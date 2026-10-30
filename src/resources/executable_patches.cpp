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
}

Result<ExecutablePatches> read_executable_patches(std::span<const char> executable) {
    ExecutablePatches patches;
    auto before = executable_data(executable, data_load_address, data_load.size());
    auto spot = executable_data(executable, id_load_address, id_load.size());
    // Not an LF2 2.0a executable laid out like the original: nothing to recognise.
    if (!before || !spot || !same(*before, data_load)) return patches;
    if (same(*spot, id_load)) return patches;
    // call rel32; nop
    if (u8(*spot, 0) != 0xe8 || u8(*spot, 5) != 0x90) {
        return fail(ErrorCode::unsupported, "lf2.exe: the hit code is changed in a way OpenLF2 does not know");
    }
    const std::uint32_t routine = id_load_address + 5 + u32(*spot, 1);
    auto table = armor_routine(executable, routine);
    if (!table) return std::unexpected(table.error());
    patches.armor_by_id = std::move(*table);
    patches.description = "armor for " + std::to_string(patches.armor_by_id.size()) + " fighters";
    return patches;
}
}
