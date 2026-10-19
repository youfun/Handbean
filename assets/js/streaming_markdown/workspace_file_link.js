const FILE_EXT =
  "markdown|graphql|svelte|lock|heex|leex|bash|swift|proto|toml|yaml|yml|html|scss|json|mjs|cjs|tsx|jsx|kts|cpp|hpp|exs|eex|erl|hrl|css|txt|md|js|ts|ex|py|rb|go|rs|sh|c|h|cc|kt|sql|vue|zig|java";

const FILE_EXT_RE = new RegExp(`^(?:${FILE_EXT})$`, "i");
const FILE_CITATION_RE = new RegExp(
  String.raw`(^|[\s"'([{（【《,;，、])((?:\.\.?/)?(?:[\w.-]+/)*[\w.-]+\.(?:${FILE_EXT}))(?![A-Za-z0-9])(?::(\d+)(?::\d+)?|\s+第\s*(\d+)\s*行)?`,
  "gi"
);

export function workspaceFileFromHref(href, linkText = "") {
  if (typeof href !== "string") return null;
  const raw = href.trim();
  if (!raw) return null;

  const httpFile = raw.match(/^https?:\/\/([^/?#]+)(\/)?(?:#L(\d+)(?:-L?\d+)?)?$/i);
  if (httpFile) {
    const host = httpFile[1];
    const hostPort = host.match(/^(.+):(\d+)$/);
    const name = decodePath(hostPort ? hostPort[1] : host);
    if (!name || !isFileLikeName(name)) return null;
    return finish(name, hostPort ? Number(hostPort[2]) : parseLine(httpFile[3]), linkText);
  }

  if (/^(?:[a-z][a-z0-9+.-]*:|\/\/)/i.test(raw) && !looksLikeLocalFile(raw)) return null;
  if (raw.startsWith("#") || raw.startsWith("?")) return null;

  let path = raw;
  let line = null;
  const hashLine = path.match(/#L(\d+)(?:-L?\d+)?$/i);
  if (hashLine) {
    line = Number(hashLine[1]);
    path = path.slice(0, hashLine.index);
  }
  path = path.split("?")[0];
  const lineCol = path.match(/:(\d+)(?::\d+)?$/);
  if (lineCol && looksLikeLocalFile(path.slice(0, lineCol.index) || path)) {
    line = Number(lineCol[1]);
    path = path.slice(0, lineCol.index);
  }

  path = decodePath(path);
  if (path == null) return null;
  path = path.replace(/^\.\//, "");
  if (!safeWorkspacePath(path) || !hasCodeExtension(path)) return null;
  return finish(path, line, linkText);
}

export function workspaceFileHref(parsed) {
  if (!parsed?.path) return null;
  return parsed.line ? `${parsed.path}#L${parsed.line}` : parsed.path;
}

export function installWorkspaceFileLinks(md) {
  md.core.ruler.before("linkify", "workspace_file_linkify", (state) => {
    for (const block of state.tokens) {
      if (block.type !== "inline" || !block.children) continue;
      block.children = linkifyFileCitations(block.children, state);
    }
  });

  md.core.ruler.after("linkify", "workspace_file_hrefs", (state) => {
    for (const block of state.tokens) {
      if (block.type !== "inline" || !block.children) continue;
      rewriteFileHrefs(block.children);
    }
  });
}

function linkifyFileCitations(children, state) {
  const out = [];
  let inLink = 0;

  for (const token of children) {
    if (token.type === "link_open") inLink += 1;
    if (token.type === "text" && inLink === 0 && token.content) {
      out.push(...splitFileCitationTokens(token, state));
    } else {
      out.push(token);
    }
    if (token.type === "link_close") inLink = Math.max(0, inLink - 1);
  }

  return out;
}

function splitFileCitationTokens(token, state) {
  const text = token.content;
  const tokens = [];
  let lastIndex = 0;
  FILE_CITATION_RE.lastIndex = 0;
  let match = FILE_CITATION_RE.exec(text);

  while (match) {
    const prefix = match[1] || "";
    const path = match[2];
    const line = parseLine(match[3] || match[4]);
    const start = match.index + prefix.length;
    if (start > lastIndex) tokens.push(textToken(state, text.slice(lastIndex, start)));
    tokens.push(...fileLinkTokens(state, path, line, text.slice(start, FILE_CITATION_RE.lastIndex)));
    lastIndex = FILE_CITATION_RE.lastIndex;
    match = FILE_CITATION_RE.exec(text);
  }

  if (lastIndex === 0) return [token];
  if (lastIndex < text.length) tokens.push(textToken(state, text.slice(lastIndex)));
  return tokens;
}

function rewriteFileHrefs(children) {
  for (let index = 0; index < children.length; index += 1) {
    const token = children[index];
    if (token.type !== "link_open") continue;
    const href = token.attrGet("href") || "";
    const parsed = workspaceFileFromHref(href, linkText(children, index));
    const next = workspaceFileHref(parsed);
    if (next) token.attrSet("href", next);
  }
}

function linkText(children, openIndex) {
  const parts = [];
  for (let index = openIndex + 1; index < children.length; index += 1) {
    const token = children[index];
    if (token.type === "link_close") break;
    if (token.type === "text") parts.push(token.content);
  }
  return parts.join("");
}

function fileLinkTokens(state, path, line, label) {
  const open = new state.Token("link_open", "a", 1);
  open.attrSet("href", workspaceFileHref({ path, line }));
  const text = textToken(state, label);
  const close = new state.Token("link_close", "a", -1);
  return [open, text, close];
}

function textToken(state, content) {
  const token = new state.Token("text", "", 0);
  token.content = content;
  return token;
}

function finish(path, line, linkText) {
  return { path, line: line || lineFromText(linkText) };
}

function lineFromText(text) {
  if (typeof text !== "string") return null;
  const zh = text.match(/第\s*(\d+)\s*行/);
  if (zh) return Number(zh[1]);
  const colon = text.match(/:(\d+)(?::\d+)?\s*$/);
  if (colon) return Number(colon[1]);
  const hash = text.match(/#L(\d+)/i);
  if (hash) return Number(hash[1]);
  return null;
}

function parseLine(value) {
  const line = Number(value);
  return Number.isInteger(line) && line > 0 ? line : null;
}

function decodePath(value) {
  try {
    return decodeURIComponent(value);
  } catch {
    return null;
  }
}

function isFileLikeName(name) {
  if (!name || name.includes("/") || name.includes("\\") || name.includes("..")) return false;
  const parts = name.split(".");
  if (parts.length < 2 || parts.some((part) => !part)) return false;
  return FILE_EXT_RE.test(parts[parts.length - 1]);
}

function looksLikeLocalFile(value) {
  const path = value.split(/[?#]/, 1)[0].replace(/:\d+(?::\d+)?$/, "");
  return /(?:^|\/)[^/:?#\\]+\.[A-Za-z0-9]+$/.test(path) && !path.includes("://");
}

function hasCodeExtension(path) {
  const base = path.split("/").filter(Boolean).pop() || "";
  return isFileLikeName(base);
}

function safeWorkspacePath(path) {
  if (!path || /[\\\u0000-\u001f\u007f%]/.test(path)) return false;
  const parts = path.split("/");
  if (parts.some((part) => part === ".." || part === ".")) return false;
  if (path.startsWith("//")) return false;
  return true;
}
