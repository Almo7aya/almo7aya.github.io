// os/programs/maze/assets.mjs · everything 7MAZE precomputes at build time, written to gen/
//   palette.bin   768 bytes, 16 colour ramps x 16 brightness levels, 6-bit DAC values
//   shade.bin     16 tables of 256 bytes: shade[level][colour] = same ramp, darker (distance fog)
//   tex.bin       64x64 wall textures, 4096 bytes each, column-major (u*64 + v) for column drawing
//   bg.bin        320x200 ceiling + floor gradient (dithered), copied under the walls every frame
//   map.bin       32x24 cells: 0 floor, 1..3 walls, 4.. posters (value - 1 = texture index)
//   tables.inc    sin table (1.14 fixed point, 2048 steps + a quarter for cos), camera-plane table
//   meta.inc      constants (start position, texture count, sector counts)
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

export default async ({ dir, gen, root }) => {
  const font = readFileSync(join(root, 'public', 'os', 'vgafont.bin'));
  const girl = readFileSync(join(root, 'os', 'assets', 'girl', 'still64.bin'));

  // ---------------- palette: ramp r (0..15), level k (0..15) -> index r*16+k ----------------
  const RAMPS = [
    [200, 200, 205], // 0 gray / text
    [165, 62, 42],   // 1 brick
    [150, 98, 52],   // 2 wood
    [105, 118, 140], // 3 stone
    [60, 175, 85],   // 4 green
    [55, 105, 215],  // 5 blue
    [225, 175, 40],  // 6 gold
    [140, 75, 205],  // 7 purple
    [40, 180, 205],  // 8 cyan
    [235, 120, 30],  // 9 orange
    [215, 70, 150],  // 10 pink
    [30, 145, 125],  // 11 teal
    [205, 35, 55],   // 12 crimson
    [160, 165, 45],  // 13 olive (gruvbox)
    [175, 150, 225], // 14 lavender (the girl)
    [205, 185, 145], // 15 sand / mortar
  ];
  const rgb = (r, k) => {
    const b = RAMPS[r], t = k / 15;
    if (t <= 0.75) return b.map(c => c * t / 0.75);
    const w = (t - 0.75) / 0.25 * 0.65;
    return b.map(c => c + (255 - c) * w);
  };
  const pal = Buffer.alloc(768);
  for (let i = 0; i < 256; i++) rgb(i >> 4, i & 15).forEach((c, j) => { pal[i * 3 + j] = Math.round(Math.min(255, c) / 255 * 63); });
  writeFileSync(join(gen, 'palette.bin'), pal);

  const shade = Buffer.alloc(4096);
  for (let l = 0; l < 16; l++) {
    const f = Math.max(0.08, 1 - l * 0.062);
    for (let i = 0; i < 256; i++) {
      const r = i >> 4, want = rgb(r, i & 15).map(c => c * f);
      let best = 0, bd = 1e9;
      for (let k = 0; k < 16; k++) { const c = rgb(r, k), d = (c[0] - want[0]) ** 2 + (c[1] - want[1]) ** 2 + (c[2] - want[2]) ** 2; if (d < bd) { bd = d; best = k; } }
      shade[l * 256 + i] = r * 16 + best;
    }
  }
  writeFileSync(join(gen, 'shade.bin'), shade);

  // ---------------- textures ----------------
  const hash = (x, y, s = 0) => { let h = (x * 374761393 + y * 668265263 + s * 2147483647) | 0; h = Math.imul(h ^ (h >>> 13), 1274126177); return ((h ^ (h >>> 16)) >>> 0) / 4294967296; };
  const BAYER = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5];
  const dith = (x, y, v) => Math.max(0, Math.min(15, Math.floor(v + BAYER[(y & 3) * 4 + (x & 3)] / 16)));
  const C = (r, k) => r * 16 + Math.max(0, Math.min(15, Math.round(k)));
  const textures = [];
  const tex = fn => { const t = new Uint8Array(4096); for (let u = 0; u < 64; u++) for (let v = 0; v < 64; v++) t[u * 64 + v] = fn(u, v); textures.push(t); return textures.length - 1; };

  // walls 0..2: brick, wood panelling, stone blocks
  tex((u, v) => {
    const row = v >> 4, off = row & 1 ? 16 : 0, bx = ((u + off) & 63) >> 5;
    const mu = (u + off) & 31, mv = v & 15;
    if (mv >= 14 || mu >= 30) return C(15, 5 + hash(u, v) * 2);
    const base = 7.5 + hash(bx, row, 1) * 2.5 - (mv === 0 || mu === 0 ? -1.5 : 0) - (mv === 13 ? 1.5 : 0);
    return C(1, dith(u, v, base + hash(u, v, 2) * 1.6 - 0.8));
  });
  tex((u, v) => {
    const p = u >> 4, pu = u & 15;
    if (pu === 0) return C(2, 2);
    if (pu === 15) return C(2, 5);
    if (v >= 56) return C(2, v === 56 ? 11 : 6);                 // skirting board
    const grain = Math.sin((u * 0.9 + p * 7) + Math.sin(v * 0.21 + p) * 2.2) * 1.1;
    return C(2, dith(u, v, 8.2 + grain + hash(p, 0, 3) * 1.5 + hash(u, v, 4) * 0.8));
  });
  tex((u, v) => {
    const row = v >> 5, rv = v & 31, cuts = row ? [0, 26, 48] : [0, 14, 40], off = 0;
    let cu = 0; for (const c of cuts) if (u >= c) cu = c;
    const nu = u - cu, idx = cuts.indexOf(cu);
    if (rv >= 30 || cuts.includes(u) || u === 63) return C(3, 3);
    let b = 8 + hash(idx, row, 5) * 2 + hash(u >> 1, v >> 1, 6) * 1.6;
    if (rv === 0 || nu === 1) b += 1.5;
    if (rv === 29) b -= 2;
    return C(3, dith(u, v, b + off));
  });

  // ---------------- background: ceiling and floor gradients, dithered ----------------
  const bg = Buffer.alloc(64000);
  for (let y = 0; y < 200; y++) for (let x = 0; x < 320; x++) {
    let c;
    if (y < 100) c = C(3, dith(x, y, 1.2 + (99 - y) / 99 * 4.6));
    else c = C(2, dith(x, y, 0.6 + (y - 100) / 99 * 6.8));
    bg[y * 320 + x] = c;
  }
  writeFileSync(join(gen, 'bg.bin'), bg);

  // ---------------- the gallery map ----------------
  const W = 32, H = 24, BRICK = 1, WOOD = 2, STONE = 3;
  const map = new Uint8Array(W * H).fill(BRICK), room = new Int8Array(W * H).fill(-1);
  const rooms = [
    { name: 'start', x0: 10, y0: 16, x1: 15, y1: 20, mat: BRICK },
    { name: 'hall', x0: 3, y0: 9, x1: 22, y1: 12, mat: WOOD },
    { name: 'kyty', x0: 1, y0: 1, x1: 7, y1: 6, mat: STONE },
    { name: 'work', x0: 10, y0: 1, x1: 15, y1: 6, mat: BRICK },
    { name: 'nvim', x0: 18, y0: 1, x1: 24, y1: 6, mat: WOOD },
  ];
  rooms.forEach((r, i) => { for (let y = r.y0; y <= r.y1; y++) for (let x = r.x0; x <= r.x1; x++) { map[y * W + x] = 0; room[y * W + x] = i; } });
  const corridors = [[12, 13, 12, 15, 0], [4, 7, 4, 8, 2], [12, 7, 12, 8, 3], [21, 7, 21, 8, 4]];
  for (const [x0, y0, x1, y1, ri] of corridors) for (let y = y0; y <= y1; y++) for (let x = x0; x <= x1; x++) { map[y * W + x] = 0; room[y * W + x] = ri; }
  for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {           // a wall takes the material of the room it faces
    if (map[y * W + x] === 0) continue;
    for (const [dx, dy] of [[0, 1], [0, -1], [1, 0], [-1, 0]]) {
      const nx = x + dx, ny = y + dy;
      if (nx >= 0 && ny >= 0 && nx < W && ny < H && map[ny * W + nx] === 0) { map[y * W + x] = rooms[room[ny * W + nx]].mat; break; }
    }
  }
  // posters, in card order (card index = map value - 4 = texture index - 3):
  // [name, x, y, ramp, big tag, small label]; each hangs on the wall texture of its room
  const posters = [
    ['welcome', 12, 21, 14], ['work', 12, 0, 12, 'play', 'WORK'], ['kyty', 4, 0, 5, 'PS5', 'KytyPS5'],
    ['lab', 0, 3, 7, 'SL', 'SHADERS'], ['learn', 8, 4, 11, '101', 'LEARN'], ['gowan', 25, 4, 8, 'GO', 'GoWAN'],
    ['openingh', 20, 0, 4, 'GH', 'NVIM'], ['gruvbox', 23, 0, 13, 'NEO', 'GRUVBOX'], ['sevenos', 9, 4, 9, '7OS', 'TINY OS'],
    ['patches', 16, 4, 10, 'PR', 'MERGED'], ['github', 16, 18, 3, '@', 'GITHUB'], ['about', 9, 18, 6, 'ALI', 'ABOUT'],
  ];
  const glyph = (ch, x, y) => (font[ch * 16 + y] >> (7 - x)) & 1;
  const PX0 = 5, PX1 = 58, PY0 = 4, PY1 = 57;                       // the poster on the 64x64 wall face
  const IX0 = PX0 + 3, IX1 = PX1 - 3, IY0 = PY0 + 3, IY1 = PY1 - 3; // inside the frame: 48 x 48
  const POSTER_BASE = textures.length + 1;
  for (const [name, x, y, ramp, tag, label] of posters) {
    if (map[y * W + x] === 0) throw new Error(`poster ${name} is not on a wall`);
    const wall = textures[map[y * W + x] - 1];
    const img = new Uint8Array(4096).fill(255);   // 255 = background, 253 tag, 254 tag shadow, 252 label
    const put = (px, py, c) => { if (px >= IX0 && px <= IX1 && py >= IY0 && py <= IY1) img[py * 64 + px] = c; };
    if (tag === 'play') {                         // a play triangle for the video player
      for (let py = 0; py < 24; py++) for (let px = 0; px < 21; px++) if (px <= (py < 12 ? py : 23 - py) * 1.75) { put(23 + px + 1, 10 + py + 1, 254); put(23 + px, 10 + py, 253); }
    } else if (tag) {
      const tw = tag.length * 16, tx = 32 - (tw >> 1), ty = 7;
      for (let i = 0; i < tag.length; i++) for (let gy = 0; gy < 16; gy++) for (let gx = 0; gx < 8; gx++) if (glyph(tag.charCodeAt(i), gx, gy))
        for (let s = 0; s < 4; s++) { const px = tx + (i * 8 + gx) * 2 + (s & 1), py = ty + gy * 2 + (s >> 1); put(px + 1, py + 1, 254); put(px, py, 253); }
    }
    if (label) {
      const lw = label.length * 7, lx = 32 - (lw >> 1), ly = 38;
      for (let i = 0; i < label.length; i++) for (let gy = 0; gy < 16; gy++) for (let gx = 0; gx < 8; gx++) if (glyph(label.charCodeAt(i), gx, gy)) put(lx + i * 7 + gx, ly + gy, 252);
    }
    tex((u, v) => {
      if (u < PX0 || u > PX1 || v < PY0 || v > PY1) {               // the wall around it, a soft shadow right/below
        const w = wall[u * 64 + v];
        return (u === PX1 + 1 && v > PY0) || (v === PY1 + 1 && u > PX0) ? (w & 0xF0) | Math.max(0, (w & 15) - 4) : w;
      }
      if (u < PX0 + 2 || u > PX1 - 2 || v < PY0 + 2 || v > PY1 - 2) return C(2, u === PX0 || v === PY0 ? 4 : u === PX1 || v === PY1 ? 2 : 6);
      if (u === PX0 + 2 || u === PX1 - 2 || v === PY0 + 2 || v === PY1 - 2) return C(6, 12);  // gold rim
      if (!tag) return C(14, dith(u, v, 1 + girl[Math.floor((v - IY0) * 64 / 48) * 64 + Math.floor((u - IX0) * 64 / 48)] / 255 * 13.5));
      const p = img[v * 64 + u];
      if (p === 253) return C(0, 15);
      if (p === 254) return C(ramp, 2);
      if (p === 252) return C(ramp, 14);
      if (v === 37) return C(ramp, 11);                                                // divider
      return C(ramp, dith(u, v, 6.5 - (v - IY0) * 0.04 + (v > 37 ? -1.5 : 0)));
    });
    map[y * W + x] = textures.length;            // map value = texture index + 1
  }
  writeFileSync(join(gen, 'map.bin'), map);
  const tbin = Buffer.alloc(textures.length * 4096);
  textures.forEach((t, i) => tbin.set(t, i * 4096));
  writeFileSync(join(gen, 'tex.bin'), tbin);

  // minimap colours: only walls that touch the floor are drawn, posters in their own colour
  const mm = new Uint8Array(W * H);
  for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
    const v = map[y * W + x];
    if (!v) continue;
    let near = false;
    for (let dy = -1; dy <= 1; dy++) for (let dx = -1; dx <= 1; dx++) { const nx = x + dx, ny = y + dy; if (nx >= 0 && ny >= 0 && nx < W && ny < H && !map[ny * W + nx]) near = true; }
    if (near) mm[y * W + x] = v < POSTER_BASE ? C(v, 7) : C(posters[v - POSTER_BASE][3], 13);
  }
  writeFileSync(join(gen, 'mm.bin'), mm);

  // ---------------- tables ----------------
  const dw = (name, arr) => `${name}:\n` + Array.from({ length: Math.ceil(arr.length / 16) }, (_, i) => '        dw ' + arr.slice(i * 16, i * 16 + 16).join(', ')).join('\n') + '\n';
  const sin = Array.from({ length: 2048 + 512 }, (_, i) => Math.round(16384 * Math.sin(i / 2048 * 2 * Math.PI)));
  const PLANE = 0.66;
  const camk = Array.from({ length: 320 }, (_, x) => Math.round(((2 * (x + 0.5)) / 320 - 1) * PLANE * 16384));
  writeFileSync(join(gen, 'tables.inc'), '; generated by assets.mjs\n' + dw('sin_tab', sin) + dw('cam_tab', camk));

  const start = rooms[0];
  writeFileSync(join(gen, 'meta.inc'), [
    '; generated by assets.mjs',
    `NTEX            equ ${textures.length}`,
    `TEX_SECTORS     equ ${tbin.length / 512}`,
    `BG_SECTORS      equ ${bg.length / 512 | 0}`,
    `BG_TAIL         equ ${bg.length % 512}`,
    `MAP_W           equ ${W}`,
    `MAP_H           equ ${H}`,
    `START_X         equ ${12 * 256 + 128}`,
    `START_Y         equ ${19 * 256 + 128}`,
    `START_ANG       equ 1536`,
    `ROOM_X0         equ ${start.x0}`,
    `ROOM_Y0         equ ${start.y0}`,
    `ROOM_X1         equ ${start.x1}`,
    `ROOM_Y1         equ ${start.y1}`,
    `NPOSTERS        equ ${posters.length}`,
    `POSTER_BASE     equ ${POSTER_BASE}`,
    '',
  ].join('\n'));
  // the map, as text, for eyeballing
  writeFileSync(join(gen, 'map.txt'), Array.from({ length: H }, (_, y) => Array.from({ length: W }, (_, x) => { const v = map[y * W + x]; return v === 0 ? '.' : v < 4 ? '#=%'[v - 1] : String.fromCharCode(96 + v - 3); }).join('')).join('\n') + '\n');
};
