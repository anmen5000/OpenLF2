-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors
-- INSANE! fighter config.ids[1] against config.ids[2] standing still (no computer player), config.far apart, for
-- config.ticks frames, logging both every config.every frames and whenever the still one's frame changes:
-- what the AI does to a fighter that cannot answer (a trap, a hold, a stun).
local catalog = require("base/game/catalog")
local match = require("base/game/match")
local constants = require("base/game/constants")
local ai = require("base/game/ai")
local t = {}
function t.run(config)
    local fighters = catalog.load()
    local function find(id) for i, f in ipairs(fighters) do if f.id == id then return i end end error("no fighter " .. id) end
    local options = {mode = constants.modes.versus, difficulty = -1, background = constants.background_rows.random,
        fighters = fighters, backgrounds = catalog.backgrounds(),
        slots = {[0] = {kind = "computer", fighter = find(config.ids[1]), team = 1}, [1] = {kind = "computer", fighter = find(config.ids[2]), team = 2}}}
    local state = match.create(options)
    local me, foe = state.items[10], state.items[11]
    -- Until config.handover, the INSANE! fighter plays config.seq ({{tick, key, down}, ...}, as keyseq) instead:
    -- a trap set by hand, then the AI's turn.
    me.brain = (config.handover or 0) > 0 and "none" or "smart"; foe.brain = "none"
    local control = ai.control
    ai.control = function(s, index, ...) if s.items[index].brain ~= "none" then return control(s, index, ...) end end
    local held = {functions = "", function_presses = "", keys = {}}
    for _ = 1, 20 do match.step(state, held) end
    if config.far then foe.x_int = me.x_int + config.far; foe.x = foe.x_int end
    if config.dz then foe.z_int = me.z_int + config.dz; foe.z = foe.z_int end
    -- config.spawn = {id, frame, dx}: an object of the mod placed at the still fighter (a trap set on it by hand).
    if config.spawn then
        local objects = require("base/game/objects")
        local slot = objects.create(state, config.spawn.id, 10, config.spawn.frame, me.team, foe.x_int + (config.spawn.dx or 0), 0, foe.z_int, 0, 0, 0, me.facing)
        engine.log("spawned object " .. config.spawn.id .. " in slot " .. slot)
    end
    local last = ""
    local pressed = {}
    for tick = 1, config.ticks or 300 do
        if tick <= (config.handover or 0) then
            for _, k in ipairs({"up", "down", "left", "right", "attack", "jump", "defend"}) do me.previous_keys[k] = me.keys[k] end
            for _, step in ipairs(config.seq or {}) do if step[1] == tick then pressed[step[2]] = step[3] end end
            for k, v in pairs(pressed) do me.keys[k] = v end
        elseif tick == (config.handover or 0) + 1 then
            me.brain = "smart"
        end
        match.step(state, held)
        local m = me.smart_memory
        local line = string.format("me f%d s%d x%d z%d y%d mp%d | %s | foe f%d s%d x%d z%d y%d hp%d caught_by %d",
            me.frame, me.record.frame(me.frame).state, me.x_int, me.z_int, me.y_int, me.mp, m and m.note or "-",
            foe.frame, foe.record.frame(foe.frame).state, foe.x_int, foe.z_int, foe.y_int, foe.hp, foe.caught_by or -1)
        local key = tostring(foe.frame)
        if key ~= last or tick % (config.every or 10) == 0 then engine.log(tick .. ": " .. line) end
        last = key
        if foe.hp <= 0 then engine.log("foe down at " .. tick) break end
    end
end
return t
