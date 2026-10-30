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
            for _, move in ipairs(analysis.moves) do
                local e = move.entry
                local how = e.sequence and (e.field .. "#" .. e.sequence) or (e.basic or ("chain " .. tostring(e.key) .. " from " .. tostring(e.from)))
                engine.log(string.format("  %-5s %-22s frame %d: first %s last %s ready %d len %d mp %d hp %d dmg %d fall %d bd %d reach x %d..%d z %d boxes %d%s%s%s",
                    e.context, how, e.frame, tostring(move.first), tostring(move.last), move.ready, move.length, move.mp, move.hp,
                    move.damage, move.fall, move.bdefend, move.reach_x1, move.reach_x2, move.reach_z, #move.boxes,
                    move.teleport and (" teleport@" .. move.teleport) or "", move.transform and " transform" or "", (move.charge and (" charge " .. move.charge) or "") .. (move.hit_damage and (" hit " .. move.hit_damage) or "")))
            end
        end
    end
end
return moves
