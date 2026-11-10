@echo off
setlocal EnableDelayedExpansion
rem BRAIN - XOI learns a small "brain" (a neural network) from its own games: each time it is about to start a move,
rem the brain predicts what the move will bring (HP dealt minus HP taken over the next 1.5 seconds), and XOI weighs
rem that prediction with the score it works out itself when choosing a move. The brain learns from recorded data:
rem every move XOI starts over thousands of games, with the situation, the move and what came of it; then it is
rem trained inside the game (a few minutes per million moves). (OpenLF2 package 67 or later.)
rem Each round: the processes record data for RECORD_MINUTES minutes (XOI against the mod's own AI - ai\<id>.as
rem scripts, Sauce's AI - when it has one, else against itself); the data of every round so far is gathered; one brain
rem is trained per mod; the next round XOI records with the brain just learned. At the end a check: XOI with the brain
rem and XOI without it play the same opponent, wins/losses go to brain\results.txt (send that file to whoever
rem maintains the AI). Each mod's brain: xoi-<mod>\brain.txt, and <mod>-xoi.zip = the mod with the brain (and XOI's
rem numbers and notes, if it has them) - uploaded to the relay or published, XOI plays that mod with the brain ("brain"
rem beside XOI in the match).
rem To pause: close this window and the minimized ones. Running the file again goes on from the unfinished round
rem (recorded data is kept). To learn further: raise ROUNDS and run again - it goes on from the next round with all the
rem data so far, the new round recorded with the newest brain. To start over: delete the brain folder (round 1 then
rem records with the brain already in xoi-<mod>, if there is one).
rem ============ SETTINGS ============
rem The installed game. Empty: found automatically (Install for me only, all users, or an OpenLF2 folder beside this file).
set "GAME="
rem The mod's zip file. Empty: EVERY mod .zip beside this file (except lf2-online-upload packages, xoi-kit, and
rem <mod>-xoi.zip when <mod>.zip lies beside it), the processes shared out over the mods (one brain per mod); a zip file
rem dragged onto this file: that mod only. The original or the <mod>-xoi.zip of spsa.bat/train.bat both do: XOI records
rem with the numbers (tune.txt) and the notes (notes.txt) of the folder xoi-<mod> beside this file when it exists, else
rem with those inside the zip; a brain inside the zip (xoi/brain.txt) is the starting brain when xoi-<mod> has none.
rem Results go to xoi-<mod>\brain.txt and <mod>-xoi.zip (a -xoi zip given is updated itself, the earlier one kept as -xoi-previous.zip).
set "PACK="
rem Rounds (ROUNDS) and recording minutes per round (RECORD_MINUTES). Round 1 records with XOI as it is; from round 2
rem XOI records with the brain just learned, so the brain learns its new play too. One process records about 2,000
rem moves a minute: 2 rounds x 20 minutes on an 80-thread machine is about 6 million moves (2.5 GB of data, about an
rem hour of training).
set "ROUNDS=2"
set "RECORD_MINUTES=20"
set "PARALLEL=%NUMBER_OF_PROCESSORS%"
rem Minutes of the final check (0 = skip): half the processes play XOI with the brain against the opponent, the other
rem half XOI without it.
set "CHECK_MINUTES=10"
rem Process priority: BELOWNORMAL (the PC stays usable while it runs), LOW, or NORMAL
set "PRIORITY=BELOWNORMAL"
rem First seed (the same seed replays the same run)
set "FIRST_SEED=7000"
rem The brain: neurons in the middle layer (HIDDEN) and passes over the whole data (EPOCHS). 48 and 8 are enough;
rem more takes longer to learn.
set "HIDDEN=48"
set "EPOCHS=8"
rem The tools\ai-bench and scripts folders of package 67 or later (empty: found beside this .bat file)
set "BENCH="
set "SCRIPTS="
rem =====================================
rem Your own settings, kept across kit updates: a file brain-settings.bat beside this one (make it yourself), one
rem setting a line as above, e.g.  set "ROUNDS=3"  - copying a new brain.bat over the old one keeps what is in there.
if exist "%~dp0brain-settings.bat" (
  call "%~dp0brain-settings.bat"
  if /i not "%~1"=="chay1" echo Your settings: brain-settings.bat
)

rem (This file calls itself for each process, in its own window: cmd /c call "<this file>" chay1 <folder>
rem <process number> <seed> <mod number>. No quotes beyond the file name: with a path holding spaces, Windows drops
rem the first and last quote.)
if /i "%~1"=="chay1" goto chay1

set "SELF=%~f0"
set "KIT=%~dp0"
set "LV=%~dp0brain"
rem --- The mods: dragged, the PACK line, or every mod zip beside this file ---
set /a NP=0
if not "%~1"=="" if /i "%~x1"==".zip" if exist "%~f1" (
  set /a NP=1
  set "PACK_1=%~f1"
)
if !NP! EQU 0 if defined PACK (
  set /a NP=1
  for %%z in ("!PACK!") do set "PACK_1=%%~fz"
)
if !NP! EQU 0 (
  pushd "%~dp0"
  for %%z in (*.zip) do (
    set "TEN=%%~nz"
    set "BO="
    if /i "!TEN:~-4!"=="-xoi" if exist "!TEN:~0,-4!.zip" set "BO=1"
    if /i "!TEN:~-13!"=="-xoi-previous" set "BO=1"
    if /i "!TEN:~-10!"=="-xoi-truoc" set "BO=1"
    if /i "!TEN:~0,17!"=="lf2-online-upload" set "BO=1"
    if /i "!TEN:~0,7!"=="xoi-kit" set "BO=1"
    if not defined BO (
      set /a NP+=1
      set "PACK_!NP!=%%~fz"
    )
  )
  popd
)
if !NP! EQU 0 (echo No mod zip file found: put the mod's zip beside this file, drag it onto this file, or set the PACK line at the top.& pause& exit /b 1)
rem (The mod's name: the file name less a -xoi ending, so that the <mod>-xoi.zip of spsa.bat/train.bat shares xoi-<mod> with the original.)
for /L %%p in (1,1,%NP%) do call :ten_mod %%p

rem --- The game, the bench, the scripts ---
if not defined GAME (
  for %%g in ("%LOCALAPPDATA%\Programs\OpenLF2\openlf2.exe" "%ProgramFiles(x86)%\OpenLF2\openlf2.exe" "%ProgramFiles%\OpenLF2\openlf2.exe" "%~dp0OpenLF2\openlf2.exe") do (
    if not defined GAME if exist "%%~g" set "GAME=%%~g"
  )
)
if not defined GAME set "GAME=%LOCALAPPDATA%\Programs\OpenLF2\openlf2.exe"
if not defined BENCH (
  if exist "%~dp0tools\ai-bench\record.lua" set "BENCH=%~dp0tools\ai-bench"
  if exist "%~dp0record.lua" set "BENCH=%~dp0."
  if exist "%~dp0..\record.lua" set "BENCH=%~dp0.."
)
if not defined SCRIPTS (
  if exist "%~dp0scripts\base\game\smart_ai.lua" set "SCRIPTS=%~dp0scripts"
  if exist "%~dp0..\..\..\scripts\base\game\smart_ai.lua" set "SCRIPTS=%~dp0..\..\..\scripts"
)
if not exist "%GAME%" (echo Game not found at "%GAME%": install OpenLF2 ^(OpenLF2-Windows-x64.exe under Releases on the project's GitHub page, choose Install for me only^), or set the GAME line at the top.& pause& exit /b 1)
if not defined BENCH (echo No tools\ai-bench folder with record.lua found - the XOI kit or package 67 or later is needed.& pause& exit /b 1)
if not exist "%BENCH%\train.lua" (echo "%BENCH%\train.lua" not found - the XOI kit or package 67 or later is needed.& pause& exit /b 1)
if not defined SCRIPTS (echo No scripts folder found beside this file - the XOI kit or package 67 or later is needed.& pause& exit /b 1)
findstr /c:"brain_kit" "%SCRIPTS%\base\game\smart_ai.lua" >nul 2>nul || (echo "%SCRIPTS%\base\game\smart_ai.lua" has no brain ^(brain_kit^) - the XOI kit or package 67 or later is needed.& pause& exit /b 1)
set /a N=PARALLEL
if %N% LSS 1 set /a N=1
set /a RAM_GB=0
if "%PARALLEL%"=="%NUMBER_OF_PROCESSORS%" for /f %%m in ('powershell -NoProfile -Command "[int][math]::Floor((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)" 2^>nul') do set /a RAM_GB=%%m 2>nul
if !RAM_GB! GEQ 2 (
  set /a "TOI_DA=(RAM_GB-4)*10/6"
  if !TOI_DA! LSS 1 set /a TOI_DA=1
  if !TOI_DA! LSS %N% (
    echo This PC has !RAM_GB! GB of RAM: running !TOI_DA! processes instead of %N% ^(each takes up to about 0.6 GB^).
    set /a N=TOI_DA
  )
)
if %N% LSS %NP% set /a N=NP
set /a GIAY_GHI=RECORD_MINUTES*60, GIAY_KT=CHECK_MINUTES*60
if defined TEST_SECONDS set /a GIAY_GHI=TEST_SECONDS, GIAY_KT=TEST_SECONDS
if %GIAY_GHI% LSS 10 set /a GIAY_GHI=10
if not defined PRIORITY set "PRIORITY=NORMAL"
if not exist "%LV%" mkdir "%LV%"
rem The installed game's scripts, updated with the package's (a package may hold only the changed files): no reinstall.
if not exist "%LV%\scripts\base\game\smart_ai.lua" (
  for %%g in ("%GAME%") do set "CAI=%%~dpgscripts"
  if exist "!CAI!\base\game\match.lua" xcopy /e /i /q /y "!CAI!" "%LV%\scripts" >nul
  xcopy /e /i /q /y "%SCRIPTS%" "%LV%\scripts" >nul
)
if not exist "%LV%\scripts\base\game\match.lua" (echo [ERROR] Could not merge the scripts into "%LV%\scripts".& pause& exit /b 1)
set XS=--scripts "%LV%\scripts"

echo Mods ^(%NP%^):
for /L %%p in (1,1,%NP%) do call echo   %%p. %%PACK_%%p%%  [xoi-%%TEN_%%p%%]
echo %ROUNDS% rounds x %RECORD_MINUTES% minutes of recording, %N% processes ^(priority %PRIORITY%^); results go to "%LV%"
echo To pause: close this window and the minimized ones. Running this file again goes on from there.
echo To run overnight: turn off Windows sleep ^(Settings - System - Power - Sleep: Never^).

set "GAME_DA_CHON=%GAME%"
set XS_DA_CHON=%XS%
rem Each mod's working copy: brain\mod-<p>.zip = the mod's zip file with xoi-<mod>'s numbers and notes laid in (when it has
rem them) and the brain inside the zip taken out (a brain comes in through the config only, so that the check's "without
rem the brain" is without one). The recording and check processes play this copy; it is made anew on every run (new
rem numbers from spsa.bat count at once).
rem (Wine's cmd, which tries this file, cannot expand !PACK_%%p!: call set and subroutines are used for such names.)
set "BM_LOI="
for /L %%p in (1,1,%NP%) do call :lam_ban_mod %%p
if defined BM_LOI (
  if "%KHONG_DUNG%"=="" pause
  exit /b 1
)
rem (A brain each mod has from an earlier run: round 1 records with it, as later rounds do.)
for /L %%p in (1,1,%NP%) do call :nao_dau %%p

set /a E=1
:luot_tiep
if %E% GTR %ROUNDS% goto kiem
set "D=%LV%\round-%E%"
if exist "%D%\round-done.txt" (
  rem (A finished round: its brain.)
  for /L %%p in (1,1,%NP%) do if exist "%D%\brain-%%p.txt" set "NAO_%%p=%D%\brain-%%p.txt"
  set /a E+=1
  goto luot_tiep
)
call :mot_luot
if errorlevel 1 goto loi
set /a E+=1
goto luot_tiep

:mot_luot
echo.
echo === Round %E%/%ROUNDS%: %N% processes recording for %RECORD_MINUTES% minutes ^(%TIME%^) ===
call :giay BAT_DAU
rem Recording (a process that finished earlier - a RECORD line - is kept, not recorded again).
set /a XONG_N=0
if exist "%D%" for /L %%k in (1,1,%N%) do if exist "%D%\p%%k\out.txt" (
  findstr /c:"RECORD " "%D%\p%%k\out.txt" >nul 2>nul && set /a XONG_N+=1
)
if !XONG_N! GEQ %N% (
  echo   ^(recorded earlier^)
  goto hoc_luot
)
if not exist "%D%" mkdir "%D%"
set /a PI=0
for /L %%k in (1,1,%N%) do (
  set /a PI+=1
  if !PI! GTR %NP% set /a PI=1
  set "DA="
  if exist "%D%\p%%k\out.txt" findstr /c:"RECORD " "%D%\p%%k\out.txt" >nul 2>nul && set "DA=1"
  if not defined DA (
    mkdir "%D%\p%%k" 2>nul
    del /q "%D%\p%%k\done.txt" 2>nul
    del /q "%D%\p%%k\out.txt" 2>nul
    del /q "%D%\p%%k\gathered.txt" 2>nul
    call :ban_bench "%D%\p%%k"
    copy /y "%LV%\scripts\base\game\smart_ai.lua" "%D%\p%%k\hs_alt.lua" >nul
    >>"%D%\p%%k\package.manifest" echo module=hs_alt^|hs_alt.lua
    set "NAO_CFG="
    call set "NAO_NAY=%%NAO_!PI!%%"
    if defined NAO_NAY (
      call :nao_lua "!NAO_NAY!" "%D%\p%%k\xoi_brain.lua"
      >>"%D%\p%%k\package.manifest" echo module=xoi_brain^|xoi_brain.lua
      set NAO_CFG=brain = {module = "xoi_brain", on = {1}},
    )
    set /a SEED=FIRST_SEED+E*1000+%%k
    >"%D%\p%%k\config.lua" echo return {command = "record", alt = "hs_alt", !NAO_CFG! games = 1000000, seconds = %GIAY_GHI%, seed = !SEED!, limit = 9000}
    start "Brain - round %E% - %%k" /MIN /%PRIORITY% cmd /c call "%SELF%" chay1 round-%E% %%k !SEED! !PI!
  )
)
call :cho "%D%" "RECORD "
:hoc_luot
rem Gathering this round's data: process k's REC lines into data\<mod>\round-%E%-p<k>.txt (the whole file written
rem again, so a rerun does not gather twice), then taken out of out.txt to keep it small.
set /a PI=0
for /L %%k in (1,1,%N%) do (
  set /a PI+=1
  if !PI! GTR %NP% set /a PI=1
  if not exist "%LV%\data\!PI!" mkdir "%LV%\data\!PI!"
  if exist "%D%\p%%k\out.txt" if not exist "%D%\p%%k\gathered.txt" (
    findstr /b /c:"REC " "%D%\p%%k\out.txt" >"%LV%\data\!PI!\round-%E%-p%%k.tmp"
    move /y "%LV%\data\!PI!\round-%E%-p%%k.tmp" "%LV%\data\!PI!\round-%E%-p%%k.txt" >nul
    >"%D%\p%%k\gathered.txt" echo done
    findstr /v /b /c:"REC " "%D%\p%%k\out.txt" >"%D%\p%%k\out-short.txt"
    move /y "%D%\p%%k\out-short.txt" "%D%\p%%k\out.txt" >nul
  )
)
rem Each mod's data (every round) packed into a training pack, then trained - one process per mod.
echo === Training a brain for each mod ^(%TIME%^) ===
set /a DONG_TONG=0
for /L %%p in (1,1,%NP%) do (
  set "H=%D%\train%%p"
  set "DA="
  if exist "!H!\out.txt" findstr /b /c:"XOI_BRAIN b2" "!H!\out.txt" >nul 2>nul && set "DA=1"
  set /a DONG_%%p=0
  if not defined DA (
    mkdir "!H!" 2>nul
    del /q "!H!\out.txt" 2>nul
    del /q "!H!\done.txt" 2>nul
    call :ban_bench "!H!"
    call :goi_du_lieu %%p "!H!\data.zip"
    >"!H!\config.lua" echo return {command = "train", epochs = %EPOCHS%, hidden = %HIDDEN%, weights = true, seed = %FIRST_SEED%}
  )
  if exist "!H!\count.txt" for /f %%c in ('type "!H!\count.txt"') do set /a DONG_%%p=%%c
  set /a DONG_TONG+=DONG_%%p
)
echo   Data: !DONG_TONG! moves ^(every round^)
if !DONG_TONG! LSS 200 (echo [ERROR] Too little data - did the processes run? See "%D%\p1\out.txt".& exit /b 1)
for /L %%p in (1,1,%NP%) do (
  set "DA="
  if exist "%D%\train%%p\out.txt" findstr /b /c:"XOI_BRAIN b2" "%D%\train%%p\out.txt" >nul 2>nul && set "DA=1"
  if not defined DA start "Brain - training %%p" /MIN /%PRIORITY% cmd /c call "%SELF%" chay1 round-%E%\train %%p %FIRST_SEED% %%p hoc
)
set "N_CU=%N%"
set /a N=NP
call :cho_hoc "%D%"
set /a N=N_CU
for /L %%p in (1,1,%NP%) do (
  set "H=%D%\train%%p"
  findstr /b /c:"XOI_BRAIN b2" "!H!\out.txt" >nul 2>nul || (echo [ERROR] Training mod %%p did not finish - see "!H!\out.txt".& exit /b 1)
  findstr /b /c:"XOI_BRAIN " "!H!\out.txt" >"%D%\brain-%%p.txt"
  set "NAO_%%p=%D%\brain-%%p.txt"
  set "DONG_BASE="
  set "DONG_NET="
  for /f "delims=" %%l in ('findstr /b /c:"BASE " "!H!\out.txt"') do set "DONG_BASE=%%l"
  for /f "delims=" %%l in ('findstr /b /c:"NET done" "!H!\out.txt"') do set "DONG_NET=%%l"
  call set "PK=%%PACK_%%p%%"
  call set "DN=%%DONG_%%p%%"
  for %%z in ("!PK!") do echo   %%p. %%~nxz: !DONG_BASE! / !DONG_NET!
  for %%z in ("!PK!") do >>"%LV%\timing.txt" echo Round %E%/%ROUNDS% mod %%p ^(%%~nxz^): !DN! moves; !DONG_BASE!; !DONG_NET!
  del /q "!H!\data.zip" 2>nul
)
call :giay HET
set /a "GIAY_V=(HET-BAT_DAU+86400) %% 86400, PHUT_V=GIAY_V/60"
>>"%LV%\timing.txt" echo Round %E%/%ROUNDS% done at %TIME%, took !PHUT_V! minutes
>"%D%\round-done.txt" echo done
rem (A new brain: the check and the packing are done again - also when run again with a higher ROUNDS to learn further.)
if exist "%LV%\check" rd /s /q "%LV%\check"
del /q "%LV%\packed.txt" 2>nul
exit /b 0

:kiem
rem The check: odd processes play XOI with the brain against the opponent, the even process right after each plays
rem XOI without the brain against the same opponent (the mod's AI when it has scripts, else XOI without a brain), same
rem mod, same seed.
if %GIAY_KT% LEQ 0 goto xong
set "K=%LV%\check"
if exist "%K%\totals.txt" goto xong
echo.
echo === Check: XOI with the brain and XOI without it, %N% processes for %CHECK_MINUTES% minutes ^(%TIME%^) ===
if not exist "%K%" mkdir "%K%"
for /L %%k in (1,1,%N%) do (
  set /a "PI=((%%k-1)/2) %% NP + 1, LE=%%k %% 2, SEED=FIRST_SEED+500000+(%%k+1)/2"
  set "DA="
  if exist "%K%\p%%k\out.txt" findstr /c:"RECORD " "%K%\p%%k\out.txt" >nul 2>nul && set "DA=1"
  if not defined DA (
    mkdir "%K%\p%%k" 2>nul
    del /q "%K%\p%%k\done.txt" 2>nul
    del /q "%K%\p%%k\out.txt" 2>nul
    call :ban_bench "%K%\p%%k"
    copy /y "%LV%\scripts\base\game\smart_ai.lua" "%K%\p%%k\hs_alt.lua" >nul
    >>"%K%\p%%k\package.manifest" echo module=hs_alt^|hs_alt.lua
    set "NAO_CFG="
    call set "NAO_NAY=%%NAO_!PI!%%"
    if !LE! EQU 1 if defined NAO_NAY (
      call :nao_lua "!NAO_NAY!" "%K%\p%%k\xoi_brain.lua"
      >>"%K%\p%%k\package.manifest" echo module=xoi_brain^|xoi_brain.lua
      set NAO_CFG=brain = {module = "xoi_brain", on = {1}},
    )
    >"%K%\p%%k\config.lua" echo return {command = "record", alt = "hs_alt", quiet = true, !NAO_CFG! games = 1000000, seconds = %GIAY_KT%, seed = !SEED!, limit = 9000}
    start "Brain - check %%k" /MIN /%PRIORITY% cmd /c call "%SELF%" chay1 check %%k !SEED! !PI!
  )
)
call :cho "%K%" "RECORD "
rem Adding up: odd processes = with the brain (CW/CL), even = without (KW/KL); per mod too.
set /a CW=0, CL=0, KW=0, KL=0
for /L %%p in (1,1,%NP%) do set /a "CW_%%p=0, CL_%%p=0, KW_%%p=0, KL_%%p=0"
for /L %%k in (1,1,%N%) do (
  set /a "PI=((%%k-1)/2) %% NP + 1, LE=%%k %% 2"
  rem (RECORD <games> games, <records> records, <name> won <w> lost <l> vs <o>: w is the 8th word, l the 10th)
  if exist "%K%\p%%k\out.txt" for /f "tokens=8,10" %%a in ('findstr /b /c:"RECORD " "%K%\p%%k\out.txt"') do (
    if !LE! EQU 1 (
      set /a CW+=%%a, CL+=%%b
      set /a "CW_!PI!+=%%a, CL_!PI!+=%%b"
    ) else (
      set /a KW+=%%a, KL+=%%b
      set /a "KW_!PI!+=%%a, KL_!PI!+=%%b"
    )
  )
)
call :phan_tram !CW! !CL! CP
call :phan_tram !KW! !KL! KP
>"%K%\totals.txt" echo XOI with the brain: won !CW! lost !CL! ^(!CP!%%^); XOI without it: won !KW! lost !KL! ^(!KP!%%^) - same opponent, same seeds
if %NP% GTR 1 for /L %%p in (1,1,%NP%) do call :tong_mod %%p
:xong
rem The results, and each mod's brain: xoi-<mod>\brain.txt, packed as <mod>-xoi.zip.
(
  echo Brain: %ROUNDS% rounds x %RECORD_MINUTES% minutes, %N% processes, HIDDEN=%HIDDEN% EPOCHS=%EPOCHS% FIRST_SEED=%FIRST_SEED%; mods:
  for /L %%p in (1,1,%NP%) do call echo   %%p. %%PACK_%%p%%
  if exist "%LV%\timing.txt" findstr /c:"Round " "%LV%\timing.txt"
  if exist "%K%\totals.txt" type "%K%\totals.txt"
) >"%LV%\results.txt"
if not exist "%LV%\packed.txt" (
  echo.
  echo === Each mod's brain ===
  for /L %%p in (1,1,%NP%) do call :goi_nao %%p
  >"%LV%\packed.txt" echo done
)
echo.
echo ===== Done. Results: "%LV%\results.txt" =====
type "%LV%\results.txt"
echo.
echo Send results.txt to whoever maintains the AI. To use the brain now: upload ^<mod^>-xoi.zip to the relay ^(same id as
echo the old mod^) or publish it - XOI plays that mod with the brain ^("brain" in the match^). If the check has XOI with the
echo brain winning less than XOI without it, do not upload. To learn further: raise ROUNDS ^(here or in brain-settings.bat^) and run again.
if "%KHONG_DUNG%"=="" pause
exit /b 0
:loi
echo [ERROR] Stopped in round %E%. Fix the error and run this file again to go on.
if "%KHONG_DUNG%"=="" pause
exit /b 1

rem --- The check line of mod %1 into totals.txt ---
:tong_mod
call :phan_tram !CW_%1! !CL_%1! CP
call :phan_tram !KW_%1! !KL_%1! KP
for %%z in ("!PACK_%1!") do >>"%K%\totals.txt" echo   %1. %%~nxz: with the brain won !CW_%1! lost !CL_%1! ^(!CP!%%^); without won !KW_%1! lost !KL_%1! ^(!KP!%%^)
exit /b 0
rem --- Win percentage (one decimal) of %1 won %2 lost into variable %3 ---
:phan_tram
set /a "PT_T=%1+%2, PT_V=0"
if !PT_T! GTR 0 set /a "PT_V=%1*1000/PT_T"
set /a "PT_1=PT_V/10, PT_2=PT_V %% 10"
set "%3=!PT_1!.!PT_2!"
exit /b 0
rem --- Brain file %1 (XOI_BRAIN ...) as Lua module %2: return {text = [==[ ... ]==]} ---
:nao_lua
>"%~2" echo return {text = [==[
type "%~1" >>"%~2"
>>"%~2" echo ]==]}
exit /b 0
rem --- Mod %1's data packed as training pack %2: a small zip with only data\data.txt and the .exe files at the mod's
rem root (enough for the game to open the pack), and xoi\data_<n>.txt = the REC lines of every round (each file under
rem 3.5 MB - a script reads a file of up to 4 MB). The line count goes to count.txt beside the pack. ---
:goi_du_lieu
set "GD_PACK=!PACK_%1!"
set "GD_OUT=%~2"
set "GD_DIR=%LV%\data\%1"
set "GD_CNT=%~dp2count.txt"
set "GD_P=%1"
del /q "%GD_OUT%" 2>nul
del /q "%GD_CNT%" 2>nul
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; Add-Type -AssemblyName System.IO.Compression; Add-Type -AssemblyName System.IO.Compression.FileSystem; $src=[System.IO.Compression.ZipFile]::OpenRead($env:GD_PACK); try { $e=$src.Entries | Where-Object { $_.FullName -imatch '(^|[\\/])data[\\/]data\.txt$' } | Sort-Object { $_.FullName.Length } | Select-Object -First 1; if (-not $e) { throw 'the zip has no data/data.txt' }; $root=$e.FullName.Substring(0, $e.FullName.Length - 13); $out=[System.IO.Compression.ZipFile]::Open($env:GD_OUT,'Create'); try { foreach ($x in $src.Entries) { if ($x.FullName.Length -le $root.Length) { continue }; if ($x.FullName.Substring(0, $root.Length) -ine $root) { continue }; $rel=$x.FullName.Substring($root.Length).Replace('\', '/'); if ($rel -ieq 'data/data.txt' -or $rel -imatch '^[^/]+\.exe$') { $n=$out.CreateEntry($rel); $i=$x.Open(); $o=$n.Open(); try { $i.CopyTo($o) } finally { $o.Dispose(); $i.Dispose() } } }; $limit=3500000; $k=0; $w=$null; $bytes=$limit; $count=0; foreach ($f in (Get-ChildItem -LiteralPath $env:GD_DIR -Filter 'round-*.txt' | Sort-Object Name)) { foreach ($line in [System.IO.File]::ReadLines($f.FullName)) { if (-not $line.StartsWith('REC ')) { continue }; if ($bytes + $line.Length + 1 -gt $limit) { if ($w) { $w.Dispose() }; $k++; $w=New-Object System.IO.StreamWriter(($out.CreateEntry('xoi/data_' + $k + '.txt')).Open()); $bytes=0 }; $w.Write($line); $w.Write([char]10); $bytes += $line.Length + 1; $count++ } }; if ($w) { $w.Dispose() }; [System.IO.File]::WriteAllText($env:GD_CNT, [string]$count + [char]13 + [char]10); Write-Host ('     Data of mod ' + $env:GD_P + ': ' + $count + ' lines, ' + $k + ' files in ' + $env:GD_OUT) } finally { $out.Dispose() } } finally { $src.Dispose() }"
if not exist "%GD_OUT%" echo      [ERROR] Could not pack the data of mod %1.
exit /b 0
rem --- Mod %1's brain: xoi-<mod>\brain.txt (the earlier one kept as brain-previous.txt), and <mod>-xoi.zip: a copy
rem of the mod's zip with xoi/brain.txt beside the data folder - and xoi-<mod>'s xoi/tune.txt and xoi/notes.txt, if any.
rem Given <mod>-xoi.zip itself, it is updated in place (the earlier one kept as <mod>-xoi-previous.zip). ---
:goi_nao
if not defined NAO_%1 (echo   %1. ^(no brain yet^)& exit /b 0)
set "XPACK=!PACK_%1!"
set "XTEN=!TEN_%1!"
for %%z in ("!XPACK!") do (
  set "XFULL=%%~fz"
  set "XDIR=%KIT%xoi-!XTEN!"
  set "XOUT=%%~dpz!XTEN!-xoi.zip"
  set "XTRUOC=%%~dpz!XTEN!-xoi-previous.zip"
)
set "XTAI_CHO="
if /i "!XFULL!"=="!XOUT!" set "XTAI_CHO=1"
if not exist "!XDIR!" mkdir "!XDIR!"
if exist "!XDIR!\brain.txt" copy /y "!XDIR!\brain.txt" "!XDIR!\brain-previous.txt" >nul
copy /y "!NAO_%1!" "!XDIR!\brain.txt" >nul
echo   %1. "!XDIR!\brain.txt"
set "XBRAIN=!XDIR!\brain.txt"
set "XTUNE="
if exist "!XDIR!\tune.txt" set "XTUNE=!XDIR!\tune.txt"
set "XNOTES="
if exist "!XDIR!\notes.txt" set "XNOTES=!XDIR!\notes.txt"
if exist "!XOUT!" copy /y "!XOUT!" "!XTRUOC!" >nul
if not defined XTAI_CHO del /q "!XOUT!" 2>nul
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; Add-Type -AssemblyName System.IO.Compression; Add-Type -AssemblyName System.IO.Compression.FileSystem; if (-not $env:XTAI_CHO) { Copy-Item -LiteralPath $env:XPACK -Destination $env:XOUT -Force }; $z=[System.IO.Compression.ZipFile]::Open($env:XOUT,'Update'); try { $e=$z.Entries | Where-Object { $_.FullName -imatch '(^|[\\/])data[\\/]data\.txt$' } | Sort-Object { $_.FullName.Length } | Select-Object -First 1; if (-not $e) { throw 'the zip has no data/data.txt' }; $root=$e.FullName.Substring(0, $e.FullName.Length - 13); foreach ($f in @(@($env:XNOTES, 'xoi/notes.txt'), @($env:XTUNE, 'xoi/tune.txt'), @($env:XBRAIN, 'xoi/brain.txt'))) { if ($f[0] -and (Test-Path -LiteralPath $f[0])) { $name=$root + $f[1]; foreach ($old in @($z.Entries | Where-Object { $_.FullName -ieq $name })) { $old.Delete() }; [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($z, $f[0], $name); Write-Host ('     Added ' + $name) } } } finally { $z.Dispose() }" 2>nul
set "XLOI="
if errorlevel 1 set "XLOI=1"
if not exist "!XOUT!" set "XLOI=1"
if defined XLOI (echo      [ERROR] Could not pack it - by hand: open the mod's zip file, go into the folder that holds the data folder, make a folder named xoi, copy "!XDIR!\brain.txt" into it.) else if defined XTAI_CHO (echo      Updated: "!XOUT!" - the earlier one: "!XTRUOC!") else (echo      Packed: "!XOUT!")
exit /b 0
rem --- Mod %1's name (TEN_<p>): the zip file's name less a -xoi ending ---
:ten_mod
for %%z in ("!PACK_%1!") do set "T_=%%~nz"
if /i "!T_:~-4!"=="-xoi" set "T_=!T_:~0,-4!"
set "TEN_%1=!T_!"
exit /b 0
rem --- Mod %1's starting brain (NAO_<p>): xoi-<mod>\brain.txt; or the folder named after the file name with its -xoi
rem ending (package 67's brain.bat did so); or the brain inside the zip (lam_ban_mod takes it out as zip-brain-<p>.txt) ---
:nao_dau
set "NAO_%1="
set "ND_=%KIT%xoi-!TEN_%1!\brain.txt"
if exist "!ND_!" set "NAO_%1=!ND_!"
if not defined NAO_%1 for %%z in ("!PACK_%1!") do if exist "%KIT%xoi-%%~nz\brain.txt" set "NAO_%1=%KIT%xoi-%%~nz\brain.txt"
if not defined NAO_%1 if exist "%LV%\zip-brain-%1.txt" set "NAO_%1=%LV%\zip-brain-%1.txt"
if defined NAO_%1 echo Mod %1 starts from its brain so far: "!NAO_%1!"
exit /b 0
rem --- Mod %1's working copy: brain\mod-<p>.zip = a copy of the mod's zip; xoi/tune.txt and xoi/notes.txt replaced by
rem xoi-<mod>'s when it has them; xoi/brain.txt taken out (kept as zip-brain-<p>.txt when xoi-<mod> has no brain yet) ---
:lam_ban_mod
set "BM_PACK=!PACK_%1!"
set "BM_OUT=%LV%\mod-%1.zip"
set "BM_DIR=%KIT%xoi-!TEN_%1!"
set "BM_NAO=%LV%\zip-brain-%1.txt"
set "BM_P=%1"
del /q "%BM_OUT%" 2>nul
del /q "%BM_NAO%" 2>nul
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; Add-Type -AssemblyName System.IO.Compression; Add-Type -AssemblyName System.IO.Compression.FileSystem; Copy-Item -LiteralPath $env:BM_PACK -Destination $env:BM_OUT -Force; $z=[System.IO.Compression.ZipFile]::Open($env:BM_OUT,'Update'); try { $e=$z.Entries | Where-Object { $_.FullName -imatch '(^|[\\/])data[\\/]data\.txt$' } | Sort-Object { $_.FullName.Length } | Select-Object -First 1; if (-not $e) { throw 'the zip has no data/data.txt' }; $root=$e.FullName.Substring(0, $e.FullName.Length - 13); $what=@(); $kitbrain=Join-Path $env:BM_DIR 'brain.txt'; foreach ($old in @($z.Entries | Where-Object { $_.FullName -ieq ($root + 'xoi/brain.txt') })) { if (-not (Test-Path -LiteralPath $kitbrain) -and -not (Test-Path -LiteralPath $env:BM_NAO)) { [System.IO.Compression.ZipFileExtensions]::ExtractToFile($old, $env:BM_NAO, $true); $what += 'the brain inside the zip: the starting brain' } else { $what += 'the brain inside the zip: taken out' }; $old.Delete() }; foreach ($f in @(@('tune.txt', 'numbers'), @('notes.txt', 'notes'))) { $src=Join-Path $env:BM_DIR $f[0]; if (Test-Path -LiteralPath $src) { $name=$root + 'xoi/' + $f[0]; foreach ($old in @($z.Entries | Where-Object { $_.FullName -ieq $name })) { $old.Delete() }; [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($z, $src, $name); $what += ($f[1] + ' of xoi-<mod>') } elseif (@($z.Entries | Where-Object { $_.FullName -ieq ($root + 'xoi/' + $f[0]) }).Count -gt 0) { $what += ($f[1] + ' inside the zip') } }; if ($what.Count -eq 0) { $what += 'no numbers, notes or brain' }; Write-Host ('  Mod ' + $env:BM_P + ': ' + ($what -join ', ')) } finally { $z.Dispose() }"
if not exist "%BM_OUT%" (echo [ERROR] Could not make mod %1's working copy ^("%BM_PACK%"^) - does the zip file open?& set "BM_LOI=1")
exit /b 0
rem --- Seconds since midnight by the clock into variable %1 ---
:giay
set "T_=%TIME: =0%"
set /a "%1=(1%T_:~0,2%-100)*3600+(1%T_:~3,2%-100)*60+(1%T_:~6,2%-100)" 2>nul
exit /b 0
:ban_bench
pushd "%BENCH%"
copy /y *.lua "%~1\" >nul
copy /y package.manifest "%~1\" >nul
popd
exit /b 0
rem --- Wait for every process p1..pN in %1 to finish: line %2 in out.txt, or done.txt (the game closed, errors too) ---
rem (THU_WINE: the out.txt line only - when this file is tried under Wine, cmd does not wait for the game.)
:cho
set /a CHO=0
call :giay CHO_TU
:cho_tiep
ping -n 6 127.0.0.1 >nul 2>&1
set /a XONG=0
for /L %%k in (1,1,%N%) do (
  set "X="
  if exist "%~1\p%%k\out.txt" findstr /c:"%~2" "%~1\p%%k\out.txt" >nul 2>&1 && set "X=1"
  if not defined THU_WINE if exist "%~1\p%%k\done.txt" set "X=1"
  if defined X set /a XONG+=1
)
if !XONG! GEQ %N% exit /b 0
set /a CHO+=5
set /a PHUT=CHO%%60
if !PHUT! EQU 0 (
  call :giay BAY_GIO
  set /a "M_=((BAY_GIO-CHO_TU+86400) %% 86400)/60"
  echo   ... !XONG!/%N% processes done, waited !M_! minutes ^(!TIME:~0,8!^)
  if not defined KHONG_TASKLIST (
    tasklist /FI "IMAGENAME eq openlf2.exe" 2>nul | find /I "openlf2.exe" >nul || (echo   [NOTE] No game is running any more - skipping the unfinished processes.& exit /b 0)
  )
)
goto cho_tiep
rem --- Wait for the training processes train1..trainN in %1 (the XOI_BRAIN b2 line, or done.txt) ---
:cho_hoc
set /a CHO=0
call :giay CHO_TU
:cho_hoc_tiep
ping -n 6 127.0.0.1 >nul 2>&1
set /a XONG=0
for /L %%p in (1,1,%N%) do (
  set "X="
  if exist "%~1\train%%p\out.txt" findstr /b /c:"XOI_BRAIN b2" "%~1\train%%p\out.txt" >nul 2>&1 && set "X=1"
  if not defined THU_WINE if exist "%~1\train%%p\done.txt" set "X=1"
  if defined X set /a XONG+=1
)
if !XONG! GEQ %N% exit /b 0
set /a CHO+=5
set /a PHUT=CHO%%60
if !PHUT! EQU 0 (
  call :giay BAY_GIO
  set /a "M_=((BAY_GIO-CHO_TU+86400) %% 86400)/60"
  echo   ... training: !XONG!/%N% done, waited !M_! minutes ^(!TIME:~0,8!^)
  if not defined KHONG_TASKLIST (
    tasklist /FI "IMAGENAME eq openlf2.exe" 2>nul | find /I "openlf2.exe" >nul || (echo   [NOTE] No game is running any more - skipping.& exit /b 0)
  )
)
goto cho_hoc_tiep

rem --- One process: the game runs headless; %2 the folder (round-N, check, or round-N\train), %3 the process number,
rem %4 the seed, %5 the mod number, %6 "hoc" = training (that mod's data pack as the mod); the window closes when done ---
:chay1
if /i "%~6"=="hoc" (
  set "DIR=%LV%\%~2%~3"
  set "P=!DIR!\data.zip"
) else (
  set "DIR=%LV%\%~2\p%~3"
  set "P=%LV%\mod-%~5.zip"
)
"%GAME_DA_CHON%" --pack "!P!" %XS_DA_CHON% --mod "!DIR!" --seed %~4 --input-trace "" >"!DIR!\out.txt" 2>&1
>"!DIR!\done.txt" echo done
exit
