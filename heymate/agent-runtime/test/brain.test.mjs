import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import path from 'node:path';
import os from 'node:os';
import { mkdtemp, rm, readFile, mkdir } from 'node:fs/promises';
import { createModelAccess, createPiSession } from '../src/pi-session.mjs';
import { HeyMateHarness } from '../src/harness.mjs';

async function fixture(t) {
  const home = await mkdtemp(path.join(os.tmpdir(), 'heymate-brain-'));
  const access = await createModelAccess(home);
  const harness = new HeyMateHarness({ home, access, createSession: createPiSession });
  t.after(async () => { await harness.close(); await rm(home, { recursive: true, force: true }); });
  return { home, access, harness };
}

test('Brain offers only ChatGPT, Claude and custom API', async t => {
  const f = await fixture(t);
  const options = await f.harness.dispatch({}, 'model.options');
  assert.deepEqual(options.providers.map(p => p.slug), ['openai-codex', 'anthropic', 'heymate-custom']);
  const claude = options.providers.find(p => p.slug === 'anthropic');
  assert.ok(claude.models.every(id => Array.isArray(claude.efforts[id]) && claude.efforts[id].length));
  await assert.rejects(f.harness.modelSet({ provider: 'deepseek', api_key: 'fixture-private-key' }), /Unsupported Brain provider/);
});

test('effort is saved with the model and clamped to what the model supports', async t => {
  const f = await fixture(t);
  await f.access.credentials.modify('anthropic', async () => ({ type: 'oauth', access: 'fixture', refresh: 'fixture', expires: Date.now() + 3_600_000 }));
  await f.harness.modelSet({ provider: 'anthropic', model: 'claude-haiku-4-5', effort: 'high' });
  assert.equal(JSON.parse(await readFile(path.join(f.home, 'model.json'), 'utf8')).effort, 'high');
  await f.harness.modelSet({ provider: 'anthropic', model: 'claude-haiku-4-5', effort: 'max' });
  assert.equal(JSON.parse(await readFile(path.join(f.home, 'model.json'), 'utf8')).effort, 'high');
  await assert.rejects(f.harness.modelSet({ provider: 'anthropic', model: 'claude-haiku-4-5', effort: 'turbo' }), /Unsupported effort/);
});

test('custom API uses real Pi request adapter, private credential and persisted model configuration', async t => {
  const f = await fixture(t); let authorization, requestedModel;
  const server = http.createServer(async (request, response) => {
    let body = ''; for await (const chunk of request) body += chunk;
    authorization = request.headers.authorization; requestedModel = JSON.parse(body).model;
    assert.equal(request.url, '/v1/chat/completions');
    response.writeHead(200, { 'Content-Type': 'text/event-stream' });
    const base = { id: 'fixture', object: 'chat.completion.chunk', created: 1, model: 'fixture-model' };
    response.write(`data: ${JSON.stringify({ ...base, choices: [{ index: 0, delta: { role: 'assistant', content: 'Verified custom API.' }, finish_reason: null }] })}\n\n`);
    response.write(`data: ${JSON.stringify({ ...base, choices: [{ index: 0, delta: {}, finish_reason: 'stop' }] })}\n\n`);
    response.end('data: [DONE]\n\n');
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const baseURL = `http://127.0.0.1:${server.address().port}/v1`;
  await f.harness.modelSet({ provider: 'heymate-custom', model: 'fixture-model', base_url: baseURL, api_key: 'fixture-private-key' });
  const restored = await createModelAccess(f.home);
  assert.ok(restored.runtime.getModel('heymate-custom', 'fixture-model'));
  assert.equal((await readFile(path.join(f.home, 'models.json'), 'utf8')).includes('fixture-private-key'), false);
  const workspace = path.join(f.home, 'work'); await mkdir(workspace);
  const record = await f.harness.store.create(workspace);
  const session = await createPiSession({ home: f.home, record, access: restored, tools: [], approve() {}, emit() {} });
  try {
    await session.prompt('Test local fixture only.');
    assert.equal(session.getLastAssistantText(), 'Verified custom API.');
    assert.equal(authorization, 'Bearer fixture-private-key'); assert.equal(requestedModel, 'fixture-model');
    const recorded = await readFile(path.join(f.home, 'logs/request-stats.jsonl'), 'utf8');
    const request = recorded.trim().split('\n').map(JSON.parse).find(row => row.kind === 'model_request');
    assert.equal(request.status, 200);
    assert.equal(request.first_byte_observation, 'response_headers');
    assert.ok(request.t_first_byte >= request.t_send);
    assert.ok(request.t_first_output >= request.t_first_byte);
    assert.ok(request.t_end >= request.t_first_output);
    assert.doesNotMatch(recorded, /fixture-private-key|Test local fixture only|Verified custom API/);
  } finally { session.dispose(); }
  await assert.rejects(f.harness.modelSet({ provider: 'heymate-custom', model: 'fixture-model', base_url: 'https://another.example/v1' }), /Enter a key/);
});

test('invalid model, endpoint and active turn cannot mutate Brain or credentials', async t => {
  const f = await fixture(t);
  await assert.rejects(f.harness.modelSet({ provider: 'deepseek', model: 'not-a-real-model', api_key: 'must-not-save' }));
  assert.equal(await f.access.credentials.read('deepseek'), undefined);
  for (const endpoint of ['http://remote.example/v1', 'https://user:pass@example.com', 'https://example.com?key=secret']) {
    await assert.rejects(f.harness.modelSet({ provider: 'heymate-custom', model: 'fixture', base_url: endpoint, api_key: 'must-not-save' }));
  }
  assert.equal(await f.access.credentials.read('heymate-custom'), undefined);
  f.harness.sessions.set('active', { running: true });
  await assert.rejects(f.harness.modelSet({ provider: 'deepseek', api_key: 'must-not-save' }), /Finish current work/);
  f.harness.sessions.delete('active');
});

test('explicit model refresh bypasses both catalog caches', async t => {
  const f = await fixture(t), calls = [];
  f.access.runtime.refresh = async options => { calls.push(options); return { errors: new Map() }; };
  await f.harness.dispatch({}, 'model.options');
  await f.harness.dispatch({}, 'model.options');
  assert.equal(calls.length, 1);
  await f.harness.dispatch({}, 'model.options', { refresh: true });
  assert.equal(calls.length, 2);
  assert.equal(calls[1].force, true);
  assert.equal(calls[1].allowNetwork, true);
});

test('speed choices follow account eligibility and reach provider payload', async t => {
  const { catalogSpeeds, applyModelSpeed } = await import('../src/model-speeds.mjs');
  const f = await fixture(t), model = f.access.runtime.getModels('openai-codex')[0];
  f.harness.modelSpeeds = catalogSpeeds({ models: [
    { slug: model.id, service_tiers: [{ id: 'priority' }, { id: 'ultrafast' }, { id: 'unknown' }] },
    { slug: 'ordinary' }, { slug: 'older', additional_speed_tiers: ['fast'] }
  ] });
  assert.deepEqual(f.harness.modelSpeeds[model.id], ['default', 'priority', 'ultrafast']);
  assert.deepEqual(f.harness.modelSpeeds.ordinary, ['default']);
  assert.deepEqual(f.harness.modelSpeeds.older, ['default', 'priority']);
  await f.access.credentials.modify('openai-codex', async () => ({ type: 'oauth', access: 'fixture', refresh: 'fixture', expires: Date.now() + 3_600_000 }));
  const saved = await f.harness.modelSet({ provider: 'openai-codex', model: model.id, effort: 'high', speed: 'priority' });
  assert.equal(JSON.parse(await readFile(path.join(f.home, 'model.json'), 'utf8')).speed, 'priority');
  assert.equal((await f.harness.modelSet({ provider: 'openai-codex', model: model.id, effort: 'low' })).speed, 'priority');
  const payload = { model: model.id, input: [] };
  assert.equal(applyModelSpeed(payload, saved, model).service_tier, 'priority');
  assert.equal(applyModelSpeed(payload, { provider: 'openai-codex' }, model).service_tier, 'default');
  assert.equal(applyModelSpeed(payload, { provider: 'anthropic', speed: 'priority' }, model), payload);
  await assert.rejects(f.harness.modelSet({ provider: 'openai-codex', model: model.id, speed: 'turbo' }), /Unsupported speed/);
  f.harness.modelSpeeds = {};
  await assert.rejects(f.harness.modelSet({ provider: 'openai-codex', model: model.id, speed: 'ultrafast' }), /not available/);
  assert.equal((await f.harness.modelSet({ provider: 'openai-codex', model: model.id, speed: 'default' })).speed, 'default');
});

test('speed discovery uses refreshed private credentials without returning secrets', async () => {
  const { fetchModelSpeeds } = await import('../src/model-speeds.mjs');
  const token = `header.${Buffer.from(JSON.stringify({ 'https://api.openai.com/auth': { chatgpt_account_id: 'test-account' } })).toString('base64url')}.signature`;
  let refreshed = false;
  const access = { credentials: { read: async () => ({ type: 'oauth', access: refreshed ? token : 'expired' }) },
    runtime: { getAuth: async () => { refreshed = true; } } };
  const speeds = await fetchModelSpeeds(access, { fetcher: async (url, options) => {
    assert.ok(url.startsWith('https://chatgpt.com/backend-api/codex/models?'));
    assert.equal(options.headers.Authorization, `Bearer ${token}`);
    assert.equal(options.headers['ChatGPT-Account-Id'], 'test-account');
    return { ok: true, json: async () => ({ models: [{ slug: 'eligible', service_tiers: [{ id: 'priority' }] }] }) };
  } });
  assert.deepEqual(speeds, { eligible: ['default', 'priority'] });
});
