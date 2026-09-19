@echo off
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Sync-ExportCSV-ToGoogleDrive.ps1" -Source "D:\資料查詢\ExportCSV" -Destination "G:\ExportCSV"
echo.
echo (執行結束，按任意鍵關閉視窗)
pause >nul
