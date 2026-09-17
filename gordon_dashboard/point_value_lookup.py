# -*- coding: utf-8 -*-
"""
point_value_lookup.py

給「點值設定(每手/每1.0價格單位變動的美元價值)」這格用的查詢工具。

【為什麼不能查網路上的公版數字】
這個值 = trade_tick_value / trade_tick_size，等於「每手、價格每變動1.0單位」
對應多少帳戶幣別(通常是美元)的損益。不同券商的合約規格(合約大小/最小跳動/
跳動值)不一定一樣，FTMO自己不同伺服器(Server1/2/3...)、不同帳戶類型
(Standard/Swing)也可能有差異。用網路查到的公版數字填，跟你這個帳號實際的
規格對不上，部位試算、風控會算錯。這裡直接從你登入的MT5帳號現場抓真正的
合約規格，不是猜的、不是查來的。

【用法】
打開MT5、確認已登入你的FTMO帳號，執行：
    python point_value_lookup.py
會把 analysis_core_v2.py 裡 SYMBOLS 清單12個商品的規格跟算好的點值印出來，
把「每1.0價格變動的美元價值」那欄的數字填進 Excel 的「點值設定」表格即可。
"""

import sys

import MetaTrader5 as mt5

import analysis_core_v2 as gfa


def main():
    if not mt5.initialize():
        print(f"MT5 初始化失敗：{mt5.last_error()}", file=sys.stderr)
        return 1

    print(f"{'商品':<12}{'合約大小':>14}{'最小跳動':>14}{'跳動值(帳戶幣別)':>18}{'每1.0價格變動的美元價值':>24}")
    print("-" * 84)

    rows = []
    for symbol in gfa.SYMBOLS:
        if not mt5.symbol_select(symbol, True):
            print(f"{symbol}：券商找不到這個商品代碼，請確認 MT5 報價視窗裡的實際代號")
            continue
        info = mt5.symbol_info(symbol)
        if info is None:
            print(f"{symbol}：抓不到規格(symbol_info回傳None)")
            continue

        contract_size = info.trade_contract_size
        tick_size = info.trade_tick_size
        tick_value = info.trade_tick_value
        value_per_1_0 = tick_value / tick_size if tick_size else float("nan")

        print(f"{symbol:<12}{contract_size:>14g}{tick_size:>14g}{tick_value:>18.4f}{value_per_1_0:>24.4f}")
        rows.append((symbol, value_per_1_0))

    mt5.shutdown()

    if not rows:
        print("沒有抓到任何商品規格，檢查一下MT5是否已登入、圖表能不能正常跳動報價。")
        return 1

    print("\n把上面「每1.0價格變動的美元價值」那欄的數字，填進 Excel「點值設定」表格對應的商品列即可。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
