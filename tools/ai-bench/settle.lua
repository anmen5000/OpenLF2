-- Frames a fighter passes through from the start with no input: settle.lua with config.id, config.ticks.
local catalog = require("base/game/catalog")
local match = require("base/game/match")
local constants = require("base/game/constants")
local t = {}
function t.run(config)
    local fighters = catalog.load()
    local function find(id) for i, f in ipairs(fighters) do if f.id == id then return i end end end
    local state = match.create({mode = constants.modes.versus, difficulty = 0, background = 0,
        fighters = fighters, backgrounds = catalog.backgrounds(),
        slots = {[0] = {kind = "human", fighter = find(config.id), team = 1}, [1] = {kind = "human", fighter = find(config.other or config.id), team = 2}}})
    local held = {functions = "", function_presses = "", keys = {}, [0] = "", [1] = ""}
    local parts = {}
    for tick = 1, config.ticks or 60 do
        if config.press and config.press[tick] then held[0] = config.press[tick] else held[0] = "" end
        match.step(state, held)
        local v = state.items[0]
        parts[#parts + 1] = string.format("%d:f%d/s%d/y%d/mp%d", tick, v.frame, v.record.frame(v.frame).state, v.y_int, v.mp)
    end
    engine.log(table.concat(parts, " "))
end
return t
