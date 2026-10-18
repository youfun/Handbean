#!/usr/bin/env bash
# Sign Handbean.app with Developer ID, notarize it, staple the ticket, and
# rewrite the release zip. This is direct distribution, not the Mac App Store.
#
# One-time setup (Account Holder):
#   1. developer.apple.com → Certificates → Developer ID Application.
#      Apple Distribution and Apple Development cannot be notarized.
#   2. Keychain Access → Certificate Assistant → Request a Certificate From
#      a Certificate Authority → Saved to disk. Upload the CSR, install the
#      downloaded .cer into the same keychain.
#   3. Store an app-specific password (appleid.apple.com), not the Apple ID password:
#        xcrun notarytool store-credentials handbean-notary \
#          --apple-id "you@example.com" --team-id TEAMID --password "xxxx-xxxx-xxxx-xxxx"
#
# Then, from the repository root, after scripts/build.sh:
#   bash desktop/macos/scripts/notarize_app.sh
#
# API key instead of a keychain profile:
#   NOTARY_KEY=AuthKey_XXX.p8 NOTARY_KEY_ID=XXX NOTARY_ISSUER=XXX \
#     bash desktop/macos/scripts/notarize_app.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/build/Handbean.app}"
ENTITLEMENTS="$ROOT/entitlements.plist"
PROFILE="${NOTARY_KEYCHAIN_PROFILE:-handbean-notary}"

if [[ ! -d "$APP/Contents/MacOS" ]]; then
  echo "error: $APP is not an app bundle. Build it first with scripts/build.sh." >&2
  exit 1
fi

if [[ ! -f "$ENTITLEMENTS" ]]; then
  echo "error: missing $ENTITLEMENTS" >&2
  exit 1
fi

if [[ -z "${CODESIGN_IDENTITY:-}" ]]; then
  CODESIGN_IDENTITY="$(
    security find-identity -v -p codesigning |
      sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' |
      head -1
  )"
fi

if [[ -z "$CODESIGN_IDENTITY" || "$CODESIGN_IDENTITY" != "Developer ID Application:"* ]]; then
  echo "error: no Developer ID Application certificate in the login keychain." >&2
  echo "       Apple Distribution is for the Mac App Store and cannot notarize a direct download." >&2
  echo "       Create a Developer ID Application certificate, then rerun." >&2
  security find-identity -v -p codesigning >&2 || true
  exit 1
fi

notary_args=()
if [[ -n "${NOTARY_KEY:-}" ]]; then
  if [[ -z "${NOTARY_KEY_ID:-}" || -z "${NOTARY_ISSUER:-}" ]]; then
    echo "error: NOTARY_KEY_ID and NOTARY_ISSUER are required with NOTARY_KEY." >&2
    exit 1
  fi
  notary_args=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
else
  if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    echo "error: notarytool has no keychain profile named $PROFILE." >&2
    echo "       Create one with: xcrun notarytool store-credentials $PROFILE --apple-id EMAIL --team-id TEAMID --password APP_SPECIFIC_PASSWORD" >&2
    exit 1
  fi
  notary_args=(--keychain-profile "$PROFILE")
fi

echo "Signing identity: $CODESIGN_IDENTITY"
echo "Clearing xattrs that notarization rejects..."
xattr -cr "$APP"

list="$(mktemp)"
trap 'rm -f "$list"' EXIT

while IFS= read -r -d '' path; do
  kind="$(file -b "$path" || true)"
  [[ "$kind" == *Mach-O* ]] || continue
  depth="$(tr -cd '/' <<<"$path" | wc -c | tr -d ' ')"
  role="lib"
  [[ "$kind" == *executable* ]] && role="exe"
  printf '%s\t%s\t%s\n' "$depth" "$role" "$path"
done < <(find "$APP" -type f -print0) | sort -t $'\t' -k1,1nr >"$list"

count="$(wc -l <"$list" | tr -d ' ')"
if [[ "$count" -eq 0 ]]; then
  echo "error: no Mach-O files in $APP" >&2
  exit 1
fi

echo "Signing $count Mach-O files from the inside out..."
while IFS=$'\t' read -r _depth role path; do
  if [[ "$role" == "exe" ]]; then
    codesign --force --sign "$CODESIGN_IDENTITY" \
      --options runtime --timestamp \
      --entitlements "$ENTITLEMENTS" \
      "$path"
  else
    codesign --force --sign "$CODESIGN_IDENTITY" \
      --options runtime --timestamp \
      "$path"
  fi
done <"$list"

echo "Signing the app bundle..."
codesign --force --sign "$CODESIGN_IDENTITY" \
  --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" \
  "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

archive_dir="$(cd "$(dirname "$APP")" && pwd)"
upload_zip="$(mktemp -t handbean-notarize).zip"
trap 'rm -f "$list" "$upload_zip"' EXIT

echo "Uploading for notarization..."
ditto -c -k --keepParent "$APP" "$upload_zip"
submit_json="$(mktemp)"
set +e
xcrun notarytool submit "$upload_zip" "${notary_args[@]}" --wait --output-format json >"$submit_json"
submit_status=$?
set -e
cat "$submit_json"

submission_id="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("id",""))' "$submit_json")"
accepted="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status",""))' "$submit_json")"
rm -f "$submit_json"

if [[ "$submit_status" -ne 0 || "$accepted" != "Accepted" ]]; then
  echo "error: notarization was not accepted." >&2
  if [[ -n "$submission_id" ]]; then
    xcrun notarytool log "$submission_id" "${notary_args[@]}" >&2 || true
  fi
  exit 1
fi

echo "Stapling the ticket onto $APP..."
stapled=0
for _ in 1 2 3 4 5; do
  if xcrun stapler staple "$APP"; then
    stapled=1
    break
  fi
  sleep 15
done
if [[ "$stapled" -ne 1 ]]; then
  echo "error: stapler did not attach the ticket." >&2
  exit 1
fi
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=4 "$APP"

release_zip="$archive_dir/Handbean-macos-arm64.zip"
checksum="$release_zip.sha256"
rm -f "$release_zip" "$checksum"
ditto -c -k --keepParent "$APP" "$release_zip"
shasum -a 256 "$release_zip" >"$checksum"

echo "Notarized app: $APP"
echo "Release zip:   $release_zip"
echo "SHA-256:       $(awk '{print $1}' "$checksum")"
