param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('x86', 'x64', 'arm64')]
    [string]$Architecture
)

$ErrorActionPreference = 'Stop'

function Invoke-Checked {
    param([string]$Program, [string[]]$Arguments)
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Program failed with exit code $LASTEXITCODE"
    }
}

$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Set-Location $root
$conanArch = @{ x86 = 'x86'; x64 = 'x86_64'; arm64 = 'armv8' }[$Architecture]
$cmakeArch = @{ x86 = 'Win32'; x64 = 'x64'; arm64 = 'ARM64' }[$Architecture]
$build = Join-Path $root "build/windows/$Architecture"
$conanDir = Join-Path $build 'conan'
$nativeDir = Join-Path $build 'native'
$runtimeDir = Join-Path $build 'runtime'
$packageDir = Join-Path $root "out/OpenLF2-Windows-$Architecture"
New-Item -ItemType Directory -Force -Path $build, $packageDir | Out-Null

Invoke-Checked 'conan' @('profile', 'detect', '--force')
$cache = Join-Path $build 'conan-cache.tgz'
if (Test-Path $cache) {
    Invoke-Checked 'conan' @('cache', 'restore', $cache)
}
Invoke-Checked 'conan' @('export', 'conan/luajit')
Invoke-Checked 'conan' @(
    'install', '.', '--profile:host', 'default', '--profile:build', 'default',
    '--output-folder', $conanDir, '--build=missing',
    '--deployer=runtime_deploy', '--deployer-folder', $runtimeDir,
    '-s:h', "arch=$conanArch", '-s:h', 'build_type=Release',
    '-s:h', 'compiler.cppstd=23', '-s:h', 'compiler.runtime=dynamic',
    '-s:h', 'compiler.runtime_type=Release'
)
$nextCache = Join-Path $build 'conan-cache-next.tgz'
Invoke-Checked 'conan' @('cache', 'save', '*:*', '--no-source', "--file=$nextCache")
Move-Item -Force $nextCache $cache

$toolchain = Join-Path $conanDir 'conan_toolchain.cmake'
Invoke-Checked 'cmake' @(
    '-S', $root, '-B', $nativeDir, '-G', 'Visual Studio 17 2022', '-A', $cmakeArch,
    "-DCMAKE_TOOLCHAIN_FILE=$toolchain", '-DOPENLF2_DEPENDENCY_PROVIDER=conan'
)
Invoke-Checked 'cmake' @('--build', $nativeDir, '--config', 'Release', '--parallel', '4')

$binaryDir = Join-Path $nativeDir 'Release'
$dlls = @(Get-ChildItem -Path $runtimeDir -Filter '*.dll' -File -Recurse)
if ($dlls.Count -eq 0) { throw 'Conan did not deploy any runtime DLLs.' }

# The Visual C++ runtime goes beside openlf2.exe too, where Windows looks for a DLL before System32. A program needs a
# runtime at least as new as the compiler that built it (from MSVC 14.40 an older MSVCP140.dll crashes it as soon as it
# locks a std::mutex), and Windows may carry an old one: MSVCP140.dll 14.24 of 2019 closed the game at once, without a
# message, on the project owner's server. It is the redistributable of the Visual Studio that CMake built with.
$generatorInstance = Select-String -LiteralPath (Join-Path $nativeDir 'CMakeCache.txt') `
    -Pattern '^CMAKE_GENERATOR_INSTANCE:[A-Z]+=(.+)$' | Select-Object -First 1
$visualStudio = if ($generatorInstance) { $generatorInstance.Matches[0].Groups[1].Value } else {
    & (Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe') -latest -products '*' `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
}
if (-not $visualStudio) { throw 'The Visual Studio that built the game was not found.' }
$redistVersion = (Get-Content -TotalCount 1 -LiteralPath (
    Join-Path $visualStudio 'VC/Auxiliary/Build/Microsoft.VCRedistVersion.default.txt')).Trim()
$crtDir = Get-ChildItem -LiteralPath (Join-Path $visualStudio "VC/Redist/MSVC/$redistVersion/$Architecture") `
    -Directory -Filter 'Microsoft.VC*.CRT' | Sort-Object Name | Select-Object -Last 1
if (-not $crtDir) { throw "Visual Studio's redistributable $redistVersion has no Visual C++ runtime for $Architecture." }
$crtDlls = @(Get-ChildItem -LiteralPath $crtDir.FullName -Filter '*.dll' -File)
$compilerFile = Get-ChildItem -LiteralPath (Join-Path $nativeDir 'CMakeFiles') -Filter 'CMakeCXXCompiler.cmake' -File `
    -Recurse | Select-Object -First 1
$compilerVersion = [version](Select-String -LiteralPath $compilerFile.FullName `
    -Pattern 'set\(CMAKE_CXX_COMPILER_VERSION "([0-9.]+)"\)').Matches[0].Groups[1].Value
$runtime = (Get-Item -LiteralPath (Join-Path $crtDir.FullName 'msvcp140.dll')).VersionInfo
if ($runtime.FileMinorPart -lt $compilerVersion.Minor) {
    throw "The Visual C++ runtime in $($crtDir.FullName) ($($runtime.FileVersion)) is older than the compiler ($compilerVersion)."
}
Write-Host "Visual C++ runtime $($runtime.FileVersion) for compiler $compilerVersion, from $($crtDir.FullName):" `
    (($crtDlls | ForEach-Object Name) -join ', ')
$dlls += $crtDlls
foreach ($dll in $dlls) {
    Copy-Item -Force $dll.FullName $binaryDir
}

Copy-Item -Force (Join-Path $binaryDir 'openlf2.exe') $packageDir
foreach ($dll in $dlls) { Copy-Item -Force $dll.FullName $packageDir }
Copy-Item -Recurse -Force (Join-Path $root 'scripts') $packageDir
Copy-Item -Force (Join-Path $root 'README.md') $packageDir
Copy-Item -Force (Join-Path $root 'LICENSE') $packageDir
Invoke-Checked 'python' @((Join-Path $root 'dist/collect-licenses.py'),
    (Join-Path $packageDir 'licenses'), '--key', 'ffmpeg', '--key', 'ffmpeg-notes', '--key', 'sdl3',
    '--key', 'sdl3-ttf', '--key', 'freetype', '--key', 'luajit', '--key', 'zlib', '--key', 'bzip2', '--key', 'openssl',
    '--key', 'libcurl')

# The installer (Inno Setup, dist/windows/openlf2.iss) is the artifact; the staged package above is its content.
$version = (Select-String -Path (Join-Path $root 'CMakeLists.txt') -Pattern '^project\(OpenLF2 VERSION ([0-9]+\.[0-9]+\.[0-9]+)').Matches[0].Groups[1].Value
if (-not $version) { throw 'The project version was not found in CMakeLists.txt.' }

# Wizard pictures and the icon, drawn from the project's SVG.
$iconDir = Join-Path $build 'icons'
Invoke-Checked 'python' @((Join-Path $root 'tools/icons/make_icons.py'), $iconDir)

# Inno Setup has no Chinese message files; the unofficial ones are pinned to the Inno Setup release.
$innoTag = 'is-6_7_1'
$languageDir = Join-Path $build 'languages'
New-Item -ItemType Directory -Force -Path $languageDir | Out-Null
$languages = @{
    'ChineseSimplified.isl'  = '7d544b9bb1d142cfa11f2e5d3cc8abe2e55f8e066c5124e3772675aa236e1278'
    'ChineseTraditional.isl' = 'ab22b0ebf82969d1c9a7208e0e9f60e5119c0c95b9dacc00eb8e5582c7d3c604'
}
foreach ($name in $languages.Keys) {
    $target = Join-Path $languageDir $name
    if (-not (Test-Path $target) -or (Get-FileHash -Algorithm SHA256 $target).Hash.ToLowerInvariant() -ne $languages[$name]) {
        Invoke-WebRequest -UseBasicParsing -Uri "https://raw.githubusercontent.com/jrsoftware/issrc/$innoTag/Files/Languages/Unofficial/$name" -OutFile $target
    }
    $actual = (Get-FileHash -Algorithm SHA256 $target).Hash.ToLowerInvariant()
    if ($actual -ne $languages[$name]) { throw "$name has an unexpected SHA-256 ($actual)." }
}

# The GitHub runner image ships Inno Setup; elsewhere it is installed from Chocolatey.
function Find-InnoSetup {
    $found = (Get-Command 'ISCC.exe' -ErrorAction SilentlyContinue).Source
    if ($found) { return $found }
    return @("${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe", "$env:ProgramFiles\Inno Setup 6\ISCC.exe") |
        Where-Object { Test-Path $_ } | Select-Object -First 1
}
$iscc = Find-InnoSetup
if (-not $iscc) {
    Invoke-Checked 'choco' @('install', 'innosetup', '--no-progress', '-y')
    $iscc = Find-InnoSetup
}
if (-not $iscc) { throw 'Inno Setup (ISCC.exe) is not installed.' }
$installerBase = "OpenLF2-Windows-$Architecture"
Invoke-Checked $iscc @('/Qp', "/DAppVersion=$version", "/DArch=$Architecture", "/DStageDir=$packageDir",
    "/DIconDir=$iconDir", "/DLanguageDir=$languageDir", "/DOutputDir=$(Join-Path $root 'out')",
    "/DOutputBase=$installerBase", (Join-Path $root 'dist/windows/openlf2.iss'))
$installer = Join-Path $root "out/$installerBase.exe"
$hash = (Get-FileHash -Algorithm SHA256 $installer).Hash.ToLowerInvariant()
Set-Content -Path "$installer.sha256" -Value "$hash  $(Split-Path -Leaf $installer)"
Write-Host "Created $installer"
