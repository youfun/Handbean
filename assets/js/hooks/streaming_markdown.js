import { createSmoothMarkdownStream } from "../streaming_markdown/smooth_stream_controller.js";
import { patchStreamingMarkdown } from "../streaming_markdown/patch_streaming_markdown.js";
import { renderMarkdown } from "../streaming_markdown/render_markdown.js";
import { injectCopyButtons } from "../streaming_markdown/code_block_copy.js";
import { patchMarkdownDom } from "../streaming_markdown/patch_markdown_dom.js";
import {
  decorateMermaidBlocks,
  disposeMermaidBlocks,
  handleMermaidPreviewClick,
  renderMermaidBlocks
} from "../streaming_markdown/mermaid_blocks.js";
import { decorateHtmlPreviews, handleHtmlPreviewClick, resizeHtmlPreview } from "../streaming_markdown/html_previews.js";
import { workspaceFileFromHref } from "../streaming_markdown/workspace_file_link.js";

const MAX_WIDGET_STATE_BYTES = 16 * 1024;
const MAX_WIDGET_STATES = 256;
const widgetStates = new Map();
let widgetRequestSequence = 0;

export const StreamingMarkdown = {
  mounted() {
    this.target = this.el.querySelector("[data-markdown-target]") || this.el;
    this.lastSource = "";
    this.lastFinal = false;
    this.lastStreaming = false;
    this.unsubscribe = null;
    this.retryId = null;
    this.applyingSource = false;
    this.lastRenderedState = null;
    this.widgetCommandRequests = new Map();
    this.resizeHandler = (event) => resizeHtmlPreview(this.target, event);
    this.widgetMessageHandler = (event) => handleWidgetMessage(this, event);
    window.addEventListener("message", this.resizeHandler);
    window.addEventListener("message", this.widgetMessageHandler);
    this.handleEvent?.("widget-command-result", (result) => handleWidgetCommandResult(this, result));
    this.controller = createSmoothMarkdownStream();
    this.unsubscribe = this.controller.subscribe(() => this.requestRender());
    this.applySource({ initial: true });
    this.retryId = setTimeout(() => {
      if (this.targetHasUnrenderedFallback()) this.applySource({ initial: true });
    }, 0);

    // Event delegation for copy buttons
    this.clickHandler = (e) => {
      handleHtmlPreviewClick(e);
      handleMermaidPreviewClick(e);
      const link = e.target.closest("a[href]");
      if (link && this.el.contains(link)) {
        const parsed = workspaceFileFromHref(link.getAttribute("href"), link.textContent);
        if (parsed) {
          e.preventDefault();
          const payload = { path: parsed.path, message_id: this.el.dataset.entryId };
          if (parsed.line) payload.line = parsed.line;
          this.pushEvent("open_file_change", payload);
          return;
        }
      }
      const btn = e.target.closest(".code-block-copy, .msg-copy-btn");
      if (!btn) return;
      this.handleCopyClick(btn);
    };
    this.el.addEventListener("click", this.clickHandler);
  },

  updated() {
    this.applySource({ initial: false });
  },

  destroyed() {
    if (this.retryId) clearTimeout(this.retryId);
    if (this.unsubscribe) this.unsubscribe();
    if (this.controller) this.controller.destroy();
    disposeMermaidBlocks(this.target);
    this.el.removeEventListener("click", this.clickHandler);
    window.removeEventListener("message", this.resizeHandler);
    window.removeEventListener("message", this.widgetMessageHandler);
    this.widgetCommandRequests?.clear();
    this.retryId = null;
    this.unsubscribe = null;
    this.controller = null;
    this.lastRenderedState = null;
  },

  applySource({ initial }) {
    const source = this.readSource();
    const final = this.readFinal();
    const streaming = this.readStreaming();
    const sourceStateChanged =
      source !== this.lastSource ||
      final !== this.lastFinal ||
      streaming !== this.lastStreaming;

    if (!initial && !sourceStateChanged && !this.targetHasUnrenderedFallback()) {
      this.requestRender();
      return;
    }

    this.applyingSource = true;
    try {
      if (!streaming) {
        this.controller.reset(source);
        this.controller.finish({ flush: true });
      } else if (initial || !source.startsWith(this.lastSource) || this.lastFinal || !this.lastStreaming) {
        this.controller.reset("");
        if (source) this.controller.enqueue(source);
      } else {
        const delta = source.slice(this.lastSource.length);
        if (delta) this.controller.enqueue(delta);
      }
    } finally {
      this.applyingSource = false;
    }

    this.lastSource = source;
    this.lastFinal = final;
    this.lastStreaming = streaming;
    this.requestRender();
  },

  requestRender() {
    if (this.applyingSource) return;

    this.renderSnapshot();
  },

  targetHasUnrenderedFallback() {
    return Boolean(this.target?.querySelector(".markdown-noscript-fallback"));
  },

  readSource() {
    return this.el.dataset.source || "";
  },

  readFinal() {
    return this.el.dataset.final === "true";
  },

  readStreaming() {
    return this.el.dataset.streaming === "true";
  },

  renderSnapshot() {
    if (!this.target || !this.controller) return;
    const snapshot = this.controller.getSnapshot();
    const final = this.readFinal();
    const streaming = this.readStreaming();
    const widget = widgetContext(this.el);
    const state = {
      visible: snapshot.visible,
      finalMarkdown: snapshot.final || final,
      streaming: streaming && !snapshot.final,
      renderMermaid: !streaming && final,
      widgetConversationId: widget?.conversationId || null,
      widgetEntryId: widget?.entryId || null
    };

    if (sameRenderState(state, this.lastRenderedState) && !this.targetHasUnrenderedFallback()) return;

    const markdown = patchStreamingMarkdown(snapshot.visible, state.finalMarkdown);
    let html = renderMarkdown(markdown, { linkTargetBlank: true });
    html = injectCopyButtons(html);
    applyRenderedHtml(this.target, html, snapshot.visible, {
      diagrams: state.renderMermaid,
      widgetContext: widget
    });
    this.lastRenderedState = state;

    if (state.streaming) {
      this.insertCursor();
      return;
    }

    this.renderMermaid();
  },

  renderMermaid() {
    if (!this.target || this.readStreaming() || !this.readFinal()) return;
    renderMermaidBlocks(this.target);
  },

  insertCursor() {
    if (!this.target) return;

    const cursor = document.createElement("span");
    cursor.className = "markdown-typewriter-cursor";
    cursor.setAttribute("aria-hidden", "true");
    cursor.textContent = "▍";

    const parent = this.findCursorParent();
    parent.appendChild(cursor);
  },

  findCursorParent() {
    const selector = [
      "p",
      "li",
      "h1",
      "h2",
      "h3",
      "h4",
      "h5",
      "h6",
      "td",
      "th",
      "blockquote"
    ].join(",");

    const candidates = [...this.target.querySelectorAll(selector)]
      .filter((el) => el.textContent.trim() !== "" || el.querySelector("img,br"));

    return candidates.at(-1) || this.target;
  },

  handleCopyClick(btn) {
    if (btn.classList.contains("msg-copy-btn")) {
      this.handleMsgCopyClick(btn);
      return;
    }
    const wrapper = btn.closest(".code-block-wrapper");
    if (!wrapper) return;
    const code = wrapper.querySelector("code");
    if (!code) return;
    const text = code.textContent || "";

    navigator.clipboard.writeText(text).then(() => {
      btn.classList.add("copied");
      const origTitle = btn.getAttribute("title");
      btn.setAttribute("title", "Copied!");
      btn.setAttribute("aria-label", "已复制");

      // Show checkmark icon temporarily
      btn.innerHTML =
        '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" ' +
        'stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">' +
        '<polyline points="20 6 9 17 4 12"></polyline></svg>';

      setTimeout(() => {
        btn.classList.remove("copied");
        btn.setAttribute("title", origTitle || "Copy");
        btn.setAttribute("aria-label", "复制代码");
        btn.innerHTML =
          '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" ' +
          'stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">' +
          '<rect x="9" y="9" width="13" height="13" rx="2" ry="2"></rect>' +
          '<path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"></path></svg>';
      }, 2000);
    }).catch(() => {
      // Clipboard API failed silently — user can still select and copy manually
    });
  },

  handleMsgCopyClick(btn) {
    const text = this.el.dataset.source || "";
    if (!text) return;

    navigator.clipboard.writeText(text).then(() => {
      btn.classList.add("copied");
      const origTitle = btn.getAttribute("title") || "复制回复";
      btn.setAttribute("title", "Copied!");
      btn.setAttribute("aria-label", "已复制");
      btn.innerHTML =
        '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" ' +
        'stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">' +
        '<polyline points="20 6 9 17 4 12"></polyline></svg>';
      this.showToast("已复制到剪贴板");

      setTimeout(() => {
        btn.classList.remove("copied");
        btn.setAttribute("title", origTitle);
        btn.setAttribute("aria-label", "复制回复");
        btn.innerHTML =
          '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" ' +
          'stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">' +
          '<rect x="9" y="9" width="13" height="13" rx="2" ry="2"></rect>' +
          '<path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"></path></svg>';
      }, 2000);
    }).catch(() => {
      // Clipboard API failed silently
    });
  },

  showToast(message) {
    const existing = document.querySelector(".copy-toast");
    if (existing) existing.remove();
    const toast = document.createElement("div");
    toast.className = "copy-toast";
    toast.textContent = message;
    document.body.appendChild(toast);
    setTimeout(() => {
      if (toast.parentNode) toast.parentNode.removeChild(toast);
    }, 2500);
  }
};

function sameRenderState(left, right) {
  return Boolean(right) &&
    left.visible === right.visible &&
    left.finalMarkdown === right.finalMarkdown &&
    left.streaming === right.streaming &&
    left.renderMermaid === right.renderMermaid &&
    left.widgetConversationId === right.widgetConversationId &&
    left.widgetEntryId === right.widgetEntryId;
}

function widgetContext(element) {
  const conversationId = element?.dataset?.conversationId;
  const entryId = element?.dataset?.entryId;
  if (element?.dataset?.widgetActions !== "true" || !conversationId || !entryId) return null;
  return { conversationId, entryId };
}

function widgetStateKey(context, fenceIndex) {
  return JSON.stringify([context.conversationId, context.entryId, String(fenceIndex)]);
}

function handleWidgetMessage(hook, event) {
  const message = event.data;
  if (!event.source ||
      (message?.type !== "handbean:widget-state" && message?.type !== "handbean:widget-command")) return;

  const frame = [...hook.target.querySelectorAll(".html-preview-frame")]
    .find((candidate) => candidate.contentWindow === event.source);
  if (!frame?.isConnected) return;

  const context = widgetContext(hook.el);
  const rawFenceIndex = frame.dataset.fenceIndex;
  if (!context || !/^\d+$/.test(rawFenceIndex ?? "")) return;
  const fenceIndex = Number(rawFenceIndex);
  if (!Number.isSafeInteger(fenceIndex)) return;

  if (message.type === "handbean:widget-state") {
    const state = jsonState(message.value);
    if (state !== undefined) storeWidgetState(widgetStateKey(context, fenceIndex), state);
    return;
  }

  if (message.command !== "prefill_follow_up" || typeof hook.pushEvent !== "function") return;

  const requestId = nextWidgetRequestId();
  hook.widgetCommandRequests.set(requestId, { frame });
  postToWidget(frame, {
    type: "handbean:widget-command-accepted",
    bridge_request_id: message.bridge_request_id,
    request_id: requestId
  });

  try {
    hook.pushEvent("widget_command", {
      request_id: requestId,
      entry_id: context.entryId,
      fence_index: fenceIndex,
      command: "prefill_follow_up",
      payload: message.payload
    });
  } catch {
    hook.widgetCommandRequests.delete(requestId);
    postToWidget(frame, {
      type: "handbean:widget-command-result",
      request_id: requestId,
      status: "error",
      reason: "Widget command could not be sent"
    });
  }
}

function handleWidgetCommandResult(hook, result) {
  if (!result || (result.status !== "ok" && result.status !== "error")) return;
  const pending = hook.widgetCommandRequests?.get(result.request_id);
  if (!pending) return;
  hook.widgetCommandRequests.delete(result.request_id);
  const message = {
    type: "handbean:widget-command-result",
    request_id: result.request_id,
    status: result.status
  };
  if (result.reason !== undefined) message.reason = result.reason;
  postToWidget(pending.frame, message);
}

function jsonState(value) {
  try {
    const serialized = JSON.stringify(value);
    if (serialized === undefined || new TextEncoder().encode(serialized).byteLength > MAX_WIDGET_STATE_BYTES) {
      return undefined;
    }
    return JSON.parse(serialized);
  } catch {
    return undefined;
  }
}

function storeWidgetState(key, state) {
  widgetStates.delete(key);
  widgetStates.set(key, state);

  if (widgetStates.size > MAX_WIDGET_STATES) {
    widgetStates.delete(widgetStates.keys().next().value);
  }
}

function readWidgetState(key) {
  if (!widgetStates.has(key)) return null;
  const state = widgetStates.get(key);
  widgetStates.delete(key);
  widgetStates.set(key, state);
  return state;
}

function nextWidgetRequestId() {
  if (globalThis.crypto?.randomUUID) return globalThis.crypto.randomUUID();
  widgetRequestSequence += 1;
  return `widget-command-${Date.now()}-${widgetRequestSequence}`;
}

function postToWidget(frame, message) {
  try {
    frame.contentWindow?.postMessage(message, "*");
  } catch {
    // A frame can disappear while a LiveView result is in flight.
  }
}

function applyRenderedHtml(target, html, markdown, options = {}) {
  if (typeof document === "undefined" || !target) {
    target.innerHTML = html;
    return;
  }

  try {
    const template = document.createElement("template");
    template.innerHTML = html;
    const widget = options.widgetContext;
    decorateHtmlPreviews(template.content, markdown, {
      widgetActions: Boolean(widget),
      widgetState: widget
        ? (fenceIndex) => readWidgetState(widgetStateKey(widget, fenceIndex))
        : undefined
    });
    if (options.diagrams) decorateMermaidBlocks(template.content);
    patchMarkdownDom(target, template.content, {
      selection: typeof window !== "undefined" ? window.getSelection?.() : null
    });
  } catch {
    disposeMermaidBlocks(target);
    target.innerHTML = html;
  }
}

export default StreamingMarkdown;
