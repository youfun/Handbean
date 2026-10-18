const ELEMENT_NODE = 1;
const TEXT_NODE = 3;

export function patchMarkdownDom(current, incoming, options = {}) {
  if (!current || !incoming) return current;
  patchChildren(current, childList(incoming), options.selection || null);
  return current;
}

function patchChildren(parent, incomingChildren, selection) {
  const currentChildren = childList(parent);
  const nextChildren = [];
  const used = new Set();

  for (const incoming of incomingChildren) {
    const match = findReusable(currentChildren, incoming, used);
    if (match) {
      used.add(match);
      if (match.dataset?.htmlPreview || incoming.dataset?.htmlPreview) {
        nextChildren.push(reuseHtmlPreview(match, incoming) || cloneNode(incoming));
      } else {
        patchNode(match, incoming, selection);
        nextChildren.push(match);
      }
    } else {
      nextChildren.push(cloneNode(incoming));
    }
  }

  replaceChildren(parent, nextChildren);
}

function reuseHtmlPreview(match, incoming) {
  const sameState = match.dataset?.htmlPreview === incoming.dataset?.htmlPreview;
  const code = match.querySelector?.("code");
  const nextCode = incoming.querySelector?.("code");
  const sameCode = code?.textContent === nextCode?.textContent;
  if (sameState && sameCode) return match;
  // Keep the paused frame while the fence is still being typed. Replacing it
  // on every token blanks the preview; scripts start only after a real close.
  if (!sameState || match.dataset?.htmlPreview !== "streaming" || !code || !nextCode) return null;

  const nextText = nextCode.textContent ?? "";
  code.textContent = nextText;
  const frame = match.querySelector("iframe:not(.html-preview-frame-pending)");
  const nextFrame = incoming.querySelector("iframe");
  if (frame && nextFrame && nextText.endsWith("\n")) stageStreamingSrcdoc(frame, nextFrame.srcdoc, nextText);
  return match;
}

function stageStreamingSrcdoc(frame, srcdoc, source) {
  const pending = frame.parentNode?.querySelector(".html-preview-frame-pending");
  if ((pending || frame).dataset.previewSource === source) return;
  const target = pending || createPendingFrame(frame);
  const epoch = String(Number(target.dataset.epoch || 0) + 1);
  target.dataset.epoch = epoch;
  target.dataset.previewSource = source;
  target.onload = () => {
    if (!target.isConnected || target.dataset.epoch !== epoch) return;
    const current = target.previousElementSibling;
    if (!current || current === target) return;
    target.classList.remove("html-preview-frame-pending");
    target.hidden = current.hidden;
    if (current.style?.height) target.style.height = current.style.height;
    target.onload = null;
    current.remove();
  };
  target.srcdoc = srcdoc;
}

function createPendingFrame(frame) {
  const pending = frame.cloneNode(false);
  pending.classList.add("html-preview-frame-pending");
  pending.hidden = true;
  pending.removeAttribute("srcdoc");
  frame.after(pending);
  return pending;
}

function patchNode(current, incoming, selection) {
  if (isText(current) && isText(incoming)) {
    const next = textValue(incoming);
    if (textValue(current) !== next) setText(current, next);
    return;
  }

  if (!isElement(current) || !isElement(incoming)) return;
  if (tagName(current) !== tagName(incoming)) return;
  if (shouldPreserveRendered(current)) return;
  copyAttributes(current, incoming);
  patchChildren(current, childList(incoming), selection);
}

function shouldPreserveRendered(node) {
  const marker = node.getAttribute?.("data-mermaid-rendered") || node.dataset?.mermaidRendered;
  return marker === "true" || marker === true;
}

function findReusable(currentChildren, incoming, used) {
  return currentChildren.find((node) => !used.has(node) && sameShape(node, incoming));
}

function sameShape(left, right) {
  if (isText(left) && isText(right)) return true;
  return isElement(left) && isElement(right) && tagName(left) === tagName(right);
}

function replaceChildren(parent, nextChildren) {
  if (typeof parent.insertBefore === "function") {
    // Detaching an unchanged iframe would destroy its form/interaction state.
    let cursor = parent.firstChild;
    for (const child of nextChildren) {
      if (child !== cursor) parent.insertBefore(child, cursor);
      cursor = child.nextSibling;
    }
    while (cursor) {
      const next = cursor.nextSibling;
      parent.removeChild(cursor);
      cursor = next;
    }
    return;
  }

  parent.childNodes = nextChildren;
  for (const child of nextChildren) child.parentNode = parent;
}

function cloneNode(node) {
  if (typeof node.cloneNode === "function") return node.cloneNode(true);
  if (isText(node)) {
    return { nodeType: TEXT_NODE, data: node.data, textContent: node.data, parentNode: null };
  }

  const clone = {
    nodeType: ELEMENT_NODE,
    tagName: node.tagName,
    attributes: { ...(node.attributes || {}) },
    childNodes: [],
    parentNode: null,
    dataset: { ...(node.dataset || {}) }
  };
  clone.childNodes = childList(node).map((child) => {
    const copied = cloneNode(child);
    copied.parentNode = clone;
    return copied;
  });
  return clone;
}

function childList(node) {
  if (!node) return [];
  if (Array.isArray(node.childNodes)) return [...node.childNodes];
  return node.childNodes ? [...node.childNodes] : [];
}

function copyAttributes(current, incoming) {
  if (incoming.attributes && !current.setAttribute) {
    current.attributes = { ...incoming.attributes };
    return;
  }
  if (!current.setAttribute || !incoming.attributes) return;
  for (const [name, value] of namedAttributes(incoming)) {
    if (!isValidAttrName(name)) continue;
    current.setAttribute(name, value);
  }
}

function namedAttributes(node) {
  const attrs = node.attributes;
  if (!attrs) return [];

  if (Array.isArray(attrs)) {
    return attrs.map((attr) => [attr.name, attr.value]);
  }

  // Live NamedNodeMap is array-like: Object.entries() yields ["0", Attr],
  // and setAttribute("0", ...) throws InvalidCharacterError in the browser.
  if (typeof attrs.item === "function" && typeof attrs.length === "number") {
    const out = [];
    for (let i = 0; i < attrs.length; i += 1) {
      const attr = attrs.item(i);
      if (attr && attr.name) out.push([attr.name, attr.value]);
    }
    return out;
  }

  return Object.entries(attrs).filter(([name, value]) => typeof value === "string" || typeof value === "number");
}

function isValidAttrName(name) {
  return typeof name === "string" && /^[A-Za-z_:][\w:.-]*$/.test(name);
}

function tagName(node) {
  return String(node.tagName || "").toUpperCase();
}

function textValue(node) {
  return node.data ?? node.textContent ?? "";
}

function setText(node, value) {
  if ("data" in node) node.data = value;
  if ("textContent" in node) node.textContent = value;
}

function isElement(node) {
  return Boolean(node) && node.nodeType === ELEMENT_NODE;
}

function isText(node) {
  return Boolean(node) && node.nodeType === TEXT_NODE;
}
