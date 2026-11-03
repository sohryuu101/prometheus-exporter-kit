@echo off
:: Removes blackbox_exporter service. Run as Administrator.
set INSTALL_DIR=C:\BlackboxExporter
set SERVICE_NAME=blackbox_exporter

echo ============================================
echo Blackbox Exporter Uninstall
echo ============================================

net session >nul 2>&1
if %errorLevel% NEQ 0 (
    echo ERROR: Run as administrator.
    timeout /t 5 /nobreak >nul 2>&1
    exit /b 1
)

if not exist "%INSTALL_DIR%\nssm.exe" (
    echo nssm.exe not found in %INSTALL_DIR% - nothing to remove or already uninstalled.
    timeout /t 5 /nobreak >nul 2>&1
    exit /b 0
)

echo Stopping service...
"%INSTALL_DIR%\nssm.exe" stop %SERVICE_NAME% >nul 2>&1

echo Removing service...
"%INSTALL_DIR%\nssm.exe" remove %SERVICE_NAME% confirm >nul 2>&1

echo Removing firewall rule...
netsh advfirewall firewall delete rule name="%SERVICE_NAME% (Prometheus only)" >nul 2>&1

timeout /t 2 >nul
echo Confirming port 9115 is free...
netstat -ano | findstr :9115 >nul 2>&1
if %errorLevel% EQU 0 (
    echo WARNING: something is still listening on 9115 - check manually.
) else (
    echo Confirmed: port 9115 no longer listening.
)

echo.
echo Service removed. Files left in %INSTALL_DIR% - delete manually if no longer needed.
timeout /t 5 /nobreak >nul 2>&1
