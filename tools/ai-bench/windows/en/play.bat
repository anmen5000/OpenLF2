@echo off
setlocal EnableDelayedExpansion
rem Play the mod with OpenLF2 on this PC, with every computer level: Easy, Normal, Difficult, CRAZY, INSANE, XOI.
rem (The mod's original .exe is the old LF2 game, which only goes up to CRAZY: INSANE and XOI are in OpenLF2.)
rem How to use: put this file next to the mod's zip file and double-click it. Or drag and drop onto this file: the
rem mod's zip file, the mod folder (the folder that has data\data.txt), or the mod's .exe - plus the XOI notes file
rem (.txt) if there is one.
rem A folder (or .exe) is packed into a zip file next to this file; with notes it becomes <name>-xoi.zip (XOI built in).
rem ============ SETTINGS ============
rem The installed game. Leave empty to find it automatically (Install for me only, all users, or an OpenLF2 folder
rem next to this file).
set "GAME="
rem The mod: a zip file or a folder. Leave empty to take the first *-xoi.zip (with XOI notes) next to this file, or
rem the first .zip if there is none.
set "PACK="
rem The mod's XOI notes (the notes.txt of whoever trained it). Leave empty to look for <mod name>-notes.txt or
rem xoi-<mod name>\notes.txt next to this file. A *-xoi.zip already has its notes and needs none.
set "NOTES="
rem Renderer. Empty: opengl (the game's default "gpu" renderer gives a plain blue window with no picture on some PCs),
rem and if opengl fails to start, the game's default renderer. Or name one: opengl, software, gpu, direct3d11.
set "RENDERER="
rem =====================================

rem What was dropped onto this file: a .txt file is the notes, a folder / .exe file / zip file is the mod.
:doc_vao
if "%~1"=="" goto doc_xong
if exist "%~1\" (
  set "PACK=%~f1"
) else if /i "%~x1"==".txt" (
  set "NOTES=%~f1"
) else if /i "%~x1"==".exe" (
  set "PACK=%~dp1"
  set "PACK=!PACK:~0,-1!"
) else (
  set "PACK=%~f1"
)
shift
goto doc_vao
:doc_xong

if not defined PACK (
  pushd "%~dp0"
  for %%z in (*-xoi.zip) do if not defined PACK set "PACK=%%~fz"
  for %%z in (*.zip) do (
    set "TEN=%%~nz"
    if not defined PACK if /i not "!TEN:~-13!"=="-xoi-previous" if /i not "!TEN:~0,17!"=="lf2-online-upload" if /i not "!TEN:~0,7!"=="xoi-kit" set "PACK=%%~fz"
  )
  popd
)
if not defined PACK (echo No mod found: drag and drop the mod zip file or mod folder onto play.bat, or edit the PACK line at the top of this file.& pause& exit /b 1)
if not exist "%PACK%" (echo "%PACK%" not found.& pause& exit /b 1)
set "THU_MUC="
if exist "%PACK%\" set "THU_MUC=1"
for %%p in ("%PACK%") do (
  set "TEN=%%~np"
  set "DUOI=%%~xp"
)
if defined THU_MUC (
  for %%p in ("%PACK%") do set "TEN=%%~nxp"
) else if /i not "%DUOI%"==".zip" (
  echo "%PACK%" is not a zip file. OpenLF2 reads a mod as a .zip file or a folder:
  echo extract the .rar / .7z file first ^(with 7-Zip^), then drag the mod folder onto play.bat.
  pause
  exit /b 1
)

if not defined GAME (
  for %%g in ("%LOCALAPPDATA%\Programs\OpenLF2\openlf2.exe" "%ProgramFiles(x86)%\OpenLF2\openlf2.exe" "%ProgramFiles%\OpenLF2\openlf2.exe" "%~dp0OpenLF2\openlf2.exe") do (
    if not defined GAME if exist "%%~g" set "GAME=%%~g"
  )
)
if not defined GAME (echo OpenLF2 is not installed: download the OpenLF2-Windows-x64.exe installer from the Releases page of the project on GitHub and choose Install for me only.& pause& exit /b 1)
if not exist "%GAME%" (echo Game "%GAME%" not found - edit the GAME line at the top of this file.& pause& exit /b 1)

rem XOI notes next to this file, named after the mod.
if not defined NOTES if exist "%~dp0%TEN%-notes.txt" set "NOTES=%~dp0%TEN%-notes.txt"
if not defined NOTES if exist "%~dp0xoi-%TEN%\notes.txt" set "NOTES=%~dp0xoi-%TEN%\notes.txt"
if defined NOTES if not exist "%NOTES%" (echo Notes file "%NOTES%" not found.& pause& exit /b 1)

rem A folder, or a mod plus notes: make a new zip file next to this file (the original mod is left as it is).
set "GOC=%TEN%"
if /i "%GOC:~-4%"=="-xoi" set "GOC=%GOC:~0,-4%"
set "OUT="
if defined NOTES (
  set "OUT=%~dp0%GOC%-xoi.zip"
) else if defined THU_MUC (
  set "OUT=%~dp0%TEN%.zip"
)
if defined OUT (
  if defined NOTES (echo Adding the XOI notes "%NOTES%" to the mod ...) else (echo Packing the mod folder into a zip file ...)
  set "XSRC=%PACK%"
  set "XNOTES=%NOTES%"
  set "XOUT=!OUT!"
  powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; Add-Type -AssemblyName System.IO.Compression; Add-Type -AssemblyName System.IO.Compression.FileSystem; $src=$env:XSRC; $tmp=$env:XOUT + '.tmp'; if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }; if (Test-Path -LiteralPath $src -PathType Container) { $dir=(Resolve-Path -LiteralPath $src).ProviderPath.TrimEnd('\'); $base=Split-Path -Leaf $dir; $z=[System.IO.Compression.ZipFile]::Open($tmp,'Create'); try { foreach ($f in @(Get-ChildItem -LiteralPath $dir -Recurse -File)) { $rel=$f.FullName.Substring($dir.Length + 1).Replace('\','/'); if ($env:XNOTES -and $rel -imatch '(^|/)xoi/notes\.txt$') { continue }; [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($z, $f.FullName, $base + '/' + $rel, 'Fastest') } } finally { $z.Dispose() } } else { Copy-Item -LiteralPath $src -Destination $tmp -Force }; $mode='Read'; if ($env:XNOTES) { $mode='Update' }; $z=[System.IO.Compression.ZipFile]::Open($tmp,$mode); try { $e=$z.Entries | Where-Object { $_.FullName -imatch '(^|[\\/])data[\\/]data\.txt$' } | Sort-Object { $_.FullName.Length } | Select-Object -First 1; if (-not $e) { throw 'no data/data.txt - this is not an LF2 game folder' }; if ($env:XNOTES) { $root=$e.FullName.Substring(0, $e.FullName.Length - 13); $name=$root + 'xoi/notes.txt'; foreach ($old in @($z.Entries | Where-Object { $_.FullName -imatch '(^|[\\/])xoi[\\/]notes\.txt$' })) { $old.Delete() }; [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($z, $env:XNOTES, $name); Write-Host ('Added ' + $name) } } finally { $z.Dispose() }; Move-Item -LiteralPath $tmp -Destination $env:XOUT -Force"
  if errorlevel 1 (
    del /q "!OUT!.tmp" 2>nul
    echo [ERROR] Could not make the zip file "!OUT!" - see the error line above.
    pause
    exit /b 1
  )
  if not exist "!OUT!" (echo [ERROR] Could not make the zip file "!OUT!".& pause& exit /b 1)
  set "PACK=!OUT!"
)

rem The scripts of the xoi-kit (or of an update package) next to this file, when newer than the installed game's
rem scripts, are merged over the installed game's scripts: no need to reinstall the game. When the installed game
rem is newer, the installed game is used as it is.
set "MOI="
if exist "%~dp0scripts\base\game\smart_ai.lua" set "MOI=%~dp0scripts"
if not defined MOI if exist "%~dp0..\..\..\scripts\base\game\smart_ai.lua" set "MOI=%~dp0..\..\..\scripts"
set "XS="
if defined MOI (
  for %%g in ("%GAME%") do set "CAI=%%~dpgscripts"
  set /a V_MOI=0, V_CAI=0
  for /f "tokens=3" %%v in ('findstr /b /c:"smart.version = " "!MOI!\base\game\smart_ai.lua" 2^>nul') do set /a V_MOI=%%v
  if exist "!CAI!\base\game\smart_ai.lua" for /f "tokens=3" %%v in ('findstr /b /c:"smart.version = " "!CAI!\base\game\smart_ai.lua" 2^>nul') do set /a V_CAI=%%v
  if !V_MOI! GTR !V_CAI! (
    set "GHEP=%~dp0scripts-play"
    if exist "!GHEP!" rmdir /s /q "!GHEP!"
    if exist "!CAI!\base\game\match.lua" xcopy /e /i /q /y "!CAI!" "!GHEP!" >nul
    xcopy /e /i /q /y "!MOI!" "!GHEP!" >nul
    if exist "!GHEP!\base\game\match.lua" (set XS=--scripts "!GHEP!") else (echo [NOTE] Could not merge the scripts - using the installed game's scripts.)
    echo INSANE computer player version !V_MOI! from the xoi-kit, version !V_CAI! in the installed game
  ) else (
    echo INSANE computer player version !V_CAI! from the installed game
  )
)
set "XR=--renderer opengl"
if defined RENDERER set "XR=--renderer %RENDERER%"

echo Game: %GAME%
echo Mod: %PACK%
echo Pick a fighter, add computer players (Com); on the difficulty line press past CRAZY to reach INSANE, then XOI.
rem A non-zero exit code is an error. When Windows kills the game the code is negative (e.g. -1073740791 = 0xC0000409),
rem which "if errorlevel 1" does not catch: compare with 0.
"%GAME%" %XR% %XS% --pack "%PACK%"
set "MA=!errorlevel!"
if not "!MA!"=="0" if not defined RENDERER (
  echo.
  echo The opengl renderer could not start on this PC ^(exit code !MA!^) - trying again with the game's default renderer ...
  "%GAME%" %XS% --pack "%PACK%"
  set "MA=!errorlevel!"
)
if not "!MA!"=="0" (
  echo.
  echo The game stopped with an error ^(exit code !MA!, see the lines above^). Game window only blue or black: edit the RENDERER line
  echo at the top of this file ^(opengl, software^). Game does not start: run check.bat ^(next to this file^) and send the file check.txt.
  pause
)
