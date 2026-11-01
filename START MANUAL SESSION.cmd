@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-vrchat-trial.ps1" -ManualSession
set "sessionExit=%ERRORLEVEL%"
echo.
echo Session ended. Wait for verified rollback; use RECOVER only if cleanup failed after the harness exited.
pause
exit /b %sessionExit%
