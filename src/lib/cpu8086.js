/*
 * cpu8086.js · a small, honest 8086 PC for almo7aya.dev
 *
 * - CPU: the 8086 real-mode instruction set (plus PUSH imm, PUSHA/POPA, shifts by imm8,
 *   IMUL imm and LEAVE from the 186), segment:offset addressing, ModR/M, prefixes,
 *   REP string ops, real interrupt vectoring through the IVT at 0000:0000.
 *   0F 0B (UD2) and unknown opcodes raise #UD and stop the machine for the debugger.
 * - Hardware: the PIT fires IRQ0 at 18.2 Hz into INT 08h, whose BIOS handler is real
 *   machine code in ROM (it counts ticks at 0040:006C and calls INT 1Ch, which programs
 *   hook). VGA: text mode at B800:0000, mode 13h at A000:0000, the DAC palette on ports
 *   3C7h-3C9h, vertical retrace on 3DAh, an 8x16 font ROM at C000:1000.
 * - BIOS: high-level emulated (HLE) INT 10h video, INT 11h/12h, INT 13h disk
 *   (CHS + LBA extensions, read-only), INT 15h/86h wait, INT 16h keyboard,
 *   INT 19h bootstrap, INT 1Ah clock. A vector the program replaces in the IVT is
 *   honoured: the CPU jumps there like real hardware would. The reset vector at
 *   FFFF:0000 is a real far jump.
 *
 * Works in the browser (window.X86) and in Node.
 */
(function (root) {
  'use strict';

  // flag bits
  const CF = 0x0001, PF = 0x0004, AF = 0x0010, ZF = 0x0040, SF = 0x0080, TF = 0x0100, IF = 0x0200, DF = 0x0400, OF = 0x0800;
  // register indices
  const AX = 0, CX = 1, DX = 2, BX = 3, SP = 4, BP = 5, SI = 6, DI = 7;
  const ES = 0, CS = 1, SS = 2, DS = 3;
  const BIOS_SEG = 0xF000;
  // the IBM PC BIOS entry points every compatible BIOS (SeaBIOS too) still uses.
  // each holds an IRET; when a program INTs to one, the BIOS service runs in JavaScript (HLE)
  const ENTRY = { 0x05: 0xFF54, 0x09: 0xE987, 0x11: 0xF84D, 0x12: 0xF841, 0x13: 0xE3FE, 0x14: 0xE739,
    0x15: 0xF859, 0x16: 0xE82E, 0x17: 0xEFD2, 0x19: 0xE6F2, 0x1A: 0xFE6E, 0x1C: 0xFF53 };
  const DUMMY_IRET = 0xFF53;                    // unclaimed vectors point at the dummy IRET, like IBM's
  const VIDEO_SEG = 0xC000, INT10_OFF = 0x0130; // INT 10h lives in the video BIOS
  const INT08_OFF = 0xFEA5, POST_OFF = 0xE05B;  // the timer handler (real code), the POST entry point
  const MOUSE_TRAMP = 0xFED0;                   // after a PS/2 mouse callback: add sp,8 / iret
  const vectorFor = n => n === 0x10 ? [VIDEO_SEG, INT10_OFF] : n === 0x08 ? [BIOS_SEG, INT08_OFF] : [BIOS_SEG, ENTRY[n] ?? DUMMY_IRET];
  const FONT_SEG = 0xC000, FONT_OFF = 0x1000;   // 8x16 font ROM, as INT 10h/1130h reports it
  const TICK_MS = 1000 / 18.2065;               // PIT channel 0 at its BIOS default
  // INT 08h, the way a real BIOS does it: count the tick, call INT 1Ch, EOI the PIC
  const INT08_CODE = [
    0x1E,                   // push ds
    0x50,                   // push ax
    0x31, 0xC0,             // xor ax, ax
    0x8E, 0xD8,             // mov ds, ax
    0xFF, 0x06, 0x6C, 0x04, // inc word [046Ch]
    0x75, 0x04,             // jnz +4
    0xFF, 0x06, 0x6E, 0x04, // inc word [046Eh]
    0xCD, 0x1C,             // int 1Ch
    0xB0, 0x20,             // mov al, 20h
    0xE6, 0x20,             // out 20h, al
    0x58,                   // pop ax
    0x1F,                   // pop ds
    0xCF,                   // iret
  ];

  // the VGA's default 256-colour DAC palette (6 bits per channel)
  // what the VGA BIOS loads for text modes: the 64 EGA colours (bits rgbRGB), repeated 4 times.
  // the attribute controller then maps text colours 0-15 to DAC entries 0-5, 14h, 7, 38h-3Fh
  function textPalette() {
    const p = new Uint8Array(768);
    for (let i = 0; i < 256; i++) {
      const c = i & 63;
      p.set([(c & 4 ? 42 : 0) + (c & 32 ? 21 : 0), (c & 2 ? 42 : 0) + (c & 16 ? 21 : 0), (c & 1 ? 42 : 0) + (c & 8 ? 21 : 0)], i * 3);
    }
    return p;
  }
  function defaultPalette() {
    const p = new Uint8Array(768);
    const ega = [0, 0, 0, 0, 0, 42, 0, 42, 0, 0, 42, 42, 42, 0, 0, 42, 0, 42, 42, 21, 0, 42, 42, 42,
      21, 21, 21, 21, 21, 63, 21, 63, 21, 21, 63, 63, 63, 21, 21, 63, 21, 63, 63, 63, 21, 63, 63, 63];
    p.set(ega);
    const grey = [0, 5, 8, 11, 14, 17, 20, 24, 28, 32, 36, 40, 45, 50, 56, 63];
    grey.forEach((g, i) => p.set([g, g, g], (16 + i) * 3));
    let i = 32;
    for (const [hi, lo] of [[63, 0], [63, 31], [63, 45], [28, 0], [28, 14], [28, 20], [16, 0], [16, 8], [16, 11]]) {
      const ramp = [lo, lo + (hi - lo) / 4, lo + (hi - lo) / 2, lo + 3 * (hi - lo) / 4, hi].map(Math.round);
      const seq = [];       // walk the colour wheel: blue -> magenta -> red -> yellow -> green -> cyan -> blue
      for (let k = 0; k < 4; k++) seq.push([ramp[k], lo, hi]);
      for (let k = 4; k > 0; k--) seq.push([hi, lo, ramp[k]]);
      for (let k = 0; k < 4; k++) seq.push([hi, ramp[k], lo]);
      for (let k = 4; k > 0; k--) seq.push([ramp[k], hi, lo]);
      for (let k = 0; k < 4; k++) seq.push([lo, hi, ramp[k]]);
      for (let k = 4; k > 0; k--) seq.push([lo, ramp[k], hi]);
      for (const c of seq) { if (i < 248) p.set(c, i * 3); i++; }
    }
    return p;
  }

  const PARITY = new Uint8Array(256);
  for (let i = 0; i < 256; i++) { let b = i, p = 1; while (b) { p ^= b & 1; b >>= 1; } PARITY[i] = p; }

  function createMachine(image, opts = {}) {
    const mem = new Uint8Array(0x100000 + 0x10000);  // +64K so FFFF:FFFF doesn't fall off
    const r = new Uint16Array(8);       // AX CX DX BX SP BP SI DI
    const s = new Uint16Array(4);       // ES CS SS DS
    const m = {
      mem, r, s, ip: 0, flags: 0x0002, image: image || new Uint8Array(512),
      halted: false, fault: null, waiting: null, wakeAt: 0, instructions: 0,
      keys: [], hooks: { int: null, reboot: null }, now: opts.now || (() => Date.now()),
      drive: opts.drive === 'floppy' ? 0x00 : 0x80,
      geometry: opts.drive === 'floppy' ? { heads: 2, spt: 18, cyls: 80 } : { heads: 16, spt: 63 },
      irqPending: 0, irqs: 0, lastTick: null, kbdIrqs: 0,
      dac: textPalette(), dacVersion: 0, font: opts.font || new Uint8Array(4096),
      // the debugger's view: when each byte was last written (in m.wtick units) and the last 64 CS:IPs
      wstamp: new Uint32Array(0x100000), wtick: 1, trail: new Uint32Array(64), trailPos: 0,
      mouse: { x: 320, y: 100, buttons: 0, shown: 0, minX: 0, maxX: 639, minY: 0, maxY: 199, installed: false },
      ps2: { enabled: false, cbSeg: 0, cbOff: 0, dx: 0, dy: 0, dirty: false, last: 0 },
      speakerHz: 0,
    };
    let dacW = 0, dacC = 0, dacR = 0, dacRC = 0, retraceToggle = 0, lastScan = 0;
    // 8253 PIT: channel reload values, access state, latches; 8259 PIC mask; port 61h; CMOS index
    const pit = [0, 1, 2].map(() => ({ reload: 0x10000, rw: 3, flip: 0, latched: null, lo: 0, start: 0 }));
    let picMask = 0, port61 = 0, cmosIndex = 0;
    const kbdQueue = [];                        // scancodes waiting for IRQ1 (when a program hooks INT 09h)
    let irq1Pending = 0;

    // ---------- memory ----------
    const lin = (seg, off) => ((seg << 4) + (off & 0xFFFF)) & 0xFFFFF;
    const rb = a => mem[a & 0xFFFFF];
    const wstamp = m.wstamp;
    const wb = (a, v) => { a &= 0xFFFFF; if (a >= 0xC0000) return; mem[a] = v & 0xFF; wstamp[a] = m.wtick; };  // video BIOS + BIOS ROM are read-only
    const rw = a => rb(a) | (rb(a + 1) << 8);
    const ww = (a, v) => { wb(a, v); wb(a + 1, v >> 8); };
    m.rb = rb; m.rw = rw; m.lin = lin;

    // ---------- registers ----------
    const r8 = i => i < 4 ? r[i] & 0xFF : r[i - 4] >> 8;
    const w8 = (i, v) => { v &= 0xFF; if (i < 4) r[i] = (r[i] & 0xFF00) | v; else r[i - 4] = (r[i - 4] & 0x00FF) | (v << 8); };
    const getF = f => (m.flags & f) !== 0;
    const setF = (f, on) => { m.flags = on ? m.flags | f : m.flags & ~f; };

    // ---------- fetch / decode state ----------
    let segOvr = -1, rep = 0, opStart = 0, opSeg = 0;
    const fetch8 = () => { const v = rb(lin(s[CS], m.ip)); m.ip = (m.ip + 1) & 0xFFFF; return v; };
    const fetch16 = () => { const lo = fetch8(); return lo | (fetch8() << 8); };
    const sx8 = v => (v & 0x80 ? v - 0x100 : v);

    let mod = 0, reg = 0, rm = 0, ea = 0, eaOff = 0;
    function modrm() {
      const b = fetch8(); mod = b >> 6; reg = (b >> 3) & 7; rm = b & 7;
      if (mod === 3) { ea = -1; return; }
      let off, seg = DS;
      switch (rm) {
        case 0: off = r[BX] + r[SI]; break;
        case 1: off = r[BX] + r[DI]; break;
        case 2: off = r[BP] + r[SI]; seg = SS; break;
        case 3: off = r[BP] + r[DI]; seg = SS; break;
        case 4: off = r[SI]; break;
        case 5: off = r[DI]; break;
        case 6: if (mod === 0) { off = fetch16(); } else { off = r[BP]; seg = SS; } break;
        default: off = r[BX];
      }
      if (mod === 1) off += sx8(fetch8()); else if (mod === 2) off += fetch16();
      eaOff = off & 0xFFFF;
      ea = lin(s[segOvr >= 0 ? segOvr : seg], eaOff);
    }
    const getRM8 = () => (ea < 0 ? r8(rm) : rb(ea));
    const setRM8 = v => (ea < 0 ? w8(rm, v) : wb(ea, v));
    const getRM16 = () => (ea < 0 ? r[rm] : rw(ea));
    const setRM16 = v => (ea < 0 ? (r[rm] = v) : ww(ea, v));
    const dataSeg = () => s[segOvr >= 0 ? segOvr : DS];

    // ---------- stack ----------
    const push = v => { r[SP] = (r[SP] - 2) & 0xFFFF; ww(lin(s[SS], r[SP]), v); };
    const pop = () => { const v = rw(lin(s[SS], r[SP])); r[SP] = (r[SP] + 2) & 0xFFFF; return v; };

    // ---------- flags ----------
    function szp(v, w) {
      const mask = w ? 0xFFFF : 0xFF;
      v &= mask;
      setF(ZF, v === 0); setF(SF, v & (w ? 0x8000 : 0x80)); setF(PF, PARITY[v & 0xFF]);
    }
    function alu(op, a, b, w) {
      const mask = w ? 0xFFFF : 0xFF, sign = w ? 0x8000 : 0x80;
      let res;
      switch (op) {
        case 0: case 2: {               // ADD, ADC
          const c = op === 2 && getF(CF) ? 1 : 0;
          res = a + b + c;
          setF(CF, res > mask); setF(OF, ((a ^ res) & (b ^ res) & sign) !== 0); setF(AF, ((a ^ b ^ res) & 0x10) !== 0);
          break;
        }
        case 3: case 5: case 7: {       // SBB, SUB, CMP
          const c = op === 3 && getF(CF) ? 1 : 0;
          res = a - b - c;
          setF(CF, res < 0); setF(OF, ((a ^ b) & (a ^ res) & sign) !== 0); setF(AF, ((a ^ b ^ res) & 0x10) !== 0);
          break;
        }
        case 1: res = a | b; setF(CF, 0); setF(OF, 0); setF(AF, 0); break;
        case 4: res = a & b; setF(CF, 0); setF(OF, 0); setF(AF, 0); break;
        case 6: res = a ^ b; setF(CF, 0); setF(OF, 0); setF(AF, 0); break;
      }
      res &= mask; szp(res, w);
      return res;
    }
    function incdec(v, dec, w) {
      const mask = w ? 0xFFFF : 0xFF, sign = w ? 0x8000 : 0x80;
      const res = (dec ? v - 1 : v + 1) & mask;
      setF(OF, dec ? v === sign : res === sign); setF(AF, ((v ^ 1 ^ res) & 0x10) !== 0); szp(res, w);
      return res;
    }
    function shift(op, v, count, w) {
      const bits = w ? 16 : 8, mask = w ? 0xFFFF : 0xFF, sign = w ? 0x8000 : 0x80;
      if (count === 0) return v;
      const origMsb = (v & sign) !== 0;
      let cf = getF(CF) ? 1 : 0;
      for (let i = 0; i < count; i++) {
        switch (op) {
          case 0: cf = (v & sign) ? 1 : 0; v = ((v << 1) | cf) & mask; break;                    // ROL
          case 1: cf = v & 1; v = (v >> 1) | (cf ? sign : 0); break;                              // ROR
          case 2: { const out = (v & sign) ? 1 : 0; v = ((v << 1) | cf) & mask; cf = out; break; } // RCL
          case 3: { const out = v & 1; v = (v >> 1) | (cf ? sign : 0); cf = out; break; }          // RCR
          case 4: case 6: cf = (v & sign) ? 1 : 0; v = (v << 1) & mask; break;                     // SHL/SAL
          case 5: cf = v & 1; v >>= 1; break;                                                     // SHR
          case 7: cf = v & 1; v = (v >> 1) | (v & sign); break;                                   // SAR
        }
      }
      setF(CF, cf);
      const msb = (v & sign) !== 0;
      if (op === 0 || op === 2 || op === 4 || op === 6) setF(OF, msb !== !!cf);
      else if (op === 1 || op === 3) setF(OF, msb !== !!(v & (sign >> 1)));
      else if (op === 5) setF(OF, origMsb);
      else setF(OF, 0);
      if (op >= 4) szp(v, w);
      void bits;
      return v;
    }

    // ---------- interrupts ----------
    function vectorIsBios(n) {
      if (n === 0x08) return false;               // the timer handler is real code: execute it
      const [seg, off] = vectorFor(n);
      return rw(n * 4 + 2) === seg && rw(n * 4) === off;
    }
    function interrupt(n, retIp) {
      if (vectorIsBios(n)) {
        const res = bios(n);
        if (res === 'wait-key') { m.ip = opStart; m.waiting = 'key'; return; }   // re-run INT when a key arrives
        if (res === 'wait-time') { m.waiting = 'time'; return; }
        return;
      }
      push(m.flags); push(s[CS]); push(retIp);
      setF(IF, 0); setF(TF, 0);
      m.ip = rw(n * 4); s[CS] = rw(n * 4 + 2);
    }
    function fault(name) {
      m.fault = { name, cs: s[CS], ip: opStart };
      m.ip = opStart;
    }

    // ---------- I/O ports ----------
    function portIn(p) {
      switch (p) {
        case 0x3DA: {               // VGA input status 1: bit 3 = vertical retrace (70 Hz), bit 0 toggles
          const t = m.now() % (1000 / 70);
          retraceToggle ^= 1;
          return (t > (1000 / 70) * 0.9 ? 0x08 : 0) | retraceToggle;
        }
        case 0x3C9: { const v = m.dac[dacR * 3 + dacRC]; if (++dacRC === 3) { dacRC = 0; dacR = (dacR + 1) & 0xFF; } return v; }
        case 0x40: case 0x41: case 0x42: return pitRead(p - 0x40);
        case 0x60: kbdFull = 0; return lastScan;    // keyboard data
        case 0x64: return 0x14 | kbdFull;           // keyboard status: system flag, key lock, output buffer full
        case 0x61: refresh ^= 0x10; return (port61 & 0x0F) | refresh | 0x20;
        case 0x20: return 0;                        // PIC IRR/ISR: nothing in service
        case 0x21: return picMask;
        case 0x71: return cmosRead(cmosIndex);
        default: return 0xFF;
      }
    }
    function portOut(p, v) {
      v &= 0xFF;
      switch (p) {
        case 0x3C8: dacW = v; dacC = 0; return;     // DAC write index
        case 0x3C7: dacR = v; dacRC = 0; return;    // DAC read index
        case 0x3C9: m.dac[dacW * 3 + dacC] = v & 0x3F; if (++dacC === 3) { dacC = 0; dacW = (dacW + 1) & 0xFF; } m.dacVersion++; return;
        case 0x43: {                                // PIT mode/command
          const ch = v >> 6, rwm = (v >> 4) & 3;
          if (ch === 3) return;                     // read-back: not on an 8253
          if (rwm === 0) { pit[ch].latched = pitCount(ch); pit[ch].flip = 0; return; }
          pit[ch].rw = rwm; pit[ch].flip = 0; return;
        }
        case 0x40: case 0x41: case 0x42: pitWrite(p - 0x40, v); return;
        case 0x61: port61 = v; speaker(); return;   // bit 0 gates PIT channel 2, bit 1 enables the speaker
        case 0x20:                                  // PIC: ICW1 starts initialisation, anything else is OCW2/3 (EOI)
          if (v & 0x10) { icw = 2; icw4 = v & 1; single = v & 2; picMask = 0; }
          return;
        case 0x21:
          if (icw === 2) { m.irqBase = v & 0xF8; icw = single ? (icw4 ? 4 : 0) : 3; return; }
          if (icw === 3) { icw = icw4 ? 4 : 0; return; }
          if (icw === 4) { icw = 0; return; }
          picMask = v; return;
        case 0x70: cmosIndex = v & 0x7F; return;
        default: return;                            // keyboard commands, DMA, POST codes: accepted, ignored
      }
    }
    let kbdFull = 0, refresh = 0, icw = 0, icw4 = 0, single = 0;
    m.irqBase = 0x08;

    // 8253 PIT at 1.193182 MHz
    const PIT_HZ = 1193182;
    const pitCount = ch => { const t = pit[ch]; const el = Math.floor((m.now() - t.start) * PIT_HZ / 1000); return (t.reload - (el % t.reload)) & 0xFFFF; };
    function pitRead(ch) {
      const t = pit[ch], v = t.latched ?? pitCount(ch);
      if (t.rw === 1) { t.latched = null; return v & 0xFF; }
      if (t.rw === 2) { t.latched = null; return v >> 8; }
      t.flip ^= 1;
      if (!t.flip) t.latched = null;
      return t.flip ? v & 0xFF : v >> 8;
    }
    function pitWrite(ch, v) {
      const t = pit[ch];
      if (t.rw === 1) t.lo = v, t.reload = v || 0x100;
      else if (t.rw === 2) t.reload = (v << 8) || 0x10000;
      else if (!t.flip) { t.lo = v; t.flip = 1; return; }
      else { t.flip = 0; t.reload = (t.lo | (v << 8)) || 0x10000; }
      t.start = m.now();
      if (ch === 0) { m.tickMs = t.reload * 1000 / PIT_HZ; m.hooks.pit && m.hooks.pit(PIT_HZ / t.reload); }
      if (ch === 2) speaker();
    }
    function speaker() {                         // channel 2 square wave out to the speaker
      const hz = (port61 & 3) === 3 ? PIT_HZ / pit[2].reload : 0;
      if (hz !== m.speakerHz) { m.speakerHz = hz; m.hooks.speaker && m.hooks.speaker(hz); }
    }
    function cmosRead(i) {                       // MC146818 RTC, BCD, 24-hour
      const d = new Date(m.now());
      switch (i) {
        case 0x00: return bcd(d.getSeconds()); case 0x02: return bcd(d.getMinutes()); case 0x04: return bcd(d.getHours());
        case 0x06: return d.getDay() + 1; case 0x07: return bcd(d.getDate()); case 0x08: return bcd(d.getMonth() + 1);
        case 0x09: return bcd(d.getFullYear() % 100); case 0x32: return bcd(Math.floor(d.getFullYear() / 100));
        case 0x0A: return 0x26; case 0x0B: return 0x02; case 0x0D: return 0x80;
        case 0x10: return 0x40;                    // floppy types: drive 0 = 1.44 MB
        case 0x14: return 0x21;                    // equipment: one floppy, colour 80 columns
        case 0x15: return 0x80; case 0x16: return 0x02;   // base memory 640K
        default: return 0;
      }
    }
    m.portIn = portIn; m.portOut = portOut;

    // ---------- the BIOS (HLE) ----------
    const COLS = 80, ROWS = 25, VRAM = 0xB8000;
    const curPos = () => ({ col: mem[0x450], row: mem[0x451] });
    const setCur = (row, col) => { mem[0x450] = col; mem[0x451] = row; };
    const cell = (row, col) => VRAM + (row * COLS + col) * 2;
    function scrollUp(lines, attr, top, left, bottom, right) {
      const h = bottom - top + 1;
      if (lines === 0 || lines > h) lines = h;
      for (let y = top; y <= bottom; y++)
        for (let x = left; x <= right; x++) {
          const from = y + lines;
          if (from <= bottom) { mem[cell(y, x)] = mem[cell(from, x)]; mem[cell(y, x) + 1] = mem[cell(from, x) + 1]; }
          else { mem[cell(y, x)] = 0x20; mem[cell(y, x) + 1] = attr; }
        }
    }
    function scrollDown(lines, attr, top, left, bottom, right) {
      const h = bottom - top + 1;
      if (lines === 0 || lines > h) lines = h;
      for (let y = bottom; y >= top; y--)
        for (let x = left; x <= right; x++) {
          const from = y - lines;
          if (from >= top) { mem[cell(y, x)] = mem[cell(from, x)]; mem[cell(y, x) + 1] = mem[cell(from, x) + 1]; }
          else { mem[cell(y, x)] = 0x20; mem[cell(y, x) + 1] = attr; }
        }
    }
    function clearScreen() { for (let i = 0; i < COLS * ROWS; i++) { mem[VRAM + i * 2] = 0x20; mem[VRAM + i * 2 + 1] = 0x07; } setCur(0, 0); }
    function teletype(ch) {
      let { row, col } = curPos();
      if (ch === 0x0D) col = 0;
      else if (ch === 0x0A) row++;
      else if (ch === 0x08) { if (col > 0) col--; }
      else if (ch === 0x07) { /* bell */ }
      else { mem[cell(row, col)] = ch; col++; if (col >= COLS) { col = 0; row++; } }
      if (row >= ROWS) { scrollUp(1, 0x07, 0, 0, ROWS - 1, COLS - 1); row = ROWS - 1; }
      setCur(row, col);
    }
    m.print = (str, attr) => { for (const c of str) { const { row, col } = curPos(); if (attr !== undefined && c >= ' ') mem[cell(row, col) + 1] = attr; teletype(c.charCodeAt(0)); } };

    function diskRead(lba, count, seg, off) {
      for (let i = 0; i < count * 512; i++) {
        const src = lba * 512 + i;
        wb(lin(seg, off + i), src < m.image.length ? m.image[src] : 0);
      }
    }
    function diskWrite(lba, count, seg, off) {     // writes land in this session's copy of the image
      for (let i = 0; i < count * 512; i++) {
        const dst = lba * 512 + i;
        if (dst < m.image.length) m.image[dst] = rb(lin(seg, off + i));
      }
      m.diskWrites = (m.diskWrites || 0) + count;
    }
    const bcd = v => ((v / 10) | 0) << 4 | (v % 10);
    const note = (n, msg, extra) => m.hooks.int && m.hooks.int(n, msg, extra);

    function bios(n) {
      const ah = r[AX] >> 8, al = r[AX] & 0xFF;
      switch (n) {
        case 0x10: switch (ah) {
          case 0x00: {
            const mode = al & 0x7F;
            if (mode === 0x13) { if (!(al & 0x80)) mem.fill(0, 0xA0000, 0xA0000 + 64000); m.dac.set(defaultPalette()); m.dacVersion++; }
            else { if (!(al & 0x80)) clearScreen(); m.dac.set(textPalette()); m.dacVersion++; }
            mem[0x449] = mode === 0x13 ? 0x13 : 0x03;
            note(n, `AH=00h set video mode ${mode.toString(16).padStart(2, '0')}h${mode === 0x13 ? ' (320x200x256, A000:0000)' : ' (80x25 text, B800:0000)'}`);
            return;
          }
          case 0x0C: if (mem[0x449] === 0x13 && r[CX] < 320 && r[DX] < 200) mem[0xA0000 + r[DX] * 320 + r[CX]] = al; return;
          case 0x0D: if (mem[0x449] === 0x13) w8(0, mem[0xA0000 + (r[DX] % 200) * 320 + (r[CX] % 320)]); return;
          case 0x10:                                // DAC registers
            if (al === 0x10) { m.dac.set([r[DX] >> 8 & 63, r[CX] >> 8 & 63, r[CX] & 63], (r[BX] & 0xFF) * 3); m.dacVersion++; }
            else if (al === 0x12) { for (let i = 0; i < r[CX]; i++) for (let c = 0; c < 3; c++) m.dac[((r[BX] + i) & 0xFF) * 3 + c] = rb(lin(s[ES], r[DX] + i * 3 + c)) & 63; m.dacVersion++; }
            else if (al === 0x15) { const b = (r[BX] & 0xFF) * 3; r[DX] = (r[DX] & 0xFF) | (m.dac[b] << 8); r[CX] = (m.dac[b + 1] << 8) | m.dac[b + 2]; }
            return;
          case 0x11:                                // character generator
            if (al === 0x30) { s[ES] = FONT_SEG; r[BP] = FONT_OFF; r[CX] = 16; r[DX] = (r[DX] & 0xFF00) | 24; note(n, 'AX=1130h font ROM → C000:1000 (8x16)'); }
            return;
          case 0x12: if ((r[BX] & 0xFF) === 0x10) r[BX] = 0x0003; return;   // EGA/VGA info: colour, 256K
          case 0x1A: if (al === 0x00) { r[AX] = (r[AX] & 0xFF00) | 0x1A; r[BX] = 0x0008; } return;  // display: VGA colour
          case 0x01: mem[0x460] = r[CX] & 0xFF; mem[0x461] = r[CX] >> 8; return;
          case 0x02: setCur(r[DX] >> 8, r[DX] & 0xFF); return;
          case 0x03: { const { row, col } = curPos(); r[DX] = (row << 8) | col; r[CX] = (mem[0x461] << 8) | mem[0x460]; return; }
          case 0x05: return;
          case 0x06: case 0x07: {
            const f = ah === 6 ? scrollUp : scrollDown;
            f(al, r[BX] >> 8, r[CX] >> 8, r[CX] & 0xFF, Math.min(ROWS - 1, r[DX] >> 8), Math.min(COLS - 1, r[DX] & 0xFF));
            return;
          }
          case 0x08: { const { row, col } = curPos(); r[AX] = (mem[cell(row, col) + 1] << 8) | mem[cell(row, col)]; return; }
          case 0x09: case 0x0A: {
            const { row, col } = curPos(); let p = row * COLS + col;
            for (let i = 0; i < r[CX] && p < COLS * ROWS; i++, p++) { mem[VRAM + p * 2] = al; if (ah === 9) mem[VRAM + p * 2 + 1] = r[BX] & 0xFF; }
            return;
          }
          case 0x0E: teletype(al); return;
          case 0x0F: r[AX] = (COLS << 8) | mem[0x449]; r[BX] &= 0x00FF; return;
          case 0x13: {
            let { row, col } = curPos();
            const save = { row, col };
            setCur(r[DX] >> 8, r[DX] & 0xFF);
            for (let i = 0; i < r[CX]; i++) {
              const a = lin(s[ES], r[BP] + i * (al & 2 ? 2 : 1));
              const c = rb(a), at = al & 2 ? rb(a + 1) : r[BX] & 0xFF;
              const p = curPos(); if (c >= 0x20) mem[cell(p.row, p.col) + 1] = at;
              teletype(c);
            }
            if (!(al & 1)) setCur(save.row, save.col);
            return;
          }
          default: return;
        }
        case 0x11: r[AX] = 0x0021; return;
        case 0x12: r[AX] = 640; return;
        case 0x13: {
          const drive = r[DX] & 0xFF, g = m.geometry, floppy = m.drive < 0x80;
          const fail = code => { r[AX] = (code << 8) | (r[AX] & 0xFF); setF(CF, 1); mem[floppy ? 0x441 : 0x474] = code; };
          const ok = () => { r[AX] &= 0x00FF; setF(CF, 0); mem[floppy ? 0x441 : 0x474] = 0; };
          if (drive !== m.drive) { fail(0x01); return; }                   // only the boot disk is attached
          const total = Math.floor(m.image.length / 512);
          const chs = () => {
            const cyl = (r[CX] >> 8) | ((r[CX] & 0xC0) << 2), sec = r[CX] & 0x3F, head = r[DX] >> 8;
            return sec === 0 || sec > g.spt || head >= g.heads ? -1 : (cyl * g.heads + head) * g.spt + (sec - 1);
          };
          switch (ah) {
            case 0x00: case 0x0C: case 0x0D: case 0x10: case 0x11: case 0x16: case 0x17: ok(); return;
            case 0x01: r[AX] = (r[AX] & 0xFF) | (mem[floppy ? 0x441 : 0x474] << 8); setF(CF, 0); return;
            case 0x02: case 0x03: case 0x04: {
              const lba = chs();
              if (lba < 0 || lba + al > total) { fail(0x04); return; }
              if (ah === 0x02) diskRead(lba, al, s[ES], r[BX]);
              if (ah === 0x03) diskWrite(lba, al, s[ES], r[BX]);
              note(n, `AH=${ah.toString(16).padStart(2, '0')}h ${['', '', 'read', 'write', 'verify'][ah]} ${al} sector(s), LBA ${lba} ↔ ${s[ES].toString(16).padStart(4, '0')}:${r[BX].toString(16).padStart(4, '0')}`, { lba, count: al });
              ok(); r[AX] = al; return;
            }
            case 0x05: ok(); return;                                      // format track: pretend
            case 0x08:
              if (floppy) { r[BX] = (r[BX] & 0xFF00) | 0x04; r[CX] = (79 << 8) | 18; r[DX] = 0x0101; s[ES] = BIOS_SEG; r[DI] = 0xEFC7; }
              else {
                const cyls = Math.max(1, Math.ceil(total / (g.heads * g.spt))) - 1;
                r[CX] = ((cyls & 0xFF) << 8) | ((cyls >> 2) & 0xC0) | g.spt; r[DX] = ((g.heads - 1) << 8) | 1;
              }
              ok(); return;
            case 0x15: setF(CF, 0); if (floppy) r[AX] = 0x0200 | (r[AX] & 0xFF); else { r[AX] = 0x0300 | (r[AX] & 0xFF); r[CX] = total >>> 16; r[DX] = total & 0xFFFF; } return;
            case 0x18: s[ES] = BIOS_SEG; r[DI] = 0xEFC7; ok(); return;
            case 0x41: if (!floppy && r[BX] === 0x55AA) { r[BX] = 0xAA55; r[CX] = 1; r[AX] = 0x2100; setF(CF, 0); return; } fail(0x01); return;
            case 0x42: case 0x43: {
              const pk = lin(s[DS], r[SI]);
              const count = rw(pk + 2), off = rw(pk + 4), seg = rw(pk + 6), lba = rw(pk + 8) + rw(pk + 10) * 0x10000;
              if (lba + count > total) { fail(0x04); return; }
              if (ah === 0x42) diskRead(lba, count, seg, off); else diskWrite(lba, count, seg, off);
              note(n, `AH=${ah.toString(16)}h ${ah === 0x42 ? 'read' : 'write'} ${count} sector(s), LBA ${lba}`, { lba, count });
              ok(); return;
            }
            default: fail(0x01); return;
          }
        }
        case 0x15:
          if (ah === 0x86) { m.wakeAt = m.now() + ((r[CX] << 16) | r[DX]) / 1000; setF(CF, 0); return 'wait-time'; }
          if (ah === 0x88) { r[AX] = 0; setF(CF, 0); return; }
          if (ah === 0x4F) { setF(CF, 1); return; }                       // keyboard intercept: pass the key on
          if (ah === 0xC2) {                                              // PS/2 pointing device BIOS interface
            const ps = m.ps2, bh = r[BX] >> 8;
            const done = (ret = 0) => { r[AX] = (r[AX] & 0x00FF) | (ret << 8); setF(CF, ret !== 0); };
            switch (al) {
              case 0x00: ps.enabled = bh === 1; ps.dx = ps.dy = 0; note(n, `AX=C200h mouse ${ps.enabled ? 'enabled' : 'disabled'}`); return done();
              case 0x01: ps.enabled = false; r[BX] = 0x00AA; return done();         // reset: BAT ok, device id 0
              case 0x02: case 0x03: case 0x05: case 0x06: if (al === 0x06 && bh === 0) { r[BX] = 0; r[CX] = 0x02; r[DX] = 100; } return done();
              case 0x04: r[BX] = r[BX] & 0x00FF; return done();                    // device type 0: standard PS/2
              case 0x07: ps.cbSeg = s[ES]; ps.cbOff = r[BX]; note(n, `AX=C207h mouse handler → ${s[ES].toString(16).padStart(4, '0')}:${r[BX].toString(16).padStart(4, '0')}`); return done();
              default: return done(1);
            }
          }
          if (ah === 0x90 || ah === 0x91) { r[AX] &= 0x00FF; setF(CF, 0); return; }
          r[AX] = (r[AX] & 0x00FF) | 0x8600; setF(CF, 1); return;
        case 0x16:
          if (ah === 0x00 || ah === 0x10) {
            if (!m.keys.length) return 'wait-key';
            r[AX] = m.keys.shift(); return;
          }
          if (ah === 0x01 || ah === 0x11) { if (m.keys.length) { r[AX] = m.keys[0]; setF(ZF, 0); } else setF(ZF, 1); return; }
          if (ah === 0x02 || ah === 0x12) { r[AX] = (r[AX] & 0xFF00) | mem[0x417]; return; }
          if (ah === 0x05) { m.keys.push(r[CX]); r[AX] &= 0xFF00; return; }
          if (ah === 0x03) return;
          return;
        case 0x33: {                                  // the mouse driver (HLE): positions in a 640x200 virtual screen
          const ms = m.mouse, ax = r[AX];
          switch (ax) {
            case 0x00: case 0x21: ms.installed = true; ms.shown = 0; ms.minX = 0; ms.maxX = 639; ms.minY = 0; ms.maxY = 199; r[AX] = 0xFFFF; r[BX] = 2; note(n, 'AX=0000h mouse reset: 2 buttons'); return;
            case 0x01: ms.shown++; return;
            case 0x02: ms.shown--; return;
            case 0x03: r[BX] = ms.buttons; r[CX] = Math.max(ms.minX, Math.min(ms.maxX, ms.x)); r[DX] = Math.max(ms.minY, Math.min(ms.maxY, ms.y)); return;
            case 0x04: ms.x = r[CX]; ms.y = r[DX]; return;
            case 0x05: case 0x06: r[AX] = ms.buttons; r[BX] = 0; r[CX] = ms.x; r[DX] = ms.y; return;
            case 0x07: ms.minX = Math.min(r[CX], r[DX]); ms.maxX = Math.max(r[CX], r[DX]); return;
            case 0x08: ms.minY = Math.min(r[CX], r[DX]); ms.maxY = Math.max(r[CX], r[DX]); return;
            case 0x0B: r[CX] = 0; r[DX] = 0; return;
            case 0x24: r[BX] = 0x0626; r[CX] = 0x0400; return;   // driver 6.26, PS/2 mouse
            default: return;
          }
        }
        case 0x19: note(n, 'bootstrap: reboot'); m.reset(); return;
        case 0x1C: return;                          // user timer tick: nothing by default
        case 0x1A: {
          const d = new Date(m.now());
          if (ah === 0x00) {
            const secs = d.getHours() * 3600 + d.getMinutes() * 60 + d.getSeconds() + d.getMilliseconds() / 1000;
            const t = Math.floor(secs * 18.2065); r[CX] = t >>> 16; r[DX] = t & 0xFFFF; r[AX] &= 0xFF00; return;
          }
          if (ah === 0x02) { r[CX] = (bcd(d.getHours()) << 8) | bcd(d.getMinutes()); r[DX] = bcd(d.getSeconds()) << 8; setF(CF, 0); return; }
          if (ah === 0x04) { r[CX] = (bcd(Math.floor(d.getFullYear() / 100)) << 8) | bcd(d.getFullYear() % 100); r[DX] = (bcd(d.getMonth() + 1) << 8) | bcd(d.getDate()); setF(CF, 0); return; }
          return;
        }
        default:
          note(n, `INT ${n.toString(16).padStart(2, '0')}h AH=${ah.toString(16).padStart(2, '0')}h (no BIOS handler)`);
          return;
      }
    }

    // ---------- reset / boot ----------
    m.reset = function () {
      mem.fill(0);
      for (let n = 0; n < 256; n++) { const [seg, off] = vectorFor(n); ww(n * 4, off); ww(n * 4 + 2, seg); mem[lin(seg, off)] = 0xCF; }  // IVT -> IRETs at the entry points
      mem[0x410] = 0x21; mem[0x413] = 0x80; mem[0x414] = 0x02;   // equipment, 640K
      mem[0x449] = 0x03; mem[0x44A] = 80;                        // video mode 3, 80 columns
      mem[0x460] = 0x0E; mem[0x461] = 0x0D;                      // underline cursor
      // ROM: the timer handler, the font, the reset vector, the BIOS date and model byte
      mem.set(INT08_CODE, lin(BIOS_SEG, INT08_OFF));
      mem.set([0x83, 0xC4, 0x08, 0xCF], lin(BIOS_SEG, MOUSE_TRAMP));   // add sp, 8 / iret
      Object.assign(m.ps2, { enabled: false, cbSeg: 0, cbOff: 0, dx: 0, dy: 0, dirty: false, last: 0 });
      ww(8 * 4, INT08_OFF); ww(8 * 4 + 2, BIOS_SEG);
      mem.set(m.font, lin(FONT_SEG, FONT_OFF));
      mem.set([0xCD, 0x19], lin(BIOS_SEG, POST_OFF));            // POST entry: INT 19h, boot again
      mem.set([0xEA, POST_OFF & 0xFF, POST_OFF >> 8, 0x00, 0xF0], 0xFFFF0);  // FFFF:0000 jmp F000:E05B
      [...'10/07/26'].forEach((c, i) => { mem[0xFFFF5 + i] = c.charCodeAt(0); });
      mem[0xFFFFE] = 0xFC;                                       // model byte: AT
      const d = new Date(m.now());
      const t = Math.floor((d.getHours() * 3600 + d.getMinutes() * 60 + d.getSeconds()) * 18.2065);
      ww(0x46C, t & 0xFFFF); ww(0x46E, t >>> 16);                // ticks since midnight
      m.dac.set(textPalette()); m.dacVersion++;                  // the machine boots in text mode 3
      // the diskette parameter table at the IBM address, also pointed to by INT 1Eh
      mem.set([0xDF, 0x02, 0x25, 0x02, 0x12, 0x1B, 0xFF, 0x6C, 0xF6, 0x0F, 0x08], lin(BIOS_SEG, 0xEFC7));
      ww(0x1E * 4, 0xEFC7); ww(0x1E * 4 + 2, BIOS_SEG);
      mem[0x475] = m.drive >= 0x80 ? 1 : 0;                      // number of hard disks
      // chips back to their power-on state
      for (const t of pit) { t.reload = 0x10000; t.rw = 3; t.flip = 0; t.latched = null; t.start = m.now(); }
      m.tickMs = TICK_MS; picMask = 0; m.irqBase = 0x08; icw = 0; port61 = 0; speaker();
      kbdQueue.length = 0; irq1Pending = 0; mem[0x417] = 0;
      r.fill(0); s.fill(0); m.flags = 0x0002 | IF;
      m.halted = false; m.fault = null; m.waiting = null; m.keys.length = 0; m.instructions = 0;
      m.irqPending = 0; m.irqs = 0; m.kbdIrqs = 0; m.lastTick = m.now(); m.trail.fill(0);
      clearScreen();
      if (opts.post) opts.post(m);
      // INT 19h: load sector 0 of the boot disk at 0000:7C00 and check the signature
      diskRead(0, 1, 0, 0x7C00);
      if (rw(0x7DFE) !== 0xAA55) { m.print('No bootable device: signature 55AA missing'); m.halted = true; }
      r[DX] = m.drive; r[SP] = 0x7C00; s[CS] = 0; m.ip = 0x7C00;
      if (m.hooks.reboot) m.hooks.reboot();
    };

    // ---------- interrupts from the outside world ----------
    // the PIT: call with the current time, queues IRQ0 for every channel-0 period that passed
    m.tickTimer = function (now = m.now()) {
      if (m.lastTick === null) m.lastTick = now;
      const due = Math.floor((now - m.lastTick) / m.tickMs);
      if (due > 0) { m.lastTick += due * m.tickMs; m.irqPending = Math.min(m.irqPending + due, 4); }
      if (now - m.lastTick > Math.max(m.tickMs * 8, 250)) m.lastTick = now;    // tab was asleep: don't flood
    };
    const int9Hooked = () => { const v = m.irqBase + 1; return !(rw(v * 4 + 2) === BIOS_SEG && rw(v * 4) === ENTRY[0x09]); };
    let lastAscii = 0;
    const MODIFIER = new Set([0x1D, 0x2A, 0x36, 0x38, 0x3A]);
    function shiftFlags(scan, down) {
      const bit = { 0x36: 1, 0x2A: 2, 0x1D: 4, 0x38: 8 }[scan & 0x7F];
      if (bit) mem[0x417] = down ? mem[0x417] | bit : mem[0x417] & ~bit;
    }
    // a key went down: the BIOS buffers it, or, if a program hooked INT 09h, the keyboard
    // controller raises IRQ1 with the make code on port 60h
    m.keyDown = (ascii, scan = 0) => {
      shiftFlags(scan, true);
      if (int9Hooked()) { if (kbdQueue.length < 32) { kbdQueue.push({ scan: scan & 0x7F, ascii }); irq1Pending++; } return; }
      lastScan = scan & 0xFF;
      if (MODIFIER.has(scan & 0x7F)) return;     // shift, ctrl, alt, caps lock only change the flags, like the ROM's INT 09h
      if (scan || ascii) m.keys.push(((scan & 0xFF) << 8) | (ascii & 0xFF));
      if (m.keys.length > 16) m.keys.shift();
    };
    m.keyUp = (scan) => {                      // break code: scan | 80h
      shiftFlags(scan, false);
      if (int9Hooked() && kbdQueue.length < 32) { kbdQueue.push({ scan: (scan & 0x7F) | 0x80, ascii: 0 }); irq1Pending++; }
    };
    m.key = (ascii, scan = 0) => m.keyDown(ascii, scan);
    function bios9() {                         // a program chained INT 09h to the BIOS: buffer the key it read
      if (!(lastScan & 0x80) && !MODIFIER.has(lastScan) && (lastScan || lastAscii)) { m.keys.push((lastScan << 8) | lastAscii); if (m.keys.length > 16) m.keys.shift(); }
    }
    function deliverIrq(irq) {                 // push FLAGS, CS, IP and vector through the PIC's base + irq
      m.halted = false;
      if (m.waiting === 'key') m.waiting = null;   // IP still points at the INT 16h, it runs again after IRET
      if (irq === 0) { m.irqPending--; m.irqs++; }
      else { irq1Pending--; const k = kbdQueue.shift(); lastScan = k.scan; lastAscii = k.ascii; kbdFull = 1; m.kbdIrqs++; }
      push(m.flags); push(s[CS]); push(m.ip);
      setF(IF, 0); setF(TF, 0);
      const v = m.irqBase + irq;
      m.ip = rw(v * 4); s[CS] = rw(v * 4 + 2);
      m.instructions++;
      return true;
    }

    // ---------- one instruction ----------
    m.step = function () {
      if (m.fault) return false;
      let irq = -1;
      if ((m.flags & IF) && m.waiting !== 'time') {
        if (m.irqPending > 0 && !(picMask & 1)) irq = 0;
        else if (irq1Pending > 0 && !(picMask & 2)) irq = 1;
      }
      if (irq < 0 && (m.flags & IF) && m.waiting !== 'time') {      // IRQ12: the PS/2 mouse, at most every 10 ms
        const ps = m.ps2;
        if (ps.enabled && ps.dirty && (ps.cbSeg || ps.cbOff) && m.now() - ps.last >= 10) return deliverMouse();
      }
      if (m.halted) return irq >= 0 ? deliverIrq(irq) : false;   // HLT sleeps until an interrupt
      if (irq >= 0) return deliverIrq(irq);
      if (m.waiting === 'time') { if (m.now() < m.wakeAt) return false; m.waiting = null; }
      if (m.waiting === 'key') { if (!m.keys.length) return false; m.waiting = null; }
      opStart = m.ip; opSeg = s[CS];
      if (opSeg === BIOS_SEG && opStart === ENTRY[0x09]) bios9();
      m.trail[m.trailPos++ & 63] = (opSeg << 16) | opStart;
      segOvr = -1; rep = 0;
      let op;
      for (;;) {                         // prefixes
        op = fetch8();
        if (op === 0x26) segOvr = ES; else if (op === 0x2E) segOvr = CS; else if (op === 0x36) segOvr = SS; else if (op === 0x3E) segOvr = DS;
        else if (op === 0xF2 || op === 0xF3) rep = op; else if (op === 0xF0) { /* LOCK */ } else break;
      }
      exec(op);
      m.instructions++;
      return true;
    };
    m.pc = () => lin(s[CS], m.ip);
    // the mouse: absolute position for the INT 33h driver, deltas for the PS/2 BIOS callback
    m.setMouse = (x, y, buttons) => {
      const ms = m.mouse, ps = m.ps2;
      ps.dx += (x | 0) - ms.x; ps.dy += (y | 0) - ms.y;
      if (buttons !== ms.buttons) ps.dirty = true;
      ms.x = x | 0; ms.y = y | 0; ms.buttons = buttons;
      if (ps.dx || ps.dy) ps.dirty = true;
    };
    m.moveMouse = (dx, dy, buttons = m.mouse.buttons) => m.setMouse(m.mouse.x + dx, m.mouse.y + dy, buttons);
    // like the BIOS IRQ12 handler: push status, X, Y, 0 and far-call the program's handler,
    // which returns with RETF to a ROM stub that drops the 4 words and IRETs
    function deliverMouse() {
      const ps = m.ps2, ms = m.mouse;
      const cl = v => Math.max(-255, Math.min(255, v));
      const dx = cl(ps.dx), dy = cl(ps.dy);
      ps.dx -= dx; ps.dy -= dy; ps.dirty = !!(ps.dx || ps.dy); ps.last = m.now();
      const status = 0x08 | (ms.buttons & 1) | (ms.buttons & 2) | (dx < 0 ? 0x10 : 0) | (dy > 0 ? 0x20 : 0);   // PS/2 Y grows upwards
      m.halted = false;
      if (m.waiting === 'key') m.waiting = null;
      push(m.flags); push(s[CS]); push(m.ip);
      setF(IF, 0); setF(TF, 0);
      push(status); push(dx & 0xFF); push((-dy) & 0xFF); push(0);
      push(BIOS_SEG); push(MOUSE_TRAMP);
      s[CS] = ps.cbSeg; m.ip = ps.cbOff;
      m.mouseIrqs = (m.mouseIrqs || 0) + 1; m.instructions++;
      return true;
    }
    Object.defineProperty(m, 'mode', { get: () => mem[0x449] });

    function stringOp(op) {
      const w = op & 1, size = w ? 2 : 1, delta = getF(DF) ? -size : size;
      const once = () => {
        switch (op & 0xFE) {
          case 0xA4: { const v = w ? rw(lin(dataSeg(), r[SI])) : rb(lin(dataSeg(), r[SI])); w ? ww(lin(s[ES], r[DI]), v) : wb(lin(s[ES], r[DI]), v); r[SI] += delta; r[DI] += delta; return true; }
          case 0xA6: { const a = w ? rw(lin(dataSeg(), r[SI])) : rb(lin(dataSeg(), r[SI])); const b = w ? rw(lin(s[ES], r[DI])) : rb(lin(s[ES], r[DI])); alu(7, a, b, w); r[SI] += delta; r[DI] += delta; return null; }
          case 0xAA: { w ? ww(lin(s[ES], r[DI]), r[AX]) : wb(lin(s[ES], r[DI]), r[AX]); r[DI] += delta; return true; }
          case 0xAC: { if (w) r[AX] = rw(lin(dataSeg(), r[SI])); else w8(0, rb(lin(dataSeg(), r[SI]))); r[SI] += delta; return true; }
          case 0xAE: { const b = w ? rw(lin(s[ES], r[DI])) : rb(lin(s[ES], r[DI])); alu(7, w ? r[AX] : r[AX] & 0xFF, b, w); r[DI] += delta; return null; }
        }
      };
      if (!rep) { once(); return; }
      while (r[CX] !== 0) {
        const plain = once(); r[CX]--;
        if (plain === null) { if (rep === 0xF3 && !getF(ZF)) break; if (rep === 0xF2 && getF(ZF)) break; }
      }
    }

    function exec(op) {
      // ALU block 00-3F
      if (op < 0x40 && (op & 7) < 6) {
        const kind = op >> 3, form = op & 7;
        switch (form) {
          case 0: { modrm(); const v = alu(kind, getRM8(), r8(reg), 0); if (kind !== 7) setRM8(v); return; }
          case 1: { modrm(); const v = alu(kind, getRM16(), r[reg], 1); if (kind !== 7) setRM16(v); return; }
          case 2: { modrm(); const v = alu(kind, r8(reg), getRM8(), 0); if (kind !== 7) w8(reg, v); return; }
          case 3: { modrm(); const v = alu(kind, r[reg], getRM16(), 1); if (kind !== 7) r[reg] = v; return; }
          case 4: { const v = alu(kind, r[AX] & 0xFF, fetch8(), 0); if (kind !== 7) w8(0, v); return; }
          case 5: { const v = alu(kind, r[AX], fetch16(), 1); if (kind !== 7) r[AX] = v; return; }
        }
      }
      switch (op) {
        case 0x06: push(s[ES]); return; case 0x07: s[ES] = pop(); return;
        case 0x0E: push(s[CS]); return;
        case 0x16: push(s[SS]); return; case 0x17: s[SS] = pop(); return;
        case 0x1E: push(s[DS]); return; case 0x1F: s[DS] = pop(); return;
        case 0x27: case 0x2F: {        // DAA / DAS
          let al = r[AX] & 0xFF; const oldCF = getF(CF), oldAL = al; setF(CF, 0);
          const sub = op === 0x2F;
          if ((al & 0x0F) > 9 || getF(AF)) { al = sub ? al - 6 : al + 6; setF(CF, oldCF || al > 0xFF || al < 0); setF(AF, 1); } else setF(AF, 0);
          if (oldAL > 0x99 || oldCF) { al = sub ? al - 0x60 : al + 0x60; setF(CF, 1); }
          w8(0, al); szp(al & 0xFF, 0); return;
        }
        case 0x37: case 0x3F: {        // AAA / AAS
          if ((r[AX] & 0x0F) > 9 || getF(AF)) {
            if (op === 0x37) { r[AX] = (r[AX] + 0x106) & 0xFFFF; } else { r[AX] = (r[AX] - 6) & 0xFFFF; w8(4, (r[AX] >> 8) - 1); }
            setF(AF, 1); setF(CF, 1);
          } else { setF(AF, 0); setF(CF, 0); }
          w8(0, r[AX] & 0x0F); return;
        }
        case 0x0F: {                   // two-byte escape: only UD2 exists here
          const op2 = fetch8();
          fault(op2 === 0x0B ? '#UD (UD2)' : '#UD (0F ' + op2.toString(16).padStart(2, '0') + ')');
          return;
        }
      }
      if (op >= 0x40 && op <= 0x47) { r[op - 0x40] = incdec(r[op - 0x40], false, 1); return; }
      if (op >= 0x48 && op <= 0x4F) { r[op - 0x48] = incdec(r[op - 0x48], true, 1); return; }
      if (op >= 0x50 && op <= 0x57) { const v = op === 0x54 ? r[SP] - 2 : r[op - 0x50]; push(v); return; }  // 8086 pushes SP-2
      if (op >= 0x58 && op <= 0x5F) { r[op - 0x58] = pop(); return; }
      if (op >= 0x70 && op <= 0x7F) {
        const d = sx8(fetch8()), f = m.flags;
        let c;
        switch (op >> 1 & 7) {
          case 0: c = f & OF; break;                                   // JO
          case 1: c = f & CF; break;                                   // JB
          case 2: c = f & ZF; break;                                   // JZ
          case 3: c = f & (CF | ZF); break;                            // JBE
          case 4: c = f & SF; break;                                   // JS
          case 5: c = f & PF; break;                                   // JP
          case 6: c = !(f & SF) !== !(f & OF); break;                  // JL
          default: c = (f & ZF) || (!(f & SF) !== !(f & OF));          // JLE
        }
        if (!c === !!(op & 1)) m.ip = (m.ip + d) & 0xFFFF;             // odd opcodes are the negations
        return;
      }
      if (op >= 0x91 && op <= 0x97) { const t = r[AX]; r[AX] = r[op - 0x90]; r[op - 0x90] = t; return; }
      if (op >= 0xB0 && op <= 0xB7) { w8(op - 0xB0, fetch8()); return; }
      if (op >= 0xB8 && op <= 0xBF) { r[op - 0xB8] = fetch16(); return; }

      switch (op) {
        case 0x60: { const sp = r[SP]; push(r[AX]); push(r[CX]); push(r[DX]); push(r[BX]); push(sp); push(r[BP]); push(r[SI]); push(r[DI]); return; }
        case 0x61: { r[DI] = pop(); r[SI] = pop(); r[BP] = pop(); pop(); r[BX] = pop(); r[DX] = pop(); r[CX] = pop(); r[AX] = pop(); return; }
        case 0x68: push(fetch16()); return;
        case 0x6A: push(sx8(fetch8()) & 0xFFFF); return;
        case 0x69: case 0x6B: {
          modrm(); const a = (getRM16() << 16) >> 16, b = op === 0x69 ? (fetch16() << 16) >> 16 : sx8(fetch8());
          const p = a * b; r[reg] = p & 0xFFFF; const ovf = p !== ((p << 16) >> 16); setF(CF, ovf); setF(OF, ovf); return;
        }
        case 0x80: case 0x82: { modrm(); const k = reg, v = alu(k, getRM8(), fetch8(), 0); if (k !== 7) setRM8(v); return; }
        case 0x81: { modrm(); const k = reg, v = alu(k, getRM16(), fetch16(), 1); if (k !== 7) setRM16(v); return; }
        case 0x83: { modrm(); const k = reg, v = alu(k, getRM16(), sx8(fetch8()) & 0xFFFF, 1); if (k !== 7) setRM16(v); return; }
        case 0x84: modrm(); alu(4, getRM8(), r8(reg), 0); return;
        case 0x85: modrm(); alu(4, getRM16(), r[reg], 1); return;
        case 0x86: { modrm(); const t = getRM8(); setRM8(r8(reg)); w8(reg, t); return; }
        case 0x87: { modrm(); const t = getRM16(); setRM16(r[reg]); r[reg] = t; return; }
        case 0x88: modrm(); setRM8(r8(reg)); return;
        case 0x89: modrm(); setRM16(r[reg]); return;
        case 0x8A: modrm(); w8(reg, getRM8()); return;
        case 0x8B: modrm(); r[reg] = getRM16(); return;
        case 0x8C: modrm(); setRM16(s[reg & 3]); return;
        case 0x8D: modrm(); r[reg] = eaOff; return;
        case 0x8E: modrm(); s[reg & 3] = getRM16(); return;
        case 0x8F: modrm(); setRM16(pop()); return;
        case 0x90: return;
        case 0x98: r[AX] = (r[AX] & 0x80) ? r[AX] | 0xFF00 : r[AX] & 0x00FF; return;
        case 0x99: r[DX] = (r[AX] & 0x8000) ? 0xFFFF : 0; return;
        case 0x9A: { const off = fetch16(), seg = fetch16(); push(s[CS]); push(m.ip); s[CS] = seg; m.ip = off; return; }
        case 0x9B: return;
        case 0x9C: push(m.flags | 0xF002); return;
        case 0x9D: m.flags = (pop() & 0x0FD5) | 0x0002; return;
        case 0x9E: m.flags = (m.flags & 0xFF00) | ((r[AX] >> 8) & 0xD5) | 0x02; return;
        case 0x9F: w8(4, (m.flags & 0xD5) | 0x02); return;
        case 0xA0: { const a = lin(dataSeg(), fetch16()); w8(0, rb(a)); return; }
        case 0xA1: { const a = lin(dataSeg(), fetch16()); r[AX] = rw(a); return; }
        case 0xA2: { const a = lin(dataSeg(), fetch16()); wb(a, r[AX]); return; }
        case 0xA3: { const a = lin(dataSeg(), fetch16()); ww(a, r[AX]); return; }
        case 0xA4: case 0xA5: case 0xA6: case 0xA7: case 0xAA: case 0xAB: case 0xAC: case 0xAD: case 0xAE: case 0xAF: stringOp(op); return;
        case 0xA8: alu(4, r[AX] & 0xFF, fetch8(), 0); return;
        case 0xA9: alu(4, r[AX], fetch16(), 1); return;
        case 0xC0: case 0xC1: case 0xD0: case 0xD1: case 0xD2: case 0xD3: {
          const w = op & 1; modrm();
          const count = op <= 0xC1 ? fetch8() & 0x1F : op <= 0xD1 ? 1 : r[CX] & 0xFF;
          if (w) setRM16(shift(reg, getRM16(), count, 1)); else setRM8(shift(reg, getRM8(), count, 0));
          return;
        }
        case 0xC2: { const n = fetch16(); m.ip = pop(); r[SP] += n; return; }
        case 0xC3: m.ip = pop(); return;
        case 0xC4: case 0xC5: { modrm(); r[reg] = rw(ea); s[op === 0xC4 ? ES : DS] = rw(ea + 2); return; }
        case 0xC6: modrm(); setRM8(fetch8()); return;
        case 0xC7: modrm(); setRM16(fetch16()); return;
        case 0xC9: r[SP] = r[BP]; r[BP] = pop(); return;
        case 0xCA: { const n = fetch16(); m.ip = pop(); s[CS] = pop(); r[SP] += n; return; }
        case 0xCB: m.ip = pop(); s[CS] = pop(); return;
        case 0xCC: interrupt(3, m.ip); return;
        case 0xCD: { const n = fetch8(); interrupt(n, m.ip); return; }
        case 0xCE: if (getF(OF)) interrupt(4, m.ip); return;
        case 0xCF: m.ip = pop(); s[CS] = pop(); m.flags = (pop() & 0x0FD5) | 0x0002; return;
        case 0xD4: { const base = fetch8(); if (!base) { interrupt(0, m.ip); return; } const al = r[AX] & 0xFF; r[AX] = ((al / base | 0) << 8) | (al % base); szp(r[AX] & 0xFF, 0); return; }
        case 0xD5: { const base = fetch8(); const al = ((r[AX] >> 8) * base + (r[AX] & 0xFF)) & 0xFF; r[AX] = al; szp(al, 0); return; }
        case 0xD7: w8(0, rb(lin(dataSeg(), r[BX] + (r[AX] & 0xFF)))); return;
        case 0xD8: case 0xD9: case 0xDA: case 0xDB: case 0xDC: case 0xDD: case 0xDE: case 0xDF: modrm(); return;  // no FPU: ignore ESC
        case 0xE0: case 0xE1: case 0xE2: {
          const d = sx8(fetch8()); r[CX]--;
          const go = r[CX] !== 0 && (op === 0xE2 || (op === 0xE1 ? getF(ZF) : !getF(ZF)));
          if (go) m.ip = (m.ip + d) & 0xFFFF; return;
        }
        case 0xE3: { const d = sx8(fetch8()); if (r[CX] === 0) m.ip = (m.ip + d) & 0xFFFF; return; }
        case 0xE4: w8(0, portIn(fetch8())); return;
        case 0xE5: { const p = fetch8(); r[AX] = portIn(p) | (portIn(p + 1) << 8); return; }
        case 0xE6: portOut(fetch8(), r[AX]); return;
        case 0xE7: { const p = fetch8(); portOut(p, r[AX]); portOut(p + 1, r[AX] >> 8); return; }
        case 0xE8: { const d = fetch16(); push(m.ip); m.ip = (m.ip + d) & 0xFFFF; return; }
        case 0xE9: { const d = fetch16(); m.ip = (m.ip + d) & 0xFFFF; return; }
        case 0xEA: { const off = fetch16(), seg = fetch16(); m.ip = off; s[CS] = seg; return; }
        case 0xEB: { const d = sx8(fetch8()); m.ip = (m.ip + d) & 0xFFFF; return; }
        case 0xEC: w8(0, portIn(r[DX])); return;
        case 0xED: r[AX] = portIn(r[DX]) | (portIn(r[DX] + 1) << 8); return;
        case 0xEE: portOut(r[DX], r[AX]); return;
        case 0xEF: portOut(r[DX], r[AX]); portOut(r[DX] + 1, r[AX] >> 8); return;
        case 0xF4: m.halted = true; return;
        case 0xF5: setF(CF, !getF(CF)); return;
        case 0xF6: case 0xF7: {
          const w = op & 1; modrm();
          const v = w ? getRM16() : getRM8();
          switch (reg) {
            case 0: case 1: alu(4, v, w ? fetch16() : fetch8(), w); return;
            case 2: w ? setRM16(~v & 0xFFFF) : setRM8(~v & 0xFF); return;
            case 3: { const res = alu(5, 0, v, w); w ? setRM16(res) : setRM8(res); setF(CF, v !== 0); return; }
            case 4: case 5: {
              if (!w) {
                const p = reg === 4 ? (r[AX] & 0xFF) * v : sx8(r[AX] & 0xFF) * sx8(v);
                r[AX] = p & 0xFFFF;
                const ovf = reg === 4 ? (r[AX] >> 8) !== 0 : p !== sx8(p & 0xFF);
                setF(CF, ovf); setF(OF, ovf);
              } else {
                const a = reg === 4 ? r[AX] : (r[AX] << 16) >> 16, b = reg === 4 ? v : (v << 16) >> 16;
                const p = a * b;
                r[AX] = p & 0xFFFF; r[DX] = Math.floor(p / 0x10000) & 0xFFFF;
                const ovf = reg === 4 ? r[DX] !== 0 : p !== ((p << 16) >> 16);
                setF(CF, ovf); setF(OF, ovf);
              }
              return;
            }
            case 6: case 7: {
              if (v === 0) { interrupt(0, m.ip); return; }
              if (!w) {
                const num = reg === 6 ? r[AX] : (r[AX] << 16) >> 16, den = reg === 6 ? v : sx8(v);
                const q = Math.trunc(num / den), rem = num - q * den;
                if (reg === 6 ? q > 0xFF : (q > 127 || q < -128)) { interrupt(0, m.ip); return; }
                r[AX] = ((rem & 0xFF) << 8) | (q & 0xFF);
              } else {
                const num = reg === 6 ? r[DX] * 0x10000 + r[AX] : ((r[DX] << 16) | r[AX]), den = reg === 6 ? v : (v << 16) >> 16;
                const q = Math.trunc(num / den), rem = num - q * den;
                if (reg === 6 ? q > 0xFFFF : (q > 32767 || q < -32768)) { interrupt(0, m.ip); return; }
                r[AX] = q & 0xFFFF; r[DX] = rem & 0xFFFF;
              }
              return;
            }
          }
          return;
        }
        case 0xF8: setF(CF, 0); return; case 0xF9: setF(CF, 1); return;
        case 0xFA: setF(IF, 0); return; case 0xFB: setF(IF, 1); return;
        case 0xFC: setF(DF, 0); return; case 0xFD: setF(DF, 1); return;
        case 0xFE: { modrm(); if (reg > 1) { fault('#UD (FE /' + reg + ')'); return; } setRM8(incdec(getRM8(), reg === 1, 0)); return; }
        case 0xFF: {
          modrm();
          switch (reg) {
            case 0: setRM16(incdec(getRM16(), false, 1)); return;
            case 1: setRM16(incdec(getRM16(), true, 1)); return;
            case 2: { const t = getRM16(); push(m.ip); m.ip = t; return; }
            case 3: { push(s[CS]); push(m.ip); m.ip = rw(ea); s[CS] = rw(ea + 2); return; }
            case 4: m.ip = getRM16(); return;
            case 5: m.ip = rw(ea); s[CS] = rw(ea + 2); return;
            case 6: push(getRM16()); return;
          }
          fault('#UD (FF /7)'); return;
        }
      }
      fault('#UD (' + op.toString(16).padStart(2, '0') + ')');
    }

    m.reset();
    return m;
  }

  // CP437, the glyphs the VGA text mode actually draws
  const CP437 = ' ☺☻♥♦♣♠•◘○◙♂♀♪♫☼►◄↕‼¶§▬↨↑↓→←∟↔▲▼' +
    ' !"#$%&\'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~⌂' +
    'ÇüéâäàåçêëèïîìÄÅÉæÆôöòûùÿÖÜ¢£¥₧ƒáíóúñÑªº¿⌐¬½¼¡«»░▒▓│┤╡╢╖╕╣║╗╝╜╛┐└┴┬├─┼╞╟╚╔╩╦╠═╬╧╨╤╥╙╘╒╓╫╪┘┌█▄▌▐▀αßΓπΣσµτΦΘΩδ∞φε∩≡±≥≤⌠⌡÷≈°∙·√ⁿ²■ ';

  const api = { createMachine, CP437, FLAGS: { CF, PF, AF, ZF, SF, TF, IF, DF, OF } };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  root.X86 = api;
})(typeof window !== 'undefined' ? window : globalThis);
