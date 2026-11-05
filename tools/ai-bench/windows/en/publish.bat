@echo off
setlocal EnableDelayedExpansion
rem Publishes a mod for ordinary players: the mod's own folder as its author shares it (bg, bgm, data, sprite..., its own
rem .exe too), with OpenLF2 added - every computer level: Easy, Normal, Difficult, CRAZY, INSANE, XOI. The players just
rem extract it and double-click "<name> - INSANE XOI.exe" - no OpenLF2 to install, no XOI kit, no original LF2 needed.
rem How to use: put this file next to the mod's zip file and double-click it - best of all the <name>-xoi.zip that
rem train.bat / spsa.bat made (XOI's notes and numbers inside). Or drag onto this file: the mod's zip file, folder or
rem .exe; with XOI's notes (notes.txt) and numbers (tune.txt), or the xoi-<name> folder holding them, if wanted.
rem Result: publish\<name>.zip next to this file - send it to the players; the folder publish\<name> is the extracted copy.
rem Needs OpenLF2 installed from package 50 or later (it plays the mod folder it lies in by itself) and publish.ps1 next
rem to this file.
rem ============ SETTINGS ============
rem Name of the published mod: its folder and zip file; the file the players double-click is "<name> - INSANE XOI.exe".
rem Left empty, the mod's name is used.
set "NAME="
rem The installed game. Left empty, it is looked for (Install for me only, all users, or an OpenLF2 folder next to this file).
set "GAME="
rem The mod: zip file or folder. Left empty, the first *-xoi.zip next to this file is used, else the first .zip file.
set "PACK="
rem XOI's notes (notes.txt from train.bat) and numbers (tune.txt from spsa.bat). Left empty, they are taken from the
rem xoi-<mod> folder next to this file - unless the mod is a *-xoi.zip (it has them inside already; they stay as they are).
set "NOTES="
set "TUNE="
rem Lock the hidden fighters for the players: Y = yes (no options button on the title screen, no unlocking, typing lf2.net
rem does not unlock either - for a mod whose hidden fighters are unbalanced), N = no (as in ordinary OpenLF2). Left empty, it asks when run.
set "LOCK_HIDDEN="
rem Words for the players: "README - INSANE XOI.txt" in the published mod is made from publish-README.txt next to this file
rem ({TEN}: the published name, {EXE}: the file the players double-click, {GOC}: the mod's own .exe). Edit that file (Notepad)
rem before running, to introduce the mod, name who made it...
rem =====================================

rem What was dragged onto this file: a folder with data\data.txt is the mod, a folder with notes.txt / tune.txt is XOI's
rem notes / numbers; a .txt file with "tune" in its name is the numbers, any other .txt file the notes; a .exe file: its
rem folder; anything else: the mod's zip file.
:doc_vao
if "%~1"=="" goto doc_xong
if exist "%~1\" (
  if exist "%~1\data\data.txt" (
    set "PACK=%~f1"
  ) else if exist "%~1\notes.txt" (
    set "NOTES=%~f1\notes.txt"
    if exist "%~1\tune.txt" set "TUNE=%~f1\tune.txt"
  ) else if exist "%~1\tune.txt" (
    set "TUNE=%~f1\tune.txt"
  ) else (
    set "PACK=%~f1"
  )
) else if /i "%~x1"==".txt" (
  set "TXT=%~n1"
  if /i not "!TXT:tune=!"=="!TXT!" (set "TUNE=%~f1") else (set "NOTES=%~f1")
) else if /i "%~x1"==".exe" (
  set "PACK=%~dp1"
  set "PACK=!PACK:~0,-1!"
) else (
  set "PACK=%~f1"
)
shift
goto doc_vao
:doc_xong

if not exist "%~dp0publish.ps1" (echo publish.ps1 is missing next to publish.bat: extract the whole XOI kit again.& pause& exit /b 1)
set "XB_KIT=%~dp0"
set "XB_TEN=%NAME%"
set "XB_GAME=%GAME%"
set "XB_PACK=%PACK%"
set "XB_NOTES=%NOTES%"
set "XB_TUNE=%TUNE%"
if not defined LOCK_HIDDEN (
  echo.
  echo Lock the hidden fighters for the players? No options button on the title screen, no unlocking, typing lf2.net does not unlock either.
  choice /c YN /n /m "Press Y = yes, N = no: "
  if errorlevel 2 (set "LOCK_HIDDEN=N") else (set "LOCK_HIDDEN=Y")
)
set "XB_KHOA_AN=%LOCK_HIDDEN%"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0publish.ps1"
if errorlevel 1 (
  echo.
  echo Nothing was published - see the [ERROR] line above.
  pause
  exit /b 1
)
pause
