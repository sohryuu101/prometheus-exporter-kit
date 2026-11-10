@echo off
:: Standardized mssql_exporter install (NSSM service).
:: Run as Administrator.
::
:: Prompts for the two database addresses and the SQL login, renders config.yml
:: from config.yml.tmpl, validates it, and installs the service.
:: Needs sql_exporter.exe next to this file - stage it with
::   ./template/prepare-offline.sh mssql-exporter-windows
::
:: Optional environment (for unattended installs):
::   PROMETHEUS_ALLOW   comma-separated IPs/CIDRs of the Prometheus server[s]
::   MSSQL_ENCRYPT      true (default) or disable
::   MSSQL_TRUST_CERT   true (default, self-signed SQL certificates) or false

setlocal
set INSTALL_DIR=C:\MssqlExporter
set SERVICE_NAME=mssql_exporter
set EXE_NAME=sql_exporter.exe
set PORT=9399
set PROC_NAME=sql_exporter
set SRC_DIR=%~dp0
set SUMS=%INSTALL_DIR%\SHA256SUMS
set FW_RULE=%SERVICE_NAME% (Prometheus only)

echo ============================================
echo MSSQL Exporter Standard Install
echo ============================================

:: check admin rights
net session >nul 2>&1
if %errorLevel% NEQ 0 (
    echo ERROR: Right-click this file and "Run as administrator".
    pause
    exit /b 1
)

:: check kit contents
for %%F in ("%EXE_NAME%" nssm.exe config.yml.tmpl install.ps1 SHA256SUMS) do (
    if not exist "%SRC_DIR%%%~F" (
        echo ERROR: %%~F not found in this folder. The kit is incomplete - re-extract the zip,
        echo        or stage the binaries with: ./template/prepare-offline.sh mssql-exporter-windows
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

echo.
echo Enter the MSSQL addresses and SQL login for this host.
echo Use a dedicated read-only monitoring login (VIEW SERVER STATE), not sa.
echo The password is asked for in the next step and is not echoed.
echo.
set "MAIN="
set "BACKUP="
set "SQLUSER="
set /p "MAIN=MSSQL main address (IP[:port]): "
if not defined MAIN (
    echo ERROR: main address cannot be empty.
    goto :fail
)
set /p "BACKUP=MSSQL backup address (IP[:port]): "
if not defined BACKUP (
    echo ERROR: backup address cannot be empty.
    goto :fail
)
set /p "SQLUSER=MSSQL username: "
if not defined SQLUSER (
    echo ERROR: MSSQL username cannot be empty.
    goto :fail
)

:: refuse a junction/symlink: takeown /R and icacls /T would act on its target
if exist "%INSTALL_DIR%" (
    powershell -NoProfile -Command "if ((Get-Item -LiteralPath '%INSTALL_DIR%' -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { exit 1 }; exit 0"
    if errorlevel 1 goto :reparse_fail
)
:: takeown first: it uses the take-ownership privilege, so it also works on files an
:: earlier install left without any access for the current admin (icacls /setowner
:: alone fails there with "Access is denied"). Not fatal on its own: "/D Y" is
:: rejected on non-English Windows, and the per-file check below is the verdict.
if exist "%INSTALL_DIR%" takeown /F "%INSTALL_DIR%" /R /A /D Y >nul 2>&1

:: --- create and lock the install folder, then render config.yml ---
:: install.ps1 creates the folder and restricts it to SYSTEM and Administrators
:: BEFORE writing the config, so the executables below are copied into a folder
:: that is already restricted rather than one every user can write to.
set "MSSQL_MAIN=%MAIN%"
set "MSSQL_BACKUP=%BACKUP%"
set "MSSQL_USER=%SQLUSER%"
echo.
echo Rendering config.yml ...
powershell -NoProfile -ExecutionPolicy Bypass -File "%SRC_DIR%install.ps1" -SourceDir "%SRC_DIR%" -InstallDir "%INSTALL_DIR%"
set "PS_RESULT=%errorLevel%"
set "MSSQL_MAIN="
set "MSSQL_BACKUP="
set "MSSQL_USER="
set "MAIN="
set "BACKUP="
set "SQLUSER="
if not "%PS_RESULT%"=="0" (
    echo ERROR: config.yml was not written - service not installed.
    goto :fail
)

:: ---- remove an earlier install's service before replacing its files ----
:: A running service keeps nssm.exe and the exporter exe open, so neither could be
:: replaced. This does not depend on the installed nssm.exe being present or usable.
echo Removing any existing %SERVICE_NAME% service ...
call :remove_service
if errorlevel 1 goto :svc_remove_fail

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

:: install.ps1 locks only the folder itself. Files an earlier (older) install left
:: behind can still carry their own explicit entries, so reset every file to inherit
:: from the locked folder, then put back the read-only entries on config.yml.
icacls "%INSTALL_DIR%\*" /reset /T /C >nul
icacls "%INSTALL_DIR%\config.yml" /inheritance:r /grant:r *S-1-5-18:(R) *S-1-5-32-544:(R) >nul
if errorlevel 1 goto :acl_fail

:: allow-list check on the folder AND every file in it (icacls /C keeps going after
:: per-file errors, so its exit code alone does not prove the lock-down worked):
:: every ACE must be SYSTEM or Administrators, the owner one of those or the installing
:: admin (the default owner of new files depends on local policy), no reparse points
powershell -NoProfile -Command "$ok='S-1-5-18','S-1-5-32-544'; $own=$ok + [Security.Principal.WindowsIdentity]::GetCurrent().User.Value; $sid=[Security.Principal.SecurityIdentifier]; $items=@(Get-Item -LiteralPath '%INSTALL_DIR%' -Force) + @(Get-ChildItem -LiteralPath '%INSTALL_DIR%' -Force -Recurse); foreach ($i in $items) { if ($i.Attributes -band [IO.FileAttributes]::ReparsePoint) { Write-Host ('  reparse point: ' + $i.FullName); exit 1 }; $a=Get-Acl -LiteralPath $i.FullName; $r=@($a.GetAccessRules($true,$true,$sid)); if (($own -notcontains $a.GetOwner($sid).Value) -or $r.Count -eq 0 -or @($r | Where-Object { $ok -notcontains $_.IdentityReference.Value }).Count -gt 0) { Write-Host ('  unexpected owner or permissions: ' + $i.FullName); exit 1 } }; exit 0"
if errorlevel 1 goto :acl_fail

:: --- validate the rendered config before installing anything ---
echo Validating the rendered config...
"%INSTALL_DIR%\%EXE_NAME%" -config.file="%INSTALL_DIR%\config.yml" -config.check
if errorlevel 1 (
    echo.
    echo WARNING: sql_exporter did not accept the rendered config ^(see above^).
    choice /c YN /n /m "Install the service anyway? [Y/N] "
    if errorlevel 2 (
        echo Aborted - no service was installed.
        goto :fail
    )
)
echo Config OK.

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
"%INSTALL_DIR%\nssm.exe" install %SERVICE_NAME% "%INSTALL_DIR%\%EXE_NAME%" || goto :svc_install_fail
"%INSTALL_DIR%\nssm.exe" set %SERVICE_NAME% AppParameters "-config.file=%INSTALL_DIR%\config.yml" || goto :svc_install_fail
"%INSTALL_DIR%\nssm.exe" set %SERVICE_NAME% DisplayName "MSSQL Exporter" || goto :svc_install_fail
"%INSTALL_DIR%\nssm.exe" set %SERVICE_NAME% Start SERVICE_AUTO_START || goto :svc_install_fail
"%INSTALL_DIR%\nssm.exe" set %SERVICE_NAME% AppStdout "%INSTALL_DIR%\service.log" || goto :svc_install_fail
"%INSTALL_DIR%\nssm.exe" set %SERVICE_NAME% AppStderr "%INSTALL_DIR%\service.log" || goto :svc_install_fail
"%INSTALL_DIR%\nssm.exe" set %SERVICE_NAME% AppRotateFiles 1 || goto :svc_install_fail

echo Starting service...
:: nssm start's own exit code is not trusted: the check below is the real verdict
"%INSTALL_DIR%\nssm.exe" start %SERVICE_NAME%

:: NSSM reports the service as Running even while it keeps restarting a crashing
:: exporter (e.g. a bad config), so also require a listener on the port.
echo Waiting for %SERVICE_NAME% to listen on port %PORT% ...
powershell -NoProfile -Command "$tcp=[bool](Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue); for ($i=0; $i -lt 30; $i++) { $s=Get-Service -Name '%SERVICE_NAME%' -ErrorAction SilentlyContinue; if ($s -and $s.Status -eq 'Running') { if (-not $tcp) { exit 0 }; if (Get-NetTCPConnection -LocalPort %PORT% -State Listen -ErrorAction SilentlyContinue) { exit 0 } }; Start-Sleep -Milliseconds 500 }; exit 1"
if errorlevel 1 goto :svc_start_fail

echo.
echo Done. %SERVICE_NAME% is running and listening on port %PORT%.
echo Verify at http://localhost:%PORT%/ on this PC.
echo Install path: %INSTALL_DIR%
echo Config (holds the SQL login): %INSTALL_DIR%\config.yml
pause
endlocal
exit /b 0

:copy_fail
echo ERROR: copying files into %INSTALL_DIR% failed. Install aborted.
echo        If a file is in use, find the process with resmon.exe (CPU tab, Associated Handles).
goto :fail

:hash_fail
echo ERROR: SHA-256 check failed or entry missing in SHA256SUMS. Install aborted, service not installed.
goto :fail

:svc_remove_fail
echo ERROR: the existing %SERVICE_NAME% service could not be removed. It may be "marked for deletion":
echo        close every Services console (services.msc), Task Manager and Event Viewer window,
echo        then re-run install.bat. Install aborted, no files were replaced.
goto :fail

:reparse_fail
echo ERROR: %INSTALL_DIR% is a junction or symlink. Refusing to install through it.
echo        Remove it ^(rmdir "%INSTALL_DIR%" removes only the link^) and re-run.
goto :fail

:acl_fail
echo ERROR: could not lock %INSTALL_DIR% down to SYSTEM and Administrators. Install aborted.
goto :fail

:svc_install_fail
echo ERROR: nssm could not create or configure the %SERVICE_NAME% service. Install aborted.
goto :fail

:svc_start_fail
echo ERROR: %SERVICE_NAME% is installed but is not running or not listening on port %PORT%.
echo        Check config.yml and that the databases are reachable. Last lines of %INSTALL_DIR%\service.log:
powershell -NoProfile -Command "if (Test-Path -LiteralPath '%INSTALL_DIR%\service.log') { Get-Content -LiteralPath '%INSTALL_DIR%\service.log' -Tail 15 } else { Write-Host '  (no service.log yet)' }"
echo        Fix the problem, then re-run install.bat.
goto :fail

:fail
pause
endlocal
exit /b 1

:: usage: call :verify_hash <name in SHA256SUMS> <file to check>  (exit 0 = match)
:verify_hash
powershell -NoProfile -Command "$l=Get-Content -LiteralPath '%SUMS%' | Where-Object { $_ -match ('^[0-9a-fA-F]{64}\s+\*?' + [regex]::Escape('%~1') + '\s*$') } | Select-Object -First 1; if (-not $l) { exit 2 }; $e=($l -split '\s+')[0].ToLower(); $h=(Get-FileHash -Algorithm SHA256 -LiteralPath '%~2').Hash.ToLower(); if ($e -eq $h) { exit 0 } else { exit 1 }"
exit /b %errorlevel%

:: usage: call :remove_service  (exit 0 = service gone and its processes ended)
:: Stops the service and waits for STOPPED, deletes it, ends any leftover
:: nssm/exporter process running from %INSTALL_DIR% (only those - other NSSM
:: services are left alone), then waits up to 10 s for the deletion to complete.
:: Does not use %INSTALL_DIR%\nssm.exe, so it works when that file is missing or locked.
:remove_service
powershell -NoProfile -Command "$n='%SERVICE_NAME%'; $s=Get-Service -Name $n -ErrorAction SilentlyContinue; if ($s) { if ($s.Status -ne 'Stopped') { Stop-Service -Name $n -Force -ErrorAction SilentlyContinue; try { $s.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(20)) } catch {} }; & sc.exe delete $n | Out-Null }; $p=@(Get-Process -Name 'nssm','%PROC_NAME%' -ErrorAction SilentlyContinue | Where-Object { $_.Path -like '%INSTALL_DIR%\*' }); if ($p.Count) { $p | Stop-Process -Force -ErrorAction SilentlyContinue; $p | Wait-Process -Timeout 10 -ErrorAction SilentlyContinue }; for ($i=0; $i -lt 20; $i++) { if (-not (Get-Service -Name $n -ErrorAction SilentlyContinue)) { exit 0 }; Start-Sleep -Milliseconds 500 }; exit 1"
exit /b %errorlevel%
