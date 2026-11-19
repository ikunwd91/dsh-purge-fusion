# auto-apply.ps1 —— 全自动解包 + 应用（替代「打开面板点应用」）
#
# 思路（学习原版 1.1.71 合集里的「预解包 + -Apply」）：
#   1. 解包必须在程序完全退出时离线做（preunpack），不能在宿主进程里做 ——
#      否则 Electron 主进程里同步解 1.8 万个小文件会卡「处理中」十几分钟。
#   2. 解包后 app.asar 被改名，插件启动时 desktopAsarStillSealed()=false，
#      配合 autoApplyOnStart=true 或本脚本的 CLI --apply，补丁就能直接写进
#      resources\app\，几秒完成，不需要点面板。
#   3. CLI --apply 要能定位 desktop 的 ai_base，必须设 DSH_SURFACE=desktop
#      和 DSH_BASE=<解包后的 @deepseek-ai 目录>（实测验证过）。
#
# 用法：
#   .\setup\auto-apply.ps1                       # 定位 + 解包 + 应用，全自动
#   .\setup\auto-apply.ps1 -DshRoot 'D:\...'     # 手动指定安装目录
#   .\setup\auto-apply.ps1 -DryRun               # 只看会做什么
#   .\setup\auto-apply.ps1 -SkipExtract          # 已解包过，只做 apply
#
# 要求：运行前完全退出 DeepSeek Harness（关窗口 → 托盘右键退出 → 任务管理器看不到）。

[CmdletBinding()]
param(
    [string]$DshRoot = '',
    [switch]$SkipExtract,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$DshHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }

function Say([string]$m) { Write-Host $m }
function Ok([string]$m) { Write-Host ("  ✓ " + $m) -ForegroundColor Green }
function Warn([string]$m) { Write-Host ("  ⚠ " + $m) -ForegroundColor Yellow }
function Fail([string]$m) { Write-Host ("  ✗ " + $m) -ForegroundColor Red }

Say '============================================================'
Say '  dsh-purge-fusion 全自动解包 + 应用'
Say '============================================================'

# ── 1. 定位 DSH 安装 ────────────────────────────────────────────
function Find-DshRoot {
    if ($DshRoot) {
        if (-not (Test-Path (Join-Path $DshRoot 'resources'))) { throw "手动指定目录下没有 resources：$DshRoot" }
        return (Resolve-Path $DshRoot).Path
    }
    # a) 运行中进程（最准）
    $proc = Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessName -match 'DeepSeek|dsh' -and $_.Path -match '\.exe$' } |
        Select-Object -First 1
    if ($proc) {
        $d = Split-Path -Parent $proc.Path
        if (Test-Path (Join-Path $d 'resources')) { return $d }
    }
    # b) 注册表卸载登记
    foreach ($root in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )) {
        try {
            $it = Get-ItemProperty -Path $root -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -like 'DeepSeek Harness*' -and $_.InstallLocation } |
                Select-Object -First 1
            if ($it) {
                $cand = Join-Path $it.InstallLocation 'DeepSeek Harness.exe'
                if (Test-Path -LiteralPath $cand) { return $it.InstallLocation }
            }
        } catch {}
    }
    # c) 常见路径
    foreach ($g in @(
        (Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness'),
        (Join-Path $env:ProgramFiles 'DeepSeek Harness'),
        (Join-Path ${env:ProgramFiles(x86)} 'DeepSeek Harness')
    )) {
        if ($g -and (Test-Path (Join-Path $g 'resources'))) { return $g }
    }
    # d) 磁盘扫描
    foreach ($drive in (Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Used -ne $null })) {
        try {
            $hit = Get-ChildItem $drive.Root -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match 'DeepSeek|Harness|dsh' -and (Test-Path (Join-Path $_.FullName 'resources')) } |
                Select-Object -First 1
            if ($hit) { return $hit.FullName }
        } catch {}
    }
    return $null
}

$root = Find-DshRoot
if (-not $root) {
    Fail '找不到 DeepSeek Harness 安装目录。用 -DshRoot 手动指定。'
    exit 1
}
$ResDir = Join-Path $root 'resources'
$asar = Join-Path $ResDir 'app.asar'
$appDir = Join-Path $ResDir 'app'
Say ('安装目录 : ' + $root)
Say ('resources : ' + $ResDir)

# ── 2. 程序必须退出 ──────────────────────────────────────────────
$running = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match 'DeepSeek|dsh' })
if ($running.Count -gt 0) {
    Fail '程序还在运行。请先完全退出（关窗口 → 托盘右键退出 → 任务管理器里看不到）。'
    exit 2
}

# ── 3. 解包（如果需要）──────────────────────────────────────────
$needExtract = (Test-Path -LiteralPath $asar) -and -not (Test-Path -LiteralPath $appDir)
if ($needExtract -and -not $SkipExtract) {
    $pp = Join-Path $RepoRoot 'setup\preunpack\preunpack.ps1'
    if (-not (Test-Path -LiteralPath $pp)) { Fail "缺少解包工具：$pp"; exit 1 }
    Say ''
    Say '正在离线解包 app.asar（约 1.8 万个小文件，SSD 十几秒，机械盘可能十几分钟）…'
    if ($DryRun) {
        Say '  (dry-run) 将执行 preunpack.ps1'
    } else {
        $ppOut = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $pp 2>&1 | Out-String
        $ppCode = $LASTEXITCODE
        foreach ($l in ($ppOut -split "`r?`n")) {
            $s = $l.Trim()
            if ($s -match '已解|全部完成|失败|ERROR|不完整|DONE') { Say "    $s" }
        }
        if ($ppCode -ne 0 -or -not (Test-Path -LiteralPath $appDir)) {
            Fail "解包没完成（退出码 $ppCode）。app.asar 仍原样，程序照常能打开。"
            exit 3
        }
        Ok '解包完成，app.asar 已改名。'
    }
} elseif ($needExtract -and $SkipExtract) {
    Warn 'app.asar 仍密封，但用了 -SkipExtract，直接尝试 apply（可能失败）。'
} elseif (-not (Test-Path -LiteralPath $asar) -and (Test-Path -LiteralPath $appDir)) {
    Ok '已经解包过（app.asar 不存在，app\ 已就位）。'
} elseif (-not (Test-Path -LiteralPath $appDir)) {
    Fail 'app.asar 和 app\ 都不在，本体不完整。'
    exit 4
}

# ── 4. 定位 ai_base 与 node ──────────────────────────────────────
$aiBase = ''
foreach ($rel in @('app\dsh\node_modules\@deepseek-ai', 'app\node_modules\@deepseek-ai')) {
    $cand = Join-Path $ResDir $rel
    if (Test-Path -LiteralPath $cand) { $aiBase = $cand; break }
}
if (-not $aiBase) {
    Fail '解包后找不到 @deepseek-ai 目录，app\ 不完整。'
    exit 5
}
Say ('ai_base   : ' + $aiBase)

$node = ''
$nodeCands = @(
    (Join-Path $ResDir 'runtime\primary-runtime\dependencies\node\bin\node.exe'),
    (Join-Path $ResDir 'runtime\dsh-primary-runtime\dependencies\node\bin\node.exe'),
    (Join-Path $ResDir 'runtime\node\bin\node.exe')
)
$g = Get-Command node.exe -ErrorAction SilentlyContinue
if ($g) { $nodeCands += $g.Source }
foreach ($c in $nodeCands) { if ($c -and (Test-Path -LiteralPath $c)) { $node = $c; break } }
if (-not $node) { Fail '找不到 node.exe'; exit 6 }
Say ('node      : ' + $node)

$cli = Join-Path $RepoRoot 'bin\dsh-purge.js'
if (-not (Test-Path -LiteralPath $cli)) { Fail "插件 CLI 不存在：$cli"; exit 7 }

# ── 5. 设环境变量（CLI 定位 desktop ai_base 的关键）──────────────
$env:DSH_SURFACE = 'desktop'
$env:DSH_BASE = $aiBase
$env:DSH_HOME = $DshHome

# ── 6. 应用 ──────────────────────────────────────────────────────
if ($DryRun) {
    Say ''
    Say '(dry-run) 将执行：node bin/dsh-purge.js --apply'
    Say ('(dry-run) DSH_SURFACE=desktop  DSH_BASE=' + $aiBase)
    exit 0
}

Say ''
Say '正在写入补丁（提示词 + 代码 + shim）…'
$applyOut = & $node $cli --apply 2>&1 | Out-String
$applyCode = $LASTEXITCODE
foreach ($l in ($applyOut -split "`r?`n")) {
    $s = $l.Trim()
    if ($s -match '宿主|已清洗|全部完成|ERROR|失败|shim') { Say "    $s" }
}
if ($applyCode -ne 0) {
    Fail "应用命令返回 $applyCode。"
    Fail ($applyOut -split "`r?`n" | Select-Object -Last 10)
    exit 8
}

# ── 7. 复查 ──────────────────────────────────────────────────────
Say ''
$after = & $node $cli --status 2>&1 | Out-String
foreach ($l in ($after -split "`r?`n")) {
    $s = $l.Trim()
    if ($s -match '补丁|shim:|patches') { Say "  $s" }
}

# 补写「已应用」标记（CLI --apply 不写；不补的话插件启动可能误判没应用过）
$reapplyJs = Join-Path $RepoRoot 'lib\reapply.js'
if (Test-Path -LiteralPath $reapplyJs) {
    $url = 'file:///' + ($reapplyJs -replace '\\', '/')
    $stampOut = & $node --input-type=module -e "const m = await import('$url'); try { m.markPatchesApplied(); console.log('stamp_ok'); } catch (e) { console.log('stamp_fail:' + (e && e.message)); }" 2>&1 | Out-String
    if ($stampOut -match 'stamp_ok') { Ok '已写「已应用」标记' }
    else { Warn ('写标记没成功（不影响补丁生效）：' + $stampOut.Trim()) }
}

Say ''
Ok '全自动应用完成。'
Say '直接打开 DeepSeek Harness 即可使用，不用再点面板「应用」。'
Say '启动后建议跑 purge_status 确认：66/67 applied、shim=patched/n/a/n/a。'
