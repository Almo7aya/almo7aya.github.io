// os/test.mjs · boot 7OS headlessly on cpu8086.js, type commands, print the text screen
//   node os/test.mjs [command ...]        (run npm run os first)
// a fake clock drives INT 15h waits and the PIT, so timer interrupts fire like on real hardware
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
await import(pathToFileURL(join(here, '..', 'src', 'lib', 'cpu8086.js')).href);   // sets globalThis.X86
const { createMachine, CP437 } = globalThis.X86;

let clock = Date.UTC(2026, 9, 7, 7, 7, 7);
const log = [];
const m = createMachine(new Uint8Array(readFileSync(join(here, '..', 'public', 'os', 'almo7aya.img'))), { now: () => clock, font: new Uint8Array(readFileSync(join(here, '..', 'public', 'os', 'vgafont.bin'))) });
m.hooks.int = (n, msg) => log.push(`INT ${n.toString(16)}h ${msg}`);
m.reset();

// run until the CPU parks waiting for a key; idle time still advances the clock (and IRQ0)
function run(idleMs = 0, limit = 20_000_000) {
  let idle = 0;
  for (let i = 0; i < limit; i++) {
    if (m.fault) return;
    if (i % 512 === 0) m.tickTimer(clock);
    if (m.step()) continue;
    if (m.waiting === 'time') { clock = m.wakeAt; continue; }
    if (idle >= idleMs) return;                       // parked in INT 16h or HLT
    clock += 5; idle += 5; m.tickTimer(clock);
  }
  throw new Error('instruction limit hit at ' + m.s[1].toString(16) + ':' + m.ip.toString(16));
}
const type = s => { for (const c of s) m.key(c.charCodeAt(0)); m.key(13, 0x1C); run(); };
const screen = () => {
  const rows = [];
  for (let y = 0; y < 25; y++) {
    let line = '';
    for (let x = 0; x < 80; x++) line += CP437[m.mem[0xB8000 + (y * 80 + x) * 2]];
    rows.push(line.replace(/[\s ]+$/, ''));
  }
  return rows.join('\n');
};

run(2500);                                            // boot, then sit at the prompt for 2.5 s of ticks
for (const c of process.argv.slice(2)) {
  if (c === 'demo') {                                 // the demo loops until a key: give it some frames
    for (const ch of 'demo') m.key(ch.charCodeAt(0));
    m.key(13, 0x1C);
    let k = 0;
    for (; k < 5_000_000 && !(m.mode === 0x13 && m.dacVersion > 2000); k++) {
      if (k % 512 === 0) m.tickTimer(clock);
      if (!m.step()) { clock += 1; if (m.waiting === 'time') clock = m.wakeAt; }
      else if (k % 64 === 0) clock += 0.05;           // let the retrace bit move
    }
    let white = 0;
    for (const b of m.mem.subarray(0xA0000, 0xA0000 + 64000)) if (b === 255) white++;
    console.log(`demo: mode ${m.mode.toString(16)}h after ${k} steps, ${white} white font-ROM pixels, ${m.dacVersion} DAC writes`);
    m.key(32, 0x39); run();
    continue;
  }
  type(c);
}
console.log(screen());
console.log('---');
console.log(`instructions ${m.instructions}, IRQ0 delivered ${m.irqs}, ${m.s[1].toString(16)}:${m.ip.toString(16)}, waiting ${m.waiting}, fault ${m.fault ? m.fault.name : '-'}`);
console.log(log.slice(0, 8).join('\n'));
