// debugger.js · runs 7OS on cpu8086.js and keeps the debugger windows in sync
import { VGA } from './vga.js';
const VIDEO_SECS = 427;

export function initDebugger() {
  const X86 = window.X86;
  const $ = s => document.querySelector(s);
  const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;
  const STILL = '/girl/still.jpg', PANIC = '/girl/panic.gif';
  const hex = (n, w = 2) => (n >>> 0).toString(16).toUpperCase().padStart(w, '0');
  const esc = s => s.replace(/&/g, '&amp;').replace(/</g, '&lt;');

  /* ---------- messages ---------- */
  const logEl = $('#log');
  const log = (text, cls = '') => {
    const d = document.createElement('div'); d.className = cls; d.textContent = text;
    logEl.appendChild(d); if (logEl.children.length > 200) logEl.firstChild.remove();
    logEl.scrollTop = logEl.scrollHeight;
  };

  /* ---------- code window: the NASM listing ---------- */
  const lines = JSON.parse($('#listing').textContent);
  const codeEl = $('#code'), rowByAddr = new Map(), bytesAt = new Map();
  const splitComment = s => {                       // first ';' outside quotes
    let q = null;
    for (let i = 0; i < s.length; i++) {
      const c = s[i];
      if (q) { if (c === q) q = null; } else if (c === '"' || c === "'") q = c; else if (c === ';') return [s.slice(0, i), s.slice(i)];
    }
    return [s, ''];
  };
  codeEl.innerHTML = lines.map(l => {
    const [code, cmt] = splitComment(l.s);
    const label = code.match(/^([.\w]+:)(.*)$/);
    const body = label ? `<span class="l">${esc(label[1])}</span>${esc(label[2])}` : esc(code);
    const isData = /\b(db|dw|times)\b/.test(code);
    const ins = l.a !== null && l.b && !isData;
    return `<div class="row${ins ? ' ins' : ''}${isData ? ' dat' : ''}"${l.a !== null && l.b ? ` data-a="${l.a}"` : ''}>` +
      `<span class="gut"></span><span class="addr">${l.a !== null && l.b ? hex(l.a, 4) : ''}</span><span class="bytes">${l.b || ''}</span>` +
      `<span class="src">${body}${cmt ? `<span class="c">${esc(cmt)}</span>` : ''}</span></div>`;
  }).join('');
  codeEl.querySelectorAll('.row[data-a]').forEach(r => {
    const a = +r.dataset.a;
    if (!rowByAddr.has(a)) { rowByAddr.set(a, r); bytesAt.set(a, (r.querySelector('.bytes').textContent.length / 2) | 0); }
  });
  const bps = new Set();
  codeEl.addEventListener('click', e => {
    const r = e.target.closest('.row.ins'); if (!r) return;
    const a = +r.dataset.a;
    if (bps.has(a)) bps.delete(a); else bps.add(a);
    r.classList.toggle('bp', bps.has(a));
    log(`BPX 0000:${hex(a, 4)} ${bps.has(a) ? 'set' : 'cleared'}`, 'y');
  });

  /* ---------- screen ---------- */
  // the screen is a <canvas>: vga.js scans video memory and draws pixels, the way the card would
  const canvas = $('#vga'), crt = $('#crt'), vga = new VGA(canvas);
  const fit = () => {                    // a 4:3 monitor in whatever space the window has
    const w = crt.clientWidth - 4, h = crt.clientHeight - 4;
    const cw = Math.min(w, h * 4 / 3);
    canvas.style.width = cw + 'px'; canvas.style.height = cw * 3 / 4 + 'px';
  };
  new ResizeObserver(fit).observe(crt);

  let m = null, shownMode = -1;
  function renderScreen(force) {
    if (force) vga.sig = '';
    vga.draw(m);
    if (m.mode !== shownMode) {
      shownMode = m.mode;
      $('#vmode').textContent = m.mode === 0x13 ? 'VGA 320×200 · mode 13h · 256 colours · A000:0000' : 'VGA 720×400 · text 80×25 · B800:0000';
    }
  }

  /* ---------- registers, memory, code cursor ---------- */
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
  const dataEl = $('#data');
  function renderMem() {
    const pc = m.pc(), len = bytesAt.get(pc) || 1, start = Math.max(0, (pc & ~7) - 8 * 8);
    let out = '';
    for (let row = 0; row < 32; row++) {
      const base = start + row * 8; let hx = '', as = '';
      for (let i = 0; i < 8; i++) {
        const a = base + i, b = m.mem[a], cls = a >= pc && a < pc + len ? 'ip' : b ? 'n' : 'z';
        hx += `<span class="${cls}">${hex(b)}</span>` + (i < 7 ? ' ' : '');
        as += b >= 0x20 && b < 0x7F ? esc(String.fromCharCode(b)) : '.';
      }
      out += `<span class="a">${hex(base >> 4, 4)}:${hex(base & 15, 1)}</span> ${hx} ${as}\n`;
    }
    dataEl.innerHTML = out.trimEnd();
    $('#memAt').textContent = `${hex(m.s[1], 4)}:${hex(m.ip, 4)}`;
  }
  let curRow = null;
  function renderCode() {
    const pc = m.pc(), r = m.s[1] === 0 ? rowByAddr.get(pc) : null;
    if (curRow && curRow !== r) curRow.classList.remove('cur', 'exc');
    curRow = r || null;
    if (r) {
      r.classList.add('cur'); r.classList.toggle('exc', !!m.fault);
      const top = r.offsetTop;
      if (top < codeEl.scrollTop + 10 || top > codeEl.scrollTop + codeEl.clientHeight - 30) codeEl.scrollTop = top - codeEl.clientHeight / 2;
    }
    $('#where').textContent = `${hex(m.s[1], 4)}:${hex(m.ip, 4)}`;
  }
  let mips = 0, mipsAt = performance.now(), mipsCount = 0;
  function renderState() {
    const now = performance.now();
    if (now - mipsAt > 1000) { mips = (m.instructions - mipsCount) / (now - mipsAt) / 1000; mipsAt = now; mipsCount = m.instructions; }
    const st = m.fault ? `<b class="x">${m.fault.name}</b>` : m.halted ? '<b>halted</b>' : m.waiting === 'key' ? '<b>waiting for a key</b>' : running ? '<b>running</b>' : '<b>break</b>';
    $('#state').innerHTML = `${st} at ${hex(m.s[1], 4)}:${hex(m.ip, 4)} · ${m.instructions.toLocaleString('en-US')} instr · ${mips.toFixed(1)} MIPS · IRQ0 ×${m.irqs}`;
    $('#goLbl').textContent = running ? 'Break' : 'Go';
  }
  function renderAll(force) { renderScreen(force); renderRegs(); renderMem(); renderCode(); renderState(); renderPlayback(); }

  /* ---------- watch: the girl is the video on the tiny TV ---------- */
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

  /* ---------- run loop ---------- */
  let running = true, wasWaiting = null, turbo = true;
  const setTurbo = on => {
    turbo = on;
    $('#kTurbo').classList.toggle('on', on);
    $('#kTurbo').setAttribute('aria-pressed', on);
    log(on ? 'TURBO on: full speed' : 'TURBO off: ~4.77 MHz 8086 speed, 0.33 MIPS', 'y');
  };
  function onFault() {
    running = false; setMood(true);
    log(`${m.fault.name} at ${hex(m.fault.cs, 4)}:${hex(m.fault.ip, 4)} · me.state: CALM → PANIC · player: buffering`, 'r');
    log('F2 reboots. on real hardware the CPU would vector through IVT[06h] and land right back here.', 'y');
  }
  function frame(now) {
    if (m) {
      const dt = (now - lastTick) / 1000; lastTick = now;
      if (running && !m.fault) {
        played += dt;
        m.tickTimer();                                 // the PIT: queue IRQ0s for the time that passed
        const until = performance.now() + 10;          // ~10 ms of CPU per frame
        // turbo off: about what a 4.77 MHz 8086 managed, ~0.33 million instructions a second
        let budget = turbo ? Infinity : Math.max(1, Math.round(330000 * Math.min(dt, 0.1)));
        run: while (performance.now() < until && budget > 0) {
          for (let i = 0; i < 4000 && budget-- > 0; i++) {
            if (!m.step()) break run;                  // parked in INT 16h / INT 15h / HLT, or faulted
            if (bps.size && bps.has(m.pc())) { running = false; log(`Break due to BPX 0000:${hex(m.ip, 4)}`, 'y'); break run; }
          }
          m.tickTimer();
        }
        if (m.fault) onFault();
        if (m.waiting !== wasWaiting) {
          if (m.waiting === 'key') log('INT 16h AH=00h: waiting for a key (click the screen and type)', 'c');
          wasWaiting = m.waiting;
        }
      }
      renderAll(false);
    }
    requestAnimationFrame(frame);
  }
  function go() { if (!m) return; if (m.fault) { log('the CPU faulted. F2 to reboot.', 'y'); return; } running = !running; log(running ? 'go' : 'Break (user)', running ? 'w' : 'y'); renderAll(true); }
  function trace() {
    if (!m) return;
    running = false;
    if (m.fault) { log('the CPU faulted. F2 to reboot.', 'y'); return; }
    if (m.waiting === 'key' && !m.keys.length) { log('the CPU is parked in INT 16h waiting for a key. type on the screen first.', 'y'); renderAll(true); return; }
    const at = m.pc(); m.step();
    if (m.fault) onFault(); else log(`traced 0000:${hex(at, 4)} → ${hex(m.s[1], 4)}:${hex(m.ip, 4)}`);
    renderAll(true);
  }
  function bpxHere() { if (!m) return; const a = m.pc(); const r = rowByAddr.get(a); if (!r) return; if (bps.has(a)) bps.delete(a); else bps.add(a); r.classList.toggle('bp', bps.has(a)); log(`BPX 0000:${hex(a, 4)} ${bps.has(a) ? 'set' : 'cleared'}`, 'y'); }
  function reboot() { if (!m) return; prev = null; played = 0; setMood(false); m.reset(); running = true; renderAll(true); crt.focus({ preventScroll: true }); }

  /* ---------- keyboard: the screen is the PC's keyboard ---------- */
  const SCAN = { Enter: [13, 0x1C], Backspace: [8, 0x0E], Escape: [27, 0x01], ArrowUp: [0, 0x48], ArrowDown: [0, 0x50], ArrowLeft: [0, 0x4B], ArrowRight: [0, 0x4D] };
  crt.addEventListener('keydown', e => {
    if (!m || e.ctrlKey || e.metaKey || e.altKey || /^F\d+$/.test(e.key)) return;
    const k = SCAN[e.key] || (e.key.length === 1 && e.key.charCodeAt(0) < 128 ? [e.key.charCodeAt(0), 0] : null);
    if (!k) return;
    e.preventDefault(); m.key(k[0], k[1]);
  });
  crt.addEventListener('focus', () => { $('#wScreen').classList.add('typing'); $('#kbdHint').textContent = 'keyboard attached'; });
  crt.addEventListener('blur', () => { $('#wScreen').classList.remove('typing'); $('#kbdHint').textContent = 'click here and type'; });
  crt.addEventListener('click', () => crt.focus({ preventScroll: true }));
  addEventListener('keydown', e => {
    if (e.ctrlKey || e.metaKey || e.altKey) return;
    if (e.key === 'F5') { e.preventDefault(); go(); }
    else if (e.key === 'F8' || e.key === 'F10') { e.preventDefault(); trace(); }
    else if (e.key === 'F9') { e.preventDefault(); bpxHere(); }
    else if (e.key === 'F2') { e.preventDefault(); reboot(); }
    else if (e.key === 'F7') { e.preventDefault(); setTurbo(!turbo); }
  });
  $('#kTurbo').onclick = () => setTurbo(!turbo);
  $('#kGo').onclick = go; $('#kTrace').onclick = trace; $('#kBpx').onclick = bpxHere; $('#kReset').onclick = reboot;

  /* ---------- docs tabs ---------- */
  const tabs = [...document.querySelectorAll('.tabs button')];
  tabs.forEach(t => t.addEventListener('click', () => {
    tabs.forEach(x => x.setAttribute('aria-selected', x === t));
    document.querySelectorAll('.doc').forEach(d => { d.hidden = d.id !== 'd-' + t.dataset.doc; });
  }));

  /* ---------- boot ---------- */
  const post = mm => {
    mm.print('Almo7aya BIOS v7.07 · an 8086 emulated in JavaScript\r\n\r\n', 0x0F);
    mm.print('Memory Test : ', 0x07); mm.print('640K OK\r\n', 0x0A);
    mm.print('Boot device : hard disk 80h, almo7aya.img\r\n\r\n', 0x07);
  };
  // the disk image and the 8x16 font ROM (unscii-16, mapped to CP437 by os/build.mjs)
  const load = url => fetch(url).then(r => { if (!r.ok) throw new Error(`${url} ${r.status}`); return r.arrayBuffer(); });
  Promise.all([load('/os/almo7aya.img'), load('/os/vgafont.bin')]).then(([buf, fontBuf]) => {
    const img = new Uint8Array(buf);
    m = X86.createMachine(img, { post, font: new Uint8Array(fontBuf) });
    m.hooks.int = (n, msg) => log(`INT ${hex(n)}h ${msg}`, 'c');
    m.hooks.reboot = () => log(`reset · INT 19h: sector 0 of almo7aya.img → 0000:7C00, signature ${hex(m.rw(0x7DFE), 4)}h`, 'g');
    running = false;
    m.reset();
    log(`almo7aya.img: ${img.length} bytes, ${img.length / 512} sectors · font ROM 4096 bytes at C000:1000`, 'w');
    renderAll(true);
    setTimeout(() => { running = true; lastTick = performance.now(); crt.focus({ preventScroll: true }); }, reduce ? 0 : 700);
  }).catch(err => log(`could not load almo7aya.img (${err.message}). run npm run os.`, 'r'));
  requestAnimationFrame(frame);

  // for the curious, from DevTools: sevenOS.machine.r, sevenOS.type('help\r'), sevenOS.run(1e5)
  window.sevenOS = {
    get machine() { return m; },
    type(s) { for (const c of s) m.key(c.charCodeAt(0), c === '\r' ? 0x1C : 0); },
    run(n = 100000) { for (let i = 0; i < n && m.step(); i++); if (m.fault) onFault(); renderAll(true); return m.instructions; },
  };

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
