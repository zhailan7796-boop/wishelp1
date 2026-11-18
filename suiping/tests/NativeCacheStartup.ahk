#Requires AutoHotkey v2.0 64-bit
#NoTrayIcon
#Include ..\TaskbarFollow.ahk
#Include ..\lib\UIA.ahk

class CacheFixture {
    Published := [], Invalidated := 0, DuringPublish := 0
    Publish(rows,epoch) {
        this.Published.Push({Rows:rows,Epoch:epoch})
        onPublish := this.DuringPublish, this.DuringPublish := 0
        if IsObject(onPublish)
            onPublish()
    }
    InvalidateCache() => this.Invalidated += 1
    static Reply(app,epoch,rows) {
        text := epoch . "`n" . rows
        payload := Buffer((StrLen(text)+1)*2,0)
        StrPut(text,payload)
        message := Buffer(A_PtrSize*3,0)
        NumPut("uptr",0x54424633,message,0)
        NumPut("uint",payload.Size,message,A_PtrSize)
        NumPut("ptr",payload.Ptr,message,A_PtrSize*2)
        return app.HelperReply(app.HelperHwnd,message)
    }
    static Check(condition,label) {
        if !condition
            throw Error(label)
    }
    static Bar(hwnd,pid,rect,at,rows := "") => {Hwnd:hwnd,Pid:pid,Rect:rect,At:at,Rows:rows}
}

try {
    app := TaskbarFollow(true)
    app.NativeMode := true, app.HelperReady := true, app.HelperHwnd := 1
    app.Native := native := CacheFixture()
    firstEpoch := app.NativeCacheEpoch
    CacheFixture.Check(CacheFixture.Reply(app,firstEpoch,"startup"),"Received the first scan")
    CacheFixture.Check(native.Published.Length = 0 && app.NativeRows.Rows = "startup","Preserved pre-mapping rows")
    app.LoadIdentity()
    CacheFixture.Check(native.Published.Length = 1 && native.Published[1].Rows = "startup","Published when mappings became ready")

    CacheFixture.Reply(app,firstEpoch,"refresh")
    native.DuringPublish := () => CacheFixture.Reply(app,firstEpoch,"trailing")
    app.PublishNativeCache()
    deadline := Desktop.Tick()+1000
    while native.Published.Length < 3 && Desktop.Tick() < deadline
        Sleep(15)
    CacheFixture.Check(native.Published.Length = 3 && native.Published[3].Rows = "trailing","Published a scan received during an active publish")

    CacheFixture.Reply(app,firstEpoch,"queued old layout")
    app.InvalidateNativeCache()
    app.PublishNativeCache()
    CacheFixture.Check(native.Invalidated = 1 && native.Published.Length = 3,"Dropped queued geometry when invalidating the layout")
    CacheFixture.Check(!CacheFixture.Reply(app,firstEpoch,"in-flight old layout"),"Rejected an old scan after invalidation")
    CacheFixture.Reply(app,app.NativeCacheEpoch,"new layout")
    app.PublishNativeCache()
    CacheFixture.Check(native.Published.Length = 4 && native.Published[4].Rows = "new layout","Published only the current layout")

    retention := TaskbarScanRetention(), primaryRect := ScreenRect(0,1000,1800,1040), secondaryRect := ScreenRect(-2200,880,0,920)
    primary := (at,rows := "") => CacheFixture.Bar(10,8,primaryRect,at,rows)
    secondary := (at,rows := "") => CacheFixture.Bar(20,8,secondaryRect,at,rows)
    CacheFixture.Check(retention.Merge(0,[primary(1000,"P1"),secondary(1000,"S1")],1000) = "P1S1","Accepted two fresh taskbars")
    CacheFixture.Check(retention.Merge(0,[primary(1750),secondary(1750,"S2")],1750) = "P1S2","Kept the primary through one empty scan while replacing the secondary")
    CacheFixture.Check(retention.Merge(0,[primary(2500),secondary(2500,"S3")],2500) = "S3","Dropped the primary on the second empty scan")
    CacheFixture.Check(retention.Merge(0,[primary(3250,"P4"),secondary(3250,"S4")],3250) = "P4S4","Preferred a recovered scan")
    moved := CacheFixture.Bar(10,8,ScreenRect(1,1000,1801,1040),3900)
    newProcess := CacheFixture.Bar(20,9,secondaryRect,3900)
    CacheFixture.Check(retention.Merge(0,[moved,newProcess],3900) = "","Rejected saved rows after a rectangle or owner change")
    retention.Merge(0,[primary(4000,"P5")],4000)
    CacheFixture.Check(retention.Merge(1,[primary(4100)],4100) = "","Rejected saved rows from an old epoch")
    retention.Merge(1,[primary(4200,"P6")],4200)
    CacheFixture.Check(retention.Merge(1,[primary(5100)],5100) = "","Rejected saved rows after a delayed refresh")

    FileAppend("startup cache queue, epoch invalidation, and one-scan taskbar retention PASS`n","*","UTF-8")
    ExitApp(0)
} catch as failure {
    FileAppend("native cache startup FAIL: " . failure.Message . " (line " . failure.Line . ")`n","*","UTF-8")
    ExitApp(1)
}
