# One bounded integration attempt. Run elevated; never an installation script.
param([switch]$Visual, [switch]$NativeTiming, [switch]$LinkDiagnostics, [switch]$NativeSource, [switch]$Stereo, [switch]$TrackedScene, [switch]$SteamVR,
    [ValidateRange(15,600)][int]$SteamVRSeconds = 30, [switch]$IsolatedHeadsetTrial, [switch]$LegacyCheckpointTrial, [switch]$NoReadbackSteamTrial, [switch]$UserLaunchSteamTrial, [switch]$StartupIdentityHeadsetTrial, [switch]$LegacyCheckpointSteamTrial, [switch]$OriginalSteamVRBaselineTrial, [switch]$DashboardSameIntegrityTrial, [switch]$DashboardNormalUserTrial, [switch]$VRChatTrial, [switch]$ManualSession)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
Set-Location -LiteralPath $root
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$out = Join-Path $root ('d3d11-' + $stamp)
New-Item -ItemType Directory -Path $out | Out-Null
$registry = @()
$moves = @()
$createdKeys = @()
$virtualDisabled = $false
$changed = $false
$client = $null
$sourceHelper = $null
$steamStarted = $false
# Release 1.1.2: install folders are looked up (install-paths.ps1) during the identity checks below.
$steamPath = $null
$steamRoot = $null
$steamBin = $null
$metaRuntime = $null
$start = Get-Date
$failed = $false
$edidChanged = $false
$sessionLock = $null
$activeSession = Join-Path $root 'active-test.xml'
$sessionLockPath = Join-Path $root 'active-test.lock'
$bridgeName = 'arc_rift_bridge.dll'
$bridgeLogName = 'arc-rift-bridge.log'
$userStopRequested = $false
[long]$bridgeLogOffset = 0
$candidateLogTail = ''
$isolatedRendererTrial = $IsolatedHeadsetTrial -or $StartupIdentityHeadsetTrial
$shortHeadsetTrial = $isolatedRendererTrial -or $LegacyCheckpointTrial
$guardedSteamTrial = $NoReadbackSteamTrial -or $LegacyCheckpointSteamTrial
$guardedTrial = $shortHeadsetTrial -or $guardedSteamTrial
[long]$steamGraphicsOffset = 0
$steamGraphicsTail = ''
$syncHiccupTimes = New-Object System.Collections.Generic.List[datetime]
$syncFloodSince = $null
$bridgeFpsPrevTick = $null
$bridgeFpsPrevFrame = $null
$bridgeLowFpsCount = 0
$headsetOff = $false
$headsetOffSince = $null
$metaLogPath = $null
[long]$metaLogOffset = 0
$metaLogCheckAt = Get-Date
$metaLastGrowth = Get-Date
$presentMonProcess = $null
$steamGraphicsLog = $null
$presentMonGames = @('VRChat.exe')
$presentMonFiles = 0
$nextGameCheck = Get-Date
[long]$vrserverLogOffset = 0
$verifiedParticipantIds = @{}
$script:ArcRiftSteamWorkerProcess = $null
$startupSeed = Join-Path $root 'arc_rift_bridge_startup.dll.identity'
$startupSeedOwned = $false
$dashboardTrialState = $null
$bootstrapServerId = $null
$bootstrapCompositorId = $null
$script:ArcRiftSteamWorkerStartupState = $null
$vrchatWarnings = @{}
$vrchatObservedPids = @{}
$recoveryWatcher = $null
$rollbackVerified = $false
$manualRecoveryFile = Join-Path $out 'manual-recovery-state.json'
$manualDiskCheckAt = Get-Date
# Release 1.1: headset/GPU identity comes from Setup (arcrift-config.json), not from fixed IDs.
$arcConfigError = $null
$monitorInstance = ''
$targetId = 0
try {
    $arcConfigPath = Join-Path $root 'arcrift-config.json'
    if (-not (Test-Path -LiteralPath $arcConfigPath)) { throw 'No headset setup found. Run Setup in ArcRift Control first (arcrift-config.json is missing).' }
    $arcConfig = Get-Content -LiteralPath $arcConfigPath -Raw | ConvertFrom-Json
    $monitorInstance = [string]$arcConfig.monitorInstance
    $targetId = [int]$arcConfig.targetId
    $gpuMatch = [regex]::Match([string]$arcConfig.gpuPnpMatch, '(?i)VEN_([0-9A-F]{4})&DEV_([0-9A-F]{4})')
    if ($monitorInstance -notmatch '^(?i)DISPLAY\\[^\\]+\\[^\\]+$' -or $targetId -le 0 -or -not $gpuMatch.Success) { throw 'arcrift-config.json is incomplete. Run Setup in ArcRift Control again.' }
    if ($gpuMatch.Groups[1].Value -ne '8086') { throw 'The GPU saved by Setup is not an Intel GPU; this release only supports Intel Arc.' }
    $identityLines = @(('target=' + $targetId), ('monitor=' + ($monitorInstance -replace '\\', '#') + '#'), ('gpu=' + $gpuMatch.Groups[1].Value + ':' + $gpuMatch.Groups[2].Value))
    Set-Content -LiteralPath (Join-Path $root 'arcrift-identity.txt') -Value $identityLines -Encoding Ascii
    # Rift S display mode (EDID) for this headset: public Rift S capture timings + this headset's serial,
    # which Meta uses to pair the display with the headset. Rebuilt every session; never flashed to hardware.
    $serial = ([string]$arcConfig.headsetSerial).Trim()
    if ($serial -notmatch '^[A-Za-z0-9]{6,32}$') { throw 'The headset serial number is missing. Run Setup again with the Meta Horizon app open and the headset connected.' }
    $edidTemplate = '00ffffffffffff003ed2120000000000011d0104a50000000e000000000000000000000000000101010101010101010101010101010145dfa0385100eea5d20cf10c000000000010000000ff0030303030303030303030303030000000fc005269667420530a20202020202000000010000000000000000000000000000000e6'
    $edidBytes = [byte[]]::new(128)
    for ($i = 0; $i -lt 128; $i++) { $edidBytes[$i] = [Convert]::ToByte($edidTemplate.Substring($i * 2, 2), 16) }
    $serialText = if ($serial.Length -ge 13) { $serial.Substring($serial.Length - 13) } else { $serial + "`n" + (' ' * (12 - $serial.Length)) }
    $serialBytes = [Text.Encoding]::ASCII.GetBytes($serialText)
    for ($i = 0; $i -lt 13; $i++) { $edidBytes[77 + $i] = $serialBytes[$i] }
    $edidSum = 0; for ($i = 0; $i -lt 127; $i++) { $edidSum += $edidBytes[$i] }
    $edidBytes[127] = [byte]((256 - ($edidSum % 256)) % 256)
    [IO.File]::WriteAllBytes((Join-Path $root 'rift-s-native-test.edid'), $edidBytes)
    . (Join-Path $root 'install-paths.ps1')
    $metaRuntime = Get-ArcRiftMetaRuntimePath
    if ($SteamVR) {
        $steamPath = Get-ArcRiftSteamPath
        $steamRoot = Get-ArcRiftSteamVRPath $steamPath
        $steamBin = Join-Path $steamRoot 'bin\win64'
        $steamGraphicsLog = Join-Path $steamPath 'logs\vrcompositor.txt'
    }
} catch { $arcConfigError = $_.Exception.Message }
$monitorParent = 'HKLM:\SYSTEM\CurrentControlSet\Enum\' + $monitorInstance + '\Device Parameters'
$edidKey = $monitorParent + '\EDID_OVERRIDE'
function Get-ActiveLayouts([string]$Text) {
    $layouts = @{}
    $pattern = '(?m)^\s*target=(\d+) [^\r\n]*pathFlags=1[^\r\n]*\r?\n[^\r\n]*\r?\n\s*(signal=[^\r\n]+)\r?\n\s*(source=[^\r\n]+)'
    foreach ($m in [regex]::Matches($Text, $pattern)) {
        $layouts[$m.Groups[1].Value] = $m.Groups[2].Value.Trim() + ' ' + $m.Groups[3].Value.Trim()
    }
    if ($layouts.Count -eq 0) { throw 'No active display layouts parsed.' }
    return $layouts
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
function Get-ArcRiftHeadsetWake([datetime]$NotBefore = [datetime]::MinValue) {
    # From Meta's newest log: is the headset awake, and since when? 'HMD unavailable' means it went to sleep after
    # sitting unused; proximity 0 -> 1 or 'HMD mounted' after that means it woke. No log at all counts as Unknown.
    $log = Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Oculus') -Filter 'Service_*.txt' -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -Last 1
    if (-not $log) { return [pscustomobject]@{State='Unknown'; Since=[datetime]::MinValue} }
    [long]$fromStart = 0
    $text = Read-AppendedBridgeLog $log.FullName ([ref]$fromStart)
    $started = $null; $asleep = $null; $woke = $null
    $pattern = '(?m)^(\d{2})/(\d{2}) (\d{2}):(\d{2}):(\d{2})\.(\d{3}) [^\r\n]*?(Starting Oculus Runtime Service|Broadcasting HMD unavailable event|Proximity state changed \(0 -> 1\)|Broadcasting HMD mounted event)'
    foreach ($m in [regex]::Matches($text, $pattern)) {
        $g = $m.Groups
        # Meta writes day/month, e.g. "02/11 11:06:25.841" for 2 November.
        $t = [datetime]::new((Get-Date).Year, [int]$g[2].Value, [int]$g[1].Value, [int]$g[3].Value, [int]$g[4].Value, [int]$g[5].Value, [int]$g[6].Value)
        if ($t -gt (Get-Date).AddDays(1)) { $t = $t.AddYears(-1) }
        if ($g[7].Value -like 'Starting*') { $started = $t; $asleep = $null; $woke = $null }
        elseif ($g[7].Value -like '*unavailable*') { $asleep = $t; $woke = $null }
        elseif ($asleep -and -not $woke) { $woke = $t }
    }
    # NotBefore: when waiting for a runtime we just started, its log must be the newest one (allow 2 s clock slack).
    if (-not $started -or ($NotBefore -gt [datetime]::MinValue -and $started -lt $NotBefore.AddSeconds(-2))) { return [pscustomobject]@{State='Starting'; Since=[datetime]::MinValue} }
    if ($asleep -and -not $woke) { return [pscustomobject]@{State='Asleep'; Since=$asleep} }
    # Meta briefly reports 'unavailable' ~8-10 s after every start, so a runtime with no wake event yet needs 15 s.
    if ($woke) { return [pscustomobject]@{State='Awake'; Since=$woke; Settle=10} }
    return [pscustomobject]@{State='Awake'; Since=$started; Settle=15}
}
function Wait-ArcRiftHeadsetAwake([datetime]$NotBefore = [datetime]::MinValue, [int]$TimeoutSeconds = 180) {
    # Release 1.1.2: Meta looks for the headset display only once, when its runtime starts. A headset that is asleep
    # (sat unused) or still waking up has no display at that moment, so wait until it has been awake for 10 s.
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $told = ''
    while ($true) {
        $wake = Get-ArcRiftHeadsetWake $NotBefore
        if ($wake.State -eq 'Unknown') { return }
        if ($wake.State -eq 'Awake' -and ((Get-Date) - $wake.Since).TotalSeconds -ge $wake.Settle) {
            if ($told) { Write-Output 'Headset is awake.' }
            return
        }
        $message = switch ($wake.State) {
            'Asleep' { 'Headset is asleep: put it on, or pick it up and move it, to wake it. The session continues 10 s after it wakes.' }
            'Awake' { 'Headset is waking up; continuing in a few seconds...' }
            default { 'Waiting for the Meta runtime to start...' }
        }
        if ($message -ne $told) { Write-Output $message; $told = $message }
        if (Test-Path -LiteralPath (Join-Path $out 'session-stop.txt')) { throw 'Stopped by you while waiting for the headset to wake.' }
        if ((Get-Date) -gt $deadline) { throw 'The headset did not wake up within 3 minutes. Put it on until its display lights up, then start the session again.' }
        Start-Sleep -Seconds 1
    }
}
$clientLogFreedTo = 1MB
$clientLogFreeWarned = $false
function Limit-ArcRiftClientLog([string]$Path) {
    # Release 1.1.2: vrcmd --pollposes writes ~40 MB/hour of poses to client.txt. Free the disk space of everything
    # except its first 1 MB and last 8 MB (sparse zeroing; vrcmd keeps writing normally). Never fails the session.
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return }
        $length = (Get-Item -LiteralPath $Path).Length
        $freeTo = [long]([math]::Floor(($length - 8MB) / 65536) * 65536)
        if ($freeTo - $script:clientLogFreedTo -lt 64MB) { return }
        if (-not ('ArcRiftSparseLog' -as [type])) {
            Add-Type -TypeDefinition @'
using System; using System.IO; using System.ComponentModel; using System.Runtime.InteropServices; using Microsoft.Win32.SafeHandles;
public static class ArcRiftSparseLog {
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool DeviceIoControl(SafeFileHandle handle, uint code, IntPtr input, int inputSize, IntPtr output, int outputSize, out int returned, IntPtr overlapped);
    public static void ZeroRange(string path, long from, long to) {
        using (var file = new FileStream(path, FileMode.Open, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete)) {
            int returned;
            // FSCTL_SET_SPARSE, then FSCTL_SET_ZERO_DATA: the zeroed range stops using disk space.
            if (!DeviceIoControl(file.SafeFileHandle, 0x000900C4, IntPtr.Zero, 0, IntPtr.Zero, 0, out returned, IntPtr.Zero)) throw new Win32Exception();
            IntPtr range = Marshal.AllocHGlobal(16);
            try {
                Marshal.WriteInt64(range, 0, from); Marshal.WriteInt64(range, 8, to);
                if (!DeviceIoControl(file.SafeFileHandle, 0x000980C8, range, 16, IntPtr.Zero, 0, out returned, IntPtr.Zero)) throw new Win32Exception();
            } finally { Marshal.FreeHGlobal(range); }
        }
    }
}
'@
        }
        [ArcRiftSparseLog]::ZeroRange($Path, $script:clientLogFreedTo, $freeTo)
        $script:clientLogFreedTo = $freeTo
    } catch {
        if (-not $script:clientLogFreeWarned) { $script:clientLogFreeWarned = $true; Write-Output ('client.txt disk space could not be freed (session unaffected): ' + $_.Exception.Message) }
    }
}
function Stop-ArcRiftPresentMon {
    if (-not $script:presentMonProcess) { return }
    try {
        $pmStop = Start-Process -FilePath (Join-Path $root 'PresentMon.exe') -ArgumentList '--session_name ArcRiftPM --terminate_existing_session' -WindowStyle Hidden -PassThru
        $null = $pmStop.WaitForExit(5000)
        if (-not $script:presentMonProcess.WaitForExit(5000)) { Stop-Process -Id $script:presentMonProcess.Id -Force -ErrorAction SilentlyContinue }
    } catch { Write-Output ('PresentMon stop note (rollback unaffected): ' + $_.Exception.Message) }
    $script:presentMonProcess = $null
}
function Start-ArcRiftPresentMon {
    # Optional read-only frame-timing capture for Meta's server and every game seen so far. Never affects the session.
    try {
        Stop-ArcRiftPresentMon
        $script:presentMonFiles++
        $csv = if ($script:presentMonFiles -eq 1) { 'presentmon.csv' } else { 'presentmon-' + $script:presentMonFiles + '.csv' }
        $names = (@($script:presentMonGames) + 'OVRServer_x64.exe' | ForEach-Object { '--process_name "' + $_ + '"' }) -join ' '
        $pmArgs = $names + ' --output_file "' + (Join-Path $out $csv) + '" --no_console_stats --no_track_input --session_name ArcRiftPM --stop_existing_session'
        $script:presentMonProcess = Start-Process -FilePath (Join-Path $root 'PresentMon.exe') -ArgumentList $pmArgs -WindowStyle Hidden -PassThru
        Write-Output ('Frame-timing recorder (PresentMon) started: ' + $csv + ' in this session folder (' + ($script:presentMonGames -join ', ') + ').')
    } catch { Write-Output ('PresentMon not started (session unaffected): ' + $_.Exception.Message) }
}
function Read-AppendedBridgeLog([string]$Path, [ref]$Offset) {
    $stream = $null
    $reader = $null
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return '' }
        $stream = [IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
        if ($stream.Length -lt $Offset.Value) { $Offset.Value = 0L }
        $null = $stream.Seek($Offset.Value,[IO.SeekOrigin]::Begin)
        $reader = New-Object IO.StreamReader($stream)
        $text = $reader.ReadToEnd()
        $Offset.Value = $stream.Position
        return $text
    } catch { return '' } finally {
        if ($reader) { $reader.Dispose() } elseif ($stream) { $stream.Dispose() }
    }
}
Start-Transcript -Path (Join-Path $out 'transcript.txt')
try {
    if ($arcConfigError) { throw $arcConfigError }
    Write-Output ('Headset display ' + $monitorInstance + ' (target ' + $targetId + ') from Setup.')
    if ($ManualSession -and -not $VRChatTrial) { throw 'ManualSession requires explicit VRChatTrial/menu-working mode.' }
    if ($VRChatTrial -and -not $DashboardNormalUserTrial) { throw 'VRChatTrial requires the menu-working DashboardNormalUserTrial; other rendering/launch modes refused.' }
    if ($DashboardNormalUserTrial -and (-not ($LegacyCheckpointSteamTrial -and $UserLaunchSteamTrial) -or $OriginalSteamVRBaselineTrial -or $DashboardSameIntegrityTrial)) { throw 'DashboardNormalUserTrial requires exact legacy renderer with normal-user launching, not elevated-baseline/UI-replacement modes.' }
    if ($DashboardSameIntegrityTrial -and -not $OriginalSteamVRBaselineTrial) { throw 'DashboardSameIntegrityTrial requires the original baseline; no other launch or renderer experiment allowed.' }
    if ($OriginalSteamVRBaselineTrial -and (-not $LegacyCheckpointSteamTrial -or $UserLaunchSteamTrial)) { throw 'OriginalSteamVRBaselineTrial requires LegacyCheckpointSteamTrial and forbids the new normal-user launcher.' }
    if ($UserLaunchSteamTrial -and -not $guardedSteamTrial) { throw 'UserLaunchSteamTrial requires a restricted guarded SteamVR trial mode.' }
    if ($SteamVR -and (Test-Path (Join-Path $root 'steamvr-tests-paused.txt')) -and -not ($UserLaunchSteamTrial -or $OriginalSteamVRBaselineTrial)) { throw 'SteamVR trials paused pending transport/launch-privilege investigation. No runtime/display changes made.' }
    if (([int][bool]$IsolatedHeadsetTrial + [int][bool]$LegacyCheckpointTrial + [int][bool]$NoReadbackSteamTrial + [int][bool]$StartupIdentityHeadsetTrial + [int][bool]$LegacyCheckpointSteamTrial) -gt 1) { throw 'Choose only one backend trial.' }
    if ($NoReadbackSteamTrial) {
        if (-not ($Visual -and $NativeTiming -and $NativeSource -and $SteamVR) -or $Stereo -or $TrackedScene -or $LinkDiagnostics) { throw 'NoReadbackSteamTrial requires only Visual/NativeTiming/NativeSource/SteamVR; no game or other render modes.' }
        if (Get-Process vrserver,vrcompositor,vrmonitor,vrcmd,VRChat,isolated_presenter_test -ErrorAction SilentlyContinue) { throw 'Another VR/graphics test is running.' }
        if ((Get-FileHash -LiteralPath (Join-Path $root 'arc_rift_bridge.dll') -Algorithm SHA256).Hash -ne 'c9fad8ed975c900d58d39cfce96cdc01608a388ce675f4f6b45fc8e18685a485') { throw 'Saved legacy reference was changed.' }
        $bridgeName = 'arc_rift_bridge_noreadback.dll'
        $bridgeLogName = 'arc-rift-bridge-noreadback.log'
        $SteamVRSeconds = 20
        Write-Output 'Explicit 20-second SteamVR-only A/B trial: legacy rendering path with recurring readbacks disabled. Saved DLL untouched.'
    } elseif ($LegacyCheckpointSteamTrial) {
        if (-not ($Visual -and $NativeTiming -and $NativeSource -and $SteamVR -and ($UserLaunchSteamTrial -or $OriginalSteamVRBaselineTrial)) -or $Stereo -or $TrackedScene -or $LinkDiagnostics) { throw 'LegacyCheckpointSteamTrial requires Visual/NativeTiming/NativeSource/SteamVR and one explicit launch mode; no games or other render modes.' }
        if (Get-Process vrserver,vrcompositor,vrmonitor,vrcmd,VRChat,isolated_presenter_test -ErrorAction SilentlyContinue) { throw 'Another VR/graphics test is running.' }
        # Release 1.1: verify every program against release-manifest.json (written by BUILD-RELEASE.cmd).
        $releaseManifestPath = Join-Path $root 'release-manifest.json'
        if (-not (Test-Path -LiteralPath $releaseManifestPath)) { throw 'release-manifest.json is missing. Run BUILD-RELEASE.cmd or reinstall the release.' }
        $releaseManifest = Get-Content -LiteralPath $releaseManifestPath -Raw | ConvertFrom-Json
        foreach ($entry in $releaseManifest.PSObject.Properties) {
            if ((Get-FileHash -LiteralPath (Join-Path $root $entry.Name) -Algorithm SHA256).Hash -ne [string]$entry.Value) { throw ('Release file differs from its manifest: ' + $entry.Name) }
        }
        $SteamVRSeconds = 20
        if ($OriginalSteamVRBaselineTrial -or $DashboardNormalUserTrial) {
            $SteamVRSeconds = 30
            $savedTools = $root
            if ($DashboardNormalUserTrial) {
                if ($VRChatTrial) {
                    Write-Output 'ArcRift session: Rift S bridge with normal-user SteamVR launch. No game files or anti-cheat are touched.'
                } else {
                    Write-Output 'Dashboard IPC trial: EXACT original DLL/native helper/EDID; SteamVR runs as normal user to match Steam. Sequenced diagnostic, 30 seconds, no games, full rollback. Desktop baseline untouched.'
                }
            } else {
                Write-Output 'Original successful SteamVR baseline: exact saved DLL/native helper/EDID, original direct elevated vrstartup/vrcmd sequence, fixed 30 seconds. No new renderer, broker or seed; emergency guards and full rollback retained.'
            }
        } else {
            Write-Output 'User-requested exact saved legacy DLL: guarded 20-second SteamVR-only trial with normal-user launching. No rebuilt renderer, no games, no permanent enablement.'
        }
    } elseif ($LegacyCheckpointTrial) {
        if (-not ($Visual -and $NativeTiming -and $NativeSource -and $Stereo) -or $SteamVR -or $TrackedScene -or $LinkDiagnostics) { throw 'LegacyCheckpointTrial is limited to 12-second stereo labels; no SteamVR or games.' }
        if (Get-Process vrserver,vrcompositor,vrmonitor,vrcmd,VRChat,isolated_presenter_test -ErrorAction SilentlyContinue) { throw 'Another VR/graphics test is running.' }
        $expected = 'c9fad8ed975c900d58d39cfce96cdc01608a388ce675f4f6b45fc8e18685a485'
        $saved = Join-Path $root 'checkpoints\near-working-and-isolated-20261031-180448\tested-legacy\arc_rift_bridge.dll'
        if ((Get-FileHash -LiteralPath $saved -Algorithm SHA256).Hash -ne $expected -or (Get-FileHash -LiteralPath (Join-Path $root $bridgeName) -Algorithm SHA256).Hash -ne $expected) { throw 'Legacy DLL does not match saved tested checkpoint; refusing trial.' }
        Write-Output 'User-requested exact checkpoint DLL: 12-second legacy stereo test only. Known sustained instability; no permanent enablement.'
    } elseif ($isolatedRendererTrial) {
        if (-not ($Visual -and $NativeTiming -and $NativeSource -and $Stereo) -or $SteamVR -or $TrackedScene -or $LinkDiagnostics) { throw 'IsolatedHeadsetTrial requires Visual/NativeTiming/NativeSource/Stereo only; no SteamVR, games, or link diagnostics.' }
        if (Get-Process vrserver,vrcompositor,vrmonitor,vrcmd,VRChat,isolated_presenter_test -ErrorAction SilentlyContinue) { throw 'Another VR/graphics test is running.' }
        $bridgeName = 'arc_rift_bridge_isolated.dll'
        $bridgeLogName = 'arc-rift-bridge-isolated.log'
        if ($StartupIdentityHeadsetTrial) {
            if (Test-Path -LiteralPath $startupSeed) { throw 'Existing startup seed; refusing to overwrite or delete it.' }
            $bridgeName = 'arc_rift_bridge_startup.dll'
            $bridgeLogName = 'arc-rift-bridge-startup.log'
        }
        Write-Output 'Explicit isolated-only 12-second headset trial; legacy/SteamVR safety gate remains in place.'
    } elseif (Test-Path (Join-Path $root 'live-tests-paused.txt')) { throw 'Live tests paused after desktop corruption. Read live-tests-paused.txt; no runtime/display changes made.' }
    if ($NativeSource -and -not $NativeTiming) { throw 'NativeSource requires NativeTiming.' }
    if ($Stereo -and -not ($Visual -and $NativeSource)) { throw 'Stereo requires Visual and NativeSource.' }
    if ($TrackedScene -and (-not ($Visual -and $NativeSource) -or $Stereo)) { throw 'TrackedScene requires Visual and NativeSource, without Stereo.' }
    if ($SteamVR -and (-not ($Visual -and $NativeSource) -or $Stereo -or $TrackedScene)) { throw 'SteamVR requires Visual and NativeSource, without other visual modes.' }
    if ($VRChatTrial) {
        . (Join-Path $root 'vrchat-trial-policy.ps1')
        $vrchatSettings = Get-ArcRiftVRChatTrialSettings ([bool]$DashboardNormalUserTrial) ([bool]$ManualSession)
        if (-not $ManualSession) { $SteamVRSeconds = $vrchatSettings.Seconds }
        elseif (-not (Test-Path (Join-Path $root 'native_source_session.exe'))) { throw 'Manual-session native helper missing.' }
    }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Elevation required.' }
    if ($DashboardSameIntegrityTrial) {
        & (Join-Path $root 'probe-process-integrity.ps1') | Out-File (Join-Path $out 'dashboard-harness-integrity.txt')
        . (Join-Path $root 'dashboard-integrity-trial.ps1')
        . (Join-Path $root 'steamvr-startup-policy.ps1')
        Write-Output 'Additional UI-only dashboard integrity trial. Original tested renderer/launch path unchanged; 30-second limit and full rollback retained.'
    }
    if ($UserLaunchSteamTrial) {
        . (Join-Path $root 'normal-user-steam-launch.ps1')
        . (Join-Path $root 'steamvr-startup-policy.ps1')
        $preflight = Join-Path $out 'user-launch-preflight'
        New-Item -ItemType Directory -Path $preflight | Out-Null
        $workerProof = Start-ArcRiftSteamWorker -EvidenceDirectory $preflight -ProbeOnly
        if ($workerProof.Integrity -ne 8192) { throw 'Normal-user worker preflight failed.' }
        if (-not (Get-Process steam -ErrorAction SilentlyContinue)) { throw 'Steam is not running. Start Steam and sign in, then start the session again; no changes made.' }
        if (-not (Get-Process OVRServer_x64 -ErrorAction SilentlyContinue)) { throw 'Meta runtime is not running. Open the Meta Horizon app with the headset plugged in, then start the session again; no changes made.' }
        foreach ($p in @(Get-Process OVRServer_x64,steam,explorer -ErrorAction Stop)) {
            if ([ArcRiftIntegrityProbe]::Integrity($p.Id) -ne 8192) { throw ('Participant is not Medium integrity: ' + $p.Name) }
        }
        if ($VRChatTrial) {
            if ($ManualSession) { Write-Output 'Manual-stop session: no time limit. Safety guards stay active. When done, quit your game and use Stop & restore.' }
            else { Write-Output 'Normal-user preflight passed. Five-minute VRChat observation; user handles normal Steam launch/login. Close VRChat before cutoff. Games are not force-terminated by this harness.' }
        } else {
            Write-Output ('Normal-user worker preflight passed without VR. Live trial is SteamVR-only, no games, fixed ' + $SteamVRSeconds + ' seconds.')
        }
    }
    if ((Get-Service OVRService).Status -ne 'Running') { throw 'Service is not in the expected original running state.' }
    if (Get-Process OculusDash -ErrorAction SilentlyContinue) { throw 'Dash is already running; refusing to interrupt an existing session.' }
    if (Test-Path -LiteralPath $edidKey) { throw 'EDID experiment already active.' }
    # Release 1.1.2: never back up "original" settings over a session that was not restored yet.
    if (Test-Path -LiteralPath $activeSession) { throw 'The previous session was not restored (active-test.xml exists). Run Recover in ArcRift Control or RECOVER.cmd first; no changes made.' }
    $sessionLock = [IO.File]::Open($sessionLockPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    [pscustomobject]@{SessionDirectory=$out; HarnessPid=$PID; Started=(Get-Date)} | Export-Clixml $activeSession
    if ($SteamVR) {
        if (-not (Test-Path (Join-Path $steamBin 'vrcmd.exe'))) { throw 'Installed SteamVR diagnostic is missing.' }
        $existing = @(Get-Process | Where-Object { $_.Path -and $_.Path.StartsWith($steamRoot + '\', [StringComparison]::OrdinalIgnoreCase) })
        if ($existing.Count -or (Get-Process vrserver,vrcompositor,vrmonitor -ErrorAction SilentlyContinue)) { throw 'SteamVR already running; refusing to interrupt an existing session.' }
        $steamConfig = Join-Path $steamPath 'config\steamvr.vrsettings'
        if (Test-Path $steamConfig) { Copy-Item -LiteralPath $steamConfig -Destination (Join-Path $out 'steamvr-settings-before.json') }
    }
    & (Join-Path $root 'display_probe.exe') | Out-File -Encoding utf8 (Join-Path $out 'physical-baseline.txt')
    if ($LASTEXITCODE -ne 0) { throw 'Baseline display probe failed.' }
    $baselineLayouts = Get-ActiveLayouts (Get-Content (Join-Path $out 'physical-baseline.txt') -Raw)
    if (-not $baselineLayouts.ContainsKey([string]$targetId)) { throw 'Active headset source missing at baseline.' }
    if ($NativeTiming) {
        $monitor = Get-PnpDevice -InstanceId $monitorInstance -PresentOnly
        if ($monitor.Class -ne 'Monitor') { throw 'Verified headset monitor is missing.' }
        $testEdid = [IO.File]::ReadAllBytes((Join-Path $root 'rift-s-native-test.edid'))
        if ($testEdid.Length -ne 128 -or (($testEdid | Measure-Object -Sum).Sum % 256) -ne 0) { throw 'Invalid native test EDID.' }
        $pixelClock = ($testEdid[54] + 256 * $testEdid[55]) * 10000
        $width = $testEdid[56] + (($testEdid[58] -band 240) * 16)
        $height = $testEdid[59] + (($testEdid[61] -band 240) * 16)
        if ($width -ne 1440 -or $height -ne 2560 -or $pixelClock -ne 571570000) { throw 'Native EDID differs from the previously tested timing.' }
        [IO.File]::WriteAllBytes((Join-Path $out 'original-monitor.edid'), (Get-ItemProperty -LiteralPath $monitorParent -Name EDID).EDID)
        [IO.File]::WriteAllBytes((Join-Path $out 'temporary-native.edid'), $testEdid)
        @{KeyExisted=$false; Instance=$monitorInstance; Parent=$monitorParent} | Export-Clixml (Join-Path $out 'edid-backup.xml')
    }
    if ($OriginalSteamVRBaselineTrial -or $DashboardNormalUserTrial) {
        & (Join-Path $savedTools 'bridge_selftest.exe') | Out-File (Join-Path $out 'bridge-preflight.txt')
    } elseif ($StartupIdentityHeadsetTrial) {
        & (Join-Path $root 'bridge_selftest_startup.exe') --startup | Out-File (Join-Path $out 'bridge-preflight.txt')
    } elseif ($IsolatedHeadsetTrial) {
        & (Join-Path $root 'bridge_selftest.exe') --isolated | Out-File (Join-Path $out 'bridge-preflight.txt')
    } elseif ($NoReadbackSteamTrial) {
        & (Join-Path $root 'bridge_selftest.exe') --no-readback | Out-File (Join-Path $out 'bridge-preflight.txt')
    } else {
        & (Join-Path $root 'bridge_selftest.exe') | Out-File (Join-Path $out 'bridge-preflight.txt')
    }
    if ($LASTEXITCODE -ne 0) { throw 'Bridge preflight failed.' }
    Get-FileHash -LiteralPath (Join-Path $root $bridgeName) -Algorithm SHA256 | Export-Clixml (Join-Path $out 'backend-hash.xml')
    # Release 1.1.2: the bridge appends to one log forever; start a fresh one once it passes 8 MB (bridge is not loaded yet).
    $bridgeLogPath = Join-Path $root $bridgeLogName
    if ((Test-Path -LiteralPath $bridgeLogPath) -and (Get-Item -LiteralPath $bridgeLogPath).Length -gt 8MB) {
        try { Move-Item -LiteralPath $bridgeLogPath -Destination ($bridgeLogPath -replace '\.log$', '.old.log') -Force } catch { Write-Output ('Bridge log not rotated: ' + $_.Exception.Message) }
    }
    if (Test-Path $bridgeLogPath) { $bridgeLogOffset = (Get-Item $bridgeLogPath).Length }
    [long]$bridgeLogSessionStart = $bridgeLogOffset
    $settings = @(
        @{Path='HKLM:\SOFTWARE\Oculus'; Name='DirectDisplayDLL'; Value=(Join-Path $root $bridgeName); Kind='String'},
        @{Path='HKLM:\SOFTWARE\Oculus'; Name='ForceGPUDriverVersionAcceptance'; Value=1; Kind='DWord'},
        @{Path='HKLM:\SOFTWARE\WOW6432Node\Oculus VR, LLC\Oculus\Config'; Name='PreventDashLaunch'; Value=1; Kind='DWord'}
    )
    foreach ($s in $settings) {
        $had = $false; $value = $null; $kind = $null
        if (Test-Path $s.Path) {
            $k = Get-Item $s.Path
            $had = $k.GetValueNames() -contains $s.Name
            if ($had) { $value = $k.GetValue($s.Name); $kind = $k.GetValueKind($s.Name).ToString() }
        } else {
            $p = $s.Path
            while (-not (Test-Path $p)) { $createdKeys += $p; $p = Split-Path $p }
        }
        $registry += [pscustomobject]@{Path=$s.Path; Name=$s.Name; Had=$had; Value=$value; Kind=$kind}
    }
    $registry | Export-Clixml (Join-Path $out 'registry-backup.xml')
    foreach ($name in @('RemoteHeadset.dll','RemoteHeadset_v55.dll','RemoteHeadsetDisco.dll')) {
        $original = Join-Path (Join-Path $metaRuntime 'server-plugins') $name
        $temporary = $original + '.arc-rift-d3d11-disabled'
        if (Test-Path -LiteralPath $temporary) { throw 'Existing temporary plugin file.' }
        if (-not (Test-Path -LiteralPath $original)) {
            # A Meta update can drop or rename a streaming plugin; nothing to disable then.
            Write-Output ('Meta streaming plugin ' + $name + ' is not installed (Meta update?); nothing to disable for it.')
            continue
        }
        $moves += [pscustomobject]@{Original=$original; Temporary=$temporary; Hash=(Get-FileHash -LiteralPath $original -Algorithm SHA256).Hash}
    }
    $moves | Export-Clixml (Join-Path $out 'plugins-backup.xml')
    if ($StartupIdentityHeadsetTrial) {
        & (Join-Path $root 'startup_identity_test.exe') --capture-only $PID | Out-File (Join-Path $out 'startup-identity-capture.txt')
        if ($LASTEXITCODE -ne 0) { throw 'Fresh exact active startup identity capture failed; refusing runtime changes.' }
        $startupSeedOwned = $true
        Copy-Item -LiteralPath $startupSeed -Destination (Join-Path $out 'startup-identity-evidence.bin')
    }
    if ($ManualSession) {
        $virtual=Get-PnpDevice -InstanceId 'ROOT\DISPLAY\0000' -PresentOnly -ErrorAction SilentlyContinue
        $manualState=[pscustomobject]@{ManualSession=$true; Root=$root; OwnerPid=$PID; OwnerCreated=(Get-Process -Id $PID).StartTime.ToUniversalTime().ToFileTimeUtc().ToString(); VirtualMonitorWasOk=([bool]($virtual -and $virtual.Status -eq 'OK')); CleanupVerified=$false}
        $manualState | ConvertTo-Json | Set-Content $manualRecoveryFile
        $watchArgs='-NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $root 'watch-manual-session.ps1')+'" -SessionDirectory "'+$out+'"'
        $recoveryWatcher=Start-Process powershell.exe -ArgumentList $watchArgs -PassThru -WindowStyle Hidden
        $null=$recoveryWatcher.Handle
        $watchDeadline=(Get-Date).AddSeconds(5)
        while (-not (Test-Path (Join-Path $out 'manual-watcher-ready.txt'))) {
            if ($recoveryWatcher.HasExited -or (Get-Date) -gt $watchDeadline) { throw 'Independent recovery watcher failed to attach; refusing manual-session runtime changes.' }
            Start-Sleep -Milliseconds 100
        }
    }
    # Release 1.1.2: the usual "first start fails" cause was a headset that had gone to sleep before the session.
    Wait-ArcRiftHeadsetAwake
    $changed = $true
    Stop-ArcRiftMetaRuntime
    foreach ($s in $settings) {
        if (-not (Test-Path $s.Path)) { New-Item $s.Path -Force | Out-Null }
        New-ItemProperty $s.Path -Name $s.Name -Value $s.Value -PropertyType $s.Kind -Force | Out-Null
    }
    foreach ($m in $moves) { Move-Item -LiteralPath $m.Original -Destination $m.Temporary }
    $v = Get-PnpDevice -InstanceId 'ROOT\DISPLAY\0000' -PresentOnly -ErrorAction SilentlyContinue
    if ($v -and $v.FriendlyName -eq 'Meta Virtual Monitor' -and $v.Status -eq 'OK') {
        $virtualDisabled = $true
        Disable-PnpDevice -InstanceId $v.InstanceId -Confirm:$false
    }
    $start = Get-Date
    # Release 1.1.1: Meta looks for displays only once, right when its runtime starts. If the headset display was not
    # there at that moment, retry once (nothing else has been applied to the displays yet).
    for ($metaAttempt = 1; $metaAttempt -le 2; $metaAttempt++) {
        Start-Service OVRService
        $serverId = $null
        for ($i = 0; $i -lt 24; $i++) {
            Start-Sleep -Milliseconds 500
            if (Get-Process OculusDash -ErrorAction SilentlyContinue) { throw 'Dash started despite suppression; aborting.' }
            $server = Get-Process OVRServer_x64 -ErrorAction SilentlyContinue
            if ($server) {
                if ($serverId -and $server.Id -ne $serverId) { throw 'VR server restarted; aborting.' }
                $serverId = $server.Id
            } elseif ($serverId) { throw 'VR server exited; aborting.' }
        }
        if (-not $serverId) { throw 'VR server did not start.' }
        if (-not $guardedTrial) { break }
        $bootLog = Read-AppendedBridgeLog (Join-Path $root $bridgeLogName) ([ref]$bridgeLogOffset)
        $candidateLogTail += $bootLog
        $enumDeadline = (Get-Date).AddSeconds(8)
        while ($bootLog -notmatch ('Enumerate verified target ' + $targetId + '\b') -and (Get-Date) -lt $enumDeadline) {
            Start-Sleep -Milliseconds 500
            if (-not (Get-Process -Id $serverId -ErrorAction SilentlyContinue)) { throw 'VR server exited; aborting.' }
            if (Get-Process OculusDash -ErrorAction SilentlyContinue) { throw 'Dash started despite suppression; aborting.' }
            $moreBootLog = Read-AppendedBridgeLog (Join-Path $root $bridgeLogName) ([ref]$bridgeLogOffset)
            $bootLog += $moreBootLog
            $candidateLogTail += $moreBootLog
        }
        if ($bootLog -match ('Enumerate verified target ' + $targetId + '\b')) { break }
        if ($metaAttempt -eq 1) {
            # Release 1.1.2: restarting the bridge runtime alone never brought the display back (it cannot wake the
            # headset). Wake it with Meta's normal runtime first, then switch to the bridge again right away.
            Write-Output 'Meta did not find the headset display (headset asleep or still waking up). Waking it with the normal Meta runtime, then retrying once...'
            Stop-ArcRiftMetaRuntime
            $originalBackend = $registry | Where-Object Name -eq 'DirectDisplayDLL'
            if ($originalBackend.Had) { New-ItemProperty $originalBackend.Path -Name 'DirectDisplayDLL' -Value $originalBackend.Value -PropertyType $originalBackend.Kind -Force | Out-Null }
            else { Remove-ItemProperty $originalBackend.Path -Name 'DirectDisplayDLL' -ErrorAction SilentlyContinue }
            $normalStart = Get-Date
            Start-Service OVRService
            Wait-ArcRiftHeadsetAwake $normalStart
            Stop-ArcRiftMetaRuntime
            $bridgeSetting = $settings | Where-Object Name -eq 'DirectDisplayDLL'
            New-ItemProperty $bridgeSetting.Path -Name $bridgeSetting.Name -Value $bridgeSetting.Value -PropertyType $bridgeSetting.Kind -Force | Out-Null
            continue
        }
        throw 'Selected backend did not enumerate verified display during runtime startup; refusing timing/render changes.'
    }
    if ($LinkDiagnostics) {
        & (Join-Path $root 'igcl_probe.exe') --link-status | Out-File -Encoding utf8 (Join-Path $out 'link-before-native.txt')
        & (Join-Path $root 'hid_probe.exe') | Out-File -Encoding utf8 (Join-Path $out 'hid-before-native.txt')
    }
    if ($NativeTiming) {
        # First enumerate the verified output while connected, then change timing.
        # Restarting PnP with the service stopped can hide the display at provider startup.
        & (Join-Path $root 'display_probe.exe') | Out-File -Encoding utf8 (Join-Path $out 'physical-display-before-native.txt')
        $edidChanged = $true
        New-Item -Path $edidKey | Out-Null
        New-ItemProperty -LiteralPath $edidKey -Name '0' -Value $testEdid -PropertyType Binary -Force | Out-Null
        Write-Output 'Temporary published native timing applied ONLY to verified Rift S monitor. Not a firmware write.'
        & pnputil.exe /restart-device $monitorInstance
        if ($LASTEXITCODE -ne 0) { throw 'Headset monitor restart failed.' }
        Start-Sleep -Seconds 6
        & (Join-Path $root 'display_probe.exe') | Out-File -Encoding utf8 (Join-Path $out 'physical-display-after-runtime-start.txt')
        $probe = Get-Content (Join-Path $out 'physical-display-after-runtime-start.txt') -Raw
        $match = [regex]::Match($probe, '(?m)^\s*target=' + $targetId + ' [^\r\n]*pathFlags=1[^\r\n]*\r?\n[^\r\n]*\r?\n\s*signal=1440x2560 total=1752x4078 pixelClock=571570000 vSync=(\d+)/(\d+)')
        if (-not $match.Success) { throw 'Expected native physical scanout was not confirmed after runtime startup; refusing render test.' }
        $hz = [double]$match.Groups[1].Value / [double]$match.Groups[2].Value
        if ($hz -lt 79 -or $hz -gt 81) { throw 'Native scanout refresh rate was unexpected.' }
        Write-Output ('Physical native scanout verified: 1440x2560 at ' + $hz + ' Hz.')
    }
    if ($NativeSource) {
        $holdSeconds = 45
        if ($SteamVR) { $holdSeconds = $SteamVRSeconds + 30 }
        if ($VRChatTrial -and -not $ManualSession -and $holdSeconds -ne $vrchatSettings.NativeHoldSeconds) { throw 'VRChat/native-helper time budgets do not match; refusing source apply.' }
        $sourceExe='native_source_test.exe'; $sourceArgs='--hold-managed '+$holdSeconds
        if ($ManualSession) { $sourceExe='native_source_session.exe'; $sourceArgs='--hold-session '+$PID }
        $sourceHelper = Start-Process -FilePath (Join-Path $root $sourceExe) -ArgumentList $sourceArgs -WorkingDirectory $out -RedirectStandardOutput (Join-Path $out 'native-source.txt') -RedirectStandardError (Join-Path $out 'native-source-stderr.txt') -PassThru
        $null = $sourceHelper.Handle
        $readyDeadline = (Get-Date).AddSeconds(5)
        while (-not (Test-Path (Join-Path $out 'native-source-ready.txt'))) {
            if ($sourceHelper.HasExited -or (Get-Date) -gt $readyDeadline) { throw 'Native desktop surface was not verified; refusing render test.' }
            Start-Sleep -Milliseconds 100
        }
        Write-Output 'Native desktop verified. Full EDID/runtime rollback is managed and verified by this harness; source-only timeout restore is NOT guaranteed.'
    }
    $clientArgs = '--render'
    if ($Visual) { $clientArgs = '--render-long' }
    if ($Stereo) { $clientArgs = '--stereo-pattern' }
    if ($TrackedScene) { $clientArgs = '--tracked-scene' }
    if ($shortHeadsetTrial) { $clientArgs = '--stereo-short' }
    if ($SteamVR) {
        $steamStarted = $true
        if (Test-Path -LiteralPath $steamGraphicsLog) { $steamGraphicsOffset = (Get-Item -LiteralPath $steamGraphicsLog).Length }
        if ($UserLaunchSteamTrial) {
            if ($DashboardNormalUserTrial) {
                $client = Start-ArcRiftSteamWorker -EvidenceDirectory $out -WaitForCompositor -MetaServerPid $serverId -SourceHelperPid $sourceHelper.Id
                $bootstrapServerId = $script:ArcRiftSteamWorkerStartupState.BootstrapServerId
                $bootstrapCompositorId = $script:ArcRiftSteamWorkerStartupState.BootstrapCompositorId
            } else {
                $client = Start-ArcRiftSteamWorker -EvidenceDirectory $out
            }
            Write-Output ('Normal-user SteamVR startup and diagnostic launched; diagnostic PID=' + $client.Id)
        } else {
            $startup = Start-Process -FilePath (Join-Path $steamBin 'vrstartup.exe') -WorkingDirectory $steamBin -PassThru
            Write-Output ('Starting installed SteamVR; bounded diagnostic only, startup PID=' + $startup.Id)
            if ($DashboardSameIntegrityTrial) {
                # Background diagnostics must NOT race vrstartup to create another server.
                $bootstrapDeadline = (Get-Date).AddSeconds(8)
                $bootstrapState = @{}
                $lastBootstrapSignature = ''
                $bootstrapEventCheck = Get-Date
                while ($true) {
                    $bootServers = @(Get-Process vrserver -ErrorAction SilentlyContinue)
                    $bootCompositors = @(Get-Process vrcompositor -ErrorAction SilentlyContinue)
                    $serverIds = @($bootServers | ForEach-Object { $_.Id })
                    $compositorIds = @($bootCompositors | ForEach-Object { $_.Id })
                    $signature = ($serverIds -join ',') + '/' + ($compositorIds -join ',')
                    if ($signature -ne $lastBootstrapSignature) {
                        $actors = @(Get-Process vrstartup,vrserver,vrcompositor,vrdashboard,vrwebhelper -ErrorAction SilentlyContinue | ForEach-Object {
                            [pscustomobject]@{Name=$_.Name; Pid=$_.Id; Session=$_.SessionId; Integrity=[ArcRiftIntegrityProbe]::Integrity($_.Id)}
                        })
                        [pscustomobject]@{Time=(Get-Date).ToString('o'); ServerIds=$serverIds; CompositorIds=$compositorIds; Actors=$actors} |
                            ConvertTo-Json -Depth 5 -Compress | Add-Content (Join-Path $out 'bootstrap-process-history.jsonl')
                        $lastBootstrapSignature = $signature
                    }
                    $steamGraphicsTail += Read-AppendedBridgeLog $steamGraphicsLog ([ref]$steamGraphicsOffset)
                    if ($steamGraphicsTail.Length -gt 8192) { $steamGraphicsTail = $steamGraphicsTail.Substring($steamGraphicsTail.Length-8192) }
                    if ($steamGraphicsTail -match '(?i:AcquireSync FAILED|ReleaseSync FAILED|WaitForAcquire timed out|DXGI_ERROR_DEVICE_REMOVED|DXGI_ERROR_DEVICE_HUNG)') { throw 'SteamVR synchronization/device error during bootstrap.' }
                    $candidateLogTail += Read-AppendedBridgeLog (Join-Path $root $bridgeLogName) ([ref]$bridgeLogOffset)
                    if ($candidateLogTail.Length -gt 8192) { $candidateLogTail = $candidateLogTail.Substring($candidateLogTail.Length-8192) }
                    if ($candidateLogTail -match '(?i:Renderer failed|Surface failed|Present frame=\d+ result=(?!00000000)[a-f0-9]{8})') { throw 'Backend graphics failure during bootstrap.' }
                    if (Test-Path (Join-Path $out 'session-stop.txt')) { throw 'User requested stop during bootstrap; performing full rollback.' }
                    if ($sourceHelper.HasExited -or -not (Get-Process OVRServer_x64 -ErrorAction SilentlyContinue | Where-Object Id -eq $serverId)) { throw 'Meta server/native source helper exited during bootstrap.' }
                    if ((Get-Date) -ge $bootstrapEventCheck) {
                        if (@(Get-WinEvent -FilterHashtable @{LogName='System';Id=4101;StartTime=$start} -ErrorAction SilentlyContinue).Count) { throw 'Windows display recovery during bootstrap.' }
                        $bootstrapEventCheck = (Get-Date).AddSeconds(1)
                    }
                    if (Test-ArcRiftSteamVRStartup $bootstrapState $serverIds $compositorIds ($steamGraphicsTail -match 'Startup Complete')) {
                        $bootstrapServerId = $bootstrapState.ServerId
                        $bootstrapCompositorId = $bootstrapState.CompositorId
                        Write-Output ('Fresh compositor startup complete; launching background diagnostic only now. Server=' + $bootstrapServerId + ' compositor=' + $bootstrapCompositorId)
                        break
                    }
                    if ((Get-Date) -gt $bootstrapDeadline) { throw 'SteamVR compositor did not become ready within 8 seconds; diagnostic was not launched.' }
                    Start-Sleep -Milliseconds 100
                }
            }
            $client = Start-Process -FilePath (Join-Path $steamBin 'vrcmd.exe') -ArgumentList '--background --info --pollposes --pollcontrollers' -WorkingDirectory $steamBin -RedirectStandardOutput (Join-Path $out 'client.txt') -RedirectStandardError (Join-Path $out 'client-stderr.txt') -PassThru
        }
    } else {
        $client = Start-Process -FilePath (Join-Path $root 'ovr_d3d11_test.exe') -ArgumentList $clientArgs -WorkingDirectory $root -RedirectStandardOutput (Join-Path $out 'client.txt') -RedirectStandardError (Join-Path $out 'client-stderr.txt') -PassThru
    }
    # Retain the native process handle so ExitCode remains available after exit.
    $null = $client.Handle
    & (Join-Path $root 'display_probe.exe') | Out-File -Encoding utf8 (Join-Path $out 'physical-display-during-client.txt')
    if ($LinkDiagnostics) {
        & (Join-Path $root 'igcl_probe.exe') --link-status | Out-File -Encoding utf8 (Join-Path $out 'link-during-client.txt')
        & (Join-Path $root 'hid_probe.exe') | Out-File -Encoding utf8 (Join-Path $out 'hid-during-client.txt')
    }
    $limit = 15
    if ($Visual) { $limit = 40 }
    if ($SteamVR) { $limit = $SteamVRSeconds }
    if ($shortHeadsetTrial) { $limit = 20 }
    $deadline = (Get-Date).AddSeconds($limit)
    if ($ManualSession) { $deadline=$null }
    $cutoffLabel=if ($ManualSession) { 'manual STOP (no duration cutoff)' } else { $deadline.ToString('HH:mm:ss') }
    if ($VRChatTrial) {
        [pscustomobject]@{Seconds=$(if ($ManualSession) {0} else {$limit}); ManualSession=[bool]$ManualSession; Started=(Get-Date).ToString('o'); Deadline=$(if ($ManualSession) {$null} else {$deadline.ToString('o')}); HarnessPid=$PID; GameLaunchedByHarness=$false} |
            ConvertTo-Json | Set-Content (Join-Path $out 'vrchat-trial-timing.json')
    }
    if ($SteamVR) { Write-Output ('SteamVR stop policy: ' + $cutoffLabel + '. Use Stop & restore in ArcRift Control (or STOP AND RESTORE.cmd) for full rollback; do not close this PowerShell window.') }
    $steamServerId = $bootstrapServerId
    $steamCompositorId = $bootstrapCompositorId
    $steamReady = $false
    $observationStart = Get-Date
    $candidateLastHealth = Get-Date
    $nextEventCheck = Get-Date
    $nextPresenceCheck = Get-Date
    while ($SteamVR -or -not $client.HasExited) {
        # Release 1.1.2: process-presence and token checks once per second, not every loop pass (each listing costs ~12 ms CPU).
        $presenceCheck = (Get-Date) -ge $nextPresenceCheck
        if ($presenceCheck) { $nextPresenceCheck = (Get-Date).AddSeconds(1) }
        if (Test-Path (Join-Path $out 'session-stop.txt')) { $userStopRequested = $true; Write-Output 'User requested early stop; performing full rollback.'; break }
        if ($ManualSession -and $recoveryWatcher.HasExited) { throw 'Independent manual-session recovery watcher exited; stopping session.' }
        if ($ManualSession -and (Get-Date) -ge $manualDiskCheckAt) {
            $drive=New-Object IO.DriveInfo([IO.Path]::GetPathRoot($root))
            if ($drive.AvailableFreeSpace -lt 1GB) { throw 'Low disk space: stopping manual session before diagnostic logs fill the drive.' }
            Limit-ArcRiftClientLog (Join-Path $out 'client.txt')
            $manualDiskCheckAt=(Get-Date).AddSeconds(30)
        }
        if ($VRChatTrial) {
            $pendingWarnings=@()
            if (-not $ManualSession) { $pendingWarnings=@(Get-ArcRiftVRChatWarnings (($deadline-(Get-Date)).TotalSeconds) $vrchatWarnings) }
            foreach ($warning in $pendingWarnings) {
                Write-Output ('VRCHAT CUTOFF WARNING: ' + $warning + ' seconds or less remain. Exit VRChat before automatic runtime/display cleanup.')
                ('At ' + (Get-Date).ToString('o') + ': ' + $warning + ' seconds or less remain; exit VRChat.') | Add-Content (Join-Path $out 'vrchat-countdown.txt')
            }
            # Process presence only: no game handles, token probing, memory reads or injection.
            foreach ($game in @(if ($presenceCheck) { Get-Process VRChat -ErrorAction SilentlyContinue })) {
                if (-not $vrchatObservedPids.ContainsKey($game.Id)) {
                    $vrchatObservedPids[$game.Id] = $true
                    ('Observed VRChat PID=' + $game.Id + ' at ' + (Get-Date).ToString('o') + '; presence does not prove successful VR rendering.') | Add-Content (Join-Path $out 'vrchat-process-observations.txt')
                    Write-Output 'VRChat process observed. Optical gameplay/comfort must be confirmed by user.'
                }
            }
        }
        if ($UserLaunchSteamTrial) {
            foreach ($p in @(if ($presenceCheck) { Get-Process OVRServer_x64,steam,explorer,vrstartup,vrmonitor,vrserver,vrcompositor,vrcmd -ErrorAction SilentlyContinue })) {
                if (-not $verifiedParticipantIds.ContainsKey($p.Id)) {
                    $rid = [ArcRiftIntegrityProbe]::Integrity($p.Id)
                    ($p.Name + ' PID=' + $p.Id + ' IntegrityRID=' + $rid) | Add-Content (Join-Path $out 'live-participant-integrity.txt')
                    $confirmedExited = $false
                    if ($rid -lt 0) {
                        $freshLauncher = Get-Process -Id $p.Id -ErrorAction SilentlyContinue
                        if (-not $freshLauncher) { $confirmedExited = $true }
                        else {
                            try { $confirmedExited = $freshLauncher.HasExited } catch { $confirmedExited = $false }
                        }
                    }
                    $tokenDecision = Get-ArcRiftParticipantTokenDecision $p.Name $rid $confirmedExited
                    if ($tokenDecision -eq 'ExitedLauncher') {
                        ('Confirmed ' + $p.Name + ' exit PID=' + $p.Id + ' before token check; server/compositor/diagnostic guards remain active.') | Add-Content (Join-Path $out 'live-participant-integrity.txt')
                        continue
                    }
                    $verifiedParticipantIds[$p.Id] = $true
                }
            }
            if ($client.HasExited) { throw 'Normal-user diagnostic exited during SteamVR trial.' }
        }
        if ($guardedTrial) {
            $newLog = Read-AppendedBridgeLog (Join-Path $root $bridgeLogName) ([ref]$bridgeLogOffset)
            $candidateLogTail += $newLog
            if ($candidateLogTail.Length -gt 8192) { $candidateLogTail = $candidateLogTail.Substring($candidateLogTail.Length-8192) }
            if ($isolatedRendererTrial) {
                if ($candidateLogTail -match '(?i:Isolated[^\r\n]*(?:failed|failure|stalled|exceeded|exception|faulted=1))') { throw 'Isolated backend fault detected; stopping immediately.' }
                if ($newLog -match 'Isolated Present callbacks=') { $candidateLastHealth = Get-Date }
            } else {
                if ($candidateLogTail -match '(?i:Renderer failed|Surface failed|Present frame=\d+ result=(?!00000000)[a-f0-9]{8}|Legacy Present health[^\r\n]*slow=1)') { throw 'Legacy backend graphics failure or >100ms presentation stall detected.' }
                if ($newLog -match 'Present frame=|Output surface frame=|Legacy Present health') { $candidateLastHealth = Get-Date }
                if ($ManualSession) {
                    # Manual session: stop if headset output drops below 45 fps for 2 consecutive 120-frame samples.
                    foreach ($m in [regex]::Matches($newLog,'(?m)^(\d+) Output surface frame=(\d+)')) {
                        $tick=[double]$m.Groups[1].Value; $frame=[double]$m.Groups[2].Value
                        if ($null -ne $bridgeFpsPrevTick -and $frame -gt $bridgeFpsPrevFrame -and $tick -gt $bridgeFpsPrevTick) {
                            $fps=($frame-$bridgeFpsPrevFrame)*1000.0/($tick-$bridgeFpsPrevTick)
                            if ($fps -lt 45) {
                                $bridgeLowFpsCount++
                                ('At ' + (Get-Date).ToString('o') + ': headset output ' + [math]::Round($fps,1) + ' fps (low sample ' + $bridgeLowFpsCount + ')') | Add-Content (Join-Path $out 'sync-hiccups.txt')
                            } else { $bridgeLowFpsCount = 0 }
                            if ($bridgeLowFpsCount -ge 2) { throw 'Headset output dropped below 45 fps for 2 consecutive samples; aborting rather than waiting through corruption.' }
                        }
                        $bridgeFpsPrevTick=$tick; $bridgeFpsPrevFrame=$frame
                    }
                }
            }
            $warmupSeconds = 5
            if ($guardedSteamTrial) { $warmupSeconds = 12 }
            if ($ManualSession) {
                # v2: pause the freeze check while Meta reports the headset off (proximity sensor / HMD unmounted).
                if ((Get-Date) -ge $metaLogCheckAt) {
                    $metaLogCheckAt = (Get-Date).AddSeconds(1)
                    $metaLogNow = Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Oculus') -Filter 'Service_*.txt' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $start } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
                    if ($metaLogNow -and $metaLogNow.FullName -ne $metaLogPath) {
                        if ($metaLogPath) { $metaLogOffset = 0L } else { $metaLogOffset = $metaLogNow.Length }
                        $metaLogPath = $metaLogNow.FullName
                        $metaLastGrowth = Get-Date
                    }
                }
                if ($metaLogPath) {
                    $metaNew = Read-AppendedBridgeLog $metaLogPath ([ref]$metaLogOffset)
                    # v5 freeze watchdog: Meta logs at least every ~15 s even when idle (longest normal gap seen: 13.5 s).
                    # Its runtime can hang when it restarts tracking after the headset sat still; then its log stops.
                    if ($metaNew.Length -gt 0) { $metaLastGrowth = Get-Date }
                    elseif (((Get-Date) - $metaLastGrowth).TotalSeconds -gt 30) { throw 'Meta runtime stopped responding (its log was silent for 30 s); stopping and restoring so a fresh session can be started.' }
                    foreach ($metaLine in ($metaNew -split "`r?`n")) {
                        if ($metaLine -match 'Proximity state changed \(1 -> 0\)|Broadcasting HMD unmounted event') {
                            if (-not $headsetOff) {
                                $headsetOff = $true; $headsetOffSince = Get-Date
                                Write-Output 'Headset off: freeze check paused until it is worn again. Other guards stay active.'
                                ('At ' + (Get-Date).ToString('o') + ': headset off, freeze check paused') | Add-Content (Join-Path $out 'sync-hiccups.txt')
                            }
                        } elseif ($metaLine -match 'Proximity state changed \(0 -> 1\)|Broadcasting HMD mounted event') {
                            if ($headsetOff) {
                                $headsetOff = $false
                                $candidateLastHealth = (Get-Date).AddSeconds(5); $bridgeFpsPrevTick = $null; $bridgeLowFpsCount = 0
                                Write-Output 'Headset on: freeze check resumes after an 8-second grace period.'
                                ('At ' + (Get-Date).ToString('o') + ': headset on, freeze check resumes') | Add-Content (Join-Path $out 'sync-hiccups.txt')
                            }
                        }
                    }
                }
                if ($headsetOff -and ((Get-Date)-$headsetOffSince).TotalSeconds -gt 3 -and $newLog -match 'Output surface frame=') {
                    # Frames are flowing again (e.g. proximity bypass on): resume normal checking.
                    $headsetOff = $false; $bridgeFpsPrevTick = $null; $bridgeLowFpsCount = 0
                    ('At ' + (Get-Date).ToString('o') + ': frames flowing while marked off, freeze check resumes') | Add-Content (Join-Path $out 'sync-hiccups.txt')
                }
                if ($headsetOff) { $candidateLastHealth = Get-Date }
            }
            if (((Get-Date)-$observationStart).TotalSeconds -gt $warmupSeconds -and ((Get-Date)-$candidateLastHealth).TotalSeconds -gt 3) { throw 'Backend presentation health log stopped progressing.' }
            if ($guardedSteamTrial) {
                if ($ManualSession) {
                    # Manual session: tolerate isolated sync hiccups (seen when VRChat launches), stop on floods or device loss.
                    $newSteamGraphics = Read-AppendedBridgeLog $steamGraphicsLog ([ref]$steamGraphicsOffset)
                    foreach ($syncLine in ($newSteamGraphics -split "`r?`n")) {
                        if ($syncLine -match '(?i:DXGI_ERROR_DEVICE_REMOVED|DXGI_ERROR_DEVICE_HUNG)') { throw 'SteamVR reported GPU device removed/hung; aborting.' }
                        if ($syncLine -match '(?i:AcquireSync FAILED|ReleaseSync FAILED|WaitForAcquire timed out)') {
                            $syncNow = Get-Date
                            while ($syncHiccupTimes.Count -and ($syncNow - $syncHiccupTimes[0]).TotalSeconds -gt 30) { $syncHiccupTimes.RemoveAt(0) }
                            if ($syncFloodSince -and $syncHiccupTimes.Count -le 20) {
                                $syncFloodSince = $null
                                Write-Output 'SteamVR sync errors back to normal.'
                            }
                            if ($syncLine -match '(?i:AcquireSync FAILED)') {
                                # one AcquireSync line per hitch, plus any SteamVR hid with [N messages suppressed]
                                $syncAdd = 1
                                if ($syncLine -match '\[(\d+) messages suppressed\]') { $syncAdd += [int]$matches[1] }
                                for ($k = 0; $k -lt $syncAdd; $k++) { $syncHiccupTimes.Add($syncNow) }
                            }
                            while ($syncHiccupTimes.Count -and ($syncNow - $syncHiccupTimes[0]).TotalSeconds -gt 30) { $syncHiccupTimes.RemoveAt(0) }
                            ('At ' + $syncNow.ToString('o') + ' (' + $syncHiccupTimes.Count + ' hitches in last 30s): ' + $syncLine.Trim()) | Add-Content (Join-Path $out 'sync-hiccups.txt')
                            # A slow game (e.g. VRChat CPU-bound in a busy world) floods these too; the headset frame-rate,
                            # stall and device-loss guards cover real presentation trouble, so only stop on a long flood.
                            if ($syncHiccupTimes.Count -gt 20) {
                                if (-not $syncFloodSince) {
                                    $syncFloodSince = $syncNow
                                    Write-Output 'SteamVR sync errors high (game running slowly). Session continues; it stops if this lasts 2 minutes. Lower game settings if you can.'
                                } elseif (($syncNow - $syncFloodSince).TotalSeconds -gt 120) {
                                    throw 'Sustained SteamVR sync hitches (more than 20 in 30s for 2 minutes); aborting rather than waiting through corruption.'
                                }
                            }
                            if ($syncLine -match '(?i:AcquireSync FAILED)' -and $syncLine -match '(?i:OMITTING additional logs)') { Write-Output 'SteamVR sync burst (SteamVR hid further warnings for 30s). Headset frame-rate and stall guards still active.' }
                        }
                    }
                } else {
                    $steamGraphicsTail += Read-AppendedBridgeLog $steamGraphicsLog ([ref]$steamGraphicsOffset)
                    if ($steamGraphicsTail.Length -gt 8192) { $steamGraphicsTail = $steamGraphicsTail.Substring($steamGraphicsTail.Length-8192) }
                    if ($steamGraphicsTail -match '(?i:AcquireSync FAILED|ReleaseSync FAILED|WaitForAcquire timed out|DXGI_ERROR_DEVICE_REMOVED|DXGI_ERROR_DEVICE_HUNG)') { throw 'SteamVR graphics synchronization/device error detected; aborting rather than waiting through corruption.' }
                }
            }
            if ((Get-Date) -ge $nextEventCheck) {
                $displayReset = @(Get-WinEvent -FilterHashtable @{LogName='System';Id=4101;StartTime=$start} -ErrorAction SilentlyContinue)
                if ($displayReset.Count) { throw 'Windows reported a display-driver recovery during trial.' }
                $nextEventCheck = (Get-Date).AddSeconds(1)
            }
        }
        if ($sourceHelper -and $sourceHelper.HasExited) { throw 'Native source helper exited before client finished.' }
        if (-not $ManualSession -and (Get-Date) -gt $deadline) {
            if ($SteamVR) { Write-Output 'SteamVR observation interval complete.'; break }
            throw 'Client time limit reached.'
        }
        # One process listing for all four exit/restart guards (still every pass).
        $watched = @(Get-Process OVRServer_x64,OculusDash,vrserver,vrcompositor -ErrorAction SilentlyContinue)
        $server = $watched | Where-Object Name -eq 'OVRServer_x64'
        if (-not $server -or $server.Id -ne $serverId) { throw 'VR server exited/restarted during client test.' }
        if ($watched | Where-Object Name -eq 'OculusDash') { throw 'Dash appeared during client test.' }
        if ($SteamVR) {
            $ss = $watched | Where-Object Name -eq 'vrserver'
            $sc = $watched | Where-Object Name -eq 'vrcompositor'
            if (($DashboardSameIntegrityTrial -or $DashboardNormalUserTrial) -and (@($ss).Count -gt 1 -or @($sc).Count -gt 1)) { throw 'Multiple SteamVR servers/compositors appeared after bootstrap.' }
            if ($DashboardNormalUserTrial -and -not $dashboardTrialState -and ((Get-Date)-$observationStart).TotalSeconds -gt 3) {
                @(Get-Process vrdashboard,vrwebhelper -ErrorAction SilentlyContinue | ForEach-Object {
                    [pscustomobject]@{Name=$_.Name; Pid=$_.Id; Integrity=[ArcRiftIntegrityProbe]::Integrity($_.Id)}
                }) | ConvertTo-Json | Set-Content (Join-Path $out 'normal-dashboard-tokens.json')
                $dashboardTrialState = [pscustomobject]@{Recorded=$true}
                if ($VRChatTrial) {
                    Write-Output ('SteamVR is starting as your normal user. Stop policy: ' + $cutoffLabel + '.')
                } else {
                    Write-Output 'Normal-user dashboard trial: press LEFT Touch menu button. No game launch.'
                }
            }
            if ($ss) {
                if ($steamServerId -and $steamServerId -ne $ss.Id) { throw 'SteamVR server restarted.' }
                $steamServerId = $ss.Id
            } elseif ($steamServerId) { throw 'SteamVR server exited.' }
            if ($sc) {
                if ($steamCompositorId -and $steamCompositorId -ne $sc.Id) { throw 'SteamVR compositor restarted.' }
                $steamCompositorId = $sc.Id
            } elseif ($steamCompositorId) { throw 'SteamVR compositor exited.' }
            if ($DashboardSameIntegrityTrial -and $ss -and $sc) {
                if (-not $dashboardTrialState -and ((Get-Date)-$observationStart).TotalSeconds -gt 3) {
                    $dashboardTrialState = Invoke-ArcRiftDashboardIntegrityTrial -SteamRoot $steamRoot -EvidenceDirectory $out
                    if ($dashboardTrialState) { Write-Output 'Dashboard token inspection complete. Press the LEFT controller menu button to request SteamVR dashboard; do not launch games.' }
                    elseif (((Get-Date)-$observationStart).TotalSeconds -gt 15) { throw 'Dashboard processes never became available for token inspection.' }
                }
                if ($dashboardTrialState -and $dashboardTrialState.Replaced) {
                    foreach ($p in $dashboardTrialState.Processes) {
                        if ($p.HasExited) { throw ('Replacement dashboard process exited: ' + $p.ProcessName) }
                    }
                }
            }
            if (-not $steamReady -and $ss -and $sc -and ((Get-Date) - $observationStart).TotalSeconds -gt 5 -and (Get-Item (Join-Path $out 'client.txt')).Length -gt 0) {
                $steamReady = $true
                'SteamVR processes running and diagnostic output received. Optical verification is user-reported.' | Out-File (Join-Path $out 'session-ready.txt')
                if ($VRChatTrial) {
                    Write-Output ('VR ready. Start your SteamVR game. Stop policy: ' + $cutoffLabel + '. When done, quit the game and use Stop & restore.')
                    # v3: optional read-only frame-timing capture (PresentMon). Never affects the session.
                    # Release 1.1.2: other SteamVR games are added when SteamVR reports them (see the game check below).
                    if ($ManualSession -and (Test-Path -LiteralPath (Join-Path $root 'PresentMon.exe'))) { Start-ArcRiftPresentMon }
                    # v4: give SteamVR's and Meta's compositors high GPU/CPU priority (SteamVR runs as a normal user, so it
                    # cannot raise its own). Lives only as long as those processes; never fails the session.
                    if ($ManualSession) {
                        try {
                            if (-not ('ArcRiftGpuPriority' -as [type])) {
                                Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class ArcRiftGpuPriority {
    [DllImport("gdi32.dll")] public static extern int D3DKMTSetProcessSchedulingPriorityClass(IntPtr hProcess, int priority);
    [DllImport("gdi32.dll")] public static extern int D3DKMTGetProcessSchedulingPriorityClass(IntPtr hProcess, out int priority);
}
'@
                            }
                            foreach ($bp in @(Get-Process vrcompositor,OVRServer_x64 -ErrorAction SilentlyContinue)) {
                                $gpuBefore = -1; $null = [ArcRiftGpuPriority]::D3DKMTGetProcessSchedulingPriorityClass($bp.Handle, [ref]$gpuBefore)
                                $gpuStatus = 'kept'
                                if ($gpuBefore -ge 0 -and $gpuBefore -lt 4) { $gpuStatus = 'set HIGH status=0x' + ([ArcRiftGpuPriority]::D3DKMTSetProcessSchedulingPriorityClass($bp.Handle, 4)).ToString('x8') }
                                $gpuAfter = -1; $null = [ArcRiftGpuPriority]::D3DKMTGetProcessSchedulingPriorityClass($bp.Handle, [ref]$gpuAfter)
                                $cpuBefore = $bp.PriorityClass
                                try { if ($bp.PriorityClass -eq 'Normal') { $bp.PriorityClass = 'High' } } catch {}
                                $boostLine = $bp.Name + ' PID=' + $bp.Id + ' GPU priority ' + $gpuBefore + ' -> ' + $gpuAfter + ' (' + $gpuStatus + '; 2=normal 4=high 5=realtime), CPU ' + $cpuBefore + ' -> ' + $bp.PriorityClass
                                Write-Output ('Performance boost: ' + $boostLine)
                                $boostLine | Add-Content (Join-Path $out 'performance-boost.txt')
                            }
                        } catch { Write-Output ('Performance boost skipped (session unaffected): ' + $_.Exception.Message) }
                    }
                } elseif ($guardedSteamTrial) {
                    Write-Output 'SteamVR diagnostic ready. Remain seated; do not launch games during this bounded trial.'
                } else {
                    Write-Output 'SteamVR ready for user trial. Start games normally through Steam; game processes are not managed or terminated by this harness.'
                }
            }
        }
        if ($presentMonProcess -and (Get-Date) -ge $nextGameCheck) {
            # Add any newly connected SteamVR game to the frame-timing capture. Read-only; never fails the session.
            $nextGameCheck = (Get-Date).AddSeconds(2)
            try {
                $newGames = @()
                $vrserverText = Read-AppendedBridgeLog (Join-Path $steamPath 'logs\vrserver.txt') ([ref]$vrserverLogOffset)
                foreach ($m in [regex]::Matches($vrserverText, 'New Connect message from (.+?\.exe) \(VRApplication_Scene\)')) {
                    $exe = [IO.Path]::GetFileName($m.Groups[1].Value)
                    if ($exe -and $exe -notin $presentMonGames -and $exe -notin $newGames) { $newGames += $exe }
                }
                if ($newGames.Count) { $presentMonGames += $newGames; Start-ArcRiftPresentMon }
            } catch { Write-Output ('Game check for frame timing skipped (session unaffected): ' + $_.Exception.Message) }
        }
        Start-Sleep -Milliseconds 250
    }
    if ($SteamVR) {
        Get-Process | Where-Object { $_.Path -and $_.Path.StartsWith($steamRoot + '\', [StringComparison]::OrdinalIgnoreCase) } | Select-Object Name,Id,Path | Export-Clixml (Join-Path $out 'steamvr-processes.xml')
        if (-not (Get-Process vrserver -ErrorAction SilentlyContinue) -or -not (Get-Process vrcompositor -ErrorAction SilentlyContinue)) { throw 'SteamVR server/compositor did not remain running; inspect native logs.' }
        Write-Output 'SteamVR interval ended; consult native logs for actual initialization/rendering success.'
    } else {
        if ($userStopRequested -and -not $client.HasExited) { Stop-Process -Id $client.Id -Force -ErrorAction Continue }
        $client.WaitForExit()
        Write-Output ('Client exit=' + $client.ExitCode)
        Get-Content (Join-Path $out 'client.txt') | Select-Object -Last 25
        if ($client.ExitCode -ne 0 -and -not $userStopRequested) { throw 'Diagnostic client failed.' }
        if ($isolatedRendererTrial -and -not $userStopRequested) {
            $candidateLogTail += Read-AppendedBridgeLog (Join-Path $root $bridgeLogName) ([ref]$bridgeLogOffset)
            $health = [regex]::Matches($candidateLogTail,'Isolated Present callbacks=[^\r\n]*presented=(\d+)')
            if (-not $health.Count -or [int]$health[$health.Count-1].Groups[1].Value -lt 1) { throw 'No successful isolated backend presentation confirmed.' }
            if ($candidateLogTail -match '(?i:Isolated[^\r\n]*(?:failed|failure|stalled|exceeded|exception|faulted=1))') { throw 'Isolated backend fault detected at trial end.' }
        }
    }
} catch {
    $failed = $true
    Write-Output ('TEST STOP: ' + $_.Exception.Message)
} finally {
    Stop-ArcRiftPresentMon
    if ($VRChatTrial -and (Get-Process VRChat -ErrorAction SilentlyContinue)) {
        Write-Output 'VRChat is still running. Restoring display and runtime now; the game is not force-closed. Close it normally.'
    }
    if ($startupSeedOwned) {
        try {
            Remove-Item -LiteralPath $startupSeed -ErrorAction Stop
            if (Test-Path -LiteralPath $startupSeed) { throw 'Startup identity seed remains.' }
            Write-Output 'Owned startup metadata seed removed; no retained identity remains enabled.'
        } catch { $failed = $true; Write-Output ('STARTUP IDENTITY CLEANUP ERROR: ' + $_.Exception.Message) }
    }
    if ($UserLaunchSteamTrial) {
        'Cancel any pending broker launch.' | Set-Content (Join-Path $out 'user-worker-cancel.txt')
        if ($script:ArcRiftSteamWorkerProcess -and -not $script:ArcRiftSteamWorkerProcess.HasExited) {
            try { $script:ArcRiftSteamWorkerProcess.Kill(); $null = $script:ArcRiftSteamWorkerProcess.WaitForExit(2000) }
            catch { $failed = $true; Write-Output ('WORKER CLEANUP ERROR: ' + $_.Exception.Message) }
        }
    }
    if ($client -and -not $client.HasExited) { Stop-Process -Id $client.Id -Force -ErrorAction Continue }
    if ($steamStarted) {
        # All SteamVR-root processes were absent at preflight. Never stop Steam itself or games.
        try {
            Get-Process vrmonitor -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($steamRoot + '\', [StringComparison]::OrdinalIgnoreCase) } | ForEach-Object { $null = $_.CloseMainWindow() }
            Start-Sleep -Seconds 1
            for ($pass = 0; $pass -lt 3; $pass++) {
                $owned = @(Get-Process | Where-Object { $_.Path -and $_.Path.StartsWith($steamRoot + '\', [StringComparison]::OrdinalIgnoreCase) })
                if (-not $owned.Count) { break }
                $owned | Stop-Process -Force -ErrorAction Continue
                Start-Sleep -Milliseconds 200
            }
            $remaining = @(Get-Process | Where-Object { $_.Path -and $_.Path.StartsWith($steamRoot + '\', [StringComparison]::OrdinalIgnoreCase) })
            if ($remaining.Count) { throw 'Test-started SteamVR processes remain.' }
            foreach ($name in @('vrserver.txt','vrcompositor.txt','vrmonitor.txt','vrstartup.txt','vrdashboard.txt','vrclient_vrdashboard.txt','vrwebhelper_main.txt','vrclient_vrwebhelper_main.txt','vrclient_steam.txt','vrclient_vrcmd.txt','vrclient_vrmonitor.txt')) {
                $log = Join-Path (Join-Path $steamPath 'logs') $name
                if (Test-Path $log) { Copy-Item -LiteralPath $log -Destination $out }
            }
            if (Test-Path $steamConfig) { Copy-Item -LiteralPath $steamConfig -Destination (Join-Path $out 'steamvr-settings-after.json') }
            Write-Output 'Test-started SteamVR processes stopped. No SteamVR settings were explicitly changed by harness.'
        } catch { $failed = $true; Write-Output ('STEAMVR CLEANUP ERROR: ' + $_.Exception.Message) }
    }
    if ($sourceHelper) {
        'Stop and restore source layout.' | Out-File (Join-Path $out 'native-source-stop.txt')
        if (-not $sourceHelper.WaitForExit(6000)) { Stop-Process -Id $sourceHelper.Id -Force -ErrorAction Continue }
        if ($sourceHelper.ExitCode -ne 0) {
            $failed = $true
            Write-Output 'Source helper failed; attempting backup restoration before EDID rollback.'
            if (Test-Path (Join-Path $out 'native-source-backup.bin')) {
                $restore = Start-Process -FilePath (Join-Path $root 'native_source_test.exe') -ArgumentList '--restore' -WorkingDirectory $out -RedirectStandardOutput (Join-Path $out 'native-source-emergency-restore.txt') -PassThru -Wait
                if ($restore.ExitCode -ne 0) { Write-Output 'SOURCE RESTORE ERROR: emergency restoration failed.' }
            }
        }
        Get-Content (Join-Path $out 'native-source.txt') -ErrorAction Continue
    }
    if ($changed) {
        try { Stop-ArcRiftMetaRuntime } catch { $failed = $true; Write-Output ('RUNTIME STOP ERROR: ' + $_.Exception.Message) }
        # Only this session's part of the bridge log, not every earlier session's lines again.
        try { [IO.File]::WriteAllText((Join-Path $out 'bridge-log.txt'), (Read-AppendedBridgeLog (Join-Path $root $bridgeLogName) ([ref]$bridgeLogSessionStart))) }
        catch { Write-Output ('Bridge log copy note (rollback unaffected): ' + $_.Exception.Message) }
        Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Oculus') -Filter 'Service_*.txt' | Where-Object { $_.LastWriteTime -ge $start -and $_.Length -gt 0 } | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $out -ErrorAction Continue
        }
        foreach ($s in $registry) {
            try {
                if ($s.Had) { New-ItemProperty $s.Path -Name $s.Name -Value $s.Value -PropertyType $s.Kind -Force | Out-Null }
                elseif (Test-Path $s.Path) { Remove-ItemProperty $s.Path -Name $s.Name -ErrorAction SilentlyContinue }
            } catch { $failed = $true; Write-Output ('REGISTRY RESTORE ERROR: ' + $_.Exception.Message) }
        }
        foreach ($m in $moves) {
            try {
                if (Test-Path -LiteralPath $m.Temporary) {
                    if (Test-Path -LiteralPath $m.Original) { throw ('Restore conflict: ' + $m.Original) }
                    Move-Item -LiteralPath $m.Temporary -Destination $m.Original
                }
                if ((Get-FileHash -LiteralPath $m.Original -Algorithm SHA256).Hash -ne $m.Hash) { throw ('Hash mismatch: ' + $m.Original) }
                Write-Output ('Plugin restored/hash verified: ' + [IO.Path]::GetFileName($m.Original))
            } catch { $failed = $true; Write-Output ('PLUGIN RESTORE ERROR: ' + $_.Exception.Message) }
        }
        foreach ($p in $createdKeys) {
            if (Test-Path $p) { $k = Get-Item $p; if ($k.ValueCount -eq 0 -and $k.SubKeyCount -eq 0) { Remove-Item $p -ErrorAction Continue } }
        }
        if ($virtualDisabled) { Enable-PnpDevice -InstanceId 'ROOT\DISPLAY\0000' -Confirm:$false -ErrorAction Continue }
        if ($edidChanged) {
            try {
                Remove-ItemProperty -LiteralPath $edidKey -Name '0' -ErrorAction SilentlyContinue
                if (Test-Path -LiteralPath $edidKey) {
                    $k = Get-Item -LiteralPath $edidKey
                    if ($k.ValueCount -eq 0 -and $k.SubKeyCount -eq 0) { Remove-Item -LiteralPath $edidKey }
                }
                & pnputil.exe /restart-device $monitorInstance
                if ($LASTEXITCODE -ne 0) {
                    # v5: the Rift S display only exists while Meta's runtime runs; start it, then retry.
                    Start-Service OVRService -ErrorAction Continue
                    $monitorRestarted = $false
                    for ($i = 0; $i -lt 20 -and -not $monitorRestarted; $i++) {
                        Start-Sleep -Seconds 2
                        & pnputil.exe /restart-device $monitorInstance
                        if ($LASTEXITCODE -eq 0) { $monitorRestarted = $true }
                    }
                    if (-not $monitorRestarted) { throw 'Monitor restart during rollback failed.' }
                }
                Start-Sleep -Seconds 3
                & (Join-Path $root 'display_probe.exe') | Out-File -Encoding utf8 (Join-Path $out 'physical-display-after-rollback.txt')
                Write-Output 'Original absent EDID override restored; monitor restarted.'
            } catch { $failed = $true; Write-Output ('EDID RESTORE ERROR: ' + $_.Exception.Message) }
        }
        Start-Service OVRService -ErrorAction Continue
        try {
            $restored = $false
            for ($attempt = 0; $attempt -lt 10; $attempt++) {
                Start-Sleep -Seconds 1
                & (Join-Path $root 'display_probe.exe') | Out-File -Encoding utf8 (Join-Path $out 'physical-after-original-runtime.txt')
                if ($LASTEXITCODE -ne 0) { continue }
                # A probe taken while the display is still settling may list no active layout yet: retry, don't fail.
                try { $afterLayouts = Get-ActiveLayouts (Get-Content (Join-Path $out 'physical-after-original-runtime.txt') -Raw) } catch { continue }
                $same = $afterLayouts.Count -eq $baselineLayouts.Count
                foreach ($id in $baselineLayouts.Keys) { if ($afterLayouts[$id] -ne $baselineLayouts[$id]) { $same = $false } }
                if ($same) { $restored = $true; break }
            }
            if (-not $restored) { throw 'Display source/signal layouts differ from baseline; manual recovery required.' }
            if (Test-Path -LiteralPath $edidKey) { throw 'Temporary EDID override still present.' }
            foreach ($s in $registry) {
                $k = Get-Item $s.Path -ErrorAction SilentlyContinue
                $had = $k -and ($k.GetValueNames() -contains $s.Name)
                if ([bool]$had -ne $s.Had -or ($s.Had -and ($k.GetValue($s.Name) -ne $s.Value -or $k.GetValueKind($s.Name).ToString() -ne $s.Kind))) { throw ('Registry mismatch: ' + $s.Name) }
            }
            if ((Get-Service OVRService).Status -ne 'Running') { throw 'Original runtime service not running.' }
            if ($virtualDisabled -and (Get-PnpDevice -InstanceId 'ROOT\DISPLAY\0000' -PresentOnly).Status -ne 'OK') { throw 'Virtual Monitor was not restored.' }
            Write-Output 'ROLLBACK VERIFIED: all active source/signal layouts match baseline; registry, EDID, service and Virtual Monitor restored.'
            $rollbackVerified=$true
        } catch { $failed = $true; Write-Output ('ROLLBACK VERIFICATION ERROR: ' + $_.Exception.Message) }
    }
    if ($sessionLock) {
        if ($ManualSession -and (Test-Path $manualRecoveryFile)) {
            $state=Get-Content $manualRecoveryFile -Raw | ConvertFrom-Json
            $state.CleanupVerified=$rollbackVerified -or -not $changed
            $state | ConvertTo-Json | Set-Content $manualRecoveryFile
        }
        if (-not $ManualSession -or $rollbackVerified -or -not $changed) { Remove-Item -LiteralPath $activeSession -ErrorAction Continue }
        else { Write-Output 'Manual recovery marker retained. Run RECOVER in this folder after harness exits.' }
        $sessionLock.Dispose()
        Remove-Item -LiteralPath $sessionLockPath -ErrorAction Continue
    }
    Stop-Transcript
}
if ($failed) { exit 1 }
