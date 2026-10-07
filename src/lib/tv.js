// tv.js · the Watch window's smart TV: the girl from panic-sheet.png on a clean 16:9 panel
//   calm:  frame 0, a slow breath, the player's controls fade out like a real TV app
//   panic: the 16 frames at a readable 12 fps, the picture dims while the player stalls
const PAPER = '#f2f2f0';

export function createTV(canvas, { sheetUrl = '/girl/panic-sheet.png', metaUrl = '/girl/panic-sheet.json', reduce = false } = {}) {
  const ctx = canvas.getContext('2d');
  let meta = null, frames = null, panic = false, panicAt = 0, w = 0, h = 0, paper = PAPER;

  Promise.all([fetch(metaUrl).then(r => r.json()), new Promise((ok, no) => { const i = new Image(); i.onload = () => ok(i); i.onerror = no; i.src = sheetUrl; })])
    .then(([m, img]) => {
      meta = m;
      frames = Array.from({ length: m.frames }, (_, i) => {
        const c = document.createElement('canvas'); c.width = c.height = m.size;
        c.getContext('2d').drawImage(img, (i % m.cols) * m.size, Math.floor(i / m.cols) * m.size, m.size, m.size, 0, 0, m.size, m.size);
        return c;
      });
      const [r, g, b] = frames[0].getContext('2d').getImageData(2, 2, 1, 1).data;   // the GIF's own paper white, so the frame has no edges
      paper = `rgb(${r},${g},${b})`;
      canvas.classList.add('ready');
    }).catch(() => canvas.classList.add('failed'));

  function resize() {
    const r = canvas.getBoundingClientRect(), dpr = Math.min(2, devicePixelRatio || 1);
    const W = Math.round(r.width * dpr), H = Math.round(r.height * dpr);
    if (W !== w || H !== h) { w = canvas.width = W; h = canvas.height = H; }
  }

  function draw(now) {
    if (!frames) return;
    resize();
    if (!w || !h) return;
    const t = now / 1000;
    ctx.globalAlpha = 1;
    ctx.fillStyle = paper; ctx.fillRect(0, 0, w, h);
    const n = panic && !reduce ? Math.floor(Math.max(0, now - panicAt) / 83) % frames.length : 0;   // rAF time can trail performance.now()
    const breath = reduce || panic ? 1 : 1 + 0.01 * Math.sin(t * 1.6);
    const s = h * 1.02 * breath, x = (w - s) / 2, y = (h - s) / 2 + h * 0.03;
    ctx.imageSmoothingQuality = 'high';
    ctx.drawImage(frames[n], x, y, s, s);
    if (panic) { ctx.fillStyle = 'rgba(0,0,0,.35)'; ctx.fillRect(0, 0, w, h); }
  }

  return {
    setPanic(on) { if (on && !panic) panicAt = performance.now(); panic = on; },
    draw,
    get ready() { return !!frames; },
  };
}
