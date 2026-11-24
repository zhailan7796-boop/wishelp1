#Requires AutoHotkey v2.0 64-bit
#NoTrayIcon
#SingleInstance Off
#Include ..\lib\LinkFollow.ahk

; Set up, undo or inspect 随屏链接 without the tray menu.
;   runtime\AutoHotkey64.exe tools\Configure-LinkFollow.ahk [setup|quick|uninstall|status]
; "uninstall" is what 撤销链接随屏.cmd runs. "quick" is used by 一键生效.cmd:
; no dialogs, it registers 随屏链接, opens its Windows Settings page and prints
; one line (ALREADY / OK / FAIL) for the console. Every change only touches the
; current user's registry keys listed in lib\LinkFollow.ahk and settings.ini.
SplitPath(A_ScriptDir,,&root)
config := root . "\settings.ini"
mode := A_Args.Length ? StrLower(A_Args[1]) : "setup"
if mode = "quick" {
    try {
        if LinkFollow.Active(root) {
            FileAppend("ALREADY browser=" . LinkFollow.BrowserName(config) . "`n","*","UTF-8")
            ExitApp(0)
        }
        browser := LinkFollow.Install(config,root)
        SplitPath(browser.Path,,,,&name)
        if !LinkFollow.RegisteredFor(root)
            throw Error("registration was not written")
        LinkFollow.OpenOwnSettings()
        FileAppend("OK browser=" . name . "`n","*","UTF-8")
        ExitApp(0)
    } catch as failure {
        FileAppend("FAIL " . failure.Message . "`n","*","UTF-8")
        ExitApp(1)
    }
}
try {
    switch mode {
        case "uninstall", "undo":
            if !LinkFollow.Registered() && !LinkFollow.IsDefault()
                MsgBox("「随屏链接」没有登记，无需撤销。链接由浏览器直接打开。",LinkFollow.Title,"Iconi")
            else
                LinkFollow.UndoDialog(config)
        case "status":
            MsgBox("登记：" . (LinkFollow.Registered() ? (LinkFollow.RegisteredFor(root) ? "已登记（本文件夹）" : "已登记（其他文件夹：" . LinkFollow.RegisteredCommand() . "）") : "未登记")
                . "`n默认浏览器（https）：" . (LinkFollow.UserChoice("https") = "" ? "未知" : LinkFollow.UserChoice("https"))
                . "`n实际打开链接的浏览器：" . LinkFollow.BrowserName(config),LinkFollow.Title,"Iconi")
        default:
            LinkFollow.SetupDialog(config,root)
    }
} catch as failure {
    MsgBox("操作没有完成：`n" . failure.Message,LinkFollow.Title,"Iconx")
    ExitApp(1)
}
ExitApp(0)
