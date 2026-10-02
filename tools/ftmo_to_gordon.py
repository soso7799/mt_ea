#!/usr/bin/env python3
"""
把 HistoryExporter 匯出的 FTMO 資料轉成 Gordon_FTMO_Data_Console 的 merged 格式，
讓 update_all_data.py / 儀表板不用改就能直接使用（取代 Excel 一組一組呼叫 Python 匯出）。

來源：FTMO_Data\\<週期>\\<商品>.csv     <DATE>,<TIME>,<OPEN>,<HIGH>,<LOW>,<CLOSE>,<TICKVOL>,<SPREAD>
輸出：<out>\\<商品>_<週期>_MERGED_ALL_DATA.csv   日期,開,高,低,收,成交量（utf-8-sig，日期 yyyy-mm-dd hh:mm:ss）
      <out>\\_last_bar_state.csv                 Symbol,TF,LastDateTime（與 merge_export_csv.py 相同）

只附加比輸出檔最後一根更新的K棒，每天跑也很快。只需 Python，不用安裝套件。

用法：
  python ftmo_to_gordon.py
  python ftmo_to_gordon.py --data "H:\\我的雲端硬碟\\FTMO_Data" --out "D:\\整合計畫\\整理後\\ExportCSV\\merged"
  python ftmo_to_gordon.py --tfs M5,M15,H1,H4,D1 --symbols EURUSD,US500.cash
"""
import argparse
import os
import sys

HEADER = "日期,開,高,低,收,成交量\n"


def last_datetime(path):
    """讀檔尾最後一行的日期（yyyy-mm-dd hh:mm:ss），沒有就回傳空字串"""
    try:
        with open(path, "rb") as f:
            f.seek(0, 2)
            size = f.tell()
            f.seek(max(0, size - 4096))
            tail = f.read().decode("utf-8-sig", errors="ignore")
    except OSError:
        return ""
    for line in reversed(tail.splitlines()):
        first = line.split(",")[0].strip()
        if len(first) >= 16 and first[0].isdigit():
            return first if len(first) == 19 else first[:16] + ":00"
    return ""


def convert(src, dst):
    """回傳 (新增筆數, 最後日期)"""
    last = last_datetime(dst) if os.path.exists(dst) else ""
    out = []
    newest = last
    with open(src, encoding="ascii", errors="ignore") as f:
        for line in f:
            if not line or line[0] == "<":
                continue
            c = line.rstrip("\r\n").split(",")
            if len(c) < 7:
                continue
            dt = c[0].replace(".", "-") + " " + c[1] + ":00"
            if dt <= last:                      # 同格式字串可直接比大小
                continue
            out.append(f"{dt},{c[2]},{c[3]},{c[4]},{c[5]},{c[6]}\n")
            newest = dt
    if out:
        new_file = not os.path.exists(dst) or os.path.getsize(dst) == 0
        with open(dst, "a", encoding="utf-8-sig" if new_file else "utf-8", newline="") as f:
            if new_file:
                f.write(HEADER)
            f.writelines(out)
    return len(out), newest


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    appdata = os.environ.get("APPDATA", "")
    ap.add_argument("--data", default=os.path.join(appdata, "MetaQuotes", "Terminal", "Common", "Files", "FTMO_Data"))
    ap.add_argument("--out", default=r"D:\整合計畫\整理後\ExportCSV\merged")
    ap.add_argument("--tfs", default="", help="只轉這些週期（逗號分隔，空白 = 全部）")
    ap.add_argument("--symbols", default="", help="只轉這些商品（逗號分隔，空白 = 全部）")
    a = ap.parse_args()

    if not os.path.isdir(a.data):
        sys.exit(f"找不到 {a.data}（HistoryExporter 還沒匯出？）")
    os.makedirs(a.out, exist_ok=True)
    want_tf = {t.strip().upper() for t in a.tfs.split(",") if t.strip()}
    want_sym = {s.strip() for s in a.symbols.split(",") if s.strip()}

    state = {}
    total_new = files = 0
    for tf in sorted(os.listdir(a.data)):
        tdir = os.path.join(a.data, tf)
        if not os.path.isdir(tdir) or (want_tf and tf.upper() not in want_tf):
            continue
        for name in sorted(os.listdir(tdir)):
            if not name.endswith(".csv"):
                continue
            sym = name[:-4]
            if want_sym and sym not in want_sym:
                continue
            dst = os.path.join(a.out, f"{sym}_{tf}_MERGED_ALL_DATA.csv")
            n, newest = convert(os.path.join(tdir, name), dst)
            files += 1
            total_new += n
            if newest:
                state[(sym, tf)] = newest
            if n:
                print(f"  {sym:<14} {tf:<4} +{n}")

    # 增量狀態檔：保留 merged 裡其他（非本工具產生）的組合
    state_path = os.path.join(a.out, "_last_bar_state.csv")
    for fn in os.listdir(a.out):
        if fn.endswith("_MERGED_ALL_DATA.csv"):
            sym, tf = fn[:-len("_MERGED_ALL_DATA.csv")].rsplit("_", 1)
            if (sym, tf) not in state:
                dt = last_datetime(os.path.join(a.out, fn))
                if dt:
                    state[(sym, tf)] = dt
    with open(state_path, "w", encoding="utf-8-sig", newline="") as f:
        f.write("Symbol,TF,LastDateTime\n")
        for (sym, tf), dt in sorted(state.items()):
            f.write(f"{sym},{tf},{dt}\n")

    print(f"完成：{files} 個檔案，新增 {total_new} 根K棒 → {a.out}")


if __name__ == "__main__":
    main()
