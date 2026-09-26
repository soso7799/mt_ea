@echo off
chcp 65001 >nul
REM ============================================================
REM  從執行程式碟 (P:\src\mt_ea) 部署 EA 原始碼到本機 MT5，之後在 MetaEditor 編譯
REM ============================================================
setlocal

set "SRC=%~dp0.."
set "MT5_DATA=%APPDATA%\MetaQuotes\Terminal\REPLACE_WITH_TERMINAL_ID"

if not exist "%MT5_DATA%\MQL5" (
  echo [錯誤] 找不到 MT5 資料夾: %MT5_DATA%
  exit /b 1
)

copy /Y "%SRC%\FilterLib_v5.mqh"      "%MT5_DATA%\MQL5\Include\" || exit /b 1
copy /Y "%SRC%\MultiCurrency_EA.mq5"  "%MT5_DATA%\MQL5\Experts\" || exit /b 1

echo 已部署，請在 MetaEditor 按 F7 編譯，並把 .ex5 複製到 releases\^<版本^>\
endlocal
