@echo off
rem ===========================================================================
rem  start_dsh_team.cmd - Windows double-click entry point for the Codex + DSH
rem  Team environment. Keep this file pure ASCII: cmd.exe does not reliably
rem  parse non-ASCII bytes in a .bat/.cmd file, and non-ASCII text here can make
rem  the batch parser loop forever. All human-facing Chinese output is printed by
rem  the PowerShell launcher below.
rem
rem  It only starts the entry point and keeps the window open:
rem    - calls .agents\skills\mcp-to-dsh\scripts\start_dsh_team.ps1
rem    - forwards any extra arguments to that script, e.g.
rem        start_dsh_team.cmd -SkipDshCheck
rem        start_dsh_team.cmd -NoBrowser
rem        start_dsh_team.cmd -Port 4317
rem    - pauses so the user can read the final status or the full error reason
rem ===========================================================================
setlocal

rem UTF-8 console so the PowerShell launcher's Chinese output renders correctly.
rem Safe here because this batch file contains ASCII bytes only.
chcp 65001 >nul 2>nul

set "SCRIPT=%~dp0.agents\skills\mcp-to-dsh\scripts\start_dsh_team.ps1"

if not exist "%SCRIPT%" (
  echo.
  echo [X] Launcher script not found:
  echo     %SCRIPT%
  echo     Make sure this file sits in the project root and that
  echo     .agents\skills\mcp-to-dsh\scripts is complete.
  echo.
  goto :hold
)

rem PowerShell host selection: prefer the reliable PowerShell 7+ (pwsh.exe).
rem When only Windows PowerShell 5.1 is present we still start it, but the launcher
rem verifies the host itself: it runs a real JSON serialisation probe and a PS version
rem check, and stops with a clear message instead of emitting output that cannot be
rem parsed downstream. No host is silently downgraded.
set "PWSH=powershell.exe"
where pwsh.exe >nul 2>nul
if %ERRORLEVEL%==0 set "PWSH=pwsh.exe"

title DSH Team Launcher

"%PWSH%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
set "RC=%ERRORLEVEL%"

if not "%RC%"=="0" (
  echo.
  echo [X] Launcher exited with code %RC%. Read the error above, fix it, then run again.
)

:hold
echo.
echo Press any key to close this window...
pause >nul
endlocal
exit /b %RC%
