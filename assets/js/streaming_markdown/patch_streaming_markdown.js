export function patchStreamingMarkdown(markdown, final = false) {
  const source = String(markdown ?? "");
  if (final || source === "") return source;

  let patched = stripDanglingHtmlLikeTail(source);
  patched = stripDanglingBlockMarker(patched);
  patched = closeDanglingEmphasis(patched);
  patched = closeDanglingMath(patched);
  patched = closeDanglingTableRow(patched);
  patched = closeDanglingFence(patched);
  return patched;
}

function stripDanglingBlockMarker(markdown) {
  return markdown.replace(/(^|\n)[ \t]*(?:[-*+]|\d+[.)]|>)\s*$/u, "$1");
}

function stripDanglingHtmlLikeTail(markdown) {
  return markdown.replace(/<\/?[A-Za-z][A-Za-z0-9:-]*[^>\n]*$/u, "");
}

function closeDanglingEmphasis(markdown) {
  const unmatched = (markdown.match(/\*\*/g) || []).length;
  if (unmatched % 2 === 0) return markdown;
  return `${markdown}**`;
}

function closeDanglingMath(markdown) {
  if ((markdown.match(/(?<!\\)\$/g) || []).length % 2 === 0) return markdown;
  return `${markdown}$`;
}

function closeDanglingTableRow(markdown) {
  const lines = markdown.split("\n");
  const last = lines.at(-1) ?? "";
  if (!/^\|/.test(last) || /\|$/.test(last.trimEnd())) return markdown;
  lines[lines.length - 1] = `${last.trimEnd()} |`;
  return lines.join("\n");
}

function closeDanglingFence(markdown) {
  const lines = markdown.split("\n");
  let openFence = null;

  for (const line of lines) {
    const match = line.match(/^([ \t]*)(`{3,}|~{3,})(.*)$/u);
    if (!match) continue;

    const marker = match[2];
    const char = marker[0];
    const length = marker.length;

    if (!openFence) {
      openFence = { char, length };
      continue;
    }

    if (char === openFence.char && length >= openFence.length && line.trim().replace(new RegExp(`\\${char}`, "g"), "") === "") {
      openFence = null;
    }
  }

  if (!openFence) return markdown;
  const close = openFence.char.repeat(openFence.length);
  return markdown.endsWith("\n") ? `${markdown}${close}` : `${markdown}\n${close}`;
}
