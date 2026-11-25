#Requires AutoHotkey v2.0 64-bit
#Include ..\lib\Native.ahk
Desktop.Physical()
Log(text) => FileAppend(text . "`n", "*", "UTF-8")
Refresh(hwnd,target) {
    operation := WindowMoveOperation(hwnd,target)
    result := operation.Start()
    if result != "requested"
        return result
    return Finish(operation)
}
Finish(operation,neverMinimized := false) {
    deadline := Desktop.Tick()+1000
    while Desktop.Tick()<deadline {
        if neverMinimized && Desktop.IsMin(operation.Hwnd)
            return "minimized-during-direct-move"
        result := operation.Advance()
        if result = "complete"
            return "requested"
        if result != "waiting"
            break
        Sleep(30)
    }
    operation.Cancel()
    return result
}
WaitFor(observation,label) {
    deadline := Desktop.Tick()+1000
    while Desktop.Tick()<deadline {
        if observation()
            return
        Sleep(20)
    }
    throw Error(label)
}
class DeniedPlacementMove extends WindowMoveOperation {
    Attempts := 0
    SetPlacement(stage,success) {
        this.Attempts += 1
        return stage . "-placement-failed:5"
    }
}
ForeignCases(executable,one,two) {
    unique := "TaskbarFollow foreign move " . DllCall("kernel32\GetCurrentProcessId","uint") . "-" . A_TickCount
    hwnd := 0, focus := Desktop.Foreground(), anchor := 0
    Run('"' . executable . '" /ErrorStdOut=UTF-8 "' . A_ScriptDir . '\WindowMoveFixture.ahk" "' . unique . '"',,"Hide",&child)
    try {
        if !WinWait(unique . " ahk_pid " . child,,3)
            throw Error("Foreign movement fixture did not start")
        hwnd := WinExist(unique . " ahk_pid " . child)
        if WindowMover.Move(hwnd,one,true) != "already-there"
            WaitFor(() => Desktop.SameMonitor(Desktop.MonitorOf(hwnd),one),"Foreign fixture setup did not move")
        operation := DeniedPlacementMove(hwnd,two)
        if operation.Start() != "requested" || Finish(operation,true) != "requested"
            || operation.Attempts != 1 || !Desktop.SameMonitor(Desktop.MonitorOf(hwnd),two)
            throw Error("A denied minimize did not fall back to a direct move")
        if Refresh(hwnd,one) != "requested" || Refresh(hwnd,two) != "requested" || Desktop.IsMin(hwnd)
            throw Error("Foreign normal refresh failed")
        DllCall("user32\ShowWindowAsync","ptr",hwnd,"int",3)
        WaitFor(() => NumGet(Desktop.Placement(hwnd),8,"uint")=3,"Foreign fixture did not maximize")
        operation := DeniedPlacementMove(hwnd,one)
        if operation.Start() != "minimize-placement-failed:5" || operation.Attempts != 1
            || !Desktop.SameMonitor(Desktop.MonitorOf(hwnd),two) || NumGet(Desktop.Placement(hwnd),8,"uint") != 3
            throw Error("Access denied must preserve a maximized window's state and position")
        if Refresh(hwnd,one) != "requested" || NumGet(Desktop.Placement(hwnd),8,"uint") != 3
            throw Error("Foreign maximized refresh failed")
        DllCall("user32\ShowWindowAsync","ptr",hwnd,"int",7)
        WaitFor(() => Desktop.IsMin(hwnd),"Foreign fixture did not minimize")
        operation := WindowMoveOperation(hwnd,two,true)
        if operation.Start() != "requested" || Finish(operation) != "requested"
            || NumGet(Desktop.Placement(hwnd),8,"uint") != 3
            throw Error("Foreign minimized-maximized refresh failed")
        operation := WindowMoveOperation(hwnd,one)
        if operation.Start() != "requested"
            throw Error("Foreign cancellation setup failed")
        WaitFor(() => Desktop.IsMin(hwnd),"Foreign cancellation did not reach minimization")
        anchor := Gui("+ToolWindow","TaskbarFollow move cancellation anchor")
        anchor.Show("w240 h90")
        focusBeforeCancel := Desktop.Foreground()
        operation.Cancel()
        Sleep(150)
        if operation.Advance() != "cancelled" || !Desktop.SameMonitor(Desktop.MonitorOf(hwnd),two)
            || !Desktop.IsMin(hwnd) || !(NumGet(Desktop.Placement(hwnd),4,"uint") & 2)
            throw Error("Cancellation changed placement/state or resumed the move")
        if Desktop.Foreground() != focusBeforeCancel
            throw Error("Cancellation stole focus from the new foreground window")
        DllCall("user32\ShowWindowAsync","ptr",hwnd,"int",7)
        WaitFor(() => Desktop.IsMin(hwnd),"Originally minimized cancellation setup failed")
        operation := WindowMoveOperation(hwnd,one,true)
        if operation.Start() != "requested"
            throw Error("Originally minimized cancellation did not start")
        operation.Cancel()
        Sleep(150)
        if !Desktop.IsMin(hwnd) || operation.Advance() != "cancelled"
            throw Error("Cancelling an originally minimized window restored it")
        Log("PASS foreign async movement, access-denied fallback and cancellation; runtime=" . executable)
    } finally {
        if IsObject(anchor)
            anchor.Destroy()
        if hwnd && Desktop.Pid(hwnd)=child
            WinClose("ahk_id " . hwnd)
        if focus
            try WinActivate("ahk_id " . focus)
    }
}
try {
    if MonitorGetCount() < 2
        throw Error("Need two monitors")
    MonitorGet(1, &l1, &t1, &r1, &b1), MonitorGet(2, &l2, &t2, &r2, &b2)
    one := Desktop.MonitorAt((l1+r1)//2, (t1+b1)//2)
    two := Desktop.MonitorAt((l2+r2)//2, (t2+b2)//2)
    g := Gui("+E0x08000000 +ToolWindow", "TaskbarFollow isolated movement test")
    g.AddText(, "Automated test fixture; no user application is touched.")
    g.Show("NA x" . (one.Work.L + 100) . " y" . (one.Work.T + 100) . " w640 h400")
    Sleep(100)
    shellCom := ComObject("Shell.Application") ; initialize COM before using the shell's native property store
    storePtr := 0
    iid := Desktop.Guid("{886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99}")
    if DllCall("shell32\SHGetPropertyStoreForWindow", "ptr", g.Hwnd, "ptr", iid, "ptr*", &storePtr, "int") < 0
        throw Error("Fixture property store unavailable")
    store := ComValue(13, storePtr, 1), key := Buffer(20, 0), pv := Buffer(24, 0)
    appGuid := Desktop.Guid("{9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3}")
    DllCall("ntdll\RtlMoveMemory", "ptr", key, "ptr", appGuid, "uptr", 16)
    NumPut("uint", 5, key, 16)
    appText := "TaskbarFollow.NativeTest"
    appTextPtr := DllCall("ole32\CoTaskMemAlloc", "uptr", (StrLen(appText) + 1) * 2, "ptr")
    if !appTextPtr
        throw Error("Fixture AppID allocation failed")
    StrPut(appText, appTextPtr, StrLen(appText) + 1)
    NumPut("ushort", 31, pv)
    NumPut("ptr", appTextPtr, pv, 8) ; VT_LPWSTR owned and released by PropVariantClear
    try {
        ComCall(6, store, "ptr", key, "ptr", pv)
        ComCall(7, store)
    } finally {
        DllCall("ole32\PropVariantClear", "ptr", pv)
    }
    id := WindowIdentity.WindowAppId(g.Hwnd)
    Log("window-appid=" . id)
    if id != "TaskbarFollow.NativeTest"
        throw Error("Window AppID round-trip failed")
    identity := WindowIdentity().Get(g.Hwnd)
    Log("identity-path=" . identity.Path)
    Log("normal-before=" . Desktop.MonitorOf(g.Hwnd).Device)
    Log("normal-result=" . WindowMover.Move(g.Hwnd, two))
    Sleep(350)
    Log("normal-after=" . Desktop.MonitorOf(g.Hwnd).Device)
    if !Desktop.SameMonitor(Desktop.MonitorOf(g.Hwnd), two)
        throw Error("Normal move failed")
    DllCall("user32\ShowWindow", "ptr", g.Hwnd, "int", 3)
    Sleep(150)
    Log("max-before=" . Desktop.MonitorOf(g.Hwnd).Device)
    Log("max-result=" . WindowMover.Move(g.Hwnd, one))
    Sleep(350)
    Log("max-after=" . Desktop.MonitorOf(g.Hwnd).Device . " max-state=" . NumGet(Desktop.Placement(g.Hwnd), 8, "uint"))
    if !Desktop.SameMonitor(Desktop.MonitorOf(g.Hwnd), one) || NumGet(Desktop.Placement(g.Hwnd), 8, "uint") != 3
        throw Error("Maximized move failed")
    if Refresh(g.Hwnd,two) != "requested"
        throw Error("Visible maximized refresh was not requested")
    Sleep(350)
    if Desktop.IsMin(g.Hwnd) || !Desktop.SameMonitor(Desktop.MonitorOf(g.Hwnd),two) || NumGet(Desktop.Placement(g.Hwnd),8,"uint") != 3
        throw Error("Visible refresh did not preserve maximized state on target")
    DllCall("user32\ShowWindow","ptr",g.Hwnd,"int",9)
    Sleep(100)
    if Refresh(g.Hwnd,one) != "requested"
        throw Error("Visible normal refresh was not requested")
    Sleep(350)
    if Desktop.IsMin(g.Hwnd) || !Desktop.SameMonitor(Desktop.MonitorOf(g.Hwnd),one) || NumGet(Desktop.Placement(g.Hwnd),8,"uint") = 3
        throw Error("Visible refresh did not preserve normal state on target")
    DllCall("user32\ShowWindow","ptr",g.Hwnd,"int",3)
    Sleep(100)
    DllCall("user32\ShowWindow", "ptr", g.Hwnd, "int", 6)
    Sleep(100)
    if !Desktop.IsMin(g.Hwnd) || WindowMover.Move(g.Hwnd, two, false) != "minimized"
        throw Error("A native minimized window was unexpectedly restored")
    Log("minimized-max-result=" . WindowMover.Move(g.Hwnd, two, true))
    Sleep(300)
    if !Desktop.SameMonitor(Desktop.MonitorOf(g.Hwnd), two) || NumGet(Desktop.Placement(g.Hwnd), 8, "uint") != 3
        throw Error("Minimized maximized state was not preserved")
    DllCall("user32\ShowWindow", "ptr", g.Hwnd, "int", 9)
    Sleep(100)
    DllCall("user32\ShowWindow", "ptr", g.Hwnd, "int", 6)
    Sleep(100)
    Log("minimized-normal-result=" . WindowMover.Move(g.Hwnd, one, true))
    Sleep(300)
    if Desktop.IsMin(g.Hwnd) || !Desktop.SameMonitor(Desktop.MonitorOf(g.Hwnd), one)
        throw Error("Minimized normal window did not restore on destination")
    if NumGet(Desktop.Placement(g.Hwnd), 8, "uint") = 3
        throw Error("A normal window unexpectedly became maximized")
    if WindowMover.Move(g.Hwnd, one) != "already-there"
        throw Error("Same-screen operation was not a no-op")
    if Desktop.Eligible(g.Hwnd)
        throw Error("NOACTIVATE/tool test fixture must not be automatically eligible")
    changed := {Handle: two.Handle, Device: two.Device, Bounds: two.Bounds, Work: ScreenRect(two.Work.L, two.Work.T + 1, two.Work.R, two.Work.B)}
    if WindowMover.Move(g.Hwnd, changed) != "monitor-changed"
        throw Error("A stale work-area snapshot was accepted")
    Log("PASS normal/maximized/minimized/no-op/stale-monitor native cases")
    ; Direct mode, used for windows without a taskbar button (芒果TV's player):
    ; the window moves without ever being minimized, normal and maximized.
    if !WindowMoveOperation.NoTaskbarButton(g.Hwnd)
        throw Error("A tool window was not recognized as having no taskbar button")
    DllCall("user32\ShowWindow","ptr",g.Hwnd,"int",4)
    Sleep(100)
    operation := WindowMoveOperation(g.Hwnd,two,false,true)
    if operation.Start() != "requested" || Finish(operation,true) != "requested"
        || Desktop.IsMin(g.Hwnd) || !Desktop.SameMonitor(Desktop.MonitorOf(g.Hwnd),two) || NumGet(Desktop.Placement(g.Hwnd),8,"uint") = 3
        throw Error("Direct normal move failed")
    DllCall("user32\ShowWindow","ptr",g.Hwnd,"int",3)
    Sleep(150)
    operation := WindowMoveOperation(g.Hwnd,one,false,true)
    if operation.Start() != "requested" || Finish(operation,true) != "requested"
        || Desktop.IsMin(g.Hwnd) || !Desktop.SameMonitor(Desktop.MonitorOf(g.Hwnd),one) || NumGet(Desktop.Placement(g.Hwnd),8,"uint") != 3
        throw Error("Direct maximized move failed")
    Log("PASS direct (never minimized) normal/maximized moves")
    g.Destroy()
    ForeignCases(A_AhkPath,one,two)
    ForeignCases(A_ScriptDir . "\..\runtime\AutoHotkey32.exe",one,two)
    ExitApp(0)
} catch as e {
    Log("FAIL " . e.Message . " at " . e.Line)
    try g.Destroy()
    ExitApp(1)
}



