<#
  Renders snmp.yml with this site's SNMP community strings and locks it down.

  Called by install.bat. The communities are prompted for here rather than
  committed, so this kit and the .zip built from it never carry the switch
  credentials. Set SNMP_COMMUNITY_RO / SNMP_COMMUNITY in the environment to
  skip the prompts.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SourceDir,
    [Parameter(Mandatory = $true)][string]$InstallDir
)

$ErrorActionPreference = 'Stop'

$readOnlyCommunity = $env:SNMP_COMMUNITY_RO
$mainCommunity     = $env:SNMP_COMMUNITY

# Communities are credentials: read them without echoing them to the screen.
function Read-Secret {
    param([Parameter(Mandatory = $true)][string]$Prompt)
    $secure = Read-Host -Prompt $Prompt -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

if ([string]::IsNullOrWhiteSpace($readOnlyCommunity)) {
    $readOnlyCommunity = Read-Secret -Prompt 'SNMP read-only community (site_ro)'
}
if ([string]::IsNullOrWhiteSpace($mainCommunity)) {
    $mainCommunity = Read-Secret -Prompt 'SNMP main community (site_main)'
}
if ([string]::IsNullOrWhiteSpace($readOnlyCommunity) -or [string]::IsNullOrWhiteSpace($mainCommunity)) {
    Write-Host 'ERROR: both community strings are required.' -ForegroundColor Red
    exit 1
}

$templatePath = Join-Path $SourceDir 'snmp.yml'
$configPath   = Join-Path $InstallDir 'snmp.yml'

if (-not (Test-Path -LiteralPath $templatePath)) {
    Write-Host "ERROR: $templatePath not found." -ForegroundColor Red
    exit 1
}

# Replace the read-only placeholder first: REPLACE_WITH_READ_ONLY_COMMUNITY is
# not a substring of REPLACE_WITH_COMMUNITY, but ordering longest-first keeps
# that true if either placeholder is ever renamed.
$content = Get-Content -LiteralPath $templatePath -Raw
# Each value goes in as a single-quoted YAML string, so characters such as # : @
# in a community cannot change the meaning of the file. Control characters
# (including line breaks) are refused outright.
function ConvertTo-YamlQuoted {
    param([Parameter(Mandatory = $true)][string]$Value)
    if ($Value -match '[\x00-\x1f\x7f]') {
        Write-Host 'ERROR: a community string contains a control character.' -ForegroundColor Red
        exit 1
    }
    return "'" + $Value.Replace("'", "''") + "'"
}
$content = $content.Replace('REPLACE_WITH_READ_ONLY_COMMUNITY', (ConvertTo-YamlQuoted -Value $readOnlyCommunity))
$content = $content.Replace('REPLACE_WITH_COMMUNITY', (ConvertTo-YamlQuoted -Value $mainCommunity))
$readOnlyCommunity = $null
$mainCommunity     = $null

if ($content -match 'REPLACE_WITH_(READ_ONLY_)?COMMUNITY') {
    Write-Host "ERROR: $templatePath still contains a placeholder after rendering." -ForegroundColor Red
    exit 1
}

# Only these two principals may hold rights on the install directory or on the
# config inside it. Matched by SID so this works on non-English Windows:
# S-1-5-18 = SYSTEM, S-1-5-32-544 = Administrators.
$trustedSids = @('S-1-5-18', 'S-1-5-32-544')

function Get-OwnerSid {
    param([Parameter(Mandatory = $true)][string]$Path)
    $owner = (Get-Acl -LiteralPath $Path).Owner
    try {
        return (New-Object System.Security.Principal.NTAccount($owner)).Translate(
            [System.Security.Principal.SecurityIdentifier]).Value
    }
    catch {
        return $owner   # already a SID, or not resolvable here
    }
}

function Get-AceSids {
    param([Parameter(Mandatory = $true)][string]$Path)
    $sids = @()
    foreach ($ace in (Get-Acl -LiteralPath $Path).Access) {
        try {
            $sids += $ace.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value
        }
        catch {
            $sids += $ace.IdentityReference.Value
        }
    }
    return $sids
}

# True when the path exists and is a junction, symlink or other reparse point.
# A standard user can create a directory under C:\ and turn it into a junction
# without any special privilege, so the fixed install path is worth checking.
function Test-ReparsePoint {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $attributes = (Get-Item -LiteralPath $Path -Force).Attributes
    return [bool]($attributes -band [System.IO.FileAttributes]::ReparsePoint)
}

# Replace a path's DACL with exactly SYSTEM + Administrators. /reset comes first
# and discards any explicit ACEs a previous install or another admin left behind:
# /inheritance:r on its own only removes *inherited* ACEs, so those would survive
# and could leave another principal with read access. /grant:r then sets the two
# entries instead of adding to whatever is there. /L keeps the operation on a link
# itself rather than following it to its target. Returns icacls' exit code.
function Set-LockedDownAcl {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Rights
    )
    # icacls is a native command; under ErrorActionPreference=Stop a warning on
    # its stderr stream can abort the script, so relax the preference here.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & icacls $Path /reset /L /inheritance:r /grant:r "*S-1-5-18:$Rights" "*S-1-5-32-544:$Rights" > $null 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = $previous
    return $code
}

# Allow-list check: nothing but SYSTEM and Administrators may hold rights, and the
# owner must be one of those or the elevated user running this installer. A
# deny-list of well-known broad SIDs would miss anything else that was granted.
function Test-LockedDown {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label
    )
    $unexpected = @(Get-AceSids -Path $Path | Where-Object { $trustedSids -notcontains $_ } | Select-Object -Unique)
    if ($unexpected.Count -gt 0) {
        Write-Host "ERROR: $Label still grants rights to: $($unexpected -join ', ')" -ForegroundColor Red
        return $false
    }
    $owner = Get-OwnerSid -Path $Path
    $installingUser = ([System.Security.Principal.WindowsIdentity]::GetCurrent()).User.Value
    if (($trustedSids -notcontains $owner) -and ($owner -ne $installingUser)) {
        Write-Host "ERROR: $Label is owned by $owner, which is neither SYSTEM, Administrators, nor the installing user." -ForegroundColor Red
        return $false
    }
    return $true
}

# --- refuse a redirected install path -------------------------------------
# If C:\SnmpExporter were a junction, both the config and the ACL applied to it
# would land on whatever the link points at, which could put the switch
# credentials in a folder the attacker controls. A pre-existing directory that is
# not a link is still subject to the owner check below, which refuses one created
# by a principal that is not SYSTEM or an administrator. snmp.yml is handled
# after the directory is locked, so there is no window in which to plant one.
if (Test-ReparsePoint -Path $InstallDir) {
    Write-Host "ERROR: $InstallDir is a reparse point (junction or symlink)." -ForegroundColor Red
    Write-Host 'Refusing to install through it. Remove it and re-run.' -ForegroundColor Red
    exit 1
}
if ((Test-Path -LiteralPath $InstallDir) -and
    -not (Get-Item -LiteralPath $InstallDir -Force).PSIsContainer) {
    Write-Host "ERROR: $InstallDir exists and is not a directory." -ForegroundColor Red
    exit 1
}

# --- lock the install directory down BEFORE anything is written into it ---
# snmp.yml holds the switch community strings, so it must never exist with
# inherited, broadly readable permissions - not even briefly. Locking the
# directory first means the file only ever inherits the two trusted principals,
# and install.bat copies the executables in afterwards, once the directory is
# already restricted. SYSTEM needs write on the directory (NSSM writes
# service.log into it), but only read on the config file itself.
if (-not (Test-Path -LiteralPath $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
}

if ((Set-LockedDownAcl -Path $InstallDir -Rights '(OI)(CI)F') -ne 0) {
    Write-Host "ERROR: could not restrict permissions on $InstallDir" -ForegroundColor Red
    exit 1
}
if (-not (Test-LockedDown -Path $InstallDir -Label $InstallDir)) {
    Write-Host 'Refusing to write switch credentials into a directory other users can reach.' -ForegroundColor Red
    exit 1
}

# --- create the config fresh ------------------------------------------------
# The directory is locked and verified by this point, so nothing else can be
# created in it. Any pre-existing file is removed and the new one is created with
# CreateNew, which fails if anything is at that path. A symlink or hardlink
# planted there earlier would otherwise redirect the write to its target, and
# CreateNew turns that into a hard failure rather than a silent disclosure.
if (Test-Path -LiteralPath $configPath) {
    if (Test-ReparsePoint -Path $configPath) {
        Write-Host "ERROR: $configPath is a reparse point (junction or symlink)." -ForegroundColor Red
        Write-Host 'Refusing to write the switch credentials through it. Remove it and re-run.' -ForegroundColor Red
        exit 1
    }
    Remove-Item -LiteralPath $configPath -Force
}

# Write without a UTF-8 BOM: a BOM on the first line breaks the YAML parser.
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$stream = New-Object System.IO.FileStream(
    $configPath,
    [System.IO.FileMode]::CreateNew,
    [System.IO.FileAccess]::Write,
    [System.IO.FileShare]::None)
try {
    $bytes = $utf8NoBom.GetBytes($content)
    $stream.Write($bytes, 0, $bytes.Length)
}
finally {
    $stream.Dispose()
}

if ((Set-LockedDownAcl -Path $configPath -Rights '(R)') -ne 0) {
    Write-Host "ERROR: could not restrict permissions on $configPath" -ForegroundColor Red
    exit 1
}
if (-not (Test-LockedDown -Path $configPath -Label $configPath)) {
    Write-Host 'It holds the switch credentials and may still be readable by other users - fix it before use.' -ForegroundColor Red
    exit 1
}

Write-Host "Wrote $configPath" -ForegroundColor Green
exit 0
