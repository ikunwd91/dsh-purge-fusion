# install.ps1 —— 一键接入：把本仓库装成可用的 DSH 插件
#
# 场景：换机器 / 重装 DSH / 从零恢复。
#   1. git clone <本仓库> D:\dsh-purge-fusion
#   2. cd D:\dsh-purge-fusion
#   3. .\setup\install.ps1
#   4. 完全退出 DSH 桌面端，再启动
#
# 挂载方式（与标准 profile 一致）：
#   A. profile/package.json 的 dependencies 加 "dsh-purge": "link:<本仓库>"
#   B. profile/package.json 的 dsh.profile.bundles 加 "dsh-purge"
#   C. profile/node_modules 建指向本仓库的 junction
#   D. 融合层由本插件自己的 cordis.patch.yml 挂载，无需额外配置
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

# ── 探测 profile ───────────────────────────────────────────────────
$profilesRoot = Join-Path $DshHome 'profiles'
if (-not (Test-Path $profilesRoot)) { throw "找不到 profiles 目录: $profilesRoot（DSH 装过吗？）" }

if (-not $Profile) {
  $candidates = Get-ChildItem $profilesRoot -Directory | Where-Object {
    Test-Path (Join-Path $_.FullName 'package.json')
  }
  if (-not $candidates) { throw "profiles 下没有可用的 profile" }
  $pick = $candidates | Where-Object { $_.Name -eq 'desktop' } | Select-Object -First 1
  if (-not $pick) { $pick = $candidates | Select-Object -First 1 }
  $Profile = $pick.Name
}
$profDir = Join-Path $profilesRoot $Profile
if (-not (Test-Path $profDir)) { throw "profile 不存在: $profDir" }
Write-Host "  profile: $Profile  ($profDir)"

# ── 1. node_modules junction ───────────────────────────────────────
Write-Host "`n=== 1/4 node_modules 链接 ==="
$nmDir = Join-Path $profDir 'node_modules'
$linkPath = Join-Path $nmDir 'dsh-purge'
if ($DryRun) {
  Write-Host "  (dry-run) junction: $linkPath -> $RepoRoot"
} else {
  New-Item -ItemType Directory -Force -Path $nmDir | Out-Null
  $needLink = $true
  if (Test-Path $linkPath) {
    $existing = (Get-Item $linkPath -Force).Target
    $existingStr = if ($existing) { ($existing -join '') } else { '' }
    if ($existingStr -and ($existingStr.TrimEnd('\') -eq $RepoRoot.TrimEnd('\'))) {
      Write-Host "  链接已正确，跳过"
      $needLink = $false
    } elseif ($existingStr) {
      Write-Host "  已有链接指向 $existingStr，重建"
      Remove-Item $linkPath -Force -Recurse
    } else {
      Write-Host "  $linkPath 是实体目录而非链接，跳过（请确认这是你要的）"
      $needLink = $false
    }
  }
  if ($needLink) {
    New-Item -ItemType Junction -Path $linkPath -Target $RepoRoot | Out-Null
    Write-Host "  已建 junction"
  }
}

# ── 2. profile package.json：dependencies + bundles ────────────────
Write-Host "`n=== 2/4 profile package.json ==="
$profPkgPath = Join-Path $profDir 'package.json'
if (-not (Test-Path $profPkgPath)) { throw "profile package.json 不存在: $profPkgPath" }

$raw = [System.IO.File]::ReadAllText($profPkgPath, [System.Text.Encoding]::UTF8)
$profPkg = $raw | ConvertFrom-Json

$linkSpec = 'link:' + ($RepoRoot -replace '\\', '/')
$needDep = -not ($profPkg.dependencies.PSObject.Properties.Name -contains 'dsh-purge')
$needBundle = -not ($profPkg.dsh.profile.bundles -contains 'dsh-purge')

if ($DryRun) {
  Write-Host "  (dry-run) 需要加 dependencies: $needDep，需要加 bundles: $needBundle"
  if ($needDep) { Write-Host "            依赖项: `"dsh-purge`": `"$linkSpec`"" }
} elseif ($needDep -or $needBundle) {
  Copy-Item $profPkgPath "$profPkgPath.bak-install" -Force
  # 用 Node 改 JSON，保证格式与转义正确
  $nodeScript = @"
const fs = require('fs');
const p = process.argv[1];
const linkSpec = process.argv[2];
const needDep = process.argv[3] === '1';
const needBundle = process.argv[4] === '1';
const j = JSON.parse(fs.readFileSync(p, 'utf8'));
if (needDep) {
  j.dependencies = j.dependencies || {};
  j.dependencies['dsh-purge'] = linkSpec;
}
if (needBundle) {
  j.dsh = j.dsh || {};
  j.dsh.profile = j.dsh.profile || {};
  j.dsh.profile.bundles = j.dsh.profile.bundles || [];
  if (!j.dsh.profile.bundles.includes('dsh-purge')) j.dsh.profile.bundles.push('dsh-purge');
}
fs.writeFileSync(p, JSON.stringify(j, null, 2) + '\n', 'utf8');
"@
  $tmpJs = Join-Path $env:TEMP "dsh-fusion-pkgpatch.cjs"
  Write-NoBom $tmpJs $nodeScript
  node $tmpJs $profPkgPath $linkSpec $(if ($needDep) { '1' } else { '0' }) $(if ($needBundle) { '1' } else { '0' })
  if ($LASTEXITCODE -ne 0) { throw "改写 profile package.json 失败" }
  Write-Host "  已写入（备份 $profPkgPath.bak-install）"
  if ($needDep) { Write-Host "    dependencies['dsh-purge'] = $linkSpec" }
  if ($needBundle) { Write-Host "    dsh.profile.bundles += 'dsh-purge'" }
} else {
  Write-Host "  dependencies 与 bundles 都已配置，跳过"
}

# ── 3. 运行时 ──────────────────────────────────────────────────────
Write-Host "`n=== 3/4 引擎运行时 ==="
$runtimeScript = Join-Path $RepoRoot 'setup\install-runtime.ps1'
if ($SkipRuntime) {
  Write-Host "  已跳过（-SkipRuntime）。静态/离线车道可用，引擎工具会提示运行时缺失。"
} elseif (-not (Test-Path $runtimeScript)) {
  Write-Host "  找不到 setup\install-runtime.ps1，跳过"
} elseif ($DryRun) {
  Write-Host "  (dry-run) 将调用 install-runtime.ps1"
} else {
  $rtArgs = @{ FusionRoot = (Join-Path $RepoRoot 'lib\fusion') }
  if ($RuntimeArchive) { $rtArgs.Archive = $RuntimeArchive }
  & $runtimeScript @rtArgs
  if ($LASTEXITCODE -ne 0) { Write-Host "  运行时安装未成功，可稍后单独跑 setup\install-runtime.ps1" }
}

# ── 4. 自检 ────────────────────────────────────────────────────────
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
