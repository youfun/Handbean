import assert from "node:assert/strict";
import { ConversationNav } from "../js/hooks/conversation_nav.js";

class FakeClassList {
  constructor(el) {
    this.el = el;
  }
  contains(name) {
    return this.el._classes.has(name);
  }
  toggle(name, force) {
    const on = force === undefined ? !this.el._classes.has(name) : Boolean(force);
    if (on) this.el._classes.add(name);
    else this.el._classes.delete(name);
    return on;
  }
}

class FakeEl {
  constructor(attrs = {}) {
    this.attrs = { ...attrs };
    this.children = [];
    this.listeners = {};
    this._classes = new Set(String(attrs.class || "").split(/\s+/).filter(Boolean));
    this.classList = new FakeClassList(this);
    this.hidden = Boolean(attrs.hidden);
    this.parent = null;
    this._scrolled = false;
    this.scrollTop = 0;
    this.scrollHeight = 800;
    this.clientHeight = 200;
  }

  get id() {
    return this.attrs.id;
  }

  append(child) {
    child.parent = this;
    this.children.push(child);
    return child;
  }

  contains(node) {
    if (node === this) return true;
    return this.children.some((child) => child.contains(node));
  }

  closest(selector) {
    if (this.matches(selector)) return this;
    return this.parent ? this.parent.closest(selector) : null;
  }

  matches(selector) {
    if (selector.startsWith("[") && selector.endsWith("]")) {
      const body = selector.slice(1, -1);
      const [rawName, rawValue] = body.split("=");
      const name = rawName.trim();
      if (rawValue === undefined) return this.attrs[name] !== undefined;
      return String(this.attrs[name]) === rawValue.replace(/^"|"$/g, "");
    }
    return false;
  }

  querySelector(selector) {
    return this.querySelectorAll(selector)[0] || null;
  }

  querySelectorAll(selector) {
    const found = [];
    const visit = (node) => {
      if (node !== this && node.matches(selector)) found.push(node);
      for (const child of node.children) visit(child);
    };
    visit(this);
    return found;
  }

  getAttribute(name) {
    const value = this.attrs[name];
    return value === undefined ? null : String(value);
  }

  setAttribute(name, value) {
    this.attrs[name] = String(value);
  }

  addEventListener(type, fn) {
    this.listeners[type] = this.listeners[type] || [];
    this.listeners[type].push(fn);
  }

  removeEventListener(type, fn) {
    this.listeners[type] = (this.listeners[type] || []).filter((cb) => cb !== fn);
  }

  dispatchEvent(event) {
    const type = event.type;
    const payload = event && typeof event === "object" ? event : { type };
    let node = this;
    while (node) {
      for (const fn of node.listeners[type] || []) fn(payload);
      node = node.parent;
    }
    return true;
  }

  getBoundingClientRect() {
    return { top: this.attrs.top || 0 };
  }

  scrollIntoView() {
    this._scrolled = true;
  }
}

const messages = new FakeEl({ id: "ai-messages" });
const first = new FakeEl({ id: "u1", top: 0 });
const second = new FakeEl({ id: "u2", top: 400 });
messages.append(first);
messages.append(second);

const navEl = new FakeEl({ id: "conversation-nav" });
const panel = new FakeEl({ "data-conversation-nav-panel": "", hidden: true });
const counter = new FakeEl({ "data-conversation-nav-counter": "" });
counter.textContent = "2/2";
const item1 = new FakeEl({ "data-target-id": "u1", "data-index": "1" });
const item2 = new FakeEl({ "data-target-id": "u2", "data-index": "2" });
const toggle = new FakeEl({ "data-conversation-nav-toggle": "", "aria-expanded": "false" });
const bottom = new FakeEl({ "data-conversation-nav-bottom": "" });
panel.append(counter);
panel.append(item1);
panel.append(item2);
navEl.append(panel);
navEl.append(toggle);
navEl.append(bottom);

const documentListeners = {};
const fakeDocument = {
  getElementById(id) {
    if (id === "ai-messages") return messages;
    if (id === "u1") return first;
    if (id === "u2") return second;
    if (id === "conversation-nav") return navEl;
    return null;
  },
  addEventListener(type, fn, _opts) {
    documentListeners[type] = documentListeners[type] || [];
    documentListeners[type].push(fn);
  },
  removeEventListener(type, fn) {
    documentListeners[type] = (documentListeners[type] || []).filter((cb) => cb !== fn);
  },
};

globalThis.document = fakeDocument;
globalThis.requestAnimationFrame = (fn) => {
  fn();
  return 0;
};

const nav = { ...ConversationNav, el: navEl };
nav.mounted();

assert.equal(panel.hidden, true);
assert.equal(toggle.getAttribute("aria-expanded"), "false");

navEl.dispatchEvent({ type: "click", target: toggle, preventDefault() {} });
assert.equal(panel.hidden, false);
assert.equal(toggle.getAttribute("aria-expanded"), "true");

let unpinned = 0;
messages.addEventListener("handbean:unpin-chat-scroll", () => {
  unpinned += 1;
});

navEl.dispatchEvent({ type: "click", target: item1, preventDefault() {} });
assert.equal(first._scrolled, true);
assert.equal(unpinned, 1);
assert.equal(panel.hidden, true);
assert.equal(item1.getAttribute("aria-current"), "true");
assert.equal(counter.textContent, "1/2");

messages.scrollTop = 600;
nav.syncFromScroll();
assert.equal(bottom.getAttribute("aria-hidden"), "true");
assert.equal(bottom.tabIndex, -1);
assert.equal(navEl.classList.contains("is-away-from-bottom"), false);

panel.children = [counter];
messages.scrollTop = 0;
nav.syncFromScroll();
assert.equal(bottom.getAttribute("aria-hidden"), "false");
assert.equal(bottom.tabIndex, 0);
assert.equal(navEl.classList.contains("is-away-from-bottom"), true);

nav.setOpen(true);
for (const fn of documentListeners.keydown || []) fn({ key: "Escape" });
assert.equal(panel.hidden, true);

nav.destroyed();
delete globalThis.document;
console.log("conversation_nav_test passed");
