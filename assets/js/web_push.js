import { registerServiceWorker } from "./service_worker.js";

const API = "/api/web-push";
const LOCK = "handbean-web-push";
const CLEANUP = "handbean-web-push-pending-disable";

export function pushSupport(env = globalThis) {
  if (!env.isSecureContext) return "insecure";
  const navigator = env.navigator;
  const ios = /iPad|iPhone|iPod/.test(navigator?.userAgent || "") ||
    (navigator?.platform === "MacIntel" && navigator.maxTouchPoints > 1);
  const standalone = navigator?.standalone || env.matchMedia?.("(display-mode: standalone)").matches;
  if (ios && !standalone) return "install";
  if (!navigator?.serviceWorker || !env.PushManager || !env.Notification) return "unsupported";
  return null;
}

export function applicationServerKey(value) {
  const base64 = value.replace(/-/g, "+").replace(/_/g, "/");
  const decoded = atob(base64.padEnd(Math.ceil(base64.length / 4) * 4, "="));
  return Uint8Array.from(decoded, (character) => character.charCodeAt(0));
}

function keyMatches(subscription, publicKey) {
  const current = subscription.options?.applicationServerKey;
  if (!current) return true;
  const expected = applicationServerKey(publicKey);
  const bytes = new Uint8Array(current);
  return bytes.length === expected.length && bytes.every((byte, index) => byte === expected[index]);
}

export function createWebPush(env = globalThis) {
  let registration;
  let config;
  let locale;
  let pending;
  let persistedSignature = null;
  const listeners = new Set();
  let state = {status: "checking", busy: false, subscribed: false, configured: false, error: null};

  function resolvedLocale() {
    return (locale || config?.locale) === "zh_CN" ? "zh_CN" : "en";
  }

  function subscriptionSignature(subscription) {
    return JSON.stringify([subscription.toJSON(), resolvedLocale(), config?.public_key || null]);
  }

  function update(changes) {
    state = {...state, ...changes};
    listeners.forEach((listener) => listener(state));
    return state;
  }

  async function api(path, method = "GET", body) {
    const csrf = env.document.querySelector("meta[name='csrf-token']")?.content;
    if (!csrf) throw new Error("csrf_missing");
    const response = await env.fetch(`${API}/${path}`, {
      method,
      credentials: "same-origin",
      cache: "no-store",
      headers: {"accept": "application/json", "content-type": "application/json", "x-csrf-token": csrf},
      ...(body ? {body: JSON.stringify(body)} : {})
    });
    const result = await response.json();
    if (!response.ok || result.error) throw new Error(result.error || "request_failed");
    return result;
  }

  function operation(work) {
    if (pending) return pending;
    update({busy: true, error: null});
    const execute = async () => {
      try {
        await work();
      } catch (error) {
        update({error: error.message || "request_failed"});
      } finally {
        update({busy: false});
      }
      return state;
    };
    // The browser subscription is shared by tabs. Keep reconcile and removal ordered.
    pending = Promise.resolve().then(() => env.navigator?.locks
      ? env.navigator.locks.request(LOCK, execute)
      : execute()).catch((error) => update({busy: false, error: error.message || "request_failed"}))
      .finally(() => { pending = null; });
    return pending;
  }

  async function ready() {
    if (!registration) registration = await registerServiceWorker(env);
    return registration;
  }

  async function loadConfig() {
    config = await api("config");
    update({configured: Boolean(config.configured && config.public_key)});
  }

  async function persist(subscription) {
    await api("subscription", "POST", {
      subscription: subscription.toJSON(),
      locale: resolvedLocale()
    });
    persistedSignature = subscriptionSignature(subscription);
  }

  function cleanupStorage(method, value) {
    try {
      return env.localStorage[method](CLEANUP, value);
    } catch (_) {
      update({status: "cleanup"});
      throw new Error("cleanup_storage_failed");
    }
  }

  function pendingCleanup() {
    const value = cleanupStorage("getItem");
    if (value === null) return null;
    // Migrate the previous single-endpoint value without dropping its intent.
    if (value.startsWith("https://")) return [value];
    try {
      const endpoints = JSON.parse(value);
      if (Array.isArray(endpoints) && endpoints.every((endpoint) =>
        typeof endpoint === "string" && endpoint.startsWith("https://"))) return endpoints;
    } catch (_) {}
    update({status: "cleanup"});
    throw new Error("cleanup_storage_invalid");
  }

  async function cleanup(endpoints) {
    persistedSignature = null;
    update({status: "cleanup"});
    const targets = new Set(endpoints);
    cleanupStorage("setItem", JSON.stringify([...targets]));
    const subscription = await registration.pushManager.getSubscription();
    if (subscription) targets.add(subscription.endpoint);
    // This marker means disable the entire registration, including a subscription
    // renewed since a previous attempt. Persist every known endpoint before effects.
    cleanupStorage("setItem", JSON.stringify([...targets]));
    let failure;
    if (subscription) {
      try {
        const removed = await subscription.unsubscribe();
        if (!removed) throw new Error("unsubscribe_failed");
      } catch (error) { failure = error; }
    }
    for (const endpoint of targets) {
      try {
        await api("subscription", "DELETE", {endpoint});
        targets.delete(endpoint);
      } catch (error) { failure ||= error; }
    }
    const remaining = await registration.pushManager.getSubscription();
    update({subscribed: Boolean(remaining)});
    // Rotation may also occur during unsubscribe or DELETE. Keep the registration
    // disabled in intent and clean the new endpoint on the next foreground attempt.
    if (remaining) {
      targets.add(remaining.endpoint);
      failure ||= new Error("unsubscribe_failed");
    }
    cleanupStorage("setItem", JSON.stringify([...targets]));
    if (failure) throw failure;
    cleanupStorage("removeItem");
    update({status: "disabled"});
  }

  async function remove(subscription) {
    await cleanup([...(pendingCleanup() || []), subscription.endpoint]);
  }

  function reconcile(options = {}) {
    const onlyIfChanged = Boolean(options?.onlyIfChanged);
    return operation(async () => {
      const unsupported = pushSupport(env);
      if (unsupported) {
        update({status: unsupported});
        return;
      }
      await ready();
      const subscription = await registration.pushManager.getSubscription();
      update({subscribed: Boolean(subscription)});
      if (onlyIfChanged && config && pendingCleanup() === null) {
        if (!state.configured) {
          update({status: "unconfigured"});
          return;
        }
        if (env.Notification.permission !== "granted") {
          update({status: env.Notification.permission === "denied" ? "denied" : "disabled"});
          return;
        }
        if (!subscription) {
          update({status: "disabled"});
          return;
        }
        if (keyMatches(subscription, config.public_key) && persistedSignature === subscriptionSignature(subscription)) {
          update({status: "enabled"});
          return;
        }
      }
      await loadConfig();
      const endpoints = pendingCleanup();
      if (endpoints) {
        await cleanup(endpoints);
        return;
      }
      if (!state.configured) {
        update({status: "unconfigured"});
      } else if (env.Notification.permission !== "granted") {
        update({status: env.Notification.permission === "denied" ? "denied" : "disabled"});
      } else if (!subscription) {
        persistedSignature = null;
        update({status: "disabled"});
      } else if (!keyMatches(subscription, config.public_key)) {
        persistedSignature = null;
        update({status: "renewal"});
      } else {
        await persist(subscription);
        update({status: "enabled"});
      }
    });
  }

  // This function must be entered directly from the click handler: Safari requires
  // requestPermission before any await, fetch, lock, or service-worker promise.
  function enable() {
    if (pending || pushSupport(env) || !state.configured) return pending || Promise.resolve(state);
    let permission;
    try {
      permission = env.Notification.permission === "default"
        ? env.Notification.requestPermission()
        : Promise.resolve(env.Notification.permission);
    } catch (error) {
      return Promise.resolve(update({error: error.message || "permission_failed"}));
    }
    // Attach a rejection handler immediately, including while another tab owns the lock.
    const result = Promise.resolve(permission).then((value) => ({value}), (error) => ({error}));
    return operation(async () => {
      const answer = await result;
      if (answer.error) throw answer.error;
      if (answer.value !== "granted") {
        update({status: answer.value === "denied" ? "denied" : "dismissed"});
        return;
      }
      await ready();
      await loadConfig();
      if (!state.configured) {
        update({status: "unconfigured"});
        return;
      }
      const endpoints = pendingCleanup();
      if (endpoints) await cleanup(endpoints);
      let subscription = await registration.pushManager.getSubscription();
      if (subscription && !keyMatches(subscription, config.public_key)) {
        await remove(subscription);
        subscription = null;
      }
      const created = !subscription;
      subscription ||= await registration.pushManager.subscribe({
        userVisibleOnly: true,
        applicationServerKey: applicationServerKey(config.public_key)
      });
      update({subscribed: true});
      try {
        await persist(subscription);
      } catch (error) {
        if (created) {
          try {
            await remove(subscription);
          } catch (_) {
            if (await registration.pushManager.getSubscription()) {
              update({status: "cleanup"});
              throw new Error("rollback_failed");
            }
          }
        }
        throw error;
      }
      update({status: "enabled"});
    });
  }

  function disable() {
    return operation(async () => {
      await ready();
      await cleanup(pendingCleanup() || []);
    });
  }

  function test() {
    return operation(async () => {
      await ready();
      const endpoints = pendingCleanup();
      if (endpoints) {
        await cleanup(endpoints);
        return;
      }
      const subscription = await registration.pushManager.getSubscription();
      if (!subscription) {
        update({subscribed: false, status: "disabled"});
        return;
      }
      update({status: "enabled"});
      try {
        await api("test", "POST", {endpoint: subscription.endpoint});
      } catch (error) {
        if (error.message === "subscription_expired") {
          await remove(subscription);
          update({status: "subscription_expired"});
        }
        throw error;
      }
      update({status: "sent"});
    });
  }

  return {
    get state() { return state; },
    reconcile, enable, disable, test,
    setLocale(value) { locale = value; },
    subscribe(listener) {
      listeners.add(listener);
      listener(state);
      return () => listeners.delete(listener);
    }
  };
}

let browserPush;
let browserPushBooted = false;
export function webPush() {
  browserPush ||= createWebPush(window);
  return browserPush;
}

export function bootWebPush() {
  if (browserPushBooted) return;
  browserPushBooted = true;
  const push = webPush();
  void push.reconcile();
  // Renewal is reconciled in a foreground page with its current CSRF token.
  // No worker background request bypasses the authenticated subscription API.
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible") void push.reconcile({onlyIfChanged: true});
  });
  window.addEventListener("pageshow", (event) => {
    if (event.persisted) void push.reconcile({onlyIfChanged: true});
  });
}
