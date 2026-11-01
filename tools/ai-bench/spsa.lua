-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors
-- Tuning the INSANE! player's judgement by play: SPSA (Spall's simultaneous perturbation stochastic approximation,
-- the way chess engines tune their numbers) over smart.tune_ranges in scripts/base/game/smart_ai.lua.
-- Each iteration nudges every number at once by the same share of its range, each up or down at random, and lets
-- the numbers nudged one way (base/game/smart_ai, "smart") fight those nudged the other way (a copy of the same
-- file in this package as spsa_alt.lua, "smart@spsa_alt"): two games on one stage, each version playing each
-- fighter of a random pair; then every number moves toward the side that did better, by how much better.
-- A run is one chain of iterations; many chains run side by side (windows/spsa.bat) and their numbers are
-- averaged between rounds (step "merge"); step "check" plays tuned numbers against the AI's own.
--
-- config (command = "spsa"):
--   step       "chain" (default), "merge" or "check"
--   start      module of this package returning the numbers to start from (name = value); the AI's own when absent
--   names      the numbers to tune (all of smart.tune_ranges by default)
--   iterations game pairs in this run; first: iterations this chain did before (for the gains); total: all it will do
--   a, c       gains, as shares of each number's range: a the step size, c the nudge (defaults 0.02 and 0.08),
--              decaying as a / (total / 10 + k)^0.602 and c / k^0.101 at the chain's k-th iteration
--   seed       the chain's own random numbers (pairs, stages, nudges)
--   ids        fighter ids to draw pairs from (all a player can choose when absent); limit: frames per game
--   chains     (merge) module returning the chains' end numbers, {{name = value, ...}, ...}
--   games      (check) game pairs to play
-- Output: "SPSA it ..." per iteration and the chain's end numbers as "{...}, --SPSA_END"; the merge prints the
-- average as "return {...} --SPSA_START" and a readable list; the check prints "SPSA_CHECK <tuned wins> <own wins>
-- <draws> <result>".
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

-- The numbers to tune: {name, default, low, high, integer} from smart.tune_ranges.
local function numbers(names)
    local wanted
    if names then
        wanted = {}
        for _, name in ipairs(names) do wanted[name] = true end
    end
    local list = {}
    for _, entry in ipairs(require("base/game/smart_ai").tune_ranges) do
        if not wanted or wanted[entry[1]] then
            list[#list + 1] = {name = entry[1], default = entry[2], low = entry[3], high = entry[4], integer = entry[5]}
        end
    end
    return list
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
        for _ = 1, config.limit or 9000 do
            match.step(state, held)
            if state.round_counter > 0 then break end
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
    engine.log(string.format("SPSA chain: %d numbers, %d iterations from %d (of %s), %d fighters, %d stages, a %.4g c %.4g, seed %d",
        #list, iterations, first, tostring(config.total or "?"), #pool, #backgrounds, a, c, config.seed or 1))
    local sum, played = 0, 0
    for iteration = 1, iterations do
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
        end
    end
    local values = {}
    for index, number in ipairs(list) do values[number.name] = value_at(number, u[index]) end
    engine.log(string.format("{%s}, --SPSA_END", format_numbers(list, values)))
    engine.log(string.format("SPSA chain done: %d of %d iterations played, mean result %.3f", played, iterations, sum / max(played, 1)))
end

local function merge(config)
    local list = numbers(config.names)
    local chains = require("bench/" .. (config.chains or "spsa_chains"))
    local start = config.start and require("bench/" .. config.start) or {}
    assert(#chains > 0, "no chain finished this round")
    local values = {}
    for _, number in ipairs(list) do
        local total = 0
        for _, values_of in ipairs(chains) do total = total + (values_of[number.name] or start[number.name] or number.default) end
        values[number.name] = total / #chains
    end
    engine.log(string.format("return {%s} --SPSA_START", format_numbers(list, values)))
    engine.log(string.format("SPSA merge: %d chains", #chains))
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
    for _, entry in ipairs(alt.tune_ranges) do defaults[entry[1]] = entry[2] end
    alt.set_tune(defaults)
    local fighters, backgrounds = catalog.load(), catalog.backgrounds()
    local pool = choices(config, fighters)
    local random = generator(config.seed or 1)
    local wins, losses, draws, sum = 0, 0, 0, 0
    for _ = 1, config.games or 20 do
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
