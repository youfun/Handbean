#!/usr/bin/env bash
set -euo pipefail
BINARY="${1:?Pass the compiled Handbean executable}"
DEST="${2:?Pass a disposable absolute directory}"
IDENTITY="${3:--}"
[[ -x "$BINARY" && "$DEST" == /* && -d "$DEST" ]] || { echo 'Use an executable and an existing absolute directory' >&2; exit 1; }
python3 - "$DEST" <<'PY'
import os
import pathlib
import sys
directory = pathlib.Path(sys.argv[1]).resolve()
attributes = directory.stat()
if attributes.st_uid != os.getuid() or attributes.st_mode & 0o077:
    raise SystemExit('Verification directory must be owned by you and private (mode 700)')
PY
APP="$DEST/ComputerVerification.app"
mkdir -p "$APP/Contents/MacOS"
cp "$BINARY" "$APP/Contents/MacOS/Handbean"
python3 - "$APP/Contents/Info.plist" "$DEST" <<'PY'
import pathlib
import plistlib
import sys
with open(sys.argv[1], 'wb') as output:
    plistlib.dump({
        'CFBundleIdentifier': 'com.youfun.handbean.computerverification',
        'CFBundleExecutable': 'Handbean',
        'CFBundleName': 'Computer Use Verification',
        'CFBundlePackageType': 'APPL',
        'NSHighResolutionCapable': True,
        'HandbeanComputerVerificationDirectory': str(pathlib.Path(sys.argv[2]).resolve()),
    }, output)
PY
# No launch, TCC grant or installation. Use a stable identity for repeat runs;
# ad-hoc signing defaults to a disposable test build only.
codesign --force --sign "$IDENTITY" "$APP"
printf '%s\n' "$APP"
