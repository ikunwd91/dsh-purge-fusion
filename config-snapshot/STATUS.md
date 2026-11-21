# 板上状态快照 / Applied State Snapshot

- 快照时间：2026-11-21（本机）
- 插件版本：`dsh-purge` **1.1.72**（`installed-rev = apply:1.1.72`，`applied.json` 同步）
- 宿主：desktop（`D:\deepseek\DeepSeek Harness.exe`）
- DSH_HOME：`C:\Users\Administrator\.dsh`
- 提示词注入：`.dsh/prompt-inject.md`（见 `prompt/prompt-inject.md`），override 状态 `default`，未改动（`customized: false`）
- 破甲预设（jailbreak preset）：`coldcoffee`
- 融合层：`dsh-purge-fusion` 1.0.0
  - base：`mmparko/dsh-purge`（宿主：提示词权威性清洗 + 演练台 + 工具面）
  - donor：`Minglink/dsh-infinite-gen-5` v1.3.0 @ `8604739aab14e23233c0a2b3783e26a701e9e6bd`
  - 引擎：Ghidra + x64dbg + bundled reverse provider，工具面 `full`（43/43 激活）
  - 技能：16 条已注册（`purge-re-*` 8 条自带 + `ig5-*` 8 条供体迁移）

## 补丁状态 / Patch Status

**67/68 applied，0 pending，1 skipped**

| # | ID | 类别 | 状态 |
|---|---|---|---|
| 1 | WORKSPACE_CONTEXT_INTRO | 提示词 | applied |
| 4 | SYSTEM_PROMPT_PERSONA | 提示词 | applied |
| 5 | APPROVAL_NEVER_SENTENCE | 提示词 | applied |
| 6 | SANDBOX_DENY_FILE_WRITE | 代码 | applied |
| 7 | SANDBOX_MODE_DEFAULT | 代码 | applied |
| 8 | APPROVAL_POLICY_DEFAULT | 代码 | applied |
| 13 | ESCALATION_WIDENING_EXEMPT | 代码 | applied |
| 14 | ESCALATION_GRANT_UNCONDITIONAL | 代码 | applied |
| 15 | SANDBOX_CONFINE_PASSTHROUGH | 代码 | applied |
| 16 | FS_FENCE_DISABLED | 代码 | applied |
| 17 | FS_OBSERVATION_INTENT_FREE | 代码 | applied |
| 18 | REPEAT_TOOL_REMINDER_DISABLED | 代码 | applied |
| 19 | TOOL_RESULT_PRUNER_DISABLED | 代码 | applied |
| 21 | BASH_TIMEOUT_RESTORE | 代码 | applied |
| 22 | READ_CAPS_RAISED | 代码 | applied |
| 23 | SUBAGENT_MAXDEPTH_RAISED | 代码 | applied |
| 24 | PRESET_FETCH_ENABLED | 代码 | applied |
| 25 | HARNESS_IDENTITY_STRIP | 提示词 | applied |
| 26 | MINIMAL_PERSONA_PURGE | 提示词 | applied |
| 29 | TOOL_WEB_UNTRUSTED_NEUTRAL | 工具 | applied |
| 30 | HOOKS_CLAUDE_DENY_ALLOW | 工具 | applied |
| 32 | WEB_SURFACE_IDENTITY_NEUTRAL | 提示词 | applied |
| 33 | TOOL_SHELL_DENIAL_PROMPT | 提示词 | applied |
| 34 | SANDBOX_HINT_NEUTRAL | 提示词 | applied |
| 35 | ESCALATION_NEVER_REJECT | 代码 | applied |
| 36 | TOOL_FS_ESCALATION_SCHEMA | 提示词 | applied |
| 37 | SUBAGENT_SCOPE_LOCK_NEUTRAL | 提示词 | applied |
| 38 | PERSONA_TEXT_PREFIX_ALIAS | 代码 | applied |
| 39 | SESSION_V0_PLUGIN_SUMMARY_ALIAS | 代码 | applied |
| 40 | COMPLETE_PROMPT_KEEP_INJECT | 0.1.5 兼容 | applied |
| 42 | SETTINGS_LEGACY_API | 代码 | applied |
| 43 | WEB_PRESET_IDENTITY_STRIP | 提示词 | applied |
| 45 | OFFICIAL_DESKTOP_UPDATE_HANDOFF | 代码 | applied |
| 47 | ANTHROPIC_OAUTH_NO_CLAUDE_IDENTITY | 0.2.0 兼容 | applied |
| 48 | TOOL_SHELL_DELETE_MOVE_NEUTRAL | 工具 | applied |
| 49 | ANTHROPIC_OAUTH_CLI_NEUTRAL | 0.2.0 兼容 | applied |
| 50 | SESSION_REFERENCE_FRAMING_NEUTRAL | 提示词 | applied |
| 51 | FRESH_SESSION_FULL_ACCESS | 代码 | applied |
| 52 | SESSION_LOG_UPLOAD_DEFAULT_OFF | 代码 | applied |
| 53 | WEB_SURFACE_PROHIBITION | 提示词 | applied |
| 54 | DELIVERABLE_DO_NOT | 提示词 | applied |
| 55 | SYSTEM_PROMPT_REPLACE_HEAD | 代码 | applied |
| 56 | REWIND_HIDE_CUT_ONLY | 代码 | applied |
| 57 | DEEPSEEK_SYSTEM_ROLE | 代码 | applied |
| 58 | REWIND_SKIP_DERIVE | 代码 | applied |
| 59 | OFFICIAL_AUTO_REVIEW_PASSTHROUGH | 代码 | applied |
| 60 | OFFICIAL_RUN_CODE_APPROVAL_NEUTRAL | 工具 | applied |
| 61 | OFFICIAL_SANDBOX_POLICY_NEUTRAL | 提示词 | applied |
| 62 | OFFICIAL_TOOL_ASK_FAILOPEN | 代码 | applied |
| 63 | OFFICIAL_PLAN_MODE_NEUTRAL | 提示词 | applied |
| 64 | HOOKS_STOP_STEER_NEUTRAL | 工具 | applied |
| 66 | SYSTEM_PROMPT_RENDER_GUARD | 代码 | applied |
| 67 | AGENT_LOOP_MESSAGES_GUARD | 代码 | applied |
| 68 | SYSTEM_NODES_CONTENT_GUARD | 代码 | applied |
| 69 | MODEL_STREAM_RELEASE | 代码 | applied |
| 70 | PRESET_SHELL_NETWORK | 提示词 | applied |
| 72 | MESSAGES_SYSTEM_CURRENT | 代码 | applied |
| 73 | PRESET_BASH_MIRROR_LINE | 提示词 | applied |
| 74 | ASSEMBLE_BEFORE_PRESTEP | 代码 | applied |
| 75 | REWIND_RESET_TODOS | 代码 | applied |
| 77 | REWIND_DROP_SENT_ON_APPEND | 代码 | applied |
| 78 | OVERLAY_RESTORE_FROM_BAK | 代码 | applied |
| 80 | MINIMAL_OFFICIAL_TOOLSET | 工具 | **skipped** |
| 82 | DESKTOP_SHELL_PROFILE_FALLBACK | 代码 | applied |
| 83 | DESKTOP_HOST_CLOSE_NO_FATAL | 代码 | applied |
| 85 | SESSION_PROMPT_ALWAYS_FOLLOWUP | 代码 | applied |
| 87 | HUNG_PROMPT_LF_NEEDLE | 代码 | applied |
| 90 | STOP_REASON_REFUSAL_OK | 代码 | applied |

## 融合层工具 / Tools

`purge_apk_audit`、`purge_apk_result`、`purge_bindiff`、`purge_engine_tools`、`purge_apply`、`purge_revert`、`purge_status`、`purge_fusion_status`；引擎侧 43 个 `ig5_*` 全部激活。

## 融合层未移植项 / Not Ported

- `client.js` 工作台 UI（与 purge 的 slot 注册冲突）
- `cordis.patch.yml` 的 systemPrompt 注入（提示词统一由 `lib/index.js` 装配钩子负责）
- 供体 `index.js` 的 `apply()`（只复用 `defineIg5Tools`）
- webServer 路由 `/ig5-diag` `/ig5-jobs` `/ig5-data`

## shim

`dsh.cmd = patched`；`dsh.ps1` / `dsh` 在 desktop 布局下不适用（启动器只有 cmd）。
