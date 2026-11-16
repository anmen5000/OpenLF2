-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors
-- Reinforcement learning, a trial (package 85; windows/hoc-tang-cuong.bat): XOI with a learned hand on its keys, for
-- one fighter. Every frame XOI decides as always; then a small network (two layers of 64) sees the situation
-- (brain_kit.features' 41 numbers and a few more: the keys of the frame before, the ways on by A, J, D in the
-- fighter's frame, the blow in the target's, the two nearest flying things of the enemy, the fighter's meters), the
-- keys XOI chose this frame (one of 36, facing-relative), and either lets XOI's keys through or plays one of 22 moves
-- of its own over the next frames, XOI's keys set aside meanwhile: a press of A, J or D; a jump (on the spot,
-- forward, back, up, down); a walk of 4 frames (forward, back, up, down); a run of 10 (forward, back); the seven
-- D-moves (D>A, D>J, D^A, D^J, DvA, DvJ, DJA, the direction locked to the facing at its start); a wait of 4 frames
-- with no key. The network is asked only where a key can change anything (free states, a frame with ways on by keys,
-- the frames of a fall where J flips); at first it lets XOI's keys through 99 times in 100.
-- The fighter plays XOI without a brain (xoi@hs_alt) on every fighter of the mod, random stages. Learning: PPO.
-- Rewards: HP dealt minus HP taken, in hundreds, frame by frame; a won game 2 more, a lost one 2 less. Each process
-- plays its games with the round's network, works its own epochs from it (Adam) and prints the change (RLD lines);
-- step "avg" lays the mean of the processes' changes onto the network (RLW lines: the next round's); step "eval"
-- plays each game twice from the same start, the network's way and XOI's alone (RLE: sums for step "sum", RLC).
-- Every step ends with RL_DONE.
--
-- config (command = "rl"):
--   step      "play" (default), "avg", "eval", "sum", "who" (the fighter `fighter` names: RLF <id> <name>)
--   weights   bench module with the round's network (its text: RLW lines); none: a new one (init_seed, 1)
--   parts     (avg) the processes' RLD (and RLS, RLM) lines in that many files mods/bench/rl_part_<k>.txt, assets of
--             this package (one a process); deltas: instead, a bench module with them all (a few processes only: a
--             module may not exceed 1 MiB); evals: (sum) bench module with the processes' RLE lines
--   fighter   the learned side: an id or a name (bench/names; default 2); ids: the opponents' ids (all fighters a
--             player can choose when absent, the Template aside)
--   games, seed, offset, limit (frames a game, 9000); brain (bench module: the learned side's XOI brain)
--   epochs (3), batch (256), rate (3e-4), clip (0.2), gamma (0.997), lambda (0.95), entropy (0), vcoef (0.5),
--   win (2: a won game's reward), greedy (eval: the likeliest action instead of one drawn), bonus_move/bonus (a test
--   of the learning: a reward for choosing that move)
local catalog = require("base/game/catalog")
local match = require("base/game/match")
local constants = require("base/game/constants")
local brains = require("bench/brains")
local item = require("base/game/item")
local job = {}

local facing_right = constants.facings.right
local KEYS = item.keys -- up, down, left, right, attack, jump, defend
local NOBS = 41 + 7 + 36 + 3 + 3 + 12 + 3
-- The moves: each a list of frames, each frame the keys held (f forward, b back, u up, d down, A, J, D) and those
-- pressed fresh (capitals after "!").
local MOVES = {
    {"!A"}, {"!J"}, {"!D"},
    {"!J"}, {"f!J", "f", "f"}, {"b!J", "b", "b"}, {"u!J", "u", "u"}, {"d!J", "d", "d"},
    {"!f", "f", "f", "f"}, {"!b", "b", "b", "b"}, {"!u", "u", "u", "u"}, {"!d", "d", "d", "d"},
    {"!f", "", "!f", "f", "f", "f", "f", "f", "f", "f"}, {"!b", "", "!b", "b", "b", "b", "b", "b", "b", "b"},
    {"!D", "!f", "!A"}, {"!D", "!f", "!J"}, {"!D", "!u", "!A"}, {"!D", "!u", "!J"}, {"!D", "!d", "!A"}, {"!D", "!d", "!J"},
    {"!D", "!J", "!A"},
    {"", "", "", ""},
}
local MOVE_NAMES = {"A", "J", "D", "jump", "jump-f", "jump-b", "jump-u", "jump-d", "walk-f", "walk-b", "walk-u", "walk-d",
    "run-f", "run-b", "D>A", "D>J", "D^A", "D^J", "DvA", "DvJ", "DJA", "wait"}
local NH, NA = 64, 1 + #MOVES
local tanh, exp, log, sqrt, floor, min, max = math.tanh, math.exp, math.log, math.sqrt, math.floor, math.min, math.max

-- The parameters in one array: W1 (NH x NOBS), b1, W2 (NH x NH), b2, Wp (NA x NH), bp, Wv (NH), bv.
local oW1 = 0
local oB1 = oW1 + NH * NOBS
local oW2 = oB1 + NH
local oB2 = oW2 + NH * NH
local oWP = oB2 + NH
local oBP = oWP + NA * NH
local oWV = oBP + NA
local oBV = oWV + NH
local NP = oBV + 1

local function lcg(seed)
    local s = seed % 2147483647
    if s <= 0 then s = s + 2147483646 end
    return function()
        s = (s * 48271) % 2147483647
        return (s - 0.5) / 2147483646
    end
end

local function new_params(seed)
    local rnd = lcg(seed)
    local function gauss() return sqrt(-2 * log(rnd())) * math.cos(2 * math.pi * rnd()) end
    local p = {}
    for i = 1, NP do p[i] = 0 end
    for i = 1, NH * NOBS do p[oW1 + i] = gauss() / sqrt(NOBS) end
    for i = 1, NH * NH do p[oW2 + i] = gauss() / sqrt(NH) end
    for i = 1, NA * NH do p[oWP + i] = gauss() * 0.01 / sqrt(NH) end
    for i = 1, NH do p[oWV + i] = gauss() * 0.1 / sqrt(NH) end
    -- Letting XOI's keys through: about 99 frames in 100 at first.
    p[oBP + 1] = 7.7
    return p
end

local function params_text(p, head)
    local lines = {string.format("%s_HEAD %d %d %d %d", head, NOBS, NH, NA, NP)}
    local chunk = 400
    for start = 1, NP, chunk do
        local parts = {}
        for i = start, min(NP, start + chunk - 1) do parts[#parts + 1] = string.format("%.6g", p[i]) end
        lines[#lines + 1] = string.format("%s %d %s", head, start, table.concat(parts, " "))
    end
    return lines
end

local function parse_params(text, head)
    local p = {}
    local count = 0
    for line in text:gmatch("[^\n]+") do
        local start, rest = line:match("^" .. head .. " (%d+) (.*)$")
        if start then
            local i = tonumber(start)
            for token in rest:gmatch("%S+") do p[i] = tonumber(token); i = i + 1; count = count + 1 end
        end
    end
    assert(count == NP, string.format("%s: %d numbers, %d expected", head, count, NP))
    return p
end

-- The network: h1 = tanh(W1 x + b1), h2 = tanh(W2 h1 + b2), logits = Wp h2 + bp, value = Wv . h2 + bv.
local function forward(p, x, h1, h2, z)
    for j = 1, NH do
        local s = p[oB1 + j]
        local base = oW1 + (j - 1) * NOBS
        for i = 1, NOBS do
            local xi = x[i]
            if xi ~= 0 then s = s + p[base + i] * xi end
        end
        h1[j] = tanh(s)
    end
    for j = 1, NH do
        local s = p[oB2 + j]
        local base = oW2 + (j - 1) * NH
        for i = 1, NH do s = s + p[base + i] * h1[i] end
        h2[j] = tanh(s)
    end
    for k = 1, NA do
        local s = p[oBP + k]
        local base = oWP + (k - 1) * NH
        for i = 1, NH do s = s + p[base + i] * h2[i] end
        z[k] = s
    end
    local v = p[oBV + 1]
    for i = 1, NH do v = v + p[oWV + i] * h2[i] end
    return v
end

local function softmax(z, out)
    local m = -math.huge
    for k = 1, NA do if z[k] > m then m = z[k] end end
    local s = 0
    for k = 1, NA do local e = exp(z[k] - m); out[k] = e; s = s + e end
    for k = 1, NA do out[k] = out[k] / s end
end

-- The keys as a facing-relative kind: direction 0..8 (none, forward, back, up, down, up-forward, up-back,
-- down-forward, down-back) times button 0..3 (none, A, J, D): 1..36.
local function kind_of(keys, previous, facing)
    local fwd, back
    if facing == facing_right then fwd, back = keys.right and not keys.left, keys.left and not keys.right
    else fwd, back = keys.left and not keys.right, keys.right and not keys.left end
    local up, down = keys.up and not keys.down, keys.down and not keys.up
    local d = 0
    if up then d = fwd and 5 or back and 6 or 3
    elseif down then d = fwd and 7 or back and 8 or 4
    else d = fwd and 1 or back and 2 or 0 end
    -- The button: a fresh press first (A, J, D), then one held.
    local b = 0
    if keys.attack and not previous.attack then b = 1
    elseif keys.jump and not previous.jump then b = 2
    elseif keys.defend and not previous.defend then b = 3
    elseif keys.attack then b = 1 elseif keys.jump then b = 2 elseif keys.defend then b = 3 end
    return d * 4 + b + 1
end

local dir_fwd = {[1] = true, [5] = true, [7] = true}
local dir_back = {[2] = true, [6] = true, [8] = true}
local dir_up = {[3] = true, [5] = true, [6] = true}
local dir_down = {[4] = true, [7] = true, [8] = true}
local button_key = {"attack", "jump", "defend"}

local function apply_kind(value, kind, last)
    local d, b = floor((kind - 1) / 4), (kind - 1) % 4
    local right = value.facing == facing_right
    local want = {up = dir_up[d] or false, down = dir_down[d] or false, left = false, right = false,
        attack = false, jump = false, defend = false}
    if dir_fwd[d] then want[right and "right" or "left"] = true end
    if dir_back[d] then want[right and "left" or "right"] = true end
    if b > 0 then want[button_key[b]] = true end
    for _, key in ipairs(KEYS) do
        value.previous_keys[key] = last[key] or false
        value.keys[key] = want[key]
    end
    if b > 0 then value.previous_keys[button_key[b]] = false end
end

local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end

-- Whether a key can change anything in the fighter's frame: free (standing, walking, running, jumping, dashing,
-- defending, holding a caught one), a frame with ways on by keys (combos, D-moves), the frames of a fall where J flips.
-- Elsewhere XOI's keys go through and the network is not asked.
local act_states = {[0] = true, [1] = true, [2] = true, [4] = true, [5] = true, [7] = true, [9] = true}
local function can_act(self)
    local frame = self.record.frame(self.frame)
    if act_states[frame.state] then return true end
    local h = frame.hits
    if h.a ~= 0 or h.j ~= 0 or h.d ~= 0 or h.Fa ~= 0 or h.Ua ~= 0 or h.Da ~= 0 or h.Fj ~= 0 or h.Uj ~= 0 or h.Dj ~= 0 or h.ja ~= 0 then
        return true
    end
    return self.frame == 182 or self.frame == 188
end

-- A move's frame onto the keys: `right` the facing locked at the move's start.
local letter_key = {u = "up", d = "down", A = "attack", J = "jump", D = "defend"}
local function apply_frame(value, spec, right, last)
    local held, fresh = spec:match("^([^!]*)!?(.*)$")
    local want = {up = false, down = false, left = false, right = false, attack = false, jump = false, defend = false}
    local new = {}
    local function key_of(ch)
        if ch == "f" then return right and "right" or "left" end
        if ch == "b" then return right and "left" or "right" end
        return letter_key[ch]
    end
    for ch in held:gmatch(".") do local k = key_of(ch); if k then want[k] = true end end
    for ch in fresh:gmatch(".") do local k = key_of(ch); if k then want[k] = true; new[k] = true end end
    for _, key in ipairs(KEYS) do
        value.previous_keys[key] = (not new[key]) and (last[key] or false) or false
        value.keys[key] = want[key]
    end
end

-- The situation as the network sees it.
local dummy_move = {boxes = {}, entry = {}}
local function observe(smart, state, self, target, xoi_kind, last, out)
    local memory = self.smart_memory or {}
    local f = smart.brain_kit.features(self, target, dummy_move, 0, 0, memory.calm, nil)
    for i = 1, 41 do out[i] = f[i] end
    local at = 41
    -- The keys of the frame before, facing-relative: forward, back, up, down, A, J, D.
    local right = self.facing == facing_right
    out[at + 1] = (right and last.right or (not right) and last.left) and 1 or 0
    out[at + 2] = (right and last.left or (not right) and last.right) and 1 or 0
    out[at + 3] = last.up and 1 or 0
    out[at + 4] = last.down and 1 or 0
    out[at + 5] = last.attack and 1 or 0
    out[at + 6] = last.jump and 1 or 0
    out[at + 7] = last.defend and 1 or 0
    at = at + 7
    for k = 1, 36 do out[at + k] = 0 end
    out[at + xoi_kind] = 1
    at = at + 36
    -- The frame's ways on by A, J, D (combos, follow-ups).
    local frame = self.record.frame(self.frame)
    out[at + 1] = frame.hits.a ~= 0 and 1 or 0
    out[at + 2] = frame.hits.j ~= 0 and 1 or 0
    out[at + 3] = frame.hits.d ~= 0 and 1 or 0
    at = at + 3
    -- The target's frame: a blow in it now, how hard, how much it knocks down.
    local tframe = target.record.frame(target.frame)
    local injury, fall, blows = 0, 0, 0
    for _, box in ipairs(tframe.interactions or {}) do
        blows = 1
        if (box.injury or 0) > injury then injury = box.injury end
        if (box.fall or 0) > fall then fall = box.fall end
    end
    out[at + 1] = blows
    out[at + 2] = clamp(injury / 100, 0, 3)
    out[at + 3] = clamp(fall / 100, 0, 2)
    at = at + 3
    -- The two nearest things of the enemy's flying (not characters): where, how fast.
    local face = right and 1 or -1
    local best1, best2, d1, d2 = nil, nil, math.huge, math.huge
    for index = 12, 399 do
        local value = state.items[index]
        if value and value.record.kind ~= constants.record_kinds.character and value.team ~= self.team and value.team ~= 0 then
            local fr = value.record.frame(value.frame)
            if fr.interactions and #fr.interactions > 0 then
                local dd = math.abs(value.x_int - self.x_int) + math.abs(value.z_int - self.z_int) * 2
                if dd < d1 then best2, d2, best1, d1 = best1, d1, value, dd
                elseif dd < d2 then best2, d2 = value, dd end
            end
        end
    end
    for slot, value in ipairs({best1 or false, best2 or false}) do
        local base = at + (slot - 1) * 6
        if value then
            out[base + 1] = 1
            out[base + 2] = clamp((value.x_int - self.x_int) * face / 300, -3, 3)
            out[base + 3] = clamp((value.z_int - self.z_int) / 60, -3, 3)
            out[base + 4] = clamp((value.y_int - self.y_int) / 100, -3, 3)
            out[base + 5] = clamp((value.vx or 0) * face / 10, -3, 3)
            out[base + 6] = clamp((value.vz or 0) / 4, -3, 3)
        else
            for i = 1, 6 do out[base + i] = 0 end
        end
    end
    at = at + 12
    -- The fighter's own meters and the target's: knocked-down meter, guard meter, its press buffers.
    out[at + 1] = clamp((self.fall_damage or 0) / 100, -1, 2)
    out[at + 2] = clamp((self.timer_b8 or 0) / 100, -1, 2)
    out[at + 3] = (self.attack_press > 0 or self.jump_press > 0 or self.defend_press > 0) and 1 or 0
    return out
end

-- (Every step ends with "RL_DONE": what the kit waits for before it reads the lines above it.)
function job.run(config)
    job.step(config)
    engine.log("RL_DONE")
end

function job.step(config)
    local step = config.step or "play"
    if step == "avg" then return job.average(config) end
    if step == "sum" then return job.sum(config) end
    if step == "who" then
        -- The learned side named by `fighter`: RLF <id> <name>, or RLF_ERROR and the mod's fighters.
        local fighters = catalog.load()
        local ok, id = pcall(require("bench/names").id, fighters, config.fighter or 2)
        if not ok then engine.log("RLF_ERROR " .. tostring(id)); return end
        for _, fighter in ipairs(fighters) do
            if fighter.id == id then engine.log(string.format("RLF %d %s", id, tostring(fighter.name))); return end
        end
        return
    end
    local smart = require("base/game/smart_ai")
    local fighters, backgrounds = catalog.load(), catalog.backgrounds()
    brains.load("xoi@hs_alt")
    local by_id = {}
    for index, fighter in ipairs(fighters) do by_id[fighter.id] = by_id[fighter.id] or index end
    -- The learned side: an id, or a name (bench/names).
    local me_id = require("bench/names").id(fighters, config.fighter or 2)
    local me_index = assert(by_id[me_id], "no fighter " .. tostring(me_id))
    local pool = {}
    if config.ids then
        for _, id in ipairs(config.ids) do if by_id[id] then pool[#pool + 1] = by_id[id] end end
    else
        for index, fighter in ipairs(fighters) do
            if not fighter.hidden and fighter.id ~= 40 then pool[#pool + 1] = index end
        end
    end
    if config.brain then
        local brain = assert(smart.brain_kit.parse(require("bench/" .. config.brain).text), "the brain's text does not fit")
        smart.set_brain(brain)
        engine.log("brain " .. config.brain .. " on the learned side")
    else
        smart.set_brain(nil)
    end
    local alt = brains.load("xoi@hs_alt")
    if alt and alt.set_brain then alt.set_brain(nil) end
    -- (The game's own learned brains, smart.rl_kit, stay off on both sides: this job plays the network it learns.)
    if smart.rl_kit then smart.rl_kit.off = true end
    if alt and alt.rl_kit then alt.rl_kit.off = true end
    local p = config.weights and parse_params(require("bench/" .. config.weights).text, "RLW") or new_params(config.init_seed or 1)
    -- How the learned side plays the game under way: "learn" (drawn from the network, recorded), "sample" (drawn),
    -- "greedy" (the likeliest), "follow" (XOI alone).
    local mode = "learn"
    local rnd = lcg((config.seed or 1) * 7919 + (config.offset or 0) * 104729 + 13)
    -- The trajectory of the process: per decision of the learned side, its numbers, action, probability, value,
    -- reward, frames; per game, where it ends.
    local X, Aa, LP, V, R, DONE, K = {}, {}, {}, {}, {}, {}, {}
    local moves_used = {}
    local n = 0
    local h1, h2, z, pr = {}, {}, {}, {}
    local current = nil -- {self, target, last = keys, hp, thp, pending (the step awaiting reward), move}
    local overrides, frames_seen = 0, 0
    local entropy_sum = 0
    local control = smart.control
    smart.control = function(state, index)
        local result = control(state, index)
        local c = current
        if c and state.items[index] == c.self then
            local self, target = c.self, c.target
            -- The reward of the step before: HP dealt minus HP taken since, in hundreds.
            if c.pending then
                R[c.pending] = R[c.pending] + ((c.thp - target.hp) - (c.hp - self.hp)) / 100
            end
            c.hp, c.thp = self.hp, target.hp
            if c.move then
                -- A move of the network's under way: its next frame.
                local move = c.move
                apply_frame(self, MOVES[move.index][move.at], move.right, c.last)
                move.at = move.at + 1
                if c.pending then K[c.pending] = K[c.pending] + 1 end
                if move.at > #MOVES[move.index] then c.move = nil end
            elseif mode == "follow" or not can_act(self) then
                -- XOI's keys go through; the frame counts to the step under way.
                if c.pending then K[c.pending] = K[c.pending] + 1 end
            else
                local xoi_kind = kind_of(self.keys, self.previous_keys, self.facing)
                local x = observe(smart, state, self, target, xoi_kind, c.last, {})
                local v = forward(p, x, h1, h2, z)
                softmax(z, pr)
                local a
                if mode == "greedy" then
                    a = 1
                    for k = 2, NA do if pr[k] > pr[a] then a = k end end
                else
                    local u, acc = rnd(), 0
                    a = NA
                    for k = 1, NA do acc = acc + pr[k]; if u <= acc then a = k; break end end
                end
                local ent = 0
                for k = 1, NA do if pr[k] > 0 then ent = ent - pr[k] * log(pr[k]) end end
                entropy_sum = entropy_sum + ent
                frames_seen = frames_seen + 1
                if mode == "learn" then
                    n = n + 1
                    X[n], Aa[n], LP[n], V[n], R[n], DONE[n], K[n] = x, a, log(max(pr[a], 1e-12)), v, 0, false, 1
                    -- (A test of the learning: a bonus for choosing one move.)
                    if config.bonus_move and a == config.bonus_move + 1 then R[n] = config.bonus or 1 end
                    c.pending = n
                end
                if a ~= 1 then
                    overrides = overrides + 1
                    moves_used[a - 1] = (moves_used[a - 1] or 0) + 1
                    local move = {index = a - 1, at = 1, right = self.facing == facing_right}
                    apply_frame(self, MOVES[move.index][1], move.right, c.last)
                    move.at = 2
                    if move.at <= #MOVES[move.index] then c.move = move end
                end
            end
            local last = c.last
            for _, key in ipairs(KEYS) do last[key] = self.keys[key] end
        end
        return result
    end

    local seed_table = engine.random_state()
    local offset = config.offset or 0
    local limit = config.limit or 9000
    local random = lcg(config.seed or 1)
    local function pick(count) return floor(random() * count) + 1 end
    local win_reward = config.win or 2
    -- One game from its point of the random sequence (the same game again: the same start).
    local function play(game, b, row)
        engine.set_random_state(seed_table, (game * 37 + 11 + offset) % 2999, 0)
        local result
        local ok, problem = pcall(function()
            local state = match.create({mode = constants.modes.versus, difficulty = config.difficulty or -3, background = row,
                fighters = fighters, backgrounds = backgrounds,
                slots = {[0] = {kind = "computer", fighter = me_index, team = 1}, [1] = {kind = "computer", fighter = b, team = 2}}})
            state.items[10].brain = "xoi"
            state.items[11].brain = "xoi@hs_alt"
            current = {self = state.items[10], target = state.items[11], last = {}, hp = state.items[10].hp, thp = state.items[11].hp}
            local held = {functions = "", function_presses = "", keys = {}}
            local ticks = 0
            while ticks < limit do
                match.step(state, held)
                ticks = ticks + 1
                local one, two = state.items[10], state.items[11]
                if not one or not two then break end
                if one.hp <= 0 or two.hp <= 0 or state.round_counter > 0 then break end
            end
            local one, two = state.items[10], state.items[11]
            local h1v, h2v = one and one.hp or 0, two and two.hp or 0
            local r, bonus = "D", 0
            if h1v > 0 and h2v <= 0 then r, bonus = "W", win_reward
            elseif h2v > 0 and h1v <= 0 then r, bonus = "L", -win_reward end
            local c = current
            if c.pending then
                R[c.pending] = R[c.pending] + ((c.thp - (two and two.hp or 0)) - (c.hp - (one and one.hp or 0))) / 100 + bonus
                DONE[c.pending] = true
            end
            result = {r = r, ticks = ticks, h1 = h1v, h2 = h2v}
        end)
        current = nil
        if not ok then
            engine.log("game " .. game .. " failed: " .. tostring(problem))
            if n > 0 then DONE[n] = true end
        end
        return result
    end
    local games = config.games or 10
    local wins, losses, draws, margin, played = 0, 0, 0, 0, 0
    local function tally(res)
        played = played + 1
        if res.r == "W" then wins = wins + 1 elseif res.r == "L" then losses = losses + 1 else draws = draws + 1 end
        margin = margin + (max(res.h1, 0) - max(res.h2, 0))
    end
    if step == "eval" then
        -- Paired: each game from the same start played by XOI alone and by the network - the likeliest action
        -- ("greedy": what it would play in a match) and/or one drawn ("sample": as it learns); RLE <way>: the
        -- sums of the differences (points: a win 1, a draw 1/2) for step "sum".
        local points = {W = 1, D = 0.5, L = 0}
        local ways = config.greedy and {"greedy"} or (config.both and {"greedy", "sample"} or {"sample"})
        local acc = {}
        for _, way in ipairs(ways) do acc[way] = {sd = 0, sd2 = 0, sh = 0, sh2 = 0, same = 0, n = 0, w = 0, l = 0, d = 0} end
        local xw, xl, xd = 0, 0, 0
        for game = 1, games do
            local b = pool[pick(#pool)]
            local row = pick(#backgrounds) - 1
            mode = "follow"
            local base = play(game, b, row)
            if base then
                if base.r == "W" then xw = xw + 1 elseif base.r == "L" then xl = xl + 1 else xd = xd + 1 end
                for _, way in ipairs(ways) do
                    mode = way
                    local one = play(game, b, row)
                    if one then
                        local a = acc[way]
                        if one.r == "W" then a.w = a.w + 1 elseif one.r == "L" then a.l = a.l + 1 else a.d = a.d + 1 end
                        local d = points[one.r] - points[base.r]
                        local h = (max(one.h1, 0) - max(one.h2, 0)) - (max(base.h1, 0) - max(base.h2, 0))
                        a.sd, a.sd2, a.sh, a.sh2, a.n = a.sd + d, a.sd2 + d * d, a.sh + h, a.sh2 + h * h, a.n + 1
                        if one.r == base.r and one.ticks == base.ticks and one.h1 == base.h1 and one.h2 == base.h2 then a.same = a.same + 1 end
                        engine.log(string.format("RLP %s %d %d %d %s %s %d %d", way, game, me_id, fighters[b].id, one.r, base.r,
                            max(one.h1, 0) - max(one.h2, 0), max(base.h1, 0) - max(base.h2, 0)))
                    end
                end
            end
        end
        for _, way in ipairs(ways) do
            local a = acc[way]
            engine.log(string.format("RLE %s %d %.6g %.6g %.6g %.6g %d %d %d %d %d %d %d", way, a.n, a.sd, a.sd2, a.sh, a.sh2,
                a.w, a.l, a.d, xw, xl, xd, a.same))
        end
        smart.control = control
        return
    end
    mode = (step == "play") and "learn" or (config.follow and "follow" or (config.greedy and "greedy" or "sample"))
    for game = 1, games do
        local b = pool[pick(#pool)]
        local row = pick(#backgrounds) - 1
        local res = play(game, b, row)
        if res then
            tally(res)
            engine.log(string.format("RES %d %d %d %s %d %d %d", game, me_id, fighters[b].id, res.r, res.ticks, res.h1, res.h2))
        end
    end
    smart.control = control
    engine.log(string.format("RLS games %d won %d lost %d drawn %d margin %.1f overrides %.2f%% entropy %.3f frames %d",
        played, wins, losses, draws, played > 0 and margin / played or 0, frames_seen > 0 and 100 * overrides / frames_seen or 0,
        frames_seen > 0 and entropy_sum / frames_seen or 0, frames_seen))
    local parts = {}
    for m = 1, #MOVES do parts[#parts + 1] = string.format("%s %d", MOVE_NAMES[m], moves_used[m] or 0) end
    engine.log("RLM " .. table.concat(parts, ", "))
    if mode ~= "learn" or n == 0 then return end
    job.learn(config, p, X, Aa, LP, V, R, DONE, n, K)
end

-- The processes' RLE lines (module `evals`) summed, way by way: RLC <way>, the network against XOI alone over the
-- same games.
function job.sum(config)
    local text = require("bench/" .. config.evals).text
    local by, order = {}, {}
    for line in text:gmatch("[^\n]+") do
        local f = {}
        for token in line:gmatch("%S+") do f[#f + 1] = token end
        if f[1] == "RLE" and #f >= 14 then
            local way = f[2]
            local t = by[way]
            if not t then t = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}; by[way] = t; order[#order + 1] = way end
            for i = 1, 12 do t[i] = t[i] + tonumber(f[i + 2]) end
        end
    end
    if #order == 0 then engine.log("RLC no games"); return end
    for _, way in ipairs(order) do
        local t = by[way]
        local n, sd, sd2, sh, sh2, w, l, d, xw, xl, xd, same = t[1], t[2], t[3], t[4], t[5], t[6], t[7], t[8], t[9], t[10], t[11], t[12]
        if n >= 2 then
            local md, mh = sd / n, sh / n
            local se_d = sqrt(max(sd2 / n - md * md, 0) * n / (n - 1) / n)
            local se_h = sqrt(max(sh2 / n - mh * mh, 0) * n / (n - 1) / n)
            engine.log(string.format("RLC %s games %d: network %d-%d (draws %d, %.1f%%), XOI alone %d-%d (draws %d, %.1f%%); network - XOI %+.1f points per 100 games +- %.1f (95%%); HP margin %+.1f +- %.1f a game; same game %d",
                way, n, w, l, d, 100 * (w + d / 2) / n, xw, xl, xd, 100 * (xw + xd / 2) / n, 100 * md, 196 * se_d, mh, 1.96 * se_h, same))
            -- (For the kit, whole numbers: the difference and its lower 95% bound, in tenths of a point per 100 games.)
            engine.log(string.format("RLB %s %d %d", way, floor(1000 * md + 0.5), floor(1000 * md - 1960 * se_d + 0.5)))
        end
    end
end

-- PPO from the round's network on this process's own steps; prints the change as RLD lines.
function job.learn(config, p0, X, Aa, LP, V, R, DONE, n, K)
    local gamma, lambda = config.gamma or 0.997, config.lambda or 0.95
    local ADV, RET = {}, {}
    local next_adv, next_v = 0, 0
    for t = n, 1, -1 do
        if DONE[t] then next_adv, next_v = 0, 0 end
        -- (A step of k frames: discounted k times.)
        local gk = gamma ^ (K and K[t] or 1)
        local delta = R[t] + gk * next_v - V[t]
        local adv = delta + gk * lambda * next_adv
        ADV[t], RET[t] = adv, adv + V[t]
        next_adv, next_v = adv, V[t]
    end
    local mean, sq = 0, 0
    for t = 1, n do mean = mean + ADV[t] end
    mean = mean / n
    for t = 1, n do sq = sq + (ADV[t] - mean) ^ 2 end
    local sd = sqrt(sq / n) + 1e-8
    for t = 1, n do ADV[t] = (ADV[t] - mean) / sd end
    local p = {}
    for i = 1, NP do p[i] = p0[i] end
    local m1, m2 = {}, {}
    for i = 1, NP do m1[i], m2[i] = 0, 0 end
    local g = {}
    local rate, clip, ent_c, vcoef = config.rate or 3e-4, config.clip or 0.2, config.entropy or 0, config.vcoef or 0.5
    local b1c, b2c, eps = 0.9, 0.999, 1e-8
    local adam_t = 0
    local batch = config.batch or 256
    local order = {}
    for t = 1, n do order[t] = t end
    local rnd = lcg((config.seed or 1) * 31 + 7)
    local h1, h2, z, pr = {}, {}, {}, {}
    local dz, dh2, dh1 = {}, {}, {}
    local stats_pl, stats_vl, stats_kl, stats_clip, stats_count = 0, 0, 0, 0, 0
    for epoch = 1, config.epochs or 3 do
        for t = n, 2, -1 do
            local j = floor(rnd() * t) + 1
            order[t], order[j] = order[j], order[t]
        end
        for start = 1, n, batch do
            local stop = min(n, start + batch - 1)
            for i = 1, NP do g[i] = 0 end
            local count = stop - start + 1
            for o = start, stop do
                local t = order[o]
                local x = X[t]
                local v = forward(p, x, h1, h2, z)
                softmax(z, pr)
                local a = Aa[t]
                local lp = log(max(pr[a], 1e-12))
                local ratio = exp(lp - LP[t])
                local adv = ADV[t]
                -- Clipped surrogate: the gradient flows only where the clip does not hold the ratio.
                local active = not ((adv > 0 and ratio > 1 + clip) or (adv < 0 and ratio < 1 - clip))
                local ent = 0
                for k = 1, NA do if pr[k] > 0 then ent = ent - pr[k] * log(pr[k]) end end
                for k = 1, NA do
                    local d = 0
                    if active then d = -ratio * adv * ((k == a and 1 or 0) - pr[k]) end
                    -- minus the entropy: d(-H)/dz_k = pr_k (log pr_k + H)
                    if pr[k] > 0 then d = d + ent_c * pr[k] * (log(pr[k]) + ent) end
                    dz[k] = d / count
                end
                local dv = 2 * vcoef * (v - RET[t]) / count
                stats_pl = stats_pl - (active and ratio * adv or (1 + (adv > 0 and clip or -clip)) * adv)
                stats_vl = stats_vl + (v - RET[t]) ^ 2
                stats_kl = stats_kl + (LP[t] - lp)
                if not active then stats_clip = stats_clip + 1 end
                stats_count = stats_count + 1
                -- Back through the heads.
                for i = 1, NH do dh2[i] = p[oWV + i] * dv end
                for k = 1, NA do
                    local d = dz[k]
                    if d ~= 0 then
                        local base = oWP + (k - 1) * NH
                        for i = 1, NH do
                            g[base + i] = g[base + i] + d * h2[i]
                            dh2[i] = dh2[i] + d * p[base + i]
                        end
                        g[oBP + k] = g[oBP + k] + d
                    end
                end
                for i = 1, NH do g[oWV + i] = g[oWV + i] + dv * h2[i] end
                g[oBV + 1] = g[oBV + 1] + dv
                -- Layer 2.
                for i = 1, NH do dh1[i] = 0 end
                for j = 1, NH do
                    local da = dh2[j] * (1 - h2[j] * h2[j])
                    if da ~= 0 then
                        local base = oW2 + (j - 1) * NH
                        for i = 1, NH do
                            g[base + i] = g[base + i] + da * h1[i]
                            dh1[i] = dh1[i] + da * p[base + i]
                        end
                        g[oB2 + j] = g[oB2 + j] + da
                    end
                end
                -- Layer 1.
                for j = 1, NH do
                    local da = dh1[j] * (1 - h1[j] * h1[j])
                    if da ~= 0 then
                        local base = oW1 + (j - 1) * NOBS
                        for i = 1, NOBS do
                            local xi = x[i]
                            if xi ~= 0 then g[base + i] = g[base + i] + da * xi end
                        end
                        g[oB1 + j] = g[oB1 + j] + da
                    end
                end
            end
            -- Adam.
            adam_t = adam_t + 1
            local c1, c2 = 1 - b1c ^ adam_t, 1 - b2c ^ adam_t
            for i = 1, NP do
                local gi = g[i]
                local a1 = b1c * m1[i] + (1 - b1c) * gi
                local a2 = b2c * m2[i] + (1 - b2c) * gi * gi
                m1[i], m2[i] = a1, a2
                p[i] = p[i] - rate * (a1 / c1) / (sqrt(a2 / c2) + eps)
            end
        end
    end
    engine.log(string.format("RLL steps %d policy %.4f value %.4f kl %.5f clipped %.3f", n, stats_pl / stats_count,
        stats_vl / stats_count, stats_kl / stats_count, stats_clip / stats_count))
    local d = {}
    for i = 1, NP do d[i] = p[i] - p0[i] end
    for _, line in ipairs(params_text(d, "RLD")) do engine.log(line) end
end

-- The mean of the processes' changes laid onto the round's network: RLW lines (and RLW_HEAD). The changes are the
-- processes' RLD lines (with their RLS and RLM lines): in files handed over as assets of this package, one a process
-- (`parts` of them: mods/bench/rl_part_<k>.txt — the kit's way: a bench module may not exceed 1 MiB, nor all of them
-- together 8, and the change of one process is some 150 KB), or in the bench module `deltas` (a few processes).
function job.average(config)
    local p = config.weights and parse_params(require("bench/" .. config.weights).text, "RLW") or new_params(config.init_seed or 1)
    local sum, count = {}, 0
    for i = 1, NP do sum[i] = 0 end
    local skipped, missing = 0, 0
    -- The round's games, from the processes' RLS and RLM lines.
    local g, w, l, dr, m, ov, en, k = 0, 0, 0, 0, 0, 0, 0, 0
    local moves = {}
    local function take(text)
        -- The processes' changes, each from its RLD_HEAD to the next.
        local current, seen = nil, 0
        local function close()
            if current then
                -- (A change cut short - a process stopped while writing it - is left out.)
                if seen == NP then
                    for i = 1, NP do sum[i] = sum[i] + current[i] end
                    count = count + 1
                else
                    skipped = skipped + 1
                end
            end
            current, seen = nil, 0
        end
        for line in text:gmatch("[^\n]+") do
            if line:match("^RLD_HEAD ") then
                close()
                current = {}
            else
                local start, rest = line:match("^RLD (%d+) (.*)$")
                if start then
                    if current then
                        local i = tonumber(start)
                        for token in rest:gmatch("%S+") do current[i] = tonumber(token); i = i + 1; seen = seen + 1 end
                    end
                else
                    local gg, ww, ll, dd, mm, oo, ee = line:match("^RLS games (%d+) won (%d+) lost (%d+) drawn (%d+) margin (%S+) overrides (%S+)%% entropy (%S+)")
                    if gg then
                        gg = tonumber(gg)
                        g, w, l, dr, m = g + gg, w + tonumber(ww), l + tonumber(ll), dr + tonumber(dd), m + tonumber(mm) * gg
                        ov, en, k = ov + tonumber(oo), en + tonumber(ee), k + 1
                    end
                    local listed = line:match("^RLM (.*)$")
                    if listed then
                        for name, n in listed:gmatch("([^,%s]+) (%d+)") do moves[name] = (moves[name] or 0) + tonumber(n) end
                    end
                end
            end
        end
        close()
    end
    if config.parts then
        for part = 1, config.parts do
            local ok, text = pcall(engine.read_resource, "mods/bench/rl_part_" .. part .. ".txt")
            if ok and type(text) == "string" then take(text) else missing = missing + 1 end
        end
    else
        take(require("bench/" .. config.deltas).text)
    end
    assert(count > 0, "no changes")
    if g > 0 then
        engine.log(string.format("RLR games %d won %d lost %d drawn %d margin %+.1f overrides %.2f%% entropy %.3f", g, w, l, dr, m / g, ov / k, en / k))
        local parts = {}
        for i, name in ipairs(MOVE_NAMES) do parts[i] = string.format("%s %d", name, moves[name] or 0) end
        engine.log("RLR moves " .. table.concat(parts, ", "))
    end
    local scale = config.scale or 1
    for i = 1, NP do p[i] = p[i] + scale * sum[i] / count end
    engine.log(string.format("RLA averaged %d changes (%d cut short, left out%s)", count, skipped,
        missing > 0 and string.format("; files not found: %d", missing) or ""))
    for _, line in ipairs(params_text(p, "RLW")) do engine.log(line) end
end

return job
