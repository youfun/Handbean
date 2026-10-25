import assert from "node:assert/strict";
import test from "node:test";
import { JSDOM } from "jsdom";
import { createWebPush, pushSupport, applicationServerKey } from "../js/web_push.js";
import { renderPushNotifications } from "../js/hooks/push_notifications.js";

function fixture(options = {}) {
  const calls = [];
  const storage = options.storage || new Map();
  let current = null;
  let serial = 0;
  let unsubscribeFails = false;
  const configuration = {configured: true, public_key: "AQID", locale: "zh_CN", ...options.config};
  const failures = new Map();
  const subscription = (endpoint = `https://push.example/${++serial}`, key = [1, 2, 3]) => ({
    endpoint,
    options: {applicationServerKey: new Uint8Array(key).buffer},
    toJSON() { return {endpoint, keys: {p256dh: "public-key", auth: "auth-key"}}; },
    async unsubscribe() {
      calls.push({kind: "unsubscribe", endpoint});
      if (unsubscribeFails) throw new Error("unsubscribe_failed");
      current = null;
      return true;
    }
  });
  const registration = {
    active: {state: "activated"},
    pushManager: {
      async getSubscription() { return current; },
      async subscribe(value) {
        calls.push({kind: "subscribe", value});
        current = subscription();
        return current;
      }
    }
  };
  const env = {
    isSecureContext: true,
    PushManager: function() {},
    Notification: {
      permission: options.permission || "default",
      requestPermission() {
        calls.push({kind: "permission"});
        this.permission = options.answer || "granted";
        return Promise.resolve(this.permission);
      }
    },
    document: {querySelector() { return {content: "page-csrf"}; }},
    localStorage: {
      getItem(key) { return storage.get(key) || null; },
      setItem(key, value) { storage.set(key, value); },
      removeItem(key) { storage.delete(key); }
    },
    navigator: {
      userAgent: "Desktop browser",
      serviceWorker: {
        async register(url, value) { calls.push({kind: "register", url, value}); return registration; },
        ready: Promise.resolve(registration)
      },
      locks: {async request(name, callback) { calls.push({kind: "lock", name}); return callback(); }}
    },
    async fetch(url, request) {
      calls.push({kind: "api", url, ...request, body: request.body && JSON.parse(request.body)});
      const error = failures.get(`${request.method} ${url}`);
      if (typeof error === "function") return error(request);
      return {ok: !error, async json() { return error ? {error} : url.endsWith("/config") ? configuration : {ok: true}; }};
    }
  };
  return {
    env, calls, storage, failures, configuration, registration, subscription,
    push: createWebPush(env),
    set current(value) { current = value; },
    get current() { return current; },
    set unsubscribeFails(value) { unsubscribeFails = value; }
  };
}
const posts = (f) => f.calls.filter((call) => call.kind === "api" && call.method === "POST");

test("unsupported and insecure contexts never register, fetch or request permission", async () => {
  for (const [change, status] of [
    [(env) => { env.isSecureContext = false; }, "insecure"],
    [(env) => { delete env.PushManager; }, "unsupported"],
    [(env) => { env.navigator.userAgent = "iPhone"; }, "install"]
  ]) {
    const f = fixture();
    change(f.env);
    await f.push.reconcile();
    await f.push.enable();
    assert.equal(f.push.state.status, status);
    assert.equal(f.calls.some((call) => ["register", "api", "permission"].includes(call.kind)), false);
  }
  const f = fixture();
  f.env.navigator.platform = "MacIntel";
  f.env.navigator.maxTouchPoints = 5;
  assert.equal(pushSupport(f.env), "install");
  f.env.navigator.standalone = true;
  assert.equal(pushSupport(f.env), null);
});

test("startup registers root-scoped worker without creating a subscription or prompting", async () => {
  const f = fixture();
  await f.push.reconcile();
  assert.equal(f.push.state.status, "disabled");
  assert.deepEqual(f.calls.find((call) => call.kind === "register"), {
    kind: "register", url: "/sw.js", value: {scope: "/", updateViaCache: "none"}
  });
  assert.equal(posts(f).length, 0);
  assert.equal(f.calls.some((call) => call.kind === "permission" || call.kind === "subscribe"), false);
});

test("explicit enable prompts synchronously before locks or network and persists the browser subscription", async () => {
  const f = fixture();
  await f.push.reconcile();
  f.calls.length = 0;
  const enabled = f.push.enable();
  assert.deepEqual(f.calls.map((call) => call.kind), ["permission"]);
  await enabled;
  assert.equal(f.push.state.status, "enabled");
  const post = posts(f)[0];
  assert.deepEqual(post.body, {subscription: f.current.toJSON(), locale: "zh_CN"});
  assert.equal(post.credentials, "same-origin");
  assert.equal(post.headers["x-csrf-token"], "page-csrf");
  assert.equal(f.calls.find((call) => call.kind === "subscribe").value.userVisibleOnly, true);
  assert.deepEqual([...applicationServerKey("-_8")], [251, 255]);
});

test("permission rejection and dismissal never subscribe", async () => {
  for (const answer of ["denied", "default"]) {
    const f = fixture({answer});
    await f.push.reconcile();
    await f.push.enable();
    assert.equal(f.push.state.status, answer === "denied" ? "denied" : "dismissed");
    assert.equal(posts(f).length, 0);
    assert.equal(f.current, null);
  }
});

test("server configuration status is explicit and cannot trigger the permission prompt", async () => {
  const f = fixture({config: {configured: false, public_key: null}});
  await f.push.reconcile();
  await f.push.enable();
  assert.equal(f.push.state.status, "unconfigured");
  assert.equal(f.calls.some((call) => call.kind === "permission"), false);
});

test("existing and renewed browser subscriptions reconcile without prompts; locale can be updated", async () => {
  const f = fixture({permission: "granted"});
  f.current = f.subscription("https://push.example/old");
  await f.push.reconcile();
  f.current = f.subscription("https://push.example/renewed");
  f.push.setLocale("en");
  await f.push.reconcile();
  assert.deepEqual(posts(f).map((post) => [post.body.subscription.endpoint, post.body.locale]), [
    ["https://push.example/old", "zh_CN"], ["https://push.example/renewed", "en"]
  ]);
  assert.equal(f.calls.some((call) => call.kind === "permission" || call.kind === "subscribe"), false);
});

test("foreground visibility reconcile skips network calls when subscription and cleanup state are unchanged", async () => {
  const unsubscribed = fixture();
  await unsubscribed.push.reconcile();
  unsubscribed.calls.length = 0;
  await unsubscribed.push.reconcile({onlyIfChanged: true});
  assert.equal(unsubscribed.calls.some((call) => call.kind === "api"), false);

  const subscribed = fixture({permission: "granted"});
  subscribed.current = subscribed.subscription("https://push.example/stable");
  await subscribed.push.reconcile();
  assert.equal(posts(subscribed).length, 1);

  subscribed.calls.length = 0;
  await subscribed.push.reconcile({onlyIfChanged: true});
  assert.equal(subscribed.calls.some((call) => call.kind === "api"), false);
  assert.equal(subscribed.push.state.status, "enabled");

  subscribed.current = subscribed.subscription("https://push.example/rotated");
  await subscribed.push.reconcile({onlyIfChanged: true});
  assert.equal(posts(subscribed).length, 1);
  assert.equal(posts(subscribed)[0].body.subscription.endpoint, "https://push.example/rotated");
});

test("existing subscriptions with revoked or ungranted permission are never persisted", async () => {
  for (const permission of ["denied", "default"]) {
    const f = fixture({permission});
    f.current = f.subscription();
    await f.push.reconcile();
    assert.equal(posts(f).length, 0);
    assert.equal(f.push.state.subscribed, true, "the user can still remove the browser subscription");
  }
});

test("changed application key requires explicit enable to replace the subscription", async () => {
  const f = fixture({permission: "granted"});
  f.current = f.subscription("https://push.example/previous", [9]);
  await f.push.reconcile();
  assert.equal(f.push.state.status, "renewal");
  assert.equal(posts(f).length, 0);
  await f.push.enable();
  assert.equal(f.push.state.status, "enabled");
  assert.notEqual(f.current.endpoint, "https://push.example/previous");
  assert.equal(f.calls.some((call) => call.method === "DELETE" && call.body.endpoint.endsWith("previous")), true);
});

test("persistence failure rolls back a newly created browser subscription and removes the record", async () => {
  const f = fixture();
  await f.push.reconcile();
  f.failures.set("POST /api/web-push/subscription", "subscription_limit");
  await f.push.enable();
  assert.equal(f.push.state.error, "subscription_limit");
  assert.equal(f.push.state.subscribed, false);
  assert.equal(f.current, null);
  assert.equal(f.storage.size, 0);
  assert.equal(f.calls.some((call) => call.method === "DELETE"), true);
});

test("conflicting existing subscription is not silently replaced; explicit disable/enable recovers", async () => {
  const f = fixture({permission: "granted"});
  f.current = f.subscription("https://push.example/conflict");
  f.failures.set("POST /api/web-push/subscription", "subscription_conflict");
  await f.push.reconcile();
  assert.equal(f.push.state.error, "subscription_conflict");
  assert.equal(f.current.endpoint, "https://push.example/conflict");
  await f.push.disable();
  f.failures.clear();
  await f.push.enable();
  assert.equal(f.push.state.status, "enabled");
  assert.notEqual(f.current.endpoint, "https://push.example/conflict");
});

test("disable survives server failure and a fresh page finishes cleanup without re-enabling", async () => {
  const f = fixture({permission: "granted"});
  f.current = f.subscription();
  await f.push.reconcile();
  f.failures.set("DELETE /api/web-push/subscription", "offline");
  await f.push.disable();
  assert.equal(f.push.state.error, "offline");
  assert.equal(f.push.state.status, "cleanup");
  assert.equal(f.current, null);
  assert.equal(f.storage.size, 1);
  f.calls.length = 0;
  f.failures.clear();
  const freshPage = createWebPush(f.env);
  await freshPage.reconcile();
  await freshPage.reconcile();
  assert.equal(freshPage.state.status, "disabled");
  assert.equal(f.storage.size, 0);
  assert.equal(posts(f).length, 0);
  assert.equal(f.calls.some((call) => call.kind === "subscribe"), false);
});

test("failed unsubscribe still attempts server removal, keeps intent and never reconciles the old subscription", async () => {
  const f = fixture({permission: "granted"});
  f.current = f.subscription();
  await f.push.reconcile();
  f.unsubscribeFails = true;
  f.calls.length = 0;
  await f.push.disable();
  assert.equal(f.storage.size, 1);
  assert.equal(f.calls.some((call) => call.method === "DELETE"), true);
  const freshPage = createWebPush(f.env);
  await freshPage.reconcile();
  assert.equal(posts(f).length, 0);
  assert.equal(freshPage.state.error, "unsubscribe_failed");
  f.unsubscribeFails = false;
  await freshPage.reconcile();
  assert.equal(f.current, null);
  assert.equal(f.storage.size, 0);
});

test("pending disable covers rotated subscriptions and retains only failed server cleanup targets", async () => {
  const f = fixture({permission: "granted"});
  const endpointA = "https://push.example/A";
  const endpointB = "https://push.example/B";
  f.current = f.subscription(endpointA);
  await f.push.reconcile();
  f.unsubscribeFails = true;
  f.failures.set("DELETE /api/web-push/subscription", "offline");
  await f.push.disable();
  assert.equal(f.push.state.status, "cleanup");
  f.current = f.subscription(endpointB);
  f.unsubscribeFails = false;
  f.calls.length = 0;
  f.failures.set("DELETE /api/web-push/subscription", async (request) => {
    const failed = JSON.parse(request.body).endpoint === endpointB;
    return {ok: !failed, async json() { return failed ? {error: "offline"} : {ok: true}; }};
  });
  const freshPage = createWebPush(f.env);
  await freshPage.reconcile();
  assert.equal(f.current, null, "rotated B is unsubscribed while cleaning A");
  assert.equal(freshPage.state.status, "cleanup");
  assert.deepEqual(f.calls.filter((call) => call.method === "DELETE").map((call) => call.body.endpoint), [endpointA, endpointB]);
  assert.deepEqual(JSON.parse([...f.storage.values()][0]), [endpointB]);
  assert.equal(posts(f).length, 0);
  f.calls.length = 0;
  f.failures.clear();
  const nextPage = createWebPush(f.env);
  await nextPage.reconcile();
  await nextPage.reconcile();
  assert.equal(nextPage.state.status, "disabled");
  assert.equal(f.storage.size, 0);
  assert.deepEqual(f.calls.filter((call) => call.method === "DELETE").map((call) => call.body.endpoint), [endpointB]);
  assert.equal(posts(f).length, 0, "neither A nor B can be automatically re-enabled");
});

test("legacy single-endpoint disable intent also removes the browser's renewed subscription", async () => {
  const f = fixture({permission: "granted"});
  f.storage.set("handbean-web-push-pending-disable", "https://push.example/legacy-A");
  f.current = f.subscription("https://push.example/renewed-B");
  await f.push.reconcile();
  assert.equal(f.current, null);
  assert.equal(f.storage.size, 0);
  assert.equal(f.push.state.status, "disabled");
  assert.deepEqual(f.calls.filter((call) => call.method === "DELETE").map((call) => call.body.endpoint), [
    "https://push.example/legacy-A", "https://push.example/renewed-B"
  ]);
  await f.push.reconcile();
  assert.equal(posts(f).length, 0);
});

test("rotation during server cleanup keeps registration opt-out pending until the new subscription is removed", async () => {
  const f = fixture({permission: "granted"});
  f.current = f.subscription("https://push.example/A");
  await f.push.reconcile();
  f.failures.set("DELETE /api/web-push/subscription", async () => {
    f.current = f.subscription("https://push.example/B");
    return {ok: true, async json() { return {ok: true}; }};
  });
  await f.push.disable();
  assert.equal(f.push.state.status, "cleanup");
  assert.equal(f.push.state.subscribed, true);
  assert.deepEqual(JSON.parse([...f.storage.values()][0]), ["https://push.example/B"]);
  f.failures.clear();
  f.calls.length = 0;
  await createWebPush(f.env).reconcile();
  assert.equal(f.current, null);
  assert.equal(f.storage.size, 0);
  assert.equal(posts(f).length, 0);
});

test("storage read, write and removal failures never report disable success or silently re-enable", async () => {
  for (const method of ["getItem", "setItem", "removeItem"]) {
    const f = fixture({permission: "granted"});
    f.current = f.subscription();
    await f.push.reconcile();
    const original = f.env.localStorage[method];
    f.env.localStorage[method] = () => { throw new Error("storage unavailable"); };
    f.calls.length = 0;
    await f.push.disable();
    assert.equal(f.push.state.status, "cleanup", method);
    assert.equal(f.push.state.error, "cleanup_storage_failed", method);
    assert.equal(posts(f).length, 0, method);
    if (method !== "removeItem") {
      assert.ok(f.current, "no teardown before intent can be read and persisted");
      assert.equal(f.calls.some((call) => call.kind === "unsubscribe"), false);
    } else {
      assert.equal(f.current, null);
      assert.equal(f.storage.size, 1, "failed marker removal remains retryable");
    }
    if (method !== "setItem") {
      await createWebPush(f.env).reconcile();
      assert.equal(posts(f).length, 0, method);
    }
    f.env.localStorage[method] = original;
    await f.push.disable();
    assert.equal(f.push.state.status, "disabled", method);
    assert.equal(f.current, null);
    assert.equal(f.storage.size, 0);
  }
});

test("malformed cleanup storage blocks automatic persistence instead of discarding opt-out intent", async () => {
  const f = fixture({permission: "granted"});
  f.current = f.subscription();
  f.storage.set("handbean-web-push-pending-disable", "{");
  await f.push.reconcile();
  assert.equal(f.push.state.error, "cleanup_storage_invalid");
  assert.equal(f.push.state.status, "cleanup");
  assert.equal(posts(f).length, 0);
  assert.equal(f.storage.size, 1);
});

test("a stale test-notification button honors another tab's registration disable intent", async () => {
  const f = fixture({permission: "granted"});
  f.current = f.subscription("https://push.example/B");
  await f.push.reconcile();
  f.storage.set("handbean-web-push-pending-disable", "https://push.example/A");
  f.calls.length = 0;
  await f.push.test();
  assert.equal(f.current, null);
  assert.equal(f.push.state.status, "disabled");
  assert.equal(posts(f).length, 0);
});

test("failed rollback retains cleanup intent and presents a recoverable error", async () => {
  const f = fixture();
  await f.push.reconcile();
  f.unsubscribeFails = true;
  f.failures.set("POST /api/web-push/subscription", "offline");
  await f.push.enable();
  assert.equal(f.push.state.error, "rollback_failed");
  assert.equal(f.push.state.subscribed, true);
  assert.equal(f.storage.size, 1);
  f.unsubscribeFails = false;
  await f.push.disable();
  assert.equal(f.current, null);
});

test("test notification success is reported only after server delivery has been accepted", async () => {
  const f = fixture({permission: "granted"});
  f.current = f.subscription();
  await f.push.reconcile();
  let accept;
  f.failures.set("POST /api/web-push/test", () => new Promise((resolve) => { accept = resolve; }));
  const sending = f.push.test();
  while (!accept) await Promise.resolve();
  assert.equal(f.push.state.busy, true);
  assert.notEqual(f.push.state.status, "sent");
  accept({ok: true, async json() { return {ok: true}; }});
  await sending;
  assert.equal(f.push.state.status, "sent");
  f.failures.set("POST /api/web-push/test", "delivery_failed");
  await f.push.test();
  assert.equal(f.push.state.error, "delivery_failed");
  assert.notEqual(f.push.state.status, "sent");
});

test("expired test subscriptions are cleaned up and require an explicit enable", async () => {
  const f = fixture({permission: "granted"});
  f.current = f.subscription("https://push.example/expired");
  await f.push.reconcile();
  f.failures.set("POST /api/web-push/test", "subscription_expired");
  await f.push.test();
  assert.equal(f.push.state.status, "subscription_expired");
  assert.equal(f.push.state.error, "subscription_expired");
  assert.equal(f.push.state.subscribed, false);
  assert.equal(f.current, null);
  f.calls.length = 0;
  await f.push.reconcile();
  assert.equal(posts(f).length, 0);
  await f.push.enable();
  assert.equal(f.push.state.status, "enabled");
  assert.notEqual(f.current.endpoint, "https://push.example/expired");
});

test("reconcile and disable in separate tabs share a lock and leave the durable record removed", async () => {
  const f = fixture({permission: "granted"});
  f.current = f.subscription();
  let tail = Promise.resolve();
  f.env.navigator.locks.request = (_name, callback) => {
    const result = tail.then(callback);
    tail = result.catch(() => {});
    return result;
  };
  const secondTab = createWebPush(f.env);
  await Promise.all([f.push.reconcile(), secondTab.reconcile()]);
  f.calls.length = 0;
  await Promise.all([f.push.reconcile(), secondTab.disable()]);
  assert.equal(f.current, null);
  assert.equal(f.calls.filter((call) => call.kind === "api").at(-1).method, "DELETE");
  await f.push.reconcile();
  assert.equal(f.push.state.subscribed, false);
});

test("settings controls expose busy state, denied permission and specific recovery guidance accessibly", () => {
  const dom = new JSDOM(`<section data-locale="en">
    <p data-push-status role="status"></p><p data-push-error role="alert"></p>
    <button data-push-action="enable"></button><button data-push-action="disable"></button>
    <button data-push-action="test"></button><button data-push-action="reconcile"></button>
    <div hidden><span data-push-message="denied">Allow notifications in browser settings</span>
    <span data-push-message="busy">Updating</span>
    <span data-push-message="subscription_expired">Subscription expired; enable again</span>
    <span data-push-message="subscription_conflict">Disable then enable</span></div>
  </section>`);
  const el = dom.window.document.querySelector("section");
  renderPushNotifications(el, {status: "denied", configured: true, busy: false});
  assert.equal(el.querySelector('[data-push-action="enable"]').disabled, true);
  assert.equal(el.querySelector('[role="status"]').textContent, "Allow notifications in browser settings");
  renderPushNotifications(el, {status: "enabled", configured: true, subscribed: true, busy: true});
  assert.equal(el.getAttribute("aria-busy"), "true");
  assert.equal(el.querySelector('[data-push-action="disable"]').disabled, true);
  assert.equal(el.querySelector('[data-push-action="test"]').disabled, true);
  renderPushNotifications(el, {status: "checking", configured: true, subscribed: true, error: "subscription_conflict"});
  assert.equal(el.querySelector('[role="alert"]').textContent, "Disable then enable");
  assert.equal(el.querySelector('[data-push-action="disable"]').hidden, false);
  renderPushNotifications(el, {status: "subscription_expired", configured: true, busy: false, subscribed: false, error: "subscription_expired"});
  assert.equal(el.querySelector('[role="alert"]').textContent, "Subscription expired; enable again");
  assert.equal(el.querySelector('[data-push-action="enable"]').hidden, false);
  assert.equal(el.querySelector('[data-push-action="enable"]').disabled, false);
  assert.equal(el.querySelector('[data-push-action="test"]').disabled, true);
  assert.equal(el.querySelector('[data-push-action="test"]').hidden, true);
});
