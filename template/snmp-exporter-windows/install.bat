@echo off
:: Standardized snmp_exporter install (NSSM service).
:: Run as Administrator. Same script for every probe host.
::
:: Prompts for the two SNMP community strings, renders snmp.yml from the
:: placeholder copy in this folder, and installs the service. Needs
:: snmp_exporter.exe next to this file - stage it with
::   ./template/prepare-offline.sh snmp-exporter-windows
::
:: Optional environment (for unattended installs):
::   PROMETHEUS_ALLOW                comma-separated IPs/CIDRs of the Prometheus server[s]
::   SNMP_COMMUNITY_RO, SNMP_COMMUNITY  skip the community prompts

setlocal
set INSTALL_DIR=C:\SnmpExporter
set SERVICE_NAME=snmp_exporter
set EXE_NAME=snmp_exporter.exe
set PORT=9116
set SRC_DIR=%~dp0
set SUMS=%INSTALL_DIR%\SHA256SUMS
set FW_RULE=%SERVICE_NAME% (Prometheus only)

echo ============================================
echo SNMP Exporter Standard Install
echo ============================================

:: check admin rights
net session >nul 2>&1
if %errorLevel% NEQ 0 (
    echo ERROR: Right-click this file and "Run as administrator".
    pause
    exit /b 1
)

:: check kit contents
for %%F in ("%EXE_NAME%" nssm.exe snmp.yml install.ps1 SHA256SUMS) do (
    if not exist "%SRC_DIR%%%~F" (
        echo ERROR: %%~F not found in this folder. The kit is incomplete - re-extract the zip,
        echo        or stage the binaries with: ./template/prepare-offline.sh snmp-exporter-windows
        pause
        exit /b 1
    )
)

:: ---- Prometheus allow-list for the firewall rule (asked before changing anything) ----
:: set /p returns empty when there is no console (unattended); that means "no restriction".
if not defined PROMETHEUS_ALLOW set /p PROMETHEUS_ALLOW=Prometheus server IP[s]/CIDR[s], comma-separated, no spaces (empty = open to everyone):
if not defined PROMETHEUS_ALLOW goto :allow_ok
:: only digits, hex letters, . : / , - are accepted (the value goes into a netsh command line)
powershell -NoProfile -Command "if ($env:PROMETHEUS_ALLOW -match '^[0-9a-fA-F.:/,-]+$') { exit 0 } else { exit 1 }"
if errorlevel 1 (
    echo ERROR: PROMETHEUS_ALLOW may contain only IPs/CIDRs separated by commas, without spaces.
    goto :fail
)
:allow_ok

:: --- create and lock the install folder, then render snmp.yml ---
:: install.ps1 creates the folder and restricts it to SYSTEM and Administrators
:: BEFORE writing the config, so the executables below are copied into a folder
:: that is already restricted rather than one every user can write to.
echo.
echo The switch community strings are needed for this host. They are not stored
echo in this kit, so they are asked for now (input is not echoed).
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%SRC_DIR%install.ps1" -SourceDir "%SRC_DIR%" -InstallDir "%INSTALL_DIR%"
if errorlevel 1 (
    echo ERROR: snmp.yml was not written - service not installed.
    goto :fail
)

:: stop any running service first so its exe can be replaced (safe if none exists)
if exist "%INSTALL_DIR%\nssm.exe" (
    "%INSTALL_DIR%\nssm.exe" stop %SERVICE_NAME% >nul 2>&1
    "%INSTALL_DIR%\nssm.exe" remove %SERVICE_NAME% confirm >nul 2>&1
)

echo Copying files...
copy /Y "%SRC_DIR%%EXE_NAME%" "%INSTALL_DIR%\" >nul
if errorlevel 1 goto :copy_fail
copy /Y "%SRC_DIR%nssm.exe" "%INSTALL_DIR%\" >nul
if errorlevel 1 goto :copy_fail
copy /Y "%SRC_DIR%SHA256SUMS" "%SUMS%" >nul
if errorlevel 1 goto :copy_fail

:: ---- verify the COPIED files (the extracted kit folder may be user-writable) ----
echo Verifying SHA-256 of the installed files...
call :verify_hash "%EXE_NAME%" "%INSTALL_DIR%\%EXE_NAME%"
if errorlevel 1 goto :hash_fail
call :verify_hash nssm.exe "%INSTALL_DIR%\nssm.exe"
if errorlevel 1 goto :hash_fail

:: ---- firewall: allow the port only from Prometheus ----
:: empty PROMETHEUS_ALLOW keeps a rule from an earlier install rather than deleting it
if not defined PROMETHEUS_ALLOW goto :fw_open
netsh advfirewall firewall delete rule name="%FW_RULE%" >nul 2>&1
echo Adding firewall rule "%FW_RULE%" for %PROMETHEUS_ALLOW% ...
netsh advfirewall firewall add rule name="%FW_RULE%" dir=in action=allow protocol=TCP localport=%PORT% remoteip=%PROMETHEUS_ALLOW% profile=any >nul
if errorlevel 1 (
    echo ERROR: could not add the firewall rule.
    goto :fail
)
:: the rule only restricts anything while Windows Firewall is on
netsh advfirewall show allprofiles state | findstr /I /C:"OFF" >nul
if not errorlevel 1 (
    echo WARNING: Windows Firewall is OFF on at least one profile. The rule has NO effect there,
    echo          and port %PORT% is reachable from the whole network. Turn the firewall on.
)
goto :fw_done
:fw_open
netsh advfirewall firewall show rule name="%FW_RULE%" >nul 2>&1
if not errorlevel 1 (
    echo Keeping the existing firewall rule "%FW_RULE%" from an earlier install.
    goto :fw_done
)
echo WARNING: PROMETHEUS_ALLOW is empty. Port %PORT% stays OPEN to everyone on the network,
echo          without authentication, and /snmp will walk any device for anyone.
echo          Re-run install.bat with PROMETHEUS_ALLOW set to fix this.
:fw_done

echo Installing service...
"%INSTALL_DIR%\nssm.exe" install %SERVICE_NAME% "%INSTALL_DIR%\%EXE_NAME%"
"%INSTALL_DIR%\nssm.exe" set %SERVICE_NAME% AppParameters "--config.file=%INSTALL_DIR%\snmp.yml --web.listen-address=:%PORT%"
"%INSTALL_DIR%\nssm.exe" set %SERVICE_NAME% DisplayName "SNMP Exporter"
"%INSTALL_DIR%\nssm.exe" set %SERVICE_NAME% Start SERVICE_AUTO_START
"%INSTALL_DIR%\nssm.exe" set %SERVICE_NAME% AppStdout "%INSTALL_DIR%\service.log"
"%INSTALL_DIR%\nssm.exe" set %SERVICE_NAME% AppStderr "%INSTALL_DIR%\service.log"
"%INSTALL_DIR%\nssm.exe" set %SERVICE_NAME% AppRotateFiles 1

echo Starting service...
"%INSTALL_DIR%\nssm.exe" start %SERVICE_NAME%

timeout /t 2 >nul
echo Checking listener on port %PORT%...
netstat -ano | findstr :%PORT%
if errorlevel 1 (
    echo.
    echo WARNING: nothing is listening on %PORT%. The service may have failed to
    echo start - check the config and the log:
    echo    "%INSTALL_DIR%\nssm.exe" status %SERVICE_NAME%
    echo    type "%INSTALL_DIR%\service.log"
)

echo.
echo Done. Verify at http://localhost:%PORT%/ on this PC.
echo Install path: %INSTALL_DIR%
pause
endlocal
exit /b 0

:copy_fail
echo ERROR: copying files into %INSTALL_DIR% failed. Install aborted.
goto :fail

:hash_fail
echo ERROR: SHA-256 check failed or entry missing in SHA256SUMS. Install aborted, service not installed.
goto :fail

:fail
pause
endlocal
exit /b 1

:: usage: call :verify_hash <name in SHA256SUMS> <file to check>  (exit 0 = match)
:verify_hash
powershell -NoProfile -Command "$l=Get-Content -LiteralPath '%SUMS%' | Where-Object { $_ -match ('^[0-9a-fA-F]{64}\s+\*?' + [regex]::Escape('%~1') + '\s*$') } | Select-Object -First 1; if (-not $l) { exit 2 }; $e=($l -split '\s+')[0].ToLower(); $h=(Get-FileHash -Algorithm SHA256 -LiteralPath '%~2').Hash.ToLower(); if ($e -eq $h) { exit 0 } else { exit 1 }"
exit /b %errorlevel%
