-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors
-- A match to watch, in the window: config.brains against each other on config.ids (two fighter ids), config.games
-- games (sides swapped every other game), the score on the status line. The match's own keys work: F1 pauses,
-- F5 runs fast, F4 leaves the game. With config.command = "show":
--   {command = "show", brains = {"smart", "classic"}, ids = {4, 7}, games = 5}
--   {command = "show", brains = {"smart", "smart@ai_alt"}, ids = {1, 1}, games = 3}   -- two versions of INSANE!
local catalog = require("base/game/catalog")
local constants = require("base/game/constants")
local screen = require("base/ui/match_screen")
local controls = require("base/ui/controls")
local font = require("base/ui/font")
local brains = require("bench/brains")
local show = {}

local function find(fighters, id)
    for index, fighter in ipairs(fighters) do if fighter.id == id then return index end end
    error("no fighter " .. tostring(id))
end

local function new_match(state)
    local config = state.config
    local game = state.played + 1
    local first, second = 1, 2
    if game % 2 == 0 then first, second = 2, 1 end
    local ids = config.ids or {config.pairs[1][1], config.pairs[1][2]}
    local options = {mode = constants.modes.versus, difficulty = config.difficulty or -1,
        background = config.background or constants.background_rows.random, fighters = state.fighters, backgrounds = state.backgrounds,
        slots = {[0] = {kind = "computer", fighter = find(state.fighters, ids[first]), team = 1},
            [1] = {kind = "computer", fighter = find(state.fighters, ids[second]), team = 2}}}
    state.screen = screen.create(options)
    local items = state.screen.match.items
    -- Brain 1 always plays ids[1]: slot 10 holds ids[first].
    items[10].brain = config.brains[first]
    items[11].brain = config.brains[second]
    state.sides = {[10] = first, [11] = second}
    state.linger = 0
    require("base/game/smart_ai").prepare(state.screen.match)
end

function show.create(config, options)
    controls.load(options.default_controller)
    for _, name in ipairs(config.brains or {}) do brains.load(name) end
    local state = {config = config, fighters = catalog.load(), backgrounds = catalog.backgrounds(), played = 0, wins = {0, 0}, draws = 0}
    state.labels = {brains.label(config.brains[1]), brains.label(config.brains[2])}
    new_match(state)
    return state
end

function show.update(state, raw, context)
    if state.finished then return end
    local input = controls.read(controls.current(), raw)
    -- The fight over, the match shows its result until a player presses attack or jump; here nobody does, so
    -- after two seconds player 1's attack key is pressed for it and the next game begins.
    local current = state.screen.match
    if current.round_counter >= 144 then
        state.linger = (state.linger or 0) + 1
        if state.linger == 61 then input[0] = (input[0] or "") .. "c" end
    end
    local routed = {}
    for key, value in pairs(context) do routed[key] = value end
    local requested
    function routed.action(name) requested = name end
    screen.update(state.screen, input, routed)
    if requested == "title" then
        state.finished = true
        return
    end
    if requested == "round_over" or requested == "replay_error" then
        local items = state.screen.match.items
        local hp = {}
        for slot, side in pairs(state.sides) do hp[side] = items[slot] and math.max(items[slot].hp, 0) or 0 end
        if hp[1] > 0 and hp[2] <= 0 then state.wins[1] = state.wins[1] + 1
        elseif hp[2] > 0 and hp[1] <= 0 then state.wins[2] = state.wins[2] + 1
        else state.draws = state.draws + 1 end
        state.played = state.played + 1
        engine.log(string.format("show: game %d: %s %d - %d %s (draws %d)", state.played, state.labels[1], state.wins[1], state.wins[2], state.labels[2], state.draws))
        if state.played < (state.config.games or 1) then new_match(state) else state.finished = true end
    end
end

function show.draw(state, context)
    screen.draw(state.screen, context)
    local text = string.format("%s  %d - %d  %s%s   game %d/%d%s", state.labels[1], state.wins[1], state.wins[2], state.labels[2],
        state.draws > 0 and ("  (draws " .. state.draws .. ")") or "", math.min(state.played + 1, state.config.games or 1), state.config.games or 1,
        state.finished and "  done" or "")
    font.gdi(context, text, 3, 0x213, 0xffff00)
end

function show.describe(state)
    return string.format("show game %d %d-%d", state.played, state.wins[1], state.wins[2])
end
return show
