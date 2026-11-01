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
rem So vong (VONG), so cap tran moi tien trinh moi vong (CAP), so tien trinh chay cung luc (SONG_SONG).
rem Mot cap tran: hai tran cung hai nhan vat, cung san, doi ben - ban "cong" (31 so nhich len hay xuong ngau nhien)
rem danh ban "tru" (nhich nguoc lai); xong cap, cac so dich ve phia ban danh tot hon. Mot vong: moi tien trinh danh
rem CAP cap tren ban mod cua no; het vong lay trung binh so cua moi tien trinh, vong sau bat dau tu do. Moi tien trinh
rem dich so VONG x CAP lan, buoc dich nho dan theo tong ay. Mot cap mat chung 1-3 giay (One Piece lau hon Naruto), nen
rem mot vong mat chung CAP x 2 giay; het moi vong file nay in vong ay mat bao lau va ca qua trinh con khoang bao lau.
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

rem (File nay tu goi lai chinh no cho tung tien trinh, trong cua so rieng: cmd /c call "<file nay>" chay1 <vong-N
rem hoac kiem-tra> <so tien trinh> <hat giong> <so thu tu ban mod>. Ngoai ten file, khong dau ngoac kep nao: khi
rem lenh co nhieu cap ngoac kep, Windows bo dau ngoac kep dau va cuoi, va duong dan co dau cach - vi du
rem D:\...\AI arena - lam tien trinh khong chay. Thu muc cua tien trinh: spsa\<vong-N hoac kiem-tra>\p<so>.)
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
rem Bo nho: mot tien trinh dung toi khoang 0,6 GB (Naruto ~0,5). SONG_SONG de mac dinh (moi luong CPU) ma may it RAM
rem thi bot so tien trinh, chua lai khoang 4 GB cho Windows (may 16 GB: 18 tien trinh). Dat SONG_SONG khac so luong
rem CPU thi giu dung so ay.
set /a RAM_GB=0
if "%SONG_SONG%"=="%NUMBER_OF_PROCESSORS%" for /f %%m in ('powershell -NoProfile -Command "[int][math]::Floor((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)" 2^>nul') do set /a RAM_GB=%%m 2>nul
if !RAM_GB! GEQ 2 (
  set /a "TOI_DA=(RAM_GB-4)*10/6"
  if !TOI_DA! LSS 1 set /a TOI_DA=1
  if !TOI_DA! LSS %N% (
    echo May co !RAM_GB! GB RAM: chay !TOI_DA! tien trinh thay vi %N% ^(moi tien trinh toi khoang 0,6 GB^).
    set /a N=TOI_DA
  )
)
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
for /L %%p in (1,1,%NP%) do call echo   %%p. %%PACK_%%p%%
echo %VONG% vong x %N% tien trinh x %CAP% cap tran = !TONG! cap moi tien trinh; ket qua vao "%LV%"
echo Dung mo game choi trong luc nay. Tat may giua chung thi chay lai file nay de lam tiep.
echo De may chay qua dem: tat che do ngu cua Windows ^(Settings - System - Power - Sleep: Never^).

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
call :giay BAT_DAU
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
  start "SPSA vong %E% - %%k" /MIN cmd /c call "%SELF%" chay1 vong-%E% %%k !SEED! !PI!
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
rem Vong nay mat bao lau (theo dong ho; qua nua dem van dung), ca qua trinh con khoang bao lau.
call :giay XONG_LUC
set /a "PHUT_V=((XONG_LUC-BAT_DAU+86400) %% 86400)/60, CON_V=VONG-E, CON=CON_V*PHUT_V, CON_G=CON/60, CON_P=CON %% 60"
>>"%LV%\thoi-gian.txt" echo Vong %E%/%VONG%: %N% tien trinh x %CAP% cap tran, xong luc %TIME%, mat !PHUT_V! phut
(
  echo Ket qua sau vong %E%/%VONG% ^(!CO!/%N% tien trinh xong^):
  type "%D%\start-sau.lua"
  echo.
  findstr /c:"SPSA_LIST" "%M%\out.txt"
  echo.
  echo Cai dat: VONG=%VONG% CAP=%CAP% SONG_SONG=%N% KIEM_TRA=%KIEM_TRA% HAT_GIONG=%HAT_GIONG%; ban mod:
  for /L %%p in (1,1,%NP%) do call echo   %%p. %%PACK_%%p%%
  type "%LV%\thoi-gian.txt"
) >"%LV%\ket-qua.txt"
echo Vong %E% xong luc %TIME%: !CO!/%N% tien trinh, vong nay mat !PHUT_V! phut; con !CON_V! vong, khoang !CON_G! gio !CON_P! phut ^(chua ke kiem tra^).
echo Cac so hien tai: "%LV%\ket-qua.txt"
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
  start "SPSA kiem tra - %%k" /MIN cmd /c call "%SELF%" chay1 kiem-tra %%k !SEED! !PI!
)
call :cho "%K%" "SPSA_CHECK"
rem Cong ket qua: ca thay, va tung ban mod (tien trinh k dung ban mod thu ((k-1) chia du cho so ban mod) + 1).
set /a TW=0, TL=0, TD=0, CO=0, PK=0
for /L %%p in (1,1,%NP%) do set /a "W_%%p=0, L_%%p=0, D_%%p=0"
for /L %%k in (1,1,%N%) do (
  set /a PK+=1
  if !PK! GTR %NP% set /a PK=1
  if exist "%K%\p%%k\out.txt" for /f "tokens=2,3,4" %%a in ('findstr /b /c:"SPSA_CHECK" "%K%\p%%k\out.txt"') do (
    set /a TW+=%%a, TL+=%%b, TD+=%%c, CO+=1
    set /a "W_!PK!+=%%a, L_!PK!+=%%b, D_!PK!+=%%c"
  )
)
set /a TT=TW+TL
set /a PT=0
if !TT! GTR 0 set /a PT=TW*1000/TT
set /a P1=PT/10, P2=PT%%10
>"%K%\tong.txt" echo Ban da chinh thang !TW!, ban goc thang !TL!, hoa !TD! ^(!CO!/%N% tien trinh; ban da chinh thang !P1!.!P2!%% so tran co nguoi thang^)
if %NP% GTR 1 for /L %%p in (1,1,%NP%) do call :in_mod %%p
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

rem --- Ket qua kiem tra cua ban mod thu %1 ---
:in_mod
set "TEN=!PACK_%1!"
for %%n in ("!TEN!") do set "TEN=%%~nxn"
set /a "MT=W_%1+L_%1, MP=0"
if !MT! GTR 0 set /a "MP=W_%1*1000/MT"
set /a "M1=MP/10, M2=MP %% 10"
>>"%K%\tong.txt" echo   %1. !TEN!: ban da chinh thang !W_%1!, ban goc thang !L_%1!, hoa !D_%1! ^(!M1!.!M2!%%^)
exit /b 0

rem --- So giay tu nua dem theo dong ho vao bien %1 (%TIME% la gio:phut:giay; gio duoi 10 co dau cach o dau) ---
:giay
set "T_=%TIME: =0%"
set /a "%1=(1%T_:~0,2%-100)*3600+(1%T_:~3,2%-100)*60+(1%T_:~6,2%-100)" 2>nul
exit /b 0

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
set /a CHO=0, NHIP=-1
if not defined DOI_THEM set /a DOI_THEM=600
:cho_tiep
ping -n 6 127.0.0.1 >nul 2>&1
set /a XONG=0, TOT=0
for /L %%k in (1,1,%N%) do (
  set "X="
  set "Y="
  if exist "%~1\p%%k\out.txt" findstr /c:"%~2" "%~1\p%%k\out.txt" >nul 2>&1 && set "Y=1"
  if defined Y set "X=1"
  if not defined THU_WINE if exist "%~1\p%%k\xong.txt" set "X=1"
  if defined X set /a XONG+=1
  if defined Y set /a TOT+=1
)
if !XONG! GEQ %N% exit /b 0
set /a CHO+=5
rem Mot nua so tien trinh xong (co dong cuoi) thi dat nhip: tien trinh nao con chay qua 4 lan nhip ay, va qua it
rem nhat 10 phut (DOI_THEM giay) sau nhip, coi nhu bi treo (game dung o mot cho, hay hop bao loi cua Windows) -
rem dung no va lam tiep voi cac tien trinh da xong, de mot cua so treo khong giu ca dem.
set /a "NUA=TOT*2"
if !NUA! GEQ %N% if !NHIP! LSS 0 set /a NHIP=CHO
if !NHIP! GEQ 0 (
  set /a "HAN=NHIP*4, HAN2=NHIP+DOI_THEM"
  if !HAN2! GTR !HAN! set /a HAN=HAN2
  if !CHO! GEQ !HAN! (
    set /a CON_LAI=N-XONG
    echo   [CHU Y] !CON_LAI! tien trinh chay qua lau ^(qua 4 lan nua so kia^) - dung chung, lam tiep voi !XONG!/%N% tien trinh.
    call :dung_treo "%~1"
    exit /b 0
  )
)
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

rem --- Dung game cua cac tien trinh chua xong trong thu muc %1 (tim theo duong dan --mod "...\p<k>"; cua so tu dong) ---
:dung_treo
for /L %%k in (1,1,%N%) do (
  if not exist "%~1\p%%k\xong.txt" (
    set "TREO=%~1\p%%k"
    >>"%LV%\thoi-gian.txt" echo   Dung tien trinh bi treo: !TREO!
    powershell -NoProfile -Command "Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'openlf2.exe' -and $_.CommandLine -and $_.CommandLine.Contains($env:TREO + [char]34) } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }" >nul 2>&1
  )
)
exit /b 0

rem --- Cho dong %2 xuat hien trong file %1 (toi da khoang mot phut) ---
:cho_dong
set /a CD=0
:cho_dong_tiep
findstr /c:"%~2" "%~1" >nul 2>&1 && exit /b 0
set /a CD+=1
if !CD! GEQ 30 exit /b 1
ping -n 3 127.0.0.1 >nul 2>&1
goto cho_dong_tiep

rem --- Mot tien trinh: game chay ngam; %2 vong-N hoac kiem-tra, %3 so tien trinh, %4 hat giong, %5 so thu tu ban
rem mod (LV, GAME_DA_CHON, XS_DA_CHON, PACK_n: tu cua so chinh); xong thi dong cua so ---
:chay1
set "DIR=%LV%\%~2\p%~3"
set "P=!PACK_%~5!"
"%GAME_DA_CHON%" --pack "!P!" %XS_DA_CHON% --mod "!DIR!" --seed %~4 --input-trace "" >"!DIR!\out.txt" 2>&1
>"!DIR!\xong.txt" echo xong
exit
