@echo off
:: Removes windows_exporter service. Run as Administrator.
set INSTALL_DIR=C:\WindowsExporter
set SERVICE_NAME=windows_exporter
set PORT=9182

echo ============================================
echo Windows Exporter Uninstall
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

timeout /t 2 >nul
echo Confirming port %PORT% is free...
netstat -ano | findstr :%PORT% >nul 2>&1
if %errorLevel% EQU 0 (
    echo WARNING: something is still listening on %PORT% - check manually.
) else (
    echo Confirmed: port %PORT% no longer listening.
)

echo.
echo Service removed. Files left in %INSTALL_DIR% - delete manually if no longer needed.
timeout /t 5 /nobreak >nul 2>&1
