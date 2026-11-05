LF2 XOI kit (English edition): the INSANE! and XOI computer players on your PC
=============================================================================
Full guide: https://anmen5000.github.io/OpenLF2/xoi.html (the guide names the files of the Vietnamese kit;
this edition has the same tools under English names, listed at the end).

A mod's own .exe is the original Little Fighter 2: its computer players stop at CRAZY!.
INSANE! and XOI are part of OpenLF2, which plays the same mod files.

1. Install OpenLF2 for Windows once: OpenLF2-Windows-x64.exe from
   https://github.com/anmen5000/OpenLF2/releases/latest
   (x64 is for 64-bit Windows 10 and 11, nearly every PC; x86 is only for old 32-bit Windows.)
   Choose "Install for me only". If Windows says "Windows protected your PC": More info, then Run anyway.
2. Play: put a mod's .zip next to play.bat and double-click play.bat, or drag the mod's .zip, its folder
   or its .exe onto play.bat. In the game, cycle the difficulty past CRAZY! to INSANE!, then XOI.
   XOI notes: a <mod>-xoi.zip has them inside; a notes .txt is dragged onto play.bat together with the mod.
   A window that stays blue with no pictures: open play.bat in Notepad and set RENDERER=software.
3. Train XOI for a mod: put the mod's .zip next to train.bat and double-click it (its settings are at the
   top of the file: right-click it, Edit). It makes <mod>-xoi.zip (the mod with xoi\notes.txt inside) and
   xoi-<mod>\notes.txt (the notes alone, to share).
4. Measure: measure.bat plays XOI against INSANE! on every pair of fighters and prints the win rate.
5. Tune XOI's numbers (SPSA): put one or more mods' .zip next to spsa.bat and double-click it. Two
   computer players fight with XOI's 77 numbers nudged one way and the other; the numbers move toward
   whichever did better, round after round (ROUNDS rounds of ROUND_MINUTES minutes, 12 x 5 by default, one
   process per CPU thread), then the tuned numbers play the ones they started from for CHECK_MINUTES
   minutes. The tuned numbers are XOI's alone: INSANE! keeps its own, set by hand (from package 43). Result:
   spsa\results.txt - send it to whoever maintains the AI. A night: ROUNDS=60, ROUND_MINUTES=10, CHECK_MINUTES=15.
   A pair is two games, same fighters and stage, sides swapped. In a round every process plays pairs until
   the minutes are up, all stopping together (no thread waits for a slower one); then the mean step per pair
   is taken, every mod weighing the same. To pause: close its window and the minimized SPSA windows; run it
   again to go on - finished rounds stay, and so does what the round under way had played. Several mods at
   once: put their .zip files next to it; the check gives each mod's result too. A game in which nobody
   loses HP for a minute ends there, and a window stuck far longer than the others is stopped.
   Each mod's numbers: at the end it writes xoi-<mod>\tune.txt and <mod>-xoi.zip, the mod with xoi\tune.txt
   (and XOI's notes, if trained) inside: uploaded to the relay, XOI plays that mod with its own
   numbers ("mod tuned" in the match). With one mod next to it, the next run goes on from that mod's numbers.
   Several PCs: give each PC one or two mods of its own (one mod per PC gives each mod its own best numbers);
   two PCs on the same mod need different FIRST_SEED.
   Start from earlier numbers: put a "return {...}" line of a previous results.txt into spsa\start.lua before
   the first round.
   OPPONENT=classic: both nudged sets play the original computer player instead of each other - the mod's
   ai\<id>.as scripts where a fighter has them (Sauce's AI, item 9) - so the numbers move toward what beats that
   opponent; a round costs twice the games, and the check reports the tuned numbers and the original ones against
   it. For tuning against one particular player; the numbers it finds suit that player first.
6. Publish a mod for its players, INSANE! and XOI built in: put <mod>-xoi.zip (or the mod's zip or folder)
   next to publish.bat and double-click it. It makes publish\<mod>.zip: the mod's own folder as its author
   shares it (bg, bgm, data, sprite..., its own .exe too) with OpenLF2 added - "<mod> - INSANE XOI.exe", its
   .dll files, the scripts and licenses folders, XOI's notes and numbers in xoi\. Players extract it and
   double-click "<mod> - INSANE XOI.exe" - nothing to install, no kit, no original LF2. Needs OpenLF2 from
   package 50 (it plays the mod folder it lies in by itself; publish.bat says when the installed one is older).
   Another name: NAME at the top of publish.bat; your words for the players: edit publish-README.txt first
   ({TEN} becomes the name, {EXE} the program, {GOC} the mod's own .exe); it becomes README - INSANE XOI.txt.
   It asks whether to lock the hidden fighters (Y = yes): no "options" on the players' title screen, no
   unlocking, lf2.net does nothing; CRAZY!, INSANE! and XOI stay (openlf2.txt in the mod; package 49).
   LOCK_HIDDEN at the top of publish.bat answers it beforehand.
   Publish your own mod, or one whose author allows it; keep the licenses folder in it.
7. The game does not open, or closes at once: put a mod's .zip next to check.bat, double-click it, wait
   about 2 minutes (game windows may open and close by themselves) and send check.txt.
8. Watch two computer players fight in the game's window (to record a clip): open watch.bat in Notepad, set
   FIGHTER1 and FIGHTER2 to two fighters - by name as the game shows it (Crimson, Deep; capitals or not; the
   first letters are enough) or by id - and BRAIN1, BRAIN2 (xoi, smart = INSANE!, classic), then double-click
   it. GAMES games, sides swapped every game; STAGE a background by name or number (empty: random); a game
   still on after TICK_LIMIT ticks (9000 = 5 minutes) is a draw; the same SEED plays the same games again.
   F1 pauses, F5 runs fast, F4 ends the game under way (after the last, it closes the window). FIGHTER1 left
   empty: it lists the mod's fighters (id, name) and backgrounds into fighters.txt.
   It takes the mod as the other files do (a *-xoi.zip first, or drag a zip, a mod folder or a published
   mod's .exe onto it). Record with OBS Studio or Xbox Game Bar (Win+Alt+R). measure.bat takes names in
   IDS too ("Crimson Deep").
9. INSANE! or XOI against another computer player made for LF2 - a mod's ai\<id>.as scripts, which LF2 runs
   with the AI script engine's ai.dll or ddraw.dll (Sauce's "lf2-AI VS and Stage Challenge"; package 56): in
   measure.bat (or watch.bat) set BRAIN1=smart (or xoi), BRAIN2=classic - the original computer player, which
   plays the mod's script for each fighter that has one - and LEVEL=-1 (CRAZY!, the scripts' best level); IDS
   the fighters (Sauce's ten original ones: 1 2 4 5 6 7 8 9 10 11). A mod whose own .exe has none of LF2's
   pictures (moved to its UI folder, as Sauce's) needs OpenLF2 built from package 56 on; with an older one,
   copy LF2 2.0a's lf2.exe (or a mod's lf2_2.0a.exe, mode Convergence has one) into the mod's folder as
   lf2.exe first.

Files: play.bat (play), train.bat (train XOI), measure.bat (measure), spsa.bat (tune), watch.bat (watch),
publish.bat (publish; its work is in publish.ps1, the published README comes from publish-README.txt),
check.bat (check why the game does not open), scripts\ (the game's scripts with the computer players, laid over
the installed game's), tools\ai-bench\ (the training and measuring jobs), version.txt (which version this kit is).
The Vietnamese kit's names, for the guide: choi.bat = play.bat, xoi-hoc.bat = train.bat, dau-nhieu.bat =
measure.bat, xem.bat = watch.bat, xuat-ban.bat = publish.bat, kiem-tra.bat = check.bat; ket-qua.txt = results.txt,
danh-sach.txt = fighters.txt, <mod>-xoi-truoc.zip = <mod>-xoi-previous.zip, kiem-tra.txt = check.txt.
