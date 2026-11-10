// server/auth.js — scrypt 口令、HS256 JWT、刷新令牌旋转与复用检测
import crypto from 'node:crypto';
import { promisify } from 'node:util';
import { db, audit } from './db.js';
import { SECURITY } from './config.js';

const scrypt = promisify(crypto.scrypt);
const now = () => Date.now();

/* ── 口令 ────────────────────────────────────────────────── */
export async function hashPassword(pw) {
  const { N, r, p, keylen } = SECURITY.scrypt;
  const salt = crypto.randomBytes(16);
  const dk = await scrypt(pw.normalize('NFKC'), salt, keylen, { N, r, p, maxmem: 64 * 1024 * 1024 });
  return `scrypt$${N}$${r}$${p}$${salt.toString('base64url')}$${dk.toString('base64url')}`;
}

export async function verifyPassword(pw, stored) {
  try {
    const [scheme, N, r, p, saltB64, hashB64] = String(stored).split('$');
    if (scheme !== 'scrypt') return false;
    const salt = Buffer.from(saltB64, 'base64url');
    const expect = Buffer.from(hashB64, 'base64url');
    const dk = await scrypt(pw.normalize('NFKC'), salt, expect.length, {
      N: Number(N), r: Number(r), p: Number(p), maxmem: 64 * 1024 * 1024,
    });
    return crypto.timingSafeEqual(dk, expect);
  } catch {
    return false;
  }
}

/* ── JWT（HS256，手写以便零依赖与完全可控） ───────────────── */
const b64u = (o) => Buffer.from(typeof o === 'string' ? o : JSON.stringify(o)).toString('base64url');

export function signToken(payload, ttl) {
  const header = { alg: 'HS256', typ: 'JWT' };
  const body = { ...payload, iat: Math.floor(now() / 1000), exp: Math.floor(now() / 1000) + ttl };
  const data = `${b64u(header)}.${b64u(body)}`;
  const sig = crypto.createHmac('sha256', SECURITY.secret).update(data).digest('base64url');
  return `${data}.${sig}`;
}

export function verifyToken(token) {
  if (typeof token !== 'string') return null;
  const parts = token.split('.');
  if (parts.length !== 3) return null;
  const [h, b, s] = parts;
  const expect = crypto.createHmac('sha256', SECURITY.secret).update(`${h}.${b}`).digest('base64url');
  const a = Buffer.from(s);
  const e = Buffer.from(expect);
  if (a.length !== e.length || !crypto.timingSafeEqual(a, e)) return null;
  let body;
  try { body = JSON.parse(Buffer.from(b, 'base64url').toString('utf8')); } catch { return null; }
  if (!body || typeof body !== 'object') return null;
  if (typeof body.exp !== 'number' || body.exp * 1000 <= now()) return null;
  return body;
}

/* ── 刷新令牌（不透明随机串，仅存哈希） ───────────────────── */
const sha = (s) => crypto.createHash('sha256').update(s).digest('hex');

export function issueRefresh(userId, ip, ua, replaces = null) {
  const raw = crypto.randomBytes(40).toString('base64url');
  const id = crypto.randomUUID();
  const exp = now() + SECURITY.refreshTtl * 1000;
  db.prepare('INSERT INTO refresh_tokens(id,user_id,token_hash,expires_at,ip,ua,created_at) VALUES (?,?,?,?,?,?,?)')
    .run(id, userId, sha(raw), exp, ip ?? null, (ua || '').slice(0, 200), now());
  if (replaces) {
    db.prepare('UPDATE refresh_tokens SET revoked_at = ?, replaced_by = ? WHERE id = ?')
      .run(now(), id, replaces);
  }
  return { raw, id, exp };
}

export function rotateRefresh(rawToken, ip, ua) {
  if (!rawToken) return { ok: false, reason: 'missing' };
  const row = db.prepare('SELECT * FROM refresh_tokens WHERE token_hash = ?').get(sha(rawToken));
  if (!row) return { ok: false, reason: 'unknown' };
  if (row.revoked_at) {
    // 复用检测：已旋转的令牌被再次使用 → 视为泄露，注销该用户全部会话
    db.prepare('UPDATE refresh_tokens SET revoked_at = ? WHERE user_id = ? AND revoked_at IS NULL')
      .run(now(), row.user_id);
    audit(row.user_id, 'refresh.reuse_detected', ip, { tokenId: row.id });
    return { ok: false, reason: 'reuse' };
  }
  if (row.expires_at <= now()) return { ok: false, reason: 'expired' };
  const next = issueRefresh(row.user_id, ip, ua, row.id);
  return { ok: true, userId: row.user_id, token: next };
}

export function revokeRefresh(rawToken) {
  if (!rawToken) return;
  db.prepare('UPDATE refresh_tokens SET revoked_at = ? WHERE token_hash = ? AND revoked_at IS NULL')
    .run(now(), sha(rawToken));
}

/* ── 鉴权中间件 ──────────────────────────────────────────── */
export function authenticate(req) {
  const h = req.headers['authorization'] || '';
  const m = /^Bearer\s+(.+)$/i.exec(h);
  if (!m) return null;
  const claims = verifyToken(m[1]);
  if (!claims || claims.typ !== 'access') return null;
  const user = db.prepare('SELECT id, email, role, created_at FROM users WHERE id = ?').get(claims.sub);
  if (!user) return null;
  return user;
}
