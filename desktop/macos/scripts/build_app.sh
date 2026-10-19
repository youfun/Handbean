#!/usr/bin/env bash
# Assemble an ad-hoc signed Handbean.app.
# Direct download uses scripts/notarize_app.sh (Developer ID, notarytool, stapler).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WEB_ROOT="${HANDBEAN_WEB_ROOT:-$ROOT/Resources/handbean-web}"
cd "$ROOT"

if [[ -x "$WEB_ROOT/bin/handbean" ]]; then
  bash "$ROOT/../../scripts/version.sh" verify-web "$WEB_ROOT"
fi

swift build -c release --arch arm64
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"
BIN="$BIN_DIR/Handbean"
test -x "$BIN"

APP="$ROOT/build/Handbean.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Handbean"
bash "$ROOT/../../scripts/version.sh" plist "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/Handbean.icns" "$APP/Contents/Resources/Handbean.icns"
chmod +x "$APP/Contents/MacOS/Handbean"

if [[ -x "$WEB_ROOT/bin/handbean" ]]; then
  ditto "$WEB_ROOT" "$APP/Contents/Resources/handbean-web"
  xattr -dr com.apple.quarantine "$APP/Contents/Resources/handbean-web" 2>/dev/null || true
else
  echo "warning: $WEB_ROOT does not contain an executable bin/handbean." >&2
  echo "         The app can attach to a running server, but cannot start one." >&2
fi

declared_minimum="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")"
runtime_binary=("$APP"/Contents/Resources/handbean-web/erts-*/bin/beam.smp)
if [[ -e "${runtime_binary[0]}" ]]; then
  runtime_archs="$(lipo -archs "${runtime_binary[0]}")"
  if [[ " $runtime_archs " != *" arm64 "* ]]; then
    echo "error: bundled OTP runtime is not arm64: $runtime_archs" >&2
    exit 1
  fi

  runtime_minimum="$(vtool -show-build "${runtime_binary[0]}" | awk '/minos/ { print $2; exit }')"
  if [[ -z "$runtime_minimum" ]]; then
    echo "error: cannot determine the bundled OTP runtime's minimum macOS version" >&2
    exit 1
  fi
  if ! awk -v declared="$declared_minimum" -v runtime="$runtime_minimum" 'BEGIN {
    split(declared, d, "."); split(runtime, r, ".")
    exit !((d[1] + 0 > r[1] + 0) || (d[1] + 0 == r[1] + 0 && d[2] + 0 >= r[2] + 0))
  }'; then
    echo "error: LSMinimumSystemVersion $declared_minimum is lower than the OTP runtime minimum $runtime_minimum" >&2
    exit 1
  fi
fi

if ! codesign --force --sign - --identifier com.youfun.handbean \
  --entitlements "$ROOT/entitlements.plist" "$APP"; then
  echo "warning: ad-hoc codesign failed; the app can still be opened locally" >&2
fi

echo "Built $APP"
