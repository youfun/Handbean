import { defaultMarkdownIt } from "./render_markdown.js";

// Only fenced assistant HTML opts into execution. Ordinary Markdown stays on
// the DOMPurify path; preview documents never enter the application's DOM.
export function decorateHtmlPreviews(fragment, markdown, options = {}) {
  const fences = defaultMarkdownIt.parse(markdown, {})
    .filter((token) => token.type === "fence" && /^(html|widget)$/i.test(token.info.trim().split(/\s+/)[0]));
  const codes = [...fragment.querySelectorAll("pre > code")]
    .filter((code) => /(?:^|\s)language-(html|widget)(?:\s|$)/i.test(code.className));

  codes.forEach((code, index) => {
    const token = fences[index];
    if (!token) return;
    const wrapper = code.closest(".code-block-wrapper");
    if (!wrapper) return;

    // MarkdownIt's map includes a real closing fence; content does not. A
    // mid-line unclosed fence has the same span, so require a trailing newline.
    const closed = fenceClosed(token);
    code.textContent = token.content;
    wrapper.dataset.htmlPreview = closed ? "ready" : "streaming";
    const toolbar = document.createElement("div");
    toolbar.className = "html-preview-toolbar";
    toolbar.innerHTML = '<span class="html-preview-label">HTML</span>' +
      '<button type="button" data-html-view="preview" aria-pressed="true">预览</button>' +
      '<button type="button" data-html-view="source" aria-pressed="false">源码</button>';
    const status = document.createElement("span");
    status.className = "html-preview-status";
    status.textContent = closed ? "隔离运行" : "生成中 · 脚本暂停";
    toolbar.appendChild(status);
    wrapper.prepend(toolbar);
    code.parentElement.hidden = true;

    const frame = document.createElement("iframe");
    frame.className = "html-preview-frame";
    frame.title = `HTML 预览 ${index + 1}`;
    frame.setAttribute("sandbox", closed ? "allow-scripts" : "");
    frame.setAttribute("referrerpolicy", "no-referrer");
    frame.setAttribute("allow", "camera 'none'; microphone 'none'; geolocation 'none'; clipboard-read 'none'; clipboard-write 'none'");
    frame.dataset.fenceIndex = String(index);
    const widgetState = options.widgetState?.(index) ?? null;
    frame.srcdoc = previewDocument(token.content, closed, {
      widgetActions: options.widgetActions === true,
      widgetState
    });
    if (!closed) frame.dataset.previewSource = token.content;
    wrapper.appendChild(frame);
  });
}

export function handleHtmlPreviewClick(event) {
  const button = event.target.closest("[data-html-view]");
  const wrapper = button?.closest("[data-html-preview]");
  if (!wrapper) return;
  const showSource = button.dataset.htmlView === "source";
  wrapper.querySelector("pre").hidden = !showSource;
  wrapper.querySelector("iframe").hidden = showSource;
  for (const tab of wrapper.querySelectorAll("[data-html-view]")) {
    tab.setAttribute("aria-pressed", String(tab === button));
  }
}

export function resizeHtmlPreview(root, event) {
  if (!event.source || event.data?.type !== "handbean:preview-height" ||
      !Number.isFinite(event.data.height)) return;
  const frame = [...root.querySelectorAll(".html-preview-frame")]
    .find((candidate) => candidate.contentWindow === event.source);
  if (frame) frame.style.height = `${Math.max(220, Math.min(720, Math.ceil(event.data.height)))}px`;
}

function fenceClosed(token) {
  if (!token?.map) return false;
  const content = token.content ?? "";
  // The closer is always its own line, so captured content is empty or ends
  // with a newline. Treating a partial line as closed reloads the iframe on
  // every line and flashes the preview between paused and isolated-run.
  if (content !== "" && !content.endsWith("\n")) return false;
  return token.map[1] - token.map[0] > content.split("\n").length;
}

function previewDocument(source, closed, options) {
  const scripts = closed ? "'unsafe-inline'" : "'none'";
  const policy = `default-src 'none'; script-src ${scripts}; style-src 'unsafe-inline'; img-src data: blob:; font-src data:; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'`;
  const widgetBridge = closed && options.widgetActions ? widgetBridgeScript(options.widgetState) : "";
  const resizeScript = closed ? `<script>(() => {
    const report = () => parent.postMessage({type: "handbean:preview-height", height: document.documentElement.scrollHeight}, "*");
    new ResizeObserver(report).observe(document.body);
    addEventListener("load", report);
    report();
  })();</script>` : "";
  return '<!doctype html><html><head><meta charset="utf-8">' +
    `<meta http-equiv="Content-Security-Policy" content="${policy}">` +
    '<meta name="viewport" content="width=device-width, initial-scale=1">' +
    '<style>html{color-scheme:light dark}body{margin:0;padding:16px;box-sizing:border-box;font:14px/1.5 system-ui,sans-serif;overflow-wrap:anywhere}img,svg,canvas{max-width:100%}button,input,select,textarea{font:inherit}</style>' +
    `${widgetBridge}</head><body>${source}${resizeScript}</body></html>`;
}

function widgetBridgeScript(initialState) {
  const state = JSON.stringify(initialState ?? null).replaceAll("<", "\\u003c").replaceAll("\u2028", "\\u2028").replaceAll("\u2029", "\\u2029");
  return `<script>(() => {
    const maxStateBytes = 16 * 1024;
    const maxPendingCommands = 32;
    const pending = new Map();
    let sequence = 0;
    let state = ${state};
    const serializeState = (value) => {
      const serialized = JSON.stringify(value);
      if (serialized === undefined) throw new TypeError("Widget state must be JSON serializable");
      if (new TextEncoder().encode(serialized).byteLength > maxStateBytes) {
        throw new RangeError("Widget state exceeds 16 KiB");
      }
      return serialized;
    };
    const getState = () => JSON.parse(JSON.stringify(state));
    const setState = (value) => {
      const serialized = serializeState(value);
      state = JSON.parse(serialized);
      parent.postMessage({type: "handbean:widget-state", value: state}, "*");
      return getState();
    };
    const prefillFollowUp = (payload) => {
      if (pending.size >= maxPendingCommands) {
        return Promise.reject(new Error("Too many pending widget commands"));
      }
      return new Promise((resolve, reject) => {
        const bridgeRequestId = "widget-" + Date.now() + "-" + (++sequence);
        parent.postMessage({
          type: "handbean:widget-command",
          command: "prefill_follow_up",
          payload,
          bridge_request_id: bridgeRequestId
        }, "*");
        pending.set(bridgeRequestId, {resolve, reject});
      });
    };
    addEventListener("message", (event) => {
      if (event.source !== parent) return;
      const message = event.data;
      if (message?.type === "handbean:widget-command-accepted") {
        const callbacks = pending.get(message.bridge_request_id);
        if (!callbacks) return;
        pending.delete(message.bridge_request_id);
        pending.set(message.request_id, callbacks);
        return;
      }
      if (message?.type !== "handbean:widget-command-result") return;
      const callbacks = pending.get(message.request_id);
      if (!callbacks) return;
      pending.delete(message.request_id);
      if (message.status === "ok") callbacks.resolve();
      else callbacks.reject(new Error(message.reason || "Widget command failed"));
    });
    Object.defineProperty(window, "handbean", {
      value: Object.freeze({
        getState,
        setState,
        prefillFollowUp,
        sendFollowUpMessage: prefillFollowUp
      })
    });
  })();</script>`;
}
