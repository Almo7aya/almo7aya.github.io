// test.mjs · boot 7OS headlessly on cpu8086.js, type some commands, print the screen
//   node os/test.mjs [command ...]   (run npm run os first)
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
await import(pathToFileURL(join(here, '..', 'src', 'lib', 'cpu8086.js')).href);   // sets globalThis.X86
const { createMachine, CP437 } = globalThis.X86;

let clock = Date.UTC(2026, 9, 7, 7, 7, 7);           // a fake clock so INT 15h waits pass instantly
const log = [];
const m = createMachine(new Uint8Array(readFileSync(join(here, '..', 'public', 'os', 'almo7aya.img'))), { now: () => clock });
m.hooks.int = (n, msg) => log.push(`INT ${n.toString(16)}h ${msg}`);
m.reset();

function run(limit = 5_000_000) {
  for (let i = 0; i < limit; i++) {
    if (m.fault || m.halted) return;
    if (!m.step()) {
      if (m.waiting === 'time') { clock = m.wakeAt; continue; }
      return;                                         // waiting for a key
    }
  }
  throw new Error('instruction limit hit, ip=' + m.ip.toString(16));
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

run();
const cmds = process.argv.slice(2);
for (const c of cmds) type(c);
console.log(screen());
console.log('---');
console.log(`instructions: ${m.instructions}, ip: ${m.s[1].toString(16)}:${m.ip.toString(16)}, waiting: ${m.waiting}, fault: ${m.fault ? m.fault.name : '-'}`);
console.log(log.slice(0, 6).join('\n'));
