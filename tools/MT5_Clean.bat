@echo off
title MT5 Clean
powershell -NoProfile -ExecutionPolicy Bypass -Command "$d=@('%~dp0',(Join-Path $env:USERPROFILE 'Desktop'),(Join-Path $env:USERPROFILE 'Downloads'),(Join-Path $env:USERPROFILE 'OneDrive\Desktop')); $s=Get-ChildItem -LiteralPath $d -Filter 'Keep-MT5Needed*.ps1' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1; if(-not $s){Write-Host 'Keep-MT5Needed.ps1 not found. Put it on the Desktop.' -ForegroundColor Red; exit 1}; $k=Get-ChildItem -LiteralPath $d -Filter 'MT5_*.txt' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1; Write-Host $s.FullName; $p=@{Delete=$true;Interactive=$true}; if($k){$p.KeepList=$k.FullName; Write-Host $k.FullName}; & $s.FullName @p"
echo.
pause
