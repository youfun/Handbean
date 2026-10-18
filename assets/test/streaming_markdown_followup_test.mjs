import assert from "node:assert/strict";
import { patchStreamingMarkdown } from "../js/streaming_markdown/patch_streaming_markdown.js";
import { patchMarkdownDom } from "../js/streaming_markdown/patch_markdown_dom.js";
import { createSmoothMarkdownStream } from "../js/streaming_markdown/smooth_stream_controller.js";

// 1. Incomplete streaming constructs: tables, emphasis, math
{
  const table = patchStreamingMarkdown("| a | b |\n| --- | --- |\n| 1", false);
  assert.equal(table, "| a | b |\n| --- | --- |\n| 1 |");

  const emphasis = patchStreamingMarkdown("hello **bo", false);
  assert.equal(emphasis, "hello **bo**");

  const math = patchStreamingMarkdown("area is $x^", false);
  assert.equal(math, "area is $x^$");
}

// 3. final settles unfinished constructs instead of keeping stream patches
{
  const openFence = "```js\nconsole.log(1)";
  assert.notEqual(patchStreamingMarkdown(openFence, false), openFence);
  assert.equal(patchStreamingMarkdown(openFence, true), openFence);

  const danglingTable = "| a | b |\n| --- | --- |\n| 1";
  assert.notEqual(patchStreamingMarkdown(danglingTable, false), danglingTable);
  assert.equal(patchStreamingMarkdown(danglingTable, true), danglingTable);

  assert.equal(patchStreamingMarkdown("hello **bo", true), "hello **bo");
  assert.equal(patchStreamingMarkdown("area is $x^", true), "area is $x^");
}

// 2. Incremental DOM patch keeps matching nodes and selection
{
  function el(tag, attrs = {}, children = []) {
    return {
      nodeType: 1,
      tagName: tag.toUpperCase(),
      attributes: { ...attrs },
      childNodes: [...children],
      parentNode: null,
      dataset: {},
      textContent: children.map((child) => child.textContent ?? "").join("")
    };
  }

  function text(value) {
    return { nodeType: 3, data: value, textContent: value, parentNode: null };
  }

  function link(parent, children) {
    parent.childNodes = children;
    for (const child of children) child.parentNode = parent;
    return parent;
  }

  const strong = el("strong", {}, [text("world")]);
  const firstP = el("p", {}, [text("hello "), strong]);
  const root = link(el("div"), [firstP]);
  link(firstP, [text("hello "), strong]);
  link(strong, [text("world")]);
  strong.dataset.keep = "yes";

  const selection = { anchorNode: strong.childNodes[0], anchorOffset: 0, focusOffset: 2 };

  const nextStrong = el("strong", {}, [text("world")]);
  const nextP = el("p", {}, [text("hello "), nextStrong, text(" and more")]);
  const incoming = link(el("div"), [nextP]);
  link(nextP, [text("hello "), nextStrong, text(" and more")]);
  link(nextStrong, [text("world")]);

  patchMarkdownDom(root, incoming, { selection });

  assert.equal(root.childNodes[0], firstP);
  assert.equal(firstP.childNodes[1], strong);
  assert.equal(strong.dataset.keep, "yes");
  assert.equal(firstP.childNodes[2].data, " and more");
  assert.equal(selection.anchorNode, strong.childNodes[0]);
  assert.equal(selection.anchorOffset, 0);
  assert.equal(selection.focusOffset, 2);
}

// 4. Smooth stream withholds an opening fence until the line is complete
{
  const stream = createSmoothMarkdownStream({
    startDelayMs: 0,
    minCharsPerSecond: 10_000,
    maxCharsPerSecond: 10_000,
    maxCharsPerCommit: 10_000
  });

  stream.enqueue("```js");
  stream.flush();
  assert.equal(stream.getSnapshot().visible, "");

  stream.enqueue("\nconsole.log(1)");
  stream.flush();
  assert.equal(stream.getSnapshot().visible, "```js\nconsole.log(1)");

  stream.finish({ flush: true });
  assert.equal(stream.getSnapshot().visible, "```js\nconsole.log(1)");
  assert.equal(stream.getSnapshot().final, true);
}

console.log("streaming_markdown_followup_test passed");
