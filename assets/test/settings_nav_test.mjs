import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { JSDOM } from "jsdom";

const template = await readFile(new URL("../../lib/handbean_web/live/settings_live.html.heex", import.meta.url), "utf8");
const source = template.match(/<script\b[^>]*name="\.SettingsNav"[^>]*>([\s\S]*?)<\/script>/)[1];
const { default: SettingsNav } = await import(`data:text/javascript,${encodeURIComponent(source)}`);

const dom = new JSDOM(`<!doctype html><div id="settings-menu">
  <button>Models</button>
  <button aria-current="page">Git</button>
</div>`);

globalThis.requestAnimationFrame = (callback) => {
  callback();
  return 0;
};

const menu = dom.window.document.getElementById("settings-menu");
const active = menu.querySelector("[aria-current='page']");
let options;
active.scrollIntoView = (value) => { options = value; };

const hook = { ...SettingsNav, el: menu };
hook.mounted();
assert.deepEqual(options, { block: "nearest", inline: "center" });

options = undefined;
hook.updated();
assert.equal(options, undefined);

delete globalThis.requestAnimationFrame;
console.log("settings_nav_test passed");
