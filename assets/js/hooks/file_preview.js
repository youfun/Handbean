import hljs from "highlight.js/lib/core";
import bash from "highlight.js/lib/languages/bash";
import c from "highlight.js/lib/languages/c";
import cpp from "highlight.js/lib/languages/cpp";
import css from "highlight.js/lib/languages/css";
import elixir from "highlight.js/lib/languages/elixir";
import go from "highlight.js/lib/languages/go";
import ini from "highlight.js/lib/languages/ini";
import java from "highlight.js/lib/languages/java";
import javascript from "highlight.js/lib/languages/javascript";
import json from "highlight.js/lib/languages/json";
import kotlin from "highlight.js/lib/languages/kotlin";
import markdown from "highlight.js/lib/languages/markdown";
import python from "highlight.js/lib/languages/python";
import ruby from "highlight.js/lib/languages/ruby";
import rust from "highlight.js/lib/languages/rust";
import sql from "highlight.js/lib/languages/sql";
import swift from "highlight.js/lib/languages/swift";
import typescript from "highlight.js/lib/languages/typescript";
import xml from "highlight.js/lib/languages/xml";
import yaml from "highlight.js/lib/languages/yaml";
import { createMarkdownIt, renderMarkdown } from "../streaming_markdown/render_markdown.js";

const languages = {
  bash, c, cpp, css, elixir, go, ini, java, javascript, json, kotlin,
  markdown, plaintext: null, python, ruby, rust, sql, swift, typescript, xml, yaml
};

Object.entries(languages).forEach(([name, definition]) => {
  if (definition) hljs.registerLanguage(name, definition);
});

const invalidPath = /[\\\u0000-\u001f\u007f]|^[a-z][a-z\d+.-]*:|^\//i;

// Resolve only workspace-relative references. The server remains responsible for
// filesystem containment (including symlinks) and authorization.
function relativePath(reference, currentFile) {
  try {
    const rawPath = reference.split(/[?#]/, 1)[0];
    if (!rawPath || invalidPath.test(rawPath)) return null;
    const path = decodeURIComponent(rawPath);
    // Nested encoding must not turn into traversal in a subsequent URL decoder.
    if (invalidPath.test(path) || path.includes(":") || /%[a-f\d]{2}/i.test(path)) return null;
    if (!currentFile || invalidPath.test(currentFile)) return null;
    const parts = currentFile.split("/").slice(0, -1);
    if (parts.some(part => !part || part === "." || part === "..")) return null;
    for (const part of path.split("/")) {
      if (!part || part === ".") continue;
      if (part === "..") {
        if (!parts.length) return null;
        parts.pop();
      } else {
        parts.push(part);
      }
    }
    return parts.length ? parts.join("/") : null;
  } catch {
    return null;
  }
}

function externalLink(href) {
  try {
    return /^https?:\/\//i.test(href) && ["http:", "https:"].includes(new URL(href).protocol);
  } catch {
    return false;
  }
}

function fragment(href) {
  if (!href.startsWith("#")) return null;
  try {
    const value = decodeURIComponent(href.slice(1));
    return /[\u0000-\u001f\u007f]/.test(value) ? null : value;
  } catch {
    return null;
  }
}

function headingAnchors(rendered, root) {
  const anchors = new Map();
  for (const heading of rendered.querySelectorAll("h1, h2, h3, h4, h5, h6")) {
    const base = heading.textContent.trim().toLowerCase().replace(/[^\p{L}\p{N}\p{M}_\s-]/gu, "").replace(/\s+/g, "-") || "section";
    let slug = base;
    for (let suffix = 1; anchors.has(slug); suffix++) slug = `${base}-${suffix}`;
    // Namespace IDs to avoid named-property clobbering and other preview DOMs.
    heading.id = `${root.id || "file-preview"}-heading-${slug}`;
    heading.tabIndex = -1;
    anchors.set(slug, heading);
  }
  return anchors;
}

function previewMarkdown(source, root) {
  const md = createMarkdownIt({ linkTargetBlank: true });
  const linkOpen = md.renderer.rules.link_open;
  md.renderer.rules.link_open = (tokens, index, options, env, renderer) => {
    const token = tokens[index];
    const href = token.attrGet("href") || "";
    if (!externalLink(href) && fragment(href) === null && !relativePath(href, root.dataset.relativePath)) {
      token.attrs = (token.attrs || []).filter(([name]) => name !== "href");
    }
    return linkOpen(tokens, index, options, env, renderer);
  };
  md.renderer.rules.image = (tokens, index) => {
    const token = tokens[index];
    const path = relativePath(token.attrGet("src") || "", root.dataset.relativePath);
    const alt = md.utils.escapeHtml(token.content || "");
    if (!path || !root.dataset.workspaceId) return alt;
    const url = `/workspace-files/${encodeURIComponent(root.dataset.workspaceId)}/${path.split("/").map(encodeURIComponent).join("/")}`;
    return `<img src="${md.utils.escapeHtml(url)}" alt="${alt}">`;
  };
  return renderMarkdown(source, { markdownItInstance: md, window: root.ownerDocument.defaultView });
}

export const FilePreview = {
  mounted() {
    this.previewMode = this.el.dataset.kind === "markdown" ? "rendered" : "source";
    this.previewWrap = false;
    this.previewClick = event => {
      const button = event.target.closest("[data-preview-mode], [data-preview-wrap]");
      if (button && this.el.contains(button)) {
        event.preventDefault();
        if (button.hasAttribute("data-preview-wrap")) this.previewWrap = !this.previewWrap;
        else if (["rendered", "source"].includes(button.dataset.previewMode)) this.previewMode = button.dataset.previewMode;
        FilePreview.renderPreview.call(this);
        return;
      }
      const link = event.target.closest("[data-preview-target='rendered'] a[href]");
      if (!link || !this.el.contains(link)) return;
      const href = link.getAttribute("href");
      if (externalLink(href)) return;
      event.preventDefault();
      if (href.startsWith("#")) {
        const anchor = fragment(href);
        const heading = this.previewAnchors?.get(anchor);
        const destination = anchor === "" ? this.renderedTarget : heading;
        destination?.scrollIntoView?.({ block: "start" });
        heading?.focus({ preventScroll: true });
        return;
      }
      const path = relativePath(href, this.el.dataset.relativePath);
      if (path) this.pushEvent("select_workspace_file", { path });
    };
    this.el.addEventListener("click", this.previewClick);
    FilePreview.renderPreview.call(this);
  },

  updated() {
    FilePreview.renderPreview.call(this);
  },

  destroyed() {
    this.el.removeEventListener("click", this.previewClick);
  },

  renderPreview() {
    const source = this.el.querySelector("[data-preview-source]")?.textContent || "";
    const kind = this.el.dataset.kind || "code";
    const rendered = this.el.querySelector("[data-preview-target='rendered']");
    const target = this.el.querySelector("[data-preview-target='source']");
    const language = this.el.dataset.language || "plaintext";
    const key = JSON.stringify([this.el.dataset.digest ?? source, kind, language, this.el.dataset.workspaceId, this.el.dataset.relativePath]);

    if (key !== this.previewKey || rendered !== this.renderedTarget || target !== this.sourceTarget) {
      if (kind === "markdown" && rendered) {
        try {
          rendered.innerHTML = previewMarkdown(source, this.el);
          this.previewAnchors = headingAnchors(rendered, this.el);
        } catch {
          rendered.textContent = source;
          this.previewAnchors = new Map();
        }
      }
      if (target) {
        try {
          if (Object.hasOwn(languages, language) && languages[language]) {
            target.innerHTML = hljs.highlight(source, { language, ignoreIllegals: true }).value;
          } else {
            target.textContent = source;
          }
        } catch {
          target.textContent = source;
        }
      }
      this.previewKey = key;
      this.renderedTarget = rendered;
      this.sourceTarget = target;
    }

    const gutter = this.el.querySelector("[data-preview-line-numbers]");
    if (gutter) {
      const lines = Array.from({ length: source.split(/\r\n|\r|\n/).length }, (_, index) => index + 1).join("\n");
      if (gutter.textContent !== lines) gutter.textContent = lines;
      gutter.setAttribute("aria-hidden", "true");
      gutter.hidden = this.previewWrap;
    }
    this.el.dataset.previewWrapped = String(this.previewWrap);
    const showRendered = kind === "markdown" && this.previewMode === "rendered";
    if (rendered) rendered.hidden = !showRendered;
    const sourceSurface = target?.closest("pre") || target;
    if (sourceSurface) {
      sourceSurface.hidden = showRendered;
      sourceSurface.style.whiteSpace = this.previewWrap ? "pre-wrap" : "pre";
      sourceSurface.style.overflowWrap = this.previewWrap ? "anywhere" : "normal";
    }
    this.el.querySelectorAll("[data-preview-mode]").forEach(button => {
      button.setAttribute("aria-pressed", String(button.dataset.previewMode === (showRendered ? "rendered" : "source")));
    });
    this.el.querySelectorAll("[data-preview-wrap]").forEach(button => {
      button.setAttribute("aria-pressed", String(this.previewWrap));
      button.hidden = showRendered;
    });
  }
};

// Keep load/error handling local to the image preview; strings and the image
// route remain owned by the server template.
export const FileImage = {
  mounted() {
    FileImage.updated.call(this);
  },

  updated() {
    const image = this.el.querySelector("img");
    const source = image?.getAttribute("src");
    if (image !== this.previewImage || source !== this.previewImageSource) {
      FileImage.destroyed.call(this);
      this.previewImage = image;
      this.previewImageSource = source;
      this.previewImageState = "loading";
      if (image) {
        this.previewImageLoad = () => {
          this.previewImageState = "loaded";
          FileImage.showImageState.call(this);
        };
        this.previewImageError = () => {
          this.previewImageState = "error";
          FileImage.showImageState.call(this);
        };
        image.addEventListener("load", this.previewImageLoad);
        image.addEventListener("error", this.previewImageError);
        if (image.complete) this.previewImageState = image.naturalWidth > 0 ? "loaded" : "error";
      }
    }
    FileImage.showImageState.call(this);
  },

  showImageState() {
    if (this.previewImage) this.previewImage.hidden = this.previewImageState !== "loaded";
    const error = this.el.querySelector("[data-preview-image-error]");
    if (error) {
      error.setAttribute("role", "status");
      error.hidden = this.previewImageState !== "error";
    }
  },

  destroyed() {
    if (this.previewImage) {
      this.previewImage.removeEventListener("load", this.previewImageLoad);
      this.previewImage.removeEventListener("error", this.previewImageError);
    }
  }
};

// Tabs retain server-owned selection. Keyboard navigation sends the same event
// as a normal tab click; close buttons keep their existing LiveView click owner.
export const FileTabs = {
  mounted() {
    this.tabsKeydown = event => {
      const tab = event.target.closest("[role='tab']");
      if (!tab || !this.el.contains(tab) || event.altKey || event.ctrlKey || event.metaKey) return;
      const tabs = [...this.el.querySelectorAll("[role='tab']")];
      const index = tabs.indexOf(tab);
      const next = {
        ArrowRight: (index + 1) % tabs.length,
        ArrowLeft: (index + tabs.length - 1) % tabs.length,
        Home: 0,
        End: tabs.length - 1
      }[event.key];
      if (next === undefined) return;
      event.preventDefault();
      event.stopPropagation();
      tabs[next].focus();
      if (tabs[next].dataset.relativePath) this.pushEvent("select_editor_file", { path: tabs[next].dataset.relativePath });
    };
    this.tabsClick = event => {
      const close = event.target.closest("[data-close-tab]");
      if (!close || !this.el.contains(close)) return;
      const tabs = [...this.el.querySelectorAll("[role='tab']")];
      const index = tabs.findIndex(tab => tab.dataset.relativePath === close.dataset.closeTab);
      if (index >= 0) this.pendingTabClose = { path: close.dataset.closeTab, index };
    };
    this.el.addEventListener("keydown", this.tabsKeydown);
    this.el.addEventListener("click", this.tabsClick);
    FileTabs.updated.call(this);
  },

  updated() {
    const tabs = [...this.el.querySelectorAll("[role='tab']")];
    const active = tabs.find(tab => tab.getAttribute("aria-selected") === "true");
    tabs.forEach(tab => { tab.tabIndex = tab === (active || tabs[0]) ? 0 : -1; });
    if (active && active !== this.activePreviewTab) active.scrollIntoView?.({ block: "nearest", inline: "nearest" });
    this.activePreviewTab = active;
    if (this.pendingTabClose && !tabs.some(tab => tab.dataset.relativePath === this.pendingTabClose.path)) {
      tabs[Math.min(this.pendingTabClose.index, tabs.length - 1)]?.focus();
      this.pendingTabClose = null;
    }
  },

  destroyed() {
    this.el.removeEventListener("keydown", this.tabsKeydown);
    this.el.removeEventListener("click", this.tabsClick);
  }
};

export default FilePreview;
