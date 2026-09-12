#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
check_data_quality.py
======================
在跑 vegas_backtest_optimizer.py 之前，先確認 Data Console(GDH_ExportCSV)
匯出的歷史資料是不是「乾淨」的：有沒有缺漏時間段、重複時間戳、OHLC邏輯錯誤，
以及每個檔案實際涵蓋的日期範圍/根數夠不夠拿去做參數優化。

用法：
    python check_data_quality.py --data-dir "D:\\資料查詢\\ExportCSV"

會掃描資料夾裡所有符合 {Symbol}_{TF}_ALL_DATA_*.csv 的檔案(跟
vegas_backtest_optimizer.py讀取同一批檔案、同一套規則)，每個檔案各自
檢查一次，最後印出一張總表，並存成 DataQualityReport.csv。
"""

import argparse
import glob
import os
import re

import numpy as np
import pandas as pd

EXPECTED_GAP_MINUTES = {
    "M5": 5, "M15": 15, "H1": 60, "H4": 240, "D1": 1440,
}


def load_csv(path: str) -> pd.DataFrame:
    try:
        df = pd.read_csv(path, encoding="utf-8-sig")
    except UnicodeDecodeError:
        df = pd.read_csv(path, encoding="big5")

    rename_map = {}
    for col in df.columns:
        c = col.strip()
        if c in ("日期", "Date", "date"):
            rename_map[col] = "date"
        elif c in ("開", "Open", "open"):
            rename_map[col] = "open"
        elif c in ("高", "High", "high"):
            rename_map[col] = "high"
        elif c in ("低", "Low", "low"):
            rename_map[col] = "low"
        elif c in ("收", "Close", "close"):
            rename_map[col] = "close"
        elif c in ("成交量", "Volume", "volume"):
            rename_map[col] = "volume"
    df = df.rename(columns=rename_map)
    return df


def check_file(path: str, symbol: str, tf: str) -> dict:
    result = {
        "file": os.path.basename(path),
        "symbol": symbol,
        "tf": tf,
        "status": "OK",
        "rows": 0,
        "date_start": "",
        "date_end": "",
        "duplicate_timestamps": 0,
        "missing_bars_estimate": 0,
        "biggest_gap": "",
        "ohlc_violations": 0,
        "zero_or_negative_price": 0,
        "notes": "",
    }

    df = load_csv(path)
    required = {"date", "open", "high", "low", "close", "volume"}
    if not required.issubset(df.columns):
        result["status"] = "FAIL"
        result["notes"] = f"欄位不符預期，實際欄位: {list(df.columns)}"
        return result

    df["date"] = pd.to_datetime(df["date"], errors="coerce")
    bad_dates = df["date"].isna().sum()
    df = df.dropna(subset=["date"])

    for c in ("open", "high", "low", "close", "volume"):
        df[c] = pd.to_numeric(df[c], errors="coerce")
    df = df.dropna(subset=["open", "high", "low", "close"])

    df = df.sort_values("date").reset_index(drop=True)
    result["rows"] = len(df)
    if len(df) == 0:
        result["status"] = "FAIL"
        result["notes"] = "資料筆數為0"
        return result

    result["date_start"] = str(df["date"].iloc[0])
    result["date_end"] = str(df["date"].iloc[-1])

    dup_count = int(df["date"].duplicated().sum())
    result["duplicate_timestamps"] = dup_count

    zero_neg = int(((df[["open", "high", "low", "close"]] <= 0).any(axis=1)).sum())
    result["zero_or_negative_price"] = zero_neg

    viol = int((
        (df["high"] < df[["open", "close", "low"]].max(axis=1)) |
        (df["low"] > df[["open", "close", "high"]].min(axis=1))
    ).sum())
    result["ohlc_violations"] = viol

    expected_gap = EXPECTED_GAP_MINUTES.get(tf)
    if expected_gap and len(df) > 1:
        diffs = df["date"].diff().dropna().dt.total_seconds() / 60.0
        # 週末/假日休市造成的長間隔是正常的，只挑出「不是週末、但間隔仍然異常大」的當作真正缺漏
        # 這裡用一個寬鬆但實用的門檻：超過 expected_gap * 20 且發生在週一~週五之間才算可疑缺漏
        # (週五收盤到週日/週一開盤的長間隔會被自動排除，不會被誤判)
        suspicious = 0
        max_gap = 0.0
        for i in range(1, len(df)):
            gap = (df["date"].iloc[i] - df["date"].iloc[i - 1]).total_seconds() / 60.0
            if gap > max_gap:
                max_gap = gap
            weekday_start = df["date"].iloc[i - 1].weekday()  # 0=Mon ... 6=Sun
            is_weekend_gap = weekday_start >= 4 and gap > 24 * 60  # 週五之後的長間隔視為正常收假
            if gap > expected_gap * 20 and not is_weekend_gap:
                suspicious += 1
        result["missing_bars_estimate"] = suspicious
        result["biggest_gap"] = f"{max_gap:.0f}分鐘"

    problems = []
    if dup_count > 0:
        problems.append(f"{dup_count}筆重複時間戳")
    if zero_neg > 0:
        problems.append(f"{zero_neg}筆價格<=0")
    if viol > 0:
        problems.append(f"{viol}筆OHLC邏輯錯誤(high/low不合理)")
    if result["missing_bars_estimate"] > 0:
        problems.append(f"疑似{result['missing_bars_estimate']}處平日資料缺漏")
    if bad_dates > 0:
        problems.append(f"{bad_dates}筆日期欄位解析失敗")
    if result["rows"] < 300:
        problems.append(f"資料筆數只有{result['rows']}根，可能不夠拿去做參數優化(建議至少300根以上)")

    if problems:
        result["status"] = "警告"
        result["notes"] = "；".join(problems)

    return result


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--data-dir", required=True, help="Data Console匯出CSV的資料夾")
    args = ap.parse_args()

    pattern = os.path.join(args.data_dir, "*_ALL_DATA_*.csv")
    files = sorted(glob.glob(pattern))
    if not files:
        print(f"在 {args.data_dir} 底下找不到任何 *_ALL_DATA_*.csv 檔案，先確認路徑對不對、有沒有先跑過EXPORT CSV。")
        return

    name_re = re.compile(r"^(.*?)_(M5|M15|H1|H4|D1)_ALL_DATA_.*\.csv$", re.IGNORECASE)

    rows = []
    for path in files:
        base = os.path.basename(path)
        m = name_re.match(base)
        if not m:
            print(f"  [跳過，檔名格式看不懂] {base}")
            continue
        symbol, tf = m.group(1), m.group(2).upper()
        rows.append(check_file(path, symbol, tf))

    report = pd.DataFrame(rows)
    out_path = os.path.join(args.data_dir, "DataQualityReport.csv")
    report.to_csv(out_path, index=False, encoding="utf-8-sig")

    ok = (report["status"] == "OK").sum()
    warn = (report["status"] == "警告").sum()
    fail = (report["status"] == "FAIL").sum()
    print(f"\n共檢查 {len(report)} 個檔案：正常 {ok}　警告 {warn}　失敗 {fail}")
    print(f"完整報告已存到：{out_path}\n")

    if warn > 0 or fail > 0:
        print("需要留意的檔案：")
        for _, r in report[report["status"] != "OK"].iterrows():
            print(f"  [{r['status']}] {r['symbol']} {r['tf']}: {r['notes']}")
    else:
        print("全部檔案都正常，可以直接拿去跑 vegas_backtest_optimizer.py 了。")


if __name__ == "__main__":
    main()
