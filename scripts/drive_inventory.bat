@echo off
REM ============================================================
REM  Read-only inventory of a drive: every folder and file (name, size, date),
REM  large files, duplicate names, empty folders. Nothing is changed.
REM  The report goes to the history drive reports folder.
REM  Usage: drive_inventory.bat [drive]      default drive: G:\
REM  NOTE: keep this file ASCII-only. cmd misreads UTF-8 batch files.
REM ============================================================
setlocal EnableDelayedExpansion

set "DATA_ROOT=H:"
set "TARGET=%~1"
if "%TARGET%"=="" set "TARGET=G:\"

call "%~dp0find_data_root.bat" %DATA_ROOT% || exit /b 1

where python >nul 2>nul || (
  echo [ERROR] python not found. Install Python 3.10+ and tick
  echo "Add python.exe to PATH" during setup.
  exit /b 1
)
python -m pip install -q pandas openpyxl || exit /b 1

if not exist "%DATA_ROOT%\reports" mkdir "%DATA_ROOT%\reports"
echo === Inventory of %TARGET% (read-only) ===
python "%~dp0..\tools\drive_inventory.py" "%TARGET%" --out "%DATA_ROOT%\reports"
endlocal
