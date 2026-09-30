<#
  Clean-MT5Terminal.ps1
  整理 %APPDATA%\MetaQuotes\Terminal：找出重複 / 舊版本檔案與已失效的終端機資料夾。

  預設只產生報告（不動任何檔案）。加 -Apply 才會把「建議移除」的項目
  「搬到」桌面的備份資料夾（保留原本路徑），不會直接刪除；確認 MT5 正常後再自行刪除備份。

  用法（PowerShell）：
    powershell -ExecutionPolicy Bypass -File .\Clean-MT5Terminal.ps1              # 只產生報告
    powershell -ExecutionPolicy Bypass -File .\Clean-MT5Terminal.ps1 -Apply       # 搬移建議移除的項目
    加 -IncludeOrphans：連「安裝位置已不存在」的終端機資料夾也一起搬移
#>
param(
    [string]$Root = (Join-Path $env:APPDATA 'MetaQuotes\Terminal'),
    [switch]$Apply,
    [switch]$IncludeOrphans
)

$ErrorActionPreference = 'Stop'
$stamp   = Get-Date -Format 'yyyyMMdd_HHmmss'
$desktop = [Environment]::GetFolderPath('Desktop')

if (-not (Test-Path $Root)) { Write-Host "找不到資料夾：$Root" -ForegroundColor Red; exit 1 }

if ($Apply) {
    $running = Get-Process -Name terminal64, terminal, metaeditor64, metaeditor, metatester64 -ErrorAction SilentlyContinue
    if ($running) {
        Write-Host '請先關閉所有 MT5 / MetaEditor 視窗再執行 -Apply：' -ForegroundColor Red
        $running | ForEach-Object { Write-Host "  $($_.ProcessName)  PID=$($_.Id)" }
        exit 1
    }
}

$items = New-Object System.Collections.Generic.List[object]
function Add-Item($category, $action, $path, $keep, $note) {
    $items.Add([pscustomobject]@{
        類別 = $category; 建議 = $action; 路徑 = $path; 保留的版本 = $keep; 說明 = $note
    })
}
function Get-Hash($p) { (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash }

$copyRx    = '^(?<base>.+?)(?: - 複製| - 副本| - Copy| copy|_copy|_複製)?(?: ?\((?<n>\d+)\))?$'
$versionRx = '^(?<base>.+?)[ _\-\.]?[vV](?<ver>\d+(?:[._]\d+)*)$'

# ---------- 1. 終端機資料夾（32 碼的資料夾名稱） ----------
$terminals = Get-ChildItem -LiteralPath $Root -Directory | Where-Object { $_.Name -match '^[0-9A-Fa-f]{32}$' }
foreach ($t in $terminals) {
    $originFile = Join-Path $t.FullName 'origin.txt'
    $origin = $null
    if (Test-Path -LiteralPath $originFile) {
        $origin = (Get-Content -LiteralPath $originFile -Encoding Unicode -Raw).Trim([char]0xFEFF, ' ', "`r", "`n")
    }
    $sizeMB = [math]::Round(((Get-ChildItem -LiteralPath $t.FullName -Recurse -File -ErrorAction SilentlyContinue |
               Measure-Object Length -Sum).Sum) / 1MB, 1)
    if (-not $origin) {
        Add-Item '終端機資料夾' '手動確認' $t.FullName '' "沒有 origin.txt，無法判斷屬於哪套 MT5（$sizeMB MB）"
    } elseif (Test-Path -LiteralPath $origin) {
        Add-Item '終端機資料夾' '保留' $t.FullName $origin "使用中的安裝（$sizeMB MB）"
    } else {
        $act = if ($IncludeOrphans) { '移除' } else { '建議移除(需 -IncludeOrphans)' }
        Add-Item '終端機資料夾' $act $t.FullName '' "安裝位置已不存在：$origin（$sizeMB MB）。裡面的 EA/指標若還要用，請先另存"
    }
}

# ---------- 2. 每個終端機的 MQL5 內：複本與舊版本 ----------
foreach ($t in $terminals) {
    $mql5 = Join-Path $t.FullName 'MQL5'
    if (-not (Test-Path -LiteralPath $mql5)) { continue }

    $files = Get-ChildItem -LiteralPath $mql5 -Recurse -File -ErrorAction SilentlyContinue |
             Where-Object { $_.FullName -notmatch '\\MQL5\\(Logs|Files)\\' }

    foreach ($dirGroup in ($files | Group-Object DirectoryName)) {
        $dirFiles = $dirGroup.Group

        # 2a. 「- 複製」「(1)」等複本
        foreach ($f in $dirFiles) {
            $m = [regex]::Match($f.BaseName, $copyRx)
            if (-not $m.Success -or $m.Groups['base'].Value -eq $f.BaseName) { continue }
            $origName = $m.Groups['base'].Value + $f.Extension
            $orig = $dirFiles | Where-Object { $_.Name -ieq $origName } | Select-Object -First 1
            if (-not $orig) {
                Add-Item '複本' '手動確認' $f.FullName '' "看起來是複本，但同資料夾沒有原檔 $origName"
            } elseif ((Get-Hash $f.FullName) -eq (Get-Hash $orig.FullName)) {
                Add-Item '複本' '移除' $f.FullName $orig.FullName '內容與原檔完全相同'
            } else {
                Add-Item '複本' '手動確認' $f.FullName $orig.FullName '檔名像複本但內容不同，可能有修改'
            }
        }

        # 2b. 同資料夾、同副檔名、只有版本號不同（xxx_v4 / xxx_v5）
        $versioned = foreach ($f in $dirFiles) {
            $m = [regex]::Match($f.BaseName, $versionRx)
            if ($m.Success) {
                $parts = @($m.Groups['ver'].Value -split '[._]' | ForEach-Object { [int]$_ })
                while ($parts.Count -lt 2) { $parts += 0 }
                [pscustomobject]@{ File = $f; Key = ($m.Groups['base'].Value.ToLower() + '|' + $f.Extension.ToLower())
                                   Ver = [version]($parts[0..([math]::Min(3, $parts.Count - 1))] -join '.') }
            }
        }
        foreach ($g in (@($versioned) | Where-Object { $_ } | Group-Object Key | Where-Object Count -gt 1)) {
            $sorted = $g.Group | Sort-Object Ver, { $_.File.LastWriteTime } -Descending
            $newest = $sorted[0].File
            foreach ($old in ($sorted | Select-Object -Skip 1)) {
                if ($old.File.Extension -ieq '.mqh') {
                    Add-Item '舊版本' '手動確認' $old.File.FullName $newest.FullName '.mqh 會被 EA 以檔名 #include，刪除可能導致重新編譯失敗'
                } else {
                    Add-Item '舊版本' '移除' $old.File.FullName $newest.FullName "較新版本：$($newest.Name)"
                }
            }
        }
    }

    # 2c. 同一個終端機內，同檔名同內容但放在不同資料夾（只列出，不動）
    $byName = $files | Where-Object { $_.Extension -in '.mq5', '.mqh', '.ex5' } | Group-Object Name | Where-Object Count -gt 1
    foreach ($g in $byName) {
        foreach ($hg in ($g.Group | Group-Object { Get-Hash $_.FullName } | Where-Object Count -gt 1)) {
            $list = $hg.Group | Sort-Object LastWriteTime -Descending
            foreach ($dup in ($list | Select-Object -Skip 1)) {
                Add-Item '不同資料夾重複' '手動確認' $dup.FullName $list[0].FullName '內容相同；可能被不同 EA 以相對路徑 include，請確認後再刪'
            }
        }
    }
}

# ---------- 3. 輸出報告 ----------
$report = Join-Path $desktop "MT5_清理報告_$stamp.csv"
$items | Export-Csv -LiteralPath $report -NoTypeInformation -Encoding UTF8

$summary = $items | Group-Object 類別, 建議 | Sort-Object Name
Write-Host "`n===== 整理結果 =====" -ForegroundColor Cyan
$summary | ForEach-Object { Write-Host ("{0,-40} {1,5}" -f $_.Name, $_.Count) }
Write-Host "`n完整報告：$report" -ForegroundColor Green

$toMove = $items | Where-Object 建議 -eq '移除'
if (-not $Apply) {
    Write-Host "`n目前只產生報告，沒有動任何檔案。共有 $($toMove.Count) 項標示為「移除」。" -ForegroundColor Yellow
    Write-Host '確認報告後，關閉 MT5，再加 -Apply 執行即可搬到備份資料夾。'
    exit 0
}

# ---------- 4. 搬到備份資料夾（不直接刪除） ----------
$backup = Join-Path $desktop "MT5_清理備份_$stamp"
$moved = 0
foreach ($it in $toMove) {
    if (-not (Test-Path -LiteralPath $it.路徑)) { continue }
    $rel  = $it.路徑.Substring($Root.TrimEnd('\').Length).TrimStart('\')
    $dest = Join-Path $backup $rel
    New-Item -ItemType Directory -Path (Split-Path $dest -Parent) -Force | Out-Null
    Move-Item -LiteralPath $it.路徑 -Destination $dest
    $moved++
}
Copy-Item -LiteralPath $report -Destination $backup -ErrorAction SilentlyContinue
Write-Host "`n已搬移 $moved 項到：$backup" -ForegroundColor Green
Write-Host '開啟 MT5 確認 EA / 指標都正常後，再把這個備份資料夾刪除；若有問題，把檔案搬回原位置即可。'
