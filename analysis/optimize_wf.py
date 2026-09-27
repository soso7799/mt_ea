"""
各商品指標參數最佳化 —— 滾動式（walk-forward），避免「事後挑最好」的偏差

  每一輪：用過去 TRAIN 週挑出最佳參數組合 → 用它交易接下來 TEST 週 → 往前推 TEST 週再重來
  只統計每輪「下 TEST 週」的交易（挑參數時沒看過的資料），等於模擬每月重新調參數的真實結果。

  觸發（你圖上的指標）：
    MA 交叉：EMA 快線上穿/下穿慢線
    MACD Hull：主線上穿/下穿訊號線（移植自 Macd Hull.mq5，mladen）
    KDJ（移植自 KDJ_Averages.mq5，SMA 平滑）：K 上穿 D 且 K < 下限（做多）/ K 下穿 D 且 K > 上限（做空）；或 K 穿越 50 線
    TAI：由非多頭轉多頭動能（做多）/ 轉空頭動能（做空）（移植自 TAI_Color_Panel_Optimized.mq5）
  每個觸發 × 濾網（無 / 價格在 EMA50 同側且 EMA50 同向 / EMA100 同上）× 方向（順訊號 / 反向做）
       × 停損停利（ATR 倍數 1/1.5、1/2、1.5/3）；最多持有 48 根；同一組合一次只持有一筆
  成交：訊號 K 線收盤後、下一根開盤；買在 Ask、賣在 Bid；出場依 Bid/Ask；同根同時碰到 SL/TP 算 SL
  成本：點差（逐根）＋外匯手續費；報酬單位 R（1R = 停損距離）

用法：python optimize_wf.py --m1-cache H:\\...\\export\\bars --out H:\\...\\reports [--years 1] [--tf M5 M15]
"""
import argparse
import datetime as dt
import itertools
import os
import sys

import numpy as np
import pandas as pd

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "ml"))

from build_report import DEFAULT_SYMBOLS               # noqa: E402
from indicators import atr, ema, tai                   # noqa: E402
from levels_study import is_fx                         # noqa: E402

TRAIN_W, TEST_W = 12, 4
MAX_HOLD = 48
SLTP = [(1.0, 1.5), (1.0, 2.0), (1.5, 3.0)]
MIN_TRAIN_N = 20
# 你目前在圖上的設定（用來對照）
CURRENT = {"MACD Hull": "5/35/5", "KDJ": "9/3/3 區間20/80", "TAI": "MA28/週期5"}


# ---------------------------------------------------------------- 指標
def wma(x, n):
    n = int(n)
    if n <= 1:
        return x.copy()
    w = np.arange(1, n + 1, dtype=float)
    out = np.full(len(x), np.nan)
    if len(x) >= n:
        out[n - 1:] = np.convolve(x, w[::-1], mode="valid") / w.sum()
    return out


def hma(x, n):
    n = max(int(n), 2)
    half, sq = n // 2, int(np.floor(np.sqrt(n)))
    raw = 2 * wma(x, half) - wma(x, n)
    raw = np.where(np.isnan(raw), x, raw)
    return wma(raw, max(sq, 1))


def macd_hull(c, f, s, g):
    v = hma(c, f) - hma(c, s)
    v = np.nan_to_num(v)
    sig = pd.Series(v).ewm(span=g, adjust=False).mean().to_numpy()
    return v, sig


def kdj(h, l, c, n, mk, md):
    """移植自 KDJ_Averages.mq5（預設 SMA 平滑）：RSV → K=SMA(RSV,mk) → D=SMA(K,md)；J=3D-2K（該檔寫法）。"""
    ll = pd.Series(l).rolling(n, min_periods=n).min().to_numpy()
    hh = pd.Series(h).rolling(n, min_periods=n).max().to_numpy()
    warm = np.isnan(ll) | np.isnan(hh)
    ll, hh = np.fmin(c, ll), np.fmax(c, hh)
    rsv = np.where(hh != ll, 100.0 * (c - ll) / np.where(hh != ll, hh - ll, 1.0), 50.0)
    rsv = np.where(warm, np.nan, rsv)
    K = pd.Series(rsv).rolling(max(mk, 2), min_periods=max(mk, 2)).mean().to_numpy()
    D = pd.Series(K).rolling(max(md, 2), min_periods=max(md, 2)).mean().to_numpy()
    return K, D


def cross_up(a, b):
    return (a > b) & (np.r_[np.nan, a[:-1]] <= np.r_[np.nan, b[:-1]])


def onset(x):
    x = np.asarray(x, bool)
    return x & ~np.r_[False, x[:-1]]


def triggers(o, h, l, c):
    """回傳 list of (觸發名稱, 參數字串, long_bool, short_bool)。"""
    T = []
    E = {p: ema(c, p) for p in (5, 8, 13, 21, 34, 55, 89, 144)}
    for f, s in itertools.product((5, 8, 13, 21), (34, 55, 89, 144)):
        T.append(("MA交叉", f"EMA{f}/{s}", cross_up(E[f], E[s]), cross_up(E[s], E[f])))
    for f, s, g in ((5, 35, 5), (12, 26, 9), (8, 21, 5), (5, 20, 3), (10, 40, 7)):
        v, sg = macd_hull(c, f, s, g)
        T.append(("MACD Hull", f"{f}/{s}/{g}", cross_up(v, sg), cross_up(sg, v)))
    for n, m in itertools.product((9, 14, 21), (3, 5)):
        K, D = kdj(h, l, c, n, m, m)
        for lo, hi in ((20, 80), (30, 70)):
            T.append(("KDJ", f"{n}/{m}/{m} 區間{lo}/{hi}", cross_up(K, D) & (K < lo), cross_up(D, K) & (K > hi)))
        fifty = np.full(len(c), 50.0)
        T.append(("KDJ", f"{n}/{m}/{m} K穿50", cross_up(K, fifty), cross_up(fifty, K)))
    for ma, tp in itertools.product((14, 21, 28, 50), (5, 8)):
        col = tai(o, h, l, c, ma_period=ma, tai_period=tp)[1]
        T.append(("TAI", f"MA{ma}/週期{tp}", onset(col == 1), onset(col == 2)))
    return T


def trend_filters(c):
    out = {"無濾網": (np.ones(len(c), bool), np.ones(len(c), bool))}
    for p in (50, 100):
        e = ema(c, p)
        up = (c > e) & (e > np.r_[np.full(5, np.nan), e[:-5]])
        dn = (c < e) & (e < np.r_[np.full(5, np.nan), e[:-5]])
        out[f"EMA{p}趨勢"] = (up, dn)
    return out


# ---------------------------------------------------------------- 交易
def exits(idx, d, o, h, l, c, sp, a, sl_m, tp_m, comm_px):
    """向量化：每筆進場的出場索引與 R。"""
    n = len(c)
    e = idx + 1
    ok = (e < n) & ~np.isnan(a[idx]) & (a[idx] > 0)
    idx, d, e = idx[ok], d[ok], e[ok]
    if not len(e):
        return idx, e, e, np.array([])
    A = a[idx]
    entry = np.where(d > 0, o[e] + sp[e], o[e])
    sl = entry - d * sl_m * A
    tp = entry + d * tp_m * A
    J = e[:, None] + np.arange(MAX_HOLD)[None, :]
    valid = J < n
    Jc = np.minimum(J, n - 1)
    adj = np.where(d[:, None] < 0, sp[Jc], 0.0)
    hi, lo = h[Jc] + adj, l[Jc] + adj
    s_hit = np.where(d[:, None] > 0, lo <= sl[:, None], hi >= sl[:, None]) & valid
    t_hit = np.where(d[:, None] > 0, hi >= tp[:, None], lo <= tp[:, None]) & valid
    anyh = s_hit | t_hit
    has = anyh.any(1)
    first = np.argmax(anyh, 1)
    last = np.minimum(e + MAX_HOLD - 1, n - 1)
    rows = np.arange(len(e))
    is_sl = s_hit[rows, first]
    exit_px = np.where(has, np.where(is_sl, sl, tp), c[last] + np.where(d < 0, sp[last], 0.0))
    exit_i = np.where(has, e + first, last)
    R = ((exit_px - entry) * d - comm_px) / (sl_m * A)
    return idx, e, exit_i, R


def non_overlap(e, x):
    keep, busy = [], -1
    for k in range(len(e)):
        if e[k] > busy:
            keep.append(k)
            busy = x[k]
    return np.array(keep, dtype=int)


def combos_for(df, sym, point, contract, commission):
    o, h, l, c = (df[k].to_numpy(float) for k in ("open", "high", "low", "close"))
    sp = df["spread"].to_numpy(float) * point
    med = np.nanmedian(sp[sp > 0]) if (sp > 0).any() else point
    sp = np.where(sp > 0, sp, med)
    a = atr(h, l, c, 14)
    t = df["time"].to_numpy()
    comm_px = 0.0
    if is_fx(sym) and commission:
        comm_px = commission / contract * (1.0 if sym.endswith("USD") else np.nanmedian(c))
    F = trend_filters(c)
    out = []
    for trig, prm, lg, sh in triggers(o, h, l, c):
        for fname, (fu, fd) in F.items():
            L = np.flatnonzero(lg & fu)
            S = np.flatnonzero(sh & fd)
            idx = np.r_[L, S]
            dd = np.r_[np.ones(len(L), int), -np.ones(len(S), int)]
            order = np.argsort(idx, kind="stable")
            idx, dd = idx[order], dd[order]
            for mode in ("順訊號", "反向做"):
                dm = dd if mode == "順訊號" else -dd
                for sl_m, tp_m in SLTP:
                    i2, e, x, R = exits(idx, dm, o, h, l, c, sp, a, sl_m, tp_m, comm_px)
                    if not len(R):
                        continue
                    k = non_overlap(e, x)
                    out.append(dict(觸發=trig, 參數=prm, 濾網=fname, 方向=mode, SL=sl_m, TP=tp_m,
                                    t=t[e[k]], R=R[k]))
    return out


def stat(R):
    n = len(R)
    if n < 2:
        return n, (R.mean() if n else np.nan), np.nan
    sd = R.std(ddof=1)
    # 報酬幾乎相同（例如成本主導、每筆都同樣虧）時 t 值會爆大、沒有意義
    return n, R.mean(), (R.mean() / sd * np.sqrt(n) if sd > 1e-6 else np.nan)


def walk_forward(combos, t_start, t_end):
    weeks = pd.Timedelta(weeks=1)
    start = pd.Timestamp(t_start) + TRAIN_W * weeks
    rows, oos = [], []
    cur = start
    while cur + TEST_W * weeks <= pd.Timestamp(t_end) + weeks:
        tr0, tr1, te1 = cur - TRAIN_W * weeks, cur, cur + TEST_W * weeks
        best, best_t = None, -np.inf
        for cb in combos:
            m = (cb["t"] >= np.datetime64(tr0)) & (cb["t"] < np.datetime64(tr1))
            n, mu, tt = stat(cb["R"][m])
            if n >= MIN_TRAIN_N and mu > 0 and not np.isnan(tt) and tt > best_t:
                best, best_t = cb, tt
        if best is not None:
            m = (best["t"] >= np.datetime64(tr1)) & (best["t"] < np.datetime64(te1))
            r = best["R"][m]
            oos.append(r)
            rows.append(dict(訓練起=tr0.date(), 測試起=tr1.date(), 測試迄=te1.date(), 選到=f"{best['觸發']} {best['參數']}",
                             濾網=best["濾網"], 方向=best["方向"], SLTP=f"{best['SL']}/{best['TP']}",
                             訓練t=round(best_t, 2), 測試筆數=len(r), 測試平均R=r.mean() if len(r) else np.nan,
                             測試總R=r.sum()))
        else:
            rows.append(dict(訓練起=tr0.date(), 測試起=tr1.date(), 測試迄=te1.date(), 選到="（訓練期無達標組合，不交易）"))
        cur = te1
    R = np.concatenate(oos) if oos else np.array([])
    return rows, R


def latest_best(combos, t_end):
    tr1 = pd.Timestamp(t_end)
    tr0 = tr1 - pd.Timedelta(weeks=TRAIN_W)
    best, best_t = None, -np.inf
    for cb in combos:
        m = (cb["t"] >= np.datetime64(tr0)) & (cb["t"] <= np.datetime64(tr1))
        n, mu, tt = stat(cb["R"][m])
        if n >= MIN_TRAIN_N and mu > 0 and not np.isnan(tt) and tt > best_t:
            best, best_t, nn, mm = cb, tt, n, mu
    return (best, best_t, nn, mm) if best is not None else (None, np.nan, 0, np.nan)


def resample(m1, minutes):
    g = m1.set_index("time")
    r = g.resample(f"{minutes}min", label="left", closed="left").agg(
        {"open": "first", "high": "max", "low": "min", "close": "last", "tick_volume": "sum", "spread": "mean"}).dropna()
    return r.reset_index()


def main():
    ap = argparse.ArgumentParser(description="各商品指標滾動式最佳化")
    ap.add_argument("--symbols", nargs="*", default=DEFAULT_SYMBOLS)
    ap.add_argument("--m1-cache", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--terminal", default=None)
    ap.add_argument("--years", type=float, default=1.0)
    ap.add_argument("--to", default=None)
    ap.add_argument("--tf", nargs="*", default=["M5", "M15"], choices=["M5", "M15", "H1"])
    ap.add_argument("--commission", type=float, default=5.0)
    args = ap.parse_args()

    from mt5data import fetch_m1
    end = dt.datetime.fromisoformat(args.to) if args.to else dt.datetime.combine(dt.date.today(), dt.time())
    start = end - dt.timedelta(days=round(args.years * 365.25))
    summary, windows, params, current = [], [], [], []
    minutes = {"M5": 5, "M15": 15, "H1": 60}
    for s in args.symbols:
        try:
            got = fetch_m1([s], start - dt.timedelta(days=10), end, args.m1_cache, args.terminal)
        except SystemExit as e:
            print(f"⚠️ {s} 略過：{e}")
            continue
        m1, meta = got[s]
        m1 = m1[(m1["time"] >= pd.Timestamp(start)) & (m1["time"] < pd.Timestamp(end))]
        point = float(meta.get("point", 0.0001))
        contract = float(meta.get("contract") or 100000)
        for tf in args.tf:
            df = resample(m1, minutes[tf])
            if len(df) < 2000:
                continue
            combos = combos_for(df, s, point, contract, args.commission)
            rows, R = walk_forward(combos, df["time"].iloc[0], df["time"].iloc[-1])
            n, mu, tt = stat(R)
            wins = [r for r in rows if r.get("測試筆數")]
            pos = np.mean([r["測試總R"] > 0 for r in wins]) if wins else np.nan
            ok = n >= 30 and mu > 0 and (tt or 0) >= 2 and (pos or 0) >= 0.6
            b, bt, bn, bm = latest_best(combos, df["time"].iloc[-1])
            summary.append(dict(商品=s, 週期=tf, 滾動測試筆數=n, 平均R=mu, t值=tt,
                                勝率=(R > 0).mean() * 100 if len(R) else np.nan, 總R=R.sum() if len(R) else 0,
                                獲利輪數比例=pos * 100 if not np.isnan(pos) else np.nan, 輪數=len(rows),
                                判定="✅ 可用" if ok else "❌ 不穩定",
                                目前建議=(f"{b['觸發']} {b['參數']}｜{b['濾網']}｜{b['方向']}｜SL{b['SL']}/TP{b['TP']}"
                                      if b else "（近期無達標組合，建議不交易）"),
                                建議組合近12週t=bt, 建議組合近12週筆數=bn))
            for r in rows:
                windows.append(dict(商品=s, 週期=tf, **r))
            chosen = pd.Series([r["選到"] for r in rows if "選到" in r]).value_counts()
            for k, v in chosen.items():
                params.append(dict(商品=s, 週期=tf, 組合=k, 被選到輪數=v))
            # 你目前的設定：整段期間、前半/後半（順訊號、無濾網、SL1/TP2）
            for cb in combos:
                key = {"MACD Hull": cb["參數"] == "5/35/5", "KDJ": cb["參數"] in ("9/3/3 區間20/80", "9/3/3 K穿50"),
                       "TAI": cb["參數"] == "MA28/週期5"}.get(cb["觸發"], False)
                if key and cb["濾網"] == "無濾網" and cb["SL"] == 1.0 and cb["TP"] == 2.0:
                    mid = df["time"].iloc[len(df) // 2]
                    h1 = cb["R"][cb["t"] < np.datetime64(mid)]
                    h2 = cb["R"][cb["t"] >= np.datetime64(mid)]
                    n0, m0, t0 = stat(cb["R"])
                    current.append(dict(商品=s, 週期=tf, 指標=cb["觸發"], 參數=cb["參數"], 方向=cb["方向"],
                                        筆數=n0, 平均R=m0, t值=t0, 前半平均R=stat(h1)[1], 後半平均R=stat(h2)[1]))
            print(f"  {s} {tf}: 滾動測試 {n} 筆  平均 {mu:+.3f}R  t={tt if tt == tt else 0:.2f}  "
                  f"獲利輪數 {pos:.0%}  → {'✅' if ok else '❌'}")

    S = pd.DataFrame(summary)
    updated = dt.datetime.now().replace(microsecond=0)
    os.makedirs(args.out, exist_ok=True)
    path = os.path.join(args.out, f"指標滾動優化_{updated:%Y%m%d_%H%M}.xlsx")
    notes = [f"產生時間 {updated}；期間 {start.date()} ~ {end.date()}；週期 {', '.join(args.tf)}",
             f"滾動式最佳化：每輪用過去 {TRAIN_W} 週挑參數（交易≥{MIN_TRAIN_N}、平均R>0、t 最高），交易接下來 {TEST_W} 週，再往前推。",
             "『平均R / t值 / 勝率』只統計每輪『下 4 週』的交易 —— 挑參數時沒用到的資料，等於每月重新調參數的真實結果。",
             "觸發：MA交叉（EMA）、MACD Hull（移植自 Macd Hull.mq5）、KDJ（KDJ_Averages.mq5，K/D 交叉 + 區間，或 K 穿 50）、TAI（動能轉色）。",
             "每個觸發 × 濾網（無 / EMA50 趨勢 / EMA100 趨勢）× 方向（順訊號 / 反向做）× SL/TP（1/1.5、1/2、1.5/3 ATR），最多持有 48 根，一次一筆。",
             "成交：下一根開盤；買在 Ask、賣在 Bid；同根碰到 SL 與 TP 算 SL。成本：逐根點差 + 外匯手續費。1R = 停損距離。",
             "判定 ✅ 可用：滾動測試 ≥30 筆、平均R>0、t≥2、≥60% 的輪數獲利。",
             "『目前建議』= 用最近 12 週選出的組合（下個月要用的參數）；若該商品判定 ❌，建議參數也不可靠。",
             "『你目前的設定』= MACD Hull 5/35/5、KDJ 9/3/3、TAI MA28/週期5，順訊號與反向做，無濾網、SL1/TP2，整段期間與前後半。",
             f"注意：同時檢驗 {len(S)} 個商品×週期，即使完全隨機也可能有 1–2 個碰巧 ✅。"]
    with pd.ExcelWriter(path, engine="openpyxl") as xw:
        pd.DataFrame({"說明": notes}).to_excel(xw, sheet_name="說明", index=False)
        S.round(3).to_excel(xw, sheet_name="總結與建議參數", index=False)
        pd.DataFrame(current).round(3).to_excel(xw, sheet_name="你目前的設定", index=False)
        pd.DataFrame(windows).round(3).to_excel(xw, sheet_name="每輪明細", index=False)
        pd.DataFrame(params).to_excel(xw, sheet_name="參數穩定度", index=False)
        from openpyxl.styles import Font, PatternFill
        for ws in xw.sheets.values():
            for cc in ws[1]:
                cc.font = Font(bold=True, color="FFFFFF")
                cc.fill = PatternFill("solid", fgColor="1F4E78")
            for col in ws.columns:
                w = max(len(str(x.value or "")) for x in col[:300])
                ws.column_dimensions[col[0].column_letter].width = min(max(9, w * 1.4), 80)
            ws.freeze_panes = "A2"
            for row in ws.iter_rows(min_row=2):
                for cell in row:
                    if isinstance(cell.value, str) and cell.value.startswith("✅"):
                        cell.fill = PatternFill("solid", fgColor="C6EFCE")
    print(f"\n完成：{path}")
    ok = S[S["判定"].str.startswith("✅")] if len(S) else S
    print(f"\n✅ 可用：{len(ok)} / {len(S)}（純運氣預期約 {max(1, round(len(S) * 0.03))} 個）")
    for _, r in ok.iterrows():
        print(f"  {r['商品']} {r['週期']}: 平均 {r['平均R']:+.3f}R  t={r['t值']:.2f}  → 目前建議：{r['目前建議']}")


if __name__ == "__main__":
    main()
