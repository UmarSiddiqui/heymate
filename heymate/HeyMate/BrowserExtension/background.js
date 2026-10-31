/*
 * HeyMate Chrome Extension Background Script
 * Connects to the native messaging host (com.heymate.browser) which forwards
 * commands to the local Unix domain socket server (BrowserSocketServer).
 *
 * Protocol:
 *   Extension -> Native Host: {"message": {"type": "command", "id": "...", ...}}
 *   Native Host -> Extension:  {"message": {"type": "result", "id": "...", ...}}
 *   Extension -> Native Host:  {"message": {"type": "hello", "version": "1.0.0"}}
 *   Native Host -> Extension:  {"message": {"type": "ready", "selected": true}}
 */

const HOST_NAME = 'com.heymate.browser';

let port = null;
let pending = new Map(); // id -> { resolve, reject }

function connect() {
  try {
    port = chrome.runtime.connectNative(HOST_NAME);
    port.onMessage.addListener(handleMessage);
    port.onDisconnect.addListener(() => {
      port = null;
    });
    send({ type: 'hello', version: '1.0.0' });
  } catch (e) {
    console.error('Failed to connect to native host:', e);
  }
}

function handleMessage(message) {
  if (!message || message.type !== 'message') return;
  const body = message.body || {};
  const id = body.id;
  if (id && pending.has(id)) {
    const { resolve } = pending.get(id);
    pending.delete(id);
    resolve(body);
  }
}

function send(message) {
  return new Promise((resolve, reject) => {
    if (!port) {
      resolve({ error: 'Not connected to native host' });
      return;
    }
    const id = Date.now().toString() + Math.random().toString(36).slice(2);
    pending.set(id, resolve);
    port.postMessage({ type: 'command', id, ...message });
  }
}

async function executeCommand(command) {
  try {
    const result = await send(command);
    return result;
  } catch (e) {
    return { error: e.message };
  }
}

// Listen for commands from the native messaging host
chrome.runtime.onMessage.addListener((request, sender, sendResponse) => {
  if (request.type === 'executeCommand') {
    executeCommand(request.command).then((result) => {
      sendResponse(result);
    });
    return true; // keep channel open for async response
  }
  return false;
});

connect();

// Expose executeCommand for testing/debugging
window.executeCommand = executeCommand;
