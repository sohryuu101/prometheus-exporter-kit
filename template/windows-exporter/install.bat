@echo off
:: Standardized windows_exporter install
:: Run as Administrator. Same script for every PC.
:: Safe to re-run over an earlier install: the old service is removed first.
:: Optional: set PROMETHEUS_ALLOW (comma-separated IPs/CIDRs of the Prometheus
:: server[s]) before running, e.g. for unattended installs. Otherwise it is asked.

setlocal
set INSTALL_DIR=C:\WindowsExporter
set SERVICE_NAME=windows_exporter
set EXE_NAME=windows_exporter-0.25.1-amd64.exe
set PORT=9182
set PROC_NAME=windows_exporter
set SRC_DIR=%~dp0
set SUMS=%INSTALL_DIR%\SHA256SUMS
set FW_RULE=%SERVICE_NAME% (Prometheus only)

:: Optional: a file named "process.include" next to this script enables per-process
:: CPU/memory metrics. Its first line is a Go regexp matched against process names
:: (see process.include.example). Read through PowerShell so a UTF-8/UTF-16 BOM -
:: which PowerShell's Set-Content/Out-File add by default - cannot corrupt the
:: regexp. Without the file the exporter keeps its upstream default collector set,
:: so the kit stays vendor-neutral.
set "PROCESS_INCLUDE="
if exist "%SRC_DIR%process.include.txt" if not exist "%SRC_DIR%process.include" (
    echo ERROR: found process.include.txt - rename it to process.include ^(no .txt^).
    goto :fail
)
if not exist "%SRC_DIR%process.include" goto :include_done
set "INCLUDE_FILE=%SRC_DIR%process.include"
set "INCLUDE_OUT=%TEMP%\proc-include.%RANDOM%%RANDOM%.txt"
powershell -NoProfile -Command "$p=(Get-Content -LiteralPath $env:INCLUDE_FILE | Where-Object { $_.Trim() -and -not $_.TrimStart().StartsWith('#') } | Select-Object -First 1); if (-not $p) { Write-Host 'process.include has no non-comment content'; exit 1 }; $p=$p.Trim(); if ($p.Length -gt 900) { Write-Host 'the regexp in process.include is longer than 900 characters'; exit 1 }; if ($p.ToCharArray() | Where-Object { [int]$_ -gt 126 }) { Write-Host 'process.include must be plain ASCII'; exit 1 }; if ($p.IndexOfAny([char[]]@(32,9,34,37,33,38,60,62,59)) -ge 0) { Write-Host 'process.include must not contain spaces, tabs, quotes, percent, !, amp, <, > or ;'; exit 1 }; try { $null=[regex]$p } catch { Write-Host ('process.include is not a valid regex: ' + $_.Exception.Message); exit 1 }; [IO.File]::WriteAllText($env:INCLUDE_OUT, $p)"
if errorlevel 1 (
    echo ERROR: invalid process.include - see the message above.
    goto :fail
)
set /p PROCESS_INCLUDE=<"%INCLUDE_OUT%"
del /q "%INCLUDE_OUT%" >nul 2>&1
:include_done

:: windows_exporter 0.25.1 defaults; --collectors.enabled REPLACES them, so
:: enabling "process" requires listing all of them again.
set "DEFAULT_COLLECTORS=cpu,cs,logical_disk,net,os,physical_disk,service,system,textfile"

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

:: ---- remove an earlier install's service before replacing its files ----
:: A running service keeps nssm.exe and the exporter exe open, so neither could be
:: replaced. This does not depend on the installed nssm.exe being present or usable.

:: Re-running without process.include silently turns per-process metrics off unless
:: this is pointed out. The installed service's AppParameters live in the registry,
:: so the check works even when the installed nssm.exe is missing or locked.
if defined PROCESS_INCLUDE goto :proc_ok
reg query "HKLM\SYSTEM\CurrentControlSet\Services\%SERVICE_NAME%\Parameters" /v AppParameters 2>nul | findstr /C:"--collector.process.include" >nul
if errorlevel 1 goto :proc_ok
echo WARNING: the installed %SERVICE_NAME% service has per-process metrics ENABLED,
echo          but there is no process.include file next to this install.bat.
echo          Continuing turns them OFF. Copy process.include here and re-run.
choice /C YN /N /D N /T 30 /M "Turn per-process metrics OFF? (Y = yes, N = abort) "
if errorlevel 2 goto :guard_abort
if errorlevel 1 goto :proc_ok
:guard_abort
echo Aborted. Nothing was changed.
pause
exit /b 1
:proc_ok

sc query %SERVICE_NAME% >nul 2>&1 && set SVC_EXISTED=1
echo Removing any existing %SERVICE_NAME% service ...
call :remove_service
if errorlevel 1 goto :svc_remove_fail
if defined SVC_EXISTED set SVC_REMOVED=1

:: ---- lock the install folder BEFORE anything is copied into it ----
echo Creating install folder %INSTALL_DIR% ...
:: refuse a junction/symlink: takeown /R and icacls /T would act on its target
if exist "%INSTALL_DIR%" (
    powershell -NoProfile -Command "if ((Get-Item -LiteralPath '%INSTALL_DIR%' -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { exit 1 }; exit 0"
    if errorlevel 1 goto :reparse_fail
)
if not exist "%INSTALL_DIR%" mkdir "%INSTALL_DIR%"
if not exist "%INSTALL_DIR%" (
    echo ERROR: could not create %INSTALL_DIR%.
    goto :fail
)

echo Locking %INSTALL_DIR% to SYSTEM and Administrators ...
:: takeown first: it uses the take-ownership privilege, so it also works on files an
:: earlier install left without any access for the current admin (icacls /setowner
:: alone fails there with "Access is denied"). Not fatal on its own: "/D Y" is
:: rejected on non-English Windows, and the per-file check below is the verdict.
if exist "%INSTALL_DIR%" takeown /F "%INSTALL_DIR%" /R /A /D Y >nul 2>&1
:: SIDs, not names: S-1-5-18 = SYSTEM, S-1-5-32-544 = Administrators (works on any language)
icacls "%INSTALL_DIR%" /setowner *S-1-5-32-544 /T /C >nul
if errorlevel 1 goto :acl_fail
:: /reset drops explicit entries left by an earlier install; /inheritance:r alone would not
icacls "%INSTALL_DIR%" /reset /T /C >nul
if errorlevel 1 goto :acl_fail
icacls "%INSTALL_DIR%" /inheritance:r /grant:r *S-1-5-18:(OI)(CI)F *S-1-5-32-544:(OI)(CI)F /T /C >nul
if errorlevel 1 goto :acl_fail

:: allow-list check on the folder AND every file in it (icacls /C keeps going after
:: per-file errors, so its exit code alone does not prove the lock-down worked):
:: every ACE must be SYSTEM or Administrators, the owner one of those or the installing
:: admin (the default owner of new files depends on local policy), no reparse points
powershell -NoProfile -Command "$ok='S-1-5-18','S-1-5-32-544'; $own=$ok + [Security.Principal.WindowsIdentity]::GetCurrent().User.Value; $sid=[Security.Principal.SecurityIdentifier]; $items=@(Get-Item -LiteralPath '%INSTALL_DIR%' -Force) + @(Get-ChildItem -LiteralPath '%INSTALL_DIR%' -Force -Recurse); foreach ($i in $items) { if ($i.Attributes -band [IO.FileAttributes]::ReparsePoint) { Write-Host ('  reparse point: ' + $i.FullName); exit 1 }; $a=Get-Acl -LiteralPath $i.FullName; $r=@($a.GetAccessRules($true,$true,$sid)); if (($own -notcontains $a.GetOwner($sid).Value) -or $r.Count -eq 0 -or @($r | Where-Object { $ok -notcontains $_.IdentityReference.Value }).Count -gt 0) { Write-Host ('  unexpected owner or permissions: ' + $i.FullName); exit 1 } }; exit 0"
if errorlevel 1 goto :acl_fail

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
set "PARAMS=--web.listen-address=:%PORT%"
if defined PROCESS_INCLUDE set "PARAMS=%PARAMS% --collectors.enabled=%DEFAULT_COLLECTORS%,process --collector.process.include=%PROCESS_INCLUDE%"
if defined PROCESS_INCLUDE echo Per-process metrics: enabled
:: "set VAR" prints name=value safely; echoing the value directly would let the
:: regex's ^( | ) be parsed by cmd as redirection/pipeline characters.
if defined PROCESS_INCLUDE set PROCESS_INCLUDE
if not defined PROCESS_INCLUDE echo Per-process metrics: disabled (no process.include file)
"%INSTALL_DIR%\nssm.exe" install %SERVICE_NAME% "%INSTALL_DIR%\windows_exporter.exe" || goto :svc_install_fail
"%INSTALL_DIR%\nssm.exe" set %SERVICE_NAME% AppParameters "%PARAMS%" || goto :svc_install_fail
"%INSTALL_DIR%\nssm.exe" set %SERVICE_NAME% DisplayName "Windows Exporter" || goto :svc_install_fail
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
echo Verify at http://localhost:%PORT%/metrics on this PC.
echo Install path: %INSTALL_DIR%
pause
endlocal
exit /b 0

:acl_fail
echo ERROR: could not lock %INSTALL_DIR% down to SYSTEM and Administrators. Install aborted.
goto :fail

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

:svc_install_fail
echo ERROR: nssm could not create or configure the %SERVICE_NAME% service. Install aborted.
goto :fail

:svc_start_fail
set NEW_SVC_INSTALLED=1
echo ERROR: %SERVICE_NAME% is installed but is not running or not listening on port %PORT%.
echo        Check the AppParameters and the log. Last lines of %INSTALL_DIR%\service.log:
powershell -NoProfile -Command "if (Test-Path -LiteralPath '%INSTALL_DIR%\service.log') { Get-Content -LiteralPath '%INSTALL_DIR%\service.log' -Tail 15 } else { Write-Host '  (no service.log yet)' }"
echo        Fix the problem, then re-run install.bat.
goto :fail

:fail
if defined SVC_REMOVED if not defined NEW_SVC_INSTALLED echo WARNING: the previous service was already removed, so this PC currently has NO exporter.
if defined SVC_REMOVED if not defined NEW_SVC_INSTALLED echo          Fix the error above, then re-run install.bat.
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
