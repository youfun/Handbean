export function createConnectionStatus(element, env = globalThis) {
  let hadInterruption = false;
  let hideTimer;
  let observer;
  let liveViewRoot;

  function render(status) {
    if (!element) return;
    env.clearTimeout(hideTimer);
    const message = element.querySelector(`[data-connection-message="${status}"]`);
    element.querySelector("[data-connection-copy]").textContent = message?.textContent || "";
    element.dataset.state = status;
    element.hidden = status === "connected" && !hadInterruption;
  }

  function connected() {
    if (!hadInterruption) {
      if (element?.dataset.state !== "restored") render("connected");
      return;
    }
    hadInterruption = false;
    render("restored");
    hideTimer = env.setTimeout(() => {
      element.hidden = true;
      element.dataset.state = "connected";
    }, 2_500);
  }

  function disconnected() {
    hadInterruption = true;
    render(env.navigator?.onLine === false ? "offline" : "reconnecting");
  }

  function syncLiveView() {
    if (env.navigator?.onLine === false) offline();
    else if (liveViewRoot?.classList.contains("phx-connected")) connected();
    else if (["phx-error", "phx-client-error", "phx-server-error"]
      .some((name) => liveViewRoot?.classList.contains(name))) disconnected();
  }

  function online() {
    hadInterruption = true;
    if (liveViewRoot?.classList.contains("phx-connected")) connected();
    else render("reconnecting");
  }

  function offline() {
    hadInterruption = true;
    render("offline");
  }

  env.addEventListener?.("online", online);
  env.addEventListener?.("offline", offline);
  if (env.navigator?.onLine === false) offline();

  return {
    bind(root) {
      if (!root || root === liveViewRoot) return;
      observer?.disconnect();
      liveViewRoot = root;
      observer = new env.MutationObserver(syncLiveView);
      observer.observe(root, {attributes: true, attributeFilter: ["class"]});
      syncLiveView();
    },
    destroy() {
      env.clearTimeout(hideTimer);
      observer?.disconnect();
      env.removeEventListener?.("online", online);
      env.removeEventListener?.("offline", offline);
    }
  };
}
