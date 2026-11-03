# Remote push of the blackbox_exporter kit to multiple induction PCs.
# Run FROM your admin PC (not on the induction PCs). Requires:
#  - Admin credentials valid on target PCs
#  - WinRM enabled on targets (enable on target once: Enable-PSRemoting -Force)
# The kit is copied over the PSSession (no SMB share) into a unique folder under
# %WINDIR%\Temp that is locked to SYSTEM + Administrators before any file lands in
# it, install.bat runs from there, and the folder is deleted afterwards.
#
# Usage:
#   .\deploy_remote.ps1 -Targets "PC-IND-01","PC-IND-02" -PrometheusAllow "10.0.0.5,10.0.1.0/24"
#   (-PrometheusAllow: comma-separated IPs/CIDRs of the Prometheus server(s); it limits
#    the firewall rule for port 9115. Omit it and the port stays open to everyone.)

param(
    [Parameter(Mandatory=$true)]
    [string[]]$Targets,
    [string]$KitPath = "$PSScriptRoot",
    [string]$PrometheusAllow = ""
)

$cred = Get-Credential -Message "Enter admin credentials valid on target induction PCs"

foreach ($pc in $Targets) {
    Write-Host "=== $pc ===" -ForegroundColor Cyan
    $session = $null
    $stage = $null
    try {
        $session = New-PSSession -ComputerName $pc -Credential $cred -ErrorAction Stop

        # unique staging folder, locked down BEFORE the kit is copied in
        $stage = Invoke-Command -Session $session -ScriptBlock {
            $dir = Join-Path $env:WINDIR ("Temp\BlackboxKit-" + [guid]::NewGuid().ToString("N"))
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            # SIDs: S-1-5-18 = SYSTEM, S-1-5-32-544 = Administrators
            & icacls.exe $dir /setowner '*S-1-5-32-544' /T /C | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "icacls /setowner failed on $dir" }
            & icacls.exe $dir /reset /T /C | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "icacls /reset failed on $dir" }
            & icacls.exe $dir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' /T /C | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "icacls lock-down failed on $dir" }
            $ok = 'S-1-5-18', 'S-1-5-32-544'
            $sids = @((Get-Acl -LiteralPath $dir).Access | ForEach-Object {
                $_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value })
            if ($sids.Count -eq 0 -or @($sids | Where-Object { $ok -notcontains $_ }).Count -gt 0) {
                throw "Unexpected permissions on $dir"
            }
            $dir
        }

        Write-Host "Copying kit to $stage on $pc ..."
        Copy-Item -Path "$KitPath\*" -Destination $stage -ToSession $session -Recurse -Force

        Write-Host "Running install.bat remotely ..."
        Invoke-Command -Session $session -ArgumentList $stage, $PrometheusAllow -ScriptBlock {
            param($dir, $allow)
            $env:PROMETHEUS_ALLOW = $allow
            Set-Location $dir
            & cmd.exe /c ".\install.bat" | Out-Host
            if ($LASTEXITCODE -ne 0) { throw "install.bat exited with code $LASTEXITCODE" }
        }
        Write-Host "$pc done." -ForegroundColor Green
    }
    catch {
        Write-Host "$pc FAILED: $_" -ForegroundColor Red
    }
    finally {
        if ($session) {
            if ($stage) {
                try {
                    Invoke-Command -Session $session -ArgumentList $stage -ScriptBlock {
                        param($dir)
                        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
                    }
                } catch { Write-Host "$pc : could not delete staging folder $stage : $_" -ForegroundColor Yellow }
            }
            Remove-PSSession $session -ErrorAction SilentlyContinue
        }
    }
}
