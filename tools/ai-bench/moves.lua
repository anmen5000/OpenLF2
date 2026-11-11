-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors
-- Prints what base/game/smart_ai learned about some fighters.
local catalog = require("base/game/catalog")
local object_data = require("base/game/object_data")
local item = require("base/game/item")
local smart = require("base/game/smart_ai")
local moves = {}
function moves.run(config)
    for _, fighter in ipairs(catalog.load()) do
        if config.only[fighter.id] then
            local record = item.record({id = fighter.id, kind = 0}, object_data.load(fighter.path))
            local analysis = smart.analyze(record)
            engine.log(string.format("== %d %s: %d moves from %d entries%s", fighter.id, fighter.name, #analysis.moves, analysis.entries or -1, (analysis.entries or 0) >= 40 and " (CAP)" or ""))
            local function show(list, indent)
                for _, move in ipairs(list) do
                    local e = move.entry
                    local how = e.sequence and (e.field .. "#" .. e.sequence) or (e.basic or ("chain " .. tostring(e.key) .. " from " .. tostring(e.from)))
                    if e.chain and not e.parent then how = how .. "+" .. #e.chain end
                    engine.log(string.format("%s%-5s %-22s frame %s: first %s last %s ready %d len %d mp %d hp %d dmg %d fall %d bd %d reach x %d..%d z %d boxes %d%s%s%s%s",
                        indent, e.context, how, tostring(e.frame or e.press), tostring(move.first), tostring(move.last), move.ready, move.length, move.mp, move.hp,
                        move.damage, move.fall, move.bdefend, move.reach_x1, move.reach_x2, move.reach_z, #move.boxes,
                        move.teleport and (" teleport@" .. move.teleport) or "", move.transform and " transform" or "", (move.charge and (" charge " .. move.charge) or "") .. (move.hit_damage and (" hit " .. move.hit_damage) or ""),
                        (move.mode and string.format(" MODE item %d code %d rest %d", move.mode.record.id, move.mode.code, move.mode.frame) or "")
                        .. (move.share and string.format(" share %.2f", move.share) or "") .. (move.teleport_reach and (" reach " .. move.teleport_reach) or "")
                        .. (move.lasting and " lasting" or "") .. (move.branch_frames and " branch" or "") .. (move.shield and " shield" or "")))
                    if config.boxes and move.mode then
                        for _, box in ipairs(move.boxes) do
                            engine.log(string.format("%s    box t%d own=%s kind %d inj %d fall %d x %d..%d y %d..%d z %d frame %s", indent, box.t, tostring(box.own) .. "(" .. tostring(box.source) .. ")", box.kind, box.injury, box.fall, box.x1, box.x2, box.y1, box.y2, box.z, tostring(move.frames[box.t])))
                        end
                    end
                end
            end
            show(analysis.moves, "  ")
            -- (The change back of a fighter that has changed — a move apart, version 44.)
            if analysis.back_move then show({analysis.back_move}, "  back: ") end
            -- Its modes (an item of its own making in hand): what it does in each.
            for _, mode in pairs(analysis.modes or {}) do
                local armed = smart.internals.armed_analysis(record, mode.record, #analysis.moves + 1)
                local function keys_of(set) local list = {} for k in pairs(set or {}) do list[#list + 1] = k end table.sort(list) return table.concat(list, ",") end
                engine.log(string.format("  -- mode: item %d held with code %d, resting frame %d: %d moves, best damage %d (drain %s, run %s, worth %.2f) idle {%s} moving {%s} runs_on %s stop %s ready %d",
                    mode.record.id, mode.code, mode.frame, #armed.moves, mode.best_damage or -1, tostring(mode.drain), tostring(mode.run_speed), mode.worth or -1,
                    keys_of(mode.idle), keys_of(mode.moving), tostring(mode.runs_on), tostring(mode.stop_key), mode.start and mode.start.ready or -1))
                show(armed.moves, "     ")
            end
        end
    end
    -- The shields learned on the way (version 44: what a move leaves standing that breaks the plain balls thrown at
    -- its fighter), each with the frames it is up in.
    local shields = {}
    for _, known in pairs(smart.shield_kit.records) do shields[#shields + 1] = known end
    table.sort(shields, function(a, b) return a.id < b.id end)
    for _, known in ipairs(shields) do
        local ids = {}
        for frame_id in pairs(known.frames) do ids[#ids + 1] = frame_id end
        table.sort(ids)
        local parts, i = {}, 1
        while i <= #ids do
            local j = i
            while j < #ids and ids[j + 1] == ids[j] + 1 do j = j + 1 end
            parts[#parts + 1] = i == j and tostring(ids[i]) or (ids[i] .. "-" .. ids[j])
            i = j + 1
        end
        engine.log(string.format("== shield: record %d, up in frames %s", known.id, table.concat(parts, " ")))
    end
end
return moves
