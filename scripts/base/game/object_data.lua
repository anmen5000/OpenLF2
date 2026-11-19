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
-- The picture a frame shows, `offset` on (the second colour set: 140 after a record transform, states 8000-8999, a
-- battle side's soldiers, a stage enemy joining the players). A record without pictures there shows its own (OpenLF2
-- extension): the original draws nothing - Naruto: The Setting Dawn 2.6's Deidara was gone once his D^J had put him
-- on his bird (state 8058, the bird's pictures 0-34 only), and when he got off it too.
function object_data.picture(data, frame_id, offset)
    local frame = data.frames[frame_id]
    if not frame then return nil end
    local resource, source = sheet_cell(data, frame.picture + (offset or 0))
    if not resource and offset and offset ~= 0 then resource, source = sheet_cell(data, frame.picture) end
    return resource, source
end
return object_data
