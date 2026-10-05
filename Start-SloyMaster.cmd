@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0launch-print-advisor.ps1"
if errorlevel 1 pause
