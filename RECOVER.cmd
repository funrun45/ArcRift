@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0recover-manual-session.ps1"
echo.
echo Recovery is for an exited/crashed manual harness, not for stopping a live session.
pause
