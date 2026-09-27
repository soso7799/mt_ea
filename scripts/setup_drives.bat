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

call "%~dp0find_data_root.bat" %DATA_ROOT% || exit /b 1

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
call :link "%MT5_DATA%\MQL5\Files\trade_logs" "%DATA_ROOT%\trade_logs" || exit /b 1

set "COMMON_FILES=%APPDATA%\MetaQuotes\Terminal\Common\Files"
if not exist "%COMMON_FILES%" mkdir "%COMMON_FILES%"

echo === Link Common\Files\mt_ea_ml (ML training data) ===
call :link "%COMMON_FILES%\mt_ea_ml" "%DATA_ROOT%\ml\features" || exit /b 1

echo === Link Common\Files\mt_ea_models (ML models) ===
call :link "%COMMON_FILES%\mt_ea_models" "%PROG_ROOT%\releases\models" || exit /b 1

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
exit /b 0

REM ---- :link <link> <target>  -> (re)create a directory symlink.
REM      An existing link is removed first (rmdir on a link never touches
REM      the target), so a broken or outdated link gets fixed.
:link
if exist "%~1" (
  rmdir "%~1" 2>nul || (
    echo [ERROR] %~1 is a folder with files, not a link.
    echo Move its files to %~2, delete the folder, then run again.
    exit /b 1
  )
)
mklink /D "%~1" "%~2"
exit /b %errorlevel%
