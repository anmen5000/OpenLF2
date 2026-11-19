@echo off
setlocal EnableDelayedExpansion
rem LEARN THE MOVES ONCE (package 104). Before every match INSANE! and XOI learn each fighter's moves from the mod's
rem data: a match of 8 fighters takes 15-45 seconds in a browser, and every computer of a room learns them. This file
rem has your computer learn every fighter of the mod ONCE (their transformations too) and writes what it learned into
rem the mod's zip (xoi/learned-<id>.txt): the game reads those files instead of learning again, and the match begins
rem at once. The computer players play exactly as when they learn by themselves.
rem Result: <name>-xoi.zip beside the mod's zip (if it is there already it is updated, its other xoi files kept - the
rem notes, the numbers, the brains; the one before is kept as <name>-xoi-previous.zip). Upload it to the relay as usual:
rem the whole room plays the same file.
rem Run it again when the mod's data changes (its .dat files), or after an OpenLF2 package that learns differently (the
rem game's log says "learned by another version ... learn-moves.bat again"; meanwhile the game learns as before, no harm).
rem ============ SETTINGS ============
rem The installed game. Empty: found by itself (Install for me only, all users, or an OpenLF2 folder beside this file).
set "GAME="
rem The mod's zip. Empty: the first *-xoi.zip beside this file, else the first mod zip; or drag the mod's zip onto this
rem file. For example: set "PACK=%~dp0naruto.zip"
set "PACK="
rem The package's tools\ai-bench and scripts folders (empty: found beside this .bat)
set "BENCH="
set "SCRIPTS="
rem ==================================
set "KIT=%~dp0"
if not "%~1"=="" if /i "%~x1"==".zip" if exist "%~f1" set "PACK=%~f1"
if not defined PACK (
  pushd "%KIT%"
  for %%z in (*-xoi.zip) do if not defined PACK set "PACK=%%~fz"
  for %%z in (*.zip) do if not defined PACK (
    set "TEN=%%~nz"
    set "BO="
    if /i "!TEN:~-13!"=="-xoi-previous" set "BO=1"
    if /i "!TEN:~-10!"=="-xoi-truoc" set "BO=1"
    if /i "!TEN:~0,17!"=="lf2-online-upload" set "BO=1"
    if /i "!TEN:~0,7!"=="xoi-kit" set "BO=1"
    if not defined BO set "PACK=%%~fz"
  )
  popd
)
if not defined PACK (echo No mod zip found: put it beside this file, drag it onto this file, or set PACK at the top of this file.& pause& exit /b 1)
if not exist "%PACK%" (echo Cannot find "%PACK%" - set PACK at the top of this file.& pause& exit /b 1)
if not defined GAME (
  for %%g in ("%LOCALAPPDATA%\Programs\OpenLF2\openlf2.exe" "%ProgramFiles(x86)%\OpenLF2\openlf2.exe" "%ProgramFiles%\OpenLF2\openlf2.exe" "%KIT%OpenLF2\openlf2.exe") do (
    if not defined GAME if exist "%%~g" set "GAME=%%~g"
  )
)
if not defined GAME set "GAME=%LOCALAPPDATA%\Programs\OpenLF2\openlf2.exe"
if not exist "%GAME%" (echo Cannot find the game "%GAME%": install OpenLF2 ^(OpenLF2-Windows-x64.exe from the project's GitHub Releases, Install for me only^), or set GAME at the top of this file.& pause& exit /b 1)
if not defined BENCH (
  if exist "%KIT%tools\ai-bench\learned.lua" set "BENCH=%KIT%tools\ai-bench"
  if exist "%KIT%learned.lua" set "BENCH=%KIT%."
  if exist "%KIT%..\learned.lua" set "BENCH=%KIT%.."
)
if not defined BENCH (echo No tools\ai-bench folder with learned.lua - this needs the XOI kit of package 104 or later.& pause& exit /b 1)
if not exist "%BENCH%\learned.lua" (echo Cannot find "%BENCH%\learned.lua" - this needs the XOI kit of package 104 or later.& pause& exit /b 1)
if not defined SCRIPTS (
  if exist "%KIT%scripts\base\game\learned.lua" set "SCRIPTS=%KIT%scripts"
  if exist "%KIT%..\..\scripts\base\game\learned.lua" set "SCRIPTS=%KIT%..\..\scripts"
  if exist "%KIT%..\..\..\scripts\base\game\learned.lua" set "SCRIPTS=%KIT%..\..\..\scripts"
)
for %%z in ("%PACK%") do (
  set "XTEN=%%~nz"
  set "XDIR=%%~dpz"
)
if /i "!XTEN:~-4!"=="-xoi" set "XTEN=!XTEN:~0,-4!"
set "XOUT=!XDIR!!XTEN!-xoi.zip"
set "XTRUOC=!XDIR!!XTEN!-xoi-previous.zip"
rem (Learned on the very file that is updated - its data - so that the files fit it.)
set "XHOC=%PACK%"
if exist "!XOUT!" set "XHOC=!XOUT!"
set "LAM=%KIT%learn-moves-!XTEN!"
if exist "%LAM%" rmdir /s /q "%LAM%"
mkdir "%LAM%\bench" 2>nul
copy /y "%BENCH%\*.lua" "%LAM%\bench\" >nul
copy /y "%BENCH%\package.manifest" "%LAM%\bench\" >nul
>"%LAM%\bench\config.lua" echo return {command = "learned"}
rem The installed game's scripts, with the package's laid over them (a package holds the files changed): no new install.
set "XS="
for %%g in ("%GAME%") do set "CAI=%%~dpgscripts"
if defined SCRIPTS if exist "!CAI!\base\game\match.lua" (
  xcopy /e /i /q /y "!CAI!" "%LAM%\scripts" >nul
  xcopy /e /i /q /y "!SCRIPTS!" "%LAM%\scripts" >nul
  if exist "%LAM%\scripts\base\game\learned.lua" set XS=--scripts "%LAM%\scripts"
)
if not defined XS if not exist "!CAI!\base\game\learned.lua" (echo The installed game is older than package 104 and this kit's scripts are not here: install a new OpenLF2, or keep this file in the XOI kit's folder.& pause& exit /b 1)
echo Mod: "!XHOC!"
echo Learning every fighter's moves ^(once; a few minutes for a big mod^) ...
"%GAME%" --pack "!XHOC!" %XS% --mod "%LAM%\bench" --seed 1 --input-trace "" > "%LAM%\out.txt" 2>&1
findstr /b /c:"LEARNED-END" "%LAM%\out.txt" >nul
if errorlevel 1 (
  echo [ERROR] The game stopped half way - the last lines of "%LAM%\out.txt":
  powershell -NoProfile -Command "Get-Content -LiteralPath '%LAM%\out.txt' -Tail 8"
  pause
  exit /b 1
)
set "HC_LAM=%LAM%"
set "HC_HOC=!XHOC!"
set "HC_OUT=!XOUT!"
set "HC_TRUOC=!XTRUOC!"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; Add-Type -AssemblyName System.IO.Compression; Add-Type -AssemblyName System.IO.Compression.FileSystem; $dir=Join-Path $env:HC_LAM 'xoi'; New-Item -ItemType Directory -Force -Path $dir | Out-Null; $enc=New-Object System.Text.UTF8Encoding($false); $w=@{}; $names=@{}; $ok=@(); $bad=@(); $bytes=0; foreach ($l in [System.IO.File]::ReadLines((Join-Path $env:HC_LAM 'out.txt'))) { if ($l.StartsWith('LEARNED ')) { $m=[regex]::Match($l, '^LEARNED (-?\d+)(?: (.*))?$'); if (-not $m.Success) { continue }; $id=$m.Groups[1].Value; $f=$w[$id]; if ($null -eq $f) { $f=New-Object System.IO.StreamWriter((Join-Path $dir ('learned-' + $id + '.txt')), $false, $enc); $w[$id]=$f } else { $f.Write([char]10) }; $f.Write($m.Groups[2].Value) } elseif ($l.StartsWith('LEARNED-DONE ')) { $p=$l.Split(' '); $ok+=$p[1]; $names[$p[1]]=$p[2]; $bytes+=[long]$p[3] } elseif ($l.StartsWith('LEARNED-FAILED ')) { $bad+=$l.Substring(15) } }; foreach ($f in $w.Values) { $f.Close() }; foreach ($id in @($w.Keys)) { if (-not ($ok -contains $id)) { Remove-Item -LiteralPath (Join-Path $dir ('learned-' + $id + '.txt')) -Force } }; Write-Host ('Learned ' + $ok.Count + ' fighters (' + [math]::Round($bytes / 1MB, 1) + ' MB before packing).'); foreach ($b in $bad) { Write-Host ('  [NOTE] could not be written: ' + $b + ' - the game learns this fighter as before') }; if ($ok.Count -eq 0) { throw 'no fighter learned' }; if (Test-Path -LiteralPath $env:HC_OUT) { Copy-Item -LiteralPath $env:HC_OUT -Destination $env:HC_TRUOC -Force } else { Copy-Item -LiteralPath $env:HC_HOC -Destination $env:HC_OUT -Force }; $z=[System.IO.Compression.ZipFile]::Open($env:HC_OUT, 'Update'); try { $e=$z.Entries | Where-Object { $_.FullName -imatch '(^|[\\/])data[\\/]data\.txt$' } | Sort-Object { $_.FullName.Length } | Select-Object -First 1; if (-not $e) { throw 'the zip has no data/data.txt' }; $root=$e.FullName.Substring(0, $e.FullName.Length - 13); $cu=0; foreach ($old in @($z.Entries | Where-Object { $_.FullName.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) -and $_.FullName.Substring($root.Length) -imatch '^xoi[\\/]learned-[^\\/]*\.txt$' })) { $old.Delete(); $cu++ }; foreach ($id in $ok) { [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($z, (Join-Path $dir ('learned-' + $id + '.txt')), ($root + 'xoi/learned-' + $id + '.txt'), [System.IO.Compression.CompressionLevel]::Optimal) }; if ($cu -gt 0) { Write-Host ('Replaced ' + $cu + ' older files of learned moves.') } } finally { $z.Dispose() }; Write-Host ''; Write-Host ('Done: ' + $env:HC_OUT)"
if errorlevel 1 (
  echo [ERROR] Could not put them into the zip. By hand: open the mod's zip, go to the folder with the data folder,
  echo         make a folder xoi there and copy the files of "%LAM%\xoi" into it.
  pause
  exit /b 1
)
echo.
echo Play with this zip ^(upload it to the relay with the old mod's id - every computer of a room uses this file^):
echo INSANE^^! and XOI read the moves learned and need not learn them again. A copy of the files is in "%LAM%\xoi".
pause
exit /b 0
