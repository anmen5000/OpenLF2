-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors
-- Training for XOI (base/game/smart_ai): many games of each pair of fighters, both played by the INSANE! player,
-- and what each fighter's moves brought against the other written down as the notes XOI plays with — lines
-- starting "XOI ", which xoi-hoc.bat (or `grep "^XOI "`) gathers into the mod's xoi/notes.txt:
--   XOI G <a> <b> <games> <wins> <draws>       fighter a's games against fighter b
--   XOI R <a> <b> <starts> <hits>              a's moves started at a risk, and how many of them b struck first
--   XOI M <a> <b> <move> <starts> <landed> <struck first> <dealt> <taken> <expected>
--                                              each move a chose as an attack against b: how often it landed,
--                                              how often a was hit before it did, the damage dealt and taken
--                                              while it ran (follow-ups included) and what it was expected to
--                                              bring (the attack's score with the wait for the blow taken out)
-- config.pairs of fighter ids, or config.ids (every pair of them, each once; "all": every fighter of the mod),
-- config.games per pair (the sides swap every game); config.part and config.parts: this job plays only its share
-- of the pairs (the part-th of every `parts`), so that many jobs side by side share the work (xoi-hoc.bat).
-- config.brains = {"smart", "smart"} by default ("xoi" plays with the notes given, to train further on top of
-- them: config.notes names a module of this package returning {text = <the notes>}). Each pair's lines are written as
-- soon as its games are over, so that a job stopped half-way keeps what it did; a game that fails is left out.
local catalog = require("base/game/catalog")
local match = require("base/game/match")
local constants = require("base/game/constants")
local brains = require("bench/brains")
local learn = {}

local function find(fighters, id)
    for index, fighter in ipairs(fighters) do if fighter.id == id then return index end end
    error("no fighter " .. tostring(id))
end

local function sorted_keys(list)
    local keys = {}
    for key in pairs(list) do keys[#keys + 1] = key end
    table.sort(keys, function(x, y) return tostring(x) < tostring(y) end)
    return keys
end

function learn.run(config)
    local smart = require("base/game/smart_ai")
    if config.notes then smart.use_notes(require("bench/" .. config.notes).text) end
    local names = config.brains or {"smart", "smart"}
    for _, name in ipairs(names) do brains.load(name) end
    engine.log(string.format("learn: %s against %s", brains.label(names[1]), brains.label(names[2])))
    local fighters = catalog.load()
    local backgrounds = catalog.backgrounds()
    local all = {}
    for _, pair in ipairs(config.pairs or {}) do all[#all + 1] = pair end
    if config.ids then
        local ids = config.ids
        if ids == "all" then
            -- (A mod may list an id twice: once is enough.)
            ids = {}
            local seen = {}
            for _, fighter in ipairs(fighters) do
                if not seen[fighter.id] then seen[fighter.id] = true; ids[#ids + 1] = fighter.id end
            end
        end
        for i = 1, #ids do for j = i + 1, #ids do all[#all + 1] = {ids[i], ids[j]} end end
    end
    local list = {}
    local parts, part = config.parts or 1, config.part or 1
    for index, pair in ipairs(all) do
        if (index - 1) % parts == part - 1 then list[#list + 1] = pair end
    end
    engine.log(string.format("learn: %d pairs of %d (part %d of %d), %d games each", #list, #all, part, parts, config.games or 10))

    -- What happens while a move chosen as an attack runs: from its start until it is over and the fighter has had
    -- a few frames to be punished in (longer for a follow-up started meanwhile), or another attack begins.
    local open = {} -- by fighter (the item)
    local tick = 0
    local records -- [a][b] of the pair being played
    local function moves_of(a, b)
        local mine = records[a]
        if not mine then mine = {}; records[a] = mine end
        local entry = mine[b]
        if not entry then entry = {games = 0, wins = 0, draws = 0, risk_starts = 0, risk_hits = 0, moves = {}}; mine[b] = entry end
        return entry
    end
    local function close(window)
        local m = moves_of(window.a, window.b).moves
        local row = m[window.key]
        if not row then row = {0, 0, 0, 0, 0, 0}; m[window.key] = row end
        row[1] = row[1] + 1
        if window.landed then row[2] = row[2] + 1 end
        if window.cut then row[3] = row[3] + 1 end
        row[4], row[5], row[6] = row[4] + window.dealt, row[5] + window.taken, row[6] + window.expected
    end
    local foe_of = {}
    smart.on_start = function(self, move, t, score)
        local window = open[self]
        local busy = math.max(move.ready or 0, move.length or 0)
        if score and foe_of[self] then
            if window then close(window) end
            local key, foe = smart.note_key(move), foe_of[self]
            -- (What the move was expected to bring before XOI weighed it by the notes it plays with.)
            if self.brain == "xoi" then
                local notes = smart.pair_notes(self.record.id, foe.record.id)
                local factor = notes and notes.factor[key]
                if factor then score = score / factor end
            end
            open[self] = {a = self.record.id, b = foe.record.id, key = key,
                ends = tick + math.max(t or 0, busy) + 8, expected = math.max(score, 0) * ((t or 0) + 10) / 14,
                cost = math.max(move.hp or 0, 0), dealt = 0, taken = 0, landed = false, cut = false}
        elseif t and window then
            window.ends = math.max(window.ends, tick + math.max(t, busy) + 8)
        elseif window then
            close(window)
            open[self] = nil
        end
    end

    local function play_game(pair, game)
        local swap = game % 2 == 0
        local slot_of = swap and {11, 10} or {10, 11} -- pair[1] plays from slot_of[1]
        local options = {mode = constants.modes.versus, difficulty = config.difficulty or constants.difficulties.insane,
            background = config.background or constants.background_rows.random, fighters = fighters,
            backgrounds = backgrounds,
            slots = {[slot_of[1] - 10] = {kind = "computer", fighter = find(fighters, pair[1]), team = 1},
                [slot_of[2] - 10] = {kind = "computer", fighter = find(fighters, pair[2]), team = 2}}}
        local state = match.create(options)
        local a, b = state.items[slot_of[1]], state.items[slot_of[2]]
        a.brain, b.brain = names[1], names[2]
        open, foe_of = {}, {[a] = b, [b] = a}
        local hp = {[a] = a.hp, [b] = b.hp}
        local held = {functions = "", function_presses = "", keys = {}}
        tick = 0
        while tick < (config.limit or 9000) do
            tick = tick + 1
            match.step(state, held)
            for value, foe in pairs(foe_of) do
                local lost, foe_lost = math.max(hp[value] - value.hp, 0), math.max(hp[foe] - foe.hp, 0)
                local window = open[value]
                if window then
                    -- (A move's own price in HP, paid as it starts, is not a blow taken.)
                    if window.cost > 0 and not window.paid and lost > 0 and math.abs(lost - window.cost) <= 1 then
                        window.paid, lost = true, 0
                    end
                    if foe_lost > 0 then window.dealt, window.landed = window.dealt + foe_lost, true end
                    if lost > 2 then
                        window.taken = window.taken + lost
                        if not window.landed then window.cut = true end
                    end
                    if tick > window.ends then close(window); open[value] = nil end
                end
            end
            hp[a], hp[b] = a.hp, b.hp
            if state.round_counter > 0 then break end
        end
        for value, window in pairs(open) do close(window); open[value] = nil end
        local left_a, left_b = math.max(a.hp, 0), math.max(b.hp, 0)
        local mine, theirs = moves_of(pair[1], pair[2]), moves_of(pair[2], pair[1])
        mine.games, theirs.games = mine.games + 1, theirs.games + 1
        if left_a > 0 and left_b <= 0 then mine.wins = mine.wins + 1
        elseif left_b > 0 and left_a <= 0 then theirs.wins = theirs.wins + 1
        else mine.draws, theirs.draws = mine.draws + 1, theirs.draws + 1 end
        for value, entry in pairs({[a] = mine, [b] = theirs}) do
            local memory = value.smart_memory
            if memory then
                entry.risk_starts = entry.risk_starts + (memory.risk_starts or 0)
                entry.risk_hits = entry.risk_hits + (memory.risk_hits or 0)
            end
        end
        if config.verbose then
            engine.log(string.format("game %d of %d vs %d: hp %d - %d, %d ticks", game, pair[1], pair[2], left_a, left_b, tick))
        end
    end
    local failed = 0
    for number, pair in ipairs(list) do
        records = {}
        local pair_failed = 0
        for game = 1, config.games or 10 do
            -- (A game that fails — a fighter the versus mode cannot set up — counts for nothing; what it noted so
            -- far is dropped with it.)
            local kept = records
            records = {}
            for a, mine in pairs(kept) do
                records[a] = {}
                for b, entry in pairs(mine) do
                    local copy = {games = entry.games, wins = entry.wins, draws = entry.draws,
                        risk_starts = entry.risk_starts, risk_hits = entry.risk_hits, moves = {}}
                    for key, row in pairs(entry.moves) do copy.moves[key] = {row[1], row[2], row[3], row[4], row[5], row[6]} end
                    records[a][b] = copy
                end
            end
            local ok, problem = pcall(play_game, pair, game)
            if not ok then
                records = kept
                failed, pair_failed = failed + 1, pair_failed + 1
                engine.log(string.format("game %d of %d vs %d failed: %s", game, pair[1], pair[2], tostring(problem)))
                -- (A pair whose first games all fail is left.)
                if pair_failed >= 3 and pair_failed == game then break end
            end
        end
        for _, ids in ipairs({{pair[1], pair[2]}, {pair[2], pair[1]}}) do
            local entry = moves_of(ids[1], ids[2])
            engine.log(string.format("XOI G %d %d %d %d %d", ids[1], ids[2], entry.games, entry.wins, entry.draws))
            engine.log(string.format("XOI R %d %d %d %d", ids[1], ids[2], entry.risk_starts, entry.risk_hits))
            for _, key in ipairs(sorted_keys(entry.moves)) do
                local row = entry.moves[key]
                engine.log(string.format("XOI M %d %d %s %d %d %d %d %d %d", ids[1], ids[2], key, row[1], row[2], row[3],
                    row[4], row[5], math.floor(row[6] + 0.5)))
            end
        end
        local entry = moves_of(pair[1], pair[2])
        engine.log(string.format("pair %d of %d done: %d vs %d, %d - %d, draws %d", number, #list, pair[1], pair[2],
            entry.wins, moves_of(pair[2], pair[1]).wins, entry.draws))
    end
    smart.on_start = nil
    engine.log(string.format("LEARN DONE (%d games failed)", failed))
end
return learn
