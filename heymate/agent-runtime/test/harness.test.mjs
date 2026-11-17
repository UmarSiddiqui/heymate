import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, rm, readFile, stat } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { once } from 'node:events';
import { WebSocket } from 'ws';
import { HeyMateHarness } from '../src/harness.mjs';
import { startServer, sameToken, loginFailureReason } from '../src/server.mjs';
import { FileCredentials } from '../src/credentials.mjs';
import { createModelAccess, createPiSession } from '../src/pi-session.mjs';
import { saveJSON } from '../src/store.mjs';
import { AssistantMessageEventStream } from '@earendil-works/pi-ai/utils/event-stream';
import { writeFile } from 'node:fs/promises';
import { webToolDefinitions } from '../src/web-tools.mjs';
import { batchReadTool } from '../src/batch-reads.mjs';
import { continuationText } from '../src/continuation.mjs';
import { turnLimits } from '../src/pi-session.mjs';

async function fixture(t, createSession = async () => ({
  messages: [{ role: 'assistant', stopReason: 'stop' }],
  async prompt() {}, getLastAssistantText: () => 'Verified fixture answer', async abort() {}, dispose() {}
})) {
  const root = await mkdtemp(path.join(os.tmpdir(), 'heymate-pi-test-'));
  const home = path.join(root, 'agent'); await mkdir(home);
  t.after(() => rm(root, { recursive: true, force: true }));
  const workspace = path.join(home, 'work'); await mkdir(workspace);
  const access = { credentials: new FileCredentials(path.join(home, 'auth.json')),
    runtime: { getModels: () => [{ id: 'fixture' }], getModel: () => ({}), async refresh() {} } };
  const harness = new HeyMateHarness({ home, access, createSession });
  t.after(() => harness.close());
  const sent = [];
  const peer = { serverRequests: true, open: () => true, send: message => sent.push(message) };
  const created = await harness.dispatch(peer, 'session.create', { cwd: workspace });
  return { home, workspace, harness, access, peer, sent, id: created.session_id };
}

test('acceptance is distinct from persisted completion, with ordered replay', async t => {
  let release;
  const f = await fixture(t, async ({ emit }) => ({
    messages: [{ role: 'assistant', stopReason: 'stop' }],
    async prompt() { emit('message.delta', { text: 'Verified' }); await new Promise(r => { release = r; }); },
    getLastAssistantText: () => 'Verified answer', async abort() { release?.(); }, dispose() {}
  }));
  const accepted = await f.harness.dispatch(f.peer, 'prompt.submit', { session_id: f.id, text: 'Fixture' });
  assert.equal(accepted.status, 'streaming'); assert.equal(accepted.user_row_id, 1);
  const state = await f.harness.get(f.id);
  while (!release) await new Promise(setImmediate);
  assert.equal((await f.harness.messages(f.id, 1)).pagination.has_newer, true);
  release(); await state.run;
  assert.equal((await f.harness.messages(f.id, 1)).messages.at(-1).finish_reason, 'stop');
  const replay = await f.harness.dispatch(f.peer, 'session.events.since', { session_id: f.id, last_seen: 0 });
  assert.deepEqual(replay.events.map(e => e.seq), [1, 2]);
  assert.equal(replay.events.at(-1).type, 'message.complete');
});

test('unknown peer cannot use a session before resume', async t => {
  const f = await fixture(t);
  await assert.rejects(f.harness.dispatch({ send() {} }, 'prompt.submit', { session_id: f.id, text: 'Fixture' }));
  assert.equal((await f.harness.get(f.id)).running, false);
});

test('approval is one-time, denial and lost UI cannot approve', async t => {
  const f = await fixture(t), state = await f.harness.get(f.id);
  const pending = f.harness.approve(state, 'bash', { command: 'fixture' });
  const message = f.sent.at(-1);
  assert.equal(message.method, 'approval');
  f.harness.answer(f.peer, { id: message.id, result: { choice: 'deny' } });
  await assert.rejects(pending, /did not approve/);
  const allowed = f.harness.approve(state, 'write', { path: 'fixture' });
  f.harness.answer(f.peer, { id: f.sent.at(-1).id, result: { choice: 'once' } }); await allowed;
  const disconnected = f.harness.approve(state, 'bash', { command: 'fixture' });
  assert.equal(f.sent.at(-1).params.tool, 'bash');
  assert.equal(f.sent.at(-1).params.subject, 'fixture');
  f.harness.disconnect(f.peer); await assert.rejects(disconnected, /disconnected/);
  const cancels = state.events.filter(e => e.type === 'request.cancel');
  assert.equal(cancels.at(-1).payload.reason, 'disconnected');
  // An answered card closes without a reason, so the app shows nothing extra.
  assert.equal(cancels.at(0).payload.reason, undefined);
  await assert.rejects(f.harness.approve(state, 'bash', {}), /No native approval/);
});

test('cancellation waits for running tool loop and never reports success', async t => {
  let release;
  const f = await fixture(t, async () => ({ messages: [],
    prompt: () => new Promise(resolve => { release = resolve; }),
    async abort() { await new Promise(setImmediate); release?.(); },
    getLastAssistantText: () => 'Incomplete', dispose() {}
  }));
  await f.harness.dispatch(f.peer, 'prompt.submit', { session_id: f.id, text: 'Fixture' });
  while (!release) await new Promise(setImmediate);
  const reply = await f.harness.dispatch(f.peer, 'session.interrupt', { session_id: f.id });
  assert.equal(reply.status, 'interrupted'); assert.equal((await f.harness.get(f.id)).running, false);
  assert.equal(f.sent.at(-1).params.payload.status, 'interrupted');
  assert.equal((await f.harness.messages(f.id, 1)).messages.at(-1).finish_reason, 'aborted');
});

test('restart never replays a pending prompt or promotes it to success', async t => {
  const f = await fixture(t), state = await f.harness.get(f.id);
  state.record.pending = true;
  state.record.rows = [{ id: 1, role: 'user', content: 'Fixture' }]; await f.harness.store.save(state.record);
  const restarted = new HeyMateHarness({ home: f.home, access: f.access, createSession: () => { throw new Error('Must not execute'); } });
  t.after(() => restarted.close());
  await restarted.dispatch(f.peer, 'session.resume', { session_id: f.id });
  await assert.rejects(restarted.dispatch(f.peer, 'prompt.submit', { session_id: f.id, text: 'Duplicate' }), /not replayed/);
  assert.equal((await restarted.messages(f.id, 1)).pagination.has_newer, true);
});

test('session idempotency binds workspace and rejects traversal', async t => {
  const f = await fixture(t), key = randomUUID();
  const a = await f.harness.dispatch(f.peer, 'session.create', { cwd: f.workspace, idempotency_key: key });
  const b = await f.harness.dispatch(f.peer, 'session.create', { cwd: f.workspace, idempotency_key: key });
  assert.equal(a.session_id, b.session_id);
  await assert.rejects(f.harness.dispatch(f.peer, 'session.create', { cwd: f.home, idempotency_key: key }));
  await assert.rejects(f.harness.get('../auth'));
});

test('credential mutations serialize and metadata never contains secrets', async t => {
  const f = await fixture(t);
  await Promise.all(Array.from({ length: 8 }, () => f.access.credentials.modify('fixture', async old => {
    await new Promise(setImmediate); return { type: 'api_key', key: String(Number(old?.key ?? 0) + 1) };
  })));
  assert.equal((await f.access.credentials.read('fixture')).key, '8');
  assert.deepEqual(await f.access.credentials.list(), [{ providerId: 'fixture', type: 'api_key' }]);
  assert.equal((await stat(path.join(f.home, 'auth.json'))).mode & 0o777, 0o600);
});

test('HTTP and WebSocket require owner token and reject browser origins', async t => {
  const f = await fixture(t), token = 'fixture-token-'.repeat(4);
  const server = await startServer({ home: f.home, token, access: f.access }); t.after(() => server.close());
  const base = `http://127.0.0.1:${server.port}`;
  assert.equal((await fetch(base + '/api/status')).status, 401);
  assert.equal((await fetch(base + '/api/status', { headers: { 'X-HeyMate-Agent-Token': token, Origin: 'https://example.com' } })).status, 401);
  const status = await fetch(base + '/api/status', { headers: { 'X-HeyMate-Agent-Token': token } });
  assert.equal(status.status, 200); assert.equal((await status.json()).engine, 'pi');
  assert.equal(sameToken(token + 'x', token), false);
  const ws = new WebSocket(`ws://127.0.0.1:${server.port}/api/ws?token=${token}`);
  const ready = once(ws, 'message'); await once(ws, 'open');
  assert.equal(JSON.parse((await ready)[0]).params.type, 'gateway.ready');
  ws.close(); await once(ws, 'close');
});

test('real Pi SDK registers custom tools and gates file writes before execution', async t => {
  const f = await fixture(t), access = await createModelAccess(f.home);
  const model = access.runtime.getModels('anthropic').find(m => m.type === undefined || m.type === 'chat');
  assert.ok(model);
  await access.credentials.modify('anthropic', async () => ({ type: 'oauth', access: 'fixture', refresh: 'fixture', expires: Date.now() + 3600000 }));
  await saveJSON(path.join(f.home, 'model.json'), { provider: 'anthropic', model: model.id });
  const record = await f.harness.store.load(f.id);
  let allowed = false, approvalCount = 0;
  const session = await createPiSession({ home: f.home, record, access, tools: [], approve: async () => {
    approvalCount++; if (!allowed) throw new Error('Fixture denied');
  }, emit() {} });
  try {
    assert.equal(session.model.id, model.id);
    assert.ok(session.getActiveToolNames().includes('bash'));
    assert.ok(session.getActiveToolNames().includes('read'));
    assert.ok(record.sessionFile.startsWith(path.join(f.home, 'sessions')));
    assert.equal(session.messages.length, 0);
    const write = session.agent.state.tools.find(tool => tool.name === 'write');
    const file = path.join(f.workspace, 'approved.txt');
    await assert.rejects(write.execute('denied', { path: file, content: 'fixture' }), /Fixture denied/);
    await assert.rejects(readFile(file), { code: 'ENOENT' });
    allowed = true;
    await write.execute('allowed', { path: file, content: 'fixture' });
    assert.equal(await readFile(file, 'utf8'), 'fixture'); assert.equal(approvalCount, 2);
  } finally { session.dispose(); }
});

test('custom harness drives real Pi tool loop, approval and durable follow-up with a fixture provider', async t => {
  const f = await fixture(t), access = await createModelAccess(f.home);
  const artifact = path.join(f.workspace, 'pi-result.txt');
  const missing = path.join(f.workspace, 'private-source', 'review-input.txt');
  let rounds = 0, followUpSawHistory = false;
  access.runtime.registerProvider('anthropic', { name: 'In-process test provider', api: 'openai-completions',
    baseUrl: 'http://127.0.0.1:1', models: [{ id: 'fixture', name: 'Fixture', reasoning: false,
      input: ['text'], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 32768, maxTokens: 1024 }],
    streamSimple: (model, context) => {
      rounds++;
      if (rounds === 3) followUpSawHistory = JSON.stringify(context).includes('Create fixture artifact');
      const stream = new AssistantMessageEventStream();
      const message = { role: 'assistant', api: 'openai-completions', provider: 'anthropic', model: model.id,
        content: rounds === 1 ? [
          { type: 'toolCall', id: 'fixture-write', name: 'write', arguments: { path: artifact, content: 'Created through Pi' } },
          { type: 'toolCall', id: 'fixture-read', name: 'read', arguments: { path: missing } }
        ]
          : [{ type: 'text', text: rounds === 2 ? 'Artifact verified.' : 'History retained.' }],
        usage: { input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2,
          cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
        stopReason: rounds === 1 ? 'toolUse' : 'stop', timestamp: Date.now() };
      queueMicrotask(() => { stream.push({ type: 'done', reason: message.stopReason, message }); });
      return stream;
    } });
  await access.credentials.modify('anthropic', async () => ({ type: 'oauth', access: 'fixture', refresh: 'fixture', expires: Date.now() + 3600000 }));
  await saveJSON(path.join(f.home, 'model.json'), { provider: 'anthropic', model: 'fixture' });
  const harness = new HeyMateHarness({ home: f.home, access, createSession: createPiSession });
  t.after(() => harness.close());
  const progress = [];
  const peer = { serverRequests: true, open: () => true, send: message => {
    if (message.method === 'approval') queueMicrotask(() => harness.answer(peer, { id: message.id, result: { choice: 'once' } }));
    if (message.method === 'event' && message.params?.payload?.tool_call_id === 'fixture-read') progress.push(message.params);
  } };
  const { session_id: id } = await harness.dispatch(peer, 'session.create', { cwd: f.workspace });
  await harness.dispatch(peer, 'prompt.submit', { session_id: id, text: 'Create fixture artifact' });
  await (await harness.get(id)).run;
  assert.equal(await readFile(artifact, 'utf8'), 'Created through Pi');
  assert.deepEqual(progress.map(event => [event.type, event.payload]), [
    ['tool.start', { name: 'read', tool_call_id: 'fixture-read', file_name: 'review-input.txt' }],
    ['tool.end', { name: 'read', tool_call_id: 'fixture-read', is_error: true, failure_code: 'missing_file' }]
  ]);
  assert.equal((await harness.messages(id, 1)).messages.at(-1).content, 'Artifact verified.');
  await harness.dispatch(peer, 'prompt.submit', { session_id: id, text: 'What did we do?' });
  await (await harness.get(id)).run;
  assert.equal((await harness.messages(id, 3)).messages.at(-1).content, 'History retained.');
  assert.equal(followUpSawHistory, true);
});

test('Brain offers subscription and API access, rejects unknown providers and mismatched credential types', async t => {
  const f = await fixture(t);
  const inventory = await f.harness.dispatch(f.peer, 'model.options');
  assert.deepEqual(inventory.providers.map(p => p.slug), ['openai-codex', 'anthropic', 'heymate-custom']);
  await assert.rejects(f.harness.dispatch(f.peer, 'model.save_key', { slug: 'anthropic', api_key: 'fixture' }));
  await assert.rejects(f.harness.modelSet({ provider: 'unknown', model: 'fixture' }));
  await f.access.credentials.modify('anthropic', async () => ({ type: 'api_key', key: 'fixture' }));
  await assert.rejects(f.harness.modelSet({ provider: 'anthropic' }));
  assert.equal((await f.harness.dispatch(f.peer, 'model.options')).providers[1].authenticated, false);
  await saveJSON(path.join(f.home, 'model.json'), { provider: 'anthropic', model: 'fixture' });
  assert.equal((await f.harness.dispatch(f.peer, 'setup.runtime_check')).ok, false);
  await assert.rejects(createPiSession({ home: f.home, record: await f.harness.store.load(f.id), access: f.access }));
});

for (const provider of ['openai-codex', 'anthropic']) {
  test(`${provider} OAuth completes through owner HTTP flow and automatically selects subscription`, async t => {
    const f = await fixture(t);
    f.access.runtime.login = async (slug, type, interaction) => {
      assert.equal(slug, provider); assert.equal(type, 'oauth');
      if (provider === 'anthropic') {
        assert.equal(await interaction.prompt({ type: 'select', options: [{ id: 'browser' }, { id: 'copy_code' }] }), 'copy_code');
        interaction.notify({ type: 'auth_url', url: 'https://claude.ai/oauth/authorize?state=fixture&code_challenge=fixture' });
        assert.equal(await interaction.prompt({ type: 'manual_code' }), 'fixture#state');
      } else {
        assert.equal(await interaction.prompt({ type: 'select', options: [{ id: 'device_code' }] }), 'device_code');
        interaction.notify({ type: 'device_code', verificationUri: 'https://auth.openai.com/codex/device', userCode: 'ABCD-EFGH', expiresInSeconds: 900 });
      }
      await f.access.credentials.modify(provider, async () => ({ type: 'oauth', access: 'fixture', refresh: 'fixture', expires: Date.now() + 3600000 }));
    };
    const token = 'owner-token-for-subscription-test-123456';
    const server = await startServer({ home: f.home, token, access: f.access });
    t.after(() => server.close());
    const request = async (route, method = 'GET', data) => {
      const response = await fetch(`http://127.0.0.1:${server.port}${route}`, { method,
        headers: { 'X-HeyMate-Agent-Token': token }, body: data && JSON.stringify(data) });
      assert.equal(response.status, 200); return response.json();
    };
    const start = await request(`/api/providers/oauth/${provider}/start`, 'POST');
    assert.equal(start.flow, provider === 'anthropic' ? 'authorization_code' : 'device_code');
    if (provider === 'anthropic') await request(`/api/providers/oauth/sessions/${start.session_id}/code`, 'POST', { code: 'fixture#state' });
    let status;
    for (let attempt = 0; attempt < 100; attempt++) {
      status = (await request(`/api/providers/oauth/${provider}/poll/${start.session_id}`)).status;
      if (status !== 'pending') break;
      await new Promise(resolve => setTimeout(resolve, 5));
    }
    assert.equal(status, 'approved');
    assert.deepEqual(JSON.parse(await readFile(path.join(f.home, 'model.json'), 'utf8')), { provider, model: 'fixture', effort: 'off', speed: 'default' });
    assert.equal((await server.harness.dispatch(f.peer, 'setup.runtime_check')).ok, true);
  });
}

test('sign-in failures report fixed reasons and never echo provider bodies', async t => {
  assert.equal(loginFailureReason(new Error('Token exchange request failed. details=HTTP request failed. status=400; body=private-fixture')), 'code_rejected');
  assert.equal(loginFailureReason(new Error('OAuth state mismatch')), 'code_mismatch');
  assert.equal(loginFailureReason(new Error('Missing authorization code')), 'code_missing');
  assert.equal(loginFailureReason(new Error('Token exchange request failed. details=fetch failed')), 'network');
  assert.equal(loginFailureReason(new Error('private-fixture')), 'unknown');
  const f = await fixture(t);
  f.access.runtime.login = async (slug, type, interaction) => {
    await interaction.prompt({ type: 'select', options: [{ id: 'copy_code' }] });
    interaction.notify({ type: 'auth_url', url: 'https://claude.ai/oauth/authorize?state=fixture&code_challenge=fixture' });
    await interaction.prompt({ type: 'manual_code' });
    throw new Error('Token exchange request failed. details=HTTP request failed. status=400; body=private-fixture');
  };
  const token = 'owner-token-for-subscription-test-123456';
  const server = await startServer({ home: f.home, token, access: f.access });
  t.after(() => server.close());
  const request = async (route, method = 'GET', data) => {
    const response = await fetch(`http://127.0.0.1:${server.port}${route}`, { method,
      headers: { 'X-HeyMate-Agent-Token': token }, body: data && JSON.stringify(data) });
    assert.equal(response.status, 200); return response.json();
  };
  const start = await request('/api/providers/oauth/anthropic/start', 'POST');
  await request(`/api/providers/oauth/sessions/${start.session_id}/code`, 'POST', { code: 'fixture#state' });
  let poll;
  for (let attempt = 0; attempt < 100; attempt++) {
    poll = await request(`/api/providers/oauth/anthropic/poll/${start.session_id}`);
    if (poll.status !== 'pending') break;
    await new Promise(resolve => setTimeout(resolve, 5));
  }
  assert.deepEqual(poll, { session_id: start.session_id, status: 'error', reason: 'code_rejected' });
});

test('subscription switch closes idle model session and keeps durable chat history', async t => {
  const f = await fixture(t), state = await f.harness.get(f.id);
  let disposed = false;
  state.session = { dispose() { disposed = true; } };
  state.record.rows = [{ id: 1, role: 'user', content: 'Keep context' }];
  await f.harness.store.save(state.record);
  await f.access.credentials.modify('anthropic', async () => ({ type: 'oauth', access: 'fixture', refresh: 'fixture', expires: Date.now() + 3600000 }));
  await f.harness.modelSet({ provider: 'anthropic' });
  assert.equal(disposed, true); assert.equal(state.session, null);
  assert.equal((await f.harness.store.load(f.id)).rows[0].content, 'Keep context');
});

test('one Pi session serves a chat until instructions change, receiving system and seed', async t => {
  const created = [];
  const f = await fixture(t, async options => {
    created.push({ system: options.system, seed: options.seed });
    return { messages: [{ role: 'assistant', stopReason: 'stop' }], async prompt() {},
      getLastAssistantText: () => 'Answer', async abort() {}, dispose() {} };
  });
  const seed = [{ role: 'user', content: 'Earlier question' }, { role: 'assistant', content: 'Earlier answer' }];
  const turn = async (text, system) => {
    await f.harness.dispatch(f.peer, 'prompt.submit', { session_id: f.id, text, system, seed });
    await (await f.harness.get(f.id)).run;
  };
  await turn('First', 'Mate A'); await turn('Second', 'Mate A');
  assert.equal(created.length, 1);
  assert.deepEqual(created[0], { system: 'Mate A', seed });
  await turn('Third', 'Mate B');
  assert.equal(created.length, 2); assert.equal(created[1].system, 'Mate B');
  const rows = (await f.harness.messages(f.id, 1)).messages.filter(row => row.role === 'user');
  assert.deepEqual(rows.map(row => row.content), ['First', 'Second', 'Third']);
  await assert.rejects(f.harness.dispatch(f.peer, 'prompt.submit', { session_id: f.id, text: 'x', seed: [{ role: 'system', content: 'x' }] }), /Invalid chat history/);
});

test('failed turn surfaces a redacted reason and logs it privately', async t => {
  const f = await fixture(t, async () => ({ messages: [{ role: 'assistant', stopReason: 'error', errorMessage: '401 invalid key sk-abcdefghijklmnop' }],
    async prompt() {}, getLastAssistantText: () => '', async abort() {}, dispose() {} }));
  const events = [];
  f.peer.send = message => events.push(message);
  await f.harness.dispatch(f.peer, 'prompt.submit', { session_id: f.id, text: 'Fixture' });
  await (await f.harness.get(f.id)).run;
  const complete = events.map(e => e.params).find(e => e?.type === 'message.complete');
  assert.equal(complete.payload.status, 'error');
  assert.match(complete.payload.error, /Reason: 401 invalid key sk-\[redacted\]/);
  const row = (await f.harness.messages(f.id, 1)).messages.at(-1);
  assert.equal(row.display_kind, 'failed_turn'); assert.match(row.error_detail, /401/);
  const log = await readFile(path.join(f.home, 'logs', 'turn-failures.log'), 'utf8');
  assert.match(log, /401 invalid key/); assert.doesNotMatch(log, /abcdefghijklmnop/);
  assert.equal((await stat(path.join(f.home, 'logs', 'turn-failures.log'))).mode & 0o777, 0o600);
});

test('real Pi puts instructions in the system prompt, seeds history once and forwards progress', async t => {
  const f = await fixture(t), access = await createModelAccess(f.home);
  const contexts = [];
  access.runtime.registerProvider('anthropic', { name: 'In-process test provider', api: 'openai-completions',
    baseUrl: 'http://127.0.0.1:1', models: [{ id: 'fixture', name: 'Fixture', reasoning: true,
      input: ['text'], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 32768, maxTokens: 1024 }],
    streamSimple: (model, context) => {
      contexts.push(JSON.parse(JSON.stringify(context)));
      const stream = new AssistantMessageEventStream();
      const message = { role: 'assistant', api: 'openai-completions', provider: 'anthropic', model: model.id,
        content: [{ type: 'thinking', thinking: 'Considering' }, { type: 'text', text: `Reply ${contexts.length}` }],
        usage: { input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2,
          cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
        stopReason: 'stop', timestamp: Date.now() };
      queueMicrotask(() => {
        stream.push({ type: 'start', partial: { ...message, content: [] } });
        stream.push({ type: 'thinking_start', contentIndex: 0, partial: message });
        stream.push({ type: 'done', reason: 'stop', message });
      });
      return stream;
    } });
  await access.credentials.modify('anthropic', async () => ({ type: 'oauth', access: 'fixture', refresh: 'fixture', expires: Date.now() + 3600000 }));
  await saveJSON(path.join(f.home, 'model.json'), { provider: 'anthropic', model: 'fixture' });
  const harness = new HeyMateHarness({ home: f.home, access, createSession: createPiSession });
  t.after(() => harness.close());
  const events = [];
  const peer = { serverRequests: true, open: () => true, send: message => events.push(message.params?.type) };
  const { session_id: id } = await harness.dispatch(peer, 'session.create', { cwd: f.workspace });
  const seed = [{ role: 'user', content: 'My product is Fixturely' }, { role: 'assistant', content: 'Noted Fixturely' }];
  for (const text of ['First question', 'Second question']) {
    await harness.dispatch(peer, 'prompt.submit', { session_id: id, text, system: 'MATE IDENTITY: Captain', seed });
    await (await harness.get(id)).run;
  }
  assert.equal(contexts.length, 2);
  // Pi carries the system prompt as a system message; the identity is its addendum.
  for (const context of contexts) {
    assert.match(JSON.stringify(context.messages.filter(m => m.role === 'system')), /MATE IDENTITY: Captain/);
  }
  const second = JSON.stringify(contexts[1].messages.filter(m => m.role !== 'system'));
  assert.equal(second.split('My product is Fixturely').length - 1, 1);
  assert.ok(second.includes('Noted Fixturely') && second.includes('Reply 1'));
  assert.doesNotMatch(second, /MATE IDENTITY/);
  assert.ok(events.includes('agent.thinking'));
  assert.equal((await harness.messages(id, 1)).messages.at(-1).content, 'Reply 2');
});

test('connector writes are keyed, ledgered and never repeated; reads run in parallel', async t => {
  const f = await fixture(t), state = await f.harness.get(f.id);
  const calls = [];
  f.harness.bridges.set('hm_fixture', { peer: f.peer, sessionID: f.id, tools: [
    { name: 'send', inputSchema: { type: 'object' } },
    { name: 'list', inputSchema: { type: 'object' }, annotations: { readOnlyHint: true } }],
    client: { async close() {}, callTool: async request => { calls.push(request); return { content: [{ type: 'text', text: `sent ${calls.length}` }] }; } } });
  state.bridgeNames.add('hm_fixture'); state.running = true;
  const tools = await f.harness.tools(state);
  const send = tools.find(tool => tool.name === 'hm_fixture_send'), list = tools.find(tool => tool.name === 'hm_fixture_list');
  assert.equal(send.executionMode, 'sequential'); assert.equal(list.executionMode, undefined);
  await list.execute('read-1', {});
  assert.equal(calls[0]._meta, undefined);
  const first = await send.execute('call-1', { to: 'a@example.com' });
  const again = await send.execute('call-1', { to: 'a@example.com' });
  assert.equal(calls.length, 2); assert.equal(calls[1]._meta['heymate/idempotency_key'], `${f.id}:call-1`);
  assert.equal(first.content[0].text, 'sent 2'); assert.match(again.content[0].text, /Already done earlier/);
  const saved = await f.harness.store.load(f.id);
  assert.deepEqual(saved.effects.map(e => [e.tool, e.status]), [['hm_fixture_send', 'done']]);
  assert.match(f.harness.effectsNote(state), /hm_fixture_send .*a@example.com.*receipt: sent 2/);
  state.record.effects.push({ key: `${f.id}:call-2`, tool: 'hm_fixture_send', target: '{}', status: 'started' });
  await assert.rejects(send.execute('call-2', {}), /outcome is unknown/);
  assert.equal(calls.length, 2);
});

test('task continuation reuses persisted effects across scopes and skips duplicate approval', async t => {
  let writes = 0, approvals = 0;
  const workID = randomUUID();
  const createSession = async ({ sideEffect }) => ({
    messages: [{ role: 'assistant', stopReason: 'stop' }],
    async prompt(text) {
      const initial = text === 'initial';
      const tool = initial ? 'hm_123456789abc_create_draft' : 'hm_abcdef123456_create_draft';
      const args = initial ? { recipient: 'fixture', data: { a: 1, b: 2 } }
        : { data: { b: 2, a: 1 }, recipient: 'fixture' };
      const result = await sideEffect(tool, args, text, async () => {
        writes++;
        return { content: [{ type: 'text', text: 'draft receipt' }] };
      }, () => { approvals++; });
      this.answer = result.content[0].text;
    },
    getLastAssistantText() { return this.answer; }, async abort() {}, dispose() {}
  });
  const f = await fixture(t, createSession);
  const submit = async (harness, text, id, continuation) => {
    await harness.dispatch(f.peer, 'prompt.submit', {
      session_id: f.id, text, work_id: id, work_continuation: continuation
    });
    await (await harness.get(f.id)).run;
    return (await harness.store.load(f.id)).rows.at(-1).content;
  };
  assert.equal(await submit(f.harness, 'initial', workID, false), 'draft receipt');
  const restarted = new HeyMateHarness({ home: f.home, access: f.access, createSession });
  t.after(() => restarted.close());
  await restarted.dispatch(f.peer, 'session.resume', { session_id: f.id });
  assert.match(await submit(restarted, 'retry', workID, true), /Already done earlier.*draft receipt/);
  assert.equal(writes, 1);
  assert.equal(approvals, 1);
  assert.equal(await submit(restarted, 'other task', randomUUID(), false), 'draft receipt');
  assert.equal(writes, 2);
  assert.equal(approvals, 2);
});

test('both browser tools fetch fresh snapshots when a task resumes', async t => {
  const f = await fixture(t), state = await f.harness.get(f.id);
  const reads = [];
  f.harness.bridges.set('hm_123456789abc', { peer: f.peer, sessionID: f.id, tools: [
    { name: 'use_browser', inputSchema: { type: 'object' } },
    { name: 'use_chrome', inputSchema: { type: 'object' } }
  ], client: { async close() {}, async callTool(request) {
    assert.equal(request._meta, undefined);
    reads.push(request.name);
    return { content: [{ type: 'text', text: `Page ${reads.length}` }] };
  } } });
  state.bridgeNames.add('hm_123456789abc');
  Object.assign(state, { running: true });
  Object.assign(state.record, { activeWorkID: randomUUID(), activeTurnID: randomUUID() });
  const tools = await f.harness.tools(state);
  const args = { op: 'snapshot', tab_id: 7 };
  for (const tool of tools.slice(0, 2)) await tool.execute(`initial-${tool.name}`, args);
  Object.assign(state.record, { activeTurnID: randomUUID(), workContinuation: true });
  for (const [index, tool] of tools.slice(0, 2).entries()) {
    const result = await tool.execute(`resumed-${tool.name}`, args);
    assert.equal(result.content[0].text, `Page ${index + 3}`);
  }
  assert.deepEqual(reads, ['use_browser', 'use_chrome', 'use_browser', 'use_chrome']);
});

test('task continuation holds uncertain writes and retries actions declined before execution', async t => {
  const f = await fixture(t), state = await f.harness.get(f.id);
  Object.assign(state.record, { activeWorkID: randomUUID(), activeTurnID: randomUUID() });
  await assert.rejects(f.harness.sideEffect(state, 'write', { path: 'uncertain' }, 'first',
    async () => { throw new Error('Connection lost'); }), /Connection lost/);
  await assert.rejects(f.harness.sideEffect(state, 'write', { path: 'declined' }, 'second',
    () => assert.fail('Should not execute after denial'), () => { throw new Error('Declined'); }), /Declined/);
  Object.assign(state.record, { activeTurnID: randomUUID(), workContinuation: true });
  await assert.rejects(f.harness.sideEffect(state, 'write', { path: 'uncertain' }, 'retry-first',
    () => assert.fail('Should not repeat an uncertain write')), /outcome is unknown/);
  let writes = 0;
  await f.harness.sideEffect(state, 'write', { path: 'declined' }, 'retry-second', () => { writes++; });
  assert.equal(writes, 1);
});

test('a message sent mid-turn steers the running turn instead of being rejected', async t => {
  let release; const steered = [];
  const f = await fixture(t, async () => ({ messages: [{ role: 'assistant', stopReason: 'stop' }],
    prompt: () => new Promise(resolve => { release = resolve; }), async steer(text) { steered.push(text); },
    getLastAssistantText: () => 'Both handled', async abort() { release?.(); }, dispose() {} }));
  await assert.rejects(f.harness.dispatch(f.peer, 'session.steer', { session_id: f.id, text: 'Early' }), /No running turn/);
  await f.harness.dispatch(f.peer, 'prompt.submit', { session_id: f.id, text: 'First' });
  while (!release) await new Promise(setImmediate);
  const reply = await f.harness.dispatch(f.peer, 'session.steer', { session_id: f.id, text: 'Also check B' });
  assert.deepEqual(reply, { status: 'queued', user_row_id: 2 }); assert.deepEqual(steered, ['Also check B']);
  release(); await (await f.harness.get(f.id)).run;
  const rows = (await f.harness.messages(f.id, 1)).messages;
  assert.deepEqual(rows.map(row => [row.role, row.content]), [['user', 'First'], ['user', 'Also check B'], ['assistant', 'Both handled']]);
});

async function piFixture(t, reply, limits) {
  const f = await fixture(t), access = await createModelAccess(f.home);
  const contexts = [];
  access.runtime.registerProvider('anthropic', { name: 'In-process test provider', api: 'openai-completions',
    baseUrl: 'http://127.0.0.1:1', models: [{ id: 'fixture', name: 'Fixture', reasoning: false,
      input: ['text'], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 32768, maxTokens: 1024 }],
    streamSimple: (model, context) => {
      contexts.push(JSON.stringify(context));
      const content = reply(contexts.length, context);
      const stream = new AssistantMessageEventStream();
      const toolUse = content.some(part => part.type === 'toolCall');
      const message = { role: 'assistant', api: 'openai-completions', provider: 'anthropic', model: model.id, content,
        usage: { input: 3, output: 2, cacheRead: 1, cacheWrite: 0, totalTokens: 5, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
        stopReason: toolUse ? 'toolUse' : 'stop', timestamp: Date.now() };
      queueMicrotask(() => stream.push({ type: 'done', reason: message.stopReason, message }));
      return stream;
    } });
  await access.credentials.modify('anthropic', async () => ({ type: 'oauth', access: 'fixture', refresh: 'fixture', expires: Date.now() + 3600000 }));
  await saveJSON(path.join(f.home, 'model.json'), { provider: 'anthropic', model: 'fixture' });
  const harness = new HeyMateHarness({ home: f.home, access, createSession: options => createPiSession({ ...options, limits }) });
  t.after(() => harness.close());
  const peer = { serverRequests: true, open: () => true, send() {} };
  const { session_id: id } = await harness.dispatch(peer, 'session.create', { cwd: f.workspace });
  return { ...f, harness, peer, id, contexts };
}

test('a runaway turn is nudged to wrap up at 80% and stopped at its step limit with stats logged', async t => {
  const f = await piFixture(t, () => [{ type: 'toolCall', id: `read-${randomUUID()}`, name: 'read', arguments: { path: 'missing.txt' } }],
    { steps: 5, ms: 60000, nudgeAt: 0.8 });
  await f.harness.dispatch(f.peer, 'prompt.submit', { session_id: f.id, text: 'Loop forever' });
  await (await f.harness.get(f.id)).run;
  const row = (await f.harness.messages(f.id, 1)).messages.at(-1);
  assert.equal(row.display_kind, 'failed_turn'); assert.match(row.error_detail, /step limit/);
  assert.ok(f.contexts.at(-1).includes('close to its time or step limit'));
  assert.ok(f.contexts.length <= 7);
  const stats = (await readFile(path.join(f.home, 'logs', 'turn-stats.jsonl'), 'utf8')).trim().split('\n').map(line => JSON.parse(line));
  const limited = stats.find(entry => entry.limit);
  assert.equal(limited.nudged, true); assert.match(limited.limit, /step limit/);
  assert.ok(limited.usage.input >= 15 && limited.usage.cacheRead >= 5);
  assert.match(row.content, /ran out of time/); assert.doesNotMatch(row.content, /model access/);
});

test('a turn stopped by its limit still answers from what it already found', async t => {
  const f = await piFixture(t, (round, context) => JSON.stringify(context).includes('Tools are now off')
    ? [{ type: 'text', text: 'Found your post with 6 comments; could not read them in time.' }]
    : [{ type: 'toolCall', id: `read-${randomUUID()}`, name: 'read', arguments: { path: 'missing.txt' } }],
    { steps: 3, ms: 60000, nudgeAt: 0.8 });
  await f.harness.dispatch(f.peer, 'prompt.submit', { session_id: f.id, text: 'Find my Reddit post' });
  await (await f.harness.get(f.id)).run;
  const row = (await f.harness.messages(f.id, 1)).messages.at(-1);
  assert.notEqual(row.display_kind, 'failed_turn');
  assert.match(row.content, /6 comments/);
});

test('time spent waiting on the user for an answer does not count against the turn', async t => {
  const f = await piFixture(t, n => n === 1
    ? [{ type: 'toolCall', id: 'ask-1', name: 'ask_user', arguments: { question: 'Which color?' } }]
    : [{ type: 'text', text: 'Blue it is.' }], { steps: 20, ms: 300, nudgeAt: 0.8 });
  f.peer.send = message => {
    if (message.method === 'clarify') setTimeout(() => f.harness.answer(f.peer, { id: message.id, result: { answers: { answer: 'Blue' } } }), 600);
  };
  await f.harness.dispatch(f.peer, 'prompt.submit', { session_id: f.id, text: 'Pick a color with me' });
  await (await f.harness.get(f.id)).run;
  const row = (await f.harness.messages(f.id, 1)).messages.at(-1);
  assert.notEqual(row.display_kind, 'failed_turn');
  assert.match(row.content, /Blue it is/);
});

test('after compaction the side-effect ledger comes from the durable record, not the summary', async t => {
  const f = await piFixture(t, (round, context) => [{ type: 'text', text: JSON.stringify(context).includes('Summarize') || round === 2 ? 'Goal: fixture summary' : `Reply ${round}` }],
    { steps: 60, ms: 60000, nudgeAt: 0.8 });
  const state = await f.harness.get(f.id);
  state.record.effects = [{ key: `${f.id}:fixture`, tool: 'hm_gmail_send', target: '{"to":"boss@example.com"}', status: 'done', receipt: 'id 42' }];
  for (const text of ['Send the report', 'More', 'Even more']) {
    await f.harness.dispatch(f.peer, 'prompt.submit', { session_id: f.id, text: `${text} ${'context '.repeat(5000)}` });
    await state.run;
  }
  assert.doesNotMatch(f.contexts[0], /Side effects already done/);
  if (!state.session.messages.some(message => message.role === 'compactionSummary')) await state.session.compact();
  await f.harness.dispatch(f.peer, 'prompt.submit', { session_id: f.id, text: 'Did it go out?' });
  await state.run;
  assert.match(f.contexts.at(-1), /Side effects already done.*hm_gmail_send.*boss@example.com.*receipt: id 42/);
  assert.equal((await f.harness.messages(f.id, 1)).messages.at(-1).finish_reason, 'stop');
});

test('ask_user offers choices, records the answer and keeps it past compaction', async t => {
  const f = await fixture(t), state = await f.harness.get(f.id);
  f.peer.send = message => {
    f.sent.push(message);
    if (message.method === 'clarify') queueMicrotask(() => f.harness.answer(f.peer, { id: message.id, result: { answers: { answer: 'Blue' } } }));
  };
  const ask = (await f.harness.tools(state)).find(tool => tool.name === 'ask_user');
  const result = await ask.execute('q1', { question: 'Which color?', choices: ['Blue', 'Red', '', 7] });
  assert.deepEqual(f.sent.find(m => m.method === 'clarify').params.questions, [{ qid: 'answer', question: 'Which color?', choices: ['Blue', 'Red'] }]);
  assert.equal(result.content[0].text, 'User answered: Blue');
  assert.equal((await f.harness.store.load(f.id)).answers[0].answer, 'Blue');
  assert.match(f.harness.effectsNote(state), /Q: Which color\? A: Blue/);
  f.peer.send = message => { if (message.method === 'clarify') queueMicrotask(() => f.harness.answer(f.peer, { id: message.id, result: { answers: { answer: null } } })); };
  assert.match((await ask.execute('q2', { question: 'Size?' })).content[0].text, /gave no answer/);
  f.peer.send = message => {
    if (message.method === 'clarify') queueMicrotask(() => f.harness.answer(f.peer, { id: message.id, result: { deferred: true } }));
  };
  const deferred = await ask.execute('q3', { question: 'Which region?' });
  assert.match(deferred.content[0].text, /filed in Waiting on You/);
  assert.equal(state.record.answers.length, 1, 'filing the question must not invent a user answer');
});

test('note tools keep one live markdown note per chat in the Notes folder', async t => {
  const f = await fixture(t), state = await f.harness.get(f.id);
  const tool = async name => (await f.harness.tools(state)).find(item => item.name === name);
  const text = result => result.content[0].text;
  assert.match(text(await (await tool('note_tick')).execute('t0', { item: 'x' })), /no note yet/);
  assert.equal(text(await (await tool('note')).execute('n1', { md: '# Lisbon\n\n## In short\n- [ ] Pick a hotel {now}\n- [ ] Dinner' })), 'Saved.');
  assert.equal(text(await (await tool('note_tick')).execute('n2', { item: 'Pick a hotel', next: 'Dinner' })), 'Saved.');
  assert.match(text(await (await tool('note_replace')).execute('n3', { find: 'nothing like this at all', md: 'x' })), /Couldn't find/);
  const noteID = (await f.harness.store.load(f.id)).noteID;
  assert.match(noteID, /^[0-9A-F-]{36}$/);
  const md = await readFile(path.join(f.harness.notesFolder, `${noteID}.md`), 'utf8');
  assert.match(md, /- \[x\] Pick a hotel\n- \[ \] Dinner \{now\}/);
});

test('a steer message can carry images attached during the running turn', async t => {
  let release; const steered = [];
  const f = await fixture(t, async () => ({ messages: [{ role: 'assistant', stopReason: 'stop' }],
    prompt: () => new Promise(resolve => { release = resolve; }), async steer(text, images) { steered.push([text, images?.length ?? 0]); },
    getLastAssistantText: () => 'Seen', async abort() { release?.(); }, dispose() {} }));
  await f.harness.dispatch(f.peer, 'prompt.submit', { session_id: f.id, text: 'First' });
  while (!release) await new Promise(setImmediate);
  await f.harness.dispatch(f.peer, 'image.attach_bytes', { session_id: f.id, filename: 'image.png', content_base64: Buffer.from('png').toString('base64') });
  await f.harness.dispatch(f.peer, 'session.steer', { session_id: f.id, text: 'Look at this' });
  assert.deepEqual(steered, [['Look at this', 1]]);
  assert.equal((await f.harness.get(f.id)).images.length, 0);
  release(); await (await f.harness.get(f.id)).run;
});

test('incremental note edits serialize, survive restart and can be read back', async t => {
  const f = await fixture(t), state = await f.harness.get(f.id);
  await f.harness.editNote(state, 'note', { md: '# Comparison\n\n## Options\n| Name | Cost |\n| --- | --- |\n| Alpha | $10 |\n\n## Plan\n- [ ] Compare\n- [ ] Decide\n' });
  await Promise.all([
    f.harness.editNote(state, 'note_add', { after: '## Options', md: '| Beta | $20 |' }),
    f.harness.editNote(state, 'note_replace', { find: '$10', md: '$12' }),
    f.harness.editNote(state, 'note_remove', { find: '| Beta |', why: 'Over budget' }),
    f.harness.editNote(state, 'note_tick', { item: 'Compare', next: 'Decide' }),
    f.harness.editNote(state, 'note_answer', { line: 'Choose Alpha', big: '$12', aside: 'Within budget' })
  ]);
  const markdown = await f.harness.readNote(state);
  assert.match(markdown, /Alpha \| \$12/); assert.match(markdown, /Beta.*\{out\}/);
  assert.match(markdown, /\[x\] Compare/); assert.match(markdown, /\[ \] Decide \{now\}/);
  assert.match(markdown, /> Choose Alpha \{big="\$12" note="Within budget"\}/);
  const restarted = new HeyMateHarness({ home: f.home, access: f.access, createSession: async () => ({}) });
  t.after(() => restarted.close());
  const resumed = await restarted.get(f.id);
  assert.equal(resumed.record.noteID, state.record.noteID);
  const readTool = (await restarted.tools(resumed)).find(tool => tool.name === 'note_read');
  assert.equal((await readTool.execute('read', {})).content[0].text, markdown);
  const file = f.harness.noteFile(state);
  assert.equal((await stat(file)).mode & 0o777, 0o600);
  const other = await f.harness.dispatch(f.peer, 'session.create', { cwd: f.workspace });
  assert.equal(await f.harness.readNote(await f.harness.get(other.session_id)), '');
});

test('note replay deduplicates saved edits, resumes after rename, and refuses changed call identities', async t => {
  const f = await fixture(t), state = await f.harness.get(f.id);
  await f.harness.editNote(state, 'note', { md: '# Replay\n\n## Findings\n' }, 'start');
  const args = { after: '', md: 'One finding' };
  await f.harness.editNote(state, 'note_add', args, 'append');
  await f.harness.editNote(state, 'note_add', args, 'append');
  assert.equal((await f.harness.readNote(state)).match(/One finding/g).length, 1);
  await assert.rejects(f.harness.editNote(state, 'note_add', { after: '', md: 'different' }, 'append'), /different arguments/);
  const receipt = state.record.noteReceipts.find(r => r.id === 'append');
  receipt.status = 'started'; receipt.markdown = await f.harness.readNote(state);
  await f.harness.store.save(state.record);
  const restarted = new HeyMateHarness({ home: f.home, access: f.access });
  t.after(() => restarted.close());
  const restored = await restarted.get(f.id);
  await restarted.editNote(restored, 'note_add', args, 'append');
  assert.equal((await restarted.readNote(restored)).match(/One finding/g).length, 1);
});
test('live previews do not commit saved Markdown and close before tool execution', async t => {
  const f = await fixture(t), state = await f.harness.get(f.id); state.running = true;
  await f.harness.previewNote(state, { id: 'n1', name: 'note', arguments: { md: '# Live\nPartial content' } });
  assert.equal(await f.harness.readNote(state), '');
  const file = path.join(f.harness.notesFolder, `${state.record.noteID}.preview.json`);
  assert.match(JSON.parse(await readFile(file, 'utf8')).markdown, /Partial/);
  const tool = (await f.harness.tools(state)).find(t => t.name === 'note');
  await tool.execute('n1', { md: '# Live\nSaved content' });
  await f.harness.previewNote(state, { id: 'n1', name: 'note', arguments: { md: 'late stale preview' } });
  await assert.rejects(readFile(file), { code: 'ENOENT' });
  assert.match(await f.harness.readNote(state), /Saved content/);
});
test('note closing pass is bounded, note-only and preserves original answer', async t => {
  let prompts = 0, active = ['read', 'bash', 'note'];
  const f = await fixture(t, async () => ({
    messages: [{ role: 'assistant', stopReason: 'stop' }],
    async prompt() {
      prompts++;
      if (prompts === 1) await f.harness.editNote(await f.harness.get(f.id), 'note', { md: '# Work\n- [ ] Pending {now}\n' });
      else { assert.ok(!active.includes('bash')); await f.harness.editNote(await f.harness.get(f.id), 'note', { md: '# Work\n> Still blocked\n- [ ] Pending\n' }); }
    },
    getActiveToolNames: () => active, setActiveToolsByName: names => { active = names; },
    getLastAssistantText: () => prompts === 1 ? 'Original verified result' : 'Note finished',
    async abort() {}, dispose() {}
  }));
  await f.harness.dispatch(f.peer, 'prompt.submit', { session_id: f.id, text: 'Work' });
  await (await f.harness.get(f.id)).run;
  assert.equal(prompts, 2); assert.deepEqual(active, ['read', 'bash', 'note']);
  assert.equal((await f.harness.get(f.id)).record.rows.at(-1).content, 'Original verified result');
});

test('text written before the first tool call is emitted as an opener, apart from the answer', async t => {
  const f = await piFixture(t, n => n === 1
    ? [{ type: 'text', text: 'Checking that file now.' }, { type: 'toolCall', id: 'read-1', name: 'read', arguments: { path: 'missing.txt' } }]
    : [{ type: 'text', text: 'The file is missing.' }], { steps: 20, ms: 60000, nudgeAt: 0.8 });
  const events = [];
  f.peer.send = message => { if (message.method === 'event') events.push(message.params); };
  await f.harness.dispatch(f.peer, 'prompt.submit', { session_id: f.id, text: 'Read missing.txt' });
  await (await f.harness.get(f.id)).run;
  const openers = events.filter(event => event.type === 'agent.opener');
  assert.deepEqual(openers.map(event => event.payload.text), ['Checking that file now.']);
  assert.equal((await f.harness.messages(f.id, 1)).messages.at(-1).content, 'The file is missing.');
  assert.ok(f.contexts[0].includes('Reply first'));
});

// Built-in web tools in the harness and real Pi (web-tools.mjs).
test('web tools are batch reads in every chat and batch_read can group them', async t => {
  const root = await mkdtemp(path.join(os.tmpdir(), 'heymate-web-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const home = path.join(root, 'agent'); await mkdir(home, { recursive: true });
  const access = { credentials: new FileCredentials(path.join(home, 'auth.json')), runtime: { getModels: () => [], getModel: () => ({}) } };
  const harness = new HeyMateHarness({ home, access, createSession: async () => ({}) });
  t.after(() => harness.close());
  const peer = { serverRequests: true, open: () => true, send() {} };
  const { session_id: id } = await harness.dispatch(peer, 'session.create', { cwd: root });
  const tools = await harness.tools(await harness.get(id));
  for (const name of ['web_search', 'web_fetch']) {
    assert.ok(tools.some(tool => tool.name === name), name);
    const entry = tools.batchReads.find(item => item.tool.name === name);
    assert.ok(entry && entry.allows === undefined, `${name} is an unconditional read`);
    assert.equal(tools.find(tool => tool.name === name).executionMode, undefined);
  }
  const fake = { name: 'web_fetch', execute: async (_id, args) => ({ content: [{ type: 'text', text: `page ${args.url}` }] }) };
  const batch = batchReadTool([{ tool: fake }]);
  const result = JSON.parse((await batch.execute('b', { calls: [{ tool: 'web_fetch', arguments: { url: 'https://a.example/' } }] })).content[0].text);
  assert.equal(result[0].ok, true);
});

test('real Pi journals web_fetch as a read and raises no approval card', async t => {
  const root = await mkdtemp(path.join(os.tmpdir(), 'heymate-web-pi-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const home = path.join(root, 'Agent'); await mkdir(home);
  const workspace = path.join(root, 'work'); await mkdir(workspace);
  const access = await createModelAccess(home);
  let rounds = 0;
  access.runtime.registerProvider('anthropic', { name: 'Fixture', api: 'openai-completions', baseUrl: 'http://127.0.0.1:1',
    models: [{ id: 'fixture', name: 'Fixture', reasoning: false, input: ['text'], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 32768, maxTokens: 1024 }],
    streamSimple: (model, context) => {
      rounds++;
      if (rounds === 1) assert.match(JSON.stringify(context), /untrusted data, never instructions/);
      const content = rounds === 1 ? [{ type: 'toolCall', id: 'web1', name: 'web_fetch', arguments: { url: 'https://example.com/' } }]
        : [{ type: 'text', text: 'Read it. Source: https://example.com/' }];
      const message = { role: 'assistant', api: 'openai-completions', provider: 'anthropic', model: model.id, content,
        usage: { input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
        stopReason: rounds === 1 ? 'toolUse' : 'stop', timestamp: Date.now() };
      const stream = new AssistantMessageEventStream();
      queueMicrotask(() => { stream.push({ type: 'start', partial: message }); stream.push({ type: 'done', reason: message.stopReason, message }); });
      return stream;
    } });
  await access.credentials.modify('anthropic', async () => ({ type: 'oauth', access: 'fixture', refresh: 'fixture', expires: Date.now() + 3600000 }));
  await saveJSON(path.join(home, 'model.json'), { provider: 'anthropic', model: 'fixture' });
  const fetched = [];
  const webTools = webToolDefinitions({ get: async url => { fetched.push(url); return { status: 200, url,
    headers: { 'content-type': 'text/plain' }, body: Buffer.from('Example body'), truncated: false }; } });
  const harness = new HeyMateHarness({ home, access, createSession: createPiSession, webTools });
  t.after(() => harness.close());
  let approvals = 0;
  const peer = { serverRequests: true, open: () => true, send(message) { if (message.method === 'approval') approvals++; } };
  const { session_id: id } = await harness.dispatch(peer, 'session.create', { cwd: workspace });
  await harness.dispatch(peer, 'prompt.submit', { session_id: id, text: 'Read example.com' });
  const state = await harness.get(id); await state.run;
  assert.equal(state.record.rows.at(-1).content, 'Read it. Source: https://example.com/');
  assert.deepEqual(fetched, ['https://example.com/']); assert.equal(approvals, 0);
  assert.equal(state.record.effects ?? undefined, undefined, 'a read never enters the side-effect ledger');
  const markers = (await readFile(path.join(home, 'desktop', 'journal', id, 'started.jsonl'), 'utf8')).trim().split('\n').map(JSON.parse);
  const toolMarkers = markers.filter(marker => marker.kind !== 'model');
  assert.equal(toolMarkers.length, 1); assert.equal(toolMarkers[0].kind, 'read');
});

// Long runs: checkpoint and continuation turns (continuation.mjs).
async function continuationFixture(t, createSession) {
  const root = await mkdtemp(path.join(os.tmpdir(), 'heymate-continue-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const home = path.join(root, 'agent'); await mkdir(home);
  const workspace = path.join(home, 'work'); await mkdir(workspace);
  const access = { credentials: new FileCredentials(path.join(home, 'auth.json')), runtime: { getModels: () => [], getModel: () => ({}) } };
  const harness = new HeyMateHarness({ home, access, createSession });
  t.after(() => harness.close());
  const sent = [];
  const peer = { serverRequests: true, open: () => true, send: message => sent.push(message) };
  const { session_id: id } = await harness.dispatch(peer, 'session.create', { cwd: workspace });
  return { harness, peer, sent, id, home, workspace };
}

const limitedSession = kind => async () => {
  const session = { messages: [], limitReached: null, limitKind: null,
    async prompt() {
      session.messages.push({ role: 'assistant', stopReason: 'aborted' });
      session.limitReached = 'Turn step limit reached before a final answer.'; session.limitKind = kind;
    },
    getLastAssistantText: () => 'partial', async abort() {}, dispose() {} };
  return session;
};

test('a turn out of steps ends at a checkpoint the client can continue from', async t => {
  const f = await continuationFixture(t, limitedSession('steps'));
  await f.harness.dispatch(f.peer, 'prompt.submit', { session_id: f.id, text: 'Long task', allow_continuation: true });
  const state = await f.harness.get(f.id); await state.run;
  const complete = state.events.find(event => event.type === 'message.complete');
  assert.deepEqual(complete.payload, { status: 'complete', text: continuationText, continuation: true, limit: 'steps' });
  assert.equal(state.record.pending, false); assert.equal(state.running, false);
  assert.equal(state.record.rows.at(-1).display_kind, 'continuation');
  assert.equal(state.session.continues, true, 'wrap-up nudge is off while continuations remain');
  // The next turn is accepted on the same session.
  await f.harness.dispatch(f.peer, 'prompt.submit', { session_id: f.id, text: 'Continue', allow_continuation: false });
  await state.run;
  assert.equal(state.session.continues, false);
  const last = state.events.filter(event => event.type === 'message.complete').at(-1);
  assert.equal(last.payload.status, 'error', 'without continuations left the old salvage path answers (here: none)');
  assert.equal(last.payload.continuation, undefined);
});

test('a stalled turn is never continued, and the flag must be boolean', async t => {
  const f = await continuationFixture(t, limitedSession('stall'));
  await f.harness.dispatch(f.peer, 'prompt.submit', { session_id: f.id, text: 'Task', allow_continuation: true });
  const state = await f.harness.get(f.id); await state.run;
  const complete = state.events.find(event => event.type === 'message.complete');
  assert.equal(complete.payload.status, 'error'); assert.equal(complete.payload.continuation, undefined);
  await assert.rejects(f.harness.dispatch(f.peer, 'prompt.submit', { session_id: f.id, text: 'x', allow_continuation: 'yes' }), /continuation/);
});

test('real Pi: a step-limited turn checkpoints without a wrap-up nudge and the continuation never repeats an action', async t => {
  const root = await mkdtemp(path.join(os.tmpdir(), 'heymate-continue-pi-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const home = path.join(root, 'Agent'); await mkdir(home);
  const workspace = path.join(root, 'work'); await mkdir(workspace);
  const access = await createModelAccess(home);
  const target = path.join(workspace, 'out.txt');
  let rounds = 0;
  const contexts = [];
  access.runtime.registerProvider('anthropic', { name: 'Fixture', api: 'openai-completions', baseUrl: 'http://127.0.0.1:1',
    models: [{ id: 'fixture', name: 'Fixture', reasoning: false, input: ['text'], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 32768, maxTokens: 1024 }],
    streamSimple: (model, context) => {
      rounds++;
      const text = JSON.stringify(context.messages);
      contexts.push(text);
      const lastUser = [...context.messages].reverse().find(message => message.role === 'user');
      const continuing = JSON.stringify(lastUser ?? '').includes('CONTINUE-FIXTURE');
      const toolResults = context.messages.filter(message => message.role === 'toolResult').length;
      // Turn 1 writes once and then keeps reading; the continuation retries the same write once, then answers.
      const content = continuing
        ? (toolResults < 4 ? [{ type: 'toolCall', id: `again${rounds}`, name: 'write', arguments: { path: target, content: 'once' } }]
          : [{ type: 'text', text: 'Finished after continuing.' }])
        : rounds === 1 ? [{ type: 'toolCall', id: 'w1', name: 'write', arguments: { path: target, content: 'once' } }]
          : [{ type: 'toolCall', id: `r${rounds}`, name: 'read', arguments: { path: target } }];
      const message = { role: 'assistant', api: 'openai-completions', provider: 'anthropic', model: model.id, content,
        usage: { input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
        stopReason: content[0].type === 'toolCall' ? 'toolUse' : 'stop', timestamp: Date.now() };
      const stream = new AssistantMessageEventStream();
      queueMicrotask(() => { stream.push({ type: 'start', partial: message }); stream.push({ type: 'done', reason: message.stopReason, message }); });
      return stream;
    } });
  await access.credentials.modify('anthropic', async () => ({ type: 'oauth', access: 'fixture', refresh: 'fixture', expires: Date.now() + 3600000 }));
  await saveJSON(path.join(home, 'model.json'), { provider: 'anthropic', model: 'fixture' });
  const harness = new HeyMateHarness({ home, access, webTools: [],
    createSession: options => createPiSession({ ...options, limits: { ...turnLimits, steps: 3 } }) });
  t.after(() => harness.close());
  let approvals = 0;
  const peer = { serverRequests: true, open: () => true, send(message) {
    if (message.method === 'approval') { approvals++; queueMicrotask(() => harness.answer(peer, { id: message.id, result: { choice: 'once' } })); }
  } };
  const { session_id: id } = await harness.dispatch(peer, 'session.create', { cwd: workspace });
  const workID = '0F2C3A1E-1B2C-4D5E-8F90-123456789ABC';
  await harness.dispatch(peer, 'prompt.submit', { session_id: id, text: 'Long task', allow_continuation: true, work_id: workID, work_continuation: false });
  const state = await harness.get(id); await state.run;
  const first = state.events.filter(event => event.type === 'message.complete').at(-1);
  assert.equal(first.payload.continuation, true); assert.equal(first.payload.limit, 'steps');
  assert.ok(!contexts.some(text => text.includes('close to its time or step limit')), 'no wrap-up nudge while continuing');
  assert.equal(approvals, 1);
  await writeFile(target, 'changed by someone else');
  await harness.dispatch(peer, 'prompt.submit', { session_id: id, text: 'CONTINUE-FIXTURE', allow_continuation: true, work_id: workID, work_continuation: true });
  await state.run;
  const last = state.events.filter(event => event.type === 'message.complete').at(-1);
  assert.equal(last.payload.text, 'Finished after continuing.'); assert.equal(last.payload.continuation, undefined);
  // The repeated write in the continuation returned the earlier receipt instead of running again.
  assert.equal(approvals, 1);
  assert.equal(state.record.effects.filter(effect => effect.tool === 'write' && effect.status === 'done').length, 1);
  assert.ok(contexts.at(-1).includes('Already done earlier'));
});
