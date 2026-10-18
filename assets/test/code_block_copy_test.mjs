import assert from "node:assert/strict";
import { injectCopyButtons } from "../js/streaming_markdown/code_block_copy.js";

// Single code block gets a copy button
const single = injectCopyButtons('<pre><code class="language-elixir">IO.puts("hello")\n</code></pre>');
assert.match(single, /code-block-wrapper/, "wrapper should be present");
assert.match(single, /code-block-copy/, "copy button should be present");
assert.match(single, /title="Copy"/, "copy button should have title");
assert.match(single, /aria-label="复制代码"/, "copy button should have aria-label");
assert.match(single, /IO\.puts\("hello"\)/, "original code content preserved");

// Multiple code blocks each get their own copy button
const multi = injectCopyButtons(
  '<pre><code class="language-js">const a = 1;\n</code></pre>\n' +
  '<p>text between</p>\n' +
  '<pre><code class="language-python">print("hi")\n</code></pre>'
);
const btnCount = (multi.match(/code-block-copy/g) || []).length;
assert.equal(btnCount, 2, `expected 2 copy buttons, got ${btnCount}`);

const wrapperCount = (multi.match(/code-block-wrapper/g) || []).length;
assert.equal(wrapperCount, 2, `expected 2 wrappers, got ${wrapperCount}`);

// No code blocks → no copy buttons injected
const noCode = injectCopyButtons('<p>Just plain text, no code blocks here.</p>');
assert.doesNotMatch(noCode, /code-block-copy/, "no copy button when no code block");
assert.doesNotMatch(noCode, /code-block-wrapper/, "no wrapper when no code block");

// Inline code (single backtick) should NOT get a copy button
const inlineCode = injectCopyButtons('<p>Use <code>String.trim()</code> here</p>');
assert.doesNotMatch(inlineCode, /code-block-copy/, "no copy button for inline code");

console.log("code_block_copy_test passed");
