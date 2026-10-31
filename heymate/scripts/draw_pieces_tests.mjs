import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { createHash } from 'node:crypto';
import test from 'node:test';

const sources = new URL('../HeyMate/', import.meta.url);
const engine = fs.readFileSync(new URL('mate-draw-engine.js', sources), 'utf8');
const pieces = fs.readFileSync(new URL('mate-draw-pieces.js', sources), 'utf8');
const W = 1280, H = 800;

// A drawing program run the way the app runs it: the pieces first, then the program, in the engine's scope.
function draw(code, host = {}) {
  const context = vm.createContext({ console, ...host });
  vm.runInContext(engine, context);
  const marks = context.MateDraw.runCode(pieces + '\n' + code, W, H);
  return { marks: JSON.parse(JSON.stringify(marks)), error: marks.error || null, says: marks.says };
}
const ok = (code, host) => { const run = draw(code, host); assert.equal(run.error, null, code); return run.marks; };
const boxOf = pts => { const xs = pts.map(p => p[0]), ys = pts.map(p => p[1]); return [Math.min(...xs), Math.min(...ys), Math.max(...xs), Math.max(...ys)]; };

const PIECES = ['INK', 'button', 'check', 'cheer', 'clipping', 'connect', 'copyText', 'cross', 'dreamMedal', 'fadeAway', 'frame', 'handOff', 'hover', 'ink',
  'inkCircle', 'jobTicket', 'label', 'legend', 'lessonTitle', 'nextQuestions', 'num', 'onScreen', 'openPage', 'paper', 'photo', 'plan', 'point', 'receipt',
  'ring', 'scroll', 'sfx', 'showNotch', 'source', 'sources', 'spotlight', 'sticky', 'strike', 'tag', 'target', 'task', 'tie', 'tourJob', 'trace',
  'tuckJobs', 'typeText', 'underline', 'waitForUser', 'write'];

test('every piece the model is taught exists, and nothing else leaks into the program', () => {
  const [mark] = ok(`text(1, 1, JSON.stringify([${PIECES.map(n => `typeof ${n}`).join(',')}]))`);
  assert.ok(JSON.parse(mark.text).every(t => t === 'function' || t === 'string'));
  const [leak] = ok(`text(1, 1, [typeof __pills, typeof __gel, typeof __nameMark, typeof pills, typeof gel, typeof drawWindow].join())`);
  assert.equal(leak.text, 'undefined,undefined,undefined,undefined,undefined,undefined');
});

test('a program may use any name for its own things', () => {
  // these were private helpers once; a program declaring them must not change how the pieces place pills
  const plain = ok(`label(100, 100, 'One'); label(100, 100, 'Two')`);
  const shadowed = ok(`const pills = []; var named = 3; let __pills = 'mine'; label(100, 100, 'One'); label(100, 100, 'Two')`);
  assert.deepEqual(shadowed, plain);
});

test('pills never land on each other', () => {
  const marks = ok(`for (let i = 0; i < 12; i++) ring(200 + (i % 4) * 90, 200 + Math.floor(i / 4) * 40, 60, 20, 'Item ' + i)`);
  const pills = marks.filter(m => m.role === 'label' && m.do === 'poly' && m.snd === 'gel-pop').map(m => boxOf(m.pts));
  assert.equal(pills.length, 12);
  for (let i = 0; i < pills.length; i++) for (let j = i + 1; j < pills.length; j++) {
    const [a, b] = [pills[i], pills[j]];
    assert.ok(a[2] <= b[0] || b[2] <= a[0] || a[3] <= b[1] || b[3] <= a[1], `pills ${i} and ${j} overlap`);
  }
});

test('trace({fill: true}) tints the inside in the ink', () => {
  const [mark] = ok(`trace([[100,100],[300,80],[350,250],[120,280]], {fill: true})`, { __mateInk: '#FF4C4C' });
  assert.equal(mark.fill, '#FF4C4C');
  assert.equal(mark.fillAlpha, 0.18);
});

test("a sticky's folded corner stays on its sheet when tilted", () => {
  const marks = ok(`sticky(100, 100, 'note', 'butter', {tilt: 8, size: 200})`);
  const sheet = marks.find(m => m.do === 'poly' && m.snd === 'sticky-press'), fold = marks.find(m => m.do === 'poly' && m.fillAlpha === 0.12);
  // the fold's two outer corners are the sheet's two cut corners
  for (const p of fold.pts.slice(0, 2)) assert.ok(sheet.pts.some(q => Math.hypot(p[0] - q[0], p[1] - q[1]) < 1e-6), 'fold corner off the sheet');
});

test('pills are sized for wide characters', () => {
  const width = str => { const [m] = ok(`label(100, 100, ${JSON.stringify(str)})`); const b = boxOf(m.pts); return b[2] - b[0]; };
  assert.ok(width('保存してください') > width('abcdefgh') * 1.5);
  assert.equal(width('Save'), Math.round(4 * 12 * 0.58 + 12 * 1.9));
});

test('odd inputs draw what they can instead of stopping the program', () => {
  for (const code of [`ink([], {label: 'x'})`, `receipt(1, 1, 'T', null)`, `button({}, 'x', {open: 'u'})`, `sticky(1, 1)`, `trace([], {label: 'x'})`,
    `tie(null, [1, 2, 3, 4])`, `sources(1, 1, 'nope')`, `legend(1, 1, 'nope')`, `nextQuestions('nope')`, `spotlight({alpha: 0.5})`, `label(1, 1, null)`]) {
    const run = draw(code + `; text(5, 5, 'after')`);
    assert.equal(run.error, null, code);
    assert.ok(run.marks.some(m => m.text === 'after'), code);
  }
});

test('host hooks: the app draws pointers, buttons and windows itself', () => {
  const host = { __hostDrawsPointers: true, __hostDrawsButtons: true, __hostDrawsWindows: true, __mateInk: '#26c281' };
  const marks = ok(`target(100, 100, 80, 30, 'Go'); button(300, 300, 'Open', {open: 'https://a.com'}); paper(400, 200, 300, 200, {title: 'T'}); text(1, 1, typeof __card3d)`, host);
  assert.deepEqual(marks.filter(m => m.role === 'target').map(m => [m.do, m.ring, m.box]), [['dot', 21, [100, 100, 80, 30]]]);
  assert.equal(marks.filter(m => m.role === 'button').length, 1);
  assert.equal(JSON.parse(marks.find(m => m.role === 'button').payload).kind, 'open');
  assert.ok(marks.some(m => m.do === 'window'));
  assert.equal(marks.at(-1).text, 'function');
  // a lower-case ink is the same ink
  assert.equal(ok(`point(10, 10)`, host)[0].tone, '#26C281');
});

// Fingerprints of what a set of drawings produce. A change here is a visible change: check it renders as intended,
// then update the fingerprint.
const GOLDEN = {
  screen: `point(300, 200, 'Save'); target(100, 100, 80, 30, 'Export'); hover(500, 500, 120, 40, 'Menu'); frame(100, 300, 400, 200, 'Panel'); ring(700, 100, 60, 20, 'Word'); ring(900, 300, 300, 200, 'Big'); scroll(1100, 600); num(50, 700, 1); underline(200, 700, 120); check(400, 700); cross(450, 700); strike(500, 700, 80); connect([600, 650], [800, 700], {label: 'then'})`,
  cards: `const a = paper(200, 120, 600, 380, {title: 'Plan', heading: 'How it works', subtitle: 'In short'}); num(a.x, a.y + 20, 1); write(a.x + 30, a.y + 28, 'Find the file'); const p = photo(900, 100, 200, 150, 'eiffel tower', 'Eiffel Tower', {subtitle: 'Paris'}); tie([700, 300], p); button(p, 'Visit', {open: 'https://x.com'}); sources(a.x, a.y + a.h, [['apple.com', 'Apple'], ['b.com', 'B']]); receipt(50, 550, 'List', ['a', 'b']); clipping(400, 560, 300, 'Fact', 'Body', 'Wiki'); legend(800, 700, [['red', 'Red'], ['sky', 'Sky']])`,
  tour: `spotlight(300, 300, 200, 100); jobTicket(100, 100, {title: 'Your mashup', steps: ['listen', 'match', 'pick'], time: '2 min', icon: 'chart', handOff: {task: 't'}}); dreamMedal(800, 300, '$1', {caption: 'from a stranger'}); sticky(900, 550, 'Note', 'mint'); cheer(600, 700)`,
};
const EXPECTED = JSON.parse(fs.readFileSync(new URL('draw-pieces-golden.json', import.meta.url), 'utf8'));
const fingerprint = marks => createHash('sha256').update(JSON.stringify(marks, (k, v) => (typeof v === 'number' ? Math.round(v * 1000) / 1000 : v))).digest('hex');

test('drawings look the way they did', () => {
  const hosts = { plain: {}, gold2x: { __mateInk: '#D4A017', __canvasUnitPoints: 2 }, windows: { __hostDrawsWindows: true, __hostDrawsMarquee: true } };
  const actual = {};
  for (const [hostName, host] of Object.entries(hosts)) for (const [name, code] of Object.entries(GOLDEN)) actual[hostName + '/' + name] = fingerprint(ok(code, host));
  if (process.env.UPDATE_GOLDEN) fs.writeFileSync(new URL('draw-pieces-golden.json', import.meta.url), JSON.stringify(actual, null, 2) + '\n');
  else assert.deepEqual(actual, EXPECTED);
});
