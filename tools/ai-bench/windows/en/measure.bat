@echo off
setlocal EnableDelayedExpansion
rem Measures computer player against computer player in bulk: one background openlf2.exe process per CPU core, the results added up when done.
rem By default every fighter of the mod plays every other fighter (on both sides), no need to edit config.lua.
rem ============ SETTINGS ============
rem The installed game. Left empty, it is found automatically (Install for me only, all users, or an OpenLF2 folder beside this file).
set "GAME="
rem The mod's zip file. To measure XOI, use the <name>-xoi.zip that train.bat makes. Left empty, the first *-xoi.zip
rem beside this file is taken, or else the first .zip; or drag a zip file onto this file.
set "PACK="
rem The two computer players that fight: xoi = XOI, smart = INSANE!, classic = the original one, smart@ai_alt = the AI copied into ai_alt.lua
set "BRAIN1=xoi"
set "BRAIN2=smart"
rem Difficulty of the games: -2 (INSANE!/XOI); -1 with classic (the original computer player plays at CRAZY!)
set "LEVEL=-2"
rem Fighters: all = every fighter against every other; or a list of ids or names, e.g. "7 18 1 4" or "Crimson Deep 4"
rem (names as the game shows them, capitals or not; watch.bat with FIGHTER1 left empty prints the list of ids and names).
rem Left empty (set "IDS=") it uses the config.lua of tools\ai-bench: every process runs that same config with a different seed.
set "IDS=all"
rem Games per pair per side (a against b GAMES games and b against a GAMES games, sides swapped every game)
set "GAMES=10"
rem Number of processes running at once (each process takes one CPU core)
set "PARALLEL=%NUMBER_OF_PROCESSORS%"
rem The first seed; process i uses seed FIRST_SEED + i. Change it for every run to get a new set of games.
set "FIRST_SEED=1000"
rem The tools\ai-bench and scripts folders of the package (left empty, they are looked for beside this .bat)
set "BENCH="
set "SCRIPTS="
rem =====================================

rem (This file calls itself to run each process: "chay1 <seed> <number>", the mod in PACK_DA_CHON;
rem through cmd /c call, so that a path with spaces or parentheses ^(^) still runs - see spsa.bat.)
if /i "%~1"=="chay1" set "PACK=%PACK_DA_CHON%"
if /i "%~x1"==".zip" if not exist "%~1\" set "PACK=%~f1"
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

rem One results folder per run (per FIRST_SEED).
set "KQ=%~dp0results-%FIRST_SEED%"
if not defined BENCH (
  if exist "%~dp0tools\ai-bench\duel.lua" set "BENCH=%~dp0tools\ai-bench"
  if exist "%~dp0duel.lua" set "BENCH=%~dp0."
  if exist "%~dp0..\duel.lua" set "BENCH=%~dp0.."
)
if not defined SCRIPTS (
  if exist "%~dp0scripts\base\game\smart_ai.lua" set "SCRIPTS=%~dp0scripts"
  if exist "%~dp0..\..\scripts\base\game\smart_ai.lua" set "SCRIPTS=%~dp0..\..\scripts"
  if exist "%~dp0..\..\..\scripts\base\game\smart_ai.lua" set "SCRIPTS=%~dp0..\..\..\scripts"
)
if /i "%~1"=="chay1" goto chay1
rem A results folder dragged onto this file: only recomputes the summary, plays no game.
if not "%~1"=="" if /i not "%~x1"==".zip" (
  set "KQ=%~1"
  goto tonghop
)

if not exist "%GAME%" (echo Game not found at "%GAME%": install OpenLF2 ^(the OpenLF2-Windows-x64.exe installer under Releases on the project's GitHub page, choose Install for me only^), or edit the GAME line at the top of the file.& pause& exit /b 1)
if not defined PACK (echo No mod zip file found: put it beside this file, drag it onto this file, or edit the PACK line at the top of the file.& pause& exit /b 1)
if not exist "%PACK%" (echo Mod not found: "%PACK%" - edit the PACK line at the top of the file.& pause& exit /b 1)
if not defined BENCH (echo No tools\ai-bench folder found beside this file.& pause& exit /b 1)
if not defined IDS if not exist "%BENCH%\config.lua" (echo "%BENCH%\config.lua" not found& pause& exit /b 1)
if not exist "%KQ%" mkdir "%KQ%"
del /q "%KQ%\run-*.txt" 2>nul
rem The installed game's scripts, updated with the package's scripts (the package holds only the files that changed): no need to reinstall the game.
if exist "%KQ%\scripts" rmdir /s /q "%KQ%\scripts"
if defined SCRIPTS (
  for %%g in ("%GAME%") do set "CAI=%%~dpgscripts"
  if exist "!CAI!\base\game\match.lua" (
    echo Merging the installed game's scripts with the package's scripts ...
    xcopy /e /i /q /y "!CAI!" "%KQ%\scripts" >nul
    xcopy /e /i /q /y "!SCRIPTS!" "%KQ%\scripts" >nul
    if not exist "%KQ%\scripts\base\game\smart_ai.lua" echo [NOTE] Could not merge - using the installed game's scripts.
  )
)

set /a N=PARALLEL
if %N% LSS 1 set /a N=1
for /L %%k in (1,1,%N%) do if exist "%KQ%\b%%k" rmdir /s /q "%KQ%\b%%k"
rem Automatic: one copy of tools\ai-bench per process with its own config (share k of the matchups).
set "IDS_LUA="
if defined IDS if /i "%IDS%"=="all" set "IDS_LUA="all""
rem (Each id or name inside [==[ ]==]: tools\ai-bench\names.lua turns names into ids.)
if defined IDS if not defined IDS_LUA (
  for %%i in (%IDS%) do if defined IDS_LUA (set "IDS_LUA=!IDS_LUA!, [==[%%i]==]") else (set "IDS_LUA=[==[%%i]==]")
  set "IDS_LUA={!IDS_LUA!}"
)
if defined IDS (
  for /L %%k in (1,1,%N%) do (
    mkdir "%KQ%\b%%k"
    copy /y "%BENCH%\*.lua" "%KQ%\b%%k\" >nul
    copy /y "%BENCH%\package.manifest" "%KQ%\b%%k\" >nul
    >"%KQ%\b%%k\config.lua" echo return {command = "duel", brains = {"%BRAIN1%", "%BRAIN2%"}, difficulty = %LEVEL%, games = %GAMES%, limit = 9000, audit = true, ids = !IDS_LUA!, part = %%k, parts = %N%}
  )
  echo Matchups: %BRAIN1% against %BRAIN2%, fighters: %IDS%, %GAMES% games per pair per side, split over %N% processes.
) else (
  echo Every process runs "%BENCH%\config.lua" with its own seed.
)

echo Mod: "%PACK%"
echo Starting %N% processes, seeds from %FIRST_SEED% + 1 ...
set "PACK_DA_CHON=%PACK%"
for /L %%i in (1,1,%N%) do (
  set /a SEED=FIRST_SEED+%%i
  start "AI !SEED!" /MIN cmd /c call "%~f0" chay1 !SEED! %%i
)
echo Running (each process is a minimized window, nothing is drawn). Results are written to "%KQ%"
echo Waiting for the openlf2.exe processes to finish (do not open the game to play meanwhile)...
if defined KHONG_CHO exit /b 0
:cho
timeout /t 5 /nobreak >nul
tasklist /FI "IMAGENAME eq openlf2.exe" 2>nul | find /I "openlf2.exe" >nul && goto cho

:tonghop
if not exist "%KQ%\run-*.txt" (echo No run-*.txt files in "%KQ%"& pause& exit /b 1)
set /a W=0, L=0, D=0, N=0, LOI=0
set "KEYS="
set "DA_IN="
set "TU_DONG="
if exist "%KQ%\b1\config.lua" set "TU_DONG=1"
type nul > "%KQ%\pairs.txt"
type nul > "%KQ%\fighters.tmp"
echo.
for /f "delims=" %%n in ('dir /b /on "%KQ%\run-*.txt"') do (
  set "F=!KQ!\%%n"
  if not defined DA_IN (
    for /f "delims=" %%l in ('findstr /C:"brains:" "!F!"') do echo %%l
    set "DA_IN=!F!"
  )
  set "CO="
  for /f "tokens=3,5,8" %%a in ('findstr /C:"TOTAL " "!F!"') do (
    set /a W+=%%a, L+=%%b, D+=%%c, N+=1
    set "CO=1"
  )
  if not defined CO (
    set /a LOI+=1
    echo [ERROR] %%n has no TOTAL line - errors in the file:
    findstr /C:"ERROR" "!F!"
  )
  for /f "tokens=2,4,6,8" %%a in ('findstr /C:"pair " "!F!"') do (
    if not defined FW_%%a echo %%a>>"!KQ!\fighters.tmp"
    set /a FW_%%a+=%%c, FL_%%a+=%%d
    rem Right side: the second fighter, controlled by brains[2].
    set "B=%%b"
    set "B=!B::=!"
    set /a GW_!B!+=%%d, GL_!B!+=%%c
    if not defined TU_DONG (
      set "K=%%a_%%b"
      set "K=!K::=!"
      if not defined PW_!K! set "KEYS=!KEYS! !K!"
      set /a PW_!K!+=%%c, PL_!K!+=%%d
    )
  )
  if defined TU_DONG findstr /C:"pair " "!F!" >> "!KQ!\pairs.txt"
)
echo.
if defined TU_DONG (
  echo ===== Each fighter, against every other fighter =====
  echo   column 1: the fighter controlled by brains[1] ^(%BRAIN1%^), the opponent controlled by brains[2] ^(%BRAIN2%^): wins - losses, win rate
  echo   column 2: the other way round, the fighter controlled by brains[2]: win rate
  echo   diff: column 1 minus column 2. Both columns low = a weak fighter ^(not the AI's doing^);
  echo   positive diff = brains[1] plays this fighter better than brains[2], negative diff = worse.
  for /f "usebackq delims=" %%i in ("%KQ%\fighters.tmp") do call :in_quan %%i
  echo Every pair's result: "%KQ%\pairs.txt"
) else (
  echo ===== Each pair ^(left id controlled by brains[1]; left wins - right wins^) =====
  for %%k in (!KEYS!) do call :in_cap %%k
)
set /a TONG=W+L
if %TONG% EQU 0 (echo No game has a result.& pause& exit /b 1)
set /a "P10=W*1000/TONG, P1=P10/10, P2=P10%%10"
rem 95%% error margin when the rate is around 50%%: 98 / square root(games) percent.
set /a "T100=TONG*100, S=T100"
for /L %%z in (1,1,40) do set /a "S=(S+T100/S)/2"
set /a "E10=9800/S, E1=E10/10, E2=E10%%10"
echo.
echo ===== Summary of %N% runs: %W% wins - %L% losses, %D% draws =====
echo Win rate of brains[1]: %P1%.%P2%%% over %TONG% games with a result, error margin about +-%E1%.%E2%%%
echo (Less than the error margin away from 50%% counts as even; run again with another FIRST_SEED to be surer.)
if %LOI% GTR 0 echo [ERROR] %LOI% files have no result - see the ERROR lines above.
echo Details (every game, AUDIT) are in "%KQ%\run-*.txt"
if "%KHONG_DUNG%"=="" pause
exit /b 0

:chay1
rem One process: the game runs in the background (no window) with seed %2, results into run-%2.txt, closes the window when done.
set "XS="
if exist "%KQ%\scripts\base\game\smart_ai.lua" set XS=--scripts "%KQ%\scripts"
set "MOD=%BENCH%"
if exist "%KQ%\b%~3\config.lua" set "MOD=%KQ%\b%~3"
"%GAME%" --pack "%PACK%" %XS% --mod "%MOD%" --seed %~2 --input-trace "" > "%KQ%\run-%~2.txt" 2>&1
exit

:in_cap
for /f "tokens=1,2 delims=_" %%x in ("%~1") do echo   %%x vs %%y: !PW_%~1! - !PL_%~1!
exit /b 0

:in_quan
set "TEN="
for /f "tokens=3" %%t in ('findstr /C:"fighter %1 " "%DA_IN%" 2^>nul') do if not defined TEN set "TEN=%%t"
set /a "QW=FW_%1, QL=FL_%1, QT=QW+QL, RW=GW_%1, RL=GL_%1, RT=RW+RL"
if %QT% EQU 0 (echo   %1 %TEN%: no game with a result yet& exit /b 0)
set /a "QP=QW*1000/QT, Q1=QP/10, Q2=QP%%10"
if %RT% EQU 0 (echo   %1 %TEN%: %QW% - %QL% ^(%Q1%.%Q2%%%^)& exit /b 0)
set /a "RP=RW*1000/RT, R1=RP/10, R2=RP%%10, DP=QP-RP"
set "SG=+"
if %DP% LSS 0 (set "SG=-"& set /a DP=-DP)
set /a "D1=DP/10, D2=DP%%10"
echo   %1 %TEN%: %QW% - %QL% ^(%Q1%.%Q2%%%^) ^| column 2: %R1%.%R2%%% ^| diff %SG%%D1%.%D2%
exit /b 0
