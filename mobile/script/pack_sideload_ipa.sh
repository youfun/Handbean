#!/usr/bin/env bash
# Pack an ad-hoc signed iOS IPA with no provisioning profile.
# A user re-signs it with their own Apple ID (Sideloadly or AltStore) and installs it.
# This is not the TestFlight / App Store package.
set -euo pipefail

PROBE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROBE_ROOT"

artifacts_dir="$PROBE_ROOT/artifacts"

usage() {
  cat <<'EOF'
Usage: script/pack_sideload_ipa.sh [--artifacts directory]

Writes Handbean-ios-sideload.ipa and Handbean-ios-sideload.ipa.sha256.
The IPA is ad-hoc signed and contains no embedded.mobileprovision.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
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

if [[ ! -f priv/generated/driver_tab_ios.c ]]; then
  echo "missing priv/generated/driver_tab_ios.c" >&2
  exit 1
fi

if ! xcrun -sdk iphoneos --show-sdk-path >/dev/null 2>&1; then
  echo "iphoneos SDK not found. Install Xcode." >&2
  exit 1
fi

if [[ -z "$(brew --prefix libgit2 2>/dev/null || true)" ]]; then
  echo "libgit2 is required to compile the host ex_git NIF. Install it with: brew install libgit2" >&2
  exit 1
fi

mix local.hex --force
mix local.rebar --force
mix deps.get
mix mob.write_mob_exs

mkdir -p "$artifacts_dir"
export HANDBEAN_IPA_DIR="$artifacts_dir"
if [[ -n "${HANDREAM_ISH_LIBS:-}" ]]; then
  bash script/link_ios_ish.sh
fi
mix run --no-start script/pack_sideload_ipa.exs

ipa="$artifacts_dir/Handbean-ios-sideload.ipa"
if [[ ! -f "$ipa" ]]; then
  echo "IPA was not written: $ipa" >&2
  exit 1
fi

if unzip -l "$ipa" | grep -q 'embedded.mobileprovision'; then
  echo "sideload IPA must not embed a provisioning profile" >&2
  exit 1
fi

bash "$PROBE_ROOT/../scripts/version.sh" verify-ipa "$ipa"
shasum -a 256 "$ipa" > "$ipa.sha256"
echo "Wrote $ipa"
