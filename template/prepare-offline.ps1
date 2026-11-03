<#
  Windows counterpart of prepare-offline.sh: stages the upstream binaries into
  the package folders, on a Windows host with nothing but built-in PowerShell
  (5.1 or later; no bash, curl, tar, unzip or sha256sum needed).

  Every download is checked against the SHA256SUMS committed in its package
  before it is put in place; a mismatch stages nothing for that package.

  Usage (from cmd, or double-click prepare-offline.cmd):
    prepare-offline.cmd mssql-exporter-windows snmp-exporter-windows
    prepare-offline.cmd all              (the four Linux packages, to transfer on)
  Or from PowerShell:
    powershell -ExecutionPolicy Bypass -File prepare-offline.ps1 windows-exporter

  Set OFFLINE_SOURCE_DIR to stage archives downloaded elsewhere instead of
  fetching them (same file names as the upstream release assets).

  Keep the versions below in sync with prepare-offline.sh.
#>
[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Packages
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # the progress bar slows downloads badly on 5.1

$NodeVersion            = '1.11.1'
$ProcessVersion         = '0.8.7'
$SqlVersion             = '0.24.0'
$BlackboxVersion        = '0.28.0'
$WindowsExporterVersion = '0.25.1'
$SnmpVersion            = '0.30.1'
$NssmVersion            = '2.24'

$ScriptDir        = Split-Path -Parent $MyInvocation.MyCommand.Path
$OfflineSourceDir = $env:OFFLINE_SOURCE_DIR

$LinuxPackages   = @('node-exporter', 'process-exporter', 'mssql-exporter', 'blackbox-exporter')
$WindowsPackages = @('windows-exporter', 'blackbox-exporter-windows', 'mssql-exporter-windows', 'snmp-exporter-windows')

function Show-Usage {
    Write-Host "Usage: prepare-offline.cmd [all|$(($LinuxPackages + $WindowsPackages) -join '|') ...]"
    Write-Host '  all = the four Linux packages; the Windows kits must be named explicitly.'
    exit 2
}

# PowerShell 5.1 defaults to TLS 1.0/1.1, which GitHub refuses.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.IO.Compression.FileSystem

# Hash expected for $Name in a SHA256SUMS file ("<hash>  <name>" or "<hash> *<name>"), or $null.
function Get-ExpectedHash {
    param([string]$SumsPath, [string]$Name)
    foreach ($line in Get-Content -LiteralPath $SumsPath) {
        if ($line -match '^([0-9a-fA-F]{64})\s+\*?(.+?)\s*$' -and $Matches[2] -eq $Name) {
            return $Matches[1].ToLower()
        }
    }
    return $null
}

function Test-FileHash {
    param([string]$Path, [string]$Expected)
    (Test-Path -LiteralPath $Path) -and
        ((Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLower() -eq $Expected)
}

# Copy $Asset from OFFLINE_SOURCE_DIR, or download it (3 attempts), into $DestDir.
function Get-Asset {
    param([string]$Asset, [string]$Url, [string]$DestDir)
    $dest = Join-Path $DestDir $Asset
    if ($OfflineSourceDir) {
        $src = Join-Path $OfflineSourceDir $Asset
        if (-not (Test-Path -LiteralPath $src)) { throw "Archive not found in OFFLINE_SOURCE_DIR: $src" }
        Copy-Item -LiteralPath $src -Destination $dest -Force
        return $dest
    }
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Invoke-WebRequest -Uri $Url -OutFile $dest -UseBasicParsing
            return $dest
        }
        catch {
            if ($attempt -eq 3) { throw "Download failed: $Url ($($_.Exception.Message))" }
            Write-Host "  download failed, retrying: $Url"
            Start-Sleep -Seconds (2 * $attempt)
        }
    }
}

# Extract the zip entry whose path ends with $EntrySuffix (e.g. 'win64/nssm.exe') to $DestPath.
function Expand-ZipEntry {
    param([string]$ZipPath, [string]$EntrySuffix, [string]$DestPath)
    $zip = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $entry = $zip.Entries | Where-Object { ('/' + $_.FullName) -like "*/$EntrySuffix" } | Select-Object -First 1
        if (-not $entry) { throw "$EntrySuffix not found in $ZipPath" }
        [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $DestPath, $true)
    }
    finally { $zip.Dispose() }
}

function Invoke-StageLinux {
    param([string]$Package, [string]$Archive, [string]$Url, [string]$StagingRoot)
    $sums = Join-Path (Join-Path $ScriptDir $Package) 'SHA256SUMS'
    if (-not (Test-Path -LiteralPath $sums)) { throw "Missing $sums; cannot verify the download." }
    $expected = Get-ExpectedHash -SumsPath $sums -Name $Archive
    if (-not $expected) { throw "$Archive is not listed in $sums." }

    $staging = New-Item -ItemType Directory -Path (Join-Path $StagingRoot $Package) -Force
    $file = Get-Asset -Asset $Archive -Url $Url -DestDir $staging.FullName
    if (-not (Test-FileHash -Path $file -Expected $expected)) {
        throw "Checksum verification failed for $Archive; nothing staged."
    }

    $dist = Join-Path (Join-Path $ScriptDir $Package) 'dist'
    New-Item -ItemType Directory -Path $dist -Force | Out-Null
    Move-Item -LiteralPath $file -Destination (Join-Path $dist $Archive) -Force
    Write-Host "Staged $Package in $dist" -ForegroundColor Green
}

function Invoke-StageWindowsKit {
    param([string]$Package, [string]$StagingRoot)
    $kitDir = Join-Path $ScriptDir $Package
    $sums = Join-Path $kitDir 'SHA256SUMS'
    if (-not (Test-Path -LiteralPath $sums)) { throw "Missing $sums; cannot verify the download." }

    # Each staged file: name in SHA256SUMS, release asset, URL, zip entry (or $null for a bare .exe).
    switch ($Package) {
        'windows-exporter' {
            $exe = "windows_exporter-$WindowsExporterVersion-amd64.exe"
            $main = @{ Name = $exe; Asset = $exe; Entry = $null
                       Url = "https://github.com/prometheus-community/windows_exporter/releases/download/v$WindowsExporterVersion/$exe" }
        }
        'blackbox-exporter-windows' {
            $asset = "blackbox_exporter-$BlackboxVersion.windows-amd64.zip"
            $main = @{ Name = 'blackbox_exporter.exe'; Asset = $asset; Entry = 'blackbox_exporter.exe'
                       Url = "https://github.com/prometheus/blackbox_exporter/releases/download/v$BlackboxVersion/$asset" }
        }
        'mssql-exporter-windows' {
            $asset = "sql_exporter-$SqlVersion.windows-amd64.zip"
            $main = @{ Name = 'sql_exporter.exe'; Asset = $asset; Entry = 'sql_exporter.exe'
                       Url = "https://github.com/burningalchemist/sql_exporter/releases/download/$SqlVersion/$asset" }
        }
        'snmp-exporter-windows' {
            $asset = "snmp_exporter-$SnmpVersion.windows-amd64.zip"
            $main = @{ Name = 'snmp_exporter.exe'; Asset = $asset; Entry = 'snmp_exporter.exe'
                       Url = "https://github.com/prometheus/snmp_exporter/releases/download/v$SnmpVersion/$asset" }
        }
    }
    $nssmAsset = "nssm-$NssmVersion.zip"
    $files = @($main, @{ Name = 'nssm.exe'; Asset = $nssmAsset; Entry = 'win64/nssm.exe'
                         Url = "https://nssm.cc/release/$nssmAsset" })

    $staging = New-Item -ItemType Directory -Path (Join-Path $StagingRoot $Package) -Force
    $ready = @()
    foreach ($f in $files) {
        $expected = Get-ExpectedHash -SumsPath $sums -Name $f.Name
        if (-not $expected) { throw "$($f.Name) is not listed in $sums." }
        # Already in the kit and correct (nssm.exe is committed): nothing to fetch.
        if (Test-FileHash -Path (Join-Path $kitDir $f.Name) -Expected $expected) {
            Write-Host "  $($f.Name) already present and verified"
            continue
        }
        $downloaded = Get-Asset -Asset $f.Asset -Url $f.Url -DestDir $staging.FullName
        $target = Join-Path $staging.FullName $f.Name
        if ($f.Entry) { Expand-ZipEntry -ZipPath $downloaded -EntrySuffix $f.Entry -DestPath $target }
        if (-not (Test-FileHash -Path $target -Expected $expected)) {
            throw "Checksum verification failed for $($f.Name) in $Package; nothing staged."
        }
        $ready += $target
    }

    # Only move files in once every one of them has verified.
    foreach ($t in $ready) { Move-Item -LiteralPath $t -Destination $kitDir -Force }
    Write-Host "Staged $Package in $kitDir" -ForegroundColor Green
}

if (-not $Packages -or $Packages.Count -eq 0 -or ($Packages.Count -eq 1 -and $Packages[0] -eq 'all')) {
    $Packages = $LinuxPackages
}
elseif ($Packages -contains 'all') {
    Show-Usage
}
foreach ($p in $Packages) {
    if (($LinuxPackages + $WindowsPackages) -notcontains $p) { Write-Host "Unknown package: $p"; Show-Usage }
}

$stagingRoot = Join-Path ([IO.Path]::GetTempPath()) ('exporter-offline-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stagingRoot | Out-Null
$failed = $false
try {
    foreach ($p in $Packages) {
        try {
            switch ($p) {
                'node-exporter' {
                    $a = "node_exporter-$NodeVersion.linux-amd64.tar.gz"
                    Invoke-StageLinux $p $a "https://github.com/prometheus/node_exporter/releases/download/v$NodeVersion/$a" $stagingRoot
                }
                'process-exporter' {
                    $a = "process-exporter-$ProcessVersion.linux-amd64.tar.gz"
                    Invoke-StageLinux $p $a "https://github.com/ncabatoff/process-exporter/releases/download/v$ProcessVersion/$a" $stagingRoot
                }
                'mssql-exporter' {
                    $a = "sql_exporter-$SqlVersion.linux-amd64.tar.gz"
                    Invoke-StageLinux $p $a "https://github.com/burningalchemist/sql_exporter/releases/download/$SqlVersion/$a" $stagingRoot
                }
                'blackbox-exporter' {
                    $a = "blackbox_exporter-$BlackboxVersion.linux-amd64.tar.gz"
                    Invoke-StageLinux $p $a "https://github.com/prometheus/blackbox_exporter/releases/download/v$BlackboxVersion/$a" $stagingRoot
                }
                default { Invoke-StageWindowsKit $p $stagingRoot }
            }
        }
        catch {
            Write-Host "ERROR ($p): $($_.Exception.Message)" -ForegroundColor Red
            $failed = $true
        }
    }
}
finally {
    Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
}
if ($failed) { exit 1 }
exit 0
