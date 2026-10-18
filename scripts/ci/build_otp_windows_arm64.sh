#!/usr/bin/env bash
# Build OTP for native Windows ARM64 from inside WSL and copy the release tree
# to /mnt/c/otp-arm64. Erlang/OTP has no published ARM64 Windows installer.
# Upstream builds this with a WSL shell plus MSVC; wxWidgets is omitted.
set -euo pipefail

otp_version="${1:?otp version}"
prefix="${2:-/mnt/c/otp-arm64}"
vcpkg="${3:-/mnt/c/vcpkg}"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends build-essential autoconf m4 unzip curl ca-certificates

if [[ ! -x "${vcpkg}/vcpkg.exe" ]]; then
  echo "vcpkg is not installed at ${vcpkg}" >&2
  exit 1
fi
"${vcpkg}/vcpkg.exe" install openssl:arm64-windows

src_root="${RUNNER_TEMP:-/tmp}/otp-src-${otp_version}"
rm -rf "$src_root"
mkdir -p "$src_root"
curl -fsSL "https://github.com/erlang/otp/releases/download/OTP-${otp_version}/otp_src_${otp_version}.tar.gz" \
  | tar -xz -C "$src_root" --strip-components=1
cd "$src_root"

export ERL_TOP="$src_root"
export MAKEFLAGS="-j$(($(nproc) + 1))"
# otp_build finds ARM64 cl.exe through its WSL wrapper when this runs in WSL.
eval "$(./otp_build env_win32 arm64)"
./otp_build configure --without-wx --with-ssl="${vcpkg}/installed/arm64-windows"
./otp_build boot -a
./otp_build release -a

if [[ ! -d release/win32 ]]; then
  echo "OTP release/win32 was not produced" >&2
  exit 1
fi

rm -rf "$prefix"
mkdir -p "$prefix"
cp -a release/win32/. "$prefix/"

if ! find "$prefix" -name erl.exe -print -quit | grep -q .; then
  echo "OTP release tree has no erl.exe" >&2
  exit 1
fi
