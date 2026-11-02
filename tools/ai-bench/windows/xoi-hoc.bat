@echo off
setlocal EnableDelayedExpansion
rem XOI - hoc tung cap nhan vat cho muc kho XOI (OpenLF2 ban 25 tro len).
rem Cho may INSANE! danh VAN tran moi cap nhan vat cua ban mod (hai chieu), ghi lai chieu nao cua ai
rem dung voi ai thi duoc gi, roi dong goi thanh xoi\notes.txt trong mot ban sao cua file zip ban mod.
rem Chay nhieu dot (moi dot mot HAT_GIONG_DAU khac) thi bo nho cong don. Dot sau co the cho hai may XOI
rem (dung bo nho da co) danh voi nhau de hoc tiep (NAO=xoi) - nho do lai sau moi dot, giu dot nao lam XOI manh hon.
rem ============ CHINH O DAY ============
rem Game da cai. De trong thi tu tim (Install for me only, all users, hoac thu muc OpenLF2 canh file nay).
set "GAME="
rem File zip ban mod. De trong thi lay file .zip dau tien canh file nay (tru cac file *-xoi.zip file nay tao ra);
rem hoac keo tha file zip ban mod vao file nay. Vi du: set "PACK=%~dp0naruto.zip"
set "PACK="
rem Id cac nhan vat se hoc, cach nhau bang dau cach (vi du "1 2 3 7 18"), hoac all = moi nhan vat cua ban mod
set "IDS=all"
rem So tran moi cap nhan vat (moi cap hoc ca hai chieu: a danh b va b danh a)
set "VAN=100"
rem So tien trinh chay cung luc (moi tien trinh chiem mot nhan CPU)
set "SONG_SONG=%NUMBER_OF_PROCESSORS%"
rem Hat giong dau tien; tien trinh thu i dung hat giong HAT_GIONG_DAU + i. Doi so nay moi dot hoc them.
set "HAT_GIONG_DAU=5000"
rem Ai danh trong luc hoc: smart = hai may INSANE! (dot dau); xoi = hai may XOI dung bo nho da gop cua cac dot
rem truoc (xoi-<ten ban mod>\notes.txt) de hoc tiep tren no
set "NAO=smart"
rem Thu muc tools\ai-bench va scripts cua goi ban 25 tro len (de trong thi tu tim canh file .bat nay)
set "BENCH="
set "SCRIPTS="
rem =====================================

rem (File nay tu goi lai chinh no de chay tung tien trinh: "chay1 <so thu tu>", voi ban mod da chon o PACK_DA_CHON;
rem qua cmd /c call, de duong dan co dau cach hay dau ngoac ^(^) van chay - xem spsa.bat.)
if /i "%~1"=="chay1" set "PACK=%PACK_DA_CHON%"
rem Keo tha vao file nay: file zip = hoc ban mod ay. Chu gop, hay mot thu muc (thu muc xoi-<ten> = ban mod <ten>):
rem chi gop lai cac dot da hoc va dong goi, khong hoc them.
set "GOP="
if not "%~1"=="" if /i not "%~1"=="chay1" set "GOP=1"
if defined GOP if /i "%~x1"==".zip" if not exist "%~1\" (
  set "PACK=%~f1"
  set "GOP="
)
if defined GOP if exist "%~1\data\data.txt" (
  echo "%~1" la thu muc ban mod. Keo no vao choi.bat mot lan de nen thanh file zip, roi keo file zip vao day.
  pause
  exit /b 1
)
if defined GOP if exist "%~1\" (
  set "THU=%~nx1"
  if /i "!THU:~0,4!"=="xoi-" if not defined PACK (
    set "PACK=%~dp0!THU:~4!.zip"
    if exist "%~f1\ban-mod.txt" set /p PACK=<"%~f1\ban-mod.txt"
  )
)
if not defined PACK (
  pushd "%~dp0"
  for %%z in (*.zip) do (
    set "TEN=%%~nz"
    if not defined PACK if /i not "!TEN:~-4!"=="-xoi" if /i not "!TEN:~-10!"=="-xoi-truoc" if /i not "!TEN:~0,17!"=="lf2-online-upload" if /i not "!TEN:~0,7!"=="xoi-kit" set "PACK=%%~fz"
  )
  popd
)
if not defined PACK (echo Khong thay file zip ban mod: dat file zip ban mod canh file nay, keo tha no vao file nay, hoac sua dong PACK o dau file.& pause& exit /b 1)
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
rem Moi ban mod mot thu muc xoi-<ten ban mod>: moi dot hoc trong dot-<hat giong>, bo nho gop o notes.txt
set "XOI=%~dp0xoi-%TEN%"
set "KQ=%XOI%\dot-%HAT_GIONG_DAU%"
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

if not exist "%GAME%" (echo Khong thay game "%GAME%": cai OpenLF2 ^(bo cai OpenLF2-Windows-x64.exe o muc Releases cua trang GitHub cua du an, chon Install for me only^), hoac sua dong GAME o dau file.& pause& exit /b 1)
if not exist "%PACK%" (echo Khong thay ban mod "%PACK%" - sua dong PACK o dau file.& pause& exit /b 1)
if not defined BENCH (echo Khong thay thu muc tools\ai-bench co learn.lua - can goi ban 25 tro len.& pause& exit /b 1)
if not exist "%BENCH%\learn.lua" (echo Khong thay "%BENCH%\learn.lua" - can goi ban 25 tro len.& pause& exit /b 1)
if exist "%KQ%\p1" (
  echo Dot hoc voi hat giong %HAT_GIONG_DAU% da co: "%KQ%"
  echo Doi HAT_GIONG_DAU de hoc them, hoac chay file nay voi chu gop de chi gop lai.
  pause
  exit /b 1
)
if /i "%NAO%"=="xoi" (
  if not exist "%XOI%\notes.txt" (echo NAO=xoi can bo nho cua dot truoc: "%XOI%\notes.txt" chua co - chay dot dau voi NAO=smart.& pause& exit /b 1)
  for %%f in ("%XOI%\notes.txt") do if %%~zf LSS 10 (echo Bo nho "%XOI%\notes.txt" dang trong - chay dot dau voi NAO=smart.& pause& exit /b 1)
)
if not exist "%KQ%" mkdir "%KQ%"
rem (Nho file zip ban mod da hoc, de keo tha thu muc xoi-<ten> vao file nay ve sau la gop va dong goi duoc.)
>"%XOI%\ban-mod.txt" echo !PACK!

rem Scripts cua game da cai, cap nhat bang scripts cua goi (goi chi chua file da doi): khoi cai lai game.
if defined SCRIPTS (
  for %%g in ("%GAME%") do set "CAI=%%~dpgscripts"
  if exist "!CAI!\base\game\match.lua" (
    echo Ghep scripts cua game da cai voi scripts cua goi ...
    xcopy /e /i /q /y "!CAI!" "%KQ%\scripts" >nul
    xcopy /e /i /q /y "!SCRIPTS!" "%KQ%\scripts" >nul
    if not exist "%KQ%\scripts\base\game\smart_ai.lua" echo [CHU Y] Khong ghep duoc - dung scripts cua game da cai, game phai la ban 25 tro len.
  ) else (
    echo [CHU Y] Khong thay "!CAI!" - dung scripts cua game da cai, game phai la ban 25 tro len.
  )
)

if /i "%IDS%"=="all" (set "IDS_LUA="all"") else (set "IDS_LUA={%IDS: =, %}")
set /a N=SONG_SONG
if %N% LSS 1 set /a N=1
rem NAO=xoi: hai may XOI, voi bo nho hien co chep vao tung tien trinh (module xoi_notes).
set "THEM="
if /i "%NAO%"=="xoi" set "THEM=, brains = {"xoi", "xoi"}, notes = "xoi_notes""
for /L %%k in (1,1,%N%) do (
  mkdir "%KQ%\p%%k" 2>nul
  copy /y "%BENCH%\*.lua" "%KQ%\p%%k\" >nul
  copy /y "%BENCH%\package.manifest" "%KQ%\p%%k\" >nul
  if /i "%NAO%"=="xoi" (
    >"%KQ%\p%%k\xoi_notes.lua" echo return {text = [==[
    type "%XOI%\notes.txt" >>"%KQ%\p%%k\xoi_notes.lua"
    >>"%KQ%\p%%k\xoi_notes.lua" echo ]==]}
    >>"%KQ%\p%%k\package.manifest" echo module=xoi_notes^|xoi_notes.lua
  )
  >"%KQ%\p%%k\config.lua" echo return {command = "learn", games = %VAN%, difficulty = -2, limit = 9000, ids = !IDS_LUA!, part = %%k, parts = %N%!THEM!}
)

echo Ban mod: "%PACK%"
echo Mo %N% tien trinh hoc ^(%NAO% danh %NAO%^), moi cap %VAN% tran, hat giong tu %HAT_GIONG_DAU% + 1 ...
set "PACK_DA_CHON=%PACK%"
for /L %%k in (1,1,%N%) do start "XOI %%k" /MIN cmd /c call "%~f0" chay1 %%k
echo Dang hoc (moi tien trinh la mot cua so thu nho, khong ve hinh). Ket qua ghi vao "%KQ%"
echo Cho cac tien trinh openlf2.exe ket thuc (dung mo game choi trong luc nay)...
if defined KHONG_CHO exit /b 0
:cho
timeout /t 10 /nobreak >nul
tasklist /FI "IMAGENAME eq openlf2.exe" 2>nul | find /I "openlf2.exe" >nul && goto cho

:gop
rem Gop moi dot hoc cua ban mod nay (xoi-<ten ban mod>\dot-*) thanh xoi-<ten ban mod>\notes.txt
set /a CAP=0, LOI=0, DOT=0
if not exist "%XOI%" mkdir "%XOI%"
type nul > "%XOI%\notes.txt"
for /f "delims=" %%d in ('dir /b /ad "%XOI%\dot-*" 2^>nul') do call :gop_dot "%XOI%\%%d"
if %DOT% EQU 0 (echo Chua co dot hoc nao cua "%TEN%" canh file nay.& pause& exit /b 1)
echo.
echo ===== %DOT% dot hoc, %CAP% cap nhan vat da hoc xong =====
if %LOI% GTR 0 echo [LOI] %LOI% tien trinh chua xong hoac co loi - xem cac dong o tren.
for %%f in ("%XOI%\notes.txt") do echo Bo nho: "%%~ff" (%%~zf byte)
rem (Ban sao dung cho viec chep tay: thu muc xoi nay dat vao trong zip, canh thu muc data.)
if not exist "%XOI%\goi\xoi" mkdir "%XOI%\goi\xoi"
copy /y "%XOI%\notes.txt" "%XOI%\goi\xoi\notes.txt" >nul

rem Dong goi: ban sao cua file zip ban mod, them xoi/notes.txt vao thu muc game (canh thu muc data) - va xoi/tune.txt,
rem bo so rieng cua ban mod ma spsa.bat da chinh (xoi-<ten ban mod>\tune.txt), neu co.
if not exist "%PACK%" (echo Khong thay "%PACK%" de dong goi.& pause& exit /b 1)
set "XPACK=%PACK%"
set "XOUT=%OUT%"
set "XNOTES=%XOI%\notes.txt"
set "XTUNE="
if exist "%XOI%\tune.txt" set "XTUNE=%XOI%\tune.txt"
rem (Ban dong goi lan truoc duoc giu lai thanh <ten>-xoi-truoc.zip, de do so sanh voi ban moi.)
for %%z in ("%PACK%") do set "TRUOC=%%~dpnz-xoi-truoc.zip"
if exist "%OUT%" copy /y "%OUT%" "%TRUOC%" >nul
del /q "%OUT%" 2>nul
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; Add-Type -AssemblyName System.IO.Compression; Add-Type -AssemblyName System.IO.Compression.FileSystem; Copy-Item -LiteralPath $env:XPACK -Destination $env:XOUT -Force; $z=[System.IO.Compression.ZipFile]::Open($env:XOUT,'Update'); try { $e=$z.Entries | Where-Object { $_.FullName -imatch '(^|[\\/])data[\\/]data\.txt$' } | Sort-Object { $_.FullName.Length } | Select-Object -First 1; if (-not $e) { throw 'zip khong co data/data.txt' }; $root=$e.FullName.Substring(0, $e.FullName.Length - 13); foreach ($f in @(@($env:XNOTES, 'xoi/notes.txt'), @($env:XTUNE, 'xoi/tune.txt'))) { if ($f[0] -and (Test-Path -LiteralPath $f[0])) { $name=$root + $f[1]; foreach ($old in @($z.Entries | Where-Object { $_.FullName -ieq $name })) { $old.Delete() }; [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($z, $f[0], $name); Write-Host ('Da them ' + $name) } } } finally { $z.Dispose() }"
if not exist "%OUT%" goto khong_goi
if errorlevel 1 goto khong_goi
echo.
echo Xong: "%OUT%"
echo Tai file nay len relay (trang admin, cung id voi ban mod cu) - moi nguoi chon muc XOI se dung bo nho nay.
echo Muon hoc them: doi HAT_GIONG_DAU roi chay lai - bo nho cong don qua cac dot ^(NAO=xoi: XOI danh XOI^).
if exist "%TRUOC%" echo Ban truoc lan gop nay: "%TRUOC%" - do ca hai bang dau-nhieu.bat ^(cung HAT_GIONG_DAU^), giu ban manh hon.
if "%KHONG_DUNG%"=="" pause
exit /b 0

:khong_goi
(
  echo [LOI] Khong dong goi duoc. Tu lam bang tay: mo file zip ban mod ^(bang 7-Zip hoac Explorer^),
  echo       vao thu muc co thu muc data, keo thu muc "%XOI%\goi\xoi" vao do, roi tai zip len relay.
)
if "%KHONG_DUNG%"=="" pause
exit /b 1

:gop_dot
set /a DOT+=1
for /f "delims=" %%p in ('dir /b /ad "%~1\p*" 2^>nul') do call :gop1 "%~1\%%p"
exit /b 0

:gop1
if not exist "%~1\out.txt" (set /a LOI+=1& echo [LOI] "%~1" chua chay& exit /b 0)
findstr /C:"XOI " "%~1\out.txt" >> "%XOI%\notes.txt"
for /f "delims=" %%l in ('findstr /C:" done: " "%~1\out.txt"') do set /a CAP+=1
findstr /C:"LEARN DONE" "%~1\out.txt" >nul && exit /b 0
set /a LOI+=1
echo [LOI] "%~1" chua xong hoac co loi:
findstr /C:"ERROR" /C:"failed" "%~1\out.txt"
exit /b 0

:chay1
rem Mot tien trinh: game chay ngam (khong cua so), phan viec thu %2, ket qua vao p%2\out.txt, xong thi dong cua so.
set /a SEED=HAT_GIONG_DAU+%~2
set "XS="
if exist "%KQ%\scripts\base\game\smart_ai.lua" set XS=--scripts "%KQ%\scripts"
"%GAME%" --pack "%PACK%" %XS% --mod "%KQ%\p%~2" --seed %SEED% --input-trace "" > "%KQ%\p%~2\out.txt" 2>&1
exit
