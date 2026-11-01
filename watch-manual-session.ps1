# Independent best-effort recovery if the owning harness dies unexpectedly.
param([Parameter(Mandatory=$true)][string]$SessionDirectory)
$ErrorActionPreference='Stop'
$statePath=Join-Path $SessionDirectory 'manual-recovery-state.json'
$state=Get-Content $statePath -Raw | ConvertFrom-Json
$owner=Get-Process -Id $state.OwnerPid -ErrorAction SilentlyContinue
if ($owner -and $owner.StartTime.ToUniversalTime().ToFileTimeUtc().ToString() -eq $state.OwnerCreated) {
    $null=$owner.Handle
    'Independent recovery watcher attached.' | Set-Content (Join-Path $SessionDirectory 'manual-watcher-ready.txt')
    $owner.WaitForExit()
}
$state=Get-Content $statePath -Raw | ConvertFrom-Json
if ($state.CleanupVerified) { exit 0 }
try { & (Join-Path $PSScriptRoot 'recover-manual-session.ps1') -SessionDirectory $SessionDirectory }
catch { $_ | Out-String | Set-Content (Join-Path $SessionDirectory 'manual-watcher-error.txt'); exit 1 }
