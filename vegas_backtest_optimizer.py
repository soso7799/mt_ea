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
import time
from dataclasses import dataclass, field
from typing import Optional

import numpy as np
import pandas as pd

SYMBOLS = ["EURUSD", "GBPUSD", "USDJPY", "USDCAD", "AUDUSD", "NZDUSD", "USDCHF",
           "US30.cash", "US500.cash", "US100.cash", "USDCNH", "JP225.cash"]

# M5 加進來了：跟EA的PeriodToTFString()新增支援對齊，5個TF全部都會被優化。
TIMEFRAMES = ["M5", "M15", "H1", "H4", "D1"]

# ---- 搜參範圍(可自行調整；範圍越大跑越久) ----
# 注意：這是純Python逐K棒迴圈(不是向量化計算)，組合數 x 資料根數 直接等於運算量。
# 預設值搭配下面的 DEFAULT_MAX_BARS，每個(商品,週期)大約幾分鐘內跑完；
# 想要更精細的搜尋，先確認能接受等待時間變長，再放寬這幾個GRID。
GRID_LONG_A = [100, 144, 169, 200]
GRID_LONG_B = [144, 169, 200, 233]
GRID_SHORT_A = [21, 34, 55]
GRID_SHORT_B = [55, 89, 144]
GRID_FILTER = [50, 100, 150]

GRID_VOL_THRESHOLD = [1.0, 1.2, 1.5]
GRID_VOL_AVG_BARS = [14, 20]
GRID_SLOPE_LOOKBACK = [3, 8]

ATR_PERIOD = 14
ATR_MULTIPLIER = 2.0  # 跟EA的input ATRMultiplier一致
MIN_BARS_MARGIN = 30  # 額外緩衝根數，避免EMA/HMA warmup吃掉太多可用資料

# 每個(商品,週期)最多用最近多少根K棒來優化(值太大在M5/M15這種細週期上會慢到不可行，
# 因為這是逐K棒的Python迴圈，運算量=組合數x根數；較舊的資料對「現在該用哪組參數」
# 參考價值本來也比較低)。可用 --max-bars 覆蓋。
DEFAULT_MAX_BARS = 15000


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
    df = _trim_before_large_gap(df, symbol, tf)
    return df


def _trim_before_large_gap(df: pd.DataFrame, symbol: str, tf: str, max_gap_days: float = 30.0) -> pd.DataFrame:
    """有些商品(常見於指數/CFD代碼中途換過)的歷史資料中間會有一段長達數月甚至數年的
    真空期，不是假日休市那種正常缺口。EMA/ATR是按K棒index而非實際經過時間計算，
    這種大洞不會讓程式出錯，但洞口銜接處會產生一根價格瞬間跳動的離譜K棒，污染ATR/
    Vegas通道的判斷。這裡自動抓出最大缺口，超過max_gap_days天就只保留缺口之後的
    資料(較新的資料本來也比較有參考價值)。"""
    if len(df) < 2:
        return df
    gaps = df["date"].diff()
    max_gap = gaps.max()
    if pd.isna(max_gap) or max_gap.total_seconds() / 86400.0 <= max_gap_days:
        return df
    cut_idx = int(gaps.idxmax())
    print(f"  [{symbol} {tf}] 偵測到 {max_gap.days} 天的異常缺口"
          f"({df['date'].iloc[cut_idx-1]} -> {df['date'].iloc[cut_idx]})，"
          f"只保留缺口之後的 {len(df) - cut_idx} 根資料。")
    return df.iloc[cut_idx:].reset_index(drop=True)


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


def precompute_indicator_cache(close: np.ndarray, volume: np.ndarray):
    """把每個會用到的EMA週期、Hull MA週期、成交量均量根數，各自只算一次，存進dict。
    這是效能的關鍵：原本每個(la,lb,sa,sb,f,vt,vb,sl)組合都會重算一次EMA/HullMA，
    但Hull MA本身是O(n*sqrt(period)*period)的巢狀迴圈，重算幾千次會慢到不可行；
    這裡改成只算「所有GRID裡出現過的獨立週期值」各一次，後面每個組合直接查表。"""
    ema_periods = set(GRID_LONG_A) | set(GRID_LONG_B) | set(GRID_SHORT_A) | set(GRID_SHORT_B)
    ema_cache = {p: ema_sma_seeded(close, p) for p in ema_periods}

    hma_cache = {p: hull_ma(close, p) for p in set(GRID_FILTER)}

    n = len(volume)
    cumvol = np.concatenate(([0.0], np.cumsum(volume.astype(float))))
    vol_avg_cache = {}
    for vb in set(GRID_VOL_AVG_BARS):
        avg = np.full(n, np.nan)
        for k in range(vb, n):
            avg[k] = (cumvol[k] - cumvol[k - vb]) / vb
        vol_avg_cache[vb] = avg

    return ema_cache, hma_cache, vol_avg_cache


def compute_vegas_directions(close: np.ndarray, volume: np.ndarray, p: VegasParams,
                              ema_cache: dict, hma_cache: dict, vol_avg_cache: dict) -> np.ndarray:
    """回傳跟close等長的方向陣列：+1多／-1空／0無訊號，每個k代表「收在k那根K棒時」的訊號。
    EMA/HullMA/成交量均量都是從預先算好的cache查表，這個函式本身只做逐K棒的訊號判斷。"""
    n = len(close)

    ema_la = ema_cache[p.long_a]
    ema_lb = ema_cache[p.long_b]
    ema_sa = ema_cache[p.short_a]
    ema_sb = ema_cache[p.short_b]
    ema_f = hma_cache[p.filter_p]
    vol_avg = vol_avg_cache[p.vol_avg_bars]

    directions = np.zeros(n, dtype=int)

    warmup = max(p.long_a, p.long_b, p.filter_p + max(1, round(math.sqrt(p.filter_p))),
                 p.vol_avg_bars) + p.slope_lookback + 3
    for k in range(warmup, n - 1):  # 留最後一根給"下一根"用不到，這裡k本身就是「已收完」的那根
        if k - p.slope_lookback < 0:
            continue
        if np.isnan(ema_la[k]) or np.isnan(ema_lb[k]) or np.isnan(ema_sa[k]) or np.isnan(ema_sb[k]) or np.isnan(ema_f[k]):
            continue

        long_upper_now = max(ema_la[k], ema_lb[k])
        long_lower_now = min(ema_la[k], ema_lb[k])
        long_upper_prev = max(ema_la[k - 1], ema_lb[k - 1])
        long_lower_prev = min(ema_la[k - 1], ema_lb[k - 1])

        avg_vol = vol_avg[k]
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


def optimize_symbol_tf(df: pd.DataFrame, symbol: str, tf: str, mode: str = "greedy") -> pd.DataFrame:
    """入口：mode="greedy"(預設，重點式，快)或"full"(全網格窮舉，慢但更完整)。"""
    if mode == "full":
        return optimize_symbol_tf_full(df, symbol, tf)
    return optimize_symbol_tf_greedy(df, symbol, tf)


# 重點式搜尋固定用的經典起始值(跟EA本身的input預設值一致)
DEFAULT_LONG_A, DEFAULT_LONG_B = 144, 169
DEFAULT_SHORT_A, DEFAULT_SHORT_B = 34, 55
DEFAULT_FILTER = 100
DEFAULT_VOL_THRESHOLD, DEFAULT_VOL_AVG_BARS, DEFAULT_SLOPE_LOOKBACK = 1.2, 20, 5


def optimize_symbol_tf_greedy(df: pd.DataFrame, symbol: str, tf: str) -> pd.DataFrame:
    """重點式(座標下降)搜尋：其他參數先固定在經典預設值，一次只調一組維度
    (長隧道→短隧道→過濾線→成交量濾網)，每步驟結束後只保留該步驟裡分數最高的值，
    帶著往下一步繼續。組合數從全網格的近2000組降到約30~40組，速度快非常多，
    代價是不保證找到全域最佳解(座標下降法的固有限制)，但對於「先有一組堪用的
    參數」這個目的來說已經足夠，且仍然把每一步測試過的組合都記進summary，
    想要更完整的搜尋可以之後對特定商品週期改用 --mode full。"""
    high = df["high"].to_numpy()
    low = df["low"].to_numpy()
    close = df["close"].to_numpy()
    volume = df["volume"].to_numpy()
    atr = atr_series(high, low, close, ATR_PERIOD)

    print(f"  {symbol} {tf}: 預先計算EMA/HullMA/成交量均量(每個週期只算一次)...")
    precompute_start = time.time()
    ema_cache, hma_cache, vol_avg_cache = precompute_indicator_cache(close, volume)
    print(f"  {symbol} {tf}: 預先計算完成，花了{time.time()-precompute_start:.1f}秒")

    rows = []

    def eval_combo(la, lb, sa, sb, f, vt, vb, sl):
        if len(df) < max(la, lb, f) + MIN_BARS_MARGIN:
            return None
        p = VegasParams(la, lb, sa, sb, f, vt, vb, sl)
        directions = compute_vegas_directions(close, volume, p, ema_cache, hma_cache, vol_avg_cache)
        if not np.any(directions):
            return None
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
        return combo_score

    best = {
        "la": DEFAULT_LONG_A, "lb": DEFAULT_LONG_B,
        "sa": DEFAULT_SHORT_A, "sb": DEFAULT_SHORT_B,
        "f": DEFAULT_FILTER,
        "vt": DEFAULT_VOL_THRESHOLD, "vb": DEFAULT_VOL_AVG_BARS, "sl": DEFAULT_SLOPE_LOOKBACK,
    }
    best_score = -999.0
    start_time = time.time()

    # 第1步：長隧道(其餘固定在經典值)
    for la in GRID_LONG_A:
        for lb in GRID_LONG_B:
            if lb <= la:
                continue
            s = eval_combo(la, lb, best["sa"], best["sb"], best["f"], best["vt"], best["vb"], best["sl"])
            if s is not None and s > best_score:
                best_score, best["la"], best["lb"] = s, la, lb

    # 第2步：短隧道(用第1步選出的長隧道)
    for sa in GRID_SHORT_A:
        for sb in GRID_SHORT_B:
            if sb <= sa:
                continue
            s = eval_combo(best["la"], best["lb"], sa, sb, best["f"], best["vt"], best["vb"], best["sl"])
            if s is not None and s > best_score:
                best_score, best["sa"], best["sb"] = s, sa, sb

    # 第3步：過濾線(用前兩步選出的長短隧道)
    for f in GRID_FILTER:
        s = eval_combo(best["la"], best["lb"], best["sa"], best["sb"], f, best["vt"], best["vb"], best["sl"])
        if s is not None and s > best_score:
            best_score, best["f"] = s, f

    # 第4步：成交量濾網(用前三步選出的通道+過濾線)
    for vt in GRID_VOL_THRESHOLD:
        for vb in GRID_VOL_AVG_BARS:
            for sl in GRID_SLOPE_LOOKBACK:
                s = eval_combo(best["la"], best["lb"], best["sa"], best["sb"], best["f"], vt, vb, sl)
                if s is not None and s > best_score:
                    best_score, best["vt"], best["vb"], best["sl"] = s, vt, vb, sl

    print(f"  {symbol} {tf}: 重點式搜尋完成，共測試{len(rows)}組，花費{time.time()-start_time:.1f}秒")

    if not rows:
        return pd.DataFrame()
    return pd.DataFrame(rows).sort_values("score", ascending=False).reset_index(drop=True)


def optimize_symbol_tf_full(df: pd.DataFrame, symbol: str, tf: str) -> pd.DataFrame:
    """對單一(Symbol,TF)跑完整網格搜尋，回傳一份DataFrame(每個組合一列)。"""
    high = df["high"].to_numpy()
    low = df["low"].to_numpy()
    close = df["close"].to_numpy()
    volume = df["volume"].to_numpy()
    atr = atr_series(high, low, close, ATR_PERIOD)

    print(f"  {symbol} {tf}: 預先計算EMA/HullMA/成交量均量(每個週期只算一次)...")
    precompute_start = time.time()
    ema_cache, hma_cache, vol_avg_cache = precompute_indicator_cache(close, volume)
    print(f"  {symbol} {tf}: 預先計算完成，花了{time.time()-precompute_start:.1f}秒")

    rows = []
    tunnel_combos = [
        (la, lb, sa, sb, f)
        for la in GRID_LONG_A for lb in GRID_LONG_B
        for sa in GRID_SHORT_A for sb in GRID_SHORT_B
        for f in GRID_FILTER
        if lb > la and sb > sa
    ]

    total_combos = len(tunnel_combos) * len(GRID_VOL_THRESHOLD) * len(GRID_VOL_AVG_BARS) * len(GRID_SLOPE_LOOKBACK)
    print(f"  {symbol} {tf}: {len(df)}根K棒 x {total_combos}組參數組合，開始搜尋...")
    start_time = time.time()
    done = 0
    last_report = start_time

    for (la, lb, sa, sb, f) in tunnel_combos:
        for vt in GRID_VOL_THRESHOLD:
            for vb in GRID_VOL_AVG_BARS:
                for sl in GRID_SLOPE_LOOKBACK:
                    done += 1
                    now = time.time()
                    if now - last_report >= 15:  # 每15秒回報一次進度，避免看起來像當機
                        elapsed = now - start_time
                        rate = done / elapsed if elapsed > 0 else 0
                        remaining = (total_combos - done) / rate if rate > 0 else float("nan")
                        print(f"    進度 {done}/{total_combos} "
                              f"({done/total_combos:.0%})，已耗時{elapsed/60:.1f}分鐘，"
                              f"預估剩餘{remaining/60:.1f}分鐘")
                        last_report = now

                    params = VegasParams(la, lb, sa, sb, f, vt, vb, sl)
                    if len(df) < max(la, lb, f) + MIN_BARS_MARGIN:
                        continue
                    directions = compute_vegas_directions(close, volume, params, ema_cache, hma_cache, vol_avg_cache)
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

    print(f"  {symbol} {tf}: 搜尋完成，共花費{(time.time()-start_time)/60:.1f}分鐘")

    if not rows:
        return pd.DataFrame()
    return pd.DataFrame(rows).sort_values("score", ascending=False).reset_index(drop=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--data-dir", required=True, help="Data Console匯出CSV的資料夾，例如 D:\\資料查詢\\ExportCSV")
    ap.add_argument("--out-dir", required=True, help="結果輸出資料夾")
    ap.add_argument("--symbols", default=",".join(SYMBOLS), help="逗號分隔的商品清單，預設12個商品全跑")
    ap.add_argument("--timeframes", default=",".join(TIMEFRAMES), help="逗號分隔的週期清單，預設M5,M15,H1,H4,D1全跑")
    ap.add_argument("--max-bars", type=int, default=DEFAULT_MAX_BARS,
                     help=f"每個(商品,週期)最多用最近幾根K棒來優化，預設{DEFAULT_MAX_BARS}"
                          "(這是逐K棒Python迴圈，值越大跑越久；0表示不限制，用全部資料)")
    ap.add_argument("--mode", choices=["greedy", "full"], default="greedy",
                     help="greedy(預設)：重點式座標下降搜尋，每個商品週期約30~40組合，"
                          "幾秒到幾十秒就能跑完，但不保證全域最佳。"
                          "full：全網格窮舉(近2000組合)，更完整但慢很多，"
                          "適合先用greedy篩出方向後，針對少數幾個商品週期精修")
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

            if args.max_bars > 0 and len(df) > args.max_bars:
                print(f"  資料共{len(df)}根，只取最近{args.max_bars}根來優化(用 --max-bars 調整)")
                df = df.iloc[-args.max_bars:].reset_index(drop=True)

            result_df = optimize_symbol_tf(df, symbol, tf, mode=args.mode)
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
