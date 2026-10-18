#!/usr/bin/env bash
# Shared release metadata and Apple/Android package verification.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
metadata="$ROOT/version.properties"
version="$(awk -F= 'NF == 2 && $1 == "version" {sub(/\r$/, "", $2); print $2}' "$metadata")"
build="$(awk -F= 'NF == 2 && $1 == "build" {sub(/\r$/, "", $2); print $2}' "$metadata")"

fail() { echo "version: $*" >&2; exit 1; }

[[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] \
  || fail "expected version=MAJOR.MINOR.PATCH in $metadata"
[[ "$build" =~ ^[1-9][0-9]{0,9}$ ]] && (( build <= 2100000000 )) \
  || fail "expected build between 1 and 2100000000 in $metadata"

verify_plist() {
  local actual_version actual_build
  actual_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1")"
  actual_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$1")"
  [[ "$actual_version" == "$version" && "$actual_build" == "$build" ]] \
    || fail "$1 has $actual_version ($actual_build), expected $version ($build)"
}

case "${1:-}" in
  version) printf '%s\n' "$version" ;;
  build) printf '%s\n' "$build" ;;
  check-tag)
    [[ "${2:-}" == "v$version" ]] || fail "tag must be v$version, got ${2:-<missing>}"
    ;;
  verify-web)
    actual_version="$(awk '{print $2}' "$2/releases/start_erl.data")"
    [[ "$actual_version" == "$version" ]] \
      || fail "$2 has Web release $actual_version, expected $version"
    ;;
  plist)
    cp "$2" "$3"
    /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $version" "$3"
    /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $build" "$3"
    plutil -lint "$3"
    verify_plist "$3"
    ;;
  verify-plist) verify_plist "$2" ;;
  verify-ipa)
    entry="$(unzip -Z1 "$2" | awk '/^Payload\/[^\/]+\.app\/Info\.plist$/')"
    [[ "$entry" =~ ^Payload/[^/]+\.app/Info\.plist$ ]] || fail "expected one app plist in $2"
    tmp="$(mktemp)"
    trap 'rm -f "$tmp"' EXIT
    unzip -p "$2" "$entry" > "$tmp"
    verify_plist "$tmp"
    ;;
  verify-apk)
    aapt="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}/build-tools/35.0.0/aapt"
    [[ -x "$aapt" ]] || aapt="$(command -v aapt)"
    package="$("$aapt" dump badging "$2" | awk '/^package: /')"
    actual_version="$(printf '%s\n' "$package" | sed -n "s/.*versionName='\([^']*\)'.*/\1/p")"
    actual_build="$(printf '%s\n' "$package" | sed -n "s/.*versionCode='\([^']*\)'.*/\1/p")"
    [[ "$actual_version" == "$version" && "$actual_build" == "$build" ]] \
      || fail "$2 has $actual_version ($actual_build), expected $version ($build)"
    ;;
  *) fail "usage: $0 version|build|check-tag TAG|plist TEMPLATE OUTPUT|verify-web DIR|verify-plist FILE|verify-ipa FILE|verify-apk FILE" ;;
esac
