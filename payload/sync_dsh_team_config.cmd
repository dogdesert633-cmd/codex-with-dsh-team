@echo off
setlocal
chcp 65001 >nul 2>nul
set "SCRIPT=%~dp0.agents\skills\mcp-to-dsh\scripts\start_dsh_team.ps1"
if not exist "%SCRIPT%" (
  echo [X] DSH sync launcher not found: "%SCRIPT%"
  exit /b 1
)
rem Prefer PowerShell 7+ (pwsh.exe); the launcher verifies its own host (JSON probe and
rem PS version) and blocks clearly if the runtime cannot honour the output contract.
set "PWSH=powershell.exe"
where pwsh.exe >nul 2>nul
if %ERRORLEVEL%==0 set "PWSH=pwsh.exe"
"%PWSH%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -SkipDshCheck -NoBrowser %*
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" echo [X] DSH configuration sync failed with code %RC%.
endlocal & exit /b %RC%
