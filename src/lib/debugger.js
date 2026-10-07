// debugger.js · boots a disk on cpu8086.js and keeps the debugger windows honest:
//   Code     disassembles the bytes really in memory at CS:IP (any segment, ROM included),
//            with the NASM listing's labels and comments laid over it as symbols
//   Memory   any address, follows CS:IP or SS:SP, bytes flash when the CPU writes them
//   Stack    the words at SS:SP, with call and interrupt frames recognised
import { VGA } from './vga.js';
import { disasm, window as disasmWindow } from './disasm8086.js';

const VIDEO_SECS = 427;
// names for the ROM, so stepping into the BIOS reads like a real debugger with BIOS symbols
const ROM_SYMBOLS = {
  0xFFEA5: 'BIOS.int08_timer', 0xFFED0: 'BIOS.ps2_mouse_return', 0xFE3FE: 'BIOS.int13_disk', 0xFE82E: 'BIOS.int16_keyboard',
  0xFFE6E: 'BIOS.int1A_clock', 0xFFF53: 'BIOS.dummy_iret', 0xFE987: 'BIOS.int09_keyboard_irq', 0xFF859: 'BIOS.int15_system',
  0xFE6F2: 'BIOS.int19_boot', 0xFF84D: 'BIOS.int11_equipment', 0xFF841: 'BIOS.int12_memory', 0xFE05B: 'BIOS.post',
  0xFFFF0: 'BIOS.reset_vector', 0xC0130: 'VGABIOS.int10_video',
};
// KeyboardEvent.code -> XT scan code set 1
const SCAN = {
  Escape: 0x01, Digit1: 0x02, Digit2: 0x03, Digit3: 0x04, Digit4: 0x05, Digit5: 0x06, Digit6: 0x07, Digit7: 0x08, Digit8: 0x09, Digit9: 0x0A, Digit0: 0x0B,
  Minus: 0x0C, Equal: 0x0D, Backspace: 0x0E, Tab: 0x0F, KeyQ: 0x10, KeyW: 0x11, KeyE: 0x12, KeyR: 0x13, KeyT: 0x14, KeyY: 0x15, KeyU: 0x16, KeyI: 0x17,
  KeyO: 0x18, KeyP: 0x19, BracketLeft: 0x1A, BracketRight: 0x1B, Enter: 0x1C, ControlLeft: 0x1D, ControlRight: 0x1D, KeyA: 0x1E, KeyS: 0x1F, KeyD: 0x20,
  KeyF: 0x21, KeyG: 0x22, KeyH: 0x23, KeyJ: 0x24, KeyK: 0x25, KeyL: 0x26, Semicolon: 0x27, Quote: 0x28, Backquote: 0x29, ShiftLeft: 0x2A, Backslash: 0x2B,
  KeyZ: 0x2C, KeyX: 0x2D, KeyC: 0x2E, KeyV: 0x2F, KeyB: 0x30, KeyN: 0x31, KeyM: 0x32, Comma: 0x33, Period: 0x34, Slash: 0x35, ShiftRight: 0x36,
  AltLeft: 0x38, AltRight: 0x38, Space: 0x39, CapsLock: 0x3A, F1: 0x3B, F3: 0x3D, F4: 0x3E, F10: 0x44,
  Home: 0x47, ArrowUp: 0x48, PageUp: 0x49, ArrowLeft: 0x4B, ArrowRight: 0x4D, End: 0x4F, ArrowDown: 0x50, PageDown: 0x51, Insert: 0x52, Delete: 0x53,
};
const ASCII_SPECIAL = { Enter: 13, Backspace: 8, Tab: 9, Escape: 27 };

export function initDebugger() {
  const X86 = window.X86;
  const $ = s => document.querySelector(s);
  const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;
  const STILL = '/girl/still.jpg', PANIC = '/girl/panic.gif';
  const hex = (n, w = 2) => (n >>> 0).toString(16).toUpperCase().padStart(w, '0');
  const esc = s => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;');
  const lin = (seg, off) => ((seg << 4) + (off & 0xFFFF)) & 0xFFFFF;

  /* ---------- messages ---------- */
  const logEl = $('#log');
  const log = (text, cls = '') => {
    const d = document.createElement('div'); d.className = cls; d.textContent = text;
    logEl.appendChild(d); if (logEl.children.length > 250) logEl.firstChild.remove();
    logEl.scrollTop = logEl.scrollHeight;
  };
  document.querySelectorAll('.minitabs button').forEach(b => b.addEventListener('click', () => {
    document.querySelectorAll('.minitabs button').forEach(x => x.setAttribute('aria-selected', x === b));
    $('#log').hidden = b.dataset.pane !== 'log'; $('#stack').hidden = b.dataset.pane !== 'stack';
  }));

  /* ---------- the machine and its disk ---------- */
  let m = null, disk = null, symbols = new Map(), comments = new Map(), symList = [], font = null, disks = [];
  let dataSpans = [];                                 // [start, end) linear ranges the listing declares with db/dw/dd/times
  const dataEnd = a => {
    let lo = 0, hi = dataSpans.length - 1;
    while (lo <= hi) { const mid = (lo + hi) >> 1, [s, e] = dataSpans[mid]; if (a < s) hi = mid - 1; else if (a >= e) lo = mid + 1; else return e; }
    return 0;
  };
  const bps = new Set();
  const symAt = a => symbols.get(a) || ROM_SYMBOLS[a];
  const nearestSym = a => {                           // "label+off" for an address inside a program
    let lo = 0, hi = symList.length - 1, best = -1;
    while (lo <= hi) { const mid = (lo + hi) >> 1; if (symList[mid] <= a) { best = mid; lo = mid + 1; } else hi = mid - 1; }
    if (best < 0 || a - symList[best] > 0x400) return ROM_SYMBOLS[a] || '';
    const s = symList[best];
    return a === s ? symbols.get(s) : `${symbols.get(s)}+${hex(a - s, 1)}`;
  };

  /* ---------- screen ---------- */
  const canvas = $('#vga'), crt = $('#crt'), vga = new VGA(canvas);
  const fit = () => {                                 // a 4:3 monitor in whatever space the window has
    const w = crt.clientWidth - 4, h = crt.clientHeight - 4, cw = Math.min(w, h * 4 / 3);
    canvas.style.width = cw + 'px'; canvas.style.height = cw * 3 / 4 + 'px';
  };
  new ResizeObserver(fit).observe(crt);
  let shownMode = -1;
  function renderScreen(force) {
    if (force) vga.sig = '';
    vga.draw(m);
    if (m.mode !== shownMode) {
      shownMode = m.mode;
      $('#vmode').textContent = m.mode === 0x13 ? 'VGA 320×200 · mode 13h · 256 colours · A000:0000' : 'VGA 720×400 · text 80×25 · B800:0000';
    }
    canvas.style.cursor = m.ps2.enabled ? 'none' : '';
  }

  /* ---------- registers ---------- */
  let prev = null;
  function renderRegs() {
    const r = m.r, s = m.s, now = { AX: r[0], BX: r[3], CX: r[1], DX: r[2], SI: r[6], DI: r[7], BP: r[5], SP: r[4], IP: m.ip, CS: s[1], DS: s[3], ES: s[0], SS: s[2], FL: m.flags };
    const v = k => { const t = `<b>${k}</b>=${hex(now[k], 4)}`; return prev && prev[k] !== now[k] ? `<span class="chg">${t}</span>` : t; };
    const F = X86.FLAGS;
    const fl = [['O', F.OF], ['D', F.DF], ['I', F.IF], ['S', F.SF], ['Z', F.ZF], ['A', F.AF], ['P', F.PF], ['C', F.CF]]
      .map(([c, bit]) => (m.flags & bit) ? `<span class="on">${c}</span>` : c.toLowerCase()).join(' ');
    $('#regs').innerHTML = `${v('AX')} ${v('BX')} ${v('CX')} ${v('DX')} ${v('SI')} ${v('DI')}\n${v('BP')} ${v('SP')} ${v('IP')} <span class="fl">${fl}</span>\n${v('CS')} ${v('DS')} ${v('ES')} ${v('SS')} ${v('FL')}`;
    prev = now;
  }

  /* ---------- code: a real disassembly of memory at CS:IP ---------- */
  const codeEl = $('#code');
  let codeKey = '';
  function renderCode() {
    const cs = m.s[1], ip = m.ip, key = `${cs}:${ip}:${m.fault ? 1 : 0}:${bps.size}`;
    if (key === codeKey) return;
    codeKey = key;
    const base = cs << 4;
    const cands = [];
    for (const a of symList) if (a >= base + ip - 96 && a < base + ip) cands.push(a - base);
    const trailHere = new Set();
    for (const t of m.trail) if (t && (t >>> 16) === cs) { const o = t & 0xFFFF; trailHere.add(o); if (o < ip && ip - o < 96) cands.push(o); }
    const win = disasmWindow(m.rb, cs, ip, cands, 9, 26);
    // walk again from the same start, but show the listing's db/dw spans as data, not as junk opcodes
    const rows = [];
    for (let off = win[0].off, n = 0; n < win.length + 4; n++) {
      const a = lin(cs, off), end = dataEnd(a);
      if (end && !(a <= m.pc() && m.pc() < end)) {
        const len = Math.min(8, end - a), bytes = [];
        for (let i = 0; i < len; i++) bytes.push(m.rb(a + i));
        const str = bytes.every(b => b >= 0x20 && b < 0x7F) ? `'${String.fromCharCode(...bytes)}'` : bytes.map(b => '0x' + hex(b)).join(', ');
        rows.push({ off, len, bytes, text: `db ${str}`, kind: 'data' });
        off = (off + len) & 0xFFFF;
      } else { const d = disasm(m.rb, cs, off); rows.push(d); off = (off + d.len) & 0xFFFF; }
    }
    let html = '';
    for (const d of rows) {
      const a = lin(cs, d.off), sym = symAt(a);
      if (sym) html += `<div class="lbl">${esc(sym)}:</div>`;
      const cur = d.off === ip;
      let cmt = '';
      if (d.target) { const t = lin(d.target.seg, d.target.off); const n = nearestSym(t); if (n) cmt = `→ ${n}`; }
      else if (d.kind === 'int') { const n = parseInt(d.text.split(' ')[1], 16); if (!isNaN(n)) { const v = lin(m.rw(n * 4 + 2), m.rw(n * 4)); cmt = `→ ${hex(m.rw(n * 4 + 2), 4)}:${hex(m.rw(n * 4), 4)} ${ROM_SYMBOLS[v] || nearestSym(v)}`; } }
      if (!cmt && comments.has(a)) cmt = comments.get(a);
      const cls = ['row', cur ? 'cur' : '', d.kind === 'data' ? 'dat' : '', cur && m.fault ? 'exc' : '', bps.has(a) ? 'bp' : '', !cur && trailHere.has(d.off) ? 'ran' : '', d.kind === 'bad' ? 'bad' : ''].join(' ');
      const [mn, ...ops] = d.text.split(' ');
      html += `<div class="${cls}" data-a="${a}"><span class="gut"></span><span class="addr">${hex(cs, 4)}:${hex(d.off, 4)}</span>` +
        `<span class="bytes">${d.bytes.slice(0, 6).map(b => hex(b)).join('')}${d.bytes.length > 6 ? '…' : ''}</span>` +
        `<span class="src"><span class="mn">${esc(mn)}</span> ${esc(ops.join(' '))}${cmt ? `<span class="c"> ; ${esc(cmt)}</span>` : ''}</span></div>`;
    }
    codeEl.innerHTML = html;
    const cur = codeEl.querySelector('.cur');
    if (cur) codeEl.scrollTop = cur.offsetTop - codeEl.clientHeight / 3;
    $('#where').textContent = `${hex(cs, 4)}:${hex(ip, 4)}${nearestSym(lin(cs, ip)) ? ' · ' + nearestSym(lin(cs, ip)) : ''}`;
  }
  codeEl.addEventListener('click', e => {
    const r = e.target.closest('.row'); if (!r) return;
    const a = +r.dataset.a;
    if (bps.has(a)) bps.delete(a); else bps.add(a);
    log(`BPX ${r.querySelector('.addr').textContent} (linear ${hex(a, 5)}) ${bps.has(a) ? 'set' : 'cleared'}${symAt(a) ? ' · ' + symAt(a) : ''}`, 'y');
    codeKey = '';
  });

  /* ---------- memory: any address, writes flash ---------- */
  const dataEl = $('#data');
  let memMode = 'CS:IP', memBase = 0;
  function parseAddr(s) {
    s = s.trim().toUpperCase();
    if (s === 'CS:IP' || s === 'SS:SP') return s;
    const so = s.match(/^([0-9A-F]{1,4}):([0-9A-F]{1,4})$/);
    if (so) return lin(parseInt(so[1], 16), parseInt(so[2], 16));
    if (/^[0-9A-F]{1,5}$/.test(s)) return parseInt(s, 16);
    return null;
  }
  function setMem(s) {
    const v = parseAddr(s);
    if (v === null) { $('#memAddr').classList.add('err'); return; }
    $('#memAddr').classList.remove('err');
    if (typeof v === 'string') memMode = v; else { memMode = 'fixed'; memBase = v & ~7; }
    $('#memAddr').value = s.toUpperCase();
    renderMem();
  }
  $('#memForm').addEventListener('submit', e => { e.preventDefault(); setMem($('#memAddr').value); });
  document.querySelectorAll('.presets button').forEach(b => b.addEventListener('click', () => setMem(b.dataset.at)));
  function renderMem() {
    const pc = m.pc(), len = disasm(m.rb, m.s[1], m.ip).len;
    let start;
    if (memMode === 'CS:IP') start = Math.max(0, (pc & ~7) - 8 * 6);
    else if (memMode === 'SS:SP') start = Math.max(0, (lin(m.s[2], m.r[4]) & ~7) - 8 * 2);
    else start = memBase;
    const tick = m.wtick, ws = m.wstamp, sp = lin(m.s[2], m.r[4]);
    let out = '';
    for (let row = 0; row < 48; row++) {
      const base = (start + row * 8) & 0xFFFFF;
      let hx = '', as = '';
      for (let i = 0; i < 8; i++) {
        const a = base + i, b = m.mem[a], age = tick - ws[a];
        let cls = a >= pc && a < pc + len ? 'ip' : a === sp || a === sp + 1 ? 'sp' : ws[a] && age < 12 ? 'w1' : ws[a] && age < 90 ? 'w2' : b ? 'n' : 'z';
        hx += `<span class="${cls}">${hex(b)}</span>` + (i < 7 ? ' ' : '');
        as += `<span class="${cls === 'w1' || cls === 'w2' ? cls : ''}">${esc(b >= 0x20 && b < 0x7F ? String.fromCharCode(b) : '.')}</span>`;
      }
      const segv = base >= 0xF0000 ? 0xF000 : base >= 0xC0000 ? 0xC000 : base >= 0xB8000 ? 0xB800 : base >= 0xA0000 ? 0xA000 : (base >> 4) & 0xF000;
      out += `<span class="a">${hex(segv, 4)}:${hex(base - segv * 16, 4)}</span> ${hx} ${as}\n`;
    }
    dataEl.innerHTML = out.trimEnd();
    $('#memAt').textContent = memMode === 'fixed' ? `${hex(memBase, 5)}` : memMode;
  }

  /* ---------- stack ---------- */
  const stackEl = $('#stack');
  function renderStack() {
    if (stackEl.hidden) return;
    const ss = m.s[2], sp = m.r[4];
    const words = [];
    for (let i = 0; i < 24; i++) words.push(m.rw(lin(ss, sp + i * 2)));
    const notes = new Array(24).fill('');
    for (let i = 0; i < 22; i++) {                    // IRET frames: IP, CS, FLAGS (bit 1 always set)
      const [ip, cs, fl] = [words[i], words[i + 1], words[i + 2]];
      if ((fl & 0x0002) && (fl & 0xF000) === 0xF000 && (cs === 0 || cs === 0xF000 || cs === 0xC000 || cs === m.s[1]) && !notes[i]) {
        const n = nearestSym(lin(cs, ip));
        notes[i] = `iret → ${hex(cs, 4)}:${hex(ip, 4)}${n ? ' ' + n : ''}`; notes[i + 1] = '  (CS of the interrupted code)'; notes[i + 2] = '  (FLAGS before the interrupt)';
      }
    }
    for (let i = 0; i < 24; i++) {                    // near return addresses: preceded by a CALL in CS
      if (notes[i]) continue;
      const v = words[i], a = lin(m.s[1], v);
      if (m.rb(a - 3) === 0xE8 || (m.rb(a - 2) === 0xFF && ((m.rb(a - 1) >> 3) & 7) === 2) || (m.rb(a - 4) === 0xFF && ((m.rb(a - 3) >> 3) & 7) === 2)) {
        const n = nearestSym(a); notes[i] = `ret → ${hex(v, 4)}${n ? ' ' + n : ''}`;
      }
    }
    stackEl.innerHTML = words.map((w, i) => `<div class="${i === 0 ? 'top' : ''}"><span class="a">${hex(ss, 4)}:${hex(sp + i * 2, 4)}</span> <b>${hex(w, 4)}</b> <span class="c">${esc(notes[i])}</span></div>`).join('');
  }

  /* ---------- status and the girl ---------- */
  let mips = 0, mipsAt = performance.now(), mipsCount = 0;
  function renderState() {
    const now = performance.now();
    if (m.instructions < mipsCount) mipsCount = 0;   // reset or a new disk
    if (now - mipsAt > 1000) { mips = (m.instructions - mipsCount) / (now - mipsAt) / 1000; mipsAt = now; mipsCount = m.instructions; }
    const st = m.fault ? `<b class="x">${m.fault.name}</b>` : m.halted ? '<b>hlt</b>' : m.waiting === 'key' ? '<b>INT 16h wait</b>' : running ? '<b>running</b>' : '<b>break</b>';
    $('#state').innerHTML = `${st} ${hex(m.s[1], 4)}:${hex(m.ip, 4)} · ${mips.toFixed(1)} MIPS · IRQ0 ×${m.irqs} · IRQ1 ×${m.kbdIrqs}${m.speakerHz ? ` · ♪ ${m.speakerHz.toFixed(0)} Hz` : ''}`;
    $('#goLbl').textContent = running ? 'Break' : 'Go';
  }
  let played = 0, lastTick = performance.now();
  function renderPlayback() {
    const s = Math.floor(played) % VIDEO_SECS;
    $('#pfill').style.width = (s / VIDEO_SECS * 100) + '%';
    $('#ptime').textContent = `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
    if (!m.fault) $('#pstate').textContent = running ? '▶ playing' : '❚❚ paused';
  }
  function setMood(panic) {
    $('#mood').textContent = panic ? 'PANIC' : 'CALM'; $('#mood').className = panic ? 'p' : '';
    $('#wWatch').classList.toggle('stalled', panic);
    $('#pstate').textContent = panic ? '⟳ buffering…' : '▶ playing'; $('#pstate').className = panic ? 'p' : '';
    $('#girl').src = panic && !reduce ? PANIC : STILL;
    if (panic) { const p = $('#pic'); p.classList.remove('shake'); void p.offsetWidth; p.classList.add('shake'); }
  }
  function renderAll(force) {
    if (!m) return;
    renderScreen(force); renderRegs(); renderCode(); renderMem(); renderStack(); renderState(); renderPlayback();
  }

  /* ---------- PC speaker -> Web Audio ---------- */
  let audio = null, osc = null, gain = null, soundOn = true;
  function ensureAudio() {
    if (audio || !window.AudioContext) return;
    audio = new AudioContext();
    osc = audio.createOscillator(); osc.type = 'square';
    gain = audio.createGain(); gain.gain.value = 0;
    osc.connect(gain).connect(audio.destination); osc.start();
  }
  function speaker(hz) {
    if (!audio) return;
    const t = audio.currentTime;
    if (hz > 20 && hz < 20000 && soundOn) { osc.frequency.setValueAtTime(hz, t); gain.gain.setTargetAtTime(0.05, t, 0.002); }
    else gain.gain.setTargetAtTime(0, t, 0.004);
  }
  const setSound = on => { soundOn = on; $('#kSound').setAttribute('aria-pressed', on); $('#soundLbl').textContent = on ? 'SPK on' : 'SPK off'; if (m) speaker(m.speakerHz); };

  /* ---------- run loop ---------- */
  let running = true, wasWaiting = null, turbo = true;
  const setTurbo = on => {
    turbo = on; $('#kTurbo').classList.toggle('on', on); $('#kTurbo').setAttribute('aria-pressed', on);
    log(on ? 'TURBO on: full speed' : 'TURBO off: ~4.77 MHz 8086 speed, 0.33 MIPS', 'y');
  };
  function onFault() {
    running = false; setMood(true); codeKey = '';
    log(`${m.fault.name} at ${hex(m.fault.cs, 4)}:${hex(m.fault.ip, 4)} · me.state: CALM → PANIC`, 'r');
    log('F2 reboots. a real CPU would vector through the IVT and come right back here.', 'y');
  }
  function frame(now) {
    if (m) {
      const dt = (now - lastTick) / 1000; lastTick = now;
      m.wtick = Math.floor(now / 50);               // write stamps in 50 ms units: flash ~0.6 s, then glow ~4.5 s
      if (running && !m.fault) {
        played += dt;
        m.tickTimer();
        const until = performance.now() + 10;
        let budget = turbo ? Infinity : Math.max(1, Math.round(330000 * Math.min(dt, 0.1)));
        run: while (performance.now() < until && budget > 0) {
          for (let i = 0; i < 4000 && budget-- > 0; i++) {
            if (!m.step()) break run;
            if (bps.size && bps.has(m.pc())) { running = false; log(`Break due to BPX ${hex(m.s[1], 4)}:${hex(m.ip, 4)} ${nearestSym(m.pc())}`, 'y'); break run; }
          }
          m.tickTimer();
        }
        if (m.fault) onFault();
        if (m.waiting !== wasWaiting) { if (m.waiting === 'key') log('INT 16h AH=00h: waiting for a key', 'c'); wasWaiting = m.waiting; }
      }
      renderAll(false);
    }
    requestAnimationFrame(frame);
  }
  function go() { if (!m) return; if (m.fault) { log('the CPU faulted. F2 to reboot.', 'y'); return; } running = !running; log(running ? 'go' : 'Break (user)', running ? 'w' : 'y'); codeKey = ''; renderAll(true); }
  function trace() {
    if (!m) return;
    running = false;
    if (m.fault) { log('the CPU faulted. F2 to reboot.', 'y'); return; }
    if (m.waiting === 'key' && !m.keys.length) { log('parked in INT 16h waiting for a key. type on the screen first.', 'y'); renderAll(true); return; }
    const before = `${hex(m.s[1], 4)}:${hex(m.ip, 4)}`, d = disasm(m.rb, m.s[1], m.ip);
    m.step();
    if (m.fault) onFault(); else log(`${before}  ${d.text}`);
    renderAll(true);
  }
  function bpxHere() { if (!m) return; const a = m.pc(); if (bps.has(a)) bps.delete(a); else bps.add(a); log(`BPX ${hex(m.s[1], 4)}:${hex(m.ip, 4)} ${bps.has(a) ? 'set' : 'cleared'}`, 'y'); codeKey = ''; }
  function reboot() { if (!m) return; prev = null; played = 0; setMood(false); bps.clear(); m.reset(); running = true; codeKey = ''; renderAll(true); crt.focus({ preventScroll: true }); }

  /* ---------- keyboard and mouse: the screen is the PC's keyboard and mouse ---------- */
  crt.addEventListener('keydown', e => {
    ensureAudio();
    if (!m || bootMenuOpen() || e.ctrlKey || e.metaKey || (/^F\d+$/.test(e.key) && !['F1', 'F3', 'F4', 'F10'].includes(e.key))) return;
    const scan = SCAN[e.code];
    const ascii = ASCII_SPECIAL[e.key] ?? (e.key.length === 1 && e.key.charCodeAt(0) < 128 ? e.key.charCodeAt(0) : 0);
    if (!scan && !ascii) return;
    e.preventDefault();
    m.keyDown(ascii, scan || 0);
  });
  crt.addEventListener('keyup', e => { const scan = SCAN[e.code]; if (m && scan) { e.preventDefault(); m.keyUp(scan); } });
  crt.addEventListener('focus', () => { $('#wScreen').classList.add('typing'); $('#kbdHint').textContent = 'keyboard + mouse attached'; });
  crt.addEventListener('blur', () => { $('#wScreen').classList.remove('typing'); $('#kbdHint').textContent = 'click here and type'; });
  const mouseAt = e => {
    const r = canvas.getBoundingClientRect();
    return [Math.max(0, Math.min(639, (e.clientX - r.left) / r.width * 640)), Math.max(0, Math.min(199, (e.clientY - r.top) / r.height * 200))];
  };
  let buttons = 0;
  canvas.addEventListener('pointermove', e => { if (m) { const [x, y] = mouseAt(e); m.setMouse(x, y, buttons); } });
  canvas.addEventListener('pointerdown', e => { ensureAudio(); crt.focus({ preventScroll: true }); buttons |= e.button === 2 ? 2 : 1; if (m) { const [x, y] = mouseAt(e); m.setMouse(x, y, buttons); } });
  addEventListener('pointerup', e => { buttons &= e.button === 2 ? ~2 : ~1; if (m) m.setMouse(m.mouse.x, m.mouse.y, buttons); });
  canvas.addEventListener('contextmenu', e => e.preventDefault());

  addEventListener('keydown', e => {
    if (e.ctrlKey || e.metaKey || e.altKey) return;
    if (bootMenuOpen()) return;
    const k = e.key;
    if (k === 'F5') { e.preventDefault(); go(); }
    else if (k === 'F8') { e.preventDefault(); trace(); }
    else if (k === 'F9') { e.preventDefault(); bpxHere(); }
    else if (k === 'F2') { e.preventDefault(); reboot(); }
    else if (k === 'F7') { e.preventDefault(); setTurbo(!turbo); }
    else if (k === 'F6') { e.preventDefault(); ensureAudio(); setSound(!soundOn); }
    else if (k === 'F12') { e.preventDefault(); openBootMenu(); }
  });
  $('#kGo').onclick = go; $('#kTrace').onclick = trace; $('#kBpx').onclick = bpxHere; $('#kReset').onclick = reboot;
  $('#kTurbo').onclick = () => setTurbo(!turbo);
  $('#kSound').onclick = () => { ensureAudio(); setSound(!soundOn); };
  $('#kBoot').onclick = () => openBootMenu();
  $('#diskBtn').onclick = () => openBootMenu();

  /* ---------- docs tabs ---------- */
  const tabs = [...document.querySelectorAll('.tabs button')];
  tabs.forEach(t => t.addEventListener('click', () => {
    tabs.forEach(x => x.setAttribute('aria-selected', x === t));
    document.querySelectorAll('.doc').forEach(d => { d.hidden = d.id !== 'd-' + t.dataset.doc; });
  }));

  /* ---------- boot menu (F12) ---------- */
  const menu = $('#bootMenu'), listEl = $('#bootList');
  let sel = 0;
  const bootMenuOpen = () => !menu.hidden;
  function openBootMenu() {
    if (!disks.length) return;
    sel = Math.max(0, disks.findIndex(d => d.id === disk?.id));
    drawMenu(); menu.hidden = false; crt.focus({ preventScroll: true });
  }
  function drawMenu() {
    listEl.innerHTML = disks.map((d, i) => `<li class="${i === sel ? 'sel' : ''}" data-i="${i}"><b>${i + 1}. ${esc(d.title)}</b> <span>${esc(d.drive === 'floppy' ? 'floppy 00h' : 'hard disk 80h')}${d.size ? ` · ${d.size < 4096 ? d.size + ' bytes' : Math.ceil(d.size / 1024) + ' KB'}` : ''}</span><br><i>${esc(d.description || '')}</i></li>`).join('');
  }
  listEl.addEventListener('click', e => { const li = e.target.closest('li'); if (li) { menu.hidden = true; boot(disks[+li.dataset.i].id); } });
  crt.addEventListener('keydown', e => {
    if (!bootMenuOpen()) return;
    e.preventDefault(); e.stopImmediatePropagation();
    if (e.key === 'ArrowDown') sel = (sel + 1) % disks.length;
    else if (e.key === 'ArrowUp') sel = (sel + disks.length - 1) % disks.length;
    else if (/^[1-9]$/.test(e.key) && +e.key <= disks.length) sel = +e.key - 1;
    else if (e.key === 'Enter') { menu.hidden = true; boot(disks[sel].id); return; }
    else if (e.key === 'Escape' || e.key === 'F12') { menu.hidden = true; return; }
    drawMenu();
  }, true);

  /* ---------- boot ---------- */
  const post = mm => {
    mm.print('Almo7aya BIOS v7.07 · an 8086 PC emulated in JavaScript\r\n\r\n', 0x0F);
    mm.print('Memory Test : ', 0x07); mm.print('640K OK\r\n', 0x0A);
    mm.print(`Boot device : ${disk.drive === 'floppy' ? 'floppy 00h' : 'hard disk 80h'}, ${disk.image}\r\n`, 0x07);
    mm.print('Press F12 for the boot menu\r\n\r\n', 0x08);
  };
  const load = url => fetch(url).then(r => { if (!r.ok) throw new Error(`${url} ${r.status}`); return r.arrayBuffer(); });
  async function boot(id) {
    disk = disks.find(d => d.id === id) || disks[0];
    try { localStorage.setItem('disk', disk.id); } catch (e) {}
    const url = new URL(location.href); url.searchParams.set('disk', disk.id); history.replaceState(null, '', url);
    $('#diskName').textContent = disk.title; $('#diskTitle').textContent = `8086 · real mode · ${disk.title}`;
    $('#imgSize').textContent = (disk.size || 0).toLocaleString('en-US');
    $('#imgLink').href = `/os/${disk.image}`; $('#imgLink').textContent = `⬇ ${disk.image}`;
    $('#qemuCmd').textContent = `qemu-system-i386 -drive format=raw,${disk.drive === 'floppy' ? 'if=floppy,' : ''}file=${disk.image}`;
    $('#srcLink').href = disk.source || `/os/${disk.id}.asm`;
    symbols = new Map(); comments = new Map(); symList = []; dataSpans = [];
    let img, info;
    try {
      [img, info] = await Promise.all([load(`/os/${disk.image}`), disk.external ? Promise.resolve(null) : fetch(`/os/${disk.id}.json`).then(r => r.ok ? r.json() : null).catch(() => null)]);
    } catch (err) { log(`could not load ${disk.image} (${err.message}). run npm run os.`, 'r'); return; }
    if (info) {
      for (const [a, n] of Object.entries(info.symbols)) symbols.set(+a, n);
      for (const l of info.lines) {
        if (l.a === null) continue;
        const i = l.s.indexOf(';');
        if (i >= 0 && !comments.has(l.a)) comments.set(l.a, l.s.slice(i + 1).trim());
      }
      symList = [...symbols.keys()].sort((a, b) => a - b);
      const at = info.lines.filter(l => l.a !== null).sort((x, y) => x.a - y.a || x.n - y.n);
      for (let i = 0; i < at.length; i++) {
        const src = at[i].s.replace(/;.*/, '').replace(/^[\w.]+:\s*/, '').trim();
        if (!/^(db|dw|dd|times|resb|resw|incbin)\b/i.test(src)) continue;
        let j = i + 1; while (j < at.length && at[j].a <= at[i].a) j++;
        const end = j < at.length ? at[j].a : at[i].a + at[i].b.length / 2;
        const last = dataSpans[dataSpans.length - 1];
        if (last && last[1] >= at[i].a) last[1] = Math.max(last[1], end); else dataSpans.push([at[i].a, end]);
      }
    }
    $('#codeSrc').textContent = info ? `disassembly · ${disk.id}.asm symbols` : 'disassembly · no symbols';
    m = X86.createMachine(new Uint8Array(img), { post, font, drive: disk.drive });
    m.hooks.int = (n, msg) => log(`INT ${hex(n)}h ${msg}`, 'c');
    m.hooks.reboot = () => log(`reset · INT 19h: sector 0 of ${disk.image} → 0000:7C00, signature ${hex(m.rw(0x7DFE), 4)}h`, 'g');
    m.hooks.speaker = speaker;
    m.hooks.pit = hz => log(`PIT channel 0 reprogrammed: IRQ0 at ${hz.toFixed(1)} Hz`, 'c');
    window.sevenOS.machine = m;
    running = false; bps.clear(); prev = null; played = 0; setMood(false); codeKey = '';
    m.reset();
    log(`booting ${disk.title}: ${disk.image}, ${img.byteLength.toLocaleString('en-US')} bytes · ${disk.keys || ''}`, 'w');
    renderAll(true);
    setTimeout(() => { running = true; lastTick = performance.now(); crt.focus({ preventScroll: true }); }, reduce ? 0 : 500);
  }

  window.sevenOS = {
    machine: null, disasm: (seg, off) => disasm(window.sevenOS.machine.rb, seg, off).text,
    type(s) { for (const c of s) window.sevenOS.machine.keyDown(c.charCodeAt(0), c === '\r' ? 0x1C : 0); },
    run(n = 100000) { const mm = window.sevenOS.machine; for (let i = 0; i < n && mm.step(); i++); if (mm.fault) onFault(); renderAll(true); return mm.instructions; },
    boot: id => boot(id),
  };

  Promise.all([load('/os/vgafont.bin'), fetch('/os/disks.json').then(r => r.json())]).then(([f, list]) => {
    font = new Uint8Array(f); disks = list;
    let want = new URL(location.href).searchParams.get('disk');
    try { want ??= localStorage.getItem('disk'); } catch (e) {}
    boot(disks.some(d => d.id === want) ? want : disks[0].id);
  }).catch(err => log(`could not load the disks (${err.message}). run npm run os.`, 'r'));
  requestAnimationFrame(frame);

  /* ---------- live GitHub numbers, cached values stay if this fails ---------- */
  (async () => {
    try {
      const get = u => fetch('https://api.github.com/' + u).then(r => { if (!r.ok) throw r.status; return r.json(); });
      const [u, a, b] = await Promise.all([get('users/Almo7aya'), get('repos/Almo7aya/openingh.nvim'), get('repos/Almo7aya/neogruvbox.nvim')]);
      $('#ghRepos').textContent = u.public_repos; $('#ghFol').textContent = u.followers; $('#ghSince').textContent = u.created_at.slice(0, 4);
      $('#ghS1').textContent = a.stargazers_count; $('#ghS2').textContent = b.stargazers_count; $('#ghLive').textContent = 'live';
    } catch (e) { /* keep cached */ }
  })();
}
