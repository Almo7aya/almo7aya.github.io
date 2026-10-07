// os/girl-sheet.mjs · turns public/girl/panic.gif into a sprite sheet the Watch TV can draw:
//   public/girl/panic-sheet.png   grayscale, every frame composed (disposal honoured), SIZE×SIZE each, COLS per row
//   public/girl/panic-sheet.json  { size, cols, frames, delays }
// a tiny GIF89a decoder (LZW, local/global palettes, transparency, interlace), no dependencies
import { readFileSync, writeFileSync } from 'node:fs';
import { deflateSync, crc32 } from 'node:zlib';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const SIZE = 256, COLS = 6;

function decodeGif(b) {
  if (b.toString('latin1', 0, 3) !== 'GIF') throw new Error('not a GIF');
  const W = b.readUInt16LE(6), H = b.readUInt16LE(8), flags = b[10];
  let p = 13, gct = null;
  const table = (at, n) => { const t = []; for (let i = 0; i < n; i++) t.push([b[at + i * 3], b[at + i * 3 + 1], b[at + i * 3 + 2]]); return t; };
  if (flags & 0x80) { const n = 2 << (flags & 7); gct = table(p, n); p += n * 3; }
  const canvas = new Uint8Array(W * H).fill(255);   // luminance, white background like the original
  const frames = [], delays = [];
  let gce = { disposal: 0, transparent: -1, delay: 2 };
  const blocks = () => { const out = []; while (b[p]) { out.push(b.subarray(p + 1, p + 1 + b[p])); p += b[p] + 1; } p++; return Buffer.concat(out); };
  for (;;) {
    const id = b[p++];
    if (id === 0x3B || id === undefined) break;
    if (id === 0x21) {
      const label = b[p++];
      if (label === 0xF9) { const f = b[p + 1]; gce = { disposal: (f >> 2) & 7, transparent: f & 1 ? b[p + 4] : -1, delay: b.readUInt16LE(p + 2) || 2 }; }
      blocks();
      continue;
    }
    if (id !== 0x2C) throw new Error(`bad block ${id.toString(16)} at ${p - 1}`);
    const x = b.readUInt16LE(p), y = b.readUInt16LE(p + 2), w = b.readUInt16LE(p + 4), h = b.readUInt16LE(p + 6), lf = b[p + 8]; p += 9;
    let pal = gct;
    if (lf & 0x80) { const n = 2 << (lf & 7); pal = table(p, n); p += n * 3; }
    const minCode = b[p++], data = blocks();
    const idx = lzw(data, minCode, w * h);
    const before = gce.disposal === 3 ? canvas.slice() : null;
    const rows = [];                                   // interlaced rows come in 4 passes
    if (lf & 0x40) for (const [s, st] of [[0, 8], [4, 8], [2, 4], [1, 2]]) for (let r = s; r < h; r += st) rows.push(r);
    else for (let r = 0; r < h; r++) rows.push(r);
    rows.forEach((r, i) => {
      for (let c = 0; c < w; c++) {
        const v = idx[i * w + c]; if (v === gce.transparent || v === undefined) continue;
        const [R, G, B] = pal[v]; const X = x + c, Y = y + r;
        if (X < W && Y < H) canvas[Y * W + X] = Math.round(0.299 * R + 0.587 * G + 0.114 * B);
      }
    });
    frames.push(canvas.slice()); delays.push(gce.delay * 10);
    if (gce.disposal === 2) for (let r = 0; r < h; r++) canvas.fill(255, (y + r) * W + x, (y + r) * W + x + w);
    if (before) canvas.set(before);
    gce = { disposal: 0, transparent: -1, delay: 2 };
  }
  return { W, H, frames, delays };
}

function lzw(data, minCode, n) {
  const clear = 1 << minCode, eoi = clear + 1, out = new Uint8Array(n);
  let size = minCode + 1, next = eoi + 1, prev = -1, o = 0, bit = 0;
  const pre = new Int32Array(4096), suf = new Uint8Array(4096), len = new Uint16Array(4096);
  for (let i = 0; i < clear; i++) { pre[i] = -1; suf[i] = i; len[i] = 1; }
  const first = c => { while (pre[c] !== -1) c = pre[c]; return suf[c]; };
  const emit = c => { const l = len[c]; for (let i = l - 1, k = c; i >= 0; i--, k = pre[k]) if (o + i < n) out[o + i] = suf[k]; o += l; };
  while (o < n) {
    let code = 0;
    for (let i = 0; i < size; i++, bit++) if (data[bit >> 3] & (1 << (bit & 7))) code |= 1 << i;
    if ((bit >> 3) > data.length) break;
    if (code === clear) { size = minCode + 1; next = eoi + 1; prev = -1; continue; }
    if (code === eoi) break;
    if (prev === -1) { emit(code); prev = code; continue; }
    const k = code < next ? first(code) : first(prev);
    if (next < 4096) { pre[next] = prev; suf[next] = k; len[next] = len[prev] + 1; next++; if (next === 1 << size && size < 12) size++; }
    emit(code); prev = code;
  }
  return out;
}

// area-average downscale, then a light unsharp mask so the line art stays crisp at SIZE
function scale(src, W, H, S) {
  const dst = new Float32Array(S * S), r = W / S;
  for (let y = 0; y < S; y++) for (let x = 0; x < S; x++) {
    let sum = 0, cnt = 0;
    for (let yy = Math.floor(y * r); yy < Math.min(H, Math.ceil((y + 1) * r)); yy++)
      for (let xx = Math.floor(x * r); xx < Math.min(W, Math.ceil((x + 1) * r)); xx++) { sum += src[yy * W + xx]; cnt++; }
    dst[y * S + x] = sum / cnt;
  }
  const out = new Uint8Array(S * S);
  for (let y = 0; y < S; y++) for (let x = 0; x < S; x++) {
    let blur = 0, cnt = 0;
    for (let dy = -1; dy <= 1; dy++) for (let dx = -1; dx <= 1; dx++) { const X = x + dx, Y = y + dy; if (X >= 0 && Y >= 0 && X < S && Y < S) { blur += dst[Y * S + X]; cnt++; } }
    const v = dst[y * S + x] + 0.6 * (dst[y * S + x] - blur / cnt);
    out[y * S + x] = Math.max(0, Math.min(255, Math.round(v)));
  }
  return out;
}

function png(file, w, h, gray) {
  const chunk = (type, data) => { const len = Buffer.alloc(4); len.writeUInt32BE(data.length); const td = Buffer.concat([Buffer.from(type), data]); const c = Buffer.alloc(4); c.writeUInt32BE(crc32(td)); return Buffer.concat([len, td, c]); };
  const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4); ihdr[8] = 8; ihdr[9] = 0;   // 8-bit grayscale
  const raw = Buffer.alloc((w + 1) * h);
  for (let y = 0; y < h; y++) gray.subarray(y * w, y * w + w).forEach((v, x) => { raw[y * (w + 1) + 1 + x] = v; });
  writeFileSync(file, Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', ihdr), chunk('IDAT', deflateSync(raw, { level: 9 })), chunk('IEND', Buffer.alloc(0))]));
}

const gif = decodeGif(readFileSync(join(root, 'public', 'girl', 'panic.gif')));
const rows = Math.ceil(gif.frames.length / COLS), sheet = new Uint8Array(COLS * SIZE * rows * SIZE).fill(255);
gif.frames.forEach((f, i) => {
  const s = scale(f, gif.W, gif.H, SIZE), ox = (i % COLS) * SIZE, oy = Math.floor(i / COLS) * SIZE;
  for (let y = 0; y < SIZE; y++) sheet.set(s.subarray(y * SIZE, y * SIZE + SIZE), (oy + y) * COLS * SIZE + ox);
});
png(join(root, 'public', 'girl', 'panic-sheet.png'), COLS * SIZE, rows * SIZE, sheet);
writeFileSync(join(root, 'public', 'girl', 'panic-sheet.json'), JSON.stringify({ size: SIZE, cols: COLS, frames: gif.frames.length, delays: gif.delays }) + '\n');
console.log(`panic.gif ${gif.W}x${gif.H}, ${gif.frames.length} frames -> panic-sheet.png ${COLS * SIZE}x${rows * SIZE}`);
