-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

-- The computer players of INSANE!, OpenLF2's own level above CRAZY! (the original has none). The original's AI
-- knows the original's fighters by id; this one learns any fighter's moves from its data, so mods' fighters
-- fight well too:
-- - Each fighter's moves (its D>A ... D+J+A specials, punches, jump, run and dash attacks, and what pressing
--   attack or jump continues into) are played once in a private copy of the game, by the game's own rules,
--   recording where and when they can hit (the fighter's own attacks and those of what it spawns), how it moves
--   and when it is free again. The copy draws random numbers from a fixed state and the game's generator is put
--   back afterwards, so nothing in the match changes and every computer in a network room learns the same.
-- - Every frame it looks at what is about to hit its fighter (enemies' moves in progress, flying attacks) and
--   strikes first, defends, steps out of the way in depth, jumps or backs off; otherwise it uses the move that
--   will hit its target, preferring sure, strong and cheap ones, follows up while the target is hurt, and keeps
--   the distance its best move wants.
-- What it decides comes only from the match and the game's random numbers, so replays and network play stay in
-- step.

local constants = require("base/game/constants")
local item = require("base/game/item")
local control = require("base/game/control")
local physics = require("base/game/physics")
local animation = require("base/game/animation")
local frame_rules = require("base/game/frame_rules")
local objects = require("base/game/objects")
local weapons = require("base/game/weapons")
local combat = require("base/game/combat")
local grab = require("base/game/grab")
local camera = require("base/game/camera")
local smart = {}

local abs, floor, min, max = math.abs, math.floor, math.min, math.max
local states = constants.frame_states
local frames = constants.character_frames
local combo = constants.combo_indices
local complete = constants.combo_states.complete
local facing_right, facing_left = constants.facings.right, constants.facings.left
local record_kinds = constants.record_kinds
local attack_kinds = constants.attack_kinds
local default_zwidth = constants.combat.default_zwidth
local break_threshold = constants.combat.defend_break_threshold
local team_enemies = constants.teams.enemies
local mode_stage = constants.modes.stage
local weapon_none = constants.weapon_holder_codes.none

-- Levels: the reaction delay (frames an enemy's move must have run before it is answered) and how often a
-- chance to attack is taken.
smart.levels = {
    [constants.difficulties.insane] = {reaction = 1, eagerness = 100},
}
-- Whether the computer player at `index` plays this way: at INSANE!, unless its mod gave the fighter an AI
-- script of its own (made for that fighter, which then plays as at CRAZY!).
function smart.enabled(state, value, index)
    if value.brain then return value.brain == "smart" end
    if state.random_game or state.replay_demo then return false end
    if smart.levels[state.difficulty] == nil then return false end
    return not require("base/game/ai_scripts").has(state, index)
end

local function trunc(value)
    if value >= 0 then return floor(value) end
    return -floor(-value)
end

---------------------------------------------------------------------------------------------------------------
-- Learning a fighter's moves.
---------------------------------------------------------------------------------------------------------------

local analyses = {} -- by the record's parsed data (one per file)
local horizon_ticks = 75 -- how long a move is followed in the copy
local max_moves = 60
local sandbox_x, sandbox_z, dummy_gap = 2000, 500, 230

-- A fixed table for the copy's random numbers (the game's own table may differ between matches).
local fixed_table
local function random_table()
    if fixed_table then return fixed_table end
    local bytes, seed = {}, 20261030
    for index = 1, 3000 do
        seed = (seed * 214013 + 2531011) % 4294967296
        bytes[index] = string.char(floor(seed / 65536) % 32768 % 255 + 1)
    end
    fixed_table = table.concat(bytes)
    return fixed_table
end

local free_states = {[states.standing] = true, [states.walking] = true, [states.running] = true}
local no_body_frame = {bodies = {}, center_x = 0, center_y = 0} -- a frame nothing can hit
local function is_free(value)
    local frame = value.record.frame(value.frame)
    if free_states[frame.state] then return true end
    if frame.state == states.jumping and value.frame == frames.jump + 2 then return true end
    if frame.state == states.dashing then return true end
    return false
end

local damaging_kinds = {[attack_kinds.plain] = true, [attack_kinds.catch] = true, [attack_kinds.reflect_ball] = true,
    [attack_kinds.whirlwind] = true, [attack_kinds.conditional_whirlwind] = true,
    [attack_kinds.pulling_whirlwind] = true, [attack_kinds.freezing_whirlwind] = true}
local function damaging(area)
    local kind = area.kind
    if not damaging_kinds[kind] then return false end
    if kind == attack_kinds.plain or kind == attack_kinds.reflect_ball then
        return area.effect ~= constants.effects.skip_characters and (area.injury > 0 or area.fall >= 20)
    end
    -- Catching always matters; whirlwinds only when they hurt or freeze.
    return kind == attack_kinds.catch or area.injury > 0 or kind == attack_kinds.freezing_whirlwind
end

-- World rectangle of a frame area, as base/game/combat computes it.
local function area_x(value, frame, area)
    if value.facing == facing_right then return area.x + value.x_int - frame.center_x end
    return frame.center_x + value.x_int - area.width - area.x
end

local held_nothing = {functions = "", function_presses = "", keys = {}}

local function new_sandbox(record)
    local state = {mode = constants.modes.versus, difficulty = constants.difficulties.difficult, running = true,
        items = {}, counter_12 = 0, counter_3 = 0, shake = 0, camera = 0, camera_step = 0, frame_number = 0,
        input_phase = 0, random_game = false, ai_skill = 0, round_counter = 0, winner = -1, elapsed = 0,
        finished = false, paused = false, pause_request = false, pause_next = false, cheat_lock = 2,
        heal_all = false, weapon_command = 0, function_counts = {[6] = 0, [7] = 0, [8] = 0, [9] = 0},
        background_row = 0, stage_bound = 0, camera_limit = 0, stage = {width = 4000, zboundary = {100, 900}},
        sandbox = true}
    local function place(slot, x, team, facing)
        local value = item.create(record)
        value.drop_counter = record.data.weapon and record.data.weapon.hp or 0
        value.x_int, value.y_int, value.z_int = x, 0, sandbox_z
        value.x, value.y, value.z = x, 0.0, sandbox_z
        value.vx, value.vy, value.vz = 0.0, 0.0, 0.0
        value.team, value.owner, value.slot, value.human = team, slot, slot, false
        value.facing = facing
        value.hp, value.dark_hp, value.max_hp, value.mp = 500, 500, 500, 500
        state.items[slot] = value
        return value
    end
    local me = place(0, sandbox_x, constants.teams.player_one, facing_right)
    local dummy = place(1, sandbox_x + dummy_gap, constants.teams.player_two, facing_left)
    dummy.blink = 1000000 -- nothing touches it
    return state, me
end

local function set_keys(value, held)
    for _, key in ipairs(item.keys) do
        local down = held and held[key] or false
        value.previous_keys[key] = value.keys[key]
        value.keys[key] = down
    end
end

-- Puts the fighter of a fresh copy where a move of this context starts. Returns false when it cannot.
-- A fighter whose frame 0 only leads to its standing frames (Blackbeard of One Piece GrandWorld: 0 to 329 to
-- 1-4) gets there first.
local function enter_context(state, me, context, step)
    step()
    for _ = 1, 120 do
        if me.record.frame(me.frame).state == states.standing and me.y_int == 0 then break end
        step()
    end
    if context == "ground" then return me.record.frame(me.frame).state == states.standing end
    if context == "air" then
        set_keys(me, {jump = true}); step()
        set_keys(me, nil)
        for _ = 1, 20 do
            step()
            if me.y_int < 0 and me.frame == frames.jump + 2 then
                step(); step()
                return me.frame == frames.jump + 2
            end
        end
        return false
    end
    -- Running: two fresh presses.
    set_keys(me, {right = true}); step()
    set_keys(me, nil); step()
    set_keys(me, {right = true}); step()
    for _ = 1, 3 do set_keys(me, {right = true}); me.previous_keys.right = true; step() end
    if me.record.frame(me.frame).state ~= states.running then return false end
    if context == "run" then return true end
    set_keys(me, {jump = true}); step()
    set_keys(me, nil); step()
    return me.record.frame(me.frame).state == states.dashing
end

local function add_box(list, t, value, frame, area, origin, own, me)
    local x = area_x(value, frame, area)
    local y = area.y + value.y_int - frame.center_y
    local zw = area.zwidth ~= 0 and area.zwidth or default_zwidth
    local base_x, base_y, base_z
    if own then base_x, base_y, base_z = me.x_int, me.y_int, me.z_int
    else base_x, base_y, base_z = origin.x, origin.y, origin.z end
    list[#list + 1] = {t = t, x1 = x - base_x, x2 = x - base_x + area.width, y1 = y - base_y, y2 = y - base_y + area.height,
        z = value.z_int - base_z, zw = zw, injury = area.injury or 0, fall = area.fall or 0, bdefend = area.bdefend or 0,
        dvx = area.dvx or 0, kind = area.kind, effect = area.effect or 0, own = own}
end

-- One frame of the private copy: the match's frame (base/game/match) without what cannot happen there (weapons
-- falling in, the round's end, input). Hits are worked out only when something could touch the untouchable
-- dummy (attacks of kind 8 and 14 ignore its blink) or when the dummy can be hit; items spawned during a phase
-- take part in its later slots, as in the match.
local homing_kinds = {[attack_kinds.heal] = true, [attack_kinds.obstacle] = true}
local function sandbox_step(state)
    state.frame_number = state.frame_number + 1
    state.shake = 1 - state.shake
    state.counter_12 = (state.counter_12 + 1) % 12
    state.counter_3 = (state.counter_3 + 1) % 3
    local items = state.items
    local last = 1
    for index = constants.item_slots - 1, 2, -1 do
        if items[index] then last = index; break end
    end
    for index = 10, last do
        local value = items[index]
        if value and value.record.kind ~= record_kinds.character and value.record.frame(value.frame).hits.Fa > 0 then
            objects.update(state, index)
        end
    end
    for index = constants.item_slots - 1, last + 1, -1 do
        if items[index] then last = index; break end
    end
    for index = 0, last do
        local value = items[index]
        if value then
            control.step(state, value)
            frame_rules.after_control(state, index, value)
        end
    end
    local touching = state.dummy_hittable
    local holding = false
    for index = 0, last do
        local value = items[index]
        if value then
            physics.step(state, value)
            if value.record.frame(value.frame).state == states.removed
               or (index > 1 and value.record.kind ~= record_kinds.character and abs(value.x - sandbox_x) > 1600) then
                objects.remove(state, index)
            end
            frame_rules.after_physics(state, index, value)
            if value.weapon ~= weapon_none then holding = true end
            if not touching then
                for _, area in ipairs(value.record.frame(value.frame).interactions) do
                    if homing_kinds[area.kind] then touching = true; break end
                end
            end
        end
    end
    if holding then weapons.carry(state) end
    if touching then
        combat.detect(state)
        for index = 0, last do
            local value = items[index]
            if value and value.record.kind == record_kinds.character then combat.apply(state, index) end
        end
        for index = 0, last do
            local value = items[index]
            if value and value.record.kind > record_kinds.character then combat.apply(state, index) end
        end
        grab.update_holds(state)
        grab.place_victims(state)
        camera.step(state)
        combat.apply_impulses(state)
    else
        for index = 0, last do
            local value = items[index]
            if value then value.frame_at_pass = value.frame end
        end
    end
    if holding then
        weapons.check_holders(state)
        weapons.carry(state)
    end
    local index = 0
    while index <= last do
        local value = items[index]
        if value then
            frame_rules.before_advance(state, index, value)
            animation.advance(state, value, index)
            local hundreds = floor(value.frame / 100)
            if hundreds == 11 or hundreds == 12 then
                value.blink = 1100 - value.frame
                value.frame = 0
            elseif value.frame < 0 or value.frame >= constants.frame_limit then
                value.frame = 0
                objects.remove(state, index)
            else
                if objects.spawn_from_frame(state, index, value) then
                    for spawned = constants.item_slots - 1, last + 1, -1 do
                        if items[spawned] then last = spawned; break end
                    end
                end
                objects.state_effects(state, index, value)
                value.state_frame = value.frame
            end
        end
        index = index + 1
    end
    if touching then combat.reset_lists(state) end
    state.sound_queue, state.sound_order, state.direct_sounds = nil, nil, nil
end

local summarize
-- How much a move hurts a fighter standing where its first thrown attack arrives (dx, dz from the start): what
-- it throws may only burst on hitting something, which the untouchable dummy of play() never shows.
local function measure_hit(record, entry, dx, dz, ticks)
    local state, me = new_sandbox(record)
    local dummy = state.items[1]
    local function step() sandbox_step(state) end
    if not enter_context(state, me, entry.context, step) then return 0 end
    dummy.x_int, dummy.y_int, dummy.z_int = me.x_int + dx, 0, me.z_int + dz
    dummy.x, dummy.y, dummy.z = dummy.x_int, 0.0, dummy.z_int
    dummy.blink, dummy.frame, dummy.facing = 0, 0, facing_left
    dummy.hp, dummy.dark_hp, dummy.max_hp = 5000, 5000, 5000
    state.dummy_hittable = true
    set_keys(me, nil)
    if entry.sequence then me.sequences[entry.sequence] = complete
    else
        me.frame = entry.frame
        me.wait_counter = 0
    end
    local chain_step = 1
    for _ = 1, ticks do
        step()
        set_keys(me, nil)
        local link = entry.chain and entry.chain[chain_step]
        if link and me.record.frame(me.frame).hits[link.key] == link.target then
            set_keys(me, {[link.button] = true})
            me.previous_keys[link.button] = false
            chain_step = chain_step + 1
        end
    end
    local loss = 5000 - dummy.hp
    if dummy.armor > 0 then loss = floor(loss * dummy.armor / 100) end
    return max(loss, 0)
end

-- Plays one move in a fresh copy and returns what it does, or nil when it does not start. The fighter has
-- full MP unless `mp` says otherwise.
smart.plays = 0
local function play(record, entry, mp)
    smart.plays = smart.plays + 1
    local state, me = new_sandbox(record)
    if mp then me.mp = mp end
    local function step()
        if smart.full_sandbox then require("base/game/match").step(state, held_nothing) else sandbox_step(state) end
        if smart.watch then smart.watch(state, me, entry) end
    end
    if not enter_context(state, me, entry.context, step) then return nil end
    if entry.walking then
        set_keys(me, {right = true}); step()
        if me.record.frame(me.frame).state ~= states.walking then return nil end
    end
    local start_frame = me.frame
    local origin = {x = me.x_int, y = me.y_int, z = me.z_int}
    local start_mp, start_hp, start_record = me.mp, me.hp, me.record
    local move = {entry = entry, boxes = {}, traj_x = {[0] = 0}, traj_y = {[0] = 0}, traj_z = {[0] = 0},
        vel_x = {[0] = me.vx}, vel_y = {[0] = me.vy}, frames = {}, ready = horizon_ticks, mp = 0, hp = 0}
    set_keys(me, nil)
    if entry.sequence then
        me.sequences[entry.sequence] = complete
    else
        me.frame = entry.frame
        me.wait_counter = 0
    end
    local chain_step = 1
    local started = false
    local quiet = 0
    local spawned = {}
    for t = 1, horizon_ticks do
        step()
        set_keys(me, nil)
        -- A chain is not over while a key of it is still to come (a stance between its keys may look free).
        local pending_link = entry.chain and chain_step <= #entry.chain
        -- A chained move: its key, pressed as soon as the fighter is in a frame that takes it there.
        local link = entry.chain and entry.chain[chain_step]
        if link and me.record.frame(me.frame).hits[link.key] == link.target then
            set_keys(me, {[link.button] = true})
            me.previous_keys[link.button] = false
            chain_step = chain_step + 1
            move.link_tick = t
        end
        if t == 1 then
            local first = me.frame_at_pass or me.frame
            if entry.sequence and first == start_frame and me.frame == start_frame then return nil end
            started = true
        end
        move.traj_x[t], move.traj_y[t], move.traj_z[t] = me.x_int - origin.x, me.y_int - origin.y, me.z_int - origin.z
        move.vel_x[t], move.vel_y[t] = me.vx, me.vy
        local at_pass = me.frame_at_pass or me.frame
        move.frames[t] = at_pass
        local frame = me.record.frame(at_pass)
        for _, area in ipairs(frame.interactions) do
            if damaging(area) then add_box(move.boxes, t, me, frame, area, origin, true, me) end
        end
        local objects_active = false
        for index = 2, constants.item_slots - 1 do
            local value = state.items[index]
            if value and value.owner == me.owner then
                spawned[value] = spawned[value] or t
                if value.frame_at_pass then
                    local object_frame = value.record.frame(value.frame_at_pass)
                    for _, area in ipairs(object_frame.interactions) do
                        if damaging(area) then
                            add_box(move.boxes, t, value, object_frame, area, origin, false, me)
                            move.boxes[#move.boxes].spawn = spawned[value]
                            objects_active = true
                        end
                    end
                end
            end
        end
        if me.record ~= start_record and not move.transform then move.transform = me.record end
        if me.record.frame(me.frame).state == states.teleport_to_enemy and not move.teleport then move.teleport = t end
        if move.ready == horizon_ticks and t > 1 and is_free(me) and not pending_link then move.ready = t end
        if move.ready < horizon_ticks then
            quiet = objects_active and 0 or quiet + 1
            if quiet > 2 or t > move.ready + 45 then break end
        end
    end
    if not started then return nil end
    -- A chain whose keys did not all take is only its first move again.
    if entry.chain and chain_step <= #entry.chain then return nil end
    move.mp = start_mp - me.mp
    move.hp = start_hp - me.hp
    move.length = #move.traj_x
    return summarize(move)
end

-- The part of a chained move after its last key, as a move of its own: what pressing that key does when the
-- fighter is already in the frame that takes it.
local function continuation(data, move)
    local entry = move.entry
    local link = entry.chain[#entry.chain]
    local from = move.link_tick
    if not from or from >= move.length then return nil end
    local cost = data.frames[link.target] and data.frames[link.target].mp or 0
    local mp_cost = cost % 1000
    local part = {entry = {context = entry.context, frame = link.target, parent = true, from = link.from, key = link.key,
            button = link.button},
        boxes = {}, traj_x = {[0] = 0}, traj_y = {[0] = 0}, traj_z = {[0] = 0},
        vel_x = {[0] = move.vel_x[from]}, vel_y = {[0] = move.vel_y[from]}, frames = {},
        ready = max(move.ready - from, 1), mp = cost >= 0 and mp_cost or 0, hp = cost >= 0 and floor(cost / 1000) * 10 or 0}
    local bx, by, bz = move.traj_x[from], move.traj_y[from], move.traj_z[from]
    for t = from + 1, move.length do
        local k = t - from
        part.traj_x[k], part.traj_y[k], part.traj_z[k] = move.traj_x[t] - bx, move.traj_y[t] - by, move.traj_z[t] - bz
        part.vel_x[k], part.vel_y[k] = move.vel_x[t], move.vel_y[t]
        part.frames[k] = move.frames[t]
    end
    for _, box in ipairs(move.boxes) do
        if box.t > from then
            local copy = {}
            for key, value in pairs(box) do copy[key] = value end
            copy.t = box.t - from
            if not box.own then
                copy.x1, copy.x2 = box.x1 - bx, box.x2 - bx
                copy.y1, copy.y2 = box.y1 - by, box.y2 - by
                copy.z = box.z - bz
                copy.spawn = max(box.spawn - from, 0)
            end
            part.boxes[#part.boxes + 1] = copy
        end
    end
    part.length = #part.traj_x
    part.hit_damage = move.hit_damage
    return summarize(part)
end

-- Sorts a move's boxes and sums up when, where and how hard it hits.
summarize = function(move)
    table.sort(move.boxes, function(a, b)
        if a.t ~= b.t then return a.t < b.t end
        return a.injury > b.injury
    end)
    local first, last, injury, fall, bdefend = nil, 0, 0, 0, 0
    local x1, x2, z = 100000, -100000, 0
    for _, box in ipairs(move.boxes) do
        first = first or box.t
        last = max(last, box.t)
        injury = max(injury, box.injury)
        fall = max(fall, box.fall)
        bdefend = max(bdefend, box.bdefend)
        local ox = box.own and move.traj_x[box.t] or 0
        x1, x2 = min(x1, box.x1 + ox), max(x2, box.x2 + ox)
        z = max(z, abs(box.z + (box.own and move.traj_z[box.t] or 0)) + box.zw)
    end
    move.first, move.last, move.injury, move.fall, move.bdefend = first, last, injury, fall, bdefend
    move.reach_x1, move.reach_x2, move.reach_z = x1, x2, z
    -- A victim is hit again only after arest/vrest; a fair estimate of a move's damage is its strongest box plus a
    -- share of the others.
    local total = 0
    for _, box in ipairs(move.boxes) do total = total + box.injury end
    move.damage = first and min(injury + floor((total - injury) / 4), injury * 3) or 0
    return move
end

local sequence_fields = {
    {field = "Fa", sequence = combo.right_attack}, {field = "Ua", sequence = combo.up_attack},
    {field = "Da", sequence = combo.down_attack}, {field = "Fj", sequence = combo.right_jump},
    {field = "Uj", sequence = combo.up_jump}, {field = "Dj", sequence = combo.down_jump},
    {field = "ja", sequence = combo.jump_attack},
}
local context_frames = {ground = {0, 5}, air = {frames.jump + 2}, run = {frames.running}, dash = {frames.dash}}
local context_order = {"ground", "air", "run", "dash"}

local function analyze(record)
    local data = record.data
    local found = analyses[data]
    if found then return found end
    local analysis = {moves = {}, frames = {}, lock = {}}
    analyses[data] = analysis
    if record.kind ~= record_kinds.character then return analysis end
    local saved_table, saved_index, saved_sequence = engine.random_state()
    local runtime = require("base/game/ai_scripts").runtime
    local saved_self_o, saved_self_n = runtime.self.o, runtime.self.n
    local saved_target_o, saved_target_n = runtime.target.o, runtime.target.n
    local entries, seen, deferred = {}, {}, {}
    local function want(entry)
        local key = entry.context .. ":" .. tostring(entry.sequence and ("s" .. entry.sequence .. ":" .. entry.frame) or entry.frame)
        if entry.parent then key = key .. ":from" .. entry.from end
        for _, link in ipairs(entry.chain or {}) do key = key .. ">" .. link.from .. link.button end
        if seen[key] or #entries >= max_moves then return end
        seen[key] = true
        -- What follows the super punch (only thrown into a broken guard) is learned last, when there is room.
        if entry.basic == "super_punch" and entry.chain then deferred[#deferred + 1] = entry return end
        entries[#entries + 1] = entry
    end
    for _, context in ipairs(context_order) do
        for _, spec in ipairs(sequence_fields) do
            for _, frame_id in ipairs(context_frames[context]) do
                local frame = data.frames[frame_id]
                local target = frame and frame.hits[spec.field] or 0
                if target ~= 0 then
                    -- A key only the walking frames carry (Blackbeard of One Piece GrandWorld) is pressed walking.
                    want({context = context, sequence = spec.sequence, field = spec.field, frame = target,
                        walking = context == "ground" and frame_id == frames.walking or nil})
                    break
                end
            end
        end
    end
    if data.frames[frames.defend] then want({context = "ground", frame = frames.defend, basic = "defend"}) end
    if data.frames[frames.punch] then want({context = "ground", frame = frames.punch, basic = "attack"}) end
    if data.frames[frames.punch + 5] then want({context = "ground", frame = frames.punch + 5, basic = "attack2"}) end
    if data.frames[frames.super_punch] then want({context = "ground", frame = frames.super_punch, basic = "super_punch"}) end
    if data.frames[frames.jump_attack] then want({context = "air", frame = frames.jump_attack, basic = "jump_attack"}) end
    if data.frames[frames.run_attack] then want({context = "run", frame = frames.run_attack, basic = "run_attack"}) end
    if data.frames[frames.dash_attack] then want({context = "dash", frame = frames.dash_attack, basic = "dash_attack"}) end
    local index = 1
    while index <= #entries do
        local entry = entries[index]
        engine.set_random_state(random_table(), 0, 0)
        local ok, move = pcall(play, record, entry)
        if ok and move and not move.first and move.mp == 0 and not move.transform and not move.teleport then
            -- Nothing seen with MP full: a move that fills MP (a chakra charge in Naruto: The Setting Dawn) only
            -- shows when there is room for it.
            engine.set_random_state(random_table(), 0, 0)
            local ok_again, again = pcall(play, record, entry, 150)
            if ok_again and again and again.mp < 0 then move = again end
        end
        local signature
        -- The guard itself (the defend key leading to defending frames at once) is no move, but the keys its
        -- frames take are explored below: a mod's fighter may strike out of its guard (Sanji of One Piece
        -- GrandWorld). Otherwise the defend key is one of the fighter's moves (Blackbeard's dark field), kept as such.
        local guard_move
        if ok and move and entry.basic == "defend" and not entry.chain then
            local guards = false
            for t = 1, min(3, move.length) do
                local id = move.frames[t]
                if id and record.frame(id).state == states.defending then guards = true end
            end
            analysis.guard = guards
            if guards then guard_move, move = move, nil end
        end
        if ok and move then
            local parts = {entry.context, entry.sequence or entry.basic or "", move.mp}
            for t = 1, min(move.length, 40) do parts[#parts + 1] = move.frames[t] end
            signature = table.concat(parts, ",")
            if seen[signature] then move = nil else seen[signature] = true end
        end
        if ok and move then
            -- What it throws, measured on a fighter it reaches.
            for _, box in ipairs(move.boxes) do
                if not box.own then
                    if box.injury < 30 then
                        engine.set_random_state(random_table(), 0, 0)
                        local measured_ok, measured = pcall(measure_hit, record, entry, floor((box.x1 + box.x2) / 2), box.z,
                            min(box.t + 30, horizon_ticks))
                        if measured_ok then move.hit_damage = measured end
                    end
                    break
                end
            end
            move.index = #analysis.moves + 1
            analysis.moves[move.index] = move
            if entry.chain then
                local part = continuation(data, move)
                if part then
                    part.index = #analysis.moves + 1
                    analysis.moves[part.index] = part
                end
            end
            for t = 1, move.length do
                local frame_id = move.frames[t]
                if frame_id and not analysis.frames[frame_id] then analysis.frames[frame_id] = {move = move, t = t} end
            end
        end
        local explored = move or guard_move
        if ok and explored then
            -- Pressing attack, jump or defend in one of its frames continues into another move: that move from
            -- the frame (when the fighter is already there) and the whole sequence from this move's start.
            local depth = entry.chain and #entry.chain or 0
            if not entry.parent and depth < 2 and entry.basic ~= "attack2" then
                local listed = {}
                for t = (explored.link_tick or 0) + 1, min(explored.length, 40) do
                    local frame_id = explored.frames[t]
                    local frame = data.frames[frame_id]
                    if frame and not listed[frame_id] then
                        listed[frame_id] = true
                        for _, key in ipairs({"a", "j", "d"}) do
                            local target = frame.hits[key]
                            local link_key = key .. target
                            if target > 0 and target ~= 999 and data.frames[target] and not listed[target] and not listed[link_key] then
                                listed[link_key] = true
                                local button = key == "a" and "attack" or (key == "j" and "jump" or "defend")
                                local chain = {}
                                for position, link in ipairs(entry.chain or {}) do chain[position] = link end
                                chain[#chain + 1] = {from = frame_id, button = button, key = key, target = target}
                                want({context = entry.context, sequence = entry.sequence, field = entry.field, frame = entry.frame,
                                    basic = entry.basic, chain = chain})
                            end
                        end
                    end
                end
            end
        end
        index = index + 1
        if index > #entries and #deferred > 0 then
            for _, entry in ipairs(deferred) do
                if #entries < max_moves then entries[#entries + 1] = entry end
            end
            deferred = {}
        end
    end
    engine.set_random_state(saved_table, saved_index, saved_sequence)
    runtime.self.o, runtime.self.n = saved_self_o, saved_self_n
    runtime.target.o, runtime.target.n = saved_target_o, saved_target_n
    analysis.entries = #entries
    -- Moves by how they start; attack starts one of the two punches at random.
    analysis.by_sequence, analysis.chains = {}, {}
    for _, move in ipairs(analysis.moves) do
        local entry = move.entry
        if entry.basic == "attack" and not entry.chain then analysis.punch = move end
        if entry.basic == "attack2" and not entry.chain then analysis.punch2 = move end
        if entry.parent then
            analysis.chains[entry.from] = analysis.chains[entry.from] or {}
            local list = analysis.chains[entry.from]
            list[#list + 1] = move
        end
        if move.mp < 0 and move.first == nil then move.charge = -move.mp end
    end
    return analysis
end
smart.analyze = analyze

-- Whether a frame, or one of the few after it, can attack or spawn something.
local function may_attack(record, frame_id)
    local current = frame_id
    for _ = 1, 8 do
        local frame = record.frames[current]
        if not frame then return false end
        if frame.opoint.kind > 0 then return true end
        for _, area in ipairs(frame.interactions) do
            if damaging(area) then return true end
        end
        local next_id = frame.next
        if next_id == 0 or next_id == 999 or next_id == current then return false end
        current = next_id < 0 and -next_id or next_id
    end
    return false
end

-- The move a fighter is in and how far into it: from what was learned, or else learned now from its present
-- frame (moves reached in ways the analysis does not try, as a mod's AI script or the super punch may). The
-- result only depends on the fighter's data, so it does not matter when or on which computer it is learned.
local function where_of(record, analysis, value)
    local frame_id = value.frame
    local where = analysis.frames[frame_id]
    if where then return where end
    analysis.extra = analysis.extra or {}
    local known = analysis.extra[frame_id]
    if known ~= nil then return known or nil end
    local frame = record.frame(frame_id)
    local result = false
    if not free_states[frame.state] and frame.state ~= states.lying and frame.state ~= states.defending
       and record.kind == record_kinds.character and may_attack(record, frame_id) then
        local saved_table, saved_index, saved_sequence = engine.random_state()
        local runtime = require("base/game/ai_scripts").runtime
        local saved_self_o, saved_self_n = runtime.self.o, runtime.self.n
        local saved_target_o, saved_target_n = runtime.target.o, runtime.target.n
        engine.set_random_state(random_table(), 0, 0)
        local ok, move = pcall(play, record, {context = value.y_int < 0 and "air" or "ground", frame = frame_id, basic = "frame"})
        engine.set_random_state(saved_table, saved_index, saved_sequence)
        runtime.self.o, runtime.self.n = saved_self_o, saved_self_n
        runtime.target.o, runtime.target.n = saved_target_o, saved_target_n
        if ok and move and move.first then
            result = {move = move, t = 1}
            for t = 2, move.length do
                local id = move.frames[t]
                if id and not analysis.frames[id] and analysis.extra[id] == nil then analysis.extra[id] = {move = move, t = t} end
            end
        end
    end
    analysis.extra[frame_id] = result
    return result or nil
end

-- Frames until a fighter in `frame_id` is free again without input (stun, recovery), following next/wait.
local function lock_of(record, analysis, frame_id)
    local cached = analysis.lock[frame_id]
    if cached then return cached end
    local total, current, guard = 0, frame_id, 0
    while guard < 40 do
        guard = guard + 1
        local frame = record.frames[current]
        if not frame then break end
        if free_states[frame.state] then break end
        total = total + frame.wait + 1
        local next_id = frame.next
        if next_id == 0 or next_id == 999 then break end
        if next_id < 0 then next_id = -next_id end
        if next_id == current then total = total + 30; break end
        current = next_id
    end
    analysis.lock[frame_id] = total
    return total
end

-- A stance: frames that go round without ever reaching a free one until a key ends them (a chakra charge in
-- Naruto: The Setting Dawn, Blackbeard's dark field in One Piece GrandWorld). For a frame in one, the key of the
-- frame that frees the fighter soonest and how long that takes; nil for any other frame.
local function stance_exit(record, analysis, frame_id)
    local current, seen, cycles = frame_id, {}, false
    for _ = 1, 60 do
        local frame = record.frames[current]
        if not frame or free_states[frame.state] then return nil end
        if seen[current] then cycles = true; break end
        seen[current] = true
        local next_id = frame.next
        if next_id == 0 or next_id == 999 or next_id >= 1000 then return nil end
        if next_id < 0 then next_id = -next_id end
        current = next_id
    end
    if not cycles then return nil end
    local hits = record.frames[frame_id].hits
    local best_key, best_lock
    for _, key in ipairs({"d", "a", "j"}) do
        local target = hits[key]
        if target == 999 then
            best_key, best_lock = key, 0
            break
        elseif target > 0 and record.frames[target] then
            local lock = lock_of(record, analysis, target)
            if not best_lock or lock < best_lock then best_key, best_lock = key, lock end
        end
    end
    return best_key, best_lock
end

-- Frames a fighter stays in its guard after pressing defend (frame 110 and what follows it while defending).
local function defend_ticks(record, analysis)
    if analysis.defend_ticks then return analysis.defend_ticks end
    local total, current = 0, frames.defend
    for _ = 1, 10 do
        local frame = record.frames[current]
        if not frame or frame.state ~= states.defending then break end
        total = total + frame.wait + 1
        local next_id = frame.next
        if next_id <= 0 or next_id == 999 or next_id == current then break end
        current = next_id
    end
    analysis.defend_ticks = total
    return total
end

---------------------------------------------------------------------------------------------------------------
-- Geometry at play time.
---------------------------------------------------------------------------------------------------------------

local function hostile(state, a, b)
    if a.team == b.team and a.team ~= constants.teams.independent then return false end
    if state.mode == mode_stage then
        return (b.team ~= a.team and a.team == team_enemies) or (b.team == team_enemies and a.team ~= team_enemies)
    end
    return a.team ~= b.team
end

-- Extra distance after k frames of a speed difference dv: kept in the air, worn down by 1 a frame on the ground.
local function drift(dv, k, airborne)
    if k <= 0 or dv == 0 then return 0 end
    if airborne then return dv * k end
    local speed = abs(dv)
    local n = min(k, floor(speed))
    local sum = n * speed - n * (n - 1) / 2
    if dv > 0 then return sum end
    return -sum
end

-- Where a fighter will be `t` frames from now if nothing new happens (stunned and thrown fighters keep sliding,
-- walking and running ones keep going a while).
local function predict(value, t, fstate)
    local vx, vz = value.vx, value.vz
    local x, y, z = value.x, value.y, value.z
    local vy = value.vy
    if fstate == states.running then return trunc(x + vx * t), trunc(y), trunc(z + vz * t) end
    if fstate == states.walking then
        local walk = min(t, 4)
        return trunc(x + vx * walk), trunc(y), trunc(z + vz * walk)
    end
    for _ = 1, min(t, 25) do
        x = x + vx
        z = z + vz
        if y < 0 or vy < 0 then
            y = y + vy
            vy = vy + 1.7
            if y > 0 then y, vy = 0, 0 end
        else
            if vx > 0 then vx = max(vx - 1, 0) elseif vx < 0 then vx = min(vx + 1, 0) end
            if vz > 0 then vz = max(vz - 1, 0) elseif vz < 0 then vz = min(vz + 1, 0) end
        end
    end
    return trunc(x), trunc(y), trunc(z)
end

-- Whether an attack box in world coordinates touches any body of `value` (its frame `frame`) placed at (x, y).
local function touches(value, frame, x, y, bx1, bx2, by1, by2)
    local bodies = frame.bodies
    for index = 1, #bodies do
        local body = bodies[index]
        local left
        if value.facing == facing_right then left = body.x + x - frame.center_x
        else left = frame.center_x + x - body.width - body.x end
        local top = body.y + y - frame.center_y
        if bx1 < left + body.width and left < bx2 and by1 < top + body.height and top < by2 then return true end
    end
    return false
end

-- The first frame from now (1..horizon) at which `move` of `attacker` (facing `face`: 1 right, -1 left), which is
-- `from_t` frames into it, hits `victim`, and the box. The victim is where victim_at(k) puts it (x, y, z), in
-- the frame `vframe`, or vframe(k) when that is a function (a busy victim's frames to come).
-- Attacks of things the move spawned before now are left to the flying-attack check.
local function move_hits(attacker, face, move, from_t, victim, vframe, victim_at, horizon)
    local boxes = move.boxes
    local frame_at = type(vframe) == "function" and vframe or nil
    if #boxes == 0 or (not frame_at and #vframe.bodies == 0) then return nil end
    local traj_x, traj_y, traj_z = move.traj_x, move.traj_y, move.traj_z
    local ax, ay, az = attacker.x_int, attacker.y_int, attacker.z_int
    local nx, ny, nz = traj_x[from_t] or 0, traj_y[from_t] or 0, traj_z[from_t] or 0
    local dvx = attacker.vx * face - (move.vel_x[from_t] or 0)
    local dvy = attacker.vy - (move.vel_y[from_t] or 0)
    local airborne = attacker.y_int < 0
    if from_t == 0 then
        -- Quick reject on the whole move's reach.
        local dx = (victim.x_int - ax) * face
        if dx < move.reach_x1 - 150 or dx > move.reach_x2 + 150 then return nil end
        if abs(victim.z_int - az) > move.reach_z + 60 then return nil end
    end
    local last_k, px, py, pz = -1, 0, 0, 0
    for index = 1, #boxes do
        local box = boxes[index]
        local t = box.t
        local k = t - from_t
        if k > horizon then break end
        -- A move in progress hits already in this frame's combat (k = 0); one started now, from its first frame.
        if k >= (from_t > 0 and 0 or 1) and (box.own or box.spawn > from_t) then
            local ox, oy, oz
            if box.own then
                ox = traj_x[t] - nx + drift(dvx, k, airborne)
                oy = traj_y[t] - ny + (airborne and dvy * k or 0)
                oz = traj_z[t] - nz
            else
                local ks = box.spawn - from_t
                ox = -nx + drift(dvx, ks, airborne)
                oy = -ny + (airborne and dvy * ks or 0)
                oz = -nz
            end
            if k ~= last_k then
                px, py, pz = victim_at(k)
                last_k = k
            end
            local depth = az + oz + box.z - pz
            if depth < box.zw and depth > -box.zw then
                local bx1, bx2
                if face == 1 then bx1, bx2 = ax + ox + box.x1, ax + ox + box.x2
                else bx1, bx2 = ax - ox - box.x2, ax - ox - box.x1 end
                local vf = frame_at and frame_at(k) or vframe
                if touches(victim, vf, px, py, bx1, bx2, ay + oy + box.y1, ay + oy + box.y2) then return k, box end
            end
        end
    end
    return nil
end

---------------------------------------------------------------------------------------------------------------
-- Threats.
---------------------------------------------------------------------------------------------------------------

-- The earliest hit on `self` within `horizon` frames, when it stays where it is or moves by plan(k) -> dx, dy, dz
-- (in its present frame, or in frame_at(k) when given): frames, box, source. Enemies' moves in progress (answered
-- once they have run `reaction` frames) and flying attacks.
local function earliest_threat(state, index, self, horizon, plan, reaction, context, frame_at)
    local best_t, best_box, best_source
    local self_frame = self.record.frame(self.frame)
    if #self_frame.bodies == 0 and not frame_at then return nil end
    local sx, sy, sz = self.x_int, self.y_int, self.z_int
    local function self_at(k)
        if plan then
            local dx, dy, dz = plan(k)
            return sx + dx, sy + dy, sz + dz
        end
        return sx, sy, sz
    end
    local items = state.items
    for other = 0, constants.item_slots - 1 do
        local value = items[other]
        if value and other ~= index and value.hp > 0 and hostile(state, self, value) then
            if value.record.kind == record_kinds.character then
                if abs(value.x_int - sx) < 1000 and abs(value.z_int - sz) < 250 then
                    local analysis = context.analysis_of(value)
                    local where = where_of(value.record, analysis, value)
                    if where then
                        -- After a step a fighter's frame and wait counter are those of its next step (the counter
                        -- counting the steps already spent in the frame), which is k = 0 below.
                        local now = where.t + value.wait_counter
                        if now >= reaction then
                            local face = value.facing == facing_right and 1 or -1
                            local k, box = move_hits(value, face, where.move, now, self, frame_at or self_frame, self_at, best_t and best_t - 1 or horizon)
                            if k then best_t, best_box, best_source = k, box, value end
                        end
                    end
                end
            elseif abs(value.x_int - sx) < 1200 and abs(value.z_int - sz) < 300 then
                -- Something flying: the attack boxes of its frames to come, carried along by its speed.
                local record = value.record
                local frame_id = value.frame
                local frame = record.frame(frame_id)
                local left = frame.wait + 1 - value.wait_counter
                local airborne = value.y_int < 0 or record.kind == record_kinds.ball
                -- Step k = 1 is this frame's combat (after it moves); threats count frames from it.
                local limit = (best_t and best_t - 1 or horizon) + 1
                for k = 1, limit do
                    if left <= 0 then
                        local next_id = frame.next
                        if next_id == 0 or next_id == 1000 or next_id >= constants.frame_limit or next_id <= -constants.frame_limit then break end
                        if next_id < 0 then next_id = -next_id end
                        if next_id == 999 then next_id = 0 end
                        frame_id = next_id
                        frame = record.frame(frame_id)
                        if frame.undefined then break end
                        left = frame.wait + 1
                    end
                    left = left - 1
                    local interactions = frame.interactions
                    if #interactions > 0 then
                        local mx = trunc(airborne and value.vx * k or drift(value.vx, k, false))
                        local mz = trunc(value.vz * k)
                        local px, py, pz = self_at(k - 1)
                        local own_frame = frame_at and frame_at(k - 1) or self_frame
                        local hit
                        for _, area in ipairs(interactions) do
                            if damaging(area) then
                                local zw = area.zwidth ~= 0 and area.zwidth or default_zwidth
                                local depth = value.z_int + mz - pz
                                if depth < zw and depth > -zw then
                                    local x0 = area_x(value, frame, area)
                                    local y0 = area.y + value.y_int - frame.center_y
                                    if touches(self, own_frame, px, py, x0 + mx, x0 + mx + area.width, y0, y0 + area.height) then
                                        hit = {injury = area.injury, fall = area.fall, bdefend = area.bdefend, dvx = area.dvx,
                                            kind = area.kind, effect = area.effect, zw = zw}
                                        break
                                    end
                                end
                            end
                        end
                        if hit then
                            best_t, best_box, best_source = k - 1, hit, value
                            break
                        end
                    end
                end
            end
        end
    end
    return best_t, best_box, best_source
end

---------------------------------------------------------------------------------------------------------------
-- Choosing.
---------------------------------------------------------------------------------------------------------------

local function press(value, key) value.keys[key] = true end
local function fresh(value, key) value.keys[key] = true; value.previous_keys[key] = false end
-- The key that a frame's hit_a, hit_d, hit_j field answers to.
local key_names = {a = "attack", d = "defend", j = "jump"}
local function clear_keys(value)
    for _, key in ipairs(item.keys) do
        value.previous_keys[key] = value.keys[key]
        value.keys[key] = false
    end
end

local exposed_states = {[states.broken_defend] = true, [states.injured] = true, [states.falling] = true,
    [states.frozen] = true, [states.dizzy] = true, [states.burning] = true}

-- Whether a move can be started now from the fighter's present frame.
local function can_start(self, frame, fstate, move)
    local entry = move.entry
    if self.mp < move.mp or (move.hp > 0 and self.hp <= move.hp + 20) then return false end
    if entry.parent then return frame.hits[entry.key] == entry.frame end
    if entry.sequence then
        if self.weapon == record_kinds.heavy_item then return false end
        -- D+J+A of a transformed fighter changes it back instead.
        if entry.field == "ja" and self.transform ~= -1 then return false end
        return frame.hits[entry.field] == entry.frame
    end
    if self.weapon ~= weapon_none then return false end
    local basic = entry.basic
    if basic == "attack" then return fstate == states.standing or fstate == states.walking end
    if basic == "defend" then return (fstate == states.standing or fstate == states.walking) and self.defend_lock == 0 end
    -- Attacking a staggered fighter that offers the window (its kind-6 interaction) throws the super punch.
    if basic == "super_punch" then return (fstate == states.standing or fstate == states.walking) and self.super_window > 0 end
    if basic == "jump_attack" then return fstate == states.jumping and self.y_int < 0 end
    if basic == "run_attack" then return fstate == states.running end
    if basic == "dash_attack" then return fstate == states.dashing end
    return false
end

-- Moves that turn toward the target as they start: D>A / D>J choose the side, a punch turns with the direction key.
local function turns(move)
    local entry = move.entry
    return entry.sequence == combo.right_attack or entry.sequence == combo.right_jump or entry.basic == "attack"
end

local function start(self, move, target)
    if smart.on_start then smart.on_start(self, move) end
    local entry = move.entry
    if entry.parent then
        fresh(self, entry.button)
        return
    end
    if entry.chain then
        local memory = self.smart_memory
        memory.chain, memory.chain_step, memory.chain_age = entry.chain, 1, 0
    end
    if entry.sequence then
        local sequence = entry.sequence
        if sequence == combo.right_attack and target and target.x_int < self.x_int then sequence = combo.left_attack end
        if sequence == combo.right_jump and target and target.x_int < self.x_int then sequence = combo.left_jump end
        self.sequences[sequence] = complete
        return
    end
    if entry.basic == "attack" and target then
        if target.x_int > self.x_int then press(self, "right") elseif target.x_int < self.x_int then press(self, "left") end
    end
    if entry.basic == "defend" then
        if target and target.x_int > self.x_int then press(self, "right") elseif target and target.x_int < self.x_int then press(self, "left") end
        fresh(self, "defend")
        return
    end
    fresh(self, "attack")
end

-- What a box of `move` is worth against `target`: damage counting armor, defence and knocking down.
local function worth(target, box, blocked, move)
    local injury = box.injury
    if not box.own and move and move.hit_damage then injury = max(injury, move.hit_damage) end
    if target.armor > 0 then injury = floor(injury * 100 / target.armor) end
    if blocked then
        -- A guarded blow: a tenth of its damage, or a broken guard (the super punch follows); one that does
        -- neither is hardly worth the recovery it costs.
        if box.bdefend + target.timer_b8 >= break_threshold then return floor(injury / 10) + 15 end
        return floor(injury / 10)
    end
    local value = injury
    if box.kind == attack_kinds.catch then value = max(value, 45) end
    if box.fall >= 60 or target.timer_b0 + max(box.fall, 20) > 60 then value = value + 12 end
    if box.effect == constants.effects.freeze or box.effect == constants.effects.burn then value = value + 8 end
    return value
end

local function would_block(target, tstate, attacker_facing, box)
    if tstate ~= states.defending then return false end
    if box.bdefend >= 61 then return false end
    return attacker_facing ~= target.facing
end

-- The target's frame state k steps from now: the frame its move will be in (mods give some attacking frames
-- the defending state, which guards them as they strike), else its present one.
local function target_state_at(context, target, k)
    local where = context.target_where
    if where and where.value == target and k >= 0 then
        local id = where.move.frames[where.now + k]
        if id then return target.record.frame(id).state end
    end
    return target.record.frame(target.frame).state
end

-- The fastest hit the enemy `other` could land on `self`: frames from now and its damage, or nil. A free enemy
-- starts a move now (facing `self`); one held for `lock` frames starts it then, from standing, unless a follow-up
-- its move's coming frames take (a punch that goes on into the next) lands sooner.
local function enemy_reach(context, other, self, horizon, lock)
    local oframe = other.record.frame(other.frame)
    local ostate = oframe.state
    if lock > 0 then oframe, ostate = other.record.frame(frames.standing), states.standing end
    local analysis = context.analysis_of(other)
    local face = self.x_int >= other.x_int and 1 or -1
    local self_frame = self.record.frame(self.frame)
    local sx, sy, sz = self.x_int, self.y_int, self.z_int
    local function self_at() return sx, sy, sz end
    local best, damage
    -- A free enemy on its feet may first step in (its walking speed, a few frames) and then strike.
    local steps = (lock == 0 and (ostate == states.standing or ostate == states.walking)) and 3 or 0
    local walk = steps > 0 and ((other.record.movement or {}).walking_speed or 4) or 0
    local virtual = steps > 0 and {x_int = other.x_int, y_int = other.y_int, z_int = other.z_int, vx = 0, vy = 0, facing = other.facing} or nil
    for _, move in ipairs(analysis.moves) do
        if move.first and move.first <= horizon and (not best or move.first < best) and can_start(other, oframe, ostate, move) then
            local own_face = turns(move) and face or (other.facing == facing_right and 1 or -1)
            local k, box = move_hits(other, own_face, move, 0, self, self_frame, self_at, best and best - 1 or horizon)
            if k then best, damage = k, box.injury end
            if not k and virtual and move.first <= 8 then
                for step = 1, steps do
                    if best and step + move.first >= best then break end
                    virtual.x_int = other.x_int + trunc(face * walk * step)
                    k, box = move_hits(virtual, own_face, move, 0, self, self_frame, self_at, (best or horizon + 1) - step - 1)
                    if k then best, damage = step + k, box.injury; break end
                end
            end
        end
    end
    local from_standing = best
    if best then best = best + lock end
    local where = context.target_where
    if lock > 0 and where and where.value == other then
        local own_face = other.facing == facing_right and 1 or -1
        local traj_x, traj_z = where.move.traj_x, where.move.traj_z
        local base_x, base_z = traj_x[where.now] or 0, traj_z[where.now] or 0
        local virtual = {x_int = 0, y_int = other.y_int, z_int = 0, vx = 0, vy = 0, facing = other.facing}
        for k = 0, lock do
            if best and k >= best then break end
            local id = where.move.frames[where.now + k]
            if not id then break end
            local parts = analysis.chains[id]
            if parts then
                virtual.x_int = other.x_int + ((traj_x[where.now + k] or base_x) - base_x) * own_face
                virtual.z_int = other.z_int + (traj_z[where.now + k] or base_z) - base_z
                for _, part in ipairs(parts) do
                    if part.first and other.mp >= part.mp and (not best or k + part.first < best) then
                        local kk, box = move_hits(virtual, own_face, part, 0, self, self_frame, self_at, (best or horizon + lock + 1) - k - 1)
                        if kk then best, damage = k + kk, box.injury end
                    end
                end
            end
        end
    end
    return best, damage, from_standing
end

-- How far a fighter's quick blows reach in front of it (its own attacks, not what it throws).
local function melee_reach(analysis)
    if analysis.melee then return analysis.melee end
    local reach = 0
    for _, move in ipairs(analysis.moves) do
        local entry = move.entry
        if move.first and move.first <= 10 and move.damage >= 15 and not entry.parent
           and (entry.sequence or entry.basic == "attack" or entry.basic == "attack2") then
            for _, box in ipairs(move.boxes) do
                if box.own and box.t <= move.first + 4 then reach = max(reach, box.x2 + (move.traj_x[box.t] or 0)) end
            end
        end
    end
    analysis.melee = reach
    return reach
end

-- Where a fighter's quick, strong moves strike in front of it (its own blows and what it throws, in its facing
-- frame): {x1, x2, z, t, damage, unguardable, mp}.
local function danger_zones(analysis)
    if analysis.zones then return analysis.zones end
    local zones = {}
    for _, move in ipairs(analysis.moves) do
        local entry = move.entry
        if move.first and move.first <= 16 and not entry.parent and entry.context == "ground"
           and (entry.sequence or entry.basic == "attack" or entry.basic == "attack2") then
            local damage = max(move.damage, move.hit_damage or 0)
            if damage >= 25 then
                local x1, x2, z, unguardable, bdefend = 100000, -100000, 0, false, 0
                for _, box in ipairs(move.boxes) do
                    if box.t > move.first + 6 then break end
                    local ox = box.own and (move.traj_x[box.t] or 0) or 0
                    local oz = box.own and (move.traj_z[box.t] or 0) or 0
                    x1, x2 = min(x1, box.x1 + ox), max(x2, box.x2 + ox)
                    z = max(z, abs(box.z + oz) + box.zw)
                    if box.bdefend >= 61 then unguardable = true end
                    bdefend = max(bdefend, box.bdefend)
                end
                zones[#zones + 1] = {x1 = x1, x2 = x2, z = z, t = move.first, damage = damage,
                    unguardable = unguardable, mp = move.mp, bdefend = bdefend}
            end
        end
    end
    analysis.zones = zones
    return zones
end

-- The worst a free enemy could do to a fighter standing at (x, z) with one quick move, turned toward it: its
-- damage, weighed by how hard it is to answer (unguardable, or too quick to guard).
local function danger_at(target, analysis, x, z)
    local dx = abs(x - target.x_int)
    local dz = abs(z - target.z_int)
    local worst = 0
    for _, zone in ipairs(danger_zones(analysis)) do
        if target.mp >= zone.mp and dz < zone.z and dx > zone.x1 - 22 and dx < zone.x2 + 22 then
            -- Unguardable hurts in full; a quick blow is hard to guard, and a guard that breaks lets the rest in.
            local weight = zone.unguardable and 1.0 or (zone.t <= 3 and 0.55 or 0.2)
            if not zone.unguardable and zone.bdefend >= 16 then weight = weight + 0.2 end
            worst = max(worst, zone.damage * weight)
        end
    end
    -- Within a free enemy's quick blows it has the first move: a place to stay out of, though no reason to run.
    local reach = melee_reach(analysis)
    if reach > 0 and dz < 15 and dx < reach + 22 then worst = max(worst, 15) end
    return worst
end

-- Frames from now for which `target` cannot be hit: while it blinks, and, down, until it has got up and its
-- blinking after that (base/game/animation: not stage soldiers) is over; `lock` is how long it stays down.
-- A target expected to flip up (context.target_path) is hittable along its roll instead.
local function untouchable_for(context, target, tstate, lock)
    local frames_left = abs(target.blink)
    local path = context.target_path
    if path and path.value == target then return frames_left end
    if tstate == states.lying or tstate == states.falling then
        local state = context.state
        local blink = constants.blink.get_up_frames
        if (state.mode == mode_stage or state.mode == constants.modes.battle) and target.team == team_enemies
           and floor(target.record.id / 10) == 3 and target.record.id ~= constants.fighter_ids.bat then
            blink = 0
        end
        frames_left = max(frames_left, lock + blink)
    end
    return frames_left
end

-- The standing frame a fighter can be hit in (frame 0, or the first of its standing frames with a body: some
-- mods' fighters stand in frames 1-4 and keep frame 0 for an entrance).
local function standing_frame(record)
    for id = 0, 4 do
        local frame = record.frames[id]
        if frame and frame.state == states.standing then
            for _, body in ipairs(frame.bodies) do
                if abs(body.y) < 1000 then return frame end
            end
        end
    end
    return record.frame(frames.standing)
end

-- The frame `target` will be in k steps from now, as far as its move or stun tells: its move's frames
-- (context.target_where), then standing; a stunned fighter's own frame until it is free.
local function target_frame_at_fn(context, target, tframe, stunned)
    local where = context.target_where
    local standing = standing_frame(target.record)
    local path = context.target_path
    if path and path.value == target then
        local frames = path.path.frames
        return function(k)
            if k <= 0 then return tframe end
            return frames[min(k, #path.path.x)] or no_body_frame
        end
    end
    if where and where.value == target then
        return function(k)
            local id = where.move.frames[where.now + k]
            if id then return target.record.frame(id) end
            return standing
        end
    end
    if stunned > 0 then
        return function(k)
            if k > stunned then return standing end
            return tframe
        end
    end
    return tframe
end

-- A knocked fighter's two ways down, k = 1..recovery_horizon frames from now: flipping back onto its feet now
-- (the recovery frames, carried by the roll's speed until it lands, the landing crouch, standing), or letting the
-- fall finish (the falling frames in the air, then lying until it gets up, blinking). Each is the frame it would be
-- in (nil where nothing can hit it) and where it would be, relative to now.
local recovery_horizon = 30
local function hittable(frame)
    if not frame then return nil end
    for _, body in ipairs(frame.bodies) do
        if abs(body.y) < 1000 then return frame end
    end
    return nil
end
local function recovery_paths(self, analysis)
    local record = self.record
    local movement = record.movement or {}
    local roll, roll_height = movement.rowing_distance or 0, movement.rowing_height or 0
    local standing = hittable(standing_frame(record))
    local flip, fall = {frames = {}, x = {}, y = {}}, {frames = {}, x = {}, y = {}}
    -- Flipping (base/game/control recovering, physics landing).
    local current
    if self.facing == facing_right then current = self.vx <= 0.0 and 100 or 108 else current = self.vx >= 0.0 and 100 or 108 end
    if not record.frames[current] then current = nil end
    local vx
    if self.vx < 1.0 and self.vx > -1.0 then vx = self.facing == facing_left and roll or -roll
    else vx = self.vx > 0.0 and roll or -roll end
    local x, y, vy = 0, self.y, min(self.vy, roll_height)
    local left = current and record.frames[current].wait + 1 or 0
    local landed = false
    for k = 1, recovery_horizon do
        x = x + vx
        if landed then
            if vx > 0 then vx = max(vx - 1, 0) elseif vx < 0 then vx = min(vx + 1, 0) end
        else
            y = y + vy
            if y >= 0 then
                y, landed, vx = 0, true, vx / 3
                current = record.frames[frames.crouch_alternate] and frames.crouch_alternate or nil
                left = current and record.frames[current].wait + 1 or 0
            else
                vy = vy + 1.7
            end
        end
        flip.frames[k] = current and hittable(record.frames[current]) or (not current and standing) or nil
        flip.x[k], flip.y[k] = trunc(x), trunc(y)
        if current then
            left = left - 1
            if left <= 0 then
                local next_id = record.frames[current].next
                if next_id < 0 then next_id = -next_id end
                if next_id == 0 or next_id == 999 or next_id >= 1000 or not record.frames[next_id] then current = nil
                else current = next_id; left = record.frames[current].wait + 1 end
            end
        end
    end
    -- Letting the fall finish.
    local falling = hittable(record.frame(self.frame))
    local lying_id = self.frame >= 186 and frames.lying + 1 or frames.lying
    local lying = hittable(record.frames[lying_id])
    local lying_lock = record.frames[lying_id] and lock_of(record, analysis, lying_id) or 0
    x, y, vy, vx, landed = 0, self.y, self.vy, self.vx, false
    local down = 0
    for k = 1, recovery_horizon do
        if landed then
            down = down + 1
            fall.frames[k] = down <= lying_lock and lying or nil
        else
            x, y = x + vx, y + vy
            if y >= 0 then
                y, landed = 0, true
                fall.frames[k] = lying
            else
                vy = vy + 1.7
                fall.frames[k] = falling
            end
        end
        fall.x[k], fall.y[k] = trunc(x), trunc(y)
    end
    return flip, fall
end

-- A path's place and frame k frames from now, for earliest_threat.
local function path_plan(self, path)
    local base_y = self.y_int
    return function(k)
        if k <= 0 then return 0, 0, 0 end
        k = min(k, recovery_horizon)
        return path.x[k], path.y[k] - base_y, 0
    end
end
local function path_frames(self, path)
    local now = self.record.frame(self.frame)
    return function(k)
        if k <= 0 then return now end
        return path.frames[min(k, recovery_horizon)] or no_body_frame
    end
end

---------------------------------------------------------------------------------------------------------------
-- Knowing the opponent. Its data says what it can do; how it plays says what it will do. Each fighter in the
-- match is watched as the frames go by (once a frame, by whoever looks at it first): the blows it guarded and
-- the blows that landed on it while it was free, the attacks it started when an enemy was within its reach and
-- the frames it had the chance to, the falls it flipped out of, the jumps it took. Only the match's own state
-- goes in, so every machine of a network game counts the same.
---------------------------------------------------------------------------------------------------------------

local function model_of(context, value)
    local models = context.models
    if not models then models = {}; context.models = models end
    local model = models[value]
    if not model then
        model = {guards = 0, hits = 0, attacks = 0, chances = 0, falls = 0, flips = 0, jumps = 0, frames = 0,
            frame = value.frame, hp = value.hp, b8 = value.timer_b8, free = true, fstate = states.standing, seen = -1}
        models[value] = model
    end
    return model
end

-- One frame of watching `value`; `nearby` says whether an enemy stands within its reach (a chance to attack).
local function watch(context, value, nearby)
    local model = model_of(context, value)
    local now = context.state.frame_number
    if model.seen == now then return model end
    model.seen = now
    local frame = value.record.frame(value.frame)
    local fstate = frame.state
    local free_now = is_free(value) or fstate == states.defending
    if fstate == states.defending and value.timer_b8 > model.b8 then model.guards = model.guards + 1 end
    if value.hp < model.hp - 6 and model.free and exposed_states[fstate] then model.hits = model.hits + 1 end
    if model.free and not free_now and not exposed_states[fstate] and fstate ~= states.lying and fstate ~= states.caught
       and fstate ~= states.catching and where_of(value.record, context.analysis_of(value), value) then
        model.attacks = model.attacks + 1
    end
    if model.free and nearby then model.chances = model.chances + 1 end
    if fstate == states.jumping and model.fstate ~= states.jumping and value.y_int == 0 then model.jumps = model.jumps + 1 end
    local recovering = value.frame == 182 or value.frame == 188
    local was_recovering = model.frame == 182 or model.frame == 188
    if recovering and not was_recovering then model.falls = model.falls + 1 end
    if was_recovering and (value.frame == 100 or value.frame == 108) then model.flips = model.flips + 1 end
    model.frames = model.frames + 1
    model.frame, model.hp, model.b8, model.free, model.fstate = value.frame, value.hp, value.timer_b8, free_now, fstate
    return model
end

-- Where a target expected to flip up (context.target_path) will be k frames from now, or nil for no such path.
local function path_position_fn(context, target)
    local path = context.target_path
    if not (path and path.value == target) then return nil end
    local xs, ys = path.path.x, path.path.y
    local x0, y0, z0 = target.x_int, target.y_int, target.z_int
    return function(k)
        if k <= 0 then return x0, y0, z0 end
        k = min(k, #xs)
        return x0 + xs[k], ys[k], z0
    end
end

-- How likely this fighter is to guard a blow it sees coming (what it did so far, around a middling prior).
local function guard_rate(model)
    return (model.guards + 1.3) / (model.guards + model.hits + 2)
end
-- Attacks a second when an enemy is within its reach (how pressing it is), once there is something to go on.
local function pressure(model)
    if model.chances < 90 then return nil end
    return model.attacks / (model.chances + 30) * 30
end
-- Whether it flips back up out of a fall as soon as it may (humans mostly do; the original computer player does
-- not), once seen a couple of times.
local function flips_up(model)
    return model.falls >= 2 and model.flips * 2 >= model.falls
end

-- What `move` (started `lead` frames from now) landing its box `box` on `target` after `t` frames is worth:
-- damage weighed by how sure the hit is, what a guard would cost, MP, and what being busy afterwards would cost.
local function attack_score(context, target, tstate, move, t, box, face, stunned, danger, stagger, lead)
    local blocked = would_block(target, target_state_at(context, target, t - 1), face == 1 and facing_right or facing_left, box)
    -- A hit is sure while the target cannot act; otherwise it may step away or guard in time.
    local sure = 1.0
    if t > stunned then sure = max(0.2, 1.0 - (t - stunned) * 0.04) end
    if danger and t > danger - 2 then sure = sure * 0.6 end
    -- A free target facing the blow can raise its guard in time (mods' fighters then often strike back from
    -- the guard): the likelier the longer the blow takes, and the more this one has guarded so far; a guarded
    -- blow is worth a tenth, or a broken guard. The longer nothing has happened, the more it is worth trying.
    local guarded = blocked and 1 or 0
    if not blocked and t > stunned and box.bdefend < 61 and (tstate == states.standing or tstate == states.walking)
       and target.facing ~= (face == 1 and facing_right or facing_left) then
        guarded = guard_rate(model_of(context, target)) * min(1, (1 - 0.9 ^ (t - stunned)) * 1.25) * (1 - 0.5 * (context.aggression or 0))
    end
    local damage = worth(target, box, false, move) * (1 - guarded) + worth(target, box, true, move) * guarded
    local score = damage * sure
    if not blocked and guarded > 0 then score = score - guarded * (context.guard_counter or 20) end
    score = score - move.mp * 0.06 - max(move.hp, 0) * 0.5
    score = score * 14 / (t + 10)
    -- Still busy when the target, back on its feet, could land its quickest blow: that blow is the price.
    local ready = move.ready + lead
    local knocked = box.fall >= 60 or target.timer_b0 + max(box.fall, 20) > 60
    local back_at = t + (knocked and 30 or stagger) + (context.counter_first or 99)
    if ready >= back_at - 1 then score = score - (context.counter_damage or 0) * 0.7 * 14 / (t + 10) end
    local open = ready - t - (knocked and 30 or stagger)
    if open > 0 then score = score - open * 0.2 end
    -- The whole of what the fighter can do gets its turn: a move not yet tried this match is a little more
    -- tempting, one just used a little less (the choice stays the fighter's own, from its own data).
    local last_use = context.last_use
    if last_use and score > 0 then
        local last = last_use[move.index]
        if not last then score = score * 1.1
        elseif context.now - last < 90 then score = score * 0.85 end
    end
    return score
end

-- The best move to start now against `target`: move, frames until it hits, score. Moves that would land only
-- after the target could have hit back (`danger` frames) are left out.
local function best_attack(context, self, frame, fstate, target, horizon, danger, excluded)
    local analysis = context.analysis_of(self)
    local tframe = target.record.frame(target.frame)
    local tstate = tframe.state
    local best, best_t, best_score = nil, nil, 0
    local stunned = context.target_lock or 0
    local untouchable = untouchable_for(context, target, tstate, stunned)
    local toward = target.x_int >= self.x_int and 1 or -1
    local target_at = path_position_fn(context, target) or function(k) return predict(target, k, tstate) end
    local target_frame = target_frame_at_fn(context, target, tframe, stunned)
    local stagger = lock_of(target.record, context.analysis_of(target), frames.injured)
    for _, move in ipairs(analysis.moves) do
        local entry = move.entry
        if move.first and move.first <= horizon and entry.basic ~= "attack2" and not (excluded and excluded[move])
           and can_start(self, frame, fstate, move) then
            local face = turns(move) and toward or (self.facing == facing_right and 1 or -1)
            local t, box = move_hits(self, face, move, 0, target, target_frame, target_at, horizon)
            -- Attack picks one of two punches: both must land, the later counts.
            if t and entry.basic == "attack" and not entry.chain and analysis.punch2 then
                local t2, box2 = move_hits(self, face, analysis.punch2, 0, target, target_frame, target_at, horizon)
                if not t2 then t = nil
                elseif t2 > t then t, box = t2, box2 end
            end
            -- Nothing lands while the target blinks (and, down, it gets up blinking).
            if t and t <= untouchable then t = nil end
            -- Landing together with the target's quickest answer is a trade at worst: it has not started it yet.
            if t and (not danger or t < danger or (t == danger and stunned == 0)) then
                local score = attack_score(context, target, tstate, move, t, box, face, stunned, danger, stagger, 0)
                if score > best_score then best, best_t, best_score = move, t, score end
            end
        end
    end
    return best, best_t, best_score
end

-- Where `move` of `self` (turned toward `target` when it turns) takes the fighter and what frames it is in, k frames
-- after starting it: for earliest_threat, which tells whether a blow already on its way lands on that path.
local function move_path(self, move, target)
    local face = turns(move) and (target.x_int >= self.x_int and 1 or -1) or (self.facing == facing_right and 1 or -1)
    local record = self.record
    local now = record.frame(self.frame)
    local length = move.length
    local plan = function(k)
        if k <= 0 then return 0, 0, 0 end
        k = min(k, length)
        return (move.traj_x[k] or 0) * face, move.traj_y[k] or 0, move.traj_z[k] or 0
    end
    local frames_at = function(k)
        if k <= 0 then return now end
        local id = move.frames[min(k, length)]
        return id and record.frame(id) or now
    end
    return plan, frames_at
end

-- Whether `move` can start from the airborne frame `air_frame` (the jump's or the dash's), MP and weapon allowing.
local function starts_airborne(self, move, air_frame)
    local entry = move.entry
    if entry.parent or not move.first then return false end
    if self.mp < move.mp or (move.hp > 0 and self.hp <= move.hp + 20) then return false end
    if entry.sequence then
        if self.weapon == record_kinds.heavy_item then return false end
        if entry.field == "ja" and self.transform ~= -1 then return false end
        return air_frame.hits[entry.field] == entry.frame
    end
    if self.weapon ~= weapon_none then return false end
    return entry.basic == "jump_attack" or entry.basic == "dash_attack"
end

-- Jumping in (from the ground) or dashing (out of a run) toward the target: the air move that would land as the
-- fighter flies, started some frames after taking off, and its score and frames until it hits. The flight is the
-- game's: the jump's speed and height from the fighter's data, gravity 1.7 a frame (base/game/physics).
local jump_starts = {2, 5, 8, 11, 14}
local dash_starts = {1, 4, 7}
local function approach_attack(context, self, fstate, target, danger)
    local analysis = context.analysis_of(self)
    local movement = self.record.movement or {}
    local running = fstate == states.running
    local speed, height, lead, air_frame, starts
    if running then
        speed, height = movement.dash_distance or 0, movement.dash_height or 0
        lead, air_frame, starts = 1, self.record.frame(frames.dash), dash_starts
    else
        speed, height = movement.jump_distance or 0, movement.jump_height or 0
        local first, second = self.record.frames[frames.jump], self.record.frames[frames.jump + 1]
        lead = (first and first.wait + 1 or 1) + (second and second.wait + 1 or 1)
        air_frame, starts = self.record.frame(frames.jump + 2), jump_starts
    end
    if speed <= 0 or height >= 0 then return nil end
    local want = running and "dash" or "air"
    local tframe = target.record.frame(target.frame)
    local tstate = tframe.state
    local stunned = context.target_lock or 0
    local untouchable = untouchable_for(context, target, tstate, stunned)
    local stagger = lock_of(target.record, context.analysis_of(target), frames.injured)
    local dir = target.x_int >= self.x_int and 1 or -1
    local target_frame = target_frame_at_fn(context, target, tframe, stunned)
    local along = path_position_fn(context, target)
    local virtual = {x_int = 0, y_int = 0, z_int = self.z_int, vx = 0, vy = 0, facing = self.facing}
    local best, best_t, best_score = nil, nil, 0
    local y, vy, flown = 0, height, 0
    for _, s in ipairs(starts) do
        while flown < s do y = y + vy; vy = vy + 1.7; flown = flown + 1 end
        if y >= -8 then break end
        virtual.x_int, virtual.y_int, virtual.vx, virtual.vy = self.x_int + trunc(dir * speed * s), trunc(y), dir * speed, vy
        local offset = lead + s
        local function target_at(k)
            if along then return along(offset + k) end
            return predict(target, offset + k, tstate)
        end
        local frame_at = target_frame
        if type(target_frame) == "function" then frame_at = function(k) return target_frame(offset + k) end end
        for _, move in ipairs(analysis.moves) do
            if move.entry.context == want and starts_airborne(self, move, air_frame) then
                local t, box = move_hits(virtual, dir, move, 0, target, frame_at, target_at, 30)
                if t then
                    local total = offset + t
                    if total > untouchable and (not danger or total < danger) then
                        local score = attack_score(context, target, tstate, move, total, box, dir, stunned, danger, stagger, offset)
                        if score > best_score then best, best_t, best_score = move, total, score end
                    end
                end
            end
        end
    end
    return best, best_t, best_score, lead
end

-- The distance to keep: near the far end of where the fighter's best quick, cheap move strikes first.
local function preferred_range(context, self)
    local analysis = context.analysis_of(self)
    if analysis.range then return analysis.range, analysis.range_z end
    local best, best_value, best_far = nil, -1, 0
    for _, move in ipairs(analysis.moves) do
        local entry = move.entry
        if move.first and move.first <= 12 and move.mp <= 30 and not entry.parent and not entry.chain
           and (entry.sequence or entry.basic == "attack") then
            local near, far = 100000, -100000
            for _, box in ipairs(move.boxes) do
                if box.t > move.first + 3 then break end
                local ox = box.own and move.traj_x[box.t] or 0
                near, far = min(near, box.x1 + ox), max(far, box.x2 + ox)
            end
            if far > 0 then
                local value = move.damage / (move.first + 4)
                if entry.basic == "attack" then value = value * 1.3 end
                if value > best_value then best, best_value, best_far = move, value, far end
            end
        end
    end
    local range, range_z = 60, 8
    if best then
        range = max(30, min(best_far, 240))
        range_z = max(3, min(best.reach_z - 8, 12))
    end
    analysis.range, analysis.range_z = range, range_z
    return range, range_z
end

local function target_analysis_of(context, target) return context.analysis_of(target) end

-- Frames until the target can act again: stunned, down, or finishing a move.
local function target_lock_of(context, target, tframe)
    local tstate = tframe.state
    local analysis = context.analysis_of(target)
    if exposed_states[tstate] or tstate == states.lying then
        return max(lock_of(target.record, analysis, target.frame) - target.wait_counter, 0)
    end
    if not is_free(target) then
        local where = where_of(target.record, analysis, target)
        if where then return max(where.move.ready - (where.t + target.wait_counter), 0) end
    end
    return 0
end

-- Frames until the target could land a hit on `self` if it attacked as soon as it can, or nil when it could not
-- within a while.
local function counter_time(context, target, self, lock)
    if abs(target.x_int - self.x_int) > 450 or abs(target.z_int - self.z_int) > 90 then return nil end
    if lock == 0 and not is_free(target) then lock = 1 end
    local reach, damage, from_standing = enemy_reach(context, target, self, 16, lock)
    context.counter_first, context.counter_damage = from_standing, damage
    if not reach then return nil end
    return reach
end

local function choose_target(state, index, self, memory)
    local items = state.items
    local best, best_score
    for other = 0, constants.item_slots - 1 do
        local value = items[other]
        if value and other ~= index and value.hp > 0 and value.record.kind == record_kinds.character and hostile(state, self, value) then
            local distance = abs(value.x_int - self.x_int) + abs(value.z_int - self.z_int) * 2
            if other == memory.target then distance = distance - 80 end
            local tstate = value.record.frame(value.frame).state
            if exposed_states[tstate] then distance = distance - 60 end
            if tstate == states.lying then distance = distance + 120 end
            -- Among several enemies (a team, a stage): one busy with a move cannot answer, one low on HP is
            -- soonest out of the fight.
            if not is_free(value) and not exposed_states[tstate] and tstate ~= states.lying then distance = distance - 40 end
            if value.hp < 150 then distance = distance - 40 end
            if not best_score or distance < best_score then best, best_score = other, distance end
        end
    end
    memory.target = best
    return best
end

local function face(self, target_x)
    if target_x > self.x_int and self.facing == facing_left then press(self, "right")
    elseif target_x < self.x_int and self.facing == facing_right then press(self, "left") end
end

-- Turns to meet an attack: a guard holds against attacks whose facing is not the guard's own.
local function face_against(self, source)
    local wanted = 1 - source.facing
    if source.record.kind == record_kinds.character and source.x_int ~= self.x_int and abs(source.x_int - self.x_int) > 8 then
        wanted = source.x_int > self.x_int and facing_right or facing_left
    end
    if wanted ~= self.facing then press(self, wanted == facing_right and "right" or "left") end
end

-- Answers a threat in `threat_t` frames: true when it did something.
local function answer(state, index, self, frame, fstate, context, memory, level, threat_t, threat_box, source)
    local analysis = context.analysis_of(self)
    local can_defend = (fstate == states.standing or fstate == states.walking) and self.defend_lock == 0
        and self.weapon ~= record_kinds.heavy_item and analysis.guard ~= false
    -- A guard takes a tenth of the damage; it holds unless the defence points reach the break threshold.
    local guardable = threat_box.bdefend < 61
    local blockable = guardable and threat_box.bdefend + self.timer_b8 < break_threshold
    -- Strike first when a move lands before the threat does.
    -- (A move started now strikes t - 1 frames from now; the threat, threat_t frames from now.)
    if source.record.kind == record_kinds.character and threat_t >= 1 then
        local move, t = best_attack(context, self, frame, fstate, source, threat_t, nil)
        if move and t <= threat_t then
            start(self, move, source)
            memory.note = "strike first"
            return true
        end
    end
    local guard = defend_ticks(self.record, analysis)
    if blockable and fstate == states.defending then
        face_against(self, source)
        memory.note = "keep guard"
        return true
    end
    -- A heavy blow is better dodged than guarded when there is time (a guard broken by the next one lets a
    -- worse one in); a light one is simply guarded.
    local heavy = threat_box.injury >= 45 or threat_box.bdefend >= 16
    if blockable and can_defend and threat_t <= guard and threat_t <= 3 and not (heavy and threat_t >= 2) then
        face_against(self, source)
        fresh(self, "defend")
        memory.note = "defend " .. threat_t
        return true
    end
    if self.y_int < 0 or not (fstate == states.standing or fstate == states.walking or fstate == states.running) then
        return false
    end
    -- Out of the way: in depth, by jumping, or back.
    local movement = self.record.movement or {}
    local speedz = (fstate == states.running and movement.running_speedz or movement.walking_speedz) or 2
    local speed = movement.walking_speed or 4
    local near, far = state.stage.zboundary[1] or 0, state.stage.zboundary[2] or 0
    local reaction = level.reaction
    local sides = {}
    if self.z_int - near > 12 then sides[#sides + 1] = -1 end
    if far - self.z_int > 12 then sides[#sides + 1] = 1 end
    if #sides == 2 and (memory.dodge_dz == 1 or (memory.dodge_dz == 0 and source.z_int < self.z_int)) then
        sides[1], sides[2] = 1, -1
    end
    for _, side in ipairs(sides) do
        local plan = function(k) return 0, 0, trunc(side * speedz * k) end
        if not earliest_threat(state, index, self, threat_t + 8, plan, reaction, context) then
            memory.dodge_dz = side
            press(self, side > 0 and "down" or "up")
            memory.note = "dodge z"
            return true
        end
    end
    -- Jumping clears thrown attacks (fighters' blows reach too high to trust it).
    if fstate ~= states.running and source.record.kind ~= record_kinds.character then
        local height = movement.jump_height or -16
        local plan = function(k)
            if k < 3 then return 0, 0, 0 end
            local tt = k - 2
            local y = height * tt + 0.85 * tt * tt
            if y > 0 then y = 0 end
            return 0, trunc(y), 0
        end
        if not earliest_threat(state, index, self, threat_t + 6, plan, reaction, context) then
            fresh(self, "jump")
            memory.note = "jump dodge"
            return true
        end
    end
    local away = source.x_int > self.x_int and -1 or 1
    local width = state.stage_bound > 0 and state.stage_bound or (state.stage.width or constants.screen.width)
    local cornered = (away < 0 and self.x_int < 60) or (away > 0 and self.x_int > width - 60)
    local plan = function(k) return trunc(away * speed * k), 0, 0 end
    if not cornered and not earliest_threat(state, index, self, threat_t + 6, plan, reaction, context) then
        press(self, away > 0 and "right" or "left")
        memory.note = "back off"
        return true
    end
    -- A guard that would break (the points of the last blows still count) leaves the fighter helpless for the
    -- super punch that follows, unguarded: the blow itself, taken, costs less in the end.
    if blockable and fstate == states.defending then
        face_against(self, source)
        memory.note = "keep broken guard"
        return true
    end
    if blockable and can_defend and threat_t <= guard and threat_t <= 3 then
        face_against(self, source)
        fresh(self, "defend")
        memory.note = "defend late " .. threat_t
        return true
    end
    -- Nothing avoids it: at least out of its way as far as possible.
    if not cornered and threat_t > 1 then
        press(self, away > 0 and "right" or "left")
        memory.note = "flee"
        return true
    end
    return false
end

-- One frame of control for the computer player at `index`.
function smart.control(state, index)
    local items = state.items
    local self = items[index]
    local level = smart.levels[state.difficulty] or smart.levels[constants.difficulties.insane]
    local memory = self.smart_memory
    if not memory then
        memory = {target = nil, dodge_dz = 0}
        self.smart_memory = memory
    end
    local context = state.smart_context
    if not context then
        context = {state = state}
        function context.analysis_of(value) return analyze(value.record) end
        state.smart_context = context
    end
    clear_keys(self)
    local frame = self.record.frame(self.frame)
    local fstate = frame.state

    -- Falling: flipping back onto the feet (jump) is quick, but the roll it lands in can be hit; with an enemy
    -- still swinging there, or free right next to where the roll ends, the fall is let finish: lying cannot be
    -- hit and the fighter gets up blinking (untouchable) instead.
    if self.frame == 182 or self.frame == 188 then
        local target_index = choose_target(state, index, self, memory)
        local target = target_index and items[target_index]
        local flip, fall = recovery_paths(self, context.analysis_of(self))
        local flip_t, flip_box = earliest_threat(state, index, self, recovery_horizon, path_plan(self, flip), level.reaction, context, path_frames(self, flip))
        local fall_t, fall_box = earliest_threat(state, index, self, recovery_horizon, path_plan(self, fall), level.reaction, context, path_frames(self, fall))
        local stay = false
        if flip_t and fall_t then stay = flip_box.injury > fall_box.injury
        elseif flip_t then stay = true
        elseif not fall_t and target then
            -- Nothing on its way yet: the way that leaves fewer frames in which a free enemy next to us could hit.
            local tframe = target.record.frame(target.frame)
            local tlock = target_lock_of(context, target, tframe)
            local reach = melee_reach(context.analysis_of(target)) + 30
            local function exposure(path)
                local count = 0
                if abs(target.z_int - self.z_int) >= 24 then return 0 end
                for k = tlock + 1, recovery_horizon do
                    if path.frames[k] then
                        local tx = predict(target, k, tframe.state)
                        if abs(tx - (self.x_int + path.x[k])) < reach then count = count + 1 end
                    end
                end
                return count
            end
            stay = exposure(flip) > exposure(fall) + 2
        end
        if stay then
            memory.note = "stay down"
        else
            fresh(self, "jump")
            memory.note = "flip up"
        end
        return
    end
    if fstate == states.catching then
        if state.frame_number % 3 == 0 then fresh(self, "attack") end
        return
    end

    local free = fstate == states.standing or fstate == states.walking or fstate == states.running
        or fstate == states.jumping or fstate == states.dashing or fstate == states.defending

    -- A planned chain: its next key in a frame that takes it there (a guard's or the jump's frame may be
    -- that frame; the chain is over once the fighter stands, walks or runs again).
    if memory.chain then
        local link = memory.chain[memory.chain_step]
        local idle = fstate == states.standing or fstate == states.walking or fstate == states.running
        memory.chain_age = memory.chain_age + 1
        if not link or memory.chain_age > 60 or (idle and memory.chain_age > 2) then
            memory.chain = nil
        elseif frame.hits[link.key] == link.target then
            fresh(self, link.button)
            memory.chain_step = memory.chain_step + 1
            return
        elseif not free then
            return
        end
    end

    local target_index = choose_target(state, index, self, memory)
    local target = target_index and items[target_index]
    -- What this opponent does: watched every frame it is the target, busy or not (a blow of ours lands while
    -- we are still in the move).
    local model
    if target then
        model = watch(context, target, abs(target.x_int - self.x_int) < melee_reach(context.analysis_of(target)) + 80
            and abs(target.z_int - self.z_int) < 40)
    end

    -- A move in progress: continue it into a follow-up that lands before the target can hit back.
    if not free then
        local analysis = context.analysis_of(self)
        if target then
            local chains = analysis.chains[self.frame]
            if chains then
                local tframe = target.record.frame(target.frame)
                local lock = target_lock_of(context, target, tframe)
                local counter = counter_time(context, target, self, lock)
                local function target_at(k) return predict(target, k, tframe.state) end
                local own_face = self.facing == facing_right and 1 or -1
                context.target_where = nil
                if not is_free(target) then
                    local twhere = where_of(target.record, context.analysis_of(target), target)
                    if twhere then context.target_where = {value = target, move = twhere.move, now = twhere.t + target.wait_counter} end
                end
                local target_frame = target_frame_at_fn(context, target, tframe, lock)
                for _, move in ipairs(chains) do
                    if can_start(self, frame, fstate, move) then
                        local t = move_hits(self, own_face, move, 0, target, target_frame, target_at, 20)
                        if t and t <= untouchable_for(context, target, tframe.state, lock) then t = nil end
                        if t and (not counter or t < counter) then
                            start(self, move, target)
                            memory.last_use = memory.last_use or {}
                            memory.last_use[move.index] = state.frame_number
                            memory.note = "follow up"
                            return
                        end
                    end
                end
            end
        end
        -- A stance that goes on until a key ends it: kept while it serves (a charge fills MP while nothing can
        -- reach us; a field holds the target within it), left in time otherwise.
        -- (In the air the frames go round until landing: not a stance.)
        local exit_key, exit_lock
        if self.y_int == 0 then exit_key, exit_lock = stance_exit(self.record, analysis, self.frame) end
        if exit_key then
            local where = where_of(self.record, analysis, self)
            local stay = not earliest_threat(state, index, self, exit_lock + 6, nil, level.reaction, context)
            if stay and where then
                if where.move.mp < 0 and not where.move.first then
                    -- (Kept while the target stays outside its quick reach, with a margin below the one the charge
                    -- was started at, so that it is not left and started again every few frames.)
                    local tlock = target and target_lock_of(context, target, target.record.frame(target.frame)) or 99
                    stay = self.mp < constants.points.full
                        and (not target or abs(target.x_int - self.x_int) > melee_reach(context.analysis_of(target)) + 50
                             or tlock > exit_lock + 10)
                elseif target then
                    local tframe = target.record.frame(target.frame)
                    local function target_at(k) return predict(target, k, tframe.state) end
                    local own_face = self.facing == facing_right and 1 or -1
                    stay = move_hits(self, own_face, where.move, where.t + self.wait_counter, target, tframe, target_at, 8) ~= nil
                else
                    stay = false
                end
            elseif stay then
                stay = false
            end
            if stay then
                memory.note = "hold stance"
            else
                fresh(self, key_names[exit_key])
                memory.note = "leave stance"
            end
        end
        return
    end
    if not target then return end

    local tframe = target.record.frame(target.frame)
    local target_lock = target_lock_of(context, target, tframe)
    context.target_lock = target_lock
    local target_analysis = context.analysis_of(target)
    -- Frames since the last blow between the two: a standoff makes it bolder; so does an opponent that hardly
    -- ever attacks when it could (nothing to bait, everything to walk up to).
    -- (A guarded blow's tenth does not count: a guard that only soaks up jabs is a standoff too.)
    local hp_sum = self.hp + target.hp
    if memory.hp_sum and hp_sum < memory.hp_sum - 6 then memory.calm = 0 else memory.calm = (memory.calm or 0) + 1 end
    memory.hp_sum = hp_sum
    context.aggression = min(1, max(0, (memory.calm - 90) / 150))
    local target_pressure = pressure(model)
    if target_pressure and target_pressure < 0.2 then context.aggression = max(context.aggression, 0.6) end
    -- A target that flips up out of its falls as soon as it may: where its roll takes it is where to strike.
    context.target_path = nil
    if (target.frame == 182 or target.frame == 188) and flips_up(model) then
        local flip = recovery_paths(target, target_analysis)
        context.target_path = {value = target, path = flip}
    end
    memory.last_use = memory.last_use or {}
    context.last_use, context.now = memory.last_use, state.frame_number
    context.target_where = nil
    if not is_free(target) then
        local where = where_of(target.record, context.analysis_of(target), target)
        if where then context.target_where = {value = target, move = where.move, now = where.t + target.wait_counter} end
    end

    -- Answering what is about to hit.
    -- (Blinking after getting up, nothing hits us until it ends: no need to answer what lands before.)
    local blinking = abs(self.blink)
    local threat_t, threat_box, threat_source = earliest_threat(state, index, self, 16, nil, level.reaction, context)
    if threat_t and threat_t <= blinking then threat_t = nil end
    if threat_t and answer(state, index, self, frame, fstate, context, memory, level, threat_t, threat_box, threat_source) then
        return
    end

    -- How soon the target could hit back, and what striking back from a guard could cost.
    context.counter_first, context.counter_damage = nil, nil
    local strongest = 0
    for _, zone in ipairs(danger_zones(target_analysis_of(context, target))) do strongest = max(strongest, zone.damage) end
    context.guard_counter = min(strongest, 80) * 0.5
    local danger = counter_time(context, target, self, target_lock)
    -- Blinking, the counter can only land once the blinking is over: the time to strike freely.
    if danger and blinking > 0 then danger = max(danger, blinking + 1) end

    -- Attacking (a slow move too, when the target is held long enough for it).
    local move, t, score = best_attack(context, self, frame, fstate, target, horizon_ticks - 5, danger)
    -- Not into a blow already on its way: a move whose path meets an enemy's attack in progress before it lands is
    -- left alone (the next best is tried).
    local excluded
    for _ = 1, 3 do
        if not (move and score > 2.5) then break end
        local plan, frames_at = move_path(self, move, target)
        if not earliest_threat(state, index, self, t - 1, plan, level.reaction, context, frames_at) then break end
        excluded = excluded or {}
        excluded[move] = true
        move, t, score = best_attack(context, self, frame, fstate, target, horizon_ticks - 5, danger, excluded)
    end
    if smart.trace then
        smart.trace(state, index, string.format("lock %d danger %s best %s t%s s%.1f", target_lock, tostring(danger),
            move and (move.entry.field or move.entry.basic or "chain") or "-", tostring(t), score or 0))
    end
    if move and score > 2.5 then
        start(self, move, target)
        memory.last_use[move.index] = state.frame_number
        memory.note = string.format("attack %s%s f%d t%d s%.1f", move.entry.field or move.entry.basic or ("chain " .. move.entry.key),
            move.entry.chain and "+" or "", move.entry.frame, t, score)
        return
    end

    local grounded = self.y_int >= 0
    -- Jumping in, or dashing out of the run: when a move from the air would land as the fighter flies at the
    -- target (its moves in the air are as much its own as those on the ground), and nothing reaches it as it
    -- takes off. Not twice in a row: a landing is a moment to be used, not to jump again.
    if grounded and not threat_t and target.y_int >= 0 and (memory.next_jump or 0) <= state.frame_number
       and (fstate == states.standing or fstate == states.walking or fstate == states.running) then
        local distance = abs(target.x_int - self.x_int)
        if distance > 50 and distance < 460 then
            local jump_move, jump_t, jump_score, lead = approach_attack(context, self, fstate, target, danger)
            if jump_move and jump_score > 2.5 then
                local dir = target.x_int >= self.x_int and 1 or -1
                local movement = self.record.movement or {}
                local speed = fstate == states.running and (movement.dash_distance or 0) or (movement.jump_distance or 0)
                local plan = function(k) return trunc(dir * speed * max(k - lead, 0)), 0, 0 end
                if not earliest_threat(state, index, self, lead + 6, plan, level.reaction, context) then
                    fresh(self, "jump")
                    if fstate ~= states.running then press(self, dir > 0 and "right" or "left") end
                    -- (The direction held as the feet leave the ground sets the jump's speed.)
                    memory.jump_dir, memory.jump_hold = dir, state.frame_number + lead + 2
                    memory.next_jump = state.frame_number + 50
                    memory.note = string.format("jump in %s f%d t%d s%.1f", jump_move.entry.field or jump_move.entry.basic or "chain",
                        jump_move.entry.frame, jump_t, jump_score)
                    return
                end
            end
        end
    end
    -- Transforming (a mod's stronger form) or charging MP when far and safe.
    local far_away = abs(target.x_int - self.x_int) > 260 or abs(target.z_int - self.z_int) > 120
    if grounded and fstate ~= states.running and far_away and target_lock == 0 then
        for _, candidate in ipairs(context.analysis_of(self).moves) do
            if candidate.transform and not candidate.entry.parent and can_start(self, frame, fstate, candidate)
               and candidate.ready < 60 then
                start(self, candidate, target)
                memory.note = "transform"
                return
            end
        end
    end
    -- Charging MP (a fighter that can): when the target is well outside its quick reach or down for a while,
    -- nothing is about to reach us, and MP is wanted.
    if grounded and fstate ~= states.running and self.mp < constants.points.full - 80
       and (abs(target.x_int - self.x_int) > melee_reach(context.analysis_of(target)) + 85 or target_lock > 25) then
        for _, candidate in ipairs(context.analysis_of(self).moves) do
            if candidate.charge and can_start(self, frame, fstate, candidate)
               and not earliest_threat(state, index, self, 24, nil, level.reaction, context) then
                start(self, candidate, target)
                memory.note = "charge"
                return
            end
        end
    end

    -- Positioning.
    if fstate == states.jumping or fstate == states.dashing then
        if memory.jump_dir and self.y_int == 0 and state.frame_number <= (memory.jump_hold or 0) then
            press(self, memory.jump_dir > 0 and "right" or "left")
        else
            face(self, target.x_int)
        end
        return
    end
    -- In the guard a direction key only turns the fighter (and a guard holds only facing the attacker).
    if fstate == states.defending then
        face(self, target.x_int)
        memory.note = "guard"
        return
    end
    local range, range_z = preferred_range(context, self)
    local dx = target.x_int - self.x_int
    local dz = target.z_int - self.z_int
    local distance = abs(dx)
    local want_dx, want_dz = 0, 0
    local width = state.stage_bound > 0 and state.stage_bound or (state.stage.width or constants.screen.width)
    local near_z, far_z = state.stage.zboundary[1] or 0, state.stage.zboundary[2] or 0
    local coming = target.y_int < 0 and abs(dz) < 32 and abs(dx) < 420
        and (target.vx == 0 or (target.vx > 0) == (dx < 0))
    if coming and target_lock == 0 then
        -- An enemy in the air keeps its depth until it lands: leave its line before it strikes.
        if dz >= 0 then want_dz = -1 else want_dz = 1 end
        if want_dz < 0 and self.z_int - near_z < 12 then want_dz = 1 end
        if want_dz > 0 and far_z - self.z_int < 12 then want_dz = -1 end
        memory.note = "leave air line"
    elseif target_lock == 0 and danger_at(target, context.analysis_of(target), self.x_int, self.z_int) >= 30 + 60 * context.aggression then
        -- Where the free enemy's quick, strong moves land: step to the nearest spot they do not reach.
        local analysis = context.analysis_of(target)
        local movement = self.record.movement or {}
        local step_x, step_z = (movement.walking_speed or 4) * 6, (movement.walking_speedz or 2) * 6
        local best_dx, best_dz, best_value
        for ox = -1, 1 do
            for oz = -1, 1 do
                local x, z = self.x_int + ox * step_x, self.z_int + oz * step_z
                if x > 20 and x < width - 20 and z >= near_z and z <= far_z then
                    local value = danger_at(target, analysis, x, z) + abs(abs(target.x_int - x) - range) * 0.05
                    if not best_value or value < best_value then best_dx, best_dz, best_value = ox, oz, value end
                end
            end
        end
        want_dx, want_dz = best_dx or 0, best_dz or 0
        memory.note = "leave reach"
    else
        -- Toward the target until a move reaches it (nothing did this frame), unless much too close; against
        -- longer arms, just outside them until the target commits.
        -- Just outside a free enemy's arms (unless ours are clearly longer): it has to come to us, and walks
        -- into our blow; a long standoff ends the patience.
        local hold = range
        local their_reach = melee_reach(context.analysis_of(target)) + 25
        if their_reach > range - 10 and target_lock == 0 and context.aggression < 0.5 and (target_pressure or 1) >= 0.2 then
            hold = max(range, their_reach + 15)
        end
        if distance > max(hold - 20, 10) then want_dx = dx > 0 and 1 or -1
        elseif distance < max(hold - 50, 8) and target_lock == 0 then want_dx = dx > 0 and -1 or 1 end
        if want_dx ~= 0 and (want_dx < 0) == (dx > 0) and ((want_dx < 0 and self.x_int < 80) or (want_dx > 0 and self.x_int > width - 80)) then
            want_dx = 0
        end
        if abs(dz) > range_z then want_dz = dz > 0 and 1 or -1 end
        memory.note = string.format("move %d %d (hold %d)", want_dx, want_dz, hold)
    end
    local near, far = state.stage.zboundary[1] or 0, state.stage.zboundary[2] or 0
    if want_dz < 0 and self.z_int - near < 6 then want_dz = 0 end
    if want_dz > 0 and far - self.z_int < 6 then want_dz = 0 end
    -- Not a step into a blow that misses where we stand (turning toward the target is a step too).
    local turn = want_dx == 0 and ((dx > 0 and self.facing == facing_left) or (dx < 0 and self.facing == facing_right))
    if (want_dx ~= 0 or want_dz ~= 0 or turn) and fstate ~= states.running and not threat_t then
        local movement = self.record.movement or {}
        local speed, speedz = movement.walking_speed or 4, movement.walking_speedz or 2
        local step_x = want_dx ~= 0 and want_dx or (dx > 0 and 1 or -1)
        local plan = function(k) return trunc(step_x * speed * k), 0, trunc(want_dz * speedz * k) end
        if earliest_threat(state, index, self, 12, plan, level.reaction, context) then
            want_dx, want_dz, turn = 0, 0, false
            memory.note = "hold still"
        end
    end
    -- Blocked (a barrel or crate in the way, another fighter): two steps that moved nothing → around it in depth.
    if want_dx ~= 0 and grounded and fstate ~= states.running and memory.step_x == want_dx
       and memory.step_at_x == self.x_int and memory.step_at_z == self.z_int and self.x_int > 30 and self.x_int < width - 30 then
        memory.blocked = (memory.blocked or 0) + 1
    else
        memory.blocked = 0
    end
    memory.step_x, memory.step_at_x, memory.step_at_z = want_dx, self.x_int, self.z_int
    if memory.detour_until and state.frame_number < memory.detour_until then
        want_dz = memory.detour
    elseif memory.blocked >= 2 then
        if dz ~= 0 then memory.detour = dz > 0 and 1 or -1
        else memory.detour = (far - self.z_int > self.z_int - near) and 1 or -1 end
        memory.detour_until = state.frame_number + 14
        memory.blocked = 0
        want_dz = memory.detour
    end
    if want_dz < 0 and self.z_int - near < 6 then want_dz = 0 end
    if want_dz > 0 and far - self.z_int < 6 then want_dz = 0 end
    if fstate == states.running then
        -- Stop running near the target, by pressing against the run.
        if distance < range + 140 or (dx > 0) ~= (self.facing == facing_right) then
            press(self, self.facing == facing_right and "left" or "right")
        elseif want_dz ~= 0 then
            press(self, want_dz > 0 and "down" or "up")
        end
        return
    end
    if want_dx ~= 0 then
        local key = want_dx > 0 and "right" or "left"
        -- A long way to go: run, which takes two taps (a release between them) rather than a held key.
        local run = distance > range + 200 and want_dx == (dx > 0 and 1 or -1) and grounded and fstate ~= states.running
        if not (run and self.previous_keys[key]) then press(self, key) end
    elseif turn then
        face(self, target.x_int)
    end
    if want_dz ~= 0 then press(self, want_dz > 0 and "down" or "up") end
end
-- Learns the moves of the match's fighters, and of those the stage will bring in, ahead (what is learned only
-- depends on their data).
function smart.prepare(state)
    for index = 0, constants.item_slots - 1 do
        local value = state.items[index]
        if value and value.record.kind == record_kinds.character then analyze(value.record) end
    end
    if state.stage_run then
        for _, id in ipairs(require("base/game/stage").enemy_ids(state.stage_run)) do
            local record = objects.record(state, id)
            if record and record.kind == record_kinds.character then analyze(record) end
        end
    end
end

-- For the test bench.
smart.internals = {earliest_threat = earliest_threat, where_of = where_of, analyze = analyze, move_hits = move_hits,
    danger_at = danger_at, danger_zones = danger_zones, melee_reach = melee_reach, best_attack = best_attack,
    enemy_reach = enemy_reach, defend_ticks = defend_ticks, target_lock_of = target_lock_of}
return smart
