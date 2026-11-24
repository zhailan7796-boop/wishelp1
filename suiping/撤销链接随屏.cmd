@echo off
rem Undo "suiping link follow": restores the default browser and removes its registration.
setlocal
cd /d "%~dp0"
if not exist "%~dp0runtime\AutoHotkey64.exe" (
  echo Missing portable AutoHotkey runtime. Keep the complete TaskbarFollow folder.
  pause
  exit /b 2
)
start "" "%~dp0runtime\AutoHotkey64.exe" "%~dp0tools\Configure-LinkFollow.ahk" uninstall
