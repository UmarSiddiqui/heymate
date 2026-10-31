// The page HeyMate's drawing window shows (Explainer.swift loads it in a transparent WKWebView over the screen).
// It runs the drawing canvas (mate-draw-native.js with mate-draw-engine.js and the pieces) in a global of its own,
// answers the canvas's host calls (clock, timers, text and path measuring through this page's SVG, and what the
// screen under an area looks like, from the screenshot the model saw), paints the render ops the canvas records
// into one SVG over the screen, and lets the user drag, zoom and close the cards it draws and press their buttons.
// The things the canvas leaves to the app to draw (window chrome, photos, buttons) are drawn here. 3D stages go to
// mate-stage3d.js. Anything the user or the drawing asks of the app (pointing, sounds, photos, button presses)
// goes to Swift as a message on the 'heymate' handler.
//
// Needs, loaded first: three-r159.min.js, mate-three.js, mate-three-parts.js, mate-stage3d.js, and the sources
// in window.__mateSources = {native, engine, pieces} (text).
// API: HeyMateCanvas.begin({w, h, width, ink}), feed(code, done), line(k), lineLength(k, seconds), continue(),
// finish(), screenChanged(), photoFound(query, url), state(), clear(), screenSampling.
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

  // ---------------------------------------------------------------- what the canvas asks of its host
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
  // The page's globals the pieces read: they run inside model programs (new Function), which see this page, not G.
  const SHARED_GLOBALS = ['__mateInk', '__canvasUnitPoints', '__inkFor', '__busyFor', '__lumFor', '__figuresFloat', '__shape3d',
    '__hostDrawsPointers', '__hostDrawsButtons', '__hostDrawsWindows', '__hostDrawsMarquee', '__mateMotion', '__mateInTick3d'];
  function boot() {
    const src = window.__mateSources;
    Object.assign(G, { __host: host, globalThis: G });
    // As in JavaScriptCore, no animation frames: the engine's edits run on the canvas's own timers.
    G.requestAnimationFrame = G.cancelAnimationFrame = undefined;
    for (const key of SHARED_GLOBALS) Object.defineProperty(window, key, { configurable: true, get: () => G[key], set: v => { G[key] = v; } });
    const native = src.native.replace(/\}\)\(this\);\s*$/, '})(G);');
    new Function('G', 'with (G) {\n' + native + '\n' + src.engine + '\n}')(G);
    G.mateCanvas.setPieces(src.pieces);
  }

  // ---------------------------------------------------------------- painting what the canvas recorded
  // The canvas records its drawing as render ops (set, remove, wrap, prop, stop, motion); paint() drains them after
  // every call and every timer and applies them to one SVG over the screen, in four layers.
  const LAYERS = ['under', 'main', 'hl', 'words'];
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
  const CSS_EASE = [0.25, 0.1, 0.25, 1];
  // A draw-in animation, started `delay` seconds after the canvas recorded it (`at`): a late paint starts it part way.
  function cssAnimation(a) {
    if (!a || !a.name) return '';
    const delay = (a.delay || 0) - (now() - (a.at || now()));
    return `${a.name} ${Math.max(0.001, a.dur || 0).toFixed(3)}s cubic-bezier(${(a.fn || CSS_EASE).join(',')}) ${delay.toFixed(3)}s both`;
  }
  function el(tag, attrs, parent) {
    const e = document.createElementNS(NS, tag);
    for (const k in attrs) if (attrs[k] != null) e.setAttribute(k, attrs[k]);
    if (parent) parent.appendChild(e);
    return e;
  }

  // The things the canvas leaves to the app to draw. Each keeps its own pattern or clip inside it, so they leave with it.
  // A little Mac window, as the pieces describe it: board in the paper tone, a title bar washed with Mate's ink,
  // red and green buttons, the title in grey, and a faint grid or dots on the board.
  const WINDOW = { corner: 10, header: 28, paper: '#FAF5EA', bar: '#E3E2E4', tint: '#0F7FFF', tintAlpha: 0.08, buttons: ['#FF736A', '#19C332'], title: '#7D8088' };
  function paintWindow(a, n) {
    const x = +a.x, y = +a.y, w = +a.width, h = +a.height, head = +a['data-header'] || WINDOW.header, r = WINDOW.corner;
    const g = el('g', { 'data-window': '' });
    g.style.filter = 'drop-shadow(0 8px 18px rgba(0,0,0,.22)) drop-shadow(0 0 1px rgba(0,0,0,.45))';
    el('rect', { x, y, width: w, height: h, rx: r, fill: a['data-bg'] || WINDOW.paper }, g);
    const board = a['data-board'];
    if (board === 'grid' || board === 'dots') {
      const id = `mate-board-${n}`;
      const pattern = el('pattern', { id, width: 24, height: 24, patternUnits: 'userSpaceOnUse', x, y: y + head }, el('defs', {}, g));
      if (board === 'grid') el('path', { d: 'M24 0 L0 0 0 24', fill: 'none', stroke: '#000', 'stroke-opacity': 0.06, 'stroke-width': 1 }, pattern);
      else el('circle', { cx: 12, cy: 12, r: 1.2, fill: '#000', 'fill-opacity': 0.12 }, pattern);
      el('rect', { x, y: y + head, width: w, height: h - head, fill: `url(#${id})`, rx: r }, g);
    }
    const bar = `M${x} ${y + head} V${y + r} Q${x} ${y} ${x + r} ${y} H${x + w - r} Q${x + w} ${y} ${x + w} ${y + r} V${y + head} Z`;
    el('path', { d: bar, fill: WINDOW.bar }, g);
    el('path', { d: bar, fill: a['data-tint'] || WINDOW.tint, 'fill-opacity': a['data-tint-alpha'] || WINDOW.tintAlpha }, g);
    el('rect', { x, y: y + head - 0.5, width: w, height: 0.5, fill: '#000', 'fill-opacity': 0.1 }, g);
    WINDOW.buttons.forEach((fill, k) => el('circle', { cx: x + 16 + 20 * k, cy: y + head / 2, r: 6, fill }, g));
    const title = (a['data-title'] || '').toLowerCase();
    if (title) {
      el('text', { x: x + w / 2, y: y + head / 2 + 4.5, 'text-anchor': 'middle', 'font-family': '-apple-system, system-ui, sans-serif',
        'font-size': 13, 'font-weight': 600, fill: WINDOW.title }, g).textContent = title;
    }
    return g;
  }
  // A photo for a query: a soft grey frame until HeyMate's photo finder (findPhoto, asked once per query) sends an
  // address, then the photo fades in, cropped to the frame.
  const photoURLs = new Map(), photoFrames = new Map(), photosAsked = new Set();
  function askForPhotos(actions) {
    for (const a of actions || []) {
      if (a.role !== 'photo' || !a.text || photosAsked.has(a.text)) continue;
      photosAsked.add(a.text);
      post('findPhoto', a.text);
    }
  }
  function fillPhoto(frame, url) {
    const { g, x, y, w, h, r, id } = frame;
    if (g.querySelector('image')) return;
    el('rect', { x, y, width: w, height: h, rx: r }, el('clipPath', { id }, el('defs', {}, g)));
    const image = el('image', { x, y, width: w, height: h, href: url, preserveAspectRatio: 'xMidYMid slice', 'clip-path': `url(#${id})` }, g);
    image.style.opacity = '0'; image.style.transition = 'opacity .5s';
    image.addEventListener('load', () => { image.style.opacity = '1'; });
  }
  function paintPhoto(a, n) {
    const x = +a.x, y = +a.y, w = +a.width, h = +a.height, r = +a['data-radius'] || 2, query = String(a['data-query'] || '');
    const g = el('g', { transform: a['data-rotate'] ? `rotate(${a['data-rotate']} ${x + w / 2} ${y + h / 2})` : null });
    el('rect', { x, y, width: w, height: h, rx: r, fill: '#D9DCE2' }, g);
    const frame = { g, x, y, w, h, r, id: `mate-photo-${n}` };
    if (photoURLs.get(query)) fillPhoto(frame, photoURLs.get(query));
    else { if (!photoFrames.has(query)) photoFrames.set(query, []); photoFrames.get(query).push(frame); }
    return g;
  }
  const APP_DRAWN = { window: paintWindow, photo: paintPhoto };

  // One recorded node (and its children) as page elements.
  function build(node) {
    const e = APP_DRAWN[node.tag] ? APP_DRAWN[node.tag](node.a, node.n) : el(node.tag, node.a);
    e.__n = node.n;
    nodes.set(node.n, e);
    if (node.st) for (const k in node.st) if (k !== 'animation') { try { e.style[k] = node.st[k]; } catch (_) {} }
    if (node.anim) e.style.animation = cssAnimation(node.anim);
    if (node.text) fillLines(e, node.text.lines || []);
    for (const c of node.ch || []) e.appendChild(build(c));
    return e;
  }
  // What an op addresses: a node by number, or the pen path inside a mask by the mask's id.
  function targetOf(t) {
    if (t.mask) { const m = svg.querySelector(`mask[id="${t.mask}"]`); return m && m.querySelector('path'); }
    return nodes.get(t.n);
  }

  // Edits in motion. Opacity and the pen's dash run as Web Animations; when one ends its last value is written to
  // the element and the animation dropped, so a later change to that property (an undo, a restyle) shows. A move
  // glides the element's SVG transform (a CSS transform would leave its pen masks behind), one glide per element at a
  // time: a new move starts from where the last one had got to.
  const STYLE_OF = { opacity: 'opacity', dash: 'strokeDashoffset' };
  const matrix = xf => `matrix(${xf[0]} 0 0 ${xf[0]} ${xf[1]} ${xf[2]})`;
  // A timing curve as CSS evaluates cubic-bezier(x1, y1, x2, y2): progress in time -> progress along the move.
  function bezier([x1, y1, x2, y2]) {
    const at = (a, b, t) => 3 * a * t * (1 - t) * (1 - t) + 3 * b * t * t * (1 - t) + t * t * t;
    return x => { let lo = 0, hi = 1; for (let k = 0; k < 24; k++) { const m = (lo + hi) / 2; if (at(x1, x2, m) < x) lo = m; else hi = m; } return at(y1, y2, (lo + hi) / 2); };
  }
  function glide(e, from, to, op) {
    const run = e.__glide = {};
    // A drop lands at once (the canvas sends it as a 1 ms glide).
    if (op.dur < 0.05 && op.begin <= now() + 0.01) { e.setAttribute('transform', matrix(to)); return; }
    const ease = bezier(op.fn || CSS_EASE), dur = Math.max(0.001, op.dur);
    const step = () => {
      if (e.__glide !== run) return;
      const p = Math.min(1, Math.max(0, (now() - op.begin) / dur)), k = ease(p);
      e.setAttribute('transform', matrix(from.map((v, i) => v + (to[i] - v) * k)));
      if (p < 1) requestAnimationFrame(step); else e.__glide = null;
    };
    step();
  }
  function stopAnimating(e, key) {
    for (const a of e.getAnimations ? e.getAnimations() : []) {
      if (a.animationName) continue;                       // the draw-in (CSS) animation
      if (!key || a.effect.getKeyframes().some(f => STYLE_OF[key] in f)) a.cancel();
    }
    if (!key || key === 'transform') e.__glide = null;
  }
  function animate(e, key, from, to, op) {
    stopAnimating(e, key);
    e.style.animation = 'none';
    const prop = STYLE_OF[key];
    if (!prop) return;
    try {
      const a = e.animate([{ [prop]: from }, { [prop]: to }],
        { delay: Math.max(0, (op.begin - now()) * 1000), duration: op.dur * 1000, easing: `cubic-bezier(${op.fn.join(',')})`, fill: 'both' });
      a.finished.then(() => { e.style[prop] = to; a.cancel(); }, () => {});
    } catch (_) {}
  }

  // Moving an element in the page restarts its CSS animations (a Core Animation layer would keep going). Every
  // draw-in animation ends on the element's own state (shown, unclipped, unscaled), so a finished one is switched off
  // before the move; one still running is put back where it had got to.
  function keepingAnimations(e, move) {
    const running = [];
    for (const n of [e, ...e.querySelectorAll('*')]) {
      const anims = n.getAnimations ? n.getAnimations() : [];
      if (!anims.length) continue;
      if (anims.every(a => a.playState === 'finished')) n.style.animation = 'none';
      else running.push([n, anims.map(a => a.currentTime)]);
    }
    move();
    for (const [n, times] of running) (n.getAnimations ? n.getAnimations() : []).forEach((a, i) => { if (times[i] != null) a.currentTime = times[i]; });
  }

  const APPLY = {
    remove(op) { const e = nodes.get(op.n); if (e) { e.remove(); nodes.delete(op.n); } },
    // An element gets a group around it (for a later move or scale of the group).
    wrap(op) {
      const child = nodes.get(op.child);
      if (!child || !child.parentNode) return;
      const g = el('g', {}); g.__n = op.g; nodes.set(op.g, g);
      keepingAnimations(child, () => { child.parentNode.insertBefore(g, child); g.appendChild(child); });
    },
    // A node is new or redrawn: it replaces the element it was, else goes into its layer before `before`.
    set(op) {
      const parent = op.group === 'defs' ? defs : layers[op.group];
      if (!parent) return;
      const old = nodes.get(op.node.n), e = build(op.node), before = op.before != null ? nodes.get(op.before) : null;
      if (old && old.parentNode) old.replaceWith(e);
      else parent.insertBefore(e, before && before.parentNode === parent ? before : null);
    },
    prop(op) {
      const e = targetOf(op);
      if (!e) return;
      stopAnimating(e, op.key);
      if (op.key === 'transform') e.setAttribute('transform', op.value);
      else if (STYLE_OF[op.key]) e.style[STYLE_OF[op.key]] = op.value;
    },
    stop(op) { const e = targetOf(op); if (e) { e.style.animation = 'none'; stopAnimating(e); } },
    motion(op) {
      for (const item of op.items) {
        const e = targetOf(item);
        if (!e) continue;
        if (item.key === 'transform') { stopAnimating(e, 'transform'); glide(e, item.from, item.to, op); }
        else animate(e, item.key, item.from, item.to, op);
      }
    },
  };
  function paint() {
    if (!G.__drainRender) return;
    let ops;
    try { const text = G.__drainRender(); if (!text) return; ops = JSON.parse(text); } catch (err) { console.warn('[mate] drain', err); return; }
    if (window.__mateDebugOps) window.__mateDebugOps.push(...ops);
    for (const op of ops) if (APPLY[op.op]) APPLY[op.op](op);
  }

  // The figure()'s tick functions, one frame at a time (the stage calls mateCanvas.tick3d each frame).
  const tickProvider = (stage, ticks, dt) => G.mateCanvas.tick3d({ stage, ticks, dt });

  // A fresh drawing surface of w x h canvas pixels, filling the page.
  function setUp(w, h) {
    if (!root) {
      const style = document.createElement('style'); style.textContent = KEYFRAMES; document.head.appendChild(style);
      root = document.createElement('div'); root.id = 'mate-canvas';
      Object.assign(root.style, { position: 'absolute', inset: '0', overflow: 'hidden', touchAction: 'none' });
      document.body.appendChild(root);
      root.addEventListener('pointerdown', onDown);
      root.addEventListener('pointermove', onMove);
      root.addEventListener('pointerup', onUp);
      root.addEventListener('pointercancel', onCancel);
    }
    if (globalThis.MateStage3D) MateStage3D.reset();
    cardList = []; gesture = null; lastRects = '';
    root.textContent = '';
    nodes.clear();
    svg = el('svg', { viewBox: `0 0 ${w} ${h}` });
    Object.assign(svg.style, { position: 'absolute', inset: '0', width: '100%', height: '100%', overflow: 'visible' });
    defs = el('defs', {}, svg);
    layers = {};
    for (const id of LAYERS) layers[id] = el('g', { id }, svg);
    root.appendChild(svg);
    if (globalThis.MateStage3D) MateStage3D.attach(root, { tick3d: tickProvider, onBuild: buildAt });
  }

  // Every call into the canvas paints what it recorded, even when the call throws.
  function call(fn) { try { return fn(); } finally { paint(); } }

  // ---------------------------------------------------------------- the user's hands on the drawing
  // Cards can be dragged, closed with their red button and made full screen with their green one, and 3D figures
  // turned and clicked. The canvas says what the cards are and where (cards()); this page moves a card's elements while
  // the pointer drags, and tells the canvas where it was dropped (moveCard), closed (closeCard) or zoomed (zoomCard).
  let cardList = [], lastRects = '';
  // The canvas is the screenshot (its pixels are the model's coordinates); the page is the screen in points.
  let canvasW = 1, canvasH = 1;
  const unit = () => globalThis.__mateUnitPx || 1;
  const toPage = b => b.map(v => v * unit());
  const boxOf = card => (card.window ? card.window.box : card.box);
  const keyOf = card => (card.window ? 'w' + card.window.mark : card.marks.join(','));
  const within = (b, outer, slack = 4) => b[0] >= outer[0] - slack && b[1] >= outer[1] - slack &&
    b[0] + b[2] <= outer[0] + outer[2] + slack && b[1] + b[3] <= outer[1] + outer[3] + slack;
  // A 3D part starts growing: HeyMate's cursor flies to it and names it, so it looks like it builds the model.
  function buildAt(x, y, name) { post('pointAt', { x: x / unit(), y: y / unit(), label: name, role: 'build', w: canvasW, h: canvasH }); }
  function readCards() {
    try { cardList = JSON.parse((G.mateCanvas && G.mateCanvas.cards()) || '[]'); } catch (_) { cardList = []; }
    return cardList;
  }
  // Where HeyMate's window should take clicks (cards, 3D stages, buttons): the rest of the screen stays the user's.
  function refreshHits() {
    if (!G.mateCanvas) return;
    readCards();
    placeButtons();
    const rects = cardList.map(c => toPage(boxOf(c))).concat(globalThis.MateStage3D ? MateStage3D.rects : [])
      .concat([...buttons.values()].map(({ el }) => { const r = el.getBoundingClientRect(); return [r.left, r.top, r.width, r.height]; }));
    const key = JSON.stringify(rects.map(r => r.map(Math.round)));
    if (key !== lastRects) { lastRects = key; post('hitRects', rects); }
  }
  setInterval(refreshHits, 250);
  function cardAt(x, y) {
    for (let i = cardList.length - 1; i >= 0; i--) if (within([x, y, 0, 0], boxOf(cardList[i]), 0)) return cardList[i];
    return null;
  }
  // A window's red and green buttons, where paintWindow drew them. cards() gives the window's box and header as they
  // are now, zoomed or not; the buttons' offsets and size scale with it.
  function windowButtonAt(card, x, y) {
    const w = card.window;
    if (!w) return null;
    const s = w.scale || 1, cy = w.box[1] + (w.header || 28 * s) / 2;
    for (const [name, offset] of [['close', 16], ['zoom', 36]]) if (Math.hypot(x - (w.box[0] + offset * s), y - cy) <= 9 * s) return name;
    return null;
  }
  // Full screen, with a 60 point margin, and back.
  function zoom(card) {
    if (card.window.zoomed) return call(() => G.mateCanvas.zoomCard({ marks: card.marks, to: null }));
    const [x, y, w, h] = card.window.box, margin = 120 / unit();
    const k = Math.min((canvasW - margin) / w, (canvasH - margin) / h);
    return call(() => G.mateCanvas.zoomCard({ marks: card.marks, to: [k, (canvasW - k * w) / 2 - k * x, (canvasH - k * h) / 2 - k * y] }));
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

  // ---------------------------------------------------------------- buttons
  // button() leaves a spot with its box and {text, kind, value}; the canvas says when its beat is drawn and it can go
  // up. A button drawn on a window belongs to it: it is placed from where the window is now (dragged, dropped, moved by
  // an edit, zoomed), scaled with it, and closed with it. A window's box is fixed while it draws; other cards (a photo
  // and its label) grow as their marks arrive, so a button on one keeps its own box, moved when the card is dropped.
  const buttons = new Map();             // mark index -> {el, box (canvas units), payload, card: {key, home, scale} | null}
  function showButton(i, seconds, tries = 0) {
    const a = ((analysis && analysis.actions) || []).find(x => x.i === i && x.role === 'button');
    if (!a) { if (tries < 20) setTimeout(() => showButton(i, seconds, tries + 1), 100); return; }
    if (buttons.has(i)) return;
    let payload;
    try { payload = JSON.parse(a.text || '{}'); } catch (_) { return; }
    const box = a.box || [a.x, a.y, 120, 30];
    const el = document.createElement('button');
    el.dataset.mateButton = String(i);
    el.textContent = String(payload.text || '') + (payload.kind === 'open' ? '  ↗' : '');
    const ink = G.__mateInk || '#3380FF';
    Object.assign(el.style, { position: 'absolute', font: '600 13px -apple-system, system-ui, sans-serif', color: '#15171C', whiteSpace: 'nowrap',
      background: `linear-gradient(#FFFFFF, ${ink}33)`, border: `1px solid ${ink}66`, borderRadius: '999px', padding: '0 14px',
      boxShadow: '0 2px 8px rgba(0,0,0,.25)', cursor: 'pointer', opacity: '0', transform: 'scale(.85)', transition: 'opacity .25s, transform .25s' });
    el.addEventListener('click', ev => { ev.stopPropagation(); post('button', payload); el.style.transform = 'scale(.94)'; setTimeout(() => { el.style.transform = 'none'; }, 120); });
    root.appendChild(el);
    const card = readCards().slice().reverse().find(c => c.window && within(box, boxOf(c)));
    const b = { el, box: box.slice(), payload, card: card ? { key: keyOf(card), home: boxOf(card).slice(), scale: (card.window && card.window.scale) || 1 } : null };
    buttons.set(i, b);
    placeButton(b);
    setTimeout(() => { el.style.opacity = '1'; el.style.transform = 'none'; refreshHits(); }, Math.max(0, seconds) * 1000);
  }
  // A button where it is now: on a card, at the same place relative to the card's box and scaled with it.
  function placeButton(b, drag = [0, 0]) {
    let [x, y, w, h] = b.box, s = 1;
    const card = b.card && cardList.find(c => keyOf(c) === b.card.key);
    if (card) {
      const now = boxOf(card), from = b.card.home;
      s = ((card.window && card.window.scale) || 1) / b.card.scale;
      x = now[0] + (x - from[0]) * s; y = now[1] + (y - from[1]) * s;
    }
    const u = unit();
    Object.assign(b.el.style, { left: (x + drag[0]) * u + 'px', top: (y + drag[1]) * u + 'px', minWidth: w * u + 'px', height: h * u + 'px',
      scale: s === 1 ? '' : String(s), transformOrigin: s === 1 ? '' : '0 0' });
  }
  function placeButtons() { for (const b of buttons.values()) placeButton(b); }
  const buttonsOn = card => [...buttons.entries()].filter(([, b]) => (b.card ? b.card.key === keyOf(card) : within(b.box, boxOf(card))));
  function clearButtons() { for (const { el } of buttons.values()) el.remove(); buttons.clear(); }

  // ---------------------------------------------------------------- pointer gestures
  // Down on a card starts a drag (once the pointer has moved 3 points), on a 3D stage a turn; up without a drag is a
  // click: a window button, or a 3D part to ask about. A gesture the system cancels puts everything back.
  function onDown(ev) {
    if (ev.target && ev.target.closest && ev.target.closest('[data-mate-button]')) return;
    const x = ev.clientX, y = ev.clientY;
    refreshHits();
    post('touched', null);
    const stage = globalThis.MateStage3D && MateStage3D.stageAt(x, y);
    const card = stage ? null : cardAt(x / unit(), y / unit());
    if (!stage && !card) return;
    gesture = { x, y, stage, card, moved: false, lx: x, ly: y };
    try { root.setPointerCapture(ev.pointerId); } catch (_) {}
    ev.preventDefault();
  }
  const dragOf = (g, ev) => [(ev.clientX - g.x) / unit(), (ev.clientY - g.y) / unit()];
  function onMove(ev) {
    if (!gesture) return;
    if (Math.hypot(ev.clientX - gesture.x, ev.clientY - gesture.y) > 3) gesture.moved = true;
    if (gesture.stage) {
      MateStage3D.turn(gesture.stage, ev.clientX - gesture.lx, ev.clientY - gesture.ly);
      gesture.lx = ev.clientX; gesture.ly = ev.clientY;
    } else if (gesture.moved) dragCard(gesture.card, dragOf(gesture, ev));
  }
  // While a card is dragged its elements and buttons ride along on top of whatever transform they have.
  function dragCard(card, [dx, dy]) {
    for (const n of card.units) {
      const e = nodes.get(n);
      if (!e) continue;
      if (e.__dragBase === undefined) e.__dragBase = e.getAttribute('transform') || '';
      e.setAttribute('transform', `translate(${dx} ${dy}) ${e.__dragBase}`.trim());
    }
    for (const [, b] of buttonsOn(card)) placeButton(b, [dx, dy]);
  }
  function endDrag(card) {
    for (const n of card.units) {
      const e = nodes.get(n);
      if (!e || e.__dragBase === undefined) continue;
      if (e.__dragBase) e.setAttribute('transform', e.__dragBase); else e.removeAttribute('transform');
      delete e.__dragBase;
    }
  }
  function onUp(ev) {
    const g = gesture; gesture = null;
    if (!g) return;
    if (g.stage) {
      if (!g.moved) { const part = MateStage3D.pick(g.stage, ev.clientX, ev.clientY); if (part) post('askPart', part); }
      return;
    }
    endDrag(g.card);
    if (g.moved) { const [dx, dy] = dragOf(g, ev); dropCard(g.card, dx, dy); return; }
    const button = windowButtonAt(g.card, ev.clientX / unit(), ev.clientY / unit());
    if (button === 'close') closeCard(g.card);
    else if (button === 'zoom') { zoom(g.card); refreshHits(); setTimeout(refreshHits, 600); }
  }
  function onCancel() {
    const g = gesture; gesture = null;
    if (g && g.card) { endDrag(g.card); refreshHits(); }
  }
  function dropCard(card, dx, dy) {
    for (const [, b] of buttonsOn(card)) if (!b.card) { b.box[0] += dx; b.box[1] += dy; }
    call(() => G.mateCanvas.moveCard({ marks: card.marks, dx, dy }));
    refreshHits();
  }
  function closeCard(card) {
    for (const [i, b] of buttonsOn(card)) { b.el.remove(); buttons.delete(i); }
    let result = {};
    try { result = JSON.parse(call(() => G.mateCanvas.closeCard({ marks: card.marks })) || '{}') || {}; } catch (_) {}
    refreshHits();
    if (!result.left) setTimeout(() => post('empty', null), 600);
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
