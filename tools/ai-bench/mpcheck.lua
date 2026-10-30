-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors
-- Puts a fighter into a frame with little MP and reports its MP as the frames run (charging moves).
local catalog = require("base/game/catalog")
local match = require("base/game/match")
local constants = require("base/game/constants")
local mpcheck = {}
function mpcheck.run(config)
    local fighters = catalog.load()
    local function find(id) for i, f in ipairs(fighters) do if f.id == id then return i end end error("no fighter " .. id) end
    local options = {mode = constants.modes.versus, difficulty = -1, background = constants.background_rows.random,
        fighters = fighters, backgrounds = catalog.backgrounds(),
        slots = {[0] = {kind = "computer", fighter = find(config.id), team = 1}, [1] = {kind = "computer", fighter = find(config.other or config.id), team = 2}}}
    local state = match.create(options)
    local me = state.items[10]
    me.brain = "none"; state.items[11].brain = "none"
    local held = {functions = "", function_presses = "", keys = {}}
    for _ = 1, 40 do match.step(state, held) end
    me.mp = config.mp or 100
    me.frame = config.frame; me.wait_counter = 0
    local line = {}
    for t = 1, config.ticks or 90 do
        if config.press and t >= config.press_at then
            require("base/game/ai").control = function() end
            for _, k in ipairs({"up", "down", "left", "right", "attack", "jump", "defend"}) do me.previous_keys[k] = me.keys[k]; me.keys[k] = false end
            if (t - config.press_at) % 2 == 0 then me.keys[config.press] = true end
        end
        match.step(state, held)
        if t % (config.every or 5) == 0 then line[#line + 1] = string.format("t%d f%d s%d mp%d", t, me.frame, me.record.frame(me.frame).state, me.mp) end
    end
    engine.log(table.concat(line, " | "))
end
return mpcheck
