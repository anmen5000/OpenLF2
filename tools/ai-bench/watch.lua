-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors
-- Plays one fighter's analysis with a frame-by-frame log of the fighter and its objects (config.id, config.full).
local catalog = require("base/game/catalog")
local object_data = require("base/game/object_data")
local item = require("base/game/item")
local smart = require("base/game/smart_ai")
local w = {}
function w.run(config)
    for _, fighter in ipairs(catalog.load()) do
        if fighter.id == config.id then
            smart.full_sandbox = config.full
            local tick = 0
            smart.watch = function(state, me, entry)
                if entry.frame ~= config.entry or entry.chain or entry.parent then return end
                tick = tick + 1
                if tick >= config.from and tick <= config.to then
                    local parts = {string.format("%d me f%d x%d y%d", tick, me.frame, me.x_int, me.y_int)}
                    for index = 1, 399 do
                        local v = state.items[index]
                        if v then parts[#parts + 1] = string.format("[%d id%d f%d x%d y%d itr%d]", index, v.record.id, v.frame, v.x_int, v.y_int, #v.record.frame(v.frame).interactions) end
                    end
                    engine.log(table.concat(parts, " "))
                end
            end
            local record = item.record({id = fighter.id, kind = 0}, object_data.load(fighter.path))
            smart.analyze(record)
        end
    end
end
return w
