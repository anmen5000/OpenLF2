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
