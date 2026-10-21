import assert from "node:assert/strict";
import { JSDOM } from "jsdom";
import { installImageLightbox } from "../js/image_lightbox.js";

const dom = new JSDOM(`<!doctype html><body>
  <div id="ai-messages">
    <button data-shot-open data-shot-id="shot-1" data-shot-src="/media/conv/a.png" data-shot-name="first.png">1</button>
    <button data-shot-open data-shot-id="shot-2" data-shot-src="/media/conv/b.png" data-shot-name="second.png">2</button>
    <button data-shot-open data-shot-id="shot-3" data-shot-src="/media/conv/c.png" data-shot-name="third.png">3</button>
  </div>
</body>`, { url: "https://handbean.test" });

const { document, MouseEvent, KeyboardEvent } = dom.window;
globalThis.window = dom.window;
globalThis.document = document;

installImageLightbox();

function click(el) {
  el.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true }));
}

function key(key) {
  document.dispatchEvent(new KeyboardEvent("keydown", { key, bubbles: true, cancelable: true }));
}

function lightbox() {
  return document.getElementById("image-lightbox");
}

// Clicking a shot inside #ai-messages opens the lightbox with the right image.
click(document.querySelector('[data-shot-id="shot-2"]'));
let root = lightbox();
assert.ok(root, "lightbox should open");
assert.equal(root.getAttribute("role"), "dialog");
assert.equal(root.getAttribute("aria-modal"), "true");
assert.equal(root.querySelector(".image-lightbox-img").getAttribute("src"), "/media/conv/b.png");
assert.equal(root.querySelector(".image-lightbox-img").alt, "second.png");
assert.equal(root.querySelector("[data-lightbox-name]").textContent, "second.png");
assert.equal(root.querySelector("[data-lightbox-count]").textContent, "2 / 3");
assert.equal(root.querySelector("[data-lightbox-download]").getAttribute("href"), "/media/conv/b.png");
assert.equal(root.querySelector(".prev").hidden, false);
assert.equal(root.querySelector(".next").hidden, false);

// Navigation buttons and arrow keys step through the gallery.
click(root.querySelector("[data-lightbox-next]"));
assert.equal(root.querySelector(".image-lightbox-img").getAttribute("src"), "/media/conv/c.png");
assert.equal(root.querySelector("[data-lightbox-count]").textContent, "3 / 3");
key("ArrowRight");
assert.equal(root.querySelector(".image-lightbox-img").getAttribute("src"), "/media/conv/a.png");
assert.equal(root.querySelector("[data-lightbox-count]").textContent, "1 / 3");
click(root.querySelector("[data-lightbox-prev]"));
assert.equal(root.querySelector(".image-lightbox-img").getAttribute("src"), "/media/conv/c.png");
key("ArrowLeft");
assert.equal(root.querySelector(".image-lightbox-img").getAttribute("src"), "/media/conv/b.png");

// Close button, Escape, and backdrop click all dismiss the dialog.
click(root.querySelector("[data-lightbox-close]"));
assert.equal(lightbox(), null, "close button should remove the lightbox");

click(document.querySelector('[data-shot-id="shot-1"]'));
root = lightbox();
assert.ok(root);
key("Escape");
assert.equal(lightbox(), null, "Escape should close the lightbox");

click(document.querySelector('[data-shot-id="shot-3"]'));
root = lightbox();
assert.ok(root);
click(root);
assert.equal(lightbox(), null, "clicking the backdrop should close the lightbox");

// A single image hides the navigation buttons.
document.getElementById("ai-messages").innerHTML =
  '<button data-shot-open data-shot-id="solo" data-shot-src="/media/conv/solo.png" data-shot-name="solo.png">solo</button>';
click(document.querySelector('[data-shot-id="solo"]'));
root = lightbox();
assert.ok(root);
assert.equal(root.querySelector(".image-lightbox-img").getAttribute("src"), "/media/conv/solo.png");
assert.equal(root.querySelector("[data-lightbox-count]").textContent, "");
assert.equal(root.querySelector(".prev").hidden, true, "prev should be hidden for a single image");
assert.equal(root.querySelector(".next").hidden, true, "next should be hidden for a single image");
click(root.querySelector("[data-lightbox-close]"));
assert.equal(lightbox(), null);

// Shots outside #ai-messages do not open the lightbox.
const outside = document.createElement("button");
outside.setAttribute("data-shot-open", "");
outside.setAttribute("data-shot-id", "outside");
outside.setAttribute("data-shot-src", "/media/conv/outside.png");
document.body.appendChild(outside);
click(outside);
assert.equal(lightbox(), null, "shots outside #ai-messages should not open the lightbox");

console.log("image_lightbox_test: all assertions passed");
