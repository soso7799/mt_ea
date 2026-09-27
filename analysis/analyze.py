"""
單一商品的完整分析：各週期 11 指標參數最佳化、投票狀態、分組判定、多空狀態回測、S1–S14 規則驗證、目前訊號。
"""
import numpy as np
import pandas as pd

import engine
import rules as R
import votes as V
from data import TFS, TF_MIN
from indicators import adx, atr, ema, stoch, bollinger, keltner, tai, swing_trendline

HTF = {"M5": "M15", "M15": "H1", "H1": "H4", "H4": "D1", "D1": None}
MIN_IS_TRADES = 20


def closed_bars(df, tf, server_now):
    """去掉還沒收盤的最後一根。"""
    if server_now is not None and len(df) and \
            df["time"].iloc[-1] + pd.Timedelta(minutes=TF_MIN[tf]) > server_now:
        return df.iloc[:-1].reset_index(drop=True)
    return df


def cost_pct(df, point):
    spr = df["spread"].replace(0, np.nan).median()
    if np.isnan(spr):
        spr = 1
    return float(spr * point / df["close"].median() * 100)


def optimize_indicator(ind, o, h, l, c, cost):
    """格點搜尋：前 70% 選最佳（期望值最高、交易 ≥20），回報該參數在後 30% 的表現。"""
    best = None
    for p in V.GRID[ind]:
        st, tr = V.compute(ind, p, o, h, l, c)
        trades = engine.flip_trades(tr, o, cost)
        is_, oos = engine.split(trades, len(c))
        m_is = engine.metrics([t[3] for t in is_])
        score = (m_is["n"] >= MIN_IS_TRADES, m_is["exp"] if m_is["n"] else -1e9)
        if best is None or score > best[0]:
            best = (score, p, st, tr, m_is, engine.metrics([t[3] for t in oos]))
    _, p, st, tr, m_is, m_oos = best
    return dict(params=p, state=st, trade=tr, is_=m_is, oos=m_oos)


def status_text(lv, sv):
    return np.where(lv > sv, "多頭確認", np.where(sv > lv, "空頭確認", "中性"))


def market_text(a):
    return np.where(a >= 25, "趨勢盤", np.where(a <= 20, "盤整盤", "不明確"))


def judge(market, tdir, zone, lv, sv):
    if market == "趨勢盤":
        if tdir == "多":
            return "多頭（過熱勿追）" if zone == "超買" else "多頭"
        if tdir == "空":
            return "空頭（過熱勿追）" if zone == "超賣" else "空頭"
        return "觀望"
    if market == "盤整盤":
        return {"超買": "區間高檔（偏空）", "超賣": "區間低檔（偏多）"}.get(zone, "區間中段（觀望）")
    return "偏多" if lv >= 7 else ("偏空" if sv >= 7 else "觀望")


def analyze_symbol(sym, frames, meta, server_now, log=print):
    point = float(meta.get("point", 0.0001))
    res = {"symbol": sym, "tf": {}, "meta": meta}
    for tf in TFS:
        df = frames.get((sym, tf))
        if df is None or len(df) < 300:
            log(f"    {sym} {tf}: 資料不足，略過")
            continue
        df = closed_bars(df, tf, server_now)
        o, h, l, c = (df[k].to_numpy(float) for k in ("open", "high", "low", "close"))
        cost = cost_pct(df, point)
        opt = {ind: optimize_indicator(ind, o, h, l, c, cost) for ind in V.ORDER}
        prm = {k: v["params"] for k, v in opt.items()}
        st = np.vstack([opt[k]["state"] for k in V.ORDER])
        lv, sv = (st == 1).sum(0), (st == -1).sum(0)
        ti = [V.ORDER.index(k) for k in V.TREND]
        oi = [V.ORDER.index(k) for k in V.OSC]
        tl, ts = (st[ti] == 1).sum(0), (st[ti] == -1).sum(0)
        ol, os_ = (st[oi] == 1).sum(0), (st[oi] == -1).sum(0)
        ax, _, _ = adx(h, l, c, 14)
        zn = V.zone(o, h, l, c, prm)
        K, D = stoch(h, l, c, prm["KD"]["k"], prm["KD"]["d"], prm["KD"]["s"])
        taic = {m: tai(o, h, l, c, ma_period=m, tai_period=5)[1] for m in (14, 28)}
        tln = swing_trendline(h, l, c, 5)
        a14 = atr(h, l, c, 14)

        # 多空狀態翻轉回測（回測摘要 / 交易明細）
        pos = np.where(lv > sv, 1, np.where(sv > lv, -1, 0))
        flips = engine.flip_trades(pos, o, cost)

        res["tf"][tf] = dict(
            df=df, o=o, h=h, l=l, c=c, cost=cost, opt=opt, prm=prm, st=st, lv=lv, sv=sv,
            tl=tl, ts=ts, ol=ol, os=os_, adx=ax, zone=zn, K=K, D=D, tai=taic, trendline=tln, atr=a14,
            ema200=ema(c, 200), boll=bollinger(c, prm["BOLL"]["n"], prm["BOLL"]["k"]),
            kelt=keltner(h, l, c, prm["KELTNER"]["n"], prm["KELTNER"]["m"]),
            status=status_text(lv, sv), market=market_text(ax), flips=flips)
        log(f"    {sym} {tf}: {len(df)} 根，成本 {cost:.4f}%")

    # 上一層週期的狀態（對齊到本週期，只用已收盤的上層 K 線）
    for tf, t in res["tf"].items():
        hi = HTF[tf]
        t["htf_state"] = None
        if hi and hi in res["tf"]:
            H = res["tf"][hi]
            hdf = pd.DataFrame({"t": H["df"]["time"] + pd.Timedelta(minutes=TF_MIN[hi]),
                                "s": np.sign(H["lv"] - H["sv"])})
            cur = pd.DataFrame({"t": t["df"]["time"] + pd.Timedelta(minutes=TF_MIN[tf])})
            m = pd.merge_asof(cur, hdf, on="t", direction="backward")
            t["htf_state"] = m["s"].fillna(0).to_numpy()

    evaluate_rules(res)
    return res


def evaluate_rules(res):
    cands = []
    for tf, t in res["tf"].items():
        ctx = dict(tf=tf, htf=HTF[tf], c=t["c"], long_votes=t["lv"], short_votes=t["sv"],
                   trend_long=t["tl"], trend_short=t["ts"], osc_long=t["ol"], osc_short=t["os"],
                   trade={k: v["trade"] for k, v in t["opt"].items()},
                   pstr={k: str(V.fmt_params(k, v)) for k, v in t["prm"].items()},
                   K=t["K"], D=t["D"], boll=t["boll"], kelt=t["kelt"], ema200=t["ema200"],
                   htf_state=t["htf_state"], adx=t["adx"], tai=t["tai"], trendline=t["trendline"])
        n = len(t["c"])
        t["s1_sltp"] = None
        best_s1 = None
        for rule in R.build(ctx):
            combos = [(sl, tp) for sl in R.SL_GRID for tp in R.TP_GRID] if rule["sltp"] else [(None, None)]
            for sl, tp in combos:
                tr = engine.event_trades(rule["idx"], rule["dirs"], t["o"], t["h"], t["l"], t["c"], t["atr"],
                                         sl, tp, t["cost"], exit_idx=rule["exit_idx"])
                is_, oos = engine.split(tr, n)
                m_is = engine.metrics([x[3] for x in is_])
                m_oos = engine.metrics([x[3] for x in oos])
                c = dict(tf=tf, rule=rule, sl=sl, tp=tp, is_=m_is, oos=m_oos, trades=tr)
                cands.append(c)
                if rule["rule"] == "S1" and rule["desc"].startswith("≥7") and m_is["n"]:
                    if best_s1 is None or m_is["exp"] > best_s1[0]:
                        best_s1 = (m_is["exp"], sl, tp)
        if best_s1:
            t["s1_sltp"] = best_s1[1:]
    res["candidates"] = cands

    # 只用前 70% 選：IS 交易 ≥30、期望值 >0、獲利因子 ≥1.1 中 t 值最高者
    ok = [c for c in cands if c["is_"]["n"] >= 30 and c["is_"]["exp"] > 0 and c["is_"]["pf"] >= 1.1
          and not np.isnan(c["is_"]["t"])]
    best = max(ok, key=lambda c: c["is_"]["t"]) if ok else None
    res["best_rule"] = best
    for c in cands:                      # 只保留最佳規則的交易明細，節省記憶體
        if c is not best:
            c["trades"] = None
    if best is None:
        res["grade"] = "無驗證規則"
        return
    m = best["oos"]
    if m["n"] and m["exp"] <= 0:
        res["grade"] = "排除"
    elif m["n"] >= 20 and m["pf"] >= 1.3 and m["t"] >= 2.5:
        res["grade"] = "可進場"
    elif m["n"] >= 15 and m["pf"] >= 1.15 and m["t"] >= 1.5:
        res["grade"] = "觀察"
    else:
        res["grade"] = "無驗證規則"


def rule_label(c):
    r = c["rule"]
    s = f"{c['tf']} {r['rule']} {r['title']}｜{r['desc']}"
    if c["sl"] is not None:
        s += f"+SL{c['sl']:.1f}/TP{c['tp']:.1f}"
    return s


def current_signal(res):
    """依選出的規則判斷目前：持多中/持空中/做多進場/做空進場/觀望。"""
    b = res.get("best_rule")
    g = res["grade"]
    if g == "排除":
        return dict(text="排除（回測扣點差後虧損）")
    if g == "無驗證規則" or b is None:
        return dict(text="無驗證規則（只看方向）")
    t = res["tf"][b["tf"]]
    n = len(t["c"])
    times = t["df"]["time"]
    pre = "觀察：" if g == "觀察" else ""
    last = b["trades"][-1] if b["trades"] else None
    if last and last[6] == "OPEN":
        e, _, d, _, sl, tp, _ = last
        return dict(text=pre + ("持多中" if d > 0 else "持空中"), time=times.iloc[e], price=t["o"][e],
                    sl=sl, tp=tp, bar=times.iloc[-1])
    ev = b["rule"]["idx"]
    if len(ev) and ev[-1] == n - 1:
        d = b["rule"]["dirs"][-1]
        px, a = t["c"][-1], t["atr"][-1]
        sl = px - d * b["sl"] * a if b["sl"] else None
        tp = px + d * b["tp"] * a if b["tp"] else None
        return dict(text=pre + ("做多進場（下一根開盤）" if d > 0 else "做空進場（下一根開盤）"),
                    time=times.iloc[-1], price=px, sl=sl, tp=tp, bar=times.iloc[-1])
    return dict(text=pre + "觀望", bar=times.iloc[-1])
