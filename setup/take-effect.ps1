# take-effect.ps1 —— 让已写入 resources\app 的补丁真正生效
#
# 背景：DSH 是 Electron 应用，默认优先读 resources\app.asar。
# dsh-purge 的补丁写进 resources\app\（解包目录），只要 app.asar 还在，
# Electron 就读 asar、补丁完全不可见 —— 这也是插件看起来"没生效"或
# 启动异常的原因。
#
# 本脚本：校验 app 目录完整 → 把 app.asar 改名为 app.asar.bak → 提示重启。
# 有完整校验和回滚，不会把 DSH 弄成打不开。
#
# 用法：
#   .\setup\take-effect.ps1                  # 校验 + 改名
#   .\setup\take-effect.ps1 -DryRun          # 只看会做什么
#   .\setup\take-effect.ps1 -Rollback        # 改回 asar（恢复原状）

[CmdletBinding()]
param(
  [string]$DshRoot = '',
  [switch]$DryRun,
  [switch]$Rollback,
  [int]$MinPackages = 200
)

$ErrorActionPreference = 'Stop'

function Find-DshRoot {
  if ($DshRoot) { return (Resolve-Path $DshRoot).Path }
  # 1) 运行中的 DSH 进程
  $proc = Get-Process -Name "DeepSeek Harness","DeepSeek*" -ErrorAction SilentlyContinue |
    Where-Object { $_.Path } | Select-Object -First 1
  if ($proc) { return (Split-Path -Parent $proc.Path) }
  # 2) 桌面快捷方式
  $sh = New-Object -ComObject WScript.Shell
  foreach ($dir in @("$env:USERPROFILE\Desktop", "$env:PUBLIC\Desktop")) {
    foreach ($lnk in (Get-ChildItem $dir -Filter "*DeepSeek*" -ErrorAction SilentlyContinue)) {
      $t = $sh.CreateShortcut($lnk.FullName).TargetPath
      if ($t -and (Test-Path $t) -and ($t -match '\.exe$')) { return (Split-Path -Parent $t) }
    }
  }
  # 3) 常见位置
  foreach ($p in @("D:\DeepSeek-Harness-0.2.0-", "C:\DeepSeek-Harness-0.2.0-", "D:\dsh fake", "C:\dsh fake")) {
    if (Test-Path $p) { return (Resolve-Path $p).Path }
  }
  return $null
}

$root = Find-DshRoot
if (-not $root) { throw "找不到 DSH 安装目录。用 -DshRoot 'D:\...' 手动指定。" }

$res = Join-Path $root 'resources'
$asar = Join-Path $res 'app.asar'
$appDir = Join-Path $res 'app'

# 备份名兼容两种：本脚本的 app.asar.bak，以及手工/其他工具的 app.asar.purge-bak-<时间戳>
function Get-AsarBackups {
  return @(Get-ChildItem $res -Filter 'app.asar*bak*' -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ne 'app.asar' } | Sort-Object LastWriteTime -Descending)
}
$backups = Get-AsarBackups

Write-Host "=== DSH 目录检查 ==="
Write-Host "  安装根: $root"
Write-Host "  app.asar    : $(if (Test-Path $asar) { '存在' } else { '不存在' })"
Write-Host "  app.asar 备份: $(if ($backups.Count) { $backups[0].Name } else { '无' })"
Write-Host "  app\ 目录   : $(if (Test-Path $appDir) { '存在' } else { '不存在' })"

# ── 回滚模式 ───────────────────────────────────────────────────────
if ($Rollback) {
  if ($backups.Count -eq 0) { throw "找不到 app.asar 备份，无需回滚。" }
  if (Test-Path $asar) { Write-Host "`napp.asar 已存在，无需回滚。"; exit 0 }
  $pick = $backups[0]
  if ($DryRun) { Write-Host "`n(dry-run) 将把 $($pick.Name) 改回 app.asar"; exit 0 }
  Move-Item $pick.FullName $asar
  Write-Host "`n已回滚：$($pick.Name) → app.asar"
  Write-Host "重启 DSH 后补丁将不再生效（这是原始状态）。"
  exit 0
}

# ── 已经生效？ ─────────────────────────────────────────────────────
if ((-not (Test-Path $asar)) -and (Test-Path $appDir)) {
  Write-Host "`n补丁已生效（app.asar 已改名，Electron 读 resources\app）。"
  Write-Host "如果仍异常，检查 resources\app 是否完整，或重新点插件面板「应用」。"
  exit 0
}

# ── 校验 app 目录完整性（关键：不完整就改名会让 DSH 打不开）─────────
Write-Host "`n=== 校验 resources\app 完整性 ==="
if (-not (Test-Path $appDir)) {
  throw "resources\app 不存在。先在 dsh-purge 面板点「应用」让插件解包并打补丁，再来跑本脚本。"
}

$aiDir = Join-Path $appDir 'dsh\node_modules\@deepseek-ai'
if (-not (Test-Path $aiDir)) {
  throw "resources\app\dsh\node_modules\@deepseek-ai 不存在 —— app 目录不完整，改名会让 DSH 打不开。请先在插件面板点「应用」。"
}

$pkgCount = (Get-ChildItem $aiDir -Directory -ErrorAction SilentlyContinue | Measure-Object).Count
Write-Host "  @deepseek-ai 子包数: $pkgCount （阈值 $MinPackages）"
if ($pkgCount -lt $MinPackages) {
  throw "子包数只有 $pkgCount，低于阈值 $MinPackages —— app 目录解包不完整，不敢改名。请先在插件面板点「应用」。"
}

# 再确认几个关键入口存在
foreach ($rel in @(
  'dsh\node_modules\@deepseek-ai\dsh-agent-instructions\lib\index.js',
  'dsh\node_modules\@deepseek-ai\dsh-app-boot\lib\index.js',
  'lib\main.js'
)) {
  $fp = Join-Path $appDir $rel
  if (-not (Test-Path $fp)) { throw "resources\app 缺少关键文件: $rel —— 不敢改名。" }
}
Write-Host "  关键入口文件: 齐全 ✅"

# ── 执行改名 ───────────────────────────────────────────────────────
if ($DryRun) {
  Write-Host "`n(dry-run) 将把 app.asar 改名为 app.asar.bak（$([math]::Round((Get-Item $asar).Length/1MB,1)) MB）"
  Write-Host "(dry-run) 之后需完全退出 DSH 再启动"
  exit 0
}

Write-Host "`n=== 改名 app.asar → app.asar.purge-bak-<时间戳> ==="
Write-Host "  注意：purge 要挪走 asar 必须先结束 host，而被终止的 host 会由"
Write-Host "  旧 asar 里的原版 main.js 判定为致命 → 弹「应用无法启动」。"
Write-Host "  改名后重启即读解开目录，#83 生效，弹窗循环中断。"
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$target = Join-Path $res "app.asar.purge-bak-$stamp"
Move-Item $asar $target
Write-Host "  完成。备份保留在: $target"

Write-Host ""
Write-Host "=== 下一步 ==="
Write-Host "完全退出 DSH（托盘图标右键退出），再启动。"
Write-Host "启动后不应再出现「应用无法启动 / dsh desktop host stopped」弹窗。"
Write-Host ""
Write-Host "启动异常时回滚（一条命令）："
Write-Host "  .\setup\take-effect.ps1 -Rollback"
