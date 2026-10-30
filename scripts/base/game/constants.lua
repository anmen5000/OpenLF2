-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

-- Original mode IDs are stored in recordings.
return {
    modes = {
        versus = 0,
        stage = 1,
        championship = 2,
        team_championship = 3,
        battle = 4,
        demo = 5,
    },
    -- The title menu's last two entries; unlike the modes above they are never stored in a recording.
    title_entries = {
        replay = 6,
        quit = 7,
    },
    -- The championship setup screen's state machine (`state.state`), in the order a tournament runs through them.
    championship_states = {
        setup = 0x14,
        selecting = 0x15,
        confirming = 0x16,
        shuffling = 0x17,
        randomizing = 0x18,
        options = 0x19,
        next_pair = 0x1a,
        claiming = 0x1b,
        round_over = 0x1c,
        finished = 0x1d,
    },
    championship_selection_steps = {
        fighter = 0,
        controller = 1,
    },
    two_choice_rows = {
        first = 0,
        second = 1,
    },
    font_variants = {
        white = 0,
        blue = 1,
        red = 2,
        green = 3,
        yellow = 4,
        magenta = 5,
    },
    -- Result codes written to each participant's recording result field.
    recording_results = {
        defeat = -1,
        draw = 0,
        victory_dead = 1,
        victory_alive = 2,
    },
    fusion_states = {
        unmerged = -1,
        merged = 1,
    },
    -- The battle setup screen's states; the troop picker takes `troop_picker` up to `troop_picker_end - 1`.
    battle_setup_states = {
        panel = 200,
        random_fighters = 201,
        options = 202,
        troop_picker = 210,
        troop_picker_end = 220,
    },
    character_slot_phases = {
        empty = 0,
        choosing_fighter = 1,
        choosing_team = 2,
        ready = 3,
        computer_fighter = 11,
        computer_team = 12,
        computer_ready = 13,
    },
    character_menus = {
        human_slots = 0,
        computer_count = 1,
        computer_slots = 2,
        options = 3,
    },
    combo_states = {
        idle = 0,
        defend_pressed = 1,
        second_pressed = 2,
        complete = 3,
    },
    -- Indices into each item's sequences array and control.lua's sequence definitions.
    combo_indices = {
        right_attack = 1,
        left_attack = 2,
        up_attack = 3,
        down_attack = 4,
        right_jump = 5,
        left_jump = 6,
        up_jump = 7,
        down_jump = 8,
        jump_attack = 9,
    },
    -- opoint.facing's units digit: all other values force the spawned object to face right.
    opoint_facing_modes = {
        inherit = 0,
        opposite = 1,
    },
    catch_direction_controls = {
        none = 0,
        forward = 1,
        reverse = -1,
    },
    -- cpoint.cover's tens digit controls the caught character's facing.
    catch_facing_modes = {
        inherit = 1,
        opposite = 2,
    },
    input_devices = {
        keyboard = 0,
        controller_one = 1,
        controller_two = 2,
        controller_three = 3,
        controller_four = 4,
    },
    -- Key-history codes used by control.lua and the team-order recognizer (not virtual keys).
    key_history_codes = {
        jump = 0,
        down = 2,
        left = 4,
        attack = 5,
        right = 6,
        up = 8,
        defend = 9,
    },
    team_order_codes = {
        none = 0,
        move_to_marker = 100,
        follow = 102,
        cancel_follow = 104,
    },
    -- Shared options-panel rows; background selects a stage level in Stage mode.
    match_option_rows = {
        start = 0,
        reselect = 1,
        reroll = 2,
        background = 3,
        difficulty = 4,
        exit = 5,
    },
    battle_panel_rows = {
        defense = 0,
        first_upper = 1,
        reserve_upper = 2,
        first_lower = 3,
        reserve_lower = 4,
        troop_picker = 5,
        continue = 6,
    },
    -- The classic picture the game is drawn on, in pixels; stages are at least this wide.
    screen = {
        width = 794,
        height = 550,
    },
    -- Frame numbers below this are frames (the original's program has 400, 0-399; a mod's own program may allow
    -- more, and its data files then use them); 999 and above select what happens next instead.
    frame_limit = 999,
    -- Frame dvx/dvy/dvz above the threshold encode an absolute velocity as value - offset.
    velocity_encoding = {
        absolute_threshold = 500,
        absolute_offset = 550,
    },
    -- A frame's mp field combines MP cost (remainder) and HP cost (quotient * hp_unit).
    move_cost_encoding = {
        hp_radix = 1000,
        hp_unit = 10,
    },
    -- Special frame targets, interpreted by the engine rather than looked up in the record.
    frame_selectors = {
        return_to_standing = 999, -- airborne characters return to the airborne jump frame
    },
    input = {
        press_frames = 5,
        history_length = 5,
        run_double_tap_frames = 10,
        defend_lock_frames = 3,
    },
    combat = {
        default_zwidth = 15,
        max_hit_list_entries = 20,
        default_attack_rest = 4, -- minimum arest when no vrest was supplied
        defend_break_threshold = 31,
        knockdown_fall_points = 80,
    },
    -- timer_b8 must remain below the corresponding limit for innate armor to absorb a hit.
    armor_hit_timer_limits = {
        knight = 16,
        louis = 2,
        julian = 16,
    },
    teleport = {
        nearest_enemy_distance_limit = 10000,
        enemy_x_offset = 120,
        ally_x_offset = 60,
    },
    revival = {
        x_random_range = 51,
        x_offset = 26.0,
        z_random_range = 31,
        z_offset = 16.0,
        initial_y = -300,
    },
    blink = {
        defeated_frames = 30,
        get_up_frames = 15,
        frozen_tail_frames = 20,
        spawn_frames = 20,
    },
    -- The host's music volume is an affine function of the 0..maximum master setting.
    music_volume = {
        maximum = 100,
        muted = -10000,
        gain = 34,
        offset = 3900,
    },
    hit_sparks = {
        max_per_object = 10,
        position_range = 9,
        position_offset = 4,
    },
    damage = {
        dark_hp_divisor = 3,
    },
    camera_motion = {
        facing_lookahead = 130,
        fallback_focus_x = 800,
        target_distance_divisor = 14,
        previous_step_weight = 6,
        step_weight_divisor = 7,
    },
    world_edges = {
        ball_margin = 300.0,
        spawned_character_margin = 100.0,
        enemy_character_left_margin = 300.0,
        drink_margin = 10.0,
    },
    text_limits = {
        player_name_bytes = 10,
        player_name_field_bytes = 11, -- includes the terminator or network padding
        recording_field_bytes = 99,
    },
    random_table_size = 3000,
    recording = {
        hp_checksum_interval = 150,
    },
    network = {
        default_port = 12345,
        max_receive_buffer_bytes = 8192,
    },
    -- Counter value that completes the round, also used to skip the results screen.
    round_counters = {
        finished = 350,
    },
    sound_spatialization = {
        full_volume_radius = 200,
        audible_radius = 400,
        left_ear_offset = 200,
        right_ear_offset = 600,
    },
    -- regen_timer encodes remaining healing time above timer_base.
    healing = {
        timer_base = 1000,
        self_duration = 100,
        tick_frames = 8,
        points_per_tick = 8,
    },
    weapon_spawn = {
        max_existing = 4,
        chance_denominator = 200,
        initial_y = -500.0,
    },
    stage_spawn = {
        random_side_x = -1000,
        x_random_range = 300,
        outside_margin = 150,
        rare_enemy_denominator = 7,
        rare_enemy_hp_multiplier = 4,
    },
    stage_health = {
        crazy_multiplier = 1.5,
        easy_multiplier = 0.75,
    },
    stage_random_fighters = {
        count = 10,
        shuffle_swaps = 50,
    },
    -- All fusion limits are exclusive: both fighters must be below them.
    fusion = {
        hp_limit_exclusive = 177,
        x_distance_exclusive = 50,
        z_distance_exclusive = 8,
    },
    battle_strategies = {
        custom = -1,
        zero = 0,
        balanced = 1,
        inferior = 2,
        ranged_attack = 3,
        melee_attack = 4,
        giant = 5,
        full = 6,
    },
    battle_sizes = {
        custom = -1,
        small = 0,
        medium = 1,
        large = 2,
    },
    battle_presets = {
        scale_divisor = 3,
    },
    -- Exact accelerations per simulation step; preserve the original floating-point literals.
    gravity = {
        default = 1.7,
        drink = 1.1333333333333333,
        baseball = 0.85,
        thrown_boomerang = 0.16999999999999998,
        thrown_knife = 0.425,
        thrown_hoe = 1.1333333333333333,
        thrown_item = 0.5666666666666667,
    },
    landing = {
        bounce_vy = -3.5,
        max_bounce_speed_x = 7.0,
        bounce_speed_x_threshold = 9.0,
        bounce_speed_y_threshold = 11.0,
        frozen_bounce_speed_y_threshold = 17.0,
        frozen_impact_damage = 10,
    },
    -- Milk's intervals test the bottle's remaining HP, not a separate frame counter.
    milk = {
        hp_consumption = 1,
        hp_interval = 5,
        hp_gain = 4,
        dark_hp_gain = 2,
        mp_interval = 6,
        mp_gain = 5,
    },
    beer = {
        hp_consumption = 2,
        mp_gain = 3,
    },
    -- Hit and magic points: a fresh fighter has `full_points` of both (also the most MP a fighter can hold), a
    -- milk bottle in the stage mode heals to `milk_hp`.
    points = {
        full = 500,
        milk_hp = 200,
    },
    -- Background rows of the options: 100 picks a random one, 99 is the built-in Lee on the road.
    background_rows = {
        random = 100,
        lee_on_road = 99,
    },
    -- Defense of a battle side in tenths of a percent: 100 is the normal one, up to 300.
    defense = {
        normal = 100,
        maximum = 300,
    },
    -- Windows virtual-key codes, the key numbers of the host's input (F5 is the fast-forward key, F11 and F12 change
    -- the volume).
    virtual_keys = {
        backspace = 0x08,
        tab = 0x09,
        enter = 0x0d,
        shift = 0x10,
        escape = 0x1b,
        space = 0x20,
        left = 0x25,
        up = 0x26,
        right = 0x27,
        down = 0x28,
        f1 = 0x70,
        f9 = 0x78,
        f11 = 0x7a,
        f12 = 0x7b,
    },
    -- Item slots: 0-19 hold the fighters (players and computers), the rest spawned objects.
    item_slots = 400,
    first_spawned_slot = 20,
    -- facing 0 looks right, 1 left.
    facings = {
        right = 0,
        left = 1,
    },
    -- The frames of a weapon or other item: 0 is the one it flies and falls in.
    item_frames = {
        in_the_sky = 0,
    },
    difficulties = {
        -- OpenLF2's own level above CRAZY!: computer players that learn every fighter's moves (base/game/smart_ai).
        -- The game's rules otherwise play as in CRAZY!.
        insane = -2,
        crazy = -1,
        difficult = 0,
        normal = 1,
        easy = 2,
    },
    stage_groups = {
        final_story = 4,
        survival = 5,
    },
    stage_levels = {
        survival_start = 50,
    },
    -- Kind 4 is catalog `type: 4`, used only by baseball; kind 6 is `type: 6`, used by milk
    -- and beer.
    record_kinds = {
        character = 0,
        light_item = 1,
        heavy_item = 2,
        ball = 3,
        baseball = 4,
        prisoner = 5,
        drink = 6,
    },
    -- A holder's `weapon` field normally repeats the held item's record_kinds value; knife
    -- and boomerang are the one documented exception.
    -- The held item carries the negated code.
    weapon_holder_codes = {
        none = 0,
        knife_or_boomerang = 101,
    },
    -- Fighter record IDs from data/data.txt and object headers in the owner's
    -- v2.0a installer.
    fighter_ids = {
        template = 0,
        deep = 1,
        john = 2,
        henry = 4,
        rudolf = 5,
        louis = 6,
        firen = 7,
        freeze = 8,
        dennis = 9,
        woody = 10,
        davis = 11,
        bandit = 30,
        hunter = 31,
        mark = 32,
        jack = 33,
        sorcerer = 34,
        monk = 35,
        jan = 36,
        knight = 37,
        bat = 38,
        justin = 39,
        louis_ex = 50,
        firzen = 51,
        julian = 52,
    },
    record_ids = {
        criminal = 300,
        team_order_marker = 998,
    },
    -- Catalog boundaries used by original random fighter and weapon selection.
    record_id_ranges = {
        random_fighter_end_exclusive = 30,
        background_weapon_lower_exclusive = 99,
        background_weapon_end_exclusive = 200,
        -- Enemy characters of the stages (the bats and the bosses among them).
        enemy_character_first = 30,
        enemy_character_last = 49,
    },
    -- Special IDs in stage.dat entries.
    stage_record_selectors = {
        random_fighter = 1000,
        random_stage_enemy = 3000,
        random_stage_enemy_with_rare = 3001,
    },
    -- Frame state codes; special-state names follow the owner's v2.0a object frames.
    frame_states = {
        standing = 0,
        walking = 1,
        running = 2,
        attacking = 3,
        jumping = 4,
        dashing = 5,
        rowing = 6,
        defending = 7,
        broken_defend = 8,
        catching = 9,
        caught = 10,
        injured = 11,
        falling = 12,
        frozen = 13,
        lying = 14,
        dizzy = 16,
        drinking = 17,
        burning = 18,
        burning_run = 19,
        louis_dash_attack = 100,
        deep_dash_sword = 301,
        airborne_item = 1000,
        held_item = 1001,
        thrown_item = 1002,
        landed_light_item = 1003,
        resting_light_item = 1004,
        heal_self = 1700,
        flying_heavy_item = 2000,
        held_heavy_item = 2001,
        resting_heavy_item = 2004,
        flying_ball = 3000,
        ball_hiting = 3001,
        ball_hit = 3002,
        rebound_ball = 3003,
        object_disappearing = 3004,
        vanishing_ball = 3005,   -- not turned by other balls, no shadow, vanishes when reflected
        flying_missile = 3006,
        debris_piece = 9999,
        teleport_to_enemy = 400,
        teleport_to_ally = 401,
        transform_start = 500,
        transform_complete = 501,
        transform_louis_ex = 9995,
        louis_transform_shards = 9996,
        team_order_marker = 9997,
        removed = 9998,
    },
    -- States 8000–8999 encode the destination record as state - 8000.
    frame_state_ranges = {
        record_transform_start = 8000,
        record_transform_end_exclusive = 9000,
    },
    -- The frame numbers every character shares (the template frame table): the first frame of each named run,
    -- e.g. punch is 60-61 and 65-66, falling 180-191.
    character_frames = {
        standing = 0,
        walking = 5,
        running = 9,
        heavy_walking = 12,
        heavy_running = 16,
        heavy_stop_running = 19,
        weapon_attack = 20,
        jump_weapon_attack = 30,
        run_weapon_attack = 35,
        dash_weapon_attack = 40,
        light_weapon_throw = 45,
        heavy_weapon_throw = 50,
        jump_light_weapon_throw = 52,
        drinking = 55,
        punch = 60,
        super_punch = 70,
        jump_attack = 80,
        run_attack = 85,
        dash_attack = 90,
        dash_defend = 95,
        rowing = 100,
        defend = 110,
        broken_defend = 112,
        picking_light = 115,
        picking_heavy = 116,
        catching = 120,
        caught = 130,
        falling = 180,
        ice = 200,
        fire = 203,
        tired = 207,
        jump = 210,
        dash = 213,
        crouch = 215,
        stop_running = 218,
        crouch_alternate = 219,
        injured = 220,
        lying = 230,
        thrown_lying = 232,
    },
    -- The frames of a ball (a `flying_ball` object): 40 is the stars it dissolves into.
    ball_frames = {
        flying = 0,
        hitting = 10,
        hit = 20,
        rebounding = 30,
        vanishing = 40,
    },
    effects = {
        plain_hit = 0,
        sharp_hit = 1,
        burn = 2,
        freeze = 3,
        skip_characters = 4,
        burn_alt = 20,
        burn_state_guard = 21,
        burn_push = 22,
        burn_sound = 23,
        rebound = 30,
    },
    hit_fa_modes = {
        chase = 1,
        animated_chase = 2,
        projectile_chase = 3,
        healing_projectile = 4,
        ally_projectiles = 5,
        enemy_seeker = 6,
        returning_copy = 7,
        multi_seeker = 8,
        ranged_attack = 9,
        accelerating = 10,
        explosion = 11,
        unanimated_chase = 12,
        single_seeker = 13,
        special_chase = 14,
    },
    teleport_modes = {
        nearest_enemy = 1,
        farthest_ally = 2,
    },
    hit_list_results = {
        not_listed = 0,
        list = 1,
        skip = 2,
    },
    attack_kinds = {
        plain = 0,
        catch_nearest = 1,
        pick_up = 2,
        catch = 3,
        thrown_body = 4,
        held_item = 5,
        super_window = 6,
        rolling_pickup = 7,
        heal = 8,
        reflect_ball = 9,
        whirlwind = 10,
        conditional_whirlwind = 11,
        ignored_12 = 12,
        ignored_13 = 13,
        obstacle = 14,
        pulling_whirlwind = 15,
        freezing_whirlwind = 16,
    },
    -- A body of kind 1000 + N belongs to a criminal who turns to frame N when freed; stage mode lets only
    -- characters and some arrows touch them.
    body_kinds = {
        frame_base = 1000,
    },
    -- order_x / order_z of a fighter without a team order; `nearest` of one without a target in reach.
    no_order = -1000,
    nobody_near = 1000,
    cpoint_kinds = {
        holder = 1,
        caught = 2,
    },
    stage_entry_kinds = {
        soldier = 1,
        boss = 2,
    },
    -- opoint kind 1 is the ordinary (detached) spawn, the majority case in the owner's v2.0a
    -- catalog; it needs no special-case code beyond the kind > 0 spawn gate.
    opoint_kinds = {
        normal = 1,
        held_spawn = 2,
    },
    -- wpoint kinds 1 and 2 behave identically; only kind 3 (drop) changes behavior, so this
    -- may be an authoring-only distinction.
    wpoint_kinds = {
        primary = 1,
        secondary = 2,
        drop = 3,
    },
    recording_statuses = {
        starting = 1,
        saved = 2,
        cancelled = 3,
        error = 4,
    },
    teams = {
        independent = 0,
        player_one = 1,
        player_two = 2,
        player_three = 3,
        player_four = 4,
        enemies = 5,
        -- A fighter without a team gets its slot + 10: players 10-13, computers 20-27.
        slot_offset = 10,
        active_end_exclusive = 40,
    },
    item_ids = {
        stick = 100,
        hoe = 101,
        knife = 120,
        baseball = 121,
        boomerang = 124,
        stone = 150,
        wooden_box = 151,
        louis_armour = 217,
        louis_armour_two = 218,
        milk = 122,
        beer = 123,
        ice_sword = 213,
    },
    -- Names follow data/data.txt in the local v2.0a installer and the corresponding
    -- object files.
    object_ids = {
        john_ball = 200,
        henry_arrow = 201,
        rudolf_weapon = 202,
        deep_ball = 203,
        henry_wind = 204,
        dennis_ball = 205,
        woody_ball = 206,
        davis_ball = 207,
        henry_arrow_two = 208,
        freeze_ball = 209,
        firen_ball = 210,
        firen_flame = 211,
        freeze_column = 212,
        john_biscuit = 214,
        dennis_chase = 215,
        jack_ball = 216,
        jan_ally_chase = 219,
        jan_chase = 220,
        firzen_chase_fire = 221,
        firzen_chase_ice = 222,
        firzen_ball = 223,
        bat_ball = 224,
        bat_chase = 225,
        justin_ball = 226,
        julian_ball = 228,
        julian_ball_two = 229,
        broken_weapon = 999,
    },
}
