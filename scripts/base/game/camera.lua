-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

local constants = require("base/game/constants")
local camera_motion_facing_lookahead = constants.camera_motion.facing_lookahead
local camera_motion_fallback_focus_x = constants.camera_motion.fallback_focus_x
local camera_motion_previous_step_weight = constants.camera_motion.previous_step_weight
local camera_motion_step_weight_divisor = constants.camera_motion.step_weight_divisor
local camera_motion_target_distance_divisor = constants.camera_motion.target_distance_divisor
local state_lying = constants.frame_states.lying
local item_id_beer = constants.item_ids.beer
local item_id_milk = constants.item_ids.milk
local item_slots = constants.item_slots
local mode_stage = constants.modes.stage
local view = constants.view -- the match's picture (a mod's own screen, else the classic one), read when it runs
local stage_group_survival = constants.stage_groups.survival
local team_enemies = constants.teams.enemies
local world_edge_ball_margin = constants.world_edges.ball_margin
local world_edge_drink_margin = constants.world_edges.drink_margin
local world_edge_enemy_character_left_margin = constants.world_edges.enemy_character_left_margin
local world_edge_spawned_character_margin = constants.world_edges.spawned_character_margin
local record_kinds = constants.record_kinds
local record_kinds = constants.record_kinds
local objects = require("base/game/objects")
local camera = {}

local function cdiv(a, b)
    local q = a / b
    if q >= 0 then return math.floor(q) end
    return math.ceil(q)
end
local function truncate(value)
    if value >= 0 then return math.floor(value) end
    return math.ceil(value)
end

-- Keeps items inside the stage depth and width; the last-rendered-width rules by kind.
local function clamp(state)
    local stage = state.stage
    local near, far, width = stage.zboundary[1] or 0, stage.zboundary[2] or 0, stage.width or view.width
    for index = 0, item_slots - 1 do
        local value = state.items[index]
        if value then
            local kind = value.record.kind
            if kind == record_kinds.character then
                if near > value.z then value.z = near end
                if far < value.z then value.z = far end
            else
                if near - 1.0 > value.z then value.z = near - 1.0 end
                if far + 1.0 < value.z then value.z = far + 1.0 end
            end
            value.z_int = truncate(value.z)
            if kind == record_kinds.ball then
                if value.x < -world_edge_ball_margin or width + world_edge_ball_margin < value.x then objects.remove(state, index) end
            elseif kind == record_kinds.character then
                if index >= 20 then
                    if value.x < -world_edge_spawned_character_margin then value.x = -world_edge_spawned_character_margin end
                    if width + world_edge_spawned_character_margin < value.x then value.x = width + world_edge_spawned_character_margin end
                else
                    if value.team == team_enemies then
                        if value.x < -world_edge_enemy_character_left_margin then value.x = -world_edge_enemy_character_left_margin end
                    elseif value.x < 0.0 then
                        value.x = 0.0
                    end
                    if width < value.x then value.x = width end
                end
                if state.stage_bound > 0 and state.stage_bound < value.x and value.team ~= team_enemies and value.blink == 0 then
                    value.x = state.stage_bound
                end
            elseif (value.record.id == item_id_milk or value.record.id == item_id_beer)
                   and (value.battle_side > 0 or (state.mode == mode_stage and math.floor(state.stage_run.id / 10) == stage_group_survival)) then
                if value.x < world_edge_drink_margin then value.x = world_edge_drink_margin end
                if width - world_edge_drink_margin < value.x then value.x = width - world_edge_drink_margin end
            elseif (value.x < 0.0 or width < value.x) and value.y_int == 0 then
                objects.remove(state, index)
            end
            value.x_int = truncate(value.x)
        end
    end
end

function camera.step(state)
    clamp(state)
    local sum, count = 0, 0
    local network = state.held and state.held.network
    for index = 0, 7 do
        local value = state.items[index]
        if value and value.human and value.hp > 0 and (network or index < 4) then
            if value.record.frame(value.frame).state == state_lying then sum = sum + value.x_int
            else sum = sum + camera_motion_facing_lookahead + value.x_int - value.facing * (camera_motion_facing_lookahead * 2) end
            count = count + 1
        end
    end
    if count == 0 then
        for index = 0, item_slots - 1 do
            local value = state.items[index]
            if value and value.record.kind == record_kinds.character and value.hp > 0 then
                sum = sum + value.x_int
                count = count + 1
            end
        end
        if count == 0 then sum, count = camera_motion_fallback_focus_x, 1 end
    end
    local screen_width = view.width
    local width = state.stage.width or screen_width
    local target = cdiv(sum, count) - screen_width / 2
    if target < 0 then target = 0 end
    if target > width - screen_width then target = width - screen_width end
    if state.camera_limit ~= 0 and target > state.camera_limit then target = state.camera_limit end
    state.camera_step = cdiv(cdiv(target - state.camera, camera_motion_target_distance_divisor) + state.camera_step * camera_motion_previous_step_weight, camera_motion_step_weight_divisor)
    if state.camera_step == 0 then
        if state.camera < target then state.camera_step = 1
        elseif target < state.camera then state.camera_step = -1 end
    end
    state.camera = state.camera + state.camera_step
    local pan = state.replay_pan
    if pan and pan.active then state.camera = pan.x end
    if state.camera < 0 then state.camera = 0 end
    if state.camera > width - screen_width then state.camera = width - screen_width end
    if pan and pan.active then pan.x = state.camera end
end
return camera
