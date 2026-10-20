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

  if [[ $has_target == false && $zigler_sema == false ]]; then
    set -- "$@" -Dtarget=x86_64-linux-gnu.2.17
  fi
fi

exec "$zig" "$@"
