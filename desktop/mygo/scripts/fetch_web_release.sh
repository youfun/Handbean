#!/usr/bin/env bash
# Import the Linux x86_64 Web UI release into the MyGo desktop resources.
# Usage: scripts/fetch_web_release.sh [tag]
# HANDBEAN_WEB_TAR=/path/to.tar.gz skips the download.
set -euo pipefail
umask 022

tag="${1:-web-latest}"
root="$(cd "$(dirname "$0")/.." && pwd)"
repo_root="$(cd "$root/../.." && pwd)"
raw_dest="${HANDBEAN_WEB_DEST:-$root/resources/handbean-web}"
# Check the final path component without letting trailing slash or /. syntax
# dereference a destination symlink first.
while [[ "$raw_dest" == */ || "$raw_dest" == */. ]]; do
  if [[ "$raw_dest" == */. ]]; then
    raw_dest="${raw_dest%/.}"
  else
    raw_dest="${raw_dest%/}"
  fi
done
[[ -n "$raw_dest" ]] || raw_dest="/"
if [[ -L "$raw_dest" ]]; then
  echo "refusing symbolic-link Web UI destination: $raw_dest" >&2
  exit 2
fi
dest="$(realpath -m "$raw_dest")"
case "$dest" in
  /|"$HOME"|"$root"|"$(dirname "$root")")
    echo "refusing unsafe Web UI destination: $dest" >&2
    exit 2
    ;;
esac
case "$repo_root/" in
  "$dest/"*)
    echo "refusing Web UI destination that contains the repository: $dest" >&2
    exit 2
    ;;
esac

parent="$(dirname "$dest")"
mkdir -p "$parent"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/handbean-linux-web.XXXXXX")"
stage="$(mktemp -d "$parent/.handbean-web-stage.XXXXXX")"
cleanup() {
  rm -rf "$tmp"
  if [[ -n "$stage" ]]; then
    find "$stage" -type d -exec chmod u+rwx {} \; 2>/dev/null || true
    rm -rf "$stage"
  fi
}
trap cleanup EXIT

archive="$tmp/handbean-web-linux-x86_64.tar.gz"
sidecar="$archive.sha256"
if [[ -n "${HANDBEAN_WEB_TAR:-}" ]]; then
  cp -- "$HANDBEAN_WEB_TAR" "$archive"
  if [[ -f "$HANDBEAN_WEB_TAR.sha256" ]]; then
    cp -- "$HANDBEAN_WEB_TAR.sha256" "$sidecar"
  fi
else
  url="https://github.com/youfun/Handbean/releases/download/$tag/handbean-web-linux-x86_64.tar.gz"
  echo "Downloading $url"
  curl --fail --location --retry 3 --retry-all-errors --output "$archive" "$url"
  curl --fail --location --retry 3 --retry-all-errors --output "$sidecar" "$url.sha256"
fi

if [[ -f "$sidecar" ]]; then
  expected="$(awk 'NR == 1 {print tolower($1)}' "$sidecar")"
  actual="$(sha256sum "$archive" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || {
    echo "sha256 mismatch: $actual != $expected" >&2
    exit 1
  }
  echo "sha256 ok"
fi

entries="$tmp/archive-entries"
if ! tar -tzf "$archive" > "$entries"; then
  echo "cannot list Web UI archive" >&2
  exit 1
fi
if awk '/^\// || /(^|\/)\.\.(\/|$)/ { unsafe = 1 } END { exit unsafe ? 0 : 1 }' "$entries"; then
  echo "Web UI archive contains an unsafe path" >&2
  exit 1
fi
if ! tar -xzf "$archive" -C "$stage"; then
  echo "cannot extract Web UI archive" >&2
  exit 1
fi
# Extraction preserves directory modes from the archive. GNU chmod -R may try
# to descend before changing a mode-000 directory, so first restore owner
# traversal top-down, then apply the public application-data permissions.
if ! find "$stage" -type d -exec chmod u+rwx {} \;; then
  echo "cannot normalize Web UI archive directory access" >&2
  exit 1
fi
chmod -R a+rX "$stage"
links="$tmp/archive-symlinks"
if ! find "$stage" -type l -print0 > "$links"; then
  echo "cannot inspect Web UI archive symlinks" >&2
  exit 1
fi
while IFS= read -r -d '' link; do
  resolved="$(realpath -m "$link")"
  case "$resolved" in
    "$stage"/*) ;;
    *)
      echo "Web UI archive contains a symlink outside its payload: $link" >&2
      exit 1
      ;;
  esac
done < "$links"
launcher="$stage/bin/handbean"
[[ -x "$launcher" ]] || {
  echo "archive does not contain executable bin/handbean" >&2
  exit 1
}
[[ -r "$stage/releases/start_erl.data" ]] || {
  echo "archive does not contain readable releases/start_erl.data" >&2
  exit 1
}

backup=""
if [[ -e "$dest" ]]; then
  backup="$(mktemp -d "$parent/.handbean-web-backup.XXXXXX")"
  rmdir "$backup"
  mv -- "$dest" "$backup"
fi
if mv -- "$stage" "$dest"; then
  stage=""
  if [[ -n "$backup" ]]; then
    rm -rf "$backup"
  fi
else
  if [[ -n "$backup" && ! -e "$dest" ]]; then
    mv -- "$backup" "$dest"
  fi
  echo "could not replace $dest" >&2
  exit 1
fi
echo "Unpacked to $dest"
