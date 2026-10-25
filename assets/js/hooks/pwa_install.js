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
