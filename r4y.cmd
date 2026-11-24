@echo off
setlocal
chcp 65001 >nul
if not exist "%~dp0scripts\r4y.ps1" (
  echo R4Y installer script is missing: scripts\r4y.ps1
  exit /b 1
)
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\r4y.ps1" %*
exit /b %ERRORLEVEL%
