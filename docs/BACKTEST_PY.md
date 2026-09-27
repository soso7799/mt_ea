# Python 回測

用 Python 逐分鐘模擬 MultiCurrency_EA，**一次跑出「舊邏輯 A」與「修正後 B」的比較**，
並同時產生 ML 訓練資料。比 MT5 策略測試器快很多（3 年約數分鐘）。

## 事前準備（只需一次）

1. 安裝 Python 3.10 以上，安裝時勾選「Add python.exe to PATH」。
2. 在 FTMO 的 MT5：「工具 → 選項 → 圖表 → 圖表中最大K線數」設為 **無限制**，按確定後重開 MT5
   （否則只抓得到最近幾個月的 M1）。
3. 保持 FTMO 的 MT5 開啟並已登入。

## 執行

```
G:\我的雲端硬碟\src\mt_ea\scripts\backtest_py.bat --deposit 10000
```

- 期間預設為**從今天往前 3 年**（用最新的資料）。`--years 5` 改成 5 年；
  也可以用 `--from 2024-01-01 --to 2024-12-31` 指定。

- `--deposit`：**請填你的帳戶資金**。EA 的淨值下限寫死 9600（為 1 萬美元帳戶設計），
  資金不同結果差很多。
- 第一次會從 MT5 下載 7 個商品的 M1（每個約 100 萬根，需幾分鐘），存到
  `H:\我的雲端硬碟\export\bars\`，之後直接讀快取。加 `--refresh` 重新下載。

其他參數：

| 參數 | 預設 | 說明 |
|------|------|------|
| `--mode` | both | `both` / `fixed`（只跑修正後）/ `legacy`（只跑舊邏輯） |
| `--commission` | 5 | 每手來回手續費（USD） |
| `--local-tz` | Asia/Taipei | 你電腦的時區，EA 的強平 / 禁止交易時段 / 每日重置都用本機時間 |
| `--server-ny-offset` | 7 | 伺服器時間 = 紐約時間 + 7 小時（FTMO） |
| `--equity-floor` | EA 的 9600 | 覆寫淨值下限；填 `0` 停用 |
| `--day-loss` | EA 的 -350 | 覆寫單日虧損上限，例如 `-5000` |

> **用 1 萬美元回測時，淨值跌破 9600 後 EA 會每天鎖住、不再交易**，
> 報告的「最後一筆」會停在很早的日期。要看策略在整段期間的表現，加
> `--equity-floor 0 --day-loss -100000`；要看實際 EA 風控下的結果，則用你帳戶的真實資金、不加這兩個參數。

### 找出哪個機制在虧錢

```
backtest_py.bat --ablation --equity-floor 0 --day-loss -100000
```

用修正後邏輯一次跑 5 種組合（原樣 / 無反向平倉 / 無追蹤停損 / 兩者皆無 / 只有固定 SL/TP），
最後印出比較表。也可以單獨用 `--no-reverse`、`--no-trailing`、`--no-force`。
這些只影響 Python 模擬，EA 本身不變。

報告另外列出 **FTMO 檢查**：相對初始資金的最大虧損（限 10%）與單日最大虧損（限 5%）。

## 輸出

| 檔案 | 位置 |
|------|------|
| `report.txt`：A / B 的淨利、獲利因子、最大回撤、交易次數、勝率、平倉原因、各商品損益 | `H:\我的雲端硬碟\tester_reports\py_<期間>_<時間>\` |
| `trades_legacy.csv`、`trades_fixed.csv`：每筆交易 | 同上 |
| `equity_*.csv`：淨值曲線（每小時） | 同上 |
| `features_py_<期間>.csv`：ML 訓練資料（B 的信號） | `H:\我的雲端硬碟\ml\features\` |

之後直接執行 `train_ml.bat` 就會用這份資料訓練。
**同一資料夾不要同時放 MT5 測試器產生的 `features_tester_*.csv` 和 Python 的 `features_py_*.csv`**，
兩者是同一批信號，請擇一。

## 模擬了什麼

參數全部直接從 `MultiCurrency_EA.mq5` / `FilterLib_v5.mqh` 讀取（改 EA 參數不用改 Python）：

- 7 商品的 5 指標信號與加權分數、MinConfirm、每根 K 線只開一單、MaxPos、同商品只持一單
- FilterLib：SL/TP/手數、ATR 波動過濾與波動平倉、追蹤停損（擺動點 + 階梯鎖利）、
  H1 反向信號平倉、每商品每日 SL 次數上限、單日虧損上限、淨值下限、禁止交易時段、每日重置與強平
- 指標依 MT5 內建公式（EMA、RSI Wilder、BB 母體標準差、MACD 訊號線 SMA、Stochastic SMA、ATR SMA）

## 與 MT5 測試器的差異

- 每分鐘開盤執行一次 EA 邏輯（MT5 是每個 tick）；SL/TP 用該分鐘高低點判斷，同時碰到算 SL。
- 波動過濾用「前一根 M1 的真實波幅」近似 `iATR(M1,1)`。
- 不含隔夜利息。

結果應與 MT5 測試器方向一致、數值接近，**正式上線前仍以 MT5 測試器為準**。

## 模擬時發現的 EA 行為（原本就存在）

1. **「05:50 強平」實際在每天 07:15（本機時間）執行。**
   每日重置在 07:15 把 `forceClosedToday` 設回 false，接著 `CheckForceClose` 判斷
   「現在 ≥ 05:50」立刻成立而全部平倉；到了隔天 05:50 旗標仍是 true，所以不會再平。
2. **淨值下限 9600 是為 1 萬美元帳戶寫死的**：資金 1 萬時虧 4% 就每天鎖死不再交易；
   資金 10 萬時則永遠不會觸發。
3. **EURUSD 不在 FilterLib 的 `SYMBOLS` 清單**，所以 EURUSD 的持倉不會被 H1 反向信號平倉
   （其他 6 個會）。
4. 單日損益用 `HistorySelect(本機時間, TimeLocal())` 查詢，但成交紀錄是伺服器時間，
   兩者差 5–6 小時，「當日」的範圍會偏移。

以上 Python 版都照 EA 實際行為模擬，沒有修正；要不要修由你決定。
