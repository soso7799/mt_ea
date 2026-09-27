"""
每 30 分鐘監視所有商品：最近 3 根 K 線同方向（不反轉）就列入工作表

每根 M30 收盤後幾秒掃描一次 MT5「市場報價」中顯示的所有商品（或 --symbols 指定）：
  最近 3 根已收盤 K 都是陽線 → 做多訊號；都是陰線 → 做空訊號（剛形成 = 再前一根不是同色）
  建議停損 = 2 ATR(14)（同回測 A），出場 = 出現第一根反向 K 收盤
寫入 Excel（reports\\連續K監視.xlsx）：
  『目前訊號』：本次掃描所有有訊號的商品（含是否剛形成、進場參考價、停損價、該商品回測平均R）
  『訊號紀錄』：每次掃描新形成的訊號，一直累加
Excel 開著時無法寫入，會改寫到 連續K監視_時間.xlsx，並在畫面提示。
只列訊號、不下單。

用法：python monitor_streak.py --out H:\\...\\reports [--tf M30] [--once] [--symbols ...]
"""
import argparse
import datetime as dt
import glob
import os
import time

import numpy as np
import pandas as pd

TFMAP = {"M15": 15, "M30": 30, "H1": 60}


def atr14(h, l, c):
    pc = np.r_[c[0], c[:-1]]
    tr = np.maximum(h - l, np.maximum(abs(h - pc), abs(l - pc)))
    return pd.Series(tr).ewm(alpha=1 / 14, adjust=False).mean().to_numpy()


def backtest_table(out_dir, tf):
    files = sorted(glob.glob(os.path.join(out_dir, f"連續K回測_{tf}_各商品_latest.csv")))
    if not files:
        return {}
    P = pd.read_csv(files[-1])
    P = P[(P["出場"].str.startswith("A")) & (P["方向"] == "順勢做")]
    return {r["商品"]: (r["平均R"], r["前半平均R"], r["後半平均R"]) for _, r in P.iterrows()}


def scan(mt5, symbols, tf_const, k, bt):
    rows = []
    for s in symbols:
        r = mt5.copy_rates_from_pos(s, tf_const, 1, 60)           # 從第 1 根起 = 只取已收盤 K
        if r is None or len(r) < k + 20:
            continue
        df = pd.DataFrame(r)
        o, h, l, c = (df[x].to_numpy(float) for x in ("open", "high", "low", "close"))
        a = atr14(h, l, c)[-1]
        last = c[-k:] - o[-k:]
        prev = c[-k - 1] - o[-k - 1]
        if (last > 0).all():
            d, fresh = 1, not prev > 0
        elif (last < 0).all():
            d, fresh = -1, not prev < 0
        else:
            continue
        run = k
        while run < len(c) and ((c[-run - 1] - o[-run - 1]) * d > 0):
            run += 1
        info = mt5.symbol_info(s)
        tick = mt5.symbol_info_tick(s)
        px = (tick.ask if d > 0 else tick.bid) if tick else c[-1]
        digits = info.digits if info else 5
        b = bt.get(s)
        rows.append(dict(
            掃描時間=dt.datetime.now().replace(microsecond=0),
            K線收盤=pd.to_datetime(df["time"].iloc[-1], unit="s") + pd.Timedelta(minutes=0),
            商品=s, 方向="做多" if d > 0 else "做空", 剛形成="是" if fresh else f"否（已連續 {run} 根）",
            進場參考價=round(px, digits), 建議停損=round(px - d * 2 * a, digits), ATR=round(a, digits),
            出場規則="出現第一根反向 K 收盤",
            回測平均R=(round(b[0], 3) if b else None),
            回測前半R=(round(b[1], 3) if b else None), 回測後半R=(round(b[2], 3) if b else None)))
    return pd.DataFrame(rows)


def write(path, cur, log):
    try:
        with pd.ExcelWriter(path, engine="openpyxl") as xw:
            cur.to_excel(xw, sheet_name="目前訊號", index=False)
            log.to_excel(xw, sheet_name="訊號紀錄", index=False)
            for ws in xw.sheets.values():
                for col in ws.columns:
                    w = max(len(str(x.value or "")) for x in col[:200])
                    ws.column_dimensions[col[0].column_letter].width = min(max(9, w * 1.3), 40)
                ws.freeze_panes = "A2"
        return path
    except PermissionError:
        alt = path.replace(".xlsx", f"_{dt.datetime.now():%Y%m%d_%H%M}.xlsx")
        write(alt, cur, log)
        print(f"  ⚠️ {os.path.basename(path)} 正被 Excel 開啟，這次改寫到 {os.path.basename(alt)}")
        return alt


def main():
    ap = argparse.ArgumentParser(description="每 30 分鐘監視所有商品的連續 K")
    ap.add_argument("--out", required=True)
    ap.add_argument("--terminal", default=None)
    ap.add_argument("--symbols", nargs="*", default=None)
    ap.add_argument("--tf", default="M30", choices=list(TFMAP))
    ap.add_argument("--bars", type=int, default=3, help="連續幾根（預設 3）")
    ap.add_argument("--once", action="store_true", help="只掃描一次")
    args = ap.parse_args()

    import MetaTrader5 as mt5
    if not (mt5.initialize(path=args.terminal) if args.terminal else mt5.initialize()):
        raise SystemExit(f"[錯誤] 無法連線 MT5：{mt5.last_error()}。請先開啟並登入 MT5。")
    tfc = {"M15": mt5.TIMEFRAME_M15, "M30": mt5.TIMEFRAME_M30, "H1": mt5.TIMEFRAME_H1}[args.tf]
    os.makedirs(args.out, exist_ok=True)
    path = os.path.join(args.out, "連續K監視.xlsx")
    log = pd.read_excel(path, sheet_name="訊號紀錄") if os.path.exists(path) else pd.DataFrame()
    mins = TFMAP[args.tf]
    try:
        while True:
            syms = args.symbols or [s.name for s in (mt5.symbols_get() or []) if s.visible]
            bt = backtest_table(args.out, args.tf)
            cur = scan(mt5, syms, tfc, args.bars, bt)
            new = cur[cur["剛形成"] == "是"] if len(cur) else cur
            log = pd.concat([log, new], ignore_index=True) if len(new) else log
            used = write(path, cur, log)
            now = dt.datetime.now().strftime("%H:%M:%S")
            print(f"[{now}] 掃描 {len(syms)} 個商品：{len(cur)} 個連續 {args.bars} 根同向，剛形成 {len(new)} 個 → {used}")
            for _, r in new.iterrows():
                print(f"    {r['商品']:<12} {r['方向']}  參考價 {r['進場參考價']}  停損 {r['建議停損']}  回測平均R {r['回測平均R']}")
            if args.once:
                break
            # 等到下一根 K 收盤後 10 秒（以伺服器時間對齊：用最新 K 線開盤時間推算）
            r = mt5.copy_rates_from_pos(syms[0], tfc, 0, 1) if syms else None
            srv_open = int(r[0]["time"]) if r is not None and len(r) else None
            tick = mt5.symbol_info_tick(syms[0]) if syms else None
            if srv_open and tick:
                wait = srv_open + mins * 60 - tick.time + 10
                wait = wait if 0 < wait <= mins * 60 + 10 else mins * 60
            else:
                wait = mins * 60
            time.sleep(wait)
    except KeyboardInterrupt:
        print("已停止")
    finally:
        mt5.shutdown()


if __name__ == "__main__":
    main()
