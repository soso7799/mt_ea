# -*- coding: utf-8 -*-
"""
strategy_test.py —— 用 merged 資料夾的完整歷史 K 棒，比較多種進出場規則 × 多組參數（含點差成本）

資料：ExportCSV\\merged\\{商品}_{週期}_MERGED_ALL_DATA.csv（datetime,open,high,low,close,volume）
點差：build_extra_tables.py 從 MT5 寫出的 update_output\\spreads.csv；沒有就用價格的 0.01%

防止「參數挑到剛好好看」：每個商品×週期把歷史切成前 70%（挑參數）和後 30%（驗證）。
每種規則只在前 70% 挑出最好的那組參數，再看它在「沒看過」的後 30% 表現。
判定「有效」：前70%、後30% 都賺，後30% 獲利因子 >= 1.2，且後30% 平均報酬 t 值 >= 2.5（排除運氣）。

規則（全部是 K 棒收盤出訊號、下一根開盤進場，不偷看未來）：
  S0 投票翻邊        ：目前儀表板的 11 指標多數決，翻邊就反手（對照組，無參數）
  S1 順勢投票        ：投票方向與 EMA(n) 方向一致才持有；n = 50 / 100 / 200
  S2 投票+停損停利   ：投票翻邊進場；停損 1/1.5/2 ATR × 停利 1.5/2/3 ATR；可加 EMA200 順勢過濾
  S3 前日高低突破    ：收盤突破前一日高做多 / 跌破前一日低做空（只測 H1）；停損停利同 S2，換日平倉
  S4 均線交叉        ：EMA 快慢線交叉就反手；(10,30) / (20,50) / (50,200)
  S5 通道突破        ：收盤突破前 N 根最高做多、跌破前 N 根最低做空，反向 N/2 通道出場；N = 20 / 55
  S6 關卡突破+量+多空：H1/M15 收盤突破 亞/歐/美盤高低、今日高低、前日高低（當下已知的關卡）順勢進場；
                      過濾：成交量 >= 前 20 根平均 1 / 1.5 / 2 倍 × 是否要求 11 指標多空同向；停損 1/1.5 × 停利 1.5/2/3 ATR
  S7 關卡反轉+量+多空：同上關卡，盤中刺破但收盤收回（假突破）就反向進場；過濾與出場同 S6
  ── 11 指標分組（趨勢組：MA/MACD/MTM/布林/BIAS/Keltner；震盪組：RSI/KD/威廉/CCI/PSY，震盪組要反著用）──
  S8  趨勢組同向持有    ：趨勢組 6 個至少 4/5/6 個同向就持有，不夠就空手
  S9  趨勢方向+震盪拉回 ：價在 EMA100/200 之上時，等震盪組 2/3 個「超賣」才買（空方相反）；停損停利 ATR
  S10 盤整震盪反轉      ：ADX < 20/25（盤整）時，震盪組 2/3 個超賣買、超買賣；停損停利 ATR
  S11 趨勢順勢進場      ：ADX >= 20/25（有趨勢）時，趨勢組剛轉成 4/5 個同向就順勢進場；停損停利 ATR
  S12 抵銷後淨票數      ：多票減空票後的淨差夠大才判多空（原本儀表板等於淨差 >= 1）
                        原 11 票淨差 >= 3/5/7；分組算法（趨勢組順向＋震盪組反向）淨差 >= 2/3/4
                        兩種用法：淨差達標就持有 / 剛達標時進場＋停損停利 ATR
  ── 使用者的 MT5 指標（照原始碼移植）──
  S13 TAI 動能          ：TAI_Color_Panel_Optimized v2.60；藍＝多頭動能、紅＝空頭動能
                        用法：有色就持有 / 「啟動」（第 1 根變色）進場 / 「延續」（連 2 根同色）進場＋停損停利
                        參數：MA 14/28 × TAI 週期 5/10（其餘照指標預設）
  S14 趨勢線突破        ：Trendline Signal FAST v2.10；已確認擺動點連線，陽線突破下降壓力線做多、陰線跌破上升支撐線做空
                        擺動左右 3/5 根 × 過濾（不過濾 / TAI 同向 / TAI 不反向 / 分組淨票同向）× 停損停利

輸出：
  update_output\\strategy_test.csv      每個 商品×週期×規則：最佳參數、前70%/後30% 成績、判定
  update_output\\strategy_test_all.csv  每一組參數的全期成績（給想細看的人）

用法：按 Excel「更新關卡」時由 build_extra_tables.py 自動執行；24 小時內跑過就不重跑。
手動重跑：python strategy_test.py
"""
import csv
import glob
import os
import sys
import time

import numpy as np
import pandas as pd

OUT_DIR = r"G:\我的雲端硬碟\整理後\update_output"
MERGED_DIRS = [r"G:\我的雲端硬碟\整理後\ExportCSV\merged", r"G:\我的雲端硬碟\ExportCSV\merged"]
TFS = ["D1", "H4", "H1", "M15"]
MAX_BARS = {"D1": 6000, "H4": 20000, "H1": 30000, "M15": 40000}   # 每個週期最多用最近幾根（控制執行時間）
LEVEL_TFS = ("H1", "M15")        # 關卡突破/反轉只測日內週期
SESSIONS = {"亞": (3, 12), "歐": (10, 19), "美": (16, 24)}   # FTMO 伺服器時間，跟 make_levels.py 一樣
VOL_K = [1.0, 1.5, 2.0]          # 成交量 >= 前 20 根平均的幾倍（1.0 = 不過濾）
LVL_SL, LVL_TP = [1.0, 1.5], [1.5, 2.0, 3.0]
VERSION = "5"                    # 規則有改就換版本，會強制重跑
TREND_K = [4, 5]                 # 趨勢組 6 個指標至少幾個同方向
OSC_M = [2, 3]                   # 震盪組 5 個指標至少幾個同時超買/超賣
ADX_LV = [20, 25]                # ADX 低於＝盤整、高於＝趨勢
GRP_SL, GRP_TP = [1.5, 2.0], [2.0, 3.0]
NET_TH_11 = [3, 5, 7]            # 原 11 票：多票-空票 淨差門檻（原本儀表板等於門檻 1）
NET_TH_GRP = [2, 3, 4]           # 分組算法淨差門檻（趨勢組順向 + 震盪組反向，範圍 -11~+11）
# TAI_Color_Panel_Optimized（v2.60）參數組合：(MA 週期, TAI 週期)；其餘照指標預設
TAI_SETS = [(28, 5), (14, 5), (28, 10), (14, 10)]
TAI_BOOST, TAI_FL, TAI_UP, TAI_DN, TAI_ATR, TAI_ATR_MULT = 0.35, 50, 80.0, 20.0, 14, 1.0
# Trendline Signal FAST（v2.10）參數：擺動左右根數
TL_LR = [3, 5]
TL_DEPTH = 400                   # 往回找擺動點的最大根數（指標 MaxBarsToScan+SwingSearchDepth）
SPLIT = 0.70
MIN_TRADES_IS, MIN_TRADES_OOS = 30, 20
RERUN_HOURS = 24
SL_LIST, TP_LIST = [1.0, 1.5, 2.0], [1.5, 2.0, 3.0]
T_MIN = 2.5              # 後30% 平均報酬 t 值門檻（隨機資料校準過）


# ------------------------------------------------------------------ 指標
def ema(s, n):
    return s.ewm(span=n, adjust=False).mean()


def vote_series(df, return_net=False):
    """跟 build_extra_tables.py / 儀表板一樣的 11 指標投票：+1 多 / -1 空 / 0 無"""
    c, h, l = df["close"], df["high"], df["low"]
    sig = {}
    sig["MA"] = np.sign(c.rolling(8).mean() - c.rolling(50).mean())
    d = c.diff()
    ag = d.clip(lower=0).ewm(alpha=1 / 14, adjust=False).mean()
    al = (-d.clip(upper=0)).ewm(alpha=1 / 14, adjust=False).mean()
    rsi = 100 - 100 / (1 + ag / al.replace(0, np.nan))
    sig["RSI"] = np.sign(rsi - 50)
    ll, hh = l.rolling(9).min(), h.rolling(9).max()
    k = ((c - ll) / (hh - ll).replace(0, np.nan) * 100).ewm(alpha=1 / 3, adjust=False).mean()
    sig["KD"] = np.sign(k - k.ewm(alpha=1 / 3, adjust=False).mean())
    sig["PSY"] = np.sign((d > 0).astype(float).rolling(12).sum() / 12 * 100 - 50)
    hw, lw = h.rolling(14).max(), l.rolling(14).min()
    sig["WR"] = np.sign((hw - c) / (hw - lw).replace(0, np.nan) * -100 + 50)
    sig["MTM"] = np.sign(c.diff(10))
    macd = ema(c, 12) - ema(c, 26)
    sig["MACD"] = np.sign(macd - ema(macd, 9))
    sig["BOLL"] = np.sign(c - c.rolling(20).mean())
    tp = (h + l + c) / 3
    md = tp.rolling(14).apply(lambda x: np.mean(np.abs(x - x.mean())), raw=True)
    sig["CCI"] = np.sign((tp - tp.rolling(14).mean()) / (0.015 * md.replace(0, np.nan)))
    sig["BIAS"] = np.sign(c - c.rolling(20).mean())
    sig["KELTNER"] = np.sign(c - ema(c, 20))
    m = pd.DataFrame(sig)
    longs, shorts = (m > 0).sum(axis=1), (m < 0).sum(axis=1)
    pos = np.where(longs > shorts, 1, np.where(shorts > longs, -1, 0))
    pos[m.isna().any(axis=1).values] = 0
    if return_net:
        net = (longs - shorts).values.astype(int)
        net[m.isna().any(axis=1).values] = 0
        return pos, net
    return pos


def indicator_groups(df):
    """11 指標分兩組：
       趨勢組（方向）：MA、MACD、MTM、布林(價在中軌上/下)、BIAS、Keltner → 各 +1/-1，回傳 多票數, 空票數
       震盪組（超買超賣，要反著用）：RSI<30、K<20、威廉%R<-80、CCI<-100、PSY<25 算超賣；反之算超買
       另外回傳 ADX(14)（>=門檻＝有趨勢，<門檻＝盤整）"""
    c, h, l = df["close"], df["high"], df["low"]
    tr = {}
    tr["MA"] = np.sign(c.rolling(8).mean() - c.rolling(50).mean())
    macd = ema(c, 12) - ema(c, 26)
    tr["MACD"] = np.sign(macd - ema(macd, 9))
    tr["MTM"] = np.sign(c.diff(10))
    tr["BOLL"] = np.sign(c - c.rolling(20).mean())
    tr["BIAS"] = np.sign(c - c.rolling(50).mean())
    tr["KELTNER"] = np.sign(c - ema(c, 20))
    t = pd.DataFrame(tr)
    t_long, t_short = (t > 0).sum(axis=1).values, (t < 0).sum(axis=1).values
    t_ok = ~t.isna().any(axis=1).values

    d = c.diff()
    ag = d.clip(lower=0).ewm(alpha=1 / 14, adjust=False).mean()
    al = (-d.clip(upper=0)).ewm(alpha=1 / 14, adjust=False).mean()
    rsi = 100 - 100 / (1 + ag / al.replace(0, np.nan))
    ll, hh = l.rolling(9).min(), h.rolling(9).max()
    k = ((c - ll) / (hh - ll).replace(0, np.nan) * 100).ewm(alpha=1 / 3, adjust=False).mean()
    hw, lw = h.rolling(14).max(), l.rolling(14).min()
    wr = (hw - c) / (hw - lw).replace(0, np.nan) * -100
    tp = (h + l + c) / 3
    md = tp.rolling(14).apply(lambda x: np.mean(np.abs(x - x.mean())), raw=True)
    cci = (tp - tp.rolling(14).mean()) / (0.015 * md.replace(0, np.nan))
    psy = (d > 0).astype(float).rolling(12).sum() / 12 * 100
    oversold = ((rsi < 30).astype(int) + (k < 20).astype(int) + (wr < -80).astype(int)
                + (cci < -100).astype(int) + (psy < 25).astype(int)).values
    overbought = ((rsi > 70).astype(int) + (k > 80).astype(int) + (wr > -20).astype(int)
                  + (cci > 100).astype(int) + (psy > 75).astype(int)).values

    up, dn = h.diff(), -l.diff()
    pdm = np.where((up > dn) & (up > 0), up, 0.0)
    ndm = np.where((dn > up) & (dn > 0), dn, 0.0)
    trr = pd.concat([h - l, (h - c.shift()).abs(), (l - c.shift()).abs()], axis=1).max(axis=1)
    atr_ = trr.ewm(alpha=1 / 14, adjust=False).mean()
    pdi = 100 * pd.Series(pdm, index=df.index).ewm(alpha=1 / 14, adjust=False).mean() / atr_
    ndi = 100 * pd.Series(ndm, index=df.index).ewm(alpha=1 / 14, adjust=False).mean() / atr_
    dx = 100 * (pdi - ndi).abs() / (pdi + ndi).replace(0, np.nan)
    adx = dx.ewm(alpha=1 / 14, adjust=False).mean().fillna(0).values
    return t_long, t_short, t_ok, oversold, overbought, adx


def tai_color(df, ma_period=28, tai_period=5, boost=TAI_BOOST, fl_period=TAI_FL,
              lv_up=TAI_UP, lv_dn=TAI_DN, atr_period=TAI_ATR, atr_mult=TAI_ATR_MULT):
    """移植 TAI_Color_Panel_Optimized.mq5 v2.60（逐根、只用當根以前資料）
       回傳 color[i]：1＝多頭動能（藍）、2＝空頭動能（紅）、0＝無（灰）"""
    c, h, l = df["close"].values, df["high"].values, df["low"].values
    n = len(c)
    avg = pd.Series(c).ewm(span=ma_period, adjust=False).mean().values        # iMA EMA
    tr = np.maximum(h - l, np.maximum(abs(h - np.r_[c[0], c[:-1]]), abs(l - np.r_[c[0], c[:-1]])))
    atr_ = pd.Series(tr).rolling(atr_period).mean().fillna(0).values           # iATR（SMA）
    fast = np.empty(n)
    fast[0] = avg[0]
    fast[1:] = avg[1:] + boost * (avg[1:] - avg[:-1])
    val = np.zeros(n)
    for i in range(tai_period, n):
        w = fast[i - tai_period + 1:i + 1]
        d = 1.0 if fast[i] >= fast[i - 1] else -1.0
        val[i] = 100.0 * d * (w.max() - w.min()) / abs(c[i]) if abs(c[i]) > 1e-12 else 0.0
    col = np.zeros(n, dtype=int)
    vs = pd.Series(val)
    vmin = vs.rolling(fl_period).min().values
    vmax = vs.rolling(fl_period).max().values
    for i in range(tai_period + fl_period, n):
        rng = max(vmax[i] - vmin[i], 1e-12)
        vol = min(0.20, (atr_[i] / abs(c[i]) if abs(c[i]) > 1e-12 else 0.0) * atr_mult * 10.0)
        up = vmin[i] + rng * min(95.0, lv_up + vol * 25.0) * 0.01
        dn = vmin[i] + rng * max(5.0, lv_dn - vol * 25.0) * 0.01
        if val[i] > up and val[i] > val[i - 1]:
            col[i] = 1
        elif val[i] < dn and val[i] < val[i - 1]:
            col[i] = 2
    return col


def tai_streak(col):
    """面板邏輯：連續同色根數（>=2＝動能延續、1＝動能啟動），多為正、空為負"""
    out, run = [0] * len(col), 0
    for i, x in enumerate(col):
        if x == 1:
            run = run + 1 if run > 0 else 1
        elif x == 2:
            run = run - 1 if run < 0 else -1
        else:
            run = 0
        out[i] = run
    return out


def trendline_signals(df, lr=3, depth=TL_DEPTH, need_dir_bar=True, need_slope=True):
    """移植 Trendline Signal FAST V2.10：
       用「訊號 K 收盤時已確認」的最近兩個擺動高點連成壓力線、兩個擺動低點連成支撐線；
       壓力線向下（新高點較低）且陽線收盤由線下突破到線上 → +1；
       支撐線向上（新低點較高）且陰線收盤由線上跌破到線下 → -1。"""
    o, h, l, c = (df[k].values for k in ("open", "high", "low", "close"))
    t = df["datetime"].values.astype("datetime64[s]").astype(np.int64).astype(float)
    n = len(c)
    sh, sl_ = [], []                       # 擺動點（依時間先後）
    for j in range(lr, n - lr):
        if all(h[j] > h[j + k] for k in range(1, lr + 1)) and all(h[j] >= h[j - k] for k in range(1, lr + 1)):
            sh.append(j)
        if all(l[j] < l[j + k] for k in range(1, lr + 1)) and all(l[j] <= l[j - k] for k in range(1, lr + 1)):
            sl_.append(j)

    def line(j_old, j_new, p_old, p_new, tt):
        if t[j_new] == t[j_old]:
            return p_new
        return p_old + (p_new - p_old) * (tt - t[j_old]) / (t[j_new] - t[j_old])

    sig = [0] * n
    ih = il = 0
    for s in range(1, n):
        lim = s - lr                        # 擺動點 j 需 j <= s-lr 才算已確認
        while ih < len(sh) and sh[ih] <= lim:
            ih += 1
        while il < len(sl_) and sl_[il] <= lim:
            il += 1
        if ih >= 2:
            jn, jo = sh[ih - 1], sh[ih - 2]
            if s - jo <= depth + lr and (not need_slope or h[jn] < h[jo]) and (not need_dir_bar or c[s] > o[s]):
                if c[s - 1] <= line(jo, jn, h[jo], h[jn], t[s - 1]) and c[s] > line(jo, jn, h[jo], h[jn], t[s]):
                    sig[s] = 1
        if il >= 2 and sig[s] == 0:
            jn, jo = sl_[il - 1], sl_[il - 2]
            if s - jo <= depth + lr and (not need_slope or l[jn] > l[jo]) and (not need_dir_bar or c[s] < o[s]):
                if c[s - 1] >= line(jo, jn, l[jo], l[jn], t[s - 1]) and c[s] < line(jo, jn, l[jo], l[jn], t[s]):
                    sig[s] = -1
    return sig


def atr(df, n=14):
    h, l, c = df["high"], df["low"], df["close"]
    tr = pd.concat([h - l, (h - c.shift()).abs(), (l - c.shift()).abs()], axis=1).max(axis=1)
    return tr.ewm(alpha=1 / n, adjust=False).mean().values


# ------------------------------------------------------------------ 交易引擎（回傳 [(出場索引, 報酬%)]）
def run_position(o, want, cost_frac):
    """want[i]：第 i 根收盤後想要的部位，第 i+1 根開盤執行"""
    out, cur, entry = [], 0, 0.0
    for i in range(len(o) - 1):
        w = want[i]
        if w == cur:
            continue
        px = o[i + 1]
        if cur != 0:
            out.append((i + 1, cur * (px - entry) / entry * 100 - cost_frac * 100))
        cur, entry = w, px
    return out


def run_sl_tp(o, h, l, c, a, days, sig, sl_k, tp_k, cost_frac, day_exit=False):
    out, i, n = [], 0, len(o)
    while i < n - 1:
        s = sig[i]
        if s == 0 or a[i] != a[i]:
            i += 1
            continue
        e = o[i + 1]
        sl, tp = e - s * sl_k * a[i], e + s * tp_k * a[i]
        j, px = i + 1, None
        while j < n:
            if s > 0:
                if l[j] <= sl:
                    px = sl
                elif h[j] >= tp:
                    px = tp
            else:
                if h[j] >= sl:
                    px = sl
                elif l[j] <= tp:
                    px = tp
            if px is None and day_exit and j + 1 < n and days[j + 1] != days[j]:
                px = c[j]
            if px is not None:
                break
            j += 1
        if px is None:
            j, px = n - 1, c[n - 1]
        out.append((j, s * (px - e) / e * 100 - cost_frac * 100))
        i = j + 1
    return out


# ------------------------------------------------------------------ 訊號
def flips(vote):
    f = [0] * len(vote)
    for i in range(1, len(vote)):
        if vote[i] != vote[i - 1] and vote[i] != 0:
            f[i] = int(vote[i])
    return f


def breakout_signals(df):
    d = df["datetime"].dt.date
    daily = df.groupby(d).agg(hi=("high", "max"), lo=("low", "min")).shift(1)
    phi, plo = d.map(daily["hi"]).values, d.map(daily["lo"]).values
    c, dv = df["close"].values, d.values
    sig, fired = [0] * len(df), {}
    for i in range(len(df)):
        if phi[i] != phi[i]:
            continue
        f = fired.setdefault(dv[i], set())
        if c[i] > phi[i] and 1 not in f:
            sig[i] = 1
            f.add(1)
        elif c[i] < plo[i] and -1 not in f:
            sig[i] = -1
            f.add(-1)
    return sig


def level_events(df):
    """逐根算出「當下已知」的關卡（只用到前一根為止的資料，不偷看）：
       亞/歐/美盤高低（今天該時段已開始且有資料用今天的，否則用最近一次的）、今日高低、前日高低。
       回傳 brk[i]：收盤向上突破某個高點類關卡 +1、向下跌破某個低點類關卡 -1
            rev[i]：盤中刺破高點類關卡但收回下方 -1、刺破低點類關卡但收回上方 +1"""
    t = df["datetime"]
    days, hours = t.dt.date.tolist(), t.dt.hour.tolist()
    o, h, l, c = (df[k].tolist() for k in ("open", "high", "low", "close"))
    n = len(df)
    brk, rev = [0] * n, [0] * n
    last_sess, cur_sess = {}, {}
    day_hi = day_lo = None
    prev_hi = prev_lo = None
    cur_day = None
    for i in range(n):
        if days[i] != cur_day:
            if cur_day is not None:
                for k, v in cur_sess.items():
                    last_sess[k] = v
                prev_hi, prev_lo = day_hi, day_lo
            cur_day, cur_sess, day_hi, day_lo = days[i], {}, None, None
        if i > 0:
            highs, lows = [], []
            for k in SESSIONS:
                v = cur_sess.get(k) or last_sess.get(k)
                if v:
                    highs.append(v[0])
                    lows.append(v[1])
            if day_hi is not None:
                highs.append(day_hi)
                lows.append(day_lo)
            if prev_hi is not None:
                highs.append(prev_hi)
                lows.append(prev_lo)
            pc = c[i - 1]
            up = any(pc <= L < c[i] for L in highs)
            dn = any(pc >= L > c[i] for L in lows)
            if up != dn:
                brk[i] = 1 if up else -1
            r_dn = any(pc < L < h[i] and c[i] < L for L in highs)
            r_up = any(pc > L > l[i] and c[i] > L for L in lows)
            if r_dn != r_up:
                rev[i] = -1 if r_dn else 1
        # 把第 i 根納入今天的統計
        day_hi = h[i] if day_hi is None else max(day_hi, h[i])
        day_lo = l[i] if day_lo is None else min(day_lo, l[i])
        for k, (a_, z_) in SESSIONS.items():
            if a_ <= hours[i] < z_:
                v = cur_sess.get(k)
                cur_sess[k] = (h[i], l[i]) if v is None else (max(v[0], h[i]), min(v[1], l[i]))
    return brk, rev


def volume_ratio(df):
    v = df["volume"].astype(float) if "volume" in df.columns else pd.Series(np.ones(len(df)))
    avg = v.rolling(20).mean().shift(1)
    return (v / avg.replace(0, np.nan)).fillna(0).tolist()


def donchian_want(df, n):
    hi_n = df["high"].rolling(n).max().shift(1).values
    lo_n = df["low"].rolling(n).min().shift(1).values
    hi_x = df["high"].rolling(n // 2).max().shift(1).values
    lo_x = df["low"].rolling(n // 2).min().shift(1).values
    c = df["close"].values
    want, cur = [0] * len(df), 0
    for i in range(len(df)):
        if hi_n[i] != hi_n[i]:
            continue
        if cur == 1 and c[i] < lo_x[i]:
            cur = 0
        elif cur == -1 and c[i] > hi_x[i]:
            cur = 0
        if c[i] > hi_n[i]:
            cur = 1
        elif c[i] < lo_n[i]:
            cur = -1
        want[i] = cur
    return want


# ------------------------------------------------------------------ 統計
def stats(rets):
    n = len(rets)
    if n == 0:
        return dict(n=0, win=0.0, avg=0.0, total=0.0, pf=0.0, streak=0, t=0.0)
    r = np.array(rets)
    w, lo = r[r > 0].sum(), -r[r < 0].sum()
    streak = best = 0
    for x in r:
        streak = streak + 1 if x <= 0 else 0
        best = max(best, streak)
    pf = w / lo if lo > 0 else (99.0 if w > 0 else 0.0)
    sd = r.std(ddof=1) if n > 1 else 0.0
    t = r.mean() / (sd / np.sqrt(n)) if sd > 0 else 0.0     # 平均報酬的 t 值（>=2 才算不是運氣）
    return dict(n=n, win=(r > 0).mean() * 100, avg=r.mean(), total=r.sum(), pf=pf, streak=best, t=t)


def split_stats(trades, cut):
    is_r = [r for j, r in trades if j < cut]
    oos_r = [r for j, r in trades if j >= cut]
    return stats([r for _, r in trades]), stats(is_r), stats(oos_r)


def verdict(is_s, oos):
    """有效＝前70%和後30%都賺，且後30%的 t 值 >= T_MIN（隨機資料很難做到）"""
    if is_s["n"] < MIN_TRADES_IS or oos["n"] < MIN_TRADES_OOS:
        return "樣本不足"
    if is_s["avg"] > 0 and oos["avg"] > 0 and oos["pf"] >= 1.2 and oos["t"] >= T_MIN:
        return "有效"
    if is_s["avg"] > 0 and oos["avg"] > 0 and oos["pf"] > 1:
        return "可能有效（統計上不夠強）"
    return "無效"


# ------------------------------------------------------------------ 主程式
def find_merged_dir():
    for d in MERGED_DIRS:
        if os.path.isdir(d) and glob.glob(os.path.join(d, "*_MERGED_ALL_DATA.csv")):
            return d
    return None


def load_spreads():
    path = os.path.join(OUT_DIR, "spreads.csv")
    sp = {}
    if os.path.exists(path):
        with open(path, encoding="utf-8-sig", newline="") as f:
            for r in csv.DictReader(f):
                try:
                    sp[r["Symbol"].strip()] = float(r["Spread"])
                except (KeyError, ValueError):
                    pass
    return sp


def load(path, tf):
    df = pd.read_csv(path, encoding="utf-8-sig", thousands=",", dtype=str)
    df.columns = [c.strip().lower() for c in df.columns]
    for col in ("open", "high", "low", "close", "volume"):      # 成交量可能有千分位逗號 "2,694"
        if col in df.columns:
            df[col] = pd.to_numeric(df[col].str.replace(",", "", regex=False), errors="coerce")
    if "volume" in df.columns:
        df["volume"] = df["volume"].fillna(0)
    df["datetime"] = pd.to_datetime(df["datetime"], errors="coerce")
    df = df.dropna(subset=["datetime", "open", "high", "low", "close"]).sort_values("datetime")
    df = df.drop_duplicates("datetime").tail(MAX_BARS[tf]).reset_index(drop=True)
    return df


def test_series(sym, tf, df, spread):
    o, h, l, c = (df[k].tolist() for k in ("open", "high", "low", "close"))
    a = atr(df).tolist()
    days = df["datetime"].dt.date.tolist()
    price = float(np.median(df["close"].values))
    cost_frac = (spread / price) if spread else 0.0001
    cut = int(len(df) * SPLIT)
    vote = [int(x) for x in vote_series(df)]
    fl = flips(vote)
    close = df["close"]
    trend = {n: [1 if x > m else -1 for x, m in zip(close, ema(close, n))] for n in (50, 100, 200)}
    for n in trend:
        trend[n][:n] = [0] * min(n, len(df))

    fams = {}
    fams["S0 投票翻邊"] = {"—": run_position(o, vote, cost_frac)}
    fams["S1 順勢投票"] = {f"EMA{n}": run_position(o, [v if v == t else 0 for v, t in zip(vote, trend[n])], cost_frac)
                           for n in (50, 100, 200)}
    s2 = {}
    for filt in (False, True):
        sig = [f if (not filt or f == trend[200][i]) else 0 for i, f in enumerate(fl)]
        for sl in SL_LIST:
            for tp in TP_LIST:
                key = f"SL{sl}/TP{tp}" + ("+EMA200" if filt else "")
                s2[key] = run_sl_tp(o, h, l, c, a, days, sig, sl, tp, cost_frac)
    fams["S2 投票+停損停利"] = s2
    if tf == "H1":
        bsig = breakout_signals(df)
        fams["S3 前日高低突破"] = {f"SL{sl}/TP{tp}": run_sl_tp(o, h, l, c, a, days, bsig, sl, tp, cost_frac, True)
                                  for sl in SL_LIST for tp in TP_LIST}
    s4 = {}
    for f_, s_ in ((10, 30), (20, 50), (50, 200)):
        want = [1 if x > y else -1 for x, y in zip(ema(close, f_), ema(close, s_))]
        want[:s_] = [0] * min(s_, len(df))
        s4[f"EMA{f_}/{s_}"] = run_position(o, want, cost_frac)
    fams["S4 均線交叉"] = s4
    fams["S5 通道突破"] = {f"N{n}": run_position(o, donchian_want(df, n), cost_frac) for n in (20, 55)}
    # ---- 分組後的新規則 ----
    tl, ts, tok, osd, obt, adx = indicator_groups(df)
    n_ = len(df)
    fams["S8 趨勢組同向持有"] = {}
    for kk in TREND_K + [6]:
        want = [(1 if tl[i] >= kk else -1 if ts[i] >= kk else 0) if tok[i] else 0 for i in range(n_)]
        fams["S8 趨勢組同向持有"][f"{kk}/6同向"] = run_position(o, want, cost_frac)
    s9, s10, s11 = {}, {}, {}
    for en in (100, 200):
        for mm in OSC_M:
            # 大趨勢用慢速 EMA 判斷（快速趨勢指標在回檔時會跟著翻，不能用）：
            # 價在 EMA 上 → 等震盪組「超賣」才買（順勢買回檔）；價在 EMA 下 → 等「超買」才賣
            sig = [(1 if trend[en][i] == 1 and osd[i] >= mm else -1 if trend[en][i] == -1 and obt[i] >= mm else 0)
                   for i in range(n_)]
            for sl in GRP_SL:
                for tp_ in GRP_TP:
                    s9[f"EMA{en}方向+震盪{mm}/5反向+SL{sl}/TP{tp_}"] = run_sl_tp(o, h, l, c, a, days, sig, sl, tp_, cost_frac)
    for lv in ADX_LV:
        for mm in OSC_M:
            # ADX 低（盤整）：震盪組超賣買、超買賣
            sig = [(1 if osd[i] >= mm else -1 if obt[i] >= mm else 0) if adx[i] < lv else 0 for i in range(n_)]
            for sl in GRP_SL:
                for tp_ in GRP_TP:
                    s10[f"ADX<{lv}+震盪{mm}/5+SL{sl}/TP{tp_}"] = run_sl_tp(o, h, l, c, a, days, sig, sl, tp_, cost_frac)
        for kk in TREND_K:
            # ADX 高（有趨勢）：趨勢組剛轉成 kk 票同向時順勢進場
            sig = [0] * n_
            for i in range(1, n_):
                if tok[i] and adx[i] >= lv:
                    if tl[i] >= kk and tl[i - 1] < kk:
                        sig[i] = 1
                    elif ts[i] >= kk and ts[i - 1] < kk:
                        sig[i] = -1
            for sl in GRP_SL:
                for tp_ in GRP_TP:
                    s11[f"ADX≥{lv}+趨勢{kk}/6+SL{sl}/TP{tp_}"] = run_sl_tp(o, h, l, c, a, days, sig, sl, tp_, cost_frac)
    # ---- S12 抵銷後淨票數：多票減空票，淨差夠大才判多空 ----
    _, net11 = vote_series(df, return_net=True)
    net_grp = [(tl[i] - ts[i]) + (osd[i] - obt[i]) if tok[i] else 0 for i in range(n_)]   # 趨勢組順向 + 震盪組反向
    s12 = {}
    for th in NET_TH_11:
        want = [1 if x >= th else -1 if x <= -th else 0 for x in net11]
        s12[f"原11票淨差≥{th} 持有"] = run_position(o, want, cost_frac)
        ent = [0] + [(1 if net11[i] >= th > net11[i - 1] else -1 if net11[i] <= -th < net11[i - 1] else 0)
                     for i in range(1, n_)]
        for sl in GRP_SL:
            for tp_ in GRP_TP:
                s12[f"原11票淨差≥{th} 進場+SL{sl}/TP{tp_}"] = run_sl_tp(o, h, l, c, a, days, ent, sl, tp_, cost_frac)
    for th in NET_TH_GRP:
        want = [1 if x >= th else -1 if x <= -th else 0 for x in net_grp]
        s12[f"分組淨差≥{th} 持有"] = run_position(o, want, cost_frac)
        ent = [0] + [(1 if net_grp[i] >= th > net_grp[i - 1] else -1 if net_grp[i] <= -th < net_grp[i - 1] else 0)
                     for i in range(1, n_)]
        for sl in GRP_SL:
            for tp_ in GRP_TP:
                s12[f"分組淨差≥{th} 進場+SL{sl}/TP{tp_}"] = run_sl_tp(o, h, l, c, a, days, ent, sl, tp_, cost_frac)
    fams["S12 抵銷後淨票數"] = s12
    # ---- S13 TAI 動能（移植 TAI_Color_Panel）----
    s13, tai_dir = {}, {}
    for mp, tpd in TAI_SETS:
        col = tai_color(df, mp, tpd)
        stk = tai_streak(col)
        tag = f"TAI(MA{mp},週期{tpd})"
        tai_dir[(mp, tpd)] = [1 if x > 0 else -1 if x < 0 else 0 for x in stk]
        s13[f"{tag} 有色就持有"] = run_position(o, tai_dir[(mp, tpd)], cost_frac)
        for need, name in ((1, "啟動"), (2, "延續")):
            ent = [1 if stk[i] == need else -1 if stk[i] == -need else 0 for i in range(n_)]
            for sl in GRP_SL:
                for tp_ in GRP_TP:
                    s13[f"{tag} {name}進場+SL{sl}/TP{tp_}"] = run_sl_tp(o, h, l, c, a, days, ent, sl, tp_, cost_frac)
    fams["S13 TAI動能"] = s13
    # ---- S14 趨勢線突破（移植 Trendline Signal FAST）＋ TAI / 分組淨票 過濾 ----
    s14 = {}
    tai_f = tai_dir[TAI_SETS[0]]
    for lr in TL_LR:
        tsig = trendline_signals(df, lr)
        for fname, keep in (("不過濾", lambda i, e: True),
                            ("TAI同向", lambda i, e: tai_f[i] == e),
                            ("TAI不反向", lambda i, e: tai_f[i] != -e),
                            ("分組淨票同向", lambda i, e: net_grp[i] * e >= 2)):
            sig = [e if e != 0 and keep(i, e) else 0 for i, e in enumerate(tsig)]
            for sl in GRP_SL:
                for tp_ in GRP_TP:
                    s14[f"擺動{lr}+{fname}+SL{sl}/TP{tp_}"] = run_sl_tp(o, h, l, c, a, days, sig, sl, tp_, cost_frac)
    fams["S14 趨勢線突破"] = s14
    fams["S9 趨勢方向+震盪拉回進場"] = s9
    fams["S10 盤整(ADX低)震盪反轉"] = s10
    fams["S11 趨勢(ADX高)順勢進場"] = s11
    if tf in LEVEL_TFS:
        brk, rev = level_events(df)
        vr = volume_ratio(df)
        for fam, ev in (("S6 關卡突破+量+多空", brk), ("S7 關卡反轉+量+多空", rev)):
            combos = {}
            for vk in VOL_K:
                for vote_f in (False, True):
                    sig = [e if e != 0 and vr[i] >= vk and (not vote_f or vote[i] == e) else 0
                           for i, e in enumerate(ev)]
                    for sl in LVL_SL:
                        for tp in LVL_TP:
                            key = (f"量≥{vk}倍" if vk > 1 else "不看量") + ("+多空同向" if vote_f else "") + f"+SL{sl}/TP{tp}"
                            combos[key] = run_sl_tp(o, h, l, c, a, days, sig, sl, tp, cost_frac)
            fams[fam] = combos

    span_is = f"{df['datetime'].iloc[0]:%Y-%m-%d}~{df['datetime'].iloc[cut - 1]:%Y-%m-%d}"
    span_oos = f"{df['datetime'].iloc[cut]:%Y-%m-%d}~{df['datetime'].iloc[-1]:%Y-%m-%d}"
    best_rows, all_rows = [], []
    for fam, combos in fams.items():
        scored = []
        for key, trades in combos.items():
            full, is_s, oos = split_stats(trades, cut)
            all_rows.append([sym, tf, fam, key, full["n"], f"{full['win']:.1f}", f"{full['avg']:.3f}",
                             f"{full['total']:.2f}", f"{full['pf']:.2f}", full["streak"]])
            scored.append((key, is_s, oos))
        ok = [x for x in scored if x[1]["n"] >= MIN_TRADES_IS]
        pool = ok or scored
        key, is_s, oos = max(pool, key=lambda x: (x[1]["pf"], x[1]["avg"]))
        best_rows.append([sym, tf, fam, key,
                          is_s["n"], f"{is_s['win']:.1f}", f"{is_s['avg']:.3f}", f"{is_s['pf']:.2f}",
                          oos["n"], f"{oos['win']:.1f}", f"{oos['avg']:.3f}", f"{oos['total']:.2f}",
                          f"{oos['pf']:.2f}", f"{oos['t']:.2f}", oos["streak"],
                          verdict(is_s, oos), span_is, span_oos])
    return best_rows, all_rows


def main(force=False):
    path = os.path.join(OUT_DIR, "strategy_test.csv")
    ver_file = os.path.join(OUT_DIR, "strategy_test.version")
    try:
        same_ver = open(ver_file, encoding="utf-8").read().strip() == VERSION
    except OSError:
        same_ver = False
    if not force and same_ver and os.path.exists(path) and time.time() - os.path.getmtime(path) < RERUN_HOURS * 3600:
        print(f"[規則測試] {RERUN_HOURS} 小時內跑過，這次略過")
        return
    try:   # 清掉之前背景版本留下的鎖定檔
        os.remove(os.path.join(OUT_DIR, "strategy_test.running"))
    except OSError:
        pass
    mdir = find_merged_dir()
    if not mdir:
        print(f"[規則測試] 找不到 merged 資料夾：{MERGED_DIRS}")
        return
    spreads = load_spreads()
    t0 = time.time()
    best, allr = [], []
    files = sorted(glob.glob(os.path.join(mdir, "*_MERGED_ALL_DATA.csv")))
    print(f"[規則測試] 資料夾 {mdir}，{len(files)} 個檔", flush=True)
    for fpath in files:
        base = os.path.basename(fpath)[:-len("_MERGED_ALL_DATA.csv")]
        sym, _, tf = base.rpartition("_")
        if tf not in TFS:
            continue
        try:
            df = load(fpath, tf)
            if len(df) < 500:
                continue
            b, a = test_series(sym, tf, df, spreads.get(sym))
            best += b
            allr += a
            print(f"[規則測試] {sym} {tf}：{len(df)} 根 OK（累計 {time.time() - t0:.0f} 秒）", flush=True)
        except Exception as e:
            print(f"[規則測試] {sym} {tf} 失敗：{e}", flush=True)
    with open(os.path.join(OUT_DIR, "strategy_test_all.csv"), "w", encoding="utf-8-sig", newline="") as f:
        w = csv.writer(f)
        w.writerow(["Symbol", "週期", "規則", "參數", "交易數", "勝率%", "平均報酬%", "總報酬%", "獲利因子", "最大連虧"])
        w.writerows(allr)
    with open(path, "w", encoding="utf-8-sig", newline="") as f:
        w = csv.writer(f)
        w.writerow(["Symbol", "週期", "規則", "最佳參數(前70%挑)",
                    "前70%交易數", "前70%勝率%", "前70%平均報酬%", "前70%獲利因子",
                    "後30%交易數", "後30%勝率%", "後30%平均報酬%", "後30%總報酬%", "後30%獲利因子",
                    "後30%t值", "後30%最大連虧", "判定", "前70%期間", "後30%期間"])
        w.writerows(best)
    with open(ver_file, "w", encoding="utf-8") as f:
        f.write(VERSION)
    print(f"[規則測試] 完成：{len(best)} 列，耗時 {time.time() - t0:.0f} 秒")


def launch_background():
    """給 build_extra_tables.py 呼叫：另開背景程序跑，不卡住 Excel 按鈕"""
    path = os.path.join(OUT_DIR, "strategy_test.csv")
    if os.path.exists(path) and time.time() - os.path.getmtime(path) < RERUN_HOURS * 3600:
        return "24 小時內跑過，略過"
    lock = os.path.join(OUT_DIR, "strategy_test.running")
    if os.path.exists(lock) and time.time() - os.path.getmtime(lock) < 3600:
        return "上一次還在背景執行中"
    import subprocess
    log = open(os.path.join(OUT_DIR, "log_strategy_test.txt"), "w", encoding="utf-8")
    flags = 0x00000008 | 0x08000000 if os.name == "nt" else 0   # DETACHED_PROCESS | CREATE_NO_WINDOW
    subprocess.Popen([sys.executable, "-u", os.path.abspath(__file__), "--bg"], stdout=log, stderr=log,
                     cwd=os.path.dirname(os.path.abspath(__file__)), creationflags=flags,
                     env=dict(os.environ, PYTHONIOENCODING="utf-8"))
    return "已在背景啟動（約數分鐘，完成後寫出 strategy_test.csv）"


if __name__ == "__main__":
    if "--bg" in sys.argv:
        lock = os.path.join(OUT_DIR, "strategy_test.running")
        open(lock, "w").close()
        try:
            main(force=True)
        finally:
            try:
                os.remove(lock)
            except OSError:
                pass
    else:
        main(force=True)
