"""
雲端硬碟（或任何磁碟）盤點：列出所有資料夾與檔案，找出大檔、重複檔、空資料夾、舊檔
只讀取檔名 / 大小 / 日期（不開檔、不會觸發 Google Drive 下載），不修改任何東西。

輸出（--out 資料夾）：
  <磁碟>_盤點_日期.xlsx：總覽、各資料夾、副檔名、大檔前200、疑似重複（同名同大小）、空資料夾、全部檔案（前 50000 筆）
  <磁碟>_盤點_日期.csv ：全部檔案清單

用法：python drive_inventory.py G:\\ --out H:\\我的雲端硬碟\\reports
"""
import argparse
import datetime as dt
import os
import sys

import pandas as pd

SKIP = {"$RECYCLE.BIN", "System Volume Information", ".tmp.drivedownload", ".tmp.driveupload"}


def main():
    ap = argparse.ArgumentParser(description="磁碟盤點（唯讀）")
    ap.add_argument("root")
    ap.add_argument("--out", required=True)
    ap.add_argument("--max-depth", type=int, default=12)
    args = ap.parse_args()
    root = os.path.abspath(args.root)
    files, dirs = [], []
    n = 0
    for cur, dnames, fnames in os.walk(root, onerror=lambda e: print(f"  ⚠️ 無法讀取：{e.filename}")):
        dnames[:] = [d for d in dnames if d not in SKIP]
        rel = os.path.relpath(cur, root)
        depth = 0 if rel == "." else rel.count(os.sep) + 1
        if depth > args.max_depth:
            dnames[:] = []
            continue
        dirs.append(dict(資料夾=rel, 層級=depth, 子資料夾數=len(dnames), 檔案數=len(fnames)))
        for f in fnames:
            p = os.path.join(cur, f)
            try:
                st = os.stat(p)
            except OSError:
                continue
            files.append(dict(資料夾=rel, 檔名=f, 副檔名=os.path.splitext(f)[1].lower() or "(無)",
                              大小MB=st.st_size / 1048576, 修改時間=dt.datetime.fromtimestamp(st.st_mtime).replace(microsecond=0),
                              頂層=rel.split(os.sep)[0] if rel != "." else "(根目錄)"))
            n += 1
            if n % 5000 == 0:
                print(f"  已掃描 {n} 個檔案 ...")
    F = pd.DataFrame(files)
    D = pd.DataFrame(dirs)
    if not len(F):
        F = pd.DataFrame(columns=["資料夾", "檔名", "副檔名", "大小MB", "修改時間", "頂層"])
    # 各資料夾（含子資料夾）總大小
    agg = []
    for d in D["資料夾"]:
        pre = "" if d == "." else d + os.sep
        m = (F["資料夾"] == d) | F["資料夾"].str.startswith(pre) if pre else pd.Series(True, index=F.index)
        agg.append((F.loc[m, "大小MB"].sum(), int(m.sum()), F.loc[m, "修改時間"].max() if m.any() else pd.NaT))
    D["含子資料夾總MB"] = [a[0] for a in agg]
    D["含子資料夾檔案數"] = [a[1] for a in agg]
    D["最後修改"] = [a[2] for a in agg]
    empty = D[D["含子資料夾檔案數"] == 0]
    top = F.groupby("頂層").agg(檔案數=("檔名", "size"), 總MB=("大小MB", "sum"), 最後修改=("修改時間", "max")).reset_index() \
        .sort_values("總MB", ascending=False)
    ext = F.groupby("副檔名").agg(檔案數=("檔名", "size"), 總MB=("大小MB", "sum")).reset_index().sort_values("總MB", ascending=False)
    dup = F[F.duplicated(["檔名", "大小MB"], keep=False)].sort_values(["檔名", "資料夾"])
    big = F.sort_values("大小MB", ascending=False).head(200)
    now = dt.datetime.now().replace(microsecond=0)
    tag = (os.path.splitdrive(root)[0] or os.path.basename(root)).replace(":", "")
    os.makedirs(args.out, exist_ok=True)
    base = os.path.join(args.out, f"{tag}_盤點_{now:%Y%m%d_%H%M}")
    F.to_csv(base + ".csv", index=False, encoding="utf-8-sig")
    summary = pd.DataFrame({"項目": ["盤點位置", "時間", "檔案數", "資料夾數", "總大小MB", "空資料夾", "疑似重複檔（同名同大小）"],
                            "值": [root, str(now), len(F), len(D), round(F["大小MB"].sum(), 1), len(empty), len(dup)]})
    with pd.ExcelWriter(base + ".xlsx", engine="openpyxl") as xw:
        summary.to_excel(xw, sheet_name="總覽", index=False)
        top.round(2).to_excel(xw, sheet_name="頂層資料夾", index=False)
        D.sort_values("資料夾").round(2).to_excel(xw, sheet_name="各資料夾", index=False)
        ext.round(2).to_excel(xw, sheet_name="副檔名", index=False)
        big.round(2).to_excel(xw, sheet_name="大檔前200", index=False)
        dup.round(3).head(20000).to_excel(xw, sheet_name="疑似重複", index=False)
        empty.to_excel(xw, sheet_name="空資料夾", index=False)
        F.sort_values(["資料夾", "檔名"]).head(50000).round(3).to_excel(xw, sheet_name="全部檔案", index=False)
    print(f"\n完成：{base}.xlsx")
    print(f"  檔案 {len(F)} 個、資料夾 {len(D)} 個、共 {F['大小MB'].sum():,.0f} MB、空資料夾 {len(empty)}、疑似重複 {len(dup)}")
    for _, r in top.head(15).iterrows():
        print(f"    {r['頂層']:<40} {r['檔案數']:>7} 個  {r['總MB']:>10,.1f} MB  最後修改 {r['最後修改']}")


if __name__ == "__main__":
    sys.exit(main())
