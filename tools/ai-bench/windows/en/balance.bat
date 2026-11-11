@echo off
setlocal EnableDelayedExpansion
rem BALANCE - measures the win rate of each fighter of a mod against every other fighter, and which of its moves deal
rem the damage (OpenLF2 package 77 or later). One computer player plays both sides (XOI by default); every pair of
rem fighters plays on both sides, on the same stage, from the same point of the random sequence, again and again on
rem every CPU thread. Results: the folder balance-<mod>\ next to this file (another player than XOI:
rem balance-<mod>-<player>\): report.html (open it in a browser: the ranking with its margins, the matchup chart,
rem every move of every fighter - how often it is used, how often it lands, the damage it deals, how often its user
rem is hit in it) and results.txt (a summary). The report only gives the measured numbers; how to change the fighters
rem is up to the mod's maker.
rem To pause: close this window (the games running in the background stop with it), or set RUN_HOURS, or shut the PC
rem down. To go on: run this file again - the finished rounds are kept, and so is what the round under way had played.
rem To measure more after it is done: raise TOTAL_GAMES (or TOTAL_HOURS) and run it again - the new games add up to
rem the results.
rem To measure again from scratch (after changing fighters, say): delete or rename the folder balance-<mod>.
rem ============ SETTINGS ============
rem The installed game. Left empty, it is looked for (Install for me only, all users, or an OpenLF2 folder next to this file).
set "GAME="
rem The mod's zip file. Left empty: the mod zip next to this file, if there is only one (skipping *-xoi-previous.zip,
rem the lf2-online-upload package, xoi-kit, balance-kit); drag a zip file onto this file to measure that mod. The
rem <mod>-xoi.zip (with XOI's numbers, brain and notes for that mod - from the XOI kit) works too, and is the better
rem choice: XOI plays stronger with it.
set "PACK="
rem Fighters: all = every fighter a player can choose; or a list of ids or names, e.g.: 8 25 Crimson Deep
rem (names as in the game, any case).
set "FIGHTERS=all"
rem Fighters to leave out (ids or names), e.g. a training dummy or a boss: Dummy 40
set "EXCLUDE="
rem The computer player on both sides: xoi (XOI, with the mod's own numbers and brain if it has them), smart (INSANE!),
rem classic (the original computer player; a fighter with its own AI script in the mod - like Sauce's AI - is played by
rem that script). Measure with all three and compare: a fighter that is strong with every player is almost surely
rem strong.
set "BRAIN=xoi"
rem How much: the total number of games (TOTAL_GAMES, e.g. 200000), or the total hours (TOTAL_HOURS, used when
rem TOTAL_GAMES is empty; 7.5 = seven and a half hours). Split into ROUNDS rounds: after every round the report is updated
rem (it can be opened while the rest runs).
rem For example: 21 fighters (210 pairs), a margin of about +-1%% for each fighter: about 100000 games; +-3%% for each
rem cell of the matchup chart: about 230000 games. The speed depends on the mod and the PC (one CPU thread: from a few
rem hundred to about 9000 games an hour); after every round this file shows the games per hour, to size TOTAL_GAMES or
rem TOTAL_HOURS next time.
set "ROUNDS=10"
set "TOTAL_GAMES="
set "TOTAL_HOURS=2"
rem Weapons falling from the sky: 0 = off (only the fighters and what they make themselves are measured), 1 = on
set "WEAPONS=0"
rem A game lasts at most GAME_MINUTES minutes; STILL_SECONDS seconds in a row without anybody losing HP end it, a draw
set "GAME_MINUTES=5"
set "STILL_SECONDS=60"
rem How many processes run at once (one per CPU thread)
set "PARALLEL=%NUMBER_OF_PROCESSORS%"
rem Pause timer (RUN_HOURS): stop after about this many hours, e.g. 8, or 7.5 = seven and a half (empty: run to the
rem end). When the time is up, the processes stop at once and keep what they played; run this file again to go on.
set "RUN_HOURS="
rem The priority of the processes: BELOWNORMAL (the PC stays smooth to use while it runs), LOW, or NORMAL
set "PRIORITY=BELOWNORMAL"
rem The first seed (same seed, same settings: the very same games)
set "FIRST_SEED=5000"
rem The package's tools\ai-bench and scripts folders (left empty: looked for next to this .bat file)
set "BENCH="
set "SCRIPTS="
rem =====================================
rem Your own settings, kept across updates of the kit: a file balance-settings.bat next to this file (create it), one
rem setting a line as above, e.g.  set "TOTAL_GAMES=200000"
if exist "%~dp0balance-settings.bat" (
  call "%~dp0balance-settings.bat"
  if /i not "%~1"=="chay1" echo Your settings: balance-settings.bat
)

rem (This file calls itself again for each process, in its own window: cmd /c call "<this file>" chay1 <round-N>
rem <process number> <seed>; the mod in PACK_1, the results folder in LV - from the main window. See spsa.bat.)
if /i "%~1"=="chay1" goto chay1

set "SELF=%~f0"
set "KIT=%~dp0"
rem --- The mod: dragged onto this file, the PACK line, or the only mod zip next to this file ---
set "PACK_1="
if not "%~1"=="" if /i "%~x1"==".zip" if exist "%~f1" set "PACK_1=%~f1"
if not defined PACK_1 if defined PACK set "PACK_1=%PACK%"
set /a NP=0
set "CAC_ZIP="
if not defined PACK_1 (
  pushd "%~dp0"
  for %%z in (*.zip) do (
    set "TEN=%%~nz"
    set "BO="
    if /i "!TEN:~-13!"=="-xoi-previous" set "BO=1"
    if /i "!TEN:~0,17!"=="lf2-online-upload" set "BO=1"
    if /i "!TEN:~0,7!"=="xoi-kit" set "BO=1"
    if /i "!TEN:~0,11!"=="balance-kit" set "BO=1"
    if not defined BO (
      set /a NP+=1
      set "UNG_!NP!=%%~fz"
      set "CAC_ZIP=!CAC_ZIP! "%%~nxz""
    )
  )
  popd
)
if not defined PACK_1 if !NP! EQU 1 set "PACK_1=!UNG_1!"
if not defined PACK_1 if !NP! GTR 1 (
  echo There are !NP! mod zip files next to this file - which one to measure? Drag one zip file onto this file, or set the PACK line:
  echo  !CAC_ZIP!
  if "%KHONG_DUNG%"=="" pause
  exit /b 1
)
if not defined PACK_1 (echo No mod zip file found: put the mod's zip file next to this file, drag it onto this file, or edit the PACK line at the top of the file.& pause& exit /b 1)
if not exist "%PACK_1%" (echo The mod "%PACK_1%" was not found - edit the PACK line at the top of the file.& pause& exit /b 1)
for %%z in ("%PACK_1%") do set "TEN_MOD=%%~nz"
rem (A results folder for each player: balance-<mod> for XOI, balance-<mod>-smart, -classic for the others.)
if not defined BRAIN set "BRAIN=xoi"
set "LV=%~dp0balance-%TEN_MOD%"
if /i not "%BRAIN%"=="xoi" set "LV=%~dp0balance-%TEN_MOD%-%BRAIN%"

rem --- The game, the bench, the scripts ---
if not defined GAME (
  for %%g in ("%LOCALAPPDATA%\Programs\OpenLF2\openlf2.exe" "%ProgramFiles(x86)%\OpenLF2\openlf2.exe" "%ProgramFiles%\OpenLF2\openlf2.exe" "%~dp0OpenLF2\openlf2.exe") do (
    if not defined GAME if exist "%%~g" set "GAME=%%~g"
  )
)
if not defined GAME set "GAME=%LOCALAPPDATA%\Programs\OpenLF2\openlf2.exe"
if not defined BENCH (
  if exist "%~dp0tools\ai-bench\balance.lua" set "BENCH=%~dp0tools\ai-bench"
  if exist "%~dp0balance.lua" set "BENCH=%~dp0."
  if exist "%~dp0..\balance.lua" set "BENCH=%~dp0.."
)
if not defined SCRIPTS (
  if exist "%~dp0scripts\base\game\smart_ai.lua" set "SCRIPTS=%~dp0scripts"
  if exist "%~dp0..\..\..\scripts\base\game\smart_ai.lua" set "SCRIPTS=%~dp0..\..\..\scripts"
)
if not exist "%GAME%" (echo The game "%GAME%" was not found: install OpenLF2 ^(the OpenLF2-Windows-x64.exe installer under Releases on the project's GitHub page, Install for me only^), or edit the GAME line at the top of the file.& pause& exit /b 1)
if not defined BENCH (echo No tools\ai-bench folder with balance.lua found - this needs the kit of package 77 or later.& pause& exit /b 1)
if not exist "%BENCH%\balance.lua" (echo "%BENCH%\balance.lua" was not found - this needs the kit of package 77 or later.& pause& exit /b 1)
if not exist "%BENCH%\balance-report-head.html" (echo "%BENCH%\balance-report-head.html" was not found - this needs the kit of package 77 or later.& pause& exit /b 1)
if not defined SCRIPTS (echo No scripts folder found next to this file - this needs the kit of package 77 or later.& pause& exit /b 1)
findstr /c:"battle.on_damage" "%SCRIPTS%\base\game\battle.lua" >nul 2>nul || (echo "%SCRIPTS%\base\game\battle.lua" cannot count the damage of each move yet - this needs the kit of package 77 or later.& pause& exit /b 1)
set /a N=PARALLEL
if %N% LSS 1 set /a N=1
rem Memory: a process uses up to about 0.6 GB. With PARALLEL left at its default on a PC with little RAM, fewer
rem processes run, keeping about 4 GB for Windows. PARALLEL set to another number than the CPU threads is kept as it is.
set /a RAM_GB=0
if "%PARALLEL%"=="%NUMBER_OF_PROCESSORS%" for /f %%m in ('powershell -NoProfile -Command "[int][math]::Floor((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)" 2^>nul') do set /a RAM_GB=%%m 2>nul
if !RAM_GB! GEQ 2 (
  set /a "TOI_DA=(RAM_GB-4)*10/6"
  if !TOI_DA! LSS 1 set /a TOI_DA=1
  if !TOI_DA! LSS %N% (
    echo This PC has !RAM_GB! GB of RAM: running !TOI_DA! processes instead of %N% ^(each uses up to about 0.6 GB^).
    set /a N=TOI_DA
  )
)

rem --- The settings of the measurement, for the game's config ---
rem (Each id or name in [==[ ]==]: tools\ai-bench\names.lua turns names into ids.)
set "IDS_LUA="all""
if /i not "%FIGHTERS%"=="all" if defined FIGHTERS (
  set "IDS_LUA="
  for %%i in (%FIGHTERS%) do if defined IDS_LUA (set "IDS_LUA=!IDS_LUA!, [==[%%~i]==]") else (set "IDS_LUA=[==[%%~i]==]")
  set "IDS_LUA={!IDS_LUA!}"
)
set "BO_LUA="
if defined EXCLUDE for %%i in (%EXCLUDE%) do if defined BO_LUA (set "BO_LUA=!BO_LUA!, [==[%%~i]==]") else (set "BO_LUA=[==[%%~i]==]")
set "BO_LUA={!BO_LUA!}"
set "VK=false"
if "%WEAPONS%"=="1" set "VK=true"
set /a GIOI=GAME_MINUTES*1800, DUNG=STILL_SECONDS*30
if !GIOI! LSS 900 set /a GIOI=900
set CFG_CHUNG=ids = !IDS_LUA!, exclude = !BO_LUA!, brain = "%BRAIN%", weapons = !VK!, limit = !GIOI!, stall = !DUNG!
rem The total games or the total hours (TONG_GIAY, seconds).
set "CHE_DO=gio"
set /a TONG_V=0, TONG_GIAY=0
if defined TOTAL_GAMES set /a TONG_V=TOTAL_GAMES 2>nul
if !TONG_V! GTR 0 set "CHE_DO=van"
if "!CHE_DO!"=="gio" (
  set "TG_H="
  set "TG_T="
  if defined TOTAL_HOURS for /f "tokens=1,2 delims=.," %%a in ("%TOTAL_HOURS%") do (
    set "TG_H=%%a"
    set "TG_T=%%b"
  )
  if not defined TG_H set "TG_H=0"
  if not defined TG_T set "TG_T=0"
  set "TG_T=!TG_T:~0,1!"
  set /a "TONG_GIAY=TG_H*3600+TG_T*360" 2>nul
)
rem (TEST_TOTAL_SECONDS: the total in seconds, for trying this file.)
if defined TEST_TOTAL_SECONDS set /a TONG_GIAY=TEST_TOTAL_SECONDS
if "!CHE_DO!"=="gio" if !TONG_GIAY! LEQ 0 (echo Set TOTAL_GAMES ^(the games^) or TOTAL_HOURS ^(the hours^) at the top of the file.& pause& exit /b 1)
set /a VONG_N=ROUNDS
if !VONG_N! LSS 1 set /a VONG_N=1
if not defined PRIORITY set "PRIORITY=NORMAL"
set "KIT_VER="
if exist "%~dp0version.txt" set /p KIT_VER=<"%~dp0version.txt"

if not exist "%LV%" mkdir "%LV%"
rem The settings of a measurement stay the same from start to end: fighters, player, weapons, game rules. Changed, they
rem are measured in another folder.
set "KY=FIGHTERS=%FIGHTERS% / EXCLUDE=%EXCLUDE% / BRAIN=%BRAIN% / WEAPONS=%WEAPONS% / GAME_MINUTES=%GAME_MINUTES% / STILL_SECONDS=%STILL_SECONDS%"
if exist "%LV%\settings-used.txt" (
  set "KY_CU="
  set /p KY_CU=<"%LV%\settings-used.txt"
  if not "!KY_CU!"=="!KY!" (
    echo [NOTE] The folder "%LV%" was measured with other settings:
    echo   then: !KY_CU!
    echo   now:  !KY!
    echo Two settings merged into one report would mix the numbers up. Set them back, or delete or rename that folder to measure again.
    if "%KHONG_DUNG%"=="" pause
    exit /b 1
  )
) else (
  >"%LV%\settings-used.txt" echo !KY!
)
rem The installed game's scripts, updated with the package's scripts: done once for the whole measurement (the same AI
rem from start to end).
if not exist "%LV%\scripts\base\game\smart_ai.lua" (
  for %%g in ("%GAME%") do set "CAI=%%~dpgscripts"
  if exist "!CAI!\base\game\match.lua" xcopy /e /i /q /y "!CAI!" "%LV%\scripts" >nul
  xcopy /e /i /q /y "%SCRIPTS%" "%LV%\scripts" >nul
)
if not exist "%LV%\scripts\base\game\match.lua" (echo [ERROR] The scripts could not be put together in "%LV%\scripts".& pause& exit /b 1)
if exist "%SCRIPTS%\runtime\bootstrap.lua" copy /y "%SCRIPTS%\runtime\bootstrap.lua" "%LV%\scripts\runtime\bootstrap.lua" >nul 2>nul
set XS=--scripts "%LV%\scripts"

rem --- The list of fighters (the game reads the mod, picks the fighters, says which names it does not have) ---
set "DS=%LV%\list"
if exist "%DS%" rmdir /s /q "%DS%"
mkdir "%DS%"
call :ban_bench "%DS%"
>"%DS%\config.lua" echo return {command = "balance", step = "list", %CFG_CHUNG%}
"%GAME%" --pack "%PACK_1%" %XS% --mod "%DS%" --seed 1 --input-trace "" >"%DS%\out.txt" 2>&1
call :cho_dong "%DS%\out.txt" "BAL_COUNT"
findstr /c:"BENCH ERROR" "%DS%\out.txt" >nul 2>nul && (
  echo [ERROR] The game reported an error reading the mod or the list of fighters:
  findstr /c:"BENCH ERROR" "%DS%\out.txt"
  if "%KHONG_DUNG%"=="" pause
  exit /b 1
)
set /a SO_NV=0, SO_CAP=0
for /f "tokens=2,3" %%a in ('findstr /b /c:"BAL_COUNT " "%DS%\out.txt"') do set /a SO_NV=%%a, SO_CAP=%%b
if !SO_NV! LSS 2 (echo [ERROR] At least two fighters are needed - see "%DS%\out.txt".& pause& exit /b 1)
findstr /b /c:"BAL_FIGHTER " "%DS%\out.txt" >"%LV%\fighters.txt"

echo The mod: "%PACK_1%"
echo %SO_NV% fighters, %SO_CAP% pairs ^(the list: "%LV%\fighters.txt"^); the player on both sides: %BRAIN%
for /f "tokens=1,*" %%a in ('findstr /b /c:"BAL_LEFT_OUT " "%DS%\out.txt"') do echo   left out: %%b
if "!CHE_DO!"=="van" (echo The plan: %TONG_V% games in %VONG_N% round^(s^), %N% processes ^(priority %PRIORITY%^)) else (echo The plan: %TOTAL_HOURS% hours in %VONG_N% round^(s^), %N% processes ^(priority %PRIORITY%^))
echo Results in "%LV%" ^(report.html, results.txt - updated after every round^)
echo To pause: close this window ^(the games in the background stop with it^). Run this file again to go on, the round under way too.
echo To let the PC run overnight: turn off Windows sleep ^(Settings - System - Power - Sleep: Never^).
rem The timer (RUN_HOURS): the most seconds to run (GIOI_HAN; 0 = no timer), counted from now.
set /a GIOI_HAN=0, DA_CHAY=0
set "HET_GIO="
set "GC_H="
set "GC_T="
if defined RUN_HOURS for /f "tokens=1,2 delims=.," %%a in ("%RUN_HOURS%") do (
  set "GC_H=%%a"
  set "GC_T=%%b"
)
if defined GC_H (
  if not defined GC_T set "GC_T=0"
  set "GC_T=!GC_T:~0,1!"
  set /a "GIOI_HAN=GC_H*3600+GC_T*360" 2>nul
)
rem (THU_GIOI_HAN: seconds, for trying this file.)
if defined THU_GIOI_HAN set /a GIOI_HAN=THU_GIOI_HAN
if !GIOI_HAN! GTR 0 echo Timer: running %RUN_HOURS% hours, then pausing ^(RUN_HOURS^).
call :giay CHAY_LUC
rem The window watch: a hidden PowerShell waits for this window to close - even with X clicked halfway - and then stops
rem every game of this folder. When this file is done (all rounds, the timer, an error), it writes watch-done.txt and the
rem watch stops watching.
set "CANH=%LV%\"
set "CANH_XONG=%LV%\watch-done.txt"
del /q "%CANH_XONG%" 2>nul
if not defined THU_WINE start "Balance - window watch" /MIN powershell -NoProfile -WindowStyle Hidden -Command "$c = (Get-CimInstance Win32_Process -Filter ('ProcessId=' + $PID)).ParentProcessId; if (-not $c) { exit }; while (Get-Process -Id $c -ErrorAction SilentlyContinue) { if (Test-Path -LiteralPath $env:CANH_XONG) { exit }; Start-Sleep -Seconds 3 }; Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'openlf2.exe' -and $_.CommandLine -and $_.CommandLine.Contains($env:CANH) } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }"

set "GAME_DA_CHON=%GAME%"
set XS_DA_CHON=%XS%
rem The finished rounds: their totals in round-N\totals.txt, the games and seconds played in round-N\done.txt.
set /a E=1, DONE_VAN=0, DONE_GIAY=0
set "TRUOC_TONG="
:xet_vong
set "D=%LV%\round-%E%"
if exist "%D%\done.txt" (
  findstr /c:"--BAL_TONG" "%D%\totals.txt" >nul 2>nul && (
    for /f "usebackq tokens=1,2" %%a in ("%D%\done.txt") do set /a DONE_VAN=%%a, DONE_GIAY=%%b
    set "TRUOC_TONG=%D%\totals.txt"
    set /a E+=1
    goto xet_vong
  )
  echo The totals of round %E% are broken ^(the PC shut down while writing them?^): merging round %E% again.
  del /q "%D%\done.txt" 2>nul
)
if %E% GTR 1 echo %DONE_VAN% games done in the rounds before.

:vong_tiep
rem What is left: games or seconds, split evenly over the rounds left. Past ROUNDS rounds with some left (TOTAL_GAMES
rem or TOTAL_HOURS raised after the end): the extra is split into rounds the size of the earlier ones.
if "!CHE_DO!"=="van" (set /a CON=TONG_V-DONE_VAN, TONG_KH=TONG_V) else (set /a CON=TONG_GIAY-DONE_GIAY, TONG_KH=TONG_GIAY)
if "!CHE_DO!"=="van" if !CON! LEQ 0 goto xong
if "!CHE_DO!"=="gio" if !CON! LSS 30 goto xong
set /a CON_VONG=VONG_N-E+1
if !CON_VONG! LSS 1 set /a "CON_VONG=(CON*VONG_N+TONG_KH-1)/TONG_KH"
if !CON_VONG! LSS 1 set /a CON_VONG=1
set /a "MOI=(CON+CON_VONG-1)/CON_VONG"
if "!CHE_DO!"=="van" (
  set /a "MOI_P=(MOI+N-1)/N"
  set /a "MOI_P=(MOI_P+1)/2*2"
  if !MOI_P! LSS 2 set /a MOI_P=2
  set "NGAN_SACH=games = !MOI_P!"
  set /a SNAP=300
  set "MO_TA=!MOI! games, !MOI_P! games a process"
) else (
  if !MOI! LSS 60 set /a MOI=60
  set "NGAN_SACH=seconds = !MOI!"
  set /a "SNAP=MOI/6"
  if !SNAP! LSS 60 set /a SNAP=60
  if !SNAP! GTR 600 set /a SNAP=600
  set /a "MOI_PH=(MOI+59)/60"
  set "MO_TA=!MOI_PH! minutes"
)
rem (TEST_SNAP: seconds between two snapshots, for trying this file.)
if defined TEST_SNAP set /a SNAP=TEST_SNAP
if !GIOI_HAN! GTR 0 (
  call :dong_ho
  if !DA_CHAY! GEQ !GIOI_HAN! goto het_gio
)
call :mot_vong
if defined HET_GIO goto het_gio
if errorlevel 1 goto loi
set /a TRUOC_VAN=DONE_VAN
for /f "usebackq tokens=1,2" %%a in ("%D%\done.txt") do set /a DONE_VAN=%%a, DONE_GIAY=%%b
if !DONE_VAN! LEQ !TRUOC_VAN! (echo [ERROR] Round %E% played no game - see "%D%\p1\log.txt".& goto loi)
set "TRUOC_TONG=%D%\totals.txt"
set /a E+=1
set "D=%LV%\round-%E%"
goto vong_tiep

:mot_vong
echo.
echo === Round %E%: %N% processes, !MO_TA! ^(%TIME:~0,8%^) ===
call :giay BAT_DAU
set "GHI_CHU="
rem The processes of this round finished last time (a BAL_END line) but were not merged: merging only.
if exist "%D%" (
  set /a XONG_N=0, CHUA_N=0
  pushd "%D%"
  for /d %%p in (p*) do if exist "%%p\out.txt" (
    set "XONG_P="
    findstr /b /c:"BAL_END " "%%p\out.txt" >nul 2>nul && set "XONG_P=1"
    if defined XONG_P (set /a XONG_N+=1) else set /a CHUA_N+=1
  )
  popd
  if !XONG_N! GEQ 1 if !CHUA_N! EQU 0 (
    echo   ^(the processes finished last time: merging only^)
    set "GHI_CHU= - merged only"
    goto gop_vong
  )
)
rem This round was cut short last time (window closed, PC shut down, timer): what it played is kept in before\<start>
rem and merged at the end of the round. (File patterns: pushd into the folder, then relative paths - see spsa.bat.)
set /a LAN=0
set "DO_DANG="
if exist "%D%" (
  pushd "%D%"
  for /d %%p in (p*) do if exist "%%p\out.txt" set "DO_DANG=1"
  popd
)
if defined DO_DANG (
  set "LAN="
  for /L %%a in (1,1,99) do if not defined LAN if not exist "%D%\before\%%a" set "LAN=%%a"
  mkdir "%D%\before\!LAN!"
  pushd "%D%"
  for /d %%p in (p*) do if exist "%%p\out.txt" move /y "%%p\out.txt" "before\!LAN!\%%p.txt" >nul
  popd
  echo   ^(going on with a round cut short: what it played before is kept^)
)
rem What the earlier starts of this round played (before\<start>\p<k>.txt, the last snapshot of each process): the
rem games added up, the seconds as the longest process of each start, added up. This start plays only what is missing.
set /a DA_V=0, DA_G=0
if exist "%D%\before" (
  pushd "%D%\before"
  for /d %%l in (*) do (
    set /a LAU=0
    pushd "%%l"
    for %%f in (p*.txt) do (
      set "SV="
      set "SG="
      for /f "tokens=3,4" %%a in ('findstr /b /c:"BAL_SNAP " "%%~ff" 2^>nul') do (
        set "SV=%%a"
        set "SG=%%b"
      )
      if defined SV set /a DA_V+=SV
      if defined SG if !SG! GTR !LAU! set /a LAU=SG
    )
    popd
    set /a DA_G+=LAU
  )
  popd
)
if !DA_V! GTR 0 (
  if "!CHE_DO!"=="van" (
    set /a "MOI_P=(MOI-DA_V+N-1)/N"
    set /a "MOI_P=(MOI_P+1)/2*2"
    if !MOI_P! LSS 2 set /a MOI_P=2
    set "NGAN_SACH=games = !MOI_P!"
  ) else (
    set /a "MOI_G=MOI-DA_G"
    if !MOI_G! LSS 60 set /a MOI_G=60
    set "NGAN_SACH=seconds = !MOI_G!"
  )
  echo   ^(the earlier starts played !DA_V! games of this round; this start: !NGAN_SACH!^)
)
if not exist "%D%" mkdir "%D%"
for /L %%k in (1,1,%N%) do (
  mkdir "%D%\p%%k" 2>nul
  del /q "%D%\p%%k\done.txt" 2>nul
  call :ban_bench "%D%\p%%k"
  set /a SEED=FIRST_SEED+E*1000+%%k+LAN*100000
  >"%D%\p%%k\config.lua" echo return {command = "balance", step = "play", %CFG_CHUNG%, !NGAN_SACH!, snap = !SNAP!, seed = !SEED!, round = %E%, process = %%k, processes = %N%}
  start "Balance round %E% - %%k" /MIN /%PRIORITY% cmd /c call "%SELF%" chay1 round-%E% %%k !SEED!
)
call :cho "%D%" "BAL_END "
if defined HET_GIO exit /b 0
:gop_vong
rem Merging: the last whole part of each process (the earlier starts in before\ too), added to the rounds before.
rem (The game reads them as files that come with the merge package - assets in package.manifest -, 4 MB at most each.)
set "M=%D%\merge"
if exist "%M%" rmdir /s /q "%M%"
mkdir "%M%"
call :ban_bench "%M%"
set "PREV_CFG="
if defined TRUOC_TONG (
  copy /y "%TRUOC_TONG%" "%M%\bal_prev.txt" >nul
  >>"%M%\package.manifest" echo asset=mods/bench/bal_prev.txt^|bal_prev.txt
  set "PREV_CFG=prev = true, "
)
set /a CO=0
set "BIN_0="
pushd "%D%"
for /d %%p in (p*) do call :lay_snap "%D%\%%p\out.txt" "%M%" 0
if exist before (
  pushd before
  for /d %%l in (*) do (
    set "BIN_%%l="
    pushd "%%l"
    for %%f in (p*.txt) do call :lay_snap "%%~ff" "%M%" %%l
    popd
  )
  popd
)
popd
if !CO! EQU 0 (
  echo [ERROR] No process played any game in round %E%:
  findstr /c:"BENCH ERROR" "%D%\p1\out.txt" 2>nul
  echo See "%D%\p1\out.txt".
  exit /b 1
)
set "NGAY=%DATE% %TIME:~0,5%"
>"%M%\config.lua" echo return {command = "balance", step = "merge", %CFG_CHUNG%, !PREV_CFG!lang = "en", mod = [==[%TEN_MOD%]==], plan_rounds = %VONG_N%, plan_games = !TONG_V!, plan_seconds = !TONG_GIAY!, date = [==[!NGAY!]==], kit = [==[!KIT_VER!]==]}
"%GAME%" --pack "%PACK_1%" %XS% --mod "%M%" --seed 1 --input-trace "" >"%M%\out.txt" 2>&1
call :cho_dong "%M%\out.txt" "BAL_DONE "
findstr /c:"--BAL_TONG" "%M%\out.txt" >"%D%\totals.tmp"
for %%f in ("%D%\totals.tmp") do if %%~zf LSS 20 (
  echo [ERROR] Round %E% could not be merged:
  findstr /c:"BENCH ERROR" "%M%\out.txt"
  echo See "%M%\out.txt".
  exit /b 1
)
move /y "%D%\totals.tmp" "%D%\totals.txt" >nul
findstr /c:"//BAL_JS" "%M%\out.txt" >"%LV%\data.js"
copy /b "%BENCH%\balance-report-head.html" + "%LV%\data.js" + "%BENCH%\balance-report-tail.html" "%LV%\report.html" >nul
findstr /b /c:"| " "%M%\out.txt" >"%LV%\results.txt"
for /f "tokens=2,3,4" %%a in ('findstr /b /c:"BAL_DONE " "%M%\out.txt"') do >"%D%\done.txt" echo %%a %%b %%c
if not exist "%D%\done.txt" (echo [ERROR] The merge of round %E% did not finish - see "%M%\out.txt".& exit /b 1)
rem Cleaning up: what the processes played is in the totals (round-N\totals.txt); each process keeps a short log.
pushd "%D%"
for /d %%p in (p*) do (
  if exist "%%p\out.txt" findstr /v /b /c:"{" "%%p\out.txt" >"%%p\log.txt" 2>nul
  del /q "%%p\out.txt" 2>nul
  del /q "%%p\*.lua" 2>nul
  del /q "%%p\package.manifest" 2>nul
)
if exist before rmdir /s /q before
popd
pushd "%M%"
del /q bal_*.txt part.txt *.lua 2>nul
popd
call :giay XONG_LUC
set /a "PHUT_V=((XONG_LUC-BAT_DAU+86400) %% 86400)/60"
rem The speed: the games of this round over its seconds (its longest process, by the game's clock).
set "VAN_TONG="
set /a GIAY_TONG=0
for /f "usebackq tokens=1,2" %%a in ("%D%\done.txt") do (
  set "VAN_TONG=%%a"
  set /a GIAY_TONG=%%b
)
set "TOC_DO="
set /a "VAN_V=VAN_TONG-DONE_VAN, GIAY_V=GIAY_TONG-DONE_GIAY"
if !GIAY_V! GEQ 60 set /a "TOC=VAN_V*60/(GIAY_V/60)"
if !GIAY_V! GEQ 60 set "TOC_DO= (about !TOC! games an hour)"
>>"%LV%\timing.txt" echo Round %E%: done at %TIME:~0,8%, took !PHUT_V! minutes, !VAN_TONG! games in all!TOC_DO!!GHI_CHU!
echo Round %E% done at %TIME:~0,8%, took !PHUT_V! minutes: !VAN_TONG! games in all!TOC_DO!. The report: "%LV%\report.html"
exit /b 0

:xong
echo.
echo ===== Done: %DONE_VAN% games. Results: "%LV%\results.txt", the full report: "%LV%\report.html" =====
if exist "%LV%\results.txt" type "%LV%\results.txt"
echo.
echo Open report.html in a browser ^(Chrome, Edge, Firefox^). To measure more: raise TOTAL_GAMES or TOTAL_HOURS and run this file again.
if defined CANH_XONG >"%CANH_XONG%" echo done
if not defined THU_WINE if "%KHONG_DUNG%"=="" if exist "%LV%\report.html" start "" "%LV%\report.html"
if "%KHONG_DUNG%"=="" pause
exit /b 0

:loi
echo [ERROR] Stopped in round %E%. Fix the error, then run this file again to go on.
if defined CANH_XONG >"%CANH_XONG%" echo done
if "%KHONG_DUNG%"=="" pause
exit /b 1

rem The timer is up (RUN_HOURS): the games have stopped, what the round under way played is kept - run again to go on.
:het_gio
echo.
echo === Ran %RUN_HOURS% hours ^(%TIME:~0,8%^): pausing. Run this file again to go on, the round under way too. ===
>>"%LV%\timing.txt" echo Paused at %TIME:~0,8% after %RUN_HOURS% hours ^(RUN_HOURS^)
if defined CANH_XONG >"%CANH_XONG%" echo done
if "%KHONG_DUNG%"=="" pause
exit /b 0

rem --- Adds the last whole part of file %1 (one process) to the merge folder %2, start %3: the lines of its last
rem snapshot (a line BAL_SNAP <s> marks snapshot s as fully written; none: skipped), appended to a file
rem bal_<start>_<n>.txt - about 3 MB a file, several processes ---
:lay_snap
if not exist "%~1" exit /b 0
set "SNAP_S="
for /f "tokens=2" %%s in ('findstr /b /c:"BAL_SNAP " "%~1" 2^>nul') do set "SNAP_S=%%s"
if not defined SNAP_S exit /b 0
findstr /b /c:"{!SNAP_S!," "%~1" >"%~2\part.txt"
set /a KB_PHAN=0
for %%f in ("%~2\part.txt") do set /a "KB_PHAN=%%~zf/1024"
if not defined BIN_%~3 set /a BIN_%~3=0, KB_%~3=99999
set /a "THU=KB_%~3+KB_PHAN"
if !THU! GTR 3000 (
  set /a BIN_%~3+=1
  set /a KB_%~3=0
  >>"%~2\package.manifest" echo asset=mods/bench/bal_%~3_!BIN_%~3!.txt^|bal_%~3_!BIN_%~3!.txt
)
type "%~2\part.txt" >>"%~2\bal_%~3_!BIN_%~3!.txt"
set /a KB_%~3+=KB_PHAN
set /a CO+=1
exit /b 0

rem --- The seconds since midnight by the clock into variable %1 (%TIME% is hours:minutes:seconds; hours under 10 start
rem with a space) ---
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

rem --- Waits for every process to finish: the end line %2 in out.txt, or done.txt (the game closed, also on an error) ---
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
  if exist "%~1\p%%k\out.txt" findstr /b /c:"%~2" "%~1\p%%k\out.txt" >nul 2>&1 && set "Y=1"
  if defined Y set "X=1"
  if not defined THU_WINE if exist "%~1\p%%k\done.txt" set "X=1"
  if defined X set /a XONG+=1
  if defined Y set /a TOT+=1
)
if !XONG! GEQ %N% exit /b 0
rem The timer is up (RUN_HOURS): stops every game of this folder, keeping what they played (each process's last snapshot).
if !GIOI_HAN! GTR 0 (
  call :dong_ho
  if !DA_CHAY! GEQ !GIOI_HAN! (
    set "HET_GIO=1"
    call :dung_het "%~1"
    exit /b 0
  )
)
set /a CHO+=5
rem When half the processes are done, a beat is set: a process still running past twice that beat, and at least
rem 5 minutes (DOI_THEM seconds) after it, is taken as hung - it is stopped and the round goes on with the finished
rem processes (what it played is merged all the same).
set /a "NUA=TOT*2"
if !NUA! GEQ %N% if !NHIP! LSS 0 set /a NHIP=CHO
if !NHIP! GEQ 0 (
  set /a "HAN=NHIP*2, HAN2=NHIP+DOI_THEM"
  if !HAN2! GTR !HAN! set /a HAN=HAN2
  if !CHO! GEQ !HAN! (
    set /a CON_LAI=N-XONG
    echo   [NOTE] !CON_LAI! processes are running too long ^(over twice the other half^) - stopping them, going on with !XONG!/%N% processes.
    call :dung_treo "%~1"
    exit /b 0
  )
)
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

rem --- Stops the games of the unfinished processes in folder %1 (found by their --mod "...\p<k>" path; their windows
rem close by themselves) ---
:dung_treo
for /L %%k in (1,1,%N%) do (
  if not exist "%~1\p%%k\done.txt" (
    set "TREO=%~1\p%%k"
    >>"%LV%\timing.txt" echo   Stopped a hung process: !TREO!
    powershell -NoProfile -Command "Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'openlf2.exe' -and $_.CommandLine -and $_.CommandLine.Contains($env:TREO + [char]34) } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }" >nul 2>&1
  )
)
exit /b 0

rem --- Stops every game of folder %1 (the timer: RUN_HOURS) ---
:dung_het
set "TREO=%~1\"
powershell -NoProfile -Command "Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'openlf2.exe' -and $_.CommandLine -and $_.CommandLine.Contains($env:TREO) } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }" >nul 2>&1
exit /b 0

rem --- The time run since the start (DA_CHAY, seconds) by the clock, past midnight too ---
:dong_ho
rem (THU_WINE: the %TIME% of cmd under Wine has no seconds - each call counts as 5 seconds, one beat of the wait.)
if defined THU_WINE (set /a DA_CHAY+=5& exit /b 0)
call :giay BAY_GIO_DH
set /a "DA_CHAY+=(BAY_GIO_DH-CHAY_LUC+86400) %% 86400, CHAY_LUC=BAY_GIO_DH"
exit /b 0

rem --- Waits for line %2 to show up in file %1 (a minute at most) ---
:cho_dong
set /a CD=0
:cho_dong_tiep
findstr /c:"%~2" "%~1" >nul 2>&1 && exit /b 0
set /a CD+=1
if !CD! GEQ 30 exit /b 1
ping -n 3 127.0.0.1 >nul 2>&1
goto cho_dong_tiep

rem --- One process: the game runs in the background; %2 round-N, %3 the process number, %4 the seed (LV, GAME_DA_CHON,
rem XS_DA_CHON, PACK_1: from the main window); when done, its window closes ---
:chay1
set "DIR=%LV%\%~2\p%~3"
"%GAME_DA_CHON%" --pack "%PACK_1%" %XS_DA_CHON% --mod "!DIR!" --seed %~4 --input-trace "" >"!DIR!\out.txt" 2>&1
>"!DIR!\done.txt" echo done
exit
