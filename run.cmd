@echo off
setlocal
rem ============================================================
rem  run.cmd  --  menu front-end for this repository.
rem
rem  Read-only probes, apply / restore (with confirmation and
rem  UAC), and the IFR locator that makes patch files.
rem  All menu text lives in run.ps1 (kept pure ASCII).
rem ============================================================

set "DIR=%~dp0"
set "PS1=%DIR%run.ps1"

if not exist "%PS1%" (
  echo [X] not found: "%PS1%"
  pause
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
