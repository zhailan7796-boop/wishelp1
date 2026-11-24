; 随屏链接 - optional per-user URL handler for links opened from other apps.
; Windows lets only the user choose the default browser. This file registers a
; candidate under HKCU, records which real browser receives the links, and opens
; the matching Settings pages. It never writes UserChoice and never edits the
; browser's own registration, so undoing it is: pick the browser again in
; Settings, then delete the three HKCU keys written by Register().
class LinkFollow {
    static ProgId := "TaskbarFollow.Link"
    static Client := "TaskbarFollow.Link"
    static Name := "随屏链接"
    static Section := "LinkFollow"
    static Magic := 0x54424635
    static Title := "随屏 · 链接随屏"

    static Runtime(root) => root . "\runtime\AutoHotkey64.exe"
    static Script(root) => root . "\LinkOpen.ahk"
    static Icon(root) => root . "\launcher\TaskbarFollow.ico"
    ; Same contract as Chromium's own handler: everything after the marker is
    ; one URL, so a link can never add switches to this or the browser's line.
    static Command(root) => '"' . this.Runtime(root) . '" "' . this.Script(root) . '" --single-argument %1'

    static RegisteredCommand() {
        try {
            return RegRead("HKCU\Software\Classes\" . this.ProgId . "\shell\open\command")
        } catch {
            return ""
        }
    }
    static Registered() => this.RegisteredCommand() != ""
    static RegisteredFor(root) => this.RegisteredCommand() = this.Command(root)
    static UserChoice(scheme) {
        base := "HKCU\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\" . scheme
        for key in ["\UserChoiceLatest","\UserChoice"] {
            try {
                progId := RegRead(base . key,"ProgId")
                if progId != ""
                    return progId
            }
        }
        return ""
    }
    static IsDefault() => this.UserChoice("https") = this.ProgId && this.UserChoice("http") = this.ProgId
    static Active(root) => this.IsDefault() && this.RegisteredFor(root)

    static ProgIdCommand(progId) {
        if progId = "" || progId = this.ProgId
            return ""
        for root in ["HKCU\Software\Classes\","HKLM\Software\Classes\"] {
            try {
                command := RegRead(root . progId . "\shell\open\command")
                if command != ""
                    return command
            }
        }
        return ""
    }
    static SplitCommand(command,&exe,&args) {
        exe := "", args := ""
        command := Trim(command)
        if SubStr(command,1,1) = '"' {
            close := InStr(command,'"',,2)
            if !close
                return false
            exe := SubStr(command,2,close-2), args := Trim(SubStr(command,close+1))
        } else if RegExMatch(command,"i)^(.+?\.exe)(?=\s|$)(.*)$",&match) {
            exe := match[1], args := Trim(match[2])
        } else {
            return false
        }
        exe := LinkFollow.ExpandEnvironment(exe)
        return LinkFollow.UsableBrowser(exe)
    }
    static ExpandEnvironment(text) {
        chars := DllCall("kernel32\ExpandEnvironmentStringsW","wstr",text,"ptr",0,"uint",0,"uint")
        if !chars
            return text
        expanded := Buffer(chars*2,0)
        DllCall("kernel32\ExpandEnvironmentStringsW","wstr",text,"ptr",expanded,"uint",chars,"uint")
        return StrGet(expanded)
    }
    ; A browser is a real executable that is not this tool's own runtime. That
    ; rule is what makes a link loop (handler -> handler) impossible.
    static UsableBrowser(path) {
        if !RegExMatch(path,"i)^[a-z]:\\.+\.exe$")
            return false
        attributes := FileExist(path)
        if attributes = "" || InStr(attributes,"D")
            return false
        SplitPath(path,&exe)
        return InStr(StrLower(exe),"autohotkey") != 1
    }
    ; {Path,Args} of the browser that really opens links: the recorded one, the
    ; previous https handler if it is not this tool, then Chrome / Edge.
    static Browser(config) {
        path := IniRead(config,this.Section,"Browser","")
        if path != "" && this.UsableBrowser(path)
            return {Path:path,Args:IniRead(config,this.Section,"BrowserArgs","")}
        command := this.ProgIdCommand(this.UserChoice("https"))
        if command != "" && this.SplitCommand(command,&exe,&args)
            return {Path:exe,Args:args}
        for name in ["chrome.exe","msedge.exe"] {
            for hive in ["HKCU","HKLM"] {
                try {
                    candidate := Trim(RegRead(hive . "\Software\Microsoft\Windows\CurrentVersion\App Paths\" . name),'"')
                    if this.UsableBrowser(candidate)
                        return {Path:candidate,Args:"--single-argument %1"}
                }
            }
        }
        return 0
    }
    static Remember(config) {
        progId := this.UserChoice("https")
        command := this.ProgIdCommand(progId)
        if command != "" && this.SplitCommand(command,&exe,&args) {
            browser := {Path:exe,Args:args}
            IniWrite(progId,config,this.Section,"PreviousProgId")
        } else
            browser := this.Browser(config)
        if !IsObject(browser)
            return 0
        IniWrite(browser.Path,config,this.Section,"Browser")
        IniWrite(browser.Args,config,this.Section,"BrowserArgs")
        return browser
    }

    static IsChromium(path) {
        static names := Map("chrome.exe",1,"msedge.exe",1,"brave.exe",1,"vivaldi.exe",1,"chromium.exe",1,"opera.exe",1)
        SplitPath(path,&exe)
        return names.Has(StrLower(exe))
    }
    static NewWindowFlag(path) {
        if this.IsChromium(path)
            return "--new-window"
        SplitPath(path,&exe)
        return StrLower(exe) = "firefox.exe" ? "-new-window" : ""
    }
    static CleanUrl(url) {
        url := RegExReplace(Trim(url," `t`r`n"),"[\x00-\x1F]","")
        url := StrReplace(url,'"',"%22")
        ; A trailing backslash would escape the closing quote of "%1" templates.
        if SubStr(url,-1) = "\"
            url := SubStr(url,1,StrLen(url)-1) . "%5C"
        return url
    }
    ; Built only from the browser's own registered template, never by handing
    ; the URL back to the shell, so the link cannot return to this handler.
    static CommandLine(browser,url,newWindow := false) {
        url := this.CleanUrl(url)
        if url = ""
            return '"' . browser.Path . '"'
        args := StrReplace(browser.Args,"%L","%1")
        if args = ""
            args := this.IsChromium(browser.Path) ? "--single-argument %1" : '"%1"'
        if newWindow {
            flag := this.NewWindowFlag(browser.Path)
            if flag = "-new-window"
                args := '-new-window "%1"' ; Firefox's -osint form accepts only -url
            else if flag != ""
                args := flag . " " . args
        }
        if InStr(args,"--single-argument %1")
            line := StrReplace(args,"%1",url)
        else if InStr(args,'"%1"')
            line := StrReplace(args,"%1",url)
        else if InStr(args,"%1")
            line := StrReplace(args,"%1",StrReplace(url," ","%20"))
        else
            line := Trim(args . ' "' . url . '"')
        return '"' . browser.Path . '" ' . line
    }

    static Register(root) {
        command := this.Command(root), icon := this.Icon(root) . ",0"
        classes := "HKCU\Software\Classes\" . this.ProgId
        RegWrite(this.Name . " 网页链接","REG_SZ",classes)
        RegWrite("","REG_SZ",classes,"URL Protocol")
        RegWrite(this.Name,"REG_SZ",classes,"FriendlyTypeName")
        RegWrite(icon,"REG_SZ",classes . "\DefaultIcon")
        RegWrite(this.Name,"REG_SZ",classes . "\Application","ApplicationName")
        RegWrite(icon,"REG_SZ",classes . "\Application","ApplicationIcon")
        RegWrite(command,"REG_SZ",classes . "\shell\open\command")
        client := "HKCU\Software\Clients\StartMenuInternet\" . this.Client
        RegWrite(this.Name,"REG_SZ",client)
        RegWrite(icon,"REG_SZ",client . "\DefaultIcon")
        RegWrite('"' . this.Runtime(root) . '" "' . this.Script(root) . '"',"REG_SZ",client . "\shell\open\command")
        capabilities := client . "\Capabilities"
        RegWrite(this.Name,"REG_SZ",capabilities,"ApplicationName")
        RegWrite(icon,"REG_SZ",capabilities,"ApplicationIcon")
        RegWrite("随屏：应用里打开的网页链接，在你点击的那块屏幕用原来的浏览器打开。","REG_SZ",capabilities,"ApplicationDescription")
        RegWrite(this.Client,"REG_SZ",capabilities . "\Startmenu","StartMenuInternet")
        for scheme in ["http","https"]
            RegWrite(this.ProgId,"REG_SZ",capabilities . "\URLAssociations",scheme)
        RegWrite("Software\Clients\StartMenuInternet\" . this.Client . "\Capabilities","REG_SZ",
            "HKCU\Software\RegisteredApplications",this.Client)
        DllCall("shell32\SHChangeNotify","int",0x08000000,"uint",0,"ptr",0,"ptr",0) ; SHCNE_ASSOCCHANGED
    }
    static Unregister() {
        for key in ["HKCU\Software\Classes\" . this.ProgId,"HKCU\Software\Clients\StartMenuInternet\" . this.Client] {
            try RegDeleteKey(key)
        }
        try RegDelete("HKCU\Software\RegisteredApplications",this.Client)
        DllCall("shell32\SHChangeNotify","int",0x08000000,"uint",0,"ptr",0,"ptr",0)
    }

    static EncodeQuery(text) {
        encoded := "", bytes := Buffer(StrPut(text,"UTF-8"),0)
        StrPut(text,bytes,"UTF-8")
        Loop bytes.Size - 1 {
            byte := NumGet(bytes,A_Index-1,"uchar")
            encoded .= (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
                || byte = 0x2D || byte = 0x2E || byte = 0x5F ? Chr(byte) : Format("%{:02X}",byte)
        }
        return encoded
    }
    static OpenSettings(query := "") {
        try {
            Run("ms-settings:defaultapps" . (query != "" ? "?" . query : ""))
        } catch {
            try Run("ms-settings:defaultapps")
        }
    }
    static OpenOwnSettings() => this.OpenSettings("registeredAppUser=" . this.EncodeQuery(this.Client))
    ; Settings page of the browser that handled links before (e.g. Google Chrome).
    static OpenBrowserSettings(config) {
        progId := IniRead(config,this.Section,"PreviousProgId","")
        if progId != "" && progId != this.ProgId {
            for hive in ["HKCU","HKLM"] {
                try {
                    Loop Reg hive . "\Software\RegisteredApplications" {
                        name := A_LoopRegName
                        if name = this.Client
                            continue
                        try {
                            if RegRead(hive . "\" . RegRead() . "\URLAssociations","https") = progId {
                                this.OpenSettings((hive = "HKCU" ? "registeredAppUser=" : "registeredAppMachine=") . this.EncodeQuery(name))
                                return true
                            }
                        }
                    }
                }
            }
        }
        this.OpenSettings()
        return false
    }

    static Install(config,root) {
        if !FileExist(this.Script(root)) || !FileExist(this.Runtime(root))
            throw Error("缺少 LinkOpen.ahk 或 runtime\AutoHotkey64.exe，请保留完整的随屏文件夹。")
        browser := this.Remember(config)
        if !IsObject(browser)
            throw Error("没有找到可用的浏览器（Chrome 或 Edge）。")
        this.Register(root)
        IniWrite("1",config,this.Section,"Enabled")
        return browser
    }
    static BrowserName(config) {
        browser := this.Browser(config)
        if !IsObject(browser)
            return "原来的浏览器"
        SplitPath(browser.Path,,,,&name)
        return name
    }
    static SetupDialog(config,root) {
        if this.Active(root) {
            answer := MsgBox("「链接随屏」已开启：Windows 的默认浏览器是「随屏链接」，它再用 " . this.BrowserName(config)
                . " 打开网页。`n`n要撤销吗？点「是」会带你把默认浏览器改回原来的浏览器，并删除随屏链接的登记。",this.Title,"YesNo Iconi")
            return answer = "Yes" ? this.UndoDialog(config) : false
        }
        answer := MsgBox("开启后：在飞书等应用里点网页链接，会在你点击的那块屏幕打开。`n"
            . "  · 那块屏幕上已有浏览器窗口 → 开成那个窗口的新标签；`n"
            . "  · 没有 → 在那块屏幕新开一个浏览器窗口。`n"
            . "浏览器本身不换，仍然用原来的（例如 Chrome）。`n`n"
            . "需要两步：`n"
            . "  1. 随屏把「随屏链接」登记为可选浏览器（只写当前用户注册表，不改 Chrome）；`n"
            . "  2. 接着会打开 Windows 设置，请在「随屏链接」页面点顶部的「设为默认值」（或把 HTTP、HTTPS 都选成「随屏链接」）。`n`n"
            . "随时可以撤销：托盘菜单再点这一项，或双击文件夹里的「撤销链接随屏.cmd」。`n`n点「确定」开始。",this.Title,"OKCancel Iconi")
        if answer != "OK"
            return false
        try browser := this.Install(config,root)
        catch as failure {
            MsgBox("没有完成设置：`n" . failure.Message . "`n`n没有改动默认浏览器。",this.Title,"Iconx")
            return false
        }
        SplitPath(browser.Path,,,,&name)
        this.OpenOwnSettings()
        MsgBox("第 1 步已完成：链接会交给 " . name . " 打开。`n`n"
            . "第 2 步：在刚打开的 Windows 设置里，找到「随屏链接」，点「设为默认值」（或把 HTTP、HTTPS 都改成「随屏链接」）。`n"
            . "如果设置页没有直接定位，请在「默认应用」里搜索“随屏链接”。`n`n"
            . "改好后，从飞书点一个云文档试试。",this.Title,"Iconi")
        return true
    }
    static UndoDialog(config) {
        answer := MsgBox("撤销「链接随屏」：`n"
            . "  1. 随屏会打开 Windows 设置，请把默认浏览器改回原来的浏览器（例如 Google Chrome，点「设为默认值」）；`n"
            . "  2. 改好后回到这里点「确定」，随屏会删除「随屏链接」的登记。`n`n"
            . "撤销后，链接恢复由浏览器直接打开（窗口位置由浏览器自己决定）。",this.Title,"OKCancel Icon?")
        if answer != "OK"
            return false
        if this.IsDefault() {
            this.OpenBrowserSettings(config)
            MsgBox("请在刚打开的设置页里把默认浏览器改回原来的浏览器，然后点「确定」。",this.Title,"Iconi")
        }
        if this.IsDefault() {
            answer := MsgBox("Windows 的默认浏览器看起来仍是「随屏链接」。`n`n仍然删除登记吗？删除后，下次点链接时 Windows 会请你重新选择浏览器（选 Chrome 即可）。",
                this.Title,"YesNo Icon!")
            if answer != "Yes"
                return false
        }
        this.Unregister()
        try IniWrite("0",config,this.Section,"Enabled")
        MsgBox("已撤销：「随屏链接」的登记已删除，链接恢复由浏览器直接打开。",this.Title,"Iconi")
        return true
    }
}
