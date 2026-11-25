@echo off
setlocal EnableDelayedExpansion
rem DUA BO NAO HOC TANG CUONG VAO BAN MOD (goi 88) - tu goi 88, XOI dieu khien nhan vat nao thi dung bo nao hoc tang
rem cuong cua nhan vat ay neu ban mod co file xoi/rl-<id>.txt (cung cho voi xoi/brain.txt, xoi/notes.txt).
rem File nay lay bo nao cua tung nhan vat trong thu muc hoc-tang-cuong\ (do hoc-tang-cuong.bat tao): bo da xac nhan
rem tren tran moi (xac-nhan.txt; tu goi 89 hoc-tang-cuong.bat xac nhan sau vong cuoi), khong thi bo cua lan kiem tra
rem moi nhat; CHI dua vao khi ket qua ay cho thay no hon XOI mot minh ("network - XOI" duong). Nhan vat co bo nao kem
rem hon XOI thi bo qua (va go file cu cua no ra khoi ban mod neu co). (Goi 88 lay bo co lan kiem tra cao nhat; lan cao
rem nhat trong nhieu lan thuong la lan gap may, nen tu goi 89 khong lay theo no nua.)
rem Ket qua: <ten>-xoi.zip canh file zip ban mod (dung ban -xoi thi cap nhat chinh no; ban truoc giu o
rem <ten>-xoi-truoc.zip). Ca phong choi phai cung file zip ban mod nay.
rem Tu goi 94: tom-tat.txt ghi ma cua ban mod da hoc (tu file data\data.txt cua no); bo nao hoc tren ban mod khac
rem (ban mod khac co cung so id) khong duoc dua vao. Ket qua cua goi truoc 94 khong co ma: van dua vao nhu truoc -
rem xong mot ban mod thi doi ten thu muc hoc-tang-cuong (vi du hoc-tang-cuong-naruto) truoc khi hoc ban mod khac.
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
rem (Tu goi 90: co file may-con-cai-dat.bat canh file nay - hoc tang cuong tren nhieu may, trang /hoc cua relay - thi
rem tai ket qua cua cac may con ve hoc-tang-cuong\<nhan vat>\ truoc. Nhan vat da hoc tren chinh may nay thi giu ket
rem qua cua may nay.)
set "HOC_HUB="
set "HOC_KEY="
if exist "%KIT%may-con-cai-dat.bat" call "%KIT%may-con-cai-dat.bat"
if defined HOC_HUB if defined HOC_KEY call :tai_vps
if not exist "%RL_DIR%" (echo Khong thay thu muc "%RL_DIR%" - chay hoc-tang-cuong.bat ^(hay may-con.bat^) truoc.& pause& exit /b 1)
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
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; Add-Type -AssemblyName System.IO.Compression; Add-Type -AssemblyName System.IO.Compression.FileSystem; $inv=[Globalization.CultureInfo]::InvariantCulture; $chi=@(); if ($env:RL_CHI) { $chi=@($env:RL_CHI -split '[ ,;]+' | Where-Object { $_ }) }; $bora=@(); if ($env:RL_BO_RA) { $bora=@($env:RL_BO_RA -split '[ ,;]+' | Where-Object { $_ }) }; $ma=''; try { $zr=[System.IO.Compression.ZipFile]::OpenRead($env:RL_PACK); try { $er=@($zr.Entries | Where-Object { $_.FullName -imatch '(^|[\\/])data[\\/]data\.txt$' } | Sort-Object { $_.FullName.Length }); if ($er.Count -gt 0) { $sr=$er[0].Open(); try { $hr=[Security.Cryptography.SHA256]::Create().ComputeHash($sr) } finally { $sr.Close() }; $ma=-join ($hr[0..5] | ForEach-Object { $_.ToString('x2') }) } } finally { $zr.Dispose() } } catch { $ma='' }; if ($ma) { Write-Host ('Ma ban mod: ' + $ma) }; $done=@{}; $cu=0; $add=@(); $drop=@($bora); foreach ($d in @(Get-ChildItem -LiteralPath $env:RL_DIR -Directory | Sort-Object Name)) { if ($chi.Count -gt 0 -and -not ($chi -contains $d.Name)) { continue }; $tt=Join-Path $d.FullName 'tom-tat.txt'; if (-not (Test-Path -LiteralPath $tt)) { continue }; $lines=@(Get-Content -LiteralPath $tt); $id=$null; $name=$d.Name; foreach ($l in $lines) { if ($l -match 'nhan vat (.+) \(id (-?\d+)\)') { $name=$Matches[1]; $id=$Matches[2]; break } }; if ($id -eq $null) { Write-Host ('  ' + $d.Name + ': khong thay so id trong tom-tat.txt - bo qua'); continue }; if ($bora -contains $id) { Write-Host ('  ' + $name + ' (id ' + $id + '): co trong BO_RA - khong dua vao'); continue }; $bd=@($lines | Where-Object { $_ -match '^=== Bat dau luc ' }); $mk=''; if ($bd.Count -gt 0 -and $bd[$bd.Count - 1] -match '\[ma-mod ([0-9a-f]+)\]') { $mk=$Matches[1] }; if ($mk -and $ma -and $mk -ne $ma) { Write-Host ('  ' + $d.Name + ' - ' + $name + ' (id ' + $id + '): hoc tren ban mod khac (ma ' + $mk + ') - bo qua'); continue }; if (-not $mk -and $d.Name -match '\.cu-[0-9]+$') { Write-Host ('  ' + $d.Name + ' - ' + $name + ' (id ' + $id + '): ket qua cu, khong ro ban mod - bo qua'); continue }; if ($done.ContainsKey($id)) { Write-Host ('  ' + $d.Name + ' - ' + $name + ' (id ' + $id + '): da lay bo nao cua id nay o ' + $done[$id] + ' - bo qua'); continue }; $file=$null; $round=$null; $score=$null; $how=''; $xn=Join-Path $d.FullName 'xac-nhan.txt'; if (Test-Path -LiteralPath $xn) { $t=@(([string](Get-Content -LiteralPath $xn -TotalCount 1)).Trim() -split '\s+'); if ($t.Count -ge 2 -and $t[0] -match '^\d+$') { $f=Join-Path $d.FullName ('bo-nao-' + $t[0] + '.txt'); if (Test-Path -LiteralPath $f) { $file=$f; $round=[int]$t[0]; $score=[double]::Parse($t[1], $inv) / 10; $how=', xac nhan tren tran moi' } } }; if ($null -eq $file) { foreach ($l in $lines) { if ($l -match '^KIEM TRA vong (\d+), greedy .*network - XOI ([+-]?[0-9.]+) points') { $r=[int]$Matches[1]; $f=Join-Path $d.FullName ('bo-nao-' + $r + '.txt'); if ((Test-Path -LiteralPath $f) -and (($null -eq $round) -or ($r -ge $round))) { $file=$f; $round=$r; $score=[double]::Parse($Matches[2], $inv); $how=', lan kiem tra moi nhat, chua xac nhan' } } } }; if ($null -eq $file) { Write-Host ('  ' + $name + ' (id ' + $id + '): chua co bo nao nao duoc kiem tra - bo qua'); continue }; $first=Get-Content -LiteralPath $file -TotalCount 1; if ($first -notmatch '^RLW_HEAD ') { Write-Host ('  ' + $name + ' (id ' + $id + '): file bo nao hong - bo qua'); continue }; if ($score -le 0) { Write-Host ('  ' + $name + ' (id ' + $id + '): bo nao vong ' + $round + ' khong hon XOI (' + $score.ToString('+0.0;-0.0;0.0', $inv) + ' diem moi 100 tran' + $how + ') - khong dua vao'); $done[$id]=$d.Name; $drop += $id; continue }; Write-Host ('  ' + $name + ' (id ' + $id + '): bo nao vong ' + $round + ', hon XOI ' + $score.ToString('+0.0', $inv) + ' diem moi 100 tran' + $how + ' - dua vao'); $done[$id]=$d.Name; if (-not $mk) { $cu++ }; $add += ,@($id, $file) }; if ($add.Count -eq 0 -and $drop.Count -eq 0) { Write-Host 'Khong co gi de dua vao.'; exit 0 }; if (Test-Path -LiteralPath $env:RL_OUT) { Copy-Item -LiteralPath $env:RL_OUT -Destination $env:RL_TRUOC -Force } else { Copy-Item -LiteralPath $env:RL_PACK -Destination $env:RL_OUT -Force }; $z=[System.IO.Compression.ZipFile]::Open($env:RL_OUT, 'Update'); try { $e=$z.Entries | Where-Object { $_.FullName -imatch '(^|[\\/])data[\\/]data\.txt$' } | Sort-Object { $_.FullName.Length } | Select-Object -First 1; if (-not $e) { throw 'zip khong co data/data.txt' }; $root=$e.FullName.Substring(0, $e.FullName.Length - 13); foreach ($id in $drop) { $entry=$root + 'xoi/rl-' + $id + '.txt'; foreach ($old in @($z.Entries | Where-Object { $_.FullName -ieq $entry })) { $old.Delete(); Write-Host ('     Da go ' + $entry) } }; foreach ($a in $add) { $entry=$root + 'xoi/rl-' + $a[0] + '.txt'; foreach ($old in @($z.Entries | Where-Object { $_.FullName -ieq $entry })) { $old.Delete() }; [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($z, $a[1], $entry); Write-Host ('     Da them ' + $entry) } } finally { $z.Dispose() }; Write-Host ''; Write-Host ('Xong: ' + $env:RL_OUT); if ($cu -gt 0) { Write-Host ('Chu y: ' + $cu + ' bo nao vua dua vao hoc truoc goi 94 (tom-tat.txt khong ghi ma ban mod) - hay chac chung hoc tren chinh ban mod nay.') }"
if errorlevel 1 (echo [LOI] Khong dua duoc bo nao vao ban mod. Tu lam: mo file zip ban mod, vao thu muc co thu muc data, tao thu muc xoi, chep bo-nao-^<vong^>.txt cua nhan vat vao do voi ten rl-^<id^>.txt.& pause& exit /b 1)
echo.
echo Choi bang file zip nay ^(may nao trong phong cung phai co dung file nay^). XOI dung bo nao hoc tang cuong cua
echo nhan vat co file xoi/rl-^<id^>.txt; INSANE^^! khong dung.
pause
exit /b 0

rem --- Ket qua cua cac may con tren relay (may-con.bat): ve hoc-tang-cuong\<nhan vat>\ (danh dau tu-vps.txt) ---
:tai_vps
where curl.exe >nul 2>&1 || (echo [CHU Y] Khong co curl.exe ^(can Windows 10 ban 1803 tro len^) - khong tai duoc ket qua tu relay.& exit /b 0)
echo Tai ket qua cua cac may con tu relay "%HOC_HUB%"...
if not exist "%RL_DIR%" mkdir "%RL_DIR%"
set "DS=%RL_DIR%\ket-qua-relay.txt"
del /q "%DS%" 2>nul
curl.exe -s -S -m 120 -H "X-Hoc-Key: %HOC_KEY%" -o "%DS%" "%HOC_HUB%/api/ket-qua"
if errorlevel 1 (echo [CHU Y] Khong noi duoc voi relay - chi dung ket qua tren may nay.& exit /b 0)
if not exist "%DS%" (echo   Relay chua co nhan vat nao xong.& exit /b 0)
findstr /b /c:"LOI=" "%DS%" >nul 2>&1 && (echo [CHU Y] Relay bao loi:& type "%DS%"& del /q "%DS%"& exit /b 0)
for /f "usebackq tokens=1,*" %%a in ("%DS%") do call :tai_mot "%%a" "%%b"
del /q "%DS%" 2>nul
echo.
exit /b 0

:tai_mot
set "ID=%~1"
set "TEPS=%~2"
set "D=%RL_DIR%\%ID%"
rem Tu goi 94: tom-tat.txt cua relay truoc; thu muc tren may nay la cua nhan vat khac hay ban mod khac (khac ma) thi
rem doi ten no thanh <id>.cu-<so> (khong xoa gi) roi moi tai.
set "TT_MOI=%RL_DIR%\%ID%.tom-tat.tai"
del /q "%TT_MOI%" 2>nul
curl.exe -s -S -f -m 300 -H "X-Hoc-Key: %HOC_KEY%" -o "%TT_MOI%" "%HOC_HUB%/api/tep/%ID%/tom-tat.txt"
if errorlevel 1 (echo   %ID%: tai chua duoc - chay lai file nay sau.& del /q "%TT_MOI%" 2>nul& exit /b 0)
if exist "%D%\tom-tat.txt" call :cung_nv
if exist "%D%\" if not exist "%D%\tu-vps.txt" (echo   %ID%: da hoc tren may nay - giu ket qua cua may nay.& del /q "%TT_MOI%" 2>nul& exit /b 0)
if not exist "%D%" mkdir "%D%"
move /y "%TT_MOI%" "%D%\tom-tat.txt" >nul
set "HONG="
for %%t in (%TEPS%) do if /i not "%%t"=="tom-tat.txt" (
  curl.exe -s -S -f -m 300 -H "X-Hoc-Key: %HOC_KEY%" -o "%D%\%%t.tai" "%HOC_HUB%/api/tep/%ID%/%%t" && move /y "%D%\%%t.tai" "%D%\%%t" >nul || set "HONG=1"
)
if defined HONG (
  echo   %ID%: tai chua du file - chay lai file nay sau.
) else (
  >"%D%\tu-vps.txt" echo ket qua tai tu relay
  echo   %ID%: da tai ket qua tu relay.
)
exit /b 0

rem --- Thu muc tren may nay va ket qua tren relay: cung nhan vat, cung ban mod, cung doi thu (DOI_THU, tu goi 112)?
rem Khac thi doi ten thu muc ---
:cung_nv
set "TT_CU=%D%\tom-tat.txt"
powershell -NoProfile -Command "$f = { param($p) $n = ''; $m = ''; $o = ''; $b = @(Select-String -LiteralPath $p -Pattern '^=== Bat dau luc ' | Select-Object -Last 1); if ($b.Count -gt 0) { $s = $b[0].Line; if ($s -match 'nhan vat (.+?) \(id (-?\d+)\)') { $n = $Matches[1] + ' (id ' + $Matches[2] + ')' }; if ($s -match '\[ma-mod ([0-9a-f]+)\]') { $m = $Matches[1] }; if ($s -match '\[doi-thu ([a-z]+)\]') { $o = $Matches[1] } }; ,@($n, $m, $o) }; $x = & $f $env:TT_CU; $y = & $f $env:TT_MOI; if (-not (($x[0] -and $y[0] -and $x[0] -ne $y[0]) -or ($x[1] -and $y[1] -and $x[1] -ne $y[1]) -or ($x[0] -and $y[0] -and $x[2] -ne $y[2]))) { exit 0 }; $k = 1; while (Test-Path -LiteralPath ($env:D + '.cu-' + $k)) { $k++ }; $moi = (Split-Path -Leaf $env:D) + '.cu-' + $k; try { Rename-Item -LiteralPath $env:D -NewName $moi -ErrorAction Stop } catch { Write-Host ('  [LOI] Khong doi ten duoc ' + $env:D + ': ' + $_.Exception.Message); exit 1 }; $mx = ''; if ($x[1]) { $mx = ', ma ban mod ' + $x[1] }; if ($x[2] -ne $y[2]) { $ox = 'XOI khong bo nao'; if ($x[2]) { $ox = $x[2] }; $mx = $mx + ', doi thu ' + $ox }; Write-Host ('  ' + (Split-Path -Leaf $env:D) + ': ket qua tren may nay la cua ' + $x[0] + $mx + ', khac ket qua tren relay - da doi ten thanh ' + $moi + ' (khong xoa gi).'); exit 2"
exit /b 0
