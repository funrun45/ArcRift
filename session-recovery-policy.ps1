function Get-ArcRiftRecoveryLayouts([string]$Text) {
    $layouts = @{}
    $pattern = '(?m)^\s*target=(\d+) [^\r\n]*pathFlags=1[^\r\n]*\r?\n[^\r\n]*\r?\n\s*(signal=[^\r\n]+)\r?\n\s*(source=[^\r\n]+)'
    foreach ($m in [regex]::Matches($Text,$pattern)) { $layouts[$m.Groups[1].Value]=$m.Groups[2].Value.Trim()+' '+$m.Groups[3].Value.Trim() }
    if (-not $layouts.Count) { throw 'No display layouts parsed; recovery cannot claim success.' }
    return $layouts
}
function Assert-ArcRiftRecoveryScope($Registry,$Plugins,$Edid) {
    $allowed = @(
        'HKLM:\SOFTWARE\Oculus|DirectDisplayDLL',
        'HKLM:\SOFTWARE\Oculus|ForceGPUDriverVersionAcceptance',
        'HKLM:\SOFTWARE\WOW6432Node\Oculus VR, LLC\Oculus\Config|PreventDashLaunch'
    )
    if (@($Registry).Count -ne 3 -or @($Plugins).Count -ne 3) { throw 'Recovery backup count mismatch.' }
    $seen = @{}
    foreach ($r in $Registry) {
        $key=$r.Path+'|'+$r.Name
        if ($key -notin $allowed -or $seen.ContainsKey($key)) { throw 'Recovery registry scope mismatch.' }
        $seen[$key]=$true
    }
    $seen=@{}
    foreach ($p in $Plugins) {
        $name=[IO.Path]::GetFileName($p.Original)
        $expected='C:\Program Files\Meta Horizon\Support\oculus-runtime\server-plugins\'+$name
        if ($name -notin @('RemoteHeadset.dll','RemoteHeadset_v55.dll','RemoteHeadsetDisco.dll') -or
            $p.Original -ne $expected -or $p.Temporary -ne ($expected+'.arc-rift-d3d11-disabled') -or
            $p.Hash -notmatch '^[a-fA-F0-9]{64}$' -or $seen.ContainsKey($name)) { throw 'Recovery plugin scope mismatch.' }
        $seen[$name]=$true
    }
    $cfgInstance = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'arcrift-config.json') -Raw | ConvertFrom-Json).monitorInstance
    if ($Edid.KeyExisted -or -not $cfgInstance -or $Edid.Instance -ne $cfgInstance) { throw 'Recovery EDID scope mismatch.' }
}
