const MERMAID_LANG = /(?:^|\s)language-mermaid(?:\s|$)/;
const SOURCE_LIMIT = 50_000;
const OUTPUT_LIMIT = 1_048_576;
const MAX_DIMENSION = 8192;
const MAX_PIXELS = 8_000_000;
const DEFAULT_TIMEOUT_MS = 4000;
const PALETTE_KEYS = {
  "--pele-bg": "--color-surface",
  "--pele-fg": "--color-text-primary",
  "--pele-muted": "--color-text-secondary",
  "--pele-line": "--color-text-primary",
  "--pele-surface": "--color-surface-hover",
  "--pele-surface-alt": "--color-surface-active",
  "--pele-border": "--color-border",
  "--pele-accent": "--color-primary",
  "--pele-critical": "--color-error"
};
const PALETTE_NAME = /^--pele-(?:bg|fg|muted|line|surface|surface-alt|border|accent|critical)$/;
const COLOR_VALUE = /^(?:#(?:[\da-f]{3,4}|[\da-f]{6}|[\da-f]{8})|rgba?\([\d\s,./%]+\))$/i;
const REASONS = new Set(["syntax", "unsupported", "limit", "worker", "capability", "deadline", "image"]);
const MESSAGES = {
  syntax: "图表语法无效",
  unsupported: "图表类型不受支持",
  limit: "图表超出限制",
  worker: "图表渲染失败",
  capability: "当前环境无法渲染图表",
  deadline: "图表渲染超时",
  image: "图表显示失败"
};

const blocks = new WeakMap();
const waiting = [];
let worker = null;
let inflight = null;
let serial = 0;

export function isMermaidCode(code) {
  return MERMAID_LANG.test(code?.className || "");
}

export function mermaidSource(code) {
  return String(code?.textContent ?? "").replace(/\n$/, "");
}

export function decorateMermaidBlocks(fragment) {
  if (!fragment?.querySelectorAll) return;
  const document = fragment.ownerDocument || globalThis.document;
  if (!document?.createElement) return;

  for (const code of fragment.querySelectorAll("pre > code")) {
    if (!isMermaidCode(code)) continue;
    let wrapper = code.closest(".code-block-wrapper");
    if (!wrapper) {
      const pre = code.parentElement;
      if (!pre) continue;
      wrapper = document.createElement("div");
      wrapper.className = "code-block-wrapper";
      pre.replaceWith(wrapper);
      wrapper.append(pre);
    }
    if (wrapper.dataset.mermaidPreview) continue;

    wrapper.dataset.mermaidPreview = "waiting";
    wrapper.dataset.mermaidShowing = "diagram";

    const toolbar = document.createElement("div");
    toolbar.className = "html-preview-toolbar";

    const label = document.createElement("span");
    label.className = "html-preview-label";
    label.textContent = "Mermaid";

    const diagramBtn = document.createElement("button");
    diagramBtn.type = "button";
    diagramBtn.dataset.mermaidView = "diagram";
    diagramBtn.setAttribute("aria-pressed", "true");
    diagramBtn.textContent = "图";

    const sourceBtn = document.createElement("button");
    sourceBtn.type = "button";
    sourceBtn.dataset.mermaidView = "source";
    sourceBtn.setAttribute("aria-pressed", "false");
    sourceBtn.textContent = "源码";

    const status = document.createElement("span");
    status.className = "html-preview-status";
    status.setAttribute("role", "status");
    status.textContent = "正在渲染图表";

    toolbar.append(label, diagramBtn, sourceBtn, status);
    wrapper.prepend(toolbar);
  }
}

export function handleMermaidPreviewClick(event) {
  const target = event.target;
  if (typeof target?.closest !== "function") return;
  const button = target.closest("[data-mermaid-view]");
  const wrapper = button?.closest("[data-mermaid-preview]");
  if (!wrapper || wrapper.dataset.mermaidPreview === "failed") return;
  wrapper.dataset.mermaidShowing = button.dataset.mermaidView;
  const block = blocks.get(wrapper);
  if (block) block.applyView();
  else applyMermaidView(wrapper);
}

export function disposeMermaidBlock(wrapper) {
  const block = blocks.get(wrapper);
  if (block) block.dispose();
}

export function disposeMermaidBlocks(root) {
  if (!root?.querySelectorAll) return;
  if (root.dataset?.mermaidPreview) disposeMermaidBlock(root);
  for (const wrapper of root.querySelectorAll("[data-mermaid-preview]")) {
    disposeMermaidBlock(wrapper);
  }
}

export function renderMermaidBlocks(root, options = {}) {
  if (!root?.querySelectorAll) return;
  for (const wrapper of root.querySelectorAll("[data-mermaid-preview]")) {
    if (blocks.has(wrapper)) continue;
    if (wrapper.dataset.mermaidPreview === "failed") continue;
    const block = new Block(wrapper, options);
    blocks.set(wrapper, block);
  }
}

function applyMermaidView(wrapper) {
  const view = wrapper.dataset.mermaidShowing || "diagram";
  const failed = wrapper.dataset.mermaidPreview === "failed";
  const diagram = wrapper.querySelector(".mermaid-diagram");
  const pre = wrapper.querySelector("pre");
  const showSource = failed || view === "source" || !diagram;
  if (pre) pre.hidden = !showSource;
  if (diagram) diagram.hidden = showSource;
  for (const button of wrapper.querySelectorAll("[data-mermaid-view]")) {
    button.setAttribute("aria-pressed", String(
      button.dataset.mermaidView === (showSource ? "source" : "diagram")
    ));
  }
}

class Block {
  constructor(wrapper, options) {
    this.wrapper = wrapper;
    this.options = options;
    this.generation = 0;
    this.lastWidth = 0;
    this.disposed = false;
    this.failed = false;
    this.template = null;
    this.url = null;
    this.pendingUrl = null;
    this.paletteKey = "";
    this.loadingKey = "";
    this.imageToken = 0;
    this.timeoutMs = Number.isFinite(options.timeoutMs) ? options.timeoutMs : DEFAULT_TIMEOUT_MS;
    this.resize = null;
    this.theme = null;
    this.watch();
    this.schedule();
  }

  watch() {
    const ResizeObserverCtor = this.options.ResizeObserver || globalThis.ResizeObserver;
    if (typeof ResizeObserverCtor === "function" && !Number.isFinite(this.options.width)) {
      this.resize = new ResizeObserverCtor(() => this.schedule());
      this.resize.observe(this.wrapper);
    }

    const document = this.wrapper.ownerDocument || globalThis.document;
    const root = document?.documentElement;
    if (root && typeof MutationObserver === "function") {
      this.theme = new MutationObserver(() => this.applyTheme());
      this.theme.observe(root, { attributes: true, attributeFilter: ["class", "data-theme", "style"] });
    }
  }

  measure() {
    if (Number.isFinite(this.options.width) && this.options.width > 0) {
      return Math.floor(this.options.width);
    }
    return Math.floor(this.wrapper.clientWidth || 0);
  }

  schedule() {
    if (this.disposed || this.failed) return;
    const source = mermaidSource(this.wrapper.querySelector("code"));
    if (source.length > SOURCE_LIMIT) {
      this.fail("limit");
      return;
    }
    const width = this.measure();
    if (width <= 0) return;
    if (width === this.lastWidth && (this.template || waiting.includes(this) || inflight?.block === this)) {
      return;
    }
    this.lastWidth = width;
    this.generation += 1;
    enqueue(this);
  }

  input() {
    return {
      source: mermaidSource(this.wrapper.querySelector("code")),
      width: this.lastWidth,
      fonts: readFonts(this.wrapper)
    };
  }

  readPalette() {
    if (typeof this.options.readPalette === "function") return this.options.readPalette(this.wrapper);
    return readPalette(this.wrapper);
  }

  accept(data) {
    if (typeof data.svg !== "string" || data.svg.length > OUTPUT_LIMIT) {
      this.fail("limit");
      return;
    }
    const width = data.width;
    const height = data.height;
    if (
      !Number.isFinite(width) ||
      !Number.isFinite(height) ||
      width <= 0 ||
      height <= 0 ||
      width > MAX_DIMENSION ||
      height > MAX_DIMENSION ||
      width * height > MAX_PIXELS
    ) {
      this.fail("limit");
      return;
    }
    this.template = { svg: data.svg, width, height };
    void this.showImage(this.template, this.readPalette());
  }

  applyTheme() {
    if (this.disposed || this.failed || !this.template) return;
    const palette = this.readPalette();
    const key = JSON.stringify(palette);
    if (key === this.paletteKey && !this.pendingUrl) return;
    if (key === this.loadingKey) return;
    void this.showImage(this.template, palette);
  }

  async showImage(template, palette) {
    const token = (this.imageToken += 1);
    this.loadingKey = JSON.stringify(palette);
    let url;
    try {
      const blob = new Blob(
        [diagramDocument(template.svg, template.width, template.height, palette)],
        { type: "image/svg+xml" }
      );
      if (blob.size > OUTPUT_LIMIT) {
        if (token === this.imageToken) this.fail("limit");
        return;
      }
      url = URL.createObjectURL(blob);
      this.pendingUrl = url;
      if (this.options.decodeImage !== false) await decodeImage(url, this.options);
    } catch {
      if (this.pendingUrl === url) this.pendingUrl = null;
      if (url) URL.revokeObjectURL(url);
      if (token === this.imageToken && !this.disposed && !this.failed) this.fail("image");
      return;
    }

    if (this.disposed || this.failed || token !== this.imageToken) {
      if (this.pendingUrl === url) this.pendingUrl = null;
      URL.revokeObjectURL(url);
      return;
    }

    this.pendingUrl = null;
    this.paletteKey = this.loadingKey;
    this.mountImage(url, template);
  }

  mountImage(url, template) {
    const document = this.wrapper.ownerDocument;
    let host = this.wrapper.querySelector(".mermaid-diagram");
    if (!host) {
      host = document.createElement("div");
      host.className = "mermaid-diagram";
      this.wrapper.appendChild(host);
    }
    let img = host.querySelector("img");
    if (!img) {
      img = document.createElement("img");
      img.alt = "Mermaid 图表";
      host.appendChild(img);
    }
    img.width = template.width;
    img.height = template.height;
    const previous = this.url;
    this.url = url;
    img.src = url;
    if (previous && previous !== url) URL.revokeObjectURL(previous);
    this.wrapper.dataset.mermaidPreview = "ready";
    const status = this.wrapper.querySelector(".html-preview-status");
    if (status) status.textContent = "";
    this.applyView();
  }

  applyView() {
    applyMermaidView(this.wrapper);
  }

  fail(reason) {
    if (this.disposed || this.failed) return;
    this.failed = true;
    this.imageToken += 1;
    this.loadingKey = "";
    cancel(this);
    const status = this.wrapper.querySelector(".html-preview-status");
    if (status) status.textContent = MESSAGES[reason] || MESSAGES.worker;
    this.wrapper.dataset.mermaidPreview = "failed";
    this.wrapper.dataset.mermaidShowing = "source";
    this.revoke();
    this.wrapper.querySelector(".mermaid-diagram")?.remove();
    this.applyView();
  }

  dispose() {
    if (this.disposed) return;
    this.disposed = true;
    this.failed = true;
    this.resize?.disconnect();
    this.theme?.disconnect();
    this.resize = null;
    this.theme = null;
    this.imageToken += 1;
    this.loadingKey = "";
    cancel(this);
    this.revoke();
    blocks.delete(this.wrapper);
  }

  revoke() {
    if (this.pendingUrl) URL.revokeObjectURL(this.pendingUrl);
    this.pendingUrl = null;
    if (this.url) URL.revokeObjectURL(this.url);
    this.url = null;
    this.template = null;
  }
}

function enqueue(block) {
  if (block.disposed || block.failed) return;
  if (inflight?.block === block && inflight.generation === block.generation) return;
  if (waiting.includes(block)) return;
  waiting.push(block);
  pump();
}

function cancel(block) {
  const index = waiting.indexOf(block);
  if (index !== -1) waiting.splice(index, 1);
  if (inflight?.block === block) {
    clearTimeout(inflight.timer);
    inflight = null;
    killWorker();
    pump();
  }
}

function pump() {
  if (inflight) return;
  const block = waiting.shift();
  if (!block) {
    killWorker();
    return;
  }
  if (block.disposed || block.failed) {
    pump();
    return;
  }
  start(block);
}

function start(block) {
  const input = block.input();
  if (!input.source || input.width <= 0) {
    pump();
    return;
  }
  if (input.source.length > SOURCE_LIMIT) {
    block.fail("limit");
    pump();
    return;
  }

  let instance;
  try {
    instance = ensureWorker(block.options);
  } catch {
    block.fail("capability");
    pump();
    return;
  }
  if (!instance) {
    block.fail("capability");
    pump();
    return;
  }

  const id = (serial += 1);
  const generation = block.generation;
  const timer = setTimeout(() => {
    if (inflight?.id !== id) return;
    inflight = null;
    killWorker();
    block.fail("deadline");
    pump();
  }, block.timeoutMs);

  inflight = { id, block, generation, timer };
  instance.postMessage({ id, ...input });
}

function ensureWorker(options) {
  if (worker) return worker;
  const create = options.createWorker || defaultCreateWorker;
  if (typeof create !== "function") return null;
  const instance = create();
  if (!instance) return null;
  instance.onmessage = onWorkerMessage;
  instance.onerror = onWorkerError;
  worker = instance;
  return worker;
}

function defaultCreateWorker() {
  if (typeof Worker === "undefined") return null;
  return new Worker("/assets/js/streaming_markdown/pele.worker.js");
}

function onWorkerMessage(event) {
  const data = event.data;
  if (!inflight || data?.id !== inflight.id) return;
  const { block, generation, timer } = inflight;
  clearTimeout(timer);
  inflight = null;
  if (block.disposed || block.generation !== generation) {
    if (!block.disposed && !block.failed && !waiting.includes(block)) enqueue(block);
    pump();
    return;
  }
  if (!data || data.ok !== true) {
    block.fail(REASONS.has(data?.reason) ? data.reason : "worker");
    pump();
    return;
  }
  block.accept(data);
  pump();
}

function onWorkerError() {
  if (!inflight) {
    killWorker();
    return;
  }
  const { block, timer } = inflight;
  clearTimeout(timer);
  inflight = null;
  killWorker();
  block.fail("worker");
  pump();
}

function killWorker() {
  if (!worker) return;
  worker.onmessage = null;
  worker.onerror = null;
  worker.terminate?.();
  worker = null;
}

function computedStyle(element) {
  const view = element.ownerDocument?.defaultView || globalThis;
  return view.getComputedStyle(element);
}

function readFonts(element) {
  const style = computedStyle(element);
  const size = Number.parseFloat(style.fontSize);
  const root = element.ownerDocument?.documentElement || element;
  return {
    sans: fontFamily(style.fontFamily, "sans-serif"),
    mono: fontFamily(computedStyle(root).getPropertyValue("--sig-font-mono") || style.fontFamily, "monospace"),
    size: Number.isFinite(size) && size > 0 && size <= 200 ? size : 16
  };
}

function fontFamily(value, fallback) {
  const text = String(value || "").trim();
  if (!text || text.length > 200 || /[<>;{}]/.test(text)) return fallback;
  return text;
}

function readPalette(element) {
  const style = computedStyle(element);
  const palette = {};
  for (const [token, property] of Object.entries(PALETTE_KEYS)) {
    const value = style.getPropertyValue(property).trim();
    if (COLOR_VALUE.test(value)) palette[token] = value;
  }
  return palette;
}

function paletteStyle(palette) {
  return Object.entries(palette).map(([key, value]) => {
    if (!PALETTE_NAME.test(key) || !COLOR_VALUE.test(value)) throw new Error("palette");
    return `${key}:${value}`;
  }).join(";");
}

function escapeXml(value) {
  return value.replace(/[&<>"']/g, (character) => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    '"': "&quot;",
    "'": "&#39;"
  })[character]);
}

function diagramDocument(svg, _width, _height, palette) {
  const extra = escapeXml(paletteStyle(palette));
  const open = svg.match(/^<svg\b([^>]*)>/i);
  if (!open) throw new Error("image");
  const attrs = extra
    ? (/\sstyle="/i.test(open[1])
      ? open[1].replace(/\sstyle="([^"]*)"/i, (_, value) => ` style="${value};${extra}"`)
      : `${open[1]} style="${extra}"`)
    : open[1];
  return `<svg${attrs}>${svg.slice(open[0].length)}`;
}

function decodeImage(url, options) {
  const ImageCtor = options.Image || globalThis.Image;
  if (typeof ImageCtor !== "function") return Promise.resolve();
  return new Promise((resolve, reject) => {
    const image = new ImageCtor();
    const timer = setTimeout(() => {
      image.onload = image.onerror = null;
      reject(new Error("image"));
    }, 5000);
    image.onload = () => {
      clearTimeout(timer);
      resolve();
    };
    image.onerror = () => {
      clearTimeout(timer);
      reject(new Error("image"));
    };
    image.src = url;
  });
}
