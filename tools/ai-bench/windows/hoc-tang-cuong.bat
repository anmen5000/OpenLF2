@echo off
setlocal EnableDelayedExpansion
rem HOC TANG CUONG (THU NGHIEM, goi 85) - mot bo nao nho hoc cach bam phim cho MOT nhan vat, ngay trong tran.
rem Moi khung hinh XOI tu quyet nhu thuong; roi bo nao xem tinh huong va phim XOI vua chon, va hoac de XOI bam,
rem hoac tu ra mot trong 22 nuoc cua no: bam A, J hay D; nhay (tai cho, toi, lui, len, xuong); di 4 khung (toi,
rem lui, len, xuong); chay 10 khung (toi, lui); 7 chieu D (D>A, D>J, D^A, D^J, DvA, DvJ, DJA); dung yen 4 khung.
rem Nhan vat ay (NHAN_VAT) danh voi XOI khong bo nao, doi thu la moi nhan vat cua ban mod, san ngau nhien.
rem Moi vong: moi tien trinh (mot luong CPU) danh TRAN tran voi bo nao cua vong truoc, tu hoc tren cac tran cua
rem minh (PPO), ghi phan doi; het vong lay trung binh phan doi cua cac tien trinh thanh bo nao moi. Luc dau bo nao
rem gan nhu luon de XOI bam (99 khung tren 100), nen nhan vat danh gan nhu XOI; no chi doi khi thay doi co loi.
rem Cu KIEM_TRA_MOI vong: kiem tra - moi tran danh hai lan tu cung mot luc bat dau, mot lan bo nao, mot lan XOI mot
rem minh, so ket qua. Kiem tra chi do, khong doi gi trong viec hoc. Ket qua: hoc-tang-cuong\<NHAN_VAT>\tom-tat.txt
rem (gui file nay cho nguoi lam AI); bo nao cua moi vong: hoc-tang-cuong\<NHAN_VAT>\bo-nao-<vong>.txt; bo nao co lan
rem kiem tra "greedy" tot nhat (tu goi 88): bo-nao-tot-nhat.txt (vong va diem cua no trong tot-nhat.txt).
rem Xac nhan (tu goi 89): het vong cuoi, bo nao vong cuoi va bo tot nhat danh lai tren nhung tran moi; bo co ket qua
rem cao hon duoc chon (xac-nhan.txt: vong va diem). dua-bo-nao-vao-mod.bat lay bo nay.
rem Dua bo nao vao ban mod (tu goi 88 game dung duoc): chay dua-bo-nao-vao-mod.bat - chi nhan vat co bo nao hon XOI.
rem Tam dung: dong cua so nay (cac game cua no tu dung theo), hay dat GIO_CHAY. Lam tiep: chay lai file nay - cac
rem vong da xong duoc giu, vong dang do danh lai. Hoc lai tu dau: xoa thu muc hoc-tang-cuong\<NHAN_VAT>.
rem ============ CHINH O DAY ============
rem Game da cai. De trong thi tu tim (Install for me only, all users, hoac thu muc OpenLF2 canh file nay).
set "GAME="
rem File zip ban mod. De trong thi dung file .zip ban mod dau tien canh file nay (tru *-xoi.zip, goi
rem lf2-online-upload, xoi-kit); keo tha mot file zip vao file nay thi dung ban mod ay.
set "PACK="
rem Nhan vat hoc: ten (hay dau ten) hay so id trong ban mod, vi du khaos, davis, 2. Nhieu nhan vat cung luc: ghi cach
rem nhau bang dau cach hay dau phay, vi du  set "NHAN_VAT=2 19 55"  - moi nhan vat mot cua so rieng, chia deu cac luong
rem CPU (3 nhan vat tren may 99 luong: moi nhan vat 33).
set "NHAN_VAT=khaos"
rem So vong, so tran moi tien trinh moi vong (moi tran ~1-2 giay, them vai giay hoc moi vong: mot vong chung nua
rem phut; 500 vong khoang 5-6 gio)
set "VONG=500"
set "TRAN=20"
set "SONG_SONG=%NUMBER_OF_PROCESSORS%"
rem Kiem tra cu bao nhieu vong (0 = chi kiem tra o vong cuoi), moi tien trinh bao nhieu tran. Kiem tra KHONG lam bo nao
rem hoc tot hon (buoc hoc khong nhin ket qua kiem tra; bo nao vong cuoi y het du kiem tra hay khong): no de xem tien do
rem va chon bo nao. Moi lan kiem tra, moi tran danh 3 lan (XOI mot minh, greedy, sample), ton chung 2 vong: moi 25
rem vong la them chung 7 phan tram thoi gian, moi 50 vong chung 3-4 phan tram.
set "KIEM_TRA_MOI=25"
set "TRAN_KIEM_TRA=12"
rem Xac nhan sau vong cuoi: tong so tran (chia deu cho cac tien trinh; moi tran danh 2 lan, XOI mot minh va greedy).
set "TRAN_XAC_NHAN=720"
rem Hen gio tam dung: chay chung ay gio roi tu dung (vi du 8; de trong: chay den het)
set "GIO_CHAY="
set "UU_TIEN=BELOWNORMAL"
set "HAT_GIONG=7000"
rem Thu muc tools\ai-bench va scripts cua goi (de trong thi tu tim canh file .bat nay)
set "BENCH="
set "SCRIPTS="
rem =====================================
rem Cai dat rieng, giu qua cac lan cap nhat bo XOI: file hoc-tang-cuong-cai-dat.bat canh file nay, moi dong mot
rem cai dat nhu tren, vi du  set "NHAN_VAT=davis"
if exist "%~dp0hoc-tang-cuong-cai-dat.bat" call "%~dp0hoc-tang-cuong-cai-dat.bat"
rem (Mot nhan vat trong nhieu: cua so chinh goi lai file nay - mot_nv <nhan vat> <so tien trinh> - trong cua so rieng;
rem ban mod la ban cua cua so chinh, PACK_CHA.)
if /i "%~1"=="mot_nv" (
  set "NHAN_VAT=%~2"
  set "SONG_SONG=%~3"
)

rem (Moi tien trinh: file nay goi lai chinh no, trong cua so rieng: cmd /c call "<file nay>" chay1 <thu muc vong>
rem <so tien trinh> <hat giong>. Duong dan lay tu bien cua cua so chinh: LV, GAME_DA_CHON, XS_DA_CHON, PACK_DA_CHON.)
if /i "%~1"=="chay1" goto chay1

set "SELF=%~f0"
set "KIT=%~dp0"
rem --- Ban mod ---
set "PACK_1="
if not "%~1"=="" if /i "%~x1"==".zip" if exist "%~f1" set "PACK_1=%~f1"
if /i "%~1"=="mot_nv" if defined PACK_CHA set "PACK_1=%PACK_CHA%"
if not defined PACK_1 if defined PACK set "PACK_1=%PACK%"
if not defined PACK_1 (
  pushd "%~dp0"
  for %%z in (*.zip) do if not defined PACK_1 (
    set "TEN=%%~nz"
    set "BO="
    if /i "!TEN:~-4!"=="-xoi" set "BO=1"
    if /i "!TEN:~-10!"=="-xoi-truoc" set "BO=1"
    if /i "!TEN:~0,17!"=="lf2-online-upload" set "BO=1"
    if /i "!TEN:~0,7!"=="xoi-kit" set "BO=1"
    if not defined BO set "PACK_1=%%~fz"
  )
  popd
)
if not defined PACK_1 (echo Khong thay file zip ban mod: dat file zip ban mod canh file nay, keo tha no vao file nay, hoac sua dong PACK o dau file.& pause& exit /b 1)

rem --- Game, bo chay thu, scripts ---
if not defined GAME (
  for %%g in ("%LOCALAPPDATA%\Programs\OpenLF2\openlf2.exe" "%ProgramFiles(x86)%\OpenLF2\openlf2.exe" "%ProgramFiles%\OpenLF2\openlf2.exe" "%~dp0OpenLF2\openlf2.exe") do (
    if not defined GAME if exist "%%~g" set "GAME=%%~g"
  )
)
if not defined GAME set "GAME=%LOCALAPPDATA%\Programs\OpenLF2\openlf2.exe"
if not defined BENCH (
  if exist "%~dp0tools\ai-bench\rl.lua" set "BENCH=%~dp0tools\ai-bench"
  if exist "%~dp0rl.lua" set "BENCH=%~dp0."
  if exist "%~dp0..\rl.lua" set "BENCH=%~dp0.."
)
if not defined SCRIPTS (
  if exist "%~dp0scripts\base\game\smart_ai.lua" set "SCRIPTS=%~dp0scripts"
  if exist "%~dp0..\..\..\scripts\base\game\smart_ai.lua" set "SCRIPTS=%~dp0..\..\..\scripts"
)
if not exist "%GAME%" (echo Khong thay game "%GAME%": cai OpenLF2 ^(bo cai OpenLF2-Windows-x64.exe o muc Releases cua trang GitHub cua du an, chon Install for me only^), hoac sua dong GAME o dau file.& pause& exit /b 1)
if not defined BENCH (echo Khong thay thu muc tools\ai-bench co rl.lua - can bo XOI cua goi 85 tro len.& pause& exit /b 1)
if not exist "%BENCH%\rl.lua" (echo Khong thay "%BENCH%\rl.lua" - can bo XOI cua goi 85 tro len.& pause& exit /b 1)
if not defined SCRIPTS (echo Khong thay thu muc scripts canh file nay - can bo XOI cua goi 85 tro len.& pause& exit /b 1)
set /a N=SONG_SONG
if %N% LSS 1 set /a N=1
rem Bo nho: mot tien trinh dung toi khoang 0,7 GB. SONG_SONG de mac dinh (moi luong CPU) ma may it RAM thi bot so
rem tien trinh, chua lai khoang 4 GB cho Windows.
set /a RAM_GB=0
if "%SONG_SONG%"=="%NUMBER_OF_PROCESSORS%" for /f %%m in ('powershell -NoProfile -Command "[int][math]::Floor((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)" 2^>nul') do set /a RAM_GB=%%m 2>nul
if !RAM_GB! GEQ 2 (
  set /a "TOI_DA=(RAM_GB-4)*10/7"
  if !TOI_DA! LSS 1 set /a TOI_DA=1
  if !TOI_DA! LSS %N% (
    echo May co !RAM_GB! GB RAM: chay !TOI_DA! tien trinh thay vi %N% ^(moi tien trinh toi khoang 0,7 GB^).
    set /a N=TOI_DA
  )
)
if not defined UU_TIEN set "UU_TIEN=NORMAL"
if not defined KIEM_TRA_MOI set "KIEM_TRA_MOI=0"
if not defined TRAN_XAC_NHAN set "TRAN_XAC_NHAN=720"

rem Nhieu nhan vat (cach nhau bang dau cach hay dau phay): moi nhan vat mot cua so rieng chay file nay, chia deu cac
rem luong; cua so nay chi mo cac cua so ay.
set /a SO_NV=0
for %%n in (%NHAN_VAT%) do set /a SO_NV+=1
if !SO_NV! EQU 0 (echo Dong NHAN_VAT o dau file dang trong: ghi ten, dau ten hay so id cua nhan vat.& pause& exit /b 1)
if !SO_NV! GTR 1 if /i not "%~1"=="mot_nv" (
  set /a "MOI_NV=N/SO_NV"
  if !MOI_NV! LSS 1 set /a MOI_NV=1
  set "PACK_CHA=%PACK_1%"
  echo Hoc !SO_NV! nhan vat cung luc, moi nhan vat !MOI_NV! tien trinh, moi nhan vat mot cua so rieng:
  for %%n in (%NHAN_VAT%) do (
    echo   %%n
    start "Hoc tang cuong - %%n" cmd /c call "%SELF%" mot_nv %%n !MOI_NV!
    ping -n 4 127.0.0.1 >nul 2>&1
  )
  echo Ket qua cua moi nhan vat: hoc-tang-cuong\^<nhan vat^>\tom-tat.txt. Dong cua so nay duoc - cac cua so kia van chay.
  pause
  exit /b 0
)

rem Thu muc cua nhan vat: hoc-tang-cuong\<NHAN_VAT> (dau cach doi thanh dau gach).
set "TEN_NV=%NHAN_VAT: =-%"
set "LV=%~dp0hoc-tang-cuong\%TEN_NV%"
if not exist "%LV%" mkdir "%LV%"
rem Scripts cua game da cai, cap nhat bang scripts cua goi (goi co the chi chua file da doi). Mot lan hoc giu scripts
rem cua no tu dau den cuoi (xoa hoc-tang-cuong\<NHAN_VAT>\scripts de lay scripts cua bo XOI moi).
if not exist "%LV%\scripts\base\game\smart_ai.lua" (
  for %%g in ("%GAME%") do set "CAI=%%~dpgscripts"
  if exist "!CAI!\base\game\match.lua" xcopy /e /i /q /y "!CAI!" "%LV%\scripts" >nul
  xcopy /e /i /q /y "%SCRIPTS%" "%LV%\scripts" >nul
)
if not exist "%LV%\scripts\base\game\match.lua" (echo [LOI] Khong ghep duoc scripts vao "%LV%\scripts".& pause& exit /b 1)
if exist "%SCRIPTS%\runtime\bootstrap.lua" copy /y "%SCRIPTS%\runtime\bootstrap.lua" "%LV%\scripts\runtime\bootstrap.lua" >nul 2>nul
set XS=--scripts "%LV%\scripts"
set "GAME_DA_CHON=%GAME%"
set XS_DA_CHON=%XS%
set "PACK_DA_CHON=%PACK_1%"
rem Nhan vat co trong ban mod khong (buoc "who" cua rl.lua: RLF <id> <ten>, hay RLF_ERROR va cac nhan vat cua ban mod).
set "W0=%LV%\ten"
if exist "%W0%" rmdir /s /q "%W0%"
mkdir "%W0%"
call :ban_bench "%W0%"
>"%W0%\config.lua" echo return {command = "rl", step = "who", fighter = "%NHAN_VAT%"}
"%GAME%" --pack "%PACK_1%" %XS% --mod "%W0%" --seed 1 --input-trace "" >"%W0%\out.txt" 2>&1
call :cho_dong "%W0%\out.txt" "RL_DONE"
set "TEN_THAT="
for /f "tokens=2,*" %%a in ('findstr /b /c:"RLF " "%W0%\out.txt"') do set "TEN_THAT=%%b (id %%a)"
if not defined TEN_THAT (
  echo [LOI] Khong tim thay nhan vat "%NHAN_VAT%" trong ban mod "%PACK_1%":
  findstr /b /c:"RLF_ERROR" /c:"BENCH ERROR" "%W0%\out.txt"
  echo Sua dong NHAN_VAT o dau file ^(ten, dau ten hay so id; nhieu nhan vat thi cach nhau bang dau cach hay dau phay^).
  pause
  exit /b 1
)

echo Hoc tang cuong ^(thu nghiem^): nhan vat !TEN_THAT!, ban mod "%PACK_1%"
echo %VONG% vong, moi vong %N% tien trinh x %TRAN% tran ^(uu tien %UU_TIEN%^); ket qua vao "%LV%"
echo Tam dung: dong cua so nay. Chay lai file nay la lam tiep. De may chay qua dem: tat che do ngu cua Windows.
rem Hen gio (GIO_CHAY): so giay chay toi da (GIOI_HAN; 0 = khong hen).
set /a GIOI_HAN=0, DA_CHAY=0
set "HET_GIO="
if defined GIO_CHAY for /f "tokens=1,2 delims=.," %%a in ("%GIO_CHAY%") do (
  set /a "GIOI_HAN=%%a*3600" 2>nul
  if not "%%b"=="" set /a "GIOI_HAN+=%%b*360" 2>nul
)
if !GIOI_HAN! GTR 0 echo Hen gio: chay %GIO_CHAY% gio roi tam dung ^(GIO_CHAY^).
call :giay CHAY_LUC
rem Canh cua so: mot PowerShell an cho cua so nay dong - ke ca bam X - roi dung moi game cua thu muc nay.
set "CANH=%LV%\"
set "CANH_XONG=%LV%\canh-xong.txt"
del /q "%CANH_XONG%" 2>nul
start "Hoc tang cuong - canh cua so" /MIN powershell -NoProfile -WindowStyle Hidden -Command "$c = (Get-CimInstance Win32_Process -Filter ('ProcessId=' + $PID)).ParentProcessId; if (-not $c) { exit }; while (Get-Process -Id $c -ErrorAction SilentlyContinue) { if (Test-Path -LiteralPath $env:CANH_XONG) { exit }; Start-Sleep -Seconds 3 }; Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'openlf2.exe' -and $_.CommandLine -and $_.CommandLine.Contains($env:CANH) } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }"
>>"%LV%\tom-tat.txt" echo === Bat dau luc %DATE% %TIME%: nhan vat !TEN_THAT!, ban mod %PACK_1%, %N% tien trinh x %TRAN% tran moi vong

set /a E=1
:vong_tiep
if %E% GTR %VONG% goto xong
rem Vong da xong: co bo-nao-<vong>.txt (dong RLW_HEAD o dau). Kiem tra cua no (neu den luot) lam sau.
if exist "%LV%\bo-nao-%E%.txt" (
  findstr /b /c:"RLW_HEAD" "%LV%\bo-nao-%E%.txt" >nul 2>nul && (
    call :kiem_neu_can
    if defined HET_GIO goto het_gio
    set /a E+=1
    goto vong_tiep
  )
  del /q "%LV%\bo-nao-%E%.txt" 2>nul
)
if !GIOI_HAN! GTR 0 (
  call :dong_ho
  if !DA_CHAY! GEQ !GIOI_HAN! goto het_gio
)
call :mot_vong
if defined HET_GIO goto het_gio
if errorlevel 1 goto loi
call :kiem_neu_can
if defined HET_GIO goto het_gio
set /a E+=1
goto vong_tiep

:mot_vong
echo.
echo === Vong %E%/%VONG%: %N% tien trinh x %TRAN% tran ^(%TIME:~0,8%^) ===
call :giay BAT_DAU
set "D=%LV%\vong-%E%"
if exist "%D%" rmdir /s /q "%D%"
mkdir "%D%"
set /a TRUOC_E=E-1
set "W_TRUOC="
if exist "%LV%\bo-nao-%TRUOC_E%.txt" set "W_TRUOC=%LV%\bo-nao-%TRUOC_E%.txt"
call :chuan_bi "%D%"
set "W_CFG="
if defined W_TRUOC set W_CFG=weights = "rl_weights",
for /L %%k in (1,1,%N%) do (
  set /a SEED=HAT_GIONG+E*1000+%%k, OFF=E*7919+%%k*104
  >"%D%\p%%k\config.lua" echo return {command = "rl", step = "play", !W_CFG!fighter = "%NHAN_VAT%", games = %TRAN%, seed = !SEED!, offset = !OFF!, limit = 9000}
  start "Hoc tang cuong vong %E% - %%k" /MIN /%UU_TIEN% cmd /c call "%SELF%" chay1 vong-%E% %%k !SEED!
)
call :cho "%D%" "RL_DONE"
if defined HET_GIO exit /b 0
rem Gop: trung binh phan doi cua cac tien trinh, dat len bo nao cua vong truoc.
set "M=%D%\gop"
mkdir "%M%" 2>nul
call :ban_bench "%M%"
if defined W_TRUOC call :mo_dun "%W_TRUOC%" "%M%\rl_weights.lua" rl_weights
rem (Moi tien trinh mot file rl_part_<k>.txt, tai nguyen cua bo chay thu: mot mo dun Lua chi duoc toi 1 MB, ma phan
rem doi cua mot tien trinh da khoang 150 KB.)
set /a CO=0, PHAN=0
for /L %%k in (1,1,%N%) do if exist "%D%\p%%k\out.txt" (
  findstr /b /c:"RL_DONE" "%D%\p%%k\out.txt" >nul 2>nul && set /a CO+=1
  set /a PHAN+=1
  findstr /b /c:"RLD" /c:"RLS " /c:"RLM " "%D%\p%%k\out.txt" >"%M%\rl_part_!PHAN!.txt"
  >>"%M%\package.manifest" echo asset=mods/bench/rl_part_!PHAN!.txt^|rl_part_!PHAN!.txt
)
if !CO! EQU 0 (echo [LOI] Khong tien trinh nao hoc xong o vong %E% - xem "%D%\p1\out.txt".& exit /b 1)
>"%M%\config.lua" echo return {command = "rl", step = "avg", !W_CFG!parts = !PHAN!}
"%GAME%" --pack "%PACK_1%" %XS% --mod "%M%" --seed 1 --input-trace "" >"%M%\out.txt" 2>&1
call :cho_dong "%M%\out.txt" "RL_DONE"
findstr /b /c:"RLW" "%M%\out.txt" >"%LV%\bo-nao-%E%.tmp"
findstr /b /c:"RLW_HEAD" "%LV%\bo-nao-%E%.tmp" >nul 2>nul || (echo [LOI] Khong gop duoc vong %E% - xem "%M%\out.txt".& del /q "%LV%\bo-nao-%E%.tmp" 2>nul& exit /b 1)
move /y "%LV%\bo-nao-%E%.tmp" "%LV%\bo-nao-%E%.txt" >nul
call :giay XONG_LUC
set /a "GIAY_V=(XONG_LUC-BAT_DAU+86400) %% 86400, CON_V=VONG-E, CON=CON_V*GIAY_V/60, CON_G=CON/60, CON_P=CON %% 60"
for /f "tokens=1,* delims= " %%a in ('findstr /b /c:"RLR games" "%M%\out.txt"') do (
  >>"%LV%\tom-tat.txt" echo Vong %E%: !CO! tien trinh, %%b ^(!GIAY_V! giay^)
  echo   %%b
)
for /f "tokens=1,* delims= " %%a in ('findstr /b /c:"RLR moves" "%M%\out.txt"') do >>"%LV%\tom-tat.txt" echo   nuoc cua bo nao: %%b
echo Vong %E% xong ^(!GIAY_V! giay^); con !CON_V! vong, khoang !CON_G! gio !CON_P! phut.
rem Phan doi cua tung tien trinh da nam trong bo nao moi: bo thu muc vong (giu out.txt cua buoc gop).
copy /y "%M%\out.txt" "%LV%\gop-cuoi.txt" >nul
rmdir /s /q "%D%" 2>nul
exit /b 0

rem --- Kiem tra bo nao cua vong %E% neu den luot (moi KIEM_TRA_MOI vong, va vong cuoi) va chua kiem tra ---
:kiem_neu_can
set "DEN="
if %E% EQU %VONG% set "DEN=1"
if %KIEM_TRA_MOI% GTR 0 (
  set /a "DU=E %% KIEM_TRA_MOI"
  if !DU! EQU 0 set "DEN=1"
)
if not defined DEN exit /b 0
if exist "%LV%\kiem-tra-%E%.txt" exit /b 0
if !GIOI_HAN! GTR 0 (
  call :dong_ho
  if !DA_CHAY! GEQ !GIOI_HAN! (set "HET_GIO=1"& exit /b 0)
)
echo.
echo === Kiem tra bo nao vong %E%: moi tran hai lan, bo nao va XOI mot minh ^(%TIME:~0,8%^) ===
set "K=%LV%\kiem-tra-vong-%E%"
if exist "%K%" rmdir /s /q "%K%"
mkdir "%K%"
set "W_TRUOC=%LV%\bo-nao-%E%.txt"
call :chuan_bi "%K%"
rem Cung cac tran cho moi lan kiem tra (hat giong co dinh): cac lan kiem tra so duoc voi nhau.
for /L %%k in (1,1,%N%) do (
  set /a SEED=HAT_GIONG+900000+%%k, OFF=%%k*131
  >"%K%\p%%k\config.lua" echo return {command = "rl", step = "eval", both = true, weights = "rl_weights", fighter = "%NHAN_VAT%", games = %TRAN_KIEM_TRA%, seed = !SEED!, offset = !OFF!, limit = 9000}
  start "Hoc tang cuong kiem tra - %%k" /MIN /%UU_TIEN% cmd /c call "%SELF%" chay1 kiem-tra-vong-%E% %%k !SEED!
)
call :cho "%K%" "RL_DONE"
if defined HET_GIO exit /b 0
set "M=%K%\gop"
mkdir "%M%" 2>nul
call :ban_bench "%M%"
>"%M%\rl_evals.lua" echo return {text = [==[
for /L %%k in (1,1,%N%) do if exist "%K%\p%%k\out.txt" findstr /b /c:"RLE " "%K%\p%%k\out.txt" >>"%M%\rl_evals.lua"
>>"%M%\rl_evals.lua" echo ]==]}
>>"%M%\package.manifest" echo module=rl_evals^|rl_evals.lua
>"%M%\config.lua" echo return {command = "rl", step = "sum", evals = "rl_evals"}
"%GAME%" --pack "%PACK_1%" %XS% --mod "%M%" --seed 1 --input-trace "" >"%M%\out.txt" 2>&1
call :cho_dong "%M%\out.txt" "RL_DONE"
rem Hai dong: greedy (bo nao ra nuoc no cho la hay nhat - nhu khi dau that) va sample (nuoc rut ngau nhien theo bo nao,
rem nhu luc hoc).
set "KQ="
del /q "%LV%\kiem-tra-%E%.tmp" 2>nul
for /f "tokens=1,* delims= " %%a in ('findstr /b /c:"RLC " "%M%\out.txt"') do (
  set "KQ=1"
  >>"%LV%\kiem-tra-%E%.tmp" echo %%b
  >>"%LV%\tom-tat.txt" echo KIEM TRA vong %E%, %%b
  echo   %%b
)
if not defined KQ (echo [CHU Y] Khong cong duoc ket qua kiem tra vong %E% - xem "%M%\out.txt".& exit /b 0)
move /y "%LV%\kiem-tra-%E%.tmp" "%LV%\kiem-tra-%E%.txt" >nul
rem Bo nao tot nhat den nay: lan kiem tra "greedy" (nhu khi dau that) hon XOI nhieu nhat - bo-nao-tot-nhat.txt, va
rem tot-nhat.txt = vong va diem (phan muoi diem moi 100 tran). dua-bo-nao-vao-mod.bat lay bo nay.
set "DIEM="
for /f "tokens=2,3" %%a in ('findstr /b /c:"RLB " "%M%\out.txt"') do if /i "%%a"=="greedy" set "DIEM=%%b"
if defined DIEM (
  set "DIEM_TOT="
  if exist "%LV%\tot-nhat.txt" for /f "usebackq tokens=1,2" %%a in ("%LV%\tot-nhat.txt") do set "DIEM_TOT=%%b"
  set "MOI="
  if not defined DIEM_TOT (set "MOI=1") else if !DIEM! GTR !DIEM_TOT! set "MOI=1"
  if defined MOI (
    copy /y "%LV%\bo-nao-%E%.txt" "%LV%\bo-nao-tot-nhat.txt" >nul
    >"%LV%\tot-nhat.txt" echo %E% !DIEM!
    >>"%LV%\tom-tat.txt" echo   ^(bo nao tot nhat den nay: vong %E%^)
    echo   ^(bo nao tot nhat den nay: vong %E%^)
  )
)
rmdir /s /q "%K%" 2>nul
exit /b 0

rem --- Xac nhan (tu goi 89), sau vong cuoi: bo nao vong cuoi va bo tot nhat (neu khac) danh lai tren nhung tran moi,
rem chi greedy (nhu khi dau that). Moi lan kiem tra deu dung cung mot bo tran va lech vai diem do may rui, nen lan cao
rem nhat trong nhieu lan thuong la lan gap may; tren tran moi moi ra diem that. Bo co diem xac nhan cao hon duoc chon
rem (bang nhau: bo vong cuoi): xac-nhan.txt = vong va diem (phan muoi diem moi 100 tran); dua-bo-nao-vao-mod.bat lay
rem bo nay. Bo nao da xac nhan (xac-nhan-<vong>.txt) thi khong danh lai. ---
:xac_nhan
if not exist "%LV%\bo-nao-%VONG%.txt" exit /b 0
set "XN_TOT="
if exist "%LV%\tot-nhat.txt" for /f "usebackq tokens=1" %%a in ("%LV%\tot-nhat.txt") do set "XN_TOT=%%a"
if "!XN_TOT!"=="%VONG%" set "XN_TOT="
if defined XN_TOT if not exist "%LV%\bo-nao-!XN_TOT!.txt" set "XN_TOT="
call :xn_mot %VONG%
if defined HET_GIO exit /b 0
if defined XN_TOT call :xn_mot !XN_TOT!
if defined HET_GIO exit /b 0
set "XN_CHON="
set "XN_DIEM="
for %%r in (%VONG% !XN_TOT!) do if exist "%LV%\xac-nhan-%%r.txt" for /f "usebackq tokens=1,2" %%a in ("%LV%\xac-nhan-%%r.txt") do (
  if not defined XN_CHON (
    set "XN_CHON=%%a"
    set "XN_DIEM=%%b"
  ) else if %%b GTR !XN_DIEM! (
    set "XN_CHON=%%a"
    set "XN_DIEM=%%b"
  )
)
if not defined XN_CHON exit /b 0
set "XN_CU="
if exist "%LV%\xac-nhan.txt" for /f "usebackq tokens=1,2" %%a in ("%LV%\xac-nhan.txt") do set "XN_CU=%%a %%b"
if "!XN_CU!"=="!XN_CHON! !XN_DIEM!" (echo   Bo nao da chon tu truoc: vong !XN_CHON!.& exit /b 0)
>"%LV%\xac-nhan.txt" echo !XN_CHON! !XN_DIEM!
>>"%LV%\tom-tat.txt" echo XAC NHAN: chon bo nao vong !XN_CHON! - dua-bo-nao-vao-mod.bat dua no vao neu network - XOI tren tran moi duong.
echo   Chon bo nao vong !XN_CHON!.
exit /b 0

rem --- Xac nhan mot bo nao (tham so: vong, file bo-nao-<vong>.txt); ket qua xac-nhan-<vong>.txt = vong va diem ---
:xn_mot
set "XR=%~1"
if exist "%LV%\xac-nhan-%XR%.txt" exit /b 0
if !GIOI_HAN! GTR 0 (
  call :dong_ho
  if !DA_CHAY! GEQ !GIOI_HAN! (set "HET_GIO=1"& exit /b 0)
)
set /a XN_MOI=1
set /a "XN_MOI=(TRAN_XAC_NHAN+N-1)/N" 2>nul
if !XN_MOI! LSS 1 set /a XN_MOI=1
echo.
echo === Xac nhan bo nao vong %XR% tren tran moi: !XN_MOI! tran moi tien trinh, bo nao ^(greedy^) va XOI mot minh ^(%TIME:~0,8%^) ===
set "K=%LV%\xac-nhan-vong-%XR%"
if exist "%K%" rmdir /s /q "%K%"
mkdir "%K%"
set "W_TRUOC=%LV%\bo-nao-%XR%.txt"
call :chuan_bi "%K%"
rem Hat giong rieng: nhung tran khac cac lan kiem tra va cac vong hoc; moi bo nao xac nhan danh cung cac tran ay.
for /L %%k in (1,1,%N%) do (
  set /a SEED=HAT_GIONG+900500+%%k, OFF=%%k*173+7
  >"%K%\p%%k\config.lua" echo return {command = "rl", step = "eval", greedy = true, weights = "rl_weights", fighter = "%NHAN_VAT%", games = !XN_MOI!, seed = !SEED!, offset = !OFF!, limit = 9000}
  start "Hoc tang cuong xac nhan - %%k" /MIN /%UU_TIEN% cmd /c call "%SELF%" chay1 xac-nhan-vong-%XR% %%k !SEED!
)
call :cho "%K%" "RL_DONE"
if defined HET_GIO exit /b 0
set "M=%K%\gop"
mkdir "%M%" 2>nul
call :ban_bench "%M%"
>"%M%\rl_evals.lua" echo return {text = [==[
for /L %%k in (1,1,%N%) do if exist "%K%\p%%k\out.txt" findstr /b /c:"RLE " "%K%\p%%k\out.txt" >>"%M%\rl_evals.lua"
>>"%M%\rl_evals.lua" echo ]==]}
>>"%M%\package.manifest" echo module=rl_evals^|rl_evals.lua
>"%M%\config.lua" echo return {command = "rl", step = "sum", evals = "rl_evals"}
"%GAME%" --pack "%PACK_1%" %XS% --mod "%M%" --seed 1 --input-trace "" >"%M%\out.txt" 2>&1
call :cho_dong "%M%\out.txt" "RL_DONE"
for /f "tokens=1,* delims= " %%a in ('findstr /b /c:"RLC greedy" "%M%\out.txt"') do (
  >>"%LV%\tom-tat.txt" echo XAC NHAN vong %XR% ^(tran moi^), %%b
  echo   %%b
)
set "DIEM="
for /f "tokens=2,3" %%a in ('findstr /b /c:"RLB " "%M%\out.txt"') do if /i "%%a"=="greedy" set "DIEM=%%b"
if not defined DIEM (echo [CHU Y] Khong cong duoc ket qua xac nhan vong %XR% - xem "%M%\out.txt".& exit /b 0)
>"%LV%\xac-nhan-%XR%.txt" echo %XR% !DIEM!
rmdir /s /q "%K%" 2>nul
exit /b 0

:xong
call :xac_nhan
if defined HET_GIO goto het_gio
echo.
echo ===== Xong %VONG% vong. Ket qua: "%LV%\tom-tat.txt" =====
findstr /c:"KIEM TRA" /c:"XAC NHAN" "%LV%\tom-tat.txt"
echo.
echo Gui file tom-tat.txt cho nguoi lam AI. Dong "greedy": "network - XOI" duong ^(+^) va lon hon phan +- la bo nao da hon
echo XOI mot minh. Dua bo nao vao ban mod: chay dua-bo-nao-vao-mod.bat ^(chi nhan vat co bo nao hon XOI^).
if defined CANH_XONG >"%CANH_XONG%" echo xong
pause
exit /b 0

:loi
echo [LOI] Dung o vong %E%. Chay lai file nay de lam tiep.
if defined CANH_XONG >"%CANH_XONG%" echo xong
pause
exit /b 1

:het_gio
echo.
echo === Da chay du %GIO_CHAY% gio ^(%TIME:~0,8%^): tam dung. Chay lai file nay la lam tiep. ===
>>"%LV%\tom-tat.txt" echo Tam dung luc %TIME:~0,8% sau %GIO_CHAY% gio ^(GIO_CHAY^)
if defined CANH_XONG >"%CANH_XONG%" echo xong
pause
exit /b 0

rem --- Mot file thanh mo dun Lua cua bo chay thu: %1 file, %2 file .lua, %3 ten mo dun (them vao package.manifest) ---
:mo_dun
>"%~2" echo return {text = [==[
type "%~1" >>"%~2"
>>"%~2" echo ]==]}
for %%f in ("%~2") do >>"%%~dpfpackage.manifest" echo module=%~3^|%~3.lua
exit /b 0

rem --- Moi tien trinh mot thu muc p<k>: bo chay thu, ban sao smart_ai.lua (doi thu, XOI khong bo nao), bo nao cua vong truoc ---
:chuan_bi
for /L %%k in (1,1,%N%) do (
  mkdir "%~1\p%%k" 2>nul
  del /q "%~1\p%%k\xong.txt" 2>nul
  call :ban_bench "%~1\p%%k"
  if defined W_TRUOC call :mo_dun "!W_TRUOC!" "%~1\p%%k\rl_weights.lua" rl_weights
)
exit /b 0

:ban_bench
pushd "%BENCH%"
copy /y *.lua "%~1\" >nul
copy /y package.manifest "%~1\" >nul
popd
copy /y "%LV%\scripts\base\game\smart_ai.lua" "%~1\hs_alt.lua" >nul
>>"%~1\package.manifest" echo module=hs_alt^|hs_alt.lua
exit /b 0

:giay
set "T_=%TIME: =0%"
set /a "%1=(1%T_:~0,2%-100)*3600+(1%T_:~3,2%-100)*60+(1%T_:~6,2%-100)" 2>nul
exit /b 0

rem --- Cho moi tien trinh xong: dong %2 trong out.txt, hoac xong.txt (game tat, ke ca khi loi) ---
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
  if exist "%~1\p%%k\xong.txt" set "X=1"
  if defined X set /a XONG+=1
  if defined Y set /a TOT+=1
)
if !XONG! GEQ %N% exit /b 0
if !GIOI_HAN! GTR 0 (
  call :dong_ho
  if !DA_CHAY! GEQ !GIOI_HAN! (
    set "HET_GIO=1"
    call :dung_het "%~1"
    exit /b 0
  )
)
set /a CHO+=5
rem Mot nua so tien trinh xong thi dat nhip: tien trinh nao con chay qua 2 lan nhip ay va qua it nhat 5 phut sau
rem nhip coi nhu bi treo - dung no va lam tiep voi cac tien trinh da xong.
set /a "NUA=TOT*2"
if !NUA! GEQ %N% if !NHIP! LSS 0 set /a NHIP=CHO
if !NHIP! GEQ 0 (
  set /a "HAN=NHIP*2, HAN2=NHIP+DOI_THEM"
  if !HAN2! GTR !HAN! set /a HAN=HAN2
  if !CHO! GEQ !HAN! (
    set /a CON_LAI=N-XONG
    echo   [CHU Y] !CON_LAI! tien trinh chay qua lau - dung chung, lam tiep voi !XONG!/%N% tien trinh.
    call :dung_treo "%~1"
    exit /b 0
  )
)
set /a PHUT=CHO%%60
if !PHUT! EQU 0 (
  echo   ... !XONG!/%N% tien trinh xong ^(!TIME:~0,8!^)
  tasklist /FI "IMAGENAME eq openlf2.exe" 2>nul | find /I "openlf2.exe" >nul || (echo   [CHU Y] Khong con game nao chay - bo qua cac tien trinh chua xong.& exit /b 0)
)
goto cho_tiep

:dung_treo
for /L %%k in (1,1,%N%) do (
  if not exist "%~1\p%%k\xong.txt" (
    set "TREO=%~1\p%%k"
    powershell -NoProfile -Command "Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'openlf2.exe' -and $_.CommandLine -and $_.CommandLine.Contains($env:TREO + [char]34) } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }" >nul 2>&1
  )
)
exit /b 0

:dung_het
set "TREO=%~1\"
powershell -NoProfile -Command "Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'openlf2.exe' -and $_.CommandLine -and $_.CommandLine.Contains($env:TREO) } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }" >nul 2>&1
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

:dong_ho
call :giay BAY_GIO_DH
set /a "DA_CHAY+=(BAY_GIO_DH-CHAY_LUC+86400) %% 86400, CHAY_LUC=BAY_GIO_DH"
exit /b 0

rem --- Mot tien trinh: %2 thu muc (vong-N hay kiem-tra-vong-N), %3 so tien trinh, %4 hat giong; xong thi dong cua so ---
:chay1
set "DIR=%LV%\%~2\p%~3"
"%GAME_DA_CHON%" --pack "%PACK_DA_CHON%" %XS_DA_CHON% --mod "!DIR!" --seed %~4 --input-trace "" >"!DIR!\out.txt" 2>&1
>"!DIR!\xong.txt" echo xong
exit
