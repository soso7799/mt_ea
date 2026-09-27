"""
從 MT5 終端下載 M1 歷史 K 線並快取成 csv.gz（放在歷史資料碟 export\\bars）。

需要：pip install MetaTrader5（僅 Windows），且 MT5 終端已登入。
MT5「工具 → 選項 → 圖表 → 圖表中最大K線數」請設為「無限制」，否則只拿得到最近的資料。
"""
import datetime as dt
import json
import os

import pandas as pd

COLS = ["time", "open", "high", "low", "close", "spread"]


def cache_paths(cache_dir, sym):
    return (os.path.join(cache_dir, f"{sym}_M1.csv.gz"),
            os.path.join(cache_dir, f"{sym}_meta.json"))


def load_cached(cache_dir, sym):
    data, meta = cache_paths(cache_dir, sym)
    if not (os.path.exists(data) and os.path.exists(meta)):
        return None, None
    df = pd.read_csv(data)
    df["time"] = pd.to_datetime(df["time"])
    with open(meta, encoding="utf-8") as f:
        return df, json.load(f)


def save_cached(cache_dir, sym, df, meta):
    os.makedirs(cache_dir, exist_ok=True)
    data, mpath = cache_paths(cache_dir, sym)
    df.to_csv(data, index=False, compression="gzip")
    with open(mpath, "w", encoding="utf-8") as f:
        json.dump(meta, f, indent=2)


def fetch_m1(symbols, start, end, cache_dir, terminal=None, refresh=False):
    """回傳 {symbol: (DataFrame, meta)}。時間為 MT5 伺服器時間（naive）。"""
    out = {}
    need = []
    for sym in symbols:
        df, meta = (None, None) if refresh else load_cached(cache_dir, sym)
        if df is not None and df["time"].min() <= start + dt.timedelta(days=3) \
                and df["time"].max() >= end - dt.timedelta(days=3):
            out[sym] = (df, meta)
        else:
            need.append(sym)
    if not need:
        return out

    try:
        import MetaTrader5 as mt5
    except ImportError:
        raise SystemExit("[錯誤] 需要 MetaTrader5 套件：python -m pip install MetaTrader5")

    ok = mt5.initialize(path=terminal) if terminal else mt5.initialize()
    if not ok:
        raise SystemExit(f"[錯誤] 無法連線 MT5 終端：{mt5.last_error()}。請先開啟並登入 MT5。")
    try:
        for sym in need:
            if not mt5.symbol_select(sym, True):
                raise SystemExit(f"[錯誤] MT5 找不到商品 {sym}（名稱可能有後綴，請用 --symbols 指定）")
            info = mt5.symbol_info(sym)
            meta = {"digits": info.digits, "point": info.point,
                    "contract": info.trade_contract_size}
            parts = []
            a = start
            while a < end:                                   # 分月下載，避免單次太大
                b = min(a + dt.timedelta(days=31), end)
                r = mt5.copy_rates_range(sym, mt5.TIMEFRAME_M1,
                                         a.replace(tzinfo=dt.timezone.utc),
                                         b.replace(tzinfo=dt.timezone.utc))
                if r is not None and len(r):
                    parts.append(pd.DataFrame(r))
                a = b
            if not parts:
                raise SystemExit(f"[錯誤] {sym} 沒有下載到任何 M1 資料")
            df = pd.concat(parts, ignore_index=True)
            df["time"] = pd.to_datetime(df["time"], unit="s")
            df = df.drop_duplicates("time").sort_values("time")[COLS].reset_index(drop=True)
            if df["time"].min() > start + dt.timedelta(days=3):
                print(f"⚠️ {sym} 最早只到 {df['time'].min()}，"
                      "請把 MT5「圖表中最大K線數」設為無限制後加 --refresh 重抓")
            save_cached(cache_dir, sym, df, meta)
            print(f"  {sym}: {len(df):,} 根 M1（{df['time'].min()} ~ {df['time'].max()}）")
            out[sym] = (df, meta)
    finally:
        mt5.shutdown()
    return out
