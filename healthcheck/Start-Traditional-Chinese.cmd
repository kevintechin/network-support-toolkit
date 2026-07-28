@echo off
chcp 65001 >nul 2>&1
setlocal EnableExtensions
if not exist "%~dp0zh-TW\Start-NetworkCheck.cmd" (
  echo 錯誤：找不到 zh-TW 繁體中文套件。
  echo 請確認已完整解壓縮整個 ZIP。
  pause
  exit /b 1
)
call "%~dp0zh-TW\Start-NetworkCheck.cmd"
exit /b %ERRORLEVEL%
