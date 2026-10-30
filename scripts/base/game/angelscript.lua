-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

-- Mods' AI scripts (ai/<id>.as, for the community's ddraw.dll AI script engine) are AngelScript. This
-- compiles the part of the language they use to Lua text, typed as AngelScript types it: functions,
-- global and local variables (int and its sized kinds, float, double, bool, string, array<T> and T[],
-- the API's handle types), if/else, for, while, do/while, switch, break, continue, return, and C's
-- expressions with ?:, ++/--, compound assignment and casts such as int(x). Integer division and %
-- truncate toward zero and raise AngelScript's "Divide by zero" exception; a double stored in an
-- int is truncated. Anything else is a compile error that names the file and line; the caller then
-- leaves that character to the built-in AI.
--
-- api describes what the scripts see (base/game/ai_scripts): api.globals[name] = {type, code},
-- api.functions[name] = {result, params = {type...}, defaults = {...}, code}, api.classes[type] =
-- {fields = {name = {type, code}}, index = element type, methods = {...}}, where each code is a
-- Lua text template with "$" for the object and "$1".."$9" for the arguments.

local angelscript = {}

local integer_types = {int = true, int8 = true, int16 = true, int32 = true, int64 = true,
    uint = true, uint8 = true, uint16 = true, uint32 = true, uint64 = true}
local float_types = {float = true, double = true}
local keywords = {["if"] = true, ["else"] = true, ["for"] = true, ["while"] = true, ["do"] = true,
    ["switch"] = true, ["case"] = true, ["default"] = true, ["break"] = true, ["continue"] = true,
    ["return"] = true, ["true"] = true, ["false"] = true, ["null"] = true, ["const"] = true,
    ["cast"] = true, ["and"] = true, ["or"] = true, ["not"] = true, ["xor"] = true}
local operators = {">>>=", "<<=", ">>=", ">>>", "**=", "==", "!=", "<=", ">=", "&&", "||", "^^", "++", "--",
    "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<", ">>", "**", "::"}

local function failure(file, line, message)
    error({angelscript = true, message = file .. "(" .. line .. "): " .. message}, 0)
end

-- Tokens: {kind = "name"|"number"|"string"|"op"|"eof", value, line, float}.
local function tokenize(source, file)
    local tokens, position, line = {}, 1, 1
    local length = #source
    -- The script builder's preprocessor: #if/#elif/#else/#endif on defined words (none here) and #define.
    local defined, skipping, stack = {}, false, {}
    local function add(kind, value, extra)
        if not skipping then tokens[#tokens + 1] = {kind = kind, value = value, line = line, float = extra} end
    end
    while position <= length do
        local c = source:sub(position, position)
        if c == "\n" then
            line = line + 1
            position = position + 1
        elseif c:match("%s") then
            position = position + 1
        elseif c == "#" then
            local stop = source:find("\n", position, true) or length + 1
            local directive = source:sub(position + 1, stop - 1)
            local word, rest = directive:match("^%s*(%a+)%s*(.-)%s*$")
            if word == "if" then
                stack[#stack + 1] = skipping
                skipping = skipping or not defined[rest]
            elseif word == "elif" or word == "else" then
                local outer = stack[#stack]
                if outer == nil then failure(file, line, "#" .. word .. " without #if") end
                skipping = outer or not skipping or (word == "elif" and not defined[rest])
            elseif word == "endif" then
                if #stack == 0 then failure(file, line, "#endif without #if") end
                skipping = table.remove(stack)
            elseif word == "define" then
                if not skipping then defined[rest] = true end
            elseif not skipping then
                failure(file, line, "unsupported directive #" .. tostring(word))
            end
            position = stop
        elseif source:sub(position, position + 1) == "//" then
            position = source:find("\n", position, true) or length + 1
        elseif source:sub(position, position + 1) == "/*" then
            local stop = source:find("*/", position + 2, true)
            if not stop then failure(file, line, "unterminated comment") end
            for _ in source:sub(position, stop):gmatch("\n") do line = line + 1 end
            position = stop + 2
        elseif c:match("[%a_]") then
            local word = source:match("^[%w_]+", position)
            add("name", word)
            position = position + #word
        elseif c:match("%d") or (c == "." and source:sub(position + 1, position + 1):match("%d")) then
            local hex = source:match("^0[xX]%x+", position)
            if hex then
                add("number", tonumber(hex:sub(3), 16), false)
                position = position + #hex
            else
                local text = source:match("^%d*%.?%d*", position)
                local exponent = source:match("^[eE][+-]?%d+", position + #text)
                local float = text:find(".", 1, true) ~= nil or exponent ~= nil
                local value = tonumber(text .. (exponent or ""))
                position = position + #text + #(exponent or "")
                local suffix = source:sub(position, position)
                if suffix == "f" or suffix == "F" or suffix == "d" or suffix == "D" then
                    float, position = true, position + 1
                elseif suffix == "u" or suffix == "U" or suffix == "l" or suffix == "L" then
                    position = position + 1
                end
                add("number", value, float)
            end
        elseif c == '"' or c == "'" then
            local parts, at = {}, position + 1
            local triple = c == '"' and source:sub(position, position + 2) == '"""'
            if triple then
                local stop = source:find('"""', position + 3, true)
                if not stop then failure(file, line, "unterminated string") end
                local text = source:sub(position + 3, stop - 1)
                for _ in text:gmatch("\n") do line = line + 1 end
                add("string", text)
                position = stop + 3
            else
                while true do
                    local ch = source:sub(at, at)
                    if ch == "" or ch == "\n" then failure(file, line, "unterminated string") end
                    if ch == c then break end
                    if ch == "\\" then
                        local escaped = source:sub(at + 1, at + 1)
                        local map = {n = "\n", t = "\t", r = "\r", ["0"] = "\0", ["\\"] = "\\", ['"'] = '"', ["'"] = "'"}
                        parts[#parts + 1] = map[escaped] or escaped
                        at = at + 2
                    else
                        parts[#parts + 1] = ch
                        at = at + 1
                    end
                end
                add("string", table.concat(parts))
                position = at + 1
            end
        else
            local matched
            for _, op in ipairs(operators) do
                if source:sub(position, position + #op - 1) == op then matched = op break end
            end
            matched = matched or c
            if not matched:match("^[%p]+$") then failure(file, line, "unexpected character") end
            add("op", matched)
            position = position + #matched
        end
    end
    if #stack > 0 then failure(file, line, "#if without #endif") end
    tokens[#tokens + 1] = {kind = "eof", value = "<end of file>", line = line}
    return tokens
end

-- The compiler state: tokens, position, output, scopes, names.
local function new_compiler(source, file, api)
    return {file = file, api = api, tokens = tokenize(source, file), at = 1, scopes = {},
        functions = {}, globals = {}, labels = 0, loops = {}, lines = {}, indent = 1}
end

local function peek(c, offset) return c.tokens[c.at + (offset or 0)] end
local function line_of(c) return peek(c).line end
local function fail(c, message) failure(c.file, line_of(c), message) end
local function check(c, value, offset)
    local token = peek(c, offset)
    return token.kind ~= "string" and token.kind ~= "number" and token.value == value
end
local function accept(c, value)
    if check(c, value) then c.at = c.at + 1 return true end
    return false
end
local function expect(c, value)
    if not accept(c, value) then fail(c, "expected '" .. value .. "' but found '" .. tostring(peek(c).value) .. "'") end
end
local function name(c)
    local token = peek(c)
    if token.kind ~= "name" or keywords[token.value] then fail(c, "expected a name but found '" .. tostring(token.value) .. "'") end
    c.at = c.at + 1
    return token.value
end
local function emit(c, text) c.lines[#c.lines + 1] = string.rep("  ", c.indent) .. text end
local function label(c, prefix)
    c.labels = c.labels + 1
    return prefix .. c.labels
end

-- Types: "int", "double", "bool", "string", "void", "array:<element>", or an API class name.
local function is_number(t) return t == "int" or t == "double" end
local function known_class(c, t) return c.api.classes[t] ~= nil end
local function type_start(c, offset)
    offset = offset or 0
    local token = peek(c, offset)
    if token.kind ~= "name" then return false end
    local word = token.value
    if word == "const" then return true end
    return integer_types[word] or float_types[word] or word == "bool" or word == "string" or word == "void"
        or word == "auto" or word == "array" or known_class(c, word)
end
-- type := ['const'] base ['<' type '>'] {'[' ']'} ['@'] ['&' ['in'|'out'|'inout']]
local function parse_type(c)
    accept(c, "const")
    local word = name(c)
    local t
    if integer_types[word] then t = "int"
    elseif float_types[word] then t = "double"
    elseif word == "bool" or word == "string" or word == "void" or word == "auto" then t = word
    elseif word == "array" then
        expect(c, "<")
        local element = parse_type(c)
        if check(c, ">>") then
            -- array<array<int>>: split the token.
            c.tokens[c.at].value = ">"
            table.insert(c.tokens, c.at + 1, {kind = "op", value = ">", line = line_of(c)})
        end
        expect(c, ">")
        t = "array:" .. element
    elseif known_class(c, word) then t = word
    else fail(c, "unknown type '" .. word .. "'") end
    while check(c, "[") and check(c, "]", 1) do
        c.at = c.at + 2
        t = "array:" .. t
    end
    accept(c, "@")
    if accept(c, "&") then
        if check(c, "in") or check(c, "out") or check(c, "inout") then c.at = c.at + 1 end
    end
    accept(c, "const")
    return t
end

local function default_value(t)
    if t == "int" or t == "double" then return "0" end
    if t == "bool" then return "false" end
    if t == "string" then return '""' end
    if t:sub(1, 6) == "array:" then return "R.array_new(0)" end
    return "nil"
end

-- Variables: scopes hold {name = {lua, type, const}}.
local function declare(c, script_name, t, const)
    local scope = c.scopes[#c.scopes]
    local lua = "v_" .. script_name .. "_" .. #c.scopes
    scope[script_name] = {lua = lua, type = t, const = const}
    return lua
end
local function lookup(c, script_name)
    for index = #c.scopes, 1, -1 do
        local found = c.scopes[index][script_name]
        if found then return found end
    end
    return c.globals[script_name]
end

local function convert(c, code, from, to)
    if to == from or to == "auto" then return code end
    if to == "int" then
        if from == "double" then return "R.trunc(" .. code .. ")" end
        if from == "int" then return code end
    elseif to == "double" then
        if from == "int" or from == "double" then return code end
    elseif to == "bool" then
        if from == "bool" then return code end
    elseif to == "string" then
        if from == "string" then return code end
    elseif from == "null" then
        return "nil"
    elseif to == from then
        return code
    end
    fail(c, "cannot convert " .. from .. " to " .. to)
end
local function condition(c, code, t)
    if t == "bool" then return code end
    if is_number(t) then return "(" .. code .. " ~= 0)" end
    fail(c, "a condition must be bool, not " .. t)
end

local function template(code, object, args)
    return (code:gsub("%$(%d?)", function(digit)
        if digit == "" then return object end
        return args[tonumber(digit)] or "nil"
    end))
end

local expression
local assignment

local function arguments(c)
    local list = {}
    expect(c, "(")
    if not accept(c, ")") then
        repeat list[#list + 1] = {assignment(c)} until not accept(c, ",")
        expect(c, ")")
    end
    return list
end

-- A call of an API function or a script function; args = {{code, type}...}.
local function call(c, script_name, args)
    local user = c.functions[script_name]
    if user then
        local chosen
        for _, candidate in ipairs(user) do
            local required = 0
            for index = 1, #candidate.params do
                if candidate.params[index].default == nil then required = index end
            end
            if #args >= required and #args <= #candidate.params then chosen = candidate break end
        end
        if not chosen then fail(c, "no '" .. script_name .. "' takes " .. #args .. " arguments") end
        local codes = {}
        for index, param in ipairs(chosen.params) do
            if args[index] then codes[index] = convert(c, args[index][1], args[index][2], param.type)
            else codes[index] = param.default end
        end
        return chosen.lua .. "(" .. table.concat(codes, ", ") .. ")", chosen.result
    end
    local api = c.api.functions[script_name]
    if not api then fail(c, "unknown function '" .. script_name .. "'") end
    local codes = {}
    local count = math.max(#args, #(api.params or {}))
    for index = 1, count do
        local wanted = api.params and api.params[index]
        if args[index] then
            if wanted == "number" then
                if not is_number(args[index][2]) and args[index][2] ~= "bool" then fail(c, script_name .. " expects a number") end
                codes[index] = args[index][2] == "bool" and "(" .. args[index][1] .. " and 1 or 0)" or args[index][1]
            elseif wanted == "any" or wanted == nil then
                codes[index] = args[index][1]
                if wanted == nil and api.params then fail(c, "too many arguments for '" .. script_name .. "'") end
            else
                codes[index] = convert(c, args[index][1], args[index][2], wanted)
            end
        elseif api.defaults and api.defaults[index] ~= nil then
            codes[index] = api.defaults[index]
        else
            fail(c, "missing argument " .. index .. " for '" .. script_name .. "'")
        end
    end
    local result = api.result
    if type(result) == "function" then result = result(args) end
    return template(api.code, "", codes), result
end

local function member(c, object, t, field)
    local class = c.api.classes[t]
    if t:sub(1, 6) == "array:" then
        if field == "length" or field == "size" or field == "insertLast" or field == "resize" or field == "removeAt"
           or field == "removeLast" or field == "insertAt" or field == "isEmpty" or field == "find" or field == "reverse" then
            return object, t, field
        end
        fail(c, "arrays have no '" .. field .. "' here")
    end
    if not class then fail(c, t .. " has no members") end
    local entry = class.fields and class.fields[field]
    if entry then return template(entry[2], object, {}), entry[1] end
    if class.methods and class.methods[field] then return object, t, field end
    fail(c, t .. " has no member '" .. field .. "'")
end

local function array_method(c, object, t, method, args)
    local element = t:sub(7)
    local function arg(index, wanted)
        if not args[index] then fail(c, method .. " needs argument " .. index) end
        return convert(c, args[index][1], args[index][2], wanted)
    end
    if method == "length" or method == "size" then return "R.array_length(" .. object .. ")", "int" end
    if method == "isEmpty" then return "(R.array_length(" .. object .. ") == 0)", "bool" end
    if method == "insertLast" then return "R.array_insert(" .. object .. ", nil, " .. arg(1, element) .. ")", "void" end
    if method == "insertAt" then return "R.array_insert(" .. object .. ", " .. arg(1, "int") .. ", " .. arg(2, element) .. ")", "void" end
    if method == "removeAt" then return "R.array_remove(" .. object .. ", " .. arg(1, "int") .. ")", "void" end
    if method == "removeLast" then return "R.array_remove(" .. object .. ", nil)", "void" end
    if method == "resize" then return "R.array_resize(" .. object .. ", " .. arg(1, "int") .. ", " .. default_value(element) .. ")", "void" end
    if method == "find" then return "R.array_find(" .. object .. ", " .. arg(1, element) .. ")", "int" end
    if method == "reverse" then return "R.array_reverse(" .. object .. ")", "void" end
    fail(c, "arrays have no method '" .. method .. "'")
end

-- Postfix: member access, index, call. Returns code, type, and for lvalues a setter description.
local function primary(c)
    local token = peek(c)
    if token.kind == "number" then
        c.at = c.at + 1
        local text = token.float and string.format("%.17g", token.value) or string.format("%d", token.value)
        if token.float and not text:find("[%.e]") then text = text .. ".0" end
        return text, token.float and "double" or "int"
    elseif token.kind == "string" then
        c.at = c.at + 1
        local parts = {token.value}
        while peek(c).kind == "string" do parts[#parts + 1] = peek(c).value c.at = c.at + 1 end
        local quoted = string.format("%q", table.concat(parts)):gsub("\\\n", "\\n")
        return quoted, "string"
    elseif accept(c, "true") then return "true", "bool"
    elseif accept(c, "false") then return "false", "bool"
    elseif accept(c, "null") then return "nil", "null"
    elseif accept(c, "(") then
        local code, t = expression(c)
        expect(c, ")")
        return "(" .. code .. ")", t
    elseif accept(c, "cast") then
        expect(c, "<")
        local t = parse_type(c)
        expect(c, ">")
        expect(c, "(")
        local code, from = expression(c)
        expect(c, ")")
        return convert(c, code, from, t), t
    elseif token.kind == "name" and (integer_types[token.value] or float_types[token.value] or token.value == "bool")
        and check(c, "(", 1) then
        -- Conversions: int(x), float(x), double(x).
        local t = parse_type(c)
        expect(c, "(")
        local code, from = expression(c)
        expect(c, ")")
        if t == "int" and from == "double" then return "R.trunc(" .. code .. ")", "int" end
        if t == "bool" then return condition(c, code, from), "bool" end
        if not is_number(from) then fail(c, "cannot convert " .. from .. " to " .. t) end
        return code, t
    elseif token.kind == "name" then
        local script_name = name(c)
        if check(c, "(") then
            local args = arguments(c)
            return call(c, script_name, args)
        end
        local variable = lookup(c, script_name)
        if variable then
            return variable.lua, variable.type, {variable = variable}
        end
        local global = c.api.globals[script_name]
        if global then return global[2], global[1], {api = script_name, const = global.const} end
        fail(c, "unknown name '" .. script_name .. "'")
    end
    fail(c, "unexpected '" .. tostring(token.value) .. "'")
end

local function postfix(c)
    local code, t, lvalue = primary(c)
    while true do
        if accept(c, ".") then
            local field = name(c)
            local object = code
            local method
            code, t, method = member(c, object, t, field)
            lvalue = nil
            if method then
                local args = arguments(c)
                if t:sub(1, 6) == "array:" then
                    code, t = array_method(c, object, t, method, args)
                else
                    local entry = c.api.classes[t].methods[method]
                    local codes = {}
                    for index, a in ipairs(args) do codes[index] = a[1] end
                    code, t = template(entry[2], object, codes), entry[1]
                end
            end
        elseif accept(c, "[") then
            local index, index_type = expression(c)
            expect(c, "]")
            index = convert(c, index, index_type, "int")
            if t:sub(1, 6) == "array:" then
                lvalue = {array = code, index = index, element = t:sub(7)}
                code, t = "R.array_get(" .. code .. ", " .. index .. ")", t:sub(7)
            else
                local class = c.api.classes[t]
                if not class or not class.index then fail(c, t .. " cannot be indexed") end
                code, t = template(class.index[2], code, {index}), class.index[1]
                lvalue = nil
            end
        elseif check(c, "++") or check(c, "--") then
            break
        else
            break
        end
    end
    return code, t, lvalue
end

local function store(c, lvalue, code)
    if lvalue.variable then
        if lvalue.variable.const then fail(c, "cannot assign to a constant") end
        return lvalue.variable.lua .. " = " .. code
    elseif lvalue.array then
        return "R.array_set(" .. lvalue.array .. ", " .. lvalue.index .. ", " .. code .. ")"
    end
    fail(c, "cannot assign to this")
end

-- Statement-level increments and assignments (AngelScript allows them inside expressions too; the
-- scripts use them as statements and in for-loop steps, which is what this supports).
local arithmetic

local function unary(c)
    if accept(c, "-") then
        local code, t = unary(c)
        if not is_number(t) then fail(c, "unary - needs a number") end
        return "(-" .. code .. ")", t
    elseif accept(c, "+") then
        return unary(c)
    elseif accept(c, "!") or accept(c, "not") then
        local code, t = unary(c)
        return "(not " .. condition(c, code, t) .. ")", "bool"
    elseif accept(c, "~") then
        local code, t = unary(c)
        if t ~= "int" then fail(c, "~ needs an int") end
        return "R.bnot(" .. code .. ")", "int"
    elseif check(c, "++") or check(c, "--") then
        fail(c, "++ and -- inside expressions are not supported")
    elseif accept(c, "@") then
        return unary(c)
    end
    -- A postfix ++/-- is left for statement_expression (a statement or a for-loop step).
    return postfix(c)
end

local function binary_numeric(c, op, a, at, b, bt)
    if op == "+" and (at == "string" or bt == "string") then
        return "R.concat(" .. a .. ", " .. b .. ")", "string"
    end
    if not is_number(at) or not is_number(bt) then fail(c, "'" .. op .. "' needs numbers, not " .. at .. " and " .. bt) end
    local t = (at == "double" or bt == "double") and "double" or "int"
    if op == "/" then
        if t == "int" then return "R.idiv(" .. a .. ", " .. b .. ")", "int" end
        return "(" .. a .. " / " .. b .. ")", "double"
    elseif op == "%" then
        if t == "int" then return "R.imod(" .. a .. ", " .. b .. ")", "int" end
        return "R.fmod(" .. a .. ", " .. b .. ")", "double"
    elseif op == "**" then
        return "(" .. a .. " ^ " .. b .. ")", "double"
    elseif op == "<<" or op == ">>" or op == ">>>" or op == "&" or op == "|" or op == "^" then
        if t ~= "int" then fail(c, "'" .. op .. "' needs ints") end
        local names = {["<<"] = "shl", [">>"] = "shr", [">>>"] = "shr", ["&"] = "band", ["|"] = "bor", ["^"] = "bxor"}
        return "R." .. names[op] .. "(" .. a .. ", " .. b .. ")", "int"
    end
    return "(" .. a .. " " .. op .. " " .. b .. ")", t
end

-- Precedence climbing over AngelScript's binary operators.
local levels = {
    {["||"] = "or", ["or"] = "or", ["^^"] = "xor", ["xor"] = "xor"},
    {["&&"] = "and", ["and"] = "and"},
    {["|"] = "|"}, {["^"] = "^"}, {["&"] = "&"},
    {["=="] = "==", ["!="] = "~="},
    {["<"] = "<", ["<="] = "<=", [">"] = ">", [">="] = ">="},
    {["<<"] = "<<", [">>"] = ">>", [">>>"] = ">>>"},
    {["+"] = "+", ["-"] = "-"},
    {["*"] = "*", ["/"] = "/", ["%"] = "%"},
    {["**"] = "**"},
}
local function binary(c, level)
    if level > #levels then return unary(c) end
    local code, t, lvalue = binary(c, level + 1)
    while true do
        local token = peek(c)
        local op = token.kind == "op" and levels[level][token.value]
            or (token.kind == "name" and levels[level][token.value])
        if not op then break end
        c.at = c.at + 1
        local right, rt = binary(c, level + 1)
        lvalue = nil
        if op == "or" or op == "and" then
            code, t = "(" .. condition(c, code, t) .. " " .. op .. " " .. condition(c, right, rt) .. ")", "bool"
        elseif op == "xor" then
            code, t = "(" .. condition(c, code, t) .. " ~= " .. condition(c, right, rt) .. ")", "bool"
        elseif op == "==" or op == "~=" then
            if is_number(t) and rt == "bool" then right = "(" .. right .. " and 1 or 0)"
            elseif t == "bool" and is_number(rt) then code = "(" .. code .. " and 1 or 0)" end
            code, t = "(" .. code .. " " .. op .. " " .. right .. ")", "bool"
        elseif op == "<" or op == "<=" or op == ">" or op == ">=" then
            if not ((is_number(t) and is_number(rt)) or (t == "string" and rt == "string")) then
                fail(c, "'" .. op .. "' needs numbers")
            end
            code, t = "(" .. code .. " " .. op .. " " .. right .. ")", "bool"
        else
            code, t = binary_numeric(c, op, code, t, right, rt)
        end
    end
    return code, t, lvalue
end

local function ternary(c)
    local code, t, lvalue = binary(c, 1)
    if accept(c, "?") then
        local yes, yt = assignment(c)
        expect(c, ":")
        local no, nt = assignment(c)
        local result = yt
        if yt ~= nt then
            if is_number(yt) and is_number(nt) then result = "double"
            elseif nt == "null" then result = yt
            elseif yt == "null" then result = nt
            else fail(c, "?: needs the same type on both sides") end
        end
        -- Only the chosen side is evaluated.
        return "(" .. condition(c, code, t) .. " and {" .. yes .. "} or {" .. no .. "})[1]", result
    end
    return code, t, lvalue
end

local compound = {["+="] = "+", ["-="] = "-", ["*="] = "*", ["/="] = "/", ["%="] = "%", ["**="] = "**",
    ["&="] = "&", ["|="] = "|", ["^="] = "^", ["<<="] = "<<", [">>="] = ">>", [">>>="] = ">>>"}

-- An expression statement or for-loop step: assignments, ++/--, calls. Returns Lua statement text.
local function statement_expression(c)
    if check(c, "++") or check(c, "--") then
        local op = peek(c).value
        c.at = c.at + 1
        local code, t, lvalue = postfix(c)
        if not lvalue then fail(c, op .. " needs a variable") end
        if t == "Info" or c.api.classes[t] and c.api.classes[t].step then
            return c.api.classes[t].step:gsub("%$", code):gsub("%%d", op == "++" and "1" or "-1")
        end
        if not is_number(t) then fail(c, op .. " needs a number") end
        return store(c, lvalue, code .. (op == "++" and " + 1" or " - 1"))
    end
    local start = c.at
    local code, t, lvalue = ternary(c)
    if check(c, "++") or check(c, "--") then
        local op = peek(c).value
        c.at = c.at + 1
        if c.api.classes[t] and c.api.classes[t].step then
            return (c.api.classes[t].step:gsub("%$", code):gsub("%%d", op == "++" and "1" or "-1"))
        end
        if not lvalue then fail(c, op .. " needs a variable") end
        if not is_number(t) then fail(c, op .. " needs a number") end
        return store(c, lvalue, code .. (op == "++" and " + 1" or " - 1"))
    end
    local token = peek(c)
    if token.kind == "op" and (token.value == "=" or compound[token.value]) then
        c.at = c.at + 1
        local value, vt = assignment(c)
        if c.api.classes[t] and c.api.classes[t].assign then
            -- Info: target = 5 loads object 5; target += 1 the next one.
            local class = c.api.classes[t]
            if token.value == "=" then
                if vt == t then value = template(class.number, value, {}) end
                if not is_number(vt) and vt ~= t then fail(c, "cannot assign " .. vt .. " to " .. t) end
                return "R.discard(" .. template(class.assign, code, {value}) .. ")"
            elseif token.value == "+=" or token.value == "-=" then
                if vt == t then value = template(class.number, value, {}) end
                local sign = token.value == "+=" and " + " or " - "
                return "R.discard(" .. template(class.assign, code, {template(class.number, code, {}) .. sign .. value}) .. ")"
            end
            fail(c, "unsupported operator " .. token.value .. " on " .. t)
        end
        if not lvalue then fail(c, "cannot assign to this") end
        if token.value == "=" then
            return store(c, lvalue, convert(c, value, vt, t))
        end
        local result, rt = binary_numeric(c, compound[token.value], code, t, value, vt)
        return store(c, lvalue, convert(c, result, rt, t))
    end
    if c.at == start then fail(c, "expected a statement") end
    -- Lua runs only calls as statements: wrap anything else.
    if code:match("%)$") and not code:match("^%(") then return code end
    return "R.discard(" .. code .. ")"
end

function assignment(c)
    local start = c.at
    local code, t, lvalue = ternary(c)
    local token = peek(c)
    if token.kind == "op" and (token.value == "=" or compound[token.value]) then
        c.at = start
        fail(c, "assignments inside expressions are not supported")
    end
    return code, t, lvalue
end
expression = function(c)
    local code, t, lvalue = assignment(c)
    while accept(c, ",") do code, t, lvalue = assignment(c) end
    return code, t, lvalue
end

local statement

local function block(c)
    expect(c, "{")
    c.scopes[#c.scopes + 1] = {}
    while not accept(c, "}") do
        if peek(c).kind == "eof" then fail(c, "missing '}'") end
        statement(c)
    end
    c.scopes[#c.scopes] = nil
end
local function body(c)
    -- A statement in its own Lua block and scope.
    emit(c, "do")
    c.indent = c.indent + 1
    c.scopes[#c.scopes + 1] = {}
    if check(c, "{") then block(c) else statement(c) end
    c.scopes[#c.scopes] = nil
    c.indent = c.indent - 1
    emit(c, "end")
end

local function declaration(c, t)
    repeat
        local script_name = name(c)
        local init
        if accept(c, "=") then
            if check(c, "{") then
                -- {a, b, c}: an array's initial values.
                c.at = c.at + 1
                local values = {}
                local element = t:sub(1, 6) == "array:" and t:sub(7) or fail(c, "{...} needs an array")
                if not accept(c, "}") then
                    repeat
                        local code, vt = assignment(c)
                        values[#values + 1] = convert(c, code, vt, element)
                    until not accept(c, ",")
                    expect(c, "}")
                end
                init = "R.array_of({" .. table.concat(values, ", ") .. "}, " .. #values .. ")"
            else
                local code, vt = assignment(c)
                if t == "auto" then t = vt end
                local class = c.api.classes[t]
                if class and class.new then
                    if vt == t then code = template(class.number, code, {}) end
                    init = template(class.new, "", {code})
                else
                    init = convert(c, code, vt, t)
                end
            end
        elseif check(c, "(") then
            local args = arguments(c)
            local class = c.api.classes[t]
            if class and class.new then
                init = template(class.new, "", {args[1] and convert(c, args[1][1], args[1][2], "int") or "-1"})
            elseif t:sub(1, 6) == "array:" then
                local element = t:sub(7)
                local size = args[1] and convert(c, args[1][1], args[1][2], "int") or "0"
                local fill = args[2] and convert(c, args[2][1], args[2][2], element) or default_value(element)
                init = "R.array_new(" .. size .. ", " .. fill .. ")"
            else
                fail(c, "cannot construct " .. t)
            end
        else
            local class = c.api.classes[t]
            init = class and class.new and template(class.new, "", {"-1"}) or default_value(t)
        end
        if t == "auto" then fail(c, "auto needs a value") end
        local lua = declare(c, script_name, t, false)
        emit(c, "local " .. lua .. " = " .. init)
    until not accept(c, ",")
    expect(c, ";")
end

local function loop_body(c, continue_label)
    c.loops[#c.loops + 1] = {kind = "loop", continue_label = continue_label}
    body(c)
    c.loops[#c.loops] = nil
end

function statement(c)
    if accept(c, ";") then return end
    if check(c, "{") then
        emit(c, "do")
        c.indent = c.indent + 1
        block(c)
        c.indent = c.indent - 1
        emit(c, "end")
        return
    end
    if accept(c, "if") then
        -- else-if chains become one if/elseif (Lua limits how deeply blocks nest).
        local keyword = "if "
        while true do
            expect(c, "(")
            local code, t = expression(c)
            expect(c, ")")
            emit(c, keyword .. condition(c, code, t) .. " then")
            c.indent = c.indent + 1
            body(c)
            c.indent = c.indent - 1
            if not accept(c, "else") then break end
            if not accept(c, "if") then
                emit(c, "else")
                c.indent = c.indent + 1
                body(c)
                c.indent = c.indent - 1
                break
            end
            keyword = "elseif "
        end
        emit(c, "end")
        return
    end
    if accept(c, "while") then
        expect(c, "(")
        local code, t = expression(c)
        expect(c, ")")
        local continue_label = label(c, "continue_")
        emit(c, "while " .. condition(c, code, t) .. " do")
        c.indent = c.indent + 1
        loop_body(c, continue_label)
        emit(c, "::" .. continue_label .. "::")
        c.indent = c.indent - 1
        emit(c, "end")
        return
    end
    if accept(c, "do") then
        local continue_label = label(c, "continue_")
        emit(c, "repeat")
        c.indent = c.indent + 1
        loop_body(c, continue_label)
        emit(c, "::" .. continue_label .. "::")
        c.indent = c.indent - 1
        expect(c, "while")
        expect(c, "(")
        local code, t = expression(c)
        expect(c, ")")
        expect(c, ";")
        emit(c, "until not " .. condition(c, code, t))
        return
    end
    if accept(c, "for") then
        expect(c, "(")
        emit(c, "do")
        c.indent = c.indent + 1
        c.scopes[#c.scopes + 1] = {}
        if not accept(c, ";") then
            if type_start(c) and peek(c, 1).kind == "name" or (type_start(c) and check(c, "<", 1)) then
                declaration(c, parse_type(c))
            else
                emit(c, statement_expression(c))
                while accept(c, ",") do emit(c, statement_expression(c)) end
                expect(c, ";")
            end
        end
        local test = "true"
        if not check(c, ";") then
            local code, t = expression(c)
            test = condition(c, code, t)
        end
        expect(c, ";")
        local steps = {}
        if not check(c, ")") then
            repeat steps[#steps + 1] = statement_expression(c) until not accept(c, ",")
        end
        expect(c, ")")
        local continue_label = label(c, "continue_")
        emit(c, "while " .. test .. " do")
        c.indent = c.indent + 1
        loop_body(c, continue_label)
        emit(c, "::" .. continue_label .. "::")
        for _, step in ipairs(steps) do emit(c, step) end
        c.indent = c.indent - 1
        emit(c, "end")
        c.scopes[#c.scopes] = nil
        c.indent = c.indent - 1
        emit(c, "end")
        return
    end
    if accept(c, "switch") then
        expect(c, "(")
        local code, t = expression(c)
        expect(c, ")")
        expect(c, "{")
        local value, entry = label(c, "switch_"), label(c, "case_")
        local done = label(c, "switch_end_")
        emit(c, "do")
        c.indent = c.indent + 1
        emit(c, "local " .. value .. ", " .. entry .. " = " .. code .. ", nil")
        -- Cases are compiled first into a buffer, then the dispatch is written before them.
        local saved = c.lines
        c.lines = {}
        local cases, default_index = {}, nil
        c.loops[#c.loops + 1] = {kind = "switch", break_label = done}
        local open = false
        while not accept(c, "}") do
            if accept(c, "case") then
                local case_code = expression(c)
                expect(c, ":")
                if open then c.indent = c.indent - 1 emit(c, "end") end
                cases[#cases + 1] = case_code
                emit(c, "if " .. entry .. " and " .. entry .. " <= " .. #cases .. " then")
                c.indent = c.indent + 1
                open = true
            elseif accept(c, "default") then
                expect(c, ":")
                if open then c.indent = c.indent - 1 emit(c, "end") end
                cases[#cases + 1] = false
                default_index = #cases
                emit(c, "if " .. entry .. " and " .. entry .. " <= " .. #cases .. " then")
                c.indent = c.indent + 1
                open = true
            else
                if not open then fail(c, "a statement before the first case") end
                statement(c)
            end
        end
        if open then c.indent = c.indent - 1 emit(c, "end") end
        c.loops[#c.loops] = nil
        local case_lines = c.lines
        c.lines = saved
        local tests = {}
        for index, case_code in ipairs(cases) do
            if case_code then tests[#tests + 1] = value .. " == " .. case_code .. " then " .. entry .. " = " .. index end
        end
        if #tests > 0 then emit(c, "if " .. table.concat(tests, " elseif ") .. " end") end
        if default_index then emit(c, "if not " .. entry .. " then " .. entry .. " = " .. default_index .. " end") end
        for _, line in ipairs(case_lines) do c.lines[#c.lines + 1] = line end
        emit(c, "::" .. done .. "::")
        c.indent = c.indent - 1
        emit(c, "end")
        return
    end
    if accept(c, "break") then
        expect(c, ";")
        local inner = c.loops[#c.loops]
        if not inner then fail(c, "break outside a loop or switch") end
        if inner.kind == "switch" then emit(c, "goto " .. inner.break_label) else emit(c, "do break end") end
        return
    end
    if accept(c, "continue") then
        expect(c, ";")
        for index = #c.loops, 1, -1 do
            if c.loops[index].kind == "loop" then emit(c, "goto " .. c.loops[index].continue_label) return end
        end
        fail(c, "continue outside a loop")
    end
    if accept(c, "return") then
        local result = c.current.result
        if accept(c, ";") then
            if result ~= "void" then emit(c, "do return " .. default_value(result) .. " end") else emit(c, "do return end") end
            return
        end
        local code, t = expression(c)
        expect(c, ";")
        if result == "void" then fail(c, "a void function returns no value") end
        emit(c, "do return " .. convert(c, code, t, result) .. " end")
        return
    end
    if type_start(c) and (peek(c, 1).kind == "name" and not keywords[peek(c, 1).value] or check(c, "<", 1)
        or (check(c, "[", 1) and check(c, "]", 2)) or check(c, "@", 1)) then
        declaration(c, parse_type(c))
        return
    end
    emit(c, statement_expression(c))
    expect(c, ";")
end

-- Top level: functions and global variables, in two passes (functions may be called before their
-- definition, and globals are initialized in order after all functions exist).
local function signature(c)
    local result = parse_type(c)
    local script_name = name(c)
    -- "Info t(5);" constructs a global; a function's "(" is followed by ")" or a parameter type.
    if not check(c, "(") or not (check(c, ")", 1) or type_start(c, 1)) then return nil end
    c.at = c.at + 1
    local params = {}
    if check(c, "void") and check(c, ")", 1) then c.at = c.at + 1 end
    if not accept(c, ")") then
        repeat
            local t = parse_type(c)
            local param_name = peek(c).kind == "name" and name(c) or ("_" .. #params)
            local default
            if accept(c, "=") then
                local code, dt = assignment(c)
                default = convert(c, code, dt, t)
            end
            params[#params + 1] = {name = param_name, type = t, default = default}
        until not accept(c, ",")
        expect(c, ")")
    end
    accept(c, "const")
    return {name = script_name, result = result, params = params}
end

local function skip_block(c)
    expect(c, "{")
    local depth = 1
    while depth > 0 do
        local token = peek(c)
        if token.kind == "eof" then fail(c, "missing '}'") end
        if token.kind == "op" and token.value == "{" then depth = depth + 1
        elseif token.kind == "op" and token.value == "}" then depth = depth - 1 end
        c.at = c.at + 1
    end
end

-- Returns the Lua text of a chunk that, run with the runtime R as its environment's R, returns a
-- function making one instance of the script: {ego = function or nil, id = function or nil}.
function angelscript.compile(source, file, api)
    local c = new_compiler(source, file, api)
    -- Pass 1: function signatures.
    local definitions = {}
    while peek(c).kind ~= "eof" do
        if accept(c, ";") then
        else
            if check(c, "shared") or check(c, "funcdef") or check(c, "class") or check(c, "interface")
               or check(c, "enum") or check(c, "namespace") or check(c, "import") or check(c, "mixin") then
                fail(c, "'" .. peek(c).value .. "' is not supported")
            end
            local start = c.at
            local sig = signature(c)
            if sig then
                local list = c.functions[sig.name] or {}
                sig.lua = "f_" .. sig.name .. (#list > 0 and ("_" .. #list) or "")
                list[#list + 1] = sig
                c.functions[sig.name] = list
                sig.body_at = c.at
                definitions[#definitions + 1] = sig
                skip_block(c)
            else
                c.at = start
                -- A global declaration: skip to its ';' (parsed in pass 2).
                definitions[#definitions + 1] = {global_at = start}
                while not check(c, ";") do
                    if peek(c).kind == "eof" then fail(c, "missing ';'") end
                    if check(c, "{") then skip_block(c) else c.at = c.at + 1 end
                end
                c.at = c.at + 1
            end
        end
    end
    -- Pass 2: globals (declared first, initialized after the functions), then function bodies.
    c.scopes = {}
    local globals_text, function_text = {}, {}
    local global_names = {}
    for _, definition in ipairs(definitions) do
        if definition.global_at then
            c.at = definition.global_at
            c.lines, c.indent = {}, 1
            c.scopes = {{}}
            c.current = {result = "void"}
            local t = parse_type(c)
            declaration(c, t)
            for script_name, variable in pairs(c.scopes[1]) do
                variable.lua = "g_" .. script_name
                c.globals[script_name] = variable
                global_names[#global_names + 1] = variable.lua
            end
            for _, text in ipairs(c.lines) do
                -- "local v_x_1 = init" becomes "g_x = init".
                globals_text[#globals_text + 1] = (text:gsub("local v_([%w_]+)_1 = ", "g_%1 = "))
            end
        end
    end
    table.sort(global_names)
    for _, definition in ipairs(definitions) do
        if definition.body_at then
            c.at = definition.body_at
            c.lines, c.indent = {}, 1
            c.scopes = {{}}
            c.loops = {}
            c.current = definition
            local params = {}
            for _, param in ipairs(definition.params) do
                params[#params + 1] = declare(c, param.name, param.type, false)
            end
            block(c)
            if definition.result ~= "void" then emit(c, "do return " .. default_value(definition.result) .. " end") end
            function_text[#function_text + 1] = definition.lua .. " = function(" .. table.concat(params, ", ") .. ")"
            for _, text in ipairs(c.lines) do function_text[#function_text + 1] = text end
            function_text[#function_text + 1] = "end"
        end
    end
    local function_names = {}
    for _, definition in ipairs(definitions) do
        if definition.lua then function_names[#function_names + 1] = definition.lua end
    end
    local out = {"local R = R", "return function()"}
    if #global_names > 0 then out[#out + 1] = "local " .. table.concat(global_names, ", ") end
    if #function_names > 0 then out[#out + 1] = "local " .. table.concat(function_names, ", ") end
    for _, text in ipairs(function_text) do out[#out + 1] = text end
    for _, text in ipairs(globals_text) do out[#out + 1] = text end
    local exports = {}
    for _, entry in ipairs({{"ego", "int"}, {"id", "void"}}) do
        local list = c.functions[entry[1]]
        if list then
            for _, sig in ipairs(list) do
                if #sig.params == 0 and sig.result == entry[2] then exports[#exports + 1] = entry[1] .. " = " .. sig.lua end
            end
        end
    end
    out[#out + 1] = "return {" .. table.concat(exports, ", ") .. "}"
    out[#out + 1] = "end"
    return table.concat(out, "\n")
end

-- A compile error's message, or nil for other errors.
function angelscript.error_message(problem)
    if type(problem) == "table" and problem.angelscript then return problem.message end
    return nil
end
return angelscript
