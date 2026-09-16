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
  兩兩配對算避險相關性。

## 怎麼跑

```bash
pip install -r requirements.txt
```

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

這兩支都要連 MT5，只能在有安裝 MT5 終端機、已登入帳號的 Windows 電腦上執行。

## 【還沒解決、需要你確認的地方】

1. `D:\資料查詢\` 這個路徑、`Gordon_FTMO_Data_Console_多選多週期版.xlsm`、
   `作戰計畫_v5最終版.xlsm`、`ExcelMonitor_All.mq5` 這些 Excel/mq5 檔案我沒有拉進這個
   repo(都是二進位檔，不適合放程式碼倉庫)，你雲端硬碟「資料查詢/備份檔/
   最終正確版_FinalPackage/」裡都有，需要的話直接從那邊拿。
2. 你原本問的「Data/關卡」12商品×5週期、`AnalysisResults.csv`/`LevelsResults.csv`那套
   系統，目前確認完全沒有對應程式碼存在——如果你還是想要那一套（跟這裡的「作戰計畫」系統
   是分開的兩個東西），需要另外從頭設計，不是修復。
