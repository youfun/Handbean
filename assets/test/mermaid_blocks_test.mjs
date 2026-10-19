import assert from "node:assert/strict";
import { JSDOM } from "jsdom";
import { injectCopyButtons } from "../js/streaming_markdown/code_block_copy.js";
import { renderMarkdown } from "../js/streaming_markdown/render_markdown.js";
import { patchMarkdownDom } from "../js/streaming_markdown/patch_markdown_dom.js";
import {
  decorateMermaidBlocks,
  disposeMermaidBlocks,
  handleMermaidPreviewClick,
  isMermaidCode,
  mermaidSource,
  renderMermaidBlocks
} from "../js/streaming_markdown/mermaid_blocks.js";

const SVG = '<svg xmlns="http://www.w3.org/2000/svg" width="40" height="20"><rect width="40" height="20"/></svg>';
const SOURCE = "```mermaid\ngraph TD\n  A-->B\n```\n";

const dom = new JSDOM("<!doctype html><html><body></body></html>");
globalThis.window = dom.window;
globalThis.document = dom.window.document;
globalThis.Node = dom.window.Node;
globalThis.MutationObserver = dom.window.MutationObserver;
globalThis.URL = URL;

function after(fn) {
  process.on("exit", fn);
}

after(() => {
  delete globalThis.window;
  delete globalThis.document;
  delete globalThis.Node;
  delete globalThis.MutationObserver;
  delete globalThis.URL;
});

function flush() {
  return new Promise((resolve) => setTimeout(resolve, 0));
}

function fakeWorker(handler) {
  const worker = {
    postMessage(data) {
      queueMicrotask(() => {
        if (worker.dead) return;
        const reply = handler(data, worker);
        if (reply !== undefined) worker.onmessage?.({ data: reply });
      });
    },
    terminate() {
      worker.dead = true;
    }
  };
  return worker;
}

function okReply(data) {
  return { id: data.id, ok: true, svg: SVG, width: 40, height: 20 };
}

function mount(markdown = SOURCE) {
  const root = document.createElement("div");
  root.innerHTML = injectCopyButtons(renderMarkdown(markdown));
  decorateMermaidBlocks(root);
  document.body.appendChild(root);
  return root;
}

function diagramOptions(worker, extra = {}) {
  return {
    width: 640,
    decodeImage: false,
    createWorker: () => worker,
    readPalette: () => ({ "--pele-bg": "#ffffff", "--pele-fg": "#111111" }),
    ...extra
  };
}

{
  const root = mount();
  const code = root.querySelector("code");
  assert.equal(isMermaidCode(code), true);
  assert.equal(mermaidSource(code), "graph TD\n  A-->B");
  assert.equal(isMermaidCode(document.createElement("code")), false);
  root.remove();
}

{
  let posts = 0;
  const worker = fakeWorker((data) => {
    posts += 1;
    return okReply(data);
  });
  const root = mount();
  renderMermaidBlocks(root, diagramOptions(worker));
  await flush();

  const img = root.querySelector(".mermaid-diagram img");
  assert.equal(root.querySelector("[data-mermaid-preview]").dataset.mermaidPreview, "ready");
  assert.equal(img?.alt, "Mermaid 图表");
  assert.match(img.src, /^blob:/);
  assert.equal(root.querySelector("pre").hidden, true);
  assert.equal(root.querySelector(".mermaid-diagram").innerHTML.includes("<svg"), false);
  assert.equal(posts, 1);

  renderMermaidBlocks(root, diagramOptions(worker));
  await flush();
  assert.equal(posts, 1, "already attached blocks must not rerun");

  handleMermaidPreviewClick({ target: root.querySelector('[data-mermaid-view="source"]') });
  assert.equal(root.querySelector("pre").hidden, false);
  assert.equal(root.querySelector(".mermaid-diagram").hidden, true);
  assert.equal(root.querySelector('[data-mermaid-view="source"]').getAttribute("aria-pressed"), "true");

  disposeMermaidBlocks(root);
  root.remove();
}

{
  const worker = fakeWorker((data) => ({ id: data.id, ok: false, reason: "syntax" }));
  const root = mount("```mermaid\nbad\n```\n");
  renderMermaidBlocks(root, diagramOptions(worker));
  await flush();
  assert.equal(root.querySelector(".mermaid-diagram"), null);
  assert.equal(root.querySelector(".html-preview-status")?.textContent, "图表语法无效");
  assert.equal(root.querySelector("pre").hidden, false);
  renderMermaidBlocks(root, diagramOptions(worker));
  await flush();
  disposeMermaidBlocks(root);
  root.remove();
}

{
  const worker = {
    postMessage(data) {
      worker.last = data;
    },
    terminate() {
      worker.dead = true;
    }
  };
  const root = mount();
  renderMermaidBlocks(root, diagramOptions(worker));
  await flush();
  disposeMermaidBlocks(root);
  assert.equal(worker.dead, true);
  worker.onmessage?.({ data: { id: worker.last.id, ok: true, svg: SVG, width: 40, height: 20 } });
  assert.equal(root.querySelector("img"), null);
  root.remove();
}

{
  const worker = fakeWorker(() => undefined);
  const root = mount();
  renderMermaidBlocks(root, diagramOptions(worker, { timeoutMs: 20 }));
  await new Promise((resolve) => setTimeout(resolve, 50));
  assert.equal(root.querySelector(".html-preview-status")?.textContent, "图表渲染超时");
  assert.equal(worker.dead, true);
  disposeMermaidBlocks(root);
  root.remove();
}

{
  let posts = 0;
  let palette = { "--pele-bg": "#ffffff" };
  const worker = fakeWorker((data) => {
    posts += 1;
    return okReply(data);
  });
  const root = mount();
  renderMermaidBlocks(root, diagramOptions(worker, { readPalette: () => palette }));
  await flush();
  const firstSrc = root.querySelector("img").src;
  palette = { "--pele-bg": "#000000" };
  document.documentElement.setAttribute("data-theme", "dark");
  await flush();
  assert.equal(posts, 1, "theme changes must not rerun Pele");
  assert.match(root.querySelector("img").src, /^blob:/);
  assert.notEqual(root.querySelector("img").src, firstSrc);
  disposeMermaidBlocks(root);
  root.remove();
}

{
  const loads = [];
  function Image() {
    this.onload = null;
    this.onerror = null;
    Object.defineProperty(this, "src", {
      set(url) {
        this._src = url;
        loads.push(this);
      },
      get() {
        return this._src;
      }
    });
  }
  let palette = { "--pele-bg": "#ffffff" };
  const worker = fakeWorker((data) => okReply(data));
  const root = mount();
  renderMermaidBlocks(root, {
    width: 640,
    createWorker: () => worker,
    readPalette: () => palette,
    Image
  });
  await flush();
  await flush();
  assert.equal(loads.length, 1);
  loads[0].onload();
  await flush();
  const light = root.querySelector("img").src;
  palette = { "--pele-bg": "#000000" };
  document.documentElement.setAttribute("data-theme", "dark");
  await flush();
  assert.equal(loads.length, 2);
  palette = { "--pele-bg": "#ffffff" };
  document.documentElement.setAttribute("data-theme", "light");
  await flush();
  assert.equal(loads.length, 3);
  loads[1].onload();
  await flush();
  assert.equal(root.querySelector("img").src, light, "stale theme decode must not mount");
  loads[2].onload();
  await flush();
  assert.match(root.querySelector("img").src, /^blob:/);
  assert.equal(root.querySelector("[data-mermaid-preview]").dataset.mermaidPreview, "ready");
  disposeMermaidBlocks(root);
  root.remove();
}

{
  let posts = 0;
  let width = 640;
  const observers = [];
  const root = mount();
  const wrapper = root.querySelector("[data-mermaid-preview]");
  Object.defineProperty(wrapper, "clientWidth", { configurable: true, get: () => width });
  renderMermaidBlocks(root, {
    decodeImage: false,
    createWorker: () => fakeWorker((data) => {
      posts += 1;
      return okReply(data);
    }),
    readPalette: () => ({ "--pele-bg": "#ffffff" }),
    ResizeObserver: class {
      constructor(callback) {
        this.callback = callback;
        observers.push(this);
      }
      observe() {}
      disconnect() {}
    }
  });
  await flush();
  assert.equal(posts, 1);
  observers[0].callback();
  await flush();
  assert.equal(posts, 1, "same width must not rerender");
  width = 800;
  observers[0].callback();
  await flush();
  assert.equal(posts, 2);
  disposeMermaidBlocks(root);
  root.remove();
}

{
  const worker = fakeWorker((data) => okReply(data));
  const root = mount();
  renderMermaidBlocks(root, diagramOptions(worker));
  await flush();
  const img = root.querySelector("img");
  const incoming = document.createElement("div");
  incoming.innerHTML = injectCopyButtons(renderMarkdown(SOURCE));
  decorateMermaidBlocks(incoming);
  patchMarkdownDom(root, incoming);
  assert.equal(root.querySelector("img"), img, "same source must keep the rendered image");
  disposeMermaidBlocks(root);
  root.remove();
}

{
  const worker = {
    postMessage() {},
    terminate() {
      worker.dead = true;
    }
  };
  const root = mount();
  renderMermaidBlocks(root, diagramOptions(worker));
  await flush();
  const incoming = document.createElement("div");
  incoming.innerHTML = "<p>gone</p>";
  patchMarkdownDom(root, incoming);
  assert.equal(worker.dead, true);
  assert.equal(root.querySelector("[data-mermaid-preview]"), null);
  root.remove();
}

console.log("mermaid_blocks_test passed");
