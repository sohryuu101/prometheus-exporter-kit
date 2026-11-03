@echo off
:: Windows entry point for prepare-offline.ps1 (see that file for usage).
:: Example: prepare-offline.cmd mssql-exporter-windows snmp-exporter-windows
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0prepare-offline.ps1" %*
exit /b %errorlevel%
