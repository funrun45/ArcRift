# Launch through the existing interactive Explorer desktop, never an elevated fallback.
# Caller must separately verify the resulting process token before using this for VR.
function Start-ArcRiftNormalUserPowerShell {
    param([Parameter(Mandatory=$true)][string]$ScriptText)
    $ErrorActionPreference = 'Stop'
    if (-not ('ArcRiftIntegrityProbe' -as [type])) {
        $null = & (Join-Path $PSScriptRoot 'probe-process-integrity.ps1')
    }
    $session = (Get-Process -Id $PID).SessionId
    # Release 1.3: Windows can run more than one explorer.exe (with "Launch folder windows in a separate process", or
    # for a moment whenever a folder is opened). Only the one that owns the desktop does the launching below, so that
    # is the one checked; requiring exactly one explorer.exe refused to start on such PCs.
    $shellPid = [ArcRiftIntegrityProbe]::ShellProcessId()
    $shell = if ($shellPid -gt 0) { Get-Process -Id $shellPid -ErrorAction SilentlyContinue }
    if (-not $shell -or $shell.ProcessName -ne 'explorer' -or $shell.SessionId -ne $session -or
        [ArcRiftIntegrityProbe]::Integrity($shellPid) -ne 8192) {
        throw 'The Windows desktop (explorer.exe) must be running as your normal user. Restart Windows Explorer from Task Manager, then start the session again; no changes made.'
    }
    $windows = $null
    $shellWindows = $null
    $desktop = $null
    $application = $null
    try {
        $windows = New-Object -ComObject Shell.Application
        $shellWindows = $windows.Windows()
        $location = 0
        $rootLocation = 0
        $hwnd = 0
        # SWC_DESKTOP=8, SWFO_NEEDDISPATCH=1: get the existing desktop's automation object.
        $desktop = $shellWindows.FindWindowSW([ref]$location, [ref]$rootLocation, 8, [ref]$hwnd, 1)
        if (-not $desktop) { throw 'Existing Explorer desktop automation is unavailable.' }
        $application = $desktop.Document.Application
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($ScriptText))
        $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $application.ShellExecute($exe, ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' + $encoded), $PSScriptRoot, 'open', 0)
    } finally {
        foreach ($item in @($application, $desktop, $shellWindows, $windows)) {
            if ($null -ne $item -and [Runtime.InteropServices.Marshal]::IsComObject($item)) {
                $null = [Runtime.InteropServices.Marshal]::ReleaseComObject($item)
            }
        }
    }
}
