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
  engine.downloadStarted({ id: 3, tabId: 7, url: 'https://fixture.test/list.csv' });
  assert.deepEqual(engine.determineFilename({ id: 3, filename: '/Users/x/Downloads/list.csv' }),
    { filename: 'HeyMate/weekly-groceries/list.csv', conflictAction: 'uniquify' });
  now = 5000;
  engine.downloadStarted({ id: 4, tabId: 7, url: 'https://fixture.test/other.csv' });
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
