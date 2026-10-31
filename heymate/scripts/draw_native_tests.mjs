import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { createHash } from 'node:crypto';
import test from 'node:test';

const sources = new URL('../HeyMate/', import.meta.url);
const read = name => fs.readFileSync(new URL(name, sources), 'utf8');
const native = read('mate-draw-native.js'), engine = read('mate-draw-engine.js'), pieces = read('mate-draw-pieces.js');

// The canvas booted the way mate-host.js boots it, against a host with a hand-wound clock and simple measurements.
// Every host call, return value and paint drain is logged.
function canvas() {
  const log = [], clock = { t: 100, timers: new Map() };
  const points = d => { const n = (String(d).match(/-?\d*\.?\d+(?:e[-+]?\d+)?/g) || []).map(Number), out = []; for (let i = 0; i + 1 < n.length; i += 2) out.push(n.slice(i, i + 2)); return out; };
  const __host = {
    now: () => clock.t,
    schedule: (id, s) => clock.timers.set(id, clock.t + s),
    cancel: id => clock.timers.delete(id),
    log: m => log.push(['log', String(m).split('\n')[0]]),
    textBox: json => { const d = JSON.parse(json), w = Math.max(...d.lines.map(l => String(l.text).length)) * d.size * 0.55; return [d.x, d.y - d.size * 0.8, w, d.size * 1.2 * d.lines.length]; },
    pathBox: d => { const p = points(d); if (!p.length) return [0, 0, 0, 0]; const xs = p.map(q => q[0]), ys = p.map(q => q[1]); return [Math.min(...xs), Math.min(...ys), Math.max(...xs) - Math.min(...xs), Math.max(...ys) - Math.min(...ys)]; },
    textWidth: (family, size, weight, text) => String(text).length * size * 0.55,
    pathLength: d => { const p = points(d); let s = 0; for (let i = 1; i < p.length; i++) s += Math.hypot(p[i][0] - p[i - 1][0], p[i][1] - p[i - 1][1]); return s; },
    pathPoint: d => points(d)[0] || [0, 0],
    inkFor: x => (x > 640 ? '#15171C' : '#FFFFFF'),
    busyFor: () => 0.2, lumFor: () => 0.4, figuresFloat: () => true,
    shape3d: kind => log.push(['shape3d', kind]),
    caption: c => log.push(['caption', c]),
    markSound: (i, json) => log.push(['sound', i, json]),
    buttonReady: (i, s) => log.push(['buttonReady', i, Math.round(s * 1000) / 1000]),
  };
  const context = vm.createContext({ __host, Math, JSON, Date: { now: () => 1e12 } });
  vm.runInContext(native, context);
  vm.runInContext(engine, context);
  const drain = tag => { const out = context.__drainRender(); if (out) log.push(['drain', tag, out]); return out; };
  const call = (method, ...args) => { const v = context.mateCanvas[method](...args); log.push(['ret', method, ArrayBuffer.isView(v) ? Array.from(v) : v]); drain(method); return v; };
  const advance = seconds => {
    for (const end = clock.t + seconds; clock.t < end - 1e-9;) {
      clock.t = Math.min(end, clock.t + 1 / 30);
      const due = [...clock.timers].filter(([, at]) => at <= clock.t + 1e-9).sort((a, b) => a[1] - b[1] || a[0] - b[0]);
      for (const [id] of due) if (clock.timers.delete(id)) context.__fireTimer(id);
      drain('tick');
    }
  };
  call('setPieces', pieces);
  return { call, advance, log, context, clock };
}

const PROGRAM = `step(1);say("First we open the file menu.");
target(40, 8, 60, 22, 'File');
ring(300, 200, 120, 30, 'Export');
step(2);say("Then this card explains the export settings.");
const a = paper(500, 150, 520, 320, {title: 'Export', heading: 'Settings that matter', subtitle: 'For video'});
num(a.x, a.y + 30, 1); text(a.x + 30, a.y + 38, 'Pick MP4', {tone: 'ink'});
const p = photo(1060, 160, 160, 120, 'vlc player', 'VLC');
button(p, 'Get VLC', {open: 'https://videolan.org'});
sources(a.x, a.y + a.h, [['videolan.org', 'VideoLAN']]);
step(3);say("Finally press export.");
point(900, 700, 'Export'); typeText(400, 600, 'movie.mp4'); sfx('tada'); cheer(100, 700);`;

test('a streamed drawing reports its lines, actions and what kind of drawing it is', () => {
  const c = canvas();
  c.call('beginStream', { w: 1280, h: 800, width: 1440, ink: '#3380ff' });
  const analysis = JSON.parse(c.call('feed', { code: PROGRAM, done: true }));
  assert.equal(analysis.error, null);
  assert.deepEqual(analysis.lines, ['First we open the file menu.', 'Then this card explains the export settings.', 'Finally press export.']);
  // the sources line's favicon is looked up like a photo; point() reports its ring and its dot
  assert.deepEqual(analysis.actions.map(a => [a.role, a.line]), [['target', 0], ['photo', 1], ['button', 1], ['photo', 1], ['point', 2], ['point', 2], ['type', 2]]);
  assert.equal(analysis.picture, true);
  assert.deepEqual([analysis.pointingLines, analysis.cardLines], [[0, 2], [1]]);
  assert.equal(c.context.__mateInk, '#3380FF');
});

test('marks are painted as their lines are heard, and the button waits for its beat', () => {
  const c = canvas();
  c.call('beginStream', { w: 1280, h: 800, width: 1440 });
  c.call('feed', { code: PROGRAM, done: true });
  c.advance(1);
  assert.equal(c.log.filter(e => e[0] === 'drain' && e[1] === 'tick').length, 0, 'nothing drawn before the first line');
  c.call('line', 0); c.call('lineLength', 0, 1); c.advance(1.5);
  const painted = c.log.filter(e => e[0] === 'drain').flatMap(e => JSON.parse(e[2]));
  assert.ok(painted.some(op => op.op === 'set' && op.group), 'first beat painted');
  assert.equal(c.log.filter(e => e[0] === 'buttonReady').length, 0);
  c.call('line', 1); c.advance(3); c.call('line', 2); c.call('finish'); c.advance(3);
  assert.equal(c.log.filter(e => e[0] === 'buttonReady').length, 1);
  assert.equal(c.call('isFinished'), true);
});

test("errors point at the program's own lines, not the pieces before it", () => {
  const c = canvas();
  c.call('beginStream', { w: 1280, h: 800, width: 1280 });
  assert.match(JSON.parse(c.call('feed', { code: 'step(1);say("x");ring(10, 10, 50, 20, "ok");\nring(oops', done: true })).error, /^syntax error after line 1:/);
  // (a runtime error's line comes from the JavaScript engine's stack text, which differs between runtimes)
});

test('a continued drawing keeps its earlier turns and counts lines on', () => {
  const c = canvas();
  c.call('beginStream', { w: 1280, h: 800, width: 1280 });
  c.call('feed', { code: PROGRAM, done: true });
  for (const k of [0, 1, 2]) { c.call('line', k); c.call('lineLength', k, 0.5); c.advance(1.5); }
  c.call('finish'); c.advance(2);
  const next = JSON.parse(c.call('continueStream', {}));
  assert.equal(next.firstLine, 3);
  assert.match(next.code, /__turn\(\d+, \d+\);$/);
  assert.ok(!next.code.includes('const label'), 'the pieces are not part of the kept code');
  const analysis = JSON.parse(c.call('feed', { code: 'step(1);say("And here.");ring(200, 500, 100, 30, "Here");', done: true }));
  assert.equal(analysis.firstLine, 3);
  assert.deepEqual(analysis.actions, []);
});

test('timers run on the host clock and can be cleared', () => {
  const c = canvas(), ran = [];
  c.context.ran = ran;
  vm.runInContext(`setTimeout(() => ran.push('once'), 50); const every = setInterval(() => ran.push('tick'), 100); setTimeout(() => clearInterval(every), 350); setTimeout(() => { throw new Error('boom'); }, 10);`, c.context);
  c.advance(1);
  assert.deepEqual(ran, ['once', 'tick', 'tick', 'tick']);
  assert.ok(c.log.some(e => e[0] === 'log' && /^timer error: Error: boom/.test(e[1])));
});

test('a drawn element is edited in place, not repainted', () => {
  const c = canvas(), { document, __drainRender } = c.context;
  const svg = document.createElementNS('', 'svg'), layer = document.createElementNS('', 'g'), path = document.createElementNS('', 'path');
  layer.setAttribute('id', 'main'); svg.appendChild(layer); document.body.appendChild(svg);
  path.setAttribute('d', 'M0,0 L10,10'); path.style.animation = 'pen 0.6s ease-out 0.1s both'; layer.appendChild(path);
  const first = JSON.parse(__drainRender());
  assert.deepEqual(first.map(o => o.op), ['set']);
  assert.deepEqual(first[0].node.anim.fn, [0, 0, 0.58, 1]);
  path.style.opacity = '0.5'; path.style.animation = 'none';
  const wrap = document.createElementNS('', 'g'); layer.appendChild(wrap); wrap.appendChild(path); wrap.setAttribute('transform', 'translate(5,5)');
  assert.deepEqual(JSON.parse(__drainRender()).map(o => o.op), ['wrap', 'prop', 'stop', 'prop']);
  // taking something out of a drawn unit sends the unit again; taking the unit out removes it
  path.remove();
  const resent = JSON.parse(__drainRender());
  assert.deepEqual(resent.map(o => [o.op, o.node.n]), [['set', wrap.__n]]);
  wrap.remove();
  assert.equal(__drainRender(), JSON.stringify([{ op: 'remove', n: wrap.__n }]));
  assert.equal(__drainRender(), '');
});

test('nothing breaks when the host calls before a drawing starts', () => {
  const c = canvas();
  for (const m of ['feed', 'line', 'lineLength', 'finish', 'timeline', 'state', 'keepNotesOnly', 'dropPointing', 'cards', 'closeCard', 'buttonSpot', 'markBox', 'tick3d', 'continueStream']) {
    assert.ok([null, false, 0, undefined].includes(c.call(m, {})), m);
  }
  assert.equal(c.call('isFinished'), true);
});

// Fingerprints of whole sessions: every paint op, sound, caption and return value. A change here changes what the host
// draws: render it, check it is intended, then update the fingerprint.
test('sessions paint what they did', () => {
  const fingerprint = log => createHash('sha256').update(JSON.stringify(log)).digest('hex');
  const stream = canvas();
  stream.call('beginStream', { w: 1280, h: 800, width: 1440, subtitles: true, ink: '#FF4C4C' });
  for (let i = 1; i <= 5; i++) { stream.call('feed', { code: PROGRAM.slice(0, Math.round(PROGRAM.length * i / 5)), done: i === 5 }); stream.advance(0.1); }
  for (const k of [0, 1, 2]) { stream.call('line', k); stream.call('lineLength', k, 1.2); stream.advance(1.6); stream.call('timeline'); }
  stream.call('finish'); stream.advance(2);
  stream.call('state'); stream.call('cards');
  stream.call('buttonSpot', { box: [1080, 300, 120, 34], gap: 6, avoid: [[1080, 300, 50, 50]] });
  stream.call('dropPointing'); stream.advance(1); stream.call('keepNotesOnly'); stream.advance(1);
  const whole = canvas();
  whole.call('renderWhole', { w: 1280, h: 800, width: 1440, code: PROGRAM, ink: '#D4A017' }); whole.advance(3); whole.call('state');
  const actual = { stream: fingerprint(stream.log), whole: fingerprint(whole.log) };
  const file = new URL('draw-native-golden.json', import.meta.url);
  if (process.env.UPDATE_GOLDEN) fs.writeFileSync(file, JSON.stringify(actual, null, 2) + '\n');
  else assert.deepEqual(actual, JSON.parse(fs.readFileSync(file, 'utf8')));
});

test('caps keep an emoji whole when they space out the letters', () => {
  const c = canvas();
  c.call('renderWhole', { w: 800, h: 600, width: 800, code: "text(40, 60, 'go 🚀 now', {style: 'caps'})" });
  c.advance(2);
  const painted = JSON.stringify(c.log.filter(e => e[0] === 'drain'));
  assert.ok(painted.includes('G\\u200aO') || painted.includes('G O'), 'the caps were spaced out');
  // no half of an emoji standing alone (a lone surrogate)
  const drained = c.log.filter(e => e[0] === 'drain').map(e => typeof e[2] === 'string' ? e[2] : JSON.stringify(e[2])).join('');
  assert.ok(drained.includes('🚀'));
  assert.doesNotMatch(drained, /[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/);
});
