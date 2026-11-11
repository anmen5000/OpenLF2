LF2 fighter balance kit (OpenLF2)
=================================
Guide: https://anmen5000.github.io/OpenLF2/xoi.html#balance

For the people who make LF2 mods. One computer player - XOI, the strongest of OpenLF2's - plays both sides of
every pair of fighters of a mod, on every CPU thread, again and again, and counts:
- each fighter's win rate against all the others, with its 95% margin;
- each fighter's win rate against each other fighter (the matchup chart);
- what each move brings: how often it is used, how often it lands, how often it is guarded, the HP it takes off
  (the balls, traps, clones and thrown things it makes included), and how often its user is hit in it.
The numbers, not a verdict: what to change is the mod maker's to say.

1. Install OpenLF2 for Windows once: OpenLF2-Windows-x64.exe from
   https://github.com/anmen5000/OpenLF2/releases/latest (choose "Install for me only").
2. Unzip this kit into a folder you can write to (Documents, say) and put your mod's .zip next to balance.bat.
   A mod you trained XOI for with the XOI kit: use <mod>-xoi.zip - XOI plays it stronger.
3. Open balance.bat in Notepad to change its settings (at the top), or leave them as they are:
     ROUNDS=10          rounds: after each one the report is updated (open it while the rest runs)
     TOTAL_GAMES=       the games to play in all (e.g. 200000), or
     TOTAL_HOURS=2      the hours to run in all, used when TOTAL_GAMES is empty (7.5 = seven and a half)
     FIGHTERS=all       or some ids or names: 8 25 Crimson Deep
     EXCLUDE=           fighters to leave out (a training dummy, a boss)
     BRAIN=xoi          the player: xoi (XOI), smart (INSANE!), classic (the original LF2 computer player,
                        which plays a mod's own AI scripts where it has them)
     WEAPONS=0          weapons falling from the sky: 0 off, 1 on
     GAME_MINUTES=5     a game's longest; STILL_SECONDS=60: a minute without damage ends it, a draw
     PARALLEL, RUN_HOURS, PRIORITY, FIRST_SEED: processes at once, a pause timer, their priority, the seed
   Your own settings can go into a file balance-settings.bat next to it (one line each, such as
   set "TOTAL_GAMES=200000"): they stay when you update the kit.
4. Double-click balance.bat. The results are in balance-<mod>\ next to it:
     report.html        open it in a browser: the ranking, the matchup chart, each fighter's moves
                        (English or Vietnamese at a click; tables to download as CSV)
     results.txt        a summary in text
   Both are updated after every round. Close the window to pause; run it again to go on (the round under way
   too). To measure more later: raise TOTAL_GAMES or TOTAL_HOURS and run it again - the new games add up.
   To start over (after changing the fighters, say): delete or rename balance-<mod>\. Each player gets its
   own folder (balance-<mod>-smart\, balance-<mod>-classic\), to compare them.

How many games: for 21 fighters (210 pairs), a margin of about +-1% on each fighter's rate takes some 100000
games; +-3% on each cell of the matchup chart, some 230000. The speed depends on the mod and the PC (one CPU
thread: from a few hundred to about 9000 games an hour); after every round balance.bat shows the games per hour.

Reading the numbers:
- Win rate = (wins + half the draws) / games. Two fighters closer than their margins cannot be told apart yet.
- A move runs from where a fighter leaves a free stance (standing, walking, running, jumping, dashing,
  guarding) to where it is free again or is hit; a D-sequence (D>A, D^J ...) pressed inside it starts another
  move. Its name: the keys, the frame's name and its first frame number in the fighter's .dat file.
- "Worth a look": a move with 30% or more of the fighter's damage, landing in 50% or more of its uses (not
  asked of a catch), punished in 15% at most, used 50 times or more. A sign to look at, not a verdict.
- This is how the AI plays the fighters: it reacts almost at once and does not find combos the way a good
  player does; about a move it never used, the report says nothing. Check what you conclude with real players.

Files: balance.bat, scripts\ (the game's scripts with XOI and INSANE!, laid over the installed game's),
tools\ai-bench\ (the bench jobs: balance.lua, and the report's page), version.txt (which version this kit is),
LICENSE.txt. The full XOI kit (play, train, tune and publish with XOI) is on the guide's page too.
