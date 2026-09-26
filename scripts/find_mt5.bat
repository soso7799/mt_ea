@echo off
REM ============================================================
REM  自動尋找 MT5 資料夾，結果放在 MT5_DATA
REM  用法：call find_mt5.bat [資料夾ID]
REM    - 有給 ID：直接使用 %APPDATA%\MetaQuotes\Terminal\<ID>
REM    - 只找到一個：自動使用
REM    - 找到多個：列出安裝位置讓你選
REM ============================================================
setlocal EnableDelayedExpansion
set "TERM_ROOT=%APPDATA%\MetaQuotes\Terminal"
set "SEL="

if not "%~1"=="" (
  set "SEL=%TERM_ROOT%\%~1"
  goto :check
)

set /a N=0
for /d %%T in ("%TERM_ROOT%\*") do (
  if exist "%%T\MQL5" (
    set /a N+=1
    set "T!N!=%%T"
  )
)

if !N!==0 (
  echo [錯誤] %TERM_ROOT% 底下找不到任何 MT5 資料夾
  echo 請先開過一次 MT5，或在 MT5「檔案 ^> 開啟資料夾」確認位置
  endlocal & exit /b 1
)

if !N!==1 (
  set "SEL=!T1!"
  goto :check
)

echo 找到 !N! 個 MT5 資料夾：
for /l %%i in (1,1,!N!) do (
  set "ORIGIN=（未知安裝位置）"
  if exist "!T%%i!\origin.txt" for /f "usebackq delims=" %%o in (`type "!T%%i!\origin.txt"`) do set "ORIGIN=%%o"
  echo   [%%i] !ORIGIN!
  echo       !T%%i!
)
set /p "PICK=請輸入編號: "
if not defined T%PICK% (
  echo [錯誤] 編號無效
  endlocal & exit /b 1
)
set "SEL=!T%PICK%!"

:check
if not exist "%SEL%\MQL5" (
  echo [錯誤] 找不到 MT5 資料夾: %SEL%
  endlocal & exit /b 1
)
echo 使用 MT5 資料夾: %SEL%
endlocal & set "MT5_DATA=%SEL%"
exit /b 0
