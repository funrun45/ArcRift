# Shared handshake for a harmless preflight and the explicit, gated live trial.
. (Join-Path $PSScriptRoot 'normal-user-launch.ps1')
function Start-ArcRiftSteamWorker {
    param([Parameter(Mandatory=$true)][string]$EvidenceDirectory, [switch]$ProbeOnly,
          [switch]$WaitForCompositor, [int]$MetaServerPid=0, [int]$SourceHelperPid=0)
    $nonce = [guid]::NewGuid().ToString()
    foreach ($name in @('user-worker-ready.json','user-worker-started.json','user-worker-error.json','user-worker-go.txt')) {
        if (Test-Path -LiteralPath (Join-Path $EvidenceDirectory $name)) { throw 'Worker evidence directory is not fresh.' }
    }
    $worker = (Join-Path $PSScriptRoot 'normal-user-steam-worker.ps1').Replace("'", "''")
    $dirLiteral = $EvidenceDirectory.Replace("'", "''")
    $scriptText = "& '$worker' -EvidenceDirectory '$dirLiteral' -Nonce '$nonce'"
    if ($ProbeOnly) { $scriptText += ' -ProbeOnly' }
    if ($WaitForCompositor) { $scriptText += (' -WaitForCompositor -MetaServerPid ' + $MetaServerPid + ' -SourceHelperPid ' + $SourceHelperPid) }
    Start-ArcRiftNormalUserPowerShell -ScriptText $scriptText
    $readyPath = Join-Path $EvidenceDirectory 'user-worker-ready.json'
    $errorPath = Join-Path $EvidenceDirectory 'user-worker-error.json'
    $deadline = (Get-Date).AddSeconds(8)
    while (-not (Test-Path -LiteralPath $readyPath)) {
        if (Test-Path -LiteralPath $errorPath) { throw (Get-Content $errorPath -Raw) }
        if ((Get-Date) -gt $deadline) { throw 'Normal-user broker handshake timed out.' }
        Start-Sleep -Milliseconds 50
    }
    $ready = Get-Content -LiteralPath $readyPath -Raw | ConvertFrom-Json
    if ($ready.Nonce -ne $nonce -or $ready.Integrity -ne 8192 -or
        $ready.SessionId -ne (Get-Process -Id $PID).SessionId -or
        $ready.UserSid -ne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -or
        $ready.ProbeOnly -ne [bool]$ProbeOnly -or $ready.Sequenced -ne [bool]$WaitForCompositor) { throw 'Worker identity/session/token/nonce validation failed.' }
    if ($ProbeOnly) { return $ready }
    if ([ArcRiftIntegrityProbe]::Integrity([int]$ready.Pid) -ne 8192) { throw 'Worker token could not be independently verified.' }
    $script:ArcRiftSteamWorkerProcess = Get-Process -Id ([int]$ready.Pid) -ErrorAction Stop
    $null = $script:ArcRiftSteamWorkerProcess.Handle
    Set-Content -LiteralPath (Join-Path $EvidenceDirectory 'user-worker-go.txt') -Value $nonce
    $startedPath = Join-Path $EvidenceDirectory 'user-worker-started.json'
    $deadline = (Get-Date).AddSeconds(12)
    while (-not (Test-Path -LiteralPath $startedPath)) {
        if (Test-Path -LiteralPath $errorPath) { throw (Get-Content $errorPath -Raw) }
        if ((Get-Date) -gt $deadline) { throw 'Normal-user SteamVR launch timed out; full cleanup required.' }
        Start-Sleep -Milliseconds 50
    }
    $started = Get-Content -LiteralPath $startedPath -Raw | ConvertFrom-Json
    if ($started.Nonce -ne $nonce -or $started.ClientIntegrity -ne 8192) { throw 'SteamVR diagnostic token/nonce mismatch.' }
    if ($WaitForCompositor) {
        foreach ($entry in @(@('vrserver',$started.BootstrapServerId),@('vrcompositor',$started.BootstrapCompositorId))) {
            $observed = @(Get-Process -Name $entry[0] -ErrorAction Stop)
            if ($observed.Count -ne 1 -or $observed[0].Id -ne $entry[1] -or
                [ArcRiftIntegrityProbe]::Integrity($observed[0].Id) -ne 8192) { throw 'Sequenced normal-user bootstrap identity changed.' }
        }
        $script:ArcRiftSteamWorkerStartupState = $started
    }
    $client = Get-Process -Id ([int]$started.ClientPid) -ErrorAction Stop
    if ($client.ProcessName -ne 'vrcmd' -or [ArcRiftIntegrityProbe]::Integrity($client.Id) -ne 8192) { throw 'Unexpected SteamVR diagnostic process or token.' }
    return $client
}
