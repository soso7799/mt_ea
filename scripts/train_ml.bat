@echo off
chcp 65001 >nul
REM ============================================================
REM  ML 第2階段：訓練模型
REM  讀 H:\ml\features\features_*.csv → 輸出 releases\models\model.onnx，報告到 H:\ml\reports
REM  用法：train_ml.bat [其他 train.py 參數，例如 --model logreg]
REM ============================================================
setlocal

REM ---- 依你的環境修改 ----
set "DATA_ROOT=H:"
for %%I in ("%~dp0..\..\..") do set "PROG_ROOT=%%~fI"
set "ML_DIR=%~dp0..\ml"

where python >nul 2>nul || (
  echo [錯誤] 找不到 python，請先安裝 Python 3.10 以上版本並勾選「Add python.exe to PATH」
  exit /b 1
)

echo === 安裝 / 確認 Python 套件 ===
python -m pip install -q -r "%ML_DIR%\requirements.txt" || exit /b 1

echo === 開始訓練 ===
python "%ML_DIR%\train.py" --data "%DATA_ROOT%\ml\features" --out "%PROG_ROOT%\releases\models" --report "%DATA_ROOT%\ml\reports" %*
endlocal
