export function renderPushNotifications(element, state) {
  element.setAttribute("aria-busy", String(state.busy));
  const message = element.querySelector("[data-push-status]");
  const key = state.busy ? "busy" : state.status;
  message.textContent = element.querySelector(`[data-push-message="${key}"]`)?.textContent || "";
  const error = element.querySelector("[data-push-error]");
  error.hidden = !state.error;
  const errorKey = ["subscription_conflict", "subscription_limit", "subscription_expired", "rollback_failed"].includes(state.error)
    ? state.error : "failed";
  error.textContent = element.querySelector(`[data-push-message="${errorKey}"]`)?.textContent || "";
  const enable = element.querySelector('[data-push-action="enable"]');
  enable.hidden = state.subscribed && state.status !== "renewal";
  enable.disabled = state.busy || !state.configured ||
    ["denied", "insecure", "install", "unsupported"].includes(state.status);
  const disable = element.querySelector('[data-push-action="disable"]');
  disable.hidden = !state.subscribed;
  disable.disabled = state.busy;
  const test = element.querySelector('[data-push-action="test"]');
  test.hidden = !state.subscribed;
  test.disabled = state.busy || !state.configured || !["enabled", "sent"].includes(state.status);
  const retry = element.querySelector('[data-push-action="reconcile"]');
  retry.hidden = !state.error;
  retry.disabled = state.busy;
}
