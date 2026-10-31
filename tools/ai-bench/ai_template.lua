-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors
--
-- A computer player of your own, in the shape the bench expects of one: a module with `version`, `prepare(state)`
-- (called once before the match; learn what you like) and `control(state, index)` (called every frame for the
-- fighter in `state.items[index]`; set its keys). Pit it against INSANE! with
--   {command = "duel", brains = {"smart", "smart@ai_template"}, games = 4, pairs = {{1, 2}}, verbose = true}
-- and against another file of your own by copying it in as ai_alt.lua (`module=ai_alt|ai_alt.lua` in
-- package.manifest, or ALT_AI=<file> with tools/ai-bench/run.sh) and naming "smart@ai_alt".
--
-- Everything it may read is in the match state (frames, positions, HP, MP, what the other fighters do), the same
-- for every computer in a network room; it must not keep anything outside the state between frames except
-- its own notes (here, in `value.template_memory`), and must not draw random numbers of its own, or recordings
-- and network games fall out of step. This one walks up to the nearest enemy, guards against a blow about to land
-- and punches when in reach: a starting point, not a fighter.
local constants = require("base/game/constants")
local item = require("base/game/item")
local states = constants.frame_states
local abs = math.abs
local brain = {}
brain.version = "template 1"

function brain.prepare(state) end

local function clear(value)
    for _, key in ipairs(item.keys) do
        value.previous_keys[key] = value.keys[key]
        value.keys[key] = false
    end
end
local function press(value, key) value.keys[key] = true end
local function fresh(value, key) value.keys[key] = true; value.previous_keys[key] = false end

local function hostile(state, a, b)
    if a.team == b.team and a.team ~= constants.teams.independent then return false end
    return a.team ~= b.team
end

function brain.control(state, index)
    local me = state.items[index]
    local memory = me.template_memory or {}
    me.template_memory = memory
    clear(me)
    local frame = me.record.frame(me.frame)
    if frame.state ~= states.standing and frame.state ~= states.walking then return end
    -- The nearest enemy still standing.
    local target, best
    for other = 0, constants.item_slots - 1 do
        local value = state.items[other]
        if value and other ~= index and value.hp > 0 and value.record.kind == constants.record_kinds.character and hostile(state, me, value) then
            local distance = abs(value.x_int - me.x_int) + abs(value.z_int - me.z_int) * 2
            if not best or distance < best then target, best = value, distance end
        end
    end
    if not target then return end
    local dx, dz = target.x_int - me.x_int, target.z_int - me.z_int
    local tstate = target.record.frame(target.frame).state
    -- A blow about to land (the enemy in an attacking frame within arm's reach): guard, facing it.
    if tstate == states.attacking and abs(dx) < 90 and abs(dz) < 20 then
        press(me, dx > 0 and "right" or "left")
        fresh(me, "defend")
        return
    end
    -- In reach: punch (every other frame, so that the key is seen pressed afresh).
    if abs(dx) < 60 and abs(dz) < 14 then
        press(me, dx > 0 and "right" or "left")
        if (state.frame_number % 2) == 0 then fresh(me, "attack") end
        return
    end
    -- Otherwise walk up, lining up in depth first.
    if abs(dz) > 8 then press(me, dz > 0 and "down" or "up") end
    if abs(dx) > 40 then press(me, dx > 0 and "right" or "left") end
end

return brain
