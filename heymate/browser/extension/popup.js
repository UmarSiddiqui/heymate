const connection = document.querySelector("#connection");
const nextStep = document.querySelector("#next-step");
const download = document.querySelector("#download");

function showConnection(connected) {
  connection.dataset.connected = String(connected);
  connection.textContent = connected ? "Connected to HeyMate for Mac" : "Mac app disconnected";
  nextStep.textContent = connected
    ? "Ask a mate in the Mac app to work in Chrome."
    : "Open HeyMate for Mac. Check Settings → Permissions → Chrome if it stays disconnected.";
  download.hidden = connected;
}

const status = chrome.runtime.connect({ name: "heymate-connection-status" });
status.onMessage.addListener(message => showConnection(message.connected === true));
status.onDisconnect.addListener(() => {
  void chrome.runtime.lastError;
  showConnection(false);
});
