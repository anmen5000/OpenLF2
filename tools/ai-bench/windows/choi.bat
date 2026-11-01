@echo off
setlocal EnableDelayedExpansion
rem Choi ban mod bang OpenLF2 tren may tinh, du cac muc may: Easy, Normal, Difficult, CRAZY, INSANE, XOI.
rem (File .exe goc cua ban mod la game LF2 cu, chi co toi CRAZY: INSANE va XOI nam trong OpenLF2.)
rem Cach dung: dat file nay canh file zip ban mod roi nhay dup. Hoac keo tha vao file nay: file zip ban mod,
rem thu muc ban mod (thu muc co data\data.txt), hay file .exe cua ban mod - kem file bo nho XOI (.txt) neu co.
rem Thu muc (hay .exe) duoc nen thanh file zip canh file nay; co bo nho thi thanh <ten>-xoi.zip (co san XOI).
rem ============ CHINH O DAY ============
rem Game da cai. De trong thi tu tim (Install for me only, all users, hoac thu muc OpenLF2 canh file nay).
set "GAME="
rem Ban mod: file zip hoac thu muc. De trong thi lay file *-xoi.zip (co bo nho XOI) dau tien canh file nay,
rem khong co thi file .zip dau tien.
set "PACK="
rem Bo nho XOI cua ban mod (notes.txt cua nguoi da huan luyen). De trong thi tim <ten ban mod>-notes.txt hoac
rem xoi-<ten ban mod>\notes.txt canh file nay. File *-xoi.zip da co san bo nho thi khong can.
set "NOTES="
rem Bo ve hinh: de trong la mac dinh; may nao cua so game chi xanh tron thi doi thanh opengl (hoac software).
set "VE="
rem =====================================

rem Nhung gi keo tha vao: file .txt la bo nho, thu muc / file .exe / file zip la ban mod.
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
    if not defined PACK if /i not "!TEN:~-10!"=="-xoi-truoc" if /i not "!TEN:~0,17!"=="lf2-online-upload" if /i not "!TEN:~0,7!"=="xoi-kit" set "PACK=%%~fz"
  )
  popd
)
if not defined PACK (echo Khong thay ban mod: keo tha file zip hay thu muc ban mod vao choi.bat, hoac sua dong PACK o dau file.& pause& exit /b 1)
if not exist "%PACK%" (echo Khong thay "%PACK%".& pause& exit /b 1)
set "THU_MUC="
if exist "%PACK%\" set "THU_MUC=1"
for %%p in ("%PACK%") do (
  set "TEN=%%~np"
  set "DUOI=%%~xp"
)
if defined THU_MUC (
  for %%p in ("%PACK%") do set "TEN=%%~nxp"
) else if /i not "%DUOI%"==".zip" (
  echo "%PACK%" khong phai file zip. OpenLF2 doc ban mod dang file .zip hoac thu muc:
  echo giai nen file .rar / .7z truoc ^(bang 7-Zip^), roi keo thu muc ban mod vao choi.bat.
  pause
  exit /b 1
)

if not defined GAME (
  for %%g in ("%LOCALAPPDATA%\Programs\OpenLF2\openlf2.exe" "%ProgramFiles(x86)%\OpenLF2\openlf2.exe" "%ProgramFiles%\OpenLF2\openlf2.exe" "%~dp0OpenLF2\openlf2.exe") do (
    if not defined GAME if exist "%%~g" set "GAME=%%~g"
  )
)
if not defined GAME (echo Chua cai OpenLF2: tai bo cai OpenLF2-Windows-x64.exe o muc Releases cua trang GitHub cua du an, chon Install for me only.& pause& exit /b 1)
if not exist "%GAME%" (echo Khong thay game "%GAME%" - sua dong GAME o dau file.& pause& exit /b 1)

rem Bo nho XOI canh file nay, theo ten ban mod.
if not defined NOTES if exist "%~dp0%TEN%-notes.txt" set "NOTES=%~dp0%TEN%-notes.txt"
if not defined NOTES if exist "%~dp0xoi-%TEN%\notes.txt" set "NOTES=%~dp0xoi-%TEN%\notes.txt"
if defined NOTES if not exist "%NOTES%" (echo Khong thay bo nho "%NOTES%".& pause& exit /b 1)

rem Thu muc, hay ban mod kem bo nho: lam file zip moi canh file nay (ban mod goc giu nguyen).
set "GOC=%TEN%"
if /i "%GOC:~-4%"=="-xoi" set "GOC=%GOC:~0,-4%"
set "OUT="
if defined NOTES (
  set "OUT=%~dp0%GOC%-xoi.zip"
) else if defined THU_MUC (
  set "OUT=%~dp0%TEN%.zip"
)
if defined OUT (
  if defined NOTES (echo Them bo nho XOI "%NOTES%" vao ban mod ...) else (echo Nen thu muc ban mod thanh file zip ...)
  set "XSRC=%PACK%"
  set "XNOTES=%NOTES%"
  set "XOUT=!OUT!"
  powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; Add-Type -AssemblyName System.IO.Compression; Add-Type -AssemblyName System.IO.Compression.FileSystem; $src=$env:XSRC; $tmp=$env:XOUT + '.tmp'; if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }; if (Test-Path -LiteralPath $src -PathType Container) { $dir=(Resolve-Path -LiteralPath $src).ProviderPath.TrimEnd('\'); $base=Split-Path -Leaf $dir; $z=[System.IO.Compression.ZipFile]::Open($tmp,'Create'); try { foreach ($f in @(Get-ChildItem -LiteralPath $dir -Recurse -File)) { $rel=$f.FullName.Substring($dir.Length + 1).Replace('\','/'); if ($env:XNOTES -and $rel -imatch '(^|/)xoi/notes\.txt$') { continue }; [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($z, $f.FullName, $base + '/' + $rel, 'Fastest') } } finally { $z.Dispose() } } else { Copy-Item -LiteralPath $src -Destination $tmp -Force }; $mode='Read'; if ($env:XNOTES) { $mode='Update' }; $z=[System.IO.Compression.ZipFile]::Open($tmp,$mode); try { $e=$z.Entries | Where-Object { $_.FullName -imatch '(^|[\\/])data[\\/]data\.txt$' } | Sort-Object { $_.FullName.Length } | Select-Object -First 1; if (-not $e) { throw 'khong co data/data.txt - day khong phai thu muc game LF2' }; if ($env:XNOTES) { $root=$e.FullName.Substring(0, $e.FullName.Length - 13); $name=$root + 'xoi/notes.txt'; foreach ($old in @($z.Entries | Where-Object { $_.FullName -imatch '(^|[\\/])xoi[\\/]notes\.txt$' })) { $old.Delete() }; [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($z, $env:XNOTES, $name); Write-Host ('Da them ' + $name) } } finally { $z.Dispose() }; Move-Item -LiteralPath $tmp -Destination $env:XOUT -Force"
  if errorlevel 1 (
    del /q "!OUT!.tmp" 2>nul
    echo [LOI] Khong lam duoc file zip "!OUT!" - xem dong loi o tren.
    pause
    exit /b 1
  )
  if not exist "!OUT!" (echo [LOI] Khong lam duoc file zip "!OUT!".& pause& exit /b 1)
  set "PACK=!OUT!"
)

rem Scripts cua bo xoi-kit (hoac goi cap nhat) canh file nay, neu moi hon scripts cua game da cai, ghep len
rem scripts cua game da cai: khoi cai lai game. Game da cai moi hon thi dung luon game da cai.
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
    set "GHEP=%~dp0scripts-choi"
    if exist "!GHEP!" rmdir /s /q "!GHEP!"
    if exist "!CAI!\base\game\match.lua" xcopy /e /i /q /y "!CAI!" "!GHEP!" >nul
    xcopy /e /i /q /y "!MOI!" "!GHEP!" >nul
    if exist "!GHEP!\base\game\match.lua" (set XS=--scripts "!GHEP!") else (echo [CHU Y] Khong ghep duoc scripts - dung scripts cua game da cai.)
    echo May INSANE ban !V_MOI! cua bo xoi-kit, game da cai ban !V_CAI!
  ) else (
    echo May INSANE ban !V_CAI! cua game da cai
  )
)
set "XR="
if defined VE set "XR=--renderer %VE%"

echo Game: %GAME%
echo Ban mod: %PACK%
echo Chon nhan vat, them may (Com), o dong muc kho bam qua CRAZY la toi INSANE, roi XOI.
"%GAME%" %XR% %XS% --pack "%PACK%"
if errorlevel 1 (
  echo.
  echo Game dung voi loi ^(xem cac dong o tren^). Cua so game chi xanh tron: sua dong VE=opengl o dau file.
  pause
)
