/**
 * Opens the conversation actions menu on right-click (and long-press
 * contextmenu) and places that menu at the pointer.
 *
 * The menu itself stays server-rendered. This hook only suppresses the
 * browser menu and positions the panel after LiveView opens it.
 */
export const ConversationContextMenu = {
  mounted() {
    this._point = null;
    this.onContextMenu = (event) => {
      const row = event.target.closest("[data-conversation-id]");
      if (!row || !this.el.contains(row)) return;
      if (event.target.closest(".conversation-menu-panel")) return;

      event.preventDefault();
      const id = row.dataset.conversationId;
      if (!id) return;

      this._point = { id, x: event.clientX, y: event.clientY };
      this.pushEvent("open_conversation_context_menu", { id });
      this.position();
    };
    this.onClick = (event) => {
      if (event.target.closest("[data-conversation-menu-toggle]")) this._point = null;
    };

    this.el.addEventListener("contextmenu", this.onContextMenu);
    this.el.addEventListener("click", this.onClick);
  },

  updated() {
    this.position();
  },

  destroyed() {
    this.el.removeEventListener("contextmenu", this.onContextMenu);
    this.el.removeEventListener("click", this.onClick);
  },

  position() {
    if (!this._point) return;
    const panel = this.el.querySelector(`#conversation-menu-panel-${CSS.escape(this._point.id)}`);
    if (!panel) return;

    panel.classList.add("is-context");
    const pad = 8;
    const width = panel.offsetWidth || 160;
    const height = panel.offsetHeight || 140;
    const x = Math.min(Math.max(pad, this._point.x), window.innerWidth - width - pad);
    const y = Math.min(Math.max(pad, this._point.y), window.innerHeight - height - pad);
    panel.style.left = `${x}px`;
    panel.style.top = `${y}px`;
  }
};

export default ConversationContextMenu;
