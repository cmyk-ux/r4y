@echo off
setlocal
chcp 65001 >nul
if not exist "%~dp0scripts\install.ps1" (
  echo R4Y launcher is missing: scripts\install.ps1
  exit /b 1
)
powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0scripts\install.ps1" -OptionString "--launch"
set "R4Y_EXIT=%ERRORLEVEL%"
if not "%R4Y_EXIT%"=="0" pause
exit /b %R4Y_EXIT%
