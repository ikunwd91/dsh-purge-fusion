# install-runtime.ps1 —— 为 fusion 引擎链路安装 IG5 运行时
#
# 引擎工具（ig5_open/decompile/dbg/emulate 等 43 个）需要 Ghidra + x64dbg 便携运行时。
# 供体把这份 1.06 GB 资产放在 release 里（git 仓库不含），本脚本负责下载、校验、解包到
# 本插件自己的 runtimes 目录，不动系统 PATH、不动全局 Python、不影响供体安装。
#
# 用法：
#   .\install-runtime.ps1                     # 下载 + 校验 + 解包
#   .\install-runtime.ps1 -Archive 'D:\ig5.zip'   # 用已有压缩包（离线）
#   .\install-runtime.ps1 -VerifyOnly         # 只校验当前安装
#
# 校验基准来自供体 scripts/distribution.json，SHA256 不符即拒绝安装。

[CmdletBinding()]
param(
  [string]$Archive,
  [switch]$VerifyOnly,
  [string]$FusionRoot = 'C:\Users\Administrator\AppData\Local\dsh-purge-src\dsh-purge-master\lib\fusion'
)

$ErrorActionPreference = 'Stop'

$Asset = 'IG5-1.0.0-Windows-x64-dsh021-full-20261010.zip'
$Url   = "https://github.com/Minglink/dsh-infinite-gen-5/releases/download/v1.0.0-dsh021-20261010/$Asset"
$Sha   = 'a2459ddca1f19e5eec2d7918c504f133889809800a0b277e1e379d3ce1459b54'
$Bytes = 1064580056

$runtimeDir = Join-Path $FusionRoot 'vendor\runtimes'
$ghidraManifest = Join-Path $runtimeDir 'ghidra\runtime.json'
$x64dbgManifest = Join-Path $runtimeDir 'x64dbg\runtime.json'

function Show-Status {
  Write-Host "运行时目录: $runtimeDir"
  Write-Host "  ghidra/runtime.json : $(if (Test-Path $ghidraManifest) { 'OK' } else { 'MISSING' })"
  Write-Host "  x64dbg/runtime.json : $(if (Test-Path $x64dbgManifest) { 'OK' } else { 'MISSING' })"
  if (Test-Path $runtimeDir) {
    $size = (Get-ChildItem -Recurse -File $runtimeDir -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    Write-Host "  占用: $([math]::Round($size/1GB,2)) GB"
  }
}

Write-Host "=== 当前状态 ==="
Show-Status
if ($VerifyOnly) {
  if ((Test-Path $ghidraManifest) -and (Test-Path $x64dbgManifest)) {
    Write-Host "`n运行时已就位。启动 DSH 后调用 purge_engine_tools 确认 ready=true。"
    exit 0
  }
  Write-Host "`n运行时缺失。运行不带 -VerifyOnly 的本脚本安装。"
  exit 1
}

# 1) 取压缩包
$work = Join-Path $env:TEMP 'ig5-runtime-dl'
New-Item -ItemType Directory -Force -Path $work | Out-Null
$zip = if ($Archive) { $Archive } else { Join-Path $work $Asset }

if (-not (Test-Path $zip)) {
  Write-Host "`n=== 下载 $Asset (1.06 GB) ==="
  Write-Host "来源: $Url"
  # curl 支持断点续传，中断后重跑本脚本会接着下
  & curl.exe -L --fail --retry 8 --retry-delay 5 --retry-all-errors -C - -o $zip --connect-timeout 30 $Url
  if ($LASTEXITCODE -ne 0) { throw "下载失败（exit $LASTEXITCODE）。可手动下载后传 -Archive 路径。" }
}

# 2) 校验大小与哈希（供体 install.ps1 同一口径）
$actualBytes = (Get-Item $zip).Length
if ($actualBytes -ne $Bytes) { throw "大小不符: 期望 $Bytes, 实际 $actualBytes" }
Write-Host "`n=== 校验 SHA-256 ==="
$actualSha = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
if ($actualSha -ne $Sha) { throw "SHA-256 不符:`n  期望 $Sha`n  实际 $actualSha" }
Write-Host "SHA-256 OK"

# 3) 解包：发行包内是 plugin/runtimes/...，取 runtimes 目录
Write-Host "`n=== 解包 ==="
$stage = Join-Path $work 'stage'
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
Expand-Archive -Path $zip -DestinationPath $stage -Force

$found = Get-ChildItem $stage -Recurse -Directory -Filter 'runtimes' |
  Where-Object { Test-Path (Join-Path $_.FullName 'ghidra\runtime.json') } |
  Select-Object -First 1
if (-not $found) { throw "压缩包里没找到含 ghidra\runtime.json 的 runtimes 目录，包结构可能变了" }

if (Test-Path $runtimeDir) {
  $backup = "$runtimeDir.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
  Write-Host "已存在旧运行时，备份到 $backup"
  Move-Item $runtimeDir $backup
}
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $runtimeDir) | Out-Null
Move-Item $found.FullName $runtimeDir

Write-Host "`n=== 完成 ==="
Show-Status
Write-Host "`n完全退出 DSH 桌面端再启动，然后调用 purge_engine_tools 确认 runtime.ghidra.available=true。"
Write-Host "暂存目录可删: $work"
