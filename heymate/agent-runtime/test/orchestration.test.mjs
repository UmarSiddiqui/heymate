import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile, mkdtemp, mkdir, rm } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import os from 'node:os';
import path from 'node:path';
import { runRecoveredScript, scriptTool } from '../src/script-tools.mjs';
import { earlyReads } from '../src/early-reads.mjs';
import { createModelAccess, createPiSession } from '../src/pi-session.mjs';
import { HeyMateHarness } from '../src/harness.mjs';
import { StepJournal } from '../src/step-journal.mjs';
import { saveJSON } from '../src/store.mjs';
import { AssistantMessageEventStream } from '@earendil-works/pi-ai/utils/event-stream';

const parameters = { type: 'object', properties: { value: { type: 'number' } }, required: ['value'], additionalProperties: false };
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));

test('original H1 script runner overlaps reads, parses results and prints bounded output', async () => {
  let active = 0, peak = 0;
  const result = await runRecoveredScript('text(await Promise.all([tools.read({}), tools.read({})])); text("x".repeat(25000));', {
    hasTool: name => name === 'read', callTool: async () => {
      active++; peak = Math.max(peak, active); await delay(15); active--;
      return { text: '{"value":1}', ok: true };
    }
  });
  assert.equal(result.ok, true); assert.equal(result.calls, 2); assert.equal(peak, 2);
  assert.match(result.output, /"value": 1/); assert.match(result.output, /cut at/); assert.ok(result.output.length < 20100);
});

test('script heap has no host filesystem/network and preserves tool errors', async () => {
  const options = { hasTool: name => name === 'failed', callTool: async () => ({ ok: false, text: 'Fixture refused' }) };
  const globals = await runRecoveredScript('return [typeof process, typeof require, typeof fetch, typeof Bun, typeof globalThis, typeof ({}).constructor.constructor("return this")().process];', options);
  assert.equal(globals.ok, true); assert.equal(JSON.parse(globals.output).every(value => value === 'undefined'), true);
  const failed = await runRecoveredScript('await tools.failed({})', options);
  assert.equal(failed.ok, false); assert.match(failed.output, /Fixture refused/);
  const unknown = await runRecoveredScript('await tools.missing({})', options);
  assert.equal(unknown.ok, false); assert.match(unknown.output, /There is no tool/);
});

test('script cancellation and CPU limits stop programs; fresh execution recovers', async () => {
  const spinning = await runRecoveredScript('while (true) {}', { hasTool: () => false, timeoutMs: 30 });
  assert.equal(spinning.ok, false); assert.match(spinning.output, /interrupted/);
  const abort = new AbortController();
  const waiting = runRecoveredScript('await new Promise(() => {})', { signal: abort.signal, hasTool: () => false });
  setTimeout(() => abort.abort(), 20);
  await assert.rejects(waiting, /cancelled/);
  assert.equal((await runRecoveredScript('return 7', { hasTool: () => false })).output, '7');
});

test('script adapter serializes writes and rejects invalid nested arguments', async () => {
  let active = 0, peak = 0, count = 0;
  const write = { name: 'fixture_write', parameters, executionMode: 'sequential', async execute(_id, { value }) {
    count++; active++; peak = Math.max(peak, active); await delay(15); active--;
    return { content: [{ type: 'text', text: String(value) }] };
  } };
  const tool = scriptTool([write]);
  const out = await tool.execute('script', { code: 'text(await Promise.all([tools.fixture_write({value:1}),tools.fixture_write({value:2})]));' });
  assert.equal(out.isError, false); assert.equal(count, 2); assert.equal(peak, 1);
  const bad = await tool.execute('bad', { code: 'await tools.fixture_write({value:"wrong"})' });
  assert.equal(bad.isError, true); assert.equal(count, 2);
});

test('unawaited script tools cancel and drain before reporting incomplete execution', async () => {
  let cancelled = false;
  const result = await runRecoveredScript('tools.read({}); return "too early";', {
    hasTool: () => true,
    callTool: (_name, _args, signal) => new Promise((_, reject) => {
      signal.addEventListener('abort', () => { cancelled = true; reject(new Error('fixture cancelled')); }, { once: true });
    })
  });
  assert.equal(result.ok, false); assert.match(result.output, /Await every tool call/); assert.equal(cancelled, true);
});

test('script timeout bounds non-cooperative tool cleanup and reports unknown outcome', async () => {
  const started = Date.now();
  await assert.rejects(runRecoveredScript('await tools.read({})', {
    hasTool: () => true, timeoutMs: 15,
    callTool: async () => { await delay(1400); return { ok: true, text: 'late' }; }
  }), /outcome is unknown/);
  assert.ok(Date.now() - started < 1350);
  // A late tool reply cannot touch its disposed interpreter.
  await delay(450);
  assert.equal((await runRecoveredScript('return 9', { hasTool: () => false })).output, '9');
});

test('H1 early reads start before stream end, run once and refuse inactive/browser/write tools', async () => {
  let calls = 0;
  const tool = { name: 'fixture_read', parameters, async execute() { calls++; await delay(5); return { content: [{ type: 'text', text: 'observed' }] }; } };
  const chrome = { ...tool, name: 'chrome' };
  const early = earlyReads([{ tool }, { tool: chrome, speculative: false }], { isActive: name => name !== 'inactive' });
  const event = (name, id, value = 1) => ({ type: 'message_update', assistantMessageEvent: { type: 'toolcall_end', toolCall: { type: 'toolCall', id, name, arguments: { value } } } });
  early.onEvent(event(tool.name, 'one')); early.onEvent(event(tool.name, 'one'));
  assert.equal(calls, 1);
  early.onEvent(event('chrome', 'two')); early.onEvent(event('write', 'three'));
  assert.equal(calls, 1);
  const result = await early.take('one', tool.name, { value: 1 });
  assert.equal(result.details.early, true); assert.equal(result.content[0].text, 'observed');
  await assert.rejects(early.take('one', tool.name, { value: 2 }), /identity changed/);
  early.reset(); assert.equal(await early.take('one', tool.name, { value: 1 }), null);
});

test('real Pi streams early reads then executes recovered script through approved write and journal', async t => {
  const root = await mkdtemp(path.join(os.tmpdir(), 'heymate-h1-port-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const home = path.join(root, 'Agent'); await mkdir(home);
  const workspace = path.join(root, 'work'); await mkdir(workspace);
  const access = await createModelAccess(home), artifact = path.join(workspace, 'script.txt');
  let rounds = 0, approvals = 0, reads = 0, streaming = false, startedDuringStream = false;
  const read = { name: 'fixture_read', label: 'Fixture read', description: 'Read synthetic value', parameters,
    async execute(_id, { value }) { reads++; startedDuringStream ||= streaming; await delay(8); return { content: [{ type: 'text', text: JSON.stringify({ value }) }] }; } };
  access.runtime.registerProvider('anthropic', { name: 'Fixture', api: 'openai-completions', baseUrl: 'http://127.0.0.1:1',
    models: [{ id: 'fixture', name: 'Fixture', reasoning: false, input: ['text'], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 32768, maxTokens: 1024 }],
    streamSimple: model => {
      rounds++;
      const content = rounds === 1 ? [{ type: 'toolCall', id: 'early1', name: 'fixture_read', arguments: { value: 1 } }]
        : rounds === 2 ? [{ type: 'toolCall', id: 'script1', name: 'exec', arguments: { code: `text(await Promise.all([tools.fixture_read({value:2}),tools.fixture_read({value:3})])); await tools.write({path:${JSON.stringify(artifact)},content:"through recovered H1"});` } }]
        : [{ type: 'text', text: 'Verified fixture final.' }];
      const message = { role: 'assistant', api: 'openai-completions', provider: 'anthropic', model: model.id, content,
        usage: { input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
        stopReason: rounds < 3 ? 'toolUse' : 'stop', timestamp: Date.now() };
      const stream = new AssistantMessageEventStream();
      queueMicrotask(async () => {
        streaming = true;
        stream.push({ type: 'start', partial: message });
        if (content[0].type === 'toolCall') stream.push({ type: 'toolcall_end', contentIndex: 0, toolCall: content[0], partial: message });
        await delay(25); streaming = false; stream.push({ type: 'done', reason: message.stopReason, message });
      });
      return stream;
    }
  });
  await access.credentials.modify('anthropic', async () => ({ type: 'oauth', access: 'fixture', refresh: 'fixture', expires: Date.now() + 3600000 }));
  await saveJSON(path.join(home, 'model.json'), { provider: 'anthropic', model: 'fixture' });
  const harness = new HeyMateHarness({ home, access, createSession: options => {
    const tools = [...options.tools, read]; Object.defineProperty(tools, 'batchReads', { value: [{ tool: read }] });
    return createPiSession({ ...options, tools });
  } });
  t.after(() => harness.close());
  const peer = { serverRequests: true, open: () => true, send(message) {
    if (message.method === 'approval') { approvals++; queueMicrotask(() => harness.answer(peer, { id: message.id, result: { choice: 'once' } })); }
  } };
  const { session_id: id } = await harness.dispatch(peer, 'session.create', { cwd: workspace });
  await harness.dispatch(peer, 'prompt.submit', { session_id: id, text: 'Run fixture' });
  const state = await harness.get(id); await state.run;
  assert.equal(state.record.rows.at(-1).content, 'Verified fixture final.');
  assert.equal(await readFile(artifact, 'utf8'), 'through recovered H1');
  assert.equal(approvals, 1); assert.equal(reads, 3); assert.equal(startedDuringStream, true);
  const journal = new StepJournal({ home, sessionID: id });
  assert.equal(journal.modelResults(state.record.activeTurnID).length, 3);
  assert.equal(journal.completedAnswer(state.record.activeTurnID), 'Verified fixture final.');
  const stats = await readFile(path.join(home, 'logs/request-stats.jsonl'), 'utf8');
  assert.match(stats, /"name":"write"/); assert.doesNotMatch(stats, /through recovered H1/);
  const readsLogged = stats.trim().split('\n').map(JSON.parse).filter(row => row.kind === 'tool_call' && row.name === 'fixture_read');
  assert.equal(readsLogged.length, 3);
  assert.equal(readsLogged.filter(row => row.early).length, 1);
  assert.ok(readsLogged.find(row => row.early).exec_ms >= 0);
});

test('restart restores only host-verified final checkpoint without invoking a session', async t => {
  const root = await mkdtemp(path.join(os.tmpdir(), 'heymate-h1-restart-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const home = path.join(root, 'Agent'); await mkdir(home);
  const harness = new HeyMateHarness({ home, access: {}, createSession() { throw new Error('Must not execute'); } });
  t.after(() => harness.close());
  const record = await harness.store.create(root);
  record.pending = true; record.activeTurnID = 'interrupted-turn'; record.rows = [{ id: 1, role: 'user', content: 'fixture' }];
  await harness.store.save(record);
  await new StepJournal({ home, sessionID: record.id }).checkpointAnswer({ turnID: record.activeTurnID, answer: 'Already verified.' });
  const state = await harness.get(record.id);
  assert.equal(state.record.pending, false); assert.equal(state.record.rows.at(-1).content, 'Already verified.');
  assert.equal((await harness.store.load(record.id)).rows.length, 2);
});
