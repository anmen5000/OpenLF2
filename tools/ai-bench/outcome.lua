-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors
-- How a game ended for a side, as the game takes it when it ends the round (base/game/match, versus_counter): a side
-- is down when no character of its team stands, on the stage with HP left. A fighter gone from the stage is down
-- whatever HP it had: NTSD 2.6's Hiruzen(Clone) and Kisame(Clone) go up in smoke when struck (frame 300 "puff", or
-- the water clone's 347 and 350, leading to 1000), and the bench's tools counted their games as draws, the HP they
-- had being still theirs (the project owner's report, package 107). A side whose fighter is down while a character
-- it made still stands (Naruto's clones) is not down, as the round goes on. (Here and not in base/game: a measure
-- keeps the game's scripts it began with, can-bang.bat's and spsa.bat's, and this is to work with those too.)
local constants = require("base/game/constants")
local outcome = {}
local item_slots = constants.item_slots
local character = constants.record_kinds.character
local teams = constants.teams

-- Whether `value` stands for its team, as versus_counter counts the teams still in the round.
local function standing(value)
    return value.hp > 0 and value.record.kind == character and value.team > teams.independent
        and value.team < teams.active_end_exclusive and value.team ~= teams.enemies
end

-- Whether the side of the fighter in slot `slot`, of team `team`, is down, and the HP it ends with: the fighter's own
-- while it is on the stage, else what its team still stands with.
function outcome.side(state, slot, team)
    local count, hp = 0, 0
    for index = 0, item_slots - 1 do
        local value = state.items[index]
        if value and value.team == team and standing(value) then count, hp = count + 1, hp + value.hp end
    end
    local own = state.items[slot]
    if own then hp = math.max(own.hp, 0) end
    return count == 0, hp
end
return outcome
