-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors
-- Tuning XOI's judgement by play: SPSA (Spall's simultaneous perturbation stochastic approximation, the way chess
-- engines tune their numbers) over smart.tune_ranges in scripts/base/game/smart_ai.lua, from XOI's own numbers
-- (smart.xoi_tune over INSANE!'s; the numbers tuned so are XOI's alone: a mod's xoi/tune.txt, or smart.xoi_tune).
-- The games are played by the AI without XOI's notes, both sides with the numbers the tuner sets.
-- Each iteration nudges every number at once by the same share of its range, each up or down at random, and lets
-- the numbers nudged one way (base/game/smart_ai, "smart") fight those nudged the other way (a copy of the same
-- file in this package as spsa_alt.lua, "smart@spsa_alt"): two games on one stage, each version playing each
-- fighter of a random pair; then every number moves toward the side that did better, by how much better.
-- A run is one chain of iterations; many chains run side by side (windows/spsa.bat) and their numbers are
-- averaged between rounds (step "merge"); step "check" plays tuned numbers against XOI's own (or a base).
--
-- config (command = "spsa"):
--   step       "chain" (default), "merge" or "check"
--   start      module of this package returning the numbers to start from (name = value); XOI's own when absent
--   names      the numbers to tune (all of smart.tune_ranges by default)
--   iterations game pairs in this run (at most); first: iterations this chain did before (for the gains); total: all
--              it will do
--   seconds    stop after the game pair under way once this many seconds have gone by (the engine's clock): all the
--              chains of a round, started together, end together, the fast ones not waiting idle for the slow ones;
--              each chain then reports how many pairs it played (n) and its mod (mod: a number the caller gives)
--   report     every this many pairs (10), the chain's numbers so far as "{n = ..., mod = ..., ...}, --SPSA_STATE",
--              so that a round stopped half way (a closed window) keeps what it did
--   a, c       gains, as shares of each number's range: a the step size, c the nudge (defaults 0.02 and 0.08),
--              decaying as a / (total / 10 + k)^0.602 and c / k^0.101 at the chain's k-th iteration
--   seed       the chain's own random numbers (pairs, stages, nudges)
--   ids        fighter ids to draw pairs from (all a player can choose when absent); limit: frames per game
--   stall      a game in which nobody loses HP for this many frames ends there (default 1800, a minute; 0: never),
--              scored as at the limit: a mod's training dummy that only stands, or two fighters that cannot reach
--              each other, says nothing about the numbers and only costs time
--   chains     (merge) module returning the chains' end numbers, {{name = value, ...}, ...}; with n (pairs played)
--              and mod in them, each mod's mean step per pair, the mods weighing the same, times the chains' mean n
--              (chains of any length, cut short ones too); first: the round's first k, for "SPSA_K <next first>"
--   games      (check) game pairs to play (at most, with seconds)
--   base       (check) module of this package with the numbers to check against (name = value; the run's start,
--              say); XOI's own when absent
-- Output: "SPSA it ..." per iteration and the chain's end numbers as "{n = ..., mod = ..., ...}, --SPSA_END"; the
-- merge prints the new numbers as "return {...} --SPSA_START", a readable list, "SPSA_PAIRS <pairs>", "SPSA_MODS
-- <mod>:<pairs>/<chains> ..." and "SPSA_K <k>"; the check prints "SPSA_CHECK <tuned wins> <own wins> <draws> <result>".
local catalog = require("base/game/catalog")
local match = require("base/game/match")
local constants = require("base/game/constants")
local brains = require("bench/brains")
local spsa = {}
local floor, max, min = math.floor, math.max, math.min

-- Random numbers of the chain's own (Park and Miller's minimal standard generator: exact in doubles, the same in
-- Lua 5.2 and LuaJIT), 1 to n.
local function generator(seed)
    local x = floor(seed) % 2147483646 + 1
    return function(n)
        x = x * 16807 % 2147483647
        return x % n + 1
    end
end

-- The numbers to tune: {name, default, low, high, integer} from smart.tune_ranges, the default XOI's own (INSANE!'s
-- where XOI has none of its own; scripts older than version 31 have no smart.xoi_own: theirs).
local function numbers(names)
    local wanted
    if names then
        wanted = {}
        for _, name in ipairs(names) do wanted[name] = true end
    end
    local list = {}
    local smart = require("base/game/smart_ai")
    local own = smart.xoi_own or {}
    for _, entry in ipairs(smart.tune_ranges) do
        if not wanted or wanted[entry[1]] then
            list[#list + 1] = {name = entry[1], default = own[entry[1]] or entry[2], low = entry[3], high = entry[4], integer = entry[5]}
        end
    end
    return list
end
-- Seconds on the engine's steady clock (nil where there is none): time boxes, not game logic.
local function clock_seconds()
    local clock = engine.network_time
    return clock and clock() / 1000 or nil
end
local function share(number, value) return min(1, max(0, (value - number.low) / (number.high - number.low))) end
local function value_at(number, u) return number.low + min(1, max(0, u)) * (number.high - number.low) end
local function format_numbers(list, values)
    local parts = {}
    for _, number in ipairs(list) do parts[#parts + 1] = string.format("%s = %.6g", number.name, values[number.name]) end
    return table.concat(parts, ", ")
end

local function players(config)
    local smart = require("base/game/smart_ai")
    local alt = brains.load("smart@" .. (config.alt or "spsa_alt"))
    assert(alt and alt.set_tune and alt.tune_ranges,
        (config.alt or "spsa_alt") .. ".lua must be a copy of scripts/base/game/smart_ai.lua with smart.tune_ranges")
    assert(smart.set_tune, "scripts/base/game/smart_ai.lua has no smart.tune_ranges: the scripts are older than the tuner")
    -- (The numbers are the tuner's to set: not the mod's own, xoi/tune.txt, at each game's start, nor each level's at
    -- each player's frame. Both sides start from XOI's own; the tuner lays its numbers over them.)
    smart.tune_fixed, alt.tune_fixed = true, true
    if smart.xoi_own then smart.set_tune(smart.xoi_own) end
    if alt.xoi_own then alt.set_tune(alt.xoi_own) end
    return smart, alt
end

-- The fighters pairs are drawn from: config.ids, or every one a player can choose (no hidden ones).
local function choices(config, fighters)
    local list = {}
    local by_id = {}
    for index, fighter in ipairs(fighters) do by_id[fighter.id] = by_id[fighter.id] or index end
    if config.ids then
        for _, id in ipairs(config.ids) do
            if by_id[id] then list[#list + 1] = by_id[id] end
        end
    else
        for index, fighter in ipairs(fighters) do
            if not fighter.hidden then list[#list + 1] = index end
        end
    end
    assert(#list > 0, "no fighters to draw pairs from")
    return list
end

-- One game: "smart" plays fighters[first] (slot 0) against "smart@<alt>" with fighters[second] (slot 1), or the
-- other way round with `swap`. Its result for "smart": +1 a win, -1 a loss, 0 a draw, plus the HP it was left with
-- above the other's, as a share of 500 (within -1 and 1). Nil when the game could not be set up.
local function play(config, fighters, backgrounds, row, first, second, swap)
    local ok, result = pcall(function()
        local smart_slot = swap and 1 or 0
        local slots = {[0] = {kind = "computer", fighter = first, team = 1}, [1] = {kind = "computer", fighter = second, team = 2}}
        local state = match.create({mode = constants.modes.versus, difficulty = config.difficulty or -2, background = row,
            fighters = fighters, backgrounds = backgrounds, slots = slots})
        local own, other = state.items[10 + smart_slot], state.items[11 - smart_slot]
        own.brain, other.brain = "smart", "smart@" .. (config.alt or "spsa_alt")
        local held = {functions = "", function_presses = "", keys = {}}
        local stall, quiet, own_hp, other_hp = config.stall or 1800, 0, own.hp, other.hp
        for _ = 1, config.limit or 9000 do
            match.step(state, held)
            if state.round_counter > 0 then break end
            if own.hp < own_hp or other.hp < other_hp then quiet = 0 else quiet = quiet + 1 end
            own_hp, other_hp = own.hp, other.hp
            if stall > 0 and quiet >= stall then break end
        end
        local mine, theirs = max(own.hp, 0), max(other.hp, 0)
        local score = 0
        if mine > 0 and theirs <= 0 then score = 1 elseif theirs > 0 and mine <= 0 then score = -1 end
        return score + max(-1, min(1, (mine - theirs) / 500))
    end)
    if not ok then
        engine.log("SPSA game failed: " .. tostring(result))
        return nil
    end
    return result
end

local function chain(config)
    local smart, alt = players(config)
    local list = numbers(config.names)
    local start = config.start and require("bench/" .. config.start) or {}
    local u = {}
    for index, number in ipairs(list) do u[index] = share(number, start[number.name] or number.default) end
    local fighters, backgrounds = catalog.load(), catalog.backgrounds()
    local pool = choices(config, fighters)
    local random = generator(config.seed or 1)
    local a, c = config.a or 0.02, config.c or 0.08
    local alpha, gamma = config.alpha or 0.602, config.gamma or 0.101
    local iterations = config.iterations or 20
    local first = config.first or 0
    local stability = max(1, floor((config.total or (first + iterations)) / 10))
    local seconds, report, mod = config.seconds, config.report or 10, config.mod or 1
    local began = seconds and clock_seconds()
    local function numbers_now()
        local values = {}
        for index, number in ipairs(list) do values[number.name] = value_at(number, u[index]) end
        return values
    end
    engine.log(string.format("SPSA chain: %d numbers, %d iterations from %d (of %s), %d fighters, %d stages, a %.4g c %.4g, seed %d",
        #list, iterations, first, tostring(config.total or "?"), #pool, #backgrounds, a, c, config.seed or 1))
    local sum, played, timed_out = 0, 0, false
    for iteration = 1, iterations do
        if began and clock_seconds() - began >= seconds then timed_out = true; break end
        local k = first + iteration
        local nudge = c / k ^ gamma
        local step = a / (stability + k) ^ alpha
        local signs, plus, minus = {}, {}, {}
        for index, number in ipairs(list) do
            signs[index] = random(2) == 1 and 1 or -1
            plus[number.name] = value_at(number, u[index] + nudge * signs[index])
            minus[number.name] = value_at(number, u[index] - nudge * signs[index])
        end
        local first_fighter, second_fighter = pool[random(#pool)], pool[random(#pool)]
        local row = random(#backgrounds) - 1
        smart.set_tune(plus)
        alt.set_tune(minus)
        local one = play(config, fighters, backgrounds, row, first_fighter, second_fighter, false)
        local two = play(config, fighters, backgrounds, row, first_fighter, second_fighter, true)
        if one and two then
            local y = one + two
            for index = 1, #list do u[index] = min(1, max(0, u[index] + step * y / (2 * nudge) * signs[index])) end
            sum, played = sum + y, played + 1
            engine.log(string.format("SPSA it %d k %d fighters %d %d stage %d result %.3f", iteration, k,
                fighters[first_fighter].id, fighters[second_fighter].id, row, y))
            if played % report == 0 then
                engine.log(string.format("{n = %d, mod = %d, %s}, --SPSA_STATE", played, mod, format_numbers(list, numbers_now())))
            end
        end
    end
    engine.log(string.format("{n = %d, mod = %d, %s}, --SPSA_END", played, mod, format_numbers(list, numbers_now())))
    engine.log(string.format("SPSA chain done: %d game pairs played%s, mean result %.3f", played,
        timed_out and string.format(" in %d seconds", seconds) or string.format(" of %d", iterations), sum / max(played, 1)))
end

local function merge(config)
    local list = numbers(config.names)
    local chains = require("bench/" .. (config.chains or "spsa_chains"))
    local start = config.start and require("bench/" .. config.start) or {}
    assert(#chains > 0, "no chain finished this round")
    local values = {}
    local function start_value(number) return start[number.name] or number.default end
    if chains[1].n then
        -- Chains of different lengths (stopped by the clock, or cut short with their last report): each mod's mean
        -- step per game pair, every mod weighing the same, times the pairs a chain played on average.
        local by_mod, mods, pairs_played, chains_played = {}, {}, 0, 0
        for _, ended in ipairs(chains) do
            local n = ended.n or 0
            if n > 0 then
                local m = ended.mod or 1
                local entry = by_mod[m]
                if not entry then
                    entry = {n = 0, chains = 0, sums = {}}
                    by_mod[m], mods[#mods + 1] = entry, m
                end
                entry.n, entry.chains = entry.n + n, entry.chains + 1
                pairs_played, chains_played = pairs_played + n, chains_played + 1
                for _, number in ipairs(list) do
                    local moved = share(number, ended[number.name] or start_value(number)) - share(number, start_value(number))
                    entry.sums[number.name] = (entry.sums[number.name] or 0) + moved
                end
            end
        end
        assert(#mods > 0, "no chain played a game pair this round")
        table.sort(mods)
        local per_chain = pairs_played / chains_played
        for _, number in ipairs(list) do
            local step = 0
            for _, m in ipairs(mods) do step = step + by_mod[m].sums[number.name] / by_mod[m].n end
            values[number.name] = value_at(number, share(number, start_value(number)) + per_chain * step / #mods)
        end
        local parts = {}
        for _, m in ipairs(mods) do parts[#parts + 1] = string.format("%d:%d/%d", m, by_mod[m].n, by_mod[m].chains) end
        engine.log(string.format("return {%s} --SPSA_START", format_numbers(list, values)))
        engine.log(string.format("SPSA merge: %d chains, %d game pairs, %.0f a chain", chains_played, pairs_played, per_chain))
        engine.log(string.format("SPSA_PAIRS %d", pairs_played))
        engine.log("SPSA_MODS " .. table.concat(parts, " "))
        engine.log(string.format("SPSA_K %d", (config.first or 0) + floor(per_chain + 0.5)))
    else
        for _, number in ipairs(list) do
            local total = 0
            for _, values_of in ipairs(chains) do total = total + (values_of[number.name] or start_value(number)) end
            values[number.name] = total / #chains
        end
        engine.log(string.format("return {%s} --SPSA_START", format_numbers(list, values)))
        engine.log(string.format("SPSA merge: %d chains", #chains))
    end
    for _, number in ipairs(list) do
        local value = values[number.name]
        local before = start[number.name] or number.default
        engine.log(string.format("SPSA_LIST %-20s %10.4g  (default %g, range %g to %g; this round %+.1f%% of the range)",
            number.name, value, number.default, number.low, number.high, 100 * (value - before) / (number.high - number.low)))
    end
end

local function check(config)
    local smart, alt = players(config)
    local start = config.start and require("bench/" .. config.start) or {}
    smart.set_tune(start)
    local defaults = {}
    for _, entry in ipairs(alt.tune_ranges) do defaults[entry[1]] = (alt.xoi_own or {})[entry[1]] or entry[2] end
    alt.set_tune(defaults)
    if config.base then alt.set_tune(require("bench/" .. config.base)) end
    local fighters, backgrounds = catalog.load(), catalog.backgrounds()
    local pool = choices(config, fighters)
    local random = generator(config.seed or 1)
    local wins, losses, draws, sum = 0, 0, 0, 0
    local seconds = config.seconds
    local began = seconds and clock_seconds()
    for _ = 1, config.games or 20 do
        if began and clock_seconds() - began >= seconds then break end
        local first_fighter, second_fighter = pool[random(#pool)], pool[random(#pool)]
        local row = random(#backgrounds) - 1
        for _, swap in ipairs({false, true}) do
            local result = play(config, fighters, backgrounds, row, first_fighter, second_fighter, swap)
            if result then
                -- (A win leaves HP above the loser's: more than 1; a loss less than -1; a draw in between.)
                sum = sum + result
                if result > 1 then wins = wins + 1 elseif result < -1 then losses = losses + 1 else draws = draws + 1 end
            end
        end
    end
    engine.log(string.format("SPSA_CHECK %d %d %d %.3f", wins, losses, draws, sum))
end

function spsa.run(config)
    local step = config.step or "chain"
    if step == "chain" then chain(config)
    elseif step == "merge" then merge(config)
    elseif step == "check" then check(config)
    else error("spsa: unknown step " .. tostring(step)) end
end
return spsa
