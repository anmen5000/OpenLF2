-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors
-- The computer players a bench job may name: "smart" (INSANE! as in scripts/), "xoi" (XOI: INSANE! with the notes of
-- training, the mod's xoi/notes.txt or those a job hands over), "classic" (the original computer player), or
-- "smart@<module>" — another computer player in the shape of smart_ai.lua, loaded from this package as
-- <module>.lua (listed in package.manifest), so that two versions of the AI, or a player of your own, fight.
-- The match still calls base/game/smart_ai for every "smart…" fighter; it hands the others' fighters over.
local brains = {}
local others = {}
local function install()
    local smart = require("base/game/smart_ai")
    if smart.routed then return end
    smart.routed = true
    local control, prepare, enabled = smart.control, smart.prepare, smart.enabled
    smart.enabled = function(state, value, index)
        if value.brain and value.brain:match("^smart@") then return true end
        return enabled(state, value, index)
    end
    smart.control = function(state, index)
        local value = state.items[index]
        local name = value and value.brain and value.brain:match("^smart@(.+)$")
        local other = name and others[name]
        if not other then return control(state, index) end
        -- Each player keeps its own context (state.smart_context: how it reads the fighters' moves, its model of
        -- the opponent, its notes of the frame): two versions sharing one would play with each other's learning —
        -- whichever moved first in a match set it up for both.
        local contexts = state.bench_contexts or {}
        state.bench_contexts = contexts
        local own = state.smart_context
        state.smart_context = contexts[name]
        local result = other.control(state, index)
        contexts[name] = state.smart_context
        state.smart_context = own
        return result
    end
    smart.prepare = function(state)
        prepare(state)
        for _, other in pairs(others) do other.prepare(state) end
    end
end
-- Loads the module a "smart@<module>" brain names (once) and returns it; nil for the other brains.
function brains.load(name)
    local file = name and name:match("^smart@(.+)$")
    if not file then return nil end
    if others[file] then return others[file] end
    local module = require("bench/" .. file)
    others[file] = module
    install()
    return module
end
-- The brain's name with the version it runs ("smart v22", "smart@ai_alt v21", "classic").
function brains.label(name)
    if name == "xoi" then
        local smart = require("base/game/smart_ai")
        return string.format("xoi v%d (notes of %d pairs)", smart.version, smart.notes_pairs())
    end
    local module = name == "smart" and require("base/game/smart_ai") or brains.load(name)
    if not module then return name end
    -- (The version number exists from version 20 on.)
    return name .. (module.version and (" v" .. tostring(module.version)) or " (no version: before v20)")
end
return brains
