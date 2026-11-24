#Requires AutoHotkey v2.0 64-bit
#NoTrayIcon
#SingleInstance Off
#Warn VarUnset, StdOut
#Include ..\lib\Native.ahk

; Live checks on this script's own windows only: which newly shown windows an
; in-app click may move (Desktop.LaunchedWindowRefusal). Players such as
; 芒果TV show a Qt tool-style window owned by another window of the same
; program. No other application is touched and every window is destroyed.
class LaunchChecks {
    static Count := 0
    static Windows := []
    static Assert(value,label) {
        if !value
            throw Error(label)
        this.Count += 1
    }
    static Make(options,w,h) {
        g := Gui("-DPIScale " . options,"TaskbarFollow launched-window check")
        g.AddText(,"Automated check window; it closes by itself.")
        MonitorGetWorkArea(MonitorGetPrimary(),&left,&top)
        g.Show("NA x" . (left + 60) . " y" . (top + 60) . " w" . w . " h" . h)
        this.Windows.Push(g)
        return g
    }
}
try {
    normal := LaunchChecks.Make("",640,400)
    Sleep(150)
    LaunchChecks.Assert(Desktop.Eligible(normal.Hwnd) && Desktop.LaunchedWindowRefusal(normal.Hwnd) == "",
        "An ordinary window stays eligible")
    tool := LaunchChecks.Make("+ToolWindow",640,400)
    owned := LaunchChecks.Make("+ToolWindow +Owner" . normal.Hwnd,640,400)
    quiet := LaunchChecks.Make("+ToolWindow +E0x08000000",640,400)
    small := LaunchChecks.Make("+ToolWindow -Caption",100,50) ; no caption: no minimum tracking size
    hidden := LaunchChecks.Make("+ToolWindow",640,400)
    hidden.Hide()
    Sleep(200)
    LaunchChecks.Assert(!Desktop.Eligible(tool.Hwnd) && Desktop.LaunchedWindowRefusal(tool.Hwnd) == "",
        "A tool-style window opened by an in-app click may follow (taskbar rules still reject it)")
    LaunchChecks.Assert(Desktop.Owner(owned.Hwnd) = normal.Hwnd && !Desktop.Eligible(owned.Hwnd)
        && Desktop.LaunchedWindowRefusal(owned.Hwnd) == "" && Desktop.LaunchedWindowRefusal(owned.Hwnd,tool.Hwnd) == "",
        "A tool window owned by another window of the same program may follow")
    LaunchChecks.Assert(Desktop.LaunchedWindowRefusal(quiet.Hwnd) == "no-activate-or-child",
        "A no-activate window (notification, overlay) never follows")
    LaunchChecks.Assert(Desktop.LaunchedWindowRefusal(small.Hwnd) == "too-small",
        "A small tool window (hover card, menu-sized popup) never follows")
    LaunchChecks.Assert(Desktop.LaunchedWindowRefusal(hidden.Hwnd) == "hidden-or-disabled",
        "A hidden window never follows")
    LaunchChecks.Assert(Desktop.LaunchedWindowRefusal(0) == "gone-or-shell" && Desktop.ProcessPath(0) == ""
        && Desktop.ProcessPath(DllCall("kernel32\GetCurrentProcessId","uint")) = StrLower(A_AhkPath),
        "Missing windows are refused and process paths resolve")
    FileAppend("PASS launched-window assertions=" . LaunchChecks.Count . "`n","*","UTF-8")
    exitCode := 0
} catch as e {
    FileAppend("FAIL " . e.Message . "; line=" . e.Line . "`n","*","UTF-8")
    exitCode := 1
}
for window in LaunchChecks.Windows
    try window.Destroy()
ExitApp(exitCode)
