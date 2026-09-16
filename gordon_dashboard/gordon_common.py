"""
Gordon FTMO 監控儀表板 - 共用設定與工具函式

【假設與你之後可能要調整的地方】
1. SYMBOLS：12個商品清單是我依照你提到的相關性配對(AUDUSD/NZDUSD、US500/US30、
   EURUSD/USDCHF)推回去補齊的，不一定跟你原本帳戶交易的商品一致，要改直接改這個 list。
2. TIMEFRAMES：5個週期我先用 M15/H1/H4/D1/W1，你說明裡提到「同時持有量」判斷是用 H4，
   這組週期表有含 H4，如果你要改判斷週期，改 CORRELATION_TIMEFRAME 這個常數就好，
   不用動兩支主程式。
3. CORRELATION_GROUPS：只放你提過的三組避險關係，其餘商品沒有分組(None)。
4. CSV_OUTPUT_FOLDER：預設跟你 VBA 巨集裡的 D:\\historical_data\\ 一致，
   在 Windows 上直接跑就會對得起來；在非 Windows 環境(例如這次開發用的 Linux 容器)
   會自動改存到程式所在資料夾下的 output/，方便你在其他機器上先測試格式。
"""

from __future__ import annotations

import os
import platform
from datetime import datetime, timezone

import numpy as np
import pandas as pd

try:
    import MetaTrader5 as mt5
except ImportError:
    mt5 = None

SYMBOLS = [
    "EURUSD", "GBPUSD", "USDJPY", "USDCHF",
    "AUDUSD", "NZDUSD", "USDCAD",
    "EURJPY", "GBPJPY", "XAUUSD",
    "US500", "US30",
]

TIMEFRAME_NAMES = ["M15", "H1", "H4", "D1", "W1"]

CORRELATION_TIMEFRAME = "H4"

CORRELATION_GROUPS = {
    "AUDUSD": "AUDUSD/NZDUSD",
    "NZDUSD": "AUDUSD/NZDUSD",
    "US500": "US500/US30",
    "US30": "US500/US30",
    "EURUSD": "EURUSD/USDCHF",
    "USDCHF": "EURUSD/USDCHF",
}

if platform.system() == "Windows":
    CSV_OUTPUT_FOLDER = r"D:\historical_data"
else:
    CSV_OUTPUT_FOLDER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "output")

BARS_TO_FETCH = 300


def _mt5_timeframe(name: str):
    if mt5 is None:
        raise RuntimeError("找不到 MetaTrader5 套件，請先在有安裝 MT5 終端機的 Windows 機器上 pip install MetaTrader5")
    mapping = {
        "M15": mt5.TIMEFRAME_M15,
        "H1": mt5.TIMEFRAME_H1,
        "H4": mt5.TIMEFRAME_H4,
        "D1": mt5.TIMEFRAME_D1,
        "W1": mt5.TIMEFRAME_W1,
    }
    return mapping[name]


def connect_mt5() -> None:
    if mt5 is None:
        raise RuntimeError("找不到 MetaTrader5 套件，請先在有安裝 MT5 終端機的 Windows 機器上 pip install MetaTrader5")
    if not mt5.initialize():
        raise RuntimeError(f"MT5 連線失敗：{mt5.last_error()}，請確認 MT5 終端機已開啟並登入帳號")


def shutdown_mt5() -> None:
    if mt5 is not None:
        mt5.shutdown()


def fetch_rates(symbol: str, timeframe_name: str, count: int = BARS_TO_FETCH) -> pd.DataFrame:
    tf = _mt5_timeframe(timeframe_name)
    if not mt5.symbol_select(symbol, True):
        raise RuntimeError(f"{symbol}：券商找不到這個商品代碼，請確認 MT5 報價視窗裡的實際代號(可能有後綴，例如 EURUSD.m)")

    rates = mt5.copy_rates_from_pos(symbol, tf, 0, count)
    if rates is None or len(rates) == 0:
        raise RuntimeError(f"{symbol} {timeframe_name}：抓不到K棒資料，{mt5.last_error()}")

    df = pd.DataFrame(rates)
    df["time"] = pd.to_datetime(df["time"], unit="s", utc=True)
    df = df.rename(columns={"tick_volume": "volume"})
    return df


def get_symbol_info(symbol: str):
    if not mt5.symbol_select(symbol, True):
        raise RuntimeError(f"{symbol}：券商找不到這個商品代碼")
    info = mt5.symbol_info(symbol)
    tick = mt5.symbol_info_tick(symbol)
    if info is None or tick is None:
        raise RuntimeError(f"{symbol}：抓不到商品資訊/報價")
    return info, tick


def sma(series: pd.Series, period: int) -> pd.Series:
    return series.rolling(period).mean()


def ema(series: pd.Series, period: int) -> pd.Series:
    return series.ewm(span=period, adjust=False).mean()


def atr(df: pd.DataFrame, period: int = 14) -> pd.Series:
    high, low, close = df["high"], df["low"], df["close"]
    prev_close = close.shift(1)
    tr = pd.concat([
        high - low,
        (high - prev_close).abs(),
        (low - prev_close).abs(),
    ], axis=1).max(axis=1)
    return tr.rolling(period).mean()


def rsi(series: pd.Series, period: int = 14) -> pd.Series:
    delta = series.diff()
    gain = delta.clip(lower=0)
    loss = -delta.clip(upper=0)
    avg_gain = gain.rolling(period).mean()
    avg_loss = loss.rolling(period).mean()
    rs = avg_gain / avg_loss.replace(0, np.nan)
    result = 100 - (100 / (1 + rs))
    return result.fillna(50)


def macd(series: pd.Series, fast: int = 12, slow: int = 26, signal: int = 9):
    macd_line = ema(series, fast) - ema(series, slow)
    signal_line = ema(macd_line, signal)
    hist = macd_line - signal_line
    return macd_line, signal_line, hist


def now_str() -> str:
    return datetime.now(timezone.utc).astimezone().strftime("%Y-%m-%d %H:%M:%S")


def write_csv(rows: list[dict], columns: list[str], filename: str) -> str:
    os.makedirs(CSV_OUTPUT_FOLDER, exist_ok=True)
    path = os.path.join(CSV_OUTPUT_FOLDER, filename)
    df = pd.DataFrame(rows, columns=columns)
    df.to_csv(path, index=False, encoding="utf-8-sig")
    return path
