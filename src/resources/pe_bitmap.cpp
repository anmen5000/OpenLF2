// SPDX-License-Identifier: MIT
// Copyright (c) 2026 OpenLF2 contributors

#include "openlf2/resources/installer.hpp"
#include "openlf2/core/binary.hpp"
#include "openlf2/resources/bitmap.hpp"
#include <optional>

namespace openlf2 {
namespace {
class PeResources {
public:
    explicit PeResources(std::span<const char> bytes) : file_(bytes) {
        if (file_.text(0, 2) != "MZ") throw FormatError("not a PE executable");
        const std::size_t pe = file_.u32(0x3c);
        file_.slice(pe, 24);
        file_.slice(pe, 24 + std::size_t{file_.u16(pe + 20)});
        if (file_.text(pe, 4) != std::string("PE\0\0", 4) || file_.u16(pe + 24) != 0x10b ||
            file_.u16(pe + 20) < 120) throw FormatError("expected PE32 optional header");
        sections_ = pe + 24 + file_.u16(pe + 20);
        section_count_ = file_.u16(pe + 6);
        file_.slice(sections_, section_count_ * 40);
        image_base_ = file_.u32(pe + 24 + 28);
        const auto resource_rva = file_.u32(pe + 24 + 112);
        resource_size_ = file_.u32(pe + 24 + 116);
        root_ = file_offset(resource_rva, resource_size_);
    }
    // The DIB (header, palette, pixels) of a named bitmap resource.
    std::span<const char> bitmap(std::string_view requested) const {
        const auto type = child(0, 2, {});
        const auto name = child(type, std::nullopt, requested);
        const auto language = first_language(name);
        const BinaryView entry(resource_view(language, 16));
        const std::size_t size = entry.u32(4);
        return file_.slice(file_offset(entry.u32(0), size), size);
    }
    // Initialized data at a virtual address (backed by the file, not zero-filled BSS).
    std::span<const char> data(std::uint32_t address, std::size_t size) const {
        if (address < image_base_) throw FormatError("address below the image base");
        return file_.slice(file_offset(address - image_base_, size), size);
    }
private:
    std::size_t file_offset(std::uint32_t rva, std::size_t size) const {
        for (std::size_t index = 0; index < section_count_; ++index) {
            const auto section = sections_ + index * 40;
            const auto start = file_.u32(section + 12);
            const auto raw_size = file_.u32(section + 16);
            file_.slice(file_.u32(section + 20), raw_size);
            if (rva >= start && rva - start <= raw_size && size <= raw_size - (rva - start)) {
                const std::size_t offset = std::size_t{file_.u32(section + 20)} + (rva - start);
                file_.slice(offset, size);
                return offset;
            }
        }
        throw FormatError("resource RVA outside backed PE sections");
    }
    std::span<const char> resource_view(std::size_t offset, std::size_t size) const {
        if (offset > resource_size_ || size > resource_size_ - offset) {
            throw FormatError("resource directory offset outside section");
        }
        return file_.slice(root_ + offset, size);
    }
    std::size_t child(std::size_t directory, std::optional<std::uint32_t> id,
                      std::string_view name) const {
        const BinaryView header(resource_view(directory, 16));
        const std::size_t count = header.u16(12) + header.u16(14);
        const BinaryView entries(resource_view(directory + 16, count * 8));
        for (std::size_t index = 0; index < count; ++index) {
            const auto key = entries.u32(index * 8);
            bool matches = id && key == *id;
            if (!id && (key & 0x80000000U) != 0) {
                const std::size_t name_offset = key & 0x7fffffffU;
                const auto length = BinaryView(resource_view(name_offset, 2)).u16(0);
                const BinaryView letters(resource_view(name_offset + 2, std::size_t{length} * 2));
                matches = length == name.size();
                for (std::size_t letter = 0; matches && letter < length; ++letter) {
                    matches = letters.u16(letter * 2) == static_cast<unsigned char>(name[letter]);
                }
            }
            if (matches) {
                const auto target = entries.u32(index * 8 + 4);
                if ((target & 0x80000000U) == 0) throw FormatError("expected resource directory");
                return target & 0x7fffffffU;
            }
        }
        throw FormatError("named bitmap resource not found: " + std::string(name));
    }
    std::size_t first_language(std::size_t directory) const {
        const BinaryView header(resource_view(directory, 16));
        // The pinned binary uses one language per bitmap. Reject ambiguous variants.
        if (header.u16(12) != 0 || header.u16(14) != 1) throw FormatError("ambiguous bitmap language");
        const auto target = BinaryView(resource_view(directory + 16, 8)).u32(4);
        if ((target & 0x80000000U) != 0) throw FormatError("expected resource data entry");
        return target;
    }
    BinaryView file_;
    std::size_t sections_ = 0;
    std::size_t section_count_ = 0;
    std::uint32_t image_base_ = 0;
    std::size_t root_ = 0;
    std::size_t resource_size_ = 0;
};
}
Result<Bytes> executable_data(std::span<const char> executable, std::uint32_t address, std::size_t size) {
    if (executable.size() > 64 * 1024 * 1024) return fail(ErrorCode::limit, "PE file exceeds limit");
    try {
        const auto data = PeResources(executable).data(address, size);
        return Bytes(data.begin(), data.end());
    } catch (const FormatError& error) {
        return fail(ErrorCode::format, error.what());
    }
}
Result<Bytes> executable_code(std::span<const char> executable) {
    if (executable.size() > 64 * 1024 * 1024) return fail(ErrorCode::limit, "PE file exceeds limit");
    try {
        const BinaryView file(executable);
        if (file.text(0, 2) != "MZ") throw FormatError("not a PE executable");
        const std::size_t pe = file.u32(0x3c);
        if (file.text(pe, 4) != std::string("PE\0\0", 4)) throw FormatError("not a PE executable");
        const std::size_t sections = pe + 24 + std::size_t{file.u16(pe + 20)};
        const std::size_t count = file.u16(pe + 6);
        for (std::size_t index = 0; index < count; ++index) {
            const auto section = sections + index * 40;
            // IMAGE_SCN_CNT_CODE or IMAGE_SCN_MEM_EXECUTE.
            if ((file.u32(section + 36) & 0x20000020U) == 0) continue;
            const auto code = file.slice(file.u32(section + 20), file.u32(section + 16));
            return Bytes(code.begin(), code.end());
        }
        throw FormatError("no code section");
    } catch (const FormatError& error) {
        return fail(ErrorCode::format, error.what());
    }
}
Result<Bytes> bitmap_resource(std::span<const char> executable, std::string_view name) {
    if (executable.size() > 64 * 1024 * 1024) return fail(ErrorCode::limit, "PE file exceeds limit");
    std::span<const char> dib;
    try { dib = PeResources(executable).bitmap(name); }
    catch (const FormatError& error) { return fail(ErrorCode::format, error.what()); }
    auto converted = bitmap::from_dib(dib);
    if (!converted) converted.error().message = "pe/" + std::string(name) + ": " + converted.error().message;
    return converted;
}
}
