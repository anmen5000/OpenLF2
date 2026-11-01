-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors
-- AI against AI: config.pairs of fighter ids (or config.ids, every one against every other), config.brains =
-- {"smart", "classic"}, config.games per pair.
-- A brain "smart@<module>" is another version of the INSANE! player: that version's smart_ai.lua copied into this
-- package as <module>.lua and listed in package.manifest (`module=<module>|<module>.lua`), so that two versions of
-- the AI fight each other (brains = {"smart", "smart@ai_alt"}).
local catalog = require("base/game/catalog")
local match = require("base/game/match")
local constants = require("base/game/constants")
local duel = {}
local state_last
local function find(fighters, id)
    for index, fighter in ipairs(fighters) do if fighter.id == id then return index end end
    error("no fighter " .. tostring(id))
end
local brains = require("bench/brains")
local other_brain, label = brains.load, brains.label
function duel.run(config)
    -- config.notes: a module of this package returning {text = <notes>} for "xoi" (instead of the mod's xoi/notes.txt).
    if config.notes then require("base/game/smart_ai").use_notes(require("bench/" .. config.notes).text) end
    if config.no_ego then require("base/game/ai_scripts").ego = function() return nil end end
    if config.ego_hybrid then require("base/game/smart_ai").ego_hybrid = true end
    if config.no_prepare then require("base/game/smart_ai").prepare = function() end end
    for _, name in ipairs(config.brains or {}) do other_brain(name) end
    engine.log(string.format("brains: %s against %s", label(config.brains[1]), label(config.brains[2])))
    local fighters = catalog.load()
    local backgrounds = catalog.backgrounds()
    local wins, games, draws = {0, 0}, 0, 0
    local taken, dealt = {}, {}
    local function add(list, key, amount) list[key] = (list[key] or 0) + amount end
    local hp_left = {0, 0}
    local total_ticks = 0
    local usage, usage_records = {}, {}
    if config.usage then
        require("base/game/smart_ai").on_start = function(self, move)
            local id = self.record.id
            usage[id] = usage[id] or {}
            usage_records[id] = self.record
            usage[id][move.index] = (usage[id][move.index] or 0) + 1
        end
    end
    -- config.audit: how the blows were taken and given, per brain — attacks started and how many of them were
    -- interrupted before they landed (by a foe that was free when we started: it struck later and landed first;
    -- or by one already in a move: we walked into it), hits taken from a foe just up from the ground (within its
    -- get-up blink), hits taken with the back to a wall, trades (both hit within two frames), and what we were
    -- doing when hit (the decision's first words).
    local audit
    if config.audit then
        audit = {}
        for brain = 1, 2 do
            audit[brain] = {starts = 0, interrupted_free = 0, interrupted_busy = 0, interrupted_damage = 0, landed = 0,
                hits_taken = 0, damage_taken = 0, getup_hits = 0, getup_damage = 0, wall_hits = 0, wall_damage = 0,
                trades = 0, doing = {}, by_foe_move = {}}
        end
    end
    local excluded_counts = {}
    if audit then
        local function hook(module)
            module.on_exclude = function(self, move, reason, t)
                local key = (self.brain or "?") .. " " .. reason
                excluded_counts[key] = (excluded_counts[key] or 0) + 1
                if config.exclusions then
                    local e = move.entry
                    engine.log(string.format("%5d EXCLUDE %s %s %s t%d (me x%d z%d f%d)", state_last.frame_number, self.brain, reason, e.field or e.basic or ("chain " .. tostring(e.key)), t, self.x_int, self.z_int, self.frame))
                end
            end
        end
        hook(require("base/game/smart_ai"))
        for _, name in ipairs(config.brains or {}) do
            local module = name:match("^smart@(.+)$")
            if module then pcall(function() hook(require("bench/" .. module)) end) end
        end
    end
    local free_states = {[0] = true, [1] = true, [2] = true, [4] = true, [7] = true}
    local function is_free_state(v) return free_states[v.record.frame(v.frame).state] == true end
    -- The pairs: config.pairs as they are, and with config.ids (a list, or "all": every fighter of the mod) every
    -- fighter against every other, each way round (brains[1] plays each of the two); config.part of config.parts
    -- takes a share of those matchups, so that jobs side by side split a round of all against all
    -- (dau-nhieu.bat).
    local list = {}
    for _, pair in ipairs(config.pairs or {}) do list[#list + 1] = pair end
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
        -- (Their names, for a summary: "fighter <id> <name>".)
        for _, id in ipairs(ids) do
            for _, fighter in ipairs(fighters) do
                if fighter.id == id then engine.log(string.format("fighter %d %s", id, fighter.name)); break end
            end
        end
        local parts, part, number = config.parts or 1, config.part or 1, 0
        for i = 1, #ids do
            for j = i + 1, #ids do
                if number % parts == part - 1 then
                    list[#list + 1] = {ids[i], ids[j]}
                    list[#list + 1] = {ids[j], ids[i]}
                end
                number = number + 1
            end
        end
        engine.log(string.format("duel: %d pairs (part %d of %d), %d games each", #list, part, parts, config.games))
    end
    local failed = 0
    for _, pair in ipairs(list) do
        local pair_wins = {0, 0}
        for game = 1, config.games do
            -- (A game that fails — a fighter the versus mode cannot set up — is left out and said so.)
            local ok, problem = pcall(function()
                local swap = game % 2 == 0
                local first, second = 1, 2
                if swap then first, second = 2, 1 end
                local ids = {pair[1], pair[2]}
                local options = {mode = constants.modes.versus, difficulty = config.difficulty or -1,
                    background = config.background or constants.background_rows.random, fighters = fighters,
                    backgrounds = backgrounds,
                    slots = {[0] = {kind = "computer", fighter = find(fighters, ids[first]), team = 1},
                        [1] = {kind = "computer", fighter = find(fighters, ids[second]), team = 2}}}
                local state = match.create(options)
                state_last = state
                -- Brain 1 always plays pair[1].
                if not config.nobrain then
                    state.items[10].brain = config.brains[first]
                    state.items[11].brain = config.brains[second]
                end
                local held = {functions = "", function_presses = "", keys = {}}
                local ticks = 0
                local last_hp = {[10] = state.items[10].hp, [11] = state.items[11].hp}
                local notes = {[10] = {}, [11] = {}}
                local track = {[10] = {hp = state.items[10].hp, note = "-", free = true, lying_at = -999, hit_at = -999},
                    [11] = {hp = state.items[11].hp, note = "-", free = true, lying_at = -999, hit_at = -999}}
                local function brain_of(slot) return slot == 10 and first or second end
                while ticks < (config.limit or 5400) do
                    local before = {}
                    for _, slot in ipairs({10, 11}) do
                        local v = state.items[slot]
                        if v then before[slot] = {hp = v.hp, note = v.smart_memory and v.smart_memory.note or "-", frame = v.frame} end
                    end
                    if config.probe and config.probe[ticks + 1] and state.items[10] and state.items[11] then
                        local smart = require("base/game/smart_ai")
                        local I = smart.internals
                        for _, slot in ipairs({10, 11}) do
                            local v = state.items[slot]
                            if v.brain == "smart" then
                                local o = state.items[slot == 10 and 11 or 10]
                                local context = state.smart_context
                                if context then
                                    local t, box, src = I.earliest_threat(state, slot, v, 16, nil, 1, context)
                                    local a = I.analyze(o.record)
                                    local w = I.where_of(o.record, a, o)
                                    engine.log(string.format("probe %d: me f%d x%d z%d facing%d lock%d b8 %d | foe f%d wc%d x%d z%d facing%d where %s t%s | threat %s inj %s bd %s melee %d danger %.1f",
                                        ticks + 1, v.frame, v.x_int, v.z_int, v.facing, v.defend_lock or -1, v.timer_b8, o.frame, o.wait_counter, o.x_int, o.z_int, o.facing,
                                        w and (w.move.entry.field or w.move.entry.basic or "?") or "-", w and w.t or "-", tostring(t), box and box.injury or "-", box and box.bdefend or "-",
                                        I.melee_reach(a), I.danger_at(o, a, v.x_int, v.z_int)))
                                end
                            end
                        end
                    end
                    if config.probe then
                        local smart = require("base/game/smart_ai")
                        local now_tick = ticks + 1
                        smart.trace = function(_, index, text)
                            if config.probe[now_tick] then engine.log(string.format("trace %d slot %d: %s", now_tick, index, text)) end
                        end
                    end
                    if config.hash and games == 0 and ticks < config.hash then
                        local _, rindex, rseq = engine.random_state()
                        local a, b = state.items[10], state.items[11]
                        local n = 0
                        for i = 0, 399 do if state.items[i] then n = n + 1 end end
                        local function keys_of(v)
                            local list = {}
                            for _, k in ipairs({"up", "down", "left", "right", "attack", "jump", "defend"}) do if v.keys[k] then list[#list + 1] = k:sub(1, 2) end end
                            return table.concat(list, ",")
                        end
                        engine.log(string.format("h %d p" .. require("base/game/smart_ai").plays .. " r%d/%d n%d | %d %d %d f%d hp%d mp%d k%s %s | %d %d %d f%d hp%d mp%d k%s", ticks, rindex, rseq or -1, n,
                            a.x_int, a.y_int, a.z_int, a.frame, a.hp, a.mp, keys_of(a), a.smart_memory and a.smart_memory.note or "-", b.x_int, b.y_int, b.z_int, b.frame, b.hp, b.mp, keys_of(b)))
                    end
                    local saved_random
                    if config.rngtrace and config.rngtrace == ticks + 1 and games == 0 then
                        saved_random = engine.random
                        engine.random = function(n)
                            local r = saved_random(n)
                            local info = debug.getinfo(2, "Sl")
                            local info3 = debug.getinfo(3, "Sl")
                            local info4 = debug.getinfo(4, "Sl")
                            engine.log(string.format("rng(%s)=%s at %s:%s < %s:%s < %s:%s", tostring(n), tostring(r), info.short_src, info.currentline,
                                info3 and info3.short_src or "", info3 and info3.currentline or "", info4 and info4.short_src or "", info4 and info4.currentline or ""))
                            return r
                        end
                    end
                    match.step(state, held)
                    if saved_random then engine.random = saved_random end
                    ticks = ticks + 1
                    if audit and state.items[10] and state.items[11] then
                        local width = state.stage_bound > 0 and state.stage_bound or (state.stage.width or 794)
                        for _, slot in ipairs({10, 11}) do
                            local v, o = state.items[slot], state.items[slot == 10 and 11 or 10]
                            local tr, a = track[slot], audit[brain_of(slot)]
                            local m = v.smart_memory
                            local note = m and m.note or "-"
                            local vstate = v.record.frame(v.frame).state
                            if vstate == 14 then tr.lying_at = ticks end
                            local free_now = is_free_state(v)
                            -- A blow started: a fresh attack decision (the note changes, or we were free a frame ago).
                            if (note ~= tr.note or tr.free) and not free_now
                               and (note:find("^attack ") or note:find("^jump in") or note:find("^strike first") or note:find("^follow up")) then
                                local t = tonumber(note:match(" t(%d+)")) or 20
                                tr.start = {tick = ticks, t = t, foe_free = is_free_state(o), note = note, foe_hp = o.hp, landed = false}
                                a.starts = a.starts + 1
                            end
                            local st = tr.start
                            if st and o.hp < st.foe_hp and not st.landed then st.landed = true; a.landed = a.landed + 1 end
                            if v.hp < tr.hp - 2 then
                                local loss = tr.hp - v.hp
                                a.hits_taken = a.hits_taken + 1
                                a.damage_taken = a.damage_taken + loss
                                local otr = track[slot == 10 and 11 or 10]
                                if st and ticks <= st.tick + st.t and not st.landed then
                                    if st.foe_free then a.interrupted_free = a.interrupted_free + 1 else a.interrupted_busy = a.interrupted_busy + 1 end
                                    a.interrupted_damage = a.interrupted_damage + loss
                                    local key = string.format("%s | foe f%d", st.note:match("^(%S+ %S+)") or st.note, o.frame)
                                    a.by_foe_move[key] = (a.by_foe_move[key] or 0) + 1
                                end
                                if o.blink > 0 or ticks - otr.lying_at <= 25 then a.getup_hits = a.getup_hits + 1; a.getup_damage = a.getup_damage + loss end
                                if v.x_int < 60 or v.x_int > width - 60 then a.wall_hits = a.wall_hits + 1; a.wall_damage = a.wall_damage + loss end
                                if ticks - otr.hit_at <= 2 then a.trades = a.trades + 1 end
                                tr.hit_at = ticks
                                local doing = (tr.note or "-"):match("^(%a+ ?%a*)") or "-"
                                a.doing[doing] = (a.doing[doing] or 0) + loss
                            end
                            if st and (ticks > st.tick + st.t + 2 or (free_now and ticks > st.tick + 1)) then tr.start = nil end
                            tr.hp, tr.note, tr.free = v.hp, note, free_now
                        end
                    end
                    if config.stats then
                        for _, slot in ipairs({10, 11}) do
                            local v = state.items[slot]
                            local o = state.items[slot == 10 and 11 or 10]
                            if v and before[slot] and v.hp < before[slot].hp and o then
                                local loss = before[slot].hp - v.hp
                                local category = (before[slot].note or "-"):match("^(%a+ ?%a*)") or "-"
                                if v.brain == "smart" then
                                    add(taken, string.format("%s | by f%d", category, o.frame), loss)
                                else
                                    local onote = before[slot == 10 and 11 or 10] and before[slot == 10 and 11 or 10].note or "-"
                                    add(dealt, (onote:match("^(%a+ %S+)") or onote), loss)
                                end
                            end
                        end
                    end
                    if config.events and state.items[10] and state.items[11] then
                        for _, slot in ipairs({10, 11}) do
                            local v = state.items[slot]
                            local m = v.smart_memory
                            local list = notes[slot]
                            local extra = ""
                            if config.where and not m then
                                local smart = require("base/game/smart_ai")
                                local a = smart.analyze(v.record)
                                local w = a.frames[v.frame]
                                if w then
                                    local e = w.move.entry
                                    extra = string.format("{%s%s t%d wc%d}", e.field or e.basic or ("c" .. tostring(e.key)), e.chain and "+" or "", w.t, v.wait_counter)
                                else
                                    extra = "{?}"
                                end
                                local others = {}
                                for i = 50, 399 do
                                    local o = state.items[i]
                                    if o and o.team == v.team then others[#others + 1] = string.format("o%d:f%d,x%d,vx%.0f,itr%d", o.record.id, o.frame, o.x_int, o.vx, #o.record.frame(o.frame).interactions) end
                                end
                                if #others > 0 then extra = extra .. "[" .. table.concat(others, " ") .. "]" end
                            end
                            list[#list + 1] = string.format("%d:f%d%s%s", ticks, v.frame, m and m.note and ("(" .. m.note .. ")") or "", extra)
                            if #list > (config.history or 8) then table.remove(list, 1) end
                        end
                        for _, slot in ipairs({10, 11}) do
                            local v = state.items[slot]
                            if v.hp < last_hp[slot] - 2 then
                                local other = state.items[slot == 10 and 11 or 10]
                                engine.log(string.format("%5d %s HIT %d->%d at x%d z%d by %s x%d z%d f%d", ticks, v.brain, last_hp[slot], v.hp, v.x_int, v.z_int,
                                    other.brain, other.x_int, other.z_int, other.frame))
                                engine.log("      victim: " .. table.concat(notes[slot], " "))
                                engine.log("      hitter: " .. table.concat(notes[slot == 10 and 11 or 10], " "))
                            end
                            last_hp[slot] = v.hp
                        end
                    end
                    if config.trace and ticks % config.trace == 0 and state.items[10] and state.items[11] then
                        local parts = {}
                        for _, slot in ipairs({10, 11}) do
                            local v = state.items[slot]
                            local m = v.smart_memory
                            parts[#parts + 1] = string.format("%s[x%d z%d y%d f%d s%d hp%d mp%d w%d %s]", v.brain or "?", v.x_int, v.z_int, v.y_int, v.frame,
                                v.record.frame(v.frame).state, v.hp, v.mp, v.weapon, m and m.note or "")
                        end
                        engine.log(string.format("%5d %s", ticks, table.concat(parts, "  ")))
                    end
                    if state.round_counter > 0 then break end
                end
                local hp = {}
                hp[first] = math.max(state.items[10] and state.items[10].hp or 0, 0)
                hp[second] = math.max(state.items[11] and state.items[11].hp or 0, 0)
                local winner
                if hp[1] > 0 and hp[2] <= 0 then winner = 1 elseif hp[2] > 0 and hp[1] <= 0 then winner = 2 end
                if not winner then
                    draws = draws + 1
                else
                    wins[winner] = wins[winner] + 1
                    pair_wins[winner] = pair_wins[winner] + 1
                end
                games = games + 1
                hp_left[1], hp_left[2] = hp_left[1] + hp[1], hp_left[2] + hp[2]
                total_ticks = total_ticks + ticks
                if config.models and state.smart_context and state.smart_context.models then
                    for value, m in pairs(state.smart_context.models) do
                        engine.log(string.format("  model of %d (%s): guards %d hits %d | attacks %d in %d chance frames (%.2f/s) | falls %d flips %d | jumps %d | %d frames",
                            value.record.id, value.brain or "?", m.guards, m.hits, m.attacks, m.chances, m.chances > 0 and m.attacks / (m.chances + 30) * 30 or 0,
                            m.falls, m.flips, m.jumps, m.frames))
                    end
                end
                if config.verbose then
                    engine.log(string.format("game %d: %s(%d) vs %s(%d): hp %d - %d, %d ticks, winner %s", games,
                        config.brains[1], pair[1], config.brains[2], pair[2], hp[1], hp[2], ticks, tostring(winner and config.brains[winner] or "draw")))
                end
            end)
            if not ok then
                failed = failed + 1
                engine.log(string.format("game %d of %d vs %d failed: %s", game, pair[1], pair[2], tostring(problem)))
            end
        end
        if config.nobrain then
            engine.log("has script: " .. tostring(require("base/game/ai_scripts").has(state_last, 10)) .. " " .. tostring(require("base/game/ai_scripts").has(state_last, 11)) .. " smart memory present: " .. tostring(state_last.items[10].smart_memory ~= nil) .. " / " .. tostring(state_last.items[11].smart_memory ~= nil))
        end
        engine.log(string.format("pair %d vs %d: %s %d - %d %s", pair[1], pair[2], config.brains[1], pair_wins[1], pair_wins[2], config.brains[2]))
    end
    if config.stats then
        local function dump(title, list)
            local keys = {}
            for key in pairs(list) do keys[#keys + 1] = key end
            table.sort(keys, function(a, b) return list[a] > list[b] end)
            engine.log(title)
            for index = 1, math.min(#keys, config.stats) do engine.log(string.format("  %6d  %s", list[keys[index]], keys[index])) end
        end
        dump("damage taken by smart (its decision | enemy frame):", taken)
        dump("damage dealt by smart (decision):", dealt)
    end
    if config.usage then
        local smart = require("base/game/smart_ai")
        local ids = {}
        for id in pairs(usage_records) do ids[#ids + 1] = id end
        table.sort(ids)
        for _, id in ipairs(ids) do
            local record = usage_records[id]
            local analysis = smart.analyze(record)
            local counts = usage[id]
            local used, total = 0, 0
            for _, move in ipairs(analysis.moves) do
                if not move.entry.parent then total = total + 1; if counts[move.index] then used = used + 1 end end
            end
            engine.log(string.format("USAGE %d: %d of %d whole moves started", id, used, total))
            local function show(list)
                for _, move in ipairs(list) do
                    local e = move.entry
                    local how = e.sequence and (e.field .. "#" .. e.sequence) or (e.basic or ("chain " .. tostring(e.key) .. " from " .. tostring(e.from)))
                    local chain = ""
                    for _, link in ipairs(e.chain or {}) do chain = chain .. string.format(">%s%s", link.key, tostring(link.target)) end
                    engine.log(string.format("  %5d  %-6s %-12s f%-3s%-14s first %-4s ready %-3d mp %-4d dmg %-4d%s%s%s%s", counts[move.index] or 0,
                        e.context, how, tostring(e.frame or e.press), chain, tostring(move.first), move.ready, move.mp, move.damage,
                        move.charge and " charge" or "", move.transform and " transform" or "", move.teleport and " teleport" or "", move.mode and " MODE" or ""))
                end
            end
            show(analysis.moves)
            for _, mode in pairs(analysis.modes or {}) do
                local armed = smart.internals.armed_analysis(record, mode.record, #analysis.moves + 1)
                local mused = 0
                for _, move in ipairs(armed.moves) do if counts[move.index] then mused = mused + 1 end end
                engine.log(string.format("  -- mode item %d (%d moves, %d used):", mode.record.id, #armed.moves, mused))
                show(armed.moves)
            end
        end
    end
    if audit then
        for brain = 1, 2 do
            local a = audit[brain]
            engine.log(string.format("AUDIT %s: starts %d landed %d interrupted %d (foe free %d, foe busy %d) dmg %d | hits taken %d dmg %d: get-up %d dmg %d, at wall %d dmg %d, trades %d",
                config.brains[brain], a.starts, a.landed, a.interrupted_free + a.interrupted_busy, a.interrupted_free, a.interrupted_busy, a.interrupted_damage,
                a.hits_taken, a.damage_taken, a.getup_hits, a.getup_damage, a.wall_hits, a.wall_damage, a.trades))
            local function top(list, n, title)
                local keys = {}
                for key in pairs(list) do keys[#keys + 1] = key end
                table.sort(keys, function(x, y) return list[x] > list[y] end)
                local parts = {}
                for i = 1, math.min(n, #keys) do parts[#parts + 1] = string.format("%s %d", keys[i], list[keys[i]]) end
                engine.log(string.format("  %s: %s", title, table.concat(parts, "; ")))
            end
            top(a.doing, 8, "damage taken while")
            top(a.by_foe_move, 6, "interrupted")
        end
        local parts = {}
        for key, count in pairs(excluded_counts) do parts[#parts + 1] = string.format("%s %d", key, count) end
        table.sort(parts)
        engine.log("  moves set aside: " .. table.concat(parts, "; "))
    end
    if failed > 0 then engine.log(string.format("%d games failed", failed)) end
    local n = math.max(games, 1)
    engine.log(string.format("TOTAL %s %d - %d %s, draws %d of %d; avg hp left %.0f / %.0f; avg %.0f ticks",
        config.brains[1], wins[1], wins[2], config.brains[2], draws, games, hp_left[1] / n, hp_left[2] / n, total_ticks / n))
end
return duel
