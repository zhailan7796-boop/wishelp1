#Requires AutoHotkey v2.0 64-bit
#NoTrayIcon
#Include ..\lib\Native.ahk
#Include ..\lib\Instance.ahk
DetectHiddenWindows(true)
SplitPath(A_ScriptDir, , &root)
background := A_Args.Length = 1 && A_Args[1] = "--background"
if A_Args.Length && !background {
    FileAppend("FAIL supported option: --background`n", "*", "UTF-8")
    ExitApp(1)
}
prefix := StrLower(root . "\TaskbarFollow.ahk - AutoHotkey")
try {
    for hwnd in WinGetList("ahk_class AutoHotkey") {
        if SubStr(StrLower(Desktop.Title(hwnd)), 1, StrLen(prefix)) != prefix
            continue
        if DllCall("user32\GetPropW", "ptr", hwnd, "wstr", "TaskbarFollow.TestOnly", "ptr")
            continue
        if DllCall("user32\GetPropW", "ptr", hwnd, "wstr", "TaskbarFollow.InstanceMarker", "ptr") != FollowInstance.Magic
            continue
        pid := Desktop.Pid(hwnd)
        if !DllCall("user32\PostMessageW", "ptr", hwnd, "uint", 0x111, "uptr", 65405, "ptr", 0)
            throw Error("Could not request graceful exit: " . A_LastError)
        deadline := Desktop.Tick() + 5000
        while DllCall("user32\IsWindow", "ptr", hwnd) && Desktop.Pid(hwnd) = pid {
            if Desktop.Tick() >= deadline
                throw Error("Existing engine did not exit gracefully")
            Sleep(50)
        }
    }
    if background
        Run('"' . root . '\runtime\AutoHotkey64.exe" "' . root . '\TaskbarFollow.ahk" --background', root, "Hide")
    else
        Run('"' . root . '\Start.exe"', root, "Hide")
    FileAppend("PASS graceful engine restart on the input desktop; background=" . background . "`n", "*", "UTF-8")
    ExitApp(0)
} catch as e {
    FileAppend("FAIL " . e.Message . "`n", "*", "UTF-8")
    ExitApp(1)
}
