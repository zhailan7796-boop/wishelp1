#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
#Include ..\lib\Native.ahk
if A_Args.Length != 1
    ExitApp(1)
Desktop.Physical()
fixture := Gui("+ToolWindow",A_Args[1])
fixture.AddText(,"Owned cross-process window movement fixture.")
fixture.OnEvent("Close",(*) => ExitApp())
fixture.Show("NA w640 h400")
