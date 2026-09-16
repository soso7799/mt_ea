# -*- coding: utf-8 -*-
"""
gordon_levels_module_v1.py

給 Gordon_FTMO_監控儀表板.xlsm 的「關卡」分頁用(用法跟 Data 分頁一樣，貼進去
不動公式)。

支撐/壓力的計算方式跟 gordon_full_analysis.py 裡 compute_final_signal() 用的
是同一套公式(近期20根K棒高低、觸碰次數判斷有效性、容忍值算法)，這裡把它獨立
抽出來輸出成單獨一欄一欄的數值，而不是像 compute_final_signal 那樣只回傳合成
後的最終訊號。這不是新邏輯，是把 gordon_full_analysis.py 內部已經在用、已驗證
正確的公式攤開來顯示。

【跟「說明」分頁描述的已知差異】
跟 gordon_analysis_engine_v1.py 一樣：12商品 x D1/H4/H1/M15 共4週期 = 48列，
不是原本說的60列(12x5週期)，因為真實系統只支援4個週期。

輸出：D:\\historical_data\\LevelsResults.csv
"""

import os
import sys
import numpy as np
import pandas as pd
import MetaTrader5 as mt5

import gordon_full_analysis as gfa
from gordon_analysis_engine_v1 import fetch_mt5_df, MT5_TIMEFRAME_MAP

OUTPUT_FOLDER = r"D:\historical_data"
OUTPUT_PATH = os.path.join(OUTPUT_FOLDER, "LevelsResults.csv")

COLUMNS = [
    "Symbol", "Timeframe", "BarTime", "CurrentPrice",
    "YesterdayHigh", "YesterdayLow", "RecentSupport", "RecentResistance",
    "SupportTouchCount", "ResistanceTouchCount", "SupportValid", "ResistanceValid",
    "DistanceToSupportPct", "DistanceToResistancePct",
    "NearestKeyLevel", "DistanceToNearestKeyLevelPct", "KeyLevel_0.3pct_Alert",
    "VolumeCurrent", "VolumeMA20", "VolumeBreakoutConfirmed",
    "MA20", "MA50", "MA200", "TrendStatus",
    "SupportBroken", "ResistanceBroken", "BreakoutDirection", "UpdateTime",
]

KEY_LEVEL_ALERT_PCT = 0.003
RECENT_BARS = 20
TOUCH_LOOKBACK = 20


def support_resistance(df):
    """跟 gordon_full_analysis.compute_final_signal() 裡完全相同的公式，只是把
    中間值(支撐/壓力/觸碰次數/有效性)攤開回傳，而不是只回傳合成後的最終訊號。"""
    close, high, low = df["close"], df["high"], df["low"]
    last_price = close.iloc[-1]

    recent_sup = low.iloc[-RECENT_BARS - 1:-1].min()
    recent_res = high.iloc[-RECENT_BARS - 1:-1].max()

    tol = (recent_res - recent_sup) * 0.02 if recent_res > recent_sup else last_price * 0.0005
    lows_recent = low.iloc[-TOUCH_LOOKBACK - 1:-1]
    highs_recent = high.iloc[-TOUCH_LOOKBACK - 1:-1]
    support_touch = int((abs(lows_recent - recent_sup) <= tol).sum())
    resistance_touch = int((abs(highs_recent - recent_res) <= tol).sum())
    support_valid = support_touch >= 2
    resistance_valid = resistance_touch >= 2

    return recent_sup, recent_res, support_touch, resistance_touch, support_valid, resistance_valid


def analyze_one(symbol, tf_name):
    df = fetch_mt5_df(symbol, tf_name)
    close = df["close"]

    daily = fetch_mt5_df(symbol, "D1", count=10)
    yesterday = daily.iloc[-2] if len(daily) >= 2 else daily.iloc[-1]
    yesterday_high, yesterday_low = float(yesterday["high"]), float(yesterday["low"])

    tick = mt5.symbol_info_tick(symbol)
    current_price = float(tick.last) if tick and tick.last else float(close.iloc[-1])

    recent_sup, recent_res, sup_touch, res_touch, sup_valid, res_valid = support_resistance(df)

    dist_to_support_pct = round((current_price - recent_sup) / current_price * 100, 3)
    dist_to_resistance_pct = round((recent_res - current_price) / current_price * 100, 3)

    key_levels = {
        "YesterdayHigh": yesterday_high, "YesterdayLow": yesterday_low,
        "RecentSupport": recent_sup, "RecentResistance": recent_res,
    }
    nearest_name, nearest_level = min(key_levels.items(), key=lambda kv: abs(kv[1] - current_price))
    dist_to_nearest_pct = abs(nearest_level - current_price) / current_price * 100
    key_level_alert = dist_to_nearest_pct <= KEY_LEVEL_ALERT_PCT * 100

    volume_current = int(df["volume"].iloc[-1]) if "volume" in df.columns else 0
    volume_ma20 = df["volume"].tail(20).mean() if "volume" in df.columns else np.nan
    volume_breakout = (
        not np.isnan(volume_ma20) and volume_ma20 > 0 and volume_current > volume_ma20 * 1.2
    )  # 跟 gordon_full_analysis.compute_final_signal 的放量門檻(1.2倍)一致

    ma20 = close.rolling(20).mean().iloc[-1]
    ma50 = close.rolling(50).mean().iloc[-1]
    ma200 = close.rolling(200).mean().iloc[-1]
    _, _, _, trend_status = gfa.compute_votes_latest(df)
    trend_status = trend_status if trend_status else "資料不足"

    support_broken = current_price < yesterday_low
    resistance_broken = current_price > yesterday_high
    if resistance_broken:
        breakout_direction = "UP"
    elif support_broken:
        breakout_direction = "DOWN"
    else:
        breakout_direction = "NONE"

    return {
        "Symbol": symbol, "Timeframe": tf_name,
        "BarTime": df["time"].iloc[-1].strftime("%Y-%m-%d %H:%M:%S"),
        "CurrentPrice": current_price,
        "YesterdayHigh": yesterday_high, "YesterdayLow": yesterday_low,
        "RecentSupport": recent_sup, "RecentResistance": recent_res,
        "SupportTouchCount": sup_touch, "ResistanceTouchCount": res_touch,
        "SupportValid": sup_valid, "ResistanceValid": res_valid,
        "DistanceToSupportPct": dist_to_support_pct, "DistanceToResistancePct": dist_to_resistance_pct,
        "NearestKeyLevel": nearest_name, "DistanceToNearestKeyLevelPct": round(dist_to_nearest_pct, 3),
        "KeyLevel_0.3pct_Alert": key_level_alert,
        "VolumeCurrent": volume_current,
        "VolumeMA20": round(volume_ma20, 1) if not np.isnan(volume_ma20) else "",
        "VolumeBreakoutConfirmed": volume_breakout,
        "MA20": ma20, "MA50": ma50, "MA200": ma200, "TrendStatus": trend_status,
        "SupportBroken": support_broken, "ResistanceBroken": resistance_broken,
        "BreakoutDirection": breakout_direction,
        "UpdateTime": pd.Timestamp.now().strftime("%Y-%m-%d %H:%M:%S"),
    }


def main():
    if not mt5.initialize():
        print(f"MT5 初始化失敗：{mt5.last_error()}", file=sys.stderr)
        return 1

    rows, errors = [], []
    try:
        for symbol in gfa.SYMBOLS:
            for tf_name in gfa.TIMEFRAMES:
                try:
                    rows.append(analyze_one(symbol, tf_name))
                except Exception as e:
                    errors.append(f"{symbol} {tf_name}: {e}")
    finally:
        mt5.shutdown()

    if not rows:
        print("沒有任何一筆資料分析成功，不寫檔。")
        for e in errors:
            print(" -", e)
        return 1

    os.makedirs(OUTPUT_FOLDER, exist_ok=True)
    pd.DataFrame(rows, columns=COLUMNS).to_csv(OUTPUT_PATH, index=False, encoding="utf-8-sig")
    print(f"寫入完成：{OUTPUT_PATH}（{len(rows)} 筆，{len(gfa.SYMBOLS)}商品x{len(gfa.TIMEFRAMES)}週期）")
    if errors:
        print(f"{len(errors)} 筆失敗：")
        for e in errors:
            print(" -", e)
    return 0


if __name__ == "__main__":
    sys.exit(main())
