# restore.ps1 —— 一键从零恢复：下载源码 → 解压到 D:\ → 自检 → 全自动安装
#
# 用法（PowerShell 里跑这一条）：
#   powershell -NoProfile -ExecutionPolicy Bypass -File setup\restore.ps1
#
# 它做的事（全程不需要你点面板「应用」）：
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
#   -DestRoot 'D:\'         解压目标盘（默认 D:\）
#   -SkipPreflight          跳过环境自检
#   -SkipInstall            只下载解压，不安装
#   -DryRun                 只看会做什么，不真正下载/解压/安装

[CmdletBinding()]
param(
    [string]$DestRoot = 'D:\',
    [string]$Repo = 'ikunwd91/dsh-purge-fusion',
    [string]$Branch = 'main',
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
$urls = @(
    "https://gh-proxy.com/https://github.com/$Repo/archive/refs/heads/$Branch.zip",
    "https://github.com/$Repo/archive/refs/heads/$Branch.zip"
)

# ── 1. 下载 ──────────────────────────────────────────────────────
if ($DryRun) {
    Say ''
    Say "(dry-run) 将下载 main.zip："
    foreach ($u in $urls) { Say "    $u" }
    Say "(dry-run) 解压到: $targetDir"
} else {
    Say ''
    Say '下载源码 main.zip …'
    $ok = $false
    foreach ($u in $urls) {
        try {
            Say "  来源: $u"
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -Uri $u -OutFile $tmpZip -TimeoutSec 300 -UseBasicParsing
            $ProgressPreference = 'Continue'
            if (Test-Path $tmpZip -and (Get-Item $tmpZip).Length -gt 1000000) {
                Ok ("下载完成 " + [math]::Round((Get-Item $tmpZip).Length/1MB,1) + ' MB')
                $ok = $true
                break
            }
        } catch {
            Warn ("下载失败，换下一个源：" + $_.Exception.Message)
        }
    }
    if (-not $ok) { Fail '两个源都下载失败，请检查网络。'; exit 1 }
}

# ── 2. 解压到目标盘 ──────────────────────────────────────────────
if ($DryRun) {
    Say ''
    Say "(dry-run) 将清旧 $targetDir 并解压。"
} else {
    Say ''
    Say '清旧目录并解压 …'
    $release = Join-Path $DestRoot 'dsh-purge-fusion-main'
    if (Test-Path $release) {
        Warn "删除旧目录 $release"
        Remove-Item $release -Recurse -Force -ErrorAction SilentlyContinue
    }
    Expand-Archive -Path $tmpZip -DestinationPath $DestRoot -Force
    # GitHub zip 解压出来是 <repo>-<branch> 目录，统一成 dsh-purge-fusion-main
    $extracted = Get-ChildItem $DestRoot -Directory |
        Where-Object { $_.Name -match 'dsh-purge-fusion' } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $extracted) { Fail "解压后找不到 dsh-purge-fusion* 目录"; exit 1 }
    if ($extracted.FullName -ne $targetDir) {
        if (Test-Path $targetDir) { Remove-Item $targetDir -Recurse -Force }
        Move-Item $extracted.FullName $targetDir
    }
    $probe = Join-Path $targetDir 'lib\fusion\index.js'
    if (-not (Test-Path $probe)) {
        Fail "校验失败：$probe 不存在（压缩包不完整？）"
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

if (-not $SkipPreflight -and (Test-Path $preflight)) {
    Say ''
    Say '=== 环境自检（只读） ==='
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $preflight
}

if ($SkipInstall) {
    Say ''
    Ok '下载解压完成（-SkipInstall，跳过安装）。'
    Say "之后手动：cd $targetDir ; .\setup\install.ps1"
    exit 0
}

if (-not (Test-Path $install)) {
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
