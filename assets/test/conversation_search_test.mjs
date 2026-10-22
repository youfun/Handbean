import assert from "node:assert/strict";
import { JSDOM } from "jsdom";
import { ConversationSearch, safeHighlight } from "../js/hooks/conversation_search.js";

const dom = new JSDOM(`
  <button id="open-conversation-search">open</button>
  <button id="mobile-open-conversation-search">mobile open</button>
  <div id="overlay" data-results-query="needle">
    <input id="conversation-search-input" value="needle">
    <select id="conversation-range"><option>all</option></select>
    <button id="row-1" data-search-option aria-selected="false">one</button>
    <button id="row-2" data-search-option aria-selected="false">two</button>
    <button id="close">close</button>
    <span id="unsafe" data-safe-highlight data-highlight-query="needle">before &lt;img src=x onerror=alert(1)&gt; needle after</span>
  </div>
`);

globalThis.document = dom.window.document;
globalThis.requestAnimationFrame = (callback) => callback();

const unsafe = document.getElementById("unsafe");
safeHighlight(unsafe);
assert.equal(unsafe.querySelectorAll("img").length, 0, "highlighting never parses result HTML");
assert.equal(unsafe.querySelector("mark").textContent, "needle");
assert.match(unsafe.textContent, /<img src=x onerror=alert\(1\)>/);

const handlers = new Map();
const pushes = [];
const hook = {
  ...ConversationSearch,
  el: document.getElementById("overlay"),
  handleEvent(name, callback) {
    handlers.set(name, callback);
  },
  pushEvent(name, payload) {
    pushes.push({ name, payload });
  },
};

hook.mounted();
const input = document.getElementById("conversation-search-input");
const range = document.getElementById("conversation-range");
const first = document.getElementById("row-1");
const second = document.getElementById("row-2");
const close = document.getElementById("close");
let clicks = 0;
second.addEventListener("click", () => clicks++);
assert.equal(first.getAttribute("aria-selected"), "true");

hook.onKeydown({ key: "ArrowDown", preventDefault() {}, target: input });
assert.equal(second.getAttribute("aria-selected"), "true");
assert.equal(input.getAttribute("aria-activedescendant"), "row-2");

first.focus();
hook.activeIndex = 0;
hook.select(0, false);
hook.onKeydown({ key: "ArrowDown", preventDefault() {}, target: first });
assert.equal(document.activeElement, second, "option arrow navigation moves DOM focus with selection");

let selectPrevented = false;
hook.onKeydown({ key: "ArrowDown", preventDefault() { selectPrevented = true; }, target: range });
assert.equal(selectPrevented, false, "range select keeps native arrow-key behavior");

hook.onKeydown({ key: "Enter", isComposing: true, preventDefault() { throw new Error("IME event was handled"); }, target: input });
assert.equal(clicks, 0, "IME composition never opens a result");

input.value = "new query";
let stalePrevented = false;
hook.onKeydown({ key: "Enter", preventDefault() { stalePrevented = true; }, target: input });
assert.equal(stalePrevented, true, "input Enter always prevents form submission");
assert.equal(clicks, 0, "stale debounced results cannot be opened");

input.value = "needle";
hook.onKeydown({ key: "Enter", preventDefault() {}, target: input });
assert.equal(clicks, 1, "current results can be opened");

close.focus();
let tabPrevented = false;
hook.onKeydown({ key: "Tab", preventDefault() { tabPrevented = true; }, target: close });
assert.equal(tabPrevented, true);
assert.equal(document.activeElement, input, "Tab wraps inside the modal dialog");

input.focus();
hook.onKeydown({ key: "Tab", shiftKey: true, preventDefault() {}, target: input });
assert.equal(document.activeElement, close, "Shift+Tab wraps inside the modal dialog");

hook.onKeydown({ key: "Escape", preventDefault() {}, target: input });
assert.equal(pushes.at(-1).name, "close_conversation_search");

const mobileOpen = document.getElementById("mobile-open-conversation-search");
mobileOpen.focus();
handlers.get("focus-conversation-search")();
assert.equal(document.activeElement.id, "conversation-search-input");
handlers.get("restore-conversation-search-focus")();
assert.equal(document.activeElement, mobileOpen, "closing restores focus to the mobile trigger");

Object.defineProperty(mobileOpen, "offsetParent", { value: hook.el, configurable: true });
document.body.tabIndex = -1;
document.body.focus();
handlers.get("focus-conversation-search")();
assert.equal(document.activeElement, input);
handlers.get("restore-conversation-search-focus")();
assert.equal(
  document.activeElement,
  mobileOpen,
  "lost focus falls back to the visible mobile trigger",
);

hook.el.hidden = false;
const continuation = document.createElement("button");
continuation.id = "conversation-search-continue";
continuation.dataset.searchContinuation = "";
hook.el.append(continuation);
continuation.focus();
continuation.click();
assert.equal(
  document.activeElement,
  input,
  "continuing search transfers focus before LiveView disables the control",
);
hook.beforeUpdate();
continuation.disabled = true;
hook.updated();
assert.equal(document.activeElement, input, "the loading patch keeps focus in the search input");
hook.beforeUpdate();
continuation.remove();
hook.updated();
assert.equal(
  document.activeElement,
  input,
  "the final patch can remove the continuation control without losing dialog focus",
);
assert.equal(hook.returnFocus, mobileOpen, "result updates preserve the original trigger");
const pushesBeforeRecoveredEscape = pushes.length;
input.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
assert.equal(pushes.length, pushesBeforeRecoveredEscape + 1);
assert.equal(pushes.at(-1).name, "close_conversation_search");

const returnFocusBeforeResultOpen = hook.returnFocus;
hook.beforeUpdate();
hook.el.hidden = true;
hook.updated();
assert.equal(
  hook.returnFocus,
  returnFocusBeforeResultOpen,
  "opening a result keeps the original trigger without restoring it",
);
assert.notEqual(
  document.activeElement,
  mobileOpen,
  "opening a result never restores focus to the palette trigger",
);

hook.el.hidden = false;
mobileOpen.remove();
document.body.focus();
hook.returnFocus = null;
handlers.get("focus-conversation-search")();
handlers.get("restore-conversation-search-focus")();
assert.equal(
  document.activeElement.id,
  "open-conversation-search",
  "desktop fallback remains available when the mobile trigger is absent",
);

hook.destroyed();
delete globalThis.document;
delete globalThis.requestAnimationFrame;
console.log("conversation_search_test passed");
