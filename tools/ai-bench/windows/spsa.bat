@echo off
setlocal EnableDelayedExpansion
rem SPSA - may tu chinh cac con so phan doan cua INSANE! (va XOI) bang cach cho no danh voi chinh no
rem (OpenLF2 ban 32 tro len). Cac con so (31 so: diem cua mot chieu, nguong ra chieu, khoang cach, gan...) nam
rem trong scripts\base\game\smart_ai.lua (smart.tune_ranges).
rem Moi vong, moi tien trinh (mot nhan CPU) cho hai ban INSANE! danh nhau nhieu cap tran: ban "cong" co cac so
rem nhich len hoac xuong ngau nhien, ban "tru" nhich nguoc lai; ban nao danh tot hon thi cac so dich ve phia ban
rem ay. Het vong: lay trung binh cac tien trinh, vong sau bat dau tu do. Het moi vong: cho ban da chinh danh voi
rem ban goc de kiem tra. Ket qua: spsa\ket-qua.txt (gui file nay cho nguoi lam AI).
rem Tat may giua chung cung duoc: chay lai file nay la lam tiep tu vong dang do. Muon chinh lai tu dau: xoa thu
rem muc spsa (hoac doi HAT_GIONG va dat ten khac cho thu muc cu).
rem ============ CHINH O DAY ============
rem Game da cai. De trong thi tu tim (Install for me only, all users, hoac thu muc OpenLF2 canh file nay).
set "GAME="
rem File zip ban mod. De trong thi dung MOI file .zip ban mod canh file nay (tru *-xoi.zip, goi lf2-online-upload,
rem xoi-kit), cac tien trinh chia deu cho cac ban mod; keo tha mot file zip vao file nay thi chi dung ban mod ay.
set "PACK="
rem So vong; so cap tran (moi cap: hai tran, doi ben) moi tien trinh moi vong; so tien trinh chay cung luc
set "VONG=12"
set "CAP=40"
set "SONG_SONG=%NUMBER_OF_PROCESSORS%"
rem So cap tran moi tien trinh khi kiem tra ban da chinh voi ban goc sau vong cuoi (0 = bo qua kiem tra)
set "KIEM_TRA=20"
rem Hat giong dau (cac tran va cac lan nhich so deu theo hat giong: cung hat giong thi chay lai y het)
set "HAT_GIONG=9000"
rem Thu muc tools\ai-bench va scripts cua goi ban 32 tro len (de trong thi tu tim canh file .bat nay)
set "BENCH="
set "SCRIPTS="
rem =====================================

rem (File nay tu goi lai chinh no cho tung tien trinh: "chay1 <thu muc> <hat giong> <so thu tu ban mod>".)
if /i "%~1"=="chay1" goto chay1

set "SELF=%~f0"
set "LV=%~dp0spsa"
rem --- Ban mod: keo tha, dong PACK, hoac moi file zip ban mod canh file nay ---
set /a NP=0
if not "%~1"=="" if /i "%~x1"==".zip" if exist "%~f1" (
  set /a NP=1
  set "PACK_1=%~f1"
)
if !NP! EQU 0 if defined PACK (
  set /a NP=1
  set "PACK_1=!PACK!"
)
if !NP! EQU 0 (
  pushd "%~dp0"
  for %%z in (*.zip) do (
    set "TEN=%%~nz"
    set "BO="
    if /i "!TEN:~-4!"=="-xoi" set "BO=1"
    if /i "!TEN:~-10!"=="-xoi-truoc" set "BO=1"
    if /i "!TEN:~0,17!"=="lf2-online-upload" set "BO=1"
    if /i "!TEN:~0,7!"=="xoi-kit" set "BO=1"
    if not defined BO (
      set /a NP+=1
      set "PACK_!NP!=%%~fz"
    )
  )
  popd
)
if !NP! EQU 0 (echo Khong thay file zip ban mod: dat file zip ban mod canh file nay, keo tha no vao file nay, hoac sua dong PACK o dau file.& pause& exit /b 1)

rem --- Game, bo chay thu, scripts ---
if not defined GAME (
  for %%g in ("%LOCALAPPDATA%\Programs\OpenLF2\openlf2.exe" "%ProgramFiles(x86)%\OpenLF2\openlf2.exe" "%ProgramFiles%\OpenLF2\openlf2.exe" "%~dp0OpenLF2\openlf2.exe") do (
    if not defined GAME if exist "%%~g" set "GAME=%%~g"
  )
)
if not defined GAME set "GAME=%LOCALAPPDATA%\Programs\OpenLF2\openlf2.exe"
if not defined BENCH (
  if exist "%~dp0tools\ai-bench\spsa.lua" set "BENCH=%~dp0tools\ai-bench"
  if exist "%~dp0spsa.lua" set "BENCH=%~dp0."
  if exist "%~dp0..\spsa.lua" set "BENCH=%~dp0.."
)
if not defined SCRIPTS (
  if exist "%~dp0scripts\base\game\smart_ai.lua" set "SCRIPTS=%~dp0scripts"
  if exist "%~dp0..\..\..\scripts\base\game\smart_ai.lua" set "SCRIPTS=%~dp0..\..\..\scripts"
)
if not exist "%GAME%" (echo Khong thay game "%GAME%": cai OpenLF2 ^(bo cai OpenLF2-Windows-x64.exe o muc Releases cua trang GitHub cua du an, chon Install for me only^), hoac sua dong GAME o dau file.& pause& exit /b 1)
if not defined BENCH (echo Khong thay thu muc tools\ai-bench co spsa.lua - can bo XOI hoac goi ban 32 tro len.& pause& exit /b 1)
if not exist "%BENCH%\spsa.lua" (echo Khong thay "%BENCH%\spsa.lua" - can bo XOI hoac goi ban 32 tro len.& pause& exit /b 1)
if not defined SCRIPTS (echo Khong thay thu muc scripts canh file nay - can bo XOI hoac goi ban 32 tro len.& pause& exit /b 1)
findstr /c:"smart.tune_ranges" "%SCRIPTS%\base\game\smart_ai.lua" >nul 2>nul || (echo "%SCRIPTS%\base\game\smart_ai.lua" chua co cac con so de chinh ^(smart.tune_ranges^) - can bo XOI hoac goi ban 32 tro len.& pause& exit /b 1)
set /a N=SONG_SONG
if %N% LSS 1 set /a N=1
set /a TONG=VONG*CAP

if not exist "%LV%" mkdir "%LV%"
rem Scripts cua game da cai, cap nhat bang scripts cua goi (goi co the chi chua file da doi): khoi cai lai game.
if not exist "%LV%\scripts\base\game\smart_ai.lua" (
  for %%g in ("%GAME%") do set "CAI=%%~dpgscripts"
  if exist "!CAI!\base\game\match.lua" xcopy /e /i /q /y "!CAI!" "%LV%\scripts" >nul
  xcopy /e /i /q /y "%SCRIPTS%" "%LV%\scripts" >nul
)
if not exist "%LV%\scripts\base\game\match.lua" (echo [LOI] Khong ghep duoc scripts vao "%LV%\scripts".& pause& exit /b 1)
set XS=--scripts "%LV%\scripts"
rem Diem bat dau: cac so cua AI (bat-dau.lua rong), hoac dat san mot bat-dau.lua ^(vi du ket qua lan chinh truoc^).
if not exist "%LV%\bat-dau.lua" (>"%LV%\bat-dau.lua" echo return {})

echo Ban mod ^(%NP%^):
for /L %%p in (1,1,%NP%) do call echo   %%PACK_%%p%%
echo %VONG% vong x %N% tien trinh x %CAP% cap tran = !TONG! cap moi tien trinh; ket qua vao "%LV%"
echo Dung mo game choi trong luc nay. Tat may giua chung thi chay lai file nay de lam tiep.

set "GAME_DA_CHON=%GAME%"
set XS_DA_CHON=%XS%
set "TRUOC=%LV%\bat-dau.lua"
set /a E=1
:vong_tiep
if %E% GTR %VONG% goto kiem
set "D=%LV%\vong-%E%"
if exist "%D%\start-sau.lua" (
  set "TRUOC=%D%\start-sau.lua"
  set /a E+=1
  goto vong_tiep
)
call :mot_vong
if errorlevel 1 goto loi
set "TRUOC=%D%\start-sau.lua"
set /a E+=1
goto vong_tiep

:mot_vong
echo.
echo === Vong %E%/%VONG%: %N% tien trinh, moi tien trinh %CAP% cap tran ^(%TIME%^) ===
if exist "%D%" rmdir /s /q "%D%"
mkdir "%D%"
set /a FIRST=(E-1)*CAP
call :chuan_bi "%D%" "%TRUOC%"
set /a PI=0
for /L %%k in (1,1,%N%) do (
  set /a PI+=1
  if !PI! GTR %NP% set /a PI=1
  set /a SEED=HAT_GIONG+E*1000+%%k
  >"%D%\p%%k\config.lua" echo return {command = "spsa", step = "chain", start = "spsa_start", iterations = %CAP%, first = %FIRST%, total = %TONG%, seed = !SEED!, limit = 9000}
  start "SPSA vong %E% - %%k" /MIN "%SELF%" chay1 "%D%\p%%k" !SEED! !PI!
)
call :cho "%D%" "SPSA chain done"
rem Gop: trung binh so cua cac tien trinh da xong.
set "M=%D%\gop"
mkdir "%M%"
call :ban_bench "%M%"
copy /y "%TRUOC%" "%M%\spsa_start.lua" >nul
>"%M%\spsa_chains.lua" echo return {
set /a CO=0
for /L %%k in (1,1,%N%) do (
  if exist "%D%\p%%k\out.txt" (
    findstr /c:"--SPSA_END" "%D%\p%%k\out.txt" >>"%M%\spsa_chains.lua" && set /a CO+=1
    findstr /c:"SPSA chain done" "%D%\p%%k\out.txt" >>"%D%\tom-tat.txt"
  )
)
>>"%M%\spsa_chains.lua" echo }
if !CO! EQU 0 (echo [LOI] Khong tien trinh nao xong vong %E% - xem "%D%\p1\out.txt".& exit /b 1)
>>"%M%\package.manifest" echo module=spsa_start^|spsa_start.lua
>>"%M%\package.manifest" echo module=spsa_chains^|spsa_chains.lua
>"%M%\config.lua" echo return {command = "spsa", step = "merge", start = "spsa_start", chains = "spsa_chains"}
"%GAME%" --pack "%PACK_1%" %XS% --mod "%M%" --seed 1 --input-trace "" >"%M%\out.txt" 2>&1
call :cho_dong "%M%\out.txt" "--SPSA_START"
findstr /c:"--SPSA_START" "%M%\out.txt" >"%D%\start-sau.tmp"
for %%f in ("%D%\start-sau.tmp") do if %%~zf LSS 20 (echo [LOI] Khong gop duoc vong %E% - xem "%M%\out.txt".& exit /b 1)
move /y "%D%\start-sau.tmp" "%D%\start-sau.lua" >nul
(
  echo Ket qua sau vong %E%/%VONG% ^(!CO!/%N% tien trinh xong^):
  type "%D%\start-sau.lua"
  echo.
  findstr /c:"SPSA_LIST" "%M%\out.txt"
) >"%LV%\ket-qua.txt"
echo Vong %E% xong: !CO!/%N% tien trinh. Cac so hien tai: "%LV%\ket-qua.txt"
exit /b 0

:kiem
if %KIEM_TRA% LEQ 0 goto xong
set "K=%LV%\kiem-tra"
if exist "%K%\tong.txt" goto xong
echo.
echo === Kiem tra: ban da chinh danh voi ban goc, %N% tien trinh x %KIEM_TRA% cap tran ^(%TIME%^) ===
if exist "%K%" rmdir /s /q "%K%"
mkdir "%K%"
call :chuan_bi "%K%" "%TRUOC%"
set /a PI=0
for /L %%k in (1,1,%N%) do (
  set /a PI+=1
  if !PI! GTR %NP% set /a PI=1
  set /a SEED=HAT_GIONG+500000+%%k
  >"%K%\p%%k\config.lua" echo return {command = "spsa", step = "check", start = "spsa_start", games = %KIEM_TRA%, seed = !SEED!, limit = 9000}
  start "SPSA kiem tra - %%k" /MIN "%SELF%" chay1 "%K%\p%%k" !SEED! !PI!
)
call :cho "%K%" "SPSA_CHECK"
set /a TW=0, TL=0, TD=0, CO=0
for /L %%k in (1,1,%N%) do (
  if exist "%K%\p%%k\out.txt" for /f "tokens=2,3,4" %%a in ('findstr /b /c:"SPSA_CHECK" "%K%\p%%k\out.txt"') do (
    set /a TW+=%%a, TL+=%%b, TD+=%%c, CO+=1
  )
)
set /a TT=TW+TL
set /a PT=0
if !TT! GTR 0 set /a PT=TW*1000/TT
set /a P1=PT/10, P2=PT%%10
>"%K%\tong.txt" echo Ban da chinh thang !TW!, ban goc thang !TL!, hoa !TD! ^(!CO!/%N% tien trinh; ban da chinh thang !P1!.!P2!%% so tran co nguoi thang^)
type "%K%\tong.txt" >>"%LV%\ket-qua.txt"

:xong
echo.
echo ===== Xong. Ket qua: "%LV%\ket-qua.txt" =====
type "%LV%\ket-qua.txt"
echo.
echo Gui file ket-qua.txt cho nguoi lam AI: cac so tot thi duoc dua vao may INSANE sau khi kiem tra them.
if "%KHONG_DUNG%"=="" pause
exit /b 0

:loi
echo [LOI] Dung o vong %E%. Sua loi roi chay lai file nay de lam tiep.
if "%KHONG_DUNG%"=="" pause
exit /b 1

rem --- Moi tien trinh mot thu muc p<k>: bo chay thu, ban sao smart_ai.lua (ban "tru"), so bat dau ---
:chuan_bi
for /L %%k in (1,1,%N%) do (
  mkdir "%~1\p%%k"
  call :ban_bench "%~1\p%%k"
  copy /y "%LV%\scripts\base\game\smart_ai.lua" "%~1\p%%k\spsa_alt.lua" >nul
  copy /y "%~2" "%~1\p%%k\spsa_start.lua" >nul
  >>"%~1\p%%k\package.manifest" echo module=spsa_alt^|spsa_alt.lua
  >>"%~1\p%%k\package.manifest" echo module=spsa_start^|spsa_start.lua
)
exit /b 0

:ban_bench
pushd "%BENCH%"
copy /y *.lua "%~1\" >nul
copy /y package.manifest "%~1\" >nul
popd
exit /b 0

rem --- Cho moi tien trinh xong: dong cuoi %2 trong out.txt, hoac xong.txt (game tat, ke ca khi loi) ---
rem (THU_WINE: chi dung dong cuoi - khi thu file nay bang Wine, cmd khong cho game chay xong.)
:cho
set /a CHO=0
:cho_tiep
ping -n 6 127.0.0.1 >nul 2>&1
set /a XONG=0
for /L %%k in (1,1,%N%) do (
  set "X="
  if not defined THU_WINE if exist "%~1\p%%k\xong.txt" set "X=1"
  if not defined X if exist "%~1\p%%k\out.txt" findstr /c:"%~2" "%~1\p%%k\out.txt" >nul 2>&1 && set "X=1"
  if defined X set /a XONG+=1
)
if !XONG! GEQ %N% exit /b 0
set /a CHO+=5
set /a PHUT=CHO%%60
rem Moi phut: bao tien do; khong con openlf2.exe nao chay ma van thieu thi mot cua so tien trinh da bi dong, thoi cho.
if !PHUT! EQU 0 (
  set /a M_=CHO/60
  echo   ... !XONG!/%N% tien trinh xong, da cho !M_! phut
  if not defined KHONG_TASKLIST (
    tasklist /FI "IMAGENAME eq openlf2.exe" 2>nul | find /I "openlf2.exe" >nul || (echo   [CHU Y] Khong con game nao chay - bo qua cac tien trinh chua xong.& exit /b 0)
  )
)
goto cho_tiep

rem --- Cho dong %2 xuat hien trong file %1 (toi da khoang mot phut) ---
:cho_dong
set /a CD=0
:cho_dong_tiep
findstr /c:"%~2" "%~1" >nul 2>&1 && exit /b 0
set /a CD+=1
if !CD! GEQ 30 exit /b 1
ping -n 3 127.0.0.1 >nul 2>&1
goto cho_dong_tiep

rem --- Mot tien trinh: game chay ngam, %2 thu muc, %3 hat giong, %4 so thu tu ban mod; xong thi dong cua so ---
:chay1
set "P=!PACK_%~4!"
"%GAME_DA_CHON%" --pack "!P!" %XS_DA_CHON% --mod "%~2" --seed %~3 --input-trace "" >"%~2\out.txt" 2>&1
>"%~2\xong.txt" echo xong
exit
