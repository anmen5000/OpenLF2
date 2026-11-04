-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors
-- A match to watch, in the window: config.brains against each other on config.ids (two fighters, by id or by
-- name: bench/names), config.games games (sides swapped every other game), the score on the status line. The
-- match's own keys work: F1 pauses, F5 runs fast, F4 ends the game under way (the next begins; after the last one,
-- F4 closes the window). With config.command = "show":
--   {command = "show", brains = {"smart", "classic"}, ids = {4, 7}, games = 5}
--   {command = "show", brains = {"xoi", "smart"}, ids = {"Crimson", "Deep"}, games = 5}   -- XOI against INSANE!
--   {command = "show", brains = {"smart", "smart@ai_alt"}, ids = {1, 1}, games = 3}   -- two versions of INSANE!
-- config.background: the stage, by its row or its name (bench/names: "Lion Forest", "lf"), else a random one as
-- in LF2; config.limit: a game still on after that many ticks (default 9000, five minutes) counts as a draw and the
-- next begins (two computer players may stand off for good). A fighter or background named wrong: the window says
-- so, with the mod's fighters and backgrounds (windows/xem.bat).
local catalog = require("base/game/catalog")
local constants = require("base/game/constants")
local screen = require("base/ui/match_screen")
local controls = require("base/ui/controls")
local font = require("base/ui/font")
local brains = require("bench/brains")
local names = require("bench/names")
local show = {}

local function find(fighters, id)
    local index, problem = names.find(fighters, id)
    if not index then error(problem, 0) end
    return index
end

local function new_match(state)
    local config = state.config
    local game = state.played + 1
    local first, second = 1, 2
    if game % 2 == 0 then first, second = 2, 1 end
    local ids = config.ids or {config.pairs[1][1], config.pairs[1][2]}
    local options = {mode = constants.modes.versus, difficulty = config.difficulty or -1,
        background = state.background_row or constants.background_rows.random, fighters = state.fighters, backgrounds = state.backgrounds,
        slots = {[0] = {kind = "computer", fighter = find(state.fighters, ids[first]), team = 1},
            [1] = {kind = "computer", fighter = find(state.fighters, ids[second]), team = 2}}}
    state.screen = screen.create(options)
    -- (The F-keys count as held when a game begins, so that the F4 that ended the last one does not end this one.)
    state.screen.match.function_held = {true, true, true, true, true, true, true, true, true}
    local items = state.screen.match.items
    -- Brain 1 always plays ids[1]: slot 10 holds ids[first].
    items[10].brain = config.brains[first]
    items[11].brain = config.brains[second]
    state.sides = {[10] = first, [11] = second}
    state.linger = 0
    require("base/game/smart_ai").prepare(state.screen.match)
end

-- The lines the window shows when a fighter or the background is named wrong: what is wrong, then the mod's
-- fighters (id and name), or its backgrounds (row and name).
local function problem_lines(problem, entries, what)
    local lines = {problem, "", what == "background" and "The backgrounds of this mod (row name):" or "The fighters of this mod (id name):"}
    local row, seen = {}, {}
    for index, entry in ipairs(entries) do
        local label = what == "background" and string.format("%d %s", index - 1, names.background_name(entry))
            or string.format("%d %s", entry.id, entry.name)
        if what == "background" or not seen[entry.id] then
            if what ~= "background" then seen[entry.id] = true end
            row[#row + 1] = string.format("%-24s", label)
            if #row == 3 then lines[#lines + 1] = table.concat(row, " "); row = {} end
        end
    end
    if #row > 0 then lines[#lines + 1] = table.concat(row, " ") end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "F4 closes the window. Name them by number or name, as above, and start again."
    return lines
end

function show.create(config, options)
    controls.load(options.default_controller)
    for _, name in ipairs(config.brains or {}) do brains.load(name) end
    local state = {config = config, fighters = catalog.load(), backgrounds = catalog.backgrounds(), played = 0, wins = {0, 0}, draws = 0}
    state.labels = {brains.label(config.brains[1]), brains.label(config.brains[2])}
    local ids = config.ids or {config.pairs[1][1], config.pairs[1][2]}
    for side = 1, 2 do
        local index, problem = names.find(state.fighters, ids[side])
        if not index then
            engine.log("show: fighter " .. side .. ": " .. problem .. ". The fighters of this mod: " .. names.listing(state.fighters))
            state.problem = problem_lines(string.format("Fighter %d: %s.", side, problem), state.fighters)
            return state
        end
        engine.log(string.format("show: fighter %d: %d %s (%s)", side, state.fighters[index].id, state.fighters[index].name, state.labels[side]))
    end
    if config.background ~= nil and config.background ~= "" then
        local row, problem = names.background(state.backgrounds, config.background)
        if not row then
            engine.log("show: " .. problem)
            state.problem = problem_lines("Background: " .. problem .. ".", state.backgrounds, "background")
            return state
        end
        state.background_row = row
        engine.log(string.format("show: background %d %s", row, names.background_name(state.backgrounds[row + 1])))
    end
    new_match(state)
    return state
end

function show.update(state, raw, context)
    -- Done, or a fighter named wrong: F4 closes the window.
    if state.finished or state.problem then
        if raw and raw.functions and raw.functions:find("4", 1, true) and context.action then context.action("quit") end
        return
    end
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
    -- (A game at its limit, still undecided: a draw.)
    local timed_out = current.round_counter == 0 and (current.elapsed or 0) >= (state.config.limit or 9000)
    if requested == "round_over" or requested == "replay_error" or timed_out then
        local items = state.screen.match.items
        local hp = {}
        for slot, side in pairs(state.sides) do hp[side] = items[slot] and math.max(items[slot].hp, 0) or 0 end
        if timed_out then state.draws = state.draws + 1
        elseif hp[1] > 0 and hp[2] <= 0 then state.wins[1] = state.wins[1] + 1
        elseif hp[2] > 0 and hp[1] <= 0 then state.wins[2] = state.wins[2] + 1
        else state.draws = state.draws + 1 end
        state.played = state.played + 1
        engine.log(string.format("show: game %d: %s %d - %d %s (draws %d)%s", state.played, state.labels[1], state.wins[1], state.wins[2], state.labels[2], state.draws,
            timed_out and string.format(" - game %d stopped undecided after %d ticks", state.played, current.elapsed) or ""))
        if state.played < (state.config.games or 1) then new_match(state) else state.finished = true end
    end
end

function show.draw(state, context)
    if state.problem then
        context.viewport(794, 550, 0, 0, 0)
        for line, text in ipairs(state.problem) do font.gdi(context, text, 10, 10 + (line - 1) * 16, 0xffffff) end
        return
    end
    screen.draw(state.screen, context)
    local text = string.format("%s  %d - %d  %s%s   game %d/%d%s", state.labels[1], state.wins[1], state.wins[2], state.labels[2],
        state.draws > 0 and ("  (draws " .. state.draws .. ")") or "", math.min(state.played + 1, state.config.games or 1), state.config.games or 1,
        state.finished and "  done" or "")
    font.gdi(context, text, 3, 0x213, 0xffff00)
end

function show.describe(state)
    if state.problem then return "show: " .. state.problem[1] end
    return string.format("show game %d %d-%d", state.played, state.wins[1], state.wins[2])
end
return show
