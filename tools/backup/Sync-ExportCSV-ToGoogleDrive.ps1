<#
.SYNOPSIS
    Mirrors a local export folder into a Google Drive for Desktop mounted drive letter.

.DESCRIPTION
    Wraps Robocopy in /MIR (mirror) mode to one-way sync -Source into -Destination.
    Intended use: -Source is a local export folder (e.g. an EA's CSV export directory)
    and -Destination is a folder inside a Google Drive for Desktop mounted drive
    (e.g. G:\ExportCSV). Google Drive for Desktop then uploads/syncs that folder to
    the cloud on its own; this script only handles the local-to-local copy.

    Pass -Source and -Destination explicitly (no defaults) so this script file stays
    plain ASCII and works regardless of the system code page - put any non-ASCII
    path (e.g. Chinese folder names) on the command line / Task Scheduler action
    instead of inside this file.

.PARAMETER Source
    Folder to copy from. Must already exist.

.PARAMETER Destination
    Folder to copy into. Created if missing. Should live under a mounted Google
    Drive for Desktop drive letter so Google Drive picks up the changes.

.PARAMETER LogDir
    Where to write per-run logs. Defaults to a "logs" folder next to this script.

.PARAMETER KeepLogDays
    Log files older than this many days are deleted after each run. Default 30.

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File Sync-ExportCSV-ToGoogleDrive.ps1 `
        -Source "D:\ExportCSV" -Destination "G:\ExportCSV"

.EXAMPLE
    # Task Scheduler action (Program/script + Arguments):
    #   powershell.exe
    #   -ExecutionPolicy Bypass -File "C:\path\to\Sync-ExportCSV-ToGoogleDrive.ps1" -Source "D:\..." -Destination "G:\..."
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Source,

    [Parameter(Mandatory = $true)]
    [string]$Destination,

    [string]$LogDir = (Join-Path $PSScriptRoot "logs"),

    [int]$KeepLogDays = 30
)

$ErrorActionPreference = "Stop"

function Write-Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Write-Host $line
    Add-Content -Path $script:SummaryLog -Value $line
}

if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
    throw "Source folder not found: $Source"
}

if (-not (Test-Path -LiteralPath $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

if (-not (Test-Path -LiteralPath $Destination)) {
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
}

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$script:SummaryLog = Join-Path $LogDir "sync_summary.log"
$robocopyLog = Join-Path $LogDir "robocopy_$timestamp.log"

Write-Log "Starting sync: '$Source' -> '$Destination'"

$robocopyArgs = @(
    "`"$Source`"",
    "`"$Destination`"",
    "/MIR",       # mirror source to destination (adds, updates, and removes files)
    "/Z",         # restartable mode, safer over flaky/streamed drives
    "/R:3",       # retry 3 times per file
    "/W:5",       # wait 5 seconds between retries
    "/NFL", "/NDL", "/NP",  # quiet per-file/per-dir noise, keep the log small
    "/LOG:`"$robocopyLog`""
)

$process = Start-Process -FilePath "robocopy.exe" -ArgumentList $robocopyArgs -NoNewWindow -Wait -PassThru
$exitCode = $process.ExitCode

# Robocopy exit codes 0-7 are success (see /? for the bit meanings); 8+ means failure.
if ($exitCode -ge 8) {
    Write-Log "FAILED (robocopy exit code $exitCode). Details: $robocopyLog"
    exit 1
}

Write-Log "OK (robocopy exit code $exitCode). Details: $robocopyLog"

Get-ChildItem -Path $LogDir -Filter "robocopy_*.log" |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$KeepLogDays) } |
    Remove-Item -Force

exit 0
