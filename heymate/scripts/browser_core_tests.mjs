import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { BrowserBridge, ModelView, groupTitle, slugify, snapshotLines, webURL } from '../browser/extension/mate-core.mjs';

const engine = readFileSync(new URL('../browser/extension/mate-core.mjs', import.meta.url), 'utf8');

test('webURL accepts http(s) and refuses credentials and other schemes', () => {
  assert.equal(webURL('https://example.com/a'), 'https://example.com/a');
  assert.equal(webURL('http://example.com'), 'http://example.com/');
  assert.throws(() => webURL('http://user:secret@example.com/'), /credentials/);
  assert.throws(() => webURL('javascript:alert(1)'), /HTTP\(S\)/);
});

test('group titles stay within 32 characters and downloads get a folder slug', () => {
  assert.equal(groupTitle(''), 'HeyMate');
  assert.equal(groupTitle('  Weekly   groceries '), 'Weekly groceries');
  assert.equal(groupTitle('a'.repeat(33)), `${'a'.repeat(31)}…`);
  assert.equal(slugify('Café menu'), 'cafe-menu');
  assert.equal(slugify('---'), 'task');
});

test('snapshot lines name controls, and an action reports only the change', () => {
  const view = new ModelView();
  const page = nodes => ({ url: 'https://example.com/', title: 'Example', nodes });
  const first = view.render(page([{ role: 'button', name: ' Save ', ref: 'e1', disabled: true }]), 7, false);
  assert.equal(first.elements, 'button: Save (disabled) [e1]');
  const same = view.render(page([{ role: 'button', name: 'Save', ref: 'e1', disabled: true }]), 7, true);
  assert.equal(same.unchanged, true);
  const queried = view.forModel(page([{ role: 'button', name: 'Save', ref: 'e1' }]), { tabId: 7, query: 'save' });
  assert.equal(queried.elements, 'button: Save [e1]');
  const after = view.render(page([
    { role: 'button', name: 'Save', ref: 'e1', disabled: true },
    { role: 'StaticText', name: 'done', ref: 'e2' },
  ]), 7, true);
  assert.deepEqual(after.added, ['text: done [e2]']);
  assert.deepEqual(after.removed, []);
  assert.equal(snapshotLines(page([{ role: 'link', name: 'Docs', ref: 'e3' }]))[0], 'link: Docs [e3]');
});

test('the page pointer is HeyMate\'s and clears pointers left by earlier builds', () => {
  assert.match(engine, /createElement\('heymate-cursor'\)/);
  assert.match(engine, /querySelectorAll\('reference-renderer-cursor, heymate-cursor'\)/);
  assert.match(engine, /Symbol\.for\('heymate\.quiet'\)/);
  // the hyphenated name earlier builds used as a global is not an identifier; it must never appear as code
  assert.doesNotMatch(engine, /globalThis\.__reference-renderer/);
});

test('a stopped turn can still be ended, so the next turn can start', async () => {
  const engine = new BrowserBridge({ tabs: { query: async () => [] } });
  engine.tasks.add('mine/turn'); engine.owners.set('mine/turn', 'mine');
  engine.stopped.add('mine/turn'); engine.stopReasons.set('mine/turn', 'User took control of the page.');
  await assert.rejects(engine.execute({ task: 'mine/turn', operation: 'tabs' }), /took control/);
  assert.deepEqual(await engine.execute({ task: 'mine/turn', operation: 'end', tidy: true }), { closed: [] });
});

test('a download a click starts is filed under the turn that clicked', () => {
  let now = 1000;
  const engine = new BrowserBridge({}, undefined, { now: () => now });
  engine.tasks.add('t'); engine.owners.set('t', 'Weekly groceries'); engine.claims.set(7, 't');
  engine.tabs.set(7, { inputAt: 900 });
  engine.downloadWillBegin(7, { guid: 'download-3', url: 'https://fixture.test/list.csv' });
  // Real DownloadItem has no tabId; the page event supplies tab provenance.
  engine.downloadStarted({ id: 3, url: 'https://fixture.test/list.csv' });
  assert.deepEqual(engine.determineFilename({ id: 3, filename: '/Users/x/Downloads/list.csv' }),
    { filename: 'HeyMate/weekly-groceries/list.csv', conflictAction: 'uniquify' });
  now = 5000;
  engine.downloadWillBegin(7, { guid: 'download-4', url: 'https://fixture.test/other.csv' });
  engine.downloadStarted({ id: 4, url: 'https://fixture.test/other.csv' });
  assert.equal(engine.determineFilename({ id: 4, filename: 'other.csv' }), undefined);
});

test('which tabs are whose is saved through the store the extension gives', async () => {
  let saved = null;
  const store = { load: async () => saved, save: async value => { saved = value; } };
  const engine = new BrowserBridge({ tabs: { get: async id => ({ id }) } }, undefined, { store });
  engine.ownedTabs.set(5, 'mine'); engine.kept.set(5, 'result'); engine.homes.set('mine', { windowId: 1, groupId: 2 });
  await engine.persist();
  const back = new BrowserBridge({ tabs: { get: async id => ({ id }) } }, undefined, { store });
  await back.restore();
  assert.equal(back.ownedTabs.get(5), 'mine'); assert.equal(back.kept.get(5), 'result'); assert.equal(back.homes.get('mine').groupId, 2);
});


function downloadEngine() {
  const bridge = new BrowserBridge({});
  bridge.tasks.add('turn'); bridge.owners.set('turn', 'Reports');
  bridge.claims.set(7, 'turn'); bridge.tabs.set(7, { inputAt: Date.now() });
  return bridge;
}
test('filename attribution tolerates Chrome event order without attributing unrelated downloads', async () => {
  const bridge = downloadEngine(), item = { id: 10, url: 'https://fixture.test/report.csv', filename: '/Downloads/report.csv' };
  bridge.downloadStarted(item);
  const suggestion = bridge.filenameFor(item);
  bridge.downloadWillBegin(7, { guid: 'late-page-event', url: item.url });
  assert.deepEqual(await suggestion, { filename: 'HeyMate/reports/report.csv', conflictAction: 'uniquify' });
  // A tabId supplied by a caller is not Chrome provenance.
  bridge.downloadStarted({ id: 11, tabId: 7, url: 'https://fixture.test/unrelated.csv' });
  assert.equal(bridge.determineFilename({ id: 11, filename: 'unrelated.csv' }), undefined);
});
test('ambiguous, stale and stopped-task page downloads receive no filename suggestion', () => {
  const bridge = downloadEngine(), url = 'https://fixture.test/file';
  bridge.downloadWillBegin(7, { guid: 'one', url });
  bridge.downloadWillBegin(7, { guid: 'two', url });
  bridge.downloadStarted({ id: 12, url });
  assert.equal(bridge.downloads.has(12), false);
  bridge.downloadHints.clear(); bridge.tabs.get(7).inputAt = Date.now() - 2000;
  bridge.downloadWillBegin(7, { guid: 'stale', url });
  assert.equal(bridge.downloadHints.size, 0);
  bridge.tabs.get(7).inputAt = Date.now(); bridge.stopped.add('turn');
  bridge.downloadWillBegin(7, { guid: 'stopped', url });
  assert.equal(bridge.downloadHints.size, 0);
});
test('explicit downloads still correlate Chrome events without a tabId', () => {
  const bridge = downloadEngine(), url = 'https://fixture.test/direct';
  bridge.pendingDownloads.set(url, { task: 'turn' });
  bridge.downloadStarted({ id: 13, url });
  assert.equal(bridge.downloads.get(13).task, 'turn');
});

function debuggerEngine(options = {}) {
  const calls = [], pending = [];
  let hung = true;
  const api = { tabs: { get: async id => ({ id, url: 'https://fixture.test/', title: 'Fixture' }), query: async () => [] },
    debugger: { attach: async () => { calls.push('attach'); }, detach: async () => { calls.push('detach'); },
      sendCommand: async (_, method) => {
        calls.push(method);
        if (hung && method === (options.method ?? 'Accessibility.getFullAXTree')) return new Promise(resolve => pending.push(resolve));
        return method === 'Accessibility.getFullAXTree' ? { nodes: [] } : {};
      } } };
  const bridge = new BrowserBridge(api, undefined, { limits: { single: 25, batch: 25 } });
  return { bridge, api, calls, pending, resume() { hung = false; for (const done of pending) done({ nodes: [] }); } };
}
test('a stalled CDP read times out, releases its queue and debugger, and requires a new turn', async () => {
  const h = debuggerEngine();
  await assert.rejects(h.bridge.execute({ task: 'read', operation: 'snapshot', tabId: 7 }), /timed out.*unknown/);
  assert.equal(h.bridge.queues.size, 0); assert.equal(h.bridge.claims.has(7), false);
  assert.equal(h.bridge.tabs.has(7), false); assert.ok(h.calls.includes('detach'));
  await assert.rejects(h.bridge.execute({ task: 'read', operation: 'snapshot', tabId: 7 }), /stopped/);
  h.resume();
  await h.bridge.execute({ task: 'read', operation: 'end' });
  assert.deepEqual((await h.bridge.execute({ task: 'fresh', operation: 'snapshot', tabId: 7 })).nodes, []);
});
test('a timed-out input never replays or continues the rest of its batch when its reply arrives late', async () => {
  const h = debuggerEngine({ method: 'Input.insertText' });
  h.bridge.act = async request => h.bridge.command(request.task, request.tabId,
    request.operation === 'fill' ? 'Input.insertText' : 'Input.dispatchKeyEvent');
  await assert.rejects(h.bridge.execute({ task: 'write', operation: 'batch', tabId: 7,
    steps: [{ operation: 'fill' }, { operation: 'press' }] }), /Outcome may be unknown/);
  h.resume(); await new Promise(setImmediate);
  assert.equal(h.calls.filter(method => method === 'Input.insertText').length, 1);
  assert.equal(h.calls.includes('Input.dispatchKeyEvent'), false);
  assert.equal(h.bridge.queues.size, 0);
});
test('a tab cannot be reattached while a timed-out debugger detach remains pending', async () => {
  const h = debuggerEngine(); let detached;
  h.api.debugger.detach = () => new Promise(resolve => { detached = resolve; });
  await assert.rejects(h.bridge.execute({ task: 'old', operation: 'snapshot', tabId: 7 }), /timed out/);
  await assert.rejects(h.bridge.execute({ task: 'new', operation: 'snapshot', tabId: 7 }), /cleanup is pending/);
  assert.equal(h.calls.filter(method => method === 'attach').length, 1);
  h.resume(); detached(); await new Promise(setImmediate);
  assert.equal(h.bridge.cleanups.has(7), false);
  assert.deepEqual((await h.bridge.execute({ task: 'new', operation: 'snapshot', tabId: 7 })).nodes, []);
});

function keepEngine(store) {
  const removed = [], tabs = new Map([[7, { id: 7, groupId: 1 }], [8, { id: 8, groupId: 1 }],
    [9, { id: 9, groupId: 1 }], [10, { id: 10, groupId: 2 }], [11, { id: 11, groupId: 1 }]]);
  const bridge = new BrowserBridge({ tabs: { get: async id => tabs.get(id), query: async () => [], remove: async id => removed.push(id) } }, undefined, { store });
  bridge.current = async () => ({ id: 9 }); bridge.fold = async () => {};
  bridge.homes.set('mine', { groupId: 1 });
  for (const id of [7, 8, 9, 10]) bridge.ownedTabs.set(id, 'mine');
  bridge.ownedTabs.set(11, 'other'); bridge.kept.set(11, 'result');
  return { bridge, removed };
}
test('keeps expire on the next owner turn; renewed, current, moved-out and other-owner tabs survive', async () => {
  const { bridge, removed } = keepEngine();
  await bridge.execute({ task: 'one', owner: 'mine', operation: 'keep', tabId: 7, why: 'result' });
  await bridge.execute({ task: 'one', operation: 'keep', tabId: 8, why: 'waiting' });
  assert.deepEqual((await bridge.execute({ task: 'one', operation: 'end', tidy: true })).closed, []);
  await bridge.execute({ task: 'two', owner: 'mine', operation: 'tabs' });
  assert.equal(bridge.kept.has(7), false); assert.equal(bridge.kept.has(8), false);
  assert.equal(bridge.kept.has(11), true);
  await bridge.execute({ task: 'two', operation: 'keep', tabId: 7, why: 'result' });
  assert.deepEqual((await bridge.execute({ task: 'two', operation: 'end', tidy: true })).closed, [8]);
  assert.deepEqual(removed, [8]);
});
test('restored keeps must also be renewed by the first new owner turn', async () => {
  let saved = { owned: [[7, 'mine'], [8, 'mine']], homes: [['mine', { groupId: 1 }]], kept: [[7, 'result'], [8, 'waiting']] };
  const store = { load: async () => saved, save: async value => { saved = value; } };
  const { bridge, removed } = keepEngine(store);
  await bridge.restore(); assert.equal(bridge.kept.has(8), true);
  await bridge.execute({ task: 'after-restore', owner: 'mine', operation: 'keep', tabId: 7, why: 'result' });
  assert.deepEqual(saved.kept, [[11, 'result'], [7, 'result']]);
  await bridge.execute({ task: 'after-restore', operation: 'end', tidy: true });
  assert.deepEqual(removed, [8]);
});


test('a timed-out attach is detached when it eventually finishes, before the tab can be reused', async () => {
  const h = debuggerEngine(); let attach;
  h.api.debugger.attach = () => new Promise(resolve => { attach = resolve; });
  await assert.rejects(h.bridge.execute({ task: 'late-attach', operation: 'snapshot', tabId: 7 }), /timed out/);
  assert.equal(h.bridge.cleanups.has(7), true);
  assert.equal(h.calls.includes('Page.enable'), false);
  attach(); await new Promise(setImmediate);
  assert.equal(h.bridge.cleanups.has(7), false);
  assert.ok(h.calls.includes('detach'));
  assert.equal(h.calls.includes('Page.enable'), false);
});
test('a stale claim cannot be replaced while its debugger cleanup is still pending', async () => {
  const h = debuggerEngine(); let detach;
  h.api.debugger.detach = () => new Promise(resolve => { detach = resolve; });
  h.bridge.claims.set(7, 'finished');
  h.bridge.tabs.set(7, { task: 'finished', attached: true, world: null });
  await assert.rejects(h.bridge.execute({ task: 'replacement', operation: 'snapshot', tabId: 7 }), /cleanup is pending/);
  assert.equal(h.calls.includes('attach'), false);
  detach(); await new Promise(setImmediate);
});
test('ending after a user debugger detach does not permanently quarantine the tab', async () => {
  const h = debuggerEngine(); h.resume();
  await h.bridge.execute({ task: 'old', operation: 'snapshot', tabId: 7 });
  h.bridge.detached(7, 'canceled_by_user');
  h.api.debugger.detach = async () => { throw Error('Debugger is not attached'); };
  await h.bridge.execute({ task: 'old', operation: 'end' });
  assert.equal(h.bridge.cleanups.has(7), false);
  assert.deepEqual((await h.bridge.execute({ task: 'new', operation: 'snapshot', tabId: 7 })).nodes, []);
});
