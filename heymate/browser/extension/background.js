// HeyMate's Chrome side. The app talks through the native host; mate-core.mjs does the work through Chrome's
// debugger: pages read as accessibility snapshots, clicks and keys sent as real input, tabs kept in a "HeyMate"
// group. This file only adapts HeyMate's requests to it and its results back. The model never sends JavaScript
// (the engine has no operation that runs JavaScript), and covering banners are never accepted for the user
// (no `dismiss`).

import { BrowserBridge, snapshotLines } from "./mate-core.mjs";

const HOST = "com.heymate.browser";
const OWNER = "heymate";
const GROUP_TITLE = "HeyMate";
const CURSOR = "#3380FF";
const RECONNECT_ALARM = "heymate-reconnect";

// Whose tabs are whose, saved for the browser session: Chrome stops this worker when the app's connection drops.
const bridge = new BrowserBridge(chrome, undefined, { store: {
  load: async () => (await chrome.storage.session.get("heymateTabs")).heymateTabs ?? null,
  save: (state) => chrome.storage.session.set({ heymateTabs: state }),
} });
const restored = bridge.restore().then(async () => {
  // Legacy builds had one global owner. Leave those pages open as user tabs;
  // never assign historical tabs to an arbitrary new mate.
  let changed = false;
  for (const [id, owner] of bridge.ownedTabs) if (owner === OWNER) {
    bridge.ownedTabs.delete(id); bridge.kept?.delete(id); changed = true;
  }
  if (changed) { bridge.homes?.delete(OWNER); await bridge.persist?.(); }
});
bridge.cursor = true;

// Native capabilities bind lanes to mate/chat owners and turns. Each owner is
// ordered; different owners progress independently through the same profile.
const workers = new Map(), lanes = new Map(), cancelled = new Set(), latestScopes = new Map();
let port = null;
let barrier = Promise.resolve();

function connect() {
  if (port) return;
  try {
    port = chrome.runtime.connectNative(HOST);
  } catch (error) {
    port = null;
    return;
  }
  const connection = port;
  connection.onMessage.addListener(message => onMessage(message, connection));
  connection.onDisconnect.addListener(() => {
    // The helper exits whenever HeyMate quits or restarts; the alarm reconnects. Reading lastError marks it handled.
    void chrome.runtime.lastError;
    if (port !== connection) return;
    port = null;
    // Stop in-flight work now; queue the new identity after cleanup. A stopped
    // engine task can never be reused after the native host reconnects.
    const stopped = bridge.stop("the connection to the HeyMate app dropped").catch(error => console.warn("HeyMate browser cleanup failed", error));
    barrier = stopped;
    workers.clear(); lanes.clear(); cancelled.clear(); latestScopes.clear();
  });
  port.postMessage({ type: "hello", protocol: 4, version: chrome.runtime.getManifest().version });
}

async function onMessage(message, connection) {
  if (!message || port !== connection || !["command", "cancel"].includes(message.type)) return;
  const owner = message.owner ?? OWNER, scope = message.scope ?? "legacy";
  if (typeof owner !== "string" || !owner || owner.length > 200 || typeof scope !== "string" || !scope || scope.length > 100) return;
  const key = JSON.stringify([owner, scope]);
  if (message.type === "cancel") {
    cancelled.add(key);
    const worker = workers.get(owner);
    if (worker?.scope === scope) await bridge.end(worker.task, false, "native turn cancelled");
    return;
  }
  const id = message.id;
  const lane = (lanes.get(owner) ?? barrier).catch(() => {}).then(async () => {
    if (port !== connection) return;
    try {
      await restored;
      if (port !== connection) return;
      if (cancelled.has(key)) throw Error("Browser turn cancelled; queued action was not run.");
      const previousScope = latestScopes.get(owner);
      if (previousScope && previousScope !== scope) cancelled.add(JSON.stringify([owner, previousScope]));
      latestScopes.set(owner, scope);
      let worker = workers.get(owner);
      if (worker && worker.scope !== scope) {
        await bridge.end(worker.task, true, "native turn ended");
        // Cleanup yields to cancellation and native-host reconnects.
        if (port !== connection) return;
        workers.delete(owner); worker = null;
        if (cancelled.has(key)) throw Error("Browser turn cancelled; queued action was not run.");
      }
      if (!worker) { worker = { scope, task: crypto.randomUUID() }; workers.set(owner, worker); }
      const result = await run(message, owner, worker);
      if (port === connection) connection.postMessage({ type: "result", id, ok: true, result });
    } catch (error) {
      if (port === connection) connection.postMessage({ type: "result", id, ok: false, error: String(error && error.message ? error.message : error) });
    }
  });
  lanes.set(owner, lane);
  try { await lane; } finally { if (lanes.get(owner) === lane) lanes.delete(owner); }
}

const engineRef = (ref) => (typeof ref === "string" && /^e\d+$/.test(ref) ? ref : `e${Number(ref)}`);
const EDITABLE = new Set(["textbox", "searchbox", "combobox", "textarea", "spinbutton", "listbox"]);

// The engine's snapshot in the shape HeyMate's approvals read: numbered elements (role, name, editable) and the rest
// of the page as text.
function page(snapshot, extra = {}) {
  if (!snapshot || !Array.isArray(snapshot.nodes)) return extra;
  const elements = [], text = [];
  const lines = snapshotLines(snapshot);
  snapshot.nodes.forEach((node, index) => {
    const ref = typeof node.ref === "string" ? Number(node.ref.slice(1)) : NaN;
    if (Number.isInteger(ref)) {
      elements.push({ ref, role: node.role, name: String(node.name ?? "").replace(/\s+/g, " ").trim().slice(0, 120),
        editable: EDITABLE.has(String(node.role).toLowerCase()) || node.editable === true || node.editable === "true" });
    } else {
      text.push(lines[index]);
    }
  });
  return { ...extra, tabId: snapshot.tabId ?? extra.tabId, title: snapshot.title ?? "", url: snapshot.url ?? extra.url ?? "", text: text.join("\n").slice(0, 12000), elements };
}

// An action answers with the settled page (the engine's one-step batch).
function settled(out, extra) {
  // Single-step batches can return an error alongside a perfectly good page.
  // A snapshot proves observation, not that the preceding action succeeded.
  if (out?.error) throw new Error(out.error);
  const failed = out?.steps?.find(step => step?.error);
  if (failed) throw new Error(failed.error);
  const tabId = out?.tabId ?? out?.snapshot?.tabId ?? extra.tabId;
  extra = { ...extra, ...(tabId == null ? {} : { tabId }) };
  if (out && out.snapshot) return page(out.snapshot, extra);
  if (out && out.snapshotError) return { ...extra, note: `Done; the page could not be read afterwards (${out.snapshotError}).` };
  return extra;
}

async function run(message, owner, worker) {
  const task = worker.task;
  const request = (operation, fields = {}) => bridge.execute({ task, owner,
    groupTitle: message.groupTitle || GROUP_TITLE, cursorColor: CURSOR, operation, ...fields });
  switch (message.op) {
    case "tabs": {
      const out = await request("tabs");
      const owned = (tabId) => bridge.ownedTabs.get(tabId) === owner;
      return { tabs: out.tabs.slice(0, 60).map((tab) => ({ id: tab.id, title: tab.title || "", url: tab.url, owned: owned(tab.id), active: tab.current === true })) };
    }
    case "open": {
      const out = await request("open", { url: message.url });
      return settled(out, { tabId: out.tabId, url: message.url });
    }
    case "navigate": {
      const out = await request("open", { url: message.url, tabId: message.tabId });
      return settled(out, { tabId: message.tabId, url: message.url });
    }
    case "read":
    case "snapshot":
      return page({ ...(await request("snapshot", { tabId: message.tabId })), tabId: message.tabId });
    case "extract":
      return { tabId: message.tabId, ...(await request("extract", { tabId: message.tabId })) };
    case "click":
      return settled(await request("click", { tabId: message.tabId, ref: engineRef(message.ref) }), { tabId: message.tabId, clicked: Number(message.ref) });
    case "type": {
      const steps = [{ operation: "fill", ref: engineRef(message.ref), text: String(message.text ?? "") }];
      if (message.submit) steps.push({ operation: "press", key: "Enter" });
      const out = await request("batch", { tabId: message.tabId, steps });
      const failed = (out.steps || []).find((step) => step && step.error);
      if (failed) throw new Error(failed.error);
      return settled(out, { tabId: message.tabId, typed: Number(message.ref) });
    }
    case "press":
      return settled(await request("press", { tabId: message.tabId, key: message.key }), { tabId: message.tabId, pressed: message.key });
    case "scroll":
      return settled(await request("scroll", { tabId: message.tabId, direction: message.direction === "up" ? "up" : "down" }), { tabId: message.tabId, scrolled: true });
    case "back":
      return settled(await request("back", { tabId: message.tabId }), { tabId: message.tabId, back: true });
    case "wait_for":
      return settled(await request("wait_for", { tabId: message.tabId, text: message.text, url: message.url, timeout: message.timeout }), { tabId: message.tabId, waited: true });
    case "keep":
      return request("keep", { tabId: message.tabId, why: message.why });
    case "upload": {
      if (!message.expectedURL || (await chrome.tabs.get(message.tabId)).url !== message.expectedURL) throw new Error("Upload destination changed. Read the page and approve again.");
      return settled(await request("upload", { tabId: message.tabId, ref: engineRef(message.ref), paths: message.paths }), { tabId: message.tabId, uploaded: message.paths.map(p => p.split('/').pop()) });
    }
    case "download":
      return request("download", { url: message.url });
    case "dialog":
      return settled(await request("dialog", { tabId: message.tabId, accept: message.accept, text: message.text }), { tabId: message.tabId, dialogAnswered: true });
    case "show": {
      // Showing a window is an action too: never bypass another worker's claim.
      await request("tabs");
      await bridge.claim(task, message.tabId);
      const tab = await chrome.tabs.get(message.tabId);
      await chrome.tabs.update(tab.id, { active: true });
      await chrome.windows.update(tab.windowId, { focused: true });
      return { shown: tab.id };
    }
    case "close": {
      await request("close", { tabId: message.tabId });
      return { closed: message.tabId };
    }
    case "end": {
      const out = await request("end", { tidy: true });
      if (workers.get(owner) === worker) workers.delete(owner);
      return { closed: out.closed ?? [] };
    }
    default:
      throw new Error("unknown request");
  }
}

// The engine's view of each page expires with navigation; dialogs and file pickers are its to handle.
const mainFrames = new Map();
chrome.debugger.onEvent.addListener((source, method, params) => {
  if (method === "Page.frameNavigated" && !params?.frame?.parentId) { mainFrames.set(source.tabId, params?.frame?.id); bridge.invalidate(source.tabId); }
  if (method === "Page.navigatedWithinDocument" && [undefined, params?.frameId].includes(mainFrames.get(source.tabId))) bridge.invalidate(source.tabId);
  if (method === "Page.javascriptDialogOpening") bridge.dialogOpened(source.tabId, params);
  if (method === "Page.javascriptDialogClosed") bridge.dialogClosed(source.tabId);
  if (method === "Page.downloadWillBegin") bridge.downloadWillBegin(source.tabId, params);
  if (method === "Page.fileChooserOpened") bridge.fileChooserOpened(source.tabId, params);
  if (method.startsWith("Network.")) bridge.network(source.tabId, method, params);
});
chrome.debugger.onDetach.addListener((source, reason) => { mainFrames.delete(source.tabId); bridge.detached(source.tabId, reason); });
chrome.tabs.onUpdated.addListener((tabId, change) => { if (change.url || change.status === "loading") bridge.invalidate(tabId); });
chrome.tabs.onRemoved.addListener((tabId) => bridge.removed(tabId));
chrome.downloads?.onCreated.addListener(item => bridge.downloadStarted(item));
chrome.downloads?.onDeterminingFilename.addListener((item, suggest) => {
  const finish = name => {
    if (name) suggest({ ...name, filename: name.filename.replace(/^ReferenceRenderer\//, "HeyMate/") }); else suggest();
  };
  bridge.filenameFor(item).then(finish, () => suggest());
  return true;
});

chrome.runtime.onInstalled.addListener(connect);
chrome.runtime.onStartup.addListener(connect);
// The app may start after Chrome; try again every minute while disconnected.
chrome.alarms.create(RECONNECT_ALARM, { periodInMinutes: 1 });
chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === RECONNECT_ALARM) connect();
});
connect();
