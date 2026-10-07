#requires -Version 5.1
# ============================================================
#  杀戮尖塔 存档助手 - 控制台版（只有记录功能，没有界面）
#
#  每 N 秒检查一次游戏的 saves 目录，只要存档有变化就整份拷贝一份
#  带时间戳的快照到快照目录，方便事后回档。
#
#  用法：
#    - 双击 sts_save_watch.bat
#    - 或 powershell -ExecutionPolicy Bypass -File sts_save_watch.ps1 -GameDir "D:\...\Slay the Spire"
#
#  游戏目录的查找顺序：-GameDir 参数 → settings.txt 里的 GameDir → 常见 Steam 路径
# ============================================================

param(
    [string]$GameDir = '',
    [int]$IntervalSeconds = 5,
    [int]$KeepLast = 300
)

$scriptDir    = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$settingsFile = Join-Path $scriptDir 'settings.txt'

function Test-GameDir {
    param([string]$Dir)
    if (-not $Dir) { return $false }
    if (-not (Test-Path -LiteralPath $Dir)) { return $false }
    return (Test-Path -LiteralPath (Join-Path $Dir 'saves'))
}

function Find-GameDir {
    $cands = New-Object System.Collections.ArrayList
    foreach ($pf in @(${env:ProgramFiles(x86)}, $env:ProgramFiles, 'C:\Program Files (x86)', 'C:\Program Files')) {
        if ($pf) { [void]$cands.Add((Join-Path $pf 'Steam\steamapps\common\Slay the Spire')) }
    }
    foreach ($d in @('C:', 'D:', 'E:', 'F:', 'G:')) {
        foreach ($sub in @('Steam', 'SteamLibrary', 'Games\Steam', 'SteamApps')) {
            [void]$cands.Add(('{0}\{1}\steamapps\common\Slay the Spire' -f $d, $sub))
        }
    }
    foreach ($p in $cands) { if (Test-GameDir $p) { return $p } }
    return ''
}

$historyDir = Join-Path ([Environment]::GetFolderPath('Desktop')) 'sts_save_history'

if (Test-Path -LiteralPath $settingsFile) {
    foreach ($line in (Get-Content -LiteralPath $settingsFile -ErrorAction SilentlyContinue)) {
        if ($line -match '^\s*([^#=]+?)\s*=\s*(.+?)\s*$') {
            if ($Matches[1] -eq 'GameDir' -and -not $GameDir) { $GameDir = $Matches[2] }
            if ($Matches[1] -eq 'HistoryDir') { $historyDir = $Matches[2] }
        }
    }
}
if (-not $GameDir) { $GameDir = Find-GameDir }

if (-not (Test-GameDir $GameDir)) {
    Write-Host '[X] 没有找到游戏目录（该目录下必须有 saves 文件夹）。' -ForegroundColor Red
    Write-Host '    请先运行图形版「杀戮尖塔存档助手.bat」配置一次，'
    Write-Host '    或用参数指定：-GameDir "D:\Steam\steamapps\common\Slay the Spire"'
    exit 1
}

$savesDir = Join-Path $GameDir 'saves'
New-Item -ItemType Directory -Force -Path $historyDir | Out-Null

Write-Host '杀戮尖塔 存档助手 (控制台版)'
Write-Host ("  游戏目录 : {0}" -f $GameDir)
Write-Host ("  快照目录 : {0}" -f $historyDir)
Write-Host ("  间隔     : {0} 秒，最多保留 {1} 份" -f $IntervalSeconds, $KeepLast)
Write-Host '  保持本窗口开着即可，Ctrl+C 或关窗口结束。'
Write-Host ''

function Get-SaveSignature($files) {
    ($files | Sort-Object Name | ForEach-Object {
        '{0}:{1}:{2}' -f $_.Name, $_.Length, $_.LastWriteTimeUtc.Ticks
    }) -join '|'
}

function Get-NewestSnapshotSignature {
    $newest = Get-ChildItem -LiteralPath $historyDir -Directory -ErrorAction SilentlyContinue |
              Where-Object { $_.Name -notlike '_*' } | Sort-Object Name -Descending | Select-Object -First 1
    if (-not $newest) { return '' }
    Get-SaveSignature @(Get-ChildItem -LiteralPath $newest.FullName -File -ErrorAction SilentlyContinue)
}

$lastSig = ''
while ($true) {
    $made = $false
    try {
        $files = @(Get-ChildItem -LiteralPath $savesDir -File -ErrorAction Stop)
        if ($files.Count -gt 0) {
            $sig = Get-SaveSignature $files
            if ($sig -ne $lastSig) {
                Start-Sleep -Milliseconds 500          # 等游戏写完
                $files = @(Get-ChildItem -LiteralPath $savesDir -File -ErrorAction Stop)
                $sig = Get-SaveSignature $files
                if ($sig -ne (Get-NewestSnapshotSignature)) {
                    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
                    $sub   = Join-Path $historyDir $stamp
                    New-Item -ItemType Directory -Force -Path $sub | Out-Null
                    foreach ($f in $files) {
                        Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $sub $f.Name) -Force
                    }
                    Write-Host ("[{0}] 已快照: {1}" -f $stamp, (($files | Sort-Object Name | ForEach-Object { $_.Name }) -join ', '))
                    $made = $true

                    $all = @(Get-ChildItem -LiteralPath $historyDir -Directory | Sort-Object Name -Descending)
                    if ($all.Count -gt $KeepLast) {
                        $all | Select-Object -Skip $KeepLast | ForEach-Object {
                            Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
                        }
                    }
                }
                $lastSig = $sig
            }
        }
    } catch {
        Write-Host ("等待 saves 目录... ({0})" -f $_.Exception.Message)
    }
    if (-not $made) { Start-Sleep -Seconds $IntervalSeconds }
}
