// tools/gen-icons.js — 零依赖生成应用图标（自写 PNG 编码器，输出可复现）
// 用法: node tools/gen-icons.js
import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

/* ── CRC32 ───────────────────────────────────────────────── */
const CRC_TABLE = (() => {
  const table = new Int32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    table[n] = c;
  }
  return table;
})();

function crc32(buf) {
  let c = 0xffffffff;
  for (let i = 0; i < buf.length; i++) c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

function chunk(type, data) {
  const length = Buffer.alloc(4);
  length.writeUInt32BE(data.length, 0);
  const typeBuf = Buffer.from(type, 'ascii');
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(Buffer.concat([typeBuf, data])), 0);
  return Buffer.concat([length, typeBuf, data, crc]);
}

function encodePNG(width, height, rgba) {
  const signature = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8; // bit depth
  ihdr[9] = 6; // RGBA
  ihdr[10] = 0;
  ihdr[11] = 0;
  ihdr[12] = 0;

  const stride = width * 4;
  const raw = Buffer.alloc((stride + 1) * height);
  for (let y = 0; y < height; y++) {
    raw[y * (stride + 1)] = 0; // filter: none
    rgba.copy(raw, y * (stride + 1) + 1, y * stride, y * stride + stride);
  }
  const idat = zlib.deflateSync(raw, { level: 9 });

  return Buffer.concat([
    signature,
    chunk('IHDR', ihdr),
    chunk('IDAT', idat),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}

/* ── 绘制 ────────────────────────────────────────────────── */
const clamp = (v) => (v < 0 ? 0 : v > 1 ? 1 : v);
const smoothstep = (edge0, edge1, x) => {
  const t = clamp((x - edge0) / (edge1 - edge0));
  return t * t * (3 - 2 * t);
};

const VOID = [0x05, 0x06, 0x0b];
const AURORA = [0x6d, 0x5b, 0xff];
const PLASMA = [0xc9, 0x4b, 0xff];
const CYAN = [0x27, 0xe1, 0xf5];

function blob(nx, ny, cx, cy, spread) {
  const dx = nx - cx;
  const dy = ny - cy;
  const d2 = (dx * dx + dy * dy) / (spread * spread);
  return Math.exp(-d2 * 1.9);
}

function render(size) {
  const out = Buffer.alloc(size * size * 4);
  const cx = 0.5;
  const cy = 0.5;

  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      // 像素中心归一化
      const nx = (x + 0.5) / size;
      const ny = (y + 0.5) / size;

      // 极光三团（与 App 内 AuroraBackground 同源配色）
      const a = blob(nx, ny, 0.24, 0.18, 0.42) * 0.82;
      const b = blob(nx, ny, 0.82, 0.32, 0.38) * 0.74;
      const c = blob(nx, ny, 0.50, 0.88, 0.40) * 0.62;

      let r = VOID[0];
      let g = VOID[1];
      let bl = VOID[2];
      r += AURORA[0] * a + PLASMA[0] * b + CYAN[0] * c;
      g += AURORA[1] * a + PLASMA[1] * b + CYAN[1] * c;
      bl += AURORA[2] * a + PLASMA[2] * b + CYAN[2] * c;

      // 顶部玻璃高光
      const sheen = Math.max(0, 1 - ny / 0.42) * 0.16;
      r += 255 * sheen;
      g += 255 * sheen;
      bl += 255 * sheen;

      // 暗角，让中心更聚焦
      const dx = nx - cx;
      const dy = ny - cy;
      const dist = Math.sqrt(dx * dx + dy * dy);
      const vignette = 1 - smoothstep(0.30, 0.80, dist) * 0.72;
      r *= vignette;
      g *= vignette;
      bl *= vignette;

      // 白色圆环（App 内标识）
      const ringInner = 0.300;
      const ringOuter = 0.337;
      const ring = smoothstep(ringInner - 0.006, ringInner, dist) * (1 - smoothstep(ringOuter, ringOuter + 0.006, dist));
      // 中心点
      const dot = 1 - smoothstep(0.062, 0.078, dist);

      const white = clamp(ring * 0.94 + dot);
      r = r * (1 - white) + 255 * white;
      g = g * (1 - white) + 255 * white;
      bl = bl * (1 - white) + 255 * white;

      const i = (y * size + x) * 4;
      out[i] = Math.round(clamp(r / 255) * 255);
      out[i + 1] = Math.round(clamp(g / 255) * 255);
      out[i + 2] = Math.round(clamp(bl / 255) * 255);
      out[i + 3] = 255;
    }
  }
  return out;
}

/* ── 输出 ────────────────────────────────────────────────── */
const TARGETS = [
  { file: 'ios/AuroraApp/Assets.xcassets/AppIcon.appiconset/icon-1024.png', size: 1024 },
  { file: 'public/icons/icon-512.png', size: 512 },
  { file: 'public/icons/apple-touch-icon.png', size: 180 },
  { file: 'public/icons/favicon-32.png', size: 32 },
];

function main() {
  console.log('\n生成极光图标');
  for (const target of TARGETS) {
    const full = path.join(ROOT, target.file);
    fs.mkdirSync(path.dirname(full), { recursive: true });
    const png = encodePNG(target.size, target.size, render(target.size));
    fs.writeFileSync(full, png);
    console.log(`  ✓ ${target.file}  ${target.size}×${target.size}  ${(png.length / 1024).toFixed(1)} KB`);
  }
  console.log('');
}

main();
