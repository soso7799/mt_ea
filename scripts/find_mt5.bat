@echo off
REM ============================================================
REM  Find the MT5 data folder and return it in MT5_DATA.
REM  Usage: call find_mt5.bat [FolderID]
REM    - FolderID given : use %APPDATA%\MetaQuotes\Terminal\<FolderID>
REM    - one folder     : use it
REM    - several        : show a menu; the choice is saved in
REM                       mt5_target.txt and reused next time
REM                       (delete mt5_target.txt to choose again)
REM  NOTE: keep this file ASCII-only. cmd misreads UTF-8 batch files.
REM ============================================================
setlocal EnableDelayedExpansion
set "TERM_ROOT=%APPDATA%\MetaQuotes\Terminal"
set "SEL="
set "SAVED=%~dp0mt5_target.txt"

if not "%~1"=="" (
  set "SEL=%TERM_ROOT%\%~1"
  goto :check
)

if exist "%SAVED%" (
  set /p SAVED_ID=<"%SAVED%"
  if exist "%TERM_ROOT%\!SAVED_ID!\MQL5" (
    set "SEL=%TERM_ROOT%\!SAVED_ID!"
    echo Using saved MT5 choice. To choose again, delete: %SAVED%
    goto :check
  )
)

set /a N=0
for /d %%T in ("%TERM_ROOT%\*") do (
  if exist "%%T\MQL5" (
    set /a N+=1
    set "T!N!=%%T"
  )
)

if !N!==0 (
  echo [ERROR] No MT5 data folder found under %TERM_ROOT%
  echo Start MT5 once, or check File ^> Open Data Folder in MT5.
  endlocal & exit /b 1
)

if !N!==1 (
  set "SEL=!T1!"
  goto :check
)

echo Found !N! MT5 data folders:
for /l %%i in (1,1,!N!) do (
  set "ORIGIN=(unknown install path)"
  if exist "!T%%i!\origin.txt" for /f "usebackq delims=" %%o in (`type "!T%%i!\origin.txt"`) do set "ORIGIN=%%o"
  echo   [%%i] !ORIGIN!
  echo       !T%%i!
)
set /p "PICK=Enter number: "
if not defined T%PICK% (
  echo [ERROR] Invalid number
  endlocal & exit /b 1
)
set "SEL=!T%PICK%!"
for %%X in ("!SEL!") do (>"%SAVED%" echo %%~nxX)
echo Saved. Next time this MT5 is used automatically.

:check
if not exist "%SEL%\MQL5" (
  echo [ERROR] MT5 data folder not found: %SEL%
  endlocal & exit /b 1
)
echo MT5 data folder: %SEL%
endlocal & set "MT5_DATA=%SEL%"
exit /b 0
