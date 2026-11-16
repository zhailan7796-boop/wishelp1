#Requires AutoHotkey v2.0 64-bit
#NoTrayIcon
#Warn VarUnset, StdOut
#Include ..\lib\Native.ahk
#Include ..\lib\UIA.ahk

; Optional, read-only desktop check. This retains the old scanning path as an
; independent baseline and does not depend on generated results or archives.
class LegacyTaskbarUIA {
    __New() {
        this.Client := ComObject("{E22AD333-B25F-460C-83D0-0581107395C9}",
            "{34723AFF-0C9D-49D0-9896-7AB52DF8CD8A}")
        ComCall(61,this.Client,"uint",180)
        ComCall(63,this.Client,"uint",180)
        ptr := 0
        ComCall(20,this.Client,"ptr*",&ptr)
        this.Cache := ComValue(13,ptr,1)
        ComCall(7,this.Cache,"int",1)
        for property in [30003,30005,30011,30012]
            ComCall(3,this.Cache,"int",property)
        ptr := 0
        ComCall(16,this.Client,"ptr*",&ptr)
        this.Walker := ComValue(13,ptr,1)
    }
    static Text(element,method) {
        ptr := 0
        ComCall(method,element,"ptr*",&ptr)
        try return ptr ? StrGet(ptr) : ""
        finally {
            if ptr
                DllCall("oleaut32\SysFreeString","ptr",ptr)
        }
    }
    Buttons(hwnd,appOnly := true) {
        ptr := 0
        ComCall(10,this.Client,"ptr",hwnd,"ptr",this.Cache,"ptr*",&ptr)
        root := ComValue(13,ptr,1)
        ptr := 0
        ComCall(21,this.Client,"ptr*",&ptr)
        condition := ComValue(13,ptr,1)
        ptr := 0
        ComCall(8,root,"int",4,"ptr",condition,"ptr",this.Cache,"ptr*",&ptr)
        if !ptr
            return []
        elements := ComValue(13,ptr,1), count := 0, result := []
        ComCall(3,elements,"int*",&count)
        Loop Min(count,300) {
            ptr := 0
            ComCall(4,elements,"int",A_Index-1,"ptr*",&ptr)
            element := ComValue(13,ptr,1)
            peer := LegacyTaskbarUIA.Text(element,62)
            if appOnly && peer != "Taskbar.TaskListButtonAutomationPeer"
                continue
            rect := Buffer(16,0)
            ComCall(43,element,"ptr",rect)
            result.Push({Id:LegacyTaskbarUIA.Text(element,61),Name:LegacyTaskbarUIA.Text(element,55),
                Peer:peer,Rect:ScreenRect.FromBuffer(rect)})
        }
        return result
    }
}

class UiaSnapshotChecks {
    static Count := 0
    static Assert(value,label) {
        if !value
            throw Error(label)
        this.Count += 1
    }
    static Same(a,b,diagnostics := false) {
        if a.Length != b.Length
            return false
        for number,item in a {
            other := b[number]
            if !(item.Id == other.Id)
                return false
            for property in ["L","T","R","B"] {
                if item.Rect.%property% != other.Rect.%property%
                    return false
            }
            if diagnostics && (!(item.Name == other.Name) || !(item.Peer == other.Peer))
                return false
        }
        return true
    }
    static Equal(old,new,diagnostics,label) {
        this.Assert(old.Length = new.Length,label . ": count")
        for number,item in old {
            other := new[number]
            this.Assert(item.Id == other.Id,label . ": ID/order " . number)
            for property in ["L","T","R","B"]
                this.Assert(item.Rect.%property% = other.Rect.%property%,label . ": rectangle " . number . "/" . property)
            if diagnostics {
                this.Assert(item.Name == other.Name,label . ": name " . number)
                this.Assert(item.Peer == other.Peer,label . ": peer " . number)
            }
        }
    }
    static ScanAll(client,bars,minimal) {
        count := 0
        for bar in bars {
            items := minimal ? client.Buttons(bar,true,false) : client.Buttons(bar)
            count += items.Length
        }
        return count
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
    legacy := LegacyTaskbarUIA(), current := TaskbarUIA()
    bars := WinGetList("ahk_class Shell_TrayWnd")
    for hwnd in WinGetList("ahk_class Shell_SecondaryTrayWnd")
        bars.Push(hwnd)
    stableBars := 0, changedBars := 0, buttons := 0, hits := 0, covered := 0, changedHits := 0
    for bar in bars {
        stable := false
        ; UI updates are allowed throughout this read-only test. Compare only
        ; when the old scan brackets an unchanged layout and diagnostic data.
        Loop 3 {
            before := legacy.Buttons(bar)
            minimal := current.Buttons(bar,true,false)
            diagnostic := current.Buttons(bar)
            after := legacy.Buttons(bar)
            if UiaSnapshotChecks.Same(before,after,true) {
                stable := true
                break
            }
        }
        if !stable {
            changedBars += 1
            FileAppend("SKIP changing-taskbar-snapshot`n","*","UTF-8")
            continue
        }
        stableBars += 1
        buttons += minimal.Length
        UiaSnapshotChecks.Equal(before,minimal,false,"Minimal batch")
        UiaSnapshotChecks.Equal(before,diagnostic,true,"Diagnostic batch")
        for item in minimal {
            if item.Id = "" || item.Rect.W <= 0 || item.Rect.H <= 0
                continue
            x := (item.Rect.L+item.Rect.R)//2, y := (item.Rect.T+item.Rect.B)//2
            if Desktop.RootAt(x,y) != bar {
                covered += 1
                continue
            }
            hit := current.Hit(x,y)
            if hit.Kind != "app" || !(hit.Id == item.Id) {
                fresh := legacy.Buttons(bar)
                if !UiaSnapshotChecks.Same(after,fresh) || Desktop.RootAt(x,y) != bar {
                    changedHits += 1
                    continue
                }
            }
            UiaSnapshotChecks.Assert(hit.Kind = "app" && hit.Id == item.Id,"Read-only center hit matches batch ID")
            hits += 1
        }
    }
    FileAppend("SNAPSHOT taskbars=" . bars.Length . "; stable-bars=" . stableBars . "; changing-bars=" . changedBars
        . "; application-buttons=" . buttons . "; center-hits=" . hits . "; covered-centers=" . covered
        . "; changing-hit-skips=" . changedHits . "`n","*","UTF-8")
    UiaSnapshotChecks.Assert(stableBars > 0 && buttons > 0,"Actual taskbar application buttons are available")
    FileAppend("PASS real-taskbar batch-cache equivalence; assertions=" . UiaSnapshotChecks.Count . "`n","*","UTF-8")

    ; Each timed round re-queries both taskbars and reads all returned fields;
    ; unlike the identity benchmark, this includes the UIA scanning work.
    rounds := A_Args.Length ? Integer(A_Args[1]) : 1
    UiaSnapshotChecks.Assert(rounds >= 1 && rounds <= 5,"Benchmark rounds are bounded")
    samples := 3, oldTotal := 0, newTotal := 0
    oldCall := () => UiaSnapshotChecks.ScanAll(legacy,bars,false)
    newCall := () => UiaSnapshotChecks.ScanAll(current,bars,true)
    Loop samples {
        if Mod(A_Index,2) {
            oldMs := UiaSnapshotChecks.Time(oldCall,rounds)
            newMs := UiaSnapshotChecks.Time(newCall,rounds)
        } else {
            newMs := UiaSnapshotChecks.Time(newCall,rounds)
            oldMs := UiaSnapshotChecks.Time(oldCall,rounds)
        }
        oldTotal += oldMs, newTotal += newMs
        FileAppend("PERF sample=" . A_Index . "; rounds=" . rounds . "; legacy-ms=" . Round(oldMs,3)
            . "; batch-ms=" . Round(newMs,3) . "`n","*","UTF-8")
    }
    FileAppend("PERF real-taskbar-scanning: rounds=" . (rounds*samples)
        . "; legacy-ms-per-round=" . Round(oldTotal/(rounds*samples),3)
        . "; batch-ms-per-round=" . Round(newTotal/(rounds*samples),3)
        . "; ratio=" . Round(newTotal/oldTotal,3) . "; includes-query-and-property-reads=1; excludes-controller-identity-resolution=1`n","*","UTF-8")
    ExitApp(0)
} catch as e {
    FileAppend("FAIL " . e.Message . " (line " . e.Line . ")`n","*","UTF-8")
    ExitApp(1)
}
