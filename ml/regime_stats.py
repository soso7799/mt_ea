#!/usr/bin/env python3
"""
統計 MultiCurrency_EA 每小時「市場行情判定 + 斐波止損止盈」的成效

資料來源：EA 寫出的 CSV
  %APPDATA%\\MetaQuotes\\Terminal\\Common\\Files\\MarketRegime\\MultiCurrency_<magic>_<tester|live>.csv
  （EA 參數 Inp_MR_CSV=true；回測或實盤跑一段時間即可）

用法
  python regime_stats.py                 自動找上面資料夾裡所有 CSV
  python regime_stats.py 檔案.csv ...     指定檔案
  選項：--max-bars 48   斐波止損止盈最多追蹤幾根K棒（預設 48 = 兩天 H1）
        --symbol USDJPY 只統計某個商品

統計內容
  1. 行情判定準確度：判定為 多頭/空頭/盤整 之後 1/4/24 根K棒的價格變化（以 ATR 為單位）
     與方向命中率（多頭之後上漲、空頭之後下跌的比例）
  2. 斐波止損止盈模擬：以判定當根收盤價進場，用之後每根K棒的高低點判斷先碰到止盈還是止損
     （同一根同時碰到兩者時保守算止損；逾時以收盤損益計），依 方向×行情 分組，
     報告筆數、勝率、平均報酬(R)、總報酬(R)，並比較「順勢」與「逆勢」
  3. 依斐波區間（黃金買區/空區…）分組的模擬結果
  4. RSI3/6 乖離訊號之後的價格表現

注意：這是用每小時資料的近似模擬，未含點差與滑價；結果僅供判斷規則是否有優勢。
"""
import argparse
import csv
import glob
import io
import os
import sys
from collections import defaultdict

HORIZONS = (1, 4, 24)

GROUP_NAMES = {"major": "主要貨幣", "cross": "交叉貨幣", "exotic": "異國貨幣", "metal": "金屬",
               "energy": "能源", "index": "指數", "agri": "農產品", "crypto": "加密貨幣", "other": "其他"}
GROUP_ORDER = list(GROUP_NAMES)


def group_of(r):
    return (r.get("group") or "other").strip() or "other"


def default_dir():
    appdata = os.environ.get("APPDATA", "")
    return os.path.join(appdata, "MetaQuotes", "Terminal", "Common", "Files", "MarketRegime")


def fnum(v, default=0.0):
    try:
        return float(v)
    except (TypeError, ValueError):
        return default


def load(paths, only_symbol=None):
    by_sym = defaultdict(list)
    for p in paths:
        # EA 以 ANSI 寫出：繁中 Windows = cp950(Big5)、簡中 = gbk；都失敗才用 latin-1
        raw = open(p, "rb").read()
        text = None
        for enc in ("utf-8-sig", "cp950", "gbk", "latin-1"):
            try:
                text = raw.decode(enc)
                break
            except UnicodeDecodeError:
                continue
        with io.StringIO(text, newline="") as f:
            rd = csv.DictReader(f)
            for r in rd:
                if not r.get("symbol") or not r.get("close"):
                    continue
                if only_symbol and r["symbol"].upper() != only_symbol.upper():
                    continue
                by_sym[r["symbol"]].append(r)
    # 同一商品依時間排序並去掉重複時間（實盤重啟可能重寫同一根）
    for s, rows in by_sym.items():
        seen = {}
        for r in rows:
            seen[r["time"]] = r
        by_sym[s] = [seen[k] for k in sorted(seen)]
    return by_sym


def regime_name(r):
    # CSV 以 ANSI 寫出，中文在不同系統可能變成亂碼，改用分數判斷
    sc = int(fnum(r.get("score"), 0))
    return "多頭" if sc >= 3 else ("空頭" if sc <= -3 else "盤整")


class Acc:
    def __init__(self):
        self.n = 0
        self.wins = 0
        self.sum_r = 0.0

    def add(self, r):
        self.n += 1
        self.sum_r += r
        if r > 0:
            self.wins += 1

    def row(self, label):
        if self.n == 0:
            return f"  {label:<22}{0:>6}"
        return (f"  {label:<22}{self.n:>6}  勝率 {100.0*self.wins/self.n:5.1f}%  "
                f"平均 {self.sum_r/self.n:+.3f}R  總計 {self.sum_r:+8.2f}R")


def simulate(rows, i, direction, max_bars):
    """回傳 R 倍數；資料不足回傳 None"""
    r = rows[i]
    entry = fnum(r["close"])
    if direction > 0:
        sl, tp = fnum(r.get("long_sl")), fnum(r.get("long_tp"))
    else:
        sl, tp = fnum(r.get("short_sl")), fnum(r.get("short_tp"))
    if sl <= 0 or tp <= 0:
        return None
    risk = abs(entry - sl)
    if risk <= 0:
        return None

    last = None
    for j in range(i + 1, min(i + 1 + max_bars, len(rows))):
        hi, lo = fnum(rows[j].get("high")), fnum(rows[j].get("low"))
        if hi <= 0 or lo <= 0:  # 舊版 CSV 沒有高低點，退回用收盤
            hi = lo = fnum(rows[j]["close"])
        if direction > 0:
            hit_sl, hit_tp = lo <= sl, hi >= tp
        else:
            hit_sl, hit_tp = hi >= sl, lo <= tp
        if hit_sl:
            return -1.0
        if hit_tp:
            return abs(tp - entry) / risk
        last = fnum(rows[j]["close"])
    if last is None:
        return None
    if i + max_bars >= len(rows):  # 還沒走完追蹤期間，不計入
        return None
    return (last - entry) * direction / risk


def main():
    ap = argparse.ArgumentParser(description="統計每小時行情判定與斐波止損止盈成效")
    ap.add_argument("files", nargs="*")
    ap.add_argument("--max-bars", type=int, default=48)
    ap.add_argument("--symbol", default=None)
    a = ap.parse_args()

    files = a.files or sorted(glob.glob(os.path.join(default_dir(), "*.csv")))
    if not files:
        print("找不到 CSV。請指定檔案，或確認 EA 已開啟 Inp_MR_CSV 並跑過一段時間：")
        print("  " + default_dir())
        sys.exit(1)

    data = load(files, a.symbol)
    total = sum(len(v) for v in data.values())
    print(f"讀取 {len(files)} 個檔案，{len(data)} 個商品，共 {total} 筆每小時判定\n")
    if total == 0:
        sys.exit(1)

    # ---------- 1. 行情判定準確度 ----------
    print("=" * 78)
    print("1. 行情判定之後的價格變化（ATR 為單位；命中 = 多頭後上漲 / 空頭後下跌）")
    print("=" * 78)
    fwd = {h: defaultdict(list) for h in HORIZONS}
    for rows in data.values():
        for i, r in enumerate(rows):
            atr = fnum(r.get("atr"))
            if atr <= 0:
                atr = max(fnum(r.get("high")) - fnum(r.get("low")), 1e-9)
            c0 = fnum(r["close"])
            for h in HORIZONS:
                if i + h < len(rows):
                    fwd[h][regime_name(r)].append((fnum(rows[i + h]["close"]) - c0) / atr)
    for h in HORIZONS:
        print(f"\n  {h} 根K棒後：")
        for reg in ("多頭", "盤整", "空頭"):
            v = fwd[h][reg]
            if not v:
                print(f"    {reg}  {0:>6} 筆")
                continue
            mean = sum(v) / len(v)
            up = 100.0 * sum(1 for x in v if x > 0) / len(v)
            hit = up if reg == "多頭" else (100.0 - up if reg == "空頭" else float("nan"))
            hit_s = f"命中 {hit:5.1f}%" if reg != "盤整" else f"上漲 {up:5.1f}%"
            print(f"    {reg}  {len(v):>6} 筆  平均 {mean:+.3f} ATR  {hit_s}")

    # ---------- 2. 斐波止損止盈模擬 ----------
    print("\n" + "=" * 78)
    print(f"2. 斐波止損止盈模擬（收盤進場，最多追蹤 {a.max_bars} 根K棒）")
    print("=" * 78)
    by_group = defaultdict(Acc)
    by_zone = defaultdict(Acc)
    aligned, counter, all_long, all_short = Acc(), Acc(), Acc(), Acc()
    grp_all, grp_aligned, grp_counter = defaultdict(Acc), defaultdict(Acc), defaultdict(Acc)
    for rows in data.values():
        for i, r in enumerate(rows):
            reg = regime_name(r)
            for d, name in ((1, "多單"), (-1, "空單")):
                res = simulate(rows, i, d, a.max_bars)
                if res is None:
                    continue
                by_group[(name, reg)].add(res)
                (all_long if d > 0 else all_short).add(res)
                g = group_of(r)
                grp_all[g].add(res)
                if (reg == "多頭" and d > 0) or (reg == "空頭" and d < 0):
                    aligned.add(res)
                    grp_aligned[g].add(res)
                elif reg != "盤整":
                    counter.add(res)
                    grp_counter[g].add(res)
                zone = r.get("fib_zone", "")
                by_zone[(name, zone)].add(res)

    print(all_long.row("全部多單"))
    print(all_short.row("全部空單"))
    print()
    for name in ("多單", "空單"):
        for reg in ("多頭", "盤整", "空頭"):
            print(by_group[(name, reg)].row(f"{name} @ {reg}"))
    print()
    print(aligned.row("順勢（多頭做多/空頭做空）"))
    print(counter.row("逆勢（多頭做空/空頭做多）"))

    # ---------- 3. 依斐波區間 ----------
    print("\n" + "=" * 78)
    print("3. 依斐波區間分組（只列 20 筆以上）")
    print("=" * 78)
    for (name, zone), acc in sorted(by_zone.items(), key=lambda kv: (kv[0][0], -kv[1].n)):
        if acc.n >= 20:
            print(acc.row(f"{name} {zone}"[:22]))

    # ---------- 4. RSI 乖離訊號 ----------
    print("\n" + "=" * 78)
    print("4. RSI3/6 乖離訊號之後的價格變化（ATR 為單位，已乘上訊號方向：正值 = 訊號正確）")
    print("=" * 78)
    for sig, label in ((1, "負乖離過大→多"), (-1, "正乖離過大→空")):
        for h in (4, 24):
            v = []
            for rows in data.values():
                for i, r in enumerate(rows):
                    if int(fnum(r.get("rsi_signal"), 0)) != sig or i + h >= len(rows):
                        continue
                    atr = fnum(r.get("atr")) or 1e-9
                    v.append((fnum(rows[i + h]["close"]) - fnum(r["close"])) / atr * sig)
            if v:
                ok = 100.0 * sum(1 for x in v if x > 0) / len(v)
                print(f"  {label}  {h:>2} 根後  {len(v):>5} 筆  平均 {sum(v)/len(v):+.3f} ATR  正確 {ok:5.1f}%")
            else:
                print(f"  {label}  {h:>2} 根後      0 筆")

    # ---------- 5. 依商品分組 ----------
    print("\n" + "=" * 78)
    print("5. 依商品分組（主要貨幣 / 交叉貨幣 / 異國貨幣 / 金屬 / 能源 / 指數 / 農產品 / 加密）")
    print("=" * 78)
    counts = defaultdict(int)
    syms = defaultdict(set)
    for s_, rows in data.items():
        for r in rows:
            counts[group_of(r)] += 1
            syms[group_of(r)].add(s_)
    for g in GROUP_ORDER + sorted(k for k in counts if k not in GROUP_ORDER):
        if counts.get(g, 0) == 0:
            continue
        name = GROUP_NAMES.get(g, g)
        print(f"\n  【{name}】 {counts[g]} 筆判定  商品：{', '.join(sorted(syms[g]))}")
        print("  " + grp_all[g].row("全部斐波模擬").strip())
        print("  " + grp_aligned[g].row("順勢").strip())
        print("  " + grp_counter[g].row("逆勢").strip())

    print("\n說明：平均報酬 > 0R 且筆數夠多（建議 >100）的組合才代表有優勢；")
    print("      若「順勢」明顯優於「逆勢」，可把 Inp_MR_Mode 改為 順勢 過濾。")


if __name__ == "__main__":
    main()
