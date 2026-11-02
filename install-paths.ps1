# Release 1.1.2: finds where Steam, SteamVR and Meta's runtime are installed instead of assuming the default folders.
# Read-only; no process, registry or file changes.
function Get-ArcRiftSteamPath {
    $candidates = @((Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath)
    foreach ($key in 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam') {
        $candidates += (Get-ItemProperty $key -ErrorAction SilentlyContinue).InstallPath
    }
    $candidates += Join-Path ${env:ProgramFiles(x86)} 'Steam'
    foreach ($candidate in $candidates) {
        if (-not $candidate) { continue }
        $path = [IO.Path]::GetFullPath(($candidate -replace '/', '\')).TrimEnd('\')
        if (Test-Path -LiteralPath (Join-Path $path 'steam.exe')) { return $path }
    }
    throw 'Steam was not found. Install Steam and SteamVR normally, then try again.'
}

function Get-ArcRiftSteamVRPath([string]$SteamPath) {
    # SteamVR can live in any Steam library folder, not only the one next to steam.exe.
    $libraries = @($SteamPath)
    $libraryFile = Join-Path $SteamPath 'steamapps\libraryfolders.vdf'
    if (Test-Path -LiteralPath $libraryFile) {
        foreach ($m in [regex]::Matches((Get-Content -LiteralPath $libraryFile -Raw), '"path"\s+"([^"]+)"')) {
            $libraries += ($m.Groups[1].Value -replace '\\\\', '\')
        }
    }
    foreach ($library in $libraries) {
        $steamVR = Join-Path $library 'steamapps\common\SteamVR'
        if (Test-Path -LiteralPath (Join-Path $steamVR 'bin\win64\vrstartup.exe')) { return [IO.Path]::GetFullPath($steamVR).TrimEnd('\') }
    }
    throw 'SteamVR was not found in any Steam library. Install SteamVR from Steam, then try again.'
}

function Get-ArcRiftMetaRuntimePath {
    # Meta's runtime folder (...\Support\oculus-runtime): from its service registration, then its install record.
    $image = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\OVRService' -ErrorAction SilentlyContinue).ImagePath
    $folders = @()
    if ($image -match '^\s*"?([^"]+)\\OVRServiceLauncher\.exe') { $folders += $matches[1] }
    $base = (Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Oculus VR, LLC\Oculus' -ErrorAction SilentlyContinue).Base
    foreach ($b in @($base, (Join-Path $env:ProgramFiles 'Meta Horizon'), (Join-Path $env:ProgramFiles 'Oculus'))) {
        if ($b) { $folders += Join-Path $b 'Support\oculus-runtime' }
    }
    foreach ($folder in $folders) {
        if (Test-Path -LiteralPath (Join-Path $folder 'server-plugins')) { return [IO.Path]::GetFullPath($folder).TrimEnd('\') }
    }
    throw 'The Meta Horizon (Oculus) PC app was not found. Install it, then try again.'
}
