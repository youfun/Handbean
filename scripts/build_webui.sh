#!/usr/bin/env bash
# Build the production Web UI for this machine without starting a server.
set -euo pipefail

usage() {
  echo "Usage: bash scripts/build_webui.sh"
  echo "Build and package the Web UI for the current Linux/macOS machine. Does not start a server."
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") ;;
  *) usage >&2; exit 2 ;;
esac
if [[ $# -ne 0 ]]; then
  usage >&2
  exit 2
fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
platform="$(uname -s)-$(uname -m)"
case "$platform" in
  Darwin-arm64) target=macos-arm64 ;;
  Linux-x86_64) target=linux-x86_64 ;;
  Linux-aarch64|Linux-arm64) target=linux-arm64 ;;
  *) echo "Unsupported Web UI build platform: $platform" >&2; exit 2 ;;
esac

echo "Building Web UI for $target..."
bash "$root/scripts/pack_webui.sh" "$target"
echo "Web UI build complete. No server was started."
