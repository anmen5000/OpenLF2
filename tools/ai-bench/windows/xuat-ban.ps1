# SPDX-License-Identifier: MIT
# Copyright (c) 2026 OpenLF2 contributors
#
# The work of xuat-ban.bat ("publish", in the XOI kit): a mod made ready for its players. One folder holds OpenLF2 (its
# program under the mod's name, its libraries, scripts and licences) and the mod as game.zip, with XOI's notes and
# numbers inside; OpenLF2 (package 45 on) plays a game.zip beside it when started without --pack, so a player unpacks
# the folder and double-clicks the program, with every level up to INSANE! and XOI. The folder is tried once without a
# window, then zipped for sharing. xuat-ban.bat passes its settings and what was dragged onto it as XB_* environment
# variables. Messages are Vietnamese without accents, as in the kit's batch files (a console's code page may not show
# them). It also runs under PowerShell 7 elsewhere, which is how it was tried.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

# Stops with a message, taking away what was being made (a half-made folder or zip is not to be shared).
$script:unfinished = @()
function Fail([string]$text) {
    foreach ($path in $script:unfinished) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue }
    }
    Write-Host ''
    Write-Host ('[LOI] ' + $text)
    exit 1
}
trap { Fail ('Co loi khi xuat ban: ' + [string]$_.Exception.Message) }
# A path under $dir: Under $dir 'a' 'b' is $dir\a\b (Join-Path takes one child at a time in Windows PowerShell).
function Under([string]$dir) {
    $path = $dir
    foreach ($part in $args) { $path = Join-Path $path $part }
    return $path
}
function Test-File([string]$path) { return [bool]$path -and (Test-Path -LiteralPath $path -PathType Leaf) }
# The version of the computer players in a scripts folder (smart.version in base\game\smart_ai.lua), 0 without one.
function Get-AiVersion([string]$scripts) {
    $file = Under $scripts 'base' 'game' 'smart_ai.lua'
    if (-not (Test-File $file)) { return 0 }
    $line = Select-String -LiteralPath $file -Pattern '^smart\.version = (\d+)' | Select-Object -First 1
    if ($line) { return [int]$line.Matches[0].Groups[1].Value }
    return 0
}
# Copies the files under $from into $to, folder by folder, over files of the same name.
function Copy-Tree([string]$from, [string]$to) {
    $base = (Resolve-Path -LiteralPath $from).ProviderPath.TrimEnd('\', '/')
    foreach ($file in @(Get-ChildItem -LiteralPath $base -Recurse -File)) {
        $target = Join-Path $to $file.FullName.Substring($base.Length + 1)
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $target))
        [IO.File]::Copy($file.FullName, $target, $true)
    }
}
# What a zip holds at $name (either kind of slash), or $null.
function Find-Entry($zip, [string]$name) {
    $other = $name.Replace('/', '\')
    return $zip.Entries | Where-Object { $_.FullName -ieq $name -or $_.FullName -ieq $other } | Select-Object -First 1
}

$kit = ([string]$env:XB_KIT).TrimEnd('\', '/')
if (-not $kit) { $kit = $PSScriptRoot }
$name = ([string]$env:XB_TEN).Trim()
$game = [string]$env:XB_GAME
$pack = [string]$env:XB_PACK
$notes = [string]$env:XB_NOTES
$tune = [string]$env:XB_TUNE
# Hidden fighters locked for the players (C) or not (K, or not set): openlf2.txt beside the mod's data folder, which
# OpenLF2 (package 48 on) reads - no options on the title screen, the option to unlock and LF2.NET doing nothing.
$lock = ([string]$env:XB_KHOA_AN).Trim().ToUpper() -eq 'C'

# The mod: set or dragged; else the first *-xoi.zip beside the kit (with XOI's notes and numbers inside), then the first
# other .zip (not an older copy kept by spsa.bat, an update package or the kit itself).
if (-not $pack) {
    $zips = @(Get-ChildItem -LiteralPath $kit -File | Where-Object { $_.Extension -ieq '.zip' } | Sort-Object Name)
    $pick = @($zips | Where-Object { $_.BaseName -match '-xoi$' }) +
        @($zips | Where-Object { $_.BaseName -notmatch '-xoi(-truoc)?$' -and $_.Name -notmatch '^(lf2-online-upload|xoi-kit)' })
    if ($pick.Count -eq 0) { Fail 'Khong thay ban mod: dat file zip ban mod canh xuat-ban.bat roi chay lai, hoac keo tha file zip / thu muc ban mod vao xuat-ban.bat.' }
    $pack = $pick[0].FullName
}
if (-not (Test-Path -LiteralPath $pack)) { Fail ('Khong thay "' + $pack + '" - sua dong PACK o dau xuat-ban.bat.') }
$item = Get-Item -LiteralPath $pack
if (-not $item.PSIsContainer -and $item.Extension -ieq '.exe') { $item = $item.Directory }
$isFolder = [bool]$item.PSIsContainer
if (-not $isFolder -and $item.Extension -ine '.zip') {
    Fail ('"' + $item.FullName + '" khong phai file zip. OpenLF2 doc ban mod dang file .zip hoac thu muc: giai nen file .rar / .7z truoc (bang 7-Zip), roi keo thu muc ban mod vao xuat-ban.bat.')
}
if ($isFolder) { $modName = $item.Name } else { $modName = $item.BaseName }
$isXoiZip = (-not $isFolder) -and ($modName -match '-xoi$')
$plain = $modName -replace '-xoi$', ''
if (-not $name) { $name = $plain }
if ($name.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or $name -match '^\.*$' -or $name -match '[. ]$') {
    Fail ('Ten "' + $name + '" khong dung duoc lam ten file (khong co \ / : * ? " < > |, khong ket thuc bang dau cham hay dau cach): sua dong TEN o dau xuat-ban.bat.')
}

# XOI's notes (xoi-hoc.bat) and numbers (spsa.bat): set or dragged; else xoi-<mod>\ beside the kit, where those two
# write them. A *-xoi.zip has its own inside, and they stay as they are unless set.
$xoiDir = Join-Path $kit ('xoi-' + $plain)
if (-not $isXoiZip) {
    if (-not $notes -and (Test-File (Join-Path $xoiDir 'notes.txt'))) { $notes = Join-Path $xoiDir 'notes.txt' }
    if (-not $notes -and (Test-File (Join-Path $kit ($plain + '-notes.txt')))) { $notes = Join-Path $kit ($plain + '-notes.txt') }
    if (-not $tune -and (Test-File (Join-Path $xoiDir 'tune.txt'))) { $tune = Join-Path $xoiDir 'tune.txt' }
}
foreach ($file in @($notes, $tune)) {
    if ($file -and -not (Test-File $file)) { Fail ('Khong thay "' + $file + '" - sua dong NOTES / TUNE o dau xuat-ban.bat.') }
}

# The installed game: set, or where the installer puts it (for me only, for all users), or OpenLF2\ beside the kit.
if (-not $game) {
    $places = @()
    if ($env:LOCALAPPDATA) { $places += Under $env:LOCALAPPDATA 'Programs' 'OpenLF2' 'openlf2.exe' }
    if (${env:ProgramFiles(x86)}) { $places += Under ${env:ProgramFiles(x86)} 'OpenLF2' 'openlf2.exe' }
    if ($env:ProgramFiles) { $places += Under $env:ProgramFiles 'OpenLF2' 'openlf2.exe' }
    $places += Under $kit 'OpenLF2' 'openlf2.exe'
    foreach ($place in $places) { if (-not $game -and (Test-File $place)) { $game = $place } }
    if (-not $game) { Fail 'Chua cai OpenLF2: tai bo cai OpenLF2-Windows-x64.exe (ban 45 tro len) o muc Releases cua trang GitHub cua du an, chon Install for me only, roi chay lai.' }
}
if (-not (Test-File $game)) { Fail ('Khong thay game "' + $game + '" - sua dong GAME o dau xuat-ban.bat.') }
$game = (Resolve-Path -LiteralPath $game).ProviderPath
$gameDir = Split-Path -Parent $game
$gameScripts = Join-Path $gameDir 'scripts'
if (-not (Test-File (Under $gameScripts 'base' 'game' 'match.lua'))) { Fail ('Thu muc game "' + $gameDir + '" khong co scripts\base\game\match.lua: cai lai OpenLF2.') }

$outRoot = Join-Path $kit 'xuat-ban'
$out = Join-Path $outRoot $name
$zip = Join-Path $outRoot ($name + '.zip')
$log = Join-Path $outRoot ($name + '-kiem-tra.txt')
Write-Host ('Ban mod:   ' + $item.FullName)
Write-Host ('Game:      ' + $game)
Write-Host ('Xuat ban:  ' + $out)
[void][IO.Directory]::CreateDirectory($outRoot)
if (Test-Path -LiteralPath $out) {
    try { Remove-Item -LiteralPath $out -Recurse -Force }
    catch { Fail ('Khong xoa duoc ban xuat ban cu "' + $out + '": tat game dang chay tu thu muc ay, dong cua so dang mo no, roi chay lai.') }
}
if (Test-Path -LiteralPath $zip) {
    try { Remove-Item -LiteralPath $zip -Force }
    catch { Fail ('Khong xoa duoc file cu "' + $zip + '": dong chuong trinh dang mo no roi chay lai.') }
}
[void][IO.Directory]::CreateDirectory($out)
$script:unfinished = @($out)

# OpenLF2: the program under the mod's name, its libraries, scripts and licences.
Write-Host 'Chep OpenLF2 ...'
$exe = Join-Path $out ($name + '.exe')
[IO.File]::Copy($game, $exe, $true)
foreach ($dll in @(Get-ChildItem -LiteralPath $gameDir -File | Where-Object { $_.Extension -ieq '.dll' })) {
    [IO.File]::Copy($dll.FullName, (Join-Path $out $dll.Name), $true)
}
# The scripts: the kit's (all of the game's, as the kit was made) when their computer players are newer than the
# installed game's, as choi.bat plays, so the published mod plays with the players it was trained with; else the
# installed game's.
$kitScripts = $null
foreach ($place in @((Join-Path $kit 'scripts'), (Under $kit '..' '..' '..' 'scripts'))) {
    if (-not $kitScripts -and (Test-File (Under $place 'base' 'game' 'match.lua')) -and
        (Test-File (Under $place 'base' 'game' 'smart_ai.lua'))) { $kitScripts = $place }
}
$installed = Get-AiVersion $gameScripts
$newer = 0
if ($kitScripts) { $newer = Get-AiVersion $kitScripts }
$useKit = $newer -gt $installed
# Locking the hidden fighters needs scripts that read openlf2.txt and keep CRAZY!, INSANE! and XOI for a locked mod
# (unlock.hard_levels in base\game\unlock.lua, package 49 on: package 48's locked the levels too); the computer
# players' version says nothing of that, so with the chosen scripts older, the other ones if they have it.
function Test-Lock([string]$scripts) {
    $file = Under $scripts 'base' 'game' 'unlock.lua'
    return (Test-File $file) -and [bool](Select-String -LiteralPath $file -Pattern 'function unlock\.hard_levels' -Quiet)
}
if ($lock) {
    $chosen = $gameScripts
    $other = $kitScripts
    if ($useKit) { $chosen = $kitScripts; $other = $gameScripts }
    if (-not (Test-Lock $chosen)) {
        if ($other -and (Test-Lock $other)) { $useKit = -not $useKit }
        else {
            Fail 'Khoa nhan vat an can scripts tu goi 49 tro len: ca game da cai lan thu muc scripts canh xuat-ban.bat deu cu hon. Dat thu muc scripts cua goi moi nhat canh xuat-ban.bat (hoac cai OpenLF2 moi), roi chay lai.'
        }
    }
}
if ($useKit) {
    Copy-Tree $kitScripts (Join-Path $out 'scripts')
    Write-Host ('May INSANE!/XOI ban ' + $newer + ', scripts cua bo XOI (game da cai: ban ' + $installed + ')')
} else {
    Copy-Tree $gameScripts (Join-Path $out 'scripts')
    Write-Host ('May INSANE!/XOI ban ' + $installed + ', scripts cua game da cai')
}
$licences = Join-Path $out 'licenses'
if (Test-Path -LiteralPath (Join-Path $gameDir 'licenses') -PathType Container) { Copy-Tree (Join-Path $gameDir 'licenses') $licences }
foreach ($file in @((Join-Path $gameDir 'LICENSE.txt'), (Join-Path $gameDir 'LICENSE'))) {
    if (Test-File $file) {
        [void][IO.Directory]::CreateDirectory($licences)
        [IO.File]::Copy($file, (Join-Path $licences 'OpenLF2-LICENSE.txt'), $true)
        break
    }
}

# The mod as game.zip: a copy of its zip, or its folder zipped; XOI's notes and numbers go beside its data folder.
Write-Host 'Lam game.zip (ban mod) ...'
$gameZip = Join-Path $out 'game.zip'
if ($isFolder) {
    $dir = $item.FullName.TrimEnd('\', '/')
    $archive = [IO.Compression.ZipFile]::Open($gameZip, 'Create')
    try {
        foreach ($file in @(Get-ChildItem -LiteralPath $dir -Recurse -File)) {
            $relative = $file.FullName.Substring($dir.Length + 1).Replace('\', '/')
            if ($notes -and $relative -imatch '(^|/)xoi/notes\.txt$') { continue }
            if ($tune -and $relative -imatch '(^|/)xoi/tune\.txt$') { continue }
            [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $file.FullName, $item.Name + '/' + $relative, 'Optimal')
        }
    } finally { $archive.Dispose() }
} else {
    [IO.File]::Copy($item.FullName, $gameZip, $true)
}
$root = $null
$hadSettings = $false
$archive = [IO.Compression.ZipFile]::OpenRead($gameZip)
try {
    $data = @($archive.Entries | Where-Object { $_.FullName -imatch '(^|[\\/])data[\\/]data\.txt$' } | Sort-Object { $_.FullName.Length }) | Select-Object -First 1
    if ($data) {
        $root = $data.FullName.Substring(0, $data.FullName.Length - 'data/data.txt'.Length)
        $hadSettings = [bool](Find-Entry $archive ($root + 'openlf2.txt'))
    }
} finally { $archive.Dispose() }
if ($null -eq $root) { Fail ('"' + $item.FullName + '" khong co data\data.txt: day khong phai ban mod LF2 (hay thu muc / file zip cua no).') }
if ($notes -or $tune -or $lock -or $hadSettings) {
    $archive = [IO.Compression.ZipFile]::Open($gameZip, 'Update')
    try {
        foreach ($pair in @(@($notes, 'xoi/notes.txt'), @($tune, 'xoi/tune.txt'))) {
            if (-not $pair[0]) { continue }
            $entry = $root + $pair[1]
            foreach ($old in @($archive.Entries | Where-Object { $_.FullName -ieq $entry -or $_.FullName -ieq $entry.Replace('/', '\') })) { $old.Delete() }
            [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $pair[0], $entry, 'Optimal')
            Write-Host ('  them ' + $entry + ' <- ' + $pair[0])
        }
        # The mod's settings for OpenLF2: written when locking, taken away otherwise (the publisher's choice).
        $entry = $root + 'openlf2.txt'
        foreach ($old in @($archive.Entries | Where-Object { $_.FullName -ieq $entry -or $_.FullName -ieq $entry.Replace('/', '\') })) { $old.Delete() }
        if ($lock) {
            $writer = New-Object IO.StreamWriter(($archive.CreateEntry($entry, 'Optimal')).Open(), (New-Object Text.UTF8Encoding $false))
            try {
                $writer.Write("# OpenLF2: cai dat cua ban mod (xuat-ban.bat) / this mod's settings for OpenLF2`r`n" +
                    "# Nhan vat an bi khoa: khong co nut options, go lf2.net khong mo khoa / hidden fighters stay hidden`r`n" +
                    "hidden_characters = locked`r`noptions = hidden`r`n")
            } finally { $writer.Dispose() }
        }
    } finally { $archive.Dispose() }
}
$archive = [IO.Compression.ZipFile]::OpenRead($gameZip)
try {
    $notesEntry = Find-Entry $archive ($root + 'xoi/notes.txt')
    $tuneEntry = Find-Entry $archive ($root + 'xoi/tune.txt')
    if ($notesEntry) { Write-Host ('Bo nho XOI: co (' + [math]::Ceiling($notesEntry.Length / 1KB) + ' KB)') }
    else { Write-Host 'Bo nho XOI: chua co - XOI van choi, nhung khong co bo nho huan luyen cua ban mod (xoi-hoc.bat lam bo nho)' }
    if ($tuneEntry) { Write-Host 'Bo so rieng cua ban mod (XOI): co' }
    else { Write-Host 'Bo so rieng cua ban mod (XOI): chua co - XOI dung bo so chung (spsa.bat chinh bo so rieng)' }
} finally { $archive.Dispose() }
if ($lock) { Write-Host 'Nhan vat an: KHOA - khong co nut options o man hinh dau, go lf2.net cung khong mo; CRAZY!, INSANE!, XOI van chon duoc' }
else { Write-Host 'Nhan vat an: nhu thuong - nguoi choi mo khoa duoc (options, lf2.net)' }

# A few words for the players, from xuat-ban-README.txt beside the kit ({TEN}: the name).
$template = Join-Path $kit 'xuat-ban-README.txt'
if (Test-File $template) {
    $text = [IO.File]::ReadAllText($template, [Text.Encoding]::UTF8).Replace('{TEN}', $name)
} else {
    $text = $name + " - OpenLF2, INSANE! va XOI`r`n`r`nGiai nen ca file zip, roi nhay dup " + $name + ".exe. Muc kho: bam qua CRAZY! la toi INSANE!, roi XOI.`r`n" +
        "Extract the whole zip, then double-click " + $name + ".exe. Difficulty: past CRAZY! come INSANE!, then XOI.`r`n" +
        "game.zip la ban mod / is the mod: dung giai nen hay doi ten / leave it as it is.`r`n"
}
[IO.File]::WriteAllText((Join-Path $out 'README.txt'), $text, (New-Object Text.UTF8Encoding $true))

# Tried once as a player starts it, without a window: the program must find game.zip beside it by itself.
Write-Host 'Thu mo ban xuat ban (khong cua so) ...'
$errors = $log + '.err'
foreach ($file in @($log, $errors)) { if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force } }
$process = Start-Process -FilePath $exe -ArgumentList '--input-trace "" --seed 1' -WorkingDirectory $out -NoNewWindow -PassThru `
    -RedirectStandardOutput $log -RedirectStandardError $errors
$null = $process.Handle
if (-not $process.WaitForExit(300000)) {
    try { $process.Kill() } catch { }
    Fail ('Ban xuat ban mo qua 5 phut chua xong - xem ' + $log)
}
$output = ''
foreach ($file in @($log, $errors)) { if (Test-Path -LiteralPath $file) { $output += [IO.File]::ReadAllText($file) } }
[IO.File]::WriteAllText($log, $output)
if (Test-Path -LiteralPath $errors) { Remove-Item -LiteralPath $errors -Force }
if ($output -notmatch 'Game pack game\.zip' -and $output -match 'headless runs need|LF2_v2\.0a\.exe') {
    Fail ('OpenLF2 da cai (' + $game + ') la ban cu: chua tu mo game.zip canh no. Cai ban moi (OpenLF2-Windows-x64.exe o muc Releases, ban 45 tro len) roi chay lai xuat-ban.bat.')
}
# A picture, sound or piece of music the game cannot read is left out, as in its window, and the game plays on
# ("Picture ...; left out", "Music ...", "Sound ..."). An OpenLF2 before package 47 (pictures) or 49 (sounds and
# music) stopped such a run at the first one instead: its last line is that error - "pe/MENU_BACK2: ..." or a
# picture's path, "music: no audio stream: Decoder not found" (WMA Pro before package 49), "music bgm/main.wma is
# shorter than a second", "game pack resource missing: bgm/main.wma" - something missing, not a mod that does not
# open.
$lines = @($output -split "`r?`n" | Where-Object { $_ })
$found = $output -match 'Game pack game\.zip'
$pictures = @($lines | Where-Object { $_ -match '^(Picture|Music|Sound) .+; left out$' })
$opened = $found -and $process.ExitCode -eq 0 -and $output -match 'Indexed '
$older = $false
if (-not $opened -and $found -and $lines.Count -gt 0 -and
    $lines[-1] -match '^(pe/[A-Za-z0-9_]+: |[^:]+\.(bmp|png): |music[: ]|game pack resource missing: )') {
    $opened = $true
    $older = $true
    $pictures += $lines[-1]
}
if (-not $opened) {
    Write-Host ''
    foreach ($line in @($lines | Select-Object -Last 6)) { Write-Host ('  ' + $line) }
    Fail ('Ban xuat ban khong mo duoc ban mod (cac dong o tren, ca trong ' + $log + '). Ban mod choi duoc bang choi.bat thi gui file ay cho nguoi lam OpenLF2.')
}
Write-Host ('  ' + (@($lines | Where-Object { $_ -match '^Game pack ' }) | Select-Object -First 1))
if ($pictures.Count -gt 0) {
    Write-Host '  [CHU Y] Co hinh / nhac / tieng game khong doc duoc - game bo qua va van choi (nhu khi choi bang choi.bat):'
    foreach ($line in @($pictures | Select-Object -First 5)) { Write-Host ('    ' + $line) }
    if ($older) { Write-Host '    OpenLF2 da cai la ban cu: ban moi (goi 49 tro len) doc duoc nhieu kieu hinh va nhac hon (WMA Pro, MP3) - cai ban moi roi xuat ban lai.' }
    else { Write-Host ('    Muon game doc duoc chung: gui file ' + $log + ' cho nguoi lam OpenLF2.') }
}

# The folder zipped, its own name at the top (Windows' Extract All, 7-Zip and the like keep it together); game.zip is
# stored as it is.
Write-Host ('Nen thanh ' + $zip + ' ...')
$zipPart = $zip + '.tmp'
if (Test-Path -LiteralPath $zipPart) { Remove-Item -LiteralPath $zipPart -Force }
$script:unfinished = @($out, $zipPart)
$base = (Resolve-Path -LiteralPath $out).ProviderPath.TrimEnd('\', '/')
$archive = [IO.Compression.ZipFile]::Open($zipPart, 'Create')
try {
    foreach ($file in @(Get-ChildItem -LiteralPath $base -Recurse -File)) {
        $relative = $file.FullName.Substring($base.Length + 1).Replace('\', '/')
        $level = 'Optimal'
        if ($file.Extension -ieq '.zip') { $level = 'NoCompression' }
        [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $file.FullName, $name + '/' + $relative, $level)
    }
} finally { $archive.Dispose() }
[IO.File]::Move($zipPart, $zip)
$script:unfinished = @()

$size = (Get-Item -LiteralPath $zip).Length
Write-Host ''
Write-Host ('XONG. Gui file nay cho nguoi choi: ' + $zip + ' (' + [math]::Round($size / 1MB, 1) + ' MB)')
Write-Host ('Nguoi choi giai nen ca file zip, mo thu muc "' + $name + '", nhay dup "' + $name + '.exe": khong cai gi them.')
Write-Host 'Trong game, o dong muc kho bam qua CRAZY! la toi INSANE!, roi XOI.'
Write-Host ('Thu tren may nay: nhay dup "' + $exe + '".')
if ($env:OS -eq 'Windows_NT') {
    try { Start-Process -FilePath 'explorer.exe' -ArgumentList ('/select,"' + $zip + '"') } catch { }
}
exit 0
