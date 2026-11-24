@echo off
rem One double-click to switch on the 2026-11-23 fixes:
rem   1. self-check (about 30 s; a test window jumps from screen 1 to screen 2),
rem   2. restart TaskbarFollow so the new code is loaded,
rem   3. register the link handler and open Windows Settings, where you click "Set default" once.
rem Details: tools\Activate-Fixes.ps1 ; log: logs\activate-*.txt
setlocal
cd /d "%~dp0"
if not exist "%~dp0tools\Activate-Fixes.ps1" (
  echo Missing tools\Activate-Fixes.ps1. Keep the complete TaskbarFollow folder.
  pause
  exit /b 2
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\Activate-Fixes.ps1"
exit /b %errorlevel%
