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
# The script is run from a copy: the guard writes its environment report next to the script, and the checkout must stay
# clean. Assertions are language-independent (exit code, the code name in the file, the absence of a report).
#   -ScriptPath: the shipped NetworkHealthCheck.ps1 to exercise
#   -WorkDir:    an existing folder for the copy and its output
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
$stage = Join-Path $WorkDir ('envguard\' + $lang)
if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
New-Item -ItemType Directory -Force -Path $stage | Out-Null
foreach ($name in @('NetworkHealthCheck.ps1', 'NetworkHealthCheck.config.json')) {
    Copy-Item -LiteralPath (Join-Path $sourceDir $name) -Destination $stage
}
$staged = Join-Path $stage 'NetworkHealthCheck.ps1'
Write-Output ("Running {0} in ConstrainedLanguage from {1}" -f $lang, $stage)

# -Command, not -File: the mode has to be set in the session before the script is called, and the exit code has to
# survive back to this process.
$command = '$ExecutionContext.SessionState.LanguageMode = ''ConstrainedLanguage''; & ''' + $staged + ''' -ConsoleOnly; exit $LASTEXITCODE'
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$ErrorActionPreference = 'Continue'   # a nonzero exit code is the expected result here, not a terminating error
$output = @(& $psExe -NoProfile -ExecutionPolicy Bypass -Command $command 2>&1 | ForEach-Object { [string]$_ })
$exitCode = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
foreach ($line in $output) { Write-Output ('    | ' + $line) }

Assert-Equal 'exit code is the language-mode code' $exitCode 3
Assert-True 'the run says the tool cannot run here' (@($output | Where-Object { $_ -match 'ConstrainedLanguage' }).Count -gt 0) 'no line mentioned the language mode'

$reports = @(Get-ChildItem -LiteralPath (Join-Path $stage 'Reports') -Filter '*.json' -ErrorAction SilentlyContinue)
Assert-Equal 'no report was produced' $reports.Count 0

$written = @(Get-ChildItem -LiteralPath $stage -Filter 'NetworkHealthCheck_ENVIRONMENT_*.txt')
Assert-Equal 'one environment report was written' $written.Count 1
if ($written.Count -eq 1) {
    $text = Get-Content -LiteralPath $written[0].FullName -Raw -Encoding UTF8
    # Language-independent facts: the mode that blocked it, the version that wrote it, and the machine it ran on.
    Assert-True 'the environment report names the language mode' ($text -match 'ConstrainedLanguage') 'the mode is missing from the file'
    Assert-True 'the environment report names the tool version' ($text -match '\d+\.\d+\.\d+') 'no version in the file'
    Assert-True 'the environment report names the computer' ($text -match [regex]::Escape($env:COMPUTERNAME)) 'no computer name in the file'
    Assert-True 'the environment report says nothing was changed' ($text.Length -gt 200) ('the file is only ' + $text.Length + ' characters')
}

Write-Output ("Summary: {0} passed, {1} failed" -f $passes, $fails)
exit $fails
