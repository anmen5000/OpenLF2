@echo off
setlocal EnableDelayedExpansion
rem SPSA - may tu chinh cac con so phan doan cua XOI bang cach cho no danh voi chinh no (tu goi 43 chi XOI dung
rem cac so chinh duoc; INSANE! giu cac so dat bang tay)
rem (OpenLF2 ban 32 tro len). Cac con so (81 so tu goi 63, 77 tu goi 38: diem cua mot chieu, nguong ra chieu, khoang cach, phan
rem ung, chong lap...) nam trong scripts\base\game\smart_ai.lua (smart.tune_ranges).
rem Moi vong, moi tien trinh (mot luong CPU) cho hai ban AI danh nhau: ban "cong" co cac so nhich len hoac
rem xuong ngau nhien, ban "tru" nhich nguoc lai; ban nao danh tot hon thi cac so dich ve phia ban ay. Het vong: gop
rem cac tien trinh, vong sau bat dau tu do. Het moi vong: cho ban da chinh danh voi ban goc de kiem tra. Ket qua:
rem spsa\ket-qua.txt (gui file nay cho nguoi lam AI). Bo so cua moi ban mod: xoi-<ten ban mod>\tune.txt, va
rem <ten ban mod>-xoi.zip = ban mod co bo so ay (va bo nho XOI neu da hoc) - tai len relay thi XOI choi ban
rem mod ay bang bo so rieng cua no (goi 38 tro len; tu goi 43 INSANE! khong dung bo so nay). Chi mot ban mod: lan sau chinh tiep tu bo so cua no.
rem Tam dung: dong cua so nay va cac cua so SPSA thu nho (hay tat may). Lam tiep: chay lai file nay - cac vong da xong
rem duoc giu, va ca phan da danh cua vong dang do (tru vai cap cuoi). Muon chinh lai tu dau: xoa thu muc spsa (hoac
rem doi HAT_GIONG va dat ten khac cho thu muc cu).
rem ============ CHINH O DAY ============
rem Game da cai. De trong thi tu tim (Install for me only, all users, hoac thu muc OpenLF2 canh file nay).
set "GAME="
rem File zip ban mod. De trong thi dung MOI file .zip ban mod canh file nay (tru *-xoi.zip, goi lf2-online-upload,
rem xoi-kit), cac tien trinh chia deu cho cac ban mod; keo tha mot file zip vao file nay thi chi dung ban mod ay.
set "PACK="
rem So vong (VONG) va so phut moi vong (PHUT_VONG): ca qua trinh chung VONG x PHUT_VONG phut (60 x 10 = 10 tieng).
rem Trong mot vong, moi tien trinh danh lien cac cap tran tren ban mod cua no cho toi het PHUT_VONG phut. Mot cap tran:
rem hai tran cung hai nhan vat, cung san, doi ben - ban "cong" (cac so nhich len hay xuong ngau nhien) danh ban "tru"
rem (nhich nguoc lai); xong cap, cac so dich ve phia ban danh tot hon. Moi tien trinh dung cung luc nen khong luong
rem CPU nao ngoi cho (ban mod nhanh danh duoc nhieu cap hon). Het vong lay trung binh buoc dich moi cap, moi ban mod
rem nang nhu nhau, vong sau bat dau tu do; buoc dich nho dan qua cac vong. Mot cap mat chung 1-3 giay.
set "VONG=12"
set "PHUT_VONG=5"
set "SONG_SONG=%NUMBER_OF_PROCESSORS%"
rem So phut kiem tra ban da chinh voi ban goc sau vong cuoi (0 = bo qua kiem tra)
set "PHUT_KIEM_TRA=5"
rem Muc uu tien cua cac tien trinh: BELOWNORMAL (ban van dung may muot trong luc chay), LOW, hoac NORMAL
set "UU_TIEN=BELOWNORMAL"
rem Hat giong dau (cac tran va cac lan nhich so deu theo hat giong: cung hat giong thi chay lai y het)
set "HAT_GIONG=9000"
rem Doi thu (DOI_THU). De trong: hai ban nhich so danh voi nhau (nhu truoc). Ghi classic: ca hai ban danh voi may goc cua
rem game (CRAZY; nhan vat nao co script ai\<id>.as cua ban mod - AI cua Sauce - thi may goc choi bang script do), cac so
rem dich ve phia ban thang doi thu ay nhieu hon; moi vong mat gap doi so tran (ca hai ban deu danh), va phan kiem tra cho
rem ban da chinh roi ban goc cung danh doi thu ay (ket qua ghi ca hai). Dung de chinh so cho mot doi thu cu the (AI cua
rem Sauce tren 10 nhan vat goc; dat IDS trong toolsi-bench neu can); voi ban mod khong co script, classic la may CRAZY.
set "DOI_THU="
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
set "KIT=%~dp0"
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
rem Giay moi vong, giay kiem tra; cap tran moi tien trinh moi vong, uoc chung (mot cap ~2 giay) cho buoc dich cua vong
rem dau - tu vong 2 tinh theo so cap that da danh (spsa\vong-N\k-sau.txt). (THU_GIAY: so giay moi vong, de thu.)
set /a GIAY_VONG=PHUT_VONG*60, GIAY_KT=PHUT_KIEM_TRA*60
rem (Doi thu, neu co, vao config cua moi tien trinh: opponent = "classic", .)
set "DT_CFG="
if defined DOI_THU set DT_CFG=opponent = "%DOI_THU%", 
if defined THU_GIAY set /a GIAY_VONG=THU_GIAY, GIAY_KT=THU_GIAY
if %GIAY_VONG% LSS 10 set /a GIAY_VONG=10
set /a K_NOM=GIAY_VONG/2, TONG=VONG*(GIAY_VONG/2)
if not defined UU_TIEN set "UU_TIEN=NORMAL"

if not exist "%LV%" mkdir "%LV%"
rem Scripts cua game da cai, cap nhat bang scripts cua goi (goi co the chi chua file da doi): khoi cai lai game.
if not exist "%LV%\scripts\base\game\smart_ai.lua" (
  for %%g in ("%GAME%") do set "CAI=%%~dpgscripts"
  if exist "!CAI!\base\game\match.lua" xcopy /e /i /q /y "!CAI!" "%LV%\scripts" >nul
  xcopy /e /i /q /y "%SCRIPTS%" "%LV%\scripts" >nul
)
if not exist "%LV%\scripts\base\game\match.lua" (echo [LOI] Khong ghep duoc scripts vao "%LV%\scripts".& pause& exit /b 1)
set XS=--scripts "%LV%\scripts"
rem Diem bat dau: cac so cua XOI (bat-dau.lua rong), hoac dat san mot bat-dau.lua ^(vi du ket qua lan chinh truoc^).
rem Chi mot ban mod, da co bo so rieng (xoi-<ten>\tune.txt, tu lan chinh truoc): chinh tiep tu bo so ay.
if %NP% EQU 1 if not exist "%LV%\bat-dau.lua" for %%z in ("!PACK_1!") do if exist "%KIT%xoi-%%~nz\tune.txt" (
  copy /y "%KIT%xoi-%%~nz\tune.txt" "%LV%\bat-dau.lua" >nul
  echo Bat dau tu bo so rieng cua ban mod: "%KIT%xoi-%%~nz\tune.txt"
)
if not exist "%LV%\bat-dau.lua" (>"%LV%\bat-dau.lua" echo return {})

echo Ban mod ^(%NP%^):
for /L %%p in (1,1,%NP%) do call echo   %%p. %%PACK_%%p%%
echo %VONG% vong x %PHUT_VONG% phut, %N% tien trinh ^(uu tien %UU_TIEN%^); ket qua vao "%LV%"
echo Tam dung: dong cua so nay va cac cua so SPSA thu nho. Chay lai file nay la lam tiep, ke ca vong dang do.
echo De may chay qua dem: tat che do ngu cua Windows ^(Settings - System - Power - Sleep: Never^).

set "GAME_DA_CHON=%GAME%"
set XS_DA_CHON=%XS%
set "TRUOC=%LV%\bat-dau.lua"
rem K_DAU: so cap ma moi chuoi da danh truoc vong nay (cho buoc dich), lay tu k-sau.txt cua vong truoc.
set /a E=1, K_DAU=0
:vong_tiep
if %E% GTR %VONG% goto kiem
set "D=%LV%\vong-%E%"
if exist "%D%\start-sau.lua" (
  set "TRUOC=%D%\start-sau.lua"
  set /a K_DAU+=K_NOM
  if exist "%D%\k-sau.txt" set /p K_DAU=<"%D%\k-sau.txt"
  set /a E+=1
  goto vong_tiep
)
call :mot_vong
if errorlevel 1 goto loi
set "TRUOC=%D%\start-sau.lua"
set /a K_DAU+=K_NOM
if exist "%D%\k-sau.txt" set /p K_DAU=<"%D%\k-sau.txt"
set /a E+=1
goto vong_tiep

:mot_vong
echo.
echo === Vong %E%/%VONG%: %N% tien trinh danh trong %PHUT_VONG% phut ^(%TIME%^) ===
call :giay BAT_DAU
rem Vong nay da chay do lan truoc (dong cua so, tat may): giu phan da danh trong truoc\<lan>, gop chung o cuoi vong.
rem (Mau tim tep: pushd vao thu muc roi dung duong dan tuong doi - mau co duong dan tuyet doi trong ngoac kep thi Wine
rem khong tim ra, khi thu file nay.)
set /a LAN=0
set "DO_DANG="
if exist "%D%" (
  pushd "%D%"
  for /d %%p in (p*) do if exist "%%p\out.txt" set "DO_DANG=1"
  popd
)
if defined DO_DANG (
  set "LAN="
  for /L %%a in (1,1,99) do if not defined LAN if not exist "%D%\truoc\%%a" set "LAN=%%a"
  mkdir "%D%\truoc\!LAN!"
  pushd "%D%"
  for /d %%p in (p*) do if exist "%%p\out.txt" move /y "%%p\out.txt" "truoc\!LAN!\%%p.txt" >nul
  popd
  echo   ^(lam tiep vong do dang: giu phan da danh o lan truoc^)
)
if exist "%D%\gop" rmdir /s /q "%D%\gop"
if not exist "%D%" mkdir "%D%"
set /a FIRST=K_DAU
call :chuan_bi "%D%" "%TRUOC%"
set /a PI=0
for /L %%k in (1,1,%N%) do (
  set /a PI+=1
  if !PI! GTR %NP% set /a PI=1
  set /a SEED=HAT_GIONG+E*1000+%%k+LAN*100000
  >"%D%\p%%k\config.lua" echo return {command = "spsa", step = "chain", !DT_CFG!start = "spsa_start", iterations = 1000000, seconds = %GIAY_VONG%, first = %FIRST%, total = %TONG%, seed = !SEED!, mod = !PI!, limit = 9000}
  start "SPSA vong %E% - %%k" /MIN /%UU_TIEN% cmd /c call "%SELF%" chay1 vong-%E% %%k !SEED! !PI!
)
call :cho "%D%" "SPSA chain done"
rem Gop: buoc dich trung binh moi cap cua cac tien trinh (ca phan cua cac lan truoc trong truoc\, va tien trinh bi
rem dung giua chung voi phan den lan bao cuoi).
set "M=%D%\gop"
mkdir "%M%"
call :ban_bench "%M%"
copy /y "%TRUOC%" "%M%\spsa_start.lua" >nul
>"%M%\spsa_chains.lua" echo return {
set /a CO=0
pushd "%D%"
for /d %%p in (p*) do (
  call :lay_chuoi "%D%\%%p\out.txt" "%M%\spsa_chains.lua"
  if exist "%%p\out.txt" findstr /c:"SPSA chain done" "%%p\out.txt" >>tom-tat.txt
)
if exist truoc (
  pushd truoc
  for /r %%f in (p*.txt) do call :lay_chuoi "%%f" "%M%\spsa_chains.lua"
  popd
)
popd
>>"%M%\spsa_chains.lua" echo }
if !CO! EQU 0 (echo [LOI] Khong tien trinh nao danh duoc cap nao o vong %E% - xem "%D%\p1\out.txt".& exit /b 1)
>>"%M%\package.manifest" echo module=spsa_start^|spsa_start.lua
>>"%M%\package.manifest" echo module=spsa_chains^|spsa_chains.lua
>"%M%\config.lua" echo return {command = "spsa", step = "merge", start = "spsa_start", chains = "spsa_chains", first = %FIRST%}
"%GAME%" --pack "%PACK_1%" %XS% --mod "%M%" --seed 1 --input-trace "" >"%M%\out.txt" 2>&1
call :cho_dong "%M%\out.txt" "--SPSA_START"
findstr /c:"--SPSA_START" "%M%\out.txt" >"%D%\start-sau.tmp"
for %%f in ("%D%\start-sau.tmp") do if %%~zf LSS 20 (echo [LOI] Khong gop duoc vong %E% - xem "%M%\out.txt".& exit /b 1)
set "CAP_V=?"
for /f "tokens=2" %%v in ('findstr /c:"SPSA_PAIRS " "%M%\out.txt"') do set "CAP_V=%%v"
for /f "tokens=2" %%v in ('findstr /c:"SPSA_K " "%M%\out.txt"') do >"%D%\k-sau.txt" echo %%v
move /y "%D%\start-sau.tmp" "%D%\start-sau.lua" >nul
rem Vong nay mat bao lau (theo dong ho; qua nua dem van dung), ca qua trinh con khoang bao lau.
call :giay XONG_LUC
set /a "PHUT_V=((XONG_LUC-BAT_DAU+86400) %% 86400)/60, CON_V=VONG-E, CON=CON_V*PHUT_V, CON_G=CON/60, CON_P=CON %% 60"
>>"%LV%\thoi-gian.txt" echo Vong %E%/%VONG%: !CO! chuoi, !CAP_V! cap tran, xong luc %TIME%, mat !PHUT_V! phut
(
  echo Ket qua sau vong %E%/%VONG% ^(!CO! chuoi, !CAP_V! cap tran^):
  type "%D%\start-sau.lua"
  echo.
  findstr /c:"SPSA_LIST" "%M%\out.txt"
  findstr /c:"SPSA_MODS" "%M%\out.txt"
  echo.
  echo Cai dat: VONG=%VONG% PHUT_VONG=%PHUT_VONG% SONG_SONG=%N% PHUT_KIEM_TRA=%PHUT_KIEM_TRA% HAT_GIONG=%HAT_GIONG% DOI_THU=%DOI_THU%; ban mod:
  for /L %%p in (1,1,%NP%) do call echo   %%p. %%PACK_%%p%%
  type "%LV%\thoi-gian.txt"
) >"%LV%\ket-qua.txt"
echo Vong %E% xong luc %TIME%: !CO! chuoi, !CAP_V! cap tran, mat !PHUT_V! phut; con !CON_V! vong, khoang !CON_G! gio !CON_P! phut ^(chua ke kiem tra^).
echo Cac so hien tai: "%LV%\ket-qua.txt"
exit /b 0

:kiem
if %GIAY_KT% LEQ 0 goto xong
set "K=%LV%\kiem-tra"
if exist "%K%\tong.txt" goto xong
echo.
echo === Kiem tra: ban da chinh danh voi ban goc, %N% tien trinh trong %PHUT_KIEM_TRA% phut ^(%TIME%^) ===
if exist "%K%" rmdir /s /q "%K%"
mkdir "%K%"
call :chuan_bi "%K%" "%TRUOC%"
rem Ban goc: cac so luc bat dau - bat-dau.lua, tuc cac so cua XOI hay bo so rieng cua ban mod.
set /a PI=0
for /L %%k in (1,1,%N%) do (
  set /a PI+=1
  if !PI! GTR %NP% set /a PI=1
  set /a SEED=HAT_GIONG+500000+%%k
  copy /y "%LV%\bat-dau.lua" "%K%\p%%k\spsa_base.lua" >nul
  >>"%K%\p%%k\package.manifest" echo module=spsa_base^|spsa_base.lua
  >"%K%\p%%k\config.lua" echo return {command = "spsa", step = "check", !DT_CFG!start = "spsa_start", base = "spsa_base", games = 1000000, seconds = %GIAY_KT%, seed = !SEED!, limit = 9000}
  start "SPSA kiem tra - %%k" /MIN /%UU_TIEN% cmd /c call "%SELF%" chay1 kiem-tra %%k !SEED! !PI!
)
rem (Co doi thu: ban da chinh danh truoc, ban goc danh sau - dong SPSA_CHECK_BASE la dong cuoi.)
set "DAU_KT=SPSA_CHECK "
if defined DOI_THU set "DAU_KT=SPSA_CHECK_BASE"
call :cho "%K%" "%DAU_KT%"
rem Cong ket qua: ca thay, va tung ban mod (tien trinh k dung ban mod thu ((k-1) chia du cho so ban mod) + 1).
rem (Co doi thu: ban da chinh - dong "SPSA_CHECK " - va ban goc - dong SPSA_CHECK_BASE - deu danh doi thu ay.)
set /a TW=0, TL=0, TD=0, CO=0, PK=0, BW=0, BL=0, BD=0
for /L %%p in (1,1,%NP%) do set /a "W_%%p=0, L_%%p=0, D_%%p=0, BW_%%p=0, BL_%%p=0, BD_%%p=0"
for /L %%k in (1,1,%N%) do (
  set /a PK+=1
  if !PK! GTR %NP% set /a PK=1
  if exist "%K%\p%%k\out.txt" for /f "tokens=2,3,4" %%a in ('findstr /b /c:"SPSA_CHECK " "%K%\p%%k\out.txt"') do (
    set /a TW+=%%a, TL+=%%b, TD+=%%c, CO+=1
    set /a "W_!PK!+=%%a, L_!PK!+=%%b, D_!PK!+=%%c"
  )
  if exist "%K%\p%%k\out.txt" for /f "tokens=2,3,4" %%a in ('findstr /b /c:"SPSA_CHECK_BASE" "%K%\p%%k\out.txt"') do (
    set /a BW+=%%a, BL+=%%b, BD+=%%c
    set /a "BW_!PK!+=%%a, BL_!PK!+=%%b, BD_!PK!+=%%c"
  )
)
set /a TT=TW+TL
set /a PT=0
if !TT! GTR 0 set /a PT=TW*1000/TT
set /a P1=PT/10, P2=PT%%10
if defined DOI_THU (
  >"%K%\tong.txt" echo Danh voi %DOI_THU%: ban da chinh thang !TW!, thua !TL!, hoa !TD!; ban goc thang !BW!, thua !BL!, hoa !BD! ^(!CO!/%N% tien trinh^)
) else (
  >"%K%\tong.txt" echo Ban da chinh thang !TW!, ban goc thang !TL!, hoa !TD! ^(!CO!/%N% tien trinh; ban da chinh thang !P1!.!P2!%% so tran co nguoi thang^)
)
if %NP% GTR 1 for /L %%p in (1,1,%NP%) do call :in_mod %%p
type "%K%\tong.txt" >>"%LV%\ket-qua.txt"

:xong
rem Bo so cua moi ban mod: xoi-<ten>\tune.txt, va goi <ten>-xoi.zip (mot lan sau moi lan chinh).
if not exist "%LV%\da-goi.txt" (
  echo.
  echo === Bo so rieng cho tung ban mod ===
  for /L %%p in (1,1,%NP%) do call :goi_so %%p
  >"%LV%\da-goi.txt" echo xong
)
echo.
echo ===== Xong. Ket qua: "%LV%\ket-qua.txt" =====
type "%LV%\ket-qua.txt"
echo.
echo Gui file ket-qua.txt cho nguoi lam AI. Hoac dung ngay: tai file ^<ten ban mod^>-xoi.zip len relay ^(cung id voi ban
echo mod cu^) - XOI choi ban mod ay bang bo so vua chinh ^(trong tran ghi "mod tuned"^), INSANE giu so cua no. Kiem tra o tren ^<50%%
echo thi dung tai len: bo so moi chua hon bo so cu.
if "%KHONG_DUNG%"=="" pause
exit /b 0

:loi
echo [LOI] Dung o vong %E%. Sua loi roi chay lai file nay de lam tiep.
if "%KHONG_DUNG%"=="" pause
exit /b 1

rem --- Them vao file %2 dong cuoi cua mot chuoi trong file %1: dong ket thuc, hay (tien trinh bi dung giua chung) dong
rem bao cuoi cung; khong co thi bo qua ---
:lay_chuoi
if not exist "%~1" exit /b 0
set "DONG="
for /f "delims=" %%l in ('findstr /c:"--SPSA_END" "%~1" 2^>nul') do set "DONG=%%l"
if not defined DONG for /f "delims=" %%l in ('findstr /c:"--SPSA_STATE" "%~1" 2^>nul') do set "DONG=%%l"
if not defined DONG exit /b 0
>>"%~2" echo !DONG!
set /a CO+=1
exit /b 0

rem --- Bo so vua chinh cho ban mod thu %1: xoi-<ten>\tune.txt (bo so truoc do giu o tune-truoc.txt), va <ten>-xoi.zip:
rem ban sao file zip ban mod, them xoi/tune.txt (va xoi/notes.txt neu xoi-hoc.bat da hoc) canh thu muc data; goi truoc
rem do giu o <ten>-xoi-truoc.zip ---
:goi_so
set "XPACK=!PACK_%1!"
for %%z in ("!XPACK!") do (
  set "XDIR=%KIT%xoi-%%~nz"
  set "XOUT=%%~dpnz-xoi.zip"
  set "XTRUOC=%%~dpnz-xoi-truoc.zip"
)
if not exist "!XDIR!" mkdir "!XDIR!"
if exist "!XDIR!\tune.txt" copy /y "!XDIR!\tune.txt" "!XDIR!\tune-truoc.txt" >nul
copy /y "%TRUOC%" "!XDIR!\tune.txt" >nul
echo   %1. "!XDIR!\tune.txt"
set "XTUNE=!XDIR!\tune.txt"
set "XNOTES="
if exist "!XDIR!\notes.txt" set "XNOTES=!XDIR!\notes.txt"
if exist "!XOUT!" copy /y "!XOUT!" "!XTRUOC!" >nul
del /q "!XOUT!" 2>nul
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; Add-Type -AssemblyName System.IO.Compression; Add-Type -AssemblyName System.IO.Compression.FileSystem; Copy-Item -LiteralPath $env:XPACK -Destination $env:XOUT -Force; $z=[System.IO.Compression.ZipFile]::Open($env:XOUT,'Update'); try { $e=$z.Entries | Where-Object { $_.FullName -imatch '(^|[\\/])data[\\/]data\.txt$' } | Sort-Object { $_.FullName.Length } | Select-Object -First 1; if (-not $e) { throw 'zip khong co data/data.txt' }; $root=$e.FullName.Substring(0, $e.FullName.Length - 13); foreach ($f in @(@($env:XNOTES, 'xoi/notes.txt'), @($env:XTUNE, 'xoi/tune.txt'))) { if ($f[0] -and (Test-Path -LiteralPath $f[0])) { $name=$root + $f[1]; foreach ($old in @($z.Entries | Where-Object { $_.FullName -ieq $name })) { $old.Delete() }; [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($z, $f[0], $name); Write-Host ('     Da them ' + $name) } } } finally { $z.Dispose() }" 2>nul
if exist "!XOUT!" (echo      Goi: "!XOUT!") else (echo      [LOI] Khong goi duoc - tu lam: mo file zip ban mod, vao thu muc co thu muc data, tao thu muc xoi, chep "!XDIR!\tune.txt" vao do.)
exit /b 0

rem --- Ket qua kiem tra cua ban mod thu %1 ---
:in_mod
set "TEN=!PACK_%1!"
for %%n in ("!TEN!") do set "TEN=%%~nxn"
set /a "MT=W_%1+L_%1, MP=0"
if !MT! GTR 0 set /a "MP=W_%1*1000/MT"
set /a "M1=MP/10, M2=MP %% 10"
if defined DOI_THU (
  >>"%K%\tong.txt" echo   %1. !TEN!: ban da chinh thang !W_%1! thua !L_%1! hoa !D_%1!; ban goc thang !BW_%1! thua !BL_%1! hoa !BD_%1!
) else (
  >>"%K%\tong.txt" echo   %1. !TEN!: ban da chinh thang !W_%1!, ban goc thang !L_%1!, hoa !D_%1! ^(!M1!.!M2!%%^)
)
exit /b 0

rem --- So giay tu nua dem theo dong ho vao bien %1 (%TIME% la gio:phut:giay; gio duoi 10 co dau cach o dau) ---
:giay
set "T_=%TIME: =0%"
set /a "%1=(1%T_:~0,2%-100)*3600+(1%T_:~3,2%-100)*60+(1%T_:~6,2%-100)" 2>nul
exit /b 0

rem --- Moi tien trinh mot thu muc p<k>: bo chay thu, ban sao smart_ai.lua (ban "tru"), so bat dau ---
:chuan_bi
for /L %%k in (1,1,%N%) do (
  mkdir "%~1\p%%k" 2>nul
  del /q "%~1\p%%k\xong.txt" 2>nul
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
call :giay CHO_TU
if not defined DOI_THEM set /a DOI_THEM=300
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
rem Mot nua so tien trinh xong (co dong cuoi) thi dat nhip: tien trinh nao con chay qua 2 lan nhip ay, va qua it
rem nhat 5 phut (DOI_THEM giay) sau nhip, coi nhu bi treo (game dung o mot cho, hay hop bao loi cua Windows) - dung
rem no va lam tiep voi cac tien trinh da xong, de mot cua so treo khong giu ca dem. (Moi tien trinh dung theo dong ho,
rem cung luc, nen cham hon nhau vai giay la cung.)
set /a "NUA=TOT*2"
if !NUA! GEQ %N% if !NHIP! LSS 0 set /a NHIP=CHO
if !NHIP! GEQ 0 (
  set /a "HAN=NHIP*2, HAN2=NHIP+DOI_THEM"
  if !HAN2! GTR !HAN! set /a HAN=HAN2
  if !CHO! GEQ !HAN! (
    set /a CON_LAI=N-XONG
    echo   [CHU Y] !CON_LAI! tien trinh chay qua lau ^(qua 2 lan nua so kia^) - dung chung, lam tiep voi !XONG!/%N% tien trinh.
    call :dung_treo "%~1"
    exit /b 0
  )
)
set /a PHUT=CHO%%60
rem Moi phut: bao tien do (theo dong ho that: voi nhieu tien trinh, mot vong doc ket qua lau hon 5 giay, nen dem vong
rem thi cham hon gio that); khong con openlf2.exe nao chay ma van thieu thi mot cua so tien trinh da bi dong, thoi cho.
if !PHUT! EQU 0 (
  call :giay BAY_GIO
  set /a "M_=((BAY_GIO-CHO_TU+86400) %% 86400)/60"
  echo   ... !XONG!/%N% tien trinh xong, da cho !M_! phut ^(!TIME:~0,8!^)
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
