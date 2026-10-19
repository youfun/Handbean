import assert from "node:assert/strict";
import { JSDOM } from "jsdom";
import { ComposerPasteUpload } from "../js/hooks/composer_paste_upload.js";

const dom = new JSDOM(`
<!doctype html>
<form id="composer">
  <textarea id="ai-input" data-upload-name="images"></textarea>
</form>
`);

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

console.log("composer_paste_upload_test passed");
