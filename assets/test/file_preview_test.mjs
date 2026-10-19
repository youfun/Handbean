import assert from "node:assert/strict";
import { JSDOM } from "jsdom";
import { FilePreview, FileTabs, FileImage } from "../js/hooks/file_preview.js";
import { disposeMermaidBlocks, renderMermaidBlocks } from "../js/streaming_markdown/mermaid_blocks.js";

const dom = new JSDOM("<!doctype html><body></body>", { url: "https://handbean.test" });
const { document, MouseEvent, KeyboardEvent } = dom.window;

function preview(source, { kind = "markdown", language = "markdown", path = "docs/readme.md", workspace = "ws-1" } = {}) {
  const root = document.createElement("div");
  Object.assign(root.dataset, { kind, language, relativePath: path, workspaceId: workspace, digest: "first" });
  root.innerHTML = `<div data-preview-source hidden></div>
    <button data-preview-mode="rendered">Rendered</button><button data-preview-mode="source">Source</button>
    <button data-preview-wrap>Wrap</button><div data-preview-target="rendered" phx-update="ignore"></div>
    <pre phx-update="ignore"><span data-preview-line-numbers aria-hidden="true"></span><code data-preview-target="source"></code></pre>`;
  root.querySelector("[data-preview-source]").textContent = source;
  document.body.append(root);
  const pushed = [];
  const hook = { ...FilePreview, el: root, pushEvent: (...args) => pushed.push(args) };
  hook.mounted();
  return { hook, root, pushed, rendered: root.querySelector("[data-preview-target='rendered']"), code: root.querySelector("[data-preview-target='source']") };
}
function click(el, options = {}) {
  const event = new MouseEvent("click", { bubbles: true, cancelable: true, ...options });
  el.dispatchEvent(event);
  return event;
}

const view = preview("# Title\n\n**safe**\n\n```html\n<script>window.executed = true</script>\n```\n\n<script>window.executed = true</script>\n<img src=x onerror=alert(1)>");
assert.equal(view.rendered.querySelector("h1").textContent, "Title");
assert.equal(view.rendered.querySelector("strong").textContent, "safe");
assert.equal(view.rendered.querySelectorAll("script, iframe, img, object, embed, button").length, 0);
assert.match(view.rendered.querySelector("pre code").textContent, /<script>/);
assert.equal(dom.window.executed, undefined);
assert.equal(view.rendered.hidden, false);
assert.equal(view.code.closest("pre").hidden, true);
click(view.root.querySelector("[data-preview-mode='source']"));
assert.equal(view.rendered.hidden, true);
assert.equal(view.code.closest("pre").hidden, false);
assert.equal(view.root.querySelector("[data-preview-mode='source']").getAttribute("aria-pressed"), "true");
assert.equal(view.code.textContent, view.root.querySelector("[data-preview-source]").textContent);
const wrap = view.root.querySelector("[data-preview-wrap]");
assert.equal(wrap.getAttribute("aria-pressed"), "false");
click(wrap);
assert.equal(wrap.getAttribute("aria-pressed"), "true");
view.hook.updated();
assert.equal(wrap.getAttribute("aria-pressed"), "true");
assert.equal(view.rendered.hidden, true);

// An unrelated LiveView patch preserves both managed DOMs and their selection.
const heading = view.rendered.querySelector("h1");
const highlighted = view.code.firstChild;
view.hook.updated();
assert.equal(view.rendered.querySelector("h1"), heading);
assert.equal(view.code.firstChild, highlighted);
view.root.dataset.digest = "second";
view.root.querySelector("[data-preview-source]").textContent = "# Changed";
view.hook.updated();
assert.equal(view.rendered.querySelector("h1").textContent, "Changed");
assert.equal(view.code.textContent, "# Changed");
const replacement = document.createElement("div");
replacement.dataset.previewTarget = "rendered";
view.rendered.replaceWith(replacement);
view.hook.updated();
assert.equal(replacement.querySelector("h1").textContent, "Changed");

const links = preview("[local](../src/a%20b.ex#L2) [external](https://example.com/x) [root](/etc/passwd) [escape](../../secret) [protocol](//evil.test/x) [drive](C:/file) [encoded](%2e%2e/%2e%2e/secret) [nested](%252e%252e/secret) [slash](..%5csecret) [bad](file:///secret) [js](javascript:alert%281%29)");
const local = links.rendered.querySelector("a[href='../src/a%20b.ex#L2']");
assert.ok(local);
assert.equal(click(local).defaultPrevented, true);
assert.deepEqual(links.pushed, [["select_workspace_file", { path: "src/a b.ex" }]]);
assert.equal(click(local, { ctrlKey: true }).defaultPrevented, true);
const external = links.rendered.querySelector("a[href='https://example.com/x']");
assert.equal(external.target, "_blank");
assert.equal(external.rel, "noopener noreferrer");
assert.equal(click(external).defaultPrevented, false);
assert.equal(links.rendered.querySelectorAll("a[href]").length, 2);
// Defense in depth if an application patch inserts a non-markdown local href.
const forged = document.createElement("a");
forged.href = "../../secret";
links.rendered.append(forged);
const count = links.pushed.length;
assert.equal(click(forged).defaultPrevented, true);
assert.equal(links.pushed.length, count);
links.hook.destroyed();
click(local);
assert.equal(links.pushed.length, count);

const images = preview("![local](../img/a%20b.png) ![remote](https://evil.test/track.png) ![protocol](//evil.test/a.png) ![absolute](/img/a.png) ![escape](../../secret.png) ![data](data:image/png;base64,AAAA) ![encoded](%2f%2fevil.test/a.png)");
const imgs = images.rendered.querySelectorAll("img");
assert.equal(imgs.length, 1);
assert.equal(imgs[0].getAttribute("src"), "/workspace-files/ws-1/img/a%20b.png");
assert.equal(imgs[0].alt, "local");
assert.ok(images.rendered.textContent.includes("remote"));
assert.equal(preview("![x](a.png)", { workspace: "" }).rendered.querySelector("img"), null);
const context = preview("![x](a.png)", { workspace: "ws /?#" });
assert.equal(context.rendered.querySelector("img").getAttribute("src"), "/workspace-files/ws%20%2F%3F%23/docs/a.png");
context.root.dataset.relativePath = "other/readme.md";
context.root.dataset.workspaceId = "new";
context.hook.updated();
assert.equal(context.rendered.querySelector("img").getAttribute("src"), "/workspace-files/new/other/a.png");

const code = preview("const value = '<img src=x onerror=alert(1)>';", { kind: "code", language: "javascript" });
assert.equal(code.code.textContent, "const value = '<img src=x onerror=alert(1)>';");
assert.equal(code.code.querySelector("img"), null);
assert.equal(code.code.closest("pre").hidden, false);
assert.equal(code.root.querySelector("[data-preview-wrap]").getAttribute("aria-pressed"), "false");
assert.equal(preview("<script>unsafe</script>", { kind: "code", language: "__proto__" }).code.textContent, "<script>unsafe</script>");

// The separate gutter never splits highlighted multiline tokens. Empty files
// and trailing newlines retain the same logical line count as source text.
const multiline = preview("/* first\nsecond */\nconst value = 1;\n", { kind: "code", language: "javascript" });
const gutter = multiline.root.querySelector("[data-preview-line-numbers]");
assert.equal(gutter.textContent, "1\n2\n3\n4");
assert.equal(gutter.getAttribute("aria-hidden"), "true");
assert.equal(gutter.hidden, false);
assert.equal(multiline.code.querySelector(".hljs-comment").textContent, "/* first\nsecond */");
const comment = multiline.code.querySelector(".hljs-comment");
click(multiline.root.querySelector("[data-preview-wrap]"));
assert.equal(gutter.hidden, true);
assert.equal(multiline.code.querySelector(".hljs-comment"), comment);
multiline.hook.updated();
assert.equal(gutter.hidden, true);
click(multiline.root.querySelector("[data-preview-wrap]"));
assert.equal(gutter.hidden, false);
multiline.root.dataset.digest = "new-lines";
multiline.root.querySelector("[data-preview-source]").textContent = "one\r\ntwo\rthree";
multiline.hook.updated();
assert.equal(gutter.textContent, "1\n2\n3");
assert.equal(preview("", { kind: "code" }).root.querySelector("[data-preview-line-numbers]").textContent, "1");

// Fragment links only navigate headings within this preview, with stable,
// collision-free slugs and no document URL change or server file-selection event.
const anchorSource = "# Hello *World*!\n\n## Hello World!\n\n### Hello World-1\n\n## 中文 标题\n\n## !!!\n\n[one](#hello-world) [two](#hello-world-1) [collision](#hello-world-1-1) [unicode](#%E4%B8%AD%E6%96%87-%E6%A0%87%E9%A2%98) [empty](#section) [missing](#missing) [top](#)";
const anchors = preview(anchorSource);
const headings = [...anchors.rendered.querySelectorAll("h1, h2, h3")];
assert.equal(new Set(headings.map(h => h.id)).size, headings.length);
const headingIds = headings.map(h => h.id);
const scrolls = [];
headings.forEach(heading => { heading.scrollIntoView = () => scrolls.push(heading); });
anchors.rendered.scrollIntoView = () => scrolls.push(anchors.rendered);
for (const [index, link] of [...anchors.rendered.querySelectorAll("a")].entries()) {
  assert.equal(click(link).defaultPrevented, true);
  if (index < 5) {
    assert.equal(scrolls.at(-1), headings[index]);
    assert.equal(document.activeElement, headings[index]);
  }
}
assert.equal(scrolls.length, 6);
assert.equal(scrolls.at(-1), anchors.rendered);
assert.deepEqual(anchors.pushed, []);
assert.equal(dom.window.location.hash, "");
const otherPreview = preview(anchorSource);
const foreignHeading = otherPreview.rendered.querySelector("h1");
foreignHeading.scrollIntoView = () => assert.fail("anchor escaped its preview");
click(anchors.rendered.querySelector("a"));
assert.equal(scrolls.at(-1), headings[0]);
const malformedFragment = document.createElement("a");
malformedFragment.setAttribute("href", "#%E0%A4%A");
anchors.rendered.append(malformedFragment);
const previousScrolls = scrolls.length;
assert.equal(click(malformedFragment).defaultPrevented, true);
assert.equal(scrolls.length, previousScrolls);
anchors.root.dataset.digest = "rerender-anchors";
anchors.hook.updated();
assert.deepEqual([...anchors.rendered.querySelectorAll("h1, h2, h3")].map(h => h.id), headingIds);
const refreshed = anchors.rendered.querySelector("h1");
refreshed.scrollIntoView = () => scrolls.push(refreshed);
click(anchors.rendered.querySelector("a"));
assert.equal(scrolls.at(-1), refreshed);

// Tab navigation activates exactly once; click activation stays with LiveView.
const tabs = document.createElement("div");
tabs.innerHTML = ["a.ex", "b.ex", "c.ex"].map((path, i) => `<button role="tab" data-relative-path="${path}" aria-selected="${i === 1}">${path}</button><button data-close-tab="${path}">Close</button>`).join("");
document.body.append(tabs);
const activated = [];
const scrolled = [];
for (const tab of tabs.querySelectorAll("[role='tab']")) tab.scrollIntoView = () => scrolled.push(tab.dataset.relativePath);
const tabHook = { ...FileTabs, el: tabs, pushEvent: (...args) => activated.push(args) };
tabHook.mounted();
assert.deepEqual(scrolled, ["b.ex"]);
const tabButtons = [...tabs.querySelectorAll("[role='tab']")];
function key(tab, name) {
  const event = new KeyboardEvent("keydown", { key: name, bubbles: true, cancelable: true });
  tab.dispatchEvent(event);
  return event;
}
assert.equal(key(tabButtons[1], "ArrowRight").defaultPrevented, true);
assert.equal(document.activeElement, tabButtons[2]);
assert.deepEqual(activated.pop(), ["select_editor_file", { path: "c.ex" }]);
key(tabButtons[2], "ArrowRight");
assert.equal(document.activeElement, tabButtons[0]);
key(tabButtons[0], "ArrowLeft");
assert.equal(document.activeElement, tabButtons[2]);
key(tabButtons[2], "Home");
assert.equal(document.activeElement, tabButtons[0]);
key(tabButtons[0], "End");
assert.equal(document.activeElement, tabButtons[2]);
assert.equal(key(tabButtons[2], "Enter").defaultPrevented, false);
const beforeClick = activated.length;
click(tabButtons[0]);
assert.equal(activated.length, beforeClick);
click(tabs.querySelector("[data-close-tab='b.ex']"));
tabButtons[1].remove();
tabHook.updated();
assert.equal(document.activeElement, tabButtons[2]);
assert.equal(activated.length, beforeClick);
click(tabs.querySelector("[data-close-tab='c.ex']"));
tabButtons[2].remove();
tabHook.updated();
assert.equal(document.activeElement, tabButtons[0]);
tabHook.destroyed();
key(tabButtons[0], "Home");
assert.equal(activated.length, beforeClick);
// Image errors (including rejected routes) use the template's localized status;
// cached images and replacement nodes follow the same load/error behavior.
function imagePreview({ complete = false, naturalWidth = 0 } = {}) {
  const root = document.createElement("div");
  root.innerHTML = '<img src="/workspace-files/ws-1/image.png"><p data-preview-image-error hidden>Localized failure</p>';
  document.body.append(root);
  const image = root.querySelector("img");
  Object.defineProperties(image, {
    complete: { configurable: true, get: () => complete },
    naturalWidth: { configurable: true, get: () => naturalWidth }
  });
  const hook = { ...FileImage, el: root };
  hook.mounted();
  return { hook, root, image, error: root.querySelector("[data-preview-image-error]") };
}
function imageEvent(image, type) {
  image.dispatchEvent(new dom.window.Event(type));
}
const picture = imagePreview();
assert.equal(picture.image.hidden, true);
assert.equal(picture.error.hidden, true);
imageEvent(picture.image, "load");
assert.equal(picture.image.hidden, false);
assert.equal(picture.error.hidden, true);
imageEvent(picture.image, "error");
assert.equal(picture.image.hidden, true);
assert.equal(picture.error.hidden, false);
assert.equal(picture.error.getAttribute("role"), "status");
assert.equal(picture.error.textContent, "Localized failure");
picture.hook.updated();
assert.equal(picture.error.hidden, false);
picture.image.src = "/workspace-files/ws-1/retry.png";
picture.hook.updated();
assert.equal(picture.error.hidden, true);
assert.equal(picture.image.hidden, true);
imageEvent(picture.image, "load");
assert.equal(picture.image.hidden, false);

// New nodes with the same URL still need fresh listeners and error state.
imageEvent(picture.image, "error");
const newImage = picture.image.cloneNode();
Object.defineProperty(newImage, "complete", { get: () => false });
picture.image.replaceWith(newImage);
picture.hook.updated();
assert.equal(picture.error.hidden, true);
assert.equal(newImage.hidden, true);
imageEvent(picture.image, "error");
assert.equal(picture.error.hidden, true);
imageEvent(newImage, "load");
assert.equal(newImage.hidden, false);
picture.hook.destroyed();
imageEvent(newImage, "error");
assert.equal(newImage.hidden, false);
assert.equal(picture.error.hidden, true);

const cachedImage = imagePreview({ complete: true, naturalWidth: 128 });
assert.equal(cachedImage.image.hidden, false);
assert.equal(cachedImage.error.hidden, true);
const brokenImage = imagePreview({ complete: true });
assert.equal(brokenImage.image.hidden, true);
assert.equal(brokenImage.error.hidden, false);
// LiveView may replace just the status node in an unrelated update.
const newError = brokenImage.error.cloneNode(true);
newError.hidden = true;
brokenImage.error.replaceWith(newError);
brokenImage.hook.updated();
assert.equal(newError.hidden, false);
brokenImage.image.remove();
brokenImage.hook.updated();
assert.equal(newError.hidden, true);
imageEvent(brokenImage.image, "error");
assert.equal(newError.hidden, true);
for (const hook of [cachedImage.hook, brokenImage.hook]) hook.destroyed();

const diagram = preview("```mermaid\ngraph TD\n  A-->B\n```\n");
assert.ok(diagram.rendered.querySelector("[data-mermaid-preview]"));
assert.match(diagram.rendered.querySelector("code.language-mermaid")?.textContent ?? "", /A-->B/);
const oldRendered = diagram.rendered;
const mermaidTarget = document.createElement("div");
mermaidTarget.dataset.previewTarget = "rendered";
oldRendered.replaceWith(mermaidTarget);
diagram.hook.updated();
let created = 0;
renderMermaidBlocks(oldRendered, {
  width: 640,
  decodeImage: false,
  createWorker: () => {
    created += 1;
    return { postMessage() {}, terminate() {} };
  },
  readPalette: () => ({ "--pele-bg": "#ffffff" })
});
assert.equal(created, 1, "replaced preview target must release the previous diagram");
disposeMermaidBlocks(oldRendered);
diagram.hook.destroyed();

dom.window.close();
console.log("file_preview_test passed");
