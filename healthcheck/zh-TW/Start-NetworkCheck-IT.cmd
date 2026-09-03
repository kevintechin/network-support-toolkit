@echo off
rem 免安裝啟動器：所有檔案留在本機，並記錄啟動階段錯誤。
chcp 65001 >nul 2>&1
setlocal EnableExtensions
cd /d "%~dp0"
title 網路健康檢查（IT）

set "SCRIPT=%~dp0NetworkHealthCheck.ps1"
set "PS_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "FAIL_REASON="

if not exist "%SCRIPT%" (
    set "FAIL_REASON=找不到程式檔 NetworkHealthCheck.ps1。請將所有檔案放在同一個資料夾。"
    goto :launcher_error
)

if not exist "%PS_EXE%" (
    where pwsh.exe >nul 2>&1
    if errorlevel 1 (
        set "FAIL_REASON=此電腦找不到 PowerShell。"
        goto :launcher_error
    ) else (
        set "PS_EXE=pwsh.exe"
    )
)

"%PS_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File "%SCRIPT%" -Interactive -ExpandDetails
set "RC=%ERRORLEVEL%"

if not "%RC%"=="0" (
    set "FAIL_REASON=檢測程式結束代碼為 %RC%。PowerShell 或公司安全政策可能阻擋執行。"
    goto :launcher_error
)

exit /b 0

:launcher_error
set "ERRFILE=%~dp0LauncherError.txt"
>"%ERRFILE%" (
    echo 網路健康檢查啟動器錯誤
    echo ========================
    echo 日期時間：%DATE% %TIME%
    echo 電腦：%COMPUTERNAME%
    echo 使用者：%USERNAME%
    echo 資料夾：%~dp0
    echo 程式：%SCRIPT%
    echo PowerShell：%PS_EXE%
    echo.
    echo 錯誤：%FAIL_REASON%
    echo.
    echo 建議：請將完整 ZIP 解壓縮到本機資料夾，再執行 Start-NetworkCheck-IT.cmd。
) 2>nul

if exist "%ERRFILE%" goto :show_launcher_error

set "ERRFILE=%TEMP%\NetworkHealthCheck_LauncherError.txt"
>"%ERRFILE%" (
    echo 網路健康檢查啟動器錯誤
    echo 日期時間：%DATE% %TIME%
    echo 電腦：%COMPUTERNAME%
    echo 使用者：%USERNAME%
    echo 錯誤：%FAIL_REASON%
)

:show_launcher_error
echo.
echo 錯誤：%FAIL_REASON%
echo 錯誤報告："%ERRFILE%"
echo.
pause
exit /b 1
