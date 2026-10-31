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
