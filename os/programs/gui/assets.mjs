// os/programs/gui/assets.mjs · palette, pixel-art icons, cursor and the girl for 7GUI
//   gen/palette.bin   768 bytes, the whole DAC (6-bit R, G, B)
//   gen/icons.bin     7 icons of 16x16 bytes (palette indices, 0xFF = transparent)
//   gen/cursor.bin    the arrow, 11x16
//   gen/girl.bin      still128.bin, Floyd-Steinberg dithered to 16 grays (0xE0..0xEF)
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const T = 0xFF;
// the 16 base colours + extras; letters are what the ASCII art uses
const BASE = [
  ['K', [0, 0, 0]],     // 0  black
  ['n', [0, 0, 40]],    // 1  navy (selection)
  ['g', [0, 36, 0]],    // 2  green
  ['t', [0, 32, 32]],   // 3  teal
  ['r', [40, 0, 0]],    // 4  dark red
  ['p', [32, 0, 32]],   // 5  purple
  ['O', [40, 22, 6]],   // 6  brown
  ['l', [48, 48, 48]],  // 7  light gray (the face colour)
  ['d', [32, 32, 32]],  // 8  dark gray
  ['b', [16, 28, 63]],  // 9  blue
  ['G', [18, 56, 18]],  // 10 lime
  ['c', [20, 58, 60]],  // 11 cyan
  ['R', [63, 18, 18]],  // 12 red
  ['m', [63, 28, 52]],  // 13 pink
  ['y', [63, 56, 18]],  // 14 yellow
  ['W', [63, 63, 63]],  // 15 white
  ['1', [3, 10, 5]],    // 16 LCD background
  ['2', [24, 60, 30]],  // 17 LCD digits
  ['o', [60, 38, 10]],  // 18 orange
  ['s', [63, 47, 37]],  // 19 skin
  ['h', [20, 12, 6]],   // 20 hair
  ['Y', [50, 38, 4]],   // 21 folder shade
  ['B', [8, 14, 40]],   // 22 deep blue
];
const lerp = (a, b, t) => a.map((v, i) => Math.round(v + (b[i] - v) * t));

export default async ({ dir, gen }) => {
  const pal = Array.from({ length: 256 }, () => [0, 0, 0]);
  BASE.forEach(([, c], i) => { pal[i] = c; });
  for (let i = 0; i < 32; i++) pal[0x20 + i] = lerp([0, 0, 34], [18, 40, 58], i / 31);   // active title bar
  for (let i = 0; i < 32; i++) pal[0x40 + i] = lerp([24, 24, 26], [38, 38, 40], i / 31); // inactive title bar
  for (let i = 0; i < 64; i++) pal[0x60 + i] = lerp([4, 26, 34], [20, 10, 30], i / 63);  // desktop, top to bottom
  for (let i = 0; i < 64; i++) pal[0xA0 + i] = lerp([9, 33, 41], [26, 15, 37], i / 63);  // the watermark, a bit lighter
  for (let i = 0; i < 16; i++) pal[0xE0 + i] = [0, 1, 2].map(() => Math.round(i * 63 / 15)); // 16 grays
  writeFileSync(join(gen, 'palette.bin'), Buffer.from(pal.flat()));

  const key = Object.fromEntries(BASE.map(([k], i) => [k, i]));
  const art = (rows, w, h, name) => {
    if (rows.length !== h) throw new Error(`${name}: ${rows.length} rows, want ${h}`);
    return Buffer.from(rows.flatMap((r, y) => {
      if (r.length !== w) throw new Error(`${name} row ${y}: "${r}" is ${r.length} wide, want ${w}`);
      return [...r].map(ch => {
        if (ch === '.') return T;
        if (!(ch in key)) throw new Error(`${name}: unknown colour ${ch}`);
        return key[ch];
      });
    }));
  };

  // the girl, 128x128 grayscale, dithered to 16 levels
  const src = readFileSync(join(dir, '..', '..', 'assets', 'girl', 'still128.bin'));
  const f = Float32Array.from(src, v => v / 255 * 15);
  const girl = Buffer.alloc(128 * 128);
  for (let y = 0; y < 128; y++) for (let x = 0; x < 128; x++) {
    const i = y * 128 + x, v = Math.max(0, Math.min(15, Math.round(f[i]))), e = f[i] - v;
    girl[i] = 0xE0 + v;
    if (x < 127) f[i + 1] += e * 7 / 16;
    if (y < 127) { if (x) f[i + 127] += e * 3 / 16; f[i + 128] += e * 5 / 16; if (x < 127) f[i + 129] += e / 16; }
  }
  writeFileSync(join(gen, 'girl.bin'), girl);

  // her icon: a framed 14x14 thumbnail
  const thumb = Buffer.alloc(256, 0);
  for (let y = 0; y < 14; y++) for (let x = 0; x < 14; x++) {
    let s = 0, n = 0;
    for (let yy = Math.floor(y * 128 / 14); yy < Math.floor((y + 1) * 128 / 14); yy++)
      for (let xx = Math.floor(x * 128 / 14); xx < Math.floor((x + 1) * 128 / 14); xx++) { s += src[yy * 128 + xx]; n++; }
    thumb[(y + 1) * 16 + x + 1] = 0xE0 + Math.round(s / n / 255 * 15);
  }

  const icons = [
    art([ // about: a person
      '................',
      '.....KKKKKK.....',
      '....KhhhhhhK....',
      '...KhhhhhhhhK...',
      '...KhsssssshK...',
      '...KssKssKssK...',
      '...KssssssssK...',
      '...KsssKKsssK...',
      '....KssssssK....',
      '.....KKssKK.....',
      '...KKbbKKbbKK...',
      '..KbbbbWWbbbbK..',
      '.KbbbbbWWbbbbbK.',
      '.KbbbbbWWbbbbbK.',
      '.KbbbbbbbbbbbbK.',
      '.KKKKKKKKKKKKKK.',
    ], 16, 16, 'about'),
    art([ // work: a briefcase
      '................',
      '................',
      '.....KKKKKK.....',
      '....KK....KK....',
      '....K......K....',
      '.KKKKKKKKKKKKKK.',
      '.KooooooooooooK.',
      '.KOOOOOOOOOOOOK.',
      '.KOOOOOOOOOOOOK.',
      '.KKKKKKyyKKKKKK.',
      '.KOOOOOyyOOOOOK.',
      '.KOOOOOOOOOOOOK.',
      '.KOOOOOOOOOOOOK.',
      '.KOOOOOOOOOOOOK.',
      '.KKKKKKKKKKKKKK.',
      '................',
    ], 16, 16, 'work'),
    art([ // projects: a folder
      '................',
      '................',
      '.KKKKK..........',
      'KYYYYYK.........',
      'KYYYYYYKKKKKKKK.',
      'KYYYYYYYYYYYYYYK',
      'KYYKKKKKKKKKKKKK',
      'KYKWyyyyyyyyyyyK',
      'KYKyyyyyyyyyyyyK',
      'KYKyyyyyyyyyyyyK',
      'KKyyyyyyyyyyyyyK',
      'KKyyyyyyyyyyyyyK',
      'KKyyyyyyyyyyyyyK',
      'KKyyyyyyyyyyyyyK',
      'KKKKKKKKKKKKKKKK',
      '................',
    ], 16, 16, 'projects'),
    art([ // github: a globe
      '................',
      '.....KKKKKK.....',
      '...KKbbbGGbbKK..',
      '..KbbbGGGGbbbbK.',
      '.KbbbGGGGGbbbbbK',
      '.KbbbbGGGbbbGbbK',
      '.KbbbbbGbbbGGGbK',
      '.KbbbbbbbbGGGGbK',
      '.KbbGGbbbbGGGGbK',
      '.KbGGGGbbbbGGbbK',
      '.KbGGGGGbbbbbbbK',
      '..KbGGGGbbbbbbK.',
      '..KbbGGbbbbbbbK.',
      '...KKbbbbbbbKK..',
      '.....KKKKKK.....',
      '................',
    ], 16, 16, 'github'),
    thumb,
    art([ // clock
      '................',
      '.....KKKKKK.....',
      '...KKWWWWWWKK...',
      '..KWWWWKWWWWWK..',
      '.KWWWWWKWWWWWWK.',
      '.KWWWWWKWWWWWWK.',
      'KWWWWWWKWWWWWWWK',
      'KWKWWWWKWWWWWKWK',
      'KWWWWWWWKKKWWWWK',
      'KWWWWWWWWWWWWWWK',
      '.KWWWWWWWWWWWWK.',
      '.KWWWWWWWWRWWWK.',
      '..KWWWWWKWWRWK..',
      '...KKWWWWWWKK...',
      '.....KKKKKK.....',
      '................',
    ], 16, 16, 'clock'),
    art([ // readme: a terminal
      '................',
      '.KKKKKKKKKKKKKK.',
      '.KllllllllllllK.',
      '.KlKKKKKKKKKKlK.',
      '.KlKGKKKKKKKKlK.',
      '.KlKKGKKKKKKKlK.',
      '.KlKGKKGGGKKKlK.',
      '.KlKKKKKKKKKKlK.',
      '.KlKGGGGGKKKKlK.',
      '.KlKKKKKKKKKKlK.',
      '.KllllllllllllK.',
      '.KKKKKKKKKKKKKK.',
      '......KlllK.....',
      '....KKKKKKKKK...',
      '....KdddddddK...',
      '....KKKKKKKKK...',
    ], 16, 16, 'readme'),
  ];
  writeFileSync(join(gen, 'icons.bin'), Buffer.concat(icons));

  writeFileSync(join(gen, 'cursor.bin'), art([
    'K..........',
    'KK.........',
    'KWK........',
    'KWWK.......',
    'KWWWK......',
    'KWWWWK.....',
    'KWWWWWK....',
    'KWWWWWWK...',
    'KWWWWWWWK..',
    'KWWWWWWWWK.',
    'KWWWWWKKKKK',
    'KWWKWWK....',
    'KWK.KWWK...',
    'KK..KWWK...',
    'K....KWWK..',
    '......KK...',
  ], 11, 16, 'cursor'));
};
