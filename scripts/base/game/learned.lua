-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

-- A web of Lua tables as text and back (OpenLF2 extension): what INSANE! and XOI learn of a fighter, written once to a
-- file of the mod (base/game/smart_ai learned_kit) and read instead of learned again. Every table reached from the
-- root is a line, in the order a walk from the root finds them, keys in a fixed order: the same web gives the same
-- text, and the text gives back the same web - tables met twice (a move in the list and in a chain) are one again.
-- A line is its keys and values, a token each, separated by spaces: n<number> (17 digits, the double exactly), I, J,
-- N (infinity, minus infinity, not a number), s<string> (% and what is not a visible character as %XX), T, F, r<line>
-- (a table of the web), and what `describe` names for a table that is not the web's own (a record, an object's
-- data: base/game/smart_ai), given back by `resolve`. Nothing in it runs: it is read as data.
local learned = {}
local format, tostring, tonumber, type, pairs, ipairs = string.format, tostring, tonumber, type, pairs, ipairs
local concat, sort, huge = table.concat, table.sort, math.huge

local function escape(text)
    return (text:gsub("[%%%c%s\128-\255]", function(char) return format("%%%02X", char:byte()) end))
end
local function unescape(text)
    if not text:find("%", 1, true) then return text end
    return (text:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end))
end
local function number_token(value)
    if value ~= value then return "N" end
    if value == huge then return "I" end
    if value == -huge then return "J" end
    return "n" .. format("%.17g", value)
end
-- Keys in a fixed order: numbers, then strings, then true before false, then named tables by their names.
local kind_order = {number = 1, string = 2, boolean = 3, table = 4}
local function key_less(a, b)
    local ka, kb = a.order, b.order
    if ka ~= kb then return ka < kb end
    if ka == 3 then return a.key == true and b.key == false end
    return a.sort < b.sort
end

-- The text of the web from `root` (the lines, without a header), and its number of lines; nil and a message when
-- something in it cannot be written (a function, a table used as a key that `describe` does not name, ...).
function learned.encode(root, describe)
    local index, order = {[root] = 1}, {root}
    local lines = {}
    local position = 1
    local problem
    local function token(value, where)
        local kind = type(value)
        if kind == "number" then return number_token(value) end
        if kind == "string" then return "s" .. escape(value) end
        if kind == "boolean" then return value and "T" or "F" end
        if kind == "table" then
            local named = describe(value)
            if named then return named end
            local at = index[value]
            if not at then
                at = #order + 1
                index[value], order[at] = at, value
            end
            return "r" .. at
        end
        problem = problem or ("cannot write a " .. kind .. " at " .. where)
        return "F"
    end
    while position <= #order do
        local node = order[position]
        local keys = {}
        for key in pairs(node) do
            local kind = type(key)
            local entry = {key = key, order = kind_order[kind] or 5}
            if kind == "number" then entry.sort = key
            elseif kind == "string" then entry.sort = key
            elseif kind == "table" then
                entry.sort = describe(key)
                if not entry.sort then problem = problem or ("a table as a key at line " .. position) end
                entry.sort = entry.sort or ""
            elseif kind ~= "boolean" then problem = problem or ("a " .. kind .. " as a key at line " .. position) end
            keys[#keys + 1] = entry
        end
        sort(keys, key_less)
        local parts = {}
        for _, entry in ipairs(keys) do
            local where = "line " .. position .. " key " .. tostring(entry.key)
            parts[#parts + 1] = token(entry.key, where)
            parts[#parts + 1] = token(node[entry.key], where)
        end
        lines[position] = concat(parts, " ")
        if problem then return nil, problem end
        position = position + 1
    end
    return concat(lines, "\n"), #lines
end

-- The web back from the lines of learned.encode (the text after a header: `count` lines), its root; nil and a
-- message for text that is not such lines. `resolve(token)` gives the table a name stands for, nil if none;
-- `between`, if given, is called every 256 lines (the learning ahead of base/game/smart_ai pauses there).
function learned.decode(text, count, resolve, between)
    if type(count) ~= "number" or count < 1 or count ~= math.floor(count) or count > #text + 1 then
        return nil, "a wrong number of lines"
    end
    local nodes = {}
    for line = 1, count do nodes[line] = {} end
    local problem
    local function value_of(token)
        local first = token:sub(1, 1)
        if first == "n" then
            local number = tonumber(token:sub(2))
            if not number then problem = problem or ("not a number: " .. token) end
            return number
        elseif first == "s" then return unescape(token:sub(2))
        elseif first == "r" then
            local node = nodes[tonumber(token:sub(2)) or 0]
            if not node then problem = problem or ("no such line: " .. token) end
            return node
        elseif first == "T" then return true
        elseif first == "F" then return false
        elseif first == "I" then return huge
        elseif first == "J" then return -huge
        elseif first == "N" then return 0 / 0
        end
        local named = resolve(token)
        if named == nil then problem = problem or ("unknown name: " .. token) end
        return named
    end
    local line = 0
    for row in (text .. "\n"):gmatch("([^\n]*)\n") do
        line = line + 1
        if line > count then return nil, "more lines than said" end
        if between and line % 256 == 0 then between() end
        local node = nodes[line]
        local key
        for token in row:gmatch("%S+") do
            if key == nil then
                key = value_of(token)
                if key == nil or key ~= key then problem = problem or ("a key of nothing on line " .. line) end
            else
                node[key] = value_of(token)
                key = nil
            end
            if problem then return nil, problem .. " (line " .. line .. ")" end
        end
        if key ~= nil then return nil, "a key without a value on line " .. line end
    end
    if line ~= count then return nil, "fewer lines than said" end
    return nodes[1]
end

return learned
