-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

-- Mods' AI scripts: ai/<id>.as beside the game, written for the community's AI script engine (a
-- ddraw.dll that mods such as Dragon Ball Super Edition ship; it runs AngelScript in the original
-- game). Its behaviour, which this follows:
-- - A script's `int ego()` runs in place of the original's special-move routine (base/game/ai's
--   `specials`) for computer players of that id, with `self` = the player and `target` = the AI's
--   target; nonzero means it acted, so the rest of the AI is skipped that frame, as when the
--   original routine returns nonzero. `void id()` runs in place of the whole AI (ai.control).
-- - self/target are Info objects: copies of an object's fields as loaded (target = n, loadTarget(n),
--   which return the object's type, or -1 and keep the old copy when there is no object n).
-- - up/down/left/right/A/J/D(key = 1, holding = 0) set self's key and its "held last frame" flag;
--   DrA() .. DJA() complete that key sequence; rand(n) is the game's own random (replays and
--   network play stay in step); print and clr write to a console the game does not show.
-- - A script error (as AngelScript's "Divide by zero") ends that call, and ego() then counts as 0.
-- Each match gets fresh instances, so every computer in a network room starts from the same state.

local constants = require("base/game/constants")
local item = require("base/game/item")
local angelscript = require("base/game/angelscript")
local ai_scripts = {}

local facing_left = constants.facings.left
local complete = constants.combo_states.complete
local item_slots = constants.item_slots
local key_names = {up = "up", down = "down", left = "left", right = "right", A = "attack", J = "jump", D = "defend"}

-- The runtime the compiled scripts call (their environment's R).
local R = {}
local items -- the match's objects during a call
local zero_record = {id = 0, kind = 0, data = {}, movement = {}, frames = {}}
function zero_record.frame() return item.empty_frame end
local zero_object = {x_int = 0, y_int = 0, z_int = 0, x = 0, y = 0, z = 0, vx = 0, vy = 0, vz = 0,
    facing = 0, keys = {}, previous_keys = {}, sequences = {}, hp = 0, dark_hp = 0, max_hp = 0, mp = 0,
    frame = 0, previous_frame = 0, timer_b0 = 0, timer_b8 = 0, team = 0, blink = 0, weapon = 0,
    held_item = 0, holder = 0, hit_lag = 0, wait_counter = 0, catch_timer = 0, caught_by = 0,
    timer_ec = 0, follow = -1, lives = 0, walk_phase = 0, dash_counter = 0, impulse_x = 0,
    impulse_y = 0, impulse_z = 0, thrower = -1, kills = 0, pickings = 0, damage_dealt = 0, hp_spent = 0,
    mp_spent = 0, last_target = -1, armor = 0, record = zero_record}
for _, key in pairs(key_names) do zero_object.keys[key], zero_object.previous_keys[key] = false, false end
for index = 1, 9 do zero_object.sequences[index] = 0 end
local snapshot_fields = {"x_int", "y_int", "z_int", "x", "y", "z", "vx", "vy", "vz", "facing", "hp", "dark_hp",
    "max_hp", "mp", "frame", "previous_frame", "timer_b0", "timer_b8", "team", "blink", "weapon", "held_item",
    "holder", "hit_lag", "wait_counter", "catch_timer", "caught_by", "timer_ec", "follow", "lives",
    "walk_phase", "dash_counter", "impulse_x", "impulse_y", "impulse_z", "thrower", "kills", "pickings",
    "damage_dealt", "hp_spent", "mp_spent", "last_target", "armor", "record", "pair_rest"}

-- An Info's copy of an object.
local function snapshot(object)
    local copy = {keys = {}, previous_keys = {}, sequences = {}}
    for _, field in ipairs(snapshot_fields) do copy[field] = object[field] end
    for _, key in pairs(key_names) do
        copy.keys[key], copy.previous_keys[key] = object.keys[key], object.previous_keys[key]
    end
    for index = 1, 9 do copy.sequences[index] = object.sequences[index] or 0 end
    return copy
end

-- Info: {o = the object (or its copy), n = its index}. self and target read the live object during
-- a call (nothing else moves then) and target keeps a copy between calls.
function R.info_new(n)
    local info = {o = zero_object, n = 0}
    R.info_load(info, n)
    return info
end
function R.info_load(info, n)
    n = n and math.floor(n) or -1
    if n < 0 or n >= item_slots then return -1 end
    local object = items and items[n]
    if not object then return -1 end
    info.o = info.live and object or snapshot(object)
    info.n = n
    return object.record.kind
end
R.self = {o = zero_object, n = 0, live = true}
R.target = {o = zero_object, n = 0, live = true}
R.globals = {}

function R.state_of(object) return object.record.frame(object.frame).state end
function R.weapon_held(object)
    if object.weapon == 0 then return -1 end
    return object.held_item
end
function R.vrest(object)
    local rest = object.pair_rest
    if not rest then return 0 end
    local a, b = rest[0] or 0, rest[3] or 0
    return a > b and a or b
end
function R.set_enemy(n)
    if n < 0 or n >= item_slots or not (items and items[n]) then return -1 end
    R.self.o.last_target = n
    return n
end

-- Views of the game's objects and data.
function R.exists(n) return n >= 0 and n < item_slots and items ~= nil and items[n] ~= nil end
function R.object(n)
    return {o = (n >= 0 and n < item_slots and items and items[n]) or zero_object, n = n}
end
function R.data(record) return {r = record} end
function R.frame(data, n) return {f = data.r.frame(n)} end
local zero_rect = {x = 0, y = 0, width = 0, height = 0}
local zero_itr = {kind = 0, x = 0, y = 0, width = 0, height = 0, dvx = 0, dvy = 0, fall = 0, arest = 0,
    vrest = 0, respond = 0, effect = 0, catching_actions = {0, 0}, caught_actions = {0, 0}, bdefend = 0,
    injury = 0, zwidth = 0}
function R.itr(frame, n) return frame.f.interactions[n + 1] or zero_itr end
function R.bdy(frame, n) return frame.f.bodies[n + 1] or zero_itr end
function R.bounds(rect) return rect or zero_rect end

-- Keys and sequences of self.
function R.key(name, key, holding)
    local object = R.self.o
    object.keys[name] = key ~= 0
    object.previous_keys[name] = holding ~= 0
end
function R.combo(index) R.self.o.sequences[index] = complete end
function R.rand(n) return engine.random(n) end

-- Numbers, strings and arrays as AngelScript has them.
function R.trunc(value)
    if value >= 0 then return math.floor(value) end
    return math.ceil(value)
end
local divide_by_zero = {angelscript_exception = "Divide by zero"}
function R.idiv(a, b)
    if b == 0 then error(divide_by_zero, 0) end
    return R.trunc(a / b)
end
function R.imod(a, b)
    if b == 0 then error(divide_by_zero, 0) end
    return math.fmod(a, b)
end
R.fmod = math.fmod
function R.abs(value) return math.abs(value) end
for _, name in ipairs({"sqrt", "cos", "sin", "tan", "acos", "asin", "atan", "cosh", "sinh", "tanh", "log",
    "ceil", "floor", "exp"}) do
    R[name] = math[name]
end
function R.atan2(y, x) return math.atan2 and math.atan2(y, x) or math.atan(y, x) end
function R.log10(value) return math.log(value) / math.log(10) end
function R.pow(a, b) return a ^ b end
function R.fraction(value) return value - R.trunc(value) end
local function text(value)
    if type(value) == "boolean" then return value and "true" or "false" end
    if type(value) == "number" and value == math.floor(value) and math.abs(value) < 2 ^ 53 then
        return string.format("%d", value)
    end
    return tostring(value)
end
function R.concat(a, b) return text(a) .. text(b) end
function R.print() end
function R.clr() end
function R.discard() end
-- Bit operations on 32-bit two's complement values.
local function to_unsigned(value) return math.floor(value) % 4294967296 end
local function to_signed(value)
    value = value % 4294967296
    if value >= 2147483648 then return value - 4294967296 end
    return value
end
local function bitwise(a, b, rule)
    a, b = to_unsigned(a), to_unsigned(b)
    local result, bit = 0, 1
    for _ = 1, 32 do
        local x, y = a % 2, b % 2
        if rule(x, y) then result = result + bit end
        a, b, bit = (a - x) / 2, (b - y) / 2, bit * 2
    end
    return to_signed(result)
end
function R.band(a, b) return bitwise(a, b, function(x, y) return x == 1 and y == 1 end) end
function R.bor(a, b) return bitwise(a, b, function(x, y) return x == 1 or y == 1 end) end
function R.bxor(a, b) return bitwise(a, b, function(x, y) return x ~= y end) end
function R.bnot(a) return to_signed(4294967295 - to_unsigned(a)) end
function R.shl(a, b) return to_signed(to_unsigned(a) * 2 ^ (b % 32)) end
function R.shr(a, b) return to_signed(math.floor(to_unsigned(a) / 2 ^ (b % 32))) end
function R.array_new(size, fill)
    local array = {n = size}
    for index = 0, size - 1 do array[index] = fill end
    return array
end
function R.array_of(values, count)
    local array = {n = count}
    for index = 1, count do array[index - 1] = values[index] end
    return array
end
local out_of_range = {angelscript_exception = "Index out of bounds"}
function R.array_get(array, index)
    if index < 0 or index >= array.n then error(out_of_range, 0) end
    return array[index]
end
function R.array_set(array, index, value)
    if index < 0 or index >= array.n then error(out_of_range, 0) end
    array[index] = value
end
function R.array_length(array) return array.n end
function R.array_insert(array, at, value)
    at = at or array.n
    for index = array.n, at + 1, -1 do array[index] = array[index - 1] end
    array[at] = value
    array.n = array.n + 1
end
function R.array_remove(array, at)
    at = at or array.n - 1
    if at < 0 or at >= array.n then error(out_of_range, 0) end
    for index = at, array.n - 2 do array[index] = array[index + 1] end
    array[array.n - 1] = nil
    array.n = array.n - 1
end
function R.array_resize(array, size, fill)
    for index = array.n, size - 1 do array[index] = fill end
    for index = size, array.n - 1 do array[index] = nil end
    array.n = size
end
function R.array_find(array, value)
    for index = 0, array.n - 1 do if array[index] == value then return index end end
    return -1
end
function R.array_reverse(array)
    for index = 0, math.floor(array.n / 2) - 1 do
        array[index], array[array.n - 1 - index] = array[array.n - 1 - index], array[index]
    end
end

-- What the scripts see, for the compiler (base/game/angelscript): types and Lua templates.
local function fields(list)
    local result = {}
    for name, entry in pairs(list) do result[name] = entry end
    return result
end
local object_fields = {
    x = {"int", "$.o.x_int"}, y = {"int", "$.o.y_int"}, z = {"int", "$.o.z_int"},
    x_real = {"double", "$.o.x"}, y_real = {"double", "$.o.y"}, z_real = {"double", "$.o.z"},
    x_velocity = {"double", "$.o.vx"}, y_velocity = {"double", "$.o.vy"}, z_velocity = {"double", "$.o.vz"},
    facing = {"bool", "($.o.facing == " .. facing_left .. ")"},
    holding_up = {"bool", "$.o.previous_keys.up"}, holding_down = {"bool", "$.o.previous_keys.down"},
    holding_left = {"bool", "$.o.previous_keys.left"}, holding_right = {"bool", "$.o.previous_keys.right"},
    holding_a = {"bool", "$.o.previous_keys.attack"}, holding_j = {"bool", "$.o.previous_keys.jump"},
    holding_d = {"bool", "$.o.previous_keys.defend"},
    up = {"bool", "$.o.keys.up"}, down = {"bool", "$.o.keys.down"}, left = {"bool", "$.o.keys.left"},
    right = {"bool", "$.o.keys.right"}, A = {"bool", "$.o.keys.attack"}, J = {"bool", "$.o.keys.jump"},
    D = {"bool", "$.o.keys.defend"},
    DrA = {"int", "$.o.sequences[1]"}, DlA = {"int", "$.o.sequences[2]"}, DuA = {"int", "$.o.sequences[3]"},
    DdA = {"int", "$.o.sequences[4]"}, DrJ = {"int", "$.o.sequences[5]"}, DlJ = {"int", "$.o.sequences[6]"},
    DuJ = {"int", "$.o.sequences[7]"}, DdJ = {"int", "$.o.sequences[8]"}, DJA = {"int", "$.o.sequences[9]"},
    hp = {"int", "$.o.hp"}, dark_hp = {"int", "$.o.dark_hp"}, max_hp = {"int", "$.o.max_hp"}, mp = {"int", "$.o.mp"},
    fall = {"int", "$.o.timer_b0"}, shake = {"int", "$.o.hit_lag"}, bdefend = {"int", "$.o.timer_b8"},
    team = {"int", "$.o.team"}, blink = {"int", "$.o.blink"}, wait_counter = {"int", "$.o.wait_counter"},
    weapon_type = {"int", "$.o.weapon"}, weapon_holder = {"int", "$.o.holder"},
    ctimer = {"int", "$.o.catch_timer"}, arest = {"int", "$.o.timer_ec"},
    clone = {"int", "$.o.follow"}, reserve = {"int", "$.o.lives"},
    data = {"DataFile", "R.data($.o.record)"},
}
local info_fields = fields(object_fields)
info_fields.frame = {"int", "$.o.frame"}
info_fields.id = {"int", "$.o.record.id"}
info_fields.type = {"int", "$.o.record.kind"}
info_fields.state = {"int", "R.state_of($.o)"}
info_fields.weapon_held = {"int", "R.weapon_held($.o)"}
info_fields.vrest = {"int", "R.vrest($.o)"}
info_fields.num = {"int", "$.n"}
local game_object_fields = fields(object_fields)
game_object_fields.frame1 = {"int", "$.o.frame"}
game_object_fields.frame2 = {"int", "$.o.previous_frame"}
game_object_fields.weapon_held = {"int", "$.o.held_item"}
game_object_fields.move_counter = {"int", "$.o.walk_phase"}
game_object_fields.run_counter = {"int", "$.o.dash_counter"}
game_object_fields.x_acceleration = {"double", "$.o.impulse_x"}
game_object_fields.y_acceleration = {"double", "$.o.impulse_y"}
game_object_fields.z_acceleration = {"double", "$.o.impulse_z"}
game_object_fields.ccatcher = {"int", "$.o.caught_by"}
game_object_fields.weapon_thrower = {"int", "$.o.thrower"}
game_object_fields.kills = {"int", "$.o.kills"}
game_object_fields.weapon_picks = {"int", "$.o.pickings"}
game_object_fields.total_attack = {"int", "$.o.damage_dealt"}
game_object_fields.hp_lost = {"int", "$.o.hp_spent"}
game_object_fields.mp_usage = {"int", "$.o.mp_spent"}
game_object_fields.enemy = {"int", "$.o.last_target"}
game_object_fields.armour_multiplier = {"int", "$.o.armor"}

local movement = {}
for _, name in ipairs({"walking_speed", "walking_speedz", "running_speed", "running_speedz", "heavy_walking_speed",
    "heavy_walking_speedz", "heavy_running_speed", "heavy_running_speedz", "jump_height", "jump_distance",
    "jump_distancez", "dash_height", "dash_distance", "dash_distancez", "rowing_height", "rowing_distance"}) do
    movement[name] = {"double", "($.r.movement and $.r.movement." .. name .. " or 0)"}
end
movement.walking_frame_rate = {"int", "($.r.movement and $.r.movement.walking_frame_rate or 0)"}
movement.running_frame_rate = {"int", "($.r.movement and $.r.movement.running_frame_rate or 0)"}

local function frame_fields()
    local list = {
        exists = {"bool", "(not $.f.undefined)"}, pic = {"int", "$.f.picture"}, state = {"int", "$.f.state"},
        wait = {"int", "$.f.wait"}, next = {"int", "$.f.next"}, dvx = {"int", "$.f.dvx"}, dvy = {"int", "$.f.dvy"},
        dvz = {"int", "$.f.dvz"}, centerx = {"int", "$.f.center_x"}, centery = {"int", "$.f.center_y"},
        mp = {"int", "$.f.mp"},
        itr_count = {"int", "#$.f.interactions"}, bdy_count = {"int", "#$.f.bodies"},
        itrs = {"ItrArray", "$"}, bdys = {"BdyArray", "$"},
        opoint = {"Opoint", "$.f.opoint"}, bpoint = {"Bpoint", "$.f.bpoint"}, cpoint = {"Cpoint", "$.f.cpoint"},
        wpoint = {"Wpoint", "$.f.wpoint"},
        itr_x = {"int", "R.bounds($.f.interaction_bounds).x"}, itr_y = {"int", "R.bounds($.f.interaction_bounds).y"},
        itr_w = {"int", "R.bounds($.f.interaction_bounds).width"}, itr_h = {"int", "R.bounds($.f.interaction_bounds).height"},
        bdy_x = {"int", "R.bounds($.f.body_bounds).x"}, bdy_y = {"int", "R.bounds($.f.body_bounds).y"},
        bdy_w = {"int", "R.bounds($.f.body_bounds).width"}, bdy_h = {"int", "R.bounds($.f.body_bounds).height"},
    }
    for _, hit in ipairs({"a", "d", "j", "Fa", "Ua", "Da", "Fj", "Uj", "Dj", "ja"}) do
        list["hit_" .. hit] = {"int", "$.f.hits." .. hit}
    end
    return list
end
local function plain(names)
    local list = {}
    for _, name in ipairs(names) do list[name] = {"int", "$." .. name} end
    return list
end
local itr = plain({"kind", "x", "y", "dvx", "dvy", "fall", "arest", "vrest", "effect", "bdefend", "injury", "zwidth"})
itr.w, itr.h = {"int", "$.width"}, {"int", "$.height"}
itr.catchingact1, itr.catchingact2 = {"int", "$.catching_actions[1]"}, {"int", "$.catching_actions[2]"}
itr.caughtact1, itr.caughtact2 = {"int", "$.caught_actions[1]"}, {"int", "$.caught_actions[2]"}
local bdy = plain({"kind", "x", "y"})
bdy.w, bdy.h = {"int", "$.width"}, {"int", "$.height"}

local data_fields = fields(movement)
data_fields.frames = {"FrameArray", "$"}
data_fields.id = {"int", "$.r.id"}
data_fields.type = {"int", "$.r.kind"}
data_fields.weapon_hp = {"int", "($.r.data.weapon_hp or 0)"}
data_fields.weapon_drop_hurt = {"int", "($.r.data.weapon_drop_hurt or 0)"}

local info_class = {fields = info_fields, new = "R.info_new($1)", assign = "R.info_load($, $1)",
    number = "$.n", step = "R.discard(R.info_load($, $.n + %d))", methods = {}}
local api = {
    classes = {
        Info = info_class,
        Object = {fields = game_object_fields, methods = {}},
        Game = {fields = {exists = {"BoolArray", "$"}, objects = {"ObjectArray", "$"}}, methods = {}},
        BoolArray = {index = {"bool", "R.exists($1)"}, methods = {}},
        ObjectArray = {index = {"Object", "R.object($1)"}, methods = {}},
        DataFile = {fields = data_fields, methods = {get_name = {"string", "($.r.data.name or \"\")"}}},
        FrameArray = {index = {"Frame", "R.frame($, $1)"}, methods = {}},
        Frame = {fields = frame_fields(), methods = {}},
        ItrArray = {index = {"Itr", "R.itr($, $1)"}, methods = {}},
        BdyArray = {index = {"Bdy", "R.bdy($, $1)"}, methods = {}},
        Itr = {fields = itr, methods = {}},
        Bdy = {fields = bdy, methods = {}},
        Opoint = {fields = plain({"kind", "x", "y", "action", "dvx", "dvy", "oid", "facing"}), methods = {}},
        Bpoint = {fields = plain({"x", "y"}), methods = {}},
        Cpoint = {fields = plain({"kind", "x", "y", "injury", "cover", "vaction", "aaction", "jaction", "daction",
            "throwvx", "throwvy", "hurtable", "decrease", "dircontrol", "taction", "throwinjury", "throwvz"}), methods = {}},
        Wpoint = {fields = plain({"kind", "x", "y", "weaponact", "attacking", "cover", "dvx", "dvy", "dvz"}), methods = {}},
    },
    globals = {
        self = {"Info", "R.self", const = true}, target = {"Info", "R.target"}, game = {"Game", "R.game", const = true},
    },
    functions = {
        rand = {result = "int", params = {"int"}, code = "R.rand($1)"},
        loadTarget = {result = "int", params = {"int"}, code = "R.info_load(R.target, $1)"},
        setEnemy = {result = "int", params = {"int"}, code = "R.set_enemy($1)"},
        print = {result = "void", params = {"any"}, code = "R.print($1)"},
        printAddr = {result = "void", params = {"any"}, code = "R.discard($1)"},
        clr = {result = "void", params = {}, code = "R.clr()"},
        abs = {result = "double", params = {"double"}, code = "R.abs($1)"},
        pow = {result = "double", params = {"double", "double"}, code = "R.pow($1, $2)"},
        atan2 = {result = "double", params = {"double", "double"}, code = "R.atan2($1, $2)"},
    },
}
R.game = {}
for _, name in ipairs({"mode", "difficulty", "background", "bg_width", "bg_zwidth1", "bg_zwidth2", "stage_bound",
    "current_phase", "current_phase_count", "current_stage", "elapsed_time"}) do
    api.globals[name] = {"int", "R.globals." .. name, const = true}
end
api.globals.stage_clear = {"bool", "R.globals.stage_clear", const = true}
for name in pairs(key_names) do
    api.functions[name] = {result = "void", params = {"number", "number"}, defaults = {"1", "0"},
        code = "R.key(\"" .. key_names[name] .. "\", $1, $2)"}
end
for index, name in ipairs({"DrA", "DlA", "DuA", "DdA", "DrJ", "DlJ", "DuJ", "DdJ", "DJA"}) do
    api.functions[name] = {result = "void", params = {}, code = "R.combo(" .. index .. ")"}
end
for _, name in ipairs({"sqrt", "cos", "sin", "tan", "acos", "asin", "atan", "cosh", "sinh", "tanh", "log", "log10",
    "ceil", "floor", "fraction", "exp"}) do
    api.functions[name] = {result = "double", params = {"double"}, code = "R." .. name .. "($1)"}
end
ai_scripts.api = api
ai_scripts.runtime = R

-- Compiled scripts by path (once per session): {factory} or {problem}.
local compiled = {}
local reported = {}
local function report(problem)
    if reported[problem] then return end
    reported[problem] = true
    if engine.log then engine.log("AI script: " .. problem) end
end
local function compile(path)
    local cached = compiled[path]
    if cached then return cached end
    local found, source = pcall(engine.read_resource, path)
    if not found then
        cached = {}
    else
        local ok, result = pcall(angelscript.compile, source, path, api)
        if not ok then
            cached = {problem = angelscript.error_message(result) or tostring(result)}
        else
            local chunk, message = engine.compile_text(result, path, {R = R})
            if not chunk then cached = {problem = path .. ": " .. tostring(message)}
            else
                local made, factory = pcall(chunk)
                if made then cached = {factory = factory} else cached = {problem = path .. ": " .. tostring(factory)} end
            end
        end
        if cached.problem then report(cached.problem .. "; the built-in AI plays this character") end
    end
    compiled[path] = cached
    return cached
end
ai_scripts.compile_file = compile

-- The match's instance of the script for a record id, or false.
local function instance(state, id)
    local instances = state.ai_scripts
    if not instances then
        instances = {}
        state.ai_scripts = instances
        R.target.o, R.target.n = zero_object, 0
    end
    local found = instances[id]
    if found ~= nil then return found end
    found = false
    local script = compile("ai/" .. id .. ".as")
    if script.factory then
        items = state.items
        local ok, made = pcall(script.factory)
        if ok then found = made else report("ai/" .. id .. ".as: " .. tostring(made)) end
    end
    instances[id] = found
    return found
end

local function prepare(state, index)
    items = state.items
    local g = R.globals
    -- Scripts know the original's levels; INSANE! plays them as CRAZY!.
    g.difficulty = math.max(state.difficulty or 0, constants.difficulties.crazy)
    g.mode, g.elapsed_time = state.mode or 0, state.elapsed or 0
    local stage = state.stage or {}
    g.background = state.background_id or 0
    g.bg_width = stage.width or 0
    g.bg_zwidth1 = stage.zboundary and stage.zboundary[1] or 0
    g.bg_zwidth2 = stage.zboundary and stage.zboundary[2] or 0
    if state.mode == constants.modes.stage then
        g.stage_bound = state.stage_bound or 0
        g.stage_clear = g.stage_bound == 0
    else
        g.stage_bound, g.stage_clear = g.bg_width, false
    end
    local run = state.stage_run
    g.current_phase = run and run.phase or 0
    g.current_phase_count = run and run.phase_count or 0
    g.current_stage = run and run.id or 0
    R.self.o, R.self.n = items[index], index
end
local function finish()
    -- target keeps the copy it had when the call ended.
    local target = R.target
    if target.o ~= zero_object and items[target.n] == target.o then target.o = snapshot(target.o) end
    items = nil
end

-- ego() for the computer player at `index` aimed at `target_index`: its result, or nil when the
-- player's id has no ego().
function ai_scripts.ego(state, index, target_index)
    local value = state.items[index]
    local script = instance(state, value.record.id)
    if not script or not script.ego then return nil end
    prepare(state, index)
    R.info_load(R.target, target_index)
    local ok, result = pcall(script.ego)
    finish()
    if not ok then
        if type(result) ~= "table" or not result.angelscript_exception then
            report("ai/" .. value.record.id .. ".as: " .. tostring(result))
        end
        return 0
    end
    return result or 0
end

-- id() in place of the whole AI for the computer player at `index`: true when it ran.
-- Whether the fighter at `index` has its mod's own AI script (ai/<id>.as with id() or ego()).
function ai_scripts.has(state, index)
    local script = instance(state, state.items[index].record.id)
    return script and (script.id or script.ego) and true or false
end

function ai_scripts.id(state, index)
    local value = state.items[index]
    local script = instance(state, value.record.id)
    if not script or not script.id then return false end
    prepare(state, index)
    local ok, result = pcall(script.id)
    finish()
    if not ok and (type(result) ~= "table" or not result.angelscript_exception) then
        report("ai/" .. value.record.id .. ".as: " .. tostring(result))
    end
    return true
end
return ai_scripts
