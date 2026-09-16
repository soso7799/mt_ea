# Gordon FTMO 分析系統（從 Google Drive 還原的真實版本）

這個資料夾放的是你 Google 雲端硬碟「資料查詢」裡**真正存在、真正在跑**的分析腳本，
不是憑空編的。過程紀錄如下，方便你核對。

## 這兩支腳本是怎麼來的

最早那個 `Gordon_FTMO_監控儀表板.xlsm`（Data/監控/策略規則/儀表板/關卡 分頁，配
`gordon_analysis_engine_v1.py`/`gordon_levels_module_v1.py`、輸出到
`D:\historical_data\`）——**這兩支 py 在你雲端硬碟裡完全找不到，從來沒被寫出來過**，
所以 VBA 巨集才會一直報「找不到檔案」。這不是你搞丟了，是它們本來就不存在。

用 Google Drive 搜尋後，找到你真正在用、有實際輸出資料(2026-09-12)的另一套系統，
說明寫在「資料查詢/備份檔/最終正確版_FinalPackage/00_README_請先看這個.txt」：

- 主檔案：`作戰計畫_v5最終版.xlsm`
- 抓報價：`ExcelMonitor_All.mq5`(MT5指標，背景每5秒寫CSV) + `gordon_mt5_incremental.py`
- 分析引擎：`gordon_full_analysis.py`
- 全部放在 `D:\資料查詢\` 底下，不是 `D:\historical_data\`

## gordon_full_analysis.py 的還原細節

你的「策略」備份資料夾裡這支腳本其實有兩份：一份 27883 bytes(12:15存)，一份
`gordon_full_analysis..py`(檔名多一點) 31678 bytes(同一天22:19存，更晚、更完整，
多了「支撐壓力+趨勢+成交量」三層合成訊號、跟 `ExcelMonitor_All.mq5` 的 M5 邏輯呼應)。
這裡採用的是**比較完整的那份**。

**商品清單擴充**：備份檔裡這支腳本的 `SYMBOLS` 只寫了8個
(EURUSD/GBPUSD/USDJPY/USDCAD/AUDUSD/NZDUSD/USDCHF/XAUUSD)，但同一個資料夾裡真實的
輸出結果 `AllSymbols_DashboardParams.csv` / `AllSymbols_OptimizedParams.txt` 明明白白
算出了 `US500.cash`/`US30.cash`/`US100.cash`/`JP225.cash` 這4個指數商品的結果——代表
實際在跑的版本是12個商品，備份的原始碼落後於實際使用版本。這裡依照那份真實輸出資料，
把 `SYMBOLS` 補齊成這12個，**邏輯完全沒動，只補了清單**。

已用假資料驗證跑得通：`MultiTF_Signals.csv` 輸出12列、`AllSymbols_DashboardParams.csv`
輸出48列(12商品×4週期)，格式跟你雲端硬碟裡真實的舊輸出檔案一致。

## 這是什麼

- `gordon_mt5_incremental.py` — 由 Excel Console 端傳入 `--symbol --timeframe --amount
  --unit --output` 等參數呼叫，直連 MT5 抓歷史資料，輸出成中文表頭(日期,開,高,低,收,
  成交量)的CSV。這支是原封不動照抄，沒有改動。
- `gordon_full_analysis.py` — 讀 `D:\資料查詢\ExportCSV\` 裡每個商品/週期最新的CSV，跑
  11指標網格回測找最佳參數、算ATR動態SL/TP、M15/H1多空共振+三層合成最終訊號、8→12商品
  兩兩配對算避險相關性。`TIMEFRAMES` 是 D1/H4/H1/M15/M5 共5個週期(`compute_final_signal()`
  的註解本來就寫「跟 ExcelMonitor_All.mq5 M5 那邊同一套邏輯」，這裡把 M5 補進清單，
  跟備份檔案裡原本只有4個週期的版本不同)。
- `gordon_analysis_engine_v1.py` — 給 `Gordon_FTMO_監控儀表板.xlsm`「Data」分頁用。直連
  MT5 抓12商品×5週期報價，呼叫 `gordon_full_analysis.py` 裡驗證過的指標函式
  (ATR/RSI/MACD/三層合成訊號)算出32欄。不是另外發明的邏輯，是把
  `gordon_full_analysis.py` 的真實計算結果換一種格式輸出。
- `gordon_levels_module_v1.py` — 給「關卡」分頁用。支撐/壓力公式跟
  `gordon_full_analysis.py` 的 `compute_final_signal()` 內部用的完全一樣(近期20根K棒
  高低、觸碰次數判斷有效性)，只是把中間值攤開成28欄輸出，而不是像原本那樣只回傳合成後
  的最終訊號。
- `RunDashboardUpdate.py` — 上面兩支的「一鍵執行」入口，見下方【怎麼跑】。

已用模擬報價資料驗證跑得通：`AnalysisResults.csv` 60列×32欄、`LevelsResults.csv` 60列×
28欄(12商品×5週期，跟「說明」分頁原本描述的一致)。輸出路徑跟你原本 VBA 巨集
`RefreshAllData` 的 `csvFolder = "D:\historical_data\"` 一致，不用改巨集。

## 怎麼跑

這個資料夾其實對應你**兩套獨立的系統**，各自有各自的執行順序，不要混著跑。

```bash
pip install -r requirements.txt
```

### A. `Gordon_FTMO_監控儀表板.xlsm`(Data/監控/策略規則/儀表板/關卡)

1. 打開 MT5 終端機，確認已登入你的 FTMO 帳號，圖表能正常跳動報價。
2. 執行 `python RunDashboardUpdate.py`。這支會一次連線 MT5、抓完12商品×5週期的報價，
   同時算出並寫入 `D:\historical_data\AnalysisResults.csv` 跟
   `D:\historical_data\LevelsResults.csv`，跑完才斷線一次——不要分開跑
   `gordon_analysis_engine_v1.py`/`gordon_levels_module_v1.py` 兩支，那樣會變成連續
   斷線重連兩次、報價也重複抓兩次。
3. 回到 `Gordon_FTMO_監控儀表板.xlsm`，按「RefreshAllData」巨集，兩個CSV就會一次匯入
   Data / 關卡 兩個分頁。

【MT5會不會被關掉】跑完 `RunDashboardUpdate.py`，MT5 終端機應用程式本身不會被關閉——
`mt5.shutdown()` 只是斷開 Python 跟終端機之間的資料連線，跟你手動關閉終端機視窗是
兩回事，終端機、你開的圖表/其他EA都不受影響，可以放心重複執行這支腳本。

### B. `作戰計畫_v5最終版.xlsm`(另一套獨立系統，跟A無關)

1. 用 `Gordon_FTMO_Data_Console_多選多週期版.xlsm` 的「市場清單」勾選商品/週期，跑
   `GDH_BatchExportSelected` 巨集，批次匯出歷史CSV到 `D:\資料查詢\ExportCSV\`
   (內部會呼叫 `gordon_mt5_incremental.py` 逐筆抓)。
2. 執行 `python gordon_full_analysis.py`，讀 ExportCSV 裡的資料做分析，輸出：
   - `AllSymbols_OptimizedParams.txt`
   - `MultiTF_Signals.csv`
   - `HedgePairs.csv`
   - `AllSymbols_DashboardParams.csv`
3. 打開 `量化分析儀表板_全新版.xlsx`(第一次要另存成.xlsm並匯入RefreshDashboard巨集)，
   按「更新儀表板」看結果。

以上兩套系統的所有腳本都要連 MT5，只能在有安裝 MT5 終端機、已登入帳號的 Windows 電腦上
執行。

## 【還沒解決、需要你確認的地方】

1. `D:\資料查詢\` 這個路徑、`Gordon_FTMO_Data_Console_多選多週期版.xlsm`、
   `作戰計畫_v5最終版.xlsm`、`ExcelMonitor_All.mq5` 這些 Excel/mq5 檔案我沒有拉進這個
   repo(都是二進位檔，不適合放程式碼倉庫)，你雲端硬碟「資料查詢/備份檔/
   最終正確版_FinalPackage/」裡都有，需要的話直接從那邊拿。
2. Data(32欄)/關卡(28欄) 的欄名是我設計的(你先前答覆「沒有現成標題」)，如果你的 Excel
   分頁裡已經有自己手動打好的表頭，兩邊對不上的話，巨集會把資料貼到錯的欄位底下——把你
   Excel 裡實際的表頭貼給我，我可以照著調整 `COLUMNS` 順序。
