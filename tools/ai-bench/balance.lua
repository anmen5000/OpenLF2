-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors
-- balance: how the fighters of a mod do against one another, one computer player playing both sides — every pair of
-- fighters, each on both sides, game after game — and what each fighter's moves bring: how often a move is started,
-- how often it lands, the HP it takes off (the blows of the objects it makes included), how often it is guarded, and
-- how often its user is hit while in it. For the people who make mods: the numbers, not a verdict; what to change is
-- theirs to say. The Windows runners (can-bang.bat, balance.bat) spread the games over the CPU threads, round after
-- round, and merge them into a report: an HTML page (balance-report-head.html + the data + balance-report-tail.html)
-- and a text summary.
--   step "list": the fighters chosen, "BAL_FIGHTER <id> <name>" lines (and "BAL_LEFT_OUT ..." for those left out).
--   step "play": games until `games` are played or `seconds` are up; every `snap` seconds and at the end, the totals
--     so far as lines "{<s>,<kind>,...}," (snapshot s = 1, 2, ...) followed by "BAL_SNAP <s> <games> <seconds>";
--     last "BAL_END <games>".
--   step "merge": the snapshots handed over as assets of the merge's package, mods/bench/bal_<attempt>_<n>.txt
--     (attempt 0: the round's last start; 1, 2, ...: starts it had before, cut short; n = 1, 2, ...: files of a few
--     processes each, 4 MiB at most), and the totals of the rounds before (bal_prev.txt), summed: the new totals
--     ("{0,...}, --BAL_TONG" lines: the next merge's bal_prev.txt), "BAL_DONE <games> <seconds> <rounds>", the
--     report's data ("B.x(...); //BAL_JS" lines) and the text summary ("| " lines).
-- Settings (config): ids ("all": every fighter a player can choose, or a list of ids and names, bench/names),
-- exclude (a list), brain ("xoi", "smart" = INSANE!, "classic" = the original player, which plays the mod's own AI
-- scripts where it has them), weapons (false: no weapons fall from the sky), limit (frames a game may last: 9000,
-- five minutes), stall (a game in which nobody loses HP for so many frames ends there, a draw: 1800, a minute),
-- seed, round, process, processes (whose share of the pairs a process starts with), games, seconds, snap.
-- (Each blow is credited by the game's own count of damage, battle.on_damage: the item that struck, and whether the
-- blow was guarded. A fighter's move is the stretch of frames from where it leaves a free stance — standing,
-- walking, running, jumping, dashing, rowing, guarding — to where it is free again or hit; a D-sequence pressed
-- inside a move starts another. An object takes the move of the frame that made it; a weapon, its holder's move.
-- HP lost with no blow behind it — a thrown fighter landing, a whirlwind's grind — goes to the last move that touched
-- the fighter, or caught it.)
local catalog = require("base/game/catalog")
local match = require("base/game/match")
local constants = require("base/game/constants")
local objects = require("base/game/objects")
local battle = require("base/game/battle")
local names = require("bench/names")
local job = {}
local floor, max, min, abs, sqrt = math.floor, math.max, math.min, math.abs, math.sqrt
local item_slots = constants.item_slots
local state_caught = constants.frame_states.caught

-- Seconds on the engine's steady clock (nil where there is none): time boxes, not game logic.
local function clock_seconds()
    local clock = engine.network_time
    return clock and clock() / 1000 or nil
end

-- A Park-Miller generator: generator(seed)(n) is 1..n.
local function generator(seed)
    local x = floor(seed) % 2147483647
    if x <= 0 then x = x + 2147483646 end
    return function(n)
        x = x * 16807 % 2147483647
        return x % n + 1
    end
end

local function number_text(value) return string.format("%.0f", value) end

---------------------------------------------------------------------------------------------------------------
-- The fighters.
---------------------------------------------------------------------------------------------------------------

-- The fighters to measure, in the order they are listed: config.ids ("all", or ids and names), less config.exclude,
-- less a fighter the versus match seats nobody for (the Template, id 0 in most mods) or cannot load, each tried once.
-- Returns a list of {index, id, name} and the reasons for those left out.
local function chosen(config, fighters, backgrounds)
    local picked, seen = {}, {}
    local function add(index)
        local fighter = fighters[index]
        if fighter and not seen[fighter.id] then
            seen[fighter.id] = true
            picked[#picked + 1] = index
        end
    end
    if config.ids == nil or config.ids == "all" then
        for index, fighter in ipairs(fighters) do
            if not fighter.hidden then add(index) end
        end
    else
        for _, wanted in ipairs(config.ids) do
            local index, problem = names.find(fighters, wanted)
            if not index then error(problem .. " (the mod's fighters: " .. names.listing(fighters) .. ")", 0) end
            add(index)
        end
    end
    local dropped = {}
    for _, wanted in ipairs(config.exclude or {}) do
        local index, problem = names.find(fighters, wanted)
        if not index then error(problem .. " (the mod's fighters: " .. names.listing(fighters) .. ")", 0) end
        dropped[fighters[index].id] = true
    end
    local list, left_out = {}, {}
    for _, index in ipairs(picked) do
        local fighter = fighters[index]
        if not dropped[fighter.id] then
            local ok, reason = pcall(function()
                local state = match.create({mode = constants.modes.versus, difficulty = -2, background = 0,
                    fighters = fighters, backgrounds = backgrounds,
                    slots = {[0] = {kind = "computer", fighter = index, team = 1}, [1] = {kind = "computer", fighter = index, team = 2}}})
                if not (state.items[10] and state.items[11]) then return "the versus match seats nobody for this fighter" end
            end)
            if ok and not reason then
                list[#list + 1] = {index = index, id = fighter.id, name = fighter.name}
            else
                left_out[#left_out + 1] = string.format("%d %s: %s", fighter.id, tostring(fighter.name), tostring(reason))
            end
        end
    end
    return list, left_out
end

---------------------------------------------------------------------------------------------------------------
-- The totals: what the games gave, by pair, fighter and move.
---------------------------------------------------------------------------------------------------------------
-- pairs[a b] (a < b): {a, b, games, wins of a, wins of b, draws, stalls, timeouts, ticks, HP a won with, HP b won with}
-- fighters[f]: {f, games, wins, losses, draws, ticks, HP left in its wins, damage dealt, damage taken, dealt by no move}
-- moves[f r e] (fighter, the record it was in, the move's first frame): {f, r, e, uses, landed, damage, guarded,
--   punished, blows}
-- versus[f o r e]: {f, o, r, e, uses, damage}
-- meta: {games, seconds, failed}
local function new_totals()
    return {pairs = {}, fighters = {}, moves = {}, versus = {}, meta = {0, 0, 0}, pair_list = {}, fighter_list = {},
        move_list = {}, versus_list = {}}
end
local list_of = {pairs = "pair_list", fighters = "fighter_list", moves = "move_list", versus = "versus_list"}
local function entry(totals, kind, key, fresh)
    local found = totals[kind][key]
    if not found then
        found = fresh
        totals[kind][key] = found
        local list = totals[list_of[kind]]
        list[#list + 1] = found
    end
    return found
end
local function pair_entry(totals, a, b)
    return entry(totals, "pairs", a .. " " .. b, {a, b, 0, 0, 0, 0, 0, 0, 0, 0, 0})
end
local function fighter_entry(totals, f)
    return entry(totals, "fighters", f, {f, 0, 0, 0, 0, 0, 0, 0, 0, 0})
end
local function move_entry(totals, f, r, e)
    return entry(totals, "moves", f .. " " .. r .. " " .. e, {f, r, e, 0, 0, 0, 0, 0, 0})
end
local function versus_entry(totals, f, o, r, e)
    return entry(totals, "versus", f .. " " .. o .. " " .. r .. " " .. e, {f, o, r, e, 0, 0})
end

-- Adds a line of a snapshot (or of the totals) to `totals`: {s, kind, ...}.
local function add_line(totals, line)
    local kind = line[2]
    local function sum(target, from)
        for i = from, #target do target[i] = target[i] + (line[i + 2] or 0) end
    end
    if kind == 0 then
        for i = 1, 3 do totals.meta[i] = totals.meta[i] + (line[i + 2] or 0) end
    elseif kind == 1 then sum(pair_entry(totals, line[3], line[4]), 3)
    elseif kind == 2 then sum(fighter_entry(totals, line[3]), 2)
    elseif kind == 3 then sum(move_entry(totals, line[3], line[4], line[5]), 4)
    elseif kind == 4 then sum(versus_entry(totals, line[3], line[4], line[5], line[6]), 5)
    end
end

-- The versus entries as they are kept in print: for each fighter and opponent, the moves that dealt the most
-- (versus_kept of them), the others summed in one entry, frame -1 (the page shows the move that dealt the most against
-- each opponent; the sum stays whole). Every move against every opponent would grow with the square of the fighters.
local versus_kept = 3
local function compact_versus(list)
    local groups, order = {}, {}
    for _, values in ipairs(list) do
        local key = values[1] .. " " .. values[2]
        local group = groups[key]
        if not group then
            group = {}
            groups[key] = group
            order[#order + 1] = group
        end
        group[#group + 1] = values
    end
    local out = {}
    for _, group in ipairs(order) do
        local rest = {group[1][1], group[1][2], 0, -1, 0, 0}
        local moves = {}
        for _, values in ipairs(group) do
            if values[4] == -1 then rest[5], rest[6] = rest[5] + values[5], rest[6] + values[6]
            else moves[#moves + 1] = values end
        end
        table.sort(moves, function(x, y)
            if x[6] ~= y[6] then return x[6] > y[6] end
            if x[5] ~= y[5] then return x[5] > y[5] end
            if x[3] ~= y[3] then return x[3] < y[3] end
            return x[4] < y[4]
        end)
        for i, values in ipairs(moves) do
            if i <= versus_kept and values[6] > 0 then out[#out + 1] = values
            else rest[5], rest[6] = rest[5] + values[5], rest[6] + values[6] end
        end
        if rest[5] > 0 or rest[6] > 0 then out[#out + 1] = rest end
    end
    return out
end

-- The totals as lines: prefix .. "<kind>,<numbers>}" .. suffix, one a line.
local function print_totals(totals, prefix, suffix, meta)
    local function out(kind, values)
        local parts = {}
        for i, value in ipairs(values) do parts[i] = number_text(value) end
        engine.log(prefix .. kind .. "," .. table.concat(parts, ",") .. "}" .. suffix)
    end
    out(0, meta or totals.meta)
    for _, values in ipairs(totals.pair_list) do out(1, values) end
    for _, values in ipairs(totals.fighter_list) do out(2, values) end
    for _, values in ipairs(totals.move_list) do out(3, values) end
    for _, values in ipairs(compact_versus(totals.versus_list)) do out(4, values) end
end

-- Adds the lines "{...}" of a file the runner handed over as an asset of this package (mods/bench/<name>, at most
-- 4 MiB) to `totals`; each(line) sees every line. False when there is no such file.
local function read_part(totals, name, each)
    local ok, text = pcall(engine.read_resource, "mods/bench/" .. name)
    if not ok then
        if tostring(text):find("exceeds", 1, true) then error(name .. ": " .. tostring(text), 0) end
        return false
    end
    if type(text) ~= "string" then return false end
    for row in text:gmatch("[^\r\n]+") do
        if row:byte(1) == 123 then
            local line = {}
            for value in row:gmatch("%-?%d+") do line[#line + 1] = tonumber(value) end
            if #line >= 2 then
                add_line(totals, line)
                if each then each(line) end
            end
        end
    end
    return true
end

---------------------------------------------------------------------------------------------------------------
-- Watching a game: moves, and the blows each one deals.
---------------------------------------------------------------------------------------------------------------

local free_states = {[0] = true, [1] = true, [2] = true, [4] = true, [5] = true, [6] = true, [7] = true, [17] = true}
local hurt_states = {[8] = true, [10] = true, [11] = true, [12] = true, [13] = true, [14] = true, [16] = true, [18] = true}
local sequence_fields = {"Fa", "Ua", "Da", "Fj", "Uj", "Dj", "ja"}
local cost_radix, cost_unit = constants.move_cost_encoding.hp_radix, constants.move_cost_encoding.hp_unit

local watching -- the game being watched: {state, totals, tick, sides, by_value, origins, seen, last_contact, held}

-- Whether a frame begins a move: the frames it runs through by itself (next, next ...) strike — a blow that does
-- something, a catch, a whirlwind, an object made, a weapon swung — or it is a fighter's catch; or it is a special,
-- what a D-sequence leads to from a free stance (a change, a teleport, a power-up: no blow, but a move all the
-- same). A crouch on landing, a stagger, a pose: no move.
local strike_kinds = {[1] = true, [3] = true, [10] = true, [11] = true, [15] = true, [16] = true}
local move_frames = {} -- by record id (one mod a process)
local function specials_of(record)
    local found = {}
    for _, frame in pairs(record.frames) do
        if free_states[frame.state] and frame.hits then
            for _, field in ipairs(sequence_fields) do
                local target = frame.hits[field]
                if target and target ~= 0 then found[abs(target)] = true end
            end
        end
    end
    return found
end
local function begins_move(record, frame_id)
    local known = move_frames[record.id]
    if not known then
        known = {specials = specials_of(record)}
        move_frames[record.id] = known
    end
    local result = known[frame_id]
    if result ~= nil then return result end
    result = known.specials[frame_id] == true
    local current, seen = frame_id, {}
    for _ = 1, 80 do
        if result then break end
        local frame = record.frames[current]
        if not frame or seen[current] or (current ~= frame_id and free_states[frame.state]) then break end
        seen[current] = true
        if frame.state == constants.frame_states.catching then result = true; break end
        local point = frame.opoint
        if point and (point.kind or 0) > 0 and (point.oid or 0) > 0 then result = true; break end
        if frame.wpoint and (frame.wpoint.attacking or 0) > 0 then result = true; break end
        for _, itr in ipairs(frame.interactions or {}) do
            if strike_kinds[itr.kind] or (itr.kind == 0 and ((itr.injury or 0) ~= 0 or (itr.fall or 0) > 0 or (itr.effect or 0) ~= 0)) then
                result = true
                break
            end
        end
        local after = abs(frame.next or 0)
        if after == 0 or after >= 999 then break end
        current = after
    end
    known[frame_id] = result
    return result
end

local function open(game, side, record_id, frame_id)
    local totals = game.totals
    local move = move_entry(totals, side.f, record_id, frame_id)
    local versus = versus_entry(totals, side.f, side.o, record_id, frame_id)
    move[4] = move[4] + 1
    versus[5] = versus[5] + 1
    side.current = {move = move, versus = versus, landed = false, guarded = false, punished = false}
end
local function close(game, side)
    if side.current then
        side.current.closed_at = game.tick
        side.last = side.current
        side.current = nil
    end
end
-- The fighter's move as of its present frame (several calls in a frame are one).
local function update(game, side)
    local value = side.value
    if not value then return end
    local frame_id, record_id = value.frame, value.record.id
    if frame_id == side.frame and record_id == side.record then return end
    local frame = value.record.frame(frame_id)
    local state = frame.state
    if hurt_states[state] or free_states[state] then
        close(game, side)
    elseif not side.current then
        if begins_move(value.record, frame_id) then open(game, side, record_id, frame_id) end
    elseif record_id == side.record then
        -- (A D-sequence pressed inside a move starts another; the attack, jump and defend keys go on with it.)
        local hits = value.record.frame(side.frame).hits
        for _, field in ipairs(sequence_fields) do
            local target = hits and hits[field]
            if target and target ~= 0 and abs(target) == frame_id then
                close(game, side)
                open(game, side, record_id, frame_id)
                break
            end
        end
    end
    side.frame, side.record = frame_id, record_id
end
local function move_of(side) return side.current or side.last end

-- Whose blow, and of which move: a fighter's own; a weapon's holder's; an object's maker's; else its owner's.
local function credit(game, attacker)
    if not attacker then return nil end
    local side = game.by_value[attacker]
    if side then
        update(game, side)
        return side, move_of(side)
    end
    if attacker.weapon and attacker.weapon < 0 then
        local holder = game.state.items[attacker.holder]
        side = holder and game.by_value[holder]
        if side then
            update(game, side)
            return side, move_of(side)
        end
    end
    local origin = game.origins[attacker]
    if origin then return origin.side, origin.move end
    local owner = game.state.items[attacker.owner]
    side = owner and game.by_value[owner]
    if side then return side, move_of(side) end
    return nil
end

local function on_damage(state, victim, damage, attacker, defended, contact)
    local game = watching
    if not game or state ~= game.state then return end
    local side = game.by_value[victim]
    if not side then return end
    update(game, side)
    local by, move = credit(game, attacker)
    if by and by ~= side then
        local fighter = fighter_entry(game.totals, by.f)
        if move then
            if defended then
                if not move.guarded then move.guarded = true; move.move[7] = move.move[7] + 1 end
            elseif damage > 0 or contact then
                if not move.landed then move.landed = true; move.move[5] = move.move[5] + 1 end
                move.move[9] = move.move[9] + 1
            end
            move.move[6] = move.move[6] + damage
            move.versus[6] = move.versus[6] + damage
            game.last_contact[side] = {move = move, tick = game.tick}
        else
            fighter[10] = fighter[10] + damage
        end
        fighter[8] = fighter[8] + damage
        -- (Hit while in a move of its own — or in the frame the blow cut it short: punished.)
        local own = side.current or (side.last and side.last.closed_at == game.tick and side.last)
        if own and not own.punished and not defended and (damage > 0 or contact) then
            own.punished = true
            own.move[8] = own.move[8] + 1
        end
    end
    fighter_entry(game.totals, side.f)[9] = fighter_entry(game.totals, side.f)[9] + damage
    side.accounted = side.accounted + damage
end

-- An object takes the move of the frame that made it (or of the object that made it).
local function spawned(state, parent)
    local game = watching
    if not game or state ~= game.state then return end
    local side = game.by_value[parent]
    local origin
    if side then
        update(game, side)
        local move = move_of(side)
        origin = {side = side, move = move}
    else
        origin = game.origins[parent]
    end
    for slot = 0, item_slots - 1 do
        local value = state.items[slot]
        if value and not game.seen[value] then
            game.seen[value] = true
            if origin then game.origins[value] = origin end
        end
    end
end

local installed = false
local function install(config)
    if installed then return end
    installed = true
    battle.on_damage = on_damage
    local spawn = objects.spawn_from_frame
    objects.spawn_from_frame = function(state, index, parent)
        local made = spawn(state, index, parent)
        if made and watching then spawned(state, parent) end
        return made
    end
    if not config.weapons then
        -- (No weapons falling from the sky: the fighters, and what they make, alone.)
        require("base/game/weapons").drop_background = function() end
    end
end

-- One game: fighters `left` (slot 0) and `right` (slot 1), from point h of the random sequence, on stage `row`.
-- Returns the winner (1 left, 2 right, nil a draw), how it ended ("ko", "stall", "limit"), the ticks and both HPs.
local function play_game(context, left, right, row, h)
    engine.set_random_state(context.table, h % 3000, floor(h / 3000) % 1234)
    local state = match.create({mode = constants.modes.versus, difficulty = -2, background = row,
        fighters = context.fighters, backgrounds = context.backgrounds,
        slots = {[0] = {kind = "computer", fighter = left.index, team = 1}, [1] = {kind = "computer", fighter = right.index, team = 2}}})
    local a, b = state.items[10], state.items[11]
    assert(a and b, "the match seats nobody for a fighter of the pair")
    a.brain, b.brain = context.brain, context.brain
    if context.prepare then context.prepare(state) end
    local totals = context.totals
    local sides = {
        {f = left.id, o = right.id, slot = 10, value = a, frame = -1, record = -1, hp = a.hp, accounted = 0},
        {f = right.id, o = left.id, slot = 11, value = b, frame = -1, record = -1, hp = b.hp, accounted = 0},
    }
    sides[1].other, sides[2].other = sides[2], sides[1]
    local game = {state = state, totals = totals, tick = 0, sides = sides, by_value = {[a] = sides[1], [b] = sides[2]},
        origins = {}, seen = {}, last_contact = {}, held = {}}
    for slot = 0, item_slots - 1 do
        local value = state.items[slot]
        if value then game.seen[value] = true end
    end
    for _, side in ipairs(sides) do update(game, side) end
    watching = game
    local held_keys = {functions = "", function_presses = "", keys = {}}
    local stall, limit = context.stall, context.limit
    local quiet, ending = 0, "limit"
    local ok, problem = pcall(function()
        while game.tick < limit do
            -- (A fighter's item may be another table after some change of the game's: look again.)
            for _, side in ipairs(sides) do
                local value = state.items[side.slot]
                if value ~= side.value and value then
                    game.by_value[side.value] = nil
                    side.value = value
                    game.by_value[value] = side
                end
                side.before = value and value.frame
            end
            game.tick = game.tick + 1
            match.step(state, held_keys)
            local lost = false
            for _, side in ipairs(sides) do
                local value = side.value
                update(game, side)
                -- HP lost with no blow counted for it: a move's own price, or the last move that touched it.
                local drop = side.hp - value.hp
                local extra = drop - side.accounted
                if extra > 0 then
                    if value.frame ~= side.before then
                        local cost = value.record.frame(value.frame).mp
                        if cost >= cost_radix then extra = extra - floor(cost / cost_radix) * cost_unit end
                    end
                    if extra > 0 then
                        -- (Within ten seconds of the contact: a thrown fighter lands, a whirlwind grinds. Later, or
                        -- with no contact at all, it is no blow of the other's.)
                        local contact = game.last_contact[side]
                        if contact and game.tick - contact.tick <= 300 then
                            local move = contact.move
                            move.move[6] = move.move[6] + extra
                            move.versus[6] = move.versus[6] + extra
                            local fighter = fighter_entry(totals, side.other.f)
                            fighter[8] = fighter[8] + extra
                        end
                        local own = fighter_entry(totals, side.f)
                        own[9] = own[9] + extra
                    end
                end
                if drop > 0 then lost = true end
                side.hp, side.accounted = value.hp, 0
                -- (Caught: whatever it loses next is the catcher's.)
                if value.record.frame(value.frame).state == state_caught and move_of(side.other) then
                    game.last_contact[side] = {move = move_of(side.other), tick = game.tick}
                end
            end
            if context.weapons then
                -- A weapon let go of: thrown, by its holder's move of that frame.
                local now = {}
                for slot = 0, item_slots - 1 do
                    local value = state.items[slot]
                    if value and value.weapon and value.weapon < 0 then
                        local holder = state.items[value.holder]
                        local side = holder and game.by_value[holder]
                        if side then now[value] = side end
                    end
                end
                for value, side in pairs(game.held) do
                    if not now[value] then game.origins[value] = {side = side, move = move_of(side)} end
                end
                game.held = now
            end
            if state.round_counter > 0 then ending = "ko"; break end
            if lost then quiet = 0 else quiet = quiet + 1 end
            if stall > 0 and quiet >= stall then ending = "stall"; break end
        end
    end)
    watching = nil
    if not ok then error(problem, 0) end
    local hp_left, hp_right = max(a.hp, 0), max(b.hp, 0)
    local winner
    if hp_left > 0 and hp_right <= 0 then winner = 1 elseif hp_right > 0 and hp_left <= 0 then winner = 2 end
    if ending == "ko" and not winner then ending = "both" end
    return winner, ending, game.tick, hp_left, hp_right
end

-- A game's result into the totals.
local function count_game(totals, left, right, winner, ending, ticks, hp_left, hp_right)
    local a, b = left, right
    local hp_a, hp_b, a_won, b_won = hp_left, hp_right, winner == 1, winner == 2
    if b.id < a.id then a, b, hp_a, hp_b, a_won, b_won = right, left, hp_right, hp_left, winner == 2, winner == 1 end
    local pair = pair_entry(totals, a.id, b.id)
    pair[3] = pair[3] + 1
    if a_won then pair[4] = pair[4] + 1; pair[10] = pair[10] + hp_a
    elseif b_won then pair[5] = pair[5] + 1; pair[11] = pair[11] + hp_b
    else
        pair[6] = pair[6] + 1
        if ending == "stall" then pair[7] = pair[7] + 1 elseif ending == "limit" then pair[8] = pair[8] + 1 end
    end
    pair[9] = pair[9] + ticks
    for side, fighter in ipairs({left, right}) do
        local f = fighter_entry(totals, fighter.id)
        f[2] = f[2] + 1
        f[6] = f[6] + ticks
        if winner == side then
            f[3] = f[3] + 1
            f[7] = f[7] + (side == 1 and hp_left or hp_right)
        elseif winner then f[4] = f[4] + 1
        else f[5] = f[5] + 1 end
    end
end

---------------------------------------------------------------------------------------------------------------
-- The steps.
---------------------------------------------------------------------------------------------------------------

local function list_step(config)
    local fighters, backgrounds = catalog.load(), catalog.backgrounds()
    local list, left_out = chosen(config, fighters, backgrounds)
    for _, fighter in ipairs(list) do engine.log(string.format("BAL_FIGHTER %d %s", fighter.id, tostring(fighter.name))) end
    for _, reason in ipairs(left_out) do engine.log("BAL_LEFT_OUT " .. reason) end
    engine.log(string.format("BAL_COUNT %d %d", #list, #list * (#list - 1) / 2))
end

local function play_step(config)
    local fighters, backgrounds = catalog.load(), catalog.backgrounds()
    local list = chosen(config, fighters, backgrounds)
    assert(#list >= 2, "fewer than two fighters to measure")
    install(config)
    local brain = config.brain or "xoi"
    local smart = require("base/game/smart_ai")
    local context = {fighters = fighters, backgrounds = backgrounds, brain = brain, totals = new_totals(),
        table = engine.random_state(), limit = config.limit or 9000, stall = config.stall or 1800, weapons = config.weapons,
        prepare = brain ~= "classic" and smart.prepare or nil}
    local pairs_list = {}
    for i = 1, #list do
        for j = i + 1, #list do pairs_list[#pairs_list + 1] = {list[i], list[j]} end
    end
    local process, processes, round = config.process or 1, max(1, config.processes or 1), config.round or 1
    local start = floor((process - 1) * #pairs_list / processes) + ((round - 1) * 7919) % #pairs_list
    local random = generator(config.seed or 1)
    local budget, seconds, snap = config.games, config.seconds, config.snap or 300
    local began = clock_seconds() or 0
    local last_snap, snapshot = began, 0
    local totals = context.totals
    local function elapsed() return (clock_seconds() or began) - began end
    local function snapshot_now()
        snapshot = snapshot + 1
        totals.meta[2] = floor(elapsed())
        print_totals(totals, "{" .. snapshot .. ",", ",")
        engine.log(string.format("BAL_SNAP %d %d %d", snapshot, totals.meta[1], totals.meta[2]))
    end
    engine.log(string.format("balance: %d fighters, %d pairs, brain %s, process %d of %d, round %d, %s, from pair %d", #list,
        #pairs_list, brain, process, processes, round,
        budget and (budget .. " games") or ((seconds or 0) .. " seconds"), start % #pairs_list + 1))
    local visit = 0
    while true do
        if budget and totals.meta[1] + totals.meta[3] >= budget then break end
        if seconds and elapsed() >= seconds then break end
        if not budget and not seconds and visit >= #pairs_list then break end
        local pair = pairs_list[(start + visit) % #pairs_list + 1]
        visit = visit + 1
        local h = random(3000 * 1234) - 1
        local row = random(#backgrounds) - 1
        -- (Both sides of the pair from the same point of the random sequence, on the same stage.)
        for side = 1, 2 do
            local left, right = pair[side], pair[3 - side]
            local ok, winner, ending, ticks, hp_left, hp_right = pcall(play_game, context, left, right, row, h)
            if ok then
                count_game(totals, left, right, winner, ending, ticks, hp_left, hp_right)
                totals.meta[1] = totals.meta[1] + 1
            else
                totals.meta[3] = totals.meta[3] + 1
                engine.log(string.format("BAL_FAILED %d vs %d: %s", left.id, right.id, tostring(winner)))
            end
        end
        local now = clock_seconds() or 0
        if now - last_snap >= snap then
            snapshot_now()
            last_snap = now
        end
    end
    snapshot_now()
    engine.log(string.format("BAL_END %d", totals.meta[1]))
end

---------------------------------------------------------------------------------------------------------------
-- Merging, and the report.
---------------------------------------------------------------------------------------------------------------

local key_names = {Fa = "D>A", Ua = "D^A", Da = "DvA", Fj = "D>J", Uj = "D^J", Dj = "DvJ", ja = "D+J+A", a = "A", j = "J", d = "D"}
local key_order = {"Fa", "Ua", "Da", "Fj", "Uj", "Dj", "ja", "a", "j", "d"}
local free_frame_states = {[0] = true, [1] = true, [2] = true, [4] = true, [5] = true}

-- How a move is started: the keys that lead to its first frame from a free stance ("D>A"), or from some other frame
-- ("A"); nil for one the game starts by itself (a punch, a jump attack: the frame's name says it).
local function keys_of(record, frame_id)
    local found, found_free
    local ids = {}
    for id in pairs(record.frames) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local frame = record.frames[id]
        local hits = frame.hits
        if hits then
            for _, field in ipairs(key_order) do
                local target = hits[field]
                if target and target ~= 0 and abs(target) == frame_id then
                    if free_frame_states[frame.state] then found_free = found_free or field
                    else found = found or field end
                end
            end
        end
    end
    local field = found_free or found
    return field and key_names[field] or nil, field ~= nil and found_free ~= nil
end

-- A string as JavaScript (JSON): quotes, backslashes and control characters escaped, and <, >, & too (the data
-- goes inside the page's <script>).
local function js_string(text)
    text = tostring(text or "")
    return '"' .. text:gsub('[%c"\\<>&]', function(c)
        local byte = c:byte()
        if c == '"' then return '\\"' elseif c == "\\" then return "\\\\" end
        return string.format("\\u%04x", byte)
    end) .. '"'
end
local function js_list(values)
    local parts = {}
    for i, value in ipairs(values) do
        if type(value) == "string" then parts[i] = js_string(value)
        elseif type(value) == "boolean" then parts[i] = value and "true" or "false"
        else parts[i] = number_text(value) end
    end
    return "[" .. table.concat(parts, ",") .. "]"
end

-- The win rate of a fighter (a draw counts a half) and the half width of its 95% interval.
local function rate(wins, draws, games)
    if games <= 0 then return 0, 0 end
    local p = (wins + draws / 2) / games
    local squares = (wins + draws / 4) / games
    local variance = max(0, squares - p * p)
    return p, 1.96 * sqrt(variance / games)
end

local texts = {
    vi = {
        title = "Can bang %s: %s van, may %s",
        rules = "Moi van toi da %d phut; dung (hoa) khi %d giay khong ai mat mau. Vu khi roi tu troi: %s. %d nhan vat, %s, moi cap danh ca hai ben.",
        on = "bat", off = "tat",
        plan = "Ke hoach: %s. Da danh %s, %s gio may (cong moi tien trinh).",
        plan_games = "%s, %s van", plan_hours = "%s, %s gio",
        round1 = "vong", rounds = "vong", pair1 = "cap", pairs = "cap",
        classic = "CRAZY! (may goc; nhan vat co script AI rieng cua ban mod thi choi bang script do)",
        tuned = "thang so rieng cua ban mod", brain = "bo nao", notes = "bo nho %d cap", no_notes = "chua co bo nho",
        ranking = "Xep hang (ti le thang: thang + nua so hoa, tren moi van; +- la khoang sai so 95%%):",
        rank_line = "%3d. %-18s %5.1f%% +-%4.1f  thang %d, hoa %d, thua %d (%d van); gay %d mau moi van",
        moves = "Chieu gay nhieu sat thuong nhat cua tung nhan vat (phan tram sat thuong cua no, ti le trung, bi danh tra):",
        move_part = "%s %d%% (trung %d%%, bi danh tra %d%%)",
        catch_part = "%s %d%% (bat/om, bi danh tra %d%%)",
        review = "  [nen xem lai] %s: %s - %d%% sat thuong, trung %d%% so lan dung, bi danh tra %d%%",
        review_catch = "  [nen xem lai] %s: %s (bat/om, %s lan moi van) - %d%% sat thuong, bi danh tra %d%%",
        review_title = "Chieu chu luc, trung nhieu, it bi danh tra (chiem tu 30%% sat thuong, trung tu 50%% - bat/om thi khong xet, bi danh tra toi da 15%%, tu 50 lan dung):",
        none = "  (khong co)",
        draws = "Cap nhieu van hoa nhat:",
        draw_line = "  %s - %s: %d/%d van hoa (%d dung im 1 phut, %d het gio, %d hai ben cung guc)",
        report = "Bao cao day du: mo file bao-cao.html (ban do doi dau, tung chieu cua tung nhan vat).",
        no_data = "Chua co van nao.",
    },
    en = {
        title = "Balance of %s: %s games, played by %s",
        rules = "A game lasts at most %d minutes; it ends (a draw) after %d seconds in which nobody loses HP. Weapons falling from the sky: %s. %d fighters, %s, every pair played on both sides.",
        on = "on", off = "off",
        plan = "Plan: %s. %s played, %s CPU hours (all processes together).",
        plan_games = "%s, %s games", plan_hours = "%s, %s hours",
        round1 = "round", rounds = "rounds", pair1 = "pair", pairs = "pairs",
        classic = "CRAZY! (the original computer player; the mod's own AI scripts where it has them)",
        tuned = "the mod's own numbers", brain = "brain", notes = "notes on %d pairs", no_notes = "no notes",
        ranking = "Ranking (win rate: wins plus half the draws, over all games; +- is the 95%% margin):",
        rank_line = "%3d. %-18s %5.1f%% +-%4.1f  won %d, drew %d, lost %d (%d games); deals %d HP a game",
        moves = "Each fighter's moves that deal the most (share of its damage, how often it lands, how often its user is hit in it):",
        move_part = "%s %d%% (lands %d%%, punished %d%%)",
        catch_part = "%s %d%% (a catch, punished %d%%)",
        review = "  [worth a look] %s: %s - %d%% of its damage, lands %d%% of the times used, punished %d%%",
        review_catch = "  [worth a look] %s: %s (a catch, %s a game) - %d%% of its damage, punished %d%%",
        review_title = "Main moves that land often and are seldom punished (30%% of the damage or more, landing 50%% or more - not asked of a catch, punished 15%% at most, used 50 times or more):",
        none = "  (none)",
        draws = "Pairs with the most draws:",
        draw_line = "  %s - %s: %d/%d games drawn (%d a minute without damage, %d at the time limit, %d both down)",
        report = "The full report: open report.html (the matchup chart, every move of every fighter).",
        no_data = "No games yet.",
    },
}

local report
local function merge_step(config)
    local totals = new_totals()
    local rounds, wall = 0, 0
    -- (The totals of the rounds before: their line 0 carries the rounds and the wall seconds too.)
    if config.prev then
        local found = read_part(totals, "bal_prev.txt", function(line)
            if line[2] == 0 then rounds, wall = line[6] or 0, line[7] or 0 end
        end)
        assert(found, "the totals of the rounds before (bal_prev.txt) are missing")
    end
    -- This round: every start of it (attempt 0 the last one), every process (a line 0 each); its wall time is each
    -- start's longest process, summed over the starts.
    local parts = 0
    for attempt = 0, 99 do
        local longest, found = 0, false
        for n = 1, 1000 do
            if not read_part(totals, "bal_" .. attempt .. "_" .. n .. ".txt", function(line)
                if line[2] == 0 then
                    parts = parts + 1
                    longest = max(longest, line[4] or 0)
                end
            end) then break end
            found = true
        end
        if not found and attempt > 0 then break end
        wall = wall + longest
    end
    rounds = rounds + 1
    local meta = {totals.meta[1], totals.meta[2], totals.meta[3], rounds, wall}
    print_totals(totals, "{0,", ", --BAL_TONG", meta)
    engine.log(string.format("balance merge: %d parts, %d games in all, %d rounds", parts, totals.meta[1], rounds))
    -- (The last line, "BAL_DONE <games> <wall seconds> <rounds>", once the page's data and the summary are out: the
    -- runner waits for it.)
    local ok, problem = pcall(report, config, totals, rounds, wall)
    if not ok then engine.log("BENCH ERROR: the report: " .. tostring(problem)) end
    engine.log(string.format("BAL_DONE %d %d %d", totals.meta[1], wall, rounds))
end

-- The report: the page's data and the text summary.
function report(config, totals, rounds, wall)
    -- (Names of fighters and moves from the mod's data.)
    local fighters, backgrounds = catalog.load(), catalog.backgrounds()
    local list = chosen(config, fighters, backgrounds)
    local name_of = {}
    for _, fighter in ipairs(fighters) do name_of[fighter.id] = name_of[fighter.id] or fighter.name end
    local state
    if #list >= 2 then
        state = match.create({mode = constants.modes.versus, difficulty = -2, background = 0, fighters = fighters,
            backgrounds = backgrounds,
            slots = {[0] = {kind = "computer", fighter = list[1].index, team = 1}, [1] = {kind = "computer", fighter = list[2].index, team = 2}}})
    end
    local function record_of(id) return state and objects.record(state, id) or nil end
    -- (The computer player: XOI with what the mod brings for it - its own numbers xoi/tune.txt, a brain, notes -,
    -- INSANE!, or the original one.)
    local smart = require("base/game/smart_ai")
    local ai = {kind = config.brain == "smart" and "smart" or config.brain == "classic" and "classic" or "xoi",
        version = tonumber(smart.version) or 0, tuned = false, brain = false, notes = 0}
    if ai.kind == "xoi" then
        local function has(path) local ok = pcall(engine.read_resource, path); return ok end
        ai.tuned, ai.brain = has("xoi/tune.txt"), has("xoi/brain.txt")
        ai.notes = smart.notes_pairs and smart.notes_pairs() or 0
    end
    local lang = texts[config.lang or "en"] and (config.lang or "en") or "en"
    local text = texts[lang]
    local function counted(n, one, many) return number_text(n) .. " " .. (n == 1 and one or many) end
    local label
    if ai.kind == "classic" then label = text.classic
    elseif ai.kind == "smart" then label = "INSANE! v" .. ai.version
    else
        local bits = {"XOI v" .. ai.version}
        if ai.tuned then bits[#bits + 1] = text.tuned end
        if ai.brain then bits[#bits + 1] = text.brain end
        bits[#bits + 1] = ai.notes > 0 and string.format(text.notes, ai.notes) or text.no_notes
        label = table.concat(bits, ", ")
    end
    -- (The plan the runner was given: rounds, and the total games or the total seconds.)
    local plan_rounds = tonumber(config.plan_rounds) or 0
    local plan_games, plan_seconds = tonumber(config.plan_games) or 0, tonumber(config.plan_seconds) or 0
    local plan
    if plan_rounds > 0 and plan_games > 0 then
        plan = string.format(text.plan_games, counted(plan_rounds, text.round1, text.rounds), number_text(plan_games))
    elseif plan_rounds > 0 and plan_seconds > 0 then
        local hours = plan_seconds / 3600
        plan = string.format(text.plan_hours, counted(plan_rounds, text.round1, text.rounds),
            hours == floor(hours) and number_text(hours) or string.format("%.1f", hours))
    end
    local limit, stall = config.limit or 9000, config.stall or 1800
    local fighter_ids = {}
    for _, fighter in ipairs(list) do fighter_ids[#fighter_ids + 1] = fighter.id end

    -- Data for the page.
    local function js(call, values) engine.log("B." .. call .. "(" .. values .. "); //BAL_JS") end
    js("meta", "{" .. table.concat({
        "mod:" .. js_string(config.mod or "?"), "lang:" .. js_string(lang),
        "ai:{kind:" .. js_string(ai.kind) .. ",version:" .. number_text(ai.version) .. ",tuned:" .. tostring(ai.tuned) ..
            ",brain:" .. tostring(ai.brain) .. ",notes:" .. number_text(ai.notes) .. "}",
        "games:" .. number_text(totals.meta[1]), "failed:" .. number_text(totals.meta[3]), "rounds:" .. number_text(rounds),
        "cpu:" .. number_text(totals.meta[2]), "wall:" .. number_text(wall), "limit:" .. number_text(limit),
        "stall:" .. number_text(stall), "weapons:" .. (config.weapons and "true" or "false"),
        "plan:{rounds:" .. number_text(plan_rounds) .. ",games:" .. number_text(plan_games) .. ",seconds:" ..
            number_text(plan_seconds) .. "}",
        "date:" .. js_string(config.date or ""), "kit:" .. js_string(config.kit or "")}, ",") .. "}")
    for _, fighter in ipairs(list) do
        local f = totals.fighters[fighter.id] or {fighter.id, 0, 0, 0, 0, 0, 0, 0, 0, 0}
        js("f", js_list({fighter.id, tostring(fighter.name), f[2], f[3], f[4], f[5], f[6], f[7], f[8], f[9], f[10]}))
    end
    for _, pair in ipairs(totals.pair_list) do js("p", js_list(pair)) end
    local labels = {}
    local function label_of(r, e)
        local key = r .. " " .. e
        if labels[key] then return labels[key] end
        local record = record_of(r)
        local frame = record and record.frames[e]
        local keys = record and keys_of(record, e) or nil
        -- (A catch begins on contact: it always "lands", and its rate says nothing.)
        local entry = {keys or "", frame and frame.name or "", record and record.data and record.data.name or tostring(r),
            frame ~= nil and frame.state == constants.frame_states.catching}
        labels[key] = entry
        return entry
    end
    for _, move in ipairs(totals.move_list) do
        local l = label_of(move[2], move[3])
        js("m", js_list({move[1], move[2], move[3], l[1], l[2], move[2] ~= move[1] and l[3] or "", move[4], move[5], move[6],
            move[7], move[8], move[9], l[4] and "catch" or ""}))
    end
    for _, versus in ipairs(compact_versus(totals.versus_list)) do js("v", js_list(versus)) end
    -- The specials each fighter has (a D-sequence from a free stance) and never started: nothing measured about them.
    for _, fighter in ipairs(list) do
        local record = record_of(fighter.id)
        if record then
            local seen = {}
            for id, frame in pairs(record.frames) do
                if free_frame_states[frame.state] and frame.hits then
                    for _, field in ipairs(sequence_fields) do
                        local target = frame.hits[field]
                        if target and target ~= 0 then seen[abs(target)] = key_names[field] end
                    end
                end
            end
            local targets = {}
            for target in pairs(seen) do targets[#targets + 1] = target end
            table.sort(targets)
            for _, target in ipairs(targets) do
                local move = totals.moves[fighter.id .. " " .. fighter.id .. " " .. target]
                if (not move or move[4] == 0) and record.frames[target] then
                    js("u", js_list({fighter.id, fighter.id, target, seen[target], record.frames[target].name or ""}))
                end
            end
        end
    end

    -- The text summary.
    local function line(format, ...) engine.log("| " .. string.format(format, ...)) end
    line(text.title, tostring(config.mod or "?"), number_text(totals.meta[1]), label)
    line(text.rules, floor(limit / 1800 + 0.5), floor(stall / 30 + 0.5), config.weapons and text.on or text.off, #list,
        counted(#list * (#list - 1) / 2, text.pair1, text.pairs))
    if plan then
        line(text.plan, plan, counted(rounds, text.round1, text.rounds), string.format("%.1f", totals.meta[2] / 3600))
    end
    line("")
    if totals.meta[1] == 0 then line(text.no_data); return end
    local ranked = {}
    for _, fighter in ipairs(list) do
        local f = totals.fighters[fighter.id]
        if f and f[2] > 0 then
            local p, margin = rate(f[3], f[5], f[2])
            ranked[#ranked + 1] = {fighter = fighter, f = f, p = p, margin = margin}
        end
    end
    table.sort(ranked, function(x, y) if x.p ~= y.p then return x.p > y.p end return x.fighter.id < y.fighter.id end)
    line(text.ranking)
    for i, r in ipairs(ranked) do
        line(text.rank_line, i, tostring(r.fighter.name):sub(1, 18), r.p * 100, r.margin * 100, r.f[3], r.f[5], r.f[4], r.f[2],
            floor(r.f[8] / r.f[2] + 0.5))
    end
    line("")
    line(text.moves)
    local reviews = {}
    for _, r in ipairs(ranked) do
        local own = {}
        local dealt = 0
        for _, move in ipairs(totals.move_list) do
            if move[1] == r.fighter.id then own[#own + 1] = move; dealt = dealt + move[6] end
        end
        table.sort(own, function(x, y) return x[6] > y[6] end)
        local parts = {}
        for i = 1, min(3, #own) do
            local move = own[i]
            if move[6] > 0 and dealt > 0 then
                local l = label_of(move[2], move[3])
                local name = (l[1] ~= "" and (l[1] .. " ") or "") .. (l[2] ~= "" and l[2] or "frame") .. " (" .. move[3] .. ")"
                if move[2] ~= move[1] then name = "[" .. l[3] .. "] " .. name end
                local share = floor(move[6] * 100 / dealt + 0.5)
                local lands = move[4] > 0 and floor(move[5] * 100 / move[4] + 0.5) or 0
                local punished = move[4] > 0 and floor(move[8] * 100 / move[4] + 0.5) or 0
                if l[4] then
                    parts[#parts + 1] = string.format(text.catch_part, name, share, punished)
                else
                    parts[#parts + 1] = string.format(text.move_part, name, share, lands, punished)
                end
                -- (A catch begins on contact: no landing rate to ask of it. One that brings much of a fighter's
                -- damage is often the moves before it, which leave the opponent dazed; see how often it comes.)
                if share >= 30 and punished <= 15 and move[4] >= 50 then
                    if l[4] then
                        reviews[#reviews + 1] = string.format(text.review_catch, tostring(r.fighter.name), name,
                            string.format("%.1f", move[4] / r.f[2]), share, punished)
                    elseif lands >= 50 then
                        reviews[#reviews + 1] = string.format(text.review, tostring(r.fighter.name), name, share, lands, punished)
                    end
                end
            end
        end
        line("  %s: %s", tostring(r.fighter.name), table.concat(parts, "; "))
    end
    line("")
    line(text.review_title)
    if #reviews == 0 then line(text.none) end
    for _, review in ipairs(reviews) do line("%s", review) end
    line("")
    line(text.draws)
    local drawn = {}
    for _, pair in ipairs(totals.pair_list) do
        if pair[6] > 0 then drawn[#drawn + 1] = pair end
    end
    table.sort(drawn, function(x, y) return x[6] / x[3] > y[6] / y[3] end)
    if #drawn == 0 then line(text.none) end
    for i = 1, min(8, #drawn) do
        local pair = drawn[i]
        line(text.draw_line, tostring(name_of[pair[1]] or pair[1]), tostring(name_of[pair[2]] or pair[2]), pair[6], pair[3], pair[7], pair[8],
            pair[6] - pair[7] - pair[8])
    end
    line("")
    line(text.report)
end

function job.run(config)
    local step = config.step or "play"
    if step == "list" then return list_step(config) end
    if step == "play" then return play_step(config) end
    if step == "merge" then return merge_step(config) end
    error("balance: unknown step " .. tostring(step))
end
return job
