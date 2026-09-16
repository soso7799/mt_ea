# -*- coding: utf-8 -*-
"""
RunDashboardUpdate.py

給 Gordon_FTMO_監控儀表板.xlsm 用的「一鍵更新」入口，取代分別執行
gordon_analysis_engine_v1.py 跟 gordon_levels_module_v1.py 兩次。

【為什麼要這支：解決MT5自動斷線退出的問題】
gordon_analysis_engine_v1.py 跟 gordon_levels_module_v1.py 各自獨立呼叫
mt5.initialize()/mt5.shutdown()。如果照順序分開執行兩支，等於連續做兩次
「連線→拉資料→斷線」，同一顆商品/週期的報價也重複抓了兩遍。這支把兩邊合併成
一次 mt5.initialize()，跑完兩份分析、兩個CSV都寫完才 mt5.shutdown()，全程只
連線一次、每個商品每個週期的報價只抓一次，不會在執行中途反覆斷線重連。

【執行順序 - 直接照這3步做】
1. 打開 MT5 終端機，確認已登入你的 FTMO 帳號、圖表可以正常跳動報價。
2. 在這個資料夾底下執行：
       python RunDashboardUpdate.py
   跑完會同時產生：
       D:\\historical_data\\AnalysisResults.csv
       D:\\historical_data\\LevelsResults.csv
3. 回到 Gordon_FTMO_監控儀表板.xlsm，按「RefreshAllData」巨集，兩個檔案都會
   一次匯入 Data / 關卡 兩個分頁。

跑完這支之後 MT5 終端機本身不會被關掉 —— mt5.shutdown() 只是斷開 Python
跟終端機之間的資料連線，終端機應用程式本身、你手動開的圖表/EA都不受影響，
可以放心連續重複執行這支腳本。
"""

import os
import sys
import pandas as pd
import MetaTrader5 as mt5

import gordon_full_analysis as gfa
import gordon_analysis_engine_v1 as engine
import gordon_levels_module_v1 as levels


def main():
    if not mt5.initialize():
        print(f"MT5 初始化失敗：{mt5.last_error()}", file=sys.stderr)
        return 1

    analysis_rows, levels_rows, errors = [], [], []
    try:
        for symbol in gfa.SYMBOLS:
            try:
                daily = engine.fetch_mt5_df(symbol, "D1", count=10)
            except Exception as e:
                errors.append(f"{symbol} D1(關卡用昨日高低): {e}")
                daily = None

            for tf_name in gfa.TIMEFRAMES:
                try:
                    df = engine.fetch_mt5_df(symbol, tf_name)
                except Exception as e:
                    errors.append(f"{symbol} {tf_name}(抓K棒): {e}")
                    continue

                try:
                    analysis_rows.append(engine.analyze_one(symbol, tf_name, df=df))
                except Exception as e:
                    errors.append(f"{symbol} {tf_name}(Data分析): {e}")

                try:
                    levels_rows.append(levels.analyze_one(symbol, tf_name, df=df, daily=daily))
                except Exception as e:
                    errors.append(f"{symbol} {tf_name}(關卡分析): {e}")
    finally:
        mt5.shutdown()

    if not analysis_rows and not levels_rows:
        print("沒有任何一筆資料分析成功，不寫檔。")
        for e in errors:
            print(" -", e)
        return 1

    os.makedirs(engine.OUTPUT_FOLDER, exist_ok=True)

    if analysis_rows:
        pd.DataFrame(analysis_rows, columns=engine.COLUMNS).to_csv(
            engine.OUTPUT_PATH, index=False, encoding="utf-8-sig")
        print(f"寫入完成：{engine.OUTPUT_PATH}（{len(analysis_rows)} 筆）")

    if levels_rows:
        pd.DataFrame(levels_rows, columns=levels.COLUMNS).to_csv(
            levels.OUTPUT_PATH, index=False, encoding="utf-8-sig")
        print(f"寫入完成：{levels.OUTPUT_PATH}（{len(levels_rows)} 筆）")

    if errors:
        print(f"{len(errors)} 筆失敗：")
        for e in errors:
            print(" -", e)

    if engine.STALE_LOG:
        print(f"[警告] 共 {len(engine.STALE_LOG)} 筆資料疑似過期(不是即時報價)，請檢查上面的警告訊息")

    return 0


if __name__ == "__main__":
    sys.exit(main())
