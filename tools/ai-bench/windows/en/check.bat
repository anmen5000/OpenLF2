@echo off
setlocal EnableDelayedExpansion
rem CHECK - find out why the OpenLF2 game does not start on this PC. Double-click this file (in the XOI kit, next to
rem play.bat and a mod zip file), wait about 2 minutes, then send the file check.txt to the game's developer.
rem While it runs, the game window can appear and close by itself: do not press anything.
rem (This file calls itself again for each windowed launch of the game: cmd /c call "<this file>" thu1 <renderer>, with
rem no other quotes - see spsa.bat; the game, mod, temp folder and renderer come from GAME, PACK, TAM, VE, CFG of the
rem main window.)
if /i "%~1"=="thu1" goto thu1
rem ============ SETTINGS ============
rem The installed game. Leave empty to find it automatically (Install for me only, all users, or an OpenLF2 folder
rem next to this file).
set "GAME="
rem The mod's zip file. Leave empty to take the first mod zip file next to this file; dropping a zip file onto this
rem file works too.
set "PACK="
rem =====================================

set "SELF=%~f0"
set "TAM=%TEMP%\lf2-check"
set "BAO=%~dp0check.txt"
if not defined GAME (
  for %%g in ("%LOCALAPPDATA%\Programs\OpenLF2\openlf2.exe" "%ProgramFiles(x86)%\OpenLF2\openlf2.exe" "%ProgramFiles%\OpenLF2\openlf2.exe" "%~dp0OpenLF2\openlf2.exe") do (
    if not defined GAME if exist "%%~g" set "GAME=%%~g"
  )
)
if not defined GAME (echo openlf2.exe not found - install OpenLF2 first ^(the OpenLF2-Windows-x64.exe installer, choose Install for me only^).& pause& exit /b 1)
if not exist "%GAME%" (echo Game "%GAME%" not found - edit the GAME line at the top of this file.& pause& exit /b 1)
if not "%~1"=="" if /i "%~x1"==".zip" set "PACK=%~f1"
if not defined PACK (
  pushd "%~dp0"
  for %%z in (*.zip) do (
    set "TEN=%%~nz"
    if not defined PACK if /i not "!TEN:~0,17!"=="lf2-online-upload" if /i not "!TEN:~0,7!"=="xoi-kit" set "PACK=%%~fz"
  )
  popd
)
if not defined PACK (echo No mod zip file next to this file - put a mod zip file ^(e.g. naruto.zip^) next to this file.& pause& exit /b 1)
tasklist /FI "IMAGENAME eq openlf2.exe" 2>nul | find /I "openlf2.exe" >nul && (
  echo openlf2.exe is running ^(the game, train.bat or spsa.bat^). Close them all, then run this file again.
  pause
  exit /b 1
)
if exist "%TAM%" rmdir /s /q "%TAM%"
mkdir "%TAM%"

echo Checking, about 2 minutes. The game window can appear and close by itself - do not press anything.
(
  echo ===== OpenLF2 check %DATE% %TIME% =====
  echo Game: %GAME%
  for %%g in ("%GAME%") do echo   size %%~zg bytes, modified %%~tg
  if exist "%~dp0version.txt" (echo XOI kit:& type "%~dp0version.txt")
  echo Mod: %PACK%
  echo Session: %SESSIONNAME% ^(Console = sitting at the PC; RDP-Tcp = Remote Desktop^)
  ver
  echo CPU: %NUMBER_OF_PROCESSORS% threads, %PROCESSOR_ARCHITECTURE% %PROCESSOR_ARCHITEW6432%
) >"%BAO%"
powershell -NoProfile -Command "'RAM: ' + [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1) + ' GB'" >>"%BAO%" 2>&1
rem The installed game's build: x86 (32-bit), x64 or arm64 - read from the start of the .exe file.
powershell -NoProfile -Command "$f = [IO.File]::OpenRead($env:GAME); try { $b = New-Object byte[] 4096; [void]$f.Read($b, 0, 4096) } finally { $f.Close() }; $o = [BitConverter]::ToInt32($b, 60); $m = [BitConverter]::ToUInt16($b, $o + 4); $k = switch ($m) { 0x14c { 'x86 (32-bit)' } 0x8664 { 'x64 (64-bit)' } 0xaa64 { 'arm64' } default { 'unknown' } }; 'Game build: ' + $k" >>"%BAO%" 2>&1
echo.>>"%BAO%"
echo ----- Graphics card ----->>"%BAO%"
powershell -NoProfile -Command "Get-CimInstance Win32_VideoController | ForEach-Object { $_.Name + ' / driver ' + $_.DriverVersion + ' / ' + $_.VideoModeDescription }" >>"%BAO%" 2>&1

rem 1. Without a window (like train.bat, spsa.bat): load every fighter of the mod.
echo.>>"%BAO%"
echo ----- 1. Run without a window ^(like spsa.bat, train.bat^) ----->>"%BAO%"
set "BENCH="
if exist "%~dp0tools\ai-bench\loadall.lua" set "BENCH=%~dp0tools\ai-bench"
if defined BENCH (
  mkdir "%TAM%\bench"
  pushd "%BENCH%"
  copy /y *.lua "%TAM%\bench\" >nul
  copy /y package.manifest "%TAM%\bench\" >nul
  popd
  >"%TAM%\bench\config.lua" echo return {command = "loadall"}
  "%GAME%" --pack "%PACK%" --mod "%TAM%\bench" --input-trace "" --seed 1 >"%TAM%\no-window.txt" 2>&1
  set "MA=!errorlevel!"
  type "%TAM%\no-window.txt" >>"%BAO%"
  echo [exit code !MA!]>>"%BAO%"
) else (
  echo ^(skipped: no tools\ai-bench next to this file^)>>"%BAO%"
)

rem 2. With a window, one renderer at a time: after 15 seconds, is the game still running, and does it have a window?
set /a SO=0
for %%r in (software direct3d11 opengl gpu default default-newconfig) do call :thu_ve %%r

echo.>>"%BAO%"
echo ----- 3. Errors Windows logged about openlf2.exe ----->>"%BAO%"
powershell -NoProfile -Command "Get-WinEvent -FilterHashtable @{LogName='Application'; ProviderName='Application Error','Application Hang'} -MaxEvents 200 -ErrorAction SilentlyContinue | Where-Object { $_.Message -match 'openlf2' } | Select-Object -First 3 | ForEach-Object { '--- ' + $_.TimeCreated; $_.Message }" >>"%BAO%" 2>&1
echo.
echo ===== Done. Send this file to the game's developer: "%BAO%" =====
type "%BAO%"
pause
exit /b 0

:thu_ve
set /a SO+=1
set "VE=--renderer %1"
set "CFG="
if /i "%1"=="default" set "VE="
rem (default-newconfig: the default renderer with a fresh config - the window position is not remembered, so the
rem window is not hidden when it opens.)
if /i "%1"=="default-newconfig" set "VE="
if /i "%1"=="default-newconfig" set "CFG=%TAM%\new-config"
if defined CFG mkdir "%CFG%" 2>nul
echo   ... renderer %1
start "check %1" /MIN cmd /c call "%SELF%" thu1 %1
ping -n 16 127.0.0.1 >nul 2>&1
set "TT=unknown"
for /f "delims=" %%s in ('powershell -NoProfile -Command "$p = Get-Process openlf2 -ErrorAction SilentlyContinue; if (-not $p) { 'exited' } elseif ($p | Where-Object { $_.MainWindowHandle -ne 0 }) { 'HAS A WINDOW' } else { 'still running but NO window' }"') do set "TT=%%s"
taskkill /F /IM openlf2.exe >nul 2>&1
ping -n 3 127.0.0.1 >nul 2>&1
echo.>>"%BAO%"
echo ----- 2.%SO% With a window, renderer: %1 - after 15 seconds: !TT! ----->>"%BAO%"
if exist "%TAM%\renderer-%1.txt" (type "%TAM%\renderer-%1.txt" >>"%BAO%") else (echo ^(this launch of the game did not run^)>>"%BAO%")
exit /b 0

rem --- One windowed launch of the game: %2 is the renderer (result file renderer-%2.txt) ---
:thu1
set "KQ=%TAM%\renderer-%~2.txt"
if defined CFG (
  "%GAME%" --config-dir "%CFG%" --pack "%PACK%" >"%KQ%" 2>&1
) else (
  "%GAME%" %VE% --pack "%PACK%" >"%KQ%" 2>&1
)
>>"%KQ%" echo [exit code %errorlevel%]
exit
