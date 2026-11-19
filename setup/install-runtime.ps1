# install-runtime.ps1 —— 为 fusion 引擎链路安装 IG5 运行时
#
# 引擎工具（ig5_open/decompile/dbg/emulate 等 43 个）需要 Ghidra + x64dbg 便携运行时。
# 这份 1.29 GB 资产不进 Git（jdk-21.0.12.1+1/lib/modules 单文件 134.4 MB，
# 超过 GitHub 单文件 100 MB 硬限制），改走 Release 附件分发。
#
# 本脚本兼容两种压缩包结构：
#   1. 本仓库 Release：压平版，根目录直接是 ghidra/ + x64dbg/ + manifest.json
#   2. 供体发行包：外层 plugin/runtimes/...
#
# 用法：
#   .\install-runtime.ps1                        # 下载 + 校验 + 解包
#   .\install-runtime.ps1 -Archive 'D:\x.zip'    # 用已有压缩包（离线）
#   .\install-runtime.ps1 -VerifyOnly            # 只校验当前安装
#   .\install-runtime.ps1 -Source donor          # 强制从供体发行包取

[CmdletBinding()]
param(
  [string]$Archive,
  [switch]$VerifyOnly,
  [switch]$DryRun,
  [ValidateSet('auto', 'repo', 'donor')]
  [string]$Source = 'auto',
  [string]$FusionRoot
)

$ErrorActionPreference = 'Stop'

# 默认按本脚本位置推断 fusion 根：<repo>/setup/install-runtime.ps1 → <repo>/lib/fusion
if (-not $FusionRoot) {
  $repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
  $FusionRoot = Join-Path $repoRoot 'lib\fusion'
}

# ── 分发源 ─────────────────────────────────────────────────────────
# repo  = 本仓库 Release（压平版，推荐）
# donor = 供体 Minglink/dsh-infinite-gen-5 的完整发行包（压平版的来源）
$Sources = @{
  repo  = @{
    Asset = 'fusion-runtime-1.29GB.zip'
    Url   = 'https://github.com/ikunwd91/dsh-purge-fusion/releases/download/runtime-v1/fusion-runtime-1.29GB.zip'
    Sha   = 'bd1af6a79d7f073ab66d6cfdf1896da601602c55e821df1a5751072afd5100c0'
    Bytes = 826929284
    Flat  = $true
  }
  donor = @{
    Asset = 'IG5-1.0.0-Windows-x64-dsh021-full-20261010.zip'
    Url   = 'https://github.com/Minglink/dsh-infinite-gen-5/releases/download/v1.0.0-dsh021-20261010/IG5-1.0.0-Windows-x64-dsh021-full-20261010.zip'
    Sha   = 'a2459ddca1f19e5eec2d7918c504f133889809800a0b277e1e379d3ce1459b54'
    Bytes = 1064580056
    Flat  = $false
  }
}

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

# ── 选定分发源 ─────────────────────────────────────────────────────
$pick = $Source
if ($pick -eq 'auto') { $pick = 'repo' }
$meta = $Sources[$pick]
Write-Host "`n分发源: $pick  ($($meta.Asset))"

# 若 repo 源还是占位符且用户没显式指定，回退 donor
if ($pick -eq 'repo' -and $meta.Url -match 'REPLACE_') {
  if ($Source -eq 'auto') {
    Write-Host "  ⚠ repo 源 URL 未配置（仍是 REPLACE_ 占位符），自动回退到 donor 发行包"
    $pick = 'donor'
    $meta = $Sources[$pick]
    Write-Host "  改用: $pick  ($($meta.Asset))"
  } else {
    throw "setup/install-runtime.ps1 里的 repo 源 URL 仍是占位符，请改成你自己的 Release 地址，或改用 -Source donor"
  }
}

# ── 自动查找本地已有的压缩包 ───────────────────────────────────────
# 用户自己从 Release 下好了包，但可能放在桌面/下载/D:\游戏 等任意位置。
# 这里先找一遍，找到大小完全一致的就直接用，不用再填 -Archive。
function Find-LocalArchive {
  param([long]$ExpectedBytes, [string]$AssetName)

  $hits = @()
  $tried = @()

  # 搜索根：用户目录常见位置 + 各盘根 + 一两级子目录
  $roots = @()
  foreach ($d in @("$env:USERPROFILE\Desktop", "$env:USERPROFILE\Downloads", "$env:USERPROFILE\Documents", $env:TEMP, (Get-Location).Path)) {
    if ($d -and (Test-Path $d)) { $roots += $d }
  }
  foreach ($drive in (Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Used -ne $null })) {
    if (Test-Path $drive.Root) { $roots += $drive.Root }
  }

  foreach ($root in ($roots | Select-Object -Unique)) {
    # 先按名字找
    $found = @()
    try {
      $found = Get-ChildItem $root -Filter "*fusion-runtime*" -File -Recurse -Depth 2 -ErrorAction SilentlyContinue
    } catch {}
    # 名字不完全匹配时，退一步按大小找（用户可能改过名）
    if (-not $found) {
      try {
        $found = Get-ChildItem $root -Filter "*.zip" -File -Recurse -Depth 2 -ErrorAction SilentlyContinue |
          Where-Object { $_.Length -eq $ExpectedBytes }
      } catch {}
    }
    foreach ($f in $found) {
      if ($tried -contains $f.FullName) { continue }
      $tried += $f.FullName
      if ($f.Length -eq $ExpectedBytes) { $hits += $f }
    }
    if ($hits.Count -gt 0) { break }   # 找到就不继续扫别的根
  }

  if ($hits.Count -gt 0) {
    # 多份就取最新的
    return ($hits | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
  }
  return $null
}

# ── 取压缩包 ───────────────────────────────────────────────────────
$work = Join-Path $env:TEMP 'ig5-runtime-dl'
New-Item -ItemType Directory -Force -Path $work | Out-Null

# 预先算好可读大小，避免在双引号里内联除法（PowerShell 会把 1GB 当单位字面量）
$sizeGb = [math]::Round($meta.Bytes / 1073741824, 2)

if ($Archive) {
  $zip = $Archive
} else {
  Write-Host "`n=== 查找本地已有的运行时包 ==="
  $local = Find-LocalArchive -ExpectedBytes $meta.Bytes -AssetName $meta.Asset
  if ($local) {
    Write-Host "  找到: $local"
    Write-Host "  大小: $([math]::Round((Get-Item $local).Length/1MB,1)) MB ✅ 与期望一致"
    $zip = $local
  } else {
    Write-Host "  本机没有匹配的包（大小需为 $($meta.Bytes) 字节），将自动下载。"
    $zip = Join-Path $work $meta.Asset
  }
}

# 已有文件是否完整？残缺文件（上次下载中断）不能直接跳过，否则后面校验必挂。
$needDownload = $true
if (Test-Path $zip) {
  $have = (Get-Item $zip).Length
  if ($have -eq $meta.Bytes) {
    Write-Host "`n使用压缩包: $zip"
    $needDownload = $false
  } elseif ($Archive) {
    throw "指定的压缩包大小不符: 期望 $($meta.Bytes), 实际 $have`n文件: $zip"
  } else {
    Write-Host "`n检测到不完整文件（$have / $($meta.Bytes) 字节），断点续传"
  }
}

if ($needDownload) {
  Write-Host "`n=== 下载 $($meta.Asset) ($sizeGb GB) ==="
  Write-Host "来源: $($meta.Url)"
  # curl 支持断点续传，中断后重跑本脚本会接着下。
  # --ssl-no-revoke：Windows schannel 查不到证书吊销列表（CRL/OCSP）时会报
  #   CRYPT_E_NO_REVOCATION_CHECK (0x80092012) 并直接失败。
  #   这不是证书有问题，是查询服务器不可达；跳过吊销检查即可。
  & curl.exe --ssl-no-revoke -L --fail --retry 8 --retry-delay 5 --retry-all-errors -C - -o $zip --connect-timeout 30 $meta.Url
  $curlCode = $LASTEXITCODE

  # curl 挂了退回 .NET 下载（走 Windows 证书链，行为不同，常能过）
  if ($curlCode -ne 0) {
    Write-Host "`n  curl 失败（exit $curlCode），改用系统下载器重试…"
    try {
      $oldProgress = $ProgressPreference
      $ProgressPreference = 'SilentlyContinue'   # 大文件时进度条拖慢速度
      Invoke-WebRequest -Uri $meta.Url -OutFile $zip -TimeoutSec 3600 -UseBasicParsing
      $ProgressPreference = $oldProgress
      Write-Host "  系统下载器成功"
    } catch {
      # 清掉残缺文件，避免下次又跳过下载
      if (Test-Path $zip) { Remove-Item $zip -Force -ErrorAction SilentlyContinue }
      throw "两种下载方式都失败：$($_.Exception.Message)`n可手动下载后传 -Archive 路径。"
    }
  }
}

# ── 校验大小与哈希 ─────────────────────────────────────────────────
$actualBytes = (Get-Item $zip).Length
if ($actualBytes -ne $meta.Bytes) {
  throw "大小不符: 期望 $($meta.Bytes), 实际 $actualBytes`n若压缩包来自别处，请核对 -Source。"
}
Write-Host "`n=== 校验 SHA-256 ==="
$actualSha = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
if ($actualSha -ne $meta.Sha) {
  throw "SHA-256 不符:`n  期望 $($meta.Sha)`n  实际 $actualSha"
}
Write-Host "SHA-256 OK"

if ($DryRun) {
  Write-Host ""
  Write-Host "=== (dry-run) 到此为止 ==="
  Write-Host "  压缩包已确认可用: $zip"
  Write-Host "  将解包到: $runtimeDir"
  Write-Host "  去掉 -DryRun 即真正安装。"
  exit 0
}

# ── 解包（兼容压平版与供体版）─────────────────────────────────────
Write-Host "`n=== 解包 ==="
$stage = Join-Path $work 'stage'
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
Expand-Archive -Path $zip -DestinationPath $stage -Force

$found = $null
if (Test-Path (Join-Path $stage 'ghidra\runtime.json')) {
  # 压平版：根目录直接是 ghidra/ x64dbg/
  $found = $stage
} else {
  # 供体版：外层 plugin/runtimes/
  $hit = Get-ChildItem $stage -Recurse -Directory -Filter 'runtimes' -ErrorAction SilentlyContinue |
    Where-Object { Test-Path (Join-Path $_.FullName 'ghidra\runtime.json') } |
    Select-Object -First 1
  if ($hit) { $found = $hit.FullName }
}
if (-not $found) {
  throw "压缩包里没找到含 ghidra\runtime.json 的目录。包结构可能变了，请检查 $zip"
}

if (Test-Path $runtimeDir) {
  $backup = "$runtimeDir.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
  Write-Host "已存在旧运行时，备份到 $backup"
  Move-Item $runtimeDir $backup
}
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $runtimeDir) | Out-Null
Move-Item $found $runtimeDir

Write-Host "`n=== 完成 ==="
Show-Status
Write-Host "`n完全退出 DSH 桌面端再启动，然后调用 purge_engine_tools 确认 runtime.ghidra.available=true。"
Write-Host "暂存目录可删: $work"
