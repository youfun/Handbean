// Transform rendered markdown HTML by injecting copy buttons into <pre> blocks.
// Pure function — no DOM access, no side effects. Testable in Node.js.

const COPY_SVG =
  '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" ' +
  'stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">' +
  '<rect x="9" y="9" width="13" height="13" rx="2" ry="2"></rect>' +
  '<path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"></path>' +
  '</svg>';

/**
 * Inject copy buttons into <pre><code> blocks in the given HTML string.
 * Each <pre> is wrapped in a .code-block-wrapper div with a copy button.
 */
export function injectCopyButtons(html) {
  return html.replace(
    /(<pre><code(?:\s[^>]*)?>)/g,
    (_match, preTag) =>
      `<div class="code-block-wrapper">${preTag}`
  ).replace(
    /(<\/code><\/pre>)/g,
    `</code></pre><button class="code-block-copy" title="Copy" aria-label="复制代码">${COPY_SVG}</button></div>`
  );
}
