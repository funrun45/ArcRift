# Release 1.2.1: find an earlier ArcRift session that never finished cleanup, so it can be restored automatically.
# This happens when the PC is shut down, restarted, crashes or loses power during a session (Windows ends the session
# window and its recovery watcher before they can restore anything), or when the session window is closed.
# Looks in this folder, in the folder of the bridge Meta is still configured to use, and in sibling ArcRift folders
# (an older copy such as ArcRift-Release-1.1 next to this one). Changes no settings itself.
# Release 1.3: the one thing it does remove is a leftover session marker (active-test.xml) that no longer stands for
# anything to restore; see Remove-ArcRiftStaleMarker. Before, such a marker blocked Start, Recover and Clear for good.
if (-not (Get-Command Get-ArcRiftMetaRuntimePath -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'install-paths.ps1') }

function Test-ArcRiftSessionOwnerRunning($State) {
    $owner = Get-Process -Id $State.OwnerPid -ErrorAction SilentlyContinue
    return [bool]($owner -and $owner.StartTime.ToUniversalTime().ToFileTimeUtc().ToString() -eq $State.OwnerCreated)
}

function Test-ArcRiftLockHeld([string]$Package) {
    $path = Join-Path $Package 'active-test.lock'
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    try { $f = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite); $f.Dispose(); return $false }
    catch { return $true }
}

# Is the session window that wrote this marker still open? Same test as stop-arc-rift.ps1: a program that later reused
# the PID started after the marker was written.
function Test-ArcRiftMarkerHarnessRunning($Session) {
    if (-not $Session.HarnessPid) { return $false }
    $harness = Get-Process -Id $Session.HarnessPid -ErrorAction SilentlyContinue
    if (-not $harness) { return $false }
    $created = $null; try { $created = $harness.StartTime } catch { }
    return -not ($created -and $Session.Started -and $created -gt $Session.Started.AddSeconds(5))
}

# True only when none of the things a session changes is in place: Meta is not pointed at an ArcRift bridge, no Meta
# plugin is renamed, and the headset from this folder's Setup has no temporary display mode. Anything unclear counts
# as "something may be applied".
function Test-ArcRiftNothingApplied([string]$Package) {
    try {
        $dll = (Get-ItemProperty 'HKLM:\SOFTWARE\Oculus' -ErrorAction SilentlyContinue).DirectDisplayDLL
        if ($dll -and [IO.Path]::GetFileName([string]$dll) -like 'arc_rift_bridge*.dll') { return $false }
        $plugins = Join-Path (Get-ArcRiftMetaRuntimePath) 'server-plugins'
        if (@(Get-ChildItem -LiteralPath $plugins -Filter '*.arc-rift-d3d11-disabled' -ErrorAction Stop).Count) { return $false }
        $instance = [string](Get-Content -LiteralPath (Join-Path $Package 'arcrift-config.json') -Raw -ErrorAction Stop | ConvertFrom-Json).monitorInstance
        if ($instance -notmatch '^(?i)DISPLAY\\[^\\]+\\[^\\]+$') { return $false }
        if (Test-Path -LiteralPath ('HKLM:\SYSTEM\CurrentControlSet\Enum\' + $instance + '\Device Parameters\EDID_OVERRIDE')) { return $false }
        return $true
    } catch { return $false }
}

# Release 1.3: removes a session marker that has nothing left to restore, and returns why (or $null if it was kept).
# Two cases, both only when that session's window is closed and no recovery is running:
#   * the session was restored, but its marker was never removed (window closed at the very end), or
#   * the session was ended in its first seconds, before it recorded or changed anything (it has no
#     manual-recovery-state.json, and nothing of ArcRift is applied).
# OnlySession: remove the marker only if it belongs to that session folder.
function Remove-ArcRiftStaleMarker([string]$Package, [string]$OnlySession) {
    $marker = Join-Path $Package 'active-test.xml'
    if (-not (Test-Path -LiteralPath $marker)) { return $null }
    $session = Import-Clixml -LiteralPath $marker
    $dir = [IO.Path]::GetFullPath([string]$session.SessionDirectory).TrimEnd('\')
    if ($OnlySession -and $dir -ne [IO.Path]::GetFullPath($OnlySession).TrimEnd('\')) { return $null }
    if ((Test-ArcRiftMarkerHarnessRunning $session) -or (Test-ArcRiftLockHeld $Package)) { return $null }
    $statePath = Join-Path $dir 'manual-recovery-state.json'
    $reason = $null
    if (Test-Path -LiteralPath $statePath) {
        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        if ($state.CleanupVerified -and -not (Test-ArcRiftSessionOwnerRunning $state)) { $reason = 'it was already restored' }
    } elseif (Test-ArcRiftNothingApplied $Package) { $reason = 'it stopped before it changed anything' }
    if (-not $reason) { return $null }
    # ArcRift Control reads the marker every 2 s; retry if it happens to be open right now.
    for ($try = 1; ; $try++) {
        try { Remove-Item -LiteralPath $marker -ErrorAction Stop; break }
        catch { if ($try -ge 5) { return $null }; Start-Sleep -Milliseconds 200 }
    }
    Remove-Item -LiteralPath (Join-Path $Package 'active-test.lock') -ErrorAction SilentlyContinue
    return $reason
}

function Find-ArcRiftLeftoverSession([string]$Root) {
    $candidates = @($Root)
    $dll = (Get-ItemProperty 'HKLM:\SOFTWARE\Oculus' -ErrorAction SilentlyContinue).DirectDisplayDLL
    if ($dll -and [IO.Path]::GetFileName([string]$dll) -like 'arc_rift_bridge*.dll') { $candidates += [IO.Path]::GetDirectoryName([string]$dll) }
    $parent = Split-Path -Parent $Root
    if ($parent) {
        foreach ($d in @(Get-ChildItem -LiteralPath $parent -Directory -ErrorAction SilentlyContinue)) {
            if (Test-Path -LiteralPath (Join-Path $d.FullName 'active-test.xml')) { $candidates += $d.FullName }
        }
    }
    $seen = @{}
    foreach ($c in $candidates) {
        $pkg = [IO.Path]::GetFullPath($c).TrimEnd('\')
        if ($seen.ContainsKey($pkg.ToLowerInvariant())) { continue }
        $seen[$pkg.ToLowerInvariant()] = $true
        $marker = Join-Path $pkg 'active-test.xml'
        if (-not (Test-Path -LiteralPath $marker)) { continue }
        if (-not (Test-Path -LiteralPath (Join-Path $pkg 'test-ovr-d3d11.ps1'))) { continue }
        $session = Import-Clixml -LiteralPath $marker
        $dir = [IO.Path]::GetFullPath([string]$session.SessionDirectory).TrimEnd('\')
        $statePath = Join-Path $dir 'manual-recovery-state.json'
        if (-not (Test-Path -LiteralPath $statePath)) {
            # Release 1.3: a session ended in its first seconds leaves only its marker; nothing to restore then.
            $why = Remove-ArcRiftStaleMarker $pkg
            if ($why) { Write-Host ('Removed a leftover session marker in ' + $pkg + ': ' + $why + '.'); continue }
            throw ('An earlier ArcRift session in ' + $pkg + ' was not restored and cannot be restored automatically. Run RECOVER.cmd in that folder; no changes made.')
        }
        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        if ($state.CleanupVerified) {
            # Release 1.3: restored, but its marker was never removed. Retire the marker so it cannot block Start.
            $why = Remove-ArcRiftStaleMarker $pkg
            if ($why) { Write-Host ('Removed a leftover session marker in ' + $pkg + ': ' + $why + '.') }
            continue
        }
        if (Test-ArcRiftSessionOwnerRunning $state) {
            throw ('An ArcRift session from ' + $pkg + ' is still running. Use Stop & restore for that session first; no changes made.')
        }
        if (Test-ArcRiftLockHeld $pkg) {
            throw 'The last session is being restored right now. Wait for it to finish, then press Start again; no changes made.'
        }
        return [pscustomobject]@{ Package = $pkg; SessionDirectory = $dir; Foreign = ($pkg -ne [IO.Path]::GetFullPath($Root).TrimEnd('\')) }
    }
    return $null
}
