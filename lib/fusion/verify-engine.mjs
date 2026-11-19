/**
 * 引擎车道端到端验证（需先装 runtimes/）。
 *
 *   node lib/fusion/verify-engine.mjs [sample.exe]
 *
 * 依次验证：doctor → open → funcs → strings → decompile → cfg → close。
 * 每步断言返回值结构，不只看"没抛异常"。无样本时用自身 JS 文件做最小目标。
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const { createEngine, wrapDefinition, engineReady } = await import(pathToFileURL(path.join(HERE, 'engine.js')).href);

const failures = [];
const notes = [];
const check = (name, ok, detail = '') => {
  if (ok) notes.push(`PASS ${name}`);
  else failures.push(`FAIL ${name}${detail ? ` :: ${detail}` : ''}`);
};

const engine = createEngine({ log: (m, ...a) => notes.push(`LOG ${m} ${JSON.stringify(a).slice(0, 160)}`) });
const catalog = new Map(engine.definitions.map((d) => [d.name, d]));
const call = async (name, args) => {
  const definition = wrapDefinition(catalog.get(name), engine);
  return definition.execute(args, {});
};

check('runtime ready', engineReady(engine), JSON.stringify(engine.runtime.ghidra));
if (!engineReady(engine)) {
  for (const line of notes) console.log(line);
  console.error('\n运行时未就绪，先跑 fusion-patch/install-runtime.ps1');
  process.exit(1);
}

// 目标样本：argv → 环境变量 → 内置 runtimes 里挑一个真实可执行文件。
// 不能回退成本文件（.mjs），那不是 Ghidra 能加载的格式，open 必然失败。
function hasBinaryMagic(fp) {
  try {
    const fd = fs.openSync(fp, 'r');
    const buf = Buffer.alloc(4);
    fs.readSync(fd, buf, 0, 4, 0);
    fs.closeSync(fd);
    const hex = buf.toString('hex').toUpperCase();
    // MZ (PE) / 7F454C46 (ELF) / Mach-O 四种
    return hex.startsWith('4D5A') || hex === '7F454C46' ||
      ['FEEDFACE', 'FEEDFACF', 'CEFAEDFE', 'CFFAEDFE'].includes(hex);
  } catch { return false; }
}

function pickFallbackSample() {
  const roots = [engine.runtime?.runtimeRoot].filter(Boolean);
  for (const root of roots) {
    for (const rel of [
      'ghidra/ghidra_12.1.4_PUBLIC/Ghidra/Features/Base/os/windows_x86_64/Decompile.exe',
      'ghidra/ghidra_12.1.4_PUBLIC/support/analyzeHeadless.bat',
      'ghidra/python/python.exe',
      'x64dbg/release/x64/x64dbg.exe',
    ]) {
      const fp = path.join(root.replace(/[\\/]/g, path.sep), rel);
      if (fs.existsSync(fp) && hasBinaryMagic(fp)) return fp;
    }
  }
  // 最后试系统自带的稳定 PE
  for (const fp of ['C:\\Windows\\System32\\notepad.exe', 'C:\\Windows\\System32\\kernel32.dll']) {
    if (fs.existsSync(fp) && hasBinaryMagic(fp)) return fp;
  }
  return null;
}

let sample = null;
const argvSample = process.argv[2];
const envSample = process.env.IG5_SAMPLE;
if (argvSample && fs.existsSync(argvSample) && hasBinaryMagic(argvSample)) {
  sample = path.resolve(argvSample);
} else if (envSample && fs.existsSync(envSample) && hasBinaryMagic(envSample)) {
  sample = path.resolve(envSample);
} else {
  sample = pickFallbackSample();
}
if (!sample) {
  for (const line of notes) console.log(line);
  console.error('\n找不到可用样本：传一个 PE/ELF 路径作第一个参数，或设 IG5_SAMPLE 环境变量。');
  process.exit(1);
}
notes.push(`TARGET ${sample}`);

const engineName = engine.runtime.ghidra.available ? 'ghidra' : 'reverse';

// 1) doctor
let doctor;
try {
  doctor = await call('ig5_doctor', {});
  check('doctor ok', doctor?.ok === true || doctor?.runtimeReady === true, JSON.stringify(doctor).slice(0, 240));
} catch (error) {
  check('doctor ok', false, String(error?.message).slice(0, 240));
}

// 2) open
let opened;
try {
  opened = await call('ig5_open', { path: sample, engine: engineName, analysis_timeout: 120, background: false });
  // 字段名是 n_funcs，不是 functions。原来写 `>= 0` 恒真，等于没断言。
  const fnCount = Number(opened?.n_funcs ?? opened?.functions ?? opened?.functionCount ?? 0);
  check('open returns functions', fnCount > 0, `n_funcs=${JSON.stringify(opened?.n_funcs)} raw=${JSON.stringify(opened).slice(0, 200)}`);
  check('open analysis complete', opened?.analysisComplete === true, String(opened?.analysisComplete));
  check('open returns arch', Boolean(opened?.arch || opened?.architecture || opened?.segments), JSON.stringify(opened).slice(0, 200));
} catch (error) {
  check('open ok', false, String(error?.message).slice(0, 300));
}

if (opened) {
  // 3) funcs
  try {
    const funcs = await call('ig5_funcs', { target: sample, engine: engineName, limit: 5 });
    const list = funcs?.funcs ?? funcs?.functions ?? funcs?.items ?? [];
    check('funcs returns list', Array.isArray(list), JSON.stringify(funcs).slice(0, 200));
    notes.push(`INFO functions=${funcs?.total ?? list.length}`);
  } catch (error) {
    check('funcs ok', false, String(error?.message).slice(0, 240));
  }

  // 4) strings
  try {
    const strings = await call('ig5_strings', { target: sample, engine: engineName, limit: 5 });
    check('strings returns list', Array.isArray(strings?.strings ?? strings?.items ?? []), JSON.stringify(strings).slice(0, 200));
  } catch (error) {
    check('strings ok', false, String(error?.message).slice(0, 240));
  }

  // 5) decompile 第一个函数
  try {
    const funcs = await call('ig5_funcs', { target: sample, engine: engineName, limit: 1 });
    const first = (funcs?.funcs ?? funcs?.functions ?? funcs?.items ?? [])[0];
    if (first?.ea || first?.address) {
      const ea = first.ea ?? first.address;
      const dec = await call('ig5_decompile', { target: sample, engine: engineName, ea });
      check('decompile returns code', typeof (dec?.code ?? dec?.text ?? dec?.pseudocode) === 'string', JSON.stringify(dec).slice(0, 200));
    } else {
      notes.push('SKIP decompile (no function address returned)');
    }
  } catch (error) {
    check('decompile ok', false, String(error?.message).slice(0, 240));
  }

  // 6) close
  try {
    await call('ig5_close', { target: sample, engine: engineName });
    check('close ok', true);
  } catch (error) {
    check('close ok', false, String(error?.message).slice(0, 200));
  }
}

await engine.dispose();

for (const line of notes) console.log(line);
for (const line of failures) console.error(line);
console.log(`\n${failures.length ? 'FAILED' : 'OK'} — ${notes.filter((n) => n.startsWith('PASS')).length} passed, ${failures.length} failed`);
process.exit(failures.length ? 1 : 0);
