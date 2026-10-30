-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors
-- Loads every object of the mod (as a match would) and reports what fails: loadall.lua.
local catalog = require("base/game/catalog")
local object_data = require("base/game/object_data")
local t = {}
function t.run(config)
    local objects = catalog.objects()
    local count, failed = 0, 0
    for _, entry in ipairs(objects.list or objects) do
        if type(entry) == "table" and entry.path then
            count = count + 1
            local ok, result = pcall(object_data.load, entry.path)
            if not ok then
                failed = failed + 1
                engine.log(string.format("FAIL id %d %s: %s", entry.id, entry.path, tostring(result)))
            elseif config.diagnostics and result.diagnostics and #result.diagnostics > 0 then
                engine.log(string.format("id %d %s: %d notes; first: %s", entry.id, entry.path, #result.diagnostics, result.diagnostics[1]))
            end
        end
    end
    local fighters = catalog.load()
    engine.log(string.format("%d objects, %d failed; %d fighters: %s", count, failed, #fighters,
        (function() local names = {} for _, f in ipairs(fighters) do names[#names + 1] = f.id .. ":" .. f.name .. (f.hidden and "(h)" or "") end return table.concat(names, " ") end)()))
    for _, bg in ipairs(catalog.backgrounds()) do engine.log("bg " .. tostring(bg.name or bg.path)) end
end
return t
