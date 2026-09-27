@echo off
REM ============================================================
REM  Resolve the history-drive folder and return it in DATA_ROOT.
REM  Usage: call find_data_root.bat H:
REM  Some drives (e.g. Google Drive for desktop) do not allow folders
REM  at the drive root, only inside "My Drive". In that case the first
REM  writable subfolder is used.
REM  NOTE: keep this file ASCII-only. cmd misreads UTF-8 batch files.
REM ============================================================
setlocal
set "BASE=%~1"
set "FOUND="

if not exist "%BASE%\" (
  echo [ERROR] Cannot see history drive %BASE%
  echo As Administrator, mapped drive letters may be hidden.
  echo Set DATA_ROOT to the network path, e.g. \\server\share
  endlocal & exit /b 1
)

call :writable "%BASE%" && set "FOUND=%BASE%"
if not defined FOUND (
  for /d %%D in ("%BASE%\*") do (
    if not defined FOUND call :writable "%%~fD" && set "FOUND=%%~fD"
  )
)
if not defined FOUND (
  echo [ERROR] Cannot create folders on %BASE% or its subfolders.
  endlocal & exit /b 1
)
if not "%FOUND%"=="%BASE%" echo %BASE%\ does not allow folders, using %FOUND%
endlocal & set "DATA_ROOT=%FOUND%"
exit /b 0

:writable
if not exist "%~1\" exit /b 1
mkdir "%~1\_mt_ea_write_test" 2>nul || exit /b 1
rmdir "%~1\_mt_ea_write_test"
exit /b 0
