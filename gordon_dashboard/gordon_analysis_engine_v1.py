"""
Gordon FTMO 監控 - 分析引擎 v1

產生 AnalysisResults.csv，給 Excel「Data」分頁用（12商品 x 5週期 = 60列，32欄）。
這支只負責抓報價、算技術指標、判斷進場訊號/SL/TP，不做部位大小、相關性避險這些
資金管理邏輯 -- 那些照你原本的分頁說明，是「策略規則」分頁的公式負責算，這支只
負責把乾淨的原始分析結果貼進去。

【32欄設計 - 假設，之後可依你原本 Data 分頁實際表頭調整】
Symbol, Timeframe, BarTime, CurrentPrice, Bid, Ask, Spread,
Trend, Signal, SignalStrength, Entry, SL, TP, SL_Pips, TP_Pips, RR_Ratio,
ATR14, MA20, MA50, MA200, RSI14, MACD, MACD_Signal, MACD_Hist,
Volume, VolumeMA20, DayHigh, DayLow, WeekHigh, WeekLow, CorrelationGroup, UpdateTime

【訊號判斷邏輯 - 假設，之後可調整】
- Trend：收盤價站上/跌破 MA50 判多空，MA50 附近(±0.1 ATR內)算盤整
- Signal：Trend=多 且 RSI14 在 45~70 之間 → BUY；Trend=空 且 RSI14 在 30~55 之間 → SELL；
  其餘 → WAIT
- SL：進場價反向 1.5 倍 ATR14；TP：進場價順向 3 倍 ATR14（RR固定抓2:1當基礎，你可以改倍數）
- SignalStrength：用 |RSI14-50| 正規化到 0~100，只是給你排序參考用，不是機率
"""

from __future__ import annotations

import sys

import numpy as np

import gordon_common as gc

COLUMNS = [
    "Symbol", "Timeframe", "BarTime", "CurrentPrice", "Bid", "Ask", "Spread",
    "Trend", "Signal", "SignalStrength", "Entry", "SL", "TP", "SL_Pips", "TP_Pips", "RR_Ratio",
    "ATR14", "MA20", "MA50", "MA200", "RSI14", "MACD", "MACD_Signal", "MACD_Hist",
    "Volume", "VolumeMA20", "DayHigh", "DayLow", "WeekHigh", "WeekLow",
    "CorrelationGroup", "UpdateTime",
]

ATR_SL_MULT = 1.5
ATR_TP_MULT = 3.0


def pip_size(symbol: str) -> float:
    if symbol.endswith("JPY"):
        return 0.01
    if symbol in ("XAUUSD", "US500", "US30"):
        return 0.1
    return 0.0001


def analyze_one(symbol: str, timeframe_name: str) -> dict:
    df = gc.fetch_rates(symbol, timeframe_name)
    close = df["close"]

    df["ma20"] = gc.sma(close, 20)
    df["ma50"] = gc.sma(close, 50)
    df["ma200"] = gc.sma(close, 200)
    df["rsi14"] = gc.rsi(close, 14)
    df["atr14"] = gc.atr(df, 14)
    macd_line, signal_line, hist = gc.macd(close)
    df["macd"] = macd_line
    df["macd_signal"] = signal_line
    df["macd_hist"] = hist
    df["vol_ma20"] = gc.sma(df["volume"], 20)

    last = df.iloc[-1]
    bar_time = last["time"]

    info, tick = gc.get_symbol_info(symbol)
    current_price = float(tick.last) if tick.last else float(close.iloc[-1])
    bid, ask = float(tick.bid), float(tick.ask)
    spread = round(ask - bid, 6)

    ma50 = last["ma50"]
    atr14 = last["atr14"]
    if np.isnan(ma50) or np.isnan(atr14) or atr14 == 0:
        trend, signal_val, entry, sl, tp = "N/A", "WAIT", np.nan, np.nan, np.nan
        rr_ratio = np.nan
        sl_pips = tp_pips = np.nan
        strength = 0.0
    else:
        if current_price > ma50 + 0.1 * atr14:
            trend = "UP"
        elif current_price < ma50 - 0.1 * atr14:
            trend = "DOWN"
        else:
            trend = "RANGE"

        rsi14 = last["rsi14"]
        if trend == "UP" and 45 <= rsi14 <= 70:
            signal_val = "BUY"
        elif trend == "DOWN" and 30 <= rsi14 <= 55:
            signal_val = "SELL"
        else:
            signal_val = "WAIT"

        entry = current_price
        pip = pip_size(symbol)
        if signal_val == "BUY":
            sl = entry - ATR_SL_MULT * atr14
            tp = entry + ATR_TP_MULT * atr14
        elif signal_val == "SELL":
            sl = entry + ATR_SL_MULT * atr14
            tp = entry - ATR_TP_MULT * atr14
        else:
            sl = entry - ATR_SL_MULT * atr14
            tp = entry + ATR_TP_MULT * atr14

        sl_pips = round(abs(entry - sl) / pip, 1)
        tp_pips = round(abs(tp - entry) / pip, 1)
        rr_ratio = round(tp_pips / sl_pips, 2) if sl_pips else np.nan
        strength = round(min(abs(rsi14 - 50) / 50 * 100, 100), 1)

    day_high = df["high"].tail(96).max() if timeframe_name in ("M15", "H1") else df["high"].tail(1).max()
    day_low = df["low"].tail(96).min() if timeframe_name in ("M15", "H1") else df["low"].tail(1).min()
    week_high = df["high"].tail(5).max()
    week_low = df["low"].tail(5).min()

    return {
        "Symbol": symbol,
        "Timeframe": timeframe_name,
        "BarTime": bar_time.strftime("%Y-%m-%d %H:%M:%S"),
        "CurrentPrice": current_price,
        "Bid": bid,
        "Ask": ask,
        "Spread": spread,
        "Trend": trend,
        "Signal": signal_val,
        "SignalStrength": strength,
        "Entry": entry,
        "SL": sl,
        "TP": tp,
        "SL_Pips": sl_pips,
        "TP_Pips": tp_pips,
        "RR_Ratio": rr_ratio,
        "ATR14": round(atr14, 6) if not np.isnan(atr14) else np.nan,
        "MA20": round(last["ma20"], 6) if not np.isnan(last["ma20"]) else np.nan,
        "MA50": round(ma50, 6) if not np.isnan(ma50) else np.nan,
        "MA200": round(last["ma200"], 6) if not np.isnan(last["ma200"]) else np.nan,
        "RSI14": round(last["rsi14"], 2),
        "MACD": round(last["macd"], 6) if not np.isnan(last["macd"]) else np.nan,
        "MACD_Signal": round(last["macd_signal"], 6) if not np.isnan(last["macd_signal"]) else np.nan,
        "MACD_Hist": round(last["macd_hist"], 6) if not np.isnan(last["macd_hist"]) else np.nan,
        "Volume": int(last["volume"]),
        "VolumeMA20": round(last["vol_ma20"], 1) if not np.isnan(last["vol_ma20"]) else np.nan,
        "DayHigh": day_high,
        "DayLow": day_low,
        "WeekHigh": week_high,
        "WeekLow": week_low,
        "CorrelationGroup": gc.CORRELATION_GROUPS.get(symbol, ""),
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

    path = gc.write_csv(rows, COLUMNS, "AnalysisResults.csv")
    print(f"寫入完成：{path}（{len(rows)} 筆，預期 {len(gc.SYMBOLS) * len(gc.TIMEFRAME_NAMES)} 筆）")
    if errors:
        print(f"有 {len(errors)} 筆失敗，已跳過：")
        for e in errors:
            print("  -", e)
    return 0


if __name__ == "__main__":
    sys.exit(main())
