# 12期教學範例EA — 修正優化 + 機器學習版

來源：Google 雲端硬碟 `12期教學範例EA`（第一期 ~ 第十二期 + 額外贈送 2 支）。
每支 EA **保留原本的交易邏輯**，修正程式錯誤與效能問題，並加上一個共用的**機器學習訊號過濾器**。

> 所有 EA 皆為教學範例，不保證未來獲利。任何參數請自行回測研究後再使用。

## 資料夾結構

```
12期教學範例EA/
├─ MQL5/Experts/BeeQuant12/   ← 【安裝用】14 支 EA，每支都是「單一檔案」(已內嵌函式庫)
├─ src/                       ← 【原始碼】要修改程式時改這裡
│  └─ Experts/
│      ├─ 01_Friday_ML.mq5 …  EA 本體
│      └─ BeeQuant/           共用函式庫 (取代 cash.mqh / cash_v2.mqh)
│          ├─ BQ_Trade.mqh        下單/平倉/改單/手數計算
│          ├─ BQ_Indicators.mqh   指標 handle 快取、新K棒判斷、每日計數器
│          ├─ BQ_ML.mqh           機器學習過濾器 (線上邏輯斯迴歸)
│          └─ BQ_MLInputs.mqh     各 EA 共用的 ML 參數
├─ tools/build_single.py      ← 改完 src/ 後執行，重新產生單檔 EA
└─ ml/train_logit.py          ← (選用) 離線訓練模型
```

## 安裝

1. MT5 →「檔案」→「開啟資料資料夾」→ 進入 `MQL5\Experts\`。
2. 把 `MQL5/Experts/BeeQuant12/` 裡想用的 `.mq5` 複製過去（放在 `Experts` 底下任何資料夾都可以）。
   每支 EA 都是獨立單檔，**不需要**另外複製任何 `.mqh`。
3. MetaEditor 打開 EA，按 F7 編譯。
4. 這版不再需要 `cash.mqh`、`cash_v2.mqh`；`function_MT5.mq5` 只是函式範例集，功能已由 `BQ_Trade.mqh` 取代。

檔案都是 UTF-8 (含 BOM)，中文註解在 MetaEditor 可正常顯示。

## EA 對照表

| 檔案 | 原始檔 | 原開發商品/週期 | 策略類型 |
|---|---|---|---|
| 01_Friday_ML | Tester-Friday v1.0 | EURUSD、EURGBP、EURCHF、AUDUSD / D1 | 週末反轉 |
| 02_MarketReview_ML | MarketReview(非交易EA) | 任意 | 12 種進場 x 3 種出場探測器 |
| 03_Secret_ML | Tester-Secret v6.0 Input + Live-Secret v7.0 | v7 表內 36 組 | 日區間突破 + MACD |
| 04_BBFF_ML | Tester-BBFF v2.02 | — | 夜盤布林逆勢 |
| 05_Kris_ML | Tester-Kris v1.0 | — | 雙均線回檔 |
| 06_iCOOL_ML | Tester-iCOOL v1.0 | 全商品 (iCOOL全商品.xml) | 大週期布林 + 小週期回檔 |
| 07_Lucy_ML | Tester-Lucy | EURJPY / H1 | 波動收斂區間 |
| 08_Spaghetti_ML | Tester-Spaghetti(三關價) | H1 | 三關價突破 |
| 09_Wellington_ML | Tester-Wellington 威靈頓 | GBPJPY / H1 | 三均線回檔突破 |
| 10_WeekBullBearPower_ML | Tester-WeekBullBearPower 周天成 | GBPJPY / D1 | 週/日 多空力道 |
| 11_Jimmy_ML | Tester-Jimmy | GBPJPY / H1 | 均線 + RSI |
| 12_Ultimate_ML | Tester-Ultimate | GBPCAD、GBPNZD、GBPJPY / M15 | 假突破反轉 |
| X1_Trendline_ML | Trendline EA MT5 | 手動畫線 | 趨勢線突破/反彈 |
| X2_FiveMinMomentum_ML | 五分鐘動量交易系統 | — | 均線 + MACD 動量 |

MagicNumber 規則沿用原版（空單 = 多單 + 77；Jimmy 空單 +1；BBFF 多空共用），升級後仍能接手原本 EA 開的單。

## 所有 EA 共同修正

| 問題 | 影響 | 修正 |
|---|---|---|
| `cash.mqh` 每次 `cc.iATR()` / `cc.iMA()` 都建立新的指標 handle，從不釋放 | 記憶體持續增加、回測變慢；新 handle 常常還沒算好就取值，拿到 `EMPTY_VALUE` 仍拿去計算 | handle 快取 (`BQ_Indicators.mqh`)，取值失敗就跳過這個 tick |
| 每個 tick 複製 100000 根 OHLC (Friday、Jimmy) | 回測非常慢 | 只取需要的值 |
| 每個 tick 重建 10~20 個文字物件 | CPU 浪費、圖表閃爍 | 改用 `Comment` 面板，回測不繪製 |
| `OrderSend` 只檢查 bool，沒檢查 `retcode` | 被拒單也當成功，計數錯亂 | 統一透過 `CTrade` 並檢查 retcode，遇到重新報價自動重試 |
| 沒設定成交模式 (filling) | 部分券商直接拒單 | `SetTypeFillingBySymbol` |
| 手數只 `NormalizeDouble(x,2)`，上限寫死 0.3 | 手數不合券商步進被拒單 | 對齊交易量步進/最小/最大，上限改為參數 |
| 風險手數公式假設 tick size = point | 貴金屬、指數的手數算錯 | 用 tick size / tick value 計算 |
| 停損停利沒檢查券商最小距離 | 被拒單 | 自動推到最小距離 |
| 移動停損改單時沒帶原本的 TP | TP 被清掉 | 改單保留 TP |
| 每日次數要在「6:00~6:05 有報價」才歸零 | 該時段沒報價就不歸零 | 以交易日切換歸零 |
| 分批平倉 `volume/2` 沒對齊步進 | 0.01 手的單出錯 | 對齊步進，不足最小手數則只移保本 |

每支 EA 的個別修正寫在各自檔案開頭的註解裡。比較重要的有：

- **Spaghetti**：原版關價只在 16:00 那根K棒計算，EA 在 16:00 之後才啟動時關價是 0，一啟動就亂下單。
- **MarketReview**：Case 1、6、7、8、9 的方向或掛單種類寫反（依原檔內附的 TradeStation 規格修正）；`BuyMarket` 少大括號，永遠回傳 false。
- **Secret**：「進場價到停損價距離」同時掃描多空單，只回傳最後一張，保本判斷會混用。v6/v7 合併成一支，用 `InpParamMode` 切換。
- **Lucy**：空單的追蹤停損用 `CopyHigh` 取「最低點」（複製錯陣列）。
- **Jimmy**：追蹤停利的「觸發點數」是跟停損價比較，觸發條件幾乎一定成立。已改為「最大浮盈 >= 觸發點數」才啟動；`InpLegacyTrail=true` 可切回原版行為。
- **FiveMinMomentum**：平半後移保本時找的是 magic 5555/5556（不存在的單），保本從未生效。
- **Trendline**：每日下單次數從不歸零，跑幾天之後就再也不下單。
- **BBFF**：用「最後一次送單類型」判斷目前持倉方向，平倉後判斷就錯了。

## 機器學習過濾器

### 原理

```
原策略產生訊號 ──► 計算 12 個特徵 ──► 模型估計「先到停利」機率 p
                                          │
                   p ≥ 兩平勝率 + 優勢門檻？ ─ 是 ─► 照常下單
                                          └ 否 ─► 不下單
每個訊號 (不論是否下單) 都建立「虛擬單」追蹤 → 先到停利=1 / 先到停損=0 → 立刻更新模型
```

- **模型**：線上邏輯斯迴歸（含線上標準化），純 MQL5 實作，不需要 Python、DLL 或 ONNX。
- **特徵**（全部取已收盤的 K 棒，沒有未來函數；有方向性的特徵都乘上多空方向）：
  RSI(14)、收盤與 EMA20 距離、EMA20 與 EMA50 距離、EMA20 斜率、ATR14/ATR100 波動狀態、點差/ATR、時段 (sin/cos)、上一根K棒實體、20 根區間位置、ADX(14)、方向。
- **標籤**：從訊號當下的價格起算，先碰到 EA 自己的停利還是停損。EA 沒有停利時，預設用 2 倍 ATR；逾時則看損益正負。
- **門檻**：用「損益兩平勝率 + 優勢」判斷。停利是停損 3 倍的策略，兩平勝率只要 25%，所以不同盈虧比的 EA 可以共用同一個門檻設定。
- **避免選擇偏誤**：被擋掉的訊號也會追蹤、也會學習，模型不會只看到自己放行的單。
- **暖機**：前 `InpMLMinSamples` 個訊號只學習、不過濾。

### 參數（每支 EA 都有）

| 參數 | 預設 | 說明 |
|---|---|---|
| InpMLMode | 學習並過濾 | 關閉 = 完全等同原策略；只學習 = 收集資料不擋單 |
| InpMLThreshold | 0.03 | 預估勝率需高於兩平勝率多少才放行 |
| InpMLMinSamples | 40 | 暖機樣本數 |
| InpMLBarrierTP / SL | 0 | 標記用停利/停損的 ATR 倍數，0 = 用 EA 自己的停利/停損 |
| InpMLMaxBars | 48 | 虛擬單最長追蹤 K 棒數 |
| InpMLLoadModel / SaveModel | true | 模型存在 `Common\Files\BeeQuantML\` |
| InpMLExportCSV | false | 匯出訓練資料，給 `ml/train_logit.py` 用 |
| InpMLScaleLots | false | 依預估優勢把手數調整為 0.5~1.5 倍 |
| InpMLTimeframe | 目前週期 | 特徵計算週期 |

### 建議使用流程（樣本內 / 樣本外）

1. **基準**：`InpMLMode = 關閉`，回測一次，記下原策略的績效。
2. **訓練**：`InpMLMode = 只學習`，回測前段期間（例如 2015~2020）。結束時模型會存檔。
3. **驗證**：`InpMLMode = 學習並過濾`、`InpMLLoadModel = true`，回測後段期間（例如 2021~今天），跟第 1 步同期間的結果比較。
4. 日誌最後會印出「放行單勝率 vs 擋掉單勝率」與各特徵權重。放行單勝率明顯比較高，過濾才有效。
5. 最佳化時不會寫入模型檔（多個 agent 會互相覆蓋），請用單次回測來訓練。

### 離線訓練（選用）

1. 在 MT5 策略測試器回測 EA，參數設 `InpMLMode = 只學習`、`InpMLExportCSV = true`。
   回測結束後，訓練資料會出現在 `%APPDATA%\MetaQuotes\Terminal\Common\Files\BeeQuantML\`。
2. 執行（不用加任何參數）：

```bash
pip install numpy
python ml/train_logit.py
```

程式會自動找出該資料夾裡所有 CSV，每個檔案依時間切分：前 70% 訓練、後 30% 驗證，印出 AUC 與過濾前後的勝率、期望值 (R)。
接著在同一個資料夾輸出同名的 `.model` 檔（例如 `Friday_EURUSD_H1_1234.model`），EA 下次啟動 (`InpMLLoadModel = true`) 就會自動載入，並繼續線上學習。

也可以指定檔案：`python ml/train_logit.py 檔案.csv --out 模型.model`

### 注意

- 教學 EA 的訊號數通常不多（一年幾十到幾百筆）。樣本太少時 ML 幫不上忙，這時請把 `InpMLMode` 設成「只學習」來觀察，或乾脆關閉。
- ML 是**過濾器**，只會減少交易，不會讓一個沒有優勢的策略變賺錢。請一定要做樣本外驗證。
- 回測建議使用「每個 tick」或「1 分鐘 OHLC」模式，虛擬單的停利/停損判斷才會準確。
