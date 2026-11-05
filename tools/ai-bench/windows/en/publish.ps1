# SPDX-License-Identifier: MIT
# Copyright (c) 2026 OpenLF2 contributors
#
# The work of publish.bat ("publish", in the XOI kit): a mod made ready for its players. The mod's own folder, as its
# author shares it (bg, bgm, data, sprite and the rest, its own .exe too), with OpenLF2 put in it: the program as
# "<name> - INSANE XOI.exe", its libraries, scripts and licences, and XOI's notes and numbers in xoi\. OpenLF2 (package
# 50 on) plays the game folder it lies in when started without --pack, so a player unpacks the folder and double-clicks
# the program, with every level up to INSANE! and XOI. The folder is tried once without a window, then zipped for
# sharing. publish.bat passes its settings and what was dragged onto it as XB_* environment variables. Messages are
# plain ASCII English, as in the kit's batch files (a console's code page may not show anything else). It also runs
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
    Write-Host ('[ERROR] ' + $text)
    exit 1
}
trap { Fail ('Error while publishing: ' + [string]$_.Exception.Message) }
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
# Hidden fighters locked for the players (Y) or not (N, or not set): openlf2.txt beside the mod's data folder, which
# OpenLF2 (package 48 on) reads - no options on the title screen, the option to unlock and LF2.NET doing nothing.
$lock = ([string]$env:XB_KHOA_AN).Trim().ToUpper() -eq 'Y'

# The mod: set or dragged; else the first *-xoi.zip beside the kit (with XOI's notes and numbers inside), then the first
# other .zip (not an older copy kept by spsa.bat, an update package or the kit itself).
if (-not $pack) {
    $zips = @(Get-ChildItem -LiteralPath $kit -File | Where-Object { $_.Extension -ieq '.zip' } | Sort-Object Name)
    $pick = @($zips | Where-Object { $_.BaseName -match '-xoi$' }) +
        @($zips | Where-Object { $_.BaseName -notmatch '-xoi(-previous)?$' -and $_.Name -notmatch '^(lf2-online-upload|xoi-kit)' })
    if ($pick.Count -eq 0) { Fail 'No mod found: put the zip file of the mod next to publish.bat and run it again, or drag the zip file / folder of the mod onto publish.bat.' }
    $pack = $pick[0].FullName
}
if (-not (Test-Path -LiteralPath $pack)) { Fail ('"' + $pack + '" not found - fix the PACK line at the top of publish.bat.') }
$item = Get-Item -LiteralPath $pack
if (-not $item.PSIsContainer -and $item.Extension -ieq '.exe') { $item = $item.Directory }
$isFolder = [bool]$item.PSIsContainer
if (-not $isFolder -and $item.Extension -ine '.zip') {
    Fail ('"' + $item.FullName + '" is not a zip file. OpenLF2 reads a mod as a .zip file or a folder: extract a .rar / .7z file first (with 7-Zip), then drag the mod folder onto publish.bat.')
}
if ($isFolder) { $modName = $item.Name } else { $modName = $item.BaseName }
$isXoiZip = (-not $isFolder) -and ($modName -match '-xoi$')
$plain = $modName -replace '-xoi$', ''
if (-not $name) { $name = $plain }
if ($name.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or $name -match '^\.*$' -or $name -match '[. ]$') {
    Fail ('The name "' + $name + '" cannot be a file name (none of \ / : * ? " < > |, no dot or space at the end): fix the NAME line at the top of publish.bat.')
}
# The program the players double-click, beside the mod's own .exe (the original LF2, up to CRAZY!): its name says it is
# the one with INSANE! and XOI.
$exeName = $name + ' - INSANE XOI.exe'
$readmeName = 'README - INSANE XOI.txt'

# XOI's notes (train.bat) and numbers (spsa.bat): set or dragged; else xoi-<mod>\ beside the kit, where those two
# write them. A *-xoi.zip has its own inside, and they stay as they are unless set.
$xoiDir = Join-Path $kit ('xoi-' + $plain)
if (-not $isXoiZip) {
    if (-not $notes -and (Test-File (Join-Path $xoiDir 'notes.txt'))) { $notes = Join-Path $xoiDir 'notes.txt' }
    if (-not $notes -and (Test-File (Join-Path $kit ($plain + '-notes.txt')))) { $notes = Join-Path $kit ($plain + '-notes.txt') }
    if (-not $tune -and (Test-File (Join-Path $xoiDir 'tune.txt'))) { $tune = Join-Path $xoiDir 'tune.txt' }
}
foreach ($file in @($notes, $tune)) {
    if ($file -and -not (Test-File $file)) { Fail ('"' + $file + '" not found - fix the NOTES / TUNE line at the top of publish.bat.') }
}

# The installed game: set, or where the installer puts it (for me only, for all users), or OpenLF2\ beside the kit.
if (-not $game) {
    $places = @()
    if ($env:LOCALAPPDATA) { $places += Under $env:LOCALAPPDATA 'Programs' 'OpenLF2' 'openlf2.exe' }
    if (${env:ProgramFiles(x86)}) { $places += Under ${env:ProgramFiles(x86)} 'OpenLF2' 'openlf2.exe' }
    if ($env:ProgramFiles) { $places += Under $env:ProgramFiles 'OpenLF2' 'openlf2.exe' }
    $places += Under $kit 'OpenLF2' 'openlf2.exe'
    foreach ($place in $places) { if (-not $game -and (Test-File $place)) { $game = $place } }
    if (-not $game) { Fail 'OpenLF2 is not installed: get the OpenLF2-Windows-x64.exe installer (package 50 or later) under Releases on the GitHub page of the project, choose Install for me only, then run this again.' }
}
if (-not (Test-File $game)) { Fail ('Game not found at "' + $game + '" - fix the GAME line at the top of publish.bat.') }
$game = (Resolve-Path -LiteralPath $game).ProviderPath
$gameDir = Split-Path -Parent $game
$gameScripts = Join-Path $gameDir 'scripts'
if (-not (Test-File (Under $gameScripts 'base' 'game' 'match.lua'))) { Fail ('The game folder "' + $gameDir + '" has no scripts\base\game\match.lua: reinstall OpenLF2.') }

$outRoot = Join-Path $kit 'publish'
$out = Join-Path $outRoot $name
$zip = Join-Path $outRoot ($name + '.zip')
$log = Join-Path $outRoot ($name + '-check.txt')
Write-Host ('Mod:       ' + $item.FullName)
Write-Host ('Game:      ' + $game)
Write-Host ('Published: ' + $out)
[void][IO.Directory]::CreateDirectory($outRoot)
if (Test-Path -LiteralPath $out) {
    try { Remove-Item -LiteralPath $out -Recurse -Force }
    catch { Fail ('Could not delete the old published folder "' + $out + '": close a game running from it and any window showing it, then run this again.') }
}
if (Test-Path -LiteralPath $zip) {
    try { Remove-Item -LiteralPath $zip -Force }
    catch { Fail ('Could not delete the old file "' + $zip + '": close the program that has it open, then run this again.') }
}
[void][IO.Directory]::CreateDirectory($out)
$script:unfinished = @($out)

# The mod's own folder, as its author shares it: the folder holding data\data.txt nearest the top of the zip or of the
# folder dragged, every file and folder of it (empty ones too: the original's recording folder, say). XOI's notes and
# numbers set for it, and its settings for OpenLF2 (openlf2.txt), are written after.
Write-Host 'Copying the mod (its whole folder, as shared) ...'
function Test-Later([string]$relative) {
    $relative = $relative.Replace('\', '/')
    return ($notes -and $relative -ieq 'xoi/notes.txt') -or ($tune -and $relative -ieq 'xoi/tune.txt') -or ($relative -ieq 'openlf2.txt')
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
if ($null -eq $source) { Fail ('"' + $item.FullName + '" has no data\data.txt: this is not an LF2 mod (or its folder / zip file).') }
if ($isFolder) {
    foreach ($entry in @(Get-ChildItem -LiteralPath $source -Recurse)) {
        $relative = $entry.FullName.Substring($source.Length + 1)
        $target = Join-Path $out $relative
        if ($entry.PSIsContainer) { [void][IO.Directory]::CreateDirectory($target); continue }
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
            if (Test-Later $relative) { continue }
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $target))
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
        }
    } finally { $archive.Dispose() }
}
if ($skipped -gt 0) { Write-Host ('  [NOTE] ' + $skipped + ' file(s) in the zip have names Windows cannot take - left out') }

# OpenLF2: the program under its own name, its libraries, scripts and licences.
Write-Host 'Adding OpenLF2 ...'
$exe = Join-Path $out $exeName
[IO.File]::Copy($game, $exe, $true)
foreach ($dll in @(Get-ChildItem -LiteralPath $gameDir -File | Where-Object { $_.Extension -ieq '.dll' })) {
    [IO.File]::Copy($dll.FullName, (Join-Path $out $dll.Name), $true)
}
# The scripts: the kit's (all of the game's, as the kit was made) when their computer players are newer than the
# installed game's, as play.bat plays, so the published mod plays with the players it was trained with; else the
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
            Fail 'Locking the hidden fighters needs scripts from package 49 or later: both the installed game and the scripts folder next to publish.bat are older. Put the scripts folder of the latest package next to publish.bat (or install a new OpenLF2), then run this again.'
        }
    }
}
if ($useKit) {
    Copy-Tree $kitScripts (Join-Path $out 'scripts')
    Write-Host ('INSANE!/XOI players version ' + $newer + ', scripts of the XOI kit (installed game: version ' + $installed + ')')
} else {
    Copy-Tree $gameScripts (Join-Path $out 'scripts')
    Write-Host ('INSANE!/XOI players version ' + $installed + ', scripts of the installed game')
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
foreach ($pair in @(@($notes, 'notes.txt'), @($tune, 'tune.txt'))) {
    if (-not $pair[0]) { continue }
    $target = Under $out 'xoi' $pair[1]
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $target))
    [IO.File]::Copy($pair[0], $target, $true)
    Write-Host ('  added xoi\' + $pair[1] + ' <- ' + $pair[0])
}
$notesFile = Under $out 'xoi' 'notes.txt'
if (Test-File $notesFile) { Write-Host ('XOI notes: yes (' + [math]::Ceiling((Get-Item -LiteralPath $notesFile).Length / 1KB) + ' KB)') }
else { Write-Host 'XOI notes: none - XOI still plays, but without notes of training for this mod (train.bat makes them)' }
if (Test-File (Under $out 'xoi' 'tune.txt')) { Write-Host 'XOI numbers tuned for this mod: yes' }
else { Write-Host 'XOI numbers tuned for this mod: none - XOI uses the shared numbers (spsa.bat tunes numbers for a mod)' }
# The mod's settings for OpenLF2: written when locking, left out otherwise (the publisher's choice).
if ($lock) {
    [IO.File]::WriteAllText((Join-Path $out 'openlf2.txt'),
        "# OpenLF2: this mod's settings for OpenLF2 (written by publish.bat)`r`n" +
        "# Hidden fighters locked: no options button, typing lf2.net does not unlock them`r`n" +
        "hidden_characters = locked`r`noptions = hidden`r`n", (New-Object Text.UTF8Encoding $false))
    Write-Host 'Hidden fighters: LOCKED - no options button on the title screen, typing lf2.net does not unlock them; CRAZY!, INSANE! and XOI can still be chosen'
} else {
    Write-Host 'Hidden fighters: as usual - the players can unlock them (options, lf2.net)'
}

# Tried once as a player starts it, without a window: the program must play the folder it lies in by itself.
Write-Host 'Trying the published mod (no window) ...'
$errors = $log + '.err'
foreach ($file in @($log, $errors)) { if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force } }
$process = Start-Process -FilePath $exe -ArgumentList '--input-trace "" --seed 1' -WorkingDirectory $out -NoNewWindow -PassThru `
    -RedirectStandardOutput $log -RedirectStandardError $errors
$null = $process.Handle
if (-not $process.WaitForExit(300000)) {
    try { $process.Kill() } catch { }
    Fail ('The published mod ran for over 5 minutes without finishing - see ' + $log)
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
    Fail ('The installed OpenLF2 (' + $game + ') is an old one: it does not play the mod folder it lies in by itself. Install a new one (OpenLF2-Windows-x64.exe under Releases, package 50 or later), then run publish.bat again.')
}
# A picture, sound or piece of music the game cannot read is left out, as in its window, and the game plays on
# ("Picture ...; left out", "Music ...", "Sound ...": Sx2's missing bgm/main.wma, Convergence's 8 KB tracks).
$pictures = @($lines | Where-Object { $_ -match '^(Picture|Music|Sound) .+; left out$' })
if (-not ($found -and $process.ExitCode -eq 0 -and $output -match 'Indexed ')) {
    Write-Host ''
    foreach ($line in @($lines | Select-Object -Last 6)) { Write-Host ('  ' + $line) }
    Fail ('The published mod could not open the mod (the lines above, also in ' + $log + '). If the mod plays with play.bat, send that file to whoever maintains OpenLF2.')
}
$folderLine = [string](@($lines | Where-Object { $_ -cmatch '^Game folder ' }) | Select-Object -First 1)
Write-Host ('  ' + $folderLine)
if ($pictures.Count -gt 0) {
    Write-Host '  [NOTE] Some pictures / music / sounds cannot be read - the game leaves them out and plays on (as with play.bat):'
    foreach ($line in @($pictures | Select-Object -First 5)) { Write-Host ('    ' + $line) }
    Write-Host ('    For the game to read them: send the file ' + $log + ' to whoever maintains OpenLF2.')
}
# The mod's own program, as the game found it (", executable <name>", in lowercase), by its name in the folder.
$original = 'the original .exe file of the mod'
if ($folderLine -match ', executable (.+)$') {
    $lower = $Matches[1]
    $original = $lower
    foreach ($file in @(Get-ChildItem -LiteralPath $out -File)) { if ($file.Name -ieq $lower) { $original = $file.Name; break } }
}

# A few words for the players, from publish-README.txt beside the kit ({TEN}: the name, {EXE}: the program, {GOC}: the
# mod's own .exe), beside the mod's own readme.
$template = Join-Path $kit 'publish-README.txt'
if (Test-File $template) {
    $text = [IO.File]::ReadAllText($template, [Text.Encoding]::UTF8).Replace('{TEN}', $name).Replace('{EXE}', $exeName).Replace('{GOC}', $original)
} else {
    $text = $name + " - OpenLF2, INSANE! and XOI`r`n`r`nExtract the whole zip, then double-click " + $exeName + ".`r`n" +
        "Difficulty: past CRAZY! come INSANE!, then XOI.`r`n" +
        $original + " is the mod's original game (up to CRAZY!).`r`n"
}
[IO.File]::WriteAllText((Join-Path $out $readmeName), $text, (New-Object Text.UTF8Encoding $true))

# The folder zipped, its own name at the top (Windows' Extract All, 7-Zip and the like keep it together), empty folders
# kept; zip files inside are stored as they are.
Write-Host ('Zipping into ' + $zip + ' ...')
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
Write-Host ('DONE. Send this file to the players: ' + $zip + ' (' + [math]::Round($size / 1MB, 1) + ' MB)')
Write-Host ('The players extract the whole zip, open the "' + $name + '" folder and double-click "' + $exeName + '": nothing to install.')
Write-Host ('"' + $original + '" remains the original game of the mod (up to CRAZY! only) - "' + $readmeName + '" tells the players.')
Write-Host 'In the game, cycle the difficulty past CRAZY! to INSANE!, then XOI.'
Write-Host ('To try it on this PC: double-click "' + $exe + '".')
if ($env:OS -eq 'Windows_NT') {
    try { Start-Process -FilePath 'explorer.exe' -ArgumentList ('/select,"' + $zip + '"') } catch { }
}
exit 0
