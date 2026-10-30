-- Test harness: runs the job named in bench/config on the first frame instead of the game's menus.
local flow = {}
function flow.create(options)
    require("base/game/combat").set_armor_by_id(options.armor_by_id)
    return {options = options, done = false}
end
function flow.update(state, input, context)
    if state.done then return end
    state.done = true
    local config = require("bench/config")
    local ok, problem = pcall(function() require("bench/" .. config.command).run(config, state.options) end)
    if not ok then engine.log("BENCH ERROR: " .. tostring(problem)) end
end
function flow.draw(state, context)
    local config = require("bench/config")
    if config.draw then
        context.viewport(794, 550, 0, 0, 0)
        context.image(config.draw, 0, 0)
    end
end
function flow.describe(state) return "bench done" end
return flow
