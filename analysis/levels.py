"""
關卡 / 時段壓力支撐：今日開盤、亞歐美三個時段高低點、前日高低、近支撐/近壓力、量比、訊號。
時段以 UTC 劃分：亞盤 00–07、歐盤 07–13、美盤 13–21。伺服器時間 = 紐約時間 + 7 小時（FTMO）。
"""
import numpy as np
import pandas as pd

SESS = [("亞盤", 0, 7), ("歐盤", 7, 13), ("美盤", 13, 21)]


def server_to_utc(t, ny_offset=7):
    ny = pd.DatetimeIndex(t) - pd.Timedelta(hours=ny_offset)
    ny = ny.tz_localize("America/New_York", ambiguous=np.ones(len(ny), dtype=bool), nonexistent="shift_forward")
    return ny.tz_convert("UTC").tz_localize(None)


def levels(sym, m5, d1, meta, server_now):
    if m5 is None or d1 is None or not len(m5):
        return None
    day = m5["time"].iloc[-1].normalize()
    today = m5[m5["time"] >= day]
    if not len(today):
        return None
    price = meta.get("bid") or float(m5["close"].iloc[-1])
    utc = server_to_utc(today["time"])
    row = dict(symbol=sym, price=price, open=float(today["open"].iloc[0]))
    row["chg"] = (price / row["open"] - 1) * 100
    lv = {"今日開盤": row["open"]}
    for name, a, b in SESS:
        sel = today[(utc.hour >= a) & (utc.hour < b)]
        row[name + "高"] = float(sel["high"].max()) if len(sel) else None
        row[name + "低"] = float(sel["low"].min()) if len(sel) else None
        if len(sel):
            lv[name + "高"], lv[name + "低"] = row[name + "高"], row[name + "低"]
    prev = d1[d1["time"] < day]
    if len(prev):
        row["前日高點"], row["前日低點"] = float(prev["high"].iloc[-1]), float(prev["low"].iloc[-1])
        row["prev_date"] = prev["time"].iloc[-1]
        lv["前日高"], lv["前日低"] = row["前日高點"], row["前日低點"]
    else:
        row["前日高點"] = row["前日低點"] = row["prev_date"] = None
    row["今高"], row["今低"] = float(today["high"].max()), float(today["low"].min())
    below = {k: v for k, v in lv.items() if v is not None and v < price}
    above = {k: v for k, v in lv.items() if v is not None and v > price}
    row["support"] = max(below.values()) if below else None
    row["resist"] = min(above.values()) if above else None
    near = min(lv.items(), key=lambda kv: abs(kv[1] - price))
    row["nearest"] = f"{near[0]} {near[1]:.{int(meta.get('digits', 5))}f}"
    row["nearest_pct"] = (price / near[1] - 1) * 100
    if row["前日高點"] and price > row["前日高點"]:
        sig = "突破前日高"
    elif row["前日低點"] and price < row["前日低點"]:
        sig = "跌破前日低"
    elif abs(row["nearest_pct"]) <= 0.05:
        sig = "接近" + near[0]
    else:
        sig = "區間內"
    row["signal"] = sig
    dg = int(meta.get("digits", 5))
    for k, v in list(row.items()):
        if k in ("price", "open", "support", "resist", "前日高點", "前日低點", "今高", "今低") or k.endswith("高") or k.endswith("低"):
            if isinstance(v, float):
                row[k] = round(v, dg)
    vol = m5["tick_volume"].to_numpy(float)
    row["vol"], row["vol_avg"] = vol[-1], vol[-21:-1].mean() if len(vol) > 21 else np.nan
    row["vol_ratio"] = row["vol"] / row["vol_avg"] if row["vol_avg"] else np.nan
    last_bar_end = m5["time"].iloc[-1] + pd.Timedelta(minutes=5)
    age = (server_now - last_bar_end).total_seconds() / 60 if server_now is not None else np.nan
    row["fresh"] = (f"新鮮（{max(age, 0):.0f} 分鐘前）" if age <= 15 else
                    f"已過期 {age / 60:.1f} 小時（休市或資料未更新，突破/反轉判斷不可信）")
    return row
