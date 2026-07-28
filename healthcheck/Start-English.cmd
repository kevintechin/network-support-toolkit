@echo off
setlocal
if not exist "%~dp0en-US\Start-NetworkCheck.cmd" (
  echo ERROR: en-US package is missing.
  pause
  exit /b 1
)
call "%~dp0en-US\Start-NetworkCheck.cmd"
exit /b %ERRORLEVEL%
