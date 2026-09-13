@echo off
chcp 65001 >nul 2>&1
setlocal EnableExtensions
if not exist "%~dp0zh-TW\Start-NetworkCheck.cmd" (
  echo 錯誤：找不到 zh-TW 繁體中文套件。
  rem An ASCII line stands between the two echo lines on purpose (backlog #50): under `chcp 65001` cmd
  rem mis-reads the line after one carrying non-ASCII characters, and the line telling the reader what to
  rem do never reached the screen. Measured on 2026-09-13.
  echo 請確認已完整解壓縮整個 ZIP。
  pause
  exit /b 1
)
call "%~dp0zh-TW\Start-NetworkCheck.cmd"
exit /b %ERRORLEVEL%
