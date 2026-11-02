# Full session recovery from THIS package's saved backups, never a generic reset.
param([string]$SessionDirectory)
$ErrorActionPreference='Stop'
$root=$PSScriptRoot
if (-not $SessionDirectory) {
    $marker=Import-Clixml (Join-Path $root 'active-test.xml')
    $SessionDirectory=$marker.SessionDirectory
}
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $args='-NoProfile -ExecutionPolicy Bypass -File "'+$PSCommandPath+'" -SessionDirectory "'+$SessionDirectory+'"'
    $p=Start-Process powershell.exe -Verb RunAs -ArgumentList $args -PassThru
    $null=$p.Handle; $p.WaitForExit(); exit $p.ExitCode
}
function Stop-ArcRiftMetaRuntime([int]$TimeoutSeconds = 20) {
    # Stop Meta's runtime without waiting forever: if it hangs, end its processes so rollback can continue.
    $null = & sc.exe stop OVRService
    $svcDeadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Service OVRService).Status -ne 'Stopped' -and (Get-Date) -lt $svcDeadline) { Start-Sleep -Milliseconds 500 }
    if ((Get-Service OVRService).Status -ne 'Stopped') {
        Write-Output ('Meta runtime did not stop within ' + $TimeoutSeconds + 's; ending its processes so rollback can continue.')
        Get-Process OVRServer_x64,OVRServiceLauncher -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        $svcDeadline = (Get-Date).AddSeconds(15)
        while ((Get-Service OVRService).Status -ne 'Stopped' -and (Get-Date) -lt $svcDeadline) { Start-Sleep -Milliseconds 500 }
    }
    if ((Get-Service OVRService).Status -ne 'Stopped') { throw 'Meta runtime service could not be stopped.' }
}
. (Join-Path $root 'install-paths.ps1')
. (Join-Path $root 'session-recovery-policy.ps1')
$full=[IO.Path]::GetFullPath($SessionDirectory).TrimEnd('\')
if ([IO.Path]::GetDirectoryName($full) -ne $root -or [IO.Path]::GetFileName($full) -notmatch '^d3d11-\d{8}-\d{6}$') { throw 'Recovery session must be inside this package.' }
$statePath=Join-Path $full 'manual-recovery-state.json'
$state=Get-Content $statePath -Raw | ConvertFrom-Json
if (-not $state.ManualSession -or $state.Root -ne $root) { throw 'Manual-session recovery identity mismatch.' }
if ($state.CleanupVerified) { Write-Output 'Session already restored; nothing changed.'; exit 0 }
$owner=Get-Process -Id $state.OwnerPid -ErrorAction SilentlyContinue
if ($owner -and $owner.StartTime.ToUniversalTime().ToFileTimeUtc().ToString() -eq $state.OwnerCreated) { throw 'Harness still running. Use STOP instead of recovery.' }
$registry=@(Import-Clixml (Join-Path $full 'registry-backup.xml'))
$plugins=@(Import-Clixml (Join-Path $full 'plugins-backup.xml'))
$edid=Import-Clixml (Join-Path $full 'edid-backup.xml')
Assert-ArcRiftRecoveryScope $registry $plugins $edid
$baseline=Get-ArcRiftRecoveryLayouts (Get-Content (Join-Path $full 'physical-baseline.txt') -Raw)
$lock=$null
$success=$false
Start-Transcript -Path (Join-Path $full ('manual-recovery-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.txt'))
try {
    $lock=[IO.File]::Open((Join-Path $root 'active-test.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::Write,[IO.FileShare]::None)
    $current=(Get-ItemProperty 'HKLM:\SOFTWARE\Oculus' -ErrorAction SilentlyContinue).DirectDisplayDLL
    $before=@($registry | Where-Object Name -eq 'DirectDisplayDLL')[0]
    $ours=Join-Path $root 'arc_rift_bridge.dll'
    if ($current -and $current -ne $ours -and (-not $before.Had -or $current -ne $before.Value)) { throw 'Another display backend is configured; refusing ambiguous recovery.' }
    # No SteamVR install found means no SteamVR processes to close.
    $steamRoot=try { Get-ArcRiftSteamVRPath (Get-ArcRiftSteamPath) } catch { $null }
    $vr=@(if ($steamRoot) { Get-Process | Where-Object { $_.Path -and $_.Path.StartsWith($steamRoot+'\',[StringComparison]::OrdinalIgnoreCase) } })
    if ($vr.Count -and $current -ne $ours) { throw 'Unowned SteamVR session present. Close it normally before recovery.' }
    $vr | Stop-Process -Force
    'Stop source helper for full recovery.' | Set-Content (Join-Path $full 'native-source-stop.txt')
    Stop-ArcRiftMetaRuntime
    foreach ($r in $registry) {
        if ($r.Had) { if (-not (Test-Path $r.Path)) { New-Item $r.Path -Force | Out-Null }; New-ItemProperty $r.Path -Name $r.Name -Value $r.Value -PropertyType $r.Kind -Force | Out-Null }
        elseif (Test-Path $r.Path) { Remove-ItemProperty $r.Path -Name $r.Name -ErrorAction SilentlyContinue }
    }
    foreach ($p in $plugins) {
        if (Test-Path -LiteralPath $p.Temporary) {
            if (Test-Path -LiteralPath $p.Original) { throw 'Plugin restore conflict; no files overwritten.' }
            if ((Get-FileHash $p.Temporary).Hash -ne $p.Hash) { throw 'Temporary plugin hash mismatch.' }
            Move-Item -LiteralPath $p.Temporary -Destination $p.Original
        }
        if ((Get-FileHash $p.Original).Hash -ne $p.Hash) { throw 'Restored plugin hash mismatch.' }
    }
    if ($state.VirtualMonitorWasOk) { Enable-PnpDevice -InstanceId 'ROOT\DISPLAY\0000' -Confirm:$false }
    $key='HKLM:\SYSTEM\CurrentControlSet\Enum\'+$edid.Instance+'\Device Parameters\EDID_OVERRIDE'
    if (Test-Path $key) {
        $item=Get-Item $key
        if (@($item.GetValueNames() | Where-Object { $_ -ne '0' }).Count -or $item.SubKeyCount) { throw 'Unexpected EDID values; refusing to discard them.' }
        Remove-ItemProperty $key -Name '0' -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $key
    }
    # v3: start Meta's runtime first; the Rift S display only appears while it runs. Then retry the restart.
    Start-Service OVRService
    $monitorRestarted = $false
    for ($i = 0; $i -lt 20 -and -not $monitorRestarted; $i++) {
        & pnputil.exe /restart-device $edid.Instance
        if ($LASTEXITCODE -eq 0) { $monitorRestarted = $true } else { Start-Sleep -Seconds 2 }
    }
    if (-not $monitorRestarted) { throw 'Recovery monitor restart failed (is the Rift S plugged in?).' }
    $matched=$false
    for ($i=0;$i -lt 12;$i++) {
        Start-Sleep -Seconds 1
        $text=& (Join-Path $root 'display_probe.exe')
        $text | Out-File (Join-Path $full 'manual-recovery-display.txt')
        if ($LASTEXITCODE -ne 0) { continue }
        try { $after=Get-ArcRiftRecoveryLayouts ($text -join "`n") } catch { continue }
        $matched=$after.Count -eq $baseline.Count
        foreach ($id in $baseline.Keys) { if ($after[$id] -ne $baseline[$id]) { $matched=$false } }
        if ($matched) { break }
    }
    if (-not $matched -or (Test-Path $key) -or (Get-Service OVRService).Status -ne 'Running') { throw 'Recovery display/service verification failed.' }
    foreach ($r in $registry) {
        $k=Get-Item $r.Path -ErrorAction SilentlyContinue
        $had=$k -and ($k.GetValueNames() -contains $r.Name)
        if ([bool]$had -ne $r.Had -or ($r.Had -and ($k.GetValue($r.Name) -ne $r.Value -or $k.GetValueKind($r.Name).ToString() -ne $r.Kind))) { throw 'Recovery registry verification failed.' }
    }
    if ($state.VirtualMonitorWasOk -and (Get-PnpDevice -InstanceId 'ROOT\DISPLAY\0000').Status -ne 'OK') { throw 'Recovery virtual monitor verification failed.' }
    $state.CleanupVerified=$true
    $state | ConvertTo-Json | Set-Content $statePath
    Remove-Item -LiteralPath (Join-Path $root 'active-test.xml') -ErrorAction SilentlyContinue
    $success=$true
    Write-Output 'RECOVERY VERIFIED: original layouts, registry, EDID, plugins and runtime restored. Game was not force-killed.'
} finally {
    if ($lock) { $lock.Dispose(); if ($success) { Remove-Item -LiteralPath (Join-Path $root 'active-test.lock') } }
    Stop-Transcript
}
