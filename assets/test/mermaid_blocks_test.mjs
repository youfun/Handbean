import assert from "node:assert/strict";
import { JSDOM } from "jsdom";
import { injectCopyButtons } from "../js/streaming_markdown/code_block_copy.js";
import { renderMarkdown } from "../js/streaming_markdown/render_markdown.js";
import {
  isMermaidCode,
  mermaidSource,
  renderMermaidBlocks
} from "../js/streaming_markdown/mermaid_blocks.js";

const dom = new JSDOM("<!doctype html><html><body></body></html>");
globalThis.window = dom.window;
globalThis.document = dom.window.document;
globalThis.Node = dom.window.Node;

const source = "```mermaid\ngraph TD\n  A-->B\n```\n";
const html = injectCopyButtons(renderMarkdown(source));
const root = document.createElement("div");
root.innerHTML = html;
document.body.appendChild(root);

const code = root.querySelector("code");
assert.equal(isMermaidCode(code), true);
assert.equal(mermaidSource(code), "graph TD\n  A-->B");
assert.equal(isMermaidCode(document.createElement("code")), false);

const calls = [];
const mermaid = {
  async parse(text, options) {
    calls.push(["parse", text, options]);
    return text.includes("bad") ? false : true;
  },
  async render(id, text) {
    calls.push(["render", id, text]);
    return { svg: `<svg id="${id}"><text>A</text></svg>` };
  }
};

await renderMermaidBlocks(root, { mermaid });

const diagram = root.querySelector(".mermaid-diagram");
assert.equal(diagram?.dataset.mermaidRendered, "true");
assert.match(diagram.innerHTML, /<svg/);
assert.equal(root.querySelector("pre").hidden, true);
assert.equal(root.querySelector(".code-block-copy"), root.querySelector("button"));
assert.equal(calls[0][0], "parse");
assert.equal(calls[1][0], "render");
assert.equal(calls[1][2], "graph TD\n  A-->B");

await renderMermaidBlocks(root, { mermaid });
assert.equal(calls.filter((call) => call[0] === "render").length, 1);

const broken = document.createElement("div");
broken.innerHTML = injectCopyButtons(
  renderMarkdown("```mermaid\nbad\n```\n")
);
document.body.appendChild(broken);
await renderMermaidBlocks(broken, { mermaid });
assert.equal(broken.querySelector(".mermaid-diagram"), null);
assert.equal(broken.querySelector(".mermaid-error")?.textContent, "图表语法无效");
assert.equal(broken.querySelector("pre").hidden, false);

console.log("mermaid_blocks_test passed");
