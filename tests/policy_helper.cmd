@echo off
rem NetworkHealthCheck acceptance campaign - the elevated half of the policy scenarios (backlog #29).
rem
rem     policy_helper.cmd <commands.cmd> <result.txt> <sha256 of commands.cmd>
rem
rem The campaign runs unelevated on purpose - A1 measures what an ordinary user gets - so the machine changes of M7,
rem M8 and M9 are made here instead, started elevated for one step at a time (Start-Process -Verb RunAs) and gone
rem again when the step is over. It is a .cmd and not a .ps1 because of what it has to survive: under M7 every new
rem PowerShell is ConstrainedLanguage, and under M8 no unsigned script starts at all, so the way back must not need
rem PowerShell - the same reason RECOVER.txt is written before any policy is applied.
rem
rem What runs elevated is the file the campaign wrote and nothing else. The campaign's state lives under
rem C:\Users\Public so that every account can reach it (PR #14), which means the account the campaign runs as can
rem write there too - so the marker below says only what shape a file has, and the digest the campaign passes is what
rem says it is the file the campaign meant. The digest is checked before anything is elevated, the file is then copied
rem into a folder this script makes fresh and locks to administrators, and the digest is checked again on that copy,
rem which is the one that runs (PR #67 rounds 1 and 2).
rem
rem The folder is made fresh on every step that brings its own file: %SystemRoot%\Temp is writable by ordinary users,
rem so a folder already there may have been made by one of them - with an explicit write entry of their own, which
rem icacls /grant:r would leave in place, and a file of their own already inside. It is refused when it is a reparse
rem point, removed, and made again by this elevated process, so that its permissions are the ones set below and
rem nothing in it predates this step. A step whose commands file is already inside that folder - M9's way back, staged
rem there before the policy it undoes was applied - is not touched: what protects it is its digest, recorded when the
rem campaign wrote it.
rem
rem What this is not: a security boundary. An account that can already rewrite the campaign's own driver decides what
rem the campaign asks for in the first place, and the acceptance machines are virtual machines the operator controls.
rem What it closes is the step between writing a commands file and running it.
setlocal
if "%~3"=="" goto :usage
if not exist "%~1" goto :nocommands
find /i "NHC-POLICY-STEP" "%~1" >nul 2>&1
if errorlevel 1 goto :notours
certutil -hashfile "%~1" SHA256 | find /i "%~3" >nul 2>&1
if errorlevel 1 goto :nodigest
rem Elevated, by either of two reads: net session needs the Server service, fsutil dirty needs administrator rights.
net session >nul 2>&1
if not errorlevel 1 goto :elevated
fsutil dirty query %SystemDrive% >nul 2>&1
if not errorlevel 1 goto :elevated
> "%~2" echo elevated=no
>> "%~2" echo result=FAILED
exit /b 5

:elevated
set "NHCSAFE=%SystemRoot%\Temp\nhc-policy"
set "NHCSTEP=%NHCSAFE%\step.cmd"
if /i "%~dp1"=="%NHCSAFE%\" goto :alreadythere
if not exist "%NHCSAFE%" goto :makesafe
rem A folder already there is one an ordinary user may have made: refused where it is a reparse point, because
rem removing one of those elevated is how a deletion is turned into somebody else's, and removed where it is not.
fsutil reparsepoint query "%NHCSAFE%" >nul 2>&1
if not errorlevel 1 goto :nosafe
rd /s /q "%NHCSAFE%"
if exist "%NHCSAFE%" goto :nosafe

:makesafe
md "%NHCSAFE%"
if not exist "%NHCSAFE%" goto :nosafe
rem Administrators and SYSTEM may write here; everyone else may read and run and nothing more. The folder was made by
rem this process a moment ago, so these three entries are the whole list and no other account has one.
icacls "%NHCSAFE%" /inheritance:r /grant:r "*S-1-5-32-544:(OI)(CI)F" /grant:r "*S-1-5-18:(OI)(CI)F" /grant:r "*S-1-5-32-545:(OI)(CI)RX" >nul 2>&1
if errorlevel 1 goto :nosafe
copy /y "%~1" "%NHCSTEP%" >nul
if not exist "%NHCSTEP%" goto :nosafe
goto :verify

:alreadythere
set "NHCSTEP=%~1"

:verify
certutil -hashfile "%NHCSTEP%" SHA256 | find /i "%~3" >nul 2>&1
if errorlevel 1 goto :nodigest
> "%~2" echo elevated=yes
>> "%~2" echo commands=%NHCSTEP%
call "%NHCSTEP%" >> "%~2" 2>&1
set NHCRC=%ERRORLEVEL%
>> "%~2" echo exitcode=%NHCRC%
if not "%NHCRC%"=="0" goto :failed
>> "%~2" echo result=OK
exit /b 0

:failed
>> "%~2" echo result=FAILED
exit /b %NHCRC%

:nodigest
> "%~2" echo elevated=not asked
>> "%~2" echo error=the commands file is not the one the campaign hashed
>> "%~2" echo result=FAILED
exit /b 4

:nosafe
> "%~2" echo elevated=yes
>> "%~2" echo error=the protected folder could not be made fresh and locked
>> "%~2" echo result=FAILED
exit /b 6

:notours
> "%~2" echo elevated=not asked
>> "%~2" echo error=the commands file does not carry the campaign's marker
>> "%~2" echo result=FAILED
exit /b 3

:nocommands
> "%~2" echo elevated=not asked
>> "%~2" echo error=no commands file at %~1
>> "%~2" echo result=FAILED
exit /b 2

:usage
echo usage: policy_helper.cmd ^<commands.cmd^> ^<result.txt^> ^<sha256 of commands.cmd^>
exit /b 2
