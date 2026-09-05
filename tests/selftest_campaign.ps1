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
$r5 = Invoke-Campaign 'fail' @('-Zip', $zip, '-Scenarios', 'M1') "M1=done`r`n"
$s5 = Read-State $r5.State
Assert-True '5. exit code 1' ($r5.ExitCode -eq 1) ('exit code ' + $r5.ExitCode)
Assert-True '5. M1 FAIL with the reason' ($s5.Scenarios.M1.Result -eq 'FAIL' -and $s5.Scenarios.M1.Detail -like 'no report under*') ($s5.Scenarios.M1.Result + ' / ' + $s5.Scenarios.M1.Detail)
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
Write-Output '21. M2 on a copy of the asset given a Mark of the Web, no extraction made: the prompts run, a screenshot is taken, FAIL for the missing report, exit 1'
$zipMarked = Join-Path $WorkDir ('NetworkHealthCheck-' + $version + '-marked.zip')
Copy-Item -LiteralPath $zip -Destination $zipMarked -Force
Set-Content -LiteralPath $zipMarked -Stream Zone.Identifier -Value "[ZoneTransfer]`r`nZoneId=3"
$r21 = Invoke-Campaign 'marked' @('-Zip', $zipMarked, '-Scenarios', 'M2') "M2=done`r`nM2/windows-showed=3`r`nM2/run-finished=done`r`n"
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
