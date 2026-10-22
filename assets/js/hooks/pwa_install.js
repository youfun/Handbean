import { pwaInstall } from "../pwa_install.js";

export function renderPWAInstall(element, state) {
  element.setAttribute("aria-busy", String(state.busy));
  const message = element.querySelector("[data-pwa-install-status]");
  message.textContent = element.querySelector(`[data-pwa-install-message="${state.status}"]`)?.textContent || "";

  const button = element.querySelector("[data-pwa-install-action]");
  button.hidden = !state.canInstall;
  button.disabled = state.busy;

  const guide = element.querySelector("[data-pwa-ios-guide]");
  guide.hidden = state.status !== "ios";
}

export const PWAInstall = {
  mounted() {
    this.install = pwaInstall();
    this.stopListening = this.install.subscribe((state) => renderPWAInstall(this.el, state));
    this.onInstallClick = (event) => {
      const button = event.target.closest("[data-pwa-install-action]");
      if (!button || !this.el.contains(button) || button.disabled) return;
      void this.install.install();
    };
    this.el.addEventListener("click", this.onInstallClick);
    this.install.start();
  },

  updated() {
    renderPWAInstall(this.el, this.install.state);
  },

  destroyed() {
    this.stopListening?.();
    this.el.removeEventListener("click", this.onInstallClick);
  }
};
