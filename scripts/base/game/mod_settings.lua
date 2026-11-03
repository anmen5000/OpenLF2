-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

-- A mod's own settings for OpenLF2: openlf2.txt beside its data folder (in a game pack), "key = value" lines,
-- anything after # a note. The XOI kit's xuat-ban.bat writes it into a mod published for its players:
--   hidden_characters = locked   the hidden fighters stay hidden: the option to unlock them is gone and does
--                                nothing, and LF2.NET typed at the title does nothing (the saved option is kept
--                                as it is, for an installed OpenLF2 that shares the settings file)
--   options = hidden             no "options" on the title screen
-- The original game's installer, and a mod without the file, have no settings. Read once, from the game's files,
-- so every computer playing the same mod has the same.
local mod_settings = {}
local values

local function load()
    if values then return values end
    values = {}
    local ok, text = pcall(engine.read_resource, "openlf2.txt")
    if ok and type(text) == "string" then
        for line in text:gmatch("[^\r\n]+") do
            local key, value = line:gsub("#.*", ""):match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
            if key then values[key:lower()] = value:lower() end
        end
    end
    return values
end

function mod_settings.get(key) return load()[key] end
function mod_settings.hidden_characters_locked() return load().hidden_characters == "locked" end
function mod_settings.options_hidden() return load().options == "hidden" end
return mod_settings
