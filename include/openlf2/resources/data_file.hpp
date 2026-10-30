// SPDX-License-Identifier: MIT
// Copyright (c) 2026 OpenLF2 contributors

#pragma once
#include "openlf2/core/result.hpp"
#include "openlf2/ports/resources.hpp"
#include <span>
#include <string_view>

namespace openlf2 {
// What reading a file in text mode with Microsoft's C library gives: every CR LF pair becomes LF and
// the file ends at its first Ctrl-Z (0x1A).
Bytes read_text_mode(std::span<const char> raw);
// Reverses the original data-file encoding (123-byte prefix, rotating subtraction key).
Result<Bytes> decode_data_file(std::span<const char> encoded);
// Reads an original text description like the original game does: in text mode, then names ending
// in "dat" (any case) are decoded. Rejects a NUL byte, which would end the original's token early.
Result<Bytes> read_data_text(const ResourceSource& resources, std::string_view path, std::size_t limit);
}
