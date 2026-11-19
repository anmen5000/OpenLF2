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
--                                Without the setting, a mod whose stages reach below the classic screen has the
--                                screen its stages are made for (stage_screen: NTSD 2.6's 1330x730 needs none).
--   menus = 1.9 (or 2.0)         the menus as LF2 1.9 or 2.0a draws them; without it, as the mod's pictures show
--                                (mod_settings.classic_menus)
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
-- A mod's own screen read off its stages, when its openlf2.txt gives none (a copy without the file: Naruto: The
-- Setting Dawn 2.6 as its team gives it out). The classic screen shows a stage's ground down to z = 550, below every
-- stage of the original (the deepest, Lion Forest, ends at 517); a mod whose program draws its matches on a larger
-- picture has its stages made for it (NTSD 2.6: every stage 1330 wide, its ground ending at z = 540 to 730). When
-- more than half of the stages in data.txt end below the classic screen, the screen is as wide as the narrowest of
-- those (no narrower than the classic one) and as deep as the deepest stage (NTSD 2.6: 1330x730); otherwise nil.
-- The host opens its window and the web page's canvas with the same (application.cpp: stage_screen_size).
local staged -- {width, height}, or false for the classic screen, once read
local function stage_screen()
    if staged ~= nil then
        if staged then return staged[1], staged[2] end
        return nil
    end
    local ok, list = pcall(require("base/game/catalog").backgrounds)
    if not ok then return nil end -- the game's files not open yet: asked again later
    local classic = constants.screen
    local stages, deep, width, depth = 0, 0, nil, 0
    for _, entry in ipairs(list) do
        local read, data = pcall(engine.read_background_data, entry.path)
        local far = read and data.width and data.zboundary and data.zboundary[2]
        if far then
            stages = stages + 1
            depth = math.max(depth, far)
            if far > classic.height then
                deep = deep + 1
                width = math.min(width or data.width, data.width)
            end
        end
    end
    staged = deep * 2 > stages and {math.min(math.max(width, classic.width), 4096), math.min(depth, 4096)}
    return stage_screen()
end
-- The mod's screen (width, height): its openlf2.txt's ("1330x730", "1330 730" or "1330,730"; each side between 320
-- and 4096, else the setting is left out), else its stages' (stage_screen), else the classic one.
function mod_settings.screen()
    local setting = load().screen
    local width, height = tostring(setting or ""):match("^(%d+)%s*[x, ]%s*(%d+)$")
    width, height = tonumber(width), tonumber(height)
    if width and height and width >= 320 and width <= 4096 and height >= 320 and height <= 4096 then
        return width, height
    end
    width, height = stage_screen()
    if width then return width, height end
    return constants.screen.width, constants.screen.height
end
-- Whether the menus are LF2 1.9's: a mod whose program is made from LF2 1.9 (the source release of Naruto: The
-- Setting Dawn, whose NTSD.exe is LF2 1.9c's) has its menu pictures, laid out otherwise in places: no MENU_CLIP5 (2.0a's
-- main menu, with "recording info" and "official website"), MENU_WAIT or MENU_BACK, and a mode menu without "Playback
-- Recording", its entries lower in MENU_CLIP3. The screens then draw them where LF2 1.9's program does. Asked of the
-- pictures once the game's files are open (a mod may say so in openlf2.txt: menus = 1.9 or 2.0).
local classic
function mod_settings.classic_menus()
    if classic ~= nil then return classic end
    local setting = load().menus
    if setting == "1.9" or setting == "2.0" then
        classic = setting == "1.9"
        return classic
    end
    local ok, problem = pcall(engine.read_resource, "pe/menu_clip5")
    if not ok and tostring(problem):find("not loaded", 1, true) then return false end
    classic = not ok
    return classic
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
