@echo off
rem Console fallback. It keeps all files local and records startup failures.
chcp 65001 >nul 2>&1
setlocal EnableExtensions
cd /d "%~dp0"
title 網路健康檢查 - 文字模式

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
    set "FAIL_REASON=找不到程式檔 NetworkHealthCheck.ps1。請將所有檔案放在同一個資料夾。"
    set "SUGGESTED=請將完整 ZIP 解壓縮到本機資料夾，再執行 Start-NetworkCheck-Console.cmd。"
    goto :launcher_error
)

if not exist "!PS_EXE!" (
    where pwsh.exe >nul 2>&1
    if errorlevel 1 (
        set "FAIL_REASON=此電腦找不到 PowerShell。"
        set "SUGGESTED=Windows PowerShell 5.1 是 Windows 的一部分；請 IT 檢查這台電腦，或改在另一台電腦執行檢測。"
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
    set "FAIL_REASON=檢測程式結束代碼為 3，這是程式在 PowerShell 被應用程式控制政策限制在受限語言模式時使用的代碼：沒有任何檢測執行。"
    set "SUGGESTED=請閱讀本資料夾或 Windows 暫存資料夾中的 NetworkHealthCheck_ENVIRONMENT_*.txt，裡面寫明 IT 可以怎麼做，並連同支援請求一起送出。"
    goto :launcher_error
)
if not "!RC!"=="0" goto :blocked
echo.
echo 網路健康檢查已完成。
rem These ASCII lines separate the two echoes around them on purpose (backlog #50): under `chcp 65001` cmd
rem mis-reads the line following one that carries non-ASCII characters, drops its first bytes and runs the
rem remainder as a command, so a successful run ended in "is not recognized as an internal or external
rem command" under the sentence saying the check had finished. Measured 2026-09-13; do not remove them.
echo 結束代碼：0
pause
exit /b 0

:blocked
set "FAIL_REASON=檢測程式結束代碼為 !RC!。PowerShell 或公司安全政策可能阻擋執行。"
if defined LOGKEPT goto :blocked_with_messages
if not defined LOGFILE goto :blocked_uncaptured
set "SUGGESTED=PowerShell 沒有印出任何說明。請把這份錯誤報告連同支援請求一起送出，並描述視窗顯示了什麼；若程式檔未經數位簽署或被原則封鎖，需要 IT 允許 NetworkHealthCheck.ps1。"
goto :launcher_error
:blocked_uncaptured
set "SUGGESTED=PowerShell 的說明建不出檔案來保存，所以只在這個畫面上：請閱讀錯誤上方那幾行，連同這份錯誤報告一起送出。若寫著檔案未經數位簽署或被原則封鎖，請 IT 允許 NetworkHealthCheck.ps1。"
goto :launcher_error
:blocked_with_messages
set "SUGGESTED=PowerShell 自己的說明已印在下方，並保存在 !LOGFILE!，請把那個檔案連同這份錯誤報告一起送出。若訊息說檔案未經數位簽署或被原則封鎖，請 IT 允許 NetworkHealthCheck.ps1。"
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
echo 錯誤：!FAIL_REASON!
if defined LOGKEPT echo PowerShell 說了什麼，保存在 "!LOGFILE!"：
if defined LOGKEPT type "!LOGFILE!"
if defined LOGKEPT echo.
echo 建議：!SUGGESTED!
echo 錯誤報告："!ERRFILE!"
echo.
pause
exit /b 1

:write_error_report
rem One line per write, and a stamped name, so that a second attempt is a second file and a parenthesis in a path
rem cannot end the write halfway, as it would inside a parenthesised block. The same lines beside the launcher and
rem in the Windows temporary folder; the caller's 2>nul keeps a refused write off the screen.
set "DATELINE=日期時間：!DATE! !TIME!"
if defined DATEFMT set "DATELINE=日期時間：!DATE! !TIME! （這台電腦的短日期格式：!DATEFMT!）"
set "LOGLINE=PowerShell 訊息：無，PowerShell 沒有啟動"
if defined PS_STARTED set "LOGLINE=PowerShell 訊息：未擷取，啟動器旁邊和暫存資料夾都建不出檔案，PowerShell 印的東西只在畫面上"
if defined LOGFILE set "LOGLINE=PowerShell 訊息：無，PowerShell 的錯誤資料流沒有印出任何內容"
if defined LOGKEPT set "LOGLINE=PowerShell 訊息：!LOGFILE!"
>"!ERRFILE!" echo 網路健康檢查文字模式啟動器錯誤
>>"!ERRFILE!" echo ================================
>>"!ERRFILE!" echo !DATELINE!
>>"!ERRFILE!" echo 電腦：!COMPUTERNAME!
>>"!ERRFILE!" echo 使用者：!USERNAME!
>>"!ERRFILE!" echo 資料夾：!HERE!
>>"!ERRFILE!" echo 程式：!SCRIPT!
>>"!ERRFILE!" echo PowerShell：!PS_EXE!
>>"!ERRFILE!" echo !LOGLINE!
>>"!ERRFILE!" echo.
>>"!ERRFILE!" echo 錯誤：!FAIL_REASON!
>>"!ERRFILE!" echo.
>>"!ERRFILE!" echo 建議：!SUGGESTED!
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
