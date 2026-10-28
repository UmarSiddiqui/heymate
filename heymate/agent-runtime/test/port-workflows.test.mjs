import test from 'node:test';
import assert from 'node:assert/strict';
import { batchReadTool } from '../src/batch-reads.mjs';
import { noteClosingIssues, notePreviewCall } from '../src/note-workflow.mjs';

test('read batches overlap, preserve order, cap output and retain per-call failures', async () => {
  let active = 0, maximum = 0;
  const read = { name: 'read_fixture', async execute(_id, args) {
    active++; maximum = Math.max(maximum, active);
    await new Promise(resolve => setTimeout(resolve, args.delay)); active--;
    if (args.fail) throw new Error('Fixture read failed');
    return { content: [{ type: 'text', text: args.text ?? 'x'.repeat(30000) }] };
  } };
  const tool = batchReadTool([{ tool: read }]);
  const start = performance.now();
  const out = await tool.execute('batch', { calls: [
    { tool: read.name, arguments: { delay: 90, text: 'first' } },
    { tool: read.name, arguments: { delay: 30, fail: true } },
    { tool: read.name, arguments: { delay: 60 } }
  ] });
  const values = JSON.parse(out.content[0].text);
  assert.equal(maximum, 3); assert.equal(values[0].text, 'first');
  assert.equal(values[1].ok, false); assert.match(values[1].error, /Fixture/);
  assert.equal(values[2].truncated, true); assert.ok(values[2].text.length <= 12000);
  console.log(`read batch: ${Math.round(performance.now()-start)}ms; sequential fixture waits would total 180ms`);
});
test('read batches preflight all operations; mixed Chrome writes execute nothing', async () => {
  let calls = 0;
  const tool = batchReadTool([{ tool: { name: 'chrome', execute() { calls++; } }, allows: args => args.op === 'snapshot' }]);
  await assert.rejects(tool.execute('batch', { calls: [{ tool: 'chrome', arguments: { op: 'snapshot' } }, { tool: 'chrome', arguments: { op: 'upload' } }] }), /Nothing ran/);
  assert.equal(calls, 0);
  await assert.rejects(tool.execute('batch', { calls: [{ tool: 'bash', arguments: {} }] }));
  const abort = new AbortController(); abort.abort();
  await assert.rejects(tool.execute('batch', { calls: [{ tool: 'chrome', arguments: { op: 'snapshot' } }] }, abort.signal));
  assert.equal(calls, 0);
});
test('note closing checks require an answer and stopped work markers without falsely ticking unfinished tasks', () => {
  assert.equal(noteClosingIssues('# Plan\n- [ ] Work {now}\n```js\n').length, 3);
  assert.deepEqual(noteClosingIssues('# Plan\n> Blocked; user input needed\n- [ ] Work\n'), []);
});
test('preview takes a frozen partial note call, never ordinary tool output', () => {
  const call = { type: 'toolCall', id: 'n1', name: 'note_add', arguments: { after: '', md: 'partial' } };
  const preview = notePreviewCall({ assistantMessageEvent: { type: 'toolcall_delta', contentIndex: 0, partial: { content: [call] } } });
  call.arguments.md = 'later'; assert.equal(preview.arguments.md, 'partial');
  assert.equal(notePreviewCall({ assistantMessageEvent: { type: 'toolcall_end', toolCall: { ...call, name: 'bash' } } }), null);
});
