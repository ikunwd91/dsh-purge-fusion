# dsh-purge / fusion —— 缝合层说明

把 `dsh-infinite-gen-5`（无限五代 IG5，v1.3.0）的**核心能力整树**搬进 `dsh-purge`，
与本插件既有的清洗 / 演练台共存，不抢命名空间、不抢提示词装配、不抢 client slot。

## 来源

| 角色 | 仓库 | 版本 / commit |
|---|---|---|
| 宿主（本插件） | https://github.com/mmparko/dsh-purge | 1.1.71 |
| 供体（被搬） | https://github.com/Minglink/dsh-infinite-gen-5 | 1.3.0 / `8604739aab14e23233c0a2b3783e26a701e9e6bd` |

供体许可：CC BY-NC-SA 4.0（自有代码）+ 第三方各自许可，见供体 `LICENSE` / `THIRD_PARTY_NOTICES.txt`。

## 搬了什么（核心，不是边角）

### 1. 引擎工具面：43 个 `ig5_*` 工具（完整）

**Core 8（默认）**：`ig5_doctor`、`ig5_open`、`ig5_status`、`ig5_funcs`、`ig5_strings`、`ig5_decompile`、`ig5_close`、`ig5_profile`

**Full 追加 35**：
- 静态分析：`ig5_xrefs`、`ig5_calls`、`ig5_bytes`、`ig5_search`、`ig5_listing`、`ig5_scan`、`ig5_cfg`、`ig5_slice`、`ig5_fingerprint`、`ig5_stack`、`ig5_switches`、`ig5_vtables`
- 深度车道：`ig5_microcode`、`ig5_ir`、`ig5_bindiff`、`ig5_crypto`、`ig5_protocol`、`ig5_package`、`ig5_emulate`
- 写操作（供体原有语义）：`ig5_rename`、`ig5_patch_bytes`、`ig5_comment`、`ig5_analyze`、`ig5_set_type`、`ig5_undo`、`ig5_run_idapython`、`ig5_struct`、`ig5_switch_repair`、`ig5_sync`
- 调试/采集：`ig5_dbg`、`ig5_capture`、`ig5_capture_control`
- 工作台：`ig5_workspace`、`ig5_recovery`、`ig5_export_diff`

切换：`purge_engine_tools toolset=core|full`（不重建引擎、不丢会话）

### 2. 算法车道：`source/` 163 个模块（1.6 MB，全纯 Node）

| 车道 | 模块 | 能力 |
|---|---|---|
| **VM 保护还原** | `vm_bytecode`、`vm_cfg`、`vm_handler_profile`、`vm_handler_window`、`vm_phase_model`、`vm_phase_context`、`vm_program`、`vm_role_compare/profile/samples/validation`、`vm_recovery_case/io/plan/profile`、`vm_instances`、`vm_instance_workflow`、`vm_flow_*`、`vm_context_*`、`vm_observations`、`vm_observation_profile`、`vm_address_roles`、`vm_function_contract`、`vm_recurrence_profile`（30+） | 字节码提取、handler 语义建模、阶段上下文、实例识别、恢复规划、角色校验 |
| **控制流平坦化** | `cff_overlay`、`cff_state`、`cff_workflow`、`cff_state_workflow` | 状态机识别、overlay 计算、去平坦化 |
| **位向量求解** | `bitvector_solver`、`bitvector_contract`、`bitvector_provider`、`bitvector_provider_adapter`、`bitvector_replay`、`candidate_workflow` | 有界符号执行、候选验证、provider 抽象 |
| **协议还原** | `protocol_analysis`、`protocol_inference`、`protocol_state` | framing 推断、字段切分、状态机建模 |
| **加密分析** | `crypto_analysis`、`crypto_recovery` | XOR 恢复、AES 候选检索、认证验证 |
| **流量采集** | `capture_proxy`、`capture_ca`、`capture_payload`、`capture_service`、`capture_review`、`capture_state_trace`、`traffic_correlate` | 本地代理、CA 生成、载荷解析、样本关联 |
| **研究知识库** | `knowledge_*`（10）、`research_*`（10）、`method_registry`、`method_applicability`、`verification_registry`、`verification_result`、`verification_schema`、`verifier_catalog` | 方法注册表、验证契约、案例索引、研究状态 |
| **实验/证据** | `experiment_planner`、`experiment_shadow`、`evidence_registry`、`evidence_dependencies`、`obligation_evaluator`、`failure_*` | 实验规划、影子对比、证据依赖 |
| **语义 diff** | `semantic_diff`、`semantic_diff_async` | 函数级加权匹配 |
| **APK / 固件** | `apk_analysis/zip/axml/manifest/dex/der/rules`、`firmware_cli/fs/images/io/rules/scan/jobs` | 容器解析、AXML/DEX、能力规则、镜像解包 |
| **内存/上下文** | `lcm_memory`、`lcm_bridge`、`investigation_*`、`function_dossier`、`function_batches` | 调查任务、函数档案、批处理 |

### 3. Worker 后端：`worker/` 138 个 Python 模块（68 MB）

`ig5_worker.py` 主入口 + 各车道 worker：反编译、微码、仿真、固件、协议、VM、API trace、bitvector、flow semantics、kernel。

### 4. 引擎适配：`adapters/` 87 个文件（4.3 MB）

| 适配器 | 内容 |
|---|---|
| `ghidra/` | `worker.py`（88 KB 主 worker）、`deobfuscation_analysis.py`（27 KB）、`deobfuscation_symbolic.py`、`microcode_analysis.py`、`script_api.py`（23 KB）、`switch_analysis.py`、`native-core/`（C++ SLEIGH 扩展）、`jpype-patch/` |
| `x64dbg/` | `adapter.py`（75 KB）、`api_trace.py`（20 KB）、`ig5_bridge.cpp`（23 KB 命名管道桥） |
| `kernel/` | 自研 PE/ELF/CFG/IR 反编译管线 + `ig5_decompiler.dll`（2.7 MB） |
| `vmci/` | VMware VMCI guest 调试通道 |

### 5. 运行时：`vendor/runtimes/`（1.29 GB，已安装）

Ghidra 12.1.4（本地完整 Gradle 源码构建）+ JDK 21.0.12.1 + Python 3.12.10 + x64dbg 2026.05.27。
从供体 release 的 1.06 GB 发行包按 SHA-256 校验后解包：

```
asset:  IG5-1.0.0-Windows-x64-dsh021-full-20261010.zip
bytes:  1064580056
sha256: a2459ddca1f19e5eec2d7918c504f133889809800a0b277e379d3ce1459b54
```

### 6. 技能：16 个

| 来源 | 技能 | 说明 |
|---|---|---|
| 供体原技能（8） | `ig5-triage`、`ig5-deep-dive`、`ig5-patch-and-sign`、`ig5-diff`、`ig5-debug-live`、`ig5-crypto`、`ig5-protocol`、`ig5-reverse-agent` | 位于 `vendor/skills/`，工具名 `ig5_*` 直接对应，原样可用；含 5 个 references |
| 本层改写（8） | `purge-re-triage`、`purge-re-deep-dive`、`purge-re-unpack`、`purge-re-crypto-protocol`、`purge-re-patch-sign`、`purge-re-diff`、`purge-re-evidence`、`purge-apk-audit` | 工具无关方法论，不依赖引擎 |

### 7. 本层自有工具：5 个 `purge_*`

| 工具 | 作用 |
|---|---|
| `purge_apk_audit` | APK 静态审计（包名/组件/权限/证书/DEX 能力调用点/嵌套载荷） |
| `purge_apk_result` | 按 `result_id` + `select` 分节读落盘报告 |
| `purge_bindiff` | 函数级语义 bindiff（加权匹配 + 变更块 + 常量增删） |
| `purge_engine_tools` | 查看/切换引擎工具面（core 8 / full 43） |
| `purge_fusion_status` | 融合层自检（来源/移植清单/工具/技能/运行时/冲突隔离） |

## 为了让它在宿主里真跑起来，改了什么

### 1. 必须走供体 `apply()`（最关键）

供体的工具定义是「裸」的：`scope.run` 包装、协调/内存/证据装配、`expected_revision` 校验、
`queryState` 计算**全部在 `apply(ctx, config)` 里**对每个 definition 二次加工。

只调 `defineIg5Tools()` 拿到的定义缺少 `scope.run`，导致
`mgr.get(target)` 算出的 session key 没有 `::engine` 后缀，
任何后续工具都报「worker 不在运行」。

**本层方案**：用受控 stub ctx 调用供体 `apply()`，通过 `ctx.tools.register` 捕获
「已完整包装」的 43 个定义。

stub 的职责：

| stub 成员 | 行为 | 目的 |
|---|---|---|
| `tools.register` | 捕获定义 | 拿到完整包装后的工具面 |
| `tools.restrict` | **不提供** | 让 `installWorkflow` 走 instance-wide 分支，不猜 agent scope |
| `inject(...)` | 返回可调用且带 `.dispose()` 的 fiber | 供体 `workflow.dispose()` 会调 `fiber.dispose()` |
| `get(...)` | `undefined` | 让 approval gate / 诊断路由走降级 |
| `on(...)` | no-op | 不订阅宿主事件 |
| `effect(...)` | 执行并收集 disposer | 卸载时统一释放（含关闭会话、释放 worker） |

因此不注册 HTTP 路由、不挂 projection、不接管 webServer。

### 2. Schema 降级（不改就注册失败）

供体按 DSH **0.2.1-alpha.1** 写 schema，用了 `minItems`/`maxItems`/`minimum`/`maximum`/`pattern`。
本宿主 **0.2.0** 的 `assertObjectJsonSchema` 白名单只有
`type/oneOf/properties/required/additionalProperties/items/enum/const` + `description/title/default/examples`，
越界关键字直接抛 `UNSUPPORTED_SCHEMA`。

实测被拒：`ig5_decompile`（`batch.functions.minItems/maxItems`、`max_items.minimum/maximum`、
`page_max_bytes.minimum/maximum`）、`ig5_profile`（`history.ids.minItems/maxItems`）。

`sanitizeSchema()` 做**无损降级**：删越界键，可读约束并入 `description`：

```
max_items: {type:'number', minimum:1, maximum:1000}
→ {type:'number', description:'[minimum=1, maximum=1000]'}
```

降级清单在 `purge_engine_tools.schemaDropped` 可见。

### 3. 目标→引擎映射（修供体上游的一个坑）

`WorkerManager.sessionKey()` 用 `scope.getStore()?.engine || cfg.defaultEngine` 决定后缀。
用户 `ig5_open engine=ghidra` 之后若后续调用不带 engine，就回落到 `defaultEngine('reverse')`，
算出的键是 `path` 而非 `path::ghidra`，于是报「worker 不在运行」。

本层维护 `target → engine` 表，`ig5_open` 返回后自动记录，后续同目标调用自动补齐 engine。
不改供体代码，也不要求用户每次重复写。

### 4. 数据目录重定向

供体默认 `$DSH_HOME/ig5` → 本层重定向到 `$DSH_HOME/dsh-purge/fusion/ig5`。
与供体安装共存时工程/artifact/state/报告各自独立。

### 5. 运行时缺失不崩

`runtimes/` 缺失时：43 个工具照常注册，`purge_engine_tools` 返回 `available=false` + 原因，
`execute` 给可操作提示，**不 pending 宿主**。

### 6. 去重

供体 `defineIg5Tools` 与 `defineAdvancedTools` 有 14 个同名重叠
（`ig5_stack`、`ig5_switches`、`ig5_switch_repair`、`ig5_vtables`、`ig5_microcode`、`ig5_bindiff`、
`ig5_emulate`、`ig5_crypto`、`ig5_package`、`ig5_protocol`、`ig5_capture`、`ig5_capture_control`、
`ig5_ir`、`ig5_sync`）。按「首个胜出」去重，最终 **43 个**，与供体文档一致。

### 7. 供体技能落到 `vendor/skills/`

供体 `workflow.js` 用 `path.join(HERE, 'skills', name)` 读技能；缺文件会让整个
`ctx.effect` 抛 ENOENT、工具面注册中断。技能放到 `vendor/skills/` 后，供体 `apply()` 通过，
本层也从同一目录读并注册到宿主 skills 服务。

## 验证

```powershell
node --check lib/fusion/index.js
node --check lib/fusion/engine.js

# 完整自检：结构/加载/工具面/schema/技能/行为/引擎 六组，一条命令
node lib/fusion/selfcheck.mjs [apk-fixture] [sample.exe]

# 单项回归（可选）
node lib/fusion/smoke.mjs [apk-fixture]        # 静态/离线车道 + 工具面 + schema + 技能
node lib/fusion/verify-engine.mjs [sample.exe] # 引擎端到端
```

三套脚本都在临时 `DSH_HOME` 沙箱里跑（`mkdtemp`），**不受用户真实工具面设置影响**：
真实状态文件是 `full` 时它们仍按 `core` 断言，避免假失败。运行时探测走 `vendor/runtimes`，
不依赖 `HOME`。

### 实测结果

**冒烟 141 项全绿**：

```
OK — 141 passed, 0 failed, 0 skipped
```

覆盖：模块加载、5 个 purge 工具、8 个 ig5 core 工具、16 个技能元数据、
**宿主 `@deepseek-ai/dsh-tools` schema 子集校验（13 工具 × parameters/output）**、
core↔full 切换（8↔43，总数 13↔48）、引擎状态字段、APK 降级路径、分节读取、
非法输入拒绝、注册器抛错时 fail-soft。

**引擎端到端 8 项全绿**（notepad.exe，Ghidra 12.1.4 真实分析）：

```
PASS runtime ready
PASS doctor ok
PASS open returns functions      (n_funcs=794, bits=64, segments=9)
PASS open returns arch
PASS funcs returns list          (total=498)
PASS strings returns list        (ADVAPI32.dll ...)
PASS decompile returns code      (真实 C 代码)
PASS close ok
OK — 8 passed, 0 failed
```

额外手工验证：`ig5_cfg`（blocks/mermaid/edges/queryState）、`ig5_xrefs`（6 hits）、
`ig5_scan`（entropies/crypto_markers）、`ig5_package action=apk`（真实 APK 分节读）、
`ig5_crypto action=inspect`（离线车道）。

## 冲突隔离设计

| 维度 | 处理 |
|---|---|
| 工具命名 | `purge_*`（5，本层自有）+ `ig5_*`（43，供体原名，兼容供体技能）+ 既有 `purge_apply/revert/status` + `redteam_*`，无重叠 |
| 技能命名 | `purge-*` 8 + `ig5-*` 8；runtime rank 250，用户 `$DSH_HOME/skills` 同名可覆盖 |
| 服务注入 | 只 `inject = ['tools']`；`skills` 走可选 `ctx.inject(['skills'])`，缺服务只降级 |
| 提示词 | 不注册任何 systemPrompt 段落，不碰 `personaPrefix`/`postPrompt`/`postPromptOrder` |
| client | 不声明 `dsh.client`，不动浏览器半侧，不注册 slot |
| HTTP | 不注册任何路由（供体 `/ig5-diag` `/ig5-jobs` `/ig5-data` 不搬） |
| 审批 | 不叠加供体 approval gate（stub `ctx.get` 返回 undefined）；写工具走宿主审批链 + purge 的 `hooksDenyBypass` |
| 失败软着陆 | `apply()` 整体 try/catch；每工具注册单独 try/catch；引擎装配失败降级为「工具不可用」 |
| 数据目录 | `$DSH_HOME/dsh-purge/fusion/` 独立，与供体 `$DSH_HOME/ig5` 隔离 |
| vendor 只读 | 升级供体整目录替换 `vendor/`，适配只在 `lib/fusion/*.js`（`donor-index.js` 仅追加一行 export） |

## 生效与回滚

- 生效：完全退出 DSH 桌面端再启动（`cordis.patch.yml` 新增 `dsh-purge-fusion` 行）。
- 自检：`purge_engine_tools` → `catalogCount=43`、`toolset=full`、`runtime.ghidra.available=true`。
- 回滚：删 `cordis.patch.yml` 里 `dsh-purge-fusion` 那几行，或整目录删 `lib/fusion`。
- 运行时重装：`D:\YOUxi\gouzuo\fusion-patch\install-runtime.ps1`（SHA-256 校验，支持离线包）。

## 关于插件官方更新

`dsh-purge` 的 `update.js` 用 `COPY_NAMES = [lib, bin, docs, client.js, cordis.patch.yml,
screenshots.json, package.json, README*, LICENSE]` 整目录覆盖自身文件。融合层落在三处：

| 落点 | 更新时 |
|---|---|
| `lib/fusion/`（含 1.29 GB 运行时） | 被删 |
| `package.json` 的 `exports['./fusion']` | 被覆盖 |
| `cordis.patch.yml` 的 `dsh-purge-fusion` 挂载行 | 被覆盖 |

**只要不执行插件官方更新，融合层不受任何影响。** 若确实更新了，跑一次：

```powershell
cd D:\YOUxi\gouzuo\fusion-patch
.\reapply-fusion.ps1              # 铺回 + 幂等补 exports/挂载行 + 自检
.\reapply-fusion.ps1 -DryRun      # 只看会做什么
```

`reapply-fusion.ps1` 用 `robocopy /E /XD runtimes` 覆盖代码但**保留已装运行时**，
所有写入都用 UTF-8 无 BOM（BOM 会让 `JSON.parse` 失败，曾踩过）。
