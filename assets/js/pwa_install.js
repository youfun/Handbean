import { registerServiceWorker } from "./service_worker.js";

function standalone(env) {
  return env.navigator?.standalone === true ||
    env.matchMedia?.("(display-mode: standalone)")?.matches === true;
}

function ios(env) {
  const navigator = env.navigator;
  return /iPad|iPhone|iPod/.test(navigator?.userAgent || "") ||
    (navigator?.platform === "MacIntel" && navigator.maxTouchPoints > 1);
}

function initialState(env) {
  if (standalone(env)) return {status: "standalone", installed: true, canInstall: false, busy: false};
  if (ios(env)) return {status: "ios", installed: false, canInstall: false, busy: false};
  return {status: "browser", installed: false, canInstall: false, busy: false};
}

export function createPWAInstall(env = globalThis) {
  let state = initialState(env);
  let promptEvent;
  let started = false;
  const listeners = new Set();

  function update(changes) {
    state = {...state, ...changes};
    listeners.forEach((listener) => listener(state));
    return state;
  }

  function markStandalone() {
    promptEvent = null;
    update({status: "standalone", installed: true, canInstall: false, busy: false});
  }

  function markInstalled() {
    promptEvent = null;
    update({status: "installed", installed: true, canInstall: false, busy: false});
  }

  function capturePrompt(event) {
    if (state.installed || ios(env)) return;
    event.preventDefault();
    promptEvent = event;
    update({status: "available", canInstall: true, busy: false});
  }

  function displayModeChanged(event) {
    if (event.matches) markStandalone();
  }

  function start() {
    if (started) return state;
    started = true;
    env.addEventListener?.("beforeinstallprompt", capturePrompt);
    env.addEventListener?.("appinstalled", markInstalled);
    const media = env.matchMedia?.("(display-mode: standalone)");
    media?.addEventListener?.("change", displayModeChanged);
    media?.addListener?.(displayModeChanged);
    if (standalone(env)) markStandalone();
    void registerServiceWorker(env).catch(() => {});
    return state;
  }

  function install() {
    if (!promptEvent || state.busy || state.installed) return Promise.resolve(state);
    const current = promptEvent;
    promptEvent = null;
    update({status: "installing", canInstall: false, busy: true});

    let opened;
    try {
      // Keep prompt() in the click call stack: browsers require a user gesture.
      opened = current.prompt();
    } catch (_) {
      return Promise.resolve(update({status: "failed", canInstall: false, busy: false}));
    }

    return Promise.resolve(opened)
      .then(() => current.userChoice)
      .then((choice) => {
        if (state.installed) return state;
        return choice?.outcome === "accepted"
          ? update({status: "accepted", canInstall: false, busy: false})
          : update({status: "dismissed", canInstall: false, busy: false});
      })
      .catch(() => update({status: "failed", canInstall: false, busy: false}));
  }

  function subscribe(listener) {
    listeners.add(listener);
    listener(state);
    return () => listeners.delete(listener);
  }

  return {
    start,
    install,
    subscribe,
    get state() { return state; }
  };
}

let browserInstall;

export function pwaInstall() {
  browserInstall ||= createPWAInstall(window);
  return browserInstall;
}

export function bootPWAInstall() {
  return pwaInstall().start();
}
