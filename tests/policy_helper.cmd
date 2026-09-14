@echo off
rem NetworkHealthCheck acceptance campaign - the elevated half of the policy scenarios (backlog #29).
rem
rem     policy_helper.cmd <commands.cmd> <result.txt>
rem
rem The campaign runs unelevated on purpose - A1 measures what an ordinary user gets - so the machine changes of M7,
rem M8 and M9 are made here instead, started elevated for one step at a time (Start-Process -Verb RunAs) and gone
rem again when the step is over. It is a .cmd and not a .ps1 because of what it has to survive: under M7 every new
rem PowerShell is ConstrainedLanguage, and under M8 no unsigned script starts at all, so the way back must not need
rem PowerShell - the same reason RECOVER.txt is written before any policy is applied.
rem
rem What it does: prove it is elevated, refuse a commands file the campaign did not write, run that file, and record
rem what happened in the result file the campaign reads. It decides nothing: the commands are the campaign's, and they
rem are the same lines the instructions and RECOVER.txt give a person.
setlocal
if "%~2"=="" goto :usage
if not exist "%~1" goto :nocommands
rem Only a file the campaign generated: every one of them carries this marker on its second line, and this helper runs
rem elevated, so a file that does not carry it is refused rather than run.
find /i "NHC-POLICY-STEP" "%~1" >nul 2>&1
if errorlevel 1 goto :notours
rem Elevated, by either of two reads: net session needs the Server service, fsutil dirty needs administrator rights.
net session >nul 2>&1
if not errorlevel 1 goto :elevated
fsutil dirty query %SystemDrive% >nul 2>&1
if not errorlevel 1 goto :elevated
> "%~2" echo elevated=no
>> "%~2" echo result=FAILED
exit /b 5

:elevated
> "%~2" echo elevated=yes
>> "%~2" echo commands=%~1
call "%~1" >> "%~2" 2>&1
set NHCRC=%ERRORLEVEL%
>> "%~2" echo exitcode=%NHCRC%
if not "%NHCRC%"=="0" goto :failed
>> "%~2" echo result=OK
exit /b 0

:failed
>> "%~2" echo result=FAILED
exit /b %NHCRC%

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
echo usage: policy_helper.cmd ^<commands.cmd^> ^<result.txt^>
exit /b 2
