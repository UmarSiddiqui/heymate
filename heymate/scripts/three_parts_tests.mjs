import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import test from 'node:test';

const sources = new URL('../HeyMate/', import.meta.url);
const context = vm.createContext({ console });
for (const name of ['mate-three.js', 'mate-three-parts.js']) vm.runInContext(fs.readFileSync(new URL(name, sources), 'utf8'), context);
const build = (kind, recipe = {}) => context.mateThreeBuild(kind, JSON.stringify(recipe));

// Open edges (used by one triangle once coincident points are welded), signed volume (positive when every triangle
// faces out), and the share of triangle corners whose normal agrees with the triangle's facing.
function shape(out) {
  const p = out.positions, n = out.normals, ix = out.indices, ids = [], seen = new Map(), edges = new Map();
  for (let i = 0; i < p.length; i += 3) {
    const key = [0, 1, 2].map(a => Math.round(p[i + a] * 1e4)).join('|');
    if (!seen.has(key)) seen.set(key, seen.size);
    ids.push(seen.get(key));
  }
  let volume = 0, agree = 0, corners = 0;
  for (let t = 0; t < ix.length; t += 3) {
    const [a, b, c] = [ix[t], ix[t + 1], ix[t + 2]].map(i => [p[i * 3], p[i * 3 + 1], p[i * 3 + 2]]);
    volume += (a[0] * (b[1] * c[2] - b[2] * c[1]) - a[1] * (b[0] * c[2] - b[2] * c[0]) + a[2] * (b[0] * c[1] - b[1] * c[0])) / 6;
    const u = [0, 1, 2].map(k => b[k] - a[k]), v = [0, 1, 2].map(k => c[k] - a[k]);
    const f = [u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0]];
    for (const i of [ix[t], ix[t + 1], ix[t + 2]]) { corners++; if (f[0] * n[i * 3] + f[1] * n[i * 3 + 1] + f[2] * n[i * 3 + 2] >= 0) agree++; }
    for (const [x, y] of [[ids[ix[t]], ids[ix[t + 1]]], [ids[ix[t + 1]], ids[ix[t + 2]]], [ids[ix[t + 2]], ids[ix[t]]]]) {
      if (x === y) continue;
      const key = x < y ? x + ':' + y : y + ':' + x;
      edges.set(key, (edges.get(key) || 0) + 1);
    }
  }
  let open = 0;
  for (const uses of edges.values()) if (uses === 1) open++;
  const lo = [Infinity, Infinity, Infinity], hi = [-Infinity, -Infinity, -Infinity];
  for (let i = 0; i < p.length; i += 3) for (let a = 0; a < 3; a++) { lo[a] = Math.min(lo[a], p[i + a]); hi[a] = Math.max(hi[a], p[i + a]); }
  return { open, volume, agree: agree / corners, lo, hi };
}
const near = (actual, expected, tolerance, label) => assert.ok(Math.abs(actual - expected) <= tolerance, `${label}: ${actual} vs ${expected}`);

// Parts that must come out closed and facing out, with the volume their recipe implies.
const SOLIDS = [
  ['box', { w: 1, h: 2, d: 0.5 }, 1],
  ['box', { size: [1, 1, 1], r: 0.1 }, 0.975],
  ['cyl', { r: 0.5, h: 2 }, Math.PI * 0.25 * 2],
  ['cyl', { r: 0.5, top: 0.2, h: 1, bevel: 0.05 }, 0.405],
  ['cyl', { r: 0.5, h: 0.8, arc: 270 }, Math.PI * 0.25 * 0.8 * 0.75],
  ['cone', { r: 0.6, h: 1.2 }, Math.PI * 0.36 * 1.2 / 3],
  ['cone', { r: 0.6, h: 1.2, bevel: 0.08 }, 0.446],
  ['tube', { r: 1, inner: 0.8, h: 0.5 }, Math.PI * 0.36 * 0.5],
  ['tube', { r: 1, inner: 0.7, h: 1, bevel: 0.05, axis: 'z' }, 1.588],
  ['arrow', { points: [[0, 0, 0], [1, 1, 0], [2, 0, 0]], r: 0.05 }, 0.0255],
  ['arrow', { points: [[0, 0, 0], [0, 0, 0]] }, 0.0066],
  ['lathe', { profile: [[0, 0], [0.5, 0.1], [0.4, 0.8], [0, 1]] }, 0.506],
  ['sphere', { r: 0.75 }, 4 / 3 * Math.PI * 0.75 ** 3],
  ['sphere', { r: 1, dome: true, thick: 0.05 }, 0.298],
  ['torus', { r: 0.6, tube: 0.23, axis: 'z' }, 2 * Math.PI ** 2 * 0.6 * 0.23 ** 2],
  ['torus', { r: 1, tube: 0.1, arc: 180 }, Math.PI ** 2 * 0.01],
  ['capsule', { r: 0.3, h: 1 }, 0.39],
  ['pipe', { points: [[0, 0, 0], [1, 0, 0], [1, 1, 0], [2, 1, 1]], r: 0.1 }, 0.111],
  ['pipe', { points: [[0, 0, 0], [1, 0, 0], [1, 1, 0]], r: 0.1, closed: true }, 0.105],
  ['spring', { r: 0.5, h: 2, coils: 8 }, 0.272],
  ['gear', { teeth: 16, r: 1, hole: 0.2 }, 0.927],
  ['extrude', { shape: [[0, 0], [1, 0], [1, 1], [0, 1]], depth: 0.3 }, 0.35],
  ['blob', { r: 1, seed: 3 }, 4.2],
  ['blob', { balls: [[-0.4, 0.2, 0, 0.55], [0.4, 0.2, 0, 0.55]], sticks: [[0, -0.2, 0, 0, -0.9, 0, 0.25, 0.05]] }, 1.402],
  ['blob', { balls: [{ at: [0, 0, 0], r: 0.6 }, { at: [0.8, 0, 0], r: 0.3 }, { at: [0, 0.8, 0], r: 0.25 }] }, 1.093],
  ['poly', { faces: 12, detail: 1 }, 0.472],
  ['box', { w: 1, h: 1, d: 1, stretch: [2, 1, 1], mirror: [-1, 1, 1] }, 2],
  ['cyl', { r: 0.5, h: 1, thick: 0.05, open: true }, 0.149],
];

test('every kind the engine can ask for is built', () => {
  assert.deepEqual([...context.mateThreeKinds].sort(), ['arrow', 'blob', 'box', 'capsule', 'cone', 'cyl', 'cylinder', 'extrude', 'gear', 'lathe',
    'pipe', 'poly', 'sphere', 'spring', 'surface', 'torus', 'tube']);
  assert.throws(() => build('nope'), /unknown 3D part "nope"/);
  assert.throws(() => build('toString'), /unknown 3D part/);
});

test('solid parts are closed, face out and keep their volume', () => {
  for (const [kind, recipe, volume] of SOLIDS) {
    const label = kind + ' ' + JSON.stringify(recipe), s = shape(build(kind, recipe));
    assert.equal(s.open, 0, label + ' has holes');
    assert.ok(s.agree > 0.995, label + ' has triangles facing in (' + s.agree + ')');
    near(s.volume, volume, Math.max(0.02 * volume, 0.003), label + ' volume');
  }
});

test('sheets stay open where their recipe says', () => {
  assert.equal(shape(build('cyl', { r: 1, h: 0.2, open: true })).open, 96);
  assert.equal(shape(build('sphere', { r: 1, dome: true })).open, 48);
  assert.equal(shape(build('surface', { grid: [[[0, 0, 0], [1, 0, 0]], [[0, 1, 0], [1, 1, 0]]] })).open, 4);
});

test('parts keep their size and point along their axis', () => {
  const box = shape(build('box', { w: 1, h: 2, d: 0.5 }));
  assert.deepEqual([box.lo, box.hi], [[-0.5, -1, -0.25], [0.5, 1, 0.25]]);
  const cyl = shape(build('cyl', { r: 0.3, h: 1, axis: 'x' }));
  near(cyl.hi[0], 0.5, 1e-6, 'cyl along x'); near(cyl.hi[1], 0.3, 1e-3, 'cyl radius');
  const down = shape(build('cone', { r: 0.5, h: 1, axis: '-y' }));
  near(down.lo[1], -0.5, 1e-6, 'cone base'); near(down.hi[1], 0.5, 1e-6, 'cone tip');
  const gear = shape(build('gear', { teeth: 20, r: 1, w: 0.3 }));
  near(gear.hi[0], 1, 0.03, 'gear rim (plus its bevel)'); near(gear.hi[2] - gear.lo[2], 0.3 + 2 * 0.02, 1e-6, 'gear width (plus its bevel)');
  const pipe = shape(build('pipe', { points: [[0, 0, 0], [1, 0, 0]], r: 0.1 }));
  near(pipe.lo[0], -0.1, 1e-3, 'round end'); near(pipe.hi[0], 1.1, 1e-3, 'round end');
});

test('the same recipe always builds the same arrays', () => {
  for (const [kind, recipe] of SOLIDS) {
    const a = build(kind, recipe), b = build(kind, recipe);
    assert.deepEqual(a.positions, b.positions, kind);
    assert.deepEqual(a.indices, b.indices, kind);
  }
});

test('packing matches what the stage uploads', () => {
  const out = build('blob', { balls: [[0, 0, 0, 0.5], [0.6, 0, 0, 0.4]] });
  // The arrays come from the kernel's own realm, so check their kind by name.
  assert.deepEqual([out.positions, out.normals, out.indices].map(a => a.constructor.name), ['Float32Array', 'Float32Array', 'Uint32Array']);
  assert.equal(out.positions.length, out.normals.length);
  assert.ok(out.samples.constructor.name === 'Float32Array' && out.samples.length <= 600 * 3);
  assert.ok(out.indices.every(i => i < out.positions.length / 3));
  for (let i = 0; i < out.normals.length; i += 3) near(Math.hypot(out.normals[i], out.normals[i + 1], out.normals[i + 2]), 1, 1e-3, 'unit normal');
});

test('bad recipes degrade instead of breaking', () => {
  for (const [kind, recipe] of [['pipe', { points: [] }], ['pipe', { points: [[0, 0, 0], [0, 0, 0], [0, 0, 0]] }], ['arrow', { points: 'x' }],
    ['lathe', { profile: [[1]] }], ['extrude', { d: 'Q 1' }], ['extrude', { d: 'M0 0 A 0 0 0 0 1 10 10 L 0 10 Z' }],
    ['surface', { grid: [[1, 2]] }], ['blob', { balls: [[0, 0, 0, -1]] }], ['gear', { teeth: 'many' }], ['box', null]]) {
    const out = build(kind, recipe);
    assert.ok(out.positions.length > 0 && out.positions.every(Number.isFinite), kind + ' ' + JSON.stringify(recipe));
  }
});

test('svg paths become solid shapes', () => {
  const ring = shape(build('extrude', { d: 'M10 10 H 90 V 90 H 10 Z M30 30 A20 20 0 1 0 70 30 A20 20 0 1 0 30 30 Z', depth: 0.2 }));
  near(ring.hi[0] - ring.lo[0], 0.8, 0.04, 'square width (plus its bevel)');
  // Solid square 0.8 x 0.8 x 0.2 is about 0.16 with its bevel; the 0.2-radius hole takes about 0.025 out.
  near(ring.volume, 0.133, 0.006, 'hole cut out of the square');
});

test('runaway recipes are refused', () => {
  assert.throws(() => build('surface', { grid: Array.from({ length: 400 }, (_, j) => Array.from({ length: 400 }, (_, i) => [i, j, 0])) }), /too detailed/);
});

test('the three.js slice holds exactly what the builder uses', () => {
  const used = new Set(fs.readFileSync(new URL('mate-three-parts.js', sources), 'utf8').match(/\bL\.[A-Za-z]\w*/g).map(name => name.slice(2)));
  assert.deepEqual(Object.keys(vm.runInContext('MateThreeLib', context)).sort(), [...used].sort());
});

test('mate-three.js is the build of scripts/three-kernel', { skip: !fs.existsSync(new URL('three-kernel/node_modules/esbuild', import.meta.url)) && 'run npm ci in scripts/three-kernel' }, async () => {
  const { execFileSync } = await import('node:child_process');
  execFileSync(process.execPath, [new URL('three-kernel/build.mjs', import.meta.url).pathname, '--check'], { stdio: 'pipe' });
});
