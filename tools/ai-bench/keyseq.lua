-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors
-- Plays a scripted key timeline on fighter config.id (slot 10, no AI) against a still config.other (slot 11), logging
-- the fighter's frame, state, position, mp and the objects it owns every tick: keyseq.lua with
--   config.seq = {{tick, "key", true|false}, ...}  (key: up down left right attack jump defend; true = press)
--   config.ticks, config.every (log every N ticks; frame changes are always logged)
local catalog = require("base/game/catalog")
local match = require("base/game/match")
local constants = require("base/game/constants")
local t = {}
function t.run(config)
    local fighters = catalog.load()
    local function find(id) for i, f in ipairs(fighters) do if f.id == id then return i end end error("no fighter " .. id) end
    local options = {mode = constants.modes.versus, difficulty = -1, background = constants.background_rows.random,
        fighters = fighters, backgrounds = catalog.backgrounds(),
        slots = {[0] = {kind = "computer", fighter = find(config.id), team = 1}, [1] = {kind = "computer", fighter = find(config.other or config.id), team = 2}}}
    local state = match.create(options)
    local me, foe = state.items[10], state.items[11]
    require("base/game/ai").control = function() end
    me.brain = "none"; foe.brain = "none"
    state.weapon_command = 2
    local held = {functions = "", function_presses = "", keys = {}}
    for _ = 1, 20 do match.step(state, held) end
    if config.far then foe.x_int = me.x_int + config.far; foe.x = foe.x_int end
    if config.mp then me.mp = config.mp end
    local pressed = {}
    local last = ""
    for tick = 1, config.ticks or 200 do
        for _, k in ipairs({"up", "down", "left", "right", "attack", "jump", "defend"}) do me.previous_keys[k] = me.keys[k] end
        for _, step in ipairs(config.seq or {}) do
            if step[1] == tick then pressed[step[2]] = step[3] end
        end
        for k, v in pairs(pressed) do me.keys[k] = v end
        match.step(state, held)
        local owned = {}
        for i = 50, 399 do
            local o = state.items[i]
            if o and o.owner == 10 then owned[#owned + 1] = string.format("o%d:f%d/s%d@%d,%d,%d", o.record.id, o.frame, o.record.frame(o.frame).state, o.x_int, o.y_int, o.z_int) end
        end
        local f = me.record.frame(me.frame)
        local line = string.format("f%d(%s) s%d x%d y%d z%d vx%.1f mp%d hp%d wpn%d held%d keys[%s] %s", me.frame, f.name or "", f.state, me.x_int, me.y_int, me.z_int, me.vx, me.mp, me.hp, me.weapon, me.held_item,
            table.concat((function() local ks = {} for k, v in pairs(pressed) do if v then ks[#ks + 1] = k end end table.sort(ks) return ks end)(), ","), table.concat(owned, " "))
        local key = tostring(me.frame)
        if key ~= last or tick % (config.every or 10) == 0 then engine.log(tick .. ": " .. line) end
        last = key
    end
end
return t
