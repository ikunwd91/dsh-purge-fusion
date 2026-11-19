/**
 * dsh-purge/fusion/engine —— 引擎链路适配层
 *
 * 目标：把供体 dsh-infinite-gen-5 的完整工具面（43 个 ig5_* 工具）接进本插件，
 * 且做到「运行时缺失不崩、与 purge/redteam 零冲突」。
 *
 * 关键发现（决定了本层架构）：
 *   供体的工具定义是「裸」的 —— scope.run 包装、协调/内存/证据装配、revision 校验、
 *   queryState 计算全部在 `apply(ctx, config)` 里对每个 definition 二次加工。
 *   只调 `defineIg5Tools()` 拿到的定义缺少 scope.run，导致
 *   `mgr.get(target)` 算出的 session key 没有 `::engine` 后缀，任何后续工具都会报
 *   「worker 不在运行」。因此本层必须走供体 apply()，用一个受控 stub ctx 捕获它注册的定义。
 *
 * stub ctx 的职责：
 *   - tools.register  → 捕获「已完整包装」的定义（这是要注册到真宿主的）
 *   - tools.restrict  → 不提供：让 installWorkflow 走 instance-wide 分支，
 *                        不去猜 agent scope
 *   - inject(webServer/skills/commands) → no-op：不注册 HTTP 路由、技能、/ig5 命令
 *   - get → undefined：让 approval gate / 诊断路由走降级
 *   - on → no-op：不订阅宿主事件
 *   - effect → 执行并收集 disposer，卸载时统一释放
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import { runtimeConfiguration } from './vendor/engine_runtime.js';
import { apply as donorApply, resolveConfig } from './vendor/donor-index.js';

/** 与供体一致的工具输出渲染：JSON 文本。 */
export const textRender = (_args, value) => [{ type: 'text', text: JSON.stringify(value, null, 1) }];

/** 数据根：全部落在 purge 自己的目录下，不与供体 $DSH_HOME/ig5 混用。 */
export function engineHome() {
  const home = process.env.DSH_HOME || path.join(os.homedir(), '.dsh');
  return path.join(home, 'dsh-purge', 'fusion', 'ig5');
}

/** 供体 core 工具面（默认）。 */
export const ENGINE_CORE = Object.freeze([
  'ig5_doctor', 'ig5_open', 'ig5_status', 'ig5_funcs', 'ig5_strings',
  'ig5_decompile', 'ig5_close', 'ig5_profile',
]);

/**
 * 宿主 DSH 0.2.0 的 JSON Schema 子集白名单。
 * 供体是针对 0.2.1-alpha.1 写的，用了 minItems/maxItems/minimum/maximum/pattern 等关键字，
 * 在本宿主会被 assertObjectJsonSchema 直接拒绝（UNSUPPORTED_SCHEMA），进而让工具注册失败。
 * 这里做无损降级：删掉越界关键字，把可读约束并入 description，语义信息不丢。
 */
const HOST_SCHEMA_KEYS = new Set([
  'type', 'oneOf', 'properties', 'required', 'additionalProperties', 'items',
  'enum', 'const', 'description', 'title', 'default', 'examples',
]);
const READABLE_CONSTRAINTS = new Set([
  'minItems', 'maxItems', 'minimum', 'maximum', 'minLength', 'maxLength',
  'pattern', 'format', 'uniqueItems', 'multipleOf', 'exclusiveMinimum', 'exclusiveMaximum',
]);

/**
 * 从原始 schema 里收集「宿主不会执行」的数值边界，供运行时兜底执行。
 *
 * 背景：本宿主 0.2.0 的校验器只认 type/oneOf/properties/required/
 * additionalProperties/items/enum/const，**从不执行 minimum/maximum/
 * minLength/maxLength/minItems/maxItems**。这些关键字如果留在 schema 里，
 * 只会让工具注册失败（UNSUPPORTED_SCHEMA），删掉又会让边界无人执行。
 * 因此在删之前先把边界记下来，由 {@link enforceBounds} 在调用时执行，
 * 保证「删关键字」不等于「丢约束」。
 *
 * @param {any} node 原始 schema 节点
 * @param {string} [prefix] 当前属性路径前缀
 * @param {Map<string, object>} [out] 收集结果：属性路径 → 边界
 * @returns {Map<string, object>} 属性路径 → { minimum, maximum, minLength, maxLength, minItems, maxItems }
 */
export function collectBounds(node, prefix = '', out = new Map()) {
  if (node === null || typeof node !== 'object') return out;
  if (Array.isArray(node)) return out;
  const bounds = {};
  for (const key of ['minimum', 'maximum', 'minLength', 'maxLength', 'minItems', 'maxItems']) {
    if (typeof node[key] === 'number') bounds[key] = node[key];
  }
  if (Object.keys(bounds).length && prefix) out.set(prefix, bounds);
  if (node.properties && typeof node.properties === 'object') {
    for (const [name, child] of Object.entries(node.properties)) {
      collectBounds(child, prefix ? `${prefix}.${name}` : name, out);
    }
  }
  if (node.items) collectBounds(node.items, prefix ? `${prefix}[]` : '[]', out);
  return out;
}

/**
 * 按 {@link collectBounds} 收集的边界裁剪入参。
 * 只裁数值/字符串/数组长度，不改语义、不抛错（越界即夹到边界）。
 *
 * @param {any} args 工具入参
 * @param {Map<string, object>} bounds 属性路径 → 边界
 * @returns {any} 裁剪后的入参（无变化时返回原对象）
 */
export function enforceBounds(args, bounds) {
  if (!args || typeof args !== 'object' || !bounds || bounds.size === 0) return args;
  let changed = false;
  const next = { ...args };
  // 沿路径浅拷贝每一层，保证不修改调用方传入的嵌套对象
  const writableHolder = (segments) => {
    let holder = next;
    for (const segment of segments) {
      const current = holder[segment];
      if (!current || typeof current !== 'object') return null;
      const copy = Array.isArray(current) ? [...current] : { ...current };
      holder[segment] = copy;
      holder = copy;
    }
    return holder;
  };
  for (const [path, limit] of bounds) {
    const segments = path.split('.');
    const leaf = segments.pop();
    const holder = writableHolder(segments);
    if (!holder) continue;
    const value = holder[leaf];
    if (value === undefined || value === null) continue;

    if (typeof value === 'number' && Number.isFinite(value)) {
      let clamped = value;
      if (limit.minimum !== undefined) clamped = Math.max(limit.minimum, clamped);
      if (limit.maximum !== undefined) clamped = Math.min(limit.maximum, clamped);
      if (clamped !== value) { holder[leaf] = clamped; changed = true; }
    } else if (typeof value === 'string') {
      if (limit.minLength !== undefined && value.length < limit.minLength) continue;
      if (limit.maxLength !== undefined && value.length > limit.maxLength) {
        holder[leaf] = value.slice(0, limit.maxLength);
        changed = true;
      }
    } else if (Array.isArray(value)) {
      if (limit.minItems !== undefined && value.length < limit.minItems) continue;
      if (limit.maxItems !== undefined && value.length > limit.maxItems) {
        holder[leaf] = value.slice(0, limit.maxItems);
        changed = true;
      }
    }
  }
  return changed ? next : args;
}

/**
 * 把任意 schema 压到宿主子集内。
 *
 * 除删越界关键字外，还处理三类宿主会直接拒绝的结构（供体按 0.2.1-alpha.1 写的）：
 *   1. `additionalProperties` 是 schema 对象 → 宿主只接受布尔，降级为 true
 *   2. 同时声明 `type` 与 `oneOf` → 宿主不允许共存，保留 oneOf 删 type
 *   3. 只有 `enum`/`const` 而没有 `type` → 宿主要求先有 type，按取值推断补上
 *
 * @param {any} node 原始 schema 节点
 * @param {string[]} dropped 收集被改动/删除的键（去重后供诊断）
 * @returns {any} 清洗后的 schema
 */
export function sanitizeSchema(node, dropped = []) {
  if (node === null || typeof node !== 'object') return node;
  if (Array.isArray(node)) return node.map((item) => sanitizeSchema(item, dropped));
  const out = {};
  const extras = [];
  for (const [key, value] of Object.entries(node)) {
    if (!HOST_SCHEMA_KEYS.has(key)) {
      if (READABLE_CONSTRAINTS.has(key)) extras.push(`${key}=${JSON.stringify(value)}`);
      if (!dropped.includes(key)) dropped.push(key);
      continue;
    }
    if (key === 'properties' && value && typeof value === 'object' && !Array.isArray(value)) {
      const props = {};
      for (const [propName, propSchema] of Object.entries(value)) props[propName] = sanitizeSchema(propSchema, dropped);
      out.properties = props;
    } else if (key === 'items') {
      out.items = sanitizeSchema(value, dropped);
    } else if (key === 'oneOf' && Array.isArray(value)) {
      out.oneOf = value.map((item) => sanitizeSchema(item, dropped));
    } else if (key === 'additionalProperties' && typeof value !== 'boolean') {
      // 宿主只接受布尔；schema 形式降级为 true（放开额外字段，语义上更宽松但可用）
      if (!dropped.includes('additionalProperties:schema')) dropped.push('additionalProperties:schema');
      out.additionalProperties = true;
    } else {
      out[key] = value;
    }
  }

  // type 与 oneOf 不能共存：oneOf 表达力更强，保留它
  if (out.type !== undefined && out.oneOf !== undefined) {
    if (!dropped.includes('type+oneOf')) dropped.push('type+oneOf');
    delete out.type;
  }

  // oneOf 旁边不允许出现 properties/required/additionalProperties/items/enum/const
  // （宿主 ONE_OF_SIBLING_KEYWORDS）；供体把它们和 oneOf 并列写，这里删掉兄弟键。
  if (out.oneOf !== undefined) {
    for (const sibling of ['properties', 'required', 'additionalProperties', 'items', 'enum', 'const']) {
      if (out[sibling] !== undefined) {
        if (!dropped.includes('oneOf-sibling')) dropped.push('oneOf-sibling');
        delete out[sibling];
      }
    }
  }

  // enum/const 必须有 type 承载；没有就按取值推断
  if (out.type === undefined && out.oneOf === undefined) {
    const infer = (values) => {
      const kinds = new Set(values.map((v) => (v === null ? 'null' : typeof v)));
      if (kinds.size === 1) {
        const only = [...kinds][0];
        if (only === 'string' || only === 'number' || only === 'boolean' || only === 'null') return only;
      }
      return 'string';
    };
    if (Array.isArray(out.enum) && out.enum.length) {
      out.type = infer(out.enum);
      if (!dropped.includes('inferred-type')) dropped.push('inferred-type');
    } else if (out.const !== undefined) {
      out.type = infer([out.const]);
      if (!dropped.includes('inferred-type')) dropped.push('inferred-type');
    } else if (out.properties !== undefined || out.required !== undefined || out.additionalProperties !== undefined) {
      // 只有 required/properties/additionalProperties 而没有 type：宿主要求先有 type
      out.type = 'object';
      if (!dropped.includes('inferred-type')) dropped.push('inferred-type');
    } else if (out.items !== undefined) {
      out.type = 'array';
      if (!dropped.includes('inferred-type')) dropped.push('inferred-type');
    }
  }

  // required 里的字段必须在 properties 里声明，否则宿主拒绝；
  // 供体的 oneOf 分支常靠外层 properties 继承，这里过滤掉无对应声明的项。
  if (Array.isArray(out.required)) {
    const declared = out.properties && typeof out.properties === 'object' ? out.properties : null;
    if (!declared) {
      if (!dropped.includes('required:orphan')) dropped.push('required:orphan');
      delete out.required;
    } else {
      const kept = out.required.filter((key) => typeof key === 'string' && Object.hasOwn(declared, key));
      if (kept.length !== out.required.length) {
        if (!dropped.includes('required:orphan')) dropped.push('required:orphan');
      }
      if (kept.length) out.required = kept;
      else delete out.required;
    }
  }

  if (extras.length) {
    const note = `[${extras.join(', ')}]`;
    out.description = out.description ? `${out.description} ${note}` : note;
  }
  return out;
}

/**
 * 构造引擎上下文：调用供体 apply()，用 stub ctx 捕获完整工具面。
 *
 * @param {object} options
 * @param {object} [options.config] 覆盖供体 cfg（toolset/timeout/projectRoot 等）
 * @param {function} [options.log]
 * @returns {{cfg, definitions, runtime, failures, toolset, dispose}}
 */
export function createEngine(options = {}) {
  const log = options.log ?? (() => {});
  const home = engineHome();
  fs.mkdirSync(home, { recursive: true });

  const baseConfig = {
    home,
    artifactDir: path.join(home, 'artifacts'),
    projectRoot: path.join(home, 'projects'),
    ...options.config,
  };

  const definitions = [];
  const disposers = [];
  const failures = [];
  const refused = [];

  /* ── 受控 stub ctx ─────────────────────────────────────────────── */
  const stubCtx = {
    tools: {
      register(definition) {
        if (!definition?.name) throw new Error('tool definition without a name');
        definitions.push(definition);
        return () => {
          const index = definitions.indexOf(definition);
          if (index >= 0) definitions.splice(index, 1);
        };
      },
      // 故意不提供 restrict：让 installWorkflow 走 instance-wide 分支
    },
    // webServer / skills / commands 全部不接：本层不注册路由、技能、/ig5 命令。
    // 返回值必须同时可调用且带 .dispose()：供体 workflow.dispose() 会调 fiber.dispose()。
    inject(_deps, _callback) {
      const fiber = () => {};
      fiber.dispose = fiber;
      return fiber;
    },
    get() {
      return undefined;
    },
    on() {
      return () => {};
    },
    effect(factory) {
      try {
        const disposer = factory();
        if (typeof disposer === 'function' || (disposer && typeof disposer.then === 'function')) {
          disposers.push(disposer);
        }
      } catch (error) {
        failures.push({ label: 'ctx.effect', reason: String(error?.message ?? error) });
        log('ctx.effect failed', error);
      }
      return () => {};
    },
    logger: { warn() {}, info() {}, error() {}, debug() {} },
  };

  /* ── 调供体 apply 完成完整装配 ─────────────────────────────────── */
  let applied = false;
  try {
    donorApply(stubCtx, baseConfig);
    applied = true;
  } catch (error) {
    failures.push({ label: 'donorApply', reason: String(error?.message ?? error) });
    log('donor apply failed', error);
  }

  // 供体 apply 内部各自兜底：即使它在某一步抛错，之前 capture 到的定义仍可用
  const unique = [];
  const seen = new Set();
  for (const definition of definitions) {
    if (seen.has(definition.name)) {
      failures.push({ label: 'dedupe', reason: `重复工具 ${definition.name}` });
      continue;
    }
    seen.add(definition.name);
    unique.push(definition);
  }

  // 供体没提供的能力：这里只做状态读取，不假装可用
  let cfg;
  try {
    cfg = resolveConfig(baseConfig);
  } catch (error) {
    const runtime = runtimeConfiguration(baseConfig);
    cfg = { ...runtime, home, toolset: 'core', configError: String(error?.message ?? error) };
    refused.push({ label: 'resolveConfig', reason: String(error?.message ?? error) });
  }

  const runtime = {
    home,
    runtimeRoot: cfg.runtimeRoot ?? null,
    ghidra: {
      available: cfg.ghidra?.available === true,
      source: cfg.ghidra?.source ?? null,
      readiness: cfg.ghidra?.readiness ?? null,
      reason: cfg.ghidra?.reason ?? null,
      pythonExe: cfg.ghidra?.pythonExe ?? null,
    },
    x64dbg: {
      available: cfg.x64dbg?.available === true,
      source: cfg.x64dbg?.source ?? null,
      readiness: cfg.x64dbg?.readiness ?? null,
      reason: cfg.x64dbg?.reason ?? null,
    },
    reverseProvider: cfg.reverseProvider ?? null,
    defaultEngine: cfg.defaultEngine ?? null,
    toolset: cfg.toolset ?? 'core',
    configError: cfg.configError ?? null,
  };

  let disposed = false;
  const dispose = async () => {
    if (disposed) return;
    disposed = true;
    for (const disposer of disposers.reverse()) {
      try {
        await (typeof disposer === 'function' ? disposer() : disposer);
      } catch (error) {
        log('disposer failed', error?.message ?? String(error), error?.code ?? '');
      }
    }
    disposers.length = 0;
    definitions.length = 0;
  };

  log('engine ready', { applied, tools: unique.length, failures: failures.length, ghidra: runtime.ghidra.available });

  // 目标 → 引擎 的会话映射：供体 sessionKey 依赖 scope.engine，
  // 这里记录用户 ig5_open 时选的引擎，后续同目标调用自动补齐。
  const engineByTarget = new Map();
  const keyOf = (target) => {
    const absolute = path.resolve(String(target));
    return (runtime && cfg?.host?.platform === 'win32') || process.platform === 'win32' ? absolute.toLowerCase() : absolute;
  };
  const remember = (target, engineId) => {
    if (!target || !engineId) return;
    engineByTarget.set(keyOf(target), engineId);
  };
  const engineFor = (target) => (target ? engineByTarget.get(keyOf(target)) ?? null : null);

  return { cfg, definitions: unique, runtime, failures, refused, applied, dispose, remember, engineFor, engineByTarget };
}

/** 引擎是否具备至少一个可用静态后端。 */
export function engineReady(engine) {
  return Boolean(engine?.runtime?.ghidra?.available || engine?.runtime?.x64dbg?.available);
}

/** 供体 apply() 已经包装过 scope.run，本层只补 schema 降级、engine 补齐与运行时缺失提示。 */
export function wrapDefinition(definition, engine, dropped = []) {
  // 先收集原始边界（宿主不执行这些关键字），再由 enforceBounds 在调用时执行，
  // 保证「删 schema 关键字」不等于「丢约束」。
  const bounds = definition.parameters ? collectBounds(definition.parameters) : new Map();
  const parameters = definition.parameters ? sanitizeSchema(definition.parameters, dropped) : definition.parameters;
  const output = definition.output
    ? { ...definition.output, ...(definition.output.schema ? { schema: sanitizeSchema(definition.output.schema, dropped) } : {}) }
    : definition.output;

  /**
   * 供体 `WorkerManager.sessionKey()` 用 `scope.getStore()?.engine || cfg.defaultEngine`
   * 决定会话键后缀。用户 `ig5_open engine=ghidra` 之后若后续调用不带 engine，
   * 就会回落到 defaultEngine('reverse')，算出 `path` 而非 `path::ghidra`，
   * 于是报「worker 不在运行」。这里用一张「目标→引擎」表在调用前补齐，
   * 不改供体代码，也不要求用户每次重复写 engine。
   */
  const resolveEngine = (args) => {
    if (!args || typeof args !== 'object') return args;
    const target = typeof args.target === 'string' && args.target ? args.target
      : typeof args.path === 'string' && args.path ? args.path
        : null;
    // 记录 open 的引擎，供后续调用复用
    if (definition.name === 'ig5_open' && target && typeof args.engine === 'string') {
      engine.remember(target, args.engine);
    }
    if (args.engine || !target) return args;
    const known = engine.engineFor(target);
    return known ? { ...args, engine: known } : args;
  };

  const capture = (value) => {
    if (definition.name === 'ig5_open' && value && typeof value === 'object') {
      const target = typeof value.target === 'string' ? value.target : null;
      const engineId = typeof value.engine === 'string' ? value.engine : null;
      if (target && engineId) engine.remember(target, engineId);
    }
    return value;
  };

  return {
    ...definition,
    ...(parameters ? { parameters } : {}),
    ...(output ? { output } : {}),
    async execute(args, execution) {
      try {
        return capture(await definition.execute(resolveEngine(enforceBounds(args ?? {}, bounds)), execution));
      } catch (error) {
        const message = String(error?.message ?? error);
        // 运行时缺失：补一条可操作的提示，保留原始错误
        if (/runtime|not found|ENOENT|missing/i.test(message) && !engineReady(engine)) {
          throw Object.assign(
            new Error(`${message}\n\n引擎运行时未安装。把 IG5 完整发行包的 runtimes/ 解压到 ${engine.runtime.home}\\runtimes，或用 purge_engine_tools 查看当前探测结果。`),
            { code: error?.code ?? 'ENGINE_RUNTIME_MISSING', cause: error },
          );
        }
        throw error;
      }
    },
  };
}
