import { webPush } from "../web_push.js";

export const PushNotifications = {
  mounted() {
    this.push = webPush();
    this.push.setLocale(this.el.dataset.locale);
    this.stopListening = this.push.subscribe((state) => this.renderPush(state));
    this.onPushClick = (event) => {
      const button = event.target.closest("[data-push-action]");
      if (!button || !this.el.contains(button) || button.disabled) return;
      const action = button.dataset.pushAction;
      if (["enable", "disable", "test", "reconcile"].includes(action)) {
        // Keep enable() in the click stack to preserve notification permission's user gesture.
        void this.push[action]();
      }
    };
    this.el.addEventListener("click", this.onPushClick);
    void this.push.reconcile();
  },

  updated() {
    const changed = this.el.dataset.locale !== this.pushLocale;
    this.push.setLocale(this.el.dataset.locale);
    this.renderPush(this.push.state);
    if (changed) void this.push.reconcile();
  },

  renderPush(state) {
    this.pushLocale = this.el.dataset.locale;
    this.el.setAttribute("aria-busy", String(state.busy));
    const message = this.el.querySelector("[data-push-status]");
    const key = state.busy ? "busy" : state.status;
    message.textContent = this.el.querySelector(`[data-push-message="${key}"]`)?.textContent || "";
    const error = this.el.querySelector("[data-push-error]");
    error.hidden = !state.error;
    const errorKey = ["subscription_conflict", "subscription_limit", "subscription_expired", "rollback_failed"].includes(state.error)
      ? state.error : "failed";
    error.textContent = this.el.querySelector(`[data-push-message="${errorKey}"]`)?.textContent || "";
    const enable = this.el.querySelector('[data-push-action="enable"]');
    enable.hidden = state.subscribed && state.status !== "renewal";
    enable.disabled = state.busy || !state.configured ||
      ["denied", "insecure", "install", "unsupported"].includes(state.status);
    const disable = this.el.querySelector('[data-push-action="disable"]');
    disable.hidden = !state.subscribed;
    disable.disabled = state.busy;
    const test = this.el.querySelector('[data-push-action="test"]');
    test.hidden = !state.subscribed;
    test.disabled = state.busy || !state.configured || !["enabled", "sent"].includes(state.status);
    const retry = this.el.querySelector('[data-push-action="reconcile"]');
    retry.hidden = !state.error;
    retry.disabled = state.busy;
  },

  destroyed() {
    this.stopListening?.();
    this.el.removeEventListener("click", this.onPushClick);
  }
};
