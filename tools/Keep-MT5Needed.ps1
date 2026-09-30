<#
  Keep-MT5Needed.ps1
  只保留 MT5 真正需要的程式檔，其餘集中搬到一個封存資料夾（可一鍵還原）。

  「需要的」自動判斷：
    1. 圖表上正在使用的 EA / 指標（讀取 MQL5\Profiles 內所有 .chr 圖表與 .tpl 模板）
    2. 保留清單檔（MT5_保留清單.txt）列出的名稱，可用 * 萬用字元
    3. 以上檔案用到的相依檔：同名 .mq5/.ex5、#include 的 .mqh、iCustom 呼叫的指標
    4. MT5 內建範例資料夾（Examples、Free Robots）一律保留

  只處理：Experts、Indicators、Scripts、Services，以及 MQL5 底下其他非標準資料夾與散落檔案。
  不處理：Include、Libraries、Files、Images、Logs、Presets、Profiles、Sounds、Shared Projects。

  用法：
    powershell -ExecutionPolicy Bypass -File "路徑\Keep-MT5Needed.ps1"            # 只產生報告
    powershell -ExecutionPolicy Bypass -File "路徑\Keep-MT5Needed.ps1" -Apply     # 實際搬移
    -KeepList  "D:\我的保留清單.txt"   指定保留清單（預設：與腳本同資料夾的 MT5_保留清單.txt）
    -ArchiveDir "D:\MT5_封存"         指定封存位置（預設：桌面\MT5_封存_日期時間）
#>
param(
    [string]$Root = (Join-Path $env:APPDATA 'MetaQuotes\Terminal'),
    [string]$KeepList = (Join-Path $PSScriptRoot 'MT5_保留清單.txt'),
    [string]$ArchiveDir = '',
    [string[]]$ProtectFolders = @('Examples', 'Free Robots'),
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
$stamp   = Get-Date -Format 'yyyyMMdd_HHmmss'
$desktop = [Environment]::GetFolderPath('Desktop')
if (-not $desktop) { $desktop = $HOME }
if (-not $ArchiveDir) { $ArchiveDir = Join-Path $desktop "MT5_封存_$stamp" }
$sep = [IO.Path]::DirectorySeparatorChar

$programDirs = @('Experts', 'Indicators', 'Scripts', 'Services')
$systemDirs  = @('Include', 'Libraries', 'Files', 'Images', 'Logs', 'Presets', 'Profiles', 'Sounds', 'Shared Projects')
$programExt  = @('.mq5', '.ex5', '.mqh', '.mq4', '.ex4', '.set')

if (-not (Test-Path -LiteralPath $Root)) { Write-Host "找不到資料夾：$Root" -ForegroundColor Red; exit 1 }

if ($Apply) {
    $running = Get-Process -Name terminal64, terminal, metaeditor64, metaeditor, metatester64 -ErrorAction SilentlyContinue
    if ($running) {
        Write-Host '請先關閉所有 MT5 / MetaEditor 視窗再執行 -Apply：' -ForegroundColor Red
        $running | ForEach-Object { Write-Host "  $($_.ProcessName)  PID=$($_.Id)" }
        exit 1
    }
}

# ---------- 保留清單 ----------
$patterns = @()
if (Test-Path -LiteralPath $KeepList) {
    $patterns = @(Get-Content -LiteralPath $KeepList -Encoding UTF8 |
                  ForEach-Object { $_.Trim() } |
                  Where-Object { $_ -and -not $_.StartsWith('#') } |
                  ForEach-Object { $_.Replace('/', '\') })
    Write-Host "保留清單：$KeepList（$($patterns.Count) 條）"
} else {
    Write-Host "沒有保留清單（$KeepList），只保留圖表上正在使用的程式。" -ForegroundColor Yellow
}

function Norm([string]$p) { $p.Replace('/', $sep).Replace('\', $sep) }
function Rel([string]$full, [string]$base) { $full.Substring($base.TrimEnd($sep).Length + 1).Replace($sep, '\') }
function Read-Text([string]$p) {
    try { [IO.File]::ReadAllText($p) } catch { '' }   # 依 BOM 自動判斷 UTF-16 / UTF-8
}

$report  = New-Object System.Collections.Generic.List[object]
$toMove  = New-Object System.Collections.Generic.List[object]

$terminals = Get-ChildItem -LiteralPath $Root -Directory | Where-Object { $_.Name -match '^[0-9A-Fa-f]{32}$' }
foreach ($t in $terminals) {
    $mql5 = Join-Path $t.FullName 'MQL5'
    if (-not (Test-Path -LiteralPath $mql5)) { continue }

    $origin = ''
    $originFile = Join-Path $t.FullName 'origin.txt'
    if (Test-Path -LiteralPath $originFile) {
        $origin = (Get-Content -LiteralPath $originFile -Encoding Unicode -Raw).Trim([char]0xFEFF, ' ', "`r", "`n")
    }
    $label = if ($origin) { (Split-Path $origin -Leaf) } else { 'unknown' }
    $label = ($label -replace '[\\/:*?"<>|]', '_') + '_' + $t.Name.Substring(0, 8)
    Write-Host "`n[$label] $origin" -ForegroundColor Cyan

    # ---- 候選檔案：程式資料夾 + 非標準資料夾 + MQL5 根目錄散落檔 ----
    $candidates = @{}
    foreach ($d in Get-ChildItem -LiteralPath $mql5 -Directory) {
        if ($systemDirs -contains $d.Name) { continue }
        Get-ChildItem -LiteralPath $d.FullName -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $programExt -contains $_.Extension.ToLower() } |
            ForEach-Object { $candidates[$_.FullName.ToLower()] = $_ }
    }
    Get-ChildItem -LiteralPath $mql5 -File | Where-Object { $programExt -contains $_.Extension.ToLower() } |
        ForEach-Object { $candidates[$_.FullName.ToLower()] = $_ }

    $keep   = @{}   # 全路徑(小寫) -> 原因
    $queue  = New-Object System.Collections.Generic.Queue[string]
    function Mark([string]$full, [string]$why) {
        if (-not $full) { return }
        $k = $full.ToLower()
        if ($keep.ContainsKey($k)) { return }
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { return }
        $keep[$k] = $why
        $queue.Enqueue($full)
    }

    # 1. 內建範例資料夾
    foreach ($f in $candidates.Values) {
        $parts = (Rel $f.FullName $mql5).Split('\')
        foreach ($pf in $ProtectFolders) { if ($parts -contains $pf) { Mark $f.FullName "MT5 內建（$pf）"; break } }
    }

    # 2. 圖表 / 模板上使用中的程式
    $profiles = Join-Path $mql5 'Profiles'
    if (Test-Path -LiteralPath $profiles) {
        $chartFiles = Get-ChildItem -LiteralPath $profiles -Recurse -File -Include *.chr, *.tpl -ErrorAction SilentlyContinue
        foreach ($c in $chartFiles) {
            $txt = Read-Text $c.FullName
            $where = Rel $c.FullName $mql5
            foreach ($m in [regex]::Matches($txt, '(?im)^\s*path\s*=\s*(.+?\.ex5)\s*$')) {
                Mark (Join-Path $mql5 (Norm $m.Groups[1].Value)) "圖表使用中（$where）"
            }
            foreach ($m in [regex]::Matches($txt, '(?im)<expert>[^<]*?^\s*name\s*=\s*([^\r\n]+)')) {
                $n = $m.Groups[1].Value.Trim()
                Mark (Join-Path $mql5 (Norm "Experts\$n.ex5")) "圖表使用中（$where）"
                Mark (Join-Path $mql5 (Norm "Experts\$n.mq5")) "圖表使用中（$where）"
            }
        }
    }

    # 3. 保留清單
    if ($patterns.Count) {
        foreach ($f in $candidates.Values) {
            $rel = Rel $f.FullName $mql5
            $relNoExt = $rel.Substring(0, $rel.Length - $f.Extension.Length)
            foreach ($p in $patterns) {
                if ($f.BaseName -like $p -or $f.Name -like $p -or $rel -like $p -or $relNoExt -like $p -or
                    $rel -like "*\$p" -or $relNoExt -like "*\$p") {
                    Mark $f.FullName "保留清單（$p）"; break
                }
            }
        }
    }

    # 4. 相依檔
    while ($queue.Count) {
        $f = $queue.Dequeue()
        $why = "相依：$(Split-Path $f -Leaf)"
        $dir = Split-Path $f -Parent
        $noExt = [IO.Path]::Combine($dir, [IO.Path]::GetFileNameWithoutExtension($f))
        Mark "$noExt.mq5" $why
        Mark "$noExt.ex5" $why
        Mark "$noExt.set" $why
        $ext = [IO.Path]::GetExtension($f).ToLower()
        if ($ext -ne '.mq5' -and $ext -ne '.mqh') { continue }
        $src = Read-Text $f
        foreach ($m in [regex]::Matches($src, '(?m)^\s*#include\s*([<"])([^>"]+)[>"]')) {
            $inc = Norm $m.Groups[2].Value.Trim()
            if ($m.Groups[1].Value -eq '"') { Mark (Join-Path $dir $inc) $why }
            Mark (Join-Path (Join-Path $mql5 'Include') $inc) $why
        }
        foreach ($m in [regex]::Matches($src, 'iCustom\s*\([^;]*?"([^"]+)"')) {
            $n = $m.Groups[1].Value.Trim().TrimStart('\', '/')
            if ($n.StartsWith('::')) { continue }
            if ($n -notmatch '\.ex5$') { $n = "$n.ex5" }
            Mark (Join-Path (Join-Path $mql5 'Indicators') (Norm $n)) $why
            Mark (Join-Path $dir (Norm $n)) $why
        }
    }

    # ---- 結果 ----
    $kept = 0; $moved = 0
    foreach ($f in ($candidates.Values | Sort-Object FullName)) {
        $rel = Rel $f.FullName $mql5
        $k = $f.FullName.ToLower()
        if ($keep.ContainsKey($k)) {
            $kept++
            $report.Add([pscustomobject]@{ 終端機 = $label; 動作 = '保留'; 路徑 = "MQL5\$rel"; 原因 = $keep[$k] })
        } else {
            $moved++
            $dest = Join-Path (Join-Path $ArchiveDir $label) (Norm "MQL5\$rel")
            $report.Add([pscustomobject]@{ 終端機 = $label; 動作 = '封存'; 路徑 = "MQL5\$rel"; 原因 = '未在圖表使用、不在保留清單、也不是相依檔' })
            $toMove.Add([pscustomobject]@{ Source = $f.FullName; Dest = $dest })
        }
    }
    Write-Host ("  保留 {0} 個，封存 {1} 個" -f $kept, $moved)
}

$reportPath = Join-Path $desktop "MT5_保留報告_$stamp.csv"
$report | Export-Csv -LiteralPath $reportPath -NoTypeInformation -Encoding UTF8
Write-Host "`n完整報告：$reportPath" -ForegroundColor Green

if (-not $Apply) {
    Write-Host "目前只產生報告，沒有搬動任何檔案。共 $($toMove.Count) 個檔案會被封存。" -ForegroundColor Yellow
    Write-Host '請檢查報告中「封存」的項目；要保留的，把名稱加進 MT5_保留清單.txt 後重新執行。'
    Write-Host '確認後關閉 MT5，加 -Apply 執行。'
    exit 0
}

# ---------- 搬移並產生還原腳本 ----------
New-Item -ItemType Directory -Path $ArchiveDir -Force | Out-Null
$done = New-Object System.Collections.Generic.List[object]
foreach ($m in $toMove) {
    if (-not (Test-Path -LiteralPath $m.Source)) { continue }
    New-Item -ItemType Directory -Path (Split-Path $m.Dest -Parent) -Force | Out-Null
    Move-Item -LiteralPath $m.Source -Destination $m.Dest -Force
    $done.Add($m)
}
$done | Export-Csv -LiteralPath (Join-Path $ArchiveDir '還原清單.csv') -NoTypeInformation -Encoding UTF8
Copy-Item -LiteralPath $reportPath -Destination $ArchiveDir

$restore = @'
# 把封存的檔案全部搬回 MT5 原位置。先關閉 MT5 再執行：
#   powershell -ExecutionPolicy Bypass -File "此資料夾\還原.ps1"
$list = Import-Csv -LiteralPath (Join-Path $PSScriptRoot '還原清單.csv') -Encoding UTF8
$n = 0
foreach ($m in $list) {
    if (-not (Test-Path -LiteralPath $m.Dest)) { continue }
    New-Item -ItemType Directory -Path (Split-Path $m.Source -Parent) -Force | Out-Null
    Move-Item -LiteralPath $m.Dest -Destination $m.Source -Force
    $n++
}
Write-Host "已還原 $n 個檔案。"
'@
[IO.File]::WriteAllText((Join-Path $ArchiveDir '還原.ps1'), $restore, (New-Object Text.UTF8Encoding $true))

Write-Host "`n已封存 $($done.Count) 個檔案到：$ArchiveDir" -ForegroundColor Green
Write-Host '開啟 MT5 確認 EA / 指標都正常。要全部搬回，執行封存資料夾裡的 還原.ps1。'
