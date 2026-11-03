# Remote push of BlackboxExporterKit to multiple induction PCs.
# Run FROM your admin PC (not on the induction PCs). Requires:
#  - Admin credentials valid on target PCs
#  - Admin$ share reachable (SMB) and WinRM enabled on targets
#    (enable on target once: Enable-PSRemoting -Force)
#
# Usage:
#   .\deploy_remote.ps1 -Targets "PC-IND-01","PC-IND-02","10.0.0.15"

param(
    [Parameter(Mandatory=$true)]
    [string[]]$Targets,
    [string]$KitPath = "$PSScriptRoot"
)

$cred = Get-Credential -Message "Enter admin credentials valid on target induction PCs"

foreach ($pc in $Targets) {
    Write-Host "=== $pc ===" -ForegroundColor Cyan
    try {
        $remotePath = "\\$pc\C$\BlackboxExporterKit"
        Write-Host "Copying kit to $remotePath ..."
        if (-not (Test-Path $remotePath)) {
            New-Item -ItemType Directory -Path $remotePath -Force | Out-Null
        }
        Copy-Item -Path "$KitPath\*" -Destination $remotePath -Recurse -Force

        Write-Host "Running install.bat remotely ..."
        Invoke-Command -ComputerName $pc -Credential $cred -ScriptBlock {
            Set-Location "C:\BlackboxExporterKit"
            & .\install.bat
        }
        Write-Host "$pc done." -ForegroundColor Green
    }
    catch {
        Write-Host "$pc FAILED: $_" -ForegroundColor Red
    }
}
