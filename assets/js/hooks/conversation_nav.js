/**
 * ConversationNav hook — user-turn navigator + scroll-to-bottom cluster.
 *
 * Lives in the chat pane (above the composer). The hamburger opens a
 * popover of user messages; the down arrow reuses ChatScroll's pin/scroll.
 * Open state is client-only and reapplied after LiveView remorphs.
 */

const NEAR_TOP_PX = 96;
const NEAR_BOTTOM_PX = 64;

function messagesEl() {
  return document.getElementById("ai-messages");
}

function unpinChatScroll(scroller) {
  if (!scroller) return;
  scroller.dispatchEvent(new CustomEvent("handbean:unpin-chat-scroll"));
}

export const ConversationNav = {
  mounted() {
    this._open = false;
    this._onDocPointer = (event) => {
      if (!this._open) return;
      if (this.el.contains(event.target)) return;
      this.setOpen(false);
    };
    this._onKeydown = (event) => {
      if (event.key === "Escape" && this._open) this.setOpen(false);
    };
    this._onMessagesScroll = () => this.syncFromScroll();

    this.el.addEventListener("click", (event) => this.onClick(event));
    document.addEventListener("pointerdown", this._onDocPointer, true);
    document.addEventListener("keydown", this._onKeydown);

    this.bindScroller();
    this.applyOpenState();
    this.syncFromScroll();
  },

  updated() {
    this.bindScroller();
    this.applyOpenState();
    this.syncFromScroll();
  },

  destroyed() {
    document.removeEventListener("pointerdown", this._onDocPointer, true);
    document.removeEventListener("keydown", this._onKeydown);
    this.unbindScroller();
  },

  bindScroller() {
    const next = messagesEl();
    if (this._scroller === next) return;
    this.unbindScroller();
    this._scroller = next;
    if (this._scroller) {
      this._scroller.addEventListener("scroll", this._onMessagesScroll, { passive: true });
    }
  },

  unbindScroller() {
    if (this._scroller) {
      this._scroller.removeEventListener("scroll", this._onMessagesScroll);
      this._scroller = null;
    }
  },

  onClick(event) {
    const toggle = event.target.closest("[data-conversation-nav-toggle]");
    if (toggle && this.el.contains(toggle)) {
      event.preventDefault();
      this.setOpen(!this._open);
      return;
    }

    const item = event.target.closest("[data-target-id]");
    if (item && this.el.contains(item)) {
      event.preventDefault();
      this.jumpTo(item.getAttribute("data-target-id"));
    }
  },

  setOpen(open) {
    this._open = Boolean(open);
    this.applyOpenState();
    if (this._open) this.syncFromScroll();
  },

  applyOpenState() {
    this.el.classList.toggle("is-open", this._open);
    const toggle = this.el.querySelector("[data-conversation-nav-toggle]");
    if (toggle) toggle.setAttribute("aria-expanded", this._open ? "true" : "false");
    const panel = this.el.querySelector("[data-conversation-nav-panel]");
    if (panel) panel.hidden = !this._open;
  },

  jumpTo(id) {
    if (!id) return;
    const scroller = messagesEl();
    const target = document.getElementById(id);
    if (!scroller || !target) return;

    unpinChatScroll(scroller);
    target.scrollIntoView({ behavior: "smooth", block: "start" });
    this.setOpen(false);
    this.markCurrent(id);
  },

  syncFromScroll() {
    const scroller = messagesEl();
    const items = this.navItems();
    if (!scroller) {
      this.syncBottomButton(false);
      return;
    }

    const distFromBottom = scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight;
    const awayFromBottom = distFromBottom > NEAR_BOTTOM_PX;
    this.syncBottomButton(awayFromBottom);

    if (items.length === 0) return;

    const currentId = this.currentUserMessageId(scroller, items);
    if (currentId) this.markCurrent(currentId);
  },

  syncBottomButton(awayFromBottom) {
    this.el.classList.toggle("is-away-from-bottom", awayFromBottom);
    const bottom = this.el.querySelector("[data-conversation-nav-bottom]");
    if (!bottom) return;
    bottom.setAttribute("aria-hidden", awayFromBottom ? "false" : "true");
    bottom.tabIndex = awayFromBottom ? 0 : -1;
  },

  currentUserMessageId(scroller, items) {
    const top = scroller.getBoundingClientRect().top + NEAR_TOP_PX;
    let current = items[0];

    for (const item of items) {
      const node = document.getElementById(item.id);
      if (!node) continue;
      if (node.getBoundingClientRect().top <= top) current = item;
    }

    return current.id;
  },

  navItems() {
    return Array.from(this.el.querySelectorAll("[data-target-id]")).map((el) => ({
      id: el.getAttribute("data-target-id"),
      index: el.getAttribute("data-index"),
      el,
    }));
  },

  markCurrent(id) {
    const items = this.navItems();
    let current = null;

    for (const item of items) {
      const isCurrent = item.id === id;
      item.el.classList.toggle("is-current", isCurrent);
      item.el.setAttribute("aria-current", isCurrent ? "true" : "false");
      if (isCurrent) current = item;
    }

    const counter = this.el.querySelector("[data-conversation-nav-counter]");
    if (counter && current) {
      counter.textContent = `${current.index}/${items.length}`;
    }
  },
};
