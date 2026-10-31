(() => {
  const statusEl = document.getElementById('status');
  const openTabBtn = document.getElementById('openTab');
  const snapshotBtn = document.getElementById('snapshot');

  // Connect to native messaging host
  let port = null;

  function connect() {
    try {
      port = chrome.runtime.connectNative('com.heymate.browser');
      port.onMessage.addListener((msg) => {
        if (msg.type === 'ready') {
          statusEl.textContent = 'Connected';
          statusEl.className = 'status connected';
        } else if (msg.type === 'error') {
          statusEl.textContent = msg.error || 'Error';
          statusEl.className = 'status disconnected';
        }
      });
      port.onDisconnect.addListener(() => {
        port = null;
        statusEl.textContent = 'Disconnected';
        statusEl.className = 'status disconnected';
      });
    } catch (e) {
      statusEl.textContent = 'Extension not installed';
      statusEl.className = 'status disconnected';
    }
  }

  connect();

  openTabBtn.addEventListener('click', () => {
    if (!port) return;
    port.postMessage({
      type: 'command',
      id: Date.now().toString(),
      action: 'open',
      url: 'https://example.com'
    });
    chrome.tabs.create({ url: 'https://example.com' });
  });

  snapshotBtn.addEventListener('click', () => {
    chrome.tabs.query({ active: true, currentWindow: true }, (tabs) => {
      if (tabs[0] && port) {
        port.postMessage({
          type: 'command',
          id: Date.now().toString(),
          action: 'snapshot',
          tabId: tabs[0].id
        });
      }
    });
  });
})();
