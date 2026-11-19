# install.ps1 —— 一键接入：把本仓库装成一个可用的 DSH 插件
#
# 场景：换了机器 / 重装了 DSH / 想从零恢复。
#   1. git clone <本仓库> D:\dsh-purge-fusion
#   2. cd D:\dsh-purge-fusion
#   3. .\setup\install.ps1
#   4. 完全退出 DSH 桌面端，再启动
#
# 本脚本做四件事：
#   A. 在 profile 的 node_modules 里建指向本仓库的 junction
#   B. 往 profile 的 cordis.patch.yml 写 dsh-purge 与 dsh-purge-fusion 挂载行
#   C. 调 install-runtime.ps1 装 Ghidra/x64dbg 运行时（1.29 GB，可选跳过）
#   D. 跑 fusion 自检
#
# 用法：
#   .\setup\install.ps1                      # 完整安装
#   .\setup\install.ps1 -SkipRuntime         # 跳过运行时（只装静态/离线车道）
#   .\setup\install.ps1 -Profile web         # 指定 profile（默认自动探测）
#   .\setup\install.ps1 -DryRun              # 只看会做什么

[CmdletBinding()]
param(
  [string]$Profile = '',
  [switch]$SkipRuntime,
  [switch]$DryRun,
  [string]$RuntimeArchive
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$DshHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }

function Write-NoBom([string]$Path, [string]$Text) {
  [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

Write-Host "=== dsh-purge-fusion 安装 ==="
Write-Host "  仓库根: $RepoRoot"
Write-Host "  DSH_HOME: $DshHome"

if (-not (Test-Path (Join-Path $RepoRoot 'lib\fusion\index.js'))) {
  throw "仓库结构不对：找不到 lib\fusion\index.js。请在仓库根目录运行本脚本。"
}

# ── A. 探测 profile ────────────────────────────────────────────────
$profilesRoot = Join-Path $DshHome 'profiles'
if (-not (Test-Path $profilesRoot)) { throw "找不到 profiles 目录: $profilesRoot（DSH 装过吗？）" }

if (-not $Profile) {
  $candidates = Get-ChildItem $profilesRoot -Directory | Where-Object {
    Test-Path (Join-Path $_.FullName 'package.json')
  }
  if (-not $candidates) { throw "profiles 下没有可用的 profile" }
  # 优先 desktop，其次第一个
  $pick = $candidates | Where-Object { $_.Name -eq 'desktop' } | Select-Object -First 1
  if (-not $pick) { $pick = $candidates | Select-Object -First 1 }
  $Profile = $pick.Name
}
$profDir = Join-Path $profilesRoot $Profile
if (-not (Test-Path $profDir)) { throw "profile 不存在: $profDir" }
Write-Host "  profile: $Profile  ($profDir)"

# ── B. node_modules junction ───────────────────────────────────────
Write-Host "`n=== 1/4 node_modules 链接 ==="
$nmDir = Join-Path $profDir 'node_modules'
$linkPath = Join-Path $nmDir 'dsh-purge'
if ($DryRun) {
  Write-Host "  (dry-run) 将建 junction: $linkPath -> $RepoRoot"
} else {
  New-Item -ItemType Directory -Force -Path $nmDir | Out-Null
  if (Test-Path $linkPath) {
    $existing = (Get-Item $linkPath -Force).Target
    $existingStr = if ($existing) { ($existing -join '') } else { '' }
    if ($existingStr -and ($existingStr.TrimEnd('\') -ne $RepoRoot.TrimEnd('\'))) {
      Write-Host "  已有链接指向 $existingStr，重建"
      Remove-Item $linkPath -Force -Recurse
      New-Item -ItemType Junction -Path $linkPath -Target $RepoRoot | Out-Null
    } elseif ($existingStr) {
      Write-Host "  链接已正确，跳过"
    } else {
      Write-Host "  $linkPath 是实体目录而非链接，跳过（请确认这是你要的）"
    }
  } else {
    New-Item -ItemType Junction -Path $linkPath -Target $RepoRoot | Out-Null
    Write-Host "  已建 junction"
  }
}

# ── C. profile cordis.patch.yml ────────────────────────────────────
Write-Host "`n=== 2/4 profile 挂载行 ==="
$patchPath = Join-Path $profDir 'cordis.patch.yml'
if (-not (Test-Path $patchPath)) {
  if ($DryRun) { Write-Host "  (dry-run) 将新建 $patchPath" }
  else { Write-NoBom $patchPath "[]`n"; Write-Host "  已新建空 patch 文件" }
}
$yml = if (Test-Path $patchPath) { [System.IO.File]::ReadAllText($patchPath) } else { "[]`n" }

$needBundle = -not ($yml -match 'dsh-purge')
$needFusion = -not ($yml -match 'id:\s*dsh-purge-fusion')

if ($DryRun) {
  Write-Host "  (dry-run) 需要写 bundle 行: $needBundle，需要写 fusion 行: $needFusion"
} elseif ($needBundle -or $needFusion) {
  Copy-Item $patchPath "$patchPath.bak-install" -Force
  # 空文件是 "[]"，改成数组后追加
  if ($yml.Trim() -eq '[]') { $yml = '' }
  if ($needBundle) {
    $yml += @"

# dsh-purge 插件行（本仓库即插件本体）
- insert:
    - id: dsh-purge
      name: dsh-purge
"@
  }
  if ($needFusion) {
    $yml += @"

# 融合层：供体 dsh-infinite-gen-5 整树（43 个 ig5_* 引擎工具 + 静态算法车道 + 16 个技能）
- insert:
    - id: dsh-purge-fusion
      name: dsh-purge/fusion
      config:
        verbose: false
        engineToolset: full
"@
  }
  Write-NoBom $patchPath ($yml.TrimStart() + "`n")
  Write-Host "  已写入（备份 $patchPath.bak-install）"
} else {
  Write-Host "  两条挂载行都已存在，跳过"
}

# ── D. 运行时 ──────────────────────────────────────────────────────
Write-Host "`n=== 3/4 引擎运行时 ==="
$runtimeScript = Join-Path $RepoRoot 'setup\install-runtime.ps1'
if ($SkipRuntime) {
  Write-Host "  已跳过（-SkipRuntime）。静态/离线车道可用，引擎工具会提示运行时缺失。"
} elseif (-not (Test-Path $runtimeScript)) {
  Write-Host "  找不到 setup\install-runtime.ps1，跳过"
} elseif ($DryRun) {
  Write-Host "  (dry-run) 将调用 install-runtime.ps1"
} else {
  $args = @{ FusionRoot = (Join-Path $RepoRoot 'lib\fusion') }
  if ($RuntimeArchive) { $args.Archive = $RuntimeArchive }
  & $runtimeScript @args
  if ($LASTEXITCODE -ne 0) { Write-Host "  运行时安装未成功，可稍后单独跑 setup\install-runtime.ps1" }
}

# ── E. 自检 ────────────────────────────────────────────────────────
Write-Host "`n=== 4/4 自检 ==="
if ($DryRun) {
  Write-Host "  (dry-run) 跳过"
} else {
  Push-Location $RepoRoot
  try {
    node (Join-Path $RepoRoot 'lib\fusion\selfcheck.mjs')
    $code = $LASTEXITCODE
  } finally { Pop-Location }
  if ($code -ne 0) { Write-Host "`n自检有失败项，请查看上面输出。" } else { Write-Host "`n自检通过。" }
}

Write-Host ""
Write-Host "=== 完成 ==="
Write-Host "完全退出 DSH 桌面端（托盘也退）再启动。"
Write-Host "启动后调用 purge_engine_tools 确认 toolset=full / activeCount=43。"
