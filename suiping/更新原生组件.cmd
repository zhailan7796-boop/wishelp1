@echo off
rem Self-check, then rebuild the native component (C++ hook DLL) and run its tests.
rem If anything fails, native\bin\runtime.ini is restored and nothing changes.
rem Details: tools\Update-Native.ps1 ; log: logs\update-native-*.txt
setlocal
cd /d "%~dp0"
if not exist "%~dp0tools\Update-Native.ps1" (
  echo Missing tools\Update-Native.ps1. Keep the complete TaskbarFollow folder.
  pause
  exit /b 2
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\Update-Native.ps1"
exit /b %errorlevel%
