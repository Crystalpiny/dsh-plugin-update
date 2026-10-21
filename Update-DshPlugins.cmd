@echo off
rem ---------------------------------------------------------------------------
rem  DSH plugin updater launcher
rem  Double-click to run interactively; pass arguments to run non-interactively,
rem  e.g.  Update-DshPlugins.cmd -Check
rem ---------------------------------------------------------------------------
setlocal
chcp 65001 >nul 2>nul

set "PS=pwsh.exe"
where /q pwsh.exe
if errorlevel 1 set "PS=powershell.exe"

"%PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Update-DshPlugins.ps1" %*
set "CODE=%ERRORLEVEL%"

if "%~1"=="" pause

endlocal & exit /b %CODE%
