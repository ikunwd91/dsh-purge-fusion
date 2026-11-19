/**
 * fusion 层完整自检：一条命令跑完所有不依赖人工的检查项。
 *
 *   node lib/fusion/selfcheck.mjs [apk-fixture] [sample.exe]
 *
 * 分六组：
 *   A 结构      —— 目录/文件/配置接线
 *   B 加载      —— 模块可加载、apply 不抛
 *   C 工具面    —— 数量、命名空间、schema 合规
 *   D 技能      —— 16 个技能元数据
 *   E 行为      —— 离线车道实跑、边界裁剪、持久化、fail-soft
 *   F 引擎      —— 运行时探测（有样本则跑端到端）
 *
 * 断言返回值，不只看"没抛异常"。退出码非 0 表示有失败项。
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const VENDOR = path.join(HERE, 'vendor');

/**
 * 自检自封闭：工具面默认值来自 $DSH_HOME 下的状态文件。
 * 若沿用真实 HOME，用户切到 full 后本检查会读到 43 个工具，
 * 让"core 应 13 个"之类的断言假失败。加载 index.js 前隔离 HOME。
 * 运行时探测仍走 vendor/runtimes（不依赖 HOME），不受影响。
 */
const SANDBOX_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'fusion-selfcheck-'));
process.env.DSH_HOME = SANDBOX_HOME;
const HOME = SANDBOX_HOME;
process.on('exit', () => {
  try { fs.rmSync(SANDBOX_HOME, { recursive: true, force: true }); } catch { /* ignore */ }
});

const pass = [];
const fail = [];
const skip = [];
const info = [];
const check = (name, ok, detail = '') => {
  if (ok) pass.push(name);
  else fail.push(`${name}${detail ? ` :: ${detail}` : ''}`);
};
const section = (title) => info.push(`\n── ${title} ──`);

/* ══ A 结构 ══════════════════════════════════════════════════════ */
section('A 结构');
for (const rel of ['index.js', 'engine.js', 'smoke.mjs', 'verify-engine.mjs', 'FUSION.md', 'vendor', 'skills']) {
  check(`存在 ${rel}`, fs.existsSync(path.join(HERE, rel)));
}
const donorTrees = ['source', 'worker', 'adapters', 'third_party', 'scripts', 'skills'];
for (const tree of donorTrees) {
  check(`供体树 vendor/${tree}`, fs.existsSync(path.join(VENDOR, tree)));
}
const countFiles = (dir) => {
  if (!fs.existsSync(dir)) return 0;
  let n = 0;
  const walk = (d) => {
    for (const entry of fs.readdirSync(d, { withFileTypes: true })) {
      const full = path.join(d, entry.name);
      if (entry.isDirectory()) walk(full);
      else n++;
    }
  };
  walk(dir);
  return n;
};
info.push(`  供体树文件数: source=${countFiles(path.join(VENDOR, 'source'))} worker=${countFiles(path.join(VENDOR, 'worker'))} adapters=${countFiles(path.join(VENDOR, 'adapters'))}`);

// ── 插件内结构：fusion 在 dsh-purge 的 lib/ 里，由插件 cordis.patch.yml 挂载 ──
const PKG_ROOT = path.resolve(HERE, '..', '..');
info.push(`  插件根: ${PKG_ROOT}`);

const pkg = JSON.parse(fs.readFileSync(path.join(PKG_ROOT, 'package.json'), 'utf8'));
check('插件包名 dsh-purge', pkg.name === 'dsh-purge', String(pkg.name));
check("插件 exports['./fusion'] 指向本层", pkg.exports?.['./fusion'] === './lib/fusion/index.js', String(pkg.exports?.['./fusion']));
check('插件 main 未改', pkg.main === 'lib/index.js', String(pkg.main));

const yml = fs.readFileSync(path.join(PKG_ROOT, 'cordis.patch.yml'), 'utf8');
check('插件 cordis.patch.yml 含 dsh-purge-fusion 行', /id:\s*dsh-purge-fusion/.test(yml));
check('插件 cordis.patch.yml 含 name: dsh-purge/fusion', /name:\s*dsh-purge\/fusion/.test(yml));
check('插件 cordis.patch.yml 未删原有 redteam 行', /id:\s*dsh-purge-redteam/.test(yml) && /id:\s*dsh-purge-redteam-ui/.test(yml));
check('插件 cordis.patch.yml 未删 system-prompt 行', /id:\s*system-prompt/.test(yml));

// profile 用户层不应再挂一份（否则重复注册）
// 从 DSH_HOME 环境变量定位 profiles（自检已把它指向沙箱，故改用真实 DSH 根）
const DSH_ROOT = process.env.DSH_HOME_REAL
  || path.join(process.env.USERPROFILE || os.homedir(), '.dsh');
const PROFILES_DIR = path.join(DSH_ROOT, 'profiles');
if (fs.existsSync(PROFILES_DIR)) {
  for (const entry of fs.readdirSync(PROFILES_DIR, { withFileTypes: true })) {
    if (!entry.isDirectory()) continue;
    const profDir = path.join(PROFILES_DIR, entry.name);
    const patchPath = path.join(profDir, 'cordis.patch.yml');
    if (!fs.existsSync(patchPath)) continue;
    check(`profile ${entry.name} 无重复 fusion 挂载`, !/id:\s*dsh-purge-fusion/.test(fs.readFileSync(patchPath, 'utf8')), patchPath);
    const linkPath = path.join(profDir, 'node_modules', 'dsh-purge-fusion');
    check(`profile ${entry.name} 无外部 fusion 链接`, !fs.existsSync(linkPath), linkPath);
  }
} else {
  skip.push('未定位到 profiles 目录，跳过重复挂载检查');
}

// 供体原始文件未被误改（除已知 2 处补丁）
const donorIndex = path.join(VENDOR, 'donor-index.js');
const donorIndexText = fs.readFileSync(donorIndex, 'utf8');
check('donor-index.js 仅追加 export', /export \{ defineIg5Tools, resolveConfig \};?\s*$/.test(donorIndexText.trimEnd()));
const ghidraWorker = path.join(VENDOR, 'adapters', 'ghidra', 'worker.py');
const workerText = fs.readFileSync(ghidraWorker, 'utf8');
check('worker.py 含 fusion patch 标记', workerText.includes('[fusion patch] cpu_emulator'));
check('worker.py 语法结构完整（def m_emulate 存在）', /def m_emulate\(self, params\):/.test(workerText));

/* ══ B 加载 ══════════════════════════════════════════════════════ */
section('B 加载');
const mod = await import(pathToFileURL(path.join(HERE, 'index.js')).href);
check('index.js 导出 name', mod.name === 'dsh-purge-fusion', String(mod.name));
check('index.js 导出 apply', typeof mod.apply === 'function');
const engineMod = await import(pathToFileURL(path.join(HERE, 'engine.js')).href);
for (const fn of ['createEngine', 'engineReady', 'wrapDefinition', 'sanitizeSchema', 'collectBounds', 'enforceBounds', 'engineHome', 'ENGINE_CORE']) {
  check(`engine.js 导出 ${fn}`, engineMod[fn] !== undefined);
}
check('ENGINE_CORE 恰好 8 个', engineMod.ENGINE_CORE.length === 8, String(engineMod.ENGINE_CORE.length));

// 宿主校验器（用于 schema 合规）
let hostTools = null;
const hostCandidates = [
  process.env.DSH_TOOLS_MODULE,
  'D:\\DeepSeek-Harness-0.2.0-\\resources\\app\\dsh\\node_modules\\@deepseek-ai\\dsh-tools\\lib\\index.js',
].filter(Boolean);
for (const candidate of hostCandidates) {
  if (!fs.existsSync(candidate)) continue;
  try {
    const m = await import(pathToFileURL(candidate).href);
    if (typeof m.assertObjectJsonSchema === 'function') { hostTools = m; break; }
  } catch { /* next */ }
}
if (hostTools) info.push('  宿主 schema 校验器: 已加载');
else skip.push('宿主 schema 校验器未找到，C 组 schema 检查跳过');

/* ══ C 工具面 ════════════════════════════════════════════════════ */
section('C 工具面');
const stateFile = path.join(HOME, 'dsh-purge', 'fusion', 'ig5', 'engine-toolset.json');
const savedState = fs.existsSync(stateFile) ? fs.readFileSync(stateFile, 'utf8') : null;

const buildCtx = () => {
  const tools = new Map();
  return {
    tools: { register(d) { if (tools.has(d.name)) throw new Error(`dup ${d.name}`); tools.set(d.name, d); return () => tools.delete(d.name); } },
    inject(_d, cb) { return cb({ get: () => ({ register: () => () => {} }) }); },
    effect(f) { return f(); },
    _tools: tools,
  };
};

// core 默认
try { fs.unlinkSync(stateFile); } catch { /* ignore */ }
const coreCtx = buildCtx();
mod.apply(coreCtx, {});
const purgeTools = [...coreCtx._tools.keys()].filter((n) => n.startsWith('purge_'));
const ig5Core = [...coreCtx._tools.keys()].filter((n) => n.startsWith('ig5_'));
check('purge_* 工具 5 个', purgeTools.length === 5, purgeTools.join(','));
for (const n of ['purge_apk_audit', 'purge_apk_result', 'purge_bindiff', 'purge_engine_tools', 'purge_fusion_status']) {
  check(`工具 ${n}`, coreCtx._tools.has(n));
}
check('core 面 ig5 工具 8 个', ig5Core.length === 8, ig5Core.join(','));
for (const n of engineMod.ENGINE_CORE) check(`core 含 ${n}`, coreCtx._tools.has(n));
check('core 面不含 ig5_capture', !coreCtx._tools.has('ig5_capture'));
check('工具总数 13', coreCtx._tools.size === 13, String(coreCtx._tools.size));
check('命名空间无冲突（无重复注册抛错）', true);

// schema 合规：core 面
if (hostTools) {
  let bad = [];
  for (const [name, def] of coreCtx._tools) {
    try { hostTools.assertObjectJsonSchema(def.parameters); } catch (e) { bad.push(`${name}: ${e.message.slice(0, 80)}`); }
    if (def.output?.schema) { try { hostTools.assertObjectJsonSchema(def.output.schema); } catch (e) { bad.push(`${name}.output: ${e.message.slice(0, 80)}`); } }
  }
  check('core 面 schema 全部合规', bad.length === 0, bad.join(' | '));
}

// full 面
const fullCtx = buildCtx();
const sw = await coreCtx._tools.get('purge_engine_tools').execute({ toolset: 'full' });
const swJson = JSON.parse(sw.text);
check('切 full → activeCount 43', swJson.activeCount === 43, String(swJson.activeCount));
check('切 full → failures 为空', (swJson.failures || []).length === 0, JSON.stringify(swJson.failures));
check('切 full 后宿主工具数 48', coreCtx._tools.size === 48, String(coreCtx._tools.size));
for (const n of ['ig5_patch_bytes', 'ig5_dbg', 'ig5_emulate', 'ig5_workspace', 'ig5_recovery', 'ig5_capture', 'ig5_capture_control', 'ig5_protocol', 'ig5_crypto', 'ig5_ir', 'ig5_sync']) {
  check(`full 含 ${n}`, coreCtx._tools.has(n));
}
if (hostTools) {
  let bad = [];
  for (const [name, def] of coreCtx._tools) {
    try { hostTools.assertObjectJsonSchema(def.parameters); } catch (e) { bad.push(`${name}: ${e.message.slice(0, 80)}`); }
  }
  check('full 面 43 个 schema 全部合规', bad.length === 0, bad.join(' | '));
}
info.push(`  schema 降级关键字: ${JSON.stringify([...new Set(swJson.schemaDropped || [])])}`);

// 切回 core
const swBack = await coreCtx._tools.get('purge_engine_tools').execute({ toolset: 'core' });
check('切回 core → activeCount 8', JSON.parse(swBack.text).activeCount === 8);
check('切回 core → 工具总数 13', coreCtx._tools.size === 13, String(coreCtx._tools.size));
check('切回 core → ig5_capture 已移除', !coreCtx._tools.has('ig5_capture'));

/* ══ D 技能 ══════════════════════════════════════════════════════ */
section('D 技能');
const skillCtx = buildCtx();
const registeredSkills = new Map();
skillCtx.inject = (_d, cb) => cb({ get: () => ({ register: (s) => { registeredSkills.set(s.name, s); return () => registeredSkills.delete(s.name); } }) });
mod.apply(skillCtx, {});
check('技能总数 16', registeredSkills.size === 16, String(registeredSkills.size));
const methodology = ['purge-re-triage', 'purge-re-deep-dive', 'purge-re-unpack', 'purge-re-crypto-protocol', 'purge-re-patch-sign', 'purge-re-diff', 'purge-re-evidence', 'purge-apk-audit'];
const donorSkills = ['ig5-triage', 'ig5-deep-dive', 'ig5-patch-and-sign', 'ig5-diff', 'ig5-debug-live', 'ig5-crypto', 'ig5-protocol', 'ig5-reverse-agent'];
for (const n of [...methodology, ...donorSkills]) check(`技能 ${n}`, registeredSkills.has(n));
for (const [n, s] of registeredSkills) {
  check(`技能 ${n} 元数据`, typeof s.description === 'string' && s.description.length > 10 && typeof s.content === 'string' && s.content.length > 200);
  check(`技能 ${n} 调用策略`, s.invocation?.modelInvocable === true && s.invocation?.userInvocable === true);
}

/* ══ E 行为 ══════════════════════════════════════════════════════ */
section('E 行为');
const status = JSON.parse((await skillCtx._tools.get('purge_fusion_status').execute({})).text);
check('status donor commit 40 位', status.donor?.commit?.length === 40);
check('status engine catalog 43', status.engine?.catalogCount === 43, String(status.engine?.catalogCount));
check('status engine home 在 purge 下', String(status.engine?.runtime?.home || '').includes('dsh-purge'));
check('status conflicts 四项齐全', Object.keys(status.conflicts || {}).length === 4);
check('status notPorted 不含 runtimes', !(status.notPorted || []).some((x) => x.startsWith('runtimes/')));

// 边界裁剪
const { collectBounds, enforceBounds } = engineMod;
const bs = collectBounds({ type: 'object', properties: {
  a: { type: 'number', minimum: 1, maximum: 200 },
  b: { type: 'integer', minimum: 4000, maximum: 64000 },
  c: { type: 'array', minItems: 1, maxItems: 3 },
  d: { type: 'string', minLength: 1, maxLength: 5 },
} });
check('边界收集 4 项', bs.size === 4, String(bs.size));
check('边界 max 裁剪', enforceBounds({ a: 99999 }, bs).a === 200);
check('边界 min 裁剪', enforceBounds({ a: 0 }, bs).a === 1);
check('边界 low 裁剪', enforceBounds({ b: 100 }, bs).b === 4000);
check('边界 high 裁剪', enforceBounds({ b: 999999 }, bs).b === 64000);
check('数组截断', enforceBounds({ c: ['1','2','3','4','5'] }, bs).c.length === 3);
check('字符串截断', enforceBounds({ d: 'abcdefgh' }, bs).d === 'abcde');
const legalArgs = { a: 50 };
check('合法入参原样返回', enforceBounds(legalArgs, bs) === legalArgs);
const callerObj = { nested: { n: 99 } };
const before = JSON.stringify(callerObj);
enforceBounds(callerObj, collectBounds({ type: 'object', properties: { nested: { type: 'object', properties: { n: { type: 'number', maximum: 10 } } } } }));
check('不污染调用方对象', JSON.stringify(callerObj) === before, JSON.stringify(callerObj));

// 持久化（含 BOM 容错）—— 沙箱 HOME 下总是执行
{
  fs.mkdirSync(path.dirname(stateFile), { recursive: true });
  fs.writeFileSync(stateFile, '\uFEFF' + JSON.stringify({ toolset: 'full' }), 'utf8');
  const bomCtx = buildCtx();
  mod.apply(bomCtx, {});
  check('状态文件带 BOM 仍读到 full', [...bomCtx._tools.keys()].filter((n) => n.startsWith('ig5_')).length === 43);
  fs.writeFileSync(stateFile, '', 'utf8');
  const emptyCtx = buildCtx();
  mod.apply(emptyCtx, {});
  check('状态文件为空回退 core', [...emptyCtx._tools.keys()].filter((n) => n.startsWith('ig5_')).length === 8);
  fs.writeFileSync(stateFile, '{ broken', 'utf8');
  const badCtx = buildCtx();
  mod.apply(badCtx, {});
  check('状态文件损坏回退 core', [...badCtx._tools.keys()].filter((n) => n.startsWith('ig5_')).length === 8);
}

// fail-soft
const origError = console.error;
console.error = () => {};
let softThrew = null;
try {
  mod.apply({ tools: { register() { throw new Error('simulated'); } }, inject(_d, cb) { return cb({ get: () => ({ register: () => () => {} }) }); }, effect: (f) => f() }, {});
} catch (e) { softThrew = e; } finally { console.error = origError; }
check('注册器抛错时 apply 不抛（fail-soft）', softThrew === null, String(softThrew?.message));

// APK 离线车道
const apkFixture = process.argv[2];
if (apkFixture && fs.existsSync(apkFixture)) {
  const r = JSON.parse((await skillCtx._tools.get('purge_apk_audit').execute({ path: apkFixture })).text);
  check('APK 审计返回 result_id', typeof r.result_id === 'string' && r.result_id.length === 36);
  check('APK 审计返回 sha256', /^[a-f0-9]{64}$/.test(r.file?.sha256 || ''), String(r.file?.sha256));
  const sec = JSON.parse((await skillCtx._tools.get('purge_apk_result').execute({ result_id: r.result_id, select: 'indicators' })).text);
  check('APK 分节读取', Array.isArray(sec.value));
  let badId = null;
  try { await skillCtx._tools.get('purge_apk_result').execute({ result_id: '../../etc/passwd' }); } catch (e) { badId = e; }
  check('拒绝路径穿越 result_id', badId?.code === 'INVALID_RESULT_ID');
} else {
  skip.push('未提供 APK fixture，APK 车道实跑跳过');
}

// bindiff
const snap = (tag) => JSON.stringify({ functions: [{ ea: '0x1000', name: 'f1', instructions: 20, mnemonics: { mov: 8 }, topology: ['B0->B1'], constants: ['0x1'], strings: [], call_degree: 2, blocks: [{ hash: 'h1', start: '0x1000', end: '0x1014', insns: 6 }], semantic_hash: tag, bytes_hash: tag }] });
const diff = JSON.parse((await skillCtx._tools.get('purge_bindiff').execute({ left: snap('A'), right: snap('B'), save: false })).text);
check('bindiff 匹配 1 个', diff.summary?.matched === 1, JSON.stringify(diff.summary));
check('bindiff 判定为变更', diff.summary?.changed === 1, JSON.stringify(diff.summary));

/* ══ F 引擎 ══════════════════════════════════════════════════════ */
section('F 引擎');
const engine = engineMod.createEngine({ log: () => {} , config: { toolset: 'full' } });
check('引擎装配 applied', engine.applied === true);
check('引擎目录 43 个定义', engine.definitions.length === 43, String(engine.definitions.length));
check('引擎装配无失败', (engine.failures || []).length === 0, JSON.stringify(engine.failures));

// 运行时是可选的：fresh clone 不含 runtimes/（1.29 GB，走 Release）。
// 缺失时降级为 SKIP，而不是 FAIL —— 否则每个新 clone 的自检都红一片，
// 掩盖真正需要关注的代码问题。
const runtimeRoot = engine.runtime.runtimeRoot || '';
const ghidraReady = engine.runtime.ghidra.available === true;
const x64dbgReady = engine.runtime.x64dbg.available === true;
const runtimeInstalled = ghidraReady || x64dbgReady;

check('运行时根在 vendor/runtimes', runtimeRoot.endsWith(path.join('vendor', 'runtimes')), runtimeRoot);

if (runtimeInstalled) {
  check('Ghidra 运行时可用', ghidraReady, String(engine.runtime.ghidra.reason));
  check('x64dbg 运行时可用', x64dbgReady, String(engine.runtime.x64dbg.reason));
  check('engineReady', engineMod.engineReady(engine) === true);
  check('ghidra/runtime.json 存在', fs.existsSync(path.join(runtimeRoot, 'ghidra', 'runtime.json')));
  check('x64dbg/runtime.json 存在', fs.existsSync(path.join(runtimeRoot, 'x64dbg', 'runtime.json')));
  const gpy = path.join(runtimeRoot, 'ghidra', 'python', 'python.exe');
  check('内置 python.exe 存在', fs.existsSync(gpy), gpy);
} else {
  // 未装运行时：引擎工具仍注册、静态/离线车道仍可用，属于受支持的降级状态
  check('未装运行时仍注册 43 个工具', engine.definitions.length === 43, String(engine.definitions.length));
  check('未装运行时 engineReady 为 false', engineMod.engineReady(engine) === false);
  skip.push('引擎运行时未安装（正常：fresh clone 不含 runtimes/，跑 setup/install-runtime.ps1 补装）');
}

const sample = process.argv[3];
if (sample && fs.existsSync(sample)) {
  const catalog = new Map(engine.definitions.map((d) => [d.name, d]));
  const call = async (n, a) => engineMod.wrapDefinition(catalog.get(n), engine).execute(a, {});
  try {
    const opened = await call('ig5_open', { path: sample, engine: 'ghidra', analysis_timeout: 120, background: false });
    check('引擎 open 成功', Number(opened?.n_funcs ?? 0) > 0, JSON.stringify(opened).slice(0, 120));
    check('引擎 open 返回位数', opened?.bits === 32 || opened?.bits === 64, String(opened?.bits));
    const funcs = await call('ig5_funcs', { target: sample, limit: 3 });
    check('引擎 funcs 返回列表', Array.isArray(funcs?.funcs) && funcs.funcs.length > 0, JSON.stringify(funcs).slice(0, 120));
    const ea = funcs.funcs[0]?.ea;
    if (ea) {
      const dec = await call('ig5_decompile', { target: sample, ea });
      check('引擎 decompile 返回代码', typeof (dec?.code ?? dec?.text ?? '') === 'string' && String(dec.code ?? dec.text).length > 20);
    }
    await call('ig5_close', { target: sample });
    check('引擎 close 成功', true);
  } catch (error) {
    check('引擎端到端', false, String(error?.message).slice(0, 200));
  }
} else {
  skip.push('未提供样本，引擎端到端跳过（仅做运行时探测）');
}
await engine.dispose();

// 恢复状态文件
try {
  if (savedState !== null) fs.writeFileSync(stateFile, savedState, 'utf8');
  else if (fs.existsSync(stateFile)) fs.unlinkSync(stateFile);
} catch { /* ignore */ }

/* ══ 输出 ════════════════════════════════════════════════════════ */
for (const line of info) console.log(line);
for (const line of pass) console.log(`PASS ${line}`);
for (const line of skip) console.log(`SKIP ${line}`);
for (const line of fail) console.error(`FAIL ${line}`);
console.log(`\n${fail.length ? 'FAILED' : 'OK'} — ${pass.length} passed, ${fail.length} failed, ${skip.length} skipped`);
process.exit(fail.length ? 1 : 0);
