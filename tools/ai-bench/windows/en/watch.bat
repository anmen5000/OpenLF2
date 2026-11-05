@echo off
setlocal EnableDelayedExpansion
rem Watch computer against computer in the game window, to record a clip: two fighters picked by NAME (or id), two
rem computer players, a number of games.
rem How to use: edit FIGHTER1, FIGHTER2 (and BRAIN1, BRAIN2 if you want) below, save, then double-click this file.
rem Leave FIGHTER1 or FIGHTER2 empty: it only prints the mod's fighters (id, name) and stages (number, name), and
rem writes them to fighters.txt next to this file.
rem In the window: F1 pauses / resumes, F5 runs fast, F4 skips the game being watched (on to the next game; after the
rem last game F4 closes the window). Record a clip with OBS Studio or Xbox Game Bar
rem (Win+Alt+R starts / stops recording the selected window). The same SEED replays exactly the same games: a clip
rem can be recorded again.
rem ============ SETTINGS ============
rem The installed game. Leave empty to find it automatically (Install for me only, all users, or an OpenLF2 folder
rem next to this file).
set "GAME="
rem The mod: a zip file or a mod folder (a folder with data\data.txt, including the folder publish.bat creates). To use
rem XOI's numbers (from spsa.bat) take the <name>-xoi.zip file. Leave empty to take the first *-xoi.zip next to this
rem file, or the first .zip if there is none; or drag and drop the mod's zip file / folder onto this file.
set "PACK="
rem The two fighters: a name as in the game (Crimson, Deep...; capitals or not, the first few letters are enough: crim)
rem or an id (8). Both sides can be the same fighter.
set "FIGHTER1=Crimson"
set "FIGHTER2=Crimson"
rem The computer player controlling each side: xoi = XOI, smart = INSANE!, classic = LF2's original computer player
set "BRAIN1=xoi"
set "BRAIN2=smart"
rem Level of the games: -2 for XOI / INSANE!; -1 when classic plays (the original computer player fights at CRAZY!)
set "LEVEL=-2"
rem Number of games (the sides swap every game)
set "GAMES=5"
rem Stage: a name (HK Coliseum, hk...) or its number in the list; empty = random, as in LF2
set "STAGE="
rem A game longer than this many ticks (30 ticks = 1 second; 9000 = 5 minutes) is a draw; on to the next game
set "TICK_LIMIT=9000"
rem Seed: the same number = the same games (can be recorded again); another number = other games
set "SEED=1"
rem Renderer (as in play.bat): empty = opengl, and the game's default if that fails to start; or software, gpu
set "RENDERER="
rem The package's tools\ai-bench and scripts folders (leave empty to find them next to this .bat file)
set "BENCH="
set "SCRIPTS="
rem =====================================

rem Drag and drop: the mod's zip file or folder; for an .exe file (including the .exe publish.bat creates), its folder.
if not "%~1"=="" (
  if /i "%~x1"==".exe" (
    set "PACK=%~dp1"
    set "PACK=!PACK:~0,-1!"
  ) else (
    set "PACK=%~f1"
  )
)
if not defined PACK (
  pushd "%~dp0"
  for %%z in (*-xoi.zip) do if not defined PACK set "PACK=%%~fz"
  for %%z in (*.zip) do (
    set "TEN=%%~nz"
    if not defined PACK if /i not "!TEN:~-13!"=="-xoi-previous" if /i not "!TEN:~0,17!"=="lf2-online-upload" if /i not "!TEN:~0,7!"=="xoi-kit" set "PACK=%%~fz"
  )
  popd
)
if not defined GAME (
  for %%g in ("%LOCALAPPDATA%\Programs\OpenLF2\openlf2.exe" "%ProgramFiles(x86)%\OpenLF2\openlf2.exe" "%ProgramFiles%\OpenLF2\openlf2.exe" "%~dp0OpenLF2\openlf2.exe") do (
    if not defined GAME if exist "%%~g" set "GAME=%%~g"
  )
)
if not defined GAME set "GAME=%LOCALAPPDATA%\Programs\OpenLF2\openlf2.exe"
if not defined BENCH (
  if exist "%~dp0tools\ai-bench\show.lua" set "BENCH=%~dp0tools\ai-bench"
  if exist "%~dp0show.lua" set "BENCH=%~dp0."
  if exist "%~dp0..\show.lua" set "BENCH=%~dp0.."
)
if not defined SCRIPTS (
  if exist "%~dp0scripts\base\game\smart_ai.lua" set "SCRIPTS=%~dp0scripts"
  if exist "%~dp0..\..\scripts\base\game\smart_ai.lua" set "SCRIPTS=%~dp0..\..\scripts"
  if exist "%~dp0..\..\..\scripts\base\game\smart_ai.lua" set "SCRIPTS=%~dp0..\..\..\scripts"
)
if not exist "%GAME%" (echo Game "%GAME%" not found: install OpenLF2 ^(the OpenLF2-Windows-x64.exe installer from the Releases page of the project on GitHub, choose Install for me only^), or edit the GAME line at the top of this file.& pause& exit /b 1)
if not defined PACK (echo No mod found: put a zip file next to this file, drag and drop the mod zip file or mod folder onto this file, or edit the PACK line at the top of this file.& pause& exit /b 1)
if not exist "%PACK%" (echo Mod "%PACK%" not found - edit the PACK line at the top of this file.& pause& exit /b 1)
if not defined BENCH (echo No tools\ai-bench folder ^(with show.lua^) next to this file.& pause& exit /b 1)
if not exist "%BENCH%\names.lua" (echo Folder "%BENCH%" has no names.lua: package version 54 or later is needed.& pause& exit /b 1)

rem A copy of tools\ai-bench with its own config.lua, in the watch folder next to this file.
set "XEM=%~dp0watch"
if exist "%XEM%" rmdir /s /q "%XEM%"
mkdir "%XEM%"
copy /y "%BENCH%\*.lua" "%XEM%\" >nul
copy /y "%BENCH%\package.manifest" "%XEM%\" >nul
rem The installed game's scripts, updated with the package's scripts (the package only holds the changed files): no
rem need to reinstall the game.
set "XS="
if defined SCRIPTS (
  for %%g in ("%GAME%") do set "CAI=%%~dpgscripts"
  if exist "!CAI!\base\game\match.lua" (
    xcopy /e /i /q /y "!CAI!" "%XEM%\scripts" >nul
    xcopy /e /i /q /y "!SCRIPTS!" "%XEM%\scripts" >nul
    if exist "%XEM%\scripts\base\game\smart_ai.lua" (set XS=--scripts "%XEM%\scripts") else (echo [NOTE] Could not merge the scripts - using the installed game's scripts.)
  )
)

if "%FIGHTER1%"=="" goto danh_sach
if "%FIGHTER2%"=="" goto danh_sach

rem (A name inside [==[ ]==]: any characters are allowed, except ]==] itself.)
>"%XEM%\config.lua" echo return {command = "show", brains = {"%BRAIN1%", "%BRAIN2%"}, ids = {[==[%FIGHTER1%]==], [==[%FIGHTER2%]==]}, games = %GAMES%, difficulty = %LEVEL%, background = [==[%STAGE%]==], limit = %TICK_LIMIT%}
set "XR=--renderer opengl"
if defined RENDERER set "XR=--renderer %RENDERER%"
echo Mod: %PACK%
echo %FIGHTER1% ^(%BRAIN1%^) against %FIGHTER2% ^(%BRAIN2%^), %GAMES% games, seed %SEED%.
echo F1 pauses / resumes, F5 runs fast, F4 skips the game being watched ^(after the last game: F4 closes the window^). Score: "%XEM%\watch.txt"
rem A non-zero exit code is an error; when Windows kills the game the code is negative: compare with 0 (see play.bat).
"%GAME%" %XR% %XS% --pack "%PACK%" --mod "%XEM%" --seed %SEED% > "%XEM%\watch.txt" 2>&1
set "MA=!errorlevel!"
if not "!MA!"=="0" if not defined RENDERER (
  echo The opengl renderer could not start on this PC ^(exit code !MA!^) - trying again with the game's default renderer ...
  "%GAME%" %XS% --pack "%PACK%" --mod "%XEM%" --seed %SEED% > "%XEM%\watch.txt" 2>&1
  set "MA=!errorlevel!"
)
echo.
findstr /b /c:"show:" "%XEM%\watch.txt"
findstr /c:"ERROR" "%XEM%\watch.txt"
if not "!MA!"=="0" (
  echo.
  echo The game stopped with an error ^(exit code !MA!^) - see "%XEM%\watch.txt". Window only blue or black: edit the RENDERER line at the top of this file.
)
pause
exit /b 0

:danh_sach
rem One silent run (no window): print the mod's fighters and stages.
>"%XEM%\config.lua" echo return {command = "list"}
"%GAME%" %XS% --pack "%PACK%" --mod "%XEM%" --input-trace "" > "%XEM%\list.txt" 2>&1
set "DS=%~dp0fighters.txt"
> "%DS%" echo Mod: %PACK%
>> "%DS%" echo.
>> "%DS%" echo Fighters ^(id  name  file; hidden = a hidden fighter of LF2^):
for /f "tokens=2,3,4,5" %%a in ('findstr /b /c:"fighter " "%XEM%\list.txt"') do >> "%DS%" echo   %%a  %%b   ^(%%c^) %%d
>> "%DS%" echo.
>> "%DS%" echo Stages ^(number  name - use for STAGE^):
for /f "tokens=1,*" %%a in ('findstr /b /c:"background " "%XEM%\list.txt"') do >> "%DS%" echo   %%b
type "%DS%"
findstr /c:"ERROR" "%XEM%\list.txt"
echo.
echo The list was written to "%DS%". Edit FIGHTER1, FIGHTER2 at the top of this file ^(name or id^) and run it again.
pause
exit /b 0
