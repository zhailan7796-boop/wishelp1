#Requires AutoHotkey v2.0 64-bit
#NoTrayIcon
#Warn VarUnset, StdOut
#Include ..\lib\Native.ahk
#Include ..\lib\NativeEngine.ahk

; Inject OS observations and the native snapshot only. Exercise the production
; click gate, candidate selection, bounded move and confirmation code without
; hooks, timers, input or application windows.
class CompatibilityChecks {
    static Count := 0
    static StopEngine := 0, StoppedTimerFirst := false, AbiCount := 2
    static Assert(value,label) {
        if !value
            throw Error(label)
        this.Count += 1
    }
    static Monitor(handle) => {Handle:handle,Device:"Fixture" . handle,
        Bounds:ScreenRect((handle-1)*1920,0,handle*1920,1080),
        Work:ScreenRect((handle-1)*1920,0,handle*1920,1040)}
    static Window(hwnd := 11,pid := 101) {
        SplitPath(A_AhkPath,&exe)
        return {Hwnd:hwnd,Data:{Pid:pid,AppId:"",Path:A_AhkPath,Exe:exe},
            Eligible:true,Visible:true,Minimized:false,Monitor:this.Monitor(1)}
    }
    static Stable(fixture) {
        fixture.CompatibilityTick()
        fixture.Now += 50, fixture.CompatibilityTick()
        fixture.Now += 50, fixture.CompatibilityTick()
    }
    static NoRequest(fixture,label) {
        this.Stable(fixture)
        this.Assert(fixture.Requests.Length = 0,label)
    }
    static NativeStop(timeout) {
        this.StoppedTimerFirst := !this.StopEngine.Scheduled
        return 1
    }
    static NativeStatus(status,bytes) {
        if bytes != 168
            return 0
        NumPut("uint64",3,status,48)
        NumPut("uint64",4,status,56)
        return 1
    }
    static NativeIntent(serial,snapshot,bytes) {
        if serial != 7 || bytes != 3152
            return 0
        NumPut("uint",5,"uint",this.AbiCount,snapshot,24)
        StrPut("Fixture.App",snapshot+32,256)
        StrPut(A_AhkPath,snapshot+544,1024)
        NumPut("uint64",11,"uint",101,snapshot,2592)
        NumPut("uint64",12,"uint",102,snapshot,2608)
        NumPut("uint64",2,"uint64",900,"uint64",9000,"uint",7,snapshot,3104)
        NumPut("uint",1,snapshot,3132)
        return 1
    }
}
class CompatibilityOwner {
    Enabled := true, BringActive := true, SuccessfulMoves := 0, Messages := [], Logs := []
    __New() {
        this.Identity := WindowIdentity("",false)
        this.Identity.Mappings["Fixture.App"] := A_AhkPath
    }
    ReportActivity(text) => this.Messages.Push(text)
    Log(text) => this.Logs.Push(text)
}
class CompatibilityPlan {
    Advances := 0, Cancels := 0, Result := "waiting"
    Advance() => (this.Advances += 1,this.Result)
    Cancel() => this.Cancels += 1
}
class CompatibilityFixture extends NativeEngine {
    __New(warm := true) {
        this.Owner := CompatibilityOwner(), this.Handle := 1, this.Compatibility := 0, this.CompatibilityMoves := 0
        this.Now := 1000, this.Valid := true, this.Selected := CompatibilityChecks.Window()
        this.Intent := {Serial:7,Flags:5,Id:"Fixture.App",Path:A_AhkPath,Monitor:2,Released:900,Expires:9000,NativeClaimed:0,Before:0,Source:0,
            Candidates:warm ? [{Hwnd:11,Pid:101}] : []}
        this.Requests := [], this.Scheduled := false, this.ScheduleStarts := 0, this.NativeCancels := 0
        this.MoveResult := "requested", this.IntentReads := 0, this.CancelAtRead := 0
        this.ForegroundReads := 0, this.InterruptAtForeground := 0, this.InterruptKind := ""
        this.WindowSnapshot := 0
        this.AppOrigin := {Pid:101,AppId:"Fixture.App"}
        this.TakeoverAllowed := true
        this.ReplaceAtRead := 0, this.ReplaceDuringCompare := false, this.ReplaceNativeOnlyDuringCompare := false
        this.CompareCritical := 0, this.MoveCritical := 0
    }
    ReadCompatibilityIntent(serial) {
        this.IntentReads += 1
        if this.ReplaceAtRead && this.IntentReads = this.ReplaceAtRead {
            previous := this.Intent
            this.ReplaceAtRead := 0
            this.ReplaceIntent()
            return previous
        }
        if this.CancelAtRead && this.IntentReads = this.CancelAtRead {
            this.Valid := false
            return 0
        }
        return this.Valid && serial = this.Intent.Serial ? this.Intent : 0
    }
    CompatibilityNow() => this.Now
    PollInput() { ; Native input observations are separate from this OS fixture.
    }
    CompatibilityTakeover(serial) => this.TakeoverAllowed && this.Valid && serial = this.Intent.Serial
    CompatibilitySnapshot(hwnd) => IsObject(this.WindowSnapshot) && this.WindowSnapshot.Hwnd = hwnd ? this.WindowSnapshot : 0
    CompatibilityAppOrigin(hwnd) => this.AppOrigin
    CompatibilityMonitor(handle) => CompatibilityChecks.Monitor(handle)
    CompatibilitySchedule(enabled) {
        this.Scheduled := enabled
        if enabled
            this.ScheduleStarts += 1
    }
    CompatibilityForeground() {
        this.ForegroundReads += 1
        if this.InterruptAtForeground && this.ForegroundReads = this.InterruptAtForeground {
            switch this.InterruptKind {
                case "cancel": this.Cancel()
                case "pause": this.Owner.Enabled := false
                case "stop": this.Handle := 0, this.StopCompatibility()
                case "replace": this.ReplaceIntent()
                case "replace-throw":
                    this.ReplaceIntent()
                    throw Error("Expected replaced observation failure")
            }
        }
        return this.Selected
    }
    ReplaceIntent() {
        this.Intent := this.Intent.Clone()
        this.Intent.Serial := 8
        this.Valid := true
        this.BeginCompatibility(8,2)
    }
    CompatibilityMove(hwnd,target) {
        this.Requests.Push({Hwnd:hwnd,Target:target})
        this.MoveCritical := A_IsCritical
        return this.MoveResult
    }
    CancelNativeIntent(cooldown := 0) => (this.NativeCancels += 1,this.Valid := false)
    CancelCompatibilityIntent(serial) {
        this.CompareCritical := A_IsCritical
        if this.ReplaceNativeOnlyDuringCompare {
            this.Intent := this.Intent.Clone()
            this.Intent.Serial := 8
            return false
        }
        if this.ReplaceDuringCompare {
            this.ReplaceDuringCompare := false
            this.ReplaceIntent()
        }
        if !this.Valid || serial != this.Intent.Serial
            return false
        this.NativeCancels += 1, this.Valid := false
        return true
    }
    ReleaseLibrary() => (this.Handle := 0,this.StopError := 0,true)
}

callbacks := []
try {
    fixture := CompatibilityFixture()
    CompatibilityChecks.NoRequest(fixture,"A foreground window without a taskbar click never moves")
    CompatibilityChecks.Assert(!fixture.Scheduled,"No click creates no periodic compatibility work")
    fixture.Valid := false
    CompatibilityChecks.Assert(!fixture.BeginCompatibility(7,2) && !fixture.Scheduled,"A cancelled native intent cannot start compatibility")
    fixture := CompatibilityFixture(), fixture.Intent.Flags := 1
    CompatibilityChecks.Assert(!fixture.BeginCompatibility(7,2),"An ordinary 64-bit native click cannot start compatibility")
    fixture := CompatibilityFixture()
    CompatibilityChecks.Assert(!fixture.BeginCompatibility(7,3) && !fixture.Scheduled,
        "A delayed message with a different monitor payload cannot start compatibility")

    fixture := CompatibilityFixture(), fixture.Selected.Data.Pid := 202, fixture.Selected.Data.AppId := "Fixture.App"
    fixture.BeginCompatibility(7,2)
    CompatibilityChecks.NoRequest(fixture,"A recycled HWND with a different PID is rejected")
    fixture := CompatibilityFixture(), fixture.Selected.Hwnd := 12
    fixture.BeginCompatibility(7,2)
    CompatibilityChecks.NoRequest(fixture,"A same-process window outside the warm snapshot is rejected")
    fixture.Selected.Data.AppId := "Fixture.App"
    CompatibilityChecks.Stable(fixture)
    CompatibilityChecks.Assert(fixture.Requests.Length = 1 && fixture.Requests[1].Hwnd = 12,
        "An exact live AppID confirms a new foreground window absent from the taskbar snapshot")
    fixture := CompatibilityFixture(), fixture.Selected.Hwnd := 12, fixture.Selected.Data.AppId := "Fixture.App"
    fixture.Selected.Data.Path := A_Temp . "\other.exe"
    fixture.BeginCompatibility(7,2)
    CompatibilityChecks.NoRequest(fixture,"An unlisted window with the same AppID but a different known installation is rejected")
    fixture := CompatibilityFixture(false), fixture.Selected.Data.Path := "C:\Other\AutoHotkey64.exe"
    fixture.BeginCompatibility(7,2)
    CompatibilityChecks.NoRequest(fixture,"Cold identity requires the exact verified executable path")
    fixture := CompatibilityFixture(false), fixture.Selected.Data.AppId := "Fixture.Other"
    fixture.BeginCompatibility(7,2)
    CompatibilityChecks.NoRequest(fixture,"An explicit foreign AppID cannot borrow the matching path")
    fixture := CompatibilityFixture(false), fixture.Intent.Flags := 7
    fixture.BeginCompatibility(7,2)
    CompatibilityChecks.NoRequest(fixture,"A shared host requiring an AppID rejects a missing remote AppID")
    fixture := CompatibilityFixture(false), fixture.Intent.Flags := 7, fixture.Selected.Data.AppId := "fixture.app"
    fixture.BeginCompatibility(7,2)
    CompatibilityChecks.NoRequest(fixture,"A required AppID is compared case-sensitively")

    for field in ["Visible","Minimized","Eligible"] {
        fixture := CompatibilityFixture()
        fixture.Selected.%field% := field = "Minimized"
        fixture.BeginCompatibility(7,2)
        CompatibilityChecks.NoRequest(fixture,"A hidden, minimized or ineligible selected window is not restored: " . field)
    }
    fixture := CompatibilityFixture(), fixture.Selected := 0
    fixture.BeginCompatibility(7,2)
    CompatibilityChecks.NoRequest(fixture,"An absent foreground window is not replaced by another candidate")

    fixture := CompatibilityFixture(), fixture.BeginCompatibility(7,2)
    fixture.CompatibilityTick(), fixture.Now += 50, fixture.CompatibilityTick()
    CompatibilityChecks.Assert(!fixture.Requests.Length,"A selected window must remain stable for at least 80 ms")
    fixture.Selected := CompatibilityChecks.Window(12,102)
    fixture.Intent.Candidates.Push({Hwnd:12,Pid:102})
    fixture.Now += 50, fixture.CompatibilityTick()
    fixture.Now += 50, fixture.CompatibilityTick()
    CompatibilityChecks.Assert(!fixture.Requests.Length,"Selecting another group member restarts the stability interval")
    fixture.Now += 50, fixture.CompatibilityTick()
    CompatibilityChecks.Assert(fixture.Requests.Length = 1 && fixture.Requests[1].Hwnd = 12,
        "Only the currently selected stable group member receives a move request")
    CompatibilityChecks.Assert(fixture.CompatibilityMoves = 0 && fixture.Owner.SuccessfulMoves = 0,
        "Submitting a move request does not count as confirmed success")
    fixture.Selected.Monitor := CompatibilityChecks.Monitor(2)
    fixture.Now += 50, fixture.CompatibilityTick()
    CompatibilityChecks.Assert(fixture.CompatibilityMoves = 1 && fixture.Owner.SuccessfulMoves = 1,
        "Verified destination increments compatibility and displayed totals once")
    CompatibilityChecks.Assert(!fixture.Scheduled && !IsObject(fixture.Compatibility) && fixture.NativeCancels = 1,
        "Confirmed success cancels its native transaction and bounded timer")
    fixture.CompatibilityTick()
    CompatibilityChecks.Assert(fixture.Requests.Length = 1 && fixture.CompatibilityMoves = 1,
        "A completed compatibility click never repeats a move or count")
    CompatibilityChecks.Assert(InStr(fixture.Owner.Messages[fixture.Owner.Messages.Length],"32位兼容定位"),
        "Successful feedback explicitly identifies after-show 32-bit compatibility")

    fixture := CompatibilityFixture(false), fixture.Intent.Flags := 7, fixture.Selected.Data.AppId := "Fixture.App"
    fixture.BeginCompatibility(7,2), CompatibilityChecks.Stable(fixture)
    CompatibilityChecks.Assert(fixture.Requests.Length = 1,"Cold shared-host selection accepts its exact visible AppID")

    fixture := CompatibilityFixture(false), fixture.Intent.Flags := 11, fixture.BeginCompatibility(7,2)
    CompatibilityChecks.NoRequest(fixture,"A packaged launch cannot use the executable alone")
    fixture.Selected.Data.AppId := "Other.App"
    CompatibilityChecks.NoRequest(fixture,"A different app sharing a package image cannot move")
    fixture.Selected.Data.AppId := "Fixture.App"
    CompatibilityChecks.Stable(fixture)
    CompatibilityChecks.Assert(fixture.Requests.Length = 1,"An exact packaged window can follow after appearing from the background")
    fixture.Selected.Monitor := CompatibilityChecks.Monitor(2)
    fixture.Now += 50, fixture.CompatibilityTick()
    CompatibilityChecks.Assert(fixture.CompatibilityMoves = 1 && !fixture.Scheduled,
        "A packaged follow finishes only after the selected window reaches the target")
    fixture := CompatibilityFixture(false), fixture.Intent.Flags := 11, fixture.Intent.NativeClaimed := 1
    fixture.Selected.Data.AppId := "Fixture.App", fixture.BeginCompatibility(7,2)
    CompatibilityChecks.NoRequest(fixture,"A native claim receives time to finish before fallback")
    fixture.Valid := false, fixture.CompatibilityTick()
    CompatibilityChecks.Assert(!fixture.Scheduled && !fixture.Requests.Length,"Native completion stops the package fallback")

    fixture := CompatibilityFixture(), fixture.BeginCompatibility(7,2)
    fixture.BeginCompatibility(7,2)
    CompatibilityChecks.Assert(fixture.ScheduleStarts = 1,"Duplicate delivery of one valid serial does not restart its timer")
    fixture.Valid := false, fixture.CompatibilityTick()
    CompatibilityChecks.Assert(!fixture.Scheduled && !fixture.NativeCancels,"New input stops observation without cancelling a replacement native transaction")
    fixture := CompatibilityFixture(), fixture.BeginCompatibility(7,2)
    fixture.Intent.Serial := 8, fixture.CompatibilityTick()
    CompatibilityChecks.Assert(!fixture.Scheduled && !fixture.NativeCancels,"A replacement click serial cannot inherit the previous compatibility operation")
    fixture := CompatibilityFixture(), fixture.BeginCompatibility(7,2)
    fixture.Owner.Enabled := false, fixture.CompatibilityTick()
    CompatibilityChecks.Assert(!fixture.Scheduled && !fixture.Requests.Length,"Pause stops compatibility before any move")
    fixture := CompatibilityFixture(), fixture.BeginCompatibility(7,2)
    fixture.Now := fixture.Intent.Expires, fixture.CompatibilityTick()
    CompatibilityChecks.Assert(!fixture.Scheduled && !fixture.Requests.Length,"Expiry stops the bounded timer")
    fixture := CompatibilityFixture(), fixture.BeginCompatibility(7,2)
    fixture.Cancel()
    CompatibilityChecks.Assert(!fixture.Scheduled && fixture.NativeCancels = 1,"Explicit cancellation clears the compatibility timer before cancelling native work")
    fixture := CompatibilityFixture(), fixture.BeginCompatibility(7,2)
    fixture.CompatibilityTick(), fixture.Now += 50, fixture.CompatibilityTick()
    fixture.CancelAtRead := fixture.IntentReads+2
    fixture.Now += 50, fixture.CompatibilityTick()
    CompatibilityChecks.Assert(!fixture.Scheduled && !fixture.Requests.Length,
        "Native cancellation detected by the immediate pre-move snapshot prevents the request")

    for interruption in ["cancel","pause","stop"] {
        fixture := CompatibilityFixture(), fixture.InterruptAtForeground := 4, fixture.InterruptKind := interruption
        fixture.BeginCompatibility(7,2), CompatibilityChecks.Stable(fixture)
        CompatibilityChecks.Assert(!fixture.Requests.Length && !fixture.Scheduled,
            "An interrupt during final foreground identity reading prevents the resumed move: " . interruption)
    }
    for interruption in ["replace","replace-throw"] {
        fixture := CompatibilityFixture(), fixture.InterruptAtForeground := 4, fixture.InterruptKind := interruption
        fixture.BeginCompatibility(7,2), CompatibilityChecks.Stable(fixture)
        CompatibilityChecks.Assert(!fixture.Requests.Length && fixture.Scheduled && fixture.Compatibility.Serial = 8,
            "An old observation cannot move or clear a replacement click, including exception cleanup: " . interruption)
    }
    fixture := CompatibilityFixture(), fixture.BeginCompatibility(7,2)
    CompatibilityChecks.Stable(fixture)
    fixture.Selected.Monitor := CompatibilityChecks.Monitor(2)
    fixture.ReplaceAtRead := fixture.IntentReads+2
    fixture.Now += 50, fixture.CompatibilityTick()
    CompatibilityChecks.Assert(!fixture.CompatibilityMoves && !fixture.NativeCancels && fixture.Scheduled && fixture.Compatibility.Serial = 8,
        "Replacement during End's intent read cannot cancel, count or stop the newer operation")
    fixture := CompatibilityFixture(), fixture.BeginCompatibility(7,2)
    CompatibilityChecks.Stable(fixture)
    fixture.Selected.Monitor := CompatibilityChecks.Monitor(2)
    fixture.ReplaceDuringCompare := true
    fixture.Now += 50, fixture.CompatibilityTick()
    CompatibilityChecks.Assert(!fixture.CompatibilityMoves && !fixture.NativeCancels && fixture.Scheduled && fixture.Compatibility.Serial = 8,
        "A failed native compare-cancel preserves a newly armed serial and does not count the old move")
    fixture := CompatibilityFixture(), fixture.BeginCompatibility(7,2)
    CompatibilityChecks.Stable(fixture)
    fixture.Selected.Monitor := CompatibilityChecks.Monitor(2)
    fixture.ReplaceNativeOnlyDuringCompare := true
    fixture.Now += 50, fixture.CompatibilityTick()
    CompatibilityChecks.Assert(!fixture.CompatibilityMoves && !fixture.NativeCancels && fixture.Valid && !fixture.Scheduled
        && fixture.BeginCompatibility(8,2),
        "A worker-only replacement makes compare-cancel fail without counting, and its pending message can start normally")
    previousCritical := A_IsCritical
    Critical(23)
    fixture := CompatibilityFixture(), fixture.BeginCompatibility(7,2)
    CompatibilityChecks.Stable(fixture)
    fixture.Selected.Monitor := CompatibilityChecks.Monitor(2)
    fixture.Now += 50, fixture.CompatibilityTick()
    restoredCritical := A_IsCritical
    Critical(previousCritical ? previousCritical : "Off")
    CompatibilityChecks.Assert(fixture.MoveCritical && fixture.CompareCritical && restoredCritical = 23,
        "The short move and compare-cancel sections restore the caller's previous critical interval")

    fixture := CompatibilityFixture(), fixture.BeginCompatibility(7,2)
    CompatibilityChecks.Stable(fixture)
    fixture.Now += 1000, fixture.CompatibilityTick()
    CompatibilityChecks.Assert(!fixture.Scheduled && fixture.CompatibilityMoves = 0 && fixture.Requests.Length = 1,
        "Unconfirmed positioning stops after one request and the one-second confirmation bound")
    fixture := CompatibilityFixture(), fixture.MoveResult := "set-placement-failed:5"
    fixture.BeginCompatibility(7,2), CompatibilityChecks.Stable(fixture)
    CompatibilityChecks.Assert(!fixture.Scheduled && !fixture.CompatibilityMoves,"A failed move clears the timer without counting success")
    fixture := CompatibilityFixture(), fixture.Selected.Monitor := CompatibilityChecks.Monitor(2)
    fixture.BeginCompatibility(7,2), CompatibilityChecks.Stable(fixture)
    CompatibilityChecks.Assert(!fixture.Scheduled && !fixture.Requests.Length && !fixture.CompatibilityMoves,
        "A selected window already on the destination is left in place and is not counted as a move")

    fixture := CompatibilityFixture(), fixture.Intent.Before := 11
    fixture.Intent.Candidates.Push({Hwnd:12,Pid:102})
    fixture.Selected.Monitor := CompatibilityChecks.Monitor(2)
    fixture.BeginCompatibility(7,2)
    CompatibilityChecks.NoRequest(fixture,"The original group member cannot complete a pending selection")
    CompatibilityChecks.Assert(fixture.Scheduled,"A group selection stays live while its previous foreground remains")
    fixture.Selected := CompatibilityChecks.Window(12,102)
    CompatibilityChecks.Stable(fixture)
    CompatibilityChecks.Assert(fixture.Requests.Length = 1 && fixture.Requests[1].Hwnd = 12,
        "The group selection follows the window Windows actually activated")

    fixture := CompatibilityFixture(), fixture.BeginCompatibility(7,2)
    CompatibilityChecks.StopEngine := fixture
    stopCallback := CallbackCreate(ObjBindMethod(CompatibilityChecks,"NativeStop"),,1)
    callbacks.Push(stopCallback), fixture.StopAndWaitFn := stopCallback
    CompatibilityChecks.Assert(fixture.Stop() && CompatibilityChecks.StoppedTimerFirst && !fixture.Handle,
        "Stopping the engine clears compatibility polling before native shutdown or module release")
    fixture := CompatibilityFixture(), fixture.CompatibilityMoves := 2, fixture.EventNumber := 0
    statusCallback := CallbackCreate(ObjBindMethod(CompatibilityChecks,"NativeStatus"),,2)
    callbacks.Push(statusCallback), fixture.StatusFn := statusCallback
    fixture.Poll()
    CompatibilityChecks.Assert(fixture.Owner.SuccessfulMoves = 9,
        "Status polling preserves confirmed compatibility moves while adding native counters")

    intentCallback := CallbackCreate(ObjBindMethod(CompatibilityChecks,"NativeIntent"),,3)
    callbacks.Push(intentCallback)
    decoder := {base:NativeEngine.Prototype,CompatibilityIntentFn:intentCallback}
    decoded := decoder.ReadCompatibilityIntent(7)
    CompatibilityChecks.Assert(decoded.Serial = 7 && decoded.Monitor = 2 && decoded.Released = 900 && decoded.Expires = 9000
        && decoded.NativeClaimed = 1,
        "The real compatibility decoder reads native transaction fields from the agreed ABI offsets")
    CompatibilityChecks.Assert(decoded.Flags = 5 && decoded.Id == "Fixture.App" && decoded.Path == A_AhkPath,
        "The real compatibility decoder preserves launch path and opaque identity")
    CompatibilityChecks.Assert(decoded.Candidates.Length = 2 && decoded.Candidates[2].Hwnd = 12 && decoded.Candidates[2].Pid = 102,
        "The real compatibility decoder reads the HWND/PID candidate stride")
    CompatibilityChecks.Assert(!IsObject(decoder.ReadCompatibilityIntent(8)),"A failed native serial read never returns an invented intent")
    CompatibilityChecks.AbiCount := 33
    CompatibilityChecks.Assert(!IsObject(decoder.ReadCompatibilityIntent(7)),"A malformed over-capacity native candidate count is rejected")

    fixture := CompatibilityFixture(), fixture.Intent.Flags := 17, fixture.BeginCompatibility(7,2)
    CompatibilityChecks.Stable(fixture)
    CompatibilityChecks.Assert(fixture.Requests.Length = 1,"An arbitrary verified 64-bit application has after-show backup")
    fixture := CompatibilityFixture(), fixture.TakeoverAllowed := false, fixture.BeginCompatibility(7,2)
    CompatibilityChecks.NoRequest(fixture,"A failed serial-specific handoff cannot issue a competing move")
    fixture := CompatibilityFixture(), fixture.Intent.Flags := 17, fixture.Intent.Before := 11
    fixture.WindowSnapshot := fixture.Selected, fixture.WindowSnapshot.Minimized := true, fixture.Selected := 0
    fixture.BeginCompatibility(7,2), CompatibilityChecks.Stable(fixture)
    CompatibilityChecks.Assert(fixture.Requests.Length = 1 && fixture.Compatibility.Recovering,
        "An already-active cross-screen click can rescue its exact window when Explorer minimized it without a native hook")
    fixture.WindowSnapshot.Minimized := false, fixture.WindowSnapshot.Monitor := CompatibilityChecks.Monitor(2)
    fixture.Now += 50, fixture.CompatibilityTick()
    CompatibilityChecks.Assert(fixture.CompatibilityMoves = 1,"The rescued window is counted only after it is visibly restored on target")
    fixture := CompatibilityFixture(), fixture.Intent.Before := 11
    fixture.WindowSnapshot := fixture.Selected, fixture.WindowSnapshot.Minimized := true, fixture.Selected := 0
    fixture.BeginCompatibility(7,2), CompatibilityChecks.Stable(fixture)
    CompatibilityChecks.Assert(fixture.Requests.Length = 1 && fixture.Compatibility.Recovering,
        "The same verified cross-screen rescue also works for x86 applications")
    fixture := CompatibilityFixture(), fixture.Intent.Flags := 17, fixture.Intent.Before := 11, fixture.Owner.BringActive := false
    fixture.WindowSnapshot := fixture.Selected, fixture.WindowSnapshot.Minimized := true, fixture.Selected := 0
    fixture.BeginCompatibility(7,2)
    CompatibilityChecks.NoRequest(fixture,"Disabling active-window following preserves Explorer's minimize behavior")
    fixture := CompatibilityFixture(), fixture.Intent.Flags := 19, fixture.Intent.NativeClaimed := 1
    fixture.Selected.Data.AppId := "Fixture.App", fixture.BeginCompatibility(7,2)
    CompatibilityChecks.NoRequest(fixture,"A claimed ordinary/package window gets time to finish natively")
    fixture.Now += 500, fixture.CompatibilityTick()
    CompatibilityChecks.Assert(fixture.Requests.Length = 1,"A native claim that never completes cannot disable backup forever")

    fixture := CompatibilityFixture(), fixture.Intent.Flags := 16, fixture.Intent.Path := ""
    fixture.Selected.Data.Path := "", fixture.Selected.Data.AppId := "Fixture.App"
    fixture.BeginCompatibility(7,2), CompatibilityChecks.Stable(fixture)
    CompatibilityChecks.Assert(fixture.Requests.Length = 1,"A shared application frame with an exact cached HWND/PID/AppID does not require process-path access")
    fixture := CompatibilityFixture(), fixture.Intent.Flags := 16, fixture.Intent.Path := ""
    fixture.Selected.Data.AppId := "Other.App", fixture.BeginCompatibility(7,2)
    CompatibilityChecks.NoRequest(fixture,"A frame whose application identity changed is rejected")

    fixture := CompatibilityFixture(), fixture.BeginCompatibility(7,2), CompatibilityChecks.Stable(fixture)
    plan := CompatibilityPlan(), fixture.Compatibility.MovePlan := plan
    fixture.WindowSnapshot := fixture.Selected, fixture.WindowSnapshot.Minimized := true, fixture.Selected := 0
    fixture.Now += 50, fixture.CompatibilityTick()
    CompatibilityChecks.Assert(plan.Advances=1 && fixture.Requests.Length=1 && fixture.Scheduled && !fixture.CompatibilityMoves,
        "A move's own minimized transition advances only the same HWND/PID and is not counted as success")
    fixture.WindowSnapshot.Monitor := CompatibilityChecks.Monitor(2)
    fixture.Now += 50, fixture.CompatibilityTick()
    CompatibilityChecks.Assert(plan.Advances=2 && !fixture.CompatibilityMoves,
        "A minimized restore rectangle on target is not visible completion")
    fixture.WindowSnapshot.Minimized := false, fixture.Selected := fixture.WindowSnapshot, plan.Result := "complete"
    fixture.Now += 50, fixture.CompatibilityTick()
    CompatibilityChecks.Assert(fixture.CompatibilityMoves=1 && fixture.Requests.Length=1 && !fixture.Scheduled,
        "A staged operation counts once after its visible final state and destination are confirmed")
    for interruption in ["input","pause","timeout","identity","focus","monitor"] {
        fixture := CompatibilityFixture(), fixture.BeginCompatibility(7,2), CompatibilityChecks.Stable(fixture)
        plan := CompatibilityPlan(), fixture.Compatibility.MovePlan := plan
        fixture.WindowSnapshot := fixture.Selected
        switch interruption {
            case "input": fixture.Valid := false
            case "pause": fixture.Owner.Enabled := false
            case "timeout": fixture.Now += 1000
            case "identity": fixture.WindowSnapshot.Data.Pid := 202
            case "focus": fixture.Selected := 0
            case "monitor": fixture.Intent.Monitor := 3
        }
        fixture.Now += 50, fixture.CompatibilityTick()
        CompatibilityChecks.Assert(!plan.Advances && plan.Cancels=1 && !fixture.Scheduled && !fixture.CompatibilityMoves,
            "A staged operation stops before another window request after " . interruption)
    }
    fixture := CompatibilityFixture(), fixture.BeginCompatibility(7,2), CompatibilityChecks.Stable(fixture)
    plan := CompatibilityPlan(), fixture.Compatibility.MovePlan := plan, fixture.WindowSnapshot := fixture.Selected
    fixture.TakeoverAllowed := false, fixture.Now += 50, fixture.CompatibilityTick()
    CompatibilityChecks.Assert(!plan.Advances && fixture.Requests.Length=1,
        "Each later stage requires a fresh serial-specific native handoff")
    fixture := CompatibilityFixture(), fixture.BeginCompatibility(7,2), CompatibilityChecks.Stable(fixture)
    plan := CompatibilityPlan(), fixture.Compatibility.MovePlan := plan, fixture.WindowSnapshot := fixture.Selected
    fixture.ReplaceAtRead := fixture.IntentReads+2, fixture.Now += 50, fixture.CompatibilityTick()
    CompatibilityChecks.Assert(!plan.Advances && plan.Cancels=1 && fixture.Scheduled && fixture.Compatibility.Serial=8,
        "Replacement during a stage's final snapshot cancels its old plan and preserves the new click")

    for excluded in ["Before","Source"] {
        fixture := CompatibilityFixture(false), fixture.Intent.Flags := 32, fixture.Intent.Path := "", fixture.Intent.Id := ""
        fixture.Intent.%excluded% := fixture.Selected.Hwnd, fixture.BeginCompatibility(7,2)
        CompatibilityChecks.NoRequest(fixture,"A shell click cannot move its existing foreground/source window: " . excluded)
    }
    fixture := CompatibilityFixture(false), fixture.Intent.Flags := 32, fixture.Intent.Path := "", fixture.Intent.Id := ""
    fixture.Intent.Before := 20, fixture.Intent.Source := 21
    fixture.BeginCompatibility(7,2), CompatibilityChecks.Stable(fixture)
    CompatibilityChecks.Assert(fixture.Requests.Length = 1,"A different application appearing after an explicit shell launch follows the source screen")
    fixture.Valid := false, fixture.CompatibilityTick()
    CompatibilityChecks.Assert(!fixture.Scheduled,"Any new input cancels the shell-launch backup")

    for scenario in ["new same PID","new exact AppID","new owned dialog","clicked source","old foreground",
        "visible sibling","visible other PID","unrelated PID","same PID different AppID","recycled origin"] {
        fixture := CompatibilityFixture(), fixture.Intent.Flags := NativeEngine.AppLaunchFlag
        fixture.Intent.Before := 31, fixture.Intent.Source := 30
        fixture.Intent.Candidates := [{Hwnd:30,Pid:101},{Hwnd:12,Pid:101},{Hwnd:13,Pid:102}]
        fixture.Selected := CompatibilityChecks.Window(11,101)
        switch scenario {
            case "new exact AppID": fixture.Selected.Data.Pid := 102, fixture.Selected.Data.AppId := "Fixture.App"
            case "new owned dialog": fixture.Selected.Data.Pid := 102, fixture.Selected.Owner := 30
            case "clicked source": fixture.Selected.Hwnd := 30
            case "old foreground": fixture.Selected.Hwnd := 31
            case "visible sibling": fixture.Selected.Hwnd := 12
            case "visible other PID":
                fixture.Selected.Hwnd := 13, fixture.Selected.Data.Pid := 102, fixture.Selected.Data.AppId := "Fixture.App"
            case "unrelated PID": fixture.Selected.Data.Pid := 102
            case "same PID different AppID": fixture.Selected.Data.AppId := "Other.App"
            case "recycled origin":
                fixture.AppOrigin.Pid := 103, fixture.Selected.Data.Pid := 102, fixture.Selected.Data.AppId := "Fixture.App"
        }
        CompatibilityChecks.Assert(fixture.BeginCompatibility(7,2) && !fixture.Owner.Messages.Length,
            "A potential application click is silent while waiting")
        CompatibilityChecks.Stable(fixture)
        CompatibilityChecks.Assert(fixture.Requests.Length = (SubStr(scenario,1,3) = "new"),
            "In-app launch selection: " . scenario)
        if !fixture.Requests.Length {
            fixture.Now := fixture.Intent.Expires, fixture.CompatibilityTick()
            CompatibilityChecks.Assert(!fixture.Owner.Messages.Length && !fixture.Owner.Logs.Length,
                "A normal application click expires without status or log noise")
        }
    }

    fixture := CompatibilityFixture(), fixture.Intent.Flags := NativeEngine.JumpListFlag | 1
    fixture.Intent.Before := 21, fixture.Intent.Source := 20
    fixture.Selected := CompatibilityChecks.Window(12,101)
    fixture.BeginCompatibility(7,2), CompatibilityChecks.Stable(fixture)
    CompatibilityChecks.Assert(fixture.Requests.Length = 1 && fixture.Requests[1].Hwnd = 12,
        "Opening a recent folder can follow a new window absent from the saved taskbar group")
    for rejected in ["before","other app","other installation","shared executable without AppID"] {
        fixture := CompatibilityFixture(), fixture.Intent.Flags := NativeEngine.JumpListFlag | 1
        fixture.Selected.Data.AppId := "Fixture.App"
        switch rejected {
            case "before": fixture.Intent.Before := fixture.Selected.Hwnd
            case "other app": fixture.Selected.Data.AppId := "Other.App"
            case "other installation": fixture.Selected.Data.Path := A_Temp . "\other.exe"
            case "shared executable without AppID": fixture.Intent.Flags |= 2, fixture.Selected.Data.AppId := ""
        }
        fixture.BeginCompatibility(7,2)
        CompatibilityChecks.NoRequest(fixture,"Jump-list selection rejects " . rejected)
    }
    fixture := CompatibilityFixture(false), fixture.Intent.Flags := NativeEngine.JumpListFlag
    fixture.Intent.Path := "", fixture.Selected.Data.AppId := fixture.Intent.Id
    fixture.BeginCompatibility(7,2), CompatibilityChecks.Stable(fixture)
    CompatibilityChecks.Assert(fixture.Requests.Length = 1,"A matching explicit AppID can verify the selected window without a known path")
    fixture := CompatibilityFixture(false), fixture.Intent.Flags := NativeEngine.JumpListFlag | 1, fixture.Intent.NativeClaimed := 1
    fixture.BeginCompatibility(7,2)
    CompatibilityChecks.NoRequest(fixture,"An in-process jump-list claim is given time to finish")
    fixture.Now += 500, fixture.CompatibilityTick()
    CompatibilityChecks.Assert(fixture.Requests.Length = 1,"The jump-list backup can recover an incomplete native move")

    candidates := [{Hwnd:1,Pid:101,Title:"Browser"},{Hwnd:2,Pid:102,Title:"Reader"}]
    hover := NativeEngine.HoverMatches(candidates,["Reader"])
    CompatibilityChecks.Assert(hover.Length = 1 && hover[1].Hwnd = 2,"The current thumbnail title resolves the reader even with a stale browser context")
    CompatibilityChecks.Assert(NativeEngine.HoverMatches([candidates[1]],["Reader"]).Length = 0,
        "A single cached candidate never bypasses thumbnail-title verification")
    hover := NativeEngine.HoverMatches([candidates[2],{Hwnd:3,Pid:103,Title:"Reader"}],["Reader"])
    CompatibilityChecks.Assert(hover.Length = 2,"Duplicate titles remain ambiguous and cannot produce a custom preview")
    CompatibilityChecks.Assert(NativeEngine.HoverMatches([{Hwnd:4,Pid:104,Title:""}],[""]).Length = 0,"Empty names cannot match a thumbnail")

    FileAppend("PASS compatibility-follow assertions=" . CompatibilityChecks.Count . "`n", "*", "UTF-8")
} catch as e {
    FileAppend("FAIL " . e.Message . "; line=" . e.Line . "`n", "*", "UTF-8")
    exitCode := 1
} finally {
    for callback in callbacks
        CallbackFree(callback)
}
ExitApp(IsSet(exitCode) ? exitCode : 0)
