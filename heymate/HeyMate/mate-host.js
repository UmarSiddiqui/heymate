// HeyMate's host for ReferenceRenderer's native drawing canvas (mate-draw-native.js). In ReferenceRenderer the canvas runs in
// JavaScriptCore and the app paints what it records with Core Animation (ScreenDrawingNativePainter); neither the app
// nor that painter is in the copied sources. Here the canvas runs unchanged in a sandbox object on this page, this file
// answers its __host calls (clock, timers, Core Text-style measuring through the page's own SVG) and paints the render
// ops it drains into one SVG over the screen: the engine's own elements as they are, and the ones ReferenceRenderer's app
// draws itself (window chrome, photos) drawn here. 3D stages go to mate-stage3d.js.
//
// Needs, loaded first: three-r159.min.js, mate-three.js, mate-three-parts.js, mate-stage3d.js, and the sources
// in window.__mateSources = {native, engine, pieces} (text).
// API: HeyMateCanvas.begin({w, h, ink}), feed(code, done), line(k), lineLength(k, seconds), finish(), clear().
(function () {
  'use strict';
  const NS = 'http://www.w3.org/2000/svg';
  const G = {};                        // the canvas's own global, as JavaScriptCore's would be
  const nodes = new Map();             // render node number -> painted element
  let root = null, svg = null, defs = null, layers = {}, measureSvg = null;
  const now = () => performance.now() / 1000;
  const post = (type, body) => { try { window.webkit.messageHandlers.heymate.postMessage({ type, body }); } catch (_) {} };

  // ---------------------------------------------------------------- measuring (the app does this with Core Text)
  function measureRoot() {
    if (measureSvg) return measureSvg;
    measureSvg = document.createElementNS(NS, 'svg');
    Object.assign(measureSvg.style, { position: 'absolute', left: '-10000px', top: '0', width: '10px', height: '10px', visibility: 'hidden' });
    document.body.appendChild(measureSvg);
    return measureSvg;
  }
  function textElement(d) {
    const t = document.createElementNS(NS, 'text');
    t.setAttribute('font-family', d.family); t.setAttribute('font-size', d.size); t.setAttribute('font-weight', d.weight);
    t.setAttribute('text-anchor', d.anchor || 'start');
    if (d.baseline && d.baseline !== 'auto') t.setAttribute('dominant-baseline', d.baseline);
    t.setAttribute('x', d.x); t.setAttribute('y', d.y);
    fillLines(t, d.lines || []);
    return t;
  }
  function fillLines(t, lines) {
    if (lines.length === 1 && !lines[0].dy && (lines[0].x == null || lines[0].x === +t.getAttribute('x'))) { t.textContent = lines[0].text; return; }
    for (const line of lines) {
      const s = document.createElementNS(NS, 'tspan');
      if (line.x != null) s.setAttribute('x', line.x);
      if (line.dy) s.setAttribute('dy', line.dy);
      s.textContent = line.text;
      t.appendChild(s);
    }
  }
  const box = b => [b.x, b.y, b.width, b.height];
  function withPath(d, fn) {
    const p = document.createElementNS(NS, 'path'); p.setAttribute('d', d || 'M0 0');
    measureRoot().appendChild(p);
    try { return fn(p); } catch (_) { return null; } finally { p.remove(); }
  }
  const textCanvas = document.createElement('canvas').getContext('2d');

  // ---------------------------------------------------------------- the screen under the drawing
  // The screenshot the model saw, kept as one brightness per pixel (Rec. 709 luma of the sRGB values, 0..255), so
  // the canvas can ask about any area of it: how bright its background is (lumFor), which ink reads on it (inkFor)
  // and how busy it is (busyFor). A capture that is missing, malformed or too big leaves no screen at all: an earlier
  // turn's screenshot never answers for a new one.
  const MAX_SCREEN_PIXELS = 4096 * 4096;
  const LIGHT_GROUND = 0.58;                 // a background brighter than this takes dark ink (the engine's check agrees)
  const DARK_INK = '#15171C', LIGHT_INK = '#FFFFFF';
  const BINS = 20, SAMPLES_PER_SIDE = 32;
  let screen = null;                         // {w, h, luma, change}
  function setScreenPixels({ width: w, height: h, rgba } = {}) {
    screen = null;
    if (!Number.isSafeInteger(w) || !Number.isSafeInteger(h) || w < 1 || h < 1 || w * h > MAX_SCREEN_PIXELS ||
        typeof rgba !== 'string') return false;
    let raw;
    try { raw = atob(rgba); } catch (_) { return false; }
    if (raw.length !== w * h * 4) return false;
    const luma = new Uint8Array(w * h);
    for (let p = 0, i = 0; p < luma.length; p++, i += 4) {
      luma[p] = Math.round(0.2126 * raw.charCodeAt(i) + 0.7152 * raw.charCodeAt(i + 1) + 0.0722 * raw.charCodeAt(i + 2));
    }
    screen = { w, h, luma, change: changeTable(luma, w, h) };
    return true;
  }
  // How much brightness changes at each pixel, to its right and to the pixel below, as a summed-area table: entry
  // (x, y) holds the total over every pixel left of x and above y, so the total over any area is four lookups. The
  // last column and row have no neighbour and add nothing. Each pixel adds at most 510, so a 4096 x 4096 screen
  // stays within 32 bits.
  function changeTable(luma, w, h) {
    const table = new Uint32Array(w * h);
    for (let y = 1; y < h; y++) {
      let row = 0;
      for (let x = 1; x < w; x++) {
        const p = (y - 1) * w + (x - 1);
        row += Math.abs(luma[p + 1] - luma[p]) + Math.abs(luma[p + w] - luma[p]);
        table[y * w + x] = table[(y - 1) * w + x] + row;
      }
    }
    return table;
  }
  // The pixels an area covers, clipped to the screen ([left, top, right, bottom], inclusive), or null when it covers
  // less than two pixels each way.
  function area(x, y, w, h) {
    if (!screen || ![x, y, w, h].every(Number.isFinite)) return null;
    const left = Math.max(0, Math.floor(x)), top = Math.max(0, Math.floor(y));
    const right = Math.min(screen.w - 1, Math.ceil(x + w)), bottom = Math.min(screen.h - 1, Math.ceil(y + h));
    return left < right && top < bottom ? [left, top, right, bottom] : null;
  }
  // The background's brightness, 0..1 (-1: no screen there). Brightness is binned from up to 32 x 32 samples spread
  // evenly over the area, and the fullest bin wins, so words and icons on a page don't pull its background towards
  // them the way an average would. Equal bins go to the darker one.
  function backgroundLuminance(x, y, w, h) {
    const a = area(x, y, w, h);
    if (!a) return -1;
    const [left, top, right, bottom] = a, cols = Math.min(right - left + 1, SAMPLES_PER_SIDE), rows = Math.min(bottom - top + 1, SAMPLES_PER_SIDE);
    const sums = new Float64Array(BINS), counts = new Uint32Array(BINS);
    for (let r = 0; r < rows; r++) {
      const row = (top + Math.floor((r + 0.5) * (bottom - top + 1) / rows)) * screen.w;
      for (let c = 0; c < cols; c++) {
        const v = screen.luma[row + left + Math.floor((c + 0.5) * (right - left + 1) / cols)], bin = Math.min(BINS - 1, Math.floor(v * BINS / 255));
        sums[bin] += v; counts[bin]++;
      }
    }
    let best = 0;
    for (let b = 1; b < BINS; b++) if (counts[b] > counts[best]) best = b;
    return sums[best] / counts[best] / 255;
  }
  // How busy an area is, 0..1: the average change in brightness between neighbouring pixels across all of it. A
  // plain background is 0, text and controls raise it, a one-pixel checkerboard is 1.
  function busyness(x, y, w, h) {
    const a = area(x, y, w, h);
    if (!a) return 0;
    const [left, top, right, bottom] = a, t = screen.change, at = (cx, cy) => t[cy * screen.w + cx];
    const total = at(right, bottom) - at(left, bottom) - at(right, top) + at(left, top);
    return total / ((right - left) * (bottom - top) * 2 * 255);
  }
  const screenSampling = Object.freeze({
    set: setScreenPixels,
    clear: () => { screen = null; },
    inkFor: (x, y, w, h) => (backgroundLuminance(x, y, w, h) > LIGHT_GROUND ? DARK_INK : LIGHT_INK),
    busyFor: busyness,
    lumFor: backgroundLuminance,
  });

  const timers = new Map();
  const host = {
    now,
    schedule(id, seconds) {
      clearTimeout(timers.get(id));
      timers.set(id, setTimeout(() => { timers.delete(id); G.__fireTimer(id); paint(); }, Math.max(0, seconds) * 1000));
    },
    cancel(id) { clearTimeout(timers.get(id)); timers.delete(id); },
    log: message => console.log('[mate]', message),
    textBox(json) {
      const t = textElement(JSON.parse(json)); measureRoot().appendChild(t);
      try { return box(t.getBBox()); } finally { t.remove(); }
    },
    textWidth(family, size, weight, text) {
      textCanvas.font = `${weight || 400} ${size}px ${family}`;
      return textCanvas.measureText(String(text)).width;
    },
    pathBox: d => withPath(d, p => box(p.getBBox())) || [0, 0, 0, 0],
    pathLength: d => withPath(d, p => p.getTotalLength()) || 0,
    pathPoint: (d, length) => withPath(d, p => { const q = p.getPointAtLength(length); return [q.x, q.y]; }) || [0, 0],
    inkFor: screenSampling.inkFor,
    busyFor: screenSampling.busyFor,
    lumFor: screenSampling.lumFor,
    figuresFloat: () => true,
    shape3d: () => {},
    caption: text => post('caption', text),
    // What a mark sounds like (texture, moments, when): HeyMate plays its own sounds for it.
    markSound: (i, json) => { try { post('sound', JSON.parse(json)); } catch (_) {} },
    buttonReady: (i, seconds) => showButton(i, seconds),
  };

  // ---------------------------------------------------------------- the canvas, in its own global
  function boot() {
    const src = window.__mateSources;
    G.__host = host;
    G.globalThis = G;
    // JavaScriptCore has no animation frames: the engine's edits then run on the canvas's own timers, as in the app.
    G.requestAnimationFrame = undefined; G.cancelAnimationFrame = undefined;
    // The pieces run inside model programs (new Function), which see this page's globals, not G: they read these.
    for (const key of ['__mateInk', '__canvasUnitPoints', '__inkFor', '__busyFor', '__lumFor', '__figuresFloat', '__shape3d',
      '__hostDrawsPointers', '__hostDrawsButtons', '__hostDrawsWindows', '__hostDrawsMarquee', '__mateMotion', '__mateInTick3d']) {
      Object.defineProperty(window, key, { configurable: true, get: () => G[key], set: v => { G[key] = v; } });
    }
    const native = src.native.replace(/\}\)\(this\);\s*$/, '})(G);');
    new Function('G', 'with (G) {\n' + native + '\n' + src.engine + '\n}')(G);
    G.mateCanvas.setPieces(src.pieces);
  }

  // ---------------------------------------------------------------- painting what the canvas recorded
  const KEYFRAMES = `
    @keyframes pen { from { stroke-dashoffset: 1 } to { stroke-dashoffset: 0 } }
    @keyframes fadein { from { opacity: 0 } to { opacity: 1 } }
    @keyframes grow { from { opacity: 0; transform: scale(.6) } to { opacity: 1; transform: none } }
    @keyframes pop { 0% { opacity: 0; transform: scale(0) } 70% { opacity: 1; transform: scale(1.15) } 100% { transform: none } }
    @keyframes write { from { opacity: 0; clip-path: inset(0 100% 0 0) } 30% { opacity: 1 } to { opacity: 1; clip-path: inset(0 0 0 0) } }
    @keyframes swipe { from { transform: scaleX(0) } to { transform: none } }
    @keyframes marquee { from { opacity: 0; transform: scale(.2) } to { opacity: 1; transform: none } }
    @keyframes set { from { opacity: 1 } to { opacity: 1 } }
    #mate-canvas circle, #mate-canvas [data-pop] { transform-box: fill-box; transform-origin: center }
  `;
  function cssAnimation(a) {
    if (!a || !a.name) return '';
    const delay = (a.delay || 0) - (now() - (a.at || now()));
    return `${a.name} ${Math.max(0.001, a.dur || 0).toFixed(3)}s cubic-bezier(${(a.fn || [0.25, 0.1, 0.25, 1]).join(',')}) ${delay.toFixed(3)}s both`;
  }

  function el(tag, attrs, parent) {
    const e = document.createElementNS(NS, tag);
    for (const k in attrs) if (attrs[k] != null) e.setAttribute(k, attrs[k]);
    if (parent) parent.appendChild(e);
    return e;
  }

  // A little Mac window, as the pieces describe it: board in the paper tone, a title bar washed with Mate's ink,
  // red and green buttons, the title in grey, and a faint grid or dots on the board.
  let patterns = 0;
  function paintWindow(a) {
    const x = +a.x, y = +a.y, w = +a.width, h = +a.height, head = +a['data-header'] || 28, r = 10;
    const g = el('g', { 'data-window': '' });
    g.style.filter = 'drop-shadow(0 8px 18px rgba(0,0,0,.22)) drop-shadow(0 0 1px rgba(0,0,0,.45))';
    el('rect', { x, y, width: w, height: h, rx: r, fill: a['data-bg'] || '#FAF5EA' }, g);
    const board = a['data-board'] || 'plain';
    if (board === 'grid' || board === 'dots') {
      const id = 'mate-board-' + (++patterns);
      const p = el('pattern', { id, width: 24, height: 24, patternUnits: 'userSpaceOnUse', x, y: y + head }, defs);
      if (board === 'grid') el('path', { d: 'M24 0 L0 0 0 24', fill: 'none', stroke: '#000', 'stroke-opacity': 0.06, 'stroke-width': 1 }, p);
      else el('circle', { cx: 12, cy: 12, r: 1.2, fill: '#000', 'fill-opacity': 0.12 }, p);
      el('rect', { x, y: y + head, width: w, height: h - head, fill: `url(#${id})`, rx: r }, g);
    }
    const top = `M${x} ${y + head} V${y + r} Q${x} ${y} ${x + r} ${y} H${x + w - r} Q${x + w} ${y} ${x + w} ${y + r} V${y + head} Z`;
    el('path', { d: top, fill: '#E3E2E4' }, g);
    el('path', { d: top, fill: a['data-tint'] || '#0F7FFF', 'fill-opacity': a['data-tint-alpha'] || 0.08 }, g);
    el('rect', { x, y: y + head - 0.5, width: w, height: 0.5, fill: '#000', 'fill-opacity': 0.1 }, g);
    ['#FF736A', '#19C332'].forEach((c, k) => el('circle', { cx: x + 16 + 20 * k, cy: y + head / 2, r: 6, fill: c }, g));
    const title = (a['data-title'] || '').toLowerCase();
    if (title) {
      const t = el('text', { x: x + w / 2, y: y + head / 2 + 4.5, 'text-anchor': 'middle', 'font-family': '-apple-system, system-ui, sans-serif',
        'font-size': 13, 'font-weight': 600, fill: '#7E838D' }, g);
      t.textContent = title;
    }
    return g;
  }

  // ReferenceRenderer's app finds a real photo for the query as soon as it is written (the canvas lists it among the
  // analysis's actions); HeyMate asks its own finder (findPhoto) and paints it when the address comes back. Until
  // then the frame is a soft grey.
  const photoURLs = new Map(), photoFrames = new Map(), photosAsked = new Set();
  function askForPhotos(actions) {
    for (const a of actions || []) {
      if (a.role !== 'photo' || !a.text || photosAsked.has(a.text)) continue;
      photosAsked.add(a.text);
      post('findPhoto', a.text);
    }
  }
  function fillPhoto(frame, url) {
    const { g, x, y, w, h, r } = frame;
    if (g.querySelector('image')) return;
    const id = 'mate-photo-' + (++patterns);
    const clip = el('clipPath', { id }, defs);
    el('rect', { x, y, width: w, height: h, rx: r }, clip);
    const image = el('image', { x, y, width: w, height: h, href: url, preserveAspectRatio: 'xMidYMid slice', 'clip-path': `url(#${id})` }, g);
    image.style.opacity = '0'; image.style.transition = 'opacity .5s';
    image.addEventListener('load', () => { image.style.opacity = '1'; });
  }
  function paintPhoto(a) {
    const x = +a.x, y = +a.y, w = +a.width, h = +a.height, r = +a['data-radius'] || 2, query = String(a['data-query'] || '');
    const g = el('g', { transform: a['data-rotate'] ? `rotate(${a['data-rotate']} ${x + w / 2} ${y + h / 2})` : null });
    el('rect', { x, y, width: w, height: h, rx: r, fill: '#D9DCE2' }, g);
    const frame = { g, x, y, w, h, r };
    if (photoURLs.get(query)) fillPhoto(frame, photoURLs.get(query));
    else { if (!photoFrames.has(query)) photoFrames.set(query, []); photoFrames.get(query).push(frame); }
    return g;
  }

  function build(node) {
    let e;
    if (node.tag === 'window') e = paintWindow(node.a);
    else if (node.tag === 'photo') e = paintPhoto(node.a);
    else {
      e = document.createElementNS(NS, node.tag);
      for (const k in node.a) e.setAttribute(k, node.a[k]);
    }
    e.__n = node.n;
    nodes.set(node.n, e);
    if (node.st) for (const k in node.st) if (k !== 'animation') { try { e.style[k] = node.st[k]; } catch (_) {} }
    if (node.anim) e.style.animation = cssAnimation(node.anim);
    if (node.text) fillLines(e, node.text.lines || []);
    if (node.ch) for (const c of node.ch) e.appendChild(build(c));
    return e;
  }

  function targetOf(t) {
    if (t.mask) { const m = svg.querySelector(`mask[id="${t.mask}"]`); return m && m.querySelector('path'); }
    return nodes.get(t.n);
  }
  const matrix = xf => `matrix(${xf[0]} 0 0 ${xf[0]} ${xf[1]} ${xf[2]})`;
  // The motion's own timing curve, as CSS evaluates cubic-bezier(x1, y1, x2, y2).
  function bezier([x1, y1, x2, y2]) {
    const at = (a, b, t) => 3 * a * t * (1 - t) * (1 - t) + 3 * b * t * t * (1 - t) + t * t * t;
    return x => { let lo = 0, hi = 1; for (let k = 0; k < 24; k++) { const m = (lo + hi) / 2; if (at(x1, x2, m) < x) lo = m; else hi = m; } return at(y1, y2, (lo + hi) / 2); };
  }
  function glide(e, from, to, op) {
    // A drop lands at once (the canvas sends it as a 1 ms glide).
    if (op.dur < 0.05 && op.begin <= now() + 0.01) { e.setAttribute('transform', matrix(to)); return; }
    const ease = bezier(op.fn || [0.25, 0.1, 0.25, 1]), start = op.begin, dur = Math.max(0.001, op.dur);
    const step = () => {
      const p = Math.min(1, Math.max(0, (now() - start) / dur)), k = ease(p);
      e.setAttribute('transform', matrix(from.map((v, i) => v + (to[i] - v) * k)));
      if (p < 1) requestAnimationFrame(step);
    };
    step();
  }

  // Moving an element in the page restarts its CSS animations (a Core Animation layer in ReferenceRenderer keeps going).
  // Every draw-in animation ends on the element's own state (shown, unclipped, unscaled), so a finished one is simply
  // switched off before the move; one still running is put back where it had got to.
  function keepingAnimations(e, move) {
    const saved = [];
    for (const n of [e, ...e.querySelectorAll('*')]) {
      const anims = n.getAnimations ? n.getAnimations() : [];
      if (!anims.length) continue;
      if (anims.every(a => a.playState === 'finished')) n.style.animation = 'none';
      else saved.push([n, anims.map(a => a.currentTime)]);
    }
    move();
    for (const [n, times] of saved) {
      const anims = n.getAnimations ? n.getAnimations() : [];
      anims.forEach((a, i) => { if (times[i] != null) a.currentTime = times[i]; });
    }
  }

  function apply(ops) {
    for (const op of ops) {
      if (op.op === 'remove') { const e = nodes.get(op.n); if (e) { e.remove(); nodes.delete(op.n); } }
      else if (op.op === 'wrap') {
        const child = nodes.get(op.child); if (!child || !child.parentNode) continue;
        const g = document.createElementNS(NS, 'g'); g.__n = op.g; nodes.set(op.g, g);
        keepingAnimations(child, () => { child.parentNode.insertBefore(g, child); g.appendChild(child); });
      } else if (op.op === 'set') {
        const parent = op.group === 'defs' ? defs : layers[op.group];
        if (!parent) continue;
        const old = nodes.get(op.node.n);
        const e = build(op.node);
        const before = op.before != null ? nodes.get(op.before) : null;
        if (old && old.parentNode) old.replaceWith(e);
        else parent.insertBefore(e, before && before.parentNode === parent ? before : null);
      } else if (op.op === 'prop') {
        const e = targetOf(op); if (!e) continue;
        if (op.key === 'opacity') e.style.opacity = op.value;
        else if (op.key === 'transform') e.setAttribute('transform', op.value);
        else if (op.key === 'dash') e.style.strokeDashoffset = op.value;
      } else if (op.op === 'stop') {
        const e = targetOf(op); if (e) e.style.animation = 'none';
      } else if (op.op === 'motion') {
        const timing = { delay: Math.max(0, (op.begin - now()) * 1000), duration: op.dur * 1000, easing: `cubic-bezier(${op.fn.join(',')})`, fill: 'both' };
        for (const item of op.items) {
          const e = targetOf(item); if (!e) continue;
          // A CSS transform leaves an element's pen masks behind (they stay where it was): glide its SVG transform.
          if (item.key === 'transform') { glide(e, item.from, item.to, op); continue; }
          e.style.animation = 'none';
          const frames = item.key === 'dash' ? [{ strokeDashoffset: item.from }, { strokeDashoffset: item.to }]
            : [{ [item.key]: item.from }, { [item.key]: item.to }];
          try { e.animate(frames, timing); } catch (_) {}
        }
      }
    }
  }

  function paint() {
    if (!G.__drainRender) return;
    let text;
    try { text = G.__drainRender(); } catch (err) { console.warn('[mate] drain', err); return; }
    if (!text) return;
    const ops = JSON.parse(text);
    if (window.__mateDebugOps) window.__mateDebugOps.push(...ops);
    apply(ops);
  }

  // The figure()'s tick functions, one frame at a time (ReferenceRenderer's stage calls mateCanvas.tick3d the same way).
  const tickProvider = (stage, ticks, dt) => G.mateCanvas.tick3d({ stage, ticks, dt });

  function setUp(w, h) {
    if (!root) {
      const style = document.createElement('style'); style.textContent = KEYFRAMES; document.head.appendChild(style);
      root = document.createElement('div'); root.id = 'mate-canvas';
      Object.assign(root.style, { position: 'absolute', inset: '0', overflow: 'hidden', touchAction: 'none' });
      document.body.appendChild(root);
      root.addEventListener('pointerdown', onDown);
      root.addEventListener('pointermove', onMove);
      root.addEventListener('pointerup', onUp);
      root.addEventListener('pointercancel', onUp);
    }
    if (globalThis.MateStage3D) MateStage3D.reset();
    cardList = []; zoomed.clear(); gesture = null; lastRects = '';
    root.textContent = '';
    nodes.clear();
    svg = document.createElementNS(NS, 'svg');
    svg.setAttribute('viewBox', `0 0 ${w} ${h}`);
    Object.assign(svg.style, { position: 'absolute', inset: '0', width: '100%', height: '100%', overflow: 'visible' });
    defs = el('defs', {}, svg);
    layers = {};
    for (const id of ['under', 'main', 'hl', 'words']) layers[id] = el('g', { id }, svg);
    root.appendChild(svg);
    if (globalThis.MateStage3D) MateStage3D.attach(root, { tick3d: tickProvider, onBuild: buildAt });
  }

  function call(fn) { try { return fn(); } finally { paint(); } }

  // ---------------------------------------------------------------- the user's hands on the drawing
  // ReferenceRenderer's app lets cards be dragged (ScreenDrawingCardDragHandles), closed with their red button and made full
  // screen with their green one, and 3D figures turned and clicked. The canvas says what the cards are (cards()); the
  // app moves their elements while the pointer drags and tells the canvas where they were dropped (moveCard).
  let cardList = [], zoomed = new Map(), lastRects = '';
  // The canvas is the screenshot (its pixels are the model's coordinates); the page is the screen in points.
  let canvasW = 1, canvasH = 1;
  const unit = () => globalThis.__mateUnitPx || 1;
  // A 3D part starts growing: HeyMate's cursor flies to it and names it, so it looks like it builds the model.
  function buildAt(x, y, name) { post('pointAt', { x: x / unit(), y: y / unit(), label: name, role: 'build', w: canvasW, h: canvasH }); }
  const toPage = b => b.map(v => v * unit());
  function refreshHits() {
    if (!G.mateCanvas) return;
    try { cardList = JSON.parse(G.mateCanvas.cards() || '[]'); } catch (_) { cardList = []; }
    const rects = cardList.map(c => toPage(c.window ? c.window.box : c.box)).concat(globalThis.MateStage3D ? MateStage3D.rects : [])
      .concat([...buttons.values()].map(({ el }) => { const r = el.getBoundingClientRect(); return [r.left, r.top, r.width, r.height]; }));
    const key = JSON.stringify(rects.map(r => r.map(Math.round)));
    if (key !== lastRects) { lastRects = key; post('hitRects', rects); }
  }
  setInterval(refreshHits, 250);

  function cardAt(x, y) {
    for (let i = cardList.length - 1; i >= 0; i--) {
      const c = cardList[i], b = c.window ? c.window.box : c.box;
      if (x >= b[0] && x <= b[0] + b[2] && y >= b[1] && y <= b[1] + b[3]) return c;
    }
    return null;
  }
  // The window's red and green buttons, where paintWindow drew them.
  function buttonAt(card, x, y) {
    const w = card.window; if (!w) return null;
    const s = w.scale || 1, head = (w.header || 28) * s, cy = w.box[1] + head / 2;
    for (const [name, cx] of [['close', w.box[0] + 16 * s], ['zoom', w.box[0] + 36 * s]]) if (Math.hypot(x - cx, y - cy) <= 9 * s) return name;
    return null;
  }
  function zoom(card) {
    const key = card.marks.join(',');
    if (zoomed.has(key)) { zoomed.delete(key); return call(() => G.mateCanvas.zoomCard({ marks: card.marks, to: null })); }
    const [x, y, w, h] = card.window.box, W = canvasW, H = canvasH;
    const k = Math.min((W - 120 / unit()) / w, (H - 120 / unit()) / h);
    zoomed.set(key, true);
    call(() => G.mateCanvas.zoomCard({ marks: card.marks, to: [k, (W - k * w) / 2 - k * x, (H - k * h) / 2 - k * y] }));
  }

  let gesture = null, analysis = null, heardLine = -1, pointed = new Set(), lineOffset = 0;
  // Each pointer once, as soon as both its line is being heard and its statement has arrived.
  // Pointers fly HeyMate's cursor; typeText, copyText, openPage and handOff are the app's to carry out, each once,
  // as its line is heard.
  const POINTERS = ['point', 'target', 'hover'], ACTIONS = ['type', 'copy', 'open', 'handoff'];
  function pointForHeardLines() {
    for (const a of (analysis && analysis.actions) || []) {
      if (a.line > heardLine || pointed.has(a.i)) continue;
      if (POINTERS.includes(a.role)) post('pointAt', { x: a.x, y: a.y, box: a.box, label: a.label, role: a.role, w: canvasW, h: canvasH });
      else if (ACTIONS.includes(a.role)) post('action', { role: a.role, text: a.text, x: a.x, y: a.y, w: canvasW, h: canvasH });
      else continue;
      pointed.add(a.i);
    }
  }

  // ---------------------------------------------------------------- buttons (ScreenDrawingActionButtons in the app)
  // button() leaves a spot with its box and {text, kind, value}; the canvas says when its beat is drawn and it can go up.
  const buttons = new Map();             // mark index -> {el, box (canvas units), payload}
  function showButton(i, seconds, tries = 0) {
    const a = ((analysis && analysis.actions) || []).find(x => x.i === i && x.role === 'button');
    if (!a) { if (tries < 20) setTimeout(() => showButton(i, seconds, tries + 1), 100); return; }
    if (buttons.has(i)) return;
    let payload = {};
    try { payload = JSON.parse(a.text || '{}'); } catch (_) { return; }
    const box = a.box || [a.x, a.y, 120, 30];
    const el = document.createElement('button');
    el.dataset.mateButton = String(i);
    el.textContent = payload.text + (payload.kind === 'open' ? '  ↗' : '');
    const ink = G.__mateInk || '#3380FF';
    Object.assign(el.style, { position: 'absolute', font: '600 13px -apple-system, system-ui, sans-serif', color: '#15171C', whiteSpace: 'nowrap',
      background: `linear-gradient(#FFFFFF, ${ink}33)`, border: `1px solid ${ink}66`, borderRadius: '999px', padding: '0 14px',
      boxShadow: '0 2px 8px rgba(0,0,0,.25)', cursor: 'pointer', opacity: '0', transform: 'scale(.85)', transition: 'opacity .25s, transform .25s' });
    placeButton(el, box);
    el.addEventListener('click', ev => { ev.stopPropagation(); post('button', payload); el.style.transform = 'scale(.94)'; setTimeout(() => { el.style.transform = 'none'; }, 120); });
    root.appendChild(el);
    buttons.set(i, { el, box: box.slice(), payload });
    setTimeout(() => { el.style.opacity = '1'; el.style.transform = 'none'; refreshHits(); }, Math.max(0, seconds) * 1000);
  }
  function placeButton(el, box) {
    const u = unit();
    Object.assign(el.style, { left: box[0] * u + 'px', top: box[1] * u + 'px', minWidth: box[2] * u + 'px', height: box[3] * u + 'px' });
  }
  const inside = (b, card) => b[0] >= card[0] - 4 && b[1] >= card[1] - 4 && b[0] + b[2] <= card[0] + card[2] + 4 && b[1] + b[3] <= card[1] + card[3] + 4;
  // A card's buttons ride with it when it is dropped, and go with it when it is closed.
  function buttonsOn(card) { const b = card.window ? card.window.box : card.box; return [...buttons.entries()].filter(([, v]) => inside(v.box, b)); }
  function clearButtons() { for (const { el } of buttons.values()) el.remove(); buttons.clear(); }
  function onDown(ev) {
    if (ev.target && ev.target.closest && ev.target.closest('[data-mate-button]')) return;
    const x = ev.clientX, y = ev.clientY;
    refreshHits();
    post('touched', null);
    const st = globalThis.MateStage3D && MateStage3D.stageAt(x, y);
    const card = st ? null : cardAt(x / unit(), y / unit());
    if (!st && !card) return;
    gesture = { x, y, st, card, moved: false, lx: x, ly: y };
    try { root.setPointerCapture(ev.pointerId); } catch (_) {}
    ev.preventDefault();
  }
  function onMove(ev) {
    if (!gesture) return;
    const dx = (ev.clientX - gesture.x) / unit(), dy = (ev.clientY - gesture.y) / unit();
    if (Math.hypot(ev.clientX - gesture.x, ev.clientY - gesture.y) > 3) gesture.moved = true;
    if (gesture.st) { MateStage3D.turn(gesture.st, ev.clientX - gesture.lx, ev.clientY - gesture.ly); gesture.lx = ev.clientX; gesture.ly = ev.clientY; }
    else if (gesture.moved) for (const n of gesture.card.units) {
      const e = nodes.get(n); if (!e) continue;
      if (e.__dragBase === undefined) e.__dragBase = e.getAttribute('transform') || '';
      e.setAttribute('transform', `translate(${dx} ${dy}) ${e.__dragBase}`.trim());
    }
  }
  function onUp(ev) {
    const g = gesture; gesture = null;
    if (!g) return;
    const dx = (ev.clientX - g.x) / unit(), dy = (ev.clientY - g.y) / unit();
    if (g.st) {
      if (!g.moved) { const part = MateStage3D.pick(g.st, ev.clientX, ev.clientY); if (part) post('askPart', part); }
      return;
    }
    for (const n of g.card.units) {
      const e = nodes.get(n); if (!e || e.__dragBase === undefined) continue;
      if (e.__dragBase) e.setAttribute('transform', e.__dragBase); else e.removeAttribute('transform');
      delete e.__dragBase;
    }
    if (g.moved) {
      for (const [, b] of buttonsOn(g.card)) { b.box[0] += dx; b.box[1] += dy; placeButton(b.el, b.box); }
      call(() => G.mateCanvas.moveCard({ marks: g.card.marks, dx, dy })); refreshHits(); return;
    }
    const button = buttonAt(g.card, ev.clientX / unit(), ev.clientY / unit());
    if (button === 'close') {
      for (const [i, b] of buttonsOn(g.card)) { b.el.remove(); buttons.delete(i); }
      const result = JSON.parse(call(() => G.mateCanvas.closeCard({ marks: g.card.marks })) || '{}');
      refreshHits();
      if (!result.left) setTimeout(() => post('empty', null), 600);
    } else if (button === 'zoom') { zoom(g.card); setTimeout(refreshHits, 600); }
  }
  (function loop() { paint(); requestAnimationFrame(loop); })();

  globalThis.HeyMateCanvas = {
    screenSampling,
    // w, h: the canvas in the screenshot's pixels; width: the screen's width in points.
    begin({ w, h, width, ink }) {
      if (!G.mateCanvas) boot();
      clearButtons();
      canvasW = w; canvasH = h; heardLine = -1; pointed = new Set(); analysis = null; lineOffset = 0;
      globalThis.__mateUnitPx = (width || w) / w;
      setUp(w, h);
      return call(() => G.mateCanvas.beginStream({ w, h, width: width || w, subtitles: false, ink: ink || '#3380FF' }));
    },
    feed: (code, done) => call(() => {
      const json = G.mateCanvas.feed({ code, done: !!done });
      try { const a = JSON.parse(json); if (a && a.actions) { analysis = a; askForPhotos(a.actions); } } catch (_) {}
      pointForHeardLines();
      return json;
    }),
    // A line starts: its strokes draw, and HeyMate's cursor flies to what it points at (the app's own pointer for
    // target and hover, which the canvas leaves to it).
    // k counts this turn's lines; a continued drawing's lines carry on from the turns before (continueStream).
    line: k => call(() => {
      const ok = G.mateCanvas.line(lineOffset + k);
      heardLine = Math.max(heardLine, lineOffset + k);
      pointForHeardLines();
      return ok;
    }),
    lineLength: (k, seconds) => call(() => G.mateCanvas.lineLength(lineOffset + k, seconds)),
    // A new turn on the drawing already showing: what was drawn stays, what was still waiting goes, and feed() now
    // takes only the new turn's code (it runs after the earlier turns', so their names still work).
    continue() {
      const json = call(() => G.mateCanvas.continueStream({}));
      try { lineOffset = JSON.parse(json).firstLine || 0; } catch (_) {}
      return json;
    },
    // HeyMate found the photo for a query (null: none found, the frame stays grey).
    photoFound(query, url) {
      if (!url) return;
      photoURLs.set(query, url);
      for (const frame of photoFrames.get(query) || []) fillPhoto(frame, url);
      photoFrames.delete(query);
    },
    // What is on the drawing now, for the model (its parts with ids like p3, their boxes, what was said), or null.
    state: () => (G.mateCanvas ? G.mateCanvas.state() : null),
    screenChanged: () => call(() => {
      screenSampling.clear();
      if (!G.mateCanvas) return null;
      // A finished screen annotation must not point at a newly scrolled or
      // switched app. Cards and their attached marks remain useful notes.
      const result = G.mateCanvas.isFinished()
        ? G.mateCanvas.keepNotesOnly() : G.mateCanvas.dropPointing();
      analysis = null;
      refreshHits();
      return result;
    }),
    finish: () => call(() => G.mateCanvas.finish()),
    isFinished: () => G.mateCanvas ? G.mateCanvas.isFinished() : true,
    clear: () => {
      const result = call(() => G.mateCanvas && G.mateCanvas.clear());
      // The native canvas removes its virtual stage as a whole. Its render
      // stream does not enumerate every descendant for this host to remove.
      clearButtons();
      photoFrames.clear(); photoURLs.clear(); photosAsked.clear();
      setUp(canvasW, canvasH);
      analysis = null; heardLine = -1; pointed.clear();
      refreshHits();
      return result;
    },
    get canvas() { return G.mateCanvas; },
  };
})();
