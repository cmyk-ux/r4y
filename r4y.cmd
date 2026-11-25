@echo off
setlocal
chcp 65001 >nul
if not exist "%~dp0scripts\install.ps1" (
  echo R4Y installer is missing: scripts\install.ps1
  set "R4Y_EXIT=1"
  goto :failed
)
set "R4Y_OPTIONS=%*"
powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0scripts\install.ps1" -OptionString "%R4Y_OPTIONS%"
set "R4Y_EXIT=%ERRORLEVEL%"
if not "%R4Y_EXIT%"=="0" goto :failed
exit /b 0

:failed
echo.
echo R4Y installer exited with code %R4Y_EXIT%.
pause
exit /b %R4Y_EXIT%
