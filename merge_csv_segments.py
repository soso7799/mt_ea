#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
merge_csv_segments.py
======================
把「同一個商品+週期」的多份 Data Console 匯出CSV(例如：原本的完整匯出 +
之後為了補上某段缺口另外抓的一小段)合併成一份，去重、依時間排序，
輸出成新的一份，檔名照 Data Console 原本的命名規則加上新的時間戳，
這樣 vegas_backtest_optimizer.py(挑檔名時間戳最新的那份)會自動抓到
合併後的完整版本，不會誤抓到只有一小段的補抓檔案。

用法(針對單一 Symbol+TF，把資料夾裡所有符合的檔案全部合併)：
    python merge_csv_segments.py --data-dir "D:\\資料查詢\\ExportCSV" --symbol JP225.cash --tf M5

用法(全部商品+週期一次合併，資料夾裡有幾組就處理幾組)：
    python merge_csv_segments.py --data-dir "D:\\資料查詢\\ExportCSV" --all

合併規則：
  - 依時間戳排序、時間重複的列只保留一筆(不會重複計算同一根K棒)
  - 只要求欄位對得上(日期,開,高,低,收,成交量)，不要求兩份檔案的時間範圍要相鄰
    或不重疊——有重疊也沒關係，反正會被去重
  - 合併後用 check_data_quality.py 再檢查一次，確認缺口真的補上了
"""

import argparse
import glob
import os
import re
import time

import pandas as pd


def load_csv(path: str) -> pd.DataFrame:
    try:
        df = pd.read_csv(path, encoding="utf-8-sig")
    except UnicodeDecodeError:
        df = pd.read_csv(path, encoding="big5")

    rename_map = {}
    for col in df.columns:
        c = col.strip()
        if c in ("日期", "Date", "date"):
            rename_map[col] = "日期"
        elif c in ("開", "Open", "open"):
            rename_map[col] = "開"
        elif c in ("高", "High", "high"):
            rename_map[col] = "高"
        elif c in ("低", "Low", "low"):
            rename_map[col] = "低"
        elif c in ("收", "Close", "close"):
            rename_map[col] = "收"
        elif c in ("成交量", "Volume", "volume"):
            rename_map[col] = "成交量"
    return df.rename(columns=rename_map)


def merge_one(data_dir: str, symbol: str, tf: str) -> bool:
    pattern = os.path.join(data_dir, f"{symbol}_{tf}_ALL_DATA_*.csv")
    matches = sorted(glob.glob(pattern))
    if len(matches) == 0:
        print(f"[{symbol} {tf}] 找不到任何符合的檔案，跳過")
        return False
    if len(matches) == 1:
        print(f"[{symbol} {tf}] 只有1份檔案，沒有需要合併的東西，跳過")
        return False

    print(f"[{symbol} {tf}] 找到 {len(matches)} 份檔案，開始合併：")
    for m in matches:
        print(f"    - {os.path.basename(m)}")

    frames = []
    for m in matches:
        df = load_csv(m)
        required = {"日期", "開", "高", "低", "收", "成交量"}
        if not required.issubset(df.columns):
            print(f"    [跳過此檔，欄位不符] {os.path.basename(m)}: {list(df.columns)}")
            continue
        frames.append(df[["日期", "開", "高", "低", "收", "成交量"]])

    if not frames:
        print(f"[{symbol} {tf}] 沒有任何檔案的欄位是對的，無法合併")
        return False

    merged = pd.concat(frames, ignore_index=True)
    merged["日期"] = pd.to_datetime(merged["日期"], errors="coerce")
    before = len(merged)
    merged = merged.dropna(subset=["日期"])
    merged = merged.sort_values("日期").drop_duplicates(subset="日期", keep="first").reset_index(drop=True)
    after = len(merged)

    out_name = f"{symbol}_{tf}_ALL_DATA_{time.strftime('%Y%m%d_%H%M%S')}.csv"
    out_path = os.path.join(data_dir, out_name)
    merged.to_csv(out_path, index=False, encoding="utf-8-sig")

    print(f"[{symbol} {tf}] 合併完成：{before}筆 -> 去重排序後 {after}筆")
    print(f"    範圍：{merged['日期'].iloc[0]} ~ {merged['日期'].iloc[-1]}")
    print(f"    輸出：{out_path}")
    print(f"    (原本 {len(matches)} 份分段檔案都還留著沒刪，確認合併結果沒問題後可以自行手動刪除)")
    return True


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--data-dir", required=True, help="Data Console匯出CSV的資料夾")
    ap.add_argument("--symbol", help="要合併的商品代碼，例如 JP225.cash")
    ap.add_argument("--tf", help="要合併的週期，例如 M5")
    ap.add_argument("--all", action="store_true", help="資料夾裡所有(商品,週期)只要有超過1份檔案就全部合併")
    args = ap.parse_args()

    if args.all:
        pattern = os.path.join(args.data_dir, "*_ALL_DATA_*.csv")
        files = glob.glob(pattern)
        name_re = re.compile(r"^(.*?)_(M5|M15|H1|H4|D1)_ALL_DATA_.*\.csv$", re.IGNORECASE)
        pairs = set()
        for path in files:
            m = name_re.match(os.path.basename(path))
            if m:
                pairs.add((m.group(1), m.group(2).upper()))
        if not pairs:
            print(f"在 {args.data_dir} 底下找不到任何 *_ALL_DATA_*.csv 檔案。")
            return
        merged_any = False
        for symbol, tf in sorted(pairs):
            if merge_one(args.data_dir, symbol, tf):
                merged_any = True
        if not merged_any:
            print("\n沒有任何(商品,週期)有超過1份檔案，沒有東西需要合併。")
    else:
        if not args.symbol or not args.tf:
            print("請指定 --symbol 和 --tf(單一合併)，或用 --all(全部一次處理)。")
            return
        merge_one(args.data_dir, args.symbol, args.tf)


if __name__ == "__main__":
    main()
