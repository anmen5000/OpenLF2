#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 OpenLF2 contributors
"""Makes the assembled site an app that opens without the network (package 95).

    make-pwa.py SITE

Run on the finished site (the "pages" job of .github/workflows/web.yml). Copies dist/pages/manifest.webmanifest and
dist/pages/pwa.js into SITE and writes SITE/sw.js: dist/pages/sw.js with the site's files and their SHA-256 in it.
CORE files are stored when the app installs or updates (a missing one is an error: the app would open without it);
the files under LAZY_DIRS when first used; every other file (the XOI kits, the Windows emulator) is not the service
worker's and comes from the network. The version is a digest of that list, so a site that did not change keeps
the same sw.js and nobody downloads anything.
"""
import hashlib
import json
import os
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CORE = [
    "index.html", "xoi.html", "insane.html",
    "openlf2.js", "openlf2.wasm", "openlf2.data",
    "installer-store.js", "online.js", "hero-fighter.js", "hf-direct.js", "hf-remote.js", "hf-ver.txt",
    "insane-version.json", "pwa.js", "manifest.webmanifest",
    "icon.svg", "favicon.ico", "favicon-32.png", "apple-touch-icon.png",
    "icon-192.png", "icon-512.png", "icon-maskable-512.png",
]
LAZY_DIRS = ["ruffle", "ruffle-stock", "licenses"]
MARKER = 'const FILES = {"version": "dev", "core": {}, "lazy": {}}; // @files (dist/pages/make-pwa.py)'


def digest(path):
    sha = hashlib.sha256()
    with open(path, "rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            sha.update(block)
    return sha.hexdigest()


def main(argv):
    if len(argv) != 2:
        print(__doc__)
        return 2
    site = argv[1]
    for name in ("manifest.webmanifest", "pwa.js"):
        shutil.copyfile(os.path.join(HERE, name), os.path.join(site, name))
    core, lazy = {}, {}
    missing = [name for name in CORE if not os.path.isfile(os.path.join(site, name))]
    if missing:
        print("make-pwa.py: the site has no " + ", ".join(missing), file=sys.stderr)
        return 1
    for name in CORE:
        path = os.path.join(site, name)
        core[name] = [digest(path), os.path.getsize(path)]
    for folder in LAZY_DIRS:
        top = os.path.join(site, folder)
        for root, dirs, files in os.walk(top):
            dirs.sort()
            for name in sorted(files):
                path = os.path.join(root, name)
                relative = os.path.relpath(path, site).replace(os.sep, "/")
                lazy[relative] = [digest(path), os.path.getsize(path)]
    listing = json.dumps({"core": core, "lazy": lazy}, sort_keys=True, separators=(",", ":"))
    files = {"version": hashlib.sha256(listing.encode()).hexdigest()[:16], "core": core, "lazy": lazy}
    template = open(os.path.join(HERE, "sw.js"), encoding="utf-8").read()
    if template.count(MARKER) != 1:
        print("make-pwa.py: dist/pages/sw.js has no FILES line to fill in", file=sys.stderr)
        return 1
    worker = template.replace(MARKER, "const FILES = " + json.dumps(files, sort_keys=True, separators=(",", ":"))
                              + "; // written by dist/pages/make-pwa.py")
    with open(os.path.join(site, "sw.js"), "w", encoding="utf-8", newline="\n") as out:
        out.write(worker)
    mb = lambda entries: sum(size for _, size in entries.values()) / 1e6
    print("sw.js: version %s, %d files stored on install (%.1f MB), %d when first used (%.1f MB)"
          % (files["version"], len(core), mb(core), len(lazy), mb(lazy)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
