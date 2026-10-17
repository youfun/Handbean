import assert from "node:assert/strict";
import { JSDOM } from "jsdom";
import { WorkspacePanel } from "../js/hooks/workspace_panel.js";

const dom = new JSDOM(`
  <div id="outside">outside</div>
  <div id="workspace-panel">
    <div class="workspace-tree-pane">
      <button id="directory" data-workspace-relative-path="lib" data-workspace-absolute-path="/workspace/lib">
        <span>lib</span>
      </button>
      <div id="file" data-workspace-relative-path="lib/a.ex" data-workspace-absolute-path="/workspace/lib/a.ex">
        <button><span id="file-label">a.ex</span></button>
      </div>
      <div id="symlink" data-workspace-relative-path="latest" data-workspace-absolute-path="/workspace/latest">
        latest
      </div>
    </div>
    <div id="editor-content">
      <div id="file-preview">
        <div id="error">Binary files cannot be previewed as text</div>
        <pre id="nested-preview">preview</pre>
      </div>
    </div>
    <div id="workspace-tree-context-menu" role="menu" hidden>
      <button data-workspace-tree-action="copy-absolute">Copy absolute path</button>
      <button data-workspace-tree-action="copy-relative">Copy relative path</button>
      <button data-workspace-tree-action="reveal-in-file-manager" hidden>Reveal in Finder</button>
    </div>
  </div>
`, { url: "https://handbean.test" });

const { document } = dom.window;
const root = document.getElementById("workspace-panel");
const tree = root.querySelector(".workspace-tree-pane");
const preview = document.getElementById("editor-content");
const error = document.getElementById("error");
const nestedPreview = document.getElementById("nested-preview");
const menu = document.getElementById("workspace-tree-context-menu");
const reveal = menu.querySelector("[data-workspace-tree-action='reveal-in-file-manager']");
const copied = [];
const pushed = [];

Object.defineProperty(dom.window.navigator, "clipboard", {
  configurable: true,
  value: { writeText: async (text) => copied.push(text) },
});
Object.defineProperties(menu, {
  offsetWidth: { configurable: true, value: 180 },
  offsetHeight: { configurable: true, value: 120 },
});

function setDimensions(element, { clientHeight, scrollHeight }) {
  Object.defineProperties(element, {
    clientHeight: { configurable: true, value: clientHeight },
    scrollHeight: { configurable: true, value: scrollHeight },
  });
}

function wheel(target, options = {}) {
  const event = new dom.window.WheelEvent("wheel", {
    bubbles: true,
    cancelable: true,
    deltaY: 40,
    ...options,
  });
  target.dispatchEvent(event);
  return event;
}

function contextMenu(target, options = {}) {
  const event = new dom.window.MouseEvent("contextmenu", {
    bubbles: true,
    cancelable: true,
    clientX: 80,
    clientY: 90,
    ...options,
  });
  target.dispatchEvent(event);
  return event;
}

const hook = {
  ...WorkspacePanel,
  el: root,
  handleEvent() {},
  pushEvent(name, payload) { pushed.push([name, payload]); },
};
hook.mounted();

setDimensions(tree, { clientHeight: 200, scrollHeight: 1000 });
setDimensions(preview, { clientHeight: 200, scrollHeight: 200 });
setDimensions(nestedPreview, { clientHeight: 100, scrollHeight: 100 });

// An error/binary preview cannot scroll, so its wheel gesture moves the file tree.
tree.scrollTop = 100;
let event = wheel(error);
assert.equal(tree.scrollTop, 140);
assert.equal(event.defaultPrevented, true);

// A scrollable preview keeps ownership of the gesture, including at its boundary.
setDimensions(preview, { clientHeight: 200, scrollHeight: 500 });
tree.scrollTop = 100;
preview.scrollTop = 0;
event = wheel(error, { deltaY: -40 });
assert.equal(tree.scrollTop, 100);
assert.equal(event.defaultPrevented, false);

// A nested scroll container in an otherwise fixed preview also keeps the gesture.
setDimensions(preview, { clientHeight: 200, scrollHeight: 200 });
setDimensions(nestedPreview, { clientHeight: 100, scrollHeight: 500 });
nestedPreview.style.overflowY = "auto";
event = wheel(nestedPreview);
assert.equal(tree.scrollTop, 100);
assert.equal(event.defaultPrevented, false);
setDimensions(nestedPreview, { clientHeight: 100, scrollHeight: 100 });

// Browser gestures, modifier scrolling, and horizontal pans are not intercepted.
for (const options of [
  { ctrlKey: true },
  { metaKey: true },
  { altKey: true },
  { shiftKey: true },
  { deltaX: 40, deltaY: 40 },
]) {
  tree.scrollTop = 100;
  event = wheel(error, options);
  assert.equal(tree.scrollTop, 100);
  assert.equal(event.defaultPrevented, false);
}

// Mouse-wheel line and page deltas are normalized before moving the tree.
tree.scrollTop = 0;
event = wheel(error, { deltaMode: 1, deltaY: 2 });
assert.equal(tree.scrollTop, 32);
assert.equal(event.defaultPrevented, true);

tree.scrollTop = 0;
event = wheel(error, { deltaMode: 2, deltaY: 1 });
assert.equal(tree.scrollTop, 200);
assert.equal(event.defaultPrevented, true);

// Do not consume a wheel event when the tree is already at that boundary.
tree.scrollTop = 0;
event = wheel(error, { deltaY: -40 });
assert.equal(tree.scrollTop, 0);
assert.equal(event.defaultPrevented, false);

tree.scrollTop = 800;
event = wheel(error, { deltaY: 40 });
assert.equal(tree.scrollTop, 800);
assert.equal(event.defaultPrevented, false);

// Every visible entry kind opens the same menu, including nested content.
for (const target of [
  document.querySelector("#directory span"),
  document.getElementById("file-label"),
  document.getElementById("symlink"),
]) {
  event = contextMenu(target);
  assert.equal(event.defaultPrevented, true);
  assert.equal(menu.hidden, false);
  assert.equal(reveal.hidden, false);
  hook.closeWorkspaceTreeMenu();
}

// Position is clamped to the viewport.
event = contextMenu(document.getElementById("file-label"), { clientX: 1000, clientY: 760 });
assert.equal(menu.style.left, "836px");
assert.equal(menu.style.top, "640px");

// Both copy actions use the path selected by the context click.
menu.querySelector("[data-workspace-tree-action='copy-relative']").click();
await Promise.resolve();
assert.deepEqual(copied, ["lib/a.ex"]);
assert.equal(menu.hidden, true);

contextMenu(document.getElementById("file-label"));
menu.querySelector("[data-workspace-tree-action='copy-absolute']").click();
await Promise.resolve();
assert.deepEqual(copied, ["lib/a.ex", "/workspace/lib/a.ex"]);

// File-manager integration sends only the relative path back to LiveView.
contextMenu(document.getElementById("file-label"));
reveal.click();
assert.deepEqual(pushed, [["reveal_in_file_manager", { path: "lib/a.ex" }]]);
assert.equal(menu.hidden, true);

// Outside pointer, Escape, tree scrolling, and viewport resize close the menu.
contextMenu(document.getElementById("file-label"));
document.getElementById("outside").dispatchEvent(new dom.window.Event("pointerdown", { bubbles: true }));
assert.equal(menu.hidden, true);

contextMenu(document.getElementById("file-label"));
document.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
assert.equal(menu.hidden, true);

contextMenu(document.getElementById("file-label"));
tree.dispatchEvent(new dom.window.Event("scroll"));
assert.equal(menu.hidden, true);

contextMenu(document.getElementById("file-label"));
dom.window.dispatchEvent(new dom.window.Event("resize"));
assert.equal(menu.hidden, true);

// LiveView hook teardown removes delegated and document/window listeners.
hook.destroyed();
tree.scrollTop = 100;
event = wheel(error);
assert.equal(tree.scrollTop, 100);
assert.equal(event.defaultPrevented, false);
event = contextMenu(document.getElementById("file-label"));
assert.equal(event.defaultPrevented, false);
assert.equal(menu.hidden, true);

dom.window.close();
console.log("workspace_panel_test passed");
