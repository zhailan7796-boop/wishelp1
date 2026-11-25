#Requires AutoHotkey v2.0 64-bit
#NoTrayIcon
#Warn VarUnset, StdOut
#Include ..\lib\Native.ahk

; Regression for 2026-11-24 13:38 / 17:43 (飞书 link on 屏幕2 opened on 屏幕1):
; a 随屏链接 request arrives as a message another process sends to this
; script's window, so its handler runs in that window's own (system-DPI)
; context. The screen it records must equal what the follow-up timer reads
; later in the physical context; otherwise the wait is cancelled as
; "monitor-changed" and the browser opens its new window on its last screen.
; Read-only: no window is moved, activated or created on screen.
class DpiChecks {
    static Count := 0, Handler := 0
    static Assert(value,label) {
        if !value
            throw Error(label)
        this.Count += 1
    }
    static Awareness() => DllCall("user32\GetAwarenessFromDpiAwarenessContext",
        "ptr",DllCall("user32\GetThreadDpiAwarenessContext","ptr"),"int")
    ; What the code did before the fix: read the screen in whatever context is current.
    static Raw(handle) {
        b := Buffer(104,0)
        NumPut("uint",104,b)
        if !DllCall("user32\GetMonitorInfoW","ptr",handle,"ptr",b)
            return 0
        return {Handle:handle,Bounds:ScreenRect.FromBuffer(b,4),Work:ScreenRect.FromBuffer(b,20),Device:StrGet(b.Ptr+40,32)}
    }
    static Text(m) => !IsObject(m) ? "none" : m.Device . " " . m.Bounds.L . "," . m.Bounds.T . "," . m.Bounds.R . "," . m.Bounds.B
        . " work=" . m.Work.L . "," . m.Work.T . "," . m.Work.R . "," . m.Work.B
    static SentMessage(*) {
        result := {Awareness:this.Awareness(),Monitors:[],Raw:[],After:0}
        for screen in Screens
            result.Monitors.Push(Desktop.Monitor(screen.Handle)), result.Raw.Push(this.Raw(screen.Handle))
        result.After := this.Awareness()
        this.Handler := result
        return 1
    }
}
try {
    DpiChecks.Assert(Desktop.Physical(),"The physical (per-monitor) context is available")
    Screens := []
    Loop MonitorGetCount() {
        MonitorGet(A_Index,&l,&t,&r,&b)
        x := l + (r-l)//2, y := t + (b-t)//2
        handle := DllCall("user32\MonitorFromPoint","int64",Desktop.Point(x,y),"uint",2,"ptr")
        Screens.Push({Handle:handle,X:x,Y:y,Physical:Desktop.Monitor(handle)})
        DpiChecks.Assert(IsObject(Screens[A_Index].Physical),"Screen " . A_Index . " can be read")
    }

    ; 1. Every caller context reads the same physical screen and keeps its own context.
    tested := ""
    for context in [-1,-2,-5] { ; unaware, system aware, unaware GDI-scaled
        previous := DllCall("user32\SetThreadDpiAwarenessContext","ptr",context,"ptr")
        if !previous
            continue ; context not offered by this Windows version
        try {
            expected := DpiChecks.Awareness()
            for screen in Screens {
                DpiChecks.Assert(Desktop.Unchanged(screen.Physical,Desktop.Monitor(screen.Handle)),
                    "Context " . context . " reads " . screen.Physical.Device . " in physical pixels")
                at := Desktop.MonitorAt(screen.X,screen.Y)
                DpiChecks.Assert(IsObject(at) && at.Handle = screen.Handle,
                    "Context " . context . " maps a physical point to " . screen.Physical.Device)
            }
            DpiChecks.Assert(DpiChecks.Awareness() = expected,"Context " . context . " is restored for the caller")
        } finally DllCall("user32\SetThreadDpiAwarenessContext","ptr",previous,"ptr")
        tested .= (tested = "" ? "" : ",") . context
    }
    DpiChecks.Assert(DpiChecks.Awareness() = 2,"The script is back in its physical context")

    ; 2. The real path: a message sent to the script window (like 随屏链接's
    ;    WM_COPYDATA), then the timer-side read at top level.
    OnMessage(0x8123,ObjBindMethod(DpiChecks,"SentMessage"))
    Sleep(30) ; past the new-thread interrupt guard, so the handler can run
    DllCall("user32\SendMessageW","ptr",A_ScriptHwnd,"uint",0x8123,"ptr",0,"ptr",0,"ptr")
    seen := DpiChecks.Handler
    DpiChecks.Assert(IsObject(seen),"The sent-message handler ran")
    DpiChecks.Assert(seen.After = seen.Awareness,"Reading screens inside the handler leaves its context unchanged")
    oldCancel := 0, details := ""
    for index, screen in Screens {
        later := Desktop.Monitor(screen.Handle)
        DpiChecks.Assert(Desktop.Unchanged(seen.Monitors[index],later),
            "A screen recorded inside a sent message still matches the later read: " . screen.Physical.Device)
        if !Desktop.Unchanged(seen.Raw[index],later) {
            oldCancel := 1
            details .= "; old " . DpiChecks.Text(seen.Raw[index]) . " vs " . DpiChecks.Text(later)
        }
    }
    FileAppend("PASS monitor-dpi assertions=" . DpiChecks.Count . "; screens=" . Screens.Length . "; contexts=" . tested
        . "; sent-message-awareness=" . seen.Awareness . "; old-code-would-cancel=" . oldCancel . details . "`n","*","UTF-8")
} catch as e {
    FileAppend("FAIL " . e.Message . "; line=" . e.Line . "`n","*","UTF-8")
    ExitApp(1)
}
ExitApp(0)
