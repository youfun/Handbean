const registrations = new WeakMap();
const ACTIVATION_TIMEOUT_MS = 15_000;

function waitForActivation(env, serviceWorker, registration) {
  if (registration.active) return Promise.resolve(registration);
  const worker = registration.installing || registration.waiting;
  if (!worker) return Promise.reject(new Error("service_worker_installation_missing"));

  return new Promise((resolve, reject) => {
    const schedule = env.setTimeout?.bind(env) || setTimeout;
    const cancel = env.clearTimeout?.bind(env) || clearTimeout;
    const timeout = schedule(() => finish(new Error("service_worker_activation_timeout")), ACTIVATION_TIMEOUT_MS);

    function cleanup() {
      cancel(timeout);
      worker.removeEventListener?.("statechange", check);
      serviceWorker.removeEventListener?.("controllerchange", check);
    }

    function finish(error) {
      cleanup();
      if (error) reject(error);
      else resolve(registration);
    }

    function check() {
      if (registration.active || worker.state === "activated") finish();
      else if (worker.state === "redundant") finish(new Error("service_worker_installation_failed"));
    }

    worker.addEventListener?.("statechange", check);
    serviceWorker.addEventListener?.("controllerchange", check);
    check();
  });
}

export function registerServiceWorker(env = globalThis) {
  const serviceWorker = env.navigator?.serviceWorker;
  if (!env.isSecureContext || !serviceWorker) return Promise.reject(new Error("service_worker_unavailable"));

  let pending = registrations.get(serviceWorker);
  if (!pending) {
    pending = Promise.resolve(serviceWorker.register("/sw.js", {scope: "/", updateViaCache: "none"}))
      .then((registration) => waitForActivation(env, serviceWorker, registration))
      .catch((error) => {
        registrations.delete(serviceWorker);
        throw error;
      });
    registrations.set(serviceWorker, pending);
  }
  return pending;
}
