import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, rm, readFile, stat } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { once } from 'node:events';
import { WebSocket } from 'ws';
import { HeyMateHarness } from '../src/harness.mjs';
import { startServer, sameToken } from '../src/server.mjs';
import { FileCredentials } from '../src/credentials.mjs';
import { createModelAccess, createPiSession } from '../src/pi-session.mjs';
import { saveJSON } from '../src/store.mjs';
import { AssistantMessageEventStream } from '@earendil-works/pi-ai/utils/event-stream';

async function fixture(t, createSession = async () => ({
  messages: [{ role: 'assistant', stopReason: 'stop' }],
  async prompt() {}, getLastAssistantText: () => 'Verified fixture answer', async abort() {}, dispose() {}
})) {
  const home = await mkdtemp(path.join(os.tmpdir(), 'heymate-pi-test-'));
  t.after(() => rm(home, { recursive: true, force: true }));
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
  f.harness.disconnect(f.peer); await assert.rejects(disconnected, /disconnected/);
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
  let rounds = 0, followUpSawHistory = false;
  access.runtime.registerProvider('anthropic', { name: 'In-process test provider', api: 'openai-completions',
    baseUrl: 'http://127.0.0.1:1', models: [{ id: 'fixture', name: 'Fixture', reasoning: false,
      input: ['text'], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 32768, maxTokens: 1024 }],
    streamSimple: (model, context) => {
      rounds++;
      if (rounds === 3) followUpSawHistory = JSON.stringify(context).includes('Create fixture artifact');
      const stream = new AssistantMessageEventStream();
      const message = { role: 'assistant', api: 'openai-completions', provider: 'anthropic', model: model.id,
        content: rounds === 1 ? [{ type: 'toolCall', id: 'fixture-write', name: 'write', arguments: { path: artifact, content: 'Created through Pi' } }]
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
  const peer = { serverRequests: true, open: () => true, send: message => {
    if (message.method === 'approval') queueMicrotask(() => harness.answer(peer, { id: message.id, result: { choice: 'once' } }));
  } };
  const { session_id: id } = await harness.dispatch(peer, 'session.create', { cwd: f.workspace });
  await harness.dispatch(peer, 'prompt.submit', { session_id: id, text: 'Create fixture artifact' });
  await (await harness.get(id)).run;
  assert.equal(await readFile(artifact, 'utf8'), 'Created through Pi');
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
    assert.deepEqual(JSON.parse(await readFile(path.join(f.home, 'model.json'), 'utf8')), { provider, model: 'fixture', effort: 'off' });
    assert.equal((await server.harness.dispatch(f.peer, 'setup.runtime_check')).ok, true);
  });
}

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
  assert.ok(f.contexts.length <= 6);
  const stats = (await readFile(path.join(f.home, 'logs', 'turn-stats.jsonl'), 'utf8')).trim().split('\n').map(line => JSON.parse(line));
  assert.equal(stats.at(-1).nudged, true); assert.match(stats.at(-1).limit, /step limit/);
  assert.ok(stats.at(-1).usage.input >= 15 && stats.at(-1).usage.cacheRead >= 5);
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
