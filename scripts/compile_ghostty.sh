#!/usr/bin/env bash
# Run by Mix from the Ghostty dependency directory.
set -euo pipefail

if [[ "$(zig version)" != "0.16.0" ]]; then
  echo "Ghostty source builds require Zig 0.16.0 (see mise.toml)." >&2
  exit 1
fi

host_os="$(uname -s)"
if [[ "$host_os" == Linux ]] && ! command -v patchelf >/dev/null; then
  echo "Ghostty source builds require patchelf on Linux." >&2
  exit 1
fi

export GHOSTTY_BUILD=1
# Mix exposes the parent's compiled dependencies through ERL_LIBS. Keep the
# nested build separate from its locked build directory, then expose ebin
# where Mix's custom dependency compiler expects it.
project_root="$(cd "$(dirname "$0")/.." && pwd)"
# Zig 0.16 ReleaseSafe enables glibc fortify declarations that translate-c
# cannot analyze on Debian 12. This environment applies only to Ghostty's two
# NIFs; Handbeam and libghostty-vt are still built for release.
export MIX_ENV=dev
export MIX_BUILD_PATH="$PWD/_build/handbeam"
export MIX_DEPS_PATH="${MIX_DEPS_PATH:-$project_root/deps}"
compiled_lib_dir="$MIX_BUILD_PATH/lib/ghostty/priv/lib"
compile_args=(--no-deps-check --no-archives-check --no-prune-code-paths --no-protocol-consolidation)

elixir -r lib/mix/tasks/ghostty.setup.ex -S mix ghostty.setup

if [[ ! -f "$compiled_lib_dir/Elixir.Ghostty.Terminal.Nif.so" ||
      ! -f "$compiled_lib_dir/Elixir.Ghostty.PTY.Nif.so" ]]; then
  compile_args=(--force "${compile_args[@]}")
fi

elixir -S mix compile "${compile_args[@]}"

mkdir -p ebin
cp "$MIX_BUILD_PATH/lib/ghostty/ebin/"*.beam "$MIX_BUILD_PATH/lib/ghostty/ebin/ghostty.app" ebin/
lib_dir="$PWD/priv/lib"
mkdir -p "$lib_dir"

for nif in Elixir.Ghostty.Terminal.Nif.so Elixir.Ghostty.PTY.Nif.so; do
  if [[ ! "$compiled_lib_dir/$nif" -ef "$lib_dir/$nif" ]]; then
    cp "$compiled_lib_dir/$nif" "$lib_dir/"
  fi
done

terminal_nif="$lib_dir/Elixir.Ghostty.Terminal.Nif.so"
pty_nif="$lib_dir/Elixir.Ghostty.PTY.Nif.so"

case "$host_os" in
  Darwin)
    for dylib in "$lib_dir"/libghostty-vt*.dylib; do
      install_name_tool -id @loader_path/libghostty-vt.dylib "$dylib"
      codesign --force --sign - "$dylib"
    done
    current_dep="$(otool -L "$terminal_nif" | awk '/libghostty-vt.*\.dylib/ {print $1; exit}')"
    if [[ -z "$current_dep" ]]; then
      echo "Ghostty NIF has no libghostty-vt dependency." >&2
      exit 1
    fi
    install_name_tool -change "$current_dep" @loader_path/libghostty-vt.dylib "$terminal_nif"
    codesign --force --sign - "$terminal_nif"
    ;;
  Linux)
    patchelf --set-rpath '$ORIGIN' "$terminal_nif"
    patchelf --set-rpath '$ORIGIN' "$pty_nif"
    ;;
esac
