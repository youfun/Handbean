import assert from "node:assert/strict";
import { ChatScroll } from "../js/hooks/chat_scroll.js";

class FakeElement {
  constructor() {
    this.dataset = {
      conversationId: "conversation-1",
      historyBefore: "cursor-2",
      historyHasMore: "true",
    };
    this.scrollTop = 0;
    this.scrollHeight = 1_000;
    this.clientHeight = 300;
    this.listeners = new Map();
  }

  addEventListener(type, listener) {
    const listeners = this.listeners.get(type) || [];
    listeners.push(listener);
    this.listeners.set(type, listeners);
  }

  removeEventListener(type, listener) {
    this.listeners.set(
      type,
      (this.listeners.get(type) || []).filter((item) => item !== listener),
    );
  }

  contains(target) {
    return target?.inside === true;
  }
}

class FakeMutationObserver {
  observe() {}
  disconnect() {}
}

globalThis.MutationObserver = FakeMutationObserver;
globalThis.requestAnimationFrame = (callback) => {
  callback();
  return 0;
};

const element = new FakeElement();
const pushes = [];
const hook = {
  ...ChatScroll,
  el: element,
  handleEvent() {},
  pushEvent(event, payload, callback) {
    pushes.push({ event, payload, callback });
  },
};

hook.mounted();
assert.equal(element.scrollTop, 1_000, "mount starts at the newest message");
assert.equal(pushes.length, 0, "mounting at the bottom does not fetch history");

element.scrollTop = 650;
hook.onUserIntent({ type: "touchstart" });
hook.onScroll();
assert.equal(hook._userIntent, true, "a touch gesture stays active while it leaves the bottom");

element.scrollTop = 0;
hook.onScroll();
assert.equal(pushes.length, 1);
assert.equal(pushes[0].event, "load_older_history");

hook.onScroll();
hook.onUserIntent({ type: "wheel", deltaY: -40 });
assert.equal(pushes.length, 1, "one top reach has at most one in-flight request");

element.scrollHeight = 1_800;
element.dataset.historyBefore = "cursor-1";
hook.updated();
assert.equal(element.scrollTop, 800, "prepended history keeps the old first visible content anchored");
assert.equal(hook._loadingOlder, false);

element.scrollTop = 0;
hook.onUserIntent({ type: "wheel", deltaY: -40 });
assert.equal(pushes.length, 2, "reaching the new top fetches the next page");
pushes[1].callback();
assert.equal(hook._loadingOlder, false, "an unchanged server reply allows a retry");

hook.onUserIntent({ type: "wheel", deltaY: -40 });
assert.equal(pushes.length, 3);
pushes[2].callback();
element.dataset.historyHasMore = "false";
hook.onUserIntent({ type: "wheel", deltaY: -40 });
assert.equal(pushes.length, 3, "the end of history never sends another request");

hook.destroyed();

const focusedElement = new FakeElement();
const focusPushes = [];
let focusedTarget = null;
globalThis.location = { hash: "#source-entry" };
globalThis.document = {
  getElementById(id) {
    return id === "source-entry" ? focusedTarget : null;
  },
};

const focusHandlers = new Map();
const focusHook = {
  ...ChatScroll,
  el: focusedElement,
  handleEvent(event, callback) {
    focusHandlers.set(event, callback);
  },
  pushEvent(event, payload, callback) {
    focusPushes.push({ event, payload, callback });
  },
};

focusHook.mounted();
assert.equal(focusPushes.length, 1, "a missing hash target requests one bounded around window");
assert.equal(focusPushes[0].event, "load_history_around");
assert.deepEqual(focusPushes[0].payload, { entry_id: "source-entry" });
focusHook.updated();
assert.equal(focusPushes.length, 1, "a missing target never loops through older pages");
assert.equal(focusedElement.scrollTop, 0, "a source link does not jump to the newest message");

focusedTarget = {
  inside: true,
  scrollIntoView(options) {
    this.options = options;
  },
};
focusHook.updated();
assert.deepEqual(focusedTarget.options, { behavior: "smooth", block: "center" });
assert.equal(focusHook._focusEntryId, null);

focusedTarget = null;
focusHandlers.get("focus-conversation-entry")({ id: "server-loaded-entry" });
assert.equal(focusPushes.length, 1, "server-bounded focus does not request older pages");
focusHook.destroyed();

delete globalThis.location;
delete globalThis.document;
delete globalThis.MutationObserver;
delete globalThis.requestAnimationFrame;
console.log("chat_scroll_test passed");
