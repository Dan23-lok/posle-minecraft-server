@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-HorrorClient.ps1" -LaunchTLauncher %*
if errorlevel 1 (
  echo.
  echo Installation failed. Read the error above.
  pause
  exit /b 1
)
echo.
echo Installation complete.
pause
