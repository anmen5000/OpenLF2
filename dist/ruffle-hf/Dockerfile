# SPDX-License-Identifier: MIT
#
# Ruffle's self-hosted web package (web/packages/selfhosted/dist), built from the Ruffle source in
# the build context's ruffle/ folder: dist/build-web.sh puts Ruffle 0.7.1 there with OpenLF2's change
# (draw_on_cpu.rs, operations.patch). The tools are the ones Ruffle 0.7.1's own release build used:
# Node.js 24, Rust stable with the wasm32 target, wasm-bindgen 0.2.127, Binaryen 129's wasm-opt, and
# Java (core/build.rs runs Ruffle's tools/asc/asc.jar to compile its ActionScript classes); clang in
# case a dependency compiles C for wasm32.
FROM node:24-bookworm

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends default-jre-headless clang; \
    rm -rf /var/lib/apt/lists/*; \
    java -version

RUN set -eux; \
    curl -fsSL --retry 3 -o /tmp/binaryen.tar.gz \
        https://github.com/WebAssembly/binaryen/releases/download/version_129/binaryen-version_129-x86_64-linux.tar.gz; \
    echo "50b9fa62b9abea752da92ec57e0c555fee578760cd237c40107957715d2976ba  /tmp/binaryen.tar.gz" | sha256sum -c -; \
    tar -xzf /tmp/binaryen.tar.gz -C /tmp binaryen-version_129/bin/wasm-opt; \
    mv /tmp/binaryen-version_129/bin/wasm-opt /usr/local/bin/wasm-opt; \
    curl -fsSL --retry 3 -o /tmp/wasm-bindgen.tar.gz \
        https://github.com/wasm-bindgen/wasm-bindgen/releases/download/0.2.127/wasm-bindgen-0.2.127-x86_64-unknown-linux-musl.tar.gz; \
    echo "61d4a7dc85acfa0d2354ccc0b8361928c7e52a746d17f28ebaa795ed3dc1614a  /tmp/wasm-bindgen.tar.gz" | sha256sum -c -; \
    tar -xzf /tmp/wasm-bindgen.tar.gz -C /tmp wasm-bindgen-0.2.127-x86_64-unknown-linux-musl/wasm-bindgen; \
    mv /tmp/wasm-bindgen-0.2.127-x86_64-unknown-linux-musl/wasm-bindgen /usr/local/bin/wasm-bindgen; \
    rm -rf /tmp/binaryen* /tmp/wasm-bindgen*; \
    wasm-opt --version; \
    wasm-bindgen --version

RUN set -eux; \
    curl -fsSL --retry 3 https://sh.rustup.rs -o /tmp/rustup.sh; \
    sh /tmp/rustup.sh -y --profile minimal --default-toolchain stable --target wasm32-unknown-unknown; \
    rm /tmp/rustup.sh
ENV PATH="/root/.cargo/bin:${PATH}"

COPY ruffle /ruffle
WORKDIR /ruffle/web
# Without install scripts: they only fetch the browser drivers of Ruffle's browser tests (edgedriver,
# geckodriver) and check esbuild and protobufjs, none of which this build uses.
RUN npm ci --ignore-scripts --no-audit --no-fund
# The core package (it runs cargo, wasm-bindgen and wasm-opt for the one .wasm module all current
# browsers run), then the self-hosted package around it.
RUN npm run build --workspace=ruffle-core && npm run build --workspace=ruffle-selfhosted
