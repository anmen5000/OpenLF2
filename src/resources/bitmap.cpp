// SPDX-License-Identifier: MIT
// Copyright (c) 2026 OpenLF2 contributors

#include "openlf2/resources/bitmap.hpp"
#include "openlf2/core/binary.hpp"
#include <optional>
#include <string>

namespace openlf2::bitmap {
namespace {
constexpr std::size_t header_size = 40;
constexpr std::size_t core_header_size = 12;
constexpr std::uint32_t uncompressed = 0;
constexpr std::uint32_t run_length_8 = 1;
constexpr std::uint32_t run_length_4 = 2;
constexpr std::uint32_t bit_fields = 3;

// BITMAPINFOHEADER (40 bytes) and the later headers that extend it, the same in their first 40 bytes: V2 and V3
// (52, 56: the colour masks inside the header), V4 (108: and a colour space) and V5 (124: and a colour profile).
// Windows reads them all; GIMP and Photoshop write V4 or V5 (the mod LF2 Convergence has six such pictures: some
// fighters' faces, a weapon's mirrored sheet). The output always has the 40-byte header.
bool known_header(std::uint32_t size) { return size == 40 || size == 52 || size == 56 || size == 108 || size == 124; }
// Where the palette starts: after the header, and after BI_BITFIELDS' three masks when the header is 40 bytes
// (the later headers hold them, at the same place).
std::size_t masks_end(std::uint32_t info_size, std::uint32_t compression) {
    return info_size + (compression == bit_fields && info_size == header_size ? 12 : 0);
}

void append_u32(Bytes& output, std::uint32_t value) {
    for (int shift = 0; shift < 32; shift += 8) output.push_back(static_cast<char>((value >> shift) & 255));
}
void store_u32(Bytes& output, std::size_t offset, std::uint32_t value) {
    for (std::size_t byte = 0; byte < 4; ++byte) {
        output[offset + byte] = static_cast<char>((value >> (byte * 8)) & 255);
    }
}

// One channel of a 16-bit pixel, by its mask, scaled to 0-255.
std::uint8_t channel(std::uint32_t pixel, std::uint32_t mask) {
    if (mask == 0) return 0;
    int shift = 0;
    while (((mask >> shift) & 1U) == 0) ++shift;
    const std::uint32_t top = mask >> shift;
    const std::uint32_t value = (pixel & mask) >> shift;
    return static_cast<std::uint8_t>((std::uint64_t{value} * 255 + top / 2) / top);
}

// 16-bit pixels (5-5-5, or the masks of BI_BITFIELDS such as 5-6-5) become 24-bit ones, which every
// consumer reads: Windows draws such a picture as it stands (the One Piece mod OPLoS 2.1X has two among its
// background layers, bg/sys/kf/land3.bmp and land4.bmp). Rows keep their order and the header its height.
Bytes convert_16(std::span<const char> dib, std::uint32_t compression, std::optional<std::size_t> pixel_offset) {
    const BinaryView header(dib);
    std::uint32_t masks[3] = {0x7c00U, 0x03e0U, 0x001fU};
    std::size_t palette_end = masks_end(header.u32(0), compression);
    if (compression == bit_fields) {
        for (std::size_t index = 0; index < 3; ++index) masks[index] = header.u32(header_size + index * 4);
        for (const auto mask : masks) {
            if (mask == 0 || mask > 0xffffU) throw FormatError("unsupported 16-bit bitmap masks");
        }
    } else if (compression != uncompressed) {
        throw FormatError("unsupported bitmap compression");
    }
    // (A colour table may follow, as a hint for palette displays; the pixels do not use it.)
    const auto colors = header.u32(32);
    if (colors > 256) throw FormatError("oversized bitmap palette");
    palette_end += std::size_t{colors} * 4;
    header.slice(0, palette_end);
    const auto width = header.u32(4);
    const auto height_bits = header.u32(8);
    const bool top_down = height_bits >= 0x80000000U;
    const std::uint64_t height = top_down ? std::uint64_t{0x100000000ULL} - height_bits : height_bits;
    if (width == 0 || width > 8192 || height == 0 || height > 8192) {
        throw FormatError("bitmap dimensions exceed limits");
    }
    const auto rows = static_cast<std::size_t>(height);
    const auto stride = static_cast<std::size_t>(((std::uint64_t{width} * 16 + 31) / 32) * 4);
    const auto output_stride = static_cast<std::size_t>(((std::uint64_t{width} * 24 + 31) / 32) * 4);
    const auto start = pixel_offset.value_or(palette_end);
    if (start < palette_end || start > dib.size()) throw FormatError("bitmap pixels overlap header");
    const BinaryView stored(header.slice(start, stride * rows));

    Bytes output{'B', 'M'};
    append_u32(output, static_cast<std::uint32_t>(14 + header_size + output_stride * rows));
    append_u32(output, 0);
    append_u32(output, static_cast<std::uint32_t>(14 + header_size));
    const auto info = header.slice(0, header_size);
    output.insert(output.end(), info.begin(), info.end());
    store_u32(output, 14, header_size);
    output[14 + 14] = 24;
    output[14 + 15] = 0;
    store_u32(output, 14 + 16, uncompressed);
    store_u32(output, 14 + 20, static_cast<std::uint32_t>(output_stride * rows));
    store_u32(output, 14 + 32, 0);
    store_u32(output, 14 + 36, 0);
    const auto pixels_at = output.size();
    output.resize(pixels_at + output_stride * rows, '\0');
    for (std::size_t row = 0; row < rows; ++row) {
        for (std::size_t x = 0; x < width; ++x) {
            const std::uint32_t pixel = stored.u16(row * stride + x * 2);
            const auto at = pixels_at + row * output_stride + x * 3;
            output[at] = static_cast<char>(channel(pixel, masks[2]));
            output[at + 1] = static_cast<char>(channel(pixel, masks[1]));
            output[at + 2] = static_cast<char>(channel(pixel, masks[0]));
        }
    }
    return output;
}

// BITMAPCOREHEADER (12 bytes: 16-bit width and height, planes, bits; colours as three-byte RGBTRIPLEs, no
// compression): the bitmap of OS/2 and Windows 2, which Windows still reads. KT-LF2 v3.0's program keeps its menu
// backgrounds this way (MENU_BACK1-13, MENU_CLIP, MENU_WAIT: 8-bit). Made a BITMAPINFOHEADER bitmap, the colours
// four-byte RGBQUADs, the rows as they are.
Bytes convert_core(std::span<const char> dib, std::optional<std::size_t> pixel_offset) {
    const BinaryView header(dib);
    const std::uint32_t width = header.u16(4);
    const std::uint32_t height = header.u16(6);
    if (header.u16(8) != 1) throw FormatError("only one-plane bitmaps are supported");
    const auto bits = header.u16(10);
    if (bits != 1 && bits != 4 && bits != 8 && bits != 24) throw FormatError("unsupported bitmap bit depth");
    if (width == 0 || width > 8192 || height == 0 || height > 8192) {
        throw FormatError("bitmap dimensions exceed limits");
    }
    const std::size_t colors = bits <= 8 ? (std::size_t{1} << bits) : 0;
    const std::size_t palette_end = core_header_size + colors * 3;
    const auto palette = header.slice(core_header_size, colors * 3);
    const auto stride = static_cast<std::size_t>(((std::uint64_t{width} * bits + 31) / 32) * 4);
    const auto pixel_bytes = stride * height;
    const auto start = pixel_offset.value_or(palette_end);
    if (start < palette_end || start > dib.size()) throw FormatError("bitmap pixels overlap header");
    const auto stored = header.slice(start, pixel_bytes);

    const auto output_palette_end = header_size + colors * 4;
    Bytes output{'B', 'M'};
    append_u32(output, static_cast<std::uint32_t>(14 + output_palette_end + pixel_bytes));
    append_u32(output, 0);
    append_u32(output, static_cast<std::uint32_t>(14 + output_palette_end));
    append_u32(output, header_size);
    append_u32(output, width);
    append_u32(output, height);
    output.push_back(1);
    output.push_back(0);
    output.push_back(static_cast<char>(bits));
    output.push_back(0);
    append_u32(output, uncompressed);
    append_u32(output, static_cast<std::uint32_t>(pixel_bytes));
    append_u32(output, 0);
    append_u32(output, 0);
    append_u32(output, static_cast<std::uint32_t>(colors));
    append_u32(output, 0);
    for (std::size_t index = 0; index < colors; ++index) {
        output.insert(output.end(), palette.begin() + static_cast<std::ptrdiff_t>(index * 3),
                      palette.begin() + static_cast<std::ptrdiff_t>(index * 3 + 3));
        output.push_back(0);
    }
    output.insert(output.end(), stored.begin(), stored.end());
    return output;
}

// Expands bottom-up RLE8. Pixels skipped by delta or line escapes stay index 0; a stream cut short (the Hell mod's
// sprite/sys/ad0.bmp holds a third of its picture) gives what it holds, the rest index 0, as Windows shows it.
Bytes expand_rle8(const BinaryView& stream, std::size_t stream_size, std::size_t width,
                  std::size_t height, std::size_t stride) {
    Bytes pixels(stride * height, '\0');
    std::size_t x = 0;
    std::size_t y = 0;
    std::size_t position = 0;
    const auto write_span = [&](std::size_t count) {
        if (y >= height || count > width - x) throw FormatError("RLE8 pixels outside the bitmap");
    };
    for (;;) {
        if (stream_size - position < 2) return pixels;
        const std::size_t count = stream.u8(position);
        const auto value = stream.u8(position + 1);
        position += 2;
        if (count != 0) {
            write_span(count);
            for (std::size_t index = 0; index < count; ++index) {
                pixels[y * stride + x++] = static_cast<char>(value);
            }
        } else if (value == 0) {
            x = 0;
            ++y;
        } else if (value == 1) {
            return pixels;
        } else if (value == 2) {
            if (stream_size - position < 2) throw FormatError("truncated RLE8 delta");
            x += stream.u8(position);
            y += stream.u8(position + 1);
            position += 2;
            if (x > width || y > height) throw FormatError("RLE8 delta outside the bitmap");
        } else {
            const std::size_t literal = value;
            const auto padded = literal + (literal & 1);
            write_span(literal);
            if (stream_size - position < padded) {
                for (std::size_t index = 0; index < literal && position + index < stream_size; ++index) {
                    pixels[y * stride + x++] = static_cast<char>(stream.u8(position + index));
                }
                return pixels;
            }
            for (std::size_t index = 0; index < literal; ++index) {
                pixels[y * stride + x++] = static_cast<char>(stream.u8(position + index));
            }
            position += padded;
        }
    }
}

// Expands bottom-up RLE4 (4-bit pixels, two to a byte: Windows reads it, and a mod's effect sheets may be saved so —
// Felix's blood in LF2 AI VS and Stage Challenge). Encoded runs alternate the two nibbles of the value; an absolute
// run's nibbles are packed two to a byte and padded to a word. Pixels skipped by delta or line escapes stay index 0.
Bytes expand_rle4(const BinaryView& stream, std::size_t stream_size, std::size_t width,
                  std::size_t height, std::size_t stride) {
    Bytes pixels(stride * height, '\0');
    std::size_t x = 0;
    std::size_t y = 0;
    std::size_t position = 0;
    const auto write_span = [&](std::size_t count) {
        if (y >= height || count > width - x) throw FormatError("RLE4 pixels outside the bitmap");
    };
    const auto put = [&](std::uint8_t index) {
        auto& byte = pixels[y * stride + x / 2];
        if (x % 2 == 0) byte = static_cast<char>((static_cast<unsigned char>(byte) & 0x0f) | (index << 4));
        else byte = static_cast<char>((static_cast<unsigned char>(byte) & 0xf0) | (index & 0x0f));
        ++x;
    };
    for (;;) {
        if (stream_size - position < 2) return pixels;
        const std::size_t count = stream.u8(position);
        const auto value = stream.u8(position + 1);
        position += 2;
        if (count != 0) {
            write_span(count);
            for (std::size_t index = 0; index < count; ++index) {
                put(static_cast<std::uint8_t>(index % 2 == 0 ? value >> 4 : value & 0x0f));
            }
        } else if (value == 0) {
            x = 0;
            ++y;
        } else if (value == 1) {
            return pixels;
        } else if (value == 2) {
            if (stream_size - position < 2) throw FormatError("truncated RLE4 delta");
            x += stream.u8(position);
            y += stream.u8(position + 1);
            position += 2;
            if (x > width || y > height) throw FormatError("RLE4 delta outside the bitmap");
        } else {
            const std::size_t literal = value;
            const auto bytes = (literal + 1) / 2;
            const auto padded = bytes + (bytes & 1);
            write_span(literal);
            if (stream_size - position < padded) {
                for (std::size_t index = 0; index < literal && position + index / 2 < stream_size; ++index) {
                    const auto byte = stream.u8(position + index / 2);
                    put(static_cast<std::uint8_t>(index % 2 == 0 ? byte >> 4 : byte & 0x0f));
                }
                return pixels;
            }
            for (std::size_t index = 0; index < literal; ++index) {
                const auto byte = stream.u8(position + index / 2);
                put(static_cast<std::uint8_t>(index % 2 == 0 ? byte >> 4 : byte & 0x0f));
            }
            position += padded;
        }
    }
}

Bytes convert(std::span<const char> dib, std::optional<std::size_t> pixel_offset) {
    const BinaryView header(dib);
    const auto info_size = header.u32(0);
    if (info_size == core_header_size) return convert_core(dib, pixel_offset);
    if (!known_header(info_size)) {
        throw FormatError("unsupported bitmap header of " + std::to_string(info_size) + " bytes");
    }
    if (header.u16(12) != 1) throw FormatError("only one-plane bitmaps are supported");
    header.slice(0, info_size);
    const auto bits = header.u16(14);
    auto compression = header.u32(16);
    if (bits == 16) return convert_16(dib, compression, pixel_offset);
    if (bits != 1 && bits != 4 && bits != 8 && bits != 24 && bits != 32) {
        throw FormatError("unsupported bitmap bit depth");
    }
    const auto palette_start = masks_end(info_size, compression);
    // 32-bit pixels with masks (as V4 and V5 headers often have them) that are plain blue-green-red bytes.
    if (bits == 32 && compression == bit_fields) {
        if (header.u32(40) != 0x00ff0000U || header.u32(44) != 0x0000ff00U || header.u32(48) != 0x000000ffU) {
            throw FormatError("unsupported 32-bit bitmap masks");
        }
        compression = uncompressed;
    }
    const bool run_length = (compression == run_length_8 && bits == 8) || (compression == run_length_4 && bits == 4);
    if (compression != uncompressed && !run_length) throw FormatError("unsupported bitmap compression");
    const auto colors = header.u32(32) != 0 ? header.u32(32) : (bits <= 8 ? (1U << bits) : 0U);
    if (colors > 256) throw FormatError("oversized bitmap palette");
    const std::size_t palette_end = palette_start + std::size_t{colors} * 4;
    header.slice(0, palette_end);
    const auto width = header.u32(4);
    const auto height_bits = header.u32(8);
    const bool top_down = height_bits >= 0x80000000U;
    const std::uint64_t height = top_down ? std::uint64_t{0x100000000ULL} - height_bits : height_bits;
    if (width == 0 || width > 8192 || height == 0 || height > 8192) {
        throw FormatError("bitmap dimensions exceed limits");
    }
    if (top_down && run_length) throw FormatError("top-down run-length bitmap");
    const auto stride = static_cast<std::size_t>(((std::uint64_t{width} * bits + 31) / 32) * 4);
    const auto pixel_bytes = stride * static_cast<std::size_t>(height);
    const auto start = pixel_offset.value_or(palette_end);
    if (start < palette_end || start > dib.size()) throw FormatError("bitmap pixels overlap header");

    Bytes pixels;
    if (compression == run_length_8) {
        const auto stream = header.slice(start, dib.size() - start);
        pixels = expand_rle8(BinaryView(stream), stream.size(), width, static_cast<std::size_t>(height), stride);
    } else if (compression == run_length_4) {
        const auto stream = header.slice(start, dib.size() - start);
        pixels = expand_rle4(BinaryView(stream), stream.size(), width, static_cast<std::size_t>(height), stride);
    } else {
        const auto stored = header.slice(start, pixel_bytes);
        pixels.assign(stored.begin(), stored.end());
    }

    // Legacy images can reference undeclared 8-bit palette entries; fill those with black.
    const auto output_palette_end = bits == 8 ? header_size + 256 * 4 : header_size + std::size_t{colors} * 4;
    Bytes output{'B', 'M'};
    append_u32(output, static_cast<std::uint32_t>(14 + output_palette_end + pixels.size()));
    append_u32(output, 0);
    append_u32(output, static_cast<std::uint32_t>(14 + output_palette_end));
    const auto info = header.slice(0, header_size);
    output.insert(output.end(), info.begin(), info.end());
    const auto palette = header.slice(palette_start, std::size_t{colors} * 4);
    output.insert(output.end(), palette.begin(), palette.end());
    output.resize(14 + output_palette_end, '\0');
    store_u32(output, 14, header_size);
    if (bits == 8 && colors < 256) store_u32(output, 14 + 32, 256);
    store_u32(output, 14 + 16, uncompressed);
    store_u32(output, 14 + 20, static_cast<std::uint32_t>(pixels.size()));
    output.insert(output.end(), pixels.begin(), pixels.end());
    return output;
}
}

Result<Bytes> from_dib(std::span<const char> dib) {
    try { return convert(dib, std::nullopt); }
    catch (const FormatError& error) { return fail(ErrorCode::format, error.what()); }
}

Result<Bytes> from_file(std::span<const char> file) {
    try {
        const BinaryView view(file);
        if (view.text(0, 2) != "BM") throw FormatError("missing BMP signature");
        const std::size_t pixels = view.u32(10);
        if (pixels < 14) throw FormatError("bitmap pixels overlap file header");
        return convert(view.slice(14, file.size() - 14), pixels - 14);
    } catch (const FormatError& error) { return fail(ErrorCode::format, error.what()); }
}
}
