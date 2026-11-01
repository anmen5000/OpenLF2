#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 OpenLF2 contributors
#
# make-xoi-kit.sh OUT.zip: the XOI kit for Windows (the guide is dist/pages/xoi.html), one folder LF2-XOI-kit with
# choi.bat (play a mod with INSANE! and XOI), xoi-hoc.bat (train XOI for a mod), dau-nhieu.bat (measure),
# spsa.bat (tune INSANE!'s numbers by play) and kiem-tra.bat (find out why the game does not open on a PC), beside
# this checkout's game scripts and AI bench, which they lay over the installed game's scripts.
set -euo pipefail
repo_root=$(cd "$(dirname "$0")/.." && pwd)
out=$(realpath -m "$1")
mkdir -p "$(dirname "$out")"
commit=$(git -C "$repo_root" rev-parse --short HEAD 2>/dev/null || echo unknown)
stamp=$(git -C "$repo_root" log -1 --format=%ct 2>/dev/null || date +%s)
python3 - "$repo_root" "$out" "$commit" "$stamp" <<'PY'
import re
import sys
import time
import zipfile
from pathlib import Path

root, out, commit, stamp = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3], int(sys.argv[4])
top = "LF2-XOI-kit"
when = time.gmtime(stamp)[:6]
files = []


def crlf(data):
    return data.replace(b"\r\n", b"\n").replace(b"\n", b"\r\n")


windows = root / "tools/ai-bench/windows"
for name in ("choi.bat", "xoi-hoc.bat", "dau-nhieu.bat", "spsa.bat", "kiem-tra.bat"):
    data = (windows / name).read_bytes()
    # cmd reads labels wrongly in a batch file without CRLF line ends (.gitattributes keeps them).
    if data.count(b"\n") != data.count(b"\r\n"):
        sys.exit(f"{name} must keep its CRLF line ends")
    files.append((name, data))
files.append(("README.txt", crlf((windows / "README.txt").read_bytes())))
files.append(("LICENSE.txt", crlf((root / "LICENSE").read_bytes())))
smart = (root / "scripts/base/game/smart_ai.lua").read_text(encoding="utf-8")
version = re.search(r"^smart\.version = (\d+)", smart, re.M).group(1)
files.append(("version.txt", f"INSANE! v{version}, OpenLF2 commit {commit}, "
              f"{time.strftime('%Y-%m-%d', time.gmtime(stamp))}\r\n".encode()))
for source, target in ((root / "scripts", "scripts"), (root / "tools/ai-bench", "tools/ai-bench")):
    for path in sorted(source.rglob("*")):
        relative = path.relative_to(source)
        if not path.is_file() or (target == "tools/ai-bench" and relative.parts[0] == "windows"):
            continue
        files.append((f"{target}/{relative.as_posix()}", path.read_bytes()))
names = {name for name, _ in files}
for needed in ("scripts/base/game/smart_ai.lua", "scripts/base/game/match.lua", "tools/ai-bench/learn.lua",
               "tools/ai-bench/duel.lua", "tools/ai-bench/brains.lua", "tools/ai-bench/spsa.lua",
               "tools/ai-bench/package.manifest"):
    if needed not in names:
        sys.exit(f"the kit lacks {needed}")
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as kit:
    for name, data in files:
        info = zipfile.ZipInfo(f"{top}/{name}", date_time=when)
        info.compress_type = zipfile.ZIP_DEFLATED
        info.external_attr = 0o644 << 16
        kit.writestr(info, data)
print(f"{out}: {len(files)} files, INSANE! v{version}, commit {commit}")
PY
