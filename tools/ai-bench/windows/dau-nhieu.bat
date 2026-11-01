@echo off
setlocal EnableDelayedExpansion
rem Do may dau may hang loat: moi nhan CPU mot tien trinh openlf2.exe chay ngam, xong thi cong ket qua.
rem Mac dinh: moi nhan vat cua ban mod danh voi moi nhan vat khac (ca hai ben), khong can sua config.lua.
rem ============ CHINH O DAY ============
rem Game da cai (Install for me only). Chon "all users" thi doi thanh "C:\Program Files (x86)\OpenLF2\openlf2.exe"
set "GAME=%LOCALAPPDATA%\Programs\OpenLF2\openlf2.exe"
rem File zip ban mod, nam canh file .bat nay. Do XOI thi dung file <ten>-xoi.zip ma xoi-hoc.bat tao ra.
set "PACK=%~dp0naruto.zip"
rem Hai may dau voi nhau: xoi = XOI, smart = INSANE!, classic = may goc, smart@ai_alt = ban AI chep vao ai_alt.lua
set "NAO1=xoi"
set "NAO2=smart"
rem Muc kho cua tran: -2 (INSANE!/XOI); -1 khi co classic (may goc danh o muc CRAZY!)
set "MUC=-2"
rem Nhan vat: all = moi quan danh voi moi quan khac; hoac danh sach id, vi du "7 18 1 4".
rem De trong (set "IDS=") thi dung config.lua cua tools\ai-bench: moi tien trinh chay cung config do, hat giong khac.
set "IDS=all"
rem So tran moi cap moi chieu (a danh b VAN tran va b danh a VAN tran, doi ben moi tran)
set "VAN=10"
rem So tien trinh chay cung luc (moi tien trinh chiem mot nhan CPU)
set "SONG_SONG=%NUMBER_OF_PROCESSORS%"
rem Hat giong dau tien; tien trinh thu i dung hat giong HAT_GIONG_DAU + i. Doi so nay moi dot de co bo tran moi.
set "HAT_GIONG_DAU=1000"
rem Thu muc tools\ai-bench va scripts cua goi (de trong thi tu tim canh file .bat nay)
set "BENCH="
set "SCRIPTS="
rem =====================================

rem Moi dot (moi HAT_GIONG_DAU) mot thu muc ket qua rieng.
set "KQ=%~dp0ket-qua-%HAT_GIONG_DAU%"
if not defined BENCH (
  if exist "%~dp0tools\ai-bench\duel.lua" set "BENCH=%~dp0tools\ai-bench"
  if exist "%~dp0duel.lua" set "BENCH=%~dp0."
  if exist "%~dp0..\duel.lua" set "BENCH=%~dp0.."
)
if not defined SCRIPTS (
  if exist "%~dp0scripts\base\game\smart_ai.lua" set "SCRIPTS=%~dp0scripts"
  if exist "%~dp0..\..\scripts\base\game\smart_ai.lua" set "SCRIPTS=%~dp0..\..\scripts"
  if exist "%~dp0..\..\..\scripts\base\game\smart_ai.lua" set "SCRIPTS=%~dp0..\..\..\scripts"
)
rem (File nay tu goi lai chinh no de chay tung tien trinh: "chay1 <hat giong> <so thu tu>".)
if /i "%~1"=="chay1" goto chay1
rem Keo tha mot thu muc ket qua vao file nay: chi tinh lai tong hop, khong chay tran nao.
if not "%~1"=="" (
  set "KQ=%~1"
  goto tonghop
)

if not exist "%GAME%" (echo Khong thay game "%GAME%" - sua dong GAME o dau file.& pause& exit /b 1)
if not exist "%PACK%" (echo Khong thay ban mod "%PACK%" - sua dong PACK o dau file.& pause& exit /b 1)
if not defined BENCH (echo Khong thay thu muc tools\ai-bench canh file nay.& pause& exit /b 1)
if not defined IDS if not exist "%BENCH%\config.lua" (echo Khong thay "%BENCH%\config.lua"& pause& exit /b 1)
if not exist "%KQ%" mkdir "%KQ%"
del /q "%KQ%\run-*.txt" 2>nul
rem Scripts cua game da cai, cap nhat bang scripts cua goi (goi chi chua file da doi): khoi cai lai game.
if exist "%KQ%\scripts" rmdir /s /q "%KQ%\scripts"
if defined SCRIPTS (
  for %%g in ("%GAME%") do set "CAI=%%~dpgscripts"
  if exist "!CAI!\base\game\match.lua" (
    echo Ghep scripts cua game da cai voi scripts cua goi ...
    xcopy /e /i /q /y "!CAI!" "%KQ%\scripts" >nul
    xcopy /e /i /q /y "!SCRIPTS!" "%KQ%\scripts" >nul
    if not exist "%KQ%\scripts\base\game\smart_ai.lua" echo [CHU Y] Khong ghep duoc - dung scripts cua game da cai.
  )
)

set /a N=SONG_SONG
if %N% LSS 1 set /a N=1
for /L %%k in (1,1,%N%) do if exist "%KQ%\b%%k" rmdir /s /q "%KQ%\b%%k"
rem Tu dong: moi tien trinh mot ban sao cua tools\ai-bench voi config rieng (phan viec thu k cua vong dau).
set "IDS_LUA="
if defined IDS if /i "%IDS%"=="all" set "IDS_LUA="all""
if defined IDS if not defined IDS_LUA set "IDS_LUA={%IDS: =, %}"
if defined IDS (
  for /L %%k in (1,1,%N%) do (
    mkdir "%KQ%\b%%k"
    copy /y "%BENCH%\*.lua" "%KQ%\b%%k\" >nul
    copy /y "%BENCH%\package.manifest" "%KQ%\b%%k\" >nul
    >"%KQ%\b%%k\config.lua" echo return {command = "duel", brains = {"%NAO1%", "%NAO2%"}, difficulty = %MUC%, games = %VAN%, limit = 9000, audit = true, ids = !IDS_LUA!, part = %%k, parts = %N%}
  )
  echo Vong dau: %NAO1% voi %NAO2%, nhan vat: %IDS%, moi cap moi chieu %VAN% tran, chia cho %N% tien trinh.
) else (
  echo Moi tien trinh chay "%BENCH%\config.lua" voi hat giong rieng.
)

echo Mo %N% tien trinh, hat giong tu %HAT_GIONG_DAU% + 1 ...
for /L %%i in (1,1,%N%) do (
  set /a SEED=HAT_GIONG_DAU+%%i
  start "AI !SEED!" /MIN "%~f0" chay1 !SEED! %%i
)
echo Dang chay (moi tien trinh la mot cua so thu nho, khong ve hinh). Ket qua ghi vao "%KQ%"
echo Cho cac tien trinh openlf2.exe ket thuc (dung mo game choi trong luc nay)...
if defined KHONG_CHO exit /b 0
:cho
timeout /t 5 /nobreak >nul
tasklist /FI "IMAGENAME eq openlf2.exe" 2>nul | find /I "openlf2.exe" >nul && goto cho

:tonghop
if not exist "%KQ%\run-*.txt" (echo Khong co file run-*.txt trong "%KQ%"& pause& exit /b 1)
set /a W=0, L=0, D=0, N=0, LOI=0
set "KEYS="
set "DA_IN="
set "TU_DONG="
if exist "%KQ%\b1\config.lua" set "TU_DONG=1"
type nul > "%KQ%\cap.txt"
type nul > "%KQ%\quan.tmp"
echo.
for /f "delims=" %%n in ('dir /b /on "%KQ%\run-*.txt"') do (
  set "F=!KQ!\%%n"
  if not defined DA_IN (
    for /f "delims=" %%l in ('findstr /C:"brains:" "!F!"') do echo %%l
    set "DA_IN=!F!"
  )
  set "CO="
  for /f "tokens=3,5,8" %%a in ('findstr /C:"TOTAL " "!F!"') do (
    set /a W+=%%a, L+=%%b, D+=%%c, N+=1
    set "CO=1"
  )
  if not defined CO (
    set /a LOI+=1
    echo [LOI] %%n khong co dong TOTAL - loi trong file:
    findstr /C:"ERROR" "!F!"
  )
  for /f "tokens=2,4,6,8" %%a in ('findstr /C:"pair " "!F!"') do (
    if not defined FW_%%a echo %%a>>"!KQ!\quan.tmp"
    set /a FW_%%a+=%%c, FL_%%a+=%%d
    rem Ben phai: nhan vat thu hai do brains[2] dieu khien.
    set "B=%%b"
    set "B=!B::=!"
    set /a GW_!B!+=%%d, GL_!B!+=%%c
    if not defined TU_DONG (
      set "K=%%a_%%b"
      set "K=!K::=!"
      if not defined PW_!K! set "KEYS=!KEYS! !K!"
      set /a PW_!K!+=%%c, PL_!K!+=%%d
    )
  )
  if defined TU_DONG findstr /C:"pair " "!F!" >> "!KQ!\cap.txt"
)
echo.
if defined TU_DONG (
  echo ===== Tung nhan vat, danh voi moi quan khac =====
  echo   cot 1: nhan vat do brains[1] ^(%NAO1%^) dieu khien, doi thu do brains[2] ^(%NAO2%^): thang - thua, ti le
  echo   cot 2: nguoc lai, nhan vat do brains[2] dieu khien: ti le thang
  echo   chenh: cot 1 tru cot 2. Ca hai cot cung thap = nhan vat yeu ^(khong phai do AI^);
  echo   chenh duong = brains[1] choi nhan vat nay tot hon brains[2], chenh am = kem hon.
  for /f "usebackq delims=" %%i in ("%KQ%\quan.tmp") do call :in_quan %%i
  echo Ket qua tung cap: "%KQ%\cap.txt"
) else (
  echo ===== Tung cap ^(id ben trai do brains[1] dieu khien; thang ben trai - thang ben phai^) =====
  for %%k in (!KEYS!) do call :in_cap %%k
)
set /a TONG=W+L
if %TONG% EQU 0 (echo Khong co tran nao co ket qua.& pause& exit /b 1)
set /a "P10=W*1000/TONG, P1=P10/10, P2=P10%%10"
rem Sai so 95%% khi ti le quanh 50%%: 98 / can bac hai(so tran) phan tram.
set /a "T100=TONG*100, S=T100"
for /L %%z in (1,1,40) do set /a "S=(S+T100/S)/2"
set /a "E10=9800/S, E1=E10/10, E2=E10%%10"
echo.
echo ===== Tong hop %N% lan chay: %W% thang - %L% thua, %D% hoa =====
echo Ti le thang cua brains[1]: %P1%.%P2%%% tren %TONG% tran co ket qua, sai so khoang +-%E1%.%E2%%%
echo (Lech khoi 50%% it hon sai so thi coi nhu ngang nhau; chay them dot voi HAT_GIONG_DAU khac de chac hon.)
if %LOI% GTR 0 echo [LOI] %LOI% file khong co ket qua - xem cac dong ERROR o tren.
echo Chi tiet (tung tran, AUDIT) nam trong "%KQ%\run-*.txt"
if "%KHONG_DUNG%"=="" pause
exit /b 0

:chay1
rem Mot tien trinh: game chay ngam (khong cua so) voi hat giong %2, ket qua vao run-%2.txt, xong thi dong cua so.
set "XS="
if exist "%KQ%\scripts\base\game\smart_ai.lua" set XS=--scripts "%KQ%\scripts"
set "MOD=%BENCH%"
if exist "%KQ%\b%~3\config.lua" set "MOD=%KQ%\b%~3"
"%GAME%" --pack "%PACK%" %XS% --mod "%MOD%" --seed %~2 --input-trace "" > "%KQ%\run-%~2.txt" 2>&1
exit

:in_cap
for /f "tokens=1,2 delims=_" %%x in ("%~1") do echo   %%x vs %%y: !PW_%~1! - !PL_%~1!
exit /b 0

:in_quan
set "TEN="
for /f "tokens=3" %%t in ('findstr /C:"fighter %1 " "%DA_IN%" 2^>nul') do if not defined TEN set "TEN=%%t"
set /a "QW=FW_%1, QL=FL_%1, QT=QW+QL, RW=GW_%1, RL=GL_%1, RT=RW+RL"
if %QT% EQU 0 (echo   %1 %TEN%: chua co tran nao co ket qua& exit /b 0)
set /a "QP=QW*1000/QT, Q1=QP/10, Q2=QP%%10"
if %RT% EQU 0 (echo   %1 %TEN%: %QW% - %QL% ^(%Q1%.%Q2%%%^)& exit /b 0)
set /a "RP=RW*1000/RT, R1=RP/10, R2=RP%%10, DP=QP-RP"
set "SG=+"
if %DP% LSS 0 (set "SG=-"& set /a DP=-DP)
set /a "D1=DP/10, D2=DP%%10"
echo   %1 %TEN%: %QW% - %QL% ^(%Q1%.%Q2%%%^) ^| cot 2: %R1%.%R2%%% ^| chenh %SG%%D1%.%D2%
exit /b 0
