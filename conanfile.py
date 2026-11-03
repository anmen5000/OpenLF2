# SPDX-License-Identifier: MIT
# Copyright (c) 2026 OpenLF2 contributors

"""Conan 2 dependency graph for OpenLF2's CMake consumer build."""

from conan import ConanFile
from conan.tools.cmake import CMakeDeps, CMakeToolchain
from conan.tools.env import VirtualRunEnv


class OpenLF2Conan(ConanFile):
    name = "openlf2"
    version = "1.1.2"
    settings = "os", "arch", "compiler", "build_type"
    default_options = {
        "sdl/*:shared": True,
        # SDL loads host PulseAudio only when this dependency is shared.
        "pulseaudio/*:shared": True,
        "pulseaudio/*:with_x11": False,
        "pulseaudio/*:with_openssl": False,
        "pulseaudio/*:with_dbus": False,
        "pulseaudio/*:with_glib": False,
        "pulseaudio/*:with_fftw": False,
        # PulseAudio needs libsndfile, not its optional MPEG codecs.
        "libsndfile/*:with_mpeg": False,
        "ffmpeg/*:shared": True,
        "ffmpeg/*:avdevice": False,
        "ffmpeg/*:avfilter": False,
        "ffmpeg/*:swscale": False,
        "ffmpeg/*:postproc": False,
        "ffmpeg/*:with_asm": False,
        "ffmpeg/*:disable_everything": True,
        # The original's music is WMA (version 2); mods also have WMA version 1, WMA Pro (Naruto: The Setting Dawn
        # 2.4's and One Piece GrandWorld's main.wma, among others) and MP3 (One Piece GrandWorld): the web build's
        # decoders (dist/web/build-inside.sh).
        "ffmpeg/*:enable_decoders": "wmav1,wmav2,wmapro,mp3float,mp3",
        "ffmpeg/*:enable_demuxers": "asf,mp3",
        "ffmpeg/*:enable_parsers": "mpegaudio",
        # SDL3_ttf (translated languages) must be built like SDL; no text shaping or SVG emoji is needed.
        "sdl_ttf/*:shared": True,
        "sdl_ttf/*:with_harfbuzz": False,
        "sdl_ttf/*:with_plutosvg": False,
        "freetype/*:with_png": False,
        "freetype/*:with_brotli": False,
    }

    @property
    def external_sdl(self):
        # PortMaster builds supply their own SDL3 (a shim over the device's SDL2) through CMake.
        return bool(self.conf.get("user.openlf2:external_sdl", default=False, check_type=bool))

    def configure(self):
        if self.settings.os in ("Linux", "FreeBSD") and not self.external_sdl:
            sdl = self.options["sdl"]
            sdl.pulseaudio = True
            sdl.sndio = False
            sdl.dbus = False
            sdl.libudev = False
        # Keep FFmpeg self-contained and LGPL, not ConanCenter's default integrations.
        ffmpeg = self.options["ffmpeg"]
        for option in (
            "with_zlib", "with_bzip2", "with_lzma", "with_libiconv",
            "with_freetype", "with_libxml2", "with_fontconfig", "with_fribidi",
            "with_harfbuzz", "with_libjxl", "with_openjpeg", "with_openh264",
            "with_opus", "with_vorbis", "with_zeromq", "with_sdl",
            "with_libx264", "with_libx265", "with_libvpx", "with_libmp3lame",
            "with_libwebp", "with_libsvtav1", "with_libaom", "with_libdav1d",
            "with_soxr", "with_programs",
        ):
            setattr(ffmpeg, option, False)
        ffmpeg.with_ssl = False
        if self.settings.os in ("Linux", "FreeBSD"):
            for option in (
                "with_libalsa", "with_pulse", "with_vaapi", "with_vdpau",
                "with_vulkan", "with_xcb", "with_xlib", "with_libdrm",
            ):
                setattr(ffmpeg, option, False)
        if self.settings.os != "Android":
            ffmpeg.with_libfdk_aac = False
        if self.settings.os == "Macos":
            ffmpeg.with_appkit = False
        if self.settings.os in ("Macos", "iOS", "tvOS"):
            # OpenSSL has no system CA bundle on iOS; use Apple's native trust store.
            self.options["libcurl"].with_apple_sectrust = True
            ffmpeg.with_coreimage = False
            ffmpeg.with_audiotoolbox = False
            ffmpeg.with_videotoolbox = False
            ffmpeg.with_avfoundation = False
        if self.settings.os == "Android":
            ffmpeg.with_jni = False
            ffmpeg.with_mediacodec = False

    def requirements(self):
        if not self.external_sdl:
            self.requires("sdl/3.4.14")
            # Pinned (the recipe accepts any 2.x from 2.13.2) so the license notice matches.
            self.requires("sdl_ttf/3.2.2")
            self.requires("freetype/2.13.2", override=True)
        else:
            # SDL is the caller's, so SDL3_ttf is built by CMake (OPENLF2_FETCH_SDL3_TTF) against this FreeType.
            self.requires("freetype/2.13.2")
        self.requires("luajit/2.1.0-20260908")
        self.requires("zlib/1.3.2")
        self.requires("bzip2/1.0.8")
        self.requires("openssl/3.5.7")
        self.requires("libcurl/8.21.0")
        self.requires("ffmpeg/7.1.5")

    def generate(self):
        dependencies = CMakeDeps(self)
        dependencies.set_property("luajit", "cmake_file_name", "LuaJIT")
        dependencies.set_property("luajit", "cmake_target_name", "LuaJIT::LuaJIT")
        dependencies.set_property("sdl_ttf", "cmake_target_name", "SDL3_ttf::SDL3_ttf")
        dependencies.set_property("ffmpeg", "cmake_file_name", "FFmpeg")
        for component in ("avformat", "avcodec", "avutil", "swresample"):
            dependencies.set_property(
                f"ffmpeg::{component}", "cmake_target_name", f"FFmpeg::{component}"
            )
        dependencies.generate()

        toolchain = CMakeToolchain(self)
        toolchain.generate()
        VirtualRunEnv(self).generate()
