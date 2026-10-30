-- AI against AI: config.pairs of fighter ids, config.brains = {"smart", "classic"}, config.games per pair.
local catalog = require("base/game/catalog")
local match = require("base/game/match")
local constants = require("base/game/constants")
local duel = {}
local state_last
local function find(fighters, id)
    for index, fighter in ipairs(fighters) do if fighter.id == id then return index end end
    error("no fighter " .. tostring(id))
end
function duel.run(config)
    if config.no_ego then require("base/game/ai_scripts").ego = function() return nil end end
    if config.ego_hybrid then require("base/game/smart_ai").ego_hybrid = true end
    if config.no_prepare then require("base/game/smart_ai").prepare = function() end end
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
    for _, pair in ipairs(config.pairs) do
        local pair_wins = {0, 0}
        for game = 1, config.games do
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
                        parts[#parts + 1] = string.format("%s[x%d z%d y%d f%d s%d hp%d mp%d %s]", v.brain or "?", v.x_int, v.z_int, v.y_int, v.frame,
                            v.record.frame(v.frame).state, v.hp, v.mp, m and m.note or "")
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
            if config.verbose then
                engine.log(string.format("game %d: %s(%d) vs %s(%d): hp %d - %d, %d ticks, winner %s", games,
                    config.brains[1], pair[1], config.brains[2], pair[2], hp[1], hp[2], ticks, tostring(winner and config.brains[winner] or "draw")))
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
            for _, move in ipairs(analysis.moves) do
                local e = move.entry
                local how = e.sequence and (e.field .. "#" .. e.sequence) or (e.basic or ("chain " .. tostring(e.key) .. " from " .. tostring(e.from)))
                local chain = ""
                for _, link in ipairs(e.chain or {}) do chain = chain .. string.format(">%s%d", link.key, link.target) end
                engine.log(string.format("  %5d  %-6s %-12s f%-3d%-14s first %-4s ready %-3d mp %-4d dmg %-4d%s%s%s", counts[move.index] or 0,
                    e.context, how, e.frame, chain, tostring(move.first), move.ready, move.mp, move.damage,
                    move.charge and " charge" or "", move.transform and " transform" or "", move.teleport and " teleport" or ""))
            end
        end
    end
    engine.log(string.format("TOTAL %s %d - %d %s, draws %d of %d; avg hp left %.0f / %.0f; avg %.0f ticks",
        config.brains[1], wins[1], wins[2], config.brains[2], draws, games, hp_left[1] / games, hp_left[2] / games, total_ticks / games))
end
return duel
