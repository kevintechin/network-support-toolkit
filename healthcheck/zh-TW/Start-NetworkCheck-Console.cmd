@echo off
rem 文字模式備用啟動器：所有檔案留在本機，並記錄啟動階段錯誤。
chcp 65001 >nul 2>&1
setlocal EnableExtensions
cd /d "%~dp0"
title 網路健康檢查 - 文字模式

set "HERE=%~dp0"
set "SCRIPT=%HERE%NetworkHealthCheck.ps1"
set "PS_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "FAIL_REASON="
set "SUGGESTED="
set "LOGFILE="
set "LOGKEPT="
set "DATEFMT="

rem 這次執行的檔案戳記（待辦 #47）：取 shell 自己的日期與時間裡的數字，順序照這台電腦印出的樣子，讓每次執行
rem 各寫各的檔案、不互相覆寫，而且在同一台電腦上能依時間排序。這裡不能請 PowerShell 幫忙——缺的可能就是它——
rem 而 %DATE% 帶著分隔符號、在某些電腦上還有星期，所以用迴圈只留下數字；早上個位數小時前面的空白改成 0。
set "RAW=%DATE%%TIME: =0%"
set "STAMP="
:stamp_next
if not defined RAW goto :stamp_done
set "CH=%RAW:~0,1%"
set "RAW=%RAW:~1%"
for %%D in (0 1 2 3 4 5 6 7 8 9) do if "%CH%"=="%%D" set "STAMP=%STAMP%%CH%"
goto :stamp_next
:stamp_done
if not defined STAMP set "STAMP=%RANDOM%"

rem 這台電腦印 %DATE% 用的短日期格式（待辦 #44），在寫任何東西之前先讀：錯誤報告會註明它的日期是哪一種格式。
rem 讀不到就省略，而且這一步絕不能擋住錯誤報告的寫入。
for /f "tokens=1,2,*" %%A in ('reg query "HKCU\Control Panel\International" /v sShortDate 2^>nul') do if /i "%%A"=="sShortDate" set "DATEFMT=%%C"

if not exist "%SCRIPT%" (
    set "FAIL_REASON=找不到程式檔 NetworkHealthCheck.ps1。請將所有檔案放在同一個資料夾。"
    set "SUGGESTED=請將完整 ZIP 解壓縮到本機資料夾，再執行 Start-NetworkCheck-Console.cmd。"
    goto :launcher_error
)

if not exist "%PS_EXE%" (
    where pwsh.exe >nul 2>&1
    if errorlevel 1 (
        set "FAIL_REASON=此電腦找不到 PowerShell。"
        set "SUGGESTED=Windows PowerShell 5.1 是 Windows 的一部分；請 IT 檢查這台電腦，或改在另一台電腦執行檢測。"
        goto :launcher_error
    ) else (
        set "PS_EXE=pwsh.exe"
    )
)

rem PowerShell 的錯誤資料流導到一個檔案（待辦 #47）——啟動器旁邊，不行就 Windows 暫存資料夾——這樣說明程式為何
rem 沒有執行的那句話會留下來，不必請人從螢幕抄。執行過程印出的東西仍然照常出現在這個視窗。檔案在執行前先建立：
rem 導向若在執行時才失敗，PowerShell 根本不會啟動，所以建不出檔案時程式就不帶擷取地執行。事後空檔案會被刪掉，
rem 沒印任何東西的執行不會留下東西。
set "LOGFILE=%HERE%PowerShellMessages_%STAMP%.txt"
2>nul >"%LOGFILE%" type nul
if exist "%LOGFILE%" goto :run_captured
set "LOGFILE=%TEMP%\NetworkHealthCheck_PowerShellMessages_%STAMP%.txt"
2>nul >"%LOGFILE%" type nul
if exist "%LOGFILE%" goto :run_captured
set "LOGFILE="
"%PS_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -ConsoleOnly
goto :ran
:run_captured
"%PS_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -ConsoleOnly 2>>"%LOGFILE%"
:ran
set "RC=%ERRORLEVEL%"
if defined LOGFILE if exist "%LOGFILE%" for %%F in ("%LOGFILE%") do if "%%~zF"=="0" del "%LOGFILE%" 2>nul
if defined LOGFILE if exist "%LOGFILE%" set "LOGKEPT=1"

if "%RC%"=="3" (
    set "FAIL_REASON=檢測程式結束代碼為 3，這是程式在 PowerShell 被應用程式控制政策限制在受限語言模式時使用的代碼：沒有任何檢測執行。"
    set "SUGGESTED=請閱讀本資料夾或 Windows 暫存資料夾中的 NetworkHealthCheck_ENVIRONMENT_*.txt，裡面寫明 IT 可以怎麼做，並連同支援請求一起送出。"
    goto :launcher_error
)
if not "%RC%"=="0" goto :blocked
echo.
echo 網路健康檢查已完成。
echo 結束代碼：0
pause
exit /b 0

:blocked
set "FAIL_REASON=檢測程式結束代碼為 %RC%。PowerShell 或公司安全政策可能阻擋執行。"
if defined LOGKEPT goto :blocked_with_messages
set "SUGGESTED=PowerShell 沒有印出任何說明。請把這份錯誤報告連同支援請求一起送出，並描述視窗顯示了什麼；若程式檔未經數位簽署或被原則封鎖，需要 IT 允許 NetworkHealthCheck.ps1。"
goto :launcher_error
:blocked_with_messages
set "SUGGESTED=PowerShell 自己的說明已印在下方，並保存在 %LOGFILE%，請把那個檔案連同這份錯誤報告一起送出。若訊息說檔案未經數位簽署或被原則封鎖，請 IT 允許 NetworkHealthCheck.ps1。"
goto :launcher_error

:launcher_error
rem 從這裡開始用延遲展開：下面印出的值帶著路徑，而路徑可能含有括號——瀏覽器第二次下載的 ZIP 會解到名稱後面多
rem 了 (1) 的資料夾——或 & 符號，兩者都會弄壞在解析前就展開值的那一行。這個標籤之前沒有任何一行印出值。
setlocal EnableDelayedExpansion
set "ERRFILE=!HERE!LauncherError_!STAMP!.txt"
call :write_error_report 2>nul
if exist "!ERRFILE!" goto :show_launcher_error
set "ERRFILE=!TEMP!\NetworkHealthCheck_LauncherError_!STAMP!.txt"
call :write_error_report 2>nul

:show_launcher_error
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
rem 一行寫一次、檔名帶戳記：再試一次就是另一個檔案，路徑裡的括號也不會像在括號區塊裡那樣讓寫入中途斷掉。
rem 啟動器旁邊和 Windows 暫存資料夾寫的是同樣的內容；呼叫端的 2>nul 讓被拒絕的寫入不出現在畫面上。
set "DATELINE=日期時間：!DATE! !TIME!"
if defined DATEFMT set "DATELINE=日期時間：!DATE! !TIME! （這台電腦的短日期格式：!DATEFMT!）"
set "LOGLINE=PowerShell 訊息：無，PowerShell 沒有啟動"
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
