import assert from "node:assert/strict";
import { JSDOM } from "jsdom";
import {
  WorkspaceAddDrop,
  directoryDropFromDataTransfer,
  nativeFilePath,
  pathFromUriList,
} from "../js/hooks/workspace_add_drop.js";

const dom = new JSDOM(
  `<div id="add-workspace-drop"><button id="add-workspace">添加工作区</button></div>`,
  { url: "https://handbean.test/" },
);

globalThis.window = dom.window;
globalThis.document = dom.window.document;

after(() => {
  delete globalThis.window;
  delete globalThis.document;
});

function after(fn) {
  process.on("exit", fn);
}

assert.equal(nativeFilePath({ path: "/Users/box/dev-code/Handbeam" }), "/Users/box/dev-code/Handbeam");
assert.equal(nativeFilePath({ path: "  " }), "");
assert.equal(nativeFilePath({}), "");

assert.equal(pathFromUriList("file:///Users/box/Notes"), "/Users/box/Notes");
assert.equal(pathFromUriList("file:///C:/Users/box/Notes"), "C:/Users/box/Notes");
assert.equal(pathFromUriList("https://example.com/Notes"), "");

{
  const drop = directoryDropFromDataTransfer({
    items: [
      {
        kind: "file",
        webkitGetAsEntry: () => ({ isDirectory: true, isFile: false }),
        getAsFile: () => ({ path: "/Users/box/Notes", type: "" }),
      },
    ],
  });
  assert.deepEqual(drop, { kind: "directory", path: "/Users/box/Notes" });
}

{
  const drop = directoryDropFromDataTransfer({
    items: [
      {
        kind: "file",
        webkitGetAsEntry: () => ({ isDirectory: false, isFile: true }),
        getAsFile: () => ({ path: "/Users/box/Notes/readme.md", type: "text/markdown" }),
      },
    ],
  });
  assert.deepEqual(drop, { kind: "file" });
}

{
  const drop = directoryDropFromDataTransfer({
    getData: (type) => (type === "text/uri-list" ? "file:///Users/box/Notes" : ""),
  });
  assert.deepEqual(drop, { kind: "directory", path: "/Users/box/Notes" });
}

{
  const el = document.getElementById("add-workspace-drop");
  const pushed = [];
  const hook = {
    ...WorkspaceAddDrop,
    el,
    pushEvent: (name, payload) => pushed.push([name, payload]),
  };
  hook.mounted();

  el.dispatchEvent(new dom.window.Event("dragenter", { bubbles: true, cancelable: true }));
  assert.equal(el.classList.contains("is-dragover"), true);

  const dropEvent = new dom.window.Event("drop", { bubbles: true, cancelable: true });
  dropEvent.dataTransfer = {
    items: [
      {
        kind: "file",
        webkitGetAsEntry: () => ({ isDirectory: true, isFile: false }),
        getAsFile: () => ({ path: "/Users/box/Notes", type: "" }),
      },
    ],
    files: [],
    getData: () => "",
  };
  el.dispatchEvent(dropEvent);

  assert.equal(el.classList.contains("is-dragover"), false);
  assert.deepEqual(pushed, [["drop_workspace_path", { path: "/Users/box/Notes" }]]);

  const fileEvent = new dom.window.Event("drop", { bubbles: true, cancelable: true });
  fileEvent.dataTransfer = {
    items: [
      {
        kind: "file",
        webkitGetAsEntry: () => ({ isDirectory: false, isFile: true }),
        getAsFile: () => ({ path: "/Users/box/Notes/a.md", type: "text/markdown" }),
      },
    ],
    files: [],
    getData: () => "",
  };
  el.dispatchEvent(fileEvent);
  assert.equal(pushed.length, 1);

  hook.destroyed();
}
