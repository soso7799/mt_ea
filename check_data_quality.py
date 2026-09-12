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


def _scan_gaps(dates: pd.Series, tf: str, symbol: str, holiday_gap_days: float = 5.0):
    """對一段已排序的時間序列掃描缺口，回傳 (suspicious_count, biggest_suspicious_gap_minutes,
    max_gap_minutes, gap_segments_list)。跟check_file()原本內嵌的邏輯一致，抽出來給
    「全部歷史」跟「只看最近N天」共用，不用寫兩次。"""
    expected_gap = EXPECTED_GAP_MINUTES.get(tf)
    if not expected_gap or len(dates) < 2:
        return 0, 0.0, 0.0, []

    suspicious = 0
    max_gap = 0.0
    biggest_suspicious_gap = 0.0
    segments = []
    dates = dates.reset_index(drop=True)
    for i in range(1, len(dates)):
        t_prev, t_cur = dates.iloc[i - 1], dates.iloc[i]
        gap = (t_cur - t_prev).total_seconds() / 60.0
        if gap > max_gap:
            max_gap = gap
        if gap > expected_gap * 20 and gap > holiday_gap_days * 24 * 60:
            suspicious += 1
            if gap > biggest_suspicious_gap:
                biggest_suspicious_gap = gap
            segments.append({
                "symbol": symbol, "tf": tf,
                "gap_start": str(t_prev), "gap_end": str(t_cur),
                "gap_days": round(gap / 1440.0, 2),
            })
    return suspicious, biggest_suspicious_gap, max_gap, segments


def check_file(path: str, symbol: str, tf: str, recent_days: int = 365):
    """回傳 (result_dict, gap_segments_list)。gap_segments_list 是這個檔案裡每一段
    「可疑缺漏」的明確起訖時間，直接可以拿去當作「該重新下載哪一段」的清單，
    不用自己再回頭肉眼比對。

    result_dict 同時包含「全部歷史」跟「只看最近recent_days天」兩組獨立的檢查結果
    (rows/status/notes 是全部歷史；recent_*開頭的是最近N天)——通常只要「最近N天」
    是乾淨的就夠拿去做參數優化，很久以前的舊缺口(例如商品中途換過代碼留下的洞)
    大部分情況下不用理會，看 recent_status 就好。"""
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
        "notes_gap_detail": "",
        "notes": "",
        "recent_status": "OK",
        "recent_rows": 0,
        "recent_missing_bars_estimate": 0,
        "recent_notes": "",
    }
    gap_segments = []

    df = load_csv(path)
    required = {"date", "open", "high", "low", "close", "volume"}
    if not required.issubset(df.columns):
        result["status"] = "FAIL"
        result["notes"] = f"欄位不符預期，實際欄位: {list(df.columns)}"
        return result, gap_segments

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
        return result, gap_segments

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

    # 假日(聖誕/元旦/國定假日等)常常從週三~週五就開始收假，一路連到隔週一/二才開盤，
    # 這種長間隔完全正常，不該被當成資料缺漏——不管缺口是從星期幾開始，只要總長度在
    # 「一般連續假期」的合理範圍內，就不算可疑。只有超過這個天數的缺口(通常代表商品
    # 中途換過代碼、資料庫本身有洞)才會被列為可疑，每一段都記下確切的起訖時間，
    # 存進gap_segments給merge_csv_segments.py用。
    suspicious, biggest_suspicious_gap, max_gap, segments = _scan_gaps(df["date"], tf, symbol)
    gap_segments.extend(segments)
    result["missing_bars_estimate"] = suspicious
    result["biggest_gap"] = f"{max_gap:.0f}分鐘"
    if suspicious > 0:
        result["notes_gap_detail"] = f"最大可疑缺口約{biggest_suspicious_gap/1440:.1f}天"

    problems = []
    if dup_count > 0:
        problems.append(f"{dup_count}筆重複時間戳")
    if zero_neg > 0:
        problems.append(f"{zero_neg}筆價格<=0")
    if viol > 0:
        problems.append(f"{viol}筆OHLC邏輯錯誤(high/low不合理)")
    if result["missing_bars_estimate"] > 0:
        problems.append(f"疑似{result['missing_bars_estimate']}處異常缺漏({result['notes_gap_detail']})，"
                         f"詳細起訖時間見GapSegments.csv")
    if bad_dates > 0:
        problems.append(f"{bad_dates}筆日期欄位解析失敗")
    if result["rows"] < 300:
        problems.append(f"資料筆數只有{result['rows']}根，可能不夠拿去做參數優化(建議至少300根以上)")

    if problems:
        result["status"] = "警告"
        result["notes"] = "；".join(problems)

    # ---- 只看最近 recent_days 天：這才是「現在能不能拿去優化」真正要看的欄位，
    # 很久以前的舊缺口(商品換過代碼之類)只要不影響最近這段，可以不用管。----
    cutoff = df["date"].iloc[-1] - pd.Timedelta(days=recent_days)
    recent_df = df[df["date"] >= cutoff].reset_index(drop=True)
    result["recent_rows"] = len(recent_df)

    recent_problems = []
    if len(recent_df) < 300:
        recent_problems.append(f"最近{recent_days}天只有{len(recent_df)}根，可能不夠拿去做參數優化")

    recent_dup = int(recent_df["date"].duplicated().sum()) if len(recent_df) > 0 else 0
    if recent_dup > 0:
        recent_problems.append(f"{recent_dup}筆重複時間戳")

    if len(recent_df) > 0:
        recent_viol = int((
            (recent_df["high"] < recent_df[["open", "close", "low"]].max(axis=1)) |
            (recent_df["low"] > recent_df[["open", "close", "high"]].min(axis=1))
        ).sum())
        if recent_viol > 0:
            recent_problems.append(f"{recent_viol}筆OHLC邏輯錯誤")

    r_suspicious, r_biggest, _, _ = _scan_gaps(recent_df["date"], tf, symbol) if len(recent_df) > 1 else (0, 0.0, 0.0, [])
    result["recent_missing_bars_estimate"] = r_suspicious
    if r_suspicious > 0:
        recent_problems.append(f"最近{recent_days}天內疑似{r_suspicious}處異常缺漏(最大約{r_biggest/1440:.1f}天)")

    if recent_problems:
        result["recent_status"] = "警告"
        result["recent_notes"] = "；".join(recent_problems)

    return result, gap_segments


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--data-dir", required=True, help="Data Console匯出CSV的資料夾")
    ap.add_argument("--recent-days", type=int, default=365,
                     help="只看最近幾天的資料夠不夠乾淨(預設365天=1年)，"
                          "這是實際拿去做參數優化真正要看的欄位，很久以前的舊缺口通常不用管")
    args = ap.parse_args()

    pattern = os.path.join(args.data_dir, "*_ALL_DATA_*.csv")
    files = sorted(glob.glob(pattern))
    if not files:
        print(f"在 {args.data_dir} 底下找不到任何 *_ALL_DATA_*.csv 檔案，先確認路徑對不對、有沒有先跑過EXPORT CSV。")
        return

    name_re = re.compile(r"^(.*?)_(M5|M15|H1|H4|D1)_ALL_DATA_.*\.csv$", re.IGNORECASE)

    rows = []
    all_gap_segments = []
    for path in files:
        base = os.path.basename(path)
        m = name_re.match(base)
        if not m:
            print(f"  [跳過，檔名格式看不懂] {base}")
            continue
        symbol, tf = m.group(1), m.group(2).upper()
        result, gap_segments = check_file(path, symbol, tf, recent_days=args.recent_days)
        rows.append(result)
        all_gap_segments.extend(gap_segments)

    report = pd.DataFrame(rows)
    out_path = os.path.join(args.data_dir, "DataQualityReport.csv")
    report.to_csv(out_path, index=False, encoding="utf-8-sig")

    # ---- 最近N天(重點)：這是實際能不能拿去優化真正要看的結果 ----
    recent_ok = (report["recent_status"] == "OK").sum()
    recent_warn = (report["recent_status"] == "警告").sum()
    print(f"\n=== 最近{args.recent_days}天資料狀況(這是重點) ===")
    print(f"共檢查 {len(report)} 個檔案：最近{args.recent_days}天乾淨 {recent_ok}　有問題 {recent_warn}")
    if recent_warn > 0:
        print("最近這段時間需要留意的檔案：")
        for _, r in report[report["recent_status"] != "OK"].iterrows():
            print(f"  [{r['symbol']} {r['tf']}] {r['recent_notes']}")
    else:
        print(f"最近{args.recent_days}天的資料全部乾淨，可以直接拿去跑 vegas_backtest_optimizer.py 了。")

    # ---- 全部歷史(參考用)：很久以前的舊缺口通常不用理會，只是留個紀錄 ----
    ok = (report["status"] == "OK").sum()
    warn = (report["status"] == "警告").sum()
    fail = (report["status"] == "FAIL").sum()
    print(f"\n=== 全部歷史資料狀況(參考用，不影響能不能優化) ===")
    print(f"共檢查 {len(report)} 個檔案：正常 {ok}　警告 {warn}　失敗 {fail}")
    print(f"完整報告已存到：{out_path}")

    if all_gap_segments:
        gap_path = os.path.join(args.data_dir, "GapSegments.csv")
        pd.DataFrame(all_gap_segments).to_csv(gap_path, index=False, encoding="utf-8-sig")
        print(f"\n找到 {len(all_gap_segments)} 段可疑缺口，確切起訖時間已存到：{gap_path}")
        print("這份清單就是「該去補抓哪一段」的依據——每一列都是 (商品,週期,缺口開始,缺口結束,缺口天數)。")


if __name__ == "__main__":
    main()
