// server/config.js — 运行期配置与密钥管理（零第三方依赖）
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';

export const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

const pkg = JSON.parse(fs.readFileSync(path.join(ROOT, 'package.json'), 'utf8'));

export const APP = {
  name: 'Aurora Console',
  version: pkg.version,
  build: process.env.AURORA_BUILD || detectBuild(),
};

function detectBuild() {
  try {
    const head = fs.readFileSync(path.join(ROOT, 'tools', '.build'), 'utf8').trim();
    if (head) return head;
  } catch { /* 无 build 标记时退化到时间戳日期 */ }
  const d = new Date();
  const p = (n) => String(n).padStart(2, '0');
  return `dev.${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}`;
}

export const DATA_DIR = process.env.AURORA_DATA
  ? path.resolve(process.env.AURORA_DATA)
  : path.join(ROOT, 'data');

fs.mkdirSync(DATA_DIR, { recursive: true, mode: 0o700 });

export const DB_PATH = path.join(DATA_DIR, 'aurora.db');

export const HTTP = {
  port: Number(process.env.PORT || 8787),
  host: process.env.HOST || '0.0.0.0',
  // 反向代理（Nginx/Caddy）之后置为 1，用于取真实客户端 IP 与 HSTS
  trustProxy: process.env.AURORA_TRUST_PROXY === '1',
  bodyLimit: 96 * 1024,
};

export const SECURITY = {
  // 生产环境务必写成强口令；未提供则在 data/.secret 内自动生成并 600 落盘
  secret: loadSecret(),
  accessTtl: 15 * 60,          // 访问令牌 15 分钟
  refreshTtl: 30 * 24 * 3600,  // 刷新令牌 30 天（旋转 + 复用检测）
  cookieName: 'aurora_rt',
  cookieSecure: process.env.AURORA_COOKIE_SECURE === '1' || HTTP.trustProxy,
  allowRegister: process.env.AURORA_ALLOW_REGISTER !== '0',
  maxUsers: Number(process.env.AURORA_MAX_USERS || 8),
  scrypt: { N: 16384, r: 8, p: 1, keylen: 64 },
};

function loadSecret() {
  if (process.env.AURORA_SECRET && process.env.AURORA_SECRET.length >= 32) {
    return Buffer.from(process.env.AURORA_SECRET, 'utf8');
  }
  const file = path.join(DATA_DIR, '.secret');
  try {
    const raw = fs.readFileSync(file);
    if (raw.length >= 32) return raw;
  } catch { /* 首次启动 */ }
  const fresh = crypto.randomBytes(48);
  fs.writeFileSync(file, fresh, { mode: 0o600 });
  return fresh;
}

export const LIMITS = {
  login: { window: 300, max: 8 },      // 每 IP+账号 5 分钟 8 次
  register: { window: 3600, max: 12 }, // 每 IP 每小时 12 次（用户数另有硬上限）
  refresh: { window: 300, max: 60 },
  api: { window: 60, max: 240 },       // 常规接口每 IP 每分钟 240 次
  burst: { window: 10, max: 40 },      // 突发保护
};
