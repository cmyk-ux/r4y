@echo off
setlocal
chcp 65001 >nul
if not exist "%~dp0scripts\install.ps1" (
  echo R4Y launcher is missing: scripts\install.ps1
  exit /b 1
)
if not exist "%LOCALAPPDATA%\R4Y\logs" mkdir "%LOCALAPPDATA%\R4Y\logs" >nul 2>&1
powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0scripts\install.ps1" -OptionString "--launch" > "%LOCALAPPDATA%\R4Y\logs\r4y-run.log" 2>&1
set "R4Y_EXIT=%ERRORLEVEL%"
echo R4Y output: "%LOCALAPPDATA%\R4Y\logs\r4y-run.log"
if not "%R4Y_EXIT%"=="0" pause
exit /b %R4Y_EXIT%
