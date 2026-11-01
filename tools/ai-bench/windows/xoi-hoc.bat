@echo off
setlocal EnableDelayedExpansion
rem XOI - hoc tung cap nhan vat cho muc kho XOI (OpenLF2 ban 25 tro len).
rem Cho may INSANE! danh VAN tran moi cap nhan vat cua ban mod (hai chieu), ghi lai chieu nao cua ai
rem dung voi ai thi duoc gi, roi dong goi thanh xoi\notes.txt trong mot ban sao cua file zip ban mod.
rem Chay nhieu dot (moi dot mot HAT_GIONG_DAU khac) thi bo nho cong don. Dot sau co the cho hai may XOI
rem (dung bo nho da co) danh voi nhau de hoc tiep (NAO=xoi) - nho do lai sau moi dot, giu dot nao lam XOI manh hon.
rem ============ CHINH O DAY ============
rem Game da cai (Install for me only). Chon "all users" thi doi thanh "C:\Program Files (x86)\OpenLF2\openlf2.exe"
set "GAME=%LOCALAPPDATA%\Programs\OpenLF2\openlf2.exe"
rem File zip ban mod, nam canh file .bat nay
set "PACK=%~dp0naruto.zip"
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
rem (File nay tu goi lai chinh no de chay tung tien trinh: "chay1 <so thu tu>".)
if /i "%~1"=="chay1" goto chay1
rem Chay voi "gop" (hay keo tha bat ky thu muc nao vao file nay): chi gop lai va dong goi, khong hoc them.
if not "%~1"=="" goto gop

if not exist "%GAME%" (echo Khong thay game "%GAME%" - sua dong GAME o dau file.& pause& exit /b 1)
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

echo Mo %N% tien trinh hoc ^(%NAO% danh %NAO%^), moi cap %VAN% tran, hat giong tu %HAT_GIONG_DAU% + 1 ...
for /L %%k in (1,1,%N%) do start "XOI %%k" /MIN "%~f0" chay1 %%k
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

rem Dong goi: ban sao cua file zip ban mod, them xoi/notes.txt vao thu muc game (canh thu muc data).
if not exist "%PACK%" (echo Khong thay "%PACK%" de dong goi.& pause& exit /b 1)
set "XPACK=%PACK%"
set "XOUT=%OUT%"
set "XNOTES=%XOI%\notes.txt"
rem (Ban dong goi lan truoc duoc giu lai thanh <ten>-xoi-truoc.zip, de do so sanh voi ban moi.)
for %%z in ("%PACK%") do set "TRUOC=%%~dpnz-xoi-truoc.zip"
if exist "%OUT%" copy /y "%OUT%" "%TRUOC%" >nul
del /q "%OUT%" 2>nul
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; Add-Type -AssemblyName System.IO.Compression; Add-Type -AssemblyName System.IO.Compression.FileSystem; Copy-Item -LiteralPath $env:XPACK -Destination $env:XOUT -Force; $z=[System.IO.Compression.ZipFile]::Open($env:XOUT,'Update'); try { $e=$z.Entries | Where-Object { $_.FullName -imatch '(^|[\\/])data[\\/]data\.txt$' } | Sort-Object { $_.FullName.Length } | Select-Object -First 1; if (-not $e) { throw 'zip khong co data/data.txt' }; $root=$e.FullName.Substring(0, $e.FullName.Length - 13); $name=$root + 'xoi/notes.txt'; foreach ($old in @($z.Entries | Where-Object { $_.FullName -ieq $name })) { $old.Delete() }; [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($z, $env:XNOTES, $name) } finally { $z.Dispose() }; Write-Host ('Da them ' + $name)"
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
