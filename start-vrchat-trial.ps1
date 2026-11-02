# Explicit five-minute game trial; nothing is installed permanently.
param([switch]$ManualSession)
$ErrorActionPreference = 'Stop'
$code = 1
try {
    if ($ManualSession) { Write-Host 'EXPERIMENTAL MANUAL SESSION: no duration cutoff; startup/stall/graphics guards remain.' }
    else { Write-Host 'Five-minute VRChat trial using the exact working renderer and normal-user menu setup.' }
    Write-Host 'Wait for the ready message, then launch VRChat normally through Steam in VR mode.'
    Write-Host 'Handle login yourself; start seated in your home/private instance.'
    if ($ManualSession) { Write-Host 'Quit VRChat, then use STOP AND RESTORE.cmd. Never kill the harness window. Recovery is best effort, not a guarantee.' }
    else { Write-Host 'Watch the displayed cutoff time and EXIT VRChat BEFORE it. Cleanup does not force-kill the game.' }
    Write-Host 'For early cleanup use Stop & restore in ArcRift Control, or STOP AND RESTORE.cmd in this folder.'
    Write-Host 'Do not close the elevated harness window; let rollback finish.'
    $harness = Join-Path $PSScriptRoot 'test-ovr-d3d11.ps1'
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $harness + '" -Visual -NativeTiming -NativeSource -SteamVR -LegacyCheckpointSteamTrial -UserLaunchSteamTrial -DashboardNormalUserTrial -VRChatTrial'
    if ($ManualSession) { $arguments += ' -ManualSession' }
    $process = Start-Process powershell.exe -Verb RunAs -ArgumentList $arguments -PassThru
    $null = $process.Handle
    $process.WaitForExit()
    $code = $process.ExitCode
    Write-Host ('Trial finished; harness exit=' + $code + '. Check the newest d3d11-* transcript for rollback verification.')
} catch { Write-Host $_.Exception.Message }
exit $code
