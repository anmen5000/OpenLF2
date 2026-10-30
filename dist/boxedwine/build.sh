#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 OpenLF2 contributors
#
# Builds the Windows emulator in which the site plays mods that OpenLF2 cannot read (their program is packed or
# protected, with the game's files inside it): BoxedWine's browser build (GPL-2.0-or-later,
# https://github.com/danoon2/Boxedwine) at a fixed commit, the Wine file system BoxedWine publishes for it (Wine is
# LGPL-2.1-or-later), and the MFC 8.0 library of Microsoft's Visual C++ 2005 runtime, which such mods need and
# Wine does not have. Writes OUTPUT_DIR/{boxedwine.html,boxedwine.js,boxedwine.wasm,boxedwine-shell.js,fsfs.js,
# boxedwine.css,wine.zip,vc80.zip,LICENSES.txt,build.json}; dist/pages/windows.html runs it.
#
#   dist/boxedwine/build.sh OUTPUT_DIR
#
# Needs git, curl, python3, make, cabextract and Emscripten's SDK (fetched here, emsdk $emsdk_version).
set -euo pipefail

out=${1:?usage: dist/boxedwine/build.sh OUTPUT_DIR}
here=$(cd "$(dirname "$0")" && pwd)
work=${BOXEDWINE_WORK:-$(pwd)/build/boxedwine-work}

boxedwine_commit=8790ff20428c22daa64368af9553417e4f499c94
emsdk_version=5.0.7
# BoxedWine's Wine 11 file system for its browser build, the one its own browser tests use.
wine_url=https://boxedwine.org/v2/23/TinyCore15Wine11.0-web.zip
wine_sha256=4d505092956dd78e36712dac8111c252e5d1b859ce2373fbe7c80242bb65ad47
# The Visual C++ 2005 SP1 runtime with its 2011 MFC security update (8.0.50727.6195), as winetricks fetches it.
vc_url=https://download.microsoft.com/download/8/B/4/8B42259F-5D70-43F4-AC2E-4B208FD8D66A/vcredist_x86.EXE
vc_sha256=8648c5fc29c44b9112fe52f9a33f80e7fc42d10f3b5b42b2121542a13e44adfd

download() { # url sha256 file
    if [[ -f "$3" ]] && printf '%s  %s\n' "$2" "$3" | sha256sum --check --quiet 2>/dev/null; then return; fi
    curl --fail --location --retry 4 --retry-delay 10 --connect-timeout 30 --output "$3.part" "$1"
    printf '%s  %s\n' "$2" "$3.part" | sha256sum --check
    mv "$3.part" "$3"
}

mkdir -p "$work" "$out"
out=$(cd "$out" && pwd)

# ---- BoxedWine ----------------------------------------------------------------------------------------------
if [[ ! -d "$work/Boxedwine/.git" ]]; then
    git init --quiet "$work/Boxedwine"
    git -C "$work/Boxedwine" remote add origin https://github.com/danoon2/Boxedwine.git
fi
git -C "$work/Boxedwine" fetch --quiet --depth 1 origin "$boxedwine_commit"
git -C "$work/Boxedwine" checkout --quiet --force FETCH_HEAD
git -C "$work/Boxedwine" clean --quiet -fdx -e project/emscripten/Build
python3 "$here/patch-shell.py" "$work/Boxedwine/project/emscripten/boxedwine-shell.js"

if [[ -z "${BOXEDWINE_USE_PATH_EMCC:-}" ]]; then
    if [[ ! -d "$work/emsdk/.git" ]]; then
        git clone --quiet --depth 1 https://github.com/emscripten-core/emsdk.git "$work/emsdk"
    fi
    "$work/emsdk/emsdk" install "$emsdk_version"
    "$work/emsdk/emsdk" activate "$emsdk_version"
    # shellcheck disable=SC1091
    source "$work/emsdk/emsdk_env.sh"
fi
emcc --version | head -1

(
    cd "$work/Boxedwine/project/emscripten"
    # The single-threaded build with BoxedWine's WebAssembly JIT: no SharedArrayBuffer, so no special headers
    # (GitHub Pages cannot send them).
    make jit -j"$(nproc)"
)
build="$work/Boxedwine/project/emscripten/Build/Jit"
for file in boxedwine.html boxedwine.js boxedwine.wasm; do
    [[ -s "$build/$file" ]] || { echo "BoxedWine's build has no $file" >&2; exit 1; }
    cp "$build/$file" "$out/"
done
for file in boxedwine-shell.js fsfs.js boxedwine.css; do
    cp "$work/Boxedwine/project/emscripten/$file" "$out/"
done

# ---- Wine -----------------------------------------------------------------------------------------------------
download "$wine_url" "$wine_sha256" "$work/wine.zip"
cp "$work/wine.zip" "$out/wine.zip"

# ---- MFC 8.0 ----------------------------------------------------------------------------------------------------
# An overlay on Wine's file system: the four MFC 8.0 libraries in system32, where Wine's loader finds them (the
# mods ask for the Microsoft.VC80.MFC assembly, which Wine does not have, and then load mfc80.dll by name).
download "$vc_url" "$vc_sha256" "$work/vcredist_x86.exe"
rm -rf "$work/vc80"
mkdir -p "$work/vc80"
cabextract --quiet --directory="$work/vc80" -F vcredist.msi "$work/vcredist_x86.exe"
cabextract --quiet --directory="$work/vc80" "$work/vc80/vcredist.msi"
python3 - "$work/vc80" "$out/vc80.zip" <<'PY'
import os
import sys
import zipfile

source, target = sys.argv[1:3]
system32 = "home/username/.wine/drive_c/windows/system32/"
names = ["mfc80.dll", "mfc80u.dll", "mfcm80.dll", "mfcm80u.dll"]
with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED) as overlay:
    folder = ""
    for part in system32.split("/")[:-1]:
        folder += part + "/"
        info = zipfile.ZipInfo(folder)
        info.external_attr = (0o40755 << 16) | 0x10
        info.create_system = 3
        overlay.writestr(info, b"")
    for name in names:
        # cabextract names them like mfc80.dll.8.0.50727.6195.9BAE13A2_E7AF_D6C3_FF1F_C8B3B9A1E18E
        found = [entry for entry in os.listdir(source)
                 if entry.lower().startswith(name + ".8.0.50727.6195.9bae13a2_")
                 and entry.lower().endswith("_c8b3b9a1e18e")]
        if len(found) != 1:
            sys.exit(f"vcredist_x86.exe: expected one {name} (x86) inside, found {found}")
        info = zipfile.ZipInfo(system32 + name)
        info.external_attr = 0o100644 << 16
        info.create_system = 3
        info.compress_type = zipfile.ZIP_DEFLATED
        with open(os.path.join(source, found[0]), "rb") as library:
            overlay.writestr(info, library.read())
print(f"{target}: {', '.join(names)}")
PY

# ---- Notices --------------------------------------------------------------------------------------------------
{
    echo "The Windows emulator of this site (windows/): what it is made of and under which terms."
    echo
    echo "BoxedWine, https://github.com/danoon2/Boxedwine, commit $boxedwine_commit,"
    echo "built with Emscripten $emsdk_version (make jit in project/emscripten). GNU General Public License"
    echo "version 2 or later (below). boxedwine-shell.js is changed by dist/boxedwine/patch-shell.py in the"
    echo "OpenLF2 repository: the source of both is at those addresses."
    echo
    echo "wine.zip: BoxedWine's Wine 11.0 file system, $wine_url"
    echo "(SHA-256 $wine_sha256): Tiny Core Linux and Wine (GNU LGPL 2.1 or later, https://www.winehq.org,"
    echo "source at https://gitlab.winehq.org/wine/wine) and the other free software it holds, each under its own"
    echo "terms."
    echo
    echo "vc80.zip: the MFC 8.0 libraries (8.0.50727.6195) of Microsoft's Visual C++ 2005 SP1 Redistributable"
    echo "Package, $vc_url, distributed under Microsoft's terms for that package."
    echo
    echo "------------------------------------------------------------------------------------------------"
    cat "$work/Boxedwine/license.txt"
} > "$out/LICENSES.txt"
python3 - "$out/build.json" "$boxedwine_commit" "$emsdk_version" "$wine_sha256" "$out/wine.zip" <<'PY'
import json
import os
import sys

path, commit, emsdk, wine, wine_zip = sys.argv[1:6]
with open(path, "w") as target:
    json.dump({"boxedwine": commit, "emscripten": emsdk, "wine_sha256": wine,
               "wine_size": os.path.getsize(wine_zip)}, target, indent=2)
PY
ls -la "$out"
