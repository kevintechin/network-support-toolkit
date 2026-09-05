param([string]$ScriptPath, [string]$WorkDir)
# Backlog #18: the guard that runs before anything else in NetworkHealthCheck.ps1, checked by actually running the
# shipped script in a restricted language mode - the state an application-control policy (WDAC / AppLocker) puts
# PowerShell into, where a script may not create .NET objects and this one therefore cannot run at all.
#
# The session's language mode can be tightened from within PowerShell, so the case needs no locked-down machine: the
# child process sets ConstrainedLanguage and then calls the script, which runs inside that mode. That is a simulation,
# not the real thing - a genuine WDAC lockdown also changes module loading and trust - so what this proves is that the
# guard fires, explains itself and leaves evidence behind, not that every WDAC configuration behaves identically.
#
# Two scenarios, because they meet in the field: a locked-down machine is exactly where a user is likely to double-click
# straight out of the downloaded ZIP.
#   1. from a normal folder - the environment report is written next to the script;
#   2. from a path that looks like the Windows compressed-folder view (a real folder named like the Windows 10 view, and
#      one named like the Windows 11 view) - the report must go to the temporary folder instead, because the view
#      disappears and would take the only evidence with it (PR #8 round 1; the Windows 11 shape since backlog #26).
#
# The script is run from a copy, so the checkout stays clean, and the assertions are language-independent (exit code,
# the code name in the file, the absence of a report).
#   -ScriptPath: the shipped NetworkHealthCheck.ps1 to exercise
#   -WorkDir:    an existing folder for the copies and their output
# Example: tests\env_guard_check.ps1 -ScriptPath healthcheck\en-US\NetworkHealthCheck.ps1 -WorkDir $env:TEMP\nhc-envguard
$ErrorActionPreference = 'Stop'

$passes = 0
$fails = 0
function Assert-Equal($name, $actual, $expected) {
    if ("$actual" -eq "$expected") { $script:passes++; Write-Output "[PASS] $name -> $actual" }
    else { $script:fails++; Write-Output "[FAIL] $name -> got '$actual', expected '$expected'" }
}
function Assert-True($name, $condition, $detail) {
    if ($condition) { $script:passes++; Write-Output "[PASS] $name" }
    else { $script:fails++; Write-Output "[FAIL] $name -> $detail" }
}

$source = (Resolve-Path -LiteralPath $ScriptPath).Path
$sourceDir = Split-Path -Parent $source
$lang = Split-Path -Leaf $sourceDir
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

function New-Copy([string]$Destination) {
    if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    foreach ($name in @('NetworkHealthCheck.ps1', 'NetworkHealthCheck.config.json')) {
        Copy-Item -LiteralPath (Join-Path $sourceDir $name) -Destination $Destination
    }
    return (Join-Path $Destination 'NetworkHealthCheck.ps1')
}
function Invoke-Restricted([string]$Script) {
    # -Command, not -File: the mode has to be set in the session before the script is called, and the exit code has to
    # survive back to this process.
    $command = '$ExecutionContext.SessionState.LanguageMode = ''ConstrainedLanguage''; & ''' + $Script + ''' -ConsoleOnly; exit $LASTEXITCODE'
    $ErrorActionPreference = 'Continue'   # a nonzero exit code is the expected result here, not a terminating error
    $out = @(& $psExe -NoProfile -ExecutionPolicy Bypass -Command $command 2>&1 | ForEach-Object { [string]$_ })
    $code = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    foreach ($line in $out) { Write-Output ('    | ' + $line) }
    return @{ Output = $out; ExitCode = $code }
}

# -------------------- 1. a normal folder --------------------

$stage = Join-Path $WorkDir ('envguard\' + $lang)
$staged = New-Copy $stage
Write-Output ("Running {0} in ConstrainedLanguage from {1}" -f $lang, $stage)
$run = Invoke-Restricted $staged

Assert-Equal 'exit code is the language-mode code' $run.ExitCode 3
Assert-True 'the run says the tool cannot run here' (@($run.Output | Where-Object { $_ -match 'ConstrainedLanguage' }).Count -gt 0) 'no line mentioned the language mode'

$reports = @(Get-ChildItem -LiteralPath (Join-Path $stage 'Reports') -Filter '*.json' -ErrorAction SilentlyContinue)
Assert-Equal 'no report was produced' $reports.Count 0

$written = @(Get-ChildItem -LiteralPath $stage -Filter 'NetworkHealthCheck_ENVIRONMENT_*.txt')
Assert-Equal 'one environment report was written next to the script' $written.Count 1
if ($written.Count -eq 1) {
    $text = Get-Content -LiteralPath $written[0].FullName -Raw -Encoding UTF8
    # Language-independent facts: the mode that blocked it, the version that wrote it, and the machine it ran on.
    Assert-True 'the environment report names the language mode' ($text -match 'ConstrainedLanguage') 'the mode is missing from the file'
    Assert-True 'the environment report names the tool version' ($text -match '\d+\.\d+\.\d+') 'no version in the file'
    Assert-True 'the environment report names the computer' ($text -match [regex]::Escape($env:COMPUTERNAME)) 'no computer name in the file'
    Assert-True 'the environment report says nothing was changed' ($text.Length -gt 200) ('the file is only ' + $text.Length + ' characters')
}

# -------------------- 2. the compressed-folder view --------------------

# A real folder shaped like the path Windows uses for a ZIP opened in Explorer reproduces what Test-IsRunningFromArchive
# matches on. There are two shapes: %TEMP%\Temp1_<name>.zip\... on Windows 10 and %TEMP%\<guid>_<name>.zip.<hex>\... on
# Windows 11, where the suffix is a few hex digits (.684, .bc4 on the first campaign's VM) - the 1.2.2 pattern accepted
# the first only (backlog #26), so both run here.
# The zh-TW word for a compressed file is spelled as character codes so this file can stay ASCII: Windows
# PowerShell 5.1 reads a script without a byte-order mark in the system code page (the same reason gui_check.ps1
# spells its button names this way).
$archiveWord = [string]([char]0x58D3 + [char]0x7E2E)
$viewShapes = [ordered]@{
    'Windows 10' = 'Temp1_NetworkHealthCheck.zip'
    'Windows 11' = '388e11bd-2056-4e77-a266-27df0c2ad684_NetworkHealthCheck.zip.684'
}
foreach ($shape in $viewShapes.Keys) {
    $archiveStage = Join-Path $WorkDir ('envguard\' + $viewShapes[$shape] + '\' + $lang)
    $archiveStaged = New-Copy $archiveStage
    Write-Output ("Running {0} in ConstrainedLanguage from a {1} compressed-folder path: {2}" -f $lang, $shape, $archiveStage)
    $before = Get-Date
    $archiveRun = Invoke-Restricted $archiveStaged

    Assert-Equal "$shape view: exit code is the language-mode code" $archiveRun.ExitCode 3
    Assert-Equal "$shape view: nothing was written inside the view" (@(Get-ChildItem -LiteralPath $archiveStage -Filter 'NetworkHealthCheck_ENVIRONMENT_*.txt')).Count 0
    # The work dir itself lives under %TEMP%, so "the path mentions %TEMP%" would prove nothing; what matters is that the
    # path the user is told to send is not inside the view that is about to disappear: no line that names the report
    # may also name a view folder.
    Assert-Equal "$shape view: the reported path is not inside the view" (@($archiveRun.Output | Where-Object { $_ -match 'NetworkHealthCheck_ENVIRONMENT_' -and $_ -match '\.zip(\.[0-9a-f]+)?[\\/]' }).Count) 0
    Assert-True "$shape view: the output tells the user to extract the ZIP first" (@($archiveRun.Output | Where-Object { $_ -match ('ZIP|zip|' + $archiveWord) }).Count -gt 0) 'nothing in the output mentioned the compressed folder'

    $fallback = @(Get-ChildItem -LiteralPath $env:TEMP -Filter 'NetworkHealthCheck_ENVIRONMENT_*.txt' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $before })
    Assert-Equal "$shape view: the report went to the temporary folder instead" $fallback.Count 1
    foreach ($file in $fallback) { Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue }
}

Write-Output ("Summary: {0} passed, {1} failed" -f $passes, $fails)
exit $fails
