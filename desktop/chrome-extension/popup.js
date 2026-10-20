const status = document.querySelector("#status");
const relayUrl = document.querySelector("#relay-url");
const connect = document.querySelector("#connect");
const disconnect = document.querySelector("#disconnect");

connect.addEventListener("click", async () => {
  setBusy(true);
  const reply = await chrome.runtime.sendMessage({ type: "configure", url: relayUrl.value });
  setBusy(false);

  if (reply?.ok) {
    setStatus("Connecting to Handbean…", "loading");
    window.setTimeout(refresh, 300);
  } else {
    setStatus(reply?.error || "Could not save pairing URL", "error");
  }
});

disconnect.addEventListener("click", async () => {
  setBusy(true);
  await chrome.runtime.sendMessage({ type: "disconnect" });
  relayUrl.value = "";
  setBusy(false);
  setStatus("Not paired", "idle");
});

async function refresh() {
  try {
    const stored = await chrome.storage.local.get("handbeanRelayUrl");
    relayUrl.value = stored.handbeanRelayUrl || "";

    const reply = await chrome.runtime.sendMessage({ type: "status" });
    disconnect.disabled = !reply?.configured;

    if (reply?.connected) {
      setStatus("Connected", "connected");
    } else if (reply?.configured) {
      setStatus("Waiting for Handbean…", "loading");
    } else {
      setStatus("Not paired", "idle");
    }
  } catch (_error) {
    setStatus("Extension worker unavailable", "error");
  }
}

function setBusy(busy) {
  connect.disabled = busy;
  disconnect.disabled = busy;
}

function setStatus(text, state) {
  status.textContent = text;
  status.dataset.state = state;
}

refresh();
