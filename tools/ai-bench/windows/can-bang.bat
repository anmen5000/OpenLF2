@echo off
setlocal EnableDelayedExpansion
rem CAN BANG - do ti le thang cua tung nhan vat cua mot ban mod truoc moi nhan vat khac, va chieu nao cua no gay sat
rem thuong (OpenLF2 goi 77 tro len). Mot may choi ca hai ben (XOI, mac dinh); moi cap nhan vat danh ca hai ben san,
rem cung san, cung diem xuat phat cua day so ngau nhien, lap di lap lai tren moi luong CPU. Ket qua: thu muc
rem can-bang-<ten ban mod>\ canh file nay (may khac XOI: can-bang-<ten ban mod>-<may>\): bao-cao.html (mo bang trinh duyet: xep hang co khoang sai so, bang doi dau,
rem tung chieu cua tung nhan vat - dung bao nhieu, trung bao nhieu, gay bao nhieu, bi danh tra bao nhieu) va
rem ket-qua.txt (tom tat). Bao cao chi ghi so do duoc; chinh nhan vat the nao la viec cua nguoi lam mod.
rem Tam dung: dong cua so nay (cac game chay ngam tu dung theo), hay dat GIO_CHAY, hay tat may. Lam tiep: chay lai file
rem nay - cac vong da xong duoc giu, va ca phan da danh cua vong dang do.
rem Do them sau khi xong: tang TONG_VAN (hay TONG_GIO) roi chay lai - cac van them cong don vao ket qua.
rem Do lai tu dau (vi du sau khi sua nhan vat): xoa hay doi ten thu muc can-bang-<ten ban mod>.
rem ============ CHINH O DAY ============
rem Game da cai. De trong thi tu tim (Install for me only, all users, hoac thu muc OpenLF2 canh file nay).
set "GAME="
rem File zip ban mod. De trong: file .zip ban mod canh file nay, neu chi co mot (bo qua *-xoi-truoc.zip, goi
rem lf2-online-upload, xoi-kit, balance-kit); keo tha mot file zip vao file nay thi do ban mod ay. Ban <ten>-xoi.zip
rem (co thang so, bo nao, bo nho XOI cua ban mod ay - tu bo XOI) cung do duoc, va nen dung: XOI choi manh hon.
set "PACK="
rem Nhan vat: all = moi nhan vat nguoi choi chon duoc; hoac danh sach id hay ten, vi du: 8 25 Crimson Deep
rem (ten nhu trong game, hoa thuong deu duoc).
set "NHAN_VAT=all"
rem Bo bot nhan vat (id hay ten), vi du bao tap hay boss: Dummy 40
set "BO_NHAN_VAT="
rem May choi ca hai ben (de trong = xoi): xoi (XOI; khong can file gi them - ban mod chua co thang so, bo nao, bo nho
rem XOI thi XOI choi bang so mac dinh, co thi dung ca nhung thu do), smart (INSANE!), classic (may goc; nhan vat co script
rem AI rieng cua ban mod - file ai\<id>.as, nhu AI cua Sauce - thi may goc choi bang script do). Do ca ba roi so voi
rem nhau: mot nhan vat manh voi moi may thi gan nhu chac la manh that.
set "NAO=xoi"
rem Bao nhieu: tong so van (TONG_VAN, vi du 200000), hoac tong so gio (TONG_GIO, dung khi TONG_VAN de trong; 7,5 = 7 gio
rem ruoi). Chia lam VONG vong: het moi vong bao cao duoc cap nhat (mo xem duoc ngay giua chung). De trong VONG: tu chia,
rem moi vong tu 10 phut toi 1 gio (theo TONG_GIO: thuong la 10 vong; 20 gio thanh 20 vong), hoac 10 vong (theo TONG_VAN).
rem Vi du: 21 nhan vat (210 cap), sai so khoang +-1%% cho moi nhan vat: chung 100000 van; +-3%% cho moi o cua bang doi
rem dau: chung 230000 van. Toc do tuy ban mod va may (mot luong CPU: tu vai tram toi chung 9000 van mot gio); het moi
rem vong file nay bao so van mot gio, de tinh TONG_VAN hay TONG_GIO cho lan sau.
set "VONG="
set "TONG_VAN="
set "TONG_GIO=2"
rem Vu khi roi tu troi: 0 = tat (chi do nhan vat va nhung gi no tu tao ra), 1 = bat
set "VU_KHI=0"
rem Mot van toi da PHUT_VAN phut; GIAY_DUNG_IM giay lien khong ai mat mau thi dung, tinh hoa
set "PHUT_VAN=5"
set "GIAY_DUNG_IM=60"
rem So tien trinh chay cung luc (moi luong CPU mot tien trinh)
set "SONG_SONG=%NUMBER_OF_PROCESSORS%"
rem Hen gio tam dung (GIO_CHAY): chay chung ay gio roi tu dung, vi du 8, hay 7,5 = 7 gio ruoi (de trong: chay den het).
rem Het gio, cac tien trinh dang danh dung ngay, giu phan da danh; chay lai file nay la lam tiep tu cho do.
set "GIO_CHAY="
rem Muc uu tien cua cac tien trinh: BELOWNORMAL (ban van dung may muot trong luc chay), LOW, hoac NORMAL
set "UU_TIEN=BELOWNORMAL"
rem Hat giong dau (cung hat giong, cung cai dat thi danh lai y het)
set "HAT_GIONG=5000"
rem Thu muc tools\ai-bench va scripts cua goi (de trong thi tu tim canh file .bat nay)
set "BENCH="
set "SCRIPTS="
rem =====================================
rem Cai dat rieng cua ban, giu qua cac lan cap nhat bo XOI: file can-bang-cai-dat.bat canh file nay (tu tao), moi dong
rem mot cai dat nhu tren, vi du  set "TONG_VAN=200000"
if exist "%~dp0can-bang-cai-dat.bat" (
  call "%~dp0can-bang-cai-dat.bat"
  if /i not "%~1"=="chay1" echo Cai dat rieng: can-bang-cai-dat.bat
)

rem (File nay tu goi lai chinh no cho tung tien trinh, trong cua so rieng: cmd /c call "<file nay>" chay1 <vong-N>
rem <so tien trinh> <hat giong>; ban mod o PACK_1, thu muc ket qua o LV - tu cua so chinh. Xem spsa.bat.)
if /i "%~1"=="chay1" goto chay1

set "SELF=%~f0"
set "KIT=%~dp0"
rem --- Ban mod: keo tha, dong PACK, hoac file zip ban mod duy nhat canh file nay ---
set "PACK_1="
if not "%~1"=="" if /i "%~x1"==".zip" if exist "%~f1" set "PACK_1=%~f1"
if not defined PACK_1 if defined PACK set "PACK_1=%PACK%"
set /a NP=0
set "CAC_ZIP="
if not defined PACK_1 (
  pushd "%~dp0"
  for %%z in (*.zip) do (
    set "TEN=%%~nz"
    set "BO="
    if /i "!TEN:~-10!"=="-xoi-truoc" set "BO=1"
    if /i "!TEN:~0,17!"=="lf2-online-upload" set "BO=1"
    if /i "!TEN:~0,7!"=="xoi-kit" set "BO=1"
    if /i "!TEN:~0,11!"=="balance-kit" set "BO=1"
    if not defined BO (
      set /a NP+=1
      set "UNG_!NP!=%%~fz"
      set "CAC_ZIP=!CAC_ZIP! "%%~nxz""
    )
  )
  popd
)
if not defined PACK_1 if !NP! EQU 1 set "PACK_1=!UNG_1!"
if not defined PACK_1 if !NP! GTR 1 (
  echo Co !NP! file zip ban mod canh file nay - do ban nao? Keo tha mot file zip vao file nay, hoac dat dong PACK:
  echo  !CAC_ZIP!
  if "%KHONG_DUNG%"=="" pause
  exit /b 1
)
if not defined PACK_1 (echo Khong thay file zip ban mod: dat file zip ban mod canh file nay, keo tha no vao file nay, hoac sua dong PACK o dau file.& pause& exit /b 1)
if not exist "%PACK_1%" (echo Khong thay ban mod "%PACK_1%" - sua dong PACK o dau file.& pause& exit /b 1)
for %%z in ("%PACK_1%") do set "TEN_MOD=%%~nz"
rem (Moi may mot thu muc ket qua: can-bang-<ten ban mod> cho XOI, can-bang-<ten ban mod>-smart, -classic cho may khac.)
if not defined NAO set "NAO=xoi"
set "LV=%~dp0can-bang-%TEN_MOD%"
if /i not "%NAO%"=="xoi" set "LV=%~dp0can-bang-%TEN_MOD%-%NAO%"

rem --- Game, bo chay thu, scripts ---
if not defined GAME (
  for %%g in ("%LOCALAPPDATA%\Programs\OpenLF2\openlf2.exe" "%ProgramFiles(x86)%\OpenLF2\openlf2.exe" "%ProgramFiles%\OpenLF2\openlf2.exe" "%~dp0OpenLF2\openlf2.exe") do (
    if not defined GAME if exist "%%~g" set "GAME=%%~g"
  )
)
if not defined GAME set "GAME=%LOCALAPPDATA%\Programs\OpenLF2\openlf2.exe"
if not defined BENCH (
  if exist "%~dp0tools\ai-bench\balance.lua" set "BENCH=%~dp0tools\ai-bench"
  if exist "%~dp0balance.lua" set "BENCH=%~dp0."
  if exist "%~dp0..\balance.lua" set "BENCH=%~dp0.."
)
if not defined SCRIPTS (
  if exist "%~dp0scripts\base\game\smart_ai.lua" set "SCRIPTS=%~dp0scripts"
  if exist "%~dp0..\..\..\scripts\base\game\smart_ai.lua" set "SCRIPTS=%~dp0..\..\..\scripts"
)
if not exist "%GAME%" (echo Khong thay game "%GAME%": cai OpenLF2 ^(bo cai OpenLF2-Windows-x64.exe o muc Releases cua trang GitHub cua du an, chon Install for me only^), hoac sua dong GAME o dau file.& pause& exit /b 1)
if not defined BENCH (echo Khong thay thu muc tools\ai-bench co balance.lua - can bo XOI goi 77 tro len.& pause& exit /b 1)
if not exist "%BENCH%\balance.lua" (echo Khong thay "%BENCH%\balance.lua" - can bo XOI goi 77 tro len.& pause& exit /b 1)
if not exist "%BENCH%\balance-report-head.html" (echo Khong thay "%BENCH%\balance-report-head.html" - can bo XOI goi 77 tro len.& pause& exit /b 1)
if not defined SCRIPTS (echo Khong thay thu muc scripts canh file nay - can bo XOI goi 77 tro len.& pause& exit /b 1)
findstr /c:"battle.on_damage" "%SCRIPTS%\base\game\battle.lua" >nul 2>nul || (echo "%SCRIPTS%\base\game\battle.lua" chua dem duoc sat thuong tung chieu - can bo XOI goi 77 tro len.& pause& exit /b 1)
set /a N=SONG_SONG
if %N% LSS 1 set /a N=1
rem Bo nho: mot tien trinh dung toi khoang 0,6 GB. SONG_SONG de mac dinh ma may it RAM thi bot so tien trinh, chua lai
rem khoang 4 GB cho Windows. Dat SONG_SONG khac so luong CPU thi giu dung so ay.
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

rem --- Cai dat cua phep do, cho config cua game ---
rem (Moi id hay ten trong [==[ ]==]: tools\ai-bench\names.lua doi ten ra id.)
set "IDS_LUA="all""
if /i not "%NHAN_VAT%"=="all" if defined NHAN_VAT (
  set "IDS_LUA="
  for %%i in (%NHAN_VAT%) do if defined IDS_LUA (set "IDS_LUA=!IDS_LUA!, [==[%%~i]==]") else (set "IDS_LUA=[==[%%~i]==]")
  set "IDS_LUA={!IDS_LUA!}"
)
set "BO_LUA="
if defined BO_NHAN_VAT for %%i in (%BO_NHAN_VAT%) do if defined BO_LUA (set "BO_LUA=!BO_LUA!, [==[%%~i]==]") else (set "BO_LUA=[==[%%~i]==]")
set "BO_LUA={!BO_LUA!}"
set "VK=false"
if "%VU_KHI%"=="1" set "VK=true"
set /a GIOI=PHUT_VAN*1800, DUNG=GIAY_DUNG_IM*30
if !GIOI! LSS 900 set /a GIOI=900
set CFG_CHUNG=ids = !IDS_LUA!, exclude = !BO_LUA!, brain = "%NAO%", weapons = !VK!, limit = !GIOI!, stall = !DUNG!
rem Tong so van hay tong so gio (TONG_GIAY, giay).
set "CHE_DO=gio"
set /a TONG_V=0, TONG_GIAY=0
if defined TONG_VAN set /a TONG_V=TONG_VAN 2>nul
if !TONG_V! GTR 0 set "CHE_DO=van"
if "!CHE_DO!"=="gio" (
  set "TG_H="
  set "TG_T="
  if defined TONG_GIO for /f "tokens=1,2 delims=.," %%a in ("%TONG_GIO%") do (
    set "TG_H=%%a"
    set "TG_T=%%b"
  )
  if not defined TG_H set "TG_H=0"
  if not defined TG_T set "TG_T=0"
  set "TG_T=!TG_T:~0,1!"
  set /a "TONG_GIAY=TG_H*3600+TG_T*360" 2>nul
)
rem (THU_TONG_GIAY: so giay tong cong, de thu file nay.)
if defined THU_TONG_GIAY set /a TONG_GIAY=THU_TONG_GIAY
if "!CHE_DO!"=="gio" if !TONG_GIAY! LEQ 0 (echo Dat TONG_VAN ^(so van^) hay TONG_GIO ^(so gio^) o dau file.& pause& exit /b 1)
rem VONG de trong: chung 10 vong, moi vong tu 10 phut toi 1 gio (theo TONG_GIO), hoac 10 vong (theo TONG_VAN).
set /a VONG_N=0
if defined VONG set /a VONG_N=VONG 2>nul
if !VONG_N! LSS 1 (
  set /a VONG_N=10
  if "!CHE_DO!"=="gio" (
    set /a "DAI_V=TONG_GIAY/10"
    if !DAI_V! LSS 600 set /a DAI_V=600
    if !DAI_V! GTR 3600 set /a DAI_V=3600
    set /a "VONG_N=(TONG_GIAY+DAI_V-1)/DAI_V"
  )
)
if !VONG_N! LSS 1 set /a VONG_N=1
if not defined UU_TIEN set "UU_TIEN=NORMAL"
set "KIT_VER="
if exist "%~dp0version.txt" set /p KIT_VER=<"%~dp0version.txt"

if not exist "%LV%" mkdir "%LV%"
rem Cai dat cua phep do giu nguyen tu dau den cuoi: nhan vat, may, vu khi, luat van. Doi thi do lai trong thu muc khac.
set "KY=NHAN_VAT=%NHAN_VAT% / BO_NHAN_VAT=%BO_NHAN_VAT% / NAO=%NAO% / VU_KHI=%VU_KHI% / PHUT_VAN=%PHUT_VAN% / GIAY_DUNG_IM=%GIAY_DUNG_IM%"
if exist "%LV%\cai-dat-do.txt" (
  set "KY_CU="
  set /p KY_CU=<"%LV%\cai-dat-do.txt"
  if not "!KY_CU!"=="!KY!" (
    echo [CHU Y] Thu muc "%LV%" da do voi cai dat khac:
    echo   truoc: !KY_CU!
    echo   nay:   !KY!
    echo Gop hai cai dat vao mot bao cao thi so lieu lan lon. Dat lai nhu truoc, hoac xoa hay doi ten thu muc ay de do lai.
    if "%KHONG_DUNG%"=="" pause
    exit /b 1
  )
) else (
  >"%LV%\cai-dat-do.txt" echo !KY!
)
rem Scripts cua game da cai, cap nhat bang scripts cua goi: lam mot lan cho ca phep do (cung mot AI tu dau den cuoi).
if not exist "%LV%\scripts\base\game\smart_ai.lua" (
  for %%g in ("%GAME%") do set "CAI=%%~dpgscripts"
  if exist "!CAI!\base\game\match.lua" xcopy /e /i /q /y "!CAI!" "%LV%\scripts" >nul
  xcopy /e /i /q /y "%SCRIPTS%" "%LV%\scripts" >nul
)
if not exist "%LV%\scripts\base\game\match.lua" (echo [LOI] Khong ghep duoc scripts vao "%LV%\scripts".& pause& exit /b 1)
if exist "%SCRIPTS%\runtime\bootstrap.lua" copy /y "%SCRIPTS%\runtime\bootstrap.lua" "%LV%\scripts\runtime\bootstrap.lua" >nul 2>nul
set XS=--scripts "%LV%\scripts"

rem --- Danh sach nhan vat (game doc ban mod, chon nhan vat, bao ten nao khong co) ---
set "DS=%LV%\danh-sach"
if exist "%DS%" rmdir /s /q "%DS%"
mkdir "%DS%"
call :ban_bench "%DS%"
>"%DS%\config.lua" echo return {command = "balance", step = "list", %CFG_CHUNG%}
"%GAME%" --pack "%PACK_1%" %XS% --mod "%DS%" --seed 1 --input-trace "" >"%DS%\out.txt" 2>&1
call :cho_dong "%DS%\out.txt" "BAL_COUNT"
findstr /c:"BENCH ERROR" "%DS%\out.txt" >nul 2>nul && (
  echo [LOI] Game bao loi khi doc ban mod hay danh sach nhan vat:
  findstr /c:"BENCH ERROR" "%DS%\out.txt"
  if "%KHONG_DUNG%"=="" pause
  exit /b 1
)
set /a SO_NV=0, SO_CAP=0
for /f "tokens=2,3" %%a in ('findstr /b /c:"BAL_COUNT " "%DS%\out.txt"') do set /a SO_NV=%%a, SO_CAP=%%b
if !SO_NV! LSS 2 (echo [LOI] Can it nhat hai nhan vat - xem "%DS%\out.txt".& pause& exit /b 1)
findstr /b /c:"BAL_FIGHTER " "%DS%\out.txt" >"%LV%\nhan-vat.txt"

echo Ban mod: "%PACK_1%"
echo %SO_NV% nhan vat, %SO_CAP% cap ^(danh sach: "%LV%\nhan-vat.txt"^); may choi ca hai ben: %NAO%
for /f "tokens=1,*" %%a in ('findstr /b /c:"BAL_LEFT_OUT " "%DS%\out.txt"') do echo   bo qua: %%b
if "!CHE_DO!"=="van" (echo Ke hoach: %TONG_V% van, chia %VONG_N% vong, %N% tien trinh ^(uu tien %UU_TIEN%^)) else (echo Ke hoach: %TONG_GIO% gio, chia %VONG_N% vong, %N% tien trinh ^(uu tien %UU_TIEN%^))
echo Ket qua vao "%LV%" ^(bao-cao.html, ket-qua.txt - cap nhat sau moi vong^)
echo Tam dung: dong cua so nay ^(cac game chay ngam tu dung theo^). Chay lai file nay la lam tiep, ke ca vong dang do.
echo De may chay qua dem: tat che do ngu cua Windows ^(Settings - System - Power - Sleep: Never^).
rem Hen gio (GIO_CHAY): so giay chay toi da (GIOI_HAN; 0 = khong hen), dem tu luc nay.
set /a GIOI_HAN=0, DA_CHAY=0
set "HET_GIO="
set "GC_H="
set "GC_T="
if defined GIO_CHAY for /f "tokens=1,2 delims=.," %%a in ("%GIO_CHAY%") do (
  set "GC_H=%%a"
  set "GC_T=%%b"
)
if defined GC_H (
  if not defined GC_T set "GC_T=0"
  set "GC_T=!GC_T:~0,1!"
  set /a "GIOI_HAN=GC_H*3600+GC_T*360" 2>nul
)
rem (THU_GIOI_HAN: so giay, de thu file nay.)
if defined THU_GIOI_HAN set /a GIOI_HAN=THU_GIOI_HAN
if !GIOI_HAN! GTR 0 echo Hen gio: chay %GIO_CHAY% gio roi tam dung ^(GIO_CHAY^).
call :giay CHAY_LUC
rem Canh cua so: mot PowerShell an cho cua so nay dong - ke ca khi bam X giua chung - roi dung moi game cua thu muc nay.
rem Xong viec (het cac vong, het gio, bao loi) thi file nay ghi canh-xong.txt va no thoi canh.
set "CANH=%LV%\"
set "CANH_XONG=%LV%\canh-xong.txt"
del /q "%CANH_XONG%" 2>nul
if not defined THU_WINE start "Can bang - canh cua so" /MIN powershell -NoProfile -WindowStyle Hidden -Command "$c = (Get-CimInstance Win32_Process -Filter ('ProcessId=' + $PID)).ParentProcessId; if (-not $c) { exit }; while (Get-Process -Id $c -ErrorAction SilentlyContinue) { if (Test-Path -LiteralPath $env:CANH_XONG) { exit }; Start-Sleep -Seconds 3 }; Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'openlf2.exe' -and $_.CommandLine -and $_.CommandLine.Contains($env:CANH) } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }"

set "GAME_DA_CHON=%GAME%"
set XS_DA_CHON=%XS%
rem Cac vong da xong: tong cua chung o vong-N\tong.txt, so van va so giay da danh o vong-N\xong.txt.
set /a E=1, DONE_VAN=0, DONE_GIAY=0
set "TRUOC_TONG="
:xet_vong
set "D=%LV%\vong-%E%"
if exist "%D%\xong.txt" (
  findstr /c:"--BAL_TONG" "%D%\tong.txt" >nul 2>nul && (
    for /f "usebackq tokens=1,2" %%a in ("%D%\xong.txt") do set /a DONE_VAN=%%a, DONE_GIAY=%%b
    set "TRUOC_TONG=%D%\tong.txt"
    set /a E+=1
    goto xet_vong
  )
  echo File tong cua vong %E% hong ^(may tat giua luc ghi?^): gop lai vong %E%.
  del /q "%D%\xong.txt" 2>nul
)
if %E% GTR 1 echo Da xong %DONE_VAN% van trong cac vong truoc.

:vong_tiep
rem Con bao nhieu: so van hay so giay, chia deu cho cac vong con lai. Da het VONG vong ma con (tang TONG_VAN hay
rem TONG_GIO sau khi xong): phan them chia thanh vong co co nhu vong cu.
if "!CHE_DO!"=="van" (set /a CON=TONG_V-DONE_VAN, TONG_KH=TONG_V) else (set /a CON=TONG_GIAY-DONE_GIAY, TONG_KH=TONG_GIAY)
if "!CHE_DO!"=="van" if !CON! LEQ 0 goto xong
if "!CHE_DO!"=="gio" if !CON! LSS 30 goto xong
set /a CON_VONG=VONG_N-E+1
if !CON_VONG! LSS 1 set /a "CON_VONG=(CON*VONG_N+TONG_KH-1)/TONG_KH"
if !CON_VONG! LSS 1 set /a CON_VONG=1
set /a "MOI=(CON+CON_VONG-1)/CON_VONG"
if "!CHE_DO!"=="van" (
  set /a "MOI_P=(MOI+N-1)/N"
  set /a "MOI_P=(MOI_P+1)/2*2"
  if !MOI_P! LSS 2 set /a MOI_P=2
  set "NGAN_SACH=games = !MOI_P!"
  set /a SNAP=300
  set "MO_TA=!MOI! van, !MOI_P! van moi tien trinh"
) else (
  if !MOI! LSS 60 set /a MOI=60
  set "NGAN_SACH=seconds = !MOI!"
  set /a "SNAP=MOI/6"
  if !SNAP! LSS 60 set /a SNAP=60
  if !SNAP! GTR 600 set /a SNAP=600
  set /a "MOI_PH=(MOI+59)/60"
  set "MO_TA=!MOI_PH! phut"
)
rem (THU_SNAP: so giay giua hai lan chup, de thu file nay.)
if defined THU_SNAP set /a SNAP=THU_SNAP
if !GIOI_HAN! GTR 0 (
  call :dong_ho
  if !DA_CHAY! GEQ !GIOI_HAN! goto het_gio
)
call :mot_vong
if defined HET_GIO goto het_gio
if errorlevel 1 goto loi
set /a TRUOC_VAN=DONE_VAN
for /f "usebackq tokens=1,2" %%a in ("%D%\xong.txt") do set /a DONE_VAN=%%a, DONE_GIAY=%%b
if !DONE_VAN! LEQ !TRUOC_VAN! (echo [LOI] Vong %E% khong danh duoc van nao - xem "%D%\p1\nhat-ky.txt".& goto loi)
set "TRUOC_TONG=%D%\tong.txt"
set /a E+=1
set "D=%LV%\vong-%E%"
goto vong_tiep

:mot_vong
echo.
echo === Vong %E%: %N% tien trinh, !MO_TA! ^(%TIME:~0,8%^) ===
call :giay BAT_DAU
set "GHI_CHU="
rem Cac tien trinh cua vong nay da danh xong lan truoc (co dong BAL_END) ma chua gop: chi gop lai.
if exist "%D%" (
  set /a XONG_N=0, CHUA_N=0
  pushd "%D%"
  for /d %%p in (p*) do if exist "%%p\out.txt" (
    set "XONG_P="
    findstr /b /c:"BAL_END " "%%p\out.txt" >nul 2>nul && set "XONG_P=1"
    if defined XONG_P (set /a XONG_N+=1) else set /a CHUA_N+=1
  )
  popd
  if !XONG_N! GEQ 1 if !CHUA_N! EQU 0 (
    echo   ^(cac tien trinh da danh xong lan truoc: chi gop lai^)
    set "GHI_CHU= - chi gop lai"
    goto gop_vong
  )
)
rem Vong nay da chay do lan truoc (dong cua so, tat may, het gio): giu phan da danh trong truoc\<lan>, gop chung o
rem cuoi vong. (Mau tim tep: pushd vao thu muc roi dung duong dan tuong doi - xem spsa.bat.)
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
rem Phan da danh o cac lan truoc cua vong nay (truoc\<lan>\p<k>.txt, lan chup cuoi cua moi tien trinh): so van cong lai,
rem so giay la tien trinh chay lau nhat cua moi lan, cong lai. Lan nay chi danh phan con thieu cua vong.
set /a DA_V=0, DA_G=0
if exist "%D%\truoc" (
  pushd "%D%\truoc"
  for /d %%l in (*) do (
    set /a LAU=0
    pushd "%%l"
    for %%f in (p*.txt) do (
      set "SV="
      set "SG="
      for /f "tokens=3,4" %%a in ('findstr /b /c:"BAL_SNAP " "%%~ff" 2^>nul') do (
        set "SV=%%a"
        set "SG=%%b"
      )
      if defined SV set /a DA_V+=SV
      if defined SG if !SG! GTR !LAU! set /a LAU=SG
    )
    popd
    set /a DA_G+=LAU
  )
  popd
)
if !DA_V! GTR 0 (
  if "!CHE_DO!"=="van" (
    set /a "MOI_P=(MOI-DA_V+N-1)/N"
    set /a "MOI_P=(MOI_P+1)/2*2"
    if !MOI_P! LSS 2 set /a MOI_P=2
    set "NGAN_SACH=games = !MOI_P!"
  ) else (
    set /a "MOI_G=MOI-DA_G"
    if !MOI_G! LSS 60 set /a MOI_G=60
    set "NGAN_SACH=seconds = !MOI_G!"
  )
  echo   ^(lan truoc da danh !DA_V! van cua vong nay; lan nay: !NGAN_SACH!^)
)
if not exist "%D%" mkdir "%D%"
for /L %%k in (1,1,%N%) do (
  mkdir "%D%\p%%k" 2>nul
  del /q "%D%\p%%k\xong.txt" 2>nul
  call :ban_bench "%D%\p%%k"
  set /a SEED=HAT_GIONG+E*1000+%%k+LAN*100000
  >"%D%\p%%k\config.lua" echo return {command = "balance", step = "play", %CFG_CHUNG%, !NGAN_SACH!, snap = !SNAP!, seed = !SEED!, round = %E%, process = %%k, processes = %N%}
  start "Can bang vong %E% - %%k" /MIN /%UU_TIEN% cmd /c call "%SELF%" chay1 vong-%E% %%k !SEED!
)
call :cho "%D%" "BAL_END "
if defined HET_GIO exit /b 0
:gop_vong
rem Gop: phan cuoi cung con nguyen ven cua moi tien trinh (ca cac lan truoc trong truoc\), cong vao tong cac vong truoc.
rem (Game doc chung nhu file kem theo goi gop - asset trong package.manifest -, moi file toi da 4 MB.)
set "M=%D%\gop"
if exist "%M%" rmdir /s /q "%M%"
mkdir "%M%"
call :ban_bench "%M%"
set "PREV_CFG="
if defined TRUOC_TONG (
  copy /y "%TRUOC_TONG%" "%M%\bal_prev.txt" >nul
  >>"%M%\package.manifest" echo asset=mods/bench/bal_prev.txt^|bal_prev.txt
  set "PREV_CFG=prev = true, "
)
set /a CO=0
set "BIN_0="
pushd "%D%"
for /d %%p in (p*) do call :lay_snap "%D%\%%p\out.txt" "%M%" 0
if exist truoc (
  pushd truoc
  for /d %%l in (*) do (
    set "BIN_%%l="
    pushd "%%l"
    for %%f in (p*.txt) do call :lay_snap "%%~ff" "%M%" %%l
    popd
  )
  popd
)
popd
if !CO! EQU 0 (
  echo [LOI] Khong tien trinh nao danh duoc van nao o vong %E%:
  findstr /c:"BENCH ERROR" "%D%\p1\out.txt" 2>nul
  echo Xem "%D%\p1\out.txt".
  exit /b 1
)
set "NGAY=%DATE% %TIME:~0,5%"
>"%M%\config.lua" echo return {command = "balance", step = "merge", %CFG_CHUNG%, !PREV_CFG!lang = "vi", mod = [==[%TEN_MOD%]==], plan_rounds = %VONG_N%, plan_games = !TONG_V!, plan_seconds = !TONG_GIAY!, date = [==[!NGAY!]==], kit = [==[!KIT_VER!]==]}
"%GAME%" --pack "%PACK_1%" %XS% --mod "%M%" --seed 1 --input-trace "" >"%M%\out.txt" 2>&1
call :cho_dong "%M%\out.txt" "BAL_DONE "
findstr /c:"--BAL_TONG" "%M%\out.txt" >"%D%\tong.tmp"
for %%f in ("%D%\tong.tmp") do if %%~zf LSS 20 (
  echo [LOI] Khong gop duoc vong %E%:
  findstr /c:"BENCH ERROR" "%M%\out.txt"
  echo Xem "%M%\out.txt".
  exit /b 1
)
move /y "%D%\tong.tmp" "%D%\tong.txt" >nul
findstr /c:"//BAL_JS" "%M%\out.txt" >"%LV%\du-lieu.js"
copy /b "%BENCH%\balance-report-head.html" + "%LV%\du-lieu.js" + "%BENCH%\balance-report-tail.html" "%LV%\bao-cao.html" >nul
findstr /b /c:"| " "%M%\out.txt" >"%LV%\ket-qua.txt"
for /f "tokens=2,3,4" %%a in ('findstr /b /c:"BAL_DONE " "%M%\out.txt"') do >"%D%\xong.txt" echo %%a %%b %%c
if not exist "%D%\xong.txt" (echo [LOI] Gop vong %E% khong xong - xem "%M%\out.txt".& exit /b 1)
rem Don dep: phan danh cua cac tien trinh da vao tong (vong-N\tong.txt); giu nhat ky ngan cua moi tien trinh.
pushd "%D%"
for /d %%p in (p*) do (
  if exist "%%p\out.txt" findstr /v /b /c:"{" "%%p\out.txt" >"%%p\nhat-ky.txt" 2>nul
  del /q "%%p\out.txt" 2>nul
  del /q "%%p\*.lua" 2>nul
  del /q "%%p\package.manifest" 2>nul
)
if exist truoc rmdir /s /q truoc
popd
pushd "%M%"
del /q bal_*.txt phan.txt *.lua 2>nul
popd
call :giay XONG_LUC
set /a "PHUT_V=((XONG_LUC-BAT_DAU+86400) %% 86400)/60"
rem Toc do: so van cua vong nay tren so giay cua no (tien trinh chay lau nhat, theo dong ho cua game).
set "VAN_TONG="
set /a GIAY_TONG=0
for /f "usebackq tokens=1,2" %%a in ("%D%\xong.txt") do (
  set "VAN_TONG=%%a"
  set /a GIAY_TONG=%%b
)
set "TOC_DO="
set /a "VAN_V=VAN_TONG-DONE_VAN, GIAY_V=GIAY_TONG-DONE_GIAY"
if !GIAY_V! GEQ 60 set /a "TOC=VAN_V*60/(GIAY_V/60)"
if !GIAY_V! GEQ 60 set "TOC_DO= (chung !TOC! van mot gio)"
>>"%LV%\thoi-gian.txt" echo Vong %E%: xong luc %TIME:~0,8%, mat !PHUT_V! phut, tong !VAN_TONG! van!TOC_DO!!GHI_CHU!
echo Vong %E% xong luc %TIME:~0,8%, mat !PHUT_V! phut: tong !VAN_TONG! van!TOC_DO!. Bao cao: "%LV%\bao-cao.html"
exit /b 0

:xong
echo.
echo ===== Xong: %DONE_VAN% van. Ket qua: "%LV%\ket-qua.txt", bao cao day du: "%LV%\bao-cao.html" =====
if exist "%LV%\ket-qua.txt" type "%LV%\ket-qua.txt"
echo.
echo Mo bao-cao.html bang trinh duyet ^(Chrome, Edge, Firefox^). Do them: tang TONG_VAN hay TONG_GIO roi chay lai file nay.
if defined CANH_XONG >"%CANH_XONG%" echo xong
if not defined THU_WINE if "%KHONG_DUNG%"=="" if exist "%LV%\bao-cao.html" start "" "%LV%\bao-cao.html"
if "%KHONG_DUNG%"=="" pause
exit /b 0

:loi
echo [LOI] Dung o vong %E%. Sua loi roi chay lai file nay de lam tiep.
if defined CANH_XONG >"%CANH_XONG%" echo xong
if "%KHONG_DUNG%"=="" pause
exit /b 1

rem Het gio (GIO_CHAY): cac game da dung, phan da danh cua vong dang do duoc giu - chay lai la lam tiep.
:het_gio
echo.
echo === Da chay du %GIO_CHAY% gio ^(%TIME:~0,8%^): tam dung. Chay lai file nay la lam tiep, ke ca vong dang do. ===
>>"%LV%\thoi-gian.txt" echo Tam dung luc %TIME:~0,8% sau %GIO_CHAY% gio ^(GIO_CHAY^)
if defined CANH_XONG >"%CANH_XONG%" echo xong
if "%KHONG_DUNG%"=="" pause
exit /b 0

rem --- Them phan cuoi cung con nguyen ven cua file %1 (mot tien trinh) vao thu muc gop %2, lan chay %3: cac dong cua
rem lan chup cuoi (dong BAL_SNAP <s> danh dau lan chup s da ghi xong; khong co thi bo qua), noi vao file
rem bal_<lan>_<n>.txt - moi file chung 3 MB, nhieu tien trinh ---
:lay_snap
if not exist "%~1" exit /b 0
set "SNAP_S="
for /f "tokens=2" %%s in ('findstr /b /c:"BAL_SNAP " "%~1" 2^>nul') do set "SNAP_S=%%s"
if not defined SNAP_S exit /b 0
findstr /b /c:"{!SNAP_S!," "%~1" >"%~2\phan.txt"
set /a KB_PHAN=0
for %%f in ("%~2\phan.txt") do set /a "KB_PHAN=%%~zf/1024"
if not defined BIN_%~3 set /a BIN_%~3=0, KB_%~3=99999
set /a "THU=KB_%~3+KB_PHAN"
if !THU! GTR 3000 (
  set /a BIN_%~3+=1
  set /a KB_%~3=0
  >>"%~2\package.manifest" echo asset=mods/bench/bal_%~3_!BIN_%~3!.txt^|bal_%~3_!BIN_%~3!.txt
)
type "%~2\phan.txt" >>"%~2\bal_%~3_!BIN_%~3!.txt"
set /a KB_%~3+=KB_PHAN
set /a CO+=1
exit /b 0

rem --- So giay tu nua dem theo dong ho vao bien %1 (%TIME% la gio:phut:giay; gio duoi 10 co dau cach o dau) ---
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
  if exist "%~1\p%%k\out.txt" findstr /b /c:"%~2" "%~1\p%%k\out.txt" >nul 2>&1 && set "Y=1"
  if defined Y set "X=1"
  if not defined THU_WINE if exist "%~1\p%%k\xong.txt" set "X=1"
  if defined X set /a XONG+=1
  if defined Y set /a TOT+=1
)
if !XONG! GEQ %N% exit /b 0
rem Het gio (GIO_CHAY): dung moi game cua thu muc nay, giu phan da danh (lan chup cuoi cua moi tien trinh).
if !GIOI_HAN! GTR 0 (
  call :dong_ho
  if !DA_CHAY! GEQ !GIOI_HAN! (
    set "HET_GIO=1"
    call :dung_het "%~1"
    exit /b 0
  )
)
set /a CHO+=5
rem Mot nua so tien trinh xong thi dat nhip: tien trinh nao con chay qua 2 lan nhip ay, va qua it nhat 5 phut (DOI_THEM
rem giay) sau nhip, coi nhu bi treo - dung no va lam tiep voi cac tien trinh da xong (phan no da danh van duoc gop).
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

rem --- Dung moi game cua thu muc %1 (het gio: GIO_CHAY) ---
:dung_het
set "TREO=%~1\"
powershell -NoProfile -Command "Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'openlf2.exe' -and $_.CommandLine -and $_.CommandLine.Contains($env:TREO) } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }" >nul 2>&1
exit /b 0

rem --- Gio da chay tu luc bat dau (DA_CHAY, giay) theo dong ho, ke ca qua nua dem ---
:dong_ho
rem (THU_WINE: %TIME% cua cmd trong Wine khong co giay - moi lan goi tinh la 5 giay, mot nhip cho.)
if defined THU_WINE (set /a DA_CHAY+=5& exit /b 0)
call :giay BAY_GIO_DH
set /a "DA_CHAY+=(BAY_GIO_DH-CHAY_LUC+86400) %% 86400, CHAY_LUC=BAY_GIO_DH"
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

rem --- Mot tien trinh: game chay ngam; %2 vong-N, %3 so tien trinh, %4 hat giong (LV, GAME_DA_CHON, XS_DA_CHON,
rem PACK_1: tu cua so chinh); xong thi dong cua so ---
:chay1
set "DIR=%LV%\%~2\p%~3"
"%GAME_DA_CHON%" --pack "%PACK_1%" %XS_DA_CHON% --mod "!DIR!" --seed %~4 --input-trace "" >"!DIR!\out.txt" 2>&1
>"!DIR!\xong.txt" echo xong
exit
