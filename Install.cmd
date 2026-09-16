@echo off
rem ---------------------------------------------------------------------------
rem  Codex x DSH Team Toolkit - double-click install entry point.
rem
rem  With no arguments this opens an STA Windows folder picker (no cd required).
rem  Cancelling the picker exits safely without writing anything.
rem
rem  Command line (CI / power users):
rem    Install.cmd -Target "D:\projects\my-project"
rem    Install.cmd -Target "D:\projects\my-project" -PlanOnly
rem ---------------------------------------------------------------------------
setlocal EnableExtensions
title Codex x DSH Team Toolkit - Install

set "HERE=%~dp0"
set "ENGINE=%HERE%install\Invoke-Toolkit.ps1"
if not exist "%ENGINE%" (
  echo [ERROR] Toolkit engine not found:
  echo         "%ENGINE%"
  echo         Extract the complete release package and run Install.cmd from its root.
  if "%~1"=="" pause
  exit /b 5
)

set "PWSH="
for %%P in (pwsh.exe) do if not defined PWSH set "PWSH=%%~$PATH:P"
if not defined PWSH if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not defined PWSH if exist "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" set "PWSH=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not defined PWSH (
  echo [ERROR] No PowerShell host found. Install either PowerShell 7 ^(pwsh.exe^)
  echo         or use Windows PowerShell 5.1 which ships with Windows.
  if "%~1"=="" pause
  exit /b 2
)

"%PWSH%" -NoProfile -Sta -ExecutionPolicy Bypass -File "%ENGINE%" %*
set "CODE=%ERRORLEVEL%"

echo.
if "%CODE%"=="0" (
  echo Toolkit install finished successfully.
) else (
  echo Toolkit install exited with code %CODE%. Nothing was left half-applied.
)
if "%~1"=="" pause
exit /b %CODE%
