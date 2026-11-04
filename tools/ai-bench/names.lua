-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors
-- Fighters by name, for the jobs that take fighter ids (show, duel): a fighter is named by its id (8, or "8"),
-- by its name in the mod ("Crimson", the name: line of its .dat file), by the name of its file ("crimson" for
-- sprite\crimson\crimson.dat), or by the start of one of those when only one fighter's starts so ("crim");
-- capitals and small letters alike.
local names = {}

local function stem(path)
    local file = tostring(path or ""):match("([^/\\]+)$") or ""
    return (file:gsub("%.[^.]*$", ""))
end

-- The index in `fighters` (catalog.load()) of the fighter `wanted` names, or nil and why not.
function names.find(fighters, wanted)
    if type(wanted) == "number" then
        for index, fighter in ipairs(fighters) do if fighter.id == wanted then return index end end
        return nil, string.format("no fighter has id %s", tostring(wanted))
    end
    local text = tostring(wanted or ""):match("^%s*(.-)%s*$")
    if text == "" then return nil, "no fighter named" end
    local number = tonumber(text)
    if number then return names.find(fighters, number) end
    local key = text:lower()
    for _, field in ipairs({"name", "file"}) do
        for index, fighter in ipairs(fighters) do
            local value = field == "name" and fighter.name or stem(fighter.path)
            if value:lower() == key then return index end
        end
    end
    local found, seen = {}, {}
    for index, fighter in ipairs(fighters) do
        for _, value in ipairs({fighter.name, stem(fighter.path)}) do
            if value:lower():sub(1, #key) == key and not seen[fighter.id] then
                seen[fighter.id] = true
                found[#found + 1] = index
            end
        end
    end
    if #found == 1 then return found[1] end
    if #found > 1 then
        local list = {}
        for _, index in ipairs(found) do list[#list + 1] = string.format("%d %s", fighters[index].id, fighters[index].name) end
        return nil, string.format("\"%s\" could be %s", text, table.concat(list, ", "))
    end
    return nil, string.format("no fighter named \"%s\"", text)
end

-- "8 Crimson, 25 Deep, ...": the fighters of the mod, for a message.
function names.listing(fighters)
    local list, seen = {}, {}
    for _, fighter in ipairs(fighters) do
        if not seen[fighter.id] then
            seen[fighter.id] = true
            list[#list + 1] = string.format("%d %s", fighter.id, fighter.name)
        end
    end
    return table.concat(list, ", ")
end

-- A background's name (its bg.dat's name: line), or "?" when it cannot be read.
function names.background_name(entry)
    local ok, data = pcall(require("base/game/background").load, entry.path)
    return ok and data and data.name or "?"
end

-- The row (0 on, as the match takes it) of the background `wanted` names in `backgrounds` (catalog.backgrounds()):
-- its row number, its name ("Lion Forest"; spaces, capitals and small letters alike), the name of its folder
-- ("lf" for bg/sys/lf/bg.dat), or the start of one of those when only one background's starts so; nil and why not.
function names.background(backgrounds, wanted)
    local function plain(text) return (tostring(text or ""):gsub("%s+", ""):lower()) end
    local number = tonumber(wanted)
    if number then
        if backgrounds[number + 1] then return number end
        return nil, string.format("no background in row %s", tostring(wanted))
    end
    local key = plain(wanted)
    if key == "" then return nil, "no background named" end
    local keys = {}
    for row, entry in ipairs(backgrounds) do
        keys[row] = {plain(names.background_name(entry)), plain(tostring(entry.path):match("([^/\\]+)[/\\][^/\\]+$"))}
    end
    for _, field in ipairs({1, 2}) do
        for row in ipairs(backgrounds) do
            if keys[row][field] == key then return row - 1 end
        end
    end
    local found = {}
    for row in ipairs(backgrounds) do
        if keys[row][1]:sub(1, #key) == key or keys[row][2]:sub(1, #key) == key then found[#found + 1] = row - 1 end
    end
    if #found == 1 then return found[1] end
    return nil, string.format(#found > 1 and "\"%s\" could be several backgrounds" or "no background named \"%s\"", tostring(wanted))
end

-- The id of the fighter `wanted` names; an error naming the mod's fighters when there is none.
function names.id(fighters, wanted)
    local index, problem = names.find(fighters, wanted)
    if index then return fighters[index].id end
    error(problem .. ". The fighters of this mod: " .. names.listing(fighters), 0)
end
return names
