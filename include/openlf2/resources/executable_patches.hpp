// SPDX-License-Identifier: MIT
// Copyright (c) 2026 OpenLF2 contributors

#pragma once
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
    // Itr kind 8, the original's healing that touches only fighters, made a detector that touches what the itr says
    // (the lf2.exe of Sauce's "lf2-AI VS and Stage Challenge"): where the original's hit test (0x4176be) asks whether
    // the object touched is a fighter, the mod calls a routine of its own. The itr's bdefend says what it touches
    // (0 to 6 that kind of object only, 0 the fighters as in the original; 7 weapons and drinks; 8 anything; others
    // nothing) and its respond whom (0 anyone; 1 its own team; 2 the other teams; 3 its team, with the same owner;
    // 4 as 3, and the object touched is its owner; others no one).
    bool heal_reach = false;
    // The same mod's touch of kind 8 (the original's at 0x430c8c: the touched object heals by the injury, the toucher
    // goes to frame dvx and onto the touched object's place and depth): no injury no healing, dvx 999 keeps the
    // frame, and dvy says where the toucher goes (-1 nowhere, 1 to the touched object's height and depth, 2 to its
    // place, height and depth, anything else its place and depth, as the original).
    bool heal_moves = false;
    // And a heavy weapon touched by kind 8 keeps the itr's dvx and dvy whole (0x42e55a), where the original halves
    // them for any itr that reaches one.
    bool heal_heavy_whole = false;
    // What was recognised, for the log; empty for an unchanged executable.
    std::string description;
    // Spots changed in a way this reader does not understand, each a sentence for the log: the game plays them as the
    // original does, so this mod may play differently here.
    std::vector<std::string> problems;
};
// Recognises the patches above; an executable without them gives empty patches, one that is not laid out like the
// original 2.0a (another version, packed) none either.
ExecutablePatches read_executable_patches(std::span<const char> executable);
}
