"""
MultiCurrency_EA 的 Python 回測（逐分鐘模擬），並同時產生 ML 訓練資料。

用法（Windows，MT5 終端已登入）：
    python backtest.py                  # 預設：從今天往前 3 年
    python backtest.py --years 5        # 往前 5 年
    python backtest.py --from 2024-01-01 --to 2024-12-31

特點
  * EA 參數、商品、權重、FilterLib 規則（SL/TP/手數/ATR門檻）與風控常數
    都直接從 MultiCurrency_EA.mq5 / FilterLib_v5.mqh 原始碼讀取，不用手動同步。
  * 指標依 MT5 內建指標的公式實作（EMA、RSI(Wilder)、BB(母體標準差)、
    MACD(訊號線為SMA)、Stochastic(SMA, Low/High)、ATR(SMA)）。
  * 風控照 EA 實際程式行為逐分鐘模擬：追蹤停損、H1 反向信號平倉、ATR 波動平倉、
    每商品每日止損次數、單日虧損上限、淨值下限、禁止交易時段、每日重置與強平
    （時間規則依 EA 的 TimeLocal()，用 --local-tz 換算你電腦的時區）。
  * --mode both 一次跑「舊邏輯」與「修正後」並列比較。
  * 修正後模式同時輸出與 MLRecorder 相同格式的 features_py_*.csv，可直接給 train.py。

與 MT5 策略測試器的差異（簡化）
  * 以 M1 K 線模擬：每分鐘開盤時執行一次 EA 邏輯，SL/TP 用該分鐘高低點判斷，
    同一根同時碰到 SL 與 TP 視為 SL。
  * 波動過濾用「前一根 M1 的真實波幅」近似 EA 的 iATR(M1,1)。
  * 不含隔夜利息；手續費用 --commission（每手來回，預設 5 USD，FTMO 外匯）。
  結果應與 MT5 測試器「方向一致、數值接近」，最終上線前仍以 MT5 測試器為準。
"""
import argparse
import datetime as dt
import os
import re
import sys
import time

import numpy as np
import pandas as pd

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from mt5data import fetch_m1  # noqa: E402

# ---------------------------------------------------------------- 原始碼解析

def parse_sources(src_dir):
    ea = open(os.path.join(src_dir, "MultiCurrency_EA.mq5"), encoding="utf-8-sig").read()
    fl = open(os.path.join(src_dir, "FilterLib_v5.mqh"), encoding="utf-8-sig").read()

    syms = [re.search(rf'Inp_Sym{i}\s*=\s*"([^"]+)"', ea).group(1) for i in range(1, 8)]
    p = {}
    for i in range(1, 8):
        d = {k: float(v) for k, v in re.findall(rf'\bS{i}_(\w+)\s*=\s*([\d.]+)', ea)}
        p[syms[i - 1]] = d
    weight = [int(x) for x in re.search(r'weight\[IND_COUNT\]\s*=\s*\{([^}]*)\}', ea).group(1).split(",")]
    min_conf = int(re.search(r'Inp_MinConfirm\s*=\s*(\d+)', ea).group(1))
    max_pos = int(re.search(r'Inp_MaxPos\s*=\s*(\d+)', ea).group(1))
    max_hold = int(re.search(r'Inp_MLMaxHoldHours\s*=\s*(\d+)', ea).group(1))

    rules = {}
    for m in re.finditer(
            r'fx_rules\[(\d+)\]\.symbol="(\w+)";\s*fx_rules\[\1\]\.sl_pips=([\d.]+);\s*'
            r'fx_rules\[\1\]\.tp_pips=([\d.]+);\s*fx_rules\[\1\]\.atr_threshold=([\d.]+);\s*'
            r'fx_rules\[\1\]\.lot_size=([\d.]+);', fl):
        rules[m.group(2)] = dict(sl=float(m.group(3)), tp=float(m.group(4)),
                                 atr=float(m.group(5)), lot=float(m.group(6)))

    ctor = fl[fl.index("CFilterLib_Pro(long mg"):]
    ctor = ctor[:ctor.index("InitRules();")]
    c = {k: float(v) for k, v in re.findall(r'(\w+)\s*=\s*(-?[\d.]+);', ctor)}

    block = fl[fl.index("SYMBOLS[SYMBOL_COUNT]"):]
    block = block[:block.index("};")]
    block = re.sub(r"//[^\n]*", "", block)
    f_syms = re.findall(r'"([^"]+)"', block)

    consts = {k: float(v) for k, v in re.findall(r'const (?:int|double)\s+(\w+)\s*=\s*([\d.]+);', fl)}
    return dict(symbols=syms, params=p, weight=weight, min_conf=min_conf, max_pos=max_pos,
                max_hold=max_hold, rules=rules, c=c, f_syms=f_syms, consts=consts)


# ---------------------------------------------------------------- MT5 指標公式

def ema(x, n):
    return pd.Series(x).ewm(alpha=2.0 / (n + 1), adjust=False).mean().to_numpy()


def sma(x, n):
    return pd.Series(x).rolling(int(n), min_periods=int(n)).mean().to_numpy()


def rsi(close, n):
    n = int(n)
    d = np.diff(close, prepend=np.nan)
    pos = np.full(len(close), np.nan)
    neg = np.full(len(close), np.nan)
    if len(close) <= n:
        return pos
    g = np.where(d > 0, d, 0.0)
    l_ = np.where(d < 0, -d, 0.0)
    pos[n] = g[1:n + 1].mean()
    neg[n] = l_[1:n + 1].mean()
    for i in range(n + 1, len(close)):
        pos[i] = (pos[i - 1] * (n - 1) + g[i]) / n
        neg[i] = (neg[i - 1] * (n - 1) + l_[i]) / n
    with np.errstate(divide="ignore", invalid="ignore"):
        r = 100.0 - 100.0 / (1.0 + pos / neg)
    r = np.where(neg == 0, np.where(pos != 0, 100.0, 50.0), r)
    r[:n] = np.nan
    return r


def bands(close, n, k):
    s = pd.Series(close)
    mid = s.rolling(int(n), min_periods=int(n)).mean()
    sd = s.rolling(int(n), min_periods=int(n)).std(ddof=0)
    return mid.to_numpy(), (mid + k * sd).to_numpy(), (mid - k * sd).to_numpy()


def macd(close, f, s, sig):
    main = ema(close, f) - ema(close, s)
    return main, sma(main, sig)


def stoch(high, low, close, kp, dp, slow):
    ll = pd.Series(low).rolling(int(kp), min_periods=int(kp)).min()
    hh = pd.Series(high).rolling(int(kp), min_periods=int(kp)).max()
    num = (pd.Series(close) - ll).rolling(int(slow), min_periods=int(slow)).sum()
    den = (hh - ll).rolling(int(slow), min_periods=int(slow)).sum()
    main = np.where(den == 0, 100.0, 100.0 * num / den)
    main = np.where(den.isna(), np.nan, main)
    return main, sma(main, dp)


def true_range(high, low, close):
    pc = np.roll(close, 1)
    pc[0] = np.nan
    tr = np.fmax(high, pc) - np.fmin(low, pc)
    tr[0] = high[0] - low[0]
    return tr


def resample(m1, rule):
    df = m1.set_index("time")[["open", "high", "low", "close"]]
    r = df.resample(rule, origin="start_day", label="left", closed="left").agg(
        {"open": "first", "high": "max", "low": "min", "close": "last"}).dropna()
    first = pd.Series(m1["time"].to_numpy(), index=m1["time"]).resample(
        rule, origin="start_day", label="left", closed="left").first()
    r["first_m1"] = first.reindex(r.index)
    return r.reset_index()


def shifted(a, k):
    """a[i-k]（第 i 根 K 線看 shift k）"""
    out = np.full(len(a), np.nan)
    if k < len(a):
        out[k:] = a[:len(a) - k]
    return out


# ---------------------------------------------------------------- 信號

def pip_of(digits):
    return 0.01 if digits in (2, 3) else 0.0001


def ea_signals(m12, p, weight, min_conf, legacy):
    """回傳每根 M12 K 線（在該 K 線期間有效）的 5 個指標方向、買賣分數、信號、分數。"""
    o, h, l, c = (m12[k].to_numpy() for k in ("open", "high", "low", "close"))
    EF, ES = ema(c, p["EMA_F"]), ema(c, p["EMA_S"])
    R = rsi(c, p["RSI_P"])
    BM, BU, BL = bands(c, p["BB_P"], p["BB_Std"])
    MM, MS = macd(c, p["MF"], p["MS"], p["MSig"])
    SK, SD = stoch(h, l, c, p["KP"], p["KK"], p["KD"])   # iStochastic(K, D=KK, slowing=KD)

    # 陣列第 j 個元素對應的 shift：修正後 [0]=shift1；舊版為時間正序 [0]=最舊
    def at(arr, count, j):
        k = (count - j) if legacy else (j + 1)
        return shifted(arr, k)

    c0, c1 = shifted(c, 1), shifted(c, 2)
    s = np.zeros((len(c), 5), dtype=int)

    ef0, ef1, ef2 = at(EF, 3, 0), at(EF, 3, 1), at(EF, 3, 2)
    es0, es1 = at(ES, 3, 0), at(ES, 3, 1)
    s[:, 0] = np.select([
        (ef1 <= es1) & (ef0 > es0), (ef1 >= es1) & (ef0 < es0),
        (ef0 > es0) & (ef1 > es1) & (ef0 > ef1) & (c0 > ef0),
        (ef0 < es0) & (ef1 < es1) & (ef0 < ef1) & (c0 < ef0),
        (ef0 > ef1) & (ef1 > ef2) & (ef0 > es0) & (c0 > ef0),
        (ef0 < ef1) & (ef1 < ef2) & (ef0 < es0) & (c0 < ef0)], [1, -1, 1, -1, 1, -1], 0)

    r0, r1, r2 = at(R, 3, 0), at(R, 3, 1), at(R, 3, 2)
    os_, ob = p["RSI_OS"], p["RSI_OB"]
    s[:, 1] = np.select([
        (r1 < os_) & (r0 > os_), (r1 > ob) & (r0 < ob),
        (r1 <= 50) & (r0 > 50), (r1 >= 50) & (r0 < 50),
        (r0 > r1) & (r1 > r2) & (r0 > 55), (r0 < r1) & (r1 < r2) & (r0 < 45)],
        [1, -1, 1, -1, 1, -1], 0)

    up0, up1 = at(BU, 2, 0), at(BU, 2, 1)
    lo0, lo1 = at(BL, 2, 0), at(BL, 2, 1)
    bw0, bw1 = up0 - lo0, up1 - lo1
    s[:, 2] = np.select([
        bw0 < bw1, (c1 <= lo1) & (c0 > lo0), (c1 >= up1) & (c0 < up0), c0 > up0, c0 < lo0],
        [0, 1, -1, 1, -1], 0)

    if not legacy:   # 舊版 MACD 讀不存在的緩衝區，永遠是 0
        m0, m1 = shifted(MM, 1), shifted(MM, 2)
        g0, g1 = shifted(MS, 1), shifted(MS, 2)
        H = MM - MS
        h0, h1, h2 = shifted(H, 1), shifted(H, 2), shifted(H, 3)
        s[:, 3] = np.select([
            (m1 <= g1) & (m0 > g0), (m1 >= g1) & (m0 < g0),
            (h0 > 0) & (h1 > 0) & (h0 > h1) & (h1 > h2), (h0 < 0) & (h1 < 0) & (h0 < h1) & (h1 < h2),
            (h1 < 0) & (h0 > h1), (h1 > 0) & (h0 < h1),
            (m0 > 0) & (m0 > m1), (m0 < 0) & (m0 < m1)], [1, -1, 1, -1, 1, -1, 1, -1], 0)

    ci, pi = (1, 2) if legacy else (0, 1)
    kc, kpv = at(SK, 3, ci), at(SK, 3, pi)
    dc, dpv = at(SD, 3, ci), at(SD, 3, pi)
    s[:, 4] = np.select([
        (kpv <= dpv) & (kc > dc) & (kc < 30) & (kc > kpv),
        (kpv >= dpv) & (kc < dc) & (kc > 70) & (kc < kpv)], [1, -1], 0)

    w = np.array(weight)
    buy = ((s == 1) * w).sum(1)
    sell = ((s == -1) * w).sum(1)
    sig = np.where((buy >= min_conf) & (buy > sell), 1, np.where((sell >= min_conf) & (sell > buy), -1, 0))
    score = np.where(sig > 0, buy, np.where(sig < 0, sell, 0))
    ind = dict(EF=EF, ES=ES, R=R, BM=BM, BU=BU, BL=BL, MM=MM, MS=MS, SK=SK, SD=SD)
    return s, buy, sell, sig, score, ind


def f_signal_h1(h1, sym, consts):
    """FilterLib F段：H1、固定參數，shift1 的 5 指標多數決（>=4）。"""
    c = h1["close"].to_numpy(); h = h1["high"].to_numpy(); l = h1["low"].to_numpy()
    ef, es = ema(c, consts["EMA_FAST"]), ema(c, consts["EMA_SLOW"])
    r = rsi(c, consts["RSI_PERIOD"])
    if sym == "USDJPY":
        bm, _, _ = bands(c, consts["BB_PERIOD_USDJPY"], consts["BB_DEV_USDJPY"])
    else:
        bm, _, _ = bands(c, consts["BB_PERIOD_DEFAULT"], consts["BB_DEV_DEFAULT"])
    mm, ms = macd(c, consts["MACD_FAST"], consts["MACD_SLOW"], consts["MACD_SIG"])
    kp = 14 if sym in ("GBPUSD", "AUDUSD", "NZDUSD") else 9
    sk, sd = stoch(h, l, c, kp, consts["KDJ_KD"], consts["KDJ_KK"])
    E, S_, R_, P, B, M, G, K, D = (shifted(x, 1) for x in (ef, es, r, c, bm, mm, ms, sk, sd))
    os_, ob = consts["RSI_OS"], consts["RSI_OB"]
    buy = ((E > S_).astype(int) + ((R_ > os_) & (R_ < ob)) + (P > B) + (M > G) + ((K > D) & (K < 80)))
    sell = ((E < S_).astype(int) + ((R_ < ob) & (R_ > os_)) + (P < B) + (M < G) + ((K < D) & (K > 20)))
    valid = ~np.isnan(E + S_ + R_ + B + M + G + K + D)
    return np.where(valid & (buy >= 4), 1, np.where(valid & (sell >= 4), -1, 0))


def swing_levels(m12, pip, min_body, max_swing, lookback=30):
    """CalcTrailingStop 用：前 30 根已收盤 K 線中，實體 >= min_body 的前 max_swing 根的最低低點/最高高點。"""
    o, h, l, c = (m12[k].to_numpy() for k in ("open", "high", "low", "close"))
    n = len(c)
    cnt = np.zeros(n, dtype=int)
    lo = np.full(n, np.nan)
    hi = np.full(n, np.nan)
    for k in range(1, lookback + 1):
        oo, hh, ll, cc = shifted(o, k), shifted(h, k), shifted(l, k), shifted(c, k)
        ok = (np.abs(cc - oo) / pip >= min_body) & (cnt < max_swing)
        ok &= ~np.isnan(cc)
        lo = np.where(ok, np.fmin(lo, ll), lo)
        hi = np.where(ok, np.fmax(hi, hh), hi)
        cnt += ok
    return cnt, lo, hi


# ---------------------------------------------------------------- 時間

def local_times(server_times, local_tz, server_ny_offset):
    """伺服器時間 → 你電腦的本機時間（EA 的 TimeLocal）。FTMO 伺服器 = 紐約時間 + 7 小時。"""
    ny = (pd.DatetimeIndex(server_times) - pd.Timedelta(hours=server_ny_offset))
    ny = ny.tz_localize("America/New_York", ambiguous=np.ones(len(ny), dtype=bool),
                        nonexistent="shift_forward")
    return ny.tz_convert(local_tz).tz_localize(None)


# ---------------------------------------------------------------- 模擬

class Sim:
    def __init__(self, cfg, data, legacy, deposit, commission, local_tz, server_ny_offset, log, start, end):
        self.cfg, self.legacy, self.log = cfg, legacy, log
        self.syms = cfg["symbols"]
        self.c = cfg["c"]
        self.commission = commission
        self.balance = deposit
        self.deposit = deposit

        # 統一的 M1 時間軸（只模擬 start 之後；之前的資料只用來讓指標暖機）
        times = sorted(set().union(*[set(data[s][0]["time"]) for s in self.syms]))
        self.T = pd.DatetimeIndex(times)
        self.T = self.T[(self.T >= pd.Timestamp(start)) & (self.T < pd.Timestamp(end) + pd.Timedelta(days=1))]
        self.L = local_times(self.T, local_tz, server_ny_offset)
        self.Lmin = (self.L.hour * 60 + self.L.minute).to_numpy()
        self.Tn = self.T.to_numpy()
        lday = self.L.normalize()
        self.Lday = lday.to_numpy().astype("datetime64[D]").astype(np.int64)
        st = lday + pd.Timedelta(hours=cfg["c"]["TradingStartHour"], minutes=cfg["c"]["TradingStartMin"])
        self.TDS = np.where(self.L >= st, st, st - pd.Timedelta(days=1)).astype("datetime64[ns]")

        self.S = {}
        for s in self.syms:
            m1, meta = data[s]
            d = m1.set_index("time").reindex(self.T)
            digits, point = int(meta["digits"]), float(meta["point"])
            pip = pip_of(digits)
            tr = true_range(m1["high"].to_numpy(), m1["low"].to_numpy(), m1["close"].to_numpy())
            tr_prev = pd.Series(shifted(tr, 1), index=m1["time"]).reindex(self.T).to_numpy()

            m12 = resample(m1, "12min")
            sgn, buy, sell, sig, score, ind = ea_signals(m12, cfg["params"][s], cfg["weight"],
                                                          cfg["min_conf"], legacy)
            cnt, swl, swh = swing_levels(m12, pip, self.c["MinBarBodyPips"], self.c["MaxSwingBars"])
            b12 = self.T.floor("12min")
            pos12 = m12["time"].searchsorted(b12)
            pos12 = np.where((pos12 < len(m12)) &
                             (m12["time"].to_numpy()[np.minimum(pos12, len(m12) - 1)] == b12.to_numpy()),
                             pos12, -1)
            fsig = None
            posh = None
            if s in cfg["f_syms"]:
                h1 = resample(m1, "1h")
                fsig = f_signal_h1(h1, s, cfg["consts"])
                bh = self.T.floor("1h")
                posh = h1["time"].searchsorted(bh)
                posh = np.where((posh < len(h1)) &
                                (h1["time"].to_numpy()[np.minimum(posh, len(h1) - 1)] == bh.to_numpy()),
                                posh, -1)
            self.S[s] = dict(
                o=d["open"].to_numpy(), h=d["high"].to_numpy(), l=d["low"].to_numpy(),
                c=d["close"].to_numpy(), spr=d["spread"].to_numpy(), tr_prev=tr_prev,
                point=point, digits=digits, pip=pip, contract=float(meta.get("contract", 100000)),
                rule=cfg["rules"].get(s), m12=m12, m12_time=m12["time"].to_numpy(), pos12=pos12,
                sig=sig, score=score, sgn=sgn, buy=buy, sell=sell, ind=ind,
                sw_cnt=cnt, sw_lo=swl, sw_hi=swh, fsig=fsig, posh=posh)

        # 狀態
        self.pos = {}                  # sym -> dict
        self.deals = []                # dict(time, sym, profit, reason, ...)
        self.day_lock = False
        self.sym_lock = set()
        self.last_reset = None
        self.force_closed = False
        self.last_bar = {s: None for s in self.syms}
        self.last_bar_f = {s: None for s in self.syms}
        self.last_bid = {s: np.nan for s in self.syms}
        self.last_spr = {s: 0.0 for s in self.syms}
        self.equity = np.empty(len(self.T))
        self.pos_intervals = {s: [] for s in self.syms}
        self._day = (None, -1, 0.0, {})   # 當日成交快取：(交易日開始, 成交筆數, 損益, 各商品SL次數)

    # --- 價格與損益
    def usd(self, s, diff, lot, price):
        S = self.S[s]
        v = diff * lot * S["contract"]
        return v / price if s.startswith("USD") and not s.endswith("USD") else v

    def bid_ask(self, s):
        b = self.last_bid[s]
        return b, b + self.last_spr[s] * self.S[s]["point"]

    def floating(self):
        f = 0.0
        for s, p in self.pos.items():
            b, a = self.bid_ask(s)
            if p["dir"] > 0:
                f += self.usd(s, b - p["entry"], p["lot"], b)
            else:
                f += self.usd(s, p["entry"] - a, p["lot"], a)
        return f

    def close(self, s, k, price, reason):
        p = self.pos.pop(s)
        prof = self.usd(s, (price - p["entry"]) * p["dir"], p["lot"], price) - self.commission * p["lot"]
        self.balance += prof
        self.deals.append(dict(open_time=self.Tn[p["k"]], close_time=self.Tn[k], symbol=s, dir=p["dir"],
                               lot=p["lot"], entry=p["entry"], exit=price, sl=p["sl"], tp=p["tp"],
                               profit=prof, reason=reason, score=p["score"]))
        self.pos_intervals[s].append((p["k"], k))

    def close_market(self, s, k, reason):
        b, a = self.bid_ask(s)
        self.close(s, k, b if self.pos[s]["dir"] > 0 else a, reason)

    def close_all(self, k, reason):
        for s in list(self.pos):
            self.close_market(s, k, reason)

    # --- FilterLib 邏輯（依 TimeLocal）
    def trading_day_start(self, k):
        return self.TDS[k]

    def day_stats(self, k):
        # EA 用 HistorySelect(本機時間的交易日開始, TimeLocal())，但成交時間是伺服器時間；照原樣模擬
        start = self.trading_day_start(k)
        if self._day[0] != start or self._day[1] != len(self.deals):
            pnl, slc = 0.0, {}
            for d in reversed(self.deals):
                if d["close_time"] < start:
                    break
                pnl += d["profit"]
                if d["reason"] == "SL":
                    slc[d["symbol"]] = slc.get(d["symbol"], 0) + 1
            self._day = (start, len(self.deals), pnl, slc)
        return self._day

    def sl_count(self, s, k):
        return self.day_stats(k)[3].get(s, 0)

    def day_pnl(self, k):
        return self.day_stats(k)[2] + self.floating()

    def vol_normal(self, s):
        S = self.S[s]
        r = S["rule"]
        if r is None:
            return True
        tr = S["tr_prev"][self.k]
        if np.isnan(tr):
            return True
        return tr / S["pip"] < r["atr"] * self.c["VolatilityMultiplier"]

    def no_trade(self, k):
        m = self.Lmin[k]
        c = self.c
        s1 = c["NoTradeStartHour"] * 60 + c["NoTradeStartMin"]; e1 = c["NoTradeEndHour"] * 60 + c["NoTradeEndMin"]
        s2 = c["NoTrade2StartHour"] * 60 + c["NoTrade2StartMin"]; e2 = c["NoTrade2EndHour"] * 60 + c["NoTrade2EndMin"]
        return (s1 <= m < e1) or (s2 <= m < e2)

    def daily_reset(self, k):
        day = self.Lday[k]
        past = self.Lmin[k] >= self.c["TradingStartHour"] * 60 + self.c["TradingStartMin"]
        if self.last_reset is None:
            if past:
                self.day_lock = False
                self.sym_lock.clear()
            self.last_reset = day
            return
        if day != self.last_reset and past:
            self.day_lock = False
            self.sym_lock.clear()
            self.last_reset = day
            self.force_closed = False

    def force_close(self, k):
        if self.force_closed:
            return
        if self.Lmin[k] >= self.c["ForceCloseHour"] * 60 + self.c["ForceCloseMin"]:
            self.close_all(k, "FORCE")
            self.force_closed = True

    def trailing(self, s, p, k):
        S = self.S[s]
        i12 = S["pos12"][k]
        cur = p["sl"]
        new = cur
        if i12 >= 0 and S["sw_cnt"][i12] > 0:
            if p["dir"] > 0:
                lvl = S["sw_lo"][i12]
                if lvl > cur:
                    new = lvl
            else:
                lvl = S["sw_hi"][i12]
                if cur <= 0 or lvl < cur:
                    new = lvl
        else:
            b, a = self.bid_ask(s)
            px = b if p["dir"] > 0 else a
            prof = (px - p["entry"]) / S["pip"] * p["dir"]
            if prof >= self.c["StepProfitPips"]:
                steps = int(prof / self.c["StepProfitPips"])
                stepsl = p["entry"] + p["dir"] * steps * self.c["StepLockPips"] * S["pip"]
                if (p["dir"] > 0 and stepsl > cur) or (p["dir"] < 0 and stepsl < cur):
                    new = stepsl
        if abs(new - cur) > S["point"] * 2:
            b, a = self.bid_ask(s)
            # 券商會拒絕放在現價另一側的 SL（EA 不檢查回傳值）
            if (p["dir"] > 0 and new < b) or (p["dir"] < 0 and new > a):
                p["sl"] = round(new, S["digits"])

    def monitor(self, k):
        self.daily_reset(k)
        self.force_close(k)
        eq = self.balance + self.floating()
        if eq <= self.c["AccountEquityFloor"]:
            self.close_all(k, "EQUITY_FLOOR")
            self.day_lock = True
            return
        if self.day_pnl(k) <= self.c["DayLossLimit"]:
            self.close_all(k, "DAY_LOSS")
            self.day_lock = True
            return
        for s in list(self.pos):
            if s not in self.pos or np.isnan(self.S[s]["o"][k]):
                continue
            p = self.pos[s]
            if s in self.sym_lock:
                continue
            if self.sl_count(s, k) >= self.c["MaxSymbolStopLoss"]:
                self.sym_lock.add(s)
                continue
            if not self.vol_normal(s):
                self.close_market(s, k, "VOL")
                self.sym_lock.add(s)
                continue
            self.trailing(s, p, k)
            S = self.S[s]
            if S["fsig"] is not None and S["posh"][k] >= 0:
                hb = S["posh"][k]
                if hb != self.last_bar_f[s]:
                    self.last_bar_f[s] = hb
                    fs = S["fsig"][hb]
                    if (p["dir"] > 0 and fs < 0) or (p["dir"] < 0 and fs > 0):
                        self.close_market(s, k, "REVERSE")

    def allow(self, s, k):
        if self.day_lock or s in self.sym_lock or self.no_trade(k) or not self.vol_normal(s):
            return False
        if self.balance + self.floating() <= self.c["AccountEquityFloor"]:
            return False
        if self.day_pnl(k) <= self.c["DayLossLimit"]:
            return False
        if self.sl_count(s, k) >= self.c["MaxSymbolStopLoss"]:
            return False
        return self.S[s]["rule"] is not None

    def try_open(self, k):
        best, best_score = None, 0
        for s in self.syms:
            S = self.S[s]
            i12 = S["pos12"][k]
            if i12 < 0 or np.isnan(S["o"][k]):
                continue
            if self.last_bar[s] == i12 or s in self.pos or not self.vol_normal(s):
                continue
            if S["sig"][i12] != 0 and S["score"][i12] > best_score:
                best, best_score = s, S["score"][i12]
        if best is None or len(self.pos) >= self.cfg["max_pos"] or not self.allow(best, k):
            return
        S = self.S[best]
        i12 = S["pos12"][k]
        d = int(S["sig"][i12])
        r = S["rule"]
        b, a = self.bid_ask(best)
        px = a if d > 0 else b
        self.pos[best] = dict(dir=d, entry=px, sl=round(px - d * r["sl"] * S["pip"], S["digits"]),
                              tp=round(px + d * r["tp"] * S["pip"], S["digits"]), lot=r["lot"], k=k,
                              score=int(best_score))
        self.last_bar[best] = i12

    def broker_exits(self, k):
        for s in list(self.pos):
            S = self.S[s]
            if np.isnan(S["o"][k]):
                continue
            p = self.pos[s]
            adj = S["spr"][k] * S["point"] if p["dir"] < 0 else 0.0
            o, h, l = S["o"][k] + adj, S["h"][k] + adj, S["l"][k] + adj
            if p["dir"] > 0:
                if l <= p["sl"]:
                    self.close(s, k, min(p["sl"], o), "SL")
                elif h >= p["tp"]:
                    self.close(s, k, max(p["tp"], o), "TP")
            else:
                if h >= p["sl"]:
                    self.close(s, k, max(p["sl"], o), "SL")
                elif l <= p["tp"]:
                    self.close(s, k, min(p["tp"], o), "TP")

    def run(self):
        n = len(self.T)
        t0 = time.time()
        for k in range(n):
            self.k = k
            for s in self.syms:
                o = self.S[s]["o"][k]
                if not np.isnan(o):
                    self.last_bid[s] = o
                    self.last_spr[s] = self.S[s]["spr"][k]
            self.monitor(k)
            self.try_open(k)
            self.broker_exits(k)
            for s in self.syms:
                c = self.S[s]["c"][k]
                if not np.isnan(c):
                    self.last_bid[s] = c
            self.equity[k] = self.balance + self.floating()
            if k % 100000 == 0 and k:
                self.log(f"    {pd.Timestamp(self.Tn[k]):%Y-%m-%d}  {k / n:5.1%}  餘額 {self.balance:,.0f}  "
                         f"({time.time() - t0:.0f}s)")
        self.close_all(n - 1, "END")
        self.equity[-1] = self.balance
        return self


# ---------------------------------------------------------------- 統計

def summarize(sim, name):
    d = pd.DataFrame(sim.deals)
    eq = sim.equity
    peak = np.maximum.accumulate(eq)
    dd = peak - eq
    i = int(np.argmax(dd))
    res = dict(name=name, deposit=sim.deposit, net=sim.balance - sim.deposit, trades=len(d),
               max_dd=float(dd[i]), max_dd_pct=float(dd[i] / peak[i] * 100) if peak[i] else 0.0)
    # FTMO 式檢查：相對初始資金的最大虧損、單日最大虧損（以伺服器日計）
    res["max_loss_pct"] = float((sim.deposit - eq.min()) / sim.deposit * 100)
    day = pd.Series(eq, index=pd.DatetimeIndex(sim.Tn)).resample("1D").agg(["first", "min"]).dropna()
    res["worst_day_pct"] = float(((day["first"] - day["min"]) / sim.deposit * 100).max()) if len(day) else 0.0
    if len(d):
        res["last_trade"] = str(pd.Timestamp(d["close_time"].max()))
    if len(d):
        gp = d.loc[d.profit > 0, "profit"].sum()
        gl = -d.loc[d.profit <= 0, "profit"].sum()
        res.update(gross_profit=gp, gross_loss=gl, pf=(gp / gl) if gl else float("inf"),
                   win=(d.profit > 0).mean() * 100, reasons=d["reason"].value_counts().to_dict(),
                   by_symbol=d.groupby("symbol")["profit"].agg(["count", "sum"]).round(2))
    return res, d


def fmt_summary(r):
    lines = [f"[{r['name']}]",
             f"  淨利          {r['net']:>12,.2f}",
             f"  獲利因子      {r.get('pf', 0):>12.2f}",
             f"  最大回撤      {r['max_dd']:>12,.2f}  ({r['max_dd_pct']:.2f}%)",
             f"  交易次數      {r['trades']:>12}   最後一筆 {r.get('last_trade', '-')}",
             f"  FTMO 檢查     最大虧損 {r['max_loss_pct']:.2f}% (限 10%)  單日最大虧損 {r['worst_day_pct']:.2f}% (限 5%)",
             f"  勝率          {r.get('win', 0):>11.1f}%"]
    if r.get("reasons"):
        lines.append("  平倉原因      " + ", ".join(f"{k}={v}" for k, v in sorted(r["reasons"].items())))
    if r.get("by_symbol") is not None:
        lines.append("  各商品（筆數 / 損益）")
        for s, row in r["by_symbol"].iterrows():
            lines.append(f"    {s:<8} {int(row['count']):>6}  {row['sum']:>12,.2f}")
    return "\n".join(lines)


# ---------------------------------------------------------------- ML 訓練資料（與 MLRecorder 同格式）

ML_NAMES = ["f_dir", "f_spread_pips", "f_score", "f_opp_score",
            "f_s_ema", "f_s_rsi", "f_s_bb", "f_s_macd", "f_s_stoch",
            "f_atr_pips", "f_ema_gap", "f_ema_slope", "f_close_ema",
            "f_rsi_dev", "f_rsi_chg", "f_bb_pos", "f_bb_width", "f_bb_width_chg",
            "f_macd", "f_macd_hist", "f_macd_hist_chg",
            "f_stoch_k_dev", "f_stoch_d_dev", "f_hour_sin", "f_hour_cos", "f_dow"]


def check_feature_names(src_dir):
    ea = open(os.path.join(src_dir, "MultiCurrency_EA.mq5"), encoding="utf-8-sig").read()
    blk = ea[ea.index("g_mlNames[ML_NF]"):]
    names = re.findall(r'"(f_\w+)"', blk[:blk.index("};")])
    if names != ML_NAMES:
        raise SystemExit("[錯誤] EA 的 g_mlNames 與 backtest.py 的 ML_NAMES 不一致，請同步修改")


def label_signal(t1, h1, l1, sp1, j0, sig_t, d, entry, sl, tp, point, hold_ns, chunk=720):
    """從 M1 第 j0 根開始往後找：先到 SL(0) / TP(1) / 逾時(2) / 資料結束(-1)。
    同一根同時碰到 SL 與 TP 視為 SL；賣單以 Ask(=Bid+點差) 判斷。與 MLRecorder 相同。"""
    n = len(t1)
    mfe = mae = 0.0
    j = j0
    while j < n:
        e = min(j + chunk, n)
        adj = sp1[j:e] * point if d < 0 else 0.0
        hi, lo = h1[j:e] + adj, l1[j:e] + adj
        if d > 0:
            hit_sl, hit_tp = lo <= sl, hi >= tp
            fav, adv = hi - entry, entry - lo
        else:
            hit_sl, hit_tp = hi >= sl, lo <= tp
            fav, adv = entry - lo, hi - entry
        timeout = (t1[j:e] - sig_t) >= hold_ns
        stop = hit_sl | hit_tp | timeout
        if stop.any():
            x = int(np.argmax(stop))
            mfe = max(mfe, float(fav[:x + 1].max()))
            mae = max(mae, float(adv[:x + 1].max()))
            lab = 0 if hit_sl[x] else (1 if hit_tp[x] else 2)
            return lab, j + x, j + x - j0 + 1, mfe, mae
        mfe = max(mfe, float(fav.max()))
        mae = max(mae, float(adv.max()))
        j = e
    return -1, None, n - j0, mfe, mae


def build_ml_rows(sim, s, max_hold_h, m1):
    S = sim.S[s]
    m12 = S["m12"]
    r = S["rule"]
    if r is None:
        return []
    ind = S["ind"]
    c = m12["close"].to_numpy()
    atr = sma(true_range(m12["high"].to_numpy(), m12["low"].to_numpy(), c), 14)
    idx = np.where(S["sig"] != 0)[0]
    T = sim.T
    o, spr = S["o"], S["spr"]
    has = np.zeros(len(T), dtype=bool)
    for a, b in sim.pos_intervals[s]:
        has[a:b] = True
    # 此商品自己的 M1（無缺值）供標記用
    t1 = m1["time"].to_numpy()
    h1, l1, sp1 = m1["high"].to_numpy(), m1["low"].to_numpy(), m1["spread"].to_numpy().astype(float)
    pip, point, dg = S["pip"], S["point"], S["digits"]
    slD, tpD = r["sl"] * pip, r["tp"] * pip
    hold_ns = np.timedelta64(int(max_hold_h * 3600), "s")
    rows = []
    first = m12["first_m1"].to_numpy()
    for i in idx:
        a_ = atr[i - 1] if i >= 1 else np.nan
        if np.isnan(a_) or a_ <= 0:
            continue
        k = T.searchsorted(first[i])
        if k >= len(T) or T[k] != first[i] or np.isnan(o[k]):
            continue
        d = int(S["sig"][i])
        bid = o[k]
        ask = bid + spr[k] * point
        entry = ask if d > 0 else bid
        sl, tp = entry - d * slD, entry + d * tpD
        g = lambda arr, sh: arr[i - sh] if i - sh >= 0 else np.nan   # noqa: E731
        ef0, ef1, es0 = g(ind["EF"], 1), g(ind["EF"], 2), g(ind["ES"], 1)
        r0, r1 = g(ind["R"], 1), g(ind["R"], 2)
        bm0 = g(ind["BM"], 1)
        bw0 = g(ind["BU"], 1) - g(ind["BL"], 1)
        bw1 = g(ind["BU"], 2) - g(ind["BL"], 2)
        m0, m1_ = g(ind["MM"], 1), g(ind["MM"], 2)
        h0 = m0 - g(ind["MS"], 1)
        h1_ = m1_ - g(ind["MS"], 2)
        k0, d0 = g(ind["SK"], 1), g(ind["SD"], 1)
        close = c[i - 1]
        bt = m12["time"].iloc[i]
        hr = 2 * np.pi * bt.hour / 24.0
        buy, sell = int(S["buy"][i]), int(S["sell"][i])
        f = [d, spr[k] * point / pip, buy if d > 0 else sell, sell if d > 0 else buy,
             *(S["sgn"][i] * d), a_ / pip,
             (ef0 - es0) / a_ * d, (ef0 - ef1) / a_ * d, (close - ef0) / a_ * d,
             (r0 - 50) * d, (r0 - r1) * d,
             ((close - bm0) / bw0 if bw0 > 0 else 0.0) * d, bw0 / a_, (bw0 / bw1 if bw1 > 0 else 1.0),
             m0 / a_ * d, h0 / a_ * d, (h0 - h1_) / a_ * d,
             (k0 - 50) * d, (d0 - 50) * d, np.sin(hr), np.cos(hr), (bt.dayofweek + 1) % 7]
        if any(np.isnan(x) for x in f):
            continue
        sig_t = T[k]
        j0 = int(np.searchsorted(t1, sig_t.to_datetime64(), side="right"))   # 下一根 M1 開始
        label, jo, bars, mfe, mae = label_signal(t1, h1, l1, sp1, j0, sig_t.to_datetime64(), d,
                                                 entry, sl, tp, point, hold_ns)
        out_t = pd.Timestamp(t1[jo]) if jo is not None else None
        vol_ok = True
        trp = S["tr_prev"][k]
        if not np.isnan(trp):
            vol_ok = trp / pip < r["atr"] * sim.c["VolatilityMultiplier"]
        rows.append([sig_t.strftime("%Y.%m.%d %H:%M:%S"), s, d,
                     round(entry, dg), round(sl, dg), round(tp, dg), int(has[k]), int(vol_ok),
                     *[float(f"{x:.6g}") for x in f],
                     label, out_t.strftime("%Y.%m.%d %H:%M") if out_t is not None else "", bars,
                     round(mfe / slD, 3), round(mae / slD, 3)])
    return rows


# ---------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser(description="MultiCurrency_EA Python 回測")
    ap.add_argument("--to", dest="end", default=None, help="結束日期 YYYY-MM-DD（預設今天）")
    ap.add_argument("--years", type=float, default=3, help="從結束日期往前幾年（預設 3）")
    ap.add_argument("--from", dest="start", default=None, help="開始日期 YYYY-MM-DD（預設 = 結束日期 - years）")
    ap.add_argument("--mode", choices=["both", "fixed", "legacy"], default="both",
                    help="both=舊邏輯與修正後並列（預設）")
    ap.add_argument("--deposit", type=float, default=10000, help="初始資金（預設 10000）")
    ap.add_argument("--commission", type=float, default=5.0, help="每手來回手續費 USD（預設 5）")
    ap.add_argument("--local-tz", default="Asia/Taipei", help="你電腦的時區（EA 的 TimeLocal）")
    ap.add_argument("--server-ny-offset", type=float, default=7,
                    help="伺服器時間 = 紐約時間 + N 小時（FTMO 為 7）")
    ap.add_argument("--src", default=os.path.dirname(HERE), help="EA 原始碼資料夾")
    ap.add_argument("--cache", required=True, help="M1 資料快取資料夾（例如 H:\\...\\export\\bars）")
    ap.add_argument("--out", required=True, help="報告輸出資料夾（例如 H:\\...\\tester_reports）")
    ap.add_argument("--features-out", default=None, help="ML 訓練資料輸出資料夾（例如 H:\\...\\ml\\features）")
    ap.add_argument("--terminal", default=None, help="terminal64.exe 路徑（有多個 MT5 時指定）")
    ap.add_argument("--refresh", action="store_true", help="重新下載 M1 資料")
    ap.add_argument("--equity-floor", type=float, default=None,
                    help="覆寫 FilterLib 的淨值下限 AccountEquityFloor（EA 寫死 9600；填 0 = 停用）")
    ap.add_argument("--day-loss", type=float, default=None,
                    help="覆寫單日虧損上限 DayLossLimit（EA 寫死 -350；例如 -5000）")
    args = ap.parse_args()

    cfg = parse_sources(args.src)
    if args.equity_floor is not None:
        cfg["c"]["AccountEquityFloor"] = args.equity_floor
    if args.day_loss is not None:
        cfg["c"]["DayLossLimit"] = args.day_loss
    check_feature_names(args.src)
    end = dt.datetime.fromisoformat(args.end) if args.end else \
        dt.datetime.combine(dt.date.today(), dt.time())
    start = dt.datetime.fromisoformat(args.start) if args.start else \
        end - dt.timedelta(days=round(args.years * 365.25))
    args.start, args.end = start.date().isoformat(), end.date().isoformat()
    warm = start - dt.timedelta(days=20)             # 指標暖機

    print(f"商品: {', '.join(cfg['symbols'])}   MinConfirm={cfg['min_conf']}  MaxPos={cfg['max_pos']}")
    print("讀取 / 下載 M1 資料 ...")
    data = fetch_m1(cfg["symbols"], warm, end, args.cache, args.terminal, args.refresh)
    for s in cfg["symbols"]:
        if s not in cfg["rules"]:
            print(f"⚠️ {s} 在 FilterLib fx_rules 沒有規則，EA 不會交易它")

    stamp = dt.datetime.now().strftime("%Y%m%d_%H%M%S")
    out_dir = os.path.join(args.out, f"py_{args.start}_{args.end}_{stamp}")
    os.makedirs(out_dir, exist_ok=True)
    modes = ["legacy", "fixed"] if args.mode == "both" else [args.mode]
    report = [f"Python 回測  {args.start} ~ {args.end}  初始資金 {args.deposit:,.0f}  "
              f"手續費 {args.commission}/手  本機時區 {args.local_tz}",
              f"淨值下限 {cfg['c']['AccountEquityFloor']:,.0f}  單日虧損上限 {cfg['c']['DayLossLimit']:,.0f}", ""]
    for mode in modes:
        name = "A 舊邏輯 (Inp_LegacySignalOrder=true)" if mode == "legacy" else "B 修正後 (v5.3)"
        print(f"\n=== 模擬 {name} ===")
        sim = Sim(cfg, data, mode == "legacy", args.deposit, args.commission,
                  args.local_tz, args.server_ny_offset, print, start, end)
        sim.run()
        res, deals = summarize(sim, name)
        deals.to_csv(os.path.join(out_dir, f"trades_{mode}.csv"), index=False)
        pd.DataFrame({"time": sim.T, "equity": sim.equity}).iloc[::60].to_csv(
            os.path.join(out_dir, f"equity_{mode}.csv"), index=False)
        txt = fmt_summary(res)
        print(txt)
        report += [txt, ""]

        if mode == "fixed" and args.features_out:
            print("產生 ML 訓練資料 ...")
            rows = []
            for s in sim.syms:
                rows += build_ml_rows(sim, s, cfg["max_hold"], data[s][0])
            cols = (["signal_time", "symbol", "dir", "entry", "sl", "tp", "has_pos", "vol_ok"] + ML_NAMES +
                    ["label", "outcome_time", "bars_held", "mfe_r", "mae_r"])
            ml = pd.DataFrame(rows, columns=cols).sort_values("signal_time")
            os.makedirs(args.features_out, exist_ok=True)
            fpath = os.path.join(args.features_out, f"features_py_{args.start}_{args.end}.csv")
            ml.to_csv(fpath, index=False)
            vc = ml["label"].value_counts().to_dict()
            msg = (f"ML 訓練資料: {fpath}\n  {len(ml)} 筆  TP={vc.get(1, 0)} SL={vc.get(0, 0)} "
                   f"逾時={vc.get(2, 0)} 未結束={vc.get(-1, 0)}")
            print(msg)
            report += [msg, ""]

    with open(os.path.join(out_dir, "report.txt"), "w", encoding="utf-8") as f:
        f.write("\n".join(report) + "\n")
    print(f"\n報告與交易明細: {out_dir}")


if __name__ == "__main__":
    main()
