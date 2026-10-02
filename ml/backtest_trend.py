#!/usr/bin/env python3
"""
TrendScanner v2 規則回測（用 HistoryExporter 從 FTMO 匯出的 H1 / H4 資料）

資料：HistoryExporter 輸出的資料夾（含 H1\\、H4\\、SUMMARY.csv）
  預設 %APPDATA%\\MetaQuotes\\Terminal\\Common\\Files\\FTMO_Data

用法
  python backtest_trend.py                              全部商品
  python backtest_trend.py --symbols EURUSD,XAUUSD      指定商品
  python backtest_trend.py --data "H:\\我的雲端硬碟\\FTMO_Data" --years 3
  選項：--trail atr|swing|be|none   移動止損（預設 atr）
        --units 3                   同商品最多幾單（加碼，預設 3）
        --params 路徑               TrendScanner 的 params.csv（各商品參數，預設找 Common\\Files\\TrendScanner\\params.csv）
        --split 2026-01-01          這天之前 = 樣本內、之後 = 樣本外，分開報告

規則（與 TrendScanner.mq5 v2 相同）
  評分 8 票：均線排列、價在 MA4 上下、MA4 斜率、MACD、RSI、DMI、布林中軌、量能
  H1 |分數| >= min_score、ADX >= adx_min、H4 同向分數 >= 4
  斐波（120 根 H1 波段）：方向一致、回檔 <= 61.8%；38.2~61.8% 下一根開盤進場，< 38.2% 掛 38.2% 限價（4 根內成交）
  止損止盈：斐波位 + 0.2 ATR 緩衝，止損 0.5~3 ATR，止盈為第一個 RR >= 1.5 的斐波位
  移動止損：獲利 1R 後保本，ATR 模式再以 2×ATR 追蹤；加碼：最新一單 >= 1R 且訊號仍成立，先把舊單移到保本
  反向訊號全部平倉

近似：以 H1 K 棒高低點判斷觸價，同一根同時碰到止損與止盈算止損；買單成本含點差（檔案 SPREAD 欄）。
結果以 R（每單風險）計；以每筆 0.15% 風險換算帳戶報酬。未限制同時持倉商品數。
"""
import argparse
import csv
import datetime as dt
import math
import os
import sys
from collections import defaultdict

GROUP_NAMES = {"major": "主要貨幣", "cross": "交叉貨幣", "exotic": "異國貨幣", "metal": "金屬",
               "energy": "能源", "index": "指數", "agri": "農產品", "crypto": "加密貨幣", "other": "其他"}

DEFAULT_PARAMS = dict(ma1=5, ma2=10, ma3=20, ma4=34, macd_fast=12, macd_slow=26, macd_signal=9,
                      rsi_period=14, rsi_bull=55, rsi_bear=45, adx_period=14, adx_min=20,
                      bb_period=20, vol_bars=20, min_score=6)
CONFIRM_MIN = 4
SWING_BARS = 120
STOP_BUF, MIN_SL, MAX_SL, MIN_RR = 0.2, 0.5, 3.0, 1.5
FIBS = (0.0, 0.236, 0.382, 0.5, 0.618, 0.786, 1.0)
LIMIT_BARS = 4
BE_AT_R, TRAIL_ATR, SWING_TRAIL = 1.0, 2.0, 10
ADD_AT_R = 1.0
RISK_PCT = 0.15


#--------------------------------------------------------------------- 分組（與 SymbolGroups.mqh 相同規則）
def symbol_group(sym):
    up = sym.upper()
    keys = [("metal", "XAU XAG XPT XPD GOLD SILVER PLATINUM PALLADIUM COPPER XCU"),
            ("index", "US30 US100 NAS100 USTEC US500 SPX SP500 US2000 RUSSELL GER40 DE40 DAX UK100 FTSE FRA40 CAC JP225 "
                      "JPN225 NIKKEI AUS200 HK50 HSI EU50 STOXX SPN35 IBEX N25 AEX CHN50 CN50 DXY USDX VIX SWI20 ITA40 NETH25"),
            ("crypto", "BTC ETH LTC XRP BCH SOL DOGE ADA DOT XLM LINK AVAX BNB UNI XMR DASH NEO ETC ALGO MATIC "
                       "AAV ALG AVA BAR GAL GRT ICP IMX LNK MAN NER SAN VEC XTZ"),
            ("energy", "OIL BRENT WTI NATGAS NGAS GASOIL HEATING"),
            ("agri", "CORN WHEAT SOY COFFEE COCOA SUGAR COTTON OJ ORANGE CATTLE HOGS RICE OAT")]
    for g, ks in keys:
        if any(k in up for k in ks.split()):
            return g
    major = set("USD EUR JPY GBP CHF AUD CAD NZD".split())
    ccy = major | set("CNH CNY MXN TRY ZAR SGD HKD NOK SEK DKK PLN HUF CZK ILS RUB THB INR KRW TWD BRL CLP COP IDR PHP MYR".split())
    for i in range(len(up) - 5):
        b, q = up[i:i + 3], up[i + 3:i + 6]
        if b in ccy and q in ccy:
            if b in major and q in major:
                return "major" if "USD" in (b, q) else "cross"
            return "exotic"
    return "other"


#--------------------------------------------------------------------- 讀資料
def load_bars(path):
    """回傳 dict：t(datetime) o h l c v spread，與小數位數"""
    t, o, h, l, c, v, sp = [], [], [], [], [], [], []
    digits = 0
    with open(path, newline="", encoding="ascii", errors="ignore") as f:
        for row in csv.reader(f):
            if not row or row[0].startswith("<"):
                continue
            t.append(dt.datetime.strptime(row[0] + " " + row[1], "%Y.%m.%d %H:%M"))
            o.append(float(row[2])); h.append(float(row[3])); l.append(float(row[4])); c.append(float(row[5]))
            v.append(float(row[6]) if len(row) > 6 else 0.0)
            sp.append(float(row[7]) if len(row) > 7 else 0.0)
            if "." in row[5]:
                digits = max(digits, len(row[5].split(".")[1]))
    return dict(t=t, o=o, h=h, l=l, c=c, v=v, sp=sp), digits


def load_params(path):
    out = {}
    if not path or not os.path.exists(path):
        return out
    with open(path, newline="", encoding="utf-8", errors="ignore") as f:
        for r in csv.DictReader(f):
            try:
                out[r["symbol"]] = {k: float(r[k]) for k in DEFAULT_PARAMS if r.get(k) not in (None, "")}
            except (KeyError, ValueError):
                pass
    return out


#--------------------------------------------------------------------- 指標（對齊 MT5 內建算法）
def sma(x, p):
    out = [math.nan] * len(x)
    s = 0.0
    for i, v in enumerate(x):
        s += v
        if i >= p:
            s -= x[i - p]
        if i >= p - 1:
            out[i] = s / p
    return out


def ema(x, p):
    out = [math.nan] * len(x)
    a = 2.0 / (p + 1)
    prev = None
    for i, v in enumerate(x):
        if math.isnan(v):
            continue
        prev = v if prev is None else prev + a * (v - prev)
        out[i] = prev
    return out


def macd(c, f, s, sig):
    ef, es = ema(c, f), ema(c, s)
    main = [a - b for a, b in zip(ef, es)]
    # MT5 iMACD 訊號線是主線的 SMA
    valid = [m if not math.isnan(m) else 0.0 for m in main]
    signal = sma(valid, sig)
    return main, signal


def rsi(c, p):
    out = [math.nan] * len(c)
    if len(c) <= p:
        return out
    gain = loss = 0.0
    for i in range(1, p + 1):
        d = c[i] - c[i - 1]
        gain += max(d, 0); loss += max(-d, 0)
    gain /= p; loss /= p
    out[p] = 100.0 if loss == 0 else 100 - 100 / (1 + gain / loss)
    for i in range(p + 1, len(c)):
        d = c[i] - c[i - 1]
        gain = (gain * (p - 1) + max(d, 0)) / p
        loss = (loss * (p - 1) + max(-d, 0)) / p
        out[i] = 100.0 if loss == 0 else 100 - 100 / (1 + gain / loss)
    return out


def adx(h, l, c, p):
    """MT5 iADX（非 Wilder）：每根 +DI/-DI 原始值做 EMA，ADX = DX 的 EMA"""
    n = len(c)
    pdi_raw, ndi_raw = [0.0] * n, [0.0] * n
    for i in range(1, n):
        up, dn = h[i] - h[i - 1], l[i - 1] - l[i]
        pdm = up if (up > dn and up > 0) else 0.0
        ndm = dn if (dn > up and dn > 0) else 0.0
        tr = max(h[i] - l[i], abs(h[i] - c[i - 1]), abs(l[i] - c[i - 1]))
        if tr > 0:
            pdi_raw[i], ndi_raw[i] = 100 * pdm / tr, 100 * ndm / tr
    pdi, ndi = ema(pdi_raw, p), ema(ndi_raw, p)
    dx = [100 * abs(a - b) / (a + b) if (a + b) > 0 else 0.0 for a, b in zip(pdi, ndi)]
    return ema(dx, p), pdi, ndi


def atr(h, l, c, p=14):
    tr = [h[0] - l[0]] + [max(h[i] - l[i], abs(h[i] - c[i - 1]), abs(l[i] - c[i - 1])) for i in range(1, len(c))]
    return sma(tr, p)


def score_series(b, P):
    """每根K棒收盤後的 8 票分數與 ADX（無效 = None）"""
    c, h, l, o, v = b["c"], b["h"], b["l"], b["o"], b["v"]
    m1, m2, m3, m4 = (sma(c, int(P[k])) for k in ("ma1", "ma2", "ma3", "ma4"))
    mac, sig = macd(c, int(P["macd_fast"]), int(P["macd_slow"]), int(P["macd_signal"]))
    rs = rsi(c, int(P["rsi_period"]))
    ad, pdi, ndi = adx(h, l, c, int(P["adx_period"]))
    mid = sma(c, int(P["bb_period"]))
    at = atr(h, l, c, 14)
    vb = int(P["vol_bars"])
    warm = max(int(P["ma4"]) + 6, int(P["macd_slow"]) + int(P["macd_signal"]), int(P["adx_period"]) * 3, vb, 30)
    sc, ax = [None] * len(c), [0.0] * len(c)
    for i in range(warm, len(c)):
        if at[i] <= 0 or math.isnan(at[i]):
            continue
        votes = [
            1 if m1[i] > m2[i] > m3[i] > m4[i] else (-1 if m1[i] < m2[i] < m3[i] < m4[i] else 0),
            1 if c[i] > m4[i] else -1,
        ]
        slope = (m4[i] - m4[i - 5]) / at[i]
        votes.append(1 if slope > 0.1 else (-1 if slope < -0.1 else 0))
        votes.append(1 if mac[i] > sig[i] else -1)
        votes.append(1 if rs[i] >= P["rsi_bull"] else (-1 if rs[i] <= P["rsi_bear"] else 0))
        votes.append(1 if pdi[i] > ndi[i] else -1)
        votes.append(1 if c[i] > mid[i] else -1)
        up = sum(v[j] for j in range(i - vb + 1, i + 1) if c[j] > o[j])
        dn = sum(v[j] for j in range(i - vb + 1, i + 1) if c[j] < o[j])
        votes.append(1 if up > dn else (-1 if up < dn else 0))
        sc[i], ax[i] = sum(votes), ad[i]
    return sc, ax, at


#--------------------------------------------------------------------- 斐波（與 MarketRegime.mqh 相同）
def fib_state(b, i):
    lo_i = hi_i = i
    for j in range(i - SWING_BARS + 1, i + 1):
        if b["h"][j] > b["h"][hi_i]:
            hi_i = j
        if b["l"][j] < b["l"][lo_i]:
            lo_i = j
    hi, lo = b["h"][hi_i], b["l"][lo_i]
    rng = hi - lo
    if rng <= 0:
        return None
    d = 1 if hi_i > lo_i else -1                       # 高點較新 → 上升波段
    fib = [hi - r * rng if d > 0 else lo + r * rng for r in FIBS]
    ratio = (hi - b["c"][i]) / rng if d > 0 else (b["c"][i] - lo) / rng
    return dict(dir=d, hi=hi, lo=lo, fib=fib, ratio=ratio)


def calc_stops(f, d, price, a):
    rng = f["hi"] - f["lo"]
    lv = sorted(f["fib"] + [f["lo"] - 0.272 * rng, f["lo"] - 0.618 * rng, f["hi"] + 0.272 * rng, f["hi"] + 0.618 * rng])
    gap = 0.1 * a
    if d > 0:
        below = [x for x in lv if x < price - gap]
        sl = below[-1] - STOP_BUF * a if below else price - MAX_SL * a
        dist = min(max(price - sl, MIN_SL * a), MAX_SL * a)
        sl = price - dist
        tp = next((x for x in lv if x - price >= MIN_RR * dist), None)
    else:
        above = [x for x in lv if x > price + gap]
        sl = above[0] + STOP_BUF * a if above else price + MAX_SL * a
        dist = min(max(sl - price, MIN_SL * a), MAX_SL * a)
        sl = price + dist
        tp = next((x for x in reversed(lv) if price - x >= MIN_RR * dist), None)
    if tp is None:
        return None
    return sl, tp, abs(tp - price) / dist


#--------------------------------------------------------------------- 回測一個商品
def backtest_symbol(sym, h1, h4, P, point, trail, max_units, start):
    sc, ax, at = score_series(h1, P)
    sc4, _, _ = score_series(h4, P)
    t4 = h4["t"]
    trades = []
    units = []            # 持倉：dict(dir, entry, sl, tp, risk, t)
    pending = None        # 限價單：dict(dir, price, sl, tp, expire_i)
    j4 = -1
    n = len(h1["t"])

    def close_unit(u, price, i, why):
        r = (price - u["entry"]) / u["risk"] * u["dir"]
        trades.append(dict(symbol=sym, dir=u["dir"], open=u["t"], close=h1["t"][i], entry=u["entry"],
                           exit=price, r=r, why=why, unit=u["unit"]))

    for i in range(SWING_BARS, n - 1):
        t_close = h1["t"][i] + dt.timedelta(hours=1)            # 第 i 根收盤 = 第 i+1 根開盤
        #--- 1) 第 i 根K棒內：限價成交、止損/止盈觸發
        hi, lo = h1["h"][i], h1["l"][i]
        spread = h1["sp"][i] * point
        if pending:
            if i > pending["expire_i"]:
                pending = None
            elif (pending["dir"] > 0 and lo + spread <= pending["price"]) or (pending["dir"] < 0 and hi >= pending["price"]):
                p = pending
                units.append(dict(dir=p["dir"], entry=p["price"], sl=p["sl"], tp=p["tp"],
                                  risk=abs(p["price"] - p["sl"]), t=h1["t"][i], unit=1))
                pending = None
        for u in list(units):
            bid_lo, bid_hi = lo, hi
            ask_lo, ask_hi = lo + spread, hi + spread
            if u["dir"] > 0:
                if bid_lo <= u["sl"]:
                    close_unit(u, u["sl"], i, "SL" if u["sl"] < u["entry"] else "TRAIL"); units.remove(u)
                elif bid_hi >= u["tp"]:
                    close_unit(u, u["tp"], i, "TP"); units.remove(u)
            else:
                if ask_hi >= u["sl"]:
                    close_unit(u, u["sl"], i, "SL" if u["sl"] > u["entry"] else "TRAIL"); units.remove(u)
                elif ask_lo <= u["tp"]:
                    close_unit(u, u["tp"], i, "TP"); units.remove(u)

        #--- 2) 第 i 根收盤：移動止損
        c = h1["c"][i]
        a = at[i]
        for u in units:
            profit_r = (c - u["entry"]) / u["risk"] * u["dir"]
            if trail == "none" or profit_r < BE_AT_R:
                continue
            target = u["entry"]
            if trail == "atr":
                tr_ = c - TRAIL_ATR * a if u["dir"] > 0 else c + spread + TRAIL_ATR * a
                target = max(target, tr_) if u["dir"] > 0 else min(target, tr_)
            elif trail == "swing":
                if u["dir"] > 0:
                    target = max(target, min(h1["l"][i - SWING_TRAIL + 1:i + 1]))
                else:
                    target = min(target, max(h1["h"][i - SWING_TRAIL + 1:i + 1]) + spread)
            if (u["dir"] > 0 and target > u["sl"]) or (u["dir"] < 0 and target < u["sl"]):
                u["sl"] = target

        #--- 3) 訊號
        if h1["t"][i] < start or sc[i] is None:
            continue
        while j4 + 1 < len(t4) and t4[j4 + 1] + dt.timedelta(hours=4) <= t_close:
            j4 += 1
        if j4 < 0 or sc4[j4] is None:
            continue
        s = sc[i]
        if abs(s) < P["min_score"] or ax[i] < P["adx_min"]:
            continue
        d = 1 if s > 0 else -1
        if sc4[j4] * d < CONFIRM_MIN:
            continue
        f = fib_state(h1, i)
        if not f or f["dir"] != d or f["ratio"] > 0.618:
            continue

        o_next = h1["o"][i + 1]
        sp_next = h1["sp"][i + 1] * point
        mkt = o_next + sp_next if d > 0 else o_next

        # 反向持倉 → 全部平倉
        if units and units[0]["dir"] != d:
            for u in units:
                close_unit(u, o_next if u["dir"] > 0 else o_next + sp_next, i + 1, "REVERSE")
            units = []
            pending = None

        if not units:
            if pending:
                continue
            if f["ratio"] >= 0.382:
                st = calc_stops(f, d, mkt, a)
                if st:
                    units.append(dict(dir=d, entry=mkt, sl=st[0], tp=st[1], risk=abs(mkt - st[0]),
                                      t=h1["t"][i + 1], unit=1))
            else:
                lim = f["fib"][2]
                st = calc_stops(f, d, lim, a)
                if st:
                    pending = dict(dir=d, price=lim, sl=st[0], tp=st[1], expire_i=i + LIMIT_BARS)
            continue

        # 加碼
        if len(units) >= max_units:
            continue
        last = units[-1]
        if (c - last["entry"]) / last["risk"] * d < ADD_AT_R:
            continue
        for u in units:
            if (d > 0 and u["sl"] < u["entry"]) or (d < 0 and u["sl"] > u["entry"]):
                u["sl"] = u["entry"]
        st = calc_stops(f, d, mkt, a)
        if st and (units[0]["tp"] - mkt) * d > 0:
            units.append(dict(dir=d, entry=mkt, sl=st[0], tp=units[0]["tp"], risk=abs(mkt - st[0]),
                              t=h1["t"][i + 1], unit=len(units) + 1))

    for u in units:
        close_unit(u, h1["c"][n - 1], n - 1, "END")
    return trades


#--------------------------------------------------------------------- 報告
def stats(rs):
    n = len(rs)
    if n == 0:
        return dict(n=0, win=0, avg=0, total=0, pf=0, dd=0)
    wins = [r for r in rs if r > 0]
    loss = [r for r in rs if r <= 0]
    eq = peak = dd = 0.0
    for r in rs:
        eq += r
        peak = max(peak, eq)
        dd = max(dd, peak - eq)
    pf = sum(wins) / -sum(loss) if loss and sum(loss) < 0 else float("inf")
    return dict(n=n, win=len(wins) / n * 100, avg=sum(rs) / n, total=sum(rs), pf=pf, dd=dd)


def line(name, s):
    pf = "∞" if s["pf"] == float("inf") else f"{s['pf']:.2f}"
    return (f"{name:<14} {s['n']:>5} {s['win']:>6.1f}% {s['avg']:>+7.2f} {s['total']:>+8.1f} {pf:>6} {s['dd']:>7.1f}"
            f" {s['total'] * RISK_PCT:>+8.2f}%")


HEAD = f"{'':<14} {'筆數':>5} {'勝率':>7} {'平均R':>7} {'總R':>8} {'PF':>6} {'最大回撤R':>7} {'帳戶報酬':>9}"


def main():
    try:
        sys.stdout.reconfigure(encoding="utf-8")   # 導到檔案時用 UTF-8，避免亂碼
    except AttributeError:
        pass
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    appdata = os.environ.get("APPDATA", "")
    ap.add_argument("--data", default=os.path.join(appdata, "MetaQuotes", "Terminal", "Common", "Files", "FTMO_Data"))
    ap.add_argument("--params", default=os.path.join(appdata, "MetaQuotes", "Terminal", "Common", "Files", "TrendScanner", "params.csv"))
    ap.add_argument("--symbols", default="")
    ap.add_argument("--years", type=float, default=3)
    ap.add_argument("--trail", default="atr", choices=["none", "be", "atr", "swing"])
    ap.add_argument("--units", type=int, default=3)
    ap.add_argument("--split", default="", help="樣本內/外分界日 YYYY-MM-DD")
    ap.add_argument("--out", default="backtest_trend_trades.csv")
    a = ap.parse_args()

    h1dir, h4dir = os.path.join(a.data, "H1"), os.path.join(a.data, "H4")
    if not os.path.isdir(h1dir) or not os.path.isdir(h4dir):
        sys.exit(f"找不到 {h1dir} 或 {h4dir}（先用 HistoryExporter 匯出 H1、H4）")
    syms = [s.strip() for s in a.symbols.split(",") if s.strip()] or \
        sorted(f[:-4] for f in os.listdir(h1dir) if f.endswith(".csv") and os.path.exists(os.path.join(h4dir, f)))
    per_sym_params = load_params(a.params)
    if per_sym_params:
        print(f"使用 params.csv：{len(per_sym_params)} 個商品的個別參數")

    all_trades = []
    for k, sym in enumerate(syms, 1):
        try:
            h1, digits = load_bars(os.path.join(h1dir, sym + ".csv"))
            h4, _ = load_bars(os.path.join(h4dir, sym + ".csv"))
        except (OSError, ValueError) as e:
            print(f"  {sym}: 讀檔失敗 {e}")
            continue
        if len(h1["t"]) < 500 or len(h4["t"]) < 100:
            print(f"  {sym}: 資料太少，略過")
            continue
        P = dict(DEFAULT_PARAMS)
        P.update(per_sym_params.get(sym, {}))
        start = h1["t"][-1] - dt.timedelta(days=365 * a.years)
        tr = backtest_symbol(sym, h1, h4, P, 10 ** -digits, a.trail, a.units, start)
        all_trades += tr
        s = stats([t["r"] for t in tr])
        print(f"[{k}/{len(syms)}] {sym:<12} {s['n']:>4} 筆  總 {s['total']:+.1f}R")

    if not all_trades:
        sys.exit("沒有任何交易")
    all_trades.sort(key=lambda t: t["close"])

    with open(a.out, "w", newline="", encoding="utf-8-sig") as f:
        w = csv.writer(f)
        w.writerow(["symbol", "group", "dir", "unit", "open", "close", "entry", "exit", "r", "why"])
        for t in all_trades:
            w.writerow([t["symbol"], symbol_group(t["symbol"]), "BUY" if t["dir"] > 0 else "SELL", t["unit"],
                        t["open"], t["close"], t["entry"], t["exit"], f"{t['r']:.3f}", t["why"]])

    print("\n" + "=" * 86)
    print(f"TrendScanner v2 回測  近 {a.years:g} 年  移動止損={a.trail}  加碼最多 {a.units} 單  每筆風險 {RISK_PCT}%")
    print("=" * 86)
    print(HEAD)
    print(line("全部", stats([t["r"] for t in all_trades])))

    print("\n— 依分組 —")
    by = defaultdict(list)
    for t in all_trades:
        by[symbol_group(t["symbol"])].append(t["r"])
    for g in GROUP_NAMES:
        if g in by:
            print(line(GROUP_NAMES[g], stats(by[g])))

    print("\n— 依年度 —")
    by = defaultdict(list)
    for t in all_trades:
        by[t["close"].year].append(t["r"])
    for y in sorted(by):
        print(line(str(y), stats(by[y])))

    if a.split:
        cut = dt.datetime.strptime(a.split, "%Y-%m-%d")
        print(f"\n— 樣本內 / 樣本外（分界 {a.split}）—")
        print(line("樣本內", stats([t["r"] for t in all_trades if t["open"] < cut])))
        print(line("樣本外", stats([t["r"] for t in all_trades if t["open"] >= cut])))

    print("\n— 依出場原因 —")
    by = defaultdict(list)
    for t in all_trades:
        by[t["why"]].append(t["r"])
    for k in sorted(by):
        print(line(k, stats(by[k])))

    print("\n— 依商品（總 R 由高到低）—")
    by = defaultdict(list)
    for t in all_trades:
        by[t["symbol"]].append(t["r"])
    for sym, rs in sorted(by.items(), key=lambda kv: -sum(kv[1])):
        print(line(sym, stats(rs)))

    print(f"\n逐筆交易：{os.path.abspath(a.out)}")
    print("注意：H1 近似模擬，未含滑價與隔夜費；未限制同時持倉數；結果用來比較規則與參數，不代表實盤績效。")


if __name__ == "__main__":
    main()
