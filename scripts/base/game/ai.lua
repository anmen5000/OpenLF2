-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

local constants = require("base/game/constants")
local combo_down_attack = constants.combo_indices.down_attack
local combo_down_jump = constants.combo_indices.down_jump
local combo_left_jump = constants.combo_indices.left_jump
local combo_right_attack = constants.combo_indices.right_attack
local combo_right_jump = constants.combo_indices.right_jump
local combo_up_attack = constants.combo_indices.up_attack
local combo_up_jump = constants.combo_indices.up_jump
local sequence_complete = constants.combo_states.complete
local facing_left = constants.facings.left
local facing_right = constants.facings.right
local fighter_davis = constants.fighter_ids.davis
local fighter_deep = constants.fighter_ids.deep
local fighter_dennis = constants.fighter_ids.dennis
local fighter_firen = constants.fighter_ids.firen
local fighter_henry = constants.fighter_ids.henry
local fighter_hunter = constants.fighter_ids.hunter
local fighter_jack = constants.fighter_ids.jack
local fighter_jan = constants.fighter_ids.jan
local fighter_john = constants.fighter_ids.john
local fighter_rudolf = constants.fighter_ids.rudolf
local fighter_sorcerer = constants.fighter_ids.sorcerer
local fighter_woody = constants.fighter_ids.woody
local state_attacking = constants.frame_states.attacking
local state_broken_defend = constants.frame_states.broken_defend
local state_burning = constants.frame_states.burning
local state_burning_run = constants.frame_states.burning_run
local state_defending = constants.frame_states.defending
local state_dizzy = constants.frame_states.dizzy
local state_falling = constants.frame_states.falling
local state_lying = constants.frame_states.lying
local state_resting_light_item = constants.frame_states.resting_light_item
local state_running = constants.frame_states.running
local item_id_beer = constants.item_ids.beer
local item_id_milk = constants.item_ids.milk
local mode_stage = constants.modes.stage
local no_order = constants.no_order
local object_john_ball = constants.object_ids.john_ball
local team_enemies = constants.teams.enemies
local weapon_none = constants.weapon_holder_codes.none
local character_frames = constants.character_frames
local record_kinds = constants.record_kinds
-- Computer control follows the original game's main, attack and special-move routines. Keep
-- condition order for random-call compatibility; weapon/drink keys run before attack decisions.
local objects = require("base/game/objects")
local ai_scripts = require("base/game/ai_scripts")

local ai = {}
local abs = math.abs
local random = function(range) return engine.random(range) end

local function trunc(value)
    if value >= 0 then return math.floor(value) end
    return math.ceil(value)
end
local function cdiv(a, b)
    local q = a / b
    if q >= 0 then return math.floor(q) end
    return math.ceil(q)
end
function ai.prepare(state)
    local scan = {items = state.items, slots = {}, states = {}, characters = {}, target_teams = {}}
    for index = 0, constants.item_slots - 1 do
        local value = state.items[index]
        if value then
            scan.slots[#scan.slots + 1] = index
            if value.record.kind == record_kinds.character and value.hp > 0 then
                scan.characters[#scan.characters + 1] = index
            end
            if index >= 20 and not scan.first_object then scan.first_object = #scan.slots end
        end
    end
    scan.first_object = scan.first_object or #scan.slots + 1
    return scan
end

local function state_of(value, context)
    local states = context.states
    local current = states[value]
    if current == nil then
        current = value.record.frame(value.frame).state
        states[value] = current
    end
    return current
end

-- Key helpers: `keys` are held keys (0xcd..0xd3), `previous_keys` the last frame's (0xc6..0xcc).
local function press(value, key) value.keys[key] = true end
local function fresh(value, key) value.previous_keys[key] = false end

local function far_from(a, b) return abs(a.z_int - b.z_int) > 150 or abs(a.x_int - b.x_int) > 240 end

local function edge_move(context, target, self)
    local edge_x = target.x_int
    local limit = context.width_limit
    if (edge_x < 250 or edge_x < self.x_int) and edge_x <= limit - 250 then
        press(self, "right"); fresh(self, "right")
    elseif edge_x > limit - 250 or edge_x > self.x_int then
        press(self, "left"); fresh(self, "left")
    end
end

local function copy_and_clear(value)
    for _, key in ipairs({"up", "down", "left", "right", "attack", "jump", "defend"}) do
        value.previous_keys[key] = value.keys[key]
        value.keys[key] = false
    end
end

local function attacks(context, target, self, target_state, flag_a, flag_b)
    local T, S = target, self
    local kind = S.record.id
    if ((kind ~= fighter_henry and kind ~= fighter_rudolf and kind ~= fighter_hunter) or kind ~= fighter_jan)
       and abs(T.x_int - 2 * trunc(S.vx) - S.x_int) < 80 and abs(T.z_int - S.z_int) < 5
       and random(context.skill3 + 3) == 0 and target_state ~= state_lying then
        press(S, "attack")
    end
    if flag_a ~= 0 and T.x_int > S.x_int then return end
    if flag_b ~= 0 and T.x_int < S.x_int then return end
    if random(context.skill3 + 1) ~= 0 then return end
    local ranged = {[fighter_john] = true, [fighter_henry] = true,
        [constants.fighter_ids.louis] = true, [fighter_dennis] = true,
        [fighter_woody] = true, [fighter_davis] = true,
        [constants.fighter_ids.freeze] = true, [fighter_firen] = true,
        [fighter_jack] = true, [fighter_sorcerer] = true}
    kind = S.record.id
    if ranged[kind] then
        local self_x = S.x_int
        if abs(T.x_int + 2 * trunc(T.vx) - self_x) > 100 and abs(T.x_int + 2 * trunc(T.vx) - self_x) < 900
           and abs(T.z_int - S.z_int) < 5 and random(context.skill3 + 10) == 0 and target_state ~= state_lying then
            press(S, "defend")
        end
    end
    kind = S.record.id
    if ranged[kind] then
        local self_x = S.x_int
        if abs(T.x_int + 2 * trunc(T.vx) - self_x) > 90 then
            if ((self_x < T.x_int and S.facing == facing_right) or (T.x_int < self_x and S.facing == facing_left))
               and (S.frame == character_frames.defend or S.frame > 234) and abs(T.z_int - S.z_int) < 13 and target_state ~= state_lying then
                fresh(S, "right"); fresh(S, "left"); fresh(S, "attack")
                if S.x_int < T.x_int then press(S, "right") else press(S, "left") end
                if S.record.id == fighter_sorcerer and random(2) == 0 then press(S, "jump") else press(S, "attack") end
            end
        end
    end
    if S.record.id == fighter_deep then
        local self_x = S.x_int
        if abs(T.x_int + 2 * trunc(T.vx) - self_x) > 100 and abs(T.x_int + 2 * trunc(T.vx) - self_x) < 300
           and abs(T.z_int - S.z_int) < 5 and random(context.skill5 + 10) == 0 and target_state ~= state_lying then
            press(S, "defend")
        end
    end
    if S.record.id == fighter_deep then
        local self_x = S.x_int
        if abs(T.x_int + 2 * trunc(T.vx) - self_x) > 90 then
            if ((S.facing == facing_right and self_x < T.x_int) or (S.facing == facing_left and T.x_int < self_x))
               and (S.frame == character_frames.defend or S.frame > 234) and abs(T.z_int - S.z_int) < 7 and target_state ~= state_lying then
                fresh(S, "right"); fresh(S, "left"); fresh(S, "attack")
                if S.x_int < T.x_int then press(S, "right") else press(S, "left") end
                press(S, "attack")
            end
        end
    end
end

-- Low-health ally helper shared by records 2 and 34 (heal-like special with D^J).
local function help_ally(context, S, distance, flag_b)
    local items = context.items
    if (S.weapon == weapon_none or S.frame < character_frames.running) and (S.hp >= S.dark_hp - 70 or S.hp >= 140)
       and (S.hp >= cdiv(S.dark_hp * 3, 5) or S.hp < 140) and flag_b == 0 then
        for j = 0, constants.first_spawned_slot - 1 do
            local A = items[j]
            if j ~= context.self_index and A then
                local near_x = abs(A.x_int - S.x_int)
                if A.team ~= constants.teams.independent and A.team == S.team and near_x < 250 then
                    local near_z = abs(A.z_int - S.z_int)
                    if near_z < 60 and S.mp > 350
                       and ((A.hp < A.dark_hp - 90 and A.hp < 140) or (A.hp < cdiv(A.dark_hp * 3, 5) and A.hp >= 140))
                       and A.hp > 0 and near_z + near_x < cdiv(distance, 3) then
                        if A.x_int > S.x_int then S.keys.right, S.keys.left = true, false
                        else S.keys.right, S.keys.left = false, true end
                        local tx, sx = A.x_int, S.x_int
                        if (tx > sx and S.facing == facing_right) or (tx < sx and S.facing == facing_left) or abs(tx - sx) < 5 then
                            S.sequences[combo_up_jump] = sequence_complete
                        end
                        return true
                    end
                end
            end
        end
    end
    return false
end

local function forward(S, T) return (S.facing == facing_right and S.x_int < T.x_int) or (S.facing == facing_left and T.x_int < S.x_int) end
local function dx(S, T) return abs(T.x_int - S.x_int) end
local function dz(S, T) return abs(T.z_int - S.z_int) end
local function low_health(value)
    return (value.hp < value.dark_hp - 70 and value.hp < 140)
        or (value.hp < cdiv(value.dark_hp * 3, 5) and value.hp >= 140)
end

local function specials(context, target, self, target_state, flag_a, distance, flag_b)
    local T, S = target, self
    local items = context.items
    local kind, target_kind, tx, sx, span
    local skill5 = context.skill5
    if random(skill5 + 1) > 0 then return false end
    kind = S.record.id
    if kind == fighter_john then
        if random(10) == 0 and S.mp > 350 and low_health(S) then S.sequences[combo_down_jump] = sequence_complete return true end
        if distance < 10000 and random(30) == 0 and S.mp > 250 then goto up_jump end
        target_kind = T.record.id
        if target_kind == fighter_john or target_kind == fighter_dennis
           or target_kind == fighter_woody or target_kind == fighter_davis
           or target_kind == fighter_jack or target_kind == fighter_sorcerer then
            if random(15) == 0 then
                sx, tx = S.x_int, T.x_int
                if abs(tx - sx) > 100 and abs(tx - sx) < 500 and dz(S, T) < 30 and S.mp > 100 and T.mp > 220
                   and flag_a == 0 then
                    goto toward
                end
            end
            if help_ally(context, S, distance, flag_b) then return true end
            goto after_2
        end
        if random(15) ~= 0 then
            if help_ally(context, S, distance, flag_b) then return true end
            goto after_2
        end
        if not (dx(S, T) > 100 and dx(S, T) < 250 and dz(S, T) < 30 and S.mp > 100 and T.mp > 170 and flag_a == 0) then
            if help_ally(context, S, distance, flag_b) then return true end
            goto after_2
        end
        -- The reference reads sx/tx uninitialized on this path; current positions are used.
        sx, tx = S.x_int, T.x_int
        goto toward
    end
    ::after_2::
    if S.record.id == fighter_deep then
        if S.frame >= 260 and S.frame <= 289 and dx(S, T) < 100 and dz(S, T) < 7 then
            if (T.y_int ~= 0 or S.y_int ~= 0 or random(3) ~= 0)
               and (T.y_int >= 0 or S.y_int >= 0 or random(7) ~= 0) then
                if (T.y_int < 0 and random(5) == 0) or random(30) == 0 then
                    if (S.x_int < T.x_int and S.facing == facing_right) or (T.x_int < S.x_int and S.facing == facing_left) then
                        press(S, "jump")
                    end
                    fresh(S, "jump")
                end
                return true
            end
            press(S, "attack"); fresh(S, "attack")
            return true
        end
        if random(7) ~= 0 or dx(S, T) >= 150 or dz(S, T) >= 8 or S.mp <= 150
           or ((random(10) ~= 0 or target_state == state_attacking)
               and (random(3) <= 0 or (target_state ~= state_dizzy and target_state ~= state_broken_defend and target_state ~= constants.frame_states.injured))) then
            if random(7) == 0 and dx(S, T) < 100 and dz(S, T) < 7 and S.mp > 75 then
                if S.mp > 150 and ((random(10) == 0 and target_state ~= state_attacking)
                                   or (random(3) > 0 and target_state == state_dizzy)) then
                    if S.x_int < T.x_int then S.sequences[combo_right_jump] = sequence_complete return true end
                    S.sequences[combo_left_jump] = sequence_complete
                    return true
                end
                S.sequences[combo_down_attack] = sequence_complete
                return true
            end
            goto others
        end
        goto toward_by_x
    end
    ::others::
    if S.record.id == fighter_henry then
        if S.mp > 360 and dx(S, T) < 100 and dz(S, T) < 70 and random(cdiv(S.hp, 5) + 10) == 0 then
            S.sequences[combo_up_jump] = sequence_complete
            return true
        end
        if random(45) == 0 then
            sx, tx = S.x_int, T.x_int
            span = abs(tx - sx)
            if span > 100 and span < 550 and dz(S, T) < 20 and S.mp > 170 then goto toward end
        end
        if random(30) == 0 and S.mp > 200 then
            if dx(S, T) > 100 and dx(S, T) < 160 and dz(S, T) < 55 and forward(S, T) then goto jump_attack end
        end
    end
    if S.record.id == fighter_rudolf then
        if S.mp > 450 and dx(S, T) > 100 and dz(S, T) > 50 and random(3) == 0 then
            if random(2) == 0 then S.sequences[combo_up_jump] = sequence_complete return true end
            goto down_jump
        end
        if S.mp > 70 and dx(S, T) > 100 and dx(S, T) < 160 and dz(S, T) < 8 and random(10) == 0 then goto toward_by_x end
        if random(30) == 0 and S.mp > 200 then
            if dx(S, T) > 100 and dx(S, T) < 160 and dz(S, T) < 55 then
                if S.facing == facing_right and S.x_int < T.x_int then goto right_attack end
                if S.facing == facing_left and T.x_int < S.x_int then goto left_attack end
            end
        end
    end
    if S.record.id == constants.fighter_ids.louis then
        if S.mp < 101 or dx(S, T) < 81 or dx(S, T) > 129 or dz(S, T) > 29 or random(10) ~= 0 then
            if S.mp < 101 or dx(S, T) > 44 or dz(S, T) > 4 or random(3) ~= 0 then
                if state_of(S, context) == constants.frame_states.catching and random(8) == 0 then
                    press(S, "jump"); fresh(S, "jump")
                end
                goto after_6
            end
            goto heal
        end
        goto toward_by_x
    end
    ::after_6::
    if S.record.id == fighter_firen then
        if S.frame > 267 and S.frame < 283 then
            if target_state == state_falling or target_state == constants.frame_states.injured then goto defend end
            if dx(S, T) > 150 or dz(S, T) > 25 or (S.facing == facing_right and S.x_int < T.x_int)
               or (S.facing == facing_left and T.x_int < S.x_int) then
                goto defend
            end
        end
        if target_state ~= state_burning and target_state ~= state_lying then
            if target_state ~= state_falling and S.hp > 70 and S.mp > 320 and (dx(S, T) > 50 or dz(S, T) > 10) and dx(S, T) < 85
               and T.hp < S.hp and dz(S, T) < 35 and random(5) == 0 then
                S.sequences[combo_up_jump] = sequence_complete
                return true
            end
            if target_state ~= state_falling and S.mp > 200 and dx(S, T) > 100 and dx(S, T) < 370 and dz(S, T) < 60 and random(20) == 0 then
                goto toward_by_x
            end
        end
        if random(100) == 0 and dx(S, T) > 240 and dx(S, T) < 400 then goto toward_by_x end
        if target_state ~= state_burning and target_state ~= state_lying and target_state ~= state_falling and S.mp > 200 and dx(S, T) > 60
           and dx(S, T) < 280 and dz(S, T) < 60 and random(15) == 0 then
            if forward(S, T) then S.sequences[combo_down_jump] = sequence_complete return true end
        end
        if S.frame < 255 or S.frame > 261 then goto after_7 end
        if (S.facing == facing_right and (T.x_int + 120 < S.x_int or context.width_limit - 30 < S.x_int))
           or (S.facing == facing_left and (S.x_int < T.x_int - 120 or S.x_int < 30)) then
            goto defend
        end
        local target_z, self_z = T.z_int, S.z_int
        if abs(target_z - self_z) > 70 or context.edge_flag == 1 then goto defend end
        if forward(S, T) then
            if target_z <= self_z then press(S, "up") else press(S, "down") end
        elseif target_z < self_z then
            press(S, "down")
        else
            press(S, "up")
        end
    end
    ::after_7::
    if S.record.id == constants.fighter_ids.freeze then
        if target_state ~= constants.frame_states.frozen then
            if S.mp < 201 or dx(S, T) > 399 or dz(S, T) > 169 or random(250) ~= 0 then
                if target_state == state_lying then goto state_8_b end
                if S.mp < 201 or dx(S, T) < 61 or dx(S, T) > 279 or dz(S, T) > 64 or random(15) ~= 0 then goto state_8_a end
            end
            goto toward_by_x
        end
        ::state_8_a::
        if target_state ~= state_lying and S.mp > 320 and ((dx(S, T) > 50 or dz(S, T) > 7) or target_state == constants.frame_states.frozen) and dx(S, T) < 125
           and dz(S, T) < 25 and random(3) == 0 then
            if forward(S, T) then goto heal end
        end
        ::state_8_b::
        if random(50) == 0 and S.weapon == weapon_none and S.mp > 200 and dx(S, T) > 200 and dz(S, T) > 50 then goto down_jump end
    end
    if S.record.id == fighter_davis then
        if S.mp > 150 and dx(S, T) < 280 and dz(S, T) < 30 and random(10) == 0 then
            if S.facing == facing_right and S.x_int < T.x_int then goto down_attack end
            if S.facing == facing_left and T.x_int < S.x_int then
                if T.x_int <= S.x_int then return true end
                goto down_attack
            end
        end
        -- Frame offset +0x2c (hit_j) equal to 290 while the target is airborne.
        if S.record.frame(S.frame).hits.j == 290 and T.y_int < 0 then
            fresh(S, "jump"); press(S, "jump")
        end
        if random(5) == 0 or target_state == state_dizzy or target_state == state_broken_defend then
            if abs(trunc(S.vx) - S.x_int + T.x_int) < 100 and dz(S, T) < 7 and S.mp > 200 and forward(S, T) then
                goto up_attack
            end
        end
    end
    if S.record.id == fighter_woody then
        if S.mp > 100 and dx(S, T) < 280 and dz(S, T) < 25 and random(10) == 0 then
            if S.facing == facing_right and S.x_int < T.x_int then goto down_attack end
            if S.facing == facing_left and T.x_int < S.x_int then
                if T.x_int <= S.x_int then return true end
                goto down_attack
            end
        end
        if S.frame == 271 and T.y_int < 0 and target_state == state_falling then S.sequences[combo_up_attack] = sequence_complete return true end
        if random(10) == 0 or target_state == state_dizzy or target_state == state_broken_defend then
            if abs(trunc(S.vx) - S.x_int + T.x_int) < 80 and dz(S, T) < 7 and forward(S, T) then goto up_attack end
        end
        if S.mp < 201 or dx(S, T) < 61 or dx(S, T) > 279 or dz(S, T) > 64
           or (random(15) ~= 0 and (random(4) ~= 0 or (target_state ~= state_dizzy and target_state ~= state_broken_defend
                                                         and (target_state ~= state_falling or T.y_int > -41)))) then
            if S.hp < 250 and S.hp < T.hp + 50 and random(20) == 0 and S.mp > 75 then
                local best, best_index = -1, -1
                for position = 1, #context.slots do
                    local j = context.slots[position]
                    local A = items[j]
                    if j ~= context.self_index and A and A.record.kind == record_kinds.character and A.team == S.team and T.hp < A.hp then
                        local sum = abs(A.z_int - S.z_int) + abs(A.x_int - S.x_int)
                        if best < sum then best, best_index = sum, j end
                    end
                end
                if best_index ~= -1 and best > 300 and S.weapon == weapon_none then S.sequences[combo_down_jump] = sequence_complete end
            end
            if T.hp < S.hp and random(70) == 0 and S.mp > 500 then S.sequences[combo_up_jump] = sequence_complete end
            goto after_10
        end
        goto toward_by_x_lt
    end
    ::after_10::
    if S.record.id == fighter_dennis then
        if random(10) == 0 or target_state == state_dizzy or target_state == state_broken_defend then
            if abs(trunc(S.vx) - S.x_int + T.x_int) < 120 and dz(S, T) < 7 and forward(S, T) then
                S.sequences[combo_down_attack] = sequence_complete
                return true
            end
        end
        if (target_state ~= state_burning and target_state ~= state_lying and target_state ~= state_falling and S.mp > 200 and dx(S, T) > 75
            and dx(S, T) < 370 and dz(S, T) < 60 and random(13) == 0)
           or (random(cdiv(T.hp, 4) + 40) == 0 and dx(S, T) > 150 and dx(S, T) < 400) then
            goto toward_by_x_lt
        end
        if distance < 10000 and random(30) == 0 and S.mp > 150 then goto up_jump end
    end
    if S.record.id == constants.fighter_ids.mark then
        if (target_state ~= state_burning and target_state ~= state_lying and target_state ~= state_falling and S.mp > 200 and dx(S, T) < 270
            and dz(S, T) < 60 and random(60) == 0)
           or (random(cdiv(T.hp, 4) + 40) == 0 and dx(S, T) > 150 and dx(S, T) < 400) then
            goto toward_by_x_lt
        end
        if dx(S, T) < 150 and dz(S, T) < 40 and random(15) == 0 then
            if S.x_int < T.x_int then S.sequences[combo_right_attack] = sequence_complete return true end
            S.sequences[constants.combo_indices.left_attack] = sequence_complete
            return true
        end
    end
    if S.record.id == fighter_jack and (random(5) == 0 or target_state == state_dizzy or target_state == state_broken_defend) then
        if abs(trunc(S.vx) - S.x_int + T.x_int) < 60 and dz(S, T) < 7 and S.mp > 150 and forward(S, T) then goto up_attack end
    end
    if S.record.id == fighter_sorcerer then
        if random(10) == 0 and S.mp > 350 and low_health(S) then S.sequences[combo_down_jump] = sequence_complete return true end
        if help_ally(context, S, distance, flag_b) then return true end
    end
    if S.record.id == constants.fighter_ids.louis_ex then
        if random(7) == 0 then
            sx, tx = S.x_int, T.x_int
            span = abs(tx - sx)
            if not (span > 499 or span < 91 or dz(S, T) > 3 or S.mp < 151) then
                if T.frame == 263 or T.frame == 264 then
                    fresh(S, "attack"); press(S, "attack")
                    goto state_50
                end
                goto by_side
            end
        end
        ::state_50::
        if random(7) == 0 and dx(S, T) < 100 and dz(S, T) < 7 and S.mp > 75 then S.sequences[combo_down_attack] = sequence_complete return true end
    end
    if S.record.id == constants.fighter_ids.monk and random(7) == 0 then
        sx, tx = S.x_int, T.x_int
        span = abs(tx - sx)
        if span < 650 and span > 40 and dz(S, T) < 4 and S.mp > 120 then goto by_side end
    end
    if S.record.id == fighter_jan then
        if S.mp > 200 and random(5) == 0 then
            for j = 0, 99 do
                local A = items[j]
                if A and A.record.kind == record_kinds.character and A.team == S.team then
                    local hp = A.hp
                    if hp < A.dark_hp - 200 or (hp < 200 and hp < A.dark_hp - 100) then goto heal end
                end
            end
            return true
        end
        if S.mp > 260 and random(10) == 0 and dx(S, T) < 650 and dz(S, T) < 240 then goto up_attack end
    end
    if S.record.id == constants.fighter_ids.bat then
        if S.mp > 150 and random(5) == 0 then
            if dx(S, T) < 250 and dx(S, T) > 130 and dz(S, T) < 10 then
                if S.x_int < T.x_int then S.sequences[combo_right_jump] = sequence_complete return true end
                goto left_jump
            end
        end
        if S.mp > 200 and random(10) == 0 and dz(S, T) < 10 then
            if S.x_int < T.x_int then S.sequences[combo_right_attack] = sequence_complete return true end
            goto left_attack
        end
        if S.mp > 200 and random(10) == 0 and (dx(S, T) > 200 or dz(S, T) < 250) then goto heal_up_jump end
    end
    if S.record.id == constants.fighter_ids.justin then
        if S.mp > 100 and random(3) == 0 then
            if dx(S, T) < 120 and forward(S, T) and dz(S, T) < 10 then goto down_attack end
        end
        if S.mp > 100 and random(7) == 0 then
            sx, tx = S.x_int, T.x_int
            if abs(tx - sx) < 250 and dz(S, T) < 10 then goto by_side end
        end
    end
    if S.record.id == constants.fighter_ids.julian then
        if target_state == state_attacking and S.mp > 125 and random(10) == 0 and dx(S, T) < 120 and dz(S, T) < 10 then goto jump_attack end
        if S.mp > 125 and random(5) == 0 then
            if dx(S, T) < 100 and dz(S, T) < 30 then
                if T.x_int <= S.x_int then return true end
                goto heal_up_jump
            end
        end
        if S.mp > 125 and random(14) == 0 then
            sx, tx = S.x_int, T.x_int
            if abs(tx - sx) < 700 and dz(S, T) < 150 then goto by_side end
        end
        if S.mp > 125 and random(5) == 0 and dz(S, T) < 20 then
            if T.x_int > S.x_int then S.sequences[combo_right_jump] = sequence_complete return true end
            goto left_jump
        end
        if random(5) == 0 or target_state == state_dizzy or target_state == state_broken_defend then
            if abs(trunc(S.vx) - S.x_int + T.x_int) < 100 and dz(S, T) < 7 and S.mp < 100 and forward(S, T) then
                S.sequences[combo_up_attack] = sequence_complete
                return true
            end
        end
    end
    if S.record.id ~= constants.fighter_ids.firzen then return false end
    if S.frame > 265 and S.frame < 280 and (dz(S, T) > 13 or T.record.kind ~= record_kinds.character) then
        fresh(S, "defend"); press(S, "defend")
        return true
    end
    if S.mp > 300 and random(10) == 0 and dx(S, T) < 300 and dz(S, T) < 200 then goto heal_up_jump end
    if S.mp > 300 and random(10) == 0 and dx(S, T) < 950 then goto up_attack end
    if random(5) ~= 0 or S.mp < 251 then return false end
    if dx(S, T) > 1199 or dx(S, T) < 41 or dz(S, T) > 12 then return false end
    if S.x_int < T.x_int then S.sequences[combo_right_jump] = sequence_complete return true end
    goto left_jump

    ::toward_by_x::
    if S.x_int < T.x_int then S.sequences[combo_right_jump] = sequence_complete return true end
    goto left_jump
    ::toward_by_x_lt::
    if S.x_int < T.x_int then S.sequences[combo_right_jump] = sequence_complete return true end
    goto left_jump
    ::toward::
    if sx < tx then S.sequences[combo_right_jump] = sequence_complete return true end
    goto left_jump
    ::left_jump::
    S.sequences[combo_left_jump] = sequence_complete
    do return true end
    ::heal::
    S.sequences[combo_up_jump] = sequence_complete
    do return true end
    ::heal_up_jump::
    S.sequences[combo_up_jump] = sequence_complete
    do return true end
    ::up_jump::
    S.sequences[combo_up_attack] = sequence_complete
    do return true end
    ::up_attack::
    S.sequences[combo_up_attack] = sequence_complete
    do return true end
    ::down_jump::
    S.sequences[combo_down_jump] = sequence_complete
    do return true end
    ::down_attack::
    S.sequences[combo_down_attack] = sequence_complete
    do return true end
    ::jump_attack::
    S.sequences[constants.combo_indices.jump_attack] = sequence_complete
    do return true end
    ::defend::
    press(S, "defend"); fresh(S, "defend")
    do return true end
    ::by_side::
    if sx < tx then goto right_attack end
    goto left_attack
    ::right_attack::
    S.sequences[combo_right_attack] = sequence_complete
    do return true end
    ::left_attack::
    S.sequences[constants.combo_indices.left_attack] = sequence_complete
    do return true end
end

-- Enemy relation used by both target searches.
local function hostile(mode, other_team, self_team)
    return (other_team ~= self_team and (mode ~= mode_stage or self_team == team_enemies))
        or (other_team == team_enemies and mode == mode_stage and other_team ~= self_team)
end

local function filter_targets(slots, context, mode, team)
    local result = {}
    for _, index in ipairs(slots) do
        if hostile(mode, context.items[index].team, team) then result[#result + 1] = index end
    end
    return result
end

local function target_lists(context, mode, team)
    if not context.targets then
        context.targets, context.waiting, context.objects = {}, {}, {}
        for position, index in ipairs(context.slots) do
            local value = context.items[index]
            if value.hp > 0 then
                local current = state_of(value, context)
                if current == state_lying or abs(value.blink) > 2 then
                    context.waiting[#context.waiting + 1] = index
                elseif value.record.kind == record_kinds.character or current == constants.frame_states.flying_ball then
                    context.targets[#context.targets + 1] = index
                end
            end
            if position >= context.first_object then
                local id = value.record.id
                if math.floor(id / 100) == 1 or id == constants.item_ids.ice_sword
                   or id == object_john_ball or id == constants.object_ids.firen_flame
                   or id == constants.object_ids.freeze_column then
                    context.objects[#context.objects + 1] = index
                end
            end
        end
    end
    local teams = context.target_teams[mode or false]
    if not teams then teams = {}; context.target_teams[mode or false] = teams end
    local lists = teams[team]
    if not lists then
        lists = {targets = filter_targets(context.targets, context, mode, team),
            waiting = filter_targets(context.waiting, context, mode, team)}
        teams[team] = lists
    end
    return lists.targets, lists.waiting
end

local function between(a, b, c) return (a < b and c > b) or (c < b and b < a) end

local function weapon_keys(state, context, target, index, self_state, other_state, close_target, danger_aligned)
    local items = state.items
    local S, T = items[index], items[target]
    if random(context.skill3 + 1) > 0 then return false end
    local held = objects.lookup(state, S.held_item)
    local kind = held and held.record.id or -1
    local blocked = false
    for i = 0, constants.first_spawned_slot - 1 do
        local A = items[i]
        if i ~= index and A and A.team ~= constants.teams.independent and T.team == S.team and A.hp > 0 and state_of(A, context) ~= state_lying
           and abs(A.blink) < 3 and abs(A.z_int - S.z_int) < 15 and between(S.x_int, A.x_int, T.x_int) then
            blocked = true
        end
    end
    if self_state == state_running and random(context.skill3 + 5) == 0 then
        if blocked then press(S, "jump") else press(S, "attack") end
    end
    if kind == constants.item_ids.stick or kind == constants.item_ids.hoe or kind == constants.item_ids.knife or kind == constants.item_ids.baseball or kind == constants.item_ids.boomerang then
        if abs(T.x_int - 2 * trunc(S.vx) - S.x_int) < 115 and abs(T.z_int - S.z_int) < 6
           and random(context.skill3 + 3) == 0 and other_state ~= state_lying then
            press(S, "attack")
        end
        if kind == constants.item_ids.boomerang and random(context.skill15 + 30) == 0 then press(S, "attack") end
        if random(context.skill3 + 5) == 0
           and (S.follow_order == 0 or (abs(S.z_int - T.z_int) < 151 and abs(S.x_int - T.x_int) < 241)) then
            local target_x, self_x = T.x_int, S.x_int
            if abs(target_x - self_x) < 600 and abs(T.z_int - S.z_int) < 20 then
                if self_x < target_x and context.edge_flag == 0 then
                    press(S, "right"); fresh(S, "right")
                end
                if T.x_int < S.x_int then
                    press(S, "left"); fresh(S, "left")
                end
            end
        end
    end
    if (kind == constants.item_ids.stone or kind == constants.item_ids.wooden_box) and not blocked then
        if abs(T.x_int - 2 * trunc(S.vx) - S.x_int) < 300 and abs(T.z_int - S.z_int) < 6
           and random(context.skill5 + 7) == 0 and other_state ~= state_lying then
            press(S, "attack")
        end
    end
    if kind ~= item_id_milk and kind ~= item_id_beer then return true end
    for _, key in ipairs({"defend", "jump", "attack", "down", "up", "left", "right"}) do S.keys[key] = false end
    if self_state == constants.frame_states.drinking and close_target == 1 and danger_aligned == 0 and S.blink ~= 0 then
        press(S, "defend")
        return false
    end
    if S.follow_order ~= 0 then
        if abs(S.z_int - T.z_int) > 150 then return false end
        if abs(S.x_int - T.x_int) > 240 then return false end
    end
    local near, far = state.stage.zboundary[1] or 0, state.stage.zboundary[2] or 0
    local target_z = T.z_int
    if near + 30 <= target_z and (target_z < far - 30 or S.z_int < target_z) then
        press(S, "up")
    else
        press(S, "down")
    end
    local target_x = T.x_int
    local limit = context.width_limit
    if target_x < 400 and S.x_int < 200 then
        press(S, "right")
        if random(context.skill3 + 7) == 0 then fresh(S, "right") end
        if random(context.skill3 + 5) == 0 and self_state == state_running then
            press(S, "jump")
            return false
        end
    elseif limit - 400 < target_x and limit - 200 < S.x_int then
        press(S, "left")
        if random(context.skill3 + 7) == 0 then fresh(S, "left") end
        if random(context.skill3 + 5) == 0 and self_state == state_running then
            press(S, "jump")
            return false
        end
    else
        local self_x = S.x_int
        if abs(target_x - self_x) < 350 and abs(T.z_int - S.z_int) < 70 then
            if self_x < target_x then
                press(S, "left")
                if random(context.skill3 + 4) == 0 then fresh(S, "left") end
            end
            if S.x_int < T.x_int then return false end
            press(S, "right")
            if random(context.skill3 + 4) ~= 0 then return false end
            fresh(S, "right")
            return false
        end
        if self_state == state_running then
            if S.facing == facing_right then press(S, "left") end
            if S.facing == facing_left then
                press(S, "right")
                return false
            end
        elseif random(5) == 0 then
            if danger_aligned == 0 then
                local type = S.record.id
                if (type == fighter_john or type == fighter_sorcerer)
                   and S.mp > 150 and random(context.skill3 + 3) > 0 then
                    if T.x_int <= S.x_int then S.sequences[combo_left_jump] = sequence_complete else S.sequences[combo_right_jump] = sequence_complete end
                    return true
                end
            end
            press(S, "attack")
        end
    end
    return false
end

function ai.control(state, index, mode, context)
    local items = state.items
    local S = items[index]
    local T
    context = context or ai.prepare(state)
    context.self_index = index
    local target, saved_target = -1, -1
    local nearest_distance, moving_distance, special_distance = 10000, 10000, 10000
    local close_target, team_count, strongest, needs_help, cautious = 0, 0, 0, 0, 0
    local right, left, deeper, shallower, danger_aligned, danger_near, found = 0, 0, 0, 0, 0, 0, 0
    local self_state, other_state, kind, previous, i
    if mode == mode_stage and state.stage_run and state.stage_run.last_phase == 1 then
        copy_and_clear(S)
        press(S, "right"); fresh(S, "right")
        if not S.blocked_right then return end
        fresh(S, "attack"); press(S, "attack")
        return
    end
    -- An order marker (+0x3fc/+0x400) makes the computer walk to it.
    if no_order < S.order_x then
        copy_and_clear(S)
        local walking = state_of(S, context)
        if S.x_int > S.order_x + 6 then
            press(S, "left")
            if S.x_int > S.order_x + 250 and random(state.ai_skill * 3 + 3) == 0 then fresh(S, "left") end
            if S.x_int < S.order_x + 100 and walking == state_running and S.facing == facing_left then press(S, "right") end
        elseif S.x_int < S.order_x - 6 then
            press(S, "right")
            if S.x_int < S.order_x - 250 and random(state.ai_skill * 3 + 3) == 0 then fresh(S, "right") end
            if S.x_int > S.order_x - 100 and walking == state_running and S.facing == facing_right then press(S, "left") end
        end
        if S.z_int < S.order_z - 3 then press(S, "down")
        elseif S.z_int > S.order_z + 3 then press(S, "up") end
        if S.blocked_right or S.blocked_left then
            fresh(S, "attack"); press(S, "attack")
        end
        if abs(S.order_z - S.z_int) > 90 then return end
        if abs(S.order_x - S.x_int) > 90 then return end
        S.order_x, S.order_z = no_order, no_order
        return
    end
    context.width_limit = state.stage_bound > 0 and state.stage_bound or (state.stage.width or constants.screen.width)
    local skill
    if state.random_game or (mode == mode_stage and S.team ~= team_enemies
       and (index < 20 or S.record.id < constants.record_id_ranges.random_fighter_end_exclusive)) then
        skill = 0
    else
        skill = state.difficulty
        if skill < 0 then skill = 0 end
    end
    state.ai_skill = skill
    context.skill3, context.skill5, context.skill15, context.skill20 = skill * 3, skill * 5, skill * 15, skill * 20
    context.edge_flag = 0

    if mode == mode_stage or mode == constants.modes.battle then
        local team = S.team
        if team ~= team_enemies then
            strongest = 1
            if cdiv(S.max_hp * 4, 5) < S.hp or S.max_hp - 130 < S.hp then strongest = 0 end
            for position = 1, #context.characters do
                local j = context.characters[position]
                local A = items[j]
                if j ~= index and A and A.hp > 0 and A.record.kind == record_kinds.character and A.team == team then
                    if A.hp < S.hp then strongest = 0 end
                    team_count = team_count + 1
                end
            end
            local health = S.hp
            needs_help = 0
            if health > 430 or S.max_hp - 130 < health then needs_help = 1 end
            for position = 1, #context.characters do
                local j = context.characters[position]
                local A = items[j]
                if j ~= index and A and A.hp > 0 and A.record.kind == record_kinds.character and A.team == team and A.hp < health - 200 then
                    needs_help = 1
                end
            end
            if mode == mode_stage then
                local best_x, best_z = -1, 0
                for j = 0, 9 do
                    local A = items[j]
                    if j ~= index and A and A.hp > 0 and A.record.kind == record_kinds.character and A.x_int > best_x then
                        best_z, best_x = A.z_int, A.x_int
                    end
                end
                if best_x > -1 then
                    local x = S.x_int
                    if x > best_x and cdiv(abs(S.z_int - best_z), 2) - best_x + x > 200 then context.edge_flag = 1 end
                    if S.x_int > best_x + 400 then context.edge_flag = 2 end
                end
            end
            if team_count == 0 then strongest = 0 end
        end
    end
    if S.follow > -1 then needs_help, cautious = 1, 1 end
    if S.mp > 250 then cautious = 1 end
    if mode == mode_stage and S.team == constants.teams.player_one then cautious = 1 end
    if index >= 20 and mode == constants.modes.battle then cautious = 1 end

    local targets, waiting = target_lists(context, mode, S.team)
    for position = 1, #targets do
        local j = targets[position]
        local O = items[j]
        if j ~= index and O then
            local eligible = O.record.kind == record_kinds.character
                or (O.x_int > S.x_int and O.vx < 0.0) or (O.x_int < S.x_int and O.vx > 0.0)
            if eligible then
                local distance = abs(O.z_int - S.z_int) + abs(O.x_int - S.x_int)
                if distance < nearest_distance then target, nearest_distance = j, distance end
            end
        end
    end
    if target >= 0 and abs(items[target].z_int - S.z_int) < 15 then close_target = 1 end
    if state_of(S, context) ~= constants.frame_states.catching then
        -- Lying or blinking enemies nearby become the target to wait for.
        for position = 1, #waiting do
            local j = waiting[position]
            local O = items[j]
            if j ~= index and O then
                local dz, dx = abs(O.z_int - S.z_int), abs(O.x_int - S.x_int)
                if dx + dz < moving_distance and dz < 40 and dx < 250 then target, moving_distance = j, dx + dz end
            end
        end
    end
    previous = S.last_target
    if previous > -1 and previous < constants.item_slots then
        local P = items[previous]
        if P and P.hp > 0 and random(30) > 0 and P.record.kind == record_kinds.character then target = previous
        else S.last_target = target end
    else
        S.last_target = target
    end
    copy_and_clear(S)
    saved_target = target
    if target < 0 then goto no_target end
    for position = 1, #context.objects do
        local k = context.objects[position]
        local O = items[k]
        if O then
            local type = O.record.id
            if type == object_john_ball then
                local tenth = math.floor(O.frame / 10)
                if (tenth == 6 and O.team ~= S.team)
                   or (tenth == 5 and (S.record.id == fighter_john or S.record.id == fighter_sorcerer)
                       and not (S.hp < S.max_hp - 70 and S.hp < S.max_hp - 200)
                       and not (S.hp < cdiv(S.max_hp * 3, 5) and S.hp >= S.max_hp - 200)
                       and O.team == S.team) then
                    local self_z = S.z_int
                    local dz = abs(O.z_int - self_z)
                    danger_near = 1
                    if dz < 25 then
                        local dx = abs(O.x_int - S.x_int)
                        if dx < 150 then
                            danger_aligned = 1
                            if dz < 20 then
                                if dx < 180 then
                                    if O.z_int > self_z then deeper = 1 else shallower = 1 end
                                end
                                if O.x_int > S.x_int then right = 1 else left = 1 end
                            end
                        end
                    end
                end
            end
            if (type == constants.object_ids.firen_flame and state_of(O, context) == state_burning) or (type == constants.object_ids.freeze_column and O.frame >= 150 and O.frame <= 170) then
                if abs(O.x_int - S.x_int) < 80 then
                    if O.z_int > S.z_int + 20 then deeper = 1
                    elseif O.z_int < S.z_int - 20 then shallower = 1 end
                end
                if abs(O.z_int - S.z_int) < 20 then
                    if O.x_int > S.x_int + 100 then right = 1
                    elseif O.x_int < S.x_int - 100 then left = 1 end
                end
            end
            local skip = false
            if found == 0 then
                if close_target == 0 and danger_near == 0 then
                    local distance = abs(O.z_int - S.z_int) + abs(O.x_int - S.x_int)
                    local frame_state = state_of(O, context)
                    if S.weapon == weapon_none and distance < nearest_distance * 2 and distance < special_distance
                       and (math.floor(type / 100) == 1 or type == constants.item_ids.ice_sword) and O.weapon == weapon_none
                       and (frame_state == state_resting_light_item or frame_state == constants.frame_states.resting_heavy_item) then
                        if not (needs_help == 1 and type == item_id_milk) and not (cautious == 1 and type == item_id_beer)
                           and not (S.follow_order == 1 and type ~= item_id_milk) then
                            target, special_distance = k, distance
                        end
                    end
                end
            elseif found > 1 then
                skip = true
            end
            if not skip then
                if type == object_john_ball and math.floor(O.frame / 10) == 5 then
                    if abs(O.x_int - S.x_int) < 300 and abs(O.z_int - S.z_int) < 90 and O.team == S.team then
                        if (S.hp < S.dark_hp - 70 and S.hp < 140) or (S.hp < cdiv(S.dark_hp * 3, 5) and S.hp >= 140) then
                            target = k
                        end
                        found = 1
                    end
                end
                if strongest == 1 and type == item_id_milk and state_of(O, context) == state_resting_light_item and S.weapon == weapon_none then
                    target, found = k, 1
                end
            end
        end
    end
    if danger_near == 1 then target = saved_target end
    if target < 0 then goto no_target end
    T = items[target]
    other_state = state_of(T, context)
    self_state = state_of(S, context)
    i = target
    if random(context.skill5 + 8) == 0 then
        if S.blocked_up or S.blocked_down or S.blocked_left or S.blocked_right then
            fresh(S, "attack"); press(S, "attack")
        end
    end
    if other_state == constants.frame_states.flying_ball then
        if self_state ~= state_defending and random(context.skill3) == 0 then
            local self_x, other_x = S.x_int, T.x_int
            if (other_x > self_x and other_x < self_x + 200 and 0.0 > T.vx)
               or (other_x < self_x and other_x > self_x - 200 and 0.0 < T.vx) then
                fresh(S, "defend"); press(S, "defend")
            end
        end
        if T.x_int > S.x_int and S.facing == facing_left then press(S, "right") end
        if T.x_int < S.x_int and S.facing == facing_right then press(S, "left") end
        return
    end
    if S.follow_order == 1 then
        if S.weapon > 0 then
            local held = objects.lookup(state, S.held_item)
            local held_id = held and held.record.id
            if held_id == item_id_milk or held_id == item_id_beer then
                fresh(S, "attack"); press(S, "attack")
                return
            end
        end
        if T.x_int > S.x_int and S.facing == facing_left then press(S, "right") end
        if T.x_int < S.x_int and S.facing == facing_right then press(S, "left") end
        -- A running fighter also presses against its facing, which brakes it.
        if self_state == state_running then
            if S.facing == facing_left then press(S, "right") end
            if S.facing == facing_right then press(S, "left") end
        end
    end
    if other_state == state_resting_light_item or other_state == constants.frame_states.resting_heavy_item then goto pick_up end
    if S.follow_order ~= 0 and far_from(S, T) then goto approach end
    if other_state == state_lying or abs(T.blink) > 2 then goto wait_nearby end
    ::approach::
    if T.record.id == object_john_ball then
        if T.x_int > S.x_int + 7 then press(S, "right")
        elseif T.x_int < S.x_int - 7 then press(S, "left") end
        if T.z_int > S.z_int + 2 then goto go_down end
        if T.z_int < S.z_int - 2 then press(S, "up") end
        return
    end
    -- A mod's AI script with ego() takes the place of the special moves (base/game/ai_scripts).
    do
        local scripted = ai_scripts.ego(state, index, target)
        if scripted ~= nil then
            if scripted ~= 0 then return end
        elseif specials(context, T, S, other_state, danger_aligned, nearest_distance, close_target) then
            return
        end
    end
    if S.follow_order ~= 0 and far_from(S, T) then goto weapon_check end
    if (right == 1 or context.edge_flag == 1) and self_state == state_running and S.facing == facing_right then press(S, "left") end
    if left == 1 and self_state == state_running and S.facing == facing_left then press(S, "right") end
    kind = S.record.id
    if kind == fighter_henry or kind == fighter_rudolf or kind == fighter_hunter then goto keep_distance end
    do
        local hp = S.hp
        if (T.hp > hp * 2 or (hp <= 100 and S.max_hp > 100)) and mode == mode_stage and T.record.kind == record_kinds.character
           and index >= 20 and S.team ~= team_enemies then
            goto keep_distance
        end
    end
    if self_state == state_burning_run then goto depth end
    do
        local self_x, other_x = S.x_int, T.x_int
        if other_x > self_x + 60 or (other_x > self_x and S.facing == facing_left) then
            if right == 0 and (context.edge_flag == 0 or S.facing == facing_left) then
                press(S, "right")
                if random(context.skill20 + 35) == 0 then fresh(S, "right") end
            end
        end
        self_x, other_x = S.x_int, T.x_int
        if other_x < self_x - 60 or (other_x < self_x and S.facing == facing_right) then
            if left == 0 then
                press(S, "left")
                if random(context.skill20 + 35) == 0 then fresh(S, "left") end
            end
        end
    end
    goto depth
    ::keep_distance::
    do
        local self_x, other_x = S.x_int, T.x_int
        if other_x > self_x + 170 or ((other_x > self_x + 150 or (self_state == state_defending and other_x > self_x)) and S.facing == facing_left) then
            if right == 0 and context.edge_flag == 0 then
                press(S, "right")
                if random(context.skill20 + 35) == 0 then fresh(S, "right") end
            end
        end
        self_x, other_x = S.x_int, T.x_int
        if other_x < self_x - 170 or ((other_x < self_x - 150 or (self_state == state_defending and other_x < self_x)) and S.facing == facing_right) then
            if left == 0 then
                press(S, "left")
                if random(context.skill20 + 35) == 0 then fresh(S, "left") end
            end
        end
    end
    ::depth::
    if (T.z_int > S.z_int + 3 and danger_aligned == 0) or ((right == 1 or left == 1) and shallower == 1) then
        if deeper == 0 and self_state ~= state_burning_run then press(S, "down") end
    end
    if (T.z_int < S.z_int - 3 and danger_aligned == 0) or ((right == 1 or left == 1) and deeper == 1) then
        if shallower == 0 and self_state ~= state_burning_run then press(S, "up") end
    end
    ::weapon_check::
    if S.weapon > 0 then
        if not weapon_keys(state, context, target, index, self_state, other_state, close_target, danger_aligned) then
            return
        end
    end
    if random(skill * 7 + 10) == 0 then
        if other_state == state_attacking or math.floor(other_state / 100) == 3 then
            if abs(T.z_int - S.z_int) < 9 then
                if (T.facing == facing_right and T.x_int < S.x_int) or (T.facing == facing_left and T.x_int > S.x_int) then
                    press(S, "defend")
                end
            end
        end
    end
    if S.follow_order ~= 0 and far_from(S, T) then goto jump_check_done end
    if random((skill * 5 + 10) * 2) < 3 and random(20) < 3 and other_state ~= state_lying then press(S, "jump") end
    ::jump_check_done::
    kind = S.record.id
    if (kind == fighter_henry or kind == fighter_rudolf or kind == fighter_hunter) and other_state ~= state_dizzy then goto ranged end
    if abs(T.x_int - trunc(S.vx) * 2 - S.x_int) < 80 and abs(T.z_int - S.z_int) < 5
       and random(context.skill3 + 3) == 0 and other_state ~= state_lying then
        press(S, "attack")
    end
    ::ranged::
    kind = S.record.id
    if S.weapon == weapon_none and other_state == state_dizzy and (kind == fighter_henry or kind == fighter_rudolf or kind == fighter_hunter) then
        if abs(T.x_int - trunc(S.vx) * 2 - S.x_int) >= 350 then goto finish end
        if abs(T.z_int - S.z_int) >= 5 then goto finish end
        if random(context.skill3 + 3) ~= 0 then goto finish end
        goto face_attack
    elseif S.weapon == weapon_none and other_state ~= state_dizzy and (kind == fighter_henry or kind == fighter_rudolf or kind == fighter_hunter or kind == fighter_jan) then
        -- The original applies abs() to the whole condition; dx is signed here.
        if T.x_int - S.x_int < 100 and abs(T.z_int - S.z_int) < 80 and random(context.skill3 + 2) == 0
           and self_state ~= state_defending then
            if not (S.follow_order ~= 0 and far_from(S, T)) then edge_move(context, T, S) end
            if S.follow_order ~= 0 and far_from(S, T) then goto finish end
            if random(17) == 0 then press(S, "jump") end
            goto finish
        end
        if abs(T.x_int - trunc(S.vx) * 2 - S.x_int) >= 300 then goto finish end
        if abs(T.z_int - S.z_int) >= 5 then goto finish end
        if random(context.skill3 + 3) ~= 0 then goto finish end
        if other_state == state_lying then goto finish end
        goto face_attack
    else
        if not (T.hp > S.hp * 2 or (S.hp <= 100 and S.max_hp > 100)) then goto finish end
        if mode ~= mode_stage or T.record.kind ~= record_kinds.character or index < 20 or S.team == team_enemies then goto finish end
        if not (T.x_int - S.x_int < 100 and abs(T.z_int - S.z_int) < 80 and random(context.skill3 + 2) == 0)
           or self_state == state_defending then
            goto finish
        end
        if not (S.follow_order ~= 0 and far_from(S, T)) then edge_move(context, T, S) end
        if S.follow_order ~= 0 and far_from(S, T) then goto finish end
        if random(17) == 0 then press(S, "jump") end
        goto finish
    end
    ::face_attack::
    if (T.x_int > S.x_int and S.facing == facing_right) or (T.x_int <= S.x_int and S.facing == facing_left) then press(S, "attack") end
    ::finish::
    attacks(context, T, S, other_state, right, left)
    ::no_target::
    if target ~= -1 then return end
    do
        local anchor = i and objects.lookup(state, i)
        local far = i == nil or (anchor ~= nil and far_from(S, anchor))
        if not (S.follow_order ~= 0 and far) then
            if context.edge_flag == 1 then press(S, "left") end
        end
    end
    kind = S.record.id
    if kind == fighter_firen then
        if S.frame >= 255 and S.frame <= 261 then press(S, "defend") end
    elseif kind == fighter_dennis then
        if S.frame >= 280 and S.frame <= 290 then press(S, "defend") end
    elseif kind == constants.fighter_ids.mark then
        if S.frame >= 240 and S.frame <= 245 then press(S, "defend") end
    end
    do return end
    ::wait_nearby::
    if T.x_int > context.width_limit - 30 then
        press(S, "left"); fresh(S, "left")
        return
    end
    if T.x_int < 30 then
        press(S, "right"); fresh(S, "right")
        return
    end
    if abs(T.z_int - S.z_int) > 45 and abs(T.x_int - S.x_int) > 350 then return end
    if T.x_int > S.x_int then
        press(S, "left")
        if random(context.skill20 + 35) == 0 then fresh(S, "left") end
    else
        press(S, "right")
        if random(context.skill20 + 35) == 0 then fresh(S, "right") end
    end
    if T.z_int < S.z_int then goto go_down end
    if T.z_int >= (state.stage.zboundary[1] or 0) + 10 then
        press(S, "up")
        return
    end
    ::go_down::
    press(S, "down")
    do return end
    ::pick_up::
    if S.follow_order ~= 0 and far_from(S, T) and T.record.id ~= item_id_milk and T.record.id ~= item_id_beer then goto pick_close end
    if S.x_int > T.x_int + 6 then
        press(S, "left")
        if S.x_int > T.x_int + 250 and random(context.skill3 + 3) == 0 then fresh(S, "left") end
        if S.x_int < T.x_int + 100 and self_state == state_running and S.facing == facing_left then press(S, "right") end
    elseif S.x_int < T.x_int - 6 then
        if context.edge_flag == 0 then press(S, "right") end
        if S.x_int < T.x_int - 250 and random(context.skill3 + 3) == 0 and context.edge_flag == 0 then
            fresh(S, "right")
        end
        if S.x_int > T.x_int - 100 and self_state == state_running and S.facing == facing_right then press(S, "left") end
    end
    if S.z_int < T.z_int - 3 then press(S, "down")
    elseif S.z_int > T.z_int + 3 then press(S, "up") end
    ::pick_close::
    if abs(T.z_int - S.z_int) > 3 then return end
    if abs(T.x_int - S.x_int) > 6 then return end
    fresh(S, "attack"); press(S, "attack")
end
return ai
