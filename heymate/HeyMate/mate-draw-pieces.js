// Mate's pieces for drawing on the screen (drawing-v2). Prepended to every
// model program and run inside the engine's `with (api)` scope, so these
// helpers sit next to line/arrow/text/... The API is described to the model in
// worker/src/draw/screenDrawSkill.ts — keep the two in sync.
//
// One look for marking the real screen (the production walkthrough's look):
// every mark is Mate's ink, the user's cursor colour, with a soft glow in
// that colour; things are named in solid pills of that colour with white
// rounded words; steps are numbered badges of that colour; a region is a
// dashed frame with a faint tint. Paper (sticky, receipt, clipping) is only for
// an explanation card on calm space, never to name a thing on screen.
//
// Host hooks (globals the canvas page may define; all optional):
//   __mateInk           Mate's ink, '#RRGGBB' (the canvas glows it)
//   __inkFor(x, y, w, h) → '#FFFFFF' or '#15171C': white on dark areas, dark on
//                           light ones, for free words written on the screen
//   __hostDrawsPointers   true when the app draws target/hover itself (the
//                           click-wait ring); they still become marks with a
//                           `role` so the host can read them.
// Colours are exact hexes on purpose: the canvas halos ink by colour.

const INK = typeof __mateInk === 'string' && /^#[0-9A-F]{6}$/.test(__mateInk) ? __mateInk : '#3380FF'
const __INK_LIGHT = '#FFFFFF'
const __INK_DARK = '#15171C'
// Words on a pill: off-white so the canvas gives them no halo of their own (the pill is their background).
const __PILL_WORDS = '#FEFEFE'
const __SHADOW = '#1C1E24'
const __PAPER = {butter: '#FFE27A', mint: '#BFEFCF', peach: '#FFD0BC', lilac: '#D9D1FB', sky: '#CFE6FF', white: '#FAF5EA', news: '#F3EEE4'}
const __inkAt = (x, y, w, h) => (typeof __inkFor === 'function' ? __inkFor(x, y, w || 1, h || 1) : __INK_LIGHT)
const __boxOf = pts => { const xs = pts.map(p => p[0]), ys = pts.map(p => p[1]); const x0 = min(...xs), y0 = min(...ys); return [x0, y0, max(...xs) - x0, max(...ys) - y0] }
const __hostPointers = () => typeof __hostDrawsPointers !== 'undefined' && __hostDrawsPointers === true

// lessonTitle(text): names a lesson in the user's Lessons (the app reads it from the program). Draws nothing.
const lessonTitle = () => {}
// plan(text): the picture Mate means to draw, said to itself before the first beat. Draws nothing.
const plan = () => {}

// ---- sizes in screen points
// The canvas is the screenshot (about 1280 units wide), so one unit is usually more than a point. Everything that
// marks the real screen is sized in POINTS, like the rest of ReferenceRenderer's UI, so it looks the same on every display.
const __PT = typeof __canvasUnitPoints === 'number' && __canvasUnitPoints > 0 ? __canvasUnitPoints : 1
const __pt = v => v / __PT
const __LINE = __pt(3.5)          // the pen: rings, frames, arrows, underlines
// Mate's screen pen (2026-10-19, back to the old walkthrough's marks): an even 3.5pt line with round ends (taper 0)
// and a soft glow in its own colour, [[opacity, width], ...]. Paper, cards and tie() arrows keep the felt pen.
// The old walkthrough's shadow: ink at 65%, blurred 12pt ([opacity, radius]; the app blurs it, so it fades out softly
// instead of stopping at an edge like the stacked halo bands tried first, which read as a border).
const __GLOW = [0.65, __pt(12)]
const __SCREEN_PEN = {size: __LINE, taper: 0, glow: __GLOW}
const __screenPen = o => Object.assign({}, __SCREEN_PEN, o)
// The app drags a frame open from its corner itself (the painter's marquee); elsewhere it is drawn dash by dash.
const __hostMarquee = () => typeof __hostDrawsMarquee !== 'undefined' && __hostDrawsMarquee === true
const __PILL_TEXT = __pt(12)      // name pills: 12pt semibold system font, like the click target's pill
const __busyAt = (x, y, w, h) => (typeof __busyFor === 'function' ? __busyFor(x, y, w, h) : 0)

// ---- shapes the pieces share
const __roundRect = (x, y, w, h, r) => {
  r = max(0, min(r, w / 2, h / 2))
  const pts = [], arc = (cx, cy, a0) => { for (let k = 0; k <= 6; k++) { const a = a0 + k * PI / 12; pts.push([cx + cos(a) * r, cy + sin(a) * r]) } }
  arc(x + w - r, y + r, -PI / 2); arc(x + w - r, y + h - r, 0); arc(x + r, y + h - r, PI / 2); arc(x + r, y + r, PI)
  return pts
}
// Extra points along the long straight edges of an outline, so a smoothed stroke follows them instead of
// overshooting where an edge meets a corner's arc (wide rings had little tails at their corners).
const __densify = (pts, step) => {
  const out = []
  for (let k = 0; k < pts.length; k++) {
    const p = pts[k], q = pts[(k + 1) % pts.length], n = Math.floor(dist(p, q) / step)
    out.push(p)
    for (let j = 1; j < n; j++) out.push(along(p, q, j / n))
  }
  return out
}
// Pills placed by this program, so names never sit on each other, and the boxes of the marks they name, so a pill
// never sits on another mark's ring or frame either.
const __pills = []
const __marked = []
const __overlaps = (b, list) => list.some(o => b[0] < o[0] + o[2] + 4 && b[0] + b[2] + 4 > o[0] && b[1] < o[1] + o[3] + 4 && b[1] + b[3] + 4 > o[1])
const __onCanvas = b => b[0] >= 4 && b[1] >= 4 && b[0] + b[2] <= W - 4 && b[1] + b[3] <= H - 4
const __clampBox = b => [max(4, min(b[0], W - 4 - b[2])), max(4, min(b[1], H - 4 - b[3])), b[2], b[3]]
const __pillSize = (str, size) => [round(String(str).length * size * 0.58 + size * 1.9), round(size * 1.9)]

// Mate's Aqua gel (ReferenceRenderer's gel buttons, MateGelSurface): a PASTEL plate of Mate's colour, lighter at the
// top, a white gloss strip, a solid dark rim, dark words. The blue is the app's own gel; the other cursor colours get
// the same treatment. Flat fills stacked, no filters.
const __GEL_PALETTES = {
  '#3380FF': {top: '#EDF4FF', mid: '#A2C7FF', low: '#A2D2F7', rim: '#221898'},
  '#FF4C4C': {top: '#FFF1EF', mid: '#FFB8B0', low: '#FFC8C0', rim: '#7A1E1E'},
  '#D4A017': {top: '#FFF8E2', mid: '#FFDF8A', low: '#FFE9A8', rim: '#6E4E00'},
  '#26C281': {top: '#EFFBF2', mid: '#C9F0CF', low: '#B4E8C5', rim: '#17603F'},
}
const __mixHex = (hex, other, t) => {
  const p = h => [1, 3, 5].map(i => parseInt(h.slice(i, i + 2), 16)), a = p(hex), b2 = p(other)
  return '#' + a.map((v, i) => round(v + (b2[i] - v) * t).toString(16).padStart(2, '0')).join('').toUpperCase()
}
const __GEL = __GEL_PALETTES[INK] || {top: __mixHex(INK, '#FFFFFF', 0.9), mid: __mixHex(INK, '#FFFFFF', 0.55), low: __mixHex(INK, '#FFFFFF', 0.5), rim: __mixHex(INK, '#000000', 0.55)}
const __GEL_WORDS = __INK_DARK
// Mate's paper takes a whisper of the user's cursor colour too, still a matte off-white: a warm cream for yellow,
// a cool grey-blue for blue, a soft blush for red, a pale sage for green. card = paper() and receipts, news =
// clippings, print = a photo's polaroid frame. Another ink tints the cream a little toward it.
const __PAPER_TONES = {
  '#3380FF': {card: '#EFF2F6', news: '#E8ECF1', print: '#E9EEF4'},
  '#FF4C4C': {card: '#F9EFEA', news: '#F2E7E2', print: '#F5E9E4'},
  '#D4A017': {card: '#FAF5EA', news: '#F3EEE4', print: '#F4EEDF'},
  '#26C281': {card: '#EFF4EB', news: '#E7EEE3', print: '#E9F1E5'},
}
const __PAPER_TONE = __PAPER_TONES[INK] || {card: __mixHex('#FAF5EA', INK, 0.05), news: __mixHex('#F3EEE4', INK, 0.05), print: __mixHex('#F4EEDF', INK, 0.05)}
__PAPER.white = __PAPER_TONE.card
__PAPER.news = __PAPER_TONE.news
// The part of a capsule (rounded ends of radius h/2) above the line `fraction` of its height down: the same rounded
// ends, cut straight across, so a lighter band or a gloss never pokes out past the pill.
const __capsuleTop = (x, y, w, h, fraction) => {
  const r = h / 2, cutY = y + h * max(0.02, min(1, fraction)), pts = []
  const cutAngle = Math.asin(max(-1, min(1, (cutY - y - r) / r)))
  for (let k = 0; k <= 10; k++) { const a = -PI / 2 + (cutAngle + PI / 2) * k / 10; pts.push([x + w - r + r * cos(a), y + r + r * sin(a)]) }
  for (let k = 0; k <= 10; k++) { const a = PI - cutAngle + (cutAngle + PI / 2) * k / 10; pts.push([x + r + r * cos(a), y + r + r * sin(a)]) }
  return pts
}
const __capsule = (x, y, w, h) => __roundRect(x, y, w, h, h / 2)
const __gel = (x, y, w, h, role) => {
  const m = __pt(1), g = max(__pt(1.5), h * 0.09)
  const layer = (pts, fill, fillAlpha, together = true, extra) => poly(pts, Object.assign({fill, fillAlpha, outline: false, wash: false, role, together}, extra))
  // snd: the sound the canvas plays as the pill lands (its first layer only, so one pill is one pop)
  layer(__capsule(x, y + __pt(1), w, h), __SHADOW, 0.1, true, {snd: role === 'num' ? 'badge-pop' : role === 'cheer' ? 'boing' : role === 'button' ? 'button-appear' : 'gel-pop'})
  layer(__capsule(x - m, y - m, w + 2 * m, h + 2 * m), __GEL.rim, 1)
  layer(__capsule(x, y, w, h), __GEL.low, 1)
  layer(__capsuleTop(x, y, w, h, 0.78), __GEL.mid, 1)
  layer(__capsuleTop(x, y, w, h, 0.42), __GEL.top, 0.75)
  // the gloss: an inset capsule's top half, white
  layer(__capsuleTop(x + g, y + g * 0.6, w - 2 * g, h - 2 * g, 0.5), '#FFFFFF', 0.6, false)
}

// label(x, y, text): Mate's name pill, its top-left at x, y (anchor: 'middle' centres it on x). A small pastel
// Aqua gel capsule with dark system-font words: the same pill the app draws on a click target.
const label = (x, y, str, o = {}) => {
  str = String(str == null ? '' : str).trim()
  if (!str) return null
  const size = o.size || __PILL_TEXT
  const [w, h] = __pillSize(str, size)
  let b = __clampBox([o.anchor === 'middle' ? x - w / 2 : x, y, w, h]);
  [b[0], b[1]] = __clear(b[0], b[1], w, h)
  // a pill written straight onto another one steps down (then up) until it is clear
  if (__overlaps(b, __pills)) {
    const tries = [1, 2, 3, -1, -2, -3].map(k => __clampBox([b[0], b[1] + k * (h + __pt(4)), w, h]))
    b = tries.find(t => !__overlaps(t, __pills)) || b
  }
  __pills.push(b)
  __gel(b[0], b[1], w, h, o.role || 'label')
  text(b[0] + w / 2, b[1] + h * 0.68, str, {style: 'ui', weight: 600, size, tone: __GEL_WORDS, anchor: 'middle', fit: [w - size, h], place: false, role: o.role || 'label'})
  return b
}
// The pill that names a mark: beside the mark on the calmest free spot (above, below, right, left), never on
// another pill, so it covers as little of what the user reads as it can.
const __nameMark = (box, str, o = {}) => {
  if (str == null || String(str).trim() === '') { __marked.push(box); return null }
  const size = o.labelSize || __PILL_TEXT
  const [w, h] = __pillSize(String(str).trim(), size)
  const [bx, by, bw, bh] = box, gap = __pt(5)
  const spots = [[bx, by - h - gap], [bx, by + bh + gap], [bx + bw + gap, by + bh / 2 - h / 2], [bx - w - gap, by + bh / 2 - h / 2],
    [bx + bw - w, by - h - gap], [bx + bw - w, by + bh + gap],
    [bx + bw + gap, by - h - gap], [bx + bw + gap, by + bh + gap], [bx - w - gap, by - h - gap], [bx - w - gap, by + bh + gap],
    [bx, by - 2 * h - 2 * gap], [bx, by + bh + h + 2 * gap]]
  // a little further out too, for marks crowded by page text on every side
  const far = gap * 3 + h
  spots.push([bx, by - h - far], [bx, by + bh + far], [bx + bw + far, by + bh / 2 - h / 2], [bx - w - far, by + bh / 2 - h / 2])
  const others = __marked.filter(m => !(m[0] === bx && m[1] === by && m[2] === bw && m[3] === bh))
  const free = spots.map(p => [p[0], p[1], w, h]).filter(b => __onCanvas(b) && !__overlaps(b, __pills) && !__overlaps(b, others))
  __marked.push(box)
  // the calmest spot (least text and controls under it), nearer spots preferred: each step down the list must be
  // clearly calmer to win, and the far ring only when everything close sits on text
  const cost = (b, k) => __busyAt(b[0], b[1], w, h) + k * 0.004 + (k >= spots.length - 4 ? 0.02 : 0)
  let pick = free[0], pickCost = pick ? cost(pick, spots.findIndex(p => p[0] === pick[0] && p[1] === pick[1])) : Infinity
  free.forEach(b => { const c = cost(b, spots.findIndex(p => p[0] === b[0] && p[1] === b[1])); if (c < pickCost) { pick = b; pickCost = c } })
  if (!pick) pick = __clampBox([spots[0][0], spots[0][1], w, h])
  return label(pick[0], pick[1], str, {size})
}

// ---- Mate's ink: pointing at and marking the real things
// point(x, y, label): Mate's pen goes there and rings the exact spot, named in a pill.
const point = (x, y, name) => {
  const r = __pt(12)
  circle(x, y, r, __screenPen({tone: INK, role: 'point', label: name, wobble: 0.4})); dot(x, y, __pt(3), {tone: INK, fill: INK, role: 'point'})
  __nameMark([x - r, y - r, 2 * r, 2 * r], name)
}
// target/hover(x, y, w, h, label): the control itself, by its box like frame() (top-left, width, height).
// The app outlines the real control there and waits for the click (or the cursor resting on it).
// The older centre-and-radius form target(x, y, r, label) still works.
const __pointer = (role, a, b, c, d, e) => {
  const boxed = typeof d === 'number'
  const x = boxed ? a + c / 2 : a, y = boxed ? b + d / 2 : b
  const r = boxed ? min(c, d) / 2 + 6 : (c || 22)
  const name = boxed ? e : d
  const box = boxed ? [a, b, c, d] : null
  if (__hostPointers()) { dot(x, y, 0.1, {tone: __INK_LIGHT, fillAlpha: 0, outline: false, role, ring: r, box, label: name}); return }
  const p = __pt(4)
  if (boxed) { const pts = __roundRect(a - p, b - p, c + 2 * p, d + 2 * p, (d + 2 * p) / 2); line(pts.concat([pts[0]]), __screenPen({tone: INK, dash: __pt(8), dashGap: __pt(5), smooth: false, wobble: 0, role, label: name})) }
  else circle(x, y, r, __screenPen({tone: INK, role, label: name}))
  __nameMark(boxed ? [a - p, b - p, c + 2 * p, d + 2 * p] : [x - r, y - r, 2 * r, 2 * r], name)
}
const target = (a, b, c, d, e) => __pointer('target', a, b, c, d, e)
const hover = (a, b, c, d, e) => __pointer('hover', a, b, c, d, e)
// The outline of a box, following its shape: o.r is the corner radius in screenshot pixels (a pill-shaped search
// bar or button: half its height; a card: its corner). Without o.r, a wide short thing (a bar, a button, a field)
// is treated as a pill and anything else gets small rounded corners.
const __outlineRadius = (w, h, o, fallbackRadius) => max(0, min(typeof o.r === 'number' ? o.r : (w > 2.5 * h && h < __pt(60) ? h / 2 : fallbackRadius), w / 2, h / 2))
const __outline = (x, y, w, h, o, fallbackRadius) => __roundRect(x, y, w, h, __outlineRadius(w, h, o, fallbackRadius))
// frame(x, y, w, h, label, {r}): an AREA (a panel, a section, a group of fields, a search bar): a faint tint and a
// dashed outline in Mate's ink that follows its shape, named in a pill. In the app Mate's cursor drags it open
// from its top-left corner like a selection, as the old walkthrough's highlight did.
const frame = (x, y, w, h, name, o = {}) => {
  const p = __pt(3), bx = x - p, by = y - p, bw = w + 2 * p, bh = h + 2 * p
  const shape = typeof o.r === 'number' ? Object.assign({}, o, {r: o.r + p}) : o, radius = __outlineRadius(bw, bh, shape, __pt(8))
  const pts = __roundRect(bx, by, bw, bh, radius), marquee = __hostMarquee() ? [bx, by, bw, bh, radius] : null
  poly(pts, {fill: INK, fillAlpha: 0.07, outline: false, wash: false, role: 'frame', marquee})
  line(pts.concat([pts[0]]), __screenPen({tone: INK, dash: __pt(8), dashGap: __pt(5), smooth: false, wobble: 0, role: 'frame', label: name, marquee}))
  __nameMark([x - p, y - p, w + 2 * p, h + 2 * p], name)
}
// The corner radius of a ring's loop: a pill for a thin thing (a word, a number, a button, a bar), a round loop
// only for something small (an icon, an avatar, a face), and a hand-drawn rounded box for anything bigger. A full
// circle around a big near-square box (three rows of a list, a panel) swallowed half the screen around it and read
// as sloppy; a group of things wants a box around it, not a balloon.
const __ringRadius = (bw, bh) => {
  const short = min(bw, bh), long = max(bw, bh)
  if (short <= __pt(56)) return short / 2
  if (long <= __pt(120) && long < short * 1.4) return short / 2
  return max(__pt(8), min(__pt(18), short * 0.12))
}
// ring(x, y, w, h, label, {r}): a loop around ONE thing (a word, a number, an icon, a button), hugging its shape:
// a pill for a wide or thin thing, round for a small round or square thing, a hand-drawn rounded box for anything
// big. Named in a pill.
const ring = (x, y, w, h, name, o = {}) => {
  const p = __pt(4), bw = w + 2 * p, bh = h + 2 * p
  // the screen pen bends each long side once, like a hand going round it, and runs a little past where it started
  const pts = __roundRect(x - p, y - p, bw, bh, typeof o.r === 'number' ? o.r + p : __ringRadius(bw, bh))
  line(pts.concat([pts[0], pts[1]]), __screenPen({tone: INK, bow: 'pen', role: 'ring', label: name}))
  __nameMark([x - p, y - p, bw, bh], name)
}
const ink = (pts, o = {}) => {
  const opts = Object.assign({}, __SCREEN_PEN, o, {tone: o.tone || INK})
  delete opts.arrow; delete opts.curve; delete opts.label
  // the old walkthrough's arrowhead: a 16pt open chevron, π/7 either side, as heavy as the shaft
  if (o.arrow && !opts.head) opts.head = __pt(16)
  if (o.arrow && !opts.headAngle) opts.headAngle = PI / 7
  const mark = o.arrow ? arrow(pts, opts) : o.curve ? curve(pts, opts) : line(pts, opts)
  if (o.label) { const m = pts[round((pts.length - 1) / 2)] || pts[0], [w, h] = __pillSize(o.label, __PILL_TEXT); __nameMark([m[0] - w / 2, m[1] - h / 2, w, h], o.label) }
  return mark
}
const inkCircle = (x, y, r, o = {}) => circle(x, y, r, Object.assign({}, __SCREEN_PEN, o, {tone: o.tone || INK}))
// write(x, y, text): free words on calm space (a sketch, a diagram), in the ink that reads there.
const write = (x, y, str, o = {}) => {
  const s = o.size || 24, w = String(str).length * s * 0.5, x0 = o.anchor === 'middle' ? x - w / 2 : o.anchor === 'end' ? x - w : x
  text(x, y, str, Object.assign({style: 'hand', size: s}, o, {tone: o.tone || __inkAt(x0, y - s, w, s * 1.25)}))
}

// ---- Teaching on the content: the story drawn across the real things on screen
// num(x, y, n): a numbered badge (1, 2, 3 ...) in Mate's ink for the order of steps, events or ideas.
const num = (x, y, n, o = {}) => {
  const r = o.r || __pt(9)
  // On a card, a badge that starts a row lines up with the card's left edge like its heading and words: x is the
  // badge's middle, so a list numbered at the card's x had every badge half outside that edge (2026-10-10, Nilesh).
  const board = __boards.filter(b => x - r < b[0] && x >= b[0] - r - __pt(2) && y >= b[1] - r && y <= b[1] + b[3] + __pt(48)).pop()
  if (board) x = board[0] + r
  __pills.push([x - r, y - r, 2 * r, 2 * r])
  __gel(x - r, y - r, 2 * r, 2 * r, 'num')
  // Centred by the digit's ink, not its box: the gel's rim and drop shadow put the disc's visible middle a
  // little below y, a digit's ink is about 0.71 of the size tall, and a "1" sits left in its advance.
  const s = String(n), size = r * 1.15
  const dx = /^1+$/.test(s) ? size * 0.032 : 0
  text(x + dx, y + size * 0.355 + __pt(0.8), s, {style: 'ui', weight: 700, size, tone: __GEL_WORDS, anchor: 'middle', place: false, role: 'num'})
}
// underline(x, y, w): a thin pen line UNDER the words that matter. y is the bottom of the letters; the line always
// sits a little below it, so it never runs through the words.
const underline = (x, y, w, o = {}) => {
  const yy = y + __pt(3)
  return line([[x, yy], [x + w, yy]], Object.assign({}, __SCREEN_PEN, {size: __pt(3), smooth: false, wobble: 0.3}, o, {tone: o.tone || INK, role: 'underline'}))
}
// connect(a, b, {label}): a curved arrow from one real thing to another nearby (then -> next, cause -> effect).
const connect = (a, b, o = {}) => ink([a, b], Object.assign({arrow: true, bend: 0.2}, o, {role: 'connect'}))
// trace(pts, {straight, fill, label}): a closed outline around an irregular thing (a region on a map, a cluster, a
// passage). straight: true keeps its corners (an L-shaped panel, a group of controls): straight sides that each bend
// once, like a hand. fill: true tints it inside.
const trace = (pts, o = {}) => {
  const shape = o.straight ? {smooth: false, bow: 'pen', jitter: 2, wobble: 1} : {smooth: true}
  const fill = o.fill === true ? {fill: INK, fillAlpha: 0.18, wash: false} : {}
  const opts = Object.assign({}, __SCREEN_PEN, shape, fill, o, {tone: o.tone || INK, role: 'trace'})
  delete opts.straight; delete opts.label
  if (opts.fill === true) delete opts.fill
  const mark = poly(pts, opts)
  if (o.label && pts.length) { const xs = pts.map(q => q[0]), ys = pts.map(q => q[1]); __nameMark([min(...xs), min(...ys), max(...xs) - min(...xs), max(...ys) - min(...ys)], o.label) }
  return mark
}
// check(x, y) / cross(x, y): right and wrong, a tick or an X drawn by Mate's pen beside the thing.
const check = (x, y, s = __pt(12)) => line([[x - s * 0.6, y], [x - s * 0.15, y + s * 0.5], [x + s * 0.7, y - s * 0.6]], __screenPen({tone: INK, smooth: false, role: 'check'}))
const cross = (x, y, s = __pt(10)) => { line([[x - s / 2, y - s / 2], [x + s / 2, y + s / 2]], __screenPen({tone: INK, role: 'cross'})); line([[x + s / 2, y - s / 2], [x - s / 2, y + s / 2]], __screenPen({tone: INK, role: 'cross'})) }
// strike(x, y, w): a line through words that are wrong or out of date (y is the middle of the letters).
const strike = (x, y, w) => line([[x - 2, y], [x + w + 2, y]], __screenPen({tone: INK, size: __pt(3), smooth: false, role: 'strike'}))
// scroll(x, y, dir, label): "scroll here" (the action is a scroll, not a click): a double chevron arrow, named.
const scroll = (x, y, dir = 'down', name) => {
  const s = dir === 'up' ? -1 : 1, l = __pt(22), c = __pt(7)
  arrow([[x, y - s * l], [x, y + s * l]], __screenPen({tone: INK, head: __pt(10), headAngle: PI / 7, role: 'scroll'}))
  line([[x - c, y + s * (l * 0.45)], [x, y + s * (l * 0.45 + c)], [x + c, y + s * (l * 0.45)]], __screenPen({tone: INK, smooth: false, role: 'scroll'}))
  __nameMark([x - c, y - l, 2 * c, 2 * l], name == null ? 'scroll ' + (dir === 'up' ? 'up' : 'down') : name)
}
// cheer(x, y, face): one little Mate face in a pill, like the morning greeting's: '(^_^)v', '(^‿^)', '＼(^o^)／'.
// At most one per drawing, on its last beat, when something went right or clicked. Never on errors or warnings.
let __cheered = false
const cheer = (x, y, face = '(^_^)v') => {
  if (__cheered) return null
  __cheered = true
  // a little face, not a name for something on the screen (it stays when the screen changes)
  return label(x, y, face, {role: 'cheer'})
}
// photo(x, y, w, h, query, caption, {tilt, web, from, subtitle}): a REAL photo of a real person, place, landmark, animal, artwork or product,
// found by image search for `query` (2 to 4 words, the specific name: "eiffel tower", "marie curie"), printed as a
// polaroid taped to the screen: an even white border, a deep bottom strip with the name handwritten on it, a strip of
// tape across the top, the whole print tilted a little. x, y, w, h is the picture itself; the print grows around it.
const __photoPages = new Set()
const photo = (x, y, w, h, query, caption, o = {}) => {
  // {subtitle}: an optional short line under the name ("$1,099 · Sep 19", "CEO of NVIDIA"); the strip grows for it
  const subtitle = typeof o.subtitle === 'string' ? o.subtitle.trim() : ''
  // The name sits in the strip's middle; a subtitle goes just under it, a small gap apart, and the strip ends a little
  // below that (2026-10-09, Nilesh: the name and its subtitle sat far apart).
  const strip = max(w * 0.24, __pt(34)), size = min(max(strip * 0.42, 18), 30), small = max(16, round(size * 0.74))
  const captionAt = subtitle ? strip * 0.5 : strip * 0.62, subtitleAt = captionAt + size * 0.3 + 5 + small * 0.75
  const bottom = subtitle ? subtitleAt + small * 0.3 + strip * 0.2 : strip, side = max(__pt(7), w * 0.055), deg = o.tilt ?? -2;
  [x, y] = __clear(x - side, y - side, w + 2 * side, h + side + bottom); x += side; y += side
  const card = __rect(x - side, y - side, w + 2 * side, h + side + bottom)
  const centre = [x + w / 2, y + (h + bottom - side) / 2], turn = p => rotate(p, centre, deg * PI / 180)
  poly(card.map(p => turn([p[0] + __pt(1.5), p[1] + __pt(4)])), {fill: __SHADOW, fillAlpha: 0.2, outline: false, wash: false, role: 'paper', together: true})
  poly(card.map(turn), {fill: __PAPER_TONE.print, fillAlpha: 1, outline: false, wash: false, role: 'paper', together: true, snd: 'photo-drop'})
  const [px, py] = turn([x + w / 2, y + h / 2])
  // {web: true}: something new or in the news (a just-announced phone, an event): web image search only, since its
  // Wikipedia article, when there is one, shows an older version
  // {from: url}: a news story's photo, the article's own preview picture (the name searched on the web if it has none)
  // one article, one photo: a page given for two things (an event page for three products) would show its one
  // picture three times, so a page already used falls back to the name
  let from = typeof o.from === 'string' && /^https?:\/{2}/i.test(o.from) ? o.from.trim() : ''
  if (from && __photoPages.has(from)) from = ''
  if (from) __photoPages.add(from)
  const name = String(query || caption || '')
  // {noPeople: true}: a thing or a place, never people: the app passes over hits that show a person or a face
  const searched = (o.noPeople ? 'nopeople: ' : '') + (from ? 'page: ' + from + ' :: ' + name : (o.web ? 'web: ' : '') + name)
  image(px - w / 2, py - h / 2, w, h, {query: searched, r: __pt(1), rot: deg, role: 'photo'})
  const tapeW = min(w * 0.42, __pt(80)), tapeH = __pt(18), [tx, ty] = turn([x + w / 2, y - side])
  __tape(tx, ty - tapeH * 0.05, tapeW, tapeH, deg + 3)
  if (caption) {
    const [cx, cy] = turn([x + w / 2, y + h + captionAt])
    text(cx, cy, caption, {style: 'hand', size, tone: 'ink', anchor: 'middle', fit: [w, strip * 0.8], rot: deg, place: false, role: 'photo'})
  }
  if (subtitle) {
    const [sx, sy] = turn([x + w / 2, y + h + (caption ? subtitleAt : strip * 0.62)])
    text(sx, sy, subtitle, {style: 'hand', size: small, tone: 'grey', anchor: 'middle', fit: [w * 0.94, small * 2], rot: deg, place: false, role: 'photo'})
  }
  // the whole print, for tie()
  return {box: [x - side, y - side, w + 2 * side, h + side + bottom]}
}
// tie(from, to, {bend}): a curved arrow from a row on a card ([x, y], just past the end of its line) to the photo or
// card it is about (what photo() returns, or a box [x, y, w, h]), stopping just short of its nearest edge, so with
// several photos beside a list each one is plainly the picture of its row. It belongs to the drawing, not the
// screen: it stays when the screen changes, like the card and the photo.
const tie = (from, to, o = {}) => {
  const b = to && to.box ? to.box : to
  if (!Array.isArray(from) || !Array.isArray(b) || b.length < 4) return null
  const [bx, by, bw, bh] = b, cx = bx + bw / 2, cy = by + bh / 2, dx = from[0] - cx, dy = from[1] - cy
  if (!dx && !dy) return null
  const reach = Math.min(dx ? (bw / 2 + __pt(6)) / Math.abs(dx) : Infinity, dy ? (bh / 2 + __pt(6)) / Math.abs(dy) : Infinity)
  if (reach >= 1) return null
  // a gentle bow of the same depth whatever the length (a bend of 0.25 sagged a long arrow across the card)
  // tieTo: the engine moves the start to where the row's words really end when it draws the arrow
  // a tie belongs to the card and its photos, so it keeps the paper's felt pen (thinner, tapered, no glow)
  return ink([from, [cx + dx * reach, cy + dy * reach]], Object.assign({arrow: true, bend: __pt(22), size: __pt(2.5), taper: 1, glow: null, head: __pt(8), headAngle: 0.5}, o, {role: 'tie', tieTo: [bx, by, bw, bh, __pt(6), __pt(8)]}))
}

// source(x, y, domain, words, {size}): a credit for where something came from: the site's own icon, small and grey
// ("techcrunch.com"), then the words in grey ("TechCrunch · Oct 5"). x, y is where the line starts, y its baseline
// like text(). The icon comes through the app (the Worker's favicon proxy); a site without one leaves only the words.
const source = (x, y, domain, words, o = {}) => {
  const size = o.size || 15, icon = round(size * 0.95), gap = round(size * 0.4)
  const host = String(domain || '').trim().toLowerCase().replace(/^https?:\/{2}/, '').replace(/[\/?#].*$/, '').replace(/^www\./, '')
  if (host) image(x, y - size * 0.82, icon, icon, {query: 'favicon: ' + host, r: __pt(2), role: 'source'})
  return text(host ? x + icon + gap : x, y, words, Object.assign({size, tone: 'grey'}, o, {place: false}))
}

// sources(x, y, list, {size, maxWidth}): every site an answer's facts came from, in ONE quiet grey line ("Sources"
// then each site's small grey icon and name), at the bottom-left of the card. list is [[domain, name], ...]; a site
// listed twice (two stories from TechRadar) is shown once. y is the line's baseline; with maxWidth it wraps.
const sources = (x, y, list, o = {}) => {
  const size = o.size || 13, icon = round(size * 0.95), gap = round(size * 0.35), apart = round(size * 1.2)
  // the handwriting's average letter is about 0.4 of its size wide (no measuring here: marks are laid out later)
  const wide = str => String(str).length * size * 0.42
  const seen = new Set(), sites = []
  for (const entry of Array.isArray(list) ? list : []) {
    const [domain, name] = Array.isArray(entry) ? entry : [entry && entry.domain, entry && entry.name]
    const host = String(domain || '').trim().toLowerCase().replace(/^https?:\/{2}/, '').replace(/[\/?#].*$/, '').replace(/^www\./, '')
    if (!host || seen.has(host)) continue
    seen.add(host)
    sites.push([host, String(name || host)])
  }
  if (!sites.length) return null
  // On a whiteboard (paper()) the credits go in a footer under its writing area, a padding's gap below it, whatever line
  // the program gave; they say which window they belong to, so it grows down to hold them.
  // Given anywhere else (under the photos, at the screen's foot), they still belong to the answer's card: the nearest
  // whiteboard takes them (2026-10-09: credits written loose far below the card, over the user's app).
  const distanceTo = b => Math.hypot(max(b[0] - x, 0, x - (b[0] + b[2])), max(b[1] - y, 0, y - (b[1] + b[3])))
  const board = __boards.filter(b => x >= b[0] - __pt(30) && x <= b[0] + b[2] && y >= b[1] && y <= b[1] + b[3] + __pt(48)).pop()
    || __boards.slice().sort((a, b) => distanceTo(a) - distanceTo(b))[0]
  const onWindow = board ? [board[0], board[1]] : undefined
  // A typed answer told in the notch's chat: credits with no card to sit under aren't drawn (the chat names the
  // sites under the reply instead).
  if (!board && typeof __hideLoneSources !== 'undefined' && __hideLoneSources === true) return null
  if (board) {
    x = board[0]
    y = board[1] + board[3] + __WIN_PAD + size * 0.7
    o = Object.assign({}, o, {maxWidth: board[2]})
  }
  // No whiteboard (a spoken answer that searched the web): the line sits on its own small paper plate, so it reads on
  // any app under it. Grey words straight on the screen had come out grey on grey (2026-10-14). The plate is laid out
  // first (same wrapping as the words below), kept on the screen, and the words follow it.
  if (!board) {
    const padX = round(size * 0.9), padY = round(size * 0.6), lineStep = round(size * 1.6)
    let rowX = wide('Sources') + apart, rows = 1, widest = rowX
    for (const [, name] of sites) {
      const span = icon + gap + wide(name)
      if (o.maxWidth && rowX + span > o.maxWidth && rowX > 0) { rows += 1; rowX = 0 }
      rowX += span + apart
      widest = max(widest, rowX - apart)
    }
    const plate = __clampBox([x - padX, y - size * 0.95 - padY, widest + 2 * padX, size * 1.2 + (rows - 1) * lineStep + 2 * padY])
    x = plate[0] + padX
    y = plate[1] + padY + size * 0.95
    poly(__roundRect(plate[0], plate[1] + __pt(1), plate[2], plate[3], __pt(8)), {fill: __SHADOW, fillAlpha: 0.08, outline: false, wash: false, role: 'source', together: true})
    // sourcePlate: a card for layout and notes-only, but not a picture of its own (a drawing that is only its sources
    // isn't kept in the chat)
    poly(__roundRect(plate[0], plate[1], plate[2], plate[3], __pt(8)), {fill: __PAPER_TONE.card, fillAlpha: 1, outline: false, wash: false, role: 'paper', together: true, sourcePlate: true})
  }
  // sourceLine/sourceSize: the engine moves the whole line together under whatever ends up lowest on the card
  const line = onWindow ? {sourceLine: y, sourceSize: size} : {}
  text(x, y, 'Sources', Object.assign({size, tone: 'grey'}, {place: false, onWindow}, line))
  let cx = x + wide('Sources') + apart, cy = y
  for (const [host, name] of sites) {
    const span = icon + gap + wide(name)
    if (o.maxWidth && cx + span > x + o.maxWidth && cx > x) { cx = x; cy += round(size * 1.6) }
    image(cx, cy - size * 0.82, icon, icon, Object.assign({query: 'favicon: ' + host, r: __pt(2), role: 'source', onWindow}, line))
    text(cx + icon + gap, cy, name, Object.assign({size, tone: 'grey', place: false, onWindow}, line))
    cx += span + apart
  }
  return null
}

// ---- Doing it for the user (the app acts when the line is heard)
// typeText(x, y, text): put text into the field at x, y (the caret goes there): a reply, a formula, a command for a
// visible terminal prompt. Only when the user asked Mate to write or fill something in. Never presses Return.
// If the field refuses (a password field, an address bar), the app puts the text on the clipboard instead.
const typeText = (x, y, str) => dot(x, y, 0.1, {tone: __INK_LIGHT, fillAlpha: 0, outline: false, role: 'type', payload: String(str == null ? '' : str)})
// copyText(text): put exact text on the user's clipboard (a command, a code snippet, a long value) for them to paste.
const copyText = (str) => dot(2, 2, 0.1, {tone: __INK_LIGHT, fillAlpha: 0, outline: false, role: 'copy', payload: String(str == null ? '' : str)})
// openPage(url): open a web page (http or https) in the user's browser as this line is heard: a product page, a
// search, a map, a video. Only when the user asked for it to be opened. Last beat only: the browser comes to the
// front and the drawing leaves with the screen it was on.
const openPage = (url) => dot(4, 2, 0.1, {tone: __INK_LIGHT, fillAlpha: 0, outline: false, role: 'open', payload: String(url == null ? '' : url)})
// button(x, y, text, action): a real button for the user's likely NEXT step, top-left at x, y, on a card or calm space.
// button(photo(...) or a [x, y, w, h] box, text, action): the button sits centred on that photo's (or row's) bottom
// edge, half over it, like a price tag: "Buy on Lenovo" on the laptop's polaroid.
// action is {open: url} (opens a web page), {copy: text} (puts text on their clipboard), {ask: words} (asks Mate
// that, as if they said it) or {handOff: {task, label, mate | newMate}} (gives the work to a Mate). It appears
// as its line is heard and stays with the drawing; the app draws it and runs the action when it is pressed.
const __BUTTON_TEXT = __pt(13)
// A button written onto the drawing itself (a planet, a label, an arrow) moves to the nearest spot clear of everything
// drawn so far and of the pills, staying near where it was asked for (2026-10-09: "Explore moons" sat on a card's picture).
const __buttonClearOfInk = b => {
  const ink = typeof __inkBoxes === 'function' ? __inkBoxes() : []
  const blocked = t => __overlaps(t, ink) || __overlaps(t, __pills)
  if (!blocked(b)) return b
  const stepY = b[3] + __pt(6), stepX = b[2] / 2 + __pt(6), tries = []
  for (let k = 1; k <= 8; k++) tries.push([b[0], b[1] + k * stepY], [b[0], b[1] - k * stepY], [b[0] + k * stepX, b[1]], [b[0] - k * stepX, b[1]],
    [b[0] + k * stepX, b[1] + k * stepY], [b[0] - k * stepX, b[1] + k * stepY])
  const free = tries.map(p => [p[0], p[1], b[2], b[3]]).filter(t => __onCanvas(t) && !blocked(t))
    .sort((p, q) => Math.hypot(p[0] - b[0], p[1] - b[1]) - Math.hypot(q[0] - b[0], q[1] - b[1]))
  return free[0] || b
}
const button = (x, y, str, action = {}) => {
  // the anchored form: button(photoOrBox, text, action)
  let anchor = null
  if (x && typeof x === 'object') { anchor = Array.isArray(x) ? x : x.box; action = str || {}; str = y }
  str = String(str == null ? '' : str).trim()
  if (!str || !action || typeof action !== 'object') return null
  const kind = action.open ? 'open' : action.copy ? 'copy' : action.ask ? 'ask' : action.handOff ? 'handoff' : action.card ? 'card' : null
  if (!kind) return null
  const [pw, h] = __pillSize(str, __BUTTON_TEXT)
  const w = round(pw + __BUTTON_TEXT * 1.6), hh = round(h * 1.25)
  const b = Array.isArray(anchor) && anchor.length >= 4
    ? __clampBox([anchor[0] + anchor[2] / 2 - w / 2, anchor[1] + anchor[3] - hh / 2, w, hh])
    : __buttonClearOfInk(__clampBox([x, y, w, hh]))
  __pills.push(b)
  const value = kind === 'handoff' ? action.handOff : action[kind]
  dot(b[0], b[1], 0.1, {tone: __INK_LIGHT, fillAlpha: 0, outline: false, role: 'button', box: b, payload: JSON.stringify({text: str, kind, value})})
  // The app draws the real, pressable button over this spot; a test render without it draws it here.
  if (typeof __hostDrawsButtons === 'undefined' || !__hostDrawsButtons) {
    __gel(b[0], b[1], w, hh, 'button')
    text(b[0] + w / 2, b[1] + hh * 0.66, str + (kind === 'open' ? '  ↗' : ''), {style: 'ui', weight: 600, size: __BUTTON_TEXT, tone: __GEL_WORDS, anchor: 'middle', place: false, role: 'button'})
  }
  return b
}
// handOff({task, label, mate}) or handOff({task, label, newMate: {name, role, description}}): give work to one of the
// user's Mates (their agents; the request lists them): the app starts it as this line is heard. Draws nothing.
const handOff = (o) => dot(6, 2, 0.1, {tone: __INK_LIGHT, fillAlpha: 0, outline: false, role: 'handoff', payload: JSON.stringify(o && typeof o === 'object' ? o : {task: String(o == null ? '' : o)})})
// tourJob({title, pitch, task, label, color, newMate}): the drawn welcome tour only. Draws nothing: the app shows the
// job as one of its own cards beside the drawing when its line is heard, and at the end plugs the cards into the notch.
// tuckJobs(): the drawn welcome tour only. Draws nothing: in the beat that says the jobs go into their notch, the app
// plugs the job cards into the notch as that line is heard.
const tuckJobs = () => dot(6, 2, 0.1, {tone: __INK_LIGHT, fillAlpha: 0, outline: false, role: 'tourtuck', payload: 'tuck'})
// showNotch(): the drawn welcome tour only. Draws nothing: as this line is heard the app opens their notch on Home (the
// jobs just tucked in wait there). showNotch({apps: true}) in a later beat pops a few apps into its apps pill as that
// line is heard. The notch closes with fadeAway().
const showNotch = (o) => dot(6, 2, 0.1, {tone: __INK_LIGHT, fillAlpha: 0, outline: false, role: 'tournotch', payload: o && o.apps ? 'apps' : 'notch'})
// fadeAway(): the drawn welcome tour only. Draws nothing: as this line is heard the app closes the notch if it's open
// and fades the whole drawing away, so the last line lands on a clean screen. Draw nothing after it.
const fadeAway = () => dot(6, 2, 0.1, {tone: __INK_LIGHT, fillAlpha: 0, outline: false, role: 'tourfade', payload: 'fade'})
// nextQuestions([[text, plan], ...]): the drawn welcome tour only. Draws nothing: once the voice has finished, the app pops
// these three pills in one by one in the middle of the screen (text: what the pill says and sends; plan: never shown, how
// the brain means to answer it, handed back to it when the pill is tapped).
const nextQuestions = (list) => dot(6, 2, 0.1, {tone: __INK_LIGHT, fillAlpha: 0, outline: false, role: 'tourasks',
  payload: JSON.stringify((Array.isArray(list) ? list : []).map(q => Array.isArray(q) ? {text: String(q[0] || ''), plan: String(q[1] || '')} : (q && typeof q === 'object' ? {text: String(q.text || ''), plan: String(q.plan || q.ask || '')} : {text: String(q || ''), plan: ''})).filter(q => q.text))})
const tourJob = (o) => dot(6, 2, 0.1, {tone: __INK_LIGHT, fillAlpha: 0, outline: false, role: 'tourjob', payload: JSON.stringify(o && typeof o === 'object' ? o : {title: String(o == null ? '' : o)})})
// sfx(name): a sound for the moment the NEXT mark lands, when the meaning earns one: 'ding' (the right answer, the
// winner), 'nope' (the wrong option, the trap), 'stamp' (the verdict, the big number), 'tada' (the finished picture),
// 'sparkle' (the insight), 'whoosh' (a jump in time, before and after), 'boing' (something playful). Every mark already
// makes its own quiet drawing sound; these are extra. Draws nothing.
const sfx = (name) => dot(8, 2, 0.1, {tone: __INK_LIGHT, fillAlpha: 0, outline: false, role: 'sfx', payload: String(name == null ? '' : name)})
// ---- The walkthrough (the app reads these from the program; they draw nothing)
// task(label): the short name of the task this drawing serves, e.g. task("export as MP4"). First line of a how-to.
const task = () => {}
// waitForUser(): the next step is manual work the app cannot see finish (typing, dragging, picking): the walkthrough
// stays open and goes on when the user says "continue". Instead of a target, never with one.
const waitForUser = () => {}
// onScreen(n): first line only, when the drawing goes on display n instead of the default one.
const onScreen = () => {}

// tag(x, y, text): the same name pill as label() (older programs).
const tag = (x, y, str) => label(x, y, str)

// ---- Mate's paper (the ReferenceRenderer asset library)
const __tilt = (pts, deg) => { const b = __boxOf(pts), c = [b[0] + b[2] / 2, b[1] + b[3] / 2]; return pts.map(p => rotate(p, c, deg * PI / 180)) }
// A sticky lies a touch askew with a soft shadow, flat (2026-10-09: dead straight read like a chart tool; the windows
// that replaced paper, receipts and clippings stay straight).
const __sheet = (pts, fill, deg, snd = 'paper-place') => {
  poly(__tilt(pts.map(p => [p[0], p[1] + 3]), deg), {fill: 'ink', fillAlpha: 0.07, outline: false, wash: false, role: 'paper', together: true})
  poly(__tilt(pts.map(p => [p[0], p[1] + 1]), deg), {fill: 'ink', fillAlpha: 0.08, outline: false, wash: false, role: 'paper', together: true})
  poly(__tilt(pts, deg), {fill, fillAlpha: 1, outline: false, wash: false, role: 'paper', snd})
}
const __rect = (x, y, w, h) => [[x, y], [x + w, y], [x + w, y + h], [x, y + h]]
// Mate's tape: every taped card (sticky, clipping, polaroid) wears a strip of the user's cursor colour, the light
// gel tone the name pills use, so paper reads as Mate's own like the marks on the screen. Torn ends, translucent.
const __tape = (cx, cy, w, h, deg) => {
  if (__CLEAN_PAPER) return
  const x = cx - w / 2, y = cy - h / 2, n = 4
  const ends = []
  for (let i = 0; i <= n; i++) ends.push([x + (i % 2 ? 2.5 : 0), y + i * h / n])
  const right = []
  for (let i = 0; i <= n; i++) right.push([x + w - (i % 2 ? 0 : 2.5), y + h - i * h / n])
  poly(__tilt([...ends.reverse(), ...right.reverse()], deg), {fill: __GEL.mid, fillAlpha: 0.8, outline: false, wash: false, role: 'paper', snd: 'tape'})
}
// Words that start at the top of a sheet's writing area. The engine centres fit text that wraps on its y
// (it lifts the first line by half the extra lines, sized before any shrink), which put a long note's words
// on the tape or above the paper. baseline 'alphabetic' (the same baseline as 'auto') skips that lift, so
// the first line sits on y and the rest go down into the fit box, as with one line.
const __TOP = 'alphabetic'
// Paper never lands on a 3D figure: it steps aside to the nearest free spot beside it.
const __clear = (x, y, w, h) => (typeof clearOfFigures === 'function' ? clearOfFigures(x, y, w, h) : [x, y])
const sticky = (x, y, str, color = 'butter', o = {}) => {
  const s = o.size || 170, deg = o.tilt ?? -2, c = __PAPER[color] || color;
  [x, y] = __clear(x, y, s, s)
  __sheet([[x, y], [x + s, y], [x + s, y + s - 24], [x + s - 24, y + s], [x, y + s]], c, deg, 'sticky-press')
  poly(__tilt([[x + s - 24, y + s], [x + s, y + s - 24], [x + s - 20, y + s - 20]], deg), {fill: 'ink', fillAlpha: 0.12, outline: false})
  __tape(x + s * 0.5, y + 1, s * 0.4, 20, deg)
  text(x + 16, y + 40, str, {style: 'hand', size: o.textSize || 22, tone: 'ink', fit: [s - 32, s - 50], rot: deg, baseline: __TOP})
}
// ---- Small hand-drawn icons for the welcome tour's job windows (a job with no real photo)
const __jobPen = {tone: 'ink', size: 2.4, smooth: false}
const __JOB_ICONS = {
  search: (cx, cy, s) => { circle(cx - s * 0.12, cy - s * 0.12, s * 0.3, __jobPen); line([[cx + s * 0.1, cy + s * 0.1], [cx + s * 0.42, cy + s * 0.42]], Object.assign({}, __jobPen, {size: 3.2})) },
  reviews: (cx, cy, s) => {
    const star = (x0, y0, r) => poly(range(10).map(k => polar(x0, y0, k % 2 ? r * 0.45 : r, -PI / 2 + k * PI / 5)), {tone: 'ink', size: 1.8, fill: 'sun', fillAlpha: 0.9})
    star(cx - s * 0.28, cy - s * 0.28, s * 0.17); star(cx + s * 0.05, cy - s * 0.38, s * 0.17)
    circle(cx + s * 0.02, cy + s * 0.08, s * 0.24, __jobPen); line([[cx + s * 0.2, cy + s * 0.26], [cx + s * 0.44, cy + s * 0.48]], Object.assign({}, __jobPen, {size: 3.2}))
  },
  page: (cx, cy, s) => {
    rect(cx - s * 0.48, cy - s * 0.36, s * 0.96, s * 0.72, Object.assign({}, __jobPen, {fill: 'white', fillAlpha: 0.9}))
    line([[cx - s * 0.48, cy - s * 0.18], [cx + s * 0.48, cy - s * 0.18]], __jobPen)
    rect(cx - s * 0.32, cy - s * 0.04, s * 0.36, s * 0.22, {tone: 'ink', size: 1.6, fill: 'sky', fillAlpha: 0.8})
    line([[cx + s * 0.12, cy], [cx + s * 0.34, cy]], {tone: 'grey', size: 2, smooth: false}); line([[cx + s * 0.12, cy + s * 0.12], [cx + s * 0.28, cy + s * 0.12]], {tone: 'grey', size: 2, smooth: false})
  },
  people: (cx, cy, s) => {
    for (const [dx, k] of [[-0.2, 1], [0.22, 0.85]]) {
      circle(cx + dx * s, cy - s * 0.2 * k, s * 0.13 * k, Object.assign({}, __jobPen, {fill: 'peach', fillAlpha: 0.9}))
      curve([[cx + dx * s - s * 0.22 * k, cy + s * 0.34], [cx + dx * s, cy + s * 0.02], [cx + dx * s + s * 0.22 * k, cy + s * 0.34]], {tone: 'ink', size: 2.4})
    }
  },
  mail: (cx, cy, s) => {
    rect(cx - s * 0.46, cy - s * 0.3, s * 0.92, s * 0.6, Object.assign({}, __jobPen, {fill: 'white', fillAlpha: 0.9}))
    line([[cx - s * 0.46, cy - s * 0.3], [cx, cy + s * 0.06], [cx + s * 0.46, cy - s * 0.3]], __jobPen)
    line([[cx + s * 0.26, cy - s * 0.52], [cx + s * 0.5, cy - s * 0.52], [cx + s * 0.4, cy - s * 0.42]], {tone: 'ink', size: 1.8, smooth: false})
  },
  chart: (cx, cy, s) => {
    line([[cx - s * 0.45, cy - s * 0.4], [cx - s * 0.45, cy + s * 0.38], [cx + s * 0.46, cy + s * 0.38]], __jobPen)
    ;[[0.22, 'sky'], [0.42, 'mint'], [0.66, 'leaf']].forEach(([hk, c], k) => rect(cx - s * 0.32 + k * s * 0.26, cy + s * 0.38 - s * hk, s * 0.18, s * hk, {tone: 'ink', size: 1.6, fill: c, fillAlpha: 0.85}))
  },
  list: (cx, cy, s) => {
    for (let k = 0; k < 3; k++) {
      const y0 = cy - s * 0.3 + k * s * 0.3
      rect(cx - s * 0.44, y0 - s * 0.09, s * 0.18, s * 0.18, {tone: 'ink', size: 1.8})
      line([[cx - s * 0.16, y0], [cx + s * (0.44 - k * 0.1), y0]], {tone: 'grey', size: 2.2, smooth: false})
    }
    line([[cx - s * 0.42, cy - s * 0.31], [cx - s * 0.36, cy - s * 0.25], [cx - s * 0.24, cy - s * 0.42]], {tone: 'leaf', size: 2.4, smooth: false})
  },
  map: (cx, cy, s) => {
    poly([[cx, cy + s * 0.46], [cx - s * 0.3, cy - s * 0.02], [cx - s * 0.3, cy - s * 0.2], [cx - s * 0.18, cy - s * 0.4], [cx, cy - s * 0.46], [cx + s * 0.18, cy - s * 0.4], [cx + s * 0.3, cy - s * 0.2], [cx + s * 0.3, cy - s * 0.02]], {tone: 'ink', size: 2.2, fill: 'coral', fillAlpha: 0.85, smooth: true})
    circle(cx, cy - s * 0.16, s * 0.1, {tone: 'ink', size: 1.8, fill: 'white', fillAlpha: 1})
  },
  code: (cx, cy, s) => {
    line([[cx - s * 0.18, cy - s * 0.3], [cx - s * 0.46, cy], [cx - s * 0.18, cy + s * 0.3]], __jobPen)
    line([[cx + s * 0.18, cy - s * 0.3], [cx + s * 0.46, cy], [cx + s * 0.18, cy + s * 0.3]], __jobPen)
    line([[cx + s * 0.08, cy - s * 0.38], [cx - s * 0.08, cy + s * 0.38]], {tone: 'ink', size: 2, smooth: false})
  },
  calendar: (cx, cy, s) => {
    rect(cx - s * 0.42, cy - s * 0.32, s * 0.84, s * 0.74, Object.assign({}, __jobPen, {fill: 'white', fillAlpha: 0.9}))
    rect(cx - s * 0.42, cy - s * 0.32, s * 0.84, s * 0.2, {tone: 'ink', size: 2, fill: 'coral', fillAlpha: 0.85})
    for (const [dx, dy] of [[-0.2, 0.06], [0.04, 0.06], [0.26, 0.06], [-0.2, 0.24], [0.04, 0.24]]) dot(cx + dx * s, cy + dy * s, 2.2, {tone: 'ink'})
  },
  chat: (cx, cy, s) => {
    poly([[cx - s * 0.44, cy - s * 0.32], [cx + s * 0.44, cy - s * 0.32], [cx + s * 0.44, cy + s * 0.18], [cx - s * 0.1, cy + s * 0.18], [cx - s * 0.3, cy + s * 0.38], [cx - s * 0.26, cy + s * 0.18], [cx - s * 0.44, cy + s * 0.18]], Object.assign({}, __jobPen, {fill: 'white', fillAlpha: 0.9}))
    line([[cx - s * 0.28, cy - s * 0.12], [cx + s * 0.28, cy - s * 0.12]], {tone: 'grey', size: 2, smooth: false}); line([[cx - s * 0.28, cy + s * 0.02], [cx + s * 0.12, cy + s * 0.02]], {tone: 'grey', size: 2, smooth: false})
  },
  spark: (cx, cy, s) => poly(range(8).map(k => polar(cx, cy, k % 2 ? s * 0.16 : s * 0.46, -PI / 2 + k * PI / 4)), {tone: 'ink', size: 2, fill: 'sun', fillAlpha: 0.9}),
}
// spotlight(x, y, w, h): the lights go down on the whole screen except a soft-cornered opening around one real thing
// (its box), like a stage: everything drawn after it reads on any screen. spotlight() with no box dims it all. Write it first, in the first beat, with the
// ring on that thing. Taught only by the drawn welcome tour's brief for now.
const spotlight = (x, y, w, h, o = {}) => {
  // spotlight() with no box: the whole screen dims (nothing on it relates to them)
  if (typeof x === 'object' && x) { o = x; x = undefined }
  const open = isFinite(x) && isFinite(y) && w > 0 && h > 0
  const pad = o.pad ?? 10, r = o.r ?? 14
  const hx = open ? x - pad : 0, hy = open ? y - pad : 0, hw = open ? w + 2 * pad : 0, hh = open ? h + 2 * pad : 0
  // the screen clockwise, then the opening the other way round: the opening stays clear under the non-zero rule
  const hole = open ? __roundRect(hx, hy, hw, hh, r).slice().reverse() : []
  const d = `M0,0 L${W},0 L${W},${H} L0,${H} Z` + (open ? ' M' + hole.map(p => `${p[0].toFixed(1)},${p[1].toFixed(1)}`).join(' L') + ' Z' : '')
  // role 'stage', not 'paper': a full-screen card would take every click as a drag
  path(d, {fill: '#0B0D11', fillAlpha: o.alpha ?? 0.84, outline: false, wash: false, role: 'stage', snd: 'whoosh'})
  return {box: [hx, hy, hw, hh]}
}
// ---- The welcome tour's pieces (2026-10-17). Taught only by the drawn welcome tour's brief for now
// (OneBrain/CompanionManager+DrawnOnboardingTour.swift), not the drawing skill.
// jobTicket(x, y, {title, steps, time, photo, web, icon, color, button, handOff}): one job you can do for the user, as a
// little hand-drawn ticket, top-left at x, y. A pastel stub on the left holds a real photo of what the job is about
// (photo: one specific named thing as its Wikipedia or product page names it, never a category or topic; web: true for something new or trending) or else a hand-drawn
// icon, and the time it takes; a perforated edge; the headline is what they GET (title: 2 to 5 words, "Your 8-bar
// mashup"); under it one quiet line of the work you'll do (steps: three short lowercase verb phrases, joined as "I'll
// listen to both · match the tempo · pick the lead"); and its button docked on the ticket's bottom edge (button: 2 to 4
// words starting with a verb, defaults to the title; handOff: {task, label, newMate | mate}). About 310 x 122, plus
// about 18 for its button. icon: 'reviews' | 'page' | 'people' | 'mail' | 'chart' | 'search' | 'list' | 'map' |
// 'code' | 'calendar' | 'chat' | 'spark'. color: mint | sky | peach | lilac | butter. Returns {box, button}.
const jobTicket = (x, y, o = {}) => {
  const steps = (Array.isArray(o.steps) ? o.steps : []).map(t => String(t || '').trim()).filter(Boolean).slice(0, 3)
  const w = o.w || 310, h = o.h || 122, stub = 92, r = 12
  const tint = __PAPER[o.color] || o.color || __PAPER.mint
  ;[x, y] = __clear(x, y, w, h + 20)
  const card = __roundRect(x, y, w, h, r)
  // soft shadow, the ticket, its pastel stub (rounded on the left only) and a hand-drawn edge round the whole thing
  poly(card.map(p => [p[0] + 1, p[1] + 5]), {fill: 'ink', fillAlpha: 0.12, outline: false, wash: false, role: 'paper', together: true})
  poly(card, {fill: '#FFFDF7', fillAlpha: 1, outline: false, wash: false, role: 'paper', snd: 'paper-place'})
  const stubPts = [[x + stub, y]]
  for (let k = 0; k <= 6; k++) { const a = -PI / 2 - k * PI / 12; stubPts.push([x + r + cos(a) * r, y + r + sin(a) * r]) }
  for (let k = 0; k <= 6; k++) { const a = PI - k * PI / 12; stubPts.push([x + r + cos(a) * r, y + h - r + sin(a) * r]) }
  stubPts.push([x + stub, y + h])
  poly(stubPts, {fill: tint, fillAlpha: 1, outline: false, wash: false, role: 'paper', together: true})
  poly(card, {tone: 'ink', size: 1.8, fillAlpha: 0, wash: false, role: 'paper'})
  // the perforation: a dashed tear line
  line([[x + stub, y + 10], [x + stub, y + h - 10]], {tone: 'grey', size: 1.6, dash: true, smooth: false})
  // the stub: a real photo of what the job is about (a print with a white border), else the hand-drawn icon; the time under it
  if (o.photo) {
    const ps = stub - 26, px = x + 13, py = y + 10
    poly(__rect(px - 3, py - 3, ps + 6, ps + 6).map(p => [p[0] + 1, p[1] + 2]), {fill: 'ink', fillAlpha: 0.14, outline: false, wash: false, role: 'paper', together: true})
    poly(__rect(px - 3, py - 3, ps + 6, ps + 6), {fill: '#FFFFFF', fillAlpha: 1, outline: false, wash: false, role: 'paper', snd: 'photo-drop'})
    image(px, py, ps, ps, {query: (o.web ? 'web: ' : '') + String(o.photo), r: 2, rot: 0, role: 'photo'})
  } else {
    ;(__JOB_ICONS[o.icon] || __JOB_ICONS.spark)(x + stub / 2, y + h / 2 - 12, 40)
  }
  if (o.time) text(x + stub / 2, y + h - 12, String(o.time), {style: 'caps', size: 12, tone: 'ink', anchor: 'middle', fit: [stub - 10, 16], place: false})
  // What they get is the headline, and the work under it is plainly yours, in one quiet line. The numbered steps and
  // an empty checkbox read as a to-do list for THEM (2026-10-17, Farza: "they feel like a lotta work for me").
  const bx = x + stub + 18, bw = w - stub - 30
  text(bx, y + 40, String(o.title || ''), {style: 'title', size: 22, tone: 'ink', fit: [bw, 30], place: false})
  if (steps.length) {
    // a long line shrank to tiny type: past about 52 characters the third step goes
    let shown = steps.map(t => t.replace(/[.]+$/, ''))
    while (shown.length > 1 && ("I'll " + shown.join(' \u00B7 ')).length > 52) shown = shown.slice(0, -1)
    text(bx, y + 62, "I'll " + shown.join(' \u00B7 '), {style: 'hand', size: 16, tone: 'grey', fit: [bw, 40], baseline: __TOP, place: false})
  }
  const b = o.handOff ? button([x + stub, y, w - stub, h], String(o.button || o.title || 'Start'), {handOff: o.handOff}) : null
  return {box: [x, y, w, h], button: b}
}
// dreamMedal(x, y, big, {caption}): their goal as it will look when it comes true: a glowing medallion with rays, the
// goal's short form big in the middle (big: 1 to 6 characters, "$1", "A+", "10K"), and a ribbon under it with the rest
// (caption: 2 to 5 words, "from a stranger"). x, y is the medallion's centre; about 210 x 240 in all. Returns {box}.
const dreamMedal = (x, y, big, o = {}) => {
  const R = 62, gold = o.color || 'sun'
  ;[x, y] = (() => { const c = __clear(x - R - 42, y - R - 42, 2 * R + 84, 2 * R + 122); return [c[0] + R + 42, c[1] + R + 42] })()
  // a pale cream halo (it stays bright on a dark screen), its dashed rim, and the rays
  circle(x, y, R + 42, {fill: '#FFF6D6', fillAlpha: 0.95, outline: false, wash: false, role: 'paper'})
  circle(x, y, R + 42, {tone: 'sun', size: 1.6, fillAlpha: 0, dash: true})
  path(range(16).map(k => { const a = k * PI / 8, p0 = polar(x, y, R + 12, a), p1 = polar(x, y, R + (k % 2 ? 26 : 36), a); return `M${p0[0]},${p0[1]} L${p1[0]},${p1[1]}` }).join(' '), {tone: 'sun', size: 3})
  // the medallion: a gold coin with an inner ring
  circle(x + 2, y + 5, R, {fill: 'ink', fillAlpha: 0.16, outline: false, wash: false, together: true})
  circle(x, y, R, {fill: gold, fillAlpha: 1, tone: 'ink', size: 2.4, wash: false, snd: 'sparkle'})
  circle(x, y, R - 10, {tone: '#B7791F', size: 2, fillAlpha: 0})
  const s = String(big || '').trim()
  text(x, y + (s.length <= 2 ? 18 : 12), s, {style: 'title', size: s.length <= 2 ? 54 : s.length <= 4 ? 40 : 30, tone: 'ink', anchor: 'middle', fit: [2 * R - 24, 70], place: false})
  // the ribbon with the rest of the goal
  if (o.caption) {
    const cw = max(150, String(o.caption).length * 9 + 50), ry = y + R + 10, rh = 34
    poly([[x - cw / 2 - 14, ry + 4], [x - cw / 2, ry], [x + cw / 2, ry], [x + cw / 2 + 14, ry + 4], [x + cw / 2, ry + rh / 2 + 2], [x + cw / 2 + 14, ry + rh], [x - cw / 2 - 14, ry + rh], [x - cw / 2, ry + rh / 2 + 2]],
      {fill: 'coral', fillAlpha: 1, tone: 'ink', size: 2, wash: false, smooth: false})
    text(x, ry + rh / 2 + 7, String(o.caption), {style: 'hand', size: 19, tone: '#FFFFFF', anchor: 'middle', fit: [cw - 10, rh - 6], place: false})
  }
  return {box: [x - R - 42, y - R - 42, 2 * R + 84, 2 * R + 122]}
}
// Farza's clean paper (2026-10-08) turned tape off; it is back on stickies and photo prints (2026-10-09, Nilesh:
// they looked unfinished without it). The windows never had tape. __GRID is the old chart paper's colours.
const __CLEAN_PAPER = false
const __GRID = {fill: '#F8F8F7', line: '#E7E7EA'}
// ---- Mate's windows (the ReferenceRenderer landing page's little Mac windows)
// Every explanation card is a small window: a 1pt dark frame fading down its sides, rounded corners, a soft shadow, a
// title bar (the landing page's grey with a wash of the user's cursor colour) holding the three buttons and an
// optional small grey title, and a board in the muted cursor-colour paper tone: the faint chart grid, light dots, or
// plain. The box a program gives is the WRITING AREA: the window grows around it by a padding on every side, and its
// title bar sits above that, so words placed at the box's edge still sit well inside the window.
// The app paints the window itself (crisp at any size, real buttons: close and full screen, shown while the pointer is
// on the card); anywhere else (a test render) it is built from plain shapes.
const __BOARDS = {dots: 1, grid: 1, plain: 1}
// The title bar's wash of the cursor colour, and the board: the matte paper tone of the cursor colour (cool blue-grey
// for blue, cream for yellow). It was halved toward white on 2026-10-08; the full tint is back (2026-10-09, Nilesh).
const __WASHES = {'#D4A017': ['#FEEA3D', 0.12], '#3380FF': ['#0F7FFF', 0.08], '#FF4C4C': ['#FF5A4C', 0.08], '#26C281': ['#26C281', 0.1]}
const __WASH = __WASHES[INK] || [INK, 0.09]
const __WIN_BOARD = __PAPER.white
const __WIN_HEADER = __pt(28), __WIN_PAD = __pt(24), __WIN_RADIUS = __pt(10)
const __hostWindows = () => typeof __hostDrawsWindows !== 'undefined' && __hostDrawsWindows === true
// The outline of a box with only its top corners rounded (a title bar).
const __topRoundRect = (x, y, w, h, r) => {
  r = max(0, min(r, w / 2, h))
  const pts = [], arc = (cx, cy, a0) => { for (let k = 0; k <= 6; k++) { const a = a0 + k * PI / 12; pts.push([cx + cos(a) * r, cy + sin(a) * r]) } }
  arc(x + w - r, y + r, -PI / 2); pts.push([x + w, y + h], [x, y + h]); arc(x + r, y + r, PI)
  return pts
}
// Whiteboard windows drawn so far (their writing areas): sources() puts its credits under them, and the window grows
// to hold them (the engine fits a window to what is drawn on it), so a card without sources has no empty footer.
const __boards = []
const __win = (x, y, w, h, o = {}) => {
  const head = __WIN_HEADER, pad = __WIN_PAD
  // kept on the screen: a box placed hard against its top or left edge loses some of the margin there instead
  const X = max(2, x - pad), Y = max(2, y - pad - head), Wd = x + w + pad - X, Hd = y + h + pad - Y
  if (o.footer) __boards.push([x, y, w, h])
  const title = o.title == null ? '' : String(o.title).replace(/\s+/g, ' ').trim().slice(0, 60)
  const board = __BOARDS[o.board] ? o.board : o.grid === false ? 'plain' : 'grid'
  const bg = o.bg || __WIN_BOARD, snd = o.snd || 'paper-place'
  if (__hostWindows()) {
    __window(X, Y, Wd, Hd, {header: head, pad, inner: [x, y, w, h], title, board, bg, tint: __WASH[0], tintAlpha: __WASH[1], role: 'paper', snd})
    return
  }
  const r = __WIN_RADIUS, sheet = (pts, fill, fillAlpha, extra) => poly(pts, Object.assign({fill, fillAlpha, outline: false, wash: false, role: 'paper', together: true}, extra))
  sheet(__roundRect(X, Y + __pt(8), Wd, Hd, r), __SHADOW, 0.1)
  sheet(__roundRect(X - __pt(1), Y - __pt(1), Wd + __pt(2), Hd + __pt(2), r + __pt(1)), '#2A2A2C', 0.5)
  sheet(__roundRect(X, Y, Wd, Hd, r), bg, 1, {snd})
  sheet(__topRoundRect(X, Y, Wd, head, r), '#E3E2E4', 1)
  sheet(__topRoundRect(X, Y, Wd, head, r), __WASH[0], __WASH[1])
  sheet(__rect(X, Y + head - __pt(0.5), Wd, __pt(0.5)), '#000000', 0.1)
  ;['#FF736A', '#19C332'].forEach((c, k) => dot(X + __pt(16 + 20 * k), Y + head / 2, __pt(6), {tone: c, fill: c, role: 'paper'}))
  if (title) text(X + Wd / 2, Y + head / 2 + __pt(4.5), title.toLowerCase(), {style: 'ui', weight: 600, size: __pt(13), tone: 'grey', anchor: 'middle', fit: [Wd - __pt(150), head], knockout: false})
}

// A 3D figure alone on busy screen stands in a window too (a figure placed on a paper() card stands on that card
// instead): the engine calls this before it builds the figure. Only where the app draws windows (elsewhere the figure
// keeps the stage's own paper). It is an ordinary card, so sources() goes under it.
if (__hostWindows()) __card3d = (x, y, w, h, o = {}) => __win(x, y, w, h, {title: o.title, board: o.board || 'plain', footer: true})

// receipt(x, y, title, items): a short list in a window, its title on top of the board.
const receipt = (x, y, title, items = [], o = {}) => {
  const w = o.w || 240, lh = 30, h = 48 + items.length * lh;
  [x, y] = __clear(x, y, w, h)
  __win(x, y, w, h, {board: o.board || 'plain', title: o.title})
  text(x, y + 24, title, {style: 'title', size: 20, tone: 'ink', fit: [w, 28]})
  items.forEach((it, i) => text(x, y + 54 + i * lh, (i + 1) + '. ' + it, {style: 'hand', size: 19, tone: 'ink', fit: [w, lh]}))
}
// clipping(x, y, w, title, body, source): a fact in a window, its source in the title bar.
const clipping = (x, y, w, title, body, source, o = {}) => {
  const h = o.h || 130;
  [x, y] = __clear(x, y, w, h)
  __win(x, y, w, h, {board: o.board || 'plain', title: source || o.title})
  text(x, y + 24, title, {style: 'title', size: 20, tone: 'ink', fit: [w, 28]})
  text(x, y + 52, body, {style: 'body', size: 17, tone: 'grey', fit: [w, h - 56], baseline: __TOP})
}
// legend(x, y, items, {size}): a row of colour keys, [[tone, words], ...], each a small dot and its words in grey; y is
// the words' baseline. The program puts it where its picture has room (under a chart, beside a map). Returns how wide it is.
const legend = (x, y, items = [], o = {}) => {
  const size = o.size || 15, r = max(3, round(size * 0.3)), gap = round(size * 0.45), apart = round(size * 1.3)
  let cx = x
  for (const entry of Array.isArray(items) ? items : []) {
    const [colour, words] = Array.isArray(entry) ? entry : [entry && entry.tone, entry && entry.label]
    if (!words) continue
    dot(cx + r, y - size * 0.3, r, {tone: colour || 'grey', fill: colour || 'grey', role: 'key'})
    text(cx + 2 * r + gap, y, String(words), {size, tone: 'grey', place: false})
    cx += 2 * r + gap + String(words).length * size * 0.42 + apart
  }
  return max(0, cx - apart - x)
}
// paper(x, y, w, h, {title, heading, subtitle, board}): a window to draw a diagram, chart or picture on. board: 'grid'
// (the default, the faint chart grid), 'dots' or 'plain' ({grid: false} is plain too). The fixed parts are the window's
// padding, the heading with its grey subtitle at the top left, and the sources line under everything (sources()).
// Everything else, a legend, a key, a note, is the program's to place where its picture has room: fixed spots for them
// (2026-10-09, bottom-left legend) were written over by the rows the program drew after them, so they are gone (Nilesh).
// Returns the area under the heading {x, y, w, h}, where the program draws.
const paper = (x, y, w, h, o = {}) => {
  const clean = v => (v == null ? '' : String(v).replace(/\s+/g, ' ').trim())
  const heading = clean(o.heading), subtitle = clean(o.subtitle)
  // Every window wears a name in its title bar, like a Mac window (2026-10-14, Farza): the program's title, else the
  // card's heading when it is short enough to read as one.
  const title = clean(o.title) || (heading.split(' ').length <= 5 ? heading : '')
  __win(x, y, w, h, {title, board: o.board, grid: o.grid, footer: true})
  let top = y
  if (heading) {
    text(x, y + 20, heading, {style: 'title', size: 26, tone: 'ink', place: false, fit: [w, 34]})
    top = y + 20 + 26 * 0.3
  }
  if (subtitle) {
    const baseline = heading ? y + 50 : y + 14
    text(x, baseline, subtitle, {size: 18, tone: 'grey', place: false, fit: [w, 24]})
    top = baseline + 18 * 0.3
  }
  if (top > y) top += 32
  return {x, y: top, w, h: max(40, y + h - top)}
}
