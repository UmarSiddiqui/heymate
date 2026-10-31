// HeyMate browser engine. Written from the native adapter contract and regression
// requirements, using Chrome's tab, accessibility, DOM and input protocols.
// Page scripts below are fixed functions, never model-supplied JavaScript.
export function webURL(value) {
  let url;
  try { url = new URL(value); } catch { throw Error('A valid HTTP(S) URL is required.'); }
  if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password) {
    throw Error('Only HTTP(S) URLs without credentials are allowed.');
  }
  return url.href;
}
export const GROUP_COLOR = 'blue';
export const LIMITS = Object.freeze({ load: 8000, single: 20000, batch: 30000,
  batchSteps: 20, wait: 10000, waitMax: 20000, download: 45000, saving: 3000 });
const normalized = value => String(value ?? '').replace(/\s+/g, ' ').trim();
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
export function groupTitle(value) {
  const title = normalized(value) || 'HeyMate';
  return title.length > 32 ? title.slice(0, 31) + '…' : title;
}
export function slugify(value) {
  return normalized(value).normalize('NFKD').replace(/[\u0300-\u036f]/g, '')
    .toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 64) || 'task';
}
export function snapshotLines(snapshot) {
  return (snapshot?.nodes ?? []).map(node => {
    const role = /^(statictext|inlinetextbox|text)$/i.test(node.role) ? 'text' : node.role;
    return `${role || 'text'}: ${normalized(node.name)}${node.disabled ? ' (disabled)' : ''}${node.ref ? ` [${node.ref}]` : ''}`;
  });
}
export class ModelView {
  constructor() { this.seen = new Map(); }
  forget(id) { this.seen.delete(String(id)); }
  // remember: false for a filtered view (a query), which must not become the page the next action is compared with.
  render(snapshot, tabId, fromAction, partial = false, remember = true) {
    const lines = snapshotLines(snapshot), id = String(tabId), previous = this.seen.get(id);
    if (remember) this.seen.set(id, { lines, url: snapshot.url, title: snapshot.title });
    const out = { tabId, url: snapshot.url, title: snapshot.title, elements: lines.join('\n') };
    if (partial) out.partial = true;
    if (fromAction && previous && previous.url === snapshot.url) {
      out.added = lines.filter(line => !previous.lines.includes(line));
      out.removed = previous.lines.filter(line => !lines.includes(line));
      out.unchanged = !out.added.length && !out.removed.length;
    }
    return out;
  }
  forModel(result, request = {}) {
    const page = result.snapshot ?? result;
    if (!Array.isArray(page.nodes)) return result;
    const query = normalized(request.query).toLowerCase();
    const selected = query ? { ...page, nodes: page.nodes.filter(n => normalized(n.name).toLowerCase().includes(query)) } : page;
    return this.render(selected, request.tabId ?? page.tabId, !!request.fromAction, !!query, !query);
  }
}

// Runs on a resolved DOM element. It only checks/focuses the target; real input
// goes through CDP. Covered, detached, disabled and secret fields fail closed.
function inspectTarget(mode) {
  if (!this.isConnected) return { error: 'Target is detached. Read the page again.' };
  const element = this.nodeType === 1 ? this : this.parentElement;
  if (!element) return { error: 'Target is not an element.' };
  const password = element.matches('input[type="password"]') || element.closest('input[type="password"]');
  if (password) return { error: 'Password fields require the user.' };
  if (element.disabled || element.getAttribute('aria-disabled') === 'true') return { error: 'Target is disabled.' };
  element.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
  const rect = element.getBoundingClientRect(), style = getComputedStyle(element);
  if (!rect.width || !rect.height || style.visibility === 'hidden' || style.display === 'none') return { error: 'Target is not visible.' };
  const x = Math.max(0, Math.min(innerWidth - 1, rect.x + rect.width / 2));
  const y = Math.max(0, Math.min(innerHeight - 1, rect.y + rect.height / 2));
  let top = document.elementFromPoint(x, y);
  while (top?.shadowRoot?.elementFromPoint) {
    const nested = top.shadowRoot.elementFromPoint(x, y);
    if (!nested || nested === top) break;
    top = nested;
  }
  if (!top || !(element === top || element.contains(top) || top.contains(element) || element.labels && [...element.labels].some(label => label.contains(top)))) {
    return { error: 'Target is covered. Close the covering control first.' };
  }
  if (mode === 'fill') {
    if (element.readOnly || !(element.matches('input,textarea') || element.isContentEditable)) return { error: 'Target is not editable.' };
    element.focus();
    if (typeof element.select === 'function') element.select();
    else { const range = document.createRange(); range.selectNodeContents(element); const selection = getSelection(); selection.removeAllRanges(); selection.addRange(range); }
  }
  return { x, y, tag: element.tagName, type: element.getAttribute('type') };
}

// Isolated-world page instrumentation, run as a fixed function: when the page last changed (so an action can wait
// for it to settle), whether the user has used the page since HeyMate's own input (they take over), and HeyMate's
// pointer. The pointer is an arrow in the user's cursor colour in a closed shadow root that glides to where HeyMate
// is about to click or type and rings once when it does. Pages left by earlier extension builds may still hold
// their pointer element ('reference-renderer-cursor'): it is removed when HeyMate's own appears.
function pageMonitor(action, color, x, y) {
  const key = Symbol.for('heymate.quiet');
  let monitor = globalThis[key];
  if (!monitor) {
    monitor = globalThis[key] = { changed: performance.now(), inputUntil: 0, human: 0, pointer: null };
    new MutationObserver(records => {
      if (records.some(record => !record.target.closest?.('heymate-cursor'))) monitor.changed = performance.now();
    }).observe(document, { subtree: true, childList: true, characterData: true, attributes: true });
    for (const event of ['pointerdown', 'keydown', 'wheel']) document.addEventListener(event, e => {
      if (e.isTrusted && performance.now() > monitor.inputUntil) monitor.human++;
    }, true);
  }
  if (action === 'input') monitor.inputUntil = performance.now() + 1000;
  let pointer = monitor.pointer;
  if (pointer && !pointer.host.isConnected) pointer = monitor.pointer = null;
  if ((action === 'show' || action === 'point') && !pointer) {
    for (const old of document.querySelectorAll('reference-renderer-cursor, heymate-cursor')) old.remove();
    const host = document.createElement('heymate-cursor');
    host.setAttribute('aria-hidden', 'true');
    host.style.cssText = 'all:initial;position:fixed!important;left:0!important;top:0!important;width:0!important;height:0!important;' +
      'z-index:2147483647!important;pointer-events:none!important;display:block!important;overflow:visible!important';
    const root = host.attachShadow({ mode: 'closed' });
    const tint = /^#[0-9a-f]{6}$/i.test(color || '') ? color : '#3380FF';
    root.innerHTML = '<style>' +
      '.p{position:absolute;left:0;top:0;transition:transform .22s cubic-bezier(.3,.7,.4,1),opacity .2s;opacity:0}' +
      '.p.on{opacity:1}' +
      '.r{position:absolute;left:-14px;top:-14px;width:28px;height:28px;border-radius:50%;border:2px solid ' + tint + ';opacity:0;transform:scale(.3)}' +
      '.r.go{animation:ring .45s ease-out}' +
      '@keyframes ring{0%{opacity:.9;transform:scale(.3)}100%{opacity:0;transform:scale(1.4)}}' +
      '</style><div class="p"><div class="r"></div><svg width="22" height="26" viewBox="0 0 22 26" style="position:absolute;left:-2px;top:-2px;' +
      'filter:drop-shadow(0 1px 2px rgba(0,0,0,.35))"><path d="M2 2 L2 21 L7.2 16.4 L10.6 24 L14 22.5 L10.7 15 L18 15 Z" fill="' + tint +
      '" stroke="#fff" stroke-width="1.6" stroke-linejoin="round"/></svg></div>';
    (document.body || document.documentElement).append(host);
    pointer = monitor.pointer = { host, body: root.querySelector('.p'), ring: root.querySelector('.r'), x: innerWidth - 40, y: innerHeight - 40 };
    pointer.body.style.transform = `translate(${pointer.x}px,${pointer.y}px)`;
    requestAnimationFrame(() => pointer.body.classList.add('on'));
  }
  if (pointer) {
    if (action === 'point' && Number.isFinite(x) && Number.isFinite(y)) {
      pointer.x = x; pointer.y = y; pointer.body.classList.add('on');
      pointer.body.style.transform = `translate(${x}px,${y}px)`;
    }
    if (action === 'ring') { pointer.ring.classList.remove('go'); void pointer.ring.offsetWidth; pointer.ring.classList.add('go'); }
    if (action === 'remove') { pointer.host.remove(); monitor.pointer = null; }
  }
  return { quietFor: performance.now() - monitor.changed, human: monitor.human, ready: document.readyState };
}
// The pointer's glide (pageMonitor's .22s transition) before the input it shows.
const POINTER_GLIDE = 220;
// Where the page and the boxes scrolled under a point stand: changes while a wheel scroll is still moving.
function scrollState(x, y) {
  const at = [scrollX, scrollY];
  for (let e = document.elementFromPoint(x, y); e; e = e.parentElement) if (e.scrollHeight > e.clientHeight) at.push(e.scrollTop);
  return at.join(',');
}
function readPage() {
  const clean = text => String(text ?? '').replace(/\s+/g, ' ').trim();
  return { title: document.title, url: location.href,
    text: (document.body?.innerText ?? '').slice(0, 60000),
    links: [...document.querySelectorAll('a[href]')].filter(a => a.getClientRects().length)
      .slice(0, 200).map(a => ({ text: clean(a.innerText).slice(0, 240), url: a.href })),
    tables: [...document.querySelectorAll('table')].slice(0, 20).map(t => [...t.rows].slice(0, 100)
      .map(r => [...r.cells].slice(0, 30).map(c => clean(c.innerText).slice(0, 1000)))) };
}

const interactiveRoles = new Set(['button', 'link', 'textbox', 'searchbox', 'combobox', 'checkbox', 'radio', 'switch', 'slider', 'spinbutton', 'menuitem', 'menuitemcheckbox', 'menuitemradio', 'tab', 'option', 'listbox', 'treeitem']);
const editableRoles = new Set(['textbox', 'searchbox', 'combobox', 'spinbutton']);
const storageKey = 'heymateBrowserOwnership';
export class BrowserBridge {
  constructor(api, uuid = () => crypto.randomUUID(), options = {}) {
    this.api = api; this.uuid = uuid; this.now = options.now ?? Date.now;
    this.limits = { ...LIMITS, ...options.limits };
    this.tasks = new Set(); this.owners = new Map(); this.ownedTabs = new Map();
    this.homes = new Map(); this.kept = new Map(); this.claims = new Map();
    this.tabs = new Map(); this.dialogs = new Map(); this.stopped = new Set();
    this.stopReasons = new Map(); this.queues = new Map(); this.downloads = new Map();
    this.pendingDownloads = new Map(); this.networkRequests = new Map();
    this.view = new ModelView(); this.nextRef = 1; this.persistence = Promise.resolve();
    this.store = options.store ?? (api?.storage?.session ? {
      load: async () => (await api.storage.session.get(storageKey))?.[storageKey] ?? null,
      save: value => api.storage.session.set({ [storageKey]: value }),
    } : null);
    this.colors = new Map(); this.dialogWaits = new Map();
    this.deadlines = new Map(); this.cleanups = new Map();
    this.downloadHints = new Map(); this.unmatchedDownloads = new Map();
  }
  owner(task) { return this.owners.get(task) ?? task; }
  assert(task) {
    if (this.stopped.has(task)) throw Error(`Browser access stopped for this turn: ${this.stopReasons.get(task) || 'turn ended'}`);
  }
  // Which tabs are whose survives Chrome stopping the extension's worker (saved for the browser session).
  persist() {
    if (!this.store) return Promise.resolve();
    const value = { owned: [...this.ownedTabs], homes: [...this.homes], kept: [...this.kept] };
    this.persistence = this.persistence.catch(() => {}).then(() => this.store.save(value));
    return this.persistence;
  }
  async restore() {
    if (!this.store) return;
    const data = await this.store.load();
    if (!data || !Array.isArray(data.owned)) return;
    for (const [id, owner] of data.owned) {
      if (!Number.isInteger(id) || typeof owner !== 'string') continue;
      try { await this.api.tabs.get(id); this.ownedTabs.set(id, owner); } catch { /* closed since suspension */ }
    }
    for (const [owner, home] of data.homes ?? []) if (typeof owner === 'string' && Number.isInteger(home?.groupId)) this.homes.set(owner, home);
    for (const [id, reason] of data.kept ?? []) if (this.ownedTabs.has(id)) this.kept.set(id, reason);
  }
  async current() { return (await this.api.tabs.query({ active: true, lastFocusedWindow: true }))[0] ?? null; }
  async fold(groupId) { if (groupId != null && this.api.tabGroups) await this.api.tabGroups.update(groupId, { collapsed: true }).catch(() => {}); }
  async stop(reason = 'browser access stopped') {
    // Mark every task synchronously before waiting for cleanup.
    for (const task of this.tasks) { this.stopped.add(task); this.stopReasons.set(task, reason); }
    await Promise.all([...this.tasks].map(task => this.end(task, false, reason)));
  }
  async end(task, tidy = false, reason = 'turn ended') {
    reason ??= 'turn ended';
    const owner = this.owner(task), home = this.homes.get(owner), closed = [];
    this.stopped.add(task); this.stopReasons.set(task, reason); this.tasks.delete(task);
    const ownerStillRunning = [...this.tasks].some(other => this.owner(other) === owner);
    if (tidy && !ownerStillRunning) {
      const current = await this.current();
      for (const [id, holder] of [...this.ownedTabs]) {
        if (holder !== owner || this.kept.has(id)) continue;
        try {
          const tab = await this.api.tabs.get(id);
          if (id !== current?.id && tab.groupId === home?.groupId) { await this.api.tabs.remove(id); closed.push(id); }
        } catch { /* tab already closed */ }
        this.ownedTabs.delete(id);
      }
    }
    for (const [id, holder] of [...this.claims]) if (holder === task) await this.release(id, task);
    if (!ownerStillRunning) await this.fold(home?.groupId);
    await this.persist();
    return { closed };
  }
  // Racing a promise does not cancel Chrome's work. Expired turns are stopped
  // before cleanup, so late replies cannot run subsequent steps or be replayed.
  bounded(work, deadline, message = 'Browser action timed out. Outcome may be unknown; inspect the page before retrying.') {
    return new Promise((resolve, reject) => {
      const expire = () => { const error = Error(message); error.code = 'HEYMATE_BROWSER_TIMEOUT'; reject(error); };
      const remaining = deadline - this.now();
      if (remaining <= 0) { expire(); return; }
      const timer = setTimeout(expire, remaining);
      Promise.resolve().then(work).then(resolve, reject).finally(() => clearTimeout(timer));
    });
  }
  async release(id, task, expired = false) {
    if (this.claims.get(id) !== task) return;
    this.claims.delete(id);
    const state = this.tabs.get(id);
    this.tabs.delete(id); this.view.forget(id); this.dialogWaits.delete(id);
    if (!state) return;
    // Keep the tab unavailable until detach actually finishes. A late attach or
    // detach must not interfere with a new task's debugger session.
    const entry = { state };
    const cleanup = Promise.resolve().then(async () => {
      if (state.attaching) {
        try { await state.attachment; } catch { return; }
      }
      if (!state.attached) return;
      if (!expired && !this.dialogs.has(id)) {
        const expressions = [
          ...(state.world == null ? [] : [{ contextId: state.world, expression: `(${pageMonitor})('remove')` }]),
          { expression: "for (const n of document.querySelectorAll('heymate-cursor')) n.remove()" },
        ];
        for (const params of expressions) {
          if (!state.attached) return;
          await this.bounded(
            () => this.api.debugger.sendCommand({ tabId: id }, 'Runtime.evaluate', { ...params, returnByValue: true }),
            this.now() + 200).catch(() => {});
        }
      }
      if (state.attached) {
        try { await this.api.debugger.detach({ tabId: id }); }
        catch (error) { if (state.attached) throw error; }
      }
    });
    entry.promise = cleanup;
    this.cleanups.set(id, entry);
    cleanup.then(() => {
      if (this.cleanups.get(id) === entry) this.cleanups.delete(id);
    }, () => { /* Keep quarantined on detach failure; do not attach another task. */ });
    await this.bounded(() => cleanup, this.now() + 800).catch(() => {});
  }
  invalidate(id) {
    const state = this.tabs.get(id);
    if (state) { state.epoch++; state.refs.clear(); state.refIds.clear(); state.world = null; state.human = null; }
    this.view.forget(id);
  }
  removed(id) { this.ownedTabs.delete(id); this.kept.delete(id); this.claims.delete(id); this.tabs.delete(id); this.dialogs.delete(id); void this.persist(); }
  detached(id, reason) {
    const active = this.tabs.get(id), state = active ?? this.cleanups.get(id)?.state;
    if (state) state.attached = false;
    if (active) { this.invalidate(id); this.stopped.add(active.task); this.stopReasons.set(active.task, `Chrome debugger detached (${reason}).`); }
  }
  // A page dialog stops the page's scripts, and Chrome answers the input that opened it only once it closes: input
  // waits for its reply or for a dialog, whichever comes first (dialogShown).
  dialogOpened(id, params = {}) {
    this.dialogs.set(id, params);
    const waits = this.dialogWaits.get(id);
    this.dialogWaits.delete(id);
    for (const wake of waits ?? []) wake();
  }
  // A command's reply, or nothing as soon as a dialog is open on the tab (the reply is then left to arrive or not).
  untilDialog(id, reply) {
    reply.catch(() => {});
    if (this.dialogs.has(id)) return Promise.resolve();
    return new Promise((resolve, reject) => {
      const waits = this.dialogWaits.get(id) ?? [];
      this.dialogWaits.set(id, waits);
      const done = () => { const k = waits.indexOf(wake); if (k >= 0) waits.splice(k, 1); };
      const wake = () => resolve();
      waits.push(wake);
      reply.then(value => { done(); resolve(value); }, error => { done(); reject(error); });
    });
  }
  dialogClosed(id) { this.dialogs.delete(id); }
  fileChooserOpened() { /* Upload targets are resolved file inputs; native chooser is not automated. */ }
  network(id, method, params = {}) {
    if (!this.networkRequests.has(id)) this.networkRequests.set(id, new Map());
    const requests = this.networkRequests.get(id);
    if (method === 'Network.requestWillBeSent' && params.request?.method && !['GET', 'HEAD', 'OPTIONS'].includes(params.request.method)) requests.set(params.requestId, this.now());
    if (method === 'Network.loadingFinished' || method === 'Network.loadingFailed') requests.delete(params.requestId);
  }
  async saving(id, deadline) {
    while (this.networkRequests.get(id)?.size && this.now() < deadline) await pause(50);
    return !this.networkRequests.get(id)?.size;
  }
  async queued(id, work) {
    const previous = this.queues.get(id) ?? Promise.resolve();
    const next = previous.catch(() => {}).then(work); this.queues.set(id, next);
    try { return await next; } finally { if (this.queues.get(id) === next) this.queues.delete(id); }
  }
  async claim(task, id) {
    this.assert(task);
    if (this.cleanups.has(id)) throw Error('Tab debugger cleanup is pending. Use another tab or reconnect after cleanup.');
    const owner = this.owner(task), other = this.claims.get(id), owned = this.ownedTabs.get(id);
    if ((other && other !== task && this.tasks.has(other)) || (owned && owned !== owner && [...this.tasks].some(t => this.owner(t) === owned))) throw Error('Tab belongs to another running browser task.');
    if (other && other !== task) await this.release(id, other);
    if (this.cleanups.has(id)) throw Error('Tab debugger cleanup is pending. Use another tab or reconnect after cleanup.');
    this.assert(task); this.claims.set(id, task);
  }
  async tab(task, id) {
    const tab = await this.api.tabs.get(id);
    this.assert(task);
    if (tab.incognito) throw Error('Private browsing is not supported.');
    webURL(tab.url || tab.pendingUrl);
    await this.claim(task, id);
    let state = this.tabs.get(id);
    if (!state) { state = { task, attached: false, epoch: 0, refs: new Map(), refIds: new Map(), world: null, human: null }; this.tabs.set(id, state); }
    if (!state.attached) {
      state.attaching = true;
      state.attachment = Promise.resolve().then(() => this.api.debugger.attach({ tabId: id }, '1.3'));
      try { await state.attachment; state.attached = true; }
      finally { state.attaching = false; }
      this.assert(task);
      try {
        for (const method of ['Page.enable', 'DOM.enable', 'Runtime.enable', 'Accessibility.enable', 'Network.enable']) await this.command(task, id, method);
      } catch (error) { await this.release(id, task); throw error; }
    }
    return state;
  }
  async command(task, id, method, params = {}) {
    this.assert(task);
    if (this.claims.get(id) !== task) throw Error('Tab claim changed. Read the page again.');
    const result = await this.bounded(
      () => { this.assert(task); return this.api.debugger.sendCommand({ tabId: id }, method, params); },
      this.deadlines.get(id) ?? this.now() + this.limits.single);
    this.assert(task); return result;
  }
  async world(task, id, state) {
    if (state.world == null) {
      const epoch = state.epoch;
      const tree = await this.command(task, id, 'Page.getFrameTree');
      const created = await this.command(task, id, 'Page.createIsolatedWorld', { frameId: tree.frameTree.frame.id, worldName: 'HeyMate browser observer' });
      if (state.epoch !== epoch) throw Error('Page navigated. Read it again.');
      state.world = created.executionContextId;
    }
    return state.world;
  }
  async evaluate(task, id, state, fn, args = []) {
    const contextId = await this.world(task, id, state), epoch = state.epoch;
    const result = await this.command(task, id, 'Runtime.evaluate', { contextId,
      expression: `(${fn})(${args.map(value => value === undefined ? 'undefined' : JSON.stringify(value)).join(',')})`, returnByValue: true });
    if (result.exceptionDetails) throw Error(`Page observer failed (${result.exceptionDetails.exception?.description?.split('\n')[0] || result.exceptionDetails.text}). Read the page again.`);
    if (state.epoch !== epoch) throw Error('Page navigated during observation. Read it again.');
    return result.result?.value;
  }
  async monitor(task, id, state, action, color, x, y) {
    // Without the pointer (bridge.cursor false) the page is still watched; nothing is drawn on it.
    if (this.cursor === false && ['show', 'point', 'ring'].includes(action)) action = 'watch';
    const result = await this.evaluate(task, id, state, pageMonitor, [action, color ?? this.colors.get(task), x, y]);
    if (state.human == null) state.human = result.human;
    else if (result.human > state.human) {
      this.stopped.add(task); this.stopReasons.set(task, 'User took control of the page.'); this.assert(task);
    }
    return result;
  }
  async settle(task, id, state, deadline) {
    const until = Math.min(deadline, this.now() + this.limits.load);
    while (this.now() < until) {
      this.assert(task);
      const before = state.epoch;
      try {
        const m = await this.monitor(task, id, state, 'show');
        if (m.ready !== 'loading' && m.quietFor >= 120) return;
      } catch (error) {
        if (this.stopped.has(task)) throw error;
        if (state.epoch === before && !/context|navigat/i.test(error.message)) throw error;
      }
      await pause(50);
    }
  }
  async snapshot(task, id, state, deadline = this.now() + this.limits.single) {
    const epoch = state.epoch;
    const { nodes = [] } = await this.command(task, id, 'Accessibility.getFullAXTree');
    if (state.epoch !== epoch) throw Error('Page navigated during snapshot. Read again.');
    const out = [];
    for (const node of nodes) {
      if (node.ignored) continue;
      const role = node.role?.value, name = normalized(node.name?.value);
      if (!role || role === 'InlineTextBox' || !name && !interactiveRoles.has(role)) continue;
      const properties = Object.fromEntries((node.properties ?? []).map(p => [p.name, p.value?.value]));
      const item = { role, name: name.slice(0, 2000) };
      if (properties.disabled) item.disabled = true;
      if (editableRoles.has(role)) item.editable = true;
      if (node.backendDOMNodeId && (interactiveRoles.has(role) || properties.focusable)) {
        let ref = state.refIds.get(node.backendDOMNodeId);
        if (!ref) { ref = `e${this.nextRef++}`; state.refIds.set(node.backendDOMNodeId, ref); }
        state.refs.set(ref, { backendNodeId: node.backendDOMNodeId, epoch }); item.ref = ref;
      }
      out.push(item);
      if (out.length >= 2000) break;
    }
    const tab = await this.api.tabs.get(id); this.assert(task);
    if (state.epoch !== epoch) throw Error('Page navigated during snapshot. Read again.');
    return { tabId: id, url: tab.url, title: tab.title ?? '', nodes: out };
  }
  async target(task, id, state, ref, mode) {
    const target = state.refs.get(ref);
    if (!target || target.epoch !== state.epoch) throw Error('Unknown or stale reference. Read the page again.');
    const epoch = state.epoch;
    const resolved = await this.command(task, id, 'DOM.resolveNode', { backendNodeId: target.backendNodeId, executionContextId: await this.world(task, id, state) });
    const objectId = resolved.object?.objectId;
    if (!objectId) throw Error('Target disappeared. Read the page again.');
    try {
      const result = await this.command(task, id, 'Runtime.callFunctionOn', { objectId,
        functionDeclaration: inspectTarget.toString(), arguments: [{ value: mode }], returnByValue: true });
      if (result.exceptionDetails) throw Error('Target changed. Read the page again.');
      if (result.result?.value?.error) throw Error(result.result.value.error);
      if (state.epoch !== epoch) throw Error('Page navigated. Read the page again.');
      return { ...result.result.value, backendNodeId: target.backendNodeId, epoch };
    } finally { await this.command(task, id, 'Runtime.releaseObject', { objectId }).catch(() => {}); }
  }
  async input(task, id, state, work) {
    if (this.dialogs.has(id)) throw Error('A page dialog is open. Answer it explicitly first.');
    await this.monitor(task, id, state, 'input');
    state.inputAt = this.now();
    const epoch = state.epoch;
    const send = (method, params) => {
      if (state.epoch !== epoch) throw Error('Page navigated before input. Read it again.');
      return this.untilDialog(id, this.command(task, id, method, params));
    };
    return work(send);
  }
  async key(task, id, state, raw) {
    const parts = String(raw).split('+'), name = parts.pop();
    const modifierValues = { Alt: 1, Control: 2, Ctrl: 2, Meta: 4, Command: 4, Cmd: 4, Shift: 8 };
    let modifiers = 0;
    for (const part of parts) { if (!modifierValues[part]) throw Error('Unknown key modifier.'); modifiers |= modifierValues[part]; }
    const keys = { Enter: ['Enter', 13], Tab: ['Tab', 9], Escape: ['Escape', 27], Esc: ['Escape', 27], Backspace: ['Backspace', 8], Delete: ['Delete', 46], ArrowLeft: ['ArrowLeft', 37], ArrowUp: ['ArrowUp', 38], ArrowRight: ['ArrowRight', 39], ArrowDown: ['ArrowDown', 40], Home: ['Home', 36], End: ['End', 35], PageUp: ['PageUp', 33], PageDown: ['PageDown', 34], Space: [' ', 32] };
    if (!(name in keys) && name.length !== 1) throw Error('Unsupported key.');
    if (!['Tab', 'Escape', 'Esc'].includes(name)) {
      const password = await this.evaluate(task, id, state, () => document.activeElement?.matches('input[type="password"]'));
      if (password) throw Error('Password fields require the user.');
    }
    const [key, code] = keys[name] ?? [name, name.toUpperCase().charCodeAt(0)];
    await this.input(task, id, state, async send => {
      await send('Input.dispatchKeyEvent', { type: 'keyDown', key, windowsVirtualKeyCode: code, modifiers, ...(key === 'Enter' ? { text: '\r' } : name.length === 1 && !modifiers ? { text: name } : {}) });
      await send('Input.dispatchKeyEvent', { type: 'keyUp', key, windowsVirtualKeyCode: code, modifiers });
    });
  }
  async openNew(request) {
    const { task } = request, owner = this.owner(task), url = webURL(request.url);
    const home = this.homes.get(owner);
    const windows = await this.api.windows.getAll({ windowTypes: ['normal'] });
    const window = windows.find(w => !w.incognito && w.id === home?.windowId) ?? windows.find(w => !w.incognito);
    this.assert(task);
    if (!window) throw Error('Open a normal Chrome window first.');
    const tab = await this.api.tabs.create({ url, windowId: window.id, active: false });
    // Record creation before the stop check so cleanup can still identify this tab.
    this.ownedTabs.set(tab.id, owner);
    let groupId;
    if (home) {
      try { await this.api.tabGroups.get(home.groupId); groupId = home.groupId; } catch { /* previous group closed */ }
    }
    groupId = await this.api.tabs.group({ tabIds: [tab.id], ...(groupId == null ? {} : { groupId }) });
    this.homes.set(owner, { windowId: window.id, groupId });
    await this.api.tabGroups.update(groupId, { title: groupTitle(request.groupTitle), color: GROUP_COLOR, collapsed: false });
    await this.persist(); this.assert(task);
    return tab.id;
  }
  async execute(request) {
    if (!request || typeof request.task !== 'string' || !request.task) throw Error('Browser task identity required.');
    const task = request.task;
    // A stopped turn (the user took over, the app disconnected) can always be ended: that is how the next one starts.
    if (request.operation === 'end') {
      if (!this.owners.has(task) && request.owner) this.owners.set(task, request.owner);
      return this.end(task, !!request.tidy, this.stopReasons.get(task));
    }
    this.assert(task);
    if (request.owner != null && (typeof request.owner !== 'string' || !request.owner)) throw Error('Invalid browser owner.');
    if (this.owners.has(task) && request.owner != null && this.owner(task) !== request.owner) throw Error('Task owner cannot change.');
    const owner = request.owner ?? this.owner(task);
    const newTurn = !this.tasks.has(task) && ![...this.tasks].some(other => this.owner(other) === owner);
    this.owners.set(task, owner); this.tasks.add(task);
    // A keep belongs to the turn that requested it. Persisted marks survive a
    // worker restart, but must be renewed when this owner begins another turn.
    if (newTurn) {
      let changed = false;
      for (const id of this.kept.keys()) if (this.ownedTabs.get(id) === owner) { this.kept.delete(id); changed = true; }
      if (changed) { await this.persist(); this.assert(task); }
    }
    if (typeof request.cursorColor === 'string') this.colors.set(task, request.cursorColor);
    if (request.operation === 'tabs') {
      const current = await this.current(), tabs = await this.api.tabs.query({}); this.assert(task);
      return { tabs: tabs.filter(t => !t.incognito && /^https?:\/\//.test(t.url ?? '')).map(t => ({ ...t, current: t.id === current?.id })) };
    }
    if (request.operation === 'download') return this.download(task, request.url);
    let id = request.tabId, opened = false;
    if (request.operation === 'open' && id == null) { id = await this.openNew(request); opened = true; }
    if (!Number.isInteger(id)) throw Error('A tab ID is required.');
    await this.claim(task, id);
    if (request.operation === 'keep') {
      if (this.ownedTabs.get(id) !== this.owner(task)) throw Error('Only a tab created by this owner can be kept.');
      if (!['result', 'waiting'].includes(request.why)) throw Error('Keep reason must be result or waiting.');
      this.kept.set(id, request.why); await this.persist(); return { kept: true, tabId: id };
    }
    if (request.operation === 'close') {
      if (this.ownedTabs.get(id) !== this.owner(task)) throw Error('Only a tab created by this owner can be closed.');
      await this.api.tabs.remove(id); this.removed(id); return { closed: id };
    }
    return this.queued(id, async () => {
      const deadline = this.now() + (request.operation === 'batch' ? this.limits.batch : this.limits.single);
      this.deadlines.set(id, deadline);
      try {
        return await this.bounded(() => this.runTab(request, id, opened, deadline), deadline);
      } catch (error) {
        if (error.code === 'HEYMATE_BROWSER_TIMEOUT') {
          this.stopped.add(task); this.stopReasons.set(task, error.message);
          this.invalidate(id);
          await this.release(id, task, true);
        }
        throw error;
      } finally { this.deadlines.delete(id); }
    });
  }
  async runTab(request, id, opened, deadline) {
    const task = request.task, state = await this.tab(task, id);
    if (request.operation === 'snapshot') return this.snapshot(task, id, state, deadline);
    if (request.operation === 'extract') return this.evaluate(task, id, state, readPage);
    const steps = request.operation === 'batch' ? request.steps : [request];
    if (!Array.isArray(steps) || !steps.length || steps.length > this.limits.batchSteps) throw Error('Batch needs 1–20 steps.');
    const results = []; let error;
    for (const step of steps) {
      try {
        this.assert(task);
        if (this.now() >= deadline) throw Error('Browser action time limit reached. Verify page before retrying.');
        if (step.operation !== 'dialog' && this.dialogs.has(id)) throw Error('A page dialog is open. Answer it explicitly first.');
        const value = await this.act({ ...step, task, tabId: id, opened }, state, deadline);
        results.push({ operation: step.operation, ...value });
        if (!this.dialogs.has(id)) await this.settle(task, id, state, deadline);
      } catch (failure) {
        if (failure.code === 'HEYMATE_BROWSER_TIMEOUT') throw failure;
        error = failure.message; results.push({ operation: step.operation, error }); break;
      }
    }
    const out = { tabId: id, steps: results, ...(error ? { error } : {}) };
    if (!this.stopped.has(task) && !this.dialogs.has(id)) {
      try { out.snapshot = await this.snapshot(task, id, state, deadline); }
      catch (failure) {
        if (failure.code === 'HEYMATE_BROWSER_TIMEOUT') throw failure;
        out.snapshotError = failure.message;
      }
    }
    return out;
  }
  async act(request, state, deadline) {
    const { task, tabId: id, operation } = request;
    if (operation === 'open') {
      if (request.opened) return {};
      const url = webURL(request.url);
      if (!this.ownedTabs.has(id)) {
        // Explicit navigation can use a user's tab; closing it remains forbidden.
        const current = await this.api.tabs.get(id); if (current.incognito) throw Error('Private browsing is not supported.');
      }
      this.invalidate(id); await this.api.tabs.update(id, { url }); return {};
    }
    if (operation === 'back') { this.invalidate(id); await this.api.tabs.goBack(id); return {}; }
    if (operation === 'dialog') {
      if (!this.dialogs.has(id)) throw Error('No page dialog is open.');
      if (typeof request.accept !== 'boolean') throw Error('Explicit dialog acceptance or dismissal required.');
      await this.command(task, id, 'Page.handleJavaScriptDialog', { accept: request.accept, ...(request.text == null ? {} : { promptText: String(request.text) }) });
      this.dialogs.delete(id); return {};
    }
    if (operation === 'wait_for') {
      if (!request.text && !request.url) throw Error('wait_for needs text or a URL.');
      const limit = Math.min(deadline, this.now() + Math.min(Math.max(Number(request.timeout) || this.limits.wait, 1), this.limits.waitMax));
      do {
        const page = await this.evaluate(task, id, state, readPage);
        if ((!request.text || page.text.includes(String(request.text))) && (!request.url || page.url.includes(String(request.url)))) return {};
        await pause(100);
      } while (this.now() < limit);
      throw Error('Timed out waiting for expected page text or URL.');
    }
    if (operation === 'press') { await this.key(task, id, state, request.key); return {}; }
    if (operation === 'scroll') {
      const view = await this.command(task, id, 'Page.getLayoutMetrics');
      const height = view.cssVisualViewport?.clientHeight ?? view.visualViewport?.clientHeight ?? 600;
      const x = 100, y = Math.min(height / 2, 300);
      const before = await this.evaluate(task, id, state, scrollState, [x, y]);
      await this.input(task, id, state, send => send('Input.dispatchMouseEvent', { type: 'mouseWheel', x, y, deltaX: 0, deltaY: (request.direction === 'up' ? -1 : 1) * height * 0.75 }));
      // Chrome scrolls smoothly after the wheel: wait until it has started and stopped (or nothing moved in a second).
      let last = before, still = 0;
      for (const until = Math.min(deadline, this.now() + 1000); this.now() < until && still < 2;) {
        await pause(50);
        const now = await this.evaluate(task, id, state, scrollState, [x, y]);
        still = now === last && now !== before ? still + 1 : 0; last = now;
      }
      return {};
    }
    if (operation === 'click' || operation === 'fill' || operation === 'upload') {
      const target = await this.target(task, id, state, request.ref, operation);
      if (operation !== 'upload') {
        await this.monitor(task, id, state, 'point', undefined, target.x, target.y);
        await pause(POINTER_GLIDE);
      }
      if (operation === 'upload') {
        const paths = request.paths;
        if (!Array.isArray(paths) || !paths.length || paths.length > 10 || paths.some(p => typeof p !== 'string' || !p.startsWith('/') || p.includes('\0'))) throw Error('Upload needs 1–10 absolute file paths.');
        if (target.tag !== 'INPUT' || target.type !== 'file') throw Error('Upload target must be a file input.');
        await this.command(task, id, 'DOM.setFileInputFiles', { backendNodeId: target.backendNodeId, files: paths }); return {};
      }
      await this.input(task, id, state, async send => {
        if (state.epoch !== target.epoch) throw Error('Page navigated before input.');
        if (operation === 'fill') await send('Input.insertText', { text: String(request.text ?? '') });
        else {
          await send('Input.dispatchMouseEvent', { type: 'mouseMoved', x: target.x, y: target.y });
          await send('Input.dispatchMouseEvent', { type: 'mousePressed', x: target.x, y: target.y, button: 'left', clickCount: 1 });
          await send('Input.dispatchMouseEvent', { type: 'mouseReleased', x: target.x, y: target.y, button: 'left', clickCount: 1 });
        }
      });
      if (operation === 'click' && !this.dialogs.has(id)) await this.monitor(task, id, state, 'ring').catch(() => {});
      return {};
    }
    throw Error(`Unsupported browser operation: ${operation}`);
  }
  // Page.downloadWillBegin identifies the debugger's tab; DownloadItem does
  // not. Match its URL only while that tab has recent input from a live task.
  // No referrer-only guessing: identical URLs across tabs remain ambiguous.
  downloadWillBegin(id, event) {
    const state = this.tabs.get(id), task = this.claims.get(id), now = this.now();
    if (!state || !task || !this.tasks.has(task) || this.stopped.has(task)
        || !Number.isFinite(state.inputAt) || now - state.inputAt < 0 || now - state.inputAt > 1500
        || typeof event?.guid !== 'string' || typeof event.url !== 'string') return;
    this.downloadHints.set(event.guid, { task, url: event.url, at: now });
  }
  downloadStarted(item) {
    if (this.downloads.has(item.id)) return;
    const now = this.now();
    for (const [guid, hint] of this.downloadHints) if (now - hint.at > 1500) this.downloadHints.delete(guid);
    for (const [id, record] of this.unmatchedDownloads) if (now - record.at > 1500) this.unmatchedDownloads.delete(id);
    const active = task => this.tasks.has(task) && !this.stopped.has(task);
    const urls = new Set([item.url, item.finalUrl].filter(Boolean));
    const pending = [...urls].map(url => this.pendingDownloads.get(url)).filter(value => value && active(value.task));
    if (pending.length) {
      if (new Set(pending.map(value => value.task)).size === 1) this.downloads.set(item.id, { task: pending[0].task, item });
      return;
    }
    const hints = [...this.downloadHints.entries()].filter(([, hint]) => active(hint.task) && urls.has(hint.url));
    // Also refuse when two Chrome downloads could consume the same page event.
    if (!this.unmatchedDownloads.has(item.id)) this.unmatchedDownloads.set(item.id, { item, at: now });
    const candidates = [...this.unmatchedDownloads.values()].filter(record =>
      [record.item.url, record.item.finalUrl].some(url => urls.has(url)));
    if (hints.length !== 1 || candidates.length !== 1) return;
    const [guid, hint] = hints[0];
    this.downloads.set(item.id, { task: hint.task, item });
    this.downloadHints.delete(guid); this.unmatchedDownloads.delete(item.id);
  }
  async filenameFor(item) {
    // Chrome's onCreated and the debugger's event can arrive in either order.
    // onDeterminingFilename allows an asynchronous suggestion via return true.
    for (let attempt = 0; attempt <= 10; attempt++) {
      this.downloadStarted(item);
      const suggestion = this.determineFilename(item);
      if (suggestion || attempt === 10) return suggestion;
      await pause(25);
    }
  }
  determineFilename(item) {
    const record = this.downloads.get(item.id);
    if (!record) return;
    const name = String(item.filename || 'download').split(/[\\/]/).pop().replace(/[\x00-\x1f]/g, '_');
    return { filename: `HeyMate/${slugify(this.owner(record.task))}/${name || 'download'}`, conflictAction: 'uniquify' };
  }
  async download(task, value) {
    const url = webURL(value), deadline = this.now() + this.limits.download;
    this.pendingDownloads.set(url, { task });
    let id;
    try { id = await this.api.downloads.download({ url, conflictAction: 'uniquify' }); }
    finally { this.pendingDownloads.delete(url); }
    this.downloads.set(id, { task, item: { id, url } });
    do {
      this.assert(task);
      const item = (await this.api.downloads.search({ id }))[0];
      if (!item) throw Error('Download disappeared; completion is unknown.');
      this.downloads.get(id).item = item;
      if (item.state === 'interrupted') throw Error(`Chrome download failed: ${item.error || 'interrupted'}`);
      const out = { id, downloaded: item.state === 'complete', state: item.state, filename: item.filename, bytes: item.fileSize, url: item.finalUrl || item.url };
      if (out.downloaded) return out;
      if (item.danger && !['safe', 'accepted', 'allowlisted', 'deepScannedSafe'].includes(item.danger)) return { ...out, note: 'Chrome is holding this download. Only the user can review and allow it.' };
      if (this.now() >= deadline) return { ...out, note: 'Download still in progress. Completion is unverified.' };
      await pause(100);
    } while (true);
  }
}
