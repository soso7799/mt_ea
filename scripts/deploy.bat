@echo off
chcp 65001 >nul
REM ============================================================
REM  從執行程式碟 (...\src\mt_ea) 部署 EA 原始碼到本機 MT5，之後在 MetaEditor 編譯
REM  用法：deploy.bat [MT5資料夾ID]（不給會自動尋找）
REM ============================================================
setlocal

set "SRC=%~dp0.."
call "%~dp0find_mt5.bat" %1 || exit /b 1

copy /Y "%SRC%\FilterLib_v5.mqh"      "%MT5_DATA%\MQL5\Include\" || exit /b 1
copy /Y "%SRC%\TradeLogger.mqh"       "%MT5_DATA%\MQL5\Include\" || exit /b 1
copy /Y "%SRC%\MultiCurrency_EA.mq5"  "%MT5_DATA%\MQL5\Experts\" || exit /b 1

echo 已部署，請在 MetaEditor 按 F7 編譯，並把 .ex5 複製到 releases\^<版本^>\
endlocal
