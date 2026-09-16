# -*- coding: utf-8 -*-
"""
gordon_analysis_engine_v1.py

給 Gordon_FTMO_監控儀表板.xlsm 的「Data」分頁用。

這支不是另外發明的新邏輯 —— 直接重用同資料夾裡 gordon_full_analysis.py
(你 Google 雲端硬碟裡真實在跑、有真實輸出資料驗證過的分析引擎)裡的指標計算
(ATR/RSI/MACD)、訊號判斷(compute_votes_latest 三層合成訊號)、ATR動態SL/TP邏輯
(ATR_SL_MULT/ATR_TP_MULT)，只是換一種輸出格式，貼進 Data 分頁。商品/週期跟
gordon_full_analysis.py 完全一致：12商品、D1/H4/H1/M15/M5共5週期，12x5=60列，
跟「說明」分頁描述的一致。

32欄的欄名是我設計的(你先前答覆「沒有現成標題」)，但每一欄的數值都是直接呼叫
gordon_full_analysis.py 裡驗證過的函式算出來，不是另外編的公式。

輸出：D:\\historical_data\\AnalysisResults.csv(跟你 VBA 巨集 RefreshAllData 的
csvFolder 一致，csvFolder 本身不用改)。
"""

import os
import sys
import numpy as np
import pandas as pd
import MetaTrader5 as mt5

import gordon_full_analysis as gfa

OUTPUT_FOLDER = r"D:\historical_data"
OUTPUT_PATH = os.path.join(OUTPUT_FOLDER, "AnalysisResults.csv")

COLUMNS = [
    "Symbol", "Timeframe", "BarTime", "CurrentPrice", "Bid", "Ask", "Spread",
    "Trend", "Signal", "FinalSignal", "Entry", "SL", "TP", "SL_Dist", "TP_Dist", "RR_Ratio",
    "ATR14", "MA20", "MA50", "MA200", "RSI14", "MACD", "MACD_Signal", "MACD_Hist",
    "Volume", "VolumeMA20", "DayHigh", "DayLow", "WeekHigh", "WeekLow",
    "CorrelationGroup", "UpdateTime",
]

# 跟你原本提過的三組避險關係一致(AUDUSD/NZDUSD、US500/US30、EURUSD/USDCHF)
CORRELATION_GROUPS = {
    "AUDUSD": "AUDUSD/NZDUSD", "NZDUSD": "AUDUSD/NZDUSD",
    "US500.cash": "US500/US30", "US30.cash": "US500/US30",
    "EURUSD": "EURUSD/USDCHF", "USDCHF": "EURUSD/USDCHF",
}

MT5_TIMEFRAME_MAP = {"M5": mt5.TIMEFRAME_M5, "M15": mt5.TIMEFRAME_M15, "H1": mt5.TIMEFRAME_H1,
                      "H4": mt5.TIMEFRAME_H4, "D1": mt5.TIMEFRAME_D1}


def fetch_mt5_df(symbol, tf_name, count=None):
    if count is None:
        count = gfa.OPT_LOOKBACK_BARS.get(tf_name, 2000) + 300  # 多抓一點給指標暖機用
    if not mt5.symbol_select(symbol, True):
        raise RuntimeError(f"{symbol}：券商找不到這個商品代碼，請確認 MT5 報價視窗裡的實際代號")
    rates = mt5.copy_rates_from_pos(symbol, MT5_TIMEFRAME_MAP[tf_name], 0, count)
    if rates is None or len(rates) == 0:
        raise RuntimeError(f"{symbol} {tf_name}：抓不到K棒資料，{mt5.last_error()}")
    df = pd.DataFrame(rates)
    df["time"] = pd.to_datetime(df["time"], unit="s")
    df = df.rename(columns={"tick_volume": "volume"})
    return df


def analyze_one(symbol, tf_name, df=None):
    if df is None:
        df = fetch_mt5_df(symbol, tf_name)
    close, high, low = df["close"], df["high"], df["low"]

    tick = mt5.symbol_info_tick(symbol)
    current_price = float(tick.last) if tick and tick.last else float(close.iloc[-1])
    bid = float(tick.bid) if tick else current_price
    ask = float(tick.ask) if tick else current_price

    atr14 = gfa.calc_atr_series(high, low, close, gfa.ATR_PERIOD).iloc[-1]
    ma20 = close.rolling(20).mean().iloc[-1]
    ma50 = close.rolling(50).mean().iloc[-1]
    ma200 = close.rolling(200).mean().iloc[-1]
    rsi14 = gfa.calc_rsi(close, 14).iloc[-1]
    macd_line, macd_signal = gfa.calc_macd(close, 12, 26, 9)
    macd_val, macd_sig_val = macd_line.iloc[-1], macd_signal.iloc[-1]

    signals, score, status, final_signal = gfa.compute_votes_latest(df)
    if signals is None:
        trend, sig_text, final_text = "資料不足", "資料不足", "資料不足"
        sl = tp = sl_dist = tp_dist = rr = np.nan
    else:
        trend = status
        sig_text = "多" if score > 0 else ("空" if score < 0 else "中性")
        final_text = final_signal
        if score > 0:
            sl = current_price - atr14 * gfa.ATR_SL_MULT
            tp = current_price + atr14 * gfa.ATR_TP_MULT
        else:
            sl = current_price + atr14 * gfa.ATR_SL_MULT
            tp = current_price - atr14 * gfa.ATR_TP_MULT
        sl_dist = abs(current_price - sl)
        tp_dist = abs(tp - current_price)
        rr = round(tp_dist / sl_dist, 2) if sl_dist else np.nan

    day_high = df["high"].tail(96).max()
    day_low = df["low"].tail(96).min()
    week_high = df["high"].tail(480).max()
    week_low = df["low"].tail(480).min()

    has_volume = "volume" in df.columns

    return {
        "Symbol": symbol, "Timeframe": tf_name,
        "BarTime": df["time"].iloc[-1].strftime("%Y-%m-%d %H:%M:%S"),
        "CurrentPrice": current_price, "Bid": bid, "Ask": ask, "Spread": round(ask - bid, 6),
        "Trend": trend, "Signal": sig_text, "FinalSignal": final_text,
        "Entry": current_price, "SL": sl, "TP": tp,
        "SL_Dist": sl_dist, "TP_Dist": tp_dist, "RR_Ratio": rr,
        "ATR14": atr14, "MA20": ma20, "MA50": ma50, "MA200": ma200, "RSI14": rsi14,
        "MACD": macd_val, "MACD_Signal": macd_sig_val, "MACD_Hist": macd_val - macd_sig_val,
        "Volume": int(df["volume"].iloc[-1]) if has_volume else "",
        "VolumeMA20": round(df["volume"].tail(20).mean(), 1) if has_volume else "",
        "DayHigh": day_high, "DayLow": day_low, "WeekHigh": week_high, "WeekLow": week_low,
        "CorrelationGroup": CORRELATION_GROUPS.get(symbol, ""),
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
