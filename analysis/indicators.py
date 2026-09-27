"""
技術指標（numpy / pandas 實作）。所有函式輸入 numpy 陣列，輸出與輸入等長的陣列，
第 i 個值只用到第 i 根（含）以前的資料，不會偷看未來。
"""
import numpy as np
import pandas as pd


def sma(x, n):
    return pd.Series(x).rolling(int(n), min_periods=int(n)).mean().to_numpy(copy=True)


def ema(x, n):
    return pd.Series(x).ewm(span=int(n), adjust=False).mean().to_numpy(copy=True)


def wilder(x, n):
    """Wilder 平滑（RSI / ATR / ADX 用）。"""
    return pd.Series(x).ewm(alpha=1.0 / n, adjust=False).mean().to_numpy(copy=True)


def shift(a, k=1):
    out = np.full(len(a), np.nan)
    if 0 < k < len(a):
        out[k:] = a[:-k]
    elif k == 0:
        out[:] = a
    return out


def true_range(h, l, c):
    pc = shift(c, 1)
    tr = np.fmax(h, pc) - np.fmin(l, pc)
    tr[0] = h[0] - l[0]
    return tr


def atr(h, l, c, n=14):
    return wilder(true_range(h, l, c), n)


def rsi(c, n):
    d = np.diff(c, prepend=c[0])
    up = wilder(np.where(d > 0, d, 0.0), n)
    dn = wilder(np.where(d < 0, -d, 0.0), n)
    with np.errstate(divide="ignore", invalid="ignore"):
        r = 100 - 100 / (1 + up / dn)
    r = np.where(dn == 0, 100.0, r)
    r[:n] = np.nan
    return r


def stoch(h, l, c, k, d, slow):
    ll = pd.Series(l).rolling(k, min_periods=k).min()
    hh = pd.Series(h).rolling(k, min_periods=k).max()
    num = (pd.Series(c) - ll).rolling(slow, min_periods=slow).sum()
    den = (hh - ll).rolling(slow, min_periods=slow).sum()
    K = np.where(den > 0, 100 * num / den, 50.0)
    K = np.where(den.isna(), np.nan, K)
    return K, sma(K, d)


def psy(c, n):
    up = (np.diff(c, prepend=np.nan) > 0).astype(float)
    return pd.Series(up).rolling(n, min_periods=n).mean().to_numpy() * 100


def williams_r(h, l, c, n):
    hh = pd.Series(h).rolling(n, min_periods=n).max().to_numpy()
    ll = pd.Series(l).rolling(n, min_periods=n).min().to_numpy()
    with np.errstate(divide="ignore", invalid="ignore"):
        return np.where(hh > ll, -100 * (hh - c) / (hh - ll), -50.0)


def mtm(c, n):
    return c - shift(c, n)


def macd(c, f, s, sig):
    m = ema(c, f) - ema(c, s)
    return m, ema(m, sig)


def bollinger(c, n, k):
    s = pd.Series(c)
    mid = s.rolling(n, min_periods=n).mean()
    sd = s.rolling(n, min_periods=n).std(ddof=0)
    return mid.to_numpy(), (mid + k * sd).to_numpy(), (mid - k * sd).to_numpy()


def cci(h, l, c, n):
    tp = (h + l + c) / 3.0
    out = np.full(len(tp), np.nan)
    if len(tp) < n:
        return out
    win = np.lib.stride_tricks.sliding_window_view(tp, n)
    m = win.mean(axis=1)
    md = np.abs(win - m[:, None]).mean(axis=1)
    with np.errstate(divide="ignore", invalid="ignore"):
        out[n - 1:] = (tp[n - 1:] - m) / (0.015 * md)
    return out


def bias(c, n):
    m = sma(c, n)
    with np.errstate(divide="ignore", invalid="ignore"):
        return (c - m) / m * 100


def keltner(h, l, c, n, mult):
    mid = ema(c, n)
    a = atr(h, l, c, n)
    return mid, mid + mult * a, mid - mult * a


def adx(h, l, c, n=14):
    up = np.diff(h, prepend=h[0])
    dn = -np.diff(l, prepend=l[0])
    pdm = np.where((up > dn) & (up > 0), up, 0.0)
    ndm = np.where((dn > up) & (dn > 0), dn, 0.0)
    tr = wilder(true_range(h, l, c), n)
    with np.errstate(divide="ignore", invalid="ignore"):
        pdi = 100 * wilder(pdm, n) / tr
        ndi = 100 * wilder(ndm, n) / tr
        dx = 100 * np.abs(pdi - ndi) / (pdi + ndi)
    a = wilder(np.nan_to_num(dx), n)
    a[:2 * n] = np.nan
    return a, pdi, ndi


def tai(o, h, l, c, ma_period=28, tai_period=5, boost=0.35, fl_period=50,
        lvl_up=80.0, lvl_dn=20.0, atr_period=14, atr_mult=1.0):
    """
    TAI（依 TAI_Color_Panel_Optimized.mq5 v2.60 逐行移植）。
    回傳 val（TAI 值）與 color：1=多頭動能（藍）、2=空頭動能（紅）、0=中性。
    """
    avg = ema(c, ma_period)
    n = len(c)
    fast = np.empty(n)
    fast[0] = avg[0]
    fast[1:] = avg[1:] + boost * (avg[1:] - avg[:-1])
    a = atr(h, l, c, atr_period)
    mx = pd.Series(fast).rolling(tai_period, min_periods=tai_period).max().to_numpy()
    mn = pd.Series(fast).rolling(tai_period, min_periods=tai_period).min().to_numpy()
    direction = np.where(fast >= shift(fast, 1), 1.0, -1.0)
    with np.errstate(divide="ignore", invalid="ignore"):
        val = np.where(np.abs(c) > 0, 100 * direction * (mx - mn) / np.abs(c), 0.0)
    val[:tai_period] = 0.0
    vmin = pd.Series(val).rolling(fl_period, min_periods=fl_period).min().to_numpy()
    vmax = pd.Series(val).rolling(fl_period, min_periods=fl_period).max().to_numpy()
    rng = np.maximum(vmax - vmin, 1e-12)
    vol = np.minimum(0.20, (a / np.abs(c)) * atr_mult * 10.0)
    upp = np.minimum(95.0, lvl_up + vol * 25.0)
    low = np.maximum(5.0, lvl_dn - vol * 25.0)
    level_up = vmin + rng * upp * 0.01
    level_dn = vmin + rng * low * 0.01
    prev = shift(val, 1)
    color = np.where((val > level_up) & (val > prev), 1, np.where((val < level_dn) & (val < prev), 2, 0))
    color[: tai_period + fl_period] = 0
    return val, color


def swing_trendline(h, l, c, w=5):
    """
    擺動點趨勢線：左右各 w 根內的最高/最低點為擺動點（第 i+w 根收盤後才確認，不偷看）。
    用最近兩個已確認的擺動高點連成壓力線、兩個擺動低點連成支撐線，延伸到當根。
    回傳每根的狀態：'向上突破' / '向下突破' / '收斂待變（尚未突破）' / '區間整理中'
    """
    n = len(c)
    out = np.array(["區間整理中"] * n, dtype=object)
    hs, ls = [], []
    for i in range(n):
        j = i - w                       # 在第 i 根時可以確認第 j 根是不是擺動點
        if j - w >= 0:
            if h[j] == h[j - w:j + w + 1].max():
                hs.append(j)
            if l[j] == l[j - w:j + w + 1].min():
                ls.append(j)
        if len(hs) < 2 or len(ls) < 2:
            continue
        (a1, a2), (b1, b2) = hs[-2:], ls[-2:]
        sh = (h[a2] - h[a1]) / (a2 - a1)
        sl = (l[b2] - l[b1]) / (b2 - b1)
        up_line = h[a2] + sh * (i - a2)
        dn_line = l[b2] + sl * (i - b2)
        if c[i] > up_line:
            out[i] = "向上突破"
        elif c[i] < dn_line:
            out[i] = "向下突破"
        elif sh < 0 < sl:
            out[i] = "收斂待變（尚未突破）"
    return out
