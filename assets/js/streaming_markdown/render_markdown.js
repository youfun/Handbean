import MarkdownIt from "markdown-it";
import createDOMPurify from "dompurify";

export function createMarkdownIt(options = {}) {
  const md = new MarkdownIt({
    html: false,
    linkify: true,
    breaks: false,
    ...options.markdownIt
  });

  if (options.linkTargetBlank) {
    const defaultRender = md.renderer.rules.link_open || ((tokens, idx, opts, _env, self) => self.renderToken(tokens, idx, opts));
    md.renderer.rules.link_open = (tokens, idx, opts, env, self) => {
      const token = tokens[idx];
      const targetIndex = token.attrIndex("target");
      if (targetIndex < 0) token.attrPush(["target", "_blank"]);
      else token.attrs[targetIndex][1] = "_blank";

      const relIndex = token.attrIndex("rel");
      if (relIndex < 0) token.attrPush(["rel", "noopener noreferrer"]);
      else token.attrs[relIndex][1] = "noopener noreferrer";

      return defaultRender(tokens, idx, opts, env, self);
    };
  }

  return md;
}

export const defaultMarkdownIt = createMarkdownIt();

export function renderMarkdown(markdown, options = {}) {
  const md = options.markdownItInstance || (options.linkTargetBlank ? createMarkdownIt(options) : defaultMarkdownIt);
  const rawHtml = md.render(escapeUnsafeMarkdownUrls(String(markdown ?? "")));
  const purifier = getPurifier(options.window);

  return purifier.sanitize(rawHtml, {
    USE_PROFILES: { html: true },
    FORBID_TAGS: ["script", "style", "iframe", "object", "embed", "form", "template"],
    FORBID_ATTR: ["style", "srcdoc"],
    ALLOW_DATA_ATTR: false,
    ADD_ATTR: ["target"],
    ...options.sanitize
  });
}

function escapeUnsafeMarkdownUrls(markdown) {
  return markdown.replace(/\]\(\s*((?:javascript|vbscript):[^)]*)\)/giu, "](unsafe:$1)");
}

function getPurifier(explicitWindow) {
  const candidateWindow = explicitWindow || (typeof window !== "undefined" ? window : null);
  if (!candidateWindow || !candidateWindow.document) {
    throw new Error("renderMarkdown requires a browser window/document or options.window");
  }
  return createDOMPurify(candidateWindow);
}
