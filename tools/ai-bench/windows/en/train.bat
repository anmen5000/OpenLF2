@echo off
setlocal EnableDelayedExpansion
rem XOI - trains every pair of fighters for the XOI difficulty (OpenLF2 package 25 or later).
rem Two INSANE! computer players play GAMES games for every pair of the mod's fighters (both ways round), recording which
rem move of which fighter earns what against which opponent; the notes are then packed as xoi\notes.txt into a copy of the mod's zip file.
rem Several rounds (each with a different FIRST_SEED) add up in the notes. A later round can have two XOI players
rem (using the notes so far) fight each other to learn further (BRAIN=xoi) - measure again after every round, keep the round that made XOI stronger.
rem ============ SETTINGS ============
rem The installed game. Left empty, it is found automatically (Install for me only, all users, or an OpenLF2 folder beside this file).
set "GAME="
rem The mod's zip file. Left empty, the first .zip beside this file is taken (except the *-xoi.zip files this file makes);
rem or drag the mod's zip file onto this file. Example: set "PACK=%~dp0naruto.zip"
set "PACK="
rem Ids of the fighters to train, separated by spaces (e.g. "1 2 3 7 18"), or all = every fighter of the mod
set "IDS=all"
rem Games per pair of fighters (each pair is trained both ways round: a against b and b against a)
set "GAMES=100"
rem Number of processes running at once (each process takes one CPU core)
set "PARALLEL=%NUMBER_OF_PROCESSORS%"
rem The first seed; process i uses seed FIRST_SEED + i. Change it for every further training round.
set "FIRST_SEED=5000"
rem Who plays while training: smart = two INSANE! players (first round); xoi = two XOI players using the notes merged from the
rem previous rounds (xoi-<mod>\notes.txt) to learn further on top of them
set "BRAIN=smart"
rem The tools\ai-bench and scripts folders of package 25 or later (left empty, they are looked for beside this .bat)
set "BENCH="
set "SCRIPTS="
rem =====================================

rem (This file calls itself to run each process: "chay1 <number>", with the chosen mod in PACK_DA_CHON;
rem through cmd /c call, so that a path with spaces or parentheses ^(^) still runs - see spsa.bat.)
if /i "%~1"=="chay1" set "PACK=%PACK_DA_CHON%"
rem Dragged onto this file: a zip file = train that mod. The word merge, or a folder (folder xoi-<name> = mod <name>):
rem only merge the rounds already trained and pack them, no further training.
set "GOP="
if not "%~1"=="" if /i not "%~1"=="chay1" set "GOP=1"
if defined GOP if /i "%~x1"==".zip" if not exist "%~1\" (
  set "PACK=%~f1"
  set "GOP="
)
if defined GOP if exist "%~1\data\data.txt" (
  echo "%~1" is a mod folder. Drag it onto play.bat once to zip it, then drag the zip file here.
  pause
  exit /b 1
)
if defined GOP if exist "%~1\" (
  set "THU=%~nx1"
  if /i "!THU:~0,4!"=="xoi-" if not defined PACK (
    set "PACK=%~dp0!THU:~4!.zip"
    if exist "%~f1\mod.txt" set /p PACK=<"%~f1\mod.txt"
  )
)
if not defined PACK (
  pushd "%~dp0"
  for %%z in (*.zip) do (
    set "TEN=%%~nz"
    if not defined PACK if /i not "!TEN:~-4!"=="-xoi" if /i not "!TEN:~-13!"=="-xoi-previous" if /i not "!TEN:~0,17!"=="lf2-online-upload" if /i not "!TEN:~0,7!"=="xoi-kit" set "PACK=%%~fz"
  )
  popd
)
if not defined PACK (echo No mod zip file found: put the mod's zip file beside this file, drag it onto this file, or edit the PACK line at the top of the file.& pause& exit /b 1)
if not defined GAME (
  for %%g in ("%LOCALAPPDATA%\Programs\OpenLF2\openlf2.exe" "%ProgramFiles(x86)%\OpenLF2\openlf2.exe" "%ProgramFiles%\OpenLF2\openlf2.exe" "%~dp0OpenLF2\openlf2.exe") do (
    if not defined GAME if exist "%%~g" set "GAME=%%~g"
  )
)
if not defined GAME set "GAME=%LOCALAPPDATA%\Programs\OpenLF2\openlf2.exe"

for %%z in ("%PACK%") do (
  set "TEN=%%~nz"
  set "OUT=%%~dpnz-xoi.zip"
)
rem One folder xoi-<mod> per mod: each training round in round-<seed>, the merged notes in notes.txt
set "XOI=%~dp0xoi-%TEN%"
set "KQ=%XOI%\round-%FIRST_SEED%"
if not defined BENCH (
  if exist "%~dp0tools\ai-bench\learn.lua" set "BENCH=%~dp0tools\ai-bench"
  if exist "%~dp0learn.lua" set "BENCH=%~dp0."
  if exist "%~dp0..\learn.lua" set "BENCH=%~dp0.."
)
if not defined SCRIPTS (
  if exist "%~dp0scripts\base\game\smart_ai.lua" set "SCRIPTS=%~dp0scripts"
  if exist "%~dp0..\..\scripts\base\game\smart_ai.lua" set "SCRIPTS=%~dp0..\..\scripts"
  if exist "%~dp0..\..\..\scripts\base\game\smart_ai.lua" set "SCRIPTS=%~dp0..\..\..\scripts"
)
if /i "%~1"=="chay1" goto chay1
if defined GOP goto gop

if not exist "%GAME%" (echo Game not found at "%GAME%": install OpenLF2 ^(the OpenLF2-Windows-x64.exe installer under Releases on the project's GitHub page, choose Install for me only^), or edit the GAME line at the top of the file.& pause& exit /b 1)
if not exist "%PACK%" (echo Mod not found: "%PACK%" - edit the PACK line at the top of the file.& pause& exit /b 1)
if not defined BENCH (echo No tools\ai-bench folder with learn.lua found - package 25 or later is needed.& pause& exit /b 1)
if not exist "%BENCH%\learn.lua" (echo "%BENCH%\learn.lua" not found - package 25 or later is needed.& pause& exit /b 1)
if exist "%KQ%\p1" (
  echo A training round with seed %FIRST_SEED% already exists: "%KQ%"
  echo Change FIRST_SEED to train further, or run this file with the word merge to only merge.
  pause
  exit /b 1
)
if /i "%BRAIN%"=="xoi" (
  if not exist "%XOI%\notes.txt" (echo BRAIN=xoi needs the notes of a previous round: "%XOI%\notes.txt" does not exist yet - run the first round with BRAIN=smart.& pause& exit /b 1)
  for %%f in ("%XOI%\notes.txt") do if %%~zf LSS 10 (echo The notes "%XOI%\notes.txt" are empty - run the first round with BRAIN=smart.& pause& exit /b 1)
)
if not exist "%KQ%" mkdir "%KQ%"
rem (Remembers the trained mod's zip file, so that dragging the xoi-<name> folder onto this file later merges and packs.)
>"%XOI%\mod.txt" echo !PACK!

rem The installed game's scripts, updated with the package's scripts (the package holds only the files that changed): no need to reinstall the game.
if defined SCRIPTS (
  for %%g in ("%GAME%") do set "CAI=%%~dpgscripts"
  if exist "!CAI!\base\game\match.lua" (
    echo Merging the installed game's scripts with the package's scripts ...
    xcopy /e /i /q /y "!CAI!" "%KQ%\scripts" >nul
    xcopy /e /i /q /y "!SCRIPTS!" "%KQ%\scripts" >nul
    if not exist "%KQ%\scripts\base\game\smart_ai.lua" echo [NOTE] Could not merge - using the installed game's scripts; the game must be package 25 or later.
  ) else (
    echo [NOTE] "!CAI!" not found - using the installed game's scripts; the game must be package 25 or later.
  )
)

if /i "%IDS%"=="all" (set "IDS_LUA="all"") else (set "IDS_LUA={%IDS: =, %}")
set /a N=PARALLEL
if %N% LSS 1 set /a N=1
rem BRAIN=xoi: two XOI players, with the current notes copied into each process (module xoi_notes).
set "THEM="
if /i "%BRAIN%"=="xoi" set "THEM=, brains = {"xoi", "xoi"}, notes = "xoi_notes""
for /L %%k in (1,1,%N%) do (
  mkdir "%KQ%\p%%k" 2>nul
  copy /y "%BENCH%\*.lua" "%KQ%\p%%k\" >nul
  copy /y "%BENCH%\package.manifest" "%KQ%\p%%k\" >nul
  if /i "%BRAIN%"=="xoi" (
    >"%KQ%\p%%k\xoi_notes.lua" echo return {text = [==[
    type "%XOI%\notes.txt" >>"%KQ%\p%%k\xoi_notes.lua"
    >>"%KQ%\p%%k\xoi_notes.lua" echo ]==]}
    >>"%KQ%\p%%k\package.manifest" echo module=xoi_notes^|xoi_notes.lua
  )
  >"%KQ%\p%%k\config.lua" echo return {command = "learn", games = %GAMES%, difficulty = -2, limit = 9000, ids = !IDS_LUA!, part = %%k, parts = %N%!THEM!}
)

echo Mod: "%PACK%"
echo Starting %N% training processes ^(%BRAIN% against %BRAIN%^), %GAMES% games per pair, seeds from %FIRST_SEED% + 1 ...
set "PACK_DA_CHON=%PACK%"
for /L %%k in (1,1,%N%) do start "XOI %%k" /MIN cmd /c call "%~f0" chay1 %%k
echo Training (each process is a minimized window, nothing is drawn). Results are written to "%KQ%"
echo Waiting for the openlf2.exe processes to finish (do not open the game to play meanwhile)...
if defined KHONG_CHO exit /b 0
:cho
timeout /t 10 /nobreak >nul
tasklist /FI "IMAGENAME eq openlf2.exe" 2>nul | find /I "openlf2.exe" >nul && goto cho

:gop
rem Merges every training round of this mod (xoi-<mod>\round-*) into xoi-<mod>\notes.txt
set /a CAP=0, LOI=0, DOT=0
if not exist "%XOI%" mkdir "%XOI%"
type nul > "%XOI%\notes.txt"
for /f "delims=" %%d in ('dir /b /ad "%XOI%\round-*" 2^>nul') do call :gop_dot "%XOI%\%%d"
if %DOT% EQU 0 (echo No training round of "%TEN%" beside this file yet.& pause& exit /b 1)
echo.
echo ===== %DOT% training rounds, %CAP% pairs of fighters trained =====
if %LOI% GTR 0 echo [ERROR] %LOI% processes not finished or with errors - see the lines above.
for %%f in ("%XOI%\notes.txt") do echo Notes: "%%~ff" (%%~zf bytes)
rem (A copy for copying by hand: this xoi folder goes inside the zip, beside the data folder.)
if not exist "%XOI%\pack\xoi" mkdir "%XOI%\pack\xoi"
copy /y "%XOI%\notes.txt" "%XOI%\pack\xoi\notes.txt" >nul

rem Packing: a copy of the mod's zip file with xoi/notes.txt added to the game folder (beside the data folder) - and xoi/tune.txt,
rem the mod's own numbers tuned by spsa.bat (xoi-<mod>\tune.txt), and xoi/brain.txt, brain.bat's brain, if there are any.
if not exist "%PACK%" (echo "%PACK%" not found - cannot pack.& pause& exit /b 1)
set "XPACK=%PACK%"
set "XOUT=%OUT%"
set "XNOTES=%XOI%\notes.txt"
set "XTUNE="
if exist "%XOI%\tune.txt" set "XTUNE=%XOI%\tune.txt"
set "XBRAIN="
if exist "%XOI%\brain.txt" set "XBRAIN=%XOI%\brain.txt"
rem (The previous packed copy is kept as <name>-xoi-previous.zip, to measure it against the new one.)
for %%z in ("%PACK%") do set "TRUOC=%%~dpnz-xoi-previous.zip"
if exist "%OUT%" copy /y "%OUT%" "%TRUOC%" >nul
del /q "%OUT%" 2>nul
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; Add-Type -AssemblyName System.IO.Compression; Add-Type -AssemblyName System.IO.Compression.FileSystem; Copy-Item -LiteralPath $env:XPACK -Destination $env:XOUT -Force; $z=[System.IO.Compression.ZipFile]::Open($env:XOUT,'Update'); try { $e=$z.Entries | Where-Object { $_.FullName -imatch '(^|[\\/])data[\\/]data\.txt$' } | Sort-Object { $_.FullName.Length } | Select-Object -First 1; if (-not $e) { throw 'the zip has no data/data.txt' }; $root=$e.FullName.Substring(0, $e.FullName.Length - 13); foreach ($f in @(@($env:XNOTES, 'xoi/notes.txt'), @($env:XTUNE, 'xoi/tune.txt'), @($env:XBRAIN, 'xoi/brain.txt'))) { if ($f[0] -and (Test-Path -LiteralPath $f[0])) { $name=$root + $f[1]; foreach ($old in @($z.Entries | Where-Object { $_.FullName -ieq $name })) { $old.Delete() }; [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($z, $f[0], $name); Write-Host ('Added ' + $name) } } } finally { $z.Dispose() }"
if not exist "%OUT%" goto khong_goi
if errorlevel 1 goto khong_goi
echo.
echo Done: "%OUT%"
echo Upload this file to the relay (admin page, same id as the old mod) - everyone who picks the XOI difficulty will use these notes.
echo To train further: change FIRST_SEED and run again - the notes add up over the rounds ^(BRAIN=xoi: XOI against XOI^).
if exist "%TRUOC%" echo The copy before this merge: "%TRUOC%" - measure both with measure.bat ^(same FIRST_SEED^), keep the stronger one.
if "%KHONG_DUNG%"=="" pause
exit /b 0

:khong_goi
(
  echo [ERROR] Packing failed. Do it by hand: open the mod's zip file ^(with 7-Zip or Explorer^),
  echo         go into the folder that holds the data folder, drag the folder "%XOI%\pack\xoi" in there, then upload the zip to the relay.
)
if "%KHONG_DUNG%"=="" pause
exit /b 1

:gop_dot
set /a DOT+=1
for /f "delims=" %%p in ('dir /b /ad "%~1\p*" 2^>nul') do call :gop1 "%~1\%%p"
exit /b 0

:gop1
if not exist "%~1\out.txt" (set /a LOI+=1& echo [ERROR] "%~1" has not run& exit /b 0)
findstr /C:"XOI " "%~1\out.txt" >> "%XOI%\notes.txt"
for /f "delims=" %%l in ('findstr /C:" done: " "%~1\out.txt"') do set /a CAP+=1
findstr /C:"LEARN DONE" "%~1\out.txt" >nul && exit /b 0
set /a LOI+=1
echo [ERROR] "%~1" not finished or with errors:
findstr /C:"ERROR" /C:"failed" "%~1\out.txt"
exit /b 0

:chay1
rem One process: the game runs in the background (no window), part %2 of the work, results into p%2\out.txt, closes the window when done.
set /a SEED=FIRST_SEED+%~2
set "XS="
if exist "%KQ%\scripts\base\game\smart_ai.lua" set XS=--scripts "%KQ%\scripts"
"%GAME%" --pack "%PACK%" %XS% --mod "%KQ%\p%~2" --seed %SEED% --input-trace "" > "%KQ%\p%~2\out.txt" 2>&1
exit
