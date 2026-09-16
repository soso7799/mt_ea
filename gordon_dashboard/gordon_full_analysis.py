# -*- coding: utf-8 -*-
"""
gordon_full_analysis.py

全新、自成一體的分析腳本，直接讀取 GDH_ExportCSV 匯出到
D:\\資料查詢\\ExportCSV\\ 的 12商品 × 多週期 歷史 CSV 檔案，完成：

 1. 每個商品、每個週期(D1/H4/H1/M15)：11大指標參數優化(比較勝率)，
    並用 ATR 動態算出建議 SL/TP。
 2. 每個商品的 M15/H1 多空共振投票(趨勢層) + 支撐壓力/成交量三層合成的
    最終訊號(M15_Final/H1_Final，跟 ExcelMonitor_All.mq5 的 M5 邏輯呼應)，
    寫成 MultiTF_Signals.csv(給「作戰計畫」巨集直接讀取合併)。
 3. 12個商品兩兩配對，用 H1 報酬率算相關係數，找出前3組
    (不分正負相關，一起比較絕對值)，並用 ATR反比算建議手數比例。

輸出檔案(都在 D:\\資料查詢\\)：
 - AllSymbols_OptimizedParams.txt 逐商品逐週期11指標優化結果+SL/TP
 - MultiTF_Signals.csv 12商品的M15/H1多空共振+最終合成訊號(給作戰計畫用)
 - HedgePairs.csv 前3組配對相關性+建議手數比例
 - AllSymbols_DashboardParams.csv 儀表板總表23欄參數

執行方式：直接 python gordon_full_analysis.py，不需要任何命令列參數，
會自動掃描 ExportCSV 資料夾裡每個商品每個週期「最新」的那一份檔案。

【SYMBOLS 清單說明】
原始備份檔裡這支腳本只寫了8個商品(EURUSD/GBPUSD/USDJPY/USDCAD/AUDUSD/
NZDUSD/USDCHF/XAUUSD)，但同一個資料夾裡實際的輸出結果
(AllSymbols_DashboardParams.csv / AllSymbols_OptimizedParams.txt)明明白白
算出了 US500.cash/US30.cash/US100.cash/JP225.cash 這4個指數商品的結果，
代表實際在跑的版本是12個商品。這裡依照那份真實輸出資料把清單補齊到12個，
其餘邏輯(指標、回測、輸出格式)完全比照原始版本，沒有更動。
"""

import os
import glob
import traceback
import numpy as np
import pandas as pd

BASE_DIR = r"D:\資料查詢"
EXPORT_DIR = BASE_DIR + r"\ExportCSV"

OUT_PARAMS_PATH = BASE_DIR + r"\AllSymbols_OptimizedParams.txt"
OUT_MULTITF_PATH = BASE_DIR + r"\MultiTF_Signals.csv"
OUT_HEDGE_PATH = BASE_DIR + r"\HedgePairs.csv"
LOG_PATH = BASE_DIR + r"\error_full_analysis.log"

SYMBOLS = [
    "EURUSD", "GBPUSD", "USDJPY", "USDCAD", "AUDUSD", "NZDUSD", "USDCHF", "XAUUSD",
    "US500.cash", "US30.cash", "US100.cash", "JP225.cash",
]
TIMEFRAMES = ["D1", "H4", "H1", "M15"]

# ---------------- 11指標參數搜尋範圍(跟optimize.py同一套，維持一致性) ----------------
MA_SHORT_GRID = [5, 8, 10, 13]
MA_LONG_GRID = [20, 30, 40, 50]
RSI_PERIOD_GRID = [7, 9, 14, 21]
RSI_BOUNDS_GRID = [(20, 80), (25, 75), (30, 70)]
KD_K_GRID = [5, 9, 14, 21]
PSY_PERIOD_GRID = [6, 10, 12, 15, 20]
WR_PERIOD_GRID = [7, 10, 14, 21]
MTM_PERIOD_GRID = [5, 10, 14, 20]
MACD_GRID = [(12, 26, 9), (8, 17, 9), (5, 35, 5), (19, 39, 9)]
BOLL_GRID = [(10, 1.5), (10, 2), (20, 1.5), (20, 2), (20, 2.5), (30, 2), (30, 2.5)]
CCI_PERIOD_GRID = [10, 14, 20]
BIAS_PERIOD_GRID = [10, 20, 30]
KELTNER_GRID = [(10, 1.5), (10, 2), (20, 1.5), (20, 2), (20, 2.5), (30, 2), (30, 2.5)]

ATR_PERIOD = 14
ATR_SL_MULT = 1.5
ATR_TP_MULT = 3.0
MAX_HOLD_BARS = 60
OPT_LOOKBACK_BARS = {"D1": 500, "H4": 800, "H1": 1200, "M15": 2000}

AUTO_CLEANUP_OLD_EXPORTS = True  # 分析完後自動刪除每個商品/週期用不到的舊匯出檔，只留最新一份


def cleanup_old_exports(symbol, tf, keep_path):
    """把 ExportCSV 資料夾裡同一個商品+週期、但不是這次採用的舊檔案刪掉，避免資料夾越堆越多。"""
    pattern = os.path.join(EXPORT_DIR, f"{symbol}_{tf}_ALL_DATA_*.csv")
    matches = glob.glob(pattern)
    if not matches:
        pattern2 = os.path.join(EXPORT_DIR, f"{symbol}_{tf}_*.csv")
        matches = glob.glob(pattern2)

    removed = []
    for m in matches:
        if os.path.abspath(m) != os.path.abspath(keep_path):
            try:
                os.remove(m)
                removed.append(os.path.basename(m))
            except Exception:
                pass  # 刪不掉(可能被其他程式開著)就跳過，不影響主流程
    return removed


# ======================================================================
# 檔案讀取：找出每個商品/週期「最新」的匯出檔案
# ======================================================================
def find_latest_file(symbol, tf):
    pattern = os.path.join(EXPORT_DIR, f"{symbol}_{tf}_ALL_DATA_*.csv")
    matches = glob.glob(pattern)
    if not matches:
        pattern2 = os.path.join(EXPORT_DIR, f"{symbol}_{tf}_*.csv")
        matches = glob.glob(pattern2)
    if not matches:
        return None
    matches.sort()
    return matches[-1]


def load_ohlc_csv(path):
    df = pd.read_csv(path, encoding="utf-8-sig")
    col_map = {}
    for c in df.columns:
        cs = str(c).strip()
        if cs in ("日期", "time", "Time", "Date"):
            col_map[c] = "time"
        elif cs in ("開", "open", "Open"):
            col_map[c] = "open"
        elif cs in ("高", "high", "High"):
            col_map[c] = "high"
        elif cs in ("低", "low", "Low"):
            col_map[c] = "low"
        elif cs in ("收", "close", "Close"):
            col_map[c] = "close"
        elif cs in ("成交量", "volume", "Volume", "tick_volume"):
            col_map[c] = "volume"
    df = df.rename(columns=col_map)
    needed = ["time", "open", "high", "low", "close"]
    for n in needed:
        if n not in df.columns:
            raise RuntimeError(f"{path} 缺少必要欄位 {n}，實際欄位：{list(df.columns)}")
    df["time"] = pd.to_datetime(df["time"], errors="coerce")
    df = df.dropna(subset=["time"])
    for c in ["open", "high", "low", "close"]:
        df[c] = pd.to_numeric(df[c], errors="coerce")
    df = df.dropna(subset=["open", "high", "low", "close"])
    if "volume" in df.columns:
        df["volume"] = pd.to_numeric(df["volume"], errors="coerce")
    df = df.sort_values("time").reset_index(drop=True)
    return df


# ======================================================================
# 指標計算(跟optimize.py同一套邏輯)
# ======================================================================
def calc_atr_series(high, low, close, period):
    prev_close = close.shift(1)
    tr = pd.concat([
        high - low,
        (high - prev_close).abs(),
        (low - prev_close).abs(),
    ], axis=1).max(axis=1)
    return tr.ewm(span=period, adjust=False).mean()


def calc_rsi(close, period):
    delta = close.diff()
    gain = delta.clip(lower=0)
    loss = -delta.clip(upper=0)
    avg_gain = gain.ewm(alpha=1 / period, min_periods=period, adjust=False).mean()
    avg_loss = loss.ewm(alpha=1 / period, min_periods=period, adjust=False).mean()
    rs = avg_gain / avg_loss.replace(0, np.nan)
    rsi = 100 - (100 / (1 + rs))
    return rsi.fillna(50)


def calc_kd(high, low, close, k_period, d_period, smooth):
    lowest_low = low.rolling(k_period).min()
    highest_high = high.rolling(k_period).max()
    rsv = (close - lowest_low) / (highest_high - lowest_low).replace(0, np.nan) * 100
    rsv = rsv.fillna(50)
    k = rsv.ewm(alpha=1 / smooth, adjust=False).mean()
    d = k.ewm(alpha=1 / d_period, adjust=False).mean()
    return k, d


def calc_psy(close, period):
    up = (close.diff() > 0).astype(int)
    return (up.rolling(period).mean() * 100).fillna(50)


def calc_williams_r(high, low, close, period):
    hh = high.rolling(period).max()
    ll = low.rolling(period).min()
    wr = (hh - close) / (hh - ll).replace(0, np.nan) * -100
    return wr.fillna(-50)


def calc_macd(close, fast, slow, signal):
    ema_fast = close.ewm(span=fast, adjust=False).mean()
    ema_slow = close.ewm(span=slow, adjust=False).mean()
    macd_line = ema_fast - ema_slow
    signal_line = macd_line.ewm(span=signal, adjust=False).mean()
    return macd_line, signal_line


def calc_bollinger(close, period, num_std):
    mid = close.rolling(period).mean()
    std = close.rolling(period).std()
    return mid, mid + num_std * std, mid - num_std * std


def calc_cci(high, low, close, period):
    tp = (high + low + close) / 3
    sma = tp.rolling(period).mean()
    mad = tp.rolling(period).apply(lambda x: np.mean(np.abs(x - x.mean())), raw=True)
    return ((tp - sma) / (0.015 * mad.replace(0, np.nan))).fillna(0)


def calc_bias(close, period):
    sma = close.rolling(period).mean()
    return ((close - sma) / sma.replace(0, np.nan) * 100).fillna(0)


def calc_keltner(high, low, close, period, mult):
    mid = close.ewm(span=period, adjust=False).mean()
    tr = pd.concat([
        high - low,
        (high - close.shift()).abs(),
        (low - close.shift()).abs(),
    ], axis=1).max(axis=1)
    atr = tr.ewm(span=period, adjust=False).mean()
    return mid, mid + mult * atr, mid - mult * atr


def vote(cond_bool):
    return 1 if bool(cond_bool) else -1


def signal_strength(value, strong_hi, mild_hi, mild_lo, strong_lo):
    """把連續數值轉成 -2/-1/1/2 的分級強度訊號(區間法，取代單純>中線的二元判斷)。"""
    if value >= strong_hi:
        return 2
    elif value >= mild_hi:
        return 1
    elif value <= strong_lo:
        return -2
    elif value <= mild_lo:
        return -1
    else:
        return 1 if value >= (mild_hi + mild_lo) / 2 else -1


def compute_signals_detailed(df):
    """
    回傳每個指標的分級訊號(-2~2)，而不是單純+1/-1。
    區間設計說明：
    RSI(0~100)：>60強多、50~60弱多、40~50弱空、<40強空
    KD(0~100)同RSI邏輯
    PSY(0~100)同RSI邏輯
    WR(-100~0)：>-30強多、-50~-30弱多、-70~-50弱空、<-70強空
    MACD：用「柱狀圖佔價格%」判斷，>0.05%強多...
    CCI：>100強多、0~100弱多、-100~0弱空、<-100強空
    BOLL/KELTNER：用「價格偏離中軌的比例」分級
    MTM/BIAS：用「變動幅度佔價格%」分級
    """
    close, high, low = df["close"], df["high"], df["low"]
    last_price = close.iloc[-1]

    ma_short = close.rolling(5).mean().iloc[-1]
    ma_long = close.rolling(20).mean().iloc[-1]
    ma_diff_pct = (ma_short - ma_long) / ma_long * 100 if ma_long else 0
    s_ma = signal_strength(ma_diff_pct, 0.15, 0, 0, -0.15)

    rsi_val = calc_rsi(close, 14).iloc[-1]
    s_rsi = signal_strength(rsi_val, 60, 50, 50, 40)

    k, d = calc_kd(high, low, close, 9, 3, 3)
    kd_diff = k.iloc[-1] - d.iloc[-1]
    k_val = k.iloc[-1]
    # KD特別處理：低檔黃金交叉(K<20且K>D)算強多；高檔死亡交叉(K>80且K<D)算強空
    if kd_diff > 0 and k_val < 20:
        s_kd = 2
    elif kd_diff > 0:
        s_kd = 1
    elif kd_diff < 0 and k_val > 80:
        s_kd = -2
    else:
        s_kd = -1

    psy_val = calc_psy(close, 12).iloc[-1]
    s_psy = signal_strength(psy_val, 60, 50, 50, 40)

    wr_val = calc_williams_r(high, low, close, 14).iloc[-1]
    s_wr = signal_strength(wr_val, -30, -50, -50, -70)

    mtm_pct = (close.diff(10).iloc[-1] / last_price * 100) if last_price else 0
    s_mtm = signal_strength(mtm_pct, 0.15, 0, 0, -0.15)

    macd_l, macd_s = calc_macd(close, 12, 26, 9)
    hist_pct = ((macd_l.iloc[-1] - macd_s.iloc[-1]) / last_price * 100) if last_price else 0
    s_macd = signal_strength(hist_pct, 0.05, 0, 0, -0.05)

    boll_mid, boll_up, boll_lo = calc_bollinger(close, 20, 2)
    band_half = (boll_up.iloc[-1] - boll_mid.iloc[-1]) or 1
    boll_pos = (last_price - boll_mid.iloc[-1]) / band_half
    s_boll = signal_strength(boll_pos, 0.5, 0, 0, -0.5)

    cci_val = calc_cci(high, low, close, 14).iloc[-1]
    s_cci = signal_strength(cci_val, 100, 0, 0, -100)

    bias_val = calc_bias(close, 20).iloc[-1]
    s_bias = signal_strength(bias_val, 1.0, 0, 0, -1.0)

    kelt_mid, kelt_up, kelt_lo = calc_keltner(high, low, close, 20, 2)
    kelt_half = (kelt_up.iloc[-1] - kelt_mid.iloc[-1]) or 1
    kelt_pos = (last_price - kelt_mid.iloc[-1]) / kelt_half
    s_kelt = signal_strength(kelt_pos, 0.5, 0, 0, -0.5)

    return {
        "MA": s_ma, "RSI": s_rsi, "KD": s_kd, "PSY": s_psy, "WR": s_wr,
        "MTM": s_mtm, "MACD": s_macd, "BOLL": s_boll, "CCI": s_cci,
        "BIAS": s_bias, "KELTNER": s_kelt,
    }


# 分組：震盪指標(RSI/KD/WR/CCI/MTM)本質高度相關，都在測「動能」，
# 直接加總等於同一個意見算5票，所以先組內平均成一個分數，再跟其他組加權合併
GROUP_TREND = ["MA", "MACD", "BOLL", "KELTNER"]
GROUP_MOMENTUM = ["RSI", "KD", "WR", "CCI", "MTM"]
GROUP_OTHER = ["PSY", "BIAS"]
GROUP_WEIGHTS = {"trend": 0.45, "momentum": 0.35, "other": 0.20}


def compute_weighted_score(signals):
    trend_avg = sum(signals[k] for k in GROUP_TREND) / len(GROUP_TREND)
    momentum_avg = sum(signals[k] for k in GROUP_MOMENTUM) / len(GROUP_MOMENTUM)
    other_avg = sum(signals[k] for k in GROUP_OTHER) / len(GROUP_OTHER)
    score = (trend_avg * GROUP_WEIGHTS["trend"] +
             momentum_avg * GROUP_WEIGHTS["momentum"] +
             other_avg * GROUP_WEIGHTS["other"])
    return score, trend_avg, momentum_avg, other_avg


def status_from_score(score):
    """5級狀態，取代原本只有多頭確認/空頭確認兩種的粗略分法"""
    if score >= 1.0:
        return "強力多頭"
    elif score >= 0.3:
        return "偏多"
    elif score <= -1.0:
        return "強力空頭"
    elif score <= -0.3:
        return "偏空"
    else:
        return "多空不明"


def compute_final_signal(df, weighted_score, recent_bars=20, touch_lookback=20):
    """
    跟 ExcelMonitor_All.mq5 M5 那邊同一套邏輯：
    第一層(支撐壓力)：Bid貼近「有效」近期支撐/壓力給±1.0，貼近有效性較弱的次要位給±0.5
    第二層(趨勢)：傳入已算好的weighted_score
    第三層(成交量)：放量×1.3、縮量×0.7、正常×1.0
    合成後對照5級門檻，回傳(finalSignal, combinedScore)
    """
    close, high, low = df["close"], df["high"], df["low"]
    last_price = close.iloc[-1]

    recent_sup = low.iloc[-recent_bars - 1:-1].min()
    recent_res = high.iloc[-recent_bars - 1:-1].max()

    # 觸碰次數判斷有效性(用近期波幅的一個小比例當容忍值，跟MQL5的TouchTolPoints概念一致)
    tol = (recent_res - recent_sup) * 0.02 if recent_res > recent_sup else last_price * 0.0005
    lows_recent = low.iloc[-touch_lookback - 1:-1]
    highs_recent = high.iloc[-touch_lookback - 1:-1]
    support_touch = (abs(lows_recent - recent_sup) <= tol).sum()
    resistance_touch = (abs(highs_recent - recent_res) <= tol).sum()
    support_valid = support_touch >= 2
    resistance_valid = resistance_touch >= 2

    sr_bias = 0.0
    if abs(last_price - recent_sup) <= tol * 2 and support_valid:
        sr_bias = 1.0
    elif abs(last_price - recent_res) <= tol * 2 and resistance_valid:
        sr_bias = -1.0

    # 成交量倍率(用CSV裡的volume欄位，沒有就當作正常看待)
    vol_mult = 1.0
    if "volume" in df.columns:
        cur_vol = df["volume"].iloc[-1]
        avg_vol = df["volume"].iloc[-21:-1].mean()
        if avg_vol > 0:
            if cur_vol > avg_vol * 1.2:
                vol_mult = 1.3
            elif cur_vol < avg_vol * 0.8:
                vol_mult = 0.7

    combined = (weighted_score + sr_bias * 0.5) * vol_mult

    if combined >= 1.3:
        final = "強勢多"
    elif combined >= 0.4:
        final = "偏多"
    elif combined <= -1.3:
        final = "強勢空"
    elif combined <= -0.4:
        final = "偏空"
    else:
        final = "震盪"

    return final, combined


def compute_votes_latest(df):
    """
    回傳 (signals_dict, weighted_score, status, final_signal)。
    signals_dict 裡每個指標是 -2~2 的分級訊號(不再是單純+1/-1)。
    status：純趨勢層(第二層)的5級判定
    final_signal：支撐壓力+趨勢+成交量 三層合成後的最終5級訊號
    資料不足回傳 (None, None, None, None)。
    """
    min_needed = 45
    if len(df) < min_needed:
        return None, None, None, None
    signals = compute_signals_detailed(df)
    score, trend_avg, momentum_avg, other_avg = compute_weighted_score(signals)
    status = status_from_score(score)
    final_signal, combined_score = compute_final_signal(df, score)
    return signals, score, status, final_signal


# ======================================================================
# 回測引擎(跟optimize.py同一套)
# ======================================================================
def backtest_signal(direction, close, high, low, atr):
    dir_vals = direction.values
    close_v = close.values
    high_v = high.values
    low_v = low.values
    atr_v = atr.values
    n = len(dir_vals)

    wins = 0
    completed = 0
    total_ret = 0.0
    prev = 0

    for i in range(1, n):
        cur = dir_vals[i]
        if cur == prev or np.isnan(atr_v[i]) or atr_v[i] <= 0:
            prev = cur
            continue

        entry_price = close_v[i]
        sl_dist = atr_v[i] * ATR_SL_MULT
        tp_dist = atr_v[i] * ATR_TP_MULT

        if cur > 0:
            sl_price, tp_price = entry_price - sl_dist, entry_price + tp_dist
        else:
            sl_price, tp_price = entry_price + sl_dist, entry_price - tp_dist

        end_j = min(i + MAX_HOLD_BARS, n - 1)
        outcome = None
        for j in range(i + 1, end_j + 1):
            if cur > 0:
                if low_v[j] <= sl_price:
                    outcome = "loss"
                    break
                if high_v[j] >= tp_price:
                    outcome = "win"
                    break
            else:
                if high_v[j] >= sl_price:
                    outcome = "loss"
                    break
                if low_v[j] <= tp_price:
                    outcome = "win"
                    break

        if outcome is not None:
            completed += 1
            if outcome == "win":
                wins += 1
                total_ret += (tp_dist / entry_price) * 100
            else:
                total_ret -= (sl_dist / entry_price) * 100

        prev = cur

    win_rate = (wins / completed * 100) if completed > 0 else 0.0
    avg_ret = (total_ret / completed) if completed > 0 else 0.0
    return win_rate, completed, avg_ret


def optimize_all_indicators(df):
    close, high, low = df["close"], df["high"], df["low"]
    atr = calc_atr_series(high, low, close, ATR_PERIOD)
    results = {}

    def try_combo(name, params, direction, raw=None):
        wr, n, alpha = backtest_signal(direction, close, high, low, atr)
        best = results.get(name)
        if n >= 5 and (best is None or (wr, alpha) > (best["win_rate"], best["alpha"])):
            results[name] = {"params": params, "win_rate": wr, "trades": n, "alpha": alpha, "raw": raw}

    for s in MA_SHORT_GRID:
        for l in MA_LONG_GRID:
            if s >= l:
                continue
            direction = pd.Series(np.where(close.rolling(s).mean() > close.rolling(l).mean(), 1, -1), index=close.index)
            try_combo("MA", f"{s}/{l}", direction, raw={"short": s, "long": l})

    for p in RSI_PERIOD_GRID:
        rsi = calc_rsi(close, p)
        for lo, hi in RSI_BOUNDS_GRID:
            direction = pd.Series(np.where(rsi > 50, 1, -1), index=close.index)
            try_combo("RSI", f"K={p},下={lo},上={hi}", direction, raw={"period": p, "lower": lo, "upper": hi})

    for k in KD_K_GRID:
        kk, dd = calc_kd(high, low, close, k, 3, 3)
        direction = pd.Series(np.where(kk > dd, 1, -1), index=close.index)
        try_combo("KD", f"{k}/3/3", direction, raw={"k": k, "d": 3})

    for p in PSY_PERIOD_GRID:
        direction = pd.Series(np.where(calc_psy(close, p) > 50, 1, -1), index=close.index)
        try_combo("PSY", f"{p}(上下50)", direction, raw={"period": p})

    for p in WR_PERIOD_GRID:
        direction = pd.Series(np.where(calc_williams_r(high, low, close, p) > -50, 1, -1), index=close.index)
        try_combo("WR", f"{p}", direction, raw={"period": p})

    for p in MTM_PERIOD_GRID:
        direction = pd.Series(np.where(close.diff(p) > 0, 1, -1), index=close.index)
        try_combo("MTM", f"{p}", direction, raw={"period": p})

    for fast, slow, sig in MACD_GRID:
        macd_line, signal_line = calc_macd(close, fast, slow, sig)
        direction = pd.Series(np.where(macd_line > signal_line, 1, -1), index=close.index)
        try_combo("MACD", f"{fast}/{slow}/{sig}", direction, raw={"fast": fast, "slow": slow, "signal": sig})

    for p, std in BOLL_GRID:
        mid, _, _ = calc_bollinger(close, p, std)
        direction = pd.Series(np.where(close > mid, 1, -1), index=close.index)
        try_combo("BOLL", f"{p}/{std}", direction, raw={"period": p, "std": std})

    for p in CCI_PERIOD_GRID:
        direction = pd.Series(np.where(calc_cci(high, low, close, p) > 0, 1, -1), index=close.index)
        try_combo("CCI", f"{p}", direction, raw={"period": p})

    for p in BIAS_PERIOD_GRID:
        direction = pd.Series(np.where(calc_bias(close, p) > 0, 1, -1), index=close.index)
        try_combo("BIAS", f"{p}", direction, raw={"period": p})

    for p, mult in KELTNER_GRID:
        mid, _, _ = calc_keltner(high, low, close, p, mult)
        direction = pd.Series(np.where(close > mid, 1, -1), index=close.index)
        try_combo("KELTNER", f"{p}/{mult}", direction, raw={"period": p, "mult": mult})

    return results


# ======================================================================
# 主流程
# ======================================================================
DASHBOARD_PARAMS_PATH = BASE_DIR + r"\AllSymbols_DashboardParams.csv"


def write_dashboard_params(all_results_by_symbol_tf, atr_sl_tp_by_symbol_tf):
    """
    寫出跟「儀表板總表」23欄參數表完全對齊的格式，可直接被VBA逐列讀入：
    商品,週期,最佳SL,最佳TP,短均線,長均線,RSI期數,RSI下限,RSI上限,K期數,D期數,
    PSY期數,威廉期數,MTM期數,MACD快線,MACD慢線,MACD訊號,布林期數,布林倍數,
    CCI期數,Abbr模式,肯特納期數,肯特納倍數
    """
    header = ["Symbol", "TF", "BestSL", "BestTP", "MAShort", "MALong", "RSIPeriod", "RSILower", "RSIUpper",
              "KPeriod", "DPeriod", "PSYPeriod", "WRPeriod", "MTMPeriod", "MACDFast", "MACDSlow", "MACDSignal",
              "BollPeriod", "BollStd", "CCIPeriod", "AbbrMode", "KeltPeriod", "KeltMult"]
    rows = []
    for (sym, tf), res in all_results_by_symbol_tf.items():
        if res is None:
            continue

        def raw(name, key, default):
            r = res.get(name)
            if r is None or r.get("raw") is None:
                return default
            return r["raw"].get(key, default)

        sl, tp = atr_sl_tp_by_symbol_tf.get((sym, tf), (0, 0))

        rows.append([
            sym, tf, round(sl, 6), round(tp, 6),
            raw("MA", "short", 10), raw("MA", "long", 30),
            raw("RSI", "period", 14), raw("RSI", "lower", 30), raw("RSI", "upper", 70),
            raw("KD", "k", 9), raw("KD", "d", 3),
            raw("PSY", "period", 12),
            raw("WR", "period", 14),
            raw("MTM", "period", 10),
            raw("MACD", "fast", 12), raw("MACD", "slow", 26), raw("MACD", "signal", 9),
            raw("BOLL", "period", 20), raw("BOLL", "std", 2),
            raw("CCI", "period", 14),
            1,  # AbbrMode：目前沒有可優化的獨立參數，固定填1
            raw("KELTNER", "period", 20), raw("KELTNER", "mult", 2),
        ])

    with open(DASHBOARD_PARAMS_PATH, "w", encoding="utf-8-sig") as f:
        f.write(",".join(header) + "\n")
        for r in rows:
            f.write(",".join(str(x) for x in r) + "\n")


def main():
    if not os.path.isdir(EXPORT_DIR):
        raise RuntimeError(f"找不到匯出資料夾：{EXPORT_DIR}")

    data_cache = {}
    missing = []
    all_removed = []

    for sym in SYMBOLS:
        for tf in TIMEFRAMES:
            path = find_latest_file(sym, tf)
            if path is None:
                missing.append(f"{sym}_{tf}")
                continue
            try:
                data_cache[(sym, tf)] = load_ohlc_csv(path)
                if AUTO_CLEANUP_OLD_EXPORTS:
                    removed = cleanup_old_exports(sym, tf, path)
                    all_removed.extend(removed)
            except Exception as e:
                missing.append(f"{sym}_{tf}(讀取失敗:{e})")

    if missing:
        print("警告，以下商品/週期找不到或讀取失敗，將略過：", ", ".join(missing))
    if all_removed:
        print(f"已自動清理 {len(all_removed)} 個用不到的舊匯出檔(每個商品/週期只保留最新一份)：")
        for name in all_removed:
            print(" -", name)

    param_lines = []
    multitf_rows = []
    dashboard_results = {}  # {(sym,tf): res_dict} 給 write_dashboard_params 用
    dashboard_sltp = {}  # {(sym,tf): (sl_price, tp_price)}

    for sym in SYMBOLS:
        m15_signals, m15_score, m15_status_new, m15_final = None, None, None, None
        h1_signals, h1_score, h1_status_new, h1_final = None, None, None, None

        for tf in TIMEFRAMES:
            df = data_cache.get((sym, tf))
            if df is None:
                param_lines.append(f"{sym}|{tf}|NA|NA|NA|NA|NA|NA|NA|NA|NA|NA|NA")
                continue

            lookback = OPT_LOOKBACK_BARS.get(tf, 500)
            df_opt = df.tail(lookback).reset_index(drop=True)

            if len(df_opt) < 60:
                param_lines.append(f"{sym}|{tf}|NA|NA|NA|NA|NA|NA|NA|NA|NA|NA|NA")
            else:
                res = optimize_all_indicators(df_opt)
                dashboard_results[(sym, tf)] = res

                def fmt(name):
                    r = res.get(name)
                    return "NA" if r is None else f"{r['params']}(勝率{r['win_rate']:.0f}%,{r['trades']}筆)"

                atr_now = calc_atr_series(df_opt["high"], df_opt["low"], df_opt["close"], ATR_PERIOD).iloc[-1]
                sl_price = atr_now * ATR_SL_MULT
                tp_price = atr_now * ATR_TP_MULT
                dashboard_sltp[(sym, tf)] = (sl_price, tp_price)
                dg = 3 if sym in ("USDJPY", "XAUUSD") else 5
                sl_tp_str = f"SL={sl_price:.{dg}f}/TP={tp_price:.{dg}f}(ATR{ATR_PERIOD})"

                def weighted_avg_winrate(res):
                    """用趨勢型45%/震盪型35%/其他20%加權，取代11個指標簡單等權平均"""
                    def group_avg(names):
                        vals = [res[n]["win_rate"] for n in names if n in res]
                        return sum(vals) / len(vals) if vals else None

                    trend_avg = group_avg(GROUP_TREND)
                    momentum_avg = group_avg(GROUP_MOMENTUM)
                    other_avg = group_avg(GROUP_OTHER)

                    parts_wr, parts_w = [], []
                    if trend_avg is not None:
                        parts_wr.append(trend_avg)
                        parts_w.append(GROUP_WEIGHTS["trend"])
                    if momentum_avg is not None:
                        parts_wr.append(momentum_avg)
                        parts_w.append(GROUP_WEIGHTS["momentum"])
                    if other_avg is not None:
                        parts_wr.append(other_avg)
                        parts_w.append(GROUP_WEIGHTS["other"])

                    if not parts_w:
                        return 0
                    # 依實際有資料的組別重新正規化權重，避免某組缺資料時分數被拉低
                    total_w = sum(parts_w)
                    return sum(wr * w for wr, w in zip(parts_wr, parts_w)) / total_w

                avg_wr = weighted_avg_winrate(res)

                param_lines.append("|".join([
                    sym, tf, fmt("MA"), fmt("RSI"), fmt("KD"), fmt("PSY"), fmt("WR"),
                    fmt("MTM"), fmt("MACD"), fmt("BOLL"), fmt("CCI"), fmt("BIAS"),
                    fmt("KELTNER"), sl_tp_str, f"{avg_wr:.0f}%(趨勢45%/震盪35%/其他20%加權)"
                ]))

            if tf == "M15":
                m15_signals, m15_score, m15_status_new, m15_final = compute_votes_latest(df)
            elif tf == "H1":
                h1_signals, h1_score, h1_status_new, h1_final = compute_votes_latest(df)

        if m15_signals is not None:
            m15_l = sum(1 for v in m15_signals.values() if v > 0)
            m15_s = sum(1 for v in m15_signals.values() if v < 0)
            m15_status = m15_status_new
        else:
            m15_l, m15_s, m15_status, m15_score, m15_final = "", "", "資料不足", "", "資料不足"

        if h1_signals is not None:
            h1_l = sum(1 for v in h1_signals.values() if v > 0)
            h1_s = sum(1 for v in h1_signals.values() if v < 0)
            h1_status = h1_status_new
        else:
            h1_l, h1_s, h1_status, h1_score, h1_final = "", "", "資料不足", "", "資料不足"

        multitf_rows.append([
            sym, m15_l, m15_s, m15_status, h1_l, h1_s, h1_status,
            pd.Timestamp.now().strftime("%Y/%m/%d %H:%M:%S"),
            f"{m15_score:.2f}" if m15_score != "" else "",
            f"{h1_score:.2f}" if h1_score != "" else "",
            m15_final, h1_final,
        ])

    with open(OUT_PARAMS_PATH, "w", encoding="utf-8-sig") as f:
        f.write("Symbol|TF|MA|RSI|KD|PSY|WR|MTM|MACD|BOLL|CCI|BIAS|KELTNER|SL_TP|AvgWinRate\n")
        f.write("\n".join(param_lines) + "\n")

    with open(OUT_MULTITF_PATH, "w", encoding="utf-8-sig") as f:
        f.write("Symbol,M15_Long,M15_Short,M15_Status,H1_Long,H1_Short,H1_Status,UpdateTime,M15_Score,H1_Score,M15_Final,H1_Final\n")
        for r in multitf_rows:
            f.write(",".join(str(x) for x in r) + "\n")

    write_dashboard_params(dashboard_results, dashboard_sltp)

    # ---------------- 3. 配對相關性(H1) + ATR反比手數 ----------------
    h1_returns = {}
    h1_atr_pct = {}  # 用「ATR佔價格%」而非原始價格ATR，避免USDJPY(147)跟USDCHF(0.81)這種報價位數差很大的商品直接比價格ATR失真
    for sym in SYMBOLS:
        df = data_cache.get((sym, "H1"))
        if df is None or len(df) < 60:
            continue
        df_recent = df.tail(1000)
        h1_returns[sym] = df_recent.set_index("time")["close"].pct_change().dropna()
        atr_val = calc_atr_series(df_recent["high"], df_recent["low"], df_recent["close"], ATR_PERIOD).iloc[-1]
        last_price = df_recent["close"].iloc[-1]
        h1_atr_pct[sym] = (atr_val / last_price) if last_price else None

    pairs = []
    syms_avail = list(h1_returns.keys())
    for i in range(len(syms_avail)):
        for j in range(i + 1, len(syms_avail)):
            a, b = syms_avail[i], syms_avail[j]
            ra, rb = h1_returns[a].align(h1_returns[b], join="inner")
            if len(ra) < 100:
                continue
            corr = ra.corr(rb)
            if pd.isna(corr):
                continue
            atrp_a, atrp_b = h1_atr_pct.get(a), h1_atr_pct.get(b)
            if not atrp_a or not atrp_b:
                continue
            # 手數比例：用「ATR佔價格百分比」反比，讓兩邊以相對波動幅度計算的風險曝險相對平衡
            # (仍是簡化版，未考慮實際合約規模/每點價值換算成帳戶貨幣的差異，下單前建議再用實際帳戶幣別覆核)
            ratio_a = 1.0
            ratio_b = atrp_a / atrp_b
            pairs.append((a, b, corr, ratio_a, ratio_b))

    pairs.sort(key=lambda x: abs(x[2]), reverse=True)
    top_pairs = pairs[:3]

    with open(OUT_HEDGE_PATH, "w", encoding="utf-8-sig") as f:
        f.write("# 注意：手數比例是用「ATR佔價格百分比」反比的簡化估算，未計入實際合約規模/帳戶幣別換算，下單前請再核對\n")
        f.write("商品A,商品B,相關係數,相關方向,建議手數比例(A:B),說明\n")
        for a, b, corr, ra, rb in top_pairs:
            direction = "正相關" if corr > 0 else "負相關"
            note = "同向確認(避免同時重複曝險)" if corr > 0 else "反向對沖(一多一空互相抵消風險)"
            f.write(f"{a},{b},{corr:.3f},{direction},1:{rb:.2f},{note}\n")

    print("完成！輸出檔案：")
    print(" -", OUT_PARAMS_PATH)
    print(" -", OUT_MULTITF_PATH)
    print(" -", OUT_HEDGE_PATH)
    print(" -", DASHBOARD_PARAMS_PATH)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        err = traceback.format_exc()
        print(err)
        try:
            with open(LOG_PATH, "w", encoding="utf-8-sig") as f:
                f.write(err)
        except Exception:
            pass
        raise
