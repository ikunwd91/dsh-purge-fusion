/**
 * dsh-purge/fusion —— 融合层（host 半侧）
 *
 * 把 dsh-infinite-gen-5 里「纯 Node、无外部引擎、无外部运行时」的车道搬进 dsh-purge：
 *   · APK 静态审计（ZIP/AXML/DEX/签名证书/能力规则/嵌套载荷）
 *   · 函数级语义 bindiff（指令/CFG/常量/调用度加权匹配 + 变更块）
 *   · 逆向方法论技能（原 ig5-* 技能改写为工具无关版本，引用本插件与宿主工具）
 *
 * 明确不搬的东西（见 FUSION.md）：
 *   · Ghidra / x64dbg / Unicorn 引擎车道 —— 依赖 runtimes/ 便携包（git 仓库不含），
 *     搬进来只会在启动时 pending → 宿主退出码 1。
 *   · worker/*.py 与 adapters/* —— 依赖外部 Python / 原生 dll。
 *   · 任何 systemPrompt 注入 —— 本插件的提示词权威性只由 lib/index.js 的装配钩子负责，
 *     fusion 层不注册提示词段落，避免与 purge 的 inject 顺序打架。
 *
 * 冲突隔离约定：
 *   1. 工具名统一 purge_ 前缀，与 ig5_* / redteam_* 无交集。
 *   2. 技能名统一 purge- 前缀，runtime skill rank 250，用户 $DSH_HOME/skills 同名可覆盖。
 *   3. 只 inject tools；skills 走可选 ctx.inject(['skills'])，缺服务时静默降级不 pending。
 *   4. vendor 代码只读不改：所有适配写在 lib/fusion/*.js，升级时整目录替换 vendor/ 即可。
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { analyzeApk } from './vendor/apk_analysis.js';
import { jsonToolOutput } from './vendor/json_output.js';
import { compareSemantics, functionSimilarity } from './vendor/semantic_diff.js';
import { createEngine, engineReady, wrapDefinition, engineHome, ENGINE_CORE } from './engine.js';

export const name = 'dsh-purge-fusion';
export const inject = ['tools'];

const HERE = path.dirname(fileURLToPath(import.meta.url));
const SKILL_DIR = path.join(HERE, 'skills');
const VENDOR_DIR = path.join(HERE, 'vendor');
/** 供体原技能：随供体整树镜像到 vendor/skills（供体 workflow.js 也从这里读）。 */
const DONOR_SKILL_DIR = path.join(VENDOR_DIR, 'skills');

/** 融合来源与移植范围，供 purge_fusion_status 与文档对齐。 */
export const FUSION_SOURCES = Object.freeze({
  base: {
    repo: 'https://github.com/mmparko/dsh-purge',
    package: 'dsh-purge',
    role: '宿主插件：提示词权威性清洗 + 演练台 + 工具面',
  },
  donor: {
    repo: 'https://github.com/Minglink/dsh-infinite-gen-5',
    package: 'dsh-infinite-gen-5',
    version: '1.3.0',
    commit: '8604739aab14e23233c0a2b3783e26a701e9e6bd',
    role: '供体：静态 APK 车道、语义 diff、逆向方法论技能',
  },
  ported: [
    'source/apk_analysis.js -> vendor/apk_analysis.js',
    'source/apk_zip.js -> vendor/apk_zip.js',
    'source/apk_axml.js -> vendor/apk_axml.js',
    'source/apk_manifest.js -> vendor/apk_manifest.js',
    'source/apk_dex.js -> vendor/apk_dex.js',
    'source/apk_der.js -> vendor/apk_der.js',
    'source/apk_rules.js -> vendor/apk_rules.js',
    'source/json_output.js -> vendor/json_output.js',
    'semantic_diff.js -> vendor/semantic_diff.js',
    'skills/ig5-* -> skills/purge-re-*（改写为工具无关方法论）',
  ],
  engine: {
    vendorTree: 'vendor/ = 供体整树镜像（source/ worker/ adapters/ third_party/ scripts/ + 根 js），相对 import 零改动',
    toolSurface: '43 个 ig5_* 工具（core 8 / full 43 可切换），名称保留原名以兼容供体技能与文档',
    runtime: 'runtimes/ 需单独安装（1.06 GB 发行包）；缺失时工具仍注册，execute 返回明确错误，不 pending',
  },
  notPorted: [
    'client.js 工作台 UI（与本插件 client.js 的 slot 注册会重复）',
    'cordis.patch.yml 的 systemPrompt 注入（本插件提示词只由 lib/index.js 装配钩子负责）',
    '供体 index.js 的 apply()（只取 defineIg5Tools 构造函数，不接管宿主生命周期）',
    'webServer 路由 /ig5-diag /ig5-jobs /ig5-data（与 purge 的 /dsh-purge 路由并存但本层不注册）',
  ],
});

/** 本层改写的方法论技能（工具无关，平铺 .md）。 */
const SKILL_FILES = Object.freeze([
  'purge-re-triage',
  'purge-re-deep-dive',
  'purge-re-unpack',
  'purge-re-crypto-protocol',
  'purge-re-patch-sign',
  'purge-re-diff',
  'purge-re-evidence',
  'purge-apk-audit',
]);

/** 供体原技能（目录包，工具名 ig5_* 与引擎工具面一致，原样可用）。 */
const DONOR_SKILL_FILES = Object.freeze([
  'ig5-triage',
  'ig5-deep-dive',
  'ig5-patch-and-sign',
  'ig5-diff',
  'ig5-debug-live',
  'ig5-crypto',
  'ig5-protocol',
  'ig5-reverse-agent',
]);

const APK_SELECTS = Object.freeze([
  'summary', 'overview', 'manifest', 'permissions', 'signatures', 'dex', 'nativeLibraries',
  'nestedPayloads', 'highEntropyAssets', 'capabilities', 'capabilities.rules', 'capabilities.chains',
  'classes', 'strings', 'obfuscation', 'indicators', 'anomalies', 'entries', 'limitsHit', 'notRun', 'all',
]);

const MAX_TEXT = 96 * 1024;
const UUID_RE = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;

const textRender = (_args, value) => [{ type: 'text', text: String(value?.text ?? '') }];
const textOutput = {
  schema: {
    type: 'object',
    additionalProperties: false,
    properties: { text: { type: 'string' } },
  },
  render: textRender,
};

function dshHome() {
  return process.env.DSH_HOME || path.join(os.homedir(), '.dsh');
}

function reportRoot() {
  return path.join(dshHome(), 'dsh-purge', 'fusion', 'reports');
}

function saveReport(kind, payload) {
  const root = reportRoot();
  fs.mkdirSync(root, { recursive: true });
  const id = crypto.randomUUID();
  const file = path.join(root, `${kind}-${id}.json`);
  fs.writeFileSync(file, JSON.stringify(payload), 'utf8');
  return { id, file };
}

function readReport(id) {
  const value = String(id || '').trim();
  if (!UUID_RE.test(value)) throw Object.assign(new Error('result_id 必须是保存报告返回的 UUID'), { code: 'INVALID_RESULT_ID' });
  const root = reportRoot();
  if (!fs.existsSync(root)) throw Object.assign(new Error('还没有任何已保存报告'), { code: 'RESULT_NOT_FOUND' });
  for (const entry of fs.readdirSync(root)) {
    if (!entry.endsWith(`-${value}.json`)) continue;
    const file = path.join(root, entry);
    return { kind: entry.slice(0, entry.indexOf('-')), file, report: JSON.parse(fs.readFileSync(file, 'utf8')) };
  }
  throw Object.assign(new Error(`找不到报告 ${value}`), { code: 'RESULT_NOT_FOUND' });
}

function pick(root, dotted) {
  let node = root;
  for (const key of String(dotted).split('.')) {
    if (node === null || node === undefined) return undefined;
    node = node[key];
  }
  return node;
}

function clip(value, limit = MAX_TEXT) {
  const text = JSON.stringify(value, null, 1) ?? 'null';
  if (text.length <= limit) return text;
  return `${text.slice(0, limit)}\n… 输出已截断（${text.length} 字符，上限 ${limit}）。用 purge_apk_result / 已保存报告读取完整内容。`;
}

function compactApk(report) {
  const severityRank = { high: 0, medium: 1, low: 2 };
  const indicators = [...(report.indicators || [])]
    .sort((a, b) => (severityRank[a.severity] ?? 3) - (severityRank[b.severity] ?? 3))
    .slice(0, 25);
  return {
    summary: report.summary,
    file: report.file,
    overview: report.overview,
    manifest: report.manifest && !report.manifest.error
      ? {
        package: report.manifest.package,
        versionName: report.manifest.versionName,
        versionCode: report.manifest.versionCode,
        sdk: report.manifest.sdk,
        application: report.manifest.application,
        componentCount: report.manifest.components?.length ?? 0,
        exportedComponents: (report.manifest.components || []).filter((c) => c.exported).slice(0, 20)
          .map((c) => ({ kind: c.kind, name: c.name, permission: c.permission ?? null })),
        anomalies: (report.manifest.anomalies || []).slice(0, 12),
      }
      : { error: report.manifest?.error ?? 'unreadable' },
    permissions: {
      count: report.permissions?.length ?? 0,
      dangerous: (report.permissions || []).filter((p) => p.dangerous || p.protection === 'dangerous').slice(0, 30),
      all: (report.permissions || []).slice(0, 60),
    },
    signatures: {
      verified: report.signatures?.verified === true,
      v1: report.signatures?.v1 ?? [],
      block: report.signatures?.block ?? null,
      certificates: (report.signatures?.certificates || []).map((c) => ({ sha256: c.sha256, subject: c.subject, flags: c.flags, sources: c.sources })),
    },
    dex: (report.dex || []).map((d) => (d.error ? { name: d.name, error: d.error } : { name: d.name, version: d.version, classes: d.classes, methods: d.methods, checksumOk: d.checksumOk, signatureOk: d.signatureOk })),
    capabilities: {
      categories: (report.capabilities?.categories || []).slice(0, 20),
      strongRules: (report.capabilities?.rules || []).filter((r) => r.strength === 3).slice(0, 25),
      chains: (report.capabilities?.chains || []).slice(0, 20),
      declaredWithoutCode: (report.capabilities?.declaredWithoutCode || []).slice(0, 20),
      usedWithoutPermission: (report.capabilities?.usedWithoutPermission || []).slice(0, 20),
    },
    indicators,
    indicatorTotals: report.overview?.indicators,
    nestedPayloads: (report.nestedPayloads || []).slice(0, 15),
    highEntropyAssets: (report.highEntropyAssets || []).slice(0, 10),
    obfuscation: report.obfuscation,
    limitsHit: report.limitsHit,
    notRun: report.notRun,
    note: report.note,
  };
}

function normalizeSnapshot(value, field) {
  if (value && typeof value === 'object' && Array.isArray(value.functions)) return value;
  if (typeof value === 'string' && value.trim()) {
    const text = value.trim();
    if (text.startsWith('{')) {
      let inline;
      try {
        inline = JSON.parse(text);
      } catch (error) {
        throw Object.assign(new Error(`${field} 内联 JSON 解析失败: ${error.message}`), { code: 'SNAPSHOT_INVALID' });
      }
      if (!inline || !Array.isArray(inline.functions)) throw Object.assign(new Error(`${field} 缺少 functions 数组`), { code: 'SNAPSHOT_INVALID' });
      return inline;
    }
    if (!fs.existsSync(text)) throw Object.assign(new Error(`${field} 指向的文件不存在: ${text}`), { code: 'SNAPSHOT_MISSING' });
    const raw = fs.readFileSync(text, 'utf8');
    let parsed;
    try {
      parsed = JSON.parse(raw);
    } catch (error) {
      throw Object.assign(new Error(`${field} 不是合法 JSON: ${error.message}`), { code: 'SNAPSHOT_INVALID' });
    }
    if (!parsed || !Array.isArray(parsed.functions)) throw Object.assign(new Error(`${field} 缺少 functions 数组`), { code: 'SNAPSHOT_INVALID' });
    return parsed;
  }
  throw Object.assign(new Error(`${field} 需要快照 JSON 文件路径或内联 JSON 文本`), { code: 'SNAPSHOT_INVALID' });
}

function loadSkills() {
  const skills = [];
  const skipped = [];

  const parse = (id, file, baseDir) => {
    let text;
    try {
      text = fs.readFileSync(file, 'utf8');
    } catch {
      skipped.push({ name: id, reason: 'missing-file', file });
      return null;
    }
    const match = /^---\r?\n([\s\S]*?)\r?\n---\r?\n([\s\S]+)$/.exec(text);
    if (!match) {
      skipped.push({ name: id, reason: 'no-frontmatter', file });
      return null;
    }
    const fields = {};
    for (const line of match[1].split(/\r?\n/)) {
      const field = /^(name|description):\s*(.+)$/.exec(line);
      if (field) fields[field[1]] = field[2].startsWith('"') ? JSON.parse(field[2]) : field[2].trim();
    }
    if (fields.name !== id || !fields.description) {
      skipped.push({ name: id, reason: 'bad-metadata', file });
      return null;
    }
    if (!/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(id)) {
      skipped.push({ name: id, reason: 'bad-name', file });
      return null;
    }
    return {
      name: id,
      description: fields.description,
      source: 'bundled',
      path: file,
      resourceBase: { kind: 'directory', path: baseDir },
      invocation: { modelInvocable: true, userInvocable: true },
      content: match[2].trim(),
    };
  };

  // 1) 本层改写的方法论技能：平铺 skills/<id>.md
  for (const id of SKILL_FILES) {
    const skill = parse(id, path.join(SKILL_DIR, `${id}.md`), SKILL_DIR);
    if (skill) skills.push(skill);
  }
  // 2) 供体原技能：目录包 _donor-skills/<id>/SKILL.md（工具名 ig5_* 直接对应）
  for (const id of DONOR_SKILL_FILES) {
    const dir = path.join(DONOR_SKILL_DIR, id);
    const skill = parse(id, path.join(dir, 'SKILL.md'), dir);
    if (skill) skills.push(skill);
  }
  return { skills, skipped };
}

/**
 * 失败软着陆：融合层任何一步抛错都只降级，绝不让宿主 bundle 挂载失败
 * （bundle 行抛错会让整个插件行 pending，宿主启动即报错）。
 */
export function apply(ctx, config = {}) {
  try {
    install(ctx, config);
  } catch (error) {
    console.error('[dsh-purge-fusion] install failed (degraded, host unaffected):', error?.message ?? error);
  }
}

function install(ctx, config = {}) {
  const verbose = config?.verbose === true;
  const log = (...args) => {
    if (verbose) console.log('[dsh-purge-fusion]', ...args);
  };

  // 挂载时幂等预建报告目录。否则 reportDirExists 在第一次落盘前恒为 false，
  // 看起来像故障（实际只是懒创建）。
  try { fs.mkdirSync(reportRoot(), { recursive: true }); } catch { /* 只读盘等场景忽略 */ }

  const registeredSkills = [];
  const registeredTools = [];
  const failedTools = [];
  let skillState = { available: false, reason: 'not-registered' };

  const registerTool = (definition) => {
    try {
      ctx.tools.register(definition);
      registeredTools.push(definition.name);
    } catch (error) {
      failedTools.push({ name: definition.name, reason: String(error?.message ?? error) });
      log('tool register failed', definition.name, error);
    }
  };

  /* ── 工具：APK 静态审计 ───────────────────────────────────────────── */
  registerTool({
    name: 'purge_apk_audit',
    description:
      '静态审计一个本地 APK（ZIP/AXML/DEX/签名/能力规则/嵌套载荷）：返回包名、SDK、导出组件、权限、签名证书指纹与标记、'
      + '每个 classes*.dex 的类/方法统计、能力调用点（类+方法+目标 API 证据）、嵌套或伪装载荷、高熵资产、混淆比例与命中上限。'
      + '报告全文按 UUID 落盘到 $DSH_HOME/dsh-purge/fusion/reports，可用 purge_apk_result 分节读取。'
      + '不执行样本、不联网、不启动引擎；证书只识别不验证签名，resources.arsc 不解码，native 库需另行分析。'
      + '结论是线索而非判定：普通应用也会用这些 API，按返回的调用点判断。',
    parameters: {
      type: 'object',
      additionalProperties: false,
      required: ['path'],
      properties: {
        path: { type: 'string', description: 'APK 文件绝对路径' },
        save: { type: 'boolean', description: '是否把完整报告落盘，默认 true' },
        limits: {
          type: 'object',
          additionalProperties: true,
          description: '覆盖内置上限（manifestBytes/dexBytes/dexFiles/probeEntries/deadlineMs 等），一般不用传',
        },
      },
    },
    output: textOutput,
    async execute(args = {}) {
      const file = String(args.path || '').trim();
      if (!file) throw Object.assign(new Error('path 必填'), { code: 'INVALID_INPUT' });
      if (!fs.existsSync(file)) throw Object.assign(new Error(`文件不存在: ${file}`), { code: 'NOT_FOUND' });
      const report = analyzeApk({ path: file, ...(args.limits && typeof args.limits === 'object' ? { limits: args.limits } : {}) });
      const safe = jsonToolOutput(report);
      const compact = compactApk(safe);
      let saved = null;
      if (args.save !== false) {
        const record = saveReport('apk', safe);
        saved = { result_id: record.id, file: record.file };
      }
      log('apk', file, safe.file?.sha256, saved?.result_id);
      return { text: clip({ ...(saved ? { result_id: saved.result_id, report_file: saved.file } : {}), ...compact }) };
    },
  });

  /* ── 工具：读取已保存 APK 报告的分节 ─────────────────────────────── */
  registerTool({
    name: 'purge_apk_result',
    description:
      '按 result_id 读取 purge_apk_audit 保存的完整报告；select 选择分节（manifest/signatures/dex/capabilities.rules/'
      + 'indicators/strings/classes/entries/all 等），默认 summary+indicators。用于避免一次性把大报告灌进上下文。',
    parameters: {
      type: 'object',
      additionalProperties: false,
      required: ['result_id'],
      properties: {
        result_id: { type: 'string', description: 'purge_apk_audit 返回的 result_id（UUID）' },
        select: { type: 'string', enum: [...APK_SELECTS], description: '要读取的分节，默认 indicators' },
      },
    },
    output: textOutput,
    async execute(args = {}) {
      const { kind, file, report } = readReport(args.result_id);
      if (kind !== 'apk') throw Object.assign(new Error(`报告 ${args.result_id} 属于 ${kind} 车道，不是 apk`), { code: 'INVALID_REF' });
      const select = String(args.select || 'indicators');
      if (!APK_SELECTS.includes(select)) throw Object.assign(new Error(`select 必须是 ${APK_SELECTS.join('|')}`), { code: 'INVALID_INPUT' });
      if (select === 'all') return { text: clip({ result_id: args.result_id, report_file: file, report }) };
      return { text: clip({ result_id: args.result_id, report_file: file, select, value: pick(report, select) }) };
    },
  });

  /* ── 工具：函数级语义 bindiff ────────────────────────────────────── */
  registerTool({
    name: 'purge_bindiff',
    description:
      '对比两份函数快照（版本 A/版本 B）做语义 bindiff：按指令直方图、CFG 邻域标签、常量集合、字符串集合、调用度与规模加权匹配，'
      + '输出 matched/changed/未匹配统计、变更函数列表（含常量增删与变更基本块）、歧义标记与截断说明。'
      + '快照格式 {"functions":[{ea,name,instructions,mnemonics,topology,constants,strings,call_degree,blocks,semantic_hash?,bytes_hash?,truncated?}]}，'
      + '可直接传对象或 JSON 文件路径。启发式匹配是补丁分析候选，不构成漏洞或语义等价证明。',
    parameters: {
      type: 'object',
      additionalProperties: false,
      properties: {
        left: { type: 'string', description: '版本 A 快照：JSON 文件路径，或直接给 JSON 文本（以 { 开头）' },
        right: { type: 'string', description: '版本 B 快照：JSON 文件路径，或直接给 JSON 文本（以 { 开头）' },
        threshold: { type: 'number', description: '匹配阈值 0..1，默认 0.62' },
        limit: { type: 'number', description: '每类列表返回条数上限 1..1000，默认 50' },
        save: { type: 'boolean', description: '是否把完整结果落盘，默认 true' },
      },
    },
    output: textOutput,
    async execute(args = {}) {
      const left = normalizeSnapshot(args.left, 'left');
      const right = normalizeSnapshot(args.right, 'right');
      const threshold = args.threshold === undefined ? 0.62 : Number(args.threshold);
      const limit = args.limit === undefined ? 50 : Number(args.limit);
      const result = compareSemantics(left, right, { threshold, limit });
      const safe = jsonToolOutput(result);
      let saved = null;
      if (args.save !== false) {
        const record = saveReport('bindiff', safe);
        saved = { result_id: record.id, file: record.file };
      }
      return { text: clip({ ...(saved ? { result_id: saved.result_id, report_file: saved.file } : {}), ...safe }) };
    },
  });

  /* ── 引擎链路：供体 43 个 ig5_* 工具（运行时可选，缺失不崩） ─────── */

  let engine = null;
  let engineFailures = [];
  const activeEngineTools = new Map();
  const schemaDropped = [];

  /**
   * 工具面必须跨 turn 持久化。
   * 宿主每个 turn 会重新 apply 插件，若只从 config 初始化，
   * 用户切到 full 后下一条消息就退回 core，full 里的工具模型根本看不见。
   * 因此把选择写到状态文件，启动时优先读它。
   */
  const toolsetStateFile = path.join(engineHome(), 'engine-toolset.json');
  const readToolsetState = () => {
    try {
      // 用户可能用记事本 / PowerShell 5.1 编辑该文件，二者都会写 UTF-8 BOM，
      // 而 JSON.parse 遇到 BOM 会抛错。这里先剥掉 BOM 再解析，
      // 否则工具面会静默回退到 core，full 里的工具模型看不见。
      const raw = fs.readFileSync(toolsetStateFile, 'utf8').replace(/^\uFEFF/, '').trim();
      if (!raw) return null;
      const parsed = JSON.parse(raw);
      return parsed?.toolset === 'full' ? 'full' : parsed?.toolset === 'core' ? 'core' : null;
    } catch {
      return null;
    }
  };
  const writeToolsetState = (mode) => {
    try {
      fs.mkdirSync(path.dirname(toolsetStateFile), { recursive: true });
      fs.writeFileSync(toolsetStateFile, JSON.stringify({ toolset: mode, at: new Date().toISOString() }, null, 1), 'utf8');
    } catch (error) {
      log('toolset state write failed', error);
    }
  };
  let engineToolset = readToolsetState() ?? (config?.engineToolset === 'full' ? 'full' : 'core');

  try {
    // 始终以 full 装配，拿全 43 个定义；向宿主注册 core/full 子集由本层控制，
    // 这样切换工具面不会重建引擎、不会丢已打开的会话。
    engine = createEngine({ log, config: { toolset: 'full', ...(config?.engine ?? {}) } });
    engineFailures = [...(engine.failures ?? [])];
  } catch (error) {
    engineFailures.push({ label: 'createEngine', reason: String(error?.message ?? error) });
    log('engine init failed (degraded)', error);
  }

  const engineToolNames = () => (engine?.definitions ?? []).map((d) => d.name);
  const applyEngineToolset = (mode) => {
    if (!engine) return { ok: false, reason: 'engine-unavailable' };
    const catalog = new Map(engine.definitions.map((d) => [d.name, d]));
    const wanted = mode === 'full'
      ? [...catalog.keys()]
      : ENGINE_CORE.filter((n) => catalog.has(n));
    const wantedSet = new Set(wanted);
    for (const [toolName, dispose] of [...activeEngineTools]) {
      if (wantedSet.has(toolName)) continue;
      try { dispose(); } catch { /* ignore */ }
      activeEngineTools.delete(toolName);
    }
    for (const toolName of wanted) {
      if (activeEngineTools.has(toolName)) continue;
      try {
        const dispose = ctx.tools.register(wrapDefinition(catalog.get(toolName), engine, schemaDropped));
        activeEngineTools.set(toolName, typeof dispose === 'function' ? dispose : () => {});
      } catch (error) {
        // 与已安装的供体插件同名时会走到这里：记录并跳过，不影响其它工具
        engineFailures.push({ label: 'register', name: toolName, reason: String(error?.message ?? error) });
      }
    }
    engineToolset = mode;
    writeToolsetState(mode);
    return { ok: true, mode, active: [...activeEngineTools.keys()] };
  };

  if (engine) {
    try { applyEngineToolset(engineToolset); } catch (error) {
      engineFailures.push({ label: 'applyToolset', reason: String(error?.message ?? error) });
      log('engine toolset apply failed', error);
    }
  }

  /* ── 工具：切换引擎工具面 ────────────────────────────────────────── */
  registerTool({
    name: 'purge_engine_tools',
    description:
      '查看或切换供体引擎工具面。core（默认）= ig5_doctor/open/status/funcs/strings/decompile/close/profile 共 8 个；'
      + 'full = 全部 43 个（含 patch_bytes/dbg/emulate/microcode/ir/crypto/protocol/capture 等）。'
      + '不传 toolset 只查询当前状态。切换只影响本会话工具可见性，不授予样本执行权限，也不改运行时安装状态。',
    parameters: {
      type: 'object',
      additionalProperties: false,
      properties: {
        toolset: { type: 'string', enum: ['core', 'full'], description: '目标工具面；省略则只查询' },
      },
    },
    output: textOutput,
    async execute(args = {}) {
      if (args.toolset !== undefined) applyEngineToolset(args.toolset);
      return {
        text: clip({
          available: Boolean(engine),
          toolset: engineToolset,
          activeCount: activeEngineTools.size,
          active: [...activeEngineTools.keys()],
          catalogCount: engineToolNames().length,
          catalog: engineToolNames(),
          runtime: engine?.runtime ?? null,
          ready: engineReady(engine),
          failures: engineFailures,
          // 供体 schema 被降级的键，如实暴露，便于排查"某约束是否还在执行"
          schemaDropped: [...new Set(schemaDropped)],
        }),
      };
    },
  });

  /* ── 工具：融合层状态 ────────────────────────────────────────────── */
  registerTool({
    name: 'purge_fusion_status',
    description:
      '返回融合层状态：供体仓库与 commit、已移植模块清单、明确未移植项、已注册工具、已注册技能及其降级原因、报告目录。'
      + '用于确认缝合结果与排查技能未加载。',
    parameters: { type: 'object', additionalProperties: false, properties: {} },
    output: textOutput,
    async execute() {
      const vendor = fs.existsSync(VENDOR_DIR)
        ? fs.readdirSync(VENDOR_DIR).filter((f) => f.endsWith('.js')).sort()
        : [];
      return {
        text: clip({
          plugin: name,
          version: '1.0.0',
          base: FUSION_SOURCES.base,
          donor: FUSION_SOURCES.donor,
          vendorModules: vendor,
          ported: FUSION_SOURCES.ported,
          notPorted: FUSION_SOURCES.notPorted,
          tools: registeredTools,
          failedTools,
          engine: {
            available: Boolean(engine),
            toolset: engineToolset,
            catalogCount: engineToolNames().length,
            activeCount: activeEngineTools.size,
            active: [...activeEngineTools.keys()],
            runtime: engine?.runtime ?? null,
            ready: engineReady(engine),
            failures: engineFailures,
          },
          skills: { state: skillState, registered: registeredSkills, bundled: SKILL_FILES },
          reportDir: reportRoot(),
          reportDirExists: fs.existsSync(reportRoot()),
          conflicts: {
            toolNamespace: 'purge_* 为融合层自有工具；ig5_* 为供体原工具，两族互不重叠',
            skillNamespace: 'purge-*（runtime rank 250，$DSH_HOME/skills 同名可覆盖）',
            promptInjection: 'none（提示词仍只由 lib/index.js 装配钩子负责）',
            clientSlots: 'none（不注册 client bundle，避免与 purge 的 slot 重复）',
          },
        }),
      };
    },
  });

  /* ── 技能：可选挂载，缺 skills 服务时降级不 pending ─────────────── */
  const loaded = loadSkills();
  if (loaded.skipped.length) log('skills skipped', loaded.skipped);
  if (typeof ctx.inject !== 'function') {
    skillState = { available: false, reason: 'ctx.inject-unavailable', skipped: loaded.skipped };
  } else {
    try {
      ctx.inject(['skills'], (scope) => {
        if (typeof scope.get !== 'function') {
          skillState = { available: false, reason: 'skills-scope-unavailable' };
          return;
        }
        const service = scope.get('skills');
        if (!service || typeof service.register !== 'function') {
          skillState = { available: false, reason: 'skills-service-unavailable' };
          return;
        }
        const removes = [];
        try {
          for (const skill of loaded.skills) {
            removes.push(service.register(skill));
            registeredSkills.push(skill.name);
          }
          skillState = { available: true, reason: 'registered', count: registeredSkills.length, skipped: loaded.skipped };
        } catch (error) {
          for (const remove of removes.reverse()) {
            try { remove(); } catch { /* ignore */ }
          }
          registeredSkills.length = 0;
          skillState = { available: false, reason: `register-failed: ${error?.message ?? error}`, skipped: loaded.skipped };
          log('skill register failed', error);
        }
        return () => {
          for (const remove of removes.reverse()) {
            try { remove(); } catch { /* ignore */ }
          }
          registeredSkills.length = 0;
          skillState = { available: false, reason: 'disposed' };
        };
      });
    } catch (error) {
      skillState = { available: false, reason: `inject-failed: ${error?.message ?? error}` };
      log('skills inject failed', error);
    }
  }

  ctx.effect(() => () => {
    registeredTools.length = 0;
    registeredSkills.length = 0;
  });

  log('ready', { tools: registeredTools.length, skills: registeredSkills.length });
}

export default { name, inject, apply };
