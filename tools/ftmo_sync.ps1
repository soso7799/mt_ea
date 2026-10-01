# ftmo_sync.ps1 — HistoryExporter 匯出的 FTMO 歷史資料：
#   1) 同步到雲端硬碟 1（H:，CSV 原始資料，回測讀這裡）
#   2) 資料有更新時，每個週期打包成 zip 備份到雲端硬碟 2（G:），保留最近 $Keep 份
#   3) 總表推到 GitHub（ftmo_data/SUMMARY.md）
# 用「工作排程器」每天台灣時間 02:00 執行（EA 每 10 天 01:00 更新資料；沒變化就不會重複備份或提交）
param(
  [string]$Data   = "$env:APPDATA\MetaQuotes\Terminal\Common\Files\FTMO_Data",  # EA 輸出位置
  [string]$Drive  = "H:\我的雲端硬碟\FTMO_Data",                                  # 雲端硬碟 1：CSV（留空 = 不同步）
  [string]$Backup = "G:\我的雲端硬碟\FTMO_Backup",                                # 雲端硬碟 2：zip 備份（留空 = 不備份）
  [int]   $Keep   = 3,                                                           # 保留幾份備份
  [string]$Repo   = "C:\mt_ea"                                                   # 本機 git clone 的 mt_ea（不存在 = 略過 GitHub）
)
$ErrorActionPreference = "Stop"
$log = Join-Path $env:TEMP "ftmo_sync.log"
function Log($m) { $t = Get-Date -Format "yyyy-MM-dd HH:mm:ss"; "$t $m" | Tee-Object -FilePath $log -Append }

if (-not (Test-Path "$Data\SUMMARY.md")) { Log "找不到 $Data\SUMMARY.md，EA 還沒跑完第一次"; exit 1 }
$stamp = (Get-Item "$Data\SUMMARY.md").LastWriteTime.ToString("yyyy-MM-dd_HHmm")   # EA 每次跑完才更新總表

# 1) CSV 同步到雲端硬碟 1（只新增/更新，不刪除）
if ($Drive -ne "") {
  robocopy $Data $Drive /E /XO /R:2 /W:5 /NFL /NDL /NJH /NP | Out-Null
  if ($LASTEXITCODE -ge 8) { Log "robocopy 失敗 $LASTEXITCODE" } else { Log "已同步到 $Drive" }
}

# 2) zip 備份到雲端硬碟 2（同一次 EA 更新只備份一次）
if ($Backup -ne "") {
  $dest = Join-Path $Backup $stamp
  if (Test-Path "$dest\DONE.txt") {
    Log "備份 $stamp 已存在"
  } else {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $tmp = Join-Path $env:TEMP "ftmo_backup_$stamp"
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $tmp, $dest | Out-Null
    foreach ($d in Get-ChildItem $Data -Directory) {
      $zip = Join-Path $tmp ($d.Name + ".zip")
      [System.IO.Compression.ZipFile]::CreateFromDirectory($d.FullName, $zip, [System.IO.Compression.CompressionLevel]::Optimal, $true)
    }
    Copy-Item "$Data\SUMMARY.md", "$Data\SUMMARY.csv", "$Data\state.csv" $tmp -Force -ErrorAction SilentlyContinue
    robocopy $tmp $dest /E /R:2 /W:5 /NFL /NDL /NJH /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { Log "備份複製失敗 $LASTEXITCODE" }
    else {
      "ok" | Out-File "$dest\DONE.txt"
      $mb = [math]::Round((Get-ChildItem $tmp | Measure-Object Length -Sum).Sum / 1MB)
      Log "已備份 $stamp（$mb MB）到 $Backup"
      # 只保留最近 $Keep 份
      Get-ChildItem $Backup -Directory | Where-Object { Test-Path "$($_.FullName)\DONE.txt" } |
        Sort-Object Name -Descending | Select-Object -Skip $Keep |
        ForEach-Object { Remove-Item $_.FullName -Recurse -Force; Log "刪除舊備份 $($_.Name)" }
    }
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
  }
}

# 3) 總表推到 GitHub
if (Test-Path (Join-Path $Repo ".git")) {
  $dst = Join-Path $Repo "ftmo_data"
  New-Item -ItemType Directory -Force -Path $dst | Out-Null
  git -C $Repo pull --quiet
  Copy-Item "$Data\SUMMARY.md", "$Data\SUMMARY.csv" $dst -Force
  git -C $Repo add ftmo_data/SUMMARY.md ftmo_data/SUMMARY.csv
  git -C $Repo diff --cached --quiet
  if ($LASTEXITCODE -ne 0) {
    git -C $Repo commit --quiet -m "Update FTMO data summary"
    git -C $Repo push --quiet
    Log "總表已推到 GitHub"
  } else { Log "總表沒有變化" }
} else { Log "找不到 $Repo，略過 GitHub" }
