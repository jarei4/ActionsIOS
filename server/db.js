// server/db.js — SQLite 存储层 + 版本化迁移（可回放、可审计）
import { DatabaseSync } from 'node:sqlite';
import { DB_PATH } from './config.js';

export const db = new DatabaseSync(DB_PATH);

db.exec(`
  PRAGMA journal_mode = WAL;
  PRAGMA synchronous = FULL;
  PRAGMA foreign_keys = ON;
  PRAGMA busy_timeout = 5000;
  PRAGMA trusted_schema = OFF;
`);

/**
 * 迁移表：每条迁移只执行一次，记录版本号 + 校验和。
 * 新增迁移时只能追加，不能修改历史条目（保证任何一台机器回放结果一致）。
 */
const MIGRATIONS = [
  {
    version: 1,
    name: 'core-schema',
    sql: `
      CREATE TABLE users (
        id           TEXT PRIMARY KEY,
        email        TEXT NOT NULL UNIQUE,
        password     TEXT NOT NULL,
        role         TEXT NOT NULL DEFAULT 'owner',
        created_at   INTEGER NOT NULL,
        last_login   INTEGER
      );

      CREATE TABLE refresh_tokens (
        id          TEXT PRIMARY KEY,
        user_id     TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        token_hash  TEXT NOT NULL UNIQUE,
        expires_at  INTEGER NOT NULL,
        revoked_at  INTEGER,
        replaced_by TEXT,
        ip          TEXT,
        ua          TEXT,
        created_at  INTEGER NOT NULL
      );
      CREATE INDEX idx_rt_user ON refresh_tokens(user_id);

      CREATE TABLE notes (
        id          TEXT PRIMARY KEY,
        user_id     TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        title       TEXT NOT NULL,
        body        TEXT NOT NULL DEFAULT '',
        status      TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open','done')),
        priority    INTEGER NOT NULL DEFAULT 1 CHECK (priority BETWEEN 0 AND 2),
        due_at      INTEGER,
        tags        TEXT NOT NULL DEFAULT '',
        rev         INTEGER NOT NULL DEFAULT 1,
        created_at  INTEGER NOT NULL,
        updated_at  INTEGER NOT NULL
      );
      CREATE INDEX idx_notes_user ON notes(user_id, status);

      CREATE TABLE audit_log (
        id      INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id TEXT,
        action  TEXT NOT NULL,
        ip      TEXT,
        at      INTEGER NOT NULL,
        meta    TEXT
      );
    `,
  },
  {
    version: 2,
    name: 'note-pin-and-archive',
    sql: `
      ALTER TABLE notes ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0;
      ALTER TABLE notes ADD COLUMN archived_at INTEGER;
      CREATE INDEX idx_notes_pin ON notes(user_id, pinned DESC, updated_at DESC);
    `,
  },
  {
    version: 3,
    name: 'session-revocation-index',
    sql: `
      CREATE INDEX idx_rt_hash ON refresh_tokens(token_hash, expires_at);
      CREATE TABLE app_meta (
        key   TEXT PRIMARY KEY,
        value TEXT NOT NULL
      );
      INSERT INTO app_meta(key, value) VALUES ('installed_at', CAST(strftime('%s','now') AS TEXT));
    `,
  },
];

export const SCHEMA_VERSION = MIGRATIONS[MIGRATIONS.length - 1].version;

export function migrate() {
  db.exec(`
    CREATE TABLE IF NOT EXISTS schema_migrations (
      version    INTEGER PRIMARY KEY,
      name       TEXT NOT NULL,
      checksum   TEXT NOT NULL,
      applied_at INTEGER NOT NULL
    );
  `);
  const applied = new Map(
    db.prepare('SELECT version, checksum FROM schema_migrations').all().map((r) => [r.version, r.checksum]),
  );
  const out = [];
  for (const m of MIGRATIONS) {
    const sum = checksum(m.sql);
    if (applied.has(m.version)) {
      if (applied.get(m.version) !== sum) {
        throw new Error(`迁移 v${m.version} 校验和不一致：历史迁移不允许被修改`);
      }
      continue;
    }
    db.exec('BEGIN IMMEDIATE');
    try {
      db.exec(m.sql);
      db.prepare('INSERT INTO schema_migrations(version, name, checksum, applied_at) VALUES (?,?,?,?)')
        .run(m.version, m.name, sum, Date.now());
      db.exec('COMMIT');
      out.push(m.version);
    } catch (e) {
      db.exec('ROLLBACK');
      throw e;
    }
  }
  return { schema: SCHEMA_VERSION, applied: out };
}

function checksum(s) {
  // 稳定校验：折叠空白，避免编辑器换行差异导致误报
  let h = 0x811c9dc5;
  const norm = s.replace(/\s+/g, ' ').trim();
  for (let i = 0; i < norm.length; i++) {
    h ^= norm.charCodeAt(i);
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return h.toString(16).padStart(8, '0');
}

export function audit(userId, action, ip, meta) {
  try {
    db.prepare('INSERT INTO audit_log(user_id, action, ip, at, meta) VALUES (?,?,?,?,?)')
      .run(userId ?? null, action, ip ?? null, Date.now(), meta ? JSON.stringify(meta) : null);
  } catch { /* 审计失败不阻断主链路 */ }
}

export function pruneExpired() {
  const now = Date.now();
  db.prepare('DELETE FROM refresh_tokens WHERE expires_at < ? OR revoked_at IS NOT NULL').run(now - 7 * 864e5);
}
