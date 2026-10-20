#!/usr/bin/env bash
# Build the experimental Linux amd64 MyGo GUI packages around the bundled
# Handbean Web UI release. Stable package identity; experimental artifact names.
set -euo pipefail
umask 022

root="$(cd "$(dirname "$0")/.." && pwd)"
repo_root="$(cd "$root/../.." && pwd)"
cd "$root"

[[ "$(uname -s)" == Linux ]] || {
  echo "Linux GUI packages must be built on Linux so their contents can be verified." >&2
  exit 1
}
case "$(uname -m)" in
  x86_64|amd64) ;;
  *)
    echo "This experimental package currently supports Linux amd64 only." >&2
    exit 1
    ;;
esac

web_root="$root/resources/handbean-web"
launcher="$web_root/bin/handbean"
[[ -x "$launcher" ]] || {
  echo "$web_root does not contain executable bin/handbean." >&2
  echo "Run scripts/fetch_web_release.sh first." >&2
  exit 1
}

version="$(bash "$repo_root/scripts/version.sh" version)"
bash "$repo_root/scripts/version.sh" verify-web "$web_root"
release_version="$("$launcher" version 2>&1)" || {
  echo "bundled Web release cannot run on this Linux host" >&2
  printf '%s\n' "$release_version" >&2
  exit 1
}
[[ "$release_version" == *"$version"* ]] || {
  echo "bundled Web release reported an unexpected version: $release_version" >&2
  exit 1
}

config="$root/mygo.json"
original_config="$(mktemp "${TMPDIR:-/tmp}/handbean-mygo-config.XXXXXX")"
verify_root=""
cp -- "$config" "$original_config"
cleanup() {
  cp -- "$original_config" "$config"
  rm -f "$original_config"
  if [[ -n "$verify_root" ]]; then
    rm -rf "$verify_root"
  fi
}
trap cleanup EXIT

sed -E "s/(\"version\"[[:space:]]*:[[:space:]]*\")[^\"]*(\")/\1${version}\2/" \
  "$original_config" > "$config"
[[ "$(grep -c "\"version\"[[:space:]]*:[[:space:]]*\"${version}\"" "$config")" == 1 ]] || {
  echo "could not inject version $version into mygo.json" >&2
  exit 1
}

export GOFLAGS="${GOFLAGS:+$GOFLAGS }-buildvcs=false"
go tool mygo build -platform linux/amd64

dist="$root/build/linux-amd64"
[[ -x "$dist/handbean" ]] || {
  echo "mygo build produced no $dist/handbean" >&2
  exit 1
}

mapfile -t generated_tars < <(find "$dist" -maxdepth 1 -type f -name 'handbean-*-linux-amd64.tar.gz' -print)
mapfile -t generated_debs < <(find "$dist" -maxdepth 1 -type f -name 'handbean_*_amd64.deb' -print)
[[ ${#generated_tars[@]} -eq 1 ]] || {
  echo "expected one MyGo Linux tar archive, found ${#generated_tars[@]}" >&2
  exit 1
}
[[ ${#generated_debs[@]} -eq 1 ]] || {
  echo "expected one MyGo Debian package, found ${#generated_debs[@]}" >&2
  exit 1
}

archive="$root/Handbean-linux-amd64-experimental.tar.gz"
deb="$root/Handbean-linux-amd64-experimental.deb"
rm -f "$archive" "$archive.sha256" "$deb" "$deb.sha256"
cp -- "${generated_tars[0]}" "$archive"
cp -- "${generated_debs[0]}" "$deb"

archive_entries="$(tar -tzf "$archive")"
printf '%s\n' "$archive_entries" | grep -E '(^|/)handbean-web/bin/handbean$' >/dev/null || {
  echo "$archive does not contain the bundled Web UI launcher" >&2
  exit 1
}
for tool in dpkg-deb ldd od; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "$tool is required to verify the Debian package" >&2
    exit 1
  }
done
[[ "$(dpkg-deb -f "$deb" Package)" == handbean ]] || {
  echo "$deb has the wrong Debian package name" >&2
  exit 1
}
[[ "$(dpkg-deb -f "$deb" Version)" == "$version" ]] || {
  echo "$deb has the wrong version" >&2
  exit 1
}
[[ "$(dpkg-deb -f "$deb" Architecture)" == amd64 ]] || {
  echo "$deb has the wrong architecture" >&2
  exit 1
}
depends="$(dpkg-deb -f "$deb" Depends)"
[[ "$depends" == *libgtk-3-0* ]] || {
  echo "$deb does not declare GTK 3" >&2
  exit 1
}
[[ "$depends" == *libwebkit2gtk-4.1-0* ]] || {
  echo "$deb does not declare WebKitGTK 4.1" >&2
  exit 1
}
deb_entries="$(dpkg-deb -c "$deb")"
printf '%s\n' "$deb_entries" | grep -E '/opt/handbean/handbean-web/bin/handbean$' >/dev/null || {
  echo "$deb does not contain the bundled Web UI launcher" >&2
  exit 1
}

verify_root="$(mktemp -d "${TMPDIR:-/tmp}/handbean-deb-verify.XXXXXX")"
dpkg-deb -x "$deb" "$verify_root"
installed="$verify_root/opt/handbean"
[[ -x "$installed/handbean" && -x "$installed/handbean-web/bin/handbean" ]] || {
  echo "$deb does not install executable GUI and Web launchers" >&2
  exit 1
}
unreadable="$(find "$installed" -type f ! -perm -004 -print -quit)"
untraversable="$(find "$installed" -type d ! -perm -001 -print -quit)"
[[ -z "$unreadable" && -z "$untraversable" ]] || {
  echo "$deb contains resources an unprivileged user cannot read or traverse" >&2
  printf '%s\n%s\n' "$unreadable" "$untraversable" >&2
  exit 1
}
is_linux_amd64_elf() {
  local header
  header="$(od -An -tx1 -N20 "$1" | tr -d ' \n')"
  [[ "${header:0:12}" == 7f454c460201 && "${header:36:4}" == 3e00 ]]
}
is_linux_amd64_elf "$installed/handbean" || {
  echo "$deb GUI executable is not Linux amd64" >&2
  exit 1
}
beam="$(find "$installed/handbean-web" -type f -name beam.smp -print -quit)"
[[ -n "$beam" ]] || {
  echo "$deb does not contain the ERTS beam.smp executable" >&2
  exit 1
}
is_linux_amd64_elf "$beam" || {
  echo "$deb ERTS executable is not Linux amd64" >&2
  exit 1
}
while IFS= read -r -d '' native; do
  is_linux_amd64_elf "$native" || {
    echo "$native is not a Linux amd64 ELF file" >&2
    exit 1
  }
  linked="$(ldd "$native" 2>&1 || true)"
  if [[ "$linked" == *"not found"* ]]; then
    echo "$native has unresolved dynamic libraries:" >&2
    printf '%s\n' "$linked" >&2
    exit 1
  fi
done < <(find "$installed/handbean-web" -type f \( -name beam.smp -o -name '*.so' \) -print0)

(
  cd "$(dirname "$archive")"
  sha256sum "$(basename "$archive")"
) > "$archive.sha256"
(
  cd "$(dirname "$deb")"
  sha256sum "$(basename "$deb")"
) > "$deb.sha256"
echo "Built $archive"
echo "Built $deb"
