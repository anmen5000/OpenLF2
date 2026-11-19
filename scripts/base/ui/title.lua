-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

local title = {}
local constants = require("base/game/constants")
local navigation = require("base/ui/input")
local sounds = require("base/game/sounds")
local controls = require("base/ui/controls")
local font = require("base/ui/font")
local mod_settings = require("base/game/mod_settings")
local menu_sheet = "pe/menu_clip3"
-- Each entry's highlighted picture in the sheet and where it is drawn (x, y, w, h, screen x, screen y). LF2 2.0a's
-- menu, with its box; or LF2 1.9's (a mod whose program is made from it, base/game/mod_settings.classic_menus): no
-- "Playback Recording", the pictures lower in the sheet and the box higher on the screen, where its program draws them.
local menus = {
    [false] = {box_y = 206, destinations = {"versus", "stage", "championship", "team_championship", "battle", "demo",
        "replay", "quit"}, highlighted = {
        {32, 331, 210, 22, 289, 204},
        {18, 358, 238, 24, 275, 231},
        {0, 385, 275, 23, 257, 258},
        {0, 412, 275, 24, 257, 285},
        {33, 438, 206, 24, 290, 311},
        {42, 466, 188, 23, 299, 339},
        {0, 493, 277, 25, 257, 366},
        {55, 521, 165, 23, 312, 394},
    }},
    [true] = {box_y = 189, destinations = {"versus", "stage", "championship", "team_championship", "battle", "demo",
        "quit"}, highlighted = {
        {32, 343, 210, 22, 289, 204},
        {18, 370, 238, 24, 275, 231},
        {0, 397, 275, 23, 257, 258},
        {0, 424, 275, 24, 257, 285},
        {33, 450, 206, 24, 290, 311},
        {42, 478, 188, 23, 299, 339},
        {55, 505, 165, 23, 312, 366},
    }},
}

function title.create(options)
    options = options or {}
    return {selection = 0, replay_disabled = false, vertical_offset = 0,
        background = (options.menu_seed or 0) % 13 + 1, input = navigation.create(),
        key_list = 0, pointer_x = 0, pointer_y = 0}
end

function title.set_replay_disabled(state, disabled)
    state.replay_disabled = disabled
end

function title.latch_input(state, held)
    for slot = 0, 7 do
        if held[slot] ~= "" then state.input.latched[slot] = true end
    end
end

function title.update(state, held, context)
    state.pointer_x, state.pointer_y = held.pointer_x, held.pointer_y
    local input = navigation.sample(state.input, held)
    if input == "u" or input == "d" or input == "c" then state.key_list = 0 end
    local classic = mod_settings.classic_menus()
    local destinations = menus[classic].destinations
    local entries = #destinations
    -- Original code processes up before down, then confirm in each input snapshot.
    if input:find("u", 1, true) then
        state.selection = (state.selection + entries - 1) % entries
        if not classic and state.replay_disabled and state.selection == constants.title_entries.replay then state.selection = constants.title_entries.replay - 1 end
    end
    if input:find("d", 1, true) then
        state.selection = (state.selection + 1) % entries
        if not classic and state.replay_disabled and state.selection == constants.title_entries.replay then state.selection = constants.title_entries.quit end
    end
    if input:find("c", 1, true) then
        if state.selection < entries - 1 then sounds.direct(state, "ok") end
        context.action(destinations[state.selection + 1])
    end
    for _, sound in ipairs(sounds.flush(state)) do context.sound(sound.resource, sound.volume, sound.pan) end
    -- The key list counts down while shown; a click on the menu area shows it for 450 frames.
    state.showing_keys = state.key_list > 0
    if state.key_list > 0 then state.key_list = state.key_list - 1 end
    local x, y = held.pointer_x, held.pointer_y - state.vertical_offset
    -- (LF2 1.9 has no such list, nor its picture.)
    if held.click and not classic and x >= 0xdf and x < 0x23e and y > 0xc2 and y < 0x1b0 and x ~= 0 then state.key_list = 450 end
end

function title.draw(state, context)
    local classic = mod_settings.classic_menus()
    local menu = menus[classic]
    local offset = state.vertical_offset
    if classic then
        -- LF2 1.9's: on black, the logo whole (the mod's own version in it).
        context.viewport(constants.screen.width, constants.screen.height, 0, 0, 0)
        context.sprite("pe/menu_clip", {0, 41, 496, 80}, 153, 96 + offset, true)
    else
        context.viewport(constants.screen.width, constants.screen.height, 18, 37, 101)
        context.image("pe/menu_back" .. state.background, 0, offset, true)
        -- The logo without the version in its bottom-right corner, like the launch menu.
        context.sprite("pe/menu_clip", {0, 41, 434, 80}, 153, 96 + offset, true)
        context.sprite("pe/menu_clip", {434, 41, 62, 68}, 153 + 434, 96 + offset, true)
    end
    context.sprite(menu_sheet, {0, 116, 305, 213}, 244, menu.box_y + offset, true)
    if not classic then
        local replay = state.replay_disabled and {293, 504, 277, 25} or {405, 532, 277, 25}
        context.sprite(menu_sheet, replay, 257, 366 + offset, true)
    end
    local frame = menu.highlighted[state.selection + 1] or menu.highlighted[1]
    context.sprite(menu_sheet, frame, frame[5], frame[6] + offset, false)
    if state.showing_keys then
        context.sprite("pe/menu_clip5", {0, 389, 530, 200}, 5, 0x27, true)
        local settings = controls.current()
        for set = 1, 4 do
            for row = 1, 7 do
                local label, kind = controls.key_label(settings.sets[set].keys[row])
                font.gdi(context, label, (set - 1) * 0x6c - kind + 0x82, 0x5d + (row - 1) * 0x14, 0xffffff, 0x122565)
            end
        end
    end
    context.image("pe/lf2_cursor", math.min(state.pointer_x, 0x307), math.min(state.pointer_y + 2, 0x217), true)
end
function title.describe(state)
    return string.format("selection=%d key_list=%d", state.selection, state.key_list)
end
return title
