@echo off
:: Standardized windows_exporter install
:: Run as Administrator. Same script for every PC.
:: Optional: set PROMETHEUS_ALLOW (comma-separated IPs/CIDRs of the Prometheus
:: server[s]) before running, e.g. for unattended installs. Otherwise it is asked.

setlocal
set INSTALL_DIR=C:\WindowsExporter
set SERVICE_NAME=windows_exporter
set EXE_NAME=windows_exporter-0.25.1-amd64.exe
set PORT=9182
set SRC_DIR=%~dp0
set SUMS=%INSTALL_DIR%\SHA256SUMS
set FW_RULE=%SERVICE_NAME% (Prometheus only)

echo ============================================
echo Windows Exporter Standard Install
echo ============================================

:: check admin rights
net session >nul 2>&1
if %errorLevel% NEQ 0 (
    echo ERROR: Right-click this file and "Run as administrator".
    pause
    exit /b 1
)

:: check exporter exe present
if not exist "%SRC_DIR%%EXE_NAME%" (
    echo ERROR: %EXE_NAME% not found in this folder.
    echo Place windows_exporter-0.25.1-amd64.exe next to install.bat, then re-run.
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

:: check checksum list present (binaries are verified after the copy)
if not exist "%SRC_DIR%SHA256SUMS" (
    echo ERROR: SHA256SUMS not found in this folder. The kit is incomplete - re-extract the zip.
    pause
    exit /b 1
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

:: ---- lock the install folder BEFORE anything is copied into it ----
echo Creating install folder %INSTALL_DIR% ...
if not exist "%INSTALL_DIR%" mkdir "%INSTALL_DIR%"
if not exist "%INSTALL_DIR%" (
    echo ERROR: could not create %INSTALL_DIR%.
    goto :fail
)

echo Locking %INSTALL_DIR% to SYSTEM and Administrators ...
:: SIDs, not names: S-1-5-18 = SYSTEM, S-1-5-32-544 = Administrators (works on any language)
:: owner first, so a pre-created folder cannot be re-opened by its old owner
icacls "%INSTALL_DIR%" /setowner *S-1-5-32-544 /T /C >nul
if errorlevel 1 goto :acl_fail
:: /reset drops explicit entries left by an earlier install; /inheritance:r alone would not
icacls "%INSTALL_DIR%" /reset /T /C >nul
if errorlevel 1 goto :acl_fail
icacls "%INSTALL_DIR%" /inheritance:r /grant:r *S-1-5-18:(OI)(CI)F *S-1-5-32-544:(OI)(CI)F /T /C >nul
if errorlevel 1 goto :acl_fail

:: allow-list check: only SYSTEM and Administrators may appear, folder is not a reparse point
powershell -NoProfile -Command "$p='%INSTALL_DIR%'; $ok='S-1-5-18','S-1-5-32-544'; if ((Get-Item -LiteralPath $p -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { exit 1 }; $a=Get-Acl -LiteralPath $p; if ($ok -notcontains $a.GetOwner([Security.Principal.SecurityIdentifier]).Value) { exit 1 }; $s=@($a.Access | ForEach-Object { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value }); if ($s.Count -eq 0) { exit 1 }; if (@($s | Where-Object { $ok -notcontains $_ }).Count -gt 0) { exit 1 }; exit 0"
if errorlevel 1 goto :acl_fail

:: stop any running service first so its exe can be replaced (safe if none exists)
if exist "%INSTALL_DIR%\nssm.exe" (
    "%INSTALL_DIR%\nssm.exe" stop %SERVICE_NAME% >nul 2>&1
    "%INSTALL_DIR%\nssm.exe" remove %SERVICE_NAME% confirm >nul 2>&1
)

echo Copying files...
copy /Y "%SRC_DIR%%EXE_NAME%" "%INSTALL_DIR%\windows_exporter.exe" >nul
if errorlevel 1 goto :copy_fail
copy /Y "%SRC_DIR%nssm.exe" "%INSTALL_DIR%\" >nul
if errorlevel 1 goto :copy_fail
copy /Y "%SRC_DIR%SHA256SUMS" "%SUMS%" >nul
if errorlevel 1 goto :copy_fail

:: ---- verify the COPIED files (the extracted kit folder may be user-writable) ----
echo Verifying SHA-256 of the installed files...
rem the exe is renamed on copy; SHA256SUMS lists it under its original name
call :verify_hash "%EXE_NAME%" "%INSTALL_DIR%\windows_exporter.exe"
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
echo          without authentication. Re-run install.bat with PROMETHEUS_ALLOW set to fix this.
:fw_done

echo Installing service...
"%INSTALL_DIR%\nssm.exe" install %SERVICE_NAME% "%INSTALL_DIR%\windows_exporter.exe"
"%INSTALL_DIR%\nssm.exe" set %SERVICE_NAME% AppParameters "--web.listen-address=:%PORT%"
"%INSTALL_DIR%\nssm.exe" set %SERVICE_NAME% DisplayName "Windows Exporter"
"%INSTALL_DIR%\nssm.exe" set %SERVICE_NAME% Start SERVICE_AUTO_START
"%INSTALL_DIR%\nssm.exe" set %SERVICE_NAME% AppStdout "%INSTALL_DIR%\service.log"
"%INSTALL_DIR%\nssm.exe" set %SERVICE_NAME% AppStderr "%INSTALL_DIR%\service.log"
"%INSTALL_DIR%\nssm.exe" set %SERVICE_NAME% AppRotateFiles 1

echo Starting service...
"%INSTALL_DIR%\nssm.exe" start %SERVICE_NAME%

timeout /t 2 >nul
echo Checking listener on port %PORT%...
netstat -ano | findstr :%PORT%

echo.
echo Done. Verify at http://localhost:%PORT%/metrics on this PC.
echo Install path: %INSTALL_DIR%
pause
endlocal
exit /b 0

:acl_fail
echo ERROR: could not lock %INSTALL_DIR% down to SYSTEM and Administrators. Install aborted.
goto :fail

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
