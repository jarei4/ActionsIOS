// server/security.js — 响应头、限流、输入校验、体积上限
import crypto from 'node:crypto';
import { LIMITS } from './config.js';

/* ── 安全响应头 ───────────────────────────────────────────── */
export function securityHeaders(res, { https }) {
  const csp = [
    "default-src 'self'",
    "script-src 'self'",
    "style-src 'self'",
    "img-src 'self' data:",
    "font-src 'self'",
    "connect-src 'self'",
    "manifest-src 'self'",
    "frame-ancestors 'none'",
    "base-uri 'none'",
    "form-action 'self'",
    "object-src 'none'",
  ].join('; ');
  const h = {
    'Content-Security-Policy': csp,
    'X-Content-Type-Options': 'nosniff',
    'X-Frame-Options': 'DENY',
    'Referrer-Policy': 'no-referrer',
    'Permissions-Policy': 'geolocation=(), microphone=(), camera=(), payment=()',
    'Cross-Origin-Opener-Policy': 'same-origin',
    'Cross-Origin-Resource-Policy': 'same-origin',
    'X-Aurora-Version': 'v1',
  };
  if (https) h['Strict-Transport-Security'] = 'max-age=15552000; includeSubDomains';
  for (const [k, v] of Object.entries(h)) res.setHeader(k, v);
}

/* ── 令牌桶限流（内存版，单实例；多实例请换 Redis 实现） ─────── */
const buckets = new Map();

export function rateLimit(res, key, rule, now = Date.now()) {
  const slot = buckets.get(key);
  if (!slot || slot.reset <= now) {
    buckets.set(key, { count: 1, reset: now + rule.window * 1000 });
    return true;
  }
  slot.count += 1;
  if (slot.count > rule.max) {
    const retry = Math.max(1, Math.ceil((slot.reset - now) / 1000));
    res.setHeader('Retry-After', String(retry));
    return false;
  }
  return true;
}

export function hit(res, ip, route) {
  const okBurst = rateLimit(res, `b:${ip}`, LIMITS.burst);
  const okApi = rateLimit(res, `a:${ip}:${route}`, LIMITS.api);
  return okBurst && okApi;
}

setInterval(() => {
  const now = Date.now();
  for (const [k, v] of buckets) if (v.reset <= now) buckets.delete(k);
}, 60_000).unref();

/* ── 请求体 ──────────────────────────────────────────────── */
export function readJson(req, limit) {
  const HARD_CEILING = limit * 8; // 极端的超大包才断开，保证客户端能收到 413
  return new Promise((resolve, reject) => {
    const type = (req.headers['content-type'] || '').split(';')[0].trim();
    if (type !== 'application/json') {
      reject(Object.assign(new Error('Content-Type 必须为 application/json'), { status: 415 }));
      return;
    }
    let size = 0;
    let overflow = false;
    const chunks = [];
    req.on('data', (c) => {
      size += c.length;
      if (size > HARD_CEILING) {
        // 只在这里断开：已经无法安全排空，宁可重置连接
        reject(Object.assign(new Error('请求体过大'), { status: 413 }));
        req.destroy();
        return;
      }
      if (size > limit) {
        // 超限后继续排空但不缓存：既不占内存，也让对端读得到 413
        overflow = true;
        return;
      }
      chunks.push(c);
    });
    req.on('end', () => {
      if (overflow) {
        reject(Object.assign(new Error('请求体过大'), { status: 413 }));
        return;
      }
      if (!size) return resolve({});
      try {
        const parsed = JSON.parse(Buffer.concat(chunks).toString('utf8'));
        if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
          throw new Error('请求体必须是 JSON 对象');
        }
        resolve(parsed);
      } catch (e) {
        reject(Object.assign(new Error(e.message || 'JSON 解析失败'), { status: 400 }));
      }
    });
    req.on('error', reject);
  });
}

/* ── 校验器 ──────────────────────────────────────────────── */
const EMAIL_RE = /^[A-Za-z0-9._%+-]{1,64}@[A-Za-z0-9.-]{1,190}\.[A-Za-z]{2,24}$/;

export class ValidationError extends Error {
  constructor(msg) { super(msg); this.status = 422; }
}

export function vEmail(v) {
  if (typeof v !== 'string') throw new ValidationError('邮箱格式不正确');
  const s = v.trim().toLowerCase();
  if (s.length > 254 || !EMAIL_RE.test(s)) throw new ValidationError('邮箱格式不正确');
  return s;
}

export function vPassword(v) {
  if (typeof v !== 'string') throw new ValidationError('密码格式不正确');
  if (v.length < 8 || v.length > 128) throw new ValidationError('密码需 8–128 位');
  const kinds = [/[a-z]/, /[A-Z]/, /[0-9]/, /[^A-Za-z0-9]/].filter((r) => r.test(v)).length;
  if (kinds < 2) throw new ValidationError('密码需包含大小写字母/数字/符号中的至少两类');
  return v;
}

export function vText(v, { min = 0, max = 200, field = '字段', trim = true } = {}) {
  if (v === undefined || v === null) v = '';
  if (typeof v !== 'string') throw new ValidationError(`${field}必须是字符串`);
  const s = trim ? v.trim() : v;
  if (s.length < min) throw new ValidationError(`${field}至少 ${min} 个字符`);
  if (s.length > max) throw new ValidationError(`${field}最多 ${max} 个字符`);
  return s;
}

export function vPriority(v) {
  const n = Number(v ?? 1);
  if (![0, 1, 2].includes(n)) throw new ValidationError('优先级取值不合法');
  return n;
}

export function vStatus(v) {
  if (v === undefined) return undefined;
  if (!['open', 'done'].includes(v)) throw new ValidationError('状态取值不合法');
  return v;
}

export function vDue(v) {
  if (v === undefined || v === null || v === '') return null;
  const n = typeof v === 'number' ? v : Date.parse(String(v));
  if (!Number.isFinite(n)) throw new ValidationError('日期格式不合法');
  const t = Math.trunc(n);
  if (t < 0 || t > Date.now() + 100 * 365 * 864e5) throw new ValidationError('日期超出允许范围');
  return t;
}

export function vId(v) {
  if (typeof v !== 'string' || !/^[0-9a-f-]{36}$/i.test(v)) throw new ValidationError('ID 不合法');
  return v.toLowerCase();
}

export function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

export function timingSafeEq(a, b) {
  const A = Buffer.from(String(a));
  const B = Buffer.from(String(b));
  if (A.length !== B.length) return false;
  return crypto.timingSafeEqual(A, B);
}
