# MultiCurrency_EA（FTMO 版）

8 個外匯商品多指標 EA：掛在**任何一張圖表**即可，交易商品與週期由參數決定。
**預設為「只統計」模式，不會下單**（`Inp_TradeEnabled = false`）。

## 安裝

1. MT5 →「檔案」→「開啟資料資料夾」→ 進入 `MQL5\Experts\`，建立資料夾 `MultiCurrency`。
2. 把 `MultiCurrency_EA.mq5` 和全部 7 個 `.mqh` 放進 **同一個** `MQL5\Experts\MultiCurrency\`：
   `FilterLib_v5.mqh`、`CandlePatterns.mqh`、`BQ_ML.mqh`、`BQ_Indicators.mqh`、`MarketRegime.mqh`、`NewsFilter.mqh`、`SymbolGroups.mqh`
   （EA 用引號 `#include "..."` 從自己的資料夾讀取，**不需要**放到 `MQL5\Include`；Include 裡舊的 FilterLib 不會被用到）
3. MetaEditor 開啟 `MultiCurrency_EA.mq5`，按 **F7** 編譯。
4. 掛到任一圖表。啟動日誌會印出模式、風控金額、排程對照（冬令/夏令）與可交易商品數。

## 流程

```
每根 M12 K棒，8 個商品各自：
  5 指標加權計分 (EMA/RSI/BB/MACD/KD)
  → K線型態濾網（翻多16招/翻空18招）
  → ML 過濾（線上邏輯斯迴歸，虛擬單學習）
  → 每小時行情判定過濾（多頭/空頭/盤整 + 斐波納契）
  → 新聞時段 / 週末 檢查
  → 分數最高的商品 → FilterLib 風控 → 下單（只統計模式只寫日誌）
```

## 主要參數

| 群組 | 參數 | 預設 | 說明 |
|---|---|---|---|
| Basic | `Inp_TradeEnabled` | **false** | false = 只統計，不開倉/平倉/改單 |
| | `Inp_TF` | M12 | 策略週期（進場、追蹤停損、反向平倉、型態、ML 共用） |
| FTMO 風控 | `Inp_AccountSize` | 10000 | 帳戶初始資金 |
| | `Inp_DailyLossPct` | 3.5 | 每日虧損上限 %（FTMO 5%） |
| | `Inp_MaxLossPct` | 4.0 | 總虧損上限 %（FTMO 10%） |
| K線型態 | `Inp_CP_Mode` | 擋單 | 關閉 / 反向型態擋單 / 必須同向 / 計分 |
| ML | `Inp_ML_Mode` | 學習並過濾 | 前 40 個訊號只學習 |
| 行情判定 | `Inp_MR_Mode` | 只收集 | 順勢 / 順勢+避開斐波壓力支撐 |
| | `Inp_MR_StopMode` | fx_rules | 改為「斐波」則用斐波止損止盈下單 |
| 排程 | `Inp_ScheduleOffset` | 6 | 排程時間 = 伺服器 + 6h（冬令台灣時間，冬夏令自動跟隨） |
| | `Inp_ForceCloseHour/Min` | 05:45 | 每日強平（排程時間） |
| 新聞 | `Inp_News_Enable` | true | 高影響新聞前後 5 分鐘不開倉、不主動平倉 |
| 週末 | `Inp_Fri_Enable` | true | 週五 20:00 停止開倉、22:30 平倉（伺服器時間） |

## 商品

USDJPY、AUDUSD、USDCAD、GBPUSD、EURUSD、USDCHF、NZDUSD、USDCNH。
券商後綴（如 `USDJPY.m`）自動對應；找不到的商品略過。
⚠️ USDCNH 的指標參數沿用 EURUSD、`fx_rules` 止損止盈為估計值，需回測校準；EURUSD 的 `fx_rules` 亦為估計值。

## 輸出資料（`%APPDATA%\MetaQuotes\Terminal\Common\Files\`）

| 檔案 | 內容 |
|---|---|
| `MarketRegime\MultiCurrency_<magic>_<tester\|live>.csv` | 每小時每商品：行情、均線、MACD、RSI、斐波位、支撐壓力、多空止損止盈建議 |
| `BeeQuantML\*.model` | 各商品 ML 模型（下次啟動自動載入） |
| `BeeQuantML\*.csv` | ML 訓練資料（`Inp_ML_ExportCSV=true` 時） |

## 統計工具（`ml/`）

```bash
python ml/regime_stats.py      # 行情判定準確度、斐波止損止盈模擬、順勢 vs 逆勢（只需 Python）
pip install numpy
python ml/train_logit.py       # 離線訓練 ML 模型（選用）
```

## 建議流程

1. `Inp_TradeEnabled=false` 跑回測/模擬，確認日誌與 CSV 正常。
2. `python ml/regime_stats.py` 看統計，決定是否開啟行情過濾、斐波止損止盈。
3. 基準回測（型態、ML、行情過濾都關）→ 逐項開啟比較 → 樣本外驗證。
4. FTMO 免費試用帳戶確認排程、新聞、週五平倉後，再 `Inp_TradeEnabled=true`。

## EA_Report.mq5（帳戶內各 EA 成績統計，只讀）

放到 `MQL5\Scripts\`，編譯後拖到**要檢查的帳戶**任一圖表執行（不會交易，可在真實帳戶跑）：
依 Magic Number 統計每個 EA 的淨利、勝率、獲利因子、最大回撤、最近 30/90 天損益，
列出目前各圖表掛的 EA，並輸出 `Common\Files\EA_Report\EA_Report_<帳號>.csv`。

## TrendScanner.mq5 v2（多指標趨勢掃描 + 進出場計畫，預設不下單）

與 `MarketRegime.mqh`、`SymbolGroups.mqh` 放同一個 `MQL5\Experts\TrendScanner\`，F7 編譯，掛任一圖表。

- **評分 8 票**：均線排列、價在 MA4 上下、MA4 斜率、MACD、RSI、DMI、布林中軌、量能；H1 ≥ 6 票、H4 同向 ≥ 4、ADX ≥ 20。
- **各商品參數**：第一次執行自動產生 `Common\Files\TrendScanner\params.csv`，修改後重新掛上即生效。
- **進場**：回檔 38.2~61.8% 現價；未回檔掛 38.2% 限價（4 小時失效）；超過 61.8% 觀望。斐波止損止盈，RR ≥ 1.5。
- **手數**：每筆風險 0.15%，單筆上限 1 手。
- **移動止損**：不移動 / 保本 / 保本後 ATR 追蹤 / 保本後擺動高低點追蹤（獲利 1R 啟動）。
- **加碼**：同商品最多 3 單；最新一單獲利 ≥ 1R 才加，加之前先把既有單移到保本。
- **安全**：`InpTradeEnabled=false`（只產生計畫）、`InpAllowReal=false`（真實帳戶不下單）、`InpLockAccount` 鎖帳號。
- 輸出：`Common\Files\TrendScanner\plans_YYYYMMDD.csv`、圖表面板、手機推播。

## HistoryExporter.mq5 — 從 FTMO 匯出歷史資料（只讀，每 10 天自動更新）

1. MT5「工具 → 選項 → 圖表 → 圖表最大K棒數」設為 **Unlimited**，重啟 MT5。
2. `HistoryExporter.mq5` 與 `SymbolGroups.mqh` 放同一資料夾，F7 編譯，掛到 **FTMO 模擬帳戶** 任一圖表（只讀不交易）。
3. 週期：M1 M3 M5 M10 M12 M15 M30 H1 H4 D1 W1 MN1；M1~M30 抓 3 年、H1~MN1 抓 10 年（參數可改）。
4. 輸出 `Common\Files\FTMO_Data\<週期>\<商品>.csv`（FTMO 伺服器時間，MT5 匯入格式），總表 `SUMMARY.md / SUMMARY.csv`。
5. 第一次要從伺服器下載歷史，約數十分鐘到數小時；之後每 10 天只附加新K棒。
6. 空間：100 個商品約 12 GB（zip 約 3 GB），其中 M1 佔一半；每年增加約 4 GB。

`tools/ftmo_sync.ps1`（Windows 工作排程器每天跑）：把資料同步到雲端硬碟，並把總表推到 GitHub 的 `ftmo_data/SUMMARY.md`。
