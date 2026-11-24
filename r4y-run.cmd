@echo off
setlocal
chcp 65001 >nul
rem Portable launcher: all paths are resolved relative to this repository.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\r4y.ps1" --launch %*
set "R4Y_EXIT=%ERRORLEVEL%"
if not "%R4Y_EXIT%"=="0" pause
exit /b %R4Y_EXIT%
