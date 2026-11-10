// tools/smoke.js — 端到端冒烟：真实 HTTP 请求，覆盖鉴权/并发/限流/越权
// 用法: node tools/smoke.js
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'aurora-smoke-'));
process.env.AURORA_DATA = TMP;
process.env.PORT = '0';
process.env.HOST = '127.0.0.1';
process.env.AURORA_QUIET = '1';
process.env.AURORA_SECRET = 'x'.repeat(48);
process.env.AURORA_MAX_USERS = '4';

let pass = 0;
const failures = [];

function ok(name) {
  pass += 1;
  console.log(`  \u2713 ${name}`);
}
function bad(name, detail) {
  failures.push(`${name} — ${detail}`);
  console.log(`  \u2717 ${name}  ${detail}`);
}
function eq(name, actual, expected) {
  if (JSON.stringify(actual) === JSON.stringify(expected)) ok(name);
  else bad(name, `期望 ${JSON.stringify(expected)}，实际 ${JSON.stringify(actual)}`);
}
function truthy(name, v) {
  if (v) ok(name);
  else bad(name, `期望为真，实际 ${JSON.stringify(v)}`);
}

class Jar {
  constructor() { this.cookies = new Map(); }
  absorb(res) {
    const list = typeof res.headers.getSetCookie === 'function'
      ? res.headers.getSetCookie()
      : [res.headers.get('set-cookie')].filter(Boolean);
    for (const raw of list) {
      const [pair] = String(raw).split(';');
      const i = pair.indexOf('=');
      if (i < 0) continue;
      const k = pair.slice(0, i).trim();
      const v = pair.slice(i + 1).trim();
      if (v === '') this.cookies.delete(k);
      else this.cookies.set(k, v);
    }
  }
  header() {
    return [...this.cookies.entries()].map(([k, v]) => `${k}=${v}`).join('; ');
  }
}

async function main() {
  const { start } = await import('../server/index.js');
  dbModule = await import('../server/db.js');
  const { server, port } = await start();
  const base = `http://127.0.0.1:${port}`;
  const jar = new Jar();

  const call = async (method, p, { body, token, cookie, raw } = {}) => {
    const headers = {};
    if (body !== undefined) headers['Content-Type'] = raw || 'application/json';
    if (token) headers.Authorization = `Bearer ${token}`;
    if (cookie) headers.Cookie = cookie;
    const res = await fetch(base + p, {
      method,
      headers,
      body: body === undefined ? undefined : (typeof body === 'string' ? body : JSON.stringify(body)),
      redirect: 'manual',
    });
    jar.absorb(res);
    const text = await res.text();
    let json = null;
    try { json = text ? JSON.parse(text) : null; } catch { /* 非 JSON */ }
    return { status: res.status, json, text, headers: res.headers };
  };

  console.log(`\nAurora 冒烟测试  ${base}\n  DATA ${TMP}\n`);

  /* 基础面 */
  let r = await call('GET', '/api/health');
  eq('health 200 & db up', [r.status, r.json?.db], [200, 'up']);

  r = await call('GET', '/api/version');
  eq('version 返回名称与语义版本', [r.status, r.json?.name, /^\d+\.\d+\.\d+/.test(r.json?.version || '')], [200, 'Aurora Console', true]);
  truthy('version 带 build 标识', typeof r.json?.build === 'string' && r.json.build.length > 0);

  r = await call('GET', '/api/nope');
  eq('未知接口 404', r.status, 404);

  /* 注册校验 */
  r = await call('POST', '/api/auth/register', { body: { email: 'bad', password: 'Abcdefg1' } });
  eq('非法邮箱 422', r.status, 422);

  r = await call('POST', '/api/auth/register', { body: { email: 'a@b.co', password: 'short' } });
  eq('弱口令 422', r.status, 422);

  r = await call('POST', '/api/auth/register', { body: { email: 'a@b.co', password: 'Abcdefg1' }, raw: 'text/plain' });
  eq('错误 Content-Type 415', r.status, 415);

  r = await call('POST', '/api/auth/register', { body: { email: 'a@b.co', password: 'Abcdefg1', pad: 'z'.repeat(200_000) } });
  eq('超大体 413', r.status, 413);

  /* 注册成功 */
  r = await call('POST', '/api/auth/register', { body: { email: 'owner@aurora.dev', password: 'Aurora2026!' } });
  eq('注册 201', r.status, 201);
  truthy('返回 access 令牌', typeof r.json?.access === 'string' && r.json.access.split('.').length === 3);
  eq('首个用户为 owner', r.json?.user?.role, 'owner');
  truthy('下发 HttpOnly 刷新 Cookie', jar.cookies.has('aurora_rt'));
  truthy('口令不回传', r.json?.user?.password === undefined);
  const access = r.json.access;

  r = await call('POST', '/api/auth/register', { body: { email: 'owner@aurora.dev', password: 'Aurora2026!' } });
  eq('重复注册 409', r.status, 409);

  /* 登录 */
  r = await call('POST', '/api/auth/login', { body: { email: 'owner@aurora.dev', password: 'WrongPass1' } });
  eq('错误口令 401', r.status, 401);

  r = await call('POST', '/api/auth/login', { body: { email: 'OWNER@aurora.dev ', password: 'Aurora2026!' } });
  eq('登录 200（邮箱大小写/空格归一）', r.status, 200);
  const token = r.json.access;

  /* 鉴权 */
  r = await call('GET', '/api/me');
  eq('无令牌 401', r.status, 401);

  r = await call('GET', '/api/me', { token: token.slice(0, -3) + 'abc' });
  eq('篡改令牌 401', r.status, 401);

  r = await call('GET', '/api/me', { token });
  eq('me 返回本人', [r.status, r.json?.user?.email], [200, 'owner@aurora.dev']);

  /* 条目 */
  r = await call('POST', '/api/notes', { token, body: { title: '  第一条  ', body: '极光控制台', priority: 2, tags: '#发布, 版本控制' } });
  eq('新建条目 201', r.status, 201);
  const note = r.json.note;
  eq('标题裁剪', note.title, '第一条');
  eq('初始 rev=1', note.rev, 1);
  eq('标签归一化', note.tags, ['发布', '版本控制']);
  eq('优先级保存', note.priority, 2);

  r = await call('POST', '/api/notes', { token, body: { title: '' } });
  eq('空标题 422', r.status, 422);

  r = await call('POST', '/api/notes', { token, body: { title: '优先级越界', priority: 7 } });
  eq('非法优先级 422', r.status, 422);

  r = await call('GET', '/api/notes', { token });
  eq('列表条数 1', [r.status, r.json?.notes?.length], [200, 1]);

  r = await call('GET', '/api/notes?q=极光', { token });
  eq('搜索命中正文', r.json?.notes?.length, 1);

  r = await call('GET', '/api/notes?q=%25', { token });
  eq('LIKE 通配符被转义', r.json?.notes?.length, 0);

  /* 乐观并发 */
  r = await call('PATCH', `/api/notes/${note.id}`, { token, body: { status: 'done', rev: 99 } });
  eq('过期 rev 409', r.status, 409);

  r = await call('PATCH', `/api/notes/${note.id}`, { token, body: { status: 'done', rev: 1 } });
  eq('合法 rev 更新 200', [r.status, r.json?.note?.status, r.json?.note?.rev], [200, 'done', 2]);

  r = await call('PATCH', `/api/notes/${note.id}`, { token, body: {} });
  eq('空补丁 400', r.status, 400);

  /* 统计 */
  r = await call('GET', '/api/stats', { token });
  eq('统计：1 条已完成', [r.json?.total, r.json?.done], [1, 1]);

  /* 越权隔离 */
  const jarB = new Jar();
  const callB = async (method, p, opts = {}) => {
    const headers = { 'Content-Type': 'application/json' };
    if (opts.token) headers.Authorization = `Bearer ${opts.token}`;
    const res = await fetch(base + p, { method, headers, body: opts.body ? JSON.stringify(opts.body) : undefined });
    jarB.absorb(res);
    const text = await res.text();
    let json = null;
    try { json = text ? JSON.parse(text) : null; } catch { /* ignore */ }
    return { status: res.status, json };
  };
  r = await callB('POST', '/api/auth/register', { body: { email: 'second@aurora.dev', password: 'Aurora2026!' } });
  eq('第二个用户为 member', [r.status, r.json?.user?.role], [201, 'member']);
  const tokenB = r.json.access;

  r = await callB('GET', '/api/notes', { token: tokenB });
  eq('B 看不到 A 的条目', [r.status, r.json?.notes?.length], [200, 0]);

  r = await callB('PATCH', `/api/notes/${note.id}`, { token: tokenB, body: { title: '劫持' } });
  eq('B 改 A 的条目 404', r.status, 404);

  r = await callB('DELETE', `/api/notes/${note.id}`, { token: tokenB });
  eq('B 删 A 的条目 404', r.status, 404);

  /* 刷新令牌旋转 */
  const rtOld = jar.cookies.get('aurora_rt');
  r = await call('POST', '/api/auth/refresh', { cookie: `aurora_rt=${rtOld}` });
  eq('刷新 200', r.status, 200);
  truthy('拿到新 access', typeof r.json?.access === 'string');
  const rtNew = jar.cookies.get('aurora_rt');
  truthy('刷新令牌已旋转', rtOld !== rtNew);

  r = await call('POST', '/api/auth/refresh', { cookie: `aurora_rt=${rtOld}` });
  eq('旧令牌复用被拒 401', r.status, 401);

  r = await call('POST', '/api/auth/refresh', { cookie: `aurora_rt=${rtNew}` });
  eq('复用检测已注销全部会话 401', r.status, 401);

  /* 登出 */
  r = await call('POST', '/api/auth/login', { body: { email: 'owner@aurora.dev', password: 'Aurora2026!' } });
  const rt3 = jar.cookies.get('aurora_rt');
  r = await call('POST', '/api/auth/logout', { cookie: `aurora_rt=${rt3}` });
  eq('登出 200', [r.status, r.json?.ok], [200, true]);
  r = await call('POST', '/api/auth/refresh', { cookie: `aurora_rt=${rt3}` });
  eq('登出后刷新失败 401', r.status, 401);

  /* 登录限流 */
  let limited = 0;
  for (let i = 0; i < 10; i += 1) {
    const rr = await call('POST', '/api/auth/login', { body: { email: 'limit@aurora.dev', password: 'WrongPass1' } });
    if (rr.status === 429) limited += 1;
  }
  truthy('登录爆破触发 429', limited > 0);

  /* 安全响应头 */
  r = await call('GET', '/api/version');
  truthy('带 CSP', (r.headers.get('content-security-policy') || '').includes("default-src 'self'"));
  eq('禁止 MIME 嗅探', r.headers.get('x-content-type-options'), 'nosniff');
  eq('禁止被嵌套', r.headers.get('x-frame-options'), 'DENY');
  eq('无 hsts（明文）', r.headers.get('strict-transport-security'), null);

  await new Promise((resolve) => server.close(resolve));

  console.log(`\n  ${pass} 通过, ${failures.length} 失败\n`);
  if (failures.length) {
    for (const f of failures) console.log(`  FAIL ${f}`);
    process.exitCode = 1;
  }
  cleanup();
}

function cleanup() {
  try {
    const { db } = dbModule ?? {};
    if (db) {
      db.exec('PRAGMA wal_checkpoint(TRUNCATE)');
      db.close();
    }
  } catch { /* 已关闭 */ }
  for (let i = 0; i < 5; i += 1) {
    try {
      fs.rmSync(TMP, { recursive: true, force: true });
      return;
    } catch {
      // Windows 上 SQLite 句柄释放有延迟，重试即可
    }
  }
}

let dbModule = null;

main().catch((e) => {
  console.error('冒烟异常：', e);
  process.exit(1);
});
