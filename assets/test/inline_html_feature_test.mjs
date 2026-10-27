// User-visible path: assistant text → streaming hook → preview/source → later
// deltas → history remount. Catch synthetic fence completion, source corruption,
// iframe replacement (lost input state), raw HTML execution, and stale previews.
// Real Chromium additionally checks script execution and isolation; jsdom cannot.
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";
import { StreamingMarkdown } from "../js/hooks/streaming_markdown.js";

const dom = new JSDOM("<!doctype html><body></body>");
globalThis.window = dom.window;
globalThis.document = dom.window.document;
let copied = "";
Object.defineProperty(dom.window.navigator, "clipboard", {
  configurable: true,
  value: { writeText: async (text) => { copied = text; } }
});
Object.defineProperty(globalThis, "navigator", {
  configurable: true,
  value: dom.window.navigator
});

const el = document.createElement("div");
el.innerHTML = "<div data-markdown-target></div>";
document.body.appendChild(el);
const hook = { ...StreamingMarkdown, el };
const target = el.firstElementChild;
const widget = '<button onclick="this.textContent=7">Count **</button>\n<script>window.count=3</script>\n';
const partial = "Before\n\n```widget\n" + widget;
el.dataset.source = partial;
el.dataset.streaming = "true";
el.dataset.final = "false";
hook.mounted();
hook.controller.reset(partial);
hook.renderSnapshot();

assert.equal(target.querySelectorAll("iframe").length, 1);
assert.equal(target.querySelector("iframe").getAttribute("sandbox"), "");
assert.equal(target.querySelector("code").textContent, widget);
assert.equal(target.querySelector(".html-preview-status").textContent, "生成中 · 脚本暂停");
assert.equal(target.querySelector("pre").hidden, true);

// A closed block is interactive even while the rest of the reply is streaming.
const completed = partial + "```\n\nAfter";
hook.controller.reset(completed);
hook.renderSnapshot();
const frame = target.querySelector("iframe");
assert.equal(frame.getAttribute("sandbox"), "allow-scripts");
assert.equal(frame.getAttribute("referrerpolicy"), "no-referrer");
assert.match(frame.srcdoc, /default-src 'none'/);
assert.match(frame.srcdoc, /connect-src 'none'/);
assert.match(frame.srcdoc, /form-action 'none'/);
assert.ok(frame.srcdoc.includes(widget));
assert.doesNotMatch(frame.srcdoc, /Object\.defineProperty\(window, "handbean"/, "non-chat mounts have no widget bridge");

target.querySelector(".code-block-copy").click();
assert.equal(copied, widget);
const resize = (source, height) => window.dispatchEvent(new window.MessageEvent("message", {
  source, data: { type: "handbean:preview-height", height }
}));
resize(window, 500);
assert.equal(frame.style.height, "", "other windows cannot resize the preview");
resize(frame.contentWindow, 481.2);
assert.equal(frame.style.height, "482px");
resize(frame.contentWindow, 10000);
assert.equal(frame.style.height, "720px");
resize(frame.contentWindow, -3);
assert.equal(frame.style.height, "220px");
resize(frame.contentWindow, NaN);
assert.equal(frame.style.height, "220px");

target.querySelector('[data-html-view="source"]').click();
assert.equal(target.querySelector("pre").hidden, false);
assert.equal(frame.hidden, true);
assert.equal(target.querySelector('[data-html-view="source"]').getAttribute("aria-pressed"), "true");

hook.controller.reset(completed + " more text");
hook.renderSnapshot();
assert.equal(target.querySelector("iframe"), frame);
assert.equal(frame.hidden, true, "later text must preserve the selected view");
target.querySelector('[data-html-view="preview"]').click();
assert.equal(frame.hidden, false);

// Multiple previews, ordinary code, and HTML outside a fence remain distinct.
el.dataset.source = completed + "\n\n```html\n<h2>Second</h2>\n```\n\n```js\n42\n```\n<script>bad()</script>";
el.dataset.streaming = "false";
el.dataset.final = "true";
hook.updated();
assert.equal(target.querySelectorAll("iframe").length, 2);
assert.equal(target.querySelectorAll("script").length, 0);
assert.equal(target.querySelector("code.language-js").textContent, "42\n");
assert.equal(target.querySelectorAll(".code-block-copy").length, 3);

// A longer tilde fence inside a quoted block closes only on a matching marker.
el.dataset.source = "> ~~~~HTML\n> <p>Nested</p>\n> ~~~\n";
hook.updated();
assert.equal(target.querySelector("iframe").getAttribute("sandbox"), "");
el.dataset.source += "> ~~~~\n";
hook.updated();
assert.equal(target.querySelector("iframe").getAttribute("sandbox"), "allow-scripts");
assert.match(target.querySelector("code").textContent, /Nested/);

// A partial line must stay paused. Treating it as closed flips the toolbar
// between 隔离运行 and 脚本暂停 and reloads the iframe on every line.
el.dataset.streaming = "true";
el.dataset.final = "false";
const growing = "```widget\n<div class=\"card\">partial";
hook.controller.reset(growing);
hook.renderSnapshot();
const growingFrame = target.querySelector("iframe");
assert.equal(growingFrame.getAttribute("sandbox"), "");
assert.equal(target.querySelector(".html-preview-status").textContent, "生成中 · 脚本暂停");
hook.controller.reset(growing + " more");
hook.renderSnapshot();
assert.equal(target.querySelector("iframe"), growingFrame, "mid-line growth must not reload the preview");
assert.equal(growingFrame.getAttribute("sandbox"), "");
hook.controller.reset(growing + " more\n");
hook.renderSnapshot();
assert.equal(target.querySelector("iframe"), growingFrame);
assert.equal(target.querySelector("code").textContent, "<div class=\"card\">partial more\n");
hook.controller.reset("> ~~~~HTML\n> <p>Nest");
hook.renderSnapshot();
assert.equal(target.querySelector("iframe").getAttribute("sandbox"), "");
hook.controller.reset(growing + " more\n</div>\n```");
hook.renderSnapshot();
assert.equal(target.querySelector("iframe").getAttribute("sandbox"), "allow-scripts");

// Reconnect renders from the persisted Markdown alone, without a new store.
hook.destroyed();
target.innerHTML = '<div class="markdown-noscript-fallback"></div>';
hook.mounted();
assert.equal(target.querySelectorAll("iframe").length, 1);
el.dataset.source = "A replacement reply";
hook.updated();
assert.equal(target.querySelectorAll("iframe").length, 0);
hook.destroyed();

// The main chat surface opts into widget actions explicitly. Commands are
// attributed from the real frame/DOM context, never from iframe-provided IDs.
const widgetEl = document.createElement("div");
const widgetSource = "```widget\n<button>One</button>\n```\n\n```widget\n<button>Two</button>\n```\n";
widgetEl.dataset.source = widgetSource;
widgetEl.dataset.streaming = "false";
widgetEl.dataset.final = "true";
widgetEl.dataset.widgetActions = "true";
widgetEl.dataset.entryId = "entry-real";
widgetEl.dataset.conversationId = "conversation-real";
widgetEl.innerHTML = "<div data-markdown-target></div>";
document.body.appendChild(widgetEl);
const widgetCallbacks = new Map();
const pushed = [];
const widgetHook = {
  ...StreamingMarkdown,
  el: widgetEl,
  handleEvent: (name, callback) => widgetCallbacks.set(name, callback),
  pushEvent: (name, payload) => pushed.push([name, payload])
};
widgetHook.mounted();
const widgetFrames = [...widgetEl.querySelectorAll("iframe")];
assert.equal(widgetFrames.length, 2);
assert.equal(widgetFrames[0].dataset.fenceIndex, "0");
assert.equal(widgetFrames[1].dataset.fenceIndex, "1");
assert.match(widgetFrames[0].srcdoc, /Object\.defineProperty\(window, "handbean"/);
assert.doesNotMatch(widgetFrames[0].getAttribute("sandbox"), /allow-popups/);
assert.doesNotMatch(widgetFrames[0].srcdoc, /openExternal/);

const posted = [[], []];
widgetFrames.forEach((widgetFrame, index) => {
  Object.defineProperty(widgetFrame.contentWindow, "postMessage", {
    configurable: true,
    value: (message) => posted[index].push(message)
  });
});
const sendFrom = (source, data) => window.dispatchEvent(new window.MessageEvent("message", { source, data }));
const payloadOne = {
  prompt: "Use the first choice",
  selections: [{ label: "Mode", value: true }]
};

sendFrom(window, {
  type: "handbean:widget-command",
  command: "prefill_follow_up",
  payload: payloadOne
});
assert.equal(pushed.length, 0, "a forged event.source must be ignored");

widgetEl.dataset.widgetActions = "false";
sendFrom(widgetFrames[0].contentWindow, {
  type: "handbean:widget-command",
  command: "prefill_follow_up",
  payload: payloadOne
});
assert.equal(pushed.length, 0, "a surface without capability must not forward commands");
widgetEl.dataset.widgetActions = "true";

sendFrom(widgetFrames[0].contentWindow, {
  type: "handbean:widget-state",
  value: { answer: 42, markup: "</script>" }
});
sendFrom(widgetFrames[0].contentWindow, {
  type: "handbean:widget-state",
  value: { oversized: "x".repeat(16 * 1024) }
});

sendFrom(widgetFrames[0].contentWindow, {
  type: "handbean:widget-command",
  command: "prefill_follow_up",
  payload: payloadOne,
  entry_id: "iframe-forgery",
  fence_index: 99
});
sendFrom(widgetFrames[1].contentWindow, {
  type: "handbean:widget-command",
  command: "prefill_follow_up",
  payload: { prompt: "Second widget" }
});
assert.equal(pushed.length, 2);
assert.equal(pushed[0][0], "widget_command");
assert.deepEqual(pushed[0][1], {
  request_id: pushed[0][1].request_id,
  entry_id: "entry-real",
  fence_index: 0,
  command: "prefill_follow_up",
  payload: payloadOne
});
assert.equal(pushed[1][1].entry_id, "entry-real");
assert.equal(pushed[1][1].fence_index, 1);
assert.notEqual(pushed[0][1].request_id, pushed[1][1].request_id);

const result = widgetCallbacks.get("widget-command-result");
result({ request_id: "not-pending", status: "ok" });
assert.equal(posted[0].filter((message) => message.type === "handbean:widget-command-result").length, 0);
result({ request_id: pushed[1][1].request_id, status: "ok" });
assert.deepEqual(posted[1].at(-1), {
  type: "handbean:widget-command-result",
  request_id: pushed[1][1].request_id,
  status: "ok"
});
assert.equal(posted[0].some((message) => message.request_id === pushed[1][1].request_id), false);
result({ request_id: pushed[0][1].request_id, status: "error", reason: "invalid payload" });
assert.deepEqual(posted[0].at(-1), {
  type: "handbean:widget-command-result",
  request_id: pushed[0][1].request_id,
  status: "error",
  reason: "invalid payload"
});

// Replacing an iframe restores the accepted state from the parent-only Map.
widgetEl.dataset.source = widgetSource.replace("One", "One updated");
widgetHook.updated();
const rebuiltFrame = widgetEl.querySelector("iframe");
assert.notEqual(rebuiltFrame, widgetFrames[0]);
assert.match(rebuiltFrame.srcdoc, /"answer":42/);
assert.ok(rebuiltFrame.srcdoc.includes("\\u003c/script>"));
assert.doesNotMatch(rebuiltFrame.srcdoc, /"oversized"/);

// Execute the injected bridge in its own jsdom realm to cover API state limits
// and both Promise receipt paths. Browser sandbox/isolation remains E2E scope.
const bridgeDom = new JSDOM(rebuiltFrame.srcdoc, {
  runScripts: "dangerously",
  beforeParse(bridgeWindow) {
    bridgeWindow.TextEncoder = globalThis.TextEncoder;
    bridgeWindow.ResizeObserver = class {
      observe() {}
    };
  }
});
const bridge = bridgeDom.window.handbean;
assert.deepEqual(JSON.parse(JSON.stringify(bridge.getState())), { answer: 42, markup: "</script>" });
assert.throws(() => bridge.setState({ oversized: "x".repeat(16 * 1024) }), /16 KiB/);

const nextBridgeMessage = (type) => new Promise((resolve) => {
  const listener = (event) => {
    if (event.data?.type !== type) return;
    bridgeDom.window.removeEventListener("message", listener);
    resolve(event.data);
  };
  bridgeDom.window.addEventListener("message", listener);
});
const dispatchToBridge = (data) => bridgeDom.window.dispatchEvent(new bridgeDom.window.MessageEvent("message", {
  source: bridgeDom.window.parent,
  data
}));
const bridgePayload = { prompt: "Continue", selections: [{ label: "Count", value: 2 }] };
const commandMessage = nextBridgeMessage("handbean:widget-command");
const resolved = bridge.prefillFollowUp(bridgePayload);
const command = await commandMessage;
assert.equal(JSON.stringify(command.payload), JSON.stringify(bridgePayload));
dispatchToBridge({
  type: "handbean:widget-command-accepted",
  bridge_request_id: command.bridge_request_id,
  request_id: "parent-ok"
});
dispatchToBridge({ type: "handbean:widget-command-result", request_id: "parent-ok", status: "ok" });
await resolved;

const rejectedCommandMessage = nextBridgeMessage("handbean:widget-command");
const rejected = bridge.sendFollowUpMessage({ prompt: "Reject me" });
const rejectedCommand = await rejectedCommandMessage;
dispatchToBridge({
  type: "handbean:widget-command-accepted",
  bridge_request_id: rejectedCommand.bridge_request_id,
  request_id: "parent-error"
});
dispatchToBridge({
  type: "handbean:widget-command-result",
  request_id: "parent-error",
  status: "error",
  reason: "server rejected"
});
await assert.rejects(rejected, /server rejected/);

for (let index = 0; index < 32; index += 1) {
  bridge.prefillFollowUp({ prompt: `Pending ${index}` });
}
await assert.rejects(
  bridge.prefillFollowUp({ prompt: "One request too many" }),
  /Too many pending widget commands/
);

bridgeDom.window.close();

// Widget state is a bounded LRU: updating an existing key refreshes it, while
// the oldest of more than 256 distinct widget contexts is evicted.
for (let index = 0; index < 255; index += 1) {
  widgetEl.dataset.conversationId = `lru-${index}`;
  sendFrom(rebuiltFrame.contentWindow, {
    type: "handbean:widget-state",
    value: { slot: index }
  });
}
widgetEl.dataset.conversationId = "conversation-real";
sendFrom(rebuiltFrame.contentWindow, {
  type: "handbean:widget-state",
  value: { answer: 43 }
});
widgetEl.dataset.conversationId = "lru-255";
sendFrom(rebuiltFrame.contentWindow, {
  type: "handbean:widget-state",
  value: { slot: 255 }
});

widgetEl.dataset.conversationId = "lru-0";
widgetEl.dataset.source = widgetSource.replace("One", "Eviction probe");
widgetHook.updated();
assert.doesNotMatch(widgetEl.querySelector("iframe").srcdoc, /"slot":0/);

widgetEl.dataset.conversationId = "conversation-real";
widgetEl.dataset.source = widgetSource.replace("One", "Refresh probe");
widgetHook.updated();
assert.match(widgetEl.querySelector("iframe").srcdoc, /"answer":43/);

widgetHook.destroyed();
widgetEl.remove();

dom.window.close();
delete globalThis.window;
delete globalThis.document;
delete globalThis.navigator;
console.log("inline_html_feature_test passed");
