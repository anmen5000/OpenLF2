@echo off
setlocal EnableDelayedExpansion
rem HOC SAU - XOI hoc mot "bo nao" nho (mang no-ron) tu chinh cac tran cua no: moi lan sap ra don, bo nao doan
rem don ay se mang lai gi (mau gay duoc tru mau mat trong 1,5 giay sau), va XOI can doan ay voi diem tu tinh cua no
rem khi chon don. Bo nao hoc tu du lieu ghi lai: moi lan XOI ra don trong hang nghin tran, ghi tinh huong + don + ket
rem qua; roi huan luyen ngay trong game (vai phut moi trieu lan ra don). (OpenLF2 ban 67 tro len.)
rem Moi luot: cac tien trinh ghi du lieu PHUT_GHI phut (XOI danh voi AI cua ban mod - script ai\<id>.as nhu AI cua
rem Sauce - neu co, khong thi voi chinh no); gop du lieu cua moi luot tu truoc toi gio; huan luyen mot bo nao cho
rem tung ban mod; luot sau XOI ghi du lieu voi bo nao vua hoc. Cuoi cung kiem tra: XOI co bo nao va XOI khong co
rem cung danh doi thu ay, so thang/thua ghi vao hoc-sau\ket-qua.txt (gui file nay cho nguoi lam AI). Bo nao cua moi
rem ban mod: xoi-<ten>\brain.txt, va <ten>-xoi.zip = ban mod co bo nao (cung bo so va bo nho XOI neu da co) - tai
rem len relay hay xuat ban thi XOI choi ban mod ay voi bo nao (trong tran ghi "brain" canh XOI).
rem Tam dung: dong cua so nay va cac cua so thu nho. Chay lai la lam tiep tu luot dang do (du lieu da ghi duoc giu).
rem Hoc them: tang VONG roi chay lai - lam tiep tu luot ke, voi tat ca du lieu da co, luot moi ghi voi bo nao moi nhat.
rem Lam lai tu dau: xoa thu muc hoc-sau (luot 1 ghi voi bo nao da co trong xoi-<ten>, neu co).
rem ============ CHINH O DAY ============
rem Game da cai. De trong thi tu tim (Install for me only, all users, hoac thu muc OpenLF2 canh file nay).
set "GAME="
rem File zip ban mod. De trong thi dung MOI file .zip ban mod canh file nay (tru goi lf2-online-upload, xoi-kit, va
rem <ten>-xoi.zip khi <ten>.zip cung nam day), cac tien trinh chia deu cho cac ban mod (moi ban mod mot bo nao rieng);
rem keo tha mot file zip vao file nay thi chi dung ban mod ay. Ban goc hay ban <ten>-xoi.zip cua spsa.bat/xoi-hoc.bat
rem deu duoc: XOI ghi du lieu voi bo so (tune.txt) va bo nho (notes.txt) trong thu muc xoi-<ten> canh file nay neu co,
rem khong thi voi bo so/bo nho trong goi; bo nao trong goi (xoi/brain.txt) la bo nao bat dau khi xoi-<ten> chua co.
rem Ket qua ve xoi-<ten>\brain.txt va <ten>-xoi.zip (ban -xoi dua vao thi cap nhat chinh no, ban truoc giu o -xoi-truoc.zip).
set "PACK="
rem So luot (VONG) va so phut ghi du lieu moi luot (PHUT_GHI). Luot 1 ghi voi XOI nhu no dang co; tu luot 2 XOI ghi
rem voi bo nao vua hoc, nen bo nao hoc duoc ca cach choi moi cua no. Mot tien trinh ghi chung 2.000 lan ra don moi
rem phut: 2 luot x 20 phut tren may 80 luong cho chung 6 trieu lan ra don (2,5 GB du lieu, huan luyen chung mot gio).
set "VONG=2"
set "PHUT_GHI=20"
set "SONG_SONG=%NUMBER_OF_PROCESSORS%"
rem So phut kiem tra cuoi (0 = bo qua): mot nua so tien trinh cho XOI co bo nao danh doi thu, nua kia cho XOI khong co.
set "PHUT_KIEM_TRA=10"
rem Muc uu tien cua cac tien trinh: BELOWNORMAL (ban van dung may muot trong luc chay), LOW, hoac NORMAL
set "UU_TIEN=BELOWNORMAL"
rem Hat giong dau (cung hat giong thi chay lai y het)
set "HAT_GIONG=7000"
rem Bo nao: so no-ron lop giua (AN) va so lan hoc qua toan bo du lieu (EPOCH). 48 va 8 la du; lon hon thi hoc lau hon.
set "AN=48"
set "EPOCH=8"
rem Thu muc tools\ai-bench va scripts cua goi ban 67 tro len (de trong thi tu tim canh file .bat nay)
set "BENCH="
set "SCRIPTS="
rem =====================================
rem Cai dat rieng cua ban, giu qua cac lan cap nhat bo XOI: file hoc-sau-cai-dat.bat canh file nay (tu tao), moi dong
rem mot cai dat nhu tren, vi du  set "VONG=3"  - chep de hoc-sau.bat moi len thi cai dat o day van con.
if exist "%~dp0hoc-sau-cai-dat.bat" (
  call "%~dp0hoc-sau-cai-dat.bat"
  if /i not "%~1"=="chay1" echo Cai dat rieng: hoc-sau-cai-dat.bat
)

rem (File nay tu goi lai chinh no cho tung tien trinh, trong cua so rieng: cmd /c call "<file nay>" chay1 <thu muc>
rem <so tien trinh> <hat giong> <so thu tu ban mod>. Ngoai ten file, khong dau ngoac kep nao - duong dan co dau cach
rem thi Windows bo dau ngoac kep dau va cuoi.)
if /i "%~1"=="chay1" goto chay1

set "SELF=%~f0"
set "KIT=%~dp0"
set "LV=%~dp0hoc-sau"
rem --- Ban mod: keo tha, dong PACK, hoac moi file zip ban mod canh file nay ---
set /a NP=0
if not "%~1"=="" if /i "%~x1"==".zip" if exist "%~f1" (
  set /a NP=1
  set "PACK_1=%~f1"
)
if !NP! EQU 0 if defined PACK (
  set /a NP=1
  for %%z in ("!PACK!") do set "PACK_1=%%~fz"
)
if !NP! EQU 0 (
  pushd "%~dp0"
  for %%z in (*.zip) do (
    set "TEN=%%~nz"
    set "BO="
    if /i "!TEN:~-4!"=="-xoi" if exist "!TEN:~0,-4!.zip" set "BO=1"
    if /i "!TEN:~-10!"=="-xoi-truoc" set "BO=1"
    if /i "!TEN:~-13!"=="-xoi-previous" set "BO=1"
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
rem (Ten ban mod: ten file bo duoi -xoi, de ban <ten>-xoi.zip cua spsa.bat/xoi-hoc.bat dung chung xoi-<ten> voi ban goc.)
for /L %%p in (1,1,%NP%) do call :ten_mod %%p

rem --- Game, bo chay thu, scripts ---
if not defined GAME (
  for %%g in ("%LOCALAPPDATA%\Programs\OpenLF2\openlf2.exe" "%ProgramFiles(x86)%\OpenLF2\openlf2.exe" "%ProgramFiles%\OpenLF2\openlf2.exe" "%~dp0OpenLF2\openlf2.exe") do (
    if not defined GAME if exist "%%~g" set "GAME=%%~g"
  )
)
if not defined GAME set "GAME=%LOCALAPPDATA%\Programs\OpenLF2\openlf2.exe"
if not defined BENCH (
  if exist "%~dp0tools\ai-bench\record.lua" set "BENCH=%~dp0tools\ai-bench"
  if exist "%~dp0record.lua" set "BENCH=%~dp0."
  if exist "%~dp0..\record.lua" set "BENCH=%~dp0.."
)
if not defined SCRIPTS (
  if exist "%~dp0scripts\base\game\smart_ai.lua" set "SCRIPTS=%~dp0scripts"
  if exist "%~dp0..\..\..\scripts\base\game\smart_ai.lua" set "SCRIPTS=%~dp0..\..\..\scripts"
)
if not exist "%GAME%" (echo Khong thay game "%GAME%": cai OpenLF2 ^(bo cai OpenLF2-Windows-x64.exe o muc Releases cua trang GitHub cua du an, chon Install for me only^), hoac sua dong GAME o dau file.& pause& exit /b 1)
if not defined BENCH (echo Khong thay thu muc tools\ai-bench co record.lua - can bo XOI hoac goi ban 67 tro len.& pause& exit /b 1)
if not exist "%BENCH%\train.lua" (echo Khong thay "%BENCH%\train.lua" - can bo XOI hoac goi ban 67 tro len.& pause& exit /b 1)
if not defined SCRIPTS (echo Khong thay thu muc scripts canh file nay - can bo XOI hoac goi ban 67 tro len.& pause& exit /b 1)
findstr /c:"brain_kit" "%SCRIPTS%\base\game\smart_ai.lua" >nul 2>nul || (echo "%SCRIPTS%\base\game\smart_ai.lua" chua co bo nao ^(brain_kit^) - can bo XOI hoac goi ban 67 tro len.& pause& exit /b 1)
set /a N=SONG_SONG
if %N% LSS 1 set /a N=1
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
if %N% LSS %NP% set /a N=NP
set /a GIAY_GHI=PHUT_GHI*60, GIAY_KT=PHUT_KIEM_TRA*60
if defined THU_GIAY set /a GIAY_GHI=THU_GIAY, GIAY_KT=THU_GIAY
if %GIAY_GHI% LSS 10 set /a GIAY_GHI=10
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

echo Ban mod ^(%NP%^):
for /L %%p in (1,1,%NP%) do call echo   %%p. %%PACK_%%p%%  [xoi-%%TEN_%%p%%]
echo %VONG% luot x %PHUT_GHI% phut ghi du lieu, %N% tien trinh ^(uu tien %UU_TIEN%^); ket qua vao "%LV%"
echo Tam dung: dong cua so nay va cac cua so thu nho. Chay lai file nay la lam tiep.
echo De may chay qua dem: tat che do ngu cua Windows ^(Settings - System - Power - Sleep: Never^).

set "GAME_DA_CHON=%GAME%"
set XS_DA_CHON=%XS%
rem Ban lam viec cua tung ban mod: hoc-sau\ban-mod-<p>.zip = file zip ban mod, them bo so va bo nho cua xoi-<ten> (neu co),
rem bo bo nao trong goi ra (bo nao chi dua vao qua config, de phan kiem tra "khong co bo nao" dung la khong co). Cac tien
rem trinh ghi va kiem tra chay ban nay; lam lai moi lan chay (bo so moi cua spsa.bat duoc dung ngay).
rem (Wine's cmd, which tries this file, cannot expand !PACK_%%p!: call set and subroutines are used for such names.)
set "BM_LOI="
for /L %%p in (1,1,%NP%) do call :lam_ban_mod %%p
if defined BM_LOI (
  if "%KHONG_DUNG%"=="" pause
  exit /b 1
)
rem (Bo nao da co tu lan truoc cua tung ban mod: luot 1 ghi voi no, nhu luot sau.)
for /L %%p in (1,1,%NP%) do call :nao_dau %%p

set /a E=1
:luot_tiep
if %E% GTR %VONG% goto kiem
set "D=%LV%\luot-%E%"
if exist "%D%\xong-luot.txt" (
  rem (Luot da xong: bo nao cua no.)
  for /L %%p in (1,1,%NP%) do if exist "%D%\nao-%%p.txt" set "NAO_%%p=%D%\nao-%%p.txt"
  set /a E+=1
  goto luot_tiep
)
call :mot_luot
if errorlevel 1 goto loi
set /a E+=1
goto luot_tiep

:mot_luot
echo.
echo === Luot %E%/%VONG%: %N% tien trinh ghi du lieu trong %PHUT_GHI% phut ^(%TIME%^) ===
call :giay BAT_DAU
rem Ghi du lieu (tien trinh da ghi xong lan truoc - co dong RECORD - thi giu, khong ghi lai).
set /a XONG_N=0
if exist "%D%" for /L %%k in (1,1,%N%) do if exist "%D%\p%%k\out.txt" (
  findstr /c:"RECORD " "%D%\p%%k\out.txt" >nul 2>nul && set /a XONG_N+=1
)
if !XONG_N! GEQ %N% (
  echo   ^(da ghi xong lan truoc^)
  goto hoc_luot
)
if not exist "%D%" mkdir "%D%"
set /a PI=0
for /L %%k in (1,1,%N%) do (
  set /a PI+=1
  if !PI! GTR %NP% set /a PI=1
  set "DA="
  if exist "%D%\p%%k\out.txt" findstr /c:"RECORD " "%D%\p%%k\out.txt" >nul 2>nul && set "DA=1"
  if not defined DA (
    mkdir "%D%\p%%k" 2>nul
    del /q "%D%\p%%k\xong.txt" 2>nul
    del /q "%D%\p%%k\out.txt" 2>nul
    del /q "%D%\p%%k\gop.txt" 2>nul
    call :ban_bench "%D%\p%%k"
    copy /y "%LV%\scripts\base\game\smart_ai.lua" "%D%\p%%k\hs_alt.lua" >nul
    >>"%D%\p%%k\package.manifest" echo module=hs_alt^|hs_alt.lua
    set "NAO_CFG="
    call set "NAO_NAY=%%NAO_!PI!%%"
    if defined NAO_NAY (
      call :nao_lua "!NAO_NAY!" "%D%\p%%k\xoi_brain.lua"
      >>"%D%\p%%k\package.manifest" echo module=xoi_brain^|xoi_brain.lua
      set NAO_CFG=brain = {module = "xoi_brain", on = {1}},
    )
    set /a SEED=HAT_GIONG+E*1000+%%k
    >"%D%\p%%k\config.lua" echo return {command = "record", alt = "hs_alt", !NAO_CFG! games = 1000000, seconds = %GIAY_GHI%, seed = !SEED!, limit = 9000}
    start "Hoc sau - luot %E% - %%k" /MIN /%UU_TIEN% cmd /c call "%SELF%" chay1 luot-%E% %%k !SEED! !PI!
  )
)
call :cho "%D%" "RECORD "
:hoc_luot
rem Gop du lieu cua luot nay: cac dong REC cua tien trinh k vao du-lieu\<ban mod>\luot-%E%-p<k>.txt (ghi lai ca file,
rem nen chay lai khong gop trung), roi bo chung khoi out.txt cho nhe.
set /a PI=0
for /L %%k in (1,1,%N%) do (
  set /a PI+=1
  if !PI! GTR %NP% set /a PI=1
  if not exist "%LV%\du-lieu\!PI!" mkdir "%LV%\du-lieu\!PI!"
  if exist "%D%\p%%k\out.txt" if not exist "%D%\p%%k\gop.txt" (
    findstr /b /c:"REC " "%D%\p%%k\out.txt" >"%LV%\du-lieu\!PI!\luot-%E%-p%%k.tmp"
    move /y "%LV%\du-lieu\!PI!\luot-%E%-p%%k.tmp" "%LV%\du-lieu\!PI!\luot-%E%-p%%k.txt" >nul
    >"%D%\p%%k\gop.txt" echo xong
    findstr /v /b /c:"REC " "%D%\p%%k\out.txt" >"%D%\p%%k\out-tom.txt"
    move /y "%D%\p%%k\out-tom.txt" "%D%\p%%k\out.txt" >nul
  )
)
rem Goi du lieu cua tung ban mod (tat ca cac luot) thanh goi huan luyen, roi huan luyen - mot tien trinh moi ban mod.
echo === Huan luyen bo nao cho tung ban mod ^(%TIME%^) ===
set /a DONG_TONG=0
for /L %%p in (1,1,%NP%) do (
  set "H=%D%\hoc%%p"
  set "DA="
  if exist "!H!\out.txt" findstr /b /c:"XOI_BRAIN b2" "!H!\out.txt" >nul 2>nul && set "DA=1"
  set /a DONG_%%p=0
  if not defined DA (
    mkdir "!H!" 2>nul
    del /q "!H!\out.txt" 2>nul
    del /q "!H!\xong.txt" 2>nul
    call :ban_bench "!H!"
    call :goi_du_lieu %%p "!H!\du-lieu.zip"
    >"!H!\config.lua" echo return {command = "train", epochs = %EPOCH%, hidden = %AN%, weights = true, seed = %HAT_GIONG%}
  )
  if exist "!H!\du-lieu.txt" for /f %%c in ('type "!H!\du-lieu.txt"') do set /a DONG_%%p=%%c
  set /a DONG_TONG+=DONG_%%p
)
echo   Du lieu: !DONG_TONG! lan ra don ^(tat ca cac luot^)
if !DONG_TONG! LSS 200 (echo [LOI] Qua it du lieu - cac tien trinh co chay khong? Xem "%D%\p1\out.txt".& exit /b 1)
for /L %%p in (1,1,%NP%) do (
  set "DA="
  if exist "%D%\hoc%%p\out.txt" findstr /b /c:"XOI_BRAIN b2" "%D%\hoc%%p\out.txt" >nul 2>nul && set "DA=1"
  if not defined DA start "Hoc sau - huan luyen %%p" /MIN /%UU_TIEN% cmd /c call "%SELF%" chay1 luot-%E%\hoc %%p %HAT_GIONG% %%p hoc
)
set "N_CU=%N%"
set /a N=NP
call :cho_hoc "%D%"
set /a N=N_CU
for /L %%p in (1,1,%NP%) do (
  set "H=%D%\hoc%%p"
  findstr /b /c:"XOI_BRAIN b2" "!H!\out.txt" >nul 2>nul || (echo [LOI] Huan luyen ban mod %%p khong xong - xem "!H!\out.txt".& exit /b 1)
  findstr /b /c:"XOI_BRAIN " "!H!\out.txt" >"%D%\nao-%%p.txt"
  set "NAO_%%p=%D%\nao-%%p.txt"
  set "DONG_BASE="
  set "DONG_NET="
  for /f "delims=" %%l in ('findstr /b /c:"BASE " "!H!\out.txt"') do set "DONG_BASE=%%l"
  for /f "delims=" %%l in ('findstr /b /c:"NET done" "!H!\out.txt"') do set "DONG_NET=%%l"
  call set "PK=%%PACK_%%p%%"
  call set "DN=%%DONG_%%p%%"
  for %%z in ("!PK!") do echo   %%p. %%~nxz: !DONG_BASE! / !DONG_NET!
  for %%z in ("!PK!") do >>"%LV%\thoi-gian.txt" echo Luot %E%/%VONG% ban mod %%p ^(%%~nxz^): !DN! lan ra don; !DONG_BASE!; !DONG_NET!
  del /q "!H!\du-lieu.zip" 2>nul
)
call :giay HET
set /a "GIAY_V=(HET-BAT_DAU+86400) %% 86400, PHUT_V=GIAY_V/60"
>>"%LV%\thoi-gian.txt" echo Luot %E%/%VONG% xong luc %TIME%, mat !PHUT_V! phut
>"%D%\xong-luot.txt" echo xong
rem (Bo nao moi: kiem tra va goi lai - ke ca khi chay lai voi VONG lon hon de hoc them.)
if exist "%LV%\kiem-tra" rd /s /q "%LV%\kiem-tra"
del /q "%LV%\da-goi.txt" 2>nul
exit /b 0

:kiem
rem Kiem tra: tien trinh le cho XOI co bo nao danh doi thu, tien trinh chan ngay sau no cho XOI khong co bo nao danh
rem cung doi thu ay (AI cua ban mod neu co script, khong thi XOI khong bo nao), cung ban mod, cung hat giong.
if %GIAY_KT% LEQ 0 goto xong
set "K=%LV%\kiem-tra"
if exist "%K%\tong.txt" goto xong
echo.
echo === Kiem tra: XOI co bo nao va XOI khong co, %N% tien trinh trong %PHUT_KIEM_TRA% phut ^(%TIME%^) ===
if not exist "%K%" mkdir "%K%"
for /L %%k in (1,1,%N%) do (
  set /a "PI=((%%k-1)/2) %% NP + 1, LE=%%k %% 2, SEED=HAT_GIONG+500000+(%%k+1)/2"
  set "DA="
  if exist "%K%\p%%k\out.txt" findstr /c:"RECORD " "%K%\p%%k\out.txt" >nul 2>nul && set "DA=1"
  if not defined DA (
    mkdir "%K%\p%%k" 2>nul
    del /q "%K%\p%%k\xong.txt" 2>nul
    del /q "%K%\p%%k\out.txt" 2>nul
    call :ban_bench "%K%\p%%k"
    copy /y "%LV%\scripts\base\game\smart_ai.lua" "%K%\p%%k\hs_alt.lua" >nul
    >>"%K%\p%%k\package.manifest" echo module=hs_alt^|hs_alt.lua
    set "NAO_CFG="
    call set "NAO_NAY=%%NAO_!PI!%%"
    if !LE! EQU 1 if defined NAO_NAY (
      call :nao_lua "!NAO_NAY!" "%K%\p%%k\xoi_brain.lua"
      >>"%K%\p%%k\package.manifest" echo module=xoi_brain^|xoi_brain.lua
      set NAO_CFG=brain = {module = "xoi_brain", on = {1}},
    )
    >"%K%\p%%k\config.lua" echo return {command = "record", alt = "hs_alt", quiet = true, !NAO_CFG! games = 1000000, seconds = %GIAY_KT%, seed = !SEED!, limit = 9000}
    start "Hoc sau - kiem tra %%k" /MIN /%UU_TIEN% cmd /c call "%SELF%" chay1 kiem-tra %%k !SEED! !PI!
  )
)
call :cho "%K%" "RECORD "
rem Cong: tien trinh le = co bo nao (CW/CL), chan = khong (KW/KL); tung ban mod.
set /a CW=0, CL=0, KW=0, KL=0
for /L %%p in (1,1,%NP%) do set /a "CW_%%p=0, CL_%%p=0, KW_%%p=0, KL_%%p=0"
for /L %%k in (1,1,%N%) do (
  set /a "PI=((%%k-1)/2) %% NP + 1, LE=%%k %% 2"
  rem (RECORD <games> games, <records> records, <name> won <w> lost <l> vs <o>: w la tu thu 8, l tu thu 10)
  if exist "%K%\p%%k\out.txt" for /f "tokens=8,10" %%a in ('findstr /b /c:"RECORD " "%K%\p%%k\out.txt"') do (
    if !LE! EQU 1 (
      set /a CW+=%%a, CL+=%%b
      set /a "CW_!PI!+=%%a, CL_!PI!+=%%b"
    ) else (
      set /a KW+=%%a, KL+=%%b
      set /a "KW_!PI!+=%%a, KL_!PI!+=%%b"
    )
  )
)
call :phan_tram !CW! !CL! CP
call :phan_tram !KW! !KL! KP
>"%K%\tong.txt" echo XOI co bo nao: thang !CW! thua !CL! ^(!CP!%%^); XOI khong co bo nao: thang !KW! thua !KL! ^(!KP!%%^) - cung doi thu, cung hat giong
if %NP% GTR 1 for /L %%p in (1,1,%NP%) do call :tong_mod %%p
:xong
rem Ket qua, va bo nao cua moi ban mod: xoi-<ten>\brain.txt, goi <ten>-xoi.zip.
(
  echo Hoc sau: %VONG% luot x %PHUT_GHI% phut, %N% tien trinh, AN=%AN% EPOCH=%EPOCH% HAT_GIONG=%HAT_GIONG%; ban mod:
  for /L %%p in (1,1,%NP%) do call echo   %%p. %%PACK_%%p%%
  if exist "%LV%\thoi-gian.txt" findstr /c:"Luot " "%LV%\thoi-gian.txt"
  if exist "%K%\tong.txt" type "%K%\tong.txt"
) >"%LV%\ket-qua.txt"
if not exist "%LV%\da-goi.txt" (
  echo.
  echo === Bo nao cua tung ban mod ===
  for /L %%p in (1,1,%NP%) do call :goi_nao %%p
  >"%LV%\da-goi.txt" echo xong
)
echo.
echo ===== Xong. Ket qua: "%LV%\ket-qua.txt" =====
type "%LV%\ket-qua.txt"
echo.
echo Gui file ket-qua.txt cho nguoi lam AI. Dung ngay: tai file ^<ten ban mod^>-xoi.zip len relay ^(cung id voi ban mod cu^)
echo hay xuat ban no - XOI choi ban mod ay voi bo nao ^(trong tran ghi "brain"^). Kiem tra cho XOI co bo nao thang it hon
echo XOI khong co thi dung tai len. Hoc them: tang VONG ^(trong file nay hay hoc-sau-cai-dat.bat^) roi chay lai.
if "%KHONG_DUNG%"=="" pause
exit /b 0
:loi
echo [LOI] Dung o luot %E%. Sua loi roi chay lai file nay de lam tiep.
if "%KHONG_DUNG%"=="" pause
exit /b 1

rem --- Dong ket qua kiem tra cua ban mod thu %1 vao tong.txt ---
:tong_mod
call :phan_tram !CW_%1! !CL_%1! CP
call :phan_tram !KW_%1! !KL_%1! KP
for %%z in ("!PACK_%1!") do >>"%K%\tong.txt" echo   %1. %%~nxz: co bo nao thang !CW_%1! thua !CL_%1! ^(!CP!%%^); khong co thang !KW_%1! thua !KL_%1! ^(!KP!%%^)
exit /b 0
rem --- Phan tram thang (mot chu so le) cua %1 thang %2 thua vao bien %3 ---
:phan_tram
set /a "PT_T=%1+%2, PT_V=0"
if !PT_T! GTR 0 set /a "PT_V=%1*1000/PT_T"
set /a "PT_1=PT_V/10, PT_2=PT_V %% 10"
set "%3=!PT_1!.!PT_2!"
exit /b 0
rem --- File bo nao %1 (XOI_BRAIN ...) thanh module Lua %2: return {text = [==[ ... ]==]} ---
:nao_lua
>"%~2" echo return {text = [==[
type "%~1" >>"%~2"
>>"%~2" echo ]==]}
exit /b 0
rem --- Goi du lieu cua ban mod %1 thanh goi huan luyen %2: mot file zip nho chi co data\data.txt va cac file .exe o
rem thu muc goc cua ban mod (du de game mo goi), va xoi\data_<n>.txt = cac dong REC cua moi luot (moi file duoi 3,5
rem MB - script doc duoc file toi 4 MB). So dong vao du-lieu.txt canh goi. ---
:goi_du_lieu
set "GD_PACK=!PACK_%1!"
set "GD_OUT=%~2"
set "GD_DIR=%LV%\du-lieu\%1"
set "GD_CNT=%~dp2du-lieu.txt"
set "GD_P=%1"
del /q "%GD_OUT%" 2>nul
del /q "%GD_CNT%" 2>nul
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; Add-Type -AssemblyName System.IO.Compression; Add-Type -AssemblyName System.IO.Compression.FileSystem; $src=[System.IO.Compression.ZipFile]::OpenRead($env:GD_PACK); try { $e=$src.Entries | Where-Object { $_.FullName -imatch '(^|[\\/])data[\\/]data\.txt$' } | Sort-Object { $_.FullName.Length } | Select-Object -First 1; if (-not $e) { throw 'zip khong co data/data.txt' }; $root=$e.FullName.Substring(0, $e.FullName.Length - 13); $out=[System.IO.Compression.ZipFile]::Open($env:GD_OUT,'Create'); try { foreach ($x in $src.Entries) { if ($x.FullName.Length -le $root.Length) { continue }; if ($x.FullName.Substring(0, $root.Length) -ine $root) { continue }; $rel=$x.FullName.Substring($root.Length).Replace('\', '/'); if ($rel -ieq 'data/data.txt' -or $rel -imatch '^[^/]+\.exe$') { $n=$out.CreateEntry($rel); $i=$x.Open(); $o=$n.Open(); try { $i.CopyTo($o) } finally { $o.Dispose(); $i.Dispose() } } }; $limit=3500000; $k=0; $w=$null; $bytes=$limit; $count=0; foreach ($f in (Get-ChildItem -LiteralPath $env:GD_DIR -Filter 'luot-*.txt' | Sort-Object Name)) { foreach ($line in [System.IO.File]::ReadLines($f.FullName)) { if (-not $line.StartsWith('REC ')) { continue }; if ($bytes + $line.Length + 1 -gt $limit) { if ($w) { $w.Dispose() }; $k++; $w=New-Object System.IO.StreamWriter(($out.CreateEntry('xoi/data_' + $k + '.txt')).Open()); $bytes=0 }; $w.Write($line); $w.Write([char]10); $bytes += $line.Length + 1; $count++ } }; if ($w) { $w.Dispose() }; [System.IO.File]::WriteAllText($env:GD_CNT, [string]$count + [char]13 + [char]10); Write-Host ('     Du lieu ban mod ' + $env:GD_P + ': ' + $count + ' dong, ' + $k + ' file trong ' + $env:GD_OUT) } finally { $out.Dispose() } } finally { $src.Dispose() }"
if not exist "%GD_OUT%" echo      [LOI] Khong goi duoc du lieu cua ban mod %1.
exit /b 0
rem --- Bo nao cua ban mod thu %1: xoi-<ten>\brain.txt (bo truoc giu o brain-truoc.txt), va <ten>-xoi.zip: ban sao file
rem zip ban mod, them xoi/brain.txt canh thu muc data - cung xoi/tune.txt va xoi/notes.txt cua xoi-<ten> neu co. Dua vao
rem chinh <ten>-xoi.zip thi cap nhat no tai cho (ban truoc giu o <ten>-xoi-truoc.zip). ---
:goi_nao
if not defined NAO_%1 (echo   %1. ^(chua co bo nao^)& exit /b 0)
set "XPACK=!PACK_%1!"
set "XTEN=!TEN_%1!"
for %%z in ("!XPACK!") do (
  set "XFULL=%%~fz"
  set "XDIR=%KIT%xoi-!XTEN!"
  set "XOUT=%%~dpz!XTEN!-xoi.zip"
  set "XTRUOC=%%~dpz!XTEN!-xoi-truoc.zip"
)
set "XTAI_CHO="
if /i "!XFULL!"=="!XOUT!" set "XTAI_CHO=1"
if not exist "!XDIR!" mkdir "!XDIR!"
if exist "!XDIR!\brain.txt" copy /y "!XDIR!\brain.txt" "!XDIR!\brain-truoc.txt" >nul
copy /y "!NAO_%1!" "!XDIR!\brain.txt" >nul
echo   %1. "!XDIR!\brain.txt"
set "XBRAIN=!XDIR!\brain.txt"
set "XTUNE="
if exist "!XDIR!\tune.txt" set "XTUNE=!XDIR!\tune.txt"
set "XNOTES="
if exist "!XDIR!\notes.txt" set "XNOTES=!XDIR!\notes.txt"
if exist "!XOUT!" copy /y "!XOUT!" "!XTRUOC!" >nul
if not defined XTAI_CHO del /q "!XOUT!" 2>nul
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; Add-Type -AssemblyName System.IO.Compression; Add-Type -AssemblyName System.IO.Compression.FileSystem; if (-not $env:XTAI_CHO) { Copy-Item -LiteralPath $env:XPACK -Destination $env:XOUT -Force }; $z=[System.IO.Compression.ZipFile]::Open($env:XOUT,'Update'); try { $e=$z.Entries | Where-Object { $_.FullName -imatch '(^|[\\/])data[\\/]data\.txt$' } | Sort-Object { $_.FullName.Length } | Select-Object -First 1; if (-not $e) { throw 'zip khong co data/data.txt' }; $root=$e.FullName.Substring(0, $e.FullName.Length - 13); foreach ($f in @(@($env:XNOTES, 'xoi/notes.txt'), @($env:XTUNE, 'xoi/tune.txt'), @($env:XBRAIN, 'xoi/brain.txt'))) { if ($f[0] -and (Test-Path -LiteralPath $f[0])) { $name=$root + $f[1]; foreach ($old in @($z.Entries | Where-Object { $_.FullName -ieq $name })) { $old.Delete() }; [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($z, $f[0], $name); Write-Host ('     Da them ' + $name) } } } finally { $z.Dispose() }" 2>nul
set "XLOI="
if errorlevel 1 set "XLOI=1"
if not exist "!XOUT!" set "XLOI=1"
if defined XLOI (echo      [LOI] Khong goi duoc - tu lam: mo file zip ban mod, vao thu muc co thu muc data, tao thu muc xoi, chep "!XDIR!\brain.txt" vao do.) else if defined XTAI_CHO (echo      Da cap nhat: "!XOUT!" - ban truoc: "!XTRUOC!") else (echo      Goi: "!XOUT!")
exit /b 0
rem --- Ten ban mod thu %1 (TEN_<p>): ten file zip, bo duoi -xoi ---
:ten_mod
for %%z in ("!PACK_%1!") do set "T_=%%~nz"
if /i "!T_:~-4!"=="-xoi" set "T_=!T_:~0,-4!"
set "TEN_%1=!T_!"
exit /b 0
rem --- Bo nao bat dau cua ban mod thu %1 (NAO_<p>): xoi-<ten>\brain.txt; hay thu muc theo ten file chua bo duoi -xoi
rem (hoc-sau.bat cua goi 67 lam vay); hay bo nao trong goi (lam_ban_mod lay ra nao-goi-<p>.txt) ---
:nao_dau
set "NAO_%1="
set "ND_=%KIT%xoi-!TEN_%1!\brain.txt"
if exist "!ND_!" set "NAO_%1=!ND_!"
if not defined NAO_%1 for %%z in ("!PACK_%1!") do if exist "%KIT%xoi-%%~nz\brain.txt" set "NAO_%1=%KIT%xoi-%%~nz\brain.txt"
if not defined NAO_%1 if exist "%LV%\nao-goi-%1.txt" set "NAO_%1=%LV%\nao-goi-%1.txt"
if defined NAO_%1 echo Ban mod %1 bat dau tu bo nao da co: "!NAO_%1!"
exit /b 0
rem --- Ban lam viec cua ban mod thu %1: hoc-sau\ban-mod-<p>.zip = ban sao file zip ban mod; xoi/tune.txt va xoi/notes.txt
rem thay bang cua xoi-<ten> neu co; xoi/brain.txt bo ra (lay ve nao-goi-<p>.txt khi xoi-<ten> chua co bo nao) ---
:lam_ban_mod
set "BM_PACK=!PACK_%1!"
set "BM_OUT=%LV%\ban-mod-%1.zip"
set "BM_DIR=%KIT%xoi-!TEN_%1!"
set "BM_NAO=%LV%\nao-goi-%1.txt"
set "BM_P=%1"
del /q "%BM_OUT%" 2>nul
del /q "%BM_NAO%" 2>nul
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; Add-Type -AssemblyName System.IO.Compression; Add-Type -AssemblyName System.IO.Compression.FileSystem; Copy-Item -LiteralPath $env:BM_PACK -Destination $env:BM_OUT -Force; $z=[System.IO.Compression.ZipFile]::Open($env:BM_OUT,'Update'); try { $e=$z.Entries | Where-Object { $_.FullName -imatch '(^|[\\/])data[\\/]data\.txt$' } | Sort-Object { $_.FullName.Length } | Select-Object -First 1; if (-not $e) { throw 'zip khong co data/data.txt' }; $root=$e.FullName.Substring(0, $e.FullName.Length - 13); $what=@(); $kitbrain=Join-Path $env:BM_DIR 'brain.txt'; foreach ($old in @($z.Entries | Where-Object { $_.FullName -ieq ($root + 'xoi/brain.txt') })) { if (-not (Test-Path -LiteralPath $kitbrain) -and -not (Test-Path -LiteralPath $env:BM_NAO)) { [System.IO.Compression.ZipFileExtensions]::ExtractToFile($old, $env:BM_NAO, $true); $what += 'bo nao trong goi: lay lam bo nao bat dau' } else { $what += 'bo nao trong goi: bo ra' }; $old.Delete() }; foreach ($f in @(@('tune.txt', 'bo so'), @('notes.txt', 'bo nho'))) { $src=Join-Path $env:BM_DIR $f[0]; if (Test-Path -LiteralPath $src) { $name=$root + 'xoi/' + $f[0]; foreach ($old in @($z.Entries | Where-Object { $_.FullName -ieq $name })) { $old.Delete() }; [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($z, $src, $name); $what += ($f[1] + ' cua xoi-<ten>') } elseif (@($z.Entries | Where-Object { $_.FullName -ieq ($root + 'xoi/' + $f[0]) }).Count -gt 0) { $what += ($f[1] + ' trong goi') } }; if ($what.Count -eq 0) { $what += 'khong co bo so, bo nho, bo nao' }; Write-Host ('  Ban mod ' + $env:BM_P + ': ' + ($what -join ', ')) } finally { $z.Dispose() }"
if not exist "%BM_OUT%" (echo [LOI] Khong lam duoc ban lam viec cua ban mod %1 ^("%BM_PACK%"^) - file zip co mo duoc khong?& set "BM_LOI=1")
exit /b 0
rem --- So giay tu nua dem theo dong ho vao bien %1 ---
:giay
set "T_=%TIME: =0%"
set /a "%1=(1%T_:~0,2%-100)*3600+(1%T_:~3,2%-100)*60+(1%T_:~6,2%-100)" 2>nul
exit /b 0
:ban_bench
pushd "%BENCH%"
copy /y *.lua "%~1\" >nul
copy /y package.manifest "%~1\" >nul
popd
exit /b 0
rem --- Cho moi tien trinh p1..pN trong %1 xong: dong %2 trong out.txt, hoac xong.txt (game tat, ke ca khi loi) ---
rem (THU_WINE: chi dung dong cuoi - khi thu file nay bang Wine, cmd khong cho game chay xong.)
:cho
set /a CHO=0
call :giay CHO_TU
:cho_tiep
ping -n 6 127.0.0.1 >nul 2>&1
set /a XONG=0
for /L %%k in (1,1,%N%) do (
  set "X="
  if exist "%~1\p%%k\out.txt" findstr /c:"%~2" "%~1\p%%k\out.txt" >nul 2>&1 && set "X=1"
  if not defined THU_WINE if exist "%~1\p%%k\xong.txt" set "X=1"
  if defined X set /a XONG+=1
)
if !XONG! GEQ %N% exit /b 0
set /a CHO+=5
set /a PHUT=CHO%%60
if !PHUT! EQU 0 (
  call :giay BAY_GIO
  set /a "M_=((BAY_GIO-CHO_TU+86400) %% 86400)/60"
  echo   ... !XONG!/%N% tien trinh xong, da cho !M_! phut ^(!TIME:~0,8!^)
  if not defined KHONG_TASKLIST (
    tasklist /FI "IMAGENAME eq openlf2.exe" 2>nul | find /I "openlf2.exe" >nul || (echo   [CHU Y] Khong con game nao chay - bo qua cac tien trinh chua xong.& exit /b 0)
  )
)
goto cho_tiep
rem --- Cho cac tien trinh huan luyen hoc1..hocN trong %1 xong (dong XOI_BRAIN b2, hoac xong.txt) ---
:cho_hoc
set /a CHO=0
call :giay CHO_TU
:cho_hoc_tiep
ping -n 6 127.0.0.1 >nul 2>&1
set /a XONG=0
for /L %%p in (1,1,%N%) do (
  set "X="
  if exist "%~1\hoc%%p\out.txt" findstr /b /c:"XOI_BRAIN b2" "%~1\hoc%%p\out.txt" >nul 2>&1 && set "X=1"
  if not defined THU_WINE if exist "%~1\hoc%%p\xong.txt" set "X=1"
  if defined X set /a XONG+=1
)
if !XONG! GEQ %N% exit /b 0
set /a CHO+=5
set /a PHUT=CHO%%60
if !PHUT! EQU 0 (
  call :giay BAY_GIO
  set /a "M_=((BAY_GIO-CHO_TU+86400) %% 86400)/60"
  echo   ... huan luyen: !XONG!/%N% xong, da cho !M_! phut ^(!TIME:~0,8!^)
  if not defined KHONG_TASKLIST (
    tasklist /FI "IMAGENAME eq openlf2.exe" 2>nul | find /I "openlf2.exe" >nul || (echo   [CHU Y] Khong con game nao chay - bo qua.& exit /b 0)
  )
)
goto cho_hoc_tiep

rem --- Mot tien trinh: game chay ngam; %2 thu muc (luot-N, kiem-tra, hay luot-N\hoc), %3 so tien trinh, %4 hat giong,
rem %5 so thu tu ban mod, %6 "hoc" = huan luyen (goi du lieu cua ban mod ay lam ban mod); xong thi dong cua so ---
:chay1
if /i "%~6"=="hoc" (
  set "DIR=%LV%\%~2%~3"
  set "P=!DIR!\du-lieu.zip"
) else (
  set "DIR=%LV%\%~2\p%~3"
  set "P=%LV%\ban-mod-%~5.zip"
)
"%GAME_DA_CHON%" --pack "!P!" %XS_DA_CHON% --mod "!DIR!" --seed %~4 --input-trace "" >"!DIR!\out.txt" 2>&1
>"!DIR!\xong.txt" echo xong
exit
