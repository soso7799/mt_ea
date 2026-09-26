@echo off
chcp 65001 >nul
REM ============================================================
REM  建立歷史資料碟 / 執行程式碟的資料夾結構，並把 MT5 沙盒連結過去
REM  請以「系統管理員」執行
REM  用法：setup_drives.bat [MT5資料夾ID]（不給會自動尋找）
REM ============================================================
setlocal

REM ---- 依你的環境修改 ----
REM 歷史資料碟
set "DATA_ROOT=H:"
REM 執行程式碟：預設為本腳本所在的 ...\src\mt_ea\scripts 往上三層
for %%I in ("%~dp0..\..\..") do set "PROG_ROOT=%%~fI"
set "LINK_BASES=0"
REM LINK_BASES=1 會把 bases 搬到網路碟（回測較慢，本機空間不足才用）

if not exist "%DATA_ROOT%\" (
  echo [錯誤] 看不到歷史資料碟 %DATA_ROOT%
  echo 以系統管理員執行時可能看不到網路磁碟代號，請把 DATA_ROOT 改成 \\伺服器\分享名稱
  exit /b 1
)

call "%~dp0find_mt5.bat" %1 || exit /b 1
echo 歷史資料碟: %DATA_ROOT%
echo 執行程式碟: %PROG_ROOT%

echo === 歷史資料碟 ===
for %%D in (bases export\bars export\ticks trade_logs tester_reports backups) do (
  if not exist "%DATA_ROOT%\%%D" mkdir "%DATA_ROOT%\%%D"
)

echo === 執行程式碟 ===
for %%D in (src releases presets scripts terminals) do (
  if not exist "%PROG_ROOT%\%%D" mkdir "%PROG_ROOT%\%%D"
)

echo === 連結 MQL5\Files\trade_logs ===
if exist "%MT5_DATA%\MQL5\Files\trade_logs" (
  echo 已存在，略過
) else (
  mklink /D "%MT5_DATA%\MQL5\Files\trade_logs" "%DATA_ROOT%\trade_logs" || exit /b 1
)

if "%LINK_BASES%"=="1" (
  echo === 搬移 bases 到網路碟 ^(請先關閉 MT5^) ===
  tasklist /FI "IMAGENAME eq terminal64.exe" | find /I "terminal64.exe" >nul && (
    echo [錯誤] MT5 仍在執行，請先關閉
    exit /b 1
  )
  robocopy "%MT5_DATA%\bases" "%DATA_ROOT%\bases" /E /MOVE /R:2 /W:5
  if errorlevel 8 exit /b 1
  if exist "%MT5_DATA%\bases" rmdir "%MT5_DATA%\bases"
  mklink /D "%MT5_DATA%\bases" "%DATA_ROOT%\bases" || exit /b 1
)

echo 完成。
endlocal
