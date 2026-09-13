@echo off
rem Console fallback. It keeps all files local and records startup failures.
chcp 65001 >nul 2>&1
setlocal EnableExtensions
cd /d "%~dp0"
title Network Health Check - Console Mode

rem The folder's path is taken once, before delayed expansion is switched on, and every value is expanded as !VALUE!
rem from here on: a path may carry a parenthesis - a browser's second download of the ZIP is extracted to a folder
rem named like the ZIP plus (1) - an ampersand or an exclamation mark, and any of them breaks a line that expands the
rem value before the line is parsed. Delayed expansion inserts the value after parsing, so the path cannot.
set "HERE=%~dp0"
setlocal EnableDelayedExpansion
set "SCRIPT=!HERE!NetworkHealthCheck.ps1"
set "PS_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "FAIL_REASON="
set "SUGGESTED="
set "LOGFILE="
set "LOGKEPT="
set "PS_STARTED="
set "DATEFMT="
set "CREATED="
set "SEQ=0"

rem A stamp for this attempt's files (backlog #47): the digits of the shell's own date and time, in the order this
rem computer prints them, so that separate attempts never overwrite each other and sort by time on the same machine.
rem PowerShell cannot be asked - it may be what is missing - and %DATE% carries separators and, on some machines, a
rem weekday name, so the loop keeps the digits alone; the leading space of an early hour becomes a zero. Two launchers
rem started in the same hundredth of a second get the same digits; the reservation below tells them apart.
set "RAW=!DATE!!TIME: =0!"
set "STAMP="
:stamp_next
if not defined RAW goto :stamp_done
set "CH=!RAW:~0,1!"
set "RAW=!RAW:~1!"
for %%D in (0 1 2 3 4 5 6 7 8 9) do if "!CH!"=="%%D" set "STAMP=!STAMP!!CH!"
goto :stamp_next
:stamp_done
if not defined STAMP set "STAMP=%RANDOM%"
set "BASESTAMP=!STAMP!"

rem The short-date pattern this computer printed %DATE% in (backlog #44), read before anything is written: the error
rem report states which pattern its date is in. When the value cannot be read the report omits it, and nothing here
rem may stop the report from being written.
for /f "tokens=1,2,*" %%A in ('reg query "HKCU\Control Panel\International" /v sShortDate 2^>nul') do if /i "%%A"=="sShortDate" set "DATEFMT=%%C"

if not exist "!SCRIPT!" (
    set "FAIL_REASON=The program file NetworkHealthCheck.ps1 is missing. Keep all files in the same folder."
    set "SUGGESTED=extract the complete ZIP file to a local folder, then run Start-NetworkCheck-Console.cmd again."
    goto :launcher_error
)

if not exist "!PS_EXE!" (
    where pwsh.exe >nul 2>&1
    if errorlevel 1 (
        set "FAIL_REASON=PowerShell was not found on this computer."
        set "SUGGESTED=Windows PowerShell 5.1 is part of Windows; ask IT to check this computer, or run the check on another one."
        goto :launcher_error
    ) else (
        set "PS_EXE=pwsh.exe"
    )
)

rem PowerShell's error stream goes to a file (backlog #47) - beside the launcher, else in the Windows temporary
rem folder - so that the sentence explaining why the program did not run is kept instead of being copied off the
rem screen. Everything the run prints as it goes still reaches this window. The file is created before the run: a
rem redirection that fails at run time would stop PowerShell from starting at all, so where no file can be created
rem the program runs without the capture and the report says so. The name is reserved, not merely written: a name
rem already taken means another launcher started in the same hundredth of a second, and this one moves to the next
rem suffix. An empty file is deleted afterwards, so a run that printed nothing there leaves nothing behind.
:reserve_messages
set "LOGFILE=!HERE!PowerShellMessages_!STAMP!.txt"
call :create_file LOGFILE 2>nul
if "!CREATED!"=="taken" goto :bump_messages
if "!CREATED!"=="1" goto :messages_reserved
set "LOGFILE=!TEMP!\NetworkHealthCheck_PowerShellMessages_!STAMP!.txt"
call :create_file LOGFILE 2>nul
if "!CREATED!"=="taken" goto :bump_messages
if "!CREATED!"=="1" goto :messages_reserved
goto :messages_unreserved
:bump_messages
set /a SEQ+=1
if !SEQ! GTR 9 goto :messages_unreserved
set "STAMP=!BASESTAMP!-!SEQ!"
goto :reserve_messages
:messages_unreserved
set "LOGFILE="
:messages_reserved
set "PS_STARTED=1"
if defined LOGFILE goto :run_captured
"!PS_EXE!" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "!SCRIPT!" -ConsoleOnly
goto :ran
:run_captured
"!PS_EXE!" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "!SCRIPT!" -ConsoleOnly 2>>"!LOGFILE!"
:ran
set "RC=!ERRORLEVEL!"
if defined LOGFILE if exist "!LOGFILE!" for %%F in ("!LOGFILE!") do if "%%~zF"=="0" del "!LOGFILE!" 2>nul
if defined LOGFILE if exist "!LOGFILE!" set "LOGKEPT=1"

if "!RC!"=="3" (
    set "FAIL_REASON=The diagnostic program ended with exit code 3, the code it uses when PowerShell is restricted to a limited language mode by an application-control policy: no check ran."
    set "SUGGESTED=read NetworkHealthCheck_ENVIRONMENT_*.txt in this folder or in the Windows temporary folder - it names what IT can do - and send it with the support request."
    goto :launcher_error
)
if not "!RC!"=="0" goto :blocked
echo.
echo Network Health Check completed successfully.
echo Exit code: 0
pause
exit /b 0

:blocked
set "FAIL_REASON=The diagnostic program ended with exit code !RC!. PowerShell or company security policy may have blocked execution."
if defined LOGKEPT goto :blocked_with_messages
if not defined LOGFILE goto :blocked_uncaptured
set "SUGGESTED=PowerShell printed no explanation. Send this error report with the support request and describe what the window showed; if the file is not digitally signed or is blocked by a policy, IT has to allow NetworkHealthCheck.ps1."
goto :launcher_error
:blocked_uncaptured
set "SUGGESTED=no file could be created for PowerShell's explanation, so it is on this screen only: read the lines above the error and send them with this error report. If they say the file is not digitally signed or is blocked by a policy, ask IT to allow NetworkHealthCheck.ps1."
goto :launcher_error
:blocked_with_messages
set "SUGGESTED=PowerShell's own explanation is printed below and kept in !LOGFILE! - send that file together with this error report. If it says the file is not digitally signed or is blocked by a policy, ask IT to allow NetworkHealthCheck.ps1."
goto :launcher_error

:launcher_error
rem The error report's name is reserved the same way, beside the launcher, else in the Windows temporary folder - the
rem second write is not checked, so the path shown may be one the folder refused, as the manuals say.
:reserve_report
set "ERRFILE=!HERE!LauncherError_!STAMP!.txt"
call :create_file ERRFILE 2>nul
if "!CREATED!"=="taken" goto :bump_report
if "!CREATED!"=="1" goto :report_reserved
set "ERRFILE=!TEMP!\NetworkHealthCheck_LauncherError_!STAMP!.txt"
call :create_file ERRFILE 2>nul
if "!CREATED!"=="taken" goto :bump_report
goto :report_reserved
:bump_report
set /a SEQ+=1
if !SEQ! GTR 9 goto :report_reserved
set "STAMP=!BASESTAMP!-!SEQ!"
goto :reserve_report
:report_reserved
call :write_error_report 2>nul

echo.
echo ERROR: !FAIL_REASON!
if defined LOGKEPT echo What PowerShell said, kept in "!LOGFILE!":
if defined LOGKEPT type "!LOGFILE!"
if defined LOGKEPT echo.
echo Suggested action: !SUGGESTED!
echo Error report: "!ERRFILE!"
echo.
pause
exit /b 1

:write_error_report
rem One line per write, and a stamped name, so that a second attempt is a second file and a parenthesis in a path
rem cannot end the write halfway, as it would inside a parenthesised block. The same lines beside the launcher and
rem in the Windows temporary folder; the caller's 2>nul keeps a refused write off the screen.
set "DATELINE=Date/time: !DATE! !TIME!"
if defined DATEFMT set "DATELINE=Date/time: !DATE! !TIME! (this computer's short-date pattern: !DATEFMT!)"
set "LOGLINE=PowerShell messages: none - PowerShell was not started"
if defined PS_STARTED set "LOGLINE=PowerShell messages: not captured - no file could be created beside the launcher or in the temporary folder, so whatever PowerShell printed is on the screen only"
if defined LOGFILE set "LOGLINE=PowerShell messages: none - PowerShell printed nothing on its error stream"
if defined LOGKEPT set "LOGLINE=PowerShell messages: !LOGFILE!"
>"!ERRFILE!" echo Network Health Check console launcher error
>>"!ERRFILE!" echo ===========================================
>>"!ERRFILE!" echo !DATELINE!
>>"!ERRFILE!" echo Computer: !COMPUTERNAME!
>>"!ERRFILE!" echo User: !USERNAME!
>>"!ERRFILE!" echo Folder: !HERE!
>>"!ERRFILE!" echo Script: !SCRIPT!
>>"!ERRFILE!" echo PowerShell: !PS_EXE!
>>"!ERRFILE!" echo !LOGLINE!
>>"!ERRFILE!" echo.
>>"!ERRFILE!" echo Error: !FAIL_REASON!
>>"!ERRFILE!" echo.
>>"!ERRFILE!" echo Suggested action: !SUGGESTED!
exit /b 0

:create_file
rem Creates the empty file named by the variable %1 and says how it went: 1 (created), taken (a file of that name was
rem already there), or nothing (the folder refused). fsutil creates atomically and refuses a taken name, which %RANDOM%
rem could not replace - two cmd.exe started in the same second draw the same numbers; where fsutil itself fails for
rem another reason and the name is free, a plain create stands in. The caller's 2>nul keeps a refusal off the screen.
set "CREATED="
fsutil file createnew "!%1!" 0 >nul 2>nul
if not errorlevel 1 set "CREATED=1"
if defined CREATED exit /b 0
if exist "!%1!" set "CREATED=taken"
if defined CREATED exit /b 0
>"!%1!" type nul
if exist "!%1!" set "CREATED=1"
exit /b 0
