-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors
-- Prints stance_exit and lock_of for config.id's config.frames.
local catalog = require("base/game/catalog")
local object_data = require("base/game/object_data")
local item = require("base/game/item")
local smart = require("base/game/smart_ai")
local t = {}
function t.run(config)
    for _, fighter in ipairs(catalog.load()) do
        if fighter.id == config.id then
            local record = item.record({id = fighter.id, kind = 0}, object_data.load(fighter.path))
            local analysis = smart.analyze(record)
            for _, id in ipairs(config.frames) do
                local f = record.frames[id]
                local key, lock = smart.internals.stance_exit(record, analysis, id)
                engine.log(string.format("frame %d state %d next %d wait %d: stance_exit %s %s lock_of %d", id, f.state, f.next, f.wait, tostring(key), tostring(lock), smart.internals.lock_of(record, analysis, id)))
            end
        end
    end
end
return t
