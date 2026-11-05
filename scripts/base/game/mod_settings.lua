-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

-- A mod's own settings for OpenLF2: openlf2.txt beside its data folder (in a game pack), "key = value" lines,
-- anything after # a note. The XOI kit's xuat-ban.bat writes it into a mod published for its players:
--   hidden_characters = locked   the hidden fighters stay hidden: the option to unlock them is gone and does
--                                nothing, and LF2.NET typed at the title does nothing (the saved option is kept
--                                as it is, for an installed OpenLF2 that shares the settings file); CRAZY!, INSANE!
--                                and XOI, which otherwise come with the unlock, can be chosen (unlock.hard_levels)
--   options = hidden             no "options" on the title screen
--   screen = 1330x730            the picture the mod's own program draws a match on, when it is not the classic
--                                794x550 (Naruto: The Setting Dawn 2.6: stages 1330 wide, 730 deep, backgrounds
--                                735 tall); the match is drawn on it here too (constants.view), the window opens
--                                with it, and the web page shapes its canvas to it. Menus keep the classic screen.
-- The original game's installer, and a mod without the file, have no settings. Read once, from the game's files,
-- so every computer playing the same mod has the same.
local constants = require("base/game/constants")
local mod_settings = {}
local values
local view_applied = false

local function load()
    if values then return values end
    local ok, text = pcall(engine.read_resource, "openlf2.txt")
    -- Before the game's files are open (the host says so) nothing is known yet: asked again later.
    if not ok and tostring(text):find("not loaded", 1, true) then return {} end
    values = {}
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
-- The mod's screen (width, height), the classic one without a setting. "1330x730", "1330 730" or "1330,730";
-- each side between 320 and 4096, else the setting is left out.
function mod_settings.screen()
    local setting = load().screen
    local width, height = tostring(setting or ""):match("^(%d+)%s*[x, ]%s*(%d+)$")
    width, height = tonumber(width), tonumber(height)
    if not width or not height or width < 320 or width > 4096 or height < 320 or height > 4096 then
        return constants.screen.width, constants.screen.height
    end
    return width, height
end
-- Sets constants.view to the mod's screen; once (the same every time: the setting is read once).
function mod_settings.apply_view()
    if view_applied then return constants.view end
    load()
    if not values then return constants.view end -- too early: the classic screen until the files are open
    view_applied = true
    constants.view.width, constants.view.height = mod_settings.screen()
    return constants.view
end
return mod_settings
