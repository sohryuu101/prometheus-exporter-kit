@echo off
:: Applies windows_exporter configuration to an ALREADY INSTALLED service without
:: copying files or reinstalling anything.
::
:: Use this to change process.include (per-process metrics) or to turn them off.
:: It rewrites the service's AppParameters in the registry and restarts the
:: service through the Service Control Manager. Nothing on disk is replaced, so
:: none of the file-lock / "marked for deletion" failure modes of a reinstall apply.
::
:: Use install.bat for the first install and for version upgrades.
:: Run as Administrator.

setlocal
set INSTALL_DIR=C:\WindowsExporter
set SERVICE_NAME=windows_exporter
set PORT=9182
set SRC_DIR=%~dp0
set "REGKEY=HKLM:\SYSTEM\CurrentControlSet\Services\%SERVICE_NAME%\Parameters"
set "DEFAULT_COLLECTORS=cpu,cs,logical_disk,net,os,physical_disk,service,system,textfile"
set "HERE=%SRC_DIR%process.include"
set "LOGFILE=%INSTALL_DIR%\service.log"
set "SVC=%SERVICE_NAME%"

echo ============================================
echo Windows Exporter - apply configuration
echo ============================================

net session >nul 2>&1
if %errorLevel% NEQ 0 (
    echo ERROR: Right-click this file and "Run as administrator".
    pause
    exit /b 1
)

sc query %SERVICE_NAME% >nul 2>&1
if errorlevel 1 (
    echo ERROR: %SERVICE_NAME% is not installed. Run install.bat first.
    pause
    exit /b 1
)

:: ---- read and validate process.include ----
:: Comment lines starting with # and blank lines are skipped; the first remaining
:: line is the regexp. Read through PowerShell so a UTF-8/UTF-16 BOM cannot
:: corrupt it, and hand it back through a temp file so cmd never re-parses it.
set "PROCESS_INCLUDE="
if exist "%HERE%.txt" if not exist "%HERE%" (
    echo ERROR: found process.include.txt - rename it to process.include ^(no .txt^).
    pause
    exit /b 1
)
if not exist "%HERE%" goto :include_done
set "INCLUDE_FILE=%HERE%"
set "INCLUDE_OUT=%TEMP%\proc-include.%RANDOM%%RANDOM%.txt"
powershell -NoProfile -Command "$p=(Get-Content -LiteralPath $env:INCLUDE_FILE | Where-Object { $_.Trim() -and -not $_.TrimStart().StartsWith('#') } | Select-Object -First 1); if (-not $p) { Write-Host 'process.include has no non-comment content'; exit 1 }; $p=$p.Trim(); if ($p.Length -gt 900) { Write-Host 'the regexp in process.include is longer than 900 characters'; exit 1 }; if ($p.ToCharArray() | Where-Object { [int]$_ -gt 126 }) { Write-Host 'process.include must be plain ASCII'; exit 1 }; if ($p.IndexOfAny([char[]]@(32,9,34,37,33,38,60,62,59)) -ge 0) { Write-Host 'process.include must not contain spaces, tabs, quotes, percent, !, amp, <, > or ;'; exit 1 }; try { $null=[regex]$p } catch { Write-Host ('process.include is not a valid regex: ' + $_.Exception.Message); exit 1 }; [IO.File]::WriteAllText($env:INCLUDE_OUT, $p)"
if errorlevel 1 (
    echo ERROR: invalid process.include - see the message above.
    pause
    exit /b 1
)
set /p PROCESS_INCLUDE=<"%INCLUDE_OUT%"
del /q "%INCLUDE_OUT%" >nul 2>&1
:include_done

:: ---- refuse to silently turn per-process metrics off ----
if defined PROCESS_INCLUDE goto :proc_ok
reg query "HKLM\SYSTEM\CurrentControlSet\Services\%SERVICE_NAME%\Parameters" /v AppParameters 2>nul | findstr /C:"--collector.process.include" >nul
if errorlevel 1 goto :proc_ok
echo WARNING: the installed %SERVICE_NAME% service has per-process metrics ENABLED,
echo          but there is no process.include in this folder. Continuing turns them OFF.
choice /C YN /N /D N /T 30 /M "Turn per-process metrics OFF? (Y = yes, N = abort) "
if errorlevel 2 goto :guard_abort
if errorlevel 1 goto :proc_ok
:guard_abort
echo Aborted. Nothing was changed.
pause
exit /b 1
:proc_ok

:: ---- build the configuration ----
set "PARAMS=--web.listen-address=:%PORT%"
if defined PROCESS_INCLUDE set "PARAMS=%PARAMS% --collectors.enabled=%DEFAULT_COLLECTORS%,process --collector.process.include=%PROCESS_INCLUDE%"
set "NEW_PARAMS=%PARAMS%"
set "EXPECT_PROC=0"
set "EXPECT_FLAG="
if defined PROCESS_INCLUDE set "EXPECT_PROC=1"
if defined PROCESS_INCLUDE set "EXPECT_FLAG=--collector.process.include=%PROCESS_INCLUDE%"

:: ---- keep the current value for rollback ----
set "PREV_PARAMS="
for /f "usebackq delims=" %%P in (`powershell -NoProfile -Command "$k=$env:REGKEY; if (Test-Path -LiteralPath $k) { (Get-ItemProperty -LiteralPath $k -Name AppParameters -ErrorAction SilentlyContinue).AppParameters }"`) do set "PREV_PARAMS=%%P"
if not defined PREV_PARAMS (
    echo ERROR: could not read the current AppParameters from
    echo        %REGKEY%
    echo        Run install.bat once first, then retry.
    pause
    exit /b 1
)

:: "set VAR" prints name=value without letting cmd parse the regexp characters.
echo Current configuration:
set PREV_PARAMS
echo New configuration:
set NEW_PARAMS

:: ---- apply, keeping the existing registry value kind ----
powershell -NoProfile -Command "$k=$env:REGKEY; try { $kind=(Get-Item -LiteralPath $k).GetValueKind('AppParameters') } catch { $kind=[Microsoft.Win32.RegistryValueKind]::String }; Set-ItemProperty -LiteralPath $k -Name AppParameters -Value $env:NEW_PARAMS -Type $kind"
if errorlevel 1 goto :apply_fail

:: ---- restart, then prove the NEW flags are live ----
:: Success requires: service Running, port listening, and, when the command line
:: is readable, the owning process carrying the exact expected flag. A command
:: line that cannot be read falls back to Running plus listening, so a valid
:: configuration is not rolled back just because WMI is locked down.
powershell -NoProfile -Command "$n=$env:SVC; $port=[int]$env:PORT; $hascmd=[bool](Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue); try { Stop-Service -Name $n -Force -ErrorAction Stop } catch {}; try { Start-Service -Name $n -ErrorAction Stop } catch {}; for ($i=0; $i -lt 40; $i++) { $svc=Get-Service -Name $n -ErrorAction SilentlyContinue; if ($svc -and $svc.Status -eq 'Running') { if (-not $hascmd) { exit 0 }; $c=Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1; if ($c) { $p=Get-CimInstance Win32_Process -Filter ('ProcessId=' + $c.OwningProcess) -ErrorAction SilentlyContinue; if (-not $p -or -not $p.CommandLine) { exit 0 }; if ($env:EXPECT_PROC -eq '1') { if ($p.CommandLine.Contains($env:EXPECT_FLAG)) { exit 0 } } else { if (-not $p.CommandLine.Contains('--collector.process.include')) { exit 0 } } } }; Start-Sleep -Milliseconds 500 }; exit 1"
if errorlevel 1 goto :rollback

echo.
echo Configuration applied. %SERVICE_NAME% is running and listening on port %PORT%.
if defined PROCESS_INCLUDE echo Per-process metrics: enabled
if not defined PROCESS_INCLUDE echo Per-process metrics: disabled (no process.include file)
echo Verify at http://localhost:%PORT%/metrics
pause
endlocal
exit /b 0

:apply_fail
echo ERROR: could not write AppParameters. Nothing was restarted, the old
echo        configuration is still in place.
pause
endlocal
exit /b 1

:rollback
echo ERROR: the service did not come up with the new configuration. Restoring the previous one...
set "OLD_PARAMS=%PREV_PARAMS%"
powershell -NoProfile -Command "$k=$env:REGKEY; try { $kind=(Get-Item -LiteralPath $k).GetValueKind('AppParameters') } catch { $kind=[Microsoft.Win32.RegistryValueKind]::String }; Set-ItemProperty -LiteralPath $k -Name AppParameters -Value $env:OLD_PARAMS -Type $kind"
if errorlevel 1 (
    echo.
    echo *** ROLLBACK FAILED: could not write the previous AppParameters back.
    echo *** Set it by hand from the "Current configuration" line printed above.
    pause
    endlocal
    exit /b 1
)
powershell -NoProfile -Command "$n=$env:SVC; $port=[int]$env:PORT; $hascmd=[bool](Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue); try { Stop-Service -Name $n -Force -ErrorAction Stop } catch {}; try { Start-Service -Name $n -ErrorAction Stop } catch {}; for ($i=0; $i -lt 40; $i++) { $svc=Get-Service -Name $n -ErrorAction SilentlyContinue; if ($svc -and $svc.Status -eq 'Running') { if (-not $hascmd) { exit 0 }; if (Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue) { exit 0 } }; Start-Sleep -Milliseconds 500 }; exit 1"
if errorlevel 1 (
    echo.
    echo *** EXPORTER IS DOWN: the previous configuration was written back but %SERVICE_NAME%
    echo *** is not listening on port %PORT%. Check %LOGFILE% and the System event log.
) else (
    echo The previous configuration was restored and the exporter is listening again.
)
echo Last lines of %LOGFILE%:
powershell -NoProfile -Command "if (Test-Path -LiteralPath $env:LOGFILE) { Get-Content -LiteralPath $env:LOGFILE -Tail 15 } else { Write-Host '  (no service.log file)' }"
pause
endlocal
exit /b 1
