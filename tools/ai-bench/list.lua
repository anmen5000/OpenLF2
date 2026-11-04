-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors
-- The fighters of the mod, one line each — "fighter <id> <name> <file>" (hidden: the ones LF2 hides until
-- unlocked) — and its backgrounds — "background <row> <name> <file>" — for picking them by number or by name
-- (show, duel; windows/xem.bat): {command = "list"}.
local catalog = require("base/game/catalog")
local names = require("bench/names")
local list = {}
function list.run()
    local seen = {}
    for _, fighter in ipairs(catalog.load()) do
        if not seen[fighter.id] then
            seen[fighter.id] = true
            engine.log(string.format("fighter %d %s %s%s", fighter.id, fighter.name, fighter.path, fighter.hidden and " hidden" or ""))
        end
    end
    for row, entry in ipairs(catalog.backgrounds()) do
        engine.log(string.format("background %d %s %s", row - 1, names.background_name(entry), entry.path))
    end
end
return list
