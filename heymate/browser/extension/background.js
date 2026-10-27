// HeyMate's Chrome side. The app talks through the native host; this worker
// opens pages in one "HeyMate" tab group, reads them, and clicks or types
// only inside that group. It never runs code the model wrote: every page
// function below is fixed here.

const HOST = "com.heymate.browser";
const GROUP = "HeyMate";
const RECONNECT_ALARM = "heymate-reconnect";

let port = null;

function connect() {
  if (port) return;
  try {
    port = chrome.runtime.connectNative(HOST);
  } catch (error) {
    port = null;
    return;
  }
  port.onMessage.addListener(onMessage);
  port.onDisconnect.addListener(() => {
    port = null;
  });
  port.postMessage({ type: "hello", protocol: 2, version: chrome.runtime.getManifest().version });
}

async function onMessage(message) {
  if (!message || message.type !== "command") return;
  const id = message.id;
  try {
    const result = await run(message);
    port?.postMessage({ type: "result", id, ok: true, result });
  } catch (error) {
    port?.postMessage({ type: "result", id, ok: false, error: String(error && error.message ? error.message : error) });
  }
}

function httpURL(value) {
  const parsed = new URL(value);
  if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
    throw new Error("only http and https pages");
  }
  if (parsed.username || parsed.password) {
    throw new Error("pages with a username or password in the address are refused");
  }
  return parsed.href;
}

async function heymateGroupId() {
  const groups = await chrome.tabGroups.query({ title: GROUP });
  return groups.length ? groups[0].id : null;
}

async function placeInGroup(tabId) {
  const groupId = await heymateGroupId();
  if (groupId !== null) {
    await chrome.tabs.group({ tabIds: [tabId], groupId });
    return;
  }
  const created = await chrome.tabs.group({ tabIds: [tabId] });
  await chrome.tabGroups.update(created, { title: GROUP, color: "grey" });
}

// HeyMate may act only in tabs inside its own group; the user's other tabs
// can be listed and read, never clicked or typed into.
async function ownedTab(tabId) {
  if (typeof tabId !== "number") throw new Error("missing tab");
  const tab = await chrome.tabs.get(tabId);
  const groupId = await heymateGroupId();
  if (groupId === null || tab.groupId !== groupId) {
    throw new Error("HeyMate can only act in tabs in its own group. Open the page with open first.");
  }
  return tab;
}

async function waitForLoad(tabId, timeoutMs = 15000) {
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    const tab = await chrome.tabs.get(tabId);
    if (tab.status === "complete") return;
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
}

async function inPage(tabId, func, args = []) {
  const [injected] = await chrome.scripting.executeScript({ target: { tabId }, func, args });
  return injected ? injected.result : null;
}

// --- Page functions (run inside the page; must be self-contained) ---------

function pageSnapshot() {
  const selector = "a[href], button, input, select, textarea, [role=button], [role=link], [role=tab], [role=menuitem], [role=checkbox], [contenteditable=true], summary";
  const visible = (el) => {
    const rect = el.getBoundingClientRect();
    if (rect.width < 2 || rect.height < 2) return false;
    const style = getComputedStyle(el);
    return style.visibility !== "hidden" && style.display !== "none" && style.opacity !== "0";
  };
  const nameOf = (el) => {
    const label = el.getAttribute("aria-label") || el.getAttribute("title") || el.getAttribute("placeholder")
      || (el.labels && el.labels[0] && el.labels[0].innerText) || el.innerText || el.value || el.getAttribute("name") || "";
    return label.replace(/\s+/g, " ").trim().slice(0, 80);
  };
  document.querySelectorAll("[data-heymate-ref]").forEach((el) => el.removeAttribute("data-heymate-ref"));
  const elements = [];
  for (const el of document.querySelectorAll(selector)) {
    if (elements.length >= 150) break;
    if (!visible(el) || el.disabled) continue;
    const ref = elements.length + 1;
    el.setAttribute("data-heymate-ref", String(ref));
    const tag = el.tagName.toLowerCase();
    const type = (el.getAttribute("type") || "").toLowerCase();
    const role = el.getAttribute("role") || (tag === "a" ? "link" : tag === "input" ? (type || "text") : tag);
    elements.push({
      ref,
      role,
      name: nameOf(el),
      secret: type === "password" || /cc-|one-time-code/.test(el.getAttribute("autocomplete") || ""),
      editable: tag === "textarea" || tag === "select" || el.isContentEditable
        || (tag === "input" && !["button", "submit", "reset", "checkbox", "radio", "file", "image"].includes(type)),
    });
  }
  const text = (document.body && document.body.innerText ? document.body.innerText : "").replace(/\n{3,}/g, "\n\n");
  return { title: document.title, url: location.href, text: text.slice(0, 6000), elements };
}

function pageClick(ref) {
  const el = document.querySelector(`[data-heymate-ref="${ref}"]`);
  if (!el) return { error: "That element is gone. Take a new snapshot." };
  el.scrollIntoView({ block: "center", inline: "center" });
  el.focus({ preventScroll: true });
  el.click();
  return { clicked: ref };
}

function pageType(ref, text, submit) {
  const el = document.querySelector(`[data-heymate-ref="${ref}"]`);
  if (!el) return { error: "That element is gone. Take a new snapshot." };
  const type = (el.getAttribute("type") || "").toLowerCase();
  if (type === "password" || /cc-|one-time-code/.test(el.getAttribute("autocomplete") || "")) {
    return { error: "HeyMate never types into password, card or code fields. Ask the user to do it." };
  }
  el.scrollIntoView({ block: "center" });
  el.focus();
  if (el.isContentEditable) {
    document.execCommand("selectAll", false);
    document.execCommand("insertText", false, text);
  } else if (el.tagName === "SELECT") {
    const option = [...el.options].find((o) => o.text.trim() === text || o.value === text);
    if (!option) return { error: "No option named that." };
    el.value = option.value;
  } else {
    const proto = el.tagName === "TEXTAREA" ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
    const setter = Object.getOwnPropertyDescriptor(proto, "value").set;
    setter.call(el, text);
  }
  el.dispatchEvent(new Event("input", { bubbles: true }));
  el.dispatchEvent(new Event("change", { bubbles: true }));
  if (submit) {
    el.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", code: "Enter", keyCode: 13, bubbles: true }));
    if (el.form) el.form.requestSubmit ? el.form.requestSubmit() : el.form.submit();
  }
  return { typed: ref };
}

function pageScroll(direction) {
  const amount = Math.round(window.innerHeight * 0.8);
  window.scrollBy({ top: direction === "up" ? -amount : amount });
  return { scrolledTo: Math.round(window.scrollY) };
}

// --- Commands ---------------------------------------------------------------

async function run(message) {
  switch (message.op) {
    case "tabs": {
      const groupId = await heymateGroupId();
      const tabs = await chrome.tabs.query({ windowType: "normal" });
      return {
        tabs: tabs
          .filter((tab) => tab.url && /^https?:/i.test(tab.url))
          .slice(0, 40)
          .map((tab) => ({
            id: tab.id,
            title: tab.title || "",
            url: tab.url,
            owned: groupId !== null && tab.groupId === groupId,
            active: Boolean(tab.active),
          })),
      };
    }
    case "open": {
      const url = httpURL(message.url);
      const tab = await chrome.tabs.create({ url, active: false });
      await placeInGroup(tab.id);
      await waitForLoad(tab.id);
      return { tabId: tab.id, url };
    }
    case "navigate": {
      await ownedTab(message.tabId);
      const url = httpURL(message.url);
      await chrome.tabs.update(message.tabId, { url });
      await waitForLoad(message.tabId);
      return { tabId: message.tabId, url };
    }
    case "read":
    case "snapshot": {
      if (typeof message.tabId !== "number") throw new Error("missing tab");
      await waitForLoad(message.tabId, 5000);
      return { tabId: message.tabId, ...(await inPage(message.tabId, pageSnapshot)) };
    }
    case "click": {
      await ownedTab(message.tabId);
      const result = await inPage(message.tabId, pageClick, [message.ref]);
      if (result && result.error) throw new Error(result.error);
      await new Promise((resolve) => setTimeout(resolve, 600));
      await waitForLoad(message.tabId, 8000);
      return { tabId: message.tabId, ...result };
    }
    case "type": {
      await ownedTab(message.tabId);
      const result = await inPage(message.tabId, pageType, [message.ref, String(message.text ?? ""), Boolean(message.submit)]);
      if (result && result.error) throw new Error(result.error);
      if (message.submit) await waitForLoad(message.tabId, 8000);
      return { tabId: message.tabId, ...result };
    }
    case "scroll": {
      await ownedTab(message.tabId);
      return { tabId: message.tabId, ...(await inPage(message.tabId, pageScroll, [message.direction === "up" ? "up" : "down"])) };
    }
    case "show": {
      const tab = await ownedTab(message.tabId);
      await chrome.tabs.update(tab.id, { active: true });
      await chrome.windows.update(tab.windowId, { focused: true });
      return { shown: tab.id };
    }
    case "close": {
      await ownedTab(message.tabId);
      await chrome.tabs.remove(message.tabId);
      return { closed: message.tabId };
    }
    case "end": {
      const groupId = await heymateGroupId();
      const tabs = groupId === null ? [] : await chrome.tabs.query({ groupId });
      const ids = tabs.map((tab) => tab.id);
      if (ids.length) await chrome.tabs.remove(ids);
      return { closed: ids };
    }
    default:
      throw new Error("unknown request");
  }
}

chrome.runtime.onInstalled.addListener(connect);
chrome.runtime.onStartup.addListener(connect);
// The app may start after Chrome; try again every minute while disconnected.
chrome.alarms.create(RECONNECT_ALARM, { periodInMinutes: 1 });
chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === RECONNECT_ALARM) connect();
});
connect();
