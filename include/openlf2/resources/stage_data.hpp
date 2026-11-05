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

namespace openlf2::stage_data {
inline constexpr std::size_t max_stages = 60;
inline constexpr std::size_t max_phases = 100;
inline constexpr std::size_t max_entries = 60;

enum class EntryKind : std::int32_t { normal = 0, soldier = 1, boss = 2 };

// Defaults are the values `id:` of a stage writes into all of its phases and entries.
struct Entry {
    std::int32_t id = -1;
    std::int32_t x = 500; // also set to bound + 80 by every later `bound:` of the phase
    std::int32_t hp = 500;
    std::int32_t times = 1; // `<soldier>` sets 50
    std::int32_t reserve = 0;
    std::int32_t join = 0;
    std::int32_t join_reserve = 0;
    std::int32_t act = 9;
    std::int32_t y = 0;
    double ratio = 0.0;
    EntryKind kind = EntryKind::normal;
    std::int32_t team = 0; // a mod's own `team:` (Naruto: The Setting Dawn 2.6): 1-4 fights on that side; 0 the enemies
};

struct Phase {
    std::int32_t bound = -1;
    std::string music;
    std::int32_t when_clear_goto_phase = -1;
    std::vector<Entry> entries; // entries opened by `id:`, in file order
};

struct Stage {
    std::vector<Phase> phases; // phase count as the original's +2000 field
};

// A mod whose stage.dat only lists its stages (Naruto: The Setting Dawn 2.6: `<stage_information> id: 0 name: 1:_Save_Gaara
// file: s\1\stage1.dat <stage_information_end>`), each file holding that stage's own `<stage>` blocks, numbered from 0.
struct IndexEntry {
    std::int32_t id = -1;
    std::string name;
    std::string file;
};

struct StageList {
    // Stages the file never defines keep the original's phase count -1 (absent here).
    std::array<std::optional<Stage>, max_stages> stages;
    std::vector<std::string> diagnostics;
    std::vector<IndexEntry> index;                // the stage files a listing names (see load)
    std::array<std::optional<std::string>, 6> names; // a listed stage's name, by its level (stages 1-5, survival)
};

Result<StageList> parse(std::string_view text);
// The file, or — when it is a listing of stage files — those files, each one's stages placed at its level
// (listing id 0: stages 0-9, 1: 10-19 … 5: 50-59, the survival level) and its name kept.
Result<StageList> load(const ResourceSource& resources, std::string_view path);
// Script-facing table.
ScriptValue to_script_value(const StageList& list);
}
