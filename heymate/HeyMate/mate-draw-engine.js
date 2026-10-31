// Mate's drawing engine. The model sends a drawing as data (marks) or as a small program that makes marks; this file
// runs the program, checks the layout, paces the pen to Mate's voice, and paints hand-drawn SVG: tapered pen strokes,
// wobbly shapes, watercolour fills, handwriting and highlighter, each revealed in drawing order.
//
//   render(spec, host, opts)   draws a whole program or list of marks at once
//   live(spec, host, opts)     draws a program as it streams in, each statement the moment it is whole; the drawing
//                              can be paced to speech, paused, continued in a new turn and edited in place
//   runCode, Session, statementEnds, attribute, exec    the program runner (also inside a Web Worker sandbox)
//   describe, stateText        the card as named parts and as short lines for a model (p1, p2 ... and m0, m1 ...)
//
// Mate's pieces (mate-draw-pieces.js) are written in this drawing language; mate-draw-native.js hosts the engine in
// the app, without a browser.
(function (global) {
  'use strict';
  const VERSION = '1.6';                                 // the drawing language's version, as hosts and reports name it
  // Mate's ink tones. Ink is a soft near-black (pure black read too hard on the cards); grey is the quieter text
  // colour (subtitles, labels, small numbers, sources).
  // Derived 2026-10-31 by scripts/drawing-palette.py: each tone keeps the hue family of the colour it names, its
  // lightness and chroma on fixed OKLCH steps (tones dark enough for words never lighter than the role needs).
  const TONES = {
    ink: '#2B2E34', white: '#FFFFFF', grey: '#7D8088', butter: '#FDDC5B', sun: '#FEC254', orange: '#FDA75D',
    peach: '#FDBCA6', coral: '#DC655F', red: '#D74745', pink: '#FD9CBA', lilac: '#9E91E4', violet: '#6B5AD4',
    sky: '#4BA3F7', blue: '#195CC7', mint: '#7AD59C', leaf: '#439458', brown: '#9A633B', tan: '#D6A270', cream: '#F6EED8'
  };
  // a tone's colour; any other colour as given; else the fallback, else ink
  const tone = (name, fallback) => TONES[name] || name || fallback || TONES.ink;
  // A figure()'s colour names mean the colours real things of that name have, as a photo shows them (painted steel,
  // brick, foliage, water): Mate's candy ink made a 3D model look like a toy. A hex the program gives is used as it is;
  // 2D marks and scene3d() keep TONES.
  const REAL_TONES = {
    ink: '#2B2E34', white: '#F1EEE6', grey: '#7C8088', butter: '#E5CC89', sun: '#D1A84B', orange: '#C46016',
    peach: '#CEA48C', coral: '#BD6254', red: '#97271B', pink: '#BF7883', lilac: '#9188B1', violet: '#5B4590',
    sky: '#7DA4C0', blue: '#234877', mint: '#90BA9E', leaf: '#46703D', brown: '#5F4025', tan: '#A98869', cream: '#E7DDC8'
  };
  const realTone = (name, fallback) => REAL_TONES[name] || name || fallback || REAL_TONES.ink;
  // Colour names a program uses besides the tone list ('green', 'gold', 'teal'). Passed into the runner so the
  // worker sandbox resolves them the same way; it has no closure over this file.
  const COLOR_WORDS = Object.assign(
    // everyday names for the tones
    Object.fromEntries([['sun', 'yellow gold golden'], ['violet', 'purple'], ['lilac', 'lavender'], ['leaf', 'green darkgreen'], ['mint', 'lightgreen lime'],
      ['sky', 'lightblue skyblue'], ['blue', 'darkblue navy'], ['ink', 'black'], ['grey', 'gray lightgrey lightgray'], ['cream', 'beige'],
      ['pink', 'rose magenta'], ['peach', 'salmon']].flatMap(([toneName, words]) => words.split(' ').map(w => [w, toneName]))),
    // and two blue-greens the tones do not cover
    { teal: '#319287', turquoise: '#17B6A8' });
  // A hex colour darkened by k (0 keeps it, 1 is black); anything that is not a hex colour comes back unchanged.
  const shade = (hex, k) => {
    const found = /^#?([0-9a-f]{6})$/i.exec(String(hex));
    if (!found) return hex;
    const v = parseInt(found[1], 16), keep = 1 - k;
    return '#' + [16, 8, 0].map(shift => Math.round(((v >> shift) & 255) * keep).toString(16).padStart(2, '0')).join('');
  };
  // how hand-drawn the pen is, 0 (ruler-straight) to 1 (full wobble); a cleaner 0.35 read like a chart tool
  const HAND = 1;
  // how long a frame takes to drag open like a selection (the app's spring settles a little after)
  const MARQUEE_DUR = 0.55;
  // the distance from one line of written words to the next, in font sizes (the handwriting's tall letters need room)
  const LINE_HEIGHT = 1.3;
  // Each brush's default width (canvas units) and ink opacity.
  const BRUSH = Object.fromEntries([['pen', 2.8, 1], ['marker', 8, 0.9], ['pencil', 1.8, 0.85], ['brush', 6, 0.95]].map(([name, size, alpha]) => [name, { size, alpha }]));
  // The faces text is set in. Everything Mate writes is one handwriting (Patrick Hand; titles are weight 600, which
  // the renderer draws bold since the face has one weight), including caps, a region's spaced-out name ("THE
  // HILL"). Name pills and badges on the real screen use the Mac's system font; the morning paper a newspaper serif.
  const HANDWRITING = "'Patrick Hand', cursive";
  const FONT = Object.assign(Object.fromEntries(['hand', 'title', 'body', 'mono', 'caps'].map(style => [style, HANDWRITING])),
    { ui: 'system-ui, sans-serif', serif: ['Georgia', "'Times New Roman'", 'serif'].join(', ') });
  // Library cards (generative widgets) are set in Barlow, not the handwriting: a card's program sets
  // global.__mateCardType = true before it draws, and screen drawings never do.
  const CARD_FACE = ["'Barlow'", 'sans-serif'].join(', ');
  const usesCardType = () => global.__mateCardType === true;
  const faceFor = style => (style !== 'ui' && usesCardType() ? CARD_FACE : FONT[style] || FONT.hand);

  // ---------------------------------------------------------------- seeded randomness: a drawing wobbles the same way every time
  // A string hash seeds a 32-bit linear congruential generator; each call gives the next number in [0, 1).
  function rng(seed) {
    let state = 0;
    for (const ch of String(seed)) state = (Math.imul(state, 31) + ch.charCodeAt(0)) >>> 0;
    return () => (state = (Math.imul(state, 1664525) + 1013904223) >>> 0) / 4294967296;
  }
  const dist = ([ax, ay], [bx, by]) => Math.hypot(bx - ax, by - ay);
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

  // How many screen points one canvas unit is (the host says, through __canvasUnitPoints; 1 when it does not).
  const unitPoints = () => (+global.__canvasUnitPoints > 0 ? +global.__canvasUnitPoints : 1);
  // ---------------------------------------------------------------- the pen's geometry
  // A smooth curve through the points: centripetal Catmull-Rom, so unevenly spaced points never loop or overshoot
  // (the plain, uniform kind kinks wherever a short span sits next to a long one). Each span gets one sample every 4
  // units, at least 2 and at most 3 * seg.
  function catmull(points, closed, maxSteps = 10) {
    points = distinct(points);
    if (closed && points.length > 2 && dist(points[0], points[points.length - 1]) < 1e-6) points.pop();
    if (points.length < 2) return [...points];
    if (!closed && points.length === 2) return densify(points, 12);
    const n = points.length, at = i => points[(i + n) % n];
    // an open curve's ends continue straight on, mirrored from their neighbours
    const before = closed ? at(-1) : lerp(points[1], points[0], 2), after = closed ? at(n) : lerp(points[n - 2], points[n - 1], 2);
    const P = closed ? [before, ...points, points[0], at(1)] : [before, ...points, after];
    const out = [];
    for (let i = 1; i + 2 < P.length; i++) {
      const [p0, p1, p2, p3] = P.slice(i - 1, i + 3);
      const knot = (a, b) => Math.max(Math.sqrt(dist(a, b)), 1e-4);
      const t1 = knot(p0, p1), t2 = t1 + knot(p1, p2), t3 = t2 + knot(p2, p3);
      const steps = Math.max(2, Math.min(maxSteps * 3, Math.ceil(dist(p1, p2) / 4)));
      for (let s = 0; s < steps; s++) {
        // Barry and Goldman's pyramid: three linear blends, then two, then one
        const t = t1 + (t2 - t1) * s / steps;
        const a1 = lerp(p0, p1, t / t1), a2 = lerp(p1, p2, (t - t1) / (t2 - t1)), a3 = lerp(p2, p3, (t - t2) / (t3 - t2));
        const b1 = lerp(a1, a2, t / t2), b2 = lerp(a2, a3, (t - t1) / (t3 - t1));
        out.push(lerp(b1, b2, (t - t1) / (t2 - t1)));
      }
    }
    out.push(closed ? points[0] : points[n - 1]);
    return out;
  }
  // the polyline with extra points so no span is longer than `step`
  function densify(line, step = 6) {
    const out = [line[0]];
    line.slice(1).forEach((to, k) => {
      const from = line[k], pieces = Math.max(1, Math.ceil(dist(from, to) / step));
      for (let s = 1; s <= pieces; s++) out.push(lerp(from, to, s / pieces));
    });
    return out;
  }
  // a centreline cut into dashes `on` long with `off` between them, cut exactly where the lengths run out
  function dashes(centre, on, off) {
    const line = densify(centre, 2), out = [];
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
  function handSegments(path, closed, rand, amount = 1, bow, jitter = 0) {
    const unit = unitPoints();
    if (jitter) path = path.map(p => [p[0] + (rand() * 2 - 1) * jitter / unit, p[1] + (rand() * 2 - 1) * jitter / unit]);
    const corners = closed ? [...path, path[0]] : path, out = [corners[0]];
    for (let i = 1; i < corners.length; i++) {
      const a = corners[i - 1], b = corners[i], len = dist(a, b) || 1, inPoints = len * unit;
      let bend;
      if (bow === 'pen') {
        const side = rand() < 0.5 ? -1 : 1, size = inPoints < 24 ? inPoints * 0.03 : Math.min(Math.max(inPoints * 0.03, 2), 7);
        bend = side * size * (0.6 + 0.4 * rand()) / unit * amount;
      } else bend = (rand() - 0.5) * Math.min(3.2, len * 0.03) * amount * HAND;
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
  function ellipsePts(cx, cy, rx, ry, rot, rand, wobble = 1, overshoot = true) {
    const count = Math.max(28, Math.round((rx + ry) / 2.2)), from = rand() * Math.PI * 2, sweep = Math.PI * 2 * (overshoot ? 1.06 : 1);
    const phase2 = rand() * 6, phase3 = rand() * 6, cos = Math.cos(rot), sin = Math.sin(rot), out = [];
    for (let i = 0; i <= count; i++) {
      const a = from + sweep * i / count;
      const k = 1 + wobble * HAND * (0.018 * Math.sin(a * 2 + phase2) + 0.012 * Math.sin(a * 3 + phase3)) + (overshoot ? 0.02 * wobble * i / count : 0);
      const [x, y] = [rx * k * Math.cos(a), ry * k * Math.sin(a)];
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
  function outline(centre, size, taper = 1) {
    centre = distinct(centre);
    if (centre.length < 2) return null;
    if (!taper) return evenOutline(centre, size / 2);           // taper 0: the even screen pen
    const along = [0];
    for (let i = 1; i < centre.length; i++) along.push(along[i - 1] + dist(centre[i - 1], centre[i]));
    const total = along[along.length - 1] || 1, ramp = Math.min(total * 0.3, size * 5) * taper || 1e-6;
    const [left, right] = strokeEdges(centre, i => {
      const u = along[i], press = Math.min(1, 0.35 + 0.65 * Math.min(u, total - u) / ramp);
      return size / 2 * press * (0.94 + 0.06 * Math.sin(u / 7));
    });
    return 'M' + joined(left) + ' L' + joined(right.reverse()) + ' Z';
  }
  // an even-width outline (half-width w) with a round cap at each end
  function evenOutline(centre, radius) {
    centre = distinct(centre);
    if (centre.length < 2) return null;
    const [left, right] = strokeEdges(centre, () => radius), n = centre.length;
    // half a circle round an end, from one edge to the other through the outside of the end
    const cap = (p, from, to) => {
      const out = [], a0 = Math.atan2(from[1] - p[1], from[0] - p[0]);
      let sweep = Math.atan2(to[1] - p[1], to[0] - p[0]) - a0;
      if (sweep > 0) sweep -= 2 * Math.PI;                   // always the clockwise way round, through the outside
      for (let k = 1; k < 8; k++) { const a = a0 + sweep * k / 8; out.push([p[0] + Math.cos(a) * radius, p[1] + Math.sin(a) * radius]); }
      return out;
    };
    const endCap = cap(centre[n - 1], left[left.length - 1], right[right.length - 1]), startCap = cap(centre[0], right[0], left[0]);
    return 'M' + joined([...left, ...endCap, ...right.reverse(), ...startCap]) + ' Z';
  }
  const poly = pts => 'M' + joined(pts);
  const plen = pts => { let total = 0; for (let i = 1; i < pts.length; i++) total += dist(pts[i - 1], pts[i]); return total; };

  // n + 1 evenly spaced points along an SVG path, measured by the browser
  function samplePath(d, samples = 120) {
    const probe = document.createElementNS('http://www.w3.org/2000/svg', 'path');
    probe.setAttribute('d', d);
    document.getElementById('__probe').appendChild(probe);
    const length = probe.getTotalLength(), out = [];
    for (let i = 0; i <= samples; i++) { const p = probe.getPointAtLength(length * i / samples); out.push([p.x, p.y]); }
    probe.remove();
    return out;
  }

  // ================================================================ running the model's programs
  // makeRunner closes over nothing outside itself, so the same source runs inside a Web Worker too.
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
    // How wide text will be, before the page measures it: Latin letters at the font's average width, and wide
    // characters (Hangul, CJK, full-width forms, emoji) a whole em each, so a Japanese label gets the room it needs.
    const WIDE = /[ᄀ-ᅟ⺀-꓏가-힣\uF900-﫿︰-﹏＀-｠￠-￦]|[\u{1F300}-\u{1FAFF}\u{20000}-\u{3FFFD}]/u;
    const glyphs = (s, px, average) => {
      let wide = 0, all = 0;
      for (const ch of String(s)) { all++; if (WIDE.test(ch)) wide++; }
      return (all - wide) * px * average + wide * px;
    };
    const textW = (s, size, style) => glyphs(s, size || 20, style === 'title' ? 0.56 : 0.47);
    // About n round tick values between a and b: a step of 1, 2, 2.5 or 5 times a power of ten, and each tick worked
    // out from its own index (adding the step over and over drifts on a long axis).
    function niceTicks(a, b, n) {
      n = n || 5;
      const lo = Math.min(a, b), hi = Math.max(a, b), span = hi - lo || 1, power = Math.pow(10, Math.floor(Math.log10(span / n)));
      const step = [1, 2, 2.5, 5, 10].map(k => k * power).find(s => span / s <= n) || 10 * power;
      const ticks = [];
      for (let i = Math.ceil(lo / step - 1e-9); i <= Math.floor(hi / step + 1e-9); i++) ticks.push(+(i * step).toFixed(10));
      return ticks;
    }
    // A number as an axis shows it: millions and tens of thousands short ("1.5M", "80k"), so a money axis fits.
    const inUnits = (v, unit, suffix) => {
      const q = v / unit;
      return String(+q.toFixed(Math.abs(q) < 10 && v % unit ? 1 : 0)) + suffix;
    };
    const fmt = v => {
      const size = Math.abs(v);
      if (size >= 1e6) return inUnits(v, 1e6, 'M');
      if (size >= 1e4) return inUnits(v, 1e3, 'k');
      return Number.isInteger(v) || size >= 100 ? String(Math.round(v)) : String(+v.toFixed(2));
    };
    const finite = p => Array.isArray(p) && [p[0], p[1]].every(v => isFinite(v));   // a point with both coordinates

    // Web addresses in card text. A markdown link "[label](url)" shows its label; a bare address up to 32 characters
    // shows as it is, a longer one as its site and "/…". Punctuation that ends a sentence is not part of the address.
    // The first address is kept (m.link) for the app to open when the text is clicked.
    const LONGEST_SHOWN = 32;
    const splitTrailing = url => {
      const m = /^(.*?)([.,;:!?]+)$/.exec(url);
      return m && m[1].length > 10 ? { url: m[1], trailing: m[2] } : { url, trailing: '' };
    };
    const shortAddress = url => {
      if (url.length <= LONGEST_SHOWN) return url;
      const site = url.replace(/^https?:\/\//i, '').split(/[/?#]/)[0].replace(/^www\./i, '');
      return site + (url.replace(/^https?:\/\/[^/?#]+/i, '').length > 1 ? '/…' : '');
    };
    function linkedText(value) {
      const hasAddress = typeof value === 'string' && /https?:\/\//i.test(value);
      if (!hasAddress) return { text: value };
      let first = null;
      const keep = url => { first = first || url; };
      const shown = value
        .replace(/\[([^\]\n]{1,80})\]\((https?:\/\/[^\s)]+)\)/gi, (_, label, url) => { keep(splitTrailing(url).url); return label; })
        .replace(/https?:\/\/[^\s)\]]+/gi, raw => { const { url, trailing } = splitTrailing(raw); keep(url); return shortAddress(url) + trailing; });
      return first ? { text: shown, link: first } : { text: value };
    }

    // The functions a program draws with, writing marks into sink (marks, says, warnings).
    function makeApi(w, h, sink) {
      // the step being drawn, the say() line waiting for its first mark, and the turn (0 before any __turn)
      let curStep = 1, cue = null, curTurn = 0;
      const { marks, says, warnings } = sink;
      const warn = s => { if (warnings.length < 40 && !warnings.includes(s)) warnings.push(s); };   // each once, at most 40
      // Every mark goes through here: the limits, then its step and turn, and the say() line it is drawn with (the
      // first mark after a say() takes it; edits don't).
      const push = (m, o) => {
        if (marks.length >= LIMIT) throw new Error(`too many marks (a drawing can have ${LIMIT})`);
        if (sink.deadline && Date.now() > sink.deadline) throw new Error('the program took too long to run');
        if (o && typeof o === 'object') Object.assign(m, o);
        if (m.step == null) m.step = curStep;
        if (curTurn && m.turn == null) m.turn = curTurn;
        if (cue && !m.say && m.do !== 'edit') { m.say = cue; cue = null; }
        marks.push(m);
        return m;
      };
      const mark = (kind, fields) => (o => push(Object.assign({ do: kind }, fields), o));
      const vec = {
        add: ([ax, ay], [bx, by]) => [ax + bx, ay + by], sub: ([ax, ay], [bx, by]) => [ax - bx, ay - by], mul: ([x, y], k) => [x * k, y * k],
        mid: ([ax, ay], [bx, by]) => [(ax + bx) / 2, (ay + by) / 2], along: ([ax, ay], [bx, by], t) => [ax + (bx - ax) * t, ay + (by - ay) * t],
        dist: ([ax, ay], [bx, by]) => Math.hypot(bx - ax, by - ay), angle: ([ax, ay], [bx, by]) => Math.atan2(by - ay, bx - ax),
        // the unit normal to a → b (turned a quarter to the left)
        perp: (a, b) => { const d = Math.hypot(b[0] - a[0], b[1] - a[1]) || 1; return [(a[1] - b[1]) / d, (b[0] - a[0]) / d]; },
        rotate: (p, c, a) => {
          const dx = p[0] - c[0], dy = p[1] - c[1], cos = Math.cos(a), sin = Math.sin(a);
          return [c[0] + dx * cos - dy * sin, c[1] + dx * sin + dy * cos];
        },
        polar: (cx, cy, r, a) => [cx + r * Math.cos(a), cy + r * Math.sin(a)],
      };
      const MATH = ['sin', 'cos', 'abs', 'min', 'max', 'sqrt', 'round', 'floor', 'ceil', 'trunc', 'sign', 'pow', 'exp', 'log', 'log2', 'log10',
        'hypot', 'atan2', 'atan', 'asin', 'acos', 'tan', 'sinh', 'cosh', 'tanh', 'cbrt'];
      const api = Object.assign({
        // The pieces set this when the app draws windows: a figure that would stand on paper gets a window instead.
        __card3d: null,
        W: w, H: h, PI: Math.PI,
      }, Object.fromEntries(MATH.map(k => [k, Math[k]])), vec, {
        lerp: (a, b, t) => a + t * (b - a), range: n => Array.from({ length: n }, (_, k) => k),
        step: n => { curStep = n; },
        say: s => {
          const line = { text: String(s), at: marks.length, step: curStep };
          if (curTurn) line.turn = curTurn;
          says.push(line); cue = s;
        },
        // older programs call these to mark what they looked at; they draw nothing
        seen() {}, noted() {},
        line: (pts, o) => mark('line', { pts })(o),
        curve: (pts, o) => mark('line', { pts, smooth: true })(o),
        circle: (x, y, r, o) => mark('circle', { at: [x, y], r })(o),
        ellipse: (x, y, rx, ry, o) => mark('ellipse', { at: [x, y], rx, ry })(o),
        rect: (x, y, w_, h_, o) => mark('rect', { at: [x, y], w: w_, h: h_ })(o),
        poly: (pts, o) => mark('poly', { pts })(o),
        path: (d, o) => mark('path', { d })(o),
        text: (x, y, words, o) => mark('text', Object.assign({ at: [x, y] }, linkedText(words)))(o),
        arrow: (pts, o) => mark('arrow', { pts })(o),
        dot: (x, y, r, o) => mark('dot', { at: [x, y], r })(o),
        image: (x, y, w_, h_, o) => mark('image', { at: [x, y], w: w_, h: h_ })(o),
        // a little window (title bar and board); the pieces draw them, programs are not taught to
        __window: (x, y, w_, h_, o) => mark('window', { at: [x, y], w: w_, h: h_ })(o),
        molecule: (smiles, x, y, w_, h_, o) => mark('molecule', { smiles, at: [x, y], w: w_, h: h_ })(o),
      });

      // Where ink already is (rough boxes, not the cards it sits on), so a piece drawn later can keep off it.
      const NOT_INK_ROLES = new Set(['paper', 'button', 'handoff', 'open']);
      const inkBox = m => {
        if (!m || m.do === 'window' || m.do === 'edit' || (/3d$/.test(m.do || '') && m.do !== 'stage3d') || NOT_INK_ROLES.has(m.role)) return null;
        if (m.do === 'dot' && m.fillAlpha === 0 && (+m.r || 0) <= 0.5) return null;   // an invisible anchor
        const pad = (+m.size || 3) / 2;
        if (Array.isArray(m.pts) && m.pts.length) {
          const ok = m.pts.filter(q => Array.isArray(q) && isFinite(q[0]) && isFinite(q[1]));
          if (!ok.length) return null;
          const xs = ok.map(q => q[0]), ys = ok.map(q => q[1]), x0 = Math.min(...xs), y0 = Math.min(...ys);
          return [x0 - pad, y0 - pad, Math.max(...xs) - x0 + 2 * pad, Math.max(...ys) - y0 + 2 * pad];
        }
        if (!Array.isArray(m.at)) return null;
        const [x, y] = m.at;
        if (m.do === 'circle' || m.do === 'dot') { const r = (+m.r || 3) + pad; return [x - r, y - r, 2 * r, 2 * r]; }
        if (m.do === 'ellipse') { const rx = (+m.rx || 0) + pad, ry = (+m.ry || 0) + pad; return [x - rx, y - ry, 2 * rx, 2 * ry]; }
        if (m.do === 'text') {
          const size = +m.size || 20, lines = String(m.text == null ? '' : m.text).split('\n');
          const natural = Math.max(...lines.map(t => glyphs(t, size, 0.5))), width = m.fit ? Math.min(+m.fit[0] || natural, natural) : natural;
          const left = x - (m.anchor === 'middle' ? width / 2 : m.anchor === 'end' ? width : 0);
          // the first line's alphabetic baseline is at y (for every baseline the renderer is given)
          return [left, y - size * 0.8, width, size * 1.05 * lines.length];
        }
        if (isFinite(+m.w) && isFinite(+m.h)) return [Math.min(x, x + +m.w), Math.min(y, y + +m.h), Math.abs(+m.w), Math.abs(+m.h)];
        return null;
      };
      api.__inkBoxes = () => marks.map(inkBox).filter(b => b && b.every(v => isFinite(v)) && b[2] > 0 && b[3] > 0);

      // ------------------------------------------------ a 3D figure's rectangle
      const fin = v => typeof v === 'number' && Number.isFinite(v);
      const r3 = v => Math.round(1000 * v) / 1000;          // three decimal places
      const v3 = (v, fallback) => (Array.isArray(v) && v.length >= 3 && fin(v[0]) && fin(v[1]) && fin(v[2]) ? [v[0], v[1], v[2]] : fallback);
      // An axis given as 'x', '-z' (any case, spaces allowed) or [x, y, z].
      const axis3 = (v, fallback) => {                      // an axis as 'x', '-z' or [x, y, z]
        const m = typeof v === 'string' ? /^\s*([+-]?)\s*([xyz])\s*$/i.exec(v) : null;
        if (!m) return v3(v, fallback);
        const a = [0, 0, 0];
        a['xyz'.indexOf(m[2].toLowerCase())] = m[1] === '-' ? -1 : 1;
        return a;
      };
      const pickKeys = (object, keys) => (object && typeof object === 'object' ? Object.fromEntries(keys.filter(k => object[k] !== undefined).map(k => [k, object[k]])) : {});
      // A material's colour names turned into colours (glow in Mate's own colours when glowOf is given).
      const tintMaterial = (material, colorOf, glowOf) => {
        if (material.color != null) material.color = colorOf(material.color);
        if (material.emissive != null) material.emissive = (glowOf || colorOf)(material.emissive);
        for (const k of ['bands', 'colors']) if (Array.isArray(material[k])) material[k] = material[k].map(colorOf);
        return material;
      };
      const MATERIAL_KEYS = ['color', 'roughness', 'metalness', 'emissive', 'emissiveIntensity', 'opacity', 'double', 'flat', 'bands', 'colors', 'glow'];
      let stages = 0;
      const stageRects = [];
      // A paper piece that would cover a figure moves to the nearest spot beside or above or below one that is on the
      // card, off every figure and no busier than where it was asked to go; if there is none it stays and covers it.
      api.clearOfFigures = (px, py, pw, ph) => {           // where a paper piece of this size at px, py should go
        const gap = 10;
        const overFigure = (ax, ay) => stageRects.some(([x, y, sw, sh]) => ax < x + sw + gap && ax + pw + gap > x && ay < y + sh + gap && ay + ph + gap > y);
        if (!overFigure(px, py)) return [px, py];
        const fits = (ax, ay) => ax >= 4 && ay >= 4 && ax + pw <= w - 4 && ay + ph <= h - 4 && !overFigure(ax, ay);
        const keptY = Math.min(Math.max(4, py), h - ph - 4);
        const candidates = stageRects.flatMap(([x, y, sw, sh]) => [
          [x + sw + gap, py], [x - pw - gap, py], [px, y + sh + gap], [px, y - ph - gap], [x + sw + gap, keptY], [x - pw - gap, keptY]]);
        const busyFor = hostCall('__busyFor'), busy = (ax, ay) => (busyFor ? busyFor(ax, ay, pw, ph) : 0);
        const asBusy = busy(px, py) + 0.006;
        const best = candidates.filter(([ax, ay]) => fits(ax, ay) && busy(ax, ay) <= asBusy)
          .sort((a, b) => Math.hypot(a[0] - px, a[1] - py) - Math.hypot(b[0] - px, b[1] - py))[0];
        warn(best ? 'a paper piece was moved off a 3D figure' : 'a paper piece covers a 3D figure (there was no calm spot beside it)');
        return best || [px, py];
      };
      // The window most of a rectangle (60% or more) lies in; the smallest such, when windows overlap.
      const windowAround = (x, y, w_, h_) => marks.reduce((best, m) => {
        if (!m || m.do !== 'window' || m.__erased || !Array.isArray(m.inner) || !Array.isArray(m.at)) return best;
        const [wx, wy] = m.at, ow = Math.min(x + w_, wx + m.w) - Math.max(x, wx), oh = Math.min(y + h_, wy + m.h) - Math.max(y, wy);
        if (ow <= 0 || oh <= 0 || ow * oh < 0.6 * w_ * h_) return best;
        return !best || m.w * m.h < best.w * best.h ? m : best;
      }, null);
      // How much of a rectangle is busy screen (text, controls): the share of its 64-pixel tiles over 0.02.
      const busyShare = (x, y, w_, h_) => {
        const busyFor = hostCall('__busyFor');
        let tiles = 0, busy = 0;
        for (let ty = y; ty < y + h_; ty += 64) for (let tx = x; tx < x + w_; tx += 64) {   // 64-pixel tiles
          tiles++;
          if (busyFor && busyFor(tx, ty, Math.min(64, x + w_ - tx), Math.min(64, y + h_ - ty)) > 0.02) busy++;
        }
        return tiles ? busy / tiles : 0;
      };
      // Where scene3d() and figure() stand: the stage3d mark. Over a window drawn on the card it stands in that window;
      // over busy screen (or with card: true) it gets a card of its own, or a window when the app draws windows;
      // otherwise it floats on the screen, its labels in ink that reads there. The app's figures always float.
      const standStage = (x, y, stageW, stageH, o, look) => {
        const sid = `st${++stages}`;
        const floatNow = hostCall('__figuresFloat'), floats = floatNow ? floatNow() === true : false;
        const host = floats ? null : windowAround(x, y, stageW, stageH);
        if (host) host.board = 'plain';
        const needsCard = !floats && !host && (o.card === true || (o.card !== false && busyShare(x, y, stageW, stageH) >= 0.08));
        stageRects.push([x, y, stageW, stageH]);
        const asWindow = needsCard && typeof api.__card3d === 'function';
        if (asWindow) api.__card3d(x, y, stageW, stageH, o);
        const inkFor = hostCall('__inkFor');
        const ink = needsCard || host ? MATE_HEX.ink : inkFor ? inkFor(x, y, stageW, stageH) : '#FFFFFF';
        const left = Math.max(4, x - 10), top = Math.max(4, y - 10);
        const card = [left, top, Math.min(w - 4, x + stageW + 10) - left, Math.min(h - 4, y + stageH + 10) - top];
        // a figure always turns a little (0.5 to 2): one standing still does not read as 3D
        const camera = { tilt: fin(o.tilt) ? Math.min(80, Math.max(-80, o.tilt)) : 15, fov: fin(o.fov) ? o.fov : 35, spin: fin(o.spin) ? Math.max(0.5, Math.min(2, o.spin)) : 0.7 };
        const stage = push({ do: 'stage3d', id: sid, at: [x, y], w: stageW, h: stageH, ink, card: needsCard && !asWindow ? card : null, cardWindow: host ? host.inner : undefined, camera });
        if (look) stage.look = look;
        return { sid, ink };
      };
      // The moves every 3D handle has: spin, bob, orbit, path and pulse, each a motion3d mark the stage runs.
      const bindMotions = (handle, target, sid) => {
        const move = (kind, fields) => push({ do: 'motion3d', stage: sid, op: Object.assign({ target: target.id, kind }, fields) });
        const or = (v, fallback) => (fin(v) ? v : fallback);
        Object.assign(handle, {
          spin(op) { op = op || {}; move('spin', { axis: axis3(op.axis, [0, 1, 0]), period: or(op.period, 6) }); return this; },
          bob(op) { op = op || {}; move('bob', { axis: axis3(op.axis, [0, 1, 0]), amount: or(op.amount, 0.1), period: or(op.period, 3) }); return this; },
          orbit(op) { op = op || {}; move('orbit', { axis: axis3(op.axis, [0, 1, 0]), center: v3(op.center, [0, 0, 0]), period: or(op.period, 8) }); return this; },
          path(points, op) {
            op = op || {};
            const stops = (points || []).map(p => v3(p, null)).filter(Boolean), once = op.once === true;
            if (stops.length >= 2) move('path', Object.assign({ points: stops, closed: !once && op.closed !== false, period: or(op.period, 6) }, once ? { once: true } : {}));
            return this;
          },
          pulse(op) { op = op || {}; move('pulse', { amount: fin(op.amount) ? Math.min(0.5, Math.max(-0.5, op.amount)) : 0.08, period: or(op.period, 1) }); return this; },
        });
        return handle;
      };
      // A surface from fn(u, v) → [x, y, z], sampled on a grid (segments across, rows down); the other options go on.
      const surfaceGrid = (fn, op) => {
        const { segments, rows: rowCount, u: uRange, v: vRange, ...rest } = op || {};
        const cols = Math.max(4, Math.min(160, segments || 80)), rows = Math.max(2, Math.min(80, rowCount || 16));
        const u = uRange || [0, 1], v = vRange || [0, 1];
        const grid = Array.from({ length: rows + 1 }, (_, j) => Array.from({ length: cols + 1 }, (_, i) =>
          v3(fn(u[0] + (u[1] - u[0]) * i / cols, v[0] + (v[1] - v[0]) * j / rows), [0, 0, 0]).map(r3)));
        return { rest, grid };
      };

      // scene3d(x, y, w, h, build, o): the older 3D call, parts with defaults for their sizes (figure() replaced it).
      api.scene3d = (x, y, stageW, stageH, build, o) => {
        o = o || {};
        if (![x, y, stageW, stageH].every(fin) || stageW < 24 || stageH < 24) { warn('scene3d() needs a place: x, y, width and height in pixels (at least 24 each way)'); return null; }
        const { sid, ink } = standStage(x, y, stageW, stageH, o);
        let parts = 0, labels = 0, group = null;
        const PLACING = ['at', 'rotate', 'scale', 'parent'].concat(MATERIAL_KEYS);
        const part = (kind, options) => {
          const p = Object.assign({}, options);
          const m = { do: 'part3d', id: `${sid}p${++parts}`, stage: sid, kind, pos: v3(p.at, [0, 0, 0]), rotate3: v3(p.rotate, [0, 0, 0]),
            scale3: fin(p.scale) ? p.scale : 1, material: tintMaterial(pickKeys(p, MATERIAL_KEYS), mateColor), parent: (p.parent && p.parent.id) || group };
          for (const k of PLACING) delete p[k];
          m.params = p;
          push(m);
          return bindMotions({ id: m.id, kind: 'part' }, m, sid);
        };
        const withDefaults = (kind, defaults) => op => part(kind, Object.assign({}, defaults, op));
        const inside = (parentId, fn) => { const outer = group; group = parentId; try { fn(s); } finally { group = outer; } };
        const s = {
          id: sid, kind: 'stage', box: [x, y, stageW, stageH],
          sphere: withDefaults('sphere', { r: 1 }), box: withDefaults('box', { size: [1, 1, 1], radius: 0 }), cylinder: withDefaults('cylinder', { r: 0.5, h: 1 }),
          cone: withDefaults('cone', { r: 0.5, h: 1 }), torus: withDefaults('torus', { r: 1, tube: 0.25 }), ring: withDefaults('ring', { inner: 1, outer: 1.5 }),
          capsule: withDefaults('capsule', { r: 0.3, h: 1 }),
          // a tube along points, a lathe's profile [[radius, y], ...], an extrusion of an SVG path
          tube: (points, op) => part('tube', { r: 0.08, closed: false, ...op, points: (points || []).map(p => v3(p, null)).filter(Boolean) }),
          lathe: (profile, op) => part('lathe', { ...op, profile: (profile || []).filter(p => Array.isArray(p) && fin(p[0]) && fin(p[1])) }),
          extrude: (d, op) => part('extrude', { depth: 0.3, unit: 0.01, ...op, d: String(d || '') }),
          surface(fn, op) {
            let built;
            try { built = surfaceGrid(fn, op); } catch (e) { warn(`surface(): its function threw (${e.message})`); return null; }
            return part('surface', Object.assign(built.rest, { grid: built.grid }));
          },
          group(fn, op) {
            const g = part('group', { ...op });
            if (typeof fn === 'function') inside(g.id, fn);
            return g;
          },
          camera(op) {
            op = op || {};
            const within = (v, lo, hi) => (fin(v) ? Math.min(hi, Math.max(lo, v)) : undefined);
            push({ do: 'camera3d', stage: sid, op: { tilt: within(op.tilt, -80, 80), fov: fin(op.fov) ? op.fov : undefined, spin: fin(op.spin) ? op.spin : undefined,
              target: v3(op.target, undefined), turn: within(op.turn, -180, 180) } });
          },
          label(point, text, op) {
            op = op || {};
            const words = String(text == null ? '' : text).trim();
            if (!words) return null;
            const onPart = !!(point && point.id);
            return push({ do: 'label3d', id: `${sid}l${++labels}`, stage: sid, point: onPart ? null : v3(point, [0, 0, 0]), follow: onPart ? point.id : null,
              text: words.slice(0, 60), side: op.side === 'left' || op.side === 'right' ? op.side : null,
              size: fin(op.size) ? Math.min(28, Math.max(15, op.size)) : 19, tone: op.tone || ink });
          },
          build(fn, op) {
            if (typeof fn === 'function') inside(op && op.parent && op.parent.id ? op.parent.id : group, fn);
            return s;
          },
          part: id => {
            const n = /^(?:st\d+)?p?(\d+)$/.exec(String(id == null ? '' : id).trim());
            return n ? bindMotions({ id: `${sid}p${n[1]}` }, { id: `${sid}p${n[1]}` }, sid) : null;
          },
        };
        if (typeof build === 'function') build(s);           // scene3d(x, y, w, h, s => { ... }) builds inside
        return s;
      };

      // ------------------------------------------------ figure(): a 3D model on its own stage, one part per call
      // Every part is one part3d mark: its kind and a recipe (canonical JSON) that mate-three-parts.js builds, where it
      // sits and how it is turned, its material, and the group it hangs from. Repeats (copies, around, mirror) are
      // marks of their own. The handle a call returns moves the part: outside a tick by motion3d marks (a short tween
      // or a set), inside one by the pose the stage reads every frame (sink.anim).
      const PART_KINDS = ['box', 'cyl', 'cylinder', 'cone', 'tube', 'lathe', 'sphere', 'torus', 'capsule', 'pipe', 'spring', 'gear', 'extrude', 'blob', 'poly', 'arrow'];
      const NOT_SHAPE = new Set(['at', 'pos', 'rot', 'rotate', 'scale', 'parent', 'name', 'mat', 'from', 'to', 'mirror', 'copies', 'around', 'cut']);
      const BETWEEN_POINTS = new Set(['cyl', 'cylinder', 'capsule', 'cone', 'tube']);
      const TURNS_ABOUT_AXIS = new Set(['cyl', 'cylinder', 'cone', 'tube', 'lathe', 'sphere', 'torus', 'capsule', 'spring', 'gear', 'poly', 'extrude']);
      // the axis a part is built along before it is turned (most stand up along y)
      const BUILT_ALONG = { gear: [0, 0, 1], extrude: [0, 0, 1] };
      const MATERIAL_NAMES = new Set(['steel', 'alu', 'aluminum', 'aluminium', 'titanium', 'chrome', 'brass', 'copper', 'gold', 'iron', 'black', 'rubber',
        'glass', 'water', 'wood', 'ceramic', 'paper', 'gloss', 'paint', 'plastic', 'soft', 'matte', 'metal', 'glow']);
      const dot3 = (a, b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
      const len3 = v => Math.hypot(v[0], v[1], v[2]);
      const turned = d => d.some(a => Math.abs(a) > 1e-6);

      // Quaternions [x, y, z, w], for turning copies about an axis and back into the stage's Euler angles (XYZ order).
      const Quat = {
        aboutAxis(axis, degrees) {
          const k = Math.sin(degrees * Math.PI / 360) / (len3(axis) || 1);
          return [axis[0] * k, axis[1] * k, axis[2] * k, Math.cos(degrees * Math.PI / 360)];
        },
        fromEuler(degrees) {
          // the product of the three turns, X first
          const [qx, qy, qz] = [0, 1, 2].map(i => { const a = [0, 0, 0]; a[i] = 1; return Quat.aboutAxis(a, degrees[i]); });
          return Quat.times(Quat.times(qx, qy), qz);
        },
        times([ax, ay, az, aw], [bx, by, bz, bw]) {
          return [aw * bx + ax * bw + ay * bz - az * by, aw * by - ax * bz + ay * bw + az * bx,
            aw * bz + ax * by - ay * bx + az * bw, aw * bw - ax * bx - ay * by - az * bz];
        },
        toEuler([x, y, z, w]) {
          // from the rotation matrix's entries; when the middle turn is a right angle the first takes all of the spin
          const r13 = 2 * (x * z + w * y), r23 = 2 * (y * z - w * x), r33 = 1 - 2 * (x * x + y * y);
          const r12 = 2 * (x * y - w * z), r11 = 1 - 2 * (y * y + z * z), r32 = 2 * (y * z + w * x), r22 = 1 - 2 * (x * x + z * z);
          const ry = Math.asin(Math.min(1, Math.max(-1, r13)));
          const locked = Math.abs(r13) >= 0.9999999;
          const rx = locked ? Math.atan2(r32, r22) : Math.atan2(-r23, r33), rz = locked ? 0 : Math.atan2(-r12, r11);
          return [rx, ry, rz].map(a => r3(a * 180 / Math.PI));
        },
        rotate([x, y, z, w], v) {
          // v + 2w(q × v) + 2 q × (q × v)
          const c = [2 * (y * v[2] - z * v[1]), 2 * (z * v[0] - x * v[2]), 2 * (x * v[1] - y * v[0])];
          return [v[0] + w * c[0] + (y * c[2] - z * c[1]), v[1] + w * c[1] + (z * c[0] - x * c[2]), v[2] + w * c[2] + (x * c[1] - y * c[0])];
        },
      };
      // A direction turned as the stage turns a part: about z, then y, then x.
      const turnVector = (degrees, v) => {
        const [ax, ay, az] = degrees.map(d => Math.PI * d / 180);
        const [x1, y1] = [v[0] * Math.cos(az) - v[1] * Math.sin(az), v[0] * Math.sin(az) + v[1] * Math.cos(az)];
        const [x2, z2] = [x1 * Math.cos(ay) + v[2] * Math.sin(ay), v[2] * Math.cos(ay) - x1 * Math.sin(ay)];
        return [x2, y1 * Math.cos(ax) - z2 * Math.sin(ax), y1 * Math.sin(ax) + z2 * Math.cos(ax)];
      };
      // A recipe as text that is the same for the same shape: keys sorted, numbers to 4 places, nothing that isn't data.
      const stableData = v => {
        if (typeof v === 'number') return Number.isFinite(v) ? Math.round(v * 1e4) / 1e4 : undefined;
        if (typeof v === 'string' || typeof v === 'boolean') return v;
        if (Array.isArray(v)) return v.map(x => { const s = stableData(x); return s === undefined ? null : s; });
        if (!v || typeof v !== 'object') return undefined;
        const out = {};
        for (const k of Object.keys(v).sort()) { const s = stableData(v[k]); if (s !== undefined) out[k] = s; }
        return out;
      };

      // The program rewrite writes __name3d("piston") just before `const piston = f.cyl(...)`; the next part made takes it.
      let nextPartName = null;
      api.__name3d = name => { nextPartName = typeof name === 'string' && name ? { name, at: marks.length } : null; };
      let figureTicks = 0;

      api.figure = (x, y, figW, figH, o) => {
        if (x && typeof x === 'object' && !Array.isArray(x)) {
          o = x; x = Math.round(w * 0.5); y = Math.round(h * 0.14); figW = Math.round(Math.min(620, w * 0.44)); figH = Math.round(Math.min(480, h * 0.66));
          warn('figure() takes x, y, width and height first; it was put on the right half of the card');
        }
        o = o || {};
        if (![x, y, figW, figH].every(fin) || figW < 24 || figH < 24) { warn('figure() needs a place: x, y, width and height in pixels (at least 24 each way)'); return null; }
        const { sid, ink } = standStage(x, y, figW, figH, o, 'studio');
        let parts = 0, labels = 0, group = null;
        const motion = (target, kind, fields) => push({ do: 'motion3d', stage: sid, op: { target: target.id, kind, ...fields } });
        const poseOf = id => { const all = sink.anim || (sink.anim = {}); return all[id] || (all[id] = {}); };

        // A part's handle. Each property reads what it was last set to (this frame's pose, else the last planned move,
        // else how the part was made) and sets it the way that fits: inside a tick the pose, outside a motion.
        const handleFor = m => {
          const handle = bindMotions({ id: m.id, kind: 'part', name: m.name || null }, m, sid);
          const planned = {};
          const current = key => { const pose = poseOf(m.id); return pose[key] != null ? pose[key] : planned[key]; };
          const set = (key, value, outsideTick) => {
            if (hostGlobal().__mateInTick3d === true) poseOf(m.id)[key] = value;
            else { planned[key] = value; outsideTick(); }
          };
          const tween = field => value => motion(m, 'tween', { [field]: value, period: 0.35 });
          const PROPS = {
            pos: { get: () => (current('pos') || m.pos || [0, 0, 0]).slice(), set: v => { const p = v3(v, null); if (p) set('pos', p, () => tween('to')(p)); } },
            rot: { get: () => (current('rot') || m.rotate3 || [0, 0, 0]).slice(), set: v => { const r = v3(v, null); if (r) set('rot', r, () => tween('rot')(r)); } },
            scale: { get: () => fin(current('scale')) ? current('scale') : (m.scale3 || 1), set: v => { if (fin(v) && v >= 0) set('scale', v, () => motion(m, 'set', { scale: v })); } },
            show: { get: () => current('show') !== false, set: v => set('show', !!v, () => motion(m, 'set', { show: !!v })) },
            glow: {
              get: () => current('glow') || 0,
              set: v => { if (!fin(+v)) return; const g = Math.min(1, Math.max(0, +v)); set('glow', g, () => motion(m, 'set', { glow: g })); },
            },
            color: {
              get: () => current('color') || (m.material && m.material.color) || null,
              set: v => { if (typeof v !== 'string' || !v) return; const c = realColor(v); set('color', c, () => motion(m, 'set', { color: c })); },
            },
          };
          for (const [key, prop] of Object.entries(PROPS)) Object.defineProperty(handle, key, Object.assign({ enumerable: true }, prop));
          return handle;
        };

        // ---- the steps from a call's options to its marks
        const takeName = p => {
          const pending = nextPartName && nextPartName.at === marks.length ? nextPartName.name : null;
          nextPartName = null;
          return typeof p.name === 'string' && p.name.trim() ? p.name.trim().slice(0, 40) : pending;
        };
        // mat: 'steel', 'glass:blue' (a material with a tint), 'glow:orange', or a colour (gloss in that colour)
        const materialOf = p => {
          const material = tintMaterial(pickKeys(p, MATERIAL_KEYS), realColor, mateColor);
          const matName = typeof p.mat === 'string' ? p.mat.trim() : '';
          if (matName) {
            const [name, tint] = p.mat.trim().toLowerCase().split(':').map(s => s.trim());
            const known = MATERIAL_NAMES.has(name);
            material.mat = known ? name : 'gloss';
            const colour = tint || (known ? null : name);
            if (colour) material.tint = name === 'glow' ? mateColor(colour) : realColor(colour);
          }
          return material;
        };
        // from/to: a round part stretched between two points (centred between them, its axis along them).
        const spanPoints = (kind, p, recipe, shape) => {
          const [from, to] = [v3(p.from, null), v3(p.to, null)];
          if (!from || !to || !BETWEEN_POINTS.has(kind)) return null;
          const d = [0, 1, 2].map(i => to[i] - from[i]), length = len3(d);
          Object.assign(shape, { from, to });
          if (length <= 1e-6) return null;
          recipe.h = length; recipe.axis = d.map(c => c / length);
          return [0, 1, 2].map(i => (from[i] + to[i]) / 2);
        };
        // An axis and a rot that both point the part the same way would turn it twice (a nozzle aimed at the sky):
        // keep one of them.
        const turnOnce = (kind, recipe, shape, rot, spanned, name) => {
          if (recipe.axis == null || !turned(rot) || !TURNS_ABOUT_AXIS.has(kind)) return rot;
          const axis = axis3(recipe.axis, null), length = axis ? len3(axis) : 0;
          if (length <= 1e-6) return rot;
          const unit = axis.map(c => c / length), base = BUILT_ALONG[kind] || [0, 1, 0], byRot = turnVector(rot, base);
          if (Math.abs(dot3(unit, base)) >= 0.999 || Math.abs(dot3(byRot, unit)) <= 0.999) return rot;
          warn(`${name || kind}: its axis and its rot both turn it the same way; turned it once`);
          if (spanned) return [0, 0, 0];
          if (kind === 'extrude') { delete recipe.axis; delete shape.axis; return rot; }
          recipe.axis = shape.axis = byRot.map(r3);
          return [0, 0, 0];
        };
        // scale: [x, y, z] means the figure's axes. A part turned by right angles has its own axes swapped about, so
        // each stretch moves to the part axis that now lies along that figure axis; any other turn keeps them as given.
        const stretchFor = (scale, rot) => {
          if (!scale || !turned(rot) || !rot.every(d => Math.abs(d / 90 - Math.round(d / 90)) < 1e-6)) return scale;
          return [0, 1, 2].map(i => {
            const own = [0, 0, 0]; own[i] = 1;
            const lies = turnVector(rot, own).findIndex(c => Math.abs(c) > 0.5);
            return scale[lies < 0 ? i : lies];
          });
        };
        // An arrow or a pipe given only its points sits at their middle, with the points relative to it.
        const centrePoints = (kind, p, recipe) => {
          if ((kind !== 'arrow' && kind !== 'pipe') || v3(p.at, null) || v3(p.pos, null) || !Array.isArray(recipe.points)) return null;
          const points = recipe.points.map(q => v3(q, null)).filter(q => q);
          if (points.length < 2) return null;
          const middle = [0, 1, 2].map(k => r3(points.reduce((sum, q) => sum + q[k], 0) / points.length));   // their average
          recipe.points = points.map(q => [0, 1, 2].map(k => r3(q[k] - middle[k])));
          return middle;
        };
        // cut: true (the half facing the viewer, along z), an axis, or {axis, at}: the part is drawn cut open there.
        const cutOpen = (p, material) => {
          const axis = p.cut === true ? 'z' : p.cut && typeof p.cut === 'object' ? (p.cut.axis || 'z') : p.cut;
          const normal = axis ? axis3(axis, null) : null;
          const length = normal ? len3(normal) : 0;
          if (length <= 1e-6) return;
          const n = normal.map(v => v / length), at = p.cut && typeof p.cut === 'object' && fin(p.cut.at) ? p.cut.at : 0;
          const facing = n[0] + n[1] + n[2] < 0 ? -1 : 1;
          material.cut = [...n.map(r3), r3(at * facing * Math.max(...n.map(Math.abs)))];
          if (p.cut === true) material.cutFacing = true;   // cut: true opens the side facing the viewer, as it turns
        };
        // Where the part and its repeats go: copies along a step, then all of those around an axis, then all of those
        // mirrored across each named plane (every combination of mirrors, once).
        const placesOf = (kind, p, pos, rot) => {
          let places = [{ pos, rotate3: rot, reflect: null }];
          if (kind === 'group') return places;
          if (p.copies && typeof p.copies === 'object') {
            const count = Math.min(200, Math.max(1, Math.round(fin(p.copies.count) ? p.copies.count : 1)));
            const step = v3(p.copies.step, [0, 0, 0]), turnEach = v3(p.copies.turn, [0, 0, 0]);
            for (let i = 1; i < count; i++) places.push({ pos: pos.map((v, k) => r3(v + step[k] * i)), rotate3: rot.map((v, k) => r3(v + turnEach[k] * i)), reflect: null });
          }
          if (p.around && typeof p.around === 'object') {
            const a = p.around, count = Math.min(240, Math.max(1, Math.round(fin(a.count) ? a.count : 1)));
            const axis = axis3(a.axis, [0, 1, 0]), centre = v3(a.center, [0, 0, 0]);
            const arc = fin(a.arc) ? Math.min(360, Math.max(-360, a.arc)) : 360, each = Math.abs(arc) >= 360 ? arc / count : arc / Math.max(1, count - 1);
            const ring = places.slice();
            for (let i = 1; i < count; i++) {
              const q = Quat.aboutAxis(axis, each * i);
              for (const b of ring) {
                const off = Quat.rotate(q, [0, 1, 2].map(k => b.pos[k] - centre[k]));
                places.push({ pos: off.map((v, k) => r3(v + centre[k])), rotate3: Quat.toEuler(Quat.times(q, Quat.fromEuler(b.rotate3))), reflect: null });
              }
            }
          }
          const planes = (Array.isArray(p.mirror) ? p.mirror : p.mirror ? [p.mirror] : [])
            .map(a => typeof a === 'string' ? a.trim().toLowerCase().replace(/^[+-]/, '') : null).filter(a => a === 'x' || a === 'y' || a === 'z');
          if (planes.length) {
            const flips = [];
            for (let set = 1; set < 1 << planes.length; set++) {
              const s = [1, 1, 1];
              planes.forEach((a, k) => { if (set & (1 << k)) s['xyz'.indexOf(a)] = -1; });
              if (!flips.some(f => f[0] === s[0] && f[1] === s[1] && f[2] === s[2])) flips.push(s);
            }
            const plain = places.slice();
            for (const s of flips) for (const b of plain) {
              // a mirror image's turn: each angle flips with the two axes it does not turn about
              const r = [b.rotate3[0] * s[1] * s[2], b.rotate3[1] * s[0] * s[2], b.rotate3[2] * s[0] * s[1]];
              places.push({ pos: b.pos.map((v, k) => r3(v * s[k])), rotate3: r.map(r3), reflect: s });
            }
          }
          return places;
        };

        const part = (kind, options) => {
          const p = Object.assign({}, options);
          const name = takeName(p);
          let pos = v3(p.at, null) ?? v3(p.pos, [0, 0, 0]);
          let rot = v3(p.rot, null) || v3(p.rotate, [0, 0, 0]);
          const material = materialOf(p);
          const shape = {};
          for (const k of Object.keys(p)) if (!NOT_SHAPE.has(k) && !MATERIAL_KEYS.includes(k)) shape[k] = p[k];
          const recipe = { ...shape };
          const middle = spanPoints(kind, p, recipe, shape);
          if (middle) pos = middle;
          rot = turnOnce(kind, recipe, shape, rot, !!middle || !!(v3(p.from, null) && v3(p.to, null)), name);
          const stretch = stretchFor(v3(p.scale, null), rot);
          if (stretch) recipe.stretch = stretch;
          pos = centrePoints(kind, p, recipe) || pos;
          cutOpen(p, material);
          const parent = (p.parent && p.parent.id) || group;
          let first = null;
          placesOf(kind, p, pos, rot).forEach((place, i) => {
            const own = place.reflect ? { ...recipe, mirror: place.reflect } : recipe;
            const m = { do: 'part3d', id: `${sid}p${++parts}`, stage: sid, kind, three: true, recipe: JSON.stringify(stableData(own)),
              pos: place.pos, rotate3: place.rotate3, scale3: fin(p.scale) ? p.scale : 1, material, parent };
            if (name) m.name = i === 0 ? name : `${name} ${place.reflect ? 'mirror' : i + 1}`;
            m.params = shape;
            push(m);
            const preview = hostCall('__shape3d');
            if (kind !== 'group' && preview) preview(kind, m.recipe);
            first = first || m;
          });
          return handleFor(first);
        };

        const f = { kind: 'figure', id: sid };
        for (const kind of PART_KINDS) f[kind] = options => part(kind === 'cylinder' ? 'cyl' : kind, options);
        f.arrow = (a, b) => (Array.isArray(a) ? part('arrow', Object.assign({}, b, { points: a })) : part('arrow', a || {}));
        f.surface = (fn, options) => {
          let built;
          try { built = surfaceGrid(fn, options); } catch (e) {
            warn(`surface(): its function threw (${e.message})`);
            if (nextPartName && nextPartName.at === marks.length) nextPartName = null;
            return null;
          }
          return part('surface', Object.assign(built.rest, { grid: built.grid }));
        };
        // Parts made inside build(g => ...) hang from the group (and turn and move with it).
        const inside = (parentId, fn) => { const outer = group; group = parentId; try { fn(f); } finally { group = outer; } };
        f.group = (a, b) => {
          const fn = typeof a === 'function' ? a : null;
          const g = part('group', Object.assign({}, fn ? b : a));
          if (fn) inside(g.id, fn);
          return g;
        };
        f.build = (fn, options) => {
          if (typeof fn === 'function') inside(options && options.parent && options.parent.id ? options.parent.id : group, fn);
          return f;
        };
        f.label = (point, text, options) => {
          options = options || {};
          const words = String(text == null ? '' : text).trim();
          if (!words) return null;
          const onPart = !!(point && point.id);
          return push({ do: 'label3d', id: `${sid}l${++labels}`, stage: sid, point: onPart ? null : v3(point, [0, 0, 0]), follow: onPart ? point.id : null,
            text: words.slice(0, 60), side: options.side === 'left' || options.side === 'right' ? options.side : null,
            size: fin(options.size) ? Math.min(28, Math.max(15, options.size)) : 19, tone: options.tone || ink });
        };
        f.tick = fn => {
          if (typeof fn !== 'function') { warn('tick() takes a function of the time: tick((t) => { part.pos = [...] })'); return null; }
          const m = push({ do: 'tick3d', id: `${sid}t${++figureTicks}`, stage: sid });
          sink.ticks = sink.ticks || {};
        sink.ticks[m.id] = fn;
          return { id: m.id };
        };
        // Up to six live numbers shown with the figure (a speed, a temperature); null takes one away.
        f.readout = values => {
          if (values == null || typeof values !== 'object') return f;
          const all = sink.readouts || (sink.readouts = {}), shown = all[sid] || (all[sid] = {});
          for (const k of Object.keys(values).slice(0, 6)) {
            if (values[k] == null) delete shown[k]; else shown[String(k).slice(0, 24)] = String(values[k]).slice(0, 32);
          }
          return f;
        };
        f.move = (target, options) => {
          options = options || {};
          if (!target || !target.id) { warn('move() needs the part to move'); return null; }
          const to = v3(options.to, null), rot = v3(options.rot, null);
          if (!to && !rot) return null;
          motion(target, 'tween', Object.assign({ period: fin(options.secs) ? Math.max(0.05, options.secs) : 0.8 }, to ? { to } : {}, rot ? { rot } : {}));
          return target;
        };
        const within = (v, lo, hi) => (fin(v) ? Math.min(hi, Math.max(lo, v)) : undefined);
        f.view = f.camera = options => {
          options = options || {};
          push({ do: 'camera3d', stage: sid, op: { tilt: within(options.tilt, -80, 80), fov: fin(options.fov) ? options.fov : undefined, spin: fin(options.spin) ? options.spin : undefined,
            target: v3(options.target, undefined), turn: within(options.turn, -180, 180), zoom: within(options.zoom, 0.5, 3) } });
          return f;
        };
        // A part made earlier, by its id ('st1p3', 'p3' or 3).
        f.part = id => {
          const n = /^(?:st\d+)?p?(\d+)$/.exec(String(id == null ? '' : id).trim());
          return n ? handleFor({ id: `${sid}p${n[1]}` }) : null;
        };
        return f;
      };

      // ------------------------------------------------ graph: axes in data units
      // graph(x, y, w, h, {x: [lo, hi], y: [lo, hi], ticks, xTicks, yTicks, grid, xLabel, yLabel}) draws the axes (they
      // cross at zero when zero is inside the ranges) and returns a graph to plot on in data units.
      api.graph = (frameX, frameY, frameW, frameH, o) => {
        o = o || {};
        const rangeOf = r => (Array.isArray(r) ? r : [0, 10]), xr = rangeOf(o.x), yr = rangeOf(o.y);
        const X = v => frameX + (v - xr[0]) / ((xr[1] - xr[0]) || 1) * frameW;
        const Y = v => frameY + frameH - (v - yr[0]) / ((yr[1] - yr[0]) || 1) * frameH;
        const at = (a, b) => (Array.isArray(a) ? [X(a[0]), Y(a[1])] : [X(a), Y(b)]);
        const ink = o.tone || 'ink';
        const xAxisY = yr[0] < 0 && yr[1] > 0 ? Y(0) : frameY + frameH, yAxisX = xr[0] < 0 && xr[1] > 0 ? X(0) : frameX;
        const tickList = (given, lo, hi) => {
          const values = Array.isArray(given) ? given : given === true || o.ticks ? niceTicks(lo, hi) : [];
          return values.map(t => (Array.isArray(t) ? [t[0], String(t[1])] : [t, fmt(t)]));
        };
        const xTicks = tickList(o.xTicks, xr[0], xr[1]), yTicks = tickList(o.yTicks, yr[0], yr[1]);
        const piece = { piece: 'graph' };
        const rule = (points, opts) => api.line(points, Object.assign({ smooth: false }, opts, piece));
        if (o.grid) {
          for (const [v] of xTicks) rule([[X(v), frameY], [X(v), frameY + frameH]], { tone: 'grey', size: 1.4, alpha: 0.4 });
          for (const [v] of yTicks) rule([[frameX, Y(v)], [frameX + frameW, Y(v)]], { tone: 'grey', size: 1.4, alpha: 0.4 });
        }
        api.arrow([[Math.min(frameX, yAxisX) - 6, xAxisY], [frameX + frameW + 12, xAxisY]], Object.assign({ tone: ink, size: 1.8, head: 8 }, piece));
        api.arrow([[yAxisX, Math.max(frameY + frameH, xAxisY) + 6], [yAxisX, frameY - 12]], Object.assign({ tone: ink, size: 1.8, head: 8 }, piece));
        // tick marks and their numbers; the zero where the axes cross is left to the crossing
        for (const [v, words] of xTicks) {
          if (v === 0 && yAxisX === X(0)) continue;
          rule([[X(v), xAxisY - 4], [X(v), xAxisY + 4]], { tone: ink, size: 1.6 });
          api.text(X(v), xAxisY + 22, words, Object.assign({ anchor: 'middle', size: 14, tone: 'grey' }, piece));
        }
        for (const [v, words] of yTicks) {
          if (v === 0 && xAxisY === Y(0)) continue;
          rule([[yAxisX - 4, Y(v)], [yAxisX + 4, Y(v)]], { tone: ink, size: 1.6 });
          api.text(yAxisX - 9, Y(v) + 5, words, Object.assign({ anchor: 'end', size: 14, tone: 'grey' }, piece));
        }
        if (o.xLabel) api.text(frameX + frameW + 12, xAxisY + (xTicks.length ? 48 : 30), o.xLabel, Object.assign({ anchor: 'end', size: o.labelSize || 18 }, piece));
        if (o.yLabel) api.text(yAxisX - 4, frameY - 24, o.yLabel, Object.assign({ anchor: 'start', size: o.labelSize || 18 }, piece));

        // The frame in data units, and the part of a segment inside it ([from, to] or null), clipped exactly: each
        // side of the frame limits how far along the segment (0..1) it can be.
        const frame = { x0: xr[0], x1: xr[1], y0: Math.min(yr[0], yr[1]), y1: Math.max(yr[0], yr[1]) };
        const inFrame = ([u, v]) => u >= frame.x0 - 1e-9 && u <= frame.x1 + 1e-9 && v >= frame.y0 - 1e-9 && v <= frame.y1 + 1e-9;
        const clipToFrame = (a, b) => {
          if (!(frame.x0 <= frame.x1)) return null;
          const d = [b[0] - a[0], b[1] - a[1]];
          let lo = 0, hi = 1;
          for (const [rate, room] of [[-d[0], a[0] - frame.x0], [d[0], frame.x1 - a[0]], [-d[1], a[1] - frame.y0], [d[1], frame.y1 - a[1]]]) {
            if (rate === 0) { if (room < -1e-9) return null; continue; }
            const t = room / rate;
            if (rate < 0) lo = Math.max(lo, t); else hi = Math.min(hi, t);
          }
          if (hi - lo < 1e-8) return null;
          return [[a[0] + d[0] * lo, a[1] + d[1] * lo], [a[0] + d[0] * hi, a[1] + d[1] * hi]];
        };
        // A run of data drawn as the pieces of it inside the frame: a gap (a missing value) or leaving the frame ends
        // a piece; coming back in starts a new one at the edge.
        const visibleRuns = rows => {
          const runs = [];
          let run = null;
          const close = () => { if (run) runs.push(run); run = null; };
          rows.forEach((p, k) => {
            if (!finite(p)) return close();
            const before = k > 0 && finite(rows[k - 1]) ? rows[k - 1] : null;
            if (!before) { if (inFrame(p)) run = [p]; return; }
            if (inFrame(before) && inFrame(p)) { (run = run || [before]).push(p); return; }
            const seen = clipToFrame(before, p);
            if (!seen) return close();
            if (!run) run = [seen[0]];
            run.push(inFrame(p) ? p : seen[1]);
            if (!inFrame(p)) close();
          });
          close();
          return runs;
        };
        // y at a data x along the rows (null where they don't reach it).
        const yAlong = rows => u => {
          for (let k = 1; k < rows.length; k++) {
            const a = rows[k - 1], b = rows[k];
            if (finite(a) && finite(b) && a[0] !== b[0] && (u - a[0]) * (u - b[0]) <= 0) return a[1] + (b[1] - a[1]) * (u - a[0]) / (b[0] - a[0]);
          }
          return null;
        };
        // The data point halfway along the line as drawn (by length on the card).
        const halfway = data => {
          const P = data.map(q => at(q)), seg = P.slice(1).map((q, k) => Math.hypot(q[0] - P[k][0], q[1] - P[k][1]));
          let left = seg.reduce((s, d) => s + d, 0) / 2;
          for (let k = 0; k < seg.length; k++) {
            if (seg[k] && left <= seg[k]) { const t = left / seg[k]; return [0, 1].map(i => data[k][i] + (data[k + 1][i] - data[k][i]) * t); }
            left -= seg[k];
          }
          return data[0] || [0, 0];
        };
        // Its label goes after the line's end (or before its start), turned inward when it would run off the card.
        const labelLine = (po, start, end, colour) => {
          const before = po.labelAt === 'start', anchorAt = before ? start : end, width = textW(po.label, 18);
          let lx = anchorAt[0] + (before ? -8 : 8), ly = anchorAt[1] + 6, anchor = before ? 'end' : 'start';
          if (!before && lx + width > w - 8) { lx = anchorAt[0] - 4; ly = anchorAt[1] - 14; anchor = 'end'; }
          if (before && lx - width < 8) { lx = anchorAt[0] + 4; ly = anchorAt[1] - 14; anchor = 'start'; }
          if (anchorAt[1] <= xAxisY && ly > xAxisY - 12) ly = anchorAt[1] - 12;
          api.text(lx, Math.min(h - 8, Math.max(22, ly)), po.label, Object.assign({ anchor, size: po.labelSize || 18, tone: po.labelTone || colour }, piece));
        };
        const draw = (rows, po, straight) => {
          rows = Array.isArray(rows) ? rows : [];
          const runs = visibleRuns(rows), data = rows.filter(finite);
          const tone = po.tone || 'blue', size = po.size || 4;
          for (const run of runs) if (run.length >= 2) api.line(run.map(q => at(q)), Object.assign({ tone, size, smooth: straight ? false : undefined, dash: po.dash }, piece));
          if (!runs.length) warn('graph: a line falls entirely outside the x and y ranges, so nothing of it is drawn');
          const lastRun = runs.length ? runs[runs.length - 1] : data, firstRun = runs.length ? runs[0] : data;
          const end = at(lastRun[lastRun.length - 1] || [0, 0]), start = at(firstRun[0] || [0, 0]);
          if (po.label) labelLine(po, start, end, tone);
          const y = yAlong(rows), mid = halfway(data);
          return { data, tone, size, straight, label: po.label, start, end, mid: at(mid), midData: mid, pts: data.map(q => at(q)), y,
            at: u => { const v = y(u); return v == null ? null : at(u, v); } };
        };

        const g = { box: { x: frameX, y: frameY, w: frameW, h: frameH }, origin: [yAxisX, xAxisY], x: X, y: Y, at };
        // plot(f) samples a function over the x range (or from..to); plot(points) joins [x, y] points, straight when there
        // are only a few of them (8 or fewer) unless straight or smooth says otherwise.
        g.plot = (f, po) => {
          po = po || {};
          if (typeof f === 'function') {   // a function of x, sampled
            const a = po.from != null ? po.from : xr[0], b = po.to != null ? po.to : xr[1], n = po.samples || 64;
            const rows = Array.from({ length: n + 1 }, (_, k) => {
              const u = a + (b - a) * k / n;
              let v;
              try { v = f(u); } catch (_) { v = NaN; }
              return isFinite(v) ? [u, v] : null;
            });
            return draw(rows, po, false);
          }
          if (Array.isArray(f)) return draw(f, po, po.smooth === true ? false : po.straight != null ? !!po.straight : f.length <= 8);
          warn('graph: plot() takes a function of x or a list of [x, y] points');
          return null;
        };
        g.line = (from, to, po) => g.plot([from, to], { straight: true, ...(po || {}) });
        // The same line moved by dx, dy in data units (a supply curve shifting), with an arrow showing the move.
        g.shift = (s, dx, dy, po) => {
          po = po || {};
          if (!s || !s.data) { warn('graph: shift() moves a line that plot() or line() returned'); return null; }
          const by = [dx || 0, dy || 0], data = s.data.map(([u, v]) => [u + by[0], v + by[1]]);
          const moved = draw(data, Object.assign({ size: s.size }, po, { tone: po.tone || s.tone }), s.straight);
          if (data.length && po.arrow !== false) {
            const from = halfway(s.data), a = at(from), b = at([from[0] + by[0], from[1] + by[1]]);
            const along = t => [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t];
            if (Math.hypot(b[0] - a[0], b[1] - a[1]) > 14) api.arrow([along(0.18), along(0.82)], Object.assign({ tone: po.arrowTone || 'ink', size: 3, head: 9 }, piece));
          }
          return moved;
        };
        // Where two lines first meet, in data units (the first segment of the first line that meets any of the second).
        g.cross = (s1, s2) => {
          if (!s1 || !s2 || !s1.data || !s2.data) { warn('graph: cross() takes two lines that plot() or line() returned'); return null; }
          const A = s1.data, B = s2.data, near = t => t >= -1e-9 && t <= 1 + 1e-9;
          for (let i = 1; i < A.length; i++) for (let j = 1; j < B.length; j++) {   // every pair of segments, in order
            const p = A[i - 1], q = B[j - 1], r = [A[i][0] - p[0], A[i][1] - p[1]], s = [B[j][0] - q[0], B[j][1] - q[1]];
            const across = r[0] * s[1] - r[1] * s[0];
            if (Math.abs(across) < 1e-12) continue;
            const pq = [q[0] - p[0], q[1] - p[1]], t = (pq[0] * s[1] - pq[1] * s[0]) / across, u = (pq[0] * r[1] - pq[1] * r[0]) / across;
            if (near(t) && near(u)) return [p[0] + r[0] * t, p[1] + r[1] * t];
          }
          warn('graph: the two lines do not meet within the graph');
          return null;
        };
        // A dot at a data point, with dashed guides to the axes, numbers on them, and a label, as asked.
        g.point = (a, b, po) => {
          if (Array.isArray(a)) [a, b, po] = [a[0], a[1], b];   // point([x, y], options)
          po = po || {};
          if (a == null || b == null || !isFinite(a) || !isFinite(b)) { warn('graph: point() was given no point (cross() may have found none)'); return null; }
          const [cx, cy] = at(a, b), tone = po.tone || 'ink';
          if (po.guides) {
            const guide = { tone: po.guideTone || 'grey', size: 2.4, dash: true };
            rule([[cx, cy], [cx, xAxisY]], guide); rule([[cx, cy], [yAxisX, cy]], guide);
          }
          api.dot(cx, cy, po.r || 6.5, Object.assign({ tone }, piece));
          const numberTone = po.tickTone || tone;
          if (po.xTick) api.text(cx, xAxisY + 24, po.xTick, Object.assign({ anchor: 'middle', size: 16, tone: numberTone }, piece));
          if (po.yTick) api.text(yAxisX - 10, cy + 5, po.yTick, Object.assign({ anchor: 'end', size: 16, tone: numberTone }, piece));
          if (po.label) api.text(cx + 12, cy - 12, po.label, Object.assign({ size: po.labelSize || 17, tone: po.labelTone || tone }, piece));
          return Object.assign([cx, cy], { data: [a, b] });
        };
        return g;
      };

      // ------------------------------------------------ timeline: dated marks, with room for a picture
      // timeline(x, y, width, events, o): events are [date, label, shown date] or {date | at, label | text, show}.
      // Numeric dates sit to scale (o.from..o.to, else their own range) unless o.even; others evenly. Marks too close
      // together are pushed apart. Each event gets a slot for a picture on its side of the line (o.slots: 'below',
      // 'alternate', else words below and slots above).
      api.timeline = (lineX, lineY, lineW, events, o) => {
        o = o || {};
        const list = (Array.isArray(events) ? events : []).map((e, i) => {
          if (Array.isArray(e)) return { date: e[0], label: e[1] == null ? '' : String(e[1]), show: e[2] };
          if (e && typeof e === 'object') return { date: e.date != null ? e.date : e.at != null ? e.at : i, label: String(e.label || e.text || ''), show: e.show };
          return { date: e, label: '' };
        });
        const n = list.length, tone = o.tone || 'ink', piece = { piece: 'timeline' };
        api.arrow([[lineX, lineY], [lineX + lineW, lineY]], Object.assign({ tone, size: 2, head: 9 }, piece));
        if (!n) { warn('timeline: it has no events'); return { marks: [], events: [], at: () => [lineX, lineY], slot: () => null }; }

        const numeric = list.every(e => typeof e.date === 'number' && isFinite(e.date));
        const inset = o.inset != null ? o.inset : Math.min(60, lineW / (2 * n)), span = lineW - 2 * inset - 12;
        const lo = !numeric ? 0 : o.from != null ? o.from : Math.min(...list.map(e => e.date));
        const hi = !numeric ? n - 1 : o.to != null ? o.to : Math.max(...list.map(e => e.date));
        const toScale = d => lineX + inset + (n === 1 && !(o.from != null && o.to != null) ? span / 2 : (d - lo) / ((hi - lo) || 1) * span);
        const evenly = i => lineX + inset + (n === 1 ? span / 2 : i * span / (n - 1));
        const xs = list.map((e, i) => (numeric && !o.even ? toScale(e.date) : evenly(i)));
        // at least minGap apart: pushed right in order of x, then pulled back from the end of the line
        const alternate = o.slots === 'alternate';
        const minGap = Math.min(o.minGap || (alternate ? 70 : 96), span / Math.max(1, n - 1));
        const byX = xs.map((_, i) => i).sort((a, b) => xs[a] - xs[b]);
        for (let k = 1; k < n; k++) xs[byX[k]] = Math.max(xs[byX[k]], xs[byX[k - 1]] + minGap);
        for (let k = n - 1; k >= 0; k--) xs[byX[k]] = Math.min(xs[byX[k]], k === n - 1 ? lineX + inset + span : xs[byX[k + 1]] - minGap);
        if (numeric && !o.even && xs.some((x, i) => Math.abs(x - toScale(list[i].date)) > 12)) warn('timeline: some dates were too close together to read, so their marks were moved apart');
        // the room around an event: the distance to its nearest neighbour (half the line for a lone event)
        const roomAt = i => {
          const sorted = byX.map(k => xs[k]), k = sorted.indexOf(xs[i]);
          const nearest = Math.min(k > 0 ? xs[i] - sorted[k - 1] : 1e9, k < n - 1 ? sorted[k + 1] - xs[i] : 1e9);
          return nearest > 1e8 ? lineW / 2 : nearest;
        };
        const labelSize = o.labelSize || 17, dateSize = o.dateSize || 18;
        const placed = list.map((e, i) => {
          const x = xs[i], wordsBelow = o.slots === 'below' ? false : alternate ? i % 2 === 0 : true;
          const slotBelow = alternate ? wordsBelow : o.slots === 'below';
          api.line([[x, lineY - 9], [x, lineY + 9]], Object.assign({ tone, size: 3, smooth: false }, piece));
          api.dot(x, lineY, 5.5, Object.assign({ tone: o.dotTone || 'coral' }, piece));
          const shown = e.show != null ? String(e.show) : numeric ? fmt(e.date) : String(e.date);
          const room = roomAt(i), labelW = Math.min(190, (alternate ? 1.85 : 0.96) * room), slotW = o.slotW || Math.min(150, (alternate ? 1.8 : 0.9) * room);
          const twoLines = e.label && textW(e.label, labelSize) > labelW - 6;
          const dateY = wordsBelow ? lineY + 30 : lineY - 18, labelY = wordsBelow ? lineY + (twoLines ? 64 : 56) : lineY - (twoLines ? 54 : 44);
          api.text(x, dateY, shown, Object.assign({ anchor: 'middle', size: dateSize, tone: o.dateTone || tone }, piece));
          if (e.label) api.text(x, labelY, e.label, Object.assign({ anchor: 'middle', size: labelSize, fit: [labelW - 6, 44] }, piece));
          // the picture slot: beside the line, further out when the slots alternate (clear of the words)
          const gap = alternate ? (slotBelow ? 90 : 92) : 16;
          const space = slotBelow ? h - 10 - (lineY + gap) : lineY - gap - 60;
          const slotH = o.slotH || Math.max(40, Math.min(alternate ? 110 : 150, space));
          const slotY = slotBelow ? lineY + gap : lineY - gap - slotH;
          return { date: e.date, label: e.label, x, y: lineY, at: [x, lineY], slot: { x: x - slotW / 2, y: slotY, w: slotW, h: slotH, cx: x, cy: slotY + slotH / 2 } };
        });
        // Where a date falls on the line, between the placed marks (and on past either end at the scale's rate).
        const atDate = d => {
          if (!numeric || typeof d !== 'number') { const k = list.findIndex(e => e.date === d); return k >= 0 ? [xs[k], lineY] : [lineX, lineY]; }
          const stops = byX.map(i => [list[i].date, xs[i]]), perUnit = span / ((hi - lo) || 1), first = stops[0], last = stops[stops.length - 1];
          if (d <= first[0]) return [first[1] - (first[0] - d) * perUnit, lineY];
          for (let k = 1; k < stops.length; k++) {
            const [d0, x0] = stops[k - 1], [d1, x1] = stops[k];
            if (d <= d1) return [x0 + (x1 - x0) * (d - d0) / ((d1 - d0) || 1), lineY];
          }
          return [last[1] + (d - last[0]) * perUnit, lineY];
        };
        return { marks: placed, events: placed, at: atDate, slot: i => (placed[i] ? placed[i].slot : null), start: [lineX, lineY], end: [lineX + lineW, lineY] };
      };

      // ------------------------------------------------ edits of what is already on the card
      // A program changes what it drew earlier with these: each is an edit mark the editor runs at its beat. A part is
      // named "p3" (a bare number means a part too), a mark "m4" or by its own id.
      const partId = x => (typeof x === 'number' ? `p${x}` : String(x));
      const ids = id => (Array.isArray(id) ? id.map(partId) : id == null ? '' : partId(id));
      const NEEDS_NO_ID = new Set(['startOver', 'turn']);
      const edit = op => {
        if (!op.id && !NEEDS_NO_ID.has(op.op)) warn(`${op.op}() needs to be told what to change: a part id like "p3"`);
        return push({ do: 'edit', op });
      };
      const options = o => (o && typeof o === 'object' ? o : {});
      Object.assign(api, {
        erase: id => edit({ op: 'erase', id: ids(id) }),
        recolor: (id, c) => edit({ ...(c && typeof c === 'object' ? c : { color: c }), op: 'recolor', id: ids(id) }),
        restyle: (id, o) => edit({ ...options(o), op: 'restyle', id: ids(id) }),
        move: (id, dx, dy) => edit({ op: 'move', id: ids(id), dx: +dx || 0, dy: +dy || 0 }),
        moveTo: (id, x, y) => edit({ op: 'moveTo', id: ids(id), x: +x, y: +y }),
        scale: (id, k) => edit({ op: 'scale', id: ids(id), k: +k }),
        // highlight(x, y, w, h) swipes a highlighter over an area; highlight(id, colour) marks something drawn
        highlight: (a, b, c, d, o) => (typeof a === 'number' ? push({ do: 'highlight', at: [a, b], w: c, h: d }, o)
          : edit({ op: 'highlight', id: ids(a), color: b && typeof b === 'object' ? b.color : b })),
        startOver: () => edit({ op: 'startOver' }),
        // a new turn on the same card (the host writes these): its steps count from 1 again
        __turn: (n, keep) => {
          curTurn = +n || curTurn + 1; curStep = 1; cue = null;
          return edit({ op: 'turn', turn: curTurn, keep: keep == null ? null : +keep });
        },
      });
      let seed = 20260925;
      api.Math = Object.create(Math, { random: { value: () => ((seed = (seed * 1664525 + 1013904223) >>> 0) / 4294967296) } });
      api.random = api.Math.random;
      for (const t of TONE_NAMES) if (!(t in api)) api[t] = t;
      return api;
    }
    // A mark as plain data (functions and symbols left out), so it can be posted from a worker or handed to a page.
    function clean(m) {
      const data = {};
      for (const k in m) { const v = m[k]; if (typeof v !== 'function' && typeof v !== 'symbol') data[k] = v; }
      return data;
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
        // on past white space and comments to the statement itself
        for (let moved = true; moved;) {
          moved = false;
          while (i < src.length && /\s/.test(src.charAt(i))) i++;
          const close = src.startsWith('//', i) ? '\n' : src.startsWith('/*', i) ? '*/' : null;
          if (close) {
            const j = src.indexOf(close, i + 2);
            i = j < 0 ? src.length : close === '\n' ? j : j + 2;
            moved = true;
          }
        }
        if (i < copied || i >= src.length) continue;       // two starts can lead to the same statement (a comment block before it)
        const head = src.slice(i, i + 160);
        out += src.slice(copied, i);
        copied = i;
        // a figure part kept in a variable (const piston = f.cyl(...)) is named after it
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
    function runCode(code, width, height, options) {
      const ro = options || {};
      const sink = { marks: [], says: [], warnings: [], ticks: {}, anim: {}, deadline: ro.budgetMs ? Date.now() + ro.budgetMs : 0 };
      const api = makeApi(width, height, sink), { marks } = sink;
      let error = null, fn = null;
      try { fn = compile(wholeProgram(code, api, ro.knownEnds)); }
      catch (e) {
        // the longest run of whole statements that does parse
        const ends = statementEnds(`${code}\n`);
        for (let k = ends.length - 1; k >= 0 && !fn; k--) {
          const kept = code.slice(0, ends[k]);
          try {
            fn = compile(wholeProgram(kept, api));
            error = `the code does not parse after line ${kept.split('\n').length}: ${e.message}`;
          } catch (_) { /* shorter still */ }
        }
        if (!fn) error = `the code does not parse: ${e.message}`;
      }
      if (fn) {
        try { fn(api); }
        catch (e) {
          const line = errorLine(e), where = line > 0 && line <= code.split('\n').length ? ` at line ${line}` : '';
          error = `the code failed${where}: ${e && e.message !== undefined ? e.message : e}`;
        }
      }
      if (error) error = `${error} (the ${marks.length} marks made before that stay)`;
      Object.assign(marks, { error, says: sink.says, warnings: sink.warnings });
      // figure() tick functions and the poses they set, for a run that keeps going (Session, full mode)
      const { ticks, anim } = sink;
      Object.defineProperty(marks, 'live3d', { value: { ticks, anim }, enumerable: false });
      return marks;
    }

    // A program run as it streams in: each new run of complete statements is evaluated once, in one scope that lasts
    // (a generator paused inside `with (api)`, fed code to eval). A syntax error before the program is done only means
    // more code is coming. Any other error switches to running the whole program so far from the start on every update
    // ('full'), which draws exactly what render() would. update() returns what is new since the last call.
    function Session(w, h, so) {
      so = so || {};
      const budget = so.budgetMs || 0;                  // ms a run may take (0: no limit)
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
        sink.deadline = budget && Date.now() + budget;
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
      // live3d: this run's figure() tick functions and the poses they set (mateCanvas.tick3d runs them)
      return { update, get mode() { return mode; }, get fellBack() { return fellBack; }, get code() { return ran; }, get live3d() { return { ticks: sink.ticks, anim: sink.anim }; } };
    }
    // Which top-level statement made which marks, run the way live() runs them. [{s, e, n0, n1}]: each statement's
    // character span and the indices of the marks it drew.
    function attribute(code, width, height) {
      const run = Session(width, height), all = statementEnds(`${code}\n;`), out = [];
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
    function exec(base, frag, width, height, budgetMs) {
      const run = Session(width, height, { budgetMs });
      run.update(base, true);
      return run.update(`${base}\n;\n${frag}\n`, true);   // ; ends the program's last statement whatever it was
    }
    return { statementEnds, statementScanner, runCode, Session, clean, attribute, exec, textW };
  }
  const RUNNER = makeRunner(Object.keys(TONES), TONES, REAL_TONES, COLOR_WORDS);
  const { statementEnds, textW } = RUNNER;
  const runCode = (...args) => RUNNER.runCode(...args);

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
    self.addEventListener('message', ({ data }) => {
      const q = data || {}, job = jobs[q.type];
      if (!job) return;
      try { post(job(q)); }
      catch (e) {
        // the reply the job would have sent, carrying the error ('failed' when the sandbox could not even start)
        const type = q.type === 'init' ? 'failed' : q.type === 'run' ? 'result' : q.type;
        post({ type, id: q.id, marks: [], says: [], warnings: [], error: `the sandbox failed: ${e && e.message !== undefined ? e.message : e}` });
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
      WORKER_URL = WORKER_URL || URL.createObjectURL(new Blob([workerSource()], { type: 'text/javascript' }));
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
    const limit = o.timeLimit || 1500;                   // ms a run may take
    let ready = false, inflight = null, waiting = null, dead = false, timer = null, id = 0;
    const stop = () => { dead = true; clearTimeout(timer); w.terminate(); };
    const kill = error => { if (dead) return; stop(); onResult({ marks: [], says: [], warnings: [], error }, true); };
    const arm = (ms, error) => { clearTimeout(timer); timer = setTimeout(() => kill(error), ms); };
    function next() {
      if (dead || !ready || inflight || !waiting) return;
      inflight = waiting; waiting = null;
      w.postMessage({ type: 'run', id: ++id, code: inflight.code, done: inflight.done });
      arm(limit, `the drawing program was stopped after ${limit} ms (what it drew until then stays)`);
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
    w.onerror = e => kill(`the sandbox failed: ${e.message || 'for an unknown reason'}`);
    w.postMessage({ type: 'init', w: W, h: H, budgetMs: budgetOf(limit) });
    arm(START_LIMIT, `the drawing sandbox took more than ${START_LIMIT} ms to start`);
    return { run: (code, done) => { waiting = { code, done }; next(); }, stop, sandboxed: true };
  }
  // One job ('exec' or 'attrib') in a fresh throwaway worker, with the same limits as the drawing's own worker.
  function sandboxJob(msg, ms) {
    const limit = ms || 1500;
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
  const PEN = {
    per: 600, base: 0, min: 0.14, max: 0.7,              // seconds: base + length / per, kept between min and max
    ease: null, halo: null, wash: true, washMaxArea: Infinity,
  };
  const penDur = length => { const t = PEN.base + length / PEN.per; return Math.max(PEN.min, Math.min(PEN.max, t)); };
  function setPen(o) {
    if (o) {
      for (const k of ['per', 'min', 'max', 'washMaxArea']) if (typeof o[k] === 'number' && o[k] > 0) PEN[k] = o[k];
      if (Number.isFinite(o.base)) PEN.base = o.base;     // (a NaN base used to get in and stop every stroke)
      // given at all: ease is a CSS timing curve (else the default), halo a table of halos (else none), wash on unless false
      if (Object.prototype.hasOwnProperty.call(o, 'ease')) PEN.ease = typeof o.ease === 'string' ? o.ease : null;
      if (Object.prototype.hasOwnProperty.call(o, 'halo')) PEN.halo = o.halo && typeof o.halo === 'object' ? { ...o.halo } : null;
      if (Object.prototype.hasOwnProperty.call(o, 'wash')) PEN.wash = o.wash !== false;
    }
    return { ...PEN };
  }
  // Steps are counted per turn (a continued drawing starts its steps again), so a step is known by both.
  const stepKey = m => (m && m.turn ? `${m.turn}/${m.step}` : m && m.step);

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
  function natural(m) {
    const time = naturalAlone(m);
    return m && m.together ? { dur: time.dur, adv: 0 } : time;
  }
  const MARK_TIME = { dot: [0.25, 0.06], stage3d: [0.35, 0.12], image: [0.5, 0.3], window: [0.45, 0.3], part3d: [0.65, 0.12], motion3d: [0, 0], camera3d: [0, 0], tick3d: [0, 0] };
  const plainTime = dur => ({ dur, adv: dur * 0.7 });
  const textTime = s => { const n = letters(s); return { dur: 0.4 + n * 0.015, adv: (0.35 + n * 0.012) * 0.7 }; };
  function naturalAlone(m) {
    if (!m || typeof m !== 'object') return plainTime(0.3);
    const fixed = MARK_TIME[m.do], outlined = m.outline !== false;
    if (fixed) return { dur: fixed[0], adv: fixed[1] };
    switch (m.do) {
      // an edit lasts as long as its animation (worked out from what it touches when the stream planned it)
      case 'edit': { const span = m.__est != null ? m.__est : editEstimate(m.op, null); return { dur: span, adv: span }; }
      case 'text': case 'label3d': return textTime(m.text);
      case 'line':
        if (m.dash && Array.isArray(m.marquee)) return { dur: MARQUEE_DUR, adv: MARQUEE_DUR * 0.8 };
        return plainTime(m.dash ? Math.min(0.9, 0.2 + strokeLength(m.pts) / 900) : penDur(strokeLength(m.pts)));
      case 'arrow': { const d = penDur(strokeLength(m.pts)); return { dur: d + 0.16, adv: d + 0.1 }; }
      case 'circle': case 'ellipse': { const rx = +(m.r || m.rx) || 10, ry = +(m.r || m.ry) || 10; return plainTime(outlined ? penDur(Math.PI * (rx + ry) * 1.06) : 0.3); }
      case 'rect': return plainTime(outlined ? penDur(2 * (Math.abs(+m.w || 0) + Math.abs(+m.h || 0))) : 0.3);
      case 'poly':
        // a marquee frame's tint opens together with its outline
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
  const ERASE_DUR = 0.4, REPAINT_PACE = 0.55, GLIDE_DUR = 0.5;
  // Erasing several marks starts each a little after the last: 0.05 s apart (0.03 when brisk), all of them within
  // 0.5 s (0.3).
  const STAGGER = { usual: [0.05, 0.5], brisk: [0.03, 0.3] };
  const eraseStagger = (n, brisk) => {
    if (n <= 1) return 0;
    const [each, within] = brisk ? STAGGER.brisk : STAGGER.usual;
    return Math.min(each, within / (n - 1));
  };
  const erasing = (n, brisk) => ERASE_DUR + eraseStagger(n, brisk) * (n - 1);
  function editEstimate(op, touched) {
    const kind = op && op.op, n = touched ? touched.length : null;
    if (kind === 'turn') return 0;
    // nothing to change: it takes next to no time in its beat
    if (n === 0) return kind === 'startOver' ? 0.02 : 0.05;
    switch (kind) {
      case 'erase': return n == null ? 0.6 : erasing(n, false);
      case 'startOver': return n == null ? 0.7 : erasing(n, true);
      case 'move': case 'moveTo': case 'scale': return GLIDE_DUR;
      case 'highlight': return 0.6;
      case 'recolor': case 'restyle': {
        if (!touched) return 0.6;
        let t = 0, end = 0;
        for (const m of touched.filter(Boolean)) {
          const { dur, adv } = natural(m);
          end = Math.max(end, t + dur * REPAINT_PACE);
          t += adv * REPAINT_PACE;
        }
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
    const at = Array.isArray(m.at) && m.at;
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
      const inEllipse = (px, py) => { const u = (px - cx) / rx, v = (py - cy) / ry; return u * u + v * v <= 1; };
      return { kind: 'round', b: [cx - rx, cy - ry, cx + rx, cy + ry], area: Math.PI * rx * ry, inside: inEllipse };
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
    const at = Array.isArray(m.at) ? m.at : null;
    if (!at) return [];
    if (['rect', 'highlight', 'molecule', 'stage3d', 'image', 'window'].includes(m.do)) return [at, [at[0] + (+m.w || 0), at[1] + (+m.h || 0)]];
    if (m.do === 'circle' || m.do === 'ellipse') {
      const rx = +(m.r || m.rx) || 0, ry = +(m.r || m.ry) || 0;
      return [[at[0] - rx, at[1] - ry], [at[0] + rx, at[1] + ry]];
    }
    return [at];
  }
  // a mark moved by (dx, dy); with `only`, just the points it picks (a line keeps the end that is outside a moved box)
  function shiftMark(m, dx, dy, only) {
    const moved = p => (only && !only(p) ? p : [p[0] + dx, p[1] + dy]);
    if (Array.isArray(m.at)) m.at = moved(m.at);
    if (Array.isArray(m.pts)) m.pts = m.pts.map(p => (Array.isArray(p) ? moved(p) : p));
    if (m.do === 'path') { const [sx, sy] = m.shift || [0, 0]; m.shift = [sx + dx, sy + dy]; }
  }
  function Layout(W, H) {
    // containers (closed shapes big enough to hold words), text boxes, points along strokes [x, y, i] and the boxes of
    // other shapes: what is on the paper so far
    const cons = [], texts = [], ink = [], areas = [], warnings = [];
    let group = null, overlaps = 0, moved = 0, covered = 0, n = 0;   // group: the box just moved, whose step follows it
    // what an edit erased (or a new turn dropped) is no longer on the paper; startOver clears it all
    // in place (the lists are shared), and without spreading: a long drawing's ink list is tens of thousands of points
    const prune = (list, gone) => { const kept = list.filter(x => !gone(x)); list.length = 0; for (const x of kept) list.push(x); };
    function forget(indices) {
      const set = indices instanceof Set ? indices : new Set(indices || []);
      if (!set.size) return;
      const gone = x => set.has(x.i ?? x[2]);           // shapes carry their index as i, ink points as their third value
      prune(cons, gone); prune(texts, gone); prune(ink, gone); prune(areas, gone);
      if (group && set.has(group.i)) group = null;
    }
    function reset() { cons.length = texts.length = ink.length = areas.length = 0; group = null; }
    // a container: a closed shape at least 36 x 22 and less than 40% of the paper, with an outline or a fill you see
    const filledAtLeast = (m, alpha) => m.fill && (m.fillAlpha == null || m.fillAlpha >= alpha);
    const isContainer = (m, s) => s && s.b[2] - s.b[0] >= 36 && s.b[3] - s.b[1] >= 22 && s.area < 0.4 * W * H && (m.outline !== false || filledAtLeast(m, 0.5));
    const opaque = m => m.fill !== 'none' && filledAtLeast(m, 0.7);
    // how much of shape a (moved by dx, dy) and shape b overlap, measured by sampling
    function overlap(a, b, dx = 0, dy = 0) {
      const [ax0, ay0, ax1, ay1] = a.b, [bx0, by0, bx1, by1] = b.b;
      const x0 = Math.max(ax0 + dx, bx0), y0 = Math.max(ay0 + dy, by0), x1 = Math.min(ax1 + dx, bx1), y1 = Math.min(ay1 + dy, by1);
      if (!(x1 > x0 && y1 > y0)) return 0;
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
      const [small, big] = a.area < b.area ? [a.area, b.area] : [b.area, a.area];
      const nested = shared >= 0.8 * a.area || shared >= 0.8 * b.area;   // one sits inside the other on purpose
      const touching = shared < 0.1 * small;                             // edges meeting
      // same kind of shape and of comparable size: not a badge on a box, ears on a head, a hill on the sea
      return !nested && !touching && a.kind === b.kind && a.kind !== 'poly' && small / big >= 0.2;
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
      const i = index ?? n++;
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
      // 2. words name the latest container they are written in
      if (m.do === 'text' && m.text != null && Array.isArray(m.at)) {
        const b = textBox(m), cx = (b[0] + b[2]) / 2, cy = (b[1] + b[3]) / 2;
        b.i = i; texts.push(b);
        const holder = [...cons].reverse().find(c => c.inside(cx, cy));
        if (holder) { holder.labelled = true; holder.label = holder.label || String(m.text).slice(0, 24); }
        return m;
      }
      // 3. a new container, checked against the labelled ones drawn before it
      const s = shapeOf(m);
      if (!isContainer(m, s)) return m;
      const c = Object.assign(s, { i, step: m.step, sk, opaque: opaque(m), labelled: false, label: '' });
      const hit = cons.find(o => o.labelled && clashes(c, o, overlap(c, o)));
      if (hit) {
        const by = placeFor(c, hit);
        if (by) {
          const from = c.b.slice(), inside = c.inside;
          shiftMark(m, by[0], by[1]);
          c.b = [c.b[0] + by[0], c.b[1] + by[1], c.b[2] + by[0], c.b[3] + by[1]];
          c.inside = (px, py) => inside(px - by[0], py - by[1]);
          group = { from, by, step: sk, i }; moved++;
          warnings.push(`moved a box by ${Math.round(by[0])},${Math.round(by[1])} so it no longer covers the box "${hit.label}"`);
        } else { overlaps++; warnings.push(`the box at ${Math.round(c.b[0])},${Math.round(c.b[1])} partly covers the box "${hit.label}" and there was no free spot to move it to`); }
      } else if (c.opaque) {
        const under = cons.find(o => { if (!o.labelled || o.sk === c.sk) return false; const shared = overlap(c, o); return shared > 0.2 * o.area && shared < 0.8 * o.area && shared < 0.8 * c.area; });
        if (under) { covered++; warnings.push(`a filled shape in step ${c.step} hides part of "${under.label}" from step ${under.step}`); }
      }
      cons.push(c);
      return m;
    }
    const layout = { add, forget, reset, warnings };
    for (const [name, read] of [['overlaps', () => overlaps], ['moved', () => moved], ['covered', () => covered]]) Object.defineProperty(layout, name, { enumerable: true, get: read });
    return layout;
  }
  // The layout check over a whole run of marks. plan(m, i) (optional): for an edit mark, {reset} (startOver) or
  // {forget: [the indices of the marks it erases]}.
  function layoutMarks(marks, W, H, plan) {
    const L = Layout(W, H);
    marks.forEach((m, i) => {
      if (!m || m.do !== 'edit') { marks[i] = L.add(m, i); return; }
      const erases = plan && plan(m, i);
      if (erases && erases.reset) L.reset(); else if (erases && erases.forget) L.forget(erases.forget);
    });
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
    const RUSH = o.rushPace == null ? FAST : Math.min(o.rushPace, FAST);
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
    function add(m, i, t, nat) {
      const it = { m, i, arrive: t, line: undefined, dur: nat.dur, adv: nat.adv, t: null, p: 1, rt: null };
      items.push(it);
      return it;
    }
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
        if (spread > MAXSPREAD) spread = MAXSPREAD;
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
  // Which say() line each mark belongs to. Within a step, a mark belongs to the step's latest line; marks that come
  // before the step's first line wait for it; when a step ends without one they go to the last line said before.
  // give(item, k) records the answer.
  function LineOwner(give) {
    let step = null, line = null, last = -1, waiting = [];
    const settle = () => { for (const item of waiting) give(item, last); waiting = []; };
    const enter = key => { if (key !== step) { settle(); step = key; line = null; } };
    return {
      settle,
      enter,
      // a new turn starts its own first step, whatever it is called
      restart: key => { settle(); step = key; line = null; },
      said(key, k) {
        if (key !== step) { settle(); step = key; }
        for (const item of waiting) give(item, k);
        waiting = []; line = last = k;
      },
      add(key, item) { enter(key); if (line != null) give(item, line); else waiting.push(item); },
      forget: gone => { waiting = waiting.filter(item => !gone(item)); },
    };
  }
  // Streams a program as it arrives: runs each complete statement (in a worker when sandboxed), checks the layout,
  // and hands marks to the painter (onDraw): at once, or paced to speech by the Pacer. Keeps the log of when each
  // mark and line arrived and was drawn, and the report.
  function Stream(spec, o) {
    o = o || {};
    const scanStatements = RUNNER.statementScanner();     // finds where statements end, carrying on from the last call
    const [W, H] = [spec.w || 400, spec.h || 300];
    const clock = o.clock || { now: () => performance.now() / 1000, set: (f, s) => setTimeout(f, s * 1000), clear: id => clearTimeout(id) };
    const startedAt = clock.now(), now = () => clock.now() - startedAt;
    const paced = Boolean(o.pace) && o.pace !== 'off';
    const pacer = paced ? Pacer({ wps: o.wps, gap: o.gap != null ? o.gap : o.continuous ? 0 : 0.25, speech: o.speech || 'estimate', lead: o.lead, tail: o.tail,
      minPace: o.minPace, maxSlow: o.maxSlow, maxSpread: o.maxSpread, rushPace: o.rushPace }) : null;
    const layout = o.layout === false ? null : Layout(W, H);
    const report = { errors: [], warnings: [] }, lines = [];
    const log = { marks: [], lines: [], paced, mode: null };   // when each mark and line arrived, and when it was drawn
    const arrived = [], released = new Set();          // every mark so far by index; those handed to the painter
    let count = 0, code = '', sentUpTo = -1, programDone = false, finished = false, paused = false, timer = null;
    let heldDraws = [], newLines = [], layoutWarningsTaken = 0;
    const draw = (batch, how) => {
      if (paused && !(how && how.paced)) heldDraws.push([batch, how]);
      else if (o.onDraw) o.onDraw(batch, how);
    };
    const logOwner = LineOwner((entry, k) => { entry.line = k; });
    const paceOwner = LineOwner((item, k) => pacer.assign(item, k));

    function onSay(s, t) {
      lines.push(s.text); newLines.push(s.text);
      const k = lines.length - 1;
      const line = { k, text: s.text, arrive: t, step: s.step };
      if (s.turn) line.turn = s.turn;
      log.lines.push(line);
      logOwner.said(stepKey(s), k);
      if (!paced) return;
      paceOwner.enter(stepKey(s));                       // the old step's waiting marks go to its last line first
      pacer.addLine(s.text, t); pacer.close(k - 1);
      paceOwner.said(stepKey(s), k);
    }
    // Marks from keep up to upto that were never drawn are dropped for good: never drawn later, and out of the layout
    // and the pacer.
    function dropUndrawnBetween(keep, upto) {
      const gone = [];
      const from = Math.max(0, keep);
      for (let i = from; i < upto; i++) {
        const m = arrived[i];
        if (m && !released.has(i) && !isTurnMark(m)) { m.__skip = m.__erased = m.__dropped = true; gone.push(i); }
      }
      if (gone.length) forget(new Set(gone), true);
      return gone;
    }
    function forget(indices, markDropped) {
      if (pacer) pacer.drop(i => indices.has(i));
      paceOwner.forget(item => indices.has(item.i));
      if (layout) layout.forget(indices);
      if (markDropped) for (const entry of log.marks) if (indices.has(entry.i)) entry.dropped = true;
    }
    // __turn(n, keep): a new turn on the same card. What the last turn had not drawn yet from `keep` on is dropped.
    function onTurn(m, i, t, batch) {
      if (m.op.keep != null) dropUndrawnBetween(m.op.keep, i);
      logOwner.restart(stepKey(m));
      if (paced) paceOwner.restart(stepKey(m));
      released.add(i); arrived[i] = m;
      log.marks.push({ i, arrive: t, do: 'edit', op: 'turn', step: m.step, dur: 0, adv: 0, rt: t });
      if (!paced) batch.push(m);                         // painted as nothing; it keeps an unpaced batch's indices in step
    }
    function onMark(m, i, t, batch) {
      if (isTurnMark(m)) return onTurn(m, i, t, batch);
      if (m.do !== 'edit') { if (layout) m = layout.add(m, i); }
      else {
        // an edit has no shape of its own; what it erases leaves the layout (startOver: all of it)
        const plan = o.planEdit ? o.planEdit(m, i) : null;
        if (plan && layout) { if (plan.reset) layout.reset(); else if (plan.forget) layout.forget(plan.forget); }
      }
      let timing = natural(m);
      // sequential: one stroke at a time (fills and dots still land together)
      if (o.sequential && m.outline !== false && m.do !== 'dot') timing = { dur: timing.dur, adv: Math.max(timing.adv, timing.dur + 0.03) };
      const entry = { i, arrive: t, do: m.do, step: m.step, dur: timing.dur, adv: timing.adv, rt: paced ? null : t };
      log.marks.push(entry); logOwner.add(stepKey(m), entry); arrived[i] = m;
      if (!paced) { released.add(i); batch.push(m); return; }
      paceOwner.enter(stepKey(m));
      paceOwner.add(stepKey(m), pacer.add(m, i, t, timing));
    }
    // One run's new marks and say() lines, in the order the program made them (a line said before mark j comes first).
    function take(result, done) {
      const t = now(), batch = [], newMarks = result.marks || [], says = result.says || [];
      if (result.mode) log.mode = result.mode;
      let s = 0;
      const saysUpTo = at => { while (s < says.length && says[s].at <= at) onSay(says[s++], t); };
      newMarks.forEach((m, j) => { saysUpTo(count + j); onMark(m, count + j, t, batch); });
      saysUpTo(count + newMarks.length);
      while (s < says.length) onSay(says[s++], t);
      count += newMarks.length;
      report.warnings.push(...(result.warnings || []));
      if (result.error) report.errors.push(result.error);
      if (batch.length) draw(batch, {});
      if (done && !programDone) {
        programDone = true; logOwner.settle();
        if (paced) { paceOwner.settle(); pacer.closeAll(); }
      }
      if (paced) kick(); else if (programDone && !paused) finish();
      const said = newLines; newLines = [];
      if (said.length && o.onSay) o.onSay(said);
      return said;
    }
    function finish() {
      if (finished) return;
      finished = true;
      if (layout) {
        // only what is new since the last finish: a continued turn finishes again
        report.warnings.push(...layout.warnings.slice(layoutWarningsTaken));
        layoutWarningsTaken = layout.warnings.length;
        Object.assign(report, { shapeOverlaps: layout.overlaps, nudged: layout.moved, covered: layout.covered });
      }
      if (paced) {
        for (const line of log.lines) { const span = pacer.times(line.k); if (span) { line.start = span[0]; line.end = span[1]; } }
        const byIndex = new Map(log.marks.map(entry => [entry.i, entry]));
        for (const item of pacer.items) { const entry = byIndex.get(item.i); if (entry) Object.assign(entry, { rt: item.rt, p: item.p, line: item.line }); }
      }
      if (o.sandbox === 'worker' && runner?.stop) runner.stop();   // the worker is done for this drawing
      o.onDone?.(report, log);
    }
    // Release what the pacer says is due, and wake again when the next stroke is.
    function tick() {
      timer = null;
      if (finished || paused) return;
      const t = now();
      for (const item of pacer.due(t)) { released.add(item.i); draw([item.m], { paced: true, pace: item.p, i: item.i }); }
      const next = pacer.nextAt(t);
      if (next != null) timer = clock.set(tick, Math.max(0.001, next - t));
      else if (programDone && pacer.empty()) finish();
    }
    const stopTimer = () => { if (timer != null) clock.clear(timer); timer = null; };
    function kick() { stopTimer(); tick(); }
    const inProcess = session => ({
      sync: true,
      run: (src, done, ends) => take(session.update(src, done, ends), done),
      get code() { return session.code; }, get mode() { return session.mode; }, get live3d() { return session.live3d; },
    });
    let runner = o.sandbox === 'worker' && typeof Worker !== 'undefined' ? WorkerRunner(W, H, o, (r, done) => take(r, !!done)) : null;
    const sandboxed = !!runner;
    if (!runner) runner = inProcess(RUNNER.Session(W, H, { incremental: o.incremental }));
    return {
      // All the code received so far. Runs up to its last complete statement (all of it when done) and returns the
      // new say() lines (a sandboxed run hands them to onSay instead).
      update(all, done = false) {
        if (programDone) return [];
        const ends = scanStatements(all), upTo = done ? all.length : ends.length ? ends[ends.length - 1] : 0;
        if (upTo <= sentUpTo && !done) return [];
        sentUpTo = upTo; code = all.slice(0, upTo);
        const said = runner.run(code, done, ends);       // the statement ends are found once, here
        return runner.sync ? said : [];
      },
      // the host's speech: line k started or ended (seconds since live() started; default now)
      lineStart(k, t) { if (pacer) { pacer.start(k, t != null ? t : now()); kick(); } },
      lineEnd(k, t) { if (pacer) { pacer.end(k, t != null ? t : now()); kick(); } },
      // continuous speech: the first n words of all the lines run together have been heard
      spoken(n, t) {
        if (!pacer) return;
        const at = t != null ? t : now();
        for (const line of pacer.lines) {
          if (line.start == null && n > line.cum) pacer.start(line.k, at);
          if (line.end == null && n >= line.cum + line.words) pacer.end(line.k, at);
        }
        kick();
      },
      stop() { stopTimer(); finished = true; if (runner.stop) runner.stop(); },
      // Draw every stroke still waiting for its line, quickly and in order; later ones draw as they arrive. Speech goes
      // on and is still recorded. Nothing to do unpaced or finished.
      finishNow() { if (pacer && !finished) { pacer.rush(); kick(); } },
      get rushed() { return !!(pacer && pacer.rushed); },
      // Hold the pen after the stroke being drawn (code still arrives and waits); resume() carries on.
      pause() { if (!paused && !finished) { paused = true; stopTimer(); } },
      resume() {
        if (!paused) return;
        paused = false;
        const held = heldDraws; heldDraws = [];
        for (const [batch, how] of held) if (o.onDraw) o.onDraw(batch, how);
        if (paced) kick(); else if (programDone) finish();
      },
      get paused() { return paused; }, get finished() { return finished; }, get done() { return programDone; },
      marks: arrived, get code() { return code; },
      report, log, lines, sandboxed, now,
      // For a continued turn on the same card. ran: the code the runner has run (complete statements only, so it can
      // trail `code` while a statement waits to parse).
      get ran() { return runner.code != null ? runner.code : code; }, get runMode() { return runner.mode || null; },
      // the live run's tick functions and poses for figure() (none in the worker sandbox)
      get live3d() { return runner.live3d || null; },
      get count() { return count; }, isReleased: i => released.has(i),
      // The user interrupted: every mark not drawn yet is dropped. Returns the first one dropped (count if none).
      dropPending() {
        let first = count;
        for (let i = 0; i < count; i++) if (arrived[i] && !released.has(i) && !isTurnMark(arrived[i])) { first = i; break; }
        dropUndrawnBetween(first, count); heldDraws = [];
        return first;
      },
      // take more code after the program was done
      reopen(next) {
        if (next != null && !sandboxed) { code = next; sentUpTo = next.length; }
        programDone = false; finished = false;
        if (pacer) pacer.reopen();
      },
      // Run again from `src`, whose first `keep` marks are the ones already here (the old run failed after them). The
      // marks after them leave the layout, the pacer and the log, whose indices are about to be reused.
      rebase(src, keep) {
        if (sandboxed) return false;
        const session = RUNNER.Session(W, H, { incremental: o.incremental });
        session.update(src, false);
        runner = inProcess(session); code = src; sentUpTo = src.length;
        const cut = new Set();
        for (let i = keep; i < arrived.length; i++) { released.delete(i); cut.add(i); }
        if (cut.size) forget(cut, false);
        for (let k = log.marks.length - 1; k >= 0; k--) if (cut.has(log.marks[k].i)) log.marks.splice(k, 1);   // in place: the log is shared
        arrived.length = Math.min(arrived.length, keep); count = keep;
        return true;
      },
    };
  }

  // ================================================================ render
  let SURFACES = 0;
  // label nudges: down, up, right, left, then the diagonals
  const AROUND_LABEL = [[0, 1], [0, -1], [1, 0], [-1, 0], [1, 1], [-1, 1], [1, -1], [-1, -1]];
  // The SVG every card starts as. Filters: wash (a watercolour edge for fills) and grain (pencil tooth). Layers, bottom
  // to top: a hidden probe for measuring, fills, strokes, highlights, words. The ids are what hosts look for.
  const CARD_DEFS = '<defs><filter id="wash" x="-10%" y="-10%" width="120%" height="120%"><feTurbulence type="fractalNoise" baseFrequency="0.035" numOctaves="2" seed="3"/>'
    + '<feDisplacementMap in="SourceGraphic" scale="3.5"/></filter>\n      <filter id="grain"><feTurbulence type="fractalNoise" baseFrequency="0.9" numOctaves="1" seed="7" result="n"/>'
    + '<feColorMatrix in="n" type="matrix" values="0 0 0 0 0  0 0 0 0 0  0 0 0 0 0  0 0 0 -1.2 1.1" result="a"/><feComposite in="SourceGraphic" in2="a" operator="in"/></filter></defs>\n      '
    + '<g id="__probe" style="visibility:hidden"></g><g id="under"></g><g id="main"></g><g id="hl"></g><g id="words"></g>';
  function surfaceFor(spec, host, opts = {}) {
    const uid = `cd${++SURFACES}_`;                        // ids unique per card, so several cards can share a page
    const W = spec.w || 400, H = spec.h || 300, t0 = performance.now();
    const surface = spec.surface || 'card', defInk = surface === 'sky' ? 'white' : 'ink';   // on a sky the default ink is white
    const NS = 'http://www.w3.org/2000/svg', svg = document.createElementNS(NS, 'svg');
    const shownWidth = opts.width || W * 2;
    svg.setAttribute('viewBox', `0 0 ${W} ${H}`); svg.setAttribute('width', shownWidth); svg.setAttribute('height', shownWidth * H / W);
    svg.innerHTML = CARD_DEFS;
    host.appendChild(svg);
    const [defs, under, main, hlLayer, words] = ['defs', '#under', '#main', '#hl', '#words'].map(s => svg.querySelector(s));
    let clock = 0.15, lastStep = null, maskCount = 0, delayBase = 0, pace = 1, total = 0;
    let report = { marks: 0, errors: [], warnings: [], engine: VERSION };
    // when each mark's ink starts and ends: [start, end] in seconds since the card was made, by mark index
    const placed = [];
    // What each mark drew (per layer, in paint order), its pen masks and the mark itself, so edits find them again.
    // Only references are kept: the SVG is exactly what a card without edits draws.
    const NODES = {}, MASKS = {}, MK = {};                 // by mark index: its elements, its pen masks, the mark
    // while a mark paints: where its elements and masks are collected, and the depth they sort by
    let cap = null, capM = null, capKey = 0;
    let editing = false;                                    // a repaint by an edit: words keep the place they were given
    // hooks.edit(m, i, startsAt, pace) runs a program's edit mark ({do: 'edit'}) through the card's editor and returns
    // how long it takes (s); live() and render() set it
    const hooks = {};
    // the role of the mark being painted, kept on each element it makes (label placement ignores the arrows that tie a
    // row to its photo: they cross the card, and the card's words must not move for them)
    let paintingRole = null;
    const LAYERS = new Set([main, under, hlLayer, words]);
    // An element with the given attributes (null ones left out) in parent (the strokes layer by default), recorded
    // for the mark being painted.
    const el = (tag, attrs, parent) => {
      parent = parent || main;
      const e = document.createElementNS(NS, tag);
      for (const [k, v] of Object.entries(attrs)) if (v != null) e.setAttribute(k, v);
      e.__role = paintingRole || e.__role;
      parent.appendChild(e);
      if (cap && LAYERS.has(parent)) { e.__k = capKey; cap.push(e); }
      return e;
    };
    // a CSS animation at the card's pace: dur seconds, starting at `delay` on the card's clock
    const anim = (e, name, dur, delay) => {
      const curve = name === 'pen' ? PEN.ease || 'cubic-bezier(.4,.1,.3,1)' : 'ease-out';
      e.style.animation = `${name} ${(dur * Math.max(pace, 0.35)).toFixed(2)}s ${curve} ${(delay - delayBase).toFixed(2)}s both`;
    };

    // A pen stroke along a centreline: the felt-pen outline, shown through a mask whose own stroke is drawn on over the
    // pen's time. Returns that time. Under the ink go the pen's halo for this colour (PEN.halo: [colour, opacity,
    // width], or several, widest first: a soft edge without a blur); without one, a mark's own glow ([opacity, radius])
    // rides on the ink for the app to paint as a shadow in its colour (data-glow).
    function stroke(centre, m, colour, size, parent, extra = {}) {
      const d = outline(centre, size, m.taper ?? 1);
      if (!d) return 0;
      const id = `${uid}m${maskCount++}`, dur = penDur(plen(centre)), viaMask = `url(#${id})`;
      const mask = el('mask', { id, maskUnits: 'userSpaceOnUse', x: -W, y: -H, width: W * 3, height: H * 3 }, defs);
      const reveal = el('path', { d: poly(centre), fill: 'none', stroke: '#fff', 'stroke-width': size * 2 + 4, 'stroke-linecap': 'round', 'stroke-linejoin': 'round',
        pathLength: 1, 'stroke-dasharray': '1 1' }, mask);
      anim(reveal, 'pen', dur, clock);
      if (capM) capM.push(reveal);
      const halo = PEN.halo ? PEN.halo[String(colour).toUpperCase()] : undefined;
      const halos = !halo ? [] : Array.isArray(halo[0]) ? halo : [halo];
      for (const [haloColour, opacity, width] of halos) {
        el('path', { d, fill: haloColour, 'fill-opacity': opacity, stroke: haloColour, 'stroke-opacity': opacity, 'stroke-width': width, 'stroke-linejoin': 'round',
          mask: viaMask, 'data-halo': '1' }, parent);
      }
      const ownGlow = !halo && Array.isArray(m.glow) && m.glow.length === 2 && m.glow.every(v => isFinite(+v)) ? m.glow : null;
      const ink = {
        d, fill: colour, 'fill-opacity': m.alpha != null ? m.alpha : (BRUSH[m.brush] || BRUSH.pen).alpha, mask: viaMask,
        filter: m.brush === 'pencil' ? 'url(#grain)' : null, 'data-glow': ownGlow ? `${(+ownGlow[0]).toFixed(3)} ${(+ownGlow[1]).toFixed(2)}` : null,
      };
      el('path', Object.assign(ink, extra), parent);
      return dur;
    }
    // A fill's rough area: big sheets skip the watercolour filter (PEN.washMaxArea), which is costly to animate.
    function fillArea(m) {
      if (Array.isArray(m.pts) && m.pts.length) {
        const points = m.pts.filter(Array.isArray).map(p => [+p[0] || 0, +p[1] || 0]);
        if (!points.length) return 0;
        const [x0, y0, x1, y1] = boxOf(points);
        return (x1 - x0) * (y1 - y0);
      }
      if (m.w && m.h) return Math.abs(m.w) * Math.abs(m.h);
      const [rx, ry] = m.r ? [m.r, m.r] : [m.rx, m.ry];
      return rx && ry ? 4 * rx * ry : 0;
    }
    // A shape's fill: it fades in just after its outline starts (with it, when there is no outline), or opens with a
    // marquee's tint. `wash: false` keeps a fill crisp (label pills, number badges).
    const marqueeText = m => m.marquee.map(v => (+v || 0).toFixed(2)).join(' ');
    function wash(dPath, m, parent, extra) {
      if (!m.fill) return;
      const marquee = m.outline === false && Array.isArray(m.marquee);   // a marquee's tint, which has no outline
      const watercolour = PEN.wash && m.wash !== false && !marquee && fillArea(m) <= PEN.washMaxArea;
      const fill = { d: dPath, fill: tone(m.fill), 'fill-opacity': m.fillAlpha != null ? m.fillAlpha : 1, filter: watercolour ? 'url(#wash)' : null,
        'data-marquee': marquee ? marqueeText(m) : null };
      const e = el('path', Object.assign(fill, extra || {}), parent || under);
      if (marquee) anim(e, 'marquee', MARQUEE_DUR, clock);
      else anim(e, 'fadein', 0.35, m.outline === false ? clock : clock + 0.18);
    }

    // ---------------------------------------------------------------- labels keep clear of each other and of shapes
    // An element's box on the card, with its nudge and any edit's move or scale. cache: a shape keeps the box it was
    // first measured with (the app measures paths, and they do not change); words are measured each time.
    function cardBox(e, cache) {
      let box = null;
      if (cache) {
        if (!e.__bb) { try { const q = e.getBBox(); e.__bb = q && (q.width || q.height) ? { x: q.x, y: q.y, w: q.width, h: q.height } : null; } catch (_) { e.__bb = null; } }
        box = e.__bb;
      } else {
        try { const q = e.getBBox(), [nx, ny] = e.__nudge || [0, 0]; box = { x: q.x + nx, y: q.y + ny, w: q.width, h: q.height }; } catch (_) { box = null; }
      }
      const xf = box && e.__wrap && e.__wrap.__xf;
      if (!xf) return box;
      const [k, dx, dy] = xf;
      return { x: box.x * k + dx, y: box.y * k + dy, w: box.w * k, h: box.h * k };
    }
    // how far to shift a span [start, start + size] to bring it within [lo, hi] (a span too big for it keeps to lo)
    const intoRange = (start, size, lo, hi) => Math.min(Math.max(0, lo - start), hi - start - size) || Math.max(lo - start, Math.min(0, hi - start - size));
    // A short label moves to the nearest spot on the card where it neither sits on other words nor is crossed by
    // shapes. Words are compared by their letters' middle band (a title and the subtitle under it overlap a little as
    // boxes with no letter touching). A shape around the label holds it ("User" in its circle) and never pushes it;
    // shapes crossing it do, once together they cover a fifth of its middle. Halos, ties to photos and paper cards
    // are never in the way. A paragraph or list stays where it was written.
    function placeLabel(t) {
      let b;
      try { b = t.getBBox(); } catch (_) { return; }
      if (!b.width) return;
      const live = e => e.ownerSVGElement === svg && !e.__gone;
      const otherWords = [...words.querySelectorAll('text')].filter(e => e !== t && live(e)).map(e => cardBox(e, false)).filter(Boolean);
      const shapes = [...main.querySelectorAll('path,circle,ellipse,rect,line,polyline,polygon')]
        .filter(e => live(e) && !e.getAttribute('data-halo') && e.__role !== 'tie' && e.__role !== 'paper').map(e => cardBox(e, true)).filter(Boolean);
      const overlap = (a0, a1, b0, b1) => Math.min(a1, b1) - Math.max(a0, b0);
      const onWords = (dx, dy) => otherWords.some(o => overlap(b.x + dx, b.x + dx + b.width, o.x, o.x + o.w) > 3
        && overlap(b.y + dy + b.height * 0.2, b.y + dy + b.height * 0.8, o.y + o.h * 0.2, o.y + o.h * 0.8) > 1);
      const crossedBy = (dx, dy) => {
        const x0 = b.x + dx + b.width * 0.1, x1 = b.x + dx + b.width * 0.9, y0 = b.y + dy + b.height * 0.25, y1 = b.y + dy + b.height * 0.75;
        let covered = 0;
        for (const o of shapes) {
          if (o.x <= x0 + 2 && o.y <= y0 + 2 && o.x + o.w >= x1 - 2 && o.y + o.h >= y1 - 2) continue;   // it holds the label
          // a pen line is a couple of pixels thin but crosses the words all the same: widened to a band that counts
          const ix = overlap(x0, x1, o.x - 4, o.x + o.w + 4), iy = overlap(y0, y1, o.y - 4, o.y + o.h + 4);
          if (ix > 2 && iy > 2) covered += ix * iy;
        }
        return covered / Math.max(1, (x1 - x0) * (y1 - y0));
      };
      const blocked = (dx, dy) => onWords(dx, dy) || crossedBy(dx, dy) > 0.2;
      const onCard = (dx, dy) => b.x + dx >= 4 && b.y + dy >= 4 && b.x + dx + b.width <= W - 4 && b.y + dy + b.height <= H - 4;
      let at = onCard(0, 0) ? [0, 0] : [intoRange(b.x, b.width, 4, W - 4), intoRange(b.y, b.height, 4, H - 4)];
      if (!t.querySelector('tspan') && blocked(at[0], at[1])) {
        // rings of spots around it, nearest first; a step up or down costs more than one aside
        const down = Math.max(10, b.height * 0.9), across = b.width * 0.35 + 6, spots = [];
        for (let ring = 1; ring <= 5; ring++) for (const [ux, uy] of AROUND_LABEL) spots.push([at[0] + ux * ring * across, at[1] + uy * ring * down]);
        const cost = ([dx, dy]) => Math.hypot(dx - at[0], (dy - at[1]) * 1.6);
        spots.sort((p, q) => cost(p) - cost(q));
        const free = spots.find(([dx, dy]) => onCard(dx, dy) && !blocked(dx, dy));
        if (free) { at = free; report.warnings.push(`moved the label "${t.textContent.slice(0, 20)}" clear of other words or a shape`); }
      }
      if (at[0] || at[1]) { t.__nudge = at; t.setAttribute('transform', `translate(${at[0].toFixed(1)} ${at[1].toFixed(1)}) ${t.getAttribute('transform') || ''}`); }
    }
    // A mark's rough time, for fitting a step into its budget when render() draws a whole program.
    const NO_TIME = new Set(['motion3d', 'camera3d', 'tick3d']);
    const est = m => {
      switch (m.do) {
        case 'dot': return 0.05;
        case 'text': case 'label3d': return 0.3 + String(m.text).length * 0.01;
        case 'molecule': return 0.6;
        case 'part3d': case 'stage3d': return 0.12;
        case 'edit': return m.__est != null ? m.__est : 0.3;
        default: return NO_TIME.has(m.do) ? 0 : 0.3;
      }
    };
    const BUDGET = spec.stepBudget || 2.6;                 // seconds a step's strokes may take when render() draws it whole

    // ---------------------------------------------------------------- ink that stays readable on what is under it
    // Ink that would vanish into what is under it (a blue cursor colour on a blue sky) is drawn lighter or darker.
    // What is under it is the last filled shape or card drawn beneath the mark when there is one (a paper card, a
    // pill, a cat's face), else the screen itself (the host's __lumFor).
    // grounds: [x0, y0, x1, y1, luma, colour (cards only), order, window mark (windows only)]
    // surfaces: every visible fill, [x0, y0, x1, y1, colour, alpha, order], for the colour actually under words
    const grounds = [], surfaces = [];
    let drawOrder = 0;
    const rgbOf = c => {
      const hex = /^#?([0-9a-f]{6})$/i.exec(String(c == null ? '' : c).trim());
      if (!hex) return null;
      const v = parseInt(hex[1], 16);
      return [(v >> 16) & 255, (v >> 8) & 255, v & 255];
    };
    const hexOf = c => String(TONES[c] || c || '');
    const lumaOf = c => { const rgb = rgbOf(hexOf(c)); return rgb ? (0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2]) / 255 : null; };
    const isChromatic = hex => { const rgb = rgbOf(hex); return !!rgb && Math.max(...rgb) - Math.min(...rgb) > 40; };
    const mixHex = (a, b, k) => {
      const p = rgbOf(a), q = rgbOf(b);
      return p && q ? '#' + p.map((v, j) => Math.round(v * (1 - k) + q[j] * k).toString(16).padStart(2, '0')).join('') : a;
    };
    const NO_INK_CHECK = new Set(['image', 'window', 'stage3d', 'part3d', 'label3d', 'highlight', 'molecule', 'edit', 'motion3d', 'camera3d', 'tick3d']);
    const FILLABLE = new Set(['poly', 'rect', 'circle', 'ellipse', 'path']);
    // The screen's brightness around a box: a band 8 wide round it, not its inside (inside a ring is the thing ringed,
    // and a thin line's own box is the line under it).
    function bandLuma([x0, y0, x1, y1]) {
      const hostMeasures = typeof global.__lumFor === 'function';   // the host reads the screenshot
      if (!hostMeasures) return -1;
      const pad = 8, w = Math.max(1, x1 - x0), h = Math.max(1, y1 - y0);
      const sides = [[x0 - pad, y0 - pad, w + 2 * pad, pad], [x0 - pad, y1, w + 2 * pad, pad], [x0 - pad, y0, pad, h], [x1, y0, pad, h]];
      let sum = 0, area = 0;
      for (const [x, y, sw, sh] of sides) {
        const l = global.__lumFor(x, y, sw, sh);
        if (l >= 0) { sum += l * sw * sh; area += sw * sh; }
      }
      return area ? sum / area : -1;
    }
    // A window's ground is its box as it is now (windows grow to hold what is drawn on them).
    const liveBox = g => { const win = g[7]; return (win && markBox(win)) || g; };
    const taggedFor = (m, wm) => Array.isArray(m.onWindow) && Array.isArray(wm.inner) && Math.abs(m.onWindow[0] - wm.inner[0]) < 1 && Math.abs(m.onWindow[1] - wm.inner[1]) < 1;
    // The ground under a mark (box b): the latest one under its middle, else a window it is about to grow.
    function groundFor(m, b) {
      const [cx, cy] = [(b[0] + b[2]) / 2, (b[1] + b[3]) / 2];
      const latest = test => { for (let k = grounds.length - 1; k >= 0; k--) if (test(grounds[k])) return grounds[k]; return null; };
      return latest(g => { const [x0, y0, x1, y1] = liveBox(g); return cx >= x0 && cx <= x1 && cy >= y0 && cy <= y1; })
        || latest(g => { const wm = g[7]; if (!wm || wm.__erased) return false; const [x0, y0, x1, y1] = liveBox(g); return belongsToWindow(b, x0, y0, x1, y1, taggedFor(m, wm)); });
    }
    // Words on a card or a filled shape wear a halo of the colour under them, so a line passing behind stops short of
    // the letters: the card's colour with any tinted fill drawn on it since blended over. Loose words keep the pen's.
    function knockoutFor(m) {
      const wanted = m.do === 'text' && !m.under && m.knockout !== false && m.role !== 'cheer';
      const b = wanted ? markBox(m) : null, ground = b && groundFor(m, b);
      if (!ground?.[5]) return null;
      const [px, py] = [(b[0] + b[2]) / 2, (b[1] + b[3]) / 2];
      return surfaces.filter(f => f[6] > (ground[6] || 0) && px >= f[0] && px <= f[2] && py >= f[1] && py <= f[3])
        .reduce((colour, f) => (f[5] >= 0.99 ? f[4] : mixHex(colour, f[4], f[5])), ground[5]);
    }
    // On the bare screen, ink that is too close in brightness to what is under it: words need more contrast than lines
    // (0.3 on light, 0.45 on dark against 0.2). A colour that means something keeps its hue, made darker on light
    // ground or lighter on dark, in twentieths from 0.1 to 0.85; greys become the plain dark or light ink (a quieter
    // light grey for grey words). A legend's keys keep their colours exactly.
    function readableColour(m, colour) {
      if (surface !== 'none' || NO_INK_CHECK.has(m.do) || m.role === 'paper' || m.role === 'key') return colour;
      const ink = lumaOf(colour), b = markBox(m), ground = ink != null && b ? groundFor(m, b) : undefined;
      if (ground === undefined) return colour;
      let under = ground ? ground[4] : null;
      if (under == null) { under = bandLuma(b); if (!(under >= 0)) return colour; }
      const isWords = m.do === 'text', light = under > 0.58, needed = !isWords ? 0.2 : light ? 0.3 : 0.45;
      const reads = c => { const l = lumaOf(c); return l != null && Math.abs(l - under) >= needed; };
      if (reads(colour)) return colour;
      const hex = hexOf(colour);
      if (isChromatic(hex)) {
        for (let s = 2; s <= 17; s++) { const next = light ? shade(hex, s / 20) : mixHex(hex, '#FFFFFF', s / 20); if (reads(next)) return next; }
      }
      if (light) return '#15171C';
      return isWords && ink > 0.35 ? '#C9CDD4' : '#FFFFFF';   // a quieter light grey keeps grey words second to white ones
    }

    // ---------------------------------------------------------------- windows grow to hold what is drawn on them
    // A mark that belongs to a window and reaches past its padding pushes that side out, keeping the padding (the top
    // above the title bar). The window's mark and element change, so the app redraws it and the card's box stays true.
    const windowsDrawn = [];
    // Whether a mark (box b) belongs to a window (x0..x1, y0..y1): tagged for it (onWindow), mostly on it, its middle on
    // it, or a row that ran just past its bottom (across it, starting within a line below: the model ran out of room).
    function belongsToWindow(b, x0, y0, x1, y1, tagged) {
      if (tagged) return true;
      const bw = b[2] - b[0], bh = b[3] - b[1];
      const ow = Math.min(b[2], x1) - Math.max(b[0], x0), oh = Math.min(b[3], y1) - Math.max(b[1], y0);
      const midX = (b[0] + b[2]) / 2, midY = (b[1] + b[3]) / 2;
      return (ow > 0 && oh > 0 && ow * oh >= 0.4 * bw * bh) || (midX >= x0 && midX <= x1 && midY >= y0 && midY <= y1)
        || (ow >= 0.6 * bw && b[1] >= y0 && b[1] <= y1 + 48 && bh <= 120);
    }
    // the box mark i drew on the card (halos left out), moved and scaled with it
    function drawnBox(i, m) {
      let box = null;
      for (const n of NODES[i] || []) {
        if (n.__gone || (n.getAttribute && n.getAttribute('data-halo'))) continue;
        let r;
        try { r = n.getBBox(); } catch (_) { continue; }
        if (!r || (!r.width && !r.height)) continue;
        const [nx, ny] = n.__nudge || [0, 0], q = [r.x + nx, r.y + ny, r.x + nx + r.width, r.y + ny + r.height];
        box = box ? [Math.min(box[0], q[0]), Math.min(box[1], q[1]), Math.max(box[2], q[2]), Math.max(box[3], q[3])] : q;
      }
      if (!box || !m.__xf) return box;
      const [k, dx, dy] = m.__xf;
      return [box[0] * k + dx, box[1] * k + dy, box[2] * k + dx, box[3] * k + dy];
    }
    const NEVER_IN_WINDOW_ROLES = new Set(['tie', 'photo', 'paper']);
    function fitWindowsTo(m, i) {
      if (!windowsDrawn.length || !m || m.do === 'window' || m.do === 'edit' || NEVER_IN_WINDOW_ROLES.has(m.role) || m.stage != null
        || /3d$/.test(m.do || '') || pointsAtScreen(m)) return;
      const drawn = drawnBox(i, m) || markBox(m);
      if (!drawn || drawn[2] <= drawn[0] || drawn[3] <= drawn[1]) return;
      for (const win of windowsDrawn) {
        const wm = win.m;
        if (wm.__erased || !win.e.parentNode) continue;
        // the mark's box in the window's own coordinates (the window may have been moved or scaled)
        const [k0, dx, dy] = wm.__xf || [1, 0, 0], k = k0 || 1;
        const b = [(drawn[0] - dx) / k, (drawn[1] - dy) / k, (drawn[2] - dx) / k, (drawn[3] - dy) / k];
        const [x0, y0] = wm.at, x1 = x0 + wm.w, y1 = y0 + wm.h, pad = +wm.pad || 0, head = +wm.header || 0;
        const tagged = taggedFor(m, wm);
        if (!belongsToWindow(b, x0, y0, x1, y1, tagged)) continue;
        // where its content starts and ends (the sources line keeps to its left edge and goes under its bottom)
        if (!tagged) {
          win.contentLeft = Math.min(win.contentLeft == null ? Infinity : win.contentLeft, b[0]);
          win.contentBottom = Math.max(win.contentBottom == null ? -Infinity : win.contentBottom, b[3]);
        }
        const left = Math.max(2, Math.min(x0, b[0] - pad)), right = Math.min(W - 2, Math.max(x1, b[2] + pad));
        const top = Math.max(2, Math.min(y0, b[1] - pad - head)), bottom = Math.min(H - 2, Math.max(y1, b[3] + pad));
        const grew = left < x0 - 0.5 || right > x1 + 0.5 || top < y0 - 0.5 || bottom > y1 + 0.5;
        if (!grew) continue;
        wm.at = [left, top]; wm.w = right - left; wm.h = bottom - top;
        for (const [attr, v] of [['x', left], ['y', top], ['width', wm.w], ['height', wm.h]]) win.e.setAttribute(attr, v);
        break;
      }
    }
    // What a mark puts under later ink: a window, a card or a near-opaque fill is a ground; any visible fill a surface.
    function noteGround(m) {
      if (m.do === 'window') {
        const l = lumaOf(m.bg), b = markBox(m);
        if (l != null && b) grounds.push([...b, l, hexOf(m.bg), ++drawOrder, m]);
        return;
      }
      if (!m.fill || !FILLABLE.has(m.do)) return;
      const b = markBox(m), alpha = m.fillAlpha != null ? +m.fillAlpha : 1;
      if (m.role !== 'paper') {
        const hex = hexOf(m.fill);
        if (b && /^#[0-9a-f]{6}$/i.test(hex) && alpha >= 0.08) surfaces.push([...b, hex, alpha, ++drawOrder]);
      }
      if (m.fillAlpha != null && m.fillAlpha < 0.8) return;
      const l = lumaOf(m.fill);
      // a card (paper's role) is a ground words can match; a small filled shape only lends its brightness
      const isCard = m.role === 'paper' && (m.fillAlpha == null || m.fillAlpha >= 0.99);   // opaque paper only
      if (l != null && b) grounds.push([...b, l, isCard ? hexOf(m.fill) : null, ++drawOrder]);
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
      const dash = m.__dash;
      if (!dash) return stroke(c, m, colour, size, layer);
      const on = typeof dash === 'number' ? dash : Math.max(8, size * 3);
      return dashedStroke(c, m, colour, size, layer, on, on * 0.75);
    }
    const sameOrigin = (a, b) => Array.isArray(a) && Array.isArray(b) && Math.abs(a[0] - b[0]) < 1 && Math.abs(a[1] - b[1]) < 1;
    const windowAt = inner => windowsDrawn.find(v => sameOrigin(v.m.inner, inner));
    // A window's sources line starts where its content starts (programs indent their words inside the box) and sits
    // under everything drawn on it with a clear gap. Every piece of the line shares sourceLine (its first baseline),
    // so they move together. Done once per mark.
    function alignToWindow(m) {
      if (!Array.isArray(m.onWindow) || m.__aligned || !Array.isArray(m.at)) return;
      const win = windowAt(m.onWindow);
      if (win) {
        const indent = win.contentLeft - win.m.inner[0];
        if (isFinite(win.contentLeft) && indent > 1) m.at = [m.at[0] + indent, m.at[1]];
        if (isFinite(win.contentBottom) && isFinite(+m.sourceLine)) {
          const size = +m.sourceSize || 13, gap = Math.max(24, +win.m.pad || 0);
          const down = win.contentBottom + gap - (+m.sourceLine - size * 0.82);
          if (down > 0) m.at = [m.at[0], m.at[1] + down];
        }
      }
      m.__aligned = true;
    }
    const OUTLINED = new Set(['rect', 'ellipse', 'circle', 'poly']);
    // One mark at the current clock and pace; returns how long its pen takes (draw() and edits share it).
    function paint(m, i) {
      paintingRole = m.role ?? null;
      alignToWindow(m);
      // a filled shape with no ink of its own gets a thin edge in a deeper shade of its fill, not a black one
      const fillEdge = m.fill && !m.tone && OUTLINED.has(m.do) ? shade(tone(m.fill), 0.32) : null;
      const ink = {
        r: rng((m.id || '') + i),
        colour: fillEdge || readableColour(m, tone(m.tone, TONES[defInk])),
        size: m.size || (fillEdge ? 1.6 : (BRUSH[m.brush] || BRUSH.pen).size),
        layer: m.under ? under : main,
      };
      noteGround(m);
      const painter = PAINTERS[m.do];
      if (!painter) { report.errors.push(`no such mark "${m.do}" (${m.id || i})`); return 0.3; }
      return painter(m, i, ink);
    }
    // The app paints these from their attributes: one element each, faded or set in at its beat.
    const placeholder = (tag, attrs, layer, animation, animDur, dur) => { anim(el(tag, attrs, layer), animation, animDur, clock); return dur; };
    const writeTime = text => 0.35 + letters(text) * 0.012;    // how long written words hold the pen (their own animation runs longer)
    const writeAnim = text => 0.4 + letters(text) * 0.015;
    const opOf = m => ({ 'data-stage': m.stage, 'data-op': JSON.stringify(m.op || {}) });
    const PAINTERS = {
      line: paintLine, arrow: paintLine, path: paintPath, circle: paintEllipse, ellipse: paintEllipse, rect: paintRect, poly: paintPoly,
      text: paintText, molecule: paintMolecule,
      dot(m, i, { colour, layer }) { anim(el('circle', { cx: m.at[0], cy: m.at[1], r: m.r || 3, fill: colour }, layer), 'pop', 0.25, clock); return 0.12; },
      // a highlighter swipe: a slightly crooked band, multiplied over what is under it (not on a sky)
      highlight(m) {
        const [x, y] = m.at, { w, h } = m;
        const band = `M${x} ${y + 2} Q${x + w / 2} ${y - 1} ${x + w} ${y + 1} L${x + w - 1} ${y + h} Q${x + w / 2} ${y + h + 2} ${x + 1} ${y + h - 1} Z`;
        const e = el('path', { d: band, fill: tone(m.tone || 'butter'), 'fill-opacity': 0.72, style: surface === 'sky' ? null : 'mix-blend-mode:multiply' }, m.under ? under : hlLayer);
        Object.assign(e.style, { transformOrigin: `${x}px ${y}px`, transformBox: 'view-box' });
        anim(e, 'swipe', 0.35, clock);
        return 0.35;
      },
      // an edit of what is on the card, at this point of the drawing
      edit: (m, i) => (hooks.edit ? hooks.edit(m, i, clock, pace) : 0) / Math.max(pace, 0.35),
      // a real photo, which the app finds and paints
      image: (m, i, { layer }) => placeholder('photo', { x: m.at[0], y: m.at[1], width: m.w, height: m.h, 'data-query': String(m.query || ''), 'data-radius': m.r || 0,
        'data-rotate': m.rot || 0 }, layer, 'fadein', 0.5, 0.5),
      // a little window, whose chrome and board the app paints
      window(m, i, { layer }) {
        const e = el('window', { x: m.at[0], y: m.at[1], width: m.w, height: m.h, 'data-header': m.header, 'data-title': m.title || null,
          'data-board': m.board || 'plain', 'data-bg': m.bg, 'data-tint': m.tint, 'data-tint-alpha': m.tintAlpha }, layer);
        const known = windowsDrawn.find(win => win.m === m);
        if (known) known.e = e; else windowsDrawn.push({ m, e });
        anim(e, 'fadein', 0.45, clock);
        return 0.45;
      },
      // a 3D stage on the screen; over a window the program drew, that window's board turns plain under it
      stage3d(m, i, { layer }) {
        const win = Array.isArray(m.cardWindow) ? windowAt(m.cardWindow) : null;
        if (win && win.e.getAttribute('data-board') !== 'plain') { win.m.board = 'plain'; win.e.setAttribute('data-board', 'plain'); }
        return placeholder('scene3d', { id: m.id, x: m.at[0], y: m.at[1], width: m.w, height: m.h, 'data-ink': m.ink, 'data-camera': JSON.stringify(m.camera || {}),
          'data-card': m.card ? m.card.join(' ') : null, 'data-canvas': `${W} ${H}`, 'data-look': m.look || null }, layer, 'fadein', 0.35, 0.12);
      },
      part3d(m, i, { layer }) {
        const part = { id: m.id, kind: m.kind, params: m.params, at: m.pos, rotate: m.rotate3, scale: m.scale3, material: m.material, parent: m.parent, three: m.three,
          recipe: m.recipe, name: m.name };
        return placeholder('part3d', { 'data-stage': m.stage, 'data-part': JSON.stringify(part) }, layer, 'grow', 0.65, 0.12);
      },
      label3d(m, i, { colour }) {
        const label = { id: m.id, point: m.point, follow: m.follow, text: m.text, side: m.side };
        return placeholder('label3d', { 'data-stage': m.stage, 'data-label': JSON.stringify(label), fill: tone(m.tone, colour), 'font-family': FONT.hand,
          'font-size': m.size || 19 }, words, 'write', writeAnim(m.text), writeTime(m.text));
      },
      // a figure's tick() starts at this beat
      tick3d: (m, i, { layer }) => placeholder('tick3d', { 'data-stage': m.stage, 'data-tick': m.id }, layer, 'set', 0.01, 0),
      motion3d: (m, i, { layer }) => placeholder(m.do, opOf(m), layer, 'set', 0.01, 0),
      camera3d: (m, i, { layer }) => placeholder(m.do, opOf(m), layer, 'set', 0.01, 0),
    };
    // The centreline a line or arrow is drawn along. smooth false: hand-drawn segments (wobble 0 keeps a straight line
    // straight); bow 'pen' (the screen pen): bent once per edge, then smoothed; otherwise a smooth curve through the
    // points. An arrow's bend arcs it through a point to the side of its middle (a fraction of its length, or canvas
    // units when bigger than 1; at most 0.6).
    function lineCentre(m, i, r) {
      const wobble = fallback => (m.wobble == null ? fallback : m.wobble);
      if (m.bend && m.do === 'arrow') {
        const a = m.pts[0], b = m.pts[m.pts.length - 1], length = Math.hypot(b[0] - a[0], b[1] - a[1]) || 1;
        let k = m.bend === true ? 0.15 : +m.bend || 0;
        if (Math.abs(k) > 1) k /= length;
        if (Math.abs(k) > 0.6) { k = Math.sign(k) * 0.6; report.warnings.push(`${m.id || i}: a bend of ${m.bend} is more than the most an arrow bends; used ${k}`); }
        return catmull([a, [(a[0] + b[0]) / 2 - (b[1] - a[1]) * k, (a[1] + b[1]) / 2 + (b[0] - a[0]) * k], b], false);
      }
      if (m.smooth === false) return handSegments(m.pts, false, r, wobble(0.6), m.bow, m.jitter);
      if (m.bow === 'pen') return catmull(handSegments(m.pts, false, r, wobble(1), 'pen', m.jitter), false, 2);
      return catmull(m.pts, false);
    }
    function paintLine(m, i, { r, colour, size, layer }) {
      const c = lineCentre(m, i, r);
      // a dash is the size asked for (true: three pen widths, at least 8), with three quarters of it between dashes
      const on = typeof m.dash === 'number' ? m.dash : Math.max(8, size * 3), off = +m.dashGap || 0.75 * on;
      let dur;
      if (Array.isArray(m.marquee) && m.dash) {
        // a frame dragged open from its top-left corner like a selection: the app draws it from the box it carries
        const e = el('path', { d: poly(m.pts), fill: 'none', stroke: colour, 'stroke-width': size, 'stroke-linecap': 'round', 'stroke-linejoin': 'round',
          'stroke-dasharray': `${on.toFixed(2)} ${off.toFixed(2)}`, 'data-marquee': marqueeText(m), 'data-marquee-handle': '1' }, layer);
        anim(e, 'marquee', MARQUEE_DUR, clock);
        dur = MARQUEE_DUR;
      } else dur = m.dash ? dashedStroke(c, m, colour, size, layer, on, off) : stroke(c, m, colour, size, layer);
      if (m.do !== 'arrow') return dur;
      // the head goes on after the shaft: two barbs headAngle either side of the last stretch (taper 0 keeps them heavy)
      const tip = c[c.length - 1], back = c[Math.max(0, c.length - 6)], heading = Math.atan2(tip[1] - back[1], tip[0] - back[0]);
      const length = m.head || Math.max(9, size * 3), spread = +m.headAngle || 0.5;
      const barb = side => [tip[0] - length * Math.cos(heading + side * spread), tip[1] - length * Math.sin(heading + side * spread)];
      clock += dur;
      dur = stroke([barb(-1), tip, barb(1)], Object.assign({}, m, { taper: m.taper === 0 ? 0 : 0.4 }), colour, size, layer);
      if (m.label) {
        const mid = c[Math.floor(c.length / 2)];
        const t = el('text', { x: mid[0] + (m.labelDx || 0), y: mid[1] - 8 + (m.labelDy || 0), 'text-anchor': 'middle', fill: colour, 'font-family': faceFor('hand'),
          'font-size': m.labelSize || 15 }, layer);
        t.textContent = m.label;
        anim(t, 'fadein', 0.3, clock + dur);
      }
      return dur;
    }
    // A path's separate strokes: each "M" starts a new piece (tick marks, window panes, brackets), and a relative
    // move inside a piece shows as a jump between neighbouring samples (a chord is never longer than its arc). A
    // piece with no length is a single point.
    function pathRunsOf(d) {
      const runs = [];
      for (const piece of String(d || '').split(/(?=M)/).map(s => s.trim()).filter(Boolean)) {
        const n = Math.max(40, Math.min(400, Math.round(piece.length / 2))), samples = samplePath(piece, n), length = plen(samples), step = length / n;
        if (length < 0.5) {
          const first = (piece.match(/-?\d*\.?\d+/g) || []).map(Number);
          if (first.length >= 2) runs.push([[first[0], first[1]]]);
          continue;
        }
        let run = [samples[0]];
        samples.slice(1).forEach((p, k) => { if (dist(samples[k], p) > step * 1.5 + 0.5) { runs.push(run); run = []; } run.push(p); });
        runs.push(run);
      }
      return runs;
    }
    // A path drawn piece by piece (one sampled line made stray strokes join the pieces); a lone point is a dot.
    function paintPath(m, i, { colour, size, layer }) {
      const shift = Array.isArray(m.shift) ? m.shift : null, runs = pathRunsOf(m.d);
      wash(m.d, m, layer, shift ? { transform: `translate(${shift[0] + 0.8} ${shift[1] + 1})` } : null);
      if (m.outline === false || !runs.length) return 0.3;
      const start = clock;
      let total = 0;
      for (const raw of runs) {
        const run = shift ? raw.map(p => [p[0] + shift[0], p[1] + shift[1]]) : raw;
        clock = start + total;
        if (run.length >= 2 && plen(run) >= 0.5) { total += edge(run, m, colour, size, layer); continue; }
        anim(el('circle', { cx: run[0][0], cy: run[0][1], r: Math.max(1.5, size * 0.6), fill: colour }, layer), 'pop', 0.2, clock);
        total += 0.04;
      }
      clock = start;
      return total;
    }
    function paintEllipse(m, i, { r, colour, size, layer }) {
      // rot in radians, or in degrees when it is too big to be radians
      const [cx, cy] = m.at, rx = m.r || m.rx, ry = m.r || m.ry;
      const rot = (m.rot || 0) * (typeof m.rot === 'number' && Math.abs(m.rot) > 6.3 ? Math.PI / 180 : 1);
      const rim = ellipsePts(cx, cy, rx, ry, rot, r, m.wobble == null ? 1 : m.wobble, m.outline !== false);
      wash(`${poly(ellipsePts(cx, cy, rx, ry, rot, rng('f' + i), 0.5, false))} Z`, m, layer);
      return m.outline === false ? 0.3 : edge(rim, m, colour, size, layer);
    }
    function paintRect(m, i, { r, colour, size, layer }) {
      const [x, y] = m.at, { w, h } = m;
      // r: rounded corners, each a quarter circle in six steps
      const round = Math.max(0, Math.min(+m.r || 0, Math.abs(w) / 2, Math.abs(h) / 2));
      const quarter = (cx, cy, from) => Array.from({ length: 7 }, (_, k) => [cx + Math.cos(from + k * Math.PI / 12) * round, cy + Math.sin(from + k * Math.PI / 12) * round]);
      const corners = round
        ? [...quarter(x + w - round, y + round, -Math.PI / 2), ...quarter(x + w - round, y + h - round, 0), ...quarter(x + round, y + h - round, Math.PI / 2), ...quarter(x + round, y + round, Math.PI)]
        : [[x, y], [x + w, y], [x + w, y + h], [x, y + h]];   // sharp corners, clockwise from the top left
      wash(`${poly(corners)} Z`, m, layer);
      if (m.outline === false) return 0.3;
      // a sharp box is closed by hand: the pen runs on a little past where it started
      const outline = round ? handSegments(corners, true, r, 1) : handSegments([...corners, [x, y], [x + Math.min(6, Math.abs(w) * 0.06), y + 1]], false, r, 1);
      return edge(outline, m, colour, size, layer);
    }
    function paintPoly(m, i, { r, colour, size, layer }) {
      wash(`${m.smooth ? poly(catmull(m.pts, true)) : poly(m.pts)} Z`, m, layer);
      if (m.outline === false) return 0.3;
      const closed = !(m.close === false);
      return edge(m.smooth ? catmull(m.pts, closed) : handSegments(m.pts, closed, r, m.wobble == null ? 0.7 : m.wobble, m.bow, m.jitter), m, colour, size, layer);
    }
    const probe = svg.querySelector('#__probe');
    const STYLE_SIZE = { title: 24, body: 17, caps: 14 };
    function paintText(m, i, { colour, layer }) {
      const style = m.style || 'hand';
      let fs = m.size || STYLE_SIZE[style] || 20;
      // caps: upper case, semibold, letters spread with hair spaces (the native text shaper has no letter spacing);
      // split by letter, so an emoji stays whole
      if (style === 'caps') m = Object.assign({}, m, { text: [...String(m.text).toUpperCase()].join('\u200a'), weight: m.weight || 600 });
      // ui words (name pills, badges) have their floor in screen points (8pt), not canvas units
      const smallest = style === 'ui' ? 8 / unitPoints() : 13;
      if (fs < smallest) { report.warnings.push(`${m.id || i}: text size ${fs} is too small to read; used ${Math.round(smallest)}`); fs = smallest; }
      const lineHeight = +m.lineHeight > 0.8 ? +m.lineHeight : LINE_HEIGHT;   // headlines may ask for a tighter line
      const weight = style === 'title' ? 600 : m.weight || null;
      const knockout = knockoutFor(m), haloWidth = Math.max(5, 0.45 * fs);   // the halo: a stroke round the letters, under them
      const [x, y] = m.at;
      const t = el('text', {
        x, y, fill: colour, 'font-family': faceFor(style), 'font-size': fs, 'font-weight': weight, 'text-anchor': m.anchor || 'start',
        'dominant-baseline': m.top ? 'alphabetic' : m.baseline || 'auto', transform: m.rot ? `rotate(${m.rot} ${x} ${y})` : null,
        stroke: knockout, 'stroke-width': knockout ? haloWidth : null, 'stroke-linejoin': knockout ? 'round' : null, 'paint-order': knockout ? 'stroke' : null,
        'data-knockout': knockout, 'data-knockout-width': knockout ? haloWidth.toFixed(2) : null,
      }, m.under ? layer : words);
      let lines = `${m.text}`.split('\n');
      const wrapAt = m.wrap || (m.fit && m.fit[0]);
      if (wrapAt && lines.length === 1) lines = wrapWords(lines[0], wrapAt, { 'font-family': faceFor(style), 'font-size': fs, 'font-weight': weight });
      // a wrapped block is centred on its point, unless it hangs from it or names its own baseline
      if (lines.length > 1 && (m.fit || m.wrap) && !m.top && (m.baseline || 'auto') === 'auto') t.setAttribute('y', y - (lines.length - 1) * fs * lineHeight / 2);
      if (lines.length > 1) lines.forEach((line, k) => { el('tspan', { x, dy: k ? fs * lineHeight : 0 }, t).textContent = line; });
      else t.textContent = m.text;
      if (m.fit) {
        // smaller by 8% at a time until it fits its box (down to 8)
        const [fitW, fitH] = m.fit;
        let size = fs, box = t.getBBox();
        while ((box.width > fitW || box.height > fitH) && size > Math.min(8, smallest)) {
          size *= 0.92;
          t.setAttribute('font-size', size.toFixed(1));
          t.querySelectorAll('tspan').forEach((span, k) => { if (k) span.setAttribute('dy', size * lineHeight); });
          box = t.getBBox();
        }
        if (size < fs * 0.7) report.warnings.push(`${m.id || i}: text shrank to ${Math.round(size)}px to fit its box; shorter words would read better`);
      }
      if (!editing && !m.under && m.place !== false) placeLabel(t);
      anim(t, 'write', writeAnim(m.text), clock);
      return writeTime(m.text);
    }
    // Words wrapped greedily at a width, measured in their real font on the hidden probe.
    function wrapWords(text, maxW, font) {
      const probeText = el('text', font, probe), lines = [];
      const width = s => { probeText.textContent = s; return probeText.getComputedTextLength(); };
      let line = '';
      for (const word of text.split(' ')) {
        const longer = line ? `${line} ${word}` : word;
        if (line && width(longer) > maxW) { lines.push(line); line = word; } else line = longer;
      }
      lines.push(line);
      probeText.remove();
      return lines;
    }
    // A molecule from its SMILES string, drawn by SmilesDrawer in the card's colours and fitted to its box.
    const ATOM_COLOURS = () => ({ C: TONES.ink, O: TONES.coral, N: TONES.blue, F: TONES.leaf, CL: TONES.leaf, BR: TONES.brown, I: TONES.violet, P: TONES.orange,
      S: TONES.sun, B: TONES.peach, SI: TONES.brown, H: TONES.ink, BACKGROUND: 'transparent' });
    function paintMolecule(m, i, { layer }) {
      const [x, y] = m.at, { w, h } = m;
      const g = el('g', { transform: `translate(${x} ${y})` }, layer);
      const s = el('svg', { width: w, height: h, viewBox: `0 0 ${w} ${h}`, overflow: 'visible' }, g);
      s.setAttribute('data-smiles', m.smiles);
      const drawer = global.SmilesDrawer;
      if (!drawer) report.errors.push('a molecule needs SmilesDrawer on the page');
      else {
        const d = new drawer.SvgDrawer({ width: m.w, height: m.h, bondThickness: 1.6, bondLength: m.bond || 22, shortBondLength: 0.82, fontSizeLarge: 9, fontSizeSmall: 6,
          padding: 4, compactDrawing: false, terminalCarbons: false, explicitHydrogens: false, themes: { mate: ATOM_COLOURS() } });
        drawer.parse(m.smiles, tree => { d.draw(tree, s, 'mate', null, false); }, err => report.errors.push(`smiles: ${err}`));
        for (const bond of s.querySelectorAll('line')) { bond.setAttribute('stroke-linecap', 'round'); bond.setAttribute('stroke-width', '1.8'); }
        try {
          // zoom to the drawing (at most 1.9×), centred, with a little room round it
          const bb = s.getBBox();
          if (bb.width > 0) {
            const k = Math.min(m.w / (bb.width + 10), m.h / (bb.height + 10), 1.9), vw = m.w / k, vh = m.h / k;
            s.setAttribute('viewBox', `${bb.x + bb.width / 2 - vw / 2} ${bb.y + bb.height / 2 - vh / 2} ${vw} ${vh}`);
          }
        } catch (_) {}
        for (const atom of s.querySelectorAll('text')) { atom.setAttribute('font-family', FONT.body); atom.setAttribute('font-weight', '600'); }
      }
      anim(g, 'fadein', 0.6, clock);
      return 0.6;
    }

    // ---------------------------------------------------------------- the drawing, mark by mark
    // The cursor flies to each mark on an arc. A mark far from the last one waits for it (its ink starts when the
    // cursor lands), and marks after it never start before it; the first mark waits for the flight from wherever the
    // cursor was. Typing, copying, buttons and invisible dots happen where the cursor already is.
    const NO_FLIGHT = new Set(['type', 'copy', 'open', 'handoff']);
    let penAt = null;                                      // where the cursor last went
    let penLandsAt = 0;                                    // when it lands there, on the card's clock
    function penFlightBefore(m) {
      if (NO_FLIGHT.has(m.role) || (m.role === 'button' && m.do === 'dot') || (m.do === 'dot' && (+m.r || 3) < 1)) return 0;
      const b = markBox(m);
      if (!b) return 0;
      const to = [(b[0] + b[2]) / 2, (b[1] + b[3]) / 2], from = penAt;
      penAt = to;
      if (!from) return 0.45;
      const far = Math.hypot(to[0] - from[0], to[1] - from[1]);
      if (far < 110) return 0;                              // close by: the pen is already there
      return Math.min(0.55, 0.2 + far / 2400);
    }
    // A tie arrow (tie() in Mate's pieces: {tieTo: [x, y, w, h, gap, pad]}) starts where its row's words really end
    // (the model can only guess how long a line of words is). The row is the words beside the start it was given
    // (their middle within a line of it, on the near side); the arrow leaves the far end of the longest of them, at
    // that line's height, and stops at the photo's edge plus the gap.
    const NOT_A_ROW = new Set(['photo', 'tie', 'source']);
    function snapTie(m) {
      const tie = m.tieTo, from = m.pts[0];
      if (!Array.isArray(tie) || !Array.isArray(from)) return;
      const [bx, by, bw, bh, gap, pad] = tie.map(Number);
      if ([bx, by, bw, bh, ...from.slice(0, 2)].some(v => !Number.isFinite(v)) || from.length < 2) return;
      const toRight = bx + bw / 2 > from[0], g = gap || 6, p = pad || 8;
      // words past the start, or reaching the photo, are not the row's (a missing gap never rules words out)
      const away = o => (toRight ? o.x > from[0] + 20 || o.x + o.w > bx - gap : o.x + o.w < from[0] - 20 || o.x < bx + bw + gap);
      const further = (o, than) => (toRight ? o.x + o.w > than.x + than.w : o.x < than.x);
      let row = null;
      for (const e of [...words.querySelectorAll('text')].filter(e => !e.__gone && e.ownerSVGElement === svg && !NOT_A_ROW.has(e.__role))) {
        const o = cardBox(e, false);
        if (!o || !o.w || Math.abs(o.y + o.h / 2 - from[1]) > Math.max(o.h, 20) || away(o)) continue;
        if (!row || further(o, row)) row = o;
      }
      if (!row) return;
      const start = [toRight ? row.x + row.w + p : row.x - p, row.y + row.h / 2];
      const cx = bx + bw / 2, cy = by + bh / 2, dx = start[0] - cx, dy = start[1] - cy;
      if (!dx && !dy) return;
      // how far from the photo's middle toward the start the photo (plus the gap) reaches, as a fraction of the way
      const reachAlong = (delta, half) => (delta ? (half + g) / Math.abs(delta) : Infinity);
      const reach = Math.min(reachAlong(dx, bw / 2), reachAlong(dy, bh / 2));
      if (reach < 1) m.pts = [start, [cx + dx * reach, cy + dy * reach]];
    }
    const stepOf = m => (m.step != null ? stepKey(m) : 0);
    const farOut = p => Array.isArray(p) && (p[0] < -W * 0.1 || p[0] > W * 1.1 || p[1] < -H * 0.1 || p[1] > H * 1.1);
    // Paints marks on the card's clock. Unpaced, a step's strokes speed up to fit its budget and a new step waits
    // 0.3 s. live: the clock follows real time. d.paced: the pacer chose when this mark starts (now) and its pace
    // (d.pace); d.i is its index (a new turn's dropped marks leave gaps).
    function draw(marks, live = false, d = {}) {
      if (live) { const now = nowS(); clock = d.paced ? now + 0.02 : Math.max(clock, now + 0.05); delayBase = now; }
      const stepTime = {};
      for (const m of marks) stepTime[stepOf(m)] = (stepTime[stepOf(m)] || 0) + est(m);
      const single = marks.length === 1 && d.i != null;
      let highest = total - 1;
      marks.forEach((m, j) => {
        const i = single ? d.i : total + j;
        highest = Math.max(highest, i);
        try {
          if (m.__skip) { m.__passed = true; return; }   // erased by an edit before it was drawn
          if (m._t != null) { clock = m._t; pace = m._pace != null ? m._pace : 1; }   // a schedule worked out before (paced replays, frames)
          else if (d.paced) pace = d.pace ?? 1;
          else {
            pace = Math.min(1, BUDGET / (stepTime[stepOf(m)] || 1));
            if (m.step != null && lastStep != null && stepKey(m) !== lastStep) clock += 0.3;   // a breath between steps
          }
          if (m.step != null) lastStep = stepKey(m);
          if (!m.__tied && m.tieTo && Array.isArray(m.pts) && m.pts.length > 1) { m.__tied = true; snapTie(m); }
          if (live && d.paced) {
            const flight = penFlightBefore(m);
            clock = Math.max(clock, penLandsAt);
            if (flight) penLandsAt = clock = clock + flight;
          }
          const start = clock;
          if (Array.isArray(m.pts) && m.pts.some(farOut)) report.warnings.push(`${m.id || i}: a point of this ${m.do} lies far off the card`);
          [cap, capM, capKey] = [NODES[i] = [], MASKS[i] = [], i];
          MK[i] = m;
          let dur;
          try { dur = paint(m, i); } finally { cap = null; capM = null; }
          if (m.__xf) for (const n of NODES[i]) setXf(wrap(n), m.__xf);   // moved or scaled by an edit before it was drawn
          try { fitWindowsTo(m, i); } catch (_) { /* a window that cannot grow keeps its size */ }
          placed[i] = [+start.toFixed(3), +(start + dur * Math.max(pace, 0.35)).toFixed(3)];
          // the next mark starts before this one's ink ends (a dot sooner still)
          clock += dur * pace * (m.do === 'dot' ? 0.5 : 0.7);
        } catch (e) { report.errors.push(`${m.id || i}: ${e.message}`); }   // one mark's failure does not stop the drawing
      });
      total = Math.max(total + (single ? 0 : marks.length), highest + 1);
      report.marks = total;
    }
    // The finished card's report: what runs off the card and which words overlap (where they are now, after nudges
    // and edits; erased ones left out), at most 14 warnings, and how long the drawing takes.
    function finish() {
      const live = e => e.ownerSVGElement === svg && !e.__gone;
      for (const e of [...main.querySelectorAll('text,path'), ...words.querySelectorAll('text')].filter(live)) {
        const b = cardBox(e, false);
        if (b && b.w && (b.x < -2 || b.y < -2 || b.x + b.w > W + 2 || b.y + b.h > H + 2)) report.warnings.push(`${e.tagName} at ${Math.round(b.x)},${Math.round(b.y)} runs off the card`);
      }
      const texts = [...words.querySelectorAll('text')].filter(live).map(e => ({ b: cardBox(e, false), t: e.textContent.slice(0, 24) })).filter(x => x.b && x.b.w);
      let overlaps = 0;
      texts.forEach((a, k) => texts.slice(k + 1).forEach(c => {
        const A = a.b, B = c.b;
        const ix = Math.min(A.x + A.w, B.x + B.w) - Math.max(A.x, B.x), iy = Math.min(A.y + A.h, B.y + B.h) - Math.max(A.y, B.y);
        if (ix > 3 && iy > 4) { overlaps++; report.warnings.push(`the words "${a.t}" and "${c.t}" overlap`); }
      }));
      report.overlaps = overlaps;
      Object.assign(report, { warnings: Array.from(new Set(report.warnings)).slice(0, 14), duration: Number(clock.toFixed(2)) });
      host.dataset.report = JSON.stringify(report);           // where a page that shows the card can read it
      return report;
    }

    // ---------------------------------------------------------------- changing what is already on the card
    // A mark's nodes sit in several layers (wash under, strokes, words). An edit repaints a mark with its own seed
    // (so it wobbles as before) at its own depth, moves or scales its nodes inside wrapper groups, or runs its pen
    // backwards. Edits are tweens on one timer: animation frames only while something changes every frame, otherwise
    // one wake-up at the next start or end. settle() sends every running edit to its end (an interruption).
    const TW = new Set();                                  // the running tweens
    const fresh = new Set();                               // elements an edit just painted, still drawing in
    const ease = p => (p < 0.5 ? 2 * p * p : 1 - (2 - 2 * p) ** 2 / 2);
    const EASE_CSS = 'cubic-bezier(.455,.03,.515,.955)';     // the same curve, for hosts that animate a motion themselves
    // A host that animates on its own (the native canvas, through Core Animation) is told each edit's changes once
    // (global.__mateMotion(items, at, dur, ease)) instead of a style change every frame.
    const motionHost = () => (typeof global.__mateMotion === 'function' ? global.__mateMotion : null);
    const hasRaf = typeof requestAnimationFrame === 'function';   // the native canvas has none: timers only
    const nowS = () => (performance.now() - t0) / 1000;
    const timer = { id: 0, onFrame: false, at: Infinity };
    // wake the tweens in ms (0: on the next frame); a wake-up already due sooner stands
    function arm(ms) {
      const t = performance.now(), at = Math.max(0, ms) + t;
      if (timer.id && at >= timer.at - 1) return;
      if (timer.id) { if (timer.onFrame) cancelAnimationFrame(timer.id); else clearTimeout(timer.id); }
      timer.onFrame = ms <= 0 && hasRaf;
      if (timer.onFrame) { timer.id = requestAnimationFrame(frame); timer.at = t; }
      else { timer.id = setTimeout(frame, ms <= 0 ? 16 : ms); timer.at = at; }
    }
    function frame() {
      timer.id = 0; timer.at = Infinity;
      const t = performance.now();
      let next = Infinity, everyFrame = false;
      for (const tw of [...TW]) {
        if (!TW.has(tw)) continue;                         // an earlier tween's done() settled it
        if (t < tw.s) { next = Math.min(next, tw.f ? tw.s : tw.s + tw.d); continue; }   // not started yet
        const p = Math.min((t - tw.s) / tw.d, 1);
        if (tw.f) tw.f(ease(p));
        if (p >= 1) { TW.delete(tw); tw.done?.(); }
        else if (tw.f) everyFrame = true;
        else next = Math.min(next, tw.s + tw.d);
      }
      if (!TW.size) return;
      if (everyFrame) arm(0); else if (next < Infinity) arm(next - performance.now());
    }
    // A tween from delay s for dur s: f(eased progress) each frame (none: nothing changes along the way), done() at
    // the end. decl: nodes a host is animating, whose animation settle() stops.
    function tween(delay, dur, f, done, decl) {
      // times in milliseconds: s its start, d its length (at least 1)
      const tw = { s: performance.now() + 1000 * delay, d: Math.max(1, 1000 * dur), f, done, decl };
      TW.add(tw);
      arm(Math.max(0, (f ? tw.s : tw.s + tw.d) - performance.now()));
      return tw;
    }
    function settle() {
      for (const tw of [...TW]) {
        TW.delete(tw);
        if (tw.f) tw.f(1);
        for (const n of tw.decl || []) n.style.animation = 'none';
        if (tw.done) tw.done();
      }
      for (const n of fresh) n.style.animation = 'none';
      fresh.clear();
    }
    // the group a node moves in, made on first use at the node's depth
    function wrap(n) {
      if (!n.__wrap) {
        const g = document.createElementNS(NS, 'g');
        g.__k = n.__k; g.__xf = [1, 0, 0];
        n.parentNode.insertBefore(g, n); g.appendChild(n);
        n.__wrap = g;
      }
      return n.__wrap;
    }
    function setXf(g, xf) {
      g.__xf = xf;
      const k = +xf[0].toFixed(4);
      g.setAttribute('transform', `matrix(${k} 0 0 ${k} ${+xf[1].toFixed(2)} ${+xf[2].toFixed(2)})`);
    }
    // a repainted node keeps its mark's depth: just before the first node of a later mark
    function placeByKey(n) {
      const layer = n.parentNode;
      const later = layer && [...layer.childNodes].find(c => c !== n && c.__k != null && c.__k > n.__k);
      if (later) layer.insertBefore(n, later);
    }
    // Paints mark m (seed i) at depth `key`, starting `at` s from now at pace p, leaving the drawing's own clock alone.
    function paintAt(m, i, key, at, p, repaint) {
      const saved = { clock, pace, delayBase }, now = nowS();
      delayBase = now; clock = now + at; pace = p;
      [cap, capM, capKey, editing] = [[], [], key, !!repaint];
      let dur = 0.3;
      try { dur = paint(m, i); } catch (e) { report.errors.push(`an edit of mark ${i} failed: ${e.message}`); }
      const nodes = cap, masks = capM;
      cap = capM = null; editing = false;
      ({ clock, pace, delayBase } = saved);
      nodes.forEach(n => { placeByKey(n); fresh.add(n); });
      for (const mask of masks) fresh.add(mask);
      if (m.__xf) for (const n of nodes) setXf(wrap(n), m.__xf);
      [NODES[i], MASKS[i], MK[i]] = [nodes, masks, m];
      try { fitWindowsTo(m, i); } catch (_) { /* as in draw() */ }
      const shown = dur * Math.max(p, 0.35);
      tween(at + shown + 0.1, 0.001, null, () => { for (const n of [...nodes, ...masks]) fresh.delete(n); });
      return { nodes, masks, dur: shown, adv: dur * (m.do === 'dot' ? 0.5 : 0.7) * p };
    }
    // Takes nodes off the card: the pen runs backwards over strokes, everything else fades; then they are removed.
    function unpaint(nodes, masks, at, dur) {
      const penOf = {};
      for (const reveal of masks || []) { const mask = reveal.parentNode; if (mask && mask.id) penOf[mask.id] = reveal; }
      const pen = [], fade = [];
      for (const n of nodes) {
        n.__gone = true;
        const masked = /url\(#([^)]+)\)/.exec(n.getAttribute('mask') || '');
        if (masked && penOf[masked[1]]) pen.push(penOf[masked[1]]); else fade.push(n);
      }
      const remove = () => {
        for (const n of nodes) { const w = n.__wrap; (w && w.parentNode ? w : n).remove(); }
        for (const reveal of masks || []) if (reveal.parentNode) reveal.parentNode.remove();
      };
      const motion = motionHost();
      if (motion) {
        motion([...pen.map(node => ({ node, prop: 'dash', from: 0, to: 1 })), ...fade.map(node => ({ node, prop: 'opacity', from: 1, to: 0 }))], at, dur, EASE_CSS);
        return tween(at, dur, null, remove, [...pen, ...fade]);
      }
      return tween(at, dur, p => {
        for (const reveal of pen) { reveal.style.animation = 'none'; reveal.style.strokeDashoffset = String(p); }
        for (const n of fade) { n.style.animation = 'none'; n.style.opacity = String(1 - p); }
      }, remove);
    }
    // Glides nodes to a new transform [scale, tx, ty] (straight through the matrix, so a scale keeps its centre).
    function moveNodes(nodes, to, at, dur) {
      const groups = nodes.filter(n => !n.__gone && n.parentNode).map(wrap), from = groups.map(g => g.__xf.slice());
      const motion = motionHost();
      if (motion) {
        for (const g of groups) setXf(g, to);              // where they end up; the host glides them there
        motion(groups.map((node, j) => ({ node, prop: 'xf', from: from[j], to: to.slice() })), at, dur, EASE_CSS);
        return tween(at, dur, null, null, groups);
      }
      return tween(at, dur, p => groups.forEach((g, j) => setXf(g, from[j].map((v, k) => v + (to[k] - v) * p))));
    }
    // Where a drawn mark really is on the card (words measured in their font), or null. The app's DOM has no
    // isConnected (a node on the canvas has its <svg> above it), so that is the test there.
    function domBox(i) {
      let box = null;
      for (const n of NODES[i] || []) {
        const onCard = n.isConnected ?? !!n.ownerSVGElement;
        if (n.__gone || !onCard) continue;
        const r = cardBox(n, false);
        if (!r || (!r.w && !r.h)) continue;
        const q = [r.x, r.y, r.x + r.w, r.y + r.h];
        box = box ? [Math.min(box[0], q[0]), Math.min(box[1], q[1]), Math.max(box[2], q[2]), Math.max(box[3], q[3])] : q;
      }
      return box;
    }
    const edit = { NODES, MASKS, MK, paintAt, unpaint, moveNodes, settle, tween, domBox, now: nowS, get busy() { return TW.size > 0; } };
    // when mark i starts drawing, in seconds from now, and for how long (the drawing's sounds land on its ink)
    const startsIn = i => (placed[i] ? [placed[i][0] - nowS(), placed[i][1] - placed[i][0]] : null);
    return { draw, finish, report, svg, placed, edit, hooks, startsIn };
  }

  // ================================================================ the card in words: parts, boxes and the model's view (DOM-free)
  // The model sees the card as parts: the statements under one of the program's own comment headings ("// Big bushy
  // tail"), one piece, one text, or statements written together with no blank line between them. Parts are numbered
  // p1, p2, ... in the order the program wrote them, so an id stays put while more code streams in. Each mark has an
  // id too (m0, m1, ...); the marks edits make are numbered from m2000.
  const EDIT_BASE = 2000;
  // The program's lines: where each starts, whether it is blank, its comment when the whole line is one (full) or
  // its comment after code (tail). Inside a block comment every line is comment; a line starting with * outside one
  // is code (an expression carried on: "  * 2").
  function lineIndex(code) {
    const lines = [];
    let at = 0, inBlock = false;
    code.split('\n').forEach(line => {
      const t = line.trim(), entry = { s: at, blank: !t, full: null, tail: null };
      if (inBlock || t.startsWith('/*')) {
        entry.full = t.replace(/^\/?\*+\/?\s*/, '').replace(/\*\/\s*$/, '').trim();
        inBlock = !t.includes('*/', inBlock ? 0 : 2);   // the comment goes on past this line
      } else if (t.startsWith('//')) entry.full = t.replace(/^\/\/+\s*/, '').trim();
      else if (t) {
        const k = commentAt(line);
        if (k >= 0) entry.tail = line.slice(k).replace(/^\/\/+\s*/, '').trim() || null;
      }
      lines.push(entry);
      at += line.length + 1;
    });
    return lines;
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
  // the index of the line holding character offset `at` (lines from lineIndex)
  function lineOf(lines, at) {
    let lo = 0, hi = lines.length - 1;
    while (lo < hi) {
      const mid = (lo + hi + 1) >> 1;
      if (lines[mid].s <= at) lo = mid; else hi = mid - 1;
    }
    return lo;
  }
  const TEXT_SIZE = { title: 24, body: 17 };
  const textSize = m => m.size || TEXT_SIZE[m.style] || 20;
  const growBox = (b, pad) => b && [b[0] - pad, b[1] - pad, b[2] + pad, b[3] + pad];
  const finitePoints = points => (points || []).filter(p => Array.isArray(p) && isFinite(p[0]) && isFinite(p[1]));
  // Text's box from the program's numbers: the widest line in the same letter widths as ink boxes, wrapped into its
  // fit or wrap width (a wrapped block is centred on its point), each further line a line height lower.
  function textBox(m, [x, y]) {
    const size = textSize(m), lines = String(m.text).split('\n'), widest = Math.max(...lines.map(s => textW(s, size, m.style)));
    const boxed = m.fit || m.wrap, width = m.fit ? Math.min(m.fit[0], widest) : m.wrap ? Math.min(m.wrap, widest) : widest;
    const rows = boxed ? Math.max(lines.length, Math.ceil(widest / (width || 1))) : lines.length;
    const left = x - (m.anchor === 'middle' ? width / 2 : m.anchor === 'end' ? width : 0);
    const top = y - size * 0.8 - (rows > 1 && boxed ? (rows - 1) * size * LINE_HEIGHT / 2 : 0);
    return [left, top, left + width, top + size * 1.05 + (rows - 1) * size * LINE_HEIGHT];
  }
  // A mark's box [x0, y0, x1, y1] from its data, moved and scaled as an edit left it; a path by the points its pen
  // draws (relative commands too). null when the mark has no place of its own.
  function markBox(m) {
    if (m == null || typeof m !== 'object') return null;
    const pad = (m.size || 3) / 2, at = Array.isArray(m.at) ? m.at : null;
    const around = points => { const ok = finitePoints(points); return ok.length ? growBox(boxOf(ok), pad) : null; };
    let b = null;
    if (m.do === 'line' || m.do === 'arrow' || m.do === 'poly') b = around(m.pts);
    else if (m.do === 'path') { const [dx, dy] = m.shift || [0, 0]; b = around(pathRuns(m.d).flat().map(p => [p[0] + dx, p[1] + dy])); }
    else if (at) {
      const [x, y] = at;
      switch (m.do) {
        case 'circle': case 'ellipse': {
          let rx = +(m.r || m.rx) || 0, ry = +(m.r || m.ry) || 0;
          if (m.rot) rx = ry = Math.max(rx, ry);           // turned: whatever way, it stays inside the bigger circle
          b = [x - rx - pad, y - ry - pad, x + rx + pad, y + ry + pad];
          break;
        }
        case 'dot': { const r = +m.r || 3; b = [x - r, y - r, x + r, y + r]; break; }
        case 'rect': case 'highlight': case 'molecule': case 'stage3d': case 'image': case 'window': {
          const w = +m.w || 0, h = +m.h || 0;
          b = [Math.min(x, x + w), Math.min(y, y + h), Math.max(x, x + w), Math.max(y, y + h)];
          break;
        }
        case 'text': b = textBox(m, at); break;
      }
    }
    if (!b || !m.__xf) return b;
    const [k, dx, dy] = m.__xf;
    return [b[0] * k + dx, b[1] * k + dy, b[2] * k + dx, b[3] * k + dy];
  }
  const unionBox = boxes => boxes.filter(Boolean).reduce((a, b) => (a ? [Math.min(a[0], b[0]), Math.min(a[1], b[1]), Math.max(a[2], b[2]), Math.max(a[3], b[3])] : b.slice()), null);
  const fmtBox = b => (b ? `[${[b[0], b[1], b[2] - b[0], b[3] - b[1]].map(Math.round).join(',')}]` : '[?]');
  // words squeezed to one line of at most n characters, the last one an ellipsis when cut
  const clip = (s, n) => { const one = String(s).replace(/\s+/g, ' ').trim(); return one.length <= n ? one : `${one.slice(0, n - 1)}…`; };
  // numbers in a 3D description, to two places
  const n2 = v => +(+v).toFixed(2);
  const fmt3 = v => (Array.isArray(v) ? `[${v.map(n2).join(',')}]` : '');
  const SIZES_3D = ['r', 'h', 'size', 'inner', 'outer', 'tube', 'depth'];
  // a colour by its tone's name when it is one of the tones
  const toneName = c => { const hex = String(c).toLowerCase(); return Object.entries(TONES).find(([, v]) => v.toLowerCase() === hex)?.[0] || String(c); };
  // A 3D part in words: its name when the program gave it one, kind, sizes, where it is and how it is turned (left
  // out for a row of copies, which differ only there), colour, material and tint as the program named them, and the
  // group it hangs from.
  function describe3dPart(m, withoutPlace) {
    const p = m.params || {}, spanned = Array.isArray(p.from) && Array.isArray(p.to), words = [m.kind];
    for (const k of SIZES_3D) if (p[k] != null && !(spanned && k === 'h')) words.push(`${k}=${Array.isArray(p[k]) ? fmt3(p[k]) : n2(p[k])}`);
    if (spanned && !withoutPlace) words.push(`from ${fmt3(p.from)} to ${fmt3(p.to)}`);
    if (Array.isArray(p.points)) words.push(`${p.points.length} points`);
    if (Array.isArray(p.profile)) words.push(`profile of ${p.profile.length} points`);
    if (!withoutPlace) {
      const placed = m.pos && m.pos.some(n => +n);
      if ((m.kind !== 'group' && !spanned) || placed) words.push(`at ${fmt3(m.pos)}`);
      if (m.rotate3 && m.rotate3.some(n => +n)) words.push(`rotate ${fmt3(m.rotate3)}`);
    }
    const material = m.material || {};
    if (material.color) words.push(String(material.color));
    if (m.three && (material.mat || material.tint)) words.push([material.mat, material.tint ? toneName(material.tint) : null].filter(Boolean).join(' '));
    if (m.parent) words.push(`in ${m.parent}`);
    return (m.three && m.name ? `${m.name}: ` : '') + words.join(' ');
  }
  // One mark in a few words: its kind and colours (3D figures and their parts by name, so a follow-up builds on them).
  function markLabel(m) {
    if (!m) return '?';
    const op = m.op || {};
    switch (m.do) {
      case 'stage3d': return `3D figure ${m.id}`;
      case 'part3d': return `${m.id} ${describe3dPart(m)}`;
      case 'label3d': return `3D label "${String(m.text).slice(0, 30)}"`;
      case 'motion3d': return `3D ${op.kind || ''} motion of ${op.target || ''}`;
      case 'camera3d': return '3D camera';
      case 'tick3d': return '3D tick (moves the figure every frame)';
      case 'text': return `text ${m.style || 'hand'} ${Math.round(textSize(m))} ${m.tone || 'ink'}${m.weight ? ` weight ${m.weight}` : ''}`;
      case 'highlight': return `highlight ${m.tone || 'butter'}`;
      case 'window': return `window${m.title ? ` "${String(m.title).slice(0, 30)}"` : ''} ${m.board || 'plain'} board`;
      case 'dot': return `dot ${m.tone || 'ink'}`;
    }
    const words = [m.do === 'line' && m.smooth ? 'curve' : m.do];
    const filled = m.fill && m.fill !== 'none';
    if (filled) words.push(`fill ${m.fill}`);
    if (m.outline !== false || !m.fill) words.push(filled ? `line ${m.tone || 'ink'}` : m.tone || 'ink');
    // a program's dash dashes lines and arrows only; an edit can dash any outline
    if (((m.do === 'line' || m.do === 'arrow') && m.dash) || m.__dash) words.push('dashed');
    return words.join(' ');
  }
  // Where a box sits on the card in a word or two: top-left, top, ... centre ... bottom-right (by thirds).
  function zoneOf(b, W, H) {
    if (!b) return '';
    const third = (v, low, high) => (v < 0.34 ? low : v > 0.66 ? high : '');
    const v = third((b[1] + b[3]) / 2 / H, 'top', 'bottom'), h = third((b[0] + b[2]) / 2 / W, 'left', 'right');
    return v && h ? `${v}-${h}` : v || h || 'centre';
  }
  // The first string argument at the top level of a call: what the piece says, not an option inside {...}.
  function firstWords(call) {
    let top = '', depth = 0, quote = null;
    for (let k = 0; k < call.length; k++) {
      const ch = call[k];
      if (quote) {
        if (depth === 0) top += ch;
        if (ch === '\\') { k++; if (depth === 0) top += call[k] || ''; } else if (ch === quote) quote = null;
      } else if (ch === '"' || ch === "'" || ch === '`') { quote = ch; if (depth === 0) top += ch; }
      else if (ch === '{') depth++;
      else if (ch === '}') depth = Math.max(0, depth - 1);
      else if (depth === 0) top += ch;
    }
    const found = /"((?:[^"\\]|\\.)*)"|'((?:[^'\\]|\\.)*)'|`([^`]*)`/.exec(top);
    return found ? found[1] || found[2] || found[3] || '' : '';
  }
  // From b, past white space and comments, to where a statement's code starts (at most e).
  function codeStart(code, b, e) {
    for (;;) {
      while (b < e && /\s/.test(code[b])) b++;
      const close = code.startsWith('//', b) ? '\n' : code.startsWith('/*', b) ? '*/' : null;
      if (!close) return b;
      const j = code.indexOf(close, b + 2);
      b = j < 0 ? e : Math.min(close === '\n' ? j : j + 2, e);
    }
  }
  // The card as parts a model can name. A part is the statements under one comment heading, or one call of a piece
  // (Mate's paper, sticky, receipt, ...; a helper the program defined; graph, timeline), or one text; consecutive
  // statements of a step join the part before them unless a heading, a trailing comment or a blank line splits them.
  // An edit mark ({do: 'edit'}) is never part of a part, and a statement that edits starts a new part.
  // o: {code, stmts (from attribute), mark(i), box(i), pending(i), over, added, W, H, from (helpers defined before this
  //     offset, Mate's own pieces, are not listed), drawnOnly (parts list only what is drawn: marks still waiting for
  //     their line are left out)}
  const PIECE_CALLS = new Set(['graph', 'timeline', 'molecule']);
  const SCENE_CONST = /^(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*scene3d\s*\(/;
  const HELPER_SIGNATURE = [/^function\s+([A-Za-z_$][\w$]*)\s*\(([^)]*)\)/, /^(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*(?:function\s*)?\(?([^)=]*?)\)?\s*=>/];
  const HELPER_NAME = [/^function\s+([A-Za-z_$][\w$]*)/, /^(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*(?:function\b|\(|[A-Za-z_$][\w$]*\s*=>)/];
  const firstMatch = (patterns, s) => patterns.reduce((found, re) => found || re.exec(s), null);
  function describe(o) {
    const code = o.code || '', lines = lineIndex(code), mark = o.mark, parts = [], helpers = [], figures = [], helperNames = new Set();
    // the part being grown, the heading over the current run, and a heading still waiting for code
    let growing = null, section = null, waitingHeading = null, lastLine = -1;
    const newPart = p => { p.id = `p${parts.length + 1}`; parts.push(p); return p; };
    for (const st of o.stmts ?? []) {
      const start = codeStart(code, st.s, st.e);
      if (start >= st.e) continue;
      const first = lineOf(lines, start);
      let last = lineOf(lines, Math.max(start, st.e - 1));
      while (last > first && (lines[last].blank || lines[last].full != null)) last--;
      const body = code.slice(start, st.e).trim();
      // its heading: the whole-line comments just above it ("Plan ..." is the program's plan, not a heading)
      const above = [];
      for (let k = first - 1; k > lastLine && k >= 0 && lines[k].full != null; k--) above.unshift(lines[k].full);
      const heading = above.filter(x => x && !/^plan\b/i.test(x)).join(' / ') || null;
      const blankBefore = lines.slice(lastLine + 1, Math.max(lastLine + 1, first - above.length)).some(l => l && l.blank);
      lastLine = last;
      const scene = SCENE_CONST.exec(body);
      if (scene) {
        const stage = Array.from({ length: st.n1 - st.n0 }, (_, j) => mark(st.n0 + j)).find(m => m && m.do === 'stage3d');
        if (stage) figures.push({ name: scene[1], stage: stage.id });
      }
      const defined = scene ? null : firstMatch(HELPER_SIGNATURE, body);
      if (defined && start >= (o.from || 0)) helpers.push(`${defined[1]}(${defined[2].replace(/\s+/g, ' ').trim()})`);
      const named = firstMatch(HELPER_NAME, body);
      if (named) helperNames.add(named[1]);   // later calls of it are pieces
      if (blankBefore) { section = null; waitingHeading = null; }
      const drawn = [];
      let edits = 0;
      for (let i = st.n0; i < st.n1; i++) { const m = mark(i); if (m && m.do === 'edit') edits++; else drawn.push(i); }
      if (!drawn.length) {
        // drew nothing: an edit ends the part, a lone heading waits for the code under it, a definition forgets it
        if (edits) { growing = null; waitingHeading = null; } else if (heading && !defined) waitingHeading = heading; else if (defined) waitingHeading = null;
        continue;
      }
      if (edits) growing = null;
      const own = heading || waitingHeading;
      waitingHeading = null;
      section = heading || section;
      const tail = lines[last].tail || lines[first].tail, m0 = mark(drawn[0]), step = m0 ? m0.step : null, turn = (m0 && m0.turn) || 1;
      if (drawn.every(i => mark(i) && mark(i).do === 'text')) {
        for (const i of drawn) growing = newPart({ marks: [i], step, turn, text: true, desc: null });
        continue;
      }
      const isCall = /^[A-Za-z_$][\w$.]*\s*\(/.test(body) && !/^(?:for|if|while|switch)\b/.test(body);
      const call = isCall ? body.replace(/;$/, '') : null;
      const callee = call && /^([A-Za-z_$][\w$]*)\s*\(/.exec(call);
      const piece = callee && (helperNames.has(callee[1]) || PIECE_CALLS.has(callee[1])) ? callee[1] : null;
      const desc = own ? (tail ? `${own}: ${tail}` : own) : tail ? (section ? `${section}: ${tail}` : tail) : null;
      if (piece) {
        newPart({ marks: drawn, step, turn, stmts: [{ call, n0: st.n0, n1: st.n1 }], piece, pieceText: firstWords(call), desc });
        growing = null;
        continue;
      }
      const startsNew = !growing || own || tail || growing.text || growing.tail || blankBefore || growing.step !== step || growing.turn !== turn;
      if (startsNew) growing = newPart({ marks: drawn, step, turn, tail: !!tail, stmts: [], desc });
      else growing.marks.push(...drawn);
      growing.stmts.push({ call, n0: st.n0, n1: st.n1 });
    }
    // what each part shows now (edits may have regrouped or erased its marks), its box, and how much is still to draw
    const over = o.over || {}, box = o.box || (i => markBox(mark(i)));   // regrouped parts, and where a mark is
    const all = [...parts, ...(o.added || [])];
    for (const p of all) {
      const regrouped = over[p.id];
      if (regrouped) { p.marks = regrouped.marks.slice(); if (regrouped.desc) p.desc = regrouped.desc; p.text = false; }
      const waiting = i => !!(o.pending && o.pending(i));
      p.vis = p.marks.filter(i => mark(i) && !mark(i).__erased && !(o.drawnOnly && waiting(i)));
      p.box = unionBox(p.vis.map(i => box(i)));
      p.pending = p.vis.filter(waiting).length;
    }
    const texts = all.filter(p => p.vis.length === 1 && mark(p.vis[0]).do === 'text');   // parts that are one text
    const behind = (t, b) => Math.min(t[2], b[2]) - Math.max(t[0], b[0]) > 0.4 * (t[2] - t[0]) && Math.min(t[3], b[3]) - Math.max(t[1], b[1]) > 0.3 * (t[3] - t[1]);
    for (const p of all) {
      const ms = p.vis.map(mark), firstText = ms.find(m => m.do === 'text');
      // a highlight is named by the words it sits behind
      if (!p.desc && ms.length && p.box && ms.every(m => m.do === 'highlight')) {
        const under = texts.filter(t => t.box && behind(t.box, p.box)).slice(0, 2).map(t => `"${clip(mark(t.vis[0]).text, 30)}"`);
        if (under.length) p.desc = `highlight behind ${under.join(' and ')}`;
      }
      if (!p.desc && p.piece) p.desc = `${p.piece}${p.pieceText ? ` "${clip(p.pieceText, 40)}"` : ''}, ${zoneOf(p.box, o.W, o.H)}`;
      if (!p.desc) {
        const kinds = [...new Set(ms.map(m => (m.do === 'line' && m.smooth ? 'curve' : m.do)))];
        p.desc = ms.length === 1 && firstText ? `"${clip(firstText.text, 48)}"`
          : `${kinds.slice(0, 3).join(' + ')}${firstText ? ` with "${clip(firstText.text, 30)}"` : ''}, ${zoneOf(p.box, o.W, o.H)}`;
      }
      p.kind = ms.length && ms.every(m => m.do === 'text') ? 'text' : firstText ? 'mixed' : 'shape';
    }
    const card = { parts: all, helpers, figures };
    return card;
  }
  // a run of marks: m3, or m3–m9
  const markRange = v => (v.length > 1 ? `m${v[0]}–m${v[v.length - 1]}` : `m${v[0]}`);
  const marksCount = n => `${n} mark${n > 1 ? 's' : ''}`;
  // ids as runs: p1–p62, x1
  function idRanges(ids) {
    const runs = [];
    for (const id of ids) {
      const m = /^([a-z]+)(\d+)$/.exec(id), last = runs.at(-1);
      if (m && last && last.prefix === m[1] && last.to + 1 === +m[2]) last.to = +m[2];
      else runs.push(m ? { prefix: m[1], from: +m[2], to: +m[2] } : { id });
    }
    return runs.map(r => r.id || (r.from === r.to ? `${r.prefix}${r.from}` : `${r.prefix}${r.from}–${r.prefix}${r.to}`)).join(', ');
  }
  // How a part's marks are listed in the card's words.
  function partMarks(p, o) {
    // one piece (a sticky, a receipt, ...): how many marks, and the other words on it (a small, wordless one lists its
    // marks like any part)
    const hasWords = p.vis.some(i => o.mark(i).do === 'text');
    if (p.piece && !o.over[p.id] && (o.brief || hasWords || p.vis.length > 3)) {
      const other = p.vis.map(o.mark).filter(m => m.do === 'text' && String(m.text) !== p.pieceText).map(m => `"${clip(m.text, 26)}"`);
      const more = other.length > 4 ? ', …' : '';
      return `${marksCount(p.vis.length)} (${markRange(p.vis)})${other.length ? `, with the words ${other.slice(0, 4).join(', ')}${more}` : ''}`;
    }
    if (o.brief) return `${marksCount(p.vis.length)} (${markRange(p.vis)})`;
    // a part made of several helper calls (flower(45, 410, 'pink'), ...): each call with its marks
    const byCall = p.stmts && p.stmts.length > 1 && !o.over[p.id] && p.stmts.every(t => t.call && t.n1 - t.n0 >= 3) && !p.vis.some(i => /3d$/.test((o.mark(i) || {}).do || ''));
    if (byCall) {
      const listed = p.stmts.map(t => [t.call, p.vis.filter(i => i >= t.n0 && i < t.n1)]).filter(([, v]) => v.length);
      return listed.map(([call, v]) => `${clip(call, 44)} (m${v[0]}–m${v.at(-1)})`).join(' + ');
    }
    // Runs of alike marks are one entry ("3× rect fill sky (m4–m6)"); a row of alike 3D parts (rungs, bolts) is one
    // entry with its id range, so a big figure still fits.
    const runs = [];
    for (const i of p.vis) {
      const m = o.mark(i), label = m && m.do === 'part3d' ? `part3d|${describe3dPart(m, true)}` : markLabel(m), last = runs[runs.length - 1];
      if (last && last.label === label && m.do !== 'text' && last.to === i - 1) { last.to = i; last.n++; last.end = m; }
      else runs.push({ label, from: i, to: i, n: 1, m, end: m });
    }
    return runs.map(r => {
      if (r.label.startsWith('part3d|')) return r.n > 1 ? `${r.n}× ${r.m.id}–${r.end.id} ${r.label.slice(7)} (m${r.from}–m${r.to})` : `${markLabel(r.m)} (m${r.from})`;
      const words = r.m.do === 'text' && p.vis.length > 1 ? ` "${clip(r.m.text, 30)}"` : '';
      return `${r.n > 1 ? `${r.n}× ` : ''}${r.label}${words} (m${r.from}${r.n > 1 ? `–m${r.to}` : ''})`;
    }).join(' + ');
  }
  // The card as short lines a model reads: its size and what was asked, the program's own helpers and 3D figures,
  // then every part with its id, what it is, its box and its marks, under the step (and turn) that drew it and what
  // Mate said then. o.maxChars keeps it short: past it, parts list only their mark ranges, then the oldest parts are
  // left out a few at a time.
  function stateText(d, o) {
    const limit = o && o.maxChars;
    if (limit && !o.brief && !o.skip) {
      // longer than the limit: parts by their mark ranges only, then fewer and fewer of the oldest parts
      const textWith = more => stateText(d, { ...o, maxChars: 0, ...more });
      const full = textWith({});
      if (full.length <= limit) return full;
      const shown = d.parts.filter(p => p.vis.length);
      let text = textWith({ brief: true });
      for (let leaveOut = 1; text.length > limit && leaveOut < shown.length; leaveOut++) text = textWith({ brief: true, skip: shown.slice(0, leaveOut) });
      return text;
    }
    o = { over: {}, ...o };
    const out = [], says = o.says || [], headed = new Set();
    const turnOf = x => x?.turn || 1;
    const manyTurns = says.some(x => turnOf(x) > 1) || d.parts.some(p => p.vis.length && turnOf(p) > 1);
    const saidIn = (turn, step) => says.filter(x => turnOf(x) === turn && x.step === step).map(x => x.text).join(' ');
    out.push(`The card is ${o.W} wide and ${o.H} high (x goes right, y goes down).${o.request ? ` The user asked: "${clip(o.request, 160)}".` : ''} ${o.status || ''}`.trim());
    if (d.helpers.length) out.push(`Functions the program defined (call them in code): ${d.helpers.slice(0, 12).join(', ')}`);
    if (d.figures && d.figures.length) {
      out.push(`3D figures already in the code (add to them; never draw a second one): ${d.figures.map(f => `${f.name} is ${f.stage}, its parts ${f.stage}p1, ${f.stage}p2, … listed below`).join('; ')}`);
    }
    const skipped = new Set(o.skip ?? []);
    if (skipped.size) out.push(`(${skipped.size} earlier parts left out: ${idRanges([...skipped].map(p => String(p.id)))})`);
    for (const p of d.parts) {
      if (skipped.has(p) || !p.vis.length) continue;
      const byEdit = String(p.id).startsWith('x'), key = `${turnOf(p)}/${p.step}`;
      if (p.step != null && !headed.has(key) && !byEdit) {
        headed.add(key);
        const said = saidIn(turnOf(p), p.step);
        out.push(`${manyTurns ? `Turn ${turnOf(p)}, step ${p.step}` : `Step ${p.step}`}${said ? `, as Mate said "${clip(said, 170)}"` : ''}`);
      }
      if (byEdit && !headed.has('x')) { headed.add('x'); out.push('Made by edits:'); }
      const toDraw = !p.pending ? '' : p.pending === p.vis.length ? ' (still to be drawn)' : ` (${p.pending} still to be drawn)`;
      out.push(`  ${p.id} ${clip(p.desc, 70)} ${fmtBox(p.box)}: ${partMarks(p, o)}${toDraw}`);
    }
    const latest = d.parts.filter(p => p.vis.length && !p.pending).slice(-1)[0];
    const notes = [latest && `latest part: ${latest.id}`, o.last && `last changed: ${o.last}`, o.pointed && `the user points at: ${o.pointed}`].filter(Boolean);
    if (notes.length) out.push(notes.join('; '));
    return out.join('\n');
  }

  // ================================================================ recolour and restyle a mark
  // When a filled shape takes a new colour its own outline follows, a shade deeper: the palette's next tone down
  // where there is one, else the colour at 62% of its brightness.
  const DEEPER = {
    butter: 'orange', sun: 'orange', orange: 'brown', peach: 'coral', coral: 'red', red: '#A32A2E', pink: 'coral', lilac: 'violet', violet: '#4A3AA8',
    sky: 'blue', blue: '#173F8A', mint: 'leaf', leaf: '#2A6E40', brown: '#5E3A1F', tan: 'brown', cream: 'tan', white: 'grey', grey: 'ink', ink: 'ink',
  };
  // A colour the way a program names it: a tone ('sky'), a colour word ('Light Blue'), or whatever was given.
  const normColor = c => {
    if (c == null) return c;
    const word = String(c).toLowerCase().replace(/[\s_-]+/g, '');
    return TONES[word] ? word : COLOR_WORDS[word] || String(c).trim();
  };
  function darker(c) {
    if (DEEPER[c]) return DEEPER[c];
    const hex = /^#?([0-9a-f]{6})$/i.exec(TONES[c] || c || '');
    if (!hex) return c;
    const v = parseInt(hex[1], 16);
    return '#' + [16, 8, 0].map(shift => Math.round(((v >> shift) & 255) * 0.62).toString(16).padStart(2, '0')).join('');
  }
  // What an edit may change on a mark, saved before and put back by undo.
  const FIELDS = ['tone', 'fill', 'fillAlpha', 'outline', 'style', 'size', 'weight', 'dash', '__dash', 'brush', 'alpha'];
  const snapOf = m => Object.fromEntries(FIELDS.map(k => [k, k in m ? m[k] : undefined]));
  const restoreOf = (m, saved) => { for (const k of FIELDS) { if (saved[k] === undefined) delete m[k]; else m[k] = saved[k]; } };
  const CLOSED = ['circle', 'ellipse', 'rect', 'poly', 'path'];
  const firstGiven = (...values) => values.find(v => v != null);
  // fill and line (or tone) change exactly that part; color changes the colour a mark is seen in: a filled shape's
  // fill (its own outline following a shade deeper), otherwise its ink. A 3D part has only its material's colour
  // (the repaint sends the part again under its id and the stage swaps it in place).
  function recolorMark(m, op) {
    if (m.do === 'part3d') {
      const c = firstGiven(op.color, op.fill, op.line, op.tone);
      if (c != null) m.material = { ...m.material, color: (m.three ? realTone : tone)(normColor(c)) };
      return;
    }
    const [color, fill, line] = [op.color, op.fill, op.line ?? op.tone].map(normColor);
    if (fill != null && !['text', 'line', 'arrow'].includes(m.do)) m.fill = fill;
    if (line != null) m.tone = line;
    if (fill != null || line != null || color == null) return;   // a part named exactly, or nothing to do
    if (!(m.fill && m.fill !== 'none' && CLOSED.includes(m.do))) { m.tone = color; return; }
    const ownOutline = m.tone && m.tone !== m.fill && m.outline !== false;
    m.fill = color;
    if (ownOutline) m.tone = darker(color);
  }
  const FONT_WORDS = { handwriting: 'hand', handwritten: 'hand', rounded: 'title', bold: 'title', plain: 'body', sans: 'body', typewriter: 'mono', code: 'mono' };
  const BRUSHES = ['pen', 'marker', 'pencil', 'brush'];
  const within = (v, lo, hi) => Math.max(lo, Math.min(hi, +v));
  // Words take a style (font: an older name for it), a size from 13 to 72 and a weight; a 3D label a size from 15 to
  // 28 (as label() takes it); other marks a pen width from 1 to 14, a dash (a closed shape's is the edit's own) and a
  // brush. Colours as recolorMark.
  function restyleMark(m, op) {
    const recolor = op.color != null || op.fill != null || op.line != null;
    const positive = v => v != null && +v > 0;
    if (m.do === 'label3d') {
      if (positive(op.size)) m.size = within(op.size, 15, 28);
    } else if (m.do === 'text') {
      const font = op.font ?? op.style;
      if (font != null) m.style = FONT_WORDS[font] || font;
      if (positive(op.size)) m.size = within(op.size, 13, 72);
      if (op.weight != null) m.weight = op.weight === 'bold' ? 700 : op.weight === 'normal' ? 400 : op.weight;   // bold and normal as numbers
    } else {
      const width = op.width != null ? op.width : op.size;
      if (positive(width)) m.size = within(width, 1, 14);
      if (op.dash != null) {
        const dash = op.dash === false || op.dash === 'none' ? undefined : op.dash;
        if (m.do === 'line' || m.do === 'arrow') m.dash = dash; else if (CLOSED.includes(m.do)) m.__dash = dash;
      }
      if (op.brush != null && BRUSHES.includes(op.brush)) m.brush = op.brush;
    }
    if (recolor) recolorMark(m, op);
  }
  // What points at the user's screen (it means nothing once the screen changes) and what is a card (paper, a photo, a
  // 3D figure: it means the same over any screen). Free sketches are neither.
  const POINTING_ROLES = new Set(['point', 'target', 'hover', 'type', 'ring', 'frame', 'underline', 'check', 'cross', 'strike',
    'scroll', 'label', 'num', 'connect', 'trace']);
  const pointsAtScreen = m => !!m && (POINTING_ROLES.has(m.role) || m.do === 'highlight');
  const CARD_KINDS = new Set(['stage3d', 'part3d', 'label3d']);
  const isCardMark = m => !!m && (m.role === 'paper' || m.role === 'photo' || (m.do === 'image' && m.role !== 'source') || CARD_KINDS.has(m.do) || m.stage != null);
  // Whether a box is on a card: its middle within 12 of one (tape and a title stick out a little). Null with no cards.
  function onCardTest(cardBoxes) {
    if (cardBoxes.length === 0) return null;
    return b => {
      const x = (b[0] + b[2]) / 2, y = (b[1] + b[3]) / 2;
      return cardBoxes.some(([x0, y0, x1, y1]) => x >= x0 - 12 && x <= x1 + 12 && y >= y0 - 12 && y <= y1 + 12);
    };
  }
  // ================================================================ the editor behind live() and render(): ops, undo and the model's view
  // Ops (one JSON object each): recolor, restyle, move, moveTo, scale, erase, redraw, add, highlight, startOver, undo.
  // say / new / none are for the host (the voice, or starting a new drawing); the editor just reports them.
  // A target (id) is a part ("p3", "x1"), a mark ("m4"), a run of marks ("m4-m9"), or a mark's own id ({id: 'cache'} in
  // the program, a 3D part's id): several go in a list or one string with commas.
  const NOT_REPAINTED = new Set(['stage3d', 'motion3d', 'camera3d']);
  const is3D = m => CARD_KINDS.has(m.do) || m.stage != null;
  // Groups of items whose boxes touch (within pad), unless apart(a, b) keeps two apart: joined by union-find.
  function clusters(items, boxOf, pad, apart) {
    const boxes = items.map(boxOf), root = items.map((_, j) => j);
    const top = j => (root[j] === j ? j : (root[j] = top(root[j])));
    const touch = (A, B) => A[0] - pad <= B[2] && B[0] - pad <= A[2] && A[1] - pad <= B[3] && B[1] - pad <= A[3];
    items.forEach((_, a) => {
      for (let b = a + 1; b < items.length; b++) {
        if (boxes[a] && boxes[b] && !(apart && apart(items[a], items[b])) && touch(boxes[a], boxes[b])) root[top(a)] = top(b);
      }
    });
    const groups = {};                                    // by root index, so groups come in order of their root
    items.forEach((x, j) => (groups[top(j)] = groups[top(j)] || []).push(x));
    return Object.values(groups);
  }
  function Editor(s, st, spec, opts) {
    const [W, H] = [spec.w || 400, spec.h || 300], E = s.edit;   // E: the card's own edit machinery
    const sandboxed = typeof Worker !== 'undefined' && opts.sandbox === 'worker';
    let attr = { code: null, stmts: [] };               // which statement made which marks, for the code it was worked out on
    let nextMark = EDIT_BASE, nextPart = 0, last = null, chain = Promise.resolve();
    // added: parts edits drew (x1, ...); over: a program part an edit redrew; hist: undo steps; key: an edit mark's depth
    const added = [], hist = [], log = [], over = {}, key = {};
    const userCards = [];                                // the mark sets the user dragged as one card: each stays one card
    // a mark by index: the program's (as the stream has it), else one an edit made or repainted
    const mark = i => (i < EDIT_BASE && st.marks[i]) || E.MK[i];
    const drawn = i => { const nodes = E.NODES[i], m = mark(i); return !!(nodes && nodes.length) && !(m && m.__erased); };
    // a program mark that has arrived but not been drawn yet (and is not skipped)
    const pending = i => { const m = i < EDIT_BASE ? st.marks[i] : null; return !!m && !E.NODES[i] && !m.__skip; };
    const keyOf = i => (key[i] != null ? key[i] : i);
    // where a mark is: measured on the card when it is drawn, else from its data
    const box = i => (drawn(i) ? E.domBox(i) : null) || markBox(mark(i));
    const editMarks = () => Object.keys(E.MK).map(Number).filter(i => i >= EDIT_BASE);
    // the marks on the card now, edits' own marks included, and the on-a-card test for them
    const visibleMarkIndexes = () => st.marks.map((_, i) => i).concat(editMarks()).filter(i => { const m = mark(i); return m && m.do !== 'edit' && drawn(i); });
    const cardTest = visible => onCardTest(visible.filter(i => isCardMark(mark(i))).map(i => box(i)).filter(b => b));

    // ---------------------------------------------------------------- the card as parts
    const describeWith = (stmts, o) => describe({ code: st.code, stmts, mark, box, pending, over, added, W, H, from: opts.codeStart || 0,
      drawnOnly: !!(o && o.drawnOnly) });
    // Which statement made which marks. A sandboxed drawing asks its worker (running the model's code in the page is
    // what the sandbox is there to avoid), so the synchronous version answers with the last attribution it gave.
    async function attribution() {
      if (attr.code !== st.code) {
        const code = st.code;
        attr = { code, stmts: sandboxed ? (await sandboxJob({ type: 'attrib', code, w: W, h: H })).stmts || [] : RUNNER.attribute(code, W, H) };
      }
      return attr.stmts;
    }
    function attributionNow() {
      if (attr.code !== st.code && !sandboxed) attr = { code: st.code, stmts: RUNNER.attribute(st.code, W, H) };
      return attr.stmts;
    }
    const parts = async () => describeWith(await attribution());
    const partsNow = o => describeWith(attributionNow(), o);
    const statusOf = () => {
      if (st.finished || (st.done && !st.paused)) return 'The drawing is finished.';
      return st.paused ? 'The drawing is paused part way (more may still come).' : 'The drawing is still being drawn.';
    };
    const stateOptions = o => ({ W, H, mark, says: st.log.lines, request: o.request, last, pointed: o.pointed, over });
    const state = async (o = {}) => stateText(await parts(), Object.assign(stateOptions(o), { status: statusOf() }));
    const stateNow = (o = {}) => stateText(partsNow(o), Object.assign(stateOptions(o), { status: o.status != null ? o.status : statusOf(), maxChars: o.maxChars }));
    // The marks a target names, live ones only. A run of marks stops at the last mark there is (a model's "m0-m999999"
    // used to count to a million).
    function resolve(id, P) {
      const names = Array.isArray(id) ? id : String(id == null ? '' : id).split(/[\s,]+/).filter(Boolean);
      const out = [], bad = [], named = [];
      const top = Math.max(st.marks.length, nextMark) - 1;
      let own = null;                                     // marks by their own id, looked up once
      for (const raw of names) {
        const t = String(raw).trim(), part = P.find(q => q.id === t), run = /^m(\d+)\s*[-–]\s*m?(\d+)$/.exec(t), one = /^m(\d+)$/.exec(t);
        if (part) { out.push(...part.vis); named.push(part); }
        else if (run) { for (let k = +run[1]; k <= Math.min(+run[2], top); k++) out.push(k); }
        else if (one) out.push(+one[1]);
        else {
          if (!own) { own = new Map(); for (const i of st.marks.map((_, k) => k).concat(editMarks())) { const m = mark(i); if (m && m.id != null && m.do !== 'edit') own.set(String(m.id), (own.get(String(m.id)) || []).concat(i)); } }
          if (own.has(t)) out.push(...own.get(t)); else bad.push(t);
        }
      }
      const live = i => { const m = mark(i); return !!m && !m.__erased && m.do !== 'edit'; };
      return { marks: [...new Set(out)].filter(live), bad, parts: named };
    }

    // ---------------------------------------------------------------- drawing, erasing and repainting marks
    // draws the marks again over themselves, then lifts the old strokes off; returns when the last one is done (s from now)
    function repaint(ms, p, from) {
      let at = from || 0, end = at;
      for (const i of ms) {
        if (!drawn(i)) continue;
        const m = mark(i), oldNodes = E.NODES[i], oldMasks = E.MASKS[i], oldText = oldNodes.find(n => n.tagName === 'text');
        const r = E.paintAt(m, i, keyOf(i), at, p, /* repaint */ true);
        // repainted words stay where label placement moved them
        const text = r.nodes.find(n => n.tagName === 'text');
        if (oldText && text && oldText.__nudge) { text.__nudge = oldText.__nudge; text.setAttribute('transform', `translate(${oldText.__nudge[0].toFixed(1)} ${oldText.__nudge[1].toFixed(1)}) ` + (text.getAttribute('transform') || '')); }
        // words, dots and the like cross-fade; a stroke is lifted off once its new pen has gone over it
        const fades = ['text', 'dot', 'molecule', 'highlight'].includes(m.do);
        const off = fades ? { at, dur: Math.max(0.2, r.dur) } : { at: at + r.dur, dur: 0.08 };
        E.unpaint(oldNodes, oldMasks, off.at, off.dur);
        end = Math.max(end, at + r.dur, off.at + off.dur);
        at += r.adv;
      }
      return end;
    }
    function paintNew(ms, at, p) {
      let end = at;
      for (const i of ms) {
        if (mark(i).__skip) continue;
        const r = E.paintAt(mark(i), i, keyOf(i), at, p);
        end = Math.max(end, at + r.dur);
        at += r.adv;
      }
      return end;
    }
    // the pen runs backwards over each mark, last drawn first (o.brisk: startOver's quicker sweep); returns when it is done
    function erase(ms, at, o) {
      o = o || {};
      const order = [...ms].reverse(), stagger = eraseStagger(order.filter(drawn).length, o.brisk), d = ERASE_DUR * (o.pace || 1);
      let t = at || 0, end = t;
      for (const i of order) {
        if (drawn(i)) { E.unpaint(E.NODES[i], E.MASKS[i], t, d); end = t + d; t += stagger; }
        mark(i).__erased = mark(i).__skip = true;
      }
      return end;
    }
    function unerase(ms, at) {
      const back = [];
      for (const i of ms) { const m = mark(i); m.__erased = m.__skip = false; if (i >= EDIT_BASE || E.NODES[i] || m.__passed) back.push(i); }
      return paintNew(back, at, 0.8);
    }
    // an add or redraw's code, run after the program so its helpers are in scope; its marks join the card as edit marks
    async function run(frag) {
      const base = st.code;
      // the model may wrap the code in a ``` fence
      const code = String(frag || '').replace(/^\s*```(?:js|javascript)?\s*\n?/, '').replace(/```\s*$/, '');
      const r = sandboxed ? await sandboxJob({ type: 'exec', base, code, w: W, h: H }) : RUNNER.exec(base, code, W, H, 1200);   // 1.2 s at most
      const ids = (r.marks || []).map(m => {
        // forgiving with an edit's own marks (only these): color or stroke mean tone, width means size
        if (m.tone == null && (m.color || m.stroke || typeof m.line === 'string')) m.tone = m.color || m.stroke || m.line;
        if (m.size == null && +m.width > 0 && m.do !== 'text') m.size = +m.width;
        const i = nextMark++;
        E.MK[i] = m;
        return i;
      });
      return { says: r.says || [], ids, error: r.error };
    }
    // a scale factor between a quarter and four (anything else counts as 1)
    const clampK = k => (isFinite(k) && k > 0 ? Math.min(4, Math.max(0.25, k)) : 1);
    const touchGroups = ms => { const all = unionBox(ms.map(box)); return all ? clusters(ms, box, Math.max(10, 0.06 * Math.hypot(all[2] - all[0], all[3] - all[1]))) : [ms]; };
    // everything on the card before mark `before` (every mark when null): what startOver un-draws
    function everything(before) {
      const upTo = before == null ? st.marks.length : Math.min(before, st.marks.length);
      const program = st.marks.slice(0, upTo).map((m, i) => (m && m.do !== 'edit' && !m.__erased ? i : -1)).filter(i => i >= 0);
      return program.concat(editMarks().filter(i => E.MK[i] && !E.MK[i].__erased && drawn(i)));
    }
    const newPart = (desc, marks) => { const p = { id: 'x' + (++nextPart), desc, marks, step: null }; added.push(p); return p; };
    const dropPart = p => added.splice(added.indexOf(p), 1);

    // ---------------------------------------------------------------- the ops
    // Each op: c = {op, ms (the marks it names), R (resolve's answer), label, frag (what an add or redraw's code drew),
    // at (s from now), pace, res}. Fills res, pushes its undo, and returns when its animation ends (s from now).
    const OPS = {
      // A 3D figure's own mark has no colour or style (its parts do), and painting it again builds an empty figure in its
      // place (asked to spin faster, models restyle it and the whole figure vanished); painting a motion again runs it twice.
      recolor: c => restyleOp(c, recolorMark),
      restyle: c => restyleOp(c, restyleMark),
      move: moveOp, moveTo: moveOp,
      // 3D parts grow or shrink in place in their figure (a 2D transform can't reach them)
      scale: c => c.ms.every(i => (mark(i) || {}).do === 'part3d') ? scale3dOp(c) : moveOp(c),
      erase(c) {
        const was = c.ms.filter(i => !mark(i).__skip || drawn(i));
        c.seen();
        const end = erase(c.ms, c.at, { pace: c.pace });
        hist.push(() => unerase(was, 0));
        return end;
      },
      redraw: redrawOp, highlight: highlightOp,
    };
    function restyleOp(c, change) {
      const painted = c.ms.filter(i => !NOT_REPAINTED.has((mark(i) || {}).do));
      if (!painted.length) throw new Error("a 3D figure itself has no colour or style: change its parts (by their m-numbers) or its camera");
      const before = painted.map(i => [i, snapOf(mark(i))]);
      for (const i of painted) change(mark(i), c.op);
      c.seen();
      hist.push(() => { before.forEach(([i, f]) => restoreOf(mark(i), f)); repaint(painted, REPAINT_PACE); });
      return repaint(painted, REPAINT_PACE * c.pace, c.at);
    }
    function scale3dOp(c) {
      const k = clampK(+(c.op.k != null ? c.op.k : c.op.factor)), before = c.ms.map(i => [i, mark(i).scale3]);
      for (const i of c.ms) mark(i).scale3 = (+mark(i).scale3 || 1) * k;
      c.seen();
      hist.push(() => { before.forEach(([i, was]) => { mark(i).scale3 = was; }); repaint(c.ms, REPAINT_PACE); });
      return repaint(c.ms, REPAINT_PACE * c.pace, c.at);
    }
    // Move, moveTo and scale glide marks to a new transform. A scale grows each separate thing in place (scattered leaves
    // each get bigger; a fox made of touching parts grows as one), never past the card, and nothing leaves the card.
    function moveOp(c) {
      const { op, ms, at } = c, kind = op.op;
      if (!unionBox(ms.map(box))) throw new Error('cannot tell where ' + c.label + ' is');
      const kIn = kind === 'scale' ? clampK(+(op.k != null ? op.k : op.factor)) : 1, glide = GLIDE_DUR * c.pace;
      const groups = kind === 'scale' && op.each !== false ? touchGroups(ms) : [ms];
      const before = ms.map(i => [i, mark(i).__xf ? mark(i).__xf.slice() : null]);
      let end = at;
      c.seen();
      for (const g of groups) {
        const b = unionBox(g.map(box));
        if (!b) continue;
        const [x0, y0, x1, y1] = b, cx = (x0 + x1) / 2, cy = (y0 + y1) / 2;
        // growing stops where the group would no longer fit on the card (with 4 to spare each side)
        const fits = Math.min((W - 8) / Math.max(1, x1 - x0), (H - 8) / Math.max(1, y1 - y0));
        const k = kIn > 1 ? Math.max(1, Math.min(kIn, fits)) : kIn;
        if (k < kIn) c.res.note = `scale held at ${k.toFixed(2)} to keep it on the card`;
        // move: by dx, dy; moveTo: the group's middle to x, y (either left out stays)
        const toward = (v, from) => (isFinite(+v) ? +v : from) - from;
        let dx = kind === 'moveTo' ? toward(op.x, cx) : +op.dx || 0, dy = kind === 'moveTo' ? toward(op.y, cy) : +op.dy || 0;
        // then nudged back onto the card when it fits there: per axis, the end that ran off comes back to 4 from the edge
        const onCard = (lo, hi, size) => (hi - lo > size - 8 ? 0 : lo < 4 ? 4 - lo : hi > size - 4 ? size - 4 - hi : 0);
        const scaled = v => (c0 => c0 + (v - c0) * k);
        dx += onCard(scaled(x0)(cx) + dx, scaled(x1)(cx) + dx, W);
        dy += onCard(scaled(y0)(cy) + dy, scaled(y1)(cy) + dy, H);
        for (const i of g) {
          const m = mark(i), a = m.__xf || [1, 0, 0];
          m.__xf = [a[0] * k, k * a[1] + cx * (1 - k) + dx, k * a[2] + cy * (1 - k) + dy];
          if (drawn(i)) { E.moveNodes(E.NODES[i], m.__xf, at, glide); end = at + glide; }
        }
      }
      hist.push(() => {
        for (const [i, xf] of before) {
          const m = mark(i);
          if (xf) m.__xf = xf; else delete m.__xf;
          if (drawn(i)) E.moveNodes(E.NODES[i], xf || [1, 0, 0], 0, GLIDE_DUR);
        }
      });
      return end;
    }
    // A redraw erases what it names and draws the code's marks at its depth. They take over the program part's name
    // (p3 stays p3), an added part's marks, or become a new part.
    function redrawOp(c) {
      const { op, ms, R, frag } = c;
      if (frag.error) c.res.warning = frag.error;
      if (!frag.ids.length) throw new Error(`its code drew nothing${frag.error ? `: ${frag.error}` : ''}`);
      const k0 = Math.min(...ms.map(keyOf));
      frag.ids.forEach((i, j) => { key[i] = k0 + 0.5 * (j + 1) / (frag.ids.length + 1); });
      const p = R.parts.length === 1 ? R.parts[0] : null, fromProgram = p && !String(p.id).startsWith('x'), prev = fromProgram ? over[p.id] : null;
      c.seen();
      const end = Math.max(erase(ms, c.at), paintNew(frag.ids, c.at + Math.min(0.3, 0.05 * ms.length), 1));
      let xp = null;
      if (fromProgram) over[p.id] = { marks: frag.ids, desc: op.desc || p.desc };
      else if (p) { xp = p; xp.prevMarks = xp.marks; xp.marks = frag.ids; if (op.desc) xp.desc = op.desc; }
      else xp = newPart(op.desc || 'redrawn part', frag.ids);
      hist.push(() => {
        erase(frag.ids, 0); unerase(ms, 0.2);
        if (fromProgram) { if (prev) over[p.id] = prev; else delete over[p.id]; }
        else if (p) xp.marks = xp.prevMarks;
        else dropPart(xp);
      });
      if (p) c.res.touched = [p.id];
      return end;
    }
    // Mate's coral marker: behind words, traced along a thin stroke (an axis, an arrow), or a loose ring around a thing;
    // one per separate target, so two far-apart things do not get one huge loop around both.
    function highlightOp(c) {
      const { ms, label } = c;
      if (!unionBox(ms.map(box))) throw new Error(`where ${label} is cannot be told`);
      const colour = normColor(c.op.color) || 'coral', idx = [];
      for (const g of touchGroups(ms)) {
        const b = unionBox(g.map(box));
        if (!b) continue;
        const [w, h] = [b[2] - b[0], b[3] - b[1]], gm = g.map(i => mark(i));
        // a few strokes, or a long thin run of them (an axis, an arrow), get traced rather than ringed
        const strokes = gm.every(m => ['line', 'arrow'].includes(m.do) && Array.isArray(m.pts));
        const thin = strokes && (g.length <= 3 || Math.min(w, h) < 0.25 * Math.max(w, h));
        const marks = gm.every(m => m.do === 'text') ? [{ do: 'highlight', at: [b[0] - 6, b[1] - 2], w: w + 12, h: h + 4, tone: colour }]
          : thin ? gm.map(m => { const xf = m.__xf || [1, 0, 0]; return { do: 'line', pts: m.pts.filter(Array.isArray).map(p => [p[0] * xf[0] + xf[1], p[1] * xf[0] + xf[2]]), smooth: m.smooth, brush: 'marker', size: 13, alpha: 0.5, tone: colour, taper: 0.4 }; })
          : [{ do: 'ellipse', at: [(b[0] + b[2]) / 2, (b[1] + b[3]) / 2], rx: Math.min(W / 2, w / 2 * 1.12 + 12), ry: Math.min(H / 2, h / 2 * 1.12 + 12), tone: colour, size: 4.5, wobble: 1.6 }];
        for (const hm of marks) { const i = nextMark++; E.MK[i] = hm; key[i] = 1e6 + i; idx.push(i); }
      }
      const p = newPart('coral mark on ' + label, idx);
      c.seen();
      const end = paintNew(idx, c.at, 0.8 * c.pace);
      hist.push(() => { erase(idx, 0); dropPart(p); });
      c.res.touched = [p.id]; c.res.target = label;
      return end;
    }
    // One op. P: the parts; frag: what an add or redraw's code drew; T: {at: s from now, pace, index: the program's own
    // edit mark}. Fills res and returns when its animation ends (s from now).
    function core(op, P, frag, T, res) {
      const { op: kind } = op, pace = T.pace || 1, at = T.at || 0;
      // when the user first sees the edit happen
      const seen = () => { res.visibleAt = res.visibleAt ?? performance.now(); };
      if (kind === 'add') {
        if (frag.error) res.warning = frag.error;
        if (!frag.ids.length) throw new Error(`its code drew nothing${frag.error ? `: ${frag.error}` : ''}`);
        frag.ids.forEach(i => { key[i] = 1e6 + i; });
        const p = newPart(op.desc || 'added', frag.ids);
        seen();
        const end = paintNew(frag.ids, at, pace);
        hist.push(() => { erase(frag.ids, 0); dropPart(p); });
        last = p.id; res.touched = [p.id];
        return end;
      }
      if (kind === 'startOver') {
        const all = everything(T.index);
        res.touched = all.map(i => `m${i}`);
        if (!all.length) return at;                       // an empty card (a fresh drawing starting over): nothing to do
        seen();
        const end = erase(all, at, { brisk: true, pace });
        hist.push(() => unerase(all, 0));
        last = 'everything (startOver)';
        return end;
      }
      const doOp = OPS[kind];
      if (!doOp) throw new Error(`there is no op "${kind}"`);
      const R = resolve(op.id ?? op.ids ?? op.target, P);
      // A program's edit (T.index: its own mark) changes what was on the card before it, never what the program draws
      // after it. A part is found by place, so when a follow-up erased the old card ("p1") and drew its new card in the
      // same spot, the new card counted as p1 too and was erased before it was ever drawn: the voice told the answer
      // over an empty screen.
      if (T.index != null) R.marks = R.marks.filter(k => k >= EDIT_BASE || k < T.index);
      const unknown = R.bad.length ? `nothing on the card is called ${R.bad.join(', ')}` : null;
      if (!R.marks.length) throw new Error(unknown || `nothing of ${JSON.stringify(op.id)} is left to change`);
      if (unknown) res.warning = unknown;
      const ms = R.marks;
      // named as it was asked for: by part when it was asked for by part, else by mark
      res.touched = R.parts.length ? R.parts.map(p => p.id) : ms.map(i => `m${i}`);
      const label = res.touched.join(',');
      const end = doOp({ op, ms, R, label, frag, at, pace, res, seen });
      // "that one" after a highlight means what was highlighted, not the highlight
      last = `${res.target || res.touched.join(',')} (${kind})`;
      return end;
    }
    // an op from the host (the model's edit tool, the user): run after the ones before it finish
    // Runs body(res) for an op and logs what happened (with how long it took to start, in ms); a failure is an answer
    // ({ok: false, error}), never a throw.
    function logged(op, res, body, onFailure) {
      const started = performance.now();
      const done = () => { res.ms = +(performance.now() - started).toFixed(1); log.push(Object.assign({ at: performance.now() }, res)); return res; };
      const failed = e => { res.ok = false; res.error = String((e && e.message) || e); if (onFailure) onFailure(res); return done(); };
      try {
        const out = body(res);
        return out && typeof out.then === 'function' ? out.then(done, failed) : done();
      } catch (e) { return failed(e); }
    }
    const HOST_OPS = new Set(['say', 'new', 'none']);
    function apply(op) {
      return logged(op, { op: op && op.op, ok: true, visibleAt: null }, async res => {
        if (!op || typeof op !== 'object') throw new Error('that is not an op');
        if (HOST_OPS.has(op.op)) { res.host = true; return; }
        if (op.op === 'undo') {
          const undo = hist.pop();
          if (!undo) throw new Error('there is nothing to undo');
          res.visibleAt = performance.now();
          await undo(); last = 'undo';
          return;
        }
        const { parts: P } = await parts();
        const frag = op.op === 'add' || op.op === 'redraw' ? await run(op.code) : null;
        core(op, P, frag, { at: 0, pace: 1 }, res);       // the user's edits start now, at their own pace
      });
    }
    // a program's own edit, right now; res.dur: how long its animation runs
    const PROGRAM_OPS = new Set(['erase', 'recolor', 'restyle', 'move', 'moveTo', 'scale', 'highlight', 'startOver']);
    function applyNow(op, T) {
      return logged(op, { op: op && op.op, ok: true, visibleAt: null, dur: 0 }, res => {
        if (!op || typeof op !== 'object' || !PROGRAM_OPS.has(op.op)) throw new Error(`a program cannot make the edit ${op && op.op}`);
        const P = op.op === 'startOver' ? [] : partsNow().parts;   // startOver names nothing
        res.dur = Math.max(0, core(op, P, null, T, res) - (T.at || 0));   // from its own start
      }, res => { res.dur = 0; });
    }
    // a program's edit mark, drawn at startAt (the card's seconds) at `pace`; returns how long it takes
    function runMark(m, i, startAt, pace) {
      const op = m.op || {};
      if (op.op === 'turn') return 0;                   // a turn only marks where a new turn starts
      const res = applyNow({ ...op }, { index: i, pace: pace || 1, at: Math.max(0, startAt - E.now()) });
      const asWritten = `${op.op}(${op.id != null ? JSON.stringify(op.id) : ''})`;
      const problem = !res.ok ? `${asWritten} did not change anything: ${res.error}` : res.warning ? `${asWritten}: ${res.warning}` : null;
      if (problem) s.report.warnings.push(problem);
      m.__result = { ok: res.ok, error: res.error ?? null, touched: res.touched ?? [], dur: Number(res.dur.toFixed(3)) };
      return res.dur;
    }
    // A program's edit mark as it arrives, before it is drawn: how long it will take (m.__est, for the pacer) and what
    // it takes off the paper for the layout check ({reset} for startOver, {forget: [mark indices]} for erase).
    function planMark(m, i) {
      const op = m.op || {};
      if (op.op === 'turn') return null;                // nothing to plan
      // what it will change: everything before it (startOver), else what its id names before it (or edits made)
      let touched = [];
      try {
        if (op.op === 'startOver') touched = everything(i);
        else if (op.id != null) touched = resolve(op.id, partsNow().parts).marks.filter(k => k >= EDIT_BASE || k < i);
      } catch (_) { touched = []; }
      m.__est = editEstimate(op, touched.map(k => mark(k)));
      if (op.op === 'startOver') return { reset: true };
      return op.op === 'erase' ? { forget: touched } : null;
    }
    // marks drawn on the card now (not erased), edits' own marks included
    const visibleCount = () => visibleMarkIndexes().length;
    // How many marks still show ink. Mate's pieces leave invisible dots where the app acts (a button's spot, a hand-off,
    // a sound, typed text, a page to open): drawn but showing nothing, they kept a drawing whose cards were all closed
    // looking unfinished, with its Clear pill.
    const inkCount = () => visibleMarkIndexes().filter(i => { const m = mark(i); return !(m.do === 'dot' && m.fillAlpha === 0 && m.outline === false); }).length;
    const partInfo = p => ({ id: p.id, desc: p.desc, kind: p.kind, box: p.box, marks: p.vis.slice(), pending: p.pending, step: p.step });

    // ---------------------------------------------------------------- the cards the user can handle
    // The cards the user can drag elsewhere on the screen (paper, stickies, receipts, clippings, photos). Card marks
    // that touch are one card, unless the user moved one of them apart. Every other mark rides with a card its middle
    // is on (within 12) or most of its box is on (not what points at the screen: that only by its middle, so a ring
    // beside a card stays with the screen); the smallest such card when there are two. A card the user has moved
    // keeps exactly what it carried. 3D parts turn by their own handle (a figure's stage rides only on a window, as
    // one) and tie() arrows join two things, so neither rides. Each card: {box, marks, nodes (drawn), window}.
    function cardsNow() {
      const visible = visibleMarkIndexes(), movedAs = new Map();
      userCards.forEach((set, g) => set.forEach(i => movedAs.set(i, g)));
      const cardMarks = visible
        .filter(i => { const m = mark(i); return isCardMark(m) && !is3D(m) && m.role !== 'source'; })
        .map(i => ({ i, b: box(i) })).filter(({ b }) => b);
      if (cardMarks.length === 0) return [];
      const cards = clusters(cardMarks, c => c.b, 2, (a, b) => movedAs.get(a.i) !== movedAs.get(b.i))
        .map(group => ({ box: unionBox(group.map(c => c.b)), marks: group.map(c => c.i), userCard: movedAs.get(group[0].i) }));
      const isCard = new Set(cardMarks.map(c => c.i));
      const near = (b, [x0, y0, x1, y1]) => { const x = (b[0] + b[2]) / 2, y = (b[1] + b[3]) / 2; return x >= x0 - 12 && x <= x1 + 12 && y >= y0 - 12 && y <= y1 + 12; };
      const mostlyOver = (b, c) => {
        const ow = Math.min(b[2], c[2]) - Math.max(b[0], c[0]), oh = Math.min(b[3], c[3]) - Math.max(b[1], c[1]);
        return ow > 0 && oh > 0 && ow * oh >= 0.4 * Math.max(1, boxArea(b));
      };
      for (const i of visible) {
        const m = mark(i);
        if (isCard.has(i) || (is3D(m) && m.do !== 'stage3d') || m.role === 'tie') continue;
        if (movedAs.has(i)) {
          const carrier = cards.find(c => c.userCard === movedAs.get(i));
          if (carrier) { carrier.marks.push(i); continue; }
        }
        const b = box(i);
        if (!b) continue;
        const under = cards
          .filter(c => c.userCard == null && (near(b, c.box) || (!pointsAtScreen(m) && mostlyOver(b, c.box))))
          .filter(c => m.do !== 'stage3d' || c.marks.some(k => mark(k).do === 'window'))
          .sort((p, q) => boxArea(p.box) - boxArea(q.box));
        if (under.length) under[0].marks.push(i);
      }
      // A card's window (paper, receipt, clipping) as it is now, for the app's buttons: the biggest one on the card,
      // its title bar's height at its scale, whether it is zoomed, and whether a 3D figure stands on it (no full-screen
      // button then).
      const windowOf = c => {
        const windows = c.marks.filter(i => mark(i).do === 'window').map(i => ({ i, b: box(i) })).filter(w => w.b).sort((p, q) => boxArea(q.b) - boxArea(p.b));
        if (!windows.length) return null;
        const { i, b } = windows[0], m = mark(i), k = (m.__xf || [1])[0] || 1;
        return { mark: i, box: b, header: (+m.header || 0) * k, scale: k, zoomed: !!m.__xfBeforeZoom, title: m.title || '', has3D: c.marks.some(j => mark(j).do === 'stage3d') };
      };
      const drawnNodes = marksOf => marksOf.flatMap(i => (E.NODES[i] || []).filter(n => !n.__gone));
      return cards.map(c => ({ box: c.box, marks: c.marks, nodes: drawnNodes(c.marks), window: windowOf(c) }));
    }
    // the drawn, live marks among ms, by index
    const liveMarks = ms => (ms || []).map(Number).filter(i => { const m = mark(i); return m && !m.__erased && drawn(i); });
    // takes marks off for good, the pen running briskly back over them
    const dropNow = ms => {
      erase(ms, 0, { brisk: true });
      for (const i of ms) if (mark(i)) mark(i).__dropped = true;
    };
    // the marks among those visible that pass keep(i, m, box); the rest are dropped
    const dropUnless = (visible, keep) => {
      const drop = visible.filter(i => !keep(i, mark(i), box(i)));
      if (drop.length) dropNow(drop);
      return drop.length;
    };
    const IDENTITY = [1, 0, 0];

    return {
      // ops run one after another; each answers {ok, error, visibleAt, touched}
      edit(op) {
        const done = chain.then(() => apply(op));
        chain = done.catch(() => {});
        return done;
      },
      undo() { return this.edit({ op: 'undo' }); },
      settle() { E.settle(); },
      state, parts: async () => (await parts()).parts.map(partInfo),
      // the same without waiting: the card's state and parts now, a program's edit marks, how much is on the card
      stateNow, partsNow: o => partsNow(o).parts.map(p => Object.assign(partInfo(p), { turn: p.turn })),
      runMark, planMark, visibleCount, inkCount,
      // marks a new turn takes off the card for good (they came from a statement that failed)
      dropNow,
      // The screen under a finished drawing changed. What points at the screen no longer lines up with anything and
      // goes; cards (paper, photos, 3D figures) and everything on them stay. Returns {kept, dropped}; with no card at
      // all nothing goes (kept 0: the host clears the whole drawing).
      keepNotesOnly() {
        const visible = visibleMarkIndexes(), onACard = cardTest(visible);
        if (!onACard) return { kept: 0, dropped: 0 };      // no card at all: the host clears the drawing
        const dropped = dropUnless(visible, (i, m, b) => isCardMark(m) || m.role === 'tie' || !!(b && onACard(b)));
        return { kept: visible.length - dropped, dropped };
      },
      // The screen changed while an answer was still being told: only what points at the screen goes (rings, frames,
      // pills, badges, ticks, arrows between things on it); cards and free sketches stay and the answer goes on.
      // Returns {dropped, left}.
      dropPointing() {
        const visible = visibleMarkIndexes(), onACard = cardTest(visible) || (() => false);
        const dropped = dropUnless(visible, (i, m, b) => !pointsAtScreen(m) || !!(b && onACard(b)));
        return { dropped, left: visible.length - dropped };
      },
      cardsNow,
      // The user dropped a card elsewhere: its marks move by dx, dy at once (the app already showed them following the
      // pointer) and stay one card from now on. Returns how many moved.
      moveMarks(ms, dx, dy) {
        dx = +dx || 0; dy = +dy || 0;
        if (!dx && !dy) return 0;
        const moved = liveMarks(ms);
        for (const i of moved) {
          const m = mark(i), [k, x, y] = m.__xf || IDENTITY;
          m.__xf = [k, x + dx, y + dy];
          E.moveNodes(E.NODES[i], m.__xf, 0, 0.001);       // at once: the app already showed it there
        }
        if (moved.length > 0) userCards.push(new Set(moved));
        return moved.length;
      },
      // The user closed a card (its window's red button): its marks go, and a 3D figure takes everything built into
      // it. Returns how many went.
      dropMarks(ms) {
        const gone = (ms || []).map(Number).filter(i => !!mark(i) && !mark(i).__erased);
        const stages = new Set(gone.map(mark).filter(m => m.do === 'stage3d').map(m => m.id));
        if (stages.size) for (const i of visibleMarkIndexes()) if (stages.has(mark(i).stage) && !gone.includes(i)) gone.push(i);
        if (gone.length) dropNow(gone);
        return gone.length;
      },
      // The user made a card full screen (its window's green button): its marks glide by `to` ([scale, dx, dy], on
      // top of where they were); zoomMarks(ms, null) glides them back. Zoomed, it stays its own card. Returns how many
      // moved.
      zoomMarks(ms, to) {
        const moved = [];
        for (const i of liveMarks(ms)) {
          const m = mark(i);
          if (to) {
            const before = m.__xfBeforeZoom || (m.__xfBeforeZoom = (m.__xf || IDENTITY).slice());
            const k = +to[0] || 1;
            m.__xf = [before[0] * k, k * before[1] + (+to[1] || 0), k * before[2] + (+to[2] || 0)];
          } else {
            const before = m.__xfBeforeZoom;
            if (!before) continue;
            delete m.__xfBeforeZoom;
            if (before[0] === 1 && !before[1] && !before[2]) delete m.__xf; else m.__xf = before;
          }
          E.moveNodes(E.NODES[i], m.__xf || IDENTITY, 0, GLIDE_DUR * 0.8);
          moved.push(i);
        }
        if (to && moved.length > 0) userCards.push(new Set(moved));   // zoomed, it stays a card of its own
        return moved.length;
      },
      // The part at card point (x, y): the one whose mark drew the tapped element when the host passes it, else the
      // smallest part whose box (6 wider) holds the point.
      async hit(x, y, el) {
        const { parts: all } = await parts();
        const P = all.filter(p => p.vis.length && p.box);
        const drewIt = new Map();
        for (const k of Object.keys(E.NODES)) for (const n of E.NODES[k]) drewIt.set(n, +k);
        for (let n = el; n && n.tagName !== 'svg'; n = n.parentNode) {
          const p = drewIt.has(n) ? P.find(q => q.vis.includes(drewIt.get(n))) : null;
          if (p) return p.id;
        }
        const holding = P.filter(p => x >= p.box[0] - 6 && x <= p.box[2] + 6 && y >= p.box[1] - 6 && y <= p.box[3] + 6).sort((a, b) => boxArea(a.box) - boxArea(b.box));
        return holding.length ? holding[0].id : null;
      },
      log, get last() { return last; }, get busy() { return E.busy; },
    };
  }

  // ================================================================ render and live
  // A program run the way live() runs it, one complete statement at a time, so a rendered card is what the product
  // draws.
  function runLive(code, width, height) {
    const W = width, H = height;
    const session = RUNNER.Session(W, H), marks = [], says = [], warnings = [];
    let error = null;
    const add = r => { marks.push(...r.marks); says.push(...r.says); warnings.push(...r.warnings); if (r.error) error = r.error; };
    for (const end of statementEnds(code)) add(session.update(code.slice(0, end), false));
    add(session.update(code, true));
    return Object.assign(marks, { error, says, warnings });
  }
  // A program drawn whole draws what its live drawing did: at each __turn(n, keep), the earlier turn's marks from
  // `keep` on were never drawn (the user interrupted that turn), so they are skipped here too.
  function dropUndrawn(marks) {
    marks.forEach((turn, i) => {
      if (!isTurnMark(turn) || turn.op.keep == null) return;
      for (const m of marks.slice(Math.max(0, turn.op.keep), i)) if (m && !isTurnMark(m)) m.__skip = m.__erased = m.__dropped = true;
    });
  }
  // The longest run of whole statements of `code` that runs without an error, and how many marks it makes. Found by
  // halving: once a statement fails, every longer run fails too.
  function runnablePrefix(code, width, height) {
    const run = src => runCode(src, width, height);
    const all = run(code);
    if (!all.error) return { code, marks: all.length };
    const ends = statementEnds(`${code}\n;`).filter(e => e <= code.length);
    let best = { code: '', marks: 0 }, lo = 0, hi = ends.length - 1;
    while (lo <= hi) {
      const mid = (lo + hi) >> 1, prefix = code.slice(0, ends[mid]), result = run(prefix);
      if (result.error) hi = mid - 1;
      else { best = { code: prefix, marks: result.length }; lo = mid + 1; }
    }
    return best;
  }
  // Methods of `from` offered on `onto` under the same names (and live getters for `props`).
  function forward(onto, from, methods, props = []) {
    for (const name of methods) onto[name] = (...args) => from()[name](...args);
    for (const name of props) Object.defineProperty(onto, name, { enumerable: true, get: () => from()[name] });
    return onto;
  }
  // Draws a whole drawing at once and returns its report. A program's edits (erase, recolor, move, ... startOver) run
  // through an editor on the card, each at its point in the drawing.
  //   spec: {w, h, code | marks, surface, layout, stepBudget, schedule}; schedule: [[startSeconds, pace], ...] per mark
  //         (from a paced replay), to render or freeze frames exactly
  //   opts: {width, whole (run the program at once instead of statement by statement), layout, handle (filled with
  //         state(o), parts(o), visibleCount(), keepNotesOnly(), dropPointing() for this card), sandbox, codeStart}
  // The card for a spec, and the editor wired to it (a program's edit marks run through the editor at their beat).
  function cardWithEditor(spec, host, opts, stream) {
    const card = surfaceFor(spec, host, opts), editor = Editor(card, stream, spec, opts);
    card.hooks.edit = (m, i, at, pace) => editor.runMark(m, i, at, pace);
    return [card, editor];
  }
  function render(spec, host, opts = {}) {
    const [W, H] = [spec.w || 400, spec.h || 300];
    let marks = spec.marks || [];
    if (spec.code) marks = opts.whole ? runCode(spec.code, W, H) : runLive(spec.code, W, H);
    dropUndrawn(marks);
    const says = (marks.says || []).map((line, k) => Object.assign({ k }, line));
    const [s, ed] = cardWithEditor(spec, host, opts, { marks, code: spec.code || '', log: { lines: says }, finished: true, done: true, paused: false });
    const checked = spec.layout !== false && opts.layout !== false ? layoutMarks(marks, W, H, (m, i) => ed.planMark(m, i)) : null;
    const { report } = s;
    if (marks.error) report.errors.push(marks.error);
    report.warnings.push(...(marks.warnings || []));
    if (checked) {
      s.report.warnings.push(...checked.warnings);
      Object.assign(s.report, { shapeOverlaps: checked.overlaps, nudged: checked.moved, covered: checked.covered });
    }
    if (Array.isArray(spec.schedule)) marks.forEach((m, i) => { const at = spec.schedule[i]; if (at) [m._t, m._pace] = at; });
    if (opts.handle) {
      Object.assign(opts.handle, { state: o => ed.stateNow(o), parts: o => ed.partsNow(o) });
      forward(opts.handle, () => ed, ['visibleCount', 'keepNotesOnly', 'dropPointing']);
    }
    s.draw(marks);
    return s.finish();
  }

  // Draws a program while it streams in, each statement as soon as all of it has arrived. Options, all optional:
  //   sandbox 'worker'     the program runs in a Web Worker (no page, no network; at most opts.timeLimit ms a run,
  //                        1500 by default). update() then answers [], and new say() lines come to opts.onSay(lines).
  //   pace 'speech'        a say() line's strokes are drawn while the line is spoken, spread across it
  //   speech 'estimate'    lines are timed at opts.wps words a second, opts.gap s apart (the default); 'external':
  //                        the host reports them with lineStart / lineEnd, or spoken
  //   continuous true      all the lines are one utterance, with no gaps
  //   onSay(lines), onDraw(marks, how), onDone(report, timeline)
  //   codeStart            where the program's own code begins (Mate's pieces come before it): state() does not list
  //                        the helpers defined ahead of it
  function live(spec, host, opts = {}) {
    let errorsReported = 0;
    const finished = (rep, log) => {
      // A continued drawing's stream report keeps growing: only its errors since the last finish are new (finish()
      // drops repeated warnings itself).
      s.report.errors.push(...rep.errors.slice(errorsReported));
      errorsReported = rep.errors.length;
      s.report.warnings.push(...rep.warnings);
      for (const k of ['shapeOverlaps', 'nudged', 'covered']) if (rep[k] != null) s.report[k] = rep[k];
      Object.assign(s.report, { sandboxed: st.sandboxed, mode: log.mode });
      s.finish();
      if (opts.onDone) opts.onDone(s.report, log);
    };
    let ed = null;
    const st = Stream(spec, Object.assign({}, opts, {
      onDraw: (ms, how) => { s.draw(ms, true, how || {}); if (opts.onDraw) opts.onDraw(ms, how || {}); },
      onDone: finished,
      planEdit: (m, i) => (ed ? ed.planMark(m, i) : null),
    }));
    let s;
    [s, ed] = cardWithEditor(spec, host, opts, st);
    // A new turn on the drawing that is there. What was still waiting for its line is dropped for good; the program is
    // cut back to what ran (whole statements, before any that failed) and opened again. The host then appends
    // `__turn(turn, keep);` and the new turn's code to `kept` (a whole replay of that program drops the same marks).
    // Returns {kept, keep, turn, firstLine (lines said so far), visible (marks on the card), start (the next mark)}.
    function continueTurn() {
      let keep = st.dropPending(), kept = st.ran, { count } = st;
      if (st.runMode === 'full' && !st.sandboxed) {
        // the program stopped with an error: keep the part of it that runs, and take the rest off the card
        const good = runnablePrefix(kept, spec.w || 400, spec.h || 300);
        const cutBack = good.code.length < kept.length || good.marks < count;
        if (cutBack) {
          const failed = [];
          for (let i = good.marks; i < count; i++) if (st.marks[i] && !isTurnMark(st.marks[i])) failed.push(i);
          ed.dropNow(failed);
          st.rebase(good.code, good.marks);
          ({ code: kept, marks: count } = good);
          keep = Math.min(keep, count);
        }
      }
      st.reopen(kept);
      const turn = 1 + st.marks.reduce((most, m) => Math.max(most, (m && m.turn) || 1), 1);
      keep = Math.min(keep, count);
      return { kept, keep, turn, firstLine: st.lines.length, visible: ed.visibleCount(), start: count };
    }
    const handle = { report: s.report, continueTurn, startsIn: i => s.startsIn(i) };
    // the stream: code in, the voice's timing, stopping and rushing
    forward(handle, () => st, ['update', 'lineStart', 'lineEnd', 'spoken', 'stop', 'now', 'finishNow', 'pause', 'resume'],
      ['rushed', 'paused', 'finished', 'code', 'lines', 'sandboxed']);
    Object.defineProperty(handle, 'timeline', { enumerable: true, get: () => st.log });
    Object.defineProperty(handle, 'placed', { enumerable: true, get: () => s.placed });
    handle.live3d = () => st.live3d;
    // the card: edits, its parts and state, the screen changing, and the cards the user handles
    forward(handle, () => ed, ['edit', 'settle', 'state', 'parts', 'hit', 'stateNow', 'partsNow', 'visibleCount', 'inkCount', 'keepNotesOnly', 'dropPointing',
      'cardsNow', 'moveMarks', 'dropMarks', 'zoomMarks']);
    handle.undo = () => ed.edit({ op: 'undo' });
    Object.defineProperty(handle, 'edits', { enumerable: true, get: () => ed.log });
    Object.defineProperty(handle, 'lastEdit', { enumerable: true, get: () => ed.last });
    // where a drawn mark really is now ([x0, y0, x1, y1]), or null
    handle.drawnBox = i => (s.edit && s.edit.domBox ? s.edit.domBox(i) : null);
    return handle;
  }
  global.MateDraw = {
    version: VERSION, render, live, TONES, setPen, natural, EDIT_BASE,
    // the program runner and its sandbox
    runCode, statementEnds, statementScanner: RUNNER.statementScanner, Session: RUNNER.Session, attribute: RUNNER.attribute, exec: RUNNER.exec, workerSource,
    // the stream's parts, for hosts and tests
    Stream, Pacer, Layout, layoutMarks,
    // the card in words, and what a mark is
    describe, stateText, markBox, recolorMark, restyleMark, pointsAtScreen, isCardMark, onCardTest,
    // the pen's geometry, for tests and tools
    geometry: { rng, catmull, densify, dashes, handSegments, ellipsePts, outline, evenOutline },
  };
})(typeof window !== 'undefined' ? window : globalThis);
