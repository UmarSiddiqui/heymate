import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import test from 'node:test';

function fixture(width = 10, height = 10, pixel = () => [255, 255, 255, 255]) {
  const context = {
    document: { createElement: () => ({ getContext: () => ({}) }) },
    requestAnimationFrame() {}, setInterval() {}, atob: value => Buffer.from(value, 'base64').toString('binary'),
    performance: { now: () => 0 }, console,
  };
  context.window = context;
  vm.runInNewContext(readFileSync(new URL('../HeyMate/mate-host.js', import.meta.url), 'utf8'), context);
  const sampling = context.HeyMateCanvas.screenSampling;
  const rgba = Buffer.alloc(width * height * 4);
  for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) rgba.set(pixel(x, y), (y * width + x) * 4);
  assert.equal(sampling.set({ width, height, rgba: rgba.toString('base64') }), true);
  return { sampling, context };
}
const near = (got, expected) => assert.ok(Math.abs(got - expected) < 1e-12, `${got} != ${expected}`);

test('native ink follows dominant background; uniform backgrounds have no busyness', () => {
  const { sampling: light } = fixture();
  near(light.lumFor(0, 0, 8, 8), 1);
  assert.equal(light.inkFor(0, 0, 8, 8), '#15171C');
  near(light.busyFor(0, 0, 8, 8), 0);
  const { sampling: dark } = fixture(10, 10, () => [0, 0, 0, 255]);
  near(dark.lumFor(0, 0, 8, 8), 0);
  assert.equal(dark.inkFor(0, 0, 8, 8), '#FFFFFF');
});

test('native RGB weights preserve channel order; alpha ignored by sampler', () => {
  for (const [pixel, expected] of [[[255, 0, 0, 0], 0.2126], [[0, 255, 0, 255], 0.7152], [[0, 0, 255, 255], 0.0722]]) {
    const { sampling } = fixture(10, 10, () => pixel);
    near(sampling.lumFor(0, 0, 8, 8), expected);
  }
});

test('native histogram selects background mode rather than averaging dark text into it', () => {
  const { sampling } = fixture(10, 10, x => x < 2 ? [0, 0, 0, 255] : [255, 255, 255, 255]);
  near(sampling.lumFor(0, 0, 8, 8), 1);
  assert.equal(sampling.inkFor(0, 0, 8, 8), '#15171C');
});

test('equal histogram populations preserve first darker bin', () => {
  const { sampling } = fixture(2, 2, (x, y) => x === y ? [0, 0, 0, 255] : [255, 255, 255, 255]);
  near(sampling.lumFor(0, 0, 2, 2), 0);
});

test('native busy scanlines measure adjacent pixels in both axes', () => {
  const { sampling: stripes } = fixture(10, 10, x => x % 2 ? [0, 0, 0, 255] : [255, 255, 255, 255]);
  near(stripes.busyFor(0, 0, 7, 7), 0.5);
  const { sampling: checker } = fixture(10, 10, (x, y) => (x + y) % 2 ? [0, 0, 0, 255] : [255, 255, 255, 255]);
  near(checker.busyFor(0, 0, 7, 7), 1);
  const { sampling: large } = fixture(340, 340, (x, y) => (x + y) % 2 ? [0, 0, 0, 255] : [255, 255, 255, 255]);
  near(large.busyFor(0, 0, 338, 338), 1);
});

test('bounds use clipped screenshot coordinates; invalid/empty regions retain native defaults', () => {
  const { sampling } = fixture();
  near(sampling.lumFor(-4, -4, 8, 8), 1);
  assert.equal(sampling.lumFor(20, 0, 8, 8), -1);
  assert.equal(sampling.lumFor(0, 0, 0, 8), -1);
  assert.equal(sampling.busyFor(0, 0, -1, 8), 0);
  assert.equal(sampling.inkFor(NaN, 0, 8, 8), '#FFFFFF');
});

test('missing or malformed replacement capture clears previous screenshot', () => {
  const { sampling } = fixture();
  assert.equal(sampling.set({ width: 10, height: 10, rgba: 'AA==' }), false);
  assert.equal(sampling.lumFor(0, 0, 8, 8), -1);
  assert.equal(sampling.inkFor(0, 0, 8, 8), '#FFFFFF');
  assert.equal(sampling.busyFor(0, 0, 8, 8), 0);
});

test('screen change drops screenshot even before drawing engine starts', () => {
  const { sampling, context } = fixture();
  context.HeyMateCanvas.screenChanged();
  assert.equal(sampling.lumFor(0, 0, 8, 8), -1);
});
