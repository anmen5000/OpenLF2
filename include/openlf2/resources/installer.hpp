// SPDX-License-Identifier: MIT
// Copyright (c) 2026 OpenLF2 contributors

#pragma once
#include "openlf2/ports/resources.hpp"
#include "openlf2/ports/compression.hpp"
#include <filesystem>
#include <array>
#include <map>
#include <span>
#include <string>
#include <string_view>
#include <vector>

namespace openlf2 {
// Supported LF2 v2.0a packages. Downloads continue to use the first variant.
inline constexpr std::string_view installer_name = "LF2_v2.0a.exe";
inline constexpr std::size_t installer_size = 29'586'263;
inline constexpr std::string_view alternate_installer_name = "lf2_v20a_Setup.exe";
inline constexpr std::size_t alternate_installer_size = 31'904'750;
inline constexpr std::array installer_names{installer_name, alternate_installer_name};
inline constexpr std::size_t installer_max_size = alternate_installer_size;
// Succeeds when `bytes` match a supported installer (size and SHA-256).
Result<void> identify_installer(std::span<const char> bytes);
class InstallerArchive final : public ResourceSource {
public:
    static Result<std::unique_ptr<InstallerArchive>> open(const std::filesystem::path& path,
                                                         const Decompressor& decompressor);
    InstallerArchive(Bytes bytes, const Decompressor& decompressor);
    Result<Bytes> read(std::string_view path) const override;
    [[nodiscard]] std::size_t file_count() const { return entries_.size(); }
    // Normalized virtual paths in lexical order.
    [[nodiscard]] std::vector<std::string> paths() const {
        std::vector<std::string> names;
        names.reserve(entries_.size());
        for (const auto& entry : entries_) names.push_back(entry.first);
        return names;
    }
private:
    struct Entry {
        std::size_t offset;
        std::size_t compressed_size;
        std::size_t decoded_size;
        Compression method;
    };
    Result<void> index();
    Result<void> unwrap_nsis();
    Result<void> index_nsis();
    Bytes bytes_;
    const Decompressor& decompressor_;
    std::map<std::string, Entry, std::less<>> entries_;
};
Result<Bytes> bitmap_resource(std::span<const char> executable, std::string_view name);
// Initialized data of a PE32 executable at a virtual address (e.g. the original game's recording key).
Result<Bytes> executable_data(std::span<const char> executable, std::uint32_t address, std::size_t size);
// The bytes of a PE32 executable's first code section as the file holds them, past its virtual size too (where a
// mod's tool may have added routines of its own).
Result<Bytes> executable_code(std::span<const char> executable);
}
