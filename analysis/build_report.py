"""
產生「跨週期 11 大指標分析」Excel（取代原本 AI 拼湊、沒有計算依據的資料表）。

用法（Windows，FTMO 的 MT5 開著並已登入）：
    python build_report.py --cache H:\\...\\export\\bars_mtf --out H:\\...\\reports

每個數字都由本程式從 MT5 K 線實際計算；所有規則寫在「規則定義」分頁。
參數與規則一律只用前 70% 資料挑選，表上報告的是後 30%（樣本外）且已扣點差的結果。
"""
import argparse
import datetime as dt
import os
import sys

import numpy as np
import pandas as pd

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import votes as V                                   # noqa: E402
from analyze import analyze_symbol, current_signal, judge, rule_label   # noqa: E402
from data import TFS, fetch_all                     # noqa: E402
from groups import build_groups, reliability        # noqa: E402
from levels import levels                           # noqa: E402
from rules import RULE_DOCS, SL_GRID, TP_GRID       # noqa: E402
import engine                                       # noqa: E402

DEFAULT_SYMBOLS = ["EURUSD", "GBPUSD", "USDJPY", "USDCAD", "AUDUSD", "USDCHF", "USDCNH", "NZDUSD",
                   "US500.cash", "US30.cash", "US100.cash", "JP225.cash", "NATGAS.cash", "USOIL.cash",
                   "XAUAUD", "XAUUSD"]
TF_WEIGHT = {"D1": 0.35, "H4": 0.25, "H1": 0.20, "M15": 0.12, "M5": 0.08}
MS = {1: "多", -1: "空", 0: "—"}


def r(x, nd=3):
    if x is None:
        return None
    try:
        if np.isnan(x) or np.isinf(x):
            return None
    except TypeError:
        return x
    return round(float(x), nd)


def group_dir(lo, sh, need):
    return "多" if lo >= need else ("空" if sh >= need else "中性")


def resonance(sym_res, tf):
    """本週期與所有更高週期的狀態比較：全部同向=強共振；加權多數=偏多/偏空；否則分歧。"""
    order = TFS[:TFS.index(tf) + 1]
    w, s, same = 0.0, 0.0, set()
    for t in order:
        T = sym_res["tf"].get(t)
        if T is None:
            continue
        d = int(np.sign(T["lv"][-1] - T["sv"][-1]))
        same.add(d)
        s += TF_WEIGHT[t] * d
        w += TF_WEIGHT[t]
    if same == {1}:
        return "強多共振"
    if same == {-1}:
        return "強空共振"
    return "偏多" if s / w > 0.2 else ("偏空" if s / w < -0.2 else "分歧")


def trend_direction(sym_res):
    d = [np.sign(sym_res["tf"][t]["lv"][-1] - sym_res["tf"][t]["sv"][-1]) for t in ("D1", "H4") if t in sym_res["tf"]]
    return "多頭" if d and all(x > 0 for x in d) else ("空頭" if d and all(x < 0 for x in d) else "中性")


def rule_docs_rows():
    rows = [["類別", "項目", "定義"]]
    rows += [["資料", "來源", "FTMO MT5 終端，D1/H4/H1/M15/M5 已收盤 K 線（約 D1 10 年、H4 4 年、H1 2 年、M15 10 個月、M5 4 個月）"],
             ["資料", "成本", "每筆交易扣一次點差（該商品 K 線 spread 欄位中位數 × point ÷ 價格）"],
             ["資料", "樣本切分", "每個商品每個週期：前 70% K 線用來挑參數 / 挑規則；後 30% 只用來驗證（樣本外）"],
             ["指標", "11 指標多空票", "MA 短>長=多；RSI>50=多；K>D=多；PSY>50=多；%R>-50=多；MTM>0=多；MACD 主線>訊號線=多；"
                                    "收盤>布林中軌=多；CCI>0=多；BIAS>0=多；收盤>Keltner 中線=多；反之為空"],
             ["指標", "參數最佳化", "每個指標在參數格中挑前 70% 期望值最高（且交易≥20 筆）的參數；"
                                 "『多商品參數優化』表上的勝率/交易數/Alpha/盈虧比/期望值都是這組參數在後 30% 的結果"],
             ["指標", "單一指標交易", "MA、KD、MACD：狀態翻轉即換倉；RSI：超賣回升做多、超買回落做空；"
                                   "布林/Keltner：突破上軌做多、跌破下軌做空；PSY/%R/MTM/CCI/BIAS：狀態翻轉換倉"],
             ["指標", "Alpha", "每筆報酬的平均 ÷ 標準差（每筆夏普值）"],
             ["指標", "期望值", "每筆平均報酬 %（已扣點差）"],
             ["分組", "趨勢組 / 動能組", "趨勢組 = MA、MTM、MACD、BOLL、BIAS、KELTNER（6 個）；"
                                      "動能組（震盪類方向）= RSI、KD、PSY、WR、CCI（5 個）"],
             ["分組", "震盪組（區間）", "RSI>上限、K>80、%R>-20、CCI>100、PSY>75 中 ≥3 個 = 超買；反向 ≥3 個 = 超賣；否則中性"],
             ["分組", "當前多空狀態", "多頭票 > 空頭票 = 多頭確認；反之空頭確認"],
             ["分組", "盤勢", "ADX(14) ≥25 趨勢盤、≤20 盤整盤、其餘不明確"],
             ["分組", "綜合判定", "趨勢盤：依趨勢組方向（超買/超賣時加註過熱勿追）；盤整盤：超買=區間高檔（偏空）、超賣=區間低檔（偏多）、"
                                "否則區間中段（觀望）；不明確：≥7 票偏多/偏空，否則觀望"],
             ["分組", "跨週期共振", "本週期與所有更高週期狀態全部同向 = 強多/強空共振；以週期權重（D1 .35、H4 .25、H1 .20、M15 .12、M5 .08）"
                                "加權 >0.2 偏多、<-0.2 偏空，否則分歧"],
             ["分組", "趨勢線訊號", "擺動點（左右 5 根）連成壓力/支撐線；收盤突破壓力=向上突破、跌破支撐=向下突破；"
                                "兩線收斂=收斂待變；其他=區間整理中"],
             ["回測", "多商品回測摘要", "11 指標多空狀態翻轉即換倉（永遠持倉），全期間，已扣點差；後 30% 的平均報酬另列"],
             ["規則", "進出場", f"訊號 K 線收盤後、下一根開盤進場；SL/TP 為 ATR(14) 倍數（SL ∈ {SL_GRID}，TP ∈ {TP_GRID}）；"
                             "同一根同時碰到 SL 與 TP 視為 SL；最多持有 100 根"]]
    rows += [["規則", f"{k} {t}", d] for k, t, d in RULE_DOCS]
    rows += [["選規則", "挑選", "每個商品：所有週期 × 規則 × 變體 × SL/TP 中，只看前 70%，"
                              "取交易 ≥30、期望值 >0、獲利因子 ≥1.1 裡 t 值最高的一條"],
             ["選規則", "可進場", "該規則在後 30%：交易 ≥20、獲利因子 ≥1.3、t 值 ≥2.5"],
             ["選規則", "觀察", "後 30%：交易 ≥15、獲利因子 ≥1.15、t 值 ≥1.5"],
             ["選規則", "排除", "前 70% 選出的最佳規則，在後 30% 扣點差後期望值 ≤0"],
             ["選規則", "無驗證規則", "前 70% 就沒有規則達標，或後 30% 雖為正但未達觀察門檻"],
             ["選規則", "注意", "每個商品約比較上千種組合，前 70% 的最佳值必然偏樂觀；請只看後 30% 的數字"],
             ["選規則", "多重比較", "十幾個商品同時檢驗，即使行情完全隨機也可能有 1 個碰巧達到『可進場』；上線前需以最新資料再回測確認"],
             ["關卡", "時段", "UTC 亞盤 00–07、歐盤 07–13、美盤 13–21；伺服器時間 = 紐約時間 + 7 小時"],
             ["關卡", "近支撐/近壓力", "今日開盤、各時段高低、前日高低中，低於現價最近者 / 高於現價最近者"],
             ["關卡", "訊號", "現價 > 前日高 = 突破前日高；< 前日低 = 跌破前日低；距最近關卡 ≤0.05% = 接近該關卡；否則區間內"],
             ["分組", "避險分組", "近 251 天 D1 報酬相關係數：組內每對 ≥0.70 為同向組；與某組每個成員都 ≤-0.70 為反向避險"]]
    return rows


def main():
    ap = argparse.ArgumentParser(description="產生跨週期 11 大指標分析 Excel")
    ap.add_argument("--symbols", nargs="*", default=DEFAULT_SYMBOLS)
    ap.add_argument("--cache", required=True, help="K 線快取資料夾")
    ap.add_argument("--out", required=True, help="Excel 輸出資料夾")
    ap.add_argument("--terminal", default=None, help="terminal64.exe 路徑")
    ap.add_argument("--offline", action="store_true", help="只用快取，不連 MT5")
    ap.add_argument("--dashboard", default="USDJPY", help="儀表板預設商品")
    args = ap.parse_args()

    t0 = dt.datetime.now()
    print("讀取 / 下載 K 線 ...")
    frames, metas = fetch_all(args.symbols, args.cache, args.terminal, offline=args.offline)
    syms = [s for s in args.symbols if (s, "D1") in frames]
    ticks = [pd.Timestamp(m["tick_time"]) for m in metas.values() if m.get("tick_time")]
    server_now = max(ticks) if ticks else max(frames[(s, "M5")]["time"].iloc[-1] for s in syms if (s, "M5") in frames) \
        + pd.Timedelta(minutes=5)

    results = {}
    for s in syms:
        print(f"分析 {s} ...")
        results[s] = analyze_symbol(s, frames, metas.get(s, {}), server_now)
    groups, indep, ndays = build_groups({s: frames.get((s, "D1")) for s in syms})
    lvl = {s: levels(s, frames.get((s, "M5")), frames.get((s, "D1")), metas.get(s, {}), server_now) for s in syms}
    updated = dt.datetime.now().replace(microsecond=0)

    sheets = {}
    # ---------------- 多商品狀態總表
    st_rows = [["Symbol", "Period", "LatestTime", "LatestClose", "LongVotes", "ShortVotes", "Status", "TrendlineSignal",
                *V.ORDER, "趨勢組", "動能組", "震盪組", "ADX", "盤勢", "綜合判定"]]
    status_row = {}
    for s in syms:
        for tf, T in results[s]["tf"].items():
            lv, sv = int(T["lv"][-1]), int(T["sv"][-1])
            tdir = group_dir(T["tl"][-1], T["ts"][-1], 4)
            mdir = group_dir(T["ol"][-1], T["os"][-1], 3)
            row = [s, tf, T["df"]["time"].iloc[-1].to_pydatetime(), r(T["c"][-1], 6), lv, sv, T["status"][-1],
                   T["trendline"][-1], *[MS[int(x)] for x in T["st"][:, -1]], tdir, mdir, T["zone"][-1],
                   r(T["adx"][-1], 1), T["market"][-1],
                   judge(T["market"][-1], tdir, T["zone"][-1], lv, sv)]
            st_rows.append(row)
            status_row[(s, tf)] = row
    sheets["多商品狀態總表"] = st_rows

    # ---------------- 多商品參數優化
    op = [["Symbol", "Period", "Indicator", "BestParams", "WinRatePct", "Trades", "Alpha", "PayoffRatio",
           "ExpectancyPct", "前70%交易數", "前70%期望值%", "判定"]]
    for s in syms:
        for tf, T in results[s]["tf"].items():
            for ind in V.ORDER:
                o = T["opt"][ind]
                m, mi = o["oos"], o["is_"]
                verdict = "樣本外獲利" if m["n"] and m["exp"] > 0 else ("樣本外虧損" if m["n"] else "樣本外無交易")
                op.append([s, tf, ind, V.fmt_params(ind, o["params"]), r(m["win"], 1), m["n"], r(m["alpha"]),
                           r(m["payoff"], 2), r(m["exp"], 4), mi["n"], r(mi["exp"], 4), verdict])
    sheets["多商品參數優化"] = op

    # ---------------- 回測摘要 / 交易明細
    bs = [["Symbol", "Period", "TradeCount", "WinRatePct", "AvgReturnPct", "ProfitFactor", "t值", "後30%交易數", "後30%AvgReturnPct"]]
    td = [["Symbol", "Period", "EntryTime", "ExitTime", "Side", "EntryPrice", "ExitPrice", "Result", "ReturnPct"]]
    bt_best, last_trade, bt_stats = {}, {}, {}
    for s in syms:
        for tf, T in results[s]["tf"].items():
            fl = T["flips"]
            m = engine.metrics([x[3] for x in fl])
            _, oos = engine.split(fl, len(T["c"]))
            mo = engine.metrics([x[3] for x in oos])
            bs.append([s, tf, m["n"], r(m["win"], 1), r(m["exp"]), r(m["pf"], 2), r(m["t"], 2), mo["n"], r(mo["exp"])])
            bt_stats[(s, tf)] = m
            if m["n"] and (s not in bt_best or m["exp"] > bt_best[s][1]["exp"]):
                bt_best[s] = (tf, m)
            times = T["df"]["time"]
            for e, x, d, ret in fl[-20:]:
                td.append([s, tf, times.iloc[e].to_pydatetime(), times.iloc[x].to_pydatetime(), MS[d],
                           r(T["o"][e], 6), r(T["o"][x], 6), "獲利" if ret > 0 else "虧損", r(ret)])
                if s not in last_trade or times.iloc[x] > last_trade[s][2]:
                    last_trade[s] = (tf, d, times.iloc[x], ret)
    sheets["多商品回測摘要"] = bs
    sheets["多商品交易明細"] = td

    # ---------------- 進場信號
    es = [["Symbol", "TrendDirection", "D1_Status", "H4_Status", "H1_Status", "M15_Status", "M5_Status", "M5_LatestClose",
           "EntrySignal", "規則等級", "驗證規則", "後30%勝率%", "後30%獲利因子", "後30%t值", "訊號時間", "進場價", "停損", "停利",
           "最新K棒", "後30%交易數", "後30%期望值%", "前70%交易數", "前70%t值"]]
    sig = {}
    for s in syms:
        res = results[s]
        cs = current_signal(res)
        sig[s] = cs
        b = res.get("best_rule")
        stt = [res["tf"][t]["status"][-1] if t in res["tf"] else None for t in TFS]
        m5c = r(res["tf"]["M5"]["c"][-1], 6) if "M5" in res["tf"] else None
        dg = int(res["meta"].get("digits", 5))
        es.append([s, trend_direction(res), *stt, m5c, cs["text"], res["grade"], rule_label(b) if b else None,
                   r(b["oos"]["win"], 1) if b else None, r(b["oos"]["pf"], 2) if b else None,
                   r(b["oos"]["t"], 2) if b else None,
                   cs.get("time").to_pydatetime() if cs.get("time") is not None else None,
                   r(cs.get("price"), dg), r(cs.get("sl"), dg), r(cs.get("tp"), dg),
                   cs.get("bar").to_pydatetime() if cs.get("bar") is not None else None,
                   b["oos"]["n"] if b else None, r(b["oos"]["exp"], 4) if b else None,
                   b["is_"]["n"] if b else None, r(b["is_"]["t"], 2) if b else None])
    sheets["多商品進場信號"] = es

    # ---------------- 關卡 / 時段壓力支撐
    gk = [["商品", "即時Bid", "今日開盤", "今日開盤至今漲跌%", "亞盤低", "亞盤高", "歐盤低", "歐盤高", "美盤低", "美盤高",
           "前日高點", "前日低點", "近支撐", "近壓力", "更新時間", "資料新鮮度"]]
    ss = [["商品", "CurrentPrice", "今日開盤價", "漲跌%", "亞盤高", "亞盤低", "歐盤高", "歐盤低", "美盤高", "美盤低",
           "今高", "今低", "成交量", "均量", "量比", "Signal", "PrevDate"]]
    for s in syms:
        L = lvl[s]
        if not L:
            continue
        fetched = results[s]["meta"].get("fetched")
        gk.append([s, L["price"], L["open"], r(L["chg"]), L["亞盤低"], L["亞盤高"], L["歐盤低"], L["歐盤高"], L["美盤低"],
                   L["美盤高"], L["前日高點"], L["前日低點"], L["support"], L["resist"],
                   dt.datetime.fromisoformat(fetched) if fetched else updated, L["fresh"]])
        ss.append([s, L["price"], L["open"], r(L["chg"]), L["亞盤高"], L["亞盤低"], L["歐盤高"], L["歐盤低"], L["美盤高"],
                   L["美盤低"], L["今高"], L["今低"], L["vol"], r(L["vol_avg"], 1), r(L["vol_ratio"], 2), L["signal"],
                   L["prev_date"].to_pydatetime() if L["prev_date"] is not None else None])
    sheets["關卡"] = gk
    sheets["多商品時段壓力支撐"] = ss

    # ---------------- 波段避險分組
    gp = [["波段與避險商品分組（程式實測）"], [f"近 {ndays} 個交易日 D1 報酬率相關係數，產生時間 {updated}"], [], [],
          ["分組名稱", "包含商品", "實測相關係數 (D1報酬率)", "分組邏輯", "可能用途", "注意事項 / 可信度"]]
    grp_of = {}
    for g in groups:
        if g["kind"] == "same":
            gp.append([g["name"], ", ".join(g["members"]), f"平均 {g['avg']:.2f}（最低 {g['min']:.2f}）",
                       f"D1 報酬率相關係數 ≥ 0.70（近 {ndays} 天）",
                       "同組同方向持有＝加碼同一風險，擇一交易或減量；一多一空可互相避險", reliability(g, ndays)])
            for m in g["members"]:
                grp_of[m] = (g["name"], ", ".join(x for x in g["members"] if x != m), reliability(g, ndays))
        else:
            gp.append([g["name"], f"{g['members'][0]}  ↔  {', '.join(g['against'])}",
                       f"平均 {g['avg']:.2f}（最弱 {g['min']:.2f}）", f"D1 報酬率相關係數 ≤ -0.70（近 {ndays} 天）",
                       "兩邊同方向持有可互相避險；一多一空＝加碼同一風險", reliability(g, ndays)])
            grp_of[g["members"][0]] = (g["name"], ", ".join(g["against"]), reliability(g, ndays))
    gp.append(["獨立商品", ", ".join(indep), None, "無法和其他商品組成每一對都 ≥0.70 的同向組，也沒有 ≤-0.70 的反向對",
               "走勢相對獨立，可單獨操作、分散風險", f"（{ndays} 天樣本）"])
    for m in indep:
        grp_of.setdefault(m, ("獨立商品", None, f"（{ndays} 天樣本）"))
    sheets["波段避險分組"] = gp

    # ---------------- 總整理
    zz = [["Symbol", "現價", "今日開盤價", "漲跌%", "長週期趨勢", "D1", "H4", "H1", "M15", "M5", "進場信號", "最近關卡", "距離關卡",
           "關卡訊號", "最佳週期", "最佳週期勝率%", "最佳週期平均報酬%", "最近交易週期", "最近交易方向", "最近交易結果",
           "最近交易報酬%", "最近交易時間", "避險分組", "同組商品", "分組可信度", "M5趨勢訊號", "最後更新時間", "規則等級",
           "驗證規則", "進場價", "停損", "停利"]]
    for s in syms:
        res, L, cs = results[s], lvl[s] or {}, sig[s]
        bb = bt_best.get(s)
        lt = last_trade.get(s)
        g = grp_of.get(s, (None, None, None))
        b = res.get("best_rule")
        dg = int(res["meta"].get("digits", 5))
        zz.append([s, L.get("price"), L.get("open"), r(L.get("chg")), trend_direction(res),
                   *[res["tf"][t]["status"][-1] if t in res["tf"] else None for t in TFS], cs["text"],
                   L.get("nearest"), f"{L['nearest_pct']:.3f}%" if L else None, L.get("signal"),
                   bb[0] if bb else None, r(bb[1]["win"], 1) if bb else None, r(bb[1]["exp"]) if bb else None,
                   lt[0] if lt else None, MS[lt[1]] if lt else None, ("獲利" if lt[3] > 0 else "虧損") if lt else None,
                   r(lt[3]) if lt else None, lt[2].to_pydatetime() if lt else None, g[0], g[1], g[2],
                   res["tf"]["M5"]["trendline"][-1] if "M5" in res["tf"] else None, updated, res["grade"],
                   rule_label(b) if b else None, r(cs.get("price"), dg), r(cs.get("sl"), dg), r(cs.get("tp"), dg)])
    sheets["總整理"] = zz

    # ---------------- 儀表板資料（隱藏）
    dash = [["key"] + [f"v{i}" for i in range(1, 22)]]
    for s in syms:
        res = results[s]
        for tf, T in res["tf"].items():
            p = T["prm"]
            sltp = T.get("s1_sltp")
            a = T["atr"][-1]
            m = bt_stats.get((s, tf), {})
            dash.append([f"P|{s}|{tf}", r(sltp[0] * a, 6) if sltp else None, r(sltp[1] * a, 6) if sltp else None,
                         p["MA"]["s"], p["MA"]["l"], p["RSI"]["n"], p["RSI"]["lo"], p["RSI"]["hi"],
                         V.fmt_params("KD", p["KD"]), p["PSY"]["n"], 50, p["WR"]["n"], p["MTM"]["n"],
                         V.fmt_params("MACD", p["MACD"]), V.fmt_params("BOLL", p["BOLL"]), p["CCI"]["n"], p["BIAS"]["n"],
                         V.fmt_params("KELTNER", p["KELTNER"]),
                         f"{m.get('win', 0):.1f}% / {m.get('alpha', 0):.3f}" if m.get("n") else None, updated])
            row = status_row[(s, tf)]
            L = lvl[s] or {}
            op_ = L.get("open")
            dash.append([f"S|{s}|{tf}", row[2], row[3], row[4], row[5], row[6], TF_WEIGHT[tf], resonance(res, tf),
                         op_, r((row[3] / op_ - 1) * 100, 3) if op_ else None, row[4] - row[5], L.get("fresh"),
                         f"{row[-2]}（{row[-3]}）", row[-1]])
            dash.append([f"V|{s}|{tf}", *row[8:19], row[4], row[5]])
    sheets["_dash"] = dash
    sheets["規則定義"] = rule_docs_rows()

    os.makedirs(args.out, exist_ok=True)
    path = os.path.join(args.out, f"跨週期分析_{updated:%Y%m%d_%H%M}.xlsx")
    from workbook import write_workbook
    write_workbook(path, sheets, syms, args.dashboard if args.dashboard in syms else syms[0])
    latest = os.path.join(args.out, "跨週期分析_最新.xlsx")
    try:
        import shutil
        shutil.copyfile(path, latest)
    except OSError:
        latest = None
    print(f"\n完成（{(dt.datetime.now() - t0).total_seconds():.0f} 秒）：{path}")
    if latest:
        print(f"同時更新：{latest}")


if __name__ == "__main__":
    main()
