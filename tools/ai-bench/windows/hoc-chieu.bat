@echo off
setlocal EnableDelayedExpansion
rem HOC CHIEU MOT LAN (goi 104). Truoc moi tran INSANE! va XOI hoc chieu cua tung nhan vat tu du lieu ban mod: mot
rem tran 8 nhan vat mat 15-45 giay tren trinh duyet, va may nao trong phong cung phai hoc. File nay cho may ban hoc
rem MOT LAN moi nhan vat cua ban mod (ca cac dang bien hinh cua ho) roi ghi ket qua vao file zip ban mod
rem (xoi/learned-<id>.txt): game doc thang cac file ay, khoi hoc lai, vao tran ngay. Bot danh y het nhu khi tu hoc.
rem Ket qua: <ten>-xoi.zip canh file zip ban mod (da co thi cap nhat chinh no, giu cac file xoi khac cua no - bo nho,
rem bo so, bo nao; ban truoc giu o <ten>-xoi-truoc.zip). Tai file nay len relay nhu moi khi: ca phong dung cung file.
rem Chay lai khi doi du lieu ban mod (file .dat), hoac khi len goi OpenLF2 co cach hoc chieu moi (nhat ky game ghi
rem "learned by another version ... hoc-chieu.bat again"; trong luc do game tu hoc nhu cu, khong loi gi).
rem ============ CHINH O DAY ============
rem Game da cai. De trong thi tu tim (Install for me only, all users, hoac thu muc OpenLF2 canh file nay).
set "GAME="
rem File zip ban mod. De trong: file *-xoi.zip dau tien canh file nay, khong thi file zip ban mod dau tien; hoac
rem keo tha file zip ban mod vao file nay. Vi du: set "PACK=%~dp0naruto.zip"
set "PACK="
rem Thu muc tools\ai-bench va scripts cua goi (de trong thi tu tim canh file .bat nay)
set "BENCH="
set "SCRIPTS="
rem =====================================
set "KIT=%~dp0"
if not "%~1"=="" if /i "%~x1"==".zip" if exist "%~f1" set "PACK=%~f1"
if not defined PACK (
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
)
if not defined PACK (echo Khong thay file zip ban mod: dat no canh file nay, keo tha no vao file nay, hoac sua dong PACK o dau file.& pause& exit /b 1)
if not exist "%PACK%" (echo Khong thay "%PACK%" - sua dong PACK o dau file.& pause& exit /b 1)
if not defined GAME (
  for %%g in ("%LOCALAPPDATA%\Programs\OpenLF2\openlf2.exe" "%ProgramFiles(x86)%\OpenLF2\openlf2.exe" "%ProgramFiles%\OpenLF2\openlf2.exe" "%KIT%OpenLF2\openlf2.exe") do (
    if not defined GAME if exist "%%~g" set "GAME=%%~g"
  )
)
if not defined GAME set "GAME=%LOCALAPPDATA%\Programs\OpenLF2\openlf2.exe"
if not exist "%GAME%" (echo Khong thay game "%GAME%": cai OpenLF2 ^(bo cai OpenLF2-Windows-x64.exe o muc Releases cua trang GitHub cua du an, chon Install for me only^), hoac sua dong GAME o dau file.& pause& exit /b 1)
if not defined BENCH (
  if exist "%KIT%tools\ai-bench\learned.lua" set "BENCH=%KIT%tools\ai-bench"
  if exist "%KIT%learned.lua" set "BENCH=%KIT%."
  if exist "%KIT%..\learned.lua" set "BENCH=%KIT%.."
)
if not defined BENCH (echo Khong thay thu muc tools\ai-bench co learned.lua - can bo XOI cua goi 104 tro len.& pause& exit /b 1)
if not exist "%BENCH%\learned.lua" (echo Khong thay "%BENCH%\learned.lua" - can bo XOI cua goi 104 tro len.& pause& exit /b 1)
if not defined SCRIPTS (
  if exist "%KIT%scripts\base\game\learned.lua" set "SCRIPTS=%KIT%scripts"
  if exist "%KIT%..\..\scripts\base\game\learned.lua" set "SCRIPTS=%KIT%..\..\scripts"
  if exist "%KIT%..\..\..\scripts\base\game\learned.lua" set "SCRIPTS=%KIT%..\..\..\scripts"
)
for %%z in ("%PACK%") do (
  set "XTEN=%%~nz"
  set "XDIR=%%~dpz"
)
if /i "!XTEN:~-4!"=="-xoi" set "XTEN=!XTEN:~0,-4!"
set "XOUT=!XDIR!!XTEN!-xoi.zip"
set "XTRUOC=!XDIR!!XTEN!-xoi-truoc.zip"
rem (Hoc tren chinh file se duoc cap nhat - du lieu cua no - de cac file hop voi no.)
set "XHOC=%PACK%"
if exist "!XOUT!" set "XHOC=!XOUT!"
set "LAM=%KIT%hoc-chieu-!XTEN!"
if exist "%LAM%" rmdir /s /q "%LAM%"
mkdir "%LAM%\bench" 2>nul
copy /y "%BENCH%\*.lua" "%LAM%\bench\" >nul
copy /y "%BENCH%\package.manifest" "%LAM%\bench\" >nul
>"%LAM%\bench\config.lua" echo return {command = "learned"}
rem Scripts cua game da cai, cap nhat bang scripts cua goi (goi chi chua file da doi): khoi cai lai game.
set "XS="
for %%g in ("%GAME%") do set "CAI=%%~dpgscripts"
if defined SCRIPTS if exist "!CAI!\base\game\match.lua" (
  xcopy /e /i /q /y "!CAI!" "%LAM%\scripts" >nul
  xcopy /e /i /q /y "!SCRIPTS!" "%LAM%\scripts" >nul
  if exist "%LAM%\scripts\base\game\learned.lua" set XS=--scripts "%LAM%\scripts"
)
if not defined XS if not exist "!CAI!\base\game\learned.lua" (echo Game da cai cu hon goi 104 va khong thay scripts cua bo XOI nay: cai OpenLF2 moi, hoac dat file nay trong thu muc bo XOI.& pause& exit /b 1)
echo Ban mod: "!XHOC!"
echo Dang hoc chieu moi nhan vat ^(mot lan; ban mod lon mat vai phut^) ...
"%GAME%" --pack "!XHOC!" %XS% --mod "%LAM%\bench" --seed 1 --input-trace "" > "%LAM%\out.txt" 2>&1
findstr /b /c:"LEARNED-END" "%LAM%\out.txt" >nul
if errorlevel 1 (
  echo [LOI] Game dung giua chung - cac dong cuoi cua "%LAM%\out.txt":
  powershell -NoProfile -Command "Get-Content -LiteralPath '%LAM%\out.txt' -Tail 8"
  pause
  exit /b 1
)
set "HC_LAM=%LAM%"
set "HC_HOC=!XHOC!"
set "HC_OUT=!XOUT!"
set "HC_TRUOC=!XTRUOC!"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; Add-Type -AssemblyName System.IO.Compression; Add-Type -AssemblyName System.IO.Compression.FileSystem; $dir=Join-Path $env:HC_LAM 'xoi'; New-Item -ItemType Directory -Force -Path $dir | Out-Null; $enc=New-Object System.Text.UTF8Encoding($false); $w=@{}; $names=@{}; $ok=@(); $bad=@(); $bytes=0; foreach ($l in [System.IO.File]::ReadLines((Join-Path $env:HC_LAM 'out.txt'))) { if ($l.StartsWith('LEARNED ')) { $m=[regex]::Match($l, '^LEARNED (-?\d+)(?: (.*))?$'); if (-not $m.Success) { continue }; $id=$m.Groups[1].Value; $f=$w[$id]; if ($null -eq $f) { $f=New-Object System.IO.StreamWriter((Join-Path $dir ('learned-' + $id + '.txt')), $false, $enc); $w[$id]=$f } else { $f.Write([char]10) }; $f.Write($m.Groups[2].Value) } elseif ($l.StartsWith('LEARNED-DONE ')) { $p=$l.Split(' '); $ok+=$p[1]; $names[$p[1]]=$p[2]; $bytes+=[long]$p[3] } elseif ($l.StartsWith('LEARNED-FAILED ')) { $bad+=$l.Substring(15) } }; foreach ($f in $w.Values) { $f.Close() }; foreach ($id in @($w.Keys)) { if (-not ($ok -contains $id)) { Remove-Item -LiteralPath (Join-Path $dir ('learned-' + $id + '.txt')) -Force } }; Write-Host ('Da hoc ' + $ok.Count + ' nhan vat (' + [math]::Round($bytes / 1MB, 1) + ' MB truoc khi nen).'); foreach ($b in $bad) { Write-Host ('  [CHU Y] khong ghi duoc ' + $b + ' - nhan vat nay game tu hoc nhu cu') }; if ($ok.Count -eq 0) { throw 'khong co nhan vat nao' }; if (Test-Path -LiteralPath $env:HC_OUT) { Copy-Item -LiteralPath $env:HC_OUT -Destination $env:HC_TRUOC -Force } else { Copy-Item -LiteralPath $env:HC_HOC -Destination $env:HC_OUT -Force }; $z=[System.IO.Compression.ZipFile]::Open($env:HC_OUT, 'Update'); try { $e=$z.Entries | Where-Object { $_.FullName -imatch '(^|[\\/])data[\\/]data\.txt$' } | Sort-Object { $_.FullName.Length } | Select-Object -First 1; if (-not $e) { throw 'zip khong co data/data.txt' }; $root=$e.FullName.Substring(0, $e.FullName.Length - 13); $cu=0; foreach ($old in @($z.Entries | Where-Object { $_.FullName.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) -and $_.FullName.Substring($root.Length) -imatch '^xoi[\\/]learned-[^\\/]*\.txt$' })) { $old.Delete(); $cu++ }; foreach ($id in $ok) { [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($z, (Join-Path $dir ('learned-' + $id + '.txt')), ($root + 'xoi/learned-' + $id + '.txt'), [System.IO.Compression.CompressionLevel]::Optimal) }; if ($cu -gt 0) { Write-Host ('Da thay ' + $cu + ' file hoc chieu cu.') } } finally { $z.Dispose() }; Write-Host ''; Write-Host ('Xong: ' + $env:HC_OUT)"
if errorlevel 1 (
  echo [LOI] Khong dua duoc vao file zip. Tu lam: mo file zip ban mod, vao thu muc co thu muc data, tao thu muc xoi,
  echo       chep cac file trong "%LAM%\xoi" vao do.
  pause
  exit /b 1
)
echo.
echo Choi bang file zip nay ^(tai len relay, cung id voi ban mod cu - may nao trong phong cung dung file nay^): INSANE^^!
echo va XOI doc chieu da hoc, khong phai hoc lai. Ban sao cac file o "%LAM%\xoi".
pause
exit /b 0
