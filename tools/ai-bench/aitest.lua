-- Checks that a mod's AI scripts compile and make instances: aitest.lua with config.ids.
local t = {}
function t.run(config)
    local ai_scripts = require("base/game/ai_scripts")
    local catalog = require("base/game/catalog")
    local match = require("base/game/match")
    local constants = require("base/game/constants")
    local fighters = catalog.load()
    local function find(id) for i, f in ipairs(fighters) do if f.id == id then return i end end end
    for _, id in ipairs(config.ids) do
        local c = ai_scripts.compile_file("ai/" .. id .. ".as")
        local state = match.create({mode = constants.modes.versus, difficulty = -1, background = constants.background_rows.random,
            fighters = fighters, backgrounds = catalog.backgrounds(),
            slots = {[0] = {kind = "computer", fighter = find(id), team = 1}, [1] = {kind = "computer", fighter = find(config.other), team = 2}}})
        local made_ok, made = pcall(c.factory)
        engine.log(string.format("ai/%d.as: factory %s made %s %s id=%s has=%s", id, tostring(c.factory), tostring(made_ok), type(made),
            type(made) == "table" and tostring(made.id) or "-", tostring(ai_scripts.has(state, 10))))
    end
end
return t
