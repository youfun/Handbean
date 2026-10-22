import assert from "node:assert/strict";
import { JSDOM } from "jsdom";
import { ConversationContextMenu } from "../js/hooks/conversation_context_menu.js";

const dom = new JSDOM(`<!doctype html><body>
  <div id="workspace-shell">
    <div id="activity-bar">
      <div class="conversation-row" data-conversation-menu-row data-conversation-id="sidebar-conversation">
        <button id="sidebar-conversation-title" type="button">Sidebar conversation</button>
        <div id="conversation-menu-panel-sidebar-conversation" class="conversation-menu-panel"></div>
      </div>
    </div>
    <main id="chat">
      <div id="ai-messages" data-conversation-id="chat-conversation">
        <div id="message-body">Chat message</div>
        <div data-conversation-id="chat-conversation" data-widget-actions="true">
          <button id="widget-action" type="button">Widget action</button>
        </div>
      </div>
    </main>
  </div>
</body>`);

globalThis.window = dom.window;
globalThis.document = dom.window.document;
globalThis.CSS = dom.window.CSS || {};
globalThis.CSS.escape ||= (value) => value;

const root = document.getElementById("workspace-shell");
const pushed = [];
const hook = {
  ...ConversationContextMenu,
  el: root,
  pushEvent: (name, payload) => pushed.push([name, payload]),
};
hook.mounted();

function contextMenu(target) {
  const event = new window.MouseEvent("contextmenu", {
    bubbles: true,
    cancelable: true,
    clientX: 120,
    clientY: 140,
  });
  target.dispatchEvent(event);
  return event;
}

// Conversation metadata is also used by the chat timeline and widgets. Only
// actual sidebar rows own the conversation actions menu.
for (const target of [
  document.getElementById("message-body"),
  document.getElementById("widget-action"),
]) {
  const event = contextMenu(target);
  assert.equal(event.defaultPrevented, false);
  assert.deepEqual(pushed, []);
}

const event = contextMenu(document.getElementById("sidebar-conversation-title"));
assert.equal(event.defaultPrevented, true);
assert.deepEqual(pushed, [
  ["open_conversation_context_menu", { id: "sidebar-conversation" }],
]);

const panel = document.getElementById("conversation-menu-panel-sidebar-conversation");
hook.updated();
assert.equal(panel.classList.contains("is-context"), true);
assert.equal(panel.style.left, "120px");
assert.equal(panel.style.top, "140px");

hook.destroyed();
const eventAfterDestroy = contextMenu(document.getElementById("sidebar-conversation-title"));
assert.equal(eventAfterDestroy.defaultPrevented, false);

dom.window.close();
console.log("conversation_context_menu_test passed");
