@echo off
rem Turn on "suiping link follow": links opened from apps such as Feishu open on
rem the screen you clicked. Opens a short guide; the last step is one click on
rem "Set default" in Windows Settings (Windows only lets you choose that yourself).
rem Undo any time: double-click the undo .cmd next to this file.
setlocal
cd /d "%~dp0"
if not exist "%~dp0runtime\AutoHotkey64.exe" (
  echo Missing portable AutoHotkey runtime. Keep the complete TaskbarFollow folder.
  pause
  exit /b 2
)
start "" "%~dp0runtime\AutoHotkey64.exe" "%~dp0tools\Configure-LinkFollow.ahk" setup
