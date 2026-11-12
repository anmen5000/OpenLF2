-- record: XOI's attack decisions written down with what came of them, for a learned score (the "deep" step).
-- Each time a smart player (brains[1]) starts a move (smart.on_start), one line "REC ..." with the situation as
-- numbers, the move's numbers, the player's own score and hit time for it, and — `window` frames later — the HP the
-- target lost and the HP the player lost meanwhile. Random pairs of the pool (as spsa) on random stages.
--   brains = {"xoi", "classic"} (brains[1] is recorded; "both" records brains[2] too when it is a smart one)
--   games (default 20), seed, limit (frames a game, 9000), window (45), ids (fighter ids; all seated otherwise)
--   opponent "xoi": XOI itself (config.alt's copy, without the brain) even in a pack with AI scripts of its own — those
--   of most mods are far weaker than Sauce's, and a brain learned against them learns to beat a weak player
--   (hoc-sau.bat's DOI_THU=xoi, brain.bat's OPPONENT=xoi)
--   explore (beta; nil or 0: off): the recorded player tries other moves now and then (below)
local catalog = require("base/game/catalog")
local match = require("base/game/match")
local constants = require("base/game/constants")
local ai_scripts = require("base/game/ai_scripts")
local brains = require("bench/brains")
local job = {}

local function clock_seconds() local clock = engine.network_time; return clock and clock() / 1000 or nil end

local function generator(seed)
    local s = seed % 2147483647
    if s <= 0 then s = s + 2147483646 end
    return function(n)
        s = (s * 48271) % 2147483647
        return (s % n) + 1
    end
end

local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end

function job.run(config)
    local smart = require("base/game/smart_ai")
    local fighters, backgrounds = catalog.load(), catalog.backgrounds()
    local pool = {}
    local by_id = {}
    for index, fighter in ipairs(fighters) do by_id[fighter.id] = by_id[fighter.id] or index end
    if config.ids then
        for _, id in ipairs(config.ids) do if by_id[id] then pool[#pool + 1] = by_id[id] end end
    else
        for index, fighter in ipairs(fighters) do if not fighter.hidden then pool[#pool + 1] = index end end
    end
    -- (Seated once each, as spsa: the Template's seat stays empty. And whether the pack has AI scripts of its own:
    -- the opponent is then the original player with them, Sauce's AI; else XOI itself, without the brain.)
    local seated, scripted = {}, false
    for _, index in ipairs(pool) do
        local ok = pcall(function()
            local state = match.create({mode = constants.modes.versus, difficulty = -2, background = 0, fighters = fighters, backgrounds = backgrounds,
                slots = {[0] = {kind = "computer", fighter = index, team = 1}, [1] = {kind = "computer", fighter = index, team = 2}}})
            assert(state.items[10] and state.items[11])
            if ai_scripts.has(state, 10) then scripted = true end
        end)
        if ok then seated[#seated + 1] = index end
    end
    pool = seated
    -- The opponent: the original player with the pack's own AI scripts where it has them (Sauce's AI); else XOI
    -- itself — a copy of the player (config.alt, a bench module copy of smart_ai.lua: hoc-sau.bat makes one) so
    -- that a brain given to the recorded side is not the opponent's too.
    local own_scripts = scripted and config.opponent ~= "xoi"
    local names = config.brains or {"xoi", own_scripts and "classic" or (config.alt and ("xoi@" .. config.alt) or "xoi")}
    if not config.brains then
        engine.log("record: opponent " .. names[2] .. (own_scripts and " (the pack's own AI scripts)"
            or scripted and " (XOI itself: opponent = xoi, the pack's own AI scripts left out)" or " (no AI scripts of the pack's own)"))
    end
    -- A side named "xoi@<module>" is played by that copy, with a context of its own (brains.load sets the match's
    -- routing up, as duel's does). Up to package 78 nothing did so here, and the match handed every "xoi..."
    -- fighter to the player itself, the brain given to side 1 with it: in a pack without AI scripts of its own,
    -- or with DOI_THU=xoi, the check of XOI with the brain against XOI without it set the brain against itself
    -- (and no brain against no brain) — about even whatever the brain was worth — and the rounds from the second
    -- recorded the brain against itself.
    for _, name in ipairs(names) do brains.load(name) end
    -- config.brain = {module = ..., on = {1}}: the recorded player plays with a brain (as duel's option), the
    -- records then of the play it leads to — the next brain is trained on them.
    local on_list = config.brain and (config.brain.on or {1}) or {}
    -- A side's smart player: the module named after "@" (a copy of smart_ai.lua), else the player itself; nil for
    -- a side that is no smart player (classic: the pack's own scripts, or the original computer player).
    local function player_of(side)
        local name = names[side] or ""
        local module = name:match("^[a-z:]+@(.+)$")
        if module then
            local ok, found = pcall(require, "bench/" .. module)
            return ok and type(found) == "table" and found.set_brain and found or nil
        end
        return (name:match("^xoi") or name:match("^smart")) and smart or nil
    end
    local given = {}
    if config.brain then
        local text = require("bench/" .. config.brain.module).text
        for _, side in ipairs(on_list) do
            local player = assert(player_of(side), "no smart player on side " .. side .. " to give the brain to")
            local brain = player.brain_kit.parse(text)
            assert(brain, "the brain's text does not fit")
            player.set_brain(brain)
            given[player] = true
            engine.log(string.format("brain %s on side %d", config.brain.module, side))
        end
    end
    -- Every other side plays without one — a brain the pack itself carries (xoi/brain.txt, read in every match
    -- unless set_brain fixed it) too, so that a check of XOI with the brain against XOI without compares what it
    -- says, and a round recorded without a brain is so. (A player shared by an `on` side keeps its brain.)
    for side = 1, 2 do
        local on = false
        for _, k in ipairs(on_list) do if k == side then on = true end end
        local player = not on and player_of(side)
        if player and not given[player] then player.set_brain(nil) end
    end
    local quiet = config.quiet -- (a check only: games and their winners, no records)
    local random = generator(config.seed or 1)
    local window = config.window or 45
    local limit = config.limit or 9000
    local both = config.both
    local state_now
    local pending = {}
    local last_blow = -999
    local count = 0
    local width = 0
    assert(smart.brain_kit, "scripts/base/game/smart_ai.lua has no brain kit (older than the recorder)")
    -- config.explore = beta (hoc-sau.bat's THU_DON, brain.bat's EXPLORE; 0 or nil: off): the recorded player tries
    -- other moves now and then. Each move it finds worth starting gets a shift of its score drawn for the frame and
    -- the move (Gumbel noise of scale beta, less its mean), so that moves that score close to the best one are
    -- sometimes started instead and ones far below it almost never: the records then tell what moves the player
    -- would not have chosen bring too, not only those it picks every time (smart.explore, read in best_attack).
    -- The opponent never explores, nor does any player in a check (quiet). Mode Convergence, XOI against itself,
    -- one round of 25 minutes on 2 threads: the brain learned with beta 4 won 6.5 games in 100 more than XOI
    -- without a brain, the brain learned without exploring 2.9 (the same 2,000 games).
    local explore = not quiet and config.explore and config.explore > 0 and config.explore or nil
    if explore then
        local salt = (config.seed or 1) % 100000
        smart.explore = function(self, move)
            local state = state_now
            if not state or self ~= state.items[10] then return nil end
            local h = (state.frame_number * 7919 + (move.index or 0) * 104729 + salt * 15485863) % 2147483647
            if h <= 0 then h = h + 2147483646 end
            for _ = 1, 3 do h = (h * 48271) % 2147483647 end
            local u = (h + 0.5) / 2147483647
            return explore * (-math.log(-math.log(u)) - 0.5772)
        end
        engine.log("record: the recorded player explores, beta " .. explore)
    end
    local header = {"dx", "dz", "my", "ty", "tfaces", "hp", "thp", "mp", "tmp", "vx", "tvx", "tvz", "tvy", "wpn", "twpn"}
    for i = 0, 9 do header[#header + 1] = "me" .. i end
    for i = 0, 9 do header[#header + 1] = "tg" .. i end
    for _, name in ipairs({"twait", "tleft", "tblink", "calm", "x", "tx", "t", "score", "m_first", "m_dmg", "m_mp", "m_reach", "m_ready", "m_catch", "m_proj", "m_own", "m_bdef", "m_fall", "m_air", "m_zw", "m_punch", "m_airmv", "m_seq"}) do header[#header + 1] = name end
    engine.log("RECH slot dealt taken " .. table.concat(header, " "))
    local function on_start(self, move, t, score, hand)
        local state = state_now
        if not state then return end
        t, score = t or 0, score or 0
        if not both and self ~= state.items[10] then return end
        local memory = self.smart_memory
        local target = memory and memory.target and state.items[memory.target]
        if not target then target = state.items[self == state.items[10] and 11 or 10] end
        if not target or target.hp == nil then return end
        local kit = smart.brain_kit
        local feats, n = kit.features(self, target, move, t, hand or score, memory and memory.calm or 0)
        pending[#pending + 1] = {me = self, target = target, at = state.frame_number, hp = self.hp, thp = target.hp, feats = feats, n = n,
            slot = self == state.items[10] and 1 or 0}
    end
    local modules = {smart}
    for _, name in ipairs(names) do
        local module = name:match("^[a-z:]+@(.+)$")
        if module then pcall(function() modules[#modules + 1] = require("bench/" .. module) end) end
    end
    for _, module in ipairs(modules) do module.on_start = on_start end
    local games = config.games or 20
    local seconds = config.seconds
    local began = seconds and clock_seconds()
    local wins, losses, played = 0, 0, 0
    for game = 1, games do
        if began and clock_seconds() - began >= seconds then break end
        played = played + 1
        local a, b = pool[random(#pool)], pool[random(#pool)]
        local row = random(#backgrounds) - 1
        local ok, problem = pcall(function()
            local state = match.create({mode = constants.modes.versus, difficulty = config.difficulty or -3, background = row,
                fighters = fighters, backgrounds = backgrounds,
                slots = {[0] = {kind = "computer", fighter = a, team = 1}, [1] = {kind = "computer", fighter = b, team = 2}}})
            state.items[10].brain = names[1]
            state.items[11].brain = names[2]
            state_now = state
            pending = {}
            last_blow = -999
            local held = {functions = "", function_presses = "", keys = {}}
            local ticks = 0
            local hp = {state.items[10].hp, state.items[11].hp}
            while ticks < limit do
                match.step(state, held)
                ticks = ticks + 1
                local one, two = state.items[10], state.items[11]
                if not one or not two then break end
                if one.hp < hp[1] or two.hp < hp[2] then last_blow = state.frame_number end
                hp[1], hp[2] = one.hp, two.hp
                -- Records whose window has passed.
                local keep = {}
                for _, rec in ipairs(pending) do
                    if state.frame_number - rec.at >= window or one.hp <= 0 or two.hp <= 0 then
                        local me, target = rec.me, rec.target
                        local dealt = clamp(rec.thp - (target.hp or 0), 0, 500)
                        local taken = clamp(rec.hp - (me.hp or 0), 0, 500)
                        count = count + 1
                        if not quiet then
                            local parts = {}
                            for i = 1, rec.n do parts[i] = string.format("%.3g", rec.feats[i]) end
                            engine.log(string.format("REC %d %d %d %s", rec.slot, dealt, taken, table.concat(parts, " ")))
                        end
                    else
                        keep[#keep + 1] = rec
                    end
                end
                pending = keep
                if one.hp <= 0 or two.hp <= 0 or state.round_counter > 0 then break end
            end
            local one, two = state.items[10], state.items[11]
            if one and two then
                if one.hp > 0 and two.hp <= 0 then wins = wins + 1 elseif two.hp > 0 and one.hp <= 0 then losses = losses + 1 end
            end
        end)
        if not ok then engine.log("record: game failed: " .. tostring(problem)) end
    end
    for _, module in ipairs(modules) do module.on_start = nil end
    smart.explore = nil
    engine.log(string.format("RECORD %d games, %d records, %s won %d lost %d vs %s", played, count, names[1], wins, losses, names[2]))
end
return job
