# Writes release-manifest.json: SHA-256 of each program the session script verifies before a session.
$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot
$names = 'arc_rift_bridge.dll', 'native_source_test.exe', 'native_source_session.exe', 'display_probe.exe', 'bridge_selftest.exe'
$manifest = [ordered]@{}
foreach ($name in $names) { $manifest[$name] = (Get-FileHash -LiteralPath $name -Algorithm SHA256).Hash }
$manifest | ConvertTo-Json | Set-Content -LiteralPath 'release-manifest.json' -Encoding UTF8
Write-Output ('Manifest: ' + ($names -join ', '))
