import assert from "node:assert/strict";
import test from "node:test";

import { ChromeCdpBridge } from "../../desktop/chrome-extension/cdp_bridge.js";

function eventSource() {
  const listeners = [];
  return {
    addListener(listener) {
      listeners.push(listener);
    },
    async emit(...args) {
      await Promise.all(listeners.map((listener) => listener(...args)));
    },
  };
}

function chromeFixture(options = {}) {
  const tabs = new Map([
    [1, { id: 1, windowId: 10, title: "Example", url: "https://example.com", incognito: false }],
    [2, { id: 2, windowId: 10, title: "Settings", url: "chrome://settings", incognito: false }],
    [3, { id: 3, windowId: 11, title: "Private", url: "https://private.test", incognito: true }],
  ]);
  const attached = new Set();
  const commands = [];

  const api = {
    debugger: {
      onEvent: eventSource(),
      onDetach: eventSource(),
      async attach(source) {
        if (options.attach) await options.attach(source);
        attached.add(source.tabId);
      },
      async detach(source) {
        attached.delete(source.tabId);
      },
      async sendCommand(source, method, params) {
        commands.push({ source, method, params });
        return { echoed: method };
      },
    },
    tabs: {
      onCreated: eventSource(),
      onUpdated: eventSource(),
      onRemoved: eventSource(),
      async query() {
        return [...tabs.values()];
      },
      async get(tabId) {
        if (options.get) await options.get(tabId);
        const tab = tabs.get(tabId);
        if (!tab) throw new Error("No tab");
        return tab;
      },
      async create({ url }) {
        const tab = { id: 4, windowId: 10, title: "", url, incognito: false };
        tabs.set(4, tab);
        return tab;
      },
      async update(tabId, changes) {
        return { ...tabs.get(tabId), ...changes };
      },
      async remove(tabId) {
        tabs.delete(tabId);
      },
    },
    windows: {
      async get(windowId) {
        return { id: windowId, left: 0, top: 0, width: 1200, height: 800, state: "normal" };
      },
      async update() {},
    },
  };

  return { api, tabs, attached, commands };
}

function deferred() {
  let resolve;
  const promise = new Promise((done) => {
    resolve = done;
  });
  return { promise, resolve };
}

function request(clientId, id, method, params = {}, sessionId) {
  return {
    type: "cdp",
    clientId,
    message: { id, method, params, ...(sessionId ? { sessionId } : {}) },
  };
}

function response(messages, id) {
  return messages.find((entry) => entry.type === "cdp" && entry.message.id === id)?.message;
}

test("exposes ordinary tabs without per-tab user approval", async () => {
  const fixture = chromeFixture();
  const messages = [];
  const bridge = new ChromeCdpBridge(fixture.api, (message) => messages.push(message));
  bridge.start();

  await bridge.handleEnvelope(request("client-a", 1, "Target.getTargets"));

  assert.deepEqual(response(messages, 1).result.targetInfos.map((target) => target.targetId), ["1"]);
  assert.equal(fixture.attached.size, 0, "listing tabs must not attach the debugger");

  await bridge.handleEnvelope(
    request("client-a", 2, "Target.attachToTarget", { targetId: "1", flatten: true }),
  );

  const sessionId = response(messages, 2).result.sessionId;
  assert.match(sessionId, /^hb:client-a:1$/);
  assert.deepEqual([...fixture.attached], [1]);

  await bridge.handleEnvelope(request("client-a", 3, "Page.enable", {}, sessionId));
  assert.equal(response(messages, 3).result.echoed, "Page.enable");
  assert.deepEqual(fixture.commands[0].source, { tabId: 1 });
});

test("automatically reports new eligible tabs and rejects restricted pages", async () => {
  const fixture = chromeFixture();
  const messages = [];
  const bridge = new ChromeCdpBridge(fixture.api, (message) => messages.push(message));
  bridge.start();

  await bridge.handleEnvelope(request("client-a", 1, "Target.setDiscoverTargets", { discover: true }));

  fixture.api.tabs.onCreated.emit({
    id: 5,
    windowId: 10,
    title: "New",
    url: "https://new.example",
    incognito: false,
  });
  fixture.api.tabs.onCreated.emit({
    id: 6,
    windowId: 10,
    title: "Extensions",
    url: "chrome://extensions",
    incognito: false,
  });

  const created = messages.filter((entry) => entry.message?.method === "Target.targetCreated");
  assert.equal(created.length, 1);
  assert.equal(created[0].message.params.targetInfo.targetId, "5");

  await bridge.handleEnvelope(
    request("client-a", 2, "Target.attachToTarget", { targetId: "2", flatten: true }),
  );
  assert.match(response(messages, 2).error.message, /outside Handbean's allowed scope/);
});

test("navigation into a restricted Chrome page revokes an attached tab", async () => {
  const fixture = chromeFixture();
  const messages = [];
  const bridge = new ChromeCdpBridge(fixture.api, (message) => messages.push(message));
  bridge.start();

  await bridge.handleEnvelope(
    request("client-a", 1, "Target.attachToTarget", { targetId: "1", flatten: true }),
  );
  assert.deepEqual([...fixture.attached], [1]);

  const restricted = { ...fixture.tabs.get(1), url: "chrome://settings" };
  fixture.tabs.set(1, restricted);
  await fixture.api.tabs.onUpdated.emit(1, { url: restricted.url }, restricted);

  assert.deepEqual([...fixture.attached], []);
  assert.equal(bridge.clients.get("client-a").sessions.size, 0);
  assert.ok(
    messages.some((entry) => entry.message?.method === "Target.detachedFromTarget"),
    "the CDP client must be told that its session was revoked",
  );
});

test("stop detaches every debugger target with one action", async () => {
  const fixture = chromeFixture();
  const messages = [];
  const bridge = new ChromeCdpBridge(fixture.api, (message) => messages.push(message));
  bridge.start();

  await bridge.handleEnvelope(
    request("client-a", 1, "Target.attachToTarget", { targetId: "1", flatten: true }),
  );
  assert.deepEqual([...fixture.attached], [1]);

  await bridge.handleEnvelope({ type: "stop" });
  assert.deepEqual([...fixture.attached], []);
  assert.equal(bridge.clients.size, 0);
});

test("stop also detaches an attachment that completes after Stop began", async () => {
  const attachStarted = deferred();
  const releaseAttach = deferred();
  const fixture = chromeFixture({
    attach: async () => {
      attachStarted.resolve();
      await releaseAttach.promise;
    },
  });
  const messages = [];
  const bridge = new ChromeCdpBridge(fixture.api, (message) => messages.push(message));
  bridge.start();

  const attaching = bridge.handleEnvelope(
    request("client-a", 1, "Target.attachToTarget", { targetId: "1", flatten: true }),
  );
  await attachStarted.promise;

  await bridge.handleEnvelope({ type: "stop" });
  releaseAttach.resolve();
  await attaching;

  assert.deepEqual([...fixture.attached], []);
  assert.equal(bridge.clients.size, 0);
  assert.equal(response(messages, 1), undefined, "a stale command must not reply after Stop");
});

test("disconnecting one CDP client preserves another client's shared tab", async () => {
  const fixture = chromeFixture();
  const bridge = new ChromeCdpBridge(fixture.api, () => {});
  bridge.start();

  await bridge.handleEnvelope(
    request("client-a", 1, "Target.attachToTarget", { targetId: "1", flatten: true }),
  );
  await bridge.handleEnvelope(
    request("client-b", 2, "Target.attachToTarget", { targetId: "1", flatten: true }),
  );

  await bridge.handleEnvelope({ type: "client_disconnected", clientId: "client-a" });
  assert.deepEqual([...fixture.attached], [1]);
  assert.equal(bridge.clients.has("client-a"), false);
  assert.equal(bridge.clients.has("client-b"), true);

  await bridge.handleEnvelope({ type: "client_disconnected", clientId: "client-b" });
  assert.deepEqual([...fixture.attached], []);
});

test("session-scoped Target commands cannot attach outside the top-level target gate", async () => {
  const fixture = chromeFixture();
  const messages = [];
  const bridge = new ChromeCdpBridge(fixture.api, (message) => messages.push(message));
  bridge.start();

  await bridge.handleEnvelope(
    request("client-a", 1, "Target.attachToTarget", { targetId: "1", flatten: true }),
  );
  const sessionId = response(messages, 1).result.sessionId;

  await bridge.handleEnvelope(
    request("client-a", 2, "Target.attachToTarget", { targetId: "2", flatten: true }, sessionId),
  );

  assert.match(response(messages, 2).error.message, /outside Handbean's allowed scope/);
  assert.equal(fixture.commands.length, 0);
});

test("nested debugger sessions are removed when Chrome reports detach", async () => {
  const fixture = chromeFixture();
  const messages = [];
  const bridge = new ChromeCdpBridge(fixture.api, (message) => messages.push(message));
  bridge.start();

  await bridge.handleEnvelope(
    request("client-a", 1, "Target.attachToTarget", { targetId: "1", flatten: true }),
  );

  await fixture.api.debugger.onEvent.emit(
    { tabId: 1 },
    "Target.attachedToTarget",
    { sessionId: "chrome-child", targetInfo: { type: "iframe" } },
  );
  const attachedEvent = messages.find(
    (entry) => entry.message?.method === "Target.attachedToTarget",
  );
  const childSessionId = attachedEvent.message.params.sessionId;

  await bridge.handleEnvelope(request("client-a", 2, "Page.enable", {}, childSessionId));
  assert.deepEqual(fixture.commands.at(-1).source, { tabId: 1, sessionId: "chrome-child" });

  await fixture.api.debugger.onEvent.emit(
    { tabId: 1 },
    "Target.detachedFromTarget",
    { sessionId: "chrome-child" },
  );
  await bridge.handleEnvelope(request("client-a", 3, "Page.enable", {}, childSessionId));

  assert.match(response(messages, 3).error.message, /Unknown or stale CDP session/);
});

test("Stop during target lookup prevents a later browser mutation", async () => {
  const lookupStarted = deferred();
  const releaseLookup = deferred();
  let pauseLookup = false;
  const fixture = chromeFixture({
    get: async () => {
      if (!pauseLookup) return;
      lookupStarted.resolve();
      await releaseLookup.promise;
    },
  });
  const messages = [];
  const bridge = new ChromeCdpBridge(fixture.api, (message) => messages.push(message));
  bridge.start();

  pauseLookup = true;
  const closing = bridge.handleEnvelope(request("client-a", 1, "Target.closeTarget", { targetId: "1" }));
  await lookupStarted.promise;
  await bridge.handleEnvelope({ type: "stop" });
  releaseLookup.resolve();
  await closing;

  assert.equal(fixture.tabs.has(1), true, "Stop must win before a not-yet-dispatched close");
  assert.equal(response(messages, 1), undefined);
});

test("restricted navigation invalidates an attachment still in progress", async () => {
  const attachStarted = deferred();
  const releaseAttach = deferred();
  const fixture = chromeFixture({
    attach: async () => {
      attachStarted.resolve();
      await releaseAttach.promise;
    },
  });
  const messages = [];
  const bridge = new ChromeCdpBridge(fixture.api, (message) => messages.push(message));
  bridge.start();

  const attaching = bridge.handleEnvelope(
    request("client-a", 1, "Target.attachToTarget", { targetId: "1", flatten: true }),
  );
  await attachStarted.promise;

  const restricted = { ...fixture.tabs.get(1), url: "chrome://settings" };
  fixture.tabs.set(1, restricted);
  await fixture.api.tabs.onUpdated.emit(1, { url: restricted.url }, restricted);
  releaseAttach.resolve();
  await attaching;

  assert.deepEqual([...fixture.attached], []);
  assert.equal(bridge.clients.get("client-a").sessions.size, 0);
  assert.match(response(messages, 1).error.message, /target changed|allowed scope/);
});

test("detaching a session invalidates its command paused in tab lookup", async () => {
  const lookupStarted = deferred();
  const releaseLookup = deferred();
  let pauseLookup = false;
  const fixture = chromeFixture({
    get: async () => {
      if (!pauseLookup) return;
      lookupStarted.resolve();
      await releaseLookup.promise;
    },
  });
  const messages = [];
  const bridge = new ChromeCdpBridge(fixture.api, (message) => messages.push(message));
  bridge.start();

  await bridge.handleEnvelope(
    request("client-a", 1, "Target.attachToTarget", { targetId: "1", flatten: true }),
  );
  const sessionId = response(messages, 1).result.sessionId;

  pauseLookup = true;
  const enabling = bridge.handleEnvelope(request("client-a", 2, "Page.enable", {}, sessionId));
  await lookupStarted.promise;
  await bridge.handleEnvelope(
    request("client-a", 3, "Target.detachFromTarget", { sessionId }),
  );
  releaseLookup.resolve();
  await enabling;

  assert.match(response(messages, 2).error.message, /Unknown or stale CDP session/);
  assert.equal(fixture.commands.length, 0);
});

test("Browser.close acknowledges without closing personal Chrome tabs", async () => {
  const fixture = chromeFixture();
  const messages = [];
  const bridge = new ChromeCdpBridge(fixture.api, (message) => messages.push(message));
  bridge.start();

  await bridge.handleEnvelope(request("client-a", 1, "Browser.close"));

  assert.deepEqual(response(messages, 1).result, {});
  assert.equal(fixture.tabs.size, 3);
});
