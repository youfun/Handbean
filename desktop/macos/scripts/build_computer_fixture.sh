#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${1:?Pass a disposable absolute directory}"
[[ "$DEST" == /* && -d "$DEST" ]] || { echo 'Use an existing absolute directory' >&2; exit 1; }
APP="$DEST/ComputerFixture.app"
mkdir -p "$APP/Contents/MacOS"
xcrun swiftc -parse-as-library "$ROOT/Tests/Fixtures/ComputerFixture.swift" -o "$APP/Contents/MacOS/ComputerFixture" -framework AppKit
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.youfun.computerfixture</string>
<key>CFBundleExecutable</key><string>ComputerFixture</string>
<key>CFBundleName</key><string>Computer Use Fixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
printf '%s\n' "$APP"
