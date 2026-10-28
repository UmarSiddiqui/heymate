// Mate draws: lab engine 1.6.
// The model sends a drawing as data (marks) or as a tiny program that makes marks.
// This file turns marks into hand-drawn SVG: smooth tapered pen strokes, wobbly shapes,
// watercolour washes, handwriting, highlighter and a pen-reveal animation in drawing order.
//
// 1.5 adds (all backwards compatible with 1.4's render / live / runCode / statementEnds):
//   - pieces with anchors: graph() (axes, curves, shifts, crossings, marked points) and timeline()
//   - dashed lines (o.dash)
//   - a layout check for boxes: labelled boxes that pile on each other are warned about and nudged when safe
//   - incremental execution in live(): each new statement runs once instead of re-running the prefix
//   - an optional Web Worker sandbox with a time limit (live(spec, host, {sandbox: 'worker'}))
//   - drawing paced to speech (live(spec, host, {pace: 'speech'})): the strokes after a say() line are
//     released while that line is spoken and spread across it; line times can come from the host.
//   - additive, for voice hosts: L.finishNow() draws everything still waiting right away (the voice carries on),
//     L.placed gives each drawn mark's [start, end] in seconds, and L.timeline.marks[].line is known while drawing.
//
// 1.6 adds live editing (all additive; programs draw exactly as in 1.5, which is kept as engine.v15.js):
//   - parts: every piece of a drawing has an id (p1, p2, ... in program order, named by the program's own comments;
//     every mark is m0, m1, ...), a short description and a box. L.state() is that list as short lines for a model.
//   - edits on the card that is already there, each animated in the engine's style: L.edit({op: 'recolor' | 'restyle' |
//     'move' | 'moveTo' | 'scale' | 'erase' | 'redraw' | 'add' | 'highlight' | 'undo', ...}). A new edit can cut into a
//     running one (L.settle() jumps it to its end). Erasing runs the pen backwards; redraw and add run a code fragment
//     after the program, so its helpers are in scope (in the sandbox when the drawing uses one).
//   - L.pause() / L.resume(): hold the pen after the current stroke (a barge-in) and carry on; nothing is wiped.
(function (global) {
  'use strict';
  const VERSION = '1.6';
  // ReferenceRenderer (2026-10-08): ink is a soft near-black (#1C1E24 read as solid black on the cards); grey is the secondary
  // text colour (subtitles, labels, small numbers, sources)
  const TONES = {
    ink: '#30333A', white: '#FFFFFF', grey: '#7E838D', butter: '#FFD84D', sun: '#FFB930', orange: '#FF9A3C',
    peach: '#FFB59A', coral: '#F2706B', red: '#E5484D', pink: '#F59AB5', lilac: '#A897F5', violet: '#6E5BD8',
    sky: '#5AA8F5', blue: '#1F5FCC', mint: '#7ED6A0', leaf: '#3E9E5C', brown: '#A0673D', tan: '#D9A877', cream: '#FFF3D6'
  };
  const tone = (t, fallback) => TONES[t] || t || fallback || TONES.ink;
  // three-metal (2026-10-13): a figure() model's colour names are the colours real things of that name have, as a photo
  // shows them (painted steel, brick, foliage, water), not Mate's candy ink: the same names read as a toy in 3D. A
  // hex the program gives is used as it is. 2D marks and scene3d() keep TONES.
  const REAL_TONES = {
    ink: '#2C2E33', white: '#E8E6E1', grey: '#8B8E93', butter: '#E0C477', sun: '#D6A83C', orange: '#C9692E',
    peach: '#D8A287', coral: '#C1604F', red: '#A8352D', pink: '#C7848F', lilac: '#9E92C0', violet: '#5D4D90',
    sky: '#8AAFCC', blue: '#2F5689', mint: '#94BCA2', leaf: '#53794A', brown: '#6D4A2F', tan: '#B9946F', cream: '#E4D9C2'
  };
  const realTone = (t, fallback) => REAL_TONES[t] || t || fallback || REAL_TONES.ink;
  // a hex colour mixed toward black by k (0..1); anything else passes through
  const shade = (hex, k) => { const m = /^#?([0-9a-f]{6})$/i.exec(String(hex)); if (!m) return hex; const n = parseInt(m[1], 16);
    const c = v => Math.round(v * (1 - k)).toString(16).padStart(2, '0'); return '#' + c(n >> 16) + c((n >> 8) & 255) + c(n & 255); };
  // ReferenceRenderer (2026-10-09): how hand-drawn Mate's pen is, 0 (ruler-straight) to 1 (the original sketchy wobble).
  // The clean look (0.35) read like a chart tool; back to the original wobble, with the original taper and swell.
  const HAND = 1;
  // ReferenceRenderer (2026-10-19): how long a frame takes to drag open like a selection (the app's spring settles a little after)
  const MARQUEE_DUR = 0.55;
  // one line of written text to the next, as a multiple of the font size (Patrick Hand's tall ascenders need the air)
  const LINE_HEIGHT = 1.3;
  const BRUSH = { pen: { size: 2.8, alpha: 1 }, marker: { size: 8, alpha: 0.9 }, pencil: { size: 1.8, alpha: 0.85 }, brush: { size: 6, alpha: 0.95 } };
  const FONT = {
    // One handwriting for everything Mate draws (Patrick Hand), so headings, card text and notes read as one hand.
    // Titles stay 600 (drawn bold by the renderer, since Patrick Hand has one weight). Barlow (the 2026-10-08 clean
    // look) read too clean and stays bundled only for drawings that name it.
    hand: "'Patrick Hand', cursive", title: "'Patrick Hand', cursive", body: "'Patrick Hand', cursive", mono: "'Patrick Hand', cursive",
    // a small all-caps name for a region of a picture ("THE HILL"), widely spaced
    caps: "'Patrick Hand', cursive",
    // ReferenceRenderer: the Mac's own system font, for the name pills and badges that mark the real screen
    ui: 'system-ui, sans-serif',
    // ReferenceRenderer (2026-10-20): the morning paper's type (headlines, decks, the date line), a classic newspaper serif
    serif: "Georgia, 'Times New Roman', serif"
  };
  // ReferenceRenderer (2026-10-11): Library cards (generative widgets) are set in Barlow, not the handwriting. A card's program
  // sets global.__mateCardType = true before it draws; screen drawings never set it, so they keep Patrick Hand.
  const CARD_FACE = "'Barlow', sans-serif";
  const usesCardType = () => global.__mateCardType === true;
  const faceFor = style => usesCardType() && style !== 'ui' ? CARD_FACE : (FONT[style] || FONT.hand);

  // ---------------------------------------------------------------- seeded noise, so the same drawing always wobbles the same way
  function rng(seed) { let s = 0; for (const c of String(seed)) s = (s * 31 + c.charCodeAt(0)) >>> 0; return () => ((s = (s * 1664525 + 1013904223) >>> 0) / 4294967296); }
  const dist = (a, b) => Math.hypot(b[0] - a[0], b[1] - a[1]);

  // ---------------------------------------------------------------- geometry
  function catmull(pts, closed, seg = 10) {
    if (pts.length < 2) return pts.slice();
    if (pts.length === 2 && !closed) return densify(pts, 12);
    const P = closed ? [pts[pts.length - 1], ...pts, pts[0], pts[1]] : [pts[0], ...pts, pts[pts.length - 1]];
    const out = [];
    for (let i = 1; i < P.length - 2; i++) {
      const [p0, p1, p2, p3] = [P[i - 1], P[i], P[i + 1], P[i + 2]];
      const n = Math.max(2, Math.min(seg * 3, Math.ceil(dist(p1, p2) / 4)));
      for (let s = 0; s < n; s++) {
        const t = s / n, t2 = t * t, t3 = t2 * t;
        out.push([0, 1].map(k => 0.5 * (2 * p1[k] + (-p0[k] + p2[k]) * t + (2 * p0[k] - 5 * p1[k] + 4 * p2[k] - p3[k]) * t2 + (-p0[k] + 3 * p1[k] - 3 * p2[k] + p3[k]) * t3)));
      }
    }
    out.push(closed ? pts[0] : pts[pts.length - 1]);
    return out;
  }
  function densify(pts, step = 6) {
    const out = [pts[0]];
    for (let i = 1; i < pts.length; i++) {
      const a = pts[i - 1], b = pts[i], n = Math.max(1, Math.ceil(dist(a, b) / step));
      for (let s = 1; s <= n; s++) out.push([a[0] + (b[0] - a[0]) * s / n, a[1] + (b[1] - a[1]) * s / n]);
    }
    return out;
  }
  // cut a centreline into hand-drawn dashes
  function dashes(pts, on, off) {
    const d = densify(pts, 2), out = []; let acc = 0, cur = [d[0]], pen = true;
    for (let i = 1; i < d.length; i++) {
      acc += dist(d[i - 1], d[i]);
      if (pen) { cur.push(d[i]); if (acc >= on) { out.push(cur); pen = false; acc = 0; } }
      else if (acc >= off) { pen = true; acc = 0; cur = [d[i]]; }
    }
    if (pen && cur.length > 1) out.push(cur);
    return out;
  }
  // a straight segment drawn by hand bows a little
  // ReferenceRenderer (2026-10-19): bow 'pen' is the old walkthrough's hand: each edge bends once, clearly, to one side
  // (3% of its length, 2 to 7 points, a short edge barely), and with jitter its corners land up to that many points
  // off. The default bow is the paper look's small random bend.
  function handSegments(pts, closed, r, amt = 1, bowStyle, jitter = 0) {
    const unit = +global.__canvasUnitPoints > 0 ? +global.__canvasUnitPoints : 1;
    if (jitter) { pts = pts.map(p => [p[0] + (r() * 2 - 1) * jitter / unit, p[1] + (r() * 2 - 1) * jitter / unit]); }
    const src = closed ? [...pts, pts[0]] : pts, out = [src[0]];
    for (let i = 1; i < src.length; i++) {
      const a = src[i - 1], b = src[i], L = dist(a, b), n = Math.max(2, Math.ceil(L / 5));
      const Lpt = L * unit, penBow = Lpt < 24 ? Lpt * 0.03 : Math.min(Math.max(Lpt * 0.03, 2), 7);
      const bow = bowStyle === 'pen' ? (r() < 0.5 ? -1 : 1) * penBow * (0.6 + 0.4 * r()) / unit * amt
        : (r() - 0.5) * Math.min(3.2, L * 0.03) * amt * HAND, nx = -(b[1] - a[1]) / (L || 1), ny = (b[0] - a[0]) / (L || 1);
      for (let s = 1; s <= n; s++) { const t = s / n, k = Math.sin(Math.PI * t) * bow; out.push([a[0] + (b[0] - a[0]) * t + nx * k, a[1] + (b[1] - a[1]) * t + ny * k]); }
    }
    return out;
  }
  function ellipsePts(cx, cy, rx, ry, rot, r, wobble = 1, overshoot = true) {
    const n = Math.max(28, Math.round((rx + ry) / 2.2)), start = r() * Math.PI * 2, span = Math.PI * 2 * (overshoot ? 1.06 : 1);
    const p1 = r() * 6, p2 = r() * 6, out = [];
    for (let i = 0; i <= n; i++) {
      const a = start + span * i / n, k = 1 + wobble * HAND * (0.018 * Math.sin(a * 2 + p1) + 0.012 * Math.sin(a * 3 + p2)) + (overshoot ? 0.02 * wobble * i / n : 0);
      const x = Math.cos(a) * rx * k, y = Math.sin(a) * ry * k;
      out.push([cx + x * Math.cos(rot) - y * Math.sin(rot), cy + x * Math.sin(rot) + y * Math.cos(rot)]);
    }
    return out;
  }
  // tapered outline around a centreline (a small cousin of perfect-freehand)
  function outline(pts, size, taper = 1) {
    const n = pts.length; if (n < 2) return null;
    // ReferenceRenderer (2026-10-19): taper 0 is the screen pen, the old walkthrough's line: one even width end to end with
    // round ends, no felt-pen swell (Farza missed how sure those marks looked next to the tapered ones).
    if (taper === 0) return evenOutline(pts, size / 2);
    const L = [0]; for (let i = 1; i < n; i++) L.push(L[i - 1] + dist(pts[i - 1], pts[i]));
    const total = L[n - 1] || 1, ramp = Math.min(total * 0.3, size * 5) * taper || 1e-6;
    const left = [], right = [];
    for (let i = 0; i < n; i++) {
      const a = pts[Math.max(0, i - 1)], b = pts[Math.min(n - 1, i + 1)], d = dist(a, b) || 1;
      const nx = -(b[1] - a[1]) / d, ny = (b[0] - a[0]) / d, u = L[i];
      // a light taper into and out of each stroke, and a slight swell along it, like a felt pen
      const press = Math.min(1, 0.35 + 0.65 * Math.min(u, total - u) / ramp);
      const w = size / 2 * press * (0.94 + 0.06 * Math.sin(u / 7));
      left.push([pts[i][0] + nx * w, pts[i][1] + ny * w]); right.push([pts[i][0] - nx * w, pts[i][1] - ny * w]);
    }
    const f = v => v.toFixed(1);
    return 'M' + left.map(p => f(p[0]) + ' ' + f(p[1])).join(' L') + ' L' + right.reverse().map(p => f(p[0]) + ' ' + f(p[1])).join(' L') + ' Z';
  }
  // an even-width outline with round caps around a centreline (half-width w)
  function evenOutline(pts, w) {
    const n = pts.length, left = [], right = [], normal = [];
    for (let i = 0; i < n; i++) {
      const a = pts[Math.max(0, i - 1)], b = pts[Math.min(n - 1, i + 1)], d = dist(a, b) || 1;
      const nx = -(b[1] - a[1]) / d, ny = (b[0] - a[0]) / d;
      normal.push([nx, ny]);
      left.push([pts[i][0] + nx * w, pts[i][1] + ny * w]); right.push([pts[i][0] - nx * w, pts[i][1] - ny * w]);
    }
    // half a circle around an end, from one side of the line to the other, through the outside of the end
    const cap = (p, nrm, from) => { const out = [], a0 = Math.atan2(nrm[1], nrm[0]) + from; for (let k = 1; k < 8; k++) { const a = a0 - Math.PI * k / 8; out.push([p[0] + Math.cos(a) * w, p[1] + Math.sin(a) * w]); } return out; };
    const ring = [...left, ...cap(pts[n - 1], normal[n - 1], 0), ...right.reverse(), ...cap(pts[0], normal[0], Math.PI)];
    const f = v => v.toFixed(1);
    return 'M' + ring.map(p => f(p[0]) + ' ' + f(p[1])).join(' L') + ' Z';
  }
  const poly = pts => 'M' + pts.map(p => p[0].toFixed(1) + ' ' + p[1].toFixed(1)).join(' L');
  const plen = pts => pts.reduce((s, p, i) => i ? s + dist(pts[i - 1], p) : 0, 0);

  function samplePath(d, n = 120) {
    const el = document.createElementNS('http://www.w3.org/2000/svg', 'path'); el.setAttribute('d', d);
    const tmp = document.getElementById('__probe'); tmp.appendChild(el);
    const L = el.getTotalLength(), out = [];
    for (let i = 0; i <= n; i++) { const p = el.getPointAtLength(L * i / n); out.push([p.x, p.y]); }
    el.remove(); return out;
  }

  // ================================================================ the program runner
  // Everything in makeRunner is self-contained (no outer variables), so the same source also runs inside a Web Worker.
  function makeRunner(TONE_NAMES) {
    const LIMIT = 2000;
    // (ReferenceRenderer: the same rule as 1.6, without slicing the rest of the program at every candidate end, which made it
    // quadratic: 5 ms per call on a 12 KB program with Mate's pieces, 200 ms for attribute())
    const WS = ch => ch === ' ' || ch === '\t' || ch === '\n' || ch === '\r' || /\s/.test(ch);
    function statementEnds(code, start = 0) {
      const out = []; let depth = 0, i = start; const n = code.length;
      while (i < n) {
        const c = code[i];
        if (code.startsWith('//', i)) { const j = code.indexOf('\n', i); i = j < 0 ? n : j; continue; }
        if (code.startsWith('/*', i)) { const j = code.indexOf('*/', i + 2); i = j < 0 ? n : j + 2; continue; }
        if (c === '"' || c === "'" || c === '`') { let j = i + 1; while (j < n && code[j] !== c) j += code[j] === '\\' ? 2 : 1; if (j >= n) break; i = j + 1; continue; }
        if ('([{'.includes(c)) depth++; else if (')]}'.includes(c)) depth--;
        if (depth === 0 && ';\n}'.includes(c)) {
          let j = i + 1; while (j < n && (code[j] === ' ' || code[j] === '\t')) j++;       // the next code: nxt = code.slice(j)
          let bs = start, be = i + 1; while (bs < be && WS(code[bs])) bs++; while (be > bs && WS(code[be - 1])) be--;   // body = code.slice(bs, be)
          if (j < n && be > bs) {
            let te = be; if (code[te - 1] === ';') te--; while (te > bs && WS(code[te - 1])) te--;
            const lastc = te > bs ? code[te - 1] : '';
            if (!'.?:+-*/&|,)]'.includes(code[j]) && !(lastc && '=+-*/&|,([{:?'.includes(lastc)) && !(c === '}' && code.startsWith('else', j))) { out.push(i + 1); start = i + 1; }
          }
        }
        i++;
      }
      return out;
    }
    // A stream sends its whole prefix every time. Keep the boundaries already scanned, but recheck the last one:
    // a trailing "} e" can still become "} else". Earlier boundaries cannot change when more code is appended.
    function statementScanner() {
      let previous = '', ends = [];
      return code => {
        if (code === previous) return ends;
        const keep = code.startsWith(previous) ? Math.max(0, ends.length - 1) : 0;
        const start = keep ? ends[keep - 1] : 0;
        ends = ends.slice(0, keep).concat(statementEnds(code, start));
        previous = code;
        return ends;
      };
    }
    const textW = (s, size, style) => String(s).length * (size || 20) * (style === 'title' ? 0.56 : 0.47);
    function niceTicks(a, b, n) {
      n = n || 5; const lo = Math.min(a, b), hi = Math.max(a, b), span = hi - lo || 1, mag = Math.pow(10, Math.floor(Math.log10(span / n)));
      let st = mag; for (const k of [1, 2, 2.5, 5, 10]) { st = k * mag; if (span / st <= n) break; }
      const out = []; for (let v = Math.ceil(lo / st - 1e-9) * st; v <= hi + 1e-9; v += st) out.push(+v.toFixed(10));
      return out;
    }
    // big tick values read short ("80k", "1.5M"), so a $ axis doesn't run past the card's edge
    const short = (v, d, u) => String(+(v / d).toFixed(Math.abs(v / d) < 10 && v % d ? 1 : 0)) + u;
    const fmt = v => Math.abs(v) >= 1e6 ? short(v, 1e6, 'M') : Math.abs(v) >= 10000 ? short(v, 1000, 'k') : Number.isInteger(v) || Math.abs(v) >= 100 ? String(Math.round(v)) : String(+v.toFixed(2));
    const finite = p => Array.isArray(p) && isFinite(p[0]) && isFinite(p[1]);

    // ReferenceRenderer: a web link written into card text (a web-search citation "([bestbuy.com](https://…))", a long bare
    // URL) is shown as its short name, and the text keeps the link (m.link) for the app to make clickable: a product
    // card's whole listing URL ran far off the card (2026-10-07).
    const LONG_URL = 32;
    const hostOf = url => url.replace(/^https?:\/\//i, '').split(/[/?#]/)[0].replace(/^www\./i, '');
    function linkedText(value) {
      if (typeof value !== 'string' || !/https?:\/\//i.test(value)) return { text: value };
      let link = null;
      let shown = value.replace(/\[([^\]\n]{1,80})\]\((https?:\/\/[^\s)]+)\)/gi, (_, label, url) => { link = link || url; return label; });
      shown = shown.replace(/https?:\/\/[^\s)\]]+/gi, url => {
        link = link || url;
        if (url.length <= LONG_URL) return url;
        const path = url.replace(/^https?:\/\/[^/?#]+/i, '');
        return hostOf(url) + (path.length > 1 ? '/…' : '');
      });
      return link ? { text: shown, link } : { text: value };
    }

    function makeApi(w, h, sink) {
      let curStep = 1, cue = null, curTurn = 0;
      const marks = sink.marks, says = sink.says;
      const warn = s => { if (sink.warnings.length < 40 && !sink.warnings.includes(s)) sink.warnings.push(s); };
      const push = (m, o) => {
        if (marks.length >= LIMIT) throw new Error('too many marks (the limit is ' + LIMIT + ')');
        if (sink.deadline && Date.now() > sink.deadline) throw new Error('the program ran too long');
        const mk = Object.assign(m, o && typeof o === 'object' ? o : {});
        if (mk.step == null) mk.step = curStep;
        if (curTurn && mk.turn == null) mk.turn = curTurn;
        if (cue && !mk.say && mk.do !== 'edit') { mk.say = cue; cue = null; }
        marks.push(mk); return mk;
      };
      const api = {
        // ReferenceRenderer: set by Mate's pieces when the app draws windows: a 3D figure that would stand on paper stands in
        // a window instead (the pieces draw it: __card3d(x, y, w, h, o))
        __card3d: null,
        W: w, H: h, PI: Math.PI, sin: Math.sin, cos: Math.cos, abs: Math.abs, min: Math.min, max: Math.max, sqrt: Math.sqrt, round: Math.round,
        // ReferenceRenderer (2026-10-12): the rest of Math's deterministic functions too; a car engine answer called floor()
        // bare, as 3D code often does, and stopped there.
        floor: Math.floor, ceil: Math.ceil, trunc: Math.trunc, sign: Math.sign, pow: Math.pow, exp: Math.exp, log: Math.log,
        log2: Math.log2, log10: Math.log10, hypot: Math.hypot, atan2: Math.atan2, atan: Math.atan, asin: Math.asin, acos: Math.acos,
        tan: Math.tan, sinh: Math.sinh, cosh: Math.cosh, tanh: Math.tanh, cbrt: Math.cbrt,
        range: n => Array.from({ length: n }, (_, i) => i), lerp: (a, b, t) => a + (b - a) * t,
        polar: (cx, cy, r, a) => [cx + Math.cos(a) * r, cy + Math.sin(a) * r],
        add: (a, b) => [a[0] + b[0], a[1] + b[1]], sub: (a, b) => [a[0] - b[0], a[1] - b[1]], mul: (a, k) => [a[0] * k, a[1] * k],
        mid: (a, b) => [(a[0] + b[0]) / 2, (a[1] + b[1]) / 2], along: (a, b, t) => [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t],
        dist: (a, b) => Math.hypot(b[0] - a[0], b[1] - a[1]), angle: (a, b) => Math.atan2(b[1] - a[1], b[0] - a[0]),
        perp: (a, b) => { const d = Math.hypot(b[0] - a[0], b[1] - a[1]) || 1; return [-(b[1] - a[1]) / d, (b[0] - a[0]) / d]; },
        rotate: (p, c, a) => [c[0] + (p[0] - c[0]) * Math.cos(a) - (p[1] - c[1]) * Math.sin(a), c[1] + (p[0] - c[0]) * Math.sin(a) + (p[1] - c[1]) * Math.cos(a)],
        step: n => { curStep = n; }, say: s => { cue = s; says.push(curTurn ? { text: String(s), at: marks.length, step: curStep, turn: curTurn } : { text: String(s), at: marks.length, step: curStep }); },
        // One brain: seen("…") (what the screen shows them doing) and noted("…") (a fact about the user) are read
        // from the program by the Worker and the app; they draw nothing and say nothing.
        seen: () => {}, noted: () => {},
        line: (pts, o) => push({ do: 'line', pts }, o), curve: (pts, o) => push({ do: 'line', pts, smooth: true }, o),
        circle: (x, y, r, o) => push({ do: 'circle', at: [x, y], r }, o), ellipse: (x, y, rx, ry, o) => push({ do: 'ellipse', at: [x, y], rx, ry }, o),
        rect: (x, y, w_, h_, o) => push({ do: 'rect', at: [x, y], w: w_, h: h_ }, o), poly: (pts, o) => push({ do: 'poly', pts }, o),
        path: (d, o) => push({ do: 'path', d }, o), text: (x, y, text, o) => push(Object.assign({ do: 'text', at: [x, y] }, linkedText(text)), o),
        arrow: (pts, o) => push({ do: 'arrow', pts }, o), highlight: (x, y, w_, h_, o) => push({ do: 'highlight', at: [x, y], w: w_, h: h_ }, o),
        dot: (x, y, r, o) => push({ do: 'dot', at: [x, y], r }, o),
        // ReferenceRenderer: a real photo found by the app's image search for `o.query`, filling that box
        image: (x, y, w_, h_, o) => push({ do: 'image', at: [x, y], w: w_, h: h_ }, o),
        // ReferenceRenderer: a little window (title bar with its three buttons, a board to draw on) the app paints for that whole
        // box; Mate's pieces (paper, receipt, clipping) call it, never a program directly
        __window: (x, y, w_, h_, o) => push({ do: 'window', at: [x, y], w: w_, h: h_ }, o), molecule: (smiles, x, y, w_, h_, o) => push({ do: 'molecule', smiles, at: [x, y], w: w_, h: h_ }, o)
      };
      // ReferenceRenderer (2026-10-09): rough [x, y, w, h] boxes of the ink drawn so far (shapes, words, photos; not the cards
      // they sit on), so a piece placed later (a button) can step off them instead of landing on the drawing.
      api.__inkBoxes = () => {
        const out = [];
        for (const m of marks) {
          if (!m || m.do === 'window' || m.do === 'edit' || /3d$/.test(m.do || '') && m.do !== 'stage3d') continue;
          if (m.role === 'paper' || m.role === 'button' || m.role === 'handoff' || m.role === 'open') continue;
          if (m.do === 'dot' && m.fillAlpha === 0 && (+m.r || 0) <= 0.5) continue;
          const pad = (+m.size || 3) / 2, at = Array.isArray(m.at) ? m.at : null;
          let b = null;
          if (Array.isArray(m.pts) && m.pts.length) {
            const P = m.pts.filter(q => Array.isArray(q) && isFinite(q[0]) && isFinite(q[1]));
            if (P.length) { const xs = P.map(q => q[0]), ys = P.map(q => q[1]); b = [Math.min(...xs) - pad, Math.min(...ys) - pad, Math.max(...xs) - Math.min(...xs) + 2 * pad, Math.max(...ys) - Math.min(...ys) + 2 * pad]; }
          } else if (at) {
            if (m.do === 'circle' || m.do === 'dot') { const r = (+m.r || 3) + pad; b = [at[0] - r, at[1] - r, 2 * r, 2 * r]; }
            else if (m.do === 'ellipse') { const rx = (+m.rx || 0) + pad, ry = (+m.ry || 0) + pad; b = [at[0] - rx, at[1] - ry, 2 * rx, 2 * ry]; }
            else if (m.do === 'text') {
              const size = +m.size || 20, ls = String(m.text == null ? '' : m.text).split('\n'), tw = Math.max(...ls.map(t => t.length)) * size * 0.5;
              const ww = m.fit ? Math.min(+m.fit[0] || tw, tw) : tw;
              b = [at[0] - (m.anchor === 'middle' ? ww / 2 : m.anchor === 'end' ? ww : 0), m.top ? at[1] - size * 0.8 : at[1] - size * 0.8, ww, size * 1.05 * ls.length];
            } else if (isFinite(+m.w) && isFinite(+m.h)) b = [Math.min(at[0], at[0] + +m.w), Math.min(at[1], at[1] + +m.h), Math.abs(+m.w), Math.abs(+m.h)];
          }
          if (b && b.every(v => isFinite(v)) && b[2] > 0 && b[3] > 0) out.push(b);
        }
        return out;
      };

      // ------------------------------------------------ 3D: an object standing on the screen (ReferenceRenderer)
      // scene3d(x, y, w, h, build, o) stands a 3D object in that rectangle of the screen (pixels, like paper). Every part
      // is its own mark, so parts grow in with the pen, beat by beat, and stage.label() writes a word in Mate's ink that
      // follows a point of the object. The native canvas draws the stage with Metal among the 2D marks. The part
      // ops are the ones the Metal renderer (native Metal renderer) reads.
      let stageCount = 0;
      // Every 3D figure's rectangle: Mate's paper pieces step aside from them (clearOfFigures).
      const stageBoxes = [];
      api.clearOfFigures = (px, py, pw, ph) => {
        const gap = 10, overlaps = (ax, ay) => stageBoxes.some(b => ax < b[0] + b[2] + gap && ax + pw + gap > b[0] && ay < b[1] + b[3] + gap && ay + ph + gap > b[1]);
        if (!overlaps(px, py)) return [px, py];
        const fits = (ax, ay) => ax >= 4 && ay >= 4 && ax + pw <= w - 4 && ay + ph <= h - 4 && !overlaps(ax, ay);
        const options = [];
        for (const b of stageBoxes) {
          options.push([b[0] + b[2] + gap, py], [b[0] - pw - gap, py], [px, b[1] + b[3] + gap], [px, b[1] - ph - gap]);
          options.push([b[0] + b[2] + gap, Math.min(Math.max(4, py), h - ph - 4)], [b[0] - pw - gap, Math.min(Math.max(4, py), h - ph - 4)]);
        }
        const busyHere = typeof global.__busyFor === 'function' ? (ax, ay) => global.__busyFor(ax, ay, pw, ph) : () => 0;
        const limit = busyHere(px, py) + 0.006;
        const free = options.filter(([ax, ay]) => fits(ax, ay) && busyHere(ax, ay) <= limit)
          .sort((a, b2) => Math.hypot(a[0] - px, a[1] - py) - Math.hypot(b2[0] - px, b2[1] - py));
        if (!free.length) { warn('a paper piece covers a 3D figure (no calm spot beside it)'); return [px, py]; }
        warn('moved a paper piece off a 3D figure');
        return free[0];
      };
      const MATERIAL_KEYS = ['color', 'roughness', 'metalness', 'emissive', 'emissiveIntensity', 'opacity', 'double', 'flat', 'bands', 'colors', 'glow'];
      const fin = v => typeof v === 'number' && isFinite(v);
      const v3 = (v, fallback) => Array.isArray(v) && v.length >= 3 && fin(v[0]) && fin(v[1]) && fin(v[2]) ? [v[0], v[1], v[2]] : fallback;
      // ReferenceRenderer (2026-10-09): models write an axis as 'x' or '-z' as often as [1, 0, 0]; v3 dropped those to the
      // default [0, 1, 0], so a jet engine's fan or a plane's propeller swung round the vertical instead of turning.
      const axis3 = (v, fallback) => {
        if (typeof v === 'string') { const m = /^\s*([+-]?)\s*([xyz])\s*$/i.exec(v); if (m) { const a = [0, 0, 0]; a['xyz'.indexOf(m[2].toLowerCase())] = m[1] === '-' ? -1 : 1; return a; } }
        return v3(v, fallback);
      };
      const pickKeys = (object, keys) => { const out = {}; if (object && typeof object === 'object') for (const k of keys) if (object[k] !== undefined) out[k] = object[k]; return out; };
      const r3 = v => Math.round(v * 1000) / 1000;
      // A part's colours are Mate's colours, as in 2D: 'butter', 'cream', 'yellow' (sun), 'green' (leaf) are its tones.
      const colorLikeMate = c => typeof c === 'string' ? tone(normColor(c)) : c;
      const colorsLikeMate = material => {
        for (const k of ['color', 'emissive']) if (material[k] != null) material[k] = colorLikeMate(material[k]);
        for (const k of ['bands', 'colors']) if (Array.isArray(material[k])) material[k] = material[k].map(colorLikeMate);
        return material;
      };
      // figure(): the same names in real colours (REAL_TONES).
      const colorLikeReal = c => typeof c === 'string' ? realTone(normColor(c)) : c;
      const colorsLikeReal = material => {
        if (material.color != null) material.color = colorLikeReal(material.color);
        if (material.emissive != null) material.emissive = colorLikeMate(material.emissive);   // light stays vivid
        for (const k of ['bands', 'colors']) if (Array.isArray(material[k])) material[k] = material[k].map(colorLikeReal);
        return material;
      };
      // The window a figure's rectangle is placed on (most of the rectangle inside it), the smallest when cards overlap.
      const hostCardFor = (x, y, w_, h_) => {
        let best = null;
        for (const m of marks) {
          if (!m || m.do !== 'window' || m.__erased || !Array.isArray(m.inner) || !Array.isArray(m.at)) continue;
          const ow = Math.min(x + w_, m.at[0] + m.w) - Math.max(x, m.at[0]), oh = Math.min(y + h_, m.at[1] + m.h) - Math.max(y, m.at[1]);
          if (ow <= 0 || oh <= 0 || ow * oh < 0.6 * w_ * h_) continue;
          if (!best || m.w * m.h < best.w * best.h) best = m;
        }
        return best;
      };
      // Stands a figure's stage in its rectangle (on paper, on a card the program drew, or floating) and pushes its
      // stage3d mark: shared by scene3d() and figure(), so both place a figure the same way. `look` marks a figure()
      // stage (absent for scene3d, whose marks stay exactly as they were).
      const standStage = (x, y, w_, h_, o, look) => {
        const sid = 'st' + (++stageCount);
        // The rectangle is the whole figure: the object framed in its middle, its labels in the margins beside it. On busy
        // screen (text, controls) the figure stands on a card of Mate's paper and everything on it is in paper ink; on
        // calm space it floats, in the ink that reads there.
        const pad = 10;
        const card = [Math.max(4, x - pad), Math.max(4, y - pad), 0, 0];
        card[2] = Math.min(w - 4, x + w_ + pad) - card[0]; card[3] = Math.min(h - 4, y + h_ + pad) - card[1];
        // Words or controls under the figure (in 8% of its 64-pixel tiles or more): it stands on paper. A few words read
        // through a large calm area, so the average misses them; tiles do not.
        const busyAt = (bx, by, bw, bh) => typeof global.__busyFor === 'function' ? global.__busyFor(bx, by, bw, bh) : 0;
        let tiles = 0, busyTiles = 0;
        for (let ty = y; ty < y + h_; ty += 64) for (let tx = x; tx < x + w_; tx += 64) {
          tiles++; if (busyAt(tx, ty, Math.min(64, x + w_ - tx), Math.min(64, y + h_ - ty)) > 0.02) busyTiles++;
        }
        // ReferenceRenderer (2026-10-10, Nilesh: one kind of card): a figure placed on a card the program drew (paper()) stands on
        // that card like any other picture, with the card's heading, words and sources around it, and the card's board
        // turns plain under it. Before, it drew a second window inside that card, and a figure on its own card had no
        // room for words, so the model put a second card over it.
        // ReferenceRenderer (2026-10-22, Farza): in the app's Stream mode a figure always floats with a clear background: no card
        // of its own and none it was placed on, whatever is under it.
        const floats = typeof global.__figuresFloat === 'function' && global.__figuresFloat() === true;
        const onCard = floats ? null : hostCardFor(x, y, w_, h_);
        if (onCard) onCard.board = 'plain';
        const busy = !floats && !onCard && (o.card === true || (o.card !== false && tiles > 0 && busyTiles / tiles >= 0.08));
        stageBoxes.push([x, y, w_, h_]);
        // ReferenceRenderer (2026-10-08): its card is one of Mate's windows when the app draws them (behind the figure, before
        // it); the stage then draws no paper of its own
        const windowed = busy && typeof api.__card3d === 'function';
        if (windowed) api.__card3d(x, y, w_, h_, o);
        // The stage draws the paper itself (Mate's sheet, shadow and tape), hugging the object and its labels
        // inside `card` as they arrive, so it is never mostly empty and goes wherever the figure goes.
        const ink = busy || onCard ? TONES.ink : typeof global.__inkFor === 'function' ? global.__inkFor(x, y, w_, h_) : '#FFFFFF';
        // ReferenceRenderer (2026-10-09, Nilesh: a figure sitting still doesn't feel 3D): every figure turns on its own, never
        // still (a program's spin 0 or a crawl is raised) and livelier than the old 0.3 (about 80 s a turn).
        const stageMark = push({ do: 'stage3d', id: sid, at: [x, y], w: w_, h: h_, ink, card: busy && !windowed ? card : null, cardWindow: onCard ? onCard.inner : undefined, camera: { tilt: fin(o.tilt) ? Math.max(-80, Math.min(80, o.tilt)) : 15, fov: fin(o.fov) ? o.fov : 35, spin: fin(o.spin) ? Math.min(2, Math.max(0.5, o.spin)) : 0.7 } });
        if (look) stageMark.look = look;
        return { sid, ink };
      };
      api.scene3d = (x, y, w_, h_, build, o) => {
        o = o || {};
        if (![x, y, w_, h_].every(fin) || w_ < 24 || h_ < 24) { warn('scene3d() needs x, y, width and height in pixels'); return null; }
        const { sid, ink } = standStage(x, y, w_, h_, o);
        let partCount = 0, labelCount = 0, currentParent = null;
        const motion = (target, kind, fields) => push({ do: 'motion3d', stage: sid, op: Object.assign({ target: target.id, kind }, fields) });
        const handle = m => ({
          id: m.id, kind: 'part',
          spin(op) { op = op || {}; motion(m, 'spin', { axis: axis3(op.axis, [0, 1, 0]), period: fin(op.period) ? op.period : 6 }); return this; },
          bob(op) { op = op || {}; motion(m, 'bob', { axis: axis3(op.axis, [0, 1, 0]), amount: fin(op.amount) ? op.amount : 0.1, period: fin(op.period) ? op.period : 3 }); return this; },
          orbit(op) { op = op || {}; motion(m, 'orbit', { axis: axis3(op.axis, [0, 1, 0]), center: v3(op.center, [0, 0, 0]), period: fin(op.period) ? op.period : 8 }); return this; },
          path(points, op) {
            op = op || {}; const pts = (points || []).map(p => v3(p, null)).filter(Boolean), once = op.once === true;
            // ReferenceRenderer: { once: true } travels the path once and stays at its end (a rocket lifting off).
            if (pts.length >= 2) motion(m, 'path', Object.assign({ points: pts, closed: !once && op.closed !== false, period: fin(op.period) ? op.period : 6 }, once ? { once: true } : {}));
            return this;
          },
          // ReferenceRenderer: swells and shrinks back (a heartbeat, breathing): amount 0.08 is 8% bigger at its fullest.
          pulse(op) { op = op || {}; motion(m, 'pulse', { amount: fin(op.amount) ? Math.max(-0.5, Math.min(0.5, op.amount)) : 0.08, period: fin(op.period) ? op.period : 1 }); return this; },
        });
        const part = (kind, params) => {
          const p = Object.assign({}, params);
          const m = { do: 'part3d', id: sid + 'p' + (++partCount), stage: sid, kind, pos: v3(p.at, [0, 0, 0]), rotate3: v3(p.rotate, [0, 0, 0]),
            scale3: fin(p.scale) ? p.scale : 1, material: colorsLikeMate(pickKeys(p, MATERIAL_KEYS)), parent: (p.parent && p.parent.id) || currentParent };
          for (const k of ['at', 'rotate', 'scale', 'parent'].concat(MATERIAL_KEYS)) delete p[k];
          m.params = p;
          push(m);
          return handle(m);
        };
        const s = {
          id: sid, kind: 'stage', box: [x, y, w_, h_],
          sphere: op => part('sphere', Object.assign({ r: 1 }, op)),
          box: op => part('box', Object.assign({ size: [1, 1, 1], radius: 0 }, op)),
          cylinder: op => part('cylinder', Object.assign({ r: 0.5, h: 1 }, op)),
          cone: op => part('cone', Object.assign({ r: 0.5, h: 1 }, op)),
          torus: op => part('torus', Object.assign({ r: 1, tube: 0.25 }, op)),
          ring: op => part('ring', Object.assign({ inner: 1, outer: 1.5 }, op)),
          capsule: op => part('capsule', Object.assign({ r: 0.3, h: 1 }, op)),
          tube: (points, op) => part('tube', Object.assign({ r: 0.08, closed: false }, op, { points: (points || []).map(p => v3(p, null)).filter(Boolean) })),
          lathe: (profile, op) => part('lathe', Object.assign({}, op, { profile: (profile || []).filter(p => Array.isArray(p) && fin(p[0]) && fin(p[1])) })),
          extrude: (d, op) => part('extrude', Object.assign({ depth: 0.3, unit: 0.01 }, op, { d: String(d || '') })),
          surface: (fn, op) => {
            op = op || {};
            const segments = Math.max(4, Math.min(160, op.segments || 80)), rows = Math.max(2, Math.min(80, op.rows || 16)), u = op.u || [0, 1], v = op.v || [0, 1], grid = [];
            try { for (let j = 0; j <= rows; j++) { const row = []; for (let i = 0; i <= segments; i++) row.push(v3(fn(u[0] + (u[1] - u[0]) * i / segments, v[0] + (v[1] - v[0]) * j / rows), [0, 0, 0]).map(r3)); grid.push(row); } }
            catch (e) { warn('surface() function failed: ' + e.message); return null; }
            const rest = Object.assign({}, op); delete rest.segments; delete rest.rows; delete rest.u; delete rest.v;
            return part('surface', Object.assign(rest, { grid }));
          },
          group: (fn, op) => {
            const g = part('group', Object.assign({}, op));
            if (typeof fn === 'function') { const saved = currentParent; currentParent = g.id; try { fn(s); } finally { currentParent = saved; } }
            return g;
          },
          // ReferenceRenderer: turn (degrees) shows it from another side: 180 its back, 90 and -90 its sides.
          camera: op => { op = op || {}; push({ do: 'camera3d', stage: sid, op: { tilt: fin(op.tilt) ? Math.max(-80, Math.min(80, op.tilt)) : undefined, fov: fin(op.fov) ? op.fov : undefined, spin: fin(op.spin) ? op.spin : undefined, target: v3(op.target, undefined), turn: fin(op.turn) ? Math.max(-180, Math.min(180, op.turn)) : undefined } }); },
          label: (point, text, op) => {
            op = op || {};
            const t = String(text == null ? '' : text).trim(); if (!t) return null;
            return push({ do: 'label3d', id: sid + 'l' + (++labelCount), stage: sid, point: point && point.id ? null : v3(point, [0, 0, 0]), follow: point && point.id ? point.id : null,
              text: t.slice(0, 60), side: op.side === 'left' || op.side === 'right' ? op.side : null, size: fin(op.size) ? Math.max(15, Math.min(28, op.size)) : 19, tone: op.tone || ink });
          },
          // ReferenceRenderer: build(fn, { parent: part }) puts everything it builds onto that part (it moves with it).
          build: (fn, op) => {
            if (typeof fn !== 'function') return s;
            const saved = currentParent;
            if (op && op.parent && op.parent.id) currentParent = op.parent.id;
            try { fn(s); } finally { currentParent = saved; }
            return s;
          },
          // ReferenceRenderer: a part made earlier (another turn, another build()), by its id on the card: 'st1p3' (or 'p3', 3).
          part: id => { const t = String(id == null ? '' : id).trim(); const n = /^(?:st\d+)?p?(\d+)$/.exec(t); return n ? handle({ id: sid + 'p' + n[1] }) : null; },
        };
        if (typeof build === 'function') build(s);
        return s;
      };

      // ------------------------------------------------ figure(): a 3D model built one part per statement (three-metal)
      // const f = figure(x, y, w, h, o) stands a figure like scene3d() (same placement, paper and labels) and returns it;
      // every part is then its own statement (const piston = f.cyl({ r, h, at, mat: 'steel' })), so each one draws the
      // moment its statement ends instead of waiting for a whole build callback. Its shapes are three.js's, built by the
      // app's 3D kernel (mate-three-parts.js) from the recipe each part mark carries; f.tick((t) => ...) moves parts
      // every frame (piston.pos = [...], crank.rot = [...]). Parts are drawn in studio light ("look: studio": lit
      // materials) where scene3d()'s are illustrated.
      const FIGURE_PARTS = ['box', 'cyl', 'cylinder', 'cone', 'tube', 'lathe', 'sphere', 'torus', 'capsule', 'pipe', 'spring', 'gear', 'extrude', 'blob', 'poly', 'arrow'];
      // ReferenceRenderer (2026-10-12, Blender's tools): mirror, copies, around and cut place the part (and its copies) rather
      // than shape it, so they stay out of its recipe.
      const FIGURE_PLACE_KEYS = ['at', 'pos', 'rot', 'rotate', 'scale', 'parent', 'name', 'mat', 'from', 'to', 'mirror', 'copies', 'around', 'cut'];
      // Rotations as quaternions [x, y, z, w], for copies turned round an axis: three.js's Euler 'XYZ' both ways.
      const quatFromEuler3 = degrees => {
        const [x, y, z] = degrees.map(d => d * Math.PI / 360);
        const c1 = Math.cos(x), c2 = Math.cos(y), c3 = Math.cos(z), s1 = Math.sin(x), s2 = Math.sin(y), s3 = Math.sin(z);
        return [s1 * c2 * c3 + c1 * s2 * s3, c1 * s2 * c3 - s1 * c2 * s3, c1 * c2 * s3 + s1 * s2 * c3, c1 * c2 * c3 - s1 * s2 * s3];
      };
      const quatAxisAngle = (axis, degrees) => {
        const length = Math.hypot(axis[0], axis[1], axis[2]) || 1, half = degrees * Math.PI / 360, s = Math.sin(half);
        return [axis[0] / length * s, axis[1] / length * s, axis[2] / length * s, Math.cos(half)];
      };
      const quatMultiply = (a, b) => [
        a[3] * b[0] + a[0] * b[3] + a[1] * b[2] - a[2] * b[1], a[3] * b[1] - a[0] * b[2] + a[1] * b[3] + a[2] * b[0],
        a[3] * b[2] + a[0] * b[1] - a[1] * b[0] + a[2] * b[3], a[3] * b[3] - a[0] * b[0] - a[1] * b[1] - a[2] * b[2]];
      const euler3FromQuat = ([x, y, z, w]) => {
        const m11 = 1 - 2 * (y * y + z * z), m12 = 2 * (x * y - w * z), m13 = 2 * (x * z + w * y);
        const m22 = 1 - 2 * (x * x + z * z), m23 = 2 * (y * z - w * x), m32 = 2 * (y * z + w * x), m33 = 1 - 2 * (x * x + y * y);
        const ry = Math.asin(Math.max(-1, Math.min(1, m13)));
        const [rx, rz] = Math.abs(m13) < 0.9999999 ? [Math.atan2(-m23, m33), Math.atan2(-m12, m11)] : [Math.atan2(m32, m22), 0];
        return [rx, ry, rz].map(r => r3(r * 180 / Math.PI));
      };
      const rotateAbout = (q, p) => {
        const [x, y, z, w] = q, [px, py, pz] = p;
        const ix = w * px + y * pz - z * py, iy = w * py + z * px - x * pz, iz = w * pz + x * py - y * px, iw = -x * px - y * py - z * pz;
        return [ix * w + iw * -x + iy * -z - iz * -y, iy * w + iw * -y + iz * -x - ix * -z, iz * w + iw * -z + ix * -y - iy * -x];
      };
      // The way a part points before any axis or rot: most stand along y (a torus lies flat, its hole along y); a gear's
      // axle and an extrusion's depth run along z.
      const FIGURE_STANDS_ALONG = { gear: [0, 0, 1], extrude: [0, 0, 1] };
      const FIGURE_ROUND_PARTS = ['cyl', 'cylinder', 'cone', 'tube', 'lathe', 'sphere', 'torus', 'capsule', 'spring', 'gear', 'poly'];
      // A rot [x, y, z] in degrees applied to a vector the way the stage turns a part (three.js Euler 'XYZ': Rx · Ry · Rz).
      const turn3 = (degrees, v) => {
        const [ax, ay, az] = degrees.map(d => d * Math.PI / 180);
        let [x, y, z] = v;
        [x, y] = [x * Math.cos(az) - y * Math.sin(az), x * Math.sin(az) + y * Math.cos(az)];
        [x, z] = [x * Math.cos(ay) + z * Math.sin(ay), -x * Math.sin(ay) + z * Math.cos(ay)];
        [y, z] = [y * Math.cos(ax) - z * Math.sin(ax), y * Math.sin(ax) + z * Math.cos(ax)];
        return [x, y, z];
      };
      const FIGURE_MATERIALS = ['steel', 'alu', 'aluminum', 'aluminium', 'titanium', 'chrome', 'brass', 'copper', 'gold', 'iron', 'black', 'rubber', 'glass', 'water',
        'wood', 'ceramic', 'paper', 'gloss', 'paint', 'plastic', 'soft', 'matte', 'metal', 'glow'];
      // A recipe as canonical JSON (sorted keys, numbers to 4 decimals, no functions): the 3D kernel's cache key, so the
      // same part (twenty bolts, a re-run of the program) is built once.
      const canonical3 = v => {
        if (Array.isArray(v)) return v.map(canonical3).map(x => x === undefined ? null : x);
        if (v && typeof v === 'object') { const o = {}; for (const k of Object.keys(v).sort()) { const c = canonical3(v[k]); if (c !== undefined) o[k] = c; } return o; }
        if (typeof v === 'number') return isFinite(v) ? Math.round(v * 1e4) / 1e4 : undefined;
        return typeof v === 'string' || typeof v === 'boolean' ? v : undefined;
      };
      // The variable a figure part is assigned to (const piston = f.cyl(...)) names it: transform() writes
      // __name3d("piston") before such a statement, and the next part mark takes the name if nothing else came first.
      let pendingName3 = null;
      api.__name3d = name => { pendingName3 = typeof name === 'string' && name ? { name, at: marks.length } : null; };
      let figureTicks = 0;
      api.figure = (x, y, w_, h_, o) => {
        if (x && typeof x === 'object' && !Array.isArray(x)) {             // figure({ ... }) with no rectangle: a calm default
          o = x; x = Math.round(w * 0.5); y = Math.round(h * 0.14); w_ = Math.round(Math.min(620, w * 0.44)); h_ = Math.round(Math.min(480, h * 0.66));
          warn('figure() needs x, y, width and height in pixels; placed it on the right');
        }
        o = o || {};
        if (![x, y, w_, h_].every(fin) || w_ < 24 || h_ < 24) { warn('figure() needs x, y, width and height in pixels'); return null; }
        const { sid, ink } = standStage(x, y, w_, h_, o, 'studio');
        let partCount = 0, labelCount = 0, currentParent = null;
        const motion = (target, kind, fields) => push({ do: 'motion3d', stage: sid, op: Object.assign({ target: target.id, kind }, fields) });
        // What tick() sets on a part (its pose this frame), by part id: read by the stage every frame (mateCanvas.tick3d).
        const anim = id => { const a = sink.anim || (sink.anim = {}); return a[id] || (a[id] = {}); };
        const handle = m => {
          const h3 = {
            id: m.id, kind: 'part', name: m.name || null,
            spin(op) { op = op || {}; motion(m, 'spin', { axis: axis3(op.axis, [0, 1, 0]), period: fin(op.period) ? op.period : 6 }); return this; },
            bob(op) { op = op || {}; motion(m, 'bob', { axis: axis3(op.axis, [0, 1, 0]), amount: fin(op.amount) ? op.amount : 0.1, period: fin(op.period) ? op.period : 3 }); return this; },
            orbit(op) { op = op || {}; motion(m, 'orbit', { axis: axis3(op.axis, [0, 1, 0]), center: v3(op.center, [0, 0, 0]), period: fin(op.period) ? op.period : 8 }); return this; },
            path(points, op) {
              op = op || {}; const pts = (points || []).map(p => v3(p, null)).filter(Boolean), once = op.once === true;
              if (pts.length >= 2) motion(m, 'path', Object.assign({ points: pts, closed: !once && op.closed !== false, period: fin(op.period) ? op.period : 6 }, once ? { once: true } : {}));
              return this;
            },
            pulse(op) { op = op || {}; motion(m, 'pulse', { amount: fin(op.amount) ? Math.max(-0.5, Math.min(0.5, op.amount)) : 0.08, period: fin(op.period) ? op.period : 1 }); return this; },
          };
          // Its pose: position, rotation in degrees, scale, shown or hidden, glow 0..1, colour. Inside tick() a write sets
          // this frame's pose; anywhere else (models write piston.pos = [...] or spark.show = false in a beat too) it
          // happens in its beat, as the line is heard: a quick glide for pos and rot, a switch for the rest. Without
          // this it landed the moment the line was written (ahead of the voice), or, with no tick, never.
          const inTick = () => typeof globalThis !== 'undefined' && globalThis.__mateInTick3d === true;
          const planned = {};
          const pose = (key, value, timed) => { if (inTick()) anim(m.id)[key] = value; else { planned[key] = value; timed(); } };
          const got = key => { const a = anim(m.id); return a[key] != null ? a[key] : planned[key]; };
          Object.defineProperties(h3, {
            pos: { enumerable: true, get: () => (got('pos') || m.pos || [0, 0, 0]).slice(),
              set: v => { const p = v3(v, null); if (p) pose('pos', p, () => motion(m, 'tween', { to: p, period: 0.35 })); } },
            rot: { enumerable: true, get: () => (got('rot') || m.rotate3 || [0, 0, 0]).slice(),
              set: v => { const r = v3(v, null); if (r) pose('rot', r, () => motion(m, 'tween', { rot: r, period: 0.35 })); } },
            scale: { enumerable: true, get: () => fin(got('scale')) ? got('scale') : (m.scale3 || 1),
              set: v => { if (fin(v) && v >= 0) pose('scale', v, () => motion(m, 'set', { scale: v })); } },
            show: { enumerable: true, get: () => got('show') !== false, set: v => { pose('show', !!v, () => motion(m, 'set', { show: !!v })); } },
            glow: { enumerable: true, get: () => got('glow') || 0,
              set: v => { if (fin(+v)) { const g = Math.max(0, Math.min(1, +v)); pose('glow', g, () => motion(m, 'set', { glow: g })); } } },
            color: { enumerable: true, get: () => got('color') || (m.material && m.material.color) || null,
              set: v => { if (typeof v === 'string' && v) { const c = colorLikeReal(v); pose('color', c, () => motion(m, 'set', { color: c })); } } },
          });
          return h3;
        };
        const part = (kind, params) => {
          const p = Object.assign({}, params);
          const named = pendingName3 && pendingName3.at === marks.length ? pendingName3.name : null;
          pendingName3 = null;
          const name = typeof p.name === 'string' && p.name.trim() ? p.name.trim().slice(0, 40) : named;
          let pos = v3(p.at, null) || v3(p.pos, [0, 0, 0]);
          let rotate3 = v3(p.rot, null) || v3(p.rotate, [0, 0, 0]);
          const stretch = v3(p.scale, null);
          const material = colorsLikeReal(pickKeys(p, MATERIAL_KEYS));
          // mat: 'steel', 'glass', 'paint:red', 'glow:orange' or a bare colour ('red' = gloss red); its tint in Mate's
          // colours. The stage turns the kind into a real material (DaVinci3DMaterial's studio presets).
          if (typeof p.mat === 'string' && p.mat.trim()) {
            const [kind, tint] = p.mat.trim().toLowerCase().split(':').map(s => s.trim());
            const known = FIGURE_MATERIALS.includes(kind);
            material.mat = known ? kind : 'gloss';
            const t = tint || (known ? null : kind);
            if (t) material.tint = kind === 'glow' ? colorLikeMate(t) : colorLikeReal(t);   // a lamp, a flame, an LED stay vivid
          }
          const shape = {};
          for (const k of Object.keys(p)) if (!FIGURE_PLACE_KEYS.includes(k) && !MATERIAL_KEYS.includes(k)) shape[k] = p[k];
          const recipe = Object.assign({}, shape);
          // cyl({ from, to }) stands between two points: its middle, its length and its direction.
          const from = v3(p.from, null), to = v3(p.to, null);
          if (from && to && (kind === 'cyl' || kind === 'cylinder' || kind === 'capsule' || kind === 'cone' || kind === 'tube')) {
            const d = [to[0] - from[0], to[1] - from[1], to[2] - from[2]], len = Math.hypot(d[0], d[1], d[2]);
            if (len > 1e-6) { pos = [(from[0] + to[0]) / 2, (from[1] + to[1]) / 2, (from[2] + to[2]) / 2]; recipe.h = len; recipe.axis = d.map(c => c / len); }
            shape.from = from; shape.to = to;
          }
          // ReferenceRenderer (2026-10-12, the first live figures): models often turn a part twice, with axis and again with a rot
          // that lays it down the same way (axis: 'x', rot: [0, 0, -90]): a jet engine's casing stood upright, its nozzle
          // pointed at the sky and its compressor wheels faced sideways. When the rot alone already points the part along
          // its axis's line, it is drawn turned once: a round part takes the direction the rot gave it as its axis (a
          // tick's rot then still turns it on top of its axis), an extrusion keeps the rot (it also sets which way the
          // shape faces), and cyl({ from, to }) keeps its two points.
          const along = recipe.axis != null && rotate3.some(d => Math.abs(d) > 1e-6) ? axis3(recipe.axis, null) : null;
          const alongLength = along ? Math.hypot(along[0], along[1], along[2]) : 0;
          if (alongLength > 1e-6 && (FIGURE_ROUND_PARTS.includes(kind) || kind === 'extrude')) {
            const stands = FIGURE_STANDS_ALONG[kind] || [0, 1, 0], unit = along.map(c => c / alongLength), byRot = turn3(rotate3, stands);
            const dot = (a, b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
            if (Math.abs(dot(unit, stands)) < 0.999 && Math.abs(dot(byRot, unit)) > 0.999) {
              if (from && to) rotate3 = [0, 0, 0];
              else if (kind === 'extrude') { delete recipe.axis; delete shape.axis; }
              else { recipe.axis = shape.axis = byRot.map(r3); rotate3 = [0, 0, 0]; }
              warn(`${name || kind}: turned the same way by axis and rot; drew it turned once`);
            }
          }
          // A part turned by right angles stretches along the figure's own x, y, z: models flatten a fuselage laid along z
          // with rot: [90, 0, 0] by scale: [1, 0.7, 1], and it shortened the body instead (a fighter lost its nose, its
          // nose probe floating ahead of it). Any other turn keeps the scale in the part's own axes, as three.js does.
          let stretchInPart = stretch;
          if (stretch && rotate3.some(d => Math.abs(d) > 1e-6) && rotate3.every(d => Math.abs(d / 90 - Math.round(d / 90)) < 1e-6)) {
            stretchInPart = [0, 1, 2].map(i => {
              const e = [0, 0, 0]; e[i] = 1;
              const j = turn3(rotate3, e).findIndex(c => Math.abs(c) > 0.5);
              return stretch[j < 0 ? i : j];
            });
          }
          if (stretchInPart) recipe.stretch = stretchInPart;
          // An arrow or pipe given by points stands at their middle (the points become relative to it), so its label, its
          // picking and the camera's framing find it where it is, not at the figure's origin.
          if ((kind === 'arrow' || kind === 'pipe') && !v3(p.at, null) && !v3(p.pos, null) && Array.isArray(recipe.points)) {
            const points = recipe.points.map(q => v3(q, null)).filter(Boolean);
            if (points.length >= 2) {
              const middle = [0, 1, 2].map(k => r3(points.reduce((sum, q) => sum + q[k], 0) / points.length));
              recipe.points = points.map(q => q.map((v, k) => r3(v - middle[k])));
              pos = middle;
            }
          }
          // ReferenceRenderer (2026-10-12, Blender's tools): cut: true (or 'x', '-y', { axis, at }) slices the part with a plane
          // through the figure's middle, the way Blender's answers cut a casing open with a boolean. cut: true takes away
          // the half toward the viewer whichever way the figure has turned (cutFacing: the stage turns the plane with
          // the camera; +z until it does), a named axis that side for good. The stage paints the inside that shows
          // through the opening as a hatched cut face (DaVinci3DMaterial.cutPlane).
          const cut = p.cut === true ? 'z' : p.cut && typeof p.cut === 'object' ? p.cut.axis || 'z' : p.cut;
          const cutNormal = cut ? axis3(cut, null) : null;
          if (cutNormal && Math.hypot(...cutNormal) > 1e-6) {
            const length = Math.hypot(...cutNormal), n = cutNormal.map(v => v / length);
            const at = p.cut && typeof p.cut === 'object' && fin(p.cut.at) ? p.cut.at : 0;
            // The plane crosses the axis at `at` (a coordinate on it, whichever side is taken away).
            material.cut = [...n.map(r3), r3(at * (n[0] + n[1] + n[2] < 0 ? -1 : 1) * Math.max(...n.map(Math.abs)))];
            if (p.cut === true) material.cutFacing = true;
          }
          // Its copies: copies: { count, step, turn } in a row and around: { count, axis, center, arc } round an axis (a
          // fan's blades, a wheel's bolts), each count including the part itself; then mirror: 'x' (or ['x', 'z']) adds
          // the mirror image of each across the figure's middle (a plane's other wing). Copies share their shape.
          const placements = [{ pos, rotate3, reflect: null }];
          // (A group is only its own place: what hangs on it comes later, so it has nothing to copy yet.)
          const copies = kind !== 'group' && p.copies && typeof p.copies === 'object' ? p.copies : null;
          if (copies) {
            const count = Math.max(1, Math.min(200, Math.round(fin(copies.count) ? copies.count : 1)));
            const step = v3(copies.step, [0, 0, 0]), turnBy = v3(copies.turn, [0, 0, 0]);
            for (let i = 1; i < count; i++) placements.push({ pos: pos.map((v, k) => r3(v + step[k] * i)), rotate3: rotate3.map((v, k) => r3(v + turnBy[k] * i)), reflect: null });
          }
          const around = kind !== 'group' && p.around && typeof p.around === 'object' ? p.around : null;
          if (around) {
            const count = Math.max(1, Math.min(240, Math.round(fin(around.count) ? around.count : 1))), axis = axis3(around.axis, [0, 1, 0]);
            const center = v3(around.center, [0, 0, 0]), arc = fin(around.arc) ? Math.max(-360, Math.min(360, around.arc)) : 360;
            const gap = Math.abs(arc) >= 360 ? arc / count : arc / Math.max(1, count - 1);
            const row = placements.slice();
            for (let i = 1; i < count; i++) {
              const q = quatAxisAngle(axis, gap * i);
              for (const b of row) {
                const offset = rotateAbout(q, [b.pos[0] - center[0], b.pos[1] - center[1], b.pos[2] - center[2]]);
                placements.push({ pos: offset.map((v, k) => r3(v + center[k])), rotate3: euler3FromQuat(quatMultiply(q, quatFromEuler3(b.rotate3))), reflect: null });
              }
            }
          }
          const mirrorAxes = (kind === 'group' ? [] : Array.isArray(p.mirror) ? p.mirror : p.mirror ? [p.mirror] : [])
            .map(a => typeof a === 'string' ? a.trim().toLowerCase().replace(/^[+-]/, '') : null).filter(a => ['x', 'y', 'z'].includes(a));
          if (mirrorAxes.length) {
            const reflections = [];
            for (let mask = 1; mask < (1 << mirrorAxes.length); mask++) {
              const s = [1, 1, 1];
              mirrorAxes.forEach((a, k) => { if (mask & (1 << k)) s['xyz'.indexOf(a)] = -1; });
              if (!reflections.some(r => r.every((v, k) => v === s[k]))) reflections.push(s);
            }
            const unmirrored = placements.slice();
            // A reflection M of a part stands at M·pos, turned M·R·M: each Euler angle times the other two axes' signs.
            for (const s of reflections) for (const b of unmirrored) {
              placements.push({ pos: b.pos.map((v, k) => r3(v * s[k])), rotate3: [b.rotate3[0] * s[1] * s[2], b.rotate3[1] * s[0] * s[2], b.rotate3[2] * s[0] * s[1]].map(r3), reflect: s });
            }
          }
          const parent = (p.parent && p.parent.id) || currentParent;
          let first = null;
          placements.forEach((place, index) => {
            const own = place.reflect ? Object.assign({}, recipe, { mirror: place.reflect }) : recipe;
            const recipeJSON = JSON.stringify(canonical3(own));
            const m = { do: 'part3d', id: sid + 'p' + (++partCount), stage: sid, kind, three: true, recipe: recipeJSON, pos: place.pos, rotate3: place.rotate3,
              scale3: fin(p.scale) ? p.scale : 1, material, parent };
            if (name) m.name = index === 0 ? name : `${name} ${place.reflect ? 'mirror' : index + 1}`;
            m.params = shape;
            push(m);
            // Start building its shape now: the kernel has until this part's beat is drawn.
            if (kind !== 'group' && typeof global.__shape3d === 'function') global.__shape3d(kind, recipeJSON);
            if (!first) first = m;
          });
          return handle(first);
        };
        const f = { id: sid, kind: 'figure' };
        for (const k of FIGURE_PARTS) f[k] = op => part(k === 'cylinder' ? 'cyl' : k, op);
        // f.arrow(points, { r, mat }) or f.arrow({ points, ... }): a flow arrow through the points, head at the last.
        f.arrow = (a, b) => Array.isArray(a) ? part('arrow', Object.assign({}, b, { points: a })) : part('arrow', a || {});
        f.surface = (fn, op) => {
          op = op || {};
          const segments = Math.max(4, Math.min(160, op.segments || 80)), rows = Math.max(2, Math.min(80, op.rows || 16)), u = op.u || [0, 1], v = op.v || [0, 1], grid = [];
          try { for (let j = 0; j <= rows; j++) { const row = []; for (let i = 0; i <= segments; i++) row.push(v3(fn(u[0] + (u[1] - u[0]) * i / segments, v[0] + (v[1] - v[0]) * j / rows), [0, 0, 0]).map(r3)); grid.push(row); } }
          catch (e) { warn('surface() function failed: ' + e.message); return null; }
          const rest = Object.assign({}, op); delete rest.segments; delete rest.rows; delete rest.u; delete rest.v;
          return part('surface', Object.assign(rest, { grid }));
        };
        // group(op) or group((f) => { ... }, op): parts made inside (or given { parent }) move with it.
        f.group = (a, b) => {
          const fn = typeof a === 'function' ? a : null, op = fn ? b : a;
          const g = part('group', Object.assign({}, op));
          if (fn) { const saved = currentParent; currentParent = g.id; try { fn(f); } finally { currentParent = saved; } }
          return g;
        };
        f.label = (point, text, op) => {
          op = op || {};
          const t = String(text == null ? '' : text).trim(); if (!t) return null;
          return push({ do: 'label3d', id: sid + 'l' + (++labelCount), stage: sid, point: point && point.id ? null : v3(point, [0, 0, 0]), follow: point && point.id ? point.id : null,
            text: t.slice(0, 60), side: op.side === 'left' || op.side === 'right' ? op.side : null, size: fin(op.size) ? Math.max(15, Math.min(28, op.size)) : 19, tone: op.tone || ink });
        };
        // tick((t, dt) => { ... }) runs every frame once its beat is drawn (t: seconds since then): set parts' pos, rot,
        // scale, show, glow and color to drive a mechanism. The function stays in this program's live run; its mark only
        // says when it starts.
        f.tick = fn => {
          if (typeof fn !== 'function') { warn('tick() needs a function: tick((t) => { part.pos = [...] })'); return null; }
          const m = push({ do: 'tick3d', id: sid + 't' + (++figureTicks), stage: sid });
          (sink.ticks || (sink.ticks = {}))[m.id] = fn;
          return { id: m.id };
        };
        // readout({ Stroke: 'Power', Angle: '400°' }): a few live numbers or words for the figure's card, usually set
        // from tick() (the latest values win; kept for the stage, never a mark).
        f.readout = values => {
          if (!values || typeof values !== 'object') return f;
          const r = sink.readouts || (sink.readouts = {}), now = r[sid] || (r[sid] = {});
          for (const k of Object.keys(values).slice(0, 6)) { const v = values[k]; if (v == null) delete now[k]; else now[String(k).slice(0, 24)] = String(v).slice(0, 32); }
          return f;
        };
        // move(part, { to, rot, secs }) glides a part to a new place or angle once, in this beat, and leaves it there.
        f.move = (target, op) => {
          op = op || {};
          if (!target || !target.id) { warn('move() needs a part'); return null; }
          const to = v3(op.to, null), rot = v3(op.rot, null);
          if (!to && !rot) return null;
          motion(target, 'tween', Object.assign({ period: fin(op.secs) ? Math.max(0.05, op.secs) : 0.8 }, to ? { to } : {}, rot ? { rot } : {}));
          return target;
        };
        // view({ turn, tilt, zoom, spin }): show it from another side, closer or turning faster (camera() is the same).
        f.view = f.camera = op => {
          op = op || {};
          push({ do: 'camera3d', stage: sid, op: { tilt: fin(op.tilt) ? Math.max(-80, Math.min(80, op.tilt)) : undefined, fov: fin(op.fov) ? op.fov : undefined, spin: fin(op.spin) ? op.spin : undefined,
            target: v3(op.target, undefined), turn: fin(op.turn) ? Math.max(-180, Math.min(180, op.turn)) : undefined, zoom: fin(op.zoom) ? Math.max(0.5, Math.min(3, op.zoom)) : undefined } });
          return f;
        };
        f.build = (fn, op) => {
          if (typeof fn !== 'function') return f;
          const saved = currentParent;
          if (op && op.parent && op.parent.id) currentParent = op.parent.id;
          try { fn(f); } finally { currentParent = saved; }
          return f;
        };
        f.part = id => { const t = String(id == null ? '' : id).trim(); const n = /^(?:st\d+)?p?(\d+)$/.exec(t); return n ? handle({ id: sid + 'p' + n[1] }) : null; };
        return f;
      };

      // ------------------------------------------------ graph piece: axes in data units, with anchors
      api.graph = (gx, gy, gw, gh, o) => {
        o = o || {};
        const xr = Array.isArray(o.x) ? o.x : [0, 10], yr = Array.isArray(o.y) ? o.y : [0, 10];
        const X = v => gx + (v - xr[0]) / ((xr[1] - xr[0]) || 1) * gw, Y = v => gy + gh - (v - yr[0]) / ((yr[1] - yr[0]) || 1) * gh;
        const at = (a, b) => Array.isArray(a) ? [X(a[0]), Y(a[1])] : [X(a), Y(b)];
        const ink = o.tone || 'ink', ax = yr[0] < 0 && yr[1] > 0 ? Y(0) : gy + gh, ay = xr[0] < 0 && xr[1] > 0 ? X(0) : gx;
        const ticks = (list, lo, hi) => (Array.isArray(list) ? list : (list === true || o.ticks) ? niceTicks(lo, hi) : []).map(t => Array.isArray(t) ? [t[0], String(t[1])] : [t, fmt(t)]);
        const xt = ticks(o.xTicks, xr[0], xr[1]), yt = ticks(o.yTicks, yr[0], yr[1]);
        if (o.grid) {
          for (const [v] of xt) api.line([[X(v), gy], [X(v), gy + gh]], { tone: 'grey', size: 1.4, alpha: 0.4, smooth: false, piece: 'graph' });
          for (const [v] of yt) api.line([[gx, Y(v)], [gx + gw, Y(v)]], { tone: 'grey', size: 1.4, alpha: 0.4, smooth: false, piece: 'graph' });
        }
        api.arrow([[Math.min(gx, ay) - 6, ax], [gx + gw + 12, ax]], { tone: ink, size: 1.8, head: 8, piece: 'graph' });
        api.arrow([[ay, Math.max(gy + gh, ax) + 6], [ay, gy - 12]], { tone: ink, size: 1.8, head: 8, piece: 'graph' });
        for (const [v, lab] of xt) { if (v === 0 && ay === X(0)) continue; api.line([[X(v), ax - 4], [X(v), ax + 4]], { tone: ink, size: 1.6, smooth: false, piece: 'graph' }); api.text(X(v), ax + 22, lab, { anchor: 'middle', size: 14, tone: 'grey', piece: 'graph' }); }
        for (const [v, lab] of yt) { if (v === 0 && ax === Y(0)) continue; api.line([[ay - 4, Y(v)], [ay + 4, Y(v)]], { tone: ink, size: 1.6, smooth: false, piece: 'graph' }); api.text(ay - 9, Y(v) + 5, lab, { anchor: 'end', size: 14, tone: 'grey', piece: 'graph' }); }
        if (o.xLabel) api.text(gx + gw + 12, ax + (xt.length ? 48 : 30), o.xLabel, { anchor: 'end', size: o.labelSize || 18, piece: 'graph' });
        if (o.yLabel) api.text(ay - 4, gy - 24, o.yLabel, { anchor: 'start', size: o.labelSize || 18, piece: 'graph' });
        const inRange = ([u, v]) => u >= xr[0] - 1e-9 && u <= xr[1] + 1e-9 && v >= Math.min(yr[0], yr[1]) - 1e-9 && v <= Math.max(yr[0], yr[1]) + 1e-9;
        const clip = (a, b) => {                      // the point where segment a->b (a inside) leaves the data box
          let lo = 0, hi = 1; for (let k = 0; k < 24; k++) { const m = (lo + hi) / 2, p = [a[0] + (b[0] - a[0]) * m, a[1] + (b[1] - a[1]) * m]; if (inRange(p)) lo = m; else hi = m; }
          return [a[0] + (b[0] - a[0]) * lo, a[1] + (b[1] - a[1]) * lo];
        };
        const yOf = data => u => {
          for (let k = 1; k < data.length; k++) { const [a, b] = [data[k - 1], data[k]]; if ((u - a[0]) * (u - b[0]) <= 0 && a[0] !== b[0]) return a[1] + (b[1] - a[1]) * (u - a[0]) / (b[0] - a[0]); }
          return null;
        };
        const midOf = data => {                          // the data point halfway along the drawn line
          const P = data.map(p => at(p)); let L = 0; for (let k = 1; k < P.length; k++) L += Math.hypot(P[k][0] - P[k - 1][0], P[k][1] - P[k - 1][1]);
          let acc = 0; for (let k = 1; k < P.length; k++) { const d = Math.hypot(P[k][0] - P[k - 1][0], P[k][1] - P[k - 1][1]); if (acc + d >= L / 2 && d) { const t = (L / 2 - acc) / d; return [data[k - 1][0] + (data[k][0] - data[k - 1][0]) * t, data[k - 1][1] + (data[k][1] - data[k - 1][1]) * t]; } acc += d; }
          return data[0] || [0, 0];
        };
        const series = (data, po, straight) => {
          data = data.filter(finite);
          const pieces = []; let cur = [];
          for (let k = 0; k < data.length; k++) {
            const p = data[k], ins = inRange(p);
            if (ins) { if (!cur.length && k && !inRange(data[k - 1])) cur.push(clip(p, data[k - 1])); cur.push(p); }
            else if (cur.length) { cur.push(clip(data[k - 1], p)); pieces.push(cur); cur = []; }
          }
          if (cur.length) pieces.push(cur);
          const tn = po.tone || 'blue', sz = po.size || 4;
          for (const pc of pieces) if (pc.length >= 2) api.line(pc.map(p => at(p)), { tone: tn, size: sz, smooth: straight ? false : undefined, dash: po.dash, piece: 'graph' });
          if (!pieces.length) warn('graph: a line lies completely outside the graph ranges');
          const last = pieces.length ? pieces[pieces.length - 1] : data, first = pieces.length ? pieces[0] : data;
          const end = at(last[last.length - 1] || [0, 0]), start = at(first[0] || [0, 0]);
          if (po.label) {
            const lw = textW(po.label, 18), atStart = po.labelAt === 'start', p = atStart ? start : end;
            let lx = p[0] + (atStart ? -8 : 8), ly = p[1] + 6, anchor = atStart ? 'end' : 'start';
            if (!atStart && lx + lw > w - 8) { lx = p[0] - 4; ly = p[1] - 14; anchor = 'end'; }
            if (atStart && lx - lw < 8) { lx = p[0] + 4; ly = p[1] - 14; anchor = 'start'; }
            if (p[1] <= ax && ly > ax - 12) ly = p[1] - 12;          // keep a line's name off the x axis
            api.text(lx, Math.max(22, Math.min(h - 8, ly)), po.label, { anchor, size: po.labelSize || 18, tone: po.labelTone || tn, piece: 'graph' });
          }
          const y = yOf(data), mid = midOf(data);
          return { data, tone: tn, size: sz, straight, label: po.label, start, end, mid: at(mid), midData: mid, pts: data.map(p => at(p)), y, at: u => { const v = y(u); return v == null ? null : at(u, v); } };
        };
        const g = { box: { x: gx, y: gy, w: gw, h: gh }, origin: [ay, ax], x: X, y: Y, at };
        g.plot = (f, po) => {
          po = po || {};
          if (typeof f === 'function') {
            const a = po.from != null ? po.from : xr[0], b = po.to != null ? po.to : xr[1], n = po.samples || 64, data = [];
            for (let k = 0; k <= n; k++) { const u = a + (b - a) * k / n; let v; try { v = f(u); } catch (_) { v = NaN; } if (isFinite(v)) data.push([u, v]); }
            return series(data, po, false);
          }
          // ReferenceRenderer: data points are joined with straight lines (a speed-time graph is segments, smoothing bent it past its
          // own points); a long list reads as a curve, and {smooth: true} / {straight: true} decide it outright
          if (Array.isArray(f)) return series(f, po, po.smooth === true ? false : po.straight != null ? !!po.straight : f.length <= 8);
          warn('graph: plot() needs a function or a list of [x, y] points'); return null;
        };
        g.line = (p1, p2, po) => g.plot([p1, p2], Object.assign({ straight: true }, po || {}));
        g.shift = (s, dx, dy, po) => {
          po = po || {};
          if (!s || !s.data) { warn('graph: shift() needs a line made by plot() or line()'); return null; }
          const data = s.data.map(([u, v]) => [u + (dx || 0), v + (dy || 0)]);
          const s2 = series(data, Object.assign({ size: s.size }, po, { tone: po.tone || s.tone }), s.straight);
          if (po.arrow !== false && data.length) {
            const m0 = midOf(s.data), a = at(m0), b = at([m0[0] + (dx || 0), m0[1] + (dy || 0)]);
            if (Math.hypot(b[0] - a[0], b[1] - a[1]) > 14) api.arrow([[a[0] + (b[0] - a[0]) * 0.18, a[1] + (b[1] - a[1]) * 0.18], [a[0] + (b[0] - a[0]) * 0.82, a[1] + (b[1] - a[1]) * 0.82]], { tone: po.arrowTone || 'ink', size: 3, head: 9, piece: 'graph' });
          }
          return s2;
        };
        g.cross = (s1, s2) => {
          if (!s1 || !s2 || !s1.data || !s2.data) { warn('graph: cross() needs two lines'); return null; }
          const A = s1.data, B = s2.data;
          for (let i = 1; i < A.length; i++) for (let j = 1; j < B.length; j++) {
            const [p, p2] = [A[i - 1], A[i]], [q, q2] = [B[j - 1], B[j]];
            const r = [p2[0] - p[0], p2[1] - p[1]], s = [q2[0] - q[0], q2[1] - q[1]], den = r[0] * s[1] - r[1] * s[0];
            if (Math.abs(den) < 1e-12) continue;
            const t = ((q[0] - p[0]) * s[1] - (q[1] - p[1]) * s[0]) / den, u = ((q[0] - p[0]) * r[1] - (q[1] - p[1]) * r[0]) / den;
            if (t >= -1e-9 && t <= 1 + 1e-9 && u >= -1e-9 && u <= 1 + 1e-9) return [p[0] + r[0] * t, p[1] + r[1] * t];
          }
          warn('graph: these two lines do not cross inside the graph'); return null;
        };
        g.point = (a, b, po) => {
          if (Array.isArray(a)) { po = b; b = a[1]; a = a[0]; }
          po = po || {};
          if (a == null || b == null || !isFinite(a) || !isFinite(b)) { warn('graph: point() got no point (did cross() find one?)'); return null; }
          const [cx, cy] = at(a, b);
          if (po.guides) {
            api.line([[cx, cy], [cx, ax]], { tone: po.guideTone || 'grey', size: 2.4, dash: true, smooth: false, piece: 'graph' });
            api.line([[cx, cy], [ay, cy]], { tone: po.guideTone || 'grey', size: 2.4, dash: true, smooth: false, piece: 'graph' });
          }
          api.dot(cx, cy, po.r || 6.5, { tone: po.tone || 'ink', piece: 'graph' });
          if (po.xTick) api.text(cx, ax + 24, po.xTick, { anchor: 'middle', size: 16, tone: po.tickTone || po.tone || 'ink', piece: 'graph' });
          if (po.yTick) api.text(ay - 10, cy + 5, po.yTick, { anchor: 'end', size: 16, tone: po.tickTone || po.tone || 'ink', piece: 'graph' });
          if (po.label) api.text(cx + 12, cy - 12, po.label, { size: po.labelSize || 17, tone: po.labelTone || po.tone || 'ink', piece: 'graph' });
          const p = [cx, cy]; p.data = [a, b]; return p;
        };
        return g;
      };

      // ------------------------------------------------ timeline piece: dated marks with picture slots
      api.timeline = (tx, ty, tw, events, o) => {
        o = o || {};
        const ev = (Array.isArray(events) ? events : []).map((e, i) => Array.isArray(e) ? { date: e[0], label: e[1] == null ? '' : String(e[1]), show: e[2] }
          : e && typeof e === 'object' ? { date: e.date != null ? e.date : e.at != null ? e.at : i, label: String(e.label || e.text || ''), show: e.show }
          : { date: e, label: '' });
        const n = ev.length, tn = o.tone || 'ink';
        api.arrow([[tx, ty], [tx + tw, ty]], { tone: tn, size: 2, head: 9, piece: 'timeline' });
        if (!n) { warn('timeline: no events'); return { marks: [], events: [], at: () => [tx, ty], slot: () => null }; }
        const num = ev.every(e => typeof e.date === 'number' && isFinite(e.date));
        const inset = o.inset != null ? o.inset : Math.min(60, tw / (2 * n)), span = tw - 2 * inset - 12;
        const lo = num ? (o.from != null ? o.from : Math.min(...ev.map(e => e.date))) : 0, hi = num ? (o.to != null ? o.to : Math.max(...ev.map(e => e.date))) : n - 1;
        const scale = d => tx + inset + (n === 1 && !(o.from != null && o.to != null) ? span / 2 : (d - lo) / ((hi - lo) || 1) * span);
        const xs = ev.map((e, i) => num && !o.even ? scale(e.date) : tx + inset + (n === 1 ? span / 2 : i * span / (n - 1)));
        const alt = o.slots === 'alternate', minGap = Math.min(o.minGap || (alt ? 70 : 96), span / Math.max(1, n - 1));
        const order = xs.map((x, i) => i).sort((a, b) => xs[a] - xs[b]);
        for (let k = 1; k < n; k++) xs[order[k]] = Math.max(xs[order[k]], xs[order[k - 1]] + minGap);
        for (let k = n - 1; k >= 0; k--) xs[order[k]] = Math.min(xs[order[k]], k === n - 1 ? tx + inset + span : xs[order[k + 1]] - minGap);
        if (num && !o.even && xs.some((x, i) => Math.abs(x - scale(ev[i].date)) > 12)) warn('timeline: some dates were too close, so their marks were spread apart');
        const room = i => { const sorted = order.map(k => xs[k]), k = sorted.indexOf(xs[i]); const l = k > 0 ? xs[i] - sorted[k - 1] : 1e9, r = k < n - 1 ? sorted[k + 1] - xs[i] : 1e9; const g = Math.min(l, r); return g > 1e8 ? tw / 2 : g; };
        const marks = ev.map((e, i) => {
          // above: picture above the line, words below; below: the other way round;
          // alternate: each mark gets one side for its date, words and picture (in that order, away from the line)
          const x = xs[i], wordsBelow = o.slots === 'below' ? false : alt ? i % 2 === 0 : true, slotBelow = alt ? wordsBelow : o.slots === 'below';
          api.line([[x, ty - 9], [x, ty + 9]], { tone: tn, size: 3, smooth: false, piece: 'timeline' });
          api.dot(x, ty, 5.5, { tone: o.dotTone || 'coral', piece: 'timeline' });
          const ds = e.show != null ? String(e.show) : num ? fmt(e.date) : String(e.date), lw = Math.min(190, (alt ? 1.85 : 0.96) * room(i));
          const sw = o.slotW || Math.min(150, (alt ? 1.8 : 0.9) * room(i));
          const ls = o.labelSize || 17, dsz = o.dateSize || 18;
          const two = e.label && textW(e.label, ls) > lw - 6;       // the label will wrap onto two lines
          if (wordsBelow) { api.text(x, ty + 30, ds, { anchor: 'middle', size: dsz, tone: o.dateTone || tn, piece: 'timeline' }); if (e.label) api.text(x, ty + (two ? 64 : 56), e.label, { anchor: 'middle', size: ls, fit: [lw - 6, 44], piece: 'timeline' }); }
          else { api.text(x, ty - 18, ds, { anchor: 'middle', size: dsz, tone: o.dateTone || tn, piece: 'timeline' }); if (e.label) api.text(x, ty - (two ? 54 : 44), e.label, { anchor: 'middle', size: ls, fit: [lw - 6, 44], piece: 'timeline' }); }
          const far = alt;                                      // slot beyond the words (alternate) or right next to the line
          const space = slotBelow ? h - 10 - (ty + (far ? 90 : 16)) : ty - (far ? 92 : 16) - 60;
          const sh = o.slotH || Math.max(40, Math.min(far ? 110 : 150, space));
          const sy = slotBelow ? ty + (far ? 90 : 16) : ty - (far ? 92 : 16) - sh;
          return { date: e.date, label: e.label, x, y: ty, at: [x, ty], slot: { x: x - sw / 2, y: sy, w: sw, h: sh, cx: x, cy: sy + sh / 2 } };
        });
        const at = d => {
          if (!num || typeof d !== 'number') { const k = ev.findIndex(e => e.date === d); return k >= 0 ? [xs[k], ty] : [tx, ty]; }
          const s = order.map(i => [ev[i].date, xs[i]]);
          if (d <= s[0][0]) return [s[0][1] - (s[0][0] - d) / ((hi - lo) || 1) * span, ty];
          for (let k = 1; k < s.length; k++) if (d <= s[k][0]) return [s[k - 1][1] + (s[k][1] - s[k - 1][1]) * (d - s[k - 1][0]) / ((s[k][0] - s[k - 1][0]) || 1), ty];
          return [s[s.length - 1][1] + (d - s[s.length - 1][0]) / ((hi - lo) || 1) * span, ty];
        };
        return { marks, events: marks, at, slot: i => marks[i] ? marks[i].slot : null, start: [tx, ty], end: [tx + tw, ty] };
      };
      // ------------------------------------------------ ReferenceRenderer: edits on what is already on the card, as marks
      // Each is a mark {do: 'edit', op} paced like a stroke: it belongs to the say() before it and happens while that line
      // is heard. Ids are part ids from the card's state (p3, 'p3,p5', ['p3', 'p5']) or mark ids (m12, m12-m15).
      const ids = id => Array.isArray(id) ? id.map(x => typeof x === 'number' ? 'p' + x : String(x)) : typeof id === 'number' ? 'p' + id : String(id == null ? '' : id);
      const edit = op => { if (!op.id && op.op !== 'startOver' && op.op !== 'turn') warn(op.op + '() needs a part id like "p3"'); return push({ do: 'edit', op }); };
      api.erase = id => edit({ op: 'erase', id: ids(id) });
      api.recolor = (id, c) => edit(Object.assign({}, c && typeof c === 'object' ? c : { color: c }, { op: 'recolor', id: ids(id) }));
      api.restyle = (id, o) => edit(Object.assign({}, o && typeof o === 'object' ? o : {}, { op: 'restyle', id: ids(id) }));
      api.move = (id, dx, dy) => edit({ op: 'move', id: ids(id), dx: +dx || 0, dy: +dy || 0 });
      api.moveTo = (id, x, y) => edit({ op: 'moveTo', id: ids(id), x: +x, y: +y });
      api.scale = (id, k) => edit({ op: 'scale', id: ids(id), k: +k });
      // highlight(x, y, w, h) is still the marker band; highlight(id, color) marks a part that is already there
      api.highlight = (a, b, c, d, o) => typeof a === 'number' ? push({ do: 'highlight', at: [a, b], w: c, h: d }, o)
        : edit({ op: 'highlight', id: ids(a), color: b && typeof b === 'object' ? b.color : b });
      // everything already on the card un-draws; the rest of the program is a fresh drawing
      api.startOver = () => edit({ op: 'startOver' });
      // a new turn on the same card (written by the canvas, never by the model): its steps start again, and the
      // previous turns' marks from index `keep` on that were never drawn (the user interrupted) are dropped
      api.__turn = (n, keep) => { curTurn = +n || curTurn + 1; curStep = 1; cue = null; return edit({ op: 'turn', turn: curTurn, keep: keep == null ? null : +keep }); };
      let seed = 20260925;
      api.Math = Object.create(Math, { random: { value: () => ((seed = (seed * 1664525 + 1013904223) >>> 0) / 4294967296) } });   // seeded: the same program always draws the same picture
      api.random = api.Math.random;
      for (const t of TONE_NAMES) if (!(t in api)) api[t] = t;   // forgiving: tone: leaf works like tone: 'leaf'
      return api;
    }

    // a mark as plain data: no functions, so it can cross into the page or be posted from a worker
    function clean(m) { const o = {}; for (const k in m) { const v = m[k]; if (typeof v !== 'function' && typeof v !== 'symbol') o[k] = v; } return o; }

    const FIGURE_PART_NAME = /^(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*[A-Za-z_$][\w$]*\s*\.\s*(?:box|cyl|cylinder|cone|tube|lathe|sphere|torus|capsule|pipe|spring|gear|extrude|blob|poly|surface|group)\s*\(/;
    // Top-level const/let become var so they survive between chunks of a live drawing (and a turn may declare a name an
    // earlier turn declared); a helper named like a drawing call must shadow it.
    function transform(src, starts, api) {
      let out = '', last = 0;
      for (const s of starts) {
        let i = s;
        for (;;) {                                       // skip blanks and comments before the statement
          while (i < src.length && /\s/.test(src[i])) i++;
          if (src.startsWith('//', i)) { const j = src.indexOf('\n', i); i = j < 0 ? src.length : j; continue; }
          if (src.startsWith('/*', i)) { const j = src.indexOf('*/', i + 2); i = j < 0 ? src.length : j + 2; continue; }
          break;
        }
        // ReferenceRenderer fix: two statement starts can skip comments/blanks to the same statement (a comment
        // block before it); rewriting it twice gave "var  var x" and broke every streamed update.
        if (i < last) continue;
        const m = /^(const|let)(\s)/.exec(src.slice(i, i + 6)), f = /^function\s+([A-Za-z_$][\w$]*)/.exec(src.slice(i, i + 80));
        // three-metal: a figure part assigned to a variable (const piston = f.cyl(...)) is named after it
        const named = '__name3d' in api && FIGURE_PART_NAME.exec(src.slice(i, i + 160));
        if (named) { out += src.slice(last, i) + '__name3d(' + JSON.stringify(named[1]) + ');'; last = i; }
        if (m) { out += src.slice(last, i) + 'var' + (m[1] === 'const' ? '  ' : ''); last = i + m[1].length; }
        else if (f && f[1] in api) { out += src.slice(last, i) + 'var ' + f[1] + ' = '; last = i; }   // a helper named like a drawing call must shadow it
      }
      return out + src.slice(last);
    }
    // ReferenceRenderer: a whole program runs with the same rewrite, so it draws exactly what streaming it statement by statement draws
    const wholeProgram = (c, api, knownEnds) => transform(c, [0].concat((knownEnds || statementEnds(c + '\n;')).filter(e => e < c.length)), api);

    // run a whole program at once (render, and the fallback for live)
    function runCode(code, w, h, ro) {
      ro = ro || {};
      const sink = { marks: [], says: [], warnings: [], deadline: ro.budgetMs ? Date.now() + ro.budgetMs : 0, ticks: {}, anim: {} };
      const api = makeApi(w, h, sink), marks = sink.marks;
      let error = null, fn = null;
      try { fn = new Function('api', 'with (api) {\n' + wholeProgram(code, api, ro.knownEnds) + '\n}'); }
      catch (e) {                      // a syntax error: keep the longest run of complete statements that parses, like live streaming would
        const ends = statementEnds(code + '\n');
        for (let k = ends.length - 1; k >= 0 && !fn; k--) { try { fn = new Function('api', 'with (api) {\n' + wholeProgram(code.slice(0, ends[k]), api) + '\n}'); error = `syntax error after line ${code.slice(0, ends[k]).split('\n').length}: ${e.message}`; } catch (_) {} }
        if (!fn) error = `syntax error: ${e.message}`;
      }
      if (fn) try { fn(api); }
      catch (e) {
        const m = /<anonymous>:(\d+)/.exec(e.stack || '');
        error = `code stopped${m ? ' at line ' + (m[1] - 2) : ''}: ${e.message}`;
      }
      if (error) error += ` (kept the ${marks.length} marks before it)`;
      marks.error = error; marks.says = sink.says; marks.warnings = sink.warnings;
      // three-metal: figure() tick functions and the poses they set, for the run that keeps going (Session, full mode)
      Object.defineProperty(marks, 'live3d', { value: { ticks: sink.ticks, anim: sink.anim }, enumerable: false });
      return marks;
    }

    // incremental execution for live drawing: each complete statement runs once, in one persistent scope.
    // Top-level const/let become var so they survive between chunks. Any error switches to re-running
    // the whole prefix (1.4 behaviour), which gives exactly what render() would draw.
    function Session(w, h, so) {
      so = so || {};
      const budget = so.budgetMs || 0;
      let sink, api, gen, mode, code, emitted, fellBack = null;
      function reset() { sink = { marks: [], says: [], warnings: [], ticks: {}, anim: {} }; api = makeApi(w, h, sink); gen = null; mode = so.incremental === false ? 'full' : 'inc'; code = ''; emitted = { marks: 0, says: 0, warnings: 0 }; }
      reset();
      // knownEnds (optional): statementEnds() of a longer program `full` is the start of, when the caller has them
      function update(full, done, knownEnds) {
        if (!full.startsWith(code)) reset();              // not append-only: start again
        const delta = full.slice(code.length);
        if (mode === 'inc' && delta.trim()) {
          if (!gen) { const G = new Function('__api', 'return function* () { with (__api) { let __r = null; for (;;) { const __c = yield __r; __r = null; try { eval(__c); } catch (e) { __r = e; } } } }')(api); gen = G(); gen.next(); }
          const base = code.length, starts = [0].concat((knownEnds || statementEnds(full + '\n;')).filter(e => e > base && e < full.length).map(e => e - base));
          sink.deadline = budget ? Date.now() + budget : 0;
          let err = null;
          try { err = gen.next(transform(delta, starts, api)).value; } catch (e) { err = e; }
          if (err && err.name === 'SyntaxError' && !done) return { marks: [], says: [], warnings: [], error: null, mode };   // parse errors have no side effects: wait for more code
          if (err) { mode = 'full'; fellBack = String(err && err.message || err); }
        }
        code = full;
        let error = null;
        if (mode === 'full') { const m = runCode(code, w, h, { budgetMs: budget }); sink = { marks: m, says: m.says, warnings: m.warnings, ticks: m.live3d.ticks, anim: m.live3d.anim }; error = m.error; }
        const out = { marks: sink.marks.slice(emitted.marks).map(clean), says: sink.says.slice(emitted.says), warnings: sink.warnings.slice(emitted.warnings), error: done ? error : null, mode };
        emitted = { marks: Math.max(emitted.marks, sink.marks.length), says: Math.max(emitted.says, sink.says.length), warnings: Math.max(emitted.warnings, sink.warnings.length) };
        return out;
      }
      // code: the program this session has run so far (ReferenceRenderer: a continued turn appends to exactly this)
      // live3d: this run's figure() tick functions and the poses they set (three-metal; mateCanvas.tick3d runs them)
      return { update, get mode() { return mode; }, get fellBack() { return fellBack; }, get code() { return code; }, get live3d() { return { ticks: sink.ticks, anim: sink.anim }; } };
    }
    // 1.6: which top-level statement made which marks, run exactly like live() (statement by statement).
    // Returns [{s, e, n0, n1}]: the statement's character span and the range of mark indices it drew.
    function attribute(code, w, h) {
      const S = Session(w, h), out = [], all = statementEnds(code + '\n;'); let n = 0, prev = 0;
      for (const e of statementEnds(code)) { const r = S.update(code.slice(0, e), false, all); out.push({ s: prev, e, n0: n, n1: n + r.marks.length }); n += r.marks.length; prev = e; }
      if (prev < code.length) { const r = S.update(code, true); out.push({ s: prev, e: code.length, n0: n, n1: n + r.marks.length }); }
      return out;
    }
    // 1.6: run a code fragment (an edit's "add" or "redraw") after the drawing's own program, so its helpers and
    // variables are in scope. Only the fragment's marks come back.
    function exec(base, frag, w, h, budgetMs) {
      const S = Session(w, h, { budgetMs }); S.update(base, true);
      return S.update(base + '\n;\n' + frag + '\n', true);
    }
    return { statementEnds, statementScanner, runCode, Session, clean, attribute, exec };
  }
  const RUNNER = makeRunner(Object.keys(TONES));
  const { statementEnds } = RUNNER;
  const runCode = (code, w, h, o) => RUNNER.runCode(code, w, h, o);

  // ================================================================ the sandbox: the runner inside a Web Worker, no DOM, no network, a time limit
  function workerMain(makeRunner, toneNames) {
    const post = self.postMessage.bind(self), R = makeRunner(toneNames);
    let session = null;
    self.addEventListener('message', ev => {
      const q = ev.data || {};
      try {
        if (q.type === 'init') { session = R.Session(q.w, q.h, { budgetMs: q.budgetMs }); post({ type: 'ready' }); }
        else if (q.type === 'run') post(Object.assign({ type: 'result', id: q.id }, session.update(q.code, q.done)));
        else if (q.type === 'exec') post(Object.assign({ type: 'exec', id: q.id }, R.exec(q.base, q.code, q.w, q.h, q.budgetMs)));
        else if (q.type === 'attrib') post({ type: 'attrib', id: q.id, stmts: R.attribute(q.code, q.w, q.h) });
      } catch (e) { post({ type: 'result', id: q.id, marks: [], says: [], warnings: [], error: 'sandbox: ' + e.message }); }
    });
    for (const k of ['fetch', 'XMLHttpRequest', 'WebSocket', 'EventSource', 'WebTransport', 'importScripts', 'indexedDB', 'caches', 'BroadcastChannel',
      'Worker', 'SharedWorker', 'postMessage', 'close', 'setTimeout', 'setInterval', 'navigator', 'location', 'Request', 'Response', 'Notification', 'FileReader', 'FileReaderSync']) {
      try { delete self[k]; } catch (_) {}
      try { Object.defineProperty(self, k, { value: undefined, writable: false, configurable: false }); } catch (_) {}
    }
  }
  let WORKER_URL = null;
  const workerSource = () => `(${workerMain.toString()})(${makeRunner.toString()}, ${JSON.stringify(Object.keys(TONES))});`;
  function WorkerRunner(W, H, o, onResult) {
    let w;
    try {
      if (!WORKER_URL) WORKER_URL = URL.createObjectURL(new Blob([workerSource()], { type: 'text/javascript' }));
      w = new Worker(WORKER_URL);
    } catch (e) { return null; }
    const limit = o.timeLimit || 1500;
    let inflight = null, pending = null, dead = false, timer = null, id = 0;
    const kill = msg => { if (dead) return; dead = true; clearTimeout(timer); w.terminate(); onResult({ marks: [], says: [], warnings: [], error: msg }, true); };
    function send(job) {
      if (dead) return;
      if (inflight) { pending = job; return; }            // a newer prefix supersedes a queued one
      inflight = job; w.postMessage({ type: 'run', id: ++id, code: job.code, done: job.done });
      timer = setTimeout(() => kill(`the drawing program ran longer than ${limit} ms and was stopped (kept what it drew before)`), limit);
    }
    w.onmessage = ev => {
      const r = ev.data || {};
      if (r.type !== 'result' || dead) return;
      clearTimeout(timer); const job = inflight; inflight = null;
      onResult(r, job && job.done);
      if (pending) { const p = pending; pending = null; send(p); }
    };
    w.onerror = e => kill('sandbox error: ' + (e.message || 'unknown'));
    w.postMessage({ type: 'init', w: W, h: H, budgetMs: Math.round(limit * 0.8) });
    return { run: (code, done) => send({ code, done }), stop: () => { dead = true; clearTimeout(timer); w.terminate(); }, sandboxed: true };
  }
  // 1.6: one job ('exec' or 'attrib') in a fresh throwaway worker, with the same limits as the drawing's own worker
  function sandboxJob(msg, limit) {
    limit = limit || 1500;
    return new Promise((res, rej) => {
      let w;
      try { if (!WORKER_URL) WORKER_URL = URL.createObjectURL(new Blob([workerSource()], { type: 'text/javascript' })); w = new Worker(WORKER_URL); }
      catch (e) { rej(e); return; }
      const timer = setTimeout(() => { w.terminate(); rej(new Error(`the edit's code ran longer than ${limit} ms and was stopped`)); }, limit);
      w.onmessage = ev => { const r = ev.data || {}; if (r.type === 'ready') { w.postMessage(Object.assign({ budgetMs: Math.round(limit * 0.8) }, msg)); return; } clearTimeout(timer); w.terminate(); res(r); };
      w.onerror = e => { clearTimeout(timer); w.terminate(); rej(new Error('sandbox error: ' + (e.message || 'unknown'))); };
      w.postMessage({ type: 'init', w: msg.w, h: msg.h, budgetMs: Math.round(limit * 0.8) });
    });
  }

  // ================================================================ timing model: how long the pen takes for each mark (DOM-free)
  // ReferenceRenderer screen canvas: pen speed is settable (MateDraw.setPen); the defaults are v2's.
  // Also settable there: `ease` (the pen's CSS timing function), `halo` ({'#FFFFFF': [colour, opacity, width]}:
  // an outline drawn under strokes of that ink, instead of the page's blurred CSS shadows) and `wash`
  // (false drops the watercolour displacement filter on fills). Filters and blurs re-render every frame
  // while a stroke animates, which is costly on a full-screen Retina canvas.
  const PEN = { per: 600, base: 0, min: 0.14, max: 0.7, ease: null, halo: null, wash: true, washMaxArea: Infinity };
  const penDur = len => Math.max(PEN.min, Math.min(PEN.max, PEN.base + len / PEN.per));
  function setPen(o) {
    if (!o) return Object.assign({}, PEN);
    for (const k of ['per', 'base', 'min', 'max', 'washMaxArea']) if (typeof o[k] === 'number' && (o[k] > 0 || k === 'base')) PEN[k] = o[k];
    if ('ease' in o) PEN.ease = typeof o.ease === 'string' ? o.ease : null;
    if ('halo' in o) PEN.halo = o.halo && typeof o.halo === 'object' ? o.halo : null;
    if ('wash' in o) PEN.wash = o.wash !== false;
    return Object.assign({}, PEN);
  }
  // ReferenceRenderer: steps are counted per turn (a continued drawing starts its steps again), so a step is known by both
  const stepKey = m => m && m.turn ? m.turn + '/' + m.step : m && m.step;
  // ReferenceRenderer: a mark with `together: true` starts with the next one instead of before it (a gel pill's stacked
  // fills appear as one piece, not layer by layer).
  function natural(m) { const n = naturalAlone(m); return m && m.together ? { dur: n.dur, adv: 0 } : n; }
  function naturalAlone(m) {
    const L = pts => { let s = 0; if (!Array.isArray(pts)) return 0; for (let i = 1; i < pts.length; i++) if (pts[i] && pts[i - 1]) s += Math.hypot(pts[i][0] - pts[i - 1][0], pts[i][1] - pts[i - 1][1]) || 0; return s; };
    const sd = penDur;
    let dur = 0.3;
    switch (m.do) {
      // an edit takes as long as its animation (estimated from what it touches when the stream planned it)
      case 'edit': { const e = m.__est != null ? m.__est : editEstimate(m.op, null); return { dur: e, adv: e }; }
      case 'line': if (m.dash && Array.isArray(m.marquee)) return { dur: MARQUEE_DUR, adv: MARQUEE_DUR * 0.8 };
        dur = m.dash ? Math.min(0.9, 0.2 + L(m.pts) / 900) : sd(L(m.pts)); break;
      case 'arrow': { const d = sd(L(m.pts)); return { dur: d + 0.16, adv: d + 0.1 }; }
      case 'circle': case 'ellipse': { const rx = +(m.r || m.rx) || 10, ry = +(m.r || m.ry) || 10; dur = m.outline === false ? 0.3 : sd(Math.PI * (rx + ry) * 1.06); break; }
      case 'rect': dur = m.outline === false ? 0.3 : sd(2 * (Math.abs(+m.w || 0) + Math.abs(+m.h || 0))); break;
      // a marquee frame's tint opens with its outline, which starts at the same moment
      case 'poly': if (Array.isArray(m.marquee) && m.outline === false) return { dur: MARQUEE_DUR, adv: 0 };
        dur = m.outline === false ? 0.3 : sd(L((m.pts || []).concat(m.pts && m.pts.length ? [m.pts[0]] : []))); break;
      case 'path': { const nums = String(m.d || '').match(/-?\d*\.?\d+/g) || [], pts = []; for (let i = 0; i + 1 < nums.length; i += 2) pts.push([+nums[i], +nums[i + 1]]); dur = /[a-z]/.test(String(m.d).replace(/e-/g, '')) ? 0.4 : sd(L(pts)); break; }
      case 'dot': return { dur: 0.25, adv: 0.06 };
      case 'highlight': dur = 0.35; break;
      case 'text': { const n = String(m.text).length; return { dur: 0.4 + n * 0.015, adv: (0.35 + n * 0.012) * 0.7 }; }
      case 'molecule': dur = 0.6; break;
      case 'stage3d': return { dur: 0.35, adv: 0.12 };
      case 'image': return { dur: 0.5, adv: 0.3 };
      case 'window': return { dur: 0.45, adv: 0.3 };
      case 'part3d': return { dur: 0.65, adv: 0.12 };
      case 'label3d': { const n = String(m.text).length; return { dur: 0.4 + n * 0.015, adv: (0.35 + n * 0.012) * 0.7 }; }
      case 'motion3d': case 'camera3d': case 'tick3d': return { dur: 0, adv: 0 };
    }
    return { dur, adv: dur * 0.7 };
  }
  // ReferenceRenderer: how long an edit op takes at pace 1, given the marks it touches (null: not known yet). The editor's ops
  // run at these speeds: erasing runs each pen backwards in 0.4 s (staggered, capped), repainting redraws at 0.55 pace.
  const ERASE_DUR = 0.4, REPAINT_PACE = 0.55, GLIDE_DUR = 0.5, BRISK = { stagger: 0.03, spread: 0.3 };
  const eraseStagger = (n, brisk) => n > 1 ? Math.min(brisk ? BRISK.stagger : 0.05, (brisk ? BRISK.spread : 0.5) / (n - 1)) : 0;
  function editEstimate(op, touched) {
    const kind = op && op.op, n = touched ? touched.length : null;
    if (kind === 'turn') return 0;
    if (n === 0) return kind === 'startOver' ? 0.02 : 0.05;      // nothing to change: it takes no time in its beat
    switch (kind) {
      case 'erase': return n == null ? 0.6 : ERASE_DUR + eraseStagger(n, false) * (n - 1);
      case 'startOver': return n == null ? 0.7 : ERASE_DUR + eraseStagger(n, true) * (n - 1);
      case 'move': case 'moveTo': case 'scale': return GLIDE_DUR;
      case 'highlight': return 0.6;
      case 'recolor': case 'restyle': {
        if (!touched) return 0.6;
        let t = 0, end = 0;
        for (const m of touched) { if (!m) continue; const nat = natural(m); end = Math.max(end, t + nat.dur * REPAINT_PACE); t += nat.adv * REPAINT_PACE; }
        return Math.max(0.3, end);
      }
    }
    return 0.3;
  }

  // ================================================================ layout check for shapes (DOM-free, causal: decides as each mark arrives)
  // Boxes that carry a label and partly overlap another labelled box (boxes piled on boxes) are warned about,
  // and the later box with its contents is nudged to the nearest free spot when there is one nearby.
  // Intentional overlaps are kept: one shape inside another (a face on a head, a box on a panel), small edge
  // contacts, small badges on a big box, and shapes of different kinds.
  function Layout(W, H) {
    const cons = [], texts = [], warnings = [], pts = [], areas = [];   // pts: points on lines and dots; areas: bboxes of shapes drawn so far
    let grp = null, overlaps = 0, moved = 0, covered = 0, n = 0;
    // ReferenceRenderer: what an edit erased (or a new turn dropped) is no longer on the paper; startOver clears it all
    const prune = (list, gone) => { let k = 0; for (const x of list) if (!gone(x)) list[k++] = x; list.length = k; };
    function forget(indices) {
      const set = indices instanceof Set ? indices : new Set(indices || []); if (!set.size) return;
      const gone = x => set.has(x.i != null ? x.i : x[2]);
      prune(cons, gone); prune(texts, gone); prune(pts, gone); prune(areas, gone);
      if (grp && set.has(grp.i)) grp = null;
    }
    function reset() { cons.length = texts.length = pts.length = areas.length = 0; grp = null; }
    const tw = (s, size, style) => String(s).length * (size || 20) * (style === 'title' ? 0.56 : 0.47);
    function shapeOf(m) {
      if (m.under) return null;
      if (m.do === 'rect' && Array.isArray(m.at) && isFinite(m.w) && isFinite(m.h)) {
        let [x, y] = m.at, w = +m.w, h = +m.h; if (w < 0) { x += w; w = -w; } if (h < 0) { y += h; h = -h; }
        return { kind: 'box', b: [x, y, x + w, y + h], area: w * h, inside: (px, py) => px >= x && px <= x + w && py >= y && py <= y + h };
      }
      if ((m.do === 'circle' || m.do === 'ellipse') && Array.isArray(m.at)) {
        const [cx, cy] = m.at; let rx = +(m.r || m.rx), ry = +(m.r || m.ry); if (!(rx > 0 && ry > 0)) return null;
        if (m.rot) rx = ry = Math.max(rx, ry);
        return { kind: 'round', b: [cx - rx, cy - ry, cx + rx, cy + ry], area: Math.PI * rx * ry, inside: (px, py) => ((px - cx) / rx) ** 2 + ((py - cy) / ry) ** 2 <= 1 };
      }
      // ReferenceRenderer: a window is a card, like the paper sheet it replaced (a 'poly': words go inside it, it is never nudged)
      if (m.do === 'window' && Array.isArray(m.at) && +m.w > 0 && +m.h > 0) {
        const [x, y] = m.at, w = +m.w, h = +m.h;
        return { kind: 'poly', b: [x, y, x + w, y + h], area: w * h, inside: (px, py) => px >= x && px <= x + w && py >= y && py <= y + h };
      }
      if (m.do === 'poly' && Array.isArray(m.pts) && m.pts.length >= 3 && m.close !== false && m.pts.every(p => Array.isArray(p))) {
        const P = m.pts, xs = P.map(p => p[0]), ys = P.map(p => p[1]);
        let a = 0; for (let i = 0; i < P.length; i++) { const p = P[i], q = P[(i + 1) % P.length]; a += p[0] * q[1] - q[0] * p[1]; }
        const inside = (px, py) => { let c = false; for (let i = 0, j = P.length - 1; i < P.length; j = i++) if ((P[i][1] > py) !== (P[j][1] > py) && px < (P[j][0] - P[i][0]) * (py - P[i][1]) / ((P[j][1] - P[i][1]) || 1e-9) + P[i][0]) c = !c; return c; };
        return { kind: 'poly', b: [Math.min(...xs), Math.min(...ys), Math.max(...xs), Math.max(...ys)], area: Math.abs(a) / 2, inside };
      }
      return null;
    }
    const isContainer = (m, s) => s && s.b[2] - s.b[0] >= 36 && s.b[3] - s.b[1] >= 22 && s.area < 0.4 * W * H && (m.outline !== false || (m.fill && (m.fillAlpha == null || m.fillAlpha >= 0.5)));
    const opaque = m => m.fill && m.fill !== 'none' && (m.fillAlpha == null || m.fillAlpha >= 0.7);
    function inter(a, b, dx = 0, dy = 0) {            // overlap area of shape a (moved by dx, dy) and shape b, by sampling
      const x0 = Math.max(a.b[0] + dx, b.b[0]), y0 = Math.max(a.b[1] + dy, b.b[1]), x1 = Math.min(a.b[2] + dx, b.b[2]), y1 = Math.min(a.b[3] + dy, b.b[3]);
      if (x1 <= x0 || y1 <= y0) return 0;
      const N = 14; let hit = 0;
      for (let i = 0; i < N; i++) for (let j = 0; j < N; j++) { const px = x0 + (i + 0.5) * (x1 - x0) / N, py = y0 + (j + 0.5) * (y1 - y0) / N; if (a.inside(px - dx, py - dy) && b.inside(px, py)) hit++; }
      return hit / (N * N) * (x1 - x0) * (y1 - y0);
    }
    function clash(a, b, dx = 0, dy = 0) {             // an unintended partial overlap between two labelled containers
      const I = inter(a, b, dx, dy); if (!I) return false;
      const small = Math.min(a.area, b.area), big = Math.max(a.area, b.area);
      if (I >= 0.8 * a.area || I >= 0.8 * b.area) return false;       // one sits inside the other on purpose
      if (I < 0.1 * small) return false;                               // edges touching
      if (a.kind !== b.kind || a.kind === 'poly' || small / big < 0.2) return false;   // a badge on a box, ears on a head, a hill on the sea
      return true;
    }
    function tbox(m) {
      const size = m.size || (m.style === 'title' ? 24 : m.style === 'body' ? 17 : 20), wd = m.fit ? Math.min(m.fit[0], tw(m.text, size, m.style)) : tw(m.text, size, m.style);
      const x = m.at[0] - (m.anchor === 'middle' ? wd / 2 : m.anchor === 'end' ? wd : 0);
      return [x, m.at[1] - size * 0.8, x + wd, m.at[1] + size * 0.25];
    }
    function points(m) {
      if (Array.isArray(m.pts)) return m.pts.filter(p => Array.isArray(p));
      if (!Array.isArray(m.at)) return [];
      if (m.do === 'rect' || m.do === 'highlight' || m.do === 'molecule' || m.do === 'stage3d' || m.do === 'image' || m.do === 'window') return [m.at, [m.at[0] + (+m.w || 0), m.at[1] + (+m.h || 0)]];
      if (m.do === 'circle' || m.do === 'ellipse') { const rx = +(m.r || m.rx) || 0, ry = +(m.r || m.ry) || 0; return [[m.at[0] - rx, m.at[1] - ry], [m.at[0] + rx, m.at[1] + ry]]; }
      return [m.at];
    }
    function shift(m, dx, dy, onlyNear) {
      const mv = p => (!onlyNear || onlyNear(p)) ? [p[0] + dx, p[1] + dy] : p;
      if (Array.isArray(m.at)) m.at = mv(m.at);
      if (Array.isArray(m.pts)) m.pts = m.pts.map(p => Array.isArray(p) ? mv(p) : p);
      if (m.do === 'path') m.shift = [(m.shift ? m.shift[0] : 0) + dx, (m.shift ? m.shift[1] : 0) + dy];
    }
    const within = (p, b, pad) => p[0] >= b[0] - pad && p[0] <= b[2] + pad && p[1] >= b[1] - pad && p[1] <= b[3] + pad;
    function add(m, index) {
      const i = index != null ? index : n++;
      if (!m || typeof m !== 'object') return m;
      if (m.do === 'edit' || m.__dropped) return m;          // ReferenceRenderer: edits have no geometry; dropped marks are never drawn
      const sk = stepKey(m);
      // 1. marks that belong to a box we moved come along with it
      if (grp) {
        if (sk !== grp.step) grp = null;
        else {
          const s0 = shapeOf(m), pts = points(m);
          if (isContainer(m, s0) && !(within([s0.b[0], s0.b[1]], grp.orig, 3) && within([s0.b[2], s0.b[3]], grp.orig, 3))) grp = null;
          else if (pts.length && (m.do === 'line' || m.do === 'arrow')) shift(m, grp.d[0], grp.d[1], p => within(p, grp.orig, 12));
          else if (pts.length && pts.every(p => within(p, grp.orig, 3))) shift(m, grp.d[0], grp.d[1]);
        }
      }
      // occupancy: what is already on the paper (a box may only be nudged into empty paper)
      if ((m.do === 'line' || m.do === 'arrow') && Array.isArray(m.pts)) { const P = m.pts.filter(p => Array.isArray(p)); for (let k = 0; k < P.length; k++) { pts.push([P[k][0], P[k][1], i]); if (k) { const L = Math.hypot(P[k][0] - P[k - 1][0], P[k][1] - P[k - 1][1]); for (let q = 1; q < L / 8; q++) pts.push([P[k - 1][0] + (P[k][0] - P[k - 1][0]) * q * 8 / L, P[k - 1][1] + (P[k][1] - P[k - 1][1]) * q * 8 / L, i]); } } }
      else if (m.do === 'dot' && Array.isArray(m.at)) pts.push([m.at[0], m.at[1], i]);
      else if (m.do === 'path') { const nums = String(m.d || '').match(/-?\d*\.?\d+/g) || []; if (!/[a-z]/.test(String(m.d).replace(/e-/g, ''))) for (let k = 0; k + 1 < nums.length; k += 2) pts.push([+nums[k] + (m.shift ? m.shift[0] : 0), +nums[k + 1] + (m.shift ? m.shift[1] : 0), i]); }
      else if (m.do !== 'text') { const s1 = shapeOf(m), P = points(m); const b = s1 ? s1.b : P.length === 2 ? [Math.min(P[0][0], P[1][0]), Math.min(P[0][1], P[1][1]), Math.max(P[0][0], P[1][0]), Math.max(P[0][1], P[1][1])] : null; if (b && (b[2] - b[0]) * (b[3] - b[1]) < 0.4 * W * H) areas.push({ b, i }); }
      // 2. a text labels the most recent container it sits in
      if (m.do === 'text' && Array.isArray(m.at) && m.text != null) {
        const b = tbox(m), cx = (b[0] + b[2]) / 2, cy = (b[1] + b[3]) / 2;
        b.i = i; texts.push(b);
        for (let k = cons.length - 1; k >= 0; k--) if (cons[k].inside(cx, cy)) { cons[k].labelled = true; if (!cons[k].label) cons[k].label = String(m.text).slice(0, 24); break; }
        return m;
      }
      // 3. a new container: check it against the labelled ones drawn before
      const s = shapeOf(m);
      if (!isContainer(m, s)) return m;
      const c = Object.assign(s, { i, step: m.step, sk, labelled: false, label: '', opaque: opaque(m) });
      const hit = cons.find(o => o.labelled && clash(c, o));
      if (hit) {
        const box = (dx, dy) => [c.b[0] + dx, c.b[1] + dy, c.b[2] + dx, c.b[3] + dy];
        const ov = (A, B) => Math.max(0, Math.min(A[2], B[2]) - Math.max(A[0], B[0])) * Math.max(0, Math.min(A[3], B[3]) - Math.max(A[1], B[1]));
        const ok = (dx, dy) => c.b[0] + dx >= 6 && c.b[1] + dy >= 6 && c.b[2] + dx <= W - 6 && c.b[3] + dy <= H - 6
          && !cons.some(o => (o.labelled && clash(c, o, dx, dy)) || (inter(c, o, dx, dy) > 0.12 * c.area && inter(c, o, dx, dy) < 0.8 * o.area))
          && !pts.some(p => within(p, box(dx, dy), 4))                                                    // no strokes where it would land
          && !areas.some(a => a.i !== i && ov(a.b, box(dx, dy)) > 0.08 * c.area && !(ov(a.b, box(dx, dy)) >= 0.95 * c.area && ov(a.b, c.b) >= 0.95 * c.area))
          && !texts.some(t => { const x0 = Math.max(t[0], c.b[0] + dx), x1 = Math.min(t[2], c.b[2] + dx), y0 = Math.max(t[1], c.b[1] + dy), y1 = Math.min(t[3], c.b[3] + dy); return x1 > x0 && y1 > y0 && (x1 - x0) * (y1 - y0) > 0.3 * (t[2] - t[0]) * (t[3] - t[1]); });
        const maxShift = 0.22 * Math.min(W, H), cands = [];
        for (let r = 8; r <= maxShift; r += 8) for (const [ux, uy] of [[0, 1], [1, 0], [-1, 0], [0, -1], [1, 1], [-1, 1], [1, -1], [-1, -1]]) cands.push([ux * r, uy * r]);
        for (const o of [hit]) cands.push([o.b[2] + 10 - c.b[0], 0], [o.b[0] - 10 - c.b[2], 0], [0, o.b[3] + 10 - c.b[1]], [0, o.b[1] - 10 - c.b[3]]);
        const best = cands.filter(([dx, dy]) => Math.hypot(dx, dy) <= maxShift * 1.1).sort((p, q) => Math.hypot(...p) - Math.hypot(...q)).find(([dx, dy]) => ok(dx, dy));
        if (best) {
          const orig = c.b.slice();
          shift(m, best[0], best[1]); c.b = [c.b[0] + best[0], c.b[1] + best[1], c.b[2] + best[0], c.b[3] + best[1]];
          const inside0 = c.inside; c.inside = (px, py) => inside0(px - best[0], py - best[1]);
          grp = { orig, d: best, step: sk, i }; moved++;
          warnings.push(`moved a box ${Math.round(best[0])},${Math.round(best[1])} so it no longer covers the box "${hit.label}"`);
        } else { overlaps++; warnings.push(`the box at ${Math.round(c.b[0])},${Math.round(c.b[1])} overlaps the box "${hit.label}"`); }
      } else if (c.opaque) {
        const cov = cons.find(o => o.labelled && o.sk !== c.sk && inter(c, o) > 0.2 * o.area && inter(c, o) < 0.8 * o.area && inter(c, o) < 0.8 * c.area);
        if (cov) { covered++; warnings.push(`a shape in step ${c.step} covers part of the labelled shape "${cov.label}" from step ${cov.step}`); }
      }
      cons.push(c);
      return m;
    }
    return { add, forget, reset, warnings, get overlaps() { return overlaps; }, get moved() { return moved; }, get covered() { return covered; } };
  }
  // plan(m, i) (ReferenceRenderer, optional): for an edit mark, {reset} (startOver) or {forget: [mark indices it erases]}
  function layoutMarks(marks, W, H, plan) {
    const L = Layout(W, H);
    for (let i = 0; i < marks.length; i++) {
      const m = marks[i];
      if (m && m.do === 'edit') { const p = plan && plan(m, i); if (p && p.reset) L.reset(); else if (p && p.forget) L.forget(p.forget); continue; }
      marks[i] = L.add(m, i);
    }
    return L;
  }

  // ================================================================ pacing to speech (DOM-free)
  // Each say() line owns the strokes that follow it (up to the next say()). Strokes in a step that come
  // before the step's first say() belong to that say(); a step with no say() joins the line before it.
  // A line's strokes wait until the line starts being spoken, then spread across its spoken duration.
  // Line times are estimated (words / wps, lines back to back) or given by the host (lineStart/lineEnd/spoken).
  function Pacer(o) {
    o = o || {};
    const wps = o.wps || 2.6, gap = o.gap != null ? o.gap : 0.25, est = o.speech !== 'external', lead = o.lead != null ? o.lead : 0.08, tail = o.tail != null ? o.tail : 0.12;
    // ReferenceRenderer screen canvas: how much a line may speed its strokes up (FAST) or slow them down (SLOW) to fit it
    const FAST = o.minPace != null ? o.minPace : 0.35, SLOW = o.maxSlow != null ? o.maxSlow : 2;
    // ReferenceRenderer screen canvas: how far a line too full for its time (or one starting late) may hurry its strokes,
    // so its marks still end with its words. Without it, a crowded line stays at FAST and runs over.
    const RUSH = o.rushPace != null ? Math.min(o.rushPace, FAST) : FAST;
    // ReferenceRenderer screen canvas: how far gaps between strokes may stretch to fill a line. Capped, an object's
    // parts (a sticky's paper and words, a badge's ring and number) stay together and spare time is a rest
    // at the end of the line instead of pauses inside the drawing.
    const MAXSPREAD = o.maxSpread != null ? o.maxSpread : Infinity;
    const lines = [], items = [];
    let closed = -1, all = false, rel = 0, rush = false;
    const count = s => String(s).trim().split(/\s+/).filter(Boolean).length;
    function addLine(text, t) { const p = lines[lines.length - 1]; lines.push({ k: lines.length, text, words: count(text), arrive: t, start: null, end: null, cum: p ? p.cum + p.words : 0 }); return lines.length - 1; }
    function add(m, i, t, nat) { const it = { m, i, arrive: t, line: undefined, dur: nat.dur, adv: nat.adv, t: null, p: 1, rt: null }; items.push(it); return it; }
    function times(k, memo) {
      if (k in memo) return memo[k];
      const L = lines[k]; let r = null;
      if (L) {
        let s = L.start;
        if (s == null && est) { const pe = k ? times(k - 1, memo) : null; if (!k || pe) s = Math.max(L.arrive, pe ? pe[1] + gap : L.arrive); }
        if (s != null) { const e = L.end != null ? L.end : s + L.words / wps; r = [s, Math.max(e, s + 0.2)]; }
      }
      return (memo[k] = r);
    }
    function plan(now) {
      if (rush) { let t = now; for (let i = rel; i < items.length; i++) { const it = items[i]; it.t = t; it.p = 0.35; it.gap = it.adv * 0.12; t += it.gap; } return; }  // finishNow: everything, quickly, in order
      const memo = {}, last = rel ? items[rel - 1] : null;
      let cursor = last ? Math.max(now, last.rt + last.gap) : now, i = rel;
      while (i < items.length) {
        const k = items[i].line;
        if (k === undefined) break;                             // still waiting for its say(): hold it and everything after it
        let j = i; while (j < items.length && items[j].line === k) j++;
        const grp = items.slice(i, j);
        if (k < 0) { for (const it of grp) { it.t = cursor; it.p = 1; it.gap = it.adv; cursor += it.adv; } i = j; continue; }
        const T = times(k, memo); if (!T) break;
        const ws = Math.max(cursor, T[0] + lead), avail = T[1] - tail - ws, isClosed = all || k <= closed;
        const A = grp.reduce((a, it, q) => a + (q < grp.length - 1 ? it.adv : 0), 0), dl = grp[grp.length - 1].dur;
        // spread so the last stroke ends as the line ends: gaps grow by `spread`, strokes slow down by at most SLOW
        let f = avail <= 0.05 ? 0 : avail / (A + dl || 0.1);
        if (!isClosed) f = Math.min(f, 1.3);                  // an open line may still get more strokes
        let p, spread;
        if (f < FAST) {
          // Too much for its time, or the line before ran over: strokes and gaps shrink together (down to RUSH) so
          // this line's marks end with its words and never push the next line's marks back.
          p = spread = Math.max(RUSH, f);
        } else {
          p = Math.min(f, SLOW); spread = f;
          if (isClosed && f > SLOW && A > 0) spread = Math.max(SLOW, (avail - SLOW * dl) / A);
        }
        spread = Math.min(spread, MAXSPREAD);
        let t = ws; for (const it of grp) { it.t = t; it.p = p; it.gap = it.adv * spread; t += it.gap; }
        cursor = t; i = j;
      }
      for (; i < items.length; i++) items[i].t = null;
    }
    function due(now) {
      const out = [];
      for (;;) { plan(now); const it = items[rel]; if (!it || it.t == null || it.t > now + 0.004) break; it.rt = now; rel++; out.push(it); }
      return out;
    }
    return {
      lines, items, addLine, add,
      assign: (it, k) => { it.line = k; }, close: k => { closed = Math.max(closed, k); }, closeAll: () => { all = true; }, rush: () => { rush = true; }, get rushed() { return rush; },
      start: (k, t) => { if (lines[k] && lines[k].start == null) lines[k].start = t; },
      end: (k, t) => { if (lines[k]) { if (lines[k].start == null) lines[k].start = t; lines[k].end = t; } },
      due, nextAt: now => { plan(now); const it = items[rel]; return it && it.t != null ? it.t : null; },
      empty: () => rel >= items.length, times: k => times(k, {}),
      // ReferenceRenderer (a new turn on the same card): items not released yet whose mark matches `gone(i)` are dropped;
      // reopen() takes more lines and strokes after the program was done
      drop: gone => { const out = []; for (let q = items.length - 1; q >= rel; q--) if (gone(items[q].i)) out.push(items.splice(q, 1)[0]); return out; },
      reopen: () => { all = false; rush = false; }
    };
  }

  // ================================================================ stream: runner + layout + pacer; calls onDraw when marks should be drawn (DOM-free)
  function Stream(spec, o) {
    const scanStatements = RUNNER.statementScanner();
    o = o || {};
    const W = spec.w || 400, H = spec.h || 300;
    const clk = o.clock || { now: () => performance.now() / 1000, set: (f, s) => setTimeout(f, s * 1000), clear: id => clearTimeout(id) };
    const t0 = clk.now(), now = () => clk.now() - t0;
    const paced = !!o.pace && o.pace !== 'off';
    const P = paced ? Pacer({ wps: o.wps, gap: o.gap != null ? o.gap : (o.continuous ? 0 : 0.25), speech: o.speech || 'estimate', lead: o.lead, tail: o.tail, minPace: o.minPace, maxSlow: o.maxSlow, maxSpread: o.maxSpread, rushPace: o.rushPace }) : null;
    const lay = o.layout === false ? null : Layout(W, H);
    const report = { errors: [], warnings: [] }, lines = [], log = { marks: [], lines: [], paced, mode: null };
    let nMarks = 0, curStep = null, curLine = null, waiting = [], lastLine = -1, doneSeen = false, finished = false, timer = null, sent = -1, fresh = [];
    // 1.6: every mark that has arrived (drawn or still waiting for its line), the code run so far, and pausing
    const all = [];
    let src = '', paused = false, held = [];
    // ReferenceRenderer: the marks handed to the painter so far (the rest are still waiting for their line)
    const released = new Set();
    const drawNow = (ms, d) => { if (paused && !(d && d.paced)) { held.push([ms, d]); return; } if (o.onDraw) o.onDraw(ms, d); };
    // which say() line owns each mark, recorded in the log as it streams (same rule as the pacer; also when unpaced)
    // (ReferenceRenderer: steps are keyed by turn and step, stepKey)
    let oStep = null, oLine = null, oLast = -1, oWait = [];
    const ownClose = () => { for (const e of oWait) e.line = oLast; oWait = []; };
    const ownSay = (s, k) => { if (stepKey(s) !== oStep) { ownClose(); oStep = stepKey(s); } for (const e of oWait) e.line = k; oWait = []; oLine = k; oLast = k; };
    const ownMark = (e, m) => { if (stepKey(m) !== oStep) { ownClose(); oStep = stepKey(m); oLine = null; } if (oLine != null) e.line = oLine; else oWait.push(e); };
    function closeStep() { if (waiting.length) { for (const it of waiting) P.assign(it, lastLine); waiting = []; } }
    function handleSay(s, t) {
      lines.push(s.text); fresh.push(s.text);
      const k = lines.length - 1;
      log.lines.push(s.turn ? { k, text: s.text, arrive: t, step: s.step, turn: s.turn } : { k, text: s.text, arrive: t, step: s.step });
      ownSay(s, k);
      if (!paced) return;
      if (stepKey(s) !== curStep) { closeStep(); curStep = stepKey(s); }
      P.addLine(s.text, t); P.close(k - 1);
      for (const it of waiting) P.assign(it, k); waiting = [];
      curLine = k; lastLine = k;
    }
    // ReferenceRenderer: marks of earlier turns in [keep, upto) that were never drawn leave for good (never drawn later, not on the card)
    function dropRange(keep, upto) {
      const gone = [];
      for (let i = Math.max(0, keep); i < upto; i++) {
        const m = all[i];
        if (!m || released.has(i) || (m.do === 'edit' && m.op && m.op.op === 'turn')) continue;
        m.__skip = m.__erased = m.__dropped = true; gone.push(i);
      }
      if (!gone.length) return gone;
      const set = new Set(gone);
      if (P) P.drop(i => set.has(i));
      waiting = waiting.filter(it => !set.has(it.i));
      if (lay) lay.forget(set);
      for (const e of log.marks) if (set.has(e.i)) e.dropped = true;
      return gone;
    }
    // __turn(n, keep): a new turn on the same card starts here
    function handleTurn(m, gi, t, batch) {
      if (m.op.keep != null) dropRange(m.op.keep, gi);
      ownClose(); oStep = stepKey(m); oLine = null;
      if (paced) { closeStep(); curStep = stepKey(m); curLine = null; }
      released.add(gi); all[gi] = m;
      log.marks.push({ i: gi, arrive: t, do: 'edit', op: 'turn', step: m.step, dur: 0, adv: 0, rt: t });
      if (!paced) batch.push(m);                          // painted as nothing, so unpaced batches keep their indices
    }
    function handleMark(m, gi, t, batch) {
      if (m.do === 'edit') {
        if (m.op && m.op.op === 'turn') { handleTurn(m, gi, t, batch); return; }
        // an edit has no geometry; what it erases leaves the layout (startOver: everything)
        const plan = o.planEdit ? o.planEdit(m, gi) : null;
        if (plan && lay) { if (plan.reset) lay.reset(); else if (plan.forget) lay.forget(plan.forget); }
      } else if (lay) m = lay.add(m, gi);
      let nat = natural(m);
      // ReferenceRenderer screen canvas: one ink stroke at a time (fills and dots still land together)
      if (o.sequential && m.outline !== false && m.do !== 'dot') nat = { dur: nat.dur, adv: Math.max(nat.adv, nat.dur + 0.03) };
      const entry = { i: gi, arrive: t, do: m.do, step: m.step, dur: nat.dur, adv: nat.adv, rt: paced ? null : t };
      log.marks.push(entry); ownMark(entry, m); all[gi] = m;
      if (!paced) { released.add(gi); batch.push(m); return; }
      if (stepKey(m) !== curStep) { closeStep(); curStep = stepKey(m); curLine = null; }
      const it = P.add(m, gi, t, nat);
      if (curLine != null) P.assign(it, curLine); else waiting.push(it);
    }
    function ingest(r, done) {
      const t = now(), batch = [], ms = r.marks || [], ss = r.says || [];
      if (r.mode) log.mode = r.mode;
      let si = 0;
      for (let j = 0; j <= ms.length; j++) {
        while (si < ss.length && ss[si].at <= nMarks + j) handleSay(ss[si++], t);
        if (j < ms.length) handleMark(ms[j], nMarks + j, t, batch);
      }
      while (si < ss.length) handleSay(ss[si++], t);
      nMarks += ms.length;
      for (const w of r.warnings || []) report.warnings.push(w);
      if (r.error) report.errors.push(r.error);
      if (batch.length) drawNow(batch, {});
      if (done && !doneSeen) { doneSeen = true; ownClose(); if (paced) { closeStep(); P.closeAll(); } }
      if (paced) kick(); else if (doneSeen && !paused) finishUp();
      const out = fresh; fresh = [];
      if (out.length && o.onSay) o.onSay(out);
      return out;
    }
    function finishUp() {
      if (finished) return; finished = true;
      if (lay) { for (const w of lay.warnings) report.warnings.push(w); report.shapeOverlaps = lay.overlaps; report.nudged = lay.moved; report.covered = lay.covered; }
      if (paced) {
        log.lines.forEach(L => { const T = P.times(L.k); if (T) { L.start = T[0]; L.end = T[1]; } });
        const byI = new Map(log.marks.map(x => [x.i, x]));
        for (const it of P.items) { const L = byI.get(it.i); if (L) { L.rt = it.rt; L.p = it.p; L.line = it.line; } }
      }
      if (runner && runner.stop && o.sandbox === 'worker') runner.stop();
      if (o.onDone) o.onDone(report, log);
    }
    function tick() {
      timer = null; if (finished || paused) return;
      const t = now();
      for (const it of P.due(t)) { released.add(it.i); drawNow([it.m], { paced: true, pace: it.p, i: it.i }); }
      const nx = P.nextAt(t);
      if (nx != null) timer = clk.set(tick, Math.max(0.001, nx - t));
      else if (doneSeen && P.empty()) finishUp();
    }
    function kick() { if (timer != null) clk.clear(timer); timer = null; tick(); }
    let runner = null;
    if (o.sandbox === 'worker' && typeof Worker !== 'undefined') runner = WorkerRunner(W, H, o, (r, done) => ingest(r, !!done));
    const sandboxed = !!runner;
    const syncRunner = S => ({ run: (code, done, knownEnds) => ingest(S.update(code, done, knownEnds), done), sync: true, get code() { return S.code; }, get mode() { return S.mode; }, get live3d() { return S.live3d; } });
    if (!runner) runner = syncRunner(RUNNER.Session(W, H, { incremental: o.incremental }));
    return {
      // code: everything received so far. Returns the new say() lines (sandboxed runs deliver them through onSay instead).
      update(code, done = false) {
        if (doneSeen) return [];
        const ends = scanStatements(code), upto = done ? code.length : (ends.length ? ends[ends.length - 1] : 0);
        if (upto <= sent && !done) return [];
        sent = upto; src = code.slice(0, upto);
        // The stream already found these boundaries; execution only needs the ones in its new tail.
        const r = runner.run(src, done, ends);
        return runner.sync ? r : [];
      },
      // the host tells the engine when a line is actually heard (seconds since live() started; default: now)
      lineStart(k, t) { if (P) { P.start(k, t != null ? t : now()); kick(); } },
      lineEnd(k, t) { if (P) { P.end(k, t != null ? t : now()); kick(); } },
      // continuous speech: n words of the joined narration have been heard so far
      spoken(n, t) {
        if (!P) return; const tt = t != null ? t : now();
        for (const L of P.lines) { if (L.start == null && n > L.cum) P.start(L.k, tt); if (L.end == null && n >= L.cum + L.words) P.end(L.k, tt); }
        kick();
      },
      stop() { if (timer != null) clk.clear(timer); timer = null; finished = true; if (runner.stop) runner.stop(); },
      // draw every stroke still waiting for its line now, quickly and in order; strokes that stream in later are drawn on arrival.
      // The host's voice carries on; lineStart/lineEnd are still recorded. No effect when unpaced or finished.
      finishNow() { if (!P || finished) return; P.rush(); kick(); },
      get rushed() { return !!(P && P.rushed); },
      // 1.6: hold the pen after the stroke it is drawing (code keeps arriving and waits); resume() carries on
      pause() { if (paused || finished) return; paused = true; if (timer != null) clk.clear(timer); timer = null; },
      resume() {
        if (!paused) return; paused = false;
        const q = held; held = []; for (const [ms, d] of q) if (o.onDraw) o.onDraw(ms, d);
        if (paced) kick(); else if (doneSeen) finishUp();
      },
      get paused() { return paused; }, get finished() { return finished; }, get done() { return doneSeen; },
      marks: all, get code() { return src; },
      report, log, lines, sandboxed, now,
      // ReferenceRenderer, for a continued turn on the same card:
      // the program the runner has actually run (complete statements; src can be ahead of it while a statement waits to parse)
      get ran() { return runner.code != null ? runner.code : src; }, get runMode() { return runner.mode || null; },
      // three-metal: the live run's figure() tick functions and poses (null in the worker sandbox)
      get live3d() { return runner.live3d || null; },
      get count() { return nMarks; }, isReleased: i => released.has(i),
      // drop every mark not drawn yet (the user interrupted); returns the first dropped index (nMarks when none)
      dropPending() {
        let keep = nMarks;
        for (let i = 0; i < nMarks; i++) { const m = all[i]; if (m && !released.has(i) && !(m.do === 'edit' && m.op && m.op.op === 'turn')) { keep = i; break; } }
        dropRange(keep, nMarks); held = [];
        return keep;
      },
      // take more code after the program was done
      reopen(code) { if (code != null && !sandboxed) { src = code; sent = code.length; } doneSeen = false; finished = false; if (P) P.reopen(); },
      // start the runner again on `code` (its first `count` marks are the ones already here), after the old run failed
      rebase(code, count) {
        if (sandboxed) return false;
        const S = RUNNER.Session(W, H, { incremental: o.incremental }); S.update(code, false);
        runner = syncRunner(S); src = code; sent = code.length;
        for (let i = count; i < all.length; i++) released.delete(i);
        all.length = Math.min(all.length, count); nMarks = count;
        return true;
      }
    };
  }

  // ================================================================ render
  let SURFACES = 0;
  function surfaceFor(spec, host, opts = {}) {
    const uid = 'cd' + (++SURFACES) + '_';            // ids unique per card, so several cards can share a page
    const W = spec.w || 400, H = spec.h || 300, surface = spec.surface || 'card', t0 = performance.now();
    const defInk = surface === 'sky' ? 'white' : 'ink';
    const NS = 'http://www.w3.org/2000/svg';
    const svg = document.createElementNS(NS, 'svg');
    svg.setAttribute('viewBox', `0 0 ${W} ${H}`); svg.setAttribute('width', opts.width || W * 2); svg.setAttribute('height', (opts.width || W * 2) * H / W);
    svg.innerHTML = `<defs><filter id="wash" x="-10%" y="-10%" width="120%" height="120%"><feTurbulence type="fractalNoise" baseFrequency="0.035" numOctaves="2" seed="3"/><feDisplacementMap in="SourceGraphic" scale="3.5"/></filter>
      <filter id="grain"><feTurbulence type="fractalNoise" baseFrequency="0.9" numOctaves="1" seed="7" result="n"/><feColorMatrix in="n" type="matrix" values="0 0 0 0 0  0 0 0 0 0  0 0 0 0 0  0 0 0 -1.2 1.1" result="a"/><feComposite in="SourceGraphic" in2="a" operator="in"/></filter></defs>
      <g id="__probe" style="visibility:hidden"></g><g id="under"></g><g id="main"></g><g id="hl"></g><g id="words"></g>`;
    host.appendChild(svg);
    const under = svg.querySelector('#under'), main = svg.querySelector('#main'), hlLayer = svg.querySelector('#hl'), words = svg.querySelector('#words');
    let clock = 0.15, lastStep = null, maskN = 0, delayBase = 0, pace = 1, total = 0, report = { marks: 0, errors: [], warnings: [], engine: VERSION };
    const placed = [];                                     // placed[i] = [start, end] of mark i, seconds since the card was created
    // 1.6: the nodes each mark drew (per layer, in paint order) and its pen masks, so edits can find them again.
    // Only JS references are kept: the SVG itself is exactly what 1.5 drew.
    const NODES = {}, MASKS = {}, MK = {};
    let cap = null, capM = null, capKey = 0, editing = false;
    // ReferenceRenderer: hooks.edit(m, i, startsAt, pace) runs a program's edit mark ({do: 'edit'}) through the card's editor and
    // returns how long it takes (s); set by live() and render()
    const hooks = {};
    // ReferenceRenderer: the role of the mark being painted, kept on each element it makes (label placement ignores the
    // arrows that tie a row to its photo: they cross the card, and the card's words must not move for them)
    let paintingRole = null;
    const el = (tag, attrs, parent) => {
      const e = document.createElementNS(NS, tag); for (const k in attrs) if (attrs[k] != null) e.setAttribute(k, attrs[k]);
      if (paintingRole) e.__role = paintingRole;
      const p = parent || main; p.appendChild(e);
      if (cap && (p === main || p === under || p === hlLayer || p === words)) { e.__k = capKey; cap.push(e); }
      return e;
    };
    const anim = (e, name, dur, delay) => { dur = dur * Math.max(pace, 0.35); e.style.animation = `${name} ${dur.toFixed(2)}s ${name === 'pen' ? (PEN.ease || 'cubic-bezier(.4,.1,.3,1)') : 'ease-out'} ${(delay - delayBase).toFixed(2)}s both`; };

    function stroke(centre, m, colour, size, parent, extra = {}) {
      const d = outline(centre, size, m.taper == null ? 1 : m.taper);
      if (!d) return 0;
      const id = uid + 'm' + (maskN++), dur = penDur(plen(centre));
      const mask = el('mask', { id, maskUnits: 'userSpaceOnUse', x: -W, y: -H, width: W * 3, height: H * 3 }, svg.querySelector('defs'));
      const mp = el('path', { d: poly(centre), fill: 'none', stroke: '#fff', 'stroke-width': size * 2 + 4, 'stroke-linecap': 'round', 'stroke-linejoin': 'round', pathLength: 1, 'stroke-dasharray': '1 1' }, mask);
      anim(mp, 'pen', dur, clock);
      if (capM) capM.push(mp);
      const b = BRUSH[m.brush] || BRUSH.pen;
      // halo: one [colour, opacity, width] or several, widest first (a soft glow without a blur)
      // ReferenceRenderer (2026-10-19): a screen mark's glow, [opacity, radius], is a real blurred shadow in its own colour, like
      // the old walkthrough's SwiftUI .shadow (the app paints it: data-glow). Ink turned white or near-black for contrast
      // keeps the pen's contrast halo instead.
      const halo = PEN.halo && PEN.halo[String(colour).toUpperCase()];
      const glow = !halo && Array.isArray(m.glow) && m.glow.length === 2 && isFinite(+m.glow[0]) && isFinite(+m.glow[1]) ? m.glow : null;
      for (const h of !halo ? [] : Array.isArray(halo[0]) ? halo : [halo])
        el('path', { d, fill: h[0], 'fill-opacity': h[1], stroke: h[0], 'stroke-opacity': h[1], 'stroke-width': h[2], 'stroke-linejoin': 'round', mask: `url(#${id})`, 'data-halo': '1' }, parent);
      el('path', Object.assign({ d, fill: colour, 'fill-opacity': m.alpha != null ? m.alpha : b.alpha, mask: `url(#${id})`, filter: m.brush === 'pencil' ? 'url(#grain)' : null,
        'data-glow': glow ? `${(+glow[0]).toFixed(3)} ${(+glow[1]).toFixed(2)}` : null }, extra), parent);
      return dur;
    }
    // rough area of a fill, for PEN.washMaxArea (big sheets skip the watercolour filter: costly to animate)
    function fillArea(m) {
      if (Array.isArray(m.pts) && m.pts.length) {
        const P = m.pts.filter(p => Array.isArray(p)); if (!P.length) return 0;
        const xs = P.map(p => +p[0] || 0), ys = P.map(p => +p[1] || 0);
        return (Math.max(...xs) - Math.min(...xs)) * (Math.max(...ys) - Math.min(...ys));
      }
      if (m.w && m.h) return Math.abs(m.w * m.h);
      if (m.r) return 4 * m.r * m.r;
      if (m.rx && m.ry) return 4 * m.rx * m.ry;
      return 0;
    }
    function wash(dPath, m, parent, extra) {
      if (!m.fill) return;
      // ReferenceRenderer: `wash: false` on a mark keeps its fill crisp (label pills, number badges)
      const filtered = PEN.wash && m.wash !== false && fillArea(m) <= PEN.washMaxArea;
      const marquee = Array.isArray(m.marquee) && m.outline === false;
      const e = el('path', Object.assign({ d: dPath, fill: tone(m.fill), 'fill-opacity': m.fillAlpha != null ? m.fillAlpha : 1, filter: filtered && !marquee ? 'url(#wash)' : null,
        'data-marquee': marquee ? m.marquee.map(v => (+v || 0).toFixed(2)).join(' ') : null }, extra || {}), parent || under);
      if (marquee) anim(e, 'marquee', MARQUEE_DUR, clock);
      else anim(e, 'fadein', 0.35, clock + (m.outline === false ? 0 : 0.18));
    }

    function placeLabel(t) {
      let b; try { b = t.getBBox(); } catch (_) { return; }
      if (!b.width) return;
      const others = [...words.querySelectorAll('text')].filter(e => e !== t && !e.__gone && e.ownerSVGElement === svg).map(e => { try { const r = e.getBBox(), tr = e.__nudge || [0, 0], xf = e.__wrap && e.__wrap.__xf; const b = { x: r.x + tr[0], y: r.y + tr[1], w: r.width, h: r.height }; return xf ? { x: b.x * xf[0] + xf[1], y: b.y * xf[0] + xf[2], w: b.w * xf[0], h: b.h * xf[0] } : b; } catch (_) { return null; } }).filter(Boolean);
      // compared by the letters' middle bands: a text box carries its whole line height, so a title and the subtitle
      // 22 units under it "overlapped" by a few units with no letter touching, the subtitle moved down onto the next
      // row, and every row of a list card cascaded after it
      const textHits = (dx, dy) => others.some(o => Math.min(b.x + dx + b.width, o.x + o.w) - Math.max(b.x + dx, o.x) > 3
        && Math.min(b.y + dy + b.height * 0.8, o.y + o.h * 0.8) - Math.max(b.y + dy + b.height * 0.2, o.y + o.h * 0.2) > 1);
      // ReferenceRenderer: drawn shapes are in the way too (a caption written across two little figures). A shape that encloses
      // the label is its container ("User" in its circle, a word in its box) and never pushes it; shapes that only
      // cross it do, once together they cover a fifth of it. Boxes are cached on the element (the app measures paths).
      const shapes = [...main.querySelectorAll('path,circle,ellipse,rect,line,polyline,polygon')].filter(e => !e.__gone && e.ownerSVGElement === svg && !e.getAttribute('data-halo') && e.__role !== 'tie' && e.__role !== 'paper').map(e => {
        if (!e.__bb) { try { const r = e.getBBox(); e.__bb = r && (r.width || r.height) ? { x: r.x, y: r.y, w: r.width, h: r.height } : null; } catch (_) { e.__bb = null; } }
        const o = e.__bb, xf = e.__wrap && e.__wrap.__xf;
        return o && xf ? { x: o.x * xf[0] + xf[1], y: o.y * xf[0] + xf[2], w: o.w * xf[0], h: o.h * xf[0] } : o;
      }).filter(Boolean);
      const shapeCover = (dx, dy) => {
        // the words' middle band: a line that only grazes the label's edge (a heading just above a grid) is not in the way
        const x0 = b.x + dx + b.width * 0.1, y0 = b.y + dy + b.height * 0.25, x1 = b.x + dx + b.width * 0.9, y1 = b.y + dy + b.height * 0.75;
        let area = 0;
        for (const o of shapes) {
          // a shape around the label is its container, not in its way
          if (o.x <= x0 + 2 && o.y <= y0 + 2 && o.x + o.w >= x1 - 2 && o.y + o.h >= y1 - 2) continue;
          // a pen line is a couple of pixels thin but crosses the words all the same: pad it to a legible band
          const pad = 4, ox = o.x - pad, oy = o.y - pad, ow = o.w + 2 * pad, oh = o.h + 2 * pad;
          const ix = Math.min(x1, ox + ow) - Math.max(x0, ox), iy = Math.min(y1, oy + oh) - Math.max(y0, oy);
          if (ix > 2 && iy > 2) area += ix * iy;
        }
        return area / Math.max(1, (x1 - x0) * (y1 - y0));
      };
      const hits = (dx, dy) => textHits(dx, dy) || shapeCover(dx, dy) > 0.2;
      const inside = (dx, dy) => b.x + dx >= 4 && b.y + dy >= 4 && b.x + dx + b.width <= W - 4 && b.y + dy + b.height <= H - 4;
      let best = [0, 0];
      if (!inside(0, 0)) best = [Math.min(Math.max(0, 4 - b.x), W - 4 - b.x - b.width) || Math.max(4 - b.x, Math.min(0, W - 4 - b.x - b.width)), Math.min(Math.max(0, 4 - b.y), H - 4 - b.y - b.height) || Math.max(4 - b.y, Math.min(0, H - 4 - b.y - b.height))];
      // ReferenceRenderer: only short labels dodge each other; a paragraph or list stays where it was written (shoving a
      // 13-line ingredient list sideways to clear its own card's title put it off the card).
      if (!t.querySelector('tspan') && hits(best[0], best[1])) {
        const step = Math.max(10, b.height * 0.9), cands = [];
        for (let k = 1; k <= 5; k++) for (const [ux, uy] of [[0, 1], [0, -1], [1, 0], [-1, 0], [1, 1], [-1, 1], [1, -1], [-1, -1]]) cands.push([best[0] + ux * k * (b.width * 0.35 + 6), best[1] + uy * k * step]);
        cands.sort((p, q) => Math.hypot(p[0] - best[0], (p[1] - best[1]) * 1.6) - Math.hypot(q[0] - best[0], (q[1] - best[1]) * 1.6));
        const free = cands.find(([dx, dy]) => inside(dx, dy) && !hits(dx, dy));
        if (free) { best = free; report.warnings.push(`moved label "${t.textContent.slice(0, 20)}" off another label or shape`); }
      }
      if (best[0] || best[1]) { t.__nudge = best; t.setAttribute('transform', `translate(${best[0].toFixed(1)} ${best[1].toFixed(1)}) ` + (t.getAttribute('transform') || '')); }
    }
    const est = m => m.do === 'dot' ? 0.05 : m.do === 'text' || m.do === 'label3d' ? 0.3 + String(m.text).length * 0.01 : m.do === 'molecule' ? 0.6 : m.do === 'part3d' || m.do === 'stage3d' ? 0.12 : m.do === 'motion3d' || m.do === 'camera3d' || m.do === 'tick3d' ? 0 : m.do === 'edit' ? (m.__est != null ? m.__est : 0.3) : 0.3;
    const BUDGET = spec.stepBudget || 2.6;
    // 1.6: an edit can dash a closed outline (m.__dash). Programs cannot set it, so they draw exactly as in 1.5, where
    // dash only applies to lines and arrows.
    function edge(c, m, colour, size, layer) {
      if (!m.__dash) return stroke(c, m, colour, size, layer);
      const on = typeof m.__dash === 'number' ? m.__dash : Math.max(8, size * 3), pieces = dashes(c, on, on * 0.75), c0 = clock, span = Math.min(0.9, 0.2 + plen(c) / 900);
      pieces.forEach((pc, k) => { clock = c0 + span * k / Math.max(1, pieces.length); stroke(pc, Object.assign({}, m, { taper: m.taper === 0 ? 0 : 0.3 }), colour, size, layer); });
      clock = c0; return span;
    }
    // one mark at the current clock and pace; returns how long its pen takes (1.6: shared by draw() and edits)
    // ReferenceRenderer: ink that would vanish into what is under it (the user's blue cursor colour on a blue sky) is drawn
    // in white or near-black there instead. "Under it" is the last filled shape or card drawn beneath the mark when
    // there is one (a paper card, a pill, a cat's face), else the screen itself (the host's __lumFor).
    const grounds = [];
    const lumaOf = c => { const h = /^#?([0-9a-f]{6})$/i.exec(String(TONES[c] || c || '').trim()); if (!h) return null; const v = parseInt(h[1], 16); return (0.2126 * (v >> 16 & 255) + 0.7152 * (v >> 8 & 255) + 0.0722 * (v & 255)) / 255; };
    const NO_INK_CHECK = { image: 1, window: 1, stage3d: 1, part3d: 1, label3d: 1, highlight: 1, molecule: 1, edit: 1, motion3d: 1, camera3d: 1, tick3d: 1 };
    // The brightness the ink is seen against: a strip around the mark's box,
    // not its inside. Inside a ring is the thing ringed (a dark swatch made a
    // ring around it white on the white page), and a thin line's own box is the
    // line it sits on (a ray on a black axis turned white and vanished).
    function bandLuma(b) {
      if (typeof global.__lumFor !== 'function') return -1;
      const pad = 8, w = Math.max(1, b[2] - b[0]), h = Math.max(1, b[3] - b[1]);
      const strips = [[b[0] - pad, b[1] - pad, w + 2 * pad, pad], [b[0] - pad, b[3], w + 2 * pad, pad], [b[0] - pad, b[1], pad, h], [b[2], b[1], pad, h]];
      let sum = 0, area = 0;
      for (const [x, y, sw, sh] of strips) { const l = global.__lumFor(x, y, sw, sh); if (l >= 0) { sum += l * sw * sh; area += sw * sh; } }
      return area > 0 ? sum / area : -1;
    }
    // the last card or filled shape drawn under a point: [x0, y0, x1, y1, luma, colour], or null
    // A window's ground is its live box (g[7] is its mark): windows grow to hold what is drawn on them, and a box
    // recorded at their first size left words in the grown part judged against the app behind (white words on a
    // white card, 2026-10-09).
    const liveBox = g => (g[7] && markBox(g[7])) || g;
    function groundAt(px, py) {
      for (let k = grounds.length - 1; k >= 0; k--) { const g = grounds[k], b = liveBox(g); if (px >= b[0] && px <= b[2] && py >= b[1] && py <= b[3]) return g; }
      return null;
    }
    // The ground under a mark, counting a window the mark is about to grow (fitWindowsTo runs after the mark is
    // painted, by the same rule: tagged for it, or mostly on it).
    function groundFor(m, b) {
      const g = groundAt((b[0] + b[2]) / 2, (b[1] + b[3]) / 2);
      if (g) return g;
      for (let k = grounds.length - 1; k >= 0; k--) {
        const w = grounds[k][7]; if (!w || w.__erased) continue;
        const tagged = Array.isArray(m.onWindow) && Array.isArray(w.inner) && Math.abs(m.onWindow[0] - w.inner[0]) < 1 && Math.abs(m.onWindow[1] - w.inner[1]) < 1;
        const wb = liveBox(grounds[k]);
        if (belongsToWindow(b, wb[0], wb[1], wb[2], wb[3], tagged)) return grounds[k];
      }
      return null;
    }
    const isChromatic = hex => { const h = /^#?([0-9a-f]{6})$/i.exec(hex); if (!h) return false; const v = parseInt(h[1], 16), r = v >> 16 & 255, g = v >> 8 & 255, b = v & 255;
      return Math.max(r, g, b) - Math.min(r, g, b) > 40; };
    const mixHex = (a, b, k) => { const p = /^#?([0-9a-f]{6})$/i.exec(a), q = /^#?([0-9a-f]{6})$/i.exec(b); if (!p || !q) return a;
      const x = parseInt(p[1], 16), y = parseInt(q[1], 16), c = sh => Math.round((x >> sh & 255) * (1 - k) + (y >> sh & 255) * k).toString(16).padStart(2, '0');
      return '#' + c(16) + c(8) + c(0); };
    // Words on a card or a filled shape wear a halo in that ground's own colour, so a line or an arrow passing behind
    // them stops short of the letters instead of cutting through them (2026-10-09). Words loose on the screen keep the
    // halo the pen gives white and near-black words.
    // Every filled shape drawn so far, [x0, y0, x1, y1, colour, alpha], so a halo takes the colour actually under the
    // words: a card's colour with any tinted box on it blended over it.
    const surfaces = [];
    let drawOrder = 0;
    function knockoutFor(m) {
      if (m.do !== 'text' || m.under || m.knockout === false || m.role === 'cheer') return null;
      const b = markBox(m); if (!b) return null;
      const px = (b[0] + b[2]) / 2, py = (b[1] + b[3]) / 2;
      const ground = groundFor(m, b);
      if (!ground || !ground[5]) return null;
      let colour = ground[5];
      // only what was drawn on top of that card
      for (const f of surfaces) if (f[6] > (ground[6] || 0) && px >= f[0] && px <= f[2] && py >= f[1] && py <= f[3]) colour = f[5] >= 0.99 ? f[4] : mixHex(colour, f[4], f[5]);
      return colour;
    }
    function readableColour(m, colour) {
      // a legend's keys keep exactly the colours of what they stand for
      if (surface !== 'none' || NO_INK_CHECK[m.do] || m.role === 'paper' || m.role === 'key') return colour;
      const ink = lumaOf(colour), b = markBox(m);
      if (ink == null || !b) return colour;
      let under = null;
      const ground = groundFor(m, b);
      if (ground) under = ground[4];
      if (under == null) { const l = bandLuma(b); if (!(l >= 0)) return colour; under = l; }
      // Words need more contrast than a line does: grey words (#7E838D) passed the line's 0.2 test on a dark app
      // and read as dark-on-dark (2026-10-09, a note under a photo over a dark editor). Grey stays a quieter
      // light grey there, so a card's two text tones keep their order.
      const isWords = m.do === 'text', needed = !isWords ? 0.2 : under > 0.58 ? 0.3 : 0.45;
      if (Math.abs(ink - under) >= needed) return colour;
      // A colour that means something (a group's colour, the dots of a legend) keeps its hue: a deeper shade of it on
      // a light ground, a lighter one on a dark ground, so "THE HILL" in mustard still matches its yellow dots instead
      // of turning black (2026-10-09). Only greys and near-greys swap to the plain dark or light ink.
      const hex = String(TONES[colour] || colour || '');
      if (isChromatic(hex)) {
        for (let k = 0.1; k <= 0.85; k += 0.05) {
          const next = under > 0.58 ? shade(hex, k) : mixHex(hex, '#FFFFFF', k), l = lumaOf(next);
          if (l != null && Math.abs(l - under) >= needed) return next;
        }
      }
      if (under > 0.58) return '#15171C';
      return isWords && ink > 0.35 ? '#C9CDD4' : '#FFFFFF';
    }
    // ReferenceRenderer (2026-10-08): Mate's windows grow to hold what is drawn on them. A mark that is mostly on a window (or
    // says it belongs to one: onWindow, the window's writing area origin) but reaches past its padding pushes that side
    // out, keeping the padding around it (never up into the title bar's place: the top grows by the same rule above
    // the title bar). The window's mark and element change, so the app redraws it and the card's box stays true.
    const windowsDrawn = [];
    // Whether a mark (box b) belongs to a window (outer box x0..x1, y0..y1): tagged for it, mostly on it, its middle on
    // it, or a row that ran just past its bottom edge (across the window, its top within a line below it): the model
    // ran out of room, and that last row was left white and loose under the card, the sources line on top of it
    // (2026-10-09).
    function belongsToWindow(b, x0, y0, x1, y1, tagged) {
      if (tagged) return true;
      const ow = Math.min(b[2], x1) - Math.max(b[0], x0), oh = Math.min(b[3], y1) - Math.max(b[1], y0), bw = b[2] - b[0], bh = b[3] - b[1];
      if (ow > 0 && oh > 0 && ow * oh >= 0.4 * bw * bh) return true;
      const cx = (b[0] + b[2]) / 2, cy = (b[1] + b[3]) / 2;
      if (cx >= x0 && cx <= x1 && cy >= y0 && cy <= y1) return true;
      return ow >= 0.6 * bw && b[1] >= y0 && b[1] <= y1 + 48 && bh <= 120;
    }
    function fitWindowsTo(m, i) {
      if (!windowsDrawn.length || !m || m.do === 'window' || m.do === 'edit' || m.role === 'tie' || m.role === 'photo' || m.role === 'paper'
        || m.stage != null || /3d$/.test(m.do || '') || pointsAtScreen(m)) return;
      // its drawn box (halos left out, so not domBox), else its estimate
      let raw = null;
      for (const n of NODES[i] || []) {
        if (n.__gone || n.getAttribute && n.getAttribute('data-halo')) continue;
        let r; try { r = n.getBBox(); } catch (_) { continue; }
        if (!r || (!r.width && !r.height)) continue;
        const nu = n.__nudge || [0, 0];
        const q = [r.x + nu[0], r.y + nu[1], r.x + nu[0] + r.width, r.y + nu[1] + r.height];
        raw = raw ? [Math.min(raw[0], q[0]), Math.min(raw[1], q[1]), Math.max(raw[2], q[2]), Math.max(raw[3], q[3])] : q;
      }
      if (raw && m.__xf) { const a = m.__xf; raw = [raw[0] * a[0] + a[1], raw[1] * a[0] + a[2], raw[2] * a[0] + a[1], raw[3] * a[0] + a[2]]; }
      if (!raw) raw = markBox(m);
      if (!raw || raw[2] <= raw[0] || raw[3] <= raw[1]) return;
      for (const w of windowsDrawn) {
        const wm = w.m; if (wm.__erased || !w.e.parentNode) continue;
        const xf = wm.__xf || [1, 0, 0], k = xf[0] || 1;
        // the mark in the window's own (undrawn-move) coordinates
        const b = [(raw[0] - xf[1]) / k, (raw[1] - xf[2]) / k, (raw[2] - xf[1]) / k, (raw[3] - xf[2]) / k];
        const x0 = wm.at[0], y0 = wm.at[1], x1 = x0 + wm.w, y1 = y0 + wm.h, pad = +wm.pad || 0, head = +wm.header || 0;
        const tagged = Array.isArray(m.onWindow) && Array.isArray(wm.inner) && Math.abs(m.onWindow[0] - wm.inner[0]) < 1 && Math.abs(m.onWindow[1] - wm.inner[1]) < 1;
        if (!belongsToWindow(b, x0, y0, x1, y1, tagged)) continue;
        // where its content starts and ends (the sources line lines up with its left edge and goes under its bottom)
        if (!tagged) { w.contentLeft = Math.min(w.contentLeft == null ? Infinity : w.contentLeft, b[0]); w.contentBottom = Math.max(w.contentBottom == null ? -Infinity : w.contentBottom, b[3]); }
        const nx0 = Math.max(2, Math.min(x0, b[0] - pad)), nx1 = Math.min(W - 2, Math.max(x1, b[2] + pad));
        const ny0 = Math.max(2, Math.min(y0, b[1] - pad - head)), ny1 = Math.min(H - 2, Math.max(y1, b[3] + pad));
        if (nx0 >= x0 - 0.5 && nx1 <= x1 + 0.5 && ny0 >= y0 - 0.5 && ny1 <= y1 + 0.5) continue;
        wm.at = [nx0, ny0]; wm.w = nx1 - nx0; wm.h = ny1 - ny0;
        w.e.setAttribute('x', nx0); w.e.setAttribute('y', ny0); w.e.setAttribute('width', wm.w); w.e.setAttribute('height', wm.h);
        break;
      }
    }
    function noteGround(m) {
      if (m.do === 'window') { const l = lumaOf(m.bg), b = markBox(m); if (l != null && b) { grounds.push([b[0], b[1], b[2], b[3], l, String(TONES[m.bg] || m.bg), ++drawOrder, m]); } return; }
      if (m.fill && m.role !== 'paper' && { poly: 1, rect: 1, circle: 1, ellipse: 1, path: 1 }[m.do]) {
        const b = markBox(m), hex = String(TONES[m.fill] || m.fill), alpha = m.fillAlpha != null ? +m.fillAlpha : 1;
        if (b && /^#[0-9a-f]{6}$/i.test(hex) && alpha >= 0.08) surfaces.push([b[0], b[1], b[2], b[3], hex, alpha, ++drawOrder]);
      }
      if (!m.fill || (m.fillAlpha != null && m.fillAlpha < 0.8) || !{ poly: 1, rect: 1, circle: 1, ellipse: 1, path: 1 }[m.do]) return;
      const l = lumaOf(m.fill), b = markBox(m);
      // a card (paper's role) is a ground the words can match; a small filled shape only lends its brightness
      const isCard = m.role === 'paper' && (m.fillAlpha == null || m.fillAlpha >= 0.99);
      if (l != null && b) grounds.push([b[0], b[1], b[2], b[3], l, isCard ? String(TONES[m.fill] || m.fill) : null, ++drawOrder]);
    }
    function paint(m, i) {
        paintingRole = m.role || null;
        // ReferenceRenderer: a window's sources line starts where the window's content starts (programs indent their words
        // inside the box, and the credits were left hanging at the box's edge)
        if (Array.isArray(m.onWindow) && !m.__aligned && Array.isArray(m.at)) {
          const w = windowsDrawn.find(v => Array.isArray(v.m.inner) && Math.abs(v.m.inner[0] - m.onWindow[0]) < 1 && Math.abs(v.m.inner[1] - m.onWindow[1]) < 1);
          if (w && isFinite(w.contentLeft) && w.contentLeft > w.m.inner[0] + 1) m.at = [m.at[0] + (w.contentLeft - w.m.inner[0]), m.at[1]];
          // The credits go under everything drawn on the card, a clear gap below it: they were placed under the card's
          // first writing area, and a last row reaching past it (the window grew to hold it) had the credits written
          // on top of it (2026-10-09). Every piece of the line shares sourceLine (its first baseline), so they move together.
          if (w && isFinite(w.contentBottom) && isFinite(+m.sourceLine)) {
            const size = +m.sourceSize || 13, gap = Math.max(24, +w.m.pad || 0), lineTop = +m.sourceLine - size * 0.82;
            const shift = w.contentBottom + gap - lineTop;
            if (shift > 0) m.at = [m.at[0], m.at[1] + shift];
          }
          m.__aligned = true;
        }
        // a filled shape with no outline colour of its own gets a thin edge in a deeper shade of its fill, not a black one
        const fillEdge = m.fill && !m.tone && /^(rect|ellipse|circle|poly)$/.test(m.do) ? shade(tone(m.fill), 0.32) : null;
        const r = rng((m.id || '') + i), colour = fillEdge || readableColour(m, tone(m.tone, TONES[defInk])), size = m.size || (fillEdge ? 1.6 : (BRUSH[m.brush] || BRUSH.pen).size);
        noteGround(m);
        const layer = m.under ? under : main;
        let dur = 0.3;
        switch (m.do) {
          case 'line': case 'arrow': {
            // wobble: 0 keeps a straight line straight (the dashed frames that mark the real screen stay crisp)
            // bow 'pen' (Mate's screen pen): a smoothed line bends once per edge too, then stays smooth through its corners
            let c = m.smooth === false ? handSegments(m.pts, false, r, m.wobble == null ? 0.6 : m.wobble, m.bow, m.jitter)
              : m.bow === 'pen' ? catmull(handSegments(m.pts, false, r, m.wobble == null ? 1 : m.wobble, 'pen', m.jitter), false, 2) : catmull(m.pts, false);
            if (m.do === 'arrow' && m.bend) {
              const [a, b] = [m.pts[0], m.pts[m.pts.length - 1]], L = Math.hypot(b[0] - a[0], b[1] - a[1]) || 1;
              let k = m.bend === true ? 0.15 : Number(m.bend) || 0;
              if (Math.abs(k) > 1) k = k / L;                              // a bend given in canvas units, not as a fraction
              if (Math.abs(k) > 0.6) { report.warnings.push(`${m.id || i}: bend ${m.bend} is too strong, used ${Math.sign(k) * 0.6}`); k = Math.sign(k) * 0.6; }
              const mid = [(a[0] + b[0]) / 2 - (b[1] - a[1]) * k, (a[1] + b[1]) / 2 + (b[0] - a[0]) * k]; c = catmull([a, mid, b], false);
            }
            if (m.dash && Array.isArray(m.marquee)) {
              // ReferenceRenderer (2026-10-19): a frame the app draws the old way, dragged open from its top-left corner like a
              // selection by Mate's cursor; the element carries the box, the app animates it (painter's marquee).
              const on = typeof m.dash === 'number' ? m.dash : Math.max(8, size * 3), off = +m.dashGap || on * 0.75;
              const e = el('path', { d: poly(m.pts), fill: 'none', stroke: colour, 'stroke-width': size, 'stroke-linecap': 'round', 'stroke-linejoin': 'round',
                'stroke-dasharray': `${on.toFixed(2)} ${off.toFixed(2)}`, 'data-marquee': m.marquee.map(v => (+v || 0).toFixed(2)).join(' '), 'data-marquee-handle': '1' }, layer);
              anim(e, 'marquee', MARQUEE_DUR, clock); dur = MARQUEE_DUR;
            } else if (m.dash) {
              const on = typeof m.dash === 'number' ? m.dash : Math.max(8, size * 3), pieces = dashes(c, on, +m.dashGap || on * 0.75), c0 = clock, span = Math.min(0.9, 0.2 + plen(c) / 900);
              pieces.forEach((pc, k) => { clock = c0 + span * k / Math.max(1, pieces.length); stroke(pc, Object.assign({}, m, { taper: m.taper === 0 ? 0 : 0.3 }), colour, size, layer); });
              clock = c0; dur = span;
            } else dur = stroke(c, m, colour, size, layer);
            if (m.do === 'arrow') {
              // ReferenceRenderer: headAngle is half the head's opening (the screen pen's is the old walkthrough's, π/7); taper 0
              // keeps the barbs as heavy as the shaft
              const e = c[c.length - 1], p = c[Math.max(0, c.length - 6)], a = Math.atan2(e[1] - p[1], e[0] - p[0]), hl = m.head || Math.max(9, size * 3), ha = +m.headAngle || 0.5;
              clock += dur;
              dur = stroke([[e[0] - hl * Math.cos(a - ha), e[1] - hl * Math.sin(a - ha)], e, [e[0] - hl * Math.cos(a + ha), e[1] - hl * Math.sin(a + ha)]], Object.assign({}, m, { taper: m.taper === 0 ? 0 : 0.4 }), colour, size, layer);
              if (m.label) { const mid = c[Math.floor(c.length / 2)]; const t = el('text', { x: mid[0] + (m.labelDx || 0), y: mid[1] - 8 + (m.labelDy || 0), 'text-anchor': 'middle', fill: colour, 'font-family': faceFor('hand'), 'font-size': m.labelSize || 15 }, layer); t.textContent = m.label; anim(t, 'fadein', 0.3, clock + dur); }
            }
            break;
          }
          case 'path': {
            // ReferenceRenderer: a path with several pieces ("M … M …": tick marks, window panes, brackets) is drawn
            // piece by piece. Sampled as one line, every move became a stray stroke joining the pieces.
            const sh = Array.isArray(m.shift) ? m.shift : null;
            const moved = run => sh ? run.map(p => [p[0] + sh[0], p[1] + sh[1]]) : run;
            const runs = [];
            for (const piece of String(m.d || '').split(/(?=M)/).map(s => s.trim()).filter(Boolean)) {
              const n = Math.max(40, Math.min(400, Math.round(piece.length / 2)));
              const c = samplePath(piece, n), step = plen(c) / n;
              if (plen(c) < 0.5) { const start = (piece.match(/-?\d*\.?\d+/g) || []).map(Number); if (start.length >= 2) runs.push([[start[0], start[1]]]); continue; }
              // a relative "m" inside a piece: split where neighbouring samples jump (a chord is never longer than its arc)
              let run = [c[0]];
              for (let k = 1; k < c.length; k++) { if (dist(c[k - 1], c[k]) > step * 1.5 + 0.5) { runs.push(run); run = []; } run.push(c[k]); }
              runs.push(run);
            }
            wash(m.d, m, layer, sh ? { transform: `translate(${sh[0] + 0.8} ${sh[1] + 1})` } : null);
            if (m.outline !== false && runs.length) {
              const c0 = clock; let total = 0;
              for (const run of runs.map(moved)) {
                clock = c0 + total;
                if (run.length < 2 || plen(run) < 0.5) { const e = el('circle', { cx: run[0][0], cy: run[0][1], r: Math.max(1.5, size * 0.6), fill: colour }, layer); anim(e, 'pop', 0.2, clock); total += 0.04; }
                else total += edge(run, m, colour, size, layer);
              }
              clock = c0; dur = total;
            } else dur = 0.3;
            break;
          }
          case 'circle': case 'ellipse': {
            const [cx, cy] = m.at, rx = m.r || m.rx, ry = m.r || m.ry, rot = (m.rot || 0) * (typeof m.rot === 'number' && Math.abs(m.rot) > 6.3 ? Math.PI / 180 : 1);
            const c = ellipsePts(cx, cy, rx, ry, rot, r, m.wobble == null ? 1 : m.wobble, m.outline !== false);
            wash(poly(ellipsePts(cx, cy, rx, ry, rot, rng('f' + i), 0.5, false)) + ' Z', m, layer);
            dur = m.outline === false ? 0.3 : edge(c, m, colour, size, layer);
            break;
          }
          case 'rect': {
            const [x, y] = m.at, w = m.w, h = m.h;
            // {r}: rounded corners (a card, a bar's cap, a button-like box)
            const cr = Math.max(0, Math.min(+m.r || 0, Math.abs(w) / 2, Math.abs(h) / 2));
            const corner = (cx, cy, a0) => Array.from({ length: 7 }, (_, k) => { const a = a0 + k * Math.PI / 12; return [cx + Math.cos(a) * cr, cy + Math.sin(a) * cr]; });
            const pts = cr ? [...corner(x + w - cr, y + cr, -Math.PI / 2), ...corner(x + w - cr, y + h - cr, 0), ...corner(x + cr, y + h - cr, Math.PI / 2), ...corner(x + cr, y + cr, Math.PI)]
              : [[x, y], [x + w, y], [x + w, y + h], [x, y + h]];
            wash(poly(pts) + ' Z', m, layer);
            // a sharp box is closed by hand: the pen runs a little past where it started
            dur = m.outline === false ? 0.3 : edge(cr ? handSegments(pts, true, r, 1) : handSegments(pts.concat([[x, y], [x + Math.min(6, Math.abs(w) * 0.06), y + 1]]), false, r, 1), m, colour, size, layer);
            break;
          }
          case 'poly': {
            const closed = m.close !== false;
            wash(m.smooth ? poly(catmull(m.pts, true)) + ' Z' : poly(m.pts) + ' Z', m, layer);
            const c = m.smooth ? catmull(m.pts, closed) : handSegments(m.pts, closed, r, m.wobble == null ? 0.7 : m.wobble, m.bow, m.jitter);
            dur = m.outline === false ? 0.3 : edge(c, m, colour, size, layer);
            break;
          }
          case 'dot': {
            const e = el('circle', { cx: m.at[0], cy: m.at[1], r: m.r || 3, fill: colour }, layer); anim(e, 'pop', 0.25, clock); dur = 0.12; break;
          }
          case 'highlight': {
            const [x, y] = m.at, e = el('path', { d: `M${x} ${y + 2} Q${x + m.w / 2} ${y - 1} ${x + m.w} ${y + 1} L${x + m.w - 1} ${y + m.h} Q${x + m.w / 2} ${y + m.h + 2} ${x + 1} ${y + m.h - 1} Z`, fill: tone(m.tone || 'butter'), 'fill-opacity': 0.72, style: surface === 'sky' ? null : 'mix-blend-mode:multiply' }, m.under ? under : hlLayer);
            e.style.transformOrigin = `${x}px ${y}px`; e.style.transformBox = 'view-box'; anim(e, 'swipe', 0.35, clock); dur = 0.35; break;
          }
          case 'text': {
            const style = m.style || 'hand'; let fs = m.size || (style === 'title' ? 24 : style === 'body' ? 17 : style === 'caps' ? 14 : 20);
            // caps: upper case, semibold, tracked out with hair spaces (the native text shaper has no letter-spacing)
            if (style === 'caps') m = Object.assign({}, m, { text: String(m.text).toUpperCase().split('').join('\u200A'), weight: m.weight || 600 });
            // ui words (name pills, badges) are sized in screen POINTS: on a big display one canvas unit is ~2pt, so their
            // floor is 8pt, not 8 units. A unit floor there drew a 12pt pill's words a third too big, wrapped onto two lines
            // and spilling out of the pill it was measured for.
            const unitPoints = +global.__canvasUnitPoints > 0 ? +global.__canvasUnitPoints : 1;
            const minSize = style === 'ui' ? 8 / unitPoints : 13;
            if (fs < minSize) { report.warnings.push(`${m.id || i}: text size ${fs} is too small to read, used ${Math.round(minSize)}`); fs = minSize; }
            // ReferenceRenderer (2026-10-20): a tighter line for the morning paper's headlines (lineHeight on the mark)
            const lineHeight = +m.lineHeight > 0.8 ? +m.lineHeight : LINE_HEIGHT;
            const knockout = knockoutFor(m), haloWidth = Math.max(5, fs * 0.45);
            const t = el('text', { x: m.at[0], y: m.at[1], fill: colour, 'font-family': faceFor(style), 'font-size': fs, 'font-weight': style === 'title' ? 600 : (m.weight || null), 'text-anchor': m.anchor || 'start', 'dominant-baseline': m.top ? 'alphabetic' : (m.baseline || 'auto'), transform: m.rot ? `rotate(${m.rot} ${m.at[0]} ${m.at[1]})` : null,
              stroke: knockout, 'stroke-width': knockout ? haloWidth : null, 'stroke-linejoin': knockout ? 'round' : null, 'paint-order': knockout ? 'stroke' : null,
              'data-knockout': knockout, 'data-knockout-width': knockout ? haloWidth.toFixed(2) : null }, m.under ? layer : words);
            let lines = String(m.text).split('\n');
            const maxW = m.wrap || (m.fit && m.fit[0]);
            if (maxW && lines.length === 1) {           // greedy word wrap using real glyph widths
              const probe = el('text', { 'font-family': faceFor(style), 'font-size': fs, 'font-weight': style === 'title' ? 600 : (m.weight || null) }, svg.querySelector('#__probe'));
              const width = str => { probe.textContent = str; return probe.getComputedTextLength(); };
              const out = []; let cur = '';
              for (const w of lines[0].split(' ')) { const next = cur ? cur + ' ' + w : w; if (cur && width(next) > maxW) { out.push(cur); cur = w; } else cur = next; }
              out.push(cur); probe.remove(); lines = out;
            }
            if (lines.length > 1 && (m.fit || m.wrap) && !m.top && (m.baseline || 'auto') === 'auto') t.setAttribute('y', m.at[1] - (lines.length - 1) * fs * lineHeight / 2);
            if (lines.length > 1) lines.forEach((ln, k) => { const s = el('tspan', { x: m.at[0], dy: k ? fs * lineHeight : 0 }, t); s.textContent = ln; }); else t.textContent = m.text;
            if (m.fit) {
              let f = fs, bb = t.getBBox();
              while ((bb.width > m.fit[0] || bb.height > m.fit[1]) && f > Math.min(8, minSize)) { f *= 0.92; t.setAttribute('font-size', f.toFixed(1)); t.querySelectorAll('tspan').forEach((ts, k) => k && ts.setAttribute('dy', f * lineHeight)); bb = t.getBBox(); }
              if (f < fs * 0.7) report.warnings.push(`${m.id || i}: text shrank to ${Math.round(f)}px to fit, shorten it`);
            }
            if (m.place !== false && !m.under && !editing) placeLabel(t);
            anim(t, 'write', 0.4 + String(m.text).length * 0.015, clock); dur = 0.35 + String(m.text).length * 0.012; break;
          }
          case 'edit': {                                     // ReferenceRenderer: an edit of what is on the card, at this point of the drawing
            const took = hooks.edit ? hooks.edit(m, i, clock, pace) : 0;
            dur = took / Math.max(pace, 0.35); break;
          }
          case 'molecule': {
            const g = el('g', { transform: `translate(${m.at[0]} ${m.at[1]})` }, layer);
            const s = el('svg', { width: m.w, height: m.h, viewBox: `0 0 ${m.w} ${m.h}`, overflow: 'visible' }, g);
            s.setAttribute('data-smiles', m.smiles);
            if (global.SmilesDrawer) {
              const d = new global.SmilesDrawer.SvgDrawer({ width: m.w, height: m.h, bondThickness: 1.6, bondLength: m.bond || 22, shortBondLength: 0.82, fontSizeLarge: 9, fontSizeSmall: 6, padding: 4, compactDrawing: false, terminalCarbons: false, explicitHydrogens: false, themes: { mate: { C: TONES.ink, O: TONES.coral, N: TONES.blue, F: TONES.leaf, CL: TONES.leaf, BR: TONES.brown, I: TONES.violet, P: TONES.orange, S: TONES.sun, B: TONES.peach, SI: TONES.brown, H: TONES.ink, BACKGROUND: 'transparent' } } });
              global.SmilesDrawer.parse(m.smiles, tree => { d.draw(tree, s, 'mate', null, false); }, err => report.errors.push('smiles: ' + err));
              s.querySelectorAll('line').forEach(ln => { ln.setAttribute('stroke-linecap', 'round'); ln.setAttribute('stroke-width', '1.8'); });
              try { const bb = s.getBBox(); if (bb.width > 0) { const k = Math.min(m.w / (bb.width + 10), m.h / (bb.height + 10), 1.9); const vw = m.w / k, vh = m.h / k;
                s.setAttribute('viewBox', `${bb.x + bb.width / 2 - vw / 2} ${bb.y + bb.height / 2 - vh / 2} ${vw} ${vh}`); } } catch (_) {}
              s.querySelectorAll('text').forEach(tx => { tx.setAttribute('font-family', FONT.body); tx.setAttribute('font-weight', '600'); });
            } else report.errors.push('molecule piece needs SmilesDrawer');
            anim(g, 'fadein', 0.6, clock); dur = 0.6; break;
          }
          case 'image': {                                    // ReferenceRenderer: a real photo; the app finds and paints it
            const e = el('photo', { x: m.at[0], y: m.at[1], width: m.w, height: m.h, 'data-query': String(m.query || ''), 'data-radius': m.r || 0, 'data-rotate': m.rot || 0 }, layer);
            anim(e, 'fadein', 0.5, clock); dur = 0.5; break;
          }
          case 'window': {                                   // ReferenceRenderer: a little window; the app paints its chrome and board
            const e = el('window', { x: m.at[0], y: m.at[1], width: m.w, height: m.h, 'data-header': m.header, 'data-title': m.title || null,
              'data-board': m.board || 'plain', 'data-bg': m.bg, 'data-tint': m.tint, 'data-tint-alpha': m.tintAlpha }, layer);
            if (!windowsDrawn.some(w => w.m === m)) windowsDrawn.push({ m, e }); else windowsDrawn.find(w => w.m === m).e = e;
            anim(e, 'fadein', 0.45, clock); dur = 0.45; break;
          }
          case 'stage3d': {                                  // ReferenceRenderer: a 3D object's stage, standing on the screen
            // standing on a card the program drew: that card's board is plain under it (already on screen too: the
            // app redraws a window whose attributes change)
            if (Array.isArray(m.cardWindow)) {
              const w = windowsDrawn.find(v => Array.isArray(v.m.inner) && Math.abs(v.m.inner[0] - m.cardWindow[0]) < 1 && Math.abs(v.m.inner[1] - m.cardWindow[1]) < 1);
              if (w && w.e.getAttribute('data-board') !== 'plain') { w.m.board = 'plain'; w.e.setAttribute('data-board', 'plain'); }
            }
            const e = el('scene3d', { id: m.id, x: m.at[0], y: m.at[1], width: m.w, height: m.h, 'data-ink': m.ink, 'data-camera': JSON.stringify(m.camera || {}), 'data-card': m.card ? m.card.join(' ') : null, 'data-canvas': W + ' ' + H, 'data-look': m.look || null }, layer);
            anim(e, 'fadein', 0.35, clock); dur = 0.12; break;
          }
          case 'part3d': {
            const e = el('part3d', { 'data-stage': m.stage, 'data-part': JSON.stringify({ id: m.id, kind: m.kind, params: m.params, at: m.pos, rotate: m.rotate3, scale: m.scale3, material: m.material, parent: m.parent, three: m.three, recipe: m.recipe, name: m.name }) }, layer);
            anim(e, 'grow', 0.65, clock); dur = 0.12; break;
          }
          case 'label3d': {
            const e = el('label3d', { 'data-stage': m.stage, 'data-label': JSON.stringify({ id: m.id, point: m.point, follow: m.follow, text: m.text, side: m.side }), fill: tone(m.tone, colour), 'font-family': FONT.hand, 'font-size': m.size || 19 }, words);
            anim(e, 'write', 0.4 + String(m.text).length * 0.015, clock); dur = 0.35 + String(m.text).length * 0.012; break;
          }
          case 'tick3d': {                                   // three-metal: a figure's tick() starts with this beat
            const e = el('tick3d', { 'data-stage': m.stage, 'data-tick': m.id }, layer);
            anim(e, 'set', 0.01, clock); dur = 0; break;
          }
          case 'motion3d': case 'camera3d': {
            const e = el(m.do, { 'data-stage': m.stage, 'data-op': JSON.stringify(m.op || {}) }, layer);
            anim(e, 'set', 0.01, clock); dur = 0; break;
          }
          default: report.errors.push(`unknown mark "${m.do}" (${m.id || i})`);
        }
        return dur;
    }
    // ReferenceRenderer: Mate's cursor flies to the next mark on an arc, like the old walkthrough's pointing flight. A
    // mark far from the last one waits for it (its ink starts when the cursor lands) instead of drawing while the
    // cursor is still across the screen; marks after it never start before it. The first mark waits for the
    // flight from wherever the cursor is.
    let penAt = null, penLandsAt = 0;
    function penFlightBefore(m) {
      if (m.role === 'type' || m.role === 'copy' || m.role === 'open' || m.role === 'handoff' || (m.role === 'button' && m.do === 'dot') || (m.do === 'dot' && (+m.r || 3) < 1)) return 0;
      const b = markBox(m); if (!b) return 0;
      const c = [(b[0] + b[2]) / 2, (b[1] + b[3]) / 2], from = penAt; penAt = c;
      if (!from) return 0.45;
      const far = Math.hypot(c[0] - from[0], c[1] - from[1]);
      return far < 110 ? 0 : Math.min(0.55, 0.2 + far / 2400);
    }
    // ReferenceRenderer: a tie arrow (tie() in Mate's pieces, {tieTo: [x, y, w, h, gap, pad]}) starts where its row's words
    // really end. The model can only guess how long a line is, so its arrows started far past short rows or inside
    // long ones. The row is the words beside the start the model gave (their middle within a line of it, starting
    // left of it); the arrow leaves the end of the longest of them, at that line's height, toward the photo.
    function snapTie(m) {
      const t = m.tieTo, from = m.pts[0];
      if (!Array.isArray(t) || !Array.isArray(from)) return;
      const [bx, by, bw, bh, gap, pad] = t.map(Number);
      if (![bx, by, bw, bh, from[0], from[1]].every(Number.isFinite)) return;
      const toRight = bx + bw / 2 > from[0];
      let best = null;
      for (const e of words.querySelectorAll('text')) {
        if (e.__gone || e.ownerSVGElement !== svg || e.__role === 'photo' || e.__role === 'tie' || e.__role === 'source') continue;
        let o; try { const r = e.getBBox(), tr = e.__nudge || [0, 0], xf = e.__wrap && e.__wrap.__xf; o = { x: r.x + tr[0], y: r.y + tr[1], w: r.width, h: r.height }; if (xf) o = { x: o.x * xf[0] + xf[1], y: o.y * xf[0] + xf[2], w: o.w * xf[0], h: o.h * xf[0] }; } catch (_) { continue; }
        if (!o.w || Math.abs(o.y + o.h / 2 - from[1]) > Math.max(o.h, 20)) continue;
        if (toRight ? (o.x > from[0] + 20 || o.x + o.w > bx - gap) : (o.x + o.w < from[0] - 20 || o.x < bx + bw + gap)) continue;
        if (!best || (toRight ? o.x + o.w > best.x + best.w : o.x < best.x)) best = o;
      }
      if (!best) return;
      const s = [toRight ? best.x + best.w + (pad || 8) : best.x - (pad || 8), best.y + best.h / 2];
      const cx = bx + bw / 2, cy = by + bh / 2, dx = s[0] - cx, dy = s[1] - cy, g = gap || 6;
      if (!dx && !dy) return;
      const reach = Math.min(dx ? (bw / 2 + g) / Math.abs(dx) : Infinity, dy ? (bh / 2 + g) / Math.abs(dy) : Infinity);
      if (reach >= 1) return;
      m.pts = [s, [cx + dx * reach, cy + dy * reach]];
    }
    // d.paced: the pacer already chose when this mark starts (now) and how fast it goes (d.pace)
    function draw(marks, live = false, d = {}) {
    if (live) { const now = (performance.now() - t0) / 1000; clock = d.paced ? now + 0.02 : Math.max(clock, now + 0.05); delayBase = now; }
    const stepTotal = {}; marks.forEach((m, i) => { const k = m.step != null ? stepKey(m) : 0; stepTotal[k] = (stepTotal[k] || 0) + est(m); });
    let top = total - 1;
    for (const [j, m] of marks.entries()) {
      // ReferenceRenderer: a paced mark comes with its own index (marks a new turn dropped are never drawn, so draw order has gaps)
      const i = marks.length === 1 && d.i != null ? d.i : total + j;
      top = Math.max(top, i);
      try {
        if (m.__skip) { m.__passed = true; continue; }                                    // 1.6: erased by an edit before it was drawn
        if (m._t != null) { clock = m._t; pace = m._pace != null ? m._pace : 1; }          // a precomputed schedule (paced replays, frames)
        else if (d.paced) pace = d.pace != null ? d.pace : 1;
        else {
          pace = Math.min(1, BUDGET / (stepTotal[m.step != null ? stepKey(m) : 0] || 1));
          if (m.step != null && lastStep != null && stepKey(m) !== lastStep) clock += 0.3;
        }
        lastStep = m.step != null ? stepKey(m) : lastStep;
        if (m.tieTo && Array.isArray(m.pts) && m.pts.length >= 2 && !m.__tied) { m.__tied = true; snapTie(m); }
        if (live && d.paced) { const flight = penFlightBefore(m); clock = Math.max(clock, penLandsAt); if (flight) penLandsAt = clock = clock + flight; }
        const st0 = clock;
        if (m.pts && Array.isArray(m.pts) && m.pts.some(p => Array.isArray(p) && (p[0] < -W * 0.1 || p[0] > W * 1.1 || p[1] < -H * 0.1 || p[1] > H * 1.1)))
          report.warnings.push(`${m.id || i}: a point of this ${m.do} is far outside the card`);
        cap = NODES[i] = []; capM = MASKS[i] = []; capKey = i; MK[i] = m;
        let dur;
        try { dur = paint(m, i); } finally { cap = capM = null; }
        if (m.__xf) NODES[i].forEach(n => setXf(wrap(n), m.__xf));                        // 1.6: moved or scaled by an edit before it was drawn
        try { fitWindowsTo(m, i); } catch (_) {}
        placed[i] = [+st0.toFixed(3), +(st0 + dur * Math.max(pace, 0.35)).toFixed(3)];
        clock += dur * (m.do === 'dot' ? 0.5 : 0.7) * pace;
      } catch (e) { report.errors.push(`${m.id || i}: ${e.message}`); }
    }
    total = Math.max(total + (marks.length === 1 && d.i != null ? 0 : marks.length), top + 1); report.marks = total;
    }
    function finish() {
    [...main.querySelectorAll('text,path'), ...words.querySelectorAll('text')].filter(e => e.ownerSVGElement === svg).forEach(e => { try { const r = e.getBBox(), n = e.__nudge || [0, 0], b = { x: r.x + n[0], y: r.y + n[1], width: r.width, height: r.height }; if (b.width && (b.x < -2 || b.y < -2 || b.x + b.width > W + 2 || b.y + b.height > H + 2)) report.warnings.push(`${e.tagName} at ${Math.round(b.x)},${Math.round(b.y)} runs off the canvas`); } catch (_) {} });
    const boxes = [...words.querySelectorAll('text')].filter(e => e.ownerSVGElement === svg && !e.__gone).map(e => { try { const r = e.getBBox(), n = e.__nudge || [0, 0]; return { b: { x: r.x + n[0], y: r.y + n[1], width: r.width, height: r.height }, t: e.textContent.slice(0, 24) }; } catch (_) { return null; } }).filter(x => x && x.b.width);
    let overlaps = 0;
    for (let a = 0; a < boxes.length; a++) for (let c = a + 1; c < boxes.length; c++) {
      const A = boxes[a].b, B = boxes[c].b, ix = Math.min(A.x + A.width, B.x + B.width) - Math.max(A.x, B.x), iy = Math.min(A.y + A.height, B.y + B.height) - Math.max(A.y, B.y);
      if (ix > 3 && iy > 4) { overlaps++; report.warnings.push(`text "${boxes[a].t}" overlaps text "${boxes[c].t}"`); }
    }
    report.overlaps = overlaps;
    report.warnings = [...new Set(report.warnings)].slice(0, 14);
    report.duration = +clock.toFixed(2);
    host.dataset.report = JSON.stringify(report);
    return report;
    }

    // ---------------------------------------------------------------- 1.6: changing what is already on the card
    // A mark's nodes sit in several layers (wash under, pen strokes, words). An edit repaints a mark with its own seed
    // (so it wobbles exactly as before) at its own depth, moves or scales its nodes inside wrapper groups, or runs its
    // pen backwards. Tweens run on requestAnimationFrame; settle() jumps every running edit to its end (an interruption).
    const TW = new Set(), fresh = new Set();
    const ease = p => p < 0.5 ? 2 * p * p : 1 - Math.pow(-2 * p + 2, 2) / 2;
    const EASE_CSS = 'cubic-bezier(.455,.03,.515,.955)';     // the same curve for hosts that animate a motion themselves
    // ReferenceRenderer: a host that animates on its own (the native canvas: Core Animation) takes each edit's property changes
    // declared once (global.__mateMotion(items, at, dur, ease)) instead of a style change on every frame
    const motionHost = () => typeof global.__mateMotion === 'function' ? global.__mateMotion : null;
    // frames run only while a tween changes something each frame; otherwise one wake-up at the next start or end
    const hasRaf = typeof requestAnimationFrame === 'function';
    let wake = 0, wakeRaf = false, wakeAt = Infinity;
    function arm(ms) {
      const t = performance.now(), at = t + Math.max(0, ms);
      if (wake && at >= wakeAt - 1) return;
      if (wake) { if (wakeRaf) cancelAnimationFrame(wake); else clearTimeout(wake); }
      if (ms <= 0 && hasRaf) { wakeRaf = true; wake = requestAnimationFrame(frame); wakeAt = t; }
      else { wakeRaf = false; wake = setTimeout(frame, ms <= 0 ? 16 : ms); wakeAt = at; }
    }
    function frame() {
      wake = 0; wakeAt = Infinity; const t = performance.now(); let next = Infinity, perFrame = false;
      for (const tw of [...TW]) {
        if (!TW.has(tw)) continue;
        if (t < tw.s) { next = Math.min(next, tw.f ? tw.s : tw.s + tw.d); continue; }
        const p = Math.min(1, (t - tw.s) / tw.d);
        if (tw.f) tw.f(ease(p));
        if (p >= 1) { TW.delete(tw); if (tw.done) tw.done(); }
        else if (tw.f) perFrame = true; else next = Math.min(next, tw.s + tw.d);
      }
      if (!TW.size) return;
      if (perFrame) arm(0); else if (next < Infinity) arm(next - performance.now());
    }
    // f(p) each frame (null: nothing changes per frame, done() at the end); decl: nodes a host is animating (settle stops them)
    function tween(delay, dur, f, done, decl) {
      const tw = { s: performance.now() + delay * 1000, d: Math.max(1, dur * 1000), f, done, decl };
      TW.add(tw); arm(Math.max(0, (f ? tw.s : tw.s + tw.d) - performance.now()));
      return tw;
    }
    function settle() {
      for (const tw of [...TW]) { TW.delete(tw); if (tw.f) tw.f(1); if (tw.decl) for (const n of tw.decl) n.style.animation = 'none'; if (tw.done) tw.done(); }
      for (const n of fresh) n.style.animation = 'none'; fresh.clear();
    }
    function wrap(n) {
      if (n.__wrap) return n.__wrap;
      const g = document.createElementNS(NS, 'g'); g.__k = n.__k; g.__xf = [1, 0, 0];
      n.parentNode.insertBefore(g, n); g.appendChild(n); n.__wrap = g; return g;
    }
    function setXf(g, xf) { g.__xf = xf; g.setAttribute('transform', `matrix(${+xf[0].toFixed(4)} 0 0 ${+xf[0].toFixed(4)} ${+xf[1].toFixed(2)} ${+xf[2].toFixed(2)})`); }
    function placeByKey(n) {                          // keep z-order: before the first node of a later mark
      const par = n.parentNode; if (!par) return;
      for (const c of par.childNodes) if (c !== n && c.__k != null && c.__k > n.__k) { par.insertBefore(n, c); return; }
    }
    const nowS = () => (performance.now() - t0) / 1000;
    // paint mark m (seed i) at depth `key`, starting `at` s from now at pace p; the drawing's own clock is left alone
    function paintAt(m, i, key, at, p, repaint) {
      const sv = [clock, pace, delayBase], tn = nowS();
      delayBase = tn; clock = tn + at; pace = p;
      cap = []; capM = []; capKey = key; editing = !!repaint;
      let dur = 0.3;
      try { dur = paint(m, i); } catch (e) { report.errors.push(`edit ${i}: ${e.message}`); }
      const nodes = cap, masks = capM; cap = capM = null; editing = false;
      [clock, pace, delayBase] = sv;
      for (const n of nodes) { placeByKey(n); fresh.add(n); }
      for (const mp of masks) fresh.add(mp);
      if (m.__xf) nodes.forEach(n => setXf(wrap(n), m.__xf));
      NODES[i] = nodes; MASKS[i] = masks; MK[i] = m;
      try { fitWindowsTo(m, i); } catch (_) {}
      const d = dur * Math.max(p, 0.35);
      tween(at + d + 0.1, 0.001, null, () => { nodes.forEach(n => fresh.delete(n)); masks.forEach(n => fresh.delete(n)); });
      return { nodes, masks, dur: d, adv: dur * (m.do === 'dot' ? 0.5 : 0.7) * p };
    }
    // take nodes off the card: the pen runs backwards over strokes, everything else fades; then they are removed
    function unpaint(nodes, masks, at, dur) {
      const byMask = {}; for (const mp of masks || []) { const mk = mp.parentNode; if (mk && mk.id) byMask[mk.id] = mp; }
      const pen = [], fade = [];
      for (const n of nodes) {
        n.__gone = true;
        const id = /url\(#([^)]+)\)/.exec(n.getAttribute('mask') || '');
        if (id && byMask[id[1]]) pen.push(byMask[id[1]]); else fade.push(n);
      }
      const off = () => { for (const n of nodes) { const w = n.__wrap; (w && w.parentNode ? w : n).remove(); } for (const mp of masks || []) { const mk = mp.parentNode; if (mk) mk.remove(); } };
      const host = motionHost();
      if (host) {
        host(pen.map(mp => ({ node: mp, prop: 'dash', from: 0, to: 1 })).concat(fade.map(n => ({ node: n, prop: 'opacity', from: 1, to: 0 }))), at, dur, EASE_CSS);
        return tween(at, dur, null, off, pen.concat(fade));
      }
      return tween(at, dur, p => { for (const mp of pen) { mp.style.animation = 'none'; mp.style.strokeDashoffset = String(p); } for (const n of fade) { n.style.animation = 'none'; n.style.opacity = String(1 - p); } }, off);
    }
    // glide nodes to a new transform [scale, tx, ty] (linear in the matrix, so a scale keeps its centre fixed)
    function moveNodes(nodes, to, at, dur) {
      const gs = nodes.filter(n => !n.__gone && n.parentNode).map(wrap), from = gs.map(g => g.__xf.slice());
      const host = motionHost();
      if (host) {
        gs.forEach(g => setXf(g, to));                   // where it ends up; the host glides it there
        host(gs.map((g, j) => ({ node: g, prop: 'xf', from: from[j], to: to.slice() })), at, dur, EASE_CSS);
        return tween(at, dur, null, null, gs);
      }
      return tween(at, dur, p => gs.forEach((g, j) => { const a = from[j]; setXf(g, [a[0] + (to[0] - a[0]) * p, a[1] + (to[1] - a[1]) * p, a[2] + (to[2] - a[2]) * p]); }));
    }
    // where a drawn mark really is on the card (text measured with its real font), or null
    function domBox(i) {
      const ns = NODES[i]; if (!ns) return null;
      let b = null;
      for (const n of ns) {
        // ReferenceRenderer: the app's virtual DOM has no isConnected (an element on the canvas has its <svg> above it). Without
        // this every box in the app was the program's estimate, and a mark with none (a path in relative commands: the
        // lines of a little document icon) never rode with its card when it was moved or shown full screen.
        if (n.__gone || !(n.isConnected !== undefined ? n.isConnected : !!n.ownerSVGElement)) continue;
        let r; try { r = n.getBBox(); } catch (_) { continue; }
        if (!r || (!r.width && !r.height)) continue;
        const nu = n.__nudge || [0, 0], xf = (n.__wrap && n.__wrap.__xf) || [1, 0, 0];
        const x0 = (r.x + nu[0]) * xf[0] + xf[1], y0 = (r.y + nu[1]) * xf[0] + xf[2], x1 = x0 + r.width * xf[0], y1 = y0 + r.height * xf[0];
        b = b ? [Math.min(b[0], x0), Math.min(b[1], y0), Math.max(b[2], x1), Math.max(b[3], y1)] : [x0, y0, x1, y1];
      }
      return b;
    }
    const edit = { NODES, MASKS, MK, paintAt, unpaint, moveNodes, settle, tween, domBox, now: nowS, get busy() { return TW.size > 0; } };
    // ReferenceRenderer: when mark i starts drawing, in seconds from now, and for how long (the drawing's sounds land on its ink)
    const startsIn = i => placed[i] ? [placed[i][0] - (performance.now() - t0) / 1000, placed[i][1] - placed[i][0]] : null;
    return { draw, finish, report, svg, placed, edit, hooks, startsIn };
  }

  // ================================================================ 1.6: parts, the things on a card a model can name (DOM-free)
  // A part is what the program's own comments call a piece of the drawing ("// Big bushy tail"), or one text, or a run
  // of statements with no blank line between them. Parts are numbered in program order (p1, p2, ...), so a part keeps
  // its id while the program streams in. Every mark also has an id (m0, m1, ...); marks made by edits start at m2000.
  const EDIT_BASE = 2000;
  function lineIndex(code) {
    const out = []; let pos = 0;
    for (const line of code.split('\n')) {
      const t = line.trim(), rec = { s: pos, blank: !t, full: null, tail: null };
      if (t.startsWith('//')) rec.full = t.replace(/^\/\/+\s*/, '').trim();
      else if (t.startsWith('/*') || t.startsWith('*')) rec.full = t.replace(/^\/?\*+\/?\s*/, '').replace(/\*\/\s*$/, '').trim();
      else if (t) { const k = commentAt(line); if (k >= 0) rec.tail = line.slice(k).replace(/^\/\/+\s*/, '').trim() || null; }
      out.push(rec); pos += line.length + 1;
    }
    return out;
  }
  function commentAt(line) { let q = null; for (let i = 0; i < line.length; i++) { const c = line[i]; if (q) { if (c === '\\') i++; else if (c === q) q = null; } else if (c === '"' || c === "'" || c === '`') q = c; else if (c === '/' && line[i + 1] === '/') return i; } return -1; }
  function lineOf(L, off) { let lo = 0, hi = L.length - 1; while (lo < hi) { const md = (lo + hi + 1) >> 1; if (L[md].s <= off) lo = md; else hi = md - 1; } return lo; }
  const textSize = m => m.size || (m.style === 'title' ? 24 : m.style === 'body' ? 17 : 20);
  // a mark's box [x0, y0, x1, y1] from its data (and the move or scale an edit gave it)
  function markBox(m) {
    if (!m || typeof m !== 'object') return null;
    let b = null; const pad = (m.size || 3) / 2;
    const ptsBox = P => { P = (P || []).filter(p => Array.isArray(p) && isFinite(p[0]) && isFinite(p[1])); if (!P.length) return null; const xs = P.map(p => p[0]), ys = P.map(p => p[1]); return [Math.min(...xs) - pad, Math.min(...ys) - pad, Math.max(...xs) + pad, Math.max(...ys) + pad]; };
    const at = Array.isArray(m.at) ? m.at : null;
    switch (m.do) {
      case 'line': case 'arrow': case 'poly': b = ptsBox(m.pts); break;
      case 'circle': case 'ellipse': if (at) { let rx = +(m.r || m.rx) || 0, ry = +(m.r || m.ry) || 0; if (m.rot) rx = ry = Math.max(rx, ry); b = [at[0] - rx - pad, at[1] - ry - pad, at[0] + rx + pad, at[1] + ry + pad]; } break;
      case 'dot': if (at) { const r = +m.r || 3; b = [at[0] - r, at[1] - r, at[0] + r, at[1] + r]; } break;
      case 'rect': case 'highlight': case 'molecule': case 'stage3d': case 'image': case 'window': if (at) { const w = +m.w || 0, h = +m.h || 0; b = [Math.min(at[0], at[0] + w), Math.min(at[1], at[1] + h), Math.max(at[0], at[0] + w), Math.max(at[1], at[1] + h)]; } break;
      case 'text': if (at) {
        const size = textSize(m), ls = String(m.text).split('\n'), lw = Math.max(...ls.map(s => s.length)) * size * (m.style === 'title' ? 0.56 : 0.47);
        const w = m.fit ? Math.min(m.fit[0], lw) : m.wrap ? Math.min(m.wrap, lw) : lw, n = m.fit || m.wrap ? Math.max(ls.length, Math.ceil(lw / (w || 1))) : ls.length;
        const x = at[0] - (m.anchor === 'middle' ? w / 2 : m.anchor === 'end' ? w : 0), y = at[1] - size * 0.8 - (n > 1 && (m.fit || m.wrap) ? (n - 1) * size * LINE_HEIGHT / 2 : 0);
        b = [x, y, x + w, y + size * 1.05 + (n - 1) * size * LINE_HEIGHT];
      } break;
      case 'path': { const nums = String(m.d || '').match(/-?\d*\.?\d+/g) || [], P = []; if (!/[a-z]/.test(String(m.d).replace(/e-/g, ''))) for (let i = 0; i + 1 < nums.length; i += 2) P.push([+nums[i] + (m.shift ? m.shift[0] : 0), +nums[i + 1] + (m.shift ? m.shift[1] : 0)]); b = ptsBox(P); break; }
    }
    const xf = m.__xf;
    return b && xf ? [b[0] * xf[0] + xf[1], b[1] * xf[0] + xf[2], b[2] * xf[0] + xf[1], b[3] * xf[0] + xf[2]] : b;
  }
  const unionBox = bs => bs.filter(Boolean).reduce((a, b) => a ? [Math.min(a[0], b[0]), Math.min(a[1], b[1]), Math.max(a[2], b[2]), Math.max(a[3], b[3])] : b.slice(), null);
  const fmtBox = b => b ? `[${Math.round(b[0])},${Math.round(b[1])},${Math.round(b[2] - b[0])},${Math.round(b[3] - b[1])}]` : '[?]';
  const clip = (s, n) => { s = String(s).replace(/\s+/g, ' ').trim(); return s.length > n ? s.slice(0, n - 1) + '…' : s; };
  // A 3D part in the card's words: its id (what part() and motions take), kind, size, place and colour.
  const fmt3 = v => Array.isArray(v) ? '[' + v.map(n => +(+n).toFixed(2)).join(',') + ']' : '';
  function describe3dPart(m, withoutPlace) {
    const p = m.params || {}, bits = [m.kind], ends = Array.isArray(p.from) && Array.isArray(p.to);
    for (const k of ['r', 'h', 'size', 'inner', 'outer', 'tube', 'depth']) if (p[k] != null && !(ends && k === 'h')) bits.push(k + '=' + (Array.isArray(p[k]) ? fmt3(p[k]) : +(+p[k]).toFixed(2)));
    if (ends && !withoutPlace) bits.push('from ' + fmt3(p.from) + ' to ' + fmt3(p.to));
    if (Array.isArray(p.points)) bits.push(p.points.length + ' points');
    if (Array.isArray(p.profile)) bits.push('profile of ' + p.profile.length + ' points');
    if (!withoutPlace && ((m.kind !== 'group' && !ends) || (m.pos && m.pos.some(n => +n)))) bits.push('at ' + fmt3(m.pos));
    if (!withoutPlace && m.rotate3 && m.rotate3.some(n => +n)) bits.push('rotate ' + fmt3(m.rotate3));
    const c = m.material && m.material.color; if (c) bits.push(String(c));
    // three-metal: a figure() part's material in the words its program used ('paint coral', 'glass'), and its name (the
    // variable it was assigned to), so a follow-up finds "the piston" without guessing from sizes.
    if (m.three && m.material && (m.material.mat || m.material.tint)) bits.push([m.material.mat, m.material.tint ? toneName(m.material.tint) : null].filter(Boolean).join(' '));
    if (m.parent) bits.push('in ' + m.parent);
    return (m.three && m.name ? m.name + ': ' : '') + bits.join(' ');
  }
  const toneName = c => Object.keys(TONES).find(k => TONES[k].toLowerCase() === String(c).toLowerCase()) || String(c);
  function markLabel(m) {
    if (!m) return '?';
    // ReferenceRenderer: 3D figures and their parts by name, so a follow-up can build on them.
    if (m.do === 'stage3d') return `3D figure ${m.id}`;
    if (m.do === 'part3d') return `${m.id} ${describe3dPart(m)}`;
    if (m.do === 'label3d') return `3D label "${String(m.text).slice(0, 30)}"`;
    if (m.do === 'motion3d') return `3D motion ${(m.op && m.op.kind) || ''} on ${(m.op && m.op.target) || ''}`;
    if (m.do === 'camera3d') return '3D camera';
    if (m.do === 'tick3d') return '3D tick (runs the mechanism every frame)';
    if (m.do === 'text') return `text ${m.style || 'hand'} ${Math.round(textSize(m))} ${m.tone || 'ink'}${m.weight ? ' weight ' + m.weight : ''}`;
    const kind = m.do === 'line' && m.smooth ? 'curve' : m.do, c = [];
    if (m.do === 'highlight') return `highlight ${m.tone || 'butter'}`;
    if (m.do === 'window') return `window${m.title ? ' "' + String(m.title).slice(0, 30) + '"' : ''} ${m.board || 'plain'} board`;
    if (m.do === 'dot') return `dot ${m.tone || 'ink'}`;
    if (m.fill && m.fill !== 'none') c.push('fill ' + m.fill);
    if (m.outline !== false || !m.fill) c.push((c.length ? 'line ' : '') + (m.tone || 'ink'));
    if (((m.do === 'line' || m.do === 'arrow') && m.dash) || m.__dash) c.push('dashed');   // what is drawn: 1.5 ignores dash on closed shapes
    return kind + (c.length ? ' ' + c.join(' ') : '');
  }
  function zoneOf(b, W, H) {
    if (!b) return '';
    const cx = (b[0] + b[2]) / 2 / W, cy = (b[1] + b[3]) / 2 / H;
    const v = cy < 0.34 ? 'top' : cy > 0.66 ? 'bottom' : '', h = cx < 0.34 ? 'left' : cx > 0.66 ? 'right' : '';
    return v && h ? v + '-' + h : v || h || 'centre';
  }
  // o: {code, stmts (from attribute), mark(i), box(i), visible(i), pending(i), says [{k, text, step, turn}], over, added, W, H,
  //     from (ReferenceRenderer: helpers defined before this offset, Mate's own pieces, are not listed), drawnOnly (parts list only
  //     what is drawn: marks still waiting for their line are left out)}
  // ReferenceRenderer: an edit mark ({do: 'edit'}) is never part of a part, and a statement that edits starts a new part. A call of
  // a piece (Mate's paper, sticky, receipt, ...; a helper the program defined; graph, timeline) is a part of its own.
  const PIECE_CALLS = { graph: 1, timeline: 1, molecule: 1 };
  function describe(o) {
    const code = o.code || '', L = lineIndex(code), parts = [], helpers = [], figures = [], mark = o.mark, helperNames = new Set();
    let cur = null, section = null, carry = null, prevEnd = -1;
    const newPart = p => { p.id = 'p' + (parts.length + 1); parts.push(p); return p; };
    const isEdit = i => { const m = mark(i); return !!m && m.do === 'edit'; };
    for (const st of o.stmts || []) {
      let b = st.s;
      for (;;) {                                         // skip blanks and comments before the statement's code
        while (b < st.e && /\s/.test(code[b])) b++;
        if (code.startsWith('//', b)) { const j = code.indexOf('\n', b); b = j < 0 ? st.e : Math.min(j, st.e); continue; }
        if (code.startsWith('/*', b)) { const j = code.indexOf('*/', b + 2); b = j < 0 ? st.e : Math.min(j + 2, st.e); continue; }
        break;
      }
      if (b >= st.e) continue;
      const l0 = lineOf(L, b); let l1 = lineOf(L, Math.max(b, st.e - 1));
      while (l1 > l0 && (L[l1].blank || L[l1].full != null)) l1--;
      const body = code.slice(b, st.e).trim();
      const head = []; for (let k = l0 - 1; k > prevEnd && k >= 0 && L[k].full != null; k--) head.unshift(L[k].full);
      const heading = head.filter(x => x && !/^plan\b/i.test(x)).join(' / ') || null;
      let blank = false; for (let k = prevEnd + 1; k < l0 - head.length; k++) if (L[k] && L[k].blank) blank = true;
      prevEnd = l1;
      const figure = /^(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*scene3d\s*\(/.exec(body);
      if (figure) {
        let stageID = null; for (let i = st.n0; i < st.n1 && !stageID; i++) { const m = mark(i); if (m && m.do === 'stage3d') stageID = m.id; }
        if (stageID) figures.push({ name: figure[1], stage: stageID });
      }
      const fn = figure ? null : /^function\s+([A-Za-z_$][\w$]*)\s*\(([^)]*)\)/.exec(body) || /^(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*(?:function\s*)?\(?([^)=]*?)\)?\s*=>/.exec(body);
      if (fn && b >= (o.from || 0)) helpers.push(fn[1] + '(' + fn[2].replace(/\s+/g, ' ').trim() + ')');
      const named = /^function\s+([A-Za-z_$][\w$]*)/.exec(body) || /^(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*(?:function\b|\(|[A-Za-z_$][\w$]*\s*=>)/.exec(body);
      if (named) helperNames.add(named[1]);
      if (blank) { section = null; carry = null; }
      const ms = []; let edits = 0;
      for (let i = st.n0; i < st.n1; i++) { if (isEdit(i)) edits++; else ms.push(i); }
      if (!ms.length) { if (edits) { cur = null; carry = null; } else if (heading && !fn) carry = heading; else if (fn) carry = null; continue; }
      if (edits) cur = null;
      const own = heading || carry; carry = null;
      if (heading) section = heading;
      const tail = L[l1].tail || L[l0].tail, m0 = mark(ms[0]), step = m0 ? m0.step : null, turn = (m0 && m0.turn) || 1;
      if (ms.every(i => mark(i) && mark(i).do === 'text')) { for (const i of ms) cur = newPart({ marks: [i], step, turn, text: true, desc: null }); continue; }
      const call = /^[A-Za-z_$][\w$.]*\s*\(/.test(body) && !/^(for|if|while|switch)\b/.test(body) ? body.replace(/;$/, '') : null;
      const callee = call && /^([A-Za-z_$][\w$]*)\s*\(/.exec(call), piece = callee && (helperNames.has(callee[1]) || PIECE_CALLS[callee[1]]) ? callee[1] : null;
      const desc = own ? (tail ? own + ': ' + tail : own) : tail ? (section ? section + ': ' + tail : tail) : null;
      if (piece) {
        // its words: the first string passed as an argument (not an option like {tone: 'coral'})
        let args = ''; for (let k = 0, depth = 0, q = null; k < call.length; k++) {
          const ch = call[k];
          if (q) { if (depth === 0) args += ch; if (ch === '\\') { k++; if (depth === 0) args += call[k] || ''; } else if (ch === q) q = null; continue; }
          if (ch === '"' || ch === "'" || ch === '`') { q = ch; if (depth === 0) args += ch; continue; }
          if (ch === '{') depth++; else if (ch === '}') depth = Math.max(0, depth - 1); else if (depth === 0) args += ch;
        }
        const words = /"((?:[^"\\]|\\.)*)"|'((?:[^'\\]|\\.)*)'|`([^`]*)`/.exec(args);
        newPart({ marks: ms, step, turn, stmts: [{ call, n0: st.n0, n1: st.n1 }], piece, pieceText: words ? words[1] || words[2] || words[3] || '' : '', desc });
        cur = null; continue;
      }
      if (!cur || own || tail || cur.text || cur.tail || blank || cur.step !== step || cur.turn !== turn) cur = newPart({ marks: ms, step, turn, tail: !!tail, stmts: [], desc });
      else cur.marks.push(...ms);
      cur.stmts.push({ call, n0: st.n0, n1: st.n1 });
    }
    const over = o.over || {}, box = o.box || (i => markBox(mark(i)));
    const all = parts.concat(o.added || []);
    for (const p of all) {
      const ov = over[p.id]; if (ov) { p.marks = ov.marks.slice(); if (ov.desc) p.desc = ov.desc; p.text = false; }
      p.vis = p.marks.filter(i => mark(i) && !mark(i).__erased && !(o.drawnOnly && o.pending && o.pending(i)));
      p.box = unionBox(p.vis.map(box));
      p.pending = p.vis.filter(i => o.pending && o.pending(i)).length;
    }
    const texts = all.filter(p => p.vis.length === 1 && mark(p.vis[0]).do === 'text');
    for (const p of all) {
      const ms = p.vis.map(mark);
      if (!p.desc && ms.length && p.box && ms.every(m => m.do === 'highlight')) {    // a highlight is named by the words it sits behind
        const on = texts.filter(t => t.box && Math.min(t.box[2], p.box[2]) - Math.max(t.box[0], p.box[0]) > 0.4 * (t.box[2] - t.box[0]) && Math.min(t.box[3], p.box[3]) - Math.max(t.box[1], p.box[1]) > 0.3 * (t.box[3] - t.box[1]));
        if (on.length) p.desc = `highlight behind ${on.map(t => '"' + clip(mark(t.vis[0]).text, 30) + '"').slice(0, 2).join(' and ')}`;
      }
      if (!p.desc && p.piece) p.desc = p.piece + (p.pieceText ? ` "${clip(p.pieceText, 40)}"` : '') + ', ' + zoneOf(p.box, o.W, o.H);
      if (!p.desc) {
        const t = ms.find(m => m.do === 'text'), kinds = [...new Set(ms.map(m => m.do === 'line' && m.smooth ? 'curve' : m.do))];
        p.desc = ms.length === 1 && t ? `"${clip(t.text, 48)}"` : (kinds.slice(0, 3).join(' + ') + (t ? ` with "${clip(t.text, 30)}"` : '') + ', ' + zoneOf(p.box, o.W, o.H));
      }
      p.kind = ms.length && ms.every(m => m.do === 'text') ? 'text' : ms.some(m => m.do === 'text') ? 'mixed' : 'shape';
    }
    return { parts: all, helpers, figures };
  }
  // the card as short lines a model can read: every part with its id, what it is, its box and its marks
  // (ReferenceRenderer: a card drawn over several turns names each turn's steps "Turn 2, step 1"; o.maxChars keeps it short:
  // past it, parts list their mark ranges only, then the oldest parts are summed up in one line)
  function stateText(d, o) {
    if (o && o.maxChars && !o.brief && !o.skip) {
      const full = stateText(d, Object.assign({}, o, { maxChars: 0 }));
      if (full.length <= o.maxChars) return full;
      let brief = stateText(d, Object.assign({}, o, { maxChars: 0, brief: true }));
      const shown = d.parts.filter(p => p.vis.length);
      for (let skip = 1; brief.length > o.maxChars && skip < shown.length; skip++) brief = stateText(d, Object.assign({}, o, { maxChars: 0, brief: true, skip: shown.slice(0, skip) }));
      return brief;
    }
    o = Object.assign({ over: {} }, o);
    const out = [], says = o.says || [], seen = new Set();
    const turnOf = x => (x && x.turn) || 1;
    const multi = says.some(x => turnOf(x) > 1) || d.parts.some(p => p.vis.length && turnOf(p) > 1);
    const sayOf = (turn, step) => says.filter(x => turnOf(x) === turn && x.step === step).map(x => x.text).join(' ');
    out.push(`Card ${o.W} x ${o.H} (x right, y down).${o.request ? ` Asked for: "${clip(o.request, 160)}".` : ''} ${o.status || ''}`.trim());
    if (d.helpers.length) out.push('Helpers the program defined (callable in code): ' + d.helpers.slice(0, 12).join(', '));
    if (d.figures && d.figures.length) out.push('3D figures (constants in the code on the card; build on them, never draw a second copy): ' + d.figures.map(f => `${f.name} is ${f.stage} (its parts: ${f.stage}p1, ${f.stage}p2, … listed below)`).join('; '));
    const markList = p => {
      // one piece (a sticky, a receipt, ...): its marks and the words on it (a small one lists its marks like any part)
      if (p.piece && !o.over[p.id] && (o.brief || p.vis.length > 3 || p.vis.some(i => o.mark(i).do === 'text'))) {
        const words = p.vis.map(o.mark).filter(m => m.do === 'text' && String(m.text) !== p.pieceText).map(m => `"${clip(m.text, 26)}"`);
        const range = p.vis.length > 1 ? `m${p.vis[0]}–m${p.vis[p.vis.length - 1]}` : `m${p.vis[0]}`;
        return `${p.vis.length} mark${p.vis.length > 1 ? 's' : ''} (${range})${words.length ? ', also says ' + words.slice(0, 4).join(', ') + (words.length > 4 ? ', …' : '') : ''}`;
      }
      // a part made of several helper calls (flower(45, 410, 'pink'), ...) lists the calls, each with its marks
      if (o.brief) return `${p.vis.length} mark${p.vis.length > 1 ? 's' : ''} (m${p.vis[0]}${p.vis.length > 1 ? '–m' + p.vis[p.vis.length - 1] : ''})`;
      if (p.stmts && p.stmts.length > 1 && !o.over[p.id] && p.stmts.every(t => t.call && t.n1 - t.n0 >= 3) && !p.vis.some(i => /3d$/.test((o.mark(i) || {}).do || ''))) {
        return p.stmts.map(t => { const v = p.vis.filter(i => i >= t.n0 && i < t.n1); return v.length ? `${clip(t.call, 44)} (m${v[0]}–m${v[v.length - 1]})` : null; }).filter(Boolean).join(' + ');
      }
      const runs = [];
      for (const i of p.vis) {
        const m = o.mark(i);
        // A row of the same 3D part (hangers, rungs, bolts) is one line with its id range, so a big figure still fits
        // the card's words.
        const lab = m && m.do === 'part3d' ? 'part3d|' + describe3dPart(m, true) : markLabel(m), last = runs[runs.length - 1];
        if (last && last.lab === lab && m.do !== 'text' && last.b === i - 1) { last.b = i; last.n++; last.end = m; } else runs.push({ lab, a: i, b: i, n: 1, m, end: m });
      }
      return runs.map(r => r.lab.startsWith('part3d|')
        ? (r.n > 1 ? `${r.n}× ${r.m.id}–${r.end.id} ${r.lab.slice(7)} (m${r.a}–m${r.b})` : `${markLabel(r.m)} (m${r.a})`)
        : (r.n > 1 ? r.n + '× ' : '') + r.lab + (r.m.do === 'text' && p.vis.length > 1 ? ` "${clip(r.m.text, 30)}"` : '') + ` (m${r.a}${r.n > 1 ? '–m' + r.b : ''})`).join(' + ');
    };
    const skipped = new Set(o.skip || []);
    if (skipped.size) {                                // their ids as ranges: p1–p62, x1
      const runs = [];
      for (const id of [...skipped].map(p => String(p.id))) {
        const m = /^([a-z]+)(\d+)$/.exec(id), last = runs[runs.length - 1];
        if (m && last && last.pre === m[1] && last.b + 1 === +m[2]) last.b = +m[2]; else runs.push(m ? { pre: m[1], a: +m[2], b: +m[2] } : { id });
      }
      out.push(`(${skipped.size} older parts not listed: ${runs.map(r => r.id || (r.a === r.b ? r.pre + r.a : `${r.pre}${r.a}–${r.pre}${r.b}`)).join(', ')})`);
    }
    for (const p of d.parts) {
      if (!p.vis.length || skipped.has(p)) continue;
      const key = turnOf(p) + '/' + p.step;
      if (p.step != null && !seen.has(key) && !String(p.id).startsWith('x')) {
        seen.add(key); const said = sayOf(turnOf(p), p.step);
        out.push(`${multi ? `Turn ${turnOf(p)}, step ${p.step}` : `Step ${p.step}`}${said ? ` · Mate said: "${clip(said, 170)}"` : ''}`);
      }
      if (String(p.id).startsWith('x') && !seen.has('x')) { seen.add('x'); out.push('Added by edits:'); }
      out.push(`  ${p.id} ${clip(p.desc, 70)} ${fmtBox(p.box)}: ${markList(p)}${p.pending ? (p.pending === p.vis.length ? ' (not drawn yet)' : ` (${p.pending} not drawn yet)`) : ''}`);
    }
    const shown = d.parts.filter(p => p.vis.length);
    const newest = shown.filter(p => !p.pending).slice(-1)[0];
    const tail = [];
    if (newest) tail.push(`newest part: ${newest.id}`);
    if (o.last) tail.push(`last changed: ${o.last}`);
    if (o.pointed) tail.push(`the user is pointing at: ${o.pointed}`);
    if (tail.length) out.push(tail.join(' · '));
    return out.join('\n');
  }

  // ================================================================ 1.6: the editor behind live(): ops, undo and the model's view
  // Ops (one JSON object each): recolor, restyle, move, moveTo, scale, erase, redraw, add, highlight, undo.
  // say / new / none are for the host (the voice, or starting a new drawing); the editor just reports them.
  const COLOR_WORDS = { yellow: 'sun', gold: 'sun', golden: 'sun', purple: 'violet', lavender: 'lilac', green: 'leaf', lightgreen: 'mint', darkgreen: 'leaf', lightblue: 'sky', darkblue: 'blue', navy: 'blue',
    black: 'ink', gray: 'grey', lightgrey: 'grey', lightgray: 'grey', beige: 'cream', rose: 'pink', magenta: 'pink', salmon: 'peach', skyblue: 'sky', lime: 'mint', teal: '#2A9D8F', turquoise: '#2EC4B6' };
  const DARKER = { butter: 'orange', sun: 'orange', orange: 'brown', peach: 'coral', coral: 'red', red: '#A32A2E', pink: 'coral', lilac: 'violet', violet: '#4A3AA8', sky: 'blue', blue: '#173F8A',
    mint: 'leaf', leaf: '#2A6E40', brown: '#5E3A1F', tan: 'brown', cream: 'tan', white: 'grey', grey: 'ink', ink: 'ink' };
  const normColor = c => { if (c == null) return c; const k = String(c).toLowerCase().replace(/[\s_-]+/g, ''); return TONES[k] ? k : COLOR_WORDS[k] || String(c).trim(); };
  function darker(c) {
    if (DARKER[c]) return DARKER[c];
    const h = /^#?([0-9a-f]{6})$/i.exec(TONES[c] || c || ''); if (!h) return c;
    const v = parseInt(h[1], 16); return '#' + [v >> 16, (v >> 8) & 255, v & 255].map(x => Math.round(x * 0.62).toString(16).padStart(2, '0')).join('');
  }
  const FIELDS = ['tone', 'fill', 'fillAlpha', 'outline', 'style', 'size', 'weight', 'dash', '__dash', 'brush', 'alpha'];
  const snapOf = m => { const f = {}; for (const k of FIELDS) f[k] = k in m ? m[k] : undefined; return f; };
  const restoreOf = (m, f) => { for (const k of FIELDS) if (f[k] === undefined) delete m[k]; else m[k] = f[k]; };
  function recolorMark(m, op) {
    if (m.do === 'part3d') {
      // ReferenceRenderer: a 3D part's colour is its material's (tone and fill mean nothing inside a figure); the repaint
      // sends the part again under its id and the stage swaps it in place.
      const c = op.color != null ? op.color : op.fill != null ? op.fill : op.line != null ? op.line : op.tone;
      if (c != null) m.material = Object.assign({}, m.material, { color: m.three ? realTone(normColor(c)) : tone(normColor(c)) });
      return;
    }
    const color = normColor(op.color), fill = normColor(op.fill), line = normColor(op.line != null ? op.line : op.tone);
    if (fill != null && m.do !== 'text' && m.do !== 'line' && m.do !== 'arrow') m.fill = fill;
    if (line != null) m.tone = line;
    if (color == null || fill != null || line != null) return;
    const filled = m.fill && m.fill !== 'none' && ['circle', 'ellipse', 'rect', 'poly', 'path'].includes(m.do);
    if (!filled) { m.tone = color; return; }
    const tonal = m.tone && m.tone !== m.fill && m.outline !== false;
    m.fill = color; if (tonal) m.tone = darker(color);
  }
  function restyleMark(m, op) {
    // ReferenceRenderer: a 3D label's size is its words' size (15 to 28, as label() takes it), not a pen width.
    if (m.do === 'label3d') {
      if (op.size != null && +op.size > 0) m.size = Math.max(15, Math.min(28, +op.size));
      if (op.color != null || op.fill != null || op.line != null) recolorMark(m, op);
      return;
    }
    const isText = m.do === 'text';
    if (isText) {
      // ReferenceRenderer: the drawing guide teaches o.style ('hand' | 'title' | 'body'); o.font is the lab's older name.
      const font = op.font != null ? op.font : op.style;
      if (font != null) m.style = ({ handwriting: 'hand', handwritten: 'hand', rounded: 'title', bold: 'title', plain: 'body', sans: 'body', typewriter: 'mono', code: 'mono' })[font] || font;
      if (op.size != null && +op.size > 0) m.size = Math.max(13, Math.min(72, +op.size));
      if (op.weight != null) m.weight = op.weight === 'bold' ? 700 : op.weight === 'normal' ? 400 : op.weight;
    } else {
      const w = op.width != null ? op.width : op.size;
      if (w != null && +w > 0) m.size = Math.max(1, Math.min(14, +w));
      if (op.dash != null) {
        const on = op.dash === false || op.dash === 'none' ? undefined : op.dash;
        if (m.do === 'line' || m.do === 'arrow') m.dash = on; else if (['circle', 'ellipse', 'rect', 'poly', 'path'].includes(m.do)) m.__dash = on;
      }
      if (op.brush != null && ['pen', 'marker', 'pencil', 'brush'].includes(op.brush)) m.brush = op.brush;
    }
    if (op.color != null || op.fill != null || op.line != null) recolorMark(m, op);
  }
  // ReferenceRenderer: what points at the user's screen (it means nothing once the screen changes) and what is a card
  // (paper, a photo, a 3D figure: it means the same over any screen). Free sketches are neither.
  const POINTING_ROLES = new Set(['point', 'target', 'hover', 'type', 'ring', 'frame', 'underline', 'check', 'cross', 'strike',
    'scroll', 'label', 'num', 'connect', 'trace']);
  const pointsAtScreen = m => !!m && (POINTING_ROLES.has(m.role) || m.do === 'highlight');
  const isCardMark = m => !!m && (m.role === 'paper' || m.role === 'photo' || (m.do === 'image' && m.role !== 'source')
    || m.do === 'scene3d' || m.do === 'part3d' || m.do === 'label3d' || m.stage != null);
  // on a card: the mark's middle sits on a card (tape and a title can stick out a little). Null with no card.
  function onCardTest(cardBoxes) {
    if (!cardBoxes.length) return null;
    return b => { const cx = (b[0] + b[2]) / 2, cy = (b[1] + b[3]) / 2; return cardBoxes.some(n => cx >= n[0] - 12 && cx <= n[2] + 12 && cy >= n[1] - 12 && cy <= n[3] + 12); };
  }
  function Editor(s, st, spec, opts) {
    const W = spec.w || 400, H = spec.h || 300, E = s.edit;
    const sandboxed = opts.sandbox === 'worker' && typeof Worker !== 'undefined';
    let attr = { code: null, stmts: [] }, nextMark = EDIT_BASE, nextPart = 0, last = null, chain = Promise.resolve();
    const added = [], over = {}, hist = [], key = {}, log = [];
    // ReferenceRenderer: the mark sets the user dragged as one card: each stays one card, apart from whatever it was dropped on
    const userCards = [];
    const mark = i => i >= EDIT_BASE ? E.MK[i] : (st.marks[i] || E.MK[i]);
    const drawn = i => !!(E.NODES[i] && E.NODES[i].length) && !(mark(i) && mark(i).__erased);
    const pending = i => i < EDIT_BASE && !!st.marks[i] && !E.NODES[i] && !st.marks[i].__skip;
    const keyOf = i => key[i] != null ? key[i] : i;
    const box = i => (drawn(i) && E.domBox(i)) || markBox(mark(i));
    // ReferenceRenderer: the marks on the card now, edits' own marks included; and the on-a-card test for them
    const visibleMarkIndexes = () => {
      const all = [];
      for (let i = 0; i < st.marks.length; i++) all.push(i);
      for (const k of Object.keys(E.MK)) if (+k >= EDIT_BASE) all.push(+k);
      return all.filter(i => { const m = mark(i); return m && m.do !== 'edit' && drawn(i); });
    };
    const cardTest = visible => onCardTest(visible.filter(i => isCardMark(mark(i))).map(box).filter(Boolean));
    const describeWith = (stmts, o) => describe({ code: st.code, stmts, mark, box, pending, over, added, W, H, from: opts.codeStart || 0, drawnOnly: !!(o && o.drawnOnly) });
    async function attribution() {
      const code = st.code;
      if (attr.code === code) return attr.stmts;
      const stmts = sandboxed ? ((await sandboxJob({ type: 'attrib', code, w: W, h: H })).stmts || []) : RUNNER.attribute(code, W, H);
      attr = { code, stmts }; return stmts;
    }
    // ReferenceRenderer: the same right now, for program edits and a synchronous state() (a sandboxed drawing answers with the last
    // attribution its worker gave: running the model's code in the page is what the sandbox is there to avoid)
    function attributionNow() {
      const code = st.code;
      if (attr.code === code || sandboxed) return attr.stmts;
      attr = { code, stmts: RUNNER.attribute(code, W, H) }; return attr.stmts;
    }
    async function parts() { return describeWith(await attribution()); }
    const partsNow = o => describeWith(attributionNow(), o);
    const statusOf = () => st.finished || (st.done && !st.paused) ? 'The drawing is finished.' : st.paused ? 'The drawing is paused mid-way (more may still come).' : 'The drawing is still being drawn.';
    async function state(o = {}) {
      return stateText(await parts(), { W, H, mark, says: st.log.lines, request: o.request, status: statusOf(), last, pointed: o.pointed, over });
    }
    function stateNow(o = {}) {
      return stateText(partsNow(o), { W, H, mark, says: st.log.lines, request: o.request, status: o.status != null ? o.status : statusOf(), last, pointed: o.pointed, over, maxChars: o.maxChars });
    }
    function resolve(id, P) {
      const list = Array.isArray(id) ? id : String(id == null ? '' : id).split(/[\s,]+/).filter(Boolean), out = [], bad = [], ps = [];
      for (const raw of list) {
        const t = String(raw).trim(); let r;
        const p = P.find(q => q.id === t);
        if (p) { out.push(...p.vis); ps.push(p); }
        else if ((r = /^m(\d+)\s*[-–]\s*m?(\d+)$/.exec(t))) { for (let k = +r[1]; k <= +r[2]; k++) out.push(k); }
        else if ((r = /^m(\d+)$/.exec(t))) out.push(+r[1]);
        else bad.push(t);
      }
      const marks = [...new Set(out)].filter(i => mark(i) && !mark(i).__erased && mark(i).do !== 'edit');
      return { marks, bad, parts: ps };
    }
    // draw the marks again over themselves, then lift the old strokes off; returns when the last one is done (s from now)
    function repaint(ms, p, at0) {
      let at = at0 || 0, end = at;
      for (const i of ms) {
        const m = mark(i);
        if (!drawn(i)) continue;
        const oldN = E.NODES[i], oldM = E.MASKS[i], oldText = oldN.find(n => n.tagName === 'text');
        const r = E.paintAt(m, i, keyOf(i), at, p, true);
        const nt = r.nodes.find(n => n.tagName === 'text');
        if (oldText && nt && oldText.__nudge) { nt.__nudge = oldText.__nudge; nt.setAttribute('transform', `translate(${oldText.__nudge[0].toFixed(1)} ${oldText.__nudge[1].toFixed(1)}) ` + (nt.getAttribute('transform') || '')); }
        const cross = m.do === 'text' || m.do === 'dot' || m.do === 'molecule' || m.do === 'highlight';
        const liftAt = cross ? at : at + r.dur, lift = cross ? Math.max(0.2, r.dur) : 0.08;
        E.unpaint(oldN, oldM, liftAt, lift);
        end = Math.max(end, at + r.dur, liftAt + lift);
        at += r.adv;
      }
      return end;
    }
    function paintNew(ms, at, p) { let end = at; for (const i of ms) { if (mark(i).__skip) continue; const r = E.paintAt(mark(i), i, keyOf(i), at, p); end = Math.max(end, at + r.dur); at += r.adv; } return end; }
    // the pen runs backwards over each mark, last drawn first (o.brisk: startOver's quicker sweep); returns when it is done
    function erase(ms, at, o) {
      o = o || {};
      const order = [...ms].reverse(), n = order.filter(drawn).length, stagger = eraseStagger(n, o.brisk), d = ERASE_DUR * (o.pace || 1);
      let t = at || 0, end = t;
      for (const i of order) { const m = mark(i); if (drawn(i)) { E.unpaint(E.NODES[i], E.MASKS[i], t, d); end = t + d; t += stagger; } m.__erased = true; m.__skip = true; }
      return end;
    }
    function unerase(ms, at) { const toPaint = []; for (const i of ms) { const m = mark(i); m.__erased = false; m.__skip = false; if (i >= EDIT_BASE || E.NODES[i] || m.__passed) toPaint.push(i); } return paintNew(toPaint, at, 0.8); }
    async function run(frag) {
      const base = st.code, code = String(frag || '').replace(/^\s*```(?:js|javascript)?\s*\n?/, '').replace(/```\s*$/, '');
      const r = sandboxed ? await sandboxJob({ type: 'exec', base, code, w: W, h: H }) : RUNNER.exec(base, code, W, H, 1200);
      // forgiving with an edit's own marks (only these): color / stroke mean tone, width means size
      const ids = (r.marks || []).map(m => { if (m.tone == null && (m.color || m.stroke || typeof m.line === 'string')) m.tone = m.color || m.stroke || m.line; if (m.size == null && +m.width > 0 && m.do !== 'text') m.size = +m.width; const i = nextMark++; E.MK[i] = m; return i; });
      return { ids, error: r.error, says: r.says || [] };
    }
    const clampK = k => Math.max(0.25, Math.min(4, isFinite(k) && k > 0 ? k : 1));
    function clusters(ms, box) {                        // marks whose boxes touch (with a little slack) belong together
      const bs = ms.map(box), all = unionBox(bs); if (!all) return [ms];
      const pad = Math.max(10, 0.06 * Math.hypot(all[2] - all[0], all[3] - all[1])), up = ms.map((_, j) => j);
      const find = j => up[j] === j ? j : (up[j] = find(up[j]));
      for (let a = 0; a < ms.length; a++) for (let b = a + 1; b < ms.length; b++) {
        const A = bs[a], B = bs[b]; if (!A || !B) continue;
        if (A[0] - pad <= B[2] && B[0] - pad <= A[2] && A[1] - pad <= B[3] && B[1] - pad <= A[3]) up[find(a)] = find(b);
      }
      const g = {}; ms.forEach((i, j) => (g[find(j)] = g[find(j)] || []).push(i)); return Object.values(g);
    }
    // ReferenceRenderer: everything on the card before mark `before` (every mark when null): what startOver un-draws
    function everything(before) {
      const out = [], n = before == null ? st.marks.length : Math.min(before, st.marks.length);
      for (let i = 0; i < n; i++) { const m = st.marks[i]; if (m && m.do !== 'edit' && !m.__erased) out.push(i); }
      for (const k of Object.keys(E.MK)) { const i = +k; if (i >= EDIT_BASE && E.MK[i] && !E.MK[i].__erased && drawn(i)) out.push(i); }
      return out;
    }
    // one op. P: the parts; frag: what an add or redraw's code drew; T: {at: s from now, pace, index: the program's edit mark};
    // fills res and returns when its animation ends (s from now)
    function core(op, P, frag, T, res) {
      const kind = op.op, pace = T.pace || 1, at = T.at || 0;
      const seen = () => { if (res.visibleAt == null) res.visibleAt = performance.now(); };
      if (kind === 'add') {
        const r = frag; if (r.error) res.warning = r.error;
        if (!r.ids.length) throw new Error('the code drew nothing' + (r.error ? ': ' + r.error : ''));
        const id = 'x' + (++nextPart), p = { id, desc: op.desc || 'added', marks: r.ids, step: null };
        r.ids.forEach(i => { key[i] = 1e6 + i; });
        added.push(p); seen(); const end = paintNew(r.ids, at, pace);
        hist.push(() => { erase(r.ids, 0); added.splice(added.indexOf(p), 1); });
        last = id; res.touched = [id]; return end;
      }
      if (kind === 'startOver') {
        const ms = everything(T.index);
        if (!ms.length) { res.touched = []; return at; }          // an empty card (a fresh drawing that starts over): nothing to do
        seen(); const end = erase(ms, at, { brisk: true, pace });
        hist.push(() => unerase(ms, 0));
        res.touched = ms.map(i => 'm' + i); last = 'everything (startOver)'; return end;
      }
      const R = resolve(op.id != null ? op.id : op.ids != null ? op.ids : op.target, P);
      // ReferenceRenderer: a program's edit (T.index: its own mark) changes what was on the card before it, never what the
      // program draws after it. A part is found by place, so when a follow-up erased the old card ("p1") and drew its
      // new card in the same spot, the new card counted as p1 too and was erased (skipped) before it was ever drawn:
      // the voice told the answer over an empty screen. planMark already counts only the marks before the edit.
      if (T.index != null) R.marks = R.marks.filter(k => k < T.index || k >= EDIT_BASE);
      if (R.bad.length && !R.marks.length) throw new Error('unknown id ' + R.bad.join(', '));
      if (!R.marks.length) throw new Error('nothing left to change in ' + JSON.stringify(op.id));
      if (R.bad.length) res.warning = 'unknown id ' + R.bad.join(', ');
      const ms = R.marks, label = R.parts.length ? R.parts.map(p => p.id).join(',') : ms.map(i => 'm' + i).join(',');
      res.touched = R.parts.length ? R.parts.map(p => p.id) : ms.map(i => 'm' + i);
      let end = at;
      if (kind === 'recolor' || kind === 'restyle') {
        // A 3D figure's own mark has no colour or style of its own (its parts do), and painting it again builds an
        // empty figure in its place (asked to spin faster, models restyle it and the whole figure vanished); painting
        // a motion again runs it twice.
        const painted = ms.filter(i => !['stage3d', 'motion3d', 'camera3d'].includes((mark(i) || {}).do));
        if (!painted.length) throw new Error('a 3D figure changes through its parts (recolor their m-numbers) or its camera');
        const snap = painted.map(i => [i, snapOf(mark(i))]);
        for (const i of painted) (kind === 'recolor' ? recolorMark : restyleMark)(mark(i), op);
        seen(); end = repaint(painted, REPAINT_PACE * pace, at);
        hist.push(() => { snap.forEach(([i, f]) => restoreOf(mark(i), f)); repaint(painted, REPAINT_PACE); });
      } else if (kind === 'scale' && ms.every(i => (mark(i) || {}).do === 'part3d')) {
        // ReferenceRenderer: 3D parts grow or shrink in place, in the figure (a 2D transform can't reach them).
        const k3 = clampK(+(op.k != null ? op.k : op.factor));
        const snap3 = ms.map(i => [i, mark(i).scale3]);
        for (const i of ms) mark(i).scale3 = (+mark(i).scale3 || 1) * k3;
        seen(); end = repaint(ms, REPAINT_PACE * pace, at);
        hist.push(() => { snap3.forEach(([i, k]) => { mark(i).scale3 = k; }); repaint(ms, REPAINT_PACE); });
      } else if (kind === 'move' || kind === 'moveTo' || kind === 'scale') {
        if (!unionBox(ms.map(box))) throw new Error('cannot tell where ' + label + ' is');
        const kIn = kind === 'scale' ? clampK(+(op.k != null ? op.k : op.factor)) : 1, glide = GLIDE_DUR * pace;
        // a scale grows each separate thing in place (scattered leaves each get bigger; a fox made of touching parts grows as one)
        const groups = kind === 'scale' && op.each !== false ? clusters(ms, box) : [ms];
        const snap = ms.map(i => [i, mark(i).__xf ? mark(i).__xf.slice() : null]);
        seen();
        for (const g of groups) {
          const b = unionBox(g.map(box)); if (!b) continue;
          const cx = (b[0] + b[2]) / 2, cy = (b[1] + b[3]) / 2;
          let dx = +op.dx || 0, dy = +op.dy || 0;
          // never grow a thing past the card (it would be clipped): limit the scale to what fits
          const kFit = Math.min((W - 8) / Math.max(1, b[2] - b[0]), (H - 8) / Math.max(1, b[3] - b[1]));
          const k = kIn > 1 ? Math.max(1, Math.min(kIn, kFit)) : kIn;
          if (k < kIn) res.note = `scale limited to ${k.toFixed(2)} so it stays on the card`;
          if (kind === 'moveTo') { dx = (isFinite(+op.x) ? +op.x : cx) - cx; dy = (isFinite(+op.y) ? +op.y : cy) - cy; }
          // keep it on the card
          const nb = [cx + (b[0] - cx) * k + dx, cy + (b[1] - cy) * k + dy, cx + (b[2] - cx) * k + dx, cy + (b[3] - cy) * k + dy];
          if (nb[2] - nb[0] <= W - 8) { if (nb[0] < 4) dx += 4 - nb[0]; else if (nb[2] > W - 4) dx -= nb[2] - (W - 4); }
          if (nb[3] - nb[1] <= H - 8) { if (nb[1] < 4) dy += 4 - nb[1]; else if (nb[3] > H - 4) dy -= nb[3] - (H - 4); }
          for (const i of g) { const m = mark(i), a = m.__xf || [1, 0, 0]; m.__xf = [a[0] * k, k * a[1] + cx * (1 - k) + dx, k * a[2] + cy * (1 - k) + dy]; if (drawn(i)) { E.moveNodes(E.NODES[i], m.__xf, at, glide); end = at + glide; } }
        }
        hist.push(() => { for (const [i, xf] of snap) { const m = mark(i); if (xf) m.__xf = xf; else delete m.__xf; if (drawn(i)) E.moveNodes(E.NODES[i], xf || [1, 0, 0], 0, GLIDE_DUR); } });
      } else if (kind === 'erase') {
        const was = ms.filter(i => !mark(i).__skip || drawn(i));
        seen(); end = erase(ms, at, { pace });
        hist.push(() => unerase(was, 0));
      } else if (kind === 'redraw') {
        const r = frag; if (r.error) res.warning = r.error;
        if (!r.ids.length) throw new Error('the code drew nothing' + (r.error ? ': ' + r.error : ''));
        const k0 = Math.min(...ms.map(keyOf)); r.ids.forEach((i, j) => { key[i] = k0 + 0.5 * (j + 1) / (r.ids.length + 1); });
        const p = R.parts.length === 1 ? R.parts[0] : null, prev = p ? over[p.id] : null;
        seen(); const t = erase(ms, at); end = Math.max(t, paintNew(r.ids, at + Math.min(0.3, 0.05 * ms.length), 1));
        let xp = null;
        if (p && !String(p.id).startsWith('x')) over[p.id] = { marks: r.ids, desc: op.desc || p.desc };
        else if (p) { xp = p; xp.prevMarks = xp.marks; xp.marks = r.ids; if (op.desc) xp.desc = op.desc; }
        else { xp = { id: 'x' + (++nextPart), desc: op.desc || 'redrawn part', marks: r.ids, step: null }; added.push(xp); }
        hist.push(() => { erase(r.ids, 0); unerase(ms, 0.2); if (p && !String(p.id).startsWith('x')) { if (prev) over[p.id] = prev; else delete over[p.id]; } else if (p) xp.marks = xp.prevMarks; else added.splice(added.indexOf(xp), 1); });
        if (p) res.touched = [p.id];
      } else if (kind === 'highlight') {
        // Mate's coral marker: behind words, traced along a thin stroke (an axis, an arrow), or a loose ring around a
        // thing; one per separate target, so two far-apart things do not get one huge loop around both
        if (!unionBox(ms.map(box))) throw new Error('cannot tell where ' + label + ' is');
        const tone = normColor(op.color) || 'coral', idx = [];
        for (const g of clusters(ms, box)) {
          const b = unionBox(g.map(box)); if (!b) continue;
          const w = b[2] - b[0], h = b[3] - b[1], gm = g.map(mark);
          const thin = gm.every(m => (m.do === 'line' || m.do === 'arrow') && Array.isArray(m.pts)) && (g.length <= 3 || Math.min(w, h) < 0.25 * Math.max(w, h));
          let hms;
          if (gm.every(m => m.do === 'text')) hms = [{ do: 'highlight', at: [b[0] - 6, b[1] - 2], w: w + 12, h: h + 4, tone }];
          else if (thin) hms = gm.map(m => { const xf = m.__xf || [1, 0, 0]; return { do: 'line', pts: m.pts.filter(Array.isArray).map(p => [p[0] * xf[0] + xf[1], p[1] * xf[0] + xf[2]]), smooth: m.smooth, brush: 'marker', size: 13, alpha: 0.5, tone, taper: 0.4 }; });
          else hms = [{ do: 'ellipse', at: [(b[0] + b[2]) / 2, (b[1] + b[3]) / 2], rx: Math.min(W / 2, w / 2 * 1.12 + 12), ry: Math.min(H / 2, h / 2 * 1.12 + 12), tone, size: 4.5, wobble: 1.6 }];
          for (const hm of hms) { const i = nextMark++; E.MK[i] = hm; key[i] = 1e6 + i; idx.push(i); }
        }
        const p = { id: 'x' + (++nextPart), desc: 'coral mark on ' + label, marks: idx, step: null };
        added.push(p); seen(); end = paintNew(idx, at, 0.8 * pace);
        hist.push(() => { erase(idx, 0); added.splice(added.indexOf(p), 1); });
        res.touched = [p.id]; res.target = label;
      } else throw new Error('unknown op "' + kind + '"');
      last = `${res.target || res.touched.join(',')} (${kind})`;         // "that one" after a highlight means what was highlighted
      return end;
    }
    async function apply(op) {
      const t0 = performance.now(), res = { op: op && op.op, ok: true, visibleAt: null };
      try {
        if (!op || typeof op !== 'object') throw new Error('not an op');
        const kind = op.op;
        if (kind === 'say' || kind === 'new' || kind === 'none') { res.host = true; return res; }
        if (kind === 'undo') { const f = hist.pop(); if (!f) throw new Error('nothing to undo'); res.visibleAt = performance.now(); await f(); last = 'undo'; return res; }
        const P = (await parts()).parts;
        const frag = kind === 'add' || kind === 'redraw' ? await run(op.code) : null;
        core(op, P, frag, { at: 0, pace: 1 }, res);
        return res;
      } catch (e) { res.ok = false; res.error = String(e && e.message || e); return res; }
      finally { res.ms = +(performance.now() - t0).toFixed(1); log.push(Object.assign({ at: performance.now() }, res)); }
    }
    // ReferenceRenderer: an op right now (the program's edits). res.dur: how long its animation runs
    const PROGRAM_OPS = { erase: 1, recolor: 1, restyle: 1, move: 1, moveTo: 1, scale: 1, highlight: 1, startOver: 1 };
    function applyNow(op, T) {
      const t0 = performance.now(), res = { op: op && op.op, ok: true, visibleAt: null, dur: 0 };
      try {
        if (!op || typeof op !== 'object' || !PROGRAM_OPS[op.op]) throw new Error('not an edit a program can make: ' + (op && op.op));
        const P = op.op === 'startOver' ? [] : partsNow().parts;
        res.dur = Math.max(0, core(op, P, null, T, res) - (T.at || 0));
      } catch (e) { res.ok = false; res.error = String(e && e.message || e); res.dur = 0; }
      finally { res.ms = +(performance.now() - t0).toFixed(1); log.push(Object.assign({ at: performance.now() }, res)); }
      return res;
    }
    // a program's edit mark, drawn at startAt (the card's seconds) at `pace`; returns how long it takes
    function runMark(m, i, startAt, pace) {
      const op = m.op || {};
      if (op.op === 'turn') return 0;
      const res = applyNow(Object.assign({}, op), { at: Math.max(0, startAt - E.now()), pace: pace || 1, index: i });
      const call = `${op.op}(${op.id != null ? JSON.stringify(op.id) : ''})`;
      if (!res.ok) s.report.warnings.push(`${call} changed nothing: ${res.error}`);
      else if (res.warning) s.report.warnings.push(`${call}: ${res.warning}`);
      m.__result = { ok: res.ok, error: res.error || null, touched: res.touched || [], dur: +res.dur.toFixed(3) };
      return res.dur;
    }
    // a program's edit mark as it arrives, before it is drawn: how long it will take (m.__est, for the pacer) and what it
    // takes off the paper for the layout ({reset} for startOver, {forget: [mark indices]} for erase)
    function planMark(m, i) {
      const op = m.op || {};
      if (op.op === 'turn') return null;
      let touched = [];
      try {
        if (op.op === 'startOver') touched = everything(i);
        else if (op.id != null) touched = resolve(op.id, partsNow().parts).marks.filter(k => k < i || k >= EDIT_BASE);
      } catch (_) { touched = []; }
      m.__est = editEstimate(op, touched.map(mark));
      return op.op === 'startOver' ? { reset: true } : op.op === 'erase' ? { forget: touched } : null;
    }
    // marks drawn on the card now (not erased), edits' own marks included
    function visibleCount() {
      let n = 0;
      for (let i = 0; i < st.marks.length; i++) { const m = st.marks[i]; if (m && m.do !== 'edit' && drawn(i)) n++; }
      for (const k of Object.keys(E.MK)) if (+k >= EDIT_BASE && drawn(+k)) n++;
      return n;
    }
    // ReferenceRenderer: how many marks still show ink. Mate's pieces leave invisible dots where the app acts (a button's
    // spot, a hand-off, a sound, typed or copied text, a page to open); they count as drawn but show nothing, so a
    // drawing whose cards were all closed still looked unfinished and kept its Clear pill.
    function inkCount() {
      return visibleMarkIndexes().filter(i => { const m = mark(i); return !(m.do === 'dot' && m.fillAlpha === 0 && m.outline === false); }).length;
    }
    return {
      // ops run in order; each returns {ok, error, visibleAt, touched}
      edit(op) { const p = chain.then(() => apply(op)); chain = p.catch(() => {}); return p; },
      undo() { return this.edit({ op: 'undo' }); },
      settle() { E.settle(); },
      state, parts: async () => (await parts()).parts.map(p => ({ id: p.id, desc: p.desc, kind: p.kind, box: p.box, marks: p.vis.slice(), pending: p.pending, step: p.step })),
      // ReferenceRenderer, synchronous: the card's state and parts now, a program's edit marks, and how much is on the card
      stateNow, partsNow: o => partsNow(o).parts.map(p => ({ id: p.id, desc: p.desc, kind: p.kind, box: p.box, marks: p.vis.slice(), pending: p.pending, step: p.step, turn: p.turn })),
      runMark, planMark, visibleCount, inkCount,
      // marks a new turn takes off the card for good (they came from a statement that failed): the pen runs back over them
      dropNow(ms) { erase(ms, 0, { brisk: true }); for (const i of ms) { const m = mark(i); if (m) m.__dropped = true; } },
      // ReferenceRenderer: the screen under a finished drawing changed. Marks that point at the screen (rings, frames, pills,
      // arrows, underlines, ink drawn over the page) no longer line up with anything and are erased; paper cards,
      // photos and 3D figures, and everything drawn on them, stay. Returns {kept, dropped}; nothing is erased when no
      // card is on the card (kept 0: the host clears the whole drawing as before).
      keepNotesOnly() {
        const visible = visibleMarkIndexes();
        const onACard = cardTest(visible);
        if (!onACard) return { kept: 0, dropped: 0 };
        const drop = visible.filter(i => { const m = mark(i); if (isCardMark(m) || m.role === 'tie') return false; const b = box(i); return !(b && onACard(b)); });
        if (drop.length) this.dropNow(drop);
        return { kept: visible.length - drop.length, dropped: drop.length };
      },
      // ReferenceRenderer: the screen changed while an answer was still being told. Only what points at the screen goes (rings,
      // frames, pills, badges, ticks, arrows between things on screen); cards and free sketches stay, and the answer
      // goes on. Returns {dropped, left} (left: marks still on the card).
      dropPointing() {
        const visible = visibleMarkIndexes();
        const onACard = cardTest(visible) || (() => false);
        const drop = visible.filter(i => { const m = mark(i); const b = box(i); return pointsAtScreen(m) && !(b && onACard(b)); });
        if (drop.length) this.dropNow(drop);
        return { dropped: drop.length, left: visible.length - drop.length };
      },
      // ReferenceRenderer: the cards the user can drag somewhere else on the screen (paper, stickies, receipts, clippings,
      // photos). Card marks that touch are one card; every other mark whose middle sits on a card rides with it (the
      // same test keepNotesOnly keeps by), on the smallest card when two are close. A card the user already moved keeps
      // exactly what it carried and never joins a card it was dropped on. 3D figures turn by their own handle and tie()
      // arrows join two things, so neither moves. Each card: {box [x0, y0, x1, y1], marks, nodes (drawn)}.
      cardsNow() {
        const visible = visibleMarkIndexes();
        const userCardOf = new Map();
        userCards.forEach((set, g) => set.forEach(i => userCardOf.set(i, g)));
        const is3D = m => m.do === 'scene3d' || m.do === 'part3d' || m.do === 'label3d' || m.do === 'stage3d' || m.stage != null;
        const cardMarks = visible.filter(i => { const m = mark(i); return isCardMark(m) && !is3D(m) && m.role !== 'source'; })
          .map(i => ({ i, b: box(i) })).filter(c => c.b);
        if (!cardMarks.length) return [];
        const up = cardMarks.map((_, j) => j), find = j => up[j] === j ? j : (up[j] = find(up[j]));
        for (let a = 0; a < cardMarks.length; a++) for (let b = a + 1; b < cardMarks.length; b++) {
          const A = cardMarks[a].b, B = cardMarks[b].b;
          if (userCardOf.get(cardMarks[a].i) !== userCardOf.get(cardMarks[b].i)) continue;
          if (A[0] - 2 <= B[2] && B[0] - 2 <= A[2] && A[1] - 2 <= B[3] && B[1] - 2 <= A[3]) up[find(a)] = find(b);
        }
        const byRoot = {};
        cardMarks.forEach((c, j) => { const g = byRoot[find(j)] = byRoot[find(j)] || { marks: [], boxes: [] }; g.marks.push(c.i); g.boxes.push(c.b); });
        const cards = Object.values(byRoot).map(g => ({ box: unionBox(g.boxes), marks: g.marks, userCard: userCardOf.get(g.marks[0]) }));
        const area = b => (b[2] - b[0]) * (b[3] - b[1]), taken = new Set(cardMarks.map(c => c.i));
        for (const i of visible) {
          const m = mark(i);
          // a 3D figure rides only on a window (the card it stands on), as one: its parts and labels live in its stage
          if (taken.has(i) || (is3D(m) && m.do !== 'stage3d') || m.role === 'tie') continue;
          const carriedBy = userCardOf.has(i) ? cards.find(c => c.userCard === userCardOf.get(i)) : null;
          if (carriedBy) { carriedBy.marks.push(i); continue; }
          const b = box(i); if (!b) continue;
          const cx = (b[0] + b[2]) / 2, cy = (b[1] + b[3]) / 2;
          // ReferenceRenderer (2026-10-08): words or a sketch hanging over a card's edge (a long line, a caption under it) ride
          // with it when most of them is on it, not only when their middle is; what points at the screen keeps the
          // middle test, so a ring beside a card stays with the screen
          const mostlyOn = c => {
            if (pointsAtScreen(m)) return false;
            const ow = Math.min(b[2], c.box[2]) - Math.max(b[0], c.box[0]), oh = Math.min(b[3], c.box[3]) - Math.max(b[1], c.box[1]);
            return ow > 0 && oh > 0 && ow * oh >= 0.4 * Math.max(1, (b[2] - b[0]) * (b[3] - b[1]));
          };
          let on = cards.filter(c => c.userCard == null && ((cx >= c.box[0] - 12 && cx <= c.box[2] + 12 && cy >= c.box[1] - 12 && cy <= c.box[3] + 12) || mostlyOn(c)));
          if (m.do === 'stage3d') on = on.filter(c => c.marks.some(k => mark(k).do === 'window'));
          if (!on.length) continue;
          on.sort((p, q) => area(p.box) - area(q.box));
          on[0].marks.push(i);
        }
        // the card's window (paper, receipt, clipping): where its title bar and buttons are now, for the app's buttons
        const windowOf = c => {
          const ws = c.marks.filter(i => mark(i).do === 'window').map(i => ({ i, b: box(i) })).filter(w => w.b);
          if (!ws.length) return null;
          ws.sort((p, q) => area(q.b) - area(p.b));
          const m = mark(ws[0].i), k = (m.__xf || [1])[0] || 1;
          // has3D: a 3D figure stands on it (its window gets no full-screen button)
          return { mark: ws[0].i, box: ws[0].b, header: (+m.header || 0) * k, scale: k, zoomed: !!m.__xfBeforeZoom, title: m.title || '',
            has3D: c.marks.some(i => mark(i).do === 'stage3d') };
        };
        return cards.map(c => ({ box: c.box, marks: c.marks, nodes: c.marks.flatMap(i => (E.NODES[i] || []).filter(n => !n.__gone)), window: windowOf(c) }));
      },
      // ReferenceRenderer: the user dropped a card (cardsNow) somewhere else: its marks move by dx, dy on the card at once (the
      // app already showed them following the pointer). Later boxes, state() and keepNotesOnly see them where they are
      // now. Returns how many marks moved.
      moveMarks(ms, dx, dy) {
        dx = +dx || 0; dy = +dy || 0;
        if (!dx && !dy) return 0;
        const moved = [];
        for (const raw of ms || []) {
          const i = +raw, m = mark(i);
          if (!m || m.__erased || !drawn(i)) continue;
          const a = m.__xf || [1, 0, 0];
          m.__xf = [a[0], a[1] + dx, a[2] + dy];
          E.moveNodes(E.NODES[i], m.__xf, 0, 0.001);
          moved.push(i);
        }
        if (moved.length) userCards.push(new Set(moved));
        return moved.length;
      },
      // ReferenceRenderer: the user closed a card (its window's red button): its marks go, the pen running back over them.
      // Returns how many marks went.
      dropMarks(ms) {
        const gone = (ms || []).map(Number).filter(i => { const m = mark(i); return m && !m.__erased; });
        // a 3D figure goes with everything built into it
        const stages = new Set(gone.map(i => mark(i)).filter(m => m.do === 'stage3d').map(m => m.id));
        if (stages.size) for (const i of visibleMarkIndexes()) { const m = mark(i); if (m && stages.has(m.stage) && !gone.includes(i)) gone.push(i); }
        if (gone.length) this.dropNow(gone);
        return gone.length;
      },
      // ReferenceRenderer: the user made a card full screen (its window's green button): its marks glide by `to` ([scale, dx,
      // dy], applied on top of where they are). zoomMarks(ms, null) glides them back. Returns how many marks moved.
      zoomMarks(ms, to) {
        const moved = [];
        for (const raw of ms || []) {
          const i = +raw, m = mark(i);
          if (!m || m.__erased || !drawn(i)) continue;
          if (to) {
            if (!m.__xfBeforeZoom) m.__xfBeforeZoom = (m.__xf || [1, 0, 0]).slice();
            const a = m.__xfBeforeZoom, k = +to[0] || 1;
            m.__xf = [a[0] * k, k * a[1] + (+to[1] || 0), k * a[2] + (+to[2] || 0)];
          } else {
            if (!m.__xfBeforeZoom) continue;
            const a = m.__xfBeforeZoom;
            delete m.__xfBeforeZoom;
            if (a[0] === 1 && !a[1] && !a[2]) delete m.__xf; else m.__xf = a;
          }
          E.moveNodes(E.NODES[i], m.__xf || [1, 0, 0], 0, GLIDE_DUR * 0.8);
          moved.push(i);
        }
        // grown over the cards around it, it stays its own card (cardsNow would join cards that touch)
        if (to && moved.length) userCards.push(new Set(moved));
        return moved.length;
      },
      // which part is at card point (x, y): the part that drew the tapped node when the host passes it, else the smallest box
      async hit(x, y, el) {
        const P = (await parts()).parts.filter(p => p.vis.length && p.box);
        for (let n = el; n && n.tagName !== 'svg'; n = n.parentNode) for (const k in E.NODES) if (E.NODES[k].includes(n)) { const p = P.find(q => q.vis.includes(+k)); if (p) return p.id; }
        const inside = P.filter(p => x >= p.box[0] - 6 && x <= p.box[2] + 6 && y >= p.box[1] - 6 && y <= p.box[3] + 6);
        inside.sort((a, b) => (a.box[2] - a.box[0]) * (a.box[3] - a.box[1]) - (b.box[2] - b.box[0]) * (b.box[3] - b.box[1]));
        return inside[0] ? inside[0].id : null;
      },
      log, get last() { return last; }, get busy() { return E.busy; }
    };
  }

  // run a program exactly the way live() does, statement by statement, so a rendered card is what the product draws
  function runLive(code, W, H) {
    const S = RUNNER.Session(W, H), marks = [], says = [], warnings = []; let error = null;
    const take = r => { marks.push(...r.marks); says.push(...r.says); warnings.push(...r.warnings); if (r.error) error = r.error; };
    for (const e of statementEnds(code)) take(S.update(code.slice(0, e), false));
    take(S.update(code, true));
    marks.error = error; marks.says = says; marks.warnings = warnings;
    return marks;
  }

  // ReferenceRenderer: a program drawn whole keeps what its live drawing did at each __turn(n, keep): an earlier turn's marks from
  // `keep` on were never drawn (the user interrupted that turn), so they are not drawn here either
  const isTurn = m => !!m && m.do === 'edit' && !!m.op && m.op.op === 'turn';
  function dropUndrawn(marks) {
    marks.forEach((m, i) => {
      if (!isTurn(m) || m.op.keep == null) return;
      for (let k = Math.max(0, m.op.keep); k < i; k++) { const x = marks[k]; if (x && !isTurn(x)) x.__skip = x.__erased = x.__dropped = true; }
    });
  }
  // spec.schedule (optional): [[startSeconds, pace], ...] per mark, e.g. from a paced replay, to render or freeze frames exactly
  // opts.handle (ReferenceRenderer, optional): filled with {state(o), parts(o), visibleCount()} for the card this draws
  function render(spec, host, opts = {}) {
    const W = spec.w || 400, H = spec.h || 300;
    const marks = spec.code ? (opts.whole ? runCode(spec.code, W, H) : runLive(spec.code, W, H)) : (spec.marks || []);
    dropUndrawn(marks);
    const s = surfaceFor(spec, host, opts);
    // a program's edits (erase, recolor, move, ... startOver) run through an editor on this card, each at its point of the drawing
    const st = { marks, code: spec.code || '', log: { lines: (marks.says || []).map((x, k) => Object.assign({ k }, x)) }, finished: true, done: true, paused: false };
    const ed = Editor(s, st, spec, opts);
    s.hooks.edit = (m, i, at, pace) => ed.runMark(m, i, at, pace);
    const lay = spec.layout === false || opts.layout === false ? null : layoutMarks(marks, W, H, (m, i) => ed.planMark(m, i));
    if (marks.error) s.report.errors.push(marks.error);
    for (const w of marks.warnings || []) s.report.warnings.push(w);
    if (lay) { for (const w of lay.warnings) s.report.warnings.push(w); s.report.shapeOverlaps = lay.overlaps; s.report.nudged = lay.moved; s.report.covered = lay.covered; }
    if (Array.isArray(spec.schedule)) marks.forEach((m, i) => { const sc = spec.schedule[i]; if (sc) { m._t = sc[0]; m._pace = sc[1]; } });
    if (opts.handle) Object.assign(opts.handle, { state: o => ed.stateNow(o), parts: o => ed.partsNow(o), visibleCount: () => ed.visibleCount(), keepNotesOnly: () => ed.keepNotesOnly(), dropPointing: () => ed.dropPointing() });
    s.draw(marks);
    return s.finish();
  }
  // ReferenceRenderer: the longest run of complete statements of `code` that runs without an error, and how many marks it makes
  function runnablePrefix(code, W, H) {
    const whole = runCode(code, W, H);
    if (!whole.error) return { code, marks: whole.length };
    const ends = statementEnds(code + '\n;').filter(e => e <= code.length);
    let lo = 0, hi = ends.length - 1, best = { code: '', marks: 0 };
    while (lo <= hi) {
      const mid = (lo + hi) >> 1, c = code.slice(0, ends[mid]), r = runCode(c, W, H);
      if (!r.error) { best = { code: c, marks: r.length }; lo = mid + 1; } else hi = mid - 1;
    }
    return best;
  }

  // ---------------------------------------------------------------- live: draw each statement the moment it has fully arrived
  // opts (all optional, 1.4 behaviour without them):
  //   sandbox: 'worker'   run the program in a Web Worker (no DOM, no network, opts.timeLimit ms per chunk, default 1500);
  //                       update() then returns [] and new say() lines arrive through opts.onSay(lines)
  //   pace: 'speech'      release each say() line's strokes while it is spoken, spread across the line
  //   speech: 'estimate' (default: lines back to back at opts.wps words/s, opts.gap s apart) | 'external' (the host calls lineStart/lineEnd or spoken)
  //   continuous: true    phrases form one utterance (gap 0)
  //   onSay(lines), onDone(report)
  //   codeStart (ReferenceRenderer): the program's own code starts at this offset (Mate's pieces come first); state() leaves out
  //                       the helpers defined before it
  function live(spec, host, opts = {}) {
    const s = surfaceFor(spec, host, opts);
    let ed = null;
    const st = Stream(spec, Object.assign({}, opts, {
      onDraw: (ms, d) => { s.draw(ms, true, d || {}); if (opts.onDraw) opts.onDraw(ms, d || {}); },
      onDone: (rep, log) => {
        for (const e of rep.errors) s.report.errors.push(e);
        for (const w of rep.warnings) s.report.warnings.push(w);
        ['shapeOverlaps', 'nudged', 'covered'].forEach(k => { if (rep[k] != null) s.report[k] = rep[k]; });
        s.report.sandboxed = st.sandboxed; s.report.mode = log.mode;
        s.finish(); if (opts.onDone) opts.onDone(s.report, log);
      },
      planEdit: (m, i) => ed ? ed.planMark(m, i) : null
    }));
    ed = Editor(s, st, spec, opts);
    s.hooks.edit = (m, i, at, pace) => ed.runMark(m, i, at, pace);
    // ReferenceRenderer: the drawing stays on the card and a new turn starts on it. Marks still waiting for their line are dropped
    // for good; the program is cut back to what ran (complete statements; before a statement that failed) and reopened.
    // The host then appends `__turn(turn, keep);` and the new turn's code to `kept` (a whole-program replay of that combined
    // program drops the same marks). Returns {kept, keep, turn, firstLine (says so far), visible (marks on the card), start
    // (index of the next mark)}.
    function continueTurn() {
      let keep = st.dropPending(), kept = st.ran, count = st.count;
      if (st.runMode === 'full' && !st.sandboxed) {           // the old program stopped with an error: keep the part that runs
        const good = runnablePrefix(kept, spec.w || 400, spec.h || 300);
        if (good.code.length < kept.length || good.marks < count) {
          const gone = []; for (let i = good.marks; i < count; i++) if (st.marks[i] && !isTurn(st.marks[i])) gone.push(i);
          ed.dropNow(gone); st.rebase(good.code, good.marks);
          kept = good.code; count = good.marks; keep = Math.min(keep, count);
        }
      }
      st.reopen(kept);
      const turn = st.marks.reduce((t, m) => Math.max(t, (m && m.turn) || 1), 1) + 1;
      return { kept, keep: Math.min(keep, count), turn, firstLine: st.lines.length, visible: ed.visibleCount(), start: count };
    }
    return {
      update: (code, done = false) => st.update(code, done),
      lineStart: (k, t) => st.lineStart(k, t), lineEnd: (k, t) => st.lineEnd(k, t), spoken: (n, t) => st.spoken(n, t),
      stop: () => st.stop(), now: () => st.now(), finishNow: () => st.finishNow(), get rushed() { return st.rushed; },
      live3d: () => st.live3d,
      report: s.report, get timeline() { return st.log; }, get lines() { return st.lines; }, get sandboxed() { return st.sandboxed; }, get placed() { return s.placed; }, startsIn: i => s.startsIn(i),
      // 1.6, all additive: pause the pen at the current stroke and carry on later; edit what is on the card
      pause: () => st.pause(), resume: () => st.resume(), get paused() { return st.paused; }, get finished() { return st.finished; },
      edit: op => ed.edit(op), undo: () => ed.edit({ op: 'undo' }), settle: () => ed.settle(),
      state: o => ed.state(o), parts: () => ed.parts(), hit: (x, y, el) => ed.hit(x, y, el), get edits() { return ed.log; }, get lastEdit() { return ed.last; }, get code() { return st.code; },
      // ReferenceRenderer: the card right now (synchronous), and a new turn on the same card
      stateNow: o => ed.stateNow(o), partsNow: o => ed.partsNow(o), visibleCount: () => ed.visibleCount(), inkCount: () => ed.inkCount(), continueTurn,
      keepNotesOnly: () => ed.keepNotesOnly(), dropPointing: () => ed.dropPointing(),
      cardsNow: () => ed.cardsNow(), moveMarks: (ms, dx, dy) => ed.moveMarks(ms, dx, dy),
      dropMarks: ms => ed.dropMarks(ms), zoomMarks: (ms, to) => ed.zoomMarks(ms, to),
      // ReferenceRenderer: where a drawn mark really is now ([x0, y0, x1, y1]), or null
      drawnBox: i => (s.edit && s.edit.domBox ? s.edit.domBox(i) : null)
    };
  }
  global.MateDraw = { workerSource, version: VERSION, render, live, TONES, runCode, statementEnds, statementScanner: RUNNER.statementScanner, Stream, Pacer, Layout, layoutMarks, natural, setPen, Session: RUNNER.Session,
    attribute: RUNNER.attribute, exec: RUNNER.exec, describe, stateText, markBox, recolorMark, restyleMark, EDIT_BASE,
    pointsAtScreen, isCardMark, onCardTest };
})(typeof window !== 'undefined' ? window : globalThis);
