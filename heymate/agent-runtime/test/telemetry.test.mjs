import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, stat, symlink, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import lockfile from 'proper-lockfile';
import { createTelemetry } from '../src/telemetry.mjs';

test('H1 telemetry keeps per-request timings and cached-token aggregates without private content', () => {
  let time = 1000;
  const rows = [];
  const t = createTelemetry({ sessionID: 'chat', model: 'fixture-model', provider: 'fixture', effort: 'medium', now: () => time, write: r => rows.push(r) });
  t.onEvent({ type: 'agent_start' });
  t.beforeRequest({ input: 'PRIVATE_PROMPT' });
  time = 1010; t.afterResponse(200);
  time = 1020; t.onEvent({ type: 'message_update', assistantMessageEvent: { type: 'thinking_delta', delta: 'PRIVATE_REASONING' } });
  time = 1030; t.onEvent({ type: 'message_update', assistantMessageEvent: { type: 'text_delta', delta: 'PRIVATE_ANSWER' } });
  time = 1100; t.onEvent({ type: 'message_end', message: { role: 'assistant', stopReason: 'toolUse', usage: { input: 100, cacheRead: 40, cacheWrite: 20, output: 15 }, content: [{ type: 'toolCall', name: 'fixture_read', arguments: { secret: 'PRIVATE_ARGS' } }] } });
  t.onEvent({ type: 'tool_execution_start', toolCallId: 't1', toolName: 'fixture_read', args: { secret: 'PRIVATE_ARGS' } });
  time = 1150; t.onEvent({ type: 'tool_execution_end', toolCallId: 't1', toolName: 'fixture_read', result: { content: [{ type: 'text', text: 'PRIVATE_RESULT' }] }, isError: false, durationMs: 45 });
  const request = rows[0];
  assert.equal(request.t_first_byte, 1010); assert.equal(request.t_first_reasoning, 1020); assert.equal(request.t_first_output, 1030);
  assert.equal(request.request_bytes, Buffer.byteLength(JSON.stringify({ input: 'PRIVATE_PROMPT' })));
  assert.equal(request.usage.cached, 40); assert.equal(request.usage.cache_write, 20);
  assert.deepEqual(request.function_calls, ['fixture_read']);
  assert.equal(rows[1].t_end - rows[1].t, 50); assert.equal(rows[1].exec_ms, 45);
  assert.equal(t.snapshot().rounds, 1); assert.equal(t.snapshot().cachedTokens, 40); assert.equal(t.snapshot().toolCalls, 1);
  assert.doesNotMatch(JSON.stringify(rows), /PRIVATE_/);
});

test('H1 telemetry preserves unknown network timing, retries, compaction and interrupted tools', () => {
  let time = 100;
  const rows = [], t = createTelemetry({ now: () => time, write: r => rows.push(r) });
  t.beforeRequest({}); time = 110; t.beforeRequest({});
  assert.equal(rows[0].error, 'superseded_request'); assert.equal(rows[0].t_first_byte, null);
  t.onEvent({ type: 'message_end', message: { role: 'assistant', stopReason: 'error', errorMessage: 'PRIVATE_SECRET' } });
  t.onEvent({ type: 'tool_execution_start', toolCallId: 'x', toolName: 'read' });
  time = 130; t.onEvent({ type: 'agent_end' });
  t.onEvent({ type: 'compaction_start' }); t.beforeRequest({});
  t.onEvent({ type: 'message_end', message: { role: 'assistant', stopReason: 'stop', usage: { input: 30, output: 3 } } });
  assert.equal(rows.at(-1).purpose, 'compaction');
  assert.equal(t.snapshot().rounds, 2); assert.equal(t.snapshot().toolErrors, 1); assert.equal(t.snapshot().compactions, 1);
  assert.doesNotMatch(JSON.stringify(rows), /PRIVATE_SECRET/);
});

test('compact logger and full timing log persist privately', async () => {
  const home = await mkdtemp(path.join(os.tmpdir(), 'heymate-telemetry-'));
  try {
    const t = createTelemetry({ home, sessionID: 'chat', model: 'fixture', provider: 'fixture', effort: 'medium' });
    t.beforeRequest({}); t.afterResponse(200);
    t.onEvent({ type: 'message_end', message: { role: 'assistant', stopReason: 'stop', usage: { input: 50, output: 7 } } });
    const log = JSON.parse((await readFile(path.join(home, 'logs/request-stats.jsonl'), 'utf8')).trim());
    const round = JSON.parse((await readFile(path.join(home, 'logs/h1-rounds.jsonl'), 'utf8')).trim());
    assert.equal(log.kind, 'model_request'); assert.equal(round.kind, 'round'); assert.equal(round.input, 50);
    assert.equal((await stat(path.join(home, 'logs/request-stats.jsonl'))).mode & 0o777, 0o600);
    assert.equal((await stat(path.join(home, 'logs/h1-rounds.jsonl'))).mode & 0o777, 0o600);
  } finally { await rm(home, { recursive: true, force: true }); }
});

test('telemetry refuses symlink targets and preserves records during a locked rotation', async () => {
  const home = await mkdtemp(path.join(os.tmpdir(), 'heymate-telemetry-'));
  try {
    const t = createTelemetry({ home, sessionID: 'chat', model: 'fixture' });
    const active = path.join(home, 'logs/request-stats.jsonl');
    const outside = path.join(home, 'unrelated.txt');
    await writeFile(outside, 'untouched', { mode: 0o644 });
    await symlink(outside, active);
    t.onEvent({ type: 'compaction_start' });
    assert.equal(await readFile(outside, 'utf8'), 'untouched');
    assert.equal((await stat(outside)).mode & 0o777, 0o644);

    await rm(active);
    const fullLog = ' '.repeat(1024 * 1024);
    await writeFile(active, fullLog, { mode: 0o644 });
    const release = lockfile.lockSync(active, { realpath: false });
    try {
      t.onEvent({ type: 'compaction_start' });
      await assert.rejects(stat(`${active}.1`), { code: 'ENOENT' });
      assert.ok((await readFile(active, 'utf8')).startsWith(fullLog));
    } finally {
      release();
    }
    t.onEvent({ type: 'compaction_start' });
    assert.equal(JSON.parse(await readFile(active, 'utf8')).kind, 'compaction');
    assert.equal(JSON.parse((await readFile(`${active}.1`, 'utf8')).trim()).kind, 'compaction');
    assert.equal((await stat(`${active}.1`)).mode & 0o777, 0o600);
  } finally {
    await rm(home, { recursive: true, force: true });
  }
});
