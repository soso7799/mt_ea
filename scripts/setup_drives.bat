@echo off
REM ============================================================
REM  Create the folder layout on the history drive and the program
REM  drive, and link the MT5 file sandboxes to them.
REM  Run as Administrator.
REM  Usage: setup_drives.bat [MT5 FolderID]   (auto-detected if omitted)
REM  NOTE: keep this file ASCII-only. cmd misreads UTF-8 batch files.
REM ============================================================
setlocal

REM ---- edit for your setup ----
REM History drive
set "DATA_ROOT=H:"
REM Program drive: three levels above this script (...\src\mt_ea\scripts)
for %%I in ("%~dp0..\..\..") do set "PROG_ROOT=%%~fI"
REM LINK_BASES=1 moves MT5 "bases" to the history drive (slower backtests)
set "LINK_BASES=0"

if not exist "%DATA_ROOT%\" (
  echo [ERROR] Cannot see history drive %DATA_ROOT%
  echo As Administrator, mapped drive letters may be hidden.
  echo Set DATA_ROOT to the network path, e.g. \\server\share
  exit /b 1
)

call "%~dp0find_mt5.bat" %1 || exit /b 1
echo History drive: %DATA_ROOT%
echo Program drive: %PROG_ROOT%

echo === History drive folders ===
for %%D in (bases export\bars export\ticks trade_logs tester_reports backups ml\features ml\reports) do (
  if not exist "%DATA_ROOT%\%%D" mkdir "%DATA_ROOT%\%%D"
)

echo === Program drive folders ===
for %%D in (src releases releases\models presets scripts terminals) do (
  if not exist "%PROG_ROOT%\%%D" mkdir "%PROG_ROOT%\%%D"
)

echo === Link MQL5\Files\trade_logs (trade log CSV) ===
if exist "%MT5_DATA%\MQL5\Files\trade_logs" (
  echo Already exists, skipped
) else (
  mklink /D "%MT5_DATA%\MQL5\Files\trade_logs" "%DATA_ROOT%\trade_logs" || exit /b 1
)

echo === Link Common\Files\mt_ea_ml (ML training data) ===
set "COMMON_FILES=%APPDATA%\MetaQuotes\Terminal\Common\Files"
if not exist "%COMMON_FILES%" mkdir "%COMMON_FILES%"
if exist "%COMMON_FILES%\mt_ea_ml" (
  echo Already exists, skipped
) else (
  mklink /D "%COMMON_FILES%\mt_ea_ml" "%DATA_ROOT%\ml\features" || exit /b 1
)

echo === Link Common\Files\mt_ea_models (ML models) ===
if exist "%COMMON_FILES%\mt_ea_models" (
  echo Already exists, skipped
) else (
  mklink /D "%COMMON_FILES%\mt_ea_models" "%PROG_ROOT%\releases\models" || exit /b 1
)

if "%LINK_BASES%"=="1" (
  echo === Move bases to history drive ^(close MT5 first^) ===
  tasklist /FI "IMAGENAME eq terminal64.exe" | find /I "terminal64.exe" >nul && (
    echo [ERROR] MT5 is still running. Close it first.
    exit /b 1
  )
  robocopy "%MT5_DATA%\bases" "%DATA_ROOT%\bases" /E /MOVE /R:2 /W:5
  if errorlevel 8 exit /b 1
  if exist "%MT5_DATA%\bases" rmdir "%MT5_DATA%\bases"
  mklink /D "%MT5_DATA%\bases" "%DATA_ROOT%\bases" || exit /b 1
)

echo Done.
endlocal
