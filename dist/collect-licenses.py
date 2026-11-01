#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 OpenLF2 contributors

"""Stage checked project and dependency license texts for a distribution."""

import argparse
import hashlib
import http.client
import io
import os
from pathlib import Path
import sys
import tarfile
import tempfile
import time
from urllib.error import HTTPError
from urllib.request import urlopen


ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / "dist/notice-sources.txt"
# A dropped or stalled connection is tried again after these pauses (seconds): GitHub's Windows arm64 runners
# lost the one download of ffmpeg.org's archive now and then, failing the whole build.
RETRY_PAUSES = (15, 30, 60, 120)


def download(url):
    for pause in RETRY_PAUSES + (None,):
        try:
            with urlopen(url, timeout=90) as response:
                return response.read()
        except (OSError, http.client.HTTPException) as error:
            if pause is None or (isinstance(error, HTTPError) and error.code < 500):
                raise
            print(f"{url}: {error}; trying again in {pause} s", file=sys.stderr, flush=True)
            time.sleep(pause)


def manifest():
    entries = {}
    for line in SOURCES.read_text(encoding="utf-8").splitlines():
        if not line or line.startswith("#"):
            continue
        key, kind, url, digest, *members = line.split()
        entries[key] = (kind, url, digest, members)
    return entries


def checked_archive(key, entry, cache):
    kind, url, digest, members = entry
    suffix = next((ending for ending in (".tar.xz", ".tar.gz", ".tar.bz2")
                   if url.endswith(ending)), ".txt")
    cached = cache / (digest + suffix)
    if not cached.exists() or hashlib.sha256(cached.read_bytes()).hexdigest() != digest:
        data = download(url)
        if hashlib.sha256(data).hexdigest() != digest:
            raise ValueError(f"{key}: upstream SHA-256 differs from notice-sources.txt")
        with tempfile.NamedTemporaryFile(dir=cache, delete=False) as temporary:
            temporary.write(data)
            temporary_name = temporary.name
        os.replace(temporary_name, cached)
    data = cached.read_bytes()
    if hashlib.sha256(data).hexdigest() != digest:
        raise ValueError(f"{key}: cached SHA-256 differs from notice-sources.txt")
    if kind == "file":
        return data
    if kind != "archive" or len(members) != 1:
        raise ValueError(f"{key}: unsupported notice source")
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:*") as archive:
        matches = [member for member in archive.getmembers()
                   if member.isfile() and Path(member.name).as_posix().endswith("/" + members[0])]
        if len(matches) != 1:
            raise ValueError(f"{key}: expected one {members[0]} in archive, found {len(matches)}")
        return archive.extractfile(matches[0]).read()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--key", action="append", default=[], help="pinned notice key")
    parser.add_argument("--local", action="append", default=[], metavar="KEY=FILE",
                        help="notice from the dependency source or installed toolchain")
    args = parser.parse_args()
    sources = manifest()
    local = dict(spec.split("=", 1) for spec in args.local)
    keys = set(args.key) | set(local)
    if not keys or set(args.key) & set(local):
        parser.error("specify keys, with each key either pinned or local")
    args.output.mkdir(parents=True, exist_ok=True)
    for old_file in args.output.glob("LICENSE-*.txt"):
        old_file.unlink()
    cache = ROOT / "build/license-cache"
    cache.mkdir(parents=True, exist_ok=True)
    (args.output / "LICENSE-OpenLF2.txt").write_bytes((ROOT / "LICENSE").read_bytes())
    (args.output / "THIRD-PARTY-NOTICES.md").write_bytes(
        (ROOT / "THIRD-PARTY-NOTICES.md").read_bytes())
    lines = ["OpenLF2 license bundle", "", "Verbatim dependency notices:"]
    for key in sorted(keys):
        if key in local:
            source = Path(local[key])
            data = source.read_bytes()
            origin = str(source)
        else:
            if key not in sources:
                raise ValueError(f"unknown notice key: {key}")
            data = checked_archive(key, sources[key], cache)
            origin = sources[key][1]
        if not data:
            raise ValueError(f"{key}: empty license file")
        name = f"LICENSE-{key}.txt"
        (args.output / name).write_bytes(data)
        lines.append(f"{name}: {origin}; SHA-256 {hashlib.sha256(data).hexdigest()}")
    (args.output / "CONTENTS.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"Staged {len(keys)} dependency notices in {args.output}")


if __name__ == "__main__":
    main()
