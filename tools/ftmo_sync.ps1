# ftmo_sync.ps1 — 把 HistoryExporter 匯出的 FTMO 歷史資料同步到雲端硬碟，並把總表推到 GitHub
# 用「工作排程器」每天執行一次即可（資料本身由 EA 每 10 天更新；沒變化就不會提交）
#
# 第一次使用：修改下面三個路徑
param(
  [string]$Data  = "$env:APPDATA\MetaQuotes\Terminal\Common\Files\FTMO_Data",  # EA 輸出位置
  [string]$Repo  = "C:\mt_ea",                                                   # 本機 git clone 的 mt_ea
  [string]$Drive = "H:\我的雲端硬碟\FTMO_Data"                                    # 雲端硬碟（留空 = 不同步）
)
$ErrorActionPreference = "Stop"
$log = Join-Path $env:TEMP "ftmo_sync.log"
function Log($m) { $t = Get-Date -Format "yyyy-MM-dd HH:mm:ss"; "$t $m" | Tee-Object -FilePath $log -Append }

if (-not (Test-Path "$Data\SUMMARY.md")) { Log "找不到 $Data\SUMMARY.md，EA 還沒跑完第一次"; exit 1 }

# 1) 資料同步到雲端硬碟（只新增/更新，不刪除）
if ($Drive -ne "") {
  robocopy $Data $Drive /E /XO /R:2 /W:5 /NFL /NDL /NJH /NP | Out-Null
  if ($LASTEXITCODE -ge 8) { Log "robocopy 失敗 $LASTEXITCODE" } else { Log "已同步到 $Drive" }
}

# 2) 總表推到 GitHub
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
