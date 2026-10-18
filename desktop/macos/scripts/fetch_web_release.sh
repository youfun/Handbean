#!/usr/bin/env bash
# Download handbean-web-macos-arm64.tar.gz and unpack it into Resources/handbean-web.
# Usage: scripts/fetch_web_release.sh [tag]
#   tag defaults to web-latest.
#   HANDBEAN_WEB_TARBALL=/path/to.tar.gz skips the download.
#   HANDBEAN_WEB_DEST overrides the unpack directory.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAG="${1:-web-latest}"
DEST="${HANDBEAN_WEB_DEST:-$ROOT/Resources/handbean-web}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [[ -n "${HANDBEAN_WEB_TARBALL:-}" ]]; then
  cp "$HANDBEAN_WEB_TARBALL" "$TMP/archive.tar.gz"
else
  URL="https://github.com/youfun/Handbean/releases/download/${TAG}/handbean-web-macos-arm64.tar.gz"
  echo "Downloading $URL"
  curl -fL --retry 3 -o "$TMP/archive.tar.gz" "$URL"
  if curl -fsL --retry 3 -o "$TMP/archive.tar.gz.sha256" "${URL}.sha256"; then
    python3 - "$TMP/archive.tar.gz" "$TMP/archive.tar.gz.sha256" <<'PY'
import hashlib, pathlib, sys
archive, shafile = map(pathlib.Path, sys.argv[1:])
expected = shafile.read_text().split()[0].strip()
digest = hashlib.sha256(archive.read_bytes()).hexdigest()
if digest != expected:
    raise SystemExit(f"sha256 mismatch: {digest} != {expected}")
print("sha256 ok")
PY
  else
    echo "No .sha256 sidecar; continuing without checksum" >&2
  fi
fi

rm -rf "$DEST"
mkdir -p "$DEST"
tar -xzf "$TMP/archive.tar.gz" -C "$DEST"
chmod +x "$DEST/start.sh" "$DEST/bin/handbean"
find "$DEST" -type f -path '*/bin/*' -exec chmod +x {} +
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
test -x "$DEST/bin/handbean"
echo "Unpacked to $DEST"
