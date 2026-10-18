// User-visible path: assistant text → streaming hook → preview/source → later
// deltas → history remount. Catch synthetic fence completion, source corruption,
// iframe replacement (lost input state), raw HTML execution, and stale previews.
// Real Chromium additionally checks script execution and isolation; jsdom cannot.
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";
import { StreamingMarkdown } from "../js/hooks/streaming_markdown.js";

const dom = new JSDOM("<!doctype html><body></body>");
globalThis.window = dom.window;
globalThis.document = dom.window.document;
let copied = "";
Object.defineProperty(globalThis, "navigator", {
  configurable: true,
  value: { clipboard: { writeText: async (text) => { copied = text; } } }
});

const el = document.createElement("div");
el.innerHTML = "<div data-markdown-target></div>";
document.body.appendChild(el);
const hook = { ...StreamingMarkdown, el };
const target = el.firstElementChild;
const widget = '<button onclick="this.textContent=7">Count **</button>\n<script>window.count=3</script>\n';
const partial = "Before\n\n```widget\n" + widget;
el.dataset.source = partial;
el.dataset.streaming = "true";
el.dataset.final = "false";
hook.mounted();
hook.controller.reset(partial);
hook.renderSnapshot();

assert.equal(target.querySelectorAll("iframe").length, 1);
assert.equal(target.querySelector("iframe").getAttribute("sandbox"), "");
assert.equal(target.querySelector("code").textContent, widget);
assert.equal(target.querySelector(".html-preview-status").textContent, "生成中 · 脚本暂停");
assert.equal(target.querySelector("pre").hidden, true);

// A closed block is interactive even while the rest of the reply is streaming.
const completed = partial + "```\n\nAfter";
hook.controller.reset(completed);
hook.renderSnapshot();
const frame = target.querySelector("iframe");
assert.equal(frame.getAttribute("sandbox"), "allow-scripts");
assert.equal(frame.getAttribute("referrerpolicy"), "no-referrer");
assert.match(frame.srcdoc, /default-src 'none'/);
assert.match(frame.srcdoc, /connect-src 'none'/);
assert.match(frame.srcdoc, /form-action 'none'/);
assert.ok(frame.srcdoc.includes(widget));

target.querySelector(".code-block-copy").click();
assert.equal(copied, widget);
const resize = (source, height) => window.dispatchEvent(new window.MessageEvent("message", {
  source, data: { type: "handbean:preview-height", height }
}));
resize(window, 500);
assert.equal(frame.style.height, "", "other windows cannot resize the preview");
resize(frame.contentWindow, 481.2);
assert.equal(frame.style.height, "482px");
resize(frame.contentWindow, 10000);
assert.equal(frame.style.height, "720px");
resize(frame.contentWindow, -3);
assert.equal(frame.style.height, "220px");
resize(frame.contentWindow, NaN);
assert.equal(frame.style.height, "220px");

target.querySelector('[data-html-view="source"]').click();
assert.equal(target.querySelector("pre").hidden, false);
assert.equal(frame.hidden, true);
assert.equal(target.querySelector('[data-html-view="source"]').getAttribute("aria-pressed"), "true");

hook.controller.reset(completed + " more text");
hook.renderSnapshot();
assert.equal(target.querySelector("iframe"), frame);
assert.equal(frame.hidden, true, "later text must preserve the selected view");
target.querySelector('[data-html-view="preview"]').click();
assert.equal(frame.hidden, false);

// Multiple previews, ordinary code, and HTML outside a fence remain distinct.
el.dataset.source = completed + "\n\n```html\n<h2>Second</h2>\n```\n\n```js\n42\n```\n<script>bad()</script>";
el.dataset.streaming = "false";
el.dataset.final = "true";
hook.updated();
assert.equal(target.querySelectorAll("iframe").length, 2);
assert.equal(target.querySelectorAll("script").length, 0);
assert.equal(target.querySelector("code.language-js").textContent, "42\n");
assert.equal(target.querySelectorAll(".code-block-copy").length, 3);

// A longer tilde fence inside a quoted block closes only on a matching marker.
el.dataset.source = "> ~~~~HTML\n> <p>Nested</p>\n> ~~~\n";
hook.updated();
assert.equal(target.querySelector("iframe").getAttribute("sandbox"), "");
el.dataset.source += "> ~~~~\n";
hook.updated();
assert.equal(target.querySelector("iframe").getAttribute("sandbox"), "allow-scripts");
assert.match(target.querySelector("code").textContent, /Nested/);

// A partial line must stay paused. Treating it as closed flips the toolbar
// between 隔离运行 and 脚本暂停 and reloads the iframe on every line.
el.dataset.streaming = "true";
el.dataset.final = "false";
const growing = "```widget\n<div class=\"card\">partial";
hook.controller.reset(growing);
hook.renderSnapshot();
const growingFrame = target.querySelector("iframe");
assert.equal(growingFrame.getAttribute("sandbox"), "");
assert.equal(target.querySelector(".html-preview-status").textContent, "生成中 · 脚本暂停");
hook.controller.reset(growing + " more");
hook.renderSnapshot();
assert.equal(target.querySelector("iframe"), growingFrame, "mid-line growth must not reload the preview");
assert.equal(growingFrame.getAttribute("sandbox"), "");
hook.controller.reset(growing + " more\n");
hook.renderSnapshot();
assert.equal(target.querySelector("iframe"), growingFrame);
assert.equal(target.querySelector("code").textContent, "<div class=\"card\">partial more\n");
hook.controller.reset("> ~~~~HTML\n> <p>Nest");
hook.renderSnapshot();
assert.equal(target.querySelector("iframe").getAttribute("sandbox"), "");
hook.controller.reset(growing + " more\n</div>\n```");
hook.renderSnapshot();
assert.equal(target.querySelector("iframe").getAttribute("sandbox"), "allow-scripts");

// Reconnect renders from the persisted Markdown alone, without a new store.
hook.destroyed();
target.innerHTML = '<div class="markdown-noscript-fallback"></div>';
hook.mounted();
assert.equal(target.querySelectorAll("iframe").length, 1);
el.dataset.source = "A replacement reply";
hook.updated();
assert.equal(target.querySelectorAll("iframe").length, 0);
hook.destroyed();
dom.window.close();
delete globalThis.window;
delete globalThis.document;
delete globalThis.navigator;
console.log("inline_html_feature_test passed");
