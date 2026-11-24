#Requires AutoHotkey v2.0 64-bit
#NoTrayIcon
#SingleInstance Off
#Include lib\Native.ahk
#Include lib\LinkFollow.ahk

; 随屏链接: when the user picks it as the default browser, Windows hands every
; http/https link opened by another application to this script. It opens the
; link with the real browser on the monitor where the user clicked:
;   - a browser window already on that monitor -> new tab there;
;   - otherwise -> a new browser window placed on that monitor.
; It only ever starts the recorded browser executable, never the URL through
; the shell, so a link cannot loop back here. Nothing is logged about the URL.
if A_LineFile = A_ScriptFullPath {
    Desktop.Physical()
    LinkOpen.Main()
    ExitApp(0)
}

class LinkOpen {
    static Root := A_ScriptDir
    static Main() {
        config := this.Root . "\settings.ini", url := this.Url()
        browser := LinkFollow.Browser(config)
        if !IsObject(browser) {
            MsgBox("随屏链接没有找到可用的浏览器（Chrome 或 Edge），这个链接没有打开。`n`n"
                . "可以双击随屏文件夹里的「撤销链接随屏.cmd」，把默认浏览器改回原来的浏览器。",LinkFollow.Title,"Iconx")
            return
        }
        try {
            this.Open(config,browser,url)
        } catch as failure {
            this.Log("error " . failure.Message . "; line=" . failure.Line)
            ; Never lose the link: the browser's ordinary command still opens it.
            try this.Start(LinkFollow.CommandLine(browser,url))
        }
    }
    static Url() {
        line := DllCall("kernel32\GetCommandLineW","str")
        marker := " --single-argument "
        position := InStr(line,marker)
        if position
            return Trim(SubStr(line,position+StrLen(marker)))
        return A_Args.Length ? A_Args[1] : ""
    }
    static Open(config,browser,url) {
        SplitPath(browser.Path,&exe)
        if url = "" {
            this.Start(LinkFollow.CommandLine(browser,""))
            return
        }
        follow := MonitorGetCount() > 1 && IniRead(config,"General","Enabled","1") = "1"
            && IniRead(config,LinkFollow.Section,"Enabled","1") = "1"
        if !follow {
            this.Start(LinkFollow.CommandLine(browser,url))
            this.Log("plain; browser=" . exe)
            return
        }
        target := this.Target()
        windows := this.Windows(browser.Path)
        if IniRead(config,LinkFollow.Section,"ReuseScreenWindow","1") = "1" {
            for window in windows {
                if !window.Tabbed || window.Minimized || !window.Eligible || !Desktop.SameMonitor(window.Monitor,target)
                    continue
                ; The browser opens external links in its most recently active
                ; window; activate the one on the clicked screen first.
                if this.Activate(window.Hwnd) {
                    this.Start(LinkFollow.CommandLine(browser,url))
                    this.Log("tab; target=" . target.Device . "; browser=" . exe)
                    return
                }
                break
            }
        }
        running := windows.Length || ProcessExist(exe)
        newWindow := running && LinkFollow.NewWindowFlag(browser.Path) != ""
        armed := this.ArmController(target,browser.Path,windows)
        ; This process may set the foreground (its parent app is in front).
        ; Pass that on so the browser can activate the window it creates.
        DllCall("user32\AllowSetForegroundWindow","uint",0xFFFFFFFF)
        this.Start(LinkFollow.CommandLine(browser,url,newWindow))
        this.Log("window; target=" . target.Device . "; browser=" . exe . "; new-window-flag=" . newWindow
            . "; controller=" . (armed ? "armed" : "unavailable"))
        if !armed
            this.FollowNewWindow(browser.Path,windows,target)
    }
    static Target() {
        if Desktop.Cursor(&x,&y) && IsObject(monitor := Desktop.MonitorAt(x,y))
            return monitor
        return Desktop.MonitorOf(Desktop.Foreground())
    }
    ; Every visible (including minimized) top-level window of the browser
    ; image, in Z order, so the topmost on a screen is its most recent one.
    static Windows(path) {
        result := [], paths := Map(), identity := WindowIdentity("",false)
        for hwnd in WinGetList() {
            pid := Desktop.Pid(hwnd)
            if !pid
                continue
            if !paths.Has(pid)
                paths[pid] := StrLower(identity.Get(hwnd).Path)
            if paths[pid] != StrLower(path)
                continue
            appId := WindowIdentity.WindowAppId(hwnd)
            ; Installed web apps (PWAs) share the browser image but are not tabbed windows.
            result.Push({Hwnd:hwnd,Pid:pid,Minimized:Desktop.IsMin(hwnd),Eligible:Desktop.Eligible(hwnd),
                Tabbed:!InStr(appId,"_crx_") && !InStr(appId,"!"),Monitor:Desktop.MonitorOf(hwnd)})
        }
        return result
    }
    static Activate(hwnd) {
        if Desktop.Foreground() = hwnd
            return true
        DllCall("user32\SetForegroundWindow","ptr",hwnd)
        deadline := Desktop.Tick() + 400
        while Desktop.Tick() < deadline {
            if Desktop.Foreground() = hwnd {
                Sleep(30) ; let the browser record this window as its last active one
                return true
            }
            Sleep(15)
        }
        return false
    }
    static Controller() {
        previous := DetectHiddenWindows(true)
        try {
            prefix := StrLower(this.Root . "\TaskbarFollow.ahk - AutoHotkey")
            for hwnd in WinGetList("ahk_class AutoHotkey") {
                if DllCall("user32\GetPropW","ptr",hwnd,"wstr","TaskbarFollow.InstanceMarker","ptr") != 0x54424632
                    continue
                if SubStr(StrLower(Desktop.Title(hwnd)),1,StrLen(prefix)) = prefix
                    return hwnd
            }
            return 0
        } finally DetectHiddenWindows(previous)
    }
    ; The running 随屏 places the new window before it is first shown (64-bit
    ; browsers with the current native component). Otherwise we move it here.
    static ArmController(target,path,windows) {
        controller := this.Controller()
        if !controller
            return false
        list := ""
        for window in windows
            list .= (list = "" ? "" : ",") . window.Hwnd
        text := "launch`n" . target.Handle . "`n" . path . "`n" . list
        data := Buffer((StrLen(text)+1)*2,0), StrPut(text,data,"UTF-16")
        cds := Buffer(A_PtrSize*3,0)
        NumPut("uptr",LinkFollow.Magic,cds,0), NumPut("uint",data.Size,cds,A_PtrSize), NumPut("ptr",data.Ptr,cds,A_PtrSize*2)
        reply := 0
        sent := DllCall("user32\SendMessageTimeoutW","ptr",controller,"uint",0x4A,"ptr",A_ScriptHwnd,"ptr",cds,
            "uint",0x2,"uint",1500,"ptr*",&reply,"ptr") ; SMTO_ABORTIFHUNG
        return sent && reply = 1
    }
    static Start(commandLine) {
        startup := Buffer(104,0), NumPut("uint",104,startup,0)
        process := Buffer(24,0)
        ; CreateProcessW may write to the command line: give it its own copy.
        line := Buffer((StrLen(commandLine)+1)*2,0), StrPut(commandLine,line,"UTF-16")
        if !DllCall("kernel32\CreateProcessW","ptr",0,"ptr",line,"ptr",0,"ptr",0,"int",false,"uint",0,
            "ptr",0,"ptr",0,"ptr",startup,"ptr",process)
            throw OSError(A_LastError,-1,"无法启动浏览器")
        DllCall("kernel32\CloseHandle","ptr",NumGet(process,0,"ptr"))
        DllCall("kernel32\CloseHandle","ptr",NumGet(process,A_PtrSize,"ptr"))
        return NumGet(process,A_PtrSize*2,"uint")
    }
    ; Fallback when 随屏 is not running or its native component predates link
    ; support: wait for the browser's new foreground window, then move it once
    ; with the same staged minimize/place/restore operation the controller uses.
    static FollowNewWindow(path,before,target,timeout := 8000) {
        known := Map()
        for window in before
            known[window.Hwnd] := true
        identity := WindowIdentity("",false), path := StrLower(path)
        deadline := Desktop.Tick() + timeout, candidate := 0, since := 0, plan := 0, planUntil := 0
        Loop {
            now := Desktop.Tick()
            if now >= deadline
                return
            if IsObject(plan) {
                result := plan.Advance()
                if result != "waiting" || now >= planUntil {
                    this.Log("fallback " . result . "; target=" . target.Device)
                    return
                }
                Sleep(50)
                continue
            }
            hwnd := Desktop.Foreground()
            if hwnd && !known.Has(hwnd) && Desktop.Eligible(hwnd) && !Desktop.IsMin(hwnd)
                && StrLower(identity.Get(hwnd).Path) = path {
                if hwnd != candidate
                    candidate := hwnd, since := now
                else if now - since >= 80 {
                    if Desktop.SameMonitor(Desktop.MonitorOf(hwnd),target)
                        return
                    plan := WindowMoveOperation(hwnd,target)
                    started := plan.Start()
                    if started != "requested" {
                        this.Log("fallback " . started . "; target=" . target.Device)
                        return
                    }
                    planUntil := now + 1500
                }
            } else
                candidate := 0
            Sleep(50)
        }
    }
    static Log(text) {
        try {
            directory := this.Root . "\logs", file := directory . "\LinkOpen.log"
            DirCreate(directory)
            if FileExist(file) && FileGetSize(file) > 262144
                FileMove(file,file . ".1",1)
            FileAppend(FormatTime(,"yyyy-MM-dd HH:mm:ss") . " " . text . "`n",file,"UTF-8")
        }
    }
}
