#!/bin/bash
# ios/release_device.sh — App Store / TestFlight build for Mob (generated
# by `mix mob.release`). Mirrors build_device.sh but with distribution
# signing, no EPMD, no distribution BEAM args, and IPA packaging.
set -e
cd "$(dirname "$0")/.."

MOB_DIR="${MOB_DIR:?MOB_DIR not set}"
ELIXIR_LIB=$(elixir -e "IO.puts(Path.dirname(to_string(:code.lib_dir(:elixir))))" 2>/dev/null)
if [ -z "$ELIXIR_LIB" ] || [ ! -d "$ELIXIR_LIB/elixir/ebin" ]; then
    ELIXIR_LIB="${MOB_ELIXIR_LIB:?MOB_ELIXIR_LIB not set}"
fi
OTP_ROOT="${MOB_IOS_DEVICE_OTP_ROOT:?MOB_IOS_DEVICE_OTP_ROOT not set}"
BUNDLE_ID="${MOB_IOS_BUNDLE_ID:?bundle_id not set}"
TEAM_ID="${MOB_IOS_TEAM_ID:?ios_team_id not set}"
SIGN_IDENTITY="${MOB_IOS_SIGN_IDENTITY:?distribution signing identity not set}"
PROFILE_UUID="${MOB_IOS_PROFILE_UUID:?App Store profile UUID not set}"
APP_NAME="${MOB_APP_NAME:?MOB_APP_NAME not set}"
APP_MODULE="${MOB_APP_MODULE:?MOB_APP_MODULE not set}"
OUTPUT_DIR="${MOB_RELEASE_OUTPUT_DIR:?MOB_RELEASE_OUTPUT_DIR not set}"

ERTS_VSN=$(ls "$OTP_ROOT" | grep '^erts-' | sort -V | tail -1)
[ -z "$ERTS_VSN" ] && echo "ERROR: No erts-* in $OTP_ROOT" && exit 1
OTP_RELEASE=$(ls "$OTP_ROOT/releases" 2>/dev/null | grep -E '^[0-9]+$' | sort -V | tail -1)
[ -z "$OTP_RELEASE" ] && echo "ERROR: No releases/<N>/ in $OTP_ROOT" && exit 1
echo "=== RELEASE: ERTS=$ERTS_VSN OTP=$OTP_RELEASE App=$APP_NAME Bundle=$BUNDLE_ID ==="

BEAMS_DIR="$OTP_ROOT/$APP_MODULE"
SDKROOT=$(xcrun -sdk iphoneos --show-sdk-path)
HOSTCC=$(xcrun -find cc)
CC="$HOSTCC -arch arm64 -miphoneos-version-min=17.0 -isysroot $SDKROOT"

IFLAGS="-I$OTP_ROOT/$ERTS_VSN/include \
        -I$OTP_ROOT/$ERTS_VSN/include/internal \
        -I$MOB_DIR/ios"

LIBS="
  $OTP_ROOT/$ERTS_VSN/lib/libbeam.a
  $OTP_ROOT/$ERTS_VSN/lib/internal/liberts_internal_r.a
  $OTP_ROOT/$ERTS_VSN/lib/internal/libethread.a
  $OTP_ROOT/$ERTS_VSN/lib/libzstd.a
  $OTP_ROOT/$ERTS_VSN/lib/libepcre.a
  $OTP_ROOT/$ERTS_VSN/lib/libryu.a
  $OTP_ROOT/$ERTS_VSN/lib/asn1rt_nif.a
  $OTP_ROOT/$ERTS_VSN/lib/crypto.a
  $OTP_ROOT/$ERTS_VSN/lib/libcrypto.a
"

echo "=== Compiling Erlang/Elixir ==="
mix compile

echo "=== Copying BEAM files to $BEAMS_DIR ==="
mkdir -p "$BEAMS_DIR"
for lib_dir in _build/dev/lib/*/ebin; do
    cp "$lib_dir"/* "$BEAMS_DIR/" 2>/dev/null || true
done

SQLITE_STATIC_LIB=""
if [ -d "_build/dev/lib/exqlite" ]; then
    EXQLITE_VSN=$(grep '"exqlite"' mix.lock \
        | grep -o '"[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*"' | head -1 | tr -d '"')
    [ -z "$EXQLITE_VSN" ] && EXQLITE_VSN=$(grep -o '{vsn,"[^"]*"}' \
        _build/dev/lib/exqlite/ebin/exqlite.app | grep -o '"[^"]*"' | tr -d '"')
    EXQLITE_LIB_DIR="$OTP_ROOT/lib/exqlite-${EXQLITE_VSN}"
    rm -rf "$OTP_ROOT/lib/exqlite-"*
    mkdir -p "$EXQLITE_LIB_DIR/ebin" "$EXQLITE_LIB_DIR/priv"
    cp _build/dev/lib/exqlite/ebin/*.beam "$EXQLITE_LIB_DIR/ebin/"
    cp _build/dev/lib/exqlite/ebin/exqlite.app "$EXQLITE_LIB_DIR/ebin/"

    EXQLITE_SRC="deps/exqlite/c_src"
    BUILD_DIR_TMP=$(mktemp -d)
    $CC -I "$EXQLITE_SRC" -I "$OTP_ROOT/$ERTS_VSN/include" \
        -I "$OTP_ROOT/$ERTS_VSN/include/internal" \
        -DSQLITE_THREADSAFE=1 -DSQLITE_ENABLE_FTS5 -DSTATIC_ERLANG_NIF_LIBNAME=sqlite3_nif \
        -Wno-\#warnings \
        -c "$EXQLITE_SRC/sqlite3_nif.c" -o "$BUILD_DIR_TMP/sqlite3_nif.o"
    $CC -I "$EXQLITE_SRC" -DSQLITE_THREADSAFE=1 -DSQLITE_ENABLE_FTS5 -Wno-\#warnings \
        -c "$EXQLITE_SRC/sqlite3.c" -o "$BUILD_DIR_TMP/sqlite3.o"
    $(xcrun -find ar) rcs "$EXQLITE_LIB_DIR/priv/sqlite3_nif.a" \
        "$BUILD_DIR_TMP/sqlite3_nif.o" "$BUILD_DIR_TMP/sqlite3.o"
    SQLITE_STATIC_LIB="$EXQLITE_LIB_DIR/priv/sqlite3_nif.a"
    rm -rf "$BUILD_DIR_TMP"
fi

# Real crypto + ssl (no shims). The iOS OTP cache ships crypto-5.9 and
# ssl-11.7 (NOT in the slim-strip list below) and the crypto NIF is
# statically linked via crypto.a, so the real beams work on device. The
# old md5-only crypto shim + no-op ssl shim used to be compiled into
# BEAMS_DIR, where (being on the prepended -pa path) they SHADOWED the
# real beams in lib/{crypto,ssl}-*/ebin. That broke TLS: real ssl needs
# ciphers crypto can't provide, and the ssl shim didn't even export
# versions/0 — so Mint hit `:ssl.versions/0 undefined`, every HTTPS
# request crashed, and the orchestra SSE never connected on device.
# Removing the shims lets the real, NIF-backed crypto + ssl load.

echo "=== Copying Elixir stdlib ==="
mkdir -p "$OTP_ROOT/lib/elixir/ebin" "$OTP_ROOT/lib/logger/ebin"
cp "$ELIXIR_LIB/elixir/ebin/"*.beam    "$OTP_ROOT/lib/elixir/ebin/"
cp "$ELIXIR_LIB/elixir/ebin/elixir.app" "$OTP_ROOT/lib/elixir/ebin/"
cp "$ELIXIR_LIB/logger/ebin/"*.beam    "$OTP_ROOT/lib/logger/ebin/"
cp "$ELIXIR_LIB/logger/ebin/logger.app" "$OTP_ROOT/lib/logger/ebin/"
cp "$ELIXIR_LIB/eex/ebin/"*.beam  "$BEAMS_DIR/" 2>/dev/null || true
cp "$ELIXIR_LIB/eex/ebin/eex.app" "$BEAMS_DIR/" 2>/dev/null || true

copy_otp_lib() {
    local APP="$1"
    local SRC
    SRC=$(elixir -e "IO.puts(:code.lib_dir(:${APP}))" 2>/dev/null)
    if [ -n "$SRC" ] && [ -d "$SRC/ebin" ]; then
        local VSN
        VSN=$(basename "$SRC")
        mkdir -p "$OTP_ROOT/lib/$VSN/ebin"
        cp "$SRC/ebin/"*.beam "$OTP_ROOT/lib/$VSN/ebin/"
        cp "$SRC/ebin/${APP}.app" "$OTP_ROOT/lib/$VSN/ebin/"
    fi
}
copy_otp_lib runtime_tools
copy_otp_lib asn1
copy_otp_lib public_key

echo "=== Copying priv (migrations, assets, bundled ebins, app priv) ==="
if [ -d "assets" ]; then
    mix assets.build
fi
# Ship the WHOLE priv/ to the device, not just repo/migrations + static.
# Apps that bundle extra runtime assets under priv/ — e.g. :mix/:hex ebins
# for on-device Mix.install, or a vendored library's priv/static (Livebook) —
# need those on device too. Mirrors the Android deployer, which pushes all
# of priv/. (Previously only priv/repo/migrations and priv/static shipped,
# so priv/mix, priv/hex, priv/<lib>/... silently never reached the device.)
if [ -d "priv" ]; then
    mkdir -p "$BEAMS_DIR/priv"
    rsync -a "priv/" "$BEAMS_DIR/priv/"
fi

APP_VSN=$(grep -o '{vsn,"[^"]*"}' "$BEAMS_DIR/${APP_MODULE}.app" | grep -o '"[^"]*"' | tr -d '"')
if [ -n "$APP_VSN" ]; then
    APP_LIB_DIR="$OTP_ROOT/lib/${APP_MODULE}-${APP_VSN}"
    rm -rf "$APP_LIB_DIR"
    mkdir -p "$APP_LIB_DIR/ebin"
    cp "$BEAMS_DIR/${APP_MODULE}.app" "$APP_LIB_DIR/ebin/"
    if [ -d "$BEAMS_DIR/priv" ]; then
        rsync -a "$BEAMS_DIR/priv/" "$APP_LIB_DIR/priv/"
    fi
fi

cp "$MOB_DIR/assets/logo/logo_dark.png"  "$OTP_ROOT/mob_logo_dark.png"  2>/dev/null || true
cp "$MOB_DIR/assets/logo/logo_light.png" "$OTP_ROOT/mob_logo_light.png" 2>/dev/null || true

echo "=== Compiling native sources (release: -DMOB_RELEASE, no EPMD) ==="
BUILD_DIR=$(mktemp -d)
SWIFT_BRIDGING="$MOB_DIR/ios/MobDemo-Bridging-Header.h"
# Project overlay: stock Mob drops `markdown`. mix mob.release rewrites this
# script; HandbeanProbe.IosMarkdownRelease splices the block back in first.
bash ios/patch_markdown_host.sh "$MOB_DIR/ios" \
    "$BUILD_DIR/MobNode.h" \
    "$BUILD_DIR/MobNode.m" \
    "$BUILD_DIR/mob_nif.m" \
    "$BUILD_DIR/MobRootView.swift"
IFLAGS="-I$BUILD_DIR $IFLAGS"

$CC -fobjc-arc -fmodules $IFLAGS \
    -c "$BUILD_DIR/MobNode.m" -o "$BUILD_DIR/MobNode.o"

SWIFT_SOURCES=("$BUILD_DIR/MobRootView.swift")
for src in "$MOB_DIR"/ios/*.swift; do
    case "$(basename "$src")" in
        MobRootView.swift) ;;
        *) SWIFT_SOURCES+=("$src") ;;
    esac
done
SWIFT_SOURCES+=("ios/HandbeanMarkdown.swift")
if [ -n "${MOB_IOS_PLUGIN_BOOTSTRAP:-}" ]; then
    SWIFT_SOURCES+=("$MOB_IOS_PLUGIN_BOOTSTRAP")
fi
xcrun -sdk iphoneos swiftc \
    -target arm64-apple-ios17.0 \
    -module-name "$APP_NAME" \
    -emit-objc-header -emit-objc-header-path "$BUILD_DIR/MobApp-Swift.h" \
    -import-objc-header "$SWIFT_BRIDGING" \
    -I "$BUILD_DIR" \
    -I "$MOB_DIR/ios" \
    -parse-as-library -wmo \
    -O \
    "${SWIFT_SOURCES[@]}" \
    -c -o "$BUILD_DIR/swift_mob.o"

# MOB_RELEASE on mob_nif.m strips the test harness (synthetic-input
# NIFs that use private UIKit selectors — App Store auto-rejects).
# MOB_ENABLE_SCREENSHOT (set when `ios_release_screenshot: true`) opts the
# public-API screenshot NIF back in — it stays stripped otherwise. `${VAR:+flag}`
# expands to the flag only when VAR is non-empty, so the default build is byte-identical.
$CC -fobjc-arc -fmodules $IFLAGS \
    -I "$BUILD_DIR" -DSTATIC_ERLANG_NIF -DMOB_RELEASE \
    ${MOB_ENABLE_SCREENSHOT:+-DMOB_ENABLE_SCREENSHOT} \
    -c "$BUILD_DIR/mob_nif.m" -o "$BUILD_DIR/mob_nif.o"

# MOB_RELEASE on mob_beam.m drops -name/-setcookie/-kernel-dist BEAM
# args + EPMD thread (no Erlang distribution surface in shipped apps).
$CC -fobjc-arc -fmodules $IFLAGS \
    -DMOB_BUNDLE_OTP \
    -DMOB_RELEASE \
    -DERTS_VSN=\"$ERTS_VSN\" \
    -DOTP_RELEASE=\"$OTP_RELEASE\" \
    -c "$MOB_DIR/ios/mob_beam.m" -o "$BUILD_DIR/mob_beam.o"

SQLITE_FLAG=""
[ -n "$SQLITE_STATIC_LIB" ] && SQLITE_FLAG="-DMOB_STATIC_SQLITE_NIF"
# driver_tab now lives in priv/generated (per-app, regenerated via
# `mix mob.regen_driver_tab --format c`), not $MOB_DIR/ios.
$CC $IFLAGS $SQLITE_FLAG \
    -c "priv/generated/driver_tab_ios.c" -o "$BUILD_DIR/driver_tab_ios.o"

$CC -fobjc-arc -fmodules $IFLAGS \
    -I "$BUILD_DIR" \
    -c ios/AppDelegate.m -o "$BUILD_DIR/AppDelegate.o"

$CC -fobjc-arc -fmodules $IFLAGS \
    -c ios/beam_main.m -o "$BUILD_DIR/beam_main.o"

# erl_errno_id stub: BEAM's erl_posix_str.o references
# erl_errno_id_unknown but the bundled OTP doesn't define it. Weak so
# an OTP-internal definition wins if one ever appears. Written with
# printf (not a heredoc) to stay cleanly indentable inside this
# Elixir """ string. NOTE the single backslash: this is a ~S (raw) heredoc,
# so '%s\\n' would reach bash verbatim and printf would emit a literal
# backslash-n into the C file (clang then rejects `}\n`). '%s\n' emits a real
# newline.
printf '%s\n' '__attribute__((weak)) const char *erl_errno_id_unknown(int error) { (void)error; return "unknown"; }' > "$BUILD_DIR/erl_errno_id_compat.c"
$CC $IFLAGS -c "$BUILD_DIR/erl_errno_id_compat.c" -o "$BUILD_DIR/erl_errno_id_compat.o"

# ── Activated-plugin NIFs ─────────────────────────────────────────────────
# driver_tab_ios references each activated plugin's <module>_nif_init; those
# definitions live in the plugin's iOS NIF source (priv/native/ios/<module>.m,
# lang: :objc). The dev build compiles these via build.zig -Dplugin_c_nifs; the
# release build must do the same or the final link dies with "Undefined
# symbols: _<module>_nif_init". The source basename is the NIF libname →
# -DSTATIC_ERLANG_NIF_LIBNAME=<name> makes ERL_NIF_INIT emit <name>_nif_init.
# -fmodules lets Clang autolink every framework the source @imports (a plugin
# may import frameworks beyond its manifest's declared set, e.g. Accelerate).
PLUGIN_OBJS=""
for SRC in $MOB_PLUGIN_IOS_NIF_SOURCES; do
    NAME=$(basename "$SRC"); NAME="${NAME%.*}"
    case "$SRC" in
        *.m) ARC="-fobjc-arc" ;;
        *)   ARC="" ;;
    esac
    echo "  plugin NIF: $NAME  ($SRC)"
    $CC $ARC -fmodules $IFLAGS \
        -DSTATIC_ERLANG_NIF -DSTATIC_ERLANG_NIF_LIBNAME="$NAME" \
        -c "$SRC" -o "$BUILD_DIR/$NAME.o"
    PLUGIN_OBJS="$PLUGIN_OBJS $BUILD_DIR/$NAME.o"
done

# Project static NIFs (mob.exs :static_nifs). driver_tab_ios references
# each <module>_nif_init; the dev zig build compiles c_src/<name>.c, but
# this script previously did not.
PROJECT_OBJS=""
for SRC in ${MOB_PROJECT_C_NIFS:-}; do
    NAME=$(basename "$SRC"); NAME="${NAME%.*}"
    echo "  project NIF: $NAME  ($SRC)"
    $CC $IFLAGS \
        -DSTATIC_ERLANG_NIF -DSTATIC_ERLANG_NIF_LIBNAME="$NAME" \
        -c "$SRC" -o "$BUILD_DIR/$NAME.o"
    PROJECT_OBJS="$PROJECT_OBJS $BUILD_DIR/$NAME.o"
done

if [ -n "${MOB_BCRYPT_SRC:-}" ]; then
    echo "  project NIF: bcrypt_nif  ($MOB_BCRYPT_SRC)"
    $CC $IFLAGS -DSTATIC_ERLANG_NIF -DSTATIC_ERLANG_NIF_LIBNAME=bcrypt_nif \
        -I "$MOB_BCRYPT_SRC" \
        -c "$MOB_BCRYPT_SRC/bcrypt_nif.c" -o "$BUILD_DIR/bcrypt_nif.o"
    $CC $IFLAGS -I "$MOB_BCRYPT_SRC" \
        -c "$MOB_BCRYPT_SRC/blowfish.c" -o "$BUILD_DIR/blowfish.o"
    PROJECT_OBJS="$PROJECT_OBJS $BUILD_DIR/bcrypt_nif.o $BUILD_DIR/blowfish.o"
fi

# Frameworks the activated plugins declare (explicit, alongside -fmodules
# autolink above): -framework <FW> for each unique name.
PLUGIN_FRAMEWORK_FLAGS=""
for FW in $MOB_PLUGIN_IOS_FRAMEWORKS; do
    PLUGIN_FRAMEWORK_FLAGS="$PLUGIN_FRAMEWORK_FLAGS -Xlinker -framework -Xlinker $FW"
done

ISH_GUEST_FLAGS=""
if [ -n "${HANDREAM_ISH_LIBS:-}" ]; then
    echo "=== Linking iSH guest ==="
    ISH_INCLUDE="${HANDREAM_ISH_INCLUDE:?HANDREAM_ISH_INCLUDE is required with HANDREAM_ISH_LIBS}"
    [ -f "$ISH_INCLUDE/kernel/init.h" ] || { echo "missing $ISH_INCLUDE/kernel/init.h" >&2; exit 1; }
    $CC $IFLAGS -DHANDREAM_IOS_GUEST -I "$ISH_INCLUDE" \
        -c c_src/handbean_ios_guest.c -o "$BUILD_DIR/handbean_ios_guest.o"
    ISH_GUEST_FLAGS="$BUILD_DIR/handbean_ios_guest.o"
    old_ifs=$IFS
    IFS=,
    for lib in $HANDREAM_ISH_LIBS; do
        [ -f "$lib" ] || { echo "missing iSH archive: $lib" >&2; exit 1; }
        ISH_GUEST_FLAGS="$ISH_GUEST_FLAGS $lib"
    done
    IFS=$old_ifs
    ISH_GUEST_FLAGS="$ISH_GUEST_FLAGS -lsqlite3 -lresolv -Xlinker -framework -Xlinker SystemConfiguration"
fi

echo "=== Linking $APP_NAME (release, no EPMD) ==="
xcrun -sdk iphoneos swiftc \
    -target arm64-apple-ios17.0 \
    "$BUILD_DIR/driver_tab_ios.o" \
    "$BUILD_DIR/MobNode.o" \
    "$BUILD_DIR/swift_mob.o" \
    "$BUILD_DIR/mob_nif.o" \
    "$BUILD_DIR/mob_beam.o" \
    "$BUILD_DIR/AppDelegate.o" \
    "$BUILD_DIR/beam_main.o" \
    "$BUILD_DIR/erl_errno_id_compat.o" \
    $PLUGIN_OBJS \
    $PROJECT_OBJS \
    $LIBS \
    "$SQLITE_STATIC_LIB" \
    $ISH_GUEST_FLAGS \
    -lz -lc++ -lpthread \
    -Xlinker -framework -Xlinker UIKit \
    -Xlinker -framework -Xlinker Foundation \
    -Xlinker -framework -Xlinker CoreGraphics \
    -Xlinker -framework -Xlinker QuartzCore \
    -Xlinker -framework -Xlinker SwiftUI \
    $PLUGIN_FRAMEWORK_FLAGS \
    -o "$BUILD_DIR/$APP_NAME"

echo "=== Building .app bundle ==="
APP="$BUILD_DIR/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP"
cp "$BUILD_DIR/$APP_NAME" "$APP/"

cp ios/Info.plist "$APP/"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $APP_NAME"   "$APP/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME"         "$APP/Info.plist"

# Apple's App Store validator requires MinimumOSVersion and DTPlatformName
# in the bundle Info.plist (codes 90065/90507/90530). Both are derived
# from the build target — set them defensively here so any app gets
# them right without needing to remember to add them by hand.
# `Add` errors if the key already exists; fall through to `Set` for the
# idempotent case.
/usr/libexec/PlistBuddy -c "Add :MinimumOSVersion string 17.0" "$APP/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :MinimumOSVersion 17.0" "$APP/Info.plist"
/usr/libexec/PlistBuddy -c "Add :DTPlatformName string iphoneos" "$APP/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :DTPlatformName iphoneos" "$APP/Info.plist"

# The DT* keys ("Development Tools") record what built the bundle.
# App Store Connect's validator (error 90534) cross-references
# DTSDKBuild + DTXcodeBuild against an allow-list of accepted Xcode
# release versions. Without them the upload is rejected as "built
# with an unsupported SDK or Xcode version" even when Xcode is current.
SDK_VERSION=$(xcrun --sdk iphoneos --show-sdk-version)
SDK_BUILD=$(xcrun --sdk iphoneos --show-sdk-build-version)
XCODE_RAW=$(xcodebuild -version | head -1 | awk '{print $2}')
XCODE_BUILD=$(xcodebuild -version | sed -n '2p' | awk '{print $3}')
XCODE_MAJOR=$(echo "$XCODE_RAW" | cut -d. -f1)
XCODE_MINOR=$(echo "$XCODE_RAW" | cut -d. -f2)
[ -z "$XCODE_MINOR" ] && XCODE_MINOR=0
XCODE_PATCH=$(echo "$XCODE_RAW" | cut -d. -f3)
[ -z "$XCODE_PATCH" ] && XCODE_PATCH=0
# DTXcode encoding: e.g. "26.4" → "2640" (major × 1000 + minor × 10 +
# patch). Same scheme Xcode itself stamps into bundles. Computed via
# arithmetic so the result is always 4 digits regardless of how the
# version components were entered.
# Apple's encoding (per their IPA validator): Xcode 16.0 → 1600,
# 16.4 → 1640, 26.4 → 2640. Always 4 digits while major is 2-digit.
DTXCODE=$(( XCODE_MAJOR * 100 + XCODE_MINOR * 10 + XCODE_PATCH ))

for kv in \
    "DTSDKName=iphoneos${SDK_VERSION}" \
    "DTSDKBuild=${SDK_BUILD}" \
    "DTPlatformVersion=${SDK_VERSION}" \
    "DTPlatformBuild=${SDK_BUILD}" \
    "DTXcode=${DTXCODE}" \
    "DTXcodeBuild=${XCODE_BUILD}" \
    "DTCompiler=com.apple.compilers.llvm.clang.1_0" \
    "BuildMachineOSBuild=$(sw_vers -buildVersion)"; do
    K="${kv%%=*}"
    V="${kv#*=}"
    /usr/libexec/PlistBuddy -c "Add :$K string $V" "$APP/Info.plist" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Set :$K $V" "$APP/Info.plist"
done
# UIDeviceFamily is required when MinimumOSVersion >= 3.2 (always, in
# practice). 1 = iPhone, 2 = iPad. Default to iPhone-only; apps that
# want universal can set the array explicitly in their Info.plist
# before this script runs (the `Add` will fail and we won't overwrite).
/usr/libexec/PlistBuddy -c "Add :UIDeviceFamily array" "$APP/Info.plist" 2>/dev/null \
    && /usr/libexec/PlistBuddy -c "Add :UIDeviceFamily:0 integer 1" "$APP/Info.plist"

# CFBundleSupportedPlatforms: array with one string identifying the
# platform the binary was built for. "iPhoneOS" for device builds,
# "iPhoneSimulator" for sim. Apple validator error 90562 if missing.
/usr/libexec/PlistBuddy -c "Add :CFBundleSupportedPlatforms array" "$APP/Info.plist" 2>/dev/null \
    && /usr/libexec/PlistBuddy -c "Add :CFBundleSupportedPlatforms:0 string iPhoneOS" "$APP/Info.plist"

if [ -d "ios/Assets.xcassets/AppIcon.appiconset" ]; then
    ACTOOL_PLIST=$(mktemp /tmp/actool_XXXXXX.plist)
    xcrun actool ios/Assets.xcassets \
        --compile "$APP" --platform iphoneos \
        --minimum-deployment-target 17.0 \
        --app-icon AppIcon \
        --output-partial-info-plist "$ACTOOL_PLIST" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Merge $ACTOOL_PLIST" "$APP/Info.plist" 2>/dev/null || true
    rm -f "$ACTOOL_PLIST"
fi

echo "=== Bundling OTP runtime (no EPMD binary path) ==="
OTP_BUNDLE="$APP/otp"
mkdir -p "$OTP_BUNDLE"
rsync -a --delete "$OTP_ROOT/lib/"      "$OTP_BUNDLE/lib/"
rsync -a --delete "$OTP_ROOT/releases/" "$OTP_BUNDLE/releases/"
rsync -a --delete "$OTP_ROOT/$APP_MODULE/" "$OTP_BUNDLE/$APP_MODULE/"
for f in "$OTP_ROOT"/*.png "$OTP_ROOT"/*.jpg; do
    [ -f "$f" ] && cp "$f" "$OTP_BUNDLE/"
done
mkdir -p "$OTP_BUNDLE/$ERTS_VSN/bin"

# ── App Store bundle policy: ONE Mach-O per .app, no .so/.a/standalone ──
# Apple's validator rejects the bundle if it contains any of:
#   - dynamic loadable libraries (.so files for NIFs/drivers)
#   - static archives (.a — these are linked into the main binary at
#     build time, but copying them into the bundle is still rejected)
#   - standalone executable files (erl_call, memsup, beam.smp, etc.)
# Strip them all from the bundled OTP tree. The static archives are
# already linked into $APP_NAME (the main Mach-O); the .so files
# belong to OTP libs the app doesn't actually use (megaco,
# runtime_tools, asn1's dynamic variant).
# ── Apple-policy strips (always on; not optional for App Store) ──
# Apple's validator rejects bundles containing .so/.a (frameworks must
# use .framework), priv/bin executables, or extra binaries in erts-*/bin.
# The BEAM is static-linked into the main Mach-O so these are
# unreachable from runtime anyway. NOT gated on MOB_SLIM — even
# `--no-slim` builds need to pass App Store validation.
echo "=== Stripping App-Store-disallowed binaries (always on) ==="
find "$OTP_BUNDLE" -type f \( -name "*.so" -o -name "*.a" \) -delete
find "$OTP_BUNDLE" -path "*/priv/bin/*" -type f -delete
find "$OTP_BUNDLE/$ERTS_VSN/bin" -type f -delete 2>/dev/null || true
# Standalone executables inside OTP libs (e.g. erl_interface/bin/erl_call)
# are also rejected by App Store validation (90171) and can't exec on iOS
# anyway. Remove every lib/*/bin/* executable while keeping the libs'
# .beam/.app — so a --no-slim full-OTP bundle (needed for runtime Mix.install)
# still passes Apple's "no standalone executables" rule.
find "$OTP_BUNDLE/lib" -path "*/bin/*" -type f -delete 2>/dev/null || true

# ── Slim strips (gated; opt out with `mix mob.release --no-slim`) ──
# Each step echoes a tagged header AND the bundle size delta so a
# broken build can be traced to a specific step. The grep-friendly tag
# `[SLIM:<step>]` is what the docs walkthrough searches for.
if [ "${MOB_SLIM:-1}" = "1" ]; then
    # Helper to log size delta around a step. Bash function so each
    # step's size delta is visible in the build log without bespoke code.
    slim_step() {
        local label=$1
        local before=$(du -sk "$OTP_BUNDLE" 2>/dev/null | awk '{print $1}')
        shift
        "$@"
        local after=$(du -sk "$OTP_BUNDLE" 2>/dev/null | awk '{print $1}')
        local delta=$((before - after))
        printf "[SLIM:%s] %s KB → %s KB  (-%s KB)\n" "$label" "$before" "$after" "$delta"
    }

    echo "=== Slim strip pass ==="

    slim_step prefix_libs bash -c '
        # Note: compiler intentionally kept — Ecto.Migrator compiles
        # .exs migration files at runtime via Code.compile_file, which
        # requires the :compiler OTP app. Stripping it lands a
        # `{:badmatch, {:error, :enoent, :"compiler.app"}}` deep in
        # application_controller during app boot, so the BEAM never
        # reaches the first screen.
        for prefix in megaco runtime_tools erl_interface os_mon wx et eunit \
                      observer debugger diameter edoc tools snmp dialyzer \
                      syntax_tools parsetools xmerl reltool inets ftp tftp \
                      common_test mnesia eldap odbc \
                      ssh; do
            rm -rf "'"$OTP_BUNDLE"'/lib/$prefix-"*
        done
    '

    slim_step foreign_apps bash -c '
        for prefix in toy_ test_ mob_test scratch_; do
            rm -rf "'"$OTP_BUNDLE"'/lib/$prefix"*-*
        done
    '

    slim_step dedup_versions bash -c '
        set +e
        cd "'"$OTP_BUNDLE"'/lib"
        for name in $(ls -1 2>/dev/null | sed "s/-[0-9].*$//" | sort -u); do
            versions=$(ls -1d "${name}"-[0-9]* 2>/dev/null | sort -V)
            [ -z "$versions" ] && continue
            count=$(printf "%s\n" "$versions" | wc -l | tr -d " ")
            if [ "$count" -gt 1 ]; then
                latest=$(printf "%s\n" "$versions" | tail -1)
                for v in $versions; do
                    [ "$v" != "$latest" ] && rm -rf "$v"
                done
            fi
        done
    '

    slim_step src_and_headers find "$OTP_BUNDLE" -type d \( -name src -o -name include \) -prune -exec rm -rf {} +

    slim_step beam_chunks erl -noinput -boot start_clean -eval "
      case beam_lib:strip_release(\"$OTP_BUNDLE\") of
        {ok, _} -> erlang:halt(0);
        {error, beam_lib, R} ->
          io:format(standard_error, \"  strip_release error: ~p~n\", [R]),
          erlang:halt(1)
      end."
else
    echo "[SLIM:skipped] MOB_SLIM=0 — keeping full OTP runtime"
fi

echo "  $(find "$OTP_BUNDLE" -type f | wc -l | tr -d ' ') files in bundle after strip"

# Strip non-global symbols from the main Mach-O — slim only.
# MUST happen before codesigning since strip rewrites the file.
if [ "${MOB_SLIM:-1}" = "1" ]; then
    echo "=== Stripping non-global symbols from main binary ==="
    SIZE_BEFORE_STRIP=$(stat -f%z "$APP/$APP_NAME")
    xcrun strip -x "$APP/$APP_NAME"
    SIZE_AFTER_STRIP=$(stat -f%z "$APP/$APP_NAME")
    echo "  $APP_NAME: $((SIZE_BEFORE_STRIP / 1024)) KB → $((SIZE_AFTER_STRIP / 1024)) KB"
fi

echo "=== Embedding App Store provisioning profile ==="
PROFILE_DIR="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
PROFILE="$PROFILE_DIR/${PROFILE_UUID}.mobileprovision"
if [ ! -f "$PROFILE" ]; then
    PROFILE="$HOME/Library/MobileDevice/Provisioning Profiles/${PROFILE_UUID}.mobileprovision"
fi
if [ ! -f "$PROFILE" ]; then
    echo "ERROR: Provisioning profile $PROFILE_UUID not found."
    exit 1
fi
cp "$PROFILE" "$APP/embedded.mobileprovision"

echo "=== Code signing (distribution, no get-task-allow) ==="
ENTITLEMENTS_FILE="$BUILD_DIR/mob_release.entitlements"
cat > "$ENTITLEMENTS_FILE" << ENTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>application-identifier</key>
    <string>${TEAM_ID}.${BUNDLE_ID}</string>
    <key>com.apple.developer.team-identifier</key>
    <string>${TEAM_ID}</string>
    <key>beta-reports-active</key>
    <true/>
</dict>
</plist>
ENTEOF
codesign --force --sign "$SIGN_IDENTITY" \
    --entitlements "$ENTITLEMENTS_FILE" \
    --timestamp \
    --options runtime \
    "$APP"

echo "=== Verifying signature ==="
codesign --verify --deep --strict --verbose=2 "$APP"

echo "=== Packaging IPA ==="
# `ditto -c -k --keepParent` (rather than plain `zip -r`) preserves
# symlinks and bundle structure that App Store Connect's validator
# checks (error code 90071: "CodeResources must be a symbolic link").
# Skip --sequesterRsrc — that's for macOS resource forks, not iOS;
# adding it injects a __MACOSX/ sidecar tree that confuses the
# validator.
# cp -RP preserves symlinks (plain cp -R follows them and turns them
# into regular files, which would defeat the whole exercise).
IPA_STAGE=$(mktemp -d)
mkdir -p "$IPA_STAGE/Payload"
cp -RP "$APP" "$IPA_STAGE/Payload/"
# `dot_clean` removes the macOS AppleDouble (`._<file>`) sidecars
# that get created when `cp` preserves extended attributes across
# filesystems. Apple's validator can flag these.
dot_clean -m "$IPA_STAGE/Payload" 2>/dev/null || true
find "$IPA_STAGE/Payload" -name '._*' -delete 2>/dev/null || true
IPA_PATH="$OUTPUT_DIR/$APP_NAME.ipa"
rm -f "$IPA_PATH"
# --norsrc / --noextattr / --noqtn: don't preserve resource forks,
# extended attributes, or quarantine flags. Without these, ditto
# creates `._<file>` AppleDouble sidecars inside the IPA for any
# source file that happens to have an xattr (the OTP cross-build
# leaves a bunch of these on the cached output). Apple's validator
# generally tolerates them but the IPA is cleaner without.
(cd "$IPA_STAGE" && ditto -c -k --norsrc --noextattr --noqtn --keepParent Payload "$IPA_PATH")
rm -rf "$IPA_STAGE"

echo "=== Done: $IPA_PATH ($(du -h "$IPA_PATH" | cut -f1)) ==="
