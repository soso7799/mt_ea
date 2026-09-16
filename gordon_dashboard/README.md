# Gordon FTMO 監控 - 分析引擎（從零重新開發版）

這個資料夾是重新開發的 `gordon_analysis_engine_v1.py` / `gordon_levels_module_v1.py`，
取代找不到的原始檔案。因為原始檔案內容沒有拿到，這是全新寫的一版，**不是修復舊檔案**，
欄位設計跟判斷邏輯都是我依照你 Excel「說明」分頁截圖裡的描述重新設計的假設，不一定跟你
原本用的版本一致，需要你先核對。

## 這是什麼

- `gordon_analysis_engine_v1.py` → 產生 `AnalysisResults.csv`（12商品 x 5週期 = 60列，32欄），給 Excel「Data」分頁用。
- `gordon_levels_module_v1.py` → 產生 `LevelsResults.csv`（12商品 x 5週期 = 60列，28欄），給 Excel「關卡」分頁用。
- `gordon_common.py` → 兩支共用的設定（商品清單、週期、輸出路徑）跟工具函式（連線 MT5、算指標）。

兩支都連 MT5 抓報價，**只能在有安裝 MT5 終端機、且已登入帳號的 Windows 電腦上執行**。這次
開發是在 Linux 容器裡做的，沒有 MT5 可以連，所以是用假資料模擬測試邏輯跑得通、欄位數量對
（60列/32欄、60列/28欄），並沒有實際對過你券商的真實報價，第一次在你電腦上跑完，數字要自
己抽查合理性。

## 怎麼跑

```bash
pip install -r requirements.txt
python gordon_analysis_engine_v1.py
python gordon_levels_module_v1.py
```

跑完後 CSV 預設會存到 `D:\historical_data\`（跟你原本 VBA 巨集 `RefreshAllData` 裡的
`csvFolder` 一致），接著在 Excel 按巨集就能匯入。

## 【需要你確認/可能要調整的地方】

1. **商品清單（12個）**：`gordon_common.py` 裡的 `SYMBOLS`，我用你提過的三組避險關係
   （AUDUSD/NZDUSD、US500/US30、EURUSD/USDCHF）回推補齊到12個，不一定是你實際交易的商品，
   要改直接改這個 list。**商品代碼也要注意**：有些券商代碼會加後綴（例如 `EURUSD.m`、
   `US500.cash`），要改成你 MT5 報價視窗裡實際看到的代碼，不然會出現「找不到商品代碼」的錯誤。
2. **週期（5個）**：目前是 M15/H1/H4/D1/W1。
3. **Data 分頁32欄、關卡分頁28欄的欄名跟順序**：完全是我自己設計的（各檔案開頭都有清楚列
   出欄位跟判斷邏輯的註解），跟你原本可能用的欄位不一定一致，要改欄位要去 `COLUMNS` list
   跟對應的 `analyze_one()` 函式一起改。
4. **訊號/SL/TP判斷邏輯**：目前用「收盤價 vs MA50 判趨勢、RSI14 篩訊號、ATR14 x 1.5/3 算
   SL/TP」，這只是一個能動的起始版本，跟你原本「Gordon策略」的實際規則八成不一樣，判斷邏輯
   在 `gordon_analysis_engine_v1.py` 的 `analyze_one()` 裡，改倍數或條件都在那個函式。
5. **關卡0.3%提醒、成交量突破倍數(1.5x)**：在 `gordon_levels_module_v1.py` 開頭的
   `KEY_LEVEL_ALERT_PCT`、`VOLUME_BREAKOUT_MULT` 常數，可直接調。
6. **點值(策略規則分頁用的每商品每手美元值)**：這兩支腳本沒有輸出這欄，維持你原本 Excel
   設計 — 這欄要你自己在「策略規則」分頁手動填，因為每個券商合約規格不同，程式沒辦法幫你
   確定。

## 跟舊版巨集的關係

`RefreshAllData` VBA 巨集本身不用改，它只是把 CSV 讀進 Excel，跟 CSV 內容從哪支程式產生
無關。之前巨集報「找不到檔案」，只要這兩支腳本先成功在 `D:\historical_data\` 產生
`AnalysisResults.csv` / `LevelsResults.csv`，巨集就能正常匯入。
