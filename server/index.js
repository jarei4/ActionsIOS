// server/index.js — HTTP/HTTPS 入口：API + 静态控制台 + 优雅退出
import http from 'node:http';
import https from 'node:https';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { pathToFileURL } from 'node:url';

import { APP, ROOT, HTTP, DATA_DIR, DB_PATH, SECURITY } from './config.js';
import { migrate, pruneExpired, SCHEMA_VERSION, audit } from './db.js';
import { handleApi } from './routes.js';
import { securityHeaders } from './security.js';

const PUBLIC_DIR = path.join(ROOT, 'public');

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.webp': 'image/webp',
  '.ico': 'image/x-icon',
  '.woff2': 'font/woff2',
  '.txt': 'text/plain; charset=utf-8',
  '.webmanifest': 'application/manifest+json',
};

function clientIp(req) {
  if (HTTP.trustProxy) {
    const xff = String(req.headers['x-forwarded-for'] || '').split(',')[0].trim();
    if (xff) return xff;
  }
  const raw = req.socket.remoteAddress || '';
  return raw.startsWith('::ffff:') ? raw.slice(7) : raw;
}

function log(...args) {
  const t = new Date().toISOString().slice(11, 19);
  console.log(`[${t}]`, ...args);
}

/* ── 静态资源（防穿越 + ETag + 分类型缓存） ───────────────── */
async function serveStatic(req, res, url) {
  if (req.method !== 'GET' && req.method !== 'HEAD') {
    res.writeHead(405, { Allow: 'GET, HEAD' });
    return res.end();
  }

  let rel = decodeURIComponent(url.pathname);
  if (rel === '/' || rel === '') rel = '/index.html';

  const candidates = [rel];
  // 无扩展名的路径按 SPA 处理，回退到 index.html
  if (!path.extname(rel)) candidates.push('/index.html');

  for (const cand of candidates) {
    const target = path.resolve(PUBLIC_DIR, '.' + cand);
    if (target !== PUBLIC_DIR && !target.startsWith(PUBLIC_DIR + path.sep)) {
      res.writeHead(403, { 'Content-Type': 'text/plain; charset=utf-8' });
      return res.end('403');
    }
    let stat;
    try {
      stat = await fsp.stat(target);
      if (!stat.isFile()) continue;
    } catch {
      continue;
    }

    const ext = path.extname(target).toLowerCase();
    const etag = `W/"${stat.size.toString(16)}-${Math.floor(stat.mtimeMs).toString(16)}"`;
    const headers = {
      'Content-Type': MIME[ext] || 'application/octet-stream',
      'Content-Length': stat.size,
      ETag: etag,
      'X-Content-Type-Options': 'nosniff',
      'Referrer-Policy': 'no-referrer',
      'X-Frame-Options': 'DENY',
      'Last-Modified': stat.mtime.toUTCString(),
      'Cache-Control': ext === '.html' ? 'no-store' : 'public, max-age=300, must-revalidate',
    };
    if (req.headers['if-none-match'] === etag) {
      res.writeHead(304, { ETag: etag });
      return res.end();
    }
    securityHeaders(res, { https: Boolean(req.socket.encrypted) });
    res.writeHead(200, headers);
    if (req.method === 'HEAD') return res.end();
    return fs.createReadStream(target).pipe(res);
  }

  securityHeaders(res, { https: Boolean(req.socket.encrypted) });
  res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
  res.end('404');
}

/* ── 请求分发 ───────────────────────────────────────────── */
function createHandler() {
  const startedAt = Date.now();

  return async function handler(req, res) {
    const ip = clientIp(req);
    let url;
    try {
      url = new URL(req.url || '/', `http://${req.headers.host || 'localhost'}`);
    } catch {
      res.writeHead(400, { 'Content-Type': 'text/plain' });
      return res.end('bad request');
    }

    if (req.method === 'OPTIONS') {
      res.writeHead(204, {
        Allow: 'GET, HEAD, POST, PATCH, PUT, DELETE, OPTIONS',
        'Access-Control-Allow-Headers': 'Content-Type, Authorization',
        'Access-Control-Allow-Methods': 'GET, POST, PATCH, PUT, DELETE',
        'Access-Control-Max-Age': '600',
      });
      return res.end();
    }

    const t0 = process.hrtime.bigint();
    res.on('finish', () => {
      const ms = Number(process.hrtime.bigint() - t0) / 1e6;
      if (!process.env.AURORA_QUIET) {
        log(`${req.method} ${url.pathname} → ${res.statusCode} ${ms.toFixed(1)}ms ${ip}`);
      }
    });

    try {
      if (url.pathname === '/api' || url.pathname.startsWith('/api/')) {
        await handleApi(req, res, url, {
          ip,
          https: Boolean(req.socket.encrypted),
          bodyLimit: HTTP.bodyLimit,
          startedAt,
        });
        return;
      }
      await serveStatic(req, res, url);
    } catch (err) {
      const status = Number(err?.status) || 500;
      if (status >= 500) console.error('[error]', err);
      if (res.headersSent) return res.end();
      const body = JSON.stringify({
        error: status >= 500 ? '服务器内部错误' : err.message,
        code: err?.code || (status >= 500 ? 'internal' : 'bad_request'),
      });
      securityHeaders(res, { https: Boolean(req.socket.encrypted) });
      res.writeHead(status, {
        'Content-Type': 'application/json; charset=utf-8',
        'Content-Length': Buffer.byteLength(body),
        'Cache-Control': 'no-store',
      });
      res.end(body);
    }
  };
}

/* ── 启动 ───────────────────────────────────────────────── */
export function createServer({ tls } = {}) {
  const handler = createHandler();
  const server = tls ? https.createServer(tls, handler) : http.createServer(handler);

  server.keepAliveTimeout = 65_000;
  server.headersTimeout = 70_000;
  server.requestTimeout = 30_000;
  server.maxHeadersCount = 100;
  return server;
}

const VIRTUAL_NIC = /vmware|virtualbox|vethernet|hyper-v|loopback|docker|br-|utun|tap|tun|zerotier|tailscale/i;

function lanAddresses() {
  const real = [];
  const virtual = [];
  for (const [name, list] of Object.entries(os.networkInterfaces())) {
    for (const n of list || []) {
      if (n.family !== 'IPv4' || n.internal) continue;
      (VIRTUAL_NIC.test(name) ? virtual : real).push({ name, address: n.address });
    }
  }
  return [...real, ...virtual];
}

export async function start() {
  const migration = migrate();
  pruneExpired();
  const pruner = setInterval(pruneExpired, 30 * 60_000);
  pruner.unref();

  let tls = null;
  const certPath = process.env.AURORA_TLS_CERT;
  const keyPath = process.env.AURORA_TLS_KEY;
  if (certPath && keyPath) {
    try {
      tls = { cert: fs.readFileSync(certPath), key: fs.readFileSync(keyPath) };
    } catch (e) {
      console.error('[tls] 证书读取失败，退回 HTTP：', e.message);
    }
  }

  const server = createServer({ tls });
  const scheme = tls ? 'https' : 'http';

  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(HTTP.port, HTTP.host, resolve);
  });

  const port = server.address().port;
  const banner = [
    '',
    `  ${APP.name}  v${APP.version} (${APP.build})`,
    `  schema v${SCHEMA_VERSION} · 迁移 ${migration.applied.length ? '+' + migration.applied.join(',') : '无变更'}`,
    `  监听 ${HTTP.host}:${port}${tls ? '  [TLS]' : ''}`,
    `  数据 ${DB_PATH}`,
    '',
    `  本机    ${scheme}://127.0.0.1:${port}`,
    ...lanAddresses().map((n, i) => `  ${i === 0 ? '局域网' : '      '}  ${scheme}://${n.address}:${port}  (${n.name})${i === 0 ? '  ← 手机填这个' : ''}`),
    '',
    `  注册用户上限 ${SECURITY.maxUsers} · 注册${SECURITY.allowRegister ? '开放' : '关闭'}`,
    `  口令强度：scrypt N=${SECURITY.scrypt.N} r=${SECURITY.scrypt.r} p=${SECURITY.scrypt.p}`,
    '',
  ].join('\n');
  console.log(banner);

  audit(null, 'server.start', null, { port, tls: Boolean(tls), version: APP.version });

  let closing = false;
  const shutdown = async (sig) => {
    if (closing) return;
    closing = true;
    log(`收到 ${sig}，正在关闭…`);
    clearInterval(pruner);
    await new Promise((r) => server.close(r));
    try {
      const { db } = await import('./db.js');
      db.exec('PRAGMA wal_checkpoint(TRUNCATE)');
      db.close();
    } catch { /* 已关闭 */ }
    log('已安全退出');
    process.exit(0);
  };
  process.on('SIGINT', () => shutdown('SIGINT'));
  process.on('SIGTERM', () => shutdown('SIGTERM'));

  return { server, port, scheme };
}

const isMain = (() => {
  try {
    return process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href;
  } catch {
    return false;
  }
})();

if (isMain) {
  start().catch((e) => {
    console.error('启动失败：', e);
    process.exit(1);
  });
}
