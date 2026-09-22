import os
import sys
import time
from datetime import datetime, timedelta
import MetaTrader5 as mt5
import pandas as pd

# 已驗證有效的自動登入設定（來自 mt5_speed_test.py 測試結果）
MT5_LOGIN = 531292442
MT5_SERVER = "FTMO-Server3"

# 用 --since 抓增量資料時，往前多抓這麼多分鐘當緩衝，避免兩次匯出中間剛好
# 卡在K棒還沒收完、或伺服器/本機時間有微小落差導致漏抓一根。多抓到的部分
# 反正 merge_export_csv.py 合併時會用時間戳記去重複，不會造成資料重複累加。
SINCE_OVERLAP_MINUTES = 30


def parse_args():
    import argparse
    parser = argparse.ArgumentParser(description="MT5 Incremental Data Fetcher for Gordon Console")
    parser.add_argument("--db", required=True, help="Database directory path")
    parser.add_argument("--symbol", required=True, help="Trading symbol (e.g., EURUSD, XAUUSD)")
    parser.add_argument("--timeframe", required=True, help="Timeframe (e.g., M15, H1, D1)")
    parser.add_argument("--amount", type=int, help="Amount value（--since 沒給時才需要，用於整批回補）")
    parser.add_argument("--unit", choices=["D", "M", "Y"], help="Unit code: D (Day), M (Month), Y (Year)（--since 沒給時才需要）")
    parser.add_argument("--since", help="只抓這個時間點之後的新資料（格式 yyyy-mm-dd hh:mm:ss）。"
                                          "有給這個參數時 --amount/--unit 會被忽略，做真正的增量更新；"
                                          "沒給則維持整批回補的舊行為。")
    parser.add_argument("--output", required=True, help="Output CSV file path")
    args = parser.parse_args()

    if not args.since and (args.amount is None or not args.unit):
        parser.error("沒有給 --since 時，--amount 和 --unit 是必填的（用於整批回補）")

    return args


def get_mt5_timeframe(tf_str):
    mapping = {
        "M1": mt5.TIMEFRAME_M1,
        "M5": mt5.TIMEFRAME_M5,
        "M15": mt5.TIMEFRAME_M15,
        "M30": mt5.TIMEFRAME_M30,
        "H1": mt5.TIMEFRAME_H1,
        "H4": mt5.TIMEFRAME_H4,
        "D1": mt5.TIMEFRAME_D1,
        "W1": mt5.TIMEFRAME_W1,
        "MN1": mt5.TIMEFRAME_MN1
    }
    return mapping.get(tf_str.upper(), mt5.TIMEFRAME_M15)


def fetch_since(symbol, tf_constant, since_dt: datetime, end_date: datetime):
    """真正的增量抓取：只要 since_dt（含緩衝）之後、到現在為止的K棒。"""
    start_date = since_dt - timedelta(minutes=SINCE_OVERLAP_MINUTES)
    rates = None
    max_retries = 3
    wait_seconds = 2
    for attempt in range(1, max_retries + 1):
        rates = mt5.copy_rates_range(symbol, tf_constant, start_date, end_date)
        if rates is not None:
            break
        print(f"第{attempt}/{max_retries}次嘗試抓取 {symbol} 增量資料失敗，等待{wait_seconds}秒後重試...",
              file=sys.stderr)
        time.sleep(wait_seconds)
    return rates


def fetch_full_backfill(symbol, tf_constant, args):
    """舊行為：整批回補，抓固定天數窗口內、從現在往回數的K棒。"""
    amount = args.amount
    unit = args.unit

    if unit == "D":
        days = amount
    elif unit == "M":
        days = amount * 30
    elif unit == "Y":
        days = amount * 365
    else:
        days = 365

    bars_per_day = {
        "M1": 1440, "M5": 288, "M15": 96, "M30": 48,
        "H1": 24, "H4": 6, "D1": 1, "W1": 1, "MN1": 1,
    }.get(args.timeframe.upper(), 96)
    need_bars = max(int(days * bars_per_day * 1.5), 200)

    rates = None
    max_retries = 3
    wait_seconds = 2
    for attempt in range(1, max_retries + 1):
        rates = mt5.copy_rates_from_pos(symbol, tf_constant, 0, need_bars)
        if rates is not None and len(rates) > 0:
            break
        print(f"第{attempt}/{max_retries}次嘗試抓取 {symbol} 失敗，等待{wait_seconds}秒後重試"
              f"(可能剛加入商品，終端機還在跟伺服器同步)...", file=sys.stderr)
        time.sleep(wait_seconds)
    return rates


def main():
    args = parse_args()

    password = os.environ.get("MT5_PASSWORD")
    if not password:
        print("[錯誤] 找不到環境變數 MT5_PASSWORD，請先設定好再重試"
              "（設定後需重開機或重開Excel才會生效）。", file=sys.stderr)
        sys.exit(3)

    # 自動登入，不依賴終端機當下是否已經是登入狀態，
    # 這樣就算券商端 session 過期，也不會卡住等人工輸入密碼
    if not mt5.initialize(login=MT5_LOGIN, password=password, server=MT5_SERVER, timeout=60000):
        print(f"MT5 自動登入失敗，錯誤代碼: {mt5.last_error()}", file=sys.stderr)
        print(f"請確認 MT5_LOGIN={MT5_LOGIN} / MT5_SERVER={MT5_SERVER} 是否正確，"
              f"以及環境變數 MT5_PASSWORD 是否為正確密碼。", file=sys.stderr)
        sys.exit(1)

    symbol = args.symbol
    tf_constant = get_mt5_timeframe(args.timeframe)

    if not mt5.symbol_select(symbol, True):
        print(f"警告：無法選取商品 {symbol}，錯誤: {mt5.last_error()}", file=sys.stderr)

    end_date = datetime.now()

    if args.since:
        try:
            since_dt = datetime.strptime(args.since, "%Y-%m-%d %H:%M:%S")
        except ValueError:
            print(f"[錯誤] --since 格式不對: {args.since}，需要 yyyy-mm-dd hh:mm:ss", file=sys.stderr)
            mt5.shutdown()
            sys.exit(4)
        print(f"正在從 MT5 增量抓取 {symbol} ({args.timeframe})，since={args.since} ...")
        rates = fetch_since(symbol, tf_constant, since_dt, end_date)
    else:
        print(f"正在從 MT5 整批回補 {symbol} ({args.timeframe}) 歷史資料...")
        rates = fetch_full_backfill(symbol, tf_constant, args)

    if rates is None or len(rates) == 0:
        # 增量抓取抓到 0 筆是正常情況（代表資料庫已經是最新的，兩次匯出之間
        # 沒有新K棒收完），不當作錯誤中斷，輸出一份只有表頭的空檔即可。
        if args.since:
            print(f"{symbol} ({args.timeframe}) 沒有新資料（資料庫已是最新）。")
            pd.DataFrame(columns=['日期', '開', '高', '低', '收', '成交量']).to_csv(
                args.output, index=False, encoding='utf-8-sig')
            mt5.shutdown()
            sys.exit(0)
        print(f"無法取得 {symbol} 的歷史資料，請確認商品名稱與市場是否開盤。錯誤: {mt5.last_error()}",
              file=sys.stderr)
        mt5.shutdown()
        sys.exit(2)

    df = pd.DataFrame(rates)
    df['time'] = pd.to_datetime(df['time'], unit='s')

    df = df[['time', 'open', 'high', 'low', 'close', 'tick_volume']]
    df.columns = ['日期', '開', '高', '低', '收', '成交量']

    df.to_csv(args.output, index=False, encoding='utf-8-sig')
    print(f"成功抓取 {len(df)} 筆資料並寫入至: {args.output}")

    mt5.shutdown()


if __name__ == "__main__":
    main()
