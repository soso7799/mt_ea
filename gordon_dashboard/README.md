# Gordon FTMO 分析系統（從 Google Drive 還原的真實版本）

這個資料夾放的是你 Google 雲端硬碟「資料查詢」裡**真正存在、真正在跑**的分析腳本，
不是憑空編的。過程紀錄如下，方便你核對。

## 這幾支腳本是怎麼來的

最早那個 `Gordon_FTMO_監控儀表板.xlsm`（Data/監控/策略規則/儀表板/關卡 分頁，配
`gordon_analysis_engine_v1.py`/`gordon_levels_module_v1.py`、輸出到
`D:\historical_data\`）——**這兩支 py 在你雲端硬碟裡完全找不到，從來沒被寫出來過**，
所以 VBA 巨集才會一直報「找不到檔案」。這不是你搞丟了，是它們本來就不存在。

用 Google Drive 搜尋後，找到你真正在用、有實際輸出資料(2026-09-12)的另一套系統，
說明寫在「資料查詢/備份檔/最終正確版_FinalPackage/00_README_請先看這個.txt」：

- 主檔案：`作戰計畫_v5最終版.xlsm`
- 抓報價：`ExcelMonitor_All.mq5`(MT5指標，背景每5秒寫CSV) + `mt5_fetch_v2.py`
- 分析引擎：`analysis_core_v2.py`
- 全部放在 `D:\資料查詢\` 底下，不是 `D:\historical_data\`

## analysis_core_v2.py 的還原細節

你的「策略」備份資料夾裡這支腳本其實有兩份：一份 27883 bytes(12:15存)，一份
檔名多一點的 31678 bytes(同一天22:19存，更晚、更完整，多了「支撐壓力+趨勢+成交量」
三層合成訊號、跟 `ExcelMonitor_All.mq5` 的 M5 邏輯呼應)。這裡採用的是**比較完整的
那份**。

**商品清單擴充(含一次修正)**：備份檔裡這支腳本的 `SYMBOLS` 只寫了8個
(EURUSD/GBPUSD/USDJPY/USDCAD/AUDUSD/NZDUSD/USDCHF/XAUUSD)。第一次依照歷史輸出檔
補到12個時，把第12個商品誤判成 XAUUSD；後來直接對照 MT5 終端機上**真正在跑**的
`ExcelMonitor_All.mq5` 指標畫面(分頁清單)，確認正確的第12個商品是 **USDCNH**，不是
XAUUSD——已經改正。現在的12個是：EURUSD、GBPUSD、USDJPY、USDCAD、AUDUSD、NZDUSD、
USDCHF、**USDCNH**、US500.cash、US30.cash、US100.cash、JP225.cash，跟
`create_excel.py` 裡 `SYMBOLS_CONFIG` 的清單一致。

## 為什麼檔名全部改成 xxx_v2.py、為什麼不再用 CSV+VBA巨集

debug到最後，`AnalysisResults.csv`/`LevelsResults.csv` 內容經你上傳確認完全正常
(60列、正確欄位、當天的即時時間戳記)，但 Excel 那邊不管用 VBA 的 `Dir$` 還是
`Scripting.FileSystemObject.FileExists`，過一段時間後都找不到同一個檔案；把輸出
資料夾搬離 `D:\historical_data\`(這個資料夾設定了Google雲端硬碟自動同步)之後，
問題依然存在。代表「Python寫檔案、Excel事後讀檔案」這種中間層，在這台電腦的環境
下本身不可靠，不管檔案放哪裡、VBA用哪個函式檢查都一樣。

所以整套重做，做了兩件事：
1. **不再用 CSV 檔案交換**：新增 `push_to_excel_v2.py`，透過 `xlwings`(Python
   操作Excel的套件)直接把資料寫進「已經開啟的」Excel活頁簿，中間沒有檔案，這一整類
   bug直接消失。這是現在**建議使用**的方式。
2. **所有 py 檔名都換新**：避免跟你電腦上任何舊版本、或存壞的重複檔名(例如帶
   `(2)` 編號的)搞混，保證用的是新的。CSV路線的 `run_csv_export_v2.py`
   (取代原本的 `RunDashboardUpdate.py`)還留著當備用，但不是主要路徑。

VBA 的 `RefreshAllData`/`ImportCSVToSheet` 巨集**不再需要**，放著不動、也可以刪掉，
新的 `push_to_excel_v2.py` 完全不依賴它。

## 檔名對照表(舊名 → 新名)

| 舊檔名 | 新檔名 |
|---|---|
| `gordon_full_analysis.py` | `analysis_core_v2.py` |
| `gordon_mt5_incremental.py` | `mt5_fetch_v2.py` |
| `gordon_analysis_engine_v1.py` | `data_sheet_v2.py` |
| `gordon_levels_module_v1.py` | `levels_sheet_v2.py` |
| `RunDashboardUpdate.py`(CSV路線，備用) | `run_csv_export_v2.py` |
| (新增) | `push_to_excel_v2.py`(**主要用這支**) |

## 這是什麼

- `mt5_fetch_v2.py` — 由 Excel Console 端傳入 `--symbol --timeframe --amount --unit
  --output` 等參數呼叫，直連 MT5 抓歷史資料，輸出成中文表頭(日期,開,高,低,收,
  成交量)的CSV。這支是原封不動照抄，沒有改動。
- `analysis_core_v2.py` — 讀 `D:\資料查詢\ExportCSV\` 裡每個商品/週期最新的CSV，跑
  11指標網格回測找最佳參數、算ATR動態SL/TP、M15/H1多空共振+三層合成最終訊號、
  12商品兩兩配對算避險相關性。`TIMEFRAMES` 是 D1/H4/H1/M15/M5 共5個週期。
- `data_sheet_v2.py` — 給 `Gordon_FTMO_監控儀表板.xlsm`「Data」分頁用的資料計算邏輯。
  直連 MT5 抓12商品×5週期報價，呼叫 `analysis_core_v2.py` 裡驗證過的指標函式
  (ATR/RSI/MACD/三層合成訊號)算出32欄。含過期資料偵測(重試+MT5自己的時間基準，
  不會被時區誤判)。
- `levels_sheet_v2.py` — 給「關卡」分頁用的資料計算邏輯。支撐/壓力公式跟
  `analysis_core_v2.py` 的 `compute_final_signal()` 內部用的完全一樣，只是把中間值
  攤開成28欄輸出。
- `push_to_excel_v2.py` — **主要入口**。連 MT5、算出 Data(32欄)/關卡(28欄) 兩份資料，
  透過 xlwings 直接寫進「已經開啟的」`Gordon_FTMO_監控儀表板.xlsm`，不經過CSV。
- `run_csv_export_v2.py` — CSV路線的備用入口(如果 xlwings 有問題可以先用這個，輸出
  `D:\GordonExchange\AnalysisResults.csv`/`LevelsResults.csv`，還是要搭配 VBA巨集
  匯入)。

## 怎麼跑

這個資料夾其實對應你**兩套獨立的系統**，各自有各自的執行順序，不要混著跑。

```bash
pip install -r requirements.txt
```

### A. `Gordon_FTMO_監控儀表板.xlsm`(Data/監控/策略規則/儀表板/關卡)

**建議做法(不用CSV、不用巨集)：**

1. 打開 MT5 終端機，確認已登入你的 FTMO 帳號，圖表能正常跳動報價。
2. 打開 `Gordon_FTMO_監控儀表板.xlsm`(注意副檔名要是 `.xlsm`，不是
   `.xlsm.xlsx` 之類的複本檔)，**保持它開著**，不用做任何操作。也不用先手動
   改分頁名稱——程式會自動依序比對 `GDX_Data`/`Data1`/`Data`(關卡分頁對應
   `GDX_關卡`/`關卡1`/`關卡`)，三個裡面存在哪個就用哪個。
3. 執行 `python push_to_excel_v2.py`。這支會連線 MT5、抓12商品×5週期報價，算完
   直接寫進 Data / 關卡 兩個分頁，跑完就是最新的。**不用按任何巨集**。
   如果三個候選分頁名稱都對不上，程式會直接印出活頁簿裡「實際存在」的分頁
   名稱清單，把那段文字貼給我就能繼續，不用再截圖。

**備用做法(CSV路線，xlwings有問題時才用)：**

1. 打開 MT5 終端機並登入。
2. 執行 `python run_csv_export_v2.py`，輸出到 `D:\GordonExchange\`(先手動建立這個
   資料夾)。
3. 回到 Excel，VBA 裡把 `csvFolder` 改成 `"D:\GordonExchange\"`，按
   `RefreshAllData`。

【MT5會不會被關掉】跑完這些腳本，MT5 終端機應用程式本身不會被關閉——
`mt5.shutdown()` 只是斷開 Python 跟終端機之間的資料連線，跟你手動關閉終端機視窗是
兩回事，終端機、你開的圖表/其他EA都不受影響，可以放心重複執行。

### B. `作戰計畫_v5最終版.xlsm`(另一套獨立系統，跟A無關)

1. 用 `Gordon_FTMO_Data_Console_多選多週期版.xlsm` 的「市場清單」勾選商品/週期，跑
   `GDH_BatchExportSelected` 巨集，批次匯出歷史CSV到 `D:\資料查詢\ExportCSV\`
   (內部會呼叫 `mt5_fetch_v2.py` 逐筆抓)。
2. 執行 `python analysis_core_v2.py`，讀 ExportCSV 裡的資料做分析，輸出：
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
   分頁裡已經有自己手動打好的表頭，兩邊對不上的話，資料會貼到錯的欄位底下——把你
   Excel 裡實際的表頭貼給我，我可以照著調整欄位順序。
3. `push_to_excel_v2.py` 依賴 xlwings 透過 COM 操作 Excel，這段沒辦法在開發環境
   (Linux容器，沒有真正的Excel)裡實際跑過，只做了語法檢查跟模擬測試。第一次在你
   電腦上執行如果有錯誤訊息，貼給我。
