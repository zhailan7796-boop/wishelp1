#Requires AutoHotkey v2.0 64-bit
#NoTrayIcon
#Include ..\lib\Native.ahk
Desktop.Physical()
ids := WindowIdentity()
for hwnd in WinGetList() {
    if Desktop.IsShell(hwnd)
        continue
    data := ids.Get(hwnd)
    if data.Exe = "AutoHotkey64.exe"
        continue
    p := Desktop.Placement(hwnd)
    rect := IsObject(p) ? ScreenRect.FromBuffer(p, 28) : ScreenRect(0,0,0,0)
    ex := DllCall("user32\GetWindowLongPtrW", "ptr", hwnd, "int", -20, "ptr")
    owner := DllCall("user32\GetWindow", "ptr", hwnd, "uint", 4, "ptr")
    FileAppend("exe=" . data.Exe . " appid=" . data.AppId . " eligible=" . Desktop.Eligible(hwnd)
        . " owner=" . owner . " ex=" . Format("{:X}", ex) . " normal=" . rect.W . "x" . rect.H
        . " cls=" . Desktop.Class(hwnd) . "`n", "*", "UTF-8")
}
ExitApp()
