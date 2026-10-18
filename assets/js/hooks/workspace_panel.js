import { copyText } from "./copy_text.js";

/**
 * WorkspacePanel hook — persist right panel state, keep wheel scrolling useful,
 * and own the workspace-tree context menu.
 */

const STORAGE_KEY = "handbean:right_panel_collapsed";
const SCROLL_TOLERANCE = 1;
const LINE_SCROLL_PIXELS = 16;
const FALLBACK_PAGE_HEIGHT = 400;
const MENU_PADDING = 8;
const FALLBACK_MENU_WIDTH = 190;
const FALLBACK_MENU_HEIGHT = 112;

function hasVerticalOverflow(element) {
  return element.scrollHeight > element.clientHeight + SCROLL_TOLERANCE;
}

function isVerticalScrollContainer(element) {
  if (!hasVerticalOverflow(element)) return false;

  const view = element.ownerDocument?.defaultView;
  const styles = view?.getComputedStyle(element);
  const overflowY = styles?.overflowY || styles?.overflow || "";
  return /^(auto|scroll|overlay)$/.test(overflowY);
}

function nestedPreviewCanScroll(target, preview) {
  for (let element = target; element && element !== preview; element = element.parentElement) {
    if (isVerticalScrollContainer(element)) return true;
  }

  return false;
}

function normalizedWheelDelta(event, pageHeight) {
  if (event.deltaMode === 1) return event.deltaY * LINE_SCROLL_PIXELS;
  if (event.deltaMode === 2) return event.deltaY * (pageHeight || FALLBACK_PAGE_HEIGHT);
  return event.deltaY;
}

export function forwardUnscrollablePreviewWheel(root, event) {
  if (
    event.defaultPrevented ||
    event.ctrlKey ||
    event.metaKey ||
    event.altKey ||
    event.shiftKey ||
    event.deltaY === 0 ||
    Math.abs(event.deltaY) <= Math.abs(event.deltaX || 0)
  ) {
    return false;
  }

  const target = event.target?.nodeType === 1 ? event.target : event.target?.parentElement;
  const preview = target?.closest?.("#editor-content");
  if (!preview || !root.contains(preview) || hasVerticalOverflow(preview)) return false;
  if (nestedPreviewCanScroll(target, preview)) return false;

  const tree = root.querySelector(".workspace-tree-pane");
  if (!tree || !hasVerticalOverflow(tree)) return false;

  const before = tree.scrollTop;
  const maximum = Math.max(0, tree.scrollHeight - tree.clientHeight);
  const delta = normalizedWheelDelta(event, tree.clientHeight);
  tree.scrollTop = Math.max(0, Math.min(maximum, before + delta));

  if (tree.scrollTop === before) return false;

  event.preventDefault();
  return true;
}

export function positionWorkspaceTreeMenu(menu, x, y, view) {
  const width = menu.offsetWidth || FALLBACK_MENU_WIDTH;
  const height = menu.offsetHeight || FALLBACK_MENU_HEIGHT;
  const left = Math.min(Math.max(MENU_PADDING, x), view.innerWidth - width - MENU_PADDING);
  const top = Math.min(Math.max(MENU_PADDING, y), view.innerHeight - height - MENU_PADDING);
  menu.style.left = `${Math.max(MENU_PADDING, left)}px`;
  menu.style.top = `${Math.max(MENU_PADDING, top)}px`;
}

export const WorkspacePanel = {
  mounted() {
    const ownerDocument = this.el.ownerDocument;
    const view = ownerDocument.defaultView;
    const stored = view.localStorage.getItem(STORAGE_KEY);
    if (stored === "true") {
      this.pushEvent("set_right_panel_collapsed", { collapsed: true });
    }

    this.handleEvent("persist_collapsed", ({ collapsed }) => {
      view.localStorage.setItem(STORAGE_KEY, collapsed ? "true" : "false");
    });

    this.workspaceMenuTarget = null;
    this.handlePreviewWheel = (event) => forwardUnscrollablePreviewWheel(this.el, event);
    this.handleTreeContextMenu = (event) => this.openWorkspaceTreeMenu(event);
    this.handlePanelClick = (event) => this.handleWorkspaceTreeMenuAction(event);
    this.handleOutsidePointer = (event) => {
      const menu = this.workspaceTreeMenu();
      if (menu && !menu.hidden && !menu.contains(event.target)) this.closeWorkspaceTreeMenu();
    };
    this.handleMenuKeydown = (event) => {
      if (event.key === "Escape") this.closeWorkspaceTreeMenu();
    };
    this.handlePanelScroll = () => this.closeWorkspaceTreeMenu();
    this.handleWindowResize = () => this.closeWorkspaceTreeMenu();

    this.el.addEventListener("wheel", this.handlePreviewWheel, { passive: false });
    this.el.addEventListener("contextmenu", this.handleTreeContextMenu);
    this.el.addEventListener("click", this.handlePanelClick);
    this.el.addEventListener("scroll", this.handlePanelScroll, true);
    ownerDocument.addEventListener("pointerdown", this.handleOutsidePointer);
    ownerDocument.addEventListener("keydown", this.handleMenuKeydown);
    view.addEventListener("resize", this.handleWindowResize);
  },

  destroyed() {
    const ownerDocument = this.el.ownerDocument;
    const view = ownerDocument.defaultView;
    this.el.removeEventListener("wheel", this.handlePreviewWheel);
    this.el.removeEventListener("contextmenu", this.handleTreeContextMenu);
    this.el.removeEventListener("click", this.handlePanelClick);
    this.el.removeEventListener("scroll", this.handlePanelScroll, true);
    ownerDocument.removeEventListener("pointerdown", this.handleOutsidePointer);
    ownerDocument.removeEventListener("keydown", this.handleMenuKeydown);
    view.removeEventListener("resize", this.handleWindowResize);
  },

  workspaceTreeMenu() {
    return this.el.querySelector("#workspace-tree-context-menu");
  },

  openWorkspaceTreeMenu(event) {
    if (event.target.closest("#workspace-tree-context-menu")) return;

    const entry = event.target.closest("[data-workspace-relative-path]");
    if (!entry || !this.el.contains(entry)) return;

    const relativePath = entry.dataset.workspaceRelativePath || "";
    const absolutePath = entry.dataset.workspaceAbsolutePath || "";
    if (!relativePath || !absolutePath) return;

    const menu = this.workspaceTreeMenu();
    if (!menu) return;

    event.preventDefault();
    this.workspaceMenuTarget = { relativePath, absolutePath };
    const reveal = menu.querySelector("[data-workspace-tree-action='reveal-in-file-manager']");
    if (reveal) reveal.hidden = false;
    menu.hidden = false;
    positionWorkspaceTreeMenu(
      menu,
      event.clientX || MENU_PADDING,
      event.clientY || MENU_PADDING,
      this.el.ownerDocument.defaultView,
    );
    menu.querySelector("button:not([hidden])")?.focus({ preventScroll: true });
  },

  handleWorkspaceTreeMenuAction(event) {
    const button = event.target.closest("[data-workspace-tree-action]");
    const target = this.workspaceMenuTarget;
    if (!button || !target) return;

    event.preventDefault();
    const action = button.dataset.workspaceTreeAction;
    if (action === "copy-absolute") {
      void copyText(target.absolutePath, this.el.ownerDocument);
    } else if (action === "copy-relative") {
      void copyText(target.relativePath, this.el.ownerDocument);
    } else if (action === "reveal-in-file-manager") {
      this.pushEvent("reveal_in_file_manager", { path: target.relativePath });
    } else {
      return;
    }

    this.closeWorkspaceTreeMenu();
  },

  closeWorkspaceTreeMenu() {
    const menu = this.workspaceTreeMenu();
    if (menu) {
      menu.hidden = true;
      const reveal = menu.querySelector("[data-workspace-tree-action='reveal-in-file-manager']");
      if (reveal) reveal.hidden = true;
    }
    this.workspaceMenuTarget = null;
  },
};

export default WorkspacePanel;
