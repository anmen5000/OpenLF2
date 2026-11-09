@echo off
setlocal EnableDelayedExpansion
rem Xuat ban mot ban mod cho nguoi choi binh thuong: thu muc goc cua ban mod nhu tac gia chia se (bg, bgm, data, sprite...,
rem ca file .exe cua no), them OpenLF2 - du cac muc may Easy, Normal, Difficult, CRAZY, INSANE, XOI. Nguoi choi chi viec
rem giai nen roi nhay dup "<ten> - INSANE XOI.exe" - khong cai OpenLF2, khong can bo XOI, khong can LF2 goc.
rem Cach dung: dat file nay canh file zip ban mod roi nhay dup - tot nhat la file <ten>-xoi.zip ma xoi-hoc.bat / spsa.bat
rem da lam (co san bo nho va bo so cua XOI). Hoac keo tha vao file nay: file zip, thu muc hay file .exe cua ban mod;
rem kem bo nho (notes.txt), bo so (tune.txt) va bo nao (brain.txt) cua XOI, hay thu muc xoi-<ten> chua chung, neu muon.
rem Ket qua: xuat-ban\<ten>.zip canh file nay - gui file nay cho nguoi choi; thu muc xuat-ban\<ten> la ban da giai nen.
rem Can OpenLF2 da cai tu goi 50 tro len (ban biet tu choi thu muc ban mod ma no nam trong) va file xuat-ban.ps1 canh
rem file nay.
rem ============ CHINH O DAY ============
rem Ten ban xuat ban: ten thu muc va file zip; file nguoi choi nhay dup la "<ten> - INSANE XOI.exe". De trong thi lay
rem ten ban mod.
set "TEN="
rem Game da cai. De trong thi tu tim (Install for me only, all users, hoac thu muc OpenLF2 canh file nay).
set "GAME="
rem Ban mod: file zip hoac thu muc. De trong thi lay file *-xoi.zip dau tien canh file nay, khong co thi file .zip dau tien.
set "PACK="
rem Bo nho XOI (notes.txt cua xoi-hoc.bat), bo so XOI (tune.txt cua spsa.bat) va bo nao XOI (brain.txt cua hoc-sau.bat).
rem De trong thi lay trong thu muc xoi-<ten ban mod> canh file nay - tru khi ban mod la file *-xoi.zip (da co san ben
rem trong, giu nguyen).
set "NOTES="
set "TUNE="
set "BRAIN="
rem Khoa nhan vat an cho nguoi choi: C = co (an nut options o man hinh dau, khong mo khoa duoc, go lf2.net cung khong
rem mo - cho ban mod co nhan vat an mat can bang), K = khong (nhu OpenLF2 thuong). De trong thi hoi khi chay.
set "KHOA_AN="
rem Loi cho nguoi choi: "README - INSANE XOI.txt" trong ban xuat ban lam tu file xuat-ban-README.txt canh file nay
rem ({TEN}: ten ban xuat ban, {EXE}: file nguoi choi nhay dup, {GOC}: file .exe goc cua ban mod). Sua file ay (Notepad)
rem truoc khi chay de them gioi thieu ban mod, ten nguoi lam...
rem =====================================

rem Nhung gi keo tha vao: thu muc co data\data.txt la ban mod, thu muc co notes.txt / tune.txt / brain.txt la bo nho / bo so /
rem bo nao cua XOI; file .txt co chu "tune" trong ten la bo so, co chu "brain" la bo nao, file .txt khac la bo nho; file .exe:
rem thu muc cua no; con lai: file zip ban mod.
:doc_vao
if "%~1"=="" goto doc_xong
if exist "%~1\" (
  if exist "%~1\data\data.txt" (
    set "PACK=%~f1"
  ) else if exist "%~1\notes.txt" (
    set "NOTES=%~f1\notes.txt"
    if exist "%~1\tune.txt" set "TUNE=%~f1\tune.txt"
    if exist "%~1\brain.txt" set "BRAIN=%~f1\brain.txt"
  ) else if exist "%~1\tune.txt" (
    set "TUNE=%~f1\tune.txt"
    if exist "%~1\brain.txt" set "BRAIN=%~f1\brain.txt"
  ) else if exist "%~1\brain.txt" (
    set "BRAIN=%~f1\brain.txt"
  ) else (
    set "PACK=%~f1"
  )
) else if /i "%~x1"==".txt" (
  set "TXT=%~n1"
  if /i not "!TXT:tune=!"=="!TXT!" (set "TUNE=%~f1") else if /i not "!TXT:brain=!"=="!TXT!" (set "BRAIN=%~f1") else (set "NOTES=%~f1")
) else if /i "%~x1"==".exe" (
  set "PACK=%~dp1"
  set "PACK=!PACK:~0,-1!"
) else (
  set "PACK=%~f1"
)
shift
goto doc_vao
:doc_xong

if not exist "%~dp0xuat-ban.ps1" (echo Thieu file xuat-ban.ps1 canh xuat-ban.bat: giai nen lai ca bo XOI.& pause& exit /b 1)
set "XB_KIT=%~dp0"
set "XB_TEN=%TEN%"
set "XB_GAME=%GAME%"
set "XB_PACK=%PACK%"
set "XB_NOTES=%NOTES%"
set "XB_TUNE=%TUNE%"
set "XB_BRAIN=%BRAIN%"
if not defined KHOA_AN (
  echo.
  echo Khoa nhan vat an cho nguoi choi? An nut options o man hinh dau, khong mo khoa duoc, go lf2.net cung khong mo.
  choice /c CK /n /m "Bam C = co, K = khong: "
  if errorlevel 2 (set "KHOA_AN=K") else (set "KHOA_AN=C")
)
set "XB_KHOA_AN=%KHOA_AN%"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0xuat-ban.ps1"
if errorlevel 1 (
  echo.
  echo Chua xuat ban duoc - xem dong [LOI] o tren.
  pause
  exit /b 1
)
pause
