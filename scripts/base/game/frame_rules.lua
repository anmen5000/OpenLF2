-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

local constants = require("base/game/constants")
local record_kinds = constants.record_kinds
local objects = require("base/game/objects")
local merge = require("base/game/merge")
local unlock = require("base/game/unlock")
local frame_rules = {}

local function cdiv(a, b)
    local q = a / b
    if q >= 0 then return math.floor(q) end
    return math.ceil(q)
end
local function random(range) return engine.random(range) end
local function state_of(value) return value.record.frame(value.frame).state end
-- Naruto: The Setting Dawn's own program (its team's code tool: transform_same_frame, read from the executable by
-- the host; frame_rules.set_executable_patches) changes an object whose frame state is 4000-4999 into record
-- state - 4000 in the same frame number, picture offset 0, before the original's 8000-8999 test (which it then
-- skips). None for the original game, whose 4000-4999 are plain states.
local same_frame_transform = false
function frame_rules.set_executable_patches(options)
    same_frame_transform = (options or {}).transform_same_frame == true
end
-- Whether states 4000-4999 change records (above): what a fighter can become (base/game/smart_ai brings).
function frame_rules.transforms_same_frame() return same_frame_transform end

-- Followers (+0x2f4 = index) that are alive take the new record, airborne ones in frame 212.
local function pass_record(state, index, record)
    for other = 0, constants.item_slots - 1 do
        local follower = state.items[other]
        if follower and follower.follow == index and follower.hp > 0 then
            follower.record = record
            follower.frame = follower.y_int < 0 and constants.character_frames.jump + 2 or constants.character_frames.standing
        end
    end
end

local function teleport(state, index, mode)
    local me = state.items[index]
    local best, distance = -1, mode == constants.teleport_modes.nearest_enemy and constants.teleport.nearest_enemy_distance_limit or -1
    for other = 0, constants.item_slots - 1 do
        local value = state.items[other]
        if other ~= index and value and value.record.kind == record_kinds.character and value.hp > 0
           and ((mode == constants.teleport_modes.nearest_enemy and value.team ~= me.team) or (mode == constants.teleport_modes.farthest_ally and value.team == me.team)) then
            local next = math.abs(value.z_int - me.z_int) + math.abs(value.x_int - me.x_int)
            if (mode == constants.teleport_modes.nearest_enemy and next < distance) or (mode == constants.teleport_modes.farthest_ally and next > distance) then
                best, distance = other, next
            end
        end
    end
    me.y_int = 0
    if best == -1 then
        me.y = me.y_int
    else
        local target = state.items[best]
        local offset = mode == constants.teleport_modes.nearest_enemy and constants.teleport.enemy_x_offset or constants.teleport.ally_x_offset
        me.z_int = target.z_int + 1
        if me.facing == constants.facings.right then me.x_int = target.x_int - offset else me.x_int = target.x_int + offset end
        me.x, me.y, me.z = me.x_int, me.y_int, me.z_int
    end
    me.vz, me.vy, me.vx = 0.0, 0.0, 0.0
end

function frame_rules.round_end(state)
    for index = 0, constants.item_slots - 1 do
        local value = state.items[index]
        if value then
            if value.transform > -1 then
                local record = objects.record(state, value.transform)
                if record then
                    value.record = record
                    value.transform = -1
                end
            elseif value.record.id == constants.fighter_ids.louis_ex and unlock.flags.characters == 0 then
                value.record = objects.record(state, constants.fighter_ids.louis) or value.record
            elseif value.twin > constants.fusion_states.unmerged then
                merge.split_at_round_end(state, value)
            end
        end
    end
end

-- After each item's control step.
function frame_rules.after_control(state, index, value)
    local current = state_of(value)
    if current == constants.frame_states.teleport_to_enemy and state.shake == 0 then teleport(state, index, constants.teleport_modes.nearest_enemy) end
    if state_of(value) == constants.frame_states.teleport_to_ally and state.shake == 0 then teleport(state, index, constants.teleport_modes.farthest_ally) end
    if state_of(value) == constants.frame_states.transform_start and (value.transformed_to == -1 or value.transform > -1) then value.frame = 0 end
    if state_of(value) == constants.frame_states.transform_complete and value.transformed_to > -1 then
        local record = objects.record(state, value.transformed_to)
        if record then
            value.transform = value.record.id
            value.record = record
            value.frame = 0
            pass_record(state, index, record)
        end
    end
end

-- After each item's physics step (the item may be removed; returns false then).
function frame_rules.after_physics(state, index, value)
    if state_of(value) == constants.frame_states.lying and value.hp <= 0 and (value.follow >= 0 or value.team == constants.teams.enemies or index >= 20)
       and value.blink > 0 and value.blink < 5 then
        if value.join_hp > 0 then
            -- A beaten stage enemy with `join:` hp gets up for the players' team 1.
            value.lives = value.join_lives
            value.mp = 0
            value.max_hp = value.join_hp
            value.dark_hp = value.max_hp
            value.hp = value.dark_hp
            value.join_hp, value.join_lives = 0, 0
            value.team = constants.teams.player_one
            if value.record.id >= constants.fighter_ids.bandit and value.record.id <= constants.fighter_ids.jan then value.pic_offset = 140 end
            value.frame = constants.character_frames.crouch_alternate
            value.wait_counter = 0
            value.hit_lag = 10
            local slot = objects.free_slot(state)
            if slot ~= -1 and objects.record(state, constants.record_ids.team_order_marker) then
                local marker = objects.place(state, slot, constants.record_ids.team_order_marker)
                marker.x_int, marker.y_int, marker.z_int = value.x_int, value.y_int, value.z_int + 1
                marker.team = value.team
                marker.x, marker.y, marker.z = value.x, value.y, value.z
                marker.frame = 6
                marker.vx, marker.vy, marker.vz = 0.0, 0.0, 0.0
                marker.facing = constants.facings.right
            end
        elseif value.lives < 2 then
            objects.remove(state, index)
            return false
        else
            -- One of its lives: it drops in again near its teammates.
            local sum_x, sum_z, mates = 0, 0, 0
            value.lives = value.lives - 1
            for other = 0, constants.item_slots - 1 do
                local mate = state.items[other]
                if mate and other ~= index and mate.record.kind == record_kinds.character and mate.team == value.team then
                    sum_x = sum_x + mate.x_int
                    sum_z = sum_z + mate.z_int
                    mates = mates + 1
                end
            end
            -- The original divides by the mate count unguarded; without mates the port keeps x/z.
            if mates > 0 then
                value.x = cdiv(sum_x, mates) + random(constants.revival.x_random_range) - constants.revival.x_offset
                value.z = cdiv(sum_z, mates) + random(constants.revival.z_random_range) - constants.revival.z_offset
            end
            value.mp = constants.points.full
            value.dark_hp = value.max_hp
            value.hp = value.dark_hp
            value.blink = constants.blink.spawn_frames
            value.frame = constants.character_frames.jump + 2
            value.y_int = constants.revival.initial_y
            value.y = value.y_int
            value.vy = 0.0
        end
    end
    if value.transform > -1 and value.sequences[constants.combo_indices.jump_attack] == constants.combo_states.complete and value.y_int == 0 and value.hp > 0 then
        value.sequences[constants.combo_indices.jump_attack] = constants.combo_states.idle
        local record = objects.record(state, value.transform)
        if record then
            value.record = record
            value.frame = 245
            value.transform = -1
            pass_record(state, index, record)
        end
    end
    return true
end

-- Before each item's regeneration and frame advance.
function frame_rules.before_advance(state, index, value)
    if value.record.kind == record_kinds.character
       and state_of(value) == constants.frame_states.transform_louis_ex then
        value.record = objects.record(state, constants.fighter_ids.louis_ex) or value.record
        value.frame = 0
    end
    local current = state_of(value)
    if same_frame_transform and current >= 4000 and current < 5000 then
        value.record = objects.record(state, current - 4000) or value.record
        value.pic_offset = 0
    elseif current >= constants.frame_state_ranges.record_transform_start
       and current < constants.frame_state_ranges.record_transform_end_exclusive then
        value.record = objects.record(state,
            current - constants.frame_state_ranges.record_transform_start) or value.record
        value.frame = 0
        value.pic_offset = 140
    end
    if value.record.kind == record_kinds.character
       and state_of(value) == constants.frame_states.louis_transform_shards
       and value.wait_counter == 1 then
        -- Five pieces (records 217, the last 218) burst away from the fighter.
        for piece = 0, 4 do
            local slot = objects.free_slot(state)
            if slot == -1 then break end
            local part = objects.place(state, slot,
                piece == 4 and constants.item_ids.louis_armour_two or constants.item_ids.louis_armour)
            if not part then break end
            part.x_int = random(7) - 3 + value.x_int
            part.y_int = random(7) - 9 + value.y_int
            part.z_int = value.z_int + 1
            part.z, part.y, part.x = part.z_int, part.y_int, part.x_int
            part.vy = -cdiv(random(15), 2) - 5.0
            part.timer_ec = 6
            if piece == 0 or piece == 2 then part.vz = random(2) + 3.0
            elseif piece == 1 or piece == 3 then part.vz = -3.0 - random(2)
            else part.vz = 1.0 end
            if piece < 2 then part.vx = -10.0 - random(3)
            elseif piece < 4 then part.vx = random(3) + 10.0
            else part.vx = random(7) - 3.0 end
            part.frame = random(4)
            part.facing = random(2)
        end
    end
end

-- A living player's last four key presses can command their team (defend=9, jump=0, attack=5):
-- defend-jump-defend-jump spawns an order marker (record 998, +/-40px); four defends makes the
-- team follow; defend-attack-defend-attack cancels that.
function frame_rules.team_orders(state, index, value)
    if index >= 10 or value.hp <= 0 or value.record.kind ~= record_kinds.character then return end
    local h = value.key_history
    local code = constants.team_order_codes.none
    if h[2] == constants.key_history_codes.defend then
        if h[3] == constants.key_history_codes.jump and h[4] == constants.key_history_codes.defend
           and h[5] == constants.key_history_codes.jump then code = constants.team_order_codes.move_to_marker end
        if h[3] == constants.key_history_codes.defend and h[4] == constants.key_history_codes.defend
           and h[5] == constants.key_history_codes.defend then code = constants.team_order_codes.follow end
        if h[3] == constants.key_history_codes.attack and h[4] == constants.key_history_codes.defend
           and h[5] == constants.key_history_codes.attack then code = constants.team_order_codes.cancel_follow end
    end
    if code == constants.team_order_codes.none then return end
    value.key_history = {0, 0, 0, 0, 0}
    local slot = objects.free_slot(state)
    if slot == -1 or not objects.record(state, constants.record_ids.team_order_marker) then return end
    local marker = objects.place(state, slot, constants.record_ids.team_order_marker)
    marker.x_int, marker.y_int, marker.z_int = value.x_int, 0, value.z_int
    marker.frame = code - constants.team_order_codes.move_to_marker
    marker.z, marker.y, marker.x = marker.z_int, marker.y_int, marker.x_int
    marker.vx, marker.vy = 0.0, 0.0
    for other = 0, constants.item_slots - 1 do
        local member = state.items[other]
        if member and member.hp > 0 and member.record.kind == record_kinds.character and member.team == value.team then
            if code == constants.team_order_codes.move_to_marker then
                member.order_x = random(81) - 40 + marker.x_int
                member.order_z = random(81) - 40 + marker.z_int
            elseif code == constants.team_order_codes.follow then
                member.follow_order = 1
            else
                member.follow_order = 0
            end
        end
    end
end
return frame_rules
