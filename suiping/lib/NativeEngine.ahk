; Native hooks own input capture and before-show positioning for 64-bit apps.
; Every verified taskbar click also has a bounded, identity-checked backup.
class NativeEngine {
    static PackagedFollowFlag := 8, VerifiedFollowFlag := 16, ShellLaunchFlag := 32, JumpListFlag := 64
    static AppLaunchFlag := 128, AfterShowFlags := 4 | 8 | 16 | 32 | 64 | 128
    static ExistingWindowFollowFlags := 4 | 16
    static Exports() => ["Start", "StopAndWait", "Configure", "SetEnabled", "Cancel", "PublishCache", "Status",
        "SetPeekEnabled", "ShowPeek", "HidePeek", "HoverCandidates", "AccessibleName", "CompatibilityIntent", "CancelCompatibility", "IntentBytes", "BeginFallback", "NextInputStatus"]
    static DllPath() {
        dllName := IniRead(A_ScriptDir . "\native\bin\runtime.ini", "Native", "Dll")
        if !RegExMatch(dllName, "^NativeHooks-[a-f0-9]+-x64\.dll$")
            throw Error("原生定位组件配置无效。")
        return A_ScriptDir . "\native\bin\" . dllName
    }
    static CheckRuntime() {
        module := DllCall("kernel32\LoadLibraryExW", "wstr", this.DllPath(), "ptr", 0, "uint", 0x1100, "ptr")
        if !module
            throw Error("原生定位组件缺失或无法加载：" . A_LastError)
        try {
            for name in this.Exports() {
                if !DllCall("kernel32\GetProcAddress", "ptr", module, "astr", "TF_" . name, "ptr")
                    throw Error("原生定位组件版本不匹配。")
            }
            bytesFn := DllCall("kernel32\GetProcAddress","ptr",module,"astr","TF_IntentBytes","ptr")
            if DllCall(bytesFn,"uint") != 3152
                throw Error("原生定位组件版本不匹配。")
        } finally DllCall("kernel32\FreeLibrary", "ptr", module)
    }
    __New(owner,path := "") {
        this.Owner := owner, this.Handle := 0, this.EventNumber := 0, this.InputNumber := 0, this.CacheCount := 0, this.Ready := false, this.CacheAge := 0
        this.HoverState := "", this.UnsupportedApps := ""
        this.StopError := 0, this.StartAttempted := false, this.StartError := 0
        this.Compatibility := 0, this.CompatibilityMoves := 0
        this.CompatibilityTimer := ObjBindMethod(this,"CompatibilityTick")
        this.Initialize(path != "" ? path : NativeEngine.DllPath())
    }
    Initialize(path) {
        this.Handle := DllCall("kernel32\LoadLibraryExW", "wstr", path, "ptr", 0, "uint", 0x1100, "ptr")
        if !this.Handle
            throw Error("无法加载原生定位组件：" . A_LastError)
        try {
            this.BindExports()
            this.StartAttempted := true
            if !DllCall(this.StartFn, "ptr", A_ScriptHwnd, "uint", 0, "int") {
                this.StartError := A_LastError
                throw Error("原生定位钩子启动失败：" . this.StartError)
            }
            DllCall(this.ConfigureFn,"uint",this.Owner.Timeout,"int",this.Owner.BringActive)
            SplitPath(path,&component)
            this.Owner.Log("native component=" . component)
            this.SetEnabled(this.Owner.Enabled)
            this.SetPeekEnabled(this.Owner.FollowPeek)
        } catch as startupError {
            ; A failed start may still own a worker finishing asynchronously.
            ; ALREADY_INITIALIZED or BUSY belongs to another same-process
            ; lifecycle owner; this loader reference must never stop it.
            if this.StartAttempted && this.StartError != 1247 && this.StartError != 170
                this.Stop()
            else
                this.ReleaseLibrary()
            throw startupError
        }
    }
    BindExports() {
        for name in NativeEngine.Exports() {
            address := DllCall("kernel32\GetProcAddress", "ptr", this.Handle, "astr", "TF_" . name, "ptr")
            if !address
                throw Error("原生定位组件版本不匹配。")
            this.DefineProp(name . "Fn", {Value: address})
        }
        if DllCall(this.IntentBytesFn,"uint") != 3152
            throw Error("原生定位组件版本不匹配。")
    }
    SetEnabled(enabled) {
        if !enabled
            this.StopCompatibility()
        return DllCall(this.SetEnabledFn, "int", enabled)
    }
    SetPeekEnabled(enabled) => DllCall(this.SetPeekEnabledFn,"int",enabled)
    Hover(text) {
        if text = "hide" || !this.Owner.Enabled {
            DllCall(this.HidePeekFn)
            return
        }
        fields := StrSplit(text,"`n")
        if fields.Length < 3
            return
        try {
            x := Integer(fields[1]), y := Integer(fields[2]), popup := Integer(fields[3])
            list := Buffer(32*16,0)
            count := DllCall(this.HoverCandidatesFn,"ptr",list,"uint",32,"uint")
            names := [], candidates := []
            nameBuffer := Buffer(2048,0)
            if DllCall(this.AccessibleNameFn,"int",x,"int",y,"ptr",nameBuffer,"uint",1024,"int")
                names.Push(TaskbarUIAField(StrGet(nameBuffer)))
            Loop fields.Length-3
                names.Push(fields[A_Index+3])
            Loop count {
                hwnd := NumGet(list,(A_Index-1)*16,"uint64"), pid := NumGet(list,(A_Index-1)*16+8,"uint")
                if Desktop.Pid(hwnd) != pid
                    continue
                candidates.Push({Hwnd:hwnd,Pid:pid,Title:TaskbarUIAField(Desktop.Title(hwnd))})
            }
            matches := NativeEngine.HoverMatches(candidates,names)
            state := count . ":" . matches.Length . ":" . popup
            if state != this.HoverState {
                this.HoverState := state
                this.Owner.Log("hover resolve; candidates=" . count . "; matches=" . matches.Length . "; popup=" . popup)
            }
            if matches.Length = 1
                DllCall(this.ShowPeekFn,"ptr",matches[1].Hwnd,"uint",matches[1].Pid,"ptr",popup,"int",x,"int",y,"int")
            else
                DllCall(this.HidePeekFn)
        } catch as e {
            this.Owner.Log("hover resolution error: " . e.Message . "; " . e.Extra . "; line=" . e.Line)
            DllCall(this.HidePeekFn)
        }
    }
    static HoverMatches(candidates,names) {
        matches := [], seen := Map()
        for candidate in candidates {
            if candidate.Title = "" || seen.Has(candidate.Hwnd)
                continue
            for name in names {
                if name != "" && name == candidate.Title {
                    seen[candidate.Hwnd] := true
                    matches.Push(candidate)
                    break
                }
            }
        }
        return matches
    }
    Cancel(cooldown := 0) {
        this.StopCompatibility()
        return this.CancelNativeIntent(cooldown)
    }
    CancelNativeIntent(cooldown := 0) => DllCall(this.CancelFn, "uint", cooldown)
    CancelCompatibilityIntent(serial) => DllCall(this.CancelCompatibilityFn,"uint",serial,"int")
    CompatibilityTakeover(serial) => DllCall(this.BeginFallbackFn,"uint",serial,"int")
    BeginCompatibility(serial,monitorHandle) {
        if !this.Handle || !this.Owner.Enabled
            return false
        intent := this.ReadCompatibilityIntent(serial), now := this.CompatibilityNow()
        if !IsObject(intent) || intent.Serial != serial || intent.Monitor != monitorHandle
            || !(intent.Flags & NativeEngine.AfterShowFlags) || now >= intent.Expires
            return false
        target := this.CompatibilityMonitor(intent.Monitor)
        if !IsObject(target)
            return false
        previousCritical := A_IsCritical
        Critical("On")
        try {
            ; Monitor queries stay outside the short state commit. A delayed
            ; bridge message must not replace a newer compatibility operation.
            fresh := this.ReadCompatibilityIntent(serial)
            if !this.Handle || !this.Owner.Enabled || !IsObject(fresh) || fresh.Serial != serial
                || fresh.Monitor != monitorHandle || !(fresh.Flags & NativeEngine.AfterShowFlags) || this.CompatibilityNow() >= fresh.Expires
                return false
            if IsObject(this.Compatibility) && this.Compatibility.Serial = serial
                return true
            this.StopCompatibility()
            packaged := !!(fresh.Flags & NativeEngine.PackagedFollowFlag)
            shell := !!(fresh.Flags & NativeEngine.ShellLaunchFlag), verified := !!(fresh.Flags & NativeEngine.VerifiedFollowFlag)
            jumpList := !!(fresh.Flags & NativeEngine.JumpListFlag), appLaunch := !!(fresh.Flags & NativeEngine.AppLaunchFlag)
            label := appLaunch ? "应用内新窗口随屏" : (jumpList || shell ? "打开窗口随屏"
                : (verified ? "窗口补充定位" : (packaged ? "应用包窗口补充定位" : "32位兼容定位")))
            logLabel := appLaunch ? "app launch" : (jumpList ? "taskbar jump list" : (shell ? "shell launch"
                : (verified ? "verified follow" : (packaged ? "packaged follow" : "32-bit compatibility"))))
            this.Compatibility := {Serial:serial,Id:fresh.Id,Source:fresh.Source,Observed:0,Target:target,Expires:fresh.Expires,Hwnd:0,Pid:0,Since:0,
                Requested:false,RequestedAt:0,Recovering:false,MovePlan:0,Label:label,LogLabel:logLabel,AppLaunch:appLaunch ? fresh : 0}
            this.CompatibilitySchedule(true)
        } finally Critical(previousCritical ? previousCritical : "Off")
        if !appLaunch
            this.Owner.ReportActivity(label . "正在等待所选窗口显示。")
        return true
    }
    ReadCompatibilityIntent(serial) {
        snapshot := Buffer(3152,0)
        if !DllCall(this.CompatibilityIntentFn,"uint",serial,"ptr",snapshot,"uint",snapshot.Size,"int")
            return 0
        count := NumGet(snapshot,28,"uint"), candidates := []
        if count > 32
            return 0
        Loop count
            candidates.Push({Hwnd:NumGet(snapshot,2592+(A_Index-1)*16,"uint64"),
                Pid:NumGet(snapshot,2600+(A_Index-1)*16,"uint")})
        return {Id:StrGet(snapshot.Ptr+32,256),Path:StrGet(snapshot.Ptr+544,1024),
            Flags:NumGet(snapshot,24,"uint"),Candidates:candidates,Monitor:NumGet(snapshot,3104,"uint64"),
            Released:NumGet(snapshot,3112,"uint64"),Expires:NumGet(snapshot,3120,"uint64"),
            Serial:NumGet(snapshot,3128,"uint"),NativeClaimed:NumGet(snapshot,3132,"uint"),
            Before:NumGet(snapshot,3136,"uint64"),Source:NumGet(snapshot,3144,"uint64")}
    }
    CompatibilityNow() => Desktop.Tick()
    CompatibilityMonitor(handle) => Desktop.Monitor(handle)
    CompatibilitySchedule(enabled) => SetTimer(this.CompatibilityTimer,enabled ? 50 : 0)
    CompatibilitySnapshot(hwnd) {
        if !hwnd
            return 0
        state := this.Compatibility
        source := IsObject(state) && IsObject(state.AppLaunch) ? state.AppLaunch.Source : 0
        return {Hwnd:hwnd,Data:this.Owner.Identity.Get(hwnd),Eligible:Desktop.Eligible(hwnd,source),Owner:Desktop.Owner(hwnd),
            Visible:DllCall("user32\IsWindowVisible","ptr",hwnd),Minimized:Desktop.IsMin(hwnd),
            Monitor:Desktop.MonitorOf(hwnd)}
    }
    CompatibilityForeground() {
        hwnd := Desktop.Foreground(), state := this.Compatibility
        if IsObject(state) && IsObject(state.AppLaunch)
            && !NativeEngine.NewAppWindow(state.AppLaunch,hwnd,Desktop.Pid(hwnd))
            return 0
        return this.CompatibilitySnapshot(hwnd)
    }
    static NewAppWindow(intent,hwnd,pid) {
        if !hwnd || !pid || hwnd = intent.Source || hwnd = intent.Before
            return false
        for candidate in intent.Candidates {
            if candidate.Hwnd = hwnd && candidate.Pid = pid
                return false
        }
        return true
    }
    CompatibilityAppOrigin(hwnd) => this.Owner.Identity.Get(hwnd)
    CompatibilityAppMatches(intent,window) {
        if !intent.Candidates.Length || intent.Candidates[1].Hwnd != intent.Source
            || !NativeEngine.NewAppWindow(intent,window.Hwnd,window.Data.Pid)
            return false
        sourcePid := intent.Candidates[1].Pid, sameProcess := window.Data.Pid = sourcePid
        ; A new HWND in the same process is enough when it has no explicit
        ; AppID. When crossing processes require direct ownership or exact ID.
        if sameProcess && window.Data.AppId = ""
            return true
        origin := this.CompatibilityAppOrigin(intent.Source)
        if origin.Pid != sourcePid
            return sameProcess
        if window.HasOwnProp("Owner") && window.Owner = intent.Source
            return true
        if origin.AppId != "" && window.Data.AppId != ""
            return origin.AppId == window.Data.AppId
        return sameProcess
    }
    CompatibilityRescue(intent) {
        ; With no usable in-process hook, Explorer may minimize an application
        ; that was already active on the other screen. Rescue only that exact
        ; pre-click HWND/PID, never an arbitrary minimized group member.
        if !(intent.Flags & NativeEngine.ExistingWindowFollowFlags) || (intent.Flags & NativeEngine.JumpListFlag)
            || !intent.Before || intent.Candidates.Length != 1
            || intent.Candidates[1].Hwnd != intent.Before || !this.Owner.BringActive
            || this.CompatibilityNow()-intent.Released > 1200
            return 0
        window := this.CompatibilitySnapshot(intent.Before)
        if !IsObject(window) || !window.Minimized || window.Data.Pid != intent.Candidates[1].Pid
            || Desktop.SameMonitor(window.Monitor,this.Compatibility.Target)
            return 0
        window.Recovery := true
        return window
    }
    CompatibilityMove(hwnd,target) {
        state := this.Compatibility
        if (Desktop.Foreground() != hwnd && !state.Recovering) || Desktop.Pid(hwnd) != state.Pid
            return "focus-changed"
        state.MovePlan := WindowMoveOperation(hwnd,target,state.Recovering)
        return state.MovePlan.Start()
    }
    CompatibilityAdvanceMove(state) => state.MovePlan.Advance()
    static CompatibilityDelay(intent) => (intent.Flags & (NativeEngine.PackagedFollowFlag | NativeEngine.VerifiedFollowFlag
        | NativeEngine.JumpListFlag)) && intent.NativeClaimed ? 500 : 80
    CompatibilityMatches(intent,window,ownTransition := false) {
        if !IsObject(window) || !window.Hwnd || !window.Data.Pid || !window.Visible || !window.Eligible
            return false
        if window.Minimized && !ownTransition && !(window.HasOwnProp("Recovery") && window.Recovery
            && (intent.Flags & NativeEngine.ExistingWindowFollowFlags) && window.Hwnd = intent.Before)
            return false
        if intent.Flags & NativeEngine.AppLaunchFlag
            return this.CompatibilityAppMatches(intent,window)
        if intent.Flags & NativeEngine.ShellLaunchFlag
            return window.Hwnd != intent.Before && window.Hwnd != intent.Source
        jumpList := !!(intent.Flags & NativeEngine.JumpListFlag)
        if jumpList && (window.Hwnd = intent.Before || window.Hwnd = intent.Source)
            return false
        listed := false
        for candidate in intent.Candidates {
            if candidate.Hwnd != window.Hwnd
                continue
            if candidate.Pid != window.Data.Pid
                return false
            listed := true
            break
        }
        ; While a group is switching, its old foreground can linger. Only an
        ; explicit single-window click can follow that unchanged foreground.
        if window.Hwnd = intent.Before && (!listed || intent.Candidates.Length != 1 || !this.Owner.BringActive)
            return false
        bothPaths := intent.Path != "" && window.Data.Path != ""
        samePath := bothPaths && StrLower(intent.Path) = StrLower(window.Data.Path)
        if bothPaths && !samePath
            return false
        if jumpList {
            ; Menu commands can open a new instance of a verified application.
            return window.Data.AppId != "" ? this.Owner.Identity.Match(intent.Id,window.Data)
                : samePath && (intent.Flags & 1) && !(intent.Flags & 2)
        }
        if !intent.Candidates.Length && (!samePath || !(intent.Flags & 1)
            || ((intent.Flags & 2) && !(window.Data.AppId == intent.Id)))
            return false
        ; A fresh exact AppID can establish a new foreground HWND even if the
        ; taskbar snapshot predates that window. A path-only warm match still
        ; requires the HWND/PID captured for this button.
        if window.Data.AppId != ""
            return this.Owner.Identity.Match(intent.Id,window.Data)
        return (listed || !intent.Candidates.Length) && samePath && !(intent.Flags & 2)
            && this.Owner.Identity.Match(intent.Id,window.Data)
    }
    CompatibilityCurrent(state) => IsObject(this.Compatibility) && this.Compatibility = state && this.Handle && this.Owner.Enabled
    StopCompatibility(expected := 0) {
        if IsObject(expected) && this.Compatibility != expected
            return false
        state := this.Compatibility
        this.CompatibilitySchedule(false)
        this.Compatibility := 0
        if IsObject(state) && IsObject(state.MovePlan)
            state.MovePlan.Cancel()
        return true
    }
    EndCompatibility(state,text := "",success := false,outcome := "ended") {
        previousCritical := A_IsCritical
        Critical("On")
        try {
            if !this.CompatibilityCurrent(state)
                return
            current := this.ReadCompatibilityIntent(state.Serial)
            if !this.CompatibilityCurrent(state)
                return
            if !IsObject(current) || current.Serial != state.Serial {
                this.StopCompatibility(state)
                return
            }
            ; Native input runs on another thread even during AHK Critical.
            ; Its compare-and-cancel must succeed before counting or reporting.
            cancelled := this.CancelCompatibilityIntent(state.Serial)
            if !this.CompatibilityCurrent(state)
                return
            this.StopCompatibility(state)
            if !cancelled
                return
            if success {
                this.CompatibilityMoves += 1
                this.Owner.SuccessfulMoves += 1
            }
        } finally Critical(previousCritical ? previousCritical : "Off")
        this.LogCompatibilityOutcome(state,success ? "confirmed" : outcome)
        if text != ""
            this.Owner.ReportActivity(text)
    }
    LogCompatibilityOutcome(state,outcome) {
        observed := state.Observed
        if state.LogLabel = "app launch" && !state.Hwnd
            return
        if IsObject(observed)
            observation := "; observed-hwnd=" . observed.Hwnd . "; observed-pid=" . observed.Data.Pid
                . "; observed-id=" . observed.Data.AppId . "; observed-eligible=" . observed.Eligible
                . "; observed-visible=" . observed.Visible . "; observed-minimized=" . observed.Minimized
        else
            observation := "; observed-hwnd=0"
        try this.Owner.Log(state.LogLabel . " " . outcome . "; serial=" . state.Serial . "; id=" . state.Id
            . "; pid=" . state.Pid . "; hwnd=" . state.Hwnd . "; target=" . state.Target.Device
            . "; source-hwnd=" . state.Source . observation)
    }
    CompatibilityTick() {
        state := this.Compatibility
        if !IsObject(state)
            return
        try {
            if !this.Handle || !this.Owner.Enabled {
                this.StopCompatibility(state)
                return
            }
            intent := this.ReadCompatibilityIntent(state.Serial), now := this.CompatibilityNow()
            if !this.CompatibilityCurrent(state)
                return
            if !IsObject(intent) || intent.Serial != state.Serial || !(intent.Flags & NativeEngine.AfterShowFlags) || now >= intent.Expires {
                this.StopCompatibility(state)
                if now >= state.Expires && (!IsObject(state.AppLaunch) || state.Hwnd) {
                    this.LogCompatibilityOutcome(state,state.Hwnd ? "selected-window-timeout" : "no-matching-window")
                    this.Owner.ReportActivity(state.Label . "等待已结束，尚未确认所选窗口到达目标屏幕。")
                }
                return
            }
            if !Desktop.Unchanged(state.Target,this.CompatibilityMonitor(intent.Monitor)) {
                this.EndCompatibility(state,,false,"monitor-changed")
                return
            }
            if state.Requested && IsObject(state.MovePlan) {
                window := this.CompatibilitySnapshot(state.Hwnd)
                if !this.CompatibilityMatches(intent,window,true) || window.Data.Pid != state.Pid {
                    this.EndCompatibility(state,state.Label . "已结束，所选窗口已发生变化。",false,"window-changed")
                    return
                }
                if !window.Minimized && !state.Recovering {
                    foreground := this.CompatibilityForeground()
                    if !IsObject(foreground) || foreground.Hwnd != state.Hwnd {
                        this.EndCompatibility(state,state.Label . "已结束，所选窗口已切换焦点。",false,"focus-changed")
                        return
                    }
                }
                if now-state.RequestedAt >= 1000 {
                    this.EndCompatibility(state,state.Label . "未能确认目标位置，已停止继续尝试。",false,"move-timeout")
                    return
                }
                previousCritical := A_IsCritical
                Critical("On")
                try {
                    if !this.CompatibilityCurrent(state)
                        return
                    fresh := this.ReadCompatibilityIntent(state.Serial)
                    if !this.CompatibilityCurrent(state) || !IsObject(fresh) || fresh.Serial != state.Serial
                        || fresh.Monitor != state.Target.Handle || !(fresh.Flags & NativeEngine.AfterShowFlags)
                        || this.CompatibilityNow() >= fresh.Expires
                        || !this.CompatibilityMatches(fresh,window,true) || !this.CompatibilityTakeover(fresh.Serial)
                        return
                    result := this.CompatibilityAdvanceMove(state)
                } finally Critical(previousCritical ? previousCritical : "Off")
                if result = "waiting"
                    return
                if result != "complete" {
                    this.EndCompatibility(state,state.Label . "请求未完成。",false,result)
                    return
                }
            }
            window := this.CompatibilityForeground()
            state.Observed := window
            if !this.CompatibilityMatches(intent,window) {
                if state.Requested && state.Recovering
                    window := this.CompatibilitySnapshot(state.Hwnd)
                else if !state.Requested
                    window := this.CompatibilityRescue(intent)
            }
            if !this.CompatibilityMatches(intent,window) {
                if state.Requested
                    this.EndCompatibility(state,state.Label . "已结束，所选窗口已隐藏、最小化或切换焦点。",false,"window-no-longer-matches")
                else
                    state.Hwnd := 0, state.Pid := 0, state.Since := 0
                return
            }
            if state.Requested {
                if window.Hwnd != state.Hwnd || window.Data.Pid != state.Pid {
                    this.EndCompatibility(state,state.Label . "已结束，所选窗口已发生变化。",false,"window-changed")
                    return
                }
                if Desktop.SameMonitor(window.Monitor,state.Target)
                    this.EndCompatibility(state,state.Label . "已完成，窗口已在点击的屏幕。",true)
                else if now-state.RequestedAt >= 1000
                    this.EndCompatibility(state,state.Label . "未能确认目标位置，已停止继续尝试。",false,"move-timeout")
                return
            }
            if state.Hwnd != window.Hwnd || state.Pid != window.Data.Pid {
                state.Hwnd := window.Hwnd, state.Pid := window.Data.Pid, state.Since := now
                state.Recovering := window.HasOwnProp("Recovery") && window.Recovery
                return
            }
            if now-state.Since < NativeEngine.CompatibilityDelay(intent)
                return
            if Desktop.SameMonitor(window.Monitor,state.Target) {
                this.EndCompatibility(state,"所选窗口已在点击的屏幕上。",false,"already-there")
                return
            }
            ; Window identity queries can dispatch messages. Finish those before
            ; entering the short, final state/epoch check and move request.
            selected := state.Recovering ? this.CompatibilityRescue(intent) : this.CompatibilityForeground()
            if !this.CompatibilityMatches(intent,selected) || selected.Hwnd != state.Hwnd || selected.Data.Pid != state.Pid {
                state.Hwnd := 0, state.Pid := 0, state.Since := 0
                return
            }
            previousCritical := A_IsCritical
            Critical("On")
            try {
                if !this.CompatibilityCurrent(state) {
                    this.StopCompatibility(state)
                    return
                }
                fresh := this.ReadCompatibilityIntent(state.Serial)
                if !this.CompatibilityCurrent(state)
                    return
                if !IsObject(fresh) || fresh.Serial != state.Serial || fresh.Monitor != state.Target.Handle
                    || !(fresh.Flags & NativeEngine.AfterShowFlags) || this.CompatibilityNow() >= fresh.Expires {
                    this.StopCompatibility(state)
                    return
                }
                if now-state.Since < NativeEngine.CompatibilityDelay(fresh) || !this.CompatibilityMatches(fresh,selected)
                    return
                if !this.CompatibilityTakeover(fresh.Serial)
                    return
                result := this.CompatibilityMove(state.Hwnd,state.Target)
                if result = "requested"
                    state.Requested := true, state.RequestedAt := now
            } finally Critical(previousCritical ? previousCritical : "Off")
            if result != "requested" {
                this.EndCompatibility(state,result = "already-there"
                    ? "所选窗口已在点击的屏幕上。"
                    : state.Label . "请求未完成。",false,result)
                return
            }
            this.Owner.Log(state.LogLabel . " requested; serial=" . state.Serial . "; id=" . fresh.Id . "; pid=" . state.Pid
                . "; hwnd=" . state.Hwnd . "; target=" . state.Target.Device . "; recovering=" . state.Recovering
                . "; native-claimed=" . fresh.NativeClaimed . "; before=" . fresh.Before
                . "; since-release-ms=" . (now-fresh.Released) . "; source=" . selected.Monitor.Device
                . "; minimized=" . selected.Minimized)
        } catch as e {
            this.StopCompatibility(state)
            try this.Owner.Log(state.LogLabel . " error: " . e.Message . "; line=" . e.Line)
        }
    }
    Stop(timeoutMs := 3000) {
        this.StopCompatibility()
        this.Ready := false
        if !this.Handle {
            this.StopError := 0
            return true
        }
        try {
            if !DllCall(this.StopAndWaitFn,"uint",timeoutMs,"int") {
                this.StopError := A_LastError
                this.StopFailed("shutdown not confirmed")
                return false
            }
        } catch as stopError {
            this.StopError := A_LastError
            this.StopFailed("stop call failed: " . stopError.Message)
            return false
        }
        return this.ReleaseLibrary()
    }
    ReleaseLibrary() {
        if !this.Handle
            return true
        if !DllCall("kernel32\FreeLibrary","ptr",this.Handle,"int") {
            this.StopError := A_LastError
            this.StopFailed("DLL release failed")
            return false
        }
        this.Handle := 0, this.StopError := 0
        return true
    }
    StopFailed(reason) {
        ; Logging must not turn a bounded shutdown failure into an exception
        ; that skips the controller's remaining helper/hook cleanup.
        try this.Owner.Log("native shutdown incomplete; " . reason . "; Win32=" . this.StopError . "; retained DLL=" . this.Handle)
    }
    InvalidateCache() {
        if !this.Handle
            return
        DllCall(this.PublishCacheFn,"ptr",0,"uint",0,"uint",3104,"int")
        this.CacheCount := 0, this.CacheAge := 0, this.Ready := false
    }
    Publish(text,epoch) {
        if epoch != this.Owner.NativeCacheEpoch
            return
        windows := []
        for hwnd in WinGetList() {
            if Desktop.Eligible(hwnd) {
                data := this.Owner.Identity.Get(hwnd)
                windows.Push({Hwnd: hwnd, Data: data})
            }
        }
        buttons := []
        for line in StrSplit(text, "`n") {
            fields := StrSplit(line, "`t")
            if fields.Length != 6 || fields[6] = "" || StrLen(fields[6]) >= 256
                continue
            try {
                bar := Integer(fields[1]), rect := ScreenRect(Integer(fields[2]),Integer(fields[3]),Integer(fields[4]),Integer(fields[5]))
                if !Desktop.IsTaskbar(Desktop.Class(bar)) || rect.W <= 0 || rect.H <= 0
                    continue
                buttons.Push({Id:fields[6],Bar:bar,Rect:rect})
            } catch {
                continue
            }
        }
        records := NativeEngine.ResolveButtons(buttons,windows,this.Owner.Identity)
        unsupported := Map(), unsupported.CaseSense := true
        cacheBuffer := Buffer(Max(1,records.Length) * 3104, 0)
        for index, record in records {
            if !record.Candidates.Length && !record.Flags
                unsupported[record.Id] := true
            offset := (index-1)*3104
            NumPut("uint64",record.Bar,cacheBuffer,offset)
            record.Rect.Write(cacheBuffer,offset+8)
            NumPut("uint",record.Flags,"uint",record.Candidates.Length,cacheBuffer,offset+24)
            StrPut(record.Id,cacheBuffer.Ptr+offset+32,256)
            StrPut(record.Path,cacheBuffer.Ptr+offset+544,1024)
            for number,item in record.Candidates
                NumPut("uint64",item.Hwnd,"uint",item.Data.Pid,cacheBuffer,offset+2592+(number-1)*16)
        }
        ; Identity resolution can yield to a display notification or helper
        ; restart. Keep the epoch check and native cache commit together.
        criticalState := A_IsCritical
        Critical "On"
        try {
            if !this.Handle || epoch != this.Owner.NativeCacheEpoch
                return
            if !DllCall(this.PublishCacheFn,"ptr",cacheBuffer,"uint",records.Length,"uint",3104,"int")
                throw Error("原生任务栏缓存提交失败。")
            this.CacheAge := 0, this.CacheCount := records.Length
        } finally Critical criticalState
        unavailable := ""
        for id in unsupported
            unavailable .= (unavailable = "" ? "" : "; ") . id
        if unavailable != this.UnsupportedApps {
            this.UnsupportedApps := unavailable
            this.Owner.Log("native buttons without verified launch/window identity=" . (unavailable = "" ? "none" : unavailable))
        }
    }
    static ResolveButtons(buttons,windows,identity) {
        ; Scope all reuse to this publish: window identities, launch files and
        ; mappings must be checked afresh when the next UIA snapshot arrives.
        index := NativeIdentityIndex(windows,identity)
        resolved := Map(), resolved.CaseSense := true
        records := []
        for button in buttons {
            try {
                if !resolved.Has(button.Id) {
                    ; A failing identity must not repeat the same slow query for
                    ; its other taskbar buttons during this publish.
                    resolved[button.Id] := 0
                    resolved[button.Id] := NativeEngine.ResolveEntry(button.Id,windows,identity,index)
                }
                entry := resolved[button.Id]
                if !IsObject(entry)
                    continue
                ; Never attach geometry to the shared identity object. The same
                ; application can have a different button on every taskbar.
                records.Push({Id:entry.Id,Path:entry.Path,Flags:entry.Flags,Candidates:entry.Candidates,
                    Bar:button.Bar,Rect:button.Rect})
            } catch {
                continue
            }
            if records.Length >= 64
                break
        }
        return records
    }
    ; Resolve launch eligibility outside the input callback. Keep this independent
    ; of UIA/geometry so a no-window (cold-start) button is regression-testable.
    static ResolveEntry(id,windows,identity,index := 0) {
        if !IsObject(index)
            index := NativeIdentityIndex(windows,identity)
        candidates := [], paths := Map()
        for item in index.Matches(id) {
            if candidates.Length < 32
                candidates.Push(item)
            ; Inspect every match, including those beyond the native HWND cap.
            if item.Data.Path != ""
                paths[index.Normalize(item.Data.Path)] := item.Data.Path
        }
        path := ""
        if paths.Count = 1 {
            for pathKey,pathValue in paths {
                path := pathValue
                break
            }
        }
        ; Multiple executable paths for one ID are not a cold-start identity.
        if !paths.Count
            path := identity.NativePath(id,index.ExpandIdPath(id))
        if StrLen(path) >= 1024
            path := ""
        cold := path != "" && index.IsExecutable(path)
        requireId := cold && index.RequiresAppId(id,path)
        binaryType := cold ? index.BinaryType(path) : -1
        compatibility := binaryType = 0
        packagedFollow := binaryType = 6 && !candidates.Length && WindowIdentity.PackageId(id)
        verifiedFollow := !compatibility && !packagedFollow && (binaryType = 6 || candidates.Length)
        ; Retain unsupported buttons too: an explicit click should report why it
        ; was skipped, not vanish from the cache without any status/log feedback.
        return {Id:id,Path:path,Candidates:candidates,
            Flags:(cold?1:0)|(requireId?2:0)|(compatibility?4:0)|(packagedFollow?NativeEngine.PackagedFollowFlag:0)
                |(verifiedFollow?NativeEngine.VerifiedFollowFlag:0)}
    }
    Poll() {
        this.PollInput()
        status := Buffer(168,0)
        if !DllCall(this.StatusFn,"ptr",status,"uint",status.Size,"int")
            return
        this.CacheCount := NumGet(status,12,"uint")
        this.CacheAge := NumGet(status,16,"uint64")
        this.Ready := NumGet(status,4,"uint") && this.CacheCount && this.CacheAge <= 3000
        this.Owner.SuccessfulMoves := NumGet(status,56,"uint64") + NumGet(status,48,"uint64") + this.CompatibilityMoves
        eventNumber := NumGet(status,96,"uint64")
        if eventNumber = this.EventNumber
            return
        this.EventNumber := eventNumber
        ; See NativeStatus's explicit ABI: lastKind=72, lastPid=76,
        ; lastWindow=80, latency=88, eventNumber=96, target=104.
        kind := NumGet(status,72,"uint"), pid := NumGet(status,76,"uint"), hwnd := NumGet(status,80,"uint64")
        latency := NumGet(status,88,"uint64"), target := StrGet(status.Ptr+104,32)
        this.Owner.Log("native event=" . kind . "; pid=" . pid . "; hwnd=" . hwnd . "; target=" . target . "; since-release-ms=" . latency)
        static messages := Map(1,"已接到任务栏点击，等待 Windows 创建或恢复对应窗口。",
            2,"已在窗口创建时指定点击的屏幕，等待首次显示。",
            3,"已在窗口恢复显示前准备好目标位置。",
            4,"已确认激活的窗口稳定在点击的屏幕。",
            5,"已确认启动或恢复的窗口稳定在点击的屏幕。",
            6,"你开始了其他操作，已取消尚未完成的定位。",
            7,"任务栏已展开多个窗口，请选择需要唤起的那个。",
            8,"此应用暂不支持原生定位，本次保留系统行为。",
            9,"窗口已在点击的屏幕上，保留系统行为。",
            10,"本次未能确认所选窗口完成定位，已结束等待并保留系统位置。",
            12,"正在当前屏幕显示悬停预览，移开鼠标即关闭；原窗口保持原位。",
            13,"悬停预览已关闭，原窗口位置和最小化状态保持不变。",
            16,"应用未接受目标位置，本次未确认定位成功。")
        state := this.Compatibility
        if kind = 1 && IsObject(state)
            this.Owner.ReportActivity(state.Label . "正在等待所选窗口显示。")
        else if messages.Has(kind)
            this.Owner.ReportActivity(messages[kind])
    }
    PollInput() {
        snapshot := Buffer(768,0)
        static reasons := Map(1,"pressed",2,"modifier",3,"cooldown",4,"hit-rejected",7,"released",8,"input-cancelled",9,"hold-rejected",10,"drag-rejected")
        Loop 32 {
            if !DllCall(this.NextInputStatusFn,"uint64",this.InputNumber,"ptr",snapshot,"uint",snapshot.Size,"int")
                break
            this.InputNumber := NumGet(snapshot,0,"uint64")
            reason := NumGet(snapshot,36,"uint")
            this.Owner.Log("native input=" . (reasons.Has(reason) ? reasons[reason] : reason)
                . "; point=" . NumGet(snapshot,8,"int") . "," . NumGet(snapshot,12,"int")
                . "; target=" . StrGet(snapshot.Ptr+704,32) . "; serial=" . NumGet(snapshot,60,"uint")
                . "; root=" . NumGet(snapshot,16,"uint64") . "; class=" . StrGet(snapshot.Ptr+64,64)
                . "; dpi-awareness=" . NumGet(snapshot,40,"uint") . "; cache-age-ms=" . NumGet(snapshot,24,"uint64")
                . "; candidates=" . NumGet(snapshot,48,"uint") . "; delta=" . NumGet(snapshot,52,"int") . "," . NumGet(snapshot,56,"int")
                . "; id=" . StrGet(snapshot.Ptr+192,256))
        }
    }
}
TaskbarUIAField(text) => SubStr(StrReplace(StrReplace(text,"`n"," "),"`r"," "),1,1024)
