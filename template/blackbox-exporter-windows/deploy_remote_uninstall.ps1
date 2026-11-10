# Remote uninstall of blackbox_exporter from multiple induction PCs.
# Run FROM your admin PC. Same WinRM access requirements as deploy_remote.ps1
# (TrustedHosts set, WinRM reachable). Also removes the firewall rule
# "blackbox_exporter (Prometheus only)". Does not depend on the kit folder or on
# C:\BlackboxExporter\nssm.exe - it talks to the Service Control Manager directly,
# and reports FAILED unless the service is confirmed gone.
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
        $result = Invoke-Command -ComputerName $pc -Credential $cred -ErrorAction Stop -ScriptBlock {
            $installDir = "C:\BlackboxExporter"
            $svc = "blackbox_exporter"
            $port = 9115

            # stop and wait, delete (works without nssm.exe)
            $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
            if ($s) {
                if ($s.Status -ne 'Stopped') {
                    Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
                    try { $s.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(20)) } catch {}
                }
                & sc.exe delete $svc | Out-Null
            }

            # NSSM's own process can outlive the stop; end leftovers from the install dir only
            $procs = @(Get-Process -Name 'nssm', 'blackbox_exporter' -ErrorAction SilentlyContinue |
                Where-Object { $_.Path -like "$installDir\*" })
            if ($procs.Count) {
                $procs | Stop-Process -Force -ErrorAction SilentlyContinue
                $procs | Wait-Process -Timeout 10 -ErrorAction SilentlyContinue
            }

            # deletion completes only once nothing holds a handle to the service
            $gone = $false
            for ($i = 0; $i -lt 20; $i++) {
                if (-not (Get-Service -Name $svc -ErrorAction SilentlyContinue)) { $gone = $true; break }
                Start-Sleep -Milliseconds 500
            }
            if (-not $gone) {
                throw "service $svc still exists (probably marked for deletion; close services.msc/Task Manager on the PC and re-run)"
            }

            & netsh.exe advfirewall firewall delete rule name="$svc (Prometheus only)" 2>$null | Out-Null

            if (Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue) {
                return "Service removed from $env:COMPUTERNAME, but something is still listening on $port - check manually."
            }
            return "Service removed from $env:COMPUTERNAME. Port $port confirmed free."
        }
        Write-Host $result -ForegroundColor Green
    }
    catch {
        Write-Host "$pc FAILED: $_" -ForegroundColor Red
    }
}
