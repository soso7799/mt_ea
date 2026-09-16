import argparse
import sys
from datetime import datetime, timedelta
import MetaTrader5 as mt5
import pandas as pd


def parse_args():
    parser = argparse.ArgumentParser(description="MT5 Incremental Data Fetcher for Gordon Console")
    parser.add_argument("--db", required=True, help="Database directory path")
    parser.add_argument("--symbol", required=True, help="Trading symbol (e.g., EURUSD, XAUUSD)")
    parser.add_argument("--timeframe", required=True, help="Timeframe (e.g., M15, H1, D1)")
    parser.add_argument("--amount", type=int, required=True, help="Amount value")
    parser.add_argument("--unit", required=True, choices=["D", "M", "Y"], help="Unit code: D (Day), M (Month), Y (Year)")
    parser.add_argument("--output", required=True, help="Output CSV file path")
    return parser.parse_args()


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


def main():
    args = parse_args()

    # 1. 初始化 MT5
    if not mt5.initialize():
        print(f"MT5 初始化失敗，錯誤代碼: {mt5.last_error()}", file=sys.stderr)
        sys.exit(1)

    symbol = args.symbol
    tf_constant = get_mt5_timeframe(args.timeframe)

    # 2. 計算時間範圍或抓取數量
    amount = args.amount
    unit = args.unit

    end_date = datetime.now()
    if unit == "D":
        start_date = end_date - timedelta(days=amount)
    elif unit == "M":
        start_date = end_date - timedelta(days=amount * 30)
    elif unit == "Y":
        start_date = end_date - timedelta(days=amount * 365)
    else:
        start_date = end_date - timedelta(days=365)

    print(f"正在從 MT5 抓取 {symbol} ({args.timeframe}) 歷史資料...")
    rates = mt5.copy_rates_range(symbol, tf_constant, start_date, end_date)

    if rates is None or len(rates) == 0:
        print(f"無法取得 {symbol} 的歷史資料，請確認商品名稱與市場是否開盤。錯誤: {mt5.last_error()}", file=sys.stderr)
        mt5.shutdown()
        sys.exit(2)

    # 3. 轉換為 DataFrame 並整理欄位格式
    df = pd.DataFrame(rates)
    df['time'] = pd.to_datetime(df['time'], unit='s')

    # 重新命名欄位對應 Excel 所需格式（日期, 開, 高, 低, 收, 成交量）
    df = df[['time', 'open', 'high', 'low', 'close', 'tick_volume']]
    df.columns = ['日期', '開', '高', '低', '收', '成交量']

    # 4. 輸出至指定的 CSV 路徑
    df.to_csv(args.output, index=False, encoding='utf-8-sig')
    print(f"成功抓取 {len(df)} 筆資料並寫入至: {args.output}")

    mt5.shutdown()


if __name__ == "__main__":
    main()
