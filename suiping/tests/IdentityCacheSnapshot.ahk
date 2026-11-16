#Requires AutoHotkey v2.0 64-bit
#NoTrayIcon
#Warn VarUnset, StdOut
#Include ..\lib\Native.ahk
#Include ..\lib\UIA.ahk
#Include ..\lib\NativeEngine.ahk

; Keep the old resolver local so this optional read-only check does not depend
; on generated results or archived source files.
class LegacyNativeEngine {
    static ResolveEntry(id,windows,identity) {
        candidates := [], paths := Map()
        for item in windows {
            if identity.Match(id,item.Data) {
                if candidates.Length < 32
                    candidates.Push(item)
                if item.Data.Path != ""
                    paths[StrLower(item.Data.Path)] := item.Data.Path
            }
        }
        path := ""
        if paths.Count = 1 {
            for pathKey,pathValue in paths {
                path := pathValue
                break
            }
        }
        if !paths.Count
            path := identity.NativePath(id)
        if StrLen(path) >= 1024
            path := ""
        cold := path != "" && FileExist(path) && RegExMatch(path,"i)^[a-z]:\\.*\.exe$")
        requireId := cold && identity.NativeRequiresAppId(id,path)
        return {Id:id,Path:path,Candidates:candidates,Flags:(cold?1:0)|(requireId?2:0)}
    }
}

class SnapshotChecks {
    static Count := 0
    static Assert(value,label) {
        if !value
            throw Error(label)
        this.Count += 1
    }
    static Legacy(buttons,windows,identity) {
        records := []
        for button in buttons {
            try {
                record := LegacyNativeEngine.ResolveEntry(button.Id,windows,identity)
                record.Bar := button.Bar, record.Rect := button.Rect
                records.Push(record)
            } catch {
                continue
            }
            if records.Length >= 64
                break
        }
        return records
    }
    static EqualRecords(old,new) {
        this.Assert(old.Length = new.Length,"Snapshot record count")
        for number,a in old {
            b := new[number]
            for property in ["Id","Bar","Path","Flags"]
                this.Assert(a.%property% == b.%property%,"Record " . number . " property " . property)
            for property in ["L","T","R","B"]
                this.Assert(a.Rect.%property% = b.Rect.%property%,"Record " . number . " rect " . property)
            this.Assert(a.Candidates.Length = b.Candidates.Length,"Record " . number . " candidate count")
            for candidate,item in a.Candidates {
                this.Assert(item.Hwnd = b.Candidates[candidate].Hwnd,"Record " . number . " HWND order")
                this.Assert(item.Data.Pid = b.Candidates[candidate].Data.Pid,"Record " . number . " PID order")
            }
        }
    }
    static Time(callback,rounds) {
        DllCall("kernel32\QueryPerformanceFrequency","int64*",&frequency := 0)
        DllCall("kernel32\QueryPerformanceCounter","int64*",&started := 0)
        Loop rounds
            callback.Call()
        DllCall("kernel32\QueryPerformanceCounter","int64*",&finished := 0)
        return (finished-started)*1000/frequency
    }
}

try {
    Desktop.Physical()
    SplitPath(A_ScriptDir,,&root)
    identity := WindowIdentity(root . "\settings.ini")
    windows := []
    for hwnd in WinGetList() {
        if Desktop.Eligible(hwnd)
            windows.Push({Hwnd:hwnd,Data:identity.Get(hwnd)})
    }
    uia := TaskbarUIA(), buttons := [], bars := 0, ids := Map()
    ids.CaseSense := true
    for cls in ["Shell_TrayWnd","Shell_SecondaryTrayWnd"] {
        for bar in WinGetList("ahk_class " . cls) {
            bars += 1
            for button in uia.Buttons(bar) {
                if button.Id = "" || StrLen(button.Id) >= 256 || button.Rect.W <= 0 || button.Rect.H <= 0
                    continue
                buttons.Push({Id:button.Id,Bar:bar,Rect:button.Rect})
                ids[button.Id] := true
            }
        }
    }
    FileAppend("SNAPSHOT bars=" . bars . "; buttons=" . buttons.Length . "; eligible-windows=" . windows.Length
        . "; mappings=" . identity.Mappings.Count . "; native-paths=" . identity.NativePaths.Count . "`n","*","UTF-8")
    SnapshotChecks.Assert(bars >= 1 && buttons.Length > 0,"Actual desktop taskbar buttons are available")
    old := SnapshotChecks.Legacy(buttons,windows,identity)
    new := NativeEngine.ResolveButtons(buttons,windows,identity)
    SnapshotChecks.EqualRecords(old,new)
    candidates := 0, cold := 0, unsupported := 0
    for record in new {
        candidates += record.Candidates.Length
        cold += !!(record.Flags & 1)
        unsupported += !record.Candidates.Length && !record.Flags
    }
    FileAppend("PASS actual-desktop-snapshot: bars=" . bars . "; buttons=" . buttons.Length
        . "; unique-ids=" . ids.Count . "; eligible-windows=" . windows.Length . "; records=" . new.Length
        . "; candidate-references=" . candidates . "; cold-enabled-records=" . cold
        . "; unsupported-records=" . unsupported . "; equality-assertions=" . SnapshotChecks.Count . "`n","*","UTF-8")
    rounds := 50, oldTotal := 0, newTotal := 0
    oldCall := () => SnapshotChecks.Legacy(buttons,windows,identity)
    newCall := () => NativeEngine.ResolveButtons(buttons,windows,identity)
    Loop 5 {
        if Mod(A_Index,2) {
            oldMs := SnapshotChecks.Time(oldCall,rounds)
            newMs := SnapshotChecks.Time(newCall,rounds)
        } else {
            newMs := SnapshotChecks.Time(newCall,rounds)
            oldMs := SnapshotChecks.Time(oldCall,rounds)
        }
        oldTotal += oldMs, newTotal += newMs
        FileAppend("PERF sample=" . A_Index . "; rounds=" . rounds . "; legacy-ms=" . Round(oldMs,3)
            . "; indexed-ms=" . Round(newMs,3) . "`n","*","UTF-8")
    }
    FileAppend("PERF fixed-snapshot-resolution-only: rounds=" . (rounds*5)
        . "; legacy-ms-per-round=" . Round(oldTotal/(rounds*5),4)
        . "; indexed-ms-per-round=" . Round(newTotal/(rounds*5),4)
        . "; ratio=" . Round(newTotal/oldTotal,3)
        . "; excludes-UIA-enumeration-and-process-identity-reads=1`n","*","UTF-8")
    ExitApp(0)
} catch as e {
    FileAppend("FAIL " . e.Message . " (line " . e.Line . ")`n","*","UTF-8")
    ExitApp(1)
}
