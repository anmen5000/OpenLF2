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
-- - A move that leaves an item of the fighter's own making in its hand (a mod's stronger form: Gear Second, Diable
--   Jambe) is a form: what the keys do in it, how it runs, what it burns and what it is worth are learned the same
--   way, in the copy, and the form is entered when worth it and safe.
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
local sqrt = math.sqrt
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
-- chance to attack is taken. XOI plays as INSANE! does, with the notes of training besides (see XOI below).
smart.levels = {
    [constants.difficulties.insane] = {reaction = 1, eagerness = 100},
    [constants.difficulties.xoi] = {reaction = 1, eagerness = 100, notes = true},
}
-- Numbers of the computer player's judgement gathered in one place, for tuning them by play (SPSA,
-- tools/ai-bench/spsa.lua): name, value, the range a tuning may try, whether it is a whole number. smart.tune holds
-- the values in use (smart.set_tune lays a tuned set over them); each is described where it is used.
smart.tune_ranges = {
    -- How a move's hit is weighed (attack_score): the sureness lost per frame the target is free to act, its floor,
    -- the part left when the target's answer could come first, how much a standoff's boldness lowers the expected
    -- guard, the price of MP and HP a move costs, the frames that halve a blow's worth (time_bias 10: 14/(t + 10)),
    -- the share of the target's counter counted when the fighter is still busy as it could land, the price per
    -- frame left open after the blow, and the pull of a move not yet tried or the push of one just used.
    {"sure_decay", 0.04, 0.01, 0.1}, {"sure_floor", 0.2, 0.05, 0.5}, {"danger_sure", 0.6, 0.3, 1},
    {"guard_aggression", 0.5, 0, 1}, {"mp_cost", 0.06, 0, 0.15}, {"hp_cost", 0.5, 0, 1.5},
    {"time_bias", 10, 4, 25}, {"counter_price", 0.7, 0.2, 1.5}, {"open_cost", 0.2, 0, 0.6},
    {"novelty", 1.1, 1, 1.4}, {"repeat_factor", 0.85, 0.5, 1},
    -- The score a move needs to be started, on the ground or from a jump; frames between jump-ins.
    {"attack_threshold", 2.5, 0.5, 6}, {"jump_cooldown", 50, 15, 120, true},
    -- Boldness: frames without a blow before a standoff makes the fighter bolder, and over how many more it grows
    -- to the full; how bold it is against an opponent that hardly attacks.
    {"calm_start", 90, 30, 240}, {"calm_span", 150, 50, 400}, {"passive_aggression", 0.6, 0.2, 1},
    -- The answer expected to a risky move: the chance before anything is seen (XOI's notes set their own) and how
    -- many risky moves' worth that guess counts for; the share of the target's strongest blow a strike out of its
    -- guard is reckoned to cost; how much heavier a blow must be to trade with a threat landing as it does.
    {"risk_prior", 0.25, 0.05, 0.6}, {"risk_weight", 4, 1, 12}, {"guard_counter", 0.5, 0.1, 1},
    {"trade_factor", 1.3, 0.8, 2.5},
    -- Spacing: how much an enemy's quick blows must threaten a spot for it to be left, and how much more as a
    -- standoff drags on; beyond longer arms, how far out to wait, and how far to charge MP from when short of it.
    {"keep_out_base", 30, 5, 70}, {"keep_out_aggression", 60, 0, 120},
    {"hold_margin", 15, -10, 60, true}, {"charge_gap", 115, 60, 220, true},
    -- A fallen enemy's wake-up blows: the margins of their zone in depth and in x, the step in depth it can take
    -- once up, and, off its line, how near and how far from the fighter's own range to wait.
    {"wake_margin_z", 8, 0, 20, true}, {"wake_margin_x", 24, 0, 60, true}, {"wake_step", 6, 0, 14, true},
    {"off_line_near", 15, -10, 40, true}, {"off_line_far", 10, -10, 40, true},
    -- Charging MP: how far beyond the target's quick reach, and how much below full MP.
    {"charge_room", 85, 30, 180, true}, {"charge_below", 80, 20, 200, true},
}
local tune = {}
for _, entry in ipairs(smart.tune_ranges) do tune[entry[1]] = entry[2] end
smart.tune = tune
-- Lays `values` (name = number) over the numbers in use, each kept within its range and whole numbers rounded.
function smart.set_tune(values)
    for _, entry in ipairs(smart.tune_ranges) do
        local value = values[entry[1]]
        if type(value) == "number" and value == value then
            value = max(entry[3], min(entry[4], value))
            if entry[5] then value = floor(value + 0.5) end
            tune[entry[1]] = value
        end
    end
end
-- The version of this computer player, shown on the site (dist/build-web.sh writes it and the history below to
-- insane-version.json) and beside INSANE! in the match. Raise it with every change to how it plays, and say
-- what changed in one line (newest first).
smart.version = 28
smart.history = {
    {28, "2026-11-01", "Keeps its distance from a fallen enemy, on shallow stages too. Stepping off the line of an enemy that is down, it counted the room left in depth from where it stood, so the room shrank with every step and on a stage only 60 deep (Hot Springs in Naruto: The Setting Dawn) the side flipped every few steps: the fighter walked to and fro on the fallen enemy's line until it got up. The room is now counted from the enemy's line, and the frames to get there count crossing it. And the step in depth that an enemy can take once up, before it strikes, is reckoned while it is still down: reckoned only once it was up, a fighter that had stepped just off its line was inside its blows again as it rose (Rock Lee waited right beside a fallen Neji, and was struck as he rose more often than before); where the stage has no room for that depth, the fighter backs out of reach instead. Blows taken from enemies just up again, on three shallow stages of Naruto 2.4: 2,485 damage instead of 3,511; against version 27, 312–293 over the 8 pairs of Naruto 2.4 and One Piece GrandWorld. (Waiting out of the enemy's plain arms at any depth was tried: fewer such blows, but the enemy just up had the first move, 136–168 in Naruto 2.4.)"},
    {27, "2026-11-01", "Knows its own untouchable forms: a body kept only on a far layer (a mod's own interactions, 1000 and more off the visible one) is out of reach of every blow but those aimed at that layer, reckoned for each opponent; a form whose frames are all out there (Drake's T-rex, Magellan's Venom Demon in One Piece GrandWorld) is worth entering for that alone and is fought in up close, its own run or creeping walk steered onto the opponent's line and stopped with its own key, and the guard's way into a form (Magellan's) no longer ends at its first frame. A move that restores HP (Marco's phoenix) is measured with HP missing and used when much lost HP can come back and nothing reaches the fighter meanwhile; the roll out of a run is learned with what follows it (Marco's phoenix flight), and a flight that steers in depth is flown onto the target's line. A grab is worth what follows it (measured) and is no blow to guard; a trap is never set again on an opponent already held (Yamato's wood prison, cast on and on from afar in Naruto 2.4, kept both fighters standing for good) — the held opponent is walked up to and struck. Short of MP with a charge of its own, the fighter backs off far enough to charge rather than waiting at the edge of the opponent's reach. XOI: notes of training by situation (what the opponent was doing, how far it was, the fighter's own HP) and of the spots found better or worse to stand on, used within narrow bounds"},
    {26, "2026-11-01", "No more turning left and right on the spot: a turn round is a step too (a direction key turns the fighter and walks it), so a step back from an enemy much too close goes on until turning round again leaves room, the edges of an enemy's reach and of a fallen enemy's wake-up blows are waited at rather than stepped in and out of, the way out of them once chosen is kept, and walking turns the fighter round at most once every few frames. A wave sent along the ground across the stage (Neji's air palm in Naruto 2.4) is reckoned all the way out, not only in its first frames: its line is walked beside even while the enemy charges MP or is busy for a moment, and a run is not steered back onto the line while a wave flies along it"},
    {25, "2026-11-01", "Gets out of the way with a move of its own when no step does: a teleport, a rush or a leap whose path no blow on its way meets (Kuma of One Piece GrandWorld vanishes and comes down behind the enemy — the keys a mod's jump takes are now learned as moves), taken when the guard cannot hold the blow, or it is a heavy one and MP is left for a strong move after it, or the move strikes back; otherwise the guard, in time; a teleport lands where the game puts it (behind the enemy when the move turns the fighter round). XOI, the level after INSANE!, plays as INSANE! with notes of training shipped with the mod (xoi/notes.txt): each move weighed by what it brought against this opponent in many games, and the opponent's answers to a risky move expected from what training saw"},
    {24, "2026-11-01", "Weighs, rather than forbids, a move the opponent's quicker blow could beat on its way: it is started when what it brings outweighs the answer's damage by how often this opponent has struck such a move first in the match so far (learned as the match goes, from a hopeful start), so a rusher no longer stands off a fighter with long, quick blows (Rock Lee against Neji in Naruto: The Setting Dawn) while a punishing opponent is soon not rushed at"},
    {23, "2026-11-01", "Keeps out of a fallen or just-risen opponent's wake-up blows (its quick moves, however far they reach) until its blink ends, leaving by the quicker way (a few steps in depth, or back out of reach) and waiting off its line rather than beside it; no charging, drinking or weapon pick-up inside them, and a charge stance is left in time to get out; weighs the opponent's quickest counter along a move's own path (a rush carries the fighter into blows that do not reach where it starts) and out of the air on a jump-in; an opponent in a charge stance is known to be free as soon as it can leave it, with the MP the charge brings; the frame a move's spawn appears is counted as a threat; a blow landing as the own blink ends is answered; a trade is struck first only when clearly heavier"},
    {22, "2026-10-31", "Approaches a free opponent whose long blows (a beam, a sweep, a special struck out of the guard) cover the line between them beside that line, in depth, and only steps onto it as its own blows come into reach; an opponent held by a trap (a wood prison) is known to be held and hittable, walked up to and struck — or, with MP short of a strong move and the hold long, MP is charged first and the strong move lands before the hold ends; weapons are worth fewer steps when MP is full"},
    {21, "2026-10-31", "Forms of a mod's own making: a move that leaves an item in the fighter's hand (Luffy's Gear Second, Sanji's Diable Jambe, a Rasengan formed) is a form whose moves, speed, MP burn and worth are learned; it is entered when worth it and safe, fought in with its own moves and runs, and left to run out away from the enemy; a fallen enemy that gets up invulnerable is kept outside arm's reach until it can be hit again"},
    {20, "2026-10-31", "Weapons: walks onto a lying knife, stick, stone or drink when nothing presses, learns what the fighter does with it in hand and swings, throws or drinks accordingly; moves that teleport to the enemy are aimed from where they land; two on one, the second fighter goes round to the other side; a passive opponent is walked up to and struck"},
    {19, "2026-10-31", "Knows the opponent: how often it guards, how pressing it is and whether it flips up out of falls are counted in the match and change the choice of moves, the spacing and the timing; among several enemies the busy and the weak are preferred"},
    {16, "2026-10-31", "Uses the whole kit: jumps in and dashes with air moves, slow specials when the target is held, charges MP, strikes out of the guard, leaves stances in time, flips up or stays down by the blows on their way, never steps into a blow"},
    {15, "2026-10-30", "Stances, defend keys that are moves, moves that start from walking, get-up invulnerability, running, obstacles, no guarding into a break; chosen in Tournament and Battle mode too"},
    {14, "2026-10-30", "INSANE! is born: every fighter's moves learned in a private copy of the match, then prediction of what hits, when the opponent can act, and what each move is worth"},
}
-- Whether the computer player at `index` plays this way: at INSANE! and XOI, unless its mod gave the fighter an
-- AI script of its own (made for that fighter, which then plays as at CRAZY!). (The bench names the player of each
-- fighter: "smart" plays as at INSANE!, "xoi" as at XOI.)
function smart.enabled(state, value, index)
    if value.brain then return value.brain == "smart" or value.brain:sub(1, 3) == "xoi" end
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
local resting_states = {[states.resting_light_item] = true, [states.resting_heavy_item] = true} -- a weapon lying on the ground
local weapon_kinds = {[record_kinds.light_item] = true, [record_kinds.heavy_item] = true,
    [record_kinds.baseball] = true, [record_kinds.drink] = true}
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
local function enter_context(state, me, context, step, heavy)
    step()
    for _ = 1, 120 do
        local fstate = me.record.frame(me.frame).state
        if (fstate == states.standing or (heavy and fstate == states.walking)) and me.y_int == 0 then break end
        step()
    end
    if context == "ground" then
        local fstate = me.record.frame(me.frame).state
        return fstate == states.standing or (heavy and fstate == states.walking)
    end
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
        dvx = area.dvx or 0, kind = area.kind, effect = area.effect or 0, own = own, source = value.record.id}
end

-- One frame of the private copy: the match's frame (base/game/match) without what cannot happen there (weapons
-- falling in, the round's end, input). Hits are worked out only when something could touch the untouchable
-- dummy (attacks of kind 8 and 14 ignore its blink) or when the dummy can be hit; items spawned during a phase
-- take part in its later slots, as in the match.
local homing_kinds = {[attack_kinds.heal] = true, [attack_kinds.obstacle] = true}
local pickup_kinds = {[attack_kinds.pick_up] = true, [attack_kinds.rolling_pickup] = true}
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
    state.sandbox_items = false
    for index = 2, last do
        local value = items[index]
        if value and resting_states[value.record.frame(value.frame).state] then state.sandbox_items = true; break end
    end
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
                    -- A pick-up zone with the attack key down: an item lying in the copy may be taken (combat.detect).
                    if pickup_kinds[area.kind] and value.keys.attack and state.sandbox_items then touching = true; break end
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
local arm -- defined with the weapons below
-- Puts a mode's fighter (an item of its own making in hand, see explore) into the mode's resting frame and lets
-- it settle; then, for a run or air entry, gets it running or into the air the way the mode runs and jumps.
local function enter_mode(state, me, mode, context, step)
    me.frame, me.wait_counter = mode.frame, 0
    set_keys(me, nil)
    step(); step()
    if context == "ground" then return true end
    if context == "air" then
        set_keys(me, {jump = true}); me.previous_keys.jump = false; step()
        set_keys(me, nil)
        for _ = 1, 20 do
            step()
            if me.y_int < 0 then step(); step(); return me.y_int < 0 end
        end
        return false
    end
    -- Running (or whatever the mode does with the run keys): two fresh presses, then the key held.
    local walk = (me.record.movement or {}).walking_speed or 4
    set_keys(me, {right = true}); step()
    set_keys(me, nil); step()
    set_keys(me, {right = true}); step()
    for _ = 1, 12 do
        set_keys(me, {right = true}); me.previous_keys.right = true; step()
        if me.record.frame(me.frame).state == states.running or abs(me.vx) > walk + 2 then return true end
    end
    return false
end

-- MP a mode costs per frame while the fighter only rests in it (Luffy's Gear Second burns MP), or gains (negative).
local function mode_drain(record, mode)
    local state, me = new_sandbox(record)
    arm(state, me, mode.record)
    local function step() sandbox_step(state) end
    if not enter_mode(state, me, mode, "ground", step) then return 0, 0 end
    local before = me.mp
    for _ = 1, 30 do set_keys(me, nil); step() end
    local drain = (before - me.mp) / 30
    -- How fast the mode runs (the run keys from its resting frames, held for a while), and, when the mode has a
    -- run of its own (Gear Second's, which is no running frame of the fighter's and goes on until a key ends
    -- it), the frames of that run (`moving`, from the first direction key on), whether it runs on with no key
    -- held and whether the defend key brings it back to rest.
    local fastest = 0
    local walk = (record.movement or {}).walking_speed or 4
    local moving, own_run = {}, false
    local function note_frame()
        if mode.idle[me.frame] or me.frame == mode.frame then return end
        moving[me.frame] = true
        local fstate = me.record.frame(me.frame).state
        if fstate ~= states.walking and fstate ~= states.running and fstate ~= states.standing then own_run = true end
    end
    me.frame, me.wait_counter = mode.frame, 0
    set_keys(me, nil); step(); step()
    set_keys(me, {right = true}); step(); note_frame()
    set_keys(me, nil); step(); note_frame()
    set_keys(me, {right = true}); step(); note_frame()
    for _ = 1, 20 do
        set_keys(me, {right = true}); me.previous_keys.right = true; step(); note_frame()
        fastest = max(fastest, abs(me.vx))
    end
    local crept = 0
    for _ = 1, 6 do
        local x = me.x_int
        set_keys(me, nil); step()
        if abs(me.vx) > walk + 2 or (own_run and me.x_int ~= x) then note_frame() end
        if me.x_int ~= x then crept = crept + 1 end
    end
    -- (A slow walk of the mode's own counts too, when it goes on by itself: Magellan's Venom Demon in One Piece
    -- GrandWorld creeps on step by step in frames of its own, its speed in no vx, until defend brings it to rest.)
    local creeping = own_run and crept >= 4 and moving[me.frame] == true
    local going = abs(me.vx) > walk + 2 or creeping
    if own_run and (fastest > walk + 2 or creeping) then
        mode.moving = moving
        if going then
            mode.runs_on = true
            set_keys(me, {defend = true}); me.previous_keys.defend = false; step()
            -- (Back in a resting frame, or one of the walking or standing state on the way to them: Drake's T-rex
            -- stops through two of those.)
            for _ = 1, 30 do
                set_keys(me, nil); step()
                local rest_state = me.record.frame(me.frame).state
                if mode.idle[me.frame] or me.frame == mode.frame
                   or ((rest_state == states.standing or rest_state == states.walking) and not moving[me.frame]) then
                    mode.stop_key = "defend"
                    break
                end
            end
        end
    end
    return drain, fastest
end

local function play(record, entry, mp, weapon_record, hp)
    smart.plays = smart.plays + 1
    local state, me = new_sandbox(record)
    if mp then me.mp = mp end
    if hp then me.hp = hp end
    if weapon_record then arm(state, me, weapon_record) end
    local function step()
        if smart.full_sandbox then require("base/game/match").step(state, held_nothing) else sandbox_step(state) end
        if smart.watch then smart.watch(state, me, entry) end
    end
    if entry.mode then
        if not enter_mode(state, me, entry.mode, entry.context, step) then return nil end
    else
        if not enter_context(state, me, entry.context, step, weapon_record and weapon_record.kind == record_kinds.heavy_item) then return nil end
    end
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
    elseif entry.press then
        -- A key pressed as it is (what the game makes of it in this frame: a mode's own attack, jump or guard).
        me.keys[entry.press] = true
        me.previous_keys[entry.press] = false
    else
        me.frame = entry.frame
        me.wait_counter = 0
    end
    local chain_step = 1
    local started = false
    local quiet = 0
    local spawned = {}
    local armed_item = weapon_record and state.items[me.held_item] or nil
    for t = 1, horizon_ticks do
        step()
        set_keys(me, nil)
        -- A chain is not over while a key of it is still to come (a stance between its keys may look free).
        local pending_link = entry.chain and chain_step <= #entry.chain
        -- A chained move: its key, pressed as soon as the fighter is in a frame that takes it there. A pick-up
        -- link presses attack in the frame whose pick-up zone covers an item the move itself laid down (a mod's
        -- way into a stronger form), until the item is in hand.
        local link = entry.chain and entry.chain[chain_step]
        if link and link.key == "pick" then
            local held = me.held_item and state.items[me.held_item]
            if held and held ~= armed_item and spawned[held] then
                chain_step = chain_step + 1
                move.link_tick = t
            elseif me.frame == link.from or (me.frame_at_pass == link.from) then
                set_keys(me, {attack = true})
                me.previous_keys.attack = false
            end
        elseif link and me.record.frame(me.frame).hits[link.key] == link.target then
            set_keys(me, {[link.button] = true})
            me.previous_keys[link.button] = false
            chain_step = chain_step + 1
            move.link_tick = t
        end
        if t == 1 then
            local first = me.frame_at_pass or me.frame
            if (entry.sequence or entry.press) and first == start_frame and me.frame == start_frame then return nil end
            started = true
        end
        move.traj_x[t], move.traj_y[t], move.traj_z[t] = me.x_int - origin.x, me.y_int - origin.y, me.z_int - origin.z
        move.vel_x[t], move.vel_y[t] = me.vx, me.vy
        local at_pass = me.frame_at_pass or me.frame
        move.frames[t] = at_pass
        local frame = me.record.frame(at_pass)
        if frame.state == states.heal_self then move.self_heal = true end
        for _, area in ipairs(frame.interactions) do
            if damaging(area) then add_box(move.boxes, t, me, frame, area, origin, true, me) end
        end
        local objects_active = false
        for index = 2, constants.item_slots - 1 do
            local value = state.items[index]
            if value and value.owner == me.owner and value ~= armed_item then
                spawned[value] = spawned[value] or t
                if weapon_kinds[value.record.kind] and not move.spawned_weapon then move.spawned_weapon = value.record end
                -- (An object born this frame strikes from the next one on; its pass frame is not yet its own.)
                if value.frame_at_pass and spawned[value] < t then
                    local object_frame = value.record.frame(value.frame_at_pass)
                    for _, area in ipairs(object_frame.interactions) do
                        if damaging(area) then
                            add_box(move.boxes, t, value, object_frame, area, origin, false, me)
                            move.boxes[#move.boxes].spawn = spawned[value]
                            objects_active = true
                        elseif area.kind == attack_kinds.held_item and value.holder == me.slot and me.held_item == index then
                            -- A weapon in the hand strikes with the holder's strength entry (base/game/combat
                            -- weapon_strike); it moves with the holder, so its box is the holder's own.
                            local strike = me.record.frame(at_pass).wpoint.attacking
                            local strength = strike > 0 and value.record.data.strengths[strike]
                            if strength and (strength.injury or 0) > 0 then
                                add_box(move.boxes, t, value, object_frame, {x = area.x, y = area.y, width = area.width,
                                    height = area.height, zwidth = strength.zwidth or 0, injury = strength.injury or 0,
                                    fall = strength.fall or 0, bdefend = strength.bdefend or 0, dvx = strength.dvx or 0,
                                    kind = attack_kinds.plain, effect = strength.effect or 0}, origin, true, me)
                            end
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
    -- A teleport to the enemy (state 400) lands beside it: in front, or behind when the move turns the fighter
    -- round first (Kuma). Where, against the enemy (the copy's dummy), in the direction the fighter set off in.
    if move.teleport then
        local after = min(move.teleport + 1, move.length)
        local dummy = state.items[1]
        move.teleport_dx = (move.traj_x[after] or 0) + origin.x - dummy.x_int
        move.teleport_dz = (move.traj_z[after] or 0) + origin.z - dummy.z_int
    end
    -- The move ended with an item of its own making in the fighter's hand: a mode (Luffy's Gear Second, Sanji's
    -- Diable Jambe and Zoro's bandana in One Piece GrandWorld are built on an invisible item picked up), whose
    -- moves are learned separately (explore). Its resting frames are those the fighter goes round in afterwards.
    local held = me.held_item and state.items[me.held_item]
    if held and held ~= armed_item and spawned[held] and me.weapon ~= weapon_none and me.y_int == 0 then
        -- The resting frames: those the fighter goes round in once left alone a while longer (the copy is
        -- stepped on past the move; what it does there is no part of the move).
        local trail = {}
        for _ = 1, 45 do
            set_keys(me, nil)
            step()
            trail[#trail + 1] = me.frame
        end
        local idle = {}
        for k = max(1, #trail - 17), #trail do idle[trail[k]] = true end
        move.mode = {record = held.record, code = me.weapon, frame = me.frame, idle = idle, from = entry}
        -- Free once the resting frames go round (a loop of state 15 frames never counts as free otherwise).
        if move.ready == horizon_ticks then
            local seen = {}
            for t = (move.link_tick or 1) + 1, move.length do
                local id = move.frames[t]
                if id and seen[id] then move.ready = t; break end
                if id then seen[id] = true end
            end
        end
    end
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

-- The keys a mode's fighter is tried with: its D-combos as its resting frame names them, attack, jump and defend
-- pressed as they are (the mode's own moves hang on them), the same from its run and in the air, and what the
-- item in its hand does as a weapon.
local function mode_entries(data, mode)
    local entries = {}
    local held = {[mode.code] = true}
    local frame = data.frames[mode.frame]
    for _, spec in ipairs(sequence_fields) do
        local target = frame and frame.hits[spec.field] or 0
        if target ~= 0 then
            entries[#entries + 1] = {context = "ground", sequence = spec.sequence, field = spec.field, frame = target, mode = mode, held = held}
        end
    end
    for _, press in ipairs({"attack", "jump", "defend"}) do
        entries[#entries + 1] = {context = "ground", press = press, basic = "mode_" .. press, mode = mode, held = held}
    end
    entries[#entries + 1] = {context = "run", press = "attack", basic = "mode_run_attack", mode = mode, held = held}
    entries[#entries + 1] = {context = "run", press = "jump", basic = "mode_run_jump", mode = mode, held = held}
    entries[#entries + 1] = {context = "air", press = "attack", basic = "mode_jump_attack", mode = mode, held = held}
    -- (Not the item's own weapon frames, a swing or a throw, set directly: what the keys do in the mode is what
    -- the fighter can do, and a frame set directly may be one no key reaches, or one the keys reach at a cost.)
    return entries
end

-- Learns a fighter's moves (mode == nil), or the moves of one of its modes (an item of its own making in hand:
-- play), into `analysis`: every entry is played in the private copy, what the keys pressed during a move continue
-- into is played too (chains, pick-ups), and the moves are indexed from `first_index`.
local function explore(record, analysis, mode, first_index)
    local data = record.data
    local saved_table, saved_index, saved_sequence = engine.random_state()
    local runtime = require("base/game/ai_scripts").runtime
    local saved_self_o, saved_self_n = runtime.self.o, runtime.self.n
    local saved_target_o, saved_target_n = runtime.target.o, runtime.target.n
    local entries, seen, deferred = {}, {}, {}
    local cap = mode and 40 or max_moves
    local function want(entry)
        local key = entry.context .. ":" .. tostring(entry.sequence and ("s" .. entry.sequence .. ":" .. entry.frame) or entry.press or entry.frame)
        if entry.parent then key = key .. ":from" .. entry.from end
        for _, link in ipairs(entry.chain or {}) do key = key .. ">" .. link.from .. link.button end
        if seen[key] or #entries >= cap then return end
        seen[key] = true
        -- What follows the super punch (only thrown into a broken guard) is learned last, when there is room.
        if entry.basic == "super_punch" and entry.chain then deferred[#deferred + 1] = entry return end
        entries[#entries + 1] = entry
    end
    if mode then
        for _, entry in ipairs(mode_entries(data, mode)) do want(entry) end
    else
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
        -- Defend out of a run rolls (frame 102); a mod's fighter may go on from the roll into a form of its own
        -- (Marco of One Piece GrandWorld takes off as a phoenix with jump): explored for the keys its frames take.
        if data.frames[frames.rowing + 2] then want({context = "run", press = "defend", basic = "roll"}) end
        -- A mod's move out of the jump's own frames (Kuma of One Piece GrandWorld vanishes and comes down behind
        -- the enemy with defend pressed as he jumps): the jump is explored as a move for the keys they take.
        for frame_id = frames.jump, frames.jump + 4 do
            local frame = data.frames[frame_id]
            if frame and (frame.hits.a > 0 or frame.hits.j > 0 or frame.hits.d > 0) then
                want({context = "ground", press = "jump", basic = "jump"})
                break
            end
        end
    end
    local weapon_record = mode and mode.record or nil
    local index = 1
    while index <= #entries do
        local entry = entries[index]
        engine.set_random_state(random_table(), 0, 0)
        local ok, move = pcall(play, record, entry, nil, weapon_record)
        if ok and move and not move.first and move.mp == 0 and not move.transform and not move.teleport and not move.mode then
            -- Nothing seen with MP full: a move that fills MP (a chakra charge in Naruto: The Setting Dawn) only
            -- shows when there is room for it.
            engine.set_random_state(random_table(), 0, 0)
            local ok_again, again = pcall(play, record, entry, 150, weapon_record)
            if ok_again and again and again.mp < 0 then move = again end
        end
        -- Nor with HP full: a move whose frames restore HP (state 1700: Marco's phoenix in One Piece GrandWorld)
        -- only shows it when there is HP to restore.
        if ok and move and not move.first and move.self_heal and move.hp <= 0 and not move.mode and not move.transform then
            engine.set_random_state(random_table(), 0, 0)
            local ok_again, again = pcall(play, record, entry, nil, weapon_record, 150)
            if ok_again and again and again.hp < -20 then
                again.heal = -again.hp
                move = again
            end
        end
        -- In a mode, a key that changes nothing (the fighter goes on round its resting frames) is no move.
        if ok and move and mode and not move.first and not move.mode then
            local moved = false
            for t = 1, move.length do
                local id = move.frames[t]
                if id and not mode.idle[id] then moved = true; break end
            end
            if not moved then move = nil end
        end
        local signature
        -- The guard itself (the defend key leading to defending frames at once) is no move, but the keys its
        -- frames take are explored below: a mod's fighter may strike out of its guard (Sanji of One Piece
        -- GrandWorld). Otherwise the defend key is one of the fighter's moves (Blackbeard's dark field), kept as such.
        local guard_move
        if ok and move and (entry.basic == "defend" or (entry.press == "defend" and entry.basic ~= "roll")) and not entry.chain then
            local guards = false
            for t = 1, min(3, move.length) do
                local id = move.frames[t]
                if id and record.frame(id).state == states.defending then guards = true end
            end
            if not mode then analysis.guard = guards end
            if guards then guard_move, move = move, nil end
        end
        -- (The jump itself is no move either, only the way to the keys its frames take.)
        if ok and move and entry.basic == "jump" and not entry.chain then guard_move, move = move, nil end
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
            -- What a catch of its own brings: a grab's box does no damage itself, what follows it does (Neji's punch
            -- in Naruto 2.4, continued with jump, dashes and grabs, and the 64 palms that follow take 400 HP) —
            -- measured on a fighter standing where the grab first reaches.
            for _, box in ipairs(move.boxes) do
                if box.own and box.kind == attack_kinds.catch then
                    engine.set_random_state(random_table(), 0, 0)
                    local measured_ok, measured = pcall(measure_hit, record, entry,
                        floor((box.x1 + box.x2) / 2) + (move.traj_x[box.t] or 0), box.z + (move.traj_z[box.t] or 0),
                        min(box.t + 70, 150))
                    if measured_ok and measured > 45 then move.catch_damage = measured end
                    break
                end
            end
            if mode then
                move.weapon = mode.code
                if move.hp < 0 then move.heal = -move.hp end
                -- The mode's own burn is not the move's cost.
                if (mode.drain or 0) > 0 then
                    local resting = 0
                    for t = 1, move.length do if mode.idle[move.frames[t]] then resting = resting + 1 end end
                    move.mp = max(0, move.mp - floor(mode.drain * resting + 0.5))
                end
            end
            move.index = first_index + #analysis.moves
            analysis.moves[#analysis.moves + 1] = move
            if entry.chain then
                local part = continuation(data, move)
                if part then
                    if mode then part.weapon = mode.code end
                    part.index = first_index + #analysis.moves
                    analysis.moves[#analysis.moves + 1] = part
                end
            end
            -- (A move out of the jump is known by its frames after the key: a fighter in its jump frames is only
            -- jumping, as far as anyone can tell.)
            local from_t = entry.basic == "jump" and (move.link_tick or 0) + 1 or 1
            for t = from_t, move.length do
                local frame_id = move.frames[t]
                if frame_id and not analysis.frames[frame_id] then analysis.frames[frame_id] = {move = move, t = t} end
            end
        end
        local explored = move or guard_move
        if ok and explored then
            -- Pressing attack, jump or defend in one of its frames continues into another move: that move from
            -- the frame (when the fighter is already there) and the whole sequence from this move's start. A frame
            -- with a pick-up zone, in a move that laid down an item, is tried with attack as well (pick-up).
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
                                    basic = entry.basic, press = entry.press, mode = entry.mode, held = entry.held, chain = chain})
                            end
                        end
                        if explored.spawned_weapon and not explored.mode and not listed["pick"] then
                            local picks = false
                            for _, area in ipairs(frame.interactions) do
                                if area.kind == attack_kinds.pick_up then picks = true end
                            end
                            if picks then
                                listed["pick"] = true
                                local chain = {}
                                for position, link in ipairs(entry.chain or {}) do chain[position] = link end
                                chain[#chain + 1] = {from = frame_id, button = "attack", key = "pick",
                                    target = explored.spawned_weapon.kind == record_kinds.heavy_item and frames.picking_heavy or frames.picking_light}
                                want({context = entry.context, sequence = entry.sequence, field = entry.field, frame = entry.frame,
                                    basic = entry.basic, press = entry.press, mode = entry.mode, held = entry.held, chain = chain})
                            end
                        end
                    end
                end
            end
        end
        index = index + 1
        if index > #entries and #deferred > 0 then
            for _, entry in ipairs(deferred) do
                if #entries < cap then entries[#entries + 1] = entry end
            end
            deferred = {}
        end
    end
    engine.set_random_state(saved_table, saved_index, saved_sequence)
    runtime.self.o, runtime.self.n = saved_self_o, saved_self_n
    runtime.target.o, runtime.target.n = saved_target_o, saved_target_n
    analysis.entries = (analysis.entries or 0) + #entries
end

local function analyze(record)
    local data = record.data
    local found = analyses[data]
    if found then return found end
    local analysis = {moves = {}, frames = {}, lock = {}, modes = {}}
    analyses[data] = analysis
    if record.kind ~= record_kinds.character then return analysis end
    explore(record, analysis, nil, 1)
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
        -- A move that puts the fighter into a mode: the mode is learned when the fighter is first seen in it
        -- (armed_analysis), and remembered here by the item it holds then.
        if move.mode and not analysis.modes[move.mode.record.data] then
            move.mode.start = move
            analysis.modes[move.mode.record.data] = move.mode
        end
    end
    return analysis
end
smart.analyze = analyze

---------------------------------------------------------------------------------------------------------------
-- Weapons. What a fighter does with one in hand is learned like its moves, in a copy where it holds the weapon:
-- the swing, the jumping, running and dashing strikes, the throw, the drink. The weapon's own frames carry the
-- blows (its kind-5 interactions and the holder's strength entries), so the same play() sees them.
---------------------------------------------------------------------------------------------------------------

-- The holder code a picked-up item gives (base/game/combat pick_up): knife and boomerang have their own.
local function holder_code(weapon_record)
    if weapon_record.kind == record_kinds.light_item then
        local id = weapon_record.id
        if id == constants.item_ids.knife or id == constants.item_ids.boomerang then return constants.weapon_holder_codes.knife_or_boomerang end
        return record_kinds.light_item
    end
    return weapon_record.kind
end
-- Puts a weapon into the copy's fighter's hand (slot 2 of the copy), as a pick-up does.
arm = function(state, me, weapon_record)
    local weapon = item.create(weapon_record)
    weapon.drop_counter = weapon_record.data.weapon and weapon_record.data.weapon.hp or 0
    weapon.x_int, weapon.y_int, weapon.z_int = me.x_int, 0, me.z_int
    weapon.x, weapon.y, weapon.z = me.x_int, 0.0, me.z_int
    weapon.vx, weapon.vy, weapon.vz = 0.0, 0.0, 0.0
    weapon.slot, weapon.human = 2, false
    state.items[2] = weapon
    local code = holder_code(weapon_record)
    me.weapon, me.held_item = code, 2
    weapon.weapon, weapon.holder, weapon.owner, weapon.team = -code, me.slot, me.slot, me.team
end

local light_codes = {[record_kinds.light_item] = true, [constants.weapon_holder_codes.knife_or_boomerang] = true}
-- The moves a weapon gives its holder: entries by the code the weapon is held with.
local function weapon_entries(code)
    if light_codes[code] then
        local entries = {
            {context = "ground", frame = frames.weapon_attack, basic = "weapon_attack", held = light_codes},
            {context = "ground", frame = frames.weapon_attack + 5, basic = "weapon_attack2", held = light_codes},
            {context = "air", frame = frames.jump_weapon_attack, basic = "weapon_jump", held = light_codes},
            {context = "run", frame = frames.run_weapon_attack, basic = "weapon_run", held = light_codes},
            {context = "dash", frame = frames.dash_weapon_attack, basic = "weapon_dash", held = light_codes},
            {context = "air", frame = frames.jump_light_weapon_throw, basic = "weapon_jump_throw", held = light_codes, direction = true},
        }
        -- A knife or boomerang is thrown from standing with a direction; a stick or hoe only out of a run.
        if code == constants.weapon_holder_codes.knife_or_boomerang then
            entries[#entries + 1] = {context = "ground", frame = frames.light_weapon_throw, basic = "weapon_throw",
                held = {[code] = true}, direction = true}
        else
            entries[#entries + 1] = {context = "run", frame = frames.light_weapon_throw, basic = "weapon_run_throw",
                held = {[code] = true}, direction = true}
        end
        return entries
    end
    if code == record_kinds.heavy_item then
        return {{context = "ground", frame = frames.heavy_weapon_throw, basic = "heavy_throw", held = {[code] = true}}}
    end
    if code == record_kinds.baseball then
        return {{context = "ground", frame = frames.light_weapon_throw, basic = "weapon_throw", held = {[code] = true}},
            {context = "air", frame = frames.jump_light_weapon_throw, basic = "weapon_jump_throw", held = {[code] = true}, direction = true}}
    end
    if code == record_kinds.drink then
        return {{context = "ground", frame = frames.drinking, basic = "drink", held = {[code] = true}},
            {context = "run", frame = frames.light_weapon_throw, basic = "weapon_run_throw", held = {[code] = true}, direction = true},
            {context = "air", frame = frames.jump_light_weapon_throw, basic = "weapon_jump_throw", held = {[code] = true}, direction = true}}
    end
    return {}
end

local weapon_analyses = {} -- [record.data][weapon_record.data]
-- What `record` does with `weapon_record` in hand: moves (indexed after the fighter's own) and their frames.
local function armed_analysis(record, weapon_record, first_index)
    local by_fighter = weapon_analyses[record.data]
    if not by_fighter then by_fighter = {}; weapon_analyses[record.data] = by_fighter end
    local found = by_fighter[weapon_record.data]
    if found then return found end
    local armed = {moves = {}, frames = {}, code = holder_code(weapon_record), weapon = weapon_record}
    by_fighter[weapon_record.data] = armed
    -- An item the fighter makes for itself (a mode, see play): what it does holding it is learned from the mode's
    -- resting frames, with all its keys.
    local mode = analyze(record).modes[weapon_record.data]
    if mode then
        armed.mode = mode
        local saved_table, saved_index, saved_sequence = engine.random_state()
        engine.set_random_state(random_table(), 0, 0)
        local ok, drain, run_speed = pcall(mode_drain, record, mode)
        engine.set_random_state(saved_table, saved_index, saved_sequence)
        mode.drain = ok and drain or 0
        mode.run_speed = ok and run_speed or 0
        explore(record, armed, mode, first_index)
        armed.chains = {}
        local best = 0
        for _, move in ipairs(armed.moves) do
            best = max(best, move.damage or 0)
            if move.entry.parent then
                armed.chains[move.entry.from] = armed.chains[move.entry.from] or {}
                local list = armed.chains[move.entry.from]
                list[#list + 1] = move
            end
        end
        mode.best_damage = best
        -- What the mode is worth: its best cheap, quick blow against the fighter's own (damage per frame to land).
        local function quick_worth(moves)
            local worth = 0
            for _, move in ipairs(moves) do
                if move.first and move.mp <= 30 and move.first <= 24 and not move.entry.parent then
                    worth = max(worth, (move.damage or 0) / max(move.first, 6))
                end
            end
            return worth
        end
        local function strong_worth(moves)
            local worth = 0
            for _, move in ipairs(moves) do
                if move.first and move.first <= 30 and move.mp <= 200 then worth = max(worth, move.damage or 0) end
            end
            return worth
        end
        local base = analyze(record).moves
        local function ratio(a, b) if b > 0 then return a / b end return a > 0 and 9 or 0 end
        mode.worth = max(ratio(quick_worth(armed.moves), quick_worth(base)), ratio(strong_worth(armed.moves), strong_worth(base)) * 0.9)
        -- Speed counts too (Gear Second runs three times as fast): the mode's run against the fighter's.
        local run = (record.movement or {}).running_speed or 10
        if mode.run_speed and run > 0 then mode.worth = max(mode.worth, mode.run_speed / run * 0.6) end
        return armed
    end
    local saved_table, saved_index, saved_sequence = engine.random_state()
    local runtime = require("base/game/ai_scripts").runtime
    local saved_self_o, saved_self_n = runtime.self.o, runtime.self.n
    local saved_target_o, saved_target_n = runtime.target.o, runtime.target.n
    for _, entry in ipairs(weapon_entries(armed.code)) do
        engine.set_random_state(random_table(), 0, 0)
        local ok, move = pcall(play, record, entry, nil, weapon_record)
        if ok and move then
            if move.hp < 0 then move.heal = -move.hp end
            if move.mp < 0 and not move.first then move.charge = -move.mp end
            move.weapon = armed.code
            move.index = first_index + #armed.moves
            armed.moves[#armed.moves + 1] = move
            for t = 1, move.length do
                local frame_id = move.frames[t]
                if frame_id and not armed.frames[frame_id] then armed.frames[frame_id] = {move = move, t = t} end
            end
        end
    end
    engine.set_random_state(saved_table, saved_index, saved_sequence)
    runtime.self.o, runtime.self.n = saved_self_o, saved_self_n
    runtime.target.o, runtime.target.n = saved_target_o, saved_target_n
    return armed
end

-- A fighter's analysis as it stands: its own when its hands are empty, else its own moves together with the
-- weapon's (a view, cached per weapon; the caches of reach, zones and range are the view's own).
local function view_of(context, value)
    local analysis = analyze(value.record)
    local items = context.state.items
    local held = value.held_item and items[value.held_item]
    if value.weapon == weapon_none or value.weapon < 0 or not held or items[held.holder] ~= value then return analysis end
    analysis.views = analysis.views or {}
    local view = analysis.views[held.record.data]
    if view then return view end
    local armed = armed_analysis(value.record, held.record, #analysis.moves + 1)
    analysis.extra = analysis.extra or {}
    view = {moves = {}, frames = {}, lock = analysis.lock, extra = analysis.extra, chains = analysis.chains,
        guard = analysis.guard, punch = analysis.punch, punch2 = analysis.punch2, by_sequence = analysis.by_sequence,
        entries = analysis.entries, armed = armed, modes = analysis.modes}
    for index, move in ipairs(analysis.moves) do view.moves[index] = move end
    for _, move in ipairs(armed.moves) do view.moves[#view.moves + 1] = move end
    -- A mode's follow-ups (what its keys continue into) join the fighter's own.
    if armed.chains then
        view.chains = {}
        for from, list in pairs(analysis.chains) do view.chains[from] = list end
        for from, list in pairs(armed.chains) do
            local merged = {}
            for _, move in ipairs(view.chains[from] or {}) do merged[#merged + 1] = move end
            for _, move in ipairs(list) do merged[#merged + 1] = move end
            view.chains[from] = merged
        end
    end
    for frame_id, where in pairs(analysis.frames) do view.frames[frame_id] = where end
    for frame_id, where in pairs(armed.frames) do view.frames[frame_id] = where end
    analysis.views[held.record.data] = view
    return view
end
smart.view_of = view_of

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

-- Frames until a fighter in a stance could be free, pressing its exit key in the first frame of the stance that
-- takes it (the stance's frames go round: the one it is in, then the next ones in turn); nil for a frame that is
-- not in a stance. An opponent charging MP is free this soon, not at the end of the charge it was seen in.
local function stance_leave(record, analysis, value)
    local frame_id = value.frame
    local current, seen = frame_id, {}
    for _ = 1, 60 do
        local frame = record.frames[current]
        if not frame or free_states[frame.state] then return nil end
        if seen[current] then break end
        seen[current] = true
        local next_id = frame.next
        if next_id == 0 or next_id == 999 or next_id >= 1000 then return nil end
        if next_id < 0 then next_id = -next_id end
        current = next_id
    end
    if not seen[current] then return nil end
    local best, elapsed, visited = nil, 0, {}
    current = frame_id
    for _ = 1, 60 do
        local frame = record.frames[current]
        if not frame or visited[current] then break end
        visited[current] = true
        for _, key in ipairs({"d", "a", "j"}) do
            local target = frame.hits[key]
            if target == 999 then
                if not best or elapsed < best then best = elapsed end
            elseif target > 0 and record.frames[target] then
                local total = elapsed + lock_of(record, analysis, target)
                if not best or total < best then best = total end
            end
        end
        local left = frame.wait + 1 - (current == frame_id and value.wait_counter or 0)
        elapsed = elapsed + max(left, 0)
        local next_id = frame.next
        if next_id == 0 or next_id == 999 or next_id >= 1000 then break end
        if next_id < 0 then next_id = -next_id end
        current = next_id
    end
    return best
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
-- (`moving`: the victim is on its way somewhere, victim_at(k) says where: no quick reject by where it stands.)
local function move_hits(attacker, face, move, from_t, victim, vframe, victim_at, horizon, moving)
    local boxes = move.boxes
    local frame_at = type(vframe) == "function" and vframe or nil
    if #boxes == 0 or (not frame_at and #vframe.bodies == 0) then return nil end
    local traj_x, traj_y, traj_z = move.traj_x, move.traj_y, move.traj_z
    local ax, ay, az = attacker.x_int, attacker.y_int, attacker.z_int
    local nx, ny, nz = traj_x[from_t] or 0, traj_y[from_t] or 0, traj_z[from_t] or 0
    local dvx = attacker.vx * face - (move.vel_x[from_t] or 0)
    local dvy = attacker.vy - (move.vel_y[from_t] or 0)
    local airborne = attacker.y_int < 0
    -- A move that teleports to the enemy (state 400) goes on from beside the victim, at its depth, on the ground,
    -- still (base/game/frame_rules; 120 in front of it, or behind when the move turned the fighter round first:
    -- as learned): the boxes after that moment are placed from there.
    local tp = move.teleport
    local tp_dx, tp_dy, tp_dz
    if tp and tp > from_t then
        local px, _, pz = victim_at(tp - from_t)
        tp_dx = (px + (move.teleport_dx or -120) * face - ax) * face - ((traj_x[tp] or 0) - nx)
        tp_dy = -ay - ((traj_y[tp] or 0) - ny)
        tp_dz = (pz + (move.teleport_dz or 1) - az) - ((traj_z[tp] or 0) - nz)
    end
    if from_t == 0 and not tp and not moving then
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
        -- (What the move spawns counts from its record until it is in the world — it spawns after the frame's
        -- control, so at the spawning step itself too; from the next, its own frames are followed instead.)
        if k >= (from_t > 0 and 0 or 1) and (box.own or box.spawn >= from_t) then
            local ox, oy, oz
            if box.own then
                if tp_dx and t >= tp then
                    ox, oy, oz = traj_x[t] - nx + tp_dx, traj_y[t] - ny + tp_dy, traj_z[t] - nz + tp_dz
                else
                    ox = traj_x[t] - nx + drift(dvx, k, airborne)
                    oy = traj_y[t] - ny + (airborne and dvy * k or 0)
                    oz = traj_z[t] - nz
                end
            else
                local ks = box.spawn - from_t
                if tp_dx and box.spawn >= tp then
                    ox, oy, oz = -nx + tp_dx, -ny + tp_dy, -nz + tp_dz
                else
                    ox = -nx + drift(dvx, ks, airborne)
                    oy = -ny + (airborne and dvy * ks or 0)
                    oz = -nz
                end
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
            elseif abs(value.x_int - sx) < 1200 and abs(value.z_int - sz) < 300
                   and not resting_states[value.record.frame(value.frame).state] and not (value.weapon < 0) then
                -- Something flying (not a weapon lying on the ground or held in a hand: a held one strikes as
                -- its holder's move): the attack boxes of its frames to come, carried along by its speed.
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

-- Helpers of the positioning below, gathered in one table (smart.control is near Lua's limit of upvalues).
local positioning = {}

-- Something flying at `self` along a line close to its own (a wave sent along the ground): the depth of that
-- line, or nil. A step toward it waits until it has gone by — earliest_threat's frame-by-frame forecast of a
-- sideways step can come out a few pixels short, and a fast wave clips a fighter at the very edge of its depth.
function positioning.flying_line(state, index, self)
    local best_z, best_gap
    for other = 0, constants.item_slots - 1 do
        local value = state.items[other]
        if value and other ~= index and value.record.kind == record_kinds.ball and value.hp > 0 and hostile(state, self, value) then
            local gap = self.x_int - value.x_int
            if abs(gap) < 700 and value.vx ~= 0 and (value.vx > 0) == (gap > 0) then
                local zw = 0
                for _, area in ipairs(value.record.frame(value.frame).interactions) do
                    if damaging(area) then zw = max(zw, area.zwidth ~= 0 and area.zwidth or default_zwidth) end
                end
                if zw > 0 and abs(value.z_int - self.z_int) < zw + 20 and (not best_gap or abs(gap) < best_gap) then
                    best_z, best_gap = value.z_int, abs(gap)
                end
            end
        end
    end
    return best_z
end

-- Far layers. A mod keeps bodies (and blows) far above or below where anything is seen, 1000 and more off, for
-- interactions of its own; a frame whose bodies are all out there, or which has none, is out of reach of every
-- blow but those aimed at the same layer: Drake's T-rex, Magellan's Venom Demon and Marco's phoenix in One Piece
-- GrandWorld are struck by almost nothing. The layers a fighter's blows (and what it throws) reach out there:
-- {top, bottom} pairs, relative to where it stands, with a margin.
function positioning.far_reach(analysis)
    local found = analysis.far_reach
    if found then return found end
    found = {}
    local seen = {}
    for _, move in ipairs(analysis.moves) do
        for _, box in ipairs(move.boxes) do
            if box.y1 >= 900 or box.y2 <= -900 then
                local key = floor(box.y1 / 100)
                if not seen[key] then
                    seen[key] = true
                    found[#found + 1] = {box.y1 - 300, box.y2 + 300}
                end
            end
        end
    end
    analysis.far_reach = found
    return found
end
-- Whether a blow of a fighter whose far layers are `far` (far_reach) can touch a body of `frame`.
function positioning.reachable(frame, far)
    local bodies = frame.bodies
    for index = 1, #bodies do
        local body = bodies[index]
        if abs(body.y) < 1000 then return true end
        local top = body.y - frame.center_y
        for k = 1, #far do
            local layer = far[k]
            if top < layer[2] and top + body.height > layer[1] then return true end
        end
    end
    return false
end
-- Whether a mode's resting and moving frames (play, mode_drain) are all out of reach of such blows.
function positioning.mode_shielded(record, mode, far)
    for id in pairs(mode.idle) do
        if positioning.reachable(record.frame(id), far) then return false end
    end
    for id in pairs(mode.moving or {}) do
        if positioning.reachable(record.frame(id), far) then return false end
    end
    return true
end
-- Whether a fighter has a move that fills MP (a chakra charge in Naruto: The Setting Dawn).
function positioning.can_charge(analysis)
    if analysis.can_charge ~= nil then return analysis.can_charge end
    local found = false
    for _, move in ipairs(analysis.moves) do
        if move.charge and not move.entry.parent then found = true; break end
    end
    analysis.can_charge = found
    return found
end
-- How far a mode's own quickest blow from rest reaches (the far end of its first strike): what a fighter out of
-- the target's reach in it closes to.
function positioning.mode_reach(view, mode)
    if mode.reach then return mode.reach end
    local best_first, reach
    for _, move in ipairs(view.moves) do
        local entry = move.entry
        if entry.mode == mode and move.first and not entry.parent and entry.context == "ground" then
            local far_x
            for _, box in ipairs(move.boxes) do
                if box.t == move.first then
                    local x2 = box.x2 + (box.own and (move.traj_x[box.t] or 0) or 0)
                    far_x = max(far_x or x2, x2)
                end
            end
            if far_x and far_x > 0 and (not best_first or move.first < best_first) then best_first, reach = move.first, far_x end
        end
    end
    mode.reach = reach or 60
    return mode.reach
end
-- Whether every frame of a move is, from frame `from_t` of it on until it is over (free again).
function positioning.move_shielded(record, move, far, from_t)
    for t = from_t or 1, min(move.ready - 1, move.length) do
        local id = move.frames[t]
        if id and positioning.reachable(record.frame(id), far) then return false end
    end
    return true
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
    if entry.mode then
        -- A mode's move: the mode's item in hand, from the mode's resting frames (or standing, walking, running in
        -- it, in the air for its air moves).
        local memory = self.smart_memory
        -- (The mode's item by its data: the match and the copies it was learned in each parse their own records.)
        if not memory or not memory.held_record or memory.held_record.data ~= entry.mode.record.data then return false end
        if entry.parent then return frame.hits[entry.key] == entry.frame end
        if entry.sequence then return frame.hits[entry.field] == entry.frame end
        local resting = entry.mode.idle[self.frame] or fstate == states.standing or fstate == states.walking
        if entry.context == "air" then return self.y_int < 0 end
        if entry.context == "run" then
            if self.y_int ~= 0 then return false end
            -- (Out of the mode's own run, in frames of the attacking state: where the key leads to the same frame.)
            local moving = entry.mode.moving
            if moving and moving[self.frame] and entry.press and move.frames[1] ~= nil
               and frame.hits[entry.press == "attack" and "a" or (entry.press == "jump" and "j" or "d")] == move.frames[1] then
                return true
            end
            return fstate == states.running
                or (not resting and fstate ~= states.attacking and abs(self.vx) > ((self.record.movement or {}).walking_speed or 4) + 2)
        end
        if entry.context == "dash" then return fstate == states.dashing end
        if entry.press then
            if self.y_int ~= 0 then return false end
            if resting then return true end
            -- (The same key out of the mode's own walk or run, where it leads to the same frame.)
            local moving = entry.mode.moving
            return moving ~= nil and moving[self.frame] == true and move.frames[1] ~= nil
                and frame.hits[entry.press == "attack" and "a" or (entry.press == "jump" and "j" or "d")] == move.frames[1]
        end
        -- The item's own weapon moves (a throw, a swing) start as a weapon's.
    end
    if entry.held then
        -- A weapon's move: the weapon in hand, and the stance the move starts from.
        if not entry.held[self.weapon] then return false end
        local basic = entry.basic
        if basic == "weapon_jump" or basic == "weapon_jump_throw" then return fstate == states.jumping and self.y_int < 0 end
        if basic == "weapon_run" or basic == "weapon_run_throw" then return fstate == states.running end
        if basic == "weapon_dash" then return fstate == states.dashing end
        return fstate == states.standing or fstate == states.walking
    end
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
    if basic == "jump" then return (fstate == states.standing or fstate == states.walking) and self.y_int == 0 end
    if basic == "roll" then return fstate == states.running and self.y_int == 0 end
    return false
end

-- Moves that turn toward the target as they start: D>A / D>J choose the side, a punch turns with the direction key.
local function turns(move)
    local entry = move.entry
    return entry.sequence == combo.right_attack or entry.sequence == combo.right_jump or entry.basic == "attack"
        or entry.basic == "weapon_attack" or entry.direction == true
end

-- (`t`, `score`: when the move should land and what it is expected to bring, for a move chosen as an attack; `t`
-- alone for a follow-up. The bench's hook sees them.)
local function start(self, move, target, t, score)
    if smart.on_start then smart.on_start(self, move, t, score) end
    local entry = move.entry
    if entry.parent then
        fresh(self, entry.button)
        return
    end
    if entry.press and not entry.chain then
        -- A mode's key, pressed as it is; attack turns toward the target as a punch does.
        if entry.press == "attack" and target then
            if target.x_int > self.x_int then press(self, "right") elseif target.x_int < self.x_int then press(self, "left") end
        end
        fresh(self, entry.press)
        return
    end
    if entry.press and entry.chain then
        local memory = self.smart_memory
        memory.chain, memory.chain_step, memory.chain_age = entry.chain, 1, 0
        if entry.press == "attack" and target then
            if target.x_int > self.x_int then press(self, "right") elseif target.x_int < self.x_int then press(self, "left") end
        end
        fresh(self, entry.press)
        return
    end
    if entry.held then
        -- A weapon's move: attack, with the direction toward the target where the move takes one (throws) or
        -- turns with it (the swing from standing).
        if target and (entry.direction or entry.basic == "weapon_attack") then
            if target.x_int > self.x_int then press(self, "right") elseif target.x_int < self.x_int then press(self, "left") end
        end
        fresh(self, "attack")
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
    if box.kind == attack_kinds.catch then
        -- A catch is worth what follows it (measured, see explore; a grab's punches and throw at least) — and
        -- nothing on a target already held: a trap set again only holds it on, what the trap does to a fighter it
        -- caught itself never comes, and the two stood there for good (Yamato's wood prison in Naruto: The Setting
        -- Dawn, cast again and again from afar), when the target held is there to be struck.
        if target.record.frame(target.frame).state == states.caught then return 0 end
        value = max(value, move and move.catch_damage or 45, 45)
    end
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

-- MP a frame that a fighter's charge (a chakra charge) brings in, averaged over the play it was seen in; 0 for a
-- fighter without one.
local function charge_rate(analysis)
    if analysis.charge_rate then return analysis.charge_rate end
    local rate = 0
    for _, move in ipairs(analysis.moves) do
        if move.charge then rate = max(rate, move.charge / max(move.length, 1)) end
    end
    analysis.charge_rate = rate
    return rate
end

-- The fastest hit the enemy `other` could land on `self`: frames from now and its damage, or nil. A free enemy
-- starts a move now (facing `self`); one held for `lock` frames starts it then, from standing, unless a follow-up
-- its move's coming frames take (a punch that goes on into the next) lands sooner.
-- With `plan` (k -> dx, dy, dz) and `frames_at` (k -> frame), the fighter is where a move of its own takes it k
-- frames from now rather than where it stands: a rush carries it into blows that do not reach where it stands.
local charging_proxy = {}
local function enemy_reach(context, other, self, horizon, lock, plan, frames_at)
    local oframe = other.record.frame(other.frame)
    local ostate = oframe.state
    if lock > 0 then oframe, ostate = other.record.frame(frames.standing), states.standing end
    local analysis = context.analysis_of(other)
    local face = self.x_int >= other.x_int and 1 or -1
    local self_frame = self.record.frame(self.frame)
    local sx, sy, sz = self.x_int, self.y_int, self.z_int
    local offset = 0
    local function self_at(k)
        if plan then
            local dx, dy, dz = plan(k + offset)
            return sx + dx, sy + dy, sz + dz
        end
        return sx, sy, sz
    end
    local vframe = self_frame
    if frames_at then vframe = function(k) return frames_at(k + offset) end end
    -- An enemy charging MP has, by the time it is free, the MP its charge brings in meanwhile: its moves are
    -- judged with that MP.
    local starter = other
    local where = context.target_where
    if lock > 0 and where and where.value == other and where.move.charge then
        local gain = charge_rate(analysis) * lock
        if gain > 0 then
            -- (A stand-in with that MP and what else can_start reads.)
            local proxy = charging_proxy
            proxy.mp, proxy.hp, proxy.weapon, proxy.smart_memory, proxy.transform = other.mp + trunc(gain), other.hp, other.weapon, other.smart_memory, other.transform
            proxy.defend_lock, proxy.super_window, proxy.y_int, proxy.vx, proxy.record, proxy.frame = other.defend_lock, other.super_window, other.y_int, other.vx, other.record, other.frame
            starter = proxy
        end
    end
    offset = lock
    local best, damage
    -- A free enemy on its feet may first step in (its walking speed, a few frames) and then strike.
    local steps = (lock == 0 and (ostate == states.standing or ostate == states.walking)) and 3 or 0
    local walk = steps > 0 and ((other.record.movement or {}).walking_speed or 4) or 0
    local virtual = steps > 0 and {x_int = other.x_int, y_int = other.y_int, z_int = other.z_int, vx = 0, vy = 0, facing = other.facing} or nil
    for _, move in ipairs(analysis.moves) do
        if move.first and move.first <= horizon and (not best or move.first < best) and can_start(starter, oframe, ostate, move) then
            local own_face = turns(move) and face or (other.facing == facing_right and 1 or -1)
            local k, box = move_hits(other, own_face, move, 0, self, vframe, self_at, best and best - 1 or horizon, plan ~= nil)
            if k then best, damage = k, box.injury end
            if not k and virtual and move.first <= 8 then
                for step = 1, steps do
                    if best and step + move.first >= best then break end
                    virtual.x_int = other.x_int + trunc(face * walk * step)
                    offset = lock + step
                    k, box = move_hits(virtual, own_face, move, 0, self, vframe, self_at, (best or horizon + 1) - step - 1, plan ~= nil)
                    offset = lock
                    if k then best, damage = step + k, box.injury; break end
                end
            end
        end
    end
    offset = 0
    local from_standing = best
    if best then best = best + lock end
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
                        offset = k
                        local kk, box = move_hits(virtual, own_face, part, 0, self, vframe, self_at, (best or horizon + lock + 1) - k - 1, plan ~= nil)
                        if kk then best, damage = k + kk, box.injury end
                    end
                end
            end
        end
        offset = 0
    end
    return best, damage, from_standing
end

-- The MP a fighter's strong moves want (the dearest of those worth 70 damage, within 350): what to charge
-- towards while a held target waits.
local function special_mp(analysis)
    if analysis.special_mp then return analysis.special_mp end
    local wanted = 0
    for _, move in ipairs(analysis.moves) do
        if move.first and move.damage >= 70 and not move.entry.parent and move.mp > wanted then wanted = min(move.mp, 350) end
    end
    analysis.special_mp = wanted
    return wanted
end

-- How far a fighter's quick blows reach in front of it (its own attacks, not what it throws).
local function melee_reach(analysis)
    if analysis.melee then return analysis.melee end
    local reach = 0
    for _, move in ipairs(analysis.moves) do
        local entry = move.entry
        if move.first and move.first <= 10 and move.damage >= 15 and not entry.parent
           and (entry.sequence or entry.basic == "attack" or entry.basic == "attack2" or entry.basic == "weapon_attack") then
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
-- With `guard_chains`, the specials struck out of the guard too (a mod's D>J>A: slower to start, so no reason to
-- keep out of their reach at every step, but a line of fire to approach beside).
local function danger_zones(analysis, guard_chains)
    if guard_chains then
        if analysis.zones_all then return analysis.zones_all end
    elseif analysis.zones then
        return analysis.zones
    end
    local zones = {}
    for _, move in ipairs(analysis.moves) do
        local entry = move.entry
        if move.first and move.first <= 16 and not entry.parent and entry.context == "ground" and not move.teleport
           and (entry.sequence or entry.basic == "attack" or entry.basic == "attack2" or entry.basic == "weapon_attack"
                or (guard_chains and entry.basic == "defend" and entry.chain)) then
            local damage = max(move.damage, move.hit_damage or 0, move.catch_damage or 0)
            if damage >= 25 then
                local x1, x2, z, unguardable, bdefend = 100000, -100000, 0, false, 0
                for _, box in ipairs(move.boxes) do
                    if box.t > move.first + 6 then break end
                    local ox = box.own and (move.traj_x[box.t] or 0) or 0
                    local oz = box.own and (move.traj_z[box.t] or 0) or 0
                    x1, x2 = min(x1, box.x1 + ox), max(x2, box.x2 + ox)
                    z = max(z, abs(box.z + oz) + box.zw)
                    -- (A grab holds a guarding fighter as well: base/game/combat catches whatever it reaches.)
                    if box.bdefend >= 61 or box.kind == attack_kinds.catch then unguardable = true end
                    bdefend = max(bdefend, box.bdefend)
                end
                zones[#zones + 1] = {x1 = x1, x2 = x2, z = z, t = move.first, damage = damage,
                    unguardable = unguardable, mp = move.mp, bdefend = bdefend}
            end
        end
    end
    if guard_chains then analysis.zones_all = zones else analysis.zones = zones end
    return zones
end

-- The far-reaching blows of an enemy's quick moves — a beam, a wave sent along the ground (Neji's air palm in
-- NTSD 2.4 crosses the stage in a few frames), a long sweep: how far along its line they strike, all the way out
-- (not only in their first frames, as danger_zones), their depth and their damage. A line to walk beside, not on.
function positioning.long_zones(analysis)
    if analysis.long_zones then return analysis.long_zones end
    local zones = {}
    for _, move in ipairs(analysis.moves) do
        local entry = move.entry
        if move.first and move.first <= 16 and not entry.parent and entry.context == "ground" and not move.teleport
           and (entry.sequence or entry.basic == "attack" or entry.basic == "attack2" or entry.basic == "weapon_attack"
                or (entry.basic == "defend" and entry.chain)) then
            local damage = max(move.damage, move.hit_damage or 0, move.catch_damage or 0)
            if damage >= 40 then
                local x1, x2, z = 100000, -100000, 0
                for _, box in ipairs(move.boxes) do
                    if box.t > move.first + 20 then break end
                    local ox = box.own and (move.traj_x[box.t] or 0) or 0
                    local oz = box.own and (move.traj_z[box.t] or 0) or 0
                    x1, x2 = min(x1, box.x1 + ox), max(x2, box.x2 + ox)
                    z = max(z, abs(box.z + oz) + box.zw)
                end
                if x2 - x1 >= 150 then
                    zones[#zones + 1] = {x1 = x1, x2 = x2, z = z, t = move.first, damage = damage, mp = move.mp}
                end
            end
        end
    end
    analysis.long_zones = zones
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

-- A fallen or blinking target's wake-up blows: those of its quick ground moves (started within 12 frames of
-- standing up; its plain reach counts too) that reach a fighter `distance` away in x. The depth they cover and
-- the far end of their reach, with margins; both zero when none reaches that far. It can strike with them as
-- soon as it is on its feet, while nothing lands on it yet: a place to be out of by then, in depth or in x.
local function wake_zone(target, analysis, distance)
    local zone_z, zone_x = 0, 0
    local reach = melee_reach(analysis)
    if reach > 0 and distance < reach + 20 then zone_z, zone_x = 14, reach + 20 end
    for _, zone in ipairs(danger_zones(analysis)) do
        if target.mp >= zone.mp and zone.t <= 12 and distance < zone.x2 + 24 and distance > zone.x1 - 24 then
            zone_z = max(zone_z, zone.z + tune.wake_margin_z)
            zone_x = max(zone_x, zone.x2 + tune.wake_margin_x)
        end
    end
    return zone_z, zone_x
end
-- Whether `self` stands where `target`'s wake-up blows strike, and the frames to be out of them in depth and
-- back along x (plus the depth and reach they cover).
local function wake_escape(target, analysis, self)
    local distance, dz = abs(target.x_int - self.x_int), abs(target.z_int - self.z_int)
    local zone_z, zone_x = wake_zone(target, analysis, distance)
    if zone_z == 0 or dz >= zone_z then return false, 0, 0, zone_z, zone_x end
    local movement = self.record.movement or {}
    return true, (zone_z - dz) / (movement.walking_speedz or 2), (zone_x - distance) / (movement.walking_speed or 4), zone_z, zone_x
end

-- The catcher holding a caught fighter (a grab, or a mod's trap: Yamato's wood prison in Naruto: The Setting
-- Dawn holds its victim from an object), or nil.
local function catcher_of(state, target)
    if not target.caught_by or target.caught_by < 0 then return nil end
    local catcher = objects.lookup(state, target.caught_by)
    if not catcher or objects.lookup(state, catcher.catching) ~= target then return nil end
    local point = catcher.record.frame(catcher.frame).cpoint
    if point.kind ~= constants.cpoint_kinds.holder then return nil end
    return catcher, point
end

-- Frames from now for which `target` cannot be hit: while it blinks, and, down, until it has got up and its
-- blinking after that (base/game/animation: not stage soldiers) is over; `lock` is how long it stays down.
-- A target expected to flip up (context.target_path) is hittable along its roll instead.
local function untouchable_for(context, target, tstate, lock)
    local frames_left = abs(target.blink)
    local path = context.target_path
    if path and path.value == target then return frames_left end
    if tstate == states.caught then
        -- Held: nothing lands on it unless its catcher's hold lets blows through (cpoint hurtable).
        local catcher, point = catcher_of(context.state, target)
        if catcher and point.hurtable == 0 then frames_left = max(frames_left, lock) end
        return frames_left
    end
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

---------------------------------------------------------------------------------------------------------------
-- XOI: the notes of training. The bench's learn job (tools/ai-bench; xoi-hoc.bat on Windows) plays many games of
-- every pair of a mod's fighters and writes, for each fighter against each opponent, what each of its moves
-- brought when chosen: how often it landed or was struck first, the damage dealt and taken while it ran (its
-- follow-ups included) and what it was expected to bring; and how often the opponent struck first a move started
-- at a risk. A mod ships them as xoi/notes.txt beside its data; at XOI a move is weighed by how much of what was
-- expected of it, against this opponent, it brought — against how much the fighter's moves brought on the whole —
-- and the opponent's answers start from what training saw. Every computer in a network room has the mod's
-- notes, so the same: what is decided stays the same on all of them.
---------------------------------------------------------------------------------------------------------------

-- A move's name in the notes, the same in every match: how it starts, from where, and what it continues.
local function note_key(move)
    local key = move.note_key
    if key then return key end
    local entry = move.entry
    key = entry.context .. ":" .. tostring(entry.sequence and ("s" .. entry.sequence .. ":" .. entry.frame) or entry.press or entry.frame)
    if entry.parent then key = key .. ":from" .. tostring(entry.from) end
    for _, link in ipairs(entry.chain or {}) do key = key .. ">" .. tostring(link.from) .. tostring(link.button) end
    if move.weapon then key = "w" .. tostring(move.weapon) .. ":" .. tostring(entry.basic or key) end
    if entry.mode and entry.mode.record then key = "m" .. tostring(entry.mode.record.id) .. ":" .. key end
    key = key:gsub("%s", "_")
    move.note_key = key
    return key
end
smart.note_key = note_key

-- The notes' lines (the same line twice counts twice: training runs simply add up):
--   XOI G <fighter id> <opponent id> <games> <wins> <draws>
--   XOI R <fighter id> <opponent id> <moves started at a risk> <struck first>
--   XOI M <fighter id> <opponent id> <move> <starts> <landed> <struck first> <damage dealt> <damage taken> <expected>
--   XOI C <fighter id> <opponent id> <move> <situation>:<starts>,<dealt - taken>,<expected> ...
--          the same move by the situation it was started in (smart.note_situation): sf sr sb sa sg sh what the
--          opponent was doing, dn dm df how far off it was, hl hh whether the fighter's own HP had run low
--   XOI P <fighter id> <opponent id> <spot>:<frames>,<visits>,<dealt>,<taken>,<squares> ...
--          the frames the fighter stood free, the opponent free on its feet too, at a distance and depth and on the
--          side it faced or behind it (smart.spot_cell), in how many visits (frames on the spot in a row), the damage
--          dealt and taken in the 45 frames after each, and the sum of the squares of (dealt - taken)
-- A mod's notes may hold every pair of a large roster (megabytes): only the lines of the pairs in the match are
-- read, found as plain text.
local notes_given -- notes handed over (the bench), instead of the mod's file
local notes_text, notes_cache, notes_count, notes_checked
-- The notes as they stand (with a line break first): the mod's xoi/notes.txt, looked at again in every match (what
-- was read of it is kept while it stays the same), or none.
local function current_notes()
    if notes_checked and notes_text then return notes_text end
    local text = notes_given
    if not text then
        local ok, found = pcall(engine.read_resource, "xoi/notes.txt")
        text = ok and type(found) == "string" and found or ""
    end
    text = "\n" .. text
    if text ~= notes_text then notes_text, notes_cache, notes_count = text, {}, nil end
    notes_checked = true
    return notes_text
end
-- (The bench: notes to play with, instead of the mod's.)
function smart.use_notes(text) notes_given, notes_text, notes_cache, notes_count, notes_checked = text, nil, nil, nil, nil end
-- Every line of the notes that starts with `prefix`: what follows the prefix.
local function note_lines(text, prefix, each)
    local needle = "\n" .. prefix
    local init = 1
    while true do
        local at = text:find(needle, init, true)
        if not at then return end
        local stop = text:find("\n", at + #needle, true) or (#text + 1)
        local rest = text:sub(at + #needle, stop - 1)
        if rest:sub(-1) == "\r" then rest = rest:sub(1, -2) end
        each(rest)
        init = stop
    end
end
-- How many pairs of fighters (one against the other) the notes know.
function smart.notes_pairs()
    local text = current_notes()
    if notes_count then return notes_count end
    local seen, count = {}, 0
    note_lines(text, "XOI G ", function(rest)
        local pair = rest:match("^(%d+%s+%d+)%s")
        if pair and not seen[pair] then seen[pair], count = true, count + 1 end
    end)
    notes_count = count
    return count
end

-- A move's record is weighed against the fighter's average over this many starts of it, so that a move seldom
-- tried keeps close to the average; a factor stays within these bounds. A move's record in one situation is
-- weighed against the move's own over situation_prior starts; what each of the three sides of a situation says
-- changes the move's factor by a part within situation_step, all three together within situation_span, and the
-- factor by situation stays within situation_low and situation_high.
local note_prior, note_low, note_high = 8, 0.5, 1.6
local situation_prior, situation_low, situation_high = 12, 0.45, 1.75
local situation_step, situation_span = {0.75, 1.33}, {0.7, 1.4}
-- A spot's record is weighed against the pair's average as if it had been visited this many more times; a spot's
-- spread is taken to be at least this (HP over 45 frames).
local spot_prior, spot_spread = 3, 10

-- The situation a move is started in, as XOI's notes count it, in training and in play alike: what the opponent
-- is doing (f free on its feet and turned toward the fighter, r the same turned away, b busy in a move, a in the
-- air, g guarding, h hurt, down or held), how far off it is (n within 80, m within 220, f farther) and whether the
-- fighter's own HP has run low (l a third of the bar or less, h more).
function smart.note_situation(self, target)
    local ts = target.record.frame(target.frame).state
    local doing
    if exposed_states[ts] or ts == states.lying or ts == states.caught then doing = "h"
    elseif ts == states.defending then doing = "g"
    elseif target.y_int < 0 then doing = "a"
    elseif ts == states.standing or ts == states.walking or ts == states.running then
        doing = ((target.facing == facing_right) == (self.x_int >= target.x_int)) and "f" or "r"
    else doing = "b" end
    local dx = abs(target.x_int - self.x_int)
    local far = dx < 80 and "n" or (dx < 220 and "m" or "f")
    local low = self.hp * 3 <= (self.max_hp or constants.points.full) and "l" or "h"
    return doing, far, low
end

-- The spot a fighter stands on against the opponent, both free, as the notes count it: "f" in front of the
-- opponent (on the side it faces), "b" behind it, then which of the distances 30 60 100 150 220 320 480 it is
-- past, then which of the depths 8 18 32. (`front`: the fighter is on the side the opponent faces.)
local spot_dx, spot_dz = {30, 60, 100, 150, 220, 320, 480}, {8, 18, 32}
function smart.spot_cell(dx, dz, front)
    dx, dz = abs(dx), abs(dz)
    local i, j = 0, 0
    while i < #spot_dx and dx >= spot_dx[i + 1] do i = i + 1 end
    while j < #spot_dz and dz >= spot_dz[j + 1] do j = j + 1 end
    return (front and "f" or "b") .. i .. j
end
-- What the notes say of `a` (a fighter id) against `b`: factor (by move name: how much more, or less, than the
-- fighter's moves on the whole, a move brought of what was expected of it) and risk (the opponent's share of
-- answers to a move started at a risk, around the hopeful start the match itself uses), or nil.
local function pair_notes(a, b)
    local text = current_notes()
    local mine = notes_cache[a]
    if not mine then mine = {}; notes_cache[a] = mine end
    local found = mine[b]
    if found ~= nil then return found or nil end
    local head = string.format("%d %d ", a, b)
    local games = 0
    note_lines(text, "XOI G " .. head, function(rest)
        local count = rest:match("^(%d+)")
        if count then games = games + tonumber(count) end
    end)
    if games == 0 then mine[b] = false; return nil end
    local risk_starts, risk_hits, moves = 0, 0, {}
    note_lines(text, "XOI R " .. head, function(rest)
        local starts, hits = rest:match("^(%d+)%s+(%d+)")
        if starts then risk_starts, risk_hits = risk_starts + tonumber(starts), risk_hits + tonumber(hits) end
    end)
    note_lines(text, "XOI M " .. head, function(rest)
        local key, s, l, c, d, t, p = rest:match("^(%S+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)")
        if key and tonumber(s) > 0 then
            local m = moves[key]
            if not m then m = {s = 0, l = 0, c = 0, d = 0, t = 0, p = 0}; moves[key] = m end
            m.s, m.l, m.c = m.s + tonumber(s), m.l + tonumber(l), m.c + tonumber(c)
            m.d, m.t, m.p = m.d + tonumber(d), m.t + tonumber(t), m.p + tonumber(p)
        end
    end)
    local situations = {}
    note_lines(text, "XOI C " .. head, function(rest)
        local key, cells = rest:match("^(%S+)%s+(.*)$")
        if not key then return end
        local by = situations[key]
        if not by then by = {}; situations[key] = by end
        for name, s, net, p in cells:gmatch("(%a%a):(%d+),(%-?%d+),(%d+)") do
            local c = by[name]
            if not c then c = {s = 0, net = 0, p = 0}; by[name] = c end
            c.s, c.net, c.p = c.s + tonumber(s), c.net + tonumber(net), c.p + tonumber(p)
        end
    end)
    local cells = {}
    note_lines(text, "XOI P " .. head, function(rest)
        for name, n, v, d, t, q in rest:gmatch("(%a%d%d):(%d+),(%d+),(%d+),(%d+),(%d+)") do
            local c = cells[name]
            if not c then c = {n = 0, v = 0, d = 0, t = 0, q = 0}; cells[name] = c end
            c.n, c.v, c.d, c.t, c.q = c.n + tonumber(n), c.v + tonumber(v), c.d + tonumber(d), c.t + tonumber(t), c.q + tonumber(q)
        end
    end)
    -- (Sums of whole numbers only, in any order: the same everywhere.)
    local brought, expected = 0, 0
    for _, m in pairs(moves) do brought, expected = brought + m.d - m.t, expected + m.p end
    local factor, own, situ = {}, {}, {}
    local ratio = 1
    if expected > 0 then
        ratio = max(brought, expected * 0.25) / expected
        for key, m in pairs(moves) do
            if m.p > 0 then
                local each = m.p / m.s
                local mine_own = (m.d - m.t + note_prior * ratio * each) / (m.p + note_prior * each)
                factor[key] = min(note_high, max(note_low, mine_own / ratio))
                own[key] = mine_own
                -- By situation: what the move brought there, weighed against what it brought on the whole.
                local by = situations[key]
                if by then
                    local d = {}
                    for name, c in pairs(by) do
                        if c.p > 0 then
                            d[name] = (c.net + situation_prior * mine_own * each) / (c.p + situation_prior * each)
                        end
                    end
                    situ[key] = d
                end
            end
        end
    end
    -- The spots: net damage over the 45 frames after standing there, weighed against the pair's average by how
    -- many visits it rests on (frames in a row tell little more than one), and how far it may be off (its spread
    -- over the visits).
    local spots
    local frames, net = 0, 0
    for _, c in pairs(cells) do frames, net = frames + c.n, net + c.d - c.t end
    if frames > 0 then
        local mean = net / frames
        spots = {mean = mean, cells = {}}
        for name, c in pairs(cells) do
            local own = (c.d - c.t) / c.n
            local spread = max(c.q / c.n - own * own, spot_spread * spot_spread)
            local visits = max(c.v, 1)
            spots.cells[name] = {v = (visits * own + spot_prior * mean) / (visits + spot_prior),
                se = sqrt(spread / (visits + spot_prior)), visits = visits}
        end
    end
    local pair = {factor = factor, own = own, situ = situ, ratio = ratio, spots = spots,
        risk = (risk_hits + 1) / (risk_starts + 4), games = games, moves = moves}
    mine[b] = pair
    return pair
end
smart.pair_notes = pair_notes

-- A move's factor in a situation (the codes of smart.note_situation, as "s".. "d".. "h"..): its factor on the whole,
-- changed by what each of the three sides of the situation said of it — the factor its record there would have,
-- against the one it has — within bounds (a side seldom seen there says little: its record keeps close to the
-- move's own, pair_notes).
local function situation_factor(notes, key, situation)
    local base = notes.factor[key]
    if not base then return 1 end
    local by = notes.situ[key]
    if not by then return base end
    local ratio, adjust = notes.ratio, 1
    for i = 1, 3 do
        local there = by[situation[i]]
        if there then
            local f = min(note_high, max(note_low, there / ratio))
            adjust = adjust * min(situation_step[2], max(situation_step[1], f / base))
        end
    end
    adjust = min(situation_span[2], max(situation_span[1], adjust))
    return min(situation_high, max(situation_low, base * adjust))
end
smart.situation_factor = situation_factor

-- What `move` (started `lead` frames from now) landing its box `box` on `target` after `t` frames is worth:
-- damage weighed by how sure the hit is, what a guard would cost, MP, and what being busy afterwards would cost.
local function attack_score(context, target, tstate, move, t, box, face, stunned, danger, stagger, lead)
    local blocked = would_block(target, target_state_at(context, target, t - 1), face == 1 and facing_right or facing_left, box)
    -- A hit is sure while the target cannot act; otherwise it may step away or guard in time.
    local sure = 1.0
    if t > stunned then sure = max(tune.sure_floor, 1.0 - (t - stunned) * tune.sure_decay) end
    if danger and t > danger - 2 then sure = sure * tune.danger_sure end
    -- A free target facing the blow can raise its guard in time (mods' fighters then often strike back from
    -- the guard): the likelier the longer the blow takes, and the more this one has guarded so far; a guarded
    -- blow is worth a tenth, or a broken guard. The longer nothing has happened, the more it is worth trying.
    local guarded = blocked and 1 or 0
    if not blocked and t > stunned and box.bdefend < 61 and (tstate == states.standing or tstate == states.walking)
       and target.facing ~= (face == 1 and facing_right or facing_left) then
        guarded = guard_rate(model_of(context, target)) * min(1, (1 - 0.9 ^ (t - stunned)) * 1.25) * (1 - tune.guard_aggression * (context.aggression or 0))
    end
    local damage = worth(target, box, false, move) * (1 - guarded) + worth(target, box, true, move) * guarded
    local score = damage * sure
    if not blocked and guarded > 0 then score = score - guarded * (context.guard_counter or 20) end
    score = score - move.mp * tune.mp_cost - max(move.hp, 0) * tune.hp_cost
    score = score * 14 / (t + tune.time_bias) * (tune.time_bias / 10)
    -- Still busy when the target, back on its feet, could land its quickest blow: that blow is the price.
    local ready = move.ready + lead
    local knocked = box.fall >= 60 or target.timer_b0 + max(box.fall, 20) > 60
    local back_at = t + (knocked and 30 or stagger) + (context.counter_first or 99)
    if ready >= back_at - 1 then score = score - (context.counter_damage or 0) * tune.counter_price * 14 / (t + tune.time_bias) * (tune.time_bias / 10) end
    local open = ready - t - (knocked and 30 or stagger)
    if open > 0 then score = score - open * tune.open_cost end
    -- The whole of what the fighter can do gets its turn: a move not yet tried this match is a little more
    -- tempting, one just used a little less (the choice stays the fighter's own, from its own data).
    local last_use = context.last_use
    if last_use and score > 0 then
        local last = last_use[move.index]
        if not last then score = score * tune.novelty
        elseif context.now - last < 90 then score = score * tune.repeat_factor end
    end
    -- XOI: what the move brought against this opponent in training, against the fighter's moves on the whole — in
    -- the situation it would be started in now, when the notes have it.
    local notes = context.notes
    if notes and score > 0 then
        local situation = context.notes_situation
        if situation then score = score * situation_factor(notes, note_key(move), situation)
        else score = score * (notes.factor[note_key(move)] or 1) end
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
        if move.first and move.first <= horizon and entry.basic ~= "attack2" and entry.basic ~= "weapon_attack2"
           and not (excluded and excluded[move]) and can_start(self, frame, fstate, move) then
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
    local traj_x, traj_y, traj_z = move.traj_x, move.traj_y, move.traj_z
    -- (A teleport goes on from beside the enemy it goes to: the target here.)
    local tp = move.teleport and move.teleport_dx and min(move.teleport + 1, length) or nil
    local tp_x, tp_z
    if tp then
        tp_x = target.x_int + move.teleport_dx * face - self.x_int - (traj_x[tp] or 0) * face
        tp_z = target.z_int + (move.teleport_dz or 1) - self.z_int - (traj_z[tp] or 0)
    end
    local plan = function(k)
        if k <= 0 then return 0, 0, 0 end
        k = min(k, length)
        if tp and k >= tp then return tp_x + (traj_x[k] or 0) * face, traj_y[k] or 0, tp_z + (traj_z[k] or 0) end
        return (traj_x[k] or 0) * face, traj_y[k] or 0, traj_z[k] or 0
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
    if entry.mode then
        -- A mode's air move: the attack key in the air, with the mode's item in hand (a light one: the jump is
        -- the fighter's own).
        local memory = self.smart_memory
        return entry.press == "attack" and not entry.chain and memory and memory.held_record ~= nil
            and memory.held_record.data == entry.mode.record.data and self.weapon ~= record_kinds.heavy_item
    end
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
    if not best then return nil end
    -- The flight, for what could reach the fighter on its way (counter_along): on the ground for `lead` frames,
    -- then along the arc in the air frame.
    local now = self.record.frame(self.frame)
    local plan = function(k)
        if k <= lead then return 0, 0, 0 end
        local tt = k - lead
        local y = tt * height + 0.85 * tt * (tt - 1)
        if y > 0 then y = 0 end
        return trunc(dir * speed * tt), trunc(y), 0
    end
    local frames_at = function(k)
        if k <= lead then return now end
        return air_frame
    end
    return best, best_t, best_score, lead, plan, frames_at
end

-- Toward a target `distance` away (1), away from it (-1) or neither (0), to keep it between `near` and `far`
-- (`back` false: never away). A direction key turns the fighter and walks it, so turning round is a step too:
-- turned away from the target (stepping back), the step back goes on until turning round again leaves it clear of
-- `near` — at that edge a fighter otherwise turned back and forth every frame, a step out and a step in by turning
-- round (a fast walker's step is wider than the band between the two).
function positioning.keep_distance(self, dx, distance, near, far, back)
    if back then
        local away_facing = dx ~= 0 and (dx > 0) == (self.facing == facing_left)
        local step = (self.record.movement or {}).walking_speed or 4
        if distance < near or (away_facing and distance < near + 2 * step + 8) then return -1 end
    end
    if distance > far then return 1 end
    return 0
end

-- XOI's spots (pair_notes): how good training found it to stand free at (dx, dz) from the opponent, it free on its
-- feet too, in front of it or behind — the net damage of the 45 frames after, against the pair's average by the
-- visits seen there — how far that may be off, and the visits.
function positioning.spot_value(spots, dx, dz, front)
    local cell = spots.cells[smart.spot_cell(dx, dz, front)]
    if not cell then return spots.mean, 1000, 0 end
    return cell.v, cell.se, cell.visits
end

-- The distance to keep: near the far end of where the fighter's best quick, cheap move strikes first.
local function preferred_range(context, self)
    local analysis = context.analysis_of(self)
    if analysis.range then return analysis.range, analysis.range_z end
    local best, best_value, best_far = nil, -1, 0
    for _, move in ipairs(analysis.moves) do
        local entry = move.entry
        if move.first and move.first <= 12 and move.mp <= 30 and not entry.parent and not entry.chain and not move.teleport
           and (entry.sequence or entry.basic == "attack" or entry.basic == "weapon_attack") then
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
    if tstate == states.caught then
        -- Held: until the hold's timer runs out (base/game/grab: `decrease` a frame from 300), or, when the hold
        -- does not time out by itself, a while.
        local catcher, point = catcher_of(context.state, target)
        if catcher then
            local left = point.decrease > 0 and min(max(floor(catcher.catch_timer / point.decrease), 1), 90) or 20
            -- A trap (an object holding it) takes hold again as its timer runs out: a long while in all.
            if catcher.record.kind ~= record_kinds.character then left = max(left, 60) end
            return left
        end
    end
    if not is_free(target) then
        local where = where_of(target.record, analysis, target)
        if where then
            local left = max(where.move.ready - (where.t + target.wait_counter), 0)
            -- A stance (a charge, a field) goes round until a key ends it: the target is free as soon as its
            -- exit allows, not at the end of the play the stance was seen in.
            if target.y_int == 0 then
                local leave = stance_leave(target.record, analysis, target)
                if leave then left = leave + 1 end
            end
            return left
        end
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
-- The same for a fighter on its way along a move of its own (move_path): where the move takes it, in the frames
-- it is in there. (A rush ends inside the arms of a target whose blows do not reach where it started.)
local function counter_along(context, target, self, lock, plan, frames_at)
    if abs(target.x_int - self.x_int) > 600 or abs(target.z_int - self.z_int) > 90 then return nil end
    if lock == 0 and not is_free(target) then lock = 1 end
    local reach, damage = enemy_reach(context, target, self, 16, lock, plan, frames_at)
    return reach, damage
end
-- How likely the target is to answer a move of ours that its quicker blow could beat on the way, by what the
-- fighter has seen in this match: of its moves started at such a risk, how many were struck before they landed
-- (counted around a hopeful start, so that the first rushes are tried at all). A target that waits for us and
-- punishes is soon not rushed at; one that does not is.
-- (At XOI the start is what training saw this opponent do: memory.risk_prior.)
local function answer_chance(memory)
    return ((memory.risk_hits or 0) + tune.risk_weight * (memory.risk_prior or tune.risk_prior)) / ((memory.risk_starts or 0) + tune.risk_weight)
end
-- What a move scored `score`, landing in `t` frames, is worth when the target's answer (`damage`) may beat it
-- on the way: the move lands only if the answer does not come, and the answer's damage is the price if it does.
local function worth_the_risk(memory, score, t, damage)
    local chance = answer_chance(memory)
    return score * (1 - chance) - chance * (damage or 0) * 14 / (t + tune.time_bias) * (tune.time_bias / 10)
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
            if exposed_states[tstate] or tstate == states.caught then distance = distance - 60 end
            if tstate == states.lying then distance = distance + 120 end
            -- Among several enemies (a team, a stage): one busy with a move cannot answer, one low on HP is
            -- soonest out of the fight, one holding a teammate or standing over a fallen one must be dealt with.
            if not is_free(value) and not exposed_states[tstate] and tstate ~= states.lying then distance = distance - 40 end
            if value.hp < 150 then distance = distance - 40 end
            if tstate == states.catching then distance = distance - 100 end
            for mate_index = 0, constants.item_slots - 1 do
                local mate = items[mate_index]
                if mate and mate_index ~= index and mate_index ~= other and mate.team == self.team and mate.hp > 0
                   and mate.record.kind == record_kinds.character then
                    local mstate = mate.record.frame(mate.frame).state
                    if (exposed_states[mstate] or mstate == states.lying or mstate == states.caught)
                       and abs(mate.x_int - value.x_int) < 120 and abs(mate.z_int - value.z_int) < 40 then
                        distance = distance - 60
                        break
                    end
                end
            end
            if not best_score or distance < best_score then best, best_score = other, distance end
        end
    end
    memory.target = best
    return best
end

local function face(self, target_x)
    -- (Not toward a target right above or below us: a pixel either side of us would turn us round every frame.)
    if abs(target_x - self.x_int) < 6 then return end
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

-- The enemy a teleport goes to: the nearest (base/game/frame_rules).
local function nearest_enemy(state, self)
    local best, distance
    for other = 0, constants.item_slots - 1 do
        local value = state.items[other]
        if value and value ~= self and value.record.kind == record_kinds.character and value.hp > 0 and value.team ~= self.team then
            local next = abs(value.z_int - self.z_int) + abs(value.x_int - self.x_int)
            if not distance or next < distance then best, distance = value, next end
        end
    end
    return best
end

-- A move of the fighter's own that takes it out of the way of what is coming when no step does: a vanishing
-- teleport, a rush, a leap (Kuma of One Piece GrandWorld comes down behind the enemy, untouchable on the way) —
-- one whose path no blow on its way meets for a while after the threat, the one that strikes back best, else
-- the cheapest and soonest over; and whether it strikes back.
local function escape_move(state, index, self, frame, fstate, context, level, threat_t, source)
    local analysis = context.analysis_of(self)
    local enemy = source.record.kind == record_kinds.character and source or nearest_enemy(state, self)
    if not enemy then return nil end
    local best, best_value, best_strikes
    for _, move in ipairs(analysis.moves) do
        local entry = move.entry
        if not entry.parent and not move.charge and not move.transform and not move.mode and not (move.heal and move.weapon)
           and move.length > 1 and not ((entry.basic == "jump" or entry.basic == "defend") and not entry.chain)
           and can_start(self, frame, fstate, move) then
            local plan, frames_at = move_path(self, move, enemy)
            if not earliest_threat(state, index, self, threat_t + 8, plan, level.reaction, context, frames_at) then
                local value = -move.mp * 0.05 - move.ready * 0.5
                local strikes = false
                if move.first and source.record.kind == record_kinds.character then
                    local face = turns(move) and (source.x_int >= self.x_int and 1 or -1) or (self.facing == facing_right and 1 or -1)
                    local sframe = source.record.frame(source.frame)
                    local t = move_hits(self, face, move, 0, source, sframe, function(k) return predict(source, k, sframe.state) end, 40)
                    if t then strikes = true; value = value + 60 - t end
                end
                if not best_value or value > best_value then best, best_value, best_strikes = move, value, strikes end
            end
        end
    end
    return best, best_strikes
end

-- Answers a threat in `threat_t` frames: true when it did something.
local function answer(state, index, self, frame, fstate, context, memory, level, threat_t, threat_box, source)
    local analysis = context.analysis_of(self)
    local can_defend = (fstate == states.standing or fstate == states.walking) and self.defend_lock == 0
        and self.weapon ~= record_kinds.heavy_item and analysis.guard ~= false
    -- A guard takes a tenth of the damage; it holds unless the defence points reach the break threshold.
    -- (A grab holds a guarding fighter as well: no guard against it.)
    local catch = threat_box.kind == attack_kinds.catch
    local guardable = threat_box.bdefend < 61 and not catch
    local blockable = guardable and threat_box.bdefend + self.timer_b8 < break_threshold
    -- Strike first when a move lands before the threat does (landing together is a trade: taken only when our
    -- blow is clearly the heavier).
    -- (A move started now strikes t - 1 frames from now; the threat, threat_t frames from now.)
    if source.record.kind == record_kinds.character and threat_t >= 1 then
        local move, t, score = best_attack(context, self, frame, fstate, source, threat_t, nil)
        if not move then
            move, t, score = best_attack(context, self, frame, fstate, source, threat_t + 1, nil)
            if move and not (t == threat_t + 1 and move.damage > threat_box.injury * tune.trade_factor) then move = nil end
        end
        if move then
            start(self, move, source, t, score)
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
    local heavy = threat_box.injury >= 45 or threat_box.bdefend >= 16 or catch
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
    -- No step gets out of its way: a move may (escape_move), when the guard cannot hold the blow, or it is a
    -- heavy one and the move keeps MP for a strong move of the fighter's own after it, or the move strikes back.
    -- Otherwise the guard, in time (not a move that cannot come out before the blow lands).
    if fstate ~= states.running then
        local escape, strikes = escape_move(state, index, self, frame, fstate, context, level, threat_t, source)
        if escape and (not blockable or strikes or (heavy and self.mp - escape.mp >= special_mp(analysis))) then
            start(self, escape, source)
            memory.note = strikes and "escape and strike" or "escape"
            return true
        end
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

-- The lying weapon worth walking to (a drink when HP or MP is wanted, a light weapon, a heavy one when the
-- target is far: it slows the walk), within a few steps, or nil.
local function weapon_to_take(state, self, target)
    local best, best_value
    local far = abs(target.x_int - self.x_int) > 250
    for other = 0, constants.item_slots - 1 do
        local value = state.items[other]
        if value and weapon_kinds[value.record.kind] and value.weapon == weapon_none and value.hp > 0
           and resting_states[value.record.frame(value.frame).state] then
            local distance = abs(value.x_int - self.x_int) + abs(value.z_int - self.z_int) * 2
            if distance <= 220 then
                local kind = value.record.kind
                local worth
                if kind == record_kinds.drink then
                    worth = (self.hp < self.dark_hp - 60 or self.mp < 250) and 120 or 0
                elseif kind == record_kinds.light_item then
                    worth = holder_code(value.record) == constants.weapon_holder_codes.knife_or_boomerang and 80 or 70
                elseif kind == record_kinds.baseball then worth = 40
                else worth = far and 50 or 0 end
                -- With MP for the fighter's own specials, a weapon is only worth the few steps to one close by.
                if kind ~= record_kinds.drink then worth = worth * (1 - min(self.mp, 400) / 500) end
                worth = worth - distance * 0.25
                if worth > 0 and (not best_value or worth > best_value) then best, best_value = value, worth end
            end
        end
    end
    return best
end
-- Whether the fighter stands on the weapon now: the attack key starts the punch, whose first frame carries the
-- pick-up area (a kind-2 interaction at the feet) that takes a lying weapon it meets.
local function over_weapon(self, frame, weapon)
    local wframe = weapon.record.frame(weapon.frame)
    local record = self.record
    for _, candidate in ipairs({frame, record.frames[frames.punch], record.frames[frames.punch + 5]}) do
        if candidate then
            for _, area in ipairs(candidate.interactions) do
                if area.kind == attack_kinds.pick_up then
                    local zw = area.zwidth ~= 0 and area.zwidth or default_zwidth
                    if abs(self.z_int - weapon.z_int) < zw then
                        local x = area_x(self, candidate, area)
                        local y = area.y + self.y_int - candidate.center_y
                        if touches(weapon, wframe, weapon.x_int, weapon.y_int, x, x + area.width, y, y + area.height) then return true end
                    end
                end
            end
        end
    end
    return false
end
-- A teammate fighting the target from the fighter's own side, nearer to it (two on one from one side).
local function mate_on_side(state, index, self, target)
    local side = self.x_int >= target.x_int and 1 or -1
    local own = abs(self.x_int - target.x_int)
    for other = 0, constants.item_slots - 1 do
        local mate = state.items[other]
        if mate and other ~= index and mate.team == self.team and mate.hp > 0 and mate.record.kind == record_kinds.character
           and mate.team ~= constants.teams.independent then
            local mdx = mate.x_int - target.x_int
            if (mdx >= 0 and 1 or -1) == side and abs(mdx) < own and abs(mdx) < 200 and abs(mate.z_int - target.z_int) < 60 then
                return true
            end
        end
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
    -- A move started at a risk (see answer_chance): struck before it landed, or landed (or came to nothing).
    local risky = memory.risky
    if risky then
        if self.hp < risky.hp - 2 and state.frame_number <= risky.ends then
            memory.risk_hits = (memory.risk_hits or 0) + 1
            memory.risky = nil
        elseif state.frame_number > risky.ends then
            memory.risky = nil
        end
    end
    local context = state.smart_context
    if not context then
        context = {state = state}
        function context.analysis_of(value) return view_of(context, value) end
        state.smart_context = context
    end
    context.notes, context.notes_situation, context.notes_spots = nil, nil, nil
    clear_keys(self)
    -- (When the fighter last turned round: positioning does not turn it round again at once, see there; and when
    -- a walk to a weapon last ended, see the weapons below.)
    if memory.facing ~= self.facing then memory.facing, memory.turned_at = self.facing, state.frame_number end
    if memory.to_weapon == state.frame_number - 2 then memory.weapon_left = state.frame_number - 1 end
    local frame = self.record.frame(self.frame)
    local fstate = frame.state
    -- What is in the hand (a weapon, or the item of a mode of the fighter's own making).
    local held_now = self.held_item and items[self.held_item]
    memory.held_record = (held_now and self.weapon ~= weapon_none and self.weapon > 0 and items[held_now.holder] == self) and held_now.record or nil
    local mode_now = memory.held_record and (context.analysis_of(self).armed or {}).mode or nil
    local mode_resting = mode_now and (mode_now.idle[self.frame] or fstate == states.standing or fstate == states.walking) or false
    local mode_moving = mode_now and mode_now.moving and mode_now.moving[self.frame] or false

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
        or fstate == states.jumping or fstate == states.dashing or fstate == states.defending or mode_resting or mode_moving

    -- A planned chain: its next key in a frame that takes it there (a guard's or the jump's frame may be
    -- that frame; the chain is over once the fighter stands, walks or runs again).
    if memory.chain then
        local link = memory.chain[memory.chain_step]
        local idle = fstate == states.standing or fstate == states.walking or fstate == states.running
        memory.chain_age = memory.chain_age + 1
        if not link or memory.chain_age > 60 or (idle and memory.chain_age > 2 and link.key ~= "pick") then
            memory.chain = nil
        elseif link.key == "pick" then
            -- The pick-up of an item the move laid down: attack while in the frame whose zone covers it.
            if memory.held_record then
                memory.chain_step = memory.chain_step + 1
                if not memory.chain[memory.chain_step] then memory.chain = nil end
                memory.note = "picked up"
                return
            elseif self.frame == link.from then
                fresh(self, "attack")
                memory.note = "pick up"
                return
            elseif not idle then
                -- (Still on the way to that frame: a guard or jump on the way counts as free, but is not over
                -- yet — Magellan of One Piece GrandWorld lays his item down from the guard's second frame.)
                memory.note = "to pick-up frame"
                return
            else
                -- Standing again without the item: the first key did not take (a crouch, a lock); over, and
                -- the mode may be tried again at once.
                memory.chain = nil
                if memory.chain_step == 1 then memory.mode_tried = nil end
            end
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
    -- XOI: the notes of this fighter against this opponent, if training saw the two, read in the situation of the
    -- moment (what the opponent is doing, how far off, the fighter's own HP), with the spots training found better
    -- or worse to stand on. (The bench's "xoi:m" plays with the moves' factors alone, as XOI did up to version 26;
    -- "xoi:c" adds the situations, "xoi:p" the spots.)
    local brain = self.brain
    if target and ((brain and brain:sub(1, 3) == "xoi") or (brain == nil and level.notes)) then
        local notes = pair_notes(self.record.id, target.record.id)
        context.notes = notes
        if notes and brain ~= "xoi:m" and brain ~= "xoi:p" then
            local doing, far, low = smart.note_situation(self, target)
            context.notes_situation = {"s" .. doing, "d" .. far, "h" .. low}
        end
        if notes and brain ~= "xoi:m" and brain ~= "xoi:c" then context.notes_spots = notes.spots end
    end
    memory.risk_prior = context.notes and context.notes.risk or nil
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
                            start(self, move, target, t)
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
                if (where.move.mp < 0 or where.move.heal) and not where.move.first then
                    -- (Kept while the target stays outside its quick reach, with a margin below the one the charge
                    -- was started at, so that it is not left and started again every few frames.) A drink is held
                    -- while it still heals or fills.
                    local tlock = target and target_lock_of(context, target, target.record.frame(target.frame)) or 99
                    local wanted = (where.move.mp < 0 and self.mp < constants.points.full)
                        or (where.move.heal and self.hp < self.dark_hp - 5)
                    -- (Beside a fallen target, within its wake-up blows: left in time to be out of them when it
                    -- is on its feet.)
                    local escape = 0
                    if target then
                        local inside, tz, tx = wake_escape(target, context.analysis_of(target), self)
                        if inside then escape = min(tz, tx) + 4 end
                    end
                    stay = wanted
                        and (not target or abs(target.x_int - self.x_int) > melee_reach(context.analysis_of(target)) + 50
                             or tlock > exit_lock + 10 + escape)
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
    -- Out of the target's reach in a mode whose resting and moving frames have no body its blows touch (a body only
    -- on a far layer, positioning.far_reach: Drake's T-rex, Magellan's Venom Demon): nothing it does can hit us
    -- there, so its reach is no reason to keep away — until MP is about to run out and end the mode.
    local far = positioning.far_reach(target_analysis)
    local shielded = mode_now ~= nil and (mode_resting or mode_moving) and not positioning.reachable(frame, far)
        and positioning.mode_shielded(self.record, mode_now, far) and not ((mode_now.drain or 0) > 0 and self.mp < 40)
    -- A target down, or up again and still blinking from its fall (not the blink of a match's first frames).
    local target_down = tframe.state == states.lying or tframe.state == states.falling
    if target_down then memory.target_down_at = state.frame_number end
    local target_waking = target_down
        or (target.blink ~= 0 and memory.target_down_at ~= nil and state.frame_number - memory.target_down_at < 90)
    -- Frames since the last blow between the two: a standoff makes it bolder; so does an opponent that hardly
    -- ever attacks when it could (nothing to bait, everything to walk up to).
    -- (A guarded blow's tenth does not count: a guard that only soaks up jabs is a standoff too.)
    local hp_sum = self.hp + target.hp
    if memory.hp_sum and hp_sum < memory.hp_sum - 6 then memory.calm = 0 else memory.calm = (memory.calm or 0) + 1 end
    memory.hp_sum = hp_sum
    context.aggression = min(1, max(0, (memory.calm - tune.calm_start) / tune.calm_span))
    local target_pressure = pressure(model)
    if target_pressure and target_pressure < 0.2 then context.aggression = max(context.aggression, tune.passive_aggression) end
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
    -- (Blinking after getting up, nothing hits us until it ends: no need to answer what lands before. A blow
    -- landing in `blinking` frames lands as it ends: the blink counts down after each frame's combat.)
    local blinking = abs(self.blink)
    local threat_t, threat_box, threat_source = earliest_threat(state, index, self, 16, nil, level.reaction, context)
    if threat_t and threat_t < blinking then threat_t = nil end
    if threat_t and answer(state, index, self, frame, fstate, context, memory, level, threat_t, threat_box, threat_source) then
        return
    end

    -- How soon the target could hit back, and what striking back from a guard could cost.
    context.counter_first, context.counter_damage = nil, nil
    local strongest = 0
    for _, zone in ipairs(danger_zones(target_analysis_of(context, target))) do strongest = max(strongest, zone.damage) end
    context.guard_counter = min(strongest, 80) * tune.guard_counter
    local danger = counter_time(context, target, self, target_lock)
    -- Blinking, the counter can only land once the blinking is over: the time to strike freely.
    if danger and blinking > 0 then danger = max(danger, blinking) end
    -- An opponent that hardly ever attacks when it could is not expected to answer this blow either (the model
    -- changes its mind as soon as it does attack).
    if target_pressure and target_pressure < 0.2 then danger = nil end

    -- Entering a mode of the fighter's own making (Gear Second, Diable Jambe: an item it lays down and picks up)
    -- when the mode's blows or speed beat its own, MP allows for it and what it burns, and nothing can reach us
    -- before it is on: while the target is held long enough, or well outside its reach. (Before a single blow at a
    -- held target: the mode pays for the rest of the fight.)
    -- (Not in the match's first frames: the fighters are set down crouching then, and the first key is lost.)
    if self.y_int == 0 and fstate ~= states.running and not memory.held_record and self.weapon == weapon_none
       and state.frame_number > 4 and (state.frame_number - (memory.mode_tried or -999)) > 90 then
        for _, candidate in ipairs(context.analysis_of(self).moves) do
            local mode = candidate.mode
            if mode and mode.start == candidate and can_start(self, frame, fstate, candidate) then
                if mode.worth == nil then armed_analysis(self.record, mode.record, #analyze(self.record).moves + 1) end
                local draining = (mode.drain or 0) > 0
                -- A mode out of the target's reach (positioning.far_reach) is worth more than its blows, and is
                -- entered near the target too (only the way in must be clear), with MP for a while in it.
                local shield = positioning.mode_shielded(self.record, mode, far)
                local wanted = self.mp >= candidate.mp + 50 + (draining and (shield and 200 or 120) or 0)
                local dx, dz = abs(target.x_int - self.x_int), abs(target.z_int - self.z_int)
                local opening = target_lock > candidate.ready + 2
                local out_of_reach = dx > melee_reach(context.analysis_of(target)) + 70 or dz > 100
                -- A mode that burns MP is worth entering while the target is held, or is near enough to be fought
                -- soon (not while it wanders far off, or off our line); one that costs nothing whenever it is safe.
                local timely = (shield and dx < 500 and dz < 120)
                    or draining and (opening or (out_of_reach and dx < 360 and dz < 60)) or (not draining and (opening or out_of_reach))
                if wanted and (shield and max(mode.worth or 0, 2) or (mode.worth or 0)) >= 1.2 and timely
                   and not earliest_threat(state, index, self, candidate.ready + 6, nil, level.reaction, context) then
                    start(self, candidate, target)
                    memory.mode_tried = state.frame_number
                    memory.note = "enter mode"
                    return
                end
            end
        end
    end

    -- A target held harmless and hittable (a trap's victim) long enough to be walked up to and struck, while MP
    -- is short of the fighter's strong moves and the hold has time to spare: MP is charged first, as long as the
    -- hold keeps the target harmless, and the strong move lands before it ends — a blow now would only set the
    -- target free for a punch's worth.
    local walk_to = max(0, abs(target.x_int - self.x_int) - melee_reach(context.analysis_of(self)) - 20) / ((self.record.movement or {}).walking_speed or 4)
    local held_open = tframe.state == states.caught and target_lock > 25 and target_lock > walk_to + 10
        and untouchable_for(context, target, tframe.state, target_lock) <= walk_to
    if held_open and self.y_int == 0 and fstate ~= states.running and self.mp < special_mp(context.analysis_of(self))
       and target_lock >= walk_to + 30 and not threat_t then
        for _, candidate in ipairs(context.analysis_of(self).moves) do
            if candidate.charge and can_start(self, frame, fstate, candidate)
               and not earliest_threat(state, index, self, 24, nil, level.reaction, context) then
                start(self, candidate, target)
                memory.note = "charge (target held)"
                return
            end
        end
    end

    -- Attacking (a slow move too, when the target is held long enough for it).
    local move, t, score = best_attack(context, self, frame, fstate, target, horizon_ticks - 5, danger)
    -- Not into a blow already on its way: a move whose path meets an enemy's attack in progress before it lands is
    -- left alone (the next best is tried). Against the target's quickest answer along that path (a rush ends
    -- inside the arms of a target whose blows do not reach where it started, and a blow it starts as we set off
    -- lands first there), the move is weighed: worth starting when what it brings, if the answer does not come,
    -- outweighs the answer's damage by how often this target has answered so far (worth_the_risk). Standing off
    -- is no answer to a target with long arms either. (Weighed against a free target, or one free again before
    -- we land.)
    local excluded, checked, at_risk
    for _ = 1, 4 do
        checked, at_risk = false, false
        if not (move and score > tune.attack_threshold) then break end
        local plan, frames_at = move_path(self, move, target)
        local into = earliest_threat(state, index, self, t - 1, plan, level.reaction, context, frames_at)
        local reason = into and "into" or nil
        if not into and not (target_pressure and target_pressure < 0.2) and t >= 4 then
            local along, along_damage = counter_along(context, target, self, target_lock, plan, frames_at)
            if along and (along < t or (along == t and target_lock > 0)) then
                if worth_the_risk(memory, score, t, along_damage) > tune.attack_threshold then at_risk = true
                else into = true; reason = "along" end
            end
        end
        if not into then checked = true; break end
        if smart.on_exclude then smart.on_exclude(self, move, reason, t) end
        excluded = excluded or {}
        excluded[move] = true
        move, t, score = best_attack(context, self, frame, fstate, target, horizon_ticks - 5, danger, excluded)
    end
    if move and not checked then move = nil end
    if smart.trace then
        smart.trace(state, index, string.format("lock %d untouchable %d danger %s best %s t%s s%.1f", target_lock,
            untouchable_for(context, target, tframe.state, target_lock), tostring(danger),
            move and (move.entry.field or move.entry.basic or "chain") or "-", tostring(t), score or 0))
    end
    if move and score > tune.attack_threshold then
        start(self, move, target, t, score)
        memory.last_use[move.index] = state.frame_number
        if at_risk then
            memory.risk_starts = (memory.risk_starts or 0) + 1
            memory.risky = {hp = self.hp, ends = state.frame_number + t}
        end
        memory.note = string.format("attack %s%s f%s t%d s%.1f%s", move.entry.field or move.entry.basic or ("chain " .. move.entry.key),
            move.entry.chain and "+" or "", tostring(move.entry.frame or move.entry.press), t, score, at_risk and " risk" or "")
        return
    end

    local grounded = self.y_int >= 0
    -- Healing (a move whose frames restore HP, see explore: Marco's phoenix in One Piece GrandWorld): when much of
    -- the HP lost can still come back, MP allows for it, and nothing can reach us on its way — its frames out of
    -- the target's reach (positioning.far_reach), or the target held, or far off, for as long.
    if grounded and self.dark_hp - self.hp >= 60 and (fstate == states.standing or fstate == states.walking) then
        for _, candidate in ipairs(context.analysis_of(self).moves) do
            if candidate.heal and not candidate.weapon and not candidate.entry.parent and self.mp >= candidate.mp + 20
               and can_start(self, frame, fstate, candidate) then
                -- (Its first few frames, the keys on the way into it — a guard's — may be ordinary ones.)
                local safe = target_lock > candidate.length or abs(target.x_int - self.x_int) > 450
                    or positioning.move_shielded(self.record, candidate, far, 4)
                if safe then
                    local plan, frames_at = move_path(self, candidate, target)
                    if not earliest_threat(state, index, self, min(candidate.length, 40), plan, level.reaction, context, frames_at) then
                        start(self, candidate, target)
                        memory.note = "heal"
                        return
                    end
                end
            end
        end
    end
    -- Jumping in, or dashing out of the run: when a move from the air would land as the fighter flies at the
    -- target (its moves in the air are as much its own as those on the ground), and nothing reaches it as it
    -- takes off. Not twice in a row: a landing is a moment to be used, not to jump again.
    if grounded and not threat_t and target.y_int >= 0 and (memory.next_jump or 0) <= state.frame_number
       and self.weapon ~= record_kinds.heavy_item
       and (fstate == states.standing or fstate == states.walking or fstate == states.running) then
        local distance = abs(target.x_int - self.x_int)
        if distance > 50 and distance < 460 then
            local jump_move, jump_t, jump_score, lead, flight, flight_frames = approach_attack(context, self, fstate, target, danger)
            if jump_move and jump_score > tune.attack_threshold then
                local dir = target.x_int >= self.x_int and 1 or -1
                local movement = self.record.movement or {}
                local speed = fstate == states.running and (movement.dash_distance or 0) or (movement.jump_distance or 0)
                local plan = function(k) return trunc(dir * speed * max(k - lead, 0)), 0, 0 end
                -- (The target, free or free in time, may strike the fighter out of the air before its own blow
                -- lands: weighed as for the moves on the ground.)
                local met, jump_risk = false, false
                if not (target_pressure and target_pressure < 0.2) then
                    local along, along_damage = counter_along(context, target, self, target_lock, flight, flight_frames)
                    if along ~= nil and along <= jump_t then
                        if worth_the_risk(memory, jump_score, jump_t, along_damage) > tune.attack_threshold then jump_risk = true else met = true end
                    end
                end
                if not met and not earliest_threat(state, index, self, lead + 6, plan, level.reaction, context) then
                    if jump_risk then
                        memory.risk_starts = (memory.risk_starts or 0) + 1
                        memory.risky = {hp = self.hp, ends = state.frame_number + jump_t}
                    end
                    fresh(self, "jump")
                    if fstate ~= states.running then press(self, dir > 0 and "right" or "left") end
                    -- (The direction held as the feet leave the ground sets the jump's speed.)
                    memory.jump_dir, memory.jump_hold = dir, state.frame_number + lead + 2
                    memory.next_jump = state.frame_number + tune.jump_cooldown
                    memory.note = string.format("jump in %s f%s t%d s%.1f", jump_move.entry.field or jump_move.entry.basic or "chain",
                        tostring(jump_move.entry.frame or jump_move.entry.press), jump_t, jump_score)
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
    -- nothing is about to reach us, and MP is wanted. (A target held hittable long enough to be walked up to and
    -- struck — a trap's victim; a fallen one gets up untouchable — is struck instead, see above. Not within the
    -- quick blows of a fallen target, nor of one blinking for any reason — up from a fall, or in a match's first
    -- frames: it can walk up and strike as its blink ends while nothing of ours lands on it meanwhile, and a stance
    -- takes time to leave; the way out of its reach comes first.)
    local in_wake = (target_down or target.blink ~= 0) and wake_escape(target, target_analysis, self)
    if grounded and fstate ~= states.running and self.mp < constants.points.full - tune.charge_below
       and (abs(target.x_int - self.x_int) > melee_reach(context.analysis_of(target)) + tune.charge_room or target_lock > 25)
       and not held_open and not in_wake then
        for _, candidate in ipairs(context.analysis_of(self).moves) do
            if candidate.charge and can_start(self, frame, fstate, candidate)
               and not earliest_threat(state, index, self, 24, nil, level.reaction, context) then
                start(self, candidate, target)
                memory.note = "charge"
                return
            end
        end
    end
    -- A drink in hand: drunk when HP or MP is wanted and nothing is about to reach us (the stance is left for a
    -- threat, see above).
    if grounded and self.weapon == record_kinds.drink and (fstate == states.standing or fstate == states.walking)
       and (self.hp < self.dark_hp - 30 or self.mp < constants.points.full - 100)
       and (abs(target.x_int - self.x_int) > melee_reach(context.analysis_of(target)) + 100 or target_lock > 25)
       and not in_wake and not earliest_threat(state, index, self, 24, nil, level.reaction, context) then
        for _, candidate in ipairs(context.analysis_of(self).moves) do
            if candidate.entry.basic == "drink" and can_start(self, frame, fstate, candidate) then
                start(self, candidate, target)
                memory.note = "drink"
                return
            end
        end
    end
    -- A weapon lying within a few steps, when nothing presses and the hands are empty: walk onto it and take
    -- it (the attack key over a lying weapon picks it up, base/game/combat pick_up).
    -- (Once on the way, on until the enemy is nearly within reach, and not off again at once after turning back:
    -- at the edge, the walk to the weapon and the step back from the enemy could take turns frame by frame —
    -- likeliest at low MP, when a drink is worth fetching.)
    local fetching = memory.to_weapon == state.frame_number - 1
    if grounded and self.weapon == weapon_none and not threat_t and not in_wake
       and (fstate == states.standing or fstate == states.walking or fstate == states.running)
       and (target_lock >= 15 or ((fetching or state.frame_number - (memory.weapon_left or -999) > 30)
            and abs(target.x_int - self.x_int) > melee_reach(context.analysis_of(target)) + (fetching and 40 or 90))) then
        local pick = weapon_to_take(state, self, target)
        if pick then
            memory.to_weapon = state.frame_number
            local wdx, wdz = pick.x_int - self.x_int, pick.z_int - self.z_int
            if fstate == states.running then
                -- Running: on past a weapon still far ahead; stopped (the key against the run) near it or behind it.
                local ahead = (wdx > 0) == (self.facing == facing_right)
                if not ahead or abs(wdx) < 70 then press(self, self.facing == facing_right and "left" or "right") end
                memory.note = "to weapon"
                return
            end
            if over_weapon(self, frame, pick) then
                fresh(self, "attack")
                memory.note = "pick up"
                return
            end
            if wdx > 4 then press(self, "right") elseif wdx < -4 then press(self, "left") end
            if wdz > 2 then press(self, "down") elseif wdz < -2 then press(self, "up") end
            memory.note = "to weapon"
            return
        end
    end

    -- Positioning.
    if fstate == states.jumping or fstate == states.dashing then
        if memory.jump_dir and self.y_int == 0 and state.frame_number <= (memory.jump_hold or 0) then
            press(self, memory.jump_dir > 0 and "right" or "left")
        else
            face(self, target.x_int)
            -- A flight that steers in depth (frames with dvz: Marco's phoenix in One Piece GrandWorld): onto the
            -- target's line.
            local dz = target.z_int - self.z_int
            if frame.dvz ~= 0 and abs(dz) > 3 then press(self, dz > 0 and "down" or "up") end
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
    -- Standing, not turned toward the target either (turning round is a step toward it: into its reach, here).
    local keep_facing = false
    -- How much a free enemy's quick blows must threaten a spot for it to be left (more as a standoff drags on).
    local keep_out = tune.keep_out_base + tune.keep_out_aggression * context.aggression
    local width = state.stage_bound > 0 and state.stage_bound or (state.stage.width or constants.screen.width)
    local near_z, far_z = state.stage.zboundary[1] or 0, state.stage.zboundary[2] or 0
    local coming = target.y_int < 0 and tframe.state ~= states.caught and abs(dz) < 32 and abs(dx) < 420
        and (target.vx == 0 or (target.vx > 0) == (dx < 0))
    if coming and target_lock == 0 and not shielded then
        -- An enemy in the air keeps its depth until it lands: leave its line before it strikes.
        if dz >= 0 then want_dz = -1 else want_dz = 1 end
        if want_dz < 0 and self.z_int - near_z < 12 then want_dz = 1 end
        if want_dz > 0 and far_z - self.z_int < 12 then want_dz = -1 end
        keep_facing = true
        memory.note = "leave air line"
    elseif target_lock == 0 and not (target_pressure and target_pressure < 0.2) and not shielded
           and danger_at(target, context.analysis_of(target), self.x_int, self.z_int) >= keep_out - (memory.leaving == state.frame_number - 1 and 20 or 0) then
        -- Where the free enemy's quick, strong moves land: step to the nearest spot they do not reach (and on
        -- out of them for a while once started, rather than stepping in and out at their edge). An opponent
        -- that hardly attacks is not kept out of reach of.
        -- (Each way is judged by the best spot it passes within six steps, not by the one spot six steps off: a
        -- narrow safe band between two zones was otherwise stepped past from either side, the fighter turning
        -- back and forth at its edge every frame; the way taken last frame keeps a little of its favour.)
        memory.leaving = state.frame_number
        local analysis = context.analysis_of(target)
        local movement = self.record.movement or {}
        local speed_x, speed_z = movement.walking_speed or 4, movement.walking_speedz or 2
        local way = memory.leave_way
        local best_dx, best_dz, best_value
        for ox = -1, 1 do
            for oz = -1, 1 do
                local value
                for k = 1, 6 do
                    local x, z = self.x_int + ox * speed_x * k, self.z_int + oz * speed_z * k
                    if x > 20 and x < width - 20 and z >= near_z and z <= far_z then
                        local spot = danger_at(target, analysis, x, z) + abs(abs(target.x_int - x) - range) * 0.05 + k * 0.3
                        if not value or spot < value then value = spot end
                    end
                    if ox == 0 and oz == 0 then break end
                end
                if value and way and way[1] == ox and way[2] == oz then value = value - 2 end
                if value and (not best_value or value < best_value) then best_dx, best_dz, best_value = ox, oz, value end
            end
        end
        want_dx, want_dz = best_dx or 0, best_dz or 0
        memory.leave_way = {want_dx, want_dz}
        keep_facing = want_dx == 0
        memory.note = "leave reach"
    else
        -- Toward the target until a move reaches it (nothing did this frame), unless much too close; against
        -- longer arms, just outside them until the target commits.
        -- Just outside a free enemy's arms (unless ours are clearly longer): it has to come to us, and walks
        -- into our blow; a long standoff ends the patience.
        local hold = shielded and max(positioning.mode_reach(context.analysis_of(self), mode_now) - 15, 30) or range
        local their_reach = melee_reach(context.analysis_of(target)) + 25
        if their_reach > range - 10 and target_lock == 0 and context.aggression < 0.5 and (target_pressure or 1) >= 0.2 and not shielded then
            hold = max(range, their_reach + tune.hold_margin)
            -- Short of MP for the fighter's strong moves, with a charge of its own: far enough off to charge (see
            -- there: beyond the target's quick reach and 85 more), rather than waiting at the edge of its arms with
            -- little to strike with. (The distance kept is from hold - 50 to hold - 20.)
            if self.mp < min(special_mp(context.analysis_of(self)), 200) and positioning.can_charge(context.analysis_of(self)) then
                hold = max(hold, their_reach + tune.charge_gap)
            end
        end
        -- A target down, or up and still blinking: nothing of ours lands on it until the blinking ends, while it
        -- can strike as soon as it is on its feet — with whatever quick blow it has, however far that reaches
        -- (a wood spike across half the stage in Naruto: The Setting Dawn). Where those blows strike is left by
        -- the time it is up, by the quicker way: in depth (a few steps off its line) or back out of their reach;
        -- off its line, we may close in x and wait there. (Not against one that hardly ever attacks.)
        local untouchable = untouchable_for(context, target, tframe.state, target_lock)
        local waking, edge_note = false, nil
        if untouchable > 0 and target_waking and not (target_pressure and target_pressure < 0.2) and not shielded then
            local zone_z, zone_x = wake_zone(target, target_analysis, distance)
            if zone_z > 0 then
                waking = true
                memory.respecting = state.frame_number
                local low = self.hp < 120
                if low then zone_z, zone_x = zone_z + 6, zone_x + 30 end
                -- (On its feet, it can step in depth before it strikes: a step's worth more — reckoned while it is
                -- still down too, as that is where its blows reach once it is up. Counted only from then, a fighter
                -- just off its line was inside again as it rose, and on a shallow stage with no room left for the
                -- step, caught there: Rock Lee beside a fallen Neji, Hot Springs in Naruto: The Setting Dawn. With
                -- no room for it, the way out is back out of their reach.)
                zone_z = zone_z + tune.wake_step
                if abs(dz) < zone_z then
                    local movement = self.record.movement or {}
                    local tx = (zone_x - distance) / (movement.walking_speed or 4)
                    local away = dx > 0 and -1 or 1
                    local walled = (away < 0 and self.x_int < 80) or (away > 0 and self.x_int > width - 80)
                    -- The side of its line we are on, when the stage has room there for the zone's depth; else the
                    -- other (and the side once chosen is kept: at its very depth, the side we are on changes with
                    -- every step). The room is counted from its line, where the zone is, not from us: counted from
                    -- us it shrank as we walked there, and on a shallow stage (Hot Springs in Naruto: The Setting
                    -- Dawn, 60 deep) the side flipped every few steps — the fighter walked to and fro on the line
                    -- of the fallen enemy until it got up.
                    local function room_on(side) return side < 0 and (target.z_int - near_z) or (far_z - target.z_int) end
                    local side = memory.wake_side or (dz > 0 and -1 or 1)
                    if room_on(side) < zone_z + 1 and room_on(-side) > room_on(side) then side = -side end
                    local room = room_on(side)
                    memory.wake_side = side
                    -- Frames to be out in depth: from where we are, across its line first when the side with room
                    -- is the other one.
                    local across = (side < 0) ~= (dz > 0)
                    local tz = (zone_z + (across and abs(dz) or -abs(dz))) / (movement.walking_speedz or 2)
                    -- (And the way out once chosen — in depth or back along x — is kept: each step changes which
                    -- is quicker, and the fighter otherwise went one way and the other in turn.)
                    local way = memory.wake_way
                    if not way then
                        way = ((tz <= tx or walled) and room >= zone_z + 1 or walled) and "z" or "x"
                        memory.wake_way = way
                    end
                    if way == "x" and not walled then want_dx = away else want_dz = side end
                    keep_facing = true
                    memory.note = string.format("leave wake-up zone %d %d (z %d x %d)", want_dx, want_dz, zone_z, zone_x)
                else
                    memory.wake_way = nil
                    -- Off its line: keep this depth; in x, about our own range away (not beside it: a step in
                    -- depth would put it back on us). (Not farther: waiting out of its plain arms instead, the fighter
                    -- took fewer blows from enemies getting up but left them the first move — 136–168 against version
                    -- 27 in Naruto: The Setting Dawn.)
                    local away = dx > 0 and -1 or 1
                    local walled = (away < 0 and self.x_int < 80) or (away > 0 and self.x_int > width - 80)
                    want_dx = positioning.keep_distance(self, dx, distance, range - tune.off_line_near, range + tune.off_line_far, not walled) * (dx > 0 and 1 or -1)
                    memory.note = string.format("wait off line %d (z %d)", want_dx, zone_z)
                end
            end
        end
        if not waking then
            memory.wake_side, memory.wake_way = nil, nil
            -- (No stepping back with a wall a couple of steps behind: stopped by it, the fighter would turn round
            -- — a step forward — and step back again.)
            local step = (self.record.movement or {}).walking_speed or 4
            local walled = (dx > 0 and self.x_int < 80 + 2 * step) or (dx < 0 and self.x_int > width - 80 - 2 * step)
            want_dx = positioning.keep_distance(self, dx, distance, max(hold - 50, 8), max(hold - 20, 10), target_lock == 0 and not walled) * (dx > 0 and 1 or -1)
            -- Nor a step back into where the blows of a target getting up strike (just stepped out of: they reach
            -- further as we near it): we wait at their edge, turned toward it (turning round, a step toward it,
            -- only once a step further out leaves room for it).
            if untouchable > 0 and target_waking and not (target_pressure and target_pressure < 0.2) and not shielded then
                local toward = dx > 0 and 1 or -1
                local facing_away = (dx > 0) == (self.facing == facing_left)
                if want_dx == toward or (want_dx == 0 and facing_away and distance >= 6) then
                    local d = max(distance - ((self.record.movement or {}).walking_speed or 4), 0)
                    local zone_z = wake_zone(target, target_analysis, d)
                    if zone_z > 0 then
                        if self.hp < 120 then zone_z = zone_z + 6 end
                        zone_z = zone_z + tune.wake_step
                    end
                    if zone_z > 0 and abs(dz) < zone_z then
                        want_dx = facing_away and -toward or 0
                        edge_note = "wait at wake-up zone"
                    end
                end
            end
        end
        if want_dx ~= 0 and (want_dx < 0) == (dx > 0) and ((want_dx < 0 and self.x_int < 80) or (want_dx > 0 and self.x_int > width - 80)) then
            want_dx = 0
        end
        -- A free target whose long blows (a beam, a sweep: Neji's in Naruto: The Setting Dawn) cover the line
        -- between us is approached beside that line, in depth, and the line is only stepped onto once our own
        -- blows are about to reach: straight along it, every step is into its arms.
        -- (Also when it is busy for now but free again before we could be there, and with its MP counted as it will
        -- be by then: a wave it cannot afford yet comes once it can — charging, Neji in NTSD 2.4 soon can.)
        local line_z
        if target_lock * 10 < distance - range and distance > range + 40 and not (target_pressure and target_pressure < 0.2) and not shielded then
            for _, zone in ipairs(positioning.long_zones(target_analysis)) do
                if target.mp + 150 >= zone.mp and zone.x2 >= distance - 40 and zone.x1 <= distance + 40 then
                    line_z = max(line_z or 0, zone.z + 10)
                end
            end
        end
        if waking then
            -- (The depth was settled above.)
        elseif line_z then
            local room_near, room_far = self.z_int - near_z, far_z - self.z_int
            if abs(dz) < line_z then
                -- Off the line, to the side with room (the side already on, when both have it).
                local away = dz > 0 and -1 or 1
                if (away < 0 and room_near < line_z + 6 and room_far > room_near) or (away > 0 and room_far < line_z + 6 and room_near > room_far) then
                    away = -away
                end
                want_dz = away
            elseif abs(dz) > line_z + 40 then
                want_dz = dz > 0 and 1 or -1
            end
            memory.note = edge_note or string.format("approach off line %d %d (z %d)", want_dx, want_dz, line_z)
        else
            if abs(dz) > range_z then want_dz = dz > 0 and 1 or -1 end
            memory.note = edge_note or string.format("move %d %d (hold %d)", want_dx, want_dz, hold)
        end
        -- Two on one: a teammate already fighting the target from this side → round to the other side, in
        -- depth first (not through the target's arms), then past it.
        if mate_on_side(state, index, self, target) and distance < 260 then
            if abs(dz) < 36 then
                want_dx = 0
                want_dz = (far_z - self.z_int > self.z_int - near_z) and 1 or -1
            else
                want_dx = dx > 0 and 1 or -1
                want_dz = 0
            end
            memory.note = "flank"
        end
        -- XOI: the spots training found better or worse to stand on against this opponent, both free. Not a step
        -- into one clearly worse than where we stand; on to one clearly better within a few steps (and on that way
        -- for a few frames). Clearly: by more than either may be off (spots seldom visited may be far off), and by
        -- more again the longer a standoff has lasted — the rules above then have their way. (The same test both
        -- ways: a step allowed in is never one to step back out of.)
        local spots = context.notes_spots
        if spots and not waking and not shielded and tframe.state <= states.running and target.y_int == 0 then
            local movement = self.record.movement or {}
            local sx, sz = movement.walking_speed or 4, movement.walking_speedz or 2
            local faces_right = target.facing == facing_right
            local here, here_se, here_visits = positioning.spot_value(spots, dx, dz, faces_right == (self.x_int >= target.x_int))
            local margin = 6 * context.aggression
            local function after(ox, oz, k)
                local x, z = self.x_int + ox * sx * k, self.z_int + oz * sz * k
                if x < 20 or x > width - 20 or z < near_z or z > far_z then return nil, 0, 0 end
                return positioning.spot_value(spots, target.x_int - x, target.z_int - z, faces_right == (x >= target.x_int))
            end
            local way = memory.spot_way
            local going = false
            if way and state.frame_number <= (memory.spot_until or -1) then
                local v, se = after(way[1], way[2], 3)
                if v and v + se >= here - here_se then
                    want_dx, want_dz, going = way[1], way[2], true
                    memory.note = "spot: on"
                end
            end
            if not going then
                memory.spot_way = nil
                if here_visits >= 5 then
                    local best_v, bx, bz
                    for ox = -1, 1 do
                        for oz = -1, 1 do
                            if ox ~= 0 or oz ~= 0 then
                                for k = 3, 6, 3 do
                                    local v, se, visits = after(ox, oz, k)
                                    if v and visits >= 5 then
                                        v = v - se - k * 0.1
                                        if not best_v or v > best_v then best_v, bx, bz = v, ox, oz end
                                    end
                                end
                            end
                        end
                    end
                    if best_v and best_v > here + here_se + margin then
                        want_dx, want_dz, going = bx, bz, true
                        memory.spot_way, memory.spot_until = {bx, bz}, state.frame_number + 8
                        memory.note = string.format("spot: to %d %d", bx, bz)
                    end
                end
            end
            if not going and (want_dx ~= 0 or want_dz ~= 0) and here_visits >= 5 then
                local floor_v = here - here_se - margin
                local v, se, visits = after(want_dx, want_dz, 3)
                if v and visits >= 5 and v + se < floor_v then
                    local both = want_dx ~= 0 and want_dz ~= 0
                    local vx, sex = nil, 0
                    local vz, sez = nil, 0
                    if both then
                        vx, sex = after(want_dx, 0, 3)
                        vz, sez = after(0, want_dz, 3)
                    end
                    if vx and vx + sex >= floor_v then want_dz = 0
                    elseif vz and vz + sez >= floor_v then want_dx, keep_facing = 0, true
                    else want_dx, want_dz, keep_facing = 0, 0, true end
                    memory.note = "spot: hold"
                end
            end
        end
        -- Not back into the quick blows of a free enemy just stepped out of: a step toward it, in x or onto its
        -- depth, waits at their edge (or comes once the standoff has made the fighter bolder), rather than in and
        -- out of them every few frames, turning round each time.
        local closer_x = want_dx ~= 0 and (want_dx > 0) == (dx > 0)
        local closer_z = want_dz ~= 0 and (want_dz > 0) == (dz > 0)
        if (closer_x or closer_z) and target_lock == 0 and not waking and not (target_pressure and target_pressure < 0.2)
           and not shielded and state.frame_number - (memory.leaving or -999) < 45 then
            local movement = self.record.movement or {}
            local x = self.x_int + want_dx * (movement.walking_speed or 4) * 3
            local z = self.z_int + want_dz * (movement.walking_speedz or 2) * 3
            if danger_at(target, target_analysis, x, z) >= keep_out then
                if closer_x then want_dx, keep_facing = 0, true end
                if closer_z then want_dz = 0 end
                memory.note = "hold off reach"
            end
        end
    end
    local near, far = state.stage.zboundary[1] or 0, state.stage.zboundary[2] or 0
    if want_dz < 0 and self.z_int - near < 6 then want_dz = 0 end
    if want_dz > 0 and far - self.z_int < 6 then want_dz = 0 end
    -- Nor toward the depth of something flying at us along it.
    local flying_z = want_dz ~= 0 and not shielded and positioning.flying_line(state, index, self)
    if flying_z and (want_dz > 0) == (flying_z > self.z_int) then
        want_dz = 0
        memory.note = tostring(memory.note) .. " (not onto its line)"
    end
    -- Not a step into a blow that misses where we stand (turning toward the target is a step too).
    local turn = want_dx == 0 and not keep_facing and abs(dx) >= 6
        and ((dx > 0 and self.facing == facing_left) or (dx < 0 and self.facing == facing_right))
    -- And not round again within a few frames of turning round (no thumb goes left, right, left that fast): with
    -- nothing on its way, a turn asked for so soon waits, the fighter standing (or stepping in depth) meanwhile.
    if (turn or (want_dx ~= 0 and (want_dx > 0) ~= (self.facing == facing_right))) and not threat_t
       and memory.turned_at and state.frame_number - memory.turned_at < 3 then
        want_dx, turn = 0, false
        memory.note = tostring(memory.note) .. " (wait to turn)"
    end
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
            -- (Not steered into a blow on its way: a run steered back onto the target's line, out of which a
            -- wave along it was just dodged, met the next one. The run's sideways step is counted a little wide:
            -- the forecast runs short of it.)
            local speedz = ((self.record.movement or {}).running_speedz or 2) + 1.5
            local vx = self.vx
            local plan = function(k) return trunc(vx * k), 0, trunc(want_dz * speedz * k) end
            if (want_dz > 0) ~= (dz > 0) or not earliest_threat(state, index, self, 12, plan, level.reaction, context) then
                press(self, want_dz > 0 and "down" or "up")
            else
                memory.note = tostring(memory.note) .. " (not onto its line)"
            end
        end
        return
    end
    -- A mode that runs instead of walking (Gear Second: a direction starts a run that goes on until a key ends it,
    -- and cannot turn): from rest, a tap toward a far target or away from a close one, with the depth key held
    -- when the target is off our line; running, the stop key once near enough (or far enough, on a run away),
    -- once past the target or at a wall; nothing else moves (a direction at rest would start the run).
    if mode_now and not mode_moving and not mode_resting then memory.mode_run_goal = nil end
    if mode_now and mode_now.runs_on and (mode_resting or mode_moving) then
        local toward = dx > 0 and "right" or "left"
        local away = dx > 0 and "left" or "right"
        local hold = memory.respecting == state.frame_number and range + 60 or range
        local off_line = abs(dz) > range_z + 6
        local zkey = dz > 0 and "down" or "up"
        local run_speed = mode_now.run_speed or 20
        local function run_plan(dir) return function(k) return trunc(dir * run_speed * k), 0, 0 end end
        -- Out of the target's reach in the mode (shielded): up to where the mode's own blows strike, and onto its
        -- line (the run steers in depth as it goes; past the target, it stops and comes back).
        if shielded then hold = max(positioning.mode_reach(context.analysis_of(self), mode_now) - 15, 30) end
        if mode_moving then
            local heading = self.vx > 0 and 1 or (self.vx < 0 and -1 or (self.facing == facing_right and 1 or -1))
            local goal = memory.mode_run_goal or "toward"
            local at_wall = (heading < 0 and self.x_int < 70) or (heading > 0 and self.x_int > width - 70)
            local done
            if goal == "away" then
                done = distance > hold + 60 or heading == (dx > 0 and 1 or -1)
            elseif shielded then
                done = (distance < hold + 10 and not off_line) or heading ~= (dx > 0 and 1 or -1)
            else
                done = distance < hold + 30 or heading ~= (dx > 0 and 1 or -1)
            end
            -- Not on into a blow on its way across the run's path.
            local into = not done and earliest_threat(state, index, self, 8, run_plan(heading), level.reaction, context)
            if done or at_wall or into then
                if mode_now.stop_key then fresh(self, mode_now.stop_key) else press(self, heading > 0 and "left" or "right") end
                memory.note = "mode run: stop"
            else
                if off_line then press(self, zkey) end
                memory.note = "mode run"
            end
        elseif threat_t then
            memory.note = string.format("mode rest (hold %d)", hold)
        elseif (distance > hold + 90 or (shielded and (distance > hold + 10 or off_line)))
               and not earliest_threat(state, index, self, 10, run_plan(dx > 0 and 1 or -1), level.reaction, context) then
            fresh(self, toward)
            if off_line then press(self, zkey) end
            memory.mode_run_goal = "toward"
            memory.note = "mode run: go"
        elseif target_lock == 0 and abs(dz) < 60 and not shielded
               and (distance < melee_reach(context.analysis_of(target)) + 30
                    or ((mode_now.drain or 0) > 0 and self.mp < 20 and distance < melee_reach(context.analysis_of(target)) + 110)) then
            -- Inside a free target's arms (the mode may have no guard): out of them. A draining mode about to
            -- end (the fighter is left tired for a while when its MP runs out): out of them by a wide margin.
            fresh(self, away)
            if off_line then press(self, zkey) end
            memory.mode_run_goal = "away"
            memory.note = "mode run: back"
        else
            -- (Off the target's line too: the run moves little in depth, and the target comes onto our line by
            -- itself; a jump of the mode's own does not steer either.)
            memory.note = string.format("mode rest (hold %d)", hold)
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
-- A fighter's moves, and those of its modes (so that nothing is left to learn once the match runs).
local function learn(record)
    local analysis = analyze(record)
    for _, mode in pairs(analysis.modes or {}) do armed_analysis(record, mode.record, #analysis.moves + 1) end
end

function smart.prepare(state)
    notes_checked = nil
    for index = 0, constants.item_slots - 1 do
        local value = state.items[index]
        if value and value.record.kind == record_kinds.character then learn(value.record) end
    end
    if state.stage_run then
        for _, id in ipairs(require("base/game/stage").enemy_ids(state.stage_run)) do
            local record = objects.record(state, id)
            if record and record.kind == record_kinds.character then learn(record) end
        end
    end
end

-- For the test bench.
smart.internals = {earliest_threat = earliest_threat, where_of = where_of, analyze = analyze, move_hits = move_hits,
    danger_at = danger_at, danger_zones = danger_zones, melee_reach = melee_reach, best_attack = best_attack,
    enemy_reach = enemy_reach, defend_ticks = defend_ticks, target_lock_of = target_lock_of, armed_analysis = armed_analysis,
    stance_exit = stance_exit, lock_of = lock_of, new_sandbox = new_sandbox, sandbox_step = sandbox_step, arm = arm,
    set_keys = set_keys}
return smart
