# Remote uninstall of blackbox_exporter from multiple induction PCs.
# Run FROM your admin PC. Same WinRM/SMB access requirements as deploy_remote.ps1
# (TrustedHosts set, WinRM reachable). Does not depend on the kit folder still
# being present on the target - talks directly to the installed nssm.exe.
#
# Usage:
#   .\deploy_remote_uninstall.ps1 -Targets "10.0.0.9","10.0.0.40"

param(
    [Parameter(Mandatory=$true)]
    [string[]]$Targets
)

$cred = Get-Credential -Message "Enter admin credentials valid on target induction PCs"

foreach ($pc in $Targets) {
    Write-Host "=== $pc ===" -ForegroundColor Cyan
    try {
        $result = Invoke-Command -ComputerName $pc -Credential $cred -ScriptBlock {
            $installDir = "C:\BlackboxExporter"
            $svc = "blackbox_exporter"
            if (-not (Test-Path "$installDir\nssm.exe")) {
                return "nssm.exe not found in $installDir - nothing to remove or already uninstalled."
            }
            & "$installDir\nssm.exe" stop $svc 2>$null | Out-Null
            & "$installDir\nssm.exe" remove $svc confirm 2>$null | Out-Null
            Start-Sleep -Seconds 2
            $stillListening = (Get-NetTCPConnection -LocalPort 9115 -ErrorAction SilentlyContinue)
            if ($stillListening) {
                return "Service removed, but something is still listening on 9115 - check manually."
            } else {
                return "Service removed from $env:COMPUTERNAME. Port 9115 confirmed free."
            }
        }
        Write-Host $result -ForegroundColor Green
    }
    catch {
        Write-Host "$pc FAILED: $_" -ForegroundColor Red
    }
}
