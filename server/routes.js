// server/routes.js — API 路由（全部参数化 SQL，统一错误出口）
import crypto from 'node:crypto';
import { db, audit } from './db.js';
import { APP, SECURITY, LIMITS } from './config.js';
import {
  readJson, rateLimit, hit, securityHeaders,
  vEmail, vPassword, vText, vPriority, vStatus, vDue, vId, ValidationError,
} from './security.js';
import {
  hashPassword, verifyPassword, signToken, authenticate,
  issueRefresh, rotateRefresh, revokeRefresh,
} from './auth.js';

const now = () => Date.now();

class HttpError extends Error {
  constructor(status, msg, code) { super(msg); this.status = status; this.code = code; }
}

function send(res, status, body, extra = {}) {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(payload),
    'Cache-Control': 'no-store',
    ...extra,
  });
  res.end(payload);
}

function parseCookies(req) {
  const out = {};
  for (const part of String(req.headers.cookie || '').split(';')) {
    const i = part.indexOf('=');
    if (i < 0) continue;
    out[part.slice(0, i).trim()] = decodeURIComponent(part.slice(i + 1).trim());
  }
  return out;
}

function setRefreshCookie(res, raw, maxAge) {
  const bits = [
    `${SECURITY.cookieName}=${encodeURIComponent(raw)}`,
    'HttpOnly',
    'SameSite=Lax',
    'Path=/api/auth',
    `Max-Age=${maxAge}`,
  ];
  if (SECURITY.cookieSecure) bits.push('Secure');
  res.setHeader('Set-Cookie', bits.join('; '));
}

function clearRefreshCookie(res) {
  const bits = [`${SECURITY.cookieName}=`, 'HttpOnly', 'SameSite=Lax', 'Path=/api/auth', 'Max-Age=0'];
  if (SECURITY.cookieSecure) bits.push('Secure');
  res.setHeader('Set-Cookie', bits.join('; '));
}

function publicUser(u) {
  return { id: u.id, email: u.email, role: u.role, createdAt: u.created_at ?? u.createdAt };
}

function requireUser(req) {
  const user = authenticate(req);
  if (!user) throw new HttpError(401, '登录状态已失效，请重新登录', 'unauthorized');
  return user;
}

/* ── 路由表 ─────────────────────────────────────────────── */
export async function handleApi(req, res, url, ctx) {
  const { ip, https } = ctx;
  securityHeaders(res, { https });
  const path = url.pathname;
  const method = req.method.toUpperCase();
  const route = `${method} ${path.replace(/\/[0-9a-f-]{36}$/i, '/:id')}`;

  if (method !== 'GET' && method !== 'HEAD' && !hit(res, ip, route)) {
    throw new HttpError(429, '请求过于频繁，请稍后再试', 'rate_limited');
  }

  /* 元信息 */
  if (method === 'GET' && path === '/api/version') {
    return send(res, 200, {
      name: APP.name,
      version: APP.version,
      build: APP.build,
      channel: process.env.AURORA_CHANNEL || 'stable',
      node: process.version,
      startedAt: ctx.startedAt,
      uptimeSec: Math.floor((now() - ctx.startedAt) / 1000),
    });
  }

  if (method === 'GET' && path === '/api/health') {
    const ok = db.prepare('SELECT 1 AS ok').get()?.ok === 1;
    return send(res, ok ? 200 : 503, { ok, db: ok ? 'up' : 'down', t: now() });
  }

  /* 注册 */
  if (method === 'POST' && path === '/api/auth/register') {
    if (!SECURITY.allowRegister) throw new HttpError(403, '当前已关闭注册', 'register_closed');
    if (!rateLimit(res, `reg:${ip}`, LIMITS.register)) {
      throw new HttpError(429, '注册过于频繁，请稍后再试', 'rate_limited');
    }
    const body = await readJson(req, ctx.bodyLimit);
    const email = vEmail(body.email);
    const password = vPassword(body.password);
    const count = db.prepare('SELECT COUNT(*) AS c FROM users').get().c;
    if (count >= SECURITY.maxUsers) throw new HttpError(403, '用户数已达上限', 'user_cap');
    if (db.prepare('SELECT id FROM users WHERE email = ?').get(email)) {
      throw new HttpError(409, '该邮箱已注册', 'email_taken');
    }
    const id = crypto.randomUUID();
    db.prepare('INSERT INTO users(id,email,password,role,created_at) VALUES (?,?,?,?,?)')
      .run(id, email, await hashPassword(password), count === 0 ? 'owner' : 'member', now());
    audit(id, 'user.register', ip, { email });
    const user = db.prepare('SELECT * FROM users WHERE id = ?').get(id);
    const access = signToken({ sub: id, typ: 'access', role: user.role }, SECURITY.accessTtl);
    const rt = issueRefresh(id, ip, req.headers['user-agent']);
    setRefreshCookie(res, rt.raw, SECURITY.refreshTtl);
    return send(res, 201, { access, expiresIn: SECURITY.accessTtl, user: publicUser(user) });
  }

  /* 登录 */
  if (method === 'POST' && path === '/api/auth/login') {
    const body = await readJson(req, ctx.bodyLimit);
    const email = vEmail(body.email);
    const password = String(body.password ?? '');
    if (!rateLimit(res, `login:${ip}:${email}`, LIMITS.login)) {
      audit(null, 'login.rate_limited', ip, { email });
      throw new HttpError(429, '尝试次数过多，请 5 分钟后再试', 'rate_limited');
    }
    const user = db.prepare('SELECT * FROM users WHERE email = ?').get(email);
    const ok = user ? await verifyPassword(password, user.password) : await verifyPassword(password, DUMMY_HASH);
    if (!user || !ok) {
      audit(user?.id ?? null, 'login.failed', ip, { email });
      throw new HttpError(401, '邮箱或密码不正确', 'bad_credentials');
    }
    db.prepare('UPDATE users SET last_login = ? WHERE id = ?').run(now(), user.id);
    audit(user.id, 'login.ok', ip, {});
    const access = signToken({ sub: user.id, typ: 'access', role: user.role }, SECURITY.accessTtl);
    const rt = issueRefresh(user.id, ip, req.headers['user-agent']);
    setRefreshCookie(res, rt.raw, SECURITY.refreshTtl);
    return send(res, 200, { access, expiresIn: SECURITY.accessTtl, user: publicUser(user) });
  }

  /* 刷新 */
  if (method === 'POST' && path === '/api/auth/refresh') {
    if (!rateLimit(res, `refresh:${ip}`, LIMITS.refresh)) {
      throw new HttpError(429, '请求过于频繁', 'rate_limited');
    }
    const raw = parseCookies(req)[SECURITY.cookieName];
    const r = rotateRefresh(raw, ip, req.headers['user-agent']);
    if (!r.ok) {
      clearRefreshCookie(res);
      const msg = r.reason === 'reuse' ? '检测到会话异常，已登出全部设备' : '会话已过期，请重新登录';
      throw new HttpError(401, msg, r.reason);
    }
    const user = db.prepare('SELECT * FROM users WHERE id = ?').get(r.userId);
    if (!user) throw new HttpError(401, '账号不存在', 'unauthorized');
    setRefreshCookie(res, r.token.raw, SECURITY.refreshTtl);
    const access = signToken({ sub: user.id, typ: 'access', role: user.role }, SECURITY.accessTtl);
    return send(res, 200, { access, expiresIn: SECURITY.accessTtl, user: publicUser(user) });
  }

  /* 登出 */
  if (method === 'POST' && path === '/api/auth/logout') {
    const raw = parseCookies(req)[SECURITY.cookieName];
    revokeRefresh(raw);
    clearRefreshCookie(res);
    return send(res, 200, { ok: true });
  }

  /* 当前用户 */
  if (method === 'GET' && path === '/api/me') {
    const user = requireUser(req);
    return send(res, 200, { user: publicUser(user) });
  }

  /* 统计 */
  if (method === 'GET' && path === '/api/stats') {
    const user = requireUser(req);
    const row = db.prepare(`
      SELECT
        COUNT(*) AS total,
        SUM(CASE WHEN status='done' THEN 1 ELSE 0 END) AS done,
        SUM(CASE WHEN status='open' THEN 1 ELSE 0 END) AS open,
        SUM(CASE WHEN status='open' AND priority=2 THEN 1 ELSE 0 END) AS urgent,
        SUM(CASE WHEN status='open' AND due_at IS NOT NULL AND due_at < ? THEN 1 ELSE 0 END) AS overdue
      FROM notes WHERE user_id = ? AND archived_at IS NULL
    `).get(now(), user.id);
    return send(res, 200, {
      total: row.total ?? 0, done: row.done ?? 0, open: row.open ?? 0,
      urgent: row.urgent ?? 0, overdue: row.overdue ?? 0,
    });
  }

  /* 列表 */
  if (method === 'GET' && path === '/api/notes') {
    const user = requireUser(req);
    const q = (url.searchParams.get('q') || '').trim().slice(0, 80);
    const status = url.searchParams.get('status');
    const where = ['user_id = ?', 'archived_at IS NULL'];
    const args = [user.id];
    if (status && ['open', 'done'].includes(status)) { where.push('status = ?'); args.push(status); }
    if (q) {
      where.push('(title LIKE ? OR body LIKE ? OR tags LIKE ?)');
      const like = `%${q.replace(/[%_]/g, (m) => '\\' + m)}%`;
      args.push(like, like, like);
    }
    const rows = db.prepare(`
      SELECT * FROM notes WHERE ${where.join(' AND ')}
      ORDER BY pinned DESC, CASE status WHEN 'open' THEN 0 ELSE 1 END,
               priority DESC, COALESCE(due_at, 9e15) ASC, updated_at DESC
      LIMIT 300
    `).all(...args);
    return send(res, 200, { notes: rows.map(noteOut) });
  }

  /* 新建 */
  if (method === 'POST' && path === '/api/notes') {
    const user = requireUser(req);
    const body = await readJson(req, ctx.bodyLimit);
    const id = crypto.randomUUID();
    const t = now();
    const n = {
      id,
      title: vText(body.title, { min: 1, max: 120, field: '标题' }),
      body: vText(body.body, { max: 4000, field: '正文', trim: false }),
      status: vStatus(body.status) ?? 'open',
      priority: vPriority(body.priority),
      due: vDue(body.due),
      tags: normalizeTags(body.tags),
      pinned: body.pinned ? 1 : 0,
    };
    db.prepare(`INSERT INTO notes(id,user_id,title,body,status,priority,due_at,tags,pinned,rev,created_at,updated_at)
                VALUES (?,?,?,?,?,?,?,?,?,1,?,?)`)
      .run(n.id, user.id, n.title, n.body, n.status, n.priority, n.due, n.tags, n.pinned, t, t);
    const row = db.prepare('SELECT * FROM notes WHERE id = ?').get(id);
    return send(res, 201, { note: noteOut(row) });
  }

  /* 更新 / 删除（/:id） */
  const idMatch = /^\/api\/notes\/([0-9a-f-]{36})$/i.exec(path);
  if (idMatch) {
    const user = requireUser(req);
    const id = vId(idMatch[1]);
    const row = db.prepare('SELECT * FROM notes WHERE id = ? AND user_id = ?').get(id, user.id);
    if (!row) throw new HttpError(404, '条目不存在', 'not_found');

    if (method === 'PATCH' || method === 'PUT') {
      const body = await readJson(req, ctx.bodyLimit);
      const sets = [];
      const args = [];
      if (body.title !== undefined) { sets.push('title = ?'); args.push(vText(body.title, { min: 1, max: 120, field: '标题' })); }
      if (body.body !== undefined) { sets.push('body = ?'); args.push(vText(body.body, { max: 4000, field: '正文', trim: false })); }
      if (body.status !== undefined) { sets.push('status = ?'); args.push(vStatus(body.status)); }
      if (body.priority !== undefined) { sets.push('priority = ?'); args.push(vPriority(body.priority)); }
      if (body.due !== undefined) { sets.push('due_at = ?'); args.push(vDue(body.due)); }
      if (body.tags !== undefined) { sets.push('tags = ?'); args.push(normalizeTags(body.tags)); }
      if (body.pinned !== undefined) { sets.push('pinned = ?'); args.push(body.pinned ? 1 : 0); }
      if (!sets.length) throw new HttpError(400, '没有可更新的字段', 'empty_patch');
      // 乐观并发：客户端可带上看到的 rev，服务端 rev 已变则 409
      if (body.rev !== undefined && Number(body.rev) !== row.rev) {
        throw new HttpError(409, '该条目已在其他设备被修改，请刷新后重试', 'conflict');
      }
      sets.push('rev = rev + 1', 'updated_at = ?');
      args.push(now(), id, user.id);
      db.prepare(`UPDATE notes SET ${sets.join(', ')} WHERE id = ? AND user_id = ?`).run(...args);
      const fresh = db.prepare('SELECT * FROM notes WHERE id = ?').get(id);
      return send(res, 200, { note: noteOut(fresh) });
    }

    if (method === 'DELETE') {
      db.prepare('DELETE FROM notes WHERE id = ? AND user_id = ?').run(id, user.id);
      return send(res, 200, { ok: true, id });
    }
  }

  throw new HttpError(404, '接口不存在', 'no_route');
}

/* ── 辅助 ───────────────────────────────────────────────── */
const DUMMY_HASH = await hashPassword(crypto.randomBytes(18).toString('base64'));

function normalizeTags(tags) {
  const arr = Array.isArray(tags)
    ? tags
    : String(tags ?? '').split(/[,，\s]+/);
  const clean = arr
    .map((t) => String(t).trim().replace(/^#/, ''))
    .filter((t) => t.length > 0 && t.length <= 20)
    .slice(0, 4);
  return [...new Set(clean)].join(',');
}

function noteOut(r) {
  return {
    id: r.id,
    title: r.title,
    body: r.body,
    status: r.status,
    priority: r.priority,
    due: r.due_at,
    tags: r.tags ? r.tags.split(',') : [],
    pinned: !!r.pinned,
    rev: r.rev,
    createdAt: r.created_at,
    updatedAt: r.updated_at,
  };
}

export { HttpError, send, ValidationError, publicUser };
