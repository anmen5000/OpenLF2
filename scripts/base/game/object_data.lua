-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

local object_data = {}
local cache = {}
local paths = {} -- the path of each data loaded (object_data.path_of)
local function canonical(path)
    path = path:gsub("\\", "/"):lower()
    assert(path:match("^[a-z0-9_./-]+$"), "unsupported original resource path: " .. path)
    return path
end
function object_data.load(path)
    path = canonical(path)
    local data = cache[path]
    if not data then
        data = engine.read_object_data(path)
        for _, sheet in ipairs(data.sheets) do sheet.resource = canonical(sheet.path) end
        cache[path], paths[data] = data, path
    end
    return data
end
-- The path a data was loaded from (canonical), nil for a table object_data.load did not give; and every data loaded,
-- by path (not to be changed).
function object_data.path_of(data) return paths[data] end
function object_data.loaded() return cache end
local function sheet_cell(data, picture)
    for _, sheet in ipairs(data.sheets) do
        local cell = picture - sheet.first_picture
        if cell >= 0 and cell < sheet.columns * sheet.rows then
            local column, row = cell % sheet.columns, math.floor(cell / sheet.columns)
            return sheet.resource, {column * (sheet.cell_width + 1), row * (sheet.cell_height + 1),
                sheet.cell_width, sheet.cell_height}
        end
    end
    return nil
end
-- The picture a frame shows, `offset` on: the second colour set of the original's soldiers (140, a battle side's or
-- a stage enemy joining the players; 114 for knights), and 140 after any record transform (states 8000-8999), as the
-- original sets it. A mod's records are often made without pictures there (OpenLF2 extension): the original then draws
-- nothing, or another picture of the record - Naruto: The Setting Dawn 2.6's Deidara was gone once his D^J had put
-- him on his bird (state 8058, the bird's pictures 0-34) and when he got off it, Kimimaro in his D^A form: 29 of the
-- mod's 39 changes (Rock Lee changed into Might Guy showed other pictures of Guy in 31 frames and nothing in the rest). Others of the same mod have their sheets declared again from 140 (Sasuke's curse seal) or a second set
-- there (Itachi's, who changes into himself to show it). A record shows its pictures at the offset only when most of
-- its frames have one there, and a frame without one shows its own.
local offset_sets = {} -- [data][offset]: whether most frames have a picture at the offset
local function has_offset_set(data, offset)
    local by_data = offset_sets[data]
    if not by_data then
        by_data = {}
        offset_sets[data] = by_data
    end
    local known = by_data[offset]
    if known ~= nil then return known end
    local with, without = 0, 0
    for _, frame in pairs(data.frames) do
        if sheet_cell(data, frame.picture) then
            if sheet_cell(data, frame.picture + offset) then with = with + 1 else without = without + 1 end
        end
    end
    known = with > without
    by_data[offset] = known
    return known
end
function object_data.picture(data, frame_id, offset)
    local frame = data.frames[frame_id]
    if not frame then return nil end
    if offset and offset ~= 0 and not has_offset_set(data, offset) then offset = 0 end
    local resource, source = sheet_cell(data, frame.picture + (offset or 0))
    if not resource and offset and offset ~= 0 then resource, source = sheet_cell(data, frame.picture) end
    return resource, source
end
return object_data
