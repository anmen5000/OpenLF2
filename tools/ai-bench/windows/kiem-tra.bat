@echo off
setlocal EnableDelayedExpansion
rem KIEM TRA - xem vi sao game OpenLF2 khong mo duoc tren may nay. Nhay dup file nay (trong bo XOI, canh choi.bat va
rem mot file zip ban mod), doi khoang 2 phut, roi gui file kiem-tra.txt cho nguoi lam game.
rem Trong luc kiem tra, cua so game co the hien len roi tu tat: dung bam gi.
rem (File nay tu goi lai chinh no cho moi lan mo game co cua so: cmd /c call "<file nay>" thu1 <cach ve>, khong dau
rem ngoac kep nao khac - xem spsa.bat; game, ban mod, thu muc tam, cach ve o GAME, PACK, TAM, VE, CFG cua cua so chinh.)
if /i "%~1"=="thu1" goto thu1
rem ============ CHINH O DAY ============
rem Game da cai. De trong thi tu tim (Install for me only, all users, hoac thu muc OpenLF2 canh file nay).
set "GAME="
rem File zip ban mod. De trong thi lay file zip ban mod dau tien canh file nay; keo tha mot file zip vao file nay cung duoc.
set "PACK="
rem =====================================

set "SELF=%~f0"
set "TAM=%TEMP%\lf2-kiem-tra"
set "BAO=%~dp0kiem-tra.txt"
if not defined GAME (
  for %%g in ("%LOCALAPPDATA%\Programs\OpenLF2\openlf2.exe" "%ProgramFiles(x86)%\OpenLF2\openlf2.exe" "%ProgramFiles%\OpenLF2\openlf2.exe" "%~dp0OpenLF2\openlf2.exe") do (
    if not defined GAME if exist "%%~g" set "GAME=%%~g"
  )
)
if not defined GAME (echo Khong thay openlf2.exe - cai OpenLF2 truoc ^(bo cai OpenLF2-Windows-x64.exe, chon Install for me only^).& pause& exit /b 1)
if not exist "%GAME%" (echo Khong thay game "%GAME%" - sua dong GAME o dau file.& pause& exit /b 1)
if not "%~1"=="" if /i "%~x1"==".zip" set "PACK=%~f1"
if not defined PACK (
  pushd "%~dp0"
  for %%z in (*.zip) do (
    set "TEN=%%~nz"
    if not defined PACK if /i not "!TEN:~0,17!"=="lf2-online-upload" if /i not "!TEN:~0,7!"=="xoi-kit" set "PACK=%%~fz"
  )
  popd
)
if not defined PACK (echo Khong thay file zip ban mod canh file nay - dat mot file zip ban mod ^(vi du naruto.zip^) canh file nay.& pause& exit /b 1)
tasklist /FI "IMAGENAME eq openlf2.exe" 2>nul | find /I "openlf2.exe" >nul && (
  echo Dang co openlf2.exe chay ^(game, xoi-hoc.bat hay spsa.bat^). Tat het chung roi chay lai file nay.
  pause
  exit /b 1
)
if exist "%TAM%" rmdir /s /q "%TAM%"
mkdir "%TAM%"

echo Dang kiem tra, khoang 2 phut. Cua so game co the hien len roi tu tat - dung bam gi.
(
  echo ===== OpenLF2 kiem tra %DATE% %TIME% =====
  echo Game: %GAME%
  for %%g in ("%GAME%") do echo   kich thuoc %%~zg byte, sua luc %%~tg
  if exist "%~dp0version.txt" (echo Bo XOI:& type "%~dp0version.txt")
  echo Ban mod: %PACK%
  echo Phien: %SESSIONNAME% ^(Console = ngoi truoc may; RDP-Tcp = Remote Desktop^)
  ver
  echo CPU: %NUMBER_OF_PROCESSORS% luong, %PROCESSOR_ARCHITECTURE% %PROCESSOR_ARCHITEW6432%
) >"%BAO%"
rem Ban game da cai: x86 (32-bit), x64 hay arm64 - doc o dau file .exe.
powershell -NoProfile -Command "$f = [IO.File]::OpenRead($env:GAME); try { $b = New-Object byte[] 4096; [void]$f.Read($b, 0, 4096) } finally { $f.Close() }; $o = [BitConverter]::ToInt32($b, 60); $m = [BitConverter]::ToUInt16($b, $o + 4); $k = switch ($m) { 0x14c { 'x86 (32-bit)' } 0x8664 { 'x64 (64-bit)' } 0xaa64 { 'arm64' } default { 'khong ro' } }; 'Ban game: ' + $k" >>"%BAO%" 2>&1
echo.>>"%BAO%"
echo ----- Card man hinh ----->>"%BAO%"
powershell -NoProfile -Command "Get-CimInstance Win32_VideoController | ForEach-Object { $_.Name + ' / driver ' + $_.DriverVersion + ' / ' + $_.VideoModeDescription }" >>"%BAO%" 2>&1

rem 1. Khong cua so (nhu xoi-hoc.bat, spsa.bat): nap moi nhan vat cua ban mod.
echo.>>"%BAO%"
echo ----- 1. Chay khong cua so ^(nhu spsa.bat, xoi-hoc.bat^) ----->>"%BAO%"
set "BENCH="
if exist "%~dp0tools\ai-bench\loadall.lua" set "BENCH=%~dp0tools\ai-bench"
if defined BENCH (
  mkdir "%TAM%\bench"
  pushd "%BENCH%"
  copy /y *.lua "%TAM%\bench\" >nul
  copy /y package.manifest "%TAM%\bench\" >nul
  popd
  >"%TAM%\bench\config.lua" echo return {command = "loadall"}
  "%GAME%" --pack "%PACK%" --mod "%TAM%\bench" --input-trace "" --seed 1 >"%TAM%\khong-cua-so.txt" 2>&1
  set "MA=!errorlevel!"
  type "%TAM%\khong-cua-so.txt" >>"%BAO%"
  echo [ma thoat !MA!]>>"%BAO%"
) else (
  echo ^(bo qua: khong thay tools\ai-bench canh file nay^)>>"%BAO%"
)

rem 2. Co cua so, voi tung cach ve: xem sau 15 giay game con chay khong, co cua so khong.
set /a SO=0
for %%r in (software direct3d11 opengl gpu macdinh macdinh-moi) do call :thu_ve %%r

echo.>>"%BAO%"
echo ----- 3. Loi Windows ghi lai ve openlf2.exe ----->>"%BAO%"
powershell -NoProfile -Command "Get-WinEvent -FilterHashtable @{LogName='Application'; ProviderName='Application Error','Application Hang'} -MaxEvents 200 -ErrorAction SilentlyContinue | Where-Object { $_.Message -match 'openlf2' } | Select-Object -First 3 | ForEach-Object { '--- ' + $_.TimeCreated; $_.Message }" >>"%BAO%" 2>&1
echo.
echo ===== Xong. Gui file nay cho nguoi lam game: "%BAO%" =====
type "%BAO%"
pause
exit /b 0

:thu_ve
set /a SO+=1
set "VE=--renderer %1"
set "CFG="
if /i "%1"=="macdinh" set "VE="
rem (macdinh-moi: cach ve mac dinh, cau hinh moi - khong nho vi tri cua so, nen cua so khong an luc mo.)
if /i "%1"=="macdinh-moi" set "VE="
if /i "%1"=="macdinh-moi" set "CFG=%TAM%\cau-hinh-moi"
if defined CFG mkdir "%CFG%" 2>nul
echo   ... cach ve %1
start "kiem tra %1" /MIN cmd /c call "%SELF%" thu1 %1
ping -n 16 127.0.0.1 >nul 2>&1
set "TT=khong biet"
for /f "delims=" %%s in ('powershell -NoProfile -Command "$p = Get-Process openlf2 -ErrorAction SilentlyContinue; if (-not $p) { 'da tat' } elseif ($p | Where-Object { $_.MainWindowHandle -ne 0 }) { 'CO CUA SO' } else { 'van chay nhung KHONG co cua so' }"') do set "TT=%%s"
taskkill /F /IM openlf2.exe >nul 2>&1
ping -n 3 127.0.0.1 >nul 2>&1
echo.>>"%BAO%"
echo ----- 2.%SO% Co cua so, cach ve: %1 - sau 15 giay: !TT! ----->>"%BAO%"
if exist "%TAM%\ve-%1.txt" (type "%TAM%\ve-%1.txt" >>"%BAO%") else (echo ^(lan mo game nay khong chay^)>>"%BAO%")
exit /b 0

rem --- Mot lan mo game co cua so: %2 cach ve (ten file ket qua ve-%2.txt) ---
:thu1
set "KQ=%TAM%\ve-%~2.txt"
if defined CFG (
  "%GAME%" --config-dir "%CFG%" --pack "%PACK%" >"%KQ%" 2>&1
) else (
  "%GAME%" %VE% --pack "%PACK%" >"%KQ%" 2>&1
)
>>"%KQ%" echo [ma thoat %errorlevel%]
exit
