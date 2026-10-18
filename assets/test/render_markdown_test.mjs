import assert from "node:assert/strict";
import { JSDOM } from "jsdom";
import { renderMarkdown } from "../js/streaming_markdown/render_markdown.js";

const dom = new JSDOM("<!doctype html><html><body></body></html>");
globalThis.window = dom.window;
globalThis.document = dom.window.document;
globalThis.Node = dom.window.Node;

after(() => {
  delete globalThis.window;
  delete globalThis.document;
  delete globalThis.Node;
});

function after(fn) {
  process.on("exit", fn);
}

assert.match(renderMarkdown("# Title"), /<h1>Title<\/h1>/);
assert.match(renderMarkdown("- item"), /<ul>\s*<li>item<\/li>\s*<\/ul>/);
assert.match(renderMarkdown("```js\nconsole.log(1)\n```"), /<pre><code class="language-js">console\.log\(1\)\n<\/code><\/pre>/);

const malicious = renderMarkdown(`
<script>alert(1)</script>
[x](javascript:alert(1))
<img src=x onerror=alert(1)>
<iframe src="https://evil.example"></iframe>
`);

assert.doesNotMatch(malicious, /<script/i);
assert.doesNotMatch(malicious, /javascript:/i);
assert.doesNotMatch(malicious, /<img/i);
assert.doesNotMatch(malicious, /<iframe/i);

const chatty = renderMarkdown(
  "**Files created:**\n\n" +
    "| File | Description |\n" +
    "|------|-------------|\n" +
    "| `ssl/server.key` | 2048-bit RSA private key |\n\n" +
    "```\nCertificate verification successful\n```\n"
);
assert.match(chatty, /<strong>Files created:<\/strong>/);
assert.match(chatty, /<table>/);
assert.match(chatty, /<th>File<\/th>/);
assert.match(chatty, /<pre><code>Certificate verification successful\n<\/code><\/pre>/);

const linked = renderMarkdown("[x](https://example.com)", { linkTargetBlank: true });
assert.match(linked, /target="_blank"/);
assert.match(linked, /rel="noopener noreferrer"/);

console.log("render_markdown_test passed");
