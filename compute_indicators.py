"""
compute_indicators.py

從 merged 資料夾的 OHLCV CSV，算出11個技術指標在每個 symbol x period 的
最新多空判定，輸出兩份結果：
  1. multi_symbol_status.csv  -> 對應 Excel「多商品狀態總表」(D1/H4/H1/M15/M5全部週期)
     多了一欄 TrendlineSignal：自動抓最近波段高低點畫壓力/支撐線，判斷現在是
     「向上突破」「向下突破」「收斂待變（尚未突破）」還是「區間整理中」——
     這不是11指標之一、不計入多空票數，是額外給的型態判斷，專門處理像楔形/
     三角收斂這種光看指標票數看不出方向、要看價格有沒有真的突破線才算數的情況。
  2. higher_tf_trend.csv      -> 新工作表「長週期趨勢總表」，只用 D1/H4/H1/M15
     加權汇总出每個商品的「綜合長週期判定」，給M5進場當濾網用。

⚠️ 這支腳本定義的「多頭/空頭」判定規則(見下面 CONFIG 區塊)是我先按常見慣例
   訂的預設值，會直接影響交易判斷，正式上線前請自己過一遍、覺得哪裡不合理
   就直接改 CONFIG，不用改下面的計算邏輯。

用法（參數都有預設值，直接執行即可）：
    python compute_indicators.py
    python compute_indicators.py --merged-dir "D:\\整合計畫\\整理後\\ExportCSV\\merged" ^
        --out-dir "D:\\整合計畫\\update_output"

資料來源：MT5 有開就直接抓 MT5 最新K棒（每次都是最新）；
          MT5 沒開才退回讀 merged 資料夾的 CSV。
"""

import argparse
import glob
import os
import re
import sys

import numpy as np
import pandas as pd

try:
    import MetaTrader5 as mt5
except ImportError:
    mt5 = None

DEFAULT_MERGED_DIR = r"G:\我的雲端硬碟\ExportCSV\merged"
DEFAULT_OUT_DIR = r"G:\我的雲端硬碟\整理後\update_output"
MT5_BARS = 500  # 從 MT5 每個週期抓幾根K棒

# 儀表板/關卡上會看的商品（merged 資料夾裡找到的也會自動加入）
DEFAULT_SYMBOLS = ["EURUSD", "GBPUSD", "USDJPY", "USDCAD", "AUDUSD", "USDCHF", "USDCNH", "NZDUSD",
                   "US500.cash", "US30.cash", "US100.cash", "JP225.cash", "XAUUSD", "XAUAUD",
                   "USOIL.cash", "NATGAS.cash"]

# ============================================================
# CONFIG —— 每個指標的參數 + 多頭判定規則，全部集中在這裡，方便你直接調整
# ============================================================
PERIODS = ["D1", "H4", "H1", "M15", "M5"]

# 長週期趨勢總表的加權（只用D1/H4/H1/M15，原35/25/20/12%正規化到100%）
HIGHER_TF_WEIGHTS = {"D1": 0.38, "H4": 0.27, "H1": 0.22, "M15": 0.13}

# 趨勢線收斂/突破偵測參數（不是11指標之一，獨立輸出成一欄，不計入多空票數）
TRENDLINE_LOOKBACK = 40      # 抓最近幾根K棒來找高低點、畫壓力/支撐線
TRENDLINE_SWING_WINDOW = 3   # 判定「這根是不是波段高/低點」時，左右各看幾根
TRENDLINE_MIN_SWINGS = 2     # 至少要抓到幾個波段高點/低點才畫得出線
TRENDLINE_CONVERGE_PCT = 0.15  # 上下軌距離縮小到現價的這個百分比以內，算「即將收斂」

IND_PARAMS = {
    "MA": {"short": 8, "long": 50},
    "RSI": {"length": 14, "mid": 50},
    "KD": {"length": 9, "smooth_k": 3, "smooth_d": 3},
    "PSY": {"length": 12, "mid": 50},
    "WR": {"length": 14, "mid": -50},
    "MTM": {"length": 10},
    "MACD": {"fast": 12, "slow": 26, "signal": 9},
    "BOLL": {"length": 20, "mult": 2.0},
    "CCI": {"length": 14},
    "BIAS": {"length": 20},
    "KELTNER": {"length": 20, "mult": 1.5},
}


# ============================================================
# 指標計算（純 pandas，不依賴額外的 TA 套件）
# ============================================================
def ema(s: pd.Series, length: int) -> pd.Series:
    return s.ewm(span=length, adjust=False).mean()


def find_swing_points(series: pd.Series, window: int, kind: str):
    """找波段高點(kind='high')或波段低點(kind='low')：
    某根K棒的值，比它左右各window根都高(或都低)，就算一個波段點。
    回傳 (位置索引, 數值) 的list，位置索引是series裡的相對位置(0起算)。"""
    vals = series.values
    n = len(vals)
    points = []
    for i in range(window, n - window):
        seg = vals[i - window: i + window + 1]
        center = vals[i]
        if kind == "high" and center == seg.max() and not np.isnan(center):
            points.append((i, center))
        elif kind == "low" and center == seg.min() and not np.isnan(center):
            points.append((i, center))
    return points


def detect_trendline_breakout(df: pd.DataFrame) -> str:
    """抓最近 TRENDLINE_LOOKBACK 根K棒的波段高點畫壓力線、波段低點畫支撐線
    （用一次線性回歸，不是隨便連兩點），拿現在收盤價跟這兩條線在「現在」
    這個時間點的推算值比，判斷：
      - 收盤價衝出壓力線之上 -> 向上突破
      - 收盤價跌破支撐線之下 -> 向下突破
      - 都沒有，但壓力線在下降、支撐線在上升、兩線距離已經縮到現價的
        TRENDLINE_CONVERGE_PCT 以內 -> 收斂待變（楔形/三角形快到頂點了）
      - 其餘 -> 區間整理中
    資料不夠（波段高/低點抓不到至少 TRENDLINE_MIN_SWINGS 個）時回傳「資料不足」，
    不硬給結論。
    """
    recent = df.tail(TRENDLINE_LOOKBACK).reset_index(drop=True)
    if len(recent) < TRENDLINE_LOOKBACK:
        return "資料不足"

    highs = find_swing_points(recent["high"], TRENDLINE_SWING_WINDOW, "high")
    lows = find_swing_points(recent["low"], TRENDLINE_SWING_WINDOW, "low")

    if len(highs) < TRENDLINE_MIN_SWINGS or len(lows) < TRENDLINE_MIN_SWINGS:
        return "資料不足"

    high_x = np.array([p[0] for p in highs])
    high_y = np.array([p[1] for p in highs])
    low_x = np.array([p[0] for p in lows])
    low_y = np.array([p[1] for p in lows])

    res_slope, res_intercept = np.polyfit(high_x, high_y, 1)
    sup_slope, sup_intercept = np.polyfit(low_x, low_y, 1)

    latest_idx = len(recent) - 1
    resistance_now = res_slope * latest_idx + res_intercept
    support_now = sup_slope * latest_idx + sup_intercept
    current_close = float(recent["close"].iloc[-1])

    if current_close > resistance_now:
        return "向上突破"
    if current_close < support_now:
        return "向下突破"

    gap_pct = abs(resistance_now - support_now) / current_close * 100 if current_close else None
    is_converging = (res_slope < 0) and (sup_slope > 0)
    if gap_pct is not None and gap_pct <= TRENDLINE_CONVERGE_PCT and is_converging:
        return "收斂待變（尚未突破）"
    return "區間整理中"


def compute_all_indicators(df: pd.DataFrame) -> dict:
    """df 需含 open/high/low/close 欄位（volume可有可無），時間由舊到新排序。
    回傳 dict：{指標名: True(多頭)/False(空頭)/None(資料不足)}"""
    close, high, low = df["close"], df["high"], df["low"]
    votes = {}

    # ---- MA ----
    p = IND_PARAMS["MA"]
    ma_s = close.rolling(p["short"]).mean()
    ma_l = close.rolling(p["long"]).mean()
    votes["MA"] = None if pd.isna(ma_s.iloc[-1]) or pd.isna(ma_l.iloc[-1]) \
        else bool(ma_s.iloc[-1] > ma_l.iloc[-1])

    # ---- RSI (Wilder) ----
    p = IND_PARAMS["RSI"]
    delta = close.diff()
    gain = delta.clip(lower=0)
    loss = -delta.clip(upper=0)
    avg_gain = gain.ewm(alpha=1 / p["length"], adjust=False).mean()
    avg_loss = loss.ewm(alpha=1 / p["length"], adjust=False).mean()
    rs = avg_gain / avg_loss.replace(0, np.nan)
    rsi = 100 - (100 / (1 + rs))
    votes["RSI"] = None if pd.isna(rsi.iloc[-1]) else bool(rsi.iloc[-1] > p["mid"])

    # ---- KD (Stochastic) ----
    p = IND_PARAMS["KD"]
    ll = low.rolling(p["length"]).min()
    hh = high.rolling(p["length"]).max()
    rsv = (close - ll) / (hh - ll).replace(0, np.nan) * 100
    k = rsv.ewm(alpha=1 / p["smooth_k"], adjust=False).mean()
    d = k.ewm(alpha=1 / p["smooth_d"], adjust=False).mean()
    votes["KD"] = None if pd.isna(k.iloc[-1]) or pd.isna(d.iloc[-1]) \
        else bool(k.iloc[-1] > d.iloc[-1])

    # ---- PSY (Psychological Line) ----
    p = IND_PARAMS["PSY"]
    up_day = (close.diff() > 0).astype(float)
    psy = up_day.rolling(p["length"]).sum() / p["length"] * 100
    votes["PSY"] = None if pd.isna(psy.iloc[-1]) else bool(psy.iloc[-1] > p["mid"])

    # ---- Williams %R ----
    p = IND_PARAMS["WR"]
    hh_w = high.rolling(p["length"]).max()
    ll_w = low.rolling(p["length"]).min()
    wr = (hh_w - close) / (hh_w - ll_w).replace(0, np.nan) * -100
    votes["WR"] = None if pd.isna(wr.iloc[-1]) else bool(wr.iloc[-1] > p["mid"])

    # ---- MTM (Momentum) ----
    p = IND_PARAMS["MTM"]
    mtm = close.diff(p["length"])
    votes["MTM"] = None if pd.isna(mtm.iloc[-1]) else bool(mtm.iloc[-1] > 0)

    # ---- MACD ----
    p = IND_PARAMS["MACD"]
    macd_line = ema(close, p["fast"]) - ema(close, p["slow"])
    signal_line = ema(macd_line, p["signal"])
    votes["MACD"] = None if pd.isna(macd_line.iloc[-1]) or pd.isna(signal_line.iloc[-1]) \
        else bool(macd_line.iloc[-1] > signal_line.iloc[-1])

    # ---- BOLL (中軌) ----
    p = IND_PARAMS["BOLL"]
    mid = close.rolling(p["length"]).mean()
    votes["BOLL"] = None if pd.isna(mid.iloc[-1]) else bool(close.iloc[-1] > mid.iloc[-1])

    # ---- CCI ----
    p = IND_PARAMS["CCI"]
    tp = (high + low + close) / 3
    tp_ma = tp.rolling(p["length"]).mean()
    tp_md = tp.rolling(p["length"]).apply(lambda x: np.mean(np.abs(x - x.mean())), raw=True)
    cci = (tp - tp_ma) / (0.015 * tp_md.replace(0, np.nan))
    votes["CCI"] = None if pd.isna(cci.iloc[-1]) else bool(cci.iloc[-1] > 0)

    # ---- BIAS (乖離率) ----
    p = IND_PARAMS["BIAS"]
    ma_b = close.rolling(p["length"]).mean()
    bias = (close - ma_b) / ma_b.replace(0, np.nan) * 100
    votes["BIAS"] = None if pd.isna(bias.iloc[-1]) else bool(bias.iloc[-1] > 0)

    # ---- KELTNER (中線=EMA) ----
    p = IND_PARAMS["KELTNER"]
    mid_k = ema(close, p["length"])
    votes["KELTNER"] = None if pd.isna(mid_k.iloc[-1]) else bool(close.iloc[-1] > mid_k.iloc[-1])

    return votes


# ============================================================
# 讀檔 / 主流程
# ============================================================
def find_csv(merged_dir: str, symbol: str, period: str):
    """依 symbol+period 找對應CSV。檔名規則請依你merged資料夾實際命名調整這裡的pattern。"""
    patterns = [
        f"{symbol}_{period}*.csv",
        f"{symbol}*{period}*.csv",
        f"*{symbol}*{period}*.csv",
    ]
    for pat in patterns:
        hits = glob.glob(os.path.join(merged_dir, pat))
        if hits:
            return max(hits, key=os.path.getmtime)  # 同名多檔取最新
    return None


def load_ohlc(csv_path: str) -> pd.DataFrame:
    df = pd.read_csv(csv_path)
    df.columns = [c.strip().lower() for c in df.columns]
    time_col = "datetime" if "datetime" in df.columns else df.columns[0]
    df[time_col] = pd.to_datetime(df[time_col])
    df = df.sort_values(time_col).reset_index(drop=True)
    df = df.rename(columns={time_col: "datetime"})
    return df


def load_ohlc_mt5(symbol: str, period: str):
    """直接從 MT5 抓最新 K 棒；抓不到回傳 None"""
    if mt5 is None:
        return None
    tf = getattr(mt5, "TIMEFRAME_" + period, None)
    if tf is None or not mt5.symbol_select(symbol, True):
        return None
    rates = mt5.copy_rates_from_pos(symbol, tf, 0, MT5_BARS)
    if rates is None or len(rates) == 0:
        return None
    df = pd.DataFrame(rates)
    df["datetime"] = pd.to_datetime(df["time"], unit="s")
    df = df.rename(columns={"tick_volume": "volume"})
    return df[["datetime", "open", "high", "low", "close", "volume"]].reset_index(drop=True)


def status_from_votes(long_v: int, short_v: int) -> str:
    if long_v > short_v:
        return "多頭確認"
    if short_v > long_v:
        return "空頭確認"
    return "震盪"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--merged-dir", default=DEFAULT_MERGED_DIR, help="merged CSV 資料夾路徑")
    ap.add_argument("--symbols-file", default=None,
                     help="每行一個商品代碼的txt檔；不給的話會嘗試從merged資料夾檔名自動推測")
    ap.add_argument("--out-dir", default=DEFAULT_OUT_DIR, help="輸出CSV的資料夾")
    args = ap.parse_args()

    os.makedirs(args.out_dir, exist_ok=True)

    if not glob.glob(os.path.join(args.merged_dir, "*.csv")):
        # merged 資料夾被搬走時，用 strategy_test 的自動尋找（往下 4 層找有資料的 merged）
        try:
            import strategy_test
            found_dir = strategy_test.find_merged_dir()
            if found_dir:
                args.merged_dir = found_dir
                print(f"[merged] 預設資料夾沒有資料，改用 {found_dir}")
        except Exception as e:
            print(f"[merged] 自動尋找失敗：{e}")

    if args.symbols_file:
        with open(args.symbols_file, encoding="utf-8") as f:
            symbols = [ln.strip() for ln in f if ln.strip()]
    else:
        # 從檔名猜商品代碼：抓每個檔名開頭到第一個 "_" 之前的字串，去重
        # （_last_bar_state.csv 這類 "_" 開頭的檔案會得到空字串，要排除）
        files = glob.glob(os.path.join(args.merged_dir, "*.csv"))
        found = {os.path.basename(f).split("_")[0].strip() for f in files}
        symbols = sorted(s for s in found | set(DEFAULT_SYMBOLS) if s)
        print(f"[商品] {len(symbols)} 個：{symbols}")

    use_mt5 = mt5 is not None and mt5.initialize()
    print("[資料來源] " + ("MT5 即時K棒" if use_mt5 else "merged CSV（MT5 未開啟）"))

    status_rows = []
    higher_rows = []

    for symbol in symbols:
        period_status = {}
        for period in PERIODS:
            df = load_ohlc_mt5(symbol, period) if use_mt5 else None
            from_mt5 = df is not None
            if df is None:
                csv_path = find_csv(args.merged_dir, symbol, period)
                if not csv_path:
                    print(f"[跳過] {symbol}-{period}：MT5 與 merged 都找不到資料")
                    continue
                df = load_ohlc(csv_path)
            if len(df) < 60:  # 指標需要的最長回看是MA長線50，抓60根保守一點
                print(f"[跳過] {symbol}-{period}：資料筆數不足({len(df)}筆)")
                continue

            # 多空判定只用「已收盤」的 K 棒（MT5 最後一根是還在跑的，拿掉；merged 檔本來就是收盤資料）
            df_closed = df.iloc[:-1].reset_index(drop=True) if from_mt5 else df
            votes = compute_all_indicators(df_closed)
            long_v = sum(1 for v in votes.values() if v is True)
            short_v = sum(1 for v in votes.values() if v is False)
            status = status_from_votes(long_v, short_v)
            trendline_signal = detect_trendline_breakout(df_closed)

            latest_time = df["datetime"].iloc[-1]
            latest_close = df["close"].iloc[-1]

            status_rows.append({
                "Symbol": symbol, "Period": period,
                "LatestTime": latest_time, "LatestClose": latest_close,
                "LongVotes": long_v, "ShortVotes": short_v, "Status": status,
                "TrendlineSignal": trendline_signal,
                # 11 指標各自的多空（給儀表板第21~25列）
                **{name: ("多" if v is True else "空" if v is False else "")
                   for name, v in votes.items()},
            })

            if period in HIGHER_TF_WEIGHTS:
                period_status[period] = (long_v, short_v)

        # ---- 匯總長週期趨勢（只用D1/H4/H1/M15） ----
        if period_status:
            score = 0.0
            detail = {}
            for period, weight in HIGHER_TF_WEIGHTS.items():
                if period in period_status:
                    lv, sv = period_status[period]
                    detail[f"{period}_多頭票"] = lv
                    detail[f"{period}_空頭票"] = sv
                    score += weight * (1 if lv > sv else (-1 if sv > lv else 0))
                else:
                    detail[f"{period}_多頭票"] = None
                    detail[f"{period}_空頭票"] = None

            if score > 0.15:
                verdict = "多頭"
            elif score < -0.15:
                verdict = "空頭"
            else:
                verdict = "中性"

            row = {"Symbol": symbol, **detail, "加權分數": round(score, 3), "綜合長週期判定": verdict}
            higher_rows.append(row)

    if use_mt5:
        mt5.shutdown()

    if not status_rows:
        print("沒有任何商品算出結果，不覆蓋舊檔。", file=sys.stderr)
        sys.exit(1)

    status_df = pd.DataFrame(status_rows)
    higher_df = pd.DataFrame(higher_rows)

    status_out = os.path.join(args.out_dir, "multi_symbol_status.csv")
    higher_out = os.path.join(args.out_dir, "higher_tf_trend.csv")
    status_df.to_csv(status_out, index=False, encoding="utf-8-sig")
    higher_df.to_csv(higher_out, index=False, encoding="utf-8-sig")

    print(f"完成：{len(status_df)} 列寫入 {status_out}")
    print(f"完成：{len(higher_df)} 列寫入 {higher_out}")


if __name__ == "__main__":
    main()
