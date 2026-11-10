// SPDX-License-Identifier: MIT
// Copyright (c) 2026 OpenLF2 contributors

#include "openlf2/resources/executable_patches.hpp"
#include "openlf2/resources/installer.hpp"
#include <algorithm>
#include <array>
#include <cstring>

namespace openlf2 {
namespace {
// The original's hit code, where it reads the victim's id: mov ecx, [eax+0x368] (its data);
// mov ecx, [ecx+0x6f4] (the data's id).
constexpr std::uint32_t data_load_address = 0x42e679;
constexpr std::array<unsigned char, 6> data_load{0x8b, 0x88, 0x68, 0x03, 0x00, 0x00};
constexpr std::uint32_t id_load_address = 0x42e67f;
constexpr std::array<unsigned char, 6> id_load{0x8b, 0x89, 0xf4, 0x06, 0x00, 0x00};
// Enough for any table such a routine could hold; a longer chain is not this patch.
constexpr std::size_t routine_limit = 4096;
constexpr std::size_t entry_limit = 400;

bool same(std::span<const char> bytes, std::span<const unsigned char> expected) {
    return bytes.size() == expected.size() && std::memcmp(bytes.data(), expected.data(), expected.size()) == 0;
}
std::uint32_t u32(std::span<const char> bytes, std::size_t at) {
    std::uint32_t value = 0;
    for (std::size_t index = 0; index < 4; ++index) value |= std::uint32_t{static_cast<unsigned char>(bytes[at + index])} << (8 * index);
    return value;
}
unsigned char u8(std::span<const char> bytes, std::size_t at) { return static_cast<unsigned char>(bytes[at]); }

Result<Bytes> code(std::span<const char> executable, std::uint32_t address, std::size_t size) {
    auto bytes = executable_data(executable, address, size);
    if (!bytes) return fail(ErrorCode::format, "lf2.exe: the patched hit code calls outside the executable's code");
    return bytes;
}

// The routine the mod calls instead of reading the id:
//   mov ecx, [ecx+0x6f4]
//   (cmp ecx, id; je set_armor)...      cmp with an 8-bit (83 f9 ib) or 32-bit (81 f9 id) id, je rel32 (0f 84)
//   ret
// where each set_armor is: mov dword [eax+0x340], armor; ret
Result<std::vector<std::pair<std::int32_t, std::int32_t>>> armor_routine(std::span<const char> executable, std::uint32_t address) {
    constexpr std::array<unsigned char, 6> setter{0xc7, 0x80, 0x40, 0x03, 0x00, 0x00};
    auto start = code(executable, address, id_load.size());
    if (!start) return std::unexpected(start.error());
    if (!same(*start, id_load)) return fail(ErrorCode::unsupported, "lf2.exe: the hit code calls a routine OpenLF2 does not know");
    std::vector<std::pair<std::int32_t, std::int32_t>> table;
    std::uint32_t at = address + static_cast<std::uint32_t>(id_load.size());
    while (at - address < routine_limit) {
        auto opcode = code(executable, at, 1);
        if (!opcode) return std::unexpected(opcode.error());
        if (u8(*opcode, 0) == 0xc3) return table;
        std::int32_t id = 0;
        std::size_t compare_size = 0;
        auto compare = code(executable, at, 3);
        if (!compare) return std::unexpected(compare.error());
        if (u8(*compare, 0) == 0x83 && u8(*compare, 1) == 0xf9) {
            id = static_cast<signed char>(u8(*compare, 2));
            compare_size = 3;
        } else if (u8(*compare, 0) == 0x81 && u8(*compare, 1) == 0xf9) {
            auto wide = code(executable, at, 6);
            if (!wide) return std::unexpected(wide.error());
            id = static_cast<std::int32_t>(u32(*wide, 2));
            compare_size = 6;
        } else {
            return fail(ErrorCode::unsupported, "lf2.exe: the hit code's added routine does something OpenLF2 does not know");
        }
        auto jump = code(executable, at + static_cast<std::uint32_t>(compare_size), 6);
        if (!jump) return std::unexpected(jump.error());
        if (u8(*jump, 0) != 0x0f || u8(*jump, 1) != 0x84) {
            return fail(ErrorCode::unsupported, "lf2.exe: the hit code's added routine does something OpenLF2 does not know");
        }
        const std::uint32_t next = at + static_cast<std::uint32_t>(compare_size) + 6;
        const std::uint32_t target = next + u32(*jump, 2);
        auto set = code(executable, target, setter.size() + 5);
        if (!set) return std::unexpected(set.error());
        if (!same(std::span<const char>(*set).first(setter.size()), setter) || u8(*set, setter.size() + 4) != 0xc3) {
            return fail(ErrorCode::unsupported, "lf2.exe: the hit code's added routine does something OpenLF2 does not know");
        }
        const auto armor = static_cast<std::int32_t>(u32(*set, setter.size()));
        // The first comparison that matches decides, as in the routine.
        if (std::none_of(table.begin(), table.end(), [id](const auto& entry) { return entry.first == id; })) {
            if (table.size() == entry_limit) return fail(ErrorCode::limit, "lf2.exe: the armor table is too long");
            table.emplace_back(id, armor);
        }
        at = next;
    }
    return fail(ErrorCode::unsupported, "lf2.exe: the hit code's added routine does not end");
}

// Sauce's kind 8 test (see heal_reach): the original reads the touched object's data, asks whether it is a fighter
// and skips it if not: mov eax, [ecx+0x368]; cmp dword [eax+0x6f8], 0; jne. The mod calls its routine instead of
// the comparison (call rel32; nop; nop), which leaves the answer in the flags for the jne.
constexpr std::uint32_t heal_test_address = 0x4176b8;
constexpr std::array<unsigned char, 6> heal_test_data{0x8b, 0x81, 0x68, 0x03, 0x00, 0x00};
constexpr std::array<unsigned char, 7> heal_test_original{0x83, 0xb8, 0xf8, 0x06, 0x00, 0x00, 0x00};
// mov edi, [esp+0x14] (the itr); mov ebx, [edi+0x40] (bdefend): below 7 the touched object's kind must equal it, 8
// anything, 7 kinds 1, 2, 4 or 6, else nothing; then ebx = [edi+0x28] (respond): 0 anyone, above 4 no one, else
// the teams ([+0x364]) compared (2 other teams, 1 the same, 3 and 4 the same with the same owner [+0x354], 4 the
// touched object being the toucher's owner).
constexpr std::array<unsigned char, 139> heal_test_routine{
    0x8b, 0x7c, 0x24, 0x14, 0x8b, 0x5f, 0x40, 0x83, 0xfb, 0x07, 0x7d, 0x09, 0x39, 0x98, 0xf8, 0x06, 0x00, 0x00, 0x74,
    0x26, 0xc3, 0x83, 0xfb, 0x08, 0x74, 0x20, 0x83, 0xfb, 0x07, 0x75, 0xf5, 0x8b, 0x98, 0xf8, 0x06, 0x00, 0x00, 0x83,
    0xfb, 0x01, 0x74, 0x10, 0x83, 0xfb, 0x02, 0x74, 0x0b, 0x83, 0xfb, 0x04, 0x74, 0x06, 0x83, 0xfb, 0x06, 0x74, 0x01,
    0xc3, 0x8b, 0x5f, 0x28, 0x83, 0xfb, 0x00, 0x74, 0x48, 0x83, 0xfb, 0x04, 0x7f, 0x43, 0x8b, 0x81, 0x64, 0x03, 0x00,
    0x00, 0x8b, 0x7c, 0x24, 0x48, 0x8b, 0xbc, 0xbe, 0x94, 0x01, 0x00, 0x00, 0x39, 0x87, 0x64, 0x03, 0x00, 0x00, 0x74,
    0x04, 0x83, 0xfb, 0x02, 0xc3, 0x83, 0xfb, 0x03, 0x7d, 0x04, 0x83, 0xfb, 0x01, 0xc3, 0x8b, 0x81, 0x54, 0x03, 0x00,
    0x00, 0x39, 0x87, 0x54, 0x03, 0x00, 0x00, 0x75, 0x0f, 0x83, 0xfb, 0x03, 0x74, 0x0a, 0x8b, 0x44, 0x24, 0x4c, 0x39,
    0x87, 0x54, 0x03, 0x00, 0x00, 0xc3};
// Sauce's kind 8 touch (see heal_moves), from the kind's test to its call of a routine that moves the toucher:
// cmp edx, 8; jne (the next kind); eax = the itr; edx = its injury; ecx = the touched object; if the injury is not 0,
// [ecx+0xe0] (the healing timer) = injury + 1000; edx = the toucher; ecx = dvy; eax = dvx; if dvx is not 999,
// [edx+0x70] (the frame) = dvx; ecx above 2 is 0, -1 skips the call, below -1 is 0; call the routine;
// then nops and a jump past the other kinds.
constexpr std::uint32_t heal_touch_address = 0x430c8c;
constexpr std::array<unsigned char, 75> heal_touch_code{
    0x83, 0xfa, 0x08, 0x75, 0x5a, 0x8b, 0x44, 0x24, 0x0c, 0x8b, 0x50, 0x44, 0x8b, 0x8c, 0xbe, 0x94, 0x01, 0x00, 0x00,
    0x83, 0xfa, 0x00, 0x74, 0x0c, 0x81, 0xc2, 0xe8, 0x03, 0x00, 0x00, 0x89, 0x91, 0xe0, 0x00, 0x00, 0x00, 0x8b, 0x94,
    0x9e, 0x94, 0x01, 0x00, 0x00, 0x8b, 0x48, 0x18, 0x8b, 0x40, 0x14, 0x3d, 0xe7, 0x03, 0x00, 0x00, 0x74, 0x03, 0x89,
    0x42, 0x70, 0x83, 0xf9, 0x02, 0x7e, 0x02, 0x33, 0xc9, 0x83, 0xf9, 0xff, 0x74, 0x09, 0x7f, 0x02, 0x33, 0xc9};
// The original's kind 8 touch, as long: the same first 19 bytes, then the healing timer always set, the frame always
// dvx, the toucher's x and z (+ 1.0) the touched object's, and the jump.
constexpr std::size_t heal_touch_shared = 19;
constexpr std::array<unsigned char, 95> heal_touch_original{
    0x83, 0xfa, 0x08, 0x75, 0x5a, 0x8b, 0x44, 0x24, 0x0c, 0x8b, 0x50, 0x44, 0x8b, 0x8c, 0xbe, 0x94, 0x01, 0x00, 0x00,
    0x81, 0xc2, 0xe8, 0x03, 0x00, 0x00, 0x89, 0x91, 0xe0, 0x00, 0x00, 0x00, 0x8b, 0x94, 0x9e, 0x94, 0x01, 0x00, 0x00,
    0x8b, 0x40, 0x14, 0x89, 0x42, 0x70, 0x8b, 0x8c, 0xbe, 0x94, 0x01, 0x00, 0x00, 0xdd, 0x41, 0x58, 0x8b, 0x94, 0x9e,
    0x94, 0x01, 0x00, 0x00, 0xdd, 0x5a, 0x58, 0x8b, 0x84, 0xbe, 0x94, 0x01, 0x00, 0x00, 0xdd, 0x40, 0x68, 0x8b, 0x8c,
    0x9e, 0x94, 0x01, 0x00, 0x00, 0xdc, 0x05, 0x08, 0x7a, 0x44, 0x00, 0xdd, 0x59, 0x68, 0xe9, 0x8f, 0x0b, 0x00, 0x00};
constexpr std::array<unsigned char, 15> heal_touch_after{
    0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0xe9, 0x8f, 0x0b, 0x00, 0x00};
// The mod's code fills the original's place exactly: its code, the call, the nops and the jump.
static_assert(heal_touch_code.size() + 5 + heal_touch_after.size() == heal_touch_original.size());
// The routine: eax = the touched object, edx = the toucher; unless ecx is 1 the toucher's x = the touched object's
// ([+0x58]); unless ecx is 0 its y ([+0x60]); its z ([+0x68]) = the touched object's + 1.0 (the original's double
// at 0x447a08).
constexpr std::array<unsigned char, 49> heal_move_routine{
    0x8b, 0x84, 0xbe, 0x94, 0x01, 0x00, 0x00, 0x8b, 0x94, 0x9e, 0x94, 0x01, 0x00, 0x00, 0x83, 0xf9, 0x01, 0x74, 0x06,
    0xdd, 0x40, 0x58, 0xdd, 0x5a, 0x58, 0x83, 0xf9, 0x00, 0x74, 0x06, 0xdd, 0x40, 0x60, 0xdd, 0x5a, 0x60, 0xdd, 0x40,
    0x68, 0xdc, 0x05, 0x08, 0x7a, 0x44, 0x00, 0xdd, 0x5a, 0x68, 0xc3};
// Where an itr reaches a heavy weapon its dvx and dvy are halved; the mod skips kind 8 there: eax = the touched
// object; ecx = its data; if its kind is 2: ecx = the itr, and unless its kind is 8 dvx and dvy are halved; edx = ecx.
constexpr std::uint32_t heal_heavy_address = 0x42e544;
constexpr std::array<unsigned char, 55> heal_heavy_code{
    0x8b, 0x84, 0xbe, 0x94, 0x01, 0x00, 0x00, 0x8b, 0x88, 0x68, 0x03, 0x00, 0x00, 0x83, 0xb9, 0xf8, 0x06, 0x00, 0x00,
    0x02, 0x75, 0x21, 0x8b, 0x4c, 0x24, 0x0c, 0x83, 0x39, 0x08, 0x74, 0x18, 0x8b, 0x41, 0x14, 0x99, 0x2b, 0xc2, 0xd1,
    0xf8, 0x89, 0x41, 0x14, 0x8b, 0x41, 0x18, 0x99, 0x2b, 0xc2, 0xd1, 0xf8, 0x89, 0x41, 0x18, 0x8b, 0xd1};

// The routine a call at `call_address` (e8 rel32) goes to, when it holds exactly `expected`.
bool calls(std::span<const char> executable, std::uint32_t call_address, std::span<const unsigned char> expected) {
    auto call = executable_data(executable, call_address, 5);
    if (!call || u8(*call, 0) != 0xe8) return false;
    const std::uint32_t routine = call_address + 5 + u32(*call, 1);
    auto bytes = executable_data(executable, routine, expected.size());
    return bytes && same(*bytes, expected);
}

void read_armor(std::span<const char> executable, ExecutablePatches& patches) {
    auto before = executable_data(executable, data_load_address, data_load.size());
    auto spot = executable_data(executable, id_load_address, id_load.size());
    // Not an LF2 2.0a executable laid out like the original: nothing to recognise.
    if (!before || !spot || !same(*before, data_load)) return;
    if (same(*spot, id_load)) return;
    // call rel32; nop
    if (u8(*spot, 0) != 0xe8 || u8(*spot, 5) != 0x90) {
        patches.problems.push_back("lf2.exe: the hit code is changed in a way OpenLF2 does not know");
        return;
    }
    const std::uint32_t routine = id_load_address + 5 + u32(*spot, 1);
    auto table = armor_routine(executable, routine);
    if (!table) {
        patches.problems.push_back(table.error().message);
        return;
    }
    patches.armor_by_id = std::move(*table);
}

void read_heal(std::span<const char> executable, ExecutablePatches& patches) {
    auto before = executable_data(executable, heal_test_address, heal_test_data.size());
    if (before && same(*before, heal_test_data)) {
        const std::uint32_t test = heal_test_address + static_cast<std::uint32_t>(heal_test_data.size());
        auto spot = executable_data(executable, test, heal_test_original.size() + 2);
        if (spot && !same(std::span<const char>(*spot).first(heal_test_original.size()), heal_test_original)) {
            // call rel32; nop; nop; jne
            if (u8(*spot, 5) == 0x90 && u8(*spot, 6) == 0x90 && u8(*spot, 7) == 0x0f && u8(*spot, 8) == 0x85
                && calls(executable, test, heal_test_routine)) {
                patches.heal_reach = true;
            } else {
                patches.problems.push_back("lf2.exe: the test of what itr kind 8 touches is changed in a way OpenLF2 does not know");
            }
        }
    }
    auto touch = executable_data(executable, heal_touch_address, heal_touch_original.size());
    const auto touch_bytes = touch ? std::span<const char>(*touch) : std::span<const char>{};
    if (touch && same(touch_bytes.first(heal_touch_shared), std::span(heal_touch_original).first(heal_touch_shared))
        && !same(touch_bytes, heal_touch_original)) {
        const std::uint32_t call = heal_touch_address + static_cast<std::uint32_t>(heal_touch_code.size());
        if (same(touch_bytes.first(heal_touch_code.size()), heal_touch_code)
            && same(touch_bytes.subspan(heal_touch_code.size() + 5), heal_touch_after) && calls(executable, call, heal_move_routine)) {
            patches.heal_moves = true;
        } else {
            patches.problems.push_back("lf2.exe: what itr kind 8 does when it touches is changed in a way OpenLF2 does not know");
        }
    }
    auto heavy = executable_data(executable, heal_heavy_address, heal_heavy_code.size());
    if (heavy && same(*heavy, heal_heavy_code)) patches.heal_heavy_whole = true;
}
}

ExecutablePatches read_executable_patches(std::span<const char> executable) {
    ExecutablePatches patches;
    read_armor(executable, patches);
    read_heal(executable, patches);
    std::vector<std::string> parts;
    if (!patches.armor_by_id.empty()) parts.push_back("armor for " + std::to_string(patches.armor_by_id.size()) + " fighters");
    if (patches.heal_reach) parts.push_back("itr kind 8 touches what its bdefend and respond say");
    if (patches.heal_moves) parts.push_back("itr kind 8 moves by its injury, dvx and dvy");
    if (patches.heal_heavy_whole) parts.push_back("heavy weapons touched by kind 8 keep its dvx and dvy whole");
    for (const auto& part : parts) patches.description += (patches.description.empty() ? "" : "; ") + part;
    return patches;
}
}
