import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, rm, writeFile, readFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { HeyMateHarness } from '../src/harness.mjs';
import { FileCredentials } from '../src/credentials.mjs';
import { createModelAccess, createPiSession } from '../src/pi-session.mjs';
import { saveJSON } from '../src/store.mjs';
import { heartbeatEffort, heartbeatLimits, heartbeatOptions, heartbeatTools } from '../src/heartbeat.mjs';

const tool = name => ({ name, label: name, description: name, parameters: { type: 'object' },
  execute: async () => ({ content: [{ type: 'text', text: name }] }) });

test('heartbeat tool set keeps only unconditional reads, whatever a connector claims', () => {
  const read = tool('hm_x_calendar_list'), write = tool('hm_x_send_email'), browser = tool('hm_x_use_chrome');
  const lying = tool('hm_x_send_to_mate');
  const tools = [read, write, browser, lying, tool('note'), tool('note_add'), tool('note_read'), tool('ask_user'),
    tool('web_search'), tool('web_fetch')];
  Object.defineProperty(tools, 'batchReads', { value: [{ tool: read }, { tool: browser, allows: () => true }, { tool: lying },
    { tool: tools[8] }, { tool: tools[9] }] });
  const kept = heartbeatTools(tools);
  assert.deepEqual(kept.map(t => t.name).sort(), ['hm_x_calendar_list', 'note_read', 'web_fetch', 'web_search']);
  assert.deepEqual(kept.batchReads.map(e => e.tool.name).sort(), ['hm_x_calendar_list', 'web_fetch', 'web_search']);
});

test('heartbeat options are validated', () => {
  assert.equal(heartbeatOptions(undefined), null);
  assert.deepEqual(heartbeatOptions({ read_root: '/Users/x/Mate' }), { readRoot: '/Users/x/Mate' });
  assert.deepEqual(heartbeatOptions({}), { readRoot: null });
  assert.throws(() => heartbeatOptions({ read_root: 'relative' }), /Invalid heartbeat/);
  assert.throws(() => heartbeatOptions('yes'), /Invalid heartbeat/);
});

test('a heartbeat submit runs on a read-only, bounded session that never continues', async t => {
  const root = await mkdtemp(path.join(os.tmpdir(), 'heymate-heartbeat-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const home = path.join(root, 'agent'); await mkdir(home);
  const access = { credentials: new FileCredentials(path.join(home, 'auth.json')), runtime: { getModels: () => [], getModel: () => ({}) } };
  const created = [];
  const harness = new HeyMateHarness({ home, access, createSession: async options => {
    created.push(options);
    return { messages: [{ role: 'assistant', stopReason: 'stop' }], async prompt() {},
      getLastAssistantText: () => '{"proposals":[]}', async abort() {}, dispose() {} };
  } });
  t.after(() => harness.close());
  const peer = { serverRequests: true, open: () => true, send() {} };
  const { session_id: id } = await harness.dispatch(peer, 'session.create', { cwd: root });
  await assert.rejects(harness.dispatch(peer, 'prompt.submit', { session_id: id, text: 'Check in', heartbeat: { read_root: 'nope' } }), /Invalid heartbeat/);
  await harness.dispatch(peer, 'prompt.submit', { session_id: id, text: 'Check in', heartbeat: { read_root: root }, allow_continuation: true });
  const state = await harness.get(id); await state.run;
  assert.equal(state.allowContinuation, false);
  assert.equal(created.length, 1);
  assert.deepEqual(created[0].heartbeat, { readRoot: root });
  assert.equal(created[0].limits, heartbeatLimits);
  assert.ok(heartbeatLimits.steps < 60 && heartbeatLimits.ms < 280000);
  const names = created[0].tools.map(t => t.name);
  for (const forbidden of ['ask_user', 'note', 'note_add']) assert.ok(!names.includes(forbidden), forbidden);
  for (const allowed of ['note_read', 'web_search', 'web_fetch']) assert.ok(names.includes(allowed), allowed);
  // The next ordinary turn gets a fresh, full session.
  await harness.dispatch(peer, 'prompt.submit', { session_id: id, text: 'Normal turn' });
  await state.run;
  assert.equal(created.length, 2);
  assert.equal(created[1].heartbeat, null);
  assert.ok(created[1].tools.some(t => t.name === 'ask_user'));
});

test('real Pi heartbeat session exposes no write, edit, bash or exec, and reads only its own folder', async t => {
  const root = await mkdtemp(path.join(os.tmpdir(), 'heymate-heartbeat-pi-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const home = path.join(root, 'agent'); await mkdir(home);
  const folder = path.join(root, 'Mate'); await mkdir(folder);
  const outside = path.join(root, 'secret.txt');
  await writeFile(path.join(folder, 'plan.md'), 'Ship the report');
  await writeFile(outside, 'private');
  const access = await createModelAccess(home);
  const model = access.runtime.getModels('anthropic').find(m => m.type === undefined || m.type === 'chat');
  assert.ok(model);
  await access.credentials.modify('anthropic', async () => ({ type: 'oauth', access: 'fixture', refresh: 'fixture', expires: Date.now() + 3600000 }));
  await saveJSON(path.join(home, 'model.json'), { provider: 'anthropic', model: model.id, effort: 'high' });
  const harness = new HeyMateHarness({ home, access, createSession: createPiSession });
  t.after(() => harness.close());
  const peer = { serverRequests: true, open: () => true, send() {} };
  const { session_id: id } = await harness.dispatch(peer, 'session.create', { cwd: root });
  const state = await harness.get(id);
  const tools = heartbeatTools(await harness.tools(state));
  const session = await createPiSession({ home, record: state.record, access, tools, approve: async () => { throw new Error('never'); },
    emit() {}, heartbeat: { readRoot: folder }, limits: heartbeatLimits });
  try {
    const active = session.getActiveToolNames();
    for (const forbidden of ['bash', 'write', 'edit', 'exec', 'ask_user', 'note', 'note_add']) assert.ok(!active.includes(forbidden), forbidden);
    for (const allowed of ['read', 'batch_read', 'web_search', 'web_fetch', 'note_read']) assert.ok(active.includes(allowed), allowed);
    assert.equal(session.thinkingLevel, heartbeatEffort(model));
    assert.notEqual(session.thinkingLevel, 'high');
    const read = session.agent.state.tools.find(t => t.name === 'read');
    const inside = await read.execute('in', { path: path.join(folder, 'plan.md') });
    assert.match(JSON.stringify(inside.content), /Ship the report/);
    await assert.rejects(read.execute('out', { path: outside }), /not in this mate/);
    const relative = await read.execute('rel', { path: 'plan.md' });
    assert.match(JSON.stringify(relative.content), /Ship the report/);
    await assert.rejects(read.execute('tilde', { path: '~/secret.txt' }), /not in this mate/);
    await assert.rejects(read.execute('up', { path: path.join(folder, '..', 'secret.txt') }), /not in this mate/);
    assert.equal(await readFile(outside, 'utf8'), 'private');
  } finally { session.dispose(); }
});
