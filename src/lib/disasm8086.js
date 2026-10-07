// disasm8086.js · decodes 8086 (and the few 186) instructions straight from memory, NASM syntax
//   disasm(rb, seg, off) -> { seg, off, len, bytes, text, kind, target }
//   rb(linear) reads a byte; kind is 'jmp' | 'jcc' | 'call' | 'ret' | 'int' | 'bad' | ''
//   target is { seg, off } for direct jumps and calls

const R8 = ['al', 'cl', 'dl', 'bl', 'ah', 'ch', 'dh', 'bh'];
const R16 = ['ax', 'cx', 'dx', 'bx', 'sp', 'bp', 'si', 'di'];
const SR = ['es', 'cs', 'ss', 'ds'];
const ALU = ['add', 'or', 'adc', 'sbb', 'and', 'sub', 'xor', 'cmp'];
const SHF = ['rol', 'ror', 'rcl', 'rcr', 'shl', 'shr', 'sal', 'sar'];
const JCC = ['jo', 'jno', 'jc', 'jnc', 'jz', 'jnz', 'jna', 'ja', 'js', 'jns', 'jpe', 'jpo', 'jl', 'jnl', 'jng', 'jg'];
const EA = ['bx+si', 'bx+di', 'bp+si', 'bp+di', 'si', 'di', 'bp', 'bx'];
const h = (v, w = 2) => '0x' + (v >>> 0).toString(16).toUpperCase().padStart(w, '0');
const sx8 = v => (v & 0x80 ? v - 0x100 : v);

export function disasm(rb, seg, off) {
  const start = off;
  const at = o => rb(((seg << 4) + (o & 0xFFFF)) & 0xFFFFF);
  const b8 = () => { const v = at(off); off = (off + 1) & 0xFFFF; return v; };
  const b16 = () => { const lo = b8(); return lo | (b8() << 8); };
  let segp = '', repp = '', lock = '', op;
  for (let n = 0; n < 6; n++) {
    op = b8();
    if (op === 0x26 || op === 0x2E || op === 0x36 || op === 0x3E) segp = SR[(op >> 3) & 3] + ':';
    else if (op === 0xF2) repp = 'repne '; else if (op === 0xF3) repp = 'rep '; else if (op === 0xF0) lock = 'lock ';
    else break;
  }
  let mod, reg, rm;
  const modrm = () => { const v = b8(); mod = v >> 6; reg = (v >> 3) & 7; rm = v & 7; };
  // an r/m operand; size = 'byte'/'word' prefix when the other operand doesn't say
  const ea = (w, size) => {
    if (mod === 3) return (w ? R16 : R8)[rm];
    let s;
    if (mod === 0 && rm === 6) s = h(b16(), 4);
    else {
      s = EA[rm];
      if (mod === 1) { const d = sx8(b8()); s += d < 0 ? '-' + h(-d) : '+' + h(d); }
      else if (mod === 2) { const d = (b16() << 16) >> 16; s += d < 0 ? '-' + h(-d, 4) : '+' + h(d, 4); }
    }
    return (size ? (w ? 'word ' : 'byte ') : '') + '[' + segp + s + ']';
  };
  const near = d => { const t = (off + d) & 0xFFFF; target = { seg, off: t }; return h(t, 4); };
  let text = '', kind = '', target = null;

  if (op < 0x40 && (op & 7) < 6) {
    const k = ALU[op >> 3], f = op & 7;
    if (f === 0) { modrm(); text = `${k} ${ea(0)}, ${R8[reg]}`; }
    else if (f === 1) { modrm(); text = `${k} ${ea(1)}, ${R16[reg]}`; }
    else if (f === 2) { modrm(); text = `${k} ${R8[reg]}, ${ea(0)}`; }
    else if (f === 3) { modrm(); text = `${k} ${R16[reg]}, ${ea(1)}`; }
    else if (f === 4) text = `${k} al, ${h(b8())}`;
    else text = `${k} ax, ${h(b16(), 4)}`;
  } else if (op >= 0x40 && op <= 0x4F) text = `${op < 0x48 ? 'inc' : 'dec'} ${R16[op & 7]}`;
  else if (op >= 0x50 && op <= 0x57) text = `push ${R16[op & 7]}`;
  else if (op >= 0x58 && op <= 0x5F) text = `pop ${R16[op & 7]}`;
  else if (op >= 0x70 && op <= 0x7F) { const d = sx8(b8()); text = `${JCC[op & 15]} ${near(d)}`; kind = 'jcc'; }
  else if (op >= 0x91 && op <= 0x97) text = `xchg ax, ${R16[op & 7]}`;
  else if (op >= 0xB0 && op <= 0xB7) text = `mov ${R8[op & 7]}, ${h(b8())}`;
  else if (op >= 0xB8 && op <= 0xBF) text = `mov ${R16[op & 7]}, ${h(b16(), 4)}`;
  else if (op >= 0xD8 && op <= 0xDF) { modrm(); text = `esc ${((op & 7) << 3) | reg}, ${ea(1)}`; }
  else switch (op) {
    case 0x06: case 0x0E: case 0x16: case 0x1E: text = `push ${SR[(op >> 3) & 3]}`; break;
    case 0x07: case 0x17: case 0x1F: text = `pop ${SR[(op >> 3) & 3]}`; break;
    case 0x0F: { const o2 = b8(); text = o2 === 0x0B ? 'ud2' : `db 0x0F, ${h(o2)}`; kind = 'bad'; break; }
    case 0x27: text = 'daa'; break; case 0x2F: text = 'das'; break; case 0x37: text = 'aaa'; break; case 0x3F: text = 'aas'; break;
    case 0x60: text = 'pusha'; break; case 0x61: text = 'popa'; break;
    case 0x68: text = `push ${h(b16(), 4)}`; break;
    case 0x6A: text = `push byte ${h(b8())}`; break;
    case 0x69: modrm(); text = `imul ${R16[reg]}, ${ea(1)}, ${h(b16(), 4)}`; break;
    case 0x6B: modrm(); text = `imul ${R16[reg]}, ${ea(1)}, ${h(b8())}`; break;
    case 0x80: case 0x82: modrm(); text = `${ALU[reg]} ${ea(0, 1)}, ${h(b8())}`; break;
    case 0x81: modrm(); text = `${ALU[reg]} ${ea(1, 1)}, ${h(b16(), 4)}`; break;
    case 0x83: { modrm(); const e = ea(1, 1), v = sx8(b8()); text = `${ALU[reg]} ${e}, ${v < 0 ? '-' + h(-v) : h(v)}`; break; }
    case 0x84: modrm(); text = `test ${ea(0)}, ${R8[reg]}`; break;
    case 0x85: modrm(); text = `test ${ea(1)}, ${R16[reg]}`; break;
    case 0x86: modrm(); text = `xchg ${ea(0)}, ${R8[reg]}`; break;
    case 0x87: modrm(); text = `xchg ${ea(1)}, ${R16[reg]}`; break;
    case 0x88: modrm(); text = `mov ${ea(0)}, ${R8[reg]}`; break;
    case 0x89: modrm(); text = `mov ${ea(1)}, ${R16[reg]}`; break;
    case 0x8A: modrm(); text = `mov ${R8[reg]}, ${ea(0)}`; break;
    case 0x8B: modrm(); text = `mov ${R16[reg]}, ${ea(1)}`; break;
    case 0x8C: modrm(); text = `mov ${ea(1)}, ${SR[reg & 3]}`; break;
    case 0x8D: modrm(); text = `lea ${R16[reg]}, ${ea(1)}`; break;
    case 0x8E: modrm(); text = `mov ${SR[reg & 3]}, ${ea(1)}`; break;
    case 0x8F: modrm(); text = `pop ${ea(1, 1)}`; break;
    case 0x90: text = 'nop'; break;
    case 0x98: text = 'cbw'; break; case 0x99: text = 'cwd'; break;
    case 0x9A: { const o = b16(), s = b16(); text = `call ${h(s, 4)}:${h(o, 4)}`; kind = 'call'; target = { seg: s, off: o }; break; }
    case 0x9B: text = 'wait'; break; case 0x9C: text = 'pushf'; break; case 0x9D: text = 'popf'; break;
    case 0x9E: text = 'sahf'; break; case 0x9F: text = 'lahf'; break;
    case 0xA0: text = `mov al, [${segp}${h(b16(), 4)}]`; break;
    case 0xA1: text = `mov ax, [${segp}${h(b16(), 4)}]`; break;
    case 0xA2: text = `mov [${segp}${h(b16(), 4)}], al`; break;
    case 0xA3: text = `mov [${segp}${h(b16(), 4)}], ax`; break;
    case 0xA4: text = 'movsb'; break; case 0xA5: text = 'movsw'; break;
    case 0xA6: text = 'cmpsb'; break; case 0xA7: text = 'cmpsw'; break;
    case 0xA8: text = `test al, ${h(b8())}`; break; case 0xA9: text = `test ax, ${h(b16(), 4)}`; break;
    case 0xAA: text = 'stosb'; break; case 0xAB: text = 'stosw'; break;
    case 0xAC: text = 'lodsb'; break; case 0xAD: text = 'lodsw'; break;
    case 0xAE: text = 'scasb'; break; case 0xAF: text = 'scasw'; break;
    case 0xC0: case 0xC1: modrm(); text = `${SHF[reg]} ${ea(op & 1, 1)}, ${h(b8())}`; break;
    case 0xC2: text = `ret ${h(b16(), 4)}`; kind = 'ret'; break;
    case 0xC3: text = 'ret'; kind = 'ret'; break;
    case 0xC4: modrm(); text = `les ${R16[reg]}, ${ea(1)}`; break;
    case 0xC5: modrm(); text = `lds ${R16[reg]}, ${ea(1)}`; break;
    case 0xC6: modrm(); text = `mov ${ea(0, 1)}, ${h(b8())}`; break;
    case 0xC7: modrm(); text = `mov ${ea(1, 1)}, ${h(b16(), 4)}`; break;
    case 0xC8: { const a = b16(), b = b8(); text = `enter ${h(a, 4)}, ${h(b)}`; break; }
    case 0xC9: text = 'leave'; break;
    case 0xCA: text = `retf ${h(b16(), 4)}`; kind = 'ret'; break;
    case 0xCB: text = 'retf'; kind = 'ret'; break;
    case 0xCC: text = 'int3'; kind = 'int'; break;
    case 0xCD: text = `int ${h(b8())}`; kind = 'int'; break;
    case 0xCE: text = 'into'; kind = 'int'; break;
    case 0xCF: text = 'iret'; kind = 'ret'; break;
    case 0xD0: case 0xD1: modrm(); text = `${SHF[reg]} ${ea(op & 1, 1)}, 1`; break;
    case 0xD2: case 0xD3: modrm(); text = `${SHF[reg]} ${ea(op & 1, 1)}, cl`; break;
    case 0xD4: { const v = b8(); text = v === 10 ? 'aam' : `aam ${h(v)}`; break; }
    case 0xD5: { const v = b8(); text = v === 10 ? 'aad' : `aad ${h(v)}`; break; }
    case 0xD7: text = 'xlatb'; break;
    case 0xE0: case 0xE1: case 0xE2: case 0xE3: { const d = sx8(b8()); text = `${['loopnz', 'loopz', 'loop', 'jcxz'][op & 3]} ${near(d)}`; kind = 'jcc'; break; }
    case 0xE4: text = `in al, ${h(b8())}`; break; case 0xE5: text = `in ax, ${h(b8())}`; break;
    case 0xE6: text = `out ${h(b8())}, al`; break; case 0xE7: text = `out ${h(b8())}, ax`; break;
    case 0xE8: { const d = b16(); text = `call ${near((d << 16) >> 16)}`; kind = 'call'; break; }
    case 0xE9: { const d = b16(); text = `jmp ${near((d << 16) >> 16)}`; kind = 'jmp'; break; }
    case 0xEA: { const o = b16(), s = b16(); text = `jmp ${h(s, 4)}:${h(o, 4)}`; kind = 'jmp'; target = { seg: s, off: o }; break; }
    case 0xEB: { const d = sx8(b8()); text = `jmp short ${near(d)}`; kind = 'jmp'; break; }
    case 0xEC: text = 'in al, dx'; break; case 0xED: text = 'in ax, dx'; break;
    case 0xEE: text = 'out dx, al'; break; case 0xEF: text = 'out dx, ax'; break;
    case 0xF4: text = 'hlt'; break; case 0xF5: text = 'cmc'; break;
    case 0xF6: case 0xF7: {
      modrm(); const w = op & 1;
      const names = ['test', 'test', 'not', 'neg', 'mul', 'imul', 'div', 'idiv'];
      text = `${names[reg]} ${ea(w, 1)}`;
      if (reg < 2) text += ', ' + (w ? h(b16(), 4) : h(b8()));
      break;
    }
    case 0xF8: text = 'clc'; break; case 0xF9: text = 'stc'; break;
    case 0xFA: text = 'cli'; break; case 0xFB: text = 'sti'; break;
    case 0xFC: text = 'cld'; break; case 0xFD: text = 'std'; break;
    case 0xFE: modrm(); text = reg < 2 ? `${reg ? 'dec' : 'inc'} ${ea(0, 1)}` : `db 0xFE`; if (reg >= 2) kind = 'bad'; break;
    case 0xFF: {
      modrm();
      const e = ea(1, reg !== 3 && reg !== 5);
      text = [`inc ${e}`, `dec ${e}`, `call ${e}`, `call far ${e}`, `jmp ${e}`, `jmp far ${e}`, `push ${e}`, `db 0xFF`][reg];
      kind = ['', '', 'call', 'call', 'jmp', 'jmp', '', 'bad'][reg];
      break;
    }
    default: text = `db ${h(op)}`; kind = 'bad';
  }
  if (repp && /^(movs|cmps|stos|lods|scas|ins|outs)/.test(text)) text = (repp === 'rep ' && /^(cmps|scas)/.test(text) ? 'repe ' : repp) + text;
  else if (repp) text = repp + text;
  if (segp && !text.includes('[')) text = segp.slice(0, 2) + ' ' + text;
  text = lock + text;
  const len = (off - start) & 0xFFFF;
  const bytes = [];
  for (let i = 0; i < len; i++) bytes.push(at(start + i));
  return { seg, off: start, len, bytes, text, kind, target };
}

// disassemble around off so that off is on an instruction boundary: try each candidate start
// (symbols, recently executed addresses) and keep the one that decodes into off exactly
export function window(rb, seg, off, candidates, before = 8, after = 24) {
  let best = null;
  for (const c of [...new Set(candidates)].filter(c => c < off && off - c <= 96).sort((a, b) => a - b)) {
    const list = [];
    let o = c;
    while (o < off && list.length < 64) { const d = disasm(rb, seg, o); list.push(d); o += d.len; }
    if (o === off) { best = list; break; }
  }
  const out = (best || []).slice(-before);
  let o = off;
  for (let i = 0; i < after; i++) { const d = disasm(rb, seg, o); out.push(d); o = (o + d.len) & 0xFFFF; }
  return out;
}
