function optionRows(root) {
  return Array.from(root.querySelectorAll("[data-search-option]"));
}

function focusableRows(root) {
  return Array.from(
    root.querySelectorAll(
      'button:not([disabled]), input:not([disabled]), select:not([disabled]), [tabindex]:not([tabindex="-1"])',
    ),
  ).filter((node) => !node.hidden && node.getAttribute("aria-hidden") !== "true");
}

function compositionActive(event) {
  return event.isComposing === true || event.keyCode === 229;
}

function searchTrigger() {
  const mobile = document.getElementById("mobile-open-conversation-search");
  if (mobile && mobile.offsetParent !== null) return mobile;
  return document.getElementById("open-conversation-search") || mobile;
}

export function safeHighlight(node) {
  const text = node.textContent || "";
  const query = node.dataset.highlightQuery || "";
  node.replaceChildren();

  if (!query) {
    node.textContent = text;
    return;
  }

  const folded = text.toLocaleLowerCase();
  const needle = query.toLocaleLowerCase();
  let cursor = 0;
  let index = folded.indexOf(needle);

  while (index !== -1) {
    node.append(document.createTextNode(text.slice(cursor, index)));
    const mark = document.createElement("mark");
    mark.textContent = text.slice(index, index + query.length);
    node.append(mark);
    cursor = index + query.length;
    index = folded.indexOf(needle, cursor);
  }

  node.append(document.createTextNode(text.slice(cursor)));
}

export const ConversationSearch = {
  mounted() {
    this.activeIndex = 0;
    this.returnFocus = null;

    this.onKeydown = (event) => {
      if (this.el.hidden || compositionActive(event)) return;

      if (event.key === "Tab") {
        const rows = focusableRows(this.el);
        if (rows.length === 0) {
          event.preventDefault();
          return;
        }

        const first = rows[0];
        const last = rows[rows.length - 1];
        if (event.shiftKey && event.target === first) {
          event.preventDefault();
          last.focus();
        } else if (!event.shiftKey && event.target === last) {
          event.preventDefault();
          first.focus();
        }
        return;
      }

      if (event.key === "Escape") {
        event.preventDefault();
        this.pushEvent("close_conversation_search", {});
        return;
      }

      const input = event.target?.id === "conversation-search-input";
      const option = event.target?.closest?.("[data-search-option]");
      if ((event.key === "ArrowDown" || event.key === "ArrowUp") && (input || option)) {
        event.preventDefault();
        const delta = event.key === "ArrowDown" ? 1 : -1;
        this.select(this.activeIndex + delta, true);
        if (option) optionRows(this.el)[this.activeIndex]?.focus();
        return;
      }

      if (event.key === "Enter" && input) {
        event.preventDefault();
        if (event.target.value !== (this.el.dataset.resultsQuery || "")) return;

        const row = optionRows(this.el)[this.activeIndex];
        row?.click();
      }
    };

    this.onClick = (event) => {
      const continuation = event.target.closest("[data-search-continuation]");

      if (continuation && this.el.contains(continuation)) {
        document.getElementById("conversation-search-input")?.focus();
      }

      const row = event.target.closest("[data-search-option]");
      if (!row || !this.el.contains(row)) return;
      const index = optionRows(this.el).indexOf(row);
      if (index >= 0) this.select(index, false);
    };

    this.el.addEventListener("keydown", this.onKeydown);
    this.el.addEventListener("click", this.onClick);

    this.handleEvent("focus-conversation-search", () => {
      this.rememberReturnFocus();
      this.focusInput();
    });

    this.handleEvent("restore-conversation-search-focus", () => {
      this.restoreTriggerFocus();
    });

    this.decorate();
  },

  beforeUpdate() {
    this.hadDialogFocusBeforeUpdate = this.el.contains(document.activeElement);
  },

  updated() {
    this.decorate();

    if (
      !this.el.hidden &&
      this.hadDialogFocusBeforeUpdate &&
      !this.el.contains(document.activeElement)
    ) {
      document.getElementById("conversation-search-input")?.focus();
    }

    this.hadDialogFocusBeforeUpdate = false;
  },

  destroyed() {
    this.el.removeEventListener("keydown", this.onKeydown);
    this.el.removeEventListener("click", this.onClick);
  },

  rememberReturnFocus() {
    const active = document.activeElement;
    const activeIsTrigger =
      active?.id === "open-conversation-search" ||
      active?.id === "mobile-open-conversation-search";
    const rememberedIsUsable =
      this.returnFocus?.isConnected &&
      this.returnFocus !== document.body &&
      this.returnFocus !== document.documentElement;

    if (activeIsTrigger) {
      this.returnFocus = active;
    } else if (!rememberedIsUsable) {
      this.returnFocus = searchTrigger();
    }
  },

  focusInput() {
    requestAnimationFrame(() => {
      this.decorate();
      document.getElementById("conversation-search-input")?.focus();
    });
  },

  restoreTriggerFocus() {
    requestAnimationFrame(() => {
      const remembered = this.returnFocus;
      const target =
        remembered?.isConnected &&
        remembered !== document.body &&
        remembered !== document.documentElement
          ? remembered
          : searchTrigger();
      target?.focus?.();
    });
  },

  decorate() {
    this.el.querySelectorAll("[data-safe-highlight]").forEach(safeHighlight);
    this.select(this.activeIndex, false);
  },

  select(index, scroll) {
    const rows = optionRows(this.el);
    if (rows.length === 0) {
      this.activeIndex = 0;
      document.getElementById("conversation-search-input")?.removeAttribute("aria-activedescendant");
      return;
    }

    this.activeIndex = Math.max(0, Math.min(index, rows.length - 1));
    rows.forEach((row, rowIndex) => {
      row.setAttribute("aria-selected", rowIndex === this.activeIndex ? "true" : "false");
    });

    const active = rows[this.activeIndex];
    const input = document.getElementById("conversation-search-input");
    if (input && active?.id) input.setAttribute("aria-activedescendant", active.id);
    if (scroll) active?.scrollIntoView?.({ block: "nearest" });
  },
};
