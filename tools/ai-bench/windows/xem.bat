@echo off
setlocal EnableDelayedExpansion
rem Xem may danh voi may trong cua so game, de quay clip: hai nhan vat chon bang TEN (hay id), hai muc may, so tran.
rem Cach dung: sua QUAN1, QUAN2 (va NAO1, NAO2 neu muon) o duoi, luu lai, roi nhay dup file nay.
rem De trong QUAN1 hoac QUAN2: chi in danh sach nhan vat (id, ten) va man nen (so, ten) cua ban mod, ghi ra
rem danh-sach.txt canh file nay.
rem Trong cua so: F1 dung / chay tiep, F5 chay nhanh, F4 bo tran dang xem (sang tran sau; het tran thi F4 dong
rem cua so). Quay clip bang OBS Studio hoac Xbox Game Bar
rem (Win+Alt+R bat / tat quay cua so dang chon). Cung HAT_GIONG thi ra dung cac tran cu: quay lai duoc.
rem ============ CHINH O DAY ============
rem Game da cai. De trong thi tu tim (Install for me only, all users, hoac thu muc OpenLF2 canh file nay).
set "GAME="
rem Ban mod: file zip hoac thu muc ban mod (thu muc co data\data.txt, ca thu muc xuat-ban.bat tao ra). Can bo so
rem cua XOI (spsa.bat) thi dung file <ten>-xoi.zip. De trong thi lay file *-xoi.zip dau tien canh file nay, khong
rem co thi file .zip dau tien; hoac keo tha file zip / thu muc ban mod vao file nay.
set "PACK="
rem Hai nhan vat: ten nhu trong game (Crimson, Deep...; hoa hay thuong deu duoc, go vai chu dau cung duoc: crim)
rem hoac id (8). Hai ben cung mot nhan vat cung duoc.
set "QUAN1=Crimson"
set "QUAN2=Crimson"
rem May dieu khien moi ben: xoi = XOI, smart = INSANE!, classic = may goc cua LF2
set "NAO1=xoi"
set "NAO2=smart"
rem Muc cua tran: -2 cho XOI / INSANE!; -1 khi co classic (may goc danh o muc CRAZY!)
set "MUC=-2"
rem So tran (hai ben doi cho moi tran)
set "VAN=5"
rem Man nen: ten (HK Coliseum, hk...) hoac so trong danh sach; de trong = ngau nhien nhu LF2
set "NEN="
rem Tran keo dai qua so tick nay (30 tick = 1 giay; 9000 = 5 phut) thi tinh hoa, sang tran sau
set "GIOI_HAN=9000"
rem Hat giong: cung so = cung cac tran (quay lai duoc); doi so = tran khac
set "HAT_GIONG=1"
rem Cach ve hinh (nhu choi.bat): de trong = opengl, khong mo duoc thi cach mac dinh cua game; hoac software, gpu
set "VE="
rem Thu muc tools\ai-bench va scripts cua goi (de trong thi tu tim canh file .bat nay)
set "BENCH="
set "SCRIPTS="
rem =====================================

rem Keo tha: file zip hay thu muc ban mod; file .exe (ca file .exe ma xuat-ban.bat tao ra) thi lay thu muc cua no.
if not "%~1"=="" (
  if /i "%~x1"==".exe" (
    set "PACK=%~dp1"
    set "PACK=!PACK:~0,-1!"
  ) else (
    set "PACK=%~f1"
  )
)
if not defined PACK (
  pushd "%~dp0"
  for %%z in (*-xoi.zip) do if not defined PACK set "PACK=%%~fz"
  for %%z in (*.zip) do (
    set "TEN=%%~nz"
    if not defined PACK if /i not "!TEN:~-10!"=="-xoi-truoc" if /i not "!TEN:~0,17!"=="lf2-online-upload" if /i not "!TEN:~0,7!"=="xoi-kit" set "PACK=%%~fz"
  )
  popd
)
if not defined GAME (
  for %%g in ("%LOCALAPPDATA%\Programs\OpenLF2\openlf2.exe" "%ProgramFiles(x86)%\OpenLF2\openlf2.exe" "%ProgramFiles%\OpenLF2\openlf2.exe" "%~dp0OpenLF2\openlf2.exe") do (
    if not defined GAME if exist "%%~g" set "GAME=%%~g"
  )
)
if not defined GAME set "GAME=%LOCALAPPDATA%\Programs\OpenLF2\openlf2.exe"
if not defined BENCH (
  if exist "%~dp0tools\ai-bench\show.lua" set "BENCH=%~dp0tools\ai-bench"
  if exist "%~dp0show.lua" set "BENCH=%~dp0."
  if exist "%~dp0..\show.lua" set "BENCH=%~dp0.."
)
if not defined SCRIPTS (
  if exist "%~dp0scripts\base\game\smart_ai.lua" set "SCRIPTS=%~dp0scripts"
  if exist "%~dp0..\..\scripts\base\game\smart_ai.lua" set "SCRIPTS=%~dp0..\..\scripts"
  if exist "%~dp0..\..\..\scripts\base\game\smart_ai.lua" set "SCRIPTS=%~dp0..\..\..\scripts"
)
if not exist "%GAME%" (echo Khong thay game "%GAME%": cai OpenLF2 ^(bo cai OpenLF2-Windows-x64.exe o muc Releases cua trang GitHub cua du an, chon Install for me only^), hoac sua dong GAME o dau file.& pause& exit /b 1)
if not defined PACK (echo Khong thay ban mod: dat file zip canh file nay, keo tha file zip hay thu muc ban mod vao file nay, hoac sua dong PACK o dau file.& pause& exit /b 1)
if not exist "%PACK%" (echo Khong thay ban mod "%PACK%" - sua dong PACK o dau file.& pause& exit /b 1)
if not defined BENCH (echo Khong thay thu muc tools\ai-bench ^(co show.lua^) canh file nay.& pause& exit /b 1)
if not exist "%BENCH%\names.lua" (echo Thu muc "%BENCH%" chua co names.lua: can goi ban 54 tro len.& pause& exit /b 1)

rem Mot ban sao cua tools\ai-bench voi config.lua rieng, trong thu muc xem canh file nay.
set "XEM=%~dp0xem"
if exist "%XEM%" rmdir /s /q "%XEM%"
mkdir "%XEM%"
copy /y "%BENCH%\*.lua" "%XEM%\" >nul
copy /y "%BENCH%\package.manifest" "%XEM%\" >nul
rem Scripts cua game da cai, cap nhat bang scripts cua goi (goi chi chua file da doi): khoi cai lai game.
set "XS="
if defined SCRIPTS (
  for %%g in ("%GAME%") do set "CAI=%%~dpgscripts"
  if exist "!CAI!\base\game\match.lua" (
    xcopy /e /i /q /y "!CAI!" "%XEM%\scripts" >nul
    xcopy /e /i /q /y "!SCRIPTS!" "%XEM%\scripts" >nul
    if exist "%XEM%\scripts\base\game\smart_ai.lua" (set XS=--scripts "%XEM%\scripts") else (echo [CHU Y] Khong ghep duoc scripts - dung scripts cua game da cai.)
  )
)

if "%QUAN1%"=="" goto danh_sach
if "%QUAN2%"=="" goto danh_sach

rem (Ten trong [==[ ]==]: ky tu nao cung duoc, tru chinh dau ]==].)
>"%XEM%\config.lua" echo return {command = "show", brains = {"%NAO1%", "%NAO2%"}, ids = {[==[%QUAN1%]==], [==[%QUAN2%]==]}, games = %VAN%, difficulty = %MUC%, background = [==[%NEN%]==], limit = %GIOI_HAN%}
set "XR=--renderer opengl"
if defined VE set "XR=--renderer %VE%"
echo Ban mod: %PACK%
echo %QUAN1% ^(%NAO1%^) danh voi %QUAN2% ^(%NAO2%^), %VAN% tran, hat giong %HAT_GIONG%.
echo F1 dung / chay tiep, F5 chay nhanh, F4 bo tran dang xem ^(het tran: F4 dong cua so^). Ti so: "%XEM%\xem.txt"
rem Ma thoat khac 0 la loi; game bi Windows tat ngang thi ma am: so sanh voi 0 (xem choi.bat).
"%GAME%" %XR% %XS% --pack "%PACK%" --mod "%XEM%" --seed %HAT_GIONG% > "%XEM%\xem.txt" 2>&1
set "MA=!errorlevel!"
if not "!MA!"=="0" if not defined VE (
  echo Cach ve opengl khong mo duoc tren may nay ^(ma thoat !MA!^) - thu lai voi cach ve mac dinh cua game ...
  "%GAME%" %XS% --pack "%PACK%" --mod "%XEM%" --seed %HAT_GIONG% > "%XEM%\xem.txt" 2>&1
  set "MA=!errorlevel!"
)
echo.
findstr /b /c:"show:" "%XEM%\xem.txt"
findstr /c:"ERROR" "%XEM%\xem.txt"
if not "!MA!"=="0" (
  echo.
  echo Game dung voi loi ^(ma thoat !MA!^) - xem "%XEM%\xem.txt". Cua so chi xanh hay den: sua dong VE o dau file.
)
pause
exit /b 0

:danh_sach
rem Chay ngam mot lan (khong cua so): in nhan vat va man nen cua ban mod.
>"%XEM%\config.lua" echo return {command = "list"}
"%GAME%" %XS% --pack "%PACK%" --mod "%XEM%" --input-trace "" > "%XEM%\list.txt" 2>&1
set "DS=%~dp0danh-sach.txt"
> "%DS%" echo Ban mod: %PACK%
>> "%DS%" echo.
>> "%DS%" echo Nhan vat ^(id ten file; hidden = nhan vat an cua LF2^):
for /f "tokens=2,3,4,5" %%a in ('findstr /b /c:"fighter " "%XEM%\list.txt"') do >> "%DS%" echo   %%a  %%b   ^(%%c^) %%d
>> "%DS%" echo.
>> "%DS%" echo Man nen ^(so ten - dung cho NEN^):
for /f "tokens=1,*" %%a in ('findstr /b /c:"background " "%XEM%\list.txt"') do >> "%DS%" echo   %%b
type "%DS%"
findstr /c:"ERROR" "%XEM%\list.txt"
echo.
echo Da ghi danh sach vao "%DS%". Sua QUAN1, QUAN2 o dau file nay ^(ten hay id^) roi chay lai.
pause
exit /b 0
