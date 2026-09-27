"""
進場規則 S1–S14（事件式：條件「剛成立」的那根 K 線收盤後產生訊號，下一根開盤進場）。
每條規則有若干變體；除 S8 外都搭配 ATR 倍數 SL/TP 格：SL ∈ {1.0,1.5,2.0}、TP ∈ {1.5,2.0,3.0}。
S8 以「條件消失」出場，不設 SL/TP。其餘規則最多持有 100 根，到期以收盤價出場。

完整文字定義見 RULE_DOCS（會寫進 Excel 的「規則定義」分頁）。
"""
import numpy as np

from indicators import shift

SL_GRID = [1.0, 1.5, 2.0]
TP_GRID = [1.5, 2.0, 3.0]

RULE_DOCS = [
    ("S1", "11指標多數決", "11 個指標中 ≥k 個同向（k=7/8/9），條件剛成立時順勢進場。"),
    ("S2", "MA交叉", "短均線上穿/下穿長均線（均線參數用該商品該週期最佳化結果）。"),
    ("S3", "RSI超買超賣反轉", "RSI 由下往上穿越下限做多、由上往下穿越上限做空（參數用最佳化結果）。"),
    ("S4", "KD區間交叉", "K 上穿 D 且 K<30 做多；K 下穿 D 且 K>70 做空。"),
    ("S5", "MACD交叉", "MACD 主線上穿/下穿訊號線。"),
    ("S6", "布林回歸", "收盤由下軌外回到軌內做多；由上軌外回到軌內做空。"),
    ("S7", "Keltner突破", "收盤突破 Keltner 上軌做多；跌破下軌做空。"),
    ("S8", "趨勢組同向持有", "趨勢組 6 個指標中 ≥k 個同向（k=5/6）時進場，條件消失的下一根開盤出場，不設 SL/TP。"),
    ("S9", "趨勢方向+震盪拉回進場", "收盤在 EMA200 之上且 EMA200 上升（下降反之）為趨勢方向；震盪組 5 個指標只剩 ≤k 個（k=1/2）同向（即拉回）時順勢進場。"),
    ("S10", "跨週期共振", "本週期 11 指標多空狀態翻轉，且上一層週期（M5→M15→H1→H4→D1）狀態同向時進場。D1 無此規則。"),
    ("S11", "趨勢(ADX高)順勢進場", "ADX(14) ≥ a（a=20/25）且趨勢組 ≥m/6（m=5/6）同向，條件剛成立時順勢進場。"),
    ("S12", "抵銷後淨票數", "趨勢組淨票數（多-空）與震盪組淨票數都 ≥g（g=2/3）且同向時進場。"),
    ("S13", "TAI動能", "TAI（TAI_Color_Panel_Optimized，EMA 週期 14/28、TAI 週期 5）由非多頭轉為多頭動能（藍）做多；轉為空頭動能（紅）做空。"),
    ("S14", "趨勢線突破", "擺動點（左右 5 根）連成的壓力線被突破且 TAI(MA28) 為多頭動能時做多；支撐線跌破且 TAI 為空頭動能時做空。"),
]


def onset(cond):
    c = np.asarray(cond, dtype=bool)
    p = np.zeros_like(c)
    p[1:] = c[:-1]
    return c & ~p


def _events(long_cond, short_cond):
    lo, so = np.flatnonzero(onset(long_cond)), np.flatnonzero(onset(short_cond))
    idx = np.concatenate([lo, so])
    d = np.concatenate([np.ones(len(lo), int), -np.ones(len(so), int)])
    order = np.argsort(idx, kind="stable")
    return idx[order], d[order]


def _hold_exit(cond_long, cond_short, idx, dirs):
    """S8：條件消失的那根（收盤後）出場 → 回傳每筆的出場訊號 K 線索引。"""
    n = len(cond_long)
    out = []
    for i, d in zip(idx, dirs):
        cond = cond_long if d > 0 else cond_short
        rest = np.flatnonzero(~cond[i + 1:])
        out.append(i + 1 + rest[0] if len(rest) else n - 1)
    return np.array(out, dtype=int)


def build(ctx):
    """回傳 list of dict(rule, title, desc, idx, dirs, exit_idx|None, sltp=bool)。"""
    R = []
    lv, sv = ctx["long_votes"], ctx["short_votes"]
    tl, ts, ol, os_ = ctx["trend_long"], ctx["trend_short"], ctx["osc_long"], ctx["osc_short"]
    c = ctx["c"]

    def add(rule, desc, lc, sc, sltp=True, exit_idx=None):
        idx, d = _events(lc, sc)
        title = dict((r[0], r[1]) for r in RULE_DOCS)[rule]
        R.append(dict(rule=rule, title=title, desc=desc, idx=idx, dirs=d,
                      exit_idx=exit_idx(idx, d) if exit_idx else None, sltp=sltp))

    for k in (7, 8, 9):
        add("S1", f"≥{k}/11同向", lv >= k, sv >= k)
    t = ctx["trade"]
    for rule, ind, desc in (("S2", "MA", "MA "), ("S5", "MACD", "MACD ")):
        tr = t[ind]
        add(rule, desc + ctx["pstr"][ind], tr > 0, tr < 0)
    tr = t["RSI"]
    add("S3", "RSI " + ctx["pstr"]["RSI"], tr > 0, tr < 0)
    K, D = ctx["K"], ctx["D"]
    add("S4", "KD " + ctx["pstr"]["KD"], (K > D) & (shift(K, 1) <= shift(D, 1)) & (K < 30),
        (K < D) & (shift(K, 1) >= shift(D, 1)) & (K > 70))
    bm, bu, bl = ctx["boll"]
    add("S6", "布林 " + ctx["pstr"]["BOLL"], (c > bl) & (shift(c, 1) <= shift(bl, 1)),
        (c < bu) & (shift(c, 1) >= shift(bu, 1)))
    km, ku, kl = ctx["kelt"]
    add("S7", "Keltner " + ctx["pstr"]["KELTNER"], c > ku, c < kl)
    for k in (5, 6):
        lc, sc = tl >= k, ts >= k
        add("S8", f"{k}/6同向", lc, sc, sltp=False,
            exit_idx=lambda i, d, lc=lc, sc=sc: _hold_exit(lc, sc, i, d))
    e200 = ctx["ema200"]
    up = (c > e200) & (e200 > shift(e200, 5))
    dn = (c < e200) & (e200 < shift(e200, 5))
    for k in (1, 2):
        add("S9", f"EMA200方向+震盪{k}/5反向", up & (ol <= k), dn & (os_ <= k))
    if ctx.get("htf_state") is not None:
        hs = ctx["htf_state"]
        add("S10", f"{ctx['tf']}翻轉+{ctx['htf']}同向", (lv > sv) & (hs > 0), (sv > lv) & (hs < 0))
    ax = ctx["adx"]
    for a in (20, 25):
        for m in (5, 6):
            add("S11", f"ADX≥{a}+趨勢{m}/6", (ax >= a) & (tl >= m), (ax >= a) & (ts >= m))
    tn, on = tl - ts, ol - os_
    for g in (2, 3):
        add("S12", f"分組淨差≥{g}", (tn >= g) & (on >= g), (tn <= -g) & (on <= -g))
    for m, col in ctx["tai"].items():
        add("S13", f"TAI(MA{m},週期5) 啟動進場", col == 1, col == 2)
    tln = ctx["trendline"]
    col28 = ctx["tai"][28]
    add("S14", "擺動5+TAI同向", (tln == "向上突破") & (col28 == 1), (tln == "向下突破") & (col28 == 2))
    return R
