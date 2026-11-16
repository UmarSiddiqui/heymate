import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, readdir, realpath, symlink, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { createFileHistory, folderKey, pruneIndex, withFileHistory } from '../src/file-history.mjs';

async function fixture() {
  const base = await realpath(await mkdtemp(path.join(os.tmpdir(), 'heymate-history-')));
  const matesRoot = path.join(base, 'mates'), root = path.join(base, 'history');
  await mkdir(path.join(matesRoot, 'writer'), { recursive: true });
  const store = path.join(root, folderKey(path.join(matesRoot, 'writer')));
  return { base, matesRoot, root, store, history: createFileHistory({ root, matesRoot }) };
}

const write = (file, text) => async () => { await writeFile(file, text); return { content: [{ type: 'text', text: 'ok' }] }; };

test('a new file is recorded as made by the mate and an overwrite keeps the prior bytes', async () => {
  const { matesRoot, store, history } = await fixture();
  const file = path.join(matesRoot, 'writer', 'notes', 'plan.md');
  await mkdir(path.dirname(file), { recursive: true });
  await withFileHistory(history, '/', 'write', { path: file }, write(file, 'one'));
  const origins = (await readFile(path.join(store, 'origins.jsonl'), 'utf8')).trim().split('\n').map(line => JSON.parse(line));
  assert.deepEqual(origins.map(({ path, origin }) => ({ path, origin })), [{ path: 'notes/plan.md', origin: 'mate' }]);
  await withFileHistory(history, '/', 'edit', { path: 'notes/plan.md' }, write(file, 'two')).catch(() => {});
  await withFileHistory(history, path.join(matesRoot, 'writer'), 'edit', { path: 'notes/plan.md' }, write(file, 'three'));
  const index = JSON.parse(await readFile(path.join(store, 'versions', 'index.json'), 'utf8'));
  const versions = index.files['notes/plan.md'];
  assert.equal(versions.length, 1);
  assert.equal(versions[0].source, 'mate');
  assert.equal(await readFile(path.join(store, 'versions', 'blobs', versions[0].id), 'utf8'), 'two');
  // Overwrites do not repeat the origin.
  assert.equal((await readFile(path.join(store, 'origins.jsonl'), 'utf8')).trim().split('\n').length, 1);
});

test('paths outside a mate folder, through symlinks or `..`, are never recorded', async () => {
  const { base, matesRoot, root, history } = await fixture();
  const outside = path.join(base, 'outside.txt');
  await writeFile(outside, 'secret');
  await symlink(base, path.join(matesRoot, 'writer', 'escape'));
  for (const target of [outside, path.join(matesRoot, 'writer', 'escape', 'outside.txt'),
    path.join(matesRoot, 'writer', '..', '..', 'outside.txt'), path.join(matesRoot, 'loose.txt')]) {
    await withFileHistory(history, '/', 'write', { path: target }, async () => ({ content: [] }));
  }
  await assert.rejects(readdir(root));
});

test('pruning keeps ten per file and drops the oldest across the mate past the size cap', () => {
  const versions = Array.from({ length: 12 }, (_, i) => ({ id: `a${String(i).padStart(2, '0')}`, at: `2026-01-01T00:00:${String(i).padStart(2, '0')}.000Z`, size: 10 }));
  const { index, removed } = pruneIndex({ files: { a: versions, b: [{ id: 'b0', at: '2025-01-01T00:00:00.000Z', size: 10 }] } },
    { perFile: 10, maxFileBytes: 100, maxTotalBytes: 95 });
  assert.deepEqual(removed, ['a00', 'a01', 'b0', 'a02']);
  assert.equal(index.files.a.length, 9);
  assert.equal(index.files.b, undefined);
});

test('other tools and unconfigured history pass straight through', async () => {
  let ran = 0;
  await withFileHistory(null, '/', 'write', { path: '/x' }, async () => { ran += 1; });
  await withFileHistory(createFileHistory({ root: '/nonexistent', matesRoot: '/nonexistent' }), '/', 'bash', { command: 'true' }, async () => { ran += 1; });
  assert.equal(ran, 2);
});
