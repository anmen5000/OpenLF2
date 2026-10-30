-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors
-- Drops a weapon beside the INSANE! fighter and watches it: weapontest.lua with config.ids, config.weapon (id), config.ticks.
local catalog = require("base/game/catalog")
local match = require("base/game/match")
local objects = require("base/game/objects")
local constants = require("base/game/constants")
local t = {}
function t.run(config)
    local fighters = catalog.load()
    local function find(id) for i, f in ipairs(fighters) do if f.id == id then return i end end error("no fighter " .. id) end
    local options = {mode = constants.modes.versus, difficulty = -1, background = constants.background_rows.random,
        fighters = fighters, backgrounds = catalog.backgrounds(),
        slots = {[0] = {kind = "computer", fighter = find(config.ids[1]), team = 1}, [1] = {kind = "computer", fighter = find(config.ids[2]), team = 2}}}
    local state = match.create(options)
    local me, foe = state.items[10], state.items[11]
    me.brain = "smart"; foe.brain = config.foe or "classic"
    if config.passive then require("base/game/ai").control = function() end end
    state.weapon_command = 2 -- no random drops
    local held = {functions = "", function_presses = "", keys = {}}
    for _ = 1, 20 do match.step(state, held) end
    if config.far then foe.x_int = me.x_int + config.far; foe.x = foe.x_int end
    local slot = objects.create(state, config.weapon, 99, 0, constants.teams.independent, me.x_int + (config.offset or 70), -40, me.z_int, 0, 0, 0, 0)
    local weapon = state.items[slot]
    engine.log(string.format("weapon %d in slot %d: kind %d frame %d", config.weapon, slot, weapon.record.kind, weapon.frame))
    for _, id in ipairs({60, 61, 64, 65, 70, 71, 72, 73, 74, 75}) do
        local f = weapon.record.frames[id]
        if f then
            local parts = {}
            for _, i in ipairs(f.interactions) do parts[#parts + 1] = string.format("itr[k%d x%d y%d w%d h%d]", i.kind, i.x, i.y, i.width, i.height) end
            for _, b in ipairs(f.bodies) do parts[#parts + 1] = string.format("bdy[x%d y%d w%d h%d]", b.x, b.y, b.width, b.height) end
            engine.log(string.format("  weapon frame %d: state %d c%d,%d %s", id, f.state, f.center_x, f.center_y, table.concat(parts, " ")))
        end
    end
    local last = ""
    for tick = 1, config.ticks or 400 do
        if config.manual then
            -- Stand on the weapon and press attack by hand (no AI): does the game pick it up?
            require("base/game/ai").control = function() end
            me.brain = "none"
            local w = state.items[slot]
            if w and tick == 30 then me.x_int = w.x_int + (config.manual_dx or 0); me.x = me.x_int; me.z_int = w.z_int; me.z = me.z_int end
            for _, k in ipairs({"up", "down", "left", "right", "attack", "jump", "defend"}) do me.previous_keys[k] = me.keys[k]; me.keys[k] = false end
            if tick >= 32 and tick % 2 == 0 then me.keys.attack = true end
        end
        match.step(state, held)
        local note = me.smart_memory and me.smart_memory.note or "-"
        if config.probe and config.probe[tick] then
            local smart = require("base/game/smart_ai")
            local I = smart.internals
            local context = state.smart_context
            local tt, box, src = I.earliest_threat(state, 10, me, 16, nil, 1, context)
            local keys = {}
            for _, k in ipairs({"up", "down", "left", "right", "attack", "jump", "defend"}) do if me.keys[k] then keys[#keys + 1] = k end end
            local view = context.analysis_of(me)
            context.target_lock = I.target_lock_of(context, foe, foe.record.frame(foe.frame))
            local bm, bt, bs = I.best_attack(context, me, me.record.frame(me.frame), me.record.frame(me.frame).state, foe, 70, nil)
            local m = context.models and context.models[foe]
            engine.log(string.format("  probe %d: keys %s vx %.1f | threat t%s inj %s from %s | lock %d | moves %d (armed %s) | best %s t%s s%.1f | danger_at %.1f aggr %.2f | model g%d h%d a%d c%d",
                tick, table.concat(keys, ","), me.vx, tostring(tt), box and box.injury or "-", src and (src.record.id .. "/f" .. src.frame) or "-",
                context.target_lock, #view.moves, tostring(view.armed ~= nil), bm and (bm.entry.basic or bm.entry.field or "chain") or "-", tostring(bt), bs or 0,
                I.danger_at(foe, context.analysis_of(foe), me.x_int, me.z_int), context.aggression or -1, m and m.guards or -1, m and m.hits or -1, m and m.attacks or -1, m and m.chances or -1))
        end
        local w = state.items[slot]
        local line = string.format("me f%d x%d z%d wpn %d held %d foe x%d f%d hp%d | %s | weapon %s", me.frame, me.x_int, me.z_int, me.weapon, me.held_item, foe.x_int, foe.frame, foe.hp, note,
            w and string.format("f%d s%d x%d y%d z%d code %d bodies %d", w.frame, w.record.frame(w.frame).state, w.x_int, w.y_int, w.z_int, w.weapon, #w.record.frame(w.frame).bodies) or "gone")
        if tick % (config.every or 10) == 0 or (note ~= last and (note:find("weapon") or note:find("pick") or note:find("drink"))) then engine.log(tick .. ": " .. line) end
        last = note
    end
    local pickups = me.pickings or 0
    engine.log(string.format("pickings %d, hp %d/%d mp %d, foe hp %d", pickups, me.hp, me.dark_hp, me.mp, foe.hp))
end
return t
