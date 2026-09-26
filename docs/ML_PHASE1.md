# ML 第 1 階段：收集訓練資料

目標：讓 EA 把**每一個信號**（不只是有下單的）當下的特徵記下來，
再往後追蹤「先到 TP 還是先到 SL」，標好結果寫成 CSV，作為第 2 階段訓練模型的資料。

這個階段**只記錄，不改變任何下單邏輯**。

## 檔案位置

| 位置 | 說明 |
|------|------|
| `%APPDATA%\MetaQuotes\Terminal\Common\Files\mt_ea_ml\` | EA 寫出的位置（所有 MT5 共用的 Common 資料夾，回測也寫得到） |
| `H:\ml\features\` | 上面那個資料夾經由 `setup_drives.bat` 連結過來，實際存在這裡 |

檔名：
- 回測：`features_tester_<回測起始日期時間>.csv`（同一段期間重跑會覆蓋舊檔）
- 實盤：`features_live_<帳號>_<開始時間>.csv`

## 操作步驟

1. 部署：執行 `scripts\deploy.bat`（會一併複製 `MLRecorder.mqh`），MetaEditor 按 F7 編譯。
2. 重新以系統管理員執行一次 `scripts\setup_drives.bat <MT5資料夾ID>`，建立 `mt_ea_ml` 連結
   （已存在的 `trade_logs` 連結會自動略過）。
3. 開啟策略測試器（Ctrl+R）：

   | 設定 | 值 |
   |------|----|
   | 專家 | MultiCurrency_EA |
   | 商品 | 7 個交易商品任一個（例如 EURUSD） |
   | 週期 | M12 |
   | 日期 | 自訂，建議至少 3 年，例如 2021.01.01 – 2025.12.31 |
   | 模式 | 「1 分鐘 OHLC」（速度快，且結果判斷本來就用 M1） |
   | 最佳化 | 停用 |

4. 「輸入」分頁：`Inp_MLRecord = true`，其他參數保持實盤要用的值。
5. 開始回測。結束後 `H:\ml\features\` 會出現 CSV。
   第一次回測 MT5 會下載 7 個商品的歷史資料，會比較久。

## CSV 欄位

| 欄位 | 說明 |
|------|------|
| `signal_time, symbol, dir` | 信號時間（伺服器時間）、商品、方向（1 買 / -1 賣） |
| `entry, sl, tp` | 假設進場價與 FilterLib 規則的 SL/TP |
| `spread_pips` | 當下點差 |
| `score, buy_score, sell_score` | 加權分數 |
| `s_ema … s_stoch` | 5 個指標各自的方向（1/0/-1），就是策略實際用的判斷 |
| `atr_pips` | M12 ATR(14) |
| `ema_gap, ema_slope, close_ema` | EMA 快慢線差、快線斜率、收盤與快線距離（÷ATR） |
| `rsi, rsi_chg` | RSI 值與變化 |
| `bb_pos, bb_width, bb_width_chg` | 價格在布林通道的位置（0=中軌，±0.5=上下軌）、寬度÷ATR、寬度變化比 |
| `macd, macd_hist, macd_hist_chg` | MACD 主線、柱狀體、柱狀體變化（÷ATR） |
| `stoch_k, stoch_d` | 隨機指標 |
| `hour, dow` | 伺服器時間的小時、星期幾（0=週日） |
| `has_pos, vol_ok` | 當時該商品是否已有持倉、ATR 波動是否正常 |
| **`label`** | **1=先到 TP，0=先到 SL，2=逾時，-1=回測結束時仍未有結果** |
| `outcome_time, bars_held` | 結果發生時間、經過幾根 M1 |
| `mfe_r, mae_r` | 最大有利 / 不利幅度，以「SL 距離」為 1R |

所有數值特徵都用**最近一根已收盤的 K 線**，不會偷看未來。

## 標記方式的限制

- 用 M1 K 線判斷：同一根 M1 同時碰到 SL 和 TP 時無法分先後，**保守記為 SL**。
- 不含追蹤停損與反向信號主動平倉，所以 label 代表「固定 SL/TP 的結果」，
  和實際成交紀錄會有差異。這是刻意的：模型要學的是信號品質本身。
- 同一商品連續幾根 K 線都出現同向信號時，每根都會記一筆，彼此高度相關；
  第 2 階段驗證時會依時間切分處理。

## 交給第 2 階段

回測完成後，告訴我 CSV 的筆數和 `label` 的分佈
（Excel 打開後對 `label` 欄做篩選即可），或直接把檔案傳給我。
