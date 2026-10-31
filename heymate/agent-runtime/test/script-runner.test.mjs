import test from 'node:test';
import assert from 'node:assert/strict';
import { gf, hf, uu } from '../src/recovered-h1-script.mjs';

const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
const idle = { hasTool: () => false, callTool: async () => ({ ok: true, text: '' }) };

test('prints, returns and console share one transcript', async () => {
  const empty = await hf('', idle);
  assert.equal(empty.ok, true);
  assert.equal(empty.output, '(the program printed nothing)');
  assert.equal(empty.calls, 0);
  const both = await hf('text("hi"); return {a:1}', idle);
  assert.equal(both.output, 'hi\n{\n "a": 1\n}');
  assert.equal((await hf('console.warn("careful")', idle)).output, 'careful');
  assert.equal((await hf('text("a"); text("b")', idle)).output, 'a\nb');
  assert.equal((await hf('return undefined', idle)).output, '(the program printed nothing)');
});

test('a failed program keeps earlier prints and a syntax error stays in the result', async () => {
  const thrown = await hf('text("keep"); throw new Error("boom")', idle);
  assert.equal(thrown.ok, false);
  assert.equal(thrown.output, 'keep\nError: boom');
  assert.equal((await hf('throw "boom"', idle)).output, 'Error: boom');
  const syntax = await hf('return (', idle);
  assert.equal(syntax.ok, false);
  assert.match(syntax.output, /^Error: /);
});

test('the transcript cuts at 20,000 characters and does not keep the rest', async () => {
  const cut = await hf('text("x".repeat(20001))', idle);
  assert.equal(cut.ok, true);
  assert.equal(cut.output.slice(0, 20000), 'x'.repeat(20000));
  assert.equal(cut.output.slice(20000), '\n… (cut at 20000 characters: print less)');
  const across = await hf('text("a".repeat(19950)); text("b".repeat(100))', idle);
  assert.equal(across.output.slice(0, 20000), `${'a'.repeat(19950)}\n${'b'.repeat(49)}`);
  assert.match(across.output, /cut at 20000 characters/);
});

test('progress is short, collapsed and capped at 20 lines', async () => {
  const seen = [];
  await hf('for (let i = 0; i < 21; i++) progress("  step   " + i + "  "); progress("z".repeat(200));', {
    ...idle,
    onProgress: line => seen.push(line),
  });
  assert.equal(seen.length, 20);
  assert.equal(seen[0], 'step 0');
  assert.equal(seen[19], 'step 19');
  seen.length = 0;
  await hf('progress("z".repeat(200))', { ...idle, onProgress: line => seen.push(line) });
  assert.deepEqual(seen, ['z'.repeat(160)]);
});

test('tool results parse, failures throw, and only mac_step time is waited', async () => {
  const missing = await hf('await tools.missing({})', idle);
  assert.equal(missing.ok, false);
  assert.equal(missing.calls, 0);
  assert.equal(missing.output, 'Error: There is no tool named missing.');
  const failed = await hf('await tools.read({})', {
    hasTool: name => name === 'read',
    callTool: async () => ({ ok: false, text: 'nope' }),
  });
  assert.equal(failed.ok, false);
  assert.equal(failed.calls, 1);
  assert.equal(failed.output, 'Error: read failed: nope');
  const parsed = await hf('return await tools.read({})', {
    hasTool: () => true,
    callTool: async () => ({ ok: true, text: '{"value":1}' }),
  });
  assert.equal(parsed.output, '{\n "value": 1\n}');
  const plain = await hf('return await tools.read({})', {
    hasTool: () => true,
    callTool: async () => ({ ok: true, text: 'plain' }),
  });
  assert.equal(plain.output, 'plain');
  let active = 0;
  let peak = 0;
  const overlapped = await hf('text(await Promise.all([tools.read({}), tools.read({})]))', {
    hasTool: name => name === 'read',
    callTool: async () => {
      active += 1;
      peak = Math.max(peak, active);
      await delay(20);
      active -= 1;
      return { ok: true, text: '{"value":1}' };
    },
  });
  assert.equal(overlapped.ok, true);
  assert.equal(overlapped.calls, 2);
  assert.equal(peak, 2);
  const mac = await hf('await tools.mac_step({})', {
    hasTool: () => true,
    callTool: async () => { await delay(40); return { ok: true, text: '1' }; },
  });
  assert.equal(mac.ok, true);
  assert.ok(mac.userWaitMs >= 30);
  const read = await hf('await tools.read({})', {
    hasTool: () => true,
    callTool: async () => { await delay(40); return { ok: true, text: '1' }; },
  });
  assert.equal(read.userWaitMs, 0);
});

test('exec catalogue keeps the run_script arguments and lists each tool', () => {
  assert.equal(uu.name, 'run_script');
  assert.equal(uu.parameters.required[0], 'code');
  const definition = gf([{
    name: 'fixture_read',
    description: 'Read a value',
    parameters: { type: 'object', required: ['value'], properties: { value: { type: 'number' }, note: { type: 'string' } } },
  }]);
  assert.equal(definition.name, 'exec');
  assert.equal(definition.parameters.required[0], 'code');
  assert.match(definition.description, /tools\.fixture_read\(\{value: number, note\?: string\}\): Read a value/);
  assert.match(definition.description, /up to 20,000 characters/);
});
