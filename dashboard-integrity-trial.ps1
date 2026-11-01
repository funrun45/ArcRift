# Opt-in UI-only experiment. Caller owns a bounded SteamVR session and full cleanup.
# Never changes a renderer, Steam settings, UAC policy, service or game file.
function Invoke-ArcRiftDashboardIntegrityTrial {
    param([Parameter(Mandatory=$true)][string]$SteamRoot,
          [Parameter(Mandatory=$true)][string]$EvidenceDirectory)
    $ErrorActionPreference = 'Stop'
    $server = Get-Process vrserver -ErrorAction Stop
    $parentRid = [ArcRiftIntegrityProbe]::Integrity($PID)
    $serverRid = [ArcRiftIntegrityProbe]::Integrity($server.Id)
    if ($parentRid -ne 12288 -or $serverRid -ne $parentRid) {
        throw 'Dashboard trial requires the original High-integrity server and harness.'
    }
    $ui = @(Get-Process vrdashboard,vrwebhelper -ErrorAction SilentlyContinue | Where-Object {
        $_.Path -and $_.Path.StartsWith($SteamRoot + '\', [StringComparison]::OrdinalIgnoreCase)
    })
    if (-not ($ui | Where-Object { $_.ProcessName -eq 'vrdashboard' }) -or
        -not ($ui | Where-Object { $_.ProcessName -eq 'vrwebhelper' })) { return $null }
    $records = @()
    $mismatch = $false
    foreach ($p in $ui) {
        $null = $p.Handle # Retain identity/lifetime before any possible termination.
        if ($p.HasExited) { return $null }
        if ($p.SessionId -ne $server.SessionId) { throw 'Dashboard is in another session; refusing to alter it.' }
        $rid = [ArcRiftIntegrityProbe]::Integrity($p.Id)
        if ($rid -ne 8192 -and $rid -ne 12288) { throw ('Unexpected dashboard token RID=' + $rid) }
        if ($rid -ne $serverRid) { $mismatch = $true }
        $records += [pscustomobject]@{Name=$p.ProcessName; Pid=$p.Id; Integrity=$rid; Path=$p.Path}
    }
    [pscustomobject]@{ServerPid=$server.Id; ServerIntegrity=$serverRid; Ui=$records; Mismatch=$mismatch} |
        ConvertTo-Json -Depth 5 | Set-Content (Join-Path $EvidenceDirectory 'dashboard-tokens-before.json')
    if (-not $mismatch) {
        Write-Host 'Dashboard already matches server integrity. Recorded evidence; no UI relaunch performed.'
        return [pscustomobject]@{Replaced=$false; Processes=@()}
    }
    $dashboardPath = Join-Path $SteamRoot 'bin\win64\vrdashboard.exe'
    $helperPath = Join-Path $SteamRoot 'bin\vrwebhelper\win64\vrwebhelper.exe'
    foreach ($path in @($dashboardPath,$helperPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw ('UI binary missing: ' + $path) }
    }
    # Only the test-started SteamVR UI processes. NEVER stop Steam, server or compositor.
    foreach ($p in $ui) {
        if (-not $p.HasExited) { $p.Kill() }
    }
    foreach ($p in $ui) {
        if (-not $p.WaitForExit(1500)) { throw 'Old dashboard process did not exit; refusing duplicate UI.' }
    }
    Write-Host 'Recorded Medium UI / High server mismatch. Relaunching only SteamVR dashboard and web UI at High integrity.'
    $dashboard = Start-Process -FilePath $dashboardPath -WorkingDirectory (Split-Path $dashboardPath) -PassThru
    $null = $dashboard.Handle
    $helper = Start-Process -FilePath $helperPath -ArgumentList '-lang=en_us -forceOnPaint=gpu' -WorkingDirectory (Split-Path $helperPath) -PassThru
    $null = $helper.Handle
    $after = @()
    foreach ($p in @($dashboard,$helper)) {
        $rid = [ArcRiftIntegrityProbe]::Integrity($p.Id)
        $after += [pscustomobject]@{Name=$p.ProcessName; Pid=$p.Id; Integrity=$rid}
        if ($rid -ne $serverRid) { throw ('Replacement UI token does not match server: ' + $p.ProcessName) }
    }
    $after | ConvertTo-Json | Set-Content (Join-Path $EvidenceDirectory 'dashboard-tokens-after.json')
    return [pscustomobject]@{Replaced=$true; Processes=@($dashboard,$helper)}
}
