/**
 * dsh-purge/fusion 冒烟测试：不需要宿主，直接以假 ctx 加载并实跑工具。
 *
 *   node lib/fusion/smoke.mjs [apkFixturePath]
 *
 * 断言返回值，不只看"没抛异常"。
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const HERE = path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1'));
const failures = [];
const notes = [];

/**
 * 测试必须自封闭：工具面默认值来自 $DSH_HOME 下的状态文件，
 * 若沿用真实 HOME，用户切到 full 后本测试会读到 43 个工具、
 * 让"core 应 13 个"之类的断言假失败。这里在加载 index.js 前
 * 把 DSH_HOME 指向临时目录，engineHome() 随之隔离。
 */
const SANDBOX_HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'fusion-smoke-'));
process.env.DSH_HOME = SANDBOX_HOME;
const cleanup = () => {
  try { fs.rmSync(SANDBOX_HOME, { recursive: true, force: true }); } catch { /* ignore */ }
};
process.on('exit', cleanup);

function check(name, condition, detail = '') {
  if (condition) notes.push(`PASS ${name}`);
  else failures.push(`FAIL ${name}${detail ? ` :: ${detail}` : ''}`);
}

/* ── 假 ctx ─────────────────────────────────────────────────────── */
const tools = new Map();
const skills = new Map();
const ctx = {
  tools: {
    register(definition) {
      if (!definition?.name) throw new Error('tool without name');
      if (tools.has(definition.name)) throw new Error(`duplicate tool ${definition.name}`);
      tools.set(definition.name, definition);
      return () => tools.delete(definition.name);
    },
  },
  inject(deps, callback) {
    const scope = { get: (name) => (name === 'skills' ? { register: (skill) => { skills.set(skill.name, skill); return () => skills.delete(skill.name); } } : undefined) };
    const dispose = callback(scope);
    return dispose;
  },
  effect(factory) {
    const dispose = factory();
    return dispose;
  },
};

const mod = await import(pathToFileURL(path.join(HERE, 'index.js')).href);
check('module exports apply', typeof mod.apply === 'function');
check('module name', mod.name === 'dsh-purge-fusion', String(mod.name));

mod.apply(ctx, { verbose: false });

/* ── 工具注册 ───────────────────────────────────────────────────── */
const expectedTools = ['purge_apk_audit', 'purge_apk_result', 'purge_bindiff', 'purge_engine_tools', 'purge_fusion_status'];
for (const name of expectedTools) check(`tool registered ${name}`, tools.has(name));

/* ── 引擎链路：43 个 ig5_* 工具，core 8 默认 ─────────────────────── */
const ENGINE_CORE = ['ig5_doctor', 'ig5_open', 'ig5_status', 'ig5_funcs', 'ig5_strings', 'ig5_decompile', 'ig5_close', 'ig5_profile'];
for (const name of ENGINE_CORE) check(`engine core tool ${name}`, tools.has(name));
const ig5Active = [...tools.keys()].filter((n) => n.startsWith('ig5_'));
check('engine core count is 8', ig5Active.length === 8, `got ${ig5Active.length}: ${ig5Active.join(',')}`);
check('default total tools 13', tools.size === 13, `got ${tools.size}`);

/* ── 技能注册 ───────────────────────────────────────────────────── */
const expectedSkills = [
  'purge-re-triage', 'purge-re-deep-dive', 'purge-re-unpack', 'purge-re-crypto-protocol',
  'purge-re-patch-sign', 'purge-re-diff', 'purge-re-evidence', 'purge-apk-audit',
  'ig5-triage', 'ig5-deep-dive', 'ig5-patch-and-sign', 'ig5-diff',
  'ig5-debug-live', 'ig5-crypto', 'ig5-protocol', 'ig5-reverse-agent',
];
for (const name of expectedSkills) check(`skill registered ${name}`, skills.has(name));
check('skill count is 16', skills.size === 16, `got ${skills.size}`);
for (const [name, skill] of skills) {
  check(`skill ${name} description`, typeof skill.description === 'string' && skill.description.length > 10);
  check(`skill ${name} content`, typeof skill.content === 'string' && skill.content.length > 200);
  check(`skill ${name} invocation`, skill.invocation?.modelInvocable === true && skill.invocation?.userInvocable === true);
}

/* ── purge_fusion_status ────────────────────────────────────────── */
const status = JSON.parse((await tools.get('purge_fusion_status').execute({})).text);
check('status donor commit', status.donor?.commit?.length === 40, JSON.stringify(status.donor?.commit));
check('status purge tools listed', Array.isArray(status.tools) && status.tools.length === 5, JSON.stringify(status.tools));
check('status skills available', status.skills?.state?.available === true, JSON.stringify(status.skills?.state));
check('status vendor modules >= 9', (status.vendorModules || []).length >= 9, String((status.vendorModules || []).length));
check('status engine catalog 43', status.engine?.catalogCount === 43, String(status.engine?.catalogCount));
check('status engine active 8', status.engine?.activeCount === 8, String(status.engine?.activeCount));
check('status engine home under purge', String(status.engine?.runtime?.home || '').includes('dsh-purge'), String(status.engine?.runtime?.home));
check('status engine notPorted excludes runtimes', !(status.notPorted || []).some((x) => x.startsWith('runtimes/')), JSON.stringify(status.notPorted));

/* ── purge_engine_tools core/full 切换 ──────────────────────────── */
const fullSwitch = JSON.parse((await tools.get('purge_engine_tools').execute({ toolset: 'full' })).text);
check('engine full switch -> 43 active', fullSwitch.activeCount === 43, String(fullSwitch.activeCount));
check('engine full switch registers tools', tools.size === 48, `got ${tools.size}`);
check('engine full includes patch_bytes', tools.has('ig5_patch_bytes'));
check('engine full includes dbg', tools.has('ig5_dbg'));
check('engine full includes emulate', tools.has('ig5_emulate'));
check('engine full includes protocol', tools.has('ig5_protocol'));
const coreSwitch = JSON.parse((await tools.get('purge_engine_tools').execute({ toolset: 'core' })).text);
check('engine core switch -> 8 active', coreSwitch.activeCount === 8, String(coreSwitch.activeCount));
check('engine core switch back to 13 tools', tools.size === 13, `got ${tools.size}`);
check('engine core removed patch_bytes', !tools.has('ig5_patch_bytes'));


/* ── 用宿主的 JSON Schema 子集校验工具 schema ───────────────────── */
const hostCandidates = [
  process.env.DSH_TOOLS_MODULE,
  'D:\\DeepSeek-Harness-0.2.0-\\resources\\app\\dsh\\node_modules\\@deepseek-ai\\dsh-tools\\lib\\index.js',
].filter(Boolean);
let hostTools = null;
let hostToolsForSchema = null;
for (const candidate of hostCandidates) {
  if (!fs.existsSync(candidate)) continue;
  try {
    hostTools = await import(pathToFileURL(candidate).href);
    if (typeof hostTools.assertObjectJsonSchema === 'function') { hostToolsForSchema = hostTools; break; }
    hostTools = null;
  } catch { hostTools = null; }
}
if (hostTools) {
  for (const [name, definition] of tools) {
    let error = null;
    try { hostTools.assertObjectJsonSchema(definition.parameters); } catch (e) { error = e; }
    check(`schema ${name} parameters`, !error, error?.message);
    let outError = null;
    try { hostTools.assertObjectJsonSchema(definition.output.schema); } catch (e) { outError = e; }
    check(`schema ${name} output`, !outError, outError?.message);
  }
/* ── full 43 工具面的 schema 必须全部通过宿主校验 ───────────────── */
{
  const { createEngine, wrapDefinition } = await import(pathToFileURL(path.join(HERE, 'engine.js')).href);
  const fullEngine = createEngine({ log: () => {}, config: { toolset: 'full' } });
  const droppedFull = [];
  let okCount = 0;
  const badList = [];
  for (const definition of fullEngine.definitions) {
    const wrapped = wrapDefinition(definition, fullEngine, droppedFull);
    try {
      if (hostToolsForSchema) hostToolsForSchema.assertObjectJsonSchema(wrapped.parameters);
      okCount++;
    } catch (error) {
      badList.push(`${definition.name}: ${String(error.message).slice(0, 120)}`);
    }
  }
  check('full toolset has 43 definitions', fullEngine.definitions.length === 43, String(fullEngine.definitions.length));
  check('all 43 full schemas pass host validation', badList.length === 0, badList.join(' | '));
  notes.push(`INFO full schema pass=${okCount}/43 dropped=${JSON.stringify([...new Set(droppedFull)])}`);
  await fullEngine.dispose();
}
  notes.push('HOST schema validation: @deepseek-ai/dsh-tools loaded');
} else {
  notes.push('SKIP host schema validation (@deepseek-ai/dsh-tools not resolvable)');
}

/* ── 边界裁剪：删掉 schema 关键字不等于丢约束 ───────────────────── */
{
  const { collectBounds, enforceBounds } = await import(pathToFileURL(path.join(HERE, 'engine.js')).href);
  const schema = { type: 'object', properties: {
    limit: { type: 'number', minimum: 1, maximum: 200 },
    page_max_bytes: { type: 'integer', minimum: 4000, maximum: 64000 },
    ids: { type: 'array', items: { type: 'string' }, minItems: 1, maxItems: 3 },
    name: { type: 'string', minLength: 1, maxLength: 5 },
    nested: { type: 'object', properties: { n: { type: 'number', maximum: 10 } } },
  } };
  const b = collectBounds(schema);
  check('bounds collected', b.size === 5, `got ${b.size}: ${[...b.keys()].join(',')}`);
  check('bounds clamp max', enforceBounds({ limit: 99999 }, b).limit === 200);
  check('bounds clamp min', enforceBounds({ limit: 0 }, b).limit === 1);
  check('bounds clamp page_max_bytes low', enforceBounds({ page_max_bytes: 100 }, b).page_max_bytes === 4000);
  check('bounds clamp page_max_bytes high', enforceBounds({ page_max_bytes: 999999 }, b).page_max_bytes === 64000);
  check('bounds truncate array', JSON.stringify(enforceBounds({ ids: ['a','b','c','d','e'] }, b).ids) === '["a","b","c"]');
  check('bounds truncate string', enforceBounds({ name: 'abcdefgh' }, b).name === 'abcde');
  const legal = { limit: 50, name: 'abc' };
  check('legal args returned as-is', enforceBounds(legal, b) === legal);
  const original = { nested: { n: 99 } };
  const snapshot = JSON.stringify(original);
  enforceBounds(original, b);
  check('caller object not mutated', JSON.stringify(original) === snapshot, JSON.stringify(original));
}
/* ── purge_bindiff ──────────────────────────────────────────────── */
const snapshot = (shift) => ({
  functions: [
    {
      ea: `0x14000${shift}000`, name: 'sub_140001000', instructions: 42,
      mnemonics: { mov: 18, lea: 6, call: 4, cmp: 3, jz: 2 },
      topology: ['B0->B1', 'B1->B2', 'B1->B3'],
      constants: ['0x20', '0x1f', shift === '1' ? '0x2a' : '0x2b'],
      strings: ['license.dat'],
      call_degree: 4,
      semantic_hash: `sem-${shift}`, bytes_hash: `bytes-${shift}`,
      blocks: [
        { hash: 'aaa', start: '0x140001000', end: '0x140001020', insns: 9 },
        { hash: shift === '1' ? 'bbb' : 'zzz', start: '0x140001020', end: '0x140001040', insns: 7 },
      ],
    },
    {
      ea: `0x14000${shift}100`, name: 'sub_140001100', instructions: 12,
      mnemonics: { push: 2, mov: 4, pop: 2, ret: 1 },
      topology: ['B0->B1'], constants: ['0x1'], strings: [], call_degree: 0,
      semantic_hash: 'sem-same', bytes_hash: 'bytes-same',
      blocks: [{ hash: 'ccc', start: '0x140001100', end: '0x140001118', insns: 5 }],
    },
  ],
});

const diff = JSON.parse((await tools.get('purge_bindiff').execute({ left: snapshot('1'), right: snapshot('2'), threshold: 0.5, limit: 10, save: false })).text);
check('bindiff summary present', !!diff.summary, JSON.stringify(diff.summary));
check('bindiff matched 2', diff.summary?.matched === 2, JSON.stringify(diff.summary));
check('bindiff detected 1 changed', diff.summary?.changed === 1, JSON.stringify(diff.summary));
check('bindiff changes carry blocks', Array.isArray(diff.changes?.[0]?.changedBlocks?.new), JSON.stringify(diff.changes?.[0]?.changedBlocks));
check('bindiff note present', typeof diff.note === 'string' && diff.note.length > 20);

/* ── purge_bindiff 拒绝非法输入 ─────────────────────────────────── */
let rejected = null;
try {
  await tools.get('purge_bindiff').execute({ left: 'C:\\nope\\missing.json', right: snapshot('2') });
} catch (error) {
  rejected = error;
}
check('bindiff rejects missing file', rejected?.code === 'SNAPSHOT_MISSING', String(rejected?.code));

/* ── purge_apk_audit ───────────────────────────────────────────── */
let apkError = null;
try {
  await tools.get('purge_apk_audit').execute({ path: 'C:\\nope\\missing.apk' });
} catch (error) {
  apkError = error;
}
check('apk rejects missing file', apkError?.code === 'NOT_FOUND', String(apkError?.code));

const fixture = process.argv[2];
if (fixture && fs.existsSync(fixture)) {
  const report = JSON.parse((await tools.get('purge_apk_audit').execute({ path: fixture })).text);
  check('apk returns result_id', typeof report.result_id === 'string' && report.result_id.length === 36, String(report.result_id));
  check('apk returns sha256', /^[a-f0-9]{64}$/.test(report.file?.sha256 || ''), String(report.file?.sha256));
  check('apk degrades manifest', !!report.manifest?.error, JSON.stringify(report.manifest));
  check('apk reports manifest.unreadable', (report.indicators || []).some((i) => i.id === 'manifest.unreadable'), JSON.stringify(report.indicators?.map?.((i) => i.id)));
  const section = JSON.parse((await tools.get('purge_apk_result').execute({ result_id: report.result_id, select: 'indicators' })).text);
  check('apk_result select indicators', Array.isArray(section.value), JSON.stringify(section.value)?.slice(0, 120));
  const all = JSON.parse((await tools.get('purge_apk_result').execute({ result_id: report.result_id, select: 'all' })).text);
  check('apk_result select all', all.report?.file?.sha256 === report.file?.sha256);
  let badSelect = null;
  try { await tools.get('purge_apk_result').execute({ result_id: report.result_id, select: 'nope' }); } catch (error) { badSelect = error; }
  check('apk_result rejects bad select', badSelect?.code === 'INVALID_INPUT', String(badSelect?.code));
  let badId = null;
  try { await tools.get('purge_apk_result').execute({ result_id: '../../etc/passwd' }); } catch (error) { badId = error; }
  check('apk_result rejects path traversal id', badId?.code === 'INVALID_RESULT_ID', String(badId?.code));
} else {
  notes.push('SKIP apk fixture run (no fixture path given)');
}

/* ── 失败软着陆：工具注册抛错也不能让宿主 bundle 挂载失败 ───────── */
let softThrew = null;
const originalError = console.error;
console.error = () => {};
try {
  mod.apply({
    tools: { register() { throw new Error('simulated registry failure'); } },
    inject(_deps, callback) { return callback({ get: () => ({ register: () => () => {} }) }); },
    effect(factory) { return factory(); },
  }, {});
} catch (error) {
  softThrew = error;
} finally {
  console.error = originalError;
}
check('apply is fail-soft when tool registry throws', softThrew === null, String(softThrew?.message));

/* ── 结果 ───────────────────────────────────────────────────────── */
for (const line of notes) console.log(line);
for (const line of failures) console.error(line);
console.log(`\n${failures.length ? 'FAILED' : 'OK'} — ${notes.filter((n) => n.startsWith('PASS')).length} passed, ${failures.length} failed, ${notes.filter((n) => n.startsWith('SKIP')).length} skipped`);
process.exit(failures.length ? 1 : 0);
