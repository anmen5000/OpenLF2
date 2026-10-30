local catalog = require("base/game/catalog")
local object_data = require("base/game/object_data")
local dump = {}
local fields = {"Fa", "Ua", "Da", "Fj", "Uj", "Dj", "ja"}
local function chain(data, start, limit)
    local out, seen, f, t = {}, {}, start, 0
    for _ = 1, limit do
        local frame = data.frames[f]
        if not frame or seen[f] then break end
        seen[f] = true
        local note = tostring(f) .. "(w" .. frame.wait .. ",s" .. frame.state
        if frame.mp ~= 0 then note = note .. ",mp" .. frame.mp end
        if frame.dvx ~= 0 then note = note .. ",dvx" .. frame.dvx end
        if frame.dvy ~= 0 then note = note .. ",dvy" .. frame.dvy end
        for _, itr in ipairs(frame.interactions) do
            note = note .. string.format(",itr[k%d x%d w%d y%d h%d inj%d f%d bd%d dvx%d z%d e%d]", itr.kind, itr.x, itr.width, itr.y, itr.height, itr.injury, itr.fall, itr.bdefend, itr.dvx, itr.zwidth, itr.effect)
        end
        if frame.opoint.kind > 0 then note = note .. string.format(",op[o%d a%d x%d y%d dvx%d f%d]", frame.opoint.oid, frame.opoint.action, frame.opoint.x, frame.opoint.y, frame.opoint.dvx, frame.opoint.facing) end
        for _, hit in ipairs({"a", "j", "d"}) do if frame.hits[hit] ~= 0 then note = note .. ",h" .. hit .. frame.hits[hit] end end
        note = note .. ")"
        out[#out + 1] = note
        t = t + frame.wait + 1
        f = frame.next
        if f == 999 or f == 0 then out[#out + 1] = "->" .. f; break end
        if f < 0 then f = -f end
    end
    return table.concat(out, " "), t
end
function dump.run(config)
    local fighters = catalog.load()
    for _, fighter in ipairs(fighters) do
        if not config.only or config.only[fighter.id] then
            local data = object_data.load(fighter.path)
            engine.log(string.format("== %d %s (%s) hidden=%s", fighter.id, fighter.name, fighter.path, tostring(fighter.hidden)))
            local m = data.movement or {}
            engine.log(string.format("  move walk %s/%s run %s/%s jump h%s d%s dash h%s d%s", tostring(m.walking_speed), tostring(m.walking_speedz), tostring(m.running_speed), tostring(m.running_speedz), tostring(m.jump_height), tostring(m.jump_distance), tostring(m.dash_height), tostring(m.dash_distance)))
            local starts = {}
            for _, f in ipairs({0, 5, 9, 110, 210, 212, 213}) do
                local frame = data.frames[f]
                if frame then
                    local parts = {}
                    for _, field in ipairs(fields) do
                        if frame.hits[field] ~= 0 then parts[#parts + 1] = field .. "=" .. frame.hits[field] end
                    end
                    engine.log(string.format("  from %d: %s", f, table.concat(parts, " ")))
                    for _, field in ipairs(fields) do
                        local target = frame.hits[field]
                        if target ~= 0 and not starts[target] then
                            starts[target] = true
                            local text, ticks = chain(data, target, 40)
                            engine.log(string.format("    %s -> %d [%d ticks]: %s", field, target, ticks, text))
                        end
                    end
                end
            end
            for _, f in ipairs({60, 65, 70, 80, 85, 90}) do
                if data.frames[f] then
                    local text, ticks = chain(data, f, 20)
                    engine.log(string.format("  basic %d [%d]: %s", f, ticks, text))
                end
            end
            local d = data.frames[110]
            if d then engine.log(string.format("  defend110 wait %d next %d; 111 wait %d", d.wait, d.next, data.frames[111] and data.frames[111].wait or -1)) end
            local frame0 = data.frames[0]
            if frame0 then
                for _, body in ipairs(frame0.bodies) do engine.log(string.format("  bdy0 x%d y%d w%d h%d c%d,%d", body.x, body.y, body.width, body.height, frame0.center_x, frame0.center_y)) end
            end
        end
    end
end
return dump
