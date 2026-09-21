# merge_export_csv.py
# 把 D:\資料查詢\ExportCSV 底下同一個 商品+週期 的所有匯出快照
# （檔名格式：{symbol}_{tf}_ALL_DATA_{yyyymmdd}_{hhmmss}.csv）合併成
# 一份連續、去重、按時間排序的完整資料庫，寫到 merged 子資料夾。
#
# 不會刪除或搬動任何原始匯出檔——原始快照全部保留，只是多產生一份
# 合併後的檔案，供 update_all_data.py 之類的下游腳本讀取更完整的歷史。
#
# 用法：直接執行本腳本即可，會自動掃描資料夾裡出現過的所有商品/週期組合。
import pandas as pd
from pathlib import Path
import re
from collections import defaultdict

SOURCE_FOLDER = Path(r"D:\資料查詢\ExportCSV")
MERGED_FOLDER = SOURCE_FOLDER / "merged"
MERGED_FOLDER.mkdir(exist_ok=True)

# 檔名格式：{symbol}_{tf}_ALL_DATA_{yyyymmdd}_{hhmmss}.csv
# symbol 可能含點（例如 US500.cash），tf 是純字母數字（M5/H1/H4/D1/M15...）
FILENAME_RE = re.compile(
    r"^(?P<symbol>.+?)_(?P<tf>[A-Z]+\d*)_ALL_DATA_(?P<yyyymmdd>\d{8})_(?P<hhmmss>\d{6})\.csv$",
    re.I
)


def read_csv_any_encoding(path: Path):
    for enc in ["utf-8-sig", "utf-8", "big5", "cp950"]:
        try:
            return pd.read_csv(path, encoding=enc)
        except Exception:
            continue
    return None


def normalize_columns(df: pd.DataFrame):
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
    df = df.dropna(subset=["datetime"])
    return df


def group_files_by_symbol_tf():
    groups = defaultdict(list)
    for f in SOURCE_FOLDER.glob("*_ALL_DATA_*.csv"):
        m = FILENAME_RE.match(f.name)
        if not m:
            continue
        key = (m.group("symbol"), m.group("tf").upper())
        ts = m.group("yyyymmdd") + m.group("hhmmss")
        groups[key].append((ts, f))
    return groups


def merge_one(symbol: str, tf: str, files: list):
    # 按檔名時間戳記排序（舊到新），後面讀進來的重複K棒會覆蓋前面的，
    # 等於「同一根K棒以較新一次匯出的數值為準」
    files_sorted = sorted(files, key=lambda x: x[0])

    frames = []
    for _, path in files_sorted:
        df = read_csv_any_encoding(path)
        if df is None:
            print(f"  [跳過] 讀取失敗: {path.name}")
            continue
        df = normalize_columns(df)
        if df is None:
            print(f"  [跳過] 找不到日期欄: {path.name}")
            continue
        frames.append(df)

    if not frames:
        print(f"  {symbol} {tf}: 沒有任何可用資料，跳過")
        return

    merged = pd.concat(frames, ignore_index=True)
    # 同一根K棒（相同datetime）如果在多份快照裡重複出現，保留最後一次
    # concat 進來的那筆（因為 files_sorted 是舊到新，keep="last" 就是最新版本）
    merged = merged.sort_values("datetime")
    merged = merged.drop_duplicates(subset="datetime", keep="last")
    merged = merged.sort_values("datetime").reset_index(drop=True)

    out_path = MERGED_FOLDER / f"{symbol}_{tf}_MERGED_ALL_DATA.csv"
    merged.to_csv(out_path, index=False, encoding="utf-8-sig")
    print(f"  {symbol} {tf}: 合併 {len(files_sorted)} 份快照 -> {len(merged)} 根K棒 -> {out_path.name}")


def main():
    if not SOURCE_FOLDER.exists():
        print(f"找不到資料夾: {SOURCE_FOLDER}")
        return

    groups = group_files_by_symbol_tf()
    if not groups:
        print(f"{SOURCE_FOLDER} 裡沒有符合命名規則的匯出檔案（{{symbol}}_{{tf}}_ALL_DATA_{{時間戳記}}.csv）")
        return

    print(f"掃描到 {len(groups)} 組 商品/週期 組合，開始合併（原始檔案不會被刪除或搬動）...")
    for (symbol, tf), files in sorted(groups.items()):
        print(f"處理 {symbol} {tf}（{len(files)} 份快照）...")
        merge_one(symbol, tf, files)

    print(f"\n全部完成，合併結果都在 {MERGED_FOLDER}")


if __name__ == "__main__":
    main()
