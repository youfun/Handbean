#!/usr/bin/env bash
# Pack one debug APK per Android ABI. Same entry point for a laptop and CI.
#
# Usage:
#   script/pack_android_apks.sh
#   script/pack_android_apks.sh --abi arm64-v8a
#   script/pack_android_apks.sh --skip-setup --skip-test
#
# One APK holds one OTP zip. arm64-v8a is phones; x86_64 is Chromos/emulators.
# Do not install the x86_64 APK on a phone.
set -euo pipefail

PROBE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROBE_ROOT"

abis=(arm64-v8a x86_64)
skip_setup=0
skip_test=0
artifacts_dir="$PROBE_ROOT/artifacts"

usage() {
  sed -n '2,12p' "$0"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --abi)
      [[ $# -ge 2 ]] || { echo "--abi needs a value" >&2; exit 1; }
      abis=("$2")
      shift 2
      ;;
    --skip-setup)
      skip_setup=1
      shift
      ;;
    --skip-test)
      skip_test=1
      shift
      ;;
    --artifacts)
      [[ $# -ge 2 ]] || { echo "--artifacts needs a directory" >&2; exit 1; }
      artifacts_dir="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

for abi in "${abis[@]}"; do
  case "$abi" in
    arm64-v8a|x86_64|armeabi-v7a) ;;
    *)
      echo "unsupported ABI: $abi" >&2
      exit 1
      ;;
  esac
done

# Ubuntu's libgit2-dev ships git2.h but not git2/sys/errors.h. ex_git calls
# git_error_set from that header. The symbol is still in libgit2.so.
# elixir_make replaces the make environment, so an exported CFLAGS never
# reaches the compiler. Write the declaration where the Makefile looks:
# $LIBGIT2_DIR/include/git2/sys/errors.h.
ensure_libgit2_sys_header() {
  local root="${LIBGIT2_DIR:-}"
  if [[ -z "$root" ]]; then
    root="$(brew --prefix libgit2 2>/dev/null || true)"
  fi
  if [[ -z "$root" ]]; then
    if [[ -f /usr/include/git2.h || -f /usr/include/git2/common.h ]]; then
      root="/usr"
    else
      root="/usr/local"
    fi
  fi

  local header="$root/include/git2/sys/errors.h"
  if [[ -f "$header" ]]; then
    echo "libgit2 sys header present: $header"
    return 0
  fi

  local dir tmp
  dir="$(dirname "$header")"
  tmp="$(mktemp)"
  cat > "$tmp" << 'EOF'
#ifndef INCLUDE_git_sys_errors_h__
#define INCLUDE_git_sys_errors_h__
#include "git2/errors.h"
#endif
EOF
  if [[ ! -d "$dir" ]]; then
    mkdir -p "$dir" 2>/dev/null || sudo mkdir -p "$dir"
  fi
  if [[ -w "$dir" ]]; then
    cp "$tmp" "$header"
  else
    sudo cp "$tmp" "$header"
  fi
  rm -f "$tmp"
  echo "installed libgit2 compat header at $header"
  [[ -f "$header" ]] || {
    echo "failed to install $header" >&2
    exit 1
  }
}

# ci_setup runs mix, which compiles ex_git. The header must exist first.
ensure_libgit2_sys_header

if [[ "$skip_setup" -eq 0 ]]; then
  bash "$PROBE_ROOT/script/ci_setup_android.sh"
fi

# mob.pack_apk starts :handbean. Clock reads schedule_runs during that start,
# and a fresh CI database has no schema until this runs.
mix ecto.create --quiet
mix ecto.migrate --quiet

if [[ "$skip_test" -eq 0 ]]; then
  mix test
fi

mkdir -p "$artifacts_dir"

for abi in "${abis[@]}"; do
  out="$artifacts_dir/Handbean-${abi}.apk"
  echo "Packing $abi → $out"
  mix mob.pack_apk --abi "$abi" --no-install --output "$out"
  test -s "$out"
  bash "$PROBE_ROOT/../scripts/version.sh" verify-apk "$out"
done

echo "APKs:"
ls -lh "$artifacts_dir"/Handbean-*.apk
