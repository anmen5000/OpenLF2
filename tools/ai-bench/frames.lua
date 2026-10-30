-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors
-- Prints chosen frames of a fighter: frames.lua with config.id and config.frames.
local catalog = require("base/game/catalog")
local object_data = require("base/game/object_data")
local f = {}
function f.run(config)
    for _, fighter in ipairs(catalog.load()) do
        if fighter.id == config.id then
            local data = object_data.load(fighter.path)
            for _, id in ipairs(config.frames) do
                local frame = data.frames[id]
                if frame then
                    local parts = {}
                    for _, b in ipairs(frame.bodies) do parts[#parts + 1] = string.format("bdy[k%d x%d y%d w%d h%d]", b.kind, b.x, b.y, b.width, b.height) end
                    for _, i in ipairs(frame.interactions) do parts[#parts + 1] = string.format("itr[k%d x%d y%d w%d h%d inj%d f%d bd%d]", i.kind, i.x, i.y, i.width, i.height, i.injury, i.fall, i.bdefend) end
                    local hits = {}
                    for _, h in ipairs({"a", "d", "j", "Fa", "Ua", "Da", "Fj", "Uj", "Dj", "ja"}) do if frame.hits[h] ~= 0 then hits[#hits + 1] = h .. "=" .. frame.hits[h] end end
                    engine.log(string.format("%d %s: state %d wait %d next %d c%d,%d %s %s", id, frame.name or "", frame.state, frame.wait, frame.next, frame.center_x, frame.center_y, table.concat(parts, " "), table.concat(hits, " ")))
                end
            end
        end
    end
end
return f
