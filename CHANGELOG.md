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
- Windows: a game window that stayed the menu's blue with no picture or text (SDL's GPU renderer, the first one tried,
  opened without an error on the project owner's PC and drew only fills): on Windows the game now tries a renderer
  once as it opens it — a red test picture, opaque and colour-keyed, drawn into the window, into a frame texture and
  through xBRZ, each read back — and passes over one whose pictures do not show (then OpenGL, SDL's default and at
  last the software renderer), or leaves out an xBRZ upscaler that shows nothing; a read SDL cannot make counts as
  shown. `choi.bat` draws with OpenGL unless its `VE` line names a renderer, and starts the game again with its
  usual renderer when OpenGL does not open
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
