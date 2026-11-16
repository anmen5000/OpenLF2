@echo off
setlocal EnableDelayedExpansion
rem DUA BO NAO HOC TANG CUONG VAO BAN MOD (goi 88) - tu goi 88, XOI dieu khien nhan vat nao thi dung bo nao hoc tang
rem cuong cua nhan vat ay neu ban mod co file xoi/rl-<id>.txt (cung cho voi xoi/brain.txt, xoi/notes.txt).
rem File nay lay bo nao cua tung nhan vat trong thu muc hoc-tang-cuong\ (do hoc-tang-cuong.bat tao): bo-nao-tot-nhat.txt
rem neu co (lan kiem tra "greedy" tot nhat), khong thi bo nao cua vong cuoi; CHI dua vao khi lan kiem tra cua bo nao
rem ay cho thay no hon XOI mot minh ("network - XOI" duong). Nhan vat co bo nao kem hon XOI thi bo qua (va go file cu
rem cua no ra khoi ban mod neu co).
rem Ket qua: <ten>-xoi.zip canh file zip ban mod (dung ban -xoi thi cap nhat chinh no; ban truoc giu o
rem <ten>-xoi-truoc.zip). Ca phong choi phai cung file zip ban mod nay.
rem ============ CHINH O DAY ============
rem File zip ban mod. De trong: dung PACK cua hoc-tang-cuong-cai-dat.bat neu co, khong thi file *-xoi.zip dau tien
rem canh file nay, khong thi file zip ban mod dau tien.
set "PACK="
rem Chi cac nhan vat nay (ten thu muc trong hoc-tang-cuong\, vi du  set "CHI=2 55" ). De trong: moi nhan vat.
set "CHI="
rem Go bo nao cua cac nhan vat nay (so id) ra khoi ban mod, vi du  set "BO_RA=19" .
set "BO_RA="
rem =====================================
set "KIT=%~dp0"
rem (PACK cua hoc-tang-cuong-cai-dat.bat: goi file ay, roi chi giu PACK - cac cai dat khac cua no khong dung o day.)
if not defined PACK if exist "%KIT%hoc-tang-cuong-cai-dat.bat" call "%KIT%hoc-tang-cuong-cai-dat.bat"
if defined PACK if not exist "%PACK%" set "PACK="
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
if not exist "%PACK%" (echo Khong thay "%PACK%".& pause& exit /b 1)
set "RL_DIR=%KIT%hoc-tang-cuong"
if not exist "%RL_DIR%" (echo Khong thay thu muc "%RL_DIR%" - chay hoc-tang-cuong.bat truoc.& pause& exit /b 1)
for %%z in ("%PACK%") do (
  set "XTEN=%%~nz"
  set "XDIR=%%~dpz"
)
if /i "!XTEN:~-4!"=="-xoi" set "XTEN=!XTEN:~0,-4!"
set "XOUT=!XDIR!!XTEN!-xoi.zip"
set "XTRUOC=!XDIR!!XTEN!-xoi-truoc.zip"
set "RL_PACK=%PACK%"
set "RL_OUT=!XOUT!"
set "RL_TRUOC=!XTRUOC!"
set "RL_CHI=%CHI%"
set "RL_BO_RA=%BO_RA%"
echo Ban mod: "%PACK%"
echo Bo nao lay tu: "%RL_DIR%"
echo.
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; Add-Type -AssemblyName System.IO.Compression; Add-Type -AssemblyName System.IO.Compression.FileSystem; $inv=[Globalization.CultureInfo]::InvariantCulture; $chi=@(); if ($env:RL_CHI) { $chi=@($env:RL_CHI -split '[ ,;]+' | Where-Object { $_ }) }; $bora=@(); if ($env:RL_BO_RA) { $bora=@($env:RL_BO_RA -split '[ ,;]+' | Where-Object { $_ }) }; $add=@(); $drop=@($bora); foreach ($d in (Get-ChildItem -LiteralPath $env:RL_DIR -Directory)) { if ($chi.Count -gt 0 -and -not ($chi -contains $d.Name)) { continue }; $tt=Join-Path $d.FullName 'tom-tat.txt'; if (-not (Test-Path -LiteralPath $tt)) { continue }; $lines=@(Get-Content -LiteralPath $tt); $id=$null; $name=$d.Name; foreach ($l in $lines) { if ($l -match 'nhan vat (.+) \(id (-?\d+)\)') { $name=$Matches[1]; $id=$Matches[2]; break } }; if ($id -eq $null) { Write-Host ('  ' + $d.Name + ': khong thay so id trong tom-tat.txt - bo qua'); continue }; $file=$null; $round=$null; $score=$null; $best=Join-Path $d.FullName 'bo-nao-tot-nhat.txt'; $bestinfo=Join-Path $d.FullName 'tot-nhat.txt'; if ((Test-Path -LiteralPath $best) -and (Test-Path -LiteralPath $bestinfo)) { $t=((Get-Content -LiteralPath $bestinfo -TotalCount 1) -split '\s+'); $file=$best; $round=$t[0]; $score=[double]::Parse($t[1], $inv) / 10 } else { $latest=@(Get-ChildItem -LiteralPath $d.FullName -Filter 'bo-nao-*.txt' | Where-Object { $_.Name -match '^bo-nao-(\d+)\.txt$' } | Sort-Object { [int]($_.Name -replace '\D', '') }) | Select-Object -Last 1; if (-not $latest) { Write-Host ('  ' + $name + ' (id ' + $id + '): chua co bo nao - bo qua'); continue }; $file=$latest.FullName; $round=[int]($latest.Name -replace '\D', ''); foreach ($l in $lines) { if ($l -match ('^KIEM TRA vong ' + $round + ', greedy .*network - XOI ([+-]?[0-9.]+) points')) { $score=[double]::Parse($Matches[1], $inv) } } }; if ($score -eq $null) { Write-Host ('  ' + $name + ' (id ' + $id + '): bo nao vong ' + $round + ' chua duoc kiem tra - bo qua'); continue }; $first=Get-Content -LiteralPath $file -TotalCount 1; if ($first -notmatch '^RLW_HEAD ') { Write-Host ('  ' + $name + ' (id ' + $id + '): file bo nao hong - bo qua'); continue }; if ($score -le 0) { Write-Host ('  ' + $name + ' (id ' + $id + '): bo nao vong ' + $round + ' khong hon XOI (' + $score.ToString('+0.0;-0.0;0.0', $inv) + ' diem moi 100 tran) - khong dua vao'); $drop += $id; continue }; Write-Host ('  ' + $name + ' (id ' + $id + '): bo nao vong ' + $round + ', hon XOI ' + $score.ToString('+0.0', $inv) + ' diem moi 100 tran - dua vao'); $add += ,@($id, $file) }; if ($add.Count -eq 0 -and $drop.Count -eq 0) { Write-Host 'Khong co gi de dua vao.'; exit 0 }; if (Test-Path -LiteralPath $env:RL_OUT) { Copy-Item -LiteralPath $env:RL_OUT -Destination $env:RL_TRUOC -Force } else { Copy-Item -LiteralPath $env:RL_PACK -Destination $env:RL_OUT -Force }; $z=[System.IO.Compression.ZipFile]::Open($env:RL_OUT, 'Update'); try { $e=$z.Entries | Where-Object { $_.FullName -imatch '(^|[\\/])data[\\/]data\.txt$' } | Sort-Object { $_.FullName.Length } | Select-Object -First 1; if (-not $e) { throw 'zip khong co data/data.txt' }; $root=$e.FullName.Substring(0, $e.FullName.Length - 13); foreach ($id in $drop) { $entry=$root + 'xoi/rl-' + $id + '.txt'; foreach ($old in @($z.Entries | Where-Object { $_.FullName -ieq $entry })) { $old.Delete(); Write-Host ('     Da go ' + $entry) } }; foreach ($a in $add) { $entry=$root + 'xoi/rl-' + $a[0] + '.txt'; foreach ($old in @($z.Entries | Where-Object { $_.FullName -ieq $entry })) { $old.Delete() }; [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($z, $a[1], $entry); Write-Host ('     Da them ' + $entry) } } finally { $z.Dispose() }; Write-Host ''; Write-Host ('Xong: ' + $env:RL_OUT)"
if errorlevel 1 (echo [LOI] Khong dua duoc bo nao vao ban mod. Tu lam: mo file zip ban mod, vao thu muc co thu muc data, tao thu muc xoi, chep bo-nao-^<vong^>.txt cua nhan vat vao do voi ten rl-^<id^>.txt.& pause& exit /b 1)
echo.
echo Choi bang file zip nay ^(may nao trong phong cung phai co dung file nay^). XOI dung bo nao hoc tang cuong cua
echo nhan vat co file xoi/rl-^<id^>.txt; INSANE! khong dung.
pause
