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
| `duel` | AI against AI, `games` games per pair of fighter ids in `pairs`; the first fighter of a pair is played by `brains[1]` (`"smart"` is INSANE!, `"classic"` the original computer player at the match's `difficulty`, `-1` = CRAZY!/INSANE!). Prints each pair's score and a `TOTAL` line. | `pairs`, `brains`, `games`, `difficulty`, `limit` (frames per game, default 5400), `verbose` (one line per game), `usage` (every move INSANE! learned, with how often it started it), `stats` (N: damage dealt and taken by decision), `events` + `history` (every hit with both fighters' last decisions), `trace` (N: both fighters every N frames), `probe` (frames at which to print INSANE!'s view), `hash` (N: a per-frame line for the first N frames of the first game, for determinism checks), `no_ego`, `no_prepare`, `nobrain` |
| `moves` | What INSANE! learned about the fighters in `only` (`{[id] = true}`): every move with its start, first and last hit, recovery, MP, damage and reach. | `only` |
| `timing` | How many moves, entries and sandbox plays the learning of each fighter in `only` takes. | `only`, `cap` |
| `frames` | The chosen `frames` of fighter `id`: state, wait, next, bodies, attacks, hit_* fields. | `id`, `frames` |
| `dump` | A summary of every fighter's combos, basic attacks and guard (`only` narrows it). | `only` |
| `settle` | The frames a fighter passes through from the start with no input, or with `press` held. | `id`, `other`, `ticks`, `press` |
| `mpcheck` | Puts fighter `id` into `frame` with `mp` and prints its MP as the frames run (charging moves). With `press` (a key name) and `press_at`, presses that key from that frame on. | `id`, `frame`, `mp`, `ticks`, `every`, `press`, `press_at`, `other` |
| `watch` | Plays one learning entry of fighter `id` with a frame-by-frame log of the fighter and what it spawns. | `id`, `entry`, `from`, `to`, `full` |
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

---

**Tiếng Việt.** Thư mục này là một gói mod biến OpenLF2 thành bộ chạy thử cho máy chơi INSANE!
(`scripts/base/game/smart_ai.lua`): thay menu bằng một "job" đọc từ `config.lua`, chạy ngay khung hình đầu và in ra
log của game; `--input-trace ""` chạy không cần cửa sổ. Lệnh mẫu ở trên: `duel` cho INSANE! đấu máy gốc hàng loạt,
`moves` in bảng chiêu máy đã học, `usage = true` cho biết chiêu nào máy thật sự dùng, `replaytest` kiểm tra tính
xác định (phải in SAME). `--seed` cố định số ngẫu nhiên để lặp lại y hệt; `--scripts <thư mục>` để so sánh hai
phiên bản của tệp AI.
