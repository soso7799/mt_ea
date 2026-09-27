"""
全面探勘：任何指標 × 所有商品 × 多週期，用歷史資料找「真的有效」的規則

指標家族（約 150 種訊號）：EMA 交叉 / 價格穿 EMA、MACD、RSI、Stochastic、CCI、Williams %R、布林（回歸 / 突破）、
  Keltner 突破、Donchian 突破（海龜）、ADX/DI、動量、拋物線 SAR、SuperTrend、一目均衡（轉換/基準線）、Aroon、
  平均K（Heikin-Ashi）、吞噬、Pin bar、內包線突破、連續收漲/收跌、爆量長K，以及你的 MACD Hull / KDJ / J 線 / TAI / 趨勢線
每個訊號 × 濾網（無 / EMA200 同側）× 方向（順訊號 / 反向做）× 出場（SL/TP = 1/1、1/2、2/2、1.5/3 ATR，最多 48 根）
成交：下一根開盤、Bid/Ask、扣點差與外匯手續費；同一組合一次一筆。

防止「挑到運氣」的三段式：
  探勘期（前 50%）→ 挑出 t ≥ 3 的組合
  驗證期（接下來 25%）→ 只保留仍然賺、t ≥ 2 的
  期末考（最後 25%）→ 只對驗證通過的組合公布一次成績；✅ = 期末考也賺且 t ≥ 2
  另外把每筆交易的多空方向隨機翻轉（破壞所有規律）再跑同樣流程 3 次 → 「純運氣會通過幾個」
兩種規則：
  跨商品通用：同一組合套用到所有商品合計（較可信）；驗證期需 ≥55% 商品獲利
  單商品：只在某個商品有效（門檻更嚴，較容易是運氣）

用法：python mine_all.py --m1-cache H:\\...\\export\\bars --out H:\\...\\reports [--symbols all] [--years 2] [--tf M15 H1 H4]
"""
import argparse
import datetime as dt
import glob
import itertools
import os
import sys
import time as _time

import numpy as np
import pandas as pd

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "ml"))

from build_report import DEFAULT_SYMBOLS                                           # noqa: E402
from indicators import adx, atr, bollinger, cci, ema, keltner, macd, rsi, stoch, williams_r   # noqa: E402
from levels_study import is_fx                                                     # noqa: E402
import optimize_wf as ow                                                           # noqa: E402

EXITS = [(1.0, 1.0), (1.0, 2.0), (2.0, 2.0), (1.5, 3.0)]
NULL_K = 3
MINUTES = {"M5": 5, "M15": 15, "H1": 60, "H4": 240}


# ---------------------------------------------------------------- 額外指標
def full(v, n):
    return np.full(n, float(v))


def xup(a, b):
    b = b if np.ndim(b) else full(b, len(a))
    return ow.cross_up(a, b)


def xdn(a, b):
    b = b if np.ndim(b) else full(b, len(a))
    return ow.cross_up(b, a)


def psar(h, l, step=0.02, mx=0.2):
    n = len(h)
    up = np.zeros(n, bool)
    if n < 3:
        return up
    bull, af, ep, sar = True, step, h[0], l[0]
    for i in range(1, n):
        sar = sar + af * (ep - sar)
        if bull:
            sar = min(sar, l[i - 1], l[i - 2] if i > 1 else l[i - 1])
            if l[i] < sar:
                bull, sar, ep, af = False, ep, l[i], step
            elif h[i] > ep:
                ep, af = h[i], min(af + step, mx)
        else:
            sar = max(sar, h[i - 1], h[i - 2] if i > 1 else h[i - 1])
            if h[i] > sar:
                bull, sar, ep, af = True, ep, h[i], step
            elif l[i] < ep:
                ep, af = l[i], min(af + step, mx)
        up[i] = bull
    return up


def supertrend(h, l, c, n=10, mult=3.0):
    a = atr(h, l, c, n)
    mid = (h + l) / 2
    ub, lb = mid + mult * a, mid - mult * a
    fu, fl = ub.copy(), lb.copy()
    up = np.zeros(len(c), bool)
    for i in range(1, len(c)):
        if np.isnan(a[i]):
            continue
        fu[i] = ub[i] if (ub[i] < fu[i - 1] or c[i - 1] > fu[i - 1]) else fu[i - 1]
        fl[i] = lb[i] if (lb[i] > fl[i - 1] or c[i - 1] < fl[i - 1]) else fl[i - 1]
        up[i] = (c[i] > fu[i - 1]) if not up[i - 1] else not (c[i] < fl[i - 1])
    return up


def roll_max(x, n):
    return pd.Series(x).rolling(n, min_periods=n).max().to_numpy()


def roll_min(x, n):
    return pd.Series(x).rolling(n, min_periods=n).min().to_numpy()


def aroon(h, l, n=25):
    N = len(h)
    up, dn = np.full(N, np.nan), np.full(N, np.nan)
    if N > n:
        wh = np.lib.stride_tricks.sliding_window_view(h, n + 1)
        wl = np.lib.stride_tricks.sliding_window_view(l, n + 1)
        up[n:] = 100 * (np.argmax(wh[:, ::-1] == wh.max(1)[:, None], 1) * -1 + n) / n
        dn[n:] = 100 * (np.argmax(wl[:, ::-1] == wl.min(1)[:, None], 1) * -1 + n) / n
    return up, dn


def flip(state):
    s = np.asarray(state, bool)
    prev = np.r_[s[0], s[:-1]]
    return s & ~prev, ~s & prev


def signals(o, h, l, c, v, t):
    n = len(c)
    S = []
    E = {p: ema(c, p) for p in (5, 8, 10, 16, 20, 21, 50, 64, 100, 200)}
    for f, s in ((5, 20), (8, 21), (10, 50), (20, 50), (16, 64), (20, 100), (50, 200)):
        S.append(("EMA交叉", f"{f}/{s}", xup(E[f], E[s]), xdn(E[f], E[s])))
    for p in (20, 50, 100, 200):
        S.append(("價格穿EMA", f"EMA{p}", xup(c, E[p]), xdn(c, E[p])))
    for f, s, g in ((12, 26, 9), (5, 35, 5), (8, 17, 9)):
        m, sg = macd(c, f, s, g)
        S.append(("MACD", f"{f}/{s}/{g} 交叉", xup(m, sg), xdn(m, sg)))
        S.append(("MACD", f"{f}/{s}/{g} 穿0", xup(m, 0), xdn(m, 0)))
    for p in (7, 14, 21):
        r = rsi(c, p)
        for lo, hi in ((30, 70), (20, 80)):
            S.append(("RSI", f"{p} 離開{lo}/{hi}", xup(r, lo), xdn(r, hi)))
        S.append(("RSI", f"{p} 穿50", xup(r, 50), xdn(r, 50)))
    for k, d, sl in ((14, 3, 3), (5, 3, 3)):
        K, D = stoch(h, l, c, k, d, sl)
        S.append(("Stochastic", f"{k}/{d}/{sl} 區間交叉", xup(K, D) & (K < 20), xdn(K, D) & (K > 80)))
        S.append(("Stochastic", f"{k}/{d}/{sl} 穿50", xup(K, 50), xdn(K, 50)))
    for p in (14, 20):
        cc = cci(h, l, c, p)
        S.append(("CCI", f"{p} 離開±100", xup(cc, -100), xdn(cc, 100)))
        S.append(("CCI", f"{p} 穿0", xup(cc, 0), xdn(cc, 0)))
    wr = williams_r(h, l, c, 14)
    S.append(("Williams%R", "14 離開極端", xup(wr, -80), xdn(wr, -20)))
    for p, k in ((20, 2.0), (20, 2.5)):
        mid, up, lo = bollinger(c, p, k)
        S.append(("布林", f"{p}/{k} 回到帶內", xup(c, lo), xdn(c, up)))
        S.append(("布林", f"{p}/{k} 突破", xup(c, up), xdn(c, lo)))
    for p, k in ((20, 1.5), (20, 2.0)):
        mid, up, lo = keltner(h, l, c, p, k)
        S.append(("Keltner", f"{p}/{k} 突破", xup(c, up), xdn(c, lo)))
    for p in (20, 55):
        hh, ll = np.r_[np.nan, roll_max(h, p)[:-1]], np.r_[np.nan, roll_min(l, p)[:-1]]
        S.append(("Donchian", f"{p} 突破", ow.onset(c > hh), ow.onset(c < ll)))
    a_, pdi, ndi = adx(h, l, c, 14)
    for th in (20, 25):
        S.append(("ADX/DI", f"DI交叉 ADX>{th}", xup(pdi, ndi) & (a_ > th), xdn(pdi, ndi) & (a_ > th)))
    for p in (10, 20):
        m = c - np.r_[np.full(p, np.nan), c[:-p]]
        S.append(("動量", f"{p} 穿0", xup(m, 0), xdn(m, 0)))
    for st, mx in ((0.02, 0.2), (0.01, 0.1)):
        b, s_ = flip(psar(h, l, st, mx))
        S.append(("拋物線SAR", f"{st}/{mx}", b, s_))
    for p, k in ((10, 3.0), (10, 2.0)):
        b, s_ = flip(supertrend(h, l, c, p, k))
        S.append(("SuperTrend", f"{p}/{k}", b, s_))
    tk = (roll_max(h, 9) + roll_min(l, 9)) / 2
    kj = (roll_max(h, 26) + roll_min(l, 26)) / 2
    S.append(("一目均衡", "轉換線穿基準線", xup(tk, kj), xdn(tk, kj)))
    S.append(("一目均衡", "價格穿基準線", xup(c, kj), xdn(c, kj)))
    au, ad = aroon(h, l, 25)
    S.append(("Aroon", "25 交叉", xup(au, ad), xdn(au, ad)))
    hc = (o + h + l + c) / 4
    ho = np.empty(n)
    ho[0] = (o[0] + c[0]) / 2
    for i in range(1, n):
        ho[i] = (ho[i - 1] + hc[i - 1]) / 2
    g = hc > ho
    g2 = g & np.r_[False, g[:-1]]
    r2 = ~g & np.r_[False, ~g[:-1]]
    S.append(("平均K", "連 2 根轉色", ow.onset(g2), ow.onset(r2)))
    po, pc = np.r_[np.nan, o[:-1]], np.r_[np.nan, c[:-1]]
    S.append(("吞噬", "吞噬K", (c > o) & (pc < po) & (c >= po) & (o <= pc), (c < o) & (pc > po) & (c <= po) & (o >= pc)))
    rng = np.where(h - l > 0, h - l, np.nan)
    body = np.abs(c - o)
    low_w, up_w = np.minimum(o, c) - l, h - np.maximum(o, c)
    S.append(("Pin bar", "20根新低/高的長影線", (low_w >= 2 * body) & (low_w / rng >= 0.6) & (l <= roll_min(l, 20)),
              (up_w >= 2 * body) & (up_w / rng >= 0.6) & (h >= roll_max(h, 20))))
    mh, ml = np.r_[np.nan, np.nan, h[:-2]], np.r_[np.nan, np.nan, l[:-2]]
    ph, pl = np.r_[np.nan, h[:-1]], np.r_[np.nan, l[:-1]]
    inside = (ph <= mh) & (pl >= ml)
    S.append(("內包線", "突破母K", inside & (c > mh), inside & (c < ml)))
    upc = c > pc
    dnc = c < pc
    for k in (3, 4, 5):
        ku = pd.Series(upc.astype(float)).rolling(k).sum().to_numpy() == k
        kd = pd.Series(dnc.astype(float)).rolling(k).sum().to_numpy() == k
        S.append(("連續收漲跌", f"連{k}根", ow.onset(ku), ow.onset(kd)))
    va = pd.Series(v).rolling(20, min_periods=20).mean().to_numpy()
    big = (v > 2.5 * va) & (body / rng > 0.5)
    S.append(("爆量長K", "量>2.5倍均量", big & (c > o), big & (c < o)))
    for trig, prm, lg, sh in ow.triggers(o, h, l, c, t):
        if trig == "MA交叉":
            continue                       # 已有 EMA 交叉
        S.append((trig, prm, lg, sh))
    return S, E[200]


# ---------------------------------------------------------------- 統計
def seg_sums(seg, R, k=3):
    """回傳 (k, 3) 的 n / sum / sumsq（依 seg 0/1/2）。"""
    n = np.bincount(seg, minlength=k).astype(float)
    s = np.bincount(seg, weights=R, minlength=k)
    q = np.bincount(seg, weights=R * R, minlength=k)
    return np.c_[n, s, q]


def tstat(n, s, q):
    with np.errstate(divide="ignore", invalid="ignore"):
        m = s / n
        var = (q - n * m * m) / (n - 1)
        t = m / np.sqrt(var / n)
    return m, np.where((n >= 2) & (var > 1e-12), t, np.nan)


def discover_symbols(cache):
    got = sorted({os.path.basename(p).split("_M1")[0] for p in glob.glob(os.path.join(cache, "*_M1.csv.gz"))})
    try:
        import MetaTrader5 as mt5
        if mt5.initialize():
            vis = [s.name for s in (mt5.symbols_get() or []) if s.visible]
            mt5.shutdown()
            got = sorted(set(got) | set(vis))
    except Exception:
        pass
    return got


def run_symbol(sym, m1, meta, tfs, cuts, commission, rng):
    point = float(meta.get("point", 0.0001))
    contract = float(meta.get("contract") or 100000)
    rows = []
    for tf in tfs:
        df = ow.resample(m1, MINUTES[tf])
        if len(df) < 1500:
            continue
        o, h, l, c = (df[k].to_numpy(float) for k in ("open", "high", "low", "close"))
        v = df["tick_volume"].to_numpy(float)
        tt = df["time"].to_numpy()
        sp = df["spread"].to_numpy(float) * point
        med = np.nanmedian(sp[sp > 0]) if (sp > 0).any() else point
        sp = np.where(sp > 0, sp, med)
        comm_px = commission / contract * (1.0 if sym.endswith("USD") else np.nanmedian(c)) if is_fx(sym) and commission else 0.0
        A = atr(h, l, c, 14)
        SIG, e200 = signals(o, h, l, c, v, tt)
        filters = {"無濾網": (np.ones(len(c), bool), np.ones(len(c), bool)), "EMA200同側": (c > e200, c < e200)}
        for fam, prm, lg, sh in SIG:
            lg = np.nan_to_num(lg, nan=0).astype(bool)
            sh = np.nan_to_num(sh, nan=0).astype(bool)
            for fname, (fu, fd) in filters.items():
                L, S_ = np.flatnonzero(lg & fu), np.flatnonzero(sh & fd)
                idx = np.r_[L, S_]
                dd = np.r_[np.ones(len(L), int), -np.ones(len(S_), int)]
                order = np.argsort(idx, kind="stable")
                idx, dd = idx[order], dd[order]
                if len(idx) < 20:
                    continue
                for mode in ("順訊號", "反向做"):
                    dm = dd if mode == "順訊號" else -dd
                    for sl_m, tp_m in EXITS:
                        i2, e, x, R = ow.exits(idx, dm, o, h, l, c, sp, A, sl_m, tp_m, comm_px)
                        if len(R) < 10:
                            continue
                        k = ow.non_overlap(e, x)
                        e, R, i2 = e[k], R[k], i2[k]
                        seg = np.searchsorted(cuts, tt[e], side="right")
                        ok = seg <= 2
                        seg, R, e, i2 = seg[ok], R[ok], e[ok], i2[ok]
                        if not len(R):
                            continue
                        costR = (sp[e] + comm_px) / (sl_m * A[i2])
                        real = seg_sums(seg, R)
                        row = dict(商品=sym, 週期=tf, 家族=fam, 參數=prm, 濾網=fname, 方向=mode, SL=sl_m, TP=tp_m)
                        for si, nm in enumerate(("探勘", "驗證", "期末")):
                            row[f"{nm}_n"], row[f"{nm}_s"], row[f"{nm}_q"] = real[si]
                        for kk in range(NULL_K):
                            flipped = rng.choice([-1.0, 1.0], size=len(R)) * (R + costR) - costR
                            nul = seg_sums(seg, flipped)
                            for si, nm in enumerate(("探勘", "驗證", "期末")):
                                row[f"null{kk}_{nm}_n"], row[f"null{kk}_{nm}_s"], row[f"null{kk}_{nm}_q"] = nul[si]
                        rows.append(row)
    return rows


def select(D, prefix, pooled):
    """回傳各階段通過的遮罩（依 prefix = '' 真實 / 'nullK_' 對照）。"""
    m1, t1 = tstat(D[f"{prefix}探勘_n"], D[f"{prefix}探勘_s"], D[f"{prefix}探勘_q"])
    m2, t2 = tstat(D[f"{prefix}驗證_n"], D[f"{prefix}驗證_s"], D[f"{prefix}驗證_q"])
    m3, t3 = tstat(D[f"{prefix}期末_n"], D[f"{prefix}期末_s"], D[f"{prefix}期末_q"])
    if pooled:
        s1 = (D[f"{prefix}探勘_n"] >= 200) & (m1 > 0) & (t1 >= 3)
        s2 = s1 & (D[f"{prefix}驗證_n"] >= 100) & (m2 > 0) & (t2 >= 2) & (D[f"{prefix}驗證獲利商品比"] >= 0.55)
        s3 = s2 & (D[f"{prefix}期末_n"] >= 50) & (m3 > 0) & (t3 >= 2)
    else:
        s1 = (D[f"{prefix}探勘_n"] >= 60) & (m1 > 0) & (t1 >= 3.5)
        s2 = s1 & (D[f"{prefix}驗證_n"] >= 30) & (m2 > 0) & (t2 >= 2)
        s3 = s2 & (D[f"{prefix}期末_n"] >= 15) & (m3 > 0) & (t3 >= 1.5)
    return s1, s2, s3, (m1, t1, m2, t2, m3, t3)


def main():
    ap = argparse.ArgumentParser(description="全面探勘：任何指標 × 所有商品")
    ap.add_argument("--symbols", nargs="*", default=None, help="預設 = 快取裡所有商品 + MT5 市場報價中顯示的商品；可指定清單")
    ap.add_argument("--m1-cache", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--terminal", default=None)
    ap.add_argument("--years", type=float, default=2.0)
    ap.add_argument("--to", default=None)
    ap.add_argument("--tf", nargs="*", default=["M15", "H1", "H4"], choices=list(MINUTES))
    ap.add_argument("--commission", type=float, default=5.0)
    args = ap.parse_args()

    from mt5data import fetch_m1
    end = dt.datetime.fromisoformat(args.to) if args.to else dt.datetime.combine(dt.date.today(), dt.time())
    start = end - dt.timedelta(days=round(args.years * 365.25))
    span = end - start
    cuts = np.array([np.datetime64(start + span * 0.5), np.datetime64(start + span * 0.75), np.datetime64(end)])
    syms = args.symbols or discover_symbols(args.m1_cache) or DEFAULT_SYMBOLS
    if args.symbols == ["all"]:
        syms = discover_symbols(args.m1_cache)
    print(f"商品 {len(syms)} 個：{', '.join(syms)}")
    print(f"探勘期 {start.date()} ~ {(start + span * 0.5).date()}｜驗證期 ~ {(start + span * 0.75).date()}｜期末考 ~ {end.date()}")
    rng = np.random.default_rng(0)
    rows = []
    for s in syms:
        t0 = _time.time()
        try:
            got = fetch_m1([s], start - dt.timedelta(days=10), end, args.m1_cache, args.terminal)
        except SystemExit as e:
            print(f"⚠️ {s} 略過：{e}")
            continue
        m1, meta = got[s]
        m1 = m1[(m1["time"] >= pd.Timestamp(start)) & (m1["time"] < pd.Timestamp(end))]
        if len(m1) < 50000:
            print(f"⚠️ {s} 資料太少，略過")
            continue
        r = run_symbol(s, m1, meta, args.tf, cuts, args.commission, rng)
        rows += r
        print(f"  {s}: {len(r)} 個組合（{_time.time() - t0:.0f} 秒）")
    if not rows:
        raise SystemExit("沒有資料")
    D = pd.DataFrame(rows)
    key = ["週期", "家族", "參數", "濾網", "方向", "SL", "TP"]
    stage_cols = [c for c in D.columns if c.endswith(("_n", "_s", "_q"))]

    # ---- 跨商品通用（合計）
    P = D.groupby(key)[stage_cols].sum().reset_index()
    for pre in [""] + [f"null{k}_" for k in range(NULL_K)]:
        pos = D.assign(p=(D[f"{pre}驗證_s"] > 0) & (D[f"{pre}驗證_n"] > 0), has=D[f"{pre}驗證_n"] > 0) \
               .groupby(key)[["p", "has"]].sum().reset_index()
        P = P.merge(pos.rename(columns={"p": f"{pre}pos", "has": f"{pre}has"}), on=key)
        P[f"{pre}驗證獲利商品比"] = P[f"{pre}pos"] / P[f"{pre}has"].replace(0, np.nan)
    P = P.merge(D.groupby(key)["商品"].nunique().rename("商品數").reset_index(), on=key)
    D["驗證獲利商品比"] = 1.0
    for k in range(NULL_K):
        D[f"null{k}_驗證獲利商品比"] = 1.0

    luck = []
    res = {}
    for name, T, pooled in (("跨商品通用", P, True), ("單商品", D, False)):
        s1, s2, s3, st = select(T, "", pooled)
        res[name] = (s1, s2, s3, st)
        nulls = [select(T, f"null{k}_", pooled)[:3] for k in range(NULL_K)]
        luck.append(dict(規則類型=name, 檢驗組合數=len(T),
                         探勘通過=int(s1.sum()), 驗證通過=int(s2.sum()), 期末考通過=int(s3.sum()),
                         **{"純運氣_探勘通過(平均)": np.mean([x[0].sum() for x in nulls]),
                            "純運氣_驗證通過(平均)": np.mean([x[1].sum() for x in nulls]),
                            "純運氣_期末考通過(平均)": np.mean([x[2].sum() for x in nulls])}))
    L = pd.DataFrame(luck)

    def table(T, name):
        s1, s2, s3, (m1, t1, m2, t2, m3, t3) = res[name]
        cols = (["商品"] if "商品" in T.columns and name == "單商品" else []) + key
        X = T[cols].copy()
        X["探勘筆數"], X["探勘平均R"], X["探勘t"] = T["探勘_n"], m1, t1
        X["驗證筆數"], X["驗證平均R"], X["驗證t"] = T["驗證_n"], m2, t2
        if "驗證獲利商品比" in T.columns and name == "跨商品通用":
            X["驗證獲利商品比%"] = T["驗證獲利商品比"] * 100
        X["期末筆數"], X["期末平均R"], X["期末t"] = T["期末_n"], m3, t3
        X["判定"] = np.where(s3, "✅ 期末考通過", np.where(s2, "⚠️ 驗證通過、期末考未過", ""))
        return X[s2].sort_values("驗證t", ascending=False), X, t1

    Wp, Xp, tp1 = table(P, "跨商品通用")
    Ws, Xs, ts1 = table(D, "單商品")
    fam = Xp.assign(_t=tp1).sort_values("_t", ascending=False).groupby(["家族", "週期"]).head(1).drop(columns="_t") \
        .sort_values(["家族", "週期"])

    updated = dt.datetime.now().replace(microsecond=0)
    os.makedirs(args.out, exist_ok=True)
    path = os.path.join(args.out, f"全面探勘_{updated:%Y%m%d_%H%M}.xlsx")
    notes = [f"產生時間 {updated}；期間 {start.date()} ~ {end.date()}；週期 {', '.join(args.tf)}；商品 {D['商品'].nunique()} 個；"
             f"組合 {len(P)} 個（每商品）",
             f"探勘期 {start.date()} ~ {(start + span * 0.5).date()}；驗證期 ~ {(start + span * 0.75).date()}；期末考 ~ {end.date()}。",
             "跨商品通用：探勘 ≥200 筆、t≥3 → 驗證 ≥100 筆、t≥2、≥55% 商品獲利 → 期末考 ≥50 筆、平均R>0、t≥2 = ✅。",
             "單商品：探勘 ≥60 筆、t≥3.5 → 驗證 ≥30 筆、t≥2 → 期末考 ≥15 筆、平均R>0、t≥1.5 = ✅（容易是運氣，需看『運氣對照』）。",
             "『運氣對照』：把每筆交易的多空方向隨機翻轉（保留成本）後跑同樣流程；真實通過數要明顯多於純運氣才有意義。",
             "成交：下一根開盤、Bid/Ask、扣點差與外匯手續費；1R = 停損距離；同一組合一次一筆；最多持有 48 根。",
             "『各家族最佳』：每個指標家族、每個週期，探勘期 t 最高的組合，以及它在驗證期與期末考的表現（通常會退化，這就是過度擬合）。"]
    with pd.ExcelWriter(path, engine="openpyxl") as xw:
        pd.DataFrame({"說明": notes}).to_excel(xw, sheet_name="說明", index=False)
        L.round(1).to_excel(xw, sheet_name="運氣對照", index=False)
        Wp.round(3).to_excel(xw, sheet_name="跨商品通用規則", index=False)
        Ws.head(3000).round(3).to_excel(xw, sheet_name="單商品規則", index=False)
        fam.round(3).to_excel(xw, sheet_name="各家族最佳", index=False)
        from openpyxl.styles import Font, PatternFill
        for ws in xw.sheets.values():
            for cc in ws[1]:
                cc.font = Font(bold=True, color="FFFFFF")
                cc.fill = PatternFill("solid", fgColor="1F4E78")
            for col in ws.columns:
                w = max(len(str(x.value or "")) for x in col[:300])
                ws.column_dimensions[col[0].column_letter].width = min(max(9, w * 1.3), 50)
            ws.freeze_panes = "A2"
            for row in ws.iter_rows(min_row=2):
                for cell in row:
                    if isinstance(cell.value, str) and cell.value.startswith("✅"):
                        cell.fill = PatternFill("solid", fgColor="C6EFCE")
    print(f"\n完成：{path}\n")
    for _, r in L.iterrows():
        print(f"  {r['規則類型']}：檢驗 {r['檢驗組合數']:,} 個 → 探勘 {r['探勘通過']} → 驗證 {r['驗證通過']} → 期末考 ✅ {r['期末考通過']}"
              f"   ｜純運氣平均：{r['純運氣_探勘通過(平均)']:.0f} → {r['純運氣_驗證通過(平均)']:.1f} → {r['純運氣_期末考通過(平均)']:.1f}")
    for nm, W in (("跨商品通用", Wp), ("單商品", Ws)):
        ok = W[W["判定"].str.startswith("✅")]
        print(f"\n  {nm} ✅（前 10）：")
        for _, r in ok.head(10).iterrows():
            who = f"{r['商品']} " if "商品" in r else ""
            print(f"    {who}{r['週期']} {r['家族']} {r['參數']}｜{r['濾網']}｜{r['方向']}｜SL{r['SL']}/TP{r['TP']}  "
                  f"探勘 {r['探勘平均R']:+.3f}R 驗證 {r['驗證平均R']:+.3f}R 期末 {r['期末平均R']:+.3f}R（{int(r['期末筆數'])} 筆）")


if __name__ == "__main__":
    main()
