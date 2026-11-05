-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

local constants = require("base/game/constants")

local background = {}
local cache = {}
local view = constants.view -- the match's picture: a mod's own screen (openlf2.txt), else the classic one
-- The painter's fixed replacements for four converted rect: colors.
local remapped = {[0x175317] = 0x104f10, [0x575347] = 0x5a4e4b, [0x977757] = 0x9a6e5a, [0x473f1f] = 0x423818}
local function canonical(path)
    path = path:gsub("\\", "/"):lower()
    assert(path:match("^[a-z0-9_./-]+$"), "unsupported original resource path: " .. path)
    return path
end
function background.load(path)
    path = canonical(path)
    local data = cache[path]
    if not data then
        data = engine.read_background_data(path)
        for _, layer in ipairs(data.layers) do layer.resource = canonical(layer.path) end
        cache[path] = data
    end
    return data
end
-- Mutable per-view state: the original keeps one animation counter per layer slot.
function background.create_state(data)
    local counters = {}
    for index = 1, #data.layers do counters[index] = 0 end
    return {counters = counters}
end
-- C integer division truncates toward zero.
local function truncate(value)
    if value >= 0 then return math.floor(value) end
    return math.ceil(value)
end
local function parallax(layer, stage_width, camera_x)
    -- A stage exactly as wide as the screen never scrolls: nothing to move (the division would be by zero).
    if stage_width <= view.width then return 0 end
    return -truncate((layer.width - view.width) * camera_x / (stage_width - view.width))
end
-- Advances the counter on every paint call; hidden outside c1..c2.
local function visible(layer, state, index)
    if layer.cc <= 0 then return true end
    local counter = (state.counters[index] + 1) % layer.cc
    state.counters[index] = counter
    return counter >= layer.c1 and counter <= layer.c2
end
local function image(context, layer, x)
    context.image(layer.resource, x, layer.y, layer.transparency ~= 0)
end
-- Widescreen ("expand" layout). `wide` = {left, right, camera}: a window of the full screen width in
-- viewport coordinates, showing the battlefield from world x `camera` (always inside the stage, so the stage's
-- edges are the screen's edges). Nothing is scaled or
-- repeated. A layer's `width` is its scroll width (its bitmaps, often a pair side by side, are narrower), and a
-- layer wider than the window moves so that it covers the window at both ends of the stage; for a layer as wide as
-- the stage this is exactly the classic movement, so the ground stays with the fighters.
local function classic_x(layer, stage_width, wide)
    -- The classic camera that would have put the window where it is (the window is not always at the game's own
    -- camera): scenery moves with the window, so it stands still when the window does.
    local camera = math.floor(wide.camera * (stage_width - view.width) / (stage_width - (wide.right - wide.left)))
    local x = layer.x
    if stage_width > view.width then x = x + parallax(layer, stage_width, camera) end
    return x + camera - (wide.camera - wide.left)
end
local function wide_x(layer, stage_width, wide)
    local view_width = wide.right - wide.left
    -- A stage narrower than the window is centred, and every layer stays fixed to it.
    if stage_width <= view_width then return layer.x + wide.left - wide.camera end
    if layer.width >= view_width then
        return layer.x + wide.left - truncate((layer.width - view_width) * wide.camera / (stage_width - view_width))
    end
    -- Narrower than the window: scenery keeps its classic movement; an opaque backdrop (sky, ground) stands still, as
    -- moving it would uncover the window's left side at the end of the stage.
    if layer.transparency ~= 0 or layer.stands_still == false then return classic_x(layer, stage_width, wide) end
    return layer.x + wide.left
end
-- True for a layer that covers the whole classic screen at every camera position (a background, not a decoration).
local function spans_screen(layer)
    return layer.x <= 0 and layer.width >= view.width
end
-- Width of an original bitmap, read from its header (nil if it cannot be read).
local bitmap_widths = {}
local function bitmap_width(resource)
    local width = bitmap_widths[resource]
    if width == nil then
        width = false
        local ok, bytes = pcall(engine.read_resource, resource)
        if ok and type(bytes) == "string" and #bytes >= 26 and bytes:sub(1, 2) == "BM" then
            local b1, b2, b3, b4 = bytes:byte(19, 22)
            width = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
        end
        bitmap_widths[resource] = width
    end
    return width or nil
end
-- Opaque layers that sit at the same height with the same scroll width (a sky or ground made of several bitmaps)
-- form a group, and the group's extent is how far its bitmaps reach together.
local function prepare_groups(data)
    local group, previous
    for _, layer in ipairs(data.layers) do
        if layer.color == 0 and layer.loop == 0 then
            layer.bitmap_width = bitmap_width(layer.resource) or layer.width
            if previous and previous.y == layer.y and previous.width == layer.width
               and previous.transparency == layer.transparency then
                group.extent = math.max(group.extent, layer.x + layer.bitmap_width)
                group.first = math.min(group.first, layer.x)
            else
                group = {extent = layer.x + layer.bitmap_width, first = layer.x}
            end
            layer.group = group
            previous = layer
        else
            previous = nil
        end
    end
    -- Layers that share a scroll width belong together and must move together. Opaque layers (sky, ground) stand
    -- still when the window is wider than they scroll, unless scenery shares their scroll width, which then moves
    -- the classic way and takes them along.
    local scenery = {}
    for _, layer in ipairs(data.layers) do
        if layer.group and layer.transparency ~= 0 then scenery[layer.width] = true end
    end
    for _, layer in ipairs(data.layers) do
        if layer.group and layer.transparency == 0 then layer.stands_still = not scenery[layer.width] end
    end
    data.groups_ready = true
end
-- A layer's bitmaps cover only a range: from 0 (or from where its first bitmap starts, if that is further left) to
-- its scroll width (or its group's extent, if that reaches further), which can be narrower than the window. Beyond
-- the range the layer continues as its mirror image (a mirror joins without a seam; this also carries scenery such
-- as a mountain or a hedge on, and hides the gaps between layers), then as the original again, and so on.
local function continue_layer(context, layer, origin, wide)
    local low = math.min(0, layer.group.first)
    local range = math.max(layer.width, layer.group.extent) - low
    if range < 1 then return end
    local keyed = layer.transparency ~= 0
    local first = math.floor((wide.left - origin - low) / range)
    local last = math.floor((wide.right - 1 - origin - low) / range)
    for copy = math.max(first, -4), math.min(last, 4) do
        if copy % 2 ~= 0 then
            context.sprite(layer.resource, {0, 0, 0, 0},
                origin + 2 * low + (copy + 1) * range - layer.x - layer.bitmap_width, layer.y, keyed, true)
        elseif copy ~= 0 then
            context.sprite(layer.resource, {0, 0, 0, 0}, origin + copy * range + layer.x, layer.y, keyed)
        end
    end
end
-- Paints every layer in file order for a camera at world x `camera_x`; `bounds` (the visible part of the window on
-- the battlefield) and `wide` are given together for the widescreen layout.
function background.paint(context, data, state, camera_x, bounds, wide)
    local stage_width = assert(data.width, "background has no width")
    for index, layer in ipairs(data.layers) do
        if layer.color == 0 and layer.loop == 0 then
            if visible(layer, state, index) then
                if wide then
                    if not data.groups_ready then prepare_groups(data) end
                    local x = wide_x(layer, stage_width, wide)
                    image(context, layer, x)
                    continue_layer(context, layer, x - layer.x, wide)
                else
                    image(context, layer, layer.x + parallax(layer, stage_width, camera_x))
                end
            end
        elseif layer.color == 0 then
            if visible(layer, state, index) then
                -- The original never terminates on a loop step of zero or less (and divides by zero on a stage as wide
                -- as its screen, where a mod's own program draws the layer once, unmoved: so here).
                assert(layer.loop > 0, "negative background layer loop step")
                local offset
                local extend = false
                if not wide then offset = parallax(layer, stage_width, camera_x)
                else
                    offset = wide_x(layer, stage_width, wide) - layer.x
                    extend = layer.width >= stage_width or spans_screen(layer)
                end
                local first, last = layer.x, layer.width - 1
                -- Only a layer that covers the classic screen repeats beyond its own range; a narrower one (a fence
                -- along part of the arena) stays where it is.
                if extend then
                    local loops = math.floor((wide.left - offset - layer.x) / layer.loop)
                    first = math.min(first, layer.x + loops * layer.loop)
                    last = math.max(last, wide.right - offset)
                end
                for x = first, last, layer.loop do
                    image(context, layer, offset + x)
                end
            end
        elseif layer.width > 0 and layer.height > 0 then
            local color = (remapped[layer.color] or layer.color) % 16777216
            local x, width = layer.x, layer.width
            if bounds and x <= 0 and x + width >= view.width then
                x, width = bounds.left, bounds.right - bounds.left
            end
            context.fill(x, layer.y, width, layer.height,
                math.floor(color / 65536), math.floor(color / 256) % 256, color % 256)
        end
    end
end
background.lee_on_road = {name = "Lee On Road", width = 2400, zboundary = {350, 470},
    shadow = "pe/shadow1", shadow_size = {37, 9}, layers = {}}
local function cmod(a, b) return a - (a / b >= 0 and math.floor(a / b) or math.ceil(a / b)) * b end
local function rgb(context, x, y, width, height, color)
    context.fill(x, y, width, height, math.floor(color / 65536), math.floor(color / 256) % 256, color % 256)
end
function background.paint_lee_on_road(context, camera_x, bounds)
    local left = bounds and bounds.left or 0
    local width = bounds and bounds.right - bounds.left or view.width
    context.image("pe/back99_2", 250 - math.floor(camera_x / 100), 120, false)
    for x = 0, 3999, 500 do
        context.image("pe/back99_3", x - math.floor(camera_x * 7 / 10) + 30, 175, true)
    end
    rgb(context, left, 326, width, 20, 0x3f3f3f)
    rgb(context, left, 345, width, 156, 0x575757)
    rgb(context, left, 471, width, 30, 0x3f3f3f)
    rgb(context, left, 328, width, 2, 0x373737)
    local first, last = cmod(900 - camera_x, 70), 792
    if bounds then
        first = first + math.floor((bounds.left - first) / 70) * 70
        last = bounds.right
    end
    for x = first, last, 70 do
        rgb(context, x, 292, 1, 37, 0x577fa7)
        rgb(context, x + 1, 292, 1, 37, 0x2f4357)
    end
    rgb(context, left, 310, width, 1, 0x577fa7)
    rgb(context, left, 311, width, 1, 0x2f4357)
    rgb(context, left, 290, width, 1, 0x577fa7)
    rgb(context, left, 291, width, 1, 0x2f4357)
    for x = 0, 3199, 320 do
        context.image("pe/back99_1", x - camera_x + 10, 390, false)
    end
end
return background
