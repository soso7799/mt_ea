# -*- coding: utf-8 -*-
"""
build_extra_tables.py —— 產生 Excel 另外 4 張表的資料（由 make_levels.py 跑完後自動呼叫）

  multi_symbol_session_levels.csv   -> 多商品時段壓力支撐
  multi_symbol_entry_signals.csv    -> 多商品進場信號
  multi_symbol_backtest_summary.csv -> 多商品回測摘要
  multi_symbol_trades.csv           -> 多商品交易明細
  hedge_groups.csv                  -> 波段避險分組（D1 報酬率相關係數實測分組）
  summary_all.csv                   -> 總整理（每個商品一列，彙整上面所有表）

回測規則（跟儀表板一致）：11 個指標投票，多頭票 > 空頭票就持多、反之持空，
票數方向改變就平倉反手。每個週期用 MT5 最近 BACKTEST_BARS 根 K 棒。
"""
import csv
import os

import numpy as np
import pandas as pd

OUT_DIR = r"G:\我的雲端硬碟\整理後\update_output"
PERIODS = ["D1", "H4", "H1", "M15", "M5"]
BACKTEST_BARS = 1000
TRADES_PER_SERIES = 20      # 交易明細每個商品每個週期保留最近幾筆
NEAR_PCT = 0.10             # 現價距離關卡在 0.10% 以內算「接近」
CORR_BARS = 250             # 避險分組：用最近幾根 D1 算報酬率相關係數
CORR_GROUP = 0.70           # 相關係數 >= 這個值算同一組（同向）
CORR_HEDGE = -0.70          # 相關係數 <= 這個值算反向避險對


def read_csv(name):
    path = os.path.join(OUT_DIR, name)
    if not os.path.exists(path):
        return []
    with open(path, encoding="utf-8-sig", newline="") as f:
        return [r for r in csv.DictReader(f) if (r.get("Symbol") or "").strip()]


def write_csv(name, header, rows):
    path = os.path.join(OUT_DIR, name)
    with open(path, "w", encoding="utf-8-sig", newline="") as f:
        w = csv.writer(f)
        w.writerow(header)
        w.writerows(rows)
    print(f"[額外報表] {name}：{len(rows)} 列")


def num(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return None


# ------------------------------------------------------------------
# 11 指標訊號序列（+1 多 / -1 空），參數跟 compute_indicators.py 一樣
# ------------------------------------------------------------------
def ema(s, n):
    return s.ewm(span=n, adjust=False).mean()


def vote_series(df):
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
    longs = (m > 0).sum(axis=1)
    shorts = (m < 0).sum(axis=1)
    pos = pd.Series(np.where(longs > shorts, 1, np.where(shorts > longs, -1, 0)), index=df.index)
    pos[m.isna().any(axis=1)] = 0
    return pos


def backtest(df, pos):
    trades = []
    cur, entry_px, entry_t = 0, None, None
    closes, times = df["close"].values, df["datetime"].values
    for i in range(len(df)):
        p = int(pos.iloc[i])
        if p == 0 or p == cur:
            continue
        if cur != 0:
            ret = cur * (closes[i] - entry_px) / entry_px * 100
            trades.append((entry_t, times[i], "多" if cur > 0 else "空", entry_px, closes[i], ret))
        cur, entry_px, entry_t = p, closes[i], times[i]
    return trades


def fmt_t(t):
    return pd.Timestamp(t).strftime("%Y-%m-%d %H:%M")


# ------------------------------------------------------------------
def build_session_table(mt5):
    """多商品時段壓力支撐；回傳 {商品: (最近關卡, 距離%, 訊號)} 給總整理用"""
    opens = {r["Symbol"].strip(): r for r in read_csv("today_open.csv")}
    rows, near = [], {}
    for r in read_csv("session_levels.csv"):
        sym = r["Symbol"].strip()
        price = num(r.get("CurrentPrice"))
        o = opens.get(sym, {})
        op = num(o.get("TodayOpen"))
        chg = f"{(price - op) / op * 100:.3f}" if price and op else ""
        levels = {}
        for key, label in [("Asian_High", "亞盤高"), ("Asian_Low", "亞盤低"),
                           ("European_High", "歐盤高"), ("European_Low", "歐盤低"),
                           ("US_High", "美盤高"), ("US_Low", "美盤低"),
                           ("PrevDay_High", "前日高"), ("PrevDay_Low", "前日低"),
                           ("Recent_Support", "今低"), ("Recent_Resistance", "今高")]:
            v = num(r.get(key))
            if v is not None:
                levels[label] = (v, r.get(key).strip())
        nearest, dist = "", ""
        signal = "無資料"
        if price and levels:
            label, (lv, lv_txt) = min(levels.items(), key=lambda kv: abs(price - kv[1][0]))
            nearest = f"{label} {lv_txt}"
            dist_pct = (price - lv) / price * 100
            dist = f"{dist_pct:.3f}%"
            pdh, pdl = (levels.get("前日高") or (None,))[0], (levels.get("前日低") or (None,))[0]
            if pdh and price > pdh:
                signal = "突破前日高"
            elif pdl and price < pdl:
                signal = "跌破前日低"
            elif abs(dist_pct) <= NEAR_PCT:
                signal = f"接近{label}"
            else:
                signal = "區間內"
        near[sym] = (nearest, dist, signal)
        # 成交量 = 最近一根已收盤 M5 的量；均量 = 它前面 20 根 M5 的平均；量比 = 成交量 / 均量
        vol, avg_vol, vol_ratio = "", "", ""
        if mt5 is not None:
            rates = mt5.copy_rates_from_pos(sym, mt5.TIMEFRAME_M5, 1, 21)
            if rates is not None and len(rates) >= 2:
                vols = [float(x["tick_volume"]) for x in rates]
                v_last, v_avg = vols[-1], sum(vols[:-1]) / len(vols[:-1])
                vol, avg_vol = f"{v_last:.0f}", f"{v_avg:.0f}"
                if v_avg > 0:
                    vol_ratio = f"{v_last / v_avg:.2f}"
        rows.append([sym, r.get("CurrentPrice", ""), o.get("TodayOpen", ""), chg,
                     r.get("Asian_High", ""), r.get("Asian_Low", ""),
                     r.get("European_High", ""), r.get("European_Low", ""),
                     r.get("US_High", ""), r.get("US_Low", ""),
                     r.get("Recent_Resistance", ""), r.get("Recent_Support", ""),
                     vol, avg_vol, vol_ratio, signal, r.get("PrevDate", "")])
    write_csv("multi_symbol_session_levels.csv",
              ["商品", "CurrentPrice", "今日開盤價", "漲跌%", "亞盤高", "亞盤低", "歐盤高", "歐盤低",
               "美盤高", "美盤低", "今高", "今低", "成交量", "均量", "量比", "Signal", "PrevDate"], rows)
    return near


def build_entry_table():
    status = {}
    for r in read_csv("multi_symbol_status.csv"):
        status[(r["Symbol"].strip(), r["Period"].strip())] = r
    trend = {r["Symbol"].strip(): r.get("綜合長週期判定", "") for r in read_csv("higher_tf_trend.csv")}
    rows = []
    for sym in sorted({s for s, _ in status}):
        st = {p: (status.get((sym, p)) or {}).get("Status", "") for p in PERIODS}
        m5_close = (status.get((sym, "M5")) or {}).get("LatestClose", "")
        if num(m5_close) is not None:
            m5_close = repr(round(num(m5_close), 6))
            if m5_close.endswith(".0"):
                m5_close = m5_close[:-2]
        td = trend.get(sym, "")
        if td == "多頭" and st["M5"] == "多頭確認":
            sig = "做多"
        elif td == "空頭" and st["M5"] == "空頭確認":
            sig = "做空"
        else:
            sig = "觀望"
        rows.append([sym, td, st["D1"], st["H4"], st["H1"], st["M15"], st["M5"], m5_close, sig])
    write_csv("multi_symbol_entry_signals.csv",
              ["Symbol", "TrendDirection", "D1_Status", "H4_Status", "H1_Status",
               "M15_Status", "M5_Status", "M5_LatestClose", "EntrySignal"], rows)
    return sorted({s for s, _ in status})


def build_backtest_tables(mt5, symbols):
    summary, detail = [], []
    best, last_trade = {}, {}
    for sym in symbols:
        if not mt5.symbol_select(sym, True):
            continue
        for p in PERIODS:
            rates = mt5.copy_rates_from_pos(sym, getattr(mt5, "TIMEFRAME_" + p), 0, BACKTEST_BARS)
            if rates is None or len(rates) < 100:
                continue
            df = pd.DataFrame(rates)
            df["datetime"] = pd.to_datetime(df["time"], unit="s")
            info = mt5.symbol_info(sym)
            dg = info.digits if info else 5
            trades = backtest(df, vote_series(df))
            n = len(trades)
            wins = sum(1 for t in trades if t[5] > 0)
            summary.append([sym, p, n,
                            f"{wins / n * 100:.1f}" if n else "",
                            f"{np.mean([t[5] for t in trades]):.3f}" if n else ""])
            if n:
                avg = float(np.mean([t[5] for t in trades]))
                if sym not in best or avg > best[sym][2]:
                    best[sym] = (p, wins / n * 100, avg)
                et, xt, side, epx, xpx, ret = trades[-1]
                if sym not in last_trade or pd.Timestamp(xt) > pd.Timestamp(last_trade[sym][4]):
                    last_trade[sym] = (p, side, "獲利" if ret > 0 else "虧損", ret, xt)
            for et, xt, side, epx, xpx, ret in trades[-TRADES_PER_SERIES:]:
                detail.append([sym, p, fmt_t(et), fmt_t(xt), side, round(float(epx), dg), round(float(xpx), dg),
                               "獲利" if ret > 0 else "虧損", f"{ret:.3f}"])
    write_csv("multi_symbol_backtest_summary.csv",
              ["Symbol", "Period", "TradeCount", "WinRatePct", "AvgReturnPct"], summary)
    write_csv("multi_symbol_trades.csv",
              ["Symbol", "Period", "EntryTime", "ExitTime", "Side", "EntryPrice", "ExitPrice",
               "Result", "ReturnPct"], detail)
    return best, last_trade


# ------------------------------------------------------------------
# 波段避險分組：D1 報酬率相關係數
# ------------------------------------------------------------------
def d1_returns(mt5, symbols):
    rets = {}
    for sym in symbols:
        if not mt5.symbol_select(sym, True):
            continue
        rates = mt5.copy_rates_from_pos(sym, mt5.TIMEFRAME_D1, 0, CORR_BARS + 1)
        if rates is None or len(rates) < 60:
            continue
        df = pd.DataFrame(rates)
        day = pd.to_datetime(df["time"], unit="s").dt.normalize()
        rets[sym] = pd.Series(df["close"].values, index=day).pct_change().dropna()
    return pd.DataFrame(rets)


def confidence(c, n):
    lvl = "高" if abs(c) >= 0.85 else ("中" if abs(c) >= 0.75 else "低")
    return f"{lvl}（{n} 天樣本）"


def hedge_groups(ret):
    """回傳 (表格列, {商品: (分組名稱, 同組商品, 可信度)})"""
    rows, member = [], {}
    if ret.shape[1] < 2:
        return rows, member
    corr = ret.corr(min_periods=60)
    syms = list(corr.columns)
    n_days = int(ret.dropna(how="all").shape[0])
    # 同向組：組內「每一對」相關係數都要 >= CORR_GROUP（complete linkage 聚合，不會被間接串進來）
    def link(g1, g2):
        vals = [corr.at[a, b] for a in g1 for b in g2]
        return -2.0 if any(pd.isna(v) for v in vals) else float(min(vals))
    clusters = [[s0] for s0 in syms]
    while True:
        best_v, best_ij = -2.0, None
        for i in range(len(clusters)):
            for j in range(i + 1, len(clusters)):
                v = link(clusters[i], clusters[j])
                if v > best_v:
                    best_v, best_ij = v, (i, j)
        if best_ij is None or best_v < CORR_GROUP:
            break
        i, j = best_ij
        clusters[i] = clusters[i] + clusters[j]
        del clusters[j]
    gid = 0
    for comp in sorted(clusters, key=lambda c: (-len(c), sorted(c))):
        if len(comp) < 2:
            continue
        gid += 1
        comp.sort()
        pair = [corr.at[a, b] for i, a in enumerate(comp) for b in comp[i + 1:]]
        cmin, cavg = float(np.nanmin(pair)), float(np.nanmean(pair))
        name = f"同向組{gid}"
        conf = confidence(cmin, n_days)
        rows.append([name, ", ".join(comp), f"平均 {cavg:.2f}（最低 {cmin:.2f}）",
                     f"D1 報酬率相關係數 ≥ {CORR_GROUP:.2f}（近 {n_days} 天實測）",
                     "同組商品走勢同向：同時同方向持有＝加碼同一風險，擇一交易或減量；一多一空可互相避險",
                     conf])
        for a in comp:
            member[a] = (name, ", ".join(x for x in comp if x != a), conf)
    # 反向避險：以「組」為單位彙整（同一組內的商品算一個單位），避免同樣的關係列好幾次
    unit = {a: member[a][0] for a in member}
    members_of = {}
    for a in syms:
        members_of.setdefault(unit.get(a, a), []).append(a)
    # 兩個單位之間「每一對」都 <= CORR_HEDGE 才合併成一列；否則只列出真的符合的那幾對
    units = sorted(members_of)
    hedge_rows = []
    for i, ua in enumerate(units):
        for ub in units[i + 1:]:
            cs = [corr.at[a, b] for a in members_of[ua] for b in members_of[ub]]
            if any(pd.isna(c) for c in cs):
                continue
            if max(cs) <= CORR_HEDGE:
                hedge_rows.append((ua, ub, sorted(members_of[ua]), sorted(members_of[ub]), [float(c) for c in cs]))
            else:
                for a in members_of[ua]:
                    for b in members_of[ub]:
                        if corr.at[a, b] <= CORR_HEDGE:
                            hedge_rows.append((a, b, [a], [b], [float(corr.at[a, b])]))
    for ua, ub, ma, mb, cs in hedge_rows:
        name = f"反向避險 {ua} ↔ {ub}"
        conf = confidence(max(cs), n_days)
        la, lb = ", ".join(ma), ", ".join(mb)
        corr_txt = f"{cs[0]:.2f}" if len(cs) == 1 else f"平均 {np.mean(cs):.2f}（最弱 {max(cs):.2f}）"
        rows.append([name, f"{la}  ↔  {lb}", corr_txt,
                     f"D1 報酬率相關係數 ≤ {CORR_HEDGE:.2f}（近 {n_days} 天實測）",
                     "兩邊走勢相反：兩邊同方向持有可互相避險；一邊多一邊空＝加碼同一風險", conf])
        for group, other in ((ma, lb), (mb, la)):
            for x in group:
                if x not in member:
                    member[x] = (name, other, conf)
    solo = sorted(s for s in syms if s not in member)
    if solo:
        rows.append(["獨立商品", ", ".join(solo), "",
                     f"無法和其他商品組成每一對都 ≥ {CORR_GROUP:.2f} 的同向組，也沒有 ≤ {CORR_HEDGE:.2f} 的反向對",
                     "走勢相對獨立，可單獨操作、分散風險", f"（{n_days} 天樣本）"])
        for s0 in solo:
            member[s0] = ("獨立商品", "", f"（{n_days} 天樣本）")
    return rows, member


def build_hedge_table(mt5, symbols):
    rows, member = hedge_groups(d1_returns(mt5, symbols))
    write_csv("hedge_groups.csv",
              ["分組名稱", "包含商品", "實測相關係數 (D1報酬率)", "分組邏輯（已驗證）", "可能用途", "注意事項 / 可信度"],
              rows)
    return member


# ------------------------------------------------------------------
# 總整理：每個商品一列
# ------------------------------------------------------------------
def build_summary_table(best, last_trade, member, near):
    opens = {r["Symbol"].strip(): r for r in read_csv("today_open.csv")}
    ent = {r["Symbol"].strip(): r for r in read_csv("multi_symbol_entry_signals.csv")}
    st = {(r["Symbol"].strip(), r["Period"].strip()): r for r in read_csv("multi_symbol_status.csv")}
    syms = list(opens) + sorted(s for s in ent if s not in opens)
    rows = []
    for sym in syms:
        o, e = opens.get(sym, {}), ent.get(sym, {})
        nl = near.get(sym, ("", "", ""))
        price, op = num(o.get("LatestClose")), num(o.get("TodayOpen"))
        chg = f"{(price - op) / op * 100:.3f}" if price and op else ""
        b = best.get(sym)
        t = last_trade.get(sym)
        g = member.get(sym, ("", "", ""))
        rows.append([sym, o.get("LatestClose", ""), o.get("TodayOpen", ""), chg,
                     e.get("TrendDirection", ""),
                     e.get("D1_Status", ""), e.get("H4_Status", ""), e.get("H1_Status", ""),
                     e.get("M15_Status", ""), e.get("M5_Status", ""), e.get("EntrySignal", ""),
                     nl[0], nl[1], nl[2],
                     b[0] if b else "", f"{b[1]:.1f}" if b else "", f"{b[2]:.3f}" if b else "",
                     t[0] if t else "", t[1] if t else "", t[2] if t else "",
                     f"{t[3]:.3f}" if t else "", fmt_t(t[4]) if t else "",
                     g[0], g[1], g[2],
                     (st.get((sym, "M5")) or {}).get("TrendlineSignal", ""),
                     o.get("DataAsOf", "")])
    write_csv("summary_all.csv",
              ["Symbol", "現價", "今日開盤價", "漲跌%", "長週期趨勢", "D1", "H4", "H1", "M15", "M5",
               "進場信號", "最近關卡", "距離關卡", "關卡訊號", "最佳週期", "最佳週期勝率%",
               "最佳週期平均報酬%", "最近交易週期", "最近交易方向", "最近交易結果", "最近交易報酬%",
               "最近交易時間", "避險分組", "同組商品", "分組可信度", "M5趨勢訊號", "最後更新時間"], rows)


def main():
    try:
        import MetaTrader5 as mt5
        if not mt5.initialize():
            mt5 = None
    except ImportError:
        mt5 = None

    near = {}
    try:
        near = build_session_table(mt5)
    except Exception as e:
        print(f"[額外報表] 時段壓力支撐 失敗：{e}")
    symbols = []
    try:
        symbols = build_entry_table()
    except Exception as e:
        print(f"[額外報表] 進場信號 失敗：{e}")
    best, last_trade, member = {}, {}, {}
    if mt5 is not None:
        try:
            best, last_trade = build_backtest_tables(mt5, symbols)
        except Exception as e:
            print(f"[額外報表] 回測 失敗：{e}")
        try:
            member = build_hedge_table(mt5, symbols)
        except Exception as e:
            print(f"[額外報表] 避險分組 失敗：{e}")
        mt5.shutdown()
    else:
        print("[額外報表] MT5 未開啟，回測摘要/交易明細/避險分組這次不更新")
    try:
        build_summary_table(best, last_trade, member, near)
    except Exception as e:
        print(f"[額外報表] 總整理 失敗：{e}")

if __name__ == "__main__":
    main()
