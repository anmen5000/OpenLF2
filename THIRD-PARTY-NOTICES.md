<!-- SPDX-License-Identifier: MIT -->
<!--
  Notice inventory for dist/collect-licenses.py. Keep version strings in sync
  with conanfile.py and the per-platform toolchain documentation. Per-target
  release review still needs to check linked transitive libraries.

  Platform keys: appimage, deb, flatpak, windows, apple, ios, android, web, switch, vita.
  A row is required on a platform when that platform appears in its "Platforms" cell.
  "Notice source" records where the verbatim license text comes from at build time;
  the build scripts pass those paths to the collector.
-->

# Third-party notices

OpenLF2's own code, scripts and documentation are MIT-licensed ([LICENSE](LICENSE)). This
file inventories the licenses of the third-party components that artifacts may carry.
It is not itself a collection of their verbatim license texts. The original Little
Fighter 2 installer, executable and assets are **not** redistributed and carry no license
here; players supply `LF2_v2.0a.exe` themselves, or Flatpak downloads the pinned
archive.org snapshot of the lf2.net installer as extra data during installation.

Verbatim license texts are never transcribed here. The package scripts stage
direct dependency notices through `dist/collect-licenses.py`; remaining
transitive-library and static-linking checks are tracked separately.

The Debian package links separate Debian dependency packages, which carry their own
copyright files. Its own `/usr/share/doc/openlf2/copyright` includes the MIT license.
The Flatpak bundles LuaJIT and installs its upstream `COPYRIGHT` under
`/app/share/licenses/luajit/`; OpenLF2's license is under `/app/share/licenses/openlf2/`.
Other dependencies are supplied separately by the Freedesktop 26.08 runtime.
The AppImage uses PulseAudio only while building SDL3; its packaging script rejects
bundled PulseAudio libraries or a direct SDL3 link to one, so PulseAudio is not a
distributed component in the notice table below.

| Key | Component | Conan reference | Other versions | License | Platforms | Notice source |
| --- | --- | --- | --- | --- | --- | --- |
| ffmpeg | FFmpeg (libavformat, libavcodec, libavutil, libswresample) | ffmpeg/7.1.5 | 7.1.5 (Conan, web, Switch 7.1, Vita 9.0.1); system packages: Debian 13 7.1.5, Ubuntu 24.04 6.1.1 | LGPL-2.1-or-later (AppImage, Windows, Apple, Android, Switch, Vita and web builds) or GPL-2.0-or-later (Debian and Ubuntu system packages) | appimage, windows, apple, ios, android, switch, vita, web | upstream `COPYING.LGPLv2.1` from the versioned source archive, plus the archive itself and the build recipe |
| sdl3 | SDL3 | sdl/3.4.14 | 3.4.14 (Conan, Android, Switch), 3.4.16 (VitaSDK), 3.2.22 (Emscripten port) | Zlib | appimage, windows, apple, ios, android, web, switch, vita | upstream `LICENSE.txt`; Android also ships the `org/libsdl.app` Java glue from the same release |
| luajit | LuaJIT | luajit/2.1.0-20260908 | 2.1.0-20260908 (commit `c6ffc141a8762b41703f9287d63d93622a13dd8f`) | MIT | appimage, flatpak, windows, apple, ios, android, switch, vita | upstream `COPYRIGHT` |
| lua | Lua (web port only; LuaJIT has no WebAssembly target there) | — | 5.2.4 | MIT | web | upstream `doc/readme.html` license notice in the source archive |
| zlib | zlib | zlib/1.3.2 | 1.3.2 (Conan, Vita), 1.3.1 (Emscripten port, Switch portlibs) | Zlib | appimage, windows, apple, ios, android, web, switch, vita | upstream `LICENSE` from the source archive, or the distribution package's copyright file |
| bzip2 | bzip2 | bzip2/1.0.8 | 1.0.8 (Conan, Vita), 1.0.6 (Emscripten port) | bzip2-1.0.6 | appimage, windows, apple, ios, android, web, switch, vita | upstream `LICENSE` from the source archive, or the distribution package's copyright file |
| openssl | OpenSSL libcrypto | openssl/3.5.7 | 3.5.7 (Conan), 1.1.1t-dev (VitaSDK) | Apache-2.0 (Conan); OpenSSL/SSLeay dual license (VitaSDK 1.1.1t) | appimage, android, windows, apple, ios, vita | upstream `LICENSE.txt` or `LICENSE` from the matching source archive |
| libcurl | libcurl | libcurl/8.21.0 | 8.21.0 (Conan), 7.69.1 (Switch portlibs), 8.22.0 (VitaSDK `curl-mbedtls`) | curl | appimage, android, windows, apple, ios, switch, vita | upstream `COPYING` from the source archive, or the distribution package's copyright file |
| mbedtls | mbedTLS (replaces OpenSSL behind the SHA-256 adapter on Switch, and libcurl's TLS backend on Vita) | — | 2.28.10 (Switch portlibs), 3.6.5 (VitaSDK) | Apache-2.0 | switch, vita | portlib or package copyright file |
| dejavu-sans | DejaVu Sans, the Latin font of the translated languages (`scripts/base/fonts/dejavu_sans.ttf`) | — | 2.37 | Bitstream Vera license, with the Arev Fonts license for imported glyphs; DejaVu's own changes are public domain | appimage, deb, flatpak, windows, apple, ios, android, web, switch, vita | the license embedded in the font, shipped beside it as `scripts/base/fonts/license-dejavu.txt` |
| droid-sans-fallback | Droid Sans Fallback, the CJK fallback font of the translated languages (`scripts/base/fonts/droid_sans_fallback.ttf`) | — | Full build, version 1.00c | Apache-2.0 | appimage, deb, flatpak, windows, apple, ios, android, web, switch, vita | the Apache-2.0 text with the font's copyright line, shipped beside it as `scripts/base/fonts/license-droid.txt` |
| sdl3-ttf | SDL3_ttf, the text renderer of the translated languages (CMake option `OPENLF2_TEXT_RENDERING`; optional) | sdl_ttf/3.2.2 | 3.2.2 (also what `OPENLF2_FETCH_SDL3_TTF` fetches) | Zlib | appimage, windows, apple, ios, android, portmaster, switch, web, flatpak, vita | upstream `LICENSE.txt` (deb: the distribution's `libsdl3-ttf` package) |
| freetype | FreeType, required by SDL3_ttf | freetype/2.13.2 | 2.13.2 | FreeType License (FTL), used instead of its GPL-2.0-only alternative | appimage, windows, apple, ios, android, portmaster, switch, web, vita | upstream `docs/FTL.TXT` at tag `VER-2-13-2` (flatpak and deb: the runtime's or distribution's FreeType) |
| harfbuzz | HarfBuzz, linked into the VitaSDK's SDL3_ttf | — | 14.4.0 (VitaSDK) | "Old MIT" license | vita | upstream `COPYING` at tag `14.4.0` |
| ca-certificates | Mozilla CA trust bundle from the pinned VitaSDK image | — | 20260601~24.04.1 | MPL-2.0 for Mozilla source data | vita | `/usr/share/doc/ca-certificates/copyright` from the same image; includes notices for package tools that are not shipped |
| alsa | ALSA (libasound and its `alsa.conf` configuration tree) | — | distribution package | LGPL-2.1-or-later | appimage | `/usr/share/doc/libasound2-data/copyright` |
| ndk-runtime | Android NDK `libc++_shared.so` | — | 28.2.13676358 (r28c) | Apache-2.0 WITH LLVM-exception | android | the NDK's own license file in the pinned toolchain |
| mpg123 | mpg123 (VitaSDK runtime) | — | 1.33.7 | LGPL-2.1-or-later | vita | upstream `COPYING` from the versioned source archive |
| egl | Mesa EGL (Switch portlibs) | — | 20.1.0-rc3 | mixed Mesa notices | switch | upstream `docs/license.html` from the versioned source archive |
| system-libs | Shared system libraries bundled by `linuxdeploy` (X11, Wayland, Mesa, ALSA and their transitive dependencies) | — | as resolved in the build container | per package | appimage | `/usr/share/doc/<package>/copyright`, discovered per bundled library by `dist/audit-appimage-libs.sh` |
| appimage-runtime | AppImage type2-runtime (the startup stub embedded in every AppImage) | — | 20251108 | MIT | appimage | `LICENSE` from the pinned runtime tag, verified by SHA-256 |
| ruffle | Ruffle, the Flash player the site's Hero Fighter page runs in (`dist/pages/hero-fighter.js`); fetched by `dist/build-web.sh` as a release package, or rebuilt from the same release with OpenLF2's CPU bitmap-drawing change (`dist/ruffle-hf/`) | — | 0.7.1 (web self-hosted release, SHA-256 checked; commit `89a7049965f3090e706265670df309a5128233ac`) | MIT OR Apache-2.0 (OpenLF2's change is under the same terms) | web | the license files shipped inside the Ruffle package, copied into `ruffle/` with it; `ruffle/OPENLF2.txt` names the change when the rebuilt one ships |
| boxedwine | BoxedWine, the Windows emulator of the site's `windows.html` page (`dist/boxedwine/build.sh` builds it with Emscripten; `patch-shell.py` changes its shell) | — | commit pinned in `dist/boxedwine/build.sh` | GPL-2.0-or-later (the emulator is a separate program in its own `windows/` folder and is not linked with OpenLF2; `patch-shell.py` is GPL-2.0-or-later itself) | web | upstream `license.txt`, written into `windows/LICENSES.txt` with the component list |
| wine | Wine, inside BoxedWine's Wine 11.0 file system (`wine.zip`, with Tiny Core Linux) | — | 11.0, SHA-256 pinned in `dist/boxedwine/build.sh` | LGPL-2.1-or-later (Wine) and the licenses of the other free software in the image | web | `windows/LICENSES.txt`, naming the source archive address |
| mfc80 | Microsoft MFC 8.0 (8.0.50727.6195) from the Visual C++ 2005 SP1 Redistributable Package, overlaid for mods that need it (`vc80.zip`) | — | 8.0.50727.6195 | Microsoft's terms for that redistributable package | web | `windows/LICENSES.txt`, naming the package address |
| build-tools | `linuxdeploy`, `appimagetool`, Conan 2, CMake, devkitPro, VitaSDK, Emscripten, Android SDK/NDK, Gradle | — | as pinned in the project's build tooling | MIT, Apache-2.0, BSD-3-Clause, EPL-2.0 and others | _(none)_ | Build-time tools that are not shipped inside any artifact, so no notice is bundled. |

The two fonts are data files in the base package, so every artifact that carries the scripts carries
them and their license texts. SDL3_ttf and FreeType are linked by the Conan-based builds. The other
artifacts (Debian, Flatpak, web, Switch, Vita, PortMaster) have no text renderer and offer only the default
language; one that gains it must add its platform to those two rows and stage both notices.

## Why these are the obligations

- **LGPL-2.1-or-later (FFmpeg, ALSA, mpg123).** Static linking is allowed under the LGPL
  with its section 6 distribution conditions. FFmpeg's checklist recommends shared
  linking as one practical route, along with corresponding source, build instructions
  and license text. AppImage and Android build shared FFmpeg; both stage its license text,
  while only AppImage currently bundles the corresponding source archive.
  Switch, Vita, web and iOS use static FFmpeg and need a relinking plan and corresponding
  materials before distribution.
- **GPL-2.0-or-later (Debian's and Ubuntu's FFmpeg).** The `deb` and local system builds link
  a GPL FFmpeg, which makes the combined work GPL-2.0-or-later as a whole. The `deb` package
  says so in its generated `copyright` file; the project stays MIT for its own
  code. Redistributing the `deb` therefore requires the complete corresponding source.
- **Apache-2.0 (OpenSSL 3, mbedTLS, the NDK runtime).** Redistribution must carry a copy of the license
  and any `NOTICE` content, and must state changes.
- **Bitstream Vera and Apache-2.0 fonts (DejaVu Sans, Droid Sans Fallback).** The copyright and
  license notices stay with the font files, which the fonts' own terms allow to be bundled but
  not sold by themselves; a modified font must be renamed.
- **zlib, bzip2-1.0.6, curl and the MIT licenses (SDL3, LuaJIT, Lua, Mesa).** Redistribution
  must reproduce the notice text; these require no source offer and no relinkability.
