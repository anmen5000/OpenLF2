// SPDX-License-Identifier: MIT
// Copyright (c) 2026 OpenLF2 contributors

#include "openlf2/engine/application.hpp"
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <iostream>
#include <limits>
#include <span>
#include <string>
#include <streambuf>
#include <vector>
#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>
#ifdef OPENLF2_GUI_SUBSYSTEM
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#endif
#ifdef __SWITCH__
#include <switch.h>
#endif

#ifdef OPENLF2_GUI_SUBSYSTEM
namespace {
class WindowsOutputBuffer final : public std::streambuf {
public:
    void set_handle(HANDLE handle) {
        handle_ = handle;
        DWORD mode = 0;
        is_console_ = GetConsoleMode(handle, &mode) != 0;
    }

private:
    std::streamsize xsputn(const char* data, std::streamsize count) override {
        if (count <= 0) return 0;
        // What Lua's print left in the C runtime's buffer goes out first: both often reach one file (a batch file's
        // `> out.txt 2>&1`), and a message written past that buffer landed in the middle of the line it held — the
        // game's last message, "screen must declare a viewport", cut a bench job's last line in two.
        std::fflush(stdout);
        const auto input = std::span(data, static_cast<std::size_t>(count));
        if (!is_console_) return write_bytes(input);

        std::string lines;
        lines.reserve(input.size());
        for (const char byte : input) {
            if (byte == '\n' && previous_byte_ != '\r') lines.push_back('\r');
            lines.push_back(byte);
            previous_byte_ = byte;
        }
        return write_bytes(std::span(lines.data(), lines.size())) ==
            static_cast<std::streamsize>(lines.size()) ? count : 0;
    }

    std::streamsize write_bytes(std::span<const char> bytes) {
        auto remaining = bytes;
        while (!remaining.empty()) {
            const auto chunk = static_cast<DWORD>(std::min<std::size_t>(
                remaining.size(), std::numeric_limits<DWORD>::max()));
            DWORD written = 0;
            if (!WriteFile(handle_, remaining.data(), chunk, &written, nullptr) || written == 0) break;
            remaining = remaining.subspan(written);
        }
        return static_cast<std::streamsize>(bytes.size() - remaining.size());
    }

    int_type overflow(int_type value) override {
        if (traits_type::eq_int_type(value, traits_type::eof())) return traits_type::not_eof(value);
        const char byte = traits_type::to_char_type(value);
        return xsputn(&byte, 1) == 1 ? value : traits_type::eof();
    }

    int sync() override {
        std::fflush(stdout);
        return 0;
    }

    HANDLE handle_ = INVALID_HANDLE_VALUE;
    bool is_console_ = false;
    char previous_byte_ = 0;
};

bool usable_output_handle(HANDLE handle) {
    if (handle == nullptr || handle == INVALID_HANDLE_VALUE) return false;
    SetLastError(NO_ERROR);
    return GetFileType(handle) != FILE_TYPE_UNKNOWN || GetLastError() == NO_ERROR;
}

class WindowsOutput final {
public:
    WindowsOutput() {
        // The handles the parent gave us come first: a batch file's `> out.txt 2>&1` (the XOI kit reads the game's
        // output from such files), a pipe, or its console. Attaching to the parent console replaces the process's
        // standard handles with the console's, so a redirected run attached first lost everything written through
        // std::cout and std::cerr (Lua's print, on the C runtime's stdout, still reached the file) — the kit's
        // training step failed with an empty out.txt and no word of why. Only a handle that is not usable (Explorer
        // gives none; a terminal gives a GUI program none either) is taken from the parent console, when there is one.
        // A redirected run still attaches, keeping its own handles: a process attached to a console ends when that
        // console's window is closed, and without it closing the kit's windows (spsa.bat's, hoc-sau.bat's) left their
        // games running in the background to the end of the round.
        HANDLE out = GetStdHandle(STD_OUTPUT_HANDLE);
        HANDLE err = GetStdHandle(STD_ERROR_HANDLE);
        const bool out_usable = usable_output_handle(out);
        const bool err_usable = usable_output_handle(err);
        if (AttachConsole(ATTACH_PARENT_PROCESS)) {
            if (out_usable) SetStdHandle(STD_OUTPUT_HANDLE, out); else out = GetStdHandle(STD_OUTPUT_HANDLE);
            if (err_usable) SetStdHandle(STD_ERROR_HANDLE, err); else err = GetStdHandle(STD_ERROR_HANDLE);
        }
        if (usable_output_handle(out)) {
            out_.set_handle(out);
            previous_out_ = std::cout.rdbuf(&out_);
        }
        if (usable_output_handle(err)) {
            err_.set_handle(err);
            previous_err_ = std::cerr.rdbuf(&err_);
        }
    }

    ~WindowsOutput() {
        if (previous_err_) {
            std::cerr.flush();
            std::cerr.rdbuf(previous_err_);
        }
        if (previous_out_) {
            std::cout.flush();
            std::cout.rdbuf(previous_out_);
        }
    }

    bool has_error_output() const { return previous_err_ != nullptr; }

private:
    WindowsOutputBuffer out_;
    WindowsOutputBuffer err_;
    std::streambuf* previous_out_ = nullptr;
    std::streambuf* previous_err_ = nullptr;
};

void show_startup_error(const std::string& message) {
    SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR, "OpenLF2", message.c_str(), nullptr);
}
}
#endif

static int run_main(int count, char** values) {
#ifdef OPENLF2_GUI_SUBSYSTEM
    WindowsOutput windows_output;
#endif
    try {
#ifdef __SWITCH__
        // The NRO embeds scripts in RomFS and stores settings/installer on SD.
        if (R_FAILED(romfsInit())) {
            std::cerr << "Could not mount bundled scripts\n";
            return 1;
        }
        struct SwitchServices {
            bool network = false;
            ~SwitchServices() {
                if (network) socketExit();
                romfsExit();
            }
        } services;
        // libnx normally mounts SD before main. A second mount fails because the device
        // already exists; libnx also unmounts it after main returns.
        if (!fsdevGetDeviceFileSystem("sdmc") && R_FAILED(fsdevMountSdmc())) {
            std::cerr << "Could not mount SD card\n";
            return 1;
        }
        services.network = R_SUCCEEDED(socketInitializeDefault());
#endif
        std::vector<std::string> owned;
        // Homebrew launchers may call main with argc=0 and no argv. A subspan(1)
        // on an empty span is invalid and made the Switch build read arbitrary memory.
        if (count > 1 && values != nullptr) {
            const std::span<char*> arguments(values, static_cast<std::size_t>(count));
            for (const auto argument : arguments.subspan(1)) owned.emplace_back(argument);
        }
#ifdef __ANDROID__
        // Use the app's files directory supplied by OpenLF2Activity. SDL's Android internal
        // storage path is not safely readable here.
        if (owned.empty()) {
            std::cerr << "OpenLF2Activity did not supply the internal storage path\n";
            return 1;
        }
        const std::filesystem::path base(owned.front());
        owned.erase(owned.begin());
#elif defined(__SWITCH__)
        const std::filesystem::path base = "romfs:/";
#elif defined(__EMSCRIPTEN__)
        const std::filesystem::path base = "/";
#else
        const auto* base_cstr = SDL_GetBasePath();
        if (base_cstr == nullptr) {
            const std::string error = SDL_GetError();
            std::cerr << error << '\n';
#ifdef OPENLF2_GUI_SUBSYSTEM
            if (!windows_output.has_error_output()) show_startup_error(error);
#endif
            return 1;
        }
        // SDL returns UTF-8; the native narrow-path constructor uses the Windows
        // code page and can point at a different folder when its name is Unicode.
        const std::filesystem::path base(reinterpret_cast<const char8_t*>(base_cstr));
#endif
        const int result = openlf2::run_application(owned, base);
#ifdef OPENLF2_GUI_SUBSYSTEM
        if (result != 0 && !windows_output.has_error_output()) {
            show_startup_error("OpenLF2 could not start. Run openlf2.exe from a terminal for details.");
        }
#endif
        return result;
    } catch (const std::exception& error) {
        std::cerr << "Startup failure: " << error.what() << '\n';
#ifdef OPENLF2_GUI_SUBSYSTEM
        if (!windows_output.has_error_output()) {
            show_startup_error(std::string("Startup failure: ") + error.what());
        }
#endif
        return 1;
    }
}

// C ABI entry point and argv pointers remain confined to the platform boundary.
int main(int count, char** values) {
    const int result = run_main(count, values);
#ifdef SDL_PLATFORM_IOS
    // SDL keeps UIKit's event loop alive after SDL_main returns. All game resources
    // and entry-point locals have been released; finish the process explicitly.
    std::exit(result);
#else
    return result;
#endif
}
