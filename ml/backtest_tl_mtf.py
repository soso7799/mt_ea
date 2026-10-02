#!/usr/bin/env python3
"""
多週期趨勢線回測：大週期（H1）自動畫壓力線/支撐線，小週期（M15/M5）用指標確認後進場
（與 TrendlineMTF.mq5 相同規則）

畫線（大週期，與 TrendScanner 相同，不看未來）
  擺動高點 = 左右各 N 根都比它低；壓力線 = 最近兩個擺動高點相連且後高 < 前高；支撐線反之
  大週期收盤突破線 0.1 ATR → 線作廢
  小週期每根 K 棒用「目前這根大週期 K 棒」位置的線值（只用已收盤的大週期 K 棒畫線）

兩種玩法（--mode）
  bounce 碰線反轉：最近 4 根小週期高點碰到壓力線 - zone×ATR(大) 且收在線下 + 確認訊號 → 做空
                  止損 = max(最近 6 根高點, 線) + 0.3 ATR(小)；支撐線做多反之
  break  突破：    小週期收盤站上壓力線 0.1 ATR(大) + 確認訊號 → 做多（每條線只算第一次突破）
                  止損 = 最近 6 根低點 - 0.3 ATR(小)；跌破支撐線做空反之
  止盈 = RR × 止損距離；最多持有 --max-hold 根小週期 K 棒；一個商品一次一單

確認訊號（--trigger，小週期）
  none   不用指標，只要求 K 棒方向（反轉：陰線做空；突破：陽線做多）
  rsi    反轉：RSI(14) 由 >=60 跌回 60 以下做空（<=40 回升做多）；突破：RSI >= 55 做多（<= 45 做空）
  candle 反轉：吞噬或長上影（上影 >= 2 倍實體且收在下半部）；突破：實體 >= 60% 的強勢 K 棒
  ema    反轉：EMA9 下穿 EMA21 做空；突破：EMA9 > EMA21 做多
  --trend 只順大週期 EMA50 方向做（收盤在 EMA50 下只做空）

用法（資料 = HistoryExporter 的 FTMO_Data；小週期只有 3 年）
  python backtest_tl_mtf.py --grid --split 2025-01-01                                 全部商品、全部組合
  python backtest_tl_mtf.py --grid --split 2025-01-01 --symbols USDJPY,CADJPY,GBPJPY
  python backtest_tl_mtf.py --ltf M5 --grid --split 2025-01-01 --group major,cross
  python backtest_tl_mtf.py --mode bounce --trigger rsi --rr 2 --split 2025-01-01      單一組合
"""
import argparse
import csv
import datetime as dt
import os
import sys
from collections import defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from backtest_trend import load_bars, atr, ema, rsi, stats, symbol_group, GROUP_NAMES, RISK_PCT  # noqa: E402
from backtest_trendline import pivots  # noqa: E402

TF_MIN = {"M5": 5, "M15": 15, "M30": 30, "H1": 60, "H4": 240}
BREAK_ATR = 0.1       # 大週期 ATR：收盤超過線多少算突破
TOUCH_BARS = 4        # 反轉：最近幾根小週期 K 棒內碰過線
SL_BARS = 6           # 止損參考最近幾根小週期高/低點
SL_BUF = 0.3          # 止損緩衝（小週期 ATR）
RSI_HI, RSI_LO = 60, 40
RSI_BULL, RSI_BEAR = 55, 45
TREND_EMA = 50
GRID_MODE = ("bounce", "break")
GRID_TRIGGER = ("none", "rsi", "candle", "ema")
GRID_RR = (1.5, 2.0, 3.0)
GRID_TREND = (False, True)


def line_value(ln, x):
    i1, p1, i2, p2 = ln
    return p2 + (p2 - p1) / (i2 - i1) * (x - i2)


def htf_lines(b, n, a_):
    """每根大週期 K 棒收盤後的有效壓力線 / 支撐線"""
    ph, pl = pivots(b, n)
    h, l, c = b["h"], b["l"], b["c"]
    N = len(c)
    dn_at, up_at = [None] * N, [None] * N
    hk = lk = 0
    dn = up = None
    for i in range(N):
        while hk < len(ph) and ph[hk] + n <= i:
            hk += 1
            if hk >= 2:
                i1, i2 = ph[hk - 2], ph[hk - 1]
                if h[i2] < h[i1]:
                    dn = (i1, h[i1], i2, h[i2])
        while lk < len(pl) and pl[lk] + n <= i:
            lk += 1
            if lk >= 2:
                i1, i2 = pl[lk - 2], pl[lk - 1]
                if l[i2] > l[i1]:
                    up = (i1, l[i1], i2, l[i2])
        a = a_[i]
        if a == a and a > 0:
            if dn and c[i] > line_value(dn, i) + BREAK_ATR * a:
                dn = None
            if up and c[i] < line_value(up, i) - BREAK_ATR * a:
                up = None
        dn_at[i], up_at[i] = dn, up
    return dn_at, up_at


def candidates(H, L, n, zone, start_t):
    """小週期 K 棒 k 收盤時，價格靠近/突破大週期線的位置 → [(k, kind, dir, v, trend)]"""
    ah = atr(H["h"], H["l"], H["c"], 14)
    eh = ema(H["c"], TREND_EMA)
    dn_at, up_at = htf_lines(H, n, ah)
    th, hdur = H["t"], dt.timedelta(minutes=H["min"])
    h, l, c, t = L["h"], L["l"], L["c"], L["t"]
    out = []
    broken = set()
    j = 0
    for k in range(max(SL_BARS, TOUCH_BARS), len(c) - 1):
        if t[k] < start_t:
            continue
        while j + 1 < len(th) and th[j + 1] <= t[k]:
            j += 1
        if j < 1 or not (th[j] <= t[k] < th[j] + hdur):
            continue
        a = ah[j - 1]
        if a != a or a <= 0:
            continue
        trend = 1 if H["c"][j - 1] > eh[j - 1] else -1
        dn, up = dn_at[j - 1], up_at[j - 1]
        if dn:
            v = line_value(dn, j)
            if c[k] > v + BREAK_ATR * a:
                if dn not in broken:
                    broken.add(dn)
                    out.append((k, "break", 1, v, trend))
            elif c[k] < v and max(h[k - TOUCH_BARS + 1:k + 1]) >= v - zone * a:
                out.append((k, "bounce", -1, v, trend))
        if up:
            v = line_value(up, j)
            if c[k] < v - BREAK_ATR * a:
                if up not in broken:
                    broken.add(up)
                    out.append((k, "break", -1, v, trend))
            elif c[k] > v and min(l[k - TOUCH_BARS + 1:k + 1]) <= v + zone * a:
                out.append((k, "bounce", 1, v, trend))
    return out


def triggered(L, k, kind, d, trig):
    o, h, l, c = L["o"], L["h"], L["l"], L["c"]
    if kind == "bounce":
        if trig == "none":
            return c[k] < o[k] if d < 0 else c[k] > o[k]
        if trig == "rsi":
            r0, r1 = L["rsi"][k], L["rsi"][k - 1]
            return (r1 >= RSI_HI > r0) if d < 0 else (r1 <= RSI_LO < r0)
        if trig == "ema":
            f0, s0, f1, s1 = L["ef"][k], L["es"][k], L["ef"][k - 1], L["es"][k - 1]
            return (f1 >= s1 and f0 < s0) if d < 0 else (f1 <= s1 and f0 > s0)
        if trig == "candle":
            body = abs(c[k] - o[k])
            rng = h[k] - l[k]
            if rng <= 0:
                return False
            if d < 0:
                engulf = c[k] < o[k] and c[k - 1] > o[k - 1] and o[k] >= c[k - 1] and c[k] <= o[k - 1]
                pin = h[k] - max(o[k], c[k]) >= 2 * body and c[k] <= l[k] + 0.5 * rng
            else:
                engulf = c[k] > o[k] and c[k - 1] < o[k - 1] and o[k] <= c[k - 1] and c[k] >= o[k - 1]
                pin = min(o[k], c[k]) - l[k] >= 2 * body and c[k] >= l[k] + 0.5 * rng
            return engulf or pin
    else:
        if trig == "none":
            return c[k] > o[k] if d > 0 else c[k] < o[k]
        if trig == "rsi":
            return L["rsi"][k] >= RSI_BULL if d > 0 else L["rsi"][k] <= RSI_BEAR
        if trig == "ema":
            return L["ef"][k] > L["es"][k] if d > 0 else L["ef"][k] < L["es"][k]
        if trig == "candle":
            rng = h[k] - l[k]
            return rng > 0 and abs(c[k] - o[k]) >= 0.6 * rng and (c[k] > o[k]) == (d > 0)
    return False


def simulate(L, k, kind, d, v, rr, point, max_hold):
    """回傳 (R, 出場索引)；不成立回傳 None"""
    o, h, l, c, sp, al = L["o"], L["h"], L["l"], L["c"], L["sp"], L["atr"]
    a = al[k]
    if a != a or a <= 0:
        return None
    if d < 0:
        sl = max(max(h[k - SL_BARS + 1:k + 1]), v if kind == "bounce" else -1e18) + SL_BUF * a
    else:
        sl = min(min(l[k - SL_BARS + 1:k + 1]), v if kind == "bounce" else 1e18) - SL_BUF * a
    e = k + 1
    entry = o[e] + sp[e] * point if d > 0 else o[e]
    risk = (entry - sl) if d > 0 else (sl - entry)
    if risk < 0.3 * a or risk > 10 * a:
        return None
    tp = entry + rr * risk if d > 0 else entry - rr * risk
    last = min(len(c) - 1, e + max_hold - 1)
    for m in range(e, last + 1):
        s = sp[m] * point
        if d > 0:
            if l[m] <= sl:
                return -1.0, m
            if h[m] >= tp:
                return rr, m
        else:
            if h[m] + s >= sl:
                return -1.0, m
            if l[m] + s <= tp:
                return rr, m
    ex = c[last] if d > 0 else c[last] + sp[last] * point
    return ((ex - entry) if d > 0 else (entry - ex)) / risk, last


def run_combo(L, cands, mode, trig, rr, trend, point, max_hold):
    trades = []
    busy = -1
    for k, kind, d, v, tr in cands:
        if k <= busy or kind != mode or (trend and tr != d):
            continue
        if not triggered(L, k, kind, d, trig):
            continue
        x = simulate(L, k, kind, d, v, rr, point, max_hold)
        if x is None:
            continue
        r, busy = x
        trades.append((L["t"][k + 1], r))
    return trades


def load_tf(path, minutes):
    b, digits = load_bars(path)
    b["min"] = minutes
    return b, 10 ** -digits


def main():
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except AttributeError:
        pass
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    appdata = os.environ.get("APPDATA", "")
    ap.add_argument("--data", default=os.path.join(appdata, "MetaQuotes", "Terminal", "Common", "Files", "FTMO_Data"))
    ap.add_argument("--htf", default="H1", choices=["H1", "H4"], help="畫線週期")
    ap.add_argument("--ltf", default="M15", choices=["M5", "M15", "M30"], help="進場週期")
    ap.add_argument("--symbols", default="")
    ap.add_argument("--group", default="", help="例如 major,cross")
    ap.add_argument("--years", type=float, default=3)
    ap.add_argument("--split", default="", help="樣本內/外分界日 YYYY-MM-DD")
    ap.add_argument("--pivot", type=int, default=5, help="擺動點左右各幾根（大週期）")
    ap.add_argument("--zone", type=float, default=0.3, help="碰線容許距離（大週期 ATR 倍數）")
    ap.add_argument("--mode", default="bounce", choices=GRID_MODE)
    ap.add_argument("--trigger", default="rsi", choices=GRID_TRIGGER)
    ap.add_argument("--rr", type=float, default=2.0)
    ap.add_argument("--trend", action="store_true", help="只順大週期 EMA50 方向")
    ap.add_argument("--max-hold", type=int, default=96, help="最多持有幾根小週期 K 棒")
    ap.add_argument("--min-trades", type=int, default=20, help="判定「兩段都賺」時樣本內最少筆數（樣本外取一半）")
    ap.add_argument("--grid", action="store_true", help="跑全部 模式 × 確認訊號 × RR × 順勢 組合")
    ap.add_argument("--out", default="tl_mtf.csv")
    a = ap.parse_args()

    hdir, ldir = os.path.join(a.data, a.htf), os.path.join(a.data, a.ltf)
    for d_ in (hdir, ldir):
        if not os.path.isdir(d_):
            sys.exit(f"找不到 {d_}")
    syms = [s.strip() for s in a.symbols.split(",") if s.strip()] or \
        sorted(f[:-4] for f in os.listdir(ldir) if f.endswith(".csv") and os.path.exists(os.path.join(hdir, f)))
    if a.group:
        want = {g.strip() for g in a.group.split(",")}
        syms = [s for s in syms if symbol_group(s) in want]
    cut = dt.datetime.strptime(a.split, "%Y-%m-%d") if a.split else None
    combos = [(m, tg, rr, tr) for m in GRID_MODE for tg in GRID_TRIGGER for rr in GRID_RR for tr in GRID_TREND] \
        if a.grid else [(a.mode, a.trigger, a.rr, a.trend)]
    print(f"多週期趨勢線回測：{a.htf} 畫線 → {a.ltf} 進場，{len(syms)} 個商品，近 {a.years:g} 年，"
          f"擺動N={a.pivot} 碰線{a.zone}ATR，{len(combos)} 組" + (f"，分界 {a.split}" if cut else ""))

    # 一次讀一個商品（M5 很大），把每個組合的交易累積起來
    res = {cb: defaultdict(list) for cb in combos}
    for si, s in enumerate(syms, 1):
        try:
            H, _ = load_tf(os.path.join(hdir, s + ".csv"), TF_MIN[a.htf])
            L, point = load_tf(os.path.join(ldir, s + ".csv"), TF_MIN[a.ltf])
        except (OSError, ValueError):
            continue
        if len(L["t"]) < 1000 or len(H["t"]) < 200:
            continue
        start_t = L["t"][-1] - dt.timedelta(days=365 * a.years)
        L["atr"] = atr(L["h"], L["l"], L["c"], 14)
        L["rsi"] = rsi(L["c"], 14)
        L["ef"], L["es"] = ema(L["c"], 9), ema(L["c"], 21)
        cands = candidates(H, L, a.pivot, a.zone, start_t)
        for cb in combos:
            res[cb][s] = run_combo(L, cands, cb[0], cb[1], cb[2], cb[3], point, a.max_hold)
        print(f"  [{si}/{len(syms)}] {s:<12} 靠近/突破線 {len(cands)} 次", flush=True)

    def name(cb):
        m, tg, rr, tr = cb
        return f"{m:<6} {tg:<6} RR{rr:<3} {'順勢' if tr else '不限'}"

    summary = []
    print()
    for ci, cb in enumerate(combos, 1):
        per = res[cb]
        allr = [r for rs in per.values() for _, r in rs]
        ins = [r for rs in per.values() for t0, r in rs if cut and t0 < cut]
        oos = [r for rs in per.values() for t0, r in rs if cut and t0 >= cut]
        st, si_, so_ = stats(allr), stats(ins), stats(oos)
        summary.append((cb, st, si_, so_))
        ln = f"[{ci:2d}/{len(combos)}] {name(cb)} 全部 {st['n']:6d}筆 勝率{st['win']:5.1f}% {st['total']:+8.1f}R PF{st['pf']:.2f}"
        if cut:
            ln += f" | 內 PF{si_['pf']:.2f} {si_['total']:+.0f}R | 外 PF{so_['pf']:.2f} {so_['total']:+.0f}R"
        print(ln)

    def key(x):
        return min(x[2]["pf"], x[3]["pf"]) if cut else x[1]["pf"]
    summary.sort(key=key, reverse=True)
    with open(a.out, "w", newline="", encoding="utf-8-sig") as f:
        w = csv.writer(f)
        w.writerow(["mode", "trigger", "rr", "trend", "n", "win", "total_R", "pf", "dd", "is_n", "is_R", "is_pf",
                    "oos_n", "oos_R", "oos_pf"])
        for (m, tg, rr, tr), st, si_, so_ in summary:
            w.writerow([m, tg, rr, int(tr), st["n"], round(st["win"], 1), round(st["total"], 1), round(st["pf"], 2),
                        round(st["dd"], 1), si_["n"], round(si_["total"], 1), round(si_["pf"], 2),
                        so_["n"], round(so_["total"], 1), round(so_["pf"], 2)])

    cb, st, si_, so_ = summary[0]
    per = res[cb]
    print("\n" + "=" * 90)
    print(f"最佳組合：{name(cb)}   全部 {st['n']}筆 PF{st['pf']:.2f} {st['total']:+.1f}R 最大回撤 {st['dd']:.1f}R "
          f"（帳戶 {st['total'] * RISK_PCT:+.1f}%，每筆風險 {RISK_PCT}%）")
    if cut:
        print(f"  樣本內 PF{si_['pf']:.2f} {si_['total']:+.1f}R ({si_['n']}筆) | 樣本外 PF{so_['pf']:.2f} {so_['total']:+.1f}R ({so_['n']}筆)")
    print("=" * 90)
    grp = defaultdict(list)
    for s, rs in per.items():
        grp[symbol_group(s)] += [r for _, r in rs]
    print("— 依分組 —")
    for g in GROUP_NAMES:
        if grp.get(g):
            x = stats(grp[g])
            print(f"  {GROUP_NAMES[g]:<6} {x['n']:5d}筆 勝率{x['win']:5.1f}% {x['total']:+8.1f}R PF{x['pf']:.2f}")
    yr = defaultdict(list)
    for rs in per.values():
        for t0, r in rs:
            yr[t0.year].append(r)
    print("— 依年度 —")
    for y in sorted(yr):
        x = stats(yr[y])
        print(f"  {y} {x['n']:5d}筆 {x['total']:+8.1f}R PF{x['pf']:.2f}")

    if cut:
        rows = []
        for s, rs in per.items():
            rows.append((s, stats([r for t0, r in rs if t0 < cut]), stats([r for t0, r in rs if t0 >= cut])))
        mi, mo = a.min_trades, a.min_trades // 2
        good = [x for x in rows if x[1]["n"] >= mi and x[2]["n"] >= mo and x[1]["pf"] > 1 and x[2]["pf"] > 1]
        good.sort(key=lambda x: -min(x[1]["pf"], x[2]["pf"]))
        print(f"\n— 樣本內、樣本外都賺的商品（內≥{mi}筆、外≥{mo}筆）：{len(good)} / {len(rows)} 個 —")
        for s, xi, xo in good:
            print(f"  ✅ {s:<12} 內 {xi['n']:4d}筆 PF{xi['pf']:.2f} {xi['total']:+6.1f}R | 外 {xo['n']:4d}筆 PF{xo['pf']:.2f} {xo['total']:+6.1f}R")
        exp = sum(1 for _, xi, _ in rows if xi["n"] >= mi and xi["pf"] > 1) * \
            sum(1 for _, _, xo in rows if xo["n"] >= mo and xo["pf"] > 1) / max(len(rows), 1)
        print(f"  （參考：純靠運氣預期約 {exp:.0f} 個商品會兩段都賺；實際 {len(good)} 個）")
        if good:
            print("  InpSymbols 可填：" + ",".join(s for s, _, _ in good))
    print(f"\n全部組合：{os.path.abspath(a.out)}")


if __name__ == "__main__":
    main()
