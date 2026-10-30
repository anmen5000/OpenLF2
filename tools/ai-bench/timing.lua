-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors
-- Times the learning of some fighters: timing.lua with config.ids.
local catalog = require("base/game/catalog")
local object_data = require("base/game/object_data")
local item = require("base/game/item")
local smart = require("base/game/smart_ai")
local t = {}
function t.run(config)
    local clock = os and os.clock
    for _, fighter in ipairs(catalog.load()) do
        if config.only[fighter.id] then
            local record = item.record({id = fighter.id, kind = 0}, object_data.load(fighter.path))
            local before, plays = clock and clock() or 0, smart.plays
            local analysis = smart.analyze(record)
            engine.log(string.format("%d %s: %d moves, %d entries%s, %d plays, %.2f s", fighter.id, fighter.name, #analysis.moves,
                analysis.entries or -1, (analysis.entries or 0) >= (config.cap or 40) and " (CAP)" or "", smart.plays - plays, clock and (clock() - before) or -1))
        end
    end
end
return t
