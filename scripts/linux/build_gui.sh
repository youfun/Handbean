#!/usr/bin/env bash
# Build the Linux x86_64 Web UI release and experimental MyGo GUI tar/deb
# packages from the same source and version.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
mygo_root="$repo_root/desktop/mygo"
cd "$repo_root"

[[ "$(uname -s)" == Linux ]] || {
  echo "Run this builder on a Linux amd64 machine." >&2
  exit 1
}
case "$(uname -m)" in
  x86_64|amd64) ;;
  *)
    echo "This experimental builder currently supports Linux amd64 only." >&2
    exit 1
    ;;
esac

export MIX_BUILD_PATH="$repo_root/_build/gui-linux-x86_64"
export MIX_DEPS_PATH="$repo_root/_build/gui-linux-x86_64-deps"

# Mix symlinks the root application's priv directory into the build. Preserve
# native artifacts produced by another host, then force Linux to rebuild only
# the NIFs owned by this application. Dependency native outputs are isolated by
# MIX_DEPS_PATH. Finish and verify every backup before enabling the trap: a
# partial backup must never authorize deletion of an original file.
native_backup="$(mktemp -d "${TMPDIR:-/tmp}/handbean-linux-native.XXXXXX")"
native_files=(
  "$repo_root/priv/handbean_storage.so"
  "$repo_root/priv/handbean_darwin_process.so"
)
for native in "${native_files[@]}"; do
  if [[ -f "$native" ]]; then
    backup="$native_backup/$(basename "$native")"
    if ! cp -p -- "$native" "$backup" || ! cmp -s -- "$native" "$backup"; then
      echo "could not safely back up $native; original files were not changed" >&2
      rm -rf -- "$native_backup"
      exit 1
    fi
  fi
done

native_modified=()
native_restore_complete=false
restore_native_artifacts() {
  [[ "$native_restore_complete" == true ]] && return 0
  local failed=0 native backup restore_tmp
  for native in "${native_modified[@]}"; do
    backup="$native_backup/$(basename "$native")"
    if [[ -f "$backup" ]]; then
      restore_tmp="${native}.handbean-restore.$$"
      if cp -p -- "$backup" "$restore_tmp" && mv -f -- "$restore_tmp" "$native"; then
        :
      else
        rm -f -- "$restore_tmp"
        failed=1
      fi
    elif ! rm -f -- "$native"; then
      failed=1
    fi
  done
  if (( failed != 0 )); then
    echo "could not restore every native artifact; backup preserved at $native_backup" >&2
    return 1
  fi
  native_restore_complete=true
  rm -rf -- "$native_backup"
}
trap 'status=$?; restore_native_artifacts || status=1; exit "$status"' EXIT
for native in "${native_files[@]}"; do
  native_modified+=("$native")
  rm -f -- "$native"
done

bash scripts/pack_webui.sh linux-x86_64
restore_native_artifacts
trap - EXIT
export HANDBEAN_WEB_TAR="$repo_root/handbean-web-linux-x86_64.tar.gz"
bash "$mygo_root/scripts/fetch_web_release.sh"
bash "$mygo_root/scripts/build_app.sh"
