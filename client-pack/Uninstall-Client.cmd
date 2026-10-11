@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Uninstall-HorrorClient.ps1" %*
if errorlevel 1 (
  echo.
  echo Uninstall failed. Read the error above; no unknown files were deleted.
  pause
  exit /b 1
)
echo.
echo Scoped uninstall command finished.
pause
