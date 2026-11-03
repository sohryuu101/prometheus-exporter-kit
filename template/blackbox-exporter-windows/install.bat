@echo off
:: Standardized blackbox_exporter install 
:: Run as Administrator. Same script for every induction PC.

setlocal
set INSTALL_DIR=C:\BlackboxExporter
set SERVICE_NAME=blackbox_exporter
set SRC_DIR=%~dp0

echo ============================================
echo Blackbox Exporter Standard Install
echo ============================================

:: check admin rights
net session >nul 2>&1
if %errorLevel% NEQ 0 (
    echo ERROR: Right-click this file and "Run as administrator".
    pause
    exit /b 1
)

:: check nssm present
if not exist "%SRC_DIR%nssm.exe" (
    echo ERROR: nssm.exe not found in this folder.
    echo Download from https://nssm.cc/download and place it next to install.bat, then re-run.
    pause
    exit /b 1
)

echo Creating install folder %INSTALL_DIR% ...
if not exist "%INSTALL_DIR%" mkdir "%INSTALL_DIR%"

echo Copying files...
copy /Y "%SRC_DIR%blackbox_exporter.exe" "%INSTALL_DIR%\" >nul
copy /Y "%SRC_DIR%blackbox.yml" "%INSTALL_DIR%\" >nul
copy /Y "%SRC_DIR%nssm.exe" "%INSTALL_DIR%\" >nul

echo Removing any existing service (safe if none exists)...
"%INSTALL_DIR%\nssm.exe" stop %SERVICE_NAME% >nul 2>&1
"%INSTALL_DIR%\nssm.exe" remove %SERVICE_NAME% confirm >nul 2>&1

echo Installing service...
"%INSTALL_DIR%\nssm.exe" install %SERVICE_NAME% "%INSTALL_DIR%\blackbox_exporter.exe" "--config.file=%INSTALL_DIR%\blackbox.yml"
"%INSTALL_DIR%\nssm.exe" set %SERVICE_NAME% DisplayName "Blackbox Exporter (PLC Monitoring)"
"%INSTALL_DIR%\nssm.exe" set %SERVICE_NAME% Start SERVICE_AUTO_START
"%INSTALL_DIR%\nssm.exe" set %SERVICE_NAME% AppStdout "%INSTALL_DIR%\service.log"
"%INSTALL_DIR%\nssm.exe" set %SERVICE_NAME% AppStderr "%INSTALL_DIR%\service.log"
"%INSTALL_DIR%\nssm.exe" set %SERVICE_NAME% AppRotateFiles 1

echo Starting service...
"%INSTALL_DIR%\nssm.exe" start %SERVICE_NAME%

timeout /t 2 >nul
echo Checking listener on port 9115...
netstat -ano | findstr :9115

echo.
echo Done. Verify at http://localhost:9115 on this PC.
echo Install path: %INSTALL_DIR%
pause
endlocal
