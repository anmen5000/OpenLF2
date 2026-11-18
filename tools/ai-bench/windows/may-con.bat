@echo off
setlocal EnableDelayedExpansion
rem MAY CON HOC TANG CUONG (goi 90) - nhieu may cung hoc tang cuong, relay (VPS) chia viec.
rem Tren trang /hoc cua relay (https://<relay>/hoc, ma quan tri ADMIN_KEY) ban dat viec: ban mod, cac nhan vat can
rem hoc, so vong... Moi may con (da cai OpenLF2 va co bo XOI nay) chay file nay: may chia cac luong CPU thanh cac
rem "o" (moi o MOI_NV tien trinh, theo viec), moi o hoi relay mot nhan vat, hoc no bang hoc-tang-cuong.bat (ket
rem qua van o hoc-tang-cuong\<nhan vat>\ nhu thuong), gui ket qua len relay (tom-tat.txt, xac-nhan.txt, bo nao da
rem chon: khoang 1 MB) roi lay nhan vat tiep, toi khi het viec. Relay khong hoc gi, chi chuyen cac file nho.
rem May chinh: dua-bo-nao-vao-mod.bat (co may-con-cai-dat.bat canh no) tai ket qua cua moi may con ve truoc khi dua
rem bo nao vao ban mod. May chinh cung la may con duoc: chay ca file nay.
rem Tam dung: dong cac cua so. Chay lai file nay: moi o lam tiep nhan vat cua no (cac vong da xong duoc giu).
rem Ban mod (khi viec de "moi may tu co file zip ban mod"): keo tha file zip vao file nay, hay dat no canh file nay
rem (uu tien <ten>-xoi.zip), hay ghi o dong PACK.
rem Can Windows 10 ban 1803 tro len (co san curl.exe).
rem ============ CHINH O DAY ============
rem Dia chi viec va ma may con: lay file may-con-cai-dat.bat o trang /hoc cua relay (nut "Tai file
rem may-con-cai-dat.bat") va dat canh file nay - hai dong duoi se lay tu file ay.
set "HOC_HUB="
set "HOC_KEY="
rem Ten may tren trang /hoc (de trong: ten Windows cua may)
set "MAY="
rem So luong CPU dung cho viec nay (de trong: tat ca)
set "LUONG="
rem File zip ban mod khi viec de "moi may tu co file zip ban mod" (de trong: file keo tha vao file nay, PACK cua
rem hoc-tang-cuong-cai-dat.bat, khong thi file zip canh file nay - <ten>-xoi.zip truoc)
set "PACK="
rem =====================================
if exist "%~dp0may-con-cai-dat.bat" call "%~dp0may-con-cai-dat.bat"
set "KIT=%~dp0"
set "SELF=%~f0"
if not defined MAY set "MAY=%COMPUTERNAME%"
set "MAY=%MAY: =-%"
if not defined LUONG set "LUONG=%NUMBER_OF_PROCESSORS%"
set "TAM=%KIT%may-con"
if not exist "%TAM%" mkdir "%TAM%"
if /i "%~1"=="o" goto o

title May con hoc tang cuong - %MAY%
where curl.exe >nul 2>&1 || (echo [LOI] Khong co curl.exe - can Windows 10 ban 1803 tro len.& pause& exit /b 1)
if not defined HOC_HUB (echo [LOI] Chua co dia chi viec: tai file may-con-cai-dat.bat o trang /hoc cua relay va dat canh file nay.& pause& exit /b 1)
if not defined HOC_KEY (echo [LOI] Chua co ma may con: tai lai file may-con-cai-dat.bat o trang /hoc cua relay.& pause& exit /b 1)
if not exist "%KIT%hoc-tang-cuong.bat" (echo [LOI] Khong thay hoc-tang-cuong.bat canh file nay - giai nen ca bo XOI.& pause& exit /b 1)
echo May con hoc tang cuong: may %MAY%, relay %HOC_HUB%
call :hoi GET "%HOC_HUB%/api/viec" "%TAM%\viec.txt"
if errorlevel 1 (pause& exit /b 1)
call :doc "%TAM%\viec.txt"
if not defined HOC_MOI_NV set "HOC_MOI_NV=33"
set /a O=LUONG / HOC_MOI_NV
if !O! LSS 1 set /a O=1
rem --- Ban mod: cua relay (tai mot lan, kiem bang SHA-256), hay file cua may nay ---
set "HOC_PACK_FILE="
if not "%~1"=="" if /i "%~x1"==".zip" if exist "%~f1" set "PACK=%~f1"
if defined HOC_PACK_ID (
  set "HOC_PACK_FILE=%TAM%\ban-mod-!HOC_PACK_ID!.zip"
  call :ban_mod
  if errorlevel 1 (pause& exit /b 1)
) else (
  call :tim_ban_mod
  if not defined PACK (echo [LOI] Khong thay file zip ban mod: keo tha no vao may-con.bat, dat no canh may-con.bat, hay ghi o dong PACK.& pause& exit /b 1)
  set "HOC_PACK_FILE=!PACK!"
  echo Ban mod: "!PACK!"
)
echo Viec: !HOC_VONG! vong, moi nhan vat !HOC_MOI_NV! tien trinh; may nay hoc !O! nhan vat mot luc ^(!LUONG! luong^).
rem (Dung som - tu goi 97: relay cu khong gui DUNG_SOM, hoc-tang-cuong.bat dung cai dat cua no.)
if defined HOC_DUNG_SOM if not "!HOC_DUNG_SOM!"=="0" echo Dung som: nhan vat qua !HOC_DUNG_SOM! vong khong tien bo thi thoi hoc, o ay lay nhan vat ke.
for /L %%i in (1,1,!O!) do (
  start "May con %MAY% - o %%i" cmd /c call "%SELF%" o %%i
  ping -n 4 127.0.0.1 >nul 2>&1
)
echo.
echo Moi o mot cua so "May con %MAY% - o N". Xem tien do o trang /hoc cua relay. Dong cua so nay duoc.
pause
exit /b 0

rem --- Mot o: hoi relay mot nhan vat, hoc, gui ket qua, lap lai toi khi het viec ---
:o
set "SO=%~2"
set "HOC_MAY=%MAY%-o%SO%"
set /a THU=0
:o_tiep
for %%v in (NV HET LOI VONG TRAN KIEM_TRA_MOI TRAN_KIEM_TRA TRAN_XAC_NHAN MOI_NV DUNG_SOM) do set "HOC_%%v="
call :hoi POST "%HOC_HUB%/api/nhan?may=%HOC_MAY%" "%TAM%\nhan-%SO%.txt"
if errorlevel 1 (
  if defined HOC_LOI (echo [LOI] O %SO% dung lai.& pause& exit /b 1)
  set /a THU+=1
  if !THU! GEQ 120 (echo [LOI] Mat lien lac voi relay qua lau - o %SO% dung lai.& pause& exit /b 1)
  echo   Thu lai sau mot phut...
  ping -n 61 127.0.0.1 >nul 2>&1
  goto o_tiep
)
set /a THU=0
call :doc "%TAM%\nhan-%SO%.txt"
if defined HOC_HET (
  echo.
  echo === O %SO%: het viec - cac nhan vat deu da co may nhan. ===
  pause
  exit /b 0
)
if not defined HOC_NV (echo [LOI] Relay tra loi la - xem "%TAM%\nhan-%SO%.txt".& pause& exit /b 1)
set "NV=!HOC_NV!"
title May con %MAY% - o %SO% - nhan vat !NV!
echo.
echo ===== O %SO%: hoc nhan vat !NV! ^(!HOC_VONG! vong, !HOC_MOI_NV! tien trinh^) - %DATE% %TIME:~0,8% =====
call "%KIT%hoc-tang-cuong.bat" mot_nv !NV! !HOC_MOI_NV!
set "HOC_KQ=!errorlevel!"
set "LVN=%KIT%hoc-tang-cuong\!NV!"
rem (Tu goi 94: hoc-tang-cuong.bat bao loi thi khong gui gi - thu muc co the con ket qua cu cua ban mod khac.)
set "LOI_HOC="
if not "!HOC_KQ!"=="0" set "LOI_HOC=1"
if not exist "!LVN!\xac-nhan.txt" set "LOI_HOC=1"
if defined LOI_HOC (
  call :bao_loi
  pause
  exit /b 1
)
call :nop
if errorlevel 1 (
  echo   [CHU Y] Gui ket qua cua nhan vat !NV! chua duoc - thu lai sau mot phut.
  ping -n 61 127.0.0.1 >nul 2>&1
  call :nop
)
goto o_tiep

rem --- Gui ket qua: tom-tat.txt, xac-nhan.txt, tot-nhat.txt, bo nao da chon va bo nao cua lan kiem tra moi nhat ---
:nop
set "CHON="
for /f "usebackq tokens=1" %%a in ("!LVN!\xac-nhan.txt") do set "CHON=%%a"
set "MOI_NHAT=0"
for %%f in ("!LVN!\kiem-tra-*.txt") do for /f "tokens=3 delims=-." %%n in ("%%~nxf") do if %%n GTR !MOI_NHAT! set "MOI_NHAT=%%n"
set "GUI=tom-tat.txt xac-nhan.txt"
if exist "!LVN!\tot-nhat.txt" set "GUI=!GUI! tot-nhat.txt"
if defined CHON if exist "!LVN!\bo-nao-!CHON!.txt" set "GUI=!GUI! bo-nao-!CHON!.txt"
if not "!MOI_NHAT!"=="!CHON!" if exist "!LVN!\bo-nao-!MOI_NHAT!.txt" set "GUI=!GUI! bo-nao-!MOI_NHAT!.txt"
for %%g in (!GUI!) do (
  call :gui_tep "!LVN!\%%g" "%HOC_HUB%/api/nop/!NV!/%%g?may=%HOC_MAY%"
  if errorlevel 1 exit /b 1
)
call :hoi POST "%HOC_HUB%/api/xong/!NV!?may=%HOC_MAY%" "%TAM%\nop-%SO%.txt"
if errorlevel 1 exit /b 1
echo   Da gui ket qua cua nhan vat !NV! len relay.
exit /b 0

rem --- Nhan vat khong hoc xong. Chua bat dau hoc (khong co tom-tat.txt: thieu game, scripts...) la loi cua may nay:
rem tra nhan vat ve hang doi cho may khac (relay tu goi 91). Nhan vat khong co trong ban mod (loi.txt) hay hoc do
rem dang thi bao relay loi cua nhan vat (kem cuoi tom-tat.txt), de no cho o trang /hoc. ---
:bao_loi
set "TRA_XONG="
set "DUOI=%TAM%\loi-%SO%.txt"
set "TT=!LVN!\tom-tat.txt"
if not exist "!LVN!\loi.txt" if not exist "!TT!" call :tra_lai
if defined TRA_XONG exit /b 0
if exist "!LVN!\loi.txt" (
  copy /y "!LVN!\loi.txt" "!DUOI!" >nul
) else if exist "!TT!" (
  powershell -NoProfile -Command "Get-Content -LiteralPath $env:TT -Tail 15" >"!DUOI!" 2>nul
) else (
  >"!DUOI!" echo hoc-tang-cuong.bat dung truoc khi bat dau hoc - xem cua so o %SO% tren may %MAY%.
)
curl.exe -s -m 60 -X POST -H "X-Hoc-Key: %HOC_KEY%" --data-binary "@!DUOI!" "%HOC_HUB%/api/loi/!NV!?may=%HOC_MAY%" >nul 2>&1
echo.
echo [LOI] Nhan vat !NV! khong hoc xong - da bao relay ^(trang /hoc: nut Giao lai khi da sua^). O %SO% dung lai.
exit /b 0

rem --- Tra nhan vat ve hang doi (relay tu goi 91; relay cu hon thi khong duoc - bao loi nhu truoc) ---
:tra_lai
set "TRA_XONG="
del /q "%TAM%\tra-%SO%.txt" 2>nul
curl.exe -s -m 60 -X POST -H "X-Hoc-Key: %HOC_KEY%" -o "%TAM%\tra-%SO%.txt" "%HOC_HUB%/api/tra/!NV!?may=%HOC_MAY%" >nul 2>&1
findstr /b /c:"OK=1" "%TAM%\tra-%SO%.txt" >nul 2>&1 || exit /b 0
set "TRA_XONG=1"
echo.
echo [LOI] May nay chua hoc duoc - xem thong bao o tren. Nhan vat !NV! da tra ve hang doi cho may khac. O %SO% dung lai.
exit /b 0

rem --- Ban mod cua may nay: PACK (hay file keo tha vao file nay), PACK cua hoc-tang-cuong-cai-dat.bat, roi file zip
rem canh file nay (<ten>-xoi.zip truoc: ban mod co bo nho XOI) ---
:tim_ban_mod
if defined PACK if not exist "!PACK!" (echo [CHU Y] Khong thay "!PACK!".& set "PACK=")
if not defined PACK if exist "%KIT%hoc-tang-cuong-cai-dat.bat" call :pack_cai_dat
if defined PACK if not exist "!PACK!" set "PACK="
if defined PACK exit /b 0
pushd "%KIT%"
for %%z in (*-xoi.zip) do if not defined PACK set "PACK=%%~fz"
for %%z in (*.zip) do if not defined PACK (
  set "TEN=%%~nz"
  set "BO="
  if /i "!TEN:~-10!"=="-xoi-truoc" set "BO=1"
  if /i "!TEN:~0,17!"=="lf2-online-upload" set "BO=1"
  if /i "!TEN:~0,7!"=="xoi-kit" set "BO=1"
  if not defined BO set "PACK=%%~fz"
)
popd
exit /b 0

:pack_cai_dat
setlocal
set "PACK="
call "%KIT%hoc-tang-cuong-cai-dat.bat" >nul 2>&1
endlocal & set "PACK=%PACK%"
exit /b 0

rem --- Ban mod cua relay: tai ve mot lan (kiem SHA-256) ---
:ban_mod
if exist "!HOC_PACK_FILE!" (
  call :sha "!HOC_PACK_FILE!"
  if /i "!SHA!"=="!HOC_PACK_SHA256!" (echo Ban mod: "!HOC_PACK_FILE!".& exit /b 0)
)
echo Tai ban mod !HOC_PACK_ID! tu relay ^(mot lan^)...
curl.exe -s -S -f -m 7200 -H "X-Hoc-Key: %HOC_KEY%" -o "!HOC_PACK_FILE!.tmp" "%HOC_HUB%/api/ban-mod"
if errorlevel 1 (echo [LOI] Khong tai duoc ban mod tu relay.& exit /b 1)
call :sha "!HOC_PACK_FILE!.tmp"
if /i not "!SHA!"=="!HOC_PACK_SHA256!" (echo [LOI] Ban mod tai ve bi hong - chay lai file nay.& del /q "!HOC_PACK_FILE!.tmp"& exit /b 1)
move /y "!HOC_PACK_FILE!.tmp" "!HOC_PACK_FILE!" >nul
echo Ban mod: "!HOC_PACK_FILE!".
exit /b 0

:sha
set "SHA="
set "SHA_FILE=%~1"
for /f "usebackq delims=" %%h in (`powershell -NoProfile -Command "(Get-FileHash -Algorithm SHA256 -LiteralPath $env:SHA_FILE).Hash.ToLower()"`) do set "SHA=%%h"
exit /b 0

rem --- Hoi relay (tham so: GET hay POST, dia chi, file nhan tra loi); loi: thong bao cua relay o HOC_LOI ---
:hoi
set "HOC_LOI="
del /q "%~3" 2>nul
curl.exe -s -S -m 300 -X %~1 -H "X-Hoc-Key: %HOC_KEY%" -o "%~3" "%~2"
if errorlevel 1 (echo   [CHU Y] Khong noi duoc voi relay.& exit /b 1)
if not exist "%~3" exit /b 0
for /f "usebackq tokens=1,* delims==" %%a in ("%~3") do if "%%a"=="LOI" set "HOC_LOI=%%b"
if defined HOC_LOI (echo   [Relay] !HOC_LOI!& exit /b 1)
exit /b 0

rem --- Gui mot file (tham so: file, dia chi) ---
:gui_tep
set "HOC_LOI="
del /q "%TAM%\gui-%SO%.txt" 2>nul
curl.exe -s -S -m 600 -T "%~1" -H "X-Hoc-Key: %HOC_KEY%" -o "%TAM%\gui-%SO%.txt" "%~2"
if errorlevel 1 (echo   [CHU Y] Khong gui duoc %~nx1.& exit /b 1)
if not exist "%TAM%\gui-%SO%.txt" exit /b 0
for /f "usebackq tokens=1,* delims==" %%a in ("%TAM%\gui-%SO%.txt") do if "%%a"=="LOI" set "HOC_LOI=%%b"
if defined HOC_LOI (echo   [Relay] !HOC_LOI!& exit /b 1)
exit /b 0

rem --- Doc tra loi cua relay: moi dong TEN=gia tri thanh bien HOC_TEN ---
:doc
if not exist "%~1" exit /b 0
for /f "usebackq tokens=1,* delims==" %%a in ("%~1") do set "HOC_%%a=%%b"
exit /b 0
