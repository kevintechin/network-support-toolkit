@echo off
rem Console fallback. It keeps all files local and records startup failures.
chcp 65001 >nul 2>&1
setlocal EnableExtensions
cd /d "%~dp0"
title Network Health Check - Console Mode

set "SCRIPT=%~dp0NetworkHealthCheck.ps1"
set "PS_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "FAIL_REASON="

if not exist "%SCRIPT%" (
    set "FAIL_REASON=The program file NetworkHealthCheck.ps1 is missing. Keep all files in the same folder."
    goto :launcher_error
)

if not exist "%PS_EXE%" (
    where pwsh.exe >nul 2>&1
    if errorlevel 1 (
        set "FAIL_REASON=PowerShell was not found on this computer."
        goto :launcher_error
    ) else (
        set "PS_EXE=pwsh.exe"
    )
)

"%PS_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -ConsoleOnly
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
    set "FAIL_REASON=The diagnostic program ended with exit code %RC%. PowerShell or company security policy may have blocked execution."
    goto :launcher_error
)

echo.
echo Network Health Check completed successfully.
echo Exit code: 0
pause
exit /b 0

:launcher_error
set "ERRFILE=%~dp0LauncherError.txt"
>"%ERRFILE%" (
    echo Network Health Check console launcher error
    echo ===========================================
    echo Date/time: %DATE% %TIME%
    echo Computer: %COMPUTERNAME%
    echo User: %USERNAME%
    echo Folder: %~dp0
    echo Script: %SCRIPT%
    echo PowerShell: %PS_EXE%
    echo.
    echo Error: %FAIL_REASON%
    echo.
    echo Suggested action: extract the complete ZIP file to a local folder, then run Start-NetworkCheck-Console.cmd again.
) 2>nul

if exist "%ERRFILE%" goto :show_launcher_error

set "ERRFILE=%TEMP%\NetworkHealthCheck_LauncherError.txt"
>"%ERRFILE%" (
    echo Network Health Check console launcher error
    echo Date/time: %DATE% %TIME%
    echo Computer: %COMPUTERNAME%
    echo User: %USERNAME%
    echo Error: %FAIL_REASON%
)

:show_launcher_error
echo.
echo ERROR: %FAIL_REASON%
echo Error report: "%ERRFILE%"
echo.
pause
exit /b 1
