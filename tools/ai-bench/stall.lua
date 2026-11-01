-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors
-- Finds stretches of a match in which neither fighter loses HP for `quiet` frames (default 300): two computer
-- players stuck in a loop (a trap cast again and again on an opponent already held, two fighters standing off
-- for good). Plays `games` games of every pair in `pairs` (the sides swap every game) with `brains` (default
-- {"smart", "smart"}; `notes`: XOI notes of this package, as for duel) and prints, for each stretch found, where it
-- started; at the end, how many frames were spent so, and what each fighter's computer player was doing then (its
-- note of the frame, the second fighter's frame state). `show` = N: a line every N frames of each stretch.
local catalog = require("base/game/catalog")
local match = require("base/game/match")
local constants = require("base/game/constants")
local brains = require("bench/brains")
local job = {}
local function find(fighters, id)
    for i, f in ipairs(fighters) do if f.id == id then return i end end
    error("no fighter " .. tostring(id))
end
local function category(note) return (note:match("^(%a+:? ?%a*)")) or note end
local function top(list, n)
    local keys = {}
    for k in pairs(list) do keys[#keys + 1] = k end
    table.sort(keys, function(x, y) if list[x] ~= list[y] then return list[x] > list[y] end return x < y end)
    local parts = {}
    for i = 1, math.min(n, #keys) do parts[#parts + 1] = string.format("%s=%d", keys[i], list[keys[i]]) end
    return table.concat(parts, "; ")
end
function job.run(config)
    local fighters, backgrounds = catalog.load(), catalog.backgrounds()
    if config.notes then require("base/game/smart_ai").use_notes(require("bench/" .. config.notes).text) end
    local names = config.brains or {"smart", "smart"}
    for _, name in ipairs(names) do brains.load(name) end
    local quiet = config.quiet or 300
    local stalls, stall_frames, frames, games, draws = 0, 0, 0, 0, 0
    local notes_a, notes_b, states_b = {}, {}, {}
    for _, pair in ipairs(config.pairs) do
        for game = 1, config.games or 2 do
            local slot_a, slot_b = 0, 1
            if game % 2 == 0 then slot_a, slot_b = 1, 0 end
            local state = match.create({mode = constants.modes.versus, difficulty = config.difficulty or -2,
                background = constants.background_rows.random, fighters = fighters, backgrounds = backgrounds,
                slots = {[slot_a] = {kind = "computer", fighter = find(fighters, pair[1]), team = 1},
                    [slot_b] = {kind = "computer", fighter = find(fighters, pair[2]), team = 2}}})
            local a, b = state.items[10 + slot_a], state.items[10 + slot_b]
            a.brain, b.brain = names[1], names[2]
            games = games + 1
            local held = {functions = "", function_presses = "", keys = {}}
            local last_change, hp_a, hp_b = 0, a.hp, b.hp
            for tick = 1, config.limit or 9000 do
                match.step(state, held)
                frames = frames + 1
                if a.hp < hp_a - 2 or b.hp < hp_b - 2 then last_change = tick end
                hp_a, hp_b = a.hp, b.hp
                local still = tick - last_change
                if still == quiet then
                    stalls = stalls + 1
                    engine.log(string.format("STALL game %d (%d vs %d) from frame %d: HP %d / %d, MP %d / %d", games,
                        a.record.id, b.record.id, last_change, a.hp, b.hp, a.mp, b.mp))
                end
                if still >= quiet then
                    stall_frames = stall_frames + 1
                    local na = a.smart_memory and a.smart_memory.note or "-"
                    local nb = b.smart_memory and b.smart_memory.note or "-"
                    notes_a[category(na)] = (notes_a[category(na)] or 0) + 1
                    notes_b[category(nb)] = (notes_b[category(nb)] or 0) + 1
                    local sb = "s" .. b.record.frame(b.frame).state
                    states_b[sb] = (states_b[sb] or 0) + 1
                    if config.show and still % config.show == 0 then
                        engine.log(string.format("  frame %d: %d in %d (%s) MP %d [%s] | %d in %d (%s) MP %d [%s] | dx %d dz %d", tick,
                            a.record.id, a.frame, tostring(a.record.frame(a.frame).name), a.mp, na, b.record.id, b.frame,
                            tostring(b.record.frame(b.frame).name), b.mp, nb, b.x_int - a.x_int, b.z_int - a.z_int))
                    end
                end
                if state.round_counter > 0 then break end
            end
            if a.hp > 0 and b.hp > 0 then draws = draws + 1 end
        end
    end
    engine.log(string.format("STALLS %d: %d of %d frames, %d games, %d draws", stalls, stall_frames, frames, games, draws))
    engine.log("STALL notes of the first fighter: " .. top(notes_a, 14))
    engine.log("STALL notes of the second fighter: " .. top(notes_b, 14))
    engine.log("STALL frame states of the second fighter: " .. top(states_b, 8))
end
return job
