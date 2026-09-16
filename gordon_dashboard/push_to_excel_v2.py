# -*- coding: utf-8 -*-
"""
push_to_excel_v2.py

給 Gordon_FTMO_監控儀表板.xlsm 用的資料更新入口 —— 取代整套 CSV + VBA巨集
的方式，改成透過 xlwings 直接把資料寫進「已經開啟的」Excel活頁簿。

【為什麼整個重做，不再走CSV+VBA這條路】
CSV+VBA這條路查到底，確認過 Python 端完全正常(AnalysisResults.csv/
LevelsResults.csv 內容格式、時間戳記都對)，但 Excel 那邊不管用 Dir$ 還是
FileSystemObject.FileExists，過一段時間後都找不到同一個檔案；把輸出資料夾搬離
Google雲端硬碟同步範圍(D:\GordonExchange)後問題依然存在。這代表「寫檔案、事後
讀檔案」這種中間層，在這台電腦的環境下本身就不可靠，不管檔案放哪裡、VBA用哪個
函式檢查都一樣。所以整個放棄這個中間層：Python 不寫CSV，直接用 xlwings 透過
COM 把資料寫進「當下開著的」Excel活頁簿，沒有檔案可以在中間被搞丟，這一整類
bug直接消失，不用再猜是誰的問題。

VBA 的 RefreshAllData/ImportCSVToSheet 巨集不再需要，不用改、不用刪，放著
不會影響這支腳本，這支完全不依賴它。

【用法】
1. 第一次要多裝一個套件：pip install xlwings
2. 打開 Gordon_FTMO_監控儀表板.xlsm(注意副檔名要是 .xlsm，不是 .xlsm.xlsx 之類
   的複本)，保持它開著(不用做任何操作)
3. 在這個資料夾底下執行：python push_to_excel_v2.py
4. 資料會直接寫進「Data 分頁」跟「關卡 分頁」，跑完就是最新的，不用再按任何巨集

【分頁名稱怎麼找】
不用先手動改分頁名稱。程式會依序找 GDX_Data / Data1 / Data(關卡分頁對應
GDX_關卡 / 關卡1 / 關卡)，三個候選名稱裡只要活頁簿裡存在其中一個就會用。
如果三個都對不上，程式會直接印出這個活頁簿裡「實際的」分頁名稱清單，
把那份清單貼給我就好，不用再截圖。

【已知限制，老實說清楚】
這支重用 data_sheet_v2.py / levels_sheet_v2.py 裡
已經在 Windows 實機驗證過會動的 analyze_one()/COLUMNS，邏輯沒有變。但
xlwings 需要真正的 Excel COM 環境，這次開發用的 Linux 容器沒有 Excel，
所以「透過 xlwings 寫進 Excel」這一段本身沒辦法在這裡實際跑過，只做了
語法檢查，第一次在你電腦上執行如果有問題，把錯誤訊息貼給我。
"""

import sys

import MetaTrader5 as mt5
import xlwings as xw

import analysis_core_v2 as gfa
import data_sheet_v2 as engine
import levels_sheet_v2 as levels

WORKBOOK_NAME = "Gordon_FTMO_監控儀表板.xlsm"
# 分頁名稱用「候選清單」而不是寫死一個字串：你不管是照指示改成 GDX_ 前綴、
# 還是自己在後面加「1」、或根本沒改，都抓得到，不用逼你重新命名一次。
DATA_SHEET_CANDIDATES = ["GDX_Data", "Data1", "Data"]
LEVELS_SHEET_CANDIDATES = ["GDX_關卡", "關卡1", "關卡"]


def find_sheet(wb, candidates):
    """依序比對候選分頁名稱，抓到第一個存在的就回傳。
    如果一個都對不上，把活頁簿裡「實際存在」的分頁名稱列出來，
    這樣錯誤訊息本身就能回答「你的分頁到底叫什麼」，不用再截圖確認。"""
    existing = {s.name: s for s in wb.sheets}
    for name in candidates:
        if name in existing:
            return existing[name]
    raise RuntimeError(
        f"候選分頁名稱 {candidates} 在活頁簿裡都找不到。"
        f"這個活頁簿目前實際的分頁名稱是：{list(existing.keys())}"
    )


def write_sheet(ws, rows, columns):
    """把表頭(第1列)也一併蓋成這支程式自己的欄位名稱，再貼新資料。

    之前版本假設分頁裡已經有跟這支程式欄位對得上的表頭、所以不動第1列——結果
    使用者的分頁裡留著別的舊表格的表頭(symbol/tf/status/date/close/ma_fast/...)，
    造成資料寫進去了、但欄名對不起來(例如第3欄實際是BarTime，但表頭還寫著
    status)。既然表頭對不上，就不該假裝它是對的，直接蓋掉，欄名跟資料才會一致。
    """
    header_clear_cols = max(len(columns), 60)
    ws.range((1, 1), (1, header_clear_cols)).clear_contents()
    ws.range((1, 1)).value = [columns]

    n = len(rows)
    clear_rows = max(n, 200)
    ws.range((2, 1), (clear_rows + 1, len(columns))).clear_contents()
    if n == 0:
        return
    values = [[r.get(c, "") for c in columns] for r in rows]
    ws.range((2, 1)).value = values


def main():
    if not mt5.initialize():
        print(f"MT5 初始化失敗：{mt5.last_error()}", file=sys.stderr)
        return 1
    engine.print_connection_info()

    try:
        wb = xw.Book(WORKBOOK_NAME)
    except Exception as e:
        mt5.shutdown()
        print(f"連不到已開啟的 {WORKBOOK_NAME}：{e}", file=sys.stderr)
        print("請先手動打開這個檔案、保持開著，再重跑這支。")
        return 1

    try:
        data_ws = find_sheet(wb, DATA_SHEET_CANDIDATES)
        levels_ws = find_sheet(wb, LEVELS_SHEET_CANDIDATES)
    except RuntimeError as e:
        mt5.shutdown()
        print(str(e), file=sys.stderr)
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
        print("沒有任何一筆資料分析成功，不寫入。")
        for e in errors:
            print(" -", e)
        return 1

    if analysis_rows:
        write_sheet(data_ws, analysis_rows, engine.COLUMNS)
        print(f"已寫入「{data_ws.name}」分頁：{len(analysis_rows)} 筆")

    if levels_rows:
        write_sheet(levels_ws, levels_rows, levels.COLUMNS)
        print(f"已寫入「{levels_ws.name}」分頁：{len(levels_rows)} 筆")

    wb.app.calculate()

    if errors:
        print(f"{len(errors)} 筆失敗：")
        for e in errors:
            print(" -", e)

    if engine.STALE_LOG:
        print(f"[警告] 共 {len(engine.STALE_LOG)} 筆資料疑似過期(不是即時報價)，請檢查上面的警告訊息")

    print("完成，不用再按任何 Excel 巨集。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
