// vga.js · draws the emulated VGA onto a <canvas>, pixel by pixel, like the hardware would:
//   text mode: 80x25 cells of 9x16 pixels = 720x400, glyphs from an 8x16 font ROM,
//              the 9th column repeats column 8 for line-drawing characters (C0h-DFh),
//              attribute bit 7 blinks, the cursor is drawn on its scanlines from the BDA
//   mode 13h:  320x200, one byte per pixel at A000:0000, colours from the DAC palette

const TEXT_PALETTE = ['#000000', '#0000aa', '#00aa00', '#00aaaa', '#aa0000', '#aa00aa', '#aa5500', '#aaaaaa',
  '#555555', '#5555ff', '#55ff55', '#55ffff', '#ff5555', '#ff55ff', '#ffff55', '#ffffff']
  .map(h => 0xFF000000 | (parseInt(h.slice(5, 7), 16) << 16) | (parseInt(h.slice(3, 5), 16) << 8) | parseInt(h.slice(1, 3), 16));

export class VGA {
  constructor(canvas) {
    this.cv = canvas;
    this.ctx = canvas.getContext('2d', { alpha: false });
    this.mode = -1; this.sig = ''; this.frames = 0; this.dacSeen = -1; this.pal256 = new Uint32Array(256);
  }
  setMode(mode) {
    this.mode = mode;
    const [w, h] = mode === 0x13 ? [320, 200] : [720, 400];
    this.cv.width = w; this.cv.height = h;
    this.img = this.ctx.createImageData(w, h);
    this.px = new Uint32Array(this.img.data.buffer);
    this.sig = '';
  }
  draw(m) {
    this.frames++;
    const mode = m.mem[0x449] === 0x13 ? 0x13 : 0x03;
    if (mode !== this.mode) this.setMode(mode);
    return mode === 0x13 ? this.drawGraphics(m) : this.drawText(m);
  }
  drawGraphics(m) {
    if (this.dacSeen !== m.dacVersion) {
      this.dacSeen = m.dacVersion;
      for (let i = 0; i < 256; i++) {
        const r = m.dac[i * 3] * 255 / 63 | 0, g = m.dac[i * 3 + 1] * 255 / 63 | 0, b = m.dac[i * 3 + 2] * 255 / 63 | 0;
        this.pal256[i] = 0xFF000000 | (b << 16) | (g << 8) | r;
      }
    }
    const v = m.mem, px = this.px, pal = this.pal256;
    for (let i = 0; i < 64000; i++) px[i] = pal[v[0xA0000 + i]];
    this.ctx.putImageData(this.img, 0, 0);
    return true;
  }
  drawText(m) {
    const mem = m.mem, font = m.mem, FONT = 0xC1000;
    const blinkOn = (this.frames >> 4) & 1;          // ~2 Hz at 60 fps, like the real 16-frame blink
    const curStart = mem[0x461] & 0x1F, curEnd = mem[0x460] & 0x1F, curOff = mem[0x461] & 0x20;
    const cx = mem[0x450], cy = mem[0x451];
    // only repaint when video memory, the cursor or the blink phase changed
    let h = 2166136261;
    for (let i = 0xB8000; i < 0xB8000 + 4000; i++) h = Math.imul(h ^ mem[i], 16777619);
    const sig = `${h}|${cx},${cy},${curStart},${curEnd},${curOff}|${blinkOn}`;
    if (sig === this.sig) return false;
    this.sig = sig;
    const px = this.px, W = 720;
    for (let row = 0; row < 25; row++) {
      for (let col = 0; col < 80; col++) {
        const cell = 0xB8000 + (row * 80 + col) * 2, ch = mem[cell], at = mem[cell + 1];
        let fg = TEXT_PALETTE[at & 15];
        const bg = TEXT_PALETTE[(at >> 4) & 7];
        if (at & 0x80 && !blinkOn) fg = bg;
        const line = ch >= 0xC0 && ch <= 0xDF;
        const isCur = row === cy && col === cx && !curOff && blinkOn;
        let o = row * 16 * W + col * 9;
        for (let y = 0; y < 16; y++, o += W) {
          let bits = font[FONT + ch * 16 + y];
          if (isCur && y >= curStart && y <= curEnd) bits = 0xFF;
          px[o] = bits & 0x80 ? fg : bg; px[o + 1] = bits & 0x40 ? fg : bg; px[o + 2] = bits & 0x20 ? fg : bg; px[o + 3] = bits & 0x10 ? fg : bg;
          px[o + 4] = bits & 0x08 ? fg : bg; px[o + 5] = bits & 0x04 ? fg : bg; px[o + 6] = bits & 0x02 ? fg : bg; px[o + 7] = bits & 0x01 ? fg : bg;
          px[o + 8] = line && bits & 0x01 ? fg : (isCur && y >= curStart && y <= curEnd ? fg : bg);
        }
      }
    }
    this.ctx.putImageData(this.img, 0, 0);
    return true;
  }
}
