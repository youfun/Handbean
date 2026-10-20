#!/usr/bin/env bash
# Sourced by build-release.sh inside the pinned manylinux2014 container.

set -euo pipefail

cache=${HANDBEAN_GLIBC217_CACHE:-/cache}
downloads="$cache/downloads"
toolchain="$cache/toolchain"
sources=/build/toolchain-sources
jobs=${HANDBEAN_BUILD_JOBS:-$(nproc)}

mkdir -p "$downloads" "$toolchain" "$sources"

install_packages() {
  local packages=(
    autoconf automake binutils bzip2 bzip2-devel curl diffutils file findutils
    git libtool make ncurses-devel openssl-devel patch perl-core procps-ng tar
    unzip which xz xz-devel zlib-devel
  )

  if command -v dnf >/dev/null 2>&1; then
    dnf install -y "${packages[@]}"
    dnf clean all
  else
    yum install -y "${packages[@]}"
    yum clean all
  fi
}

verify_sha256() {
  local expected=$1
  local path=$2
  printf '%s  %s\n' "$expected" "$path" | sha256sum -c -
}

download_sha256() {
  local url=$1
  local path=$2
  local expected=$3

  if [[ -f "$path" ]] && ! verify_sha256 "$expected" "$path" >/dev/null 2>&1; then
    rm -f "$path"
  fi

  if [[ ! -f "$path" ]]; then
    rm -f "$path.part"
    curl -fL --retry 8 --retry-delay 2 --connect-timeout 20 -o "$path.part" "$url"
    mv "$path.part" "$path"
  fi

  verify_sha256 "$expected" "$path"
}

install_openssl() {
  local version=3.0.18
  local prefix="$toolchain/openssl-$version"
  local archive="$downloads/openssl-$version.tar.gz"

  download_sha256 \
    "https://github.com/openssl/openssl/releases/download/openssl-$version/openssl-$version.tar.gz" \
    "$archive" \
    d80c34f5cf902dccf1f1b5df5ebb86d0392e37049e5d73df1b3abae72e4ffe8b

  if [[ ! -f "$prefix/.handbean-complete" ]]; then
    rm -rf "$prefix" "$sources/openssl-$version"
    tar -C "$sources" -xzf "$archive"
    (
      cd "$sources/openssl-$version"
      ./Configure linux-x86_64 no-shared no-tests \
        --prefix="$prefix" \
        --openssldir="$prefix/ssl"
      make -j"$jobs"
      make install_sw
    )
    touch "$prefix/.handbean-complete"
  fi

  "$prefix/bin/openssl" version
}

install_otp() {
  local version=29.0
  local prefix="$toolchain/otp-$version"
  local archive="$downloads/otp_src_$version.tar.gz"

  download_sha256 \
    "https://github.com/erlang/otp/releases/download/OTP-$version/otp_src_$version.tar.gz" \
    "$archive" \
    149bb67708427ae50fce861d54ff676134e003438012efb41187d28122938564

  if [[ ! -f "$prefix/.handbean-complete" ]]; then
    rm -rf "$prefix" "$sources/otp_src_$version"
    tar -C "$sources" -xzf "$archive"
    (
      cd "$sources/otp_src_$version"
      ./configure \
        --prefix="$prefix" \
        --with-ssl="$toolchain/openssl-3.0.18" \
        --disable-dynamic-ssl-lib \
        --without-javac \
        --without-wx
      make -j"$jobs"
      make install
    )
    touch "$prefix/.handbean-complete"
  fi

  "$prefix/bin/erl" -noshell -eval '
    io:format("OTP ~s ERTS ~s~n", [erlang:system_info(otp_release), erlang:system_info(version)]),
    {ok, _} = application:ensure_all_started(ssl),
    io:format("SSL ~p~nCrypto ~p~n", [ok, crypto:info_lib()]),
    halt().
  '
}

install_elixir() {
  local version=1.20.2
  local prefix="$toolchain/elixir-$version"
  local archive="$downloads/elixir-$version.tar.gz"

  download_sha256 \
    "https://github.com/elixir-lang/elixir/archive/refs/tags/v$version.tar.gz" \
    "$archive" \
    1a25bbf9a9016651fc332eecc02bb9681d0b8e722c2e256e73ddb88fbce6e6b0

  if [[ ! -f "$prefix/.handbean-complete" ]]; then
    rm -rf "$prefix" "$sources/elixir-$version"
    tar -C "$sources" -xzf "$archive"
    (
      cd "$sources/elixir-$version"
      PATH="$toolchain/otp-29.0/bin:$PATH" make -j"$jobs"
      PATH="$toolchain/otp-29.0/bin:$PATH" make install PREFIX="$prefix"
    )
    touch "$prefix/.handbean-complete"
  fi
}

install_patchelf() {
  local version=0.18.0
  local prefix="$toolchain/patchelf-$version"
  local archive="$downloads/patchelf-$version.tar.gz"

  download_sha256 \
    "https://github.com/NixOS/patchelf/releases/download/$version/patchelf-$version.tar.gz" \
    "$archive" \
    64de10e4c6b8b8379db7e87f58030f336ea747c0515f381132e810dbf84a86e7

  if [[ ! -f "$prefix/.handbean-complete" ]]; then
    rm -rf "$prefix" "$sources/patchelf-$version"
    tar -C "$sources" -xzf "$archive"
    (
      cd "$sources/patchelf-$version"
      ./configure --prefix="$prefix"
      make -j"$jobs"
      make install
    )
    touch "$prefix/.handbean-complete"
  fi
}

install_rust() {
  local version=1.98.0
  local prefix="$toolchain/rust-$version"
  local archive="$downloads/rust-$version-x86_64-unknown-linux-gnu.tar.xz"

  download_sha256 \
    "https://static.rust-lang.org/dist/rust-$version-x86_64-unknown-linux-gnu.tar.xz" \
    "$archive" \
    ed8ee2df70909c88cbaf87a6cfa3920dac00b537de12a6abe6906641e0f5952f

  if [[ ! -f "$prefix/.handbean-complete" ]]; then
    rm -rf "$prefix" "$sources/rust-$version-x86_64-unknown-linux-gnu"
    tar -C "$sources" -xf "$archive"
    "$sources/rust-$version-x86_64-unknown-linux-gnu/install.sh" \
      --prefix="$prefix" \
      --disable-ldconfig
    touch "$prefix/.handbean-complete"
  fi
}

install_cmake() {
  local version=3.31.10
  local prefix="$toolchain/cmake-$version"
  local archive="$downloads/cmake-$version.tar.gz"

  download_sha256 \
    "https://github.com/Kitware/CMake/releases/download/v$version/cmake-$version.tar.gz" \
    "$archive" \
    cf06fadfd6d41fa8e1ade5099e54976d1d844fd1487ab99942341f91b13d3e29

  if [[ ! -f "$prefix/.handbean-complete" ]]; then
    rm -rf "$prefix" "$sources/cmake-$version"
    tar -C "$sources" -xzf "$archive"
    (
      cd "$sources/cmake-$version"
      ./bootstrap --prefix="$prefix" --parallel="$jobs"
      make -j"$jobs"
      make install
    )
    touch "$prefix/.handbean-complete"
  fi
}

install_zig() {
  local version=0.16.0
  local prefix="$toolchain/zig-$version"
  local archive="$downloads/zig-x86_64-linux-$version.tar.xz"

  download_sha256 \
    "https://ziglang.org/download/$version/zig-x86_64-linux-$version.tar.xz" \
    "$archive" \
    70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00

  if [[ ! -f "$prefix/.handbean-complete" ]]; then
    rm -rf "$prefix" "$sources/zig-x86_64-linux-$version"
    tar -C "$sources" -xf "$archive"
    mv "$sources/zig-x86_64-linux-$version" "$prefix"
    touch "$prefix/.handbean-complete"
  fi
}

install_packages

if [[ $(uname -m) != x86_64 || $(getconf GNU_LIBC_VERSION) != "glibc 2.17" ]]; then
  echo "the release container must be x86_64 with glibc 2.17" >&2
  exit 1
fi

install_openssl
install_otp
install_elixir
install_patchelf
install_rust
install_cmake
install_zig

export HANDBEAN_ZIG="$toolchain/zig-0.16.0/zig"
export PATH="$toolchain/elixir-1.20.2/bin:$toolchain/otp-29.0/bin:$toolchain/patchelf-0.18.0/bin:$toolchain/rust-1.98.0/bin:$toolchain/cmake-3.31.10/bin:$PATH"

elixir --version
patchelf --version
rustc --version
cargo --version
cmake --version | head -1
"$HANDBEAN_ZIG" version
