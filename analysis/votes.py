"""
11 大指標：每個指標定義
  * 參數格（最佳化時搜尋的範圍）
  * state：多空狀態（+1 多 / -1 空 / 0 資料不足），用於「11 指標投票」
  * trade：單一指標的交易訊號（持倉方向 +1/-1，翻轉即換倉），用於「參數優化」
分組：趨勢組 6 個（MA、MTM、MACD、BOLL、BIAS、KELTNER），震盪組 5 個（RSI、KD、PSY、WR、CCI）
"""
import itertools

import numpy as np

from indicators import (sma, rsi, stoch, psy, williams_r, mtm, macd, bollinger, cci,
                        bias, keltner, shift)

ORDER = ["MA", "RSI", "KD", "PSY", "WR", "MTM", "MACD", "BOLL", "CCI", "BIAS", "KELTNER"]
TREND = ["MA", "MTM", "MACD", "BOLL", "BIAS", "KELTNER"]
OSC = ["RSI", "KD", "PSY", "WR", "CCI"]
LABEL_ZH = {"MA": "1.MA", "RSI": "2.RSI", "KD": "3.KD", "PSY": "4.PSY", "WR": "5.威廉 %R",
            "MTM": "6.MTM", "MACD": "7.MACD", "BOLL": "8.布林", "CCI": "9.CCI",
            "BIAS": "10.Abbr", "KELTNER": "11.Keltner"}

GRID = {
    "MA": [dict(s=s, l=l) for s, l in itertools.product([5, 8, 10, 20], [30, 50, 60, 100])],
    "RSI": [dict(n=n, lo=lo, hi=hi) for n, lo, hi in itertools.product([9, 14, 21], [20, 25, 30], [70, 75, 80])],
    "KD": [dict(k=k, d=d, s=s) for k, d, s in itertools.product([9, 14, 21], [3, 5], [3, 5])],
    "PSY": [dict(n=n) for n in [10, 12, 15, 20]],
    "WR": [dict(n=n) for n in [9, 14, 21]],
    "MTM": [dict(n=n) for n in [6, 10, 14, 20]],
    "MACD": [dict(f=f, s=s, g=g) for f, s, g in [(12, 26, 9), (5, 35, 5), (8, 21, 5), (5, 35, 9)]],
    "BOLL": [dict(n=n, k=k) for n, k in itertools.product([10, 20, 27], [1.5, 2.0])],
    "CCI": [dict(n=n) for n in [10, 14, 20]],
    "BIAS": [dict(n=n) for n in [10, 20, 30, 60]],
    "KELTNER": [dict(n=n, m=m) for n, m in itertools.product([10, 18, 20], [1.5, 2.0])],
}


def fmt_params(ind, p):
    return {"MA": lambda: f"{p['s']}/{p['l']}",
            "RSI": lambda: f"K={p['n']},下={p['lo']},上={p['hi']}",
            "KD": lambda: f"{p['k']}/{p['d']}/{p['s']}",
            "PSY": lambda: f"{p['n']}(上下50)",
            "WR": lambda: p["n"], "MTM": lambda: p["n"],
            "MACD": lambda: f"{p['f']}/{p['s']}/{p['g']}",
            "BOLL": lambda: f"{p['n']}/{p['k']}",
            "CCI": lambda: p["n"], "BIAS": lambda: p["n"],
            "KELTNER": lambda: f"{p['n']}/{p['m']}"}[ind]()


def _sign(cond_long, cond_short):
    return np.where(cond_long, 1, np.where(cond_short, -1, 0))


def _hold(sig):
    """把 +1/-1 事件延續成持倉（沒有新事件就維持）；最前面沒有事件前為 0。"""
    s = np.where(sig == 0, np.nan, sig.astype(float))
    return np.nan_to_num(pd_ffill(s)).astype(int)


def pd_ffill(a):
    import pandas as pd
    return pd.Series(a).ffill().to_numpy()


def compute(ind, p, o, h, l, c):
    """回傳 (state, trade)。"""
    if ind == "MA":
        s1, s2 = sma(c, p["s"]), sma(c, p["l"])
        st = _sign(s1 > s2, s1 < s2)
        return st, st
    if ind == "RSI":
        r = rsi(c, p["n"])
        st = _sign(r > 50, r < 50)
        pr = shift(r, 1)
        ev = _sign((pr < p["lo"]) & (r >= p["lo"]), (pr > p["hi"]) & (r <= p["hi"]))   # 超賣回升做多 / 超買回落做空
        return st, _hold(ev)
    if ind == "KD":
        K, D = stoch(h, l, c, p["k"], p["d"], p["s"])
        st = _sign(K > D, K < D)
        return st, st
    if ind == "PSY":
        v = psy(c, p["n"])
        st = _sign(v > 50, v < 50)
        return st, _hold(st)
    if ind == "WR":
        v = williams_r(h, l, c, p["n"])
        st = _sign(v > -50, v < -50)
        return st, _hold(st)
    if ind == "MTM":
        v = mtm(c, p["n"])
        st = _sign(v > 0, v < 0)
        return st, _hold(st)
    if ind == "MACD":
        m, g = macd(c, p["f"], p["s"], p["g"])
        st = _sign(m > g, m < g)
        return st, st
    if ind == "BOLL":
        mid, up, dn = bollinger(c, p["n"], p["k"])
        st = _sign(c > mid, c < mid)
        return st, _hold(_sign(c > up, c < dn))                                         # 突破上軌做多 / 跌破下軌做空
    if ind == "CCI":
        v = cci(h, l, c, p["n"])
        st = _sign(v > 0, v < 0)
        return st, _hold(st)
    if ind == "BIAS":
        v = bias(c, p["n"])
        st = _sign(v > 0, v < 0)
        return st, _hold(st)
    if ind == "KELTNER":
        mid, up, dn = keltner(h, l, c, p["n"], p["m"])
        st = _sign(c > mid, c < mid)
        return st, _hold(_sign(c > up, c < dn))
    raise KeyError(ind)


def zone(o, h, l, c, prm):
    """震盪組區間：RSI>上限、K>80、%R>-20、CCI>100、PSY>75 中 ≥3 個 → 超買；反之 ≥3 個 → 超賣。"""
    r = rsi(c, prm["RSI"]["n"])
    K, _ = stoch(h, l, c, prm["KD"]["k"], prm["KD"]["d"], prm["KD"]["s"])
    w = williams_r(h, l, c, prm["WR"]["n"])
    cc = cci(h, l, c, prm["CCI"]["n"])
    ps = psy(c, prm["PSY"]["n"])
    ob = (r > prm["RSI"]["hi"]).astype(int) + (K > 80) + (w > -20) + (cc > 100) + (ps > 75)
    os_ = (r < prm["RSI"]["lo"]).astype(int) + (K < 20) + (w < -80) + (cc < -100) + (ps < 25)
    return np.where(ob >= 3, "超買", np.where(os_ >= 3, "超賣", "中性"))
