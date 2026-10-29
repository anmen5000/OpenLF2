#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Tests dist/ruffle-hf's change without building Ruffle (which takes Docker and 20 minutes): a sparse
# checkout of Ruffle 0.7.1 with the change applied, and make_crates.py's workspace around its files.
# draw_on_cpu.rs is checked against a model of what the GPU draws (draw.rs: positions, sampling,
# colour transforms, blend modes, a few thousand random draws), and the lines the patch adds to
# `draw` are compiled against stand-ins with Ruffle's signatures. Needs git, python3 and cargo
# (no crates are downloaded).
#   dist/ruffle-hf/test/run.sh
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
patch_dir=$(dirname "$here")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

git clone --quiet --depth 1 --branch v0.7.1 --filter=blob:none --sparse \
    https://github.com/ruffle-rs/ruffle.git "$work/ruffle" 2> /dev/null
git -C "$work/ruffle" sparse-checkout set --no-cone /swf/src/types.rs /swf/src/types/ /core/src/bitmap/ /render/src/bitmap.rs
git -C "$work/ruffle" apply "$patch_dir/operations.patch"
cp "$patch_dir/draw_on_cpu.rs" "$work/ruffle/core/src/bitmap/operations/draw_on_cpu.rs"
python3 -I "$here/make_crates.py" "$work/ruffle" "$work/crates" "$here/draw.rs"
cd "$work/crates"
cargo build --offline --quiet -p glue
# Without --release: with Rust's overflow checks, which Ruffle's web build leaves out.
cargo test --offline --quiet -p harness -- --nocapture
