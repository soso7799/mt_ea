#!/usr/bin/env python3
"""
趨勢線策略回測（把「兩個高點連成壓力線 / 兩個低點連成支撐線」變成可驗證的規則）

規則（程式自動畫線，不看未來）：
  1. 擺動高點 = 左右各 N 根都比它低的 K 棒（要等右邊 N 根走完才確認）
  2. 下降壓力線 = 最近兩個擺動高點相連，且後高 < 前高；上升支撐線 = 最近兩個擺動低點相連，且後低 > 前低
  3. 線被收盤價突破後即作廢，等新的兩個擺動點再畫
  兩種玩法（--mode）：
    bounce 碰線反彈：價格碰到壓力線（高點 >= 線 - 0.1 ATR）但收在線下 → 下一根開盤做空；支撐線反之做多
                     止損 = 線外 0.5 ATR；止盈 = RR 倍止損距離
    break  突破：收盤價突破壓力線 0.1 ATR 以上 → 下一根開盤做多；跌破支撐線做空
                 止損 = 最近 N 根的低點（做多）/ 高點（做空）外 0.2 ATR；止盈 = RR 倍
  同一商品一次一單；最多持有 --max-hold 根；同根同時碰止損止盈算止損；含點差

用法（資料 = HistoryExporter 的 FTMO_Data）
  python backtest_trendline.py --grid --years 3 --split 2025-01-01            全部商品、全部參數組合
  python backtest_trendline.py --tf H4 --grid --years 10 --split 2023-01-01
  python backtest_trendline.py --symbols EURUSD --mode bounce --pivot 5 --rr 2 單一組合，印各商品
"""
import argparse
import csv
import datetime as dt
import os
import sys
from collections import defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from backtest_trend import load_bars, atr, stats, symbol_group, GROUP_NAMES, RISK_PCT  # noqa: E402

TOL_ATR = 0.1        # 碰線容許誤差
SL_LINE_ATR = 0.5    # 反彈：止損放線外
SL_SWING_ATR = 0.2   # 突破：止損放擺動點外
GRID_PIVOT = (3, 5, 8)
GRID_MODE = ("bounce", "break")
GRID_RR = (1.5, 2.0, 3.0)


def pivots(b, n):
    """回傳 (高點索引list, 低點索引list)；索引 i 在 i+n 根收盤後才可用"""
    h, l = b["h"], b["l"]
    ph, pl = [], []
    for i in range(n, len(h) - n):
        if all(h[i] > h[j] for j in range(i - n, i + n + 1) if j != i):
            ph.append(i)
        if all(l[i] < l[j] for j in range(i - n, i + n + 1) if j != i):
            pl.append(i)
    return ph, pl


def run(sym, b, a_, ph, pl, n, mode, rr, point, start_i, max_hold):
    o, h, l, c, sp, t = b["o"], b["h"], b["l"], b["c"], b["sp"], b["t"]
    N = len(c)
    trades = []
    pos = None
    hi_k = lo_k = 0          # ph / pl 中「已確認」的數量
    dn = up = None           # 目前有效的線 (i1, p1, i2, p2)
    for i in range(max(start_i, 2 * n + 2), N - 1):
        a = a_[i]
        if a != a or a <= 0:
            continue
        spread = sp[i] * point
        # --- 持倉：K 棒內止損 / 止盈
        if pos:
            d, entry, sl, tp, i0 = pos
            if d > 0:
                if l[i] <= sl:
                    trades.append((t[i0], -1.0, "SL"))
                    pos = None
                elif h[i] >= tp:
                    trades.append((t[i0], rr, "TP"))
                    pos = None
            else:
                if h[i] + spread >= sl:
                    trades.append((t[i0], -1.0, "SL"))
                    pos = None
                elif l[i] + spread <= tp:
                    trades.append((t[i0], rr, "TP"))
                    pos = None
            if pos and i - i0 >= max_hold:
                ex = c[i] if d > 0 else c[i] + spread
                r = (ex - entry) / (entry - sl) if d > 0 else (entry - ex) / (sl - entry)
                trades.append((t[i0], r, "TIME"))
                pos = None
        # --- 更新已確認的擺動點與趨勢線
        while hi_k < len(ph) and ph[hi_k] + n <= i:
            hi_k += 1
            if hi_k >= 2:
                i1, i2 = ph[hi_k - 2], ph[hi_k - 1]
                if h[i2] < h[i1]:
                    dn = (i1, h[i1], i2, h[i2])
        while lo_k < len(pl) and pl[lo_k] + n <= i:
            lo_k += 1
            if lo_k >= 2:
                i1, i2 = pl[lo_k - 2], pl[lo_k - 1]
                if l[i2] > l[i1]:
                    up = (i1, l[i1], i2, l[i2])
        if pos:
            continue

        def line(ln):
            i1, p1, i2, p2 = ln
            return p2 + (p2 - p1) / (i2 - i1) * (i - i2)

        sig = 0
        sl = 0.0
        if dn:
            v = line(dn)
            if c[i] > v + TOL_ATR * a:                       # 收盤突破壓力線
                if mode == "break":
                    sig, sl = 1, min(l[i - n:i + 1]) - SL_SWING_ATR * a
                dn = None
            elif mode == "bounce" and h[i] >= v - TOL_ATR * a and c[i] < v:
                sig, sl = -1, v + SL_LINE_ATR * a
        if not sig and up:
            v = line(up)
            if c[i] < v - TOL_ATR * a:                       # 收盤跌破支撐線
                if mode == "break":
                    sig, sl = -1, max(h[i - n:i + 1]) + SL_SWING_ATR * a
                up = None
            elif mode == "bounce" and l[i] <= v + TOL_ATR * a and c[i] > v:
                sig, sl = 1, v - SL_LINE_ATR * a
        if not sig:
            continue
        nsp = sp[i + 1] * point
        entry = o[i + 1] + nsp if sig > 0 else o[i + 1]
        risk = (entry - sl) if sig > 0 else (sl - entry)
        if risk <= 0.2 * a or risk > 5 * a:                 # 止損太近或太遠就放棄
            continue
        tp = entry + rr * risk if sig > 0 else entry - rr * risk
        pos = (sig, entry, sl, tp, i + 1)
    return trades


def load(sym, a, tfdir):
    b, digits = load_bars(os.path.join(tfdir, sym + ".csv"))
    if len(b["t"]) < 500:
        return None
    start = b["t"][-1] - dt.timedelta(days=365 * a.years)
    si = next((k for k, x in enumerate(b["t"]) if x >= start), len(b["t"]))
    return b, 10 ** -digits, si, atr(b["h"], b["l"], b["c"], 14)


def main():
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except AttributeError:
        pass
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    appdata = os.environ.get("APPDATA", "")
    ap.add_argument("--data", default=os.path.join(appdata, "MetaQuotes", "Terminal", "Common", "Files", "FTMO_Data"))
    ap.add_argument("--tf", default="H1", choices=["M15", "M30", "H1", "H4", "D1"])
    ap.add_argument("--symbols", default="")
    ap.add_argument("--group", default="", help="例如 major,cross 或 crypto")
    ap.add_argument("--years", type=float, default=3)
    ap.add_argument("--split", default="", help="樣本內/外分界日 YYYY-MM-DD")
    ap.add_argument("--mode", default="bounce", choices=GRID_MODE)
    ap.add_argument("--pivot", type=int, default=5)
    ap.add_argument("--rr", type=float, default=2.0)
    ap.add_argument("--max-hold", type=int, default=100, help="最多持有幾根 K 棒")
    ap.add_argument("--grid", action="store_true", help="跑全部 擺動N × 模式 × RR 組合")
    ap.add_argument("--out", default="trendline.csv")
    a = ap.parse_args()

    tfdir = os.path.join(a.data, a.tf)
    if not os.path.isdir(tfdir):
        sys.exit(f"找不到 {tfdir}")
    syms = [s.strip() for s in a.symbols.split(",") if s.strip()] or \
        sorted(f[:-4] for f in os.listdir(tfdir) if f.endswith(".csv"))
    if a.group:
        want = {g.strip() for g in a.group.split(",")}
        syms = [s for s in syms if symbol_group(s) in want]
    cut = dt.datetime.strptime(a.split, "%Y-%m-%d") if a.split else None

    data = {}
    for s in syms:
        try:
            x = load(s, a, tfdir)
        except (OSError, ValueError):
            x = None
        if x:
            data[s] = x
    print(f"趨勢線回測：{a.tf}，{len(data)} 個商品，近 {a.years:g} 年" + (f"，分界 {a.split}" if cut else ""))

    combos = [(n, m, rr) for n in GRID_PIVOT for m in GRID_MODE for rr in GRID_RR] if a.grid \
        else [(a.pivot, a.mode, a.rr)]
    piv_cache = {}
    results = []
    for ci, (n, mode, rr) in enumerate(combos, 1):
        allr, ins, oos = [], [], []
        per = defaultdict(list)
        grp = defaultdict(list)
        for s, (b, point, si, at) in data.items():
            if (s, n) not in piv_cache:
                piv_cache[(s, n)] = pivots(b, n)
            ph, pl = piv_cache[(s, n)]
            for t0, r, why in run(s, b, at, ph, pl, n, mode, rr, point, si, a.max_hold):
                allr.append(r)
                per[s].append(r)
                grp[symbol_group(s)].append(r)
                if cut:
                    (ins if t0 < cut else oos).append(r)
        st = stats(allr)
        si_, so_ = stats(ins), stats(oos)
        results.append((n, mode, rr, st, si_, so_, per, grp))
        line = f"[{ci:2d}/{len(combos)}] 擺動N={n} {mode:<6} RR{rr:<3} 全部 {st['n']:6d}筆 勝率{st['win']:5.1f}% {st['total']:+8.1f}R PF{st['pf']:.2f}"
        if cut:
            line += f" | 內 PF{si_['pf']:.2f} {si_['total']:+.0f}R | 外 PF{so_['pf']:.2f} {so_['total']:+.0f}R"
        print(line)

    def k(r):
        return min(r[4]["pf"], r[5]["pf"]) if cut else r[3]["pf"]
    results.sort(key=k, reverse=True)
    best = results[0]
    n, mode, rr, st, si_, so_, per, grp = best
    print("\n" + "=" * 90)
    print(f"最佳組合：擺動N={n} {mode} RR{rr}   全部 {st['n']}筆 PF{st['pf']:.2f} {st['total']:+.1f}R "
          f"（帳戶 {st['total'] * RISK_PCT:+.1f}%，每筆風險 {RISK_PCT}%）")
    if cut:
        print(f"  樣本內 PF{si_['pf']:.2f} {si_['total']:+.1f}R ({si_['n']}筆) | 樣本外 PF{so_['pf']:.2f} {so_['total']:+.1f}R ({so_['n']}筆)")
    print("=" * 90)
    print("— 依分組 —")
    for g in GROUP_NAMES:
        if g in grp:
            x = stats(grp[g])
            print(f"  {GROUP_NAMES[g]:<6} {x['n']:5d}筆 勝率{x['win']:5.1f}% {x['total']:+8.1f}R PF{x['pf']:.2f}")
    print("— 依商品（前 15 / 後 5）—")
    ranked = sorted(per.items(), key=lambda kv: -sum(kv[1]))
    show = ranked if len(ranked) <= 20 else ranked[:15] + [("...", [])] + ranked[-5:]
    for s, rs in show:
        if not rs:
            print("  ...")
            continue
        x = stats(rs)
        print(f"  {s:<12} {x['n']:4d}筆 勝率{x['win']:5.1f}% {x['total']:+7.1f}R PF{x['pf']:.2f}")

    with open(a.out, "w", newline="", encoding="utf-8-sig") as f:
        w = csv.writer(f)
        w.writerow(["pivot", "mode", "rr", "n", "win", "totalR", "pf", "is_n", "is_R", "is_pf", "oos_n", "oos_R", "oos_pf"])
        for n, mode, rr, st, si_, so_, _, _ in results:
            w.writerow([n, mode, rr, st["n"], round(st["win"], 1), round(st["total"], 1), round(st["pf"], 2),
                        si_["n"], round(si_["total"], 1), round(si_["pf"], 2), so_["n"], round(so_["total"], 1), round(so_["pf"], 2)])
    print(f"\n全部組合：{os.path.abspath(a.out)}")
    print("注意：程式化畫線只取「最近兩個擺動點」，和人工畫線不完全相同；結果用來判斷規則有沒有優勢。")


if __name__ == "__main__":
    main()
