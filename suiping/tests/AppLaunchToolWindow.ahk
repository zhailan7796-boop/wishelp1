#Requires AutoHotkey v2.0 64-bit
#NoTrayIcon
#SingleInstance Off
#Warn VarUnset, StdOut
#Include ..\lib\Native.ahk
#Include ..\lib\NativeEngine.ahk

; End-to-end check of the 芒果TV case, on this script's own windows only:
; a click inside the main window shows a frameless Qt-style player window
; (class Qt5QWindowToolSaveBits, WS_EX_TOOLWINDOW, owned by a hidden window
; of the same program) on the first screen. The production NativeEngine code
; (snapshot, matching, staged move, confirmation) runs unchanged; only the
; native click snapshot is injected. With two monitors the player must end up
; on the other screen; with one monitor the player must at least be accepted.
; Every window is destroyed at the end; no other application is touched.
;
; The real 芒果TV player hides itself as soon as it is minimized (2026-11-23
; 14:00: "app launch requested" then "window-changed", the window flashed and
; vanished). The test player counts every minimize and, in the third run,
; hides itself the same way. The player must never be minimized.
Desktop.Physical()
PlayerWndProc(hwnd,msg,wParam,lParam) {
    if msg = 0x0005 && wParam = 1 { ; WM_SIZE / SIZE_MINIMIZED
        PlayerChecks.Minimized[hwnd] := (PlayerChecks.Minimized.Has(hwnd) ? PlayerChecks.Minimized[hwnd] : 0) + 1
        if PlayerChecks.HideOnMinimize.Has(hwnd)
            DllCall("user32\ShowWindow","ptr",hwnd,"int",0) ; SW_HIDE, like the real player
    }
    return DllCall("user32\DefWindowProcW","ptr",hwnd,"uint",msg,"uptr",wParam,"ptr",lParam,"ptr")
}

class LaunchOwner {
    Enabled := true, BringActive := true, SuccessfulMoves := 0, Messages := [], Logs := []
    __New() {
        this.Identity := WindowIdentity("",false)
    }
    ReportActivity(text) => this.Messages.Push(text)
    Log(text) => this.Logs.Push(text)
}
class LaunchEngine extends NativeEngine {
    __New(intent) {
        this.Owner := LaunchOwner(), this.Handle := 1, this.Compatibility := 0, this.CompatibilityMoves := 0
        this.Intent := intent
    }
    ReadCompatibilityIntent(serial) => serial = this.Intent.Serial ? this.Intent : 0
    CompatibilityTakeover(serial) => serial = this.Intent.Serial
    CancelCompatibilityIntent(serial) => serial = this.Intent.Serial
    CompatibilitySchedule(enabled) { ; ticks are driven by the loop below
    }
}
class PlayerChecks {
    static Count := 0, Windows := [], Guis := [], Minimized := Map(), HideOnMinimize := Map()
    static Assert(value,label) {
        if !value
            throw Error(label)
        this.Count += 1
    }
    static ClassName := "Qt5QWindowToolSaveBits"
    static Register() {
        static atom := 0
        if atom
            return atom
        user32 := DllCall("kernel32\GetModuleHandleW","wstr","user32.dll","ptr")
        wc := Buffer(80,0)
        NumPut("uint",80,"uint",0x0803,wc,0) ; CS_SAVEBITS | CS_HREDRAW | CS_VREDRAW
        NumPut("ptr",CallbackCreate(PlayerWndProc,,4),wc,8)
        NumPut("ptr",DllCall("kernel32\GetModuleHandleW","ptr",0,"ptr"),wc,24)
        NumPut("ptr",DllCall("user32\LoadCursorW","ptr",0,"ptr",32512,"ptr"),wc,40)
        NumPut("ptr",DllCall("gdi32\GetStockObject","int",0,"ptr"),wc,48)
        NumPut("ptr",StrPtr(this.ClassName),wc,64)
        atom := DllCall("user32\RegisterClassExW","ptr",wc,"ushort")
        if !atom
            throw Error("RegisterClassExW failed: " . A_LastError)
        return atom
    }
    ; WS_POPUP | WS_CLIPSIBLINGS | WS_CLIPCHILDREN (+ WS_VISIBLE when shown)
    static Create(ex,style,x,y,w,h,owner) {
        this.Register()
        hwnd := DllCall("user32\CreateWindowExW","uint",ex,"wstr",this.ClassName,"wstr","TaskbarFollow player check",
            "uint",style,"int",x,"int",y,"int",w,"int",h,"ptr",owner,"ptr",0,
            "ptr",DllCall("kernel32\GetModuleHandleW","ptr",0,"ptr"),"ptr",0,"ptr")
        if !hwnd
            throw Error("CreateWindowExW failed: " . A_LastError)
        this.Windows.Push(hwnd)
        return hwnd
    }
    static Activate(hwnd) {
        start := Desktop.Tick(), deadline := start + 2000
        while Desktop.Tick() < deadline {
            if Desktop.Foreground() = hwnd
                return true
            ; Plain request first; AutoHotkey's WinActivate (which works around
            ; the foreground lock) only if Windows has not granted it yet.
            if Desktop.Tick() - start < 300
                DllCall("user32\SetForegroundWindow","ptr",hwnd)
            else
                try WinActivate("ahk_id " . hwnd)
            Sleep(30)
        }
        return Desktop.Foreground() = hwnd
    }
    static Screens(&source,&target) {
        MonitorGetWorkArea(MonitorGetPrimary(),&l,&t,&r,&b)
        source := Desktop.MonitorAt(l + 50,t + 50), target := source
        Loop MonitorGetCount() {
            MonitorGet(A_Index,&ml,&mt,&mr,&mb)
            candidate := Desktop.MonitorAt((ml + mr) // 2,(mt + mb) // 2)
            if IsObject(candidate) && !Desktop.SameMonitor(candidate,source) {
                target := candidate
                break
            }
        }
        return !Desktop.SameMonitor(source,target)
    }
    ; Drives the engine until it finishes, then checks the outcome for player.
    static Finish(label,engine,player,target,twoScreens,now,minimizedText := "") {
        deadline := now + 3600 ; past Expires, so a refused window is logged
        while IsObject(engine.Compatibility) && Desktop.Tick() < deadline {
            engine.CompatibilityTick()
            Sleep(50)
        }
        logs := ""
        for line in engine.Owner.Logs
            logs .= line . "`n"
        FileAppend(label . " log:`n" . logs,"*","UTF-8")
        this.Assert(!InStr(logs,"unmatched-window"),label . ": the player window was not refused")
        minimized := minimizedText != "" ? !InStr(Desktop.Title(player),minimizedText) : this.Minimized.Has(player)
        this.Assert(!minimized,label . ": the player was never minimized (it has no taskbar button)")
        if twoScreens {
            this.Assert(InStr(logs,"app launch confirmed") && InStr(logs,"hwnd=" . player . ";"),
                label . ": the player move was confirmed")
            this.Assert(Desktop.SameMonitor(Desktop.MonitorOf(player),target) && !Desktop.IsMin(player)
                && DllCall("user32\IsWindowVisible","ptr",player),label . ": the player is visible on the clicked screen")
        } else {
            this.Assert(InStr(logs,"app launch already-there") && InStr(logs,"hwnd=" . player . ";"),
                label . ": the player was accepted (one monitor: nothing to move)")
        }
    }
    ; The same click, but the video app is a separate process (32-bit when the
    ; 32-bit runtime is present, like 芒果TV.exe) whose player hides itself when
    ; minimized. The engine moves the window across processes, as in real use.
    static Foreign := []
    static RunForeign(label) {
        twoScreens := this.Screens(&source,&target)
        exe := A_ScriptDir . "\..\runtime\AutoHotkey32.exe"
        if !FileExist(exe)
            exe := A_AhkPath
        unique := "TaskbarFollow player fixture " . DllCall("kernel32\GetCurrentProcessId","uint") . "-" . A_TickCount
        Run('"' . exe . '" /ErrorStdOut=UTF-8 "' . A_ScriptDir . '\PlayerFixture.ahk" "' . unique . '" '
            . (source.Work.L + 120) . " " . (source.Work.T + 90) . " 960 540 hide",A_ScriptDir,,&child)
        this.Foreign.Push(child)
        main := WinWait(unique . " main ahk_pid " . child,,5)
        this.Assert(main,label . ": the simulated video app started (" . (exe = A_AhkPath ? "64" : "32") . "-bit)")
        this.Assert(this.Activate(main),label . ": its main window became the foreground window")
        now := Desktop.Tick()
        intent := {Serial:41,Flags:NativeEngine.AppLaunchFlag,Id:"",Path:exe,Monitor:target.Handle,
            Released:now,Expires:now + 3000,NativeClaimed:0,Before:main,Source:main,
            Candidates:[{Hwnd:main,Pid:child}]}
        engine := LaunchEngine(intent)
        this.Assert(engine.BeginCompatibility(41,target.Handle),label . ": in-app click wait started")
        PostMessage(0x8101,0,0,,"ahk_id " . main) ; "click a drama"
        player := WinWait(unique . " player ahk_pid " . child,,3)
        this.Assert(player,label . ": the simulated player window appeared")
        this.Assert(this.Activate(player),label . ": the player window became the foreground window")
        this.Assert(!Desktop.Eligible(player,main),label . ": taskbar rules still refuse the tool-style player")
        this.Finish(label,engine,player,target,twoScreens,now,"minimized=0")
        return twoScreens
    }
    static Run(label,unaware := false,hideOnMinimize := false) {
        twoScreens := this.Screens(&source,&target)
        main := Gui("-DPIScale","TaskbarFollow player check main window")
        main.AddText(,"Automated check window; it closes by itself.")
        this.Guis.Push(main)
        main.Show("x" . (source.Work.L + 40) . " y" . (source.Work.T + 40) . " w700 h420")
        this.Assert(this.Activate(main.Hwnd),label . ": main window became the foreground window")
        now := Desktop.Tick(), pid := DllCall("kernel32\GetCurrentProcessId","uint")
        intent := {Serial:41,Flags:NativeEngine.AppLaunchFlag,Id:"",Path:A_AhkPath,Monitor:target.Handle,
            Released:now,Expires:now + 3000,NativeClaimed:0,Before:main.Hwnd,Source:main.Hwnd,
            Candidates:[{Hwnd:main.Hwnd,Pid:pid}]}
        engine := LaunchEngine(intent)
        this.Assert(engine.BeginCompatibility(41,target.Handle),label . ": in-app click wait started")
        ; The player: hidden owner + owned tool window, both of this process.
        previous := unaware ? DllCall("user32\SetThreadDpiAwarenessContext","ptr",-1,"ptr") : 0
        try {
            owner := this.Create(0,0x86000000,source.Work.L,source.Work.T,10,10,0)
            player := this.Create(0x80,0x86000000,source.Work.L + 120,source.Work.T + 90,960,540,owner)
        } finally {
            if previous
                DllCall("user32\SetThreadDpiAwarenessContext","ptr",previous,"ptr")
        }
        if hideOnMinimize
            this.HideOnMinimize[player] := true
        DllCall("user32\ShowWindow","ptr",player,"int",5)
        this.Assert(this.Activate(player),label . ": player window became the foreground window")
        this.Assert(!Desktop.Eligible(player,main.Hwnd),label . ": taskbar rules still refuse the tool-style player")
        this.Finish(label,engine,player,target,twoScreens,now)
        return twoScreens
    }
    static Cleanup() {
        for hwnd in this.Windows
            try DllCall("user32\DestroyWindow","ptr",hwnd)
        for g in this.Guis
            try g.Destroy()
        for child in this.Foreign {
            try WinClose("ahk_pid " . child)
            if ProcessWaitClose(child,2)
                try ProcessClose(child)
        }
        this.Windows := [], this.Guis := [], this.Foreign := []
    }
}
try {
    moved := PlayerChecks.Run("qt-player")
    PlayerChecks.Cleanup()
    PlayerChecks.Run("qt-player-dpi-unaware",true)
    PlayerChecks.Cleanup()
    PlayerChecks.Run("qt-player-hides-when-minimized",false,true)
    PlayerChecks.Cleanup()
    PlayerChecks.RunForeign("separate-process-player-hides-when-minimized")
    FileAppend("PASS app-launch tool-window assertions=" . PlayerChecks.Count . "; screens=" . (moved ? 2 : 1) . "`n","*","UTF-8")
    exitCode := 0
} catch as e {
    FileAppend("FAIL " . e.Message . "; line=" . e.Line . "`n","*","UTF-8")
    exitCode := 1
}
PlayerChecks.Cleanup()
ExitApp(exitCode)
