D:\整合計畫\整理後\ —— 資料流程整理說明
====================================================================

【這個資料夾放什麼】
把以下 3 支 Python 腳本、1 份 VBA 巨集檔，全部放在
D:\整合計畫\整理後\ 這一層（不要再分散在 D:\資料查詢\ 之類別的地方）：

  gordon_mt5_incremental.py     從 MT5 抓報價，支援 --since 增量抓取
  merge_export_csv.py           合併 ExportCSV 底下的匯出快照成資料庫
  update_all_data.py            從合併後的資料庫產生給 Excel 用的 CSV
  Module1_Complete.bas          VBA 巨集（貼到 Gordon_FTMO_Data_Console
                                 活頁簿的 Module1）

執行後會自動在這裡長出兩個資料夾：
  ExportCSV\           原始匯出快照 + ExportCSV\merged\（合併後資料庫、
                        _last_bar_state.csv 增量狀態檔）
  update_output\        today_open.csv / session_levels.csv


【完整資料流程（按 GDH_UpdateEverything 這顆按鈕，4步驟都會自動跑）】

  Excel「市場清單」打勾商品/週期
        │
        ▼
  ① GDH_BatchExportSelected（VBA）
     呼叫 gordon_mt5_incremental.py
     → 匯出新快照到 ExportCSV\
        │
        ▼
  ② merge_export_csv.py --delete-source --yes
     → 合併進 ExportCSV\merged\，刪除已合併的舊快照，
       同時寫出 _last_bar_state.csv（供下次①判斷增量/整批回補）
        │
        ▼
  ③ update_all_data.py
     → 讀 ExportCSV\merged\，產生
       update_output\today_open.csv
       update_output\session_levels.csv
        │
        ▼
  ④ 另一個活頁簿（含「關卡」「儀表板總表」分頁）的：
     Update關卡（讀 update_output\ 的兩份CSV，寫進「關卡」分頁）
     RefreshDashboard（把「關卡」等資料寫進「儀表板總表」的 C/D 欄）


【⚠️ 目前還沒接上、需要你自己確認的部分】

「儀表板總表」除了 C欄(最佳SL)/D欄(最佳TP) 是上面這條流程算出來的，
其餘全部資料來源是另外三張表：

  多商品參數優化    →  儀表板總表 E~T 欄（短均線/RSI/KD/PSY.../勝率Alpha）
  多商品狀態總表    →  儀表板總表 第15~19列（跨週期多空狀態、共振訊號）
  多商品指標明細    →  儀表板總表 第21~25列（11指標明細）

這三張表**不是**由 Update關卡/RefreshDashboard 或這次整理的 3 支 Python
腳本產生的——目前找不到是什麼工具在更新它們（GDH_BatchExportSelected
巨集開頭注解提過一個「量化分析引擎」，但實際腳本沒找到）。也就是說：

  按 GDH_UpdateEverything，「關卡」跟「儀表板總表」的 C/D 欄
  （最佳SL/最佳TP）會真的更新成最新資料；
  但「儀表板總表」其他欄位，只要那個「量化分析引擎」沒有被
  單獨執行，資料就會停在舊的，看起來像沒更新。

在找到/確認那個引擎是什麼之前，這部分只能先照實記錄，不去猜測或假裝
已經修好。


【另一個活頁簿要手動改的地方】

含「關卡」「儀表板總表」分頁的那個活頁簿，它的 Module1（主控更新模組）
裡有寫死 update_output 的路徑，要跟著改成新資料夾，否則 Update關卡
還是會去讀舊的 D:\整合計畫\update_output\：

  Const PY_SCRIPT As String = "D:\整合計畫\整理後\update_all_data.py"
  Const CSV_OPEN As String = "D:\整合計畫\整理後\update_output\today_open.csv"
  Const CSV_LEVELS As String = "D:\整合計畫\整理後\update_output\session_levels.csv"

（只要改這 3 行常數，其餘 Update關卡/RefreshDashboard 的邏輯不用動。）
