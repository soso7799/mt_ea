@echo off
REM ============================================================
REM  ML phase 2: train the signal filter model.
REM  Reads H:\ml\features\features_*.csv, writes releases\models\model.onnx
REM  and a report to H:\ml\reports.
REM  Usage: train_ml.bat [extra train.py options, e.g. --model logreg]
REM  NOTE: keep this file ASCII-only. cmd misreads UTF-8 batch files.
REM ============================================================
setlocal

REM ---- edit for your setup ----
set "DATA_ROOT=H:"
for %%I in ("%~dp0..\..\..") do set "PROG_ROOT=%%~fI"
set "ML_DIR=%~dp0..\ml"

where python >nul 2>nul || (
  echo [ERROR] python not found. Install Python 3.10+ and tick
  echo "Add python.exe to PATH" during setup.
  exit /b 1
)

echo === Installing / checking Python packages ===
python -m pip install -q -r "%ML_DIR%\requirements.txt" || exit /b 1

echo === Training ===
python "%ML_DIR%\train.py" --data "%DATA_ROOT%\ml\features" --out "%PROG_ROOT%\releases\models" --report "%DATA_ROOT%\ml\reports" %*
endlocal
