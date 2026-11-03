// SPDX-License-Identifier: MIT
// Copyright (c) 2026 OpenLF2 contributors

#pragma once
#include "openlf2/ports/compression.hpp"
#include "openlf2/ports/resources.hpp"
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <string_view>

namespace openlf2 {
// A game pack (OpenLF2 extension): a ZIP file holding a whole LF2 game folder, such as a mod
// distributed with its own executable, data, sprite, bgm and bg folders. It stands in for the
// original installer. Paths match like the installer's (case-insensitive, either slash) from the
// game folder: the one holding data/data.txt nearest the top of the ZIP file. The game's executable
// is its lf2.exe, or else its only .exe (the largest when there are several: mods keep their
// pictures in it). Entries are read from the file on demand.
class PackArchive final : public ResourceSource {
public:
    static Result<std::unique_ptr<PackArchive>> open(const std::filesystem::path& path,
                                                     const Decompressor& decompressor);
    Result<Bytes> read(std::string_view path) const override;
    [[nodiscard]] std::size_t file_count() const { return entries_.size(); }
    // The pack's own name for lf2.exe (for messages).
    [[nodiscard]] const std::string& executable_name() const { return executable_; }
private:
    struct Entry {
        std::uint32_t header_offset;
        std::uint32_t compressed_size;
        std::uint32_t size;
        Compression method;
    };
    PackArchive(const std::filesystem::path& path, const Decompressor& decompressor);
    Result<void> index();
    const Decompressor& decompressor_;
    std::map<std::string, Entry, std::less<>> entries_;
    std::string executable_;
    std::uintmax_t file_size_ = 0;
    mutable std::mutex mutex_;
    mutable std::ifstream file_;
};

// A game folder (OpenLF2 extension): an LF2 game folder on disk, such as a mod as its author shares it, played like a
// game pack: from the folder holding data/data.txt nearest the top, paths matching the same way. OpenLF2's own program
// may lie in it (a mod published with OpenLF2), so its executable is the one with LF2's pictures in it: lf2.exe, else
// the largest .exe at the top that has them; without one, lf2.exe or the largest other than OpenLF2's (whose missing
// pictures the caller reports). Files are read on demand.
class PackFolder final : public ResourceSource {
public:
    static Result<std::unique_ptr<PackFolder>> open(const std::filesystem::path& path);
    Result<Bytes> read(std::string_view path) const override;
    [[nodiscard]] std::size_t file_count() const { return files_.size(); }
    // The folder's own name for lf2.exe (for messages).
    [[nodiscard]] const std::string& executable_name() const { return executable_; }
private:
    PackFolder() = default;
    Result<void> index(const std::filesystem::path& path);
    std::map<std::string, std::filesystem::path, std::less<>> files_;
    std::string executable_;
};
// Whether `directory` is an LF2 game folder: data/data.txt in it, in any case.
bool is_game_folder(const std::filesystem::path& directory);
}
