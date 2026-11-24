@echo off
setlocal
chcp 65001 >nul
if not exist "%~dp0scripts\install.ps1" (
  echo R4Y installer is missing: scripts\install.ps1
  exit /b 1
)
set "R4Y_OPTIONS=%*"
powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0scripts\install.ps1" -OptionString "%R4Y_OPTIONS%"
exit /b %ERRORLEVEL%
