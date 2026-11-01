# Read-only process token integrity check. Never enables privileges or opens a GPU.
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ArcRiftIntegrityProbe {
    [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr OpenProcess(uint access,bool inherit,int pid);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    [DllImport("advapi32.dll",SetLastError=true)] static extern bool OpenProcessToken(IntPtr process,uint access,out IntPtr token);
    [DllImport("advapi32.dll",SetLastError=true)] static extern bool GetTokenInformation(IntPtr token,int kind,IntPtr data,int bytes,out int needed);
    [DllImport("advapi32.dll")] static extern IntPtr GetSidSubAuthorityCount(IntPtr sid);
    [DllImport("advapi32.dll")] static extern IntPtr GetSidSubAuthority(IntPtr sid,uint index);
    public static int Integrity(int pid) {
        IntPtr process=OpenProcess(0x1000,false,pid),token=IntPtr.Zero,data=IntPtr.Zero;
        if(process==IntPtr.Zero) return -Marshal.GetLastWin32Error();
        try {
            if(!OpenProcessToken(process,8,out token)) return -Marshal.GetLastWin32Error();
            int needed;
            GetTokenInformation(token,25,IntPtr.Zero,0,out needed);
            if(needed<=0) return -Marshal.GetLastWin32Error();
            data=Marshal.AllocHGlobal(needed);
            if(!GetTokenInformation(token,25,data,needed,out needed)) return -Marshal.GetLastWin32Error();
            IntPtr sid=Marshal.ReadIntPtr(data);
            byte count=Marshal.ReadByte(GetSidSubAuthorityCount(sid));
            if(count==0) return -1;
            return Marshal.ReadInt32(GetSidSubAuthority(sid,(uint)(count-1)));
        } finally {
            if(data!=IntPtr.Zero) Marshal.FreeHGlobal(data);
            if(token!=IntPtr.Zero) CloseHandle(token);
            CloseHandle(process);
        }
    }
}
'@
$processes = @(Get-Process -Id $PID)
$processes += @(Get-Process OVRServer_x64,vrserver,vrcompositor,steam,explorer -ErrorAction SilentlyContinue)
foreach ($p in $processes) {
    $rid = [ArcRiftIntegrityProbe]::Integrity($p.Id)
    $level = switch ($rid) { 4096 {'Low'} 8192 {'Medium'} 8448 {'MediumPlus'} 12288 {'High'} 16384 {'System'} default {'Other/Error'} }
    Write-Output ($p.Name + ' PID=' + $p.Id + ' Integrity=' + $level + ' RID=' + $rid)
}
