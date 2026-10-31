// HeyMate's drawing pieces: the vocabulary a drawing program uses on top of the engine's marks (line, circle, text,
// poly, ...). The app prepends this file to every program, and the engine runs the result inside its `with (api)`
// scope, so a program calls label(), ring(), paper() ... as if they were built in. The model learns the screen and
// card pieces from the drawing instructions in CompanionPrompts.swift (a change to a signature belongs there too); the
// welcome tour's pieces (spotlight, jobTicket, dreamMedal, tourJob ...) are not taught by any prompt in this repository.
//
// Everything below is one statement. Only the pieces themselves (and INK) become names in the program's scope: the
// helpers and the per-drawing state (pills placed so far, cards drawn, the one cheer) stay private, so a program that
// happens to declare a name of its own can't collide with them or overwrite them halfway through a drawing.
//
// The look: whatever marks the real screen is drawn in Mate's ink (the user's cursor colour) with a soft glow of the
// same colour, and named in a small gel pill; explanations go on paper or in little Mac windows on calm space.
//
// Optional host globals, read when a piece runs:
//   __mateInk            '#RRGGBB', Mate's ink (default #3380FF)
//   __canvasUnitPoints   screen points per canvas unit (the canvas is the screenshot); marks on the screen are sized in points
//   __inkFor(x, y, w, h) a readable ink for free words over that area: '#FFFFFF' or '#15171C'
//   __busyFor(x, y, w, h) 0..1, how much text and controls the area holds (pills prefer calm spots)
//   __hostDrawsPointers / __hostDrawsButtons / __hostDrawsWindows / __hostDrawsMarquee
//                        the app draws that thing itself; the piece leaves a mark describing it instead
//   __hideLoneSources    drop a sources() line that has no card to sit under
// It also sets the engine's __card3d hook when the app draws windows (a 3D figure on a busy screen gets one).
const {
  INK, lessonTitle, plan, task, waitForUser, onScreen,
  label, tag, point, target, hover, frame, ring, ink, inkCircle, write, num, underline, connect, trace, check, cross, strike, scroll, cheer,
  photo, tie, source, sources, typeText, copyText, openPage, button, handOff, tourJob, tuckJobs, showNotch, fadeAway, nextQuestions, sfx,
  sticky, spotlight, jobTicket, dreamMedal, receipt, clipping, legend, paper,
} = (() => {
  const { min, max, round, abs, hypot, cos, sin, asin, PI } = Math;
  // Host hooks are looked up by name through the program's scope (the engine's api first, then the page's globals).
  const hostDraws = {
    pointers: () => typeof __hostDrawsPointers !== 'undefined' && __hostDrawsPointers === true,
    buttons: () => typeof __hostDrawsButtons !== 'undefined' && !!__hostDrawsButtons,
    windows: () => typeof __hostDrawsWindows !== 'undefined' && __hostDrawsWindows === true,
    marquee: () => typeof __hostDrawsMarquee !== 'undefined' && __hostDrawsMarquee === true,
  };

  // ---------------------------------------------------------------- colours
  const ink0 = typeof __mateInk === 'string' && /^#[0-9A-F]{6}$/i.test(__mateInk) ? __mateInk.toUpperCase() : '#3380FF';
  const WHITE_INK = '#FFFFFF', DARK_INK = '#15171C', SHADOW = '#1C1E24';
  // a channel-wise blend of two '#RRGGBB' colours, t of the way from `a` to `b`
  const blend = (a, b, t) => {
    const ch = h => [1, 3, 5].map(i => parseInt(h.slice(i, i + 2), 16)), p = ch(a), q = ch(b);
    return '#' + p.map((v, i) => round(v + (q[i] - v) * t).toString(16).padStart(2, '0')).join('').toUpperCase();
  };
  // Tuned colours for the four cursor colours the app offers; any other ink is mixed from itself.
  const TUNED = {
    '#3380FF': { gel: ['#EDF4FF', '#A2C7FF', '#A2D2F7', '#221898'], paper: ['#EFF2F6', '#E8ECF1', '#E9EEF4'], wash: ['#0F7FFF', 0.08] },
    '#FF4C4C': { gel: ['#FFF1EF', '#FFB8B0', '#FFC8C0', '#7A1E1E'], paper: ['#F9EFEA', '#F2E7E2', '#F5E9E4'], wash: ['#FF5A4C', 0.08] },
    '#D4A017': { gel: ['#FFF8E2', '#FFDF8A', '#FFE9A8', '#6E4E00'], paper: ['#FAF5EA', '#F3EEE4', '#F4EEDF'], wash: ['#FEEA3D', 0.12] },
    '#26C281': { gel: ['#EFFBF2', '#C9F0CF', '#B4E8C5', '#17603F'], paper: ['#EFF4EB', '#E7EEE3', '#E9F1E5'], wash: ['#26C281', 0.1] },
  }[ink0];
  // The gel pill: a pastel of the ink, lighter towards the top, with a dark rim.
  const [gelTop, gelMid, gelLow, gelRim] = TUNED ? TUNED.gel
    : [blend(ink0, '#FFFFFF', 0.9), blend(ink0, '#FFFFFF', 0.55), blend(ink0, '#FFFFFF', 0.5), blend(ink0, '#000000', 0.55)];
  // Paper is a matte off-white with a whisper of the ink: card (windows, plates), news, print (a photo's border).
  const [paperCard, paperNews, paperPrint] = TUNED ? TUNED.paper : ['#FAF5EA', '#F3EEE4', '#F4EEDF'].map(c => blend(c, ink0, 0.05));
  const [washColour, washAlpha] = TUNED ? TUNED.wash : [ink0, 0.09];
  const STICKY = { butter: '#FFE27A', mint: '#BFEFCF', peach: '#FFD0BC', lilac: '#D9D1FB', sky: '#CFE6FF', white: paperCard, news: paperNews };
  const PILL_WORDS = DARK_INK;

  // ---------------------------------------------------------------- sizes
  // The canvas is the screenshot, so a unit is usually more than a point. Marks on the real screen are sized in points.
  const unitPoints = typeof __canvasUnitPoints === 'number' && Number.isFinite(__canvasUnitPoints) && __canvasUnitPoints > 0 ? __canvasUnitPoints : 1;
  const pt = v => v / unitPoints;
  // The screen pen: an even 3.5 pt line with round ends and a 12 pt glow of its own colour at 65% ([opacity, blur]).
  const SCREEN_PEN = { size: pt(3.5), taper: 0, glow: [0.65, pt(12)] };
  const screenPen = o => Object.assign({}, SCREEN_PEN, o);
  const DASHED = { dash: pt(8), dashGap: pt(5), smooth: false, wobble: 0 };
  const PILL_SIZE = pt(12), BUTTON_SIZE = pt(13);
  // An invisible dot: how a piece hands the app something to do (or to draw itself) at a point.
  const signal = (x, y, extra) => dot(x, y, 0.1, Object.assign({ tone: WHITE_INK, fillAlpha: 0, outline: false }, extra));

  // ---------------------------------------------------------------- outlines
  // A rounded rectangle as a closed list of points, clockwise from the top edge's right end: 7 points per corner.
  const quarter = (out, cx, cy, r, from) => { for (let k = 0; k <= 6; k++) { const a = from + k * PI / 12; out.push([cx + cos(a) * r, cy + sin(a) * r]); } };
  const roundRect = (x, y, w, h, r) => {
    r = max(0, min(r, w / 2, h / 2));
    const out = [];
    quarter(out, x + w - r, y + r, r, -PI / 2); quarter(out, x + w - r, y + h - r, r, 0);
    quarter(out, x + r, y + h - r, r, PI / 2); quarter(out, x + r, y + r, r, PI);
    return out;
  };
  // Only the top corners rounded: a window's title bar.
  const topRoundRect = (x, y, w, h, r) => {
    r = max(0, min(r, w / 2, h));
    const out = [];
    quarter(out, x + w - r, y + r, r, -PI / 2); out.push([x + w, y + h], [x, y + h]); quarter(out, x + r, y + r, r, PI);
    return out;
  };
  const corners = (x, y, w, h) => [[x, y], [x + w, y], [x + w, y + h], [x, y + h]];
  const capsule = (x, y, w, h) => roundRect(x, y, w, h, h / 2);
  // The top `fraction` of a capsule, cut straight across, keeping its round ends (a band of light that stays inside it).
  const capsuleTop = (x, y, w, h, fraction) => {
    const r = h / 2, cutY = y + h * max(0.02, min(1, fraction)), cut = asin(max(-1, min(1, (cutY - y - r) / r))), out = [];
    for (let k = 0; k <= 10; k++) { const a = -PI / 2 + (cut + PI / 2) * k / 10; out.push([x + w - r + r * cos(a), y + r + r * sin(a)]); }
    for (let k = 0; k <= 10; k++) { const a = PI - cut + (cut + PI / 2) * k / 10; out.push([x + r + r * cos(a), y + r + r * sin(a)]); }
    return out;
  };
  const boundsOf = pts => {
    const xs = pts.map(p => p[0]), ys = pts.map(p => p[1]), x0 = min(...xs), y0 = min(...ys);
    return [x0, y0, max(...xs) - x0, max(...ys) - y0];
  };
  const turned = (pts, deg, about) => {
    const b = about || boundsOf(pts), c = [b[0] + b[2] / 2, b[1] + b[3] / 2];
    return pts.map(p => rotate(p, c, deg * PI / 180));
  };

  // ---------------------------------------------------------------- text width guesses (marks are measured later)
  // East Asian and emoji characters are about a full em wide; everything else is counted at the font's average.
  const WIDE = /[ᄀ-ᅟ⺀-꓏가-힣豈-﫿︰-﹏＀-｠￠-￦]|[\u{1F300}-\u{1FAFF}\u{20000}-\u{3FFFD}]/u;
  const widthOf = (str, size, average) => {
    let narrow = 0, wide = 0;
    for (const ch of String(str)) WIDE.test(ch) ? wide++ : narrow++;
    return narrow * size * average + wide * size;
  };
  const pillSize = (str, size) => [round(widthOf(str, size, 0.58) + size * 1.9), round(size * 1.9)];

  // ---------------------------------------------------------------- where things go
  const pills = [];       // every pill, badge and button placed so far: names never sit on each other
  const named = [];       // the boxes of marks that were named: a pill never sits on another mark either
  const cards = [];       // the writing areas of windows that take a sources line under them
  const MARGIN = 4;
  const overlaps = (b, list) => list.some(o => b[0] < o[0] + o[2] + MARGIN && b[0] + b[2] + MARGIN > o[0] && b[1] < o[1] + o[3] + MARGIN && b[1] + b[3] + MARGIN > o[1]);
  const onCanvas = b => b[0] >= MARGIN && b[1] >= MARGIN && b[0] + b[2] <= W - MARGIN && b[1] + b[3] <= H - MARGIN;
  const keepOn = b => [max(MARGIN, min(b[0], W - MARGIN - b[2])), max(MARGIN, min(b[1], H - MARGIN - b[3])), b[2], b[3]];
  const busy = (x, y, w, h) => (typeof __busyFor === 'function' ? __busyFor(x, y, w, h) : 0);
  // Paper never lands on a 3D figure: the engine moves it to the nearest free spot.
  const clearOf3d = (x, y, w, h) => (typeof clearOfFigures === 'function' ? clearOfFigures(x, y, w, h) : [x, y]);

  // A gel pill (or badge, or button face): drop shadow, dark rim, pastel body lighter toward the top, white gloss.
  const POP = { num: 'badge-pop', cheer: 'boing', button: 'button-appear' };
  const gel = (x, y, w, h, role) => {
    const rim = pt(1), inset = max(pt(1.5), h * 0.09);
    const layer = (pts, fill, fillAlpha, together, extra) => poly(pts, Object.assign({ fill, fillAlpha, outline: false, wash: false, role, together }, extra));
    layer(capsule(x, y + pt(1), w, h), SHADOW, 0.1, true, { snd: POP[role] || 'gel-pop' });   // one pill, one pop
    layer(capsule(x - rim, y - rim, w + 2 * rim, h + 2 * rim), gelRim, 1, true);
    layer(capsule(x, y, w, h), gelLow, 1, true);
    layer(capsuleTop(x, y, w, h, 0.78), gelMid, 1, true);
    layer(capsuleTop(x, y, w, h, 0.42), gelTop, 0.75, true);
    layer(capsuleTop(x + inset, y + inset * 0.6, w - 2 * inset, h - 2 * inset, 0.5), '#FFFFFF', 0.6, false);
  };

  // label(x, y, text, {anchor, size, role}): a name pill, its top-left at x, y ('middle' centres it on x). A pill that
  // would land on another one steps down a row, then up, until it is clear.
  const label = (x, y, str, o = {}) => {
    str = String(str == null ? '' : str).trim();
    if (!str) return null;
    const size = o.size || PILL_SIZE, role = o.role || 'label', [w, h] = pillSize(str, size);
    let b = keepOn([o.anchor === 'middle' ? x - w / 2 : x, y, w, h]);
    [b[0], b[1]] = clearOf3d(b[0], b[1], w, h);
    if (overlaps(b, pills)) b = [1, 2, 3, -1, -2, -3].map(k => keepOn([b[0], b[1] + k * (h + pt(4)), w, h])).find(t => !overlaps(t, pills)) || b;
    pills.push(b);
    gel(b[0], b[1], w, h, role);
    text(b[0] + w / 2, b[1] + h * 0.68, str, { style: 'ui', weight: 600, size, tone: PILL_WORDS, anchor: 'middle', fit: [w - size, h], place: false, role });
    return b;
  };
  const tag = (x, y, str) => label(x, y, str);

  // Names a mark with a pill beside it: on the calmest of the free spots around it (above, below, right, left, its
  // corners, a row further out), never on another pill or another named mark. Nearer spots win unless a farther one is
  // clearly calmer; the outermost ring is a last resort.
  const nameMark = (box, str, o = {}) => {
    if (str == null || String(str).trim() === '') { named.push(box); return null; }
    const size = o.labelSize || PILL_SIZE, [w, h] = pillSize(String(str).trim(), size), [bx, by, bw, bh] = box, gap = pt(5), far = gap * 3 + h;
    const above = by - h - gap, below = by + bh + gap, right = bx + bw + gap, left = bx - w - gap, middle = by + bh / 2 - h / 2;
    const spots = [[bx, above], [bx, below], [right, middle], [left, middle], [bx + bw - w, above], [bx + bw - w, below],
      [right, above], [right, below], [left, above], [left, below], [bx, by - 2 * h - 2 * gap], [bx, by + bh + h + 2 * gap],
      [bx, by - h - far], [bx, by + bh + far], [bx + bw + far, middle], [bx - w - far, middle]];
    const lastResort = spots.length - 4;
    // a spot listed twice counts as its first listing
    const rank = spots.map(([sx, sy]) => spots.findIndex(([tx, ty]) => tx === sx && ty === sy));
    const others = named.filter(m => !(m[0] === bx && m[1] === by && m[2] === bw && m[3] === bh));
    named.push(box);
    let pick = null, best = Infinity;
    spots.forEach(([sx, sy], i) => {
      const b = [sx, sy, w, h];
      if (!onCanvas(b) || overlaps(b, pills) || overlaps(b, others)) return;
      const cost = busy(sx, sy, w, h) + rank[i] * 0.004 + (rank[i] >= lastResort ? 0.02 : 0);
      if (cost < best || pick === null) { pick = b; best = cost; }
    });
    if (!pick) pick = keepOn([spots[0][0], spots[0][1], w, h]);
    return label(pick[0], pick[1], str, { size });
  };

  // ---------------------------------------------------------------- marking the real screen
  // point(x, y, name): a ring on the exact spot, a dot in its middle, named.
  const point = (x, y, name) => {
    const r = pt(12);
    circle(x, y, r, screenPen({ tone: ink0, role: 'point', label: name, wobble: 0.4 }));
    dot(x, y, pt(3), { tone: ink0, fill: ink0, role: 'point' });
    nameMark([x - r, y - r, 2 * r, 2 * r], name);
  };
  // target/hover(x, y, w, h, name): the control to click (or rest the pointer on), by its box. The older
  // target(x, y, r, name) centre-and-radius form still works. When the app draws pointers itself the piece only
  // reports where.
  const pointer = role => (a, b, c, d, e) => {
    const boxed = typeof d === 'number', name = boxed ? e : d;
    const x = boxed ? a + c / 2 : a, y = boxed ? b + d / 2 : b, r = boxed ? min(c, d) / 2 + 6 : (c || 22);
    if (hostDraws.pointers()) { signal(x, y, { role, ring: r, box: boxed ? [a, b, c, d] : null, label: name }); return; }
    const p = pt(4);
    if (boxed) {
      const outline = roundRect(a - p, b - p, c + 2 * p, d + 2 * p, (d + 2 * p) / 2);
      line(outline.concat([outline[0]]), screenPen(Object.assign({ tone: ink0 }, DASHED, { role, label: name })));
    } else {
      circle(x, y, r, screenPen({ tone: ink0, role, label: name }));
    }
    nameMark(boxed ? [a - p, b - p, c + 2 * p, d + 2 * p] : [x - r, y - r, 2 * r, 2 * r], name);
  };
  const target = pointer('target'), hover = pointer('hover');

  // frame(x, y, w, h, name, {r}): an area (a panel, a group of fields, a bar) with a faint tint and a dashed outline that
  // follows its shape. Without r, something wide and short is a pill and anything else gets small rounded corners.
  const frame = (x, y, w, h, name, o = {}) => {
    const p = pt(3), bx = x - p, by = y - p, bw = w + 2 * p, bh = h + 2 * p;
    const wanted = typeof o.r === 'number' ? o.r + p : bw > 2.5 * bh && bh < pt(60) ? bh / 2 : pt(8);
    const radius = max(0, min(wanted, bw / 2, bh / 2)), outline = roundRect(bx, by, bw, bh, radius);
    // the app drags the frame open from its corner like a selection when it can
    const marquee = hostDraws.marquee() ? [bx, by, bw, bh, radius] : null;
    poly(outline, { fill: ink0, fillAlpha: 0.07, outline: false, wash: false, role: 'frame', marquee });
    line(outline.concat([outline[0]]), screenPen(Object.assign({ tone: ink0 }, DASHED, { role: 'frame', label: name, marquee })));
    nameMark([bx, by, bw, bh], name);
  };
  // ring(x, y, w, h, name, {r}): a loop around one thing. A pill round anything thin, a round loop round something
  // small and squarish, and for anything bigger a hand-drawn rounded box (a circle round a big box swallows the screen).
  const loopRadius = (bw, bh) => {
    const short = min(bw, bh), long = max(bw, bh);
    if (short <= pt(56) || (long <= pt(120) && long < short * 1.4)) return short / 2;
    return max(pt(8), min(pt(18), short * 0.12));
  };
  const ring = (x, y, w, h, name, o = {}) => {
    const p = pt(4), bw = w + 2 * p, bh = h + 2 * p;
    const outline = roundRect(x - p, y - p, bw, bh, typeof o.r === 'number' ? o.r + p : loopRadius(bw, bh));
    // the pen bows each side once and runs a little past where it started, like a hand going round
    line(outline.concat([outline[0], outline[1]]), screenPen({ tone: ink0, bow: 'pen', role: 'ring', label: name }));
    nameMark([x - p, y - p, bw, bh], name);
  };
  // ink(pts, {arrow, curve, label, ...}): a free stroke in the screen pen; arrow: true gives it an open 16 pt chevron.
  const ink = (pts, o = {}) => {
    const opts = Object.assign({}, SCREEN_PEN, o, { tone: o.tone || ink0 });
    delete opts.arrow; delete opts.curve; delete opts.label;
    if (o.arrow) { opts.head = opts.head || pt(16); opts.headAngle = opts.headAngle || PI / 7; }
    const mark = o.arrow ? arrow(pts, opts) : o.curve ? curve(pts, opts) : line(pts, opts);
    const middle = Array.isArray(pts) ? pts[round((pts.length - 1) / 2)] || pts[0] : null;
    if (o.label && middle) { const [w, h] = pillSize(o.label, PILL_SIZE); nameMark([middle[0] - w / 2, middle[1] - h / 2, w, h], o.label); }
    return mark;
  };
  const inkCircle = (x, y, r, o = {}) => circle(x, y, r, Object.assign({}, SCREEN_PEN, o, { tone: o.tone || ink0 }));
  // write(x, y, text, {anchor, size, tone}): handwriting on calm space, in whichever ink reads on what is under it.
  const write = (x, y, str, o = {}) => {
    const size = o.size || 24, w = widthOf(str, size, 0.5), left = o.anchor === 'middle' ? x - w / 2 : o.anchor === 'end' ? x - w : x;
    const tone = o.tone || (typeof __inkFor === 'function' ? __inkFor(left, y - size, w || 1, size * 1.25 || 1) : WHITE_INK);
    return text(x, y, str, Object.assign({ style: 'hand', size }, o, { tone }));
  };

  // ---------------------------------------------------------------- teaching on top of the screen
  // num(x, y, n, {r}): a numbered badge. On a card, a badge starting a row moves in to line up with the card's left edge.
  const num = (x, y, n, o = {}) => {
    const r = o.r || pt(9);
    const card = cards.filter(b => x - r < b[0] && x >= b[0] - r - pt(2) && y >= b[1] - r && y <= b[1] + b[3] + pt(48)).pop();
    if (card) x = card[0] + r;
    pills.push([x - r, y - r, 2 * r, 2 * r]);
    gel(x - r, y - r, 2 * r, 2 * r, 'num');
    // centred on the digits' ink: below y for the gel's rim and shadow, and a lone "1" nudged right
    const digits = String(n), size = r * 1.15, nudge = /^1+$/.test(digits) ? size * 0.032 : 0;
    text(x + nudge, y + size * 0.355 + pt(0.8), digits, { style: 'ui', weight: 700, size, tone: PILL_WORDS, anchor: 'middle', place: false, role: 'num' });
  };
  // underline(x, y, w): y is the bottom of the letters; the line sits just under it.
  const underline = (x, y, w, o = {}) => {
    const yy = y + pt(3);
    return line([[x, yy], [x + w, yy]], Object.assign({}, SCREEN_PEN, { size: pt(3), smooth: false, wobble: 0.3 }, o, { tone: o.tone || ink0, role: 'underline' }));
  };
  // connect(a, b, {label, bend}): a gently curved arrow from one thing to another.
  const connect = (a, b, o = {}) => ink([a, b], Object.assign({ arrow: true, bend: 0.2 }, o, { role: 'connect' }));
  // trace(pts, {straight, fill, label}): a closed outline round an irregular thing. straight keeps its corners (each
  // side bowed once, like a hand); fill: true tints the inside in the ink, or give fill a tone.
  const trace = (pts, o = {}) => {
    const shape = o.straight ? { smooth: false, bow: 'pen', jitter: 2, wobble: 1 } : { smooth: true };
    const tint = o.fill === true ? { fillAlpha: 0.18, wash: false } : {};
    const opts = Object.assign({}, SCREEN_PEN, shape, tint, o, { tone: o.tone || ink0, role: 'trace' });
    delete opts.straight; delete opts.label;
    if (o.fill === true) opts.fill = ink0;
    const mark = poly(pts, opts);
    if (o.label && Array.isArray(pts) && pts.length) nameMark(boundsOf(pts), o.label);
    return mark;
  };
  // check / cross: right and wrong. strike(x, y, w): through words that are wrong (y is the middle of the letters).
  const check = (x, y, s = pt(12)) => line([[x - s * 0.6, y], [x - s * 0.15, y + s * 0.5], [x + s * 0.7, y - s * 0.6]], screenPen({ tone: ink0, smooth: false, role: 'check' }));
  const cross = (x, y, s = pt(10)) => {
    line([[x - s / 2, y - s / 2], [x + s / 2, y + s / 2]], screenPen({ tone: ink0, role: 'cross' }));
    line([[x + s / 2, y - s / 2], [x - s / 2, y + s / 2]], screenPen({ tone: ink0, role: 'cross' }));
  };
  const strike = (x, y, w) => line([[x - 2, y], [x + w + 2, y]], screenPen({ tone: ink0, size: pt(3), smooth: false, role: 'strike' }));
  // scroll(x, y, 'down' | 'up', name): scroll here, not click: an arrow with a second chevron.
  const scroll = (x, y, dir = 'down', name) => {
    const up = dir === 'up', s = up ? -1 : 1, l = pt(22), c = pt(7), elbow = l * 0.45;
    arrow([[x, y - s * l], [x, y + s * l]], screenPen({ tone: ink0, head: pt(10), headAngle: PI / 7, role: 'scroll' }));
    line([[x - c, y + s * elbow], [x, y + s * (elbow + c)], [x + c, y + s * elbow]], screenPen({ tone: ink0, smooth: false, role: 'scroll' }));
    nameMark([x - c, y - l, 2 * c, 2 * l], name == null ? (up ? 'scroll up' : 'scroll down') : name);
  };
  // cheer(x, y, face): one little face in a pill when something went right; only the first one a drawing asks for.
  let cheered = false;
  const cheer = (x, y, face = '(^_^)v') => {
    if (cheered) return null;
    cheered = true;
    return label(x, y, face, { role: 'cheer' });
  };

  // ---------------------------------------------------------------- photos and credits
  const usedPages = new Set();
  // photo(x, y, w, h, query, caption, {subtitle, tilt, web, from, noPeople}): a real photo found by image search, printed
  // as a polaroid taped to the screen. x, y, w, h is the picture; the print (border, caption strip) grows round it.
  // web: search the web only (something new); from: a news page whose preview picture to use (each page once);
  // noPeople: skip results showing people. Returns {box} of the whole print, for tie() and button().
  const photo = (x, y, w, h, query, caption, o = {}) => {
    const subtitle = typeof o.subtitle === 'string' ? o.subtitle.trim() : '';
    const strip = max(w * 0.24, pt(34)), size = min(max(strip * 0.42, 18), 30), small = max(16, round(size * 0.74));
    const captionAt = subtitle ? strip * 0.5 : strip * 0.62, subtitleAt = captionAt + size * 0.3 + 5 + small * 0.75;
    const bottom = subtitle ? subtitleAt + small * 0.3 + strip * 0.2 : strip, side = max(pt(7), w * 0.055), deg = o.tilt ?? -2;
    [x, y] = clearOf3d(x - side, y - side, w + 2 * side, h + side + bottom);
    x += side; y += side;
    const print = corners(x - side, y - side, w + 2 * side, h + side + bottom);
    const centre = [x + w / 2, y + (h + bottom - side) / 2], turn = p => rotate(p, centre, deg * PI / 180);
    poly(print.map(p => turn([p[0] + pt(1.5), p[1] + pt(4)])), { fill: SHADOW, fillAlpha: 0.2, outline: false, wash: false, role: 'paper', together: true });
    poly(print.map(turn), { fill: paperPrint, fillAlpha: 1, outline: false, wash: false, role: 'paper', together: true, snd: 'photo-drop' });
    let page = typeof o.from === 'string' && /^https?:\/{2}/i.test(o.from) ? o.from.trim() : '';
    if (usedPages.has(page)) page = '';
    if (page) usedPages.add(page);
    const name = String(query || caption || '');
    const search = (o.noPeople ? 'nopeople: ' : '') + (page ? 'page: ' + page + ' :: ' + name : (o.web ? 'web: ' : '') + name);
    const [px, py] = turn([x + w / 2, y + h / 2]);
    image(px - w / 2, py - h / 2, w, h, { query: search, r: pt(1), rot: deg, role: 'photo' });
    const [tx, ty] = turn([x + w / 2, y - side]), tapeH = pt(18);
    tape(tx, ty - tapeH * 0.05, min(w * 0.42, pt(80)), tapeH, deg + 3);
    if (caption) {
      const [cx, cy] = turn([x + w / 2, y + h + captionAt]);
      text(cx, cy, caption, { style: 'hand', size, tone: 'ink', anchor: 'middle', fit: [w, strip * 0.8], rot: deg, place: false, role: 'photo' });
    }
    if (subtitle) {
      const [sx, sy] = turn([x + w / 2, y + h + (caption ? subtitleAt : strip * 0.62)]);
      text(sx, sy, subtitle, { style: 'hand', size: small, tone: 'grey', anchor: 'middle', fit: [w * 0.94, small * 2], rot: deg, place: false, role: 'photo' });
    }
    return { box: [x - side, y - side, w + 2 * side, h + side + bottom] };
  };
  // tie(from, to, {bend}): an arrow from a row's end ([x, y]) to the photo or box it is about, stopping just short of the
  // box's nearest edge. It keeps the paper's felt pen (thin, tapered, no glow) and stays with the drawing.
  const tie = (from, to, o = {}) => {
    const b = to && to.box ? to.box : to;
    if (!Array.isArray(from) || !Array.isArray(b) || b.length < 4) return null;
    const [bx, by, bw, bh] = b, cx = bx + bw / 2, cy = by + bh / 2, dx = from[0] - cx, dy = from[1] - cy;
    if (!dx && !dy) return null;
    const reach = min(dx ? (bw / 2 + pt(6)) / abs(dx) : Infinity, dy ? (bh / 2 + pt(6)) / abs(dy) : Infinity);
    if (reach >= 1) return null;
    // tieTo lets the engine start the arrow where the row's words really end
    return ink([from, [cx + dx * reach, cy + dy * reach]], Object.assign({ arrow: true, bend: pt(22), size: pt(2.5), taper: 1, glow: null, head: pt(8), headAngle: 0.5 }, o,
      { role: 'tie', tieTo: [bx, by, bw, bh, pt(6), pt(8)] }));
  };
  const hostOf = domain => String(domain || '').trim().toLowerCase().replace(/^https?:\/{2}/, '').replace(/[\/?#].*$/, '').replace(/^www\./, '');
  // source(x, y, domain, words, {size}): one grey credit line with the site's icon; y is its baseline.
  const source = (x, y, domain, words, o = {}) => {
    const size = o.size || 15, icon = round(size * 0.95), host = hostOf(domain);
    if (host) image(x, y - size * 0.82, icon, icon, { query: 'favicon: ' + host, r: pt(2), role: 'source' });
    return text(host ? x + icon + round(size * 0.4) : x, y, words, Object.assign({ size, tone: 'grey' }, o, { place: false }));
  };
  // sources(x, y, [[domain, name], ...], {size, maxWidth}): every site an answer used, once each, in one quiet line. It
  // goes in the footer of the card it belongs to (the card under or nearest it, which grows to hold it); with no card it
  // gets a small paper plate of its own so it reads over any app.
  const sources = (x, y, list, o = {}) => {
    const size = o.size || 13, icon = round(size * 0.95), gap = round(size * 0.35), apart = round(size * 1.2), lineStep = round(size * 1.6);
    const wide = str => widthOf(str, size, 0.42), seen = new Set(), sites = [];
    for (const entry of Array.isArray(list) ? list : []) {
      const [domain, siteName] = Array.isArray(entry) ? entry : [entry && entry.domain, entry && entry.name], host = hostOf(domain);
      if (!host || seen.has(host)) continue;
      seen.add(host);
      sites.push([host, String(siteName || host)]);
    }
    if (!sites.length) return null;
    const away = b => hypot(max(b[0] - x, 0, x - (b[0] + b[2])), max(b[1] - y, 0, y - (b[1] + b[3])));
    const card = cards.filter(b => x >= b[0] - pt(30) && x <= b[0] + b[2] && y >= b[1] && y <= b[1] + b[3] + pt(48)).pop()
      || cards.slice().sort((a, b) => away(a) - away(b))[0];
    if (!card && typeof __hideLoneSources !== 'undefined' && __hideLoneSources === true) return null;
    let maxWidth = o.maxWidth;
    if (card) {
      x = card[0]; y = card[1] + card[3] + WINDOW.pad + size * 0.7; maxWidth = card[2];
    } else {
      // lay the line out once to size its plate, then write it inside
      let rowX = wide('Sources') + apart, rows = 1, widest = rowX;
      for (const [, siteName] of sites) {
        const span = icon + gap + wide(siteName);
        if (maxWidth && rowX + span > maxWidth && rowX > 0) { rows += 1; rowX = 0; }
        rowX += span + apart;
        widest = max(widest, rowX - apart);
      }
      const padX = round(size * 0.9), padY = round(size * 0.6);
      const plate = keepOn([x - padX, y - size * 0.95 - padY, widest + 2 * padX, size * 1.2 + (rows - 1) * lineStep + 2 * padY]);
      x = plate[0] + padX; y = plate[1] + padY + size * 0.95;
      poly(roundRect(plate[0], plate[1] + pt(1), plate[2], plate[3], pt(8)), { fill: SHADOW, fillAlpha: 0.08, outline: false, wash: false, role: 'source', together: true });
      // sourcePlate: laid out like a card, but a drawing that is only its sources isn't kept as a picture
      poly(roundRect(plate[0], plate[1], plate[2], plate[3], pt(8)), { fill: paperCard, fillAlpha: 1, outline: false, wash: false, role: 'paper', together: true, sourcePlate: true });
    }
    // on a card, the engine moves the whole line together under whatever ends up lowest on it
    const onWindow = card ? [card[0], card[1]] : undefined, together = card ? { sourceLine: y, sourceSize: size } : {};
    text(x, y, 'Sources', Object.assign({ size, tone: 'grey', place: false, onWindow }, together));
    let cx = x + wide('Sources') + apart, cy = y;
    for (const [host, siteName] of sites) {
      const span = icon + gap + wide(siteName);
      if (maxWidth && cx + span > x + maxWidth && cx > x) { cx = x; cy += lineStep; }
      image(cx, cy - size * 0.82, icon, icon, Object.assign({ query: 'favicon: ' + host, r: pt(2), role: 'source', onWindow }, together));
      text(cx + icon + gap, cy, siteName, Object.assign({ size, tone: 'grey', place: false, onWindow }, together));
      cx += span + apart;
    }
    return null;
  };

  // ---------------------------------------------------------------- the app acts (when the line is heard)
  const say = v => String(v == null ? '' : v);
  // typeText(x, y, text): types into the field there (the clipboard if it refuses); never presses Return.
  const typeText = (x, y, str) => signal(x, y, { role: 'type', payload: say(str) });
  // copyText(text): puts exact text on the clipboard. openPage(url): opens a page in their browser (last beat).
  const copyText = str => signal(2, 2, { role: 'copy', payload: say(str) });
  const openPage = url => signal(4, 2, { role: 'open', payload: say(url) });
  // handOff({task, label, mate | newMate}): gives work to one of the user's Mates.
  const handOff = o => signal(6, 2, { role: 'handoff', payload: JSON.stringify(o && typeof o === 'object' ? o : { task: say(o) }) });
  // sfx(name): an extra sound as the next mark lands: ding, nope, stamp, tada, sparkle, whoosh, boing.
  const sfx = name => signal(8, 2, { role: 'sfx', payload: say(name) });
  // The drawn welcome tour: tourJob(job) shows a job card, tuckJobs() files them into the notch, showNotch({apps})
  // opens it, fadeAway() closes it and clears the drawing, nextQuestions([[text, plan], ...]) offers three follow-ups.
  const tourJob = o => signal(6, 2, { role: 'tourjob', payload: JSON.stringify(o && typeof o === 'object' ? o : { title: say(o) }) });
  const tuckJobs = () => signal(6, 2, { role: 'tourtuck', payload: 'tuck' });
  const showNotch = o => signal(6, 2, { role: 'tournotch', payload: o && o.apps ? 'apps' : 'notch' });
  const fadeAway = () => signal(6, 2, { role: 'tourfade', payload: 'fade' });
  const nextQuestions = list => {
    const asks = (Array.isArray(list) ? list : []).map(q => Array.isArray(q) ? { text: String(q[0] || ''), plan: String(q[1] || '') }
      : q && typeof q === 'object' ? { text: String(q.text || ''), plan: String(q.plan || q.ask || '') } : { text: String(q || ''), plan: '' });
    return signal(6, 2, { role: 'tourasks', payload: JSON.stringify(asks.filter(q => q.text)) });
  };
  // Read by the app from the program's text; they draw nothing.
  const lessonTitle = () => {}, plan = () => {}, task = () => {}, waitForUser = () => {}, onScreen = () => {};

  // button(x, y, text, action) or button(photoOrBox, text, action): a real button for the likely next step. Anchored to
  // a photo or a box, it sits centred on that thing's bottom edge like a price tag; given a spot, it moves off anything
  // already drawn there. action: {open: url} | {copy: text} | {ask: words} | {handOff: {...}} | {card: ...}.
  const ACTIONS = [['open', 'open'], ['copy', 'copy'], ['ask', 'ask'], ['handOff', 'handoff'], ['card', 'card']];
  const clearOfInk = b => {
    const drawn = typeof __inkBoxes === 'function' ? __inkBoxes() : [];
    const blocked = t => overlaps(t, drawn) || overlaps(t, pills);
    if (!blocked(b)) return b;
    const dy = b[3] + pt(6), dx = b[2] / 2 + pt(6), tries = [];
    for (let k = 1; k <= 8; k++) tries.push([0, k], [0, -k], [k, 0], [-k, 0], [k, k], [-k, k]);
    const free = tries.map(([i, j]) => [b[0] + i * dx, b[1] + j * dy, b[2], b[3]]).filter(t => onCanvas(t) && !blocked(t))
      .sort((p, q) => hypot(p[0] - b[0], p[1] - b[1]) - hypot(q[0] - b[0], q[1] - b[1]));
    return free[0] || b;
  };
  const button = (x, y, str, action = {}) => {
    let anchor = null;
    if (x && typeof x === 'object') {
      anchor = Array.isArray(x) ? x : x.box;
      if (!Array.isArray(anchor) || anchor.length < 4) return null;
      action = str || {}; str = y;
    }
    str = say(str).trim();
    if (!str || !action || typeof action !== 'object') return null;
    const found = ACTIONS.find(([key]) => action[key]);
    if (!found) return null;
    const [key, kind] = found, [pw, ph] = pillSize(str, BUTTON_SIZE), w = round(pw + BUTTON_SIZE * 1.6), h = round(ph * 1.25);
    const b = anchor ? keepOn([anchor[0] + anchor[2] / 2 - w / 2, anchor[1] + anchor[3] - h / 2, w, h]) : clearOfInk(keepOn([x, y, w, h]));
    pills.push(b);
    signal(b[0], b[1], { role: 'button', box: b, payload: JSON.stringify({ text: str, kind, value: action[key] }) });
    // the app lays the real, pressable button over this spot; without it (a test render) the piece draws the face
    if (!hostDraws.buttons()) {
      gel(b[0], b[1], w, h, 'button');
      text(b[0] + w / 2, b[1] + h * 0.66, str + (kind === 'open' ? '  ↗' : ''), { style: 'ui', weight: 600, size: BUTTON_SIZE, tone: PILL_WORDS, anchor: 'middle', place: false, role: 'button' });
    }
    return b;
  };

  // ---------------------------------------------------------------- paper
  // A strip of tape in the light gel tone, torn at both ends, centred on cx, cy.
  const tape = (cx, cy, w, h, deg) => {
    const x = cx - w / 2, y = cy - h / 2, steps = 4, left = [], right = [];
    for (let i = steps; i >= 0; i--) left.push([x + (i % 2 ? 2.5 : 0), y + i * h / steps]);
    for (let i = steps; i >= 0; i--) right.push([x + w - (i % 2 ? 0 : 2.5), y + h - i * h / steps]);
    poly(turned(left.concat(right), deg), { fill: gelMid, fillAlpha: 0.8, outline: false, wash: false, role: 'paper', snd: 'tape' });
  };
  // Words that start at the top of a sheet's writing area: on the alphabetic baseline the first line sits on y and the
  // rest wrap downward (a centred baseline lifted long notes onto the tape).
  const TOP = 'alphabetic';
  // sticky(x, y, text, colour, {size, tilt, textSize}): a square note with a folded corner and tape, a touch askew.
  const sticky = (x, y, str, colour = 'butter', o = {}) => {
    const s = o.size || 170, deg = o.tilt ?? -2, fill = STICKY[colour] || colour, fold = 24;
    [x, y] = clearOf3d(x, y, s, s);
    const sheet = [[x, y], [x + s, y], [x + s, y + s - fold], [x + s - fold, y + s], [x, y + s]], whole = [x, y, s, s];
    poly(turned(sheet.map(p => [p[0], p[1] + 3]), deg), { fill: 'ink', fillAlpha: 0.07, outline: false, wash: false, role: 'paper', together: true });
    poly(turned(sheet.map(p => [p[0], p[1] + 1]), deg), { fill: 'ink', fillAlpha: 0.08, outline: false, wash: false, role: 'paper', together: true });
    poly(turned(sheet, deg), { fill, fillAlpha: 1, outline: false, wash: false, role: 'paper', snd: 'sticky-press' });
    // the fold turns with the sheet it belongs to
    poly(turned([[x + s - fold, y + s], [x + s, y + s - fold], [x + s - 20, y + s - 20]], deg, whole), { fill: 'ink', fillAlpha: 0.12, outline: false });
    tape(x + s * 0.5, y + 1, s * 0.4, 20, deg);
    text(x + 16, y + 40, say(str), { style: 'hand', size: o.textSize || 22, tone: 'ink', fit: [s - 32, s - 50], rot: deg, baseline: TOP });
  };

  // ---------------------------------------------------------------- windows
  // Every explanation card is a little Mac window: a soft shadow, a thin dark frame, a title bar (grey washed with the
  // ink) with two buttons and an optional lower-case title, and a board in the paper tone. The box a program gives is
  // the writing area; the window grows round it by a padding and puts its title bar above. The app paints real
  // windows when it can; otherwise (a test render) they are built from plain shapes.
  const WINDOW = { header: pt(28), pad: pt(24), radius: pt(10) };
  const BOARDS = ['dots', 'grid', 'plain'];
  const drawWindow = (x, y, w, h, o = {}) => {
    const { header, pad, radius } = WINDOW;
    // kept on the screen: a box against the top or left edge loses some margin there instead
    const X = max(2, x - pad), Y = max(2, y - pad - header), Wd = x + w + pad - X, Hd = y + h + pad - Y;
    if (o.footer) cards.push([x, y, w, h]);
    const title = o.title == null ? '' : String(o.title).replace(/\s+/g, ' ').trim().slice(0, 60);
    const board = BOARDS.includes(o.board) ? o.board : o.grid === false ? 'plain' : 'grid', bg = o.bg || paperCard, snd = o.snd || 'paper-place';
    if (hostDraws.windows()) {
      __window(X, Y, Wd, Hd, { header, pad, inner: [x, y, w, h], title, board, bg, tint: washColour, tintAlpha: washAlpha, role: 'paper', snd });
      return;
    }
    const sheet = (pts, fill, fillAlpha, extra) => poly(pts, Object.assign({ fill, fillAlpha, outline: false, wash: false, role: 'paper', together: true }, extra));
    sheet(roundRect(X, Y + pt(8), Wd, Hd, radius), SHADOW, 0.1);
    sheet(roundRect(X - pt(1), Y - pt(1), Wd + pt(2), Hd + pt(2), radius + pt(1)), '#2A2A2C', 0.5);
    sheet(roundRect(X, Y, Wd, Hd, radius), bg, 1, { snd });
    sheet(topRoundRect(X, Y, Wd, header, radius), '#E3E2E4', 1);
    sheet(topRoundRect(X, Y, Wd, header, radius), washColour, washAlpha);
    sheet(corners(X, Y + header - pt(0.5), Wd, pt(0.5)), '#000000', 0.1);
    ['#FF736A', '#19C332'].forEach((c, k) => dot(X + pt(16 + 20 * k), Y + header / 2, pt(6), { tone: c, fill: c, role: 'paper' }));
    if (title) text(X + Wd / 2, Y + header / 2 + pt(4.5), title.toLowerCase(), { style: 'ui', weight: 600, size: pt(13), tone: 'grey', anchor: 'middle', fit: [Wd - pt(150), header], knockout: false });
  };
  // A 3D figure alone on a busy screen stands in a window too; the engine calls this before building the figure.
  if (hostDraws.windows()) __card3d = (x, y, w, h, o = {}) => drawWindow(x, y, w, h, { title: o.title, board: o.board || 'plain', footer: true });

  // receipt(x, y, title, items, {w, board, title}): a numbered list in a window.
  const receipt = (x, y, title, items = [], o = {}) => {
    const rows = Array.isArray(items) ? items : [], w = o.w || 240, step = 30, h = 48 + rows.length * step;
    [x, y] = clearOf3d(x, y, w, h);
    drawWindow(x, y, w, h, { board: o.board || 'plain', title: o.title });
    text(x, y + 24, title, { style: 'title', size: 20, tone: 'ink', fit: [w, 28] });
    rows.forEach((item, i) => text(x, y + 54 + i * step, (i + 1) + '. ' + item, { style: 'hand', size: 19, tone: 'ink', fit: [w, step] }));
  };
  // clipping(x, y, w, title, body, source, {h, board, title}): a fact in a window, its source in the title bar.
  const clipping = (x, y, w, title, body, from, o = {}) => {
    const h = o.h || 130;
    [x, y] = clearOf3d(x, y, w, h);
    drawWindow(x, y, w, h, { board: o.board || 'plain', title: from || o.title });
    text(x, y + 24, title, { style: 'title', size: 20, tone: 'ink', fit: [w, 28] });
    text(x, y + 52, body, { style: 'body', size: 17, tone: 'grey', fit: [w, h - 56], baseline: TOP });
  };
  // legend(x, y, [[tone, words], ...], {size}): colour keys in a row; y is the words' baseline. Returns its width.
  const legend = (x, y, items = [], o = {}) => {
    const size = o.size || 15, r = max(3, round(size * 0.3)), gap = round(size * 0.45), apart = round(size * 1.3);
    let cx = x;
    for (const entry of Array.isArray(items) ? items : []) {
      const [colour, words] = Array.isArray(entry) ? entry : [entry && entry.tone, entry && entry.label];
      if (!words) continue;
      dot(cx + r, y - size * 0.3, r, { tone: colour || 'grey', fill: colour || 'grey', role: 'key' });
      text(cx + 2 * r + gap, y, String(words), { size, tone: 'grey', place: false });
      cx += 2 * r + gap + widthOf(words, size, 0.42) + apart;
    }
    return max(0, cx - apart - x);
  };
  // paper(x, y, w, h, {title, heading, subtitle, board}): a window to draw on (board 'grid' by default, 'dots' or
  // 'plain'). The heading and its grey subtitle sit at the top left; a short heading doubles as the window's title.
  // Returns the area left under them, {x, y, w, h}.
  const paper = (x, y, w, h, o = {}) => {
    const tidy = v => (v == null ? '' : String(v).replace(/\s+/g, ' ').trim());
    const heading = tidy(o.heading), subtitle = tidy(o.subtitle), title = tidy(o.title) || (heading.split(' ').length <= 5 ? heading : '');
    drawWindow(x, y, w, h, { title, board: o.board, grid: o.grid, footer: true });
    let top = y;
    if (heading) {
      text(x, y + 20, heading, { style: 'title', size: 26, tone: 'ink', place: false, fit: [w, 34] });
      top = y + 20 + 26 * 0.3;
    }
    if (subtitle) {
      const baseline = heading ? y + 50 : y + 14;
      text(x, baseline, subtitle, { size: 18, tone: 'grey', place: false, fit: [w, 24] });
      top = baseline + 18 * 0.3;
    }
    if (top > y) top += 32;
    return { x, y: top, w, h: max(40, y + h - top) };
  };

  // ---------------------------------------------------------------- the welcome tour's pieces
  // spotlight(x, y, w, h, {pad, r, alpha}): dims the whole screen but a soft-cornered opening round one thing;
  // spotlight() dims all of it. Its role is 'stage' so the dark layer never catches clicks as a card would.
  const spotlight = (x, y, w, h, o = {}) => {
    if (x && typeof x === 'object') { o = x; x = undefined; }
    const open = isFinite(x) && isFinite(y) && w > 0 && h > 0, pad = o.pad ?? 10;
    const hole = open ? [x - pad, y - pad, w + 2 * pad, h + 2 * pad] : [0, 0, 0, 0];
    // the screen clockwise, the opening the other way round: under the non-zero rule the opening stays clear
    const cutout = open ? ' M' + roundRect(...hole, o.r ?? 14).reverse().map(p => `${p[0].toFixed(1)},${p[1].toFixed(1)}`).join(' L') + ' Z' : '';
    path(`M0,0 L${W},0 L${W},${H} L0,${H} Z` + cutout, { fill: '#0B0D11', fillAlpha: o.alpha ?? 0.84, outline: false, wash: false, role: 'stage', snd: 'whoosh' });
    return { box: hole };
  };
  // Small hand-drawn icons for a job with no photo, drawn in a box of side s round cx, cy.
  const felt = { tone: 'ink', size: 2.4, smooth: false };
  const thicker = Object.assign({}, felt, { size: 3.2 });
  const greyRule = { tone: 'grey', size: 2, smooth: false };
  const ICONS = {
    search: (cx, cy, s) => { circle(cx - s * 0.12, cy - s * 0.12, s * 0.3, felt); line([[cx + s * 0.1, cy + s * 0.1], [cx + s * 0.42, cy + s * 0.42]], thicker); },
    reviews: (cx, cy, s) => {
      const star = (sx, sy, r) => poly(range(10).map(k => polar(sx, sy, k % 2 ? r * 0.45 : r, -PI / 2 + k * PI / 5)), { tone: 'ink', size: 1.8, fill: 'sun', fillAlpha: 0.9 });
      star(cx - s * 0.28, cy - s * 0.28, s * 0.17); star(cx + s * 0.05, cy - s * 0.38, s * 0.17);
      circle(cx + s * 0.02, cy + s * 0.08, s * 0.24, felt); line([[cx + s * 0.2, cy + s * 0.26], [cx + s * 0.44, cy + s * 0.48]], thicker);
    },
    page: (cx, cy, s) => {
      rect(cx - s * 0.48, cy - s * 0.36, s * 0.96, s * 0.72, Object.assign({}, felt, { fill: 'white', fillAlpha: 0.9 }));
      line([[cx - s * 0.48, cy - s * 0.18], [cx + s * 0.48, cy - s * 0.18]], felt);
      rect(cx - s * 0.32, cy - s * 0.04, s * 0.36, s * 0.22, { tone: 'ink', size: 1.6, fill: 'sky', fillAlpha: 0.8 });
      line([[cx + s * 0.12, cy], [cx + s * 0.34, cy]], greyRule); line([[cx + s * 0.12, cy + s * 0.12], [cx + s * 0.28, cy + s * 0.12]], greyRule);
    },
    people: (cx, cy, s) => {
      for (const [dx, k] of [[-0.2, 1], [0.22, 0.85]]) {
        circle(cx + dx * s, cy - s * 0.2 * k, s * 0.13 * k, Object.assign({}, felt, { fill: 'peach', fillAlpha: 0.9 }));
        curve([[cx + dx * s - s * 0.22 * k, cy + s * 0.34], [cx + dx * s, cy + s * 0.02], [cx + dx * s + s * 0.22 * k, cy + s * 0.34]], { tone: 'ink', size: 2.4 });
      }
    },
    mail: (cx, cy, s) => {
      rect(cx - s * 0.46, cy - s * 0.3, s * 0.92, s * 0.6, Object.assign({}, felt, { fill: 'white', fillAlpha: 0.9 }));
      line([[cx - s * 0.46, cy - s * 0.3], [cx, cy + s * 0.06], [cx + s * 0.46, cy - s * 0.3]], felt);
      line([[cx + s * 0.26, cy - s * 0.52], [cx + s * 0.5, cy - s * 0.52], [cx + s * 0.4, cy - s * 0.42]], { tone: 'ink', size: 1.8, smooth: false });
    },
    chart: (cx, cy, s) => {
      line([[cx - s * 0.45, cy - s * 0.4], [cx - s * 0.45, cy + s * 0.38], [cx + s * 0.46, cy + s * 0.38]], felt);
      [[0.22, 'sky'], [0.42, 'mint'], [0.66, 'leaf']].forEach(([tall, c], k) => rect(cx - s * 0.32 + k * s * 0.26, cy + s * 0.38 - s * tall, s * 0.18, s * tall, { tone: 'ink', size: 1.6, fill: c, fillAlpha: 0.85 }));
    },
    list: (cx, cy, s) => {
      for (let k = 0; k < 3; k++) {
        const ry = cy - s * 0.3 + k * s * 0.3;
        rect(cx - s * 0.44, ry - s * 0.09, s * 0.18, s * 0.18, { tone: 'ink', size: 1.8 });
        line([[cx - s * 0.16, ry], [cx + s * (0.44 - k * 0.1), ry]], { tone: 'grey', size: 2.2, smooth: false });
      }
      line([[cx - s * 0.42, cy - s * 0.31], [cx - s * 0.36, cy - s * 0.25], [cx - s * 0.24, cy - s * 0.42]], { tone: 'leaf', size: 2.4, smooth: false });
    },
    map: (cx, cy, s) => {
      poly([[cx, cy + s * 0.46], [cx - s * 0.3, cy - s * 0.02], [cx - s * 0.3, cy - s * 0.2], [cx - s * 0.18, cy - s * 0.4], [cx, cy - s * 0.46], [cx + s * 0.18, cy - s * 0.4], [cx + s * 0.3, cy - s * 0.2], [cx + s * 0.3, cy - s * 0.02]],
        { tone: 'ink', size: 2.2, fill: 'coral', fillAlpha: 0.85, smooth: true });
      circle(cx, cy - s * 0.16, s * 0.1, { tone: 'ink', size: 1.8, fill: 'white', fillAlpha: 1 });
    },
    code: (cx, cy, s) => {
      line([[cx - s * 0.18, cy - s * 0.3], [cx - s * 0.46, cy], [cx - s * 0.18, cy + s * 0.3]], felt);
      line([[cx + s * 0.18, cy - s * 0.3], [cx + s * 0.46, cy], [cx + s * 0.18, cy + s * 0.3]], felt);
      line([[cx + s * 0.08, cy - s * 0.38], [cx - s * 0.08, cy + s * 0.38]], { tone: 'ink', size: 2, smooth: false });
    },
    calendar: (cx, cy, s) => {
      rect(cx - s * 0.42, cy - s * 0.32, s * 0.84, s * 0.74, Object.assign({}, felt, { fill: 'white', fillAlpha: 0.9 }));
      rect(cx - s * 0.42, cy - s * 0.32, s * 0.84, s * 0.2, { tone: 'ink', size: 2, fill: 'coral', fillAlpha: 0.85 });
      for (const [dx, dy] of [[-0.2, 0.06], [0.04, 0.06], [0.26, 0.06], [-0.2, 0.24], [0.04, 0.24]]) dot(cx + dx * s, cy + dy * s, 2.2, { tone: 'ink' });
    },
    chat: (cx, cy, s) => {
      poly([[cx - s * 0.44, cy - s * 0.32], [cx + s * 0.44, cy - s * 0.32], [cx + s * 0.44, cy + s * 0.18], [cx - s * 0.1, cy + s * 0.18], [cx - s * 0.3, cy + s * 0.38], [cx - s * 0.26, cy + s * 0.18], [cx - s * 0.44, cy + s * 0.18]],
        Object.assign({}, felt, { fill: 'white', fillAlpha: 0.9 }));
      line([[cx - s * 0.28, cy - s * 0.12], [cx + s * 0.28, cy - s * 0.12]], greyRule); line([[cx - s * 0.28, cy + s * 0.02], [cx + s * 0.12, cy + s * 0.02]], greyRule);
    },
    spark: (cx, cy, s) => poly(range(8).map(k => polar(cx, cy, k % 2 ? s * 0.16 : s * 0.46, -PI / 2 + k * PI / 4)), { tone: 'ink', size: 2, fill: 'sun', fillAlpha: 0.9 }),
  };
  // jobTicket(x, y, {title, steps, time, photo, web, icon, color, button, handOff}): a job Mate can do, as a ticket about
  // 310 x 122 (plus its button): a pastel stub with a photo or an icon and the time it takes, a perforation, the result
  // as the headline, one quiet line of the work ("I'll a · b · c", trimmed to fit), and its button on the bottom edge.
  // Returns {box, button}.
  const jobTicket = (x, y, o = {}) => {
    const steps = (Array.isArray(o.steps) ? o.steps : []).map(t => String(t || '').trim()).filter(Boolean).slice(0, 3);
    const w = o.w || 310, h = o.h || 122, stub = 92, r = 12, tint = STICKY[o.color] || o.color || STICKY.mint;
    [x, y] = clearOf3d(x, y, w, h + 20);
    const outline = roundRect(x, y, w, h, r);
    poly(outline.map(p => [p[0] + 1, p[1] + 5]), { fill: 'ink', fillAlpha: 0.12, outline: false, wash: false, role: 'paper', together: true });
    poly(outline, { fill: '#FFFDF7', fillAlpha: 1, outline: false, wash: false, role: 'paper', snd: 'paper-place' });
    // the stub: rounded on the left only
    const stubShape = [[x + stub, y]];
    for (let k = 0; k <= 6; k++) { const a = -PI / 2 - k * PI / 12; stubShape.push([x + r + cos(a) * r, y + r + sin(a) * r]); }
    for (let k = 0; k <= 6; k++) { const a = PI - k * PI / 12; stubShape.push([x + r + cos(a) * r, y + h - r + sin(a) * r]); }
    stubShape.push([x + stub, y + h]);
    poly(stubShape, { fill: tint, fillAlpha: 1, outline: false, wash: false, role: 'paper', together: true });
    poly(outline, { tone: 'ink', size: 1.8, fillAlpha: 0, wash: false, role: 'paper' });
    line([[x + stub, y + 10], [x + stub, y + h - 10]], { tone: 'grey', size: 1.6, dash: true, smooth: false });
    if (o.photo) {
      const side = stub - 26, px = x + 13, py = y + 10, border = corners(px - 3, py - 3, side + 6, side + 6);
      poly(border.map(p => [p[0] + 1, p[1] + 2]), { fill: 'ink', fillAlpha: 0.14, outline: false, wash: false, role: 'paper', together: true });
      poly(border, { fill: '#FFFFFF', fillAlpha: 1, outline: false, wash: false, role: 'paper', snd: 'photo-drop' });
      image(px, py, side, side, { query: (o.web ? 'web: ' : '') + String(o.photo), r: 2, rot: 0, role: 'photo' });
    } else {
      (ICONS[o.icon] || ICONS.spark)(x + stub / 2, y + h / 2 - 12, 40);
    }
    if (o.time) text(x + stub / 2, y + h - 12, String(o.time), { style: 'caps', size: 12, tone: 'ink', anchor: 'middle', fit: [stub - 10, 16], place: false });
    const tx = x + stub + 18, tw = w - stub - 30;
    text(tx, y + 40, String(o.title || ''), { style: 'title', size: 22, tone: 'ink', fit: [tw, 30], place: false });
    if (steps.length) {
      // the work, in Mate's words; past about 52 characters the last step goes rather than the type shrinking
      let shown = steps.map(t => t.replace(/[.]+$/, ''));
      while (shown.length > 1 && ("I'll " + shown.join(' · ')).length > 52) shown = shown.slice(0, -1);
      text(tx, y + 62, "I'll " + shown.join(' · '), { style: 'hand', size: 16, tone: 'grey', fit: [tw, 40], baseline: TOP, place: false });
    }
    const b = o.handOff ? button([x + stub, y, w - stub, h], String(o.button || o.title || 'Start'), { handOff: o.handOff }) : null;
    return { box: [x, y, w, h], button: b };
  };
  // dreamMedal(x, y, big, {caption, color}): a goal as it will look when it comes true: a gold medallion with rays and
  // a halo, `big` (1 to 6 characters) in its middle, and a ribbon with the caption. x, y is its centre; about 210 x 240.
  const dreamMedal = (x, y, big, o = {}) => {
    const R = 62, halo = R + 42, gold = o.color || 'sun';
    const spot = clearOf3d(x - halo, y - halo, 2 * halo, 2 * R + 122);
    x = spot[0] + halo; y = spot[1] + halo;
    circle(x, y, halo, { fill: '#FFF6D6', fillAlpha: 0.95, outline: false, wash: false, role: 'paper' });
    circle(x, y, halo, { tone: 'sun', size: 1.6, fillAlpha: 0, dash: true });
    path(range(16).map(k => { const a = k * PI / 8, p0 = polar(x, y, R + 12, a), p1 = polar(x, y, R + (k % 2 ? 26 : 36), a); return `M${p0[0]},${p0[1]} L${p1[0]},${p1[1]}`; }).join(' '), { tone: 'sun', size: 3 });
    circle(x + 2, y + 5, R, { fill: 'ink', fillAlpha: 0.16, outline: false, wash: false, together: true });
    circle(x, y, R, { fill: gold, fillAlpha: 1, tone: 'ink', size: 2.4, wash: false, snd: 'sparkle' });
    circle(x, y, R - 10, { tone: '#B7791F', size: 2, fillAlpha: 0 });
    const s = String(big || '').trim(), short = s.length <= 2;
    text(x, y + (short ? 18 : 12), s, { style: 'title', size: short ? 54 : s.length <= 4 ? 40 : 30, tone: 'ink', anchor: 'middle', fit: [2 * R - 24, 70], place: false });
    if (o.caption) {
      const cw = max(150, String(o.caption).length * 9 + 50), ry = y + R + 10, rh = 34, l = x - cw / 2, rr = x + cw / 2;
      poly([[l - 14, ry + 4], [l, ry], [rr, ry], [rr + 14, ry + 4], [rr, ry + rh / 2 + 2], [rr + 14, ry + rh], [l - 14, ry + rh], [l, ry + rh / 2 + 2]],
        { fill: 'coral', fillAlpha: 1, tone: 'ink', size: 2, wash: false, smooth: false });
      text(x, ry + rh / 2 + 7, String(o.caption), { style: 'hand', size: 19, tone: '#FFFFFF', anchor: 'middle', fit: [cw - 10, rh - 6], place: false });
    }
    return { box: [x - halo, y - halo, 2 * halo, 2 * R + 122] };
  };

  return {
    INK: ink0, lessonTitle, plan, task, waitForUser, onScreen,
    label, tag, point, target, hover, frame, ring, ink, inkCircle, write, num, underline, connect, trace, check, cross, strike, scroll, cheer,
    photo, tie, source, sources, typeText, copyText, openPage, button, handOff, tourJob, tuckJobs, showNotch, fadeAway, nextQuestions, sfx,
    sticky, spotlight, jobTicket, dreamMedal, receipt, clipping, legend, paper,
  };
})();
