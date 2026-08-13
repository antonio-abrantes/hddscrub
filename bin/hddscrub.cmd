@echo off
setlocal

if /I "%~1"=="-v" (
  if "%~2"=="" (
    set "HDDSCRUB_ARGS=--version"
    goto run
  )
)

if /I "%~1"=="-h" (
  set "HDDSCRUB_ARGS=--help"
  goto run
)

if /I "%~1"=="-?" (
  set "HDDSCRUB_ARGS=--help"
  goto run
)

set "HDDSCRUB_ARGS=%*"

:run
where pwsh.exe >nul 2>nul
if %ERRORLEVEL%==0 (
  pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0hddscrub.ps1" %HDDSCRUB_ARGS%
) else (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0hddscrub.ps1" %HDDSCRUB_ARGS%
)

exit /b %ERRORLEVEL%
