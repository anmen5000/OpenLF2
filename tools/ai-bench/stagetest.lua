-- An INSANE! Stage mode run with computer players: stagetest.lua with config.ids, config.level, config.limit.
local catalog = require("base/game/catalog")
local match = require("base/game/match")
local constants = require("base/game/constants")
local t = {}
function t.run(config)
    local fighters = catalog.load()
    local function find(id) for i, f in ipairs(fighters) do if f.id == id then return i end end end
    local slots = {}
    for k, id in ipairs(config.ids) do slots[k - 1] = {kind = "computer", fighter = find(id), team = 1} end
    local smart = require("base/game/smart_ai")
    local plays0 = smart.plays
    local state = match.create({mode = constants.modes.stage, difficulty = config.difficulty or -2, background = 0, stage_level = config.level or 0,
        fighters = fighters, backgrounds = catalog.backgrounds(), slots = slots})
    engine.log("stage enemies: " .. table.concat(require("base/game/stage").enemy_ids(state.stage_run), ",") .. "; plays at creation " .. (smart.plays - plays0))
    local held = {functions = "", function_presses = "", keys = {}}
    local before = smart.plays
    local most, most_at = 0, 0
    for tick = 1, config.limit do
        local p = smart.plays
        local result = match.step(state, held)
        if smart.plays - p > most then most, most_at = smart.plays - p, tick end
        if result == "finished" or state.round_counter > 0 then engine.log("round over at " .. tick) break end
    end
    local enemies, smart_count = 0, 0
    for i = 0, 399 do
        local v = state.items[i]
        if v and v.record.kind == 0 and v.team == constants.teams.enemies then enemies = enemies + 1 end
        if v and v.smart_memory then smart_count = smart_count + 1 end
    end
    for i = 0, 399 do
        local v = state.items[i]
        if v and v.record.kind == 0 then
            engine.log(string.format("  slot %d id %d team %d hp %d x %d z %d y %d f%d state %d note %s", i, v.record.id, v.team, v.hp, v.x_int, v.z_int, v.y_int, v.frame,
                v.record.frame(v.frame).state, v.smart_memory and v.smart_memory.note or "-"))
        end
    end
    engine.log(string.format("stage %d: run.id %d phase %d; enemies now %d; smart-controlled %d; plays during play %d (most in one tick %d at %d)",
        config.level or 0, state.stage_run.id, state.stage_run.phase, enemies, smart_count, smart.plays - before, most, most_at))
end
return t
