import { createSmoothMarkdownStream } from "../streaming_markdown/smooth_stream_controller.js";
import { patchStreamingMarkdown } from "../streaming_markdown/patch_streaming_markdown.js";
import { renderMarkdown } from "../streaming_markdown/render_markdown.js";
import { injectCopyButtons } from "../streaming_markdown/code_block_copy.js";
import { patchMarkdownDom } from "../streaming_markdown/patch_markdown_dom.js";
import { renderMermaidBlocks } from "../streaming_markdown/mermaid_blocks.js";
import { decorateHtmlPreviews, handleHtmlPreviewClick, resizeHtmlPreview } from "../streaming_markdown/html_previews.js";

export const StreamingMarkdown = {
  mounted() {
    this.target = this.el.querySelector("[data-markdown-target]") || this.el;
    this.lastSource = "";
    this.lastFinal = false;
    this.lastStreaming = false;
    this.unsubscribe = null;
    this.retryId = null;
    this.resizeHandler = (event) => resizeHtmlPreview(this.target, event);
    window.addEventListener("message", this.resizeHandler);
    this.controller = createSmoothMarkdownStream({}, () => this.renderSnapshot());
    this.unsubscribe = this.controller.subscribe(() => this.renderSnapshot());
    this.applySource({ initial: true });
    this.retryId = setTimeout(() => {
      if (this.targetHasUnrenderedFallback()) this.applySource({ initial: true });
    }, 0);

    // Event delegation for copy buttons
    this.clickHandler = (e) => {
      handleHtmlPreviewClick(e);
      const link = e.target.closest("a[href]");
      if (link && this.el.contains(link)) {
        const href = link.getAttribute("href");
        const localHref = href?.replace(/:\d+(?::\d+)?(?=[?#]|$)/, "");
        // Only local paths belong to the workspace; leave web links untouched.
        if (localHref && !/^(?:[a-z][a-z0-9+.-]*:|\/\/|#|\?)/i.test(localHref)) {
          e.preventDefault();
          let path;
          try { path = decodeURIComponent(href.split(/[?#]/)[0]); } catch { return; }
          path = path.replace(/:\d+(?::\d+)?$/, "");
          this.pushEvent("open_file_change", { path, message_id: this.el.dataset.entryId });
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
    this.el.removeEventListener("click", this.clickHandler);
    window.removeEventListener("message", this.resizeHandler);
    this.retryId = null;
    this.unsubscribe = null;
    this.controller = null;
  },

  applySource({ initial }) {
    const source = this.readSource();
    const final = this.readFinal();
    const streaming = this.readStreaming();

    if (
      source === this.lastSource &&
      final === this.lastFinal &&
      streaming === this.lastStreaming &&
      !initial &&
      !this.targetHasUnrenderedFallback()
    ) return;

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

    this.lastSource = source;
    this.lastFinal = final;
    this.lastStreaming = streaming;
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
    const markdown = patchStreamingMarkdown(snapshot.visible, snapshot.final || this.readFinal());
    let html = renderMarkdown(markdown, { linkTargetBlank: true });
    html = injectCopyButtons(html);
    applyRenderedHtml(this.target, html, snapshot.visible);

    if (this.readStreaming() && !snapshot.final) {
      this.insertCursor();
      return;
    }

    this.renderMermaid();
  },

  renderMermaid() {
    if (!this.target || this.readStreaming() || !this.readFinal()) return;
    renderMermaidBlocks(this.target).catch(() => {});
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

function applyRenderedHtml(target, html, markdown) {
  if (typeof document === "undefined" || !target) {
    target.innerHTML = html;
    return;
  }

  try {
    const template = document.createElement("template");
    template.innerHTML = html;
    decorateHtmlPreviews(template.content, markdown);
    patchMarkdownDom(target, template.content, {
      selection: typeof window !== "undefined" ? window.getSelection?.() : null
    });
  } catch {
    target.innerHTML = html;
  }
}

export default StreamingMarkdown;
