# update_all_data.py
# 從 D:\資料查詢\ExportCSV 抓最新資料，輸出成 Excel 可讀的 CSV
import pandas as pd
from pathlib import Path
from datetime import date, datetime
import re

# ⚠️ 原本寫死指到 D:\historical_data，但實際的批次匯出巨集
# （GDH_BatchExportSelected）是把 CSV 匯出到 D:\資料查詢\ExportCSV\，
# 兩個資料夾完全不同，導致這支腳本永遠讀不到新資料。已改成正確路徑。
DATA_FOLDER = Path(r"D:\資料查詢\ExportCSV")
# merge_export_csv.py 把同一個商品/週期的所有匯出快照合併成一份連續、去重
# 的完整歷史，放在這個子資料夾。有合併檔就優先用它（資料更完整、更連續），
# 只有在還沒跑過合併腳本時才退回去找單一份最新的原始快照。
MERGED_FOLDER = DATA_FOLDER / "merged"
OUTPUT_FOLDER = Path(r"D:\整合計畫\update_output")  # 輸出目錄
OUTPUT_FOLDER.mkdir(exist_ok=True)

SYMBOLS = [
    "EURUSD", "GBPUSD", "USDJPY", "USDCAD", "AUDUSD", "NZDUSD",
    "USDCHF", "USDCNH", "US500.cash", "US30.cash", "US100.cash", "JP225.cash"
]

# Recent_Support/Recent_Resistance 用的近期高低點回看K棒數
RECENT_LOOKBACK_BARS = 288  # M5 x 288 = 24小時

def find_latest_m5(sym: str):
    merged_path = MERGED_FOLDER / f"{sym}_M5_MERGED_ALL_DATA.csv"
    if merged_path.exists():
        return merged_path

    pattern = re.compile(rf"{re.escape(sym)}_M5_ALL_DATA_(\d{{8}})_(\d{{6}})\.csv", re.I)
    cands = []
    for f in DATA_FOLDER.glob(f"{sym}_M5_ALL_DATA_*.csv"):
        m = pattern.search(f.name)
        if m:
            cands.append((m.group(1) + m.group(2), f))
    if not cands:
        return None
    cands.sort(reverse=True)
    return cands[0][1]

def load_m5(path: Path):
    for enc in ["utf-8-sig", "utf-8", "big5", "cp950"]:
        try:
            df = pd.read_csv(path, encoding=enc)
            break
        except:
            continue
    else:
        return None
    col_map = {}
    for c in df.columns:
        cs = str(c).lower()
        if any(k in cs for k in ["date", "time", "日期", "時間"]):
            col_map[c] = "datetime"
        elif cs in ["open", "開", "o"]:
            col_map[c] = "open"
        elif cs in ["high", "高", "h"]:
            col_map[c] = "high"
        elif cs in ["low", "低", "l"]:
            col_map[c] = "low"
        elif cs in ["close", "收", "c"]:
            col_map[c] = "close"
        elif cs in ["volume", "vol", "成交量"]:
            col_map[c] = "volume"
    df = df.rename(columns=col_map)
    if "datetime" not in df.columns:
        return None
    df["datetime"] = pd.to_datetime(df["datetime"], errors="coerce")
    df = df.dropna(subset=["datetime"]).sort_values("datetime")
    return df

def session_high_low(df, start_h, end_h):
    """簡易時段高低（依小時，伺服器時間）"""
    if df is None or df.empty:
        return None, None
    d = df.copy()
    d["hour"] = d["datetime"].dt.hour
    mask = (d["hour"] >= start_h) & (d["hour"] < end_h)
    sub = d[mask]
    if sub.empty:
        return None, None
    return float(sub["high"].max()), float(sub["low"].min())

def recent_support_resistance(df, lookback_bars: int):
    """近期支撐/壓力：抓最近N根K棒的最低/最高，抓不到回傳 None"""
    if df is None or df.empty:
        return None, None
    recent = df.tail(lookback_bars)
    if recent.empty:
        return None, None
    return float(recent["low"].min()), float(recent["high"].max())

def main():
    rows_open = []
    rows_levels = []

    for sym in SYMBOLS:
        print(f"處理 {sym} ...")
        f = find_latest_m5(sym)
        if f is None:
            print("  找不到 M5")
            continue
        df = load_m5(f)
        if df is None or df.empty:
            print("  讀取失敗")
            continue

        latest = df["datetime"].max()
        day = latest.date()
        day_df = df[df["datetime"].dt.date == day].sort_values("datetime")
        open_price = float(day_df.iloc[0]["open"])
        last_close = float(day_df.iloc[-1]["close"])

        # 簡易時段（FTMO 伺服器時間大約）
        # 亞盤 0-8, 歐盤 8-16, 美盤 16-24（可依實際調整）
        ah, al = session_high_low(day_df, 0, 8)
        eh, el = session_high_low(day_df, 8, 16)
        uh, ul = session_high_low(day_df, 16, 24)

        # 若當日某時段無資料，用全日高低近似
        day_high = float(day_df["high"].max())
        day_low = float(day_df["low"].min())

        # 近期支撐/壓力（抓全部資料的最近N根K棒，不限於當日）
        rs, rr = recent_support_resistance(df, RECENT_LOOKBACK_BARS)

        rows_open.append({
            "Symbol": sym,
            "TodayOpen": open_price,
            "LatestClose": last_close,
            "DataDate": day,
            "LatestTime": latest,
            "SourceFile": f.name
        })

        rows_levels.append({
            "Symbol": sym,
            "PrevDate": day,
            "Asian_High": ah or day_high,
            "Asian_Low": al or day_low,
            "European_High": eh or day_high,
            "European_Low": el or day_low,
            "US_High": uh or day_high,
            "US_Low": ul or day_low,
            "PrevDay_High": day_high,
            "PrevDay_Low": day_low,
            "CurrentPrice": last_close,
            "Recent_Support": rs if rs is not None else day_low,
            "Recent_Resistance": rr if rr is not None else day_high
        })
        print(f"  開盤={open_price} 現價={last_close} 日期={day}")

    # 輸出
    pd.DataFrame(rows_open).to_csv(OUTPUT_FOLDER / "today_open.csv", index=False, encoding="utf-8-sig")
    pd.DataFrame(rows_levels).to_csv(OUTPUT_FOLDER / "session_levels.csv", index=False, encoding="utf-8-sig")
    print(f"\n已輸出到 {OUTPUT_FOLDER}")
    print("  - today_open.csv")
    print("  - session_levels.csv")

if __name__ == "__main__":
    main()
