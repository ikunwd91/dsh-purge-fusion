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

# 安全取嵌套属性：全新 profile 可能连 dependencies / dsh 都没有
function Get-Prop($obj, [string]$name) {
  if ($null -eq $obj) { return $null }
  $p = $obj.PSObject.Properties[$name]
  if ($null -eq $p) { return $null }
  return $p.Value
}

$depVal = Get-Prop $profPkg 'dependencies'
$hasDep = ($null -ne $depVal) -and (@($depVal.PSObject.Properties.Name) -contains 'dsh-purge')

$dshVal = Get-Prop $profPkg 'dsh'
$profVal = Get-Prop $dshVal 'profile'
$bundlesVal = Get-Prop $profVal 'bundles'
$hasBundle = ($null -ne $bundlesVal) -and (@($bundlesVal) -contains 'dsh-purge')

$needDep = -not $hasDep
$needBundle = -not $hasBundle

if ($DryRun) {
  Write-Host "  (dry-run) 需要加 dependencies: $needDep，需要加 bundles: $needBundle"
  if ($needDep) { Write-Host "            依赖项: `"dsh-purge`": `"$linkSpec`"" }
} elseif ($needDep -or $needBundle) {
  Copy-Item $profPkgPath "$profPkgPath.bak-install" -Force
  # 用 PowerShell 原生改 JSON，不依赖 node（新机器上可能没装）
  if ($needDep) {
    if ($null -eq (Get-Prop $profPkg 'dependencies')) {
      $profPkg | Add-Member -NotePropertyName dependencies -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    $profPkg.dependencies | Add-Member -NotePropertyName 'dsh-purge' -NotePropertyValue $linkSpec -Force
  }
  if ($needBundle) {
    if ($null -eq (Get-Prop $profPkg 'dsh')) {
      $profPkg | Add-Member -NotePropertyName dsh -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    if ($null -eq (Get-Prop $profPkg.dsh 'profile')) {
      $profPkg.dsh | Add-Member -NotePropertyName profile -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    $bundles = @()
    $existing = Get-Prop $profPkg.dsh.profile 'bundles'
    if ($null -ne $existing) { $bundles = @($existing) }
    if ($bundles -notcontains 'dsh-purge') { $bundles += 'dsh-purge' }
    $profPkg.dsh.profile | Add-Member -NotePropertyName bundles -NotePropertyValue $bundles -Force
  }
  $json = $profPkg | ConvertTo-Json -Depth 20
  Write-NoBom $profPkgPath ($json + "`n")
  Write-Host "  已写入（备份 $profPkgPath.bak-install）"
  if ($needDep) { Write-Host "    dependencies['dsh-purge'] = $linkSpec" }
  if ($needBundle) { Write-Host "    dsh.profile.bundles += 'dsh-purge'" }
  # 回读校验，防手写坏 JSON
  try {
    $check = [System.IO.File]::ReadAllText($profPkgPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $gotDep = Get-Prop (Get-Prop $check 'dependencies') 'dsh-purge'
    if ($gotDep -ne $linkSpec) { throw "回读校验失败：dependencies 未写入" }
    $gotBundles = Get-Prop (Get-Prop (Get-Prop $check 'dsh') 'profile') 'bundles'
    if (@($gotBundles) -notcontains 'dsh-purge') { throw "回读校验失败：bundles 未写入" }
    Write-Host "    回读校验 ✅"
  } catch {
    Copy-Item "$profPkgPath.bak-install" $profPkgPath -Force
    throw "改写 profile package.json 失败，已从备份还原：$($_.Exception.Message)"
  }
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
  # 幂等：已有运行时先查一遍，齐全就不重复下载 788 MB
  $ghidraManifest = Join-Path $RepoRoot 'lib\fusion\vendor\runtimes\ghidra\runtime.json'
  $x64dbgManifest = Join-Path $RepoRoot 'lib\fusion\vendor\runtimes\x64dbg\runtime.json'
  if ((Test-Path $ghidraManifest) -and (Test-Path $x64dbgManifest)) {
    Write-Host "  运行时已就位，跳过下载"
  } else {
    & $runtimeScript @rtArgs
  }
  # 不用 $LASTEXITCODE 判断——调用 PowerShell 脚本不会可靠地传递退出码
  # （它反映的是最后一次外部程序调用，比如 curl.exe，而不是脚本自身的 exit）。
  # 直接查产物更准。
  $rtOk = (Test-Path $ghidraManifest) -and (Test-Path $x64dbgManifest)
  if (-not $rtOk) {
    Write-Host "  ⚠ 运行时未就位，可稍后单独跑 setup\install-runtime.ps1"
  }
}

# ── 4. 自检 ────────────────────────────────────────────────────────
Write-Host "`n=== 4/4 自检 ==="
if ($DryRun) {
  Write-Host "  (dry-run) 跳过"
} else {
  # 找 node：PATH 优先，其次 DSH 自带（新机器上常见没装 node）
  $nodeExe = $null
  $cmd = Get-Command node -ErrorAction SilentlyContinue
  if ($cmd) { $nodeExe = $cmd.Source }

  if (-not $nodeExe) {
    # 先问正在运行的 DSH 进程要安装路径 —— 最准，不用猜
    $searchRoots = @()
    $dshProc = Get-Process -Name "DeepSeek Harness","DeepSeek*" -ErrorAction SilentlyContinue |
      Where-Object { $_.Path } | Select-Object -First 1
    if ($dshProc) { $searchRoots += (Split-Path -Parent $dshProc.Path) }
    try {
      $deskExe = Get-Content (Join-Path $DshHome 'dsh-purge\desktop-install.txt') -ErrorAction Stop
      if ($deskExe) { $searchRoots += (Split-Path -Parent $deskExe.Trim()) }
    } catch {}
    # 再扫常见安装位置
    foreach ($c in @(
      "D:\DeepSeek-Harness-0.2.0-", "C:\DeepSeek-Harness-0.2.0-",
      "$env:LOCALAPPDATA\Programs", "$env:ProgramFiles", "${env:ProgramFiles(x86)}"
    )) {
      if ($c -and (Test-Path $c)) { $searchRoots += $c }
    }

    foreach ($r in ($searchRoots | Select-Object -Unique)) {
      # 优先找 Electron 内嵌的 node
      $hit = Get-ChildItem $r -Recurse -Depth 8 -Filter "node.exe" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match 'runtime.*node.*bin' } | Select-Object -First 1
      if ($hit) { $nodeExe = $hit.FullName; break }
    }

    # 还找不到：DSH 本体是 Electron，可直接拿它当 node 跑脚本
    if (-not $nodeExe -and $dshProc) {
      $nodeExe = $dshProc.Path
      $env:ELECTRON_RUN_AS_NODE = '1'
      Write-Host "  用 DSH 本体当 node（ELECTRON_RUN_AS_NODE=1）"
    }
  }

  if (-not $nodeExe) {
    Write-Host "  ⚠ 找不到 node，跳过自检。"
    Write-Host "    启动 DSH 后调用 purge_engine_tools 确认 activeCount=43 即可。"
  } else {
    Write-Host "  使用 node: $nodeExe"
    Push-Location $RepoRoot
    try {
      & $nodeExe (Join-Path $RepoRoot 'lib\fusion\selfcheck.mjs')
      $code = $LASTEXITCODE
    } finally {
      Pop-Location
      Remove-Item Env:\ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue
    }
    if ($code -ne 0) { Write-Host "`n自检有失败项，请查看上面输出。" } else { Write-Host "`n自检通过。" }
  }
}

Write-Host ""
Write-Host "=== 完成 ==="

# ── app.asar 检查：补丁写进 resources\app，但 Electron 优先读 app.asar ──
if (-not $DryRun) {
  $dshRoot = $null
  $proc = Get-Process -Name "DeepSeek Harness","DeepSeek*" -ErrorAction SilentlyContinue |
    Where-Object { $_.Path } | Select-Object -First 1
  if ($proc) { $dshRoot = Split-Path -Parent $proc.Path }
  if (-not $dshRoot) {
    try {
      $deskExe = Get-Content (Join-Path $DshHome 'dsh-purge\desktop-install.txt') -ErrorAction Stop
      if ($deskExe) { $dshRoot = Split-Path -Parent $deskExe.Trim() }
    } catch {}
  }
  if ($dshRoot) {
    $asar = Join-Path $dshRoot 'resources\app.asar'
    if (Test-Path $asar) {
      Write-Host ""
      Write-Host "⚠ 检测到 app.asar 仍存在：" -ForegroundColor Yellow
      Write-Host "    $asar"
      Write-Host "  Electron 会优先读它，插件补丁写进 resources\app 后对运行中的 DSH 不可见。"
      Write-Host "  在插件面板点过「应用」之后，跑一次："
      Write-Host "    .\setup\take-effect.ps1"
      Write-Host "  它会校验 app 目录完整性再把 app.asar 改名（有 -Rollback 回滚）。"
    }
  }
}

Write-Host "完全退出 DSH 桌面端（托盘也退）再启动。"
Write-Host "启动后调用 purge_engine_tools 确认 toolset=full / activeCount=43。"
