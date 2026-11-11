-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

local constants = require("base/game/constants")
local i18n = require("base/i18n/i18n")
local record_kinds = constants.record_kinds
local battle_strategies = constants.battle_strategies
local objects = require("base/game/objects")
local battle = {}

local function cdiv(a, b)
    local q = a / b
    if q >= 0 then return math.floor(q) end
    return math.ceil(q)
end
local function cmod(a, b) return a - cdiv(a, b) * b end

local types = {[0] = constants.fighter_ids.bandit, constants.fighter_ids.hunter, constants.fighter_ids.jack,
    constants.fighter_ids.sorcerer, constants.fighter_ids.justin, constants.fighter_ids.mark,
    constants.fighter_ids.monk, constants.fighter_ids.jan, constants.fighter_ids.knight, constants.item_ids.milk, constants.item_ids.beer}
local type_count = 11
local strategies = {[battle_strategies.zero] = "Zero", [battle_strategies.balanced] = "Balanced",
    [battle_strategies.inferior] = "Inferior", [battle_strategies.ranged_attack] = "Ranged attack",
    [battle_strategies.melee_attack] = "Melee attack", [battle_strategies.giant] = "Giant", [battle_strategies.full] = "Full"}
local sizes = {[constants.battle_sizes.small] = "(S)", [constants.battle_sizes.medium] = "(M)", [constants.battle_sizes.large] = "(L)"}
-- Soldier hp by record id (separate ifs in the original, 500 otherwise).
local soldier_hp = {[constants.fighter_ids.jan] = 250, [constants.fighter_ids.knight] = 200,
    [constants.fighter_ids.monk] = 200, [constants.fighter_ids.mark] = 200, [constants.fighter_ids.justin] = 150,
    [constants.fighter_ids.jack] = 150, [constants.fighter_ids.sorcerer] = 100,
    [constants.fighter_ids.hunter] = 50, [constants.fighter_ids.bandit] = 50, [constants.item_ids.milk] = 200}

-- config: the setup's counts (stock/on_field computed at Start Game), defense, strategy, size.
function battle.create(config)
    local run = {stock = {}, on_field = {}, deaths = {[1] = 0, [2] = 0}, damage = {[1] = 0, [2] = 0},
        defense = {[0] = config.defense[0], [1] = config.defense[1]},
        strategy = {[0] = config.strategy[0], [1] = config.strategy[1]},
        size = {[0] = config.size[0], [1] = config.size[1]}, over = false}
    for i = 0, type_count * 2 - 1 do
        run.stock[i] = (config.stock and config.stock[i]) or 0
        run.on_field[i] = (config.on_field and config.on_field[i]) or 0
    end
    return run
end

function battle.count_kill(state, victim)
    local run = state.battle_run
    if run and victim.battle_side > 0 and victim.battle_side < 3 then
        run.deaths[victim.battle_side] = run.deaths[victim.battle_side] + 1
    end
end
-- (`attacker`: the item whose blow it was; `defended`: a guarded blow's chip; `contact`: a blow that touched without
-- taking HP off yet — a whirlwind's, whose HP goes later, a little at a time. battle.on_damage, when a bench job sets
-- it — the balance job, tools/ai-bench/balance.lua, crediting each blow to the move that dealt it — sees every blow;
-- it changes nothing.)
function battle.count_damage(state, victim, damage, attacker, defended, contact)
    local run = state.battle_run
    if run and victim.battle_side > 0 and victim.battle_side < 3 then
        run.damage[victim.battle_side] = run.damage[victim.battle_side] + damage
    end
    if battle.on_damage then battle.on_damage(state, victim, contact and 0 or damage, attacker, defended == true, contact == true) end
end

local function caption(run, side)
    local strategy = run.strategy[side]
    local text = strategies[strategy] or ""
    if strategy > battle_strategies.zero and strategy < battle_strategies.full then text = text .. (sizes[run.size[side]] or "") end
    local defense = run.defense[side]
    if defense ~= constants.defense.normal then
        if strategy ~= battle_strategies.custom then text = text .. "    " end
        text = text .. string.format("Defense: %d.%d", cdiv(defense, 100), cdiv(cmod(defense, 100), 10))
    end
    return text
end

function battle.update(state, run)
    local display = {}
    local census = {}
    local men, health = {[0] = 0, [1] = 0}, {[0] = 0, [1] = 0}
    for i = 0, type_count * 2 - 1 do census[i] = 0 end
    for index = 0, constants.item_slots - 1 do
        local value = state.items[index]
        if value then
            if value.battle_side > 0 and value.battle_side < 3 and index >= 20 then
                local id = value.record.id
                if (id >= constants.fighter_ids.bandit and id <= constants.fighter_ids.justin
                    and id ~= constants.fighter_ids.bat) or id == constants.item_ids.milk or id == constants.item_ids.beer then
                    for kind = 0, type_count - 1 do
                        if types[kind] == id then
                            local key = (value.battle_side - 1) * type_count + kind
                            census[key] = census[key] + 1
                        end
                    end
                end
            end
            if value.record.kind == record_kinds.character and value.hp > 0 then
                local side = value.team == constants.teams.player_one and 0 or 1
                men[side] = men[side] + 1
                health[side] = health[side] + value.hp
            end
        end
    end
    local width = state.stage.width or constants.view.width
    local near, far = state.stage.zboundary[1] or 0, state.stage.zboundary[2] or 0
    for side_base = 0, type_count, type_count do
        for kind = 0, type_count - 1 do
            local index = side_base + kind
            if run.stock[index] > 0 and run.on_field[index] > census[index] then
                local slot = -1
                for candidate = constants.first_spawned_slot, constants.item_slots - 1 do
                    if not state.items[candidate] then slot = candidate break end
                end
                local id = types[kind]
                if slot ~= -1 and objects.record(state, id) then
                    local value = objects.place(state, slot, id)
                    value.x, value.y, value.z = 350.0, 0.0, 300.0
                    value.z_int = engine.random(far - near) + near
                    local character = value.record.kind == record_kinds.character
                    if side_base == 0 then
                        value.x_int = character and -100 or 50
                    elseif character then
                        value.x_int = width + 100
                    else
                        value.x_int = width - 50
                    end
                    value.x, value.z = value.x_int, value.z_int
                    local hp = soldier_hp[id] or constants.points.full
                    if side_base == 0 and character then
                        -- Side 1 soldiers use the second color set (picture offset 140; 114 for 37).
                        value.pic_offset = id == constants.fighter_ids.knight and 114 or 140
                    end
                    value.mp = constants.points.full
                    value.dark_hp, value.hp, value.max_hp = hp, hp, hp
                    value.owner = slot
                    local side = cdiv(side_base, type_count) + 1
                    if character or value.record.kind == record_kinds.prisoner then
                        value.blink = constants.blink.spawn_frames
                        value.facing = value.x_int > cdiv(width, 2) and constants.facings.left or constants.facings.right
                        value.team = side
                    else
                        value.blink = 0
                        value.team = constants.teams.independent
                    end
                    value.battle_side = side
                    value.y_int = -300
                    value.y = value.y_int
                    if character or value.record.kind == record_kinds.prisoner then value.vy = 0.0 end
                    run.stock[index] = run.stock[index] - 1
                end
            end
        end
    end
    local reserves = {[0] = 0, [1] = 0}
    for side = 0, 1 do
        for kind = 0, type_count - 3 do reserves[side] = reserves[side] + run.stock[side * type_count + kind] end
    end
    run.over = not ((reserves[0] > 0 and reserves[1] > 0) or (men[0] > 0 and men[1] > 0))
    for side = 0, 1 do
        display[#display + 1] = {"text", string.format("%s %3d     %s %4d     %s %3d     %s %3d",
            i18n.tr("Man:"), men[side], i18n.tr("HP:"), health[side], i18n.tr("Reserve:"), reserves[side],
            i18n.tr("Die:"), run.deaths[side + 1]), side == 0 and 10 or 450, 110,
            side == 0 and 0xffb294 or 0xada6ff}
    end
    -- The strategy lines are outlined bitmap text in the team fonts (1 and 2), as in the original.
    local left, right = caption(run, 0), caption(run, 1)
    display[#display + 1] = {"caption", left, 10, 133, 1}
    display[#display + 1] = {"caption", right, 785 - #right * 8, 133, 2}
    return display
end
return battle
