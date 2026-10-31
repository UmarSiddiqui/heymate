import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import test from 'node:test';

const engine = fs.readFileSync(new URL('../HeyMate/mate-draw-engine.js', import.meta.url), 'utf8');
const context = vm.createContext({});
vm.runInContext(engine, context);
const G = context.MateDraw.geometry;

const ringOf = d => (String(d).match(/-?\d+\.\d/g) || []).map(Number).reduce((out, v, i) => (i % 2 ? out[out.length - 1].push(v) : out.push([v]), out), []);
const length = pts => pts.reduce((s, p, i) => (i ? s + Math.hypot(p[0] - pts[i - 1][0], p[1] - pts[i - 1][1]) : 0), 0);
// how far a point is from a polyline
function away(p, line) {
  let best = Infinity;
  for (let i = 1; i < line.length; i++) {
    const [a, b] = [line[i - 1], line[i]], dx = b[0] - a[0], dy = b[1] - a[1], l2 = dx * dx + dy * dy || 1;
    const t = Math.max(0, Math.min(1, ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / l2));
    best = Math.min(best, Math.hypot(p[0] - a[0] - dx * t, p[1] - a[1] - dy * t));
  }
  return best;
}
// a centreline drawn the way the engine draws a smooth line
const pen = pts => G.catmull(pts, false);

test('the same seed always wobbles the same way', () => {
  const a = G.rng('m3'), b = G.rng('m3'), c = G.rng('m4');
  const first = [a(), a(), a()];
  assert.deepEqual(first, [b(), b(), b()]);
  assert.notDeepEqual(first, [c(), c(), c()]);
  // pinned: every hand-drawn wobble on every card depends on this sequence
  assert.deepEqual(first.map(v => Math.round(v * 1e6)), [565373, 392481, 368908]);
});

test('a stroke never folds over itself where its line turns tighter than the pen is wide', () => {
  // A fold is a small loop in the outline's edge: it showed as a spike past a hairpin or a notch in a box's inner corner.
  // Count the edge's crossings between nearby segments (a real crossing of the line itself is far along it).
  const folds = d => {
    const p = ringOf(d), hits = [];
    const cross = (a, b, c, e) => { const d1 = (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]), d2 = (b[0] - a[0]) * (e[1] - a[1]) - (b[1] - a[1]) * (e[0] - a[0]);
      const d3 = (e[0] - c[0]) * (a[1] - c[1]) - (e[1] - c[1]) * (a[0] - c[0]), d4 = (e[0] - c[0]) * (b[1] - c[1]) - (e[1] - c[1]) * (b[0] - c[0]); return d1 * d2 < 0 && d3 * d4 < 0; };
    for (let i = 1; i < p.length; i++) for (let j = i + 2; j < Math.min(p.length, i + 12); j++) if (cross(p[i - 1], p[i], p[j - 1], p[j])) hits.push(i);
    return hits.length;
  };
  for (const pts of [[[0, 0], [100, 0], [100, 3], [0, 3]], [[0, 0], [60, 0], [62, 2], [60, 4], [0, 4]], [[0, 0], [100, 0], [100, 100], [0, 100]]]) {
    for (const size of [6, 9, 16]) {
      const line = G.densify(pts, 5);
      assert.equal(folds(G.outline(line, size)), 0, `${JSON.stringify(pts)} at ${size}`);
      assert.equal(folds(G.evenOutline(line, size / 2)), 0, `${JSON.stringify(pts)} even at ${size}`);
    }
  }
});

test("a corner keeps the line's width", () => {
  // a right angle drawn with the screen pen: the outside of the corner is a full half-width from the corner itself
  const line = G.densify([[0, 0], [100, 0], [100, 100]], 5), edge = ringOf(G.evenOutline(line, 4));
  const outside = Math.max(...edge.filter(p => p[0] > 100 && p[1] < 0).map(p => Math.hypot(p[0] - 100, p[1])));
  assert.ok(outside >= 4 * 1.4, `corner outside only ${outside.toFixed(2)} out`);
  // and a sharp tick turns round its point instead of ending in a long needle
  const tick = ringOf(G.evenOutline([[0, 0], [20, 30], [40, -40]], 4));
  assert.ok(Math.max(...tick.map(p => p[1])) <= 30 + 4 + 0.1);
});

test('a smooth line through uneven points does not loop or overshoot', () => {
  // a long run then two points close together: the plain (uniform) Catmull-Rom curve swung 10 units past the corner
  const pts = [[0, 0], [200, 0], [204, 4], [204, 200]], line = G.catmull(pts, false);
  for (const p of line) assert.ok(p[0] <= 207.5 && p[1] >= -3.5, `curve swings out to ${p}`);
  assert.equal(JSON.stringify([line[0], line.at(-1)]), '[[0,0],[204,200]]');
  // closed curves come back to their start, and repeated points do no harm
  const closed = G.catmull([[0, 0], [50, 0], [50, 0], [50, 50], [0, 50]], true);
  assert.equal(JSON.stringify(closed.at(-1)), '[0,0]');
  assert.ok(closed.every(p => p.every(Number.isFinite)));
});

test('dashes are cut to their lengths exactly', () => {
  const pieces = G.dashes([[0, 0], [101, 0]], 10, 5);
  assert.equal(pieces.length, 7);
  for (const dash of pieces) assert.ok(Math.abs(length(dash) - 10) < 1e-9, length(dash));
  for (let i = 1; i < pieces.length; i++) assert.ok(Math.abs(pieces[i][0][0] - pieces[i - 1].at(-1)[0] - 5) < 1e-9);
  assert.equal(G.dashes([[3, 3]], 10, 5).length, 0);
});

test('outlines are plain numbers', () => {
  const d = G.outline(G.densify([[0, 0.02], [10, -0.02], [20, 0]], 2), 0.1);
  assert.ok(!/-0\.0\b/.test(d), d);
  assert.equal(G.outline([[1, 1], [1, 1]], 4), null);
});

// ---------------------------------------------------------------- the program runner
const M = context.MateDraw;
const run = code => { const marks = M.runCode(code, 1280, 800); return { kinds: Array.from(marks, m => m.do), error: marks.error }; };

test('statements end where the program means them to', () => {
  const ends = code => Array.from(M.statementEnds(code));
  // an arrow function, a comparison or a destructuring pattern split across lines is one statement
  assert.deepEqual(ends('const f = x =>\n  x * 2\ndot(1, 1, 1)\n'), [23]);
  assert.deepEqual(ends('const ok = a >\n  b\ndot(1, 1, 1)\n'), [19]);
  assert.deepEqual(ends('const {\n  a,\n} = o\ndot(1, 1, 1)\n'), [19]);
  // a regular expression's brackets and quotes, and a template's ${} with templates inside, are not code
  assert.deepEqual(ends("const r = /[;}'(]/.test(s)\ndot(1, 1, 1)\n"), [27]);
  assert.deepEqual(ends('const s = `a${[1].map(x => `${x};`)}`\ndot(1, 1, 1)\n'), [38]);
  assert.deepEqual(ends('const half = 10 / 2 / 1\ndot(1, 1, 1)\n'), [24]);
  // a block goes on into else, catch and finally
  assert.deepEqual(ends('try {\n  a()\n} catch (e) {\n  b()\n} finally {\n  c()\n}\ndot(1, 1, 1)\n'), [51]);
  // the ends found so far stay when more code arrives, except the last ("} e" may become "} else")
  const scan = M.statementScanner();
  assert.deepEqual(Array.from(scan('if (a) {\n} e')), [10]);
  assert.deepEqual(Array.from(scan('if (a) {\n} else {\n}\ndot(1, 1, 1)')), [19]);
});

test("a runtime error names the program's own line", () => {
  assert.equal(run('dot(1, 1, 1)\nconst q = 2\nnope(q)\ndot(2, 2, 2)').error, 'code stopped at line 3: nope is not defined (kept the 1 marks before it)');
  // thrown inside a helper the program defined: the helper's line
  assert.match(run('function h() {\n  return null.x\n}\ndot(1, 1, 1)\nh()').error, /^code stopped at line 2: /);
  // a thrown value that is not an Error still reads (it has no stack, so no line)
  assert.match(run("dot(1, 1, 1)\nthrow 'no ink'").error, /^code stopped: no ink /);
  // a syntax error keeps the statements before it
  assert.deepEqual(run('dot(1, 1, 1);\nrect(1, 1, 2, 2);\ndot(oops').kinds, ['dot', 'rect']);
});

test('a line that opens with a bracket starts a new statement, run whole or streamed', () => {
  const code = 'function foo() { return 0 }\nfoo()\n[1, 2].forEach(i => dot(i, i, 1))\n(() => rect(0, 0, 1, 1))()';
  assert.deepEqual(run(code), { kinds: ['dot', 'dot', 'rect'], error: null });
  // streamed the way live() feeds it: each time a statement is complete
  const S = M.Session(1280, 800), kinds = [];
  for (const e of M.statementEnds(code)) kinds.push(...Array.from(S.update(code.slice(0, e), false).marks, m => m.do));
  kinds.push(...Array.from(S.update(code, true).marks, m => m.do));
  assert.deepEqual([S.mode, kinds], ['inc', ['dot', 'dot', 'rect']]);
});

test('names declared in one streamed chunk are there in the next', () => {
  const S = M.Session(1280, 800), parts = ['class Pin { constructor(x) { dot(x, x, 1) } }\n', 'const size = 4\n', 'let at = size * 2\n', 'new Pin(at)\nrect(size, at, 1, 1)\n'];
  let code = '', kinds = [];
  for (const [k, part] of parts.entries()) { code += part; kinds = kinds.concat(Array.from(S.update(code, k === parts.length - 1).marks, m => m.do)); }
  assert.equal(S.mode, 'inc', `fell back: ${S.fellBack}`);
  assert.deepEqual(kinds, ['dot', 'rect']);
  // and a later turn may declare the same names again
  assert.equal(S.update(code + 'class Pin {}\nconst size = 1\n', true).error, null);
});

test('statement spans and code fragments', () => {
  const code = '// heading\ndot(1, 1, 1)\nconst a = 2\nrect(a, a, 3, 3); dot(a, a, 1)';
  // (a comment on its own line is a span of its own that draws nothing; parts read their names from the lines)
  assert.deepEqual(JSON.parse(JSON.stringify(M.attribute(code, 1280, 800))).map(s => [code.slice(s.s, s.e).trim(), s.n1 - s.n0]),
    [['// heading', 0], ['dot(1, 1, 1)', 1], ['const a = 2', 0], ['rect(a, a, 3, 3);', 1], ['dot(a, a, 1)', 1]]);
  const added = M.exec(code, 'circle(a, a, 9)', 1280, 800);
  assert.deepEqual([Array.from(added.marks, m => [m.do, m.r]), added.error], [[['circle', 9]], null]);
});

test('a graph draws the part of a line that crosses the frame, and does not bridge a hole', () => {
  const marks = M.runCode(`
    const g = graph(40, 40, 200, 150, { x: [0, 10], y: [0, 10] });
    g.line([-5, 5], [15, 5], { tone: 'blue', size: 4 });
    g.line([-5, -5], [-1, -1], { tone: 'coral' });
    g.plot([[0, 1], [1, 2], [4, NaN], [8, 3], [9, 4]], { straight: true, tone: 'leaf', size: 4 });
  `, 800, 600);
  const lines = marks.filter(m => m.do === 'line' && m.piece === 'graph' && m.size === 4);
  const xy = line => Array.from(line.pts, p => [Math.round(p[0]), Math.round(p[1])]);
  assert.equal(marks.warnings.join('\n'), 'graph: a line lies completely outside the graph ranges');
  assert.equal(lines.length, 3);
  // from the left edge of the frame to the right, at y = 5
  assert.deepEqual(xy(lines[0]), [[40, 115], [240, 115]]);
  // the hole is two strokes, not one chord from x = 1 to x = 8
  assert.ok(xy(lines[1]).at(-1)[0] < 120 && xy(lines[2])[0][0] > 160);
});

test('wide letters take an em, and a link does not swallow the period after it', () => {
  const wide = M.runCode("text(10, 20, 'あ', { size: 20 })\ntext(0, 0, JSON.stringify(__inkBoxes()[0]))", 400, 200);
  assert.equal(JSON.parse(wide.at(-1).text)[2], 20);
  const link = M.runCode("text(0, 0, 'See https://example.com/a.')", 400, 100)[0];
  assert.equal(link.link, 'https://example.com/a');
  assert.equal(link.text, 'See https://example.com/a.');
  const named = M.runCode("text(0, 0, 'Go to https://very-long-example-domain.com/some/page.')", 800, 100)[0];
  assert.equal(named.link, 'https://very-long-example-domain.com/some/page');
  assert.ok(named.text.endsWith('.'));
});

test('a sandboxed figure can name a colour, and a failed surface does not name the next part', () => {
  const posted = [];
  let onMessage = null;
  const worker = vm.createContext({ self: { postMessage: m => posted.push(m), addEventListener: (_, f) => { onMessage = f; } }, Date, JSON, Math });
  vm.runInContext(M.workerSource(), worker);
  onMessage({ data: { type: 'init', w: 400, h: 300 } });
  onMessage({ data: { type: 'run', id: 2, code: "scene3d(40,40,200,160,s=>s.sphere({r:1,color:'red'}))\n", done: true } });
  const part = posted.at(-1).marks.find(m => m.do === 'part3d');
  assert.equal(posted.at(-1).error, null);
  assert.equal(part.material.color, '#E5484D');
  const missed = M.runCode(`
    const f = figure(40, 40, 200, 160, { card: false });
    const surf = f.surface(() => { throw new Error('boom'); }, { segments: 4, rows: 2 });
    f.sphere({ r: 0.2 });
  `, 800, 600);
  assert.match(missed.warnings.join('\n'), /surface\(\) function failed: boom/);
  assert.equal(missed.find(m => m.kind === 'sphere').name, undefined);
});

test('the sandbox gets a runner that stands on its own', () => {
  const posted = [];
  let onMessage = null;
  const worker = vm.createContext({ self: { postMessage: m => posted.push(m), addEventListener: (_, f) => { onMessage = f; } }, Date, JSON, Math });
  vm.runInContext(M.workerSource(), worker);
  onMessage({ data: { type: 'init', w: 100, h: 100 } });
  onMessage({ data: { type: 'run', id: 1, code: 'const k = 2\ndot(k, k, 1)\n', done: true } });
  assert.deepEqual(posted.map(p => [p.type, (p.marks || []).map(m => m.do).join()]), [['ready', ''], ['result', 'dot']]);
});

test('nothing outside the page is reachable from the sandbox, even through the global\'s prototypes', () => {
  // as in a real worker: fetch and friends live on the global's prototype, not on the global itself
  const posted = [];
  let onMessage = null;
  const scope = { fetch() {}, importScripts() {}, setTimeout() {}, postMessage: m => posted.push(m), addEventListener: (_, f) => { onMessage = f; } };
  const worker = vm.createContext({ Date, JSON, Math });
  worker.self = vm.runInContext('o => Object.create(o)', worker)(scope);
  vm.runInContext(M.workerSource(), worker);
  onMessage({ data: { type: 'init', w: 100, h: 100 } });
  const probe = "let o = self, seen = []\nwhile (o) { for (const k of ['fetch', 'importScripts', 'setTimeout']) if (Object.getOwnPropertyDescriptor(o, k) && typeof o[k] === 'function') seen.push(k); o = Object.getPrototypeOf(o) }\ntext(10, 20, seen.join(',') || 'none')\n";
  onMessage({ data: { type: 'run', id: 1, code: probe, done: true } });
  assert.equal(posted.at(-1).error, null);
  assert.equal(posted.at(-1).marks[0].text, 'none');
});

test('a slow sandbox start does not count against the program\'s time limit', async () => {
  // a worker that takes 80 ms to load (messages wait meanwhile, as in a real worker), then answers each run at once
  class SlowWorker {
    constructor() { this.queue = []; setTimeout(() => { const q = this.queue; this.queue = null; q.forEach(m => this.postMessage(m)); }, 80); }
    postMessage(q) {
      if (this.queue) { this.queue.push(q); return; }
      if (q.type === 'init') this.onmessage({ data: { type: 'ready' } });
      else if (q.type === 'run') setTimeout(() => this.onmessage({ data: { type: 'result', id: q.id, marks: [{ do: 'dot', at: [5, 5] }], says: [], warnings: [], error: null } }), 1);
    }
    terminate() { this.postMessage = () => {}; }
  }
  const page = vm.createContext({ Worker: SlowWorker, URL: { createObjectURL: () => 'blob:x' }, Blob: class {}, setTimeout, clearTimeout, performance });
  vm.runInContext(engine, page);
  const report = await new Promise(done => {
    const stream = page.MateDraw.Stream({ w: 100, h: 100 }, { sandbox: 'worker', timeLimit: 30, onDone: done });
    stream.update('dot(5, 5, 2)\n', true);
  });
  assert.deepEqual([...report.errors], []);
});

test('a path takes as long as the line its pen draws', () => {
  const time = d => M.natural({ do: 'path', d }).dur;
  // relative commands have a length (they used to take a flat 0.4 s)
  assert.equal(time('M0 0 l300 0'), time('M0 0 L300 0'));
  assert.ok(Math.abs(time('M0 0 l300 0') - 0.5) < 1e-9);
  // an arc is measured along the arc (its radii and flags used to be read as points)
  assert.ok(Math.abs(time('M0 0 A50 50 0 0 1 100 0') - Math.PI * 50 / 600) < 0.002);
  // a curve along the curve, not along its control points
  assert.ok(Math.abs(time('M0 0 C0 0 300 0 300 0') - 0.5) < 0.002);
  // H and V take one number each
  assert.ok(Math.abs(time('M0 0 H120 V120') - 240 / 600) < 1e-9);
});

test('the pen refuses settings that would stop it', () => {
  const before = M.setPen();
  try {
    const after = M.setPen({ base: NaN, per: -5, min: 'fast' });
    assert.equal(after.base, before.base);
    assert.equal(after.per, before.per);
    assert.equal(after.min, before.min);
  } finally { M.setPen(before); }
});

// a stream on a hand-wound clock: tick(s) runs its timers up to s seconds later
function woundStream(opts) {
  const clock = { t: 0, timers: new Map(), id: 0 }, done = [];
  const clk = { now: () => clock.t, set: (f, s) => { clock.timers.set(++clock.id, [clock.t + s, f]); return clock.id; }, clear: id => clock.timers.delete(id) };
  const tick = s => {
    const end = clock.t + s;
    for (let next; (next = [...clock.timers].filter(([, [at]]) => at <= end).sort((a, b) => a[1][0] - b[1][0])[0]);) { clock.timers.delete(next[0]); clock.t = Math.max(clock.t, next[1][0]); next[1][1](); }
    clock.t = end;
  };
  const stream = M.Stream({ w: 800, h: 600 }, Object.assign({ clock: clk, onDone: rep => done.push([...rep.warnings]) }, opts));
  return { stream, tick, done };
}

test('a continued turn reports only its own layout warnings', () => {
  const { stream, tick, done } = woundStream({});
  const first = 'rect(100, 100, 200, 120)\ntext(130, 150, "Cache")\nrect(160, 140, 200, 120)\n';
  stream.update(first, true); tick(1);
  assert.equal(done.length, 1);
  assert.equal(done[0].filter(w => /Cache/.test(w)).length, 1);
  stream.dropPending(); stream.reopen(stream.ran);
  stream.update(stream.ran + '__turn(2, ' + stream.count + ');\ndot(700, 500, 3)\n', true); tick(1);
  assert.equal(done.length, 2);
  // the first turn's warning is not reported again
  assert.equal(done[1].filter(w => /Cache/.test(w)).length, 1);
});

test('rebasing a stream takes the cut marks out of the layout', () => {
  const { stream, tick } = woundStream({});
  // a labelled box, then a box below it that the rebase cuts away
  stream.update('rect(100, 100, 200, 120)\ntext(130, 150, "Cache")\nrect(150, 240, 260, 120)\ndot(790, 590, 1)', false); tick(1);
  assert.equal(stream.count, 3);
  stream.rebase('rect(100, 100, 200, 120)\ntext(130, 150, "Cache")\n', 2);
  // a box half over "Cache" moves to the nearest free spot, just below it, where the cut box no longer is
  stream.update('rect(100, 100, 200, 120)\ntext(130, 150, "Cache")\nrect(180, 110, 200, 120)\n', true); tick(1);
  assert.deepEqual([...stream.marks[2].at], [180, 206]);
  assert.equal(stream.log.marks.filter(e => e.i === 2).length, 1);
});

test('a 3D figure\'s stage is a card, not ink that points at the screen', () => {
  const marks = M.runCode("scene3d(40, 40, 300, 240, s => { s.box({w: 1, h: 1, d: 1}) })", 800, 600);
  const stage = marks.find(m => m.do === 'stage3d');
  assert.ok(M.isCardMark(stage));
  assert.ok(!M.pointsAtScreen(stage));
});

test('a line that continues an expression with * is not a comment heading', () => {
  const code = 'const total = 3\n  * 2\nrect(10, 10, 100, 60)\n';
  const marks = M.runCode(code, 800, 600), d = M.describe({ code, stmts: M.attribute(code, 800, 600), mark: i => marks[i], W: 800, H: 600 });
  assert.equal(d.parts.length, 1);
  assert.doesNotMatch(d.parts[0].desc, /^2\b/);
});

test('a path has a box whatever its commands', () => {
  // relative commands (a document icon's lines) used to have no box, so they never rode with their card
  assert.equal(JSON.stringify(M.markBox({ do: 'path', d: 'M10 10 l100 0 l0 50 z', size: 2 })), '[9,9,111,61]');
  // a curve's box is the curve's, not its control points'
  const [, y0, , y1] = M.markBox({ do: 'path', d: 'M0 100 C 50 0 150 200 200 100', size: 2 });
  assert.ok(y0 > 60 && y1 < 140, `${y0} ${y1}`);
});
