import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import test from 'node:test';
import { webcrypto } from 'node:crypto';
import { BrowserBridge, snapshotLines } from '../browser/extension/mate-core.mjs';

const source = fs.readFileSync(new URL('../browser/extension/background.js', import.meta.url), 'utf8')
  .replace(/^import .*from "\.\/mate-core.mjs";$/m, '');
const event = () => ({ listeners: [], addListener(fn) { this.listeners.push(fn); } });
function adapter(execute) {
  const connections = [], requests = [];
  class Engine {
    ownedTabs = new Map();
    async restore() {}
    async execute(request) { requests.push(request); return execute(request); }
    async stop() {}
    downloadStarted(item) { this.lastDownload = item; }
    determineFilename() { return { filename: "ReferenceRenderer/qa/file.txt", conflictAction: "uniquify" }; }
  }
  const chrome = { runtime: { getManifest: () => ({ version: 'fixture' }), connectNative() {
    const port = { onMessage: event(), onDisconnect: event(), sent: [], postMessage(m) { this.sent.push(m); } };
    connections.push(port); return port;
  }, onInstalled: event(), onStartup: event() }, alarms: { create() {}, onAlarm: event() },
  downloads: { onCreated: event(), onDeterminingFilename: event() },
  debugger: { onEvent: event(), onDetach: event() }, tabs: { onUpdated: event(), onRemoved: event() } };
  const context = vm.createContext({ chrome, BrowserBridge: Engine, snapshotLines, crypto: webcrypto, console });
  vm.runInContext(source, context);
  return { context, connections, requests, async command(op, fields = {}) {
    const connection = connections.at(-1), id = webcrypto.randomUUID();
    await connection.onMessage.listeners[0]({ type: 'command', id, op, ...fields });
    return connection.sent.find(m => m.id === id);
  } };
}
const snapshot = { tabId: 7, url: 'https://fixture.test/', title: 'Fixture', nodes: [
  { ref: 'e12', role: 'textbox', name: 'Search' }, { role: 'text', name: 'Content' }
] };

test('settled page reports observed redirect URL rather than requested URL', async () => {
  const h = adapter(async () => ({ tabId: 7, snapshot }));
  const reply = await h.command('open', { url: 'https://original.test/' });
  assert.equal(reply.result.url, snapshot.url);
});

test('adapter retains action tab IDs and editable refs in settled snapshots', async () => {
  const h = adapter(async () => ({ snapshot }));
  for (const op of ['click', 'type', 'press', 'scroll', 'back', 'wait_for']) {
    const reply = await h.command(op, { tabId: 7, ref: 12, key: 'Enter', text: 'hello' });
    assert.equal(reply.ok, true); assert.equal(reply.result.tabId, 7);
    assert.equal(reply.result.elements[0].ref, 12); assert.equal(reply.result.elements[0].editable, true);
  }
});
test('single-action failure with readable snapshot is an error, never success', async () => {
  const h = adapter(async () => ({ error: 'Target is covered', snapshot }));
  for (const op of ['click', 'navigate', 'press', 'scroll', 'back', 'wait_for']) {
    const reply = await h.command(op, { tabId: 7, ref: 12 });
    assert.equal(reply.ok, false); assert.match(reply.error, /covered/);
  }
});
test('partial type batch cannot report successful submit', async () => {
  const h = adapter(async () => ({ steps: [{ operation: 'fill' }], error: 'Step 1 ran; dialog blocked step 2', snapshot }));
  const reply = await h.command('type', { tabId: 7, ref: 12, text: 'hello', submit: true });
  assert.equal(reply.ok, false); assert.match(reply.error, /step 2/);
});
test('disconnect renews stopped task; old replies never reach new connection', async () => {
  let finish;
  const h = adapter(request => request.operation === 'click' ? new Promise(r => { finish = r; }) : { tabs: [] });
  const old = h.connections[0];
  const pending = h.command('click', { tabId: 7, ref: 12 });
  while (!finish) await new Promise(setImmediate);
  old.onDisconnect.listeners[0](); vm.runInContext('connect()', h.context);
  finish({ snapshot }); await pending;
  await h.command('tabs');
  assert.notEqual(h.requests[0].task, h.requests[1].task);
  assert.equal(old.sent.filter(m => m.type === 'result').length, 0);
  assert.equal(h.connections[1].sent.filter(m => m.type === 'result').length, 1);
});
test('end is serialized after in-flight action and next command gets fresh task', async () => {
  let finish;
  const h = adapter(request => request.operation === 'click' ? new Promise(r => { finish = r; }) : {});
  const pending = h.command('click', { tabId: 7, ref: 12 });
  while (!finish) await new Promise(setImmediate);
  const ending = h.command('end');
  assert.equal(h.requests.length, 1);
  finish({ snapshot }); await pending; await ending;
  await h.command('snapshot', { tabId: 7 });
  assert.equal(h.requests[0].task, h.requests[1].task);
  assert.notEqual(h.requests[1].task, h.requests[2].task);
});

test('recovered engine refuses cross-owner claims and closing user tabs', async () => {
  const engine = new BrowserBridge({});
  engine.tasks.add('other/turn'); engine.owners.set('other/turn', 'other'); engine.ownedTabs.set(7, 'other');
  await assert.rejects(engine.execute({ task: 'mine/turn', owner: 'mine', operation: 'snapshot', tabId: 7 }), /another running/);
  await assert.rejects(engine.execute({ task: 'mine/turn', owner: 'mine', operation: 'close', tabId: 99 }), /Only a tab/);
});
test('recovered engine tidy preserves current and moved-out tabs; closes owned background tab', async () => {
  const removed = [], tabs = new Map([[1, { id: 1, groupId: 5 }], [2, { id: 2, groupId: 8 }], [3, { id: 3, groupId: 5 }]]);
  const engine = new BrowserBridge({ tabs: { get: async id => tabs.get(id), remove: async id => removed.push(id) } });
  engine.current = async () => ({ id: 1 }); engine.fold = async () => {};
  engine.tasks.add('mine/turn'); engine.owners.set('mine/turn', 'mine'); engine.homes.set('mine', { groupId: 5 });
  for (const id of tabs.keys()) engine.ownedTabs.set(id, 'mine');
  const result = await engine.execute({ task: 'mine/turn', operation: 'end', tidy: true });
  assert.deepEqual(result.closed, [3]); assert.deepEqual(removed, [3]);
  assert.equal(engine.ownedTabs.size, 0);
});

test('file adapter routes keep, upload, download and dialog; upload destination is pinned', async () => {
  const h = adapter(async r => r.operation === 'keep' ? { kept: true, tabId: 7 } : r.operation === 'download' ? { downloaded: false, state: 'in_progress', note: 'Chrome is holding this file' } : { snapshot });
  h.context.chrome.tabs.get = async () => ({ id: 7, url: snapshot.url });
  assert.equal((await h.command('keep', { tabId: 7, why: 'result' })).result.kept, true);
  const failed = await h.command('upload', { tabId: 7, ref: 12, paths: ['/tmp/fixture.txt'], expectedURL: 'https://different.test/' });
  assert.equal(failed.ok, false); assert.match(failed.error, /destination changed/);
  const uploaded = await h.command('upload', { tabId: 7, ref: 12, paths: ['/tmp/fixture.txt'], expectedURL: snapshot.url });
  assert.equal(uploaded.ok, true); assert.equal(h.requests.at(-1).operation, 'upload'); assert.equal(h.requests.at(-1).ref, 'e12');
  const held = await h.command('download', { url: 'https://fixture.test/file' });
  assert.equal(held.result.downloaded, false); assert.match(held.result.note, /holding/);
  await h.command('dialog', { tabId: 7, accept: false });
  assert.equal(h.requests.at(-1).operation, 'dialog'); assert.equal(h.requests.at(-1).accept, false);
});
test('kept result survives tidy; unkept owned tab is removed', async () => {
  const removed = [], tabs = new Map([[7, { id: 7, groupId: 1 }], [8, { id: 8, groupId: 1 }]]);
  const engine = new BrowserBridge({ tabs: { get: async id => tabs.get(id), remove: async id => removed.push(id) } });
  engine.current = async () => null; engine.fold = async () => {};
  engine.tasks.add('mine/turn'); engine.owners.set('mine/turn', 'mine'); engine.homes.set('mine', { groupId: 1 });
  engine.ownedTabs.set(7, 'mine'); engine.ownedTabs.set(8, 'mine');
  await engine.execute({ task: 'mine/turn', owner: 'mine', operation: 'keep', tabId: 7, why: 'result' });
  await engine.execute({ task: 'mine/turn', operation: 'end', tidy: true });
  assert.deepEqual(removed, [8]); assert.equal(engine.ownedTabs.has(7), true);
});

test('download events retain engine attribution and adapt only the destination folder', () => {
  const h = adapter(async () => ({}));
  const chrome = h.context.chrome;
  chrome.downloads.onCreated.listeners[0]({ id: 5 });
  assert.equal(vm.runInContext('bridge.lastDownload.id', h.context), 5);
  let suggestion;
  chrome.downloads.onDeterminingFilename.listeners[0]({}, value => { suggestion = value; });
  assert.equal(suggestion.filename, 'HeyMate/qa/file.txt');
  assert.equal(suggestion.conflictAction, 'uniquify');
});
test('recovered download reports complete, held and interrupted distinctly', async () => {
  for (const state of ['complete', 'in_progress', 'interrupted']) {
    const engine = new BrowserBridge({ downloads: { download: async () => 5,
      search: async () => [{ id: 5, state, danger: state === 'in_progress' ? 'dangerous' : 'safe', filename: 'fixture.txt', fileSize: 12, url: 'https://fixture.test/file', error: 'USER_CANCELED' }] } });
    const result = engine.execute({ task: 'qa', operation: 'download', url: 'https://fixture.test/file' });
    if (state === 'interrupted') await assert.rejects(result, /download failed/);
    else { const value = await result; assert.equal(value.downloaded, state === 'complete'); if (state !== 'complete') assert.match(value.note, /Only the user/); }
  }
});
