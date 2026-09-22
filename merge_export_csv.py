# merge_export_csv.py
# 把 D:\資料查詢\ExportCSV 底下同一個 商品+週期 的所有匯出快照
# （檔名格式：{symbol}_{tf}_ALL_DATA_{yyyymmdd}_{hhmmss}.csv）合併成
# 一份連續、去重、按時間排序的完整資料庫，寫到 merged 子資料夾。
#
# 預設不會刪除或搬動任何原始匯出檔。只有明確加上 --delete-source 參數，
# 才會在「確認合併檔案寫入成功且有資料」之後，刪除該組已經被合併進去的
# 原始快照檔（絕對不會刪除 merged 資料夾或合併後的檔案本身），並且執行前
# 還會再跳出一次文字確認，避免手滑。
#
# 用法：
#   python merge_export_csv.py                  只合併，不刪除任何原始檔（預設、安全）
#   python merge_export_csv.py --delete-source   合併後刪除已成功合併的原始快照，釋放硬碟空間
import argparse
import pandas as pd
from pathlib import Path
import re
from collections import defaultdict

SOURCE_FOLDER = Path(r"D:\整合計畫\整理後\ExportCSV")
MERGED_FOLDER = SOURCE_FOLDER / "merged"
# parents=True：ExportCSV 本身還沒被匯出巨集建出來時（例如全新環境、
# 還沒跑過批次匯出就先跑這支腳本），一次把中間缺的資料夾都補上，
# 不會因為上層資料夾不存在就丟 FileNotFoundError。
MERGED_FOLDER.mkdir(parents=True, exist_ok=True)

# 檔名格式：{symbol}_{tf}_ALL_DATA_{yyyymmdd}_{hhmmss}.csv
# symbol 可能含點（例如 US500.cash），tf 是純字母數字（M5/H1/H4/D1/M15...）
FILENAME_RE = re.compile(
    r"^(?P<symbol>.+?)_(?P<tf>[A-Z]+\d*)_ALL_DATA_(?P<yyyymmdd>\d{8})_(?P<hhmmss>\d{6})\.csv$",
    re.I
)

MERGED_FILENAME_RE = re.compile(
    r"^(?P<symbol>.+)_(?P<tf>[A-Z]+\d*)_MERGED_ALL_DATA\.csv$",
    re.I
)

# 增量狀態檔：記錄每個 商品/週期 在 merged 資料庫裡目前最新一根K棒的時間，
# 給 GDH_BatchExportSelected 讀取，決定該商品/週期用 --since 只抓新資料，
# 還是（資料庫裡還沒有時）走整批回補。
STATE_FILE = "_last_bar_state.csv"


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


def read_last_datetime(path: Path):
    """有效率地只讀檔案結尾一小段，取得最後一行的日期時間，不用整份載入記憶體。"""
    try:
        with open(path, "rb") as f:
            f.seek(0, 2)
            filesize = f.tell()
            chunk_size = min(8192, filesize)
            f.seek(-chunk_size, 2)
            tail = f.read().decode("utf-8-sig", errors="ignore")
        lines = [l for l in tail.splitlines() if l.strip()]
        if not lines:
            return None
        last_line = lines[-1]
        first_field = last_line.split(",")[0]
        dt = pd.to_datetime(first_field, errors="coerce")
        if pd.isna(dt):
            return None
        return dt
    except OSError:
        return None


def write_last_bar_state():
    """掃描 merged 資料夾裡目前所有合併檔（不限這次執行有沒有更新到），
    寫出每個 商品/週期 目前資料庫最新K棒時間，供匯出巨集判斷要不要用 --since。"""
    rows = []
    for f in MERGED_FOLDER.glob("*_MERGED_ALL_DATA.csv"):
        m = MERGED_FILENAME_RE.match(f.name)
        if not m:
            continue
        dt = read_last_datetime(f)
        if dt is None:
            continue
        rows.append({
            "Symbol": m.group("symbol"),
            "TF": m.group("tf").upper(),
            "LastDateTime": dt.strftime("%Y-%m-%d %H:%M:%S"),
        })

    state_path = MERGED_FOLDER / STATE_FILE
    pd.DataFrame(rows, columns=["Symbol", "TF", "LastDateTime"]).to_csv(
        state_path, index=False, encoding="utf-8-sig"
    )
    print(f"\n已更新增量狀態檔（{len(rows)} 組）: {state_path}")


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


def merge_one(symbol: str, tf: str, files: list, delete_source: bool):
    # 按檔名時間戳記排序（舊到新），後面讀進來的重複K棒會覆蓋前面的，
    # 等於「同一根K棒以較新一次匯出的數值為準」
    files_sorted = sorted(files, key=lambda x: x[0])

    frames = []
    usable_paths = []
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
        usable_paths.append(path)

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
    try:
        merged.to_csv(out_path, index=False, encoding="utf-8-sig")
    except PermissionError:
        # 最常見原因：這個檔案目前在 Excel 或其他程式裡開著被鎖住了。
        # 跳過這一組，繼續處理其他商品/週期，不要讓整支腳本中斷掉。
        print(f"  [寫入失敗-權限被拒] {symbol} {tf}: {out_path.name} 可能正被 Excel 或其他程式開著，先關掉再重跑。已跳過此組。")
        return
    except OSError as e:
        print(f"  [寫入失敗] {symbol} {tf}: {out_path.name} - {e}。已跳過此組。")
        return
    print(f"  {symbol} {tf}: 合併 {len(files_sorted)} 份快照 -> {len(merged)} 根K棒 -> {out_path.name}")

    if not delete_source:
        return

    # 刪除前再次確認合併檔案真的寫成功、而且有資料，才刪對應的原始快照。
    # 只刪這一組「已經成功讀進 merged 檔案」的來源檔，讀取失敗被跳過的
    # 檔案不會被刪（留著方便你事後排查為什麼讀不到）。
    if not out_path.exists() or out_path.stat().st_size == 0 or len(merged) == 0:
        print(f"  [安全跳過刪除] {symbol} {tf}: 合併檔案看起來不對勁，保留全部原始快照")
        return

    freed_bytes = 0
    deleted = 0
    for path in usable_paths:
        try:
            freed_bytes += path.stat().st_size
            path.unlink()
            deleted += 1
        except OSError as e:
            print(f"  [刪除失敗] {path.name}: {e}")

    print(f"  {symbol} {tf}: 已刪除 {deleted} 份原始快照，釋放約 {freed_bytes/1024/1024:.1f} MB")


def main():
    parser = argparse.ArgumentParser(description="合併 ExportCSV 匯出快照")
    parser.add_argument(
        "--delete-source", action="store_true",
        help="合併成功後刪除已合併的原始快照檔（預設不刪）"
    )
    parser.add_argument(
        "--yes", action="store_true",
        help="搭配 --delete-source 使用，跳過刪除前的文字確認（自動化執行用）"
    )
    args = parser.parse_args()

    if not SOURCE_FOLDER.exists():
        print(f"找不到資料夾: {SOURCE_FOLDER}")
        return

    groups = group_files_by_symbol_tf()
    if not groups:
        print(f"{SOURCE_FOLDER} 裡沒有符合命名規則的匯出檔案（{{symbol}}_{{tf}}_ALL_DATA_{{時間戳記}}.csv）")
        # 就算這次沒有新快照可合併，merged 資料夾裡的舊資料還是有效的，
        # 照樣把增量狀態檔寫出來，供匯出巨集使用。
        write_last_bar_state()
        return

    delete_source = args.delete_source
    if delete_source and not args.yes:
        total_files = sum(len(f) for f in groups.values())
        confirm = input(
            f"即將在合併成功後刪除 {total_files} 份原始快照檔（merged 資料夾跟合併結果不會動）。"
            f"確定嗎？輸入 yes 繼續，其他任意鍵取消刪除（仍會照常合併）: "
        )
        if confirm.strip().lower() != "yes":
            print("已取消刪除，僅執行合併。")
            delete_source = False

    action_desc = "合併並刪除已合併的原始快照" if delete_source else "合併（原始檔案不會被刪除或搬動）"
    print(f"掃描到 {len(groups)} 組 商品/週期 組合，開始{action_desc}...")
    for (symbol, tf), files in sorted(groups.items()):
        print(f"處理 {symbol} {tf}（{len(files)} 份快照）...")
        merge_one(symbol, tf, files, delete_source)

    write_last_bar_state()
    print(f"\n全部完成，合併結果都在 {MERGED_FOLDER}")


if __name__ == "__main__":
    main()
