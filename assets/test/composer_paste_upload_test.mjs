import assert from "node:assert/strict";
import { JSDOM } from "jsdom";
import { ComposerPasteUpload } from "../js/hooks/composer_paste_upload.js";

const dom = new JSDOM(
  `
<!doctype html>
<form id="composer">
  <input type="hidden" name="workspace_command_operation_id" value="" />
  <textarea id="ai-input" data-upload-name="images" data-command-intent-key="test-command-intent" data-command-intent-scope="new:default"></textarea>
</form>
`,
  { url: "https://handbean.test/w/default/c/conversation" },
);

globalThis.window = dom.window;
globalThis.document = dom.window.document;
globalThis.Event = dom.window.Event;
globalThis.KeyboardEvent = dom.window.KeyboardEvent;

after(() => {
  delete globalThis.window;
  delete globalThis.document;
  delete globalThis.Event;
  delete globalThis.KeyboardEvent;
});

function after(fn) {
  process.on("exit", fn);
}

{
  const el = document.querySelector("#ai-input");
  const form = document.querySelector("#composer");
  let submitted = 0;
  form.requestSubmit = () => {
    submitted += 1;
  };

  const hook = { ...ComposerPasteUpload, el, upload: () => {} };
  hook.mounted();

  const event = new KeyboardEvent("keydown", {
    key: "Enter",
    bubbles: true,
    cancelable: true,
  });

  el.dispatchEvent(event);

  assert.equal(event.defaultPrevented, true);
  assert.equal(submitted, 1);

  hook.destroyed();
}

{
  const el = document.querySelector("#ai-input");
  const form = document.querySelector("#composer");
  let submitted = 0;
  form.requestSubmit = () => {
    submitted += 1;
  };

  const hook = { ...ComposerPasteUpload, el, upload: () => {} };
  hook.mounted();

  const event = new KeyboardEvent("keydown", {
    key: "Enter",
    shiftKey: true,
    bubbles: true,
    cancelable: true,
  });

  el.dispatchEvent(event);

  assert.equal(event.defaultPrevented, false);
  assert.equal(submitted, 0);

  hook.destroyed();
}

{
  const el = document.querySelector("#ai-input");
  const form = document.querySelector("#composer");
  let submitted = 0;
  let queued = 0;
  form.requestSubmit = () => {
    submitted += 1;
  };

  const hook = {
    ...ComposerPasteUpload,
    el,
    upload: () => {},
    pushEvent: (name) => {
      if (name === "queue_message") queued += 1;
    },
  };
  hook.mounted();

  const event = new KeyboardEvent("keydown", {
    key: "Enter",
    ctrlKey: true,
    bubbles: true,
    cancelable: true,
  });

  el.dispatchEvent(event);

  assert.equal(event.defaultPrevented, true);
  assert.equal(submitted, 0);
  assert.equal(queued, 1);

  hook.destroyed();
}

{
  const el = document.querySelector("#ai-input");
  const callbacks = new Map();

  const hook = {
    ...ComposerPasteUpload,
    el,
    upload: () => {},
    handleEvent: (name, callback) => callbacks.set(name, callback),
  };
  hook.mounted();

  callbacks.get("composer:set-input")({ value: "Continue from the widget" });

  assert.equal(el.value, "Continue from the widget");
  assert.equal(document.activeElement, el);

  callbacks.get("prefill-subagent-follow-up")({ value: "@child-research " });

  assert.equal(el.value, "@child-research ");
  assert.equal(document.activeElement, el);

  hook.destroyed();
}

{
  const el = document.querySelector("#ai-input");
  const hidden = document.querySelector("input[name='workspace_command_operation_id']");
  el.value = "!pwd";

  const hook = { ...ComposerPasteUpload, el, upload: () => {} };
  hook.mounted();
  const firstId = hidden.value;
  assert.match(firstId, /^[0-9a-f-]{36}$/);

  hook.updated();
  assert.equal(hidden.value, firstId);

  el.dataset.commandIntentScope = "conversation-a";
  hook.updated();
  assert.equal(hidden.value, firstId);
  hook.destroyed();

  hidden.value = "";
  const reconnected = { ...ComposerPasteUpload, el, upload: () => {} };
  reconnected.mounted();
  assert.equal(hidden.value, firstId);

  el.dataset.commandIntentScope = "conversation-b";
  reconnected.updated();
  assert.notEqual(hidden.value, firstId);
  const secondConversationId = hidden.value;

  el.value = "!whoami";
  el.dispatchEvent(new Event("input", { bubbles: true }));
  assert.notEqual(hidden.value, secondConversationId);

  el.value = "plain message";
  el.dispatchEvent(new Event("input", { bubbles: true }));
  assert.equal(hidden.value, "");
  reconnected.destroyed();
}

{
  const el = document.querySelector("#ai-input");
  const hidden = document.querySelector("input[name='workspace_command_operation_id']");
  const storagePrototype = Object.getPrototypeOf(window.sessionStorage);
  const originalSetItem = storagePrototype.setItem;
  const staleId = "00000000-0000-4000-8000-000000000001";

  window.sessionStorage.setItem(
    "test-command-intent",
    JSON.stringify({
      value: "!pwd",
      id: staleId,
      scope: "conversation-write-failure",
    }),
  );

  storagePrototype.setItem = () => {
    throw new Error("storage full");
  };

  try {
    hidden.value = "";
    el.dataset.commandIntentScope = "conversation-write-failure";
    el.value = "!echo hello";

    const hook = { ...ComposerPasteUpload, el, upload: () => {} };
    hook.mounted();
    const firstId = hidden.value;
    assert.notEqual(firstId, staleId);

    hidden.value = "";
    hook.updated();
    assert.equal(hidden.value, firstId);
    hook.destroyed();
  } finally {
    storagePrototype.setItem = originalSetItem;
    window.sessionStorage.removeItem("test-command-intent");
  }
}

{
  const el = document.querySelector("#ai-input");
  const hidden = document.querySelector("input[name='workspace_command_operation_id']");
  const storagePrototype = Object.getPrototypeOf(window.sessionStorage);
  const originalGetItem = storagePrototype.getItem;
  const originalSetItem = storagePrototype.setItem;
  const originalRemoveItem = storagePrototype.removeItem;

  storagePrototype.getItem = () => {
    throw new Error("storage unavailable");
  };
  storagePrototype.setItem = () => {
    throw new Error("storage unavailable");
  };
  storagePrototype.removeItem = () => {
    throw new Error("storage unavailable");
  };

  try {
    hidden.value = "";
    el.dataset.commandIntentScope = "conversation-storage-failure";
    el.value = "!pwd";

    const hook = { ...ComposerPasteUpload, el, upload: () => {} };
    hook.mounted();
    const firstId = hidden.value;
    assert.match(firstId, /^[0-9a-f-]{36}$/);

    hidden.value = "";
    hook.updated();
    assert.equal(hidden.value, firstId);

    el.value = "!whoami";
    el.dispatchEvent(new Event("input", { bubbles: true }));
    assert.notEqual(hidden.value, firstId);
    hook.destroyed();
  } finally {
    storagePrototype.getItem = originalGetItem;
    storagePrototype.setItem = originalSetItem;
    storagePrototype.removeItem = originalRemoveItem;
  }
}

console.log("composer_paste_upload_test passed");
