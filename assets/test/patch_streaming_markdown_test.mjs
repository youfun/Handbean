import assert from "node:assert/strict";
import { patchStreamingMarkdown } from "../js/streaming_markdown/patch_streaming_markdown.js";

assert.equal(patchStreamingMarkdown("hello\n-", true), "hello\n-");

for (const marker of ["-", "*", "+"]) {
  assert.equal(patchStreamingMarkdown(`hello\n${marker}`, false), "hello\n");
}

assert.equal(patchStreamingMarkdown("hello\n1.", false), "hello\n");
assert.equal(patchStreamingMarkdown("hello\n2)", false), "hello\n");
assert.equal(patchStreamingMarkdown("hello\n>", false), "hello\n");

assert.equal(patchStreamingMarkdown("hello <scr", false), "hello ");
assert.equal(patchStreamingMarkdown("hello </think", false), "hello ");

const openFence = "```js\nconsole.log(1)";
assert.equal(patchStreamingMarkdown(openFence, false), "```js\nconsole.log(1)\n```");

const closedFence = "```js\nconsole.log(1)\n```";
assert.equal(patchStreamingMarkdown(closedFence, false), closedFence);

for (const markdown of ["# Title", "- item", "**bold**", "[link](https://example.com)"]) {
  assert.equal(patchStreamingMarkdown(markdown, false), markdown);
}

console.log("patch_streaming_markdown_test passed");
