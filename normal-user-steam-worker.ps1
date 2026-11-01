# Broker child: verifies its own token BEFORE launching either SteamVR executable.
param(
    [Parameter(Mandatory=$true)][string]$EvidenceDirectory,
    [Parameter(Mandatory=$true)][string]$Nonce,
    [switch]$ProbeOnly,
    [switch]$WaitForCompositor,
    [int]$MetaServerPid = 0,
    [int]$SourceHelperPid = 0
)
$ErrorActionPreference = 'Stop'
function Publish-WorkerJson([string]$Name, $Value) {
    $path = Join-Path $EvidenceDirectory $Name
    $Value | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath ($path + '.tmp') -Encoding UTF8
    Move-Item -LiteralPath ($path + '.tmp') -Destination $path
}
try {
    $participants = @(& (Join-Path $PSScriptRoot 'probe-process-integrity.ps1'))
    if ([ArcRiftIntegrityProbe]::Integrity($PID) -ne 8192) { throw 'Worker is not Medium integrity; refusing VR launch.' }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    Publish-WorkerJson 'user-worker-ready.json' ([ordered]@{
        Nonce=$Nonce; Pid=$PID; Integrity=8192
        SessionId=(Get-Process -Id $PID).SessionId; UserSid=$identity.User.Value
        ProbeOnly=[bool]$ProbeOnly; Participants=$participants; Sequenced=[bool]$WaitForCompositor
    })
    if ($ProbeOnly) { exit 0 }
    if ($WaitForCompositor -and ($MetaServerPid -le 0 -or $SourceHelperPid -le 0)) { throw 'Sequenced launch requires the live Meta/native-helper identities.' }
    $deadline = (Get-Date).AddSeconds(10)
    $go = Join-Path $EvidenceDirectory 'user-worker-go.txt'
    while (-not (Test-Path -LiteralPath $go)) {
        if ((Get-Date) -gt $deadline) { throw 'Parent did not authorize launch within 10 seconds.' }
        Start-Sleep -Milliseconds 50
    }
    if ((Get-Content -LiteralPath $go -Raw).Trim() -ne $Nonce) { throw 'Launch authorization nonce mismatch.' }
    if (Get-Process vrserver,vrcompositor,vrmonitor,vrcmd,vrstartup,VRChat -ErrorAction SilentlyContinue) {
        throw 'A VR process appeared before broker launch; refusing to join an existing session.'
    }
    $launchDeadline = (Get-Date).AddSeconds(6)
    $cancel = Join-Path $EvidenceDirectory 'user-worker-cancel.txt'
    if (Test-Path -LiteralPath $cancel) { throw 'Launch was cancelled.' }
    $bin = 'C:\Program Files (x86)\Steam\steamapps\common\SteamVR\bin\win64'
    $bootState = @{}
    if ($WaitForCompositor) {
        . (Join-Path $PSScriptRoot 'steamvr-startup-policy.ps1')
        $graphicsLog = 'C:\Program Files (x86)\Steam\logs\vrcompositor.txt'
        $backendLog = Join-Path $PSScriptRoot 'arc-rift-bridge.log'
        [long]$graphicsOffset = 0
        [long]$backendOffset = 0
        if (Test-Path $graphicsLog) { $graphicsOffset = (Get-Item $graphicsLog).Length }
        if (Test-Path $backendLog) { $backendOffset = (Get-Item $backendLog).Length }
        $graphicsTail = ''
        $backendTail = ''
    }
    $startup = Start-Process -FilePath (Join-Path $bin 'vrstartup.exe') -WorkingDirectory $bin -PassThru
    if ((Test-Path -LiteralPath $cancel) -or (Get-Date) -gt $launchDeadline) { throw 'Launch cancelled or startup exceeded worker budget; parent must clean up.' }
    if ($WaitForCompositor) {
        $deadline = (Get-Date).AddSeconds(8)
        $signature = ''
        while ($true) {
            if (Test-Path -LiteralPath $cancel) { throw 'Sequenced launch cancelled.' }
            if (-not (Get-Process -Id $MetaServerPid -ErrorAction SilentlyContinue) -or
                -not (Get-Process -Id $SourceHelperPid -ErrorAction SilentlyContinue)) { throw 'Meta/native helper exited during normal-user bootstrap.' }
            $servers = @(Get-Process vrserver -ErrorAction SilentlyContinue)
            $compositors = @(Get-Process vrcompositor -ErrorAction SilentlyContinue)
            $ids = @($servers | ForEach-Object { $_.Id })
            $cids = @($compositors | ForEach-Object { $_.Id })
            $nowSignature = ($ids -join ',') + '/' + ($cids -join ',')
            if ($nowSignature -ne $signature) {
                $actors = @($servers) + @($compositors)
                $records = @($actors | ForEach-Object { @{Name=$_.Name; Pid=$_.Id; Integrity=[ArcRiftIntegrityProbe]::Integrity($_.Id)} })
                @{Time=(Get-Date).ToString('o'); Actors=$records} | ConvertTo-Json -Depth 4 -Compress |
                    Add-Content (Join-Path $EvidenceDirectory 'normal-bootstrap-history.jsonl')
                if (@($records | Where-Object { $_.Integrity -ne 8192 }).Count) { throw 'Normal-user bootstrap participant is not Medium integrity.' }
                $signature = $nowSignature
            }
            $graphicsTail += Read-ArcRiftStartupLog $graphicsLog ([ref]$graphicsOffset)
            $backendTail += Read-ArcRiftStartupLog $backendLog ([ref]$backendOffset)
            if ($graphicsTail.Length -gt 8192) { $graphicsTail = $graphicsTail.Substring($graphicsTail.Length-8192) }
            if ($backendTail.Length -gt 8192) { $backendTail = $backendTail.Substring($backendTail.Length-8192) }
            if ($graphicsTail -match '(?i:AcquireSync FAILED|ReleaseSync FAILED|WaitForAcquire timed out|DXGI_ERROR_DEVICE_REMOVED|DXGI_ERROR_DEVICE_HUNG)' -or
                $backendTail -match '(?i:Renderer failed|Surface failed|Present frame=\d+ result=(?!00000000)[a-f0-9]{8})') { throw 'Graphics/synchronization failure during normal-user bootstrap.' }
            if (Test-ArcRiftSteamVRStartup $bootState $ids $cids ($graphicsTail -match 'Startup Complete')) { break }
            if ((Get-Date) -gt $deadline) { throw 'Normal-user compositor startup exceeded 8 seconds; diagnostic not launched.' }
            Start-Sleep -Milliseconds 100
        }
    }
    if (Test-Path -LiteralPath $cancel) { throw 'Launch cancelled before background diagnostic.' }
    $client = Start-Process -FilePath (Join-Path $bin 'vrcmd.exe') -ArgumentList '--background --info --pollposes --pollcontrollers' -WorkingDirectory $bin -RedirectStandardOutput (Join-Path $EvidenceDirectory 'client.txt') -RedirectStandardError (Join-Path $EvidenceDirectory 'client-stderr.txt') -PassThru
    Publish-WorkerJson 'user-worker-started.json' ([ordered]@{
        Nonce=$Nonce; StartupPid=$startup.Id; ClientPid=$client.Id
        ClientIntegrity=[ArcRiftIntegrityProbe]::Integrity($client.Id)
        BootstrapServerId=$bootState.ServerId; BootstrapCompositorId=$bootState.CompositorId
    })
} catch {
    Publish-WorkerJson 'user-worker-error.json' ([ordered]@{Nonce=$Nonce; Error=$_.Exception.Message})
    exit 1
}
