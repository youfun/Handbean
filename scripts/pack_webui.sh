#!/usr/bin/env bash
# Build a self-contained Web UI OTP release and archive it.
# Usage: scripts/pack_webui.sh linux-x86_64|linux-arm64|macos-arm64
set -euo pipefail

target="${1:?target name, e.g. linux-x86_64}"
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

mix local.hex --force
mix local.rebar --force
mix deps.get
npm ci
export MIX_ENV=prod
mix compile
mix esbuild.install --if-missing
mix assets.deploy
mix release --overwrite

release_dir="${MIX_BUILD_PATH:-_build/prod}/rel/handbean"
elixir scripts/package_browser_runtime.exs "$target" "$release_dir"
bash scripts/version.sh verify-web "$release_dir"
cp scripts/start.sh "$release_dir/start.sh"
chmod +x "$release_dir/start.sh" "$release_dir/bin/handbean"

case "$target" in
  macos-*) printf '%s\n' macos > "$release_dir/.handbean-host" ;;
  linux-*) rm -f "$release_dir/.handbean-host" ;;
  *) echo "unsupported Web UI target: $target" >&2; exit 2 ;;
esac

archive="handbean-web-${target}.tar.gz"
rm -f "$archive" "${archive}.sha256"
tar -C "$release_dir" -czf "$archive" .

if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$archive" > "${archive}.sha256"
else
  shasum -a 256 "$archive" > "${archive}.sha256"
fi
