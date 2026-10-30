// SPDX-License-Identifier: MIT
// Copyright (c) 2026 OpenLF2 contributors

#pragma once
#include "openlf2/core/result.hpp"
#include <cstdint>
#include <span>
#include <string>
#include <utility>
#include <vector>

namespace openlf2 {
// Changes a mod made to the code of its copy of lf2.exe that change how the game plays, read back from that
// executable so the scripts can play the same way.
struct ExecutablePatches {
    // Dragon Ball Super Edition's armor: where a plain attack reaches someone who is not exposed (the original's hit
    // code at 0x42e67f, just before Knight's, Louis's and Julian's own armor), the fighter with one of these ids gets
    // this armor, by which plain hits are divided (damage = injury * 100 / armor), until the match ends. The mod
    // calls a routine it added past the end of the code instead of reading the victim's id there.
    std::vector<std::pair<std::int32_t, std::int32_t>> armor_by_id;
    // What was recognised, for the log; empty for an unchanged executable.
    std::string description;
};
// Recognises the patches above; an executable without them gives empty patches. A changed spot this reader does
// not understand is an error, so that the game can say it plays this mod differently.
Result<ExecutablePatches> read_executable_patches(std::span<const char> executable);
}
