# Pure startup state policy; no process or graphics operations.
function Test-ArcRiftSteamVRStartup {
    param([hashtable]$State, [int[]]$ServerIds, [int[]]$CompositorIds, [bool]$FreshStartupComplete)
    if ($ServerIds.Count -gt 1 -or $CompositorIds.Count -gt 1) { throw 'Multiple SteamVR server/compositor processes during startup.' }
    foreach ($pair in @(@('ServerId', $ServerIds), @('CompositorId', $CompositorIds))) {
        $key = $pair[0]
        $ids = @($pair[1])
        if ($State[$key]) {
            if ($ids.Count -ne 1 -or $ids[0] -ne $State[$key]) { throw ('SteamVR startup process exited/restarted: ' + $key) }
        } elseif ($ids.Count -eq 1) { $State[$key] = $ids[0] }
    }
    return $ServerIds.Count -eq 1 -and $CompositorIds.Count -eq 1 -and $FreshStartupComplete
}

function Read-ArcRiftStartupLog {
    param([string]$Path, [ref]$Offset)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    $stream = $null
    $reader = $null
    try {
        $stream = [IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
        if ($stream.Length -lt $Offset.Value) { $Offset.Value = 0L }
        $null = $stream.Seek($Offset.Value,[IO.SeekOrigin]::Begin)
        $reader = New-Object IO.StreamReader($stream)
        $text = $reader.ReadToEnd()
        $Offset.Value = $stream.Position
        return $text
    } finally {
        if ($reader) { $reader.Dispose() } elseif ($stream) { $stream.Dispose() }
    }
}

# vrstartup is a short-lived bootstrapper, NOT the pinned server/compositor.
function Get-ArcRiftParticipantTokenDecision {
    param([string]$Name, [int]$Integrity, [bool]$ConfirmedExited)
    if ($Integrity -eq 8192) { return 'VerifiedMedium' }
    if ($Name -eq 'vrstartup' -and $Integrity -lt 0 -and $ConfirmedExited) { return 'ExitedLauncher' }
    throw ('Unexpected participant token: ' + $Name + ' RID=' + $Integrity)
}
