# Fixed first-game trial settings. No process, registry, game or graphics operations.
function Get-ArcRiftVRChatTrialSettings {
    param([bool]$NormalUserMenuMode, [bool]$ManualSession=$false)
    if (-not $NormalUserMenuMode) { throw 'VRChat trial requires the menu-working normal-user launch mode.' }
    if ($ManualSession) { return [pscustomobject]@{Seconds=0; NativeHoldSeconds=0; WarningSeconds=@(); ManualSession=$true} }
    return [pscustomobject]@{Seconds=300; NativeHoldSeconds=330; WarningSeconds=@(60,30,15); ManualSession=$false}
}

function Get-ArcRiftVRChatWarnings {
    param([double]$RemainingSeconds, [hashtable]$Sent)
    if ($RemainingSeconds -le 0) { return }
    foreach ($threshold in @(60,30,15)) {
        if ($RemainingSeconds -le $threshold -and -not $Sent.ContainsKey($threshold)) {
            $Sent[$threshold] = $true
            Write-Output $threshold
        }
    }
}
