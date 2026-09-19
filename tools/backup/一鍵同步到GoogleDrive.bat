@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Sync-ExportCSV-ToGoogleDrive.ps1"
echo.
echo Done. Press any key to close this window.
pause >nul
