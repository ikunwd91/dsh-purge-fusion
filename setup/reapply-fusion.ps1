# reapply-fusion.ps1 —— 插件被官方更新覆盖后，用 git 把融合层恢复回来
#
# 背景：dsh-purge 的 update.js 用 COPY_NAMES = [lib, bin, docs, client.js,
#   cordis.patch.yml, screenshots.json, package.json, README*, LICENSE]
#   整目录覆盖自身文件。融合层在 lib/fusion + package.json exports +
#   cordis.patch.yml 挂载行三处，官方更新会一并抹掉。
#
# 本仓库本身就是插件，所以恢复 = 用 git 把这三处还原。
# 运行时（1.29 GB）在 .gitignore 里，不会被 git 碰到，无需重装。
#
# 用法：
#   .\setup\reapply-fusion.ps1              # 从 git 恢复 + 校验
#   .\setup\reapply-fusion.ps1 -DryRun      # 只看会做什么
#   .\setup\reapply-fusion.ps1 -NoGit       # 不用 git，改用 Release 包重装

[CmdletBinding()]
param(
  [switch]$DryRun,
  [switch]$NoGit
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $RepoRoot

function Write-NoBom([string]$Path, [string]$Text) {
  [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

Write-Host "=== 恢复融合层 ==="
Write-Host "  仓库根: $RepoRoot"

if ($NoGit) {
  Write-Host "`n=== -NoGit 模式 ==="
  Write-Host "  请重新 clone 仓库覆盖本目录，或从 Release 下载包解压。"
  Write-Host "  然后跑 .\setup\install.ps1"
  exit 0
}

# 检查 git 状态
$isGit = Test-Path (Join-Path $RepoRoot '.git')
if (-not $isGit) { throw "不是 git 仓库。请用 -NoGit 走手工重装，或重新 clone。" }

Push-Location $RepoRoot
try {
  Write-Host "`n=== 1/3 检查被改动的文件 ==="
  $status = git status --porcelain 2>&1
  if ($status) {
    Write-Host "  以下文件与仓库不一致（可能被官方更新覆盖）："
    $status | Select-Object -First 30 | ForEach-Object { Write-Host "    $_" }
    $more = ($status | Measure-Object).Count
    if ($more -gt 30) { Write-Host "    ...共 $more 项" }
  } else {
    Write-Host "  工作区干净，无需恢复。"
    Write-Host "  如果你确认融合层丢了，跑 git checkout -- . 强制还原。"
  }

  Write-Host "`n=== 2/3 从 git 还原 ==="
  if ($DryRun) {
    Write-Host "  (dry-run) 将执行: git checkout -- lib/ package.json cordis.patch.yml setup/"
  } else {
    git checkout -- lib/ package.json cordis.patch.yml setup/ 2>&1 | ForEach-Object { Write-Host "    $_" }
    if ($LASTEXITCODE -ne 0) { throw "git checkout 失败（exit $LASTEXITCODE）" }
    Write-Host "  已还原"
  }

  Write-Host "`n=== 3/3 校验 ==="
  if ($DryRun) {
    Write-Host "  (dry-run) 跳过"
  } else {
    $pkg = Get-Content (Join-Path $RepoRoot 'package.json') -Raw | ConvertFrom-Json
    $hasExport = $null -ne $pkg.exports.'./fusion'
    $yml = [System.IO.File]::ReadAllText((Join-Path $RepoRoot 'cordis.patch.yml'))
    $hasMount = $yml -match 'dsh-purge-fusion'
    Write-Host "  exports['./fusion'] : $(if ($hasExport) { '✅' } else { '❌' })"
    Write-Host "  cordis 挂载行       : $(if ($hasMount) { '✅' } else { '❌' })"
    Write-Host "  lib/fusion/index.js : $(if (Test-Path (Join-Path $RepoRoot 'lib\fusion\index.js')) { '✅' } else { '❌' })"
    Write-Host "  运行时              : $(if (Test-Path (Join-Path $RepoRoot 'lib\fusion\vendor\runtimes\ghidra\runtime.json')) { '✅ 在' } else { '⚠ 缺（跑 setup\install-runtime.ps1）' })"

    node (Join-Path $RepoRoot 'lib\fusion\selfcheck.mjs')
    if ($LASTEXITCODE -ne 0) { Write-Host "`n自检有失败项。" } else { Write-Host "`n自检通过。" }
  }
} finally { Pop-Location }

Write-Host ""
Write-Host "完成。完全退出 DSH 桌面端再启动。"
