@echo off
REM ============================================================
REM  Python backtest of MultiCurrency_EA (old vs fixed logic) and
REM  ML training data generation.
REM  M1 data is downloaded from the MT5 terminal you picked (FTMO)
REM  and cached on the history drive (export\bars).
REM  Usage: backtest_py.bat [--years 3] [--deposit 100000]
REM         (default period: the last 3 years up to today)
REM  Keep MT5 open and logged in. In MT5 set Tools > Options > Charts >
REM  "Max bars in chart" to Unlimited.
REM  NOTE: keep this file ASCII-only. cmd misreads UTF-8 batch files.
REM ============================================================
setlocal EnableDelayedExpansion

REM ---- edit for your setup ----
set "DATA_ROOT=H:"
set "ML_DIR=%~dp0..\ml"

call "%~dp0find_data_root.bat" %DATA_ROOT% || exit /b 1
call "%~dp0find_mt5.bat" || exit /b 1

set "TERMINAL="
if exist "%MT5_DATA%\origin.txt" (
  for /f "usebackq delims=" %%o in (`type "%MT5_DATA%\origin.txt"`) do set "TERMINAL=%%o\terminal64.exe"
)
if defined TERMINAL if not exist "!TERMINAL!" set "TERMINAL="
if defined TERMINAL (
  echo MT5 terminal: !TERMINAL!
  set "TERM_ARG=--terminal"
) else (
  echo [WARN] terminal64.exe not found, using the MT5 that is currently running
  set "TERM_ARG="
)

where python >nul 2>nul || (
  echo [ERROR] python not found. Install Python 3.10+ and tick
  echo "Add python.exe to PATH" during setup.
  exit /b 1
)

echo === Installing / checking Python packages ===
python -m pip install -q -r "%ML_DIR%\requirements.txt" || exit /b 1

echo === Backtest ===
if defined TERM_ARG (
  python "%ML_DIR%\backtest.py" --cache "%DATA_ROOT%\export\bars" --out "%DATA_ROOT%\tester_reports" --features-out "%DATA_ROOT%\ml\features" --terminal "!TERMINAL!" %*
) else (
  python "%ML_DIR%\backtest.py" --cache "%DATA_ROOT%\export\bars" --out "%DATA_ROOT%\tester_reports" --features-out "%DATA_ROOT%\ml\features" %*
)
endlocal
