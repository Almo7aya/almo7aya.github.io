// os/programs/player/assets.mjs · the content pipeline for 7PLAYER
//
//   girl frames (8-bit gray) -> quantise to the 16-entry palette -> RLE -> RC4-drop256 per frame
//   -> 7MV container (header + license + index + frames, sector aligned) -> gen/movie.7mv
//   plus gen/keys.inc: the device root key that is "provisioned" inside the player binary.
//
// two renditions (an ABR ladder): HI = 128x128, 16 levels, LO = 64x64, 8 levels.
// the 16-frame clip is laid out PASSES times, every frame with its own IV, so the stream
// is 96 frames long (8 s at 12 fps) and every ciphertext is different.
//
// key ladder (mirrored in main.asm):
//   DK   = RC4drop256(ROOT ^ [0..0, MODEL]) first 16 bytes   (MODEL = ROM byte F000:FFFE)
//   KEK  = RC4drop256(DK ^ (KID || KID))   first 16 bytes
//   WRAP = CK ^ KEK                       (stored in the license)
//   KCV  = RC4drop256(CK)                 first 4 bytes
//   FK_n = CK ^ IV_n ;  frame_n = RC4drop256(FK_n) ^ rle(frame_n)
import { readFileSync, writeFileSync } from 'node:fs';
import { randomBytes } from 'node:crypto';
import { join } from 'node:path';

const MODEL = 0xFC;                        // AT model byte: the emulator ROM and SeaBIOS both have it
const PASSES = 6, FPS = 12, CLIP = 16;
export const SLOT = 8192;                  // the player's ring buffer slot size

function rc4(key) {
  const S = Array.from({ length: 256 }, (_, i) => i);
  for (let i = 0, j = 0; i < 256; i++) { j = (j + S[i] + key[i % key.length]) & 255; [S[i], S[j]] = [S[j], S[i]]; }
  let i = 0, j = 0;
  const next = () => { i = (i + 1) & 255; j = (j + S[i]) & 255; [S[i], S[j]] = [S[j], S[i]]; return S[(S[i] + S[j]) & 255]; };
  for (let k = 0; k < 256; k++) next();    // drop256
  return next;
}
const stream = (key, n) => { const g = rc4(key); return Buffer.from(Array.from({ length: n }, g)); };
const xor = (a, b) => Buffer.from(a.map((v, i) => v ^ b[i]));

// RLE: one byte per run, (run-1) << 4 | level, runs of 1..16
function rle(px) {
  const out = [];
  for (let i = 0; i < px.length;) {
    let n = 1;
    while (n < 16 && i + n < px.length && px[i + n] === px[i]) n++;
    out.push(((n - 1) << 4) | px[i]); i += n;
  }
  return Buffer.from(out);
}

export default async ({ dir, gen, root }) => {
  const girl = join(root, 'os', 'assets', 'girl');
  const hi = readFileSync(join(girl, 'panic128.bin')), lo = readFileSync(join(girl, 'panic64.bin'));

  // palette: 16 steps from ink (deep blue-black) to warm paper, a little lilac in the middle
  const pal = [];
  for (let k = 0; k < 16; k++) {
    const t = k / 15, bump = Math.sin(t * Math.PI) * 5;
    pal.push(Math.round(3 + (61 - 3) * t + bump * 0.6), Math.round(3 + (58 - 3) * t), Math.round(9 + (54 - 9) * t + bump));
  }
  const qHi = v => Math.min(15, Math.round(v * 15 / 255));
  const qLo = v => Math.min(15, Math.round(v * 7 / 255) * 2 + (v > 236 ? 1 : 0));   // 8 levels: 0,2..12,15

  const enc = (src, w, f, q) => rle(Array.from(src.subarray(f * w * w, (f + 1) * w * w), q));
  const hiRle = Array.from({ length: CLIP }, (_, f) => enc(hi, 128, f, qHi));
  const loRle = Array.from({ length: CLIP }, (_, f) => enc(lo, 64, f, qLo));

  const ROOT = randomBytes(16), CK = randomBytes(16), KID = randomBytes(8);
  const dkKey = Buffer.from(ROOT); dkKey[15] ^= MODEL;
  const DK = stream(dkKey, 16);
  const KEK = stream(xor(DK, Buffer.concat([KID, KID])), 16);
  const WRAP = xor(CK, KEK), KCV = stream(CK, 4);

  const frames = CLIP * PASSES, INDEX_SECTORS = frames * 64 / 512;
  const header = Buffer.alloc(512), index = Buffer.alloc(INDEX_SECTORS * 512), chunks = [];
  let lba = 1 + INDEX_SECTORS, sumHi = 0, sumLo = 0, maxLen = 0;      // relative to the container start
  const put = (data, iv) => {
    const c = xor(data, stream(xor(CK, iv), data.length));
    const sectors = Math.ceil(c.length / 512), padded = Buffer.alloc(sectors * 512); c.copy(padded);
    chunks.push(padded); const at = lba; lba += sectors; maxLen = Math.max(maxLen, c.length);
    if (c.length > SLOT) throw new Error('frame bigger than a ring slot');
    return at;
  };
  for (let n = 0; n < frames; n++) {
    const e = n * 64, ivH = randomBytes(16), ivL = randomBytes(16), f = n % CLIP;
    index.writeUInt16LE(put(hiRle[f], ivH), e); index.writeUInt16LE(hiRle[f].length, e + 2);
    index.writeUInt16LE(put(loRle[f], ivL), e + 4); index.writeUInt16LE(loRle[f].length, e + 6);
    ivH.copy(index, e + 8); ivL.copy(index, e + 24);
    sumHi += hiRle[f].length; sumLo += loRle[f].length;
  }
  header.write('7MV1', 0, 'latin1');
  header.writeUInt16LE(frames, 4); header.writeUInt16LE(FPS, 6);
  header[8] = 2; header.writeUInt16LE(INDEX_SECTORS, 10);
  header.write('PANIC.7MV'.padEnd(16, '\0'), 12, 'latin1');
  KID.copy(header, 28); WRAP.copy(header, 36); KCV.copy(header, 52);
  header.writeUInt16LE(Math.round(sumHi / frames), 56); header.writeUInt16LE(Math.round(sumLo / frames), 58);
  header.writeUInt16LE(lba, 60);                                       // total sectors
  Buffer.from(pal).copy(header, 64);
  const movie = Buffer.concat([header, index, ...chunks]);
  writeFileSync(join(gen, 'movie.7mv'), movie);

  const hex = b => [...b].map(v => '0x' + v.toString(16).padStart(2, '0')).join(', ');
  writeFileSync(join(gen, 'keys.inc'), `; generated by assets.mjs: the device root key provisioned in this player build\n` +
    `root_key        db ${hex(ROOT)}\nMOVIE_SECTORS   equ ${lba}\nDEV_MODEL       equ 0x${MODEL.toString(16)}\n`);
  console.log(`player   7MV: ${frames} frames, HI avg ${Math.round(sumHi / frames)} B, LO avg ${Math.round(sumLo / frames)} B, max ${maxLen} B, ${movie.length} bytes · KID ${KID.toString('hex')} KCV ${KCV.toString('hex')}`);
};
