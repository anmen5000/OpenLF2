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
# self-hosted build, the stable release (0.7.1 runs Hero Fighter about twice as fast as the October 2026 nightlies),
# from its GitHub release (checked) or else the same version from npm. Failing both, the newest Ruffle on npm;
# failing that too, the bundle has no Ruffle (LF2 still plays).
ruffle_version=0.7.1
ruffle_zip=ruffle-0.7.1-web-selfhosted.zip
ruffle_url=https://github.com/ruffle-rs/ruffle/releases/download/v0.7.1/$ruffle_zip
ruffle_sha256=ef12edbee135d581a9cd523837d746da30a07a64dbf1cf472d2e472c656f4b5e
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
    # ruffle.js and the files it loads (its .wasm builds, and core.ruffle.*.js for 0.7) sit together.
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

# Then the same Ruffle 0.7.1 built from its source with OpenLF2's change in dist/ruffle-hf: a bitmap
# drawn turned, flipped or scaled (Hero Fighter draws its fighters, shadows and effects so, in every
# frame) is drawn on the CPU when the target's pixels are there, rather than on the GPU and copied
# back at the next CPU operation. Built in Docker, in about 20 minutes; if any step fails, the stock
# 0.7.1 above stays (Hero Fighter plays the same, only slower on some computers). RUFFLE_HF=0 skips it.
# When it builds, the stock one goes in ruffle-stock/ beside it.
ruffle_hf_commit=89a7049965f3090e706265670df309a5128233ac # v0.7.1
ruffle_stock_dir="$build_dir/ruffle-stock"
ruffle_hf_log="$build_dir/ruffle-hf.log"
rm -rf "$ruffle_stock_dir" "$ruffle_hf_log"
build_ruffle_hf() {
    local work="$build_dir/ruffle-hf" image=openlf2-ruffle-hf container copied=0
    local src="$work/ruffle"
    rm -rf "$work"
    mkdir -p "$work"
    git clone --quiet --depth 1 --branch v0.7.1 --filter=blob:none --sparse \
        https://github.com/ruffle-rs/ruffle.git "$src" || return 1
    # Everything but the test movies (thousands of files the web build does not read).
    git -C "$src" sparse-checkout set --no-cone '/*' '!/tests/tests/swfs/' || return 1
    if [[ "$(git -C "$src" rev-parse HEAD)" != "$ruffle_hf_commit" ]]; then
        printf 'warning: Ruffle v0.7.1 is not commit %s\n' "$ruffle_hf_commit" >&2
        return 1
    fi
    cp "$repo_root/dist/ruffle-hf/draw_on_cpu.rs" "$src/core/src/bitmap/operations/draw_on_cpu.rs" || return 1
    git -C "$src" apply "$repo_root/dist/ruffle-hf/operations.patch" || return 1
    printf 'ruffle/.git\nruffle/target\nruffle/web/node_modules\n' > "$work/.dockerignore"
    docker build --progress=plain --platform linux/amd64 -t "$image" \
        -f "$repo_root/dist/ruffle-hf/Dockerfile" "$work" 2>&1 | tee "$ruffle_hf_log"
    if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
        return 1
    fi
    container=$(docker create --platform linux/amd64 "$image") || return 1
    docker cp "$container:/ruffle/web/packages/selfhosted/dist" "$work/dist" || copied=1
    docker rm "$container" > /dev/null || true
    docker rmi "$image" > /dev/null 2>&1 || true
    docker builder prune --force > /dev/null 2>&1 || true
    if [[ $copied -ne 0 || ! -f "$work/dist/ruffle.js" || -z "$(find "$work/dist" -maxdepth 1 -name '*.wasm' -print -quit)" ]]; then
        printf 'warning: the Ruffle build made no ruffle.js or .wasm\n' >&2
        return 1
    fi
    rm -f "$work/dist"/*.map
    cp "$repo_root/dist/ruffle-hf/draw_on_cpu.rs" "$repo_root/dist/ruffle-hf/operations.patch" "$work/dist"/ || return 1
    printf 'Ruffle 0.7.1 (https://github.com/ruffle-rs/ruffle, commit %s), built with OpenLF2'"'"'s change:\ndraw_on_cpu.rs (new: core/src/bitmap/operations/draw_on_cpu.rs) and operations.patch.\nRuffle is MIT or Apache-2.0 licensed (LICENSE_MIT, LICENSE_APACHE); so is the change.\n' \
        "$ruffle_hf_commit" > "$work/dist/OPENLF2.txt" || return 1
    # The stock one stays beside it, for pages opened with ruffle=stock (dist/pages/hero-fighter.js).
    rm -rf "$ruffle_stock_dir"
    if [[ -d "$ruffle_dir" ]]; then mv "$ruffle_dir" "$ruffle_stock_dir"; fi
    mv "$work/dist" "$ruffle_dir"
    rm -rf "$work"
}
if [[ "${RUFFLE_HF:-1}" != 0 ]]; then
    if build_ruffle_hf; then
        printf 'Ruffle for Hero Fighter: 0.7.1 with OpenLF2'"'"'s CPU drawing\n'
    else
        printf 'warning: Ruffle with OpenLF2'"'"'s change did not build: the site keeps the stock Ruffle 0.7.1\n' >&2
        # On GitHub, also a note on the run's page with the build's last lines (the log is long).
        if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
            note="Ruffle with OpenLF2's change did not build; the site keeps the stock Ruffle 0.7.1."
            if [[ -f "$ruffle_hf_log" ]]; then
                # Rust's errors (each with the lines that explain it), else the end of the log.
                errors=$(grep -E -m 6 -A 10 'error(\[E[0-9]+\])?: ' "$ruffle_hf_log" | head -n 60 || true)
                if [[ -z "$errors" ]]; then
                    errors=$(tail -n 30 "$ruffle_hf_log")
                fi
                note+=$'\n'"$errors"
            fi
            note=${note//'%'/'%25'}
            note=${note//$'\r'/'%0D'}
            note=${note//$'\n'/'%0A'}
            printf '::warning title=Ruffle for Hero Fighter::%s\n' "$note"
        fi
        rm -rf "$build_dir/ruffle-hf"
    fi
fi

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
# The site's other pages travel in the bundle too, so that a Pages job that only swaps index.html in (an older
# .github/workflows/web.yml, which a file upload to GitHub does not replace) still publishes them.
cp "$repo_root/dist/pages/insane.html" "$repo_root/dist/pages/windows.html" "$build_dir/native/"
rm -rf "$build_dir/native/ruffle" "$build_dir/native/ruffle-stock"
bundle_extra=(hero-fighter.js hf-ver.txt insane.html windows.html)
if [[ -f "$ruffle_dir/ruffle.js" ]]; then
    cp -r "$ruffle_dir" "$build_dir/native/ruffle"
    bundle_extra+=(ruffle)
fi
if [[ -f "$ruffle_stock_dir/ruffle.js" ]]; then
    cp -r "$ruffle_stock_dir" "$build_dir/native/ruffle-stock"
    bundle_extra+=(ruffle-stock)
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
