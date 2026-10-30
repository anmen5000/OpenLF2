-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors
-- Runs the same INSANE! match twice from the same random state (first with the moves unlearned, then learned)
-- and compares the fighters every 30 frames: replaytest.lua with config.pair, config.limit.
local catalog = require("base/game/catalog")
local match = require("base/game/match")
local constants = require("base/game/constants")
local t = {}
function t.run(config)
    local fighters = catalog.load()
    local function find(id) for i, f in ipairs(fighters) do if f.id == id then return i end end end
    local function play()
        local slots = {}
        for k, id in ipairs(config.ids) do slots[k - 1] = {kind = "computer", fighter = find(id), team = (k - 1) % 2 + 1} end
        local state = match.create({mode = constants.modes.versus, difficulty = -2, background = 0,
            fighters = fighters, backgrounds = catalog.backgrounds(), slots = slots})
        local held = {functions = "", function_presses = "", keys = {}}
        local trace = {}
        for tick = 1, config.limit do
            match.step(state, held)
            if tick % 30 == 0 then
                local parts = {}
                for i = 0, 399 do
                    local v = state.items[i]
                    if v then parts[#parts + 1] = string.format("%d:%d,%d,%d,%d,%d", i, v.x_int, v.z_int, v.frame, v.hp, v.mp) end
                end
                local _, index = engine.random_state()
                trace[#trace + 1] = tick .. " r" .. index .. " " .. table.concat(parts, " ")
            end
            if state.round_counter > 0 then break end
        end
        return trace
    end
    local saved_table, saved_index, saved_sequence = engine.random_state()
    local first = play()
    engine.set_random_state(saved_table, saved_index, saved_sequence)
    require("base/game/smart_ai").prepare = function() end
    local second = play()
    local same = #first == #second
    for i = 1, math.min(#first, #second) do
        if first[i] ~= second[i] then
            engine.log("DIFFER at " .. i .. "\n  " .. first[i] .. "\n  " .. second[i])
            same = false
            break
        end
    end
    engine.log(string.format("replay test %s: %d checkpoints, %s", table.concat(config.ids, ","), #first, same and "SAME" or "DIFFERENT"))
end
return t
