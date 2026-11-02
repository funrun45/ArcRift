# Requests normal harness cleanup. Does NOT kill processes or restore source-only modes.
$ErrorActionPreference = 'Stop'
trap { Write-Output $_.Exception.Message; exit 1 } # plain message for ArcRift Control, not a PowerShell error dump
$marker = Join-Path $PSScriptRoot 'active-test.xml'
if (-not (Test-Path -LiteralPath $marker)) { Write-Output 'No active Arc Rift test.'; exit 0 }
$session = Import-Clixml -LiteralPath $marker
$directory = [IO.Path]::GetFullPath($session.SessionDirectory)
if ((Split-Path $directory) -ne $PSScriptRoot -or (Split-Path $directory -Leaf) -notmatch '^d3d11-\d{8}-\d{6}$') { throw 'Invalid active test path; no action taken.' }
$harness = Get-Process -Id $session.HarnessPid -ErrorAction SilentlyContinue
# Release 1.1.2: a program that later reused the harness PID started after the marker was written.
$created = $null; if ($harness) { try { $created = $harness.StartTime } catch { } }
if (-not $harness -or ($created -and $session.Started -and $created -gt $session.Started.AddSeconds(5))) { throw 'Harness is no longer running; full recovery needs investigation. No settings changed.' }
'User requested clean stop.' | Out-File -LiteralPath (Join-Path $directory 'session-stop.txt')
Write-Output 'Stop requested. Allow the harness to complete and verify full rollback.'
