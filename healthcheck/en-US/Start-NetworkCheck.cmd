@echo off
rem Portable launcher. It keeps all files local and records startup failures.
chcp 65001 >nul 2>&1
setlocal EnableExtensions
cd /d "%~dp0"
title Network Health Check

set "SCRIPT=%~dp0NetworkHealthCheck.ps1"
set "PS_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "FAIL_REASON="
set "SUGGESTED="

if not exist "%SCRIPT%" (
    set "FAIL_REASON=The program file NetworkHealthCheck.ps1 is missing. Keep all files in the same folder."
    set "SUGGESTED=extract the complete ZIP file to a local folder, then run Start-NetworkCheck.cmd again."
    goto :launcher_error
)

if not exist "%PS_EXE%" (
    where pwsh.exe >nul 2>&1
    if errorlevel 1 (
        set "FAIL_REASON=PowerShell was not found on this computer."
        set "SUGGESTED=Windows PowerShell 5.1 is part of Windows; ask IT to check this computer, or run the check on another one."
        goto :launcher_error
    ) else (
        set "PS_EXE=pwsh.exe"
    )
)

"%PS_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File "%SCRIPT%"
set "RC=%ERRORLEVEL%"

if "%RC%"=="3" (
    set "FAIL_REASON=The diagnostic program ended with exit code 3, the code it uses when PowerShell is restricted to a limited language mode by an application-control policy: no check ran."
    set "SUGGESTED=read NetworkHealthCheck_ENVIRONMENT_*.txt in this folder or in the Windows temporary folder - it names what IT can do - and send it with the support request."
    goto :launcher_error
)
if not "%RC%"=="0" (
    set "FAIL_REASON=The diagnostic program ended with exit code %RC%. PowerShell or company security policy may have blocked execution."
    set "SUGGESTED=read the message printed above the error in this window - PowerShell says there why it did not run the program - and send it together with this file. If it says the file is not digitally signed or is blocked by a policy, ask IT to allow NetworkHealthCheck.ps1."
    goto :launcher_error
)

exit /b 0

:launcher_error
set "ERRFILE=%~dp0LauncherError.txt"
>"%ERRFILE%" (
    echo Network Health Check launcher error
    echo ===================================
    echo Date/time: %DATE% %TIME%
    echo Computer: %COMPUTERNAME%
    echo User: %USERNAME%
    echo Folder: %~dp0
    echo Script: %SCRIPT%
    echo PowerShell: %PS_EXE%
    echo.
    echo Error: %FAIL_REASON%
    echo.
    echo Suggested action: %SUGGESTED%
) 2>nul

if exist "%ERRFILE%" goto :show_launcher_error

set "ERRFILE=%TEMP%\NetworkHealthCheck_LauncherError.txt"
>"%TEMP%\NetworkHealthCheck_LauncherError.txt" (
    echo Network Health Check launcher error
    echo Date/time: %DATE% %TIME%
    echo Computer: %COMPUTERNAME%
    echo User: %USERNAME%
    echo Error: %FAIL_REASON%
    echo Suggested action: %SUGGESTED%
)

:show_launcher_error
echo.
echo ERROR: %FAIL_REASON%
echo Suggested action: %SUGGESTED%
echo Error report: "%ERRFILE%"
echo.
pause
exit /b 1
