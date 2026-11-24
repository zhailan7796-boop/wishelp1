#Requires AutoHotkey v2.0 64-bit
#NoTrayIcon
#Warn VarUnset, StdOut
#Include ..\lib\LinkFollow.ahk

; Pure checks only: no registry writes, no Settings pages, no browser start.
class LinkChecks {
    static Count := 0
    static Assert(value,label) {
        if !value
            throw Error(label)
        this.Count += 1
    }
}
try {
    chrome := {Path:"C:\Program Files\Google\Chrome\Application\chrome.exe",Args:"--single-argument %1"}
    url := "https://example.feishu.cn/docx/AbC?from=im&x=1"
    LinkChecks.Assert(LinkFollow.CommandLine(chrome,url) == '"' . chrome.Path . '" --single-argument ' . url,
        "Chromium receives the URL verbatim after its own --single-argument marker")
    LinkChecks.Assert(LinkFollow.CommandLine(chrome,url,true) == '"' . chrome.Path . '" --new-window --single-argument ' . url,
        "A new Chromium window is requested before the single-argument marker")
    LinkChecks.Assert(LinkFollow.CommandLine(chrome,'https://a/b"c d') == '"' . chrome.Path . '" --single-argument https://a/b%22c d',
        "Quotes in a URL are percent-encoded and cannot end the argument")
    LinkChecks.Assert(LinkFollow.CommandLine(chrome,"") == '"' . chrome.Path . '"',"An empty link only starts the browser")
    LinkChecks.Assert(LinkFollow.CommandLine(chrome,"https://a/`r`n--evil") == '"' . chrome.Path . '" --single-argument https://a/--evil',
        "Control characters are removed from links")

    firefox := {Path:"C:\Program Files\Mozilla Firefox\firefox.exe",Args:'-osint -url "%1"'}
    LinkChecks.Assert(LinkFollow.CommandLine(firefox,url) == '"' . firefox.Path . '" -osint -url "' . url . '"',
        "Firefox keeps its registered -osint form for ordinary links")
    LinkChecks.Assert(LinkFollow.CommandLine(firefox,url,true) == '"' . firefox.Path . '" -new-window "' . url . '"',
        "Firefox new windows use its own switch")
    LinkChecks.Assert(LinkFollow.CommandLine(firefox,"https://a/b\") == '"' . firefox.Path . '" -osint -url "https://a/b%5C"',
        "A trailing backslash cannot escape the closing quote")
    other := {Path:"D:\Browsers\other.exe",Args:""}
    LinkChecks.Assert(LinkFollow.CommandLine(other,url,true) == '"' . other.Path . '" "' . url . '"',
        "An unknown browser gets one quoted URL and no guessed switches")

    LinkChecks.Assert(LinkFollow.SplitCommand('"' . A_WinDir . '\explorer.exe" --single-argument %1',&exe,&args)
        && exe = A_WinDir . "\explorer.exe" && args == "--single-argument %1","A quoted registered command is split")
    LinkChecks.Assert(LinkFollow.SplitCommand(A_WinDir . '\explorer.exe -osint -url "%1"',&exe,&args)
        && exe = A_WinDir . "\explorer.exe" && args == '-osint -url "%1"',"An unquoted registered command is split")
    LinkChecks.Assert(!LinkFollow.SplitCommand('"' . A_AhkPath . '" "x.ahk" --single-argument %1',&exe,&args),
        "This tool's own runtime can never be recorded as the browser (no link loop)")
    LinkChecks.Assert(!LinkFollow.SplitCommand('"C:\Missing\nothing.exe" %1',&exe,&args),"A missing browser is rejected")
    LinkChecks.Assert(LinkFollow.EncodeQuery("Google Chrome") == "Google%20Chrome"
        && LinkFollow.EncodeQuery(LinkFollow.Client) == LinkFollow.Client,"Settings deep links escape application names")
    LinkChecks.Assert(LinkFollow.NewWindowFlag(chrome.Path) == "--new-window" && LinkFollow.NewWindowFlag(other.Path) == ""
        && LinkFollow.IsChromium("C:\x\MSEDGE.EXE"),"New-window switches are only used for known browsers")
    root := "D:\TaskbarFollow"
    LinkChecks.Assert(LinkFollow.Command(root) == '"D:\TaskbarFollow\runtime\AutoHotkey64.exe" "D:\TaskbarFollow\LinkOpen.ahk" --single-argument %1',
        "The registered handler passes the URL after a single-argument marker")
    FileAppend("PASS link-follow assertions=" . LinkChecks.Count . "`n","*","UTF-8")
} catch as e {
    FileAppend("FAIL " . e.Message . "; line=" . e.Line . "`n","*","UTF-8")
    ExitApp(1)
}
ExitApp(0)
