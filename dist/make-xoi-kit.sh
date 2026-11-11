#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 OpenLF2 contributors
#
# make-xoi-kit.sh OUT.zip: the XOI kit for Windows (the guide is dist/pages/xoi.html), one folder LF2-XOI-kit with
# choi.bat (play a mod with INSANE! and XOI), xoi-hoc.bat (train XOI for a mod), dau-nhieu.bat (measure),
# spsa.bat (tune XOI's numbers by play), hoc-sau.bat (XOI learns a brain, a small network scoring its moves, from its
# own games), xem.bat (watch two computer players in the window, fighters by name), can-bang.bat (fighter balance:
# each fighter's win rate against every other and what each of its moves brings, XOI playing both sides),
# xuat-ban.bat (publish a mod for its players: the mod's own folder with OpenLF2
# put in it, unpacked and played as it is; its work in xuat-ban.ps1, its players' README from xuat-ban-README.txt) and
# kiem-tra.bat (find out why the game does not open on a PC), beside this checkout's game scripts and AI bench, which
# they lay over the installed game's scripts.
# make-xoi-kit.sh --en OUT.zip: the English edition (tools/ai-bench/windows/en: the same tools under English names —
# play.bat, train.bat, measure.bat, spsa.bat, brain.bat, watch.bat, balance.bat, publish.bat, check.bat — with English
# settings and messages),
# folder LF2-XOI-kit-en.
# make-xoi-kit.sh --balance OUT.zip: the fighter balance kit on its own, in English, for any mod's maker: balance.bat,
# its README (windows/en/balance-README.txt), the scripts and the bench; folder LF2-balance-kit.
set -euo pipefail
edition=vi
if [ "${1:-}" = "--en" ]; then edition=en; shift; fi
if [ "${1:-}" = "--balance" ]; then edition=balance; shift; fi
repo_root=$(cd "$(dirname "$0")/.." && pwd)
out=$(realpath -m "$1")
mkdir -p "$(dirname "$out")"
commit=$(git -C "$repo_root" rev-parse --short HEAD 2>/dev/null || echo unknown)
stamp=$(git -C "$repo_root" log -1 --format=%ct 2>/dev/null || date +%s)
python3 - "$repo_root" "$out" "$commit" "$stamp" "$edition" <<'PY'
import re
import sys
import time
import zipfile
from pathlib import Path

root, out, commit, stamp, edition = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3], int(sys.argv[4]), sys.argv[5]
top = {"vi": "LF2-XOI-kit", "en": "LF2-XOI-kit-en", "balance": "LF2-balance-kit"}[edition]
when = time.gmtime(stamp)[:6]
files = []


def crlf(data):
    return data.replace(b"\r\n", b"\n").replace(b"\n", b"\r\n")


windows = root / "tools/ai-bench/windows"
# texts: (name in the kit, file in the windows folder)
if edition == "vi":
    bats = ("choi.bat", "xoi-hoc.bat", "dau-nhieu.bat", "spsa.bat", "hoc-sau.bat", "xem.bat", "can-bang.bat", "xuat-ban.bat",
            "kiem-tra.bat")
    texts = (("README.txt",) * 2, ("xuat-ban.ps1",) * 2, ("xuat-ban-README.txt",) * 2)
elif edition == "en":
    windows = windows / "en"
    bats = ("play.bat", "train.bat", "measure.bat", "spsa.bat", "brain.bat", "watch.bat", "balance.bat", "publish.bat",
            "check.bat")
    texts = (("README.txt",) * 2, ("publish.ps1",) * 2, ("publish-README.txt",) * 2)
else:
    windows = windows / "en"
    bats = ("balance.bat",)
    texts = (("README.txt", "balance-README.txt"),)
for name in bats:
    data = (windows / name).read_bytes()
    # cmd reads labels wrongly in a batch file without CRLF line ends (.gitattributes keeps them).
    if data.count(b"\n") != data.count(b"\r\n"):
        sys.exit(f"{name} must keep its CRLF line ends")
    files.append((name, data))
for name, source in texts:
    files.append((name, crlf((windows / source).read_bytes())))
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
for needed in [name for name, _ in texts] + [
        "scripts/base/game/smart_ai.lua", "scripts/base/game/match.lua", "tools/ai-bench/learn.lua",
        "tools/ai-bench/show.lua", "tools/ai-bench/names.lua", "tools/ai-bench/list.lua",
        "tools/ai-bench/duel.lua", "tools/ai-bench/brains.lua", "tools/ai-bench/spsa.lua",
        "tools/ai-bench/record.lua", "tools/ai-bench/train.lua", "tools/ai-bench/balance.lua",
        "tools/ai-bench/balance-report-head.html", "tools/ai-bench/balance-report-tail.html",
        "tools/ai-bench/package.manifest"]:
    if needed not in names:
        sys.exit(f"the kit lacks {needed}")
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as kit:
    for name, data in files:
        info = zipfile.ZipInfo(f"{top}/{name}", date_time=when)
        info.compress_type = zipfile.ZIP_DEFLATED
        info.external_attr = 0o644 << 16
        kit.writestr(info, data)
print(f"{out}: {len(files)} files ({top}), INSANE! v{version}, commit {commit}")
PY
