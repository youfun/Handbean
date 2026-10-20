// User-visible path: the sidebar is patched by LiveView on every sidebar
// re-render (run status, ages, list refreshes). Those patches must not tear
// down the hover card the pointer is still on, and a hovered row that the
// patch removed must not leave a stale card behind.
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";
import { ConversationHover } from "../js/hooks/conversation_hover.js";

const dom = new JSDOM(`<!doctype html><body>
  <div id="activity-bar">
    <div id="projects-sidebar-scroll">
      <div class="workspace-group" data-workspace-id="ws-1" data-workspace-name="Handbeam"
           data-workspace-path="/dev/Handbeam" data-workspace-repo="Handbeam"
           data-workspace-default="false">
        <div class="workspace-title-row"><button type="button">Handbeam</button></div>
        <div id="row-a" class="conversation-row" data-conversation-id="conv-a"
             data-conversation-title="配置 DeepSeek V4.1 Flash" data-conversation-age="5m">
          <button class="conversation-item" type="button">配置 DeepSeek V4.1 Flash</button>
        </div>
        <div id="row-b" class="conversation-row" data-conversation-id="conv-b"
             data-conversation-title="定时任务读模型" data-conversation-age="12m">
          <button class="conversation-item" type="button">定时任务读模型</button>
        </div>
      </div>
    </div>
    <div id="conversation-hover-card" class="conversation-hover" role="tooltip" hidden>
      <div class="conversation-hover-title-row">
        <span class="conversation-hover-title" data-hover-title></span>
        <button type="button" data-copy></button>
        <span class="conversation-hover-age" data-hover-age hidden></span>
      </div>
      <div data-hover-context="conv-a">context a</div>
      <div data-hover-context="conv-b">context b</div>
    </div>
    <div id="workspace-hover-card" class="workspace-hover" role="tooltip" hidden>
      <div class="workspace-hover-name" data-workspace-hover-name></div>
      <div class="workspace-hover-path" data-workspace-hover-path></div>
      <div class="workspace-hover-repo" data-workspace-hover-repo hidden>
        <span data-workspace-hover-repo-name></span>
      </div>
      <button type="button" data-workspace-hover-rename></button>
      <button type="button" data-workspace-hover-remove></button>
    </div>
  </div>
</body>`);

globalThis.window = dom.window;
globalThis.document = dom.window.document;
globalThis.MutationObserver = dom.window.MutationObserver;

const el = document.getElementById("activity-bar");
const card = document.getElementById("conversation-hover-card");
const workspaceCard = document.getElementById("workspace-hover-card");
const rowA = document.getElementById("row-a");
const rowB = document.getElementById("row-b");
const title = card.querySelector("[data-hover-title]");
const age = card.querySelector("[data-hover-age]");
const rename = workspaceCard.querySelector("[data-workspace-hover-rename]");

const events = [];
const hook = { ...ConversationHover, el, pushEvent: (name, payload) => events.push([name, payload]) };
hook.mounted();

const fire = (node, type, init = {}) =>
  node.dispatchEvent(new window.MouseEvent(type, { bubbles: true, ...init }));
const hover = (node) => fire(node, "pointerover");

// What LiveView actually rewrites on the sidebar subtree: the cards go back to
// their server view (hidden, no `is-open`, every meta row unfiltered, empty
// client-filled text). The hook's updated() is not called for these patches.
function serverPatch() {
  card.hidden = true;
  card.classList.remove("is-open");
  title.textContent = "";
  for (const node of card.querySelectorAll("[data-hover-context]")) node.hidden = false;
  workspaceCard.hidden = true;
  workspaceCard.classList.remove("is-open");
  el.querySelector("[data-workspace-hover-name]").textContent = "";
}

// Mutation notifications are delivered as microtasks.
const flush = () => new Promise((resolve) => setTimeout(resolve, 0));

// ── Opening the card ────────────────────────────────────────────────────
hover(rowA.querySelector("button"));
assert.equal(card.hidden, false);
assert.ok(card.classList.contains("is-open"));
assert.equal(title.textContent, "配置 DeepSeek V4.1 Flash");
assert.equal(age.textContent, "5m");
assert.equal(age.hidden, false);
assert.equal(card.querySelector('[data-hover-context="conv-a"]').hidden, false);
assert.equal(card.querySelector('[data-hover-context="conv-b"]').hidden, true);

// ── Opening the row's context menu dismisses the competing hover card ───
fire(rowA.querySelector("button"), "contextmenu");
assert.equal(card.hidden, true, "right-click must hide the hover card before the menu opens");
assert.equal(hook.row, null);
serverPatch();
await flush();
assert.equal(card.hidden, true, "a sidebar patch must not restore a dismissed hover card");
hover(rowA.querySelector("button"));

// ── A sidebar re-render keeps the card the pointer is still on ──────────
serverPatch();
await flush();
assert.equal(card.hidden, false, "sidebar patch must not hide a hovered card");
assert.ok(card.classList.contains("is-open"));
assert.equal(title.textContent, "配置 DeepSeek V4.1 Flash");
assert.equal(age.textContent, "5m");
assert.equal(
  card.querySelector('[data-hover-context="conv-b"]').hidden,
  true,
  "patch must not leave every meta row visible"
);

// Repeated patches (streaming run status) keep it open too.
serverPatch();
await flush();
serverPatch();
await flush();
assert.equal(card.hidden, false);

// The hook update callback is a separate path and must behave the same way.
serverPatch();
hook.updated();
assert.equal(card.hidden, false);

// ── Moving to another row retargets the card ─────────────────────────────
fire(rowA.querySelector("button"), "pointerout", { relatedTarget: null });
hook.clearHide();
hover(rowB.querySelector("button"));
assert.equal(card.hidden, false);
assert.equal(title.textContent, "定时任务读模型");
assert.equal(card.querySelector('[data-hover-context="conv-a"]').hidden, true);
assert.equal(card.querySelector('[data-hover-context="conv-b"]').hidden, false);
serverPatch();
await flush();
assert.equal(title.textContent, "定时任务读模型");

// ── Leaving the row still hides the card even if a patch lands first ─────
fire(rowB.querySelector("button"), "pointerout", { relatedTarget: null });
serverPatch();
await flush();
await new Promise((resolve) => setTimeout(resolve, 120));
assert.equal(card.hidden, true, "a card the pointer left must stay hidden");

// ── A patch that drops the hovered row closes the card ──────────────────
hover(rowB.querySelector("button"));
assert.equal(card.hidden, false);
rowB.remove();
serverPatch();
await flush();
assert.equal(card.hidden, true, "removed hovered row must not leave a stale card");

// ── Workspace card survives a patch, and closes when its group is gone ──
const group = el.querySelector(".workspace-group");
hover(group.querySelector(".workspace-title-row button"));
assert.equal(workspaceCard.hidden, false);
assert.equal(workspaceCard.querySelector("[data-workspace-hover-name]").textContent, "Handbeam");
assert.equal(workspaceCard.querySelector("[data-workspace-hover-path]").textContent, "/dev/Handbeam");
assert.equal(workspaceCard.querySelector("[data-workspace-hover-repo]").hidden, false);
assert.equal(rename.dataset.workspaceId, "ws-1");

serverPatch();
await flush();
assert.equal(workspaceCard.hidden, false, "sidebar patch must not hide a hovered workspace card");
assert.equal(workspaceCard.querySelector("[data-workspace-hover-name]").textContent, "Handbeam");

group.remove();
serverPatch();
await flush();
assert.equal(workspaceCard.hidden, true);

// ── Workspace actions still reach the LiveView ──────────────────────────
const groupRestored = dom.window.document.createElement("div");
groupRestored.className = "workspace-group";
groupRestored.dataset.workspaceId = "ws-1";
groupRestored.dataset.workspaceName = "Handbeam";
groupRestored.dataset.workspacePath = "/dev/Handbeam";
groupRestored.innerHTML = '<div class="workspace-title-row"><button type="button">Handbeam</button></div>';
document.getElementById("projects-sidebar-scroll").appendChild(groupRestored);
hover(groupRestored.querySelector(".workspace-title-row button"));
rename.dispatchEvent(new window.MouseEvent("click", { bubbles: true }));
assert.deepEqual(events, [["open_rename_workspace", { id: "ws-1" }]]);
assert.equal(workspaceCard.hidden, true);

hook.destroyed();
