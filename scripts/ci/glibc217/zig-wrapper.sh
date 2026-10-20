#!/usr/bin/env bash
set -euo pipefail

zig=${HANDBEAN_ZIG:?HANDBEAN_ZIG must point to the pinned Zig binary}

if [[ ${1:-} == build ]]; then
  has_target=false
  zigler_sema=false

  for argument in "$@"; do
    if [[ $argument == -Dtarget=* ]]; then
      has_target=true
    elif [[ $argument == -Dzigler-mode=sema ]]; then
      zigler_sema=true
    fi
  done

  if [[ $zigler_sema == true ]]; then
    build_file=$PWD/build.zig
    native_host='const host_target = b.graph.host;'
    resolved_host='const host_target = resolved_target;'
    native_host_count=$(grep -Fc "$native_host" "$build_file" || true)
    resolved_host_count=$(grep -Fc "$resolved_host" "$build_file" || true)

    if [[ $native_host_count == 1 && $resolved_host_count == 0 ]]; then
      patched_build_file=$build_file.glibc217
      sed 's/const host_target = b\.graph\.host;/const host_target = resolved_target;/' \
        "$build_file" > "$patched_build_file"
      mv "$patched_build_file" "$build_file"
    elif [[ $native_host_count != 0 || $resolved_host_count != 1 ]]; then
      echo "cannot constrain the Zigler sema host ABI in $build_file" >&2
      exit 1
    fi
  fi

  if [[ $has_target == false ]]; then
    set -- "$@" -Dtarget=x86_64-linux-gnu.2.17
  fi
fi

exec "$zig" "$@"
