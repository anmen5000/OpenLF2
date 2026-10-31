# AI bench

A mod package that turns OpenLF2 into a test bench for the computer players, above all the INSANE! level
(`scripts/base/game/smart_ai.lua`): it replaces the menus (`base/ui/flow`) with one job, read from `config.lua`,
that runs on the first frame and prints to the game's log. No window is needed: `--input-trace ""` makes a headless
run that ends when the job has printed.

```sh
# INSANE! against the original computer player, the games of config.lua, on a whole-game mod:
openlf2 --pack onepiece.zip --mod tools/ai-bench --seed 12345 --input-trace ""
# ... or on the original game:
openlf2 --installer LF2_v2.0a.exe --mod tools/ai-bench --seed 12345 --input-trace ""
```

`--seed` fixes the random numbers, so a run can be repeated exactly; compare two versions of the AI by running the
same job with `--scripts <dir>` pointing at each version's `scripts` directory. The web build is plain Lua 5.2 and
a desktop build is LuaJIT; the AI only uses what both have, and its decisions depend only on the match's state
(`replaytest` checks that), so results are the same on both.

## Jobs

Edit `config.lua` (a Lua table) and set `command` to one of these:

| command | what it does | fields |
| --- | --- | --- |
| `duel` | AI against AI, `games` games per pair of fighter ids in `pairs`; the first fighter of a pair is played by `brains[1]` (`"smart"` is INSANE!, `"classic"` the original computer player at the match's `difficulty`, `-1` = CRAZY!/INSANE!). Prints each pair's score and a `TOTAL` line; with `usage`, the moves of each form too. | `pairs`, `brains`, `games`, `difficulty`, `limit` (frames per game, default 5400), `verbose` (one line per game), `usage` (every move INSANE! learned, with how often it started it), `stats` (N: damage dealt and taken by decision), `events` + `history` (every hit with both fighters' last decisions), `trace` (N: both fighters every N frames), `models` (after each game, what each fighter's opponent model counted: guards, hits, attacks and chances, falls and flips, jumps), `probe` (frames at which to print INSANE!'s view), `hash` (N: a per-frame line for the first N frames of the first game, for determinism checks), `no_ego`, `no_prepare`, `nobrain` |
| `moves` | What INSANE! learned about the fighters in `only` (`{[id] = true}`): every move with its start, first and last hit, recovery, MP, damage and reach; then each form of the fighter (an item of its own making in hand: its item, resting and running frames, MP burn, run speed and worth) with the moves learned in it. `boxes` lists the hit boxes of form-entering moves. | `only`, `boxes` |
| `timing` | How many moves, entries and sandbox plays the learning of each fighter in `only` takes, and of its forms (an item of its own making in hand). | `only`, `cap` |
| `keyseq` | Plays a scripted key timeline (`seq`: `{{frame, "key", true|false}, ...}`, keys `up down left right attack jump defend`) on fighter `id` against a still `other`, and logs the fighter's frame, position, MP, weapon code and the objects it owns every frame a frame changes (and every `every` frames): how a form is entered, what it costs, how it runs and stops. | `id`, `other`, `far`, `mp`, `ticks`, `every`, `seq` |
| `probe` | Prints what INSANE! makes of some frames of fighter `id`: the key that leaves a stance from it and how long the fighter is held there. | `id`, `frames` |
| `frames` | The chosen `frames` of fighter `id`: state, wait, next, bodies, attacks, hit_* fields. | `id`, `frames` |
| `dump` | A summary of every fighter's combos, basic attacks and guard (`only` narrows it). | `only` |
| `settle` | The frames a fighter passes through from the start with no input, or with `press` held. | `id`, `other`, `ticks`, `press` |
| `mpcheck` | Puts fighter `id` into `frame` with `mp` and prints its MP as the frames run (charging moves). With `press` (a key name) and `press_at`, presses that key from that frame on. | `id`, `frame`, `mp`, `ticks`, `every`, `press`, `press_at`, `other` |
| `watch` | Plays one learning entry of fighter `id` with a frame-by-frame log of the fighter and what it spawns. | `id`, `entry`, `from`, `to`, `full` |
| `weapontest` | Drops a weapon (`weapon`, an object id of the mod: knife, stick, stone, drink...) beside INSANE! fighter `ids[1]` facing `ids[2]` and logs the fighter and the weapon every `every` frames for `ticks` frames: does it walk onto it, pick it up (`pickings` at the end), swing, throw or drink? `passive` makes the opponent stand still, `far` moves the opponent that far away, `offset` places the weapon, `probe` (`{[tick] = true}`) prints INSANE!'s view at those frames, `manual` stands on the weapon and presses attack without the AI (does the game itself pick it up?). | `ids`, `weapon`, `ticks`, `every`, `passive`, `far`, `offset`, `probe`, `manual`, `manual_dx`, `foe` |
| `replaytest` | Runs the same INSANE! match twice from the same random state (moves unlearned, then learned) and compares the fighters every 30 frames: must print SAME. | `ids`, `limit` |
| `stagetest` | An INSANE! Stage mode run with computer players. | `ids`, `level`, `difficulty`, `limit` |
| `loadall` | Loads every object of the mod as a match would and reports what fails. | `diagnostics` |
| `aitest` | Checks that a mod's own AI scripts (`ai/*.as`) compile and make instances. | `ids`, `other` |

Fighter ids are those of the mod's `data.txt`. `moves` and `duel` with `usage = true` together show what the AI knows
about a fighter and what it actually uses; a move it never starts has a reason worth finding (too slow for the
situations that arise, never within reach, a stance whose exit key it does not press...).

## Reading the AI

`scripts/base/game/smart_ai.lua` is one file, in this order: learning (`analyze`, `play`, `measure_hit`, the
sandbox), geometry (`predict`, `move_hits`), threats (`earliest_threat`), choosing (`can_start`, `worth`,
`attack_score`, `best_attack`, `approach_attack`, `answer`), and the per-frame `smart.control`. `smart.levels`
holds the levels' reaction times. The debugging hooks `smart.trace`, `smart.on_start`, `smart.watch` and
`smart.internals` are what the jobs above use.
