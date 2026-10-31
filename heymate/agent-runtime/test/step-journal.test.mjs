import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, readFile, stat, appendFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { StepJournal } from '../src/step-journal.mjs';

async function fixture(t) {
  const home = await mkdtemp(path.join(tmpdir(), 'heymate-step-journal-'));
  t.after(() => rm(home, { recursive: true, force: true }));
  const options = { home, sessionID: 'test-chat' };
  return { home, options, open: () => new StepJournal(options) };
}

test('recovered completed steps survive restart without calling the tool again', async t => {
  const f = await fixture(t);
  let calls = 0;
  const call = { name: 'write', id: 'call-1', kind: 'write', args: { path: '/synthetic' } };
  const value = { content: [{ type: 'text', text: 'Saved.' }], details: {} };
  assert.deepEqual(await f.open().run(call, async () => { calls++; return value; }), value);
  assert.deepEqual(await f.open().run(call, async () => { calls++; return 'wrong'; }), value);
  assert.equal(calls, 1);
  const folder = path.join(f.home, 'desktop/journal/test-chat');
  assert.equal((await stat(folder)).mode & 0o777, 0o700);
  for (const name of ['started.jsonl', 'steps.jsonl']) assert.equal((await stat(path.join(folder, name))).mode & 0o777, 0o600);
});

test('concurrent duplicates share one recovered tool execution', async t => {
  const f = await fixture(t), journal = f.open();
  let calls = 0;
  const execute = async () => { calls++; await new Promise(resolve => setTimeout(resolve, 20)); return { text: 'read result' }; };
  const call = { name: 'read', id: 'read-1', args: { path: '/synthetic' } };
  const results = await Promise.all([journal.run(call, execute), journal.run(call, execute)]);
  assert.equal(calls, 1);
  assert.deepEqual(results[0], results[1]);
  assert.throws(() => journal.run({ ...call, args: { path: '/different' } }, execute), /identity reused/);
});

test('process exit after a write starts leaves unknown outcome and refuses replay', async t => {
  const f = await fixture(t);
  const module = new URL('../src/step-journal.mjs', import.meta.url).href;
  const code = `import { StepJournal } from ${JSON.stringify(module)};
    const journal = new StepJournal(JSON.parse(process.env.JOURNAL_OPTIONS));
    await journal.run({ name: 'connector_write', id: 'write-1', kind: 'write' }, async () => process.exit(7));`;
  const child = spawnSync(process.execPath, ['--input-type=module', '-e', code], {
    env: { ...process.env, JOURNAL_OPTIONS: JSON.stringify(f.options) }, encoding: 'utf8'
  });
  assert.equal(child.status, 7, child.stderr);
  let executed = false;
  assert.throws(() => f.open().run({ name: 'connector_write', id: 'write-1', kind: 'write' }, async () => { executed = true; }), /outcome is unknown/);
  assert.equal(executed, false);
});

test('interrupted read can run again after restart; write retry policy never retries writes', async t => {
  const f = await fixture(t);
  const module = new URL('../src/step-journal.mjs', import.meta.url).href;
  const child = spawnSync(process.execPath, ['--input-type=module', '-e', `
    import { StepJournal } from ${JSON.stringify(module)};
    await new StepJournal(JSON.parse(process.env.JOURNAL_OPTIONS)).run({ name: 'read', id: 'read-1' }, async () => process.exit(7));
  `], { env: { ...process.env, JOURNAL_OPTIONS: JSON.stringify(f.options) } });
  assert.equal(child.status, 7);
  assert.equal(await f.open().run({ name: 'read', id: 'read-1' }, async () => 'fresh'), 'fresh');
  let attempts = 0;
  await assert.rejects(f.open().run({ name: 'write', id: 'write-fails', kind: 'write', policy: { retries: { limit: 3 } } }, async () => {
    attempts++; throw new Error('synthetic write failure');
  }), /synthetic write failure/);
  assert.equal(attempts, 1);
});

test('source retry policy runs reads again then records their completed result', async t => {
  const f = await fixture(t);
  let attempts = 0;
  const call = { name: 'read', id: 'read-retries', policy: { retries: { limit: 2, delay: '0 seconds' } } };
  assert.equal(await f.open().run(call, async () => {
    if (++attempts < 3) throw Error('synthetic transient read failure');
    return 'recovered result';
  }), 'recovered result');
  assert.equal(attempts, 3);
  assert.equal(await f.open().run(call, async () => assert.fail('replayed callback ran')), 'recovered result');
});

test('completed failures replay with redacted text and corruption fails closed', async t => {
  const f = await fixture(t);
  const call = { name: 'read', id: 'bad-result' };
  await assert.rejects(f.open().run(call, async () => { throw Error('Bearer abcdefghijklmnop'); }), /\[redacted\]/);
  await assert.rejects(f.open().run(call, async () => assert.fail('failed call repeated')), /\[redacted\]/);
  const file = path.join(f.home, 'desktop/journal/test-chat/steps.jsonl');
  assert.doesNotMatch(await readFile(file, 'utf8'), /abcdefghijklmnop/);
  await appendFile(file, '{broken json}\n');
  assert.throws(() => f.open(), SyntaxError);
});

test('complete model outcome checkpoints survive restart and remain scoped to their turn', async t => {
  const f = await fixture(t);
  const message = { role: 'assistant', stopReason: 'stop', content: [{ type: 'text', text: 'Verified final answer.' }], timestamp: 12345 };
  await f.open().checkpointModel({ id: 'turn-one:model-1', turnID: 'turn-one', message });
  assert.deepEqual(f.open().modelResults('turn-one'), [message]);
  assert.deepEqual(f.open().modelResults('turn-two'), []);
});

test('torn final append is discarded without discarding valid records or replaying unknown writes', async t => {
  const f = await fixture(t);
  await f.open().run({ name: 'read', id: 'read-1' }, async () => 'complete');
  const file = path.join(f.home, 'desktop/journal/test-chat/steps.jsonl');
  await appendFile(file, '{"key":"do:partial');
  assert.equal(await f.open().run({ name: 'read', id: 'read-1' }, async () => assert.fail('complete read replayed')), 'complete');
  assert.equal(await f.open().run({ name: 'read', id: 'read-2' }, async () => 'next'), 'next');
  assert.equal(await f.open().run({ name: 'read', id: 'read-2' }, async () => assert.fail('next read replayed')), 'next');
  assert.doesNotMatch(await readFile(file, 'utf8'), /partial/);
});

test('native answer recovery requires an explicit validated answer checkpoint', async t => {
  const f = await fixture(t);
  const journal = f.open();
  await journal.checkpointModel({ id: 'turn-one:model-1', turnID: 'turn-one', message: {
    role: 'assistant', stopReason: 'stop', content: [{ type: 'text', text: 'An unverified stop message.' }]
  } });
  assert.equal(f.open().completedAnswer('turn-one'), null);
  await journal.checkpointAnswer({ turnID: 'turn-one', answer: 'Verified answer before note finishing.' });
  await journal.checkpointModel({ id: 'turn-one:model-2', turnID: 'turn-one', message: {
    role: 'assistant', stopReason: 'stop', content: [{ type: 'text', text: 'Done.' }]
  } });
  assert.equal(f.open().completedAnswer('turn-one'), 'Verified answer before note finishing.');
  assert.equal(f.open().completedAnswer('turn-two'), null);
  assert.throws(() => journal.checkpointAnswer({ turnID: 'turn-two', answer: ' ' }), /Invalid final-answer/);
});

test('non-retryable errors stop retries and survive restart', async t => {
  const f = await fixture(t);
  let attempts = 0;
  const call = { name: 'read', id: 'non-retryable', policy: { retries: { limit: 2 } } };
  await assert.rejects(f.open().run(call, async () => {
    attempts++;
    const error = new Error('cannot retry'); error.name = 'NonRetryableError'; throw error;
  }), /cannot retry/);
  await assert.rejects(f.open().run(call, async () => assert.fail('replayed')), /cannot retry/);
  assert.equal(attempts, 1);
});

test('write without a serializable result remains uncertain across restart', async t => {
  const f = await fixture(t);
  const call = { name: 'write', id: 'empty', kind: 'write' };
  await assert.rejects(f.open().run(call, async () => undefined), /no serializable result/);
  assert.throws(() => f.open().run(call, async () => assert.fail('write repeated')), /outcome is unknown/);
});

test('cancellation during read retry does not record a completed result', async t => {
  const f = await fixture(t), abort = new AbortController();
  const call = { name: 'read', id: 'cancelled-retry', signal: abort.signal,
    policy: { retries: { limit: 2, delay: '1 second' } } };
  const promise = f.open().run(call, async () => { setTimeout(() => abort.abort(), 5); throw new Error('retry'); });
  await assert.rejects(promise);
  assert.equal(await f.open().run({ name: 'read', id: 'cancelled-retry' }, async () => 'recovered'), 'recovered');
});
