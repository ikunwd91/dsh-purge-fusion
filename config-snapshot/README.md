# config-snapshot — 本机已配置好的 dsh-purge 快照

这个目录是从 **正在运行的那台机器** 上抓下来的配置与运行态，配合仓库里的插件源码，可以在任意机器上还原出同一套配置。

## 目录内容

| 路径 | 来源 | 说明 |
|---|---|---|
| `prompt/prompt-inject.md` | `%DSH_HOME%\prompt-inject.md` | 当前实际注入的系统提示词（破甲母版，24.9 KB） |
| `dsh-purge/applied.json` | `%DSH_HOME%\dsh-purge\` | 已应用补丁版本记录（`1.1.72` / `apply:1.1.72`） |
| `dsh-purge/installed-rev` | 同上 | 安装修订号 |
| `dsh-purge/jailbreak-preset` | 同上 | 当前破甲预设名（`coldcoffee`） |
| `dsh-purge/override-state.json` | 同上 | 注入覆盖状态（`customized:false`，hash + seedHash） |
| `dsh-purge/unpacked-asar.json` | 同上 | 官方 asar 解包记录 |
| `dsh-purge/settle-restart.guard` | 同上 | 重启保护标记 |
| `dsh-purge/engine-toolset.json` | 同上 | 融合引擎工具面（`full`） |
| `agent-presets/agent.cordis.yml` | `%DSH_HOME%\.agent-presets\redteam\` | 红队 agent 预设（cordis 装配，27.9 KB） |
| `agent-presets/anchor-gate.mjs` | 同上 | 锚点闸门实现 |
| `agent-presets/preset.yml` | 同上 | 预设元信息 |
| `profiles/desktop/cordis.patch.yml` | `%DSH_HOME%\profiles\desktop\` | 桌面 profile 的 cordis 补丁（插件挂载点） |
| `profiles/desktop/cordis.yml` | 同上 | profile 主配置 |
| `profiles/desktop/package.json` | 同上 | profile 依赖清单 |
| `profiles/desktop/pnpm-lock.yaml` / `pnpm-workspace.yaml` | 同上 | 锁文件 |
| `redteam/preset-declare.json` | `%DSH_HOME%\redteam\` | 红队模块预设声明 |
| `redteam/setup.sh` | 同上 | 红队环境装配脚本（25 KB，含工具链安装） |
| `redteam/skills/*.md` | `%DSH_HOME%\redteam\skills\` | 22 条红队作业技能（recon / 隧道 / 凭据 / 内网 / webshell / 免杀链路） |
| `workflow-lite/instances.json` | `%DSH_HOME%\workflow-lite\` | 工作流实例索引 |
| `workflow-lite/workflows/*.json` | `%DSH_HOME%\workflow-lite\` | 已编排的工作流图（含 `破甲制作`） |
| `workflow-lite/versions/破甲制作/1.json` | 同上 | 工作流版本快照 |
| `STATUS.md` | 生成 | 67/68 补丁明细、融合层移植清单、工具面清单 |

## 有意不收录

- `%DSH_HOME%\.credentials.yaml`（凭据）
- `%DSH_HOME%\sessions\`、`storages\session_projcache\`（会话历史）
- `%DSH_HOME%\profiles\desktop\node_modules\`（体积）
- `lib/fusion/vendor/runtimes/`（1.29 GB，GitHub 单文件 100 MB 硬限，走 Release 附件 + `setup/install-runtime.ps1`）
- 各 `*.bak-*` / `*.oneclick.bak` 备份件

## 还原步骤

```powershell
# 1) 装插件源码（本仓库）
git clone https://github.com/ikunwd91/dsh-purge-fusion.git
cd dsh-purge-fusion

# 2) 拉运行时（Ghidra / x64dbg / python，约 1.3 GB）
powershell -ExecutionPolicy Bypass -File .\setup\install-runtime.ps1

# 3) 铺配置
$H = "$env:USERPROFILE\.dsh"
Copy-Item .\config-snapshot\prompt\prompt-inject.md "$H\prompt-inject.md" -Force
Copy-Item .\config-snapshot\dsh-purge\*              "$H\dsh-purge\"       -Force
Copy-Item .\config-snapshot\agent-presets\*          "$H\.agent-presets\redteam\" -Force
Copy-Item .\config-snapshot\profiles\desktop\*       "$H\profiles\desktop\" -Force
Copy-Item .\config-snapshot\workflow-lite\workflows\* "$H\workflow-lite\workflows\" -Force
Copy-Item .\config-snapshot\workflow-lite\instances.json  "$H\workflow-lite\" -Force
Copy-Item .\config-snapshot\redteam\*                     "$H\redteam\" -Force -Recurse

# 4) 打补丁 + 重启
dsh purge apply      # 67/68 → 会跳过 MINIMAL_OFFICIAL_TOOLSET，与快照一致
dsh purge status     # 期望：67/68 applied, 0 pending
```

## 校验

```powershell
# 提示词 hash 应与 override-state.json 的 seedHash 对应
(Get-FileHash "$env:USERPROFILE\.dsh\prompt-inject.md" -Algorithm SHA256).Hash.ToLower()
# 期望输出：111bcf3a26ec7e300d592e298231fe7d611526de3b86c1cdd1002c94d89536ed
```
