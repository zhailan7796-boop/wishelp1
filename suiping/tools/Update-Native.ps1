# 随屏：自检 + 重新编译原生组件（C++ 钩子 DLL）。
# 由随屏文件夹里的「更新原生组件.cmd」调用，也可以直接运行：
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\Update-Native.ps1
#
# 做的事（按顺序）：
#   1. 只读自检：检查「随屏链接」脚本能否正常加载，跑两组不碰真实窗口的检查；
#   2. 先备份 native\bin\runtime.ini，再编译原生组件并运行它的自测；
#   3. 第 2 步任何地方失败 → 自动把 runtime.ini 改回去，随屏继续用原来的组件；
#   4. 全部通过 → 问你要不要现在重启随屏，让新组件生效。
# 不改注册表、不改默认浏览器、不删除任何旧文件。
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$ahk = Join-Path $root 'runtime\AutoHotkey64.exe'
$bin = Join-Path $root 'native\bin'
$runtimeIni = Join-Path $bin 'runtime.ini'
$backupIni = Join-Path $bin ('runtime.ini.before-' + $stamp)
$logDir = Join-Path $root 'logs'
$null = New-Item -ItemType Directory -Path $logDir -Force
$log = Join-Path $logDir ('update-native-' + $stamp + '.txt')

function Note([string]$text) { Add-Content -LiteralPath $log -Value $text -Encoding UTF8 }
function Say([string]$text, [string]$color = 'Gray') { Write-Host $text -ForegroundColor $color; Note $text }

# Runs one AutoHotkey check hidden, with its output captured like tests\Run-Tests.ps1.
function Test-Ahk([string]$label, [string]$arguments) {
    $out = Join-Path ([IO.Path]::GetTempPath()) ('taskbarfollow-check-' + $stamp + '-' + [guid]::NewGuid().ToString('N') + '.out.txt')
    $err = [IO.Path]::ChangeExtension($out, '.err.txt')
    try {
        $process = Start-Process -FilePath $ahk -ArgumentList $arguments -WorkingDirectory $root -WindowStyle Hidden -PassThru `
            -RedirectStandardOutput $out -RedirectStandardError $err
        $null = $process.Handle
        if (-not $process.WaitForExit(30000)) {
            $process.Kill(); $process.WaitForExit()
            Say ('  没通过：' + $label + '（30 秒没有结束，可能弹出了提示框）') 'Red'
            return $false
        }
        $process.WaitForExit()
        $text = if (Test-Path -LiteralPath $out) { [IO.File]::ReadAllText($out, [Text.Encoding]::UTF8) } else { '' }
        $errors = if (Test-Path -LiteralPath $err) { [IO.File]::ReadAllText($err, [Text.Encoding]::UTF8) } else { '' }
        Note ('[' + $label + '] exit=' + $process.ExitCode)
        if ($text) { Note $text.TrimEnd() }
        if ($errors) { Note $errors.TrimEnd() }
        if ($process.ExitCode -ne 0 -or $errors.Trim() -ne '' -or $text -match '==>|\bWarning:|\bFAIL\b') {
            Say ('  没通过：' + $label) 'Red'
            return $false
        }
        Say ('  通过：' + $label) 'Green'
        return $true
    } catch {
        Say ('  没通过：' + $label + '（' + $_.Exception.Message + '）') 'Red'
        return $false
    } finally {
        Remove-Item -LiteralPath $out, $err -ErrorAction SilentlyContinue
    }
}

Say ('随屏 · 自检并更新原生组件   ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Say ('记录文件：' + $log)
if (-not (Test-Path -LiteralPath $ahk) -or -not (Test-Path -LiteralPath $runtimeIni)) {
    Say '随屏文件夹不完整（缺少 runtime\AutoHotkey64.exe 或 native\bin\runtime.ini），什么都没做。' 'Red'
    Read-Host '按回车关闭' | Out-Null
    exit 2
}

# ---- 第 1 步：自检 ----
Say ''
Say '第 1 步：自检（约半分钟；屏幕上会有几个测试小窗口闪一下、在两块屏幕间跳几下，都是自己的测试窗口，正常）…' 'Cyan'
$checks = @(
    @{Key = 'main'; Label = '随屏主程序能正常加载'; Args = '/ErrorStdOut=UTF-8 /validate "' + (Join-Path $root 'TaskbarFollow.ahk') + '"'},
    @{Key = 'link'; Label = '随屏链接脚本能正常加载'; Args = '/ErrorStdOut=UTF-8 /validate "' + (Join-Path $root 'LinkOpen.ahk') + '"'},
    @{Key = 'link'; Label = '链接命令行构造（不打开浏览器）'; Args = '/ErrorStdOut=UTF-8 "' + (Join-Path $root 'tests\LinkFollow.ahk') + '"'},
    @{Key = 'follow'; Label = '应用内新窗口 / 链接窗口的跟随判断'; Args = '/ErrorStdOut=UTF-8 "' + (Join-Path $root 'tests\CompatibilityFollow.ahk') + '"'},
    @{Key = 'follow'; Label = '芒果TV 这类工具窗口样式的播放窗口能被识别'; Args = '/ErrorStdOut=UTF-8 "' + (Join-Path $root 'tests\LaunchedWindow.ahk') + '"'},
    @{Key = 'follow'; Label = '跨屏移动窗口（含 32 位程序、工具窗口）'; Args = '/ErrorStdOut=UTF-8 "' + (Join-Path $root 'tests\WindowMove.ahk') + '"'}
)
$passed = @{ main = $true; link = $true; follow = $true }
foreach ($check in $checks) {
    if (-not (Test-Ahk $check.Label $check.Args)) { $passed[$check.Key] = $false }
}
$mainOk = $passed['main']
$linkOk = $mainOk -and $passed['link']
$followOk = $mainOk -and $passed['follow']
$ahkOk = $linkOk -and $followOk

# ---- 第 2 步：编译原生组件并自测 ----
Say ''
Say '第 2 步：原生组件编译和自测（约 1～3 分钟；自测在单独的隐藏桌面里进行，不会动你的窗口）…' 'Cyan'
Copy-Item -LiteralPath $runtimeIni -Destination $backupIni -Force
Say ('  已备份当前组件指向：' + $backupIni)
$build = Join-Path $root 'native\build-native.ps1'
$sawPass = $false
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $build 2>&1 | ForEach-Object {
    $line = $_.ToString()
    if ($line -like 'PASS native hook build*') { $sawPass = $true }
    Write-Host ('    ' + $line) -ForegroundColor DarkGray
    Note $line
}
$buildCode = $LASTEXITCODE
$dllName = ''
try { $dllName = ((Get-Content -LiteralPath $runtimeIni) | Where-Object { $_ -like 'Dll=*' } | Select-Object -First 1).Substring(4) } catch { }
$nativeOk = $buildCode -eq 0 -and $sawPass -and $dllName -ne '' -and (Test-Path -LiteralPath (Join-Path $bin $dllName))
if (-not $nativeOk) {
    Copy-Item -LiteralPath $backupIni -Destination $runtimeIni -Force
    Say '  原生组件没有更新成功：已自动改回原来的组件，没有任何改变。' 'Yellow'
    if ((Get-Content -LiteralPath $log -Raw) -match 'Visual C\+\+ x64 tools are required') {
        Say '  原因：这台电脑上找不到 Visual Studio 的 C++ 编译工具。' 'Yellow'
    }
} else {
    Say ('  通过：原生组件 ' + $dllName) 'Green'
}

# ---- 结果 ----
Say ''
if (-not $mainOk) {
    Say '随屏主程序自检没通过：这次不重启随屏（正在运行的随屏不受影响）。请把记录文件发给 Claude 看。' 'Red'
}
if (-not $followOk) {
    Say '「应用内新窗口跟随」自检没通过，请把记录文件发给 Claude 看。' 'Red'
}
if ($mainOk) {
    Say ''
    $answer = Read-Host '现在重启随屏，让这次的改动生效吗？输入 Y 再回车；直接回车 = 稍后自己重启'
    if ($answer -match '^\s*[yY]') {
        # Graceful exit of the running 随屏, then Start.exe (same as tray "退出" + double-click).
        $restart = Join-Path $root 'tools\Restart-Engine.ahk'
        $ok = (Test-Path -LiteralPath $restart) -and (Test-Ahk '重启随屏' ('/ErrorStdOut=UTF-8 "' + $restart + '"'))
        if ($ok) { Say '已重启随屏（托盘图标会重新出现）。' 'Green' }
        else { Say '没能自动重启：请在托盘图标上右键 →「退出」，再双击随屏文件夹里的 Start.exe。' 'Yellow' }
    } else {
        Say '稍后请在托盘图标上右键 →「退出」，再双击 Start.exe，改动才会生效。'
    }
}

# 「链接随屏」：Windows 只允许用户自己在设置里选默认浏览器，所以这里只能帮你走到那一步。
$choice = ''
foreach ($key in @('UserChoiceLatest', 'UserChoice')) {
    try {
        $value = (Get-ItemProperty -LiteralPath ('HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\https\' + $key) -ErrorAction Stop).ProgId
        if ($value) { $choice = $value; break }
    } catch { }
}
Note ('https default ProgId=' + $choice)
Say ''
if ($choice -eq 'TaskbarFollow.Link') {
    Say '「链接随屏」已开启：飞书等应用里点开的网页会在你点击的那块屏幕打开。' 'Green'
} elseif ($linkOk) {
    Say '「链接随屏」还没开启，所以飞书里点云文档仍会跑到屏幕1上已经打开的 Chrome 里。' 'Yellow'
    $answer = Read-Host '现在开启吗？输入 Y 再回车（会弹出说明框，最后需要你在 Windows 设置里点一下「设为默认值」）'
    if ($answer -match '^\s*[yY]') {
        Start-Process -FilePath $ahk -ArgumentList ('"' + (Join-Path $root 'tools\Configure-LinkFollow.ahk') + '" setup') -WorkingDirectory $root
        Say '已打开开启向导，请按弹出的说明操作。'
    } else {
        Say '以后想开启：双击随屏文件夹里的「开启链接随屏.cmd」。'
    }
} else {
    Say '「链接随屏」自检没通过，先不要开启它，请把记录文件发给 Claude 看。' 'Red'
}
Say ''
Read-Host '按回车关闭这个窗口' | Out-Null
if ($nativeOk -and $ahkOk) { exit 0 }
exit 1
