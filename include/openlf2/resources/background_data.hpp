// SPDX-License-Identifier: MIT
// Copyright (c) 2026 OpenLF2 contributors

#pragma once

#include "openlf2/core/result.hpp"
#include "openlf2/core/script_value.hpp"
#include "openlf2/ports/resources.hpp"
#include <array>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace openlf2::background_data {
// The original reads at most 30 layers; a mod's own program may allow more (Naruto: The Setting Dawn 2.6's Sand
// Country has 37), and nothing here depends on the count, so the limit only guards against a runaway file.
inline constexpr std::size_t max_layers = 200;

struct Layer {
    std::string path;              // loaded for every layer, including filled ones
    std::int32_t transparency = 0; // non-zero: source color key
    std::int32_t width = 0;        // parallax width; fill width for colored layers
    std::int32_t x = 0;
    std::int32_t y = 0;
    std::int32_t height = 0;       // fill height
    std::int32_t color = 0;        // 0x00RRGGBB fill before the painter's remap; 0 = bitmap
    std::int32_t loop = 0;         // repeat step; 0 draws once
    std::int32_t cc = 0;           // animation period; 0 = always visible
    std::int32_t c1 = 0;           // first visible counter value
    std::int32_t c2 = 0;           // last visible counter value
};

// Values the original never resets are absent until the file sets them.
struct Background {
    std::optional<std::string> name; // display form: 29 characters, underscores as spaces
    std::optional<std::int32_t> width;
    std::array<std::optional<std::int32_t>, 2> zboundary;
    std::array<std::int32_t, 2> perspective{};
    std::optional<std::string> shadow;
    std::array<std::optional<std::int32_t>, 2> shadow_size;
    std::vector<Layer> layers;
    std::int32_t token_checksum = 0;
    std::vector<std::string> diagnostics;
};

// `rect:` conversion of an RGB565 value, biased by +0x070707.
std::int32_t convert_rgb565(std::int32_t value);
Result<Background> parse(std::string_view text);
Result<Background> load(const ResourceSource& resources, std::string_view path);
// Script-facing table.
ScriptValue to_script_value(const Background& background);
}
