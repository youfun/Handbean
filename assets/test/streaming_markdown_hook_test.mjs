import assert from "node:assert/strict";
import { JSDOM } from "jsdom";
import { StreamingMarkdown } from "../js/hooks/streaming_markdown.js";

const dom = new JSDOM(`
<!doctype html>
<div id="wrapper" data-source="# Done" data-final="false" data-streaming="false">
  <div data-markdown-target></div>
</div>
`);

globalThis.window = dom.window;
globalThis.document = dom.window.document;
globalThis.Node = dom.window.Node;
Object.defineProperty(globalThis, "navigator", {
  configurable: true,
  value: { clipboard: { writeText: async () => {} } }
});

after(() => {
  delete globalThis.window;
  delete globalThis.document;
  delete globalThis.Node;
  delete globalThis.navigator;
});

function after(fn) {
  process.on("exit", fn);
}

{
  const el = document.querySelector("#wrapper");
  el.dataset.source = "[CHANGELOG.md](/workspace/CHANGELOG.md:12)";
  el.dataset.entryId = "assistant-changelog";
  el.dataset.streaming = "false";
  const events = [];
  const hook = { ...StreamingMarkdown, el, pushEvent: (...args) => events.push(args) };
  hook.mounted();
  const link = el.querySelector("a");
  const click = new window.MouseEvent("click", { bubbles: true, cancelable: true });
  link.dispatchEvent(click);
  assert.equal(click.defaultPrevented, true);
  assert.deepEqual(events, [["open_file_change", {
    path: "/workspace/CHANGELOG.md", message_id: "assistant-changelog"
  }]]);
  hook.destroyed();
  el.dataset.source = "# Done";
}

{
  const el = document.querySelector("#wrapper");
  const hook = { ...StreamingMarkdown, el };
  hook.mounted();

  const target = el.querySelector("[data-markdown-target]");
  assert.match(target.innerHTML, /<h1>Done<\/h1>/);
  assert.doesNotMatch(target.innerHTML, /markdown-typewriter-cursor/);

  hook.destroyed();
}

{
  const el = document.querySelector("#wrapper");
  el.dataset.source = "typing";
  el.dataset.final = "false";
  el.dataset.streaming = "true";

  const hook = { ...StreamingMarkdown, el };
  hook.mounted();

  const target = el.querySelector("[data-markdown-target]");
  assert.match(target.innerHTML, /markdown-typewriter-cursor/);
  assert.equal(target.querySelector("p > .markdown-typewriter-cursor")?.textContent, "▍");

  hook.destroyed();
}

{
  const el = document.querySelector("#wrapper");
  el.dataset.source = "- one\n- two";
  el.dataset.final = "false";
  el.dataset.streaming = "true";

  const hook = { ...StreamingMarkdown, el };
  hook.mounted();

  const target = el.querySelector("[data-markdown-target]");
  const items = target.querySelectorAll("li");
  assert.equal(items.length, 2);
  assert.equal(items[1].querySelector(".markdown-typewriter-cursor")?.textContent, "▍");

  hook.destroyed();
}

{
  const source =
    "**Files created:**\n\n" +
    "| File | Description |\n" +
    "|------|-------------|\n" +
    "| `ssl/server.key` | 2048-bit RSA private key |\n\n" +
    "```js\nconsole.log(1)\n```\n";

  const el = document.createElement("div");
  el.id = "assistant-md-wrapper-repro";
  el.dataset.source = source;
  el.dataset.final = "true";
  el.dataset.streaming = "false";
  el.innerHTML =
    '<div data-markdown-target class="markdown-body">' +
    '<div class="markdown-noscript-fallback whitespace-pre-wrap">' +
    source.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;") +
    "</div></div>";
  document.body.appendChild(el);

  const hook = { ...StreamingMarkdown, el };
  hook.mounted();
  hook.updated();

  const target = el.querySelector("[data-markdown-target]");
  assert.equal(target.querySelector(".markdown-noscript-fallback"), null);
  assert.equal(target.querySelectorAll("strong").length > 0, true);
  assert.equal(target.querySelectorAll("table").length, 1);
  assert.equal(target.querySelectorAll("th").length, 2);
  assert.equal(target.querySelectorAll("pre").length, 1);
  assert.equal(target.querySelector("code.language-js")?.textContent.trim(), "console.log(1)");
  assert.equal(target.querySelectorAll(".code-block-wrapper").length, 1);
  assert.doesNotMatch(target.innerHTML, /\*\*Files created:\*\*/);
  assert.doesNotMatch(target.innerHTML, /\| File \| Description \|/);

  hook.destroyed();
  el.remove();
}


{
  const source = "**Files created:**\n\n```js\nconsole.log(1)\n```\n";
  const el = document.createElement("div");
  el.dataset.source = source;
  el.dataset.final = "true";
  el.dataset.streaming = "false";
  el.innerHTML =
    '<div data-markdown-target class="markdown-body">' +
    '<div class="markdown-noscript-fallback">**Files created:**</div></div>';
  document.body.appendChild(el);

  const hook = { ...StreamingMarkdown, el };
  hook.mounted();
  const target = el.querySelector("[data-markdown-target]");
  assert.equal(target.querySelector(".markdown-noscript-fallback"), null);
  assert.ok(target.querySelector("strong"));

  // Simulate LiveView restoring the noscript fallback after a morph.
  target.innerHTML = '<div class="markdown-noscript-fallback">**Files created:**</div>';
  hook.updated();
  assert.equal(target.querySelector(".markdown-noscript-fallback"), null);
  assert.ok(target.querySelector("strong"));
  assert.ok(target.querySelector("pre"));
  assert.doesNotMatch(target.innerHTML, /\*\*Files created:\*\*/);

  hook.destroyed();
  el.remove();
}

console.log("streaming_markdown_hook_test passed");
