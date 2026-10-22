/**
 * ChatScroll hook — auto-scroll & scroll retention for the chat panel.
 *
 * Behavior:
 * - On mount: scroll to bottom, mark as "pinned".
 * - On user scroll: track whether user is within threshold of bottom.
 * - On a user-driven top reach: request one older page and retain the viewport.
 * - After DOM updates (LiveView morph / stream insert / innerHTML changes):
 *   if pinned → auto-scroll to bottom; if not pinned → preserve position.
 * - LiveView can push "user-message-sent" event to force-scroll and re-pin.
 *
 * Content growth must not unpin. A growing transcript fires `scroll` before
 * we can set scrollTop, which used to flip pinned=false and freeze the pane.
 */

const SCROLL_THRESHOLD_PX = 64;
const LOAD_OLDER_THRESHOLD_PX = 32;

export const ChatScroll = {
  mounted() {
    this.pinned = true;
    this._programmatic = false;
    this._loadingOlder = false;
    this._olderAnchor = null;
    this._touching = false;
    this._pointing = false;
    this._focusEntryId = this.focusEntryId();
    this._requestedFocusEntryId = null;

    requestAnimationFrame(() => {
      if (this._focusEntryId) this.focusEntry();
      else this.scrollToBottom();
    });

    this.onUserIntent = (event) => {
      this._userIntent = true;
      if (event?.type === "touchstart") this._touching = true;
      if (event?.type === "pointerdown") this._pointing = true;
      if (event?.type === "wheel" && event.deltaY < 0) this.maybeLoadOlder();
    };

    this.onUserIntentEnd = (event) => {
      if (event?.type.startsWith("touch")) this._touching = false;
      if (event?.type.startsWith("pointer")) this._pointing = false;
    };

    this.onScroll = () => {
      if (this._programmatic) return;
      const el = this.el;
      if (!el) return;
      const distFromBottom = el.scrollHeight - el.scrollTop - el.clientHeight;
      const nearBottom = distFromBottom <= SCROLL_THRESHOLD_PX;
      if (this._userIntent) {
        this.pinned = nearBottom;
        if (nearBottom && !this._touching && !this._pointing) this._userIntent = false;
        else this.maybeLoadOlder();
      }
    };

    this.el.addEventListener("scroll", this.onScroll, { passive: true });
    this.el.addEventListener("wheel", this.onUserIntent, { passive: true });
    this.el.addEventListener("touchstart", this.onUserIntent, { passive: true });
    this.el.addEventListener("touchend", this.onUserIntentEnd, { passive: true });
    this.el.addEventListener("touchcancel", this.onUserIntentEnd, { passive: true });
    this.el.addEventListener("pointerdown", this.onUserIntent, { passive: true });
    this.el.addEventListener("pointerup", this.onUserIntentEnd, { passive: true });
    this.el.addEventListener("pointercancel", this.onUserIntentEnd, { passive: true });

    this.observer = new MutationObserver(() => {
      this.maybeScrollToBottom();
    });

    this.observer.observe(this.el, {
      childList: true,
      subtree: true,
      characterData: true,
    });

    this.handleEvent("user-message-sent", () => {
      this.pinned = true;
      this._userIntent = false;
      this.scrollToBottom();
    });

    this.handleEvent("scroll_chat_to_bottom", () => {
      this.pinned = true;
      this._userIntent = false;
      this.scrollToBottom();
    });

    this.handleEvent("set-conversation-entry-hash", ({ id }) => {
      if (!id || !globalThis.history?.replaceState) return;
      const url = new URL(globalThis.location.href);
      url.hash = encodeURIComponent(id);
      globalThis.history.replaceState(globalThis.history.state, "", url);
    });

    this.handleEvent("focus-conversation-entry", ({ id }) => {
      if (!id) return;
      this._focusEntryId = id;
      this._requestedFocusEntryId = id;
      this.pinned = false;
      this._userIntent = true;
      requestAnimationFrame(() => this.focusEntry());
    });

    this.onUnpin = () => {
      this.pinned = false;
      this._userIntent = true;
    };
    this.el.addEventListener("handbean:unpin-chat-scroll", this.onUnpin);
  },

  updated() {
    this.restoreOlderAnchor();
    if (this._focusEntryId) this.focusEntry();
    else this.maybeScrollToBottom();
  },

  destroyed() {
    if (this.observer) {
      this.observer.disconnect();
      this.observer = null;
    }
    if (this.el) {
      this.el.removeEventListener("scroll", this.onScroll);
      this.el.removeEventListener("wheel", this.onUserIntent);
      this.el.removeEventListener("touchstart", this.onUserIntent);
      this.el.removeEventListener("touchend", this.onUserIntentEnd);
      this.el.removeEventListener("touchcancel", this.onUserIntentEnd);
      this.el.removeEventListener("pointerdown", this.onUserIntent);
      this.el.removeEventListener("pointerup", this.onUserIntentEnd);
      this.el.removeEventListener("pointercancel", this.onUserIntentEnd);
      this.el.removeEventListener("handbean:unpin-chat-scroll", this.onUnpin);
    }
  },

  historyCursor() {
    return this.el?.dataset.historyBefore || "";
  },

  focusEntryId() {
    const hash = globalThis.location?.hash || "";
    if (hash.length <= 1) return null;

    try {
      return decodeURIComponent(hash.slice(1));
    } catch (_error) {
      return null;
    }
  },

  focusEntry() {
    const id = this._focusEntryId;
    const target = id ? globalThis.document?.getElementById?.(id) : null;

    if (target && this.el?.contains?.(target)) {
      this.pinned = false;
      target.scrollIntoView?.({ behavior: "smooth", block: "center" });
      this._focusEntryId = null;
      this._loadingOlder = false;
      return;
    }

    if (id && this._requestedFocusEntryId !== id) {
      this._requestedFocusEntryId = id;
      this.pushEvent("load_history_around", { entry_id: id });
    }
  },

  maybeLoadOlder() {
    const el = this.el;
    if (!el || this._loadingOlder || !this._userIntent) return;
    if (el.dataset.historyHasMore !== "true" || el.scrollTop > LOAD_OLDER_THRESHOLD_PX) return;

    this.pinned = false;
    this._loadingOlder = true;
    this._olderAnchor = {
      conversationId: el.dataset.conversationId || "",
      cursor: this.historyCursor(),
      scrollHeight: el.scrollHeight,
      scrollTop: el.scrollTop,
    };

    this.pushEvent("load_older_history", {}, () => {
      requestAnimationFrame(() => {
        requestAnimationFrame(() => {
          if (this._loadingOlder && this.historyCursor() === this._olderAnchor?.cursor) {
            this.finishOlderLoad();
          }
        });
      });
    });
  },

  restoreOlderAnchor() {
    const el = this.el;
    const anchor = this._olderAnchor;
    if (!el || !anchor) return;

    if ((el.dataset.conversationId || "") !== anchor.conversationId) {
      this.finishOlderLoad();
      return;
    }

    if (this.historyCursor() === anchor.cursor) return;

    const addedHeight = Math.max(0, el.scrollHeight - anchor.scrollHeight);
    this._programmatic = true;
    el.scrollTop = anchor.scrollTop + addedHeight;
    requestAnimationFrame(() => {
      this._programmatic = false;
    });
    this.finishOlderLoad();
  },

  finishOlderLoad() {
    this._loadingOlder = false;
    this._olderAnchor = null;
  },

  maybeScrollToBottom() {
    if (!this.pinned) return;
    this.scrollToBottom();
  },

  scrollToBottom() {
    const el = this.el;
    if (!el) return;
    this._programmatic = true;
    const apply = () => {
      el.scrollTop = el.scrollHeight;
    };
    apply();
    requestAnimationFrame(() => {
      apply();
      requestAnimationFrame(() => {
        apply();
        this._programmatic = false;
      });
    });
  },
};
