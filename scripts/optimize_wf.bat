@echo off
REM ============================================================
REM  Walk-forward per-symbol optimization of MA cross, MACD Hull, KDJ and TAI.
REM  Picks parameters on the past 12 weeks, trades the next 4 weeks, repeats.
REM  Bars are downloaded from the MT5 terminal you picked (FTMO) and
REM  cached on the history drive (export\bars); the Excel file goes to
REM  the history drive reports folder.
REM  Usage: optimize_wf.bat [--years 1] [--tf M5 M15] [--symbols EURUSD ...]
REM  M5 and M15 bars are built from M1 (cached in export\bars).
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
echo === Walk-forward indicator optimization (first run downloads M1, may take several minutes) ===
if defined TERMINAL (
  python "%AN_DIR%\optimize_wf.py" --m1-cache "%DATA_ROOT%\export\bars" --out "%DATA_ROOT%\reports" --terminal "!TERMINAL!" %*
) else (
  python "%AN_DIR%\optimize_wf.py" --m1-cache "%DATA_ROOT%\export\bars" --out "%DATA_ROOT%\reports" %*
)
endlocal
