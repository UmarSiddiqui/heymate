// ReferenceRenderer screen-drawing canvas, native (drawing-v2). Runs in JavaScriptCore
// inside the app, next to the unchanged drawing engine (mate-draw-engine.js,
// reference-renderer-v2 engine 1.6) and Mate's pieces (mate-draw-pieces.js).
//
// The engine paints SVG. There is no browser here, so this file gives it the
// small slice of the SVG DOM its painter uses (elements, attributes, CSS
// animations, getBBox and friends) and records what it paints. The app reads
// those records after every call (__drainRender) and draws them with Core
// Animation: the same geometry, timing curves and colours a browser would
// draw, without a web view. Measurements (text widths, path lengths) come
// from the app, which sets text with Core Text exactly as WebKit does.
//
// The canvas API (mateCanvas) is what the app's canvas window drives. The
// program is model-written code: this context has no network, no files and
// no native bridge beyond the __host functions.
(function (global) {
  'use strict';
  const HOST = global.__host;
  global.window = global;
  global.self = global;

  // ---------------------------------------------------------------- clock and timers (the app's CACurrentMediaTime)
  global.performance = { now: () => HOST.now() * 1000 };
  let nextTimerId = 1;
  const timerCallbacks = new Map();
  global.setTimeout = (fn, ms) => {
    const id = nextTimerId++;
    timerCallbacks.set(id, { fn, repeat: 0 });
    HOST.schedule(id, Math.max(0, +ms || 0) / 1000);
    return id;
  };
  global.setInterval = (fn, ms) => {
    const id = nextTimerId++, every = Math.max(0.004, (+ms || 0) / 1000);
    timerCallbacks.set(id, { fn, repeat: every });
    HOST.schedule(id, every);
    return id;
  };
  global.clearTimeout = global.clearInterval = id => { if (timerCallbacks.delete(id)) HOST.cancel(id); };
  global.__fireTimer = id => {
    const timer = timerCallbacks.get(id);
    if (!timer) return;
    if (timer.repeat) HOST.schedule(id, timer.repeat); else timerCallbacks.delete(id);
    try { typeof timer.fn === 'function' ? timer.fn() : null; } catch (e) { HOST.log('timer error: ' + (e && e.stack || e)); }
  };
  global.console = {
    log: (...a) => HOST.log(a.map(String).join(' ')),
    warn: (...a) => HOST.log('warn: ' + a.map(String).join(' ')),
    error: (...a) => HOST.log('error: ' + a.map(String).join(' ')),
  };

  // ---------------------------------------------------------------- CSS bits the painter sets
  const TIMING = {
    linear: [0, 0, 1, 1], ease: [0.25, 0.1, 0.25, 1], 'ease-in': [0.42, 0, 1, 1],
    'ease-out': [0, 0, 0.58, 1], 'ease-in-out': [0.42, 0, 0.58, 1],
  };
  // "pen 0.62s cubic-bezier(.35,.2,.55,.95) 0.02s both"
  function parseAnimation(text) {
    const s = String(text).trim();
    if (!s || s === 'none') return null;
    const bezier = /cubic-bezier\(([^)]*)\)/.exec(s);
    const rest = s.replace(/cubic-bezier\([^)]*\)/, ' ').split(/\s+/).filter(Boolean);
    const name = rest[0];
    const times = rest.filter(t => /^-?[\d.]+m?s$/.test(t)).map(t => t.endsWith('ms') ? parseFloat(t) / 1000 : parseFloat(t));
    let fn = TIMING.ease;
    if (bezier) fn = bezier[1].split(',').map(Number);
    else for (const word of rest) if (TIMING[word]) fn = TIMING[word];
    return { name, dur: times[0] || 0, delay: times[1] || 0, fn, at: HOST.now() };
  }
  const camel = k => k.trim().replace(/-([a-z])/g, (_, c) => c.toUpperCase());

  // ---------------------------------------------------------------- a small SVG DOM
  let nodeSequence = 0;
  const RENDER_GROUP_IDS = { under: 1, main: 1, hl: 1, words: 1 };
  let dirtyUnits = new Set();        // top-level painted elements changed since the last drain
  let removedUnits = [];             // painted elements taken off the card since the last drain
  // Edits change what the app already drew. Their changes go over as small ops on the existing layers, never as a
  // rebuild (a rebuild re-sets the words and re-renders a watercolour wash, and loses the entry animations):
  //   wrap    an element the app drew goes into a new <g> (moved or scaled by an edit)
  //   prop    a property of a drawn element: opacity, a <g>'s transform, a pen mask's dash offset
  //   stop    a drawn element's animations jump to their end (animation: none)
  //   motion  properties animated from → to over a time span (__mateMotion): the app runs it as a Core Animation
  let structural = [];               // wraps, in the order they happened
  let patches = [];                  // props, stops and motions, in order

  // The element directly under a render group (or under <defs>): the unit the app draws as one.
  function unitOf(node) {
    let n = node;
    while (n && n.parentNode) {
      const p = n.parentNode;
      if (p.tagName === 'defs' || (p.tagName === 'g' && RENDER_GROUP_IDS[p.attributes.id] && p.parentNode && p.parentNode.tagName === 'svg')) return n;
      n = p;
    }
    return null;
  }
  function touch(node) { const unit = unitOf(node); if (unit) dirtyUnits.add(unit); }

  // A mask's pen path is named by its <mask> id; any other drawn element by its number.
  function patchTarget(node) {
    const p = node.parentNode;
    return p && p.tagName === 'mask' && p.attributes.id ? { mask: p.attributes.id } : { n: node.__n };
  }
  function makeStyle(node) {
    const props = {};
    return new Proxy(props, {
      get(target, key) {
        if (key === '__props') return props;
        if (typeof key !== 'string') return undefined;
        return key in props ? props[key] : '';
      },
      set(target, key, value) {
        props[key] = String(value);
        if (key === 'animation') node.__anim = parseAnimation(value);
        if (node.__sent) {             // already drawn by the app: change that drawing, do not rebuild it
          if (key === 'animation' && !node.__anim) { patches.push(Object.assign({ op: 'stop' }, patchTarget(node))); return true; }
          if (key === 'opacity') { patches.push(Object.assign({ op: 'prop', key: 'opacity', value: +value }, patchTarget(node))); return true; }
          if (key === 'strokeDashoffset' && node.parentNode && node.parentNode.tagName === 'mask') { patches.push(Object.assign({ op: 'prop', key: 'dash', value: +value }, patchTarget(node))); return true; }
        }
        touch(node);
        return true;
      },
    });
  }

  class Element {
    constructor(tag) {
      this.tagName = tag;
      this.nodeName = tag;
      this.nodeType = 1;
      this.__n = ++nodeSequence;
      this.attributes = Object.create(null);
      this.childNodes = [];
      this.parentNode = null;
      this.__text = null;
      this.__anim = null;
      this.style = makeStyle(this);
      this.dataset = {};
    }
    get children() { return this.childNodes; }
    get firstChild() { return this.childNodes[0] || null; }
    get lastChild() { return this.childNodes[this.childNodes.length - 1] || null; }
    get id() { return this.attributes.id || ''; }
    setAttribute(key, value) {
      const v = String(value);
      this.attributes[key] = v;
      if (key === 'style') for (const part of v.split(';')) { const i = part.indexOf(':'); if (i > 0) this.style.__props[camel(part.slice(0, i))] = part.slice(i + 1).trim(); }
      if (this.__sent && this.tagName === 'g' && key === 'transform') { patches.push({ op: 'prop', key: 'transform', n: this.__n, value: v }); return; }
      touch(this);
    }
    getAttribute(key) { return key in this.attributes ? this.attributes[key] : null; }
    hasAttribute(key) { return key in this.attributes; }
    removeAttribute(key) { delete this.attributes[key]; touch(this); }
    appendChild(child) {
      // An edit moves a drawn element into a new <g> of its own (the engine's wrap()): the app wraps the layer it drew.
      if (child.__sent && this.tagName === 'g' && !this.__sent && !this.childNodes.length && unitOf(child) === child && unitOf(this) === this && this.parentNode === child.parentNode) {
        const siblings = child.parentNode.childNodes;
        siblings.splice(siblings.indexOf(child), 1);
        child.parentNode = this;
        this.childNodes.push(child);
        dirtyUnits.delete(this); dirtyUnits.delete(child);
        this.__sent = true;
        structural.push({ op: 'wrap', g: this.__n, child: child.__n });
        return child;
      }
      if (child.parentNode) child.parentNode.removeChild(child);
      child.parentNode = this;
      this.childNodes.push(child);
      touch(child);
      return child;
    }
    insertBefore(child, reference) {
      if (!reference) return this.appendChild(child);
      if (child.parentNode) child.parentNode.removeChild(child);
      const i = this.childNodes.indexOf(reference);
      child.parentNode = this;
      this.childNodes.splice(i < 0 ? this.childNodes.length : i, 0, child);
      touch(child);
      return child;
    }
    removeChild(child) {
      const i = this.childNodes.indexOf(child);
      if (i < 0) return child;
      const unit = unitOf(child);
      if (unit === child) { removedUnits.push(child.__n); dirtyUnits.delete(child); }
      else if (unit) dirtyUnits.add(unit);
      this.childNodes.splice(i, 1);
      child.parentNode = null;
      return child;
    }
    remove() { if (this.parentNode) this.parentNode.removeChild(this); }
    get textContent() { return this.__text != null ? this.__text : this.childNodes.map(c => c.textContent).join(''); }
    set textContent(value) {
      for (const c of this.childNodes) c.parentNode = null;
      this.childNodes = [];
      this.__text = String(value);
      touch(this);
    }
    get ownerSVGElement() { let p = this.parentNode; while (p) { if (p.tagName === 'svg') return p; p = p.parentNode; } return null; }
    querySelector(selector) { return this.querySelectorAll(selector)[0] || null; }
    querySelectorAll(selector) {
      const tests = String(selector).split(',').map(s => s.trim()).filter(Boolean).map(s => s[0] === '#' ? (n => n.attributes.id === s.slice(1)) : (n => n.tagName === s));
      const out = [];
      const walk = n => { for (const c of n.childNodes) { if (tests.some(t => t(c))) out.push(c); walk(c); } };
      walk(this);
      return out;
    }
    set innerHTML(html) {
      for (const c of this.childNodes.slice()) this.removeChild(c);
      for (const c of parseMarkup(String(html))) this.appendChild(c);
    }
    get innerHTML() { return ''; }
    get classList() {
      const node = this, list = () => (node.attributes.class || '').split(/\s+/).filter(Boolean);
      return {
        add: c => { const l = list(); if (!l.includes(c)) node.setAttribute('class', l.concat(c).join(' ')); },
        remove: c => node.setAttribute('class', list().filter(x => x !== c).join(' ')),
        contains: c => list().includes(c),
      };
    }
    // ---- geometry, answered by the app (Core Text / its path code)
    getBBox() {
      if (this.tagName === 'text') { const b = HOST.textBox(JSON.stringify(textDescription(this))); return { x: b[0], y: b[1], width: b[2], height: b[3] }; }
      if (this.tagName === 'path') { const b = HOST.pathBox(this.attributes.d || ''); return { x: b[0], y: b[1], width: b[2], height: b[3] }; }
      if (this.tagName === 'circle') { const cx = +this.attributes.cx || 0, cy = +this.attributes.cy || 0, r = +this.attributes.r || 0; return { x: cx - r, y: cy - r, width: 2 * r, height: 2 * r }; }
      // groups and nested svgs: the union of their children
      let box = null;
      for (const c of this.childNodes) {
        let b; try { b = c.getBBox(); } catch (_) { continue; }
        if (!b || !(b.width || b.height)) continue;
        if (!box) box = { x: b.x, y: b.y, r: b.x + b.width, b: b.y + b.height };
        else { box.x = Math.min(box.x, b.x); box.y = Math.min(box.y, b.y); box.r = Math.max(box.r, b.x + b.width); box.b = Math.max(box.b, b.y + b.height); }
      }
      return box ? { x: box.x, y: box.y, width: box.r - box.x, height: box.b - box.y } : { x: 0, y: 0, width: 0, height: 0 };
    }
    getComputedTextLength() {
      const d = textDescription(this);
      return HOST.textWidth(d.family, d.size, d.weight, this.textContent);
    }
    getTotalLength() { return HOST.pathLength(this.attributes.d || ''); }
    getPointAtLength(length) { const p = HOST.pathPoint(this.attributes.d || '', +length || 0); return { x: p[0], y: p[1] }; }
  }

  // The template surfaceFor() writes into each new card: well-formed tags only.
  function parseMarkup(html) {
    const roots = [], stack = [];
    const re = /<\s*(\/?)\s*([A-Za-z][\w:-]*)((?:\s+[\w:-]+\s*=\s*"[^"]*")*)\s*(\/?)\s*>/g;
    let m;
    while ((m = re.exec(html))) {
      const [, closing, tag, attrs, selfClosing] = m;
      if (closing) { stack.pop(); continue; }
      const e = new Element(tag);
      const attrRe = /([\w:-]+)\s*=\s*"([^"]*)"/g; let a;
      while ((a = attrRe.exec(attrs))) e.setAttribute(a[1], a[2]);
      if (stack.length) stack[stack.length - 1].appendChild(e); else roots.push(e);
      if (!selfClosing) stack.push(e);
    }
    return roots;
  }

  // What the app needs to set a <text>: font, anchor, baseline and its lines.
  function inherited(node, key) { let n = node; while (n) { if (n.attributes && key in n.attributes) return n.attributes[key]; n = n.parentNode; } return null; }
  function textDescription(t) {
    const size = parseFloat(inherited(t, 'font-size')) || 16;
    const weightText = inherited(t, 'font-weight');
    const weight = weightText === 'bold' ? 700 : weightText === 'normal' || weightText == null ? 400 : (parseInt(weightText, 10) || 400);
    const family = inherited(t, 'font-family') || 'sans-serif';
    const x = parseFloat(t.attributes.x) || 0, y = parseFloat(t.attributes.y) || 0;
    const lines = [];
    if (t.__text != null || !t.childNodes.length) lines.push({ x, dy: 0, text: t.textContent });
    else for (const s of t.childNodes) if (s.tagName === 'tspan') lines.push({ x: s.attributes.x != null ? parseFloat(s.attributes.x) : null, dy: parseFloat(s.attributes.dy) || 0, text: s.textContent });
    return { family, size, weight, anchor: inherited(t, 'text-anchor') || 'start', baseline: t.attributes['dominant-baseline'] || 'auto', x, y, lines };
  }

  const documentRoot = new Element('body');
  global.document = {
    body: documentRoot,
    documentElement: documentRoot,
    fonts: { ready: Promise.resolve() },
    createElementNS: (ns, tag) => new Element(tag),
    createElement: tag => new Element(tag),
    getElementById: id => {
      let found = null;
      const walk = n => { for (const c of n.childNodes) { if (found) return; if (c.attributes.id === id) { found = c; return; } walk(c); } };
      walk(documentRoot);
      return found;
    },
  };

  // ---------------------------------------------------------------- what the app draws
  function serialize(node) {
    node.__sent = true;
    const out = { n: node.__n, tag: node.tagName, a: node.attributes };
    if (node.__k != null) out.k = node.__k;            // the mark that painted it (the engine's capture index)
    if (node.__anim) out.anim = node.__anim;
    const st = node.style.__props;
    for (const k in st) { out.st = st; break; }
    if (node.tagName === 'text') out.text = textDescription(node);
    else if (node.childNodes.length) out.ch = node.childNodes.map(serialize);
    return out;
  }
  // Everything painted or taken away since the last call, in paint order: removals, wraps, new or rebuilt elements, then
  // the changes to drawn ones (so a motion always finds its element built).
  global.__drainRender = () => {
    if (!dirtyUnits.size && !removedUnits.length && !structural.length && !patches.length) return '';
    const ops = [];
    for (const n of removedUnits) ops.push({ op: 'remove', n });
    removedUnits = [];
    for (const o of structural) ops.push(o);
    structural = [];
    const units = [...dirtyUnits].filter(u => unitOf(u) === u);
    dirtyUnits = new Set();
    // Each group's new elements in document order (masks first: paths point at them), each placed before the first
    // element after it that the app already has, so several new neighbours (a whole drawing's moved marks) keep their order.
    const batch = new Set(units), parents = [];
    for (const u of units) if (!parents.includes(u.parentNode)) parents.push(u.parentNode);
    parents.sort((a, b) => (b.tagName === 'defs') - (a.tagName === 'defs'));
    for (const parent of parents) {
      const siblings = parent.childNodes, order = new Map(siblings.map((c, i) => [c, i]));
      const mine = units.filter(u => u.parentNode === parent).sort((a, b) => order.get(a) - order.get(b));
      for (const u of mine) {
        let k = order.get(u) + 1; while (k < siblings.length && batch.has(siblings[k])) k++;
        const next = siblings[k];
        ops.push({ op: 'set', group: parent.tagName === 'defs' ? 'defs' : parent.attributes.id, before: next ? next.__n : null, node: serialize(u) });
      }
    }
    for (const o of patches) ops.push(o);
    patches = [];
    return JSON.stringify(ops);
  };
  // The engine's edits, declared once: each item animates one property of a drawn element from → to, starting `at`
  // seconds from now for `dur` seconds on the CSS timing curve `ease`. The app runs it (Core Animation); the engine takes
  // the element off itself when an erase ends.
  global.__mateMotion = (items, at, dur, ease) => {
    const bezier = /cubic-bezier\(([^)]*)\)/.exec(String(ease || ''));
    const fn = bezier ? bezier[1].split(',').map(Number) : TIMING.ease;
    patches.push({
      op: 'motion', begin: HOST.now() + Math.max(0, +at || 0), dur: Math.max(0.001, +dur || 0), fn,
      items: items.map(x => Object.assign({ key: x.prop === 'xf' ? 'transform' : x.prop, from: x.from, to: x.to }, patchTarget(x.node))),
    });
  };

  // ================================================================ the canvas
  let pieces = null;            // mate-draw-pieces.js source, handed in by the app once
  let session = null;           // the engine's live() handle for the drawing on screen
  let stage = null;
  let lastLine = -1, lineStarts = {}, lineLengths = {};
  let linesStartedInEngine = {};
  const PEN_EASE = [0.35, 0.2, 0.55, 0.95];
  const SCREEN_PEN_BASE_HALO = {
    '#FFFFFF': [['#080E1E', 0.16, 7], ['#080E1E', 0.45, 3]],
    '#15171C': [['#FFFFFF', 0.35, 7], ['#FFFFFF', 0.85, 3]],
  };
  const SCREEN_PEN = {
    per: 1400, base: 0.25, min: 0.3, max: 1.4,
    ease: `cubic-bezier(${PEN_EASE.join(',')})`,
    halo: null,
    wash: true,              // watercolour fills with a soft uneven edge (back 2026-10-09 with the hand-drawn look; paper,
                             // pills, badges and windows pass wash: false and stay crisp)
    washMaxArea: 60000,
  };
  const SCREEN_PACING = { minPace: 0.8, maxSlow: 1.4, sequential: true, maxSpread: 1.25, rushPace: 0.1 };
  let drawn = {};
  let programSoFar = '', lastSays = [];
  let statementCache = { length: -1, statements: [] };
  let showSubtitles = false, subtitleLine = -1, subtitleTimer = null;
  let streamW = 0, streamH = 0;
  let lastAnalysed = { program: null, json: null };
  let scanStreamStatements = null;
  // A drawing continued over several turns: the earlier turns' code (without the pieces) that stays on the card, ending in
  // the canvas's own `__turn(n, keep);` line; the new turn's first say() line and first mark.
  let earlierCode = '', turnFirstLine = 0, turnFirstMark = 0;
  // renderWhole's card (lab): what state() describes when no stream is open
  let wholeCard = null;
  // three-metal: figure() tick functions that ran over 8 ms, how many times (five strikes stop them)
  let slowTicks = {};

  // Mate's ink: the user's cursor colour, handed in by the app with each drawing (the same colour as the cursor,
  // the old walkthrough marks and the click target). It glows softly in its own colour, like the cursor does.
  const DEFAULT_MATE_INK = '#3380FF';
  global.__mateInk = DEFAULT_MATE_INK;
  function useMateInk(hex) {
    const ink = /^#[0-9a-fA-F]{6}$/.test(String(hex || '')) ? String(hex).toUpperCase() : DEFAULT_MATE_INK;
    global.__mateInk = ink;
    // No pen-wide halo for Mate's ink: the marks that point at the screen carry their own glow (the pieces' screen
    // pen, like the old walkthrough's soft shadow), and paper strokes in that colour stay crisp.
    SCREEN_PEN.halo = Object.assign({}, SCREEN_PEN_BASE_HALO);
  }
  // How many screen points one canvas unit is (the canvas is the screenshot, about 1280 wide), so pieces can size
  // pills, badges and strokes in points like the rest of ReferenceRenderer's UI.
  function useCanvasScale(w, width) {
    global.__canvasUnitPoints = w > 0 && width > 0 ? width / w : 1;
  }
  global.__inkFor = (x, y, w, h) => HOST.inkFor(x, y, w, h);
  global.__busyFor = (x, y, w, h) => (HOST.busyFor ? HOST.busyFor(x, y, w, h) : 0);
  global.__lumFor = (x, y, w, h) => (HOST.lumFor ? HOST.lumFor(x, y, w, h) : -1);
  // Stream mode: every 3D figure floats on a clear background (the engine's standStage reads it).
  global.__figuresFloat = () => (HOST.figuresFloat ? HOST.figuresFloat() === true : false);
  // three-metal: a figure() part's shape starts building in the app's 3D kernel the moment its statement runs
  global.__shape3d = (kind, recipe) => { if (HOST.shape3d) HOST.shape3d(kind, recipe); };
  global.__hostDrawsPointers = true;
  // button(): the app draws the real, pressable button (ScreenDrawingActionButtons).
  global.__hostDrawsButtons = true;
  // paper(), receipt(), clipping(): the app paints the little window (ScreenDrawingNativePainter) and its buttons work
  // (ScreenDrawingCardDragHandles).
  global.__hostDrawsWindows = true;
  // frame(): the app drags it open from its corner like a selection (ScreenDrawingNativePainter's marquee).
  global.__hostDrawsMarquee = true;

  function clearNow() {
    if (session) { try { session.stop(); } catch (_) {} session = null; }
    if (stage) { stage.remove(); stage = null; }
    lastLine = -1; lineStarts = {}; lineLengths = {}; linesStartedInEngine = {};
    drawn = {}; programSoFar = ''; lastSays = []; statementCache = { length: -1, statements: [] }; lastAnalysed = { program: null, json: null };
    scanStreamStatements = null;
    earlierCode = ''; turnFirstLine = 0; turnFirstMark = 0; wholeCard = null; slowTicks = {};
    resetSounds();
    resetButtons();
    subtitleLine = -1;
    if (subtitleTimer) { clearInterval(subtitleTimer); subtitleTimer = null; }
    HOST.caption('');
  }

  function noteDrawn(ms, d) {
    if (d.i == null || !ms[0] || !session) return;
    const pen = MateDraw.natural(ms[0]).dur * Math.max(d.pace || 1, 0.35);
    drawn[d.i] = { t: session.now(), pen };
    playSoundsFor(ms[0], d.i);
    noteDrawnForButtons(ms[0], d.i);
  }

  // ---------------------------------------------------------------- buttons wait for their beat's drawing
  // A button() goes up once everything its beat draws is on screen (the card, the photo and their words), not as its
  // line starts: it is the next step, so it comes last (Nilesh 2026-10-06: it showed before the card). The app shows
  // it when told (__host.buttonReady(mark index, seconds from now)); a beat cut short (its next line starts, the
  // drawing ends) lets its buttons go then.
  let pendingButtons = [], beatDrawnUntil = {}, programMarkCount = null;
  function resetButtons() { pendingButtons = []; beatDrawnUntil = {}; programMarkCount = null; }
  const beatOfMark = i => Math.max(0, lastSays.filter(s => s.at <= i).length - 1);
  function beatMarkRange(k) {
    const start = k === 0 ? 0 : lastSays[k].at;
    const end = lastSays[k + 1] ? lastSays[k + 1].at : programMarkCount;
    return [start, end];
  }
  function noteDrawnForButtons(m, i) {
    if (!session) return;
    const beat = beatOfMark(i), when = session.startsIn ? session.startsIn(i) : null;
    const end = HOST.now() + (when ? Math.max(0, when[0]) + Math.max(0, when[1]) : 0);
    beatDrawnUntil[beat] = Math.max(beatDrawnUntil[beat] || 0, end);
    if (m.role === 'button' || (m.do === 'text' && m.link)) pendingButtons.push({ i, beat });
    releaseButtons(-1);
  }
  // Buttons whose beat is fully drawn (or whose beat is before `throughBeat`, or every one when throughBeat is Infinity).
  function releaseButtons(throughBeat) {
    if (!pendingButtons.length || typeof HOST.buttonReady !== 'function') return;
    const now = HOST.now(), waiting = [];
    for (const b of pendingButtons) {
      const [start, end] = beatMarkRange(b.beat);
      let done = b.beat < throughBeat;
      if (!done && end != null) { done = true; for (let j = start; j < end; j++) if (!drawn[j]) { done = false; break; } }
      if (!done) { waiting.push(b); continue; }
      HOST.buttonReady(b.i, Math.max(0, (beatDrawnUntil[b.beat] || now) - now) + 0.15);
    }
    pendingButtons = waiting;
  }

  // ---------------------------------------------------------------- the drawing's sounds
  // The app makes the drawing's sound from what it paints (ScreenDrawingSoundPlayer): every pen stroke and every word
  // written gets a texture (a felt tip on the screen, pencil on a card, handwriting) whose loudness and pitch follow the
  // pen's real speed through the stroke, so the sound starts, swells and stops with the ink. On top of that, a few
  // moments get a sound of their own: a card or photo landing, a pill or badge popping in, a button, a click target,
  // typing, a 3D part, the model's sfx() accents. This only says WHAT each mark sounds like; the app times it to the
  // layers it paints for the mark. The names are the files in drawing sound resources.
  const SOUND_ACCENTS = { tada: 1, ding: 1, nope: 1, stamp: 1, sparkle: 1, whoosh: 1, boing: 1, 'page-turn': 1 };
  const PILL_ROLES = { label: 1, num: 1, cheer: 1, button: 1 };
  const STROKE_KINDS = { line: 1, circle: 1, ellipse: 1, rect: 1, poly: 1, path: 1, arrow: 1, molecule: 1 };
  // the boxes of the cards drawn so far: a stroke inside one is pencil on paper
  let drawnCardBoxes = [];
  function resetSounds() { drawnCardBoxes = []; }

  // {texture: 'felt' | 'pencil' | 'writing' | 'eraser' | null, events: [{id, at (seconds after the mark starts; from its
  // end when end is true)}]}
  function soundOf(m) {
    const events = [];
    if (m.role === 'sfx') return { texture: null, events: SOUND_ACCENTS[m.payload] ? [{ id: m.payload }] : [] };
    if (typeof m.snd === 'string') events.push({ id: m.snd, at: m.snd === 'tape' ? 0.12 : 0 });
    if (m.do === 'edit') {
      const op = m.op && m.op.op;
      if (op === 'erase') return { texture: 'eraser', events };
      if (op === 'move' || op === 'moveTo' || op === 'scale') events.push({ id: 'slide' });
      else if (op === 'startOver') { drawnCardBoxes = []; events.push({ id: 'page-clear' }); }
      else if (op === 'highlight') events.push({ id: 'highlighter' });
      return { texture: null, events };
    }
    if (m.role === 'type') events.push({ id: 'type-keys' });
    else if (m.role === 'copy') events.push({ id: 'copy-tick' });
    // a button: none here; the app plays its sound when the real button goes up, after its whole beat is drawn
    else if (m.role === 'target' || m.role === 'hover') events.push({ id: 'target-ping' });
    if (m.do === 'part3d') events.push({ id: 'build-3d' });
    if (m.do === 'highlight') events.push({ id: 'highlighter' });
    if (m.do === 'text') return { texture: PILL_ROLES[m.role] || !String(m.text || '').trim() ? null : 'writing', events };
    if (!STROKE_KINDS[m.do] || m.outline === false) return { texture: null, events };
    const box = MateDraw.markBox(m), onACard = drawnCardBoxes.length && box ? MateDraw.onCardTest(drawnCardBoxes) : null;
    if (m.do === 'arrow' || m.head) events.push({ id: 'pen-flick', at: -0.04, end: true });
    return { texture: onACard && onACard(box) ? 'pencil' : 'felt', events };
  }

  function playSoundsFor(m, i) {
    if (MateDraw.isCardMark(m)) { const b = MateDraw.markBox(m); if (b) drawnCardBoxes.push(b); }
    if (typeof HOST.markSound !== 'function' || !session || !session.startsIn) return;
    let sound;
    try { sound = soundOf(m); } catch (_) { return; }
    if (!sound.texture && !sound.events.length) return;
    // when the engine expects the mark to start and how long it takes: the app's fallback for marks it paints nothing
    // for (an edit, an app action)
    const when = session.startsIn(i) || [0.02, 0.4];
    HOST.markSound(i, JSON.stringify({ texture: sound.texture, events: sound.events, delay: Math.max(0, when[0]), dur: Math.max(0, when[1]) }));
  }

  function shortStatement(text) {
    if (/^\s*for\b/.test(text)) return 'for loop';
    const call = (text.match(/^\s*(?:const\s+\w+\s*=\s*)?([A-Za-z_$][\w$]*)\s*\(/) || [])[1];
    const quoted = text.match(/"([^"]+)"|'([^']+)'/);
    const whole = quoted ? (quoted[1] || quoted[2]) : null;
    const words = whole && whole.length > 34 ? whole.slice(0, 33) + '…' : whole;
    if (call) return words ? `${call} "${words}"` : call;
    return text.trim().slice(0, 24);
  }

  function statements() {
    if (statementCache.length === programSoFar.length) return statementCache.statements;
    const skip = (pieces || '').length;
    const lineOf = i => Math.max(0, lastSays.filter(s => s.at <= i).length - 1);
    const list = [];
    try {
      for (const st of MateDraw.attribute(programSoFar, streamW, streamH)) {
        if (st.e <= skip || st.n1 <= st.n0) continue;
        const text = programSoFar.slice(st.s, st.e).replace(/^[\s;]+/, '');
        if (/^__turn\(/.test(text)) continue;          // the canvas's own turn line
        list.push({ label: shortStatement(text), n0: st.n0, n1: st.n1, line: lineOf(st.n0) });
      }
    } catch (_) {}
    statementCache = { length: programSoFar.length, statements: list };
    return list;
  }

  function statementProgress(st, now) {
    let started = 0, finished = 0, first = null, end = null;
    for (let i = st.n0; i < st.n1; i++) {
      const d = drawn[i]; if (!d) continue;
      started++; if (now >= d.t + d.pen) finished++;
      if (first == null || d.t < first) first = d.t;
      if (end == null || d.t + d.pen > end) end = d.t + d.pen;
    }
    const marks = st.n1 - st.n0;
    return { state: finished === marks ? 'done' : started ? 'drawing' : 'waiting', first, end, drawnMarks: started, marks };
  }

  // Debug subtitles: the beat being spoken and each call of it as the pen reaches it (drawn by the app).
  function renderSubtitle() {
    if (!showSubtitles || !session || subtitleLine < 0) { HOST.caption(''); return; }
    const k = subtitleLine, now = session.now(), all = statements();
    const shown = all.filter(st => st.line === k || (st.line < k && statementProgress(st, now).state !== 'done'));
    const heard = k in lineStarts ? now - lineStarts[k] : 0;
    HOST.caption(JSON.stringify({
      header: `beat ${k + 1} of ${lastSays.length} · ${heard.toFixed(1)}s` + (k in lineLengths ? ` / ${lineLengths[k].toFixed(1)}s` : ''),
      text: (lastSays[k] || {}).text || '',
      chips: shown.map(st => ({ label: st.label, state: statementProgress(st, now).state, late: st.line < k })),
    }));
  }

  // feed() comes with every streamed chunk; the complete statements only change now and then.
  function analyse(program, w, h, knownEnds) {
    if (lastAnalysed.program === program) return lastAnalysed.json;
    const json = analyseNow(program, w, h, knownEnds);
    lastAnalysed = { program, json };
    return json;
  }
  // Mate's marks that are neither pointing nor a picture of their own.
  const NOT_A_PICTURE_ROLES = new Set(['cheer', 'source', 'key', 'tie', 'sfx', 'button', 'type', 'copy', 'open', 'handoff']);
  function analyseNow(program, w, h, knownEnds) {
    const marks = MateDraw.runCode(program, w, h, { knownEnds });
    const says = marks.says || [];
    programSoFar = program; lastSays = says;
    const lines = says.map(s => String(s.text || ''));
    const actions = [];
    marks.forEach((m, i) => {
      if (i < turnFirstMark) return;                  // a continued drawing: only this turn's pointers
      const line = Math.max(0, says.filter(s => s.at <= i).length - 1);
      // a photo: the app starts finding it as soon as it is written, so it is ready when its line is heard
      if (m.do === 'image' && m.query) { actions.push({ role: 'photo', x: m.at[0], y: m.at[1], r: 0, box: [m.at[0], m.at[1], m.w, m.h], label: null, text: String(m.query), line, i }); return; }
      // words with a web link in them (text() keeps a citation's or long URL's address): the app makes them clickable
      if (m.do === 'text' && m.link) { actions.push({ role: 'link', x: m.at[0], y: m.at[1], r: 0, box: null, label: null, text: String(m.link), line, i }); return; }
      if (m.role !== 'point' && m.role !== 'target' && m.role !== 'hover' && m.role !== 'type' && m.role !== 'copy' && m.role !== 'open' && m.role !== 'handoff' && m.role !== 'button' && m.role !== 'tourjob' && m.role !== 'tourtuck' && m.role !== 'tourasks' && m.role !== 'tournotch' && m.role !== 'tourfade') return;
      actions.push({ role: m.role, x: m.at[0], y: m.at[1], r: m.ring || 0, box: m.box || null, label: m.label || null, text: m.payload != null ? String(m.payload) : null, line, i });
    });
    // Which of this turn's lines point at the screen and which draw on a card: if the screen changes while the answer
    // is told, the app goes on only with the lines that still make sense on any screen.
    const cardBoxes = [];
    marks.forEach(m => { if (MateDraw.isCardMark(m)) { const b = MateDraw.markBox(m); if (b) cardBoxes.push(b); } });
    const onACard = MateDraw.onCardTest(cardBoxes) || (() => false);
    const pointing = {}, cards = {};
    marks.forEach((m, i) => {
      if (i < turnFirstMark || !m) return;
      const line = Math.max(0, says.filter(s => s.at <= i).length - 1);
      if (MateDraw.isCardMark(m)) { cards[line] = true; return; }
      if (!MateDraw.pointsAtScreen(m)) return;
      const b = MateDraw.markBox(m);
      if (b && onACard(b)) cards[line] = true; else pointing[line] = true;
    });
    // Marks that show ink: Mate's pieces leave invisible dots where the app acts (typeText, copyText, openPage, a
    // button's spot, handOff, sfx), so an answer that only typed or copied something drew nothing.
    const isHostSpot = m => m.do === 'dot' && m.fillAlpha === 0 && m.outline === false;
    const inked = marks.filter(m => m && !isHostSpot(m)).length;
    // A real picture (kept in the chat, and through a scroll): a card (paper, a photo, a 3D figure) or a free sketch of a
    // few strokes. Rings, pills, badges, highlights, underlines, arrows and a loose line or two only point at the screen
    // (Nilesh 2026-10-14: a circle around something was saved in the chat as a drawing).
    const sketchStrokes = marks.filter(m => m && !isHostSpot(m) && !MateDraw.pointsAtScreen(m) && !NOT_A_PICTURE_ROLES.has(m.role)
      && m.do !== 'text' && m.do !== 'highlight').length;
    // The plate a lone sources() line sits on is not a picture: an answer that only credited its sites draws nothing.
    const picture = marks.some(m => MateDraw.isCardMark(m) && !m.sourcePlate) || sketchStrokes >= 3;
    return JSON.stringify({ lines, actions, marks: marks.length, inked, picture, firstLine: turnFirstLine, error: marks.error || null, warnings: (marks.warnings || []).slice(0, 5),
      pointingLines: Object.keys(pointing).map(Number), cardLines: Object.keys(cards).map(Number) });
  }
  const programFor = code => (pieces || '') + '\n' + (earlierCode ? earlierCode + '\n' : '') + code;

  function startHeardLinesInEngine() {
    if (!session) return;
    const known = (session.timeline.lines || []).length;
    for (const key of Object.keys(lineStarts)) {
      const k = +key;
      if (k >= known || linesStartedInEngine[k]) continue;
      session.lineStart(k, lineStarts[k]);
      if (k in lineLengths) session.lineEnd(k, lineStarts[k] + lineLengths[k]);
      linesStartedInEngine[k] = true;
    }
  }

  global.mateCanvas = {
    setPieces(source) { pieces = source; return true; },

    beginStream({ w, h, width, subtitles, ink }) {
      clearNow();
      useMateInk(ink);
      useCanvasScale(w, width);
      stage = new Element('div');
      documentRoot.appendChild(stage);
      streamW = w; streamH = h;
      scanStreamStatements = MateDraw.statementScanner();
      showSubtitles = !!subtitles;
      MateDraw.setPen(SCREEN_PEN);
      session = MateDraw.live({ w, h, surface: 'none' }, stage,
        Object.assign({ width, pace: 'speech', speech: 'external', onDraw: noteDrawn, codeStart: (pieces || '').length + 1 }, SCREEN_PACING));
      return true;
    },

    // Keeps the drawing on the card and starts a new turn on it. Marks of the old program still waiting for their line
    // (the user interrupted) are dropped for good, and an unfinished statement at its end is cut off. After this, feed()
    // takes only the new turn's code; its lines keep counting from firstLine. Returns JSON {firstLine, marks (drawn on the
    // card now), code}: code is the program that stays on the card (without Mate's pieces), ending in a __turn(n, keep)
    // line; code + "\n" + the new turn's code replays (renderWhole, or a stream) to the same drawing.
    continueStream({ subtitles } = {}) {
      if (!session) return null;
      if (subtitles != null) showSubtitles = !!subtitles;
      const next = session.continueTurn();
      const prefix = (pieces || '') + '\n';
      // (the engine's session goes on from exactly the program it ran, so nothing of it is trimmed or reformatted)
      const kept = next.kept.startsWith(prefix) ? next.kept.slice(prefix.length) : '';
      earlierCode = kept + (kept && !kept.endsWith('\n') ? '\n' : '') + `__turn(${next.turn}, ${next.keep});`;
      turnFirstLine = next.firstLine; turnFirstMark = next.start;
      lastAnalysed = { program: null, json: null }; statementCache = { length: -1, statements: [] };
      return JSON.stringify({ firstLine: next.firstLine, marks: next.visible, code: earlierCode });
    },

    // What is on the card now, as short lines for the model (its parts with ids like p3, their boxes in canvas pixels and
    // what was said), or null when nothing is drawn. Synchronous.
    state() {
      const card = session || wholeCard;
      if (!card || !card.visibleCount()) return null;
      // Room for a 3D figure's parts one by one, and a continued drawing reads as finished (the app asks right after
      // continueStream(), when the new turn has drawn nothing yet).
      return card.stateNow({ drawnOnly: true, maxChars: 12000, status: earlierCode ? 'The drawing is finished: all of it is on screen.' : undefined });
    },

    feed({ code, done }) {
      if (!session) return null;
      const program = programFor(code);
      session.update(program, !!done);
      startHeardLinesInEngine();
      const ends = scanStreamStatements(program);
      const complete = done ? program : program.slice(0, ends.length ? ends[ends.length - 1] : 0);
      const analysis = analyse(complete, streamW, streamH, ends);
      if (done && analysis) { try { programMarkCount = JSON.parse(analysis).marks; } catch (_) {} releaseButtons(-1); }
      return analysis;
    },

    line(k) {
      if (!session) return false;
      if (lastLine >= 0 && lastLine < k && !(lastLine in lineLengths)) session.lineEnd(lastLine);
      const t = session.now();
      lineStarts[k] = t;
      lastLine = k;
      releaseButtons(k);
      startHeardLinesInEngine();
      if (showSubtitles) {
        subtitleLine = k;
        renderSubtitle();
        if (!subtitleTimer) subtitleTimer = setInterval(renderSubtitle, 120);
      }
      return true;
    },

    lineLength(k, seconds) {
      if (!session || !(seconds > 0)) return false;
      lineLengths[k] = seconds;
      if (linesStartedInEngine[k]) session.lineEnd(k, lineStarts[k] + seconds);
      return true;
    },

    finish() {
      if (!session) return false;
      if (lastLine >= 0 && !(lastLine in lineLengths)) session.lineEnd(lastLine);
      releaseButtons(Infinity);
      return true;
    },

    now() { return session ? session.now() : 0; },

    // Every mark that will be drawn has been drawn (the program is done and its last line was heard).
    isFinished() { return !session || !!session.finished; },

    timeline() {
      if (!session) return null;
      const now = session.now();
      return JSON.stringify({
        lines: lastSays.map((s, k) => ({ k, text: s.text, start: k in lineStarts ? lineStarts[k] : null, length: k in lineLengths ? lineLengths[k] : null })),
        statements: statements().map(st => Object.assign({ label: st.label, line: st.line }, statementProgress(st, now))),
        frames: null,
      });
    },

    clear() { clearNow(); return true; },

    // The screen under a finished drawing changed: erase what pointed at it, keep the cards (stickies, paper, photos,
    // 3D figures) and what is on them. JSON {kept, dropped}; kept 0 means nothing was erased (the host clears it all).
    keepNotesOnly() {
      if (!session || !session.keepNotesOnly) return null;
      return JSON.stringify(session.keepNotesOnly());
    },

    // The screen changed while the answer is still told: erase only what points at the screen. JSON {dropped, left}.
    dropPointing() {
      if (!session || !session.dropPointing) return null;
      return JSON.stringify(session.dropPointing());
    },

    // The cards the user can drag (paper, stickies, photos), each with what rides on it: JSON [{box [x, y, w, h] in
    // canvas units, marks, units (the elements the app drew for them, which follow the pointer while it drags)}].
    cards() {
      if (!session || !session.cardsNow) return null;
      return JSON.stringify(session.cardsNow().map(card => {
        const units = new Set();
        for (const node of card.nodes) { const unit = unitOf(node); if (unit && unit.__sent && unit.parentNode && unit.parentNode.tagName !== 'defs') units.add(unit.__n); }
        const w = card.window;
        const chrome = w ? { mark: w.mark, box: [w.box[0], w.box[1], w.box[2] - w.box[0], w.box[3] - w.box[1]], header: w.header, scale: w.scale, zoomed: w.zoomed, title: w.title, has3D: !!w.has3D } : null;
        return { box: [card.box[0], card.box[1], card.box[2] - card.box[0], card.box[3] - card.box[1]], marks: card.marks, units: [...units], window: chrome };
      }));
    },

    // The user closed a card (its window's red button): its marks go. JSON {closed, left} (left: marks still showing ink).
    closeCard({ marks }) {
      if (!session || !session.dropMarks) return null;
      const closed = session.dropMarks(marks || []);
      return JSON.stringify({ closed, left: session.inkCount ? session.inkCount() : session.visibleCount ? session.visibleCount() : 0 });
    },

    // The user made a card full screen (to: [scale, dx, dy] on top of where it is) or put it back (to: null). How many
    // marks moved.
    zoomCard({ marks, to }) {
      if (!session || !session.zoomMarks) return 0;
      return session.zoomMarks(marks || [], Array.isArray(to) && to.length === 3 ? to.map(Number) : null);
    },

    // The user dropped a card dx, dy canvas units away: its marks stay there. How many marks moved.
    moveCard({ marks, dx, dy }) {
      if (!session || !session.moveMarks) return 0;
      return session.moveMarks(marks || [], dx, dy);
    },

    // A button about to go up (box [x, y, w, h], its real size, in canvas units): where it can sit without touching the
    // drawing's words. The program places a button where it guesses a line ends, and the real button is taller than
    // its guess, so it sat on the text above it. Words keep `gap` clear around it, as do `avoid` (other buttons on
    // screen); photo captions don't count, since a price-tag button sits on its photo's strip on purpose. Moves down
    // first, then up, then sideways; JSON [x, y, w, h], the same box when it is already clear.
    buttonSpot({ box, gap, avoid }) {
      if (!stage || !Array.isArray(box) || box.length !== 4) return null;
      const [x, y, w, h] = box.map(Number), g = Math.max(0, Number(gap) || 0);
      if (![x, y, w, h].every(Number.isFinite)) return null;
      const others = [];
      for (const e of stage.querySelectorAll('text')) {
        if (e.__gone || e.__role === 'photo' || e.__role === 'button' || !e.textContent) continue;
        let o;
        try {
          const r = e.getBBox(), tr = e.__nudge || [0, 0], xf = e.__wrap && e.__wrap.__xf;
          o = [r.x + tr[0], r.y + tr[1], r.width, r.height];
          if (xf) o = [o[0] * xf[0] + xf[1], o[1] * xf[0] + xf[2], o[2] * xf[0], o[3] * xf[0]];
        } catch (_) { continue; }
        if (o[2] > 0 && o[3] > 0) others.push(o);
      }
      for (const a of avoid || []) if (Array.isArray(a) && a.length === 4 && a.every(v => Number.isFinite(+v))) others.push(a.map(Number));
      const hits = (bx, by) => others.some(o => bx - g < o[0] + o[2] && bx + w + g > o[0] && by - g < o[1] + o[3] && by + h + g > o[1]);
      const inside = (bx, by) => bx >= 4 && by >= 4 && bx + w <= streamW - 4 && by + h <= streamH - 4;
      if (!hits(x, y)) return JSON.stringify([x, y, w, h]);
      const step = Math.max(4, h / 4), candidates = [];
      for (let k = 1; k <= 16; k++) { candidates.push([x, y + k * step]); candidates.push([x, y - k * step]); }
      for (let k = 1; k <= 8; k++) for (const dy of [0, step * 2, -step * 2]) { candidates.push([x + k * w / 4, y + dy]); candidates.push([x - k * w / 4, y + dy]); }
      // nearest first, a sideways move counting double (a button belongs under its row, not beside the next word)
      candidates.sort((a, b) => (Math.abs(a[1] - y) + 2 * Math.abs(a[0] - x)) - (Math.abs(b[1] - y) + 2 * Math.abs(b[0] - x)));
      const free = candidates.find(([bx, by]) => inside(bx, by) && !hits(bx, by));
      return JSON.stringify(free ? [free[0], free[1], w, h] : [x, y, w, h]);
    },

    // Where mark i really is on the card now (its words measured with their real font, any nudge or drag applied):
    // JSON [x, y, w, h] in canvas units, or null when it isn't drawn.
    markBox({ i }) {
      if (!session || !session.drawnBox) return null;
      const b = session.drawnBox(+i);
      return b ? JSON.stringify([b[0], b[1], b[2] - b[0], b[3] - b[1]]) : null;
    },

    // Lab harness: draw a whole program at once on the engine's own schedule (no voice).
    // three-metal: one frame of a figure()'s tick functions. `ticks` is [[tick id, seconds since its beat], ...] for the
    // ticks the stage has started; each runs, then the poses they set on this figure's parts come back as one
    // Float32Array, 14 numbers a part: part number, what is set (1 pos, 2 rot, 4 scale, 8 show, 16 glow, 32 colour),
    // x y z, rotation x y z (degrees), scale, shown (0/1), glow, colour r g b (sRGB 0..1). A tick that throws, or keeps
    // taking more than 8 ms, stops for good.
    tick3d({ stage, ticks, dt }) {
      const live = session && session.live3d ? session.live3d() : null;
      if (!live || !live.ticks) return null;
      for (const entry of ticks || []) {
        const id = entry[0], fn = live.ticks[id];
        if (typeof fn !== 'function') continue;
        const started = Date.now();
        // Pose writes inside a tick set this frame's pose (outside one they become timed moves: the engine's handle).
        global.__mateInTick3d = true;
        try { fn(+entry[1] || 0, +dt || 1 / 60); }
        catch (e) { delete live.ticks[id]; HOST.log(`tick ${id} stopped: ${e && e.message}`); continue; }
        finally { global.__mateInTick3d = false; }
        if (Date.now() - started > 8) {
          slowTicks[id] = (slowTicks[id] || 0) + 1;
          if (slowTicks[id] > 5) { delete live.ticks[id]; HOST.log(`tick ${id} stopped: too slow`); }
        }
      }
      const prefix = stage + 'p', out = [];
      for (const id in live.anim) {
        if (!id.startsWith(prefix)) continue;
        const n = +id.slice(prefix.length), a = live.anim[id];
        if (!(n > 0) || !a) continue;
        let mask = 0;
        const p = a.pos || [0, 0, 0], r = a.rot || [0, 0, 0];
        if (a.pos) mask |= 1; if (a.rot) mask |= 2; if (a.scale != null) mask |= 4; if (a.show != null) mask |= 8; if (a.glow != null) mask |= 16;
        let rgb = [0, 0, 0];
        const hex = typeof a.color === 'string' ? /^#?([0-9a-f]{6})$/i.exec(a.color.trim()) : null;
        if (hex) { const v = parseInt(hex[1], 16); rgb = [(v >> 16 & 255) / 255, (v >> 8 & 255) / 255, (v & 255) / 255]; mask |= 32; }
        out.push(n, mask, p[0], p[1], p[2], r[0], r[1], r[2], a.scale != null ? a.scale : 1, a.show === false ? 0 : 1, a.glow || 0, rgb[0], rgb[1], rgb[2]);
      }
      return new Float32Array(out);
    },

    renderWhole({ w, h, width, code, ink }) {
      clearNow();
      useMateInk(ink);
      useCanvasScale(w, width);
      stage = new Element('div');
      documentRoot.appendChild(stage);
      streamW = w; streamH = h;
      MateDraw.setPen(SCREEN_PEN);
      const card = {};
      const report = MateDraw.render({ w, h, surface: 'none', code: (pieces || '') + '\n' + code }, stage, { width, whole: true, handle: card, codeStart: (pieces || '').length + 1 });
      wholeCard = { visibleCount: card.visibleCount, stateNow: card.state };
      return JSON.stringify(report);
    },
  };
})(this);
