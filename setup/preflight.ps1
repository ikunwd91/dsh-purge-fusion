# preflight.ps1 —— 安装前环境自检
#
# 专查新机器上最容易踩的两类坑：
#   1. DSH 装在非预期路径（D:\dsh fake\、C:\Program Files\... 等）
#   2. 机器上有多个 DSH 安装 / 多份插件目录，导致装到错的那个
#
# 只读，不改任何东西。先跑这个，确认路径对了再 install。
#
# 用法：
#   .\setup\preflight.ps1
#   .\setup\preflight.ps1 -RuntimeArchive "D:\ai\fusion-runtime-1.29GB.zip"

[CmdletBinding()]
param(
  [string]$RuntimeArchive = ''
)

$ErrorActionPreference = 'Continue'
$RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$DshHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }

$problems = @()
$warns = @()

function Section($t) { Write-Host ""; Write-Host "=== $t ===" }

# ── 1. 本仓库位置 ──────────────────────────────────────────────────
Section "1. 当前运行的仓库"
Write-Host "  本脚本所在: $RepoRoot"
Write-Host "  有 lib\fusion\index.js: $(if (Test-Path (Join-Path $RepoRoot 'lib\fusion\index.js')) { '✅' } else { '❌' })"

# 找机器上所有同名仓库副本，避免装错
$names = @('dsh-purge-fusion', 'dsh-purge-fusion-main')
$copies = @()
foreach ($drive in (Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Used -ne $null })) {
  foreach ($n in $names) {
    $p = Join-Path $drive.Root $n
    if (Test-Path $p) { $copies += $p }
  }
}
$copies = $copies | Select-Object -Unique
if ($copies.Count -gt 1) {
  Write-Host ""
  Write-Host "  ⚠ 发现 $($copies.Count) 份仓库副本：" -ForegroundColor Yellow
  foreach ($c in $copies) {
    $isThis = ($c.TrimEnd('\') -eq $RepoRoot.TrimEnd('\'))
    Write-Host "    $(if ($isThis) { '← 当前这份' } else { '         ' }) $c"
  }
  Write-Host "  确认你要用的是哪份。装错会导致配置指向旧代码。"
  $warns += "存在 $($copies.Count) 份仓库副本，确认用哪份"
}

# ── 2. 找所有 DSH 安装 ─────────────────────────────────────────────
Section "2. DSH 安装位置"
$installs = @()

# 2a. 运行中的进程（最准）
$procs = Get-Process -ErrorAction SilentlyContinue |
  Where-Object { $_.ProcessName -match 'DeepSeek|dsh' -and $_.Path -match '\.exe$' }
foreach ($p in $procs) {
  $d = Split-Path -Parent $p.Path
  if (Test-Path (Join-Path $d 'resources')) {
    $installs += [pscustomobject]@{ Path = $d; Source = "运行中进程 (PID $($p.Id))"; Running = $true }
  }
}

# 2b. 桌面快捷方式
$sh = New-Object -ComObject WScript.Shell
foreach ($dir in @("$env:USERPROFILE\Desktop", "$env:PUBLIC\Desktop", "$env:APPDATA\Microsoft\Windows\Start Menu\Programs")) {
  foreach ($lnk in (Get-ChildItem $dir -Filter "*.lnk" -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'DeepSeek|Harness' })) {
    $t = $sh.CreateShortcut($lnk.FullName).TargetPath
    if ($t -and (Test-Path $t) -and ($t -match '\.exe$')) {
      $d = Split-Path -Parent $t
      if (Test-Path (Join-Path $d 'resources')) {
        $installs += [pscustomobject]@{ Path = $d; Source = "快捷方式 $($lnk.Name)"; Running = $false }
      }
    }
  }
}

# 2c. 盘根常见目录
foreach ($drive in (Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Used -ne $null })) {
  $base = $drive.Root
  if (-not (Test-Path $base)) { continue }
  $dirs = @()
  try { $dirs = Get-ChildItem $base -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'harness|dsh|deepseek' } } catch {}
  foreach ($d in $dirs) {
    if (Test-Path (Join-Path $d.FullName 'resources')) {
      $installs += [pscustomobject]@{ Path = $d.FullName; Source = "盘扫描 $base"; Running = $false }
    }
  }
}

$installs = $installs | Group-Object Path | ForEach-Object { $_.Group[0] }

if ($installs.Count -eq 0) {
  Write-Host "  ❌ 没找到任何 DSH 安装" -ForegroundColor Red
  $problems += "找不到 DSH 安装，请先装 DSH 本体"
} else {
  foreach ($i in $installs) {
    $res = Join-Path $i.Path 'resources'
    $asar = Test-Path (Join-Path $res 'app.asar')
    $app = Test-Path (Join-Path $res 'app')
    $exe = Get-ChildItem $i.Path -Filter "*.exe" -File -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -match 'DeepSeek|Harness' } | Select-Object -First 1
    Write-Host ""
    Write-Host "  $(if ($i.Running) { '★ 正在运行' } else { '  ' }) $($i.Path)"
    Write-Host "      来源: $($i.Source)"
    Write-Host "      主程序: $(if ($exe) { $exe.Name } else { '未找到 exe' })"
    Write-Host "      app.asar : $(if ($asar) { '存在（Electron 会读它，补丁不可见）' } else { '不存在' })"
    Write-Host "      app\ 目录: $(if ($app) { '存在' } else { '不存在' })"
  }
  if ($installs.Count -gt 1) {
    Write-Host ""
    Write-Host "  ⚠ 发现 $($installs.Count) 个 DSH 安装！" -ForegroundColor Yellow
    Write-Host "  装到错的那个 = 你启动的那个不会生效。"
    Write-Host "  建议：只保留一个，或确认 ★ 正在运行 的那个才是你要用的。"
    $warns += "机器上有 $($installs.Count) 个 DSH 安装"
  }
}

# ── 3. DSH_HOME 与 profile ─────────────────────────────────────────
Section "3. DSH_HOME 与 profile"
Write-Host "  DSH_HOME: $DshHome"
"  (来源: $(if ($env:DSH_HOME) { '环境变量 DSH_HOME' } else { '默认 %USERPROFILE%\.dsh' }))" | Write-Host
if (-not (Test-Path $DshHome)) {
  Write-Host "  ❌ DSH_HOME 不存在" -ForegroundColor Red
  $problems += "DSH_HOME 不存在，DSH 装过并跑过吗"
} else {
  $profRoot = Join-Path $DshHome 'profiles'
  if (Test-Path $profRoot) {
    $profs = Get-ChildItem $profRoot -Directory -ErrorAction SilentlyContinue
    Write-Host "  profile 数量: $($profs.Count)"
    foreach ($pf in $profs) {
      $pkgPath = Join-Path $pf.FullName 'package.json'
      $hasPkg = Test-Path $pkgPath
      $dep = ''
      $bundles = ''
      if ($hasPkg) {
        try {
          $j = Get-Content $pkgPath -Raw | ConvertFrom-Json
          $dep = if ($j.dependencies.'dsh-purge') { "dsh-purge=$($j.dependencies.'dsh-purge')" } else { '无 dsh-purge' }
          $bundles = if ($j.dsh.profile.bundles) { "bundles=$(@($j.dsh.profile.bundles) -join ',')" } else { '无 bundles' }
        } catch { $dep = 'package.json 解析失败' }
      }
      $hasLink = Test-Path (Join-Path $pf.FullName 'node_modules\dsh-purge')
      Write-Host "    · $($pf.Name)  $(if ($hasPkg) { '' } else { '[无 package.json]' }) $dep | $bundles | junction=$(if ($hasLink) { '有' } else { '无' })"
    }
    if ($profs.Count -gt 1) {
      Write-Host "  ⚠ 有 $($profs.Count) 个 profile。install.ps1 默认选 desktop，可用 -Profile 指定。" -ForegroundColor Yellow
      $warns += "有 $($profs.Count) 个 profile，确认装到哪个"
    }
  } else {
    Write-Host "  ❌ 没有 profiles 目录" -ForegroundColor Red
    $problems += "profiles 目录不存在"
  }
}

# ── 4. 运行时压缩包 ────────────────────────────────────────────────
Section "4. 运行时压缩包"
$expectedBytes = 826929284
$expectedSha = 'bd1af6a79d7f073ab66d6cfdf1896da601602c55e821df1a5751072afd5100c0'
if ($RuntimeArchive) {
  if (-not (Test-Path $RuntimeArchive)) {
    Write-Host "  ❌ 指定的包不存在: $RuntimeArchive" -ForegroundColor Red
    $problems += "RuntimeArchive 路径不存在"
  } else {
    $f = Get-Item $RuntimeArchive
    Write-Host "  $($f.FullName)"
    Write-Host "  大小: $([math]::Round($f.Length/1MB,1)) MB ($($f.Length) 字节)"
    if ($f.Length -ne $expectedBytes) {
      Write-Host "  ❌ 大小不符，期望 $expectedBytes" -ForegroundColor Red
      $problems += "运行时包大小不符，可能没下完整"
    } else {
      Write-Host "  大小符合 ✅（SHA 由安装脚本校验）"
    }
  }
} else {
  # 找找机器上有没有现成的
  $found = @()
  foreach ($dir in @("$env:USERPROFILE\Downloads", "$env:USERPROFILE\Desktop", 'D:\', 'C:\')) {
    if (Test-Path $dir) {
      try { $found += Get-ChildItem $dir -Filter "fusion-runtime*.zip" -File -ErrorAction SilentlyContinue -Depth 2 } catch {}
    }
  }
  if ($found.Count) {
    Write-Host "  找到现成的包："
    foreach ($x in $found) { Write-Host "    $($x.FullName)  $([math]::Round($x.Length/1MB,1)) MB" }
    Write-Host "  用 -RuntimeArchive 指向它，可跳过 788 MB 下载。"
  } else {
    Write-Host "  未指定，也没找到现成的包。"
    Write-Host "  安装时会自动从 Release 下载（约 788 MB）。"
  }
}

# ── 5. 依赖工具 ────────────────────────────────────────────────────
Section "5. 依赖工具"
$node = Get-Command node -ErrorAction SilentlyContinue
Write-Host "  node: $(if ($node) { "$($node.Source) $((& node --version) 2>&1)" } else { '未在 PATH（安装脚本会自动找 DSH 自带的）' })"
$curl = Get-Command curl.exe -ErrorAction SilentlyContinue
Write-Host "  curl: $(if ($curl) { $curl.Source } else { '缺失' })"
$git = Get-Command git -ErrorAction SilentlyContinue
Write-Host "  git : $(if ($git) { '有' } else { '无（不需要，用 ZIP 安装）' })"
Write-Host "  PowerShell: $($PSVersionTable.PSVersion)"
Write-Host "  ExecutionPolicy(Process): $(Get-ExecutionPolicy -Scope Process)"

# ── 6. 汇总 ────────────────────────────────────────────────────────
Section "汇总"
if ($problems.Count -eq 0 -and $warns.Count -eq 0) {
  Write-Host "  ✅ 环境正常，可以直接安装。" -ForegroundColor Green
} else {
  if ($problems.Count) {
    Write-Host "  ❌ 必须先解决：" -ForegroundColor Red
    foreach ($p in $problems) { Write-Host "     - $p" -ForegroundColor Red }
  }
  if ($warns.Count) {
    Write-Host "  ⚠ 需要留意：" -ForegroundColor Yellow
    foreach ($w in $warns) { Write-Host "     - $w" -ForegroundColor Yellow }
  }
}

Write-Host ""
Write-Host "=== 下一步 ==="
if ($RuntimeArchive) {
  Write-Host "  cd $RepoRoot"
  Write-Host "  .\setup\install.ps1 -RuntimeArchive `"$RuntimeArchive`""
} else {
  Write-Host "  cd $RepoRoot"
  Write-Host "  .\setup\install.ps1"
}
