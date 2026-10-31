// node scripts/browser_live_check.mjs [chromium]: HeyMate's browser extension end to end in a real, isolated
// Chromium. The real background.js and mate-core.mjs run here against a chrome.* stand-in built on the DevTools
// protocol; a throwaway profile and a local fixture server keep it away from the user's browser and the network.
// Commands go in the way the app sends them through the native host, and replies are checked as the app reads them.
// Not part of `node --test scripts/*_tests.mjs`: it needs a Chromium (CHROME_PATH, or Playwright's download).
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import vm from 'node:vm';
import { webcrypto } from 'node:crypto';
import { BrowserBridge, snapshotLines } from '../browser/extension/mate-core.mjs';

function chromium() {
  if (process.argv[2]) return process.argv[2];
  if (process.env.CHROME_PATH) return process.env.CHROME_PATH;
  const cache = path.join(os.homedir(), 'Library/Caches/ms-playwright');
  const builds = fs.existsSync(cache) ? fs.readdirSync(cache).filter(d => /^chromium-\d+$/.test(d)).sort().reverse() : [];
  for (const b of builds) for (const app of ['chrome-mac-arm64', 'chrome-mac']) {
    for (const name of ['Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing', 'Chromium.app/Contents/MacOS/Chromium']) {
      const p = path.join(cache, b, app, name);
      if (fs.existsSync(p)) return p;
    }
  }
  throw Error('No Chromium found: pass its path or set CHROME_PATH.');
}

// ---------------------------------------------------------------- fixture pages
const PAGES = {
  '/form': `<title>Form</title><reference-renderer-cursor id="old"></reference-renderer-cursor>
    <label>Name <input id="name"></label> <label>Secret <input type="password" id="pw"></label>
    <button id="save" onclick="out.textContent='Saved: '+document.getElementById('name').value">Save</button>
    <button disabled>Locked</button>
    <div style="position:relative;display:inline-block"><button id="under" onclick="out.textContent='under clicked'">Under</button>
      <div style="position:absolute;inset:-4px;background:rgba(0,0,0,.2)"></div></div>
    <a href="/next">Next page</a> <p id="out"></p>
    <table><tr><th>Item</th><th>Price</th></tr><tr><td>Tea</td><td>3</td></tr></table>
    <div style="height:3000px"></div><p>Bottom of form</p>`,
  '/next': `<title>Next</title><h1>Next page</h1>`,
  '/slow': `<title>Slow</title><p id="s">Loading</p><script>setTimeout(() => s.textContent = 'Ready now', 700)</script>`,
  '/dialog': `<title>Dialog</title><button onclick="r.textContent = confirm('Sure?') ? 'yes' : 'no'">Ask</button><p id="r"></p>`,
  '/upload': `<title>Upload</title><label>File <input type="file" id="f" onchange="u.textContent='Got '+this.files[0].name"></label><p id="u"></p>`,
};
const server = http.createServer((req, res) => {
  const body = PAGES[new URL(req.url, 'http://x').pathname];
  res.writeHead(body ? 200 : 404, { 'content-type': 'text/html; charset=utf-8' });
  res.end(body ? `<!doctype html><meta charset="utf-8">${body}` : 'missing');
});
await new Promise(r => server.listen(0, '127.0.0.1', r));
const site = `http://127.0.0.1:${server.address().port}`;

// ---------------------------------------------------------------- Chromium and its protocol
const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'heymate-browser-check-'));
const browser = spawn(chromium(), ['--headless=new', '--remote-debugging-port=0', `--user-data-dir=${profile}`, '--no-first-run',
  '--no-default-browser-check', '--disable-extensions', 'about:blank'], { stdio: 'ignore' });
const portFile = path.join(profile, 'DevToolsActivePort');
for (let k = 0; k < 200 && !fs.existsSync(portFile); k++) await new Promise(r => setTimeout(r, 50));
const [port, wsPath] = fs.readFileSync(portFile, 'utf8').trim().split('\n');
const ws = new WebSocket(`ws://127.0.0.1:${port}${wsPath}`);
await new Promise((r, j) => { ws.onopen = r; ws.onerror = j; });
let seq = 0;
const waiting = new Map(), eventListeners = [];
ws.onmessage = ({ data }) => {
  const m = JSON.parse(data);
  if (m.id && waiting.has(m.id)) { const { resolve, reject } = waiting.get(m.id); waiting.delete(m.id); m.error ? reject(Error(m.error.message)) : resolve(m.result); }
  else if (m.method) for (const fn of eventListeners) fn(m);
};
const trace = process.env.HEYMATE_LIVE_TRACE ? (...a) => console.log('  ·', ...a) : () => {};
eventListeners.push(m => { if (/Dialog|frameNavigated/.test(m.method)) trace('event', m.method); });
const cdp = (method, params = {}, sessionId) => new Promise((resolve, reject) => {
  const id = ++seq; waiting.set(id, { resolve, reject, method });
  if (!/getTargetInfo|Runtime.evaluate|getFullAXTree/.test(method)) trace('send', id, method);
  ws.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }));
});

// ---------------------------------------------------------------- chrome.* on top of it
const event = () => ({ listeners: [], addListener(fn) { this.listeners.push(fn); } });
const tabIds = new Map(), targets = new Map(), groups = new Map(), sessions = new Map(), groupOf = new Map();
let nextTab = 100, nextGroup = 1;
const idFor = targetId => { if (!tabIds.has(targetId)) { tabIds.set(targetId, nextTab); targets.set(nextTab, targetId); nextTab++; } return tabIds.get(targetId); };
async function control(tabId) {   // a session of our own for tab operations (navigation, history)
  const key = 'ctl' + tabId;
  if (!sessions.has(key)) sessions.set(key, (await cdp('Target.attachToTarget', { targetId: targets.get(tabId), flatten: true })).sessionId);
  return sessions.get(key);
}
async function tabInfo(id) {
  const targetId = targets.get(id);
  if (!targetId) throw Error(`No tab with id: ${id}.`);
  const { targetInfo } = await cdp('Target.getTargetInfo', { targetId });
  return { id, windowId: 1, url: targetInfo.url === 'about:blank' ? '' : targetInfo.url, pendingUrl: targetInfo.url, title: targetInfo.title, groupId: groupOf.get(id) ?? -1, incognito: false, active: false };
}
const chrome = {
  runtime: { getManifest: () => ({ version: 'live-check' }), lastError: undefined, onInstalled: event(), onStartup: event(),
    connectNative() { const p = { onMessage: event(), onDisconnect: event(), sent: [], postMessage(m) { this.sent.push(m); } }; native.push(p); return p; } },
  storage: { session: { data: {}, async get(k) { return { [k]: this.data[k] }; }, async set(v) { Object.assign(this.data, v); } } },
  alarms: { create() {}, onAlarm: event() },
  windows: { getAll: async () => [{ id: 1, incognito: false, type: 'normal' }], update: async () => ({}) },
  tabGroups: { get: async id => { if (!groups.has(id)) throw Error('No group'); return groups.get(id); }, update: async (id, v) => Object.assign(groups.get(id), v) },
  tabs: {
    onUpdated: event(), onRemoved: event(),
    async create({ url }) { const { targetId } = await cdp('Target.createTarget', { url }); const id = idFor(targetId); return { id, windowId: 1, url: '', pendingUrl: url, groupId: -1 }; },
    get: tabInfo,
    async query() {
      const { targetInfos } = await cdp('Target.getTargets');
      return Promise.all(targetInfos.filter(t => t.type === 'page').map(t => tabInfo(idFor(t.targetId))));
    },
    async update(id, { url }) { if (url) await cdp('Page.navigate', { url }, await control(id)); return tabInfo(id); },
    async goBack(id) { await cdp('Runtime.evaluate', { expression: 'history.back()' }, await control(id)); },
    async remove(id) { await cdp('Target.closeTarget', { targetId: targets.get(id) }); for (const fn of chrome.tabs.onRemoved.listeners) fn(id); },
    async group({ tabIds: ids, groupId }) { const g = groupId ?? nextGroup++; if (!groups.has(g)) groups.set(g, { id: g }); for (const t of ids) groupOf.set(t, g); return g; },
  },
  debugger: {
    onEvent: event(), onDetach: event(),
    async attach({ tabId }) { sessions.set(tabId, (await cdp('Target.attachToTarget', { targetId: targets.get(tabId), flatten: true })).sessionId); },
    async detach({ tabId }) { const s = sessions.get(tabId); sessions.delete(tabId); if (s) await cdp('Target.detachFromTarget', { sessionId: s }).catch(() => {}); },
    sendCommand({ tabId }, method, params) { const s = sessions.get(tabId); if (!s) return Promise.reject(Error('Debugger is not attached to the tab')); return cdp(method, params, s); },
  },
};
eventListeners.push(m => {
  for (const [tabId, s] of sessions) if (s === m.sessionId && typeof tabId === 'number') for (const fn of chrome.debugger.onEvent.listeners) fn({ tabId }, m.method, m.params);
});

// ---------------------------------------------------------------- the extension, as Chrome would run it
const native = [];
const source = fs.readFileSync(new URL('../browser/extension/background.js', import.meta.url), 'utf8').replace(/^import .*from "\.\/mate-core.mjs";$/m, '');
const context = vm.createContext({ chrome, BrowserBridge, snapshotLines, crypto: webcrypto, console, setTimeout, clearTimeout });
vm.runInContext(source, context);
async function command(op, fields = {}) {
  const connection = native.at(-1), id = webcrypto.randomUUID();
  trace('command', op);
  await connection.onMessage.listeners[0]({ type: 'command', id, op, ...fields });
  trace('reply', op, JSON.stringify(connection.sent.find(m => m.id === id))?.slice(0, 160));
  const reply = connection.sent.find(m => m.id === id);
  assert.ok(reply, `no reply to ${op}`);
  return reply;
}
const ok = async (op, fields) => { const r = await command(op, fields); assert.equal(r.ok, true, `${op}: ${r.error}`); return r.result; };
const fails = async (op, fields, pattern) => { const r = await command(op, fields); assert.equal(r.ok, false, `${op} should fail`); assert.match(r.error, pattern); return r.error; };
const ref = (page, role, name) => { const e = page.elements.find(x => x.role === role && x.name.includes(name)); assert.ok(e, `no ${role} "${name}"`); return e.ref; };
const inPage = async (tabId, expression) => (await cdp('Runtime.evaluate', { expression, returnByValue: true }, await control(tabId))).result.value;

const checks = [];
// Each check reports as it ends and has 30 s: a hang is a failure, not a stuck run.
async function check(name, fn) {
  let timer;
  const limit = new Promise((_, reject) => { timer = setTimeout(() => reject(Error('timed out after 30 s')), 30000); });
  try { await Promise.race([fn(), limit]); checks.push(['ok', name]); } catch (error) { checks.push(['FAIL', name, error.message]); }
  finally { clearTimeout(timer); }
  const [status, , why] = checks.at(-1);
  console.log(`${status === 'ok' ? '✔' : '✖'} ${name}${why ? `\n    ${why}` : ''}`);
}
try {
  let tab, form;
  await check('open a new tab: settled page with numbered controls, in the HeyMate group', async () => {
    form = await ok('open', { url: `${site}/form` });
    tab = form.tabId;
    assert.equal(form.title, 'Form'); assert.equal(form.url, `${site}/form`);
    ref(form, 'textbox', 'Name'); ref(form, 'button', 'Save');
    assert.ok(form.elements.find(e => e.name === 'Name').editable);
    assert.equal(groupOf.has(tab), true); assert.equal(groups.get(groupOf.get(tab)).title, 'HeyMate');
  });
  await check('type, then click: the page changed as a user would have made it change', async () => {
    await ok('type', { tabId: tab, ref: ref(form, 'textbox', 'Name'), text: 'Ada' });
    const after = await ok('click', { tabId: tab, ref: ref(form, 'button', 'Save') });
    assert.match(after.text, /Saved: Ada/);
  });
  await check("HeyMate's pointer is on the page and the earlier build's is gone", async () => {
    assert.equal(await inPage(tab, "document.querySelectorAll('heymate-cursor').length"), 1);
    assert.equal(await inPage(tab, "document.querySelectorAll('reference-renderer-cursor').length"), 0);
  });
  await check('a covered control, a password field and a disabled button are refused', async () => {
    form = await ok('snapshot', { tabId: tab });
    await fails('click', { tabId: tab, ref: ref(form, 'button', 'Under') }, /covered/);
    await fails('type', { tabId: tab, ref: ref(form, 'textbox', 'Secret'), text: 'x' }, /Password/);
    const locked = form.elements.find(e => e.name === 'Locked');
    if (locked) await fails('click', { tabId: tab, ref: locked.ref }, /disabled/);
  });
  await check('a stale reference is refused after the page changes', async () => {
    const old = ref(form, 'link', 'Next');
    await ok('navigate', { tabId: tab, url: `${site}/next` });
    await fails('click', { tabId: tab, ref: old }, /stale|Unknown/);
  });
  await check('back returns to the form; extract reads text, links and tables', async () => {
    const back = await ok('back', { tabId: tab });
    assert.equal(back.title, 'Form');
    const read = await ok('extract', { tabId: tab });
    assert.match(read.text, /Bottom of form/);
    assert.ok(read.links.some(l => l.url === `${site}/next`));
    assert.deepEqual(read.tables[0][1], ['Tea', '3']);
  });
  await check('scroll moves the page', async () => {
    await ok('scroll', { tabId: tab, direction: 'down' });
    const at = [];
    for (let k = 0; k < 5; k++) { at.push(await inPage(tab, 'scrollY')); await new Promise(r => setTimeout(r, 200)); }
    assert.ok(at[0] > 100, `scrollY right after the reply: ${at.join(', ')}`);
  });
  await check('wait_for waits for late text', async () => {
    await ok('navigate', { tabId: tab, url: `${site}/slow` });
    await ok('wait_for', { tabId: tab, text: 'Ready now', timeout: 4000 });
  });
  await check('a page dialog blocks other actions until answered explicitly', async () => {
    const d = await ok('navigate', { tabId: tab, url: `${site}/dialog` });
    const asked = await command('click', { tabId: tab, ref: ref(d, 'button', 'Ask') });
    assert.equal(asked.ok, true, asked.error);
    await fails('press', { tabId: tab, key: 'Tab' }, /dialog/);
    const answered = await ok('dialog', { tabId: tab, accept: true });
    assert.match(answered.text, /yes/);
  });
  await check('upload sets a file input to the approved file', async () => {
    const file = path.join(profile, 'fixture.txt'); fs.writeFileSync(file, 'hello');
    const u = await ok('navigate', { tabId: tab, url: `${site}/upload` });
    const fileRef = (u.elements.find(e => /File/.test(e.name)) || u.elements[0]).ref;
    const done = await ok('upload', { tabId: tab, ref: fileRef, paths: [file], expectedURL: `${site}/upload` });
    assert.match(done.text, /Got fixture\.txt/);
  });
  await check('the user using the page takes it over', async () => {
    const f = await ok('navigate', { tabId: tab, url: `${site}/form` });
    await new Promise(r => setTimeout(r, 1100));
    const s = await control(tab);
    await cdp('Input.dispatchMouseEvent', { type: 'mousePressed', x: 5, y: 5, button: 'left', clickCount: 1 }, s);
    await cdp('Input.dispatchMouseEvent', { type: 'mouseReleased', x: 5, y: 5, button: 'left', clickCount: 1 }, s);
    await fails('click', { tabId: tab, ref: ref(f, 'button', 'Save') }, /took control/);
  });
  await check('after a takeover the turn can still be ended, and the next one works', async () => {
    await ok('end');
    const again = await ok('open', { url: `${site}/next` });
    assert.equal(again.title, 'Next');
  });
  await check('end tidies the turn: its background tab closes, a kept tab stays without the pointer', async () => {
    const second = await ok('open', { url: `${site}/form` });
    assert.equal(await inPage(second.tabId, "document.querySelectorAll('heymate-cursor').length"), 1);
    const kept = await ok('open', { url: `${site}/form` });
    await ok('click', { tabId: kept.tabId, ref: ref(kept, 'button', 'Save') });
    await ok('keep', { tabId: kept.tabId, why: 'result' });
    const ended = await ok('end');
    assert.ok(ended.closed.includes(second.tabId), `closed ${JSON.stringify(ended.closed)}`);
    assert.ok(!ended.closed.includes(kept.tabId));
    const { targetInfos } = await cdp('Target.getTargets');
    assert.equal(targetInfos.some(t => t.targetId === targets.get(second.tabId)), false);
    assert.equal(await inPage(kept.tabId, "document.querySelectorAll('heymate-cursor').length"), 0);
  });
} finally {
  ws.close(); server.close();
  await new Promise(r => { browser.once('exit', r); browser.kill(); });
  fs.rmSync(profile, { recursive: true, force: true, maxRetries: 5 });
  const failed = checks.filter(c => c[0] !== 'ok').length;
  console.log(`${checks.length - failed}/${checks.length} live checks passed`);
  process.exitCode = failed ? 1 : 0;
}
