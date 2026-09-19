# ExportCSV 自動同步到 Google Drive

用 `Sync-ExportCSV-ToGoogleDrive.ps1`（Robocopy `/MIR` 鏡像）把本機匯出的 CSV 資料夾，
自動複製到已掛載的 Google Drive 虛擬硬碟資料夾，再交給 Google Drive 用戶端把它同步上雲端。

## 前提

- 已安裝 Google Drive 電腦版，並掛載成某個磁碟機代號（例如 `G:\`）。
- 本機有一個持續產生 CSV 的來源資料夾（例如 `D:\資料查詢\ExportCSV`）。

## 最簡單的用法：雙擊執行

直接雙擊 `一鍵同步到GoogleDrive.bat` 這個檔案，不用開 PowerShell、不用打任何指令。

- 它裡面已經寫死路徑：`D:\資料查詢\ExportCSV` → `G:\ExportCSV`。如果您的路徑不是這兩個，
  用記事本打開 `一鍵同步到GoogleDrive.bat`，把裡面的 `-Source` 和 `-Destination` 後面的路徑改成您實際的路徑即可。
- 跑完視窗會停住顯示結果，按任意鍵才會關閉，方便您確認有沒有錯誤。
- 之後要排程自動執行，也是排程去執行這個 `.bat` 檔就好（見下方「設定排程」，動作改成直接指向這個 `.bat` 檔，不用再填 PowerShell 引數）。

## 手動測試一次（進階，用 PowerShell 直接下指令）

用系統管理員或一般權限開 PowerShell，執行：

```powershell
powershell.exe -ExecutionPolicy Bypass -File "C:\path\to\tools\backup\Sync-ExportCSV-ToGoogleDrive.ps1" `
    -Source "D:\資料查詢\ExportCSV" `
    -Destination "G:\ExportCSV"
```

- 第一次執行會把整個 `Source` 完整複製到 `Destination`。
- 之後每次執行都是「鏡像」：`Destination` 會新增/更新 `Source` 有的檔案，並刪除 `Source` 已經沒有的檔案，讓兩邊保持一致。
- 執行紀錄會寫在腳本旁的 `logs\` 資料夾：`sync_summary.log`（每次一行摘要）與 `robocopy_<時間戳記>.log`（該次完整明細，逾 30 天自動清除，可用 `-KeepLogDays` 調整）。

確認 `G:\ExportCSV` 內容正確、Google Drive 圖示同步完成後，再進行下一步排程。

## 設定排程（每隔一段時間自動跑）

1. 開「工作排程器」(Task Scheduler) → 建立工作。
2. 觸發程序：例如「登入時」+「每隔 15 分鐘重複一次，持續 1 天」。
3. 動作：
   - 程式/指令碼：直接瀏覽選取 `一鍵同步到GoogleDrive.bat` 這個檔案（不用填任何引數）。
4. 建議勾選「不論使用者是否登入均執行」時，確認 Google Drive 電腦版本身也有在該帳號下自動啟動，否則 `G:\` 磁碟機可能還沒掛載，腳本會因為找不到路徑而失敗。

## 關於 4 個 Google 帳號 / 每個 15GB

這支腳本一次只對應一組 `Source` → `Destination`（一個掛載的磁碟機代號）。如果之後資料量超過單一帳號的 15GB，
可以：

- 把 `ExportCSV` 依日期或商品拆成幾個子資料夾，分別同步到不同帳號掛載的磁碟機代號（例如 `G:\`、`H:\`、`I:\`、`J:\`），
  對應執行多次（用不同的 `-Source` / `-Destination` 各建一個排程工作）；或
- 改用 rclone 之類支援跨帳號 union 的工具。目前腳本先滿足單一帳號、單一資料夾的需求。
