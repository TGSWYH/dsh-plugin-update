// 查询 DSH profile 里第三方插件的最新版本（只读，不安装）。
// 用法: node check-updates.mjs <profileDir> [--tag latest] [--dsh 0.2.2-rc.5]
// 输出: 一行 JSON 数组，每项 {
//   name, spec, kind, current, latest, hasUpdate, deprecated, note, unpackedSize,
//   enginesDsh, enginesFrom, compatible,              // 最新版对 DSH 的要求
//   installed, installedRange, installedRangeFrom, installedCompatible,  // 已装版本
//   bestCompatible, bestCompatibleRange, bestCompatibleFrom,             // 当前 DSH 能用的最新版本
//   target, targetNote }                              // 最终应安装的版本（null = 没有可装的）
// 注意: 只把 JSON 写到 stdout，其它一律走 stderr。
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

const argv = process.argv.slice(2);
const profileDir = argv[0];
if (!profileDir) {
  console.error('usage: node check-updates.mjs <profileDir> [--tag <dist-tag>] [--dsh <version>]');
  process.exit(2);
}
const opt = { tag: 'latest', dsh: null };
for (let i = 1; i < argv.length; i++) {
  if (argv[i] === '--tag') opt.tag = argv[++i];
  else if (argv[i] === '--dsh') opt.dsh = argv[++i];
}

const pkg = JSON.parse(readFileSync(join(profileDir, 'package.json'), 'utf8'));
const deps = {};
for (const field of ['dependencies', 'devDependencies', 'optionalDependencies']) {
  const block = pkg[field];
  if (block && typeof block === 'object') {
    for (const [name, spec] of Object.entries(block)) if (!(name in deps)) deps[name] = spec;
  }
}

// 不是 npm 包，没法问 registry
const NON_NPM = /^(github:|git\+|git:|file:|link:|workspace:|portal:|https?:|\.{0,2}[\\/])/i;

/* ---------------- 极简 semver ---------------- */

function parseSemver(v) {
  const m = /^v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$/.exec(String(v).trim());
  if (!m) return null;
  return { major: +m[1], minor: +m[2], patch: +m[3], pre: m[4] ? m[4].split('.') : [] };
}

function cmpSemver(a, b) {
  if (a.major !== b.major) return a.major - b.major;
  if (a.minor !== b.minor) return a.minor - b.minor;
  if (a.patch !== b.patch) return a.patch - b.patch;
  if (!a.pre.length && !b.pre.length) return 0;
  if (!a.pre.length) return 1; // 正式版 > 预发布
  if (!b.pre.length) return -1;
  const n = Math.max(a.pre.length, b.pre.length);
  for (let i = 0; i < n; i++) {
    const x = a.pre[i];
    const y = b.pre[i];
    if (x === undefined) return -1;
    if (y === undefined) return 1;
    const nx = /^\d+$/.test(x);
    const ny = /^\d+$/.test(y);
    if (nx && ny) {
      const d = Number(x) - Number(y);
      if (d) return d;
    } else if (nx) return -1; // 数字标识 < 字母标识
    else if (ny) return 1;
    else if (x !== y) return x < y ? -1 : 1;
  }
  return 0;
}

function mk(major, minor, patch, pre) {
  return { major, minor, patch, pre: pre || [] };
}

function testOne(ver, op, t) {
  const c = () => cmpSemver(ver, t);
  switch (op) {
    case '=': return c() === 0;
    case '>': return c() > 0;
    case '>=': return c() >= 0;
    case '<': return c() < 0;
    case '<=': return c() <= 0;
    case '^': {
      if (c() < 0) return false;
      let upper;
      if (t.major > 0) upper = mk(t.major + 1, 0, 0, t.pre.length ? ['0'] : []);
      else if (t.minor > 0) upper = mk(0, t.minor + 1, 0, t.pre.length ? ['0'] : []);
      else upper = mk(0, 0, t.patch + 1, t.pre.length ? ['0'] : []);
      return cmpSemver(ver, upper) < 0;
    }
    case '~': {
      if (c() < 0) return false;
      const upper = mk(t.major, t.minor + 1, 0, t.pre.length ? ['0'] : []);
      return cmpSemver(ver, upper) < 0;
    }
    default: return false;
  }
}

// 返回 true / false / null(不认识这个范围写法)
function satisfies(version, range) {
  const ver = parseSemver(version);
  if (!ver) return null;
  const alts = String(range).split('||').map((s) => s.trim()).filter(Boolean);
  if (!alts.length) return null;
  let sawUnknown = false;
  for (const alt of alts) {
    // 空格分隔的每个比较式就是一个 token（"^1.2.3"、">=0.2.1-rc.2"），
    // 不能先把运算符和版本号拆开，否则 ">=" 会被切碎。
    const parts = alt.split(/\s+/).filter(Boolean);
    if (!parts.length) continue;
    let ok = true;
    for (const p of parts) {
      const m = /^([><=~^]+)?(.*)$/.exec(p);
      if (!m || !m[2]) { sawUnknown = true; ok = false; break; }
      const op = m[1] || '=';
      const t = parseSemver(m[2]);
      if (!t) { sawUnknown = true; ok = false; break; }
      if (!testOne(ver, op, t)) { ok = false; break; }
    }
    if (ok) return true;
  }
  return sawUnknown ? null : false;
}

/* ---------------- registry ---------------- */

async function getJson(url, accept) {
  const res = await fetch(url, {
    headers: { accept: accept || 'application/json', 'user-agent': 'dsh-plugin-update-script' },
    signal: AbortSignal.timeout(20000),
  });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  return res.json();
}

const pkgUrl = (name) => `https://registry.npmjs.org/${name.replace('/', '%2f')}`;

// DSH 插件的兼容范围有三个可能的落点，优先级从上到下：
//   1. dsh.engines.dsh            —— @linxin666/dsh-web-all 这类用 dsh manifest 的
//   2. engines.dsh                —— 最常见，纯 npm 式声明
//   3. peerDependencies["@deepseek-ai/dsh"]
// 只认第一个会漏掉 1 和 3，把「不兼容」误判成「无法校验」然后放行。
const DSH_RANGE_FIELDS = [
  ['dsh.engines.dsh', (m) => m.dsh && m.dsh.engines && m.dsh.engines.dsh],
  ['engines.dsh', (m) => m.engines && m.engines.dsh],
  ['peerDependencies', (m) => m.peerDependencies && m.peerDependencies['@deepseek-ai/dsh']],
];

function readDshRange(man) {
  if (!man) return { range: null, from: null };
  for (const [from, pick] of DSH_RANGE_FIELDS) {
    let v;
    try { v = pick(man); } catch { v = null; }
    if (v && String(v).trim()) return { range: String(v).trim(), from };
  }
  return { range: null, from: null };
}

async function inspect(name, spec) {
  const row = {
    name, spec, kind: 'npm', current: spec, latest: null, hasUpdate: false,
    enginesDsh: null, enginesFrom: null, compatible: null, deprecated: null, note: null, unpackedSize: null,
    installed: null, installedCompatible: null,
  };
  if (NON_NPM.test(spec)) {
    row.kind = 'git';
    row.note = 'Git/本地依赖';
    return row;
  }
  const cur = parseSemver(String(spec).replace(/^[\^~= ]+/, ''));
  if (!cur) {
    row.kind = 'range';
    row.note = '版本号不是精确值，安装命令里用包名交给 pnpm 解析';
    row.current = null;
    return row;
  }
  let doc;
  try {
    doc = await getJson(pkgUrl(name), 'application/vnd.npm.install-v1+json');
  } catch (e) {
    row.note = `查询失败: ${e && e.message ? e.message : e}`;
    return row;
  }
  const latest = doc['dist-tags'] && doc['dist-tags'][opt.tag];
  if (!latest) {
    row.note = `registry 上没有 dist-tag "${opt.tag}"`;
    return row;
  }
  row.latest = latest;
  const lt = parseSemver(latest);
  if (!lt) { row.note = `最新版号无法解析: ${latest}`; return row; }
  if (cmpSemver(lt, cur) <= 0) return row;

  row.hasUpdate = true;
  try {
    const man = await getJson(`${pkgUrl(name)}/${latest}`);
    const got = readDshRange(man);
    if (got.range) {
      row.enginesDsh = got.range;
      row.enginesFrom = got.from;
      if (opt.dsh) row.compatible = satisfies(opt.dsh, row.enginesDsh);
    }
    if (man.deprecated) row.deprecated = String(man.deprecated);
    if (man.dist && man.dist.unpackedSize) row.unpackedSize = Number(man.dist.unpackedSize);
  } catch {
    /* 兼容性信息拿不到不影响判断 */
  }
  return row;
}

// 已装版本是否和当前 DSH 兼容（不联网，直接读 node_modules 里的 package.json）
function inspectInstalled(name) {
  const p = join(profileDir, 'node_modules', ...name.split('/'), 'package.json');
  let man;
  try { man = JSON.parse(readFileSync(p, 'utf8')); } catch { return { installed: null, range: null, from: null, compatible: null }; }
  const got = readDshRange(man);
  return {
    installed: man.version || null,
    range: got.range,
    from: got.from,
    compatible: got.range && opt.dsh ? satisfies(opt.dsh, got.range) : null,
  };
}

// 在某个包的全部版本里找「最新的、且与当前 DSH 兼容的」版本。
// 只有在最新版不兼容、或已装版本不兼容时才调用（要拉完整 packument，比 abbreviated 大）。
const bestCache = new Map();
async function bestCompatible(name) {
  if (bestCache.has(name)) return bestCache.get(name);
  let result = { version: null, range: null, from: null, note: null };
  try {
    const doc = await getJson(pkgUrl(name)); // 完整 packument，才带 dsh 字段
    const vers = Object.keys(doc.versions || {}).filter((v) => parseSemver(v));
    vers.sort((a, b) => cmpSemver(parseSemver(b), parseSemver(a))); // 从新到旧
    for (const v of vers) {
      const got = readDshRange(doc.versions[v]);
      // 没有兼容声明的版本视为不限制，但只在没有任何带声明的版本可用时才接受
      if (got.range && satisfies(opt.dsh, got.range) === true) {
        result = { version: v, range: got.range, from: got.from, note: null };
        break;
      }
    }
    if (!result.version) {
      for (const v of vers) {
        if (!readDshRange(doc.versions[v]).range) { result = { version: v, range: null, from: null, note: '没有兼容声明' }; break; }
      }
    }
    if (!result.version) result.note = '所有版本都要求更高的 DSH';
  } catch (e) {
    result.note = `查询失败: ${e && e.message ? e.message : e}`;
  }
  bestCache.set(name, result);
  return result;
}

/* 分批跑，避免一次打 20 个连接 */
const names = Object.keys(deps).sort();
const rows = [];
const CHUNK = 5;
for (let i = 0; i < names.length; i += CHUNK) {
  const part = await Promise.all(names.slice(i, i + CHUNK).map((n) => inspect(n, String(deps[n] ?? ''))));
  rows.push(...part);
}

// 补上「当前已装版本」的兼容性，让调用方能看到已经躺在 node_modules 里的不兼容插件；
// 如果最新版（或已装版）与当前 DSH 不兼容，再往前找一个最新的兼容版本当目标。
for (const row of rows) {
  const inst = inspectInstalled(row.name);
  row.installed = inst.installed;
  row.installedRange = inst.range;
  row.installedRangeFrom = inst.from;
  row.installedCompatible = inst.compatible;

  row.bestCompatible = null;
  row.bestCompatibleRange = null;
  row.bestCompatibleFrom = null;
  row.target = row.hasUpdate ? row.latest : null; // 最终要装的版本
  row.targetNote = null;

  const latestBlocked = row.hasUpdate && row.compatible === false;
  const installedBlocked = row.installedCompatible === false;
  if (row.kind !== 'npm' || (!latestBlocked && !installedBlocked)) continue;

  const best = await bestCompatible(row.name);
  row.bestCompatible = best.version;
  row.bestCompatibleRange = best.range;
  row.bestCompatibleFrom = best.from;

  if (latestBlocked) {
    if (!best.version) {
      row.target = null;
      row.targetNote = `最新版要求 DSH ${row.enginesDsh}；${best.note || '找不到更旧的兼容版本'}`;
    } else if (cmpSemver(parseSemver(best.version), parseSemver(row.current)) > 0) {
      row.target = best.version;
      row.targetNote = `最新版 ${row.latest} 要求 DSH ${row.enginesDsh}，改投最新兼容版 ${best.version}`;
    } else {
      row.target = null;
      row.targetNote = `已是最新的兼容版本 ${row.current}（${row.latest} 要求 DSH ${row.enginesDsh}）`;
    }
  } else if (installedBlocked) {
    // 已装版本不兼容：即使没有更新，也值得退到兼容版本（-Repair 时执行）
    row.target = best.version || null;
    row.targetNote = best.version
      ? `已装的 ${row.installed} 要求 ${row.installedRange}，退回兼容版 ${best.version}`
      : (best.note || '找不到兼容版本');
  }
  // 目标比已装的低 = 退回（调用方据此在计划里标「退回」而不是「升级」）
}

// 统一算 isDowngrade（对所有行，不只是在上面走过兼容性分支的）
for (const row of rows) {
  row.isDowngrade = false;
  if (!row.target) continue;
  const a = parseSemver(row.target);
  const b = parseSemver(String(row.installed || row.current || '').replace(/^[\^~= ]+/, ''));
  if (a && b && cmpSemver(a, b) < 0) row.isDowngrade = true;
}

process.stdout.write(JSON.stringify(rows));
