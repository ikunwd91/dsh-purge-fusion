# preunpack.ps1 — 把官方 app.asar 预先解成 resources\app（必须在程序完全退出后运行）
# 只读自动定位 + 调用 preunpack.mjs；不碰 runtime、不碰 profile、不写 manifest。
param(
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $PSCommandPath
$mjs = Join-Path $here 'preunpack.mjs'

function Say([string]$m) { Write-Host $m }

Say '============================================================'
Say '  预解包（把程序本体提前解开，让「应用」不再等 10 分钟）'
Say '============================================================'

if (-not (Test-Path $mjs)) {
    Say ''
    Say '找不到 preunpack.mjs —— 请把整个文件夹一起复制过去，别只拿 cmd。'
    exit 1
}

# ---------- 1. 找本体 ----------
$exe = ''
$keyRoots = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
)
foreach ($root in $keyRoots) {
    if ($exe) { break }
    try {
        $items = Get-ItemProperty -Path $root -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like 'DeepSeek Harness*' -and $_.InstallLocation }
        foreach ($it in $items) {
            $cand = Join-Path $it.InstallLocation 'DeepSeek Harness.exe'
            if (Test-Path -LiteralPath $cand) { $exe = $cand; break }
        }
    } catch { }
}
if (-not $exe) {
    $guess = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness\DeepSeek Harness.exe'),
        (Join-Path $env:ProgramFiles 'DeepSeek Harness\DeepSeek Harness.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'DeepSeek Harness\DeepSeek Harness.exe')
    )
    foreach ($g in $guess) { if ($g -and (Test-Path -LiteralPath $g)) { $exe = $g; break } }
}
if (-not $exe) {
    $p = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like '*DeepSeek*' } | Select-Object -First 1
    if ($p -and $p.Path) { $exe = $p.Path }
}
if (-not $exe) {
    Say ''
    Say '没找到 DeepSeek Harness.exe。请把安装路径发我，或先正常安装一次本体。'
    exit 1
}

$install = Split-Path -Parent $exe
$resources = Join-Path $install 'resources'
if (-not (Test-Path -LiteralPath $resources)) {
    Say ''
    Say ('找到本体，但它旁边没有 resources 目录：' + $install)
    exit 1
}
Say ''
Say ('本体        : ' + $exe)
Say ('resources  : ' + $resources)

# ---------- 2. 程序必须完全退出 ----------
$running = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like '*DeepSeek*' })
if ($running.Count -gt 0) {
    Say ''
    Say '程序还在运行。请先【完全退出】：'
    Say '  1) 关掉所有窗口'
    Say '  2) 右下角托盘图标右键 -> 退出'
    Say '  3) 任务管理器里看不到 DeepSeek 才算退干净'
    Say ''
    Say '退干净以后，再双击一次这个 cmd。'
    exit 2
}

# ---------- 3. 盘的情况（这是耗时的主因）----------
$letter = (Split-Path -Qualifier $resources).TrimEnd(':')
$media = ''
try {
    $disk = Get-Partition -DriveLetter $letter -ErrorAction Stop | Get-Disk -ErrorAction Stop
    $media = (Get-PhysicalDisk -ErrorAction Stop | Where-Object { $_.DeviceId -eq $disk.Number } | Select-Object -First 1).MediaType
} catch { }
$freeGB = ''
try {
    $vol = Get-Volume -DriveLetter $letter -ErrorAction Stop
    $freeGB = [math]::Round($vol.SizeRemaining / 1GB, 1)
} catch { }
Say ''
Say ('所在盘      : ' + $letter + ': / 介质=' + $(if ($media) { $media } else { '未知' }) + ' / 剩余=' + $(if ($freeGB -ne '') { $freeGB.ToString() + ' GB' } else { '未知' }))
if ($media -eq 'HDD') {
    Say '  ★ 这块是机械盘：解包 1.8 万个小文件通常要 10 分钟上下，属正常。'
} elseif ($media -eq 'SSD') {
    Say '  ★ SSD：正常 10 秒~1 分钟。'
}
if ($freeGB -ne '' -and $freeGB -lt 3) {
    Say '  ★ 磁盘剩余不足 3 GB，解包可能失败，先腾点空间。'
}

# ---------- 4. 找 node ----------
$node = ''
$cmdNode = Get-Command node -ErrorAction SilentlyContinue
if ($cmdNode) { $node = $cmdNode.Source }
if (-not $node) {
    foreach ($c in @((Join-Path $env:ProgramFiles 'nodejs\node.exe'), (Join-Path $env:LOCALAPPDATA 'Programs\nodejs\node.exe'))) {
        if (Test-Path -LiteralPath $c) { $node = $c; break }
    }
}
if (-not $node) {
    $hit = Get-ChildItem -Path (Join-Path $env:USERPROFILE '.dsh\dsh-runtimes') -Filter node.exe -Recurse -Depth 4 -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($hit) { $node = $hit.FullName }
}

Say ''
$useElectron = $false
if ($node) {
    Say ('node        : ' + $node)
} else {
    $useElectron = $true
    Say 'node        : 没装系统 node，改用本体自带的 node 引擎（等价）'
}

# ---------- 5. 跑解包 ----------
$mode = if ($DryRun) { '--dry-run' } else { '--commit' }
Say ''
Say '开始。下面每解 250 个文件打一行进度 —— 数字在涨就是在干活，别关这个窗口。'
Say ''

# 输出必须逐行流式：不能写 $x = & cmd（那样会攒到解包结束才一次性打印）
$tr = {
    param([string]$s)
    $t = ''
    if ($s -match '^PLAN (\d+)') { $t = '  准备解包：' + $Matches[1] + ' 个文件' }
    elseif ($s -match '^EXTRACT (\d+)/(\d+) (\d+)% (\d+)s') { $t = '  已解 ' + $Matches[1] + '/' + $Matches[2] + '  (' + $Matches[3] + '%)  用时 ' + $Matches[4] + ' 秒' }
    elseif ($s -match '^EXTRACTED (\d+) overlay (\d+)') { $t = '  解包完成：正文 ' + $Matches[1] + ' 个 + 原生模块 ' + $Matches[2] + ' 个' }
    elseif ($s -match '^VERIFY_OK') { $t = '  校验通过：app\ 里能看到 @deepseek-ai' }
    elseif ($s -match '^APPDIR_READY') { $t = '  resources\app 已就位' }
    elseif ($s -match '^ASAR_RENAMED') { $t = '  app.asar 已改名成 app.asar.bak（下次启动就读 app\ 了）' }
    elseif ($s -match '^PREV_SAVED') { $t = '  原来的 app\ 已改名留底（可回滚）' }
    elseif ($s -match '^STAMP (.+)$') { $t = '  已记录解包标记：' + $Matches[1] }
    elseif ($s -match '^NEXT stale') { $t = '  发现上次失败留下的半成品（会自动清掉）' }
    elseif ($s -match '^APPDIR exists') { $t = '  现状：app\ 已存在（会先备份再换）' }
    elseif ($s -match '^APPDIR absent') { $t = '  现状：app\ 不存在（程序现在读的是密封包）' }
    elseif ($s -match '^ASAR (.+?) (\d+)$') { $t = '  归档：' + $Matches[1] + '  (' + $Matches[2] + ' 字节)' }
    elseif ($s -match '^DRY_RUN_OK') { $t = '  试运行通过：全流程没问题，但没有改动任何东西' }
    elseif ($s -match '^OVERLAY (\d+)') { $t = '  补原生模块 ' + $Matches[1] + ' 个' }
    elseif ($s -match '^DONE_OK') { $t = '  全部完成' }
    elseif ($s -match '^(ERR|WARN) (.*)$') { $t = '  ' + $Matches[1] + ' ' + $Matches[2] }
    elseif ($s.Trim() -ne '') { $t = '  ' + $s }
    if ($t -ne '') { Write-Host $t }
}

if ($useElectron) {
    $env:ELECTRON_RUN_AS_NODE = '1'
    try {
        & $exe $mjs --resources $resources $mode 2>&1 | ForEach-Object { & $tr ([string]$_) }
        $code = $LASTEXITCODE
    } finally {
        Remove-Item Env:\ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue
    }
} else {
    & $node $mjs --resources $resources $mode 2>&1 | ForEach-Object { & $tr ([string]$_) }
    $code = $LASTEXITCODE
}
Say ''
if ($code -eq 0 -and -not $DryRun) {
    Say '================ 成功了，接下来 ================'
    Say '  1) 打开 DeepSeek Harness'
    Say '  2) 新建会话 -> 点输入框上方的 dsh-purge -> 往下滑 -> 点「应用」'
    Say '     （这次不会再等 10 分钟，几秒就完）'
    Say '  3) 弹窗里点中间的【重启】'
} elseif ($code -eq 0 -and $DryRun) {
    Say '试运行结束：流程可用，什么都没改。去掉 -DryRun 再跑一次才会真解包。'
} else {
    Say ('出错了（返回码 ' + $code + '），把上面整屏发回来。')
    Say '注意：出错时 app.asar 没被动过，程序照常能开。'
}
