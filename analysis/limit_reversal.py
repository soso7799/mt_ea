"""
事先定好的單一假設：在昨日與各時段高低點掛限價單做反轉（不做參數搜尋，完整報告所有結果）

  關卡：昨高、昨低、昨亞高/低、昨歐高/低、昨美高/低（8 條，每天用前一日資料）
  掛單：關卡在價格上方 → 賣出限價；在下方 → 買入限價；價格須從一側靠近（前一根收盤距關卡 >0.1 ATR）
        每條關卡每天只成交第一次
  成交：賣出限價在 Bid 最高價 ≥ 關卡時成交；買入限價在 Ask 最低價（Bid 低 + 點差）≤ 關卡時成交
  停損：關卡外 0.3 ATR；停利：往回 1.0 ATR；最多持有 24 小時後以收盤平倉
        賣單以 Ask 判斷停損/停利、買單以 Bid 判斷；成交那根若也碰到停損 → 算停損（保守）
  ATR：預設用 H1 ATR(14)（上一根已收盤 H1），成交與出場用 M1 K 線模擬 → 同一根內先後誤差很小
  濾網：不限 / 靠近時量縮（前一根已收盤 M15 成交量 < 前 20 根平均 × 0.8，下單前就已知）
  報酬單位：R（1R = 0.3 ATR 停損距離），已含點差並扣外匯手續費

用法：python limit_reversal.py --m1-cache H:\\...\\export\\bars --out H:\\...\\reports [--years 1]
"""
import argparse
import datetime as dt
import os
import sys

import numpy as np
import pandas as pd

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "ml"))

from build_report import DEFAULT_SYMBOLS               # noqa: E402
from indicators import atr                             # noqa: E402
from levels import server_to_utc                       # noqa: E402
from levels_study import daily_levels, is_fx, session_hours, set_sessions   # noqa: E402

LEVELS = ["昨高", "昨低", "昨亞高", "昨亞低", "昨歐高", "昨歐低", "昨美高", "昨美低"]
SL_ATR, TP_ATR, TOL, HOLD_H, VOL_TH = 0.3, 1.0, 0.1, 24, 0.8


def higher_tf_atr(m1, rule):
    """把 M1 重組成較高週期，算 ATR(14)，對應回每根 M1（只用已收盤的那根）。"""
    g = m1.set_index("time")
    r = g[["open", "high", "low", "close"]].resample(rule, label="left", closed="left").agg(
        {"open": "first", "high": "max", "low": "min", "close": "last"}).dropna()
    a = pd.Series(atr(r["high"].to_numpy(), r["low"].to_numpy(), r["close"].to_numpy(), 14), index=r.index)
    a.index = a.index + pd.Timedelta(rule)          # 收盤後才可用
    return a.reindex(m1["time"], method="ffill").to_numpy()


def m15_volume_ratio(m1):
    g = m1.set_index("time")["tick_volume"].resample("15min", label="left", closed="left").sum()
    g = g[g > 0]
    ratio = g / g.rolling(20, min_periods=20).mean().shift(1)
    ratio.index = ratio.index + pd.Timedelta("15min")   # 收盤後才可用
    return ratio.reindex(m1["time"], method="ffill").to_numpy()


def run_symbol(sym, m1, point, contract, commission, atr_rule):
    t = m1["time"]
    o, h, l, c = (m1[k].to_numpy(float) for k in ("open", "high", "low", "close"))
    sp = m1["spread"].to_numpy(float) * point
    med = np.nanmedian(sp[sp > 0]) if (sp > 0).any() else point
    sp = np.where(sp > 0, sp, med)
    A = higher_tf_atr(m1, atr_rule)
    volr = m15_volume_ratio(m1)
    n = len(c)
    lv, day = daily_levels(m1, session_hours(t))
    hold = HOLD_H * 60
    day_start = np.r_[0, np.flatnonzero(day[1:] != day[:-1]) + 1]
    day_end = np.r_[day_start[1:], n]
    comm_q = commission / contract if (is_fx(sym) and commission) else 0.0
    cprev = np.r_[np.nan, c[:-1]]
    out = []
    for name in LEVELS:
        Lall = lv[name]
        for a0, b0 in zip(day_start, day_end):
            L = Lall[a0]
            if np.isnan(L):
                continue
            s = slice(max(a0, 1), b0)
            at = A[s]
            tol = TOL * at
            below = cprev[s] < L - tol
            above = cprev[s] > L + tol
            f_sell = below & (h[s] >= L)
            f_buy = above & (l[s] + sp[s] <= L)
            f = (f_sell | f_buy) & ~np.isnan(at) & (at > 0)
            if not f.any():
                continue
            i = s.start + int(np.argmax(f))
            d = -1 if f_sell[i - s.start] else 1
            ai = A[i]
            sl, tp = L - d * SL_ATR * ai, L + d * TP_ATR * ai
            e = min(n, i + 1 + hold)
            adj = sp[i:e] if d < 0 else 0.0
            hi, lo = h[i:e] + adj, l[i:e] + adj
            s_hit = lo <= sl if d > 0 else hi >= sl
            t_hit = hi >= tp if d > 0 else lo <= tp
            t_hit[0] = False                       # 成交那根只看停損（保守）
            anyh = s_hit | t_hit
            if anyh.any():
                j = int(np.argmax(anyh))
                res, px = ("SL", sl) if s_hit[j] else ("TP", tp)
                j_exit = i + j
            else:
                j_exit = e - 1
                res, px = "TIME", c[j_exit] + (sp[j_exit] if d < 0 else 0.0)
            comm = comm_q * (1.0 if sym.endswith("USD") else L)
            pnl = (px - L) * d - comm
            out.append(dict(symbol=sym, time=t.iloc[i], level=name, side="賣(壓力)" if d < 0 else "買(支撐)",
                            vol=volr[i], quiet=bool(volr[i] < VOL_TH) if not np.isnan(volr[i]) else False,
                            result=res, R=pnl / (SL_ATR * ai), cost_R=(sp[i] + comm) / (SL_ATR * ai),
                            minutes=j_exit - i, same_bar_sl=bool(res == "SL" and j_exit == i)))
    return out


def summarize(g):
    r = g["R"].to_numpy()
    n = len(r)
    if n < 2:
        return dict(筆數=n)
    sd = r.std(ddof=1)
    return dict(筆數=n, 勝率=(g["result"] == "TP").mean() * 100, 停損率=(g["result"] == "SL").mean() * 100,
                同根停損率=g["same_bar_sl"].mean() * 100, 平均R=r.mean(),
                t值=r.mean() / sd * np.sqrt(n) if sd > 0 else np.nan, 總R=r.sum(), 平均成本R=g["cost_R"].mean())


def main():
    ap = argparse.ArgumentParser(description="關卡限價反轉（事先定好的單一假設，M1 模擬成交）")
    ap.add_argument("--symbols", nargs="*", default=DEFAULT_SYMBOLS)
    ap.add_argument("--m1-cache", required=True, help="M1 快取資料夾（與 Python 回測共用，例如 H:\\...\\export\\bars）")
    ap.add_argument("--out", required=True)
    ap.add_argument("--terminal", default=None)
    ap.add_argument("--years", type=float, default=1.0, help="往前幾年（預設 1）")
    ap.add_argument("--to", default=None, help="結束日期 YYYY-MM-DD（預設今天）")
    ap.add_argument("--atr-tf", default="1h", choices=["15min", "1h", "4h"], help="停損停利用哪個週期的 ATR（預設 1h）")
    ap.add_argument("--commission", type=float, default=5.0)
    ap.add_argument("--sessions", choices=["server", "utc"], default="server",
                    help="時段定義：server = 同 YesterdayHiL 指標（預設）；utc = UTC")
    args = ap.parse_args()
    set_sessions(args.sessions)

    from mt5data import fetch_m1
    end = dt.datetime.fromisoformat(args.to) if args.to else dt.datetime.combine(dt.date.today(), dt.time())
    start = end - dt.timedelta(days=round(args.years * 365.25) + 10)
    data = {}
    for s in args.symbols:
        try:
            data.update(fetch_m1([s], start, end, args.m1_cache, args.terminal))
        except SystemExit as e:
            print(f"⚠️ {s} 略過：{e}")
    rows = []
    for s, (m1, meta) in data.items():
        m1 = m1[m1["time"] >= pd.Timestamp(end - dt.timedelta(days=round(args.years * 365.25)))].reset_index(drop=True)
        rows += run_symbol(s, m1, float(meta.get("point", 0.0001)), float(meta.get("contract") or 100000),
                           args.commission, args.atr_tf)
        print(f"  {s}: 完成")
    if not rows:
        raise SystemExit("[錯誤] 沒有任何交易（沒有資料或關卡）")
    T = pd.DataFrame(rows).sort_values("time").reset_index(drop=True)
    cut = T["time"].iloc[len(T) // 2]
    T["half"] = np.where(T["time"] < cut, "前半", "後半")

    variants = {"不限": T, "靠近時量縮": T[T["quiet"]]}
    tabs = {"總結": pd.DataFrame([dict(濾網=v, 期間=p, **summarize(gg)) for v, g in variants.items()
                                   for p, gg in [("全部", g), ("前半", g[g["half"] == "前半"]), ("後半", g[g["half"] == "後半"])]])}
    for key, col in [("各商品", "symbol"), ("各關卡", "level"), ("買賣方向", "side")]:
        tabs[key] = pd.DataFrame([dict(濾網=v, **{col: k}, **summarize(gg),
                                       前半平均R=summarize(gg[gg["half"] == "前半"]).get("平均R"),
                                       後半平均R=summarize(gg[gg["half"] == "後半"]).get("平均R"))
                                  for v, g in variants.items() for k, gg in g.groupby(col)])

    updated = dt.datetime.now().replace(microsecond=0)
    os.makedirs(args.out, exist_ok=True)
    path = os.path.join(args.out, f"限價反轉_M1_{updated:%Y%m%d_%H%M}.xlsx")
    notes = [f"產生時間 {updated}；M1 模擬成交；ATR 用 {args.atr_tf}；期間 {T['time'].min()} ~ {T['time'].max()}；前後半分界 {cut}",
             "事先定好的單一假設，不做參數搜尋；以下所有結果完整列出。",
             "關卡：昨高、昨低、昨亞/歐/美盤高低（8 條）。上方掛賣出限價、下方掛買入限價，須從一側靠近，每條關卡每天只做第一次。",
             f"停損 = 關卡外 {SL_ATR} ATR；停利 = 往回 {TP_ATR} ATR；最多 {HOLD_H} 小時。ATR = {args.atr_tf} ATR(14)（上一根已收盤）。",
             "成交以 Bid/Ask 判斷；成交當根 M1 若也碰到停損 → 算停損（保守，『同根停損率』欄可檢查影響多大）。",
             f"濾網『靠近時量縮』= 前一根已收盤 M15 成交量 < 前 20 根平均 × {VOL_TH}（下單前已知）。",
             f"R = 損益 ÷ ({SL_ATR} ATR)，已含點差並扣外匯手續費 {args.commission} USD/手。未計成本的損益兩平勝率約 "
             f"{SL_ATR / (SL_ATR + TP_ATR) * 100:.0f}%。",
             "判定：前半、後半平均 R 都 >0、全部 t≥2、且 ≥60% 商品平均 R >0 → 值得寫成 EA。"]
    with pd.ExcelWriter(path, engine="openpyxl") as xw:
        pd.DataFrame({"說明": notes}).to_excel(xw, sheet_name="說明", index=False)
        for k, v in tabs.items():
            v.round(3).to_excel(xw, sheet_name=k, index=False)
        T.round(4).to_excel(xw, sheet_name="交易明細", index=False)
        from openpyxl.styles import Font, PatternFill
        for ws in xw.sheets.values():
            for cc in ws[1]:
                cc.font = Font(bold=True, color="FFFFFF")
                cc.fill = PatternFill("solid", fgColor="1F4E78")
            for col in ws.columns:
                w = max(len(str(x.value or "")) for x in col[:200])
                ws.column_dimensions[col[0].column_letter].width = min(max(9, w * 1.5), 80)
            ws.freeze_panes = "A2"
    print(f"\n完成：{path}\n")
    for vname, g in variants.items():
        s1, s2, s3 = summarize(g), summarize(g[g["half"] == "前半"]), summarize(g[g["half"] == "後半"])
        per = g.groupby("symbol")["R"].mean()
        share = (per > 0).mean() if len(per) else 0
        ok = s2.get("平均R", -1) > 0 and s3.get("平均R", -1) > 0 and s1.get("t值", 0) >= 2 and share >= 0.6
        print(f"[{vname}] 筆數 {s1.get('筆數')}  勝率 {s1.get('勝率', 0):.1f}%  同根停損 {s1.get('同根停損率', 0):.1f}%  "
              f"平均 {s1.get('平均R', 0):+.3f}R  t={s1.get('t值', 0):.2f}  前半 {s2.get('平均R', 0):+.3f}R  "
              f"後半 {s3.get('平均R', 0):+.3f}R  獲利商品 {share:.0%}  成本 {s1.get('平均成本R', 0):.2f}R  "
              f"→ {'✅ 值得寫成 EA' if ok else '❌ 不成立'}")
    print("\n各商品平均 R（不限）：")
    for s_, v in T.groupby("symbol")["R"].mean().sort_values(ascending=False).items():
        print(f"  {s_:<12} {v:+.3f}R")


if __name__ == "__main__":
    main()
