/**
 * Shows a fixed card to the right of a sidebar conversation row.
 * The card lives outside the scroll container so overflow cannot clip it.
 *
 * Both cards are server-rendered inside the sidebar subtree, but their open
 * state is client-only. A LiveView patch of that subtree rewrites the server
 * view of the card (hidden, no `is-open`, unfiltered meta rows) and does not
 * call `updated()` on this hook, so the card is restored from the sidebar
 * mutation itself while the pointer is still on the row.
 */
export const ConversationHover = {
  mounted() {
    this.card = this.el.querySelector("#conversation-hover-card");
    this.scroll = this.el.querySelector("#projects-sidebar-scroll");
    this.row = null;
    this.conversationId = null;
    this.hideTimer = null;

    this.workspaceCard = this.el.querySelector("#workspace-hover-card");
    this.workspaceRow = null;
    this.workspaceId = null;

    this.bindCards();
    this.observer = new MutationObserver(() => this.sync());
    this.observe();

    this.onOver = (event) => {
      const row = event.target.closest("[data-conversation-id]");
      if (row && this.el.contains(row) && !event.target.closest(".conversation-hover")) {
        this.hideWorkspace();
        this.show(row);
        return;
      }

      const title = event.target.closest(".workspace-title-row");
      const group = title && title.closest("[data-workspace-id]");
      if (group && this.el.contains(group) && !event.target.closest(".workspace-hover")) {
        this.hide();
        this.showWorkspace(group);
      }
    };
    this.onOut = (event) => {
      const next = event.relatedTarget;
      if (this.row) {
        if (next && (this.row.contains(next) || (this.card && this.card.contains(next)))) return;
        this.scheduleHide();
      }
      if (this.workspaceRow) {
        if (
          next &&
          (this.workspaceRow.contains(next) ||
            (this.workspaceCard && this.workspaceCard.contains(next)))
        ) {
          return;
        }
        this.scheduleHideWorkspace();
      }
    };
    this.onScroll = () => {
      if (this.row) this.place(this.row);
      if (this.workspaceRow) this.placeWorkspace(this.workspaceRow);
    };
    this.onPointerDown = (event) => {
      if (event.target.closest(".workspace-hover, .conversation-hover")) return;
      this.hide();
      this.hideWorkspace();
    };
    this.onClick = (event) => {
      const rename = event.target.closest("[data-workspace-hover-rename]");
      const remove = event.target.closest("[data-workspace-hover-remove]");
      if (!rename && !remove) return;
      const id = this.workspaceId;
      if (!id) return;
      event.preventDefault();
      event.stopPropagation();
      this.pushEvent(rename ? "open_rename_workspace" : "open_remove_workspace", { id });
      this.hideWorkspace();
    };

    this.el.addEventListener("pointerover", this.onOver);
    this.el.addEventListener("pointerout", this.onOut);
    this.el.addEventListener("pointerdown", this.onPointerDown);
    this.el.addEventListener("click", this.onClick);
    if (this.scroll) this.scroll.addEventListener("scroll", this.onScroll, { passive: true });
  },

  updated() {
    this.sync();
  },

  destroyed() {
    this.clearHide();
    this.clearHideWorkspace();
    if (this.observer) {
      this.observer.disconnect();
      this.observer = null;
    }
    this.el.removeEventListener("pointerover", this.onOver);
    this.el.removeEventListener("pointerout", this.onOut);
    this.el.removeEventListener("pointerdown", this.onPointerDown);
    this.el.removeEventListener("click", this.onClick);
    if (this.scroll) this.scroll.removeEventListener("scroll", this.onScroll);
  },

  observe() {
    if (!this.observer) return;
    this.observer.observe(this.el, {
      subtree: true,
      childList: true,
      attributes: true,
      attributeFilter: ["hidden", "class"]
    });
  },

  /**
   * Re-applies client-only card state after a sidebar patch. Writes made here
   * are excluded from the observer so restoring a card cannot feed itself.
   */
  sync() {
    this.card = this.el.querySelector("#conversation-hover-card");
    this.workspaceCard = this.el.querySelector("#workspace-hover-card");
    this.bindCards();
    if (!this.row && !this.workspaceRow) return;

    if (this.observer) this.observer.disconnect();
    try {
      this.restore();
    } finally {
      this.observe();
    }
  },

  bindCards() {
    if (this.card !== this.boundCard) {
      this.unbindCard(this.boundCard, this.cardListeners);
      this.boundCard = this.card;
      this.cardListeners = this.bindCard(
        this.card,
        () => this.clearHide(),
        () => this.scheduleHide()
      );
    }
    if (this.workspaceCard !== this.boundWorkspaceCard) {
      this.unbindCard(this.boundWorkspaceCard, this.workspaceCardListeners);
      this.boundWorkspaceCard = this.workspaceCard;
      this.workspaceCardListeners = this.bindCard(
        this.workspaceCard,
        () => this.clearHideWorkspace(),
        () => this.scheduleHideWorkspace()
      );
    }
  },

  bindCard(card, onEnter, onLeave) {
    if (!card) return null;
    card.addEventListener("pointerenter", onEnter);
    card.addEventListener("pointerleave", onLeave);
    return { enter: onEnter, leave: onLeave };
  },

  unbindCard(card, listeners) {
    if (!card || !listeners) return;
    card.removeEventListener("pointerenter", listeners.enter);
    card.removeEventListener("pointerleave", listeners.leave);
  },

  /**
   * Re-applies an open card after a patch. A pending hide timer means the
   * pointer already left, so that card stays hidden; a hovered row that the
   * patch removed has nothing left to describe.
   */
  restore() {
    if (this.row && !this.hideTimer) {
      const row = this.findConversationRow(this.conversationId);
      if (row) this.show(row);
      else this.hide();
    }
    if (this.workspaceRow && !this.workspaceHideTimer) {
      const group = this.findWorkspaceGroup(this.workspaceId);
      if (group) this.showWorkspace(group);
      else this.hideWorkspace();
    }
  },

  findConversationRow(conversationId) {
    if (!conversationId) return null;
    return (
      Array.from(this.el.querySelectorAll("[data-conversation-id]")).find(
        (row) => row.dataset.conversationId === conversationId
      ) || null
    );
  },

  findWorkspaceGroup(workspaceId) {
    if (!workspaceId) return null;
    return (
      Array.from(this.el.querySelectorAll(".workspace-group[data-workspace-id]")).find(
        (group) => group.dataset.workspaceId === workspaceId
      ) || null
    );
  },

  show(row) {
    if (!this.card) return;
    if (row.closest(".archived")) return this.hide();
    this.clearHide();
    this.row = row;
    this.conversationId = row.dataset.conversationId || null;

    const title = this.card.querySelector("[data-hover-title]");
    const age = this.card.querySelector("[data-hover-age]");
    const copy = this.card.querySelector("[data-copy]");
    const text = row.dataset.conversationTitle || "";
    if (title) title.textContent = text;
    if (copy) copy.dataset.copy = text;
    if (age) {
      const value = row.dataset.conversationAge || "";
      age.textContent = value;
      age.hidden = value === "";
    }

    const conversationId = row.dataset.conversationId || "";
    this.card.querySelectorAll("[data-hover-context]").forEach((node) => {
      node.hidden = node.dataset.hoverContext !== conversationId;
    });

    this.card.hidden = false;
    this.card.classList.add("is-open");
    this.place(row);
  },

  showWorkspace(group) {
    if (!this.workspaceCard) return;
    this.clearHideWorkspace();
    this.workspaceRow = group;
    this.workspaceId = group.dataset.workspaceId || "";
    const name = this.workspaceCard.querySelector("[data-workspace-hover-name]");
    const path = this.workspaceCard.querySelector("[data-workspace-hover-path]");
    const repo = this.workspaceCard.querySelector("[data-workspace-hover-repo]");
    const repoName = this.workspaceCard.querySelector("[data-workspace-hover-repo-name]");
    const rename = this.workspaceCard.querySelector("[data-workspace-hover-rename]");
    if (name) name.textContent = group.dataset.workspaceName || "";
    if (path) path.textContent = group.dataset.workspacePath || "";
    const repository = group.dataset.workspaceRepo || "";
    if (repoName) repoName.textContent = repository;
    if (repo) repo.hidden = repository === "";
    if (rename) rename.dataset.workspaceId = this.workspaceId;
    const remove = this.workspaceCard.querySelector("[data-workspace-hover-remove]");
    if (remove) remove.hidden = group.dataset.workspaceDefault === "true";
    this.workspaceCard.hidden = false;
    this.workspaceCard.classList.add("is-open");
    this.placeWorkspace(group);
  },

  placeWorkspace(group) {
    const row = group.querySelector(".workspace-title-row") || group;
    const rect = row.getBoundingClientRect();
    const width = this.workspaceCard.offsetWidth || 240;
    const height = this.workspaceCard.offsetHeight || 64;
    const pad = 8;
    let left = rect.right + 10;
    if (left + width > window.innerWidth - pad) left = Math.max(pad, rect.left - width - 10);
    let top = rect.top - 4;
    if (top + height > window.innerHeight - pad) {
      top = Math.max(pad, window.innerHeight - height - pad);
    }
    this.workspaceCard.style.left = `${left}px`;
    this.workspaceCard.style.top = `${top}px`;
  },

  scheduleHideWorkspace() {
    this.clearHideWorkspace();
    this.workspaceHideTimer = window.setTimeout(() => this.hideWorkspace(), 80);
  },

  clearHideWorkspace() {
    if (this.workspaceHideTimer) window.clearTimeout(this.workspaceHideTimer);
    this.workspaceHideTimer = null;
  },

  hideWorkspace() {
    this.workspaceRow = null;
    this.workspaceId = null;
    if (!this.workspaceCard) return;
    this.workspaceCard.classList.remove("is-open");
    this.workspaceCard.hidden = true;
  },

  place(row) {
    const rect = row.getBoundingClientRect();
    const width = this.card.offsetWidth || 220;
    const height = this.card.offsetHeight || 72;
    const pad = 8;
    let left = rect.right + 10;
    if (left + width > window.innerWidth - pad) left = Math.max(pad, rect.left - width - 10);
    let top = rect.top - 4;
    if (top + height > window.innerHeight - pad) top = Math.max(pad, window.innerHeight - height - pad);
    this.card.style.left = `${left}px`;
    this.card.style.top = `${top}px`;
  },

  scheduleHide() {
    this.clearHide();
    this.hideTimer = window.setTimeout(() => this.hide(), 80);
  },

  clearHide() {
    if (this.hideTimer) window.clearTimeout(this.hideTimer);
    this.hideTimer = null;
  },

  hide() {
    this.row = null;
    this.conversationId = null;
    if (!this.card) return;
    this.card.classList.remove("is-open");
    this.card.hidden = true;
  }
};

export default ConversationHover;
