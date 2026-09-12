#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
vegas_backtest_optimizer.py
============================
Offline parameter optimizer for the Vegas dual-tunnel + Hull-MA filter +
volume-gated dual-path entry system used by ExcelMonitor_All_12商品版.mq5.

WHY THIS EXISTS
---------------
The EA already auto-loads per (Symbol, Timeframe) optimal parameters from:
  - VegasFilterParams.csv    (long tunnel A/B, short tunnel A/B, filter period)
  - VegasDualPathParams.csv  (volume threshold, volume avg bars, slope lookback)
This script IS the thing that produces those two CSVs, by grid-searching
candidate parameter combinations against real historical price data and
picking whichever set has the best win rate / lowest drawdown per
(Symbol, Timeframe).

It also writes a full leaderboard (every combination tested, not just the
winner) to VegasBacktestSummary.csv, so nothing is thrown away — that file
is the "resultaat databank" you can commit to GitHub and revisit later.

DATA SOURCE
-----------
This script does NOT talk to MT5 directly (this environment has no MT5
connection). It reads the CSV files your "Gordon FTMO Data Console"
workbook already produces via the GDH_ExportCSV button:
    D:\\資料查詢\\ExportCSV\\{SYMBOL}_{TF}_ALL_DATA_{timestamp}.csv
with columns: 日期,開,高,低,收,成交量 (Date,Open,High,Low,Close,Volume).

Run GDH_ExportCSV once per symbol (12 times, one per row in the console's
symbol dropdown) — it already exports M5/M15/H1/H4/D1 in one click, so
after 12 clicks you have every (Symbol,TF) combo this script needs.

HOW TO RUN (on the Windows machine that has the exported CSVs)
----------------------------------------------------------------
    pip install pandas numpy
    python vegas_backtest_optimizer.py --data-dir "D:\\資料查詢\\ExportCSV" --out-dir "D:\\資料查詢\\VegasOptResults"

Then copy the two winner CSVs into MT5's *Common* files folder (the EA
reads them with FILE_COMMON):
    %APPDATA%\\MetaQuotes\\Terminal\\Common\\Files\\VegasFilterParams.csv
    %APPDATA%\\MetaQuotes\\Terminal\\Common\\Files\\VegasDualPathParams.csv

METHODOLOGY NOTES (read before trusting the numbers)
-----------------------------------------------------
- EMA/HMA math is ported line-by-line from the EA's CalcEMA()/CalcHMA()
  (SMA-seeded EMA, Hull MA via WMA(2*WMA(n/2)-WMA(n), sqrt(n))) so the
  signal timing should match the live EA closely. It has NOT been
  cross-checked against live MT5 tick-for-tick output from this sandbox
  (no MT5 access here) — spot check a handful of signals against the
  chart's arrows/objects once you have real data.
- Two exit styles are both evaluated per the plan you approved:
    "atr"    : fixed SL = ATR*ATRMultiplier, TP = 2x that distance (1:2),
               matches the EA's own SL/TP math.
    "signal" : hold until the opposite-direction Path A/B signal appears
               (pure signal-in/signal-out, no fixed SL/TP).
  Both get a win rate and a max drawdown (drawdown computed on the R-multiple
  equity curve for "atr", and on a per-trade % return equity curve for
  "signal" since there's no fixed R there).
- Spread/commission/slippage are NOT modeled. Treat results as a relative
  ranking tool for picking parameters, not a promise of live performance.
- The grids below are intentionally modest (a few hundred combos per
  Symbol×TF) to keep total runtime reasonable across 12 symbols x 5
  timeframes. Widen GRID_* below if you want a finer search once the
  pipeline is proven out.
"""

import argparse
import glob
import itertools
import math
import os
import sys
from dataclasses import dataclass, field
from typing import Optional

import numpy as np
import pandas as pd

SYMBOLS = ["EURUSD", "GBPUSD", "USDJPY", "USDCAD", "AUDUSD", "NZDUSD", "USDCHF",
           "US30.cash", "US500.cash", "US100.cash", "USDCNH", "JP225.cash"]

# M5 加進來了：跟EA的PeriodToTFString()新增支援對齊，5個TF全部都會被優化。
TIMEFRAMES = ["M5", "M15", "H1", "H4", "D1"]

# ---- 搜參範圍(可自行調整；範圍越大跑越久) ----
GRID_LONG_A = [100, 144, 169, 200]
GRID_LONG_B = [144, 169, 200, 233]
GRID_SHORT_A = [21, 34, 55]
GRID_SHORT_B = [55, 89, 144]
GRID_FILTER = [50, 100, 150, 200]

GRID_VOL_THRESHOLD = [1.0, 1.2, 1.5]
GRID_VOL_AVG_BARS = [14, 20, 30]
GRID_SLOPE_LOOKBACK = [3, 5, 8]

ATR_PERIOD = 14
ATR_MULTIPLIER = 2.0  # 跟EA的input ATRMultiplier一致
MIN_BARS_MARGIN = 30  # 額外緩衝根數，避免EMA/HMA warmup吃掉太多可用資料


# =====================================================================
# 1. 資料讀取
# =====================================================================
def load_symbol_tf_csv(data_dir: str, symbol: str, tf: str) -> Optional[pd.DataFrame]:
    """從 Data Console 匯出的資料夾裡找 {symbol}_{tf}_ALL_DATA_*.csv，抓最新的那份。"""
    pattern = os.path.join(data_dir, f"{symbol}_{tf}_ALL_DATA_*.csv")
    matches = sorted(glob.glob(pattern))
    if not matches:
        return None
    path = matches[-1]  # 檔名帶時間戳，字典序排序=時間排序，取最後一個=最新
    try:
        df = pd.read_csv(path, encoding="utf-8-sig")
    except UnicodeDecodeError:
        df = pd.read_csv(path, encoding="big5")

    rename_map = {}
    for col in df.columns:
        c = col.strip()
        if c in ("日期", "Date", "date"):
            rename_map[col] = "date"
        elif c in ("開", "Open", "open"):
            rename_map[col] = "open"
        elif c in ("高", "High", "high"):
            rename_map[col] = "high"
        elif c in ("低", "Low", "low"):
            rename_map[col] = "low"
        elif c in ("收", "Close", "close"):
            rename_map[col] = "close"
        elif c in ("成交量", "Volume", "volume"):
            rename_map[col] = "volume"
    df = df.rename(columns=rename_map)

    required = {"date", "open", "high", "low", "close", "volume"}
    if not required.issubset(df.columns):
        print(f"  [略過] {path} 欄位不符預期: {list(df.columns)}")
        return None

    df["date"] = pd.to_datetime(df["date"])
    df = df.sort_values("date").drop_duplicates(subset="date").reset_index(drop=True)
    for c in ("open", "high", "low", "close", "volume"):
        df[c] = pd.to_numeric(df[c], errors="coerce")
    df = df.dropna(subset=["open", "high", "low", "close"]).reset_index(drop=True)
    return df


# =====================================================================
# 2. 指標計算(對齊EA的 CalcEMA / CalcHMA，皆為「時間由舊到新」的一維陣列版本)
# =====================================================================
def ema_sma_seeded(close: np.ndarray, period: int) -> np.ndarray:
    """跟mq5的CalcEMA()同一套seed方式：seed=最舊period根的簡單平均，之後往新遞迴平滑。
    回傳陣列長度跟close一樣，前period-1個是NaN(資料不足以seed)。"""
    n = len(close)
    out = np.full(n, np.nan)
    if n < period:
        return out
    alpha = 2.0 / (period + 1.0)
    seed = close[:period].mean()
    out[period - 1] = seed
    prev = seed
    for i in range(period, n):
        prev = close[i] * alpha + prev * (1 - alpha)
        out[i] = prev
    return out


def _wma_at(close: np.ndarray, period: int, idx: int) -> float:
    """權重period,period-1,...,1，idx本身權重最高，往回(idx-1,idx-2,...)遞減。"""
    lo = idx - period + 1
    if lo < 0:
        lo = 0
    window = close[lo:idx + 1]
    w = np.arange(1, len(window) + 1)  # 最舊的權重最小，最新(window末端=idx)權重最大
    return float(np.dot(window, w) / w.sum())


def hull_ma(close: np.ndarray, period: int) -> np.ndarray:
    """HMA(n) = WMA( 2*WMA(price,n/2) - WMA(price,n), sqrt(n) )，逐點計算(對齊EA的CalcHMAAt)。"""
    n = len(close)
    out = np.full(n, np.nan)
    half = max(1, round(period / 2.0))
    sqrt_p = max(1, round(math.sqrt(period)))
    min_idx = period + sqrt_p
    for idx in range(min_idx, n):
        raw_vals = []
        for j in range(sqrt_p):
            k = idx - j
            wma_half = _wma_at(close, half, k)
            wma_full = _wma_at(close, period, k)
            raw_vals.append(2.0 * wma_half - wma_full)
        w = np.arange(sqrt_p, 0, -1)  # j=0(最新)權重最大
        out[idx] = float(np.dot(raw_vals, w) / w.sum())
    return out


def atr_series(high: np.ndarray, low: np.ndarray, close: np.ndarray, period: int) -> np.ndarray:
    n = len(close)
    tr = np.zeros(n)
    tr[0] = high[0] - low[0]
    for i in range(1, n):
        tr[i] = max(high[i] - low[i], abs(high[i] - close[i - 1]), abs(low[i] - close[i - 1]))
    out = np.full(n, np.nan)
    for i in range(period, n):
        out[i] = tr[i - period + 1:i + 1].mean()
    return out


# =====================================================================
# 3. Vegas路徑A/B方向計算(對齊 ComputeVegasDirectionForTF_Ind)
#    在這裡 k 是「時間由舊到新」陣列裡的index，等同於mql5的 rates[1] 那個位置
#    (也就是「目前正在評估的、已經走完的那根K棒」)。
# =====================================================================
@dataclass
class VegasParams:
    long_a: int
    long_b: int
    short_a: int
    short_b: int
    filter_p: int
    vol_threshold: float
    vol_avg_bars: int
    slope_lookback: int


def compute_vegas_directions(df: pd.DataFrame, p: VegasParams) -> np.ndarray:
    """回傳跟df等長的方向陣列：+1多／-1空／0無訊號，每個k代表「收在k那根K棒時」的訊號。"""
    close = df["close"].to_numpy()
    volume = df["volume"].to_numpy()
    n = len(close)

    ema_la = ema_sma_seeded(close, p.long_a)
    ema_lb = ema_sma_seeded(close, p.long_b)
    ema_sa = ema_sma_seeded(close, p.short_a)
    ema_sb = ema_sma_seeded(close, p.short_b)
    ema_f = hull_ma(close, p.filter_p)

    directions = np.zeros(n, dtype=int)

    warmup = max(p.long_a, p.long_b, p.filter_p + max(1, round(math.sqrt(p.filter_p)))) + p.slope_lookback + 3
    for k in range(warmup, n - 1):  # 留最後一根給"下一根"用不到，這裡k本身就是「已收完」的那根
        if k - p.slope_lookback < 0:
            continue
        if np.isnan(ema_la[k]) or np.isnan(ema_lb[k]) or np.isnan(ema_sa[k]) or np.isnan(ema_sb[k]) or np.isnan(ema_f[k]):
            continue

        long_upper_now = max(ema_la[k], ema_lb[k])
        long_lower_now = min(ema_la[k], ema_lb[k])
        long_upper_prev = max(ema_la[k - 1], ema_lb[k - 1])
        long_lower_prev = min(ema_la[k - 1], ema_lb[k - 1])

        vb = min(p.vol_avg_bars, k)
        avg_vol = volume[k - vb:k].mean() if vb > 0 else volume[k]
        vol_ok = avg_vol > 0 and volume[k] > avg_vol * p.vol_threshold

        long_upper_old = max(ema_la[k - p.slope_lookback], ema_lb[k - p.slope_lookback])
        long_lower_old = min(ema_la[k - p.slope_lookback], ema_lb[k - p.slope_lookback])

        cross_up = (ema_f[k - 1] <= long_lower_prev) and (ema_f[k] > long_upper_now)
        cross_down = (ema_f[k - 1] >= long_upper_prev) and (ema_f[k] < long_lower_now)
        tunnel_slope_up = (long_upper_now - long_upper_old > 0) and (long_lower_now - long_lower_old > 0)
        tunnel_slope_down = (long_upper_now - long_upper_old < 0) and (long_lower_now - long_lower_old < 0)
        path_b_bull = cross_up and tunnel_slope_up and vol_ok
        path_b_bear = cross_down and tunnel_slope_down and vol_ok

        close_k = close[k]
        long_bull_est = close_k > long_upper_now
        long_bear_est = close_k < long_lower_now

        touched_short = False
        for j in range(0, 3):
            if k - j < 0:
                break
            c = close[k - j]
            su = max(ema_sa[k - j], ema_sb[k - j])
            sl = min(ema_sa[k - j], ema_sb[k - j])
            if sl <= c <= su:
                touched_short = True
                break

        bounce_up = k >= 2 and (close[k] > close[k - 1]) and (close[k - 1] <= close[k - 2])
        bounce_down = k >= 2 and (close[k] < close[k - 1]) and (close[k - 1] >= close[k - 2])
        path_a_bull = long_bull_est and touched_short and bounce_up and vol_ok
        path_a_bear = long_bear_est and touched_short and bounce_down and vol_ok

        if path_a_bull or path_b_bull:
            directions[k] = 1
        elif path_a_bear or path_b_bear:
            directions[k] = -1

    return directions


# =====================================================================
# 4. 交易模擬：兩種出場方式都算
# =====================================================================
@dataclass
class TradeStats:
    n_trades: int = 0
    n_wins: int = 0
    win_rate: float = 0.0
    max_drawdown: float = 0.0  # 正數，代表回撤幅度(R或%)
    total_return: float = 0.0

    def as_dict(self, prefix: str) -> dict:
        return {
            f"{prefix}_trades": self.n_trades,
            f"{prefix}_win_rate": round(self.win_rate, 4),
            f"{prefix}_max_dd": round(self.max_drawdown, 4),
            f"{prefix}_total_return": round(self.total_return, 4),
        }


def _drawdown_from_equity(equity: np.ndarray) -> float:
    if len(equity) == 0:
        return 0.0
    peak = np.maximum.accumulate(equity)
    dd = peak - equity
    return float(dd.max()) if len(dd) else 0.0


def simulate_atr_exit(df: pd.DataFrame, directions: np.ndarray, atr: np.ndarray) -> TradeStats:
    """固定SL/TP(1:2)版本，用R-multiple算勝率/回撤。"""
    close = df["close"].to_numpy()
    high = df["high"].to_numpy()
    low = df["low"].to_numpy()
    n = len(close)

    r_multiples = []
    for k in range(len(directions)):
        d = directions[k]
        if d == 0 or np.isnan(atr[k]) or atr[k] <= 0 or k + 1 >= n:
            continue
        entry = close[k]
        sl_dist = atr[k] * ATR_MULTIPLIER
        sl = entry - d * sl_dist
        tp = entry + d * sl_dist * 2.0

        result_r = None
        for j in range(k + 1, n):
            hit_sl = (low[j] <= sl) if d > 0 else (high[j] >= sl)
            hit_tp = (high[j] >= tp) if d > 0 else (low[j] <= tp)
            if hit_sl and hit_tp:
                result_r = -1.0  # 保守假設：同根K棒兩邊都碰到，算輸(SL優先)
                break
            elif hit_sl:
                result_r = -1.0
                break
            elif hit_tp:
                result_r = 2.0
                break
        if result_r is not None:
            r_multiples.append(result_r)

    stats = TradeStats()
    if not r_multiples:
        return stats
    arr = np.array(r_multiples)
    stats.n_trades = len(arr)
    stats.n_wins = int((arr > 0).sum())
    stats.win_rate = stats.n_wins / stats.n_trades
    stats.total_return = float(arr.sum())
    equity = np.cumsum(arr)
    stats.max_drawdown = _drawdown_from_equity(equity)
    return stats


def simulate_signal_exit(df: pd.DataFrame, directions: np.ndarray) -> TradeStats:
    """訊號反轉出場版本：進場後持有到下一個反方向訊號(或資料結束)，用%報酬算勝率/回撤。"""
    close = df["close"].to_numpy()
    n = len(close)

    signal_idx = [k for k in range(n) if directions[k] != 0]
    returns = []
    for pos, k in enumerate(signal_idx):
        d = directions[k]
        entry = close[k]
        exit_k = None
        for k2 in signal_idx[pos + 1:]:
            if directions[k2] == -d:
                exit_k = k2
                break
        if exit_k is None:
            continue  # 到資料結尾都沒反轉訊號，這筆是「還開著的倉位」，不計入
        exit_price = close[exit_k]
        ret_pct = d * (exit_price - entry) / entry * 100.0
        returns.append(ret_pct)

    stats = TradeStats()
    if not returns:
        return stats
    arr = np.array(returns)
    stats.n_trades = len(arr)
    stats.n_wins = int((arr > 0).sum())
    stats.win_rate = stats.n_wins / stats.n_trades
    stats.total_return = float(arr.sum())
    equity = np.cumsum(arr)
    stats.max_drawdown = _drawdown_from_equity(equity)
    return stats


# =====================================================================
# 5. 主搜尋流程
# =====================================================================
def score_combo(atr_stats: TradeStats, sig_stats: TradeStats, min_trades: int = 15) -> float:
    """挑選「贏家」用的綜合分數：勝率高、回撤低者優先；交易筆數太少的組合直接淘汰(統計上不可靠)。"""
    if atr_stats.n_trades < min_trades and sig_stats.n_trades < min_trades:
        return -999.0
    scores = []
    for st in (atr_stats, sig_stats):
        if st.n_trades >= min_trades:
            dd_penalty = st.max_drawdown / (abs(st.total_return) + 1e-9) if st.total_return != 0 else 1.0
            scores.append(st.win_rate - 0.15 * min(dd_penalty, 3.0))
    return max(scores) if scores else -999.0


def optimize_symbol_tf(df: pd.DataFrame, symbol: str, tf: str) -> pd.DataFrame:
    """對單一(Symbol,TF)跑完整網格搜尋，回傳一份DataFrame(每個組合一列)。"""
    high = df["high"].to_numpy()
    low = df["low"].to_numpy()
    close = df["close"].to_numpy()
    atr = atr_series(high, low, close, ATR_PERIOD)

    rows = []
    tunnel_combos = [
        (la, lb, sa, sb, f)
        for la in GRID_LONG_A for lb in GRID_LONG_B
        for sa in GRID_SHORT_A for sb in GRID_SHORT_B
        for f in GRID_FILTER
        if lb > la and sb > sa
    ]

    for (la, lb, sa, sb, f) in tunnel_combos:
        for vt in GRID_VOL_THRESHOLD:
            for vb in GRID_VOL_AVG_BARS:
                for sl in GRID_SLOPE_LOOKBACK:
                    params = VegasParams(la, lb, sa, sb, f, vt, vb, sl)
                    if len(df) < max(la, lb, f) + MIN_BARS_MARGIN:
                        continue
                    directions = compute_vegas_directions(df, params)
                    if not np.any(directions):
                        continue
                    atr_stats = simulate_atr_exit(df, directions, atr)
                    sig_stats = simulate_signal_exit(df, directions)
                    combo_score = score_combo(atr_stats, sig_stats)
                    row = {
                        "Symbol": symbol, "TF": tf,
                        "LongTunnelA": la, "LongTunnelB": lb,
                        "ShortTunnelA": sa, "ShortTunnelB": sb,
                        "FilterPeriod": f,
                        "VolThreshold": vt, "VolAvgBars": vb, "SlopeLookback": sl,
                        "score": round(combo_score, 4),
                    }
                    row.update(atr_stats.as_dict("atr"))
                    row.update(sig_stats.as_dict("sig"))
                    rows.append(row)

    if not rows:
        return pd.DataFrame()
    return pd.DataFrame(rows).sort_values("score", ascending=False).reset_index(drop=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--data-dir", required=True, help="Data Console匯出CSV的資料夾，例如 D:\\資料查詢\\ExportCSV")
    ap.add_argument("--out-dir", required=True, help="結果輸出資料夾")
    ap.add_argument("--symbols", default=",".join(SYMBOLS), help="逗號分隔的商品清單，預設12個商品全跑")
    ap.add_argument("--timeframes", default=",".join(TIMEFRAMES), help="逗號分隔的週期清單，預設M5,M15,H1,H4,D1全跑")
    args = ap.parse_args()

    os.makedirs(args.out_dir, exist_ok=True)
    symbols = [s.strip() for s in args.symbols.split(",") if s.strip()]
    timeframes = [t.strip() for t in args.timeframes.split(",") if t.strip()]

    all_results = []
    winners_filter = []
    winners_dualpath = []

    for symbol in symbols:
        for tf in timeframes:
            print(f"=== {symbol} {tf} ===")
            df = load_symbol_tf_csv(args.data_dir, symbol, tf)
            if df is None or len(df) < 300:
                print(f"  跳過：找不到資料或資料筆數太少(需要至少300根，目前{0 if df is None else len(df)}根)")
                continue

            result_df = optimize_symbol_tf(df, symbol, tf)
            if result_df.empty:
                print("  跳過：所有參數組合都湊不到足夠的交易筆數")
                continue

            all_results.append(result_df)
            best = result_df.iloc[0]
            print(f"  最佳組合 score={best['score']:.3f}  "
                  f"ATR版勝率={best['atr_win_rate']:.1%}(n={best['atr_trades']})  "
                  f"訊號版勝率={best['sig_win_rate']:.1%}(n={best['sig_trades']})")

            winners_filter.append({
                "Symbol": symbol, "TF": tf,
                "LongTunnelA": int(best["LongTunnelA"]), "LongTunnelB": int(best["LongTunnelB"]),
                "ShortTunnelA": int(best["ShortTunnelA"]), "ShortTunnelB": int(best["ShortTunnelB"]),
                "FilterPeriod": int(best["FilterPeriod"]),
            })
            winners_dualpath.append({
                "Symbol": symbol, "TF": tf,
                "VolThreshold": best["VolThreshold"],
                "VolAvgBars": int(best["VolAvgBars"]),
                "SlopeLookback": int(best["SlopeLookback"]),
            })

    if not all_results:
        print("沒有任何(Symbol,TF)成功跑出結果，請確認 --data-dir 底下真的有 Data Console 匯出的CSV。")
        sys.exit(1)

    summary_path = os.path.join(args.out_dir, "VegasBacktestSummary.csv")
    pd.concat(all_results, ignore_index=True).to_csv(summary_path, index=False, encoding="utf-8-sig")
    print(f"\n完整回測資料庫(每個組合都在裡面) -> {summary_path}")

    filter_path = os.path.join(args.out_dir, "VegasFilterParams.csv")
    pd.DataFrame(winners_filter).to_csv(filter_path, index=False, encoding="utf-8-sig")
    print(f"贏家參數(通道+過濾線) -> {filter_path}")

    dualpath_path = os.path.join(args.out_dir, "VegasDualPathParams.csv")
    pd.DataFrame(winners_dualpath).to_csv(dualpath_path, index=False, encoding="utf-8-sig")
    print(f"贏家參數(雙路徑訊號)  -> {dualpath_path}")

    print("\n下一步：把 VegasFilterParams.csv 跟 VegasDualPathParams.csv 複製到\n"
          "  %APPDATA%\\MetaQuotes\\Terminal\\Common\\Files\\\n"
          "EA下次啟動時會自動讀取套用。VegasBacktestSummary.csv 建議直接commit進GitHub保存。")


if __name__ == "__main__":
    main()
