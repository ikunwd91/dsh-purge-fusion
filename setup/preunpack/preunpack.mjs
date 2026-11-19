// preunpack.mjs — 在「程序完全退出」后把官方 app.asar 解成 resources\app，并把 asar 换名成 .bak
// 目的：绕开「点应用时在宿主主进程里同步解包」造成的 10 分钟卡「处理中」/ failed to fetch。
// 只用 node:fs：不依赖 Electron，不依赖 dsh-purge 插件是否存在。
//
// 用法（一般由 preunpack.ps1 调用，不用手敲）：
//   node preunpack.mjs --resources "<安装目录>\resources" --dry-run
//   node preunpack.mjs --resources "<安装目录>\resources" --commit
//
// 顺序刻意是「先换 app\，再换 asar」：任何一步失败，asar 还在，程序仍能打开。

import fs from "node:fs";
import path from "node:path";

const say = (s) => process.stdout.write(String(s) + "\n");

function arg(name, def = "") {
  const i = process.argv.indexOf("--" + name);
  if (i === -1) return def;
  const v = process.argv[i + 1];
  return v && !v.startsWith("--") ? v : "true";
}

const resources = path.resolve(arg("resources"));
const dryRun = arg("dry-run") === "true";
const commit = arg("commit") === "true";

if (!resources || !fs.existsSync(resources)) {
  say("ERR resources not found: " + resources);
  process.exit(2);
}
if (!dryRun && !commit) {
  say("ERR need --dry-run or --commit");
  process.exit(2);
}

function isFile(p) {
  try { return fs.statSync(p).isFile(); } catch { return false; }
}
function isDir(p) {
  try { return fs.statSync(p).isDirectory(); } catch { return false; }
}

function pickAsar(dir) {
  for (const n of ["app.asar", "app.asar.bak"]) {
    const p = path.join(dir, n);
    if (isFile(p)) return p;
  }
  return "";
}

function aiBaseUnder(appDir) {
  for (const p of [
    path.join(appDir, "dsh", "node_modules", "@deepseek-ai"),
    path.join(appDir, "node_modules", "@deepseek-ai"),
  ]) if (isDir(p)) return p;
  return "";
}

function rmDir(p) {
  try { fs.rmSync(p, { recursive: true, force: true }); return true; }
  catch (e) { say("WARN rm " + p + " : " + (e && e.message)); return false; }
}

// ---------- asar ----------
function readHeader(fd) {
  const pre = Buffer.alloc(16);
  if (fs.readSync(fd, pre, 0, 16, 0) !== 16) throw new Error("asar header truncated");
  if (pre.readUInt32LE(0) !== 4) throw new Error("not an asar archive");
  const headerSize = pre.readUInt32LE(4);
  const jsonSize = pre.readUInt32LE(12);
  if (!headerSize || !jsonSize || jsonSize > 256 * 1024 * 1024) throw new Error("asar header size invalid");
  const buf = Buffer.alloc(jsonSize);
  if (fs.readSync(fd, buf, 0, jsonSize, 16) !== jsonSize) throw new Error("asar header short");
  return { header: JSON.parse(buf.toString("utf8")), dataOffset: 8 + headerSize };
}

function walk(node, prefix, out) {
  const files = node && node.files;
  if (!files) return;
  for (const [name, info] of Object.entries(files)) {
    const rel = prefix ? prefix + "/" + name : name;
    if (info && info.files) walk(info, rel, out);
    else if (info) out.push({ rel, info });
  }
}

function copyRange(fd, offset, size, outPath) {
  const out = fs.openSync(outPath, "w");
  try {
    const buf = Buffer.alloc(Math.min(1024 * 1024, Math.max(size, 1)));
    let left = size;
    let pos = offset;
    while (left > 0) {
      const n = fs.readSync(fd, buf, 0, Math.min(buf.length, left), pos);
      if (n <= 0) throw new Error("short read at " + outPath);
      fs.writeSync(out, buf, 0, n);
      pos += n;
      left -= n;
    }
  } finally {
    fs.closeSync(out);
  }
}

// app.asar.unpacked 里的原生模块不在归档正文，解开目录后必须补进去
function overlayUnpacked(asarPath, destDir) {
  const unpacked = asarPath.replace(/\.bak$/i, "") + ".unpacked";
  if (!isDir(unpacked)) return 0;
  let copied = 0;
  const stack = [unpacked];
  while (stack.length) {
    const dir = stack.pop();
    for (const ent of fs.readdirSync(dir, { withFileTypes: true })) {
      const from = path.join(dir, ent.name);
      const to = path.join(destDir, path.relative(unpacked, from));
      if (ent.isDirectory()) { fs.mkdirSync(to, { recursive: true }); stack.push(from); }
      else if (ent.isFile()) {
        if (fs.existsSync(to)) continue;
        fs.mkdirSync(path.dirname(to), { recursive: true });
        fs.copyFileSync(from, to);
        copied += 1;
        if (copied % 200 === 0) say("OVERLAY " + copied);
      }
    }
  }
  return copied;
}

function extract(asarPath, destDir) {
  const fd = fs.openSync(asarPath, "r");
  const t0 = Date.now();
  let done = 0;
  let plan = 0;
  try {
    const { header, dataOffset } = readHeader(fd);
    const entries = [];
    walk(header, "", entries);
    plan = entries.filter((e) => !(e.info && e.info.unpacked)).length;
    say("PLAN " + plan);
    fs.mkdirSync(destDir, { recursive: true });
    for (const entry of entries) {
      const info = entry.info;
      const outPath = path.join(destDir, ...entry.rel.split("/"));
      fs.mkdirSync(path.dirname(outPath), { recursive: true });
      if (info.unpacked) continue;
      if (typeof info.link === "string") {
        const linkResolved = path.resolve(path.dirname(outPath), info.link);
        const destResolved = path.resolve(destDir);
        const inside = linkResolved === destResolved || linkResolved.startsWith(destResolved + path.sep);
        if (!inside) continue;
        try { fs.symlinkSync(info.link, outPath); } catch { /* 建不了链接就跳过 */ }
        continue;
      }
      const size = Number(info.size || 0);
      const offset = dataOffset + Number(info.offset || 0);
      if (size === 0) fs.writeFileSync(outPath, Buffer.alloc(0));
      else copyRange(fd, offset, size, outPath);
      done += 1;
      if (done % 250 === 0) {
        const pct = plan ? Math.floor((done / plan) * 100) : 0;
        say("EXTRACT " + done + "/" + plan + " " + pct + "% " + Math.round((Date.now() - t0) / 1000) + "s");
      }
    }
  } finally {
    fs.closeSync(fd);
  }
  return done;
}

function stampPath() {
  const home = process.env.DSH_HOME || path.join(process.env.USERPROFILE || "", ".dsh");
  return path.join(home, "dsh-purge", "unpacked-asar.json");
}

// ---------- main ----------
const appDir = path.join(resources, "app");
const next = appDir + ".dshpurge-next";
const asar = pickAsar(resources);
if (!asar) {
  say("ERR no app.asar under " + resources);
  process.exit(3);
}
say("ASAR " + asar + " " + fs.statSync(asar).size);
say("APPDIR " + (isDir(appDir) ? "exists" : "absent"));
if (fs.existsSync(next)) say("NEXT stale");

rmDir(next);
const count = extract(asar, next);
const over = overlayUnpacked(asar, next);
say("EXTRACTED " + count + " overlay " + over);

const base = aiBaseUnder(next);
if (!base) {
  rmDir(next);
  say("ERR no @deepseek-ai after extract; nothing touched");
  process.exit(4);
}
say("VERIFY_OK");

if (dryRun) {
  rmDir(next);
  say("DRY_RUN_OK");
  process.exit(0);
}

// 先换 app\（asar 还在，程序照常能开），再换 asar
const ts = new Date().toISOString().replace(/[-:T]/g, "").slice(0, 14);
let prev = "";
if (isDir(appDir)) {
  prev = appDir + ".dshpurge-prev-" + ts;
  fs.renameSync(appDir, prev);
  say("PREV_SAVED");
}
try {
  fs.renameSync(next, appDir);
} catch (e) {
  say("ERR swap: " + (e && e.message));
  if (prev && !isDir(appDir)) { try { fs.renameSync(prev, appDir); } catch { /* 旧目录仍在 prev */ } }
  process.exit(5);
}
if (!aiBaseUnder(appDir)) {
  rmDir(appDir);
  if (prev) { try { fs.renameSync(prev, appDir); } catch { /* 旧目录仍在 prev */ } }
  say("ERR verify after swap failed; rolled back");
  process.exit(6);
}
say("APPDIR_READY");

if (!/\.bak$/i.test(asar)) {
  const st = fs.statSync(asar);
  try {
    const bak = asar + ".bak";
    if (isFile(bak)) { try { fs.rmSync(bak, { force: true }); } catch { /* 同名旧备份删不掉就让下面 rename 报错 */ } }
    fs.renameSync(asar, bak);
    say("ASAR_RENAMED");
  } catch (e) {
    say("ERR rename asar (app dir is ready; quit the app fully and rerun): " + (e && e.message));
    process.exit(7);
  }
  const sp = stampPath();
  try {
    fs.mkdirSync(path.dirname(sp), { recursive: true });
    fs.writeFileSync(sp, JSON.stringify({ size: st.size, mtimeMs: Math.round(st.mtimeMs) }) + "\n", "utf8");
    say("STAMP " + sp);
  } catch (e) {
    say("WARN stamp: " + (e && e.message));
  }
}
say("DONE_OK");
