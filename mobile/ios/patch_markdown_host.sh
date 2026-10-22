#!/bin/bash
# Replay the iOS markdown host patch onto a copy of Mob's label renderer.
# Stock Mob drops unknown props and draws text nodes as plain Text, so assistant
# markdown never reaches Swift. Hex deps are not the source of truth; iOS builds
# run this script and compile the copies.
set -euo pipefail

if [ "$#" -ne 5 ]; then
  echo "usage: patch_markdown_host.sh MOB_IOS_DIR OUT_HEADER OUT_IMPL OUT_NIF OUT_ROOT" >&2
  exit 2
fi

python3 - "$1" "$2" "$3" "$4" "$5" <<'PY'
import pathlib, sys

mob_ios, out_h, out_m, out_nif, out_root = map(pathlib.Path, sys.argv[1:])

def load(name):
    path = mob_ios / name
    if not path.is_file():
        sys.exit(f"missing {path}")
    return path.read_text(encoding="utf-8")

def ensure(text, old, new, label):
    if new in text:
        return text
    count = text.count(old)
    if count != 1:
        sys.exit(f"{label}: expected 1 anchor, found {count}")
    return text.replace(old, new, 1)

header = ensure(
    load("MobNode.h"),
    "@property(nonatomic) CGFloat letterSpacing;\n",
    "@property(nonatomic) CGFloat letterSpacing;\n"
    "// Handbean: forwarded so assistant text can render markdown. Default NO.\n"
    "@property(nonatomic) BOOL markdown;\n"
    "@property(nonatomic) BOOL markdownStreaming;\n",
    "MobNode.h",
)

impl = ensure(
    load("MobNode.m"),
    "        _letterSpacing = 0.0;\n",
    "        _letterSpacing = 0.0;\n"
    "        _markdown = NO;\n"
    "        _markdownStreaming = NO;\n",
    "MobNode.m",
)

nif = load("mob_nif.m").replace('#import "MobDemo-Bridging-Header.h"\n', "", 1)
nif = ensure(
    nif,
    "    MOB_PROP_side_offset,\n    MOB_PROP__COUNT\n",
    "    MOB_PROP_side_offset,\n"
    "    MOB_PROP_markdown,\n"
    "    MOB_PROP_markdown_streaming,\n"
    "    MOB_PROP__COUNT\n",
    "mob_nif.m enum",
)
nif = ensure(
    nif,
    '[MOB_PROP_width] = @"width"};\n',
    '[MOB_PROP_width] = @"width",\n'
    '          [MOB_PROP_markdown] = @"markdown",\n'
    '          [MOB_PROP_markdown_streaming] = @"markdown_streaming"};\n',
    "mob_nif.m names",
)
nif = ensure(
    nif,
    "        id letterSpacing = pv[MOB_PROP_letter_spacing];\n"
    "        if (letterSpacing)\n"
    "            node.letterSpacing = [letterSpacing doubleValue];\n",
    "        id letterSpacing = pv[MOB_PROP_letter_spacing];\n"
    "        if (letterSpacing)\n"
    "            node.letterSpacing = [letterSpacing doubleValue];\n"
    "\n"
    "        id markdown = pv[MOB_PROP_markdown];\n"
    "        if (markdown)\n"
    "            node.markdown = [markdown boolValue];\n"
    "        id markdownStreaming = pv[MOB_PROP_markdown_streaming];\n"
    "        if (markdownStreaming)\n"
    "            node.markdownStreaming = [markdownStreaming boolValue];\n",
    "mob_nif.m assign",
)

root_old = """                let textShouldFill = node.fillWidth || node.textAlign == "center" || node.textAlign == "right"
                Text(node.text ?? "")
                    .font(node.resolvedFont)
                    .foregroundColor(node.textColor.map { Color($0) } ?? Color.primary)
                    .multilineTextAlignment(node.textAlignEnum)
                    .lineSpacing(node.computedLineSpacing)
                    .kerning(node.letterSpacing)
                    // `max_lines`: cap and tail-ellipsise, matching Android's
                    // TextOverflow.Ellipsis. Unset (0) leaves the default
                    // unlimited wrap exactly as it was.
                    .ifLet(node.maxLines > 0 ? node.maxLines : nil) { view, lines in
                        view.lineLimit(lines).truncationMode(.tail)
                    }
                    .ifLet(textShouldFill ? () : nil) { view, _ in
                        view.frame(maxWidth: .infinity, alignment: node.frameTextAlignment)
                    }
"""

root_new = """                let textShouldFill = node.fillWidth || node.textAlign == "center" || node.textAlign == "right"
                Group {
                    if node.markdown {
                        // Handbean markdown. User bubbles stay on the plain Text path.
                        HandbeanMarkdownText(
                            source: node.text ?? "",
                            streaming: node.markdownStreaming,
                            fontSize: node.textSize > 0 ? node.textSize : 14,
                            color: node.textColor.map { Color($0) } ?? Color.primary
                        )
                        .multilineTextAlignment(node.textAlignEnum)
                        .frame(maxWidth: .infinity, alignment: node.frameTextAlignment)
                    } else {
                        Text(node.text ?? "")
                            .font(node.resolvedFont)
                            .foregroundColor(node.textColor.map { Color($0) } ?? Color.primary)
                            .multilineTextAlignment(node.textAlignEnum)
                            .lineSpacing(node.computedLineSpacing)
                            .kerning(node.letterSpacing)
                            .ifLet(node.maxLines > 0 ? node.maxLines : nil) { view, lines in
                                view.lineLimit(lines).truncationMode(.tail)
                            }
                            .ifLet(textShouldFill ? () : nil) { view, _ in
                                view.frame(maxWidth: .infinity, alignment: node.frameTextAlignment)
                            }
                    }
                }
"""

def match_brace(text, open_idx):
    depth = 0
    for i in range(open_idx, len(text)):
        char = text[i]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return i
    sys.exit("MobRootView.swift: unbalanced brace")

def split_node_view_body(text):
    """Give each MobNodeView case its own ViewBuilder.

    The stock body is one expression. Adding the markdown branch makes the
    Swift type checker give up ("unable to type-check this expression in
    reasonable time") on the macOS CI compiler.
    """
    if "private var mobNodeColumn:" in text:
        return text
    struct_at = text.find("struct MobNodeView: View {")
    if struct_at < 0:
        sys.exit("MobRootView.swift: MobNodeView not found")
    struct_brace = text.find("{", struct_at)
    struct_end = match_brace(text, struct_brace)
    body_key = "    var body: some View {"
    body_at = text.find(body_key, struct_at, struct_end)
    if body_at < 0:
        sys.exit("MobRootView.swift: MobNodeView body not found")
    switch_key = "switch node.nodeType {"
    switch_at = text.find(switch_key, body_at, struct_end)
    if switch_at < 0:
        sys.exit("MobRootView.swift: nodeType switch not found")
    switch_brace = text.find("{", switch_at)
    switch_end = match_brace(text, switch_brace)
    inner = text[switch_brace + 1 : switch_end]
    lines = inner.splitlines(keepends=True)
    case_indent = None
    chunks = []
    for line in lines:
        stripped = line.lstrip(" ")
        indent = len(line) - len(stripped.lstrip("\n"))
        # blank lines have no indent signal
        is_case = stripped.startswith("case ") or stripped.startswith("@unknown default")
        if is_case and (case_indent is None or indent == case_indent):
            case_indent = indent
            chunks.append([line])
        elif chunks:
            chunks[-1].append(line)
        # preamble whitespace before the first case is ignored
    if len(chunks) < 2:
        sys.exit("MobRootView.swift: could not split nodeType cases")

    helpers = []
    new_cases = []
    for chunk in chunks:
        header = chunk[0].strip()
        if header.startswith("@unknown"):
            name = "mobNodeUnknown"
        else:
            kind = header.split(".", 1)[1].split(":", 1)[0].strip()
            name = "mobNode" + kind[0].upper() + kind[1:]
        body = "".join(chunk[1:]).rstrip() + "\n"
        helpers.append(
            "    @ViewBuilder\n"
            f"    private var {name}: some View {{\n"
            f"{body}"
            "    }\n"
        )
        new_cases.append(chunk[0].rstrip() + "\n" + (" " * (case_indent + 4)) + name + "\n")

    replacement = "\n" + "".join(new_cases) + " " * (case_indent - 4)
    text = text[: switch_brace + 1] + replacement + text[switch_end:]
    # struct_end moved by the length delta
    delta = len(replacement) - len(inner)
    struct_end += delta
    helper_block = "\n" + "\n".join(helpers)
    return text[:struct_end] + helper_block + text[struct_end:]

root = load("MobRootView.swift")
root = ensure(
    root,
    '    case "history":       return "clock.arrow.circlepath"\n'
    '    case "list":          return "list.bullet"\n',
    '    case "history":       return "clock.arrow.circlepath"\n'
    '    case "folder":        return "folder"\n'
    '    case "expand_more":   return "chevron.down"\n'
    '    case "expand_less":   return "chevron.up"\n'
    '    case "list":          return "list.bullet"\n',
    "MobRootView.swift icons",
)
root = split_node_view_body(root)
# macOS CI images often ship an SDK older than iOS 26. `#available` still
# type-checks `glassEffect`, so hide it from compilers that do not have it.
root = ensure(
    root,
    "            if #available(iOS 26.0, *) {\n"
    "                // `Glass.tint` takes an Optional, so a box whose background failed\n"
    "                // to resolve still gets plain untinted clear glass.\n"
    "                self.glassEffect(.clear.tint(fill), in: shape)\n"
    "            } else {\n",
    "            if #available(iOS 26.0, *) {\n"
    "                #if compiler(>=6.2)\n"
    "                self.glassEffect(.clear.tint(fill), in: shape)\n"
    "                #else\n"
    "                self.background(.ultraThinMaterial, in: shape)\n"
    "                    .background(fill ?? Color.clear, in: shape)\n"
    "                #endif\n"
    "            } else {\n",
    "MobRootView.swift glass",
)
if "HandbeanMarkdownText(" not in root:
    if root.count(root_old) != 1:
        sys.exit(f"MobRootView.swift: expected 1 label anchor, found {root.count(root_old)}")
    root = root.replace(root_old, root_new, 1)

for path, text in ((out_h, header), (out_m, impl), (out_nif, nif), (out_root, root)):
    path.write_text(text, encoding="utf-8")
PY
