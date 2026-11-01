# Launch through the existing interactive Explorer desktop, never an elevated fallback.
# Caller must separately verify the resulting process token before using this for VR.
function Start-ArcRiftNormalUserPowerShell {
    param([Parameter(Mandatory=$true)][string]$ScriptText)
    $ErrorActionPreference = 'Stop'
    if (-not ('ArcRiftIntegrityProbe' -as [type])) {
        $null = & (Join-Path $PSScriptRoot 'probe-process-integrity.ps1')
    }
    $session = (Get-Process -Id $PID).SessionId
    $explorers = @(Get-Process explorer -ErrorAction Stop | Where-Object { $_.SessionId -eq $session })
    if ($explorers.Count -ne 1 -or [ArcRiftIntegrityProbe]::Integrity($explorers[0].Id) -ne 8192) {
        throw 'A single Medium-integrity Explorer in the current session is required.'
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
