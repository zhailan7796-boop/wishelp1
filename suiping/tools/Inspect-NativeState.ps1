param()
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$dllName = ((Get-Content -LiteralPath (Join-Path $root 'native\bin\runtime.ini') | Where-Object { $_ -like 'Dll=*' }) -replace '^Dll=','').Trim()
Add-Type @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
public static class FollowNativeInspection {
    [DllImport("user32.dll", SetLastError=true)] static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
    [DllImport("user32.dll")] static extern bool CloseDesktop(IntPtr desktop);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool GetUserObjectInformation(IntPtr handle, int index, StringBuilder text, uint length, out uint needed);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr OpenFileMapping(uint access, bool inherit, string name);
    [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr MapViewOfFile(IntPtr mapping, uint access, uint high, uint low, UIntPtr bytes);
    [DllImport("kernel32.dll")] static extern bool UnmapViewOfFile(IntPtr view);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll")] public static extern ulong GetTickCount64();
    public static byte[] Read(string dll, out string name) {
        IntPtr desktop = OpenInputDesktop(0, false, 1);
        if (desktop == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
        var text = new StringBuilder(256); uint needed;
        try { if (!GetUserObjectInformation(desktop, 2, text, 512, out needed)) throw new Win32Exception(Marshal.GetLastWin32Error()); }
        finally { CloseDesktop(desktop); }
        ulong hash = 1469598103934665603UL;
        unchecked { foreach (char ch in (dll + text).ToLowerInvariant()) { hash ^= ch; hash *= 1099511628211UL; } }
        name = "Local\\TaskbarFollow.Native." + hash.ToString("x16");
        IntPtr mapping = OpenFileMapping(4, false, name);
        if (mapping == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
        try {
            IntPtr view = MapViewOfFile(mapping, 4, 0, 0, (UIntPtr)397552);
            if (view == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
            try { var bytes = new byte[397552]; Marshal.Copy(view, bytes, 0, bytes.Length); return bytes; }
            finally { UnmapViewOfFile(view); }
        } finally { CloseHandle(mapping); }
    }
}
'@
$mappingName = ''
$bytes = [FollowNativeInspection]::Read((Join-Path $root ('native\bin\' + $dllName)), [ref]$mappingName)
if ([BitConverter]::ToUInt32($bytes,0) -ne 0x54464E32) { throw 'Unrecognized native shared state.' }
$now = [FollowNativeInspection]::GetTickCount64()
$cacheIndex = [BitConverter]::ToUInt32($bytes,16)
$cacheCount = [BitConverter]::ToUInt32($bytes,(232+4*$cacheIndex))
$entries = @(for ($entryIndex=0; $entryIndex -lt $cacheCount; $entryIndex++) {
    $entryOffset=240+(64*$cacheIndex+$entryIndex)*3104
    [pscustomobject]@{
        Taskbar=[BitConverter]::ToUInt64($bytes,$entryOffset)
        Rect=@([BitConverter]::ToInt32($bytes,$entryOffset+8),[BitConverter]::ToInt32($bytes,$entryOffset+12),[BitConverter]::ToInt32($bytes,$entryOffset+16),[BitConverter]::ToInt32($bytes,$entryOffset+20))
        Flags=[BitConverter]::ToUInt32($bytes,$entryOffset+24)
        Candidates=[BitConverter]::ToUInt32($bytes,$entryOffset+28)
        Id=[Text.Encoding]::Unicode.GetString($bytes,$entryOffset+32,512).Split([char]0)[0]
    }
})
[pscustomobject][ordered]@{
    Component=$dllName
    OwnerPid=[BitConverter]::ToUInt32($bytes,4)
    Running=[BitConverter]::ToUInt32($bytes,8)
    Enabled=[BitConverter]::ToUInt32($bytes,12)
    HeartbeatAgeMs=$now-[BitConverter]::ToUInt64($bytes,48)
    CacheAgeMs=$now-[BitConverter]::ToUInt64($bytes,56)
    Serial=[BitConverter]::ToUInt32($bytes,36)
    InputEpoch=[BitConverter]::ToUInt32($bytes,40)
    Armed=[BitConverter]::ToUInt64($bytes,88)
    Created=[BitConverter]::ToUInt64($bytes,96)
    Restored=[BitConverter]::ToUInt64($bytes,104)
    Activated=[BitConverter]::ToUInt64($bytes,112)
    FirstShown=[BitConverter]::ToUInt64($bytes,120)
    Cancelled=[BitConverter]::ToUInt64($bytes,128)
    EventNumber=[BitConverter]::ToUInt64($bytes,136)
    LastKind=[BitConverter]::ToUInt32($bytes,144)
    LastPid=[BitConverter]::ToUInt32($bytes,148)
    LastWindow=[BitConverter]::ToUInt64($bytes,152)
    Target=[Text.Encoding]::Unicode.GetString($bytes,168,64).Trim([char]0)
    CachedButtons=$cacheCount
    Entries=$entries
} | ConvertTo-Json -Depth 5
