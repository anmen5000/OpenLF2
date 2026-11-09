# SPDX-License-Identifier: MIT
# Copyright (c) 2026 OpenLF2 contributors
#
# The work of xuat-ban.bat ("publish", in the XOI kit): a mod made ready for its players. The mod's own folder, as its
# author shares it (bg, bgm, data, sprite and the rest, its own .exe too), with OpenLF2 put in it: the program as
# "<name> - INSANE XOI.exe", its libraries, scripts and licences, and XOI's notes, numbers and brain in xoi\. OpenLF2 (package
# 50 on) plays the game folder it lies in when started without --pack, so a player unpacks the folder and double-clicks
# the program, with every level up to INSANE! and XOI. The folder is tried once without a window, then zipped for
# sharing. xuat-ban.bat passes its settings and what was dragged onto it as XB_* environment variables. Messages are
# Vietnamese without accents, as in the kit's batch files (a console's code page may not show them). It also runs
# under PowerShell 7 elsewhere, which is how it was tried.
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
# A file or folder name from the mod's zip that Windows can take: not empty, not . or .., none of \ / : * ? " < > |.
function Test-Part([string]$part) {
    return [bool]$part -and $part -ne '.' -and $part -ne '..' -and $part.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -lt 0
}

$kit = ([string]$env:XB_KIT).TrimEnd('\', '/')
if (-not $kit) { $kit = $PSScriptRoot }
$name = ([string]$env:XB_TEN).Trim()
$game = [string]$env:XB_GAME
$pack = [string]$env:XB_PACK
$notes = [string]$env:XB_NOTES
$tune = [string]$env:XB_TUNE
$brain = [string]$env:XB_BRAIN
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
# The program the players double-click, beside the mod's own .exe (the original LF2, up to CRAZY!): its name says it is
# the one with INSANE! and XOI.
$exeName = $name + ' - INSANE XOI.exe'
$readmeName = 'README - INSANE XOI.txt'

# XOI's notes (xoi-hoc.bat) and numbers (spsa.bat): set or dragged; else xoi-<mod>\ beside the kit, where those two
# write them. A *-xoi.zip has its own inside, and they stay as they are unless set.
$xoiDir = Join-Path $kit ('xoi-' + $plain)
if (-not $isXoiZip) {
    if (-not $notes -and (Test-File (Join-Path $xoiDir 'notes.txt'))) { $notes = Join-Path $xoiDir 'notes.txt' }
    if (-not $notes -and (Test-File (Join-Path $kit ($plain + '-notes.txt')))) { $notes = Join-Path $kit ($plain + '-notes.txt') }
    if (-not $tune -and (Test-File (Join-Path $xoiDir 'tune.txt'))) { $tune = Join-Path $xoiDir 'tune.txt' }
    if (-not $brain -and (Test-File (Join-Path $xoiDir 'brain.txt'))) { $brain = Join-Path $xoiDir 'brain.txt' }
}
foreach ($file in @($notes, $tune, $brain)) {
    if ($file -and -not (Test-File $file)) { Fail ('Khong thay "' + $file + '" - sua dong NOTES / TUNE / BRAIN o dau xuat-ban.bat.') }
}

# The installed game: set, or where the installer puts it (for me only, for all users), or OpenLF2\ beside the kit.
if (-not $game) {
    $places = @()
    if ($env:LOCALAPPDATA) { $places += Under $env:LOCALAPPDATA 'Programs' 'OpenLF2' 'openlf2.exe' }
    if (${env:ProgramFiles(x86)}) { $places += Under ${env:ProgramFiles(x86)} 'OpenLF2' 'openlf2.exe' }
    if ($env:ProgramFiles) { $places += Under $env:ProgramFiles 'OpenLF2' 'openlf2.exe' }
    $places += Under $kit 'OpenLF2' 'openlf2.exe'
    foreach ($place in $places) { if (-not $game -and (Test-File $place)) { $game = $place } }
    if (-not $game) { Fail 'Chua cai OpenLF2: tai bo cai OpenLF2-Windows-x64.exe (goi 50 tro len) o muc Releases cua trang GitHub cua du an, chon Install for me only, roi chay lai.' }
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

# The mod's own folder, as its author shares it: the folder holding data\data.txt nearest the top of the zip or of the
# folder dragged, every file and folder of it (empty ones too: the original's recording folder, say). XOI's notes and
# numbers set for it, and its settings for OpenLF2 (openlf2.txt), are written after.
Write-Host 'Chep ban mod (nguyen thu muc goc) ...'
function Test-Later([string]$relative) {
    $relative = $relative.Replace('\', '/')
    return ($notes -and $relative -ieq 'xoi/notes.txt') -or ($tune -and $relative -ieq 'xoi/tune.txt') -or ($brain -and $relative -ieq 'xoi/brain.txt') -or ($relative -ieq 'openlf2.txt')
}
$skipped = 0
$source = $null
if ($isFolder) {
    $listing = @(Get-ChildItem -LiteralPath $item.FullName -Recurse -File |
        Where-Object { $_.Name -ieq 'data.txt' -and $_.Directory.Name -ieq 'data' } | Sort-Object { $_.FullName.Length })
    if ($listing.Count -gt 0) { $source = $listing[0].Directory.Parent.FullName.TrimEnd('\', '/') }
} else {
    $archive = [IO.Compression.ZipFile]::OpenRead($item.FullName)
    try {
        $data = @($archive.Entries | Where-Object { $_.FullName -imatch '(^|[\\/])data[\\/]data\.txt$' } | Sort-Object { $_.FullName.Length }) | Select-Object -First 1
        if ($data) { $source = $data.FullName.Substring(0, $data.FullName.Length - 'data/data.txt'.Length).Replace('\', '/') }
    } finally { $archive.Dispose() }
}
if ($null -eq $source) { Fail ('"' + $item.FullName + '" khong co data\data.txt: day khong phai ban mod LF2 (hay thu muc / file zip cua no).') }
# The mod's own settings for OpenLF2 (openlf2.txt: a mod that plays on a screen of its own says so there, Naruto:
# The Setting Dawn 2.6), kept; the lock lines are added to them below.
$ownSettings = ''
if ($isFolder) {
    foreach ($entry in @(Get-ChildItem -LiteralPath $source -Recurse)) {
        $relative = $entry.FullName.Substring($source.Length + 1)
        $target = Join-Path $out $relative
        if ($entry.PSIsContainer) { [void][IO.Directory]::CreateDirectory($target); continue }
        if ($relative -ieq 'openlf2.txt') { $ownSettings = [IO.File]::ReadAllText($entry.FullName) }
        if (Test-Later $relative) { continue }
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $target))
        [IO.File]::Copy($entry.FullName, $target, $true)
    }
} else {
    # Only names Windows can take, under the folder: a zip from elsewhere cannot write outside it.
    $archive = [IO.Compression.ZipFile]::OpenRead($item.FullName)
    try {
        foreach ($entry in @($archive.Entries)) {
            $full = $entry.FullName.Replace('\', '/')
            if ($full.Length -le $source.Length -or -not $full.StartsWith($source, [StringComparison]::OrdinalIgnoreCase)) { continue }
            $relative = $full.Substring($source.Length)
            $parts = @($relative.TrimEnd('/').Split('/'))
            if (@($parts | Where-Object { -not (Test-Part $_) }).Count -gt 0) { $skipped += 1; continue }
            $target = Join-Path $out ($parts -join [IO.Path]::DirectorySeparatorChar)
            if ($relative.EndsWith('/')) { [void][IO.Directory]::CreateDirectory($target); continue }
            if ($relative -ieq 'openlf2.txt') {
                $reader = New-Object IO.StreamReader($entry.Open())
                try { $ownSettings = $reader.ReadToEnd() } finally { $reader.Dispose() }
            }
            if (Test-Later $relative) { continue }
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $target))
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
        }
    } finally { $archive.Dispose() }
}
if ($skipped -gt 0) { Write-Host ('  [CHU Y] ' + $skipped + ' file trong zip co ten Windows khong nhan - bo qua') }

# OpenLF2: the program under its own name, its libraries, scripts and licences.
Write-Host 'Them OpenLF2 ...'
$exe = Join-Path $out $exeName
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

# XOI's notes and numbers in xoi\ beside the data folder, where the game reads them.
foreach ($pair in @(@($notes, 'notes.txt'), @($tune, 'tune.txt'), @($brain, 'brain.txt'))) {
    if (-not $pair[0]) { continue }
    $target = Under $out 'xoi' $pair[1]
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $target))
    [IO.File]::Copy($pair[0], $target, $true)
    Write-Host ('  them xoi\' + $pair[1] + ' <- ' + $pair[0])
}
$notesFile = Under $out 'xoi' 'notes.txt'
if (Test-File $notesFile) { Write-Host ('Bo nho XOI: co (' + [math]::Ceiling((Get-Item -LiteralPath $notesFile).Length / 1KB) + ' KB)') }
else { Write-Host 'Bo nho XOI: chua co - XOI van choi, nhung khong co bo nho huan luyen cua ban mod (xoi-hoc.bat lam bo nho)' }
if (Test-File (Under $out 'xoi' 'tune.txt')) { Write-Host 'Bo so rieng cua ban mod (XOI): co' }
else { Write-Host 'Bo so rieng cua ban mod (XOI): chua co - XOI dung bo so chung (spsa.bat chinh bo so rieng)' }
if (Test-File (Under $out 'xoi' 'brain.txt')) { Write-Host 'Bo nao XOI cua ban mod: co' }
else { Write-Host 'Bo nao XOI cua ban mod: chua co - XOI choi khong co bo nao (hoc-sau.bat hoc bo nao)' }
# The mod's settings for OpenLF2: its own lines as they came (the lock's two keys taken out when locking), and the
# lock lines when locking; nothing written for a mod without settings that is not locked (the publisher's choice).
$settings = ''
if ($ownSettings) {
    foreach ($line in ($ownSettings -split "\r?\n")) {
        if ($lock -and $line -imatch '^\s*(hidden_characters|options)\s*=') { continue }
        $settings += $line.TrimEnd() + "`r`n"
    }
    $settings = $settings.TrimEnd("`r", "`n") + "`r`n"
}
if ($lock) {
    $settings += "# OpenLF2: cai dat cua ban mod (xuat-ban.bat) / this mod's settings for OpenLF2`r`n" +
        "# Nhan vat an bi khoa: khong co nut options, go lf2.net khong mo khoa / hidden fighters stay hidden`r`n" +
        "hidden_characters = locked`r`noptions = hidden`r`n"
    Write-Host 'Nhan vat an: KHOA - khong co nut options o man hinh dau, go lf2.net cung khong mo; CRAZY!, INSANE!, XOI van chon duoc'
} else {
    Write-Host 'Nhan vat an: nhu thuong - nguoi choi mo khoa duoc (options, lf2.net)'
}
if ($settings) {
    [IO.File]::WriteAllText((Join-Path $out 'openlf2.txt'), $settings, (New-Object Text.UTF8Encoding $false))
    if ($ownSettings) { Write-Host 'Cai dat rieng cua ban mod (openlf2.txt): giu nguyen' }
}

# Tried once as a player starts it, without a window: the program must play the folder it lies in by itself.
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
$lines = @($output -split "`r?`n" | Where-Object { $_ })
$found = $output -cmatch '(?m)^Game folder '
# An OpenLF2 before package 50 does not look at the folder it lies in: it asks for the original game (or plays it,
# when the computer has it) or plays a game.zip.
if (-not $found -and $output -notmatch '(?i)game folder' -and $output -match 'headless runs need|LF2_v2\.0a\.exe|lf2_v20a_Setup|Game pack |Indexed ') {
    Fail ('OpenLF2 da cai (' + $game + ') la ban cu: chua tu choi thu muc ban mod ma no nam trong. Cai ban moi (OpenLF2-Windows-x64.exe o muc Releases, goi 50 tro len) roi chay lai xuat-ban.bat.')
}
# A picture, sound or piece of music the game cannot read is left out, as in its window, and the game plays on
# ("Picture ...; left out", "Music ...", "Sound ...": Sx2's missing bgm/main.wma, Convergence's 8 KB tracks).
$pictures = @($lines | Where-Object { $_ -match '^(Picture|Music|Sound) .+; left out$' })
if (-not ($found -and $process.ExitCode -eq 0 -and $output -match 'Indexed ')) {
    Write-Host ''
    foreach ($line in @($lines | Select-Object -Last 6)) { Write-Host ('  ' + $line) }
    Fail ('Ban xuat ban khong mo duoc ban mod (cac dong o tren, ca trong ' + $log + '). Ban mod choi duoc bang choi.bat thi gui file ay cho nguoi lam OpenLF2.')
}
$folderLine = [string](@($lines | Where-Object { $_ -cmatch '^Game folder ' }) | Select-Object -First 1)
Write-Host ('  ' + $folderLine)
if ($pictures.Count -gt 0) {
    Write-Host '  [CHU Y] Co hinh / nhac / tieng game khong doc duoc - game bo qua va van choi (nhu khi choi bang choi.bat):'
    foreach ($line in @($pictures | Select-Object -First 5)) { Write-Host ('    ' + $line) }
    Write-Host ('    Muon game doc duoc chung: gui file ' + $log + ' cho nguoi lam OpenLF2.')
}
# The mod's own program, as the game found it (", executable <name>", in lowercase), by its name in the folder.
$original = 'file .exe goc cua ban mod'
if ($folderLine -match ', executable (.+)$') {
    $lower = $Matches[1]
    $original = $lower
    foreach ($file in @(Get-ChildItem -LiteralPath $out -File)) { if ($file.Name -ieq $lower) { $original = $file.Name; break } }
}

# A few words for the players, from xuat-ban-README.txt beside the kit ({TEN}: the name, {EXE}: the program, {GOC}: the
# mod's own .exe), beside the mod's own readme.
$template = Join-Path $kit 'xuat-ban-README.txt'
if (Test-File $template) {
    $text = [IO.File]::ReadAllText($template, [Text.Encoding]::UTF8).Replace('{TEN}', $name).Replace('{EXE}', $exeName).Replace('{GOC}', $original)
} else {
    $text = $name + " - OpenLF2, INSANE! va XOI`r`n`r`nGiai nen ca file zip, roi nhay dup " + $exeName + ". Muc kho: bam qua CRAZY! la toi INSANE!, roi XOI.`r`n" +
        "Extract the whole zip, then double-click " + $exeName + ". Difficulty: past CRAZY! come INSANE!, then XOI.`r`n" +
        $original + " la game goc cua ban mod (chi toi CRAZY!) / is the mod's original game (up to CRAZY!).`r`n"
}
[IO.File]::WriteAllText((Join-Path $out $readmeName), $text, (New-Object Text.UTF8Encoding $true))

# The folder zipped, its own name at the top (Windows' Extract All, 7-Zip and the like keep it together), empty folders
# kept; zip files inside are stored as they are.
Write-Host ('Nen thanh ' + $zip + ' ...')
$zipPart = $zip + '.tmp'
if (Test-Path -LiteralPath $zipPart) { Remove-Item -LiteralPath $zipPart -Force }
$script:unfinished = @($out, $zipPart)
$base = (Resolve-Path -LiteralPath $out).ProviderPath.TrimEnd('\', '/')
$archive = [IO.Compression.ZipFile]::Open($zipPart, 'Create')
try {
    foreach ($entry in @(Get-ChildItem -LiteralPath $base -Recurse)) {
        $relative = $entry.FullName.Substring($base.Length + 1).Replace('\', '/')
        if ($entry.PSIsContainer) {
            if (@(Get-ChildItem -LiteralPath $entry.FullName -Force).Count -eq 0) { [void]$archive.CreateEntry($name + '/' + $relative + '/') }
            continue
        }
        $level = 'Optimal'
        if ($entry.Extension -ieq '.zip') { $level = 'NoCompression' }
        [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $entry.FullName, $name + '/' + $relative, $level)
    }
} finally { $archive.Dispose() }
[IO.File]::Move($zipPart, $zip)
$script:unfinished = @()

$size = (Get-Item -LiteralPath $zip).Length
Write-Host ''
Write-Host ('XONG. Gui file nay cho nguoi choi: ' + $zip + ' (' + [math]::Round($size / 1MB, 1) + ' MB)')
Write-Host ('Nguoi choi giai nen ca file zip, mo thu muc "' + $name + '", nhay dup "' + $exeName + '": khong cai gi them.')
Write-Host ('"' + $original + '" van la game goc cua ban mod (chi toi CRAZY!) - "' + $readmeName + '" dan nguoi choi.')
Write-Host 'Trong game, o dong muc kho bam qua CRAZY! la toi INSANE!, roi XOI.'
Write-Host ('Thu tren may nay: nhay dup "' + $exe + '".')
if ($env:OS -eq 'Windows_NT') {
    try { Start-Process -FilePath 'explorer.exe' -ArgumentList ('/select,"' + $zip + '"') } catch { }
}
exit 0
