#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (c) 2026 OpenLF2 contributors
"""Adapts BoxedWine's browser shell (project/emscripten/boxedwine-shell.js, GPL-2.0-or-later) to the site's
Windows emulator page (dist/pages/windows.html), which shows it in a frame:

  * the page downloads the files itself (with its progress bar, keeping them in the browser between visits) and
    hands them over in window.parent.OpenLF2BoxedwineFiles {name: Uint8Array}; the shell takes a file from there
    before fetching it;
  * every line the emulator prints also goes to window.parent.OpenLF2BoxedwineLog(text), so that the page can
    show what Wine says when a game does not start.

    patch-shell.py BOXEDWINE_SHELL_JS
"""
import sys

PATCHES = [
    (
        "        function loadFile(pathPrefix, filename, callback) {\n",
        "        function loadFile(pathPrefix, filename, callback) {\n"
        "            // OpenLF2: the page around this frame may have downloaded the file already.\n"
        "            var provided = null;\n"
        "            try { provided = window.parent !== window ? window.parent.OpenLF2BoxedwineFiles : null; } catch (error) {}\n"
        "            if (provided && provided[filename]) {\n"
        "                var bytes = provided[filename];\n"
        "                delete provided[filename];\n"
        "                setTimeout(function() { callback(bytes); }, 0);\n"
        "                return;\n"
        "            }\n",
    ),
    (
        "            console.log(text);\n"
        "            if (element) {\n"
        "              element.value += text + \"\\n\";\n",
        "            console.log(text);\n"
        "            openlf2Log(text);\n"
        "            if (element) {\n"
        "              element.value += text + \"\\n\";\n",
    ),
    (
        "\t\t\tconsole.error(text);\n",
        "\t\t\tconsole.error(text);\n"
        "            openlf2Log(text);\n",
    ),
    (
        "      var Module = {\n",
        "      // OpenLF2: the emulator's output, also for the page around this frame.\n"
        "      function openlf2Log(text) {\n"
        "        try { if (window.parent !== window && window.parent.OpenLF2BoxedwineLog) window.parent.OpenLF2BoxedwineLog(text); } catch (error) {}\n"
        "      }\n"
        "      var Module = {\n",
    ),
]


def main(argv):
    if len(argv) != 2:
        sys.exit(__doc__)
    path = argv[1]
    with open(path, encoding="utf-8") as source:
        text = source.read()
    for old, new in PATCHES:
        if text.count(old) != 1:
            sys.exit(f"{path}: expected one occurrence of:\n{old}")
        text = text.replace(old, new)
    with open(path, "w", encoding="utf-8") as target:
        target.write(text)
    print(f"patched {path}")


if __name__ == "__main__":
    main(sys.argv)
