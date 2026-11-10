// tools/test-web.mjs — 前端契约测试：静态资源、安全头、以及浏览器会走的完整 API 流程
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'aurora-web-'));
process.env.AURORA_DATA = TMP;
process.env.PORT = '0';
process.env.HOST = '127.0.0.1';
process.env.AURORA_QUIET = '1';
process.env.AURORA_SECRET = 'y'.repeat(48);
process.env.AURORA_MAX_USERS = '4';

let pass = 0;
const failures = [];
const ok = (name) => { pass++; console.log(`  \u2713 ${name}`); };
const bad = (name, detail) => { failures.push(`${name} — ${detail}`); console.log(`  \u2717 ${name}  ${detail}`); };
const eq = (name, a, b) => (JSON.stringify(a) === JSON.stringify(b) ? ok(name) : bad(name, `期望 ${JSON.stringify(b)}，实际 ${JSON.stringify(a)}`));
const truthy = (name, v) => (v ? ok(name) : bad(name, '期望为真'));

async function main() {
  const { start } = await import('../server/index.js');
  const { server, port } = await start();
  const base = `http://127.0.0.1:${port}`;

  console.log(`\n前端契约测试  ${base}\n`);

  /* ── 静态资源 ── */
  let res = await fetch(`${base}/`);
  let html = await res.text();
  eq('首页 200', res.status, 200);
  truthy('首页是 HTML', (res.headers.get('content-type') || '').includes('text/html'));
  eq('首页不缓存', res.headers.get('cache-control'), 'no-store');
  truthy('首页带 CSP', (res.headers.get('content-security-policy') || '').includes("default-src 'self'"));
  truthy('首页含登录区', html.includes('id="auth-form"'));
  truthy('首页含主控台', html.includes('id="board"'));
  truthy('首页无内联脚本（CSP 强约束）', !/<script(?![^>]*src=)[^>]*>/.test(html));
  truthy('首页无内联事件处理器', !/\son[a-z]+\s*=/i.test(html));

  res = await fetch(`${base}/assets/console.css`);
  eq('样式 200', res.status, 200);
  truthy('样式 Content-Type', (res.headers.get('content-type') || '').includes('text/css'));

  res = await fetch(`${base}/assets/console.js`);
  eq('脚本 200', res.status, 200);
  truthy('脚本 Content-Type', (res.headers.get('content-type') || '').includes('javascript'));
  truthy('脚本被 ETag 标记', Boolean(res.headers.get('etag')));

  res = await fetch(`${base}/icons/icon-512.png`);
  eq('图标 200', res.status, 200);
  truthy('图标是 PNG', (res.headers.get('content-type') || '').includes('image/png'));

  res = await fetch(`${base}/manifest.webmanifest`);
  eq('清单 200', res.status, 200);

  // 无扩展名路径回退到 SPA
  res = await fetch(`${base}/notes`);
  eq('SPA 回退到 index.html', [res.status, (res.headers.get('content-type') || '').includes('text/html')], [200, true]);

  // 目录穿越必须被挡住
  res = await fetch(`${base}/../server/config.js`);
  truthy('路径穿越被挡住', res.status === 404 || res.status === 400 || res.status === 403);

  /* ── 浏览器视角的 API 流程（带 Cookie） ── */
  const jar = new Map();
  const absorb = (r) => {
    for (const raw of (typeof r.headers.getSetCookie === 'function' ? r.headers.getSetCookie() : [])) {
      const [pair] = raw.split(';');
      const i = pair.indexOf('=');
      jar.set(pair.slice(0, i).trim(), pair.slice(i + 1).trim());
    }
  };
  const call = async (method, p, body, token) => {
    const headers = { Accept: 'application/json' };
    if (body !== undefined) headers['Content-Type'] = 'application/json';
    if (token) headers.Authorization = `Bearer ${token}`;
    const cookie = [...jar.entries()].map(([k, v]) => `${k}=${v}`).join('; ');
    if (cookie) headers.Cookie = cookie;
    const r = await fetch(base + p, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
    absorb(r);
    const text = await r.text();
    let json = null;
    try { json = text ? JSON.parse(text) : null; } catch { /* ignore */ }
    return { status: r.status, json };
  };

  const version = await call('GET', '/api/version');
  eq('版本接口 200', version.status, 200);
  truthy('版本接口带 channel', typeof version.json.channel === 'string');

  const reg = await call('POST', '/api/auth/register', { email: 'web@aurora.dev', password: 'Aurora2026!' });
  eq('注册 201', reg.status, 201);
  const token = reg.json.access;

  const created = await call('POST', '/api/notes', {
    title: '网页端第一条',
    body: '来自契约测试',
    priority: 2,
    tags: ['测试', '前端'],
    due: Date.now() + 86400000,
  }, token);
  eq('新建条目 201', created.status, 201);
  eq('标签落库', created.json.note.tags, ['测试', '前端']);

  const list = await call('GET', '/api/notes?q=' + encodeURIComponent('网页端'), undefined, token);
  eq('搜索命中', list.json.notes.length, 1);

  const patched = await call('PATCH', `/api/notes/${created.json.note.id}`, { status: 'done', rev: created.json.note.rev }, token);
  eq('状态切换', [patched.status, patched.json.note.status], [200, 'done']);

  const stats = await call('GET', '/api/stats', undefined, token);
  eq('统计同步', [stats.json.total, stats.json.done], [1, 1]);

  const refreshed = await call('POST', '/api/auth/refresh');
  eq('刷新 200（浏览器 Cookie 路径）', refreshed.status, 200);
  truthy('拿到新 access', typeof refreshed.json?.access === 'string');

  const removed = await call('DELETE', `/api/notes/${created.json.note.id}`, undefined, refreshed.json.access);
  eq('删除 200', [removed.status, removed.json.ok], [200, true]);

  await new Promise((r) => server.close(r));
  try {
    const { db } = await import('../server/db.js');
    db.exec('PRAGMA wal_checkpoint(TRUNCATE)');
    db.close();
  } catch { /* 已关闭 */ }
  for (let i = 0; i < 5; i++) {
    try { fs.rmSync(TMP, { recursive: true, force: true }); break; } catch { /* Windows 句柄延迟 */ }
  }

  console.log(`\n  ${pass} 通过, ${failures.length} 失败\n`);
  if (failures.length) {
    for (const f of failures) console.log(`  FAIL ${f}`);
    process.exitCode = 1;
  }
}

main().catch((e) => { console.error('契约测试异常：', e); process.exit(1); });
