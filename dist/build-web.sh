#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
build_dir="$repo_root/build/web"
vendor_dir="$build_dir/vendor"
mkdir -p "$vendor_dir"

fetch_source() {
    local name=$1 url=$2 digest=$3
    if [[ ! -f "$vendor_dir/$name" ]]; then
        curl --fail --location --retry 3 --output "$vendor_dir/$name" "$url"
    fi
    printf '%s  %s\n' "$digest" "$vendor_dir/$name" | sha256sum --check
}

fetch_source lua-5.2.4.tar.gz https://www.lua.org/ftp/lua-5.2.4.tar.gz \
    b9e2e4aad6789b3b63a056d442f7b39f0ecfca3ae0f1fc0ae4e9614401b69f4b
fetch_source SDL3-3.4.14.tar.gz https://github.com/libsdl-org/SDL/releases/download/release-3.4.14/SDL3-3.4.14.tar.gz \
    30d4aa2b3037718142b32dffd4e72f917ebb6cc5227150e7bb9c45efb2153aeb
fetch_source ffmpeg-7.1.5.tar.xz https://ffmpeg.org/releases/ffmpeg-7.1.5.tar.xz \
    de668509caf9e35e3cd162473441fdb29538c6d96ed080292b3cf9e6fc5d558f
fetch_source freetype-2.13.2.tar.xz https://download.savannah.gnu.org/releases/freetype/freetype-2.13.2.tar.xz \
    12991c4e55c506dd7f9b765933e62fd2be2e06d421505d7950a132e4f1bb484d
fetch_source SDL3_ttf-3.2.2.tar.gz https://github.com/libsdl-org/SDL_ttf/releases/download/release-3.2.2/SDL3_ttf-3.2.2.tar.gz \
    63547d58d0185c833213885b635a2c0548201cc8f301e6587c0be1a67e1e045d

if [[ ! -d "$vendor_dir/lua-5.2.4" ]]; then
    tar -xf "$vendor_dir/lua-5.2.4.tar.gz" -C "$vendor_dir"
fi
if [[ ! -d "$vendor_dir/SDL3-3.4.14" ]]; then
    tar -xf "$vendor_dir/SDL3-3.4.14.tar.gz" -C "$vendor_dir"
fi
if [[ ! -d "$vendor_dir/freetype-2.13.2" ]]; then
    tar -xf "$vendor_dir/freetype-2.13.2.tar.xz" -C "$vendor_dir"
fi
if [[ ! -d "$vendor_dir/SDL3_ttf-3.2.2" ]]; then
    tar -xf "$vendor_dir/SDL3_ttf-3.2.2.tar.gz" -C "$vendor_dir"
fi
if [[ ! -d "$vendor_dir/ffmpeg-7.1.5" ]]; then
    tar -xf "$vendor_dir/ffmpeg-7.1.5.tar.xz" -C "$vendor_dir"
fi

# Ruffle (MIT OR Apache-2.0), the Flash player the site page runs Hero Fighter in (dist/pages/hero-fighter.js): its
# self-hosted build, the nightly Hero Fighter was tested with, from its GitHub release (checked) or else the same
# version from npm. Failing both, the newest Ruffle on npm; failing that too, the bundle has no Ruffle (LF2 still plays).
ruffle_version=0.8.0-nightly.2026.10.29
ruffle_zip=ruffle-nightly-2026_10_29-web-selfhosted.zip
ruffle_url=https://github.com/ruffle-rs/ruffle/releases/download/nightly-2026-10-29/$ruffle_zip
ruffle_sha256=febf15317b3d2bffd52b623a1feeaa64fdfcb3f52b4daf0da01b690d3ec932e3
ruffle_dir="$build_dir/ruffle"
fetch_ruffle() {
    local zip="$vendor_dir/$ruffle_zip" package="$build_dir/ruffle-package" found
    rm -rf "$ruffle_dir" "$package"
    mkdir -p "$package"
    if [[ ! -f "$zip" ]]; then
        if curl --fail --location --retry 3 --output "$zip.part" "$ruffle_url"; then mv "$zip.part" "$zip"; else rm -f "$zip.part"; fi
    fi
    if [[ -f "$zip" ]] && printf '%s  %s\n' "$ruffle_sha256" "$zip" | sha256sum --check --quiet; then
        python3 -m zipfile -e "$zip" "$package"
    elif (cd "$package" && npm pack "@ruffle-rs/ruffle@$ruffle_version" --silent && tar -xzf ./*.tgz); then
        printf 'Ruffle %s from npm\n' "$ruffle_version"
    else
        printf 'warning: Ruffle %s is not available: trying the newest Ruffle on npm\n' "$ruffle_version" >&2
        rm -rf "$package" && mkdir -p "$package"
        if ! (cd "$package" && npm pack @ruffle-rs/ruffle --silent && tar -xzf ./*.tgz); then
            printf 'warning: no Ruffle: Hero Fighter will not start on the site\n' >&2
            return 0
        fi
    fi
    # ruffle.js and the files it loads (its .wasm builds) sit together.
    found=$(find "$package" -name ruffle.js -printf '%d %p\n' | sort -n | awk 'NR == 1 { sub(/^[0-9]+ /, ""); print }')
    if [[ -z "$found" || -z "$(find "$(dirname "$found")" -name '*.wasm' -print -quit)" ]]; then
        printf 'warning: the Ruffle package has no ruffle.js or .wasm: Hero Fighter will not start on the site\n' >&2
        return 0
    fi
    mkdir -p "$ruffle_dir"
    cp -r "$(dirname "$found")"/. "$ruffle_dir"/
    rm -f "$ruffle_dir"/*.map
}
fetch_ruffle

# Favicons are rendered from the project's SVG here, on the host, and handed to the container.
python3 "$repo_root/tools/icons/make_icons.py" "$build_dir/icons"

docker build --quiet --platform linux/amd64 -f "$repo_root/dist/web/Dockerfile" \
    -t openlf2-web:local "$repo_root/dist/web"
docker run --rm --platform linux/amd64 --user "$(id -u):$(id -g)" \
    -v "$repo_root:/workspace" -w /workspace \
    openlf2-web:local \
    bash dist/web/build-inside.sh

# The page's icon: the project's SVG itself, plus the raster fallbacks rendered from it.
cp "$repo_root/dist/io.github.openlf2.OpenLF2.svg" "$build_dir/native/icon.svg"
cp "$repo_root/dist/web/installer-store.js" "$build_dir/native/installer-store.js"
cp "$repo_root/dist/web/online.js" "$build_dir/native/online.js"
cp "$build_dir/icons/web/favicon.ico" "$build_dir/icons/web/favicon-32.png" \
    "$build_dir/icons/web/apple-touch-icon.png" "$build_dir/native/"
# Hero Fighter on the site page (dist/pages/index.html): its script, the version check it answers, and Ruffle.
cp "$repo_root/dist/pages/hero-fighter.js" "$repo_root/dist/pages/hf-ver.txt" "$build_dir/native/"
rm -rf "$build_dir/native/ruffle"
bundle_extra=(hero-fighter.js hf-ver.txt)
if [[ -f "$ruffle_dir/ruffle.js" ]]; then
    cp -r "$ruffle_dir" "$build_dir/native/ruffle"
    bundle_extra+=(ruffle)
fi
python3 "$repo_root/dist/collect-licenses.py" "$build_dir/native/licenses" \
    --local "ffmpeg=$vendor_dir/ffmpeg-7.1.5/COPYING.LGPLv2.1" \
    --local "ffmpeg-notes=$vendor_dir/ffmpeg-7.1.5/LICENSE.md" \
    --local "lua=$vendor_dir/lua-5.2.4/doc/readme.html" \
    --local "sdl3=$vendor_dir/SDL3-3.4.14/LICENSE.txt" \
    --local "sdl3-ttf=$vendor_dir/SDL3_ttf-3.2.2/LICENSE.txt" \
    --local "freetype=$vendor_dir/freetype-2.13.2/docs/FTL.TXT" \
    --local "zlib=$build_dir/emscripten-cache/ports/zlib/zlib-1.3.1/LICENSE" \
    --local "bzip2=$build_dir/emscripten-cache/ports/bzip2/bzip2-1.0.6/LICENSE"
(
    cd "$build_dir/native"
    python3 -m zipfile -c ../OpenLF2-Web.zip index.html installer-store.js online.js icon.svg favicon.ico favicon-32.png apple-touch-icon.png \
        openlf2.js openlf2.wasm openlf2.data licenses "${bundle_extra[@]}"
)
printf 'Web bundle: %s\n' "$build_dir/OpenLF2-Web.zip"
