#requires -Version 5.1
# ============================================================
#  杀戮尖塔 存档助手 (Slay the Spire Save Assistant) - GUI
#
#  - 自动记录存档快照：saves 目录一变就整份拷贝一份带时间戳的快照
#  - 可视化浏览所有快照，并标注「当时是什么房间 / 什么怪 / 什么事件」
#    （解析游戏的 SlayTheSpire.log，以及游戏重启后归档的 *.log.zip）
#  - 选中任意一份 → 一键还原（还原前自动备份当前存档）
#
#  完全独立运行：Windows 自带 PowerShell 即可，无需安装任何东西。
#  双击同目录的「杀戮尖塔存档助手.bat」启动。
#
#  仅做存档的复制/还原，不修改游戏本体文件。
# ============================================================

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.IO.Compression.FileSystem

$ErrorActionPreference = 'Stop'

# ---------- 基本路径 ----------
$script:ScriptDir    = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$script:SettingsFile = Join-Path $script:ScriptDir 'settings.txt'
$script:AppLog       = Join-Path $script:ScriptDir 'sts_save_gui.log'

# ---------- 可调参数 ----------
$script:KeepLast = 300          # 最多保留多少份快照
$script:Interval = 5            # 自动快照间隔（秒）
$script:ZipCount = 8            # 解析最近几个归档日志

$script:GameDir      = ''
$script:SavesDir     = ''
$script:LogsDir      = ''
$script:LogPath      = ''
$script:HistDir      = ''
$script:LastSig      = ''
$script:LastLogCount = -1
$script:CurCache     = @{ Mtime = [datetime]::MinValue; Events = @(); LineCount = 0; Length = 0 }
$script:ZipCache     = @{ Stamp = ''; Events = @() }
$script:BucketStamp  = ''
$script:Buckets      = @{}
$script:LabelCache   = @{}

function Write-AppLog {
    param([string]$Message)
    try {
        Add-Content -LiteralPath $script:AppLog -Value ('{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message) -Encoding UTF8
    } catch { }
}

# ---------- 配置文件 / 游戏目录 ----------
function Read-Settings {
    $cfg = @{}
    if (Test-Path -LiteralPath $script:SettingsFile) {
        foreach ($line in (Get-Content -LiteralPath $script:SettingsFile -ErrorAction SilentlyContinue)) {
            if ($line -match '^\s*([^#=]+?)\s*=\s*(.+?)\s*$') { $cfg[$Matches[1]] = $Matches[2] }
        }
    }
    return $cfg
}

function Save-Setting {
    param([string]$Key, [string]$Value)
    $cfg = Read-Settings
    $cfg[$Key] = $Value
    $out = @('# 杀戮尖塔存档助手 配置（可手动编辑；删除本文件会重新自动查找）')
    foreach ($k in ($cfg.Keys | Sort-Object)) { $out += ('{0}={1}' -f $k, $cfg[$k]) }
    Set-Content -LiteralPath $script:SettingsFile -Value $out -Encoding UTF8
}

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
    [void]$cands.Add((Join-Path $script:ScriptDir 'Slay the Spire'))
    foreach ($p in $cands) { if (Test-GameDir $p) { return $p } }

    # 从 Steam 的 libraryfolders.vdf 里找其他库位置
    foreach ($root in @('C:\Program Files (x86)\Steam', 'C:\Steam', 'D:\Steam', 'D:\SteamLibrary', 'E:\Steam', 'E:\SteamLibrary', 'F:\SteamLibrary')) {
        $vdf = Join-Path $root 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $vdf) {
            foreach ($line in (Get-Content -LiteralPath $vdf -ErrorAction SilentlyContinue)) {
                if ($line -match '"path"\s+"(.+?)"') {
                    $lib = $Matches[1] -replace '\\\\', '\'
                    $p = Join-Path $lib 'steamapps\common\Slay the Spire'
                    if (Test-GameDir $p) { return $p }
                }
            }
        }
    }
    return ''
}

function Select-GameDirDialog {
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = '请选择《杀戮尖塔》的游戏目录（里面应有 saves 文件夹）'
    $dlg.ShowNewFolderButton = $false
    if ($script:GameDir -and (Test-Path -LiteralPath $script:GameDir)) { $dlg.SelectedPath = $script:GameDir }
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.SelectedPath }
    return ''
}

function Initialize-GameDir {
    $cfg = Read-Settings
    if ($cfg.ContainsKey('GameDir')) { $script:GameDir = $cfg['GameDir'] }
    if (-not (Test-GameDir $script:GameDir)) {
        $found = Find-GameDir
        if (Test-GameDir $found) { $script:GameDir = $found }
    }
    if (-not (Test-GameDir $script:GameDir)) {
        [void][System.Windows.Forms.MessageBox]::Show(
            "没有自动找到《杀戮尖塔》的游戏目录。`n`n下一步会让你手动选择一次，选择后会记住。",
            '需要选择游戏目录', 'OK', 'Information')
        $picked = Select-GameDirDialog
        if ($picked -and (Test-GameDir $picked)) {
            $script:GameDir = $picked
            Save-Setting -Key 'GameDir' -Value $picked
        } else {
            [void][System.Windows.Forms.MessageBox]::Show(
                "没有选择有效的游戏目录（该目录下必须有 saves 文件夹）。`n`n程序将退出。",
                '无法继续', 'OK', 'Error')
            Write-AppLog 'ERROR: no valid game dir'
            return $false
        }
    }
    $script:SavesDir = Join-Path $script:GameDir 'saves'
    $script:LogsDir  = Join-Path $script:GameDir 'sendToDevs\logs'
    $script:LogPath  = Join-Path $script:LogsDir 'SlayTheSpire.log'

    if (-not $script:HistDir) {
        if ($cfg.ContainsKey('HistoryDir') -and $cfg['HistoryDir']) { $script:HistDir = $cfg['HistoryDir'] }
        else { $script:HistDir = Join-Path ([Environment]::GetFolderPath('Desktop')) 'sts_save_history' }
    }
    New-Item -ItemType Directory -Force -Path $script:HistDir | Out-Null
    Write-AppLog ('game dir = {0}' -f $script:GameDir)
    Write-AppLog ('history  = {0}' -f $script:HistDir)
    return $true
}

# ---------- 快照 ----------
function Get-DirSignature {
    param([string]$Dir)
    $files = @(Get-ChildItem -LiteralPath $Dir -File -ErrorAction SilentlyContinue)
    if ($files.Count -eq 0) { return '' }
    (($files | Sort-Object Name | ForEach-Object { '{0}:{1}:{2}' -f $_.Name, $_.Length, $_.LastWriteTimeUtc.Ticks }) -join '|')
}

function Get-NewestSnapshotSignature {
    $newest = Get-ChildItem -LiteralPath $script:HistDir -Directory -ErrorAction SilentlyContinue |
              Where-Object { $_.Name -notlike '_*' } | Sort-Object Name -Descending | Select-Object -First 1
    if (-not $newest) { return '' }
    Get-DirSignature $newest.FullName
}

function New-Snapshot {
    param([switch]$Force)
    $sig = Get-DirSignature $script:SavesDir
    if (-not $sig) { return $null }
    if (-not $Force -and $sig -eq $script:LastSig) { return $null }
    if ((Get-NewestSnapshotSignature) -eq $sig) { $script:LastSig = $sig; return $null }

    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $sub = Join-Path $script:HistDir $stamp
    New-Item -ItemType Directory -Force -Path $sub | Out-Null
    Get-ChildItem -LiteralPath $script:SavesDir -File | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $sub $_.Name) -Force
    }
    $script:LastSig = $sig

    $all = @(Get-ChildItem -LiteralPath $script:HistDir -Directory | Sort-Object Name -Descending)
    if ($all.Count -gt $script:KeepLast) {
        $all | Select-Object -Skip $script:KeepLast | ForEach-Object {
            Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    Write-AppLog ('snapshot -> {0}' -f $sub)
    return $sub
}

# ---------- 从游戏日志推断房间 ----------
function Parse-LogLines {
    param([string[]]$Lines, [datetime]$AnchorDate, [datetime]$RefUtcTime)
    $out = New-Object System.Collections.ArrayList
    if (-not $Lines -or $Lines.Count -eq 0) { return @() }

    # 日志写的是 UTC 还是本地时间？
    # 比较「最后一行时间」与「文件修改时间」：差≈0 → 日志是 UTC；差≈时区偏移 → 日志是本地时间。
    # （归档日志是几分钟后才打包的，所以不能用分钟级阈值判断）
    $assumeUtc = $true
    $offMin = [math]::Abs([TimeZoneInfo]::Local.GetUtcOffset([datetime]::UtcNow).TotalMinutes)
    for ($i = $Lines.Count - 1; $i -ge 0; $i--) {
        if ($Lines[$i] -match '^(\d{2}):(\d{2}):(\d{2})\.(\d{3})') {
            $t = $AnchorDate.AddHours([int]$Matches[1]).AddMinutes([int]$Matches[2]).AddSeconds([int]$Matches[3])
            $t = [datetime]::SpecifyKind($t, 'Utc')
            $diff = [math]::Abs(($RefUtcTime - $t).TotalMinutes)
            $assumeUtc = ($diff -le [math]::Abs($diff - $offMin))
            break
        }
    }

    foreach ($line in $Lines) {
        if ($line -notmatch '^(\d{2}):(\d{2}):(\d{2})\.(\d{3})\s+\S+\s+([\w\.]+)>\s*(.*)$') { continue }
        $t = $AnchorDate.AddHours([int]$Matches[1]).AddMinutes([int]$Matches[2]).AddSeconds([int]$Matches[3])
        if ($assumeUtc) { $t = [datetime]::SpecifyKind($t, 'Utc').ToLocalTime() }
        $msg = $Matches[6]
        $kind = $null; $val = $null
        if ($msg -match '^Next Room: (.+)$') { $kind = 'room'; $val = $Matches[1].Split('.')[-1] }
        elseif ($msg -match '^GENERATING ROOM: (\w+)') { $kind = 'gen'; $val = $Matches[1] }
        elseif ($msg -match '^MONSTER: (.+)$') { $kind = 'monster'; $val = $Matches[1] }
        elseif ($msg -match '^Removed event: (.+?) from pool\.') { $kind = 'event'; $val = $Matches[1] }
        if ($kind) { [void]$out.Add([pscustomobject]@{ Time = $t; Kind = $kind; Value = $val }) }
    }
    return $out.ToArray()
}

function Get-CurrentLogEvents {
    $it = Get-Item -LiteralPath $script:LogPath -ErrorAction SilentlyContinue
    if (-not $it) { return @() }
    if ($it.LastWriteTime -eq $script:CurCache.Mtime) { return $script:CurCache.Events }

    $lines = @(Get-Content -LiteralPath $it.FullName -ErrorAction SilentlyContinue)
    $grew = ($script:CurCache.LineCount -gt 0 -and $lines.Count -ge $script:CurCache.LineCount -and $it.Length -ge $script:CurCache.Length)
    if ($grew) {
        $new = @($lines | Select-Object -Skip $script:CurCache.LineCount)
        $ev = @($script:CurCache.Events) + @(Parse-LogLines -Lines $new -AnchorDate $it.LastWriteTime.Date -RefUtcTime $it.LastWriteTimeUtc)
    } else {
        $ev = @(Parse-LogLines -Lines $lines -AnchorDate $it.LastWriteTime.Date -RefUtcTime $it.LastWriteTimeUtc)
    }
    $script:CurCache = @{ Mtime = $it.LastWriteTime; Events = $ev; LineCount = $lines.Count; Length = $it.Length }
    return $ev
}

function Get-ZipLogEvents {
    $zips = @(Get-ChildItem -LiteralPath $script:LogsDir -Filter '*.log.zip' -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime -Descending | Select-Object -First $script:ZipCount)
    $stamp = ($zips | ForEach-Object { $_.Name + ':' + $_.LastWriteTimeUtc.Ticks }) -join '|'
    if ($stamp -eq $script:ZipCache.Stamp) { return $script:ZipCache.Events }

    $ev = New-Object System.Collections.ArrayList
    foreach ($z in $zips) {
        try {
            $zip = [System.IO.Compression.ZipFile]::OpenRead($z.FullName)
            foreach ($entry in $zip.Entries) {
                if ($entry.Length -le 0) { continue }
                $sr = New-Object System.IO.StreamReader($entry.Open(), [System.Text.Encoding]::UTF8)
                $text = $sr.ReadToEnd()
                $sr.Dispose()
                $parsed = Parse-LogLines -Lines ($text -split "`r?`n") -AnchorDate $z.LastWriteTime.Date -RefUtcTime $z.LastWriteTime.ToUniversalTime()
                foreach ($e in $parsed) { [void]$ev.Add($e) }
            }
            $zip.Dispose()
        } catch { }
    }
    $script:ZipCache = @{ Stamp = $stamp; Events = $ev.ToArray() }
    return $script:ZipCache.Events
}

function Get-EventBuckets {
    $cur = @(Get-CurrentLogEvents)
    $zip = @(Get-ZipLogEvents)
    $key = '{0}|{1}|{2}' -f $script:CurCache.Mtime.Ticks, $cur.Count, $script:ZipCache.Stamp
    if ($key -eq $script:BucketStamp) { return $script:Buckets }

    $b = @{}
    foreach ($e in ($cur + $zip)) {
        $k = $e.Time.ToString('yyyyMMddHHmm')
        if (-not $b.ContainsKey($k)) { $b[$k] = New-Object System.Collections.ArrayList }
        [void]$b[$k].Add($e)
    }
    $script:Buckets = $b
    $script:BucketStamp = $key
    $script:LabelCache = @{}
    return $b
}

function Get-RoomLabel {
    param([datetime]$Time)
    try {
        $ticks = $Time.Ticks
        if ($script:LabelCache.ContainsKey($ticks)) { return $script:LabelCache[$ticks] }
        $b = Get-EventBuckets
        $win = New-Object System.Collections.ArrayList
        for ($m = 0; $m -le 4; $m++) {
            $k = $Time.AddMinutes(-$m).ToString('yyyyMMddHHmm')
            if ($b.ContainsKey($k)) { foreach ($e in $b[$k]) { [void]$win.Add($e) } }
        }
        $k = $Time.AddMinutes(1).ToString('yyyyMMddHHmm')
        if ($b.ContainsKey($k)) { foreach ($e in $b[$k]) { [void]$win.Add($e) } }
        # 桶是按分钟拼接的，必须重新按时间排序，否则 -Last 1 取到的不是最新的房间
        $win = @($win | Sort-Object Time)

        $label = '（未知）'
        $cand = @($win | Where-Object { $_.Time -le $Time.AddSeconds(3) -and $_.Time -ge $Time.AddSeconds(-240) })
        if ($cand.Count -gt 0) {
            $room = $cand | Where-Object { $_.Kind -eq 'room' } | Select-Object -Last 1
            if ($room) {
                $rmap = @{ 'MonsterRoom' = '战斗'; 'MonsterRoomElite' = '精英'; 'EventRoom' = '事件(?)'; 'RestRoom' = '篝火'; 'TreasureRoom' = '宝箱'; 'ShopRoom' = '商店'; 'BossRoom' = 'Boss'; 'VictoryRoom' = '胜利' }
                $label = $rmap[$room.Value]
                if (-not $label) { $label = [string]$room.Value }
                $near = @($cand | Where-Object { $_.Time -ge $room.Time.AddSeconds(-1) -and $_.Time -le $room.Time.AddSeconds(4) })
                $gen = $near | Where-Object { $_.Kind -eq 'gen' } | Select-Object -Last 1
                if ($gen) {
                    $gmap = @{ 'MONSTER' = '战斗'; 'EVENT' = '事件(?)'; 'SHOP' = '商店'; 'TREASURE' = '宝箱'; 'ELITE' = '精英'; 'BOSS' = 'Boss' }
                    $label = $gmap[$gen.Value]
                    if (-not $label) { $label = [string]$gen.Value }
                }
                # 怪物/事件名：取「进入房间」到「写入存档」之间最后一条（读档重进的战斗也能标出来）
                $span = @($cand | Where-Object { $_.Time -ge $room.Time.AddSeconds(-1) })
                $detail = $span | Where-Object { $_.Kind -eq 'monster' -or $_.Kind -eq 'event' } | Select-Object -Last 1
                if ($detail) { $label = '{0} · {1}' -f $label, $detail.Value }
            }
        }
        $script:LabelCache[$ticks] = $label
        return $label
    } catch { return '（未知）' }
}

# ---------- 界面 ----------
[void][System.Windows.Forms.Application]::EnableVisualStyles()

if (-not (Initialize-GameDir)) {
    [void][System.Windows.Forms.MessageBox]::Show('没有可用的游戏目录，程序退出。', '杀戮尖塔存档助手', 'OK', 'Error')
    exit 1
}

$form = New-Object System.Windows.Forms.Form
$form.Text = '杀戮尖塔 存档助手'
$form.ClientSize = New-Object System.Drawing.Size(900, 566)
$form.StartPosition = 'CenterScreen'
$form.MinimumSize = New-Object System.Drawing.Size(780, 430)
try { $form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9) } catch { }

$script:lblCurrent = New-Object System.Windows.Forms.Label
$script:lblCurrent.Location = New-Object System.Drawing.Point(12, 12)
$script:lblCurrent.Size = New-Object System.Drawing.Size(876, 20)
$script:lblCurrent.Text = '当前存档：读取中…'

$script:btnRefresh = New-Object System.Windows.Forms.Button
$script:btnRefresh.Text = '刷新 (F5)'
$script:btnRefresh.Location = New-Object System.Drawing.Point(12, 38)
$script:btnRefresh.Size = New-Object System.Drawing.Size(96, 28)

$script:btnSnap = New-Object System.Windows.Forms.Button
$script:btnSnap.Text = '立即快照'
$script:btnSnap.Location = New-Object System.Drawing.Point(114, 38)
$script:btnSnap.Size = New-Object System.Drawing.Size(96, 28)

$script:chkAuto = New-Object System.Windows.Forms.CheckBox
$script:chkAuto.Text = ('自动快照（每 {0} 秒）' -f $script:Interval)
$script:chkAuto.Location = New-Object System.Drawing.Point(222, 43)
$script:chkAuto.Size = New-Object System.Drawing.Size(170, 22)
$script:chkAuto.Checked = $true

$script:btnOpenHist = New-Object System.Windows.Forms.Button
$script:btnOpenHist.Text = '打开快照文件夹'
$script:btnOpenHist.Location = New-Object System.Drawing.Point(404, 38)
$script:btnOpenHist.Size = New-Object System.Drawing.Size(130, 28)

$script:btnOpenSaves = New-Object System.Windows.Forms.Button
$script:btnOpenSaves.Text = '打开游戏存档夹'
$script:btnOpenSaves.Location = New-Object System.Drawing.Point(540, 38)
$script:btnOpenSaves.Size = New-Object System.Drawing.Size(130, 28)

$script:btnGameDir = New-Object System.Windows.Forms.Button
$script:btnGameDir.Text = '切换游戏目录'
$script:btnGameDir.Location = New-Object System.Drawing.Point(676, 38)
$script:btnGameDir.Size = New-Object System.Drawing.Size(110, 28)

$script:lv = New-Object System.Windows.Forms.ListView
$script:lv.Location = New-Object System.Drawing.Point(12, 76)
$script:lv.Size = New-Object System.Drawing.Size(876, 404)
$script:lv.View = 'Details'
$script:lv.FullRowSelect = $true
$script:lv.GridLines = $true
$script:lv.MultiSelect = $false
$script:lv.HideSelection = $false
$script:lv.Anchor = 'Top,Left,Right,Bottom'
[void]$script:lv.Columns.Add('存档时间（游戏写入时刻）', 180)
[void]$script:lv.Columns.Add('当时所在（按游戏日志推断）', 320)
[void]$script:lv.Columns.Add('大小', 130)
[void]$script:lv.Columns.Add('快照目录', 220)

$script:btnRestore = New-Object System.Windows.Forms.Button
$script:btnRestore.Text = '还原到这个存档'
$script:btnRestore.Location = New-Object System.Drawing.Point(12, 490)
$script:btnRestore.Size = New-Object System.Drawing.Size(170, 32)
$script:btnRestore.Anchor = 'Bottom,Left'
$script:btnRestore.Font = New-Object System.Drawing.Font($form.Font, [System.Drawing.FontStyle]::Bold)

$script:lblHint = New-Object System.Windows.Forms.Label
$script:lblHint.Location = New-Object System.Drawing.Point(192, 494)
$script:lblHint.Size = New-Object System.Drawing.Size(696, 30)
$script:lblHint.Anchor = 'Bottom,Left,Right'
$script:lblHint.Text = '选中一行 → 点「还原到这个存档」（游戏必须完全退出）。还原前会自动备份当前存档。'

$script:lblStatus = New-Object System.Windows.Forms.Label
$script:lblStatus.Location = New-Object System.Drawing.Point(12, 534)
$script:lblStatus.Size = New-Object System.Drawing.Size(876, 20)
$script:lblStatus.Anchor = 'Bottom,Left,Right'
$script:lblStatus.ForeColor = [System.Drawing.Color]::DimGray
$script:lblStatus.Text = '就绪'

[void]$form.Controls.Add($script:lblCurrent)
[void]$form.Controls.Add($script:btnRefresh)
[void]$form.Controls.Add($script:btnSnap)
[void]$form.Controls.Add($script:chkAuto)
[void]$form.Controls.Add($script:btnOpenHist)
[void]$form.Controls.Add($script:btnOpenSaves)
[void]$form.Controls.Add($script:btnGameDir)
[void]$form.Controls.Add($script:lv)
[void]$form.Controls.Add($script:btnRestore)
[void]$form.Controls.Add($script:lblHint)
[void]$form.Controls.Add($script:lblStatus)

# ---------- 逻辑 ----------
function Get-GameRunning {
    $p = @(Get-Process -Name SlayTheSpire, java, javaw -ErrorAction SilentlyContinue)
    return ($p.Count -gt 0)
}

function Update-List {
    $selected = ''
    if ($script:lv.SelectedItems.Count -gt 0) { $selected = [string]$script:lv.SelectedItems[0].Tag }
    $script:lv.BeginUpdate()
    $script:lv.Items.Clear()

    $saves = @(Get-ChildItem -LiteralPath $script:SavesDir -File -ErrorAction SilentlyContinue)
    if ($saves.Count -gt 0) {
        $main = $saves | Where-Object { $_.Name -like '*.autosave' } | Select-Object -First 1
        if (-not $main) { $main = $saves[0] }
        $script:lblCurrent.Text = '当前存档：{0}   [{1}]' -f $main.LastWriteTime.ToString('MM-dd HH:mm:ss'), (Get-RoomLabel $main.LastWriteTime)
    } else {
        $script:lblCurrent.Text = '当前存档：没有找到存档文件'
    }

    $dirs = @(Get-ChildItem -LiteralPath $script:HistDir -Directory -ErrorAction SilentlyContinue)
    $rows = New-Object System.Collections.ArrayList
    foreach ($d in $dirs) {
        $files = @(Get-ChildItem -LiteralPath $d.FullName -File -ErrorAction SilentlyContinue)
        if ($files.Count -eq 0) { continue }
        $main = $files | Where-Object { $_.Name -like '*.autosave' } | Select-Object -First 1
        if (-not $main) { $main = $files[0] }
        [void]$rows.Add([pscustomobject]@{
            Dir   = $d.FullName
            Time  = $main.LastWriteTime
            Label = (Get-RoomLabel $main.LastWriteTime)
            Size  = ($files | Measure-Object -Property Length -Sum).Sum
            Count = $files.Count
        })
    }

    foreach ($r in ($rows | Sort-Object Time -Descending)) {
        $it = New-Object System.Windows.Forms.ListViewItem($r.Time.ToString('MM-dd HH:mm:ss'))
        [void]$it.SubItems.Add($r.Label)
        [void]$it.SubItems.Add(('{0:N0} 字节 / {1} 个文件' -f $r.Size, $r.Count))
        [void]$it.SubItems.Add([System.IO.Path]::GetFileName($r.Dir))
        $it.Tag = $r.Dir
        [void]$script:lv.Items.Add($it)
        if ($selected -and $r.Dir -eq $selected) { $it.Selected = $true }
    }
    $script:lv.EndUpdate()

    if ($script:LastLogCount -ne $rows.Count) {
        $script:LastLogCount = $rows.Count
        $desc = @($rows | Sort-Object Time -Descending) | Select-Object -First 12
        Write-AppLog ('rows: ' + (($desc | ForEach-Object { '{0}={1}' -f $_.Time.ToString('MM-dd HH:mm:ss'), $_.Label }) -join ' ; '))
    }

    $last = ''
    if ($rows.Count -gt 0) { $last = ($rows | Sort-Object Time -Descending | Select-Object -First 1).Time.ToString('HH:mm:ss') }
    $script:lblStatus.Text = '游戏目录：{0} · 共 {1} 份快照 · 最后记录 {2} · 游戏：{3}' -f `
        $script:GameDir, $rows.Count, $last, $(if (Get-GameRunning) { '运行中（还原前请先退出游戏）' } else { '未运行' })
}

function Restore-Snapshot {
    param([string]$Dir)
    if (-not $Dir) {
        [void][System.Windows.Forms.MessageBox]::Show('请先在列表里选中一份快照。', '提示', 'OK', 'Information')
        return
    }
    if (Get-GameRunning) {
        [void][System.Windows.Forms.MessageBox]::Show('游戏正在运行！请先完全退出游戏，再回来还原存档。', '无法还原', 'OK', 'Warning')
        return
    }
    $name = [System.IO.Path]::GetFileName($Dir)
    $ans = [System.Windows.Forms.MessageBox]::Show(
        ("确定要把存档还原到【{0}】吗？`n`n当前存档会先自动备份一份到快照文件夹。" -f $name),
        '确认还原', 'YesNo', 'Question')
    if ($ans -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    try {
        $bk = Join-Path $script:HistDir ('_before_restore_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
        New-Item -ItemType Directory -Force -Path $bk | Out-Null
        Get-ChildItem -LiteralPath $script:SavesDir -File -ErrorAction SilentlyContinue | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $bk $_.Name) -Force
        }
        Get-ChildItem -LiteralPath $Dir -File | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $script:SavesDir $_.Name) -Force
        }
        Write-AppLog ('restore {0} -> saves (backup: {1})' -f $Dir, $bk)
        $script:LastSig = ''
        Update-List
        [void][System.Windows.Forms.MessageBox]::Show(
            "还原完成！`n`n现在启动游戏，点「继续」就会进入这个存档点。",
            '完成', 'OK', 'Information')
    } catch {
        Write-AppLog ('RESTORE ERROR: ' + $_.Exception.ToString())
        [void][System.Windows.Forms.MessageBox]::Show(
            ("写入失败：{0}`n`n如果提示「拒绝访问」，说明这个窗口权限不足。`n请关掉本窗口，改为双击同目录的「杀戮尖塔存档助手.bat」重新打开再试。" -f $_.Exception.Message),
            '还原失败', 'OK', 'Error')
    }
}

# ---------- 事件绑定 ----------
$script:btnRefresh.Add_Click({ Update-List })
$script:btnSnap.Add_Click({
    $r = New-Snapshot -Force
    Update-List
    if ($r) { $script:lblStatus.Text = '已手动快照：' + [System.IO.Path]::GetFileName($r) }
})
$script:btnOpenHist.Add_Click({ Start-Process explorer.exe $script:HistDir })
$script:btnOpenSaves.Add_Click({ Start-Process explorer.exe $script:SavesDir })
$script:btnGameDir.Add_Click({
    $picked = Select-GameDirDialog
    if ($picked -and (Test-GameDir $picked)) {
        $script:GameDir  = $picked
        $script:SavesDir = Join-Path $picked 'saves'
        $script:LogsDir  = Join-Path $picked 'sendToDevs\logs'
        $script:LogPath  = Join-Path $script:LogsDir 'SlayTheSpire.log'
        Save-Setting -Key 'GameDir' -Value $picked
        $script:CurCache = @{ Mtime = [datetime]::MinValue; Events = @(); LineCount = 0; Length = 0 }
        $script:ZipCache = @{ Stamp = ''; Events = @() }
        $script:BucketStamp = ''
        $script:LastSig = ''
        Update-List
    }
})
$script:btnRestore.Add_Click({
    if ($script:lv.SelectedItems.Count -gt 0) { Restore-Snapshot ([string]$script:lv.SelectedItems[0].Tag) }
    else { Restore-Snapshot '' }
})
$script:lv.Add_DoubleClick({
    if ($script:lv.SelectedItems.Count -gt 0) { Restore-Snapshot ([string]$script:lv.SelectedItems[0].Tag) }
})
$script:lv.Add_KeyDown({
    param($sender, $e)
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::F5) { Update-List }
})
$form.Add_KeyDown({
    param($sender, $e)
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::F5) { Update-List }
})
$script:chkAuto.Add_CheckedChanged({
    if ($script:chkAuto.Checked) { $script:timer.Start(); $script:lblStatus.Text = '自动快照：已开启' }
    else { $script:timer.Stop(); $script:lblStatus.Text = '自动快照：已关闭' }
})

$script:timer = New-Object System.Windows.Forms.Timer
$script:timer.Interval = $script:Interval * 1000
$script:timer.Add_Tick({
    $r = New-Snapshot
    if ($r) { Update-List }
})

# ---------- 启动 ----------
try {
    Write-AppLog ('start (pid={0})' -f $PID)
    [void](New-Snapshot)
    Update-List
    $script:timer.Start()
    Write-AppLog ('ready: {0} snapshots' -f @(Get-ChildItem -LiteralPath $script:HistDir -Directory -ErrorAction SilentlyContinue).Count)
} catch {
    Write-AppLog ('STARTUP ERROR: ' + $_.Exception.ToString())
}

[void]$form.ShowDialog()
Write-AppLog 'exit'
