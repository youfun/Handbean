#!/bin/sh
# Point an iOS device or simulator build at prebuilt iSH static archives.
#
# The archives stay out of the app bundle. build_device.zig / build.zig pass
# their paths to the linker, so they become part of the one Mach-O.
#
#   HANDREAM_ISH_LIBS=/path/libish_emu.a,/path/libish.a,/path/libfakefs.a \
#     sh script/link_ios_ish.sh
#
# Build those archives from https://github.com/youfun/ish-arm64. This script
# does not clone or compile that tree.
set -eu

libs="${HANDREAM_ISH_LIBS:-}"
include="${HANDREAM_ISH_INCLUDE:-}"
if [ -z "$libs" ]; then
  echo "HANDREAM_ISH_LIBS is empty; iOS links without the iSH guest." >&2
  exit 0
fi
if [ -z "$include" ] || [ ! -f "$include/kernel/init.h" ]; then
  echo "HANDREAM_ISH_INCLUDE must be the ish-arm64 source root." >&2
  exit 1
fi

old_ifs=$IFS
IFS=,
for lib in $libs; do
  if [ ! -f "$lib" ]; then
    echo "missing iSH archive: $lib" >&2
    exit 1
  fi
done
IFS=$old_ifs

echo "-Dish_libs=$libs -Dish_include=$include"
