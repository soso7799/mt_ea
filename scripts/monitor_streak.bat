@echo off
REM ============================================================
REM  Every 30 minutes: scan all symbols, record 3 same-direction candles
REM  into reports\streak workbook (sheets: current signals, signal log). No orders.
REM  Usage: monitor_streak.bat [--tf M30] [--bars 3] [--once] [--symbols ...]
REM  Leave this window open. Press Ctrl+C to stop.
REM  Keep MT5 open and logged in.
REM  NOTE: keep this file ASCII-only. cmd misreads UTF-8 batch files.
REM ============================================================
setlocal EnableDelayedExpansion

REM ---- edit for your setup ----
set "DATA_ROOT=H:"
set "AN_DIR=%~dp0..\analysis"
set "ML_DIR=%~dp0..\ml"

call "%~dp0find_data_root.bat" %DATA_ROOT% || exit /b 1
call "%~dp0find_mt5.bat" || exit /b 1

set "TERMINAL="
if exist "%MT5_DATA%\origin.txt" (
  for /f "usebackq delims=" %%o in (`type "%MT5_DATA%\origin.txt"`) do set "TERMINAL=%%o\terminal64.exe"
)
if defined TERMINAL if not exist "!TERMINAL!" set "TERMINAL="

where python >nul 2>nul || (
  echo [ERROR] python not found. Install Python 3.10+ and tick
  echo "Add python.exe to PATH" during setup.
  exit /b 1
)

echo === Installing / checking Python packages ===
python -m pip install -q -r "%ML_DIR%\requirements.txt" || exit /b 1

if not exist "%DATA_ROOT%\reports" mkdir "%DATA_ROOT%\reports"
echo === Streak monitor running (every bar close) ===
if defined TERMINAL (
  python "%AN_DIR%\monitor_streak.py" --out "%DATA_ROOT%\reports" --terminal "!TERMINAL!" %*
) else (
  python "%AN_DIR%\monitor_streak.py" --out "%DATA_ROOT%\reports" %*
)
endlocal
