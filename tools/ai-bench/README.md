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
same job with `--scripts <dir>` pointing at each version's `scripts` directory, or let them fight each other (below).
The web build is plain Lua 5.2 and a desktop build is LuaJIT; the AI only uses what both have, and its decisions
depend only on the match's state (`replaytest` checks that), so results are the same on both.

## Watching a match

`command = "show"` plays the match in the window instead of headlessly: `brains` against each other on the two
fighter ids in `ids`, `games` games with the sides swapped every other game, the score on the status line, and the
game's own keys at work (F1 pauses, F5 runs fast, F4 leaves). Run the game with the package as the mod and a game
to play:

```sh
# the original game
openlf2 --installer LF2_v2.0a.exe --mod tools/ai-bench
# a mod packed as a ZIP file (the same file the relay takes)
openlf2 --pack onepiece.zip --mod tools/ai-bench
```

with `config.lua` such as `{command = "show", brains = {"smart", "classic"}, ids = {4, 7}, games = 5}` (INSANE!
against the original computer player) or `{command = "show", brains = {"smart", "smart@ai_alt"}, ids = {1, 1},
games = 3}` (this INSANE! against the version copied in as `ai_alt.lua`, see below). On Windows the game is the
installed `openlf2.exe` (`%LOCALAPPDATA%\Programs\OpenLF2\openlf2.exe` after "Install for me only";
`OpenLF2-Windows-x64.exe` from GitHub is its installer): a `.bat` file beside the mod's ZIP and this folder, such as
`"%LOCALAPPDATA%\Programs\OpenLF2\openlf2.exe" --pack "%~dp0onepiece.zip" --mod "%~dp0ai-bench"`, starts it.
Any other `command` runs without drawing — the window stays blank while the job runs and its lines go to the
console — so `show` is the one to watch.

## Two computer players against each other

A brain in `duel`'s `brains` is `"smart"` (INSANE! as in `scripts/`), `"xoi"` (XOI: INSANE! with the notes of
training, below; `"xoi:m"` weighs moves by the notes alone, as XOI did up to version 26, `"xoi:c"` adds the
situations, `"xoi:p"` the spots), `"classic"` (the original computer player), or `"smart@<module>"`: another computer player in the
shape of `smart_ai.lua`, loaded from this package as
`<module>.lua` (listed in `package.manifest` as `module=<module>|<module>.lua`). To pit a version of INSANE!
against an older one, copy the older `smart_ai.lua` in as `ai_alt.lua` and use `brains = {"smart", "smart@ai_alt"}`;
the log's first line names both versions (`brains: smart v22 against smart@ai_alt v21`; a version before 20 has
no number and is named so). Each player keeps its own context — how it reads the fighters' moves, its model of the
opponent — as it would in a match of its own (before 1 November 2026 the two shared one, which skewed matches
between versions that read moves differently, such as 23 against 16). `ai_template.lua` is a
computer player of your own in that shape — `prepare(state)` once before the match, `control(state, index)`
every frame, keys set on `state.items[index]` — ready to be copied and filled in: `brains = {"smart",
"smart@ai_template"}` runs it against INSANE!. Whatever it does must follow from the match's state alone (no
clock, no random numbers of its own, nothing kept outside the state between frames), or recordings and network
games fall out of step (a `duel` with `hash = N` run twice must print the same lines).

## Training XOI

XOI, the level after INSANE!, is INSANE! playing with notes of training: for each fighter against each opponent,
what each of its moves brought when it chose them, and how often the opponent struck first a move started at a risk
(`scripts/base/game/smart_ai.lua`, "XOI"). The `learn` job writes them: both fighters of every pair play many games
as INSANE! (the sides swap every game) and, as each pair's games end, the job prints lines starting `XOI `:

```
XOI G <a> <b> <games> <wins> <draws>
XOI R <a> <b> <moves started at a risk> <struck first>
XOI M <a> <b> <move> <starts> <landed> <struck first> <damage dealt> <damage taken> <expected>
XOI C <a> <b> <move> <situation>:<starts>,<dealt - taken>,<expected> ...
XOI P <a> <b> <spot>:<frames>,<visits>,<dealt>,<taken>,<squares> ...
```

(`C`, from version 27: the same move by the situation it was started in — `sf`/`sr` the opponent free on its feet
facing a or turned away, `sb` busy in a move, `sa` in the air, `sg` guarding, `sh` hurt, down or held; `dn`/`dm`/`df`
within 80, 220 or farther; `hl`/`hh` a's HP a third of the bar or less, or more. `P`: the frames a stood free with b
free on its feet too, by spot — `f` in front of b or `b` behind it, then which of the distances 30 60 100 150 220 320
480 and of the depths 8 18 32 it is past — in how many visits, with the damage dealt and taken in the 45 frames after
each and the sum of the squares of their difference.)

(a's record against b; a move is named as the AI learned it, such as `ground:s1:295` — the D>A that leads to frame
295 — or `ground:60>63jump`, the punch continued with jump in frame 63). Gathered into one file, they go into the
mod's ZIP file as `xoi/notes.txt` beside its `data` folder; lines of several runs simply add up. At XOI a move's
score is weighed by how much of what was expected of it, against this opponent, it brought, against the fighter's
moves on the whole (counted over a few starts' worth of the average, so that a move seldom tried stays near it; the
weight stays between 0.5 and 1.6), and the opponent's answers to a risky move start from what training saw. Each
side of the situation the move would start in changes that weight by a small part (0.75 to 1.33, the three together
0.7 to 1.4, as far as the starts seen there bear it out), and positioning neither steps onto a spot clearly worse
than where it stands nor passes up one clearly better within a few steps (clearly: by more than either may be off).
The match line shows `(XOI v27, N matchups)`, or `no notes` when the mod has none — XOI then plays as INSANE!;
notes made before version 27 have no situations or spots, and XOI weighs moves by them as before.

```sh
# every pair of these fighters, 100 games each; or ids = "all" (every fighter of the mod)
#   config.lua: return {command = "learn", games = 100, ids = {1, 2, 7, 18}}
openlf2 --pack naruto.zip --mod tools/ai-bench --seed 5001 --input-trace "" | grep "^XOI " > notes.txt
```

`part`/`parts` give a job its share of the pairs, for many jobs side by side. On Windows, `windows/xoi-hoc.bat`
(copied beside the mod's ZIP file and this package's `tools` and `scripts` folders) does all of it: one job per
processor, the notes gathered into `xoi-<mod>\notes.txt`, and a copy of the mod's ZIP file with them inside
(`<mod>-xoi.zip`, for the relay; the one before is kept as `<mod>-xoi-truoc.zip`). `NAO=xoi` trains a further round
with both fighters played by XOI on the notes gathered so far (`brains = {"xoi", "xoi"}` with the notes handed to
the job): XOI's expected scores are counted before its notes weighed them, so the rounds add up — but measure every
round against the one before: the notes only weigh which move is chosen, and a round of XOI against itself may learn
its own habits rather than an opponent's. It plays with the installed game's scripts updated by the package's (the package
holds only the files that changed), so the installed game need not be the latest. A `duel` with `brains = {"xoi",
"smart"}` and `difficulty = -2` on that ZIP file shows what the notes are worth (`notes = "<module>"` hands a
`duel` or `learn` job notes of its own instead: a module of this package returning `{text = "..."}`).
`windows/dau-nhieu.bat` runs a `duel` the same way: by default every fighter against every other (`ids = "all"`,
`brains = {"xoi", "smart"}`, each fighter played by each brain), the matchups split over the processors, then for
each fighter (with its name) its win rate when the first brain plays it, when the second does, and the difference —
a weak fighter is low in both, so the difference is what tells how the brains play it — and every pair's score in
`cap.txt`; with `IDS` left empty, every job runs `config.lua` with its own seed and the scores are added up.

`windows/choi.bat` plays a mod with INSANE! and XOI on the installed game, for players: double-clicked, it takes the
first `*-xoi.zip` beside it, else the first `.zip`; dragged onto it, a mod's ZIP, its folder or its `.exe` (a folder
is zipped once beside the file by PowerShell's ZIP classes, entries named with `/`), with a notes `.txt` if any — or
`<mod>-notes.txt` / `xoi-<mod>\notes.txt` beside it — which it packs into a copy, `<mod>-xoi.zip`. Its `scripts` lay
over the installed game's only when their `smart.version` is higher. All three files find the installed game by
themselves (for the user, for all users, or an `OpenLF2` folder beside them) and the mod's ZIP beside them
(`xoi-hoc.bat` passes over the `*-xoi.zip` it makes; a ZIP dragged onto either is the one, handed to the background
processes in `PACK_DA_CHON`); `xoi-hoc.bat` keeps the trained ZIP's path in `xoi-<mod>\ban-mod.txt`, so dragging
that folder onto it merges and packs again. The files that run background processes start each as
`start "<title>" /MIN cmd /c call "<the .bat>" chay1 <words>`, with no other quotes: given a `.bat` and more than one
quoted pair, `start` hands the line to `cmd /k`, which drops its first and last quote, and the process never runs
where the folder has spaces. `windows/kiem-tra.bat` is for a PC where the game does not open: it writes into
`kiem-tra.txt` the installed game's build (x86, x64 or arm64, from its PE header), the graphics card, a `loadall` run
without a window, 15 seconds of a window with each renderer, and Windows' record of the game's crashes.
`dist/make-xoi-kit.sh` packs the `.bat` files with `scripts` and this folder as `xoi-kit.zip` (one folder,
`LF2-XOI-kit`), which the site publishes with its guide (`dist/pages/xoi.html`, English and Vietnamese) and "Upload
to latest release" attaches beside the Windows installers.

## Tuning INSANE!'s numbers (SPSA)

The judgement of the INSANE! player — what a hit is worth against what it costs, the score a move needs, how bold a
standoff makes it, how far to keep from longer arms or from a fallen enemy, when to charge MP — rests on 31 numbers
gathered in `smart.tune_ranges` at the top of `scripts/base/game/smart_ai.lua` (each with the range a tuning may try;
`smart.tune` holds the values in use, `smart.set_tune(values)` lays a set over them). `spsa.lua` tunes them by play,
the way chess engines tune theirs (SPSA: simultaneous perturbation stochastic approximation): each iteration nudges
every number at once by the same share of its range, each up or down at random, lets the numbers nudged one way
(`base/game/smart_ai`) fight those nudged the other way (a copy of the same file in this package as `spsa_alt.lua`) —
two games on one stage, each version playing each fighter of a random pair — and moves every number toward the
side that did better, by how much better (a win counts 1 and the HP left above the other's a share of 500).

```lua
-- one chain of 40 iterations from the AI's own numbers (spsa_alt.lua: a copy of scripts/base/game/smart_ai.lua)
{command = "spsa", step = "chain", iterations = 40, first = 0, total = 480, seed = 1}
-- the average of the chains' end numbers (spsa_chains.lua: return {{...}, {...}}), printed as "return {...} --SPSA_START"
{command = "spsa", step = "merge", chains = "spsa_chains", start = "spsa_start"}
-- tuned numbers (spsa_start.lua) against the AI's own: "SPSA_CHECK <tuned wins> <own wins> <draws> <result>"
{command = "spsa", step = "check", start = "spsa_start", games = 20, seed = 1}
```

The gains are shares of each number's range: `a` (0.02) for the steps, `c` (0.08) for the nudges, decaying as
`a / (total / 10 + k)^0.602` and `c / k^0.101`. A chain alone is noisy; many run side by side and their numbers are
averaged after every round, the next round starting from the average. `windows/spsa.bat` does all of it on a PC: one
chain per CPU thread, the mods beside it shared among the chains, 12 rounds of 40 game pairs, then the tuned
numbers against the AI's own; it writes `spsa\ket-qua.txt` and goes on from the round it was in when started again.
After each round it gives the round's minutes and about how long the rest will take (`spsa\thoi-gian.txt`), and the
check's result comes for each mod as well as in all. A pair takes a process about 1 to 2 seconds with LuaJIT (Naruto
2.4 1.0, OPLoS 2.1X 1.1, One Piece GrandWorld 1.7, KT-LF2 2.1; PUC Lua 2.5 to 5 times as long), and a process holds up
to about half a GB once it has met its mod's fighters (fewer chains on a PC short of memory: 0.6 GB each, 4 GB kept).
A chain still running at four times the time half of them took (and 10 minutes more) is stopped as stuck. In `spsa`
and `learn`, a game in which nobody loses HP for `stall` frames (1800, a minute; 0: never) ends there: a training
dummy that only stands kept its games to the time limit.
Tuned numbers are taken into the AI only after they beat its own over the usual measures (`duel` against the
previous version on the standard pairs of several mods).

## Jobs

Edit `config.lua` (a Lua table) and set `command` to one of these:

| command | what it does | fields |
| --- | --- | --- |
| `show` | A match to watch in the window (not headless): `brains` on the two fighter ids in `ids`, `games` games with the sides swapped every other game, the score on the status line; see "Watching a match". | `brains`, `ids`, `games`, `difficulty`, `background` |
| `learn` | Training for XOI (see "Training XOI"): `games` games of every pair in `pairs`, or of every two of `ids` (`"all"`: every fighter), both played by INSANE! (`brains`, default `{"smart", "smart"}`); prints `XOI` lines per pair as its games end. A game that fails is left out. | `pairs`, `ids`, `games`, `part`, `parts`, `brains`, `notes`, `difficulty`, `limit`, `verbose` |
| `duel` | AI against AI, `games` games per pair of fighter ids in `pairs` (or `ids`: every one against every other, each way round; `"all"` = every fighter, `part`/`parts` a share of those matchups; a game that fails is left out); the first fighter of a pair is played by `brains[1]` (`"smart"` is INSANE!, `"classic"` the original computer player at the match's `difficulty`, `-1` = CRAZY!/INSANE!). Prints each pair's score and a `TOTAL` line; with `usage`, the moves of each form too. | `pairs`, `brains`, `games`, `difficulty`, `limit` (frames per game, default 5400), `verbose` (one line per game), `usage` (every move INSANE! learned, with how often it started it), `stats` (N: damage dealt and taken by decision), `events` + `history` (every hit with both fighters' last decisions), `trace` (N: both fighters every N frames), `models` (after each game, what each fighter's opponent model counted: guards, hits, attacks and chances, falls and flips, jumps), `probe` (frames at which to print INSANE!'s view), `hash` (N: a per-frame line for the first N frames of the first game, for determinism checks), `audit` (an `AUDIT` line per brain at the end: blows started and landed, blows interrupted before landing — by a foe that was free when we started, or one already in a move —, hits taken from a foe just up from the ground, with the back to a wall, trades, what we were doing when hit, and the moves INSANE! set aside because a threat or counter met their path; `exclusions = true` logs each of those), `no_ego`, `no_prepare`, `nobrain` |
| `stall` | Stretches of a match in which neither fighter loses HP for `quiet` frames (default 300) — two computer players stuck in a loop, such as a trap cast again and again on an opponent already held (Yamato in Naruto 2.4 before version 27): where each began, how many frames went so, and what each computer player was doing meanwhile. | `pairs`, `games`, `brains`, `notes`, `quiet`, `show`, `difficulty`, `limit` |
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
| `still` | INSANE! fighter `ids[1]` against `ids[2]` standing still (no computer player) `far` apart, logging both every `every` frames and whenever the still one's frame changes: what the AI does to a fighter that cannot answer. `handover` plays `seq` (as `keyseq`) on the INSANE! fighter first, then hands it to the AI; `spawn = {id, frame, dx}` places an object of the mod on the still fighter (a trap set by hand). | `ids`, `far`, `dz`, `ticks`, `every`, `handover`, `seq`, `spawn` |
| `loadall` | Loads every object of the mod as a match would and reports what fails. | `diagnostics` |
| `aitest` | Checks that a mod's own AI scripts (`ai/*.as`) compile and make instances. | `ids`, `other` |
| `spsa` | Tunes INSANE!'s numbers by play (above): a chain of iterations, the average of chains, or tuned numbers against the AI's own. | `step`, `iterations`, `first`, `total`, `seed`, `start`, `chains`, `games`, `a`, `c`, `names`, `ids`, `limit` |

Fighter ids are those of the mod's `data.txt`. `moves` and `duel` with `usage = true` together show what the AI knows
about a fighter and what it actually uses; a move it never starts has a reason worth finding (too slow for the
situations that arise, never within reach, a stance whose exit key it does not press...).

## Reading the AI

`scripts/base/game/smart_ai.lua` is one file, in this order: learning (`analyze`, `play`, `measure_hit`, the
sandbox), geometry (`predict`, `move_hits`), threats (`earliest_threat`), choosing (`can_start`, `worth`,
`attack_score`, `best_attack`, `approach_attack`, `answer`), and the per-frame `smart.control`. `smart.levels`
holds the levels' reaction times. The debugging hooks `smart.trace`, `smart.on_start` (the move started, and for an
attack when it should land and its score), `smart.watch` and `smart.internals` are what the jobs above use;
`smart.note_key`, `smart.pair_notes` and `smart.use_notes` are XOI's notes.
