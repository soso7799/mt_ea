@echo off
chcp 65001 >nul
title MT5 一鍵清理
echo ==================================================
echo   MT5 一鍵清理
echo   保留：圖表使用中的 EA/指標 + 保留清單 + 相依檔 + 內建範例
echo   其餘：全部刪除（送到資源回收筒）
echo ==================================================
echo.

:check
tasklist /FI "IMAGENAME eq terminal64.exe" 2>nul | find /I "terminal64.exe" >nul && goto running
tasklist /FI "IMAGENAME eq metaeditor64.exe" 2>nul | find /I "metaeditor64.exe" >nul && goto running
goto ready

:running
echo [!] MT5 或 MetaEditor 還開著，請先全部關閉，再按任意鍵繼續...
pause >nul
goto check

:ready
echo 按任意鍵開始刪除；要取消請直接關閉這個視窗。
pause >nul
echo.
powershell -NoProfile -ExecutionPolicy Bypass -Command "$d=@('%~dp0',(Join-Path $env:USERPROFILE 'Desktop'),(Join-Path $env:USERPROFILE 'Downloads'),(Join-Path $env:USERPROFILE 'OneDrive\Desktop')); $s=Get-ChildItem -LiteralPath $d -Filter 'Keep-MT5Needed*.ps1' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1; if(-not $s){Write-Host '找不到 Keep-MT5Needed.ps1，請放在桌面、下載，或和本批次檔同一個資料夾' -ForegroundColor Red; exit 1}; $k=Get-ChildItem -LiteralPath $d -Filter 'MT5_保留清單*.txt' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1; Write-Host ('使用腳本：'+$s.FullName); $p=@{Delete=$true}; if($k){$p.KeepList=$k.FullName; Write-Host ('保留清單：'+$k.FullName)}; & $s.FullName @p"
echo.
echo 完成。按任意鍵關閉視窗。
pause >nul
