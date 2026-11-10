@echo off
setlocal EnableDelayedExpansion
rem SPSA - tunes XOI's judgement numbers automatically by having XOI fight itself (from package 43 only XOI uses the
rem tuned numbers; INSANE! keeps the numbers set by hand)
rem (OpenLF2 package 32 or later). The numbers (88 from package 71 - six "momentum" ones: how much bolder or warier the
rem HP just dealt or lost makes XOI, 0 by default; 77 from package 38: the score of a move, the threshold to use a move,
rem distances, reaction, overlap...) live in scripts\base\game\smart_ai.lua (smart.tune_ranges).
rem Every round, every process (one CPU thread) has two AI players fight: the "plus" one has its numbers nudged up or
rem down at random, the "minus" one nudged the other way; the numbers move toward whichever fought better. End of round:
rem the processes are merged, the next round starts from there. After the last round: the tuned numbers play the
rem original ones as a check. Result: spsa\results.txt (send this file to whoever maintains the AI). Each mod's numbers:
rem xoi-<mod>\tune.txt, and <mod>-xoi.zip = the mod with those numbers (and XOI's notes, if trained) - uploaded to the
rem relay, XOI plays that mod with its own numbers (package 38 on; from package 43 INSANE! does not use them). One mod only: the next run goes on from its numbers.
rem To pause: close this window and the minimized SPSA windows (or shut the PC down). To go on: run this file again - the
rem finished rounds are kept, and so is what the round under way had played (but the last few pairs). To start over:
rem delete the spsa folder (or change FIRST_SEED and give the old folder another name).
rem ============ SETTINGS ============
rem The installed game. Left empty, it is looked for (Install for me only, all users, or an OpenLF2 folder next to this file).
set "GAME="
rem The mod's zip file. Left empty, EVERY mod .zip next to this file is used (but *-xoi.zip, lf2-online-upload packages,
rem xoi-kit), the processes shared out evenly among the mods; a zip file dragged onto this file is the only mod used.
set "PACK="
rem Number of rounds (ROUNDS) and minutes per round (ROUND_MINUTES): the whole run takes about ROUNDS x ROUND_MINUTES
rem minutes (60 x 10 = 10 hours). In a round every process plays pair after pair on its mod until the minutes are up.
rem A pair: two games, same two fighters, same stage, sides swapped - the "plus" player (numbers nudged up or down at
rem random) against the "minus" one (nudged the other way); after the pair the numbers move toward the better one. All
rem processes stop together, so no CPU thread sits waiting (a fast mod plays more pairs). At the end of the round the
rem mean step per pair is taken, every mod weighing the same, and the next round starts from there; the step shrinks
rem round after round. A pair takes about 1-3 seconds.
set "ROUNDS=12"
set "ROUND_MINUTES=5"
set "PARALLEL=%NUMBER_OF_PROCESSORS%"
rem Minutes of the check after the last round, the tuned numbers against the original ones (0 = skip the check)
set "CHECK_MINUTES=5"
rem Priority of the processes: BELOWNORMAL (the PC stays smooth to use while it runs), LOW, or NORMAL
set "PRIORITY=BELOWNORMAL"
rem The first seed (the games and the nudges of the numbers all follow the seed: the same seed replays exactly the same run)
set "FIRST_SEED=9000"
rem Opponent (OPPONENT). Empty: the two nudged sets play each other (as before). classic: both play the game's original
rem computer player (CRAZY; a fighter that has the mod's ai\<id>.as script - Sauce's AI - is played by that script), and
rem the numbers move toward the set that did better against it; a round costs twice the games (both sets play), and the
rem check plays the tuned numbers and then the original ones against that opponent (both results are written). For
rem tuning against one particular opponent (Sauce's AI on the ten original fighters; set IDS in tools\ai-bench if
rem needed). In a mod with no AI scripts of its own the two nudged sets still play each other (the CRAZY player is too
rem weak to tune against) - so put Sauce's pack and the mods in together: one set of numbers, every pack weighing the
rem same, each tuned against the strongest player it has.
set "OPPONENT="
rem The tools\ai-bench and scripts folders of package 32 or later (left empty, they are looked for next to this .bat file)
set "BENCH="
set "SCRIPTS="
rem =====================================
rem Your own settings, kept across kit updates: a file spsa-settings.bat beside this one (make it yourself), one
rem setting a line as above, e.g.  set "OPPONENT=classic"  and  set "ROUNDS=60"  - a new spsa.bat copied over this one
rem leaves them in place (a run in November 2026 lost OPPONENT=classic for its last five rounds that way).
if exist "%~dp0spsa-settings.bat" (
  call "%~dp0spsa-settings.bat"
  if /i not "%~1"=="chay1" echo Your settings: spsa-settings.bat
)

rem (This file calls itself again for each process, in its own window: cmd /c call "<this file>" chay1 <round-N or
rem check> <process number> <seed> <mod number>. No quotes other than around the file name: when the command holds
rem several pairs of quotes, Windows drops the first and the last, and a path with a space - D:\...\AI arena, say -
rem keeps the process from running. The process's folder: spsa\<round-N or check>\p<number>.)
if /i "%~1"=="chay1" goto chay1

set "SELF=%~f0"
set "KIT=%~dp0"
set "LV=%~dp0spsa"
rem --- The mods: dragged onto this file, the PACK line, or every mod zip next to this file ---
set /a NP=0
if not "%~1"=="" if /i "%~x1"==".zip" if exist "%~f1" (
  set /a NP=1
  set "PACK_1=%~f1"
)
if !NP! EQU 0 if defined PACK (
  set /a NP=1
  set "PACK_1=!PACK!"
)
if !NP! EQU 0 (
  pushd "%~dp0"
  for %%z in (*.zip) do (
    set "TEN=%%~nz"
    set "BO="
    if /i "!TEN:~-4!"=="-xoi" set "BO=1"
    if /i "!TEN:~-13!"=="-xoi-previous" set "BO=1"
    if /i "!TEN:~0,17!"=="lf2-online-upload" set "BO=1"
    if /i "!TEN:~0,7!"=="xoi-kit" set "BO=1"
    if not defined BO (
      set /a NP+=1
      set "PACK_!NP!=%%~fz"
    )
  )
  popd
)
if !NP! EQU 0 (echo No mod zip file found: put the mod's zip file next to this file, drag it onto this file, or set the PACK line at the top of this file.& pause& exit /b 1)

rem --- Game, bench, scripts ---
if not defined GAME (
  for %%g in ("%LOCALAPPDATA%\Programs\OpenLF2\openlf2.exe" "%ProgramFiles(x86)%\OpenLF2\openlf2.exe" "%ProgramFiles%\OpenLF2\openlf2.exe" "%~dp0OpenLF2\openlf2.exe") do (
    if not defined GAME if exist "%%~g" set "GAME=%%~g"
  )
)
if not defined GAME set "GAME=%LOCALAPPDATA%\Programs\OpenLF2\openlf2.exe"
if not defined BENCH (
  if exist "%~dp0tools\ai-bench\spsa.lua" set "BENCH=%~dp0tools\ai-bench"
  if exist "%~dp0spsa.lua" set "BENCH=%~dp0."
  if exist "%~dp0..\spsa.lua" set "BENCH=%~dp0.."
)
if not defined SCRIPTS (
  if exist "%~dp0scripts\base\game\smart_ai.lua" set "SCRIPTS=%~dp0scripts"
  if exist "%~dp0..\..\..\scripts\base\game\smart_ai.lua" set "SCRIPTS=%~dp0..\..\..\scripts"
)
if not exist "%GAME%" (echo Game not found at "%GAME%": install OpenLF2 ^(the OpenLF2-Windows-x64.exe installer under Releases on the project's GitHub page, choose Install for me only^), or set the GAME line at the top of this file.& pause& exit /b 1)
if not defined BENCH (echo No tools\ai-bench folder with spsa.lua found - the XOI kit or package 32 or later is needed.& pause& exit /b 1)
if not exist "%BENCH%\spsa.lua" (echo "%BENCH%\spsa.lua" not found - the XOI kit or package 32 or later is needed.& pause& exit /b 1)
if not defined SCRIPTS (echo No scripts folder found next to this file - the XOI kit or package 32 or later is needed.& pause& exit /b 1)
findstr /c:"smart.tune_ranges" "%SCRIPTS%\base\game\smart_ai.lua" >nul 2>nul || (echo "%SCRIPTS%\base\game\smart_ai.lua" has no numbers to tune ^(smart.tune_ranges^) - the XOI kit or package 32 or later is needed.& pause& exit /b 1)
set /a N=PARALLEL
if %N% LSS 1 set /a N=1
rem Memory: a process takes up to about 0.6 GB (Naruto ~0.5). With PARALLEL at its default (every CPU thread) on a PC
rem with little RAM, fewer processes are run, leaving about 4 GB to Windows (a 16 GB PC: 18 processes). PARALLEL set to
rem anything other than the number of CPU threads is kept as it is.
set /a RAM_GB=0
if "%PARALLEL%"=="%NUMBER_OF_PROCESSORS%" for /f %%m in ('powershell -NoProfile -Command "[int][math]::Floor((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)" 2^>nul') do set /a RAM_GB=%%m 2>nul
if !RAM_GB! GEQ 2 (
  set /a "TOI_DA=(RAM_GB-4)*10/6"
  if !TOI_DA! LSS 1 set /a TOI_DA=1
  if !TOI_DA! LSS %N% (
    echo This PC has !RAM_GB! GB of RAM: running !TOI_DA! processes instead of %N% ^(each process takes up to about 0.6 GB^).
    set /a N=TOI_DA
  )
)
rem Seconds per round, seconds of the check; pairs per process per round, estimated (a pair ~2 seconds) for the first
rem round's step - from round 2 on, the real number of pairs played is used (spsa\round-N\after.txt). (TEST_SECONDS:
rem seconds per round, for trying this file out.)
set /a GIAY_VONG=ROUND_MINUTES*60, GIAY_KT=CHECK_MINUTES*60
rem (The opponent, if any, goes into every process's config: opponent = "classic", .)
set "DT_CFG="
if defined OPPONENT set DT_CFG=opponent = "%OPPONENT%", 
if defined TEST_SECONDS set /a GIAY_VONG=TEST_SECONDS, GIAY_KT=TEST_SECONDS
if %GIAY_VONG% LSS 10 set /a GIAY_VONG=10
set /a K_NOM=GIAY_VONG/2, TONG=ROUNDS*(GIAY_VONG/2)
if not defined PRIORITY set "PRIORITY=NORMAL"

if not exist "%LV%" mkdir "%LV%"
rem The installed game's scripts, updated with the package's (which may hold only the changed files): no reinstall needed.
if not exist "%LV%\scripts\base\game\smart_ai.lua" (
  for %%g in ("%GAME%") do set "CAI=%%~dpgscripts"
  if exist "!CAI!\base\game\match.lua" xcopy /e /i /q /y "!CAI!" "%LV%\scripts" >nul
  xcopy /e /i /q /y "%SCRIPTS%" "%LV%\scripts" >nul
)
if not exist "%LV%\scripts\base\game\match.lua" (echo [ERROR] Could not assemble the scripts into "%LV%\scripts".& pause& exit /b 1)
set XS=--scripts "%LV%\scripts"
rem Starting point: XOI's numbers (an empty start.lua), or a start.lua put there beforehand ^(a previous run's result, say^).
rem One mod only, with its own numbers already (xoi-<mod>\tune.txt, from a previous run): tuning goes on from them.
if %NP% EQU 1 if not exist "%LV%\start.lua" for %%z in ("!PACK_1!") do if exist "%KIT%xoi-%%~nz\tune.txt" (
  copy /y "%KIT%xoi-%%~nz\tune.txt" "%LV%\start.lua" >nul
  echo Starting from the mod's own numbers: "%KIT%xoi-%%~nz\tune.txt"
)
if not exist "%LV%\start.lua" (>"%LV%\start.lua" echo return {})

echo Mods ^(%NP%^):
for /L %%p in (1,1,%NP%) do call echo   %%p. %%PACK_%%p%%
echo %ROUNDS% rounds x %ROUND_MINUTES% minutes, %N% processes ^(priority %PRIORITY%^); results go to "%LV%"
echo To pause: close this window and the minimized SPSA windows. Run this file again to go on, the round under way included.
echo To run overnight: turn off Windows sleep ^(Settings - System - Power - Sleep: Never^).

set "GAME_DA_CHON=%GAME%"
set XS_DA_CHON=%XS%
set "TRUOC=%LV%\start.lua"
rem K_DAU: the number of pairs every chain had played before this round (for the step size), from the previous round's after.txt.
set /a E=1, K_DAU=0
:vong_tiep
if %E% GTR %ROUNDS% goto kiem
set "D=%LV%\round-%E%"
rem A merged round: its numbers in start-after.lua (the --SPSA_START line). A broken file - the PC cut off while it was
rem being written, Windows leaves a file of zeros - is dropped, and the round merged again from the processes that
rem played it (not played again).
if exist "%D%\start-after.lua" (
  findstr /c:"--SPSA_START" "%D%\start-after.lua" >nul 2>nul && (
    set "TRUOC=%D%\start-after.lua"
    call :doc_k "%D%"
    set /a E+=1
    goto vong_tiep
  )
  echo The numbers file of round %E% is broken ^(PC cut off while writing?^): "%D%\start-after.lua" - merging round %E% again.
  del /q "%D%\start-after.lua" 2>nul
  del /q "%D%\after.txt" 2>nul
)
call :mot_vong
if errorlevel 1 goto loi
set "TRUOC=%D%\start-after.lua"
call :doc_k "%D%"
set /a E+=1
goto vong_tiep

:mot_vong
echo.
echo === Round %E%/%ROUNDS%: %N% processes playing for %ROUND_MINUTES% minutes ^(%TIME%^) ===
call :giay BAT_DAU
set /a FIRST=K_DAU
set "GHI_CHU="
rem The processes of this round all finished last time but their numbers were not merged (PC cut off during the merge,
rem or the numbers file is broken): only merge again, do not play again.
if exist "%D%" (
  set /a XONG_N=0, CHUA_N=0
  pushd "%D%"
  for /d %%p in (p*) do if exist "%%p\out.txt" (
    set "XONG_P="
    findstr /c:"SPSA chain done" "%%p\out.txt" >nul 2>nul && set "XONG_P=1"
    if defined XONG_P (set /a XONG_N+=1) else set /a CHUA_N+=1
  )
  popd
  if !XONG_N! GEQ 1 if !CHUA_N! EQU 0 (
    echo   ^(the processes finished last time: only merging again^)
    set "GHI_CHU= - merged again only"
    goto gop_vong
  )
)
rem This round was left half done last time (window closed, PC shut down): what it played is kept in earlier\<n> and
rem merged in at the end of the round. (File patterns: pushd into the folder, then a relative path - a pattern with a
rem quoted absolute path is not found by Wine, when this file is tried there.)
set /a LAN=0
set "DO_DANG="
if exist "%D%" (
  pushd "%D%"
  for /d %%p in (p*) do if exist "%%p\out.txt" set "DO_DANG=1"
  popd
)
if defined DO_DANG (
  set "LAN="
  for /L %%a in (1,1,99) do if not defined LAN if not exist "%D%\earlier\%%a" set "LAN=%%a"
  mkdir "%D%\earlier\!LAN!"
  pushd "%D%"
  for /d %%p in (p*) do if exist "%%p\out.txt" move /y "%%p\out.txt" "earlier\!LAN!\%%p.txt" >nul
  popd
  echo   ^(going on with the unfinished round: keeping what the earlier run played^)
)
if not exist "%D%" mkdir "%D%"
call :chuan_bi "%D%" "%TRUOC%"
set /a PI=0
for /L %%k in (1,1,%N%) do (
  set /a PI+=1
  if !PI! GTR %NP% set /a PI=1
  set /a SEED=FIRST_SEED+E*1000+%%k+LAN*100000
  >"%D%\p%%k\config.lua" echo return {command = "spsa", step = "chain", !DT_CFG!start = "spsa_start", iterations = 1000000, seconds = %GIAY_VONG%, first = %FIRST%, total = %TONG%, seed = !SEED!, mod = !PI!, limit = 9000}
  start "SPSA round %E% - %%k" /MIN /%PRIORITY% cmd /c call "%SELF%" chay1 round-%E% %%k !SEED! !PI!
)
call :cho "%D%" "SPSA chain done"
:gop_vong
rem Merge: the mean step per pair over the processes (the earlier runs' parts in earlier\ too, and a process stopped
rem midway with its part up to its last report).
set "M=%D%\merge"
if exist "%M%" rmdir /s /q "%M%"
mkdir "%M%"
call :ban_bench "%M%"
copy /y "%TRUOC%" "%M%\spsa_start.lua" >nul
>"%M%\spsa_chains.lua" echo return {
set /a CO=0
pushd "%D%"
for /d %%p in (p*) do (
  call :lay_chuoi "%D%\%%p\out.txt" "%M%\spsa_chains.lua"
  if not defined GHI_CHU if exist "%%p\out.txt" findstr /c:"SPSA chain done" "%%p\out.txt" >>summary.txt
)
if exist earlier (
  pushd earlier
  for /r %%f in (p*.txt) do call :lay_chuoi "%%f" "%M%\spsa_chains.lua"
  popd
)
popd
>>"%M%\spsa_chains.lua" echo }
if !CO! EQU 0 (echo [ERROR] No process played any pair in round %E% - see "%D%\p1\out.txt".& exit /b 1)
>>"%M%\package.manifest" echo module=spsa_start^|spsa_start.lua
>>"%M%\package.manifest" echo module=spsa_chains^|spsa_chains.lua
>"%M%\config.lua" echo return {command = "spsa", step = "merge", start = "spsa_start", chains = "spsa_chains", first = %FIRST%}
"%GAME%" --pack "%PACK_1%" %XS% --mod "%M%" --seed 1 --input-trace "" >"%M%\out.txt" 2>&1
call :cho_dong "%M%\out.txt" "--SPSA_START"
findstr /c:"--SPSA_START" "%M%\out.txt" >"%D%\start-after.tmp"
for %%f in ("%D%\start-after.tmp") do if %%~zf LSS 20 (echo [ERROR] Could not merge round %E% - see "%M%\out.txt".& exit /b 1)
set "CAP_V=?"
for /f "tokens=2" %%v in ('findstr /c:"SPSA_PAIRS " "%M%\out.txt"') do set "CAP_V=%%v"
for /f "tokens=2" %%v in ('findstr /c:"SPSA_K " "%M%\out.txt"') do >"%D%\after.txt" echo %%v
move /y "%D%\start-after.tmp" "%D%\start-after.lua" >nul
rem How long this round took (by the clock; right across midnight too), and about how long the whole run has left.
call :giay XONG_LUC
set /a "PHUT_V=((XONG_LUC-BAT_DAU+86400) %% 86400)/60, CON_V=ROUNDS-E, CON=CON_V*PHUT_V, CON_G=CON/60, CON_P=CON %% 60"
>>"%LV%\timing.txt" echo Round %E%/%ROUNDS%: !CO! chains, !CAP_V! pairs, finished at %TIME%, took !PHUT_V! minutes!GHI_CHU!
(
  echo Results after round %E%/%ROUNDS% ^(!CO! chains, !CAP_V! pairs^):
  type "%D%\start-after.lua"
  echo.
  findstr /c:"SPSA_LIST" "%M%\out.txt"
  findstr /c:"SPSA_MODS" "%M%\out.txt"
  echo.
  echo Settings: ROUNDS=%ROUNDS% ROUND_MINUTES=%ROUND_MINUTES% PARALLEL=%N% CHECK_MINUTES=%CHECK_MINUTES% FIRST_SEED=%FIRST_SEED% OPPONENT=%OPPONENT%; mods:
  for /L %%p in (1,1,%NP%) do call echo   %%p. %%PACK_%%p%%
  findstr /c:"Round " /c:"process" "%LV%\timing.txt"
) >"%LV%\results.txt"
echo Round %E% finished at %TIME%: !CO! chains, !CAP_V! pairs, took !PHUT_V! minutes; !CON_V! rounds left, about !CON_G! hours !CON_P! minutes ^(the check not counted^).
echo Current numbers: "%LV%\results.txt"
exit /b 0

:kiem
if %GIAY_KT% LEQ 0 goto xong
set "K=%LV%\check"
if exist "%K%\totals.txt" goto xong
echo.
echo === Check: the tuned numbers play the original ones, %N% processes for %CHECK_MINUTES% minutes ^(%TIME%^) ===
if exist "%K%" rmdir /s /q "%K%"
mkdir "%K%"
call :chuan_bi "%K%" "%TRUOC%"
rem The original: the numbers at the start - start.lua, that is XOI's numbers or the mod's own numbers.
set /a PI=0
for /L %%k in (1,1,%N%) do (
  set /a PI+=1
  if !PI! GTR %NP% set /a PI=1
  set /a SEED=FIRST_SEED+500000+%%k
  copy /y "%LV%\start.lua" "%K%\p%%k\spsa_base.lua" >nul
  >>"%K%\p%%k\package.manifest" echo module=spsa_base^|spsa_base.lua
  >"%K%\p%%k\config.lua" echo return {command = "spsa", step = "check", !DT_CFG!start = "spsa_start", base = "spsa_base", games = 1000000, seconds = %GIAY_KT%, seed = !SEED!, limit = 9000}
  start "SPSA check - %%k" /MIN /%PRIORITY% cmd /c call "%SELF%" chay1 check %%k !SEED! !PI!
)
rem (With an opponent the tuned numbers play first and the original ones after: the SPSA_CHECK_BASE line is the last.)
set "DAU_KT=SPSA_CHECK "
if defined OPPONENT set "DAU_KT=SPSA_CHECK_BASE"
call :cho "%K%" "%DAU_KT%"
rem Adding up the results: all together, and per mod (process k uses mod number ((k-1) mod the number of mods) + 1).
rem (With an opponent: the tuned numbers - the "SPSA_CHECK " line - and the original - SPSA_CHECK_BASE - both played it.)
set /a TW=0, TL=0, TD=0, CO=0, PK=0, BW=0, BL=0, BD=0
for /L %%p in (1,1,%NP%) do set /a "W_%%p=0, L_%%p=0, D_%%p=0, BW_%%p=0, BL_%%p=0, BD_%%p=0"
for /L %%k in (1,1,%N%) do (
  set /a PK+=1
  if !PK! GTR %NP% set /a PK=1
  if exist "%K%\p%%k\out.txt" for /f "tokens=2,3,4" %%a in ('findstr /b /c:"SPSA_CHECK " "%K%\p%%k\out.txt"') do (
    set /a TW+=%%a, TL+=%%b, TD+=%%c, CO+=1
    set /a "W_!PK!+=%%a, L_!PK!+=%%b, D_!PK!+=%%c"
  )
  if exist "%K%\p%%k\out.txt" for /f "tokens=2,3,4" %%a in ('findstr /b /c:"SPSA_CHECK_BASE" "%K%\p%%k\out.txt"') do (
    set /a BW+=%%a, BL+=%%b, BD+=%%c
    set /a "BW_!PK!+=%%a, BL_!PK!+=%%b, BD_!PK!+=%%c"
  )
  rem (OPPONENT=classic on a mod with no AI scripts of its own: the two sets played each other there, spsa.lua says so.)
  if exist "%K%\p%%k\out.txt" findstr /c:"no AI scripts of the pack's own" "%K%\p%%k\out.txt" >nul 2>nul && set "TU_DANH_!PK!=1"
)
set /a TT=TW+TL
set /a PT=0
if !TT! GTR 0 set /a PT=TW*1000/TT
set /a P1=PT/10, P2=PT%%10
if defined OPPONENT (
  >"%K%\totals.txt" echo Against %OPPONENT%: tuned won !TW!, lost !TL!, drew !TD!; original won !BW!, lost !BL!, drew !BD! ^(!CO!/%N% processes^)
) else (
  >"%K%\totals.txt" echo Tuned won !TW!, original won !TL!, drawn !TD! ^(!CO!/%N% processes; tuned won !P1!.!P2!%% of the decided games^)
)
if %NP% GTR 1 for /L %%p in (1,1,%NP%) do call :in_mod %%p
type "%K%\totals.txt" >>"%LV%\results.txt"

:xong
rem Each mod's numbers: xoi-<mod>\tune.txt, and the package <mod>-xoi.zip (once after each run).
if not exist "%LV%\packed.txt" (
  echo.
  echo === Each mod's own numbers ===
  for /L %%p in (1,1,%NP%) do call :goi_so %%p
  >"%LV%\packed.txt" echo done
)
echo.
echo ===== Done. Results: "%LV%\results.txt" =====
type "%LV%\results.txt"
echo.
echo Send results.txt to whoever maintains the AI. Or use it right away: upload ^<mod^>-xoi.zip to the relay ^(same id as the
echo old mod^) - XOI plays that mod with the numbers just tuned ^("mod tuned" in the match^), INSANE keeps its own. A check above
echo under 50%% means do not upload: the new numbers are not yet better than the old ones.
if "%KHONG_DUNG%"=="" pause
exit /b 0

:loi
echo [ERROR] Stopped at round %E%. Fix the error, then run this file again to go on.
if "%KHONG_DUNG%"=="" pause
exit /b 1

rem --- Appends to file %2 the last line of a chain in file %1: its end line, or (process stopped midway) its last
rem report; neither there, nothing is added ---
:lay_chuoi
if not exist "%~1" exit /b 0
set "DONG="
for /f "delims=" %%l in ('findstr /c:"--SPSA_END" "%~1" 2^>nul') do set "DONG=%%l"
if not defined DONG for /f "delims=" %%l in ('findstr /c:"--SPSA_STATE" "%~1" 2^>nul') do set "DONG=%%l"
if not defined DONG exit /b 0
>>"%~2" echo !DONG!
set /a CO+=1
exit /b 0

rem --- The numbers just tuned for mod number %1: xoi-<mod>\tune.txt (the numbers before them kept as tune-previous.txt),
rem and <mod>-xoi.zip: a copy of the mod's zip file with xoi/tune.txt (and xoi/notes.txt, if train.bat has trained) next
rem to the data folder; the previous package kept as <mod>-xoi-previous.zip ---
:goi_so
set "XPACK=!PACK_%1!"
for %%z in ("!XPACK!") do (
  set "XDIR=%KIT%xoi-%%~nz"
  set "XOUT=%%~dpnz-xoi.zip"
  set "XTRUOC=%%~dpnz-xoi-previous.zip"
)
if not exist "!XDIR!" mkdir "!XDIR!"
if exist "!XDIR!\tune.txt" copy /y "!XDIR!\tune.txt" "!XDIR!\tune-previous.txt" >nul
copy /y "%TRUOC%" "!XDIR!\tune.txt" >nul
echo   %1. "!XDIR!\tune.txt"
set "XTUNE=!XDIR!\tune.txt"
set "XNOTES="
if exist "!XDIR!\notes.txt" set "XNOTES=!XDIR!\notes.txt"
set "XBRAIN="
if exist "!XDIR!\brain.txt" set "XBRAIN=!XDIR!\brain.txt"
if exist "!XOUT!" copy /y "!XOUT!" "!XTRUOC!" >nul
del /q "!XOUT!" 2>nul
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; Add-Type -AssemblyName System.IO.Compression; Add-Type -AssemblyName System.IO.Compression.FileSystem; Copy-Item -LiteralPath $env:XPACK -Destination $env:XOUT -Force; $z=[System.IO.Compression.ZipFile]::Open($env:XOUT,'Update'); try { $e=$z.Entries | Where-Object { $_.FullName -imatch '(^|[\\/])data[\\/]data\.txt$' } | Sort-Object { $_.FullName.Length } | Select-Object -First 1; if (-not $e) { throw 'the zip has no data/data.txt' }; $root=$e.FullName.Substring(0, $e.FullName.Length - 13); foreach ($f in @(@($env:XNOTES, 'xoi/notes.txt'), @($env:XTUNE, 'xoi/tune.txt'), @($env:XBRAIN, 'xoi/brain.txt'))) { if ($f[0] -and (Test-Path -LiteralPath $f[0])) { $name=$root + $f[1]; foreach ($old in @($z.Entries | Where-Object { $_.FullName -ieq $name })) { $old.Delete() }; [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($z, $f[0], $name); Write-Host ('     Added ' + $name) } } } finally { $z.Dispose() }" 2>nul
if exist "!XOUT!" (echo      Packed: "!XOUT!") else (echo      [ERROR] Could not pack it - by hand: open the mod's zip file, go into the folder that holds the data folder, make a folder named xoi, copy "!XDIR!\tune.txt" into it.)
exit /b 0

rem --- The check's result for mod number %1 ---
:in_mod
set "TEN=!PACK_%1!"
for %%n in ("!TEN!") do set "TEN=%%~nxn"
set /a "MT=W_%1+L_%1, MP=0"
if !MT! GTR 0 set /a "MP=W_%1*1000/MT"
set /a "M1=MP/10, M2=MP %% 10"
set "KIEU=tu"
set "GHI_TU="
if defined OPPONENT if not defined TU_DANH_%1 set "KIEU=doithu"
if defined OPPONENT if defined TU_DANH_%1 set "GHI_TU= - no AI scripts of its own, the two sets played each other"
if "!KIEU!"=="doithu" (
  >>"%K%\totals.txt" echo   %1. !TEN!: tuned won !W_%1! lost !L_%1! drew !D_%1!; original won !BW_%1! lost !BL_%1! drew !BD_%1!
) else (
  >>"%K%\totals.txt" echo   %1. !TEN!: tuned won !W_%1!, original won !L_%1!, drawn !D_%1! ^(!M1!.!M2!%%^)!GHI_TU!
)
exit /b 0

rem --- K_DAU after the round in folder %1: the pairs every chain had played by the end of that round, after.txt (the
rem merge's SPSA_K) - with no file, or a broken one (PC cut off while writing) that is no whole number, the estimate K_NOM is added ---
:doc_k
set "K_FILE="
if exist "%~1\after.txt" set /p K_FILE=<"%~1\after.txt"
set "K_THUA="
if defined K_FILE for /f "delims=0123456789" %%x in ("!K_FILE!") do set "K_THUA=%%x"
set "K_HOP_LE="
if defined K_FILE if not defined K_THUA set "K_HOP_LE=1"
if defined K_HOP_LE (set /a K_DAU=K_FILE) else set /a K_DAU+=K_NOM
exit /b 0

rem --- Seconds since midnight by the clock into variable %1 (%TIME% is hours:minutes:seconds; an hour under 10 has a leading space) ---
:giay
set "T_=%TIME: =0%"
set /a "%1=(1%T_:~0,2%-100)*3600+(1%T_:~3,2%-100)*60+(1%T_:~6,2%-100)" 2>nul
exit /b 0

rem --- A folder p<k> for every process: the bench, a copy of smart_ai.lua (the "minus" player), the starting numbers ---
:chuan_bi
for /L %%k in (1,1,%N%) do (
  mkdir "%~1\p%%k" 2>nul
  del /q "%~1\p%%k\done.txt" 2>nul
  call :ban_bench "%~1\p%%k"
  copy /y "%LV%\scripts\base\game\smart_ai.lua" "%~1\p%%k\spsa_alt.lua" >nul
  copy /y "%~2" "%~1\p%%k\spsa_start.lua" >nul
  >>"%~1\p%%k\package.manifest" echo module=spsa_alt^|spsa_alt.lua
  >>"%~1\p%%k\package.manifest" echo module=spsa_start^|spsa_start.lua
)
exit /b 0

:ban_bench
pushd "%BENCH%"
copy /y *.lua "%~1\" >nul
copy /y package.manifest "%~1\" >nul
popd
exit /b 0

rem --- Waits for every process to finish: the end line %2 in out.txt, or done.txt (game closed, after an error too) ---
rem (THU_WINE: the end line only - when this file is tried under Wine, cmd does not wait for the game to finish.)
:cho
set /a CHO=0, NHIP=-1
call :giay CHO_TU
if not defined DOI_THEM set /a DOI_THEM=300
:cho_tiep
ping -n 6 127.0.0.1 >nul 2>&1
set /a XONG=0, TOT=0
for /L %%k in (1,1,%N%) do (
  set "X="
  set "Y="
  if exist "%~1\p%%k\out.txt" findstr /c:"%~2" "%~1\p%%k\out.txt" >nul 2>&1 && set "Y=1"
  if defined Y set "X=1"
  if not defined THU_WINE if exist "%~1\p%%k\done.txt" set "X=1"
  if defined X set /a XONG+=1
  if defined Y set /a TOT+=1
)
if !XONG! GEQ %N% exit /b 0
set /a CHO+=5
rem Once half the processes have finished (end line present) the mark is set: a process still running past twice that
rem mark, and past at least 5 minutes (DOI_THEM seconds) after it, counts as stuck (the game frozen, or a Windows error
rem box) - it is stopped and the finished processes are used, so one stuck window does not hold the whole night. (Every
rem process stops by the clock, at the same time, so a few seconds apart is the most they differ.)
set /a "NUA=TOT*2"
if !NUA! GEQ %N% if !NHIP! LSS 0 set /a NHIP=CHO
if !NHIP! GEQ 0 (
  set /a "HAN=NHIP*2, HAN2=NHIP+DOI_THEM"
  if !HAN2! GTR !HAN! set /a HAN=HAN2
  if !CHO! GEQ !HAN! (
    set /a CON_LAI=N-XONG
    echo   [NOTE] !CON_LAI! processes have run far too long ^(over twice the other half^) - stopping them, going on with !XONG!/%N% processes.
    call :dung_treo "%~1"
    exit /b 0
  )
)
set /a PHUT=CHO%%60
rem Every minute: progress report (by the real clock: with many processes one pass over the results takes longer than
rem 5 seconds, so counting passes runs slow); no openlf2.exe running yet some still missing means a process window was
rem closed - stop waiting.
if !PHUT! EQU 0 (
  call :giay BAY_GIO
  set /a "M_=((BAY_GIO-CHO_TU+86400) %% 86400)/60"
  echo   ... !XONG!/%N% processes done, waited !M_! minutes ^(!TIME:~0,8!^)
  if not defined KHONG_TASKLIST (
    tasklist /FI "IMAGENAME eq openlf2.exe" 2>nul | find /I "openlf2.exe" >nul || (echo   [NOTE] No game is running any more - skipping the unfinished processes.& exit /b 0)
  )
)
goto cho_tiep

rem --- Stops the games of the unfinished processes in folder %1 (found by their --mod "...\p<k>" path; the window closes by itself) ---
:dung_treo
for /L %%k in (1,1,%N%) do (
  if not exist "%~1\p%%k\done.txt" (
    set "TREO=%~1\p%%k"
    >>"%LV%\timing.txt" echo   Stopped a stuck process: !TREO!
    powershell -NoProfile -Command "Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'openlf2.exe' -and $_.CommandLine -and $_.CommandLine.Contains($env:TREO + [char]34) } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }" >nul 2>&1
  )
)
exit /b 0

rem --- Waits for line %2 to appear in file %1 (about a minute at most) ---
:cho_dong
set /a CD=0
:cho_dong_tiep
findstr /c:"%~2" "%~1" >nul 2>&1 && exit /b 0
set /a CD+=1
if !CD! GEQ 30 exit /b 1
ping -n 3 127.0.0.1 >nul 2>&1
goto cho_dong_tiep

rem --- One process: the game runs in the background; %2 round-N or check, %3 process number, %4 seed, %5 mod number
rem (LV, GAME_DA_CHON, XS_DA_CHON, PACK_n: from the main window); the window closes when done ---
:chay1
set "DIR=%LV%\%~2\p%~3"
set "P=!PACK_%~5!"
"%GAME_DA_CHON%" --pack "!P!" %XS_DA_CHON% --mod "!DIR!" --seed %~4 --input-trace "" >"!DIR!\out.txt" 2>&1
>"!DIR!\done.txt" echo done
exit
