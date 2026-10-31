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
  // Colour names a program uses besides the tone list ('green', 'gold', 'teal'). Passed into the runner so the
  // worker sandbox resolves them the same way; it has no closure over this file.
  const COLOR_WORDS = { yellow: 'sun', gold: 'sun', golden: 'sun', purple: 'violet', lavender: 'lilac', green: 'leaf', lightgreen: 'mint', darkgreen: 'leaf', lightblue: 'sky', darkblue: 'blue', navy: 'blue',
    black: 'ink', gray: 'grey', lightgrey: 'grey', lightgray: 'grey', beige: 'cream', rose: 'pink', magenta: 'pink', salmon: 'peach', skyblue: 'sky', lime: 'mint', teal: '#2A9D8F', turquoise: '#2EC4B6' };
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
  // A string hash seeds a 32-bit linear congruential generator; each call gives the next number in [0, 1).
  function rng(seed) {
    let state = 0;
    for (const ch of String(seed)) state = (Math.imul(state, 31) + ch.charCodeAt(0)) >>> 0;
    return () => (state = (Math.imul(state, 1664525) + 1013904223) >>> 0) / 4294967296;
  }
  const dist = (a, b) => Math.hypot(b[0] - a[0], b[1] - a[1]);
  const lerp = (a, b, t) => [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t];
  // one decimal, and never "-0.0"
  const num1 = v => { const s = v.toFixed(1); return s === '-0.0' ? '0.0' : s; };
  const joined = pts => pts.map(p => num1(p[0]) + ' ' + num1(p[1])).join(' L');
  // the same points without repeats (a repeated point has no direction, and would pinch a stroke or stall a curve)
  function distinct(pts) {
    const out = [];
    for (const p of pts) if (!out.length || dist(out[out.length - 1], p) > 1e-6) out.push(p);
    return out;
  }

  // ---------------------------------------------------------------- geometry
  // A smooth curve through the points: centripetal Catmull-Rom, so unevenly spaced points never loop or overshoot
  // (the plain, uniform kind kinks wherever a short span sits next to a long one). Each span gets one sample every 4
  // units, at least 2 and at most 3 * seg.
  function catmull(pts, closed, seg = 10) {
    pts = distinct(pts);
    if (closed && pts.length > 2 && dist(pts[0], pts[pts.length - 1]) < 1e-6) pts.pop();
    if (pts.length < 2) return pts.slice();
    if (pts.length === 2 && !closed) return densify(pts, 12);
    const n = pts.length, at = i => pts[(i + n) % n];
    // an open curve's ends continue straight on, mirrored from their neighbours
    const before = closed ? at(-1) : lerp(pts[1], pts[0], 2), after = closed ? at(n) : lerp(pts[n - 2], pts[n - 1], 2);
    const P = closed ? [before, ...pts, pts[0], at(1)] : [before, ...pts, after];
    const out = [];
    for (let i = 1; i < P.length - 2; i++) {
      const [p0, p1, p2, p3] = [P[i - 1], P[i], P[i + 1], P[i + 2]];
      const knot = (a, b) => Math.max(Math.sqrt(dist(a, b)), 1e-4);
      const t1 = knot(p0, p1), t2 = t1 + knot(p1, p2), t3 = t2 + knot(p2, p3);
      const steps = Math.max(2, Math.min(seg * 3, Math.ceil(dist(p1, p2) / 4)));
      for (let s = 0; s < steps; s++) {
        // Barry and Goldman's pyramid: three linear blends, then two, then one
        const t = t1 + (t2 - t1) * s / steps;
        const a1 = lerp(p0, p1, t / t1), a2 = lerp(p1, p2, (t - t1) / (t2 - t1)), a3 = lerp(p2, p3, (t - t2) / (t3 - t2));
        const b1 = lerp(a1, a2, t / t2), b2 = lerp(a2, a3, (t - t1) / (t3 - t1));
        out.push(lerp(b1, b2, (t - t1) / (t2 - t1)));
      }
    }
    out.push(closed ? pts[0] : pts[n - 1]);
    return out;
  }
  // the polyline with extra points so no span is longer than `step`
  function densify(pts, step = 6) {
    const out = [pts[0]];
    for (let i = 1; i < pts.length; i++) {
      const pieces = Math.max(1, Math.ceil(dist(pts[i - 1], pts[i]) / step));
      for (let s = 1; s <= pieces; s++) out.push(lerp(pts[i - 1], pts[i], s / pieces));
    }
    return out;
  }
  // a centreline cut into dashes `on` long with `off` between them, cut exactly where the lengths run out
  function dashes(pts, on, off) {
    const line = densify(pts, 2), out = [];
    if (!(on > 0) || !(off >= 0) || line.length < 2) return line.length > 1 ? [line] : [];
    let inked = true, left = on, cur = [line[0]];
    for (let i = 1; i < line.length; i++) {
      let a = line[i - 1];
      const b = line[i];
      let span = dist(a, b);
      while (span >= left) {
        const cut = lerp(a, b, left / span);
        if (inked) { cur.push(cut); out.push(cur); } else cur = [cut];
        span -= left; a = cut; inked = !inked; left = inked ? on : off;
      }
      left -= span;
      if (inked) cur.push(b);
    }
    if (inked && cur.length > 1 && plen(cur) > 0.5) out.push(cur);
    return out;
  }
  // A straight run drawn by hand bows a little. bow 'pen' bends each edge once, clearly, to one side: 3% of its length
  // in points, between 2 and 7 (a short edge barely), and `jitter` moves its corners up to that many points. Any other
  // bow is a small random bend. Points are canvas units; __canvasUnitPoints says how many points one unit is.
  function handSegments(pts, closed, r, amt = 1, bowStyle, jitter = 0) {
    const unit = +global.__canvasUnitPoints > 0 ? +global.__canvasUnitPoints : 1;
    if (jitter) pts = pts.map(p => [p[0] + (r() * 2 - 1) * jitter / unit, p[1] + (r() * 2 - 1) * jitter / unit]);
    const corners = closed ? [...pts, pts[0]] : pts, out = [corners[0]];
    for (let i = 1; i < corners.length; i++) {
      const a = corners[i - 1], b = corners[i], len = dist(a, b) || 1, inPoints = len * unit;
      let bend;
      if (bowStyle === 'pen') {
        const side = r() < 0.5 ? -1 : 1, size = inPoints < 24 ? inPoints * 0.03 : Math.min(Math.max(inPoints * 0.03, 2), 7);
        bend = side * size * (0.6 + 0.4 * r()) / unit * amt;
      } else bend = (r() - 0.5) * Math.min(3.2, len * 0.03) * amt * HAND;
      const nx = -(b[1] - a[1]) / len, ny = (b[0] - a[0]) / len, pieces = Math.max(2, Math.ceil(len / 5));
      for (let s = 1; s <= pieces; s++) {
        const t = s / pieces, k = Math.sin(Math.PI * t) * bend, p = lerp(a, b, t);
        out.push([p[0] + nx * k, p[1] + ny * k]);
      }
    }
    return out;
  }
  // An ellipse drawn by hand: its radius breathes with two slow waves, and the pen runs 6% past the start and drifts
  // out by 2% as it closes (overshoot), the way a quick circle round something is drawn.
  function ellipsePts(cx, cy, rx, ry, rot, r, wobble = 1, overshoot = true) {
    const count = Math.max(28, Math.round((rx + ry) / 2.2)), from = r() * Math.PI * 2, sweep = Math.PI * 2 * (overshoot ? 1.06 : 1);
    const phase2 = r() * 6, phase3 = r() * 6, cos = Math.cos(rot), sin = Math.sin(rot), out = [];
    for (let i = 0; i <= count; i++) {
      const a = from + sweep * i / count;
      const k = 1 + wobble * HAND * (0.018 * Math.sin(a * 2 + phase2) + 0.012 * Math.sin(a * 3 + phase3)) + (overshoot ? 0.02 * wobble * i / count : 0);
      const x = Math.cos(a) * rx * k, y = Math.sin(a) * ry * k;
      out.push([cx + x * cos - y * sin, cy + x * sin + y * cos]);
    }
    return out;
  }
  // The two edges of a stroke of half-width width(i) along a centreline. A corner is joined properly: the outer edge is
  // mitred out so the stroke keeps its width round the bend, and a bend over 100 degrees gets a rounded outer edge,
  // the way a round pen nib leaves it. Without it a box's corners thinned to 70% of the line and a tick's point to a hair.
  function strokeEdges(pts, width) {
    const n = pts.length, left = [], right = [];
    const dir = (a, b) => { const d = dist(a, b) || 1; return [(b[0] - a[0]) / d, (b[1] - a[1]) / d]; };
    for (let i = 0; i < n; i++) {
      const p = pts[i], w = width(i);
      const din = dir(pts[Math.max(0, i - 1)], pts[i === 0 ? 1 : i]), dout = dir(pts[i === n - 1 ? n - 2 : i], pts[Math.min(n - 1, i + 1)]);
      const nin = [-din[1], din[0]], nout = [-dout[1], dout[0]];
      let mx = nin[0] + nout[0], my = nin[1] + nout[1];
      const ml = Math.hypot(mx, my);
      if (ml < 1e-6) { mx = nin[0]; my = nin[1]; } else { mx /= ml; my /= ml; }
      const cosHalf = Math.max(1e-6, mx * nin[0] + my * nin[1]);
      const at = (nx, ny, k) => [p[0] + nx * k, p[1] + ny * k];
      if (cosHalf >= 0.643) {                               // up to a 100 degree bend: one mitred point a side
        const k = w / cosHalf;
        left.push(at(mx, my, k)); right.push(at(mx, my, -k));
        continue;
      }
      // sharper: the inner edge meets at the centreline's half-width, the outer edge goes round the corner
      const turnsLeft = din[0] * dout[1] - din[1] * dout[0] > 0, outer = turnsLeft ? -1 : 1;
      const arc = [], a0 = Math.atan2(outer * nin[1], outer * nin[0]);
      let sweep = Math.atan2(outer * nout[1], outer * nout[0]) - a0;
      while (sweep > Math.PI) sweep -= 2 * Math.PI;
      while (sweep < -Math.PI) sweep += 2 * Math.PI;
      const steps = Math.max(2, Math.ceil(Math.abs(sweep) / 0.35));
      for (let s = 0; s <= steps; s++) { const a = a0 + sweep * s / steps; arc.push([p[0] + Math.cos(a) * w, p[1] + Math.sin(a) * w]); }
      const inner = at(mx, my, -outer * w);
      if (outer > 0) { left.push(...arc); right.push(inner); } else { right.push(...arc); left.push(inner); }
    }
    let widest = 0;
    for (let i = 0; i < n; i++) widest = Math.max(widest, width(i));
    return [untangle(left, widest * 6), untangle(right, widest * 6)];
  }
  // An edge without the small loops it ties where the centreline bends tighter than the pen is wide (the inside of a
  // hairpin, a box's inner corner): each loop is cut at its crossing. Left in, a loop shows as a spike or a notch.
  // Only loops shorter than `reach` go, so a curve that really crosses itself (a circle's overshoot) keeps its shape.
  function untangle(edge, reach) {
    const out = [], along = [];
    const cross = (a, b, c, d) => {
      const rx = b[0] - a[0], ry = b[1] - a[1], sx = d[0] - c[0], sy = d[1] - c[1], den = rx * sy - ry * sx;
      if (Math.abs(den) < 1e-9) return null;
      const t = ((c[0] - a[0]) * sy - (c[1] - a[1]) * sx) / den, u = ((c[0] - a[0]) * ry - (c[1] - a[1]) * rx) / den;
      return t > 0 && t < 1 && u > 0 && u < 1 ? [a[0] + rx * t, a[1] + ry * t] : null;
    };
    for (const p of edge) {
      // the run to p may cross an earlier segment; once that loop is cut, what is left of the run may cross another
      for (let cut = true; cut && out.length >= 3;) {
        cut = false;
        const k = out.length, a = out[k - 1];
        for (let j = k - 3; j >= 0 && along[k - 1] - along[j + 1] <= reach; j--) {
          const hit = cross(out[j], out[j + 1], a, p);
          if (!hit) continue;
          out.length = along.length = j + 1;
          out.push(hit); along.push(along[j] + dist(out[j], hit));
          cut = true;
          break;
        }
      }
      along.push(out.length ? along[out.length - 1] + dist(out[out.length - 1], p) : 0);
      out.push(p);
    }
    return out;
  }
  // A stroke's filled outline around its centreline, like a felt pen: it tapers in and out of each end (over 30% of
  // the stroke, at most five widths) and swells a little along the way. taper 0 is the screen pen instead: one even
  // width with round ends, which reads surer next to the marks it sits on.
  function outline(pts, size, taper = 1) {
    pts = distinct(pts);
    if (pts.length < 2) return null;
    if (taper === 0) return evenOutline(pts, size / 2);
    const along = [0];
    for (let i = 1; i < pts.length; i++) along.push(along[i - 1] + dist(pts[i - 1], pts[i]));
    const total = along[along.length - 1] || 1, ramp = Math.min(total * 0.3, size * 5) * taper || 1e-6;
    const [left, right] = strokeEdges(pts, i => {
      const u = along[i], press = Math.min(1, 0.35 + 0.65 * Math.min(u, total - u) / ramp);
      return size / 2 * press * (0.94 + 0.06 * Math.sin(u / 7));
    });
    return 'M' + joined(left) + ' L' + joined(right.reverse()) + ' Z';
  }
  // an even-width outline (half-width w) with a round cap at each end
  function evenOutline(pts, w) {
    pts = distinct(pts);
    if (pts.length < 2) return null;
    const [left, right] = strokeEdges(pts, () => w), n = pts.length;
    // half a circle round an end, from one edge to the other through the outside of the end
    const cap = (p, from, to) => {
      const out = [], a0 = Math.atan2(from[1] - p[1], from[0] - p[0]);
      let sweep = Math.atan2(to[1] - p[1], to[0] - p[0]) - a0;
      if (sweep > 0) sweep -= 2 * Math.PI;                   // always the clockwise way round, through the outside
      for (let k = 1; k < 8; k++) { const a = a0 + sweep * k / 8; out.push([p[0] + Math.cos(a) * w, p[1] + Math.sin(a) * w]); }
      return out;
    };
    const endCap = cap(pts[n - 1], left[left.length - 1], right[right.length - 1]), startCap = cap(pts[0], right[0], left[0]);
    return 'M' + joined([...left, ...endCap, ...right.reverse(), ...startCap]) + ' Z';
  }
  const poly = pts => 'M' + joined(pts);
  const plen = pts => { let total = 0; for (let i = 1; i < pts.length; i++) total += dist(pts[i - 1], pts[i]); return total; };

  // n + 1 evenly spaced points along an SVG path, measured by the browser
  function samplePath(d, n = 120) {
    const probe = document.createElementNS('http://www.w3.org/2000/svg', 'path');
    probe.setAttribute('d', d);
    document.getElementById('__probe').appendChild(probe);
    const length = probe.getTotalLength(), out = [];
    for (let i = 0; i <= n; i++) { const p = probe.getPointAtLength(length * i / n); out.push([p.x, p.y]); }
    probe.remove();
    return out;
  }

  // ================================================================ the program runner
  // Everything in makeRunner is self-contained (no outer variables), so the same source also runs inside a Web Worker.
  function makeRunner(TONE_NAMES, MATE_HEX, REAL_HEX, COLOR_ALIASES) {
    // Everything here is self-contained (no outer names): workerSource() posts this function's own text to a Worker.
    // The colour tables are arguments so a sandboxed drawing can name 'red' or 'green'; the worker has no closure.
    const LIMIT = 2000;                                  // marks one program may make
    // The app runs drawings inside a canvas global it passes in. This function's worker copy has no closure, so a
    // missing `global` must not throw (that used to stop every 3D figure in the sandbox before it drew anything).
    const hostGlobal = () => (typeof global !== 'undefined' && global) || globalThis;
    const hostCall = name => { const g = hostGlobal(), fn = g && g[name]; return typeof fn === 'function' ? fn : null; };
    const colorName = c => { const k = String(c).toLowerCase().replace(/[\s_-]+/g, ''); return k in MATE_HEX ? k : (COLOR_ALIASES && COLOR_ALIASES[k]) || String(c).trim(); };
    const paintOf = (table, c) => { if (typeof c !== 'string') return c; const name = colorName(c); return table[name] || name || table.ink; };
    const mateColor = c => paintOf(MATE_HEX, c), realColor = c => paintOf(REAL_HEX, c);

    // ---------------------------------------------------------------- where statements end
    // A program arrives a few characters at a time, and each complete statement is run the moment it is whole. A
    // statement ends at a ';', a line break or a closing '}' outside any brackets, unless the code plainly goes on: the
    // statement so far ends in an operator or an opening bracket, the next line starts with one (.map, + 1, ? a : b),
    // or a '}' is followed by else, catch or finally. Strings, template literals (with ${} inside them, nested to any
    // depth), regular expressions and comments are skipped whole; one left open stops the scan, since what follows
    // is still inside it. Returns the offset just after each end, from `start` on.
    const ENDS_STATEMENT = ';\n}';
    const GOES_ON_AFTER = '=+-*/%&|^~!<>,([{:?';         // a statement ending in one of these is not done
    const GOES_ON_BEFORE = '.?:+-*/%&|^=<>,)]';           // nor is one whose next line starts with one of these
    const JOINED_AFTER_BRACE = /^(?:else|catch|finally)\b/;
    // after these a '/' starts a regular expression; after anything else it divides
    const REGEX_AFTER = '(,=:[!&|?{};+-*%<>~^';
    const REGEX_WORDS = /(?:^|[^\w$])(?:return|typeof|instanceof|in|of|new|delete|void|throw|case|do|else|yield|await)$/;
    const isSpace = ch => ch === ' ' || ch === '\t' || ch === '\n' || ch === '\r' || /\s/.test(ch);

    function statementEnds(code, start = 0) {
      const n = code.length, out = [], open = [];         // open: the brackets we are inside; '$' is a template's ${
      let i = start, lastSignificant = start;            // lastSignificant: just after the last code that is not blank or a comment
      // skip a quoted string, a template literal's text, or a regular expression; false when it never closes
      const skipQuoted = q => { for (let j = i + 1; j < n; j++) { if (code[j] === '\\') j++; else if (code[j] === q) { i = j + 1; return true; } } return false; };
      const skipTemplate = () => {                        // from just after ` or }: to the closing ` (true) or a ${ (pushes '$')
        for (let j = i; j < n; j++) {
          if (code[j] === '\\') j++;
          else if (code[j] === '`') { i = j + 1; return true; }
          else if (code[j] === '$' && code[j + 1] === '{') { open.push('$'); i = j + 2; return true; }
        }
        return false;
      };
      const skipRegex = () => {
        let inClass = false;
        for (let j = i + 1; j < n && code[j] !== '\n'; j++) {
          if (code[j] === '\\') j++;
          else if (code[j] === '[') inClass = true;
          else if (code[j] === ']') inClass = false;
          else if (code[j] === '/' && !inClass) { j++; while (j < n && /[a-z]/i.test(code[j])) j++; i = j; return true; }
        }
        return false;
      };
      const regexHere = () => {
        let k = lastSignificant - 1;
        if (k < start) return true;
        const before = code[k];
        if (REGEX_AFTER.includes(before)) return true;
        return /[\w$]/.test(before) && REGEX_WORDS.test(code.slice(Math.max(0, k - 11), k + 1));
      };
      while (i < n) {
        const c = code[i];
        if (c === '/' && code[i + 1] === '/') { const j = code.indexOf('\n', i); i = j < 0 ? n : j; continue; }
        if (c === '/' && code[i + 1] === '*') { const j = code.indexOf('*/', i + 2); if (j < 0) break; i = j + 2; continue; }
        if (c === '"' || c === "'") { if (!skipQuoted(c)) break; lastSignificant = i; continue; }
        if (c === '`') { i++; if (!skipTemplate()) break; lastSignificant = i; continue; }
        if (c === '/' && regexHere()) { if (!skipRegex()) break; lastSignificant = i; continue; }
        if (c === '(' || c === '[' || c === '{') open.push(c);
        else if (c === ')' || c === ']' || c === '}') {
          // a '}' that closes a template's ${ goes back into the template's text
          if (c === '}' && open[open.length - 1] === '$') { open.pop(); i++; if (!skipTemplate()) break; lastSignificant = i; continue; }
          open.pop();                                      // (a stray closer is a syntax error the run reports; scanning goes on)
        }
        if (!open.length && ENDS_STATEMENT.includes(c) && endsHere(code, start, i, c === '}' ? i + 1 : lastSignificant)) { out.push(i + 1); start = i + 1; lastSignificant = start; }
        else if (!isSpace(c)) lastSignificant = i + 1;
        i++;
      }
      return out;
    }
    // Whether the statement from `start` ends at the ';', line break or '}' at i (`last`: just after its last real code).
    function endsHere(code, start, i, last) {
      const n = code.length;
      let next = i + 1;
      while (next < n && (code[next] === ' ' || code[next] === '\t')) next++;
      if (next >= n) return false;                        // nothing after it yet: the statement may still go on
      let first = start;
      while (first < i + 1 && isSpace(code[first])) first++;
      if (first >= i + 1) return false;                   // nothing but blanks
      let end = last;
      while (end > first && isSpace(code[end - 1])) end--;
      if (code[i] === ';' && end === i + 1) { end--; while (end > first && isSpace(code[end - 1])) end--; }
      const lastChar = end > first ? code[end - 1] : '';
      if (GOES_ON_BEFORE.includes(code[next])) return false;
      if (lastChar && GOES_ON_AFTER.includes(lastChar)) return false;
      return !(code[i] === '}' && JOINED_AFTER_BRACE.test(code.slice(next, next + 8)));
    }
    // A stream sends its whole prefix every time. The ends already found stay, except the last one: a trailing
    // "} e" may still become "} else". Ends before it cannot change when more code is appended.
    function statementScanner() {
      let seen = '', ends = [];
      return code => {
        if (code === seen) return ends;
        const keep = code.startsWith(seen) ? Math.max(0, ends.length - 1) : 0;
        ends = ends.slice(0, keep).concat(statementEnds(code, keep ? ends[keep - 1] : 0));
        seen = code;
        return ends;
      };
    }

    // ---------------------------------------------------------------- small helpers for the drawing calls
    // A rough width before the page measures the real glyphs. Latin letters stay at the font's average; East Asian
    // characters and emoji are about an em wide (they used to be counted as one Latin letter and ran out of their box).
    const WIDE_GLYPH = /[ᄀ-ᅟ⺀-꓏가-힣豈-﫿︰-﹏＀-｠￠-￦]|[\u{1F300}-\u{1FAFF}\u{20000}-\u{3FFFD}]/u;
    const glyphs = (s, px, average) => { let narrow = 0, wide = 0; for (const ch of String(s)) WIDE_GLYPH.test(ch) ? wide++ : narrow++; return narrow * px * average + wide * px; };
    const textW = (s, size, style) => glyphs(s, size || 20, style === 'title' ? 0.56 : 0.47);
    // round tick values from a to b, about n of them: steps of 1, 2, 2.5 or 5 times a power of ten
    function niceTicks(a, b, n) {
      n = n || 5;
      const lo = Math.min(a, b), hi = Math.max(a, b), span = hi - lo || 1, unit = Math.pow(10, Math.floor(Math.log10(span / n)));
      let step = unit;
      for (const k of [1, 2, 2.5, 5, 10]) { step = k * unit; if (span / step <= n) break; }
      const out = [];
      // each tick from its own index, so a long axis does not gather rounding error tick by tick
      for (let k = Math.ceil(lo / step - 1e-9), last = Math.floor(hi / step + 1e-9); k <= last; k++) out.push(+(k * step).toFixed(10));
      return out;
    }
    // A tick value as an axis shows it. Big ones read short ("80k", "1.5M") so a $ axis stays on the card.
    const shortened = (v, unit, suffix) => String(+(v / unit).toFixed(Math.abs(v / unit) < 10 && v % unit ? 1 : 0)) + suffix;
    const fmt = v => Math.abs(v) >= 1e6 ? shortened(v, 1e6, 'M')
      : Math.abs(v) >= 10000 ? shortened(v, 1000, 'k')
      : Number.isInteger(v) || Math.abs(v) >= 100 ? String(Math.round(v)) : String(+v.toFixed(2));
    const finite = p => Array.isArray(p) && isFinite(p[0]) && isFinite(p[1]);

    // A web link in card text (a citation "([bestbuy.com](https://…))", a long bare URL) shows as a short name and the
    // text keeps the first link (m.link) for the app to make clickable; a product page's whole URL ran off the card.
    const SHORT_URL = 32;
    const siteOf = url => url.replace(/^https?:\/\//i, '').split(/[/?#]/)[0].replace(/^www\./i, '');
    // Sentence punctuation stuck to a URL is not part of the link. It stays in the words; the click target used to
    // include the period, so the page it opened was wrong.
    const peelTail = url => { const m = /^(.*?)([.,;:!?]+)$/.exec(url); return m && m[1].length > 10 ? [m[1], m[2]] : [url, '']; };
    function linkedText(value) {
      if (typeof value !== 'string' || !/https?:\/\//i.test(value)) return { text: value };
      let link = null;
      const shown = value
        .replace(/\[([^\]\n]{1,80})\]\((https?:\/\/[^\s)]+)\)/gi, (_, label, url) => { const [clean] = peelTail(url); link = link || clean; return label; })
        .replace(/https?:\/\/[^\s)\]]+/gi, url => {
          const [clean, tail] = peelTail(url);
          link = link || clean;
          if (clean.length <= SHORT_URL) return clean + tail;
          const rest = clean.replace(/^https?:\/\/[^/?#]+/i, '');
          return siteOf(clean) + (rest.length > 1 ? '/…' : '') + tail;
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
        marks.push(mk);
        return mk;
      };
      const api = {
        // Set by the pieces when the app draws windows: a 3D figure that would stand on paper stands in a window instead.
        __card3d: null,
        W: w, H: h, PI: Math.PI, sin: Math.sin, cos: Math.cos, abs: Math.abs, min: Math.min, max: Math.max, sqrt: Math.sqrt, round: Math.round,
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
        step: n => { curStep = n; },
        say: s => { const line = { text: String(s), at: marks.length, step: curStep }; if (curTurn) line.turn = curTurn; says.push(line); cue = s; },
        seen: () => {}, noted: () => {},
        line: (pts, o) => push({ do: 'line', pts }, o),
        curve: (pts, o) => push({ do: 'line', pts, smooth: true }, o),
        circle: (x, y, r, o) => push({ do: 'circle', at: [x, y], r }, o),
        ellipse: (x, y, rx, ry, o) => push({ do: 'ellipse', at: [x, y], rx, ry }, o),
        rect: (x, y, w_, h_, o) => push({ do: 'rect', at: [x, y], w: w_, h: h_ }, o),
        poly: (pts, o) => push({ do: 'poly', pts }, o),
        path: (d, o) => push({ do: 'path', d }, o),
        text: (x, y, text, o) => push(Object.assign({ do: 'text', at: [x, y] }, linkedText(text)), o),
        arrow: (pts, o) => push({ do: 'arrow', pts }, o),
        dot: (x, y, r, o) => push({ do: 'dot', at: [x, y], r }, o),
        image: (x, y, w_, h_, o) => push({ do: 'image', at: [x, y], w: w_, h: h_ }, o),
        // A little window (title bar, board). The pieces call it; a program is not taught to.
        __window: (x, y, w_, h_, o) => push({ do: 'window', at: [x, y], w: w_, h: h_ }, o),
        molecule: (smiles, x, y, w_, h_, o) => push({ do: 'molecule', smiles, at: [x, y], w: w_, h: h_ }, o),
      };

      // Rough boxes of the ink so far (not the cards it sits on), so a later piece can step off it.
      api.__inkBoxes = () => {
        const out = [];
        const boxOf = m => {
          if (!m || m.do === 'window' || m.do === 'edit' || (/3d$/.test(m.do || '') && m.do !== 'stage3d')) return null;
          if (m.role === 'paper' || m.role === 'button' || m.role === 'handoff' || m.role === 'open') return null;
          if (m.do === 'dot' && m.fillAlpha === 0 && (+m.r || 0) <= 0.5) return null;
          const pad = (+m.size || 3) / 2, at = Array.isArray(m.at) ? m.at : null;
          if (Array.isArray(m.pts) && m.pts.length) {
            let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity, n = 0;
            for (const q of m.pts) if (Array.isArray(q) && isFinite(q[0]) && isFinite(q[1])) { n++; x0 = Math.min(x0, q[0]); y0 = Math.min(y0, q[1]); x1 = Math.max(x1, q[0]); y1 = Math.max(y1, q[1]); }
            return n ? [x0 - pad, y0 - pad, x1 - x0 + 2 * pad, y1 - y0 + 2 * pad] : null;
          }
          if (!at) return null;
          if (m.do === 'circle' || m.do === 'dot') { const r = (+m.r || 3) + pad; return [at[0] - r, at[1] - r, 2 * r, 2 * r]; }
          if (m.do === 'ellipse') { const rx = (+m.rx || 0) + pad, ry = (+m.ry || 0) + pad; return [at[0] - rx, at[1] - ry, 2 * rx, 2 * ry]; }
          if (m.do === 'text') {
            const size = +m.size || 20, lines = String(m.text == null ? '' : m.text).split('\n');
            const tw = Math.max(...lines.map(t => glyphs(t, size, 0.5)));
            const ww = m.fit ? Math.min(+m.fit[0] || tw, tw) : tw;
            const x = at[0] - (m.anchor === 'middle' ? ww / 2 : m.anchor === 'end' ? ww : 0);
            // `top` still sits on the alphabetic line (that is how the renderer reads it), so the box starts where a normal line does.
            return [x, at[1] - size * 0.8, ww, size * 1.05 * lines.length];
          }
          if (isFinite(+m.w) && isFinite(+m.h)) return [Math.min(at[0], at[0] + +m.w), Math.min(at[1], at[1] + +m.h), Math.abs(+m.w), Math.abs(+m.h)];
          return null;
        };
        for (const m of marks) {
          const b = boxOf(m);
          if (b && b.every(v => isFinite(v)) && b[2] > 0 && b[3] > 0) out.push(b);
        }
        return out;
      };

      // ------------------------------------------------ a 3D figure's rectangle
      let stageCount = 0;
      const stageBoxes = [];
      const fin = v => typeof v === 'number' && isFinite(v);
      const r3 = v => Math.round(v * 1000) / 1000;
      const v3 = (v, fallback) => Array.isArray(v) && v.length >= 3 && fin(v[0]) && fin(v[1]) && fin(v[2]) ? [v[0], v[1], v[2]] : fallback;
      // An axis is 'x' or '-z' as often as [1, 0, 0]. A string the old reader dropped became "up", so a fan spun on the wrong axis.
      const axis3 = (v, fallback) => {
        if (typeof v === 'string') {
          const m = /^\s*([+-]?)\s*([xyz])\s*$/i.exec(v);
          if (m) { const a = [0, 0, 0]; a['xyz'.indexOf(m[2].toLowerCase())] = m[1] === '-' ? -1 : 1; return a; }
        }
        return v3(v, fallback);
      };
      const pickKeys = (object, keys) => {
        const out = {};
        if (object && typeof object === 'object') for (const k of keys) if (object[k] !== undefined) out[k] = object[k];
        return out;
      };
      const tintMaterial = (material, colorOf, glowOf) => {
        if (material.color != null) material.color = colorOf(material.color);
        if (material.emissive != null) material.emissive = (glowOf || colorOf)(material.emissive);
        for (const k of ['bands', 'colors']) if (Array.isArray(material[k])) material[k] = material[k].map(colorOf);
        return material;
      };
      // Paper steps off every figure. The nearest calm spot on the card wins; covering the figure is the last resort.
      api.clearOfFigures = (px, py, pw, ph) => {
        const gap = 10;
        const hits = (ax, ay) => stageBoxes.some(b => ax < b[0] + b[2] + gap && ax + pw + gap > b[0] && ay < b[1] + b[3] + gap && ay + ph + gap > b[1]);
        if (!hits(px, py)) return [px, py];
        const onCard = (ax, ay) => ax >= 4 && ay >= 4 && ax + pw <= w - 4 && ay + ph <= h - 4 && !hits(ax, ay);
        const spots = [];
        for (const b of stageBoxes) {
          const yClamp = Math.min(Math.max(4, py), h - ph - 4);
          spots.push([b[0] + b[2] + gap, py], [b[0] - pw - gap, py], [px, b[1] + b[3] + gap], [px, b[1] - ph - gap], [b[0] + b[2] + gap, yClamp], [b[0] - pw - gap, yClamp]);
        }
        const busy = hostCall('__busyFor');
        const score = (ax, ay) => busy ? busy(ax, ay, pw, ph) : 0;
        const limit = score(px, py) + 0.006;
        const free = spots.filter(([ax, ay]) => onCard(ax, ay) && score(ax, ay) <= limit)
          .sort((a, b) => Math.hypot(a[0] - px, a[1] - py) - Math.hypot(b[0] - px, b[1] - py));
        if (!free.length) { warn('a paper piece covers a 3D figure (no calm spot beside it)'); return [px, py]; }
        warn('moved a paper piece off a 3D figure');
        return free[0];
      };
      // The window a figure's rectangle is mostly inside, the smallest when cards overlap.
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
      // One placement for scene3d() and figure(): the stage mark, its card, and which ink the labels use.
      const standStage = (x, y, w_, h_, o, look) => {
        const sid = 'st' + (++stageCount);
        const pad = 10;
        const card = [Math.max(4, x - pad), Math.max(4, y - pad), 0, 0];
        card[2] = Math.min(w - 4, x + w_ + pad) - card[0];
        card[3] = Math.min(h - 4, y + h_ + pad) - card[1];
        const busyAt = hostCall('__busyFor');
        let tiles = 0, busyTiles = 0;
        for (let ty = y; ty < y + h_; ty += 64) for (let tx = x; tx < x + w_; tx += 64) {
          tiles++;
          if (busyAt && busyAt(tx, ty, Math.min(64, x + w_ - tx), Math.min(64, y + h_ - ty)) > 0.02) busyTiles++;
        }
        const floatNow = hostCall('__figuresFloat');
        const floats = floatNow ? floatNow() === true : false;
        const onCard = floats ? null : hostCardFor(x, y, w_, h_);
        if (onCard) onCard.board = 'plain';
        const busy = !floats && !onCard && (o.card === true || (o.card !== false && tiles > 0 && busyTiles / tiles >= 0.08));
        stageBoxes.push([x, y, w_, h_]);
        const windowed = busy && typeof api.__card3d === 'function';
        if (windowed) api.__card3d(x, y, w_, h_, o);
        const inkFor = hostCall('__inkFor');
        const ink = busy || onCard ? MATE_HEX.ink : inkFor ? inkFor(x, y, w_, h_) : '#FFFFFF';
        // A figure that was asked to sit still, or to crawl, still turns: a frozen model does not read as 3D.
        const stageMark = push({
          do: 'stage3d', id: sid, at: [x, y], w: w_, h: h_, ink, card: busy && !windowed ? card : null, cardWindow: onCard ? onCard.inner : undefined,
          camera: { tilt: fin(o.tilt) ? Math.max(-80, Math.min(80, o.tilt)) : 15, fov: fin(o.fov) ? o.fov : 35, spin: fin(o.spin) ? Math.min(2, Math.max(0.5, o.spin)) : 0.7 },
        });
        if (look) stageMark.look = look;
        return { sid, ink };
      };
      const MATERIAL_KEYS = ['color', 'roughness', 'metalness', 'emissive', 'emissiveIntensity', 'opacity', 'double', 'flat', 'bands', 'colors', 'glow'];
      const bindMotions = (handle, target, sid) => {
        const motion = (kind, fields) => push({ do: 'motion3d', stage: sid, op: Object.assign({ target: target.id, kind }, fields) });
        handle.spin = function (op) { op = op || {}; motion('spin', { axis: axis3(op.axis, [0, 1, 0]), period: fin(op.period) ? op.period : 6 }); return this; };
        handle.bob = function (op) { op = op || {}; motion('bob', { axis: axis3(op.axis, [0, 1, 0]), amount: fin(op.amount) ? op.amount : 0.1, period: fin(op.period) ? op.period : 3 }); return this; };
        handle.orbit = function (op) { op = op || {}; motion('orbit', { axis: axis3(op.axis, [0, 1, 0]), center: v3(op.center, [0, 0, 0]), period: fin(op.period) ? op.period : 8 }); return this; };
        handle.path = function (points, op) {
          op = op || {};
          const pts = (points || []).map(p => v3(p, null)).filter(Boolean), once = op.once === true;
          if (pts.length >= 2) motion('path', Object.assign({ points: pts, closed: !once && op.closed !== false, period: fin(op.period) ? op.period : 6 }, once ? { once: true } : {}));
          return this;
        };
        handle.pulse = function (op) { op = op || {}; motion('pulse', { amount: fin(op.amount) ? Math.max(-0.5, Math.min(0.5, op.amount)) : 0.08, period: fin(op.period) ? op.period : 1 }); return this; };
        return handle;
      };
      const surfaceGrid = (fn, op) => {
        op = op || {};
        const segments = Math.max(4, Math.min(160, op.segments || 80)), rowsN = Math.max(2, Math.min(80, op.rows || 16));
        const u = op.u || [0, 1], v = op.v || [0, 1], grid = [];
        for (let j = 0; j <= rowsN; j++) {
          const row = [];
          for (let i = 0; i <= segments; i++) row.push(v3(fn(u[0] + (u[1] - u[0]) * i / segments, v[0] + (v[1] - v[0]) * j / rowsN), [0, 0, 0]).map(r3));
          grid.push(row);
        }
        const rest = Object.assign({}, op);
        delete rest.segments; delete rest.rows; delete rest.u; delete rest.v;
        return { rest, grid };
      };

      api.scene3d = (x, y, w_, h_, build, o) => {
        o = o || {};
        if (![x, y, w_, h_].every(fin) || w_ < 24 || h_ < 24) { warn('scene3d() needs x, y, width and height in pixels'); return null; }
        const { sid, ink } = standStage(x, y, w_, h_, o);
        let partCount = 0, labelCount = 0, currentParent = null;
        const part = (kind, params) => {
          const p = Object.assign({}, params);
          const m = {
            do: 'part3d', id: sid + 'p' + (++partCount), stage: sid, kind, pos: v3(p.at, [0, 0, 0]), rotate3: v3(p.rotate, [0, 0, 0]),
            scale3: fin(p.scale) ? p.scale : 1, material: tintMaterial(pickKeys(p, MATERIAL_KEYS), mateColor), parent: (p.parent && p.parent.id) || currentParent,
          };
          for (const k of ['at', 'rotate', 'scale', 'parent'].concat(MATERIAL_KEYS)) delete p[k];
          m.params = p;
          push(m);
          return bindMotions({ id: m.id, kind: 'part' }, m, sid);
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
          surface(fn, op) {
            let built;
            try { built = surfaceGrid(fn, op); }
            catch (e) { warn('surface() function failed: ' + e.message); return null; }
            return part('surface', Object.assign(built.rest, { grid: built.grid }));
          },
          group(fn, op) {
            const g = part('group', Object.assign({}, op));
            if (typeof fn === 'function') { const saved = currentParent; currentParent = g.id; try { fn(s); } finally { currentParent = saved; } }
            return g;
          },
          camera(op) {
            op = op || {};
            push({ do: 'camera3d', stage: sid, op: { tilt: fin(op.tilt) ? Math.max(-80, Math.min(80, op.tilt)) : undefined, fov: fin(op.fov) ? op.fov : undefined, spin: fin(op.spin) ? op.spin : undefined, target: v3(op.target, undefined), turn: fin(op.turn) ? Math.max(-180, Math.min(180, op.turn)) : undefined } });
          },
          label(point, text, op) {
            op = op || {};
            const t = String(text == null ? '' : text).trim();
            if (!t) return null;
            return push({
              do: 'label3d', id: sid + 'l' + (++labelCount), stage: sid, point: point && point.id ? null : v3(point, [0, 0, 0]), follow: point && point.id ? point.id : null,
              text: t.slice(0, 60), side: op.side === 'left' || op.side === 'right' ? op.side : null, size: fin(op.size) ? Math.max(15, Math.min(28, op.size)) : 19, tone: op.tone || ink,
            });
          },
          build(fn, op) {
            if (typeof fn !== 'function') return s;
            const saved = currentParent;
            if (op && op.parent && op.parent.id) currentParent = op.parent.id;
            try { fn(s); } finally { currentParent = saved; }
            return s;
          },
          part: id => { const n = /^(?:st\d+)?p?(\d+)$/.exec(String(id == null ? '' : id).trim()); return n ? bindMotions({ id: sid + 'p' + n[1] }, { id: sid + 'p' + n[1] }, sid) : null; },
        };
        if (typeof build === 'function') build(s);
        return s;
      };

      // ------------------------------------------------ figure(): one part per statement, studio lit
      const FIGURE_PARTS = ['box', 'cyl', 'cylinder', 'cone', 'tube', 'lathe', 'sphere', 'torus', 'capsule', 'pipe', 'spring', 'gear', 'extrude', 'blob', 'poly', 'arrow'];
      const FIGURE_PLACE_KEYS = ['at', 'pos', 'rot', 'rotate', 'scale', 'parent', 'name', 'mat', 'from', 'to', 'mirror', 'copies', 'around', 'cut'];
      const FIGURE_STANDS_ALONG = { gear: [0, 0, 1], extrude: [0, 0, 1] };
      const FIGURE_ROUND_PARTS = ['cyl', 'cylinder', 'cone', 'tube', 'lathe', 'sphere', 'torus', 'capsule', 'spring', 'gear', 'poly'];
      const FIGURE_MATERIALS = ['steel', 'alu', 'aluminum', 'aluminium', 'titanium', 'chrome', 'brass', 'copper', 'gold', 'iron', 'black', 'rubber', 'glass', 'water',
        'wood', 'ceramic', 'paper', 'gloss', 'paint', 'plastic', 'soft', 'matte', 'metal', 'glow'];
      // three.js Euler XYZ, as quaternions [x, y, z, w]. Copies around an axis need both directions.
      const quatFromEuler = degrees => {
        const [x, y, z] = degrees.map(d => d * Math.PI / 360);
        const cx = Math.cos(x), sx = Math.sin(x), cy = Math.cos(y), sy = Math.sin(y), cz = Math.cos(z), sz = Math.sin(z);
        return [sx * cy * cz + cx * sy * sz, cx * sy * cz - sx * cy * sz, cx * cy * sz + sx * sy * cz, cx * cy * cz - sx * sy * sz];
      };
      const quatAxisAngle = (axis, degrees) => {
        const length = Math.hypot(axis[0], axis[1], axis[2]) || 1, half = degrees * Math.PI / 360, s = Math.sin(half);
        return [axis[0] / length * s, axis[1] / length * s, axis[2] / length * s, Math.cos(half)];
      };
      const quatMul = (a, b) => [
        a[3] * b[0] + a[0] * b[3] + a[1] * b[2] - a[2] * b[1], a[3] * b[1] - a[0] * b[2] + a[1] * b[3] + a[2] * b[0],
        a[3] * b[2] + a[0] * b[1] - a[1] * b[0] + a[2] * b[3], a[3] * b[3] - a[0] * b[0] - a[1] * b[1] - a[2] * b[2]];
      const eulerFromQuat = ([x, y, z, w]) => {
        const m11 = 1 - 2 * (y * y + z * z), m12 = 2 * (x * y - w * z), m13 = 2 * (x * z + w * y);
        const m22 = 1 - 2 * (x * x + z * z), m23 = 2 * (y * z - w * x), m32 = 2 * (y * z + w * x), m33 = 1 - 2 * (x * x + y * y);
        const ry = Math.asin(Math.max(-1, Math.min(1, m13)));
        const [rx, rz] = Math.abs(m13) < 0.9999999 ? [Math.atan2(-m23, m33), Math.atan2(-m12, m11)] : [Math.atan2(m32, m22), 0];
        return [rx, ry, rz].map(r => r3(r * 180 / Math.PI));
      };
      const rotateByQuat = (q, v) => {
        const [x, y, z, w] = q, [vx, vy, vz] = v;
        const tx = 2 * (y * vz - z * vy), ty = 2 * (z * vx - x * vz), tz = 2 * (x * vy - y * vx);
        return [vx + w * tx + (y * tz - z * ty), vy + w * ty + (z * tx - x * tz), vz + w * tz + (x * ty - y * tx)];
      };
      // Rx · Ry · Rz, the same order the stage turns a part.
      const turn3 = (degrees, v) => {
        const [ax, ay, az] = degrees.map(d => d * Math.PI / 180);
        let [x, y, z] = v;
        [x, y] = [x * Math.cos(az) - y * Math.sin(az), x * Math.sin(az) + y * Math.cos(az)];
        [x, z] = [x * Math.cos(ay) + z * Math.sin(ay), -x * Math.sin(ay) + z * Math.cos(ay)];
        [y, z] = [y * Math.cos(ax) - z * Math.sin(ax), y * Math.sin(ax) + z * Math.cos(ax)];
        return [x, y, z];
      };
      const canonical3 = v => {
        if (Array.isArray(v)) return v.map(canonical3).map(x => x === undefined ? null : x);
        if (v && typeof v === 'object') { const o = {}; for (const k of Object.keys(v).sort()) { const c = canonical3(v[k]); if (c !== undefined) o[k] = c; } return o; }
        if (typeof v === 'number') return isFinite(v) ? Math.round(v * 1e4) / 1e4 : undefined;
        return typeof v === 'string' || typeof v === 'boolean' ? v : undefined;
      };
      // transform() writes __name3d("piston") before `const piston = f.cyl(...)`. The next part takes it.
      let pendingName3 = null;
      api.__name3d = name => { pendingName3 = typeof name === 'string' && name ? { name, at: marks.length } : null; };
      let figureTicks = 0;
      api.figure = (x, y, w_, h_, o) => {
        if (x && typeof x === 'object' && !Array.isArray(x)) {
          o = x; x = Math.round(w * 0.5); y = Math.round(h * 0.14); w_ = Math.round(Math.min(620, w * 0.44)); h_ = Math.round(Math.min(480, h * 0.66));
          warn('figure() needs x, y, width and height in pixels; placed it on the right');
        }
        o = o || {};
        if (![x, y, w_, h_].every(fin) || w_ < 24 || h_ < 24) { warn('figure() needs x, y, width and height in pixels'); return null; }
        const { sid, ink } = standStage(x, y, w_, h_, o, 'studio');
        let partCount = 0, labelCount = 0, currentParent = null;
        const motion = (target, kind, fields) => push({ do: 'motion3d', stage: sid, op: Object.assign({ target: target.id, kind }, fields) });
        const anim = id => { const a = sink.anim || (sink.anim = {}); return a[id] || (a[id] = {}); };
        const handleOf = m => {
          const h3 = bindMotions({ id: m.id, kind: 'part', name: m.name || null }, m, sid);
          const inTick = () => hostGlobal().__mateInTick3d === true;
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
              set: v => { if (typeof v === 'string' && v) { const c = realColor(v); pose('color', c, () => motion(m, 'set', { color: c })); } } },
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
          const material = tintMaterial(pickKeys(p, MATERIAL_KEYS), realColor, mateColor);
          if (typeof p.mat === 'string' && p.mat.trim()) {
            const [matKind, tint] = p.mat.trim().toLowerCase().split(':').map(s => s.trim());
            const known = FIGURE_MATERIALS.includes(matKind);
            material.mat = known ? matKind : 'gloss';
            const t = tint || (known ? null : matKind);
            if (t) material.tint = matKind === 'glow' ? mateColor(t) : realColor(t);
          }
          const shape = {};
          for (const k of Object.keys(p)) if (!FIGURE_PLACE_KEYS.includes(k) && !MATERIAL_KEYS.includes(k)) shape[k] = p[k];
          const recipe = Object.assign({}, shape);
          const from = v3(p.from, null), to = v3(p.to, null);
          if (from && to && (kind === 'cyl' || kind === 'cylinder' || kind === 'capsule' || kind === 'cone' || kind === 'tube')) {
            const d = [to[0] - from[0], to[1] - from[1], to[2] - from[2]], len = Math.hypot(d[0], d[1], d[2]);
            if (len > 1e-6) { pos = [(from[0] + to[0]) / 2, (from[1] + to[1]) / 2, (from[2] + to[2]) / 2]; recipe.h = len; recipe.axis = d.map(c => c / len); }
            shape.from = from; shape.to = to;
          }
          // axis and rot that aim the same way used to turn the part twice (a nozzle pointed at the sky).
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
          // A right-angle turn should stretch along the figure's own axes. Any other turn keeps the part's own axes.
          let stretchInPart = stretch;
          if (stretch && rotate3.some(d => Math.abs(d) > 1e-6) && rotate3.every(d => Math.abs(d / 90 - Math.round(d / 90)) < 1e-6)) {
            stretchInPart = [0, 1, 2].map(i => {
              const e = [0, 0, 0]; e[i] = 1;
              const j = turn3(rotate3, e).findIndex(c => Math.abs(c) > 0.5);
              return stretch[j < 0 ? i : j];
            });
          }
          if (stretchInPart) recipe.stretch = stretchInPart;
          if ((kind === 'arrow' || kind === 'pipe') && !v3(p.at, null) && !v3(p.pos, null) && Array.isArray(recipe.points)) {
            const points = recipe.points.map(q => v3(q, null)).filter(Boolean);
            if (points.length >= 2) {
              const middle = [0, 1, 2].map(k => r3(points.reduce((sum, q) => sum + q[k], 0) / points.length));
              recipe.points = points.map(q => q.map((v, k) => r3(v - middle[k])));
              pos = middle;
            }
          }
          const cut = p.cut === true ? 'z' : p.cut && typeof p.cut === 'object' ? p.cut.axis || 'z' : p.cut;
          const cutNormal = cut ? axis3(cut, null) : null;
          if (cutNormal && Math.hypot(...cutNormal) > 1e-6) {
            const length = Math.hypot(...cutNormal), n = cutNormal.map(v => v / length);
            const at = p.cut && typeof p.cut === 'object' && fin(p.cut.at) ? p.cut.at : 0;
            material.cut = [...n.map(r3), r3(at * (n[0] + n[1] + n[2] < 0 ? -1 : 1) * Math.max(...n.map(Math.abs)))];
            if (p.cut === true) material.cutFacing = true;
          }
          const placements = [{ pos, rotate3, reflect: null }];
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
                const offset = rotateByQuat(q, [b.pos[0] - center[0], b.pos[1] - center[1], b.pos[2] - center[2]]);
                placements.push({ pos: offset.map((v, k) => r3(v + center[k])), rotate3: eulerFromQuat(quatMul(q, quatFromEuler(b.rotate3))), reflect: null });
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
            for (const s of reflections) for (const b of unmirrored) {
              placements.push({ pos: b.pos.map((v, k) => r3(v * s[k])), rotate3: [b.rotate3[0] * s[1] * s[2], b.rotate3[1] * s[0] * s[2], b.rotate3[2] * s[0] * s[1]].map(r3), reflect: s });
            }
          }
          const parent = (p.parent && p.parent.id) || currentParent;
          let first = null;
          placements.forEach((place, index) => {
            const own = place.reflect ? Object.assign({}, recipe, { mirror: place.reflect }) : recipe;
            const m = {
              do: 'part3d', id: sid + 'p' + (++partCount), stage: sid, kind, three: true, recipe: JSON.stringify(canonical3(own)), pos: place.pos, rotate3: place.rotate3,
              scale3: fin(p.scale) ? p.scale : 1, material, parent,
            };
            if (name) m.name = index === 0 ? name : `${name} ${place.reflect ? 'mirror' : index + 1}`;
            m.params = shape;
            push(m);
            const shape3d = hostCall('__shape3d');
            if (kind !== 'group' && shape3d) shape3d(kind, m.recipe);
            if (!first) first = m;
          });
          return handleOf(first);
        };
        const f = { id: sid, kind: 'figure' };
        for (const k of FIGURE_PARTS) f[k] = op => part(k === 'cylinder' ? 'cyl' : k, op);
        f.arrow = (a, b) => Array.isArray(a) ? part('arrow', Object.assign({}, b, { points: a })) : part('arrow', a || {});
        f.surface = (fn, op) => {
          let built;
          try { built = surfaceGrid(fn, op); }
          catch (e) {
            warn('surface() function failed: ' + e.message);
            if (pendingName3 && pendingName3.at === marks.length) pendingName3 = null;
            return null;
          }
          return part('surface', Object.assign(built.rest, { grid: built.grid }));
        };
        f.group = (a, b) => {
          const fn = typeof a === 'function' ? a : null, op = fn ? b : a;
          const g = part('group', Object.assign({}, op));
          if (fn) { const saved = currentParent; currentParent = g.id; try { fn(f); } finally { currentParent = saved; } }
          return g;
        };
        f.label = (point, text, op) => {
          op = op || {};
          const t = String(text == null ? '' : text).trim();
          if (!t) return null;
          return push({
            do: 'label3d', id: sid + 'l' + (++labelCount), stage: sid, point: point && point.id ? null : v3(point, [0, 0, 0]), follow: point && point.id ? point.id : null,
            text: t.slice(0, 60), side: op.side === 'left' || op.side === 'right' ? op.side : null, size: fin(op.size) ? Math.max(15, Math.min(28, op.size)) : 19, tone: op.tone || ink,
          });
        };
        f.tick = fn => {
          if (typeof fn !== 'function') { warn('tick() needs a function: tick((t) => { part.pos = [...] })'); return null; }
          const m = push({ do: 'tick3d', id: sid + 't' + (++figureTicks), stage: sid });
          (sink.ticks || (sink.ticks = {}))[m.id] = fn;
          return { id: m.id };
        };
        f.readout = values => {
          if (!values || typeof values !== 'object') return f;
          const r = sink.readouts || (sink.readouts = {}), now = r[sid] || (r[sid] = {});
          for (const k of Object.keys(values).slice(0, 6)) { const v = values[k]; if (v == null) delete now[k]; else now[String(k).slice(0, 24)] = String(v).slice(0, 32); }
          return f;
        };
        f.move = (target, op) => {
          op = op || {};
          if (!target || !target.id) { warn('move() needs a part'); return null; }
          const to = v3(op.to, null), rot = v3(op.rot, null);
          if (!to && !rot) return null;
          motion(target, 'tween', Object.assign({ period: fin(op.secs) ? Math.max(0.05, op.secs) : 0.8 }, to ? { to } : {}, rot ? { rot } : {}));
          return target;
        };
        f.view = f.camera = op => {
          op = op || {};
          push({
            do: 'camera3d', stage: sid, op: {
              tilt: fin(op.tilt) ? Math.max(-80, Math.min(80, op.tilt)) : undefined, fov: fin(op.fov) ? op.fov : undefined, spin: fin(op.spin) ? op.spin : undefined,
              target: v3(op.target, undefined), turn: fin(op.turn) ? Math.max(-180, Math.min(180, op.turn)) : undefined, zoom: fin(op.zoom) ? Math.max(0.5, Math.min(3, op.zoom)) : undefined,
            },
          });
          return f;
        };
        f.build = (fn, op) => {
          if (typeof fn !== 'function') return f;
          const saved = currentParent;
          if (op && op.parent && op.parent.id) currentParent = op.parent.id;
          try { fn(f); } finally { currentParent = saved; }
          return f;
        };
        f.part = id => { const n = /^(?:st\d+)?p?(\d+)$/.exec(String(id == null ? '' : id).trim()); return n ? handleOf({ id: sid + 'p' + n[1] }) : null; };
        return f;
      };

      // ------------------------------------------------ graph: axes in data units
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
        const clip = (a, b) => {
          let lo = 0, hi = 1;
          for (let k = 0; k < 24; k++) { const m = (lo + hi) / 2, p = [a[0] + (b[0] - a[0]) * m, a[1] + (b[1] - a[1]) * m]; if (inRange(p)) lo = m; else hi = m; }
          return [a[0] + (b[0] - a[0]) * lo, a[1] + (b[1] - a[1]) * lo];
        };
        // The visible part of a segment whose ends are both outside the frame. The old walk only noticed a segment when one end was inside, so a chord across the frame drew nothing.
        const rectCut = (a, b) => {
          if (!(xr[0] <= xr[1])) return null;
          const xMin = xr[0], xMax = xr[1], yMin = Math.min(yr[0], yr[1]), yMax = Math.max(yr[0], yr[1]);
          let t0 = 0, t1 = 1;
          const dx = b[0] - a[0], dy = b[1] - a[1];
          const side = (p, q) => {
            if (p === 0) return q >= -1e-9;
            const t = q / p;
            if (p < 0) { if (t > t1) return false; if (t > t0) t0 = t; }
            else { if (t < t0) return false; if (t < t1) t1 = t; }
            return true;
          };
          if (!side(-dx, a[0] - xMin) || !side(dx, xMax - a[0]) || !side(-dy, a[1] - yMin) || !side(dy, yMax - a[1]) || t1 - t0 < 1e-8) return null;
          const atT = t => [a[0] + dx * t, a[1] + dy * t];
          return [atT(t0), atT(t1)];
        };
        const yAt = rows => u => {
          for (let k = 1; k < rows.length; k++) {
            const a = rows[k - 1], b = rows[k];
            if (!finite(a) || !finite(b) || a[0] === b[0]) continue;
            if ((u - a[0]) * (u - b[0]) <= 0) return a[1] + (b[1] - a[1]) * (u - a[0]) / (b[0] - a[0]);
          }
          return null;
        };
        const midOf = data => {
          const P = data.map(p => at(p));
          let L = 0;
          for (let k = 1; k < P.length; k++) L += Math.hypot(P[k][0] - P[k - 1][0], P[k][1] - P[k - 1][1]);
          let acc = 0;
          for (let k = 1; k < P.length; k++) {
            const d = Math.hypot(P[k][0] - P[k - 1][0], P[k][1] - P[k - 1][1]);
            if (acc + d >= L / 2 && d) { const t = (L / 2 - acc) / d; return [data[k - 1][0] + (data[k][0] - data[k - 1][0]) * t, data[k - 1][1] + (data[k][1] - data[k - 1][1]) * t]; }
            acc += d;
          }
          return data[0] || [0, 0];
        };
        const series = (rows, po, straight) => {
          rows = Array.isArray(rows) ? rows : [];
          const pieces = [];
          let cur = [];
          const flush = () => { if (cur.length) pieces.push(cur); cur = []; };
          for (let k = 0; k < rows.length; k++) {
            const p = rows[k];
            if (!finite(p)) { flush(); continue; }
            const prev = k > 0 && finite(rows[k - 1]) ? rows[k - 1] : null;
            if (inRange(p)) {
              if (!cur.length && prev && !inRange(prev)) cur.push(clip(p, prev));
              cur.push(p);
            } else if (cur.length) { cur.push(clip(rows[k - 1], p)); flush(); }
            else if (prev && !inRange(prev)) { const crossed = rectCut(prev, p); if (crossed) pieces.push(crossed); }
          }
          flush();
          const data = rows.filter(finite);
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
            if (p[1] <= ax && ly > ax - 12) ly = p[1] - 12;
            api.text(lx, Math.max(22, Math.min(h - 8, ly)), po.label, { anchor, size: po.labelSize || 18, tone: po.labelTone || tn, piece: 'graph' });
          }
          const y = yAt(rows), mid = midOf(data);
          return { data, tone: tn, size: sz, straight, label: po.label, start, end, mid: at(mid), midData: mid, pts: data.map(p => at(p)), y, at: u => { const v = y(u); return v == null ? null : at(u, v); } };
        };
        const g = { box: { x: gx, y: gy, w: gw, h: gh }, origin: [ay, ax], x: X, y: Y, at };
        g.plot = (f, po) => {
          po = po || {};
          if (typeof f === 'function') {
            const a = po.from != null ? po.from : xr[0], b = po.to != null ? po.to : xr[1], n = po.samples || 64, data = [];
            for (let k = 0; k <= n; k++) {
              const u = a + (b - a) * k / n;
              let v; try { v = f(u); } catch (_) { v = NaN; }
              data.push(isFinite(v) ? [u, v] : null);
            }
            return series(data, po, false);
          }
          if (Array.isArray(f)) return series(f, po, po.smooth === true ? false : po.straight != null ? !!po.straight : f.length <= 8);
          warn('graph: plot() needs a function or a list of [x, y] points');
          return null;
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
            const rv = [p2[0] - p[0], p2[1] - p[1]], sv = [q2[0] - q[0], q2[1] - q[1]], den = rv[0] * sv[1] - rv[1] * sv[0];
            if (Math.abs(den) < 1e-12) continue;
            const t = ((q[0] - p[0]) * sv[1] - (q[1] - p[1]) * sv[0]) / den, u = ((q[0] - p[0]) * rv[1] - (q[1] - p[1]) * rv[0]) / den;
            if (t >= -1e-9 && t <= 1 + 1e-9 && u >= -1e-9 && u <= 1 + 1e-9) return [p[0] + rv[0] * t, p[1] + rv[1] * t];
          }
          warn('graph: these two lines do not cross inside the graph');
          return null;
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

      // ------------------------------------------------ timeline: dated marks, with room for a picture
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
        const placed = ev.map((e, i) => {
          const x = xs[i], wordsBelow = o.slots === 'below' ? false : alt ? i % 2 === 0 : true, slotBelow = alt ? wordsBelow : o.slots === 'below';
          api.line([[x, ty - 9], [x, ty + 9]], { tone: tn, size: 3, smooth: false, piece: 'timeline' });
          api.dot(x, ty, 5.5, { tone: o.dotTone || 'coral', piece: 'timeline' });
          const ds = e.show != null ? String(e.show) : num ? fmt(e.date) : String(e.date), lw = Math.min(190, (alt ? 1.85 : 0.96) * room(i));
          const sw = o.slotW || Math.min(150, (alt ? 1.8 : 0.9) * room(i));
          const ls = o.labelSize || 17, dsz = o.dateSize || 18;
          const two = e.label && textW(e.label, ls) > lw - 6;
          if (wordsBelow) { api.text(x, ty + 30, ds, { anchor: 'middle', size: dsz, tone: o.dateTone || tn, piece: 'timeline' }); if (e.label) api.text(x, ty + (two ? 64 : 56), e.label, { anchor: 'middle', size: ls, fit: [lw - 6, 44], piece: 'timeline' }); }
          else { api.text(x, ty - 18, ds, { anchor: 'middle', size: dsz, tone: o.dateTone || tn, piece: 'timeline' }); if (e.label) api.text(x, ty - (two ? 54 : 44), e.label, { anchor: 'middle', size: ls, fit: [lw - 6, 44], piece: 'timeline' }); }
          const far = alt;
          const space = slotBelow ? h - 10 - (ty + (far ? 90 : 16)) : ty - (far ? 92 : 16) - 60;
          const sh = o.slotH || Math.max(40, Math.min(far ? 110 : 150, space));
          const sy = slotBelow ? ty + (far ? 90 : 16) : ty - (far ? 92 : 16) - sh;
          return { date: e.date, label: e.label, x, y: ty, at: [x, ty], slot: { x: x - sw / 2, y: sy, w: sw, h: sh, cx: x, cy: sy + sh / 2 } };
        });
        const atDate = d => {
          if (!num || typeof d !== 'number') { const k = ev.findIndex(e => e.date === d); return k >= 0 ? [xs[k], ty] : [tx, ty]; }
          const s = order.map(i => [ev[i].date, xs[i]]);
          if (d <= s[0][0]) return [s[0][1] - (s[0][0] - d) / ((hi - lo) || 1) * span, ty];
          for (let k = 1; k < s.length; k++) if (d <= s[k][0]) return [s[k - 1][1] + (s[k][1] - s[k - 1][1]) * (d - s[k - 1][0]) / ((s[k][0] - s[k - 1][0]) || 1), ty];
          return [s[s.length - 1][1] + (d - s[s.length - 1][0]) / ((hi - lo) || 1) * span, ty];
        };
        return { marks: placed, events: placed, at: atDate, slot: i => placed[i] ? placed[i].slot : null, start: [tx, ty], end: [tx + tw, ty] };
      };

      // ------------------------------------------------ edits of what is already on the card
      const ids = id => Array.isArray(id) ? id.map(x => typeof x === 'number' ? 'p' + x : String(x)) : typeof id === 'number' ? 'p' + id : String(id == null ? '' : id);
      const edit = op => { if (!op.id && op.op !== 'startOver' && op.op !== 'turn') warn(op.op + '() needs a part id like "p3"'); return push({ do: 'edit', op }); };
      api.erase = id => edit({ op: 'erase', id: ids(id) });
      api.recolor = (id, c) => edit(Object.assign({}, c && typeof c === 'object' ? c : { color: c }, { op: 'recolor', id: ids(id) }));
      api.restyle = (id, o) => edit(Object.assign({}, o && typeof o === 'object' ? o : {}, { op: 'restyle', id: ids(id) }));
      api.move = (id, dx, dy) => edit({ op: 'move', id: ids(id), dx: +dx || 0, dy: +dy || 0 });
      api.moveTo = (id, x, y) => edit({ op: 'moveTo', id: ids(id), x: +x, y: +y });
      api.scale = (id, k) => edit({ op: 'scale', id: ids(id), k: +k });
      api.highlight = (a, b, c, d, o) => typeof a === 'number' ? push({ do: 'highlight', at: [a, b], w: c, h: d }, o)
        : edit({ op: 'highlight', id: ids(a), color: b && typeof b === 'object' ? b.color : b });
      api.startOver = () => edit({ op: 'startOver' });
      api.__turn = (n, keep) => { curTurn = +n || curTurn + 1; curStep = 1; cue = null; return edit({ op: 'turn', turn: curTurn, keep: keep == null ? null : +keep }); };
      let seed = 20260925;
      api.Math = Object.create(Math, { random: { value: () => ((seed = (seed * 1664525 + 1013904223) >>> 0) / 4294967296) } });
      api.random = api.Math.random;
      for (const t of TONE_NAMES) if (!(t in api)) api[t] = t;
      return api;
    }
    // a mark as plain data: no functions, so it can cross into the page or be posted from a worker
    function clean(m) {
      const o = {};
      for (const k in m) if (typeof m[k] !== 'function' && typeof m[k] !== 'symbol') o[k] = m[k];
      return o;
    }

    // ---------------------------------------------------------------- the rewrite every program gets
    // A drawing runs statement by statement as it streams in, each statement in the same scope as the ones before. So
    // that names last from one statement to the next (and a later turn may declare a name an earlier one did), each
    // top-level declaration becomes a var: const and let become var, and a class becomes a var holding the class. A
    // function named like a drawing call is made a var too, so it shadows the call. A statement that opens with ( [ or `
    // is a new statement, as the model means it (run whole, the line above would have taken it as its own call or index).
    // Line breaks are never added or removed, so error lines stay the program's own.
    const FIGURE_PART = /^(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*[A-Za-z_$][\w$]*\s*\.\s*(?:box|cyl|cylinder|cone|tube|lathe|sphere|torus|capsule|pipe|spring|gear|extrude|blob|poly|surface|group)\s*\(/;
    function transform(src, starts, api) {
      let out = '', copied = 0;
      for (const s of starts) {
        let i = s;
        for (;;) {                                         // past blanks and comments to the statement itself
          while (i < src.length && /\s/.test(src[i])) i++;
          if (src.startsWith('//', i)) { const j = src.indexOf('\n', i); i = j < 0 ? src.length : j; continue; }
          if (src.startsWith('/*', i)) { const j = src.indexOf('*/', i + 2); i = j < 0 ? src.length : j + 2; continue; }
          break;
        }
        if (i < copied || i >= src.length) continue;       // two starts can lead to the same statement (a comment block before it)
        const head = src.slice(i, i + 160);
        out += src.slice(copied, i);
        copied = i;
        // three-metal: a figure part kept in a variable (const piston = f.cyl(...)) is named after it
        const part = '__name3d' in api && FIGURE_PART.exec(head);
        if (part) out += '__name3d(' + JSON.stringify(part[1]) + ');';
        let m;
        if ((m = /^(const|let)(?=\s)/.exec(head))) { out += m[1] === 'const' ? 'var  ' : 'var'; copied = i + m[1].length; }
        else if ((m = /^class\s+([A-Za-z_$][\w$]*)/.exec(head))) out += 'var ' + m[1] + ' = ';
        else if ((m = /^(?:async\s+)?function\s*\*?\s*([A-Za-z_$][\w$]*)/.exec(head)) && m[1] in api) out += 'var ' + m[1] + ' = ';
        else if (s > 0 && '([`'.includes(src[i])) out += ';';
      }
      return out + src.slice(copied);
    }
    // a whole program gets the same rewrite, so running it at once draws exactly what streaming it does
    const wholeProgram = (code, api, knownEnds) => transform(code, [0].concat((knownEnds || statementEnds(code + '\n;')).filter(e => e < code.length)), api);
    // the program's own code inside the function the runner makes: it starts on this line of the function's source
    const FIRST_LINE = 4;                                // "function anonymous(api", ") {", "with (api) {", the program
    // a name for the program's code, so a stack names its frames ("at eval (mate-drawing-program:7:3)")
    const PROGRAM_URL = 'mate-drawing-program';
    const compile = code => new Function('api', 'with (api) {\n' + code + '\n}\n//# sourceURL=' + PROGRAM_URL);
    // The program line an error came from, or null when it is not known. V8 names the program's frames, so the first
    // one is the program line that was running, even when a drawing call threw. JavaScriptCore (the app) ignores the
    // name and gives its frames no places; its e.line is trusted only when the program's own top-level code threw
    // (its unnamed frame comes first), since an error thrown inside a drawing call carries a line of the engine.
    function errorLine(e) {
      if (!e || typeof e !== 'object') return null;
      const stack = String(e.stack || ''), named = new RegExp(PROGRAM_URL + ':(\\d+)').exec(stack);
      if (named) return +named[1] - FIRST_LINE + 1;
      if (typeof e.line === 'number' && /^(?:anonymous|eval)?@/.test(stack)) return e.line - FIRST_LINE + 1;
      return null;
    }

    // ---------------------------------------------------------------- running a program
    // A whole program at once (render(), and live() when a statement fails). A syntax error keeps the longest run of
    // complete statements that compiles, the way streaming would have drawn them; a runtime error keeps the marks made
    // before it. Either way the marks carry the error, with the program line it happened at when it is known.
    function runCode(code, w, h, ro) {
      ro = ro || {};
      const sink = { marks: [], says: [], warnings: [], deadline: ro.budgetMs ? Date.now() + ro.budgetMs : 0, ticks: {}, anim: {} };
      const api = makeApi(w, h, sink), marks = sink.marks;
      let error = null, fn = null;
      try { fn = compile(wholeProgram(code, api, ro.knownEnds)); }
      catch (e) {
        const ends = statementEnds(code + '\n');
        for (let k = ends.length - 1; k >= 0 && !fn; k--) {
          const kept = code.slice(0, ends[k]);
          try { fn = compile(wholeProgram(kept, api)); error = `syntax error after line ${kept.split('\n').length}: ${e.message}`; } catch (_) {}
        }
        if (!fn) error = `syntax error: ${e.message}`;
      }
      if (fn) {
        try { fn(api); }
        catch (e) { const line = errorLine(e), known = line > 0 && line <= code.split('\n').length; error = `code stopped${known ? ' at line ' + line : ''}: ${e && e.message !== undefined ? e.message : e}`; }
      }
      if (error) error += ` (kept the ${marks.length} marks before it)`;
      marks.error = error; marks.says = sink.says; marks.warnings = sink.warnings;
      // three-metal: figure() tick functions and the poses they set, for a run that keeps going (Session, full mode)
      Object.defineProperty(marks, 'live3d', { value: { ticks: sink.ticks, anim: sink.anim }, enumerable: false });
      return marks;
    }

    // A program run as it streams in: each new run of complete statements is evaluated once, in one scope that lasts
    // (a generator paused inside `with (api)`, fed code to eval). A syntax error before the program is done only means
    // more code is coming. Any other error switches to running the whole program so far from the start on every update
    // ('full'), which draws exactly what render() would. update() returns what is new since the last call.
    function Session(w, h, so) {
      so = so || {};
      const budget = so.budgetMs || 0;
      let sink, api, evaluator, mode, ran, sent, fellBack = null;
      function reset() {
        sink = { marks: [], says: [], warnings: [], ticks: {}, anim: {} };
        api = makeApi(w, h, sink);
        evaluator = null;
        mode = so.incremental === false ? 'full' : 'inc';
        ran = '';
        sent = { marks: 0, says: 0, warnings: 0 };
      }
      function evaluate(chunk) {
        if (!evaluator) {
          evaluator = new Function('__api', 'return function* () { with (__api) { let __r = null; for (;;) { const __c = yield __r; __r = null; try { eval(__c); } catch (e) { __r = e; } } } }')(api)();
          evaluator.next();
        }
        sink.deadline = budget ? Date.now() + budget : 0;
        try { return evaluator.next(chunk).value; } catch (e) { return e; }
      }
      reset();
      // knownEnds (optional): statementEnds() of a longer program that `full` is the start of, when the caller has them
      function update(full, done, knownEnds) {
        if (!full.startsWith(ran)) reset();                // not just more code: start again
        const added = full.slice(ran.length);
        if (mode === 'inc' && added.trim()) {
          const base = ran.length;
          const starts = [0].concat((knownEnds || statementEnds(full + '\n;')).filter(e => e > base && e < full.length).map(e => e - base));
          const err = evaluate(transform(added, starts, api));
          if (err && err.name === 'SyntaxError' && !done) return { marks: [], says: [], warnings: [], error: null, mode };
          if (err) { mode = 'full'; fellBack = String(err && err.message !== undefined ? err.message : err); }
        }
        ran = full;
        let error = null;
        if (mode === 'full') {
          const m = runCode(ran, w, h, { budgetMs: budget });
          sink = { marks: m, says: m.says, warnings: m.warnings, ticks: m.live3d.ticks, anim: m.live3d.anim };
          error = m.error;
        }
        const out = { marks: sink.marks.slice(sent.marks).map(clean), says: sink.says.slice(sent.says), warnings: sink.warnings.slice(sent.warnings), error: done ? error : null, mode };
        sent = { marks: Math.max(sent.marks, sink.marks.length), says: Math.max(sent.says, sink.says.length), warnings: Math.max(sent.warnings, sink.warnings.length) };
        return out;
      }
      // code: the program run so far (a continued turn appends to exactly this)
      // live3d: this run's figure() tick functions and the poses they set (three-metal; mateCanvas.tick3d runs them)
      return { update, get mode() { return mode; }, get fellBack() { return fellBack; }, get code() { return ran; }, get live3d() { return { ticks: sink.ticks, anim: sink.anim }; } };
    }
    // Which top-level statement made which marks, run the way live() runs them. [{s, e, n0, n1}]: each statement's
    // character span and the indices of the marks it drew.
    function attribute(code, w, h) {
      const run = Session(w, h), all = statementEnds(code + '\n;'), out = [];
      let made = 0, from = 0;
      const take = (to, done) => {
        const n = run.update(code.slice(0, to), done, done ? undefined : all).marks.length;
        out.push({ s: from, e: to, n0: made, n1: made + n });
        made += n; from = to;
      };
      for (const e of statementEnds(code)) take(e, false);
      if (from < code.length) take(code.length, true);
      return out;
    }
    // A code fragment (an edit's "add" or "redraw") run after the drawing's own program, so its helpers and variables
    // are in scope. Only the fragment's marks come back.
    function exec(base, frag, w, h, budgetMs) {
      const run = Session(w, h, { budgetMs });
      run.update(base, true);
      return run.update(base + '\n;\n' + frag + '\n', true);
    }
    return { statementEnds, statementScanner, runCode, Session, clean, attribute, exec, textW };
  }
  const RUNNER = makeRunner(Object.keys(TONES), TONES, REAL_TONES, COLOR_WORDS);
  const { statementEnds, textW } = RUNNER;
  const runCode = (code, w, h, o) => RUNNER.runCode(code, w, h, o);

  // ================================================================ the sandbox: the runner inside a Web Worker, no DOM, no network, a time limit
  // The worker builds its own runner from makeRunner's text, then takes away every way out of the page: network,
  // storage, timers, more workers, messaging. Each name goes from the global and from every prototype above it (in a
  // real worker fetch lives on WorkerGlobalScope.prototype, where taking it off the global alone left it reachable).
  function workerMain(makeRunner, toneNames, mateTones, realTones, colorWords) {
    const post = self.postMessage.bind(self), runner = makeRunner(toneNames, mateTones, realTones, colorWords);
    let session = null;
    const jobs = {
      init: q => { session = runner.Session(q.w, q.h, { budgetMs: q.budgetMs }); return { type: 'ready' }; },
      run: q => Object.assign({ type: 'result', id: q.id }, session.update(q.code, q.done)),
      exec: q => Object.assign({ type: 'exec', id: q.id }, runner.exec(q.base, q.code, q.w, q.h, q.budgetMs)),
      attrib: q => ({ type: 'attrib', id: q.id, stmts: runner.attribute(q.code, q.w, q.h) }),
    };
    self.addEventListener('message', ev => {
      const q = ev.data || {}, job = jobs[q.type];
      if (!job) return;
      try { post(job(q)); }
      catch (e) {
        // the reply the job would have sent, carrying the error ('failed' when the sandbox could not even start)
        const type = q.type === 'init' ? 'failed' : q.type === 'run' ? 'result' : q.type;
        post({ type, id: q.id, marks: [], says: [], warnings: [], error: 'sandbox: ' + (e && e.message !== undefined ? e.message : e) });
      }
    });
    const OUTSIDE = ['fetch', 'XMLHttpRequest', 'WebSocket', 'WebSocketStream', 'EventSource', 'WebTransport', 'RTCPeerConnection', 'importScripts',
      'indexedDB', 'caches', 'storage', 'BroadcastChannel', 'Worker', 'SharedWorker', 'postMessage', 'close', 'setTimeout', 'setInterval',
      'navigator', 'location', 'Request', 'Response', 'Notification', 'FileReader', 'FileReaderSync', 'webkitRequestFileSystem', 'webkitResolveLocalFileSystemURL'];
    for (let o = self; o && o !== Object.prototype; o = Object.getPrototypeOf(o))
      for (const k of OUTSIDE) if (Object.prototype.hasOwnProperty.call(o, k)) try { delete o[k]; } catch (_) {}
    for (const k of OUTSIDE) try { Object.defineProperty(self, k, { value: undefined, writable: false, configurable: false }); } catch (_) {}
  }
  let WORKER_URL = null;
  const workerSource = () => `(${workerMain.toString()})(${makeRunner.toString()}, ${JSON.stringify(Object.keys(TONES))}, ${JSON.stringify(TONES)}, ${JSON.stringify(REAL_TONES)}, ${JSON.stringify(COLOR_WORDS)});`;
  // a new sandbox worker, or null where the page cannot make one
  function spawnWorker() {
    try {
      if (!WORKER_URL) WORKER_URL = URL.createObjectURL(new Blob([workerSource()], { type: 'text/javascript' }));
      return new Worker(WORKER_URL);
    } catch (_) { return null; }
  }
  // A new worker first builds its runner. A program's time limit starts only once the worker is ready (a cold start
  // used to count against the first program, so a slow machine could stop a quick drawing), and the start has its own.
  const START_LIMIT = 5000;
  const budgetOf = limit => Math.round(limit * 0.8);   // the runner stops making marks a little before the hard stop
  // The drawing's own worker: each run() sends the whole program so far, and a newer one replaces any still waiting.
  function WorkerRunner(W, H, o, onResult) {
    const w = spawnWorker();
    if (!w) return null;
    const limit = o.timeLimit || 1500;
    let ready = false, inflight = null, waiting = null, dead = false, timer = null, id = 0;
    const stop = () => { dead = true; clearTimeout(timer); w.terminate(); };
    const kill = error => { if (dead) return; stop(); onResult({ marks: [], says: [], warnings: [], error }, true); };
    const arm = (ms, error) => { clearTimeout(timer); timer = setTimeout(() => kill(error), ms); };
    function next() {
      if (dead || !ready || inflight || !waiting) return;
      inflight = waiting; waiting = null;
      w.postMessage({ type: 'run', id: ++id, code: inflight.code, done: inflight.done });
      arm(limit, `the drawing program ran longer than ${limit} ms and was stopped (kept what it drew before)`);
    }
    w.onmessage = ev => {
      const r = ev.data || {};
      if (dead) return;
      if (r.type === 'ready') { ready = true; clearTimeout(timer); next(); }
      else if (r.type === 'failed') kill(r.error);
      else if (r.type === 'result') {
        clearTimeout(timer);
        const job = inflight; inflight = null;
        onResult(r, !!(job && job.done));
        next();
      }
    };
    w.onerror = e => kill('sandbox error: ' + (e.message || 'unknown'));
    w.postMessage({ type: 'init', w: W, h: H, budgetMs: budgetOf(limit) });
    arm(START_LIMIT, `the drawing sandbox did not start within ${START_LIMIT} ms`);
    return { run: (code, done) => { waiting = { code, done }; next(); }, stop, sandboxed: true };
  }
  // One job ('exec' or 'attrib') in a fresh throwaway worker, with the same limits as the drawing's own worker.
  function sandboxJob(msg, limit) {
    limit = limit || 1500;
    return new Promise((resolve, reject) => {
      const w = spawnWorker();
      if (!w) { reject(new Error('the sandbox is not available')); return; }
      let timer = null;
      const end = (settle, value) => { clearTimeout(timer); w.terminate(); settle(value); };
      const arm = (ms, why) => { clearTimeout(timer); timer = setTimeout(() => end(reject, new Error(why)), ms); };
      w.onmessage = ev => {
        const r = ev.data || {};
        if (r.type === 'ready') { w.postMessage(Object.assign({ budgetMs: budgetOf(limit) }, msg)); arm(limit, `the edit's code ran longer than ${limit} ms and was stopped`); }
        else if (r.type === 'failed') end(reject, new Error(r.error));
        else end(resolve, r);
      };
      w.onerror = e => end(reject, new Error('sandbox error: ' + (e.message || 'unknown')));
      w.postMessage({ type: 'init', w: msg.w, h: msg.h, budgetMs: budgetOf(limit) });
      arm(START_LIMIT, `the sandbox did not start within ${START_LIMIT} ms`);
    });
  }

  // ================================================================ timing: how long the pen takes over each mark (DOM-free)
  // The pen's speed is settable (MateDraw.setPen): a stroke takes base + length / per seconds, held between min and
  // max. Also settable: `ease` (the pen's CSS timing function), `halo` ({'#FFFFFF': [colour, opacity, width]}: an
  // outline drawn under strokes of that ink, in place of the page's blurred shadows), `wash` (false drops the
  // watercolour filter on fills) and `washMaxArea` (bigger fills skip it). Filters and blurs repaint every frame while a
  // stroke animates, which is costly on a full-screen Retina canvas.
  const PEN = { per: 600, base: 0, min: 0.14, max: 0.7, ease: null, halo: null, wash: true, washMaxArea: Infinity };
  const penDur = len => Math.max(PEN.min, Math.min(PEN.max, PEN.base + len / PEN.per));
  function setPen(o) {
    if (o) {
      for (const k of ['per', 'min', 'max', 'washMaxArea']) if (typeof o[k] === 'number' && o[k] > 0) PEN[k] = o[k];
      if (Number.isFinite(o.base)) PEN.base = o.base;     // (a NaN base used to get in and stop every stroke)
      if ('ease' in o) PEN.ease = typeof o.ease === 'string' ? o.ease : null;
      if ('halo' in o) PEN.halo = o.halo && typeof o.halo === 'object' ? Object.assign({}, o.halo) : null;
      if ('wash' in o) PEN.wash = o.wash !== false;
    }
    return Object.assign({}, PEN);
  }
  // Steps are counted per turn (a continued drawing starts its steps again), so a step is known by both.
  const stepKey = m => m && m.turn ? m.turn + '/' + m.step : m && m.step;

  // An SVG path as the runs of points its pen draws: every command, absolute or relative, with curves sampled and arcs
  // followed. (Paths used to be read as a flat list of number pairs, so a relative path had no length or place, and
  // H, V and arc arguments were taken for points.)
  const PATH_ARGS = { M: 2, L: 2, T: 2, H: 1, V: 1, C: 6, S: 4, Q: 4, A: 7 };
  function pathRuns(d) {
    const tok = String(d == null ? '' : d).match(/[A-Za-z]|[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?/g) || [];
    const runs = [], isCmd = t => /^[A-Za-z]$/.test(t);
    let run = null, x = 0, y = 0, sx = 0, sy = 0, cx = 0, cy = 0, cmd = '', last = '', k = 0;
    const to = (nx, ny) => { run.push([nx, ny]); x = nx; y = ny; };
    const bezier = (p) => {                              // p: the control points after the current one
      const x0 = x, y0 = y, n = p.length / 2;
      for (let s = 1; s <= 8; s++) {
        const t = s / 8, u = 1 - t;
        if (n === 2) to(u * u * x0 + 2 * u * t * p[0] + t * t * p[2], u * u * y0 + 2 * u * t * p[1] + t * t * p[3]);
        else to(u * u * u * x0 + 3 * u * u * t * p[0] + 3 * u * t * t * p[2] + t * t * t * p[4], u * u * u * y0 + 3 * u * u * t * p[1] + 3 * u * t * t * p[3] + t * t * t * p[5]);
      }
    };
    while (k < tok.length) {
      if (isCmd(tok[k])) cmd = tok[k++];
      else if (!cmd) { k++; continue; }
      const C = cmd.toUpperCase(), rel = cmd !== C;
      if (C === 'Z') { if (run) { to(sx, sy); run = null; } cmd = ''; last = 'Z'; continue; }
      const n = PATH_ARGS[C];
      if (!n) { cmd = ''; continue; }
      const a = [];
      while (a.length < n && k < tok.length && !isCmd(tok[k])) a.push(+tok[k++]);
      if (a.length < n) break;                            // cut off mid-command: what came before stands
      const ox = rel ? x : 0, oy = rel ? y : 0;
      if (C === 'M') { run = [[ox + a[0], oy + a[1]]]; runs.push(run); x = sx = ox + a[0]; y = sy = oy + a[1]; cmd = rel ? 'l' : 'L'; last = 'M'; continue; }
      if (!run) { run = [[x, y]]; runs.push(run); sx = x; sy = y; }
      if (C === 'L') to(ox + a[0], oy + a[1]);
      else if (C === 'H') to(ox + a[0], y);
      else if (C === 'V') to(x, oy + a[0]);
      else if (C === 'C') { bezier([ox + a[0], oy + a[1], ox + a[2], oy + a[3], ox + a[4], oy + a[5]]); cx = ox + a[2]; cy = oy + a[3]; }
      else if (C === 'S') { const r = last === 'C' || last === 'S'; bezier([r ? 2 * x - cx : x, r ? 2 * y - cy : y, ox + a[0], oy + a[1], ox + a[2], oy + a[3]]); cx = ox + a[0]; cy = oy + a[1]; }
      else if (C === 'Q') { bezier([ox + a[0], oy + a[1], ox + a[2], oy + a[3]]); cx = ox + a[0]; cy = oy + a[1]; }
      else if (C === 'T') { const r = last === 'Q' || last === 'T'; const qx = r ? 2 * x - cx : x, qy = r ? 2 * y - cy : y; bezier([qx, qy, ox + a[0], oy + a[1]]); cx = qx; cy = qy; }
      else if (C === 'A') for (const p of arcPoints(x, y, a[0], a[1], a[2], !!a[3], !!a[4], ox + a[5], oy + a[6])) to(p[0], p[1]);
      last = C;
    }
    return runs.filter(r => r.every(p => isFinite(p[0]) && isFinite(p[1])));
  }
  // the points along an SVG arc from (x1, y1) to (x2, y2), every 15 degrees or less (SVG's endpoint parametrisation)
  function arcPoints(x1, y1, rx, ry, turn, large, sweep, x2, y2) {
    rx = Math.abs(rx); ry = Math.abs(ry);
    if (!rx || !ry || (x1 === x2 && y1 === y2)) return [[x2, y2]];
    const c = Math.cos(turn * Math.PI / 180), s = Math.sin(turn * Math.PI / 180);
    const hx = (x1 - x2) / 2, hy = (y1 - y2) / 2, px = c * hx + s * hy, py = -s * hx + c * hy;
    const grow = Math.sqrt(px * px / (rx * rx) + py * py / (ry * ry));
    if (grow > 1) { rx *= grow; ry *= grow; }            // radii too small to reach: scaled up just enough, as SVG does
    const num = rx * rx * ry * ry - rx * rx * py * py - ry * ry * px * px, den = rx * rx * py * py + ry * ry * px * px;
    const f = (large === sweep ? -1 : 1) * Math.sqrt(Math.max(0, num / den));
    const qx = f * rx * py / ry, qy = -f * ry * px / rx;
    const ox = c * qx - s * qy + (x1 + x2) / 2, oy = s * qx + c * qy + (y1 + y2) / 2;
    const from = Math.atan2((py - qy) / ry, (px - qx) / rx);
    let span = Math.atan2((-py - qy) / ry, (-px - qx) / rx) - from;
    if (!sweep && span > 0) span -= 2 * Math.PI; else if (sweep && span < 0) span += 2 * Math.PI;
    const n = Math.max(2, Math.ceil(Math.abs(span) / (Math.PI / 12))), out = [];
    for (let i = 1; i <= n; i++) {
      const t = from + span * i / n, ex = rx * Math.cos(t), ey = ry * Math.sin(t);
      out.push(i === n ? [x2, y2] : [ox + c * ex - s * ey, oy + s * ex + c * ey]);
    }
    return out;
  }
  // a stroke's length along its points (a missing point or a bad number adds nothing)
  function strokeLength(pts) {
    let s = 0;
    if (Array.isArray(pts)) for (let i = 1; i < pts.length; i++) if (pts[i] && pts[i - 1]) s += Math.hypot(pts[i][0] - pts[i - 1][0], pts[i][1] - pts[i - 1][1]) || 0;
    return s;
  }
  const pathLength = d => pathRuns(d).reduce((s, run) => s + strokeLength(run), 0);
  // letters as a reader counts them (an emoji is one, not its two UTF-16 halves)
  const letters = s => [...String(s)].length;

  // How long a mark takes to draw (dur) and how long until the next one starts (adv), at pace 1. A mark with
  // `together: true` starts with the next one instead of before it (a gel pill's stacked fills appear as one piece).
  function natural(m) { const n = naturalAlone(m); return m && m.together ? { dur: n.dur, adv: 0 } : n; }
  const MARK_TIME = { dot: [0.25, 0.06], stage3d: [0.35, 0.12], image: [0.5, 0.3], window: [0.45, 0.3], part3d: [0.65, 0.12], motion3d: [0, 0], camera3d: [0, 0], tick3d: [0, 0] };
  const plainTime = dur => ({ dur, adv: dur * 0.7 });
  const textTime = s => { const n = letters(s); return { dur: 0.4 + n * 0.015, adv: (0.35 + n * 0.012) * 0.7 }; };
  function naturalAlone(m) {
    if (!m || typeof m !== 'object') return plainTime(0.3);
    const fixed = MARK_TIME[m.do], outlined = m.outline !== false;
    if (fixed) return { dur: fixed[0], adv: fixed[1] };
    switch (m.do) {
      // an edit takes as long as its animation (estimated from what it touches when the stream planned it)
      case 'edit': { const e = m.__est != null ? m.__est : editEstimate(m.op, null); return { dur: e, adv: e }; }
      case 'text': case 'label3d': return textTime(m.text);
      case 'line':
        if (m.dash && Array.isArray(m.marquee)) return { dur: MARQUEE_DUR, adv: MARQUEE_DUR * 0.8 };
        return plainTime(m.dash ? Math.min(0.9, 0.2 + strokeLength(m.pts) / 900) : penDur(strokeLength(m.pts)));
      case 'arrow': { const d = penDur(strokeLength(m.pts)); return { dur: d + 0.16, adv: d + 0.1 }; }
      case 'circle': case 'ellipse': { const rx = +(m.r || m.rx) || 10, ry = +(m.r || m.ry) || 10; return plainTime(outlined ? penDur(Math.PI * (rx + ry) * 1.06) : 0.3); }
      case 'rect': return plainTime(outlined ? penDur(2 * (Math.abs(+m.w || 0) + Math.abs(+m.h || 0))) : 0.3);
      case 'poly':
        // a marquee frame's tint opens with its outline, which starts at the same moment
        if (Array.isArray(m.marquee) && !outlined) return { dur: MARQUEE_DUR, adv: 0 };
        return plainTime(outlined ? penDur(strokeLength(Array.isArray(m.pts) && m.pts.length ? m.pts.concat([m.pts[0]]) : m.pts)) : 0.3);
      case 'path': return plainTime(penDur(pathLength(m.d)));
      case 'highlight': return plainTime(0.35);
      case 'molecule': return plainTime(0.6);
    }
    return plainTime(0.3);
  }
  // How long an edit op takes at pace 1, given the marks it touches (null: not known yet). The editor runs its ops at
  // these speeds: erasing runs each pen backwards in 0.4 s (staggered, capped), repainting redraws at 0.55 pace.
  const ERASE_DUR = 0.4, REPAINT_PACE = 0.55, GLIDE_DUR = 0.5, BRISK = { stagger: 0.03, spread: 0.3 };
  const eraseStagger = (n, brisk) => n > 1 ? Math.min(brisk ? BRISK.stagger : 0.05, (brisk ? BRISK.spread : 0.5) / (n - 1)) : 0;
  function editEstimate(op, touched) {
    const kind = op && op.op, n = touched ? touched.length : null;
    if (kind === 'turn') return 0;
    if (n === 0) return kind === 'startOver' ? 0.02 : 0.05;   // nothing to change: it takes no time in its beat
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
  // A labelled box that partly covers another labelled box (boxes piled on boxes) is moved, with what follows it in its
  // step, to the nearest free spot nearby; when there is none it is reported. Overlaps that mean something are kept:
  // one shape inside another (a face on a head, a box on a panel), edges that touch, a small badge on a big box,
  // shapes of different kinds. An opaque shape over part of an earlier step's labelled shape is reported too.
  const boxArea = b => Math.max(0, b[2] - b[0]) * Math.max(0, b[3] - b[1]);
  const boxOverlap = (a, b) => Math.max(0, Math.min(a[2], b[2]) - Math.max(a[0], b[0])) * Math.max(0, Math.min(a[3], b[3]) - Math.max(a[1], b[1]));
  const nearBox = (p, b, pad) => p[0] >= b[0] - pad && p[0] <= b[2] + pad && p[1] >= b[1] - pad && p[1] <= b[3] + pad;
  const boxOf = P => { let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity; for (const p of P) { x0 = Math.min(x0, p[0]); y0 = Math.min(y0, p[1]); x1 = Math.max(x1, p[0]); y1 = Math.max(y1, p[1]); } return [x0, y0, x1, y1]; };
  const SAMPLES = 14;                                     // overlap is measured on a 14 x 14 grid over the boxes' overlap
  const AROUND = [[0, 1], [1, 0], [-1, 0], [0, -1], [1, 1], [-1, 1], [1, -1], [-1, -1]];
  // A closed shape: its kind, box, area and an inside test. Lines, dots, text and shapes drawn under others have none.
  function shapeOf(m) {
    if (m.under) return null;
    const at = Array.isArray(m.at) ? m.at : null;
    const card = (x, y, w, h, kind) => ({ kind, b: [x, y, x + w, y + h], area: w * h, inside: (px, py) => px >= x && px <= x + w && py >= y && py <= y + h });
    if (m.do === 'rect' && at && isFinite(m.w) && isFinite(m.h)) {
      let [x, y] = at, w = +m.w, h = +m.h;
      if (w < 0) { x += w; w = -w; }
      if (h < 0) { y += h; h = -h; }
      return card(x, y, w, h, 'box');
    }
    if ((m.do === 'circle' || m.do === 'ellipse') && at) {
      const [cx, cy] = at;
      let rx = +(m.r || m.rx), ry = +(m.r || m.ry);
      if (!(rx > 0 && ry > 0)) return null;
      if (m.rot) rx = ry = Math.max(rx, ry);              // a turned ellipse: the circle it turns in
      return { kind: 'round', b: [cx - rx, cy - ry, cx + rx, cy + ry], area: Math.PI * rx * ry, inside: (px, py) => ((px - cx) / rx) ** 2 + ((py - cy) / ry) ** 2 <= 1 };
    }
    // a window is a card, like the paper sheet it replaced: words go inside it, and it is never moved
    if (m.do === 'window' && at && +m.w > 0 && +m.h > 0) return card(at[0], at[1], +m.w, +m.h, 'poly');
    if (m.do === 'poly' && Array.isArray(m.pts) && m.pts.length >= 3 && m.close !== false && m.pts.every(Array.isArray)) {
      const P = m.pts;
      let twice = 0;
      for (let i = 0; i < P.length; i++) { const p = P[i], q = P[(i + 1) % P.length]; twice += p[0] * q[1] - q[0] * p[1]; }
      const inside = (px, py) => {
        let c = false;
        for (let i = 0, j = P.length - 1; i < P.length; j = i++)
          if ((P[i][1] > py) !== (P[j][1] > py) && px < (P[j][0] - P[i][0]) * (py - P[i][1]) / ((P[j][1] - P[i][1]) || 1e-9) + P[i][0]) c = !c;
        return c;
      };
      return { kind: 'poly', b: boxOf(P), area: Math.abs(twice) / 2, inside };
    }
    return null;
  }
  // the points that place a mark: a stroke's own points, or a shape's corners
  function placePoints(m) {
    if (Array.isArray(m.pts)) return m.pts.filter(Array.isArray);
    if (!Array.isArray(m.at)) return [];
    switch (m.do) {
      case 'rect': case 'highlight': case 'molecule': case 'stage3d': case 'image': case 'window': return [m.at, [m.at[0] + (+m.w || 0), m.at[1] + (+m.h || 0)]];
      case 'circle': case 'ellipse': { const rx = +(m.r || m.rx) || 0, ry = +(m.r || m.ry) || 0; return [[m.at[0] - rx, m.at[1] - ry], [m.at[0] + rx, m.at[1] + ry]]; }
    }
    return [m.at];
  }
  // a mark moved by (dx, dy); with `only`, just the points it picks (a line keeps the end that is outside a moved box)
  function shiftMark(m, dx, dy, only) {
    const mv = p => !only || only(p) ? [p[0] + dx, p[1] + dy] : p;
    if (Array.isArray(m.at)) m.at = mv(m.at);
    if (Array.isArray(m.pts)) m.pts = m.pts.map(p => Array.isArray(p) ? mv(p) : p);
    if (m.do === 'path') m.shift = [(m.shift ? m.shift[0] : 0) + dx, (m.shift ? m.shift[1] : 0) + dy];
  }
  function Layout(W, H) {
    // containers (closed shapes big enough to hold words), text boxes, points along strokes [x, y, i] and the boxes of
    // other shapes: what is on the paper so far
    const cons = [], texts = [], ink = [], areas = [], warnings = [];
    let group = null, overlaps = 0, moved = 0, covered = 0, n = 0;   // group: the box just moved, whose step follows it
    // what an edit erased (or a new turn dropped) is no longer on the paper; startOver clears it all
    const prune = (list, gone) => { let k = 0; for (const x of list) if (!gone(x)) list[k++] = x; list.length = k; };
    function forget(indices) {
      const set = indices instanceof Set ? indices : new Set(indices || []);
      if (!set.size) return;
      const gone = x => set.has(x.i != null ? x.i : x[2]);
      prune(cons, gone); prune(texts, gone); prune(ink, gone); prune(areas, gone);
      if (group && set.has(group.i)) group = null;
    }
    function reset() { cons.length = texts.length = ink.length = areas.length = 0; group = null; }
    const isContainer = (m, s) => s && s.b[2] - s.b[0] >= 36 && s.b[3] - s.b[1] >= 22 && s.area < 0.4 * W * H && (m.outline !== false || (m.fill && (m.fillAlpha == null || m.fillAlpha >= 0.5)));
    const opaque = m => m.fill && m.fill !== 'none' && (m.fillAlpha == null || m.fillAlpha >= 0.7);
    // how much of shape a (moved by dx, dy) and shape b overlap, measured by sampling
    function overlap(a, b, dx = 0, dy = 0) {
      const x0 = Math.max(a.b[0] + dx, b.b[0]), y0 = Math.max(a.b[1] + dy, b.b[1]), x1 = Math.min(a.b[2] + dx, b.b[2]), y1 = Math.min(a.b[3] + dy, b.b[3]);
      if (x1 <= x0 || y1 <= y0) return 0;
      let hit = 0;
      for (let i = 0; i < SAMPLES; i++) for (let j = 0; j < SAMPLES; j++) {
        const px = x0 + (i + 0.5) * (x1 - x0) / SAMPLES, py = y0 + (j + 0.5) * (y1 - y0) / SAMPLES;
        if (a.inside(px - dx, py - dy) && b.inside(px, py)) hit++;
      }
      return hit / (SAMPLES * SAMPLES) * (x1 - x0) * (y1 - y0);
    }
    // an unintended partial overlap between two containers, given how much they overlap
    function clashes(a, b, shared) {
      if (!shared) return false;
      const small = Math.min(a.area, b.area), big = Math.max(a.area, b.area);
      if (shared >= 0.8 * a.area || shared >= 0.8 * b.area) return false;   // one sits inside the other on purpose
      if (shared < 0.1 * small) return false;                              // edges touching
      return a.kind === b.kind && a.kind !== 'poly' && small / big >= 0.2;  // not a badge on a box, ears on a head, a hill on the sea
    }
    function textBox(m) {
      const size = m.size || (m.style === 'title' ? 24 : m.style === 'body' ? 17 : 20), full = textW(m.text, size, m.style), w = m.fit ? Math.min(m.fit[0], full) : full;
      const x = m.at[0] - (m.anchor === 'middle' ? w / 2 : m.anchor === 'end' ? w : 0);
      return [x, m.at[1] - size * 0.8, x + w, m.at[1] + size * 0.25];
    }
    // where a container may land when moved by (dx, dy): on the paper, clear of other containers, strokes, shapes and words
    function free(c, dx, dy) {
      const b = [c.b[0] + dx, c.b[1] + dy, c.b[2] + dx, c.b[3] + dy];
      if (b[0] < 6 || b[1] < 6 || b[2] > W - 6 || b[3] > H - 6) return false;
      for (const o of cons) {
        const shared = overlap(c, o, dx, dy);
        if ((o.labelled && clashes(c, o, shared)) || (shared > 0.12 * c.area && shared < 0.8 * o.area)) return false;
      }
      if (ink.some(p => nearBox(p, b, 4))) return false;
      // another shape under it, unless it already sat on that shape and still does (a box on its panel)
      if (areas.some(a => a.i !== c.i && boxOverlap(a.b, b) > 0.08 * c.area && !(boxOverlap(a.b, b) >= 0.95 * c.area && boxOverlap(a.b, c.b) >= 0.95 * c.area))) return false;
      return !texts.some(t => boxOverlap(t, b) > 0.3 * boxArea(t));
    }
    // the nearest free spot within reach: rings of 8 directions every 8 units, and just past each side of the box hit
    function placeFor(c, hit) {
      const reach = 0.22 * Math.min(W, H), tries = [];
      for (let r = 8; r <= reach; r += 8) for (const [ux, uy] of AROUND) tries.push([ux * r, uy * r]);
      tries.push([hit.b[2] + 10 - c.b[0], 0], [hit.b[0] - 10 - c.b[2], 0], [0, hit.b[3] + 10 - c.b[1]], [0, hit.b[1] - 10 - c.b[3]]);
      return tries.filter(d => Math.hypot(d[0], d[1]) <= reach * 1.1).sort((p, q) => Math.hypot(p[0], p[1]) - Math.hypot(q[0], q[1])).find(d => free(c, d[0], d[1]));
    }
    // what a mark puts on the paper, for later boxes to stay clear of
    function occupy(m, i) {
      if ((m.do === 'line' || m.do === 'arrow') && Array.isArray(m.pts)) {
        const P = m.pts.filter(Array.isArray);
        for (let k = 0; k < P.length; k++) {
          ink.push([P[k][0], P[k][1], i]);
          if (!k) continue;                               // and every 8 units along each segment
          const [ax, ay] = P[k - 1], len = Math.hypot(P[k][0] - ax, P[k][1] - ay);
          for (let q = 1; q < len / 8; q++) ink.push([ax + (P[k][0] - ax) * q * 8 / len, ay + (P[k][1] - ay) * q * 8 / len, i]);
        }
      } else if (m.do === 'dot' && Array.isArray(m.at)) ink.push([m.at[0], m.at[1], i]);
      else if (m.do === 'path') {
        const [sx, sy] = m.shift || [0, 0];
        for (const run of pathRuns(m.d)) for (const p of run) ink.push([p[0] + sx, p[1] + sy, i]);
      } else if (m.do !== 'text') {
        const s = shapeOf(m), P = placePoints(m), b = s ? s.b : P.length === 2 ? boxOf(P) : null;
        if (b && boxArea(b) < 0.4 * W * H) areas.push({ b, i });
      }
    }
    function add(m, index) {
      const i = index != null ? index : n++;
      if (!m || typeof m !== 'object') return m;
      if (m.do === 'edit' || m.__dropped) return m;      // edits have no geometry; dropped marks are never drawn
      const sk = stepKey(m);
      // 1. what follows a moved box in its step and sits on it comes along (a line only by its ends on the box)
      if (group && sk !== group.step) group = null;
      if (group) {
        const s = shapeOf(m), P = placePoints(m), from = group.from, [dx, dy] = group.by;
        if (isContainer(m, s) && !(nearBox([s.b[0], s.b[1]], from, 3) && nearBox([s.b[2], s.b[3]], from, 3))) group = null;   // the step moved on to another box
        else if (P.length && (m.do === 'line' || m.do === 'arrow')) shiftMark(m, dx, dy, p => nearBox(p, from, 12));
        else if (P.length && P.every(p => nearBox(p, from, 3))) shiftMark(m, dx, dy);
      }
      occupy(m, i);
      // 2. a text labels the most recent container it sits in
      if (m.do === 'text' && Array.isArray(m.at) && m.text != null) {
        const b = textBox(m), cx = (b[0] + b[2]) / 2, cy = (b[1] + b[3]) / 2;
        b.i = i; texts.push(b);
        for (let k = cons.length - 1; k >= 0; k--) if (cons[k].inside(cx, cy)) { cons[k].labelled = true; if (!cons[k].label) cons[k].label = String(m.text).slice(0, 24); break; }
        return m;
      }
      // 3. a new container, checked against the labelled ones drawn before it
      const s = shapeOf(m);
      if (!isContainer(m, s)) return m;
      const c = Object.assign(s, { i, step: m.step, sk, labelled: false, label: '', opaque: opaque(m) });
      const hit = cons.find(o => o.labelled && clashes(c, o, overlap(c, o)));
      if (hit) {
        const by = placeFor(c, hit);
        if (by) {
          const from = c.b.slice(), inside = c.inside;
          shiftMark(m, by[0], by[1]);
          c.b = [c.b[0] + by[0], c.b[1] + by[1], c.b[2] + by[0], c.b[3] + by[1]];
          c.inside = (px, py) => inside(px - by[0], py - by[1]);
          group = { from, by, step: sk, i }; moved++;
          warnings.push(`moved a box ${Math.round(by[0])},${Math.round(by[1])} so it no longer covers the box "${hit.label}"`);
        } else { overlaps++; warnings.push(`the box at ${Math.round(c.b[0])},${Math.round(c.b[1])} overlaps the box "${hit.label}"`); }
      } else if (c.opaque) {
        const under = cons.find(o => { if (!o.labelled || o.sk === c.sk) return false; const shared = overlap(c, o); return shared > 0.2 * o.area && shared < 0.8 * o.area && shared < 0.8 * c.area; });
        if (under) { covered++; warnings.push(`a shape in step ${c.step} covers part of the labelled shape "${under.label}" from step ${under.step}`); }
      }
      cons.push(c);
      return m;
    }
    return { add, forget, reset, warnings, get overlaps() { return overlaps; }, get moved() { return moved; }, get covered() { return covered; } };
  }
  // The layout check over a whole run of marks. plan(m, i) (optional): for an edit mark, {reset} (startOver) or
  // {forget: [the indices of the marks it erases]}.
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
  // Each say() line owns the strokes after it, up to the next say(). Strokes of a step that come before the step's
  // first say() belong to that say(); a step with no say() joins the line before it. A line's strokes wait until the
  // line is heard, then spread over its spoken time. Line times are estimated (words / wps, lines back to back) or told
  // by the host (lineStart, lineEnd, spoken).
  function Pacer(o) {
    o = o || {};
    const opt = (k, fallback) => o[k] != null ? o[k] : fallback;
    const wps = o.wps || 2.6, gap = opt('gap', 0.25), estimated = o.speech !== 'external', lead = opt('lead', 0.08), tail = opt('tail', 0.12);
    // how far a line may speed its strokes up (FAST) or slow them down (SLOW) to fit its words
    const FAST = opt('minPace', 0.35), SLOW = opt('maxSlow', 2);
    // how far a line with too much to draw for its time (or one that starts late) may hurry, so its marks still end
    // with its words; without it a crowded line stays at FAST and runs on into the next
    const RUSH = o.rushPace != null ? Math.min(o.rushPace, FAST) : FAST;
    // how far the gaps between strokes may stretch to fill a line. Capped, an object's parts (a sticky's paper and
    // words, a badge's ring and number) stay together, and spare time is a rest at the end of the line instead
    const MAXSPREAD = opt('maxSpread', Infinity);
    const OPEN_MAX = 1.3;                                 // a line still open may get more strokes: it spreads no further
    const RUSHED = { pace: 0.35, gap: 0.12 };             // finishNow: everything left, quickly and in order
    const lines = [], items = [];
    let closedUpTo = -1, allClosed = false, released = 0, rushing = false;
    const wordCount = s => String(s).trim().split(/\s+/).filter(Boolean).length;
    function addLine(text, t) {
      const prev = lines[lines.length - 1];
      lines.push({ k: lines.length, text, words: wordCount(text), arrive: t, start: null, end: null, cum: prev ? prev.cum + prev.words : 0 });
      return lines.length - 1;
    }
    // it.t: when it is planned to start; p: its pace; rt: when it was released; line: the line it belongs to (-1: before any)
    function add(m, i, t, nat) { const it = { m, i, arrive: t, line: undefined, dur: nat.dur, adv: nat.adv, t: null, p: 1, rt: null }; items.push(it); return it; }
    // A line's [start, end] in seconds, or null while it is not known. A start the host told wins; otherwise (when
    // estimating) a line starts when the one before ends plus the gap, but not before it arrived, and lasts its words.
    // known: the lines before it, worked out in order (once per plan, so a long talk needs no deep recursion).
    function timesOf(k, known) {
      for (let j = known.length; j <= k; j++) {
        const L = lines[j];
        let span = null;
        if (L) {
          let s = L.start;
          if (s == null && estimated && (!j || known[j - 1])) s = j ? Math.max(L.arrive, known[j - 1][1] + gap) : L.arrive;
          if (s != null) span = [s, Math.max(L.end != null ? L.end : s + L.words / wps, s + 0.2)];
        }
        known.push(span);
      }
      return known[k];
    }
    // When each stroke not released yet starts, and at what pace. Strokes go in order; a line's strokes start once it
    // is heard (and after the strokes before them) and spread so the last one ends as the line does.
    function plan(now) {
      if (rushing) {
        let t = now;
        for (let q = released; q < items.length; q++) { const it = items[q]; it.t = t; it.p = RUSHED.pace; it.gap = it.adv * RUSHED.gap; t += it.gap; }
        return;
      }
      const known = [], last = released ? items[released - 1] : null;
      let cursor = last ? Math.max(now, last.rt + last.gap) : now, q = released;
      while (q < items.length) {
        const k = items[q].line;
        if (k === undefined) break;                       // still waiting for its say(): it and everything after it wait
        let end = q;
        while (end < items.length && items[end].line === k) end++;
        const group = items.slice(q, end);
        q = end;
        if (k < 0) { for (const it of group) { it.t = cursor; it.p = 1; it.gap = it.adv; cursor += it.adv; } continue; }   // before any line: their own pace
        const T = timesOf(k, known);
        if (!T) { q -= group.length; break; }
        const from = Math.max(cursor, T[0] + lead), room = T[1] - tail - from, closed = allClosed || k <= closedUpTo;
        let gaps = 0;
        for (let g = 0; g < group.length - 1; g++) gaps += group[g].adv;
        const lastDur = group[group.length - 1].dur;
        // f: how much the line's time is to its strokes' own; gaps grow by `spread`, strokes slow by at most SLOW
        let f = room <= 0.05 ? 0 : room / (gaps + lastDur || 0.1);
        if (!closed) f = Math.min(f, OPEN_MAX);
        let pace, spread;
        // too much for its time, or the line before ran over: strokes and gaps shrink together (down to RUSH), so this
        // line's marks end with its words and never push the next line's back
        if (f < FAST) pace = spread = Math.max(RUSH, f);
        else {
          pace = Math.min(f, SLOW); spread = f;
          if (closed && f > SLOW && gaps > 0) spread = Math.max(SLOW, (room - SLOW * lastDur) / gaps);
        }
        spread = Math.min(spread, MAXSPREAD);
        let t = from;
        for (const it of group) { it.t = t; it.p = pace; it.gap = it.adv * spread; t += it.gap; }
        cursor = t;
      }
      for (; q < items.length; q++) items[q].t = null;
    }
    // The strokes due by `now`, released in order. Each release replans what follows: a stroke released late moves
    // the rest along with it.
    function due(now) {
      const out = [];
      for (;;) {
        plan(now);
        const it = items[released];
        if (!it || it.t == null || it.t > now + 0.004) return out;
        it.rt = now; released++; out.push(it);
      }
    }
    const told = k => lines[k];
    return {
      lines, items, addLine, add, due,
      assign: (it, k) => { it.line = k; },
      close: k => { closedUpTo = Math.max(closedUpTo, k); }, closeAll: () => { allClosed = true; },
      rush: () => { rushing = true; }, get rushed() { return rushing; },
      start: (k, t) => { const L = told(k); if (L && L.start == null) L.start = t; },
      end: (k, t) => { const L = told(k); if (L) { if (L.start == null) L.start = t; L.end = t; } },
      nextAt: now => { plan(now); const it = items[released]; return it && it.t != null ? it.t : null; },
      empty: () => released >= items.length, times: k => timesOf(k, []),
      // a new turn on the same card: strokes not released yet whose mark gone(i) picks are dropped (returned)
      drop: gone => { const out = []; for (let q = items.length - 1; q >= released; q--) if (gone(items[q].i)) out.push(items.splice(q, 1)[0]); return out; },
      // more lines and strokes after the program was done
      reopen: () => { allClosed = false; rushing = false; }
    };
  }

  // ================================================================ stream: runner + layout + pacer; calls onDraw when marks should be drawn (DOM-free)
  const isTurnMark = m => !!m && m.do === 'edit' && !!m.op && m.op.op === 'turn';
  function Stream(spec, o) {
    o = o || {};
    const scanStatements = RUNNER.statementScanner();
    const W = spec.w || 400, H = spec.h || 300;
    const clk = o.clock || { now: () => performance.now() / 1000, set: (f, s) => setTimeout(f, s * 1000), clear: id => clearTimeout(id) };
    const t0 = clk.now(), now = () => clk.now() - t0;
    const paced = !!o.pace && o.pace !== 'off';
    const P = paced ? Pacer({ wps: o.wps, gap: o.gap != null ? o.gap : (o.continuous ? 0 : 0.25), speech: o.speech || 'estimate', lead: o.lead, tail: o.tail, minPace: o.minPace, maxSlow: o.maxSlow, maxSpread: o.maxSpread, rushPace: o.rushPace }) : null;
    const lay = o.layout === false ? null : Layout(W, H);
    const report = { errors: [], warnings: [] }, lines = [], log = { marks: [], lines: [], paced, mode: null };
    // all: every mark that has arrived (drawn, or waiting for its line); released: those handed to the painter
    const all = [], released = new Set();
    let nMarks = 0, src = '', sent = -1, doneSeen = false, finished = false, paused = false, timer = null;
    let held = [], fresh = [], layoutReported = 0;      // held: draws made while paused; fresh: say() lines not handed out yet
    const drawNow = (ms, d) => { if (paused && !(d && d.paced)) { held.push([ms, d]); return; } if (o.onDraw) o.onDraw(ms, d); };

    // Which say() line owns each mark, by the pacer's rule, for the log (paced or not). own: the step being read, its
    // line so far, the last line of all, and the marks of the step still waiting for its first say().
    const own = { step: null, line: null, last: -1, waiting: [] };
    const ownClose = () => { for (const e of own.waiting) e.line = own.last; own.waiting = []; };
    const ownStep = m => { if (stepKey(m) !== own.step) { ownClose(); own.step = stepKey(m); own.line = null; } };
    const ownSay = (s, k) => { if (stepKey(s) !== own.step) { ownClose(); own.step = stepKey(s); } for (const e of own.waiting) e.line = k; own.waiting = []; own.line = own.last = k; };
    const ownMark = (e, m) => { ownStep(m); if (own.line != null) e.line = own.line; else own.waiting.push(e); };
    // the same for the pacer's own items: the step's line, the last line, and items of the step waiting for a say()
    const pace = { step: null, line: null, last: -1, waiting: [] };
    function closeStep() { for (const it of pace.waiting) P.assign(it, pace.last); pace.waiting = []; }
    const paceStep = m => { if (stepKey(m) !== pace.step) { closeStep(); pace.step = stepKey(m); pace.line = null; } };

    function handleSay(s, t) {
      lines.push(s.text); fresh.push(s.text);
      const k = lines.length - 1;
      log.lines.push(s.turn ? { k, text: s.text, arrive: t, step: s.step, turn: s.turn } : { k, text: s.text, arrive: t, step: s.step });
      ownSay(s, k);
      if (!paced) return;
      if (stepKey(s) !== pace.step) { closeStep(); pace.step = stepKey(s); }
      P.addLine(s.text, t); P.close(k - 1);
      for (const it of pace.waiting) P.assign(it, k);
      pace.waiting = [];
      pace.line = pace.last = k;
    }
    // Marks in [keep, upto) never drawn leave for good: never drawn later, and gone from the layout and the pacer.
    function dropRange(keep, upto) {
      const gone = [];
      for (let i = Math.max(0, keep); i < upto; i++) {
        const m = all[i];
        if (!m || released.has(i) || isTurnMark(m)) continue;
        m.__skip = m.__erased = m.__dropped = true; gone.push(i);
      }
      if (gone.length) forgetMarks(new Set(gone), true);
      return gone;
    }
    function forgetMarks(set, dropped) {
      if (P) P.drop(i => set.has(i));
      pace.waiting = pace.waiting.filter(it => !set.has(it.i));
      if (lay) lay.forget(set);
      if (dropped) for (const e of log.marks) if (set.has(e.i)) e.dropped = true;
    }
    // __turn(n, keep): a new turn on the same card starts here
    function handleTurn(m, gi, t, batch) {
      if (m.op.keep != null) dropRange(m.op.keep, gi);
      ownClose(); own.step = stepKey(m); own.line = null;
      if (paced) { closeStep(); pace.step = stepKey(m); pace.line = null; }
      released.add(gi); all[gi] = m;
      log.marks.push({ i: gi, arrive: t, do: 'edit', op: 'turn', step: m.step, dur: 0, adv: 0, rt: t });
      if (!paced) batch.push(m);                          // painted as nothing, so unpaced batches keep their indices
    }
    function handleMark(m, gi, t, batch) {
      if (isTurnMark(m)) { handleTurn(m, gi, t, batch); return; }
      if (m.do === 'edit') {
        // an edit has no geometry; what it erases leaves the layout (startOver: everything)
        const plan = o.planEdit ? o.planEdit(m, gi) : null;
        if (plan && lay) { if (plan.reset) lay.reset(); else if (plan.forget) lay.forget(plan.forget); }
      } else if (lay) m = lay.add(m, gi);
      let nat = natural(m);
      // one ink stroke at a time (fills and dots still land together)
      if (o.sequential && m.outline !== false && m.do !== 'dot') nat = { dur: nat.dur, adv: Math.max(nat.adv, nat.dur + 0.03) };
      const entry = { i: gi, arrive: t, do: m.do, step: m.step, dur: nat.dur, adv: nat.adv, rt: paced ? null : t };
      log.marks.push(entry); ownMark(entry, m); all[gi] = m;
      if (!paced) { released.add(gi); batch.push(m); return; }
      paceStep(m);
      const it = P.add(m, gi, t, nat);
      if (pace.line != null) P.assign(it, pace.line); else pace.waiting.push(it);
    }
    // a run's new marks and says, in the order the program made them
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
      if (finished) return;
      finished = true;
      if (lay) {
        // only the layout's new warnings: a continued turn finishes again, and used to report the earlier ones twice
        for (const w of lay.warnings.slice(layoutReported)) report.warnings.push(w);
        layoutReported = lay.warnings.length;
        report.shapeOverlaps = lay.overlaps; report.nudged = lay.moved; report.covered = lay.covered;
      }
      if (paced) {
        for (const L of log.lines) { const T = P.times(L.k); if (T) { L.start = T[0]; L.end = T[1]; } }
        const entries = new Map(log.marks.map(e => [e.i, e]));
        for (const it of P.items) { const e = entries.get(it.i); if (e) { e.rt = it.rt; e.p = it.p; e.line = it.line; } }
      }
      if (runner && runner.stop && o.sandbox === 'worker') runner.stop();
      if (o.onDone) o.onDone(report, log);
    }
    function tick() {
      timer = null;
      if (finished || paused) return;
      const t = now();
      for (const it of P.due(t)) { released.add(it.i); drawNow([it.m], { paced: true, pace: it.p, i: it.i }); }
      const next = P.nextAt(t);
      if (next != null) timer = clk.set(tick, Math.max(0.001, next - t));
      else if (doneSeen && P.empty()) finishUp();
    }
    function kick() { if (timer != null) clk.clear(timer); timer = null; tick(); }
    let runner = o.sandbox === 'worker' && typeof Worker !== 'undefined' ? WorkerRunner(W, H, o, (r, done) => ingest(r, !!done)) : null;
    const sandboxed = !!runner;
    const syncRunner = S => ({ run: (code, done, knownEnds) => ingest(S.update(code, done, knownEnds), done), sync: true, get code() { return S.code; }, get mode() { return S.mode; }, get live3d() { return S.live3d; } });
    if (!runner) runner = syncRunner(RUNNER.Session(W, H, { incremental: o.incremental }));
    const stopTimer = () => { if (timer != null) clk.clear(timer); timer = null; };
    return {
      // code: everything received so far. Returns the new say() lines (sandboxed runs deliver them through onSay instead).
      update(code, done = false) {
        if (doneSeen) return [];
        const ends = scanStatements(code), upto = done ? code.length : (ends.length ? ends[ends.length - 1] : 0);
        if (upto <= sent && !done) return [];
        sent = upto; src = code.slice(0, upto);
        const r = runner.run(src, done, ends);           // the boundaries are found once, here, and handed on
        return runner.sync ? r : [];
      },
      // the host tells the engine when a line is actually heard (seconds since live() started; default: now)
      lineStart(k, t) { if (P) { P.start(k, t != null ? t : now()); kick(); } },
      lineEnd(k, t) { if (P) { P.end(k, t != null ? t : now()); kick(); } },
      // continuous speech: n words of the joined narration have been heard so far
      spoken(n, t) {
        if (!P) return;
        const at = t != null ? t : now();
        for (const L of P.lines) { if (L.start == null && n > L.cum) P.start(L.k, at); if (L.end == null && n >= L.cum + L.words) P.end(L.k, at); }
        kick();
      },
      stop() { stopTimer(); finished = true; if (runner.stop) runner.stop(); },
      // draw every stroke still waiting for its line now, quickly and in order; strokes that stream in later are drawn on
      // arrival. The host's voice carries on; lineStart/lineEnd are still recorded. No effect when unpaced or finished.
      finishNow() { if (!P || finished) return; P.rush(); kick(); },
      get rushed() { return !!(P && P.rushed); },
      // hold the pen after the stroke it is drawing (code keeps arriving and waits); resume() carries on
      pause() { if (paused || finished) return; paused = true; stopTimer(); },
      resume() {
        if (!paused) return;
        paused = false;
        const q = held; held = [];
        for (const [ms, d] of q) if (o.onDraw) o.onDraw(ms, d);
        if (paced) kick(); else if (doneSeen) finishUp();
      },
      get paused() { return paused; }, get finished() { return finished; }, get done() { return doneSeen; },
      marks: all, get code() { return src; },
      report, log, lines, sandboxed, now,
      // for a continued turn on the same card:
      // the program the runner has actually run (complete statements; src can be ahead of it while a statement waits to parse)
      get ran() { return runner.code != null ? runner.code : src; }, get runMode() { return runner.mode || null; },
      // the live run's figure() tick functions and poses (null in the worker sandbox)
      get live3d() { return runner.live3d || null; },
      get count() { return nMarks; }, isReleased: i => released.has(i),
      // drop every mark not drawn yet (the user interrupted); returns the first dropped index (nMarks when none)
      dropPending() {
        let keep = nMarks;
        for (let i = 0; i < nMarks; i++) if (all[i] && !released.has(i) && !isTurnMark(all[i])) { keep = i; break; }
        dropRange(keep, nMarks); held = [];
        return keep;
      },
      // take more code after the program was done
      reopen(code) { if (code != null && !sandboxed) { src = code; sent = code.length; } doneSeen = false; finished = false; if (P) P.reopen(); },
      // start the runner again on `code` (its first `count` marks are the ones already here), after the old run failed.
      // The marks after them leave everything: the layout (later boxes used to steer around shapes no longer on the
      // card), the pacer and the log (their indices are about to be reused).
      rebase(code, count) {
        if (sandboxed) return false;
        const S = RUNNER.Session(W, H, { incremental: o.incremental });
        S.update(code, false);
        runner = syncRunner(S); src = code; sent = code.length;
        const cut = new Set();
        for (let i = count; i < all.length; i++) { released.delete(i); cut.add(i); }
        if (cut.size) forgetMarks(cut, false);
        for (let k = log.marks.length - 1; k >= 0; k--) if (cut.has(log.marks[k].i)) log.marks.splice(k, 1);
        all.length = Math.min(all.length, count); nMarks = count;
        return true;
      }
    };
  }

  // ================================================================ render
  let SURFACES = 0;
  // label nudges: down, up, right, left, then the diagonals
  const AROUND_LABEL = [[0, 1], [0, -1], [1, 0], [-1, 0], [1, 1], [-1, 1], [1, -1], [-1, -1]];
  function surfaceFor(spec, host, opts = {}) {
    const uid = 'cd' + (++SURFACES) + '_';            // ids unique per card, so several cards can share a page
    const W = spec.w || 400, H = spec.h || 300, surface = spec.surface || 'card', t0 = performance.now();
    const defInk = surface === 'sky' ? 'white' : 'ink';
    const NS = 'http://www.w3.org/2000/svg';
    const svg = document.createElementNS(NS, 'svg');
    svg.setAttribute('viewBox', `0 0 ${W} ${H}`); svg.setAttribute('width', opts.width || W * 2); svg.setAttribute('height', (opts.width || W * 2) * H / W);
    // wash: a watercolour edge for fills; grain: pencil tooth. Then the layers, bottom to top: a hidden probe for
    // measuring, fills under everything, strokes, highlights, words.
    svg.innerHTML = `<defs><filter id="wash" x="-10%" y="-10%" width="120%" height="120%"><feTurbulence type="fractalNoise" baseFrequency="0.035" numOctaves="2" seed="3"/><feDisplacementMap in="SourceGraphic" scale="3.5"/></filter>
      <filter id="grain"><feTurbulence type="fractalNoise" baseFrequency="0.9" numOctaves="1" seed="7" result="n"/><feColorMatrix in="n" type="matrix" values="0 0 0 0 0  0 0 0 0 0  0 0 0 0 0  0 0 0 -1.2 1.1" result="a"/><feComposite in="SourceGraphic" in2="a" operator="in"/></filter></defs>
      <g id="__probe" style="visibility:hidden"></g><g id="under"></g><g id="main"></g><g id="hl"></g><g id="words"></g>`;
    host.appendChild(svg);
    const defs = svg.querySelector('defs'), under = svg.querySelector('#under'), main = svg.querySelector('#main'), hlLayer = svg.querySelector('#hl'), words = svg.querySelector('#words');
    let clock = 0.15, lastStep = null, maskCount = 0, delayBase = 0, pace = 1, total = 0, report = { marks: 0, errors: [], warnings: [], engine: VERSION };
    const placed = [];                                     // placed[i] = [start, end] of mark i, seconds since the card was created
    // What each mark drew (per layer, in paint order), its pen masks and the mark itself, so edits find them again.
    // Only references are kept: the SVG is exactly what a card without edits draws.
    const NODES = {}, MASKS = {}, MK = {};
    let cap = null, capM = null, capKey = 0, editing = false;
    // hooks.edit(m, i, startsAt, pace) runs a program's edit mark ({do: 'edit'}) through the card's editor and returns
    // how long it takes (s); live() and render() set it
    const hooks = {};
    // the role of the mark being painted, kept on each element it makes (label placement ignores the arrows that tie a
    // row to its photo: they cross the card, and the card's words must not move for them)
    let paintingRole = null;
    const LAYERS = new Set([main, under, hlLayer, words]);
    const el = (tag, attrs, parent) => {
      const e = document.createElementNS(NS, tag);
      for (const k in attrs) if (attrs[k] != null) e.setAttribute(k, attrs[k]);
      if (paintingRole) e.__role = paintingRole;
      const p = parent || main;
      p.appendChild(e);
      if (cap && LAYERS.has(p)) { e.__k = capKey; cap.push(e); }
      return e;
    };
    // a CSS animation at the card's pace: dur seconds, starting at `delay` on the card's clock
    const anim = (e, name, dur, delay) => {
      const curve = name === 'pen' ? (PEN.ease || 'cubic-bezier(.4,.1,.3,1)') : 'ease-out';
      e.style.animation = `${name} ${(dur * Math.max(pace, 0.35)).toFixed(2)}s ${curve} ${(delay - delayBase).toFixed(2)}s both`;
    };

    // A pen stroke along a centreline: the felt-pen outline, revealed by a mask whose own stroke is drawn on over the
    // pen's time. Returns that time.
    function stroke(centre, m, colour, size, parent, extra = {}) {
      const d = outline(centre, size, m.taper == null ? 1 : m.taper);
      if (!d) return 0;
      const id = uid + 'm' + (maskCount++), dur = penDur(plen(centre));
      const mask = el('mask', { id, maskUnits: 'userSpaceOnUse', x: -W, y: -H, width: W * 3, height: H * 3 }, defs);
      const reveal = el('path', { d: poly(centre), fill: 'none', stroke: '#fff', 'stroke-width': size * 2 + 4, 'stroke-linecap': 'round', 'stroke-linejoin': 'round', pathLength: 1, 'stroke-dasharray': '1 1' }, mask);
      anim(reveal, 'pen', dur, clock);
      if (capM) capM.push(reveal);
      const brush = BRUSH[m.brush] || BRUSH.pen;
      // The pen's halo for this ink (PEN.halo: one [colour, opacity, width] or several, widest first): a soft edge
      // without a blur. Otherwise a mark's own glow, [opacity, radius], which the app paints as a real shadow in the
      // mark's colour (data-glow).
      const halo = PEN.halo && PEN.halo[String(colour).toUpperCase()];
      const glow = !halo && Array.isArray(m.glow) && m.glow.length === 2 && isFinite(+m.glow[0]) && isFinite(+m.glow[1]) ? m.glow : null;
      for (const h of !halo ? [] : Array.isArray(halo[0]) ? halo : [halo])
        el('path', { d, fill: h[0], 'fill-opacity': h[1], stroke: h[0], 'stroke-opacity': h[1], 'stroke-width': h[2], 'stroke-linejoin': 'round', mask: `url(#${id})`, 'data-halo': '1' }, parent);
      el('path', Object.assign({ d, fill: colour, 'fill-opacity': m.alpha != null ? m.alpha : brush.alpha, mask: `url(#${id})`, filter: m.brush === 'pencil' ? 'url(#grain)' : null,
        'data-glow': glow ? `${(+glow[0]).toFixed(3)} ${(+glow[1]).toFixed(2)}` : null }, extra), parent);
      return dur;
    }
    // a fill's rough area, for PEN.washMaxArea (big sheets skip the watercolour filter: it is costly to animate)
    function fillArea(m) {
      if (Array.isArray(m.pts) && m.pts.length) {
        const P = m.pts.filter(Array.isArray).map(p => [+p[0] || 0, +p[1] || 0]);
        if (!P.length) return 0;
        const b = boxOf(P);
        return (b[2] - b[0]) * (b[3] - b[1]);
      }
      if (m.w && m.h) return Math.abs(m.w * m.h);
      if (m.r) return 4 * m.r * m.r;
      if (m.rx && m.ry) return 4 * m.rx * m.ry;
      return 0;
    }
    // A shape's fill, fading in under its outline (or opening with it, for a marquee's tint). `wash: false` keeps a
    // fill crisp (label pills, number badges).
    function wash(dPath, m, parent, extra) {
      if (!m.fill) return;
      const marquee = Array.isArray(m.marquee) && m.outline === false;
      const washed = PEN.wash && m.wash !== false && !marquee && fillArea(m) <= PEN.washMaxArea;
      const e = el('path', Object.assign({ d: dPath, fill: tone(m.fill), 'fill-opacity': m.fillAlpha != null ? m.fillAlpha : 1, filter: washed ? 'url(#wash)' : null,
        'data-marquee': marquee ? m.marquee.map(v => (+v || 0).toFixed(2)).join(' ') : null }, extra || {}), parent || under);
      if (marquee) anim(e, 'marquee', MARQUEE_DUR, clock);
      else anim(e, 'fadein', 0.35, clock + (m.outline === false ? 0 : 0.18));
    }

    // ---------------------------------------------------------------- labels keep clear of each other and of shapes
    // an element's box on the card, with any nudge and edit move; a shape's box is kept once it has one (the app
    // measures paths)
    function cardBox(e, cache) {
      let r;
      if (cache) {
        if (!e.__bb) { try { const q = e.getBBox(); e.__bb = q && (q.width || q.height) ? { x: q.x, y: q.y, w: q.width, h: q.height } : null; } catch (_) { e.__bb = null; } }
        r = e.__bb;
      } else { try { const q = e.getBBox(), n = e.__nudge || [0, 0]; r = { x: q.x + n[0], y: q.y + n[1], w: q.width, h: q.height }; } catch (_) { r = null; } }
      const xf = r && e.__wrap && e.__wrap.__xf;
      return xf ? { x: r.x * xf[0] + xf[1], y: r.y * xf[0] + xf[2], w: r.w * xf[0], h: r.h * xf[0] } : r;
    }
    // how far to shift a span [start, start + size] to bring it within [lo, hi] (a span too big for it keeps to lo)
    const intoRange = (start, size, lo, hi) => Math.min(Math.max(0, lo - start), hi - start - size) || Math.max(lo - start, Math.min(0, hi - start - size));
    // Moves a short label to the nearest spot where it neither sits on another label nor is crossed by shapes.
    function placeLabel(t) {
      let b;
      try { b = t.getBBox(); } catch (_) { return; }
      if (!b.width) return;
      const live = e => e.ownerSVGElement === svg && !e.__gone;
      const others = [...words.querySelectorAll('text')].filter(e => e !== t && live(e)).map(e => cardBox(e, false)).filter(Boolean);
      // Labels are compared by their letters' middle bands: a text box carries its whole line height, so a title and
      // the subtitle 22 units under it "overlapped" by a few units with no letter touching, and a list cascaded down.
      const textHits = (dx, dy) => others.some(o => Math.min(b.x + dx + b.width, o.x + o.w) - Math.max(b.x + dx, o.x) > 3
        && Math.min(b.y + dy + b.height * 0.8, o.y + o.h * 0.8) - Math.max(b.y + dy + b.height * 0.2, o.y + o.h * 0.2) > 1);
      // Drawn shapes are in the way too (a caption written across two little figures). A shape around the label is its
      // container ("User" in its circle) and never pushes it; shapes that cross it do, once together they cover a fifth
      // of its middle band. Halos, ties to a photo and paper cards are not in the way.
      const shapes = [...main.querySelectorAll('path,circle,ellipse,rect,line,polyline,polygon')]
        .filter(e => live(e) && !e.getAttribute('data-halo') && e.__role !== 'tie' && e.__role !== 'paper').map(e => cardBox(e, true)).filter(Boolean);
      const shapeCover = (dx, dy) => {
        const x0 = b.x + dx + b.width * 0.1, y0 = b.y + dy + b.height * 0.25, x1 = b.x + dx + b.width * 0.9, y1 = b.y + dy + b.height * 0.75;
        let area = 0;
        for (const o of shapes) {
          if (o.x <= x0 + 2 && o.y <= y0 + 2 && o.x + o.w >= x1 - 2 && o.y + o.h >= y1 - 2) continue;   // its container
          // a pen line is a couple of pixels thin but crosses the words all the same: padded to a legible band
          const pad = 4, ix = Math.min(x1, o.x + o.w + pad) - Math.max(x0, o.x - pad), iy = Math.min(y1, o.y + o.h + pad) - Math.max(y0, o.y - pad);
          if (ix > 2 && iy > 2) area += ix * iy;
        }
        return area / Math.max(1, (x1 - x0) * (y1 - y0));
      };
      const hits = (dx, dy) => textHits(dx, dy) || shapeCover(dx, dy) > 0.2;
      const inside = (dx, dy) => b.x + dx >= 4 && b.y + dy >= 4 && b.x + dx + b.width <= W - 4 && b.y + dy + b.height <= H - 4;
      let best = inside(0, 0) ? [0, 0] : [intoRange(b.x, b.width, 4, W - 4), intoRange(b.y, b.height, 4, H - 4)];
      // only short labels dodge: a paragraph or a list stays where it was written (shoving a 13-line ingredient list
      // sideways to clear its own card's title put it off the card)
      if (!t.querySelector('tspan') && hits(best[0], best[1])) {
        const rowStep = Math.max(10, b.height * 0.9), colStep = b.width * 0.35 + 6, tries = [];
        for (let k = 1; k <= 5; k++) for (const [ux, uy] of AROUND_LABEL) tries.push([best[0] + ux * k * colStep, best[1] + uy * k * rowStep]);
        // nearest first, a step up or down counting more than one aside
        const far = p => Math.hypot(p[0] - best[0], (p[1] - best[1]) * 1.6);
        tries.sort((p, q) => far(p) - far(q));
        const free = tries.find(([dx, dy]) => inside(dx, dy) && !hits(dx, dy));
        if (free) { best = free; report.warnings.push(`moved label "${t.textContent.slice(0, 20)}" off another label or shape`); }
      }
      if (best[0] || best[1]) { t.__nudge = best; t.setAttribute('transform', `translate(${best[0].toFixed(1)} ${best[1].toFixed(1)}) ` + (t.getAttribute('transform') || '')); }
    }
    // a mark's rough time, for fitting a step into its budget when render() draws a whole program
    const ZERO_TIME = { motion3d: 1, camera3d: 1, tick3d: 1 };
    const est = m => m.do === 'dot' ? 0.05 : m.do === 'text' || m.do === 'label3d' ? 0.3 + String(m.text).length * 0.01 : m.do === 'molecule' ? 0.6
      : m.do === 'part3d' || m.do === 'stage3d' ? 0.12 : ZERO_TIME[m.do] ? 0 : m.do === 'edit' ? (m.__est != null ? m.__est : 0.3) : 0.3;
    const BUDGET = spec.stepBudget || 2.6;
    // ---------------------------------------------------------------- ink that stays readable on what is under it
    // Ink that would vanish into what is under it (a blue cursor colour on a blue sky) is drawn lighter or darker
    // there. "Under it" is the last filled shape or card drawn beneath the mark when there is one (a paper card, a
    // pill, a cat's face), else the screen itself (the host's __lumFor).
    // grounds: [x0, y0, x1, y1, luma, colour (cards only), order, window mark (windows only)]
    // surfaces: every filled shape, [x0, y0, x1, y1, colour, alpha, order], for the colour actually under words
    const grounds = [], surfaces = [];
    let drawOrder = 0;
    const rgbOf = c => { const h = /^#?([0-9a-f]{6})$/i.exec(String(c == null ? '' : c).trim()); if (!h) return null; const v = parseInt(h[1], 16); return [v >> 16 & 255, v >> 8 & 255, v & 255]; };
    const hexOf = c => String(TONES[c] || c || '');
    const lumaOf = c => { const p = rgbOf(hexOf(c)); return p ? (0.2126 * p[0] + 0.7152 * p[1] + 0.0722 * p[2]) / 255 : null; };
    const isChromatic = hex => { const p = rgbOf(hex); return !!p && Math.max(...p) - Math.min(...p) > 40; };
    const mixHex = (a, b, k) => { const p = rgbOf(a), q = rgbOf(b); if (!p || !q) return a; return '#' + p.map((v, j) => Math.round(v * (1 - k) + q[j] * k).toString(16).padStart(2, '0')).join(''); };
    const NO_INK_CHECK = { image: 1, window: 1, stage3d: 1, part3d: 1, label3d: 1, highlight: 1, molecule: 1, edit: 1, motion3d: 1, camera3d: 1, tick3d: 1 };
    const FILLABLE = { poly: 1, rect: 1, circle: 1, ellipse: 1, path: 1 };
    // The brightness the ink is seen against: a strip around the mark's box, not its inside. Inside a ring is the
    // thing ringed (a dark swatch made its ring white on a white page), and a thin line's own box is the line it sits
    // on (a ray on a black axis turned white and vanished).
    function bandLuma(b) {
      if (typeof global.__lumFor !== 'function') return -1;
      const pad = 8, w = Math.max(1, b[2] - b[0]), h = Math.max(1, b[3] - b[1]);
      let sum = 0, area = 0;
      for (const [x, y, sw, sh] of [[b[0] - pad, b[1] - pad, w + 2 * pad, pad], [b[0] - pad, b[3], w + 2 * pad, pad], [b[0] - pad, b[1], pad, h], [b[2], b[1], pad, h]]) {
        const l = global.__lumFor(x, y, sw, sh);
        if (l >= 0) { sum += l * sw * sh; area += sw * sh; }
      }
      return area > 0 ? sum / area : -1;
    }
    // A window's ground is its live box: windows grow to hold what is drawn on them, and a box kept at their first size
    // judged words in the grown part against the app behind (white words on a white card).
    const liveBox = g => (g[7] && markBox(g[7])) || g;
    const taggedFor = (m, wm) => Array.isArray(m.onWindow) && Array.isArray(wm.inner) && Math.abs(m.onWindow[0] - wm.inner[0]) < 1 && Math.abs(m.onWindow[1] - wm.inner[1]) < 1;
    // The ground under a mark (box b): the last one under its middle, else a window it is about to grow (fitWindowsTo
    // grows it after the mark is painted, by the same rule).
    function groundFor(m, b) {
      const cx = (b[0] + b[2]) / 2, cy = (b[1] + b[3]) / 2;
      for (let k = grounds.length - 1; k >= 0; k--) { const g = liveBox(grounds[k]); if (cx >= g[0] && cx <= g[2] && cy >= g[1] && cy <= g[3]) return grounds[k]; }
      for (let k = grounds.length - 1; k >= 0; k--) {
        const w = grounds[k][7];
        if (!w || w.__erased) continue;
        const g = liveBox(grounds[k]);
        if (belongsToWindow(b, g[0], g[1], g[2], g[3], taggedFor(m, w))) return grounds[k];
      }
      return null;
    }
    // Words on a card or a filled shape wear a halo in that ground's colour, so a line passing behind them stops short
    // of the letters instead of cutting through them: the card's colour, with any tinted box on it blended over it.
    // Words loose on the screen keep the pen's halo.
    function knockoutFor(m) {
      if (m.do !== 'text' || m.under || m.knockout === false || m.role === 'cheer') return null;
      const b = markBox(m);
      if (!b) return null;
      const ground = groundFor(m, b);
      if (!ground || !ground[5]) return null;
      const px = (b[0] + b[2]) / 2, py = (b[1] + b[3]) / 2;
      let colour = ground[5];
      for (const f of surfaces) if (f[6] > (ground[6] || 0) && px >= f[0] && px <= f[2] && py >= f[1] && py <= f[3]) colour = f[5] >= 0.99 ? f[4] : mixHex(colour, f[4], f[5]);
      return colour;
    }
    function readableColour(m, colour) {
      // only on the bare screen; a legend's keys keep exactly the colours of what they stand for
      if (surface !== 'none' || NO_INK_CHECK[m.do] || m.role === 'paper' || m.role === 'key') return colour;
      const ink = lumaOf(colour), b = markBox(m);
      if (ink == null || !b) return colour;
      const ground = groundFor(m, b);
      let under = ground ? ground[4] : null;
      if (under == null) { const l = bandLuma(b); if (!(l >= 0)) return colour; under = l; }
      // Words need more contrast than a line: grey words passed a line's 0.2 on a dark app and read dark on dark.
      const isWords = m.do === 'text', light = under > 0.58, needed = !isWords ? 0.2 : light ? 0.3 : 0.45;
      if (Math.abs(ink - under) >= needed) return colour;
      // A colour that means something (a group's colour, a legend's dots) keeps its hue: a deeper shade of it on a
      // light ground, a lighter one on a dark ground, so words in mustard still match their yellow dots. The search
      // goes from 0.1 to 0.85 in twentieths (counted in whole steps: adding 0.05 at a time drifted and never tried 0.85).
      const hex = hexOf(colour);
      if (isChromatic(hex)) for (let s = 2; s <= 17; s++) {
        const next = light ? shade(hex, s / 20) : mixHex(hex, '#FFFFFF', s / 20), l = lumaOf(next);
        if (l != null && Math.abs(l - under) >= needed) return next;
      }
      // greys and near-greys swap to the plain dark or light ink (a light grey for quieter words, keeping their order)
      if (light) return '#15171C';
      return isWords && ink > 0.35 ? '#C9CDD4' : '#FFFFFF';
    }

    // ---------------------------------------------------------------- windows grow to hold what is drawn on them
    // A mark mostly on a window (or tagged for it with onWindow, the window's writing area origin) that reaches past
    // its padding pushes that side out, keeping the padding (the top grows by the same rule, above the title bar). The
    // window's mark and element change, so the app redraws it and the card's box stays true.
    const windowsDrawn = [];
    // Whether a mark (box b) belongs to a window (outer box x0..x1, y0..y1): tagged for it, mostly on it, its middle on
    // it, or a row that ran just past its bottom (across the window, its top within a line below): the model ran out of
    // room, and that last row was left loose under the card with the sources line on top of it.
    function belongsToWindow(b, x0, y0, x1, y1, tagged) {
      if (tagged) return true;
      const ow = Math.min(b[2], x1) - Math.max(b[0], x0), oh = Math.min(b[3], y1) - Math.max(b[1], y0), bw = b[2] - b[0], bh = b[3] - b[1];
      if (ow > 0 && oh > 0 && ow * oh >= 0.4 * bw * bh) return true;
      const cx = (b[0] + b[2]) / 2, cy = (b[1] + b[3]) / 2;
      if (cx >= x0 && cx <= x1 && cy >= y0 && cy <= y1) return true;
      return ow >= 0.6 * bw && b[1] >= y0 && b[1] <= y1 + 48 && bh <= 120;
    }
    // the box mark i drew (halos left out), on the card
    function drawnBox(i, m) {
      let box = null;
      for (const n of NODES[i] || []) {
        if (n.__gone || (n.getAttribute && n.getAttribute('data-halo'))) continue;
        let r;
        try { r = n.getBBox(); } catch (_) { continue; }
        if (!r || (!r.width && !r.height)) continue;
        const nu = n.__nudge || [0, 0], q = [r.x + nu[0], r.y + nu[1], r.x + nu[0] + r.width, r.y + nu[1] + r.height];
        box = box ? [Math.min(box[0], q[0]), Math.min(box[1], q[1]), Math.max(box[2], q[2]), Math.max(box[3], q[3])] : q;
      }
      const a = m.__xf;
      return box && a ? [box[0] * a[0] + a[1], box[1] * a[0] + a[2], box[2] * a[0] + a[1], box[3] * a[0] + a[2]] : box;
    }
    function fitWindowsTo(m, i) {
      if (!windowsDrawn.length || !m || m.do === 'window' || m.do === 'edit' || m.role === 'tie' || m.role === 'photo' || m.role === 'paper'
        || m.stage != null || /3d$/.test(m.do || '') || pointsAtScreen(m)) return;
      const raw = drawnBox(i, m) || markBox(m);
      if (!raw || raw[2] <= raw[0] || raw[3] <= raw[1]) return;
      for (const w of windowsDrawn) {
        const wm = w.m;
        if (wm.__erased || !w.e.parentNode) continue;
        const xf = wm.__xf || [1, 0, 0], k = xf[0] || 1;
        const b = [(raw[0] - xf[1]) / k, (raw[1] - xf[2]) / k, (raw[2] - xf[1]) / k, (raw[3] - xf[2]) / k];   // in the window's own coordinates
        const x0 = wm.at[0], y0 = wm.at[1], x1 = x0 + wm.w, y1 = y0 + wm.h, pad = +wm.pad || 0, head = +wm.header || 0;
        const tagged = taggedFor(m, wm);
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
    // what a mark puts under later ink: a window, a card or an opaque fill is a ground; any visible fill is a surface
    function noteGround(m) {
      if (m.do === 'window') { const l = lumaOf(m.bg), b = markBox(m); if (l != null && b) grounds.push([b[0], b[1], b[2], b[3], l, hexOf(m.bg), ++drawOrder, m]); return; }
      if (!m.fill || !FILLABLE[m.do]) return;
      if (m.role !== 'paper') {
        const b = markBox(m), hex = hexOf(m.fill), alpha = m.fillAlpha != null ? +m.fillAlpha : 1;
        if (b && /^#[0-9a-f]{6}$/i.test(hex) && alpha >= 0.08) surfaces.push([b[0], b[1], b[2], b[3], hex, alpha, ++drawOrder]);
      }
      if (m.fillAlpha != null && m.fillAlpha < 0.8) return;
      const l = lumaOf(m.fill), b = markBox(m);
      // a card (paper's role) is a ground the words can match; a small filled shape only lends its brightness
      const isCard = m.role === 'paper' && (m.fillAlpha == null || m.fillAlpha >= 0.99);
      if (l != null && b) grounds.push([b[0], b[1], b[2], b[3], l, isCard ? hexOf(m.fill) : null, ++drawOrder]);
    }
    // ---------------------------------------------------------------- painting one mark
    // A dashed run: its dashes go on one after another over the time a dashed line takes (at most 0.9 s).
    function dashedStroke(c, m, colour, size, layer, on, off) {
      const pieces = dashes(c, on, off), start = clock, span = Math.min(0.9, 0.2 + plen(c) / 900);
      const tapered = Object.assign({}, m, { taper: m.taper === 0 ? 0 : 0.3 });
      pieces.forEach((piece, k) => { clock = start + span * k / Math.max(1, pieces.length); stroke(piece, tapered, colour, size, layer); });
      clock = start;
      return span;
    }
    // A closed outline, dashed when an edit asked for it (m.__dash; programs cannot set it, their dashes are for
    // lines and arrows).
    function edge(c, m, colour, size, layer) {
      if (!m.__dash) return stroke(c, m, colour, size, layer);
      const on = typeof m.__dash === 'number' ? m.__dash : Math.max(8, size * 3);
      return dashedStroke(c, m, colour, size, layer, on, on * 0.75);
    }
    const sameOrigin = (a, b) => Array.isArray(a) && Array.isArray(b) && Math.abs(a[0] - b[0]) < 1 && Math.abs(a[1] - b[1]) < 1;
    const windowAt = inner => windowsDrawn.find(v => sameOrigin(v.m.inner, inner));
    // A window's sources line starts where the window's content starts (programs indent their words inside the box,
    // and the credits were left hanging at its edge), and goes under everything drawn on the window with a clear gap (a
    // last row that grew the window had the credits written on top of it). Every piece of the line shares sourceLine
    // (its first baseline), so they move together. Done once per mark.
    function alignToWindow(m) {
      if (!Array.isArray(m.onWindow) || m.__aligned || !Array.isArray(m.at)) return;
      const w = windowAt(m.onWindow);
      if (w && isFinite(w.contentLeft) && w.contentLeft > w.m.inner[0] + 1) m.at = [m.at[0] + (w.contentLeft - w.m.inner[0]), m.at[1]];
      if (w && isFinite(w.contentBottom) && isFinite(+m.sourceLine)) {
        const size = +m.sourceSize || 13, gap = Math.max(24, +w.m.pad || 0), shift = w.contentBottom + gap - (+m.sourceLine - size * 0.82);
        if (shift > 0) m.at = [m.at[0], m.at[1] + shift];
      }
      m.__aligned = true;
    }
    const OUTLINED = /^(rect|ellipse|circle|poly)$/;
    // one mark at the current clock and pace; returns how long its pen takes (draw() and edits share it)
    function paint(m, i) {
      paintingRole = m.role || null;
      alignToWindow(m);
      // a filled shape with no ink of its own gets a thin edge in a deeper shade of its fill, not a black one
      const fillEdge = m.fill && !m.tone && OUTLINED.test(m.do) ? shade(tone(m.fill), 0.32) : null;
      const ink = {
        r: rng((m.id || '') + i),
        colour: fillEdge || readableColour(m, tone(m.tone, TONES[defInk])),
        size: m.size || (fillEdge ? 1.6 : (BRUSH[m.brush] || BRUSH.pen).size),
        layer: m.under ? under : main,
      };
      noteGround(m);
      const painter = PAINTERS[m.do];
      if (!painter) { report.errors.push(`unknown mark "${m.do}" (${m.id || i})`); return 0.3; }
      return painter(m, i, ink);
    }
    // the app paints these from their attributes: each is one element, faded or set in at its beat
    const placeholder = (tag, attrs, layer, animation, animDur, dur) => { anim(el(tag, attrs, layer), animation, animDur, clock); return dur; };
    const writeTime = text => 0.35 + letters(text) * 0.012;    // the time a written mark holds the pen (its own animation runs longer)
    const writeAnim = text => 0.4 + letters(text) * 0.015;
    const PAINTERS = {
      line: paintLine, arrow: paintLine, path: paintPath, circle: paintEllipse, ellipse: paintEllipse, rect: paintRect, poly: paintPoly,
      text: paintText, molecule: paintMolecule,
      dot: (m, i, { colour, layer }) => { anim(el('circle', { cx: m.at[0], cy: m.at[1], r: m.r || 3, fill: colour }, layer), 'pop', 0.25, clock); return 0.12; },
      highlight(m) {
        const [x, y] = m.at, w = m.w, h = m.h;
        const e = el('path', { d: `M${x} ${y + 2} Q${x + w / 2} ${y - 1} ${x + w} ${y + 1} L${x + w - 1} ${y + h} Q${x + w / 2} ${y + h + 2} ${x + 1} ${y + h - 1} Z`,
          fill: tone(m.tone || 'butter'), 'fill-opacity': 0.72, style: surface === 'sky' ? null : 'mix-blend-mode:multiply' }, m.under ? under : hlLayer);
        e.style.transformOrigin = `${x}px ${y}px`; e.style.transformBox = 'view-box';
        anim(e, 'swipe', 0.35, clock);
        return 0.35;
      },
      // an edit of what is on the card, at this point of the drawing
      edit: (m, i) => (hooks.edit ? hooks.edit(m, i, clock, pace) : 0) / Math.max(pace, 0.35),
      // a real photo: the app finds and paints it
      image: (m, i, { layer }) => placeholder('photo', { x: m.at[0], y: m.at[1], width: m.w, height: m.h, 'data-query': String(m.query || ''), 'data-radius': m.r || 0, 'data-rotate': m.rot || 0 }, layer, 'fadein', 0.5, 0.5),
      // a little window: the app paints its chrome and board
      window(m, i, { layer }) {
        const e = el('window', { x: m.at[0], y: m.at[1], width: m.w, height: m.h, 'data-header': m.header, 'data-title': m.title || null,
          'data-board': m.board || 'plain', 'data-bg': m.bg, 'data-tint': m.tint, 'data-tint-alpha': m.tintAlpha }, layer);
        const known = windowsDrawn.find(w => w.m === m);
        if (known) known.e = e; else windowsDrawn.push({ m, e });
        anim(e, 'fadein', 0.45, clock);
        return 0.45;
      },
      // a 3D object's stage, standing on the screen; on a card the program drew, that card's board is plain under it
      // (a window already on screen too: the app redraws a window whose attributes change)
      stage3d(m, i, { layer }) {
        const w = Array.isArray(m.cardWindow) ? windowAt(m.cardWindow) : null;
        if (w && w.e.getAttribute('data-board') !== 'plain') { w.m.board = 'plain'; w.e.setAttribute('data-board', 'plain'); }
        return placeholder('scene3d', { id: m.id, x: m.at[0], y: m.at[1], width: m.w, height: m.h, 'data-ink': m.ink, 'data-camera': JSON.stringify(m.camera || {}), 'data-card': m.card ? m.card.join(' ') : null, 'data-canvas': W + ' ' + H, 'data-look': m.look || null }, layer, 'fadein', 0.35, 0.12);
      },
      part3d: (m, i, { layer }) => placeholder('part3d', { 'data-stage': m.stage, 'data-part': JSON.stringify({ id: m.id, kind: m.kind, params: m.params, at: m.pos, rotate: m.rotate3, scale: m.scale3, material: m.material, parent: m.parent, three: m.three, recipe: m.recipe, name: m.name }) }, layer, 'grow', 0.65, 0.12),
      label3d: (m, i, { colour }) => placeholder('label3d', { 'data-stage': m.stage, 'data-label': JSON.stringify({ id: m.id, point: m.point, follow: m.follow, text: m.text, side: m.side }), fill: tone(m.tone, colour), 'font-family': FONT.hand, 'font-size': m.size || 19 }, words, 'write', writeAnim(m.text), writeTime(m.text)),
      // a figure's tick() starts with this beat
      tick3d: (m, i, { layer }) => placeholder('tick3d', { 'data-stage': m.stage, 'data-tick': m.id }, layer, 'set', 0.01, 0),
      motion3d: (m, i, { layer }) => placeholder(m.do, { 'data-stage': m.stage, 'data-op': JSON.stringify(m.op || {}) }, layer, 'set', 0.01, 0),
      camera3d: (m, i, { layer }) => placeholder(m.do, { 'data-stage': m.stage, 'data-op': JSON.stringify(m.op || {}) }, layer, 'set', 0.01, 0),
    };
    function paintLine(m, i, { r, colour, size, layer }) {
      // wobble 0 keeps a straight line straight (the dashed frames that mark the real screen stay crisp); bow 'pen' (the
      // screen pen): a smoothed line bends once per edge too, then stays smooth through its corners
      let c = m.smooth === false ? handSegments(m.pts, false, r, m.wobble == null ? 0.6 : m.wobble, m.bow, m.jitter)
        : m.bow === 'pen' ? catmull(handSegments(m.pts, false, r, m.wobble == null ? 1 : m.wobble, 'pen', m.jitter), false, 2) : catmull(m.pts, false);
      if (m.do === 'arrow' && m.bend) {
        const a = m.pts[0], b = m.pts[m.pts.length - 1], L = Math.hypot(b[0] - a[0], b[1] - a[1]) || 1;
        let k = m.bend === true ? 0.15 : Number(m.bend) || 0;
        if (Math.abs(k) > 1) k = k / L;                    // a bend given in canvas units, not as a fraction
        if (Math.abs(k) > 0.6) { report.warnings.push(`${m.id || i}: bend ${m.bend} is too strong, used ${Math.sign(k) * 0.6}`); k = Math.sign(k) * 0.6; }
        c = catmull([a, [(a[0] + b[0]) / 2 - (b[1] - a[1]) * k, (a[1] + b[1]) / 2 + (b[0] - a[0]) * k], b], false);
      }
      const on = typeof m.dash === 'number' ? m.dash : Math.max(8, size * 3), off = +m.dashGap || on * 0.75;
      let dur;
      if (m.dash && Array.isArray(m.marquee)) {
        // a frame the app draws itself, dragged open from its top-left corner like a selection by the cursor: the
        // element carries the box and the app animates it
        const e = el('path', { d: poly(m.pts), fill: 'none', stroke: colour, 'stroke-width': size, 'stroke-linecap': 'round', 'stroke-linejoin': 'round',
          'stroke-dasharray': `${on.toFixed(2)} ${off.toFixed(2)}`, 'data-marquee': m.marquee.map(v => (+v || 0).toFixed(2)).join(' '), 'data-marquee-handle': '1' }, layer);
        anim(e, 'marquee', MARQUEE_DUR, clock);
        dur = MARQUEE_DUR;
      } else dur = m.dash ? dashedStroke(c, m, colour, size, layer, on, off) : stroke(c, m, colour, size, layer);
      if (m.do !== 'arrow') return dur;
      // the head after the shaft: headAngle is half its opening; taper 0 keeps the barbs as heavy as the shaft
      const tip = c[c.length - 1], from = c[Math.max(0, c.length - 6)], a = Math.atan2(tip[1] - from[1], tip[0] - from[0]), hl = m.head || Math.max(9, size * 3), ha = +m.headAngle || 0.5;
      const barb = s => [tip[0] - hl * Math.cos(a + s * ha), tip[1] - hl * Math.sin(a + s * ha)];
      clock += dur;
      dur = stroke([barb(-1), tip, barb(1)], Object.assign({}, m, { taper: m.taper === 0 ? 0 : 0.4 }), colour, size, layer);
      if (m.label) {
        const mid = c[Math.floor(c.length / 2)];
        const t = el('text', { x: mid[0] + (m.labelDx || 0), y: mid[1] - 8 + (m.labelDy || 0), 'text-anchor': 'middle', fill: colour, 'font-family': faceFor('hand'), 'font-size': m.labelSize || 15 }, layer);
        t.textContent = m.label;
        anim(t, 'fadein', 0.3, clock + dur);
      }
      return dur;
    }
    // A path with several pieces ("M … M …": tick marks, window panes, brackets) is drawn piece by piece (sampled as
    // one line, every move was a stray stroke joining the pieces); a lone point is a dot.
    function paintPath(m, i, { colour, size, layer }) {
      const sh = Array.isArray(m.shift) ? m.shift : null, runs = [];
      for (const piece of String(m.d || '').split(/(?=M)/).map(s => s.trim()).filter(Boolean)) {
        const n = Math.max(40, Math.min(400, Math.round(piece.length / 2))), c = samplePath(piece, n), step = plen(c) / n;
        if (plen(c) < 0.5) { const start = (piece.match(/-?\d*\.?\d+/g) || []).map(Number); if (start.length >= 2) runs.push([[start[0], start[1]]]); continue; }
        // a relative "m" inside a piece: split where neighbouring samples jump (a chord is never longer than its arc)
        let run = [c[0]];
        for (let k = 1; k < c.length; k++) { if (dist(c[k - 1], c[k]) > step * 1.5 + 0.5) { runs.push(run); run = []; } run.push(c[k]); }
        runs.push(run);
      }
      wash(m.d, m, layer, sh ? { transform: `translate(${sh[0] + 0.8} ${sh[1] + 1})` } : null);
      if (m.outline === false || !runs.length) return 0.3;
      const start = clock;
      let total = 0;
      for (const run0 of runs) {
        const run = sh ? run0.map(p => [p[0] + sh[0], p[1] + sh[1]]) : run0;
        clock = start + total;
        if (run.length < 2 || plen(run) < 0.5) { anim(el('circle', { cx: run[0][0], cy: run[0][1], r: Math.max(1.5, size * 0.6), fill: colour }, layer), 'pop', 0.2, clock); total += 0.04; }
        else total += edge(run, m, colour, size, layer);
      }
      clock = start;
      return total;
    }
    function paintEllipse(m, i, { r, colour, size, layer }) {
      // rot in radians, or in degrees when it could not be radians
      const [cx, cy] = m.at, rx = m.r || m.rx, ry = m.r || m.ry, rot = (m.rot || 0) * (typeof m.rot === 'number' && Math.abs(m.rot) > 6.3 ? Math.PI / 180 : 1);
      const c = ellipsePts(cx, cy, rx, ry, rot, r, m.wobble == null ? 1 : m.wobble, m.outline !== false);
      wash(poly(ellipsePts(cx, cy, rx, ry, rot, rng('f' + i), 0.5, false)) + ' Z', m, layer);
      return m.outline === false ? 0.3 : edge(c, m, colour, size, layer);
    }
    function paintRect(m, i, { r, colour, size, layer }) {
      const [x, y] = m.at, w = m.w, h = m.h;
      // {r}: rounded corners (a card, a bar's cap, a button-like box), each a quarter circle in 6 steps
      const cr = Math.max(0, Math.min(+m.r || 0, Math.abs(w) / 2, Math.abs(h) / 2));
      const corner = (cx, cy, a0) => Array.from({ length: 7 }, (_, k) => { const a = a0 + k * Math.PI / 12; return [cx + Math.cos(a) * cr, cy + Math.sin(a) * cr]; });
      const pts = cr ? [...corner(x + w - cr, y + cr, -Math.PI / 2), ...corner(x + w - cr, y + h - cr, 0), ...corner(x + cr, y + h - cr, Math.PI / 2), ...corner(x + cr, y + cr, Math.PI)]
        : [[x, y], [x + w, y], [x + w, y + h], [x, y + h]];
      wash(poly(pts) + ' Z', m, layer);
      if (m.outline === false) return 0.3;
      // a sharp box is closed by hand: the pen runs a little past where it started
      return edge(cr ? handSegments(pts, true, r, 1) : handSegments(pts.concat([[x, y], [x + Math.min(6, Math.abs(w) * 0.06), y + 1]]), false, r, 1), m, colour, size, layer);
    }
    function paintPoly(m, i, { r, colour, size, layer }) {
      wash((m.smooth ? poly(catmull(m.pts, true)) : poly(m.pts)) + ' Z', m, layer);
      if (m.outline === false) return 0.3;
      const closed = m.close !== false;
      return edge(m.smooth ? catmull(m.pts, closed) : handSegments(m.pts, closed, r, m.wobble == null ? 0.7 : m.wobble, m.bow, m.jitter), m, colour, size, layer);
    }
    const probe = svg.querySelector('#__probe');
    function paintText(m, i, { colour, layer }) {
      const style = m.style || 'hand';
      let fs = m.size || (style === 'title' ? 24 : style === 'body' ? 17 : style === 'caps' ? 14 : 20);
      // caps: upper case, semibold, tracked out with hair spaces between letters (the native text shaper has no
      // letter-spacing). Letters, not UTF-16 halves: an emoji split in two by a hair space drew as two broken glyphs.
      if (style === 'caps') m = Object.assign({}, m, { text: [...String(m.text).toUpperCase()].join(' '), weight: m.weight || 600 });
      // ui words (name pills, badges) are sized in screen points: on a big display one canvas unit is about 2pt, so
      // their floor is 8pt, not 8 units (a unit floor drew a 12pt pill's words a third too big, spilling out of it)
      const unitPoints = +global.__canvasUnitPoints > 0 ? +global.__canvasUnitPoints : 1;
      const minSize = style === 'ui' ? 8 / unitPoints : 13;
      if (fs < minSize) { report.warnings.push(`${m.id || i}: text size ${fs} is too small to read, used ${Math.round(minSize)}`); fs = minSize; }
      const lineHeight = +m.lineHeight > 0.8 ? +m.lineHeight : LINE_HEIGHT;   // a tighter line for headlines
      const weight = style === 'title' ? 600 : (m.weight || null);
      const knockout = knockoutFor(m), haloWidth = Math.max(5, fs * 0.45);
      const t = el('text', { x: m.at[0], y: m.at[1], fill: colour, 'font-family': faceFor(style), 'font-size': fs, 'font-weight': weight, 'text-anchor': m.anchor || 'start', 'dominant-baseline': m.top ? 'alphabetic' : (m.baseline || 'auto'), transform: m.rot ? `rotate(${m.rot} ${m.at[0]} ${m.at[1]})` : null,
        stroke: knockout, 'stroke-width': knockout ? haloWidth : null, 'stroke-linejoin': knockout ? 'round' : null, 'paint-order': knockout ? 'stroke' : null,
        'data-knockout': knockout, 'data-knockout-width': knockout ? haloWidth.toFixed(2) : null }, m.under ? layer : words);
      let lines = String(m.text).split('\n');
      const maxW = m.wrap || (m.fit && m.fit[0]);
      if (maxW && lines.length === 1) lines = wrapWords(lines[0], maxW, { 'font-family': faceFor(style), 'font-size': fs, 'font-weight': weight });
      // a wrapped block is centred on its point, unless it hangs from it or names its own baseline
      if (lines.length > 1 && (m.fit || m.wrap) && !m.top && (m.baseline || 'auto') === 'auto') t.setAttribute('y', m.at[1] - (lines.length - 1) * fs * lineHeight / 2);
      if (lines.length > 1) lines.forEach((ln, k) => { el('tspan', { x: m.at[0], dy: k ? fs * lineHeight : 0 }, t).textContent = ln; });
      else t.textContent = m.text;
      if (m.fit) {
        // shrinks in 8% steps until it fits its box (not below 8)
        let f = fs, bb = t.getBBox();
        while ((bb.width > m.fit[0] || bb.height > m.fit[1]) && f > Math.min(8, minSize)) {
          f *= 0.92;
          t.setAttribute('font-size', f.toFixed(1));
          t.querySelectorAll('tspan').forEach((ts, k) => k && ts.setAttribute('dy', f * lineHeight));
          bb = t.getBBox();
        }
        if (f < fs * 0.7) report.warnings.push(`${m.id || i}: text shrank to ${Math.round(f)}px to fit, shorten it`);
      }
      if (m.place !== false && !m.under && !editing) placeLabel(t);
      anim(t, 'write', writeAnim(m.text), clock);
      return writeTime(m.text);
    }
    // greedy word wrap with the real glyph widths, measured on a hidden probe
    function wrapWords(text, maxW, font) {
      const p = el('text', font, probe), out = [];
      const width = s => { p.textContent = s; return p.getComputedTextLength(); };
      let cur = '';
      for (const w of text.split(' ')) { const next = cur ? cur + ' ' + w : w; if (cur && width(next) > maxW) { out.push(cur); cur = w; } else cur = next; }
      out.push(cur);
      p.remove();
      return out;
    }
    // a molecule from its SMILES, drawn by SmilesDrawer in the card's tones and fitted to its box
    function paintMolecule(m, i, { layer }) {
      const g = el('g', { transform: `translate(${m.at[0]} ${m.at[1]})` }, layer);
      const s = el('svg', { width: m.w, height: m.h, viewBox: `0 0 ${m.w} ${m.h}`, overflow: 'visible' }, g);
      s.setAttribute('data-smiles', m.smiles);
      if (global.SmilesDrawer) {
        const d = new global.SmilesDrawer.SvgDrawer({ width: m.w, height: m.h, bondThickness: 1.6, bondLength: m.bond || 22, shortBondLength: 0.82, fontSizeLarge: 9, fontSizeSmall: 6, padding: 4, compactDrawing: false, terminalCarbons: false, explicitHydrogens: false,
          themes: { mate: { C: TONES.ink, O: TONES.coral, N: TONES.blue, F: TONES.leaf, CL: TONES.leaf, BR: TONES.brown, I: TONES.violet, P: TONES.orange, S: TONES.sun, B: TONES.peach, SI: TONES.brown, H: TONES.ink, BACKGROUND: 'transparent' } } });
        global.SmilesDrawer.parse(m.smiles, tree => { d.draw(tree, s, 'mate', null, false); }, err => report.errors.push('smiles: ' + err));
        s.querySelectorAll('line').forEach(ln => { ln.setAttribute('stroke-linecap', 'round'); ln.setAttribute('stroke-width', '1.8'); });
        try {
          const bb = s.getBBox();
          if (bb.width > 0) {
            const k = Math.min(m.w / (bb.width + 10), m.h / (bb.height + 10), 1.9), vw = m.w / k, vh = m.h / k;
            s.setAttribute('viewBox', `${bb.x + bb.width / 2 - vw / 2} ${bb.y + bb.height / 2 - vh / 2} ${vw} ${vh}`);
          }
        } catch (_) {}
        s.querySelectorAll('text').forEach(tx => { tx.setAttribute('font-family', FONT.body); tx.setAttribute('font-weight', '600'); });
      } else report.errors.push('molecule piece needs SmilesDrawer');
      anim(g, 'fadein', 0.6, clock);
      return 0.6;
    }
    // ---------------------------------------------------------------- the drawing, mark by mark
    // The cursor flies to the next mark on an arc. A mark far from the last one waits for it (its ink starts when the
    // cursor lands) instead of drawing while the cursor is still across the screen, and marks after it never start
    // before it. The first mark waits for the flight from wherever the cursor is. Typing, copying and buttons, and
    // invisible dots, are done where the cursor already is.
    const NO_FLIGHT = new Set(['type', 'copy', 'open', 'handoff']);
    let penAt = null, penLandsAt = 0;
    function penFlightBefore(m) {
      if (NO_FLIGHT.has(m.role) || (m.role === 'button' && m.do === 'dot') || (m.do === 'dot' && (+m.r || 3) < 1)) return 0;
      const b = markBox(m);
      if (!b) return 0;
      const c = [(b[0] + b[2]) / 2, (b[1] + b[3]) / 2], from = penAt;
      penAt = c;
      if (!from) return 0.45;
      const far = Math.hypot(c[0] - from[0], c[1] - from[1]);
      return far < 110 ? 0 : Math.min(0.55, 0.2 + far / 2400);
    }
    // A tie arrow (tie() in Mate's pieces, {tieTo: [x, y, w, h, gap, pad]}) starts where its row's words really end:
    // the model can only guess how long a line is, so its arrows started far past short rows or inside long ones. The
    // row is the words beside the start the model gave (their middle within a line of it, on the near side); the
    // arrow leaves the end of the longest of them, at that line's height, and stops at the photo's edge plus the gap.
    function snapTie(m) {
      const t = m.tieTo, from = m.pts[0];
      if (!Array.isArray(t) || !Array.isArray(from)) return;
      const [bx, by, bw, bh, gap, pad] = t.map(Number);
      if (![bx, by, bw, bh, from[0], from[1]].every(Number.isFinite)) return;
      const toRight = bx + bw / 2 > from[0];
      let best = null;
      for (const e of words.querySelectorAll('text')) {
        if (e.__gone || e.ownerSVGElement !== svg || e.__role === 'photo' || e.__role === 'tie' || e.__role === 'source') continue;
        const o = cardBox(e, false);
        if (!o || !o.w || Math.abs(o.y + o.h / 2 - from[1]) > Math.max(o.h, 20)) continue;
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
    const stepOf = m => m.step != null ? stepKey(m) : 0;
    const farOut = p => Array.isArray(p) && (p[0] < -W * 0.1 || p[0] > W * 1.1 || p[1] < -H * 0.1 || p[1] > H * 1.1);
    // Paints marks on the card's clock. Unpaced, each step fits its budget (its strokes speed up when there are many)
    // and a new step waits 0.3 s. live: the clock follows the real time; d.paced: the pacer already chose when this
    // mark starts (now) and how fast it goes (d.pace), and d.i is its index (a new turn's dropped marks leave gaps).
    function draw(marks, live = false, d = {}) {
      if (live) { const now = nowS(); clock = d.paced ? now + 0.02 : Math.max(clock, now + 0.05); delayBase = now; }
      const stepTotal = {};
      for (const m of marks) stepTotal[stepOf(m)] = (stepTotal[stepOf(m)] || 0) + est(m);
      const own = marks.length === 1 && d.i != null;
      let top = total - 1;
      marks.forEach((m, j) => {
        const i = own ? d.i : total + j;
        top = Math.max(top, i);
        try {
          if (m.__skip) { m.__passed = true; return; }   // erased by an edit before it was drawn
          if (m._t != null) { clock = m._t; pace = m._pace != null ? m._pace : 1; }   // a precomputed schedule (paced replays, frames)
          else if (d.paced) pace = d.pace != null ? d.pace : 1;
          else {
            pace = Math.min(1, BUDGET / (stepTotal[stepOf(m)] || 1));
            if (m.step != null && lastStep != null && stepKey(m) !== lastStep) clock += 0.3;
          }
          if (m.step != null) lastStep = stepKey(m);
          if (m.tieTo && Array.isArray(m.pts) && m.pts.length >= 2 && !m.__tied) { m.__tied = true; snapTie(m); }
          if (live && d.paced) { const flight = penFlightBefore(m); clock = Math.max(clock, penLandsAt); if (flight) penLandsAt = clock = clock + flight; }
          const start = clock;
          if (Array.isArray(m.pts) && m.pts.some(farOut)) report.warnings.push(`${m.id || i}: a point of this ${m.do} is far outside the card`);
          cap = NODES[i] = []; capM = MASKS[i] = []; capKey = i; MK[i] = m;
          let dur;
          try { dur = paint(m, i); } finally { cap = capM = null; }
          if (m.__xf) NODES[i].forEach(n => setXf(wrap(n), m.__xf));   // moved or scaled by an edit before it was drawn
          try { fitWindowsTo(m, i); } catch (_) {}
          placed[i] = [+start.toFixed(3), +(start + dur * Math.max(pace, 0.35)).toFixed(3)];
          clock += dur * (m.do === 'dot' ? 0.5 : 0.7) * pace;
        } catch (e) { report.errors.push(`${m.id || i}: ${e.message}`); }
      });
      total = Math.max(total + (own ? 0 : marks.length), top + 1);
      report.marks = total;
    }
    // The finished card's report: what runs off the card and which words overlap (where they are now: nudged, moved
    // and scaled by edits; erased ones left out), at most 14 warnings, and how long the drawing takes.
    function finish() {
      const live = e => e.ownerSVGElement === svg && !e.__gone;
      for (const e of [...main.querySelectorAll('text,path'), ...words.querySelectorAll('text')].filter(live)) {
        const b = cardBox(e, false);
        if (b && b.w && (b.x < -2 || b.y < -2 || b.x + b.w > W + 2 || b.y + b.h > H + 2)) report.warnings.push(`${e.tagName} at ${Math.round(b.x)},${Math.round(b.y)} runs off the canvas`);
      }
      const boxes = [...words.querySelectorAll('text')].filter(live).map(e => ({ b: cardBox(e, false), t: e.textContent.slice(0, 24) })).filter(x => x.b && x.b.w);
      let overlaps = 0;
      for (let a = 0; a < boxes.length; a++) for (let c = a + 1; c < boxes.length; c++) {
        const A = boxes[a].b, B = boxes[c].b, ix = Math.min(A.x + A.w, B.x + B.w) - Math.max(A.x, B.x), iy = Math.min(A.y + A.h, B.y + B.h) - Math.max(A.y, B.y);
        if (ix > 3 && iy > 4) { overlaps++; report.warnings.push(`text "${boxes[a].t}" overlaps text "${boxes[c].t}"`); }
      }
      report.overlaps = overlaps;
      report.warnings = [...new Set(report.warnings)].slice(0, 14);
      report.duration = +clock.toFixed(2);
      host.dataset.report = JSON.stringify(report);
      return report;
    }

    // ---------------------------------------------------------------- changing what is already on the card
    // A mark's nodes sit in several layers (wash under, pen strokes, words). An edit repaints a mark with its own seed
    // (so it wobbles exactly as before) at its own depth, moves or scales its nodes inside wrapper groups, or runs its
    // pen backwards. Tweens run on animation frames only while something changes each frame, else one wake-up at the
    // next start or end; settle() jumps every running edit to its end (an interruption).
    const TW = new Set(), fresh = new Set();
    const ease = p => p < 0.5 ? 2 * p * p : 1 - Math.pow(-2 * p + 2, 2) / 2;
    const EASE_CSS = 'cubic-bezier(.455,.03,.515,.955)';     // the same curve for hosts that animate a motion themselves
    // A host that animates on its own (the native canvas: Core Animation) takes each edit's changes declared once
    // (global.__mateMotion(items, at, dur, ease)) instead of a style change on every frame.
    const motionHost = () => typeof global.__mateMotion === 'function' ? global.__mateMotion : null;
    const hasRaf = typeof requestAnimationFrame === 'function';
    const nowS = () => (performance.now() - t0) / 1000;
    let wake = 0, wakeRaf = false, wakeAt = Infinity;
    function arm(ms) {
      const t = performance.now(), at = t + Math.max(0, ms);
      if (wake && at >= wakeAt - 1) return;                // already waking up in time
      if (wake) { if (wakeRaf) cancelAnimationFrame(wake); else clearTimeout(wake); }
      if (ms <= 0 && hasRaf) { wakeRaf = true; wake = requestAnimationFrame(frame); wakeAt = t; }
      else { wakeRaf = false; wake = setTimeout(frame, ms <= 0 ? 16 : ms); wakeAt = at; }
    }
    function frame() {
      wake = 0; wakeAt = Infinity;
      const t = performance.now();
      let next = Infinity, perFrame = false;
      for (const tw of [...TW]) {
        if (!TW.has(tw)) continue;                         // settled by an earlier tween's done()
        if (t < tw.s) { next = Math.min(next, tw.f ? tw.s : tw.s + tw.d); continue; }
        const p = Math.min(1, (t - tw.s) / tw.d);
        if (tw.f) tw.f(ease(p));
        if (p >= 1) { TW.delete(tw); if (tw.done) tw.done(); }
        else if (tw.f) perFrame = true;
        else next = Math.min(next, tw.s + tw.d);
      }
      if (!TW.size) return;
      if (perFrame) arm(0); else if (next < Infinity) arm(next - performance.now());
    }
    // f(p) each frame (null: nothing changes per frame, done() at the end); decl: nodes a host is animating (settle stops them)
    function tween(delay, dur, f, done, decl) {
      const tw = { s: performance.now() + delay * 1000, d: Math.max(1, dur * 1000), f, done, decl };
      TW.add(tw);
      arm(Math.max(0, (f ? tw.s : tw.s + tw.d) - performance.now()));
      return tw;
    }
    function settle() {
      for (const tw of [...TW]) { TW.delete(tw); if (tw.f) tw.f(1); if (tw.decl) for (const n of tw.decl) n.style.animation = 'none'; if (tw.done) tw.done(); }
      for (const n of fresh) n.style.animation = 'none';
      fresh.clear();
    }
    // the group a node moves in (made on first use, at the node's depth)
    function wrap(n) {
      if (n.__wrap) return n.__wrap;
      const g = document.createElementNS(NS, 'g');
      g.__k = n.__k; g.__xf = [1, 0, 0];
      n.parentNode.insertBefore(g, n); g.appendChild(n);
      return (n.__wrap = g);
    }
    function setXf(g, xf) { g.__xf = xf; g.setAttribute('transform', `matrix(${+xf[0].toFixed(4)} 0 0 ${+xf[0].toFixed(4)} ${+xf[1].toFixed(2)} ${+xf[2].toFixed(2)})`); }
    // a repainted node keeps its mark's depth: before the first node of a later mark
    function placeByKey(n) {
      const par = n.parentNode;
      if (!par) return;
      for (const c of par.childNodes) if (c !== n && c.__k != null && c.__k > n.__k) { par.insertBefore(n, c); return; }
    }
    // paints mark m (seed i) at depth `key`, starting `at` s from now at pace p; the drawing's own clock is left alone
    function paintAt(m, i, key, at, p, repaint) {
      const saved = [clock, pace, delayBase], now = nowS();
      delayBase = now; clock = now + at; pace = p;
      cap = []; capM = []; capKey = key; editing = !!repaint;
      let dur = 0.3;
      try { dur = paint(m, i); } catch (e) { report.errors.push(`edit ${i}: ${e.message}`); }
      const nodes = cap, masks = capM;
      cap = capM = null; editing = false;
      [clock, pace, delayBase] = saved;
      for (const n of nodes) { placeByKey(n); fresh.add(n); }
      for (const mp of masks) fresh.add(mp);
      if (m.__xf) nodes.forEach(n => setXf(wrap(n), m.__xf));
      NODES[i] = nodes; MASKS[i] = masks; MK[i] = m;
      try { fitWindowsTo(m, i); } catch (_) {}
      const d = dur * Math.max(p, 0.35);
      tween(at + d + 0.1, 0.001, null, () => { nodes.forEach(n => fresh.delete(n)); masks.forEach(n => fresh.delete(n)); });
      return { nodes, masks, dur: d, adv: dur * (m.do === 'dot' ? 0.5 : 0.7) * p };
    }
    // takes nodes off the card: the pen runs backwards over strokes, everything else fades; then they are removed
    function unpaint(nodes, masks, at, dur) {
      const byMask = {};
      for (const mp of masks || []) { const mk = mp.parentNode; if (mk && mk.id) byMask[mk.id] = mp; }
      const pen = [], fade = [];
      for (const n of nodes) {
        n.__gone = true;
        const id = /url\(#([^)]+)\)/.exec(n.getAttribute('mask') || '');
        if (id && byMask[id[1]]) pen.push(byMask[id[1]]); else fade.push(n);
      }
      const off = () => {
        for (const n of nodes) { const w = n.__wrap; (w && w.parentNode ? w : n).remove(); }
        for (const mp of masks || []) { const mk = mp.parentNode; if (mk) mk.remove(); }
      };
      const motion = motionHost();
      if (motion) {
        motion(pen.map(mp => ({ node: mp, prop: 'dash', from: 0, to: 1 })).concat(fade.map(n => ({ node: n, prop: 'opacity', from: 1, to: 0 }))), at, dur, EASE_CSS);
        return tween(at, dur, null, off, pen.concat(fade));
      }
      return tween(at, dur, p => {
        for (const mp of pen) { mp.style.animation = 'none'; mp.style.strokeDashoffset = String(p); }
        for (const n of fade) { n.style.animation = 'none'; n.style.opacity = String(1 - p); }
      }, off);
    }
    // glides nodes to a new transform [scale, tx, ty] (linear in the matrix, so a scale keeps its centre fixed)
    function moveNodes(nodes, to, at, dur) {
      const gs = nodes.filter(n => !n.__gone && n.parentNode).map(wrap), from = gs.map(g => g.__xf.slice());
      const motion = motionHost();
      if (motion) {
        gs.forEach(g => setXf(g, to));                     // where it ends up; the host glides it there
        motion(gs.map((g, j) => ({ node: g, prop: 'xf', from: from[j], to: to.slice() })), at, dur, EASE_CSS);
        return tween(at, dur, null, null, gs);
      }
      return tween(at, dur, p => gs.forEach((g, j) => { const a = from[j]; setXf(g, [a[0] + (to[0] - a[0]) * p, a[1] + (to[1] - a[1]) * p, a[2] + (to[2] - a[2]) * p]); }));
    }
    // Where a drawn mark really is on the card (text measured in its real font), or null. The app's DOM has no
    // isConnected (a node on the canvas has its <svg> above it): without that fallback every box in the app was the
    // program's estimate, and a mark with none never rode with its card when the card moved.
    function domBox(i) {
      let b = null;
      for (const n of NODES[i] || []) {
        if (n.__gone || !(n.isConnected !== undefined ? n.isConnected : !!n.ownerSVGElement)) continue;
        const r = cardBox(n, false);
        if (!r || (!r.w && !r.h)) continue;
        b = b ? [Math.min(b[0], r.x), Math.min(b[1], r.y), Math.max(b[2], r.x + r.w), Math.max(b[3], r.y + r.h)] : [r.x, r.y, r.x + r.w, r.y + r.h];
      }
      return b;
    }
    const edit = { NODES, MASKS, MK, paintAt, unpaint, moveNodes, settle, tween, domBox, now: nowS, get busy() { return TW.size > 0; } };
    // when mark i starts drawing, in seconds from now, and for how long (the drawing's sounds land on its ink)
    const startsIn = i => placed[i] ? [placed[i][0] - nowS(), placed[i][1] - placed[i][0]] : null;
    return { draw, finish, report, svg, placed, edit, hooks, startsIn };
  }

  // ================================================================ 1.6: parts, the things on a card a model can name (DOM-free)
  // A part is what the program's own comments call a piece of the drawing ("// Big bushy tail"), or one text, or a run
  // of statements with no blank line between them. Parts are numbered in program order (p1, p2, ...), so a part keeps
  // its id while the program streams in. Every mark also has an id (m0, m1, ...); marks made by edits start at m2000.
  const EDIT_BASE = 2000;                                // marks an edit adds are numbered from here, apart from the program's
  // ================================================================ the card in words: parts, boxes and the model's view
  // The program's lines: where each starts, whether it is blank, a whole-line comment (full) or a comment after code
  // (tail). A line starting with * is a comment only inside a block comment: elsewhere it continues an expression
  // ("  * 2"), and used to become the heading of the next part.
  function lineIndex(code) {
    const out = [];
    let pos = 0, inBlock = false;
    for (const line of code.split('\n')) {
      const t = line.trim(), rec = { s: pos, blank: !t, full: null, tail: null };
      if (inBlock || t.startsWith('/*')) {
        rec.full = t.replace(/^\/?\*+\/?\s*/, '').replace(/\*\/\s*$/, '').trim();
        inBlock = t.indexOf('*/', inBlock ? 0 : 2) < 0;   // still open after this line
      } else if (t.startsWith('//')) rec.full = t.replace(/^\/\/+\s*/, '').trim();
      else if (t) { const k = commentAt(line); if (k >= 0) rec.tail = line.slice(k).replace(/^\/\/+\s*/, '').trim() || null; }
      out.push(rec);
      pos += line.length + 1;
    }
    return out;
  }
  // where a // comment starts on a line of code (outside its strings), or -1
  function commentAt(line) {
    let quote = null;
    for (let i = 0; i < line.length; i++) {
      const c = line[i];
      if (quote) { if (c === '\\') i++; else if (c === quote) quote = null; }
      else if (c === '"' || c === "'" || c === '`') quote = c;
      else if (c === '/' && line[i + 1] === '/') return i;
    }
    return -1;
  }
  // the line holding character offset `off` (L from lineIndex)
  function lineOf(L, off) {
    let lo = 0, hi = L.length - 1;
    while (lo < hi) { const mid = (lo + hi + 1) >> 1; if (L[mid].s <= off) lo = mid; else hi = mid - 1; }
    return lo;
  }
  const textSize = m => m.size || (m.style === 'title' ? 24 : m.style === 'body' ? 17 : 20);
  const growBox = (b, pad) => b && [b[0] - pad, b[1] - pad, b[2] + pad, b[3] + pad];
  const finitePoints = P => (P || []).filter(p => Array.isArray(p) && isFinite(p[0]) && isFinite(p[1]));
  // A mark's box [x0, y0, x1, y1] from its data, with the move or scale an edit gave it. Text is sized with the same
  // letter widths as ink boxes (East Asian characters and emoji an em wide), and a path by the points its pen draws,
  // relative commands too (before, a relative path had no box and never rode with its card).
  function markBox(m) {
    if (!m || typeof m !== 'object') return null;
    const pad = (m.size || 3) / 2, at = Array.isArray(m.at) ? m.at : null;
    const pointsBox = P => { P = finitePoints(P); return P.length ? growBox(boxOf(P), pad) : null; };
    let b = null;
    switch (m.do) {
      case 'line': case 'arrow': case 'poly': b = pointsBox(m.pts); break;
      case 'circle': case 'ellipse': if (at) {
        let rx = +(m.r || m.rx) || 0, ry = +(m.r || m.ry) || 0;
        if (m.rot) rx = ry = Math.max(rx, ry);
        b = [at[0] - rx - pad, at[1] - ry - pad, at[0] + rx + pad, at[1] + ry + pad];
      } break;
      case 'dot': if (at) { const r = +m.r || 3; b = [at[0] - r, at[1] - r, at[0] + r, at[1] + r]; } break;
      case 'rect': case 'highlight': case 'molecule': case 'stage3d': case 'image': case 'window': if (at) {
        const w = +m.w || 0, h = +m.h || 0;
        b = [Math.min(at[0], at[0] + w), Math.min(at[1], at[1] + h), Math.max(at[0], at[0] + w), Math.max(at[1], at[1] + h)];
      } break;
      case 'text': if (at) {
        const size = textSize(m), lines = String(m.text).split('\n'), widest = Math.max(...lines.map(s => textW(s, size, m.style)));
        const boxed = m.fit || m.wrap, w = m.fit ? Math.min(m.fit[0], widest) : m.wrap ? Math.min(m.wrap, widest) : widest;
        const n = boxed ? Math.max(lines.length, Math.ceil(widest / (w || 1))) : lines.length;
        const x = at[0] - (m.anchor === 'middle' ? w / 2 : m.anchor === 'end' ? w : 0), y = at[1] - size * 0.8 - (n > 1 && boxed ? (n - 1) * size * LINE_HEIGHT / 2 : 0);
        b = [x, y, x + w, y + size * 1.05 + (n - 1) * size * LINE_HEIGHT];
      } break;
      case 'path': { const [sx, sy] = m.shift || [0, 0]; b = pointsBox([].concat(...pathRuns(m.d)).map(p => [p[0] + sx, p[1] + sy])); break; }
    }
    const xf = m.__xf;
    return b && xf ? [b[0] * xf[0] + xf[1], b[1] * xf[0] + xf[2], b[2] * xf[0] + xf[1], b[3] * xf[0] + xf[2]] : b;
  }
  const unionBox = bs => bs.filter(Boolean).reduce((a, b) => a ? [Math.min(a[0], b[0]), Math.min(a[1], b[1]), Math.max(a[2], b[2]), Math.max(a[3], b[3])] : b.slice(), null);
  const fmtBox = b => b ? `[${Math.round(b[0])},${Math.round(b[1])},${Math.round(b[2] - b[0])},${Math.round(b[3] - b[1])}]` : '[?]';
  const clip = (s, n) => { s = String(s).replace(/\s+/g, ' ').trim(); return s.length > n ? s.slice(0, n - 1) + '…' : s; };
  // A 3D part in the card's words: its id (what part() and motions take), kind, size, place and colour.
  const fmt3 = v => Array.isArray(v) ? '[' + v.map(n => +(+n).toFixed(2)).join(',') + ']' : '';
  const SIZES_3D = ['r', 'h', 'size', 'inner', 'outer', 'tube', 'depth'];
  function describe3dPart(m, withoutPlace) {
    const p = m.params || {}, bits = [m.kind], ends = Array.isArray(p.from) && Array.isArray(p.to);
    for (const k of SIZES_3D) if (p[k] != null && !(ends && k === 'h')) bits.push(k + '=' + (Array.isArray(p[k]) ? fmt3(p[k]) : +(+p[k]).toFixed(2)));
    if (ends && !withoutPlace) bits.push('from ' + fmt3(p.from) + ' to ' + fmt3(p.to));
    if (Array.isArray(p.points)) bits.push(p.points.length + ' points');
    if (Array.isArray(p.profile)) bits.push('profile of ' + p.profile.length + ' points');
    if (!withoutPlace && ((m.kind !== 'group' && !ends) || (m.pos && m.pos.some(n => +n)))) bits.push('at ' + fmt3(m.pos));
    if (!withoutPlace && m.rotate3 && m.rotate3.some(n => +n)) bits.push('rotate ' + fmt3(m.rotate3));
    const c = m.material && m.material.color;
    if (c) bits.push(String(c));
    // a figure() part's material in the words its program used ('paint coral', 'glass'), and its name (the variable it
    // was assigned to), so a follow-up finds "the piston" without guessing from sizes
    if (m.three && m.material && (m.material.mat || m.material.tint)) bits.push([m.material.mat, m.material.tint ? toneName(m.material.tint) : null].filter(Boolean).join(' '));
    if (m.parent) bits.push('in ' + m.parent);
    return (m.three && m.name ? m.name + ': ' : '') + bits.join(' ');
  }
  const toneName = c => Object.keys(TONES).find(k => TONES[k].toLowerCase() === String(c).toLowerCase()) || String(c);
  // one mark in a few words: its kind, colours and dashes (3D figures and their parts by name, so a follow-up can build on them)
  function markLabel(m) {
    if (!m) return '?';
    switch (m.do) {
      case 'stage3d': return `3D figure ${m.id}`;
      case 'part3d': return `${m.id} ${describe3dPart(m)}`;
      case 'label3d': return `3D label "${String(m.text).slice(0, 30)}"`;
      case 'motion3d': return `3D motion ${(m.op && m.op.kind) || ''} on ${(m.op && m.op.target) || ''}`;
      case 'camera3d': return '3D camera';
      case 'tick3d': return '3D tick (runs the mechanism every frame)';
      case 'text': return `text ${m.style || 'hand'} ${Math.round(textSize(m))} ${m.tone || 'ink'}${m.weight ? ' weight ' + m.weight : ''}`;
      case 'highlight': return `highlight ${m.tone || 'butter'}`;
      case 'window': return `window${m.title ? ' "' + String(m.title).slice(0, 30) + '"' : ''} ${m.board || 'plain'} board`;
      case 'dot': return `dot ${m.tone || 'ink'}`;
    }
    const colours = [];
    if (m.fill && m.fill !== 'none') colours.push('fill ' + m.fill);
    if (m.outline !== false || !m.fill) colours.push((colours.length ? 'line ' : '') + (m.tone || 'ink'));
    // what is drawn: a program's dash only dashes lines and arrows; an edit can dash a closed shape
    if (((m.do === 'line' || m.do === 'arrow') && m.dash) || m.__dash) colours.push('dashed');
    return (m.do === 'line' && m.smooth ? 'curve' : m.do) + (colours.length ? ' ' + colours.join(' ') : '');
  }
  // where a box sits on the card, in a word: top-left ... centre ... bottom-right
  function zoneOf(b, W, H) {
    if (!b) return '';
    const cx = (b[0] + b[2]) / 2 / W, cy = (b[1] + b[3]) / 2 / H;
    const v = cy < 0.34 ? 'top' : cy > 0.66 ? 'bottom' : '', h = cx < 0.34 ? 'left' : cx > 0.66 ? 'right' : '';
    return v && h ? v + '-' + h : v || h || 'centre';
  }
  // the first string argument at the top level of a call (its words, not an option like {tone: 'coral'})
  function firstWords(call) {
    let args = '';
    for (let k = 0, depth = 0, q = null; k < call.length; k++) {
      const ch = call[k];
      if (q) { if (depth === 0) args += ch; if (ch === '\\') { k++; if (depth === 0) args += call[k] || ''; } else if (ch === q) q = null; continue; }
      if (ch === '"' || ch === "'" || ch === '`') { q = ch; if (depth === 0) args += ch; continue; }
      if (ch === '{') depth++; else if (ch === '}') depth = Math.max(0, depth - 1); else if (depth === 0) args += ch;
    }
    const words = /"((?:[^"\\]|\\.)*)"|'((?:[^'\\]|\\.)*)'|`([^`]*)`/.exec(args);
    return words ? words[1] || words[2] || words[3] || '' : '';
  }
  // past blanks and comments to a statement's code, from b up to e
  function codeStart(code, b, e) {
    for (;;) {
      while (b < e && /\s/.test(code[b])) b++;
      if (code.startsWith('//', b)) { const j = code.indexOf('\n', b); b = j < 0 ? e : Math.min(j, e); continue; }
      if (code.startsWith('/*', b)) { const j = code.indexOf('*/', b + 2); b = j < 0 ? e : Math.min(j + 2, e); continue; }
      return b;
    }
  }
  // The card as parts a model can name. A part is the statements under one comment heading, or one call of a piece
  // (Mate's paper, sticky, receipt, ...; a helper the program defined; graph, timeline), or one text; consecutive
  // statements of a step join the part before them unless a heading, a trailing comment or a blank line splits them.
  // An edit mark ({do: 'edit'}) is never part of a part, and a statement that edits starts a new part.
  // o: {code, stmts (from attribute), mark(i), box(i), pending(i), over, added, W, H, from (helpers defined before this
  //     offset, Mate's own pieces, are not listed), drawnOnly (parts list only what is drawn: marks still waiting for
  //     their line are left out)}
  const PIECE_CALLS = { graph: 1, timeline: 1, molecule: 1 };
  const SCENE_CONST = /^(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*scene3d\s*\(/;
  const HELPER_SIGNATURE = [/^function\s+([A-Za-z_$][\w$]*)\s*\(([^)]*)\)/, /^(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*(?:function\s*)?\(?([^)=]*?)\)?\s*=>/];
  const HELPER_NAME = [/^function\s+([A-Za-z_$][\w$]*)/, /^(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*(?:function\b|\(|[A-Za-z_$][\w$]*\s*=>)/];
  const firstMatch = (res, s) => { for (const re of res) { const m = re.exec(s); if (m) return m; } return null; };
  function describe(o) {
    const code = o.code || '', L = lineIndex(code), mark = o.mark, parts = [], helpers = [], figures = [], helperNames = new Set();
    let cur = null, section = null, carry = null, prevEnd = -1;   // the part being grown, the heading over the run, a heading waiting for code
    const newPart = p => { p.id = 'p' + (parts.length + 1); parts.push(p); return p; };
    for (const st of o.stmts || []) {
      const b = codeStart(code, st.s, st.e);
      if (b >= st.e) continue;
      const l0 = lineOf(L, b);
      let l1 = lineOf(L, Math.max(b, st.e - 1));
      while (l1 > l0 && (L[l1].blank || L[l1].full != null)) l1--;
      const body = code.slice(b, st.e).trim();
      // its heading: the whole-line comments just above it (a "Plan" comment is the program's own plan, not a heading)
      const head = [];
      for (let k = l0 - 1; k > prevEnd && k >= 0 && L[k].full != null; k--) head.unshift(L[k].full);
      const heading = head.filter(x => x && !/^plan\b/i.test(x)).join(' / ') || null;
      let blank = false;
      for (let k = prevEnd + 1; k < l0 - head.length; k++) if (L[k] && L[k].blank) blank = true;
      prevEnd = l1;
      const figure = SCENE_CONST.exec(body);
      if (figure) {
        let stage = null;
        for (let i = st.n0; i < st.n1 && !stage; i++) { const m = mark(i); if (m && m.do === 'stage3d') stage = m.id; }
        if (stage) figures.push({ name: figure[1], stage });
      }
      const fn = figure ? null : firstMatch(HELPER_SIGNATURE, body);
      if (fn && b >= (o.from || 0)) helpers.push(fn[1] + '(' + fn[2].replace(/\s+/g, ' ').trim() + ')');
      const named = firstMatch(HELPER_NAME, body);
      if (named) helperNames.add(named[1]);
      if (blank) { section = null; carry = null; }
      const ms = [];
      let edits = 0;
      for (let i = st.n0; i < st.n1; i++) { const m = mark(i); if (m && m.do === 'edit') edits++; else ms.push(i); }
      if (!ms.length) {                                   // drew nothing: an edit ends the part; a lone heading waits for code
        if (edits) { cur = null; carry = null; } else if (heading && !fn) carry = heading; else if (fn) carry = null;
        continue;
      }
      if (edits) cur = null;
      const own = heading || carry;
      carry = null;
      if (heading) section = heading;
      const tail = L[l1].tail || L[l0].tail, m0 = mark(ms[0]), step = m0 ? m0.step : null, turn = (m0 && m0.turn) || 1;
      if (ms.every(i => mark(i) && mark(i).do === 'text')) { for (const i of ms) cur = newPart({ marks: [i], step, turn, text: true, desc: null }); continue; }
      const call = /^[A-Za-z_$][\w$.]*\s*\(/.test(body) && !/^(for|if|while|switch)\b/.test(body) ? body.replace(/;$/, '') : null;
      const callee = call && /^([A-Za-z_$][\w$]*)\s*\(/.exec(call), piece = callee && (helperNames.has(callee[1]) || PIECE_CALLS[callee[1]]) ? callee[1] : null;
      const desc = own ? (tail ? own + ': ' + tail : own) : tail ? (section ? section + ': ' + tail : tail) : null;
      if (piece) {
        newPart({ marks: ms, step, turn, stmts: [{ call, n0: st.n0, n1: st.n1 }], piece, pieceText: firstWords(call), desc });
        cur = null;
        continue;
      }
      if (!cur || own || tail || cur.text || cur.tail || blank || cur.step !== step || cur.turn !== turn) cur = newPart({ marks: ms, step, turn, tail: !!tail, stmts: [], desc });
      else cur.marks.push(...ms);
      cur.stmts.push({ call, n0: st.n0, n1: st.n1 });
    }
    // what each part shows now (edits may have regrouped or erased its marks), its box and how much is still to draw
    const over = o.over || {}, box = o.box || (i => markBox(mark(i)));
    const all = parts.concat(o.added || []);
    for (const p of all) {
      const ov = over[p.id];
      if (ov) { p.marks = ov.marks.slice(); if (ov.desc) p.desc = ov.desc; p.text = false; }
      p.vis = p.marks.filter(i => mark(i) && !mark(i).__erased && !(o.drawnOnly && o.pending && o.pending(i)));
      p.box = unionBox(p.vis.map(box));
      p.pending = p.vis.filter(i => o.pending && o.pending(i)).length;
    }
    const texts = all.filter(p => p.vis.length === 1 && mark(p.vis[0]).do === 'text');
    for (const p of all) {
      const ms = p.vis.map(mark);
      // a highlight is named by the words it sits behind
      if (!p.desc && ms.length && p.box && ms.every(m => m.do === 'highlight')) {
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
  // first..last as a mark range: m3, or m3–m9
  const markRange = v => v.length > 1 ? `m${v[0]}–m${v[v.length - 1]}` : `m${v[0]}`;
  const marksCount = n => `${n} mark${n > 1 ? 's' : ''}`;
  // ids as ranges: p1–p62, x1
  function idRanges(ids) {
    const runs = [];
    for (const id of ids) {
      const m = /^([a-z]+)(\d+)$/.exec(id), last = runs[runs.length - 1];
      if (m && last && last.pre === m[1] && last.b + 1 === +m[2]) last.b = +m[2]; else runs.push(m ? { pre: m[1], a: +m[2], b: +m[2] } : { id });
    }
    return runs.map(r => r.id || (r.a === r.b ? r.pre + r.a : `${r.pre}${r.a}–${r.pre}${r.b}`)).join(', ');
  }
  // The card as short lines a model can read: every part with its id, what it is, its box and its marks. A card drawn
  // over several turns names each turn's steps "Turn 2, step 1". o.maxChars keeps it short: past it, parts list their
  // mark ranges only, then the oldest parts are summed up in one line.
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
        return `${marksCount(p.vis.length)} (${markRange(p.vis)})${words.length ? ', also says ' + words.slice(0, 4).join(', ') + (words.length > 4 ? ', …' : '') : ''}`;
      }
      if (o.brief) return `${marksCount(p.vis.length)} (${markRange(p.vis)})`;
      // a part made of several helper calls (flower(45, 410, 'pink'), ...) lists the calls, each with its marks
      if (p.stmts && p.stmts.length > 1 && !o.over[p.id] && p.stmts.every(t => t.call && t.n1 - t.n0 >= 3) && !p.vis.some(i => /3d$/.test((o.mark(i) || {}).do || ''))) {
        return p.stmts.map(t => { const v = p.vis.filter(i => i >= t.n0 && i < t.n1); return v.length ? `${clip(t.call, 44)} (m${v[0]}–m${v[v.length - 1]})` : null; }).filter(Boolean).join(' + ');
      }
      // Runs of alike marks are one entry: "3× rect fill sky (m4–m6)". A row of the same 3D part (hangers, rungs,
      // bolts) is one line with its id range, so a big figure still fits the card's words.
      const runs = [];
      for (const i of p.vis) {
        const m = o.mark(i), lab = m && m.do === 'part3d' ? 'part3d|' + describe3dPart(m, true) : markLabel(m), last = runs[runs.length - 1];
        if (last && last.lab === lab && m.do !== 'text' && last.b === i - 1) { last.b = i; last.n++; last.end = m; } else runs.push({ lab, a: i, b: i, n: 1, m, end: m });
      }
      return runs.map(r => r.lab.startsWith('part3d|')
        ? (r.n > 1 ? `${r.n}× ${r.m.id}–${r.end.id} ${r.lab.slice(7)} (m${r.a}–m${r.b})` : `${markLabel(r.m)} (m${r.a})`)
        : (r.n > 1 ? r.n + '× ' : '') + r.lab + (r.m.do === 'text' && p.vis.length > 1 ? ` "${clip(r.m.text, 30)}"` : '') + ` (m${r.a}${r.n > 1 ? '–m' + r.b : ''})`).join(' + ');
    };
    const skipped = new Set(o.skip || []);
    if (skipped.size) out.push(`(${skipped.size} older parts not listed: ${idRanges([...skipped].map(p => String(p.id)))})`);
    for (const p of d.parts) {
      if (!p.vis.length || skipped.has(p)) continue;
      const key = turnOf(p) + '/' + p.step, added = String(p.id).startsWith('x');
      if (p.step != null && !seen.has(key) && !added) {
        seen.add(key);
        const said = sayOf(turnOf(p), p.step);
        out.push(`${multi ? `Turn ${turnOf(p)}, step ${p.step}` : `Step ${p.step}`}${said ? ` · Mate said: "${clip(said, 170)}"` : ''}`);
      }
      if (added && !seen.has('x')) { seen.add('x'); out.push('Added by edits:'); }
      const waiting = p.pending ? (p.pending === p.vis.length ? ' (not drawn yet)' : ` (${p.pending} not drawn yet)`) : '';
      out.push(`  ${p.id} ${clip(p.desc, 70)} ${fmtBox(p.box)}: ${markList(p)}${waiting}`);
    }
    const newest = d.parts.filter(p => p.vis.length && !p.pending).slice(-1)[0];
    const tail = [];
    if (newest) tail.push(`newest part: ${newest.id}`);
    if (o.last) tail.push(`last changed: ${o.last}`);
    if (o.pointed) tail.push(`the user is pointing at: ${o.pointed}`);
    if (tail.length) out.push(tail.join(' · '));
    return out.join('\n');
  }

  // ================================================================ recolour and restyle a mark
  // A deeper shade of a colour, for the outline of a shape whose fill changed: the next tone down the palette, or the
  // colour at 62% brightness.
  const DARKER = { butter: 'orange', sun: 'orange', orange: 'brown', peach: 'coral', coral: 'red', red: '#A32A2E', pink: 'coral', lilac: 'violet', violet: '#4A3AA8', sky: 'blue', blue: '#173F8A',
    mint: 'leaf', leaf: '#2A6E40', brown: '#5E3A1F', tan: 'brown', cream: 'tan', white: 'grey', grey: 'ink', ink: 'ink' };
  // a colour as the program would name it: a tone, a known colour word ('Light Blue'), or what was given
  const normColor = c => { if (c == null) return c; const k = String(c).toLowerCase().replace(/[\s_-]+/g, ''); return TONES[k] ? k : COLOR_WORDS[k] || String(c).trim(); };
  function darker(c) {
    if (DARKER[c]) return DARKER[c];
    const h = /^#?([0-9a-f]{6})$/i.exec(TONES[c] || c || '');
    if (!h) return c;
    const v = parseInt(h[1], 16);
    return '#' + [v >> 16, (v >> 8) & 255, v & 255].map(x => Math.round(x * 0.62).toString(16).padStart(2, '0')).join('');
  }
  // the fields an edit can change, saved and put back for undo
  const FIELDS = ['tone', 'fill', 'fillAlpha', 'outline', 'style', 'size', 'weight', 'dash', '__dash', 'brush', 'alpha'];
  const snapOf = m => { const f = {}; for (const k of FIELDS) f[k] = k in m ? m[k] : undefined; return f; };
  const restoreOf = (m, f) => { for (const k of FIELDS) if (f[k] === undefined) delete m[k]; else m[k] = f[k]; };
  const CLOSED = ['circle', 'ellipse', 'rect', 'poly', 'path'];
  // color: the colour a mark is seen in (a filled shape's fill, whose outline follows a shade darker; otherwise its
  // ink); fill and line (or tone): exactly that part
  function recolorMark(m, op) {
    if (m.do === 'part3d') {
      // a 3D part's colour is its material's (tone and fill mean nothing inside a figure); the repaint sends the part
      // again under its id and the stage swaps it in place
      const c = op.color != null ? op.color : op.fill != null ? op.fill : op.line != null ? op.line : op.tone;
      if (c != null) m.material = Object.assign({}, m.material, { color: m.three ? realTone(normColor(c)) : tone(normColor(c)) });
      return;
    }
    const color = normColor(op.color), fill = normColor(op.fill), line = normColor(op.line != null ? op.line : op.tone);
    if (fill != null && m.do !== 'text' && m.do !== 'line' && m.do !== 'arrow') m.fill = fill;
    if (line != null) m.tone = line;
    if (color == null || fill != null || line != null) return;
    const filled = m.fill && m.fill !== 'none' && CLOSED.includes(m.do);
    if (!filled) { m.tone = color; return; }
    const ownOutline = m.tone && m.tone !== m.fill && m.outline !== false;
    m.fill = color;
    if (ownOutline) m.tone = darker(color);
  }
  const FONT_WORDS = { handwriting: 'hand', handwritten: 'hand', rounded: 'title', bold: 'title', plain: 'body', sans: 'body', typewriter: 'mono', code: 'mono' };
  const BRUSHES = ['pen', 'marker', 'pencil', 'brush'];
  function restyleMark(m, op) {
    const recolor = op.color != null || op.fill != null || op.line != null;
    // a 3D label's size is its words' size (15 to 28, as label() takes it), not a pen width
    if (m.do === 'label3d') {
      if (op.size != null && +op.size > 0) m.size = Math.max(15, Math.min(28, +op.size));
      if (recolor) recolorMark(m, op);
      return;
    }
    if (m.do === 'text') {
      // o.style is what the drawing guide teaches ('hand' | 'title' | 'body'); o.font is an older name for it
      const font = op.font != null ? op.font : op.style;
      if (font != null) m.style = FONT_WORDS[font] || font;
      if (op.size != null && +op.size > 0) m.size = Math.max(13, Math.min(72, +op.size));
      if (op.weight != null) m.weight = op.weight === 'bold' ? 700 : op.weight === 'normal' ? 400 : op.weight;
    } else {
      const w = op.width != null ? op.width : op.size;
      if (w != null && +w > 0) m.size = Math.max(1, Math.min(14, +w));
      if (op.dash != null) {
        const on = op.dash === false || op.dash === 'none' ? undefined : op.dash;
        if (m.do === 'line' || m.do === 'arrow') m.dash = on; else if (CLOSED.includes(m.do)) m.__dash = on;
      }
      if (op.brush != null && BRUSHES.includes(op.brush)) m.brush = op.brush;
    }
    if (recolor) recolorMark(m, op);
  }
  // What points at the user's screen (it means nothing once the screen changes) and what is a card (paper, a photo, a
  // 3D figure: it means the same over any screen). Free sketches are neither. A 3D figure's stage is a card: it was
  // checked as 'scene3d', a kind no mark has, so a lone figure was cleared with the screen like pointing ink.
  const POINTING_ROLES = new Set(['point', 'target', 'hover', 'type', 'ring', 'frame', 'underline', 'check', 'cross', 'strike',
    'scroll', 'label', 'num', 'connect', 'trace']);
  const pointsAtScreen = m => !!m && (POINTING_ROLES.has(m.role) || m.do === 'highlight');
  const isCardMark = m => !!m && (m.role === 'paper' || m.role === 'photo' || (m.do === 'image' && m.role !== 'source')
    || m.do === 'stage3d' || m.do === 'part3d' || m.do === 'label3d' || m.stage != null);
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
    pointsAtScreen, isCardMark, onCardTest,
    // the pen's geometry, for tests and tools
    geometry: { rng, catmull, densify, dashes, handSegments, ellipsePts, outline, evenOutline } };
})(typeof window !== 'undefined' ? window : globalThis);
