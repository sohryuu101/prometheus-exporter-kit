<#
  Renders config.yml for the MSSQL exporter and locks it down.

  Called by install.bat, which prompts for the two database addresses and the
  SQL username and passes them in the environment (MSSQL_MAIN, MSSQL_BACKUP,
  MSSQL_USER). The password is prompted for HERE so that it is never echoed and
  never appears in a command line, where another user on the host could read it
  out of the process list.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SourceDir,
    [Parameter(Mandatory = $true)][string]$InstallDir
)

$ErrorActionPreference = 'Stop'

$mainAddress   = $env:MSSQL_MAIN
$backupAddress = $env:MSSQL_BACKUP
$sqlUser       = $env:MSSQL_USER

foreach ($pair in @(
        @{ Name = 'MSSQL_MAIN';   Value = $mainAddress },
        @{ Name = 'MSSQL_BACKUP'; Value = $backupAddress },
        @{ Name = 'MSSQL_USER';   Value = $sqlUser }
    )) {
    if ([string]::IsNullOrWhiteSpace($pair.Value)) {
        Write-Host "ERROR: $($pair.Name) is empty." -ForegroundColor Red
        exit 1
    }
}

# --- password, not echoed ---
$secure = Read-Host -Prompt "MSSQL password for '$sqlUser'" -AsSecureString
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
try {
    $plainPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
}
finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
}

if ([string]::IsNullOrEmpty($plainPassword)) {
    Write-Host 'ERROR: MSSQL password cannot be empty.' -ForegroundColor Red
    exit 1
}

# --- these are inserted into sqlserver:// URLs, so percent-encode them ---
$encodedUser     = [uri]::EscapeDataString($sqlUser)
$encodedPassword = [uri]::EscapeDataString($plainPassword)
$plainPassword   = $null

# --- render ---
$templatePath = Join-Path $SourceDir 'config.yml.tmpl'
$configPath   = Join-Path $InstallDir 'config.yml'

if (-not (Test-Path -LiteralPath $templatePath)) {
    Write-Host "ERROR: $templatePath not found." -ForegroundColor Red
    exit 1
}

$content = Get-Content -LiteralPath $templatePath -Raw
$content = $content.Replace('${TARGET_IP_MAIN}', $mainAddress)
$content = $content.Replace('${TARGET_IP_BACKUP}', $backupAddress)
$content = $content.Replace('${MSSQL_SA_USER}', $encodedUser)
$content = $content.Replace('${MSSQL_SA_PASSWORD}', $encodedPassword)
$encodedUser     = $null
$encodedPassword = $null

# TLS for the SQL connection: encrypt=true keeps the login and results off the
# wire in clear text. The certificate is not validated by default because most
# SQL Servers use a self-signed one; set MSSQL_TRUST_CERT=false once the server
# has a certificate this host trusts. MSSQL_ENCRYPT=disable is only for servers
# that cannot do TLS 1.2.
$encrypt   = if ($env:MSSQL_ENCRYPT)    { $env:MSSQL_ENCRYPT }    else { 'true' }
$trustCert = if ($env:MSSQL_TRUST_CERT) { $env:MSSQL_TRUST_CERT } else { 'true' }
if (@('true', 'disable') -notcontains $encrypt) {
    Write-Host 'ERROR: MSSQL_ENCRYPT must be true or disable.' -ForegroundColor Red
    exit 1
}
if (@('true', 'false') -notcontains $trustCert) {
    Write-Host 'ERROR: MSSQL_TRUST_CERT must be true or false.' -ForegroundColor Red
    exit 1
}
if ($encrypt -eq 'disable') {
    Write-Host 'WARNING: MSSQL_ENCRYPT=disable sends the SQL login without TLS.' -ForegroundColor Yellow
}
elseif ($trustCert -eq 'true') {
    Write-Host 'NOTE: the SQL connection is encrypted, but the server certificate is NOT validated' -ForegroundColor Yellow
    Write-Host '      (TrustServerCertificate=true), so an active man-in-the-middle is not detected.' -ForegroundColor Yellow
    Write-Host '      Once the server certificate (or its CA) is in this host''s trust store, re-run' -ForegroundColor Yellow
    Write-Host '      with MSSQL_TRUST_CERT=false.' -ForegroundColor Yellow
}
$content = $content.Replace('${MSSQL_ENCRYPT}', $encrypt)
$content = $content.Replace('${MSSQL_TRUST_CERT}', $trustCert)

if ($content -match '\$\{[A-Z_]+\}') {
    Write-Host "ERROR: $templatePath still contains a placeholder after rendering: $($Matches[0])" -ForegroundColor Red
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
# If C:\MssqlExporter were a junction, both the config and the ACL applied to it
# would land on whatever the link points at, which could put the SQL login in a
# folder the attacker controls. A pre-existing directory that is not a link is
# still subject to the owner check below, which refuses one created by a
# principal that is not SYSTEM or an administrator. config.yml is handled after
# the directory is locked, so there is no window in which to plant one.
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
# config.yml holds the SQL login, so it must never exist with inherited, broadly
# readable permissions - not even briefly. Locking the directory first means the
# file only ever inherits the two trusted principals, and install.bat copies the
# executables in afterwards, once the directory is already restricted. SYSTEM
# needs write on the directory (NSSM writes service.log into it), but only read on
# the config file itself.
if (-not (Test-Path -LiteralPath $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
}

if ((Set-LockedDownAcl -Path $InstallDir -Rights '(OI)(CI)F') -ne 0) {
    Write-Host "ERROR: could not restrict permissions on $InstallDir" -ForegroundColor Red
    exit 1
}
if (-not (Test-LockedDown -Path $InstallDir -Label $InstallDir)) {
    Write-Host 'Refusing to write the SQL login into a directory other users can reach.' -ForegroundColor Red
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
        Write-Host 'Refusing to write the SQL login through it. Remove it and re-run.' -ForegroundColor Red
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
    Write-Host 'It holds the SQL login and may still be readable by other users - fix it before use.' -ForegroundColor Red
    exit 1
}

Write-Host "Wrote $configPath" -ForegroundColor Green
exit 0
