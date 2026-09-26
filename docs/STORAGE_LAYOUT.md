# 網路硬碟規劃：歷史資料碟 + 執行程式碟

兩顆網路硬碟分工：

| 用途 | 建議代號 | UNC 路徑（範例，請改成你的） | 放什麼 |
|------|---------|-----------------------------|--------|
| 歷史資料碟 | `H:` | `\\NAS\mt_history` | 報價歷史、回測報告、交易紀錄、備份（大量、只增不改） |
| 執行程式碟 | `P:` | `\\NAS\mt_run`     | EA 原始碼、編譯好的 .ex5、.set 參數檔、部署腳本（小、常更新） |

> MT5 終端機本體（terminal64.exe 與 `bases` 的即時讀寫）**建議留在本機 SSD**。
> 網路斷線時從網路碟執行的終端機會直接當掉，實盤 EA 會跟著停；回測讀網路碟的 tick 也會慢很多。
> 所以網路碟負責「存放 / 發布」，本機負責「執行」，兩者用符號連結 (symlink) 與部署腳本串起來。

## 1. 歷史資料碟 `H:\`（`\\NAS\mt_history`）

```
H:\
├─ bases\                 ← MT5 下載的報價歷史 (.hcc/.tkc)，可選擇 symlink 過來
│   └─ <券商伺服器名>\history\EURUSD\...
├─ export\
│   ├─ bars\<商品>\<週期>\YYYY.csv   ← 匯出的 K 線 (M12/H1/D1…)
│   └─ ticks\<商品>\YYYY-MM.csv
├─ trade_logs\            ← EA 寫出的交易 / 信號紀錄（連結到 MQL5\Files）
│   └─ YYYY\MM\
├─ tester_reports\        ← 策略測試器報告、最佳化結果 (.htm/.xml)
│   └─ v5.2\YYYYMMDD_<說明>\
└─ backups\
    └─ YYYYMMDD\          ← 帳戶設定、profiles、.set 的每日備份
```

原則：
- 只增不改；依「商品 / 年份」分資料夾，避免單一資料夾檔案過多。
- `bases` 放網路碟會讓回測變慢，**只在本機空間不足時**才用 symlink 移過去；否則只定期備份。

## 2. 執行程式碟 `P:\`（`\\NAS\mt_run`）

```
P:\
├─ src\mt_ea\             ← 本 repo 的 git clone（唯一的原始碼來源）
│   ├─ MultiCurrency_EA.mq5
│   └─ FilterLib_v5.mqh
├─ releases\
│   └─ v5.2\              ← 編譯好的 MultiCurrency_EA.ex5 + 發布說明
├─ presets\               ← 各帳戶 / 各版本的 .set 參數檔
│   └─ v5.2_live.set, v5.2_demo.set
├─ scripts\               ← setup_drives.bat、deploy.bat（本 repo 的 scripts\）
└─ terminals\             ← (可選) 攜帶版 MT5，僅供測試機 / 備援使用，不跑實盤
```

## 3. 串接方式

MQL5 的檔案函式只能寫進沙盒 (`MQL5\Files` 或 `Common\Files`)，不能直接寫 `H:\`。
因此用目錄符號連結把沙盒指到網路碟：

| 本機路徑 | 連結到 |
|---------|--------|
| `<資料夾>\MQL5\Files\trade_logs` | `\\NAS\mt_history\trade_logs` |
| `<資料夾>\MQL5\Profiles\Tester` 的報告輸出 | 手動或腳本搬到 `tester_reports` |
| `<資料夾>\bases`（可選） | `\\NAS\mt_history\bases` |

`<資料夾>` = MT5「檔案 → 開啟資料夾」看到的路徑（`%APPDATA%\MetaQuotes\Terminal\<ID>`）。

部署流程：
1. 在 `P:\src\mt_ea` 修改、commit。
2. 執行 `scripts\deploy.bat` → 把 `.mq5/.mqh` 複製到本機 `MQL5\Experts`、`MQL5\Include`。
3. 在 MetaEditor 編譯，把 `.ex5` 複製回 `P:\releases\<版本>\` 留存。

## 4. 注意事項

- **用 UNC 路徑，不要用磁碟代號建連結**：代號是每個登入工作階段各自對應的，
  以系統管理員身分執行的 cmd 看不到一般使用者對應的 `H:`/`P:`，排程或服務也看不到。
- 建立 symlink 需要系統管理員權限（或 Windows「開發人員模式」）。
- 確認允許本機→遠端連結：`fsutil behavior query SymlinkEvaluation`，`L2R` 需為啟用。
- NAS 開啟快照 / 資源回收筒，至少保護 `H:\trade_logs` 與 `P:\src`。
- 實盤機若是 VPS，網路碟延遲高時只做每日同步（robocopy），不要即時連結。
