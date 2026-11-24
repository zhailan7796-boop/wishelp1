#Requires AutoHotkey v2.0
#NoTrayIcon
#SingleInstance Off
; Helper process for AppLaunchToolWindow.ahk (started with the 32-bit runtime
; when it exists, like 芒果TV.exe). It behaves like 芒果TV: its main window
; waits for message 0x8101, then shows a frameless player window of class
; Qt5QWindowToolSaveBits with WS_EX_TOOLWINDOW, owned by a hidden window of
; this process. With "hide" the player hides itself as soon as it is minimized,
; as the real player does. Every minimize is counted in the player's title
; ("... player minimized=N") so the test can read it from outside.
; Only this process's own windows are created; it exits when the main window
; closes, or after 30 seconds at the latest.
; Arguments: title x y w h hide|keep
title := A_Args[1], px := Integer(A_Args[2]), py := Integer(A_Args[3])
pw := Integer(A_Args[4]), ph := Integer(A_Args[5])
hideOnMinimize := A_Args.Length >= 6 && A_Args[6] = "hide"
minimizedCount := 0, player := 0, owner := 0
SetTimer(() => ExitApp(), -30000)

FixtureProc(hwnd,msg,wParam,lParam) {
    global minimizedCount
    if msg = 0x0005 && wParam = 1 && hwnd = player { ; WM_SIZE / SIZE_MINIMIZED
        minimizedCount += 1
        DllCall("user32\SetWindowTextW","ptr",hwnd,"wstr",title . " player minimized=" . minimizedCount)
        if hideOnMinimize
            DllCall("user32\ShowWindow","ptr",hwnd,"int",0) ; SW_HIDE
    }
    return DllCall("user32\DefWindowProcW","ptr",hwnd,"uint",msg,"uptr",wParam,"ptr",lParam,"ptr")
}
CreatePlayerWindow(ex,style,x,y,w,h,ownerHwnd,text) {
    static atom := 0, className := "Qt5QWindowToolSaveBits"
    module := DllCall("kernel32\GetModuleHandleW","ptr",0,"ptr")
    if !atom {
        size := A_PtrSize = 8 ? 80 : 48
        wc := Buffer(size,0)
        NumPut("uint",size,"uint",0x0803,wc,0) ; CS_SAVEBITS | CS_HREDRAW | CS_VREDRAW
        NumPut("ptr",CallbackCreate(FixtureProc,,4),wc,8)
        NumPut("ptr",module,wc,8 + A_PtrSize + 8)                                ; hInstance
        NumPut("ptr",DllCall("user32\LoadCursorW","ptr",0,"ptr",32512,"ptr"),wc,8 + 3 * A_PtrSize + 8) ; hCursor
        NumPut("ptr",DllCall("gdi32\GetStockObject","int",0,"ptr"),wc,8 + 4 * A_PtrSize + 8)           ; hbrBackground
        NumPut("ptr",StrPtr(className),wc,8 + 6 * A_PtrSize + 8)                ; lpszClassName
        atom := DllCall("user32\RegisterClassExW","ptr",wc,"ushort")
        if !atom
            ExitApp(3)
    }
    return DllCall("user32\CreateWindowExW","uint",ex,"wstr",className,"wstr",text,"uint",style,
        "int",x,"int",y,"int",w,"int",h,"ptr",ownerHwnd,"ptr",0,"ptr",module,"ptr",0,"ptr")
}
ShowPlayer(wParam,lParam,msg,hwnd) {
    global player, owner
    if player
        return 1
    owner := CreatePlayerWindow(0,0x86000000,px,py,10,10,0,title . " owner")
    player := CreatePlayerWindow(0x80,0x86000000,px,py,pw,ph,owner,title . " player minimized=0")
    if !owner || !player
        ExitApp(4)
    DllCall("user32\ShowWindow","ptr",player,"int",5)
    ; This process owns the foreground (its main window is active), so it may
    ; hand the foreground to its own new window, as a real program does.
    DllCall("user32\SetForegroundWindow","ptr",player)
    return 1
}
main := Gui("-DPIScale",title . " main")
main.AddText(,"Automated check window (simulated video app); it closes by itself.")
main.OnEvent("Close",(*) => ExitApp())
OnMessage(0x8101,ShowPlayer)
main.Show("x" . (px - 80) . " y" . (py - 50) . " w700 h420")
