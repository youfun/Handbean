import assert from "node:assert/strict";
import { JSDOM } from "jsdom";
import { BoundSelect, ModelPicker, optionMatches } from "../js/hooks/model_picker.js";

const dom = new JSDOM(`<!doctype html><html><body>
  <div id="picker-control" data-model-picker>
    <select class="model-picker-native">
      <option value="mg/a">Alpha</option>
      <option value="mg/b" selected>Beta</option>
    </select>
    <button type="button" data-model-picker-trigger aria-expanded="false">
      <span class="model-picker-trigger-label">Beta</span>
    </button>
    <button type="button" class="model-picker-backdrop" data-model-picker-close hidden></button>
    <div data-model-picker-panel hidden>
      <input data-model-picker-search />
      <section data-model-picker-group>
        <button type="button" data-model-picker-option data-value="mg/a" data-search="alpha mg">Alpha</button>
        <button type="button" data-model-picker-option data-value="mg/b" data-search="beta mg">Beta</button>
      </section>
      <div data-model-picker-empty hidden>No matches</div>
      <button type="button" data-model-picker-close>Close</button>
    </div>
  </div>
</body></html>`, { pretendToBeVisual: true });

globalThis.document = dom.window.document;
globalThis.CustomEvent = dom.window.CustomEvent;
globalThis.Event = dom.window.Event;
globalThis.requestAnimationFrame = (callback) => {
  callback();
  return 0;
};

const element = document.getElementById("picker-control");
const picker = { ...ModelPicker, el: element };
let changes = 0;
element.querySelector("select").addEventListener("change", () => { changes += 1; });

picker.mounted();
assert.equal(element.dataset.enhanced, "true");
assert.equal(element.querySelector("select").getAttribute("aria-hidden"), "true");
assert.equal(element.querySelector("select").tabIndex, -1);

const trigger = element.querySelector("[data-model-picker-trigger]");
trigger.click();
assert.equal(element.querySelector("[data-model-picker-panel]").hidden, false);
assert.equal(trigger.getAttribute("aria-expanded"), "true");

const options = [...element.querySelectorAll("[data-model-picker-option]")];
assert.equal(optionMatches(options[0], "alp"), true);
assert.equal(optionMatches(options[1], "alp"), false);

const search = element.querySelector("[data-model-picker-search]");
search.value = "alpha";
search.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
assert.equal(options[0].hidden, false);
assert.equal(options[1].hidden, true);

options[0].click();
assert.equal(element.querySelector("select").value, "mg/a");
assert.equal(changes, 1);
assert.equal(element.querySelector("[data-model-picker-panel]").hidden, true);
assert.equal(trigger.getAttribute("aria-expanded"), "false");

picker.destroyed();

const bound = document.createElement("select");
bound.setAttribute("data-value", "off");
bound.innerHTML = "<option value='low' selected>Low</option><option value='off'>Off</option>";
document.body.appendChild(bound);
bound.value = "low";
const hook = { ...BoundSelect, el: bound };
hook.updated();
assert.equal(bound.value, "off");

delete globalThis.document;
delete globalThis.CustomEvent;
delete globalThis.Event;
delete globalThis.requestAnimationFrame;
console.log("model_picker_test passed");
