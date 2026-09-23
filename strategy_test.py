# -*- coding: utf-8 -*-
"""
strategy_test.py —— 用 MT5 真實歷史 K 棒，比較幾種進出場規則是否有正期望值（含點差成本）

輸出：update_output\\strategy_test.csv（每個 商品 × 週期 × 規則 一列）
由 build_extra_tables.py 自動呼叫；結果檔 6 小時內跑過就不重跑（避免每按一次按鈕都變慢）。

規則（全部是「K 棒收盤出訊號、下一根開盤進場」，不偷看未來）：
  S0 投票翻邊     ：目前儀表板用的 11 指標多數決，翻邊就反手（對照組）
  S1 順勢投票     ：投票方向和 EMA200 方向一致才持有，不一致就空手
  S2 投票+ATR停損 ：投票翻邊進場，停損 1.5×ATR、停利 3×ATR（同一根同時碰到算停損）
  S3 前日高低突破 ：H1 收盤突破前一日高點做多、跌破前一日低點做空；停損 1.5×ATR、停利 3×ATR，
                    當天沒出場就在換日時平倉（只測 H1）
每筆交易扣一次點差（用 MT5 目前的 spread）。
"""
import csv
import os
import time

import numpy as np
import pandas as pd

from build_extra_tables import OUT_DIR, vote_series

RESULT = "strategy_test.csv"
TEST_BARS = 3000
TFS = ["D1", "H4", "H1"]
SL_ATR, TP_ATR = 1.5, 3.0
MIN_TRADES = 30          # 交易數少於這個 → 樣本不足
RERUN_HOURS = 6


def atr(df, n=14):
    h, l, c = df["high"], df["low"], df["close"]
    tr = pd.concat([h - l, (h - c.shift()).abs(), (l - c.shift()).abs()], axis=1).max(axis=1)
    return tr.ewm(alpha=1 / n, adjust=False).mean()


def run_position(df, want, cost):
    """want[i]＝第 i 根收盤後想要的部位（+1/-1/0），在第 i+1 根開盤執行。回傳每筆報酬%（已扣成本）"""
    o = df["open"].values
    rets, cur, entry = [], 0, 0.0
    for i in range(len(df) - 1):
        w = int(want[i])
        if w == cur:
            continue
        px = o[i + 1]
        if cur != 0:
            rets.append(cur * (px - entry) / entry * 100 - cost / entry * 100)
        cur, entry = w, px
    return rets


def run_sl_tp(df, entry_sig, cost, day_exit=False):
    """entry_sig[i]＝第 i 根收盤出現的進場訊號（+1/-1/0），下一根開盤進場；持倉中忽略新訊號。
    停損/停利用之後每根的高低價判斷，同一根同時碰到算停損（保守）。"""
    o, h, l, c = (df[k].values for k in ("open", "high", "low", "close"))
    a = atr(df).values
    days = df["datetime"].dt.date.values
    rets, i, n = [], 0, len(df)
    while i < n - 1:
        s = int(entry_sig[i])
        if s == 0 or np.isnan(a[i]):
            i += 1
            continue
        e = o[i + 1]
        sl = e - s * SL_ATR * a[i]
        tp = e + s * TP_ATR * a[i]
        j, exit_px = i + 1, None
        while j < n:
            if s > 0:
                if l[j] <= sl:
                    exit_px = sl
                elif h[j] >= tp:
                    exit_px = tp
            else:
                if h[j] >= sl:
                    exit_px = sl
                elif l[j] <= tp:
                    exit_px = tp
            if exit_px is None and day_exit and j + 1 < n and days[j + 1] != days[j]:
                exit_px = c[j]
            if exit_px is not None:
                break
            j += 1
        if exit_px is None:
            exit_px = c[n - 1]
        rets.append(s * (exit_px - e) / e * 100 - cost / e * 100)
        i = j + 1
    return rets


def breakout_signals(df):
    """H1：收盤第一次突破前一日高（+1）/ 跌破前一日低（-1），每天每個方向只算一次"""
    d = df["datetime"].dt.date
    daily = df.groupby(d).agg(hi=("high", "max"), lo=("low", "min"))
    prev = daily.shift(1)
    phi = d.map(prev["hi"]).values
    plo = d.map(prev["lo"]).values
    c = df["close"].values
    sig = np.zeros(len(df))
    fired = {}
    for i in range(len(df)):
        if np.isnan(phi[i]):
            continue
        k = d.iloc[i]
        f = fired.setdefault(k, set())
        if c[i] > phi[i] and 1 not in f:
            sig[i] = 1
            f.add(1)
        elif c[i] < plo[i] and -1 not in f:
            sig[i] = -1
            f.add(-1)
    return sig


def stats(rets):
    n = len(rets)
    if n == 0:
        return dict(n=0)
    r = np.array(rets)
    win, loss = r[r > 0].sum(), -r[r < 0].sum()
    streak = best = 0
    for x in r:
        streak = streak + 1 if x <= 0 else 0
        best = max(best, streak)
    half = n // 2
    def pf(x):
        w, l = x[x > 0].sum(), -x[x < 0].sum()
        return w / l if l > 0 else (np.inf if w > 0 else 0)
    return dict(n=n, win=(r > 0).mean() * 100, avg=r.mean(), total=r.sum(),
                pf=win / loss if loss > 0 else np.inf, streak=best,
                pf1=pf(r[:half]), pf2=pf(r[half:]))


def verdict(s):
    if s["n"] < MIN_TRADES:
        return "樣本不足"
    if s["avg"] > 0 and s["pf"] >= 1.2 and s["pf1"] > 1 and s["pf2"] > 1:
        return "有效（前後半段都賺）"
    if s["avg"] > 0 and s["pf"] > 1:
        return "微幅正值（不穩定）"
    return "無效"


def main(force=False):
    path = os.path.join(OUT_DIR, RESULT)
    if not force and os.path.exists(path) and time.time() - os.path.getmtime(path) < RERUN_HOURS * 3600:
        print(f"[規則測試] {RESULT} {RERUN_HOURS} 小時內跑過，這次略過")
        return
    import MetaTrader5 as mt5
    if not mt5.initialize():
        print("[規則測試] MT5 未開啟，略過")
        return
    syms = []
    status = os.path.join(OUT_DIR, "multi_symbol_status.csv")
    if os.path.exists(status):
        with open(status, encoding="utf-8-sig", newline="") as f:
            for r in csv.DictReader(f):
                s = (r.get("Symbol") or "").strip()
                if s and s not in syms:
                    syms.append(s)
    rows = []
    for sym in syms:
        if not mt5.symbol_select(sym, True):
            continue
        info = mt5.symbol_info(sym)
        cost = (info.spread * info.point) if info else 0.0
        for tf in TFS:
            rates = mt5.copy_rates_from_pos(sym, getattr(mt5, "TIMEFRAME_" + tf), 0, TEST_BARS)
            if rates is None or len(rates) < 300:
                continue
            df = pd.DataFrame(rates)
            df["datetime"] = pd.to_datetime(df["time"], unit="s")
            vote = vote_series(df).values
            ema200 = df["close"].ewm(span=200, adjust=False).mean().values
            trend = np.where(df["close"].values > ema200, 1, -1)
            trend[:200] = 0
            flip = np.zeros(len(df))
            flip[1:] = np.where((vote[1:] != vote[:-1]) & (vote[1:] != 0), vote[1:], 0)
            tests = {
                "S0 投票翻邊": run_position(df, vote, cost),
                "S1 順勢投票": run_position(df, np.where(vote == trend, vote, 0), cost),
                "S2 投票+ATR停損": run_sl_tp(df, flip, cost),
            }
            if tf == "H1":
                tests["S3 前日高低突破"] = run_sl_tp(df, breakout_signals(df), cost, day_exit=True)
            span = f"{df['datetime'].iloc[0]:%Y-%m-%d} ~ {df['datetime'].iloc[-1]:%Y-%m-%d}"
            for name, rets in tests.items():
                s = stats(rets)
                if s["n"] == 0:
                    rows.append([sym, tf, name, 0, "", "", "", "", "", "", "樣本不足", span])
                    continue
                rows.append([sym, tf, name, s["n"], f"{s['win']:.1f}", f"{s['avg']:.3f}", f"{s['total']:.2f}",
                             f"{s['pf']:.2f}" if np.isfinite(s["pf"]) else "∞", s["streak"],
                             f"{s['pf1']:.2f} / {s['pf2']:.2f}" if np.isfinite(s["pf1"]) and np.isfinite(s["pf2"]) else "",
                             verdict(s), span])
    mt5.shutdown()
    with open(path, "w", encoding="utf-8-sig", newline="") as f:
        w = csv.writer(f)
        w.writerow(["Symbol", "週期", "規則", "交易數", "勝率%", "平均報酬%(扣點差)", "總報酬%",
                    "獲利因子", "最大連虧", "前半/後半獲利因子", "判定", "測試期間"])
        w.writerows(rows)
    print(f"[規則測試] {RESULT}：{len(rows)} 列")


if __name__ == "__main__":
    main(force=True)
