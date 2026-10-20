import { ChromeCdpBridge } from "./cdp_bridge.js";

const STORAGE_KEY = "handbeanRelayUrl";
const EXTENSION_VERSION = chrome.runtime.getManifest().version;
const RECONNECT_MIN_MS = 1_000;
const RECONNECT_MAX_MS = 15_000;
const RECONNECT_ALARM = "handbean-relay-reconnect";

let socket = null;
let reconnectTimer = null;
let reconnectDelay = RECONNECT_MIN_MS;
let relayUrl = null;

const bridge = new ChromeCdpBridge(chrome, (message) => {
  if (socket?.readyState === WebSocket.OPEN) socket.send(JSON.stringify(message));
});
bridge.start();

chrome.runtime.onInstalled.addListener(() => {
  ensureReconnectAlarm();
  loadAndConnect();
});
chrome.runtime.onStartup.addListener(() => loadAndConnect());
chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === RECONNECT_ALARM && socket?.readyState !== WebSocket.OPEN) loadAndConnect();
});

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.type === "configure") {
    configure(message.url)
      .then(() => sendResponse({ ok: true }))
      .catch((error) => sendResponse({ ok: false, error: error.message }));
    return true;
  }

  if (message?.type === "disconnect") {
    disconnect(true)
      .then(() => sendResponse({ ok: true }))
      .catch((error) => sendResponse({ ok: false, error: error.message }));
    return true;
  }

  if (message?.type === "status") {
    sendResponse({
      configured: typeof relayUrl === "string",
      connected: socket?.readyState === WebSocket.OPEN,
    });
  }

  return false;
});

async function loadAndConnect() {
  const stored = await chrome.storage.local.get(STORAGE_KEY);
  relayUrl = normalizeRelayUrl(stored[STORAGE_KEY]);
  if (relayUrl) connect();
}

async function configure(url) {
  const normalized = normalizeRelayUrl(url);
  if (!normalized) throw new Error("Paste a valid Handbean pairing URL");

  relayUrl = normalized;
  await chrome.storage.local.set({ [STORAGE_KEY]: relayUrl });
  clearReconnect();
  disconnectSocket();
  await bridge.stop();
  connect();
}

async function disconnect(forget) {
  clearReconnect();
  disconnectSocket();
  await bridge.stop();

  if (forget) {
    relayUrl = null;
    await chrome.storage.local.remove(STORAGE_KEY);
  }
}

function connect() {
  if (!relayUrl || socket?.readyState === WebSocket.OPEN || socket?.readyState === WebSocket.CONNECTING) {
    return;
  }

  clearReconnect();
  const next = new WebSocket(relayUrl);
  socket = next;

  next.addEventListener("open", async () => {
    if (socket !== next) return;
    reconnectDelay = RECONNECT_MIN_MS;
    await bridge.hello(EXTENSION_VERSION);
  });

  next.addEventListener("message", async (event) => {
    if (socket !== next || typeof event.data !== "string") return;

    try {
      const envelope = JSON.parse(event.data);

      if (envelope?.type === "ping") {
        next.send(JSON.stringify({ type: "pong" }));
      } else {
        await bridge.handleEnvelope(envelope);
      }
    } catch (_error) {
      // Malformed relay messages are ignored; the relay remains usable.
    }
  });

  next.addEventListener("close", async () => {
    if (socket !== next) return;
    socket = null;
    await bridge.stop();
    scheduleReconnect();
  });

  next.addEventListener("error", () => {
    if (socket === next) next.close();
  });
}

function disconnectSocket() {
  if (socket) {
    const current = socket;
    socket = null;
    current.close(1000, "Disconnected");
  }
}

function scheduleReconnect() {
  if (!relayUrl || reconnectTimer) return;

  reconnectTimer = setTimeout(() => {
    reconnectTimer = null;
    connect();
  }, reconnectDelay);

  reconnectDelay = Math.min(RECONNECT_MAX_MS, reconnectDelay * 2);
}

function clearReconnect() {
  if (reconnectTimer) clearTimeout(reconnectTimer);
  reconnectTimer = null;
}

function ensureReconnectAlarm() {
  chrome.alarms.create(RECONNECT_ALARM, { periodInMinutes: 0.5 });
}

function normalizeRelayUrl(value) {
  if (typeof value !== "string") return null;

  try {
    const url = new URL(value.trim());
    if (url.protocol !== "ws:" || url.hostname !== "127.0.0.1") return null;
    if (!/^\/extension\/[A-Za-z0-9_-]{32,}$/.test(url.pathname)) return null;
    if (url.username || url.password || url.search || url.hash) return null;
    return url.toString();
  } catch (_error) {
    return null;
  }
}

ensureReconnectAlarm();
loadAndConnect();
