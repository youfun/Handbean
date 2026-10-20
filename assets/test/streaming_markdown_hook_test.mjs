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
    path: "/workspace/CHANGELOG.md", line: 12, message_id: "assistant-changelog"
  }]]);
  hook.destroyed();
  el.dataset.source = "# Done";
}

{
  const el = document.querySelector("#wrapper");
  el.dataset.source = "需要再次确认是因为项目 AGENTS.md 第 22 行 明确要求。";
  el.dataset.entryId = "assistant-agents";
  el.dataset.streaming = "false";
  const events = [];
  const hook = { ...StreamingMarkdown, el, pushEvent: (...args) => events.push(args) };
  hook.mounted();
  const link = el.querySelector("a");
  assert.equal(link.getAttribute("href"), "AGENTS.md#L22");
  const click = new window.MouseEvent("click", { bubbles: true, cancelable: true });
  link.dispatchEvent(click);
  assert.equal(click.defaultPrevented, true);
  assert.deepEqual(events, [["open_file_change", {
    path: "AGENTS.md", line: 22, message_id: "assistant-agents"
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

{
  const source = "```mermaid\ngraph TD\n  A-->B\n```\n";
  const el = document.createElement("div");
  el.dataset.source = source;
  el.dataset.final = "false";
  el.dataset.streaming = "true";
  el.innerHTML = '<div data-markdown-target></div>';
  document.body.appendChild(el);
  const hook = { ...StreamingMarkdown, el };
  hook.mounted();
  const target = el.querySelector("[data-markdown-target]");
  const visibleText = (node) => {
    if (node.nodeType === Node.TEXT_NODE) return node.textContent;
    if (node.hidden) return "";
    return [...node.childNodes].map(visibleText).join(" ");
  };
  const normalizedVisibleText = () => visibleText(target).replace(/\s+/g, " ").trim();
  assert.equal(target.querySelector("[data-mermaid-preview]"), null);
  assert.match(target.querySelector("code")?.className || "", /language-mermaid/);

  el.dataset.streaming = "false";
  hook.updated();
  assert.equal(
    normalizedVisibleText(),
    "graph TD A-->B",
    "an interrupted Mermaid block must keep its source visible instead of showing a pending diagram"
  );

  el.dataset.final = "true";
  hook.updated();
  assert.ok(target.querySelector("[data-mermaid-preview]"));
  hook.destroyed();
  el.remove();
}

{
  let nextFrameId = 1;
  const frames = new Map();
  globalThis.requestAnimationFrame = (callback) => {
    const id = nextFrameId++;
    frames.set(id, callback);
    return id;
  };
  globalThis.cancelAnimationFrame = (id) => frames.delete(id);

  const el = document.createElement("div");
  el.dataset.source = "First";
  el.dataset.final = "false";
  el.dataset.streaming = "true";
  el.innerHTML = '<div data-markdown-target></div>';
  document.body.appendChild(el);

  const hook = { ...StreamingMarkdown, el };
  hook.mounted();
  hook.controller.flush();
  const target = el.querySelector("[data-markdown-target]");
  const visibleText = () => {
    const copy = target.cloneNode(true);
    copy.querySelector(".markdown-typewriter-cursor")?.remove();
    return copy.textContent.trim();
  };

  assert.equal(visibleText(), "First");
  el.dataset.source = "First plus";
  hook.updated();
  assert.equal(visibleText(), "First", "an appended delta stays hidden until the stream reveals it");
  hook.controller.flush();
  assert.equal(visibleText(), "First plus");

  el.dataset.source = "Replacement";
  hook.updated();
  assert.equal(visibleText(), "", "a non-appended update must discard the old visible text");
  hook.controller.flush();
  assert.equal(visibleText(), "Replacement");

  el.dataset.source = "Cancelled result";
  el.dataset.streaming = "false";
  hook.updated();
  assert.equal(visibleText(), "Cancelled result");

  hook.destroyed();
  el.remove();
  delete globalThis.requestAnimationFrame;
  delete globalThis.cancelAnimationFrame;
}

console.log("streaming_markdown_hook_test passed");
