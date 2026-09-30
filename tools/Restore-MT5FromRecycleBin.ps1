<#
  Restore-MT5FromRecycleBin.ps1
  把資源回收筒裡「原本位於 %APPDATA%\MetaQuotes\Terminal」的檔案全部還原回原位置。
  原位置已有同名檔案的會略過，不會覆蓋。

  用法（先關閉 MT5 / MetaEditor）：
    powershell -NoProfile -ExecutionPolicy Bypass -File "路徑\Restore-MT5FromRecycleBin.ps1"
#>
param(
    [string]$Root = (Join-Path $env:APPDATA 'MetaQuotes\Terminal')
)

$shell = New-Object -ComObject Shell.Application
$bin   = $shell.Namespace(10)          # 10 = 資源回收筒
$items = @($bin.Items())
$rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'

Write-Host "資源回收筒共有 $($items.Count) 個項目，尋找來自 $Root 的檔案..." -ForegroundColor Cyan

$restored = 0; $skipped = 0; $failed = 0
foreach ($item in $items) {
    $from = $item.ExtendedProperty('System.Recycle.DeletedFrom')
    if (-not $from) { $from = $bin.GetDetailsOf($item, 1) }      # 備用：「原始位置」欄
    if (-not $from) { continue }
    $from = $from.TrimEnd('\')
    if (-not ($from + '\').StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) { continue }

    $src  = $item.Path                                            # C:\$Recycle.Bin\<SID>\$Rxxxx.ext
    $name = $item.Name                                            # 可能被隱藏副檔名
    $ext  = [IO.Path]::GetExtension($src)
    if ($ext -and -not $name.EndsWith($ext, [StringComparison]::OrdinalIgnoreCase)) { $name += $ext }
    $dest = Join-Path $from $name

    if (Test-Path -LiteralPath $dest) { $skipped++; continue }
    New-Item -ItemType Directory -Path $from -Force | Out-Null

    try { $item.InvokeVerb('undelete') } catch { }               # Windows 內建的「還原」
    if (-not (Test-Path -LiteralPath $dest)) {
        try {                                                     # 備用：直接搬回，並移除回收筒的資訊檔
            Move-Item -LiteralPath $src -Destination $dest -ErrorAction Stop
            $info = Join-Path (Split-Path $src -Parent) ('$I' + (Split-Path $src -Leaf).Substring(2))
            Remove-Item -LiteralPath $info -Force -ErrorAction SilentlyContinue
        } catch {
            $failed++
            Write-Host "還原失敗：$dest  ($($_.Exception.Message))" -ForegroundColor Red
            continue
        }
    }
    $restored++
    if ($restored % 200 -eq 0) { Write-Host "  已還原 $restored 個..." }
}

Write-Host ''
Write-Host "完成：還原 $restored 個，原位置已存在而略過 $skipped 個，失敗 $failed 個。" -ForegroundColor Green
if ($restored -eq 0 -and $skipped -eq 0) {
    Write-Host '回收筒裡沒有來自 MT5 資料夾的檔案（可能已清空，或當初是用 -Permanent 永久刪除）。' -ForegroundColor Yellow
}
Read-Host '按 Enter 關閉'
