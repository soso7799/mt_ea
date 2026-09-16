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

【過期資料保護】mt5.copy_rates_from_pos() 有個已知坑：商品剛被 symbol_select()
加進報價視窗時，終端機可能還沒同步到最新報價，這支API不會因為資料舊就報錯，
會安靜地把本地快取裡的舊K棒當成功結果回傳。這裡加了兩層保護：抓資料前先等到
有夠新的即時tick出現(wait_for_live_tick)；抓完資料後檢查最新一根K棒的時間，
如果比現在舊超過(週期秒數x3)，會在終端機印出[警告]並在最後統計總共幾筆過期，
不會悄悄放行舊資料。

輸出：D:\\historical_data\\AnalysisResults.csv(跟你 VBA 巨集 RefreshAllData 的
csvFolder 一致，csvFolder 本身不用改)。
"""

import os
import sys
import time
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

# 每個週期一根K棒的秒數，用來判斷抓到的資料是不是過期的
TF_SECONDS = {"M5": 300, "M15": 900, "H1": 3600, "H4": 14400, "D1": 86400}
STALE_MULT = 3  # 最新一根K棒的時間，如果比「現在 - N倍週期」還舊，判定為過期
TICK_WAIT_TIMEOUT_SEC = 2.0
RETRY_ATTEMPTS = 4  # 抓到過期資料時最多重抓幾次，給終端機時間在背景補齊本地歷史快取
RETRY_WAIT_SEC = 1.5
STALE_LOG = []  # main()/RunDashboardUpdate 結束時用來統計、印出總共幾筆抓到過期資料


def wait_for_live_tick(symbol, timeout=TICK_WAIT_TIMEOUT_SEC):
    """symbol_select 剛把商品加進報價視窗時，終端機可能還沒收到第一筆即時報價，
    這裡等到 tick 出現才繼續，避免緊接著的 copy_rates_from_pos 抓到終端機本地
    快取裡的舊資料。回傳抓到的 tick(可能是 None)，讓呼叫端拿它的 time 當「現在」
    的時間基準 —— 不能用 Python 本地的 time.time()/datetime.now() 去判斷這顆
    tick 夠不夠新，因為 tick.time 是券商伺服器時間，跟使用者電腦本地時區不是
    同一個時鐘，直接相減會被時差誤導成「一直等不到新tick」。"""
    deadline = time.time() + timeout
    tick = None
    while time.time() < deadline:
        tick = mt5.symbol_info_tick(symbol)
        if tick and tick.time:
            return tick
        time.sleep(0.2)
    return tick


def fetch_mt5_df(symbol, tf_name, count=None):
    """
    抓K棒資料。MT5 的 copy_rates_from_pos 只會回傳終端機本地已經快取住的歷史，
    不會強迫跟券商即時同步——如果這個商品/週期很少在 MT5 裡被實際打開過圖表，
    本地快取可能停在很久以前，API 不會報錯，會把這份不完整的舊資料當「成功」
    回傳。這裡抓到過期資料時不會就這樣放行，而是重抓幾次、每次之間等一下，
    給終端機時間在背景把缺的歷史補齊；重試完還是舊的，才會真的判定過期並警告。

    【判斷「過期」用的時間基準，必須是 MT5 自己的時間，不能是本地電腦時間】
    K棒的 time 欄位是券商伺服器時間；如果拿它去跟 Python 的
    pd.Timestamp.now()(使用者電腦本地時區)相減，只要電腦時區跟券商伺服器
    時區不一樣，就會產生一個固定幾小時的假落差，把明明新鮮的資料誤判成過期
    (這是實際踩過的坑：不同商品、不同週期全部一起卡在同一個5小時左右的區間，
    正是時區誤差的特徵，不是真的資料舊了)。所以這裡固定拿 MT5 自己回傳的
    即時報價時間(tick.time)當「現在」，跟K棒時間是同一個時鐘，不會有這個問題。
    """
    if count is None:
        count = gfa.OPT_LOOKBACK_BARS.get(tf_name, 2000) + 300  # 多抓一點給指標暖機用
    if not mt5.symbol_select(symbol, True):
        raise RuntimeError(f"{symbol}：券商找不到這個商品代碼，請確認 MT5 報價視窗裡的實際代號")

    max_age_sec = TF_SECONDS.get(tf_name, 900) * STALE_MULT
    df = None
    last_bar_age_sec = None
    for attempt in range(RETRY_ATTEMPTS):
        tick = wait_for_live_tick(symbol)
        rates = mt5.copy_rates_from_pos(symbol, MT5_TIMEFRAME_MAP[tf_name], 0, count)
        if rates is None or len(rates) == 0:
            raise RuntimeError(f"{symbol} {tf_name}：抓不到K棒資料，{mt5.last_error()}")
        df = pd.DataFrame(rates)
        df["time"] = pd.to_datetime(df["time"], unit="s")
        df = df.rename(columns={"tick_volume": "volume"})

        reference_now = pd.Timestamp(tick.time, unit="s") if tick and tick.time else pd.Timestamp.now()
        last_bar_age_sec = (reference_now - df["time"].iloc[-1]).total_seconds()
        if last_bar_age_sec <= max_age_sec:
            break
        if attempt < RETRY_ATTEMPTS - 1:
            print(f"[重試 {attempt + 1}/{RETRY_ATTEMPTS}] {symbol} {tf_name}：抓到的還是舊資料"
                  f"(最新K棒 {df['time'].iloc[-1]})，等終端機補齊本地歷史後再抓一次...")
            time.sleep(RETRY_WAIT_SEC)

    df.attrs["is_stale"] = last_bar_age_sec > max_age_sec
    df.attrs["last_bar_age_sec"] = last_bar_age_sec
    if df.attrs["is_stale"]:
        STALE_LOG.append((symbol, tf_name, last_bar_age_sec))
        print(f"[警告] {symbol} {tf_name}：重試{RETRY_ATTEMPTS}次後，抓到的最新K棒時間還是 "
              f"{df['time'].iloc[-1]}，跟MT5即時報價時間比差了 {last_bar_age_sec/60:.1f} 分鐘。這代表"
              f"MT5 終端機對這個商品/週期的本地歷史快取不完整——請在 MT5 裡手動切到這個商品、這個週期的"
              f"圖表看過一次(讓終端機把歷史抓下來)，或按 F2 開「歷史中心」手動下載更完整的歷史，再重跑一次。")
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
    if STALE_LOG:
        print(f"[警告] 共 {len(STALE_LOG)} 筆資料疑似過期(不是即時報價)，請檢查上面的警告訊息")
    return 0


if __name__ == "__main__":
    sys.exit(main())
