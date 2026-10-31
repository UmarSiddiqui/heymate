// HeyMate's screen-drawing canvas. It runs the drawing engine (mate-draw-engine.js) and Mate's pieces
// (mate-draw-pieces.js) without a browser of their own: the explainer page (mate-host.js) boots this file, then the
// engine, in one scope and implements __host for it.
//
// The engine paints SVG. This file gives it the part of the DOM its painter touches (elements, attributes, inline
// styles and CSS animations, bounding boxes) and records what changes. The host collects the record with
// __drainRender() after every call and paints it itself; it also answers measurements (text widths and boxes, path
// lengths and points) so words are measured with the real fonts.
//
// mateCanvas is the API the host drives: a drawing streamed while Mate talks (beginStream, feed, line, finish ...), the
// user's edits to it (cards dragged, closed, zoomed), and a whole program drawn at once (renderWhole). Programs are
// model-written; this scope has no network, no files and nothing native beyond the __host functions.
//
// __host: now() seconds; schedule(id, s) / cancel(id) timers (the host calls __fireTimer(id)); log(text);
// textBox(json) / pathBox(d) -> [x, y, w, h]; textWidth(family, size, weight, text); pathLength(d); pathPoint(d, at);
// inkFor / busyFor / lumFor(x, y, w, h); figuresFloat(); shape3d(kind, recipe); caption(json); markSound(i, json);
// buttonReady(i, seconds).
(function (global) {
  'use strict';
  const host = global.__host;
  Object.assign(global, { window: global, self: global, performance: { now: () => host.now() * 1000 } });

  // ---------------------------------------------------------------- timers, on the host's clock
  const jobs = new Map();
  let jobCount = 0;
  function later(fn, seconds, repeat) {
    jobCount += 1;
    jobs.set(jobCount, { fn, repeat });
    host.schedule(jobCount, seconds);
    return jobCount;
  }
  global.setTimeout = (fn, ms) => later(fn, Math.max(0, +ms || 0) / 1000, 0);
  global.setInterval = (fn, ms) => { const gap = Math.max(0.004, (+ms || 0) / 1000); return later(fn, gap, gap); };
  global.clearTimeout = global.clearInterval = id => { if (jobs.delete(id)) host.cancel(id); };
  global.__fireTimer = id => {
    const job = jobs.get(id);
    if (!job) return;
    if (job.repeat) host.schedule(id, job.repeat); else jobs.delete(id);
    try { if (typeof job.fn === 'function') job.fn(); } catch (e) { host.log('timer error: ' + ((e && e.stack) || e)); }
  };
  const logAs = prefix => (...parts) => host.log(prefix + parts.map(String).join(' '));
  global.console = { log: logAs(''), warn: logAs('warn: '), error: logAs('error: ') };

  // ---------------------------------------------------------------- CSS animations
  const CURVES = { linear: [0, 0, 1, 1], ease: [0.25, 0.1, 0.25, 1], 'ease-in': [0.42, 0, 1, 1], 'ease-out': [0, 0, 0.58, 1], 'ease-in-out': [0.42, 0, 0.58, 1] };
  const bezierIn = text => { const m = /cubic-bezier\(([^)]*)\)/.exec(text); return m ? m[1].split(',').map(Number) : null; };
  // The shorthand the painter writes, "pen 0.62s cubic-bezier(.35,.2,.55,.95) 0.02s both": its name, duration, delay
  // and timing curve, stamped with when it was set.
  function readAnimation(value) {
    const text = String(value).trim();
    if (!text || text === 'none') return null;
    const words = text.replace(/cubic-bezier\([^)]*\)/, ' ').split(/\s+/).filter(Boolean);
    const seconds = words.filter(w => /^-?[\d.]+m?s$/.test(w)).map(w => (w.endsWith('ms') ? parseFloat(w) / 1000 : parseFloat(w)));
    let curve = bezierIn(text);
    if (!curve) { curve = CURVES.ease; for (const w of words) if (CURVES[w]) curve = CURVES[w]; }
    return { name: words[0], dur: seconds[0] || 0, delay: seconds[1] || 0, fn: curve, at: host.now() };
  }
  const camelCase = key => key.trim().replace(/-([a-z])/g, (_, c) => c.toUpperCase());

  // ---------------------------------------------------------------- what changed since the host last looked
  // The host draws each element directly under one of the painter's layer groups (or under <defs>) as one unit. A new or
  // changed unit is sent whole. A unit the host already has is never rebuilt by an edit (that would set its words again,
  // re-render a wash and restart its entry animation); the edit goes over as a small op on it instead:
  //   wrap    a drawn unit moves into a new <g> of its own (moved or scaled)
  //   prop    one property of a drawn element: opacity, a <g>'s transform, a pen mask's dash offset
  //   stop    a drawn element's animations jump to their end
  //   motion  properties animated from -> to over a time span (__mateMotion), run by the host
  const LAYERS = new Set(['under', 'main', 'hl', 'words']);
  const pending = { units: new Set(), removed: [], wraps: [], edits: [] };
  const isLayer = g => g.tagName === 'g' && LAYERS.has(g.attributes.id) && !!g.parentNode && g.parentNode.tagName === 'svg';
  function unitOf(node) {
    let n = node;
    while (n && n.parentNode && n.parentNode.tagName !== 'defs' && !isLayer(n.parentNode)) n = n.parentNode;
    return n && n.parentNode ? n : null;
  }
  const changed = node => { const unit = unitOf(node); if (unit) pending.units.add(unit); };
  // A pen path inside a <mask> is addressed by the mask's id, anything else by its number.
  function addressOf(node) {
    const mask = node.parentNode && node.parentNode.tagName === 'mask' ? node.parentNode.attributes.id : null;
    return mask ? { mask } : { n: node.__n };
  }
  const editProp = (node, key, value) => pending.edits.push(Object.assign({ op: 'prop', key, value }, addressOf(node)));

  // ---------------------------------------------------------------- the DOM the painter uses
  // element.style: reads give '' for anything unset; writes to a drawn element become edits where they can.
  function styleOf(node) {
    const props = {};
    const asEdit = (key, value) => {
      if (key === 'animation' && !node.__anim) { pending.edits.push(Object.assign({ op: 'stop' }, addressOf(node))); return true; }
      if (key === 'opacity') { editProp(node, 'opacity', +value); return true; }
      if (key === 'strokeDashoffset' && node.parentNode && node.parentNode.tagName === 'mask') { editProp(node, 'dash', +value); return true; }
      return false;
    };
    return new Proxy(props, {
      get: (_, key) => (key === '__props' ? props : typeof key !== 'string' ? undefined : key in props ? props[key] : ''),
      set: (_, key, value) => {
        props[key] = String(value);
        if (key === 'animation') node.__anim = readAnimation(value);
        if (!(node.__sent && asEdit(key, value))) changed(node);
        return true;
      },
    });
  }

  let lastNode = 0;
  // Every node under `root`, parents before children, until `visit` returns true.
  function walk(root, visit) {
    const go = n => n.childNodes.some(c => visit(c) === true || go(c));
    go(root);
  }
  // The engine wrapping a drawn unit: a fresh, empty <g> that is a unit itself, beside the unit going into it.
  const wrapsDrawn = (g, child) => !!child.__sent && g.tagName === 'g' && !g.__sent && g.childNodes.length === 0
    && unitOf(child) === child && unitOf(g) === g && g.parentNode === child.parentNode;

  class Element {
    constructor(tag) {
      Object.assign(this, { tagName: tag, nodeName: tag, nodeType: 1, __n: ++lastNode, attributes: Object.create(null), childNodes: [], parentNode: null, __text: null, __anim: null });
      this.style = styleOf(this);
      this.dataset = {};
    }
    hasAttribute(key) { return Reflect.has(this.attributes, key); }
    getAttribute(key) { return this.hasAttribute(key) ? this.attributes[key] : null; }
    setAttribute(key, value) {
      const text = String(value);
      this.attributes[key] = text;
      if (key === 'style') {
        text.split(';').forEach(declaration => {
          const colon = declaration.indexOf(':');
          if (colon > 0) this.style.__props[camelCase(declaration.slice(0, colon))] = declaration.slice(colon + 1).trim();
        });
      }
      if (this.__sent && this.tagName === 'g' && key === 'transform') pending.edits.push({ op: 'prop', key: 'transform', n: this.__n, value: text });
      else changed(this);
    }
    removeAttribute(key) { delete this.attributes[key]; changed(this); }
    appendChild(child) {
      if (!wrapsDrawn(this, child)) return this.insertBefore(child, null);
      // the host wraps the layer it already drew instead of drawing it again
      const row = child.parentNode.childNodes;
      row.splice(row.indexOf(child), 1);
      child.parentNode = this;
      this.childNodes.push(child);
      pending.units.delete(this);
      pending.units.delete(child);
      this.__sent = true;
      pending.wraps.push({ op: 'wrap', g: this.__n, child: child.__n });
      return child;
    }
    insertBefore(child, before) {
      if (child.parentNode) child.parentNode.removeChild(child);
      const at = before ? this.childNodes.indexOf(before) : -1;
      this.childNodes.splice(at < 0 ? this.childNodes.length : at, 0, child);
      child.parentNode = this;
      changed(child);
      return child;
    }
    removeChild(child) {
      const at = this.childNodes.indexOf(child);
      if (at === -1) return child;
      const unit = unitOf(child);
      if (unit === child) { pending.removed.push(child.__n); pending.units.delete(child); }
      else if (unit) pending.units.add(unit);
      this.childNodes.splice(at, 1);
      child.parentNode = null;
      return child;
    }
    remove() { const parent = this.parentNode; if (parent) parent.removeChild(this); }
    // Only what the painter asks for: '#id', 'tag', and lists of them.
    querySelectorAll(selector) {
      const tests = String(selector).split(',').map(s => s.trim()).filter(Boolean).map(s => (s.startsWith('#') ? n => n.attributes.id === s.slice(1) : n => n.tagName === s));
      const found = [];
      walk(this, n => { if (tests.some(t => t(n))) found.push(n); });
      return found;
    }
    querySelector(selector) { const [first] = this.querySelectorAll(selector); return first || null; }
    // Geometry: text and paths are measured by the host; circles and groups here.
    getBBox() {
      const asBox = ([x, y, width, height]) => ({ x, y, width, height });
      if (this.tagName === 'text') return asBox(host.textBox(JSON.stringify(describeText(this))));
      if (this.tagName === 'path') return asBox(host.pathBox(pathOf(this)));
      if (this.tagName === 'circle') { const [cx, cy, r] = ['cx', 'cy', 'r'].map(k => +this.attributes[k] || 0); return asBox([cx - r, cy - r, 2 * r, 2 * r]); }
      const boxes = [];
      for (const c of this.childNodes) {
        try { const b = c.getBBox(); if (b && (b.width || b.height)) boxes.push(b); } catch (_) { /* unmeasurable: left out */ }
      }
      if (!boxes.length) return asBox([0, 0, 0, 0]);
      const left = Math.min(...boxes.map(b => b.x)), top = Math.min(...boxes.map(b => b.y));
      return asBox([left, top, Math.max(...boxes.map(b => b.x + b.width)) - left, Math.max(...boxes.map(b => b.y + b.height)) - top]);
    }
    getComputedTextLength() { const t = describeText(this); return host.textWidth(t.family, t.size, t.weight, this.textContent); }
    getTotalLength() { return host.pathLength(pathOf(this)); }
    getPointAtLength(length) { const [x, y] = host.pathPoint(pathOf(this), +length || 0); return { x, y }; }
  }
  const pathOf = node => node.attributes.d || '';
  Object.defineProperties(Element.prototype, {
    children: { get() { return this.childNodes; } },
    firstChild: { get() { return this.childNodes.length ? this.childNodes[0] : null; } },
    lastChild: { get() { return this.childNodes.length ? this.childNodes[this.childNodes.length - 1] : null; } },
    id: { get() { return this.getAttribute('id') || ''; } },
    ownerSVGElement: { get() { let p = this.parentNode; while (p && p.tagName !== 'svg') p = p.parentNode; return p || null; } },
    textContent: {
      get() { return this.__text ?? this.childNodes.map(c => c.textContent).join(''); },
      set(value) {
        this.childNodes.forEach(c => { c.parentNode = null; });
        this.childNodes = [];
        this.__text = String(value);
        changed(this);
      },
    },
    innerHTML: {
      get() { return ''; },
      set(markup) {
        this.childNodes.slice().forEach(c => this.removeChild(c));
        parseMarkup(String(markup)).forEach(c => this.appendChild(c));
      },
    },
    classList: {
      get() {
        const names = () => (this.attributes.class || '').split(/\s+/).filter(Boolean);
        return {
          add: c => { if (!names().includes(c)) this.setAttribute('class', [...names(), c].join(' ')); },
          remove: c => this.setAttribute('class', names().filter(x => x !== c).join(' ')),
          contains: c => names().includes(c),
        };
      },
    },
  });

  // The markup the painter writes into a new card: well-formed tags with quoted attributes, nothing else.
  function parseMarkup(markup) {
    const roots = [], open = [], tag = /<\s*(\/?)\s*([A-Za-z][\w:-]*)((?:\s+[\w:-]+\s*=\s*"[^"]*")*)\s*(\/?)\s*>/g;
    for (const [, closing, name, attrs, selfClosing] of markup.matchAll(tag)) {
      if (closing) { open.pop(); continue; }
      const e = new Element(name);
      for (const [, key, value] of attrs.matchAll(/([\w:-]+)\s*=\s*"([^"]*)"/g)) e.setAttribute(key, value);
      if (open.length) open[open.length - 1].appendChild(e); else roots.push(e);
      if (!selfClosing) open.push(e);
    }
    return roots;
  }

  // What the host needs to set a <text>: its font, anchor, baseline and lines.
  const inherited = (node, key) => { for (let n = node; n; n = n.parentNode) if (n.attributes && key in n.attributes) return n.attributes[key]; return null; };
  const weightOf = w => (w === 'bold' ? 700 : w === 'normal' || w == null ? 400 : (parseInt(w, 10) || 400));
  function describeText(t) {
    const [x, y] = ['x', 'y'].map(k => parseFloat(t.attributes[k]) || 0);
    const lines = t.__text != null || !t.childNodes.length ? [{ x, dy: 0, text: t.textContent }]
      : t.childNodes.filter(s => s.tagName === 'tspan').map(s => ({ x: s.attributes.x == null ? null : parseFloat(s.attributes.x), dy: parseFloat(s.attributes.dy) || 0, text: s.textContent }));
    return {
      family: inherited(t, 'font-family') || 'sans-serif',
      size: parseFloat(inherited(t, 'font-size')) || 16,
      weight: weightOf(inherited(t, 'font-weight')),
      anchor: inherited(t, 'text-anchor') || 'start',
      baseline: t.attributes['dominant-baseline'] || 'auto',
      x, y, lines,
    };
  }

  const body = new Element('body');
  global.document = {
    body, documentElement: body,
    fonts: { ready: Promise.resolve() },
    createElement: tag => new Element(tag),
    createElementNS: (_, tag) => new Element(tag),
    getElementById: id => { let found = null; walk(body, n => { if (n.attributes.id === id) found = n; return !!found; }); return found; },
  };

  // ---------------------------------------------------------------- handing the paint to the host
  function serialize(node) {
    node.__sent = true;
    const out = {};
    out.n = node.__n; out.tag = node.tagName; out.a = node.attributes;
    if (node.__k != null) out.k = node.__k;            // the index of the mark that painted it
    if (node.__anim) out.anim = node.__anim;
    if (Object.keys(node.style.__props).length) out.st = node.style.__props;
    if (node.tagName === 'text') out.text = describeText(node);
    else if (node.childNodes.length) out.ch = node.childNodes.map(serialize);
    return out;
  }
  // Everything since the last call, as JSON ops in the order the host applies them: removals, wraps, new or rebuilt units,
  // then edits to drawn ones (a motion always finds its element built). '' when nothing changed.
  global.__drainRender = () => {
    const { units, removed, wraps, edits } = pending;
    if (units.size + removed.length + wraps.length + edits.length === 0) return '';
    Object.assign(pending, { units: new Set(), removed: [], wraps: [], edits: [] });
    const fresh = [...units].filter(u => unitOf(u) === u), batch = new Set(fresh);
    // Units are set group by group, <defs> first (paths point at masks), each in document order and placed before
    // the first sibling after it that the host already has, so a run of new neighbours keeps its order.
    const groups = [...new Set(fresh.map(u => u.parentNode))].sort((a, b) => (a.tagName === 'defs' ? 0 : 1) - (b.tagName === 'defs' ? 0 : 1));
    const sets = groups.flatMap(group => {
      const row = group.childNodes, index = new Map(row.map((c, i) => [c, i]));
      return fresh.filter(u => u.parentNode === group).sort((a, b) => index.get(a) - index.get(b)).map(u => {
        let next = index.get(u) + 1;
        while (next < row.length && batch.has(row[next])) next++;
        return { op: 'set', group: group.tagName === 'defs' ? 'defs' : group.attributes.id, before: next < row.length ? row[next].__n : null, node: serialize(u) };
      });
    });
    return JSON.stringify([...removed.map(n => ({ op: 'remove', n })), ...wraps, ...sets, ...edits]);
  };
  // An edit's animation, declared once: each item takes one property of a drawn element from -> to, starting `at`
  // seconds from now, for `dur` seconds, on the CSS curve `ease`. The host runs it; the engine removes an erased element
  // itself when the erase ends.
  global.__mateMotion = (items, at, dur, ease) => {
    const begin = host.now() + Math.max(0, +at || 0), fn = bezierIn(String(ease || '')) || CURVES.ease;
    const moved = items.map(item => Object.assign({ key: item.prop === 'xf' ? 'transform' : item.prop, from: item.from, to: item.to }, addressOf(item.node)));
    pending.edits.push({ op: 'motion', begin, dur: Math.max(0.001, +dur || 0), fn, items: moved });
  };

  // ---------------------------------------------------------------- the pen and the host hooks
  // The screen pen: speed-paced strokes on the pen's ease. Fills get the watercolour wash; Mate's crisp things (paper,
  // pills, badges, windows) opt out per mark.
  const PEN = { per: 1400, base: 0.25, min: 0.3, max: 1.4, ease: 'cubic-bezier(0.35,0.2,0.55,0.95)', halo: null, wash: true, washMaxArea: 60000 };
  // A soft halo under strokes drawn in plain white or near-black, so they read on any screen. Mate's own ink has none
  // here: the pieces give each screen mark its own glow.
  const PLAIN_INK_HALO = { '#FFFFFF': [['#080E1E', 0.16, 7], ['#080E1E', 0.45, 3]], '#15171C': [['#FFFFFF', 0.35, 7], ['#FFFFFF', 0.85, 3]] };
  const PACING = { minPace: 0.8, maxSlow: 1.4, sequential: true, maxSpread: 1.25, rushPace: 0.1 };
  const DEFAULT_INK = '#3380FF';
  const optional = (name, fallback) => (...args) => (host[name] ? host[name](...args) : fallback);
  Object.assign(global, {
    __mateInk: DEFAULT_INK,
    __inkFor: (x, y, w, h) => host.inkFor(x, y, w, h),
    __busyFor: optional('busyFor', 0),
    __lumFor: optional('lumFor', -1),
    __figuresFloat: () => (host.figuresFloat ? host.figuresFloat() === true : false),   // streamed figures stand on clear ground
    __shape3d: (kind, recipe) => { if (host.shape3d) host.shape3d(kind, recipe); },      // a part starts building as its statement runs
    // the host draws these itself: click targets, real buttons, card windows, and a frame's marquee
    __hostDrawsPointers: true, __hostDrawsButtons: true, __hostDrawsWindows: true, __hostDrawsMarquee: true,
  });

  // ================================================================ one drawing
  // Everything the canvas knows about the drawing on screen. A new drawing (or clear()) replaces it whole.
  const blankDrawing = () => ({
    session: null,              // the engine's live drawing
    stage: null, w: 0, h: 0,
    whole: null,                // renderWhole()'s drawing, for state() when nothing streams
    // speech: when each line started and how long it ran, which of them the engine was told about, the last one heard
    starts: {}, lengths: {}, told: {}, lastLine: -1,
    // the say() list (each with the mark count when it was said), the program, and when each drawn mark's pen started
    // and for how long it runs
    says: [], program: '', drawn: {},
    statements: { length: -1, list: [] }, analysed: { program: null, json: null }, ends: null,
    // a drawing kept over several turns: the earlier turns' code (ending in a __turn(n, keep) line), the new turn's first
    // line and first mark
    earlier: '', firstLine: 0, firstMark: 0,
    subtitleLine: -1, subtitleTimer: null,
    buttons: [], beatDrawnUntil: {}, totalMarks: null,
    cardsDrawn: [],             // a stroke inside a card drawn so far is pencil on paper
    slowTicks: {},              // figure tick functions over 8 ms, and how often (a sixth time stops one)
  });
  let d = blankDrawing(), pieces = null, subtitles = false;

  function clearDrawing() {
    if (d.session) { try { d.session.stop(); } catch (_) { /* already gone */ } }
    if (d.stage) d.stage.remove();
    if (d.subtitleTimer) clearInterval(d.subtitleTimer);
    d = blankDrawing();
    host.caption('');
  }
  function newStage(w, h, width, ink) {
    clearDrawing();
    global.__mateInk = /^#[0-9a-fA-F]{6}$/.test(String(ink || '')) ? String(ink).toUpperCase() : DEFAULT_INK;
    PEN.halo = Object.assign({}, PLAIN_INK_HALO);
    // screen points per canvas unit (the canvas is the screenshot), so pieces size screen marks in points
    global.__canvasUnitPoints = w > 0 && width > 0 ? width / w : 1;
    d.stage = new Element('div');
    body.appendChild(d.stage);
    d.w = w; d.h = h;
    MateDraw.setPen(PEN);
  }

  // The beat (say() line) mark i belongs to: the last line said before it was made. says is in program order.
  function beatOf(i, says = d.says) {
    let lo = 0, hi = says.length;
    while (lo < hi) { const mid = (lo + hi) >> 1; if (says[mid].at <= i) lo = mid + 1; else hi = mid; }
    return Math.max(0, lo - 1);
  }
  // The engine calls this as each mark starts drawing.
  function onMarkDrawn(made, at) {
    const mark = made[0];
    if (at.i == null || !mark || !d.session) return;
    d.drawn[at.i] = { t: d.session.now(), pen: MateDraw.natural(mark).dur * Math.max(at.pace || 1, 0.35) };
    soundFor(mark, at.i);
    buttonDrawn(mark, at.i);
  }

  // ---------------------------------------------------------------- buttons come last in their beat
  // A button (or a linked word) is the user's next step, so the host shows it only once everything else its beat draws is
  // on screen; when the next line starts or the drawing ends, the buttons still waiting go up then.
  function buttonDrawn(mark, i) {
    if (!d.session) return;
    const beat = beatOf(i), timing = d.session.startsIn ? d.session.startsIn(i) : null;
    const done = host.now() + (timing ? Math.max(0, timing[0]) + Math.max(0, timing[1]) : 0);
    d.beatDrawnUntil[beat] = Math.max(d.beatDrawnUntil[beat] || 0, done);
    if (mark.role === 'button' || (mark.do === 'text' && mark.link)) d.buttons.push({ i, beat });
    releaseButtons(-1);
  }
  const allDrawn = (from, to) => { for (let j = from; j < to; j++) if (!d.drawn[j]) return false; return true; };
  // Shows the buttons whose beat is fully drawn, and every button of a beat before `throughBeat` (Infinity: all of them).
  function releaseButtons(throughBeat) {
    if (d.buttons.length === 0 || typeof host.buttonReady !== 'function') return;
    const now = host.now();
    d.buttons = d.buttons.filter(({ i, beat }) => {
      const from = beat ? d.says[beat].at : 0, to = d.says[beat + 1] ? d.says[beat + 1].at : d.totalMarks;
      const ready = beat < throughBeat || (to != null && allDrawn(from, to));
      if (ready) host.buttonReady(i, Math.max(0, (d.beatDrawnUntil[beat] || now) - now) + 0.15);
      return !ready;
    });
  }

  // ---------------------------------------------------------------- what each mark sounds like
  // The host makes the drawing's sound from what it paints: a texture for strokes and words (felt tip on the screen,
  // pencil on a card, handwriting) that follows the pen, plus a few named sounds for moments (a card landing, a pill
  // popping, a click target, typing, a 3D part, sfx() accents). This only says which; the host times them to its layers.
  const ACCENTS = new Set(['tada', 'ding', 'nope', 'stamp', 'sparkle', 'whoosh', 'boing', 'page-turn']);
  const PILLS = new Set(['label', 'num', 'cheer', 'button']);
  const STROKES = new Set(['line', 'circle', 'ellipse', 'rect', 'poly', 'path', 'arrow', 'molecule']);
  // (a button's sound is played by the host when the real button goes up)
  const ROLE_SOUND = new Map([['type', 'type-keys'], ['copy', 'copy-tick'], ['target', 'target-ping'], ['hover', 'target-ping']]);
  const EDIT_SOUND = new Map([['move', 'slide'], ['moveTo', 'slide'], ['scale', 'slide'], ['startOver', 'page-clear'], ['highlight', 'highlighter']]);
  const KIND_SOUND = new Map([['part3d', 'build-3d'], ['highlight', 'highlighter']]);
  // {texture: 'felt' | 'pencil' | 'writing' | 'eraser' | null, events: [{id, at, end}]}
  function soundOf(m) {
    if (m.role === 'sfx') return { texture: null, events: ACCENTS.has(m.payload) ? [{ id: m.payload }] : [] };
    const events = [];
    if (typeof m.snd === 'string') events.push({ id: m.snd, at: m.snd === 'tape' ? 0.12 : 0 });   // tape lands a beat late
    if (m.do === 'edit') {
      const edit = m.op ? m.op.op : undefined;
      if (edit === 'startOver') d.cardsDrawn = [];
      if (EDIT_SOUND.has(edit)) events.push({ id: EDIT_SOUND.get(edit) });
      return edit === 'erase' ? { texture: 'eraser', events } : { texture: null, events };
    }
    for (const id of [ROLE_SOUND.get(m.role), KIND_SOUND.get(m.do)]) if (id) events.push({ id });
    if (m.do === 'text') return { texture: PILLS.has(m.role) || !String(m.text || '').trim() ? null : 'writing', events };
    if (!STROKES.has(m.do) || m.outline === false) return { texture: null, events };
    const box = MateDraw.markBox(m), inCard = d.cardsDrawn.length && box ? MateDraw.onCardTest(d.cardsDrawn) : null;
    const flicks = m.do === 'arrow' || !!m.head;
    if (flicks) events.push({ id: 'pen-flick', at: -0.04, end: true });
    return { texture: inCard && inCard(box) ? 'pencil' : 'felt', events };
  }
  function soundFor(m, i) {
    const box = MateDraw.isCardMark(m) ? MateDraw.markBox(m) : null;
    if (box) d.cardsDrawn.push(box);
    if (typeof host.markSound !== 'function' || !d.session || !d.session.startsIn) return;
    let sound = null;
    try { sound = soundOf(m); } catch (_) { /* a mark the table doesn't know is silent */ }
    if (!sound || (!sound.texture && sound.events.length === 0)) return;
    // when the engine expects the mark to start and how long it runs: what the host goes by for marks it paints nothing for
    const [delay, dur] = d.session.startsIn(i) || [0.02, 0.4];
    host.markSound(i, JSON.stringify({ texture: sound.texture, events: sound.events, delay: Math.max(0, delay), dur: Math.max(0, dur) }));
  }

  // ---------------------------------------------------------------- the program's statements, for the timeline and subtitles
  // A statement as a short label: 'ring "Export"', 'for loop'.
  function labelOf(text) {
    if (/^\s*for\b/.test(text)) return 'for loop';   // a loop's body says nothing short
    const [, call] = /^\s*(?:const\s+\w+\s*=\s*)?([A-Za-z_$][\w$]*)\s*\(/.exec(text) || [];
    const quoted = /"([^"]+)"|'([^']+)'/.exec(text), words = quoted ? quoted[1] || quoted[2] : null;
    if (!call) return text.trim().slice(0, 24);
    return words ? `${call} "${words.length > 34 ? words.slice(0, 33) + '…' : words}"` : call;
  }
  // The program's own statements that made marks (not the pieces', not the canvas's turn lines), with their marks [n0, n1).
  function statements() {
    if (d.statements.length !== d.program.length) {
      const skip = (pieces || '').length, list = [];
      try {
        for (const st of MateDraw.attribute(d.program, d.w, d.h)) {
          if (st.e <= skip || st.n1 <= st.n0) continue;
          const text = d.program.slice(st.s, st.e).replace(/^[\s;]+/, '');
          if (!text.startsWith('__turn(')) list.push({ label: labelOf(text), n0: st.n0, n1: st.n1, line: beatOf(st.n0) });
        }
      } catch (_) { /* keep what was attributed */ }
      d.statements = { length: d.program.length, list };
    }
    return d.statements.list;
  }
  function progressOf(st, now) {
    const runs = [];
    for (let i = st.n0; i < st.n1; i++) if (d.drawn[i]) runs.push(d.drawn[i]);
    const marks = st.n1 - st.n0, done = runs.filter(r => now >= r.t + r.pen).length;
    return {
      state: done === marks ? 'done' : runs.length ? 'drawing' : 'waiting',
      first: runs.length ? Math.min(...runs.map(r => r.t)) : null,
      end: runs.length ? Math.max(...runs.map(r => r.t + r.pen)) : null,
      drawnMarks: runs.length, marks,
    };
  }
  // Debug subtitles (drawn by the host): the beat being heard and its calls as the pen reaches them.
  function showSubtitle() {
    const k = d.subtitleLine;
    if (!subtitles || !d.session || k < 0) { host.caption(''); return; }
    const now = d.session.now(), heard = k in d.starts ? now - d.starts[k] : 0;
    const length = k in d.lengths ? ` / ${d.lengths[k].toFixed(1)}s` : '';
    const chips = statements().filter(st => st.line === k || (st.line < k && progressOf(st, now).state !== 'done'))
      .map(st => ({ label: st.label, state: progressOf(st, now).state, late: st.line < k }));
    host.caption(JSON.stringify({ header: `beat ${k + 1} of ${d.says.length} · ${heard.toFixed(1)}s${length}`, text: (d.says[k] || {}).text || '', chips }));
  }

  // ---------------------------------------------------------------- reading the program for the host
  const withPieces = code => [pieces || '', ...(d.earlier ? [d.earlier] : []), code].join('\n');
  // The engine counts lines from the top of the whole program, Mate's pieces and earlier turns included; a message
  // about this turn's code counts from its own first line instead.
  function ownLines(message) {
    if (!message) return message;
    const before = withPieces('').split('\n').length - 1;
    return String(message).replace(/\b(at|after) line (\d+)/, (whole, word, n) => (+n > before ? `${word} line ${+n - before}` : whole));
  }
  // Marks that only point, explain, credit or act, never a picture of their own.
  const NOT_A_PICTURE = new Set(['cheer', 'source', 'key', 'tie', 'sfx', 'button', 'type', 'copy', 'open', 'handoff']);
  // The host's actions, each acting at a point (or box) when its line is heard.
  const ACTION_ROLES = new Set(['point', 'target', 'hover', 'type', 'copy', 'open', 'handoff', 'button', 'tourjob', 'tourtuck', 'tourasks', 'tournotch', 'tourfade']);
  // An invisible dot a piece leaves where the host acts; it shows no ink.
  const isHostSpot = m => m.do === 'dot' && m.outline === false && m.fillAlpha === 0;
  function actionOf(m, line, i) {
    const acts = (m.do === 'image' && m.query) || (m.do === 'text' && m.link) || ACTION_ROLES.has(m.role);
    if (!acts) return null;
    const at = { x: m.at[0], y: m.at[1] };
    // a photo is looked for as soon as it is written, so it is there when its line is heard
    if (m.do === 'image' && m.query) return { role: 'photo', ...at, r: 0, box: [m.at[0], m.at[1], m.w, m.h], label: null, text: String(m.query), line, i };
    if (m.do === 'text' && m.link) return { role: 'link', ...at, r: 0, box: null, label: null, text: String(m.link), line, i };
    return { role: m.role, ...at, r: m.ring || 0, box: m.box || null, label: m.label || null, text: m.payload == null ? null : String(m.payload), line, i };
  }
  // Runs the complete statements so far: the lines, the host's actions (photos to find, links, pointers, typing ...), how
  // much ink there is, whether it makes a picture worth keeping, and which lines point at the screen or draw on a card.
  // The host goes on with only the card lines when the screen changes under the answer.
  function analyseNow(program, w, h, knownEnds) {
    const marks = MateDraw.runCode(program, w, h, { knownEnds }), says = marks.says || [];
    d.program = program; d.says = says;
    const cardBoxes = marks.filter(m => MateDraw.isCardMark(m)).map(m => MateDraw.markBox(m)).filter(Boolean);
    const onCard = MateDraw.onCardTest(cardBoxes) || (() => false);
    const actions = [], pointing = new Set(), carded = new Set();
    for (let i = turnStart(); i < marks.length; i++) {
      const m = marks[i];
      if (!m) continue;
      const line = beatOf(i, says), action = actionOf(m, line, i);
      if (action) actions.push(action);
      if (MateDraw.isCardMark(m)) carded.add(line);
      else if (MateDraw.pointsAtScreen(m)) { const b = MateDraw.markBox(m); (b && onCard(b) ? carded : pointing).add(line); }
    }
    const inked = marks.filter(m => m && !isHostSpot(m));
    // A picture is kept in the chat: a card (paper, a photo, a 3D figure; not the plate under a lone sources line) or a
    // sketch of three or more free strokes. Rings, pills, badges, highlights and a loose arrow only point.
    const sketch = inked.filter(m => !MateDraw.pointsAtScreen(m) && !NOT_A_PICTURE.has(m.role) && m.do !== 'text' && m.do !== 'highlight');
    const ascending = set => [...set].sort((a, b) => a - b);
    return JSON.stringify({
      lines: says.map(s => String(s.text || '')), actions, marks: marks.length, inked: inked.length,
      picture: marks.some(m => MateDraw.isCardMark(m) && !m.sourcePlate) || sketch.length >= 3, firstLine: d.firstLine,
      error: ownLines(marks.error) || null, warnings: (marks.warnings || []).slice(0, 5),
      pointingLines: ascending(pointing), cardLines: ascending(carded),
    });
  }
  const turnStart = () => Math.max(0, d.firstMark);
  // feed() comes with every streamed chunk, but its complete statements change only now and then.
  function analyse(program, knownEnds) {
    if (d.analysed.program !== program) d.analysed = { program, json: analyseNow(program, d.w, d.h, knownEnds) };
    return d.analysed.json;
  }
  // Tells the engine about lines heard before it knew them (their statements had not streamed in yet).
  function tellEngineHeardLines() {
    if (!d.session) return;
    const known = (d.session.timeline.lines || []).length;
    Object.keys(d.starts).map(Number).filter(k => k < known && !d.told[k]).forEach(k => {
      d.session.lineStart(k, d.starts[k]);
      if (k in d.lengths) d.session.lineEnd(k, d.starts[k] + d.lengths[k]);
      d.told[k] = true;
    });
  }
  const asBox = b => [b[0], b[1], b[2] - b[0], b[3] - b[1]];

  // ---------------------------------------------------------------- a 3D figure's poses for the host
  // 14 numbers a part: part number, what is set (1 pos, 2 rot, 4 scale, 8 show, 16 glow, 32 colour), x y z, rotation
  // x y z in degrees, scale, shown (0/1), glow, colour r g b (0..1).
  function poseOf(n, a) {
    const hex = /^#?([0-9a-f]{6})$/i.exec(typeof a.color === 'string' ? a.color.trim() : '');
    const rgb = hex ? [16, 8, 0].map(shift => ((parseInt(hex[1], 16) >> shift) & 255) / 255) : [0, 0, 0];
    const flags = [[a.pos, 1], [a.rot, 2], [a.scale != null, 4], [a.show != null, 8], [a.glow != null, 16], [hex, 32]].reduce((sum, [on, bit]) => sum | (on ? bit : 0), 0);
    const xyz = v => [0, 1, 2].map(k => (v || [0, 0, 0])[k]);
    return [n, flags, ...xyz(a.pos), ...xyz(a.rot), a.scale != null ? a.scale : 1, a.show === false ? 0 : 1, a.glow || 0, ...rgb];
  }

  global.mateCanvas = {
    setPieces(source) { pieces = source; return true; },

    // A drawing streamed while Mate talks: w, h the canvas (the screenshot's pixels), width the screen in points.
    beginStream({ w, h, width, subtitles: withSubtitles, ink }) {
      newStage(w, h, width, ink);
      d.ends = MateDraw.statementScanner();
      subtitles = !!withSubtitles;
      const options = { width, pace: 'speech', speech: 'external', onDraw: onMarkDrawn, codeStart: (pieces || '').length + 1 };
      d.session = MateDraw.live({ w, h, surface: 'none' }, d.stage, Object.assign(options, PACING));
      return true;
    },

    // A new turn on the drawing already showing. What is drawn stays; marks still waiting for their line (the user
    // interrupted) and an unfinished last statement are dropped for good. feed() then takes only the new turn's code,
    // whose lines go on counting from firstLine. JSON {firstLine, marks (drawn now), code}: code is what stays on the
    // card (without the pieces), ending in a __turn(n, keep) line; code + "\n" + the new turn replays to the same drawing.
    continueStream({ subtitles: withSubtitles } = {}) {
      if (!d.session) return null;
      if (withSubtitles != null) subtitles = !!withSubtitles;
      const next = d.session.continueTurn(), lead = (pieces || '') + '\n';
      const kept = next.kept.startsWith(lead) ? next.kept.slice(lead.length) : '';
      d.earlier = (kept && !kept.endsWith('\n') ? kept + '\n' : kept) + `__turn(${next.turn}, ${next.keep});`;
      Object.assign(d, { firstLine: next.firstLine, firstMark: next.start, analysed: { program: null, json: null }, statements: { length: -1, list: [] } });
      return JSON.stringify({ firstLine: next.firstLine, marks: next.visible, code: d.earlier });
    },

    // What is on the drawing now, for the model (parts with ids like p3, boxes in canvas pixels, what was said), or null.
    state() {
      const shown = d.session || d.whole;
      if (!shown || !shown.visibleCount()) return null;
      // a continued drawing reads as finished: the host asks right after continueStream(), before the new turn draws
      const status = d.earlier ? 'The drawing is finished: all of it is on screen.' : undefined;
      return shown.stateNow({ drawnOnly: true, maxChars: 12000, status });
    },

    // The program so far (done: all of it). Returns the analysis JSON of its complete statements.
    feed({ code, done }) {
      if (!d.session) return null;
      const program = withPieces(code), finished = !!done;
      d.session.update(program, finished);
      tellEngineHeardLines();
      const ends = d.ends(program), complete = finished ? program : program.slice(0, ends.length ? ends[ends.length - 1] : 0);
      const analysis = analyse(complete, ends);
      if (finished && analysis) {
        try { d.totalMarks = JSON.parse(analysis).marks; } catch (_) { /* leave unknown */ }
        releaseButtons(-1);
      }
      return analysis;
    },

    // Line k starts being heard. A line that started before and has no length yet ends now.
    line(k) {
      const s = d.session;
      if (!s) return false;
      if (d.lastLine >= 0 && d.lastLine < k && !(d.lastLine in d.lengths)) s.lineEnd(d.lastLine);
      d.starts[k] = s.now();
      d.lastLine = k;
      releaseButtons(k);
      tellEngineHeardLines();
      if (subtitles) {
        d.subtitleLine = k;
        showSubtitle();
        d.subtitleTimer = d.subtitleTimer || setInterval(showSubtitle, 120);
      }
      return true;
    },

    // How long line k is when spoken, once the host knows.
    lineLength(k, seconds) {
      if (!d.session || !(seconds > 0)) return false;
      d.lengths[k] = seconds;
      if (d.told[k]) d.session.lineEnd(k, d.starts[k] + seconds);
      return true;
    },

    // The voice is done: the last line ends now and every waiting button goes up.
    finish() {
      if (!d.session) return false;
      if (d.lastLine >= 0 && !(d.lastLine in d.lengths)) d.session.lineEnd(d.lastLine);
      releaseButtons(Infinity);
      return true;
    },

    now() { return d.session ? d.session.now() : 0; },

    // Everything the program will draw has been drawn (it is complete and its last line was heard).
    isFinished() { return d.session ? !!d.session.finished : true; },

    timeline() {
      if (!d.session) return null;
      const now = d.session.now(), seen = (table, k) => (k in table ? table[k] : null);
      return JSON.stringify({
        lines: d.says.map((s, k) => ({ k, text: s.text, start: seen(d.starts, k), length: seen(d.lengths, k) })),
        statements: statements().map(st => ({ label: st.label, line: st.line, ...progressOf(st, now) })),
        frames: null,
      });
    },

    clear() { clearDrawing(); return true; },

    // The screen under a finished drawing changed: erase what pointed at it, keep the cards and what is on them.
    // JSON {kept, dropped}; kept 0 means nothing stays (the host clears it all).
    keepNotesOnly() { return d.session && d.session.keepNotesOnly ? JSON.stringify(d.session.keepNotesOnly()) : null; },

    // The screen changed while the answer is still told: erase only what points at it. JSON {dropped, left}.
    dropPointing() { return d.session && d.session.dropPointing ? JSON.stringify(d.session.dropPointing()) : null; },

    // The cards the user can drag, each with its marks and the units the host drew for them (they follow the pointer):
    // JSON [{box [x, y, w, h], marks, units, window}], in canvas units.
    cards() {
      if (!d.session || !d.session.cardsNow) return null;
      const drawnUnit = node => { const u = unitOf(node); return u && u.__sent && u.parentNode && u.parentNode.tagName !== 'defs' ? u.__n : null; };
      return JSON.stringify(d.session.cardsNow().map(({ box, marks, nodes, window: frame }) => ({
        box: asBox(box), marks,
        units: [...new Set(nodes.map(drawnUnit).filter(n => n != null))],
        window: frame ? { mark: frame.mark, box: asBox(frame.box), header: frame.header, scale: frame.scale, zoomed: frame.zoomed, title: frame.title, has3D: !!frame.has3D } : null,
      })));
    },

    // The user closed a card: its marks go. JSON {closed, left} (left: marks still showing ink).
    closeCard({ marks }) {
      const s = d.session;
      if (!s || !s.dropMarks) return null;
      const closed = s.dropMarks(marks || []), left = s.inkCount ? s.inkCount() : s.visibleCount ? s.visibleCount() : 0;
      return JSON.stringify({ closed, left });
    },

    // The user made a card full screen (to: [scale, dx, dy] over where it is) or put it back (to: null). Marks moved.
    zoomCard({ marks, to }) {
      if (!d.session || !d.session.zoomMarks) return 0;
      return d.session.zoomMarks(marks || [], Array.isArray(to) && to.length === 3 ? to.map(Number) : null);
    },

    // The user dropped a card dx, dy canvas units away. Marks moved.
    moveCard({ marks, dx, dy }) { return d.session && d.session.moveMarks ? d.session.moveMarks(marks || [], dx, dy) : 0; },

    // Where a button about to go up (box [x, y, w, h], its real size) can sit without touching the drawing's words: the
    // program guessed where its line ends, and the real button is taller. Words keep `gap` clear around it, as do the
    // `avoid` boxes (other buttons); photo captions don't count (a price-tag button sits on its photo on purpose). It
    // tries down, up, then sideways, nearest first with sideways moves counting double. JSON [x, y, w, h].
    buttonSpot({ box, gap, avoid }) {
      if (!d.stage || !Array.isArray(box) || box.length !== 4) return null;
      const [x, y, w, h] = box.map(Number), margin = Math.max(0, Number(gap) || 0);
      if (![x, y, w, h].every(Number.isFinite)) return null;
      const blockers = [...d.stage.querySelectorAll('text').map(wordsBox).filter(Boolean),
        ...(avoid || []).filter(a => Array.isArray(a) && a.length === 4 && a.every(v => Number.isFinite(+v))).map(a => a.map(Number))];
      const clear = ([bx, by]) => !blockers.some(([ox, oy, ow, oh]) => bx - margin < ox + ow && bx + w + margin > ox && by - margin < oy + oh && by + h + margin > oy);
      if (clear([x, y])) return JSON.stringify([x, y, w, h]);
      const step = Math.max(4, h / 4), spots = [];
      for (let k = 1; k <= 16; k++) spots.push([x, y + k * step], [x, y - k * step]);
      for (let k = 1; k <= 8; k++) for (const lift of [0, 2 * step, -2 * step]) spots.push([x + k * w / 4, y + lift], [x - k * w / 4, y + lift]);
      const distance = ([bx, by]) => Math.abs(by - y) + 2 * Math.abs(bx - x);
      const onCanvas = ([bx, by]) => bx >= 4 && by >= 4 && bx + w <= d.w - 4 && by + h <= d.h - 4;
      const spot = spots.sort((a, b) => distance(a) - distance(b)).find(p => onCanvas(p) && clear(p)) || [x, y];
      return JSON.stringify([spot[0], spot[1], w, h]);
    },

    // Where mark i really is now (measured words, nudges and drags applied): JSON [x, y, w, h], or null if not drawn.
    markBox({ i }) {
      const b = d.session && d.session.drawnBox ? d.session.drawnBox(+i) : null;
      return b ? JSON.stringify(asBox(b)) : null;
    },

    // One frame of a figure's tick functions: `ticks` is [[tick id, seconds since its beat], ...]. Each runs, then the
    // poses set on this figure's parts come back as one Float32Array (poseOf). A tick that throws, or keeps taking more
    // than 8 ms, stops for good.
    tick3d({ stage: figure, ticks, dt }) {
      const live = d.session && d.session.live3d ? d.session.live3d() : null;
      if (!live || !live.ticks) return null;
      const stop = (id, why) => { delete live.ticks[id]; host.log(`tick ${id} stopped: ${why}`); };
      for (const entry of ticks || []) {
        const id = entry[0], run = live.ticks[id];
        if (typeof run !== 'function') continue;
        const started = Date.now();
        global.__mateInTick3d = true;       // pose writes in a tick set this frame (outside one they are timed moves)
        try { run(+entry[1] || 0, +dt || 1 / 60); } catch (e) { stop(id, e && e.message); continue; } finally { global.__mateInTick3d = false; }
        if (Date.now() - started > 8) { d.slowTicks[id] = (d.slowTicks[id] || 0) + 1; if (d.slowTicks[id] > 5) stop(id, 'too slow'); }
      }
      const prefix = figure + 'p', poses = [];
      for (const [id, a] of Object.entries(live.anim)) {
        const n = id.startsWith(prefix) ? +id.slice(prefix.length) : NaN;
        if (n > 0 && a) poses.push(...poseOf(n, a));
      }
      return new Float32Array(poses);
    },

    // A whole program drawn at once on the engine's own schedule (no voice): the lab harness. Returns the engine's report.
    renderWhole({ w, h, width, code, ink }) {
      newStage(w, h, width, ink);
      const handle = {}, codeStart = (pieces || '').length + 1;
      const report = MateDraw.render({ w, h, surface: 'none', code: (pieces || '') + '\n' + code }, d.stage, { width, whole: true, handle, codeStart });
      d.whole = { visibleCount: handle.visibleCount, stateNow: handle.state };
      return JSON.stringify(report);
    },
  };

  // The words a button must keep clear of: a drawn <text>'s box with its nudge and any drag applied (photo captions and
  // button labels excepted).
  function wordsBox(e) {
    if (e.__gone || e.__role === 'photo' || e.__role === 'button' || !e.textContent) return null;
    try {
      const r = e.getBBox(), [nx, ny] = e.__nudge || [0, 0], xf = e.__wrap && e.__wrap.__xf;
      let b = [r.x + nx, r.y + ny, r.width, r.height];
      if (xf) b = [b[0] * xf[0] + xf[1], b[1] * xf[0] + xf[2], b[2] * xf[0], b[3] * xf[0]];
      return b[2] > 0 && b[3] > 0 ? b : null;
    } catch (_) { return null; }
  }
})(this);
