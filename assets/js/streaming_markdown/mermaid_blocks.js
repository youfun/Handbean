const MERMAID_LANG = /(?:^|\s)language-mermaid(?:\s|$)/;

let mermaidPromise = null;
let renderSerial = 0;

export function isMermaidCode(code) {
  return MERMAID_LANG.test(code?.className || "");
}

export function mermaidSource(code) {
  return String(code?.textContent ?? "").replace(/\n$/, "");
}

export async function renderMermaidBlocks(root, options = {}) {
  if (!root?.querySelectorAll) return;

  const pending = [...root.querySelectorAll("pre > code")].filter((code) => {
    if (!isMermaidCode(code)) return false;
    const slot = code.closest(".code-block-wrapper") || code.parentElement;
    return slot && !slot.querySelector(".mermaid-diagram[data-mermaid-rendered]");
  });

  if (pending.length === 0) return;

  let mermaid;
  try {
    mermaid = await loadMermaid(options);
  } catch {
    for (const code of pending) showMermaidError(code, "图表渲染失败");
    return;
  }

  for (const code of pending) {
    if (!code.isConnected) continue;
    await renderOne(mermaid, code);
  }
}

function loadMermaid(options) {
  if (options.mermaid) return Promise.resolve(options.mermaid);
  if (!mermaidPromise) {
    mermaidPromise = import("mermaid").then((mod) => {
      const mermaid = mod.default;
      mermaid.initialize({
        startOnLoad: false,
        securityLevel: "strict",
        suppressErrorRendering: true,
        fontFamily: "inherit"
      });
      return mermaid;
    });
  }
  return mermaidPromise;
}

async function renderOne(mermaid, code) {
  const source = mermaidSource(code);
  const id = `mermaid-${Date.now().toString(36)}-${(renderSerial += 1)}`;

  try {
    const parsed = await mermaid.parse(source, { suppressErrors: true });
    if (parsed === false) {
      showMermaidError(code, "图表语法无效");
      return;
    }

    const { svg } = await mermaid.render(id, source);
    mountDiagram(code, svg);
  } catch {
    removeMermaidErrorNode(id);
    showMermaidError(code, "图表渲染失败");
  }
}

function mountDiagram(code, svg) {
  const slot = code.closest(".code-block-wrapper") || code.parentElement;
  if (!slot) return;

  const host = document.createElement("div");
  host.className = "mermaid-diagram";
  host.dataset.mermaidRendered = "true";
  host.innerHTML = svg;

  const pre = code.parentElement;
  if (pre?.tagName === "PRE") pre.hidden = true;
  slot.querySelector(".mermaid-diagram")?.remove();
  slot.querySelector(".mermaid-error")?.remove();
  slot.appendChild(host);
}

function showMermaidError(code, message) {
  const slot = code.closest(".code-block-wrapper") || code.parentElement;
  if (!slot || slot.querySelector(".mermaid-error")) return;

  const note = document.createElement("p");
  note.className = "mermaid-error";
  note.textContent = message;
  slot.appendChild(note);
}

function removeMermaidErrorNode(id) {
  document.getElementById(id)?.remove();
  document.getElementById(`d${id}`)?.remove();
}
