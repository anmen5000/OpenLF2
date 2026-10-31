-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors
-- The computer players a bench job may name: "smart" (INSANE! as in scripts/), "classic" (the original computer
-- player), or "smart@<module>" — another computer player in the shape of smart_ai.lua, loaded from this package as
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
        local other = value and value.brain and others[(value.brain:match("^smart@(.+)$") or "")]
        if other then return other.control(state, index) end
        return control(state, index)
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
    if name == "smart" then return "smart v" .. tostring(require("base/game/smart_ai").version) end
    local module = brains.load(name)
    return module and (name .. " v" .. tostring(module.version)) or name
end
return brains
