# 随屏 · 一键生效（芒果TV 播放窗口 + 飞书里点开的链接）
# 由随屏文件夹里的「一键生效.cmd」调用，也可以直接运行：
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\Activate-Fixes.ps1
#
# 做的事（按顺序）：
#   1. 自检（约半分钟）：主程序和「随屏链接」能否加载、跟随判断，以及一个模拟芒果TV的测试：
#      屏幕1上弹出一个和芒果TV播放窗口同类型的测试窗口，看它能不能自动跟到屏幕2；
#   2. 主程序自检通过 → 自动重启随屏，让新代码生效（等于托盘「退出」后再双击 Start.exe）；
#   3. 「链接随屏」没开 → 登记「随屏链接」并打开 Windows 设置，你只需点一次「设为默认值」，
#      这里会自动确认是否改好。
# 不编译原生组件（它 2026-11-23 09:31 已经更新过，之后源码没变），不删除任何文件。
# 记录保存在 logs\activate-时间.txt。撤销方法见 backup\2026-11-23-before-one-click\恢复说明.md。
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$ahk = Join-Path $root 'runtime\AutoHotkey64.exe'
$logDir = Join-Path $root 'logs'
$null = New-Item -ItemType Directory -Path $logDir -Force
$log = Join-Path $logDir ('activate-' + $stamp + '.txt')

function Note([string]$text) { Add-Content -LiteralPath $log -Value $text -Encoding UTF8 }
function Say([string]$text, [string]$color = 'Gray') { Write-Host $text -ForegroundColor $color; Note $text }

# Runs one AutoHotkey script with its output captured (same rules as tests\Run-Tests.ps1).
# Normal window style: test windows must be able to show and take focus.
function Invoke-Ahk([string]$arguments, [int]$timeoutMs = 30000) {
    $out = Join-Path ([IO.Path]::GetTempPath()) ('taskbarfollow-activate-' + $stamp + '-' + [guid]::NewGuid().ToString('N') + '.out.txt')
    $err = [IO.Path]::ChangeExtension($out, '.err.txt')
    $result = @{ Code = -1; Out = ''; Err = ''; TimedOut = $false; Failure = '' }
    try {
        $process = Start-Process -FilePath $ahk -ArgumentList $arguments -WorkingDirectory $root -WindowStyle Normal -PassThru `
            -RedirectStandardOutput $out -RedirectStandardError $err
        $null = $process.Handle
        if (-not $process.WaitForExit($timeoutMs)) {
            $process.Kill(); $process.WaitForExit()
            $result.TimedOut = $true
        } else {
            $process.WaitForExit()
        }
        $result.Code = $process.ExitCode
        if (Test-Path -LiteralPath $out) { $result.Out = [IO.File]::ReadAllText($out, [Text.Encoding]::UTF8) }
        if (Test-Path -LiteralPath $err) { $result.Err = [IO.File]::ReadAllText($err, [Text.Encoding]::UTF8) }
    } catch {
        $result.Failure = $_.Exception.Message
    } finally {
        Remove-Item -LiteralPath $out, $err -ErrorAction SilentlyContinue
    }
    return $result
}
function Test-Ahk([string]$label, [string]$arguments, [int]$timeoutMs = 30000) {
    $r = Invoke-Ahk $arguments $timeoutMs
    Note ('[' + $label + '] exit=' + $r.Code + $(if ($r.TimedOut) { ' (timeout)' } else { '' }))
    if ($r.Out) { Note $r.Out.TrimEnd() }
    if ($r.Err) { Note $r.Err.TrimEnd() }
    if ($r.Failure) { Note $r.Failure }
    if ($r.TimedOut) { Say ('  没通过：' + $label + '（没有按时结束，可能弹出了提示框）') 'Red'; return $false }
    if ($r.Failure -or $r.Code -ne 0 -or $r.Err.Trim() -ne '' -or $r.Out -match '==>|\bWarning:|\bFAIL\b') {
        Say ('  没通过：' + $label) 'Red'
        return $false
    }
    Say ('  通过：' + $label) 'Green'
    return $true
}
function Get-UrlChoice([string]$scheme) {
    foreach ($key in @('UserChoiceLatest', 'UserChoice')) {
        try {
            $value = (Get-ItemProperty -LiteralPath ('HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\' + $scheme + '\' + $key) -ErrorAction Stop).ProgId
            if ($value) { return $value }
        } catch { }
    }
    return ''
}
function Test-LinkDefault { (Get-UrlChoice 'https') -eq 'TaskbarFollow.Link' -and (Get-UrlChoice 'http') -eq 'TaskbarFollow.Link' }
# Newest "start;" line the engine wrote at or after $since.
function Find-EngineStart([datetime]$since) {
    $engineLog = Join-Path $logDir 'TaskbarFollow.log'
    if (-not (Test-Path -LiteralPath $engineLog)) { return '' }
    $lines = Get-Content -LiteralPath $engineLog -Tail 400 -Encoding UTF8 -ErrorAction SilentlyContinue
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $line = [string]$lines[$i]
        if ($line.Length -lt 20 -or $line.IndexOf(' start; ') -ne 19) { continue }
        $when = [datetime]::MinValue
        if ([datetime]::TryParseExact($line.Substring(0, 19), 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::None, [ref]$when) -and $when -ge $since) {
            return $line
        }
        return ''
    }
    return ''
}

Say ('随屏 · 一键生效（芒果TV 播放窗口 + 飞书链接）   ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Say ('记录文件：' + $log)
if (-not (Test-Path -LiteralPath $ahk)) {
    Say '随屏文件夹不完整（缺少 runtime\AutoHotkey64.exe），什么都没做。' 'Red'
    Read-Host '按回车关闭' | Out-Null
    exit 2
}

# ---- 第 1 步：自检 ----
Say ''
Say '第 1 步：自检（约半分钟）。屏幕1上会弹出几个测试小窗口，其中一个会自己跳到屏幕2——' 'Cyan'
Say '        那就是在模拟“芒果TV 点剧后弹出的播放窗口”。测试窗口会自己关掉，期间请先别点鼠标。' 'Cyan'
$checks = @(
    @{Key = 'main'; Label = '随屏主程序能正常加载'; Args = '/ErrorStdOut=UTF-8 /validate "' + (Join-Path $root 'TaskbarFollow.ahk') + '"'},
    @{Key = 'link'; Label = '「随屏链接」脚本能正常加载'; Args = '/ErrorStdOut=UTF-8 /validate "' + (Join-Path $root 'LinkOpen.ahk') + '"'},
    @{Key = 'link'; Label = '「随屏链接」设置脚本能正常加载'; Args = '/ErrorStdOut=UTF-8 /validate "' + (Join-Path $root 'tools\Configure-LinkFollow.ahk') + '"'},
    @{Key = 'link'; Label = '链接交给浏览器的命令行（不打开浏览器）'; Args = '/ErrorStdOut=UTF-8 "' + (Join-Path $root 'tests\LinkFollow.ahk') + '"'},
    @{Key = 'follow'; Label = '应用内新窗口 / 链接窗口的跟随判断'; Args = '/ErrorStdOut=UTF-8 "' + (Join-Path $root 'tests\CompatibilityFollow.ahk') + '"'},
    @{Key = 'follow'; Label = '工具样式窗口的识别（菜单、提示框、小浮层仍然不动）'; Args = '/ErrorStdOut=UTF-8 "' + (Join-Path $root 'tests\LaunchedWindow.ahk') + '"'},
    @{Key = 'follow'; Label = '模拟芒果TV：播放窗口从屏幕1跟到点击的屏幕，全程不最小化（含单独的32位程序）'; Args = '/ErrorStdOut=UTF-8 "' + (Join-Path $root 'tests\AppLaunchToolWindow.ahk') + '"'}
)
$passed = @{ main = $true; link = $true; follow = $true }
foreach ($check in $checks) {
    if (-not (Test-Ahk $check.Label $check.Args)) { $passed[$check.Key] = $false }
}
$mainOk = $passed['main']
$linkOk = $mainOk -and $passed['link']
$followOk = $mainOk -and $passed['follow']
try {
    $dll = ((Get-Content -LiteralPath (Join-Path $root 'native\bin\runtime.ini')) | Where-Object { $_ -like 'Dll=*' } | Select-Object -First 1).Substring(4)
    Note ('native component=' + $dll + '; exists=' + (Test-Path -LiteralPath (Join-Path $root ('native\bin\' + $dll))))
} catch { Note 'native component=unknown' }

# ---- 第 2 步：重启随屏 ----
Say ''
$restarted = $false
if (-not $mainOk) {
    Say '第 2 步：跳过。随屏主程序自检没通过，这次不重启（正在运行的随屏不受影响）。' 'Red'
} else {
    Say '第 2 步：重启随屏，让新代码生效…' 'Cyan'
    $since = (Get-Date).AddSeconds(-1)
    $r = Invoke-Ahk ('/ErrorStdOut=UTF-8 "' + (Join-Path $root 'tools\Restart-Engine.ahk') + '"') 20000
    Note ('[restart] exit=' + $r.Code + '; ' + $r.Out.Trim() + ' ' + $r.Err.Trim() + ' ' + $r.Failure)
    $startLine = ''
    if ($r.Code -eq 0) {
        $deadline = (Get-Date).AddSeconds(20)
        while ((Get-Date) -lt $deadline -and -not $startLine) {
            Start-Sleep -Milliseconds 500
            $startLine = Find-EngineStart $since
        }
    }
    if ($startLine) {
        $restarted = $true
        Note ('engine: ' + $startLine)
        Say '  通过：随屏已重启，新代码已生效（托盘图标会重新出现，状态窗口显示「运行中」）。' 'Green'
    } else {
        Say '  没能确认重启：请在托盘的随屏图标上右键 →「退出」，再双击随屏文件夹里的 Start.exe。' 'Yellow'
    }
}

# ---- 第 3 步：链接随屏 ----
Say ''
$linkOn = $false
if (-not $linkOk) {
    Say '第 3 步：跳过。「随屏链接」自检没通过，先不开启，请把记录文件发给 Claude。' 'Red'
} else {
    Say '第 3 步：开启「链接随屏」（让飞书里点开的云文档在你点击的那块屏幕打开）…' 'Cyan'
    $r = Invoke-Ahk ('/ErrorStdOut=UTF-8 "' + (Join-Path $root 'tools\Configure-LinkFollow.ahk') + '" quick') 20000
    $reply = ($r.Out + ' ' + $r.Err + ' ' + $r.Failure).Trim()
    Note ('[link quick] exit=' + $r.Code + '; ' + $reply)
    if ($reply -like 'ALREADY*' -or (Test-LinkDefault)) {
        $linkOn = $true
        Say '  已经开启，无需再设置（这次不会弹出 Windows 设置）。' 'Green'
    } elseif ($r.Code -eq 0 -and $reply -like 'OK*') {
        Say ''
        Say '  ★ 现在只需要你做一件事：' 'Yellow'
        Say '    在刚弹出的 Windows 设置「随屏链接」页面，点最上面的「设为默认值」。' 'Yellow'
        Say '    （如果没有这个按钮：把下面的 HTTP、HTTPS 两项都点开，改选「随屏链接」。）' 'Yellow'
        Say '    网页仍然由 Chrome 打开，Chrome 不会被改动。' 'Gray'
        Say ''
        Write-Host '  等你点…（最多等 3 分钟，改好会自动提示）' -NoNewline
        $deadline = (Get-Date).AddMinutes(3)
        $tick = 0
        while ((Get-Date) -lt $deadline) {
            if (Test-LinkDefault) { $linkOn = $true; break }
            Start-Sleep -Milliseconds 500
            $tick++
            if ($tick % 10 -eq 0) { Write-Host '.' -NoNewline }
        }
        Write-Host ''
        Note ('https=' + (Get-UrlChoice 'https') + '; http=' + (Get-UrlChoice 'http'))
        if ($linkOn) {
            Say '  通过：「链接随屏」已开启。' 'Green'
        } else {
            Say '  还没检测到改好。稍后在设置里点「设为默认值」也一样有效；或者以后双击「开启链接随屏.cmd」。' 'Yellow'
        }
    } else {
        Say ('  没能开启：' + $reply) 'Red'
    }
}

# ---- 结果 ----
Say ''
Say '================ 结果 ================' 'Cyan'
if ($restarted -and $followOk) {
    Say '芒果TV：新代码已生效，模拟测试通过。请在屏幕2的芒果TV里点一部剧试一下，播放窗口应出现在屏幕2。' 'Green'
    Say '        （如果之前点剧时播放窗口闪一下就没了：直接再点一次剧即可，它会重新出现并跟到屏幕2。）' 'Gray'
} elseif ($restarted) {
    Say '芒果TV：随屏已重启，但模拟测试没通过，可能仍会留在屏幕1。请把记录文件发给 Claude。' 'Yellow'
} else {
    Say '芒果TV：还没生效（随屏没有重启）。' 'Yellow'
}
if ($linkOn) {
    Say '飞书链接：已生效。在屏幕2的飞书里点一个云文档：屏幕2上有 Chrome 窗口就开成它的新标签，没有就在屏幕2新开一个窗口。' 'Green'
} else {
    Say '飞书链接：还没生效（需要在 Windows 设置里点「设为默认值」）。' 'Yellow'
}
Say '撤销「链接随屏」：双击「撤销链接随屏.cmd」。其他撤销方法见 backup\2026-11-23-before-no-minimize\恢复说明.md。'
Say ('记录文件：' + $log)
Say ''
Read-Host '按回车关闭这个窗口' | Out-Null
if ($restarted -and $followOk -and $linkOn) { exit 0 }
exit 1
