// os/run.mjs · boot any disk headlessly and script it: keys, mouse, time, screenshots
//   node os/run.mjs <disk-id> [action ...]          (npm run os first)
//
// actions (run in order):
//   wait:MS          let MS milliseconds of machine time pass (the CPU runs at ~40 MIPS of it)
//   type:TEXT        type text; \n is Enter          e.g. "type:dir\n"
//   key:NAME         press and release a key: enter esc space tab bksp up down left right f1..f10 a..z 0..9
//   down:NAME        hold a key (games read make/break codes on IRQ1)     up:NAME releases it
//   mouse:X,Y,B      move the mouse in its 640x200 space, B = buttons (1 left, 2 right)
//   png:FILE         save the screen (text 720x400 or mode 13h 320x200) as a PNG
//   text             print the 80x25 text screen
//   regs             print CPU registers and state
//   speaker          print the PC speaker frequencies played so far
// the machine time is simulated: idle CPUs (INT 16h, HLT, INT 15h waits) skip ahead, so a
// "wait:5000" finishes in well under 5 seconds.
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { deflateSync, crc32 } from 'node:zlib';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
await import(pathToFileURL(join(root, 'src', 'lib', 'cpu8086.js')).href);
const { Frame } = await import(pathToFileURL(join(root, 'src', 'lib', 'vga.js')).href);
const { createMachine, CP437 } = globalThis.X86;

const [id, ...actions] = process.argv.slice(2);
const disks = JSON.parse(readFileSync(join(root, 'public', 'os', 'disks.json'), 'utf8'));
const disk = disks.find(d => d.id === id);
if (!disk) { console.error(`unknown disk "${id}". disks: ${disks.map(d => d.id).join(', ')}`); process.exit(1); }

let clock = Date.UTC(2026, 9, 7, 7, 7, 7);
const MIPS = 40, log = [], tones = [];
const m = createMachine(new Uint8Array(readFileSync(join(root, 'public', 'os', disk.image))), {
  now: () => clock, drive: disk.drive, font: new Uint8Array(readFileSync(join(root, 'public', 'os', 'vgafont.bin'))),
});
m.hooks.int = (n, msg) => log.push(`INT ${n.toString(16)}h ${msg}`);
m.hooks.speaker = hz => tones.push(`${(clock % 100000).toFixed(0)}ms ${hz ? hz.toFixed(0) + ' Hz' : 'off'}`);
m.reset();

function run(ms) {
  const until = clock + ms;
  let n = 0;
  while (clock < until && !m.fault) {
    m.tickTimer(clock);
    if (m.step()) { if (++n % (MIPS * 10) === 0) clock += 0.01; continue; }   // 40 instructions per microsecond
    if (m.waiting === 'time') { clock = Math.min(until, Math.max(m.wakeAt, clock + 0.01)); continue; }
    clock = Math.min(until, clock + Math.max(0.05, m.tickMs / 4));             // idle: jump towards the next tick
  }
}

const SCAN = { esc: [27, 1], bksp: [8, 0x0E], tab: [9, 0x0F], enter: [13, 0x1C], space: [32, 0x39], ctrl: [0, 0x1D], shift: [0, 0x2A], alt: [0, 0x38],
  up: [0, 0x48], down: [0, 0x50], left: [0, 0x4B], right: [0, 0x4D], home: [0, 0x47], end: [0, 0x4F], pgup: [0, 0x49], pgdn: [0, 0x51] };
for (let i = 1; i <= 10; i++) SCAN['f' + i] = [0, 0x3A + i];
const ROWS = ['1234567890-=', 'qwertyuiop[]', "asdfghjkl;'", 'zxcvbnm,./'], ROWBASE = [0x02, 0x10, 0x1E, 0x2C];
ROWS.forEach((row, r) => [...row].forEach((c, i) => { SCAN[c] = [c.charCodeAt(0), ROWBASE[r] + i]; }));
const keyOf = name => {
  const k = SCAN[name.toLowerCase()];
  if (!k) throw new Error(`unknown key ${name}`);
  return name.length === 1 && name !== name.toLowerCase() ? [name.charCodeAt(0), k[1]] : k;
};

function png(file) {
  const f = new Frame(); f.render(m); f.sig = ''; f.frames = 31; f.render(m);   // a frame with the cursor visible
  const { w, h, px } = f, raw = Buffer.alloc((w * 3 + 1) * h);
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
    const v = px[y * w + x], o = y * (w * 3 + 1) + 1 + x * 3;
    raw[o] = v & 0xFF; raw[o + 1] = (v >> 8) & 0xFF; raw[o + 2] = (v >> 16) & 0xFF;
  }
  const chunk = (type, data) => { const len = Buffer.alloc(4); len.writeUInt32BE(data.length); const td = Buffer.concat([Buffer.from(type), data]); const c = Buffer.alloc(4); c.writeUInt32BE(crc32(td)); return Buffer.concat([len, td, c]); };
  const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4); ihdr[8] = 8; ihdr[9] = 2;
  writeFileSync(file, Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', ihdr), chunk('IDAT', deflateSync(raw)), chunk('IEND', Buffer.alloc(0))]));
  console.log(`png: ${file} (${w}x${h}, mode ${m.mode.toString(16)}h)`);
}
const textScreen = () => {
  const out = [];
  for (let y = 0; y < 25; y++) { let l = ''; for (let x = 0; x < 80; x++) l += CP437[m.mem[0xB8000 + (y * 80 + x) * 2]]; out.push(l.replace(/[\s ]+$/, '')); }
  return out.join('\n').replace(/\n+$/, '');
};

run(1500);                                               // power on and boot
for (const a of actions) {
  const [cmd, ...rest] = a.split(':'), arg = rest.join(':');
  if (cmd === 'wait') run(+arg);
  else if (cmd === 'type') for (const c of arg.replace(/\\n/g, '\n')) { if (c === '\n') { m.keyDown(13, 0x1C); run(20); m.keyUp(0x1C); } else { const k = keyOf(c); m.keyDown(c.charCodeAt(0), k[1]); run(20); m.keyUp(k[1]); } run(15); }
  else if (cmd === 'key') { const k = keyOf(arg); m.keyDown(k[0], k[1]); run(40); m.keyUp(k[1]); run(40); }
  else if (cmd === 'down') { const k = keyOf(arg); m.keyDown(k[0], k[1]); run(20); }
  else if (cmd === 'up') { const k = keyOf(arg); m.keyUp(k[1]); run(20); }
  else if (cmd === 'mouse') { const [x, y, b = 0] = arg.split(',').map(Number); m.setMouse(x, y, b); run(30); }
  else if (cmd === 'png') png(arg);
  else if (cmd === 'text') console.log(textScreen());
  else if (cmd === 'regs') console.log(`AX=${m.r[0].toString(16)} BX=${m.r[3].toString(16)} CX=${m.r[1].toString(16)} DX=${m.r[2].toString(16)} SI=${m.r[6].toString(16)} DI=${m.r[7].toString(16)} SP=${m.r[4].toString(16)} CS:IP=${m.s[1].toString(16)}:${m.ip.toString(16)} mode=${m.mode.toString(16)}h waiting=${m.waiting} halted=${m.halted} instructions=${m.instructions} irq0=${m.irqs} irq1=${m.kbdIrqs}`);
  else if (cmd === 'speaker') console.log(tones.slice(-40).join('\n') || '(silent)');
  else throw new Error(`unknown action ${a}`);
  if (m.fault) { console.log(`FAULT ${m.fault.name} at ${m.fault.cs.toString(16)}:${m.fault.ip.toString(16)}`); break; }
}
console.log(`--- ${disk.id}: ${m.instructions} instructions, IRQ0 ${m.irqs}, IRQ1 ${m.kbdIrqs}, ${m.s[1].toString(16)}:${m.ip.toString(16)}${m.fault ? ', fault ' + m.fault.name : ''}`);
if (process.env.LOG) console.log(log.join('\n'));
