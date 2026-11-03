-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

local catalog = {}
local cached
local cached_backgrounds
local cached_objects
local function canonical(path)
    path = path:gsub("\\", "/"):lower()
    assert(path:match("^[a-z0-9_./-]+$"), "unsupported original resource path")
    return path
end
-- The original opens its data files in text mode (Microsoft's C library): every CR LF pair reaches
-- it as LF, and a file ends at its first Ctrl-Z. Encoded files are decoded after that.
local function text_mode(source)
    local stop = source:find("\26", 1, true)
    if stop then source = source:sub(1, stop - 1) end
    return (source:gsub("\r\n", "\n"))
end
local function data_text()
    return text_mode(engine.read_resource("data/data.txt"))
end
local function decode(source)
    source = text_mode(source)
    assert(#source >= 123, "truncated character data")
    local key = "SiuHungIsAGoodBearBecauseHeIsVeryGood"
    local result = {}
    for position = 124, #source do
        result[#result + 1] = string.char((source:byte(position) - key:byte((position - 1) % #key + 1)) % 256)
    end
    return table.concat(result)
end
-- The <object> records in file order, as the original reads them: word by word, each "id:" followed by five
-- words (the id, the word before the type, the type, the word before the file, the file), whatever the two
-- words in between say, and every other word passed over. The One Piece mod OPLoS 2.1X (OPLoS2.1X.exe) has
-- "fileb:" for "file:" in one record and lines of a lone "%", "$", "&" or "*", which the original reads past;
-- a note such as "#meat" after a record is passed over the same way. An id is a whole number, below zero too, as the
-- original reads it: Little Fighter Convergence (v0.3) has its hero Brad as "id: -1", and its readme lists him among
-- the fighters to play (here: below 30, so not hidden, and Random may give him).
local function object_records()
    local source = data_text()
    local section = assert(source:match("<object>(.-)<object_end>"), "missing object catalog")
    local words = {}
    for word in section:gmatch("%S+") do words[#words + 1] = word end
    local records = {}
    local position = 1
    while position <= #words do
        if words[position] == "id:" then
            local id, kind, path = words[position + 1], words[position + 3], words[position + 5]
            if not (id and id:match("^%-?%d+$") and kind and kind:match("^%d+$") and path) then
                error("invalid object catalog record: id: " .. tostring(id))
            end
            records[#records + 1] = {id = tonumber(id), kind = tonumber(kind), path = path}
            position = position + 6
        else
            position = position + 1
        end
    end
    return records
end
function catalog.load()
    if cached then return cached end
    local fighters = {}
    -- Object records are numbered in file order across all types, from 0.
    for index, entry in ipairs(object_records()) do
        if entry.kind == 0 then
            local id = entry.id
            local path = canonical(entry.path)
            local data = engine.read_resource(path)
            if path:sub(-4) == ".dat" then data = decode(data) end
            local header = assert(data:match("<bmp_begin>(.-)<bmp_end>"), "missing character header: " .. path)
            local name = assert(header:match("name:%s*(%S+)"), "missing character name: " .. path)
            local portrait = assert(header:match("head:%s*(%S+)"), "missing portrait: " .. path)
            local family = math.floor(id / 10)
            fighters[#fighters + 1] = {id = id, record = index - 1, name = name,
                portrait = canonical(portrait), path = path, hidden = family == 3 or family == 5}
            assert(#fighters <= 400, "too many character records")
        end
    end
    assert(#fighters > 0, "empty fighter catalog")
    cached = fighters
    return cached
end
function catalog.words_checksum()
    local source = data_text()
    local words = {}
    for word in source:gmatch("%S+") do words[#words + 1] = word end
    local sum, position, last = 0, 1, nil
    local function next_word()
        local word = words[position]
        position = position + 1
        return word
    end
    local function add(word)
        for index = 1, #word do
            local byte = word:byte(index)
            if byte > 127 then byte = byte - 256 end
            sum = sum + byte * (index - 1)
        end
    end
    local function skip_list(closing, extra)
        local word = next_word()
        while word ~= closing and word ~= nil do
            if word == "id:" then for _ = 1, extra do next_word() end end
            word = next_word()
        end
        return word
    end
    local repeated = false
    while true do
        local word = next_word()
        if word then last = word else word = last end
        if word then add(word) end
        if word == "<object>" then word = skip_list("<object_end>", 5) end
        if word == "<background>" then skip_list("<background_end>", 3) end
        if position > #words then
            if source:find("%s$") and not repeated then repeated = true else break end
        end
    end
    return sum
end

function catalog.selectable(fighter)
    return not fighter.hidden or require("base/game/unlock").flags.characters == 1
end
-- The fighters Random can give one slot, as list positions in file order. `original(fighter)` is
-- the original's test (below id 30, and so not hidden) and `taken(position)` whether a slot has
-- that fighter already. The original picks among the fighters its test takes that no slot has;
-- with none left (a mod with fewer fighters below id 30 than Random slots) it reads an
-- uninitialized one. Random here goes on to the selectable fighters no slot has, then to every
-- selectable fighter, so it always gives one.
function catalog.random_choices(fighters, original, taken)
    local choices = {}
    local function gather(test)
        for position, fighter in ipairs(fighters) do
            if test(position, fighter) then choices[#choices + 1] = position end
        end
        return #choices > 0
    end
    local _ = gather(function(position, fighter) return original(fighter) and not taken(position) end)
        or gather(function(position, fighter) return catalog.selectable(fighter) and not taken(position) end)
        or gather(function(_, fighter) return catalog.selectable(fighter) end)
        or gather(function() return true end)
    return choices
end
-- The next (step 1) or previous (step -1) selectable fighter after list position `position`
-- (0 is Random); running past either end gives Random, as the original's -1.
function catalog.step(fighters, position, step)
    repeat
        position = (position + step) % (#fighters + 1)
    until position == 0 or catalog.selectable(fighters[position])
    return position
end
-- Every <object> record in file order: {id, kind (type:), path}. FindRecordIndex in the original
-- takes the first record with a given id.
function catalog.objects()
    if cached_objects then return cached_objects end
    local objects, by_id = {}, {}
    for _, record in ipairs(object_records()) do
        local entry = {id = record.id, kind = record.kind, path = canonical(record.path)}
        objects[#objects + 1] = entry
        if not by_id[entry.id] then by_id[entry.id] = entry end
        assert(#objects <= 500, "too many object records")
    end
    cached_objects = {list = objects, by_id = by_id}
    return cached_objects
end

function catalog.backgrounds()
    if cached_backgrounds then return cached_backgrounds end
    local source = data_text()
    local section = assert(source:match("<background>(.-)<background_end>"), "missing background catalog")
    local backgrounds = {}
    for id, path in section:gmatch("id:%s*(%d+)%s+%S+%s+(%S+)") do
        backgrounds[#backgrounds + 1] = {id = tonumber(id), path = canonical(path)}
        assert(#backgrounds <= 100, "too many background records")
    end
    assert(#backgrounds > 0, "empty background catalog")
    cached_backgrounds = backgrounds
    return backgrounds
end
return catalog
