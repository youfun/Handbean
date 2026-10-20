#!/usr/bin/env bash
set -euo pipefail

output=${1:?output directory is required}
root=$(cd "$(dirname "$0")/../../.." && pwd)

cd "$root"
rm -rf "$output"
mkdir -p "$output"

export MIX_ENV=prod
mix local.hex 2.4.1 --force
rebar="$output/rebar3-3.25.1"
rebar_sha512=992fd755b7926fae455e5e07d9d195f4d3e7f181609eed1b9cabfe548624df10d148cd4b59bda40bebb185d3d68f9a9fd68a70b294101c8ad9cf0fadcc683d24
curl -fL --retry 8 --retry-delay 2 --connect-timeout 20 \
  -o "$rebar" https://builds.hex.pm/installs/1.18.4/rebar3-3.25.1-otp-28
printf '%s  %s\n' "$rebar_sha512" "$rebar" | sha512sum -c -
mix local.rebar rebar3 "$rebar" --sha512 "$rebar_sha512" --force
mix deps.get --only prod
npm ci

# This host compilation is used only to generate JavaScript and digested Web
# assets. None of its BEAM, NIF, port, or executable output enters the Linux
# release assembled by build-release.sh.
mix compile --warnings-as-errors
mix esbuild.install --if-missing
mix assets.deploy

test -s deps/ghostty/priv/static/ghostty.js
test -s priv/static/cache_manifest.json

tar -C "$root" -czf "$output/handbean-static.tar.gz" priv/static
cp deps/ghostty/priv/static/ghostty.js "$output/ghostty.js"
rm -f "$rebar"
