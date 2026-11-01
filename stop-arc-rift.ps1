# Requests normal harness cleanup. Does NOT kill processes or restore source-only modes.
$ErrorActionPreference = 'Stop'
$marker = Join-Path $PSScriptRoot 'active-test.xml'
if (-not (Test-Path -LiteralPath $marker)) { Write-Output 'No active Arc Rift test.'; exit 0 }
$session = Import-Clixml -LiteralPath $marker
$directory = [IO.Path]::GetFullPath($session.SessionDirectory)
if ((Split-Path $directory) -ne $PSScriptRoot -or (Split-Path $directory -Leaf) -notmatch '^d3d11-\d{8}-\d{6}$') { throw 'Invalid active test path; no action taken.' }
if (-not (Get-Process -Id $session.HarnessPid -ErrorAction SilentlyContinue)) { throw 'Harness is no longer running; full recovery needs investigation. No settings changed.' }
'User requested clean stop.' | Out-File -LiteralPath (Join-Path $directory 'session-stop.txt')
Write-Output 'Stop requested. Allow the harness to complete and verify full rollback.'
