// SPDX-License-Identifier: MIT
// Copyright (c) 2026 OpenLF2 contributors

#pragma once
#include "openlf2/core/result.hpp"
#include <span>

// Original bitmaps are BI_RLE8.
namespace openlf2::bitmap {
// A BITMAPINFOHEADER DIB (or one with a V2-V5 header) whose pixels follow its palette (PE resource layout) to a
// BMP file with uncompressed pixels and a BITMAPINFOHEADER. Accepts uncompressed 1/4/8/24/32-bit, 16-bit (made
// 24-bit) and 8-bit RLE8 input.
Result<Bytes> from_dib(std::span<const char> dib);
// A BMP file with the same support to a BMP file with uncompressed pixels.
Result<Bytes> from_file(std::span<const char> file);
}
