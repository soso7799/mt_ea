@echo off
REM ============================================================
REM  Copy the EA source from this folder (...\src\mt_ea) into the
REM  local MT5, then compile in MetaEditor (F7).
REM  Usage: deploy.bat [MT5 FolderID]   (auto-detected if omitted)
REM  NOTE: keep this file ASCII-only. cmd misreads UTF-8 batch files.
REM ============================================================
setlocal

set "SRC=%~dp0.."
call "%~dp0find_mt5.bat" %1 || exit /b 1

copy /Y "%SRC%\FilterLib_v5.mqh"      "%MT5_DATA%\MQL5\Include\" || exit /b 1
copy /Y "%SRC%\TradeLogger.mqh"       "%MT5_DATA%\MQL5\Include\" || exit /b 1
copy /Y "%SRC%\MLRecorder.mqh"        "%MT5_DATA%\MQL5\Include\" || exit /b 1
copy /Y "%SRC%\MLFilter.mqh"          "%MT5_DATA%\MQL5\Include\" || exit /b 1
copy /Y "%SRC%\MultiCurrency_EA.mq5"  "%MT5_DATA%\MQL5\Experts\" || exit /b 1

echo.
echo Deployed. Open MetaEditor, press F7 to compile MultiCurrency_EA.mq5,
echo then copy the .ex5 to releases\^<version^>\
endlocal
