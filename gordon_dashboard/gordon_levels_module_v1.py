"""
Gordon FTMO 監控 - 關卡模組 v1

產生 LevelsResults.csv，給 Excel「關卡」分頁用（12商品 x 5週期 = 60列，28欄，
用法跟 Data 分頁一樣，貼進去不動公式）。

【28欄設計 - 假設，之後可依你原本 關卡 分頁實際表頭調整】
Symbol, Timeframe, BarTime, CurrentPrice,
YesterdayHigh, YesterdayLow, WeeklyResistance, WeeklySupport,
PriorWeekHigh, PriorWeekLow, MonthlyHigh, MonthlyLow,
DistanceToResistancePct, DistanceToSupportPct,
NearestKeyLevel, DistanceToNearestKeyLevelPct, KeyLevel_0.3pct_Alert,
VolumeCurrent, VolumeMA20, VolumeBreakoutConfirmed,
MA20, MA50, MA200, TrendThresholdSignal,
SupportBroken, ResistanceBroken, BreakoutDirection, UpdateTime

【判斷邏輯 - 假設，之後可調整】
- 昨日高低：用 D1 資料倒數第2根K棒(倒數第1根是今天還沒收)
- 週阻力/支撐：用 W1 資料最近1根(當週)的高/低；前週高低用 W1 倒數第2根
- 0.3%關卡提醒：目前價跟(昨日高/昨日低/週阻力/週支撐)裡最近的一個，
  距離百分比 <= 0.3% 就標記 TRUE
- 成交量突破確認：最新K棒成交量 > 20期均量 * 1.5 就算確認
- 趨勢關值判斷：收盤價站上 MA50 一定幅度(>0.15 ATR，這裡用 MA20/MA50/MA200 排列粗略判斷)
  MA20>MA50>MA200 → UP；MA20<MA50<MA200 → DOWN；其餘 → NEUTRAL
- 支撐/阻力跌破判斷：最新收盤價跌破昨日低 → SupportBroken=TRUE；
  站上昨日高 → ResistanceBroken=TRUE
"""

from __future__ import annotations

import sys

import numpy as np

import gordon_common as gc

COLUMNS = [
    "Symbol", "Timeframe", "BarTime", "CurrentPrice",
    "YesterdayHigh", "YesterdayLow", "WeeklyResistance", "WeeklySupport",
    "PriorWeekHigh", "PriorWeekLow", "MonthlyHigh", "MonthlyLow",
    "DistanceToResistancePct", "DistanceToSupportPct",
    "NearestKeyLevel", "DistanceToNearestKeyLevelPct", "KeyLevel_0.3pct_Alert",
    "VolumeCurrent", "VolumeMA20", "VolumeBreakoutConfirmed",
    "MA20", "MA50", "MA200", "TrendThresholdSignal",
    "SupportBroken", "ResistanceBroken", "BreakoutDirection", "UpdateTime",
]

KEY_LEVEL_ALERT_PCT = 0.003
VOLUME_BREAKOUT_MULT = 1.5


def analyze_one(symbol: str, timeframe_name: str) -> dict:
    df = gc.fetch_rates(symbol, timeframe_name)
    daily = gc.fetch_rates(symbol, "D1", count=60)
    weekly = gc.fetch_rates(symbol, "W1", count=20)
    monthly_lookback = daily.tail(22)

    close = df["close"]
    df["ma20"] = gc.sma(close, 20)
    df["ma50"] = gc.sma(close, 50)
    df["ma200"] = gc.sma(close, 200)
    df["vol_ma20"] = gc.sma(df["volume"], 20)

    last = df.iloc[-1]
    bar_time = last["time"]

    _, tick = gc.get_symbol_info(symbol)
    current_price = float(tick.last) if tick.last else float(close.iloc[-1])

    yesterday = daily.iloc[-2] if len(daily) >= 2 else daily.iloc[-1]
    yesterday_high, yesterday_low = float(yesterday["high"]), float(yesterday["low"])

    this_week = weekly.iloc[-1]
    weekly_resistance, weekly_support = float(this_week["high"]), float(this_week["low"])

    prior_week = weekly.iloc[-2] if len(weekly) >= 2 else weekly.iloc[-1]
    prior_week_high, prior_week_low = float(prior_week["high"]), float(prior_week["low"])

    monthly_high = float(monthly_lookback["high"].max())
    monthly_low = float(monthly_lookback["low"].min())

    dist_to_resistance_pct = round((weekly_resistance - current_price) / current_price * 100, 3)
    dist_to_support_pct = round((current_price - weekly_support) / current_price * 100, 3)

    key_levels = {
        "YesterdayHigh": yesterday_high,
        "YesterdayLow": yesterday_low,
        "WeeklyResistance": weekly_resistance,
        "WeeklySupport": weekly_support,
    }
    nearest_name, nearest_level = min(
        key_levels.items(), key=lambda kv: abs(kv[1] - current_price)
    )
    dist_to_nearest_pct = abs(nearest_level - current_price) / current_price * 100
    key_level_alert = dist_to_nearest_pct <= KEY_LEVEL_ALERT_PCT * 100

    volume_current = int(last["volume"])
    volume_ma20 = last["vol_ma20"]
    volume_breakout = (
        not np.isnan(volume_ma20)
        and volume_ma20 > 0
        and volume_current > volume_ma20 * VOLUME_BREAKOUT_MULT
    )

    ma20, ma50, ma200 = last["ma20"], last["ma50"], last["ma200"]
    if np.isnan(ma20) or np.isnan(ma50) or np.isnan(ma200):
        trend_signal = "N/A"
    elif ma20 > ma50 > ma200:
        trend_signal = "UP"
    elif ma20 < ma50 < ma200:
        trend_signal = "DOWN"
    else:
        trend_signal = "NEUTRAL"

    support_broken = current_price < yesterday_low
    resistance_broken = current_price > yesterday_high
    if resistance_broken:
        breakout_direction = "UP"
    elif support_broken:
        breakout_direction = "DOWN"
    else:
        breakout_direction = "NONE"

    return {
        "Symbol": symbol,
        "Timeframe": timeframe_name,
        "BarTime": bar_time.strftime("%Y-%m-%d %H:%M:%S"),
        "CurrentPrice": current_price,
        "YesterdayHigh": yesterday_high,
        "YesterdayLow": yesterday_low,
        "WeeklyResistance": weekly_resistance,
        "WeeklySupport": weekly_support,
        "PriorWeekHigh": prior_week_high,
        "PriorWeekLow": prior_week_low,
        "MonthlyHigh": monthly_high,
        "MonthlyLow": monthly_low,
        "DistanceToResistancePct": dist_to_resistance_pct,
        "DistanceToSupportPct": dist_to_support_pct,
        "NearestKeyLevel": nearest_name,
        "DistanceToNearestKeyLevelPct": round(dist_to_nearest_pct, 3),
        "KeyLevel_0.3pct_Alert": key_level_alert,
        "VolumeCurrent": volume_current,
        "VolumeMA20": round(volume_ma20, 1) if not np.isnan(volume_ma20) else np.nan,
        "VolumeBreakoutConfirmed": volume_breakout,
        "MA20": round(ma20, 6) if not np.isnan(ma20) else np.nan,
        "MA50": round(ma50, 6) if not np.isnan(ma50) else np.nan,
        "MA200": round(ma200, 6) if not np.isnan(ma200) else np.nan,
        "TrendThresholdSignal": trend_signal,
        "SupportBroken": support_broken,
        "ResistanceBroken": resistance_broken,
        "BreakoutDirection": breakout_direction,
        "UpdateTime": gc.now_str(),
    }


def main() -> int:
    gc.connect_mt5()
    rows = []
    errors = []
    try:
        for symbol in gc.SYMBOLS:
            for timeframe_name in gc.TIMEFRAME_NAMES:
                try:
                    rows.append(analyze_one(symbol, timeframe_name))
                except Exception as exc:
                    errors.append(f"{symbol} {timeframe_name}: {exc}")
    finally:
        gc.shutdown_mt5()

    if not rows:
        print("沒有任何一筆資料分析成功，不寫檔。")
        for e in errors:
            print("  -", e)
        return 1

    path = gc.write_csv(rows, COLUMNS, "LevelsResults.csv")
    print(f"寫入完成：{path}（{len(rows)} 筆，預期 {len(gc.SYMBOLS) * len(gc.TIMEFRAME_NAMES)} 筆）")
    if errors:
        print(f"有 {len(errors)} 筆失敗，已跳過：")
        for e in errors:
            print("  -", e)
    return 0


if __name__ == "__main__":
    sys.exit(main())
