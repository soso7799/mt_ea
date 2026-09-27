"""
從 MT5 終端抓多週期 K 線（D1/H4/H1/M15/M5），快取成 csv.gz。
時間為 MT5 伺服器時間（naive）。
"""
import datetime as dt
import json
import os

import pandas as pd

TFS = ["D1", "H4", "H1", "M15", "M5"]
TF_MIN = {"D1": 1440, "H4": 240, "H1": 60, "M15": 15, "M5": 5}
# 每個週期抓幾根（約：D1 10 年、H4 4 年、H1 2 年、M15 10 個月、M5 4 個月）
DEFAULT_BARS = {"D1": 2500, "H4": 6000, "H1": 12000, "M15": 20000, "M5": 30000}


def _paths(cache, sym, tf):
    return os.path.join(cache, f"{sym}_{tf}.csv.gz"), os.path.join(cache, f"{sym}_meta.json")


def load(cache, sym, tf):
    p, m = _paths(cache, sym, tf)
    if not os.path.exists(p):
        return None, None
    df = pd.read_csv(p, parse_dates=["time"])
    meta = json.load(open(m, encoding="utf-8")) if os.path.exists(m) else {}
    return df, meta


def save(cache, sym, tf, df, meta):
    os.makedirs(cache, exist_ok=True)
    p, m = _paths(cache, sym, tf)
    df.to_csv(p, index=False, compression="gzip")
    json.dump(meta, open(m, "w", encoding="utf-8"), indent=2)


def fetch_all(symbols, cache, terminal=None, bars=None, offline=False, max_age_min=30):
    """回傳 {(sym, tf): DataFrame}，meta {sym: {...}}，以及 {sym: 抓取時間}。"""
    bars = bars or DEFAULT_BARS
    out, metas, missing = {}, {}, []
    now = dt.datetime.now()
    for s in symbols:
        for tf in TFS:
            df, meta = load(cache, s, tf)
            fresh = df is not None and meta.get("fetched") and \
                (now - dt.datetime.fromisoformat(meta["fetched"])).total_seconds() < max_age_min * 60
            if df is not None and (offline or fresh):
                out[(s, tf)] = df
                metas[s] = meta
            else:
                missing.append(s)
    missing = sorted(set(missing))
    if not missing:
        return out, metas
    if offline:
        raise SystemExit(f"[錯誤] 離線模式但沒有快取：{', '.join(missing)}")

    try:
        import MetaTrader5 as mt5
    except ImportError:
        raise SystemExit("[錯誤] 需要 MetaTrader5 套件：python -m pip install MetaTrader5")
    if not (mt5.initialize(path=terminal) if terminal else mt5.initialize()):
        raise SystemExit(f"[錯誤] 無法連線 MT5：{mt5.last_error()}。請先開啟並登入 MT5。")
    tfc = {"D1": mt5.TIMEFRAME_D1, "H4": mt5.TIMEFRAME_H4, "H1": mt5.TIMEFRAME_H1,
           "M15": mt5.TIMEFRAME_M15, "M5": mt5.TIMEFRAME_M5}
    try:
        for s in missing:
            if not mt5.symbol_select(s, True):
                print(f"⚠️ MT5 找不到商品 {s}，略過")
                continue
            info = mt5.symbol_info(s)
            tick = mt5.symbol_info_tick(s)
            meta = {"digits": info.digits, "point": info.point, "fetched": now.isoformat(timespec="seconds"),
                    "bid": tick.bid if tick else None,
                    "tick_time": dt.datetime.utcfromtimestamp(tick.time).isoformat() if tick else None}
            for tf in TFS:
                r = mt5.copy_rates_from_pos(s, tfc[tf], 0, bars[tf])
                if r is None or len(r) == 0:
                    print(f"⚠️ {s} {tf} 沒有資料")
                    continue
                df = pd.DataFrame(r)
                df["time"] = pd.to_datetime(df["time"], unit="s")
                df = df[["time", "open", "high", "low", "close", "tick_volume", "spread"]]
                save(cache, s, tf, df, meta)
                out[(s, tf)] = df
            metas[s] = meta
            print(f"  {s}: " + ", ".join(f"{tf} {len(out.get((s, tf), []))}" for tf in TFS))
    finally:
        mt5.shutdown()
    return out, metas
