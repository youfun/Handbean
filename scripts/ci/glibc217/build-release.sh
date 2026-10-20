#!/usr/bin/env bash
set -euo pipefail

workspace=/workspace
input=/input
output=/output
build=/build
source_dir="$build/handbean"

rm -rf "$build"
mkdir -p "$source_dir" "$output"

# The checkout is mounted read-only. Archive only Git-tracked source so cache,
# downloaded asset, and host build directories cannot enter the build context.
git -c safe.directory="$workspace" -C "$workspace" archive --format=tar HEAD |
  tar -C "$source_dir" -xf -

source "$workspace/scripts/ci/glibc217/toolchain.sh"

export MIX_ENV=prod
export MIX_HOME=/cache/mix-home
export HEX_HOME=/cache/hex-home
export CARGO_HOME=/cache/cargo-home
export GHOSTTY_BUILD=1
export WHISPER_CPP_BUILD=true
export WHISPER_DONT_GENERATE_BINDINGS=true
# Do not tune whisper.cpp for the transient GitHub runner CPU. Keep the NIF at
# the x86_64 scalar baseline; customers may have older CPUs than the builder.
export GGML_NATIVE=OFF
export GGML_SSE42=OFF
export GGML_AVX=OFF
export GGML_AVX2=OFF
export GGML_FMA=OFF
export GGML_F16C=OFF
export GGML_BMI2=OFF
mkdir -p "$MIX_HOME" "$HEX_HOME" "$CARGO_HOME"

wrapper_bin="$build/bin"
mkdir -p "$wrapper_bin"
ln -s "$workspace/scripts/ci/glibc217/zig-wrapper.sh" "$wrapper_bin/zig"
export PATH="$wrapper_bin:$PATH"

cd "$source_dir"
tar -xzf "$input/handbean-static.tar.gz"
test -s priv/static/cache_manifest.json

cat >config/glibc217.exs <<'EOF'
import Config
import_config "config.exs"
config :elixir_make, :force_build, exqlite: true
EOF
export MIX_CONFIG="$source_dir/config/glibc217.exs"

# Source-building whisper_cpp activates its optional Rustler compiler. This
# edit exists only in the disposable container copy and never changes mix.exs.
if ! grep -Fq '{:rustler, "~> 0.38", runtime: false}' mix.exs; then
  sed -i '/{:rustler_precompiled, "~> 0.10", override: true, optional: true},/a\      {:rustler, "~> 0.38", runtime: false},' mix.exs
fi
grep -Fq '{:rustler, "~> 0.38", runtime: false}' mix.exs

mix local.hex 2.4.1 --force
rebar="$downloads/rebar3-3.25.1"
rebar_sha512=992fd755b7926fae455e5e07d9d195f4d3e7f181609eed1b9cabfe548624df10d148cd4b59bda40bebb185d3d68f9a9fd68a70b294101c8ad9cf0fadcc683d24
if [[ ! -f "$rebar" ]] || [[ $(sha512sum "$rebar" | awk '{print $1}') != "$rebar_sha512" ]]; then
  rm -f "$rebar" "$rebar.part"
  curl -fL --retry 8 --retry-delay 2 --connect-timeout 20 \
    -o "$rebar.part" https://builds.hex.pm/installs/1.18.4/rebar3-3.25.1-otp-28
  mv "$rebar.part" "$rebar"
fi
printf '%s  %s\n' "$rebar_sha512" "$rebar" | sha512sum -c -
mix local.rebar rebar3 "$rebar" --sha512 "$rebar_sha512" --force

mix deps.get --only prod

# The PTY and TTY readers are native threads, not managed NIF entrypoints.
# Require the upstream Zigler context fix; do not hide a stale lock with a CI
# patch that normal Linux and macOS builds would not receive.
for source in deps/ghostty/lib/ghostty/pty_nif.zig deps/ghostty/lib/ghostty/terminal/ghostty_nif.zig; do
  if ! grep -Fq 'beam.independent_context(.{});' "$source"; then
    echo "Ghostty dependency lacks the independent thread-context fix: $source" >&2
    echo "Push the upstream fix and update mix.lock before running this workflow." >&2
    exit 1
  fi
done

mkdir -p deps/ghostty/priv/static
cp "$input/ghostty.js" deps/ghostty/priv/static/ghostty.js

# OXC only creates the already supplied ghostty.js. Its published NIF has a
# newer glibc requirement, so keep it out of this release and skip rebundling
# in the baseline container.
sed -i 's/{:oxc, "~> 0.5"}/{:oxc, "~> 0.5", runtime: false}/' deps/ghostty/mix.exs
sed -i 's/if Code.ensure_loaded?(OXC) do/if System.get_env("GHOSTTY_SKIP_TYPESCRIPT") != "1" and Code.ensure_loaded?(OXC) do/' deps/ghostty/mix.exs
grep -Fq '{:oxc, "~> 0.5", runtime: false}' deps/ghostty/mix.exs
export GHOSTTY_SKIP_TYPESCRIPT=1

ghostty_ref=$(tr -d '[:space:]' <deps/ghostty/.ghostty-ref)
ghostty_source="$build/ghostty-$ghostty_ref"
git init -q "$ghostty_source"
git -C "$ghostty_source" remote add origin https://github.com/ghostty-org/ghostty.git
git -C "$ghostty_source" fetch --depth 1 origin "$ghostty_ref"
git -C "$ghostty_source" checkout --detach FETCH_HEAD
[[ $(git -C "$ghostty_source" rev-parse HEAD) == "$ghostty_ref" ]]
export GHOSTTY_SOURCE_DIR="$ghostty_source"

echo '== compile source-built native dependencies and release =='
rm -rf deps/ghostty/_build/handbean
mix compile --warnings-as-errors
mix release handbean --overwrite

release_dir="$source_dir/_build/prod/rel/handbean"
shopt -s nullglob
terminal_nifs=("$release_dir"/lib/ghostty-*/priv/lib/libElixir.Ghostty.Terminal.Nif.so*)
for terminal_nif in "${terminal_nifs[@]}"; do
  patchelf --set-rpath '$ORIGIN' "$terminal_nif"
done
shopt -u nullglob

bash scripts/version.sh verify-web "$release_dir"
cp scripts/start.sh "$release_dir/start.sh"
chmod +x "$release_dir/start.sh" "$release_dir/bin/handbean"
rm -f "$release_dir/.handbean-host"

for pattern in \
  'lib/exqlite-*/priv/sqlite3_nif.so' \
  'lib/ghostty-*/priv/lib/Elixir.Ghostty.PTY.Nif.so' \
  'lib/ghostty-*/priv/lib/Elixir.Ghostty.Terminal.Nif.so' \
  'lib/whisper_cpp-*/priv/native/whisper_cpp_native.so'; do
  compgen -G "$release_dir/$pattern" >/dev/null || {
    echo "release is missing required source-built native library: $pattern" >&2
    exit 1
  }
done

if find "$release_dir" -path '*/priv/browser-runtime/*' -print -quit | grep -q .; then
  echo "low-baseline release must not contain the Node agent-browser runtime" >&2
  exit 1
fi

archive="$output/handbean-web-linux-x86_64-glibc2.17.tar.gz"
rm -f "$archive" "$archive.sha256"
tar -C "$release_dir" -czf "$archive" .
(
  cd "$output"
  sha256sum "$(basename "$archive")" >"$(basename "$archive").sha256"
)

bash "$workspace/scripts/ci/glibc217/audit-elf.sh" "$release_dir" "$output/audit"
bash "$workspace/scripts/ci/glibc217/smoke-test.sh" \
  "$archive" \
  "$build/smoke" \
  "$toolchain/openssl-3.0.18/bin/openssl" \
  >"$output/smoke-test.txt" 2>&1

cat "$output/audit/totals.txt"
cat "$output/smoke-test.txt"
cat "$archive.sha256"
chmod -R a+rX "$output"
