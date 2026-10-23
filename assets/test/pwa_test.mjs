import assert from "node:assert/strict";
import test from "node:test";
import { JSDOM } from "jsdom";
import { createPWAInstall } from "../js/pwa_install.js";
import { renderPWAInstall } from "../js/hooks/pwa_install.js";
import { createConnectionStatus } from "../js/connection_status.js";
import { registerServiceWorker } from "../js/service_worker.js";

function browser(options = {}) {
  const listeners = new Map();
  const calls = [];
  const mediaListeners = [];
  const media = {
    matches: Boolean(options.standalone),
    addEventListener(name, listener) { if (name === "change") mediaListeners.push(listener); }
  };
  const registration = {active: {state: "activated"}};
  const env = {
    isSecureContext: options.secure !== false,
    navigator: {
      userAgent: options.userAgent || "Desktop browser",
      platform: options.platform || "",
      maxTouchPoints: options.maxTouchPoints || 0,
      standalone: Boolean(options.navigatorStandalone),
      serviceWorker: {
        async register(url, config) { calls.push({kind: "register", url, config}); return registration; },
        ready: Promise.resolve(registration)
      }
    },
    matchMedia() { return media; },
    addEventListener(name, listener) {
      const entries = listeners.get(name) || [];
      entries.push(listener);
      listeners.set(name, entries);
    },
    dispatch(name, event = {}) {
      for (const listener of listeners.get(name) || []) listener(event);
    }
  };
  return {env, calls, media, mediaListeners};
}

function installEvent(outcome = "accepted") {
  let prevented = false;
  let prompted = 0;
  return {
    preventDefault() { prevented = true; },
    prompt() { prompted++; return Promise.resolve(); },
    userChoice: Promise.resolve({outcome}),
    get prevented() { return prevented; },
    get prompted() { return prompted; }
  };
}

test("failed first-time worker installation rejects asynchronously and a later registration can retry", async () => {
  let attempts = 0;
  let stateChanged;
  const failedWorker = {
    state: "installing",
    addEventListener(name, listener) { if (name === "statechange") stateChanged = listener; },
    removeEventListener() {}
  };
  const serviceWorker = {
    register() {
      attempts++;
      return attempts === 1
        ? Promise.resolve({installing: failedWorker})
        : Promise.resolve({active: {state: "activated"}});
    },
    addEventListener() {},
    removeEventListener() {}
  };
  const env = {isSecureContext: true, navigator: {serviceWorker}};

  const failed = registerServiceWorker(env);
  await new Promise((resolve) => setImmediate(resolve));
  failedWorker.state = "redundant";
  stateChanged();
  await assert.rejects(failed, /service_worker_installation_failed/);
  assert.equal((await registerServiceWorker(env)).active.state, "activated");
  assert.equal(attempts, 2);
});

test("worker registration resolves an asynchronous activation and clears its timeout", async () => {
  let stateChanged;
  let cleared;
  const worker = {
    state: "installing",
    addEventListener(name, listener) { if (name === "statechange") stateChanged = listener; },
    removeEventListener() {}
  };
  const registration = {installing: worker};
  const serviceWorker = {
    async register() { return registration; },
    addEventListener() {},
    removeEventListener() {}
  };
  const env = {
    isSecureContext: true,
    navigator: {serviceWorker},
    setTimeout() { return 42; },
    clearTimeout(value) { cleared = value; }
  };

  const pending = registerServiceWorker(env);
  await new Promise((resolve) => setImmediate(resolve));
  worker.state = "activated";
  stateChanged();
  assert.equal(await pending, registration);
  assert.equal(cleared, 42);
});

test("install prompt is captured, invoked directly, and reports browser completion", async () => {
  const fixture = browser();
  const install = createPWAInstall(fixture.env);
  install.start();
  await Promise.resolve();
  assert.deepEqual(fixture.calls[0], {
    kind: "register", url: "/sw.js", config: {scope: "/", updateViaCache: "none"}
  });

  const event = installEvent();
  fixture.env.dispatch("beforeinstallprompt", event);
  assert.equal(event.prevented, true);
  assert.equal(install.state.status, "available");
  assert.equal(install.state.canInstall, true);

  const pending = install.install();
  assert.equal(event.prompted, 1);
  assert.equal(install.state.status, "installing");
  await pending;
  assert.equal(install.state.status, "accepted");
  fixture.env.dispatch("appinstalled");
  assert.deepEqual(install.state, {status: "installed", installed: true, canInstall: false, busy: false});
});

test("dismissed prompts are one-shot and a later eligibility event can offer installation again", async () => {
  const fixture = browser();
  const install = createPWAInstall(fixture.env);
  install.start();
  const first = installEvent("dismissed");
  fixture.env.dispatch("beforeinstallprompt", first);
  await install.install();
  assert.equal(install.state.status, "dismissed");
  await install.install();
  assert.equal(first.prompted, 1);

  const second = installEvent();
  fixture.env.dispatch("beforeinstallprompt", second);
  assert.equal(install.state.status, "available");
});

test("standalone and iOS browsers expose the correct installation state without a custom prompt", () => {
  const installed = createPWAInstall(browser({standalone: true}).env);
  assert.equal(installed.state.status, "standalone");
  const fixture = browser({userAgent: "iPhone"});
  const ios = createPWAInstall(fixture.env);
  ios.start();
  const event = installEvent();
  fixture.env.dispatch("beforeinstallprompt", event);
  assert.equal(ios.state.status, "ios");
  assert.equal(event.prevented, false);
});

test("installation UI exposes the action only when eligible and shows the iOS guide", () => {
  const dom = new JSDOM(`
    <section aria-busy="false">
      <p data-pwa-install-status></p>
      <button data-pwa-install-action hidden></button>
      <div data-pwa-ios-guide hidden></div>
      <span data-pwa-install-message="available">Ready to install</span>
      <span data-pwa-install-message="ios">Use Safari</span>
    </section>
  `);
  const element = dom.window.document.querySelector("section");
  renderPWAInstall(element, {status: "available", canInstall: true, busy: false});
  assert.equal(element.querySelector("[data-pwa-install-status]").textContent, "Ready to install");
  assert.equal(element.querySelector("button").hidden, false);
  assert.equal(element.querySelector("[data-pwa-ios-guide]").hidden, true);

  renderPWAInstall(element, {status: "ios", canInstall: false, busy: false});
  assert.equal(element.querySelector("button").hidden, true);
  assert.equal(element.querySelector("[data-pwa-ios-guide]").hidden, false);
});

test("connection status follows LiveView join state and recovers when the socket never reopened", () => {
  const dom = new JSDOM(`
    <main class="phx-connected"></main>
    <div hidden><span data-connection-copy></span>
      <span data-connection-message="connected"></span>
      <span data-connection-message="offline">Offline</span>
      <span data-connection-message="reconnecting">Reconnecting</span>
      <span data-connection-message="restored">Restored</span>
    </div>
  `);
  const listeners = new Map();
  const timers = [];
  let observer;
  class MutationObserver {
    constructor(callback) { this.callback = callback; observer = this; }
    observe() {}
    disconnect() {}
    trigger() { this.callback(); }
  }
  const navigator = {onLine: true};
  const env = {
    navigator,
    MutationObserver,
    addEventListener(name, listener) { listeners.set(name, listener); },
    removeEventListener() {},
    setTimeout(callback) { timers.push(callback); return timers.length; },
    clearTimeout() {}
  };
  const root = dom.window.document.querySelector("main");
  const element = dom.window.document.querySelector("div");
  const status = createConnectionStatus(element, env);
  root.className = "phx-loading";
  status.bind(root);
  assert.equal(element.hidden, true);

  root.className = "phx-connected";
  observer.trigger();
  assert.equal(element.hidden, true);
  assert.equal(element.dataset.state, "connected");

  // A LiveView channel failure is visible even if the transport socket remains open.
  root.className = "phx-client-error";
  observer.trigger();
  assert.equal(element.dataset.state, "reconnecting");
  assert.equal(element.textContent.includes("Reconnecting"), true);

  root.className = "phx-connected";
  observer.trigger();
  assert.equal(element.dataset.state, "restored");

  // Browser connectivity can recover without a new socket open event.
  navigator.onLine = false;
  listeners.get("offline")();
  assert.equal(element.dataset.state, "offline");
  observer.trigger();
  assert.equal(element.dataset.state, "offline");
  navigator.onLine = true;
  listeners.get("online")();
  assert.equal(element.dataset.state, "restored");
  timers.at(-1)();
  assert.equal(element.hidden, true);

  // Subsequent normal class mutations while connected do not re-trigger restored banner.
  observer.trigger();
  assert.equal(element.hidden, true);
  assert.equal(element.dataset.state, "connected");
});
