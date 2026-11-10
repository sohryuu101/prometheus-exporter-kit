@echo off
:: Removes the blackbox_exporter service and its firewall rule. Run as Administrator.
:: Does not depend on C:\BlackboxExporter\nssm.exe: it uses the Service Control
:: Manager directly, so it also works when that file is missing or unreadable.
setlocal
set INSTALL_DIR=C:\BlackboxExporter
set SERVICE_NAME=blackbox_exporter
set PROC_NAME=blackbox_exporter
set PORT=9115

echo ============================================
echo Blackbox Exporter Uninstall
echo ============================================

net session >nul 2>&1
if %errorLevel% NEQ 0 (
    echo ERROR: Run as administrator.
    timeout /t 5 /nobreak >nul 2>&1
    exit /b 1
)

sc query %SERVICE_NAME% >nul 2>&1
if errorlevel 1 (
    echo Service %SERVICE_NAME% is not installed. Checking for leftover processes...
) else (
    echo Stopping and removing service %SERVICE_NAME% ...
)
call :remove_service
if errorlevel 1 (
    echo ERROR: service %SERVICE_NAME% still exists. It may be "marked for deletion":
    echo        close every Services console ^(services.msc^), Task Manager and Event Viewer
    echo        window, then re-run uninstall.bat.
    timeout /t 10 /nobreak >nul 2>&1
    endlocal
    exit /b 1
)
echo Confirmed: service %SERVICE_NAME% removed.

echo Removing firewall rule (if any)...
netsh advfirewall firewall delete rule name="%SERVICE_NAME% (Prometheus only)" >nul 2>&1

echo Confirming port %PORT% is free...
netstat -ano | findstr /R /C:":%PORT% .*LISTEN" >nul 2>&1
if %errorLevel% EQU 0 (
    echo WARNING: something is still listening on %PORT% - check manually: netstat -ano ^| findstr :%PORT%
) else (
    echo Confirmed: port %PORT% no longer listening.
)

echo.
echo Service removed. Files left in %INSTALL_DIR% - delete manually if no longer needed.
echo (They are owned by Administrators; if rmdir is denied, run: takeown /F %INSTALL_DIR% /R /A /D Y)
timeout /t 5 /nobreak >nul 2>&1
endlocal
exit /b 0

:: usage: call :remove_service  (exit 0 = service gone and its processes ended)
:: Stops the service and waits for STOPPED, deletes it, ends any leftover
:: nssm/exporter process running from %INSTALL_DIR% (only those - other NSSM
:: services are left alone), then waits up to 10 s for the deletion to complete.
:: Does not use %INSTALL_DIR%\nssm.exe, so it works when that file is missing or locked.
:remove_service
powershell -NoProfile -Command "$n='%SERVICE_NAME%'; $s=Get-Service -Name $n -ErrorAction SilentlyContinue; if ($s) { if ($s.Status -ne 'Stopped') { Stop-Service -Name $n -Force -ErrorAction SilentlyContinue; try { $s.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(20)) } catch {} }; & sc.exe delete $n | Out-Null }; $p=@(Get-Process -Name 'nssm','%PROC_NAME%' -ErrorAction SilentlyContinue | Where-Object { $_.Path -like '%INSTALL_DIR%\*' }); if ($p.Count) { $p | Stop-Process -Force -ErrorAction SilentlyContinue; $p | Wait-Process -Timeout 10 -ErrorAction SilentlyContinue }; for ($i=0; $i -lt 20; $i++) { if (-not (Get-Service -Name $n -ErrorAction SilentlyContinue)) { exit 0 }; Start-Sleep -Milliseconds 500 }; exit 1"
exit /b %errorlevel%
