param([string]$WorkDir, [switch]$Full)
# Backlog #24: the acceptance campaign driver's state machine, driven without a person through -Answers, on an asset
# built from this checkout with PowerShell alone. What is asserted:
#   1. a new campaign on scenarios whose preconditions this machine cannot meet (a 1366x768 screen under -SkipGui, a
#      host-only network, a disconnected adapter) records each as SKIPPED with the reason, writes campaign.json,
#      campaign_summary.md, answers.log and the bundle, and exits 0 - skips are not failures;
#   2. resuming the campaign leaves what was recorded alone (same finish time) and runs nothing again;
#   3. quit at a gate leaves that scenario and every later one PENDING, and the exit code counts them;
#   4. an unknown scenario id is refused;
#   5. a scenario whose action finds nothing (M1 without a compressed-folder run) is a FAIL that the exit code counts;
#   6. with -Full, the baseline A1 runs the acceptance runner for real (-SkipGui, about two minutes) and passes.
# The machine is expected to have a default gateway (a NAT or bridged network): A3 and A4 must be unmet here.
#   -WorkDir: an existing folder for the asset and the campaigns' state (default: %TEMP%\nhc-campaign-selftest\<time>)
$ErrorActionPreference = 'Stop'
$passes = 0
$fails = 0
function Assert-True($name, $condition, $detail) {
    if ($condition) { $script:passes++; Write-Output "[PASS] $name" }
    else { $script:fails++; Write-Output "[FAIL] $name -> $detail" }
}
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$tests = $PSScriptRoot
$root = (Resolve-Path -LiteralPath (Join-Path $tests '..')).Path
if (-not $WorkDir) { $WorkDir = Join-Path $env:TEMP ('nhc-campaign-selftest\' + (Get-Date -Format 'yyyyMMdd_HHmmss')) }
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
$WorkDir = (Resolve-Path -LiteralPath $WorkDir).Path

# An asset from the checkout, the way the package rule shapes it (one NetworkHealthCheck-<version>/ folder, the files
# under healthcheck/ except Reports/), with Compress-Archive - no Python here.
$version = 'unknown'
foreach ($line in [IO.File]::ReadLines((Join-Path $root 'healthcheck\en-US\NetworkHealthCheck.ps1'))) { if ($line -match '^\$script:ToolVersion\s*=\s*"([^"]+)"') { $version = $Matches[1]; break } }
$top = Join-Path $WorkDir ('NetworkHealthCheck-' + $version)
if (Test-Path -LiteralPath $top) { Remove-Item -LiteralPath $top -Recurse -Force }
Get-ChildItem -LiteralPath (Join-Path $root 'healthcheck') -Recurse -File | Where-Object { $_.FullName -notmatch '\\Reports\\' -and $_.Name -ne 'LauncherError.txt' -and $_.Name -notlike 'NetworkHealthCheck_*_*.txt' } | ForEach-Object {
    $rel = $_.FullName.Substring((Join-Path $root 'healthcheck').Length).TrimStart('\')
    $target = Join-Path $top $rel
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
    Copy-Item -LiteralPath $_.FullName -Destination $target
}
$zip = Join-Path $WorkDir ('NetworkHealthCheck-' + $version + '.zip')
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
Compress-Archive -Path $top -DestinationPath $zip
Write-Output ('asset for the self-test: ' + $zip)

function Invoke-Campaign([string]$Name, [string[]]$Arguments, [string]$AnswersText) {
    # One invocation of the driver with its own state folder under the work dir and an answers file; returns the
    # output lines, the exit code and the state folder.
    $state = Join-Path $WorkDir ('state-' + $Name)
    $answers = Join-Path $WorkDir ('answers-' + $Name + '.txt')
    [IO.File]::WriteAllText($answers, $AnswersText, (New-Object System.Text.UTF8Encoding($false)))
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $tests 'Invoke-AcceptanceCampaign.ps1'), '-Campaign', ('selftest-' + $Name), '-StateDir', $state, '-Answers', $answers) + $Arguments
    $ErrorActionPreference = 'Continue'
    $out = @(& $psExe @argList 2>&1 | ForEach-Object { [string]$_ })
    $code = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    foreach ($l in $out) { Write-Output ('    | ' + $l) }
    return @{ Output = $out; ExitCode = $code; State = $state }
}
function Read-State([string]$State) { Get-Content -LiteralPath (Join-Path $State 'campaign.json') -Raw -Encoding UTF8 | ConvertFrom-Json }

# -------------------- 1. preconditions this machine cannot meet --------------------
Write-Output ''
Write-Output '1. a new campaign on M4, A3, A4 (-SkipGui, gates answered done): every one SKIPPED, exit 0'
$r1 = Invoke-Campaign 'skips' @('-Zip', $zip, '-Scenarios', 'M4,A3,A4', '-SkipGui') "M4=done`r`nA3=done`r`nA4=done`r`n"
Assert-True '1. exit code 0 (skips are not failures)' ($r1.ExitCode -eq 0) ('exit code ' + $r1.ExitCode)
$s1 = Read-State $r1.State
Assert-True '1. M4 SKIPPED by -SkipGui' ($s1.Scenarios.M4.Result -eq 'SKIPPED' -and $s1.Scenarios.M4.Detail -eq '-SkipGui') ($s1.Scenarios.M4.Result + ' / ' + $s1.Scenarios.M4.Detail)
Assert-True '1. A3 SKIPPED, precondition not met (this machine has a gateway)' ($s1.Scenarios.A3.Result -eq 'SKIPPED' -and $s1.Scenarios.A3.Detail -like 'precondition not met:*') ($s1.Scenarios.A3.Result + ' / ' + $s1.Scenarios.A3.Detail)
Assert-True '1. A4 SKIPPED, precondition not met (adapters have addresses)' ($s1.Scenarios.A4.Result -eq 'SKIPPED' -and $s1.Scenarios.A4.Detail -like 'precondition not met:*') ($s1.Scenarios.A4.Result + ' / ' + $s1.Scenarios.A4.Detail)
Assert-True '1. A3 and A4, skipped after an attempt, went through the revert check (a gateway is present, so it verifies)' ($s1.Scenarios.A3.Reverted -like 'yes - *gateway*' -and $s1.Scenarios.A4.Reverted -like 'yes - *gateway*') ($s1.Scenarios.A3.Reverted + ' / ' + $s1.Scenarios.A4.Reverted)
Assert-True '1. A1 (not selected) has no result' (-not $s1.Scenarios.A1.Result) ('A1: ' + $s1.Scenarios.A1.Result)
Assert-True '1. the asset was copied and the package extracted into the state' ((Test-Path -LiteralPath $s1.ZipCopy) -and (Test-Path -LiteralPath (Join-Path $s1.PackageRoot 'en-US\NetworkHealthCheck.ps1'))) ($s1.ZipCopy + ' / ' + $s1.PackageRoot)
Assert-True '1. tests\ was copied into the state for other sessions' (Test-Path -LiteralPath (Join-Path $s1.TestsCopy 'Invoke-AcceptanceCampaign.ps1')) $s1.TestsCopy
$gates = @(Get-Content -LiteralPath (Join-Path $r1.State 'answers.log') | Where-Object { $_ -match '/gate = done$' })
Assert-True '1. answers.log has the two gate answers (M4 was dropped by -SkipGui before its gate)' ($gates.Count -eq 2 -and @($gates | Where-Object { $_ -match ' M4/' }).Count -eq 0) ($gates -join ' / ')
$summary1 = Get-Content -LiteralPath (Join-Path $r1.State 'campaign_summary.md') -Raw -Encoding UTF8
Assert-True '1. campaign_summary.md ends with 0 passed, 0 failed, 3 skipped and the rest pending' ($summary1 -match 'Summary: 0 passed, 0 failed, 3 skipped, 8 pending') (($summary1 -split "`n")[-1])
$bundle1 = @(Get-ChildItem -LiteralPath $r1.State -Filter 'nhc-campaign_*.zip')
Assert-True '1. the campaign bundle was written under a time-stamped name, and the summary names it' ($bundle1.Count -eq 1 -and $bundle1[0].Name -match '^nhc-campaign_.+_\d{8}_\d{6}\.zip$' -and $summary1 -match ('- Bundle: ' + [regex]::Escape($bundle1[0].Name))) ('bundles: ' + (($bundle1 | ForEach-Object { $_.Name }) -join ', '))

# -------------------- 2. resume leaves the record alone --------------------
Write-Output ''
Write-Output '2. resume the same campaign on A3: recorded earlier, nothing runs, the finish time is unchanged'
$finishedBefore = $s1.Scenarios.A3.Finished
Start-Sleep -Seconds 1
$r2 = Invoke-Campaign 'skips' @('-Resume', '-Scenarios', 'A3', '-SkipGui') "A3=done`r`n"
$s2 = Read-State $r2.State
Assert-True '2. exit code 0' ($r2.ExitCode -eq 0) ('exit code ' + $r2.ExitCode)
Assert-True '2. A3 reported as recorded earlier' (@($r2.Output | Where-Object { $_ -match '^\[SKIPPED\] A3: recorded earlier' }).Count -eq 1) (($r2.Output | Where-Object { $_ -match 'A3' }) -join ' / ')
Assert-True '2. A3 finish time unchanged' ($s2.Scenarios.A3.Finished -eq $finishedBefore) ($finishedBefore + ' -> ' + $s2.Scenarios.A3.Finished)
Assert-True '2. the resumed invocation is in the event log' (@($s2.Events | Where-Object { $_.Text -like 'invocation by*scenarios A3*' }).Count -eq 1) (($s2.Events | ForEach-Object { $_.Text }) -join ' / ')

# -------------------- 3. quit --------------------
Write-Output ''
Write-Output '3. quit at the A3 gate: A3 and A4 PENDING, exit code 2'
$r3 = Invoke-Campaign 'quit' @('-Zip', $zip, '-Scenarios', 'A3,A4', '-SkipGui') "A3=quit`r`nA4=done`r`n"
$s3 = Read-State $r3.State
Assert-True '3. exit code 2 (two pending)' ($r3.ExitCode -eq 2) ('exit code ' + $r3.ExitCode)
Assert-True '3. A3 PENDING, quit by the user' ($s3.Scenarios.A3.Result -eq 'PENDING' -and $s3.Scenarios.A3.Detail -eq 'quit by the user') ($s3.Scenarios.A3.Result + ' / ' + $s3.Scenarios.A3.Detail)
Assert-True '3. A4 PENDING, not reached' ($s3.Scenarios.A4.Result -eq 'PENDING' -and $s3.Scenarios.A4.Detail -like 'not reached*') ($s3.Scenarios.A4.Result + ' / ' + $s3.Scenarios.A4.Detail)
Assert-True '3. the resume command is printed with the same subset' (@($r3.Output | Where-Object { $_ -match 'Invoke-AcceptanceCampaign\.ps1.*-Resume -Scenarios A3,A4' }).Count -ge 1) (($r3.Output | Select-Object -Last 3) -join ' / ')

# -------------------- 4. an unknown scenario --------------------
Write-Output ''
Write-Output '4. an unknown scenario id is refused'
$r4 = Invoke-Campaign 'unknown' @('-Zip', $zip, '-Scenarios', 'A3,X9', '-SkipGui') ""
Assert-True '4. nonzero exit code' ($r4.ExitCode -ne 0) ('exit code ' + $r4.ExitCode)
Assert-True '4. the message names the unknown id' (@($r4.Output | Where-Object { $_ -match 'unknown scenario\(s\): X9' }).Count -ge 1) (($r4.Output | Select-Object -First 3) -join ' / ')

# -------------------- 5. a failing scenario --------------------
Write-Output ''
Write-Output '5. M1 answered done with no compressed-folder run: FAIL, exit code 1'
# %TEMP% is redirected to an empty folder for the duration: the driver looks for compressed-folder view folders there, and
# a view left on the machine by something else must not decide this case (the same redirection serves case 26).
$tempSave = $env:TEMP
$env:TEMP = (New-Item -ItemType Directory -Force -Path (Join-Path $WorkDir 'temp-5')).FullName
try { $r5 = Invoke-Campaign 'fail' @('-Zip', $zip, '-Scenarios', 'M1') "M1=done`r`n" } finally { $env:TEMP = $tempSave }
$s5 = Read-State $r5.State
Assert-True '5. exit code 1' ($r5.ExitCode -eq 1) ('exit code ' + $r5.ExitCode)
Assert-True '5. M1 FAIL with the reason' ($s5.Scenarios.M1.Result -eq 'FAIL' -and $s5.Scenarios.M1.Detail -like 'nothing from a compressed-folder view under*') ($s5.Scenarios.M1.Result + ' / ' + $s5.Scenarios.M1.Detail)
Assert-True '5. the summary counts one failure' ((Get-Content -LiteralPath (Join-Path $r5.State 'campaign_summary.md') -Raw) -match 'Summary: 0 passed, 1 failed, 0 skipped, 10 pending') 'summary line'

# -------------------- 7. a scenario that changed the machine is final only once the change is verified gone --------------------
Write-Output ''
Write-Output '7. A4 recorded as run but not reverted (a crafted state): quit at the revert keeps it PENDING and counts; done with the gateway back makes it PASS'
$stateFile = Join-Path $r3.State 'campaign.json'
$crafted = Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
$crafted.Scenarios.A4.Result = 'PENDING'
$crafted.Scenarios.A4.ActionResult = 'PASS'
$crafted.Scenarios.A4.ActionDetail = 'exit code 0; Summary: 24 passed (crafted by the self-test)'
$crafted.Scenarios.A4.Detail = 'ran (PASS); the change is still to be reverted (crafted by the self-test)'
[IO.File]::WriteAllText($stateFile, ($crafted | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding($false)))
$r7a = Invoke-Campaign 'quit' @('-Resume', '-Scenarios', 'A4', '-SkipGui') "A4/revert=quit`r`n"
$s7a = Read-State $r7a.State
Assert-True '7a. the action is not run again (the resume goes straight to the revert)' (@($r7a.Output | Where-Object { $_ -match 'the scenario ran earlier \(PASS' }).Count -eq 1) (($r7a.Output | Where-Object { $_ -match 'A4' }) -join ' / ')
Assert-True '7a. quit at the revert: A4 stays PENDING, not reverted' ($s7a.Scenarios.A4.Result -eq 'PENDING' -and $s7a.Scenarios.A4.Detail -like '*NOT REVERTED - quit*' -and $s7a.Scenarios.A4.Reverted -eq 'NOT REVERTED - quit') ($s7a.Scenarios.A4.Result + ' / ' + $s7a.Scenarios.A4.Detail + ' / ' + $s7a.Scenarios.A4.Reverted)
Assert-True '7a. exit code 1 (the machine is still changed)' ($r7a.ExitCode -eq 1) ('exit code ' + $r7a.ExitCode)
$r7b = Invoke-Campaign 'quit' @('-Resume', '-Scenarios', 'A4', '-SkipGui') "A4/revert=done`r`n"
$s7b = Read-State $r7b.State
Assert-True '7b. done with a gateway present: the revert is verified and A4 takes the action outcome' ($s7b.Scenarios.A4.Result -eq 'PASS' -and $s7b.Scenarios.A4.Reverted -like 'yes - *gateway*') ($s7b.Scenarios.A4.Result + ' / ' + $s7b.Scenarios.A4.Reverted)
Assert-True '7b. the final detail is the scenario''s own, not the pending text' ($s7b.Scenarios.A4.Detail -eq 'exit code 0; Summary: 24 passed (crafted by the self-test)') $s7b.Scenarios.A4.Detail
Assert-True '7b. the revert is in the event log' (@($s7b.Events | Where-Object { $_.Text -like 'A4: reverted*' }).Count -ge 1) (($s7b.Events | ForEach-Object { $_.Text }) -join ' / ')
Assert-True '7b. exit code 0' ($r7b.ExitCode -eq 0) ('exit code ' + $r7b.ExitCode)

# -------------------- 8. the facts recorded before a change survive a resume --------------------
Write-Output ''
Write-Output '8. M4 left at its gate with the screen size recorded (a crafted state): a resume keeps that record instead of measuring the changed machine'
$stateFile8 = Join-Path $r3.State 'campaign.json'
$crafted8 = Get-Content -LiteralPath $stateFile8 -Raw -Encoding UTF8 | ConvertFrom-Json
$crafted8.Scenarios.M4.Result = 'PENDING'
$crafted8.Scenarios.M4.Detail = 'quit by the user (crafted by the self-test)'
$crafted8.Scenarios.M4.Facts = [pscustomobject]@{ ScreenBefore = '1111x999' }
$crafted8.SkipGui = $false   # the campaign was started with -SkipGui; M4 must reach its gate here (the quit comes before any window)
[IO.File]::WriteAllText($stateFile8, ($crafted8 | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding($false)))
$r8 = Invoke-Campaign 'quit' @('-Resume', '-Scenarios', 'M4') "M4=quit`r`n"
$s8 = Read-State $r8.State
Assert-True '8. the recorded facts are kept (not measured again)' ([string]$s8.Scenarios.M4.Facts.ScreenBefore -eq '1111x999') ('ScreenBefore: ' + $s8.Scenarios.M4.Facts.ScreenBefore)
Assert-True '8. the driver says so' (@($r8.Output | Where-Object { $_ -match 'facts recorded earlier are kept: ScreenBefore=1111x999' }).Count -eq 1) (($r8.Output | Where-Object { $_ -match 'facts' }) -join ' / ')
Assert-True '8. M4 stays PENDING after the quit' ($s8.Scenarios.M4.Result -eq 'PENDING') $s8.Scenarios.M4.Result

# -------------------- 9. a skip before any attempt needs no revert --------------------
Write-Output ''
Write-Output '9. A4 skipped at its gate without an attempt: SKIPPED by the user, no revert asked, exit 0'
$r9 = Invoke-Campaign 'skip-first' @('-Zip', $zip, '-Scenarios', 'A4', '-SkipGui') "A4=skip`r`n"
$s9 = Read-State $r9.State
Assert-True '9. A4 SKIPPED by the user' ($s9.Scenarios.A4.Result -eq 'SKIPPED' -and $s9.Scenarios.A4.Detail -eq 'skipped by the user') ($s9.Scenarios.A4.Result + ' / ' + $s9.Scenarios.A4.Detail)
Assert-True '9. no revert was asked (nothing was attempted)' (-not $s9.Scenarios.A4.Reverted -and @(Get-Content -LiteralPath (Join-Path $r9.State 'answers.log') | Where-Object { $_ -match '/revert' }).Count -eq 0) ('Reverted: ' + $s9.Scenarios.A4.Reverted)
Assert-True '9. exit code 0' ($r9.ExitCode -eq 0) ('exit code ' + $r9.ExitCode)

# -------------------- 10. an attempt survives a quit --------------------
Write-Output ''
Write-Output '10. A4 quit at its gate after a done (a crafted state, Attempted): a skip on resume goes through the revert check'
$stateFile10 = Join-Path $r3.State 'campaign.json'
$crafted10 = Get-Content -LiteralPath $stateFile10 -Raw -Encoding UTF8 | ConvertFrom-Json
$crafted10.Scenarios.A4.Result = 'PENDING'
$crafted10.Scenarios.A4.Detail = 'quit by the user after an attempt (crafted by the self-test)'
$crafted10.Scenarios.A4.ActionResult = ''
$crafted10.Scenarios.A4.ActionDetail = ''
$crafted10.Scenarios.A4.Reverted = ''
$crafted10.Scenarios.A4.Attempted = $true
[IO.File]::WriteAllText($stateFile10, ($crafted10 | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding($false)))
$r10 = Invoke-Campaign 'quit' @('-Resume', '-Scenarios', 'A4', '-SkipGui') "A4=skip`r`n"
$s10 = Read-State $r10.State
Assert-True '10. the skip after a remembered attempt went through the revert check' ($s10.Scenarios.A4.Result -eq 'SKIPPED' -and $s10.Scenarios.A4.Reverted -like 'yes - *gateway*') ($s10.Scenarios.A4.Result + ' / ' + $s10.Scenarios.A4.Reverted)
Assert-True '10. the revert was asked' (@(Get-Content -LiteralPath (Join-Path $r10.State 'answers.log') | Where-Object { $_ -match ' A4/revert = ' }).Count -ge 1) 'answers.log'
Assert-True '10. exit code 0' ($r10.ExitCode -eq 0) ('exit code ' + $r10.ExitCode)

# -------------------- 11. the way back without PowerShell --------------------
Write-Output ''
Write-Output '11. RECOVER.txt and undo-M7.cmd are written at the start of a campaign, before any policy is applied'
$recover = Get-Content -LiteralPath (Join-Path $r1.State 'RECOVER.txt') -Raw -Encoding UTF8
Assert-True '11. RECOVER.txt names the M7 undo, the M8 gpedit path, the M9 secpol path and the resume command' (($recover -match 'reg delete "HKLM\\SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Environment" /v __PSLockdownPolicy /f') -and ($recover -match 'gpedit\.msc') -and ($recover -match 'secpol\.msc') -and ($recover -match 'Invoke-AcceptanceCampaign\.ps1.*-Resume')) (($recover -split "`n" | Select-Object -First 6) -join ' / ')
$undo = Get-Content -LiteralPath (Join-Path $r1.State 'undo-M7.cmd') -Raw
Assert-True '11. undo-M7.cmd is a plain cmd file with the reg delete and no PowerShell invocation' (($undo -match '^@echo off') -and ($undo -match 'reg delete "HKLM\\SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Environment" /v __PSLockdownPolicy /f') -and ($undo -notmatch '(?im)^\s*(powershell|pwsh)\b') -and ($undo -notmatch '-ExecutionPolicy|-Command ')) ($undo -replace "`r?`n", ' / ')

# -------------------- 12. a resume under ConstrainedLanguage stops at the door --------------------
Write-Output ''
Write-Output '12. resumed in ConstrainedLanguage (what M7 leaves behind): exit 3 and the recovery notes named, not a New-Object failure'
$driver = Join-Path $tests 'Invoke-AcceptanceCampaign.ps1'
$command = '$ExecutionContext.SessionState.LanguageMode = ''ConstrainedLanguage''; & ''' + $driver + ''' -Campaign selftest-skips -StateDir ''' + $r1.State + ''' -Resume -Scenarios A3; exit $LASTEXITCODE'
$ErrorActionPreference = 'Continue'
$out12 = @(& $psExe -NoProfile -ExecutionPolicy Bypass -Command $command 2>&1 | ForEach-Object { [string]$_ })
$code12 = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
foreach ($l in $out12) { Write-Output ('    | ' + $l) }
Assert-True '12. exit code 3' ($code12 -eq 3) ('exit code ' + $code12)
Assert-True '12. the output names ConstrainedLanguage and RECOVER.txt, and no New-Object error' ((@($out12 | Where-Object { $_ -match 'ConstrainedLanguage' -and $_ -match 'cannot run or resume' }).Count -ge 1) -and (@($out12 | Where-Object { $_ -match 'RECOVER\.txt' }).Count -ge 1) -and (@($out12 | Where-Object { $_ -match 'New-Object' }).Count -eq 0)) ($out12 -join ' / ')

# -------------------- 13. answers are matched case-insensitively, and a typo is never a skip --------------------
Write-Output ''
Write-Output '13. A4=DONE counts as done (then the precondition decides); A4=dnoe is refused: PENDING, exit 1'
$r13a = Invoke-Campaign 'answers-a' @('-Zip', $zip, '-Scenarios', 'A4', '-SkipGui') "A4=DONE`r`n"
$s13a = Read-State $r13a.State
Assert-True '13a. DONE was taken as done (the precondition ran and was not met)' ($s13a.Scenarios.A4.Result -eq 'SKIPPED' -and $s13a.Scenarios.A4.Detail -like 'precondition not met:*') ($s13a.Scenarios.A4.Result + ' / ' + $s13a.Scenarios.A4.Detail)
Assert-True '13a. the answer was recorded normalized' (@(Get-Content -LiteralPath (Join-Path $r13a.State 'answers.log') | Where-Object { $_ -match ' A4/gate = done$' }).Count -eq 1) (Get-Content -LiteralPath (Join-Path $r13a.State 'answers.log') -Raw)
$r13b = Invoke-Campaign 'answers-b' @('-Zip', $zip, '-Scenarios', 'A4', '-SkipGui') "A4=dnoe`r`n"
$s13b = Read-State $r13b.State
Assert-True '13b. dnoe is refused: PENDING with the answer named, nothing run' ($s13b.Scenarios.A4.Result -eq 'PENDING' -and $s13b.Scenarios.A4.Detail -like "unrecognized answer 'dnoe'*") ($s13b.Scenarios.A4.Result + ' / ' + $s13b.Scenarios.A4.Detail)
Assert-True '13b. exit code 1' ($r13b.ExitCode -eq 1) ('exit code ' + $r13b.ExitCode)

# -------------------- 14. an unconfirmed revert stops the campaign --------------------
Write-Output ''
Write-Output '14. A4 awaiting its revert (a crafted state) with an invalid revert answer, A4 and M7 selected: A4 PENDING, M7 not reached, exit 2'
$stateFile14 = Join-Path $r3.State 'campaign.json'
$crafted14 = Get-Content -LiteralPath $stateFile14 -Raw -Encoding UTF8 | ConvertFrom-Json
$crafted14.Scenarios.A4.Result = 'PENDING'
$crafted14.Scenarios.A4.Detail = 'ran (PASS); the change is still to be reverted (crafted by the self-test)'
$crafted14.Scenarios.A4.ActionResult = 'PASS'
$crafted14.Scenarios.A4.ActionDetail = 'exit code 0 (crafted)'
$crafted14.Scenarios.A4.Reverted = ''
$crafted14.Scenarios.M7.Result = ''
$crafted14.Scenarios.M7.Detail = ''
[IO.File]::WriteAllText($stateFile14, ($crafted14 | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding($false)))
$r14 = Invoke-Campaign 'quit' @('-Resume', '-Scenarios', 'A4,M7', '-SkipGui') "A4/revert=dnoe`r`nM7=done`r`n"
$s14 = Read-State $r14.State
Assert-True '14. A4 stays PENDING with the unrecognized revert answer named' ($s14.Scenarios.A4.Result -eq 'PENDING' -and $s14.Scenarios.A4.Detail -like "*unrecognized answer 'dnoe'*") ($s14.Scenarios.A4.Result + ' / ' + $s14.Scenarios.A4.Detail)
Assert-True '14. M7 was not reached: the campaign stopped at the unconfirmed revert' ($s14.Scenarios.M7.Result -eq 'PENDING' -and $s14.Scenarios.M7.Detail -like 'not reached*') ($s14.Scenarios.M7.Result + ' / ' + $s14.Scenarios.M7.Detail)
Assert-True '14. exit code 2' ($r14.ExitCode -eq 2) ('exit code ' + $r14.ExitCode)

# -------------------- 15. -SkipGui does not skip the revert of an attempted display scenario --------------------
Write-Output ''
Write-Output '15. M4 attempted earlier (a crafted state, its recorded size = the screen now), resumed with -SkipGui: the revert is verified, then SKIPPED, exit 0'
Add-Type -AssemblyName System.Windows.Forms
$bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$stateFile15 = Join-Path $r3.State 'campaign.json'
$crafted15 = Get-Content -LiteralPath $stateFile15 -Raw -Encoding UTF8 | ConvertFrom-Json
$crafted15.Scenarios.M4.Result = 'PENDING'
$crafted15.Scenarios.M4.Detail = 'quit by the user after an attempt (crafted by the self-test)'
$crafted15.Scenarios.M4.Attempted = $true
$crafted15.Scenarios.M4.ActionResult = ''
$crafted15.Scenarios.M4.Reverted = ''
$crafted15.Scenarios.M4.Facts = [pscustomobject]@{ ScreenBefore = ('{0}x{1}' -f $bounds.Width, $bounds.Height) }
[IO.File]::WriteAllText($stateFile15, ($crafted15 | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding($false)))
$r15 = Invoke-Campaign 'quit' @('-Resume', '-Scenarios', 'M4', '-SkipGui') "M4/revert=done`r`n"
$s15 = Read-State $r15.State
Assert-True '15. the revert was verified before the -SkipGui skip took effect' ($s15.Scenarios.M4.Result -eq 'SKIPPED' -and $s15.Scenarios.M4.Detail -eq '-SkipGui after an attempt' -and $s15.Scenarios.M4.Reverted -like 'yes - back at *') ($s15.Scenarios.M4.Result + ' / ' + $s15.Scenarios.M4.Detail + ' / ' + $s15.Scenarios.M4.Reverted)
Assert-True '15. exit code 0' ($r15.ExitCode -eq 0) ('exit code ' + $r15.ExitCode)

# -------------------- 16. an unrecognized gate answer after an attempt stops the campaign --------------------
Write-Output ''
Write-Output '16. A4 attempted earlier (a crafted state), A4=dnoe, A4 and M7 selected: A4 PENDING, M7 not reached, exit 2'
$stateFile16 = Join-Path $r3.State 'campaign.json'
$crafted16 = Get-Content -LiteralPath $stateFile16 -Raw -Encoding UTF8 | ConvertFrom-Json
$crafted16.Scenarios.A4.Result = 'PENDING'
$crafted16.Scenarios.A4.Detail = 'quit by the user after an attempt (crafted by the self-test)'
$crafted16.Scenarios.A4.Attempted = $true
$crafted16.Scenarios.A4.ActionResult = ''
$crafted16.Scenarios.A4.ActionDetail = ''
$crafted16.Scenarios.A4.Reverted = ''
$crafted16.Scenarios.M7.Result = ''
$crafted16.Scenarios.M7.Detail = ''
[IO.File]::WriteAllText($stateFile16, ($crafted16 | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding($false)))
$r16 = Invoke-Campaign 'quit' @('-Resume', '-Scenarios', 'A4,M7', '-SkipGui') "A4=dnoe`r`nM7=done`r`n"
$s16 = Read-State $r16.State
Assert-True '16. A4 PENDING, the answer named, the attempt acknowledged' ($s16.Scenarios.A4.Result -eq 'PENDING' -and $s16.Scenarios.A4.Detail -like "unrecognized answer 'dnoe'*after an attempt*") ($s16.Scenarios.A4.Result + ' / ' + $s16.Scenarios.A4.Detail)
Assert-True '16. M7 not reached' ($s16.Scenarios.M7.Result -eq 'PENDING' -and $s16.Scenarios.M7.Detail -like 'not reached*') ($s16.Scenarios.M7.Result + ' / ' + $s16.Scenarios.M7.Detail)
Assert-True '16. exit code 2' ($r16.ExitCode -eq 2) ('exit code ' + $r16.ExitCode)

# -------------------- 17. an outstanding revert comes first, whatever was selected --------------------
Write-Output ''
Write-Output '17. A4 awaiting its revert (a crafted state), only M7 selected: A4 is reverted first (PASS), then M7 runs (skipped), exit 0'
$stateFile17 = Join-Path $r3.State 'campaign.json'
$crafted17 = Get-Content -LiteralPath $stateFile17 -Raw -Encoding UTF8 | ConvertFrom-Json
$crafted17.Scenarios.A4.Result = 'PENDING'
$crafted17.Scenarios.A4.Detail = 'ran (PASS); the change is still to be reverted (crafted by the self-test)'
$crafted17.Scenarios.A4.ActionResult = 'PASS'
$crafted17.Scenarios.A4.ActionDetail = 'exit code 0 (crafted, case 17)'
$crafted17.Scenarios.A4.Attempted = $true
$crafted17.Scenarios.A4.Reverted = ''
$crafted17.Scenarios.M7.Result = ''
$crafted17.Scenarios.M7.Detail = ''
[IO.File]::WriteAllText($stateFile17, ($crafted17 | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding($false)))
$r17 = Invoke-Campaign 'quit' @('-Resume', '-Scenarios', 'M7', '-SkipGui') "A4/revert=done`r`nM7=skip`r`n"
$s17 = Read-State $r17.State
Assert-True '17. the driver announced the outstanding revert' (@($r17.Output | Where-Object { $_ -match 'Outstanding revert\(s\) first: A4' }).Count -eq 1) (($r17.Output | Where-Object { $_ -match 'Outstanding' }) -join ' / ')
Assert-True '17. A4 was reverted and finalized before M7 ran' ($s17.Scenarios.A4.Result -eq 'PASS' -and $s17.Scenarios.A4.Detail -eq 'exit code 0 (crafted, case 17)' -and $s17.Scenarios.A4.Reverted -like 'yes - *gateway*' -and $s17.Scenarios.M7.Result -eq 'SKIPPED') ($s17.Scenarios.A4.Result + ' / ' + $s17.Scenarios.A4.Reverted + ' / M7 ' + $s17.Scenarios.M7.Result)
Assert-True '17. exit code 0' ($r17.ExitCode -eq 0) ('exit code ' + $r17.ExitCode)

# -------------------- 18. the state is saved atomically --------------------
Write-Output ''
Write-Output '18. campaign.json.bak holds the previous version and parses; no campaign.json.tmp is left behind'
$bak = Join-Path $r3.State 'campaign.json.bak'
$bakOk = $false
try { $null = Get-Content -LiteralPath $bak -Raw -Encoding UTF8 | ConvertFrom-Json; $bakOk = $true } catch { }
Assert-True '18. campaign.json.bak exists and is valid JSON' ((Test-Path -LiteralPath $bak) -and $bakOk) $bak
Assert-True '18. no temporary state file remains' (-not (Test-Path -LiteralPath (Join-Path $r3.State 'campaign.json.tmp'))) 'campaign.json.tmp present'

# -------------------- 19. a prerequisite is checked before anyone is asked to act --------------------
Write-Output ''
Write-Output '19. M2 on a download without the Mark of the Web (the self-test asset is built, not downloaded): SKIPPED before the instruction, exit 0'
$r19 = Invoke-Campaign 'prereq' @('-Zip', $zip, '-Scenarios', 'M2') "M2=done`r`n"
$s19 = Read-State $r19.State
Assert-True '19. M2 SKIPPED with the prerequisite named' ($s19.Scenarios.M2.Result -eq 'SKIPPED' -and $s19.Scenarios.M2.Detail -like 'prerequisite not met: the download carries no Internet-zone Mark of the Web*') ($s19.Scenarios.M2.Result + ' / ' + $s19.Scenarios.M2.Detail)
Assert-True '19. no gate was asked and the exit code is 0' ((@(Get-Content -LiteralPath (Join-Path $r19.State 'answers.log') -ErrorAction SilentlyContinue | Where-Object { $_ -match ' M2/' }).Count -eq 0) -and $r19.ExitCode -eq 0) ('exit code ' + $r19.ExitCode)

# -------------------- 20. a prerequisite is checked again when an attempted scenario resumes --------------------
Write-Output ''
Write-Output '20. M2 attempted earlier (a crafted state) on a download without the mark: the resume rechecks and skips, exit 0'
$stateFile20 = Join-Path $r19.State 'campaign.json'
$crafted20 = Get-Content -LiteralPath $stateFile20 -Raw -Encoding UTF8 | ConvertFrom-Json
$crafted20.Scenarios.M2.Result = 'PENDING'
$crafted20.Scenarios.M2.Detail = 'quit by the user after an attempt (crafted by the self-test)'
$crafted20.Scenarios.M2.Attempted = $true
[IO.File]::WriteAllText($stateFile20, ($crafted20 | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding($false)))
$r20 = Invoke-Campaign 'prereq' @('-Resume', '-Scenarios', 'M2') "M2=done`r`n"
$s20 = Read-State $r20.State
Assert-True '20. M2 SKIPPED on the recheck despite the earlier attempt' ($s20.Scenarios.M2.Result -eq 'SKIPPED' -and $s20.Scenarios.M2.Detail -like 'prerequisite not met:*') ($s20.Scenarios.M2.Result + ' / ' + $s20.Scenarios.M2.Detail)
Assert-True '20. exit code 0' ($r20.ExitCode -eq 0) ('exit code ' + $r20.ExitCode)

# -------------------- 21. M2 runs on a marked download and fails without a report --------------------
Write-Output ''
Write-Output '21. M2 on a copy of the asset given a Mark of the Web, extracted as asked but the launcher never run: the prompts run, a screenshot is taken, FAIL for the missing report, exit 1'
$zipMarked = Join-Path $WorkDir ('NetworkHealthCheck-' + $version + '-marked.zip')
Copy-Item -LiteralPath $zip -Destination $zipMarked -Force
Set-Content -LiteralPath $zipMarked -Stream Zone.Identifier -Value "[ZoneTransfer]`r`nZoneId=3"
# The extraction the scenario asks for is made under a work root of the self-test's own, so that the precondition passes
# and the real desktop is left alone (PR #14): the built package tree under NHC-M2, the launcher included.
function Set-ExtractedLater([string]$Root) {
    # An extraction made before the driver starts would be refused as stale (the folder was written before the scenario
    # started), so the self-test stamps the folder as written a few minutes from now - the person extracts after the
    # instruction, the self-test cannot. The folder, not the files: Windows 11's extraction gives the files the archive's
    # timestamps, which is why the driver reads the folder.
    (Get-Item -LiteralPath $Root).LastWriteTime = (Get-Date).AddMinutes(5)
}
$desk21 = Join-Path $WorkDir 'desk21'
New-Item -ItemType Directory -Force -Path (Join-Path $desk21 'NHC-M2') | Out-Null
Copy-Item -LiteralPath $top -Destination (Join-Path $desk21 'NHC-M2') -Recurse -Force
Set-ExtractedLater (Join-Path $desk21 'NHC-M2')
$r21 = Invoke-Campaign 'marked' @('-Zip', $zipMarked, '-Scenarios', 'M2', '-WorkRoot', $desk21) "M2=done`r`nM2/windows-showed=3`r`nM2/run-finished=done`r`n"
$s21 = Read-State $r21.State
Assert-True '21. M2 FAIL for the missing extraction and report, with the marks recorded' ($s21.Scenarios.M2.Result -eq 'FAIL' -and $s21.Scenarios.M2.Detail -like '*no en-US report*' -and $s21.Scenarios.M2.Detail -like '*download mark: ZoneId=3*') ($s21.Scenarios.M2.Result + ' / ' + $s21.Scenarios.M2.Detail)
Assert-True '21. the screenshot was taken and the observation recorded' ((Test-Path -LiteralPath (Join-Path $r21.State 'M2\M2_after_double-click.png')) -and (@(Get-Content -LiteralPath (Join-Path $r21.State 'answers.log') | Where-Object { $_ -match ' M2/windows-showed = 3$' }).Count -eq 1)) 'screenshot or answer missing'
Assert-True '21. exit code 1' ($r21.ExitCode -eq 1) ('exit code ' + $r21.ExitCode)

# -------------------- 22. -SkipGui drops every desktop scenario --------------------
Write-Output ''
Write-Output '22. M1, M2 and M3 under -SkipGui: all SKIPPED by -SkipGui, no prompt, exit 0'
$r22 = Invoke-Campaign 'nodesk' @('-Zip', $zip, '-Scenarios', 'M1,M2,M3', '-SkipGui') "M1=done`r`nM2=done`r`nM3=done`r`n"
$s22 = Read-State $r22.State
Assert-True '22. M1, M2, M3 SKIPPED by -SkipGui' ($s22.Scenarios.M1.Detail -eq '-SkipGui' -and $s22.Scenarios.M2.Detail -eq '-SkipGui' -and $s22.Scenarios.M3.Detail -eq '-SkipGui' -and $s22.Scenarios.M1.Result -eq 'SKIPPED') ($s22.Scenarios.M1.Detail + ' / ' + $s22.Scenarios.M2.Detail + ' / ' + $s22.Scenarios.M3.Detail)
Assert-True '22. no gate was asked and the exit code is 0' ((-not (Test-Path -LiteralPath (Join-Path $r22.State 'answers.log'))) -and $r22.ExitCode -eq 0) ('exit code ' + $r22.ExitCode)

# -------------------- 23. only an Internet or Restricted zone counts as the mark --------------------
Write-Output ''
Write-Output '23. M2 on a copy of the asset marked ZoneId=0 (local machine): the prerequisite refuses it, exit 0'
$zipLocal = Join-Path $WorkDir ('NetworkHealthCheck-' + $version + '-zone0.zip')
Copy-Item -LiteralPath $zip -Destination $zipLocal -Force
Set-Content -LiteralPath $zipLocal -Stream Zone.Identifier -Value "[ZoneTransfer]`r`nZoneId=0"
$r23 = Invoke-Campaign 'zone0' @('-Zip', $zipLocal, '-Scenarios', 'M2') "M2=done`r`n"
$s23 = Read-State $r23.State
Assert-True '23. M2 SKIPPED: ZoneId=0 is not an Internet-zone mark' ($s23.Scenarios.M2.Result -eq 'SKIPPED' -and $s23.Scenarios.M2.Detail -like 'prerequisite not met: the download carries no Internet-zone Mark of the Web (ZoneId=0*') ($s23.Scenarios.M2.Result + ' / ' + $s23.Scenarios.M2.Detail)
Assert-True '23. exit code 0' ($r23.ExitCode -eq 0) ('exit code ' + $r23.ExitCode)

# -------------------- 24. a bundle that cannot be written is a row of the record --------------------
Write-Output ''
Write-Output '24. the campaign bundle path held open by another process: the bundle fails, the summary on disk carries a bundle FAIL row, exit 1'
# The staging folder is rebuilt on every invocation; a file inside it held open by another process makes that fail.
$staged = Join-Path $r3.State 'bundle\campaign_summary.md'
if (-not (Test-Path -LiteralPath $staged)) { New-Item -ItemType Directory -Force -Path (Split-Path -Parent $staged) | Out-Null; [IO.File]::WriteAllText($staged, 'placeholder') }
$bundlesBefore = @(Get-ChildItem -LiteralPath $r3.State -Filter 'nhc-campaign_*.zip' | ForEach-Object { $_.Name })
$lock = [IO.File]::Open($staged, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
try { $r24 = Invoke-Campaign 'quit' @('-Resume', '-Scenarios', 'M7', '-SkipGui') "M7=skip`r`n" }
finally { $lock.Dispose() }
$summary24 = Get-Content -LiteralPath (Join-Path $r3.State 'campaign_summary.md') -Raw -Encoding UTF8
Assert-True '24. the summary on disk carries the bundle failure' ($summary24 -match '\| bundle \| the campaign bundle \| FAIL \|') (($summary24 -split "`n" | Select-Object -Last 4) -join ' / ')
Assert-True '24. the summary line counts it' ($summary24 -match 'Summary: \d+ passed, 1 failed, ') (($summary24 -split "`n")[-1])
Assert-True '24. the summary header says the bundle was NOT WRITTEN' ($summary24 -match '- Bundle: NOT WRITTEN - ') (($summary24 -split "`n" | Where-Object { $_ -like '- Bundle:*' }) -join ' / ')
$bundlesAfter = @(Get-ChildItem -LiteralPath $r3.State -Filter 'nhc-campaign_*.zip' | ForEach-Object { $_.Name })
Assert-True '24. no new bundle appeared, and the earlier ones are named by their own time' (@($bundlesAfter | Where-Object { $bundlesBefore -notcontains $_ }).Count -eq 0 -and @($bundlesAfter | Where-Object { $_ -notmatch '_\d{8}_\d{6}\.zip$' }).Count -eq 0) ($bundlesAfter -join ' / ')
Assert-True '24. exit code 1' ($r24.ExitCode -eq 1) ('exit code ' + $r24.ExitCode)

# -------------------- 25. the display size is measured live --------------------
Write-Output ''
Write-Output '25. the driver measures the display through SystemInformation.PrimaryMonitorSize (GetSystemMetrics, read on every call), never through the Screen objects Windows Forms caches until a message loop runs - the person changes the display while the campaign waits in Read-Host (the first campaign on the Windows 11 VM, 2026-09-05). Asserted on the AST, so a comment can neither satisfy nor trip it (Codex round 1 on PR #12)'
$tokens25 = $null; $errors25 = $null
$ast25 = [System.Management.Automation.Language.Parser]::ParseFile($driver, [ref]$tokens25, [ref]$errors25)
Assert-True '25. the driver parses' (@($errors25).Count -eq 0) (@($errors25 | ForEach-Object { $_.Message }) -join ' / ')
$screenReads = @($ast25.FindAll({ param($n) $n -is [System.Management.Automation.Language.TypeExpressionAst] -and $n.TypeName.FullName -match '(^|\.)Windows\.Forms\.Screen$' }, $true))
Assert-True '25. no [System.Windows.Forms.Screen] expression anywhere in the driver' ($screenReads.Count -eq 0) (@($screenReads | ForEach-Object { 'line ' + $_.Extent.StartLineNumber }) -join ', ')
$functions25 = @{}
foreach ($f in $ast25.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) { $functions25[$f.Name] = $f }
$live25 = @()
if ($functions25.ContainsKey('Get-PrimaryBounds')) { $live25 = @($functions25['Get-PrimaryBounds'].Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.MemberExpressionAst] -and $n.Static -and $n.Expression -is [System.Management.Automation.Language.TypeExpressionAst] -and $n.Expression.TypeName.FullName -match '(^|\.)Windows\.Forms\.SystemInformation$' -and [string]$n.Member.Value -eq 'PrimaryMonitorSize' }, $true)) }
Assert-True '25. Get-PrimaryBounds reads [SystemInformation]::PrimaryMonitorSize - a statement, not a comment' ($live25.Count -ge 1) ('Get-PrimaryBounds defined: ' + $functions25.ContainsKey('Get-PrimaryBounds') + '; live reads: ' + $live25.Count)
$shotCalls25 = @()
if ($functions25.ContainsKey('Save-Screenshot')) { $shotCalls25 = @($functions25['Save-Screenshot'].Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Get-PrimaryBounds' }, $true)) }
Assert-True '25. Save-Screenshot measures through Get-PrimaryBounds' ($shotCalls25.Count -ge 1) ('Save-Screenshot defined: ' + $functions25.ContainsKey('Save-Screenshot') + '; calls: ' + $shotCalls25.Count)

# -------------------- 26. M1 - the two outcomes that are the package behaving as designed --------------------
Write-Output ''
Write-Output '26. M1 on crafted compressed-folder views under a redirected %TEMP%: the launcher stopped for the missing program file (the Windows 11 view folder shape, hex suffix) is PASS; a report carrying the compressed-folder warning (the Windows 10 shape) is PASS; the launcher stopped for another reason is FAIL'
function New-ViewFolder([string]$TempRoot, [string]$Name, [string]$Relative) {
    $dir = Join-Path (Join-Path $TempRoot $Name) $Relative
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    return $dir
}
function Set-WrittenLater([string]$Path) {
    # The self-test cannot act between the gate and the check, so what the person would have left in the view is stamped
    # as written after the campaign started.
    (Get-Item -LiteralPath $Path).LastWriteTime = (Get-Date).AddMinutes(5)
}
function New-LauncherError([string]$Dir, [string]$Reason) {
    # The file the shipped launcher writes beside itself when it stops (Start-NetworkCheck.cmd, :launcher_error).
    $text = "Network Health Check launcher error`r`n===================================`r`nDate/time: 05/09/2026 16:59:00`r`nComputer: DESKTOP-TEST`r`nUser: tester`r`nFolder: $Dir\`r`nScript: $Dir\NetworkHealthCheck.ps1`r`nPowerShell: C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe`r`n`r`nError: $Reason`r`n`r`nSuggested action: extract the complete ZIP file to a local folder, then run Start-NetworkCheck.cmd again.`r`n"
    $path = Join-Path $Dir 'LauncherError.txt'
    [IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))
    Set-WrittenLater $path
}
$answers26 = "M1=done`r`nM1/run-finished=done`r`n"
# 26a - Windows 11: <guid>_<zip>.zip.<hex suffix>\<top>\en-US\ holding the launcher alone and its LauncherError.txt
$temp26a = (New-Item -ItemType Directory -Force -Path (Join-Path $WorkDir 'temp-26a')).FullName
$view26a = New-ViewFolder $temp26a ('5d2b5f20-7a4f-4428-a382-e2e558bb2bc4_NetworkHealthCheck-' + $version + '.zip.bc4') ('NetworkHealthCheck-' + $version + '\en-US')   # the suffix is hex, as seen on the VM (.684, .bc4)
Copy-Item -LiteralPath (Join-Path $top 'en-US\Start-NetworkCheck.cmd') -Destination $view26a
New-LauncherError $view26a 'The program file NetworkHealthCheck.ps1 is missing. Keep all files in the same folder.'
$env:TEMP = $temp26a
try { $r26a = Invoke-Campaign 'view-w11' @('-Zip', $zip, '-Scenarios', 'M1') $answers26 } finally { $env:TEMP = $tempSave }
$s26a = Read-State $r26a.State
Assert-True '26a. M1 PASS: the launcher stopped for the missing program file, as stock Windows makes it' ($s26a.Scenarios.M1.Result -eq 'PASS' -and $s26a.Scenarios.M1.Detail -like 'the launcher stopped in the view, as stock Windows makes it*NetworkHealthCheck.ps1 is missing*no report') ($s26a.Scenarios.M1.Result + ' / ' + $s26a.Scenarios.M1.Detail)
$fromView26a = Join-Path $r26a.State 'M1\from-the-view'
$listing26a = $(if (Test-Path -LiteralPath (Join-Path $fromView26a 'view-folder-listing.txt')) { Get-Content -LiteralPath (Join-Path $fromView26a 'view-folder-listing.txt') -Raw } else { '' })
Assert-True '26a. LauncherError.txt was copied out and the listing shows the launcher alone, no program file' ((Test-Path -LiteralPath (Join-Path $fromView26a 'LauncherError.txt')) -and ($listing26a -match 'Start-NetworkCheck\.cmd \(') -and ($listing26a -notmatch 'NetworkHealthCheck\.ps1 \(')) ((@(Get-ChildItem -LiteralPath $fromView26a -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }) -join ', ') + ' / ' + $listing26a)
Assert-True '26a. the screenshot is there and the exit code is 0' ((Test-Path -LiteralPath (Join-Path $r26a.State 'M1\M1_from_the_view.png')) -and $r26a.ExitCode -eq 0) ('exit code ' + $r26a.ExitCode)
# 26b - Windows 10: Temp1_<zip>.zip\<top>\en-US\Reports\ holding a report with the compressed-folder warning row
$temp26b = (New-Item -ItemType Directory -Force -Path (Join-Path $WorkDir 'temp-26b')).FullName
$view26b = New-ViewFolder $temp26b ('Temp1_NetworkHealthCheck-' + $version + '.zip') ('NetworkHealthCheck-' + $version + '\en-US\Reports')
$report26b = Join-Path $view26b 'NetworkHealthCheck_20260905_170000.json'
[IO.File]::WriteAllText($report26b, (@{ SchemaVersion = 2; Results = @(@{ Tag = 'startup'; Message = 'This copy is running from inside a compressed folder. Extract the ZIP to a real folder first, or the reports will be written to a temporary location that disappears.' }) } | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
Set-WrittenLater $report26b
$env:TEMP = $temp26b
try { $r26b = Invoke-Campaign 'view-w10' @('-Zip', $zip, '-Scenarios', 'M1') $answers26 } finally { $env:TEMP = $tempSave }
$s26b = Read-State $r26b.State
Assert-True '26b. M1 PASS on the report carrying the compressed-folder warning' ($s26b.Scenarios.M1.Result -eq 'PASS' -and $s26b.Scenarios.M1.Detail -like 'the tool ran from the view:*compressed-folder warning: 1*') ($s26b.Scenarios.M1.Result + ' / ' + $s26b.Scenarios.M1.Detail)
Assert-True '26b. the report was copied out of the view and the exit code is 0' ((Test-Path -LiteralPath (Join-Path $r26b.State 'M1\from-the-view\NetworkHealthCheck_20260905_170000.json')) -and $r26b.ExitCode -eq 0) ('exit code ' + $r26b.ExitCode)
# 26c - the launcher stopped for another reason
$temp26c = (New-Item -ItemType Directory -Force -Path (Join-Path $WorkDir 'temp-26c')).FullName
$view26c = New-ViewFolder $temp26c ('Temp1_NetworkHealthCheck-' + $version + '.zip') ('NetworkHealthCheck-' + $version + '\en-US')
New-LauncherError $view26c 'PowerShell was not found on this computer.'
$env:TEMP = $temp26c
try { $r26c = Invoke-Campaign 'view-other' @('-Zip', $zip, '-Scenarios', 'M1') $answers26 } finally { $env:TEMP = $tempSave }
$s26c = Read-State $r26c.State
Assert-True '26c. M1 FAIL with the other reason quoted' ($s26c.Scenarios.M1.Result -eq 'FAIL' -and $s26c.Scenarios.M1.Detail -like 'the launcher stopped in the view for another reason: "Error: PowerShell was not found on this computer."*') ($s26c.Scenarios.M1.Result + ' / ' + $s26c.Scenarios.M1.Detail)
Assert-True '26c. exit code 1' ($r26c.ExitCode -eq 1) ('exit code ' + $r26c.ExitCode)

# -------------------- 27. -Redo runs a recorded scenario again and keeps what it superseded --------------------
Write-Output ''
Write-Output '27. -Redo A3 on the campaign of case 1 (A3 SKIPPED): the record is cleared and A3 runs again (SKIPPED again here), the earlier evidence is moved to superseded\ and bundled, the summary names it; a pending scenario with a revert to do is refused; an unknown id is refused'
$s27before = Read-State $r1.State
$a3Dir27 = Join-Path $r1.State 'A3'
New-Item -ItemType Directory -Force -Path $a3Dir27 | Out-Null
[IO.File]::WriteAllText((Join-Path $a3Dir27 'earlier-evidence.txt'), 'from the first run')
$r27 = Invoke-Campaign 'skips' @('-Resume', '-Scenarios', 'A3', '-Redo', 'A3', '-SkipGui') "A3=done`r`n"
$s27 = Read-State $r27.State
Assert-True '27. A3 ran again: SKIPPED for its precondition, with a new finish time' ($s27.Scenarios.A3.Result -eq 'SKIPPED' -and $s27.Scenarios.A3.Detail -like 'precondition not met*' -and $s27.Scenarios.A3.Finished -ne $s27before.Scenarios.A3.Finished) ($s27.Scenarios.A3.Result + ' / ' + $s27.Scenarios.A3.Detail + ' / ' + $s27.Scenarios.A3.Finished + ' vs ' + $s27before.Scenarios.A3.Finished)
$superseded27 = @($s27.Scenarios.A3.Superseded)
Assert-True '27. the record names what it superseded, with the evidence location' ($superseded27.Count -eq 1 -and ([string]$superseded27[0]) -like ('SKIPPED - ' + $s27before.Scenarios.A3.Detail + ' (finished ' + $s27before.Scenarios.A3.Finished + '; evidence under superseded\A3_*)')) ($superseded27 -join ' / ')
$aside27 = @(Get-ChildItem -LiteralPath (Join-Path $r1.State 'superseded') -Directory -Filter 'A3_*' -ErrorAction SilentlyContinue)
Assert-True '27. the earlier evidence was moved aside, out of the scenario folder' ($aside27.Count -eq 1 -and (Test-Path -LiteralPath (Join-Path $aside27[0].FullName 'earlier-evidence.txt')) -and -not (Test-Path -LiteralPath (Join-Path $a3Dir27 'earlier-evidence.txt'))) (($aside27 | ForEach-Object { $_.FullName }) -join ', ')
$summary27 = Get-Content -LiteralPath (Join-Path $r1.State 'campaign_summary.md') -Raw -Encoding UTF8
Assert-True '27. the summary names the redo' ($summary27 -match '- Redone: A3 - earlier: SKIPPED - precondition not met') (($summary27 -split "`n" | Where-Object { $_ -like '- Redone:*' }) -join ' / ')
Add-Type -AssemblyName System.IO.Compression.FileSystem
$bundle27 = @(Get-ChildItem -LiteralPath $r1.State -Filter 'nhc-campaign_*.zip' | Sort-Object LastWriteTime -Descending)
$entries27 = @()
if ($bundle27.Count) { $z = [IO.Compression.ZipFile]::OpenRead($bundle27[0].FullName); try { $entries27 = @($z.Entries | ForEach-Object { $_.FullName }) } finally { $z.Dispose() } }
Assert-True '27. the moved evidence travels in the bundle' (@($entries27 | Where-Object { $_ -match 'superseded[\\/]A3_[^\\/]+[\\/]earlier-evidence\.txt$' }).Count -eq 1) (($entries27 | Where-Object { $_ -match 'superseded' }) -join ', ')
Assert-True '27. exit code 0' ($r27.ExitCode -eq 0) ('exit code ' + $r27.ExitCode)
$stateFile27 = Join-Path $r1.State 'campaign.json'
$crafted27 = Get-Content -LiteralPath $stateFile27 -Raw -Encoding UTF8 | ConvertFrom-Json
$crafted27.Scenarios.A4.Result = 'PENDING'
$crafted27.Scenarios.A4.Detail = 'quit by the user after an attempt (crafted by the self-test)'
$crafted27.Scenarios.A4.Attempted = $true
[IO.File]::WriteAllText($stateFile27, ($crafted27 | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding($false)))
$r27b = Invoke-Campaign 'skips' @('-Resume', '-Scenarios', 'A4', '-Redo', 'A4', '-SkipGui') "A4=done`r`n"
Assert-True '27. a pending scenario with a revert to do is refused' ($r27b.ExitCode -ne 0 -and (($r27b.Output -join ' ') -match 'cannot redo A4: it is pending with a change possibly still on the machine')) ('exit code ' + $r27b.ExitCode + ' / ' + (($r27b.Output | Select-Object -Last 3) -join ' / '))
$r27c = Invoke-Campaign 'skips' @('-Resume', '-Redo', 'ZZ', '-SkipGui') ''
Assert-True '27. an unknown id in -Redo is refused' ($r27c.ExitCode -ne 0 -and (($r27c.Output -join ' ') -match 'unknown scenario\(s\) in -Redo: ZZ')) ('exit code ' + $r27c.ExitCode + ' / ' + (($r27c.Output | Select-Object -Last 3) -join ' / '))

# -------------------- 28. a refused -Redo moves nothing --------------------
Write-Output ''
Write-Output '28. -Redo A3,A4 while A4 is pending with a revert to do (the crafted state of case 27): refused before anything moves - A3 keeps its folder, its record and its single superseded entry (Codex round 1 on PR #13)'
$s28before = Read-State $r1.State
[IO.File]::WriteAllText((Join-Path $a3Dir27 'evidence-of-the-redo.txt'), 'from the second run')
$asideBefore28 = @(Get-ChildItem -LiteralPath (Join-Path $r1.State 'superseded') -Directory -Filter 'A3_*' -ErrorAction SilentlyContinue).Count
$r28 = Invoke-Campaign 'skips' @('-Resume', '-Scenarios', 'A3,A4', '-Redo', 'A3,A4', '-SkipGui') "A3=done`r`nA4=done`r`n"
$s28 = Read-State $r1.State
Assert-True '28. refused for A4' ($r28.ExitCode -ne 0 -and (($r28.Output -join ' ') -match 'cannot redo A4: it is pending with a change possibly still on the machine')) ('exit code ' + $r28.ExitCode + ' / ' + (($r28.Output | Select-Object -Last 3) -join ' / '))
Assert-True '28. the A3 folder and its evidence did not move' ((Test-Path -LiteralPath (Join-Path $a3Dir27 'evidence-of-the-redo.txt')) -and @(Get-ChildItem -LiteralPath (Join-Path $r1.State 'superseded') -Directory -Filter 'A3_*' -ErrorAction SilentlyContinue).Count -eq $asideBefore28) ('superseded A3_* folders: ' + @(Get-ChildItem -LiteralPath (Join-Path $r1.State 'superseded') -Directory -Filter 'A3_*' -ErrorAction SilentlyContinue).Count)
Assert-True '28. the A3 record is as it was' ($s28.Scenarios.A3.Result -eq $s28before.Scenarios.A3.Result -and $s28.Scenarios.A3.Finished -eq $s28before.Scenarios.A3.Finished -and @($s28.Scenarios.A3.Superseded).Count -eq @($s28before.Scenarios.A3.Superseded).Count) ($s28.Scenarios.A3.Result + ' / ' + $s28.Scenarios.A3.Finished + ' / superseded entries ' + @($s28.Scenarios.A3.Superseded).Count)

# -------------------- 29. the extraction is verified before anyone double-clicks --------------------
Write-Output ''
Write-Output '29. M2 (marked ZIP) and M3 (unmarked ZIP) with nothing extracted under the work root: SKIPPED at the precondition, the folder and the Extract All hint named, no launcher prompt, exit 0'
$desk29 = (New-Item -ItemType Directory -Force -Path (Join-Path $WorkDir 'desk29')).FullName
$r29a = Invoke-Campaign 'noextract-m2' @('-Zip', $zipMarked, '-Scenarios', 'M2', '-WorkRoot', $desk29) "M2=done`r`nM2/windows-showed=3`r`n"
$s29a = Read-State $r29a.State
Assert-True '29. M2 SKIPPED: nothing extracted under NHC-M2, with the hint' ($s29a.Scenarios.M2.Result -eq 'SKIPPED' -and $s29a.Scenarios.M2.Detail -like ('precondition not met: nothing extracted under ' + $desk29 + '\NHC-M2 (no Start-English.cmd below it) - the Extract All dialog proposes another folder; replace the destination with *')) ($s29a.Scenarios.M2.Result + ' / ' + $s29a.Scenarios.M2.Detail)
Assert-True '29. no launcher prompt was reached for M2' (@(Get-Content -LiteralPath (Join-Path $r29a.State 'answers.log') | Where-Object { $_ -match ' M2/(launched|windows-showed) ' }).Count -eq 0) ((Get-Content -LiteralPath (Join-Path $r29a.State 'answers.log')) -join ' / ')
$r29b = Invoke-Campaign 'noextract-m3' @('-Zip', $zip, '-Scenarios', 'M3', '-WorkRoot', $desk29) "M3=done`r`nM3/open-report=shown`r`n"
$s29b = Read-State $r29b.State
Assert-True '29. M3 SKIPPED: nothing extracted under NHC-M3, both launchers named; exit codes 0' ($s29b.Scenarios.M3.Result -eq 'SKIPPED' -and $s29b.Scenarios.M3.Detail -like ('precondition not met: nothing extracted under ' + $desk29 + '\NHC-M3 (no Start-English.cmd / Start-Traditional-Chinese.cmd below it)*') -and $r29a.ExitCode -eq 0 -and $r29b.ExitCode -eq 0) ($s29b.Scenarios.M3.Result + ' / ' + $s29b.Scenarios.M3.Detail + ' / exit ' + $r29a.ExitCode + ',' + $r29b.ExitCode)

# -------------------- 30. a run made from the wrong folder is named --------------------
Write-Output ''
Write-Output '30. M3 extracted under NHC-M3 as asked, but the launchers were run from the folder the Extract All dialog proposes (a zh-TW report there): FAIL naming where the report was found, exit 1'
$desk30 = (New-Item -ItemType Directory -Force -Path (Join-Path $WorkDir 'desk30')).FullName
New-Item -ItemType Directory -Force -Path (Join-Path $desk30 'NHC-M3') | Out-Null
Copy-Item -LiteralPath $top -Destination (Join-Path $desk30 'NHC-M3') -Recurse -Force
Set-ExtractedLater (Join-Path $desk30 'NHC-M3')
$elsewhere30 = Join-Path $desk30 ('NetworkHealthCheck-' + $version + '\NetworkHealthCheck-' + $version + '\zh-TW\Reports')
New-Item -ItemType Directory -Force -Path $elsewhere30 | Out-Null
$report30 = Join-Path $elsewhere30 'NetworkHealthCheck_20260905_171350_DESKTOP-TEST.json'
[IO.File]::WriteAllText($report30, (@{ SchemaVersion = 2; RunOptions = @{ EntryPoint = 'User' }; Results = @() } | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
Set-WrittenLater $report30
$r30 = Invoke-Campaign 'elsewhere' @('-Zip', $zip, '-Scenarios', 'M3', '-WorkRoot', $desk30) "M3=done`r`nM3/open-report=failed`r`n"
$s30 = Read-State $r30.State
Assert-True '30. M3 FAIL: the en-US report is missing with nothing found elsewhere' ($s30.Scenarios.M3.Result -eq 'FAIL' -and $s30.Scenarios.M3.Detail -like ('*no en-US report under ' + $desk30 + '\NHC-M3;*')) ($s30.Scenarios.M3.Result + ' / ' + $s30.Scenarios.M3.Detail)
Assert-True '30. the zh-TW report found elsewhere is named with its path' ($s30.Scenarios.M3.Detail -like ('*no zh-TW report under ' + $desk30 + '\NHC-M3 - found elsewhere, so the launchers were not run from there: ' + $report30 + '*')) $s30.Scenarios.M3.Detail
Assert-True '30. exit code 1' ($r30.ExitCode -eq 1) ('exit code ' + $r30.ExitCode)

# -------------------- 31. the edition decides how the policy scenarios are done --------------------
Write-Output ''
Write-Output '31. the summary names the edition; on a crafted Pro state M9 reaches the gate with the Pro note, on a crafted Home state it is skipped before anyone is asked, and M8 names the registry lines as the way for this machine, recorded in its facts and in RECOVER.txt - whatever the edition of the host running the self-test (Codex round 2 on PR #14)'
$r31 = Invoke-Campaign 'edition' @('-Zip', $zip, '-Scenarios', 'M9') "M9=skip`r`n"
$summary31 = Get-Content -LiteralPath (Join-Path $r31.State 'campaign_summary.md') -Raw -Encoding UTF8
Assert-True '31. the summary header names the edition and the consoles' ($summary31 -match '(?m)^- Edition: .+ \(EditionID \w+, .*build \d+\.\d+\); gpedit\.msc: (yes|no); secpol\.msc: (yes|no)\r?$') (($summary31 -split "`n" | Where-Object { $_ -like '- Edition:*' }) -join ' / ')
$stateFile31 = Join-Path $r31.State 'campaign.json'
function Set-CraftedEdition([string]$Path, [bool]$HomeEdition, [string]$Id, [string]$Caption, [bool]$Consoles) {   # not $Home: that is PowerShell's own read-only variable
    $c = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    $c.Edition.IsHome = $HomeEdition; $c.Edition.EditionId = $Id; $c.Edition.Caption = $Caption; $c.Edition.HasGpedit = $Consoles; $c.Edition.HasSecpol = $Consoles
    [IO.File]::WriteAllText($Path, ($c | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding($false)))
}
Set-CraftedEdition $stateFile31 $false 'Professional' 'Microsoft Windows 11 Pro' $true
$r31a = Invoke-Campaign 'edition' @('-Resume', '-Redo', 'M9', '-Scenarios', 'M9') "M9=skip`r`n"
$s31a = Read-State $r31.State
$gates31 = @(Get-Content -LiteralPath (Join-Path $r31.State 'answers.log') | Where-Object { $_ -match ' M9/gate ' }).Count
Assert-True '31. on Pro, M9 reaches the gate with the note that Pro does not enforce' ($s31a.Scenarios.M9.Result -eq 'SKIPPED' -and $s31a.Scenarios.M9.Detail -eq 'skipped by the user' -and (($r31a.Output -join ' ') -match 'prerequisite met - Microsoft Windows 11 Pro: Pro holds AppLocker rules but does not enforce them') -and $gates31 -ge 1) ($s31a.Scenarios.M9.Result + ' / ' + $s31a.Scenarios.M9.Detail + ' / gates ' + $gates31)
Set-CraftedEdition $stateFile31 $true 'Core' 'Microsoft Windows 11 Home' $false
$r31b = Invoke-Campaign 'edition' @('-Resume', '-Redo', 'M9', '-Scenarios', 'M9') "M9=done`r`n"
$s31b = Read-State $r31.State
Assert-True '31. on Home, M9 is skipped before anyone is asked, with the edition named' ($s31b.Scenarios.M9.Result -eq 'SKIPPED' -and $s31b.Scenarios.M9.Detail -like 'prerequisite not met: AppLocker is not available on this edition (Microsoft Windows 11 Home, EditionID Core)*' -and @(Get-Content -LiteralPath (Join-Path $r31.State 'answers.log') | Where-Object { $_ -match ' M9/gate ' }).Count -eq $gates31) ($s31b.Scenarios.M9.Result + ' / ' + $s31b.Scenarios.M9.Detail)
$r31c = Invoke-Campaign 'edition' @('-Resume', '-Scenarios', 'M8') "M8=skip`r`n"
$out31c = $r31c.Output -join "`n"
Assert-True '31. on Home, M8 names the registry lines as the way for this machine' (($out31c -match 'This machine: Microsoft Windows 11 Home \(EditionID Core\) - no gpedit\.msc: take the registry lines') -and ($out31c -match 'reg add "HKLM\\SOFTWARE\\Policies\\Microsoft\\Windows\\PowerShell" /v ExecutionPolicy /t REG_SZ /d AllSigned /f')) (($r31c.Output | Where-Object { $_ -match 'This machine|reg add' }) -join ' / ')
$s31c = Read-State $r31.State
Assert-True '31. M8 recorded how the policy is applied here' ([string]$s31c.Scenarios.M8.Facts.PolicyWay -eq 'registry' -and [string]$s31c.Scenarios.M8.Facts.Edition -eq 'Microsoft Windows 11 Home / Core') ('facts: ' + ($s31c.Scenarios.M8.Facts | ConvertTo-Json -Compress))
$recover31 = $(if (Test-Path -LiteralPath (Join-Path $r31.State 'RECOVER.txt')) { Get-Content -LiteralPath (Join-Path $r31.State 'RECOVER.txt') -Raw } else { '' })
Assert-True '31. RECOVER.txt carries the way back without gpedit as well' ($recover31 -match 'reg delete "HKLM\\SOFTWARE\\Policies\\Microsoft\\Windows\\PowerShell" /v ExecutionPolicy /f') ('RECOVER.txt length ' + $recover31.Length)

# -------------------- 32. the standard-user session gets a file to run --------------------
Write-Output ''
Write-Output '32. A2 in an administrator session: left PENDING for the standard-user session, and run-as-standard-user.cmd next to the state holds the resume command'
$r32 = Invoke-Campaign 'a2cmd' @('-Zip', $zip, '-Scenarios', 'A2') ''
$s32 = Read-State $r32.State
$cmd32 = Join-Path $r32.State 'run-as-standard-user.cmd'
Assert-True '32. A2 pending for the other session, the .cmd written and named' ($s32.Scenarios.A2.Result -eq 'PENDING' -and $s32.Scenarios.A2.Detail -like ('needs a standard-user session; run ' + $cmd32 + ' there*') -and (Test-Path -LiteralPath $cmd32)) ($s32.Scenarios.A2.Result + ' / ' + $s32.Scenarios.A2.Detail)
$cmdText32 = $(if (Test-Path -LiteralPath $cmd32) { Get-Content -LiteralPath $cmd32 -Raw } else { '' })
Assert-True '32. the .cmd holds the resume command of this campaign' (($cmdText32 -match '^@echo off') -and ($cmdText32 -match 'Invoke-AcceptanceCampaign\.ps1" -Campaign selftest-a2cmd -StateDir "') -and ($cmdText32 -match ' -Resume') -and ($cmdText32 -match '(?m)^pause')) $cmdText32

# -------------------- 33. a stale or foreign extraction is refused; the work root is the campaign's --------------------
Write-Output ''
Write-Output '33. M3 with a tree extracted before the scenario started: SKIPPED as stale; the same tree stamped fresh but with an altered program file: SKIPPED as not this asset - on a resume without -WorkRoot, which keeps the root the campaign was given (Codex round 1 on PR #14)'
$desk33 = (New-Item -ItemType Directory -Force -Path (Join-Path $WorkDir 'desk33')).FullName
New-Item -ItemType Directory -Force -Path (Join-Path $desk33 'NHC-M3') | Out-Null
Copy-Item -LiteralPath $top -Destination (Join-Path $desk33 'NHC-M3') -Recurse -Force
$r33a = Invoke-Campaign 'stale' @('-Zip', $zip, '-Scenarios', 'M3', '-WorkRoot', $desk33) "M3=done`r`n"
$s33a = Read-State $r33a.State
Assert-True '33. a tree extracted before the scenario started is refused as stale' ($s33a.Scenarios.M3.Result -eq 'SKIPPED' -and $s33a.Scenarios.M3.Detail -like ('precondition not met: the package under ' + $desk33 + '\NHC-M3 was extracted before this scenario started (the folder last changed *): remove ' + $desk33 + '\NHC-M3 and extract the downloaded ZIP again')) ($s33a.Scenarios.M3.Result + ' / ' + $s33a.Scenarios.M3.Detail)
Set-ExtractedLater (Join-Path $desk33 'NHC-M3')
Add-Content -LiteralPath (Join-Path $desk33 ('NHC-M3\NetworkHealthCheck-' + $version + '\en-US\NetworkHealthCheck.ps1')) -Value '# altered by the self-test'
$r33b = Invoke-Campaign 'stale' @('-Resume', '-Redo', 'M3', '-Scenarios', 'M3') "M3=done`r`n"
$s33b = Read-State $r33a.State
Assert-True '33. a fresh tree whose program file differs is refused as not this asset, under the root the campaign was given' ($s33b.Scenarios.M3.Result -eq 'SKIPPED' -and $s33b.Scenarios.M3.Detail -like ('precondition not met: the package under ' + $desk33 + '\NHC-M3 is not this campaign''s asset (its en-US\NetworkHealthCheck.ps1 differs; tool version ' + $version + ', the asset is ' + $version + '): remove *')) ($s33b.Scenarios.M3.Result + ' / ' + $s33b.Scenarios.M3.Detail)
$summary33 = Get-Content -LiteralPath (Join-Path $r33a.State 'campaign_summary.md') -Raw -Encoding UTF8
Assert-True '33. the summary names the work root, and the state kept it' (($summary33 -match ('(?m)^- Work root \(NHC-M2, NHC-M3\): ' + [regex]::Escape($desk33) + '\r?$')) -and ([string]$s33b.WorkRoot -eq $desk33)) (($summary33 -split "`n" | Where-Object { $_ -like '- Work root*' }) -join ' / ')

# -------------------- 34. M8 puts back what was there --------------------
Write-Output ''
Write-Output '34. M8 records the MachinePolicy and the two registry values - data and kind - before the change; on a crafted record that had RemoteSigned (REG_EXPAND_SZ) and EnableScripts 1 (REG_SZ), the revert instruction re-creates the values with their kinds and the verification compares with RemoteSigned, not Undefined (Codex rounds 1 and 2 on PR #14)'
$r34 = Invoke-Campaign 'm8facts' @('-Zip', $zip, '-Scenarios', 'M8') "M8=skip`r`n"
$s34 = Read-State $r34.State
$f34 = $s34.Scenarios.M8.Facts
Assert-True '34. the facts hold the state before M8, kinds included' (([string]$f34.MachinePolicyBefore -ne '') -and ([string]$f34.RegExecutionPolicyBefore -ne '') -and ([string]$f34.RegEnableScriptsBefore -ne '') -and ([string]$f34.RegExecutionPolicyKindBefore -ne '') -and ([string]$f34.RegEnableScriptsKindBefore -ne '') -and ([string]$f34.PolicyWay -in @('gpedit', 'registry'))) ('facts: ' + ($f34 | ConvertTo-Json -Compress))
$recover34 = Get-Content -LiteralPath (Join-Path $r34.State 'RECOVER.txt') -Raw
Assert-True '34. RECOVER.txt names the MachinePolicy that was there' ($recover34 -match ('MachinePolicy was ' + [regex]::Escape([string]$f34.MachinePolicyBefore) + ' before M8')) (($recover34 -split "`n" | Where-Object { $_ -like 'M8*' }) -join ' / ')
$stateFile34 = Join-Path $r34.State 'campaign.json'
$crafted34 = Get-Content -LiteralPath $stateFile34 -Raw -Encoding UTF8 | ConvertFrom-Json
$crafted34.Scenarios.M8.Result = 'PENDING'; $crafted34.Scenarios.M8.Detail = 'ran (PASS) but NOT REVERTED - quit (crafted by the self-test)'; $crafted34.Scenarios.M8.ActionResult = 'PASS'; $crafted34.Scenarios.M8.ActionDetail = 'crafted'; $crafted34.Scenarios.M8.Attempted = $true
$crafted34.Scenarios.M8.Facts.MachinePolicyBefore = 'RemoteSigned'
$crafted34.Scenarios.M8.Facts.RegExecutionPolicyBefore = 'RemoteSigned'; $crafted34.Scenarios.M8.Facts.RegExecutionPolicyKindBefore = 'ExpandString'
$crafted34.Scenarios.M8.Facts.RegEnableScriptsBefore = '1'; $crafted34.Scenarios.M8.Facts.RegEnableScriptsKindBefore = 'String'
[IO.File]::WriteAllText($stateFile34, ($crafted34 | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding($false)))
$r34b = Invoke-Campaign 'm8facts' @('-Resume', '-Scenarios', 'M8') "M8/revert=done`r`n"
$out34b = $r34b.Output -join "`n"
Assert-True '34. the revert instruction re-creates the values as they were, kinds included' (($out34b -match 'Put it back as it was \(MachinePolicy was RemoteSigned before M8\)') -and ($out34b -match 'reg add "HKLM\\SOFTWARE\\Policies\\Microsoft\\Windows\\PowerShell" /v ExecutionPolicy /t REG_EXPAND_SZ /d RemoteSigned /f') -and ($out34b -match 'reg add "HKLM\\SOFTWARE\\Policies\\Microsoft\\Windows\\PowerShell" /v EnableScripts /t REG_SZ /d 1 /f')) (($r34b.Output | Where-Object { $_ -match 'Put it back|reg add' }) -join ' / ')
$s34b = Read-State $r34.State
Assert-True '34. the verification compares with what was there, not with Undefined' ($s34b.Scenarios.M8.Result -eq 'PENDING' -and $s34b.Scenarios.M8.Reverted -like 'NOT VERIFIED - MachinePolicy is *; it was RemoteSigned before M8' -and $r34b.ExitCode -eq 1) ($s34b.Scenarios.M8.Result + ' / ' + $s34b.Scenarios.M8.Reverted + ' / exit ' + $r34b.ExitCode)

# -------------------- 6. the baseline for real --------------------
if ($Full) {
    Write-Output ''
    Write-Output '6. A1 for real (-SkipGui): PASS'
    $r6 = Invoke-Campaign 'full' @('-Zip', $zip, '-Scenarios', 'A1', '-SkipGui') ""
    $s6 = Read-State $r6.State
    Assert-True '6. exit code 0' ($r6.ExitCode -eq 0) ('exit code ' + $r6.ExitCode)
    Assert-True '6. A1 PASS with the acceptance summary' ($s6.Scenarios.A1.Result -eq 'PASS' -and $s6.Scenarios.A1.Detail -match 'Summary: \d+ passed, 0 failed') ($s6.Scenarios.A1.Result + ' / ' + $s6.Scenarios.A1.Detail)
    Assert-True '6. the acceptance bundle is in the scenario folder' (@(Get-ChildItem -LiteralPath (Join-Path $r6.State 'A1') -Filter 'nhc-acceptance_*.zip').Count -eq 1) 'bundle count'
}

Write-Output ''
Write-Output ('Summary: {0} passed, {1} failed' -f $passes, $fails)
if ($fails -eq 0) { Write-Output 'ALL SELF-TESTS OK'; exit 0 }
exit 1
