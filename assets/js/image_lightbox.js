const ROOT_ID = "image-lightbox";

let shots = [];
let index = 0;
let returnFocus = null;

export function installImageLightbox() {
  if (window.__handbeanImageLightbox) return;
  window.__handbeanImageLightbox = true;
  document.addEventListener("click", onClick);
  document.addEventListener("keydown", onKey);
}

function onClick(event) {
  const opener = event.target.closest("[data-shot-open]");
  if (opener && document.getElementById("ai-messages")?.contains(opener)) {
    event.preventDefault();
    openFrom(opener);
    return;
  }

  const root = document.getElementById(ROOT_ID);
  if (!root || !root.contains(event.target)) return;

  if (event.target.closest("[data-lightbox-close]")) {
    event.preventDefault();
    close();
    return;
  }

  if (event.target.closest("[data-lightbox-prev]")) {
    event.preventDefault();
    step(-1);
    return;
  }

  if (event.target.closest("[data-lightbox-next]")) {
    event.preventDefault();
    step(1);
    return;
  }

  if (event.target === root) close();
}

function onKey(event) {
  if (!document.getElementById(ROOT_ID)) return;
  if (event.key === "Escape") {
    event.preventDefault();
    close();
  } else if (event.key === "ArrowLeft") {
    step(-1);
  } else if (event.key === "ArrowRight") {
    step(1);
  }
}

function openFrom(opener) {
  shots = Array.from(document.querySelectorAll("#ai-messages [data-shot-open]"))
    .map((node) => ({
      id: node.getAttribute("data-shot-id"),
      src: safeSrc(node.getAttribute("data-shot-src")),
      name: node.getAttribute("data-shot-name") || "image"
    }))
    .filter((shot) => shot.src);

  const id = opener.getAttribute("data-shot-id");
  index = Math.max(0, shots.findIndex((shot) => shot.id === id));
  if (shots.length === 0) return;
  returnFocus = opener;
  render();
}

function step(delta) {
  if (shots.length < 2) return;
  index = (index + delta + shots.length) % shots.length;
  render();
}

function render() {
  const shot = shots[index];
  if (!shot) return close();

  let root = document.getElementById(ROOT_ID);
  if (!root) {
    root = document.createElement("div");
    root.id = ROOT_ID;
    root.className = "image-lightbox";
    root.setAttribute("role", "dialog");
    root.setAttribute("aria-modal", "true");
    root.innerHTML = `
      <div class="image-lightbox-bar">
        <span class="image-lightbox-count" data-lightbox-count></span>
        <span class="image-lightbox-name" data-lightbox-name></span>
        <a class="image-lightbox-icon" data-lightbox-download download aria-label="Download">
          <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 3v12"/><path d="m7 11 5 5 5-5"/><path d="M5 21h14"/></svg>
        </a>
        <button type="button" class="image-lightbox-icon" data-lightbox-close aria-label="Close">
          <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><path d="M6 6l12 12M18 6 6 18"/></svg>
        </button>
      </div>
      <button type="button" class="image-lightbox-nav prev" data-lightbox-prev aria-label="Previous">‹</button>
      <img class="image-lightbox-img" alt="" />
      <button type="button" class="image-lightbox-nav next" data-lightbox-next aria-label="Next">›</button>
    `;
    document.body.appendChild(root);
    root.querySelector("[data-lightbox-close]").focus();
  }

  const many = shots.length > 1;
  root.querySelector("[data-lightbox-count]").textContent = many ? `${index + 1} / ${shots.length}` : "";
  const name = root.querySelector("[data-lightbox-name]");
  name.textContent = shot.name;
  name.title = shot.name;
  const download = root.querySelector("[data-lightbox-download]");
  download.href = shot.src;
  download.setAttribute("download", shot.name || "image");
  root.querySelector(".prev").hidden = !many;
  root.querySelector(".next").hidden = !many;
  const img = root.querySelector(".image-lightbox-img");
  img.alt = shot.name;
  if (img.getAttribute("src") !== shot.src) img.src = shot.src;
}

function close() {
  document.getElementById(ROOT_ID)?.remove();
  shots = [];
  if (returnFocus && returnFocus.isConnected) returnFocus.focus();
  returnFocus = null;
}

function safeSrc(src) {
  if (!src || src === "#") return null;
  if (src.startsWith("/") && !src.startsWith("//")) return src;
  if (src.startsWith("data:image/")) return src;
  try {
    const url = new URL(src, window.location.origin);
    if (url.protocol === "http:" || url.protocol === "https:") return url.href;
  } catch (_) {}
  return null;
}
