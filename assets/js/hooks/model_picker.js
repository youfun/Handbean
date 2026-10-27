const OPEN_EVENT = "handbean:model-picker-open";

function normalize(value) {
  return String(value || "").trim().toLocaleLowerCase();
}

function applyServerValue(select) {
  const serverValue = select.getAttribute("value");
  if (serverValue == null) return;
  if (select.value === serverValue) return;
  if ([...select.options].some((option) => option.value === serverValue)) {
    select.value = serverValue;
  }
}

export const BoundSelect = {
  mounted() {
    this.sync();
  },

  updated() {
    this.sync();
  },

  sync() {
    const value = this.el.getAttribute("data-value");
    if (value == null) return;
    if (this.el.value !== value) this.el.value = value;
  },
};

export function optionMatches(option, query) {
  return normalize(option?.dataset?.search).includes(normalize(query));
}

export const ModelPicker = {
  mounted() {
    this.open = false;
    this.el.dataset.enhanced = "true";
    this.enhanceNativeSelect();

    this.onClick = (event) => {
      const trigger = event.target.closest("[data-model-picker-trigger]");
      if (trigger && this.el.contains(trigger)) {
        event.preventDefault();
        this.setOpen(true);
        return;
      }

      const close = event.target.closest("[data-model-picker-close]");
      if (close && this.el.contains(close)) {
        event.preventDefault();
        this.setOpen(false);
        return;
      }

      const option = event.target.closest("[data-model-picker-option]");
      if (option && this.el.contains(option) && !option.disabled) {
        event.preventDefault();
        this.select(option.dataset.value || "");
      }
    };

    this.onInput = (event) => {
      if (event.target.matches("[data-model-picker-search]")) {
        this.filter(event.target.value);
      }
    };

    this.onKeydown = (event) => {
      if (!this.open) return;

      if (event.key === "Escape") {
        event.preventDefault();
        this.setOpen(false);
        return;
      }

      if (event.key === "Tab") this.keepFocusInside(event);
    };

    this.onOtherPickerOpen = (event) => {
      if (event.detail !== this.el.id) this.setOpen(false, { restoreFocus: false });
    };

    this.onViewportChange = () => {
      if (this.open) this.positionSettingsPanel();
    };

    window.addEventListener("resize", this.onViewportChange);
    window.addEventListener("scroll", this.onViewportChange, true);
    this.el.addEventListener("click", this.onClick);
    this.el.addEventListener("input", this.onInput);
    document.addEventListener("keydown", this.onKeydown);
    document.addEventListener(OPEN_EVENT, this.onOtherPickerOpen);
    this.syncSelection();
  },

  updated() {
    this.el.dataset.enhanced = "true";
    this.enhanceNativeSelect();
    const select = this.nativeSelect();
    if (select) applyServerValue(select);
    this.syncSelection();

    if (this.open) {
      this.panel().hidden = false;
      this.backdrop().hidden = false;
      this.trigger().setAttribute("aria-expanded", "true");
      this.filter(this.search()?.value || "");
      this.positionSettingsPanel();
    }
  },

  destroyed() {
    this.el.removeEventListener("click", this.onClick);
    this.el.removeEventListener("input", this.onInput);
    document.removeEventListener("keydown", this.onKeydown);
    document.removeEventListener(OPEN_EVENT, this.onOtherPickerOpen);
    window.removeEventListener("resize", this.onViewportChange);
    window.removeEventListener("scroll", this.onViewportChange, true);
    document.documentElement.classList.remove("model-picker-is-open");
  },

  enhanceNativeSelect() {
    const select = this.nativeSelect();
    if (!select) return;

    select.setAttribute("aria-hidden", "true");
    select.tabIndex = -1;
  },

  nativeSelect() {
    return this.el.querySelector(".model-picker-native");
  },

  trigger() {
    return this.el.querySelector("[data-model-picker-trigger]");
  },

  panel() {
    return this.el.querySelector("[data-model-picker-panel]");
  },

  backdrop() {
    return this.el.querySelector(".model-picker-backdrop");
  },

  search() {
    return this.el.querySelector("[data-model-picker-search]");
  },

  options() {
    return [...this.el.querySelectorAll("[data-model-picker-option]")];
  },

  setOpen(open, { restoreFocus = true } = {}) {
    const next = Boolean(open);
    const panel = this.panel();
    const backdrop = this.backdrop();
    const trigger = this.trigger();
    if (!panel || !backdrop || !trigger) return;

    this.open = next;
    panel.hidden = !next;
    backdrop.hidden = !next;
    trigger.setAttribute("aria-expanded", String(next));
    document.documentElement.classList.toggle("model-picker-is-open", next);

    if (next) {
      this.positionSettingsPanel();
      document.dispatchEvent(new CustomEvent(OPEN_EVENT, { detail: this.el.id }));
      const search = this.search();
      if (search) {
        search.value = "";
        this.filter("");
        requestAnimationFrame(() => search.focus());
      }
    } else if (restoreFocus && document.activeElement && this.el.contains(document.activeElement)) {
      trigger.focus();
    }
  },

  positionSettingsPanel() {
    if (!this.el.closest(".settings-card-has-model-picker")) return;

    const panel = this.panel();
    panel.style.removeProperty("top");
    panel.style.removeProperty("bottom");
    panel.style.removeProperty("max-height");
    if (window.innerWidth <= 768) return;

    const trigger = this.trigger().getBoundingClientRect();
    const above = Math.max(0, trigger.top - 14);
    const below = Math.max(0, window.innerHeight - trigger.bottom - 14);
    const openAbove = panel.getBoundingClientRect().height > below && above > below;
    if (openAbove) {
      panel.style.top = "auto";
      panel.style.bottom = "calc(100% + 6px)";
    }
    panel.style.maxHeight = `min(520px, 70vh, ${openAbove ? above : below}px)`;
  },

  select(value) {
    const select = this.nativeSelect();
    if (!select) return;

    select.value = value;
    this.syncSelection();
    this.setOpen(false);
    select.dispatchEvent(new Event("change", { bubbles: true }));
  },

  syncSelection() {
    const select = this.nativeSelect();
    const triggerLabel = this.el.querySelector(".model-picker-trigger-label");
    if (!select || !triggerLabel) return;

    const selected = select.options[select.selectedIndex];
    if (selected) triggerLabel.textContent = selected.textContent.trim();

    for (const option of this.options()) {
      const current = option.dataset.value === select.value;
      option.classList.toggle("is-selected", current);
      if (current) option.setAttribute("aria-current", "true");
      else option.removeAttribute("aria-current");
    }
  },

  filter(query) {
    let visible = 0;

    for (const option of this.options()) {
      const matches = optionMatches(option, query);
      option.hidden = !matches;
      if (matches) visible += 1;
    }

    for (const group of this.el.querySelectorAll("[data-model-picker-group]")) {
      group.hidden = ![...group.querySelectorAll("[data-model-picker-option]")].some(
        (option) => !option.hidden
      );
    }

    const empty = this.el.querySelector("[data-model-picker-empty]");
    if (empty) empty.hidden = visible !== 0;
  },

  keepFocusInside(event) {
    const focusable = [...this.panel().querySelectorAll("button:not([hidden]):not(:disabled), input:not([hidden])")]
      .filter((element) => !element.closest("[hidden]"));
    if (focusable.length === 0) return;

    const first = focusable[0];
    const last = focusable[focusable.length - 1];

    if (event.shiftKey && document.activeElement === first) {
      event.preventDefault();
      last.focus();
    } else if (!event.shiftKey && document.activeElement === last) {
      event.preventDefault();
      first.focus();
    }
  }
};
