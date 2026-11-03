# Changelog

All notable changes to this project are documented in this file.

## [Unreleased]

LF2 Online, Xôi's build of OpenLF2 (<https://anmen5000.github.io/OpenLF2/>). The INSANE! computer
player's own version numbers (shown in the game as "INSANE! vN" and on the site's INSANE! page) are
`smart.version` in `scripts/base/game/smart_ai.lua`.

### Added
- INSANE!, a fifth computer-player level above CRAZY! (`scripts/base/game/smart_ai.lua`): learns every fighter's
  moves from the game's or mod's data in a private copy of the match before it starts, then fights by prediction;
  selectable in the character selection, Tournament and Battle mode; fighters whose mod ships a substantial AI
  script keep that script (v14)
- INSANE!: stances and charging moves, defend keys that are moves, moves that start from walking, get-up
  invulnerability, running, obstacles, no guarding into a guard break (v15)
- INSANE!: the whole kit — jumping in and dashing in with air moves, slow specials while the target is held,
  MP charging, striking out of the guard, leaving stances in time, flipping up or staying down by the blows on
  their way (v16)
- INSANE!: an opponent model counted from the match state — guard rate, how pressing the opponent is, whether it
  flips up — that changes the choice of moves, the spacing and the timing; the busy and the weak are preferred
  among several enemies (v19)
- INSANE!: weapons (walks onto a lying knife, stick, stone or drink when nothing presses, learns the fighter's
  moves with it in hand and swings, throws or drinks accordingly), moves that teleport to the enemy aimed from
  where they land, the second fighter of a pair going round to the other side, passive opponents walked up to and
  struck; the level's version is shown in the match and on the site (v20)
- INSANE!: forms of a mod's own making — a move that leaves an item in the fighter's hand (Gear Second, Diable
  Jambe, a Rasengan formed) is learned as a form with its own moves, runs, MP burn and worth, entered when worth it
  and safe, fought in and let run out away from the enemy; a fallen or just-risen, invulnerable opponent is kept
  outside arm's reach until a blow can land again (v21)
- INSANE!: approaches an opponent whose long blows cover the line between them beside that line, in depth; knows
  an opponent held by a trap (an object's hold) to be held and hittable, strikes it or charges MP for a strong move
  first while the hold lasts; weapons worth fewer steps when MP is full (v22)
- INSANE!: keeps out of a fallen or just-risen opponent's wake-up blows — its quick moves, however far they
  reach — until its blink ends, leaving in depth or back out of reach and waiting off its line; no charging,
  drinking or weapon pick-up in that zone; the opponent's quickest counter weighed along a rush's or a jump-in's
  own path; an opponent in a charge stance known to be free as soon as it can leave it; the frame a move's spawn
  appears counted as a threat; a blow landing as the own blink ends answered; trades struck first only when
  clearly heavier (v23)
- INSANE!: a blow the opponent's quicker answer could beat on its way is weighed, not forbidden — what it brings
  against the answer's damage times how often this opponent has struck such a blow first in the match so far,
  counted in the match from a hopeful start; Rock Lee no longer stands off Neji in Naruto: The Setting Dawn (v24)
- INSANE!: out of the way with a move of its own when no step gets there — a teleport, a rush or a leap whose path
  no blow on its way meets (Kuma of One Piece GrandWorld vanishes behind the enemy; keys a mod's jump takes are
  learned as moves) — against a blow the guard cannot hold, a heavy one with MP to spare, or when it strikes back;
  teleports reckoned to land where the game puts them, behind the enemy when the move turns the fighter round (v25)
- XOI, a sixth computer-player level after INSANE! (experimental): INSANE! with notes of training shipped in the
  mod's ZIP file (`xoi/notes.txt`) — each move weighed by what it brought against this opponent in many games —
  written by `tools/ai-bench`'s new `learn` job; `tools/ai-bench/windows/xoi-hoc.bat` trains on every processor of
  a Windows machine and packs the notes into a copy of the mod's ZIP file; `dau-nhieu.bat` runs duels the same way,
  by default every fighter against every other with each brain on each side, and prints each fighter's win rate
  (both use the installed game with the package's scripts, so it need not be reinstalled); `duel` takes `ids`
  (`"all"`), `part`/`parts`, and leaves out a game that fails; the bench's `xoi` brain, `smart.on_start` with the
  attack's expected landing and score (v25)
- INSANE!/XOI: steady footwork — a turn round is a step too, so no more turning left and right on the spot at
  the edge of a distance, of an enemy's quick blows or of a fallen enemy's wake-up blows (worst for fast walkers,
  most seen at low MP); a way out once chosen is kept and walking turns the fighter round at most once every few
  frames. A wave sent along the ground across the stage (Neji's air palm in Naruto 2.4) is reckoned all the way
  out: its line is walked beside even while the opponent charges MP or is busy for a moment, and a run is not
  steered back onto it while a wave flies along it (v26)
- INSANE!/XOI: untouchable forms — a body kept only on a far layer (1000 and more off the visible one, a mod's own
  interactions) is out of reach of every blow but those aimed at that layer, reckoned for each opponent: a form whose
  frames are all out there (Drake's T-rex, Magellan's Venom Demon in One Piece GrandWorld) is worth entering for that
  alone and is fought in up close, its own run or creeping walk steered onto the opponent's line and stopped with its
  own key; a form entered from the guard no longer loses its key at the guard's first frame (Magellan never got in);
  a move that restores HP (Marco's phoenix, state 1700) is measured with HP missing and used when much lost HP can
  come back and nothing reaches the fighter meanwhile; the roll out of a run is learned with what follows it (Marco's
  phoenix flight) and a flight that steers in depth is flown onto the target's line. A grab is worth what follows it
  (measured) and is no blow to guard; a trap is never set again on an opponent already held — Yamato's wood prison,
  cast on and on from afar in Naruto 2.4, kept both fighters standing for the rest of a match — and the held opponent
  is walked up to and struck; short of MP with a charge of its own, the fighter backs off far enough to charge rather
  than waiting at the edge of the opponent's reach (v27)
- XOI: notes by situation — what the opponent was doing, how far it was, whether the fighter's own HP had run low
  (`XOI C` lines) — and by spot, where the fighter stood with both fighters free and what the 45 frames after brought
  (`XOI P` lines); used within narrow bounds (measured as strong as the moves' weights alone, 158–153 over 320 games);
  notes made before have neither and play as before; the bench's `xoi:m`, `xoi:c` and `xoi:p` brains play with the
  moves' weights alone, with the situations, with the spots (v27)
- INSANE!: the 31 numbers its judgement rests on — what a hit is worth against what it costs, the score a move
  needs, how bold a standoff makes it, how far to keep from longer arms or from a fallen enemy, when to charge MP —
  gathered in `smart.tune_ranges` (with the range a tuning may try; `smart.set_tune` lays a tuned set over them; the
  values are unchanged and play is the same frame for frame), and tuning them by play: the bench's `spsa` job (SPSA,
  as chess engines tune their numbers: two versions with every number nudged opposite ways fight, and the numbers
  move toward the better one; chains averaged between rounds; tuned numbers against the AI's own) and the kit's
  `spsa.bat`, which runs it on every thread of a PC over the mods beside it, round after round, resumable; it says
  how long each round took and about how long the rest will take (also kept in `spsa\thoi-gian.txt`), gives the
  check's result for each mod as well as in all, and runs fewer processes than CPU threads on a PC short of memory
  (about 0.6 GB a process at most, 4 GB kept for Windows); a process still running at twice the time half of them
  took (and at least 5 minutes more) is taken as stuck and stopped, the round going on without it. Its rounds are
  minutes long (`VONG` rounds of `PHUT_VONG` minutes, the check `PHUT_KIEM_TRA` minutes), the chains stopping
  together by the engine's clock instead of after a fixed number of game pairs — which had left the chains on a fast
  mod idle while those on a slow one finished — and merged by their mean step per pair, every mod weighing the same;
  a round stopped half way keeps what its chains had reported when started again; the processes run at below-normal
  priority (`UU_TIEN`), so the PC stays usable
- AI bench: a game of the `spsa` and `learn` jobs in which nobody loses HP for a minute (`stall`, 1800 frames) ends
  there, scored as at the time limit — a mod's training dummy that only stands (One Piece GrandWorld's Dummy, OPLoS's
  TrainingBot) kept every game of its pairs to the limit, so the XOI training window with those pairs finished long
  after the others; other games are untouched (Naruto 2.4 training and tuning frame for frame the same)
- INSANE!/XOI v29: the 31 numbers of its judgement tuned by play (SPSA, `spsa.bat`): 40 rounds on the project
  owner's 99 threads over the original LF2, Naruto 2.4 and One Piece GrandWorld, about 850,000 pairs of games. A
  little bolder — a strike out of the opponent's guard, a counter while still busy and a frame left open after a blow
  reckoned cheaper (guard_counter 0.5 to 0.35, counter_price 0.7 to 0.57, open_cost 0.2 to 0.12), trades taken sooner
  (trade_factor 1.3 to 1.14) — and surer: a hit on a target long free to act trusted less (sure_decay 0.04 to 0.052),
  MP held dearer (mp_cost 0.06 to 0.073), waiting a little nearer (keep_out_base 30 to 26). Against v28: 52.0% of the
  76,286 games of the tuning's own check won by either (±0.4%; the original LF2 52.8%, Naruto 51.2%, One Piece
  51.2%); 297–311 over the standard 8 pairs of Naruto 2.4 and One Piece GrandWorld (640 games, too few to tell 2% either
  way); against CRAZY! 150–9 over the four mods' benchmark, v28 153–6 on the same games (within chance)
- INSANE!/XOI v31: the numbers tuned by play are XOI's alone, so that the last level is plainly stronger than the
  one before it (the project owner's wish). INSANE! plays with its 31 numbers set by hand again, as up to v28;
  XOI with v29's tuned set (`smart.xoi_tune`), and in a mod with numbers of its own (`xoi/tune.txt`, `spsa.bat`'s)
  with those laid over it — INSANE! no longer reads a mod's numbers, and the match shows *mod tuned* beside XOI
  only. Each computer player decides with its level's numbers, also two levels in one bench match. `spsa.bat` and
  `spsa.lua` tune XOI's numbers: they start from XOI's own and check against them
- Network play in the browser: the corner of the game also shows how busy each computer is (`busy`: the longest
  the page stalled in the last 5 seconds; `host busy` / `player busy` for the other side, which tells it every
  2 seconds), and the Online panel has **Copy network report**: the network's last minute as text (ping, jitter,
  busy, the beat's lateness, each link's round trips and version, the frames' lateness per second, the page's
  stalls), for a bug report. Hero Fighter's bottom line shows `busy` and `other busy` too
- Hero Fighter: a computer too slow for its fight (a Battle with many soldiers) slows the room down much less. The
  games of a room run every frame together, so the slowest sets everyone's pace; now, when its game is more than
  100 ms behind and its own frames take longer than 33 ms (the game's timings of its last frame and last
  drawing), it draws every other frame until it catches up — the fight itself still runs every frame, the same on
  every computer. It is the game's own frame skip, which its author left switched off (both branches of the
  frame loop set `skipI` to 0); `dist/pages/hero-fighter.js` changes those bytes of the loop to "behind and slow:
  draw every other frame" in as many bytes. A computer that is only behind because it waits for a slower one
  draws every frame, as before. Two Chromium pages too slow for their Battles (four kingdoms, Crazy): 5.0 frames a
  second this way against 2.5–2.9 drawing every frame, the pages swapped as well; a page that never drew and one
  drawing every other frame stayed in step for 1,880 frames of a Battle (the same count of random numbers every
  20 frames, 87,319 at the end). `hfskip=0` in the page's address leaves the game as it was
- The game page: a note under the status when the browser draws without the graphics card (WebGL by SwiftShader,
  llvmpipe or Windows' Basic Render Driver, or no WebGL at all — hardware acceleration off, or a graphics card the
  browser does not use): both games run slowly and Hero Fighter's battles most, as Ruffle waits for every picture
  its game reads back; the note says how to turn hardware acceleration on (in English and Vietnamese). The
  renderer is also in Diagnostic output and in the network report
- Network play in the browser: the network in a corner of the game while in a room — the ping to whoever keeps the
  beat (the relay, or the host's page: on the host's page its slowest player's), which way the frames come (`direct`
  or `relay`), how unevenly the frames of the last 5 seconds came (`jitter`, ms between the earliest and the latest,
  beat for beat; orange from 100 ms) and, when it is more than half a second, how far behind the newest frame the
  game runs (`behind`); for Hero Fighter the ping and the way, at the bottom in the middle (its own panels take
  the corners). The relay is timed in every room now, also without direct connections
- Hero Fighter rooms: direct links between the players' pages (`dist/pages/hf-direct.js`). The game's socket is the
  page's own object: it talks to the relay as before (the relay stays the room's server and passes every frame on)
  and besides passes the game's frames straight to the other pages of the fight over WebRTC, the game taking each
  other game's frame once and in order from whichever way brings it first, and never one of another fight (the relay
  numbers the fights, `{"t":"fight"}`, and announces who is in the room, `{"t":"peers"}`). On one LAN a frame takes
  a millisecond or two instead of the way to the relay and back. A link that never opens or breaks only means the
  frames come the usual way. The page shows the links under the game (`Network: direct links: …`, and after a fight
  how many frames came directly); the room's journal has the links of each fight and those counts.
  `?hfdirect=0` plays through the relay only
- Network play in the browser: direct connections. The game pages of a room also connect to the host's page
  directly (WebRTC data channels, set up through the relay; public STUN servers for players on different
  networks) and time both ways; when every player reaches the host directly, none more than 10 ms later than
  through the relay, and the round trips add up to less, the host's page keeps the beat itself from START by the
  relay's rules (in a worker, so a hidden tab does not slow it): players on one LAN play with a few milliseconds
  between them instead of the way to the relay and back. Otherwise (a proxy, a network that allows no direct
  connection, an older page) the relay keeps the beat as before; the Online panel shows which, with the times.
  Rooms of up to 8 players as before. The relay passes the set-ups on (`{"t":"signal"}`), answers pings, and leaves
  the beat to the host's page when told (installer version 11); the game itself is unchanged
- INSANE!/XOI v30: no endless loops. A standoff with no blow between the two fighters for 300 frames free to act
  (`loop_calm`, ten seconds and more) is taken for a loop, and then: a move tried again and again since the last
  blow, all to no avail, is worth less with every try beyond three (`loop_free`, `loop_factor`, at least `loop_floor`
  of its worth; its tries count with those of its family — how it starts and from where, whatever it continues into —
  and one is forgotten every five seconds it is not tried, `loop_forget`), so something else gets its turn; no spot
  is left for the enemy's blows any more, so one of the two comes in; and a thrower that has kept the fighter dodging
  four times (`loop_dodges`) is jumped toward over its throws, when that jump clears them and lands outside its arms.
  Before that, play is as in v29. Itachi's fireballs met Sai's ink birds for good in Naruto: The Setting Dawn (a game
  played to its five-minute limit, 8,458 frames without a blow), and Gaara jumped Itachi's kunai on the spot for good.
  A heavy item in hand (a stone, a log) is thrown, landing or not, once the target comes within its quick reach and
  `heavy_room` (40) more: holding it the fighter can neither guard, jump nor strike, and Kakashi with a stone and Gaara
  with a log stood face to face at a wall for good. And a fighter too close to its target at a wall no longer steps
  back to the wall and turns round again every few frames (once walled, walled on that side for a second).
  Against v29 on the standard 8 pairs of Naruto 2.4 and One Piece GrandWorld (two seeds, 640 games): 299–308
  (Naruto 152–161, One Piece 147–147), as even as that many games can tell (±4%); over Itachi's 48 games against
  every fighter of Naruto 2.4, the frames spent in standoffs beyond ten seconds fell from 8,890 to 2,058 and no game
  ran out of time (one had). A first try that weighed the tries from the start of a match, without waiting for a
  standoff, lost 209–233 on the same pairs: loops are rare, and play changes only once one is sure
- INSANE!: 46 more numbers open to tuning by play, 77 in all — the 39 written into the code by hand until then
  (how a free target's guard is expected, what knocking down, breaking a guard, freezing or burning add to a blow,
  how far ahead blows on their way are answered and when the guard is raised, the margins of dodges, when an
  opponent counts as passive, how dangerous a spot within an enemy's blows is, the distance kept, when a run starts
  and stops, flips, charging, weapons, forms) keep their values, the same play frame for frame on Naruto 2.4, One
  Piece GrandWorld, OPLoS and KT; and the seven of the loops and heavy items above
- INSANE!/XOI: a mod's own numbers — `xoi/tune.txt` beside its data ("name = value", as `spsa.bat` writes them),
  laid over the AI's own in every match of that mod, the same on every machine of a network room; a mod without it
  plays with the AI's own; the match shows "mod tuned" beside the level. The bench's tuning keeps the numbers its
  own (`smart.tune_fixed`)
- XOI kit: `spsa.bat` writes each mod's tuned numbers to `xoi-<mod>\tune.txt` and packs `<mod>-xoi.zip`, the mod with
  `xoi/tune.txt` (and XOI's notes, if trained) inside, the one before kept as `<mod>-xoi-truoc.zip`; with one mod
  beside it, a run starts from that mod's numbers, and its check plays the tuned numbers against the numbers it
  started from (the bench's `spsa` check: `base`); `xoi-hoc.bat` keeps a mod's tuned numbers in the packages it makes
- INSANE!/XOI: keeps its distance from a fallen enemy, on shallow stages too — the room to step off the enemy's line
  is counted from that line (counted from the fighter, it shrank with every step, and on a stage 60 deep the side
  flipped every few steps: Rock Lee walked to and fro on a fallen Neji's line on Hot Springs until he got up), the
  frames to get there count crossing the line, and the step in depth the enemy can take once up is reckoned while it
  is still down (reckoned only once it was up, a fighter just off its line was inside its blows again as it rose;
  with no room for that depth, the fighter now backs out of reach); blows taken from enemies just up again on three
  shallow stages of Naruto 2.4: 2,485 damage instead of 3,511; against v27, 160–148 in Naruto 2.4 and 152–145 in
  One Piece GrandWorld; waiting out of the enemy's plain arms at any depth was tried and dropped (fewer such blows,
  but 136–168 against v27 in Naruto) (v28)
- INSANE! and XOI on a PC (a mod's own `.exe` is the original LF2 and stops at CRAZY!): `tools/ai-bench/windows/choi.bat`
  plays a mod on the installed Windows game — the mod's ZIP, its folder (zipped once) or its `.exe` dragged onto it,
  with a notes file packed into `<mod>-xoi.zip` — laying the kit's newer scripts over the installed game's; the
  XOI kit (`xoi-kit.zip`: the three `.bat` files, `scripts`, `tools/ai-bench`, built by `dist/make-xoi-kit.sh`) and
  its step-by-step guide in English and Vietnamese (`dist/pages/xoi.html`: files, setup, playing, training,
  measuring, sharing, troubleshooting) are published with the site; "Upload to latest release" can make the release
  first (`tag`) and attaches the kit beside the Windows installers
- `xoi-hoc.bat` and `dau-nhieu.bat` find the installed game and the mod's ZIP beside them by themselves and take a
  ZIP dragged onto them; dragging `xoi-<mod>` onto `xoi-hoc.bat` merges and packs that mod again (the trained ZIP's
  path is kept in `xoi-<mod>\ban-mod.txt`)
- `tools/ai-bench/windows/dau-nhieu.bat`: each fighter's win rate when played by the first brain and when played
  by the second, and the difference (the first alone mixed the fighter's strength into the AI's)
- `tools/ai-bench`: each computer player of a `duel` keeps its own context (they shared one, which skewed matches
  between versions that read the fighters' moves differently); versions before 20 are named so instead of `vnil`
- `tools/ai-bench`: `duel` with `audit = true` counts, per computer player, blows started, landed and
  interrupted (by a foe that was free, or one already in a move), hits taken from a just-risen opponent or at a
  wall, trades, what the fighter was doing when hit, and the moves set aside because a threat or counter met
  their path
- `tools/ai-bench`: two computer players against each other (`brains = {"smart", "smart@ai_alt"}`), `ai_template.lua`
  as the shape of a player of one's own, the `still` job (a fighter that cannot answer, a trap placed by hand)
- The relay keeps a journal of each Hero Fighter room (joins with build and address, fights started, pauses,
  leaves, timeouts, and every out-of-step check with the frames and keys around it), readable from the admin page
  (`GET /admin/api/hf-journal`), to find the cause of a desync reported by players
- `tools/ai-bench/`: a mod package that runs INSANE! against the original computer player in bulk (`duel`), lists
  what it learned (`moves`), checks determinism (`replaytest`) and weapon handling (`weapontest`), and more
- The site (`dist/pages/`): the start page with the mod library and network rooms, the INSANE! page
  (`insane.html`, with the AI's version and history read from the build), the Windows emulator page for mods
  OpenLF2 cannot run (`windows.html`, `dist/boxedwine/`), the Hero Fighter page; built and published by the
  WebAssembly workflow on every push to `main`
- The relay server for network rooms and the mod library (`tools/relay/`), with a one-command installer for a
  Linux server
- Sx2's interface pictures; game packs up to 256 MiB

### Fixed
- Network play in the browser, direct (the host keeping the beat): the players' games no longer stutter while
  the host's plays smoothly. The beat ran on the host's page's main thread, after whatever the page was busy
  with (the game's own frame, the computer players' thinking, a garbage collection): every stall of the host's
  page came to the players as a late frame, then a burst (seen as `jitter` rising on the player's corner while
  the ping stayed at 1 ms). Now, in browsers that hand WebRTC data channels to a worker (Chrome, Edge), the
  host's page gives each player's channels to a worker that keeps the beat, answers pings and takes inputs
  there, unaffected by the page; the page only signals the links and mirrors their state. And every game's
  pacing (`room.lua`) follows the latest frame of the last ten seconds instead of the 90th percentile of the last
  three, so a rare late frame no longer shows as a hitch (with a host whose beat ran 40–80 ms late once in 25:
  20 hitches in 500 frames before, 0 now), with the page noting each frame's arrival for it (`KIND.stamp`,
  so the game's own frame time no longer blurs the measurement). Pings go over the datagram channel, where a
  lost packet cannot hold them up, and both sides ping, so the host's corner shows a real ping
- Mods: a spawned object sent to a frame its file does not have no longer stays for the rest of the match
  (invisible and inert, holding one of the 400 object slots). One Piece GrandWorld's Enel, lying, spawns
  enel_ball frame 112, which does not exist: in a long Survival stage that filled every slot in four minutes
  (308 of them), after which no move could spawn anything — Ace's and Marco's attacks lost their effects and
  did no damage. The original keeps such objects; here they are removed
 between the pages (as on
  Wi-Fi) no longer holds the other players' game up. A lost packet on WebRTC's reliable channel held up everything
  after it until it was sent again, a quarter of a second or more (longer on Wi-Fi), then the frames came at once: the
  players saw the host's moves late, then fast. Version 2 links (both pages say so on the link) number the game's
  messages and send each also on a second channel that never sends again what was lost, with the 7 before it, so
  a lost one comes with the next, 33 ms later. With 3% of packets lost (two Chromium pages): the longest wait for a
  frame 268 ms before, 67 ms now; 99% of frames within 110 ms of their time before, 10 ms now
- Hero Fighter rooms: a fight in Battle mode no longer goes out of step when a player who plays as player 2 (no
  player 1 on that computer, as with the W A S D keys) hires a hero: the game reads player 2's hire number from
  `<n1>` (a slip in its Console.receiveData), so every other game hired the first hero on the list instead of the
  one chosen; the relay (and the pages, for direct frames) put that number in `<n1>` too. And a game's frames go on
  to the others as its packet comes, up to 10 ms sooner than the original's 10 ms rounds
 (and every screen with the character list) no longer stop at a black screen on a
  `data/data.txt` that the original reads although its object list is untidy — the list is read as the original reads
  it, word by word, each `id:` with the five words after it whatever the two keywords say, any other word passed
  over (the One Piece mod OPLoS 2.1X, `OPLoS2.1X.exe`, has `fileb:` for `file:` in one record and lines holding a
  lone `%`, `$`, `&` or `*`); and 16-bit pictures (5-5-5, or BI_BITFIELDS masks such as 5-6-5) are drawn, read as 24-bit ones — the
  same mod has two among a stage's layers (`bg/sys/kf/land3.bmp`, `land4.bmp`)
- Windows: a game window that stayed the menu's blue with no picture or text (SDL's GPU renderer, the first one tried,
  opened without an error on the project owner's PC and drew only fills): on Windows the game now tries a renderer
  once as it opens it — a red test picture, opaque and colour-keyed, drawn into the window, into a frame texture and
  through xBRZ, each read back — and passes over one whose pictures do not show (then OpenGL, SDL's default and at
  last the software renderer), or leaves out an xBRZ upscaler that shows nothing; a read SDL cannot make counts as
  shown. `choi.bat` draws with OpenGL unless its `VE` line names a renderer, and starts the game again with its
  usual renderer when OpenGL does not open
- Windows x86 (32-bit) build: the game closed at once, before its window showed (Windows logged 0xc0000409, its
  stack check), wherever it drew with OpenGL — `choi.bat`'s renderer, and the next one tried after a GPU renderer
  that shows nothing: the xBRZ upscaler called OpenGL through plain function pointers, while OpenGL's functions on
  32-bit Windows use the stdcall convention, so each call left the stack off by its arguments. The pointers now
  carry the convention (`OPENLF2_GL_CALL` in `src/adapters/sdl/gl_upscaler.cpp`); x64, arm64 and the other
  platforms have only one
- XOI kit: `spsa.bat` started its processes as `start "…" "spsa.bat" chay1 "<folder>" …`, a line Windows hands to
  `cmd /k`, which drops its first and last quote when it holds more than one pair — so no process ran (in the
  project owner's `D:\…\AI arena` as anywhere) and the tuning stopped at its first round. `spsa.bat`, and to be
  safe in folders with brackets `xoi-hoc.bat` and `dau-nhieu.bat`, now start them as
  `cmd /c call "<the .bat>" <words without quotes>`. `choi.bat` takes any exit code but 0 for a failure — a crash's
  is negative, which `if errorlevel 1` missed, so its window closed without a word — and the kit gains
  `kiem-tra.bat`, which writes why the game does not open on a PC into `kiem-tra.txt` (the game file's build, the
  graphics card, a run without a window, a window with each renderer, Windows' own record of the game's crashes)
- Builds: `dist/collect-licenses.py` tries a dropped or stalled download of a license source again (after 15, 30,
  60 and 120 seconds) instead of failing the build — GitHub's Windows arm64 runner lost ffmpeg.org's archive in the
  last three Windows runs, which marked them failed although x86 and x64 had built

## [1.1.2] - 2026-10-26

### Changed
- The web version can be played directly: the original game is downloaded when you press play, no manual download needed

### Fixed
- Fusion: a fighter merges with at most one partner per frame, as in the original game
- Stage change: followers that have already left still count toward the limit of two per group, as in the original game

## [1.1.1] - 2026-10-18

### Added
- A fast-forward button in the top left corner of the on-screen gamepad, like the pause button on the right (it is F5)
- Escape or the back button during a fight asks "Leave the fight?" (a dialog like the exit question) and leaves like F4 on confirmation

### Changed
- Fast-forward always overlaps the simulation with rendering, whatever the draw time

### Fixed
- Typing into text fields (names, recording info, network address) on Android and iOS: Backspace and Enter taps of the soft keyboard are no longer lost, and typed characters keep their case
- Android: coming back to the app no longer leaves a black screen: the renderer is opened anew once the window surface is back (also after a lost graphics device on other platforms)

## [1.1.0] - 2026-10-17

### Added
- Windows installer (Inno Setup, English, German, Chinese) replaces the zip: optional download of the original game installer, `.lfr` file type registration, Start menu entry and uninstaller
- Language option (default, english, chinese, german): translated text is drawn with bundled TrueType fonts through SDL3_ttf, rendered once per text and cached; the default language keeps the bitmap font
- Font antialiasing option, shown when a translated language is selected
- Translation system for scripts (`i18n.tr`, one module per language) and a text draw command for the host
- Translated languages also replace the text baked into the original's menu bitmaps; `english` shows only the English part of the original's bilingual strings
- The open-file dialog for recordings, the desktop entry, the AppStream metadata and the MIME type description are translated (German, Traditional Chinese)
- Alt+Enter switches between fullscreen and window at any time (also in the setup dialogs), without any other action

### Changed
- The summary screen ends with a fresh attack or jump press of any player or a controller's south button, like the demo, so it also works in replays
- A window that leaves the maximized or fullscreen state returns to the original resolution instead of its previous size
- Without `--renderer`, xBRZ upscaling is looked for in the SDL_GPU renderer, then in OpenGL, before settling for the system's default renderer, so it is offered on Windows machines whose GPU renderer cannot run it
- Automatically overlap live simulation with rendering when the frame budget is exceeded, returning to current-frame rendering when there is enough headroom; fall back to synchronous execution when threads are unavailable
- Reduced Lua/C++ frame overhead by sending drawing, audio and control commands in one typed opcode batch
- Reduced sound scaling work with a bounded cache of volume/pan variants and faster sample rounding

## [1.0.0] - 2026-10-17

### Added
- Drag and drop `.lfr` recordings onto the launch or title menu to play them
- Open `.lfr` recordings directly from the command line or Linux file managers, with file type registration; F4 or leaving the result screen closes the application when opened this way
- Support for the alternative `lf2_v20a_Setup.exe` installer in native and browser builds, with SHA-256 verification and automatic discovery in the configuration directory
- Exit confirmation on Escape or Android's back button, controllable with keyboard, gamepad, mouse and touch
- Links to the original authors' sites in the launch menu credits
- HP bar flash while healing and remaining-lives labels above enemies, as in the original
- Demo can be ended at any time with attack from any controller or the on-screen controls

### Changed
- Reduced simulation work in crowded fights by skipping impossible collision pairs while preserving hit order and cooldown timing
- Reduced sound playback processing by reusing scaled audio buffers and bypassing scaling when no volume or pan adjustment is needed
- The expanded battlefield scrolls a window of the full screen width across the stage or the open stage section, so the stage edge is the screen edge; backgrounds continue past their pictures without scaling
- Web build uses SDL 3.4 and follows the screen size when entering fullscreen or rotating a phone
- Credits are shown on four lines
- Text colours of the scoreboard, stage and battle status lines, recording and volume messages, battle setup and control settings match the original; battle strategy lines use the team fonts

### Fixed
- Letterbox bars painted black over the picture's colours and the on-screen controls on the web
- Team order markers drawn away from the player in the expanded battlefield
- Status and text under bosses and the Stage mode scoreboard result

## [0.9.4] - 2026-10-12

### Added
- Subtle version and Git revision label on the launch menu

### Changed
- Reduced CPU work and allocations in battle simulation, collision detection, AI and rendering snapshots

### Fixed
- Weapon targeting after its holder is removed, preserving original replay behavior
- Julian and Firzen MP regeneration when HP is negative
- Stage reserve lives for recruited allies when all players are defeated
- Projectiles and effects drawing outside the battlefield

## [0.9.3] - 2026-10-11

### Added
- Optional expanded battlefield layout with support for parallax backgrounds
- Desktop window size, position and maximized state are saved and restored before showing the window; Wayland controls positioning

### Changed
- Semi-transparent on-screen controls, with no overlapping diagonal highlights on the digipad
- Options menu adjusts its layout to the available settings
- High-density rendering enabled across platforms
- Updated credits, website links and development notice
- TLS certificate verification disabled for installer downloads; installer SHA-256 verification remains enabled

### Fixed
- Keyboard and gamepad access to website links and the recording folder
- Recording help and special move links
- iOS pause button in widescreen, info bar and application exit
- Template background loading with incomplete BMP palettes
- Compiler signedness warnings; compiler warnings are now treated as errors

## [0.9.2] - 2026-10-10

### Fixed
- Black sprites with the OpenGL ES renderer
- On-screen gamepad is now also hidden when mouse force mode is active
- Launch script for ROCKNIX

## [0.9.1] - 2026-10-02

### Added
- On-screen gamepad (digipad): configurable, drawn as an overlay (also in the letterboxed area), enabled by default and larger
- On-screen special buttons and a pause button
- Touch tolerance for on-screen controls
- Support for multiple screen orientations
- Flatpak packaging
- Portmaster build

### Changed
- Linear filter is now the default (and fixed)
- All options are now shown in the config

## [0.9.0] - 2026-09-28

- Initial release
