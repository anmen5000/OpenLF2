-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors
-- Test harness: runs the job named in bench/config on the first frame instead of the game's menus — or, with
-- command "show", a match to watch in the window (bench/show).
local flow = {}
function flow.create(options)
    require("base/game/combat").set_armor_by_id(options.armor_by_id)
    local config = require("bench/config")
    local state = {options = options, done = false}
    if config.command == "show" then
        local ok, result = pcall(function() return require("bench/show").create(config, options) end)
        if ok then state.show = result else engine.log("BENCH ERROR: " .. tostring(result)) end
    end
    return state
end
function flow.update(state, input, context)
    if state.show then
        local ok, problem = pcall(require("bench/show").update, state.show, input, context)
        if not ok then engine.log("BENCH ERROR: " .. tostring(problem)); state.show = nil end
        return
    end
    if state.done then return end
    state.done = true
    local config = require("bench/config")
    local ok, problem = pcall(function() require("bench/" .. config.command).run(config, state.options) end)
    if not ok then engine.log("BENCH ERROR: " .. tostring(problem)) end
end
function flow.draw(state, context)
    if state.show then return require("bench/show").draw(state.show, context) end
    local config = require("bench/config")
    if config.draw then
        context.viewport(794, 550, 0, 0, 0)
        context.image(config.draw, 0, 0)
    end
end
function flow.describe(state)
    if state.show then return require("bench/show").describe(state.show) end
    return "bench done"
end
return flow
