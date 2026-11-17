#Requires AutoHotkey v2.0 64-bit
#SingleInstance Off
#NoTrayIcon
#Include ..\lib\Native.ahk
#Include ..\lib\UIA.ahk
#Include ..\lib\NativeEngine.ahk

Log(line) => FileAppend(line . "`n", "*", "UTF-8")

; Only the native click snapshot is supplied by this fixture. Candidate
; verification, staging, cancellation and confirmation use NativeEngine.
class ChromeCompatibilityOwner {
    Enabled := true, BringActive := true, SuccessfulMoves := 0
    __New() => this.Identity := WindowIdentity("",false)
    ReportActivity(text) => Log(text)
    Log(text) => Log(text)
}
class ChromeCompatibility extends NativeEngine {
    __New(hwnd,target,id) {
        this.Owner := ChromeCompatibilityOwner(), this.Handle := 1, this.Compatibility := 0, this.CompatibilityMoves := 0
        this.Valid := true, now := Desktop.Tick(), data := this.Owner.Identity.Get(hwnd)
        this.Intent := {Serial:1,Flags:16,Id:id,Path:data.Path,Monitor:target.Handle,Released:now,Expires:now+8000,
            NativeClaimed:0,Before:hwnd,Source:0,Candidates:[{Hwnd:hwnd,Pid:data.Pid}]}
        if !this.BeginCompatibility(1,target.Handle)
            throw Error("Test compatibility controller did not start")
    }
    ReadCompatibilityIntent(serial) => this.Valid && serial=1 ? this.Intent : 0
    CompatibilityTakeover(serial) => this.Valid && serial=1
    CancelCompatibilityIntent(serial) => (this.Valid := false,true)
    CompatibilitySchedule(enabled) {
    }
}

FindButton(uia, bar, appId) {
    for button in uia.Buttons(bar) {
        if button.Id == appId
            return button
    }
    throw Error("Test Chrome taskbar button unavailable on " . Desktop.MonitorOf(bar).Device)
}

PagePixel(hwnd) {
    rect := Desktop.Rect(hwnd)
    dc := DllCall("user32\GetDC", "ptr", 0, "ptr")
    try return DllCall("gdi32\GetPixel", "ptr", dc, "int", rect.L + rect.W//2,
        "int", rect.T + rect.H*2//3, "uint")
    finally DllCall("user32\ReleaseDC", "ptr", 0, "ptr", dc)
}

IsTestColor(pixel) => Abs((pixel & 255)-201)<18 && Abs(((pixel>>8) & 255)-87)<18
    && Abs(((pixel>>16) & 255)-49)<18

MovePointer(x,y,&expectedX,&expectedY) {
    Desktop.Physical()
    if !Desktop.Cursor(&currentX,&currentY) || Abs(currentX-expectedX)>8 || Abs(currentY-expectedY)>8
        throw Error("Other pointer activity detected; expected=" . expectedX . "," . expectedY . "; actual=" . currentX . "," . currentY)
    left := DllCall("user32\GetSystemMetrics","int",76), top := DllCall("user32\GetSystemMetrics","int",77)
    width := DllCall("user32\GetSystemMetrics","int",78), height := DllCall("user32\GetSystemMetrics","int",79)
    input := Buffer(40,0)
    NumPut("int",Round((x-left)*65535/(width-1)),"int",Round((y-top)*65535/(height-1)),input,8)
    NumPut("uint",0xC001,input,20)
    if DllCall("user32\SendInput","uint",1,"ptr",input,"int",40,"uint")!=1
        throw Error("Test pointer input failed")
    Sleep(45)
    if !Desktop.Cursor(&actualX,&actualY) || Abs(x-actualX)>8 || Abs(y-actualY)>8
        throw Error("Cannot place test pointer; expected=" . x . "," . y . "; actual=" . actualX . "," . actualY)
    expectedX := x, expectedY := y
}

HoverChrome(bar,hwnd,&expectedX,&expectedY) {
    monitor := Desktop.MonitorOf(bar)
    deadline := Desktop.Tick()+3800
    while Desktop.Tick()<deadline {
        for popup in Desktop.Thumbnails() {
            if !Desktop.SameMonitor(Desktop.MonitorOf(popup),monitor)
                continue
            rect := Desktop.Rect(popup)
            if !IsObject(rect) || rect.W<60 || rect.H<50
                continue
            MovePointer(rect.L+rect.W//2,rect.T+rect.H*2//3,&expectedX,&expectedY)
            overlayDeadline := Desktop.Tick()+2000
            while Desktop.Tick()<overlayDeadline {
                overlay := WinExist("ahk_class TaskbarFollow.HoverPreview")
                if overlay && DllCall("user32\GetPropW","ptr",overlay,"wstr","TaskbarFollow.PeekSource","ptr")=hwnd {
                    Log("Observed live preview for Chrome before selecting its thumbnail")
                    return popup
                }
                Sleep(35)
            }
            throw Error("Live preview did not show the test Chrome")
        }
        Sleep(35)
    }
    throw Error("Chrome taskbar thumbnail did not open")
}

ClickChrome(uia, bar, appId, hwnd, &expectedX, &expectedY) {
    direct := HasArg("--move-only") || HasArg("--compatibility-only")
    if !direct {
        if !Desktop.Cursor(&x,&y) || Abs(x-expectedX)>8 || Abs(y-expectedY)>8
            throw Error("Other pointer activity detected; expected=" . expectedX . "," . expectedY . "; actual=" . x . "," . y)
        button := FindButton(uia, bar, appId)
        x := (button.Rect.L+button.Rect.R)//2, y := (button.Rect.T+button.Rect.B)//2
        hit := uia.Hit(x,y)
        if hit.Kind != "app" || !(hit.Id == appId)
            throw Error("Test Chrome taskbar button is covered or changed")
        MovePointer(x,y,&expectedX,&expectedY)
        if HasArg("--hover") {
            popup := HoverChrome(bar,hwnd,&expectedX,&expectedY)
            if Desktop.RootAt(expectedX,expectedY)!=popup
                throw Error("Test Chrome thumbnail is covered")
        }
        if !Desktop.Cursor(&x,&y) || Abs(x-expectedX)>8 || Abs(y-expectedY)>8
            throw Error("Pointer moved before test click")
    }
    wasMaximized := WinGetMinMax("ahk_id " . hwnd)=1
    Log("Click Chrome; hwnd=" . hwnd . "; foreground=" . Desktop.Foreground() . "; minimized=" . Desktop.IsMin(hwnd)
        . "; source=" . Desktop.MonitorOf(hwnd).Device . "; target=" . Desktop.MonitorOf(bar).Device)
    if HasArg("--compatibility-only") {
        controller := ChromeCompatibility(hwnd,Desktop.MonitorOf(bar),appId)
    } else if HasArg("--move-only") {
        ; Exercise the production after-show mover against a foreign renderer
        ; independently of CBT activation, using only our isolated test Chrome.
        operation := WindowMoveOperation(hwnd,Desktop.MonitorOf(bar),true)
        result := operation.Start()
        Log("Compatibility mover result=" . result)
        if result != "requested"
            throw Error("Compatibility mover did not request the test move")
    } else {
        click := Buffer(80,0)
        NumPut("uint",2,click,20), NumPut("uint",4,click,60)
        if DllCall("user32\SendInput","uint",2,"ptr",click,"int",40,"uint")!=2
            throw Error("Test click failed")
    }
    monitor := Desktop.MonitorOf(bar)
    start := Desktop.Tick(), arrived := 0, whiteMs := 0, rendered := 0, lastState := ""
    Loop {
        elapsed := Desktop.Tick()-start
        if IsSet(controller)
            controller.CompatibilityTick()
        if IsSet(operation) && operation.Phase != "done" {
            result := operation.Advance()
            if result != "waiting" && result != "complete"
                throw Error("Compatibility operation failed: " . result)
        }
        state := Desktop.IsMin(hwnd) . ":" . Desktop.MonitorOf(hwnd).Device . ":" . (Desktop.Foreground()=hwnd)
        if state != lastState {
            Log("Chrome state at " . elapsed . "ms=" . state)
            lastState := state
        }
        if !Desktop.IsMin(hwnd) && Desktop.Foreground()=hwnd && Desktop.SameMonitor(Desktop.MonitorOf(hwnd),monitor) {
            if !arrived
                arrived := elapsed+1
            pixel := PagePixel(hwnd)
            if IsTestColor(pixel) && !rendered
                rendered := elapsed+1
            if !IsTestColor(pixel)
                rendered := 0
            if rendered && elapsed-rendered>=1200 {
                if IsSet(controller) && controller.CompatibilityMoves != 1
                    throw Error("Production compatibility controller did not confirm the test move")
                if (WinGetMinMax("ahk_id " . hwnd)=1)!=wasMaximized
                    throw Error("Chrome changed its maximized state")
                Log("PASS rendered test page on " . monitor.Device . "; maximized=" . wasMaximized . "; arrival-ms=" . (arrived-1)
                    . "; page-ms=" . (rendered-1) . "; last-white-ms=" . whiteMs)
                return
            }
            if (pixel & 0xFFFFFF) >= 0xE0E0E0
                whiteMs := elapsed
        }
        if elapsed>=4000 {
            if arrived
                throw Error(Format("Chrome arrived but page did not render on {}; pixel={:06X}; last-white-ms={}",
                    monitor.Device,pixel,whiteMs))
            throw Error("Chrome never activated on " . monitor.Device . "; final=" . Desktop.MonitorOf(hwnd).Device
                . "; minimized=" . Desktop.IsMin(hwnd) . "; foreground=" . Desktop.Class(Desktop.Foreground()))
        }
        Sleep(35)
    }
}

HasArg(option) {
    for arg in A_Args {
        if arg=option
            return true
    }
    return false
}


if HasArg("--check")
    ExitApp(0)

Desktop.Physical()
originalFocus := Desktop.Foreground()
originalCursor := Desktop.Cursor(&originalX,&originalY)
expectedX := originalX, expectedY := originalY
chrome := A_ProgramFiles . "\Google\Chrome\Application\chrome.exe"
profile := A_ScriptDir . "\results\chrome-render-" . DllCall("kernel32\GetCurrentProcessId","uint") . "-" . A_TickCount
title := "TaskbarFollow Chrome Test"
hwnd := 0, child := 0, failure := 0
try {
    if !originalCursor || !FileExist(chrome)
        throw Error("Chrome or input desktop unavailable")
    primary := WinExist("ahk_class Shell_TrayWnd"), secondary := WinExist("ahk_class Shell_SecondaryTrayWnd")
    if !primary || !secondary
        throw Error("Two taskbars required")
    source := Desktop.MonitorOf(primary)
    DirCreate(profile)
    page := profile . "\test.html"
    FileAppend("<title>" . title . "</title><body style='background:#c95731;color:white;font:32px sans-serif'>" . title,page,"UTF-8")
    Run('"' . chrome . '" --user-data-dir="' . profile . '" --profile-directory=TaskbarFollowTest'
        . ' --no-first-run --no-default-browser-check --disable-background-networking'
        . ' --window-position=' . (source.Work.L+120) . ',' . (source.Work.T+140) . ' --window-size=900,700 "' . page . '"',, , &child)
    deadline := Desktop.Tick()+8000, activated := false
    while Desktop.Tick()<deadline {
        for candidate in WinGetList("ahk_pid " . child . " ahk_class Chrome_WidgetWin_1") {
            if InStr(Desktop.Title(candidate),title) {
                hwnd := candidate
                break
            }
        }
        if hwnd && !activated {
            WinActivate("ahk_id " . hwnd)
            activated := true
        }
        if hwnd && Desktop.Foreground()=hwnd && IsTestColor(PagePixel(hwnd))
            break
        Sleep(65)
    }
    if !hwnd || Desktop.Foreground()!=hwnd || !IsTestColor(PagePixel(hwnd))
        throw Error("Temporary Chrome did not initially render its test page; pid=" . child . "; hwnd=" . hwnd
            . "; focused=" . (Desktop.Foreground()=hwnd) . "; pixel=" . (hwnd?Format("{:06X}",PagePixel(hwnd)):"n/a"))
    appId := WindowIdentity.WindowAppId(hwnd)
    if !RegExMatch(appId,"i)^Chrome\.")
        throw Error("Temporary Chrome does not have its own taskbar identity: " . appId)
    for other in WinGetList("ahk_exe chrome.exe ahk_class Chrome_WidgetWin_1") {
        if other!=hwnd && WindowIdentity.WindowAppId(other)==appId
            throw Error("Test taskbar group includes another Chrome window")
    }
    if !Desktop.SameMonitor(Desktop.MonitorOf(hwnd),source)
        throw Error("Temporary Chrome started on the wrong monitor")
    uia := TaskbarUIA()
    Sleep(850)
    if !Desktop.Cursor(&expectedX,&expectedY)
        throw Error("Cannot read the input pointer")
    originalX := expectedX, originalY := expectedY
    Log("Chrome test appid=" . appId . "; pid=" . child . "; source=" . source.Device)
    if !HasArg("--max-only") {
        ClickChrome(uia,secondary,appId,hwnd,&expectedX,&expectedY)
        Sleep(300)
        ClickChrome(uia,primary,appId,hwnd,&expectedX,&expectedY)
    }
    WinMaximize("ahk_id " . hwnd)
    Sleep(700)
    if WinGetMinMax("ahk_id " . hwnd)!=1
        throw Error("Temporary Chrome did not maximize")
    if HasArg("--hover") {
        anchor := Gui("+ToolWindow", "TaskbarFollow Chrome activation fixture")
        anchor.Show("x" . (source.Work.L+20) . " y" . (source.Work.T+50) . " w210 h70")
        Sleep(350)
    }
    ClickChrome(uia,secondary,appId,hwnd,&expectedX,&expectedY)
    Sleep(300)
    ClickChrome(uia,primary,appId,hwnd,&expectedX,&expectedY)
} catch as e {
    Log("FAIL " . e.Message . "; line=" . e.Line)
    failure := 1
} finally {
    if IsSet(anchor)
        anchor.Destroy()
    if hwnd && Desktop.Pid(hwnd)=child
        try WinClose("ahk_id " . hwnd)
    if originalCursor && Desktop.Cursor(&x,&y) && Abs(x-expectedX)<=8 && Abs(y-expectedY)<=8 {
        try MovePointer(originalX,originalY,&expectedX,&expectedY)
        if originalFocus
            try WinActivate("ahk_id " . originalFocus)
    }
}
ExitApp(failure)
