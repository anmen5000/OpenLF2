// SPDX-License-Identifier: MIT
// Copyright (c) 2026 OpenLF2 contributors

#include "openlf2/resources/data_file.hpp"
#include <string>
#include <string_view>

namespace openlf2 {
Bytes read_text_mode(std::span<const char> raw) {
    Bytes text;
    text.reserve(raw.size());
    for (std::size_t index = 0; index < raw.size(); ++index) {
        const char character = raw[index];
        if (character == '\x1a') break;
        if (character == '\r' && index + 1 < raw.size() && raw[index + 1] == '\n') continue;
        text.push_back(character);
    }
    return text;
}

Result<Bytes> decode_data_file(std::span<const char> encoded) {
    constexpr std::string_view key = "SiuHungIsAGoodBearBecauseHeIsVeryGood";
    constexpr std::size_t prefix = 123;
    if (encoded.size() < prefix) return fail(ErrorCode::format, "data file shorter than prefix");
    Bytes result;
    result.reserve(encoded.size() - prefix);
    for (std::size_t index = prefix; index < encoded.size(); ++index) {
        const auto byte = static_cast<unsigned char>(encoded[index]);
        const auto mask = static_cast<unsigned char>(key[index % key.size()]);
        result.push_back(static_cast<char>((static_cast<unsigned int>(byte) + 256 - mask) & 255));
    }
    return result;
}

Result<Bytes> read_data_text(const ResourceSource& resources, std::string_view path, std::size_t limit) {
    auto bytes = resources.read(path);
    if (!bytes) return std::unexpected(bytes.error());
    if (bytes->size() > limit) return fail(ErrorCode::limit, std::string(path) + ": exceeds size limit");
    // The original opens its data files in text mode, so it decodes what that reading leaves: a mod
    // whose encoded bytes hold CR LF pairs or a Ctrl-Z (Data Changer saves files ending with either)
    // decodes here as there, to the same tokens and the same data checksum.
    bytes = read_text_mode(*bytes);
    const auto encoded = path.size() >= 3 && (path[path.size() - 3] | 0x20) == 'd' &&
                         (path[path.size() - 2] | 0x20) == 'a' && (path[path.size() - 1] | 0x20) == 't';
    if (encoded) {
        auto decoded = decode_data_file(*bytes);
        if (!decoded) return std::unexpected(decoded.error());
        bytes = std::move(*decoded);
    }
    // A decoded Ctrl-Z is an ordinary character to the original's token reading; a NUL would end
    // its token early, which this parser does not reproduce.
    for (const char character : *bytes) {
        if (character == '\0') return fail(ErrorCode::unsupported, std::string(path) + ": NUL byte in data text");
    }
    return bytes;
}
}
