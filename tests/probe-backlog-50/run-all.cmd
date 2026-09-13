@echo off
rem Runs the five variants with their output captured, one log each, beside this file. The screen is the other half:
rem double-click each variant as well and photograph or screenshot what it prints, because a redirected run may not
rem take the path the console does.
setlocal
cd /d "%~dp0"
for %%V in (1-as-shipped 2-last-line-ascii 3-without-chcp 4-with-bom 5-halfwidth-colon) do (
    echo === %%V
    call "%%V.cmd" <nul > "%%V.log" 2>&1
    type "%%V.log"
)
ver > machine.txt
reg query "HKLM\SYSTEM\CurrentControlSet\Control\Nls\CodePage" /v ACP >> machine.txt
reg query "HKLM\SYSTEM\CurrentControlSet\Control\Nls\CodePage" /v OEMCP >> machine.txt
reg query "HKCU\Console" /v CodePage >> machine.txt 2>nul
echo Logs written: 1-as-shipped.log ... 5-halfwidth-colon.log, and machine.txt. Send the folder back.
pause
