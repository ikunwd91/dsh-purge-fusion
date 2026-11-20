# restore.ps1 —— 一键从零恢复：探测已有源码 → 缺则下载 → 解压到 D:\ → 自检 → 全自动安装
#
# 用法（PowerShell 里跑这一条）：
#   powershell -NoProfile -ExecutionPolicy Bypass -File setup\restore.ps1
#
# 它做的事（全程不需要你点面板「应用」）：
#   0. 先自动探测各盘根目录 / 桌面 / 下载 / TEMP 里有没有已经下好的 main.zip
#      或已经解压好的 dsh-purge-fusion-main —— 有就直接用，没有才去下载
#   1. 下载 main.zip（优先 gh-proxy，失败回退直连 github.com）
#   2. 清掉旧 D:\dsh-purge-fusion-main，解压 main.zip 到 D:\
#   3. 校验 lib\fusion\index.js 在
#   4. 跑 preflight.ps1（环境自检，只读）
#   5. 跑 install.ps1（junction + profile + 自动找 1.29GB 运行时包 + 自动解包+应用）
#
# 1.29GB 运行时包（fusion-runtime-1.29GB.zip）不用管：install 会按「文件名+大小」
# 自动搜到它（桌面/下载/各盘根都行），免下载。
#
# 可选参数：
#   -DestRoot 'D:\'           解压目标盘（默认 D:\）
#   -SourceZip 'C:\main.zip'  指定已下好的压缩包（跳过下载）
#   -SourceDir 'C:\dsh-purge-fusion-main' 指定已解压好的源码目录（跳过下载+解压）
#   -SkipPreflight            跳过环境自检
#   -SkipInstall              只解压，不安装
#   -DryRun                   只看会做什么，不真正下载/解压/安装

[CmdletBinding()]
param(
    [string]$DestRoot = 'D:\',
    [string]$Repo = 'ikunwd91/dsh-purge-fusion',
    [string]$Branch = 'main',
    [string]$SourceZip = '',
    [string]$SourceDir = '',
    [switch]$SkipPreflight,
    [switch]$SkipInstall,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

function Say([string]$m) { Write-Host $m }
function Ok([string]$m) { Write-Host ("  ✓ " + $m) -ForegroundColor Green }
function Warn([string]$m) { Write-Host ("  ⚠ " + $m) -ForegroundColor Yellow }
function Fail([string]$m) { Write-Host ("  ✗ " + $m) -ForegroundColor Red }

Say '============================================================'
Say '  dsh-purge-fusion 一键从零恢复'
Say '============================================================'

$tmpZip = Join-Path $env:TEMP 'fusion-src.zip'
$targetDir = Join-Path $DestRoot 'dsh-purge-fusion-main'
$probeFile = Join-Path $targetDir 'lib\fusion\index.js'
$urls = @(
    "https://gh-proxy.com/https://github.com/$Repo/archive/refs/heads/$Branch.zip",
    "https://github.com/$Repo/archive/refs/heads/$Branch.zip"
)

# ── 0. 探测已有 main.zip / 已解压源码 ────────────────────────────
$zipNames = @('main.zip', 'fusion-src.zip', "dsh-purge-fusion-$Branch.zip", 'dsh-purge-fusion-main.zip')
$dirNames = @('dsh-purge-fusion-main', 'dsh-purge-fusion')

$searchRoots = New-Object System.Collections.Generic.List[string]

# 所有文件系统盘根目录
foreach ($d in (Get-PSDrive -PSProvider FileSystem)) {
    $r = $d.Root
    if ($r -and -not ($searchRoots -contains $r)) { $searchRoots.Add($r) }
}

# 常用下载/桌面/临时目录
$extra = @(
    $env:USERPROFILE,
    [Environment]::GetFolderPath('Desktop'),
    [Environment]::GetFolderPath('MyDocuments')
)
foreach ($e in @(
    @($env:USERPROFILE, 'Desktop'),
    @($env:USERPROFILE, 'Downloads'),
    @($env:PUBLIC, 'Desktop'),
    @($env:PUBLIC, 'Downloads')
)) {
    if ($e[0]) { $extra += (Join-Path $e[0] $e[1]) }
}
$extra += $env:TEMP

foreach ($p in $extra) {
    if ($p -and (Test-Path -LiteralPath $p) -and -not ($searchRoots -contains $p)) {
        $searchRoots.Add($p)
    }
}

function Test-ZipCandidate([string]$path) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
    $len = (Get-Item -LiteralPath $path).Length
    return ($len -gt 1000000)
}

function Test-DirCandidate([string]$path) {
    return (Test-Path -LiteralPath (Join-Path $path 'lib\fusion\index.js'))
}

function Find-Zip {
    if ($SourceZip -and (Test-ZipCandidate $SourceZip)) { return $SourceZip }
    # 1) 各盘根 + 常用目录的顶层，按精确文件名
    foreach ($root in $searchRoots) {
        foreach ($n in $zipNames) {
            $cand = Join-Path $root $n
            if (Test-ZipCandidate $cand) { return $cand }
        }
    }
    # 2) 桌面 / 下载 / 文档 / TEMP 的浅层子目录（深度 3）：先精确名，再关键字
    $deepRoots = @()
    foreach ($r in $searchRoots) {
        if ($r -match '(?i)(Desktop|Downloads|Documents|Temp)') { $deepRoots += $r }
    }
    foreach ($root in $deepRoots) {
        foreach ($n in $zipNames) {
            foreach ($hit in (Get-ChildItem -LiteralPath $root -Filter $n -File -Recurse -Depth 3 -ErrorAction SilentlyContinue)) {
                if (Test-ZipCandidate $hit.FullName) { return $hit.FullName }
            }
        }
    }
    foreach ($root in $deepRoots) {
        foreach ($hit in (Get-ChildItem -LiteralPath $root -Filter '*.zip' -File -Recurse -Depth 3 -ErrorAction SilentlyContinue)) {
            if ($hit.Name -match '(?i)fusion|purge|dsh|main') {
                if (Test-ZipCandidate $hit.FullName) { return $hit.FullName }
            }
        }
    }
    return $null
}

function Find-Dir {
    if ($SourceDir -and (Test-DirCandidate $SourceDir)) { return $SourceDir }
    foreach ($root in $searchRoots) {
        foreach ($n in $dirNames) {
            $cand = Join-Path $root $n
            if (Test-DirCandidate $cand) { return $cand }
        }
    }
    # 兜底：在各盘根目录的一层子目录里找 lib\fusion\index.js
    foreach ($root in $searchRoots) {
        try {
            foreach ($child in (Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
                if (Test-DirCandidate $child.FullName) { return $child.FullName }
            }
        } catch { }
    }
    return $null
}

$foundZip = Find-Zip
$foundDir = Find-Dir

if ($foundZip) { Ok ("探测到已下载源码包: $foundZip") }
if ($foundDir) { Ok ("探测到已解压源码: $foundDir") }

if ($DryRun) {
    Say ''
    Say "(dry-run) 探测范围："
    foreach ($r in $searchRoots) { Say "    $r" }
    Say "(dry-run) 将复用："
    if ($foundZip) { Say "    压缩包 $foundZip" } else { Say "    (未找到压缩包)" }
    if ($foundDir) { Say "    目录   $foundDir" } else { Say "    (未找到解压目录)" }
    if (-not $foundZip -and -not $foundDir) {
        Say "(dry-run) 将下载 main.zip："
        foreach ($u in $urls) { Say "    $u" }
    }
    Say "(dry-run) 解压到: $targetDir"
}

# ── 1. 下载（仅在没找到任何现成源码时） ─────────────────────────
$needDownload = (-not $foundZip) -and (-not $foundDir)

if ($DryRun) {
    # 只打印，不动作
} elseif ($needDownload) {
    Say ''
    Say '未找到现成源码，下载 main.zip …'
    $ok = $false
    foreach ($u in $urls) {
        try {
            Say "  来源: $u"
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -Uri $u -OutFile $tmpZip -TimeoutSec 300 -UseBasicParsing
            $ProgressPreference = 'Continue'
            if (Test-Path -LiteralPath $tmpZip -and (Get-Item -LiteralPath $tmpZip).Length -gt 1000000) {
                Ok ("下载完成 " + [math]::Round((Get-Item -LiteralPath $tmpZip).Length/1MB,1) + ' MB')
                $foundZip = $tmpZip
                $ok = $true
                break
            }
        } catch {
            Warn ("下载失败，换下一个源：" + $_.Exception.Message)
        }
    }
    if (-not $ok) { Fail '所有源都下载失败，请检查网络。'; exit 1 }
} else {
    Say ''
    if ($foundDir) {
        Ok '已找到解压好的源码，跳过下载。'
    } else {
        Ok ("已找到现成压缩包，跳过下载：$foundZip")
    }
}

# ── 2. 解压到目标盘 ──────────────────────────────────────────────
if ($DryRun) {
    Say ''
    Say "(dry-run) 将清旧 $targetDir 并解压。"
} elseif ($foundDir) {
    Say ''
    Say '复用已解压源码 …'
    if ($foundDir -ne $targetDir) {
        if (Test-Path -LiteralPath $targetDir) {
            Warn "删除旧目录 $targetDir"
            Remove-Item -LiteralPath $targetDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        Ok ("复制 $foundDir -> $targetDir")
        Copy-Item -LiteralPath $foundDir -Destination $targetDir -Recurse -Force
    }
    if (-not (Test-Path -LiteralPath $probeFile)) {
        Fail "校验失败：$probeFile 不存在（目录不完整？）"
        exit 2
    }
    Ok ("源码就位: $targetDir")
} else {
    Say ''
    Say '清旧目录并解压 …'
    if (Test-Path -LiteralPath $targetDir) {
        Warn "删除旧目录 $targetDir"
        Remove-Item -LiteralPath $targetDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    Expand-Archive -Path $foundZip -DestinationPath $DestRoot -Force
    # GitHub zip 解压出来是 <repo>-<branch> 目录，统一成 dsh-purge-fusion-main
    $extracted = Get-ChildItem $DestRoot -Directory |
        Where-Object { $_.Name -match 'dsh-purge-fusion' } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $extracted) { Fail "解压后找不到 dsh-purge-fusion* 目录"; exit 1 }
    if ($extracted.FullName -ne $targetDir) {
        if (Test-Path -LiteralPath $targetDir) { Remove-Item -LiteralPath $targetDir -Recurse -Force }
        Move-Item -LiteralPath $extracted.FullName -Destination $targetDir
    }
    if (-not (Test-Path -LiteralPath $probeFile)) {
        Fail "校验失败：$probeFile 不存在（压缩包不完整？）"
        exit 2
    }
    Ok ("源码就位: $targetDir")
}

# ── 3. 自检 + 安装 ──────────────────────────────────────────────
if ($DryRun) {
    Say ''
    Say "(dry-run) 将执行 preflight.ps1 + install.ps1"
    exit 0
}

$preflight = Join-Path $targetDir 'setup\preflight.ps1'
$install = Join-Path $targetDir 'setup\install.ps1'

if (-not $SkipPreflight -and (Test-Path -LiteralPath $preflight)) {
    Say ''
    Say '=== 环境自检（只读） ==='
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $preflight
}

if ($SkipInstall) {
    Say ''
    Ok '源码就位完成（-SkipInstall，跳过安装）。'
    Say "之后手动：cd $targetDir ; .\setup\install.ps1"
    exit 0
}

if (-not (Test-Path -LiteralPath $install)) {
    Fail "找不到安装脚本 $install"
    exit 3
}

Say ''
Say '=== 安装（junction + profile + 运行时 + 自动解包+应用） ==='
Push-Location $targetDir
try {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $install
} finally {
    Pop-Location
}

Say ''
Ok '一键恢复完成。'
Say '如果 DSH 之前一直在运行，完全退出后再跑：'
Say "    .\setup\auto-apply.ps1"
Say '然后打开 DSH 即可，不用点面板「应用」。'
