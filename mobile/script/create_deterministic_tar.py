#!/usr/bin/env python3
"""Create a deterministic gzip-compressed tar archive for the Termux rootfs."""

from __future__ import annotations

import gzip
import pathlib
import sys
import tarfile


def normalized(info: tarfile.TarInfo) -> tarfile.TarInfo:
    info.uid = 0
    info.gid = 0
    info.uname = ""
    info.gname = ""
    info.mtime = 0
    return info


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: create_deterministic_tar.py SOURCE_USR OUTPUT_TAR_GZ")

    source = pathlib.Path(sys.argv[1]).resolve(strict=True)
    destination = pathlib.Path(sys.argv[2]).resolve()
    if not source.is_dir() or source.name != "usr":
        raise SystemExit("source must be an existing usr directory")

    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name(destination.name + ".new")
    temporary.unlink(missing_ok=True)

    try:
        with temporary.open("wb") as output:
            with gzip.GzipFile(filename="", mode="wb", compresslevel=9, mtime=0, fileobj=output) as compressed:
                with tarfile.open(fileobj=compressed, mode="w", format=tarfile.PAX_FORMAT, dereference=False) as archive:
                    archive.add(source, arcname="usr", recursive=True, filter=normalized)
        temporary.replace(destination)
    finally:
        temporary.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
