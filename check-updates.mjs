// 查询 DSH profile 里第三方插件的最新版本（只读，不安装）。
// 用法: node check-updates.mjs <profileDir> [--tag latest] [--dsh 0.2.2-rc.5]
// 输出: 一行 JSON 数组，每项 { name, spec, kind, current, latest, hasUpdate, enginesDsh, compatible, deprecated, note }
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

async function inspect(name, spec) {
  const row = {
    name, spec, kind: 'npm', current: spec, latest: null, hasUpdate: false,
    enginesDsh: null, compatible: null, deprecated: null, note: null, unpackedSize: null,
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
    if (man.engines && man.engines.dsh) {
      row.enginesDsh = String(man.engines.dsh);
      if (opt.dsh) row.compatible = satisfies(opt.dsh, row.enginesDsh);
    }
    if (man.deprecated) row.deprecated = String(man.deprecated);
    if (man.dist && man.dist.unpackedSize) row.unpackedSize = Number(man.dist.unpackedSize);
  } catch {
    /* 兼容性信息拿不到不影响判断 */
  }
  return row;
}

/* 分批跑，避免一次打 20 个连接 */
const names = Object.keys(deps).sort();
const rows = [];
const CHUNK = 5;
for (let i = 0; i < names.length; i += CHUNK) {
  const part = await Promise.all(names.slice(i, i + CHUNK).map((n) => inspect(n, String(deps[n] ?? ''))));
  rows.push(...part);
}

process.stdout.write(JSON.stringify(rows));
