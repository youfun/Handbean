import assert from "node:assert/strict";
import test from "node:test";
import vm from "node:vm";
import { readFile } from "node:fs/promises";

const source = await readFile(new URL("../../priv/web_push/sw.js", import.meta.url), "utf8");

function worker(windows = [], options = {}) {
  const listeners = new Map();
  const shown = [];
  const opened = [];
  const cacheAdds = [];
  const cacheDeletes = [];
  const fetches = [];
  const offlineResponse = {source: "offline"};
  const networkResponse = {source: "network"};
  const cached = new Map();
  let claimed = false;
  let skipped = false;
  const caches = {
    async open(name) {
      return {async add(url) { cacheAdds.push({name, url}); cached.set(url, offlineResponse); }};
    },
    async keys() { return options.cacheNames || []; },
    async delete(name) { cacheDeletes.push(name); return true; },
    async match(url) { return cached.get(url); }
  };
  const fetch = async (request, config) => {
    fetches.push({request, config});
    if (options.offline) throw new Error("offline");
    return networkResponse;
  };
  const self = {
    location: {origin: "https://handbean.example"},
    addEventListener(name, callback) { listeners.set(name, callback); },
    async skipWaiting() { skipped = true; },
    registration: {async showNotification(title, values) { shown.push({title, ...values}); }},
    clients: {
      async claim() { claimed = true; },
      async matchAll() { return windows; },
      async openWindow(url) { opened.push(url); }
    }
  };
  vm.runInNewContext(source, {self, URL, caches, fetch, Response: {error() { return {source: "error"}; }}});
  async function dispatch(name, values = {}) {
    let work;
    listeners.get(name)({...values, waitUntil(promise) { work = promise; }});
    await work;
  }
  async function navigate(request) {
    let response;
    listeners.get("fetch")({request, respondWith(promise) { response = promise; }});
    return response && await response;
  }
  async function click(url) {
    let closed = false;
    await dispatch("notificationclick", {notification: {data: {url}, close() { closed = true; }}});
    assert.equal(closed, true);
  }
  return {
    listeners, shown, opened, cacheAdds, cacheDeletes, fetches, dispatch, navigate, click,
    get claimed() { return claimed; }, get skipped() { return skipped; }
  };
}

function windowClient(url) {
  return {
    url,
    visibilityState: "visible",
    focused: true,
    focusCount: 0,
    navigations: [],
    async focus() { this.focusCount++; return this; },
    async navigate(value) { this.navigations.push(value); this.url = value; return this; }
  };
}

test("worker activates updates, caches only the generic offline page, and claims clients", async () => {
  const sw = worker([], {cacheNames: ["handbean-offline-old", "unrelated-cache"]});
  await sw.dispatch("install");
  await sw.dispatch("activate");
  assert.equal(sw.skipped, true);
  assert.equal(sw.claimed, true);
  assert.equal(sw.listeners.has("fetch"), true);
  assert.equal(sw.listeners.has("pushsubscriptionchange"), false);
  assert.deepEqual(sw.cacheAdds.map(({url}) => url), ["/offline.html"]);
  assert.deepEqual(sw.cacheDeletes, ["handbean-offline-old"]);
});

test("navigation uses the network and falls back offline without intercepting API or asset requests", async () => {
  const online = worker();
  await online.dispatch("install");
  const request = {method: "GET", mode: "navigate", url: "https://handbean.example/c/one"};
  assert.deepEqual(await online.navigate(request), {source: "network"});
  assert.equal(online.fetches.length, 1);
  assert.equal(online.fetches[0].request, request);
  assert.equal(online.fetches[0].config.cache, "no-store");

  const offline = worker([], {offline: true});
  await offline.dispatch("install");
  assert.deepEqual(await offline.navigate(request), {source: "offline"});
  for (const ignored of [
    {method: "POST", mode: "navigate", url: "https://handbean.example/api/web-push/subscription"},
    {method: "GET", mode: "cors", url: "https://handbean.example/assets/js/app.js"}
  ]) {
    assert.equal(await offline.navigate(ignored), undefined);
  }
  assert.equal(offline.fetches.length, 1);
});

test("every push displays a visible notification even with a focused app client", async () => {
  const sw = worker([windowClient("https://handbean.example/c/conversation-1")]);
  await sw.dispatch("push", {data: {json() { return {
    title: "Task complete", body: "Your result is ready", url: "/c/conversation-1", tag: "run-1"
  }; }}});
  assert.equal(sw.shown.length, 1);
  assert.equal(sw.shown[0].title, "Task complete");
  assert.equal(sw.shown[0].body, "Your result is ready");
  assert.equal(sw.shown[0].tag, "run-1");
  assert.equal(sw.shown[0].data.url, "https://handbean.example/c/conversation-1");
});

test("empty, malformed, primitive, and invalid-field payloads still show generic visible notifications", async () => {
  const sw = worker();
  for (const data of [undefined, {json() { throw new Error("bad JSON"); }},
    {json() { return null; }}, {json() { return 4; }},
    {json() { return {title: {}, body: "", tag: ["x"], url: "javascript:alert(1)"}; }}]) {
    await sw.dispatch("push", {data});
  }
  assert.equal(sw.shown.length, 5);
  assert.equal(sw.shown.every((notice) => notice.title === "Handbean" && notice.body.length > 0), true);
  assert.equal(sw.shown.every((notice) => notice.data.url === "https://handbean.example/settings?tab=ui"), true);
});

test("notification clicks focus the exact existing conversation without navigation", async () => {
  const other = windowClient("https://handbean.example/c/other");
  const matching = windowClient("https://handbean.example/w/workspace-1/c/conversation-1");
  const sw = worker([other, matching]);
  await sw.click("/w/workspace-1/c/conversation-1");
  assert.equal(matching.focusCount, 1);
  assert.equal(matching.navigations.length, 0);
  assert.equal(other.focusCount, 0);
  assert.equal(sw.opened.length, 0);
});

test("encoded public IDs and dotted IDs focus the corresponding existing conversation", async () => {
  for (const [link, existing] of [
    ["/c/n1%3Apublic", "/c/n1:public"],
    ["/w/workspace.one/c/n1%3apublic", "/w/workspace.one/c/n1%3Apublic"],
    ["/c/public.one", "/c/public.one"]
  ]) {
    const app = windowClient(`https://handbean.example${existing}`);
    const sw = worker([app]);
    await sw.click(link);
    assert.equal(app.focusCount, 1, link);
    assert.equal(app.navigations.length, 0, link);
    assert.equal(sw.opened.length, 0, link);
  }
  const sw = worker();
  await sw.click("/c/n1%3Apublic");
  assert.deepEqual(sw.opened, ["https://handbean.example/c/n1%3Apublic"]);
});

test("notification click navigates and focuses an existing app window", async () => {
  const app = windowClient("https://handbean.example/c/old");
  const sw = worker([app]);
  await sw.click("/c/new");
  assert.deepEqual(app.navigations, ["https://handbean.example/c/new"]);
  assert.equal(app.focusCount, 1);
  assert.equal(sw.opened.length, 0);
});

test("notification click opens a safe app window when existing windows are unrelated or navigation fails", async () => {
  const external = windowClient("https://other.example/c/old");
  const unrelated = windowClient("https://handbean.example/admin");
  const sw = worker([external, unrelated]);
  await sw.click("/settings?tab=ui");
  assert.deepEqual(sw.opened, ["https://handbean.example/settings?tab=ui"]);
  assert.equal(external.navigations.length + unrelated.navigations.length, 0);
  const app = windowClient("https://handbean.example/");
  app.navigate = async () => { throw new Error("window closed"); };
  const retry = worker([app]);
  await retry.click("/c/new");
  assert.deepEqual(retry.opened, ["https://handbean.example/c/new"]);
});

test("unsafe or non-app notification URLs can only open the safe same-origin settings fallback", async () => {
  for (const url of [
    "https://attacker.example/c/run", "//attacker.example/c/run", "javascript:alert(1)",
    "data:text/html,hello", "https://user:secret@handbean.example/c/run", "/api/delete", "/c/a/b",
    "/c/%2f%2fattacker.example", "/settings?tab=ui&redirect=https://attacker.example", "/c/a?redirect=bad",
    "/c/a#bad", "https://handbean.example.attacker.example/c/run", "https://handbean.example:444/c/run",
    "/c/%2F", "/c/a%5Cb", "/c/.", "/c/..", "/c/%2e", "/c/%2E%2e", "/c/%252f",
    "/c/%00a", "/c/a%0D%0Ab", "/c/%C2%85", "/c/%", "/c/", "/c/a/../valid",
    "/w/ws/c/%2e%2e/c/valid", "/w/%2f/c/valid", "/c/a\\\\b"
  ]) {
    const sw = worker();
    await sw.dispatch("push", {data: {json() { return {url}; }}});
    assert.equal(sw.shown[0].data.url, "https://handbean.example/settings?tab=ui", url);
    await sw.click(url);
    assert.deepEqual(sw.opened, ["https://handbean.example/settings?tab=ui"], url);
  }
});
