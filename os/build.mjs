// os/build.mjs · assemble 7OS with NASM
//   npm run os
// writes public/os/almo7aya.img (the bootable disk) and src/data/listing.json
// (the NASM listing, so the debugger can show source next to the running code)
import { execFileSync } from 'node:child_process';
import { copyFileSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const src = join(root, 'os', 'almo7aya.asm');
const out = join(root, 'public', 'os');
const img = join(out, 'almo7aya.img'), lst = join(root, 'os', 'almo7aya.lst');
mkdirSync(out, { recursive: true });

try {
  execFileSync('nasm', ['-f', 'bin', src, '-o', img, '-l', lst], { stdio: 'inherit' });
} catch (e) {
  console.error('\nnasm failed or is not installed. install it (scoop install nasm / apt install nasm) and retry.\n');
  process.exit(1);
}
copyFileSync(src, join(out, 'almo7aya.asm'));   // ship the source next to the image

const bytes = readFileSync(img);
if (bytes[510] !== 0x55 || bytes[511] !== 0xAA) throw new Error('boot signature 55AA missing');

// listing lines:  "    12 00000010 BE[2300]           mov si, msg"
// long db lines continue on rows that end in '-' with no source text
const ORG = 0x7C00, lines = [];
for (const raw of readFileSync(lst, 'latin1').split(/\r?\n/)) {
  const m = raw.match(/^\s*(\d+)\s(?:\s?([0-9A-F]{8})\s([0-9A-F\[\]\(\)]+)(-?))?\s*(.*)$/);
  if (!m) continue;
  const [, n, off, hex, cont, text] = m;
  if (cont === '-' && !text) continue;
  const last = lines[lines.length - 1];
  if (last && last.n === +n) continue;
  lines.push({ n: +n, a: off ? ORG + parseInt(off, 16) : null, b: hex ? hex.replace(/[\[\]\(\)]/g, '').slice(0, 12) : '', s: text });
}
mkdirSync(join(root, 'src', 'data'), { recursive: true });
writeFileSync(join(root, 'src', 'data', 'listing.json'), JSON.stringify({ size: bytes.length, lines }));
console.log(`7OS: almo7aya.img ${bytes.length} bytes (${bytes.length / 512} sectors), ${lines.length} listing lines`);
