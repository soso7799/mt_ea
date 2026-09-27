"""
回測引擎（全部扣點差；訊號在 K 線收盤後產生，下一根開盤進場）。
  flip_trades  ：持倉方向陣列 → 翻轉交易（單一指標參數優化、多空狀態回測）
  event_trades ：事件進場 + ATR 倍數 SL/TP（或指定出場）→ 交易（規則驗證）
  metrics      ：勝率、交易數、Alpha、盈虧比、期望值、獲利因子、t 值
"""
import numpy as np

IS_FRAC = 0.70   # 前 70% 選參數 / 規則，後 30% 驗證


def flip_trades(pos, o, cost_pct):
    """pos[i]：第 i 根收盤後希望的持倉（+1/-1/0）。在第 i+1 根開盤執行。
    回傳 list of (entry_idx, exit_idx, dir, ret_pct)。最後一筆未平倉的以最後開盤價結算。"""
    n = len(pos)
    tgt = np.empty(n)
    tgt[0] = 0
    tgt[1:] = pos[:-1]                     # 第 i 根開盤時的實際持倉
    chg = np.flatnonzero(np.diff(tgt, prepend=0) != 0)
    trades = []
    for a, b in zip(chg, list(chg[1:]) + [n - 1]):
        d = int(tgt[a])
        if d == 0 or b <= a:
            continue
        r = (o[b] - o[a]) / o[a] * d * 100 - cost_pct
        trades.append((a, b, d, r))
    return trades


def event_trades(entries, dirs, o, h, l, c, atr_arr, sl_m, tp_m, cost_pct,
                 max_hold=100, exit_idx=None):
    """entries：訊號 K 線索引（收盤後訊號），第 idx+1 根開盤進場。
    sl_m/tp_m：ATR 倍數（None 表示不用，此時需 exit_idx）。
    同一根同時碰到 SL 與 TP 視為 SL。
    回傳 list of (entry_idx, exit_idx, dir, ret_pct, sl, tp, how)，how ∈ SL/TP/TIME/EXIT/OPEN（OPEN=到資料最後仍持有）。"""
    n = len(o)
    out = []
    for k, (i, d) in enumerate(zip(entries, dirs)):
        e = i + 1
        if e >= n or np.isnan(atr_arr[i]) or atr_arr[i] <= 0:
            continue
        px = o[e]
        sl = px - d * sl_m * atr_arr[i] if sl_m else None
        tp = px + d * tp_m * atr_arr[i] if tp_m else None
        last = min(n - 1, e + max_hold) if exit_idx is None else min(n - 1, exit_idx[k] + 1)
        hh, ll = h[e:last + 1], l[e:last + 1]
        hit = None
        if sl is not None:
            if d > 0:
                s_hit, t_hit = ll <= sl, hh >= tp
            else:
                s_hit, t_hit = hh >= sl, ll <= tp
            any_hit = s_hit | t_hit
            if any_hit.any():
                j = int(np.argmax(any_hit))
                hit = (e + j, sl if s_hit[j] else tp)
        if hit is None:
            ex_i, ex_px = last, (o[last] if exit_idx is not None else c[last])
            planned_end = (e + max_hold) if exit_idx is None else exit_idx[k] + 1
            how = "OPEN" if planned_end > n - 1 else ("EXIT" if exit_idx is not None else "TIME")
        else:
            ex_i, ex_px = hit
            how = "SL" if ex_px == sl else "TP"
        r = (ex_px - px) / px * d * 100 - cost_pct
        out.append((e, ex_i, d, r, sl, tp, how))
    return out


def metrics(rets):
    r = np.asarray(rets, dtype=float)
    n = len(r)
    if n == 0:
        return dict(n=0, win=np.nan, payoff=np.nan, exp=np.nan, pf=np.nan, t=np.nan, alpha=np.nan)
    w, lo = r[r > 0], r[r <= 0]
    sd = r.std(ddof=1) if n > 1 else np.nan
    return dict(
        n=n, win=len(w) / n * 100,
        payoff=(w.mean() / -lo.mean()) if len(w) and len(lo) and lo.mean() < 0 else np.nan,
        exp=r.mean(),
        pf=(w.sum() / -lo.sum()) if len(lo) and lo.sum() < 0 else (np.inf if len(w) else np.nan),
        t=(r.mean() / sd * np.sqrt(n)) if n > 1 and sd > 0 else np.nan,
        alpha=(r.mean() / sd) if n > 1 and sd > 0 else np.nan)


def split(trades, n_bars):
    cut = int(n_bars * IS_FRAC)
    is_ = [t for t in trades if t[0] < cut]
    oos = [t for t in trades if t[0] >= cut]
    return is_, oos
