import assert from "node:assert/strict";
import { JSDOM } from "jsdom";
import { ScheduleCountdown } from "../js/hooks/schedule_countdown.js";

const dom = new JSDOM(`
  <div id="once-card-status">5 分钟后，只一次 · 下次还要 · 2026-10-12 10:05</div>
  <p
    id="once-countdown"
    data-at="2026-10-12T02:05:00Z"
    data-due-target="once-card-status"
    data-due-lines="5 分钟后，只一次 · 对话正忙，空闲后开始 · 最迟到 2026-10-12 10:35"
  ></p>
`);

const el = dom.window.document.getElementById("once-countdown");
const status = dom.window.document.getElementById("once-card-status");
const hook = { ...ScheduleCountdown, el };
const realNow = Date.now;

try {
  Date.now = () => Date.parse("2026-10-12T02:00:00Z");
  hook.tick();
  assert.equal(el.textContent, "下次还要 5 分钟");
  assert.match(status.textContent, /下次还要/);

  Date.now = () => Date.parse("2026-10-12T02:05:01Z");
  hook.tick();
  assert.equal(el.textContent, "即将运行");
  assert.equal(status.textContent, el.dataset.dueLines);
  assert.match(status.textContent, /对话正忙，空闲后开始/);
  assert.match(status.textContent, /最迟到/);
} finally {
  Date.now = realNow;
}

console.log("schedule_countdown_test passed");
