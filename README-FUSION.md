# dsh-purge + fusion（缝合版）

DeepSeek Harness 插件：**dsh-purge 破甲清洗** + **dsh-infinite-gen-5 核心能力融合**。

一份仓库，clone 下来跑一个脚本就能恢复全部能力。

---

## 快速恢复（换机器 / 重装 DSH 之后）

```powershell
# 1. 克隆到任意目录（建议放 D 盘，运行时占 1.3 GB）
git clone <本仓库地址> D:\dsh-purge-fusion
cd D:\dsh-purge-fusion

# 2. 一键接入
.\setup\install.ps1

# 3. DSH 打开后，在 dsh-purge 面板点「应用」

# 4. 让补丁真正生效（关键，见下）
.\setup\take-effect.ps1

# 5. 完全退出 DSH 桌面端（托盘也退），再启动
```

> **第 4 步不能省。** DSH 是 Electron 应用，默认优先读 `resources\app.asar`。
> 插件补丁写进 `resources\app\`，只要 asar 还在，运行中的 DSH 就读不到 ——
> 表现为插件"装了但没效果"，甚至反复弹「应用无法启动」。
> `take-effect.ps1` 会先校验 `resources\app` 完整性，再把 asar 改名，带 `-Rollback` 回滚。

启动后调用 `purge_engine_tools`，期望：

```
toolset: "full"
activeCount: 43
runtime.ghidra.available: true
ready: true
```

### 运行时包会自动查找

自己从 Release 下好了 `fusion-runtime-1.29GB.zip`？**不用填路径**，直接装就行：

```powershell
.\setup\install.ps1
```

脚本会扫描桌面、下载、文档、临时目录和各盘根（含两层子目录），
找到字节数等于 `826929284` 的包就直接用，找不到才下载。

想指定别处或改过名：

```powershell
.\setup\install.ps1 -RuntimeArchive "D:\任意位置\任意名字.zip"
```

只验证不解包：

```powershell
.\setup\install-runtime.ps1 -DryRun
```

### 想跳过 1.3 GB 运行时？

```powershell
.\setup\install.ps1 -SkipRuntime
```

静态/离线车道（`purge_apk_audit`、`purge_bindiff`、`ig5_package`、`ig5_crypto`、`ig5_protocol`）照常可用；
引擎工具（`ig5_open`/`decompile`/`dbg` 等）会提示运行时缺失。之后想补装：

```powershell
.\setup\install-runtime.ps1
```

---

## 包含什么

| 部分 | 内容 |
|---|---|
| **破甲清洗** | dsh-purge 1.1.71 定制版（66 条补丁 + 提示词权威性清洗 + 演练台） |
| **引擎工具面** | 43 个 `ig5_*` 工具（core 8 / full 43），Ghidra 静态分析 + x64dbg 无头调试 |
| **算法车道** | 163 个纯 Node 模块：VM 保护还原 / 控制流平坦化 / 位向量求解 / 协议还原 / 加密分析 / 研究知识库 / APK / 固件 |
| **Worker 后端** | 139 个 Python 模块（反编译 / 微码 / 仿真 / 固件 / 协议 / VM） |
| **引擎适配** | Ghidra、x64dbg、自研 kernel 反编译、VMware VMCI |
| **技能** | 16 个（8 个 `purge-re-*` 工具无关方法论 + 8 个 `ig5-*` 供体原技能） |
| **自有工具** | `purge_apk_audit`、`purge_apk_result`、`purge_bindiff`、`purge_engine_tools`、`purge_fusion_status` |

---

## 目录结构

```
dsh-purge-fusion/
├── lib/
│   ├── index.js              dsh-purge 主入口（清洗 / 演练台 / 工具面）
│   ├── core.js               补丁引擎（82 条补丁定义，含 shim 缓存修复）
│   ├── redteam/              演练台（资产库 / 工具 / 预设 / 技能）
│   └── fusion/               ★ 融合层
│       ├── index.js          5 个 purge_* 工具 + 引擎工具面注册 + 16 技能
│       ├── engine.js         createEngine / wrapDefinition / sanitizeSchema / 边界裁剪
│       ├── selfcheck.mjs     163 项完整自检
│       ├── smoke.mjs         152 项冒烟
│       ├── verify-engine.mjs 8 项引擎端到端
│       ├── skills/           8 个 purge-re-* 方法论技能
│       └── vendor/           供体 dsh-infinite-gen-5 整树镜像
│           ├── source/       163 个算法模块
│           ├── worker/       139 个 Python worker
│           ├── adapters/     Ghidra / x64dbg / kernel / vmci
│           ├── skills/       8 个 ig5-* 原技能
│           └── runtimes/     ★ 不进 Git，走 Release（1.29 GB）
├── setup/
│   ├── install.ps1           一键接入
│   ├── install-runtime.ps1   运行时下载/校验/解包
│   ├── take-effect.ps1       app.asar 改名，让补丁真正生效（带校验与回滚）
│   └── reapply-fusion.ps1    被官方更新覆盖后用 git 恢复
├── package.json
└── cordis.patch.yml          插件挂载配置（含 dsh-purge-fusion 行）
```

---

## 运行时（1.29 GB）

`lib/fusion/vendor/runtimes/` **不在 Git 里**——因为 `jdk-21.0.12.1+1/lib/modules`
单文件 134.4 MB，超过 GitHub 单文件 100 MB 硬限制。

它通过 GitHub Release 附件分发：

| 项 | 值 |
|---|---|
| 内容 | Ghidra 12.1.4（本地 Gradle 源码构建）+ JDK 21.0.12.1 + Python 3.12.10 + x64dbg 2026.05.27 |
| 体积 | 解包后 1.29 GB / 6257 文件 |
| 来源 | 本仓库 Release 优先；缺失时回退到供体 `Minglink/dsh-infinite-gen-5` 的 v1.0.0 发行包 |
| 校验 | SHA-256 `a2459ddca1f19e5eec2d7918c504f133889809800a0b2771e379d3ce1459b54` |

离线安装：

```powershell
.\setup\install-runtime.ps1 -Archive 'D:\ig5-full.zip'
```

只校验不安装：

```powershell
.\setup\install-runtime.ps1 -VerifyOnly
```

---

## 被官方更新覆盖了怎么办

`dsh-purge` 的 `update.js` 会整目录覆盖 `lib/`、`cordis.patch.yml`、`package.json`。
只要**不执行插件官方更新**，融合层不受影响。

真更新了，跑一次：

```powershell
.\setup\reapply-fusion.ps1
```

它用 `git checkout` 把这三处还原，**运行时不在 Git 里所以不会被动**，无需重装。

---

## 自检

```powershell
# 完整自检（结构 / 加载 / 工具面 / schema / 技能 / 行为 / 引擎）
node lib\fusion\selfcheck.mjs

# 带样本的深度自检
node lib\fusion\selfcheck.mjs "<某个.apk>" "<某个.exe>"

# 单项回归
node lib\fusion\smoke.mjs
node lib\fusion\verify-engine.mjs "<某个.exe>"
```

三套都在临时 `DSH_HOME` 沙箱里跑，不受真实工具面设置影响。

---

## 工具面切换

默认 `full`（43 个工具全部可见）。想省上下文：

```
purge_engine_tools toolset=core
```

只留 8 个核心工具。选择持久化在
`$DSH_HOME/dsh-purge/fusion/ig5/engine-toolset.json`，重启后保持。

---

## 上游来源与许可证

本仓库是二次开发缝合版，包含多方代码，**各自许可证独立生效**：

| 来源 | 许可证 | 说明 |
|---|---|---|
| [dsh-purge](https://github.com/mmparko/dsh-purge) | MIT | 插件主体、破甲清洗、演练台 |
| [dsh-infinite-gen-5](https://github.com/Minglink/dsh-infinite-gen-5) | CC BY-NC-SA 4.0 | 融合层 `lib/fusion/vendor/`（非商业 + 相同方式共享） |
| Ghidra 12.1.4 | Apache-2.0 | `vendor/runtimes/ghidra/ghidra_12.1.4_PUBLIC/` |
| OpenJDK 21 (Temurin) | GPL-2.0 + Classpath Exception | `vendor/runtimes/ghidra/jdk-21.0.12.1+1/` |
| Python 3.12.10 | PSF License | `vendor/runtimes/ghidra/python/` |
| x64dbg | GPL-3.0 | `vendor/runtimes/x64dbg/` |
| Unicorn | GPL-2.0 | `vendor/worker/vendor/unicorn/` |
| Triton | Apache-2.0 | `vendor/worker/trace_vendor/` |

**注意**：供体是 **CC BY-NC-SA 4.0**（非商业性使用 + 相同方式共享）。
如果你的用途涉及商业，需要单独评估。各目录下的 `LICENSE` / `NOTICE` /
`THIRD_PARTY_NOTICES.txt` 为原始许可证文本，请勿删除。

本仓库只做**代码整合与适配**，未修改上游算法逻辑。对供体的两处改动记录在
`lib/fusion/vendor/PROVENANCE.json`：

1. `donor-index.js` 末尾追加一行 `export`（供诊断用）
2. `adapters/ghidra/worker.py` 的 `m_emulate()` 补 `sys.path`（上游 bug，`cpu_emulator` 在 `worker/`）

---

## 已修的上游问题

| 问题 | 位置 | 处理 |
|---|---|---|
| schema 关键字不被宿主支持（`minItems`/`maximum`/`pattern` 等） | `engine.js` `sanitizeSchema()` | 13 类降级，43/43 通过宿主校验 |
| 宿主不执行数值边界 | `engine.js` `collectBounds()`/`enforceBounds()` | 删 schema 关键字前先记边界，调用时裁剪 |
| `m_emulate` 缺 `sys.path` | `vendor/adapters/ghidra/worker.py` | 补 3 行 |
| `sessionKey` 引擎后缀丢失 | `engine.js` 目标→引擎映射表 | `ig5_open` 后同目标调用自动补齐 |
| 工具面切换不跨 turn | `fusion/index.js` 状态文件 | 持久化到 `engine-toolset.json` |
| `remember("shim")` 缓存空结果 | `lib/core.js` | 空结果不缓存，用户后装 shim 也能识别 |
