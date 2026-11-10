// SPDX-License-Identifier: MIT
// Copyright (c) 2026 OpenLF2 contributors

#include "openlf2/core/files.hpp"
#include <fstream>
#include <limits>

namespace openlf2 {
Result<Bytes> read_file(const std::filesystem::path& path, std::size_t limit) {
    std::ifstream file(path, std::ios::binary | std::ios::ate);
    if (!file) return fail(ErrorCode::io, "cannot open " + path.string());
    const auto end = file.tellg();
    if (end < 0 || static_cast<std::uintmax_t>(end) > limit ||
        static_cast<std::uintmax_t>(end) > static_cast<std::uintmax_t>(std::numeric_limits<std::streamsize>::max())) {
        return fail(ErrorCode::limit, "file size exceeds limit: " + path.string());
    }
    Bytes bytes(static_cast<std::size_t>(end));
    file.seekg(0);
    if (!file.read(bytes.data(), static_cast<std::streamsize>(bytes.size()))) {
        return fail(ErrorCode::io, "short read: " + path.string());
    }
    return bytes;
}
Result<std::string> virtual_path(std::string_view input) {
    if (input.empty() || input.size() > 512) return fail(ErrorCode::format, "invalid path length");
    std::string normalized;
    for (const char byte : input) {
        const auto character = static_cast<unsigned char>(byte);
        if (character < 32 || character >= 127 || character == ':') {
            return fail(ErrorCode::format, "virtual paths must use printable ASCII without colons");
        }
        const char value = character == '\\' ? '/' : static_cast<char>(character);
        // Separators in a row are one, as Windows reads them: a mod's data may name a picture "sprite\\Felix\f.bmp"
        // (LF2 AI VS and Stage Challenge's Felix), which the original opens.
        if (value == '/' && !normalized.empty() && normalized.back() == '/') continue;
        normalized += value >= 'A' && value <= 'Z' ? static_cast<char>(value + ('a' - 'A')) : value;
    }
    std::size_t start = 0;
    while (start <= normalized.size()) {
        const auto end = normalized.find('/', start);
        const auto part = normalized.substr(start, end == std::string::npos ? end : end - start);
        if (part.empty() || part == "." || part == "..") {
            return fail(ErrorCode::format, "unsafe virtual path: " + normalized);
        }
        if (end == std::string::npos) break;
        start = end + 1;
    }
    return normalized;
}
Result<std::filesystem::path> package_file(const std::filesystem::path& root,
                                           std::string_view relative) {
    auto normalized = virtual_path(relative);
    if (!normalized) return std::unexpected(normalized.error());
    // RomFS and Vita app0: paths are immutable package images. Their newlib canonical()
    // implementation does not resolve these paths, so use lexical normalization instead.
    const auto root_string = root.generic_string();
    if (root_string.starts_with("romfs:/") || root_string.starts_with("app0:")) {
        return (root / *normalized).lexically_normal();
    }
    // Package filenames use canonical lowercase ASCII, including on case-sensitive hosts.
    std::error_code error;
    const auto base = std::filesystem::canonical(root, error);
    if (error) return fail(ErrorCode::io, "invalid package root: " + root.string());
    const auto file = std::filesystem::canonical(base / *normalized, error);
    if (error) return fail(ErrorCode::io, "missing package file: " + *normalized);
    const auto local = file.lexically_relative(base);
    if (local.empty() || local.is_absolute() || *local.begin() == "..") {
        return fail(ErrorCode::format, "package symlink escapes root: " + *normalized);
    }
    return file;
}
Result<void> replace_file(const std::filesystem::path& directory, std::string_view name, std::span<const char> bytes) {
    std::error_code error;
    std::filesystem::create_directories(directory, error);
    if (error) return fail(ErrorCode::io, "cannot create " + directory.string() + ": " + error.message());
    const auto file = directory / std::string(name);
    auto temporary = file;
    temporary += ".tmp";
    {
        std::ofstream out(temporary, std::ios::binary | std::ios::trunc);
        if (!out) return fail(ErrorCode::io, "cannot write " + temporary.string());
        out.write(bytes.data(), static_cast<std::streamsize>(bytes.size()));
        out.flush();
        if (!out) return fail(ErrorCode::io, "cannot write " + temporary.string());
    }
    std::filesystem::rename(temporary, file, error);
    if (error) {
        std::filesystem::remove(temporary, error);
        return fail(ErrorCode::io, "cannot replace " + file.string());
    }
    return {};
}
}
