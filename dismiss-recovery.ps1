# Release 1.1.2: way out of "Needs recovery" when Recover restored everything but the display layout no longer matches
# the one recorded at session start (e.g. a monitor was added, removed or turned off). Changes no settings: it only
# re-checks that registry, EDID and Meta plugins are back to their originals, then retires the session marker.
$ErrorActionPreference = 'Stop'
trap { Write-Output $_.Exception.Message; exit 1 } # plain message for ArcRift Control, not a PowerShell error dump
$root = $PSScriptRoot
$marker = Join-Path $root 'active-test.xml'
if (-not (Test-Path -LiteralPath $marker)) { Write-Output 'No session needs recovery.'; exit 0 }
$session = Import-Clixml -LiteralPath $marker
$full = [IO.Path]::GetFullPath($session.SessionDirectory).TrimEnd('\')
if ([IO.Path]::GetDirectoryName($full) -ne $root -or [IO.Path]::GetFileName($full) -notmatch '^d3d11-\d{8}-\d{6}$') { throw 'Session folder is not inside this package; nothing changed.' }
$state = Get-Content -LiteralPath (Join-Path $full 'manual-recovery-state.json') -Raw | ConvertFrom-Json
$owner = Get-Process -Id $state.OwnerPid -ErrorAction SilentlyContinue
if ($owner -and $owner.StartTime.ToUniversalTime().ToFileTimeUtc().ToString() -eq $state.OwnerCreated) { throw 'The session window is still open. Use Stop & restore instead.' }
if (-not (Get-ChildItem -LiteralPath $full -Filter 'manual-recovery-2*.txt')) { throw 'Recover has not been run for this session yet. Press Recover first.' }
$lock = $null
try { $lock = [IO.File]::Open((Join-Path $root 'active-test.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::Write, [IO.FileShare]::None) }
catch { throw 'Recovery is running right now. Wait for it to finish.' }
try {
    $problems = @()
    foreach ($r in @(Import-Clixml (Join-Path $full 'registry-backup.xml'))) {
        $k = Get-Item $r.Path -ErrorAction SilentlyContinue
        $had = $k -and ($k.GetValueNames() -contains $r.Name)
        if ([bool]$had -ne $r.Had -or ($r.Had -and ($k.GetValue($r.Name) -ne $r.Value -or $k.GetValueKind($r.Name).ToString() -ne $r.Kind))) { $problems += ('Meta setting ' + $r.Name + ' is not back to its original value') }
    }
    $edid = Import-Clixml (Join-Path $full 'edid-backup.xml')
    if (Test-Path -LiteralPath ('HKLM:\SYSTEM\CurrentControlSet\Enum\' + $edid.Instance + '\Device Parameters\EDID_OVERRIDE')) { $problems += 'the temporary headset display mode (EDID override) is still applied' }
    foreach ($p in @(Import-Clixml (Join-Path $full 'plugins-backup.xml'))) {
        if ((Test-Path -LiteralPath $p.Temporary) -or -not (Test-Path -LiteralPath $p.Original) -or (Get-FileHash -LiteralPath $p.Original -Algorithm SHA256).Hash -ne $p.Hash) { $problems += ('Meta plugin ' + [IO.Path]::GetFileName($p.Original) + ' is not restored') }
    }
    if ((Get-Service OVRService).Status -ne 'Running') { $problems += 'the Meta runtime service is not running' }
    if ($problems.Count) { throw ('Not cleared, because ' + ($problems -join '; ') + '. Press Recover again with the headset plugged in.') }
    ('Cleared by user at ' + (Get-Date).ToString('o') + ': registry, EDID, plugins and Meta service verified restored; display layout differed from the session start and was accepted by the user.') | Set-Content -LiteralPath (Join-Path $full 'recovery-dismissed.txt')
    Move-Item -LiteralPath $marker -Destination (Join-Path $full 'active-test-dismissed.xml')
    Write-Output 'Cleared. Meta settings, headset display mode and plugins are restored; check your monitor layout in Windows display settings.'
} finally {
    if ($lock) { $lock.Dispose(); Remove-Item -LiteralPath (Join-Path $root 'active-test.lock') -ErrorAction SilentlyContinue }
}
