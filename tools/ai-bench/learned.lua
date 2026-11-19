-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors
-- Learns every fighter of the mod once and prints the files of what INSANE! and XOI learn of them (base/game/smart_ai
-- learned_kit), which the kit's hoc-chieu.bat puts into the mod as xoi/learned-<id>.txt: a match then reads them
-- instead of learning. config.lua: return {command = "learned"} (config.ids = {...}: only those). Every line of a
-- fighter's file is printed as "LEARNED <id> <line>", then "LEARNED-DONE <id> <name> <bytes> <ms>" (or
-- "LEARNED-FAILED <id> <why>"), and at the end "LEARNED-END <files>". config.check: each file is read back and written
-- again, which must give the same text ("LEARNED-CHECK <id> same|DIFFERENT").
local catalog = require("base/game/catalog")
local object_data = require("base/game/object_data")
local item = require("base/game/item")
local constants = require("base/game/constants")
local smart = require("base/game/smart_ai")
local job = {}
function job.run(config)
    -- (Learned anew, whatever files the mod has already.)
    smart.learned_kit.ignore_files = true
    local wanted
    if config.ids then
        wanted = {}
        for _, id in ipairs(config.ids) do wanted[id] = true end
    end
    local names = {}
    for _, fighter in ipairs(catalog.load()) do names[fighter.id] = fighter.name end
    local done, seen = 0, {}
    for _, entry in ipairs(catalog.objects().list) do
        -- (The first entry of an id is the one a match takes: objects.record.)
        if entry.kind == constants.record_kinds.character and not seen[entry.id] and (not wanted or wanted[entry.id]) then
            seen[entry.id] = true
            local start = engine.network_time()
            local ok, text, problem = pcall(function()
                return smart.learned_kit.write(item.record(entry, object_data.load(entry.path)))
            end)
            local spent = engine.network_time() - start
            local name = tostring(names[entry.id] or entry.path):gsub("%s", "_")
            if not ok then
                engine.log(string.format("LEARNED-FAILED %d %s", entry.id, tostring(text)))
            elseif not text then
                engine.log(string.format("LEARNED-FAILED %d %s", entry.id, tostring(problem)))
            else
                -- (A few hundred lines at a time: each print is written out at once, and a big mod has 250,000.)
                local prefix, chunk = "LEARNED " .. entry.id .. " ", {}
                for line in (text .. "\n"):gmatch("([^\n]*)\n") do
                    chunk[#chunk + 1] = prefix .. line
                    if #chunk == 400 then engine.log(table.concat(chunk, "\n")); chunk = {} end
                end
                if #chunk > 0 then engine.log(table.concat(chunk, "\n")) end
                engine.log(string.format("LEARNED-DONE %d %s %d %.0f", entry.id, name, #text, spent))
                done = done + 1
                if config.check then
                    -- (Read back as a match reads it, then written again from what was read.)
                    local again = smart.learned_kit.check(item.record(entry, object_data.load(entry.path)), text)
                    engine.log(string.format("LEARNED-CHECK %d %s", entry.id, again == text and "same" or "DIFFERENT"))
                end
            end
        end
    end
    engine.log(string.format("LEARNED-END %d", done))
end
return job
