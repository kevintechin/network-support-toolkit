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
$capturedLines = 0    # what the driver said, counted where it is captured
$forwardedLines = 0   # what reached the host, counted inside the loop that forwards it - so deleting the loop cannot leave the count intact (backlog #53)
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
Get-ChildItem -LiteralPath (Join-Path $root 'healthcheck') -Recurse -File | Where-Object { $_.FullName -notmatch '\\Reports\\' -and $_.Name -notlike 'LauncherError*.txt' -and $_.Name -notlike 'PowerShellMessages_*.txt' -and $_.Name -notlike 'NetworkHealthCheck_*_*.txt' } | ForEach-Object {
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
    # The driver's lines go to the host, never to the success stream (backlog #53): every caller assigns this
    # call, so a Write-Output here lands in $rN beside the returned hashtable instead of reaching the log, while
    # member-access enumeration keeps $rN.ExitCode answering over the array so nothing looks wrong. That left
    # campaign.log with two driver lines in 199 - both from case 12, the one place that bypasses this helper -
    # and #25's bundle explanation unproven from 2026-09-06 to 2026-09-09 across two occurrences of its failure.
    $state = Join-Path $WorkDir ('state-' + $Name)
    $answers = Join-Path $WorkDir ('answers-' + $Name + '.txt')
    [IO.File]::WriteAllText($answers, $AnswersText, (New-Object System.Text.UTF8Encoding($false)))
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $tests 'Invoke-AcceptanceCampaign.ps1'), '-Campaign', ('selftest-' + $Name), '-StateDir', $state, '-Answers', $answers) + $Arguments
    $ErrorActionPreference = 'Continue'
    $out = @(& $psExe @argList 2>&1 | ForEach-Object { [string]$_ })
    $code = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    $script:capturedLines += $out.Count
    foreach ($l in $out) { Write-Host ('    | ' + $l); $script:forwardedLines++ }
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
Assert-True '1. the campaign bundle was written under a time-stamped name, and the summary names it' ($bundle1.Count -eq 1 -and $bundle1[0].Name -match '^nhc-campaign_.+_\d{8}_\d{6}_\d{3}_p\d+\.zip$' -and $summary1 -match ('- Bundle: ' + [regex]::Escape($bundle1[0].Name))) ('bundles: ' + (($bundle1 | ForEach-Object { $_.Name }) -join ', '))

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
$capturedLines += $out12.Count   # this invocation bypasses Invoke-Campaign, so it counts itself into the same totals (#53)
foreach ($l in $out12) { Write-Host ('    | ' + $l); $forwardedLines++ }   # driver lines go to the host here too, so every one of them travels the same way
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
Assert-True '21. M2 FAIL for the missing extraction and report, with the marks recorded - the download''s carrying the way it got there (backlog #30: this copy was marked by hand, and the row says so)' ($s21.Scenarios.M2.Result -eq 'FAIL' -and $s21.Scenarios.M2.Detail -like '*no en-US report*' -and $s21.Scenarios.M2.Detail -like '*download mark: ZoneId=3, no origin recorded in the stream*') ($s21.Scenarios.M2.Result + ' / ' + $s21.Scenarios.M2.Detail)
Assert-True '21. the screenshot was taken and the observation recorded' ((Test-Path -LiteralPath (Join-Path $r21.State 'M2\M2_after_double-click.png')) -and (@(Get-Content -LiteralPath (Join-Path $r21.State 'answers.log') | Where-Object { $_ -match ' M2/windows-showed = 3$' }).Count -eq 1)) 'screenshot or answer missing'
Assert-True '21. the prerequisite that let it run said what the mark is and how far the stream accounts for it - the branch no skip reaches (backlog #30)' (@($r21.Output | Where-Object { $_ -match 'prerequisite met - the download is marked: ZoneId=3, no origin recorded in the stream' }).Count -eq 1) (($r21.Output | Where-Object { $_ -match 'prerequisite met' }) -join ' / ')
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
Assert-True '24. no new bundle appeared, and the earlier ones are named by their own time and process' (@($bundlesAfter | Where-Object { $bundlesBefore -notcontains $_ }).Count -eq 0 -and @($bundlesAfter | Where-Object { $_ -notmatch '_\d{8}_\d{6}_\d{3}_p\d+\.zip$' }).Count -eq 0) ($bundlesAfter -join ' / ')
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
    # The file the shipped launcher writes beside itself when it stops (Start-NetworkCheck.cmd, :launcher_error), in
    # the 1.2.14 shape: a stamped name, the short-date pattern beside the date, the PowerShell-messages line (backlog
    # #47, #44).
    $text = "Network Health Check launcher error`r`n===================================`r`nDate/time: 05/09/2026 16:59:00.00 (this computer's short-date pattern: dd/MM/yyyy)`r`nComputer: DESKTOP-TEST`r`nUser: tester`r`nFolder: $Dir\`r`nScript: $Dir\NetworkHealthCheck.ps1`r`nPowerShell: C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe`r`nPowerShell messages: none - PowerShell was not started`r`n`r`nError: $Reason`r`n`r`nSuggested action: extract the complete ZIP file to a local folder, then run Start-NetworkCheck.cmd again.`r`n"
    $path = Join-Path $Dir 'LauncherError_0509202616590000.txt'
    [IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))
    Set-WrittenLater $path
}
$answers26 = "M1=done`r`nM1/run-finished=done`r`n"
# 26a - Windows 11: <guid>_<zip>.zip.<hex suffix>\<top>\en-US\ holding the launcher alone and its LauncherError_<stamp>.txt
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
Assert-True '26a. the LauncherError_<stamp>.txt was copied out and the listing shows the launcher alone, no program file' ((@(Get-ChildItem -LiteralPath $fromView26a -Filter 'LauncherError_*.txt' -File -ErrorAction SilentlyContinue).Count -eq 1) -and ($listing26a -match 'Start-NetworkCheck\.cmd \(') -and ($listing26a -notmatch 'NetworkHealthCheck\.ps1 \(')) ((@(Get-ChildItem -LiteralPath $fromView26a -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }) -join ', ') + ' / ' + $listing26a)
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
Assert-True '30. M3 FAIL: the en-US report is missing under the validated tree, with nothing found elsewhere' ($s30.Scenarios.M3.Result -eq 'FAIL' -and $s30.Scenarios.M3.Detail -like ('*no en-US report under ' + $desk30 + '\NHC-M3\NetworkHealthCheck-' + $version + ';*')) ($s30.Scenarios.M3.Result + ' / ' + $s30.Scenarios.M3.Detail)
Assert-True '30. the zh-TW report found elsewhere is named with its path' ($s30.Scenarios.M3.Detail -like ('*no zh-TW report under ' + $desk30 + '\NHC-M3\NetworkHealthCheck-' + $version + ' - found elsewhere, so the launchers were not run from there: ' + $report30 + '*')) $s30.Scenarios.M3.Detail
Assert-True '30. exit code 1' ($r30.ExitCode -eq 1) ('exit code ' + $r30.ExitCode)

# -------------------- 31. the edition decides how the policy scenarios are done --------------------
Write-Output ''
Write-Output '31. the summary names the edition; on a crafted Home state and on a crafted Windows 10 build below 2004 M9 is skipped before anyone is asked while on a crafted Pro state at a supported build it reaches the gate - KB 5024351 ended the edition requirement above that floor - and M8 names the registry lines as the way for this machine, recorded in its facts and in RECOVER.txt - whatever the edition of the host running the self-test (Codex round 2 on PR #14; the Pro reading corrected in Codex round 1 on PR #16)'
$r31 = Invoke-Campaign 'edition' @('-Zip', $zip, '-Scenarios', 'M9') "M9=skip`r`n"
$summary31 = Get-Content -LiteralPath (Join-Path $r31.State 'campaign_summary.md') -Raw -Encoding UTF8
Assert-True '31. the summary header names the edition and the consoles' ($summary31 -match '(?m)^- Edition: .+ \(EditionID \w+, .*build \d+\.\d+\); gpedit\.msc: (yes|no); secpol\.msc: (yes|no)\r?$') (($summary31 -split "`n" | Where-Object { $_ -like '- Edition:*' }) -join ' / ')
$stateFile31 = Join-Path $r31.State 'campaign.json'
function Set-CraftedEdition([string]$Path, [bool]$HomeEdition, [string]$Id, [string]$Caption, [bool]$Consoles, [string]$Build = '22621.1') {   # not $Home: that is PowerShell's own read-only variable
    # The build is crafted too, because M9's prerequisite reads it: below Windows 10 2004 (19041) a Group-Policy
    # deployment still needs Enterprise, Education or Server, and the assertions must not depend on the host's own build.
    $c = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    $c.Edition.IsHome = $HomeEdition; $c.Edition.EditionId = $Id; $c.Edition.Caption = $Caption; $c.Edition.HasGpedit = $Consoles; $c.Edition.HasSecpol = $Consoles; $c.Edition.Build = $Build
    [IO.File]::WriteAllText($Path, ($c | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding($false)))
}
Set-CraftedEdition $stateFile31 $false 'Professional' 'Microsoft Windows 11 Pro' $true
# On a supported Pro build the scenario reaches the gate, so this invocation must consume exactly one gate answer and
# the M9 gate count must grow by one; the crafted Home and pre-2004 states below are the opposite, where the count may
# not move at all. Counted around each invocation rather than over the whole log, because the first one ran on whatever
# edition the host running the self-test happens to be - and on a host whose own state answered nothing there is no
# answers.log to read, which is why the helper returns 0 for a missing file rather than throwing.
function Get-M9GateCount([string]$StatePath) {
    $log = Join-Path $StatePath 'answers.log'
    if (-not (Test-Path -LiteralPath $log)) { return 0 }
    return @(Get-Content -LiteralPath $log | Where-Object { $_ -match ' M9/gate ' }).Count
}
$gatesBefore31 = Get-M9GateCount $r31.State
$r31a = Invoke-Campaign 'edition' @('-Resume', '-Redo', 'M9', '-Scenarios', 'M9') "M9=skip`r`n"
$s31a = Read-State $r31.State
$gates31 = Get-M9GateCount $r31.State
Assert-True '31. on Pro, M9 reaches the gate: since Windows 10 2004 with KB 5024351 the edition does not decide enforcement' ($s31a.Scenarios.M9.Result -eq 'SKIPPED' -and $s31a.Scenarios.M9.Detail -eq 'skipped by the user' -and (($r31a.Output -join ' ') -match 'prerequisite met - Microsoft Windows 11 Pro \(EditionID Professional\)') -and $gates31 -eq ($gatesBefore31 + 1)) ($s31a.Scenarios.M9.Result + ' / ' + $s31a.Scenarios.M9.Detail + ' / gates ' + $gatesBefore31 + ' -> ' + $gates31)
Set-CraftedEdition $stateFile31 $true 'Core' 'Microsoft Windows 11 Home' $false
$r31b = Invoke-Campaign 'edition' @('-Resume', '-Redo', 'M9', '-Scenarios', 'M9') "M9=done`r`n"
$s31b = Read-State $r31.State
Assert-True '31. on Home, M9 is skipped before anyone is asked, with the edition named' ($s31b.Scenarios.M9.Result -eq 'SKIPPED' -and $s31b.Scenarios.M9.Detail -like 'prerequisite not met: AppLocker is not available on this edition (Microsoft Windows 11 Home, EditionID Core)*' -and (Get-M9GateCount $r31.State) -eq $gates31) ($s31b.Scenarios.M9.Result + ' / ' + $s31b.Scenarios.M9.Detail)
Set-CraftedEdition $stateFile31 $false 'Professional' 'Microsoft Windows 10 Pro' $true '18363.1234'
$r31d = Invoke-Campaign 'edition' @('-Resume', '-Redo', 'M9', '-Scenarios', 'M9') "M9=done`r`n"
$s31d = Read-State $r31.State
Assert-True '31. on a Windows 10 build below 2004, M9 is skipped before anyone is asked: there the edition still decides' ($s31d.Scenarios.M9.Result -eq 'SKIPPED' -and $s31d.Scenarios.M9.Detail -like 'prerequisite not met: AppLocker policies deployed through Group Policy are supported on Enterprise, Education and Server editions below Windows 10 version 2004 (Microsoft Windows 10 Pro, EditionID Professional, build 18363.1234)*' -and (Get-M9GateCount $r31.State) -eq $gates31) ($s31d.Scenarios.M9.Result + ' / ' + $s31d.Scenarios.M9.Detail)
Set-CraftedEdition $stateFile31 $true 'Core' 'Microsoft Windows 11 Home' $false
# M9's service facts are crafted rather than measured, so that the way-back lines below do not depend on the
# Application Identity service of whatever host runs the self-test; every invocation rewrites RECOVER.txt from the state.
$crafted31 = Get-Content -LiteralPath $stateFile31 -Raw -Encoding UTF8 | ConvertFrom-Json
$crafted31.Scenarios.M9.Facts = [pscustomobject]@{ AppIDSvcStartType = 'Manual'; AppIDSvcStatus = 'Stopped' }
[IO.File]::WriteAllText($stateFile31, ($crafted31 | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding($false)))
$r31c = Invoke-Campaign 'edition' @('-Resume', '-Scenarios', 'M8') "M8=skip`r`n"
$out31c = $r31c.Output -join "`n"
Assert-True '31. on Home, M8 names the registry lines as the way for this machine' (($out31c -match 'This machine: Microsoft Windows 11 Home \(EditionID Core\) - no gpedit\.msc: take the registry lines') -and ($out31c -match 'reg add "HKLM\\SOFTWARE\\Policies\\Microsoft\\Windows\\PowerShell" /v ExecutionPolicy /t REG_SZ /d AllSigned /f')) (($r31c.Output | Where-Object { $_ -match 'This machine|reg add' }) -join ' / ')
$s31c = Read-State $r31.State
Assert-True '31. M8 recorded how the policy is applied here' ([string]$s31c.Scenarios.M8.Facts.PolicyWay -eq 'registry' -and [string]$s31c.Scenarios.M8.Facts.Edition -eq 'Microsoft Windows 11 Home / Core') ('facts: ' + ($s31c.Scenarios.M8.Facts | ConvertTo-Json -Compress))
$recover31 = $(if (Test-Path -LiteralPath (Join-Path $r31.State 'RECOVER.txt')) { Get-Content -LiteralPath (Join-Path $r31.State 'RECOVER.txt') -Raw } else { '' })
Assert-True '31. RECOVER.txt carries the way back without gpedit as well' ($recover31 -match 'reg delete "HKLM\\SOFTWARE\\Policies\\Microsoft\\Windows\\PowerShell" /v ExecutionPolicy /f') ('RECOVER.txt length ' + $recover31.Length)
# M9's way back: the recorded startup type as a command that runs as written. A note after the command on the same
# line is not a comment to sc.exe or reg.exe, it is more arguments, and this file exists to be copied from (Codex
# round 1 on PR #16). The registry line is there because sc config is refused once the Script rules are gone.
$recoverLines31 = @(Get-Content -LiteralPath (Join-Path $r31.State 'RECOVER.txt'))
$scLine31 = @($recoverLines31 | Where-Object { $_ -match '^\s*sc config AppIDSvc start= demand\s*$' })
$stopLine31 = @($recoverLines31 | Where-Object { $_ -match '^\s*net stop AppIDSvc\s*$' })
$regLine31 = @($recoverLines31 | Where-Object { $_ -match '^\s*reg add "HKLM\\SYSTEM\\CurrentControlSet\\Services\\AppIDSvc" /v Start /t REG_DWORD /d 3 /f\s*$' })
Assert-True '31. RECOVER.txt gives M9 its recorded service commands, one per line and runnable as written' ($scLine31.Count -eq 1 -and $stopLine31.Count -eq 1 -and $regLine31.Count -eq 1 -and ($recover31 -match 'Access is denied')) (($recoverLines31 | Where-Object { $_ -match 'AppIDSvc' }) -join ' | ')

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

Copy-Item -LiteralPath $top -Destination (Join-Path $desk33 ('NHC-M3\NetworkHealthCheck-' + $version + '-old')) -Recurse -Force   # a second tree beside the first
Set-ExtractedLater (Join-Path $desk33 'NHC-M3')
$r33c = Invoke-Campaign 'stale' @('-Resume', '-Redo', 'M3', '-Scenarios', 'M3') "M3=done`r`n"
$s33c = Read-State $r33a.State
Assert-True '33. two package trees under the folder are refused (Codex round 3)' ($s33c.Scenarios.M3.Result -eq 'SKIPPED' -and $s33c.Scenarios.M3.Detail -like ('precondition not met: more than one package tree under ' + $desk33 + '\NHC-M3 (2 copies of Start-English.cmd): remove *')) ($s33c.Scenarios.M3.Result + ' / ' + $s33c.Scenarios.M3.Detail)

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
Assert-True '34. the revert instruction re-creates the values as they were, kinds included' (($out34b -match 'Put it back as it was \(MachinePolicy was RemoteSigned before M8\)') -and ($out34b -match 'reg add "HKLM\\SOFTWARE\\Policies\\Microsoft\\Windows\\PowerShell" /v ExecutionPolicy /t REG_EXPAND_SZ /d "RemoteSigned" /f') -and ($out34b -match 'reg add "HKLM\\SOFTWARE\\Policies\\Microsoft\\Windows\\PowerShell" /v EnableScripts /t REG_SZ /d "1" /f')) (($r34b.Output | Where-Object { $_ -match 'Put it back|reg add' }) -join ' / ')
$s34b = Read-State $r34.State
Assert-True '34. the verification compares with what was there, value by value, and names what differs' ($s34b.Scenarios.M8.Result -eq 'PENDING' -and $s34b.Scenarios.M8.Reverted -like 'NOT VERIFIED - *before M8*' -and $s34b.Scenarios.M8.Reverted -like '*ExecutionPolicy*' -and $r34b.ExitCode -eq 1) ($s34b.Scenarios.M8.Result + ' / ' + $s34b.Scenarios.M8.Reverted + ' / exit ' + $r34b.ExitCode)

$crafted34c = Get-Content -LiteralPath $stateFile34 -Raw -Encoding UTF8 | ConvertFrom-Json
$crafted34c.Scenarios.M8.Facts.RegExecutionPolicyBefore = ''; $crafted34c.Scenarios.M8.Facts.RegExecutionPolicyKindBefore = 'String'
$crafted34c.Scenarios.M8.Facts.RegEnableScriptsBefore = 'absent'; $crafted34c.Scenarios.M8.Facts.RegEnableScriptsKindBefore = 'absent'
[IO.File]::WriteAllText($stateFile34, ($crafted34c | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding($false)))
$r34c = Invoke-Campaign 'm8facts' @('-Resume', '-Scenarios', 'M8') "M8/revert=done`r`n"
$out34c = $r34c.Output -join "`n"
Assert-True '34. an existing empty value comes back empty, an absent one is deleted (Codex round 3)' (($out34c -match 'reg add "HKLM\\SOFTWARE\\Policies\\Microsoft\\Windows\\PowerShell" /v ExecutionPolicy /t REG_SZ /d "" /f') -and ($out34c -match 'reg delete "HKLM\\SOFTWARE\\Policies\\Microsoft\\Windows\\PowerShell" /v EnableScripts /f')) (($r34c.Output | Where-Object { $_ -match 'reg add|reg delete' }) -join ' / ')

$crafted34d = Get-Content -LiteralPath $stateFile34 -Raw -Encoding UTF8 | ConvertFrom-Json
$crafted34d.Scenarios.M8.Facts.RegExecutionPolicyBefore = 'absent'; $crafted34d.Scenarios.M8.Facts.RegExecutionPolicyKindBefore = 'String'   # a value whose data happens to read 'absent'
$crafted34d.Scenarios.M8.Facts.RegEnableScriptsBefore = 'a\0b'; $crafted34d.Scenarios.M8.Facts.RegEnableScriptsKindBefore = 'MultiString'
[IO.File]::WriteAllText($stateFile34, ($crafted34d | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding($false)))
$r34d = Invoke-Campaign 'm8facts' @('-Resume', '-Scenarios', 'M8') "M8/revert=done`r`n"
$out34d = $r34d.Output -join "`n"
Assert-True '34. the data comes back as recorded, whatever it says, and a REG_MULTI_SZ comes back as one (Codex round 4)' (($out34d -match 'reg add "HKLM\\SOFTWARE\\Policies\\Microsoft\\Windows\\PowerShell" /v ExecutionPolicy /t REG_SZ /d "absent" /f') -and ($out34d -match 'reg add "HKLM\\SOFTWARE\\Policies\\Microsoft\\Windows\\PowerShell" /v EnableScripts /t REG_MULTI_SZ /d "a\\0b" /f')) (($r34d.Output | Where-Object { $_ -match 'reg add|reg delete' }) -join ' / ')

# -------------------- 37. M8 is measured by the signature refusal itself, not by PowerShell's classification of it --------------------
Write-Output ''
Write-Output '37. what M8 may accept as the refusal: the signature message itself, in a display language the driver reads. The classification PowerShell prints beside that message - SecurityError, UnauthorizedAccess - says that a security policy refused the script and not which one, so output recognized by those two words alone claims more than it read (backlog #25). M8 cannot run in this self-test, since AllSigned is a machine policy and needs elevation, so the predicate is loaded out of the driver and run on captured output of each shape, and M8''s own use of it is asserted on the driver''s AST'
$tokens37 = $null; $errors37 = $null
$ast37 = [System.Management.Automation.Language.Parser]::ParseFile($driver, [ref]$tokens37, [ref]$errors37)
$defs37 = @{}
foreach ($f in $ast37.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if (-not $defs37.ContainsKey($f.Name)) { $defs37[$f.Name] = @() }
    $defs37[$f.Name] += $f
}
$loaded37 = @('Get-SignatureRefusal')   # what this case defines below; the guard after it is what keeps that list honest
Assert-True '37. the driver defines Get-SignatureRefusal once, so this case runs that definition and no other' ($defs37.ContainsKey('Get-SignatureRefusal') -and $defs37['Get-SignatureRefusal'].Count -eq 1) ('definitions: ' + $(if ($defs37.ContainsKey('Get-SignatureRefusal')) { $defs37['Get-SignatureRefusal'].Count } else { 0 }))
$needs37 = @()
if ($defs37.ContainsKey('Get-SignatureRefusal') -and $defs37['Get-SignatureRefusal'].Count -eq 1) {
    # A function of the driver that this one calls would be missing here, and the case would be measuring something the
    # driver never runs - so it is named and the case fails, rather than the list of loaded functions being trusted.
    $needs37 = @($defs37['Get-SignatureRefusal'][0].Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ -and $defs37.ContainsKey($_) -and $loaded37 -notcontains $_ } | Sort-Object -Unique)
    Invoke-Expression $defs37['Get-SignatureRefusal'][0].Extent.Text
}
Assert-True '37. it calls no function of the driver that this case has not loaded, so what runs here is what runs there' ($needs37.Count -eq 0) ('also needed: ' + ($needs37 -join ', '))
function Get-FreeVariables($Function) {
    # What the body reads without having taken it as a parameter, assigned it, or been given it by the loop it is in.
    # A function that reads a variable of the driver behaves differently here, where that variable does not exist, and
    # PowerShell says nothing about it - an unset variable is $null. Automatic variables and the environment are not
    # the driver's state and are left out; a scope-qualified read ($script:x) is the driver's and is not.
    $auto = @('_', 'PSItem', 'true', 'false', 'null', 'Matches', 'args', 'PSScriptRoot', 'PSCommandPath')
    $declared = @()
    if ($Function.Parameters) { $declared += @($Function.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }) }
    $declared += @($Function.Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] }, $true) | ForEach-Object { $_.Left.VariablePath.UserPath })
    $declared += @($Function.Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.ForEachStatementAst] }, $true) | ForEach-Object { $_.Variable.VariablePath.UserPath })
    return @($Function.Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true) | ForEach-Object { [string]$_.VariablePath.UserPath } | Where-Object { $_ -and ($declared -notcontains $_) -and ($auto -notcontains $_) -and ($_ -notlike 'env:*') } | Sort-Object -Unique)
}
$free37 = @()
if ($defs37.ContainsKey('Get-SignatureRefusal') -and $defs37['Get-SignatureRefusal'].Count -eq 1) { $free37 = @(Get-FreeVariables $defs37['Get-SignatureRefusal'][0]) }
Assert-True '37. and it reads no variable of the driver either, which would be $null here and say nothing about it' ($free37.Count -eq 0) ('free variables: ' + ($free37 -join ', '))
# A check nobody has seen fire is a check nobody has tested: the same reading, on a function of the driver that does
# read one of its variables, has to name that variable.
$control37 = @()
if ($defs37.ContainsKey('Get-MachinePolicyExecutionPolicy')) { $control37 = @(Get-FreeVariables $defs37['Get-MachinePolicyExecutionPolicy'][0]) }
Assert-True '37. the reading is not vacuous: on Get-MachinePolicyExecutionPolicy, which reads the driver''s $PsExe, it names it' ($control37 -contains 'PsExe') ('free variables found there: ' + ($control37 -join ', '))
# Round 8 of PR #65: which capture of PowerShell's messages belongs to this run is a decision of its own, so it is a
# function of its own and is loaded the same way. A run that leaves such a file needs a policy that blocks the script,
# which no self-test can impose, so it is given crafted candidates instead.
$loaded37 += 'Select-CapturedMessages'
Assert-True '37. the driver defines Select-CapturedMessages once as well' ($defs37.ContainsKey('Select-CapturedMessages') -and $defs37['Select-CapturedMessages'].Count -eq 1) ('definitions: ' + $(if ($defs37.ContainsKey('Select-CapturedMessages')) { $defs37['Select-CapturedMessages'].Count } else { 0 }))
$needsSel37 = @(); $freeSel37 = @()
if ($defs37.ContainsKey('Select-CapturedMessages') -and $defs37['Select-CapturedMessages'].Count -eq 1) {
    $needsSel37 = @($defs37['Select-CapturedMessages'][0].Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ -and $defs37.ContainsKey($_) -and $loaded37 -notcontains $_ } | Sort-Object -Unique)
    $freeSel37 = @(Get-FreeVariables $defs37['Select-CapturedMessages'][0])
    Invoke-Expression $defs37['Select-CapturedMessages'][0].Extent.Text
}
Assert-True '37. and it too calls and reads nothing of the driver that this case has not loaded' (($needsSel37.Count -eq 0) -and ($freeSel37.Count -eq 0)) ('also needed: ' + ($needsSel37 -join ', ') + '; free variables: ' + ($freeSel37 -join ', '))
function New-Capture37([string]$Dir, [string]$Name, [datetime]$When) { [pscustomobject]@{ FullName = (Join-Path $Dir $Name); DirectoryName = $Dir; Name = $Name; LastWriteTime = $When } }
$copy37 = 'C:\state\M8\en-US'
$ours37 = New-Capture37 $copy37 'PowerShellMessages_20260914_010203.txt' (Get-Date)
$foreign37 = New-Capture37 $env:TEMP 'NetworkHealthCheck_PowerShellMessages_20260914_010204.txt' ((Get-Date).AddSeconds(5))
$namedIn37 = 'ERROR: Windows PowerShell could not run the program file.' + "`n" + 'What PowerShell said, kept in "' + $ours37.FullName + '":'
$sel37a = Select-CapturedMessages @($ours37, $foreign37) $namedIn37 $copy37
Assert-True '37. a capture another launcher left under this account, newer than this run''s own, does not answer for this run' ((([string]@($sel37a.Files)[0].FullName) -eq $ours37.FullName) -and ($sel37a.Reason -like '*named by this run*')) ('picked: ' + [string]$sel37a.File.FullName + '; ' + $sel37a.Reason)
$sel37b = Select-CapturedMessages @($foreign37) 'this launcher named no file at all' $copy37
Assert-True '37. and where the launcher named none of them, none is read and the reason says how many there were' ((@($sel37b.Files).Count -eq 0) -and ($sel37b.Reason -like '*named none of them*')) ('picked: ' + @($sel37b.Files).Count + ' file(s); ' + $sel37b.Reason)
$sel37c = Select-CapturedMessages @($ours37) 'this launcher named no file at all' $copy37
Assert-True '37. a capture in this run''s own folder is this run''s, named or not - the folder is made for it' ((([string]@($sel37c.Files)[0].FullName) -eq $ours37.FullName) -and ($sel37c.Reason -like '*own folder*')) ('picked: ' + [string]$sel37c.File.FullName + '; ' + $sel37c.Reason)
$sel37d = Select-CapturedMessages @() '' $copy37
Assert-True '37. and a run that left no capture says that, rather than reading something else' ((@($sel37d.Files).Count -eq 0) -and ($sel37d.Reason -like '*kept no messages file*')) ('picked: ' + @($sel37d.Files).Count + ' file(s); ' + $sel37d.Reason)
# What a caller counts, which is the whole of the defect the machine found. @() around a single value that may be
# $null is an array holding one null - Count 1, and .FullName on it is $null - so a run that left no capture was read
# as a run that left one, and M7 and M9 both ended in "cannot bind argument to parameter 'LiteralPath' because it is
# null" with the machine changed and nothing measured (the campaign of 2026-09-15). The answer is a collection, and
# none of it is none.
Assert-True '37. and none is an empty collection, not a null a caller would count as one - the shape that ended two scenarios on the first machine this ever ran on' (((@($sel37b.Files) | Where-Object { $null -ne $_ }).Count -eq @($sel37b.Files).Count) -and ((@($sel37d.Files) | Where-Object { $null -ne $_ }).Count -eq @($sel37d.Files).Count) -and (@($sel37d.Files).Count -eq 0) -and (@($sel37a.Files).Count -eq 1)) ('none-standings count: ' + @($sel37b.Files).Count + ', ' + @($sel37d.Files).Count + '; the named one: ' + @($sel37a.Files).Count)
# A refusal the console folded. These are the bytes a real AllSigned run wrote on DESKTOP-CO7QIMR on 2026-09-15: the
# message is whole, and the phrase is split across a line break because PowerShell folds at the width of the buffer it
# prints into, mid-word where that is where the width falls.
$folded37 = @('File C:\state\M8\en-US\NetworkHealthCheck.ps1 cannot be loaded',
              '. The file C:\state\M8\en-US\NetworkHealthCheck.ps1 is not dig',
              'itally signed. You cannot run this script on the current system. For more information about running',
              ' scripts and setting execution policy, see about_Execution_Policies at https:/go.microsoft.com/fwlink/?LinkID=135170.',
              '    + CategoryInfo          : SecurityError: (:) [], ParentContainsErrorRecordException',
              '    + FullyQualifiedErrorId : UnauthorizedAccess')
$foldRead37 = Get-SignatureRefusal $folded37 @('C:\state\M8\en-US')
Assert-True '37. a refusal the console folded mid-word is still the refusal - no line carries the phrase, and reading line by line reported the classification without the message on a machine whose capture held it' (($foldRead37.Matched -eq $true) -and ($foldRead37.Culture -eq 'en-US') -and ([string]$foldRead37.Detail -like '*folded*')) ('read as: ' + [string]$foldRead37.Detail)
Assert-True '37. and the reading is not vacuous: no single line of that capture carries the phrase' ((@($folded37 | Where-Object { $_ -like '*is not digitally signed*' }).Count -eq 0) -and (($folded37 -join '') -like '*is not digitally signed*')) ('lines carrying it: ' + @($folded37 | Where-Object { $_ -like '*is not digitally signed*' }).Count)
$usesSel37 = @()
if ($defs37.ContainsKey('Invoke-LauncherRun')) { $usesSel37 = @($defs37['Invoke-LauncherRun'][0].Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Select-CapturedMessages' }, $true)) }
Assert-True '37. and Invoke-LauncherRun decides through it which capture is its own, instead of taking the newest one it can see' ($usesSel37.Count -eq 1) ('calls in Invoke-LauncherRun: ' + $usesSel37.Count)
# The three shapes: a security refusal that is not about signing - PowerShell's documented wording for a Software
# Restriction Policy, carrying the classification and no signature message - and the signature refusal in each language
# the driver reads. The zh-TW message is built from its code points because this file is ASCII and carries no
# byte-order mark - Windows PowerShell reads a script without one in the machine's ANSI code page, and the characters
# would not survive being written here.
$blocked37 = @('File C:\NHC\en-US\NetworkHealthCheck.ps1 cannot be loaded because it is blocked by software restriction policies, such as those created by using Group Policy.',
               '    + CategoryInfo          : SecurityError: (:) [], PSSecurityException',
               '    + FullyQualifiedErrorId : UnauthorizedAccess')
$unsignedEn37 = @('File C:\NHC\en-US\NetworkHealthCheck.ps1 cannot be loaded. The file C:\NHC\en-US\NetworkHealthCheck.ps1 is not digitally signed. You cannot run this script on the current system.',
                  '    + CategoryInfo          : SecurityError: (:) [], PSSecurityException',
                  '    + FullyQualifiedErrorId : UnauthorizedAccess')
$zh37 = -join @(0x672A, 0x7D93, 0x6578, 0x4F4D, 0x7C3D, 0x7F72 | ForEach-Object { [char]$_ })
$unsignedZh37 = @(('C:\NHC\zh-TW\NetworkHealthCheck.ps1 ' + $zh37), '    + FullyQualifiedErrorId : UnauthorizedAccess')
$r37a = Get-SignatureRefusal $blocked37
Assert-True '37. a refusal that is not about signing, carrying the same classification, is not the signature refusal' ((-not $r37a.Matched) -and $r37a.Generic -and ($r37a.Detail -like '*SecurityError / UnauthorizedAccess*')) ('Matched: ' + $r37a.Matched + '; ' + $r37a.Detail)
Assert-True '37. and the miss names every message the driver does read, so the answer is one line here and not a looser test' (($r37a.Detail -like '*en-US*') -and ($r37a.Detail.Contains($zh37))) $r37a.Detail
$r37b = Get-SignatureRefusal $unsignedEn37
Assert-True '37. the en-US signature message is the refusal, and the language it was read in is named' ($r37b.Matched -and $r37b.Culture -eq 'en-US') ('Matched: ' + $r37b.Matched + '; culture: ' + $r37b.Culture)
$r37c = Get-SignatureRefusal $unsignedZh37
Assert-True '37. the zh-TW signature message is the refusal, and the language it was read in is named' ($r37c.Matched -and $r37c.Culture -eq 'zh-TW') ('Matched: ' + $r37c.Matched + '; culture: ' + $r37c.Culture)
$r37d = Get-SignatureRefusal @('The system cannot find the path specified.', '')
Assert-True '37. output with neither the message nor the classification is a miss that says which it was' ((-not $r37d.Matched) -and (-not $r37d.Generic) -and ($r37d.Detail -like '*neither the signature message nor any security classification*')) ('Matched: ' + $r37d.Matched + '; ' + $r37d.Detail)
$r37e = Get-SignatureRefusal @()
Assert-True '37. a launcher that captured nothing is a miss, not a match' (-not $r37e.Matched) ('Matched: ' + $r37e.Matched + '; ' + $r37e.Detail)
# PowerShell names the script it refused inside its error, and the operator names the folder that script was copied
# into: a state directory called after the message would put the phrase on the line of a refusal that has nothing to do
# with signing (PR #65, round 7). The paths are taken out of the line before it is searched. Asserted as a pair, so
# that the trap is shown to be real rather than assumed: the same output matches when nothing is taken out.
$trapDir37 = 'C:\nhc\is not digitally signed'
$trap37 = @(('File ' + $trapDir37 + '\M8\en-US\NetworkHealthCheck.ps1 cannot be loaded because it is blocked by software restriction policies, such as those created by using Group Policy.'),
            '    + CategoryInfo          : SecurityError: (:) [], PSSecurityException',
            '    + FullyQualifiedErrorId : UnauthorizedAccess')
$r37f = Get-SignatureRefusal $trap37 @($trapDir37)
Assert-True '37. a folder named after the message is not the message' ((-not $r37f.Matched) -and $r37f.Generic) ('Matched: ' + $r37f.Matched + '; ' + $r37f.Detail)
$r37g = Get-SignatureRefusal $trap37 @()
Assert-True '37. and the trap is real: the same output, with no path taken out of it, does match' ($r37g.Matched) ('Matched: ' + $r37g.Matched + '; culture: ' + $r37g.Culture)
# The predicate being right is half of it: M8 has to be the scenario that asks it, and it has to read the policy again
# after the run - a correct predicate the scenario never calls would measure nothing.
$m8Hash37 = @($ast37.FindAll({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] -and @($n.KeyValuePairs | Where-Object { ($_.Item1.Extent.Text.Trim("'", '"') -eq 'Id') -and ($_.Item2.Extent.Text.Trim("'", '"') -eq 'M8') }).Count -eq 1 }, $true))
Assert-True '37. the driver has one M8 scenario, so the two assertions below are about that one' ($m8Hash37.Count -eq 1) ('M8 scenarios found: ' + $m8Hash37.Count)
$m8Calls37 = @()
if ($m8Hash37.Count -eq 1) {
    $pair37 = @($m8Hash37[0].KeyValuePairs | Where-Object { $_.Item1.Extent.Text.Trim("'", '"') -eq 'Action' })
    if ($pair37.Count -eq 1) { $m8Calls37 = @($pair37[0].Item2.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ } | Sort-Object -Unique) }
}
Assert-True '37. M8 decides on this predicate' ($m8Calls37 -contains 'Get-SignatureRefusal') ('M8 Action calls: ' + ($m8Calls37 -join ', '))
Assert-True '37. and reads the machine policy again inside the action, so the refusal is tied to the policy in force and not only to the one the precondition saw' ($m8Calls37 -contains 'Get-MachinePolicyExecutionPolicy') ('M8 Action calls: ' + ($m8Calls37 -join ', '))
# Round 1 of PR #65: the predicate was being fed the launcher's console output, and the launcher's own suggested action
# names the signature refusal on every blocked run - so the phrase was in the console whatever had refused the script,
# and a refusal that was not about signing would have passed as M8 again through a door the predicate never saw. What
# it may read is the file the launcher keeps PowerShell's own messages in. Two assertions: the launchers do carry the
# phrase (the reason), and the scenario passes the messages rather than the console (the fix). If a launcher's wording
# ever stops carrying it, the first fails and someone reads this again instead of the hazard quietly leaving the record.
$carry37 = @()
foreach ($lang37 in @('en-US', 'zh-TW')) {
    $path37 = Join-Path $root ('healthcheck\' + $lang37 + '\Start-NetworkCheck-Console.cmd')
    $lines37 = @()
    if (Test-Path -LiteralPath $path37) { $lines37 = @(Get-Content -LiteralPath $path37 -Encoding UTF8) }
    if ((Get-SignatureRefusal $lines37).Matched) { $carry37 += $lang37 }
}
Assert-True '37. both shipped console launchers print the signature phrase in their own suggested action, which is why the console is not what the predicate may read' ($carry37.Count -eq 2) ('launchers whose own text carries it: ' + $(if ($carry37.Count) { $carry37 -join ', ' } else { 'none' }))
$fed37 = ''
if ($m8Hash37.Count -eq 1 -and $pair37.Count -eq 1) {
    $calls37 = @($pair37[0].Item2.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Get-SignatureRefusal' }, $true))
    if ($calls37.Count -eq 1 -and $calls37[0].CommandElements.Count -ge 2) { $fed37 = [string]$calls37[0].CommandElements[1].Extent.Text }
}
Assert-True '37. and M8 feeds it what PowerShell printed, not the console the launcher wrote that suggestion into' ($fed37 -eq '$r.PowerShellMessages') ('fed with: ' + $(if ($fed37) { $fed37 } else { 'nothing this case could read' }))
$fedPaths37 = ''
if ($calls37.Count -eq 1 -and $calls37[0].CommandElements.Count -ge 3) { $fedPaths37 = [string]$calls37[0].CommandElements[2].Extent.Text }
Assert-True '37. and hands over the paths PowerShell prints inside its error, so the folder the script was copied into cannot answer for the message' (($fedPaths37 -match '\$r\.Copy') -and ($fedPaths37 -match '\$StateDir')) ('second argument: ' + $(if ($fedPaths37) { $fedPaths37 } else { 'none' }))
# Round 2 of PR #65: the file was read without naming its encoding. The launchers run `chcp 65001` on their third line,
# so what they and the PowerShell under them write is UTF-8 with no byte-order mark, and Get-Content without -Encoding
# decodes a file without one in the machine's ANSI code page - on this machine, CP950, the zh-TW refusal comes back as
# something the predicate cannot find. A rule rather than one call, and over the whole function, because every file
# Invoke-LauncherRun reads was written by our own launcher under that same chcp: the Zone.Identifier stream elsewhere
# in the driver is Windows's and is ASCII, and is not this rule's business.
$unencoded37 = @()
if ($defs37.ContainsKey('Invoke-LauncherRun')) {
    $unencoded37 = @($defs37['Invoke-LauncherRun'][0].Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Get-Content' }, $true) |
        Where-Object { @($_.CommandElements | Where-Object { ($_ -is [System.Management.Automation.Language.CommandParameterAst]) -and ($_.ParameterName -eq 'Encoding') }).Count -eq 0 } |
        ForEach-Object { 'line ' + $_.Extent.StartLineNumber })
}
Assert-True '37. and every file Invoke-LauncherRun reads names its encoding, since the launcher writes UTF-8 and this runtime would read it in the machine''s ANSI code page' (($defs37.ContainsKey('Invoke-LauncherRun')) -and ($unencoded37.Count -eq 0)) ('reads without -Encoding: ' + $(if ($unencoded37.Count) { $unencoded37 -join ', ' } else { 'none' }) + '; function found: ' + $defs37.ContainsKey('Invoke-LauncherRun'))

# -------------------- 40. which environment report belongs to this run --------------------
# Backlog #29, and the defect PR #65 round 8 named and left in place: Invoke-LauncherRun collected every
# NetworkHealthCheck_ENVIRONMENT_*.txt written under %TEMP% since the run started, and all three policy scenarios
# decide on that count - M7 wants exactly one, M8 wants none, M9 reads one as the guard having fired. A second
# launcher started under the same account during the run leaves a file that looks just as fresh, and the launcher
# names the environment report by a wildcard alone, so round 8's correlation - the launcher naming the file it wrote -
# cannot reach it. What can is the report's own text: the guard states the folder of the script that wrote it, and a
# scenario's script is a staged copy made for that run alone. A run that writes such a report needs a policy no
# self-test can impose, so the reports are crafted here and the predicate is loaded out of the driver.
Write-Output ''
Write-Output '40. the environment reports of this run, told apart from the ones another run left under the same %TEMP%'
$tokens40 = $null; $errors40 = $null
$ast40 = [System.Management.Automation.Language.Parser]::ParseFile($driver, [ref]$tokens40, [ref]$errors40)
$defs40 = @{}
foreach ($f in $ast40.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if (-not $defs40.ContainsKey($f.Name)) { $defs40[$f.Name] = @() }
    $defs40[$f.Name] += $f
}
$loaded40 = @('Select-EnvironmentReports')
Assert-True '40. the driver defines Select-EnvironmentReports once, so this case runs that definition and no other' ($defs40.ContainsKey('Select-EnvironmentReports') -and $defs40['Select-EnvironmentReports'].Count -eq 1) ('definitions: ' + $(if ($defs40.ContainsKey('Select-EnvironmentReports')) { $defs40['Select-EnvironmentReports'].Count } else { 0 }))
$needs40 = @(); $free40 = @()
if ($defs40.ContainsKey('Select-EnvironmentReports') -and $defs40['Select-EnvironmentReports'].Count -eq 1) {
    $needs40 = @($defs40['Select-EnvironmentReports'][0].Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ -and $defs40.ContainsKey($_) -and $loaded40 -notcontains $_ } | Sort-Object -Unique)
    $free40 = @(Get-FreeVariables $defs40['Select-EnvironmentReports'][0])
    Invoke-Expression $defs40['Select-EnvironmentReports'][0].Extent.Text
}
Assert-True '40. it calls and reads nothing of the driver this case has not loaded, so what runs here is what runs there' (($needs40.Count -eq 0) -and ($free40.Count -eq 0)) ('also needed: ' + ($needs40 -join ', ') + '; free variables: ' + ($free40 -join ', '))
# The crafted reports. The guard writes the file with Set-Content -Encoding UTF8 and states the script's folder on a
# line whose label is in the display language - so the zh-TW report here carries the Chinese label, built from code
# points because this file is ASCII, and the path is the only part both languages share.
$case40 = Join-Path $WorkDir 'case40'
$copy40 = Join-Path $case40 'M7\en-US'
$other40 = Join-Path $case40 'M7-of-another-run\en-US'
$temp40 = Join-Path $case40 'temp'
New-Item -ItemType Directory -Force -Path $copy40, $other40, $temp40 | Out-Null
$zhLabel40 = [string]([char]0x8173 + [char]0x672C + [char]0x8CC7 + [char]0x6599 + [char]0x593E + [char]0xFF1A)
function New-EnvReport40([string]$Dir, [string]$Name, [string]$Label, [string]$Folder) {
    $path = Join-Path $Dir $Name
    Set-Content -LiteralPath $path -Encoding UTF8 -Value @('Network Health Check - environment report',
                                                           'Reason: PowerShell is restricted to ConstrainedLanguage language mode by an application-control policy.',
                                                           'Tool version: 1.2.14',
                                                           ($Label + $Folder))
    return (Get-Item -LiteralPath $path)
}
$beside40 = New-EnvReport40 $copy40 'NetworkHealthCheck_ENVIRONMENT_20260914_120000.txt' 'Script folder: ' $other40
$mine40 = New-EnvReport40 $temp40 'NetworkHealthCheck_ENVIRONMENT_20260914_120001.txt' 'Script folder: ' $copy40
$zh40 = New-EnvReport40 $temp40 'NetworkHealthCheck_ENVIRONMENT_20260914_120002.txt' $zhLabel40 $copy40
$foreign40 = New-EnvReport40 $temp40 'NetworkHealthCheck_ENVIRONMENT_20260914_120003.txt' 'Script folder: ' $other40
$empty40 = Join-Path $temp40 'NetworkHealthCheck_ENVIRONMENT_20260914_120004.txt'
Set-Content -LiteralPath $empty40 -Value '' -NoNewline
$empty40 = Get-Item -LiteralPath $empty40
$sel40a = Select-EnvironmentReports @() @($mine40, $foreign40) $copy40
Assert-True '40. a report another launcher left under this account during the run does not count as this run''s; the one naming this run''s folder does' ((@($sel40a.Files).Count -eq 1) -and (@($sel40a.Files)[0].FullName -eq $mine40.FullName)) ('counted: ' + (@($sel40a.Files | ForEach-Object { $_.Name }) -join ', ') + '; ' + $sel40a.Note)
Assert-True '40. and the reason the other one was refused travels with the count, so the row can say how it decided' (($sel40a.Note -like '*refused*') -and ($sel40a.Note -like ('*' + $foreign40.Name + '*'))) ('note: ' + $sel40a.Note)
$sel40b = Select-EnvironmentReports @() @($foreign40) $copy40
Assert-True '40. the reading is not vacuous: with only the other run''s report, this run has none' (@($sel40b.Files).Count -eq 0) ('counted: ' + (@($sel40b.Files | ForEach-Object { $_.Name }) -join ', ') + '; ' + $sel40b.Note)
$sel40c = Select-EnvironmentReports @() @($zh40) $copy40
Assert-True '40. a report whose folder line is in Chinese is read by its path, which is the part every language shares' (@($sel40c.Files).Count -eq 1) ('counted: ' + (@($sel40c.Files | ForEach-Object { $_.Name }) -join ', ') + '; ' + $sel40c.Note)
$sel40d = Select-EnvironmentReports @() @($empty40) $copy40
Assert-True '40. a file that says nothing is refused with that as the reason, rather than counted or ignored in silence' ((@($sel40d.Files).Count -eq 0) -and ($sel40d.Note -like '*nothing could be read*')) ('counted: ' + (@($sel40d.Files | ForEach-Object { $_.Name }) -join ', ') + '; ' + $sel40d.Note)
$sel40e = Select-EnvironmentReports @($beside40) @($foreign40) $copy40
Assert-True '40. a report in the scenario''s own folder is this run''s whatever it says - that folder is made for this run and emptied first' ((@($sel40e.Files).Count -eq 1) -and (@($sel40e.Files)[0].FullName -eq $beside40.FullName)) ('counted: ' + (@($sel40e.Files | ForEach-Object { $_.Name }) -join ', ') + '; ' + $sel40e.Note)
$usesSel40 = @()
if ($defs40.ContainsKey('Invoke-LauncherRun')) { $usesSel40 = @($defs40['Invoke-LauncherRun'][0].Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Select-EnvironmentReports' }, $true)) }
Assert-True '40. and Invoke-LauncherRun decides through it which reports are its own, instead of taking every fresh file it can see' ($usesSel40.Count -eq 1) ('calls in Invoke-LauncherRun: ' + $usesSel40.Count)
# The count is what M7, M8 and M9 each decide on, so each of them says how the count was arrived at - a run that
# refused a report of another run reads differently from one that never saw it, and the row is where that shows.
$text40 = [IO.File]::ReadAllText($driver)
$missing40 = @()
foreach ($id40 in @('M7', 'M8', 'M9')) {
    $start40 = $text40.IndexOf("@{ Id = '" + $id40 + "'")
    if ($start40 -lt 0) { $missing40 += ($id40 + ' (no scenario block)'); continue }
    $next40 = $text40.IndexOf("@{ Id = '", $start40 + 10)
    $block40 = $(if ($next40 -gt $start40) { $text40.Substring($start40, $next40 - $start40) } else { $text40.Substring($start40) })
    if ($block40 -notmatch 'EnvironmentReportsNote') { $missing40 += $id40 }
}
Assert-True '40. and each of M7, M8 and M9 reports how its count was arrived at, because the count is what each of them decides on' ($missing40.Count -eq 0) ('without the note: ' + ($missing40 -join ', '))

# -------------------- 41. the elevated helper refuses what the campaign did not write --------------------
# Backlog #29: the policy scenarios change the machine themselves now, and the campaign stays unelevated - A1 measures
# what an ordinary user gets - so the change is made by tests\policy_helper.cmd, started elevated for one step at a
# time. It runs elevated, so what it agrees to run matters: only a commands file carrying the campaign's own marker,
# and only after it has proved it is elevated. Both refusals are machine-independent and are asserted here; whether
# this machine's session is elevated is not, so the third case runs a harmless command and asserts that the result
# says which of the two happened - and that the command ran only in the elevated one.
Write-Output ''
Write-Output '41. the elevated helper: what it refuses to run, and what it says about being elevated'
$helper41 = Join-Path $tests 'policy_helper.cmd'
Assert-True '41. the helper ships in tests\' (Test-Path -LiteralPath $helper41) $helper41
$dir41 = Join-Path $WorkDir 'case41'
New-Item -ItemType Directory -Force -Path $dir41 | Out-Null
$result41 = Join-Path $dir41 'result.txt'
function Invoke-Helper41([string]$Commands, [string]$Digest) {
    if (-not $Digest) {
        # What the campaign passes: the digest of the file as it wrote it. The helper checks it before it elevates
        # anything and again on the copy it runs, so a file swapped in between fails rather than running (PR #67).
        $Digest = $(if (Test-Path -LiteralPath $Commands) { [string](Get-FileHash -LiteralPath $Commands -Algorithm SHA256).Hash } else { ('0' * 64) })
    }
    if (Test-Path -LiteralPath $result41) { Remove-Item -LiteralPath $result41 -Force }
    $ErrorActionPreference = 'Continue'
    $null = & $helper41 $Commands $result41 $Digest 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    $lines = @()
    if (Test-Path -LiteralPath $result41) { $lines = @(Get-Content -LiteralPath $result41 | ForEach-Object { [string]$_ }) }
    return @{ ExitCode = $code; Lines = $lines; Text = ($lines -join ' | ') }
}
$missing41 = Join-Path $dir41 'not-here.cmd'
$r41a = Invoke-Helper41 $missing41
Assert-True '41. a commands file that is not there is refused, and the reason names the path it looked for' (($r41a.ExitCode -eq 2) -and ($r41a.Text -like '*no commands file*') -and ($r41a.Text -like '*result=FAILED*')) ('exit ' + $r41a.ExitCode + '; ' + $r41a.Text)
$plain41 = Join-Path $dir41 'plain.cmd'
Set-Content -LiteralPath $plain41 -Encoding Ascii -Value @('@echo off', 'echo this file is not the campaign''s', 'exit /b 0')
$r41b = Invoke-Helper41 $plain41
Assert-True '41. a commands file without the campaign''s marker is refused before anything is asked about elevation' (($r41b.ExitCode -eq 3) -and ($r41b.Text -like '*marker*') -and ($r41b.Text -like '*result=FAILED*')) ('exit ' + $r41b.ExitCode + '; ' + $r41b.Text)
$ours41 = Join-Path $dir41 'ours.cmd'
Set-Content -LiteralPath $ours41 -Encoding Ascii -Value @('@echo off', 'rem NHC-POLICY-STEP SELFTEST harmless', 'set NHCFAIL=0', 'ver', 'echo step=1 rc=%ERRORLEVEL%', 'if not "%ERRORLEVEL%"=="0" set NHCFAIL=1', 'exit /b %NHCFAIL%')
$r41c = Invoke-Helper41 $ours41
$said41 = @($r41c.Lines | Where-Object { $_ -like 'elevated=*' })
$ranIt41 = ($r41c.Text -like '*step=1 rc=0*')
$unelevated41 = (($r41c.ExitCode -eq 5) -and ($r41c.Text -like '*elevated=no*') -and ($r41c.Text -like '*result=FAILED*') -and (-not $ranIt41))
$elevated41 = (($r41c.ExitCode -eq 0) -and ($r41c.Text -like '*elevated=yes*') -and ($r41c.Text -like '*result=OK*') -and $ranIt41)
Assert-True '41. and a file it does accept says whether it was elevated: unelevated it refuses and runs nothing, elevated it runs it and says OK' (($said41.Count -eq 1) -and ($unelevated41 -or $elevated41)) ('exit ' + $r41c.ExitCode + '; ' + $r41c.Text)

$wrong41 = Join-Path $dir41 'ours-but-swapped.cmd'
Set-Content -LiteralPath $wrong41 -Encoding Ascii -Value @('@echo off', 'rem NHC-POLICY-STEP SELFTEST harmless', 'exit /b 0')
$r41d = Invoke-Helper41 $wrong41 ('0' * 64)
Assert-True '41. a commands file whose digest is not the one the campaign hashed is refused, and before anything is elevated - the marker says what shape a file has, the digest says it is the file the campaign wrote' (($r41d.ExitCode -eq 4) -and ($r41d.Text -like '*not the one the campaign hashed*') -and ($r41d.Text -like '*elevated=not asked*')) ('exit ' + $r41d.ExitCode + '; ' + $r41d.Text)
# -------------------- 42. the shape of one step's commands file --------------------
# The file the campaign writes for the helper: the marker the helper insists on, every command followed by its own
# exit code before the next command can replace it, and the number of commands that failed as the file's own exit
# code. A step that fails halfway has to say so even where a later command succeeds, which is the case a single
# trailing errorlevel would get wrong - so the counter is asserted against a file whose first command fails.
Write-Output ''
Write-Output '42. the commands file one step is made of: the marker, an exit code per command, and a count of the failures'
$tokens42 = $null; $errors42 = $null
$ast42 = [System.Management.Automation.Language.Parser]::ParseFile($driver, [ref]$tokens42, [ref]$errors42)
$defs42 = @{}
foreach ($f in $ast42.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if (-not $defs42.ContainsKey($f.Name)) { $defs42[$f.Name] = @() }
    $defs42[$f.Name] += $f
}
Assert-True '42. the driver defines New-PolicyStepFile once, so this case runs that definition and no other' ($defs42.ContainsKey('New-PolicyStepFile') -and $defs42['New-PolicyStepFile'].Count -eq 1) ('definitions: ' + $(if ($defs42.ContainsKey('New-PolicyStepFile')) { $defs42['New-PolicyStepFile'].Count } else { 0 }))
$needs42 = @(); $free42 = @()
if ($defs42.ContainsKey('New-PolicyStepFile') -and $defs42['New-PolicyStepFile'].Count -eq 1) {
    $needs42 = @($defs42['New-PolicyStepFile'][0].Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ -and $defs42.ContainsKey($_) } | Sort-Object -Unique)
    $free42 = @(Get-FreeVariables $defs42['New-PolicyStepFile'][0])
    Invoke-Expression $defs42['New-PolicyStepFile'][0].Extent.Text
}
Assert-True '42. it calls and reads nothing of the driver, so what runs here is what runs there' (($needs42.Count -eq 0) -and ($free42.Count -eq 0)) ('also needed: ' + ($needs42 -join ', ') + '; free variables: ' + ($free42 -join ', '))
$dir42 = Join-Path $WorkDir 'case42'
New-Item -ItemType Directory -Force -Path $dir42 | Out-Null
$file42 = New-PolicyStepFile 'SELFTEST' 'twosteps' @('cmd /c exit 1', 'ver') $dir42
$body42 = @(Get-Content -LiteralPath $file42 | ForEach-Object { [string]$_ })
Assert-True '42. the marker the helper insists on is on its second line, where the helper looks for it' (($body42.Count -gt 2) -and ($body42[1] -like 'rem NHC-POLICY-STEP SELFTEST twosteps*')) ('line 2: ' + $(if ($body42.Count -gt 1) { $body42[1] } else { '(none)' }))
Assert-True '42. every command is followed by its own exit code, before the next command can replace it' ((@($body42 | Where-Object { $_ -like 'echo step=1 rc=*' }).Count -eq 1) -and (@($body42 | Where-Object { $_ -like 'echo step=2 rc=*' }).Count -eq 1)) ($body42 -join ' / ')
$ErrorActionPreference = 'Continue'
$out42 = @(& $env:ComSpec '/c' $file42 2>&1 | ForEach-Object { [string]$_ })
$code42 = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
Assert-True '42. a step whose first command failed exits non-zero although the second succeeded - the count, not the last command' (($code42 -ne 0) -and (@($out42 | Where-Object { $_ -like 'step=1 rc=1*' }).Count -eq 1) -and (@($out42 | Where-Object { $_ -like 'step=2 rc=0*' }).Count -eq 1)) ('exit ' + $code42 + '; ' + ($out42 -join ' | '))
$file42b = New-PolicyStepFile 'SELFTEST' 'clean' @('ver') $dir42
$ErrorActionPreference = 'Continue'
$null = & $env:ComSpec '/c' $file42b 2>&1
$code42b = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
Assert-True '42. and the reading is not vacuous: the same file with nothing failing exits 0' ($code42b -eq 0) ('exit ' + $code42b)

# -------------------- 43. the way back is built from what was recorded, not from what is there now --------------------
# M8's and M9's reverts are the lines RECOVER.txt gives a person, generated from the facts the scenario recorded
# before it changed anything. The helper runs those same lines, so what they say is what the machine gets back.
Write-Output ''
Write-Output '43. the lines that put the machine back, generated from the recorded facts'
$loaded43 = @('Get-M9RevertLines', 'Get-M8RegistryLines')
$missingDefs43 = @($loaded43 | Where-Object { -not ($defs42.ContainsKey($_) -and $defs42[$_].Count -eq 1) })
Assert-True '43. the driver defines the two line builders once each' ($missingDefs43.Count -eq 0) ('not defined once: ' + ($missingDefs43 -join ', '))
$free43 = @()
if ($missingDefs43.Count -eq 0) {
    foreach ($name in $loaded43) {
        $free43 += @(Get-FreeVariables $defs42[$name][0])
        Invoke-Expression $defs42[$name][0].Extent.Text
    }
}
Assert-True '43. neither reads a variable of the driver, which would be $null here and say nothing about it' ($free43.Count -eq 0) ('free variables: ' + ($free43 -join ', '))
$auto43 = Get-M9RevertLines @{ Facts = @{ AppIDSvcStartType = 'Automatic'; AppIDSvcStatus = 'Running'; AppLockerPolicyBefore = 'C:\state\M9\applocker-before.xml' } }
Assert-True '43. a service that was Automatic and running comes back as auto, with the registry value for the case where sc config is refused, and is not stopped' ((@($auto43 | Where-Object { $_ -like 'may fail: sc config AppIDSvc start= auto*' }).Count -eq 1) -and (@($auto43 | Where-Object { $_ -like '*Services\AppIDSvc*/d 2 /f*' }).Count -eq 1) -and (@($auto43 | Where-Object { $_ -like '*net stop*' }).Count -eq 0)) ($auto43 -join ' / ')
Assert-True '43. the local policy is removed at the registry, which needs neither PowerShell nor the AppLocker module, and the machine''s own policy is put back after it' ((@($auto43)[0] -like 'reg delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\SrpV2"*') -and (@($auto43 | Where-Object { $_ -like '*Set-AppLockerPolicy -XmlPolicy*applocker-before.xml*' }).Count -eq 1) -and (@($auto43)[-1] -eq 'gpupdate /force')) ($auto43 -join ' / ')
$manual43 = Get-M9RevertLines @{ Facts = @{ AppIDSvcStartType = 'Manual'; AppIDSvcStatus = 'Stopped' } }
Assert-True '43. a service that was Manual and stopped comes back as demand and is stopped again, and no policy is restored where none was saved' ((@($manual43 | Where-Object { $_ -like 'may fail: sc config AppIDSvc start= demand*' }).Count -eq 1) -and (@($manual43 | Where-Object { $_ -like '*/d 3 /f*' }).Count -eq 1) -and (@($manual43 | Where-Object { $_ -eq 'may fail: net stop AppIDSvc' }).Count -eq 1) -and (@($manual43 | Where-Object { $_ -like '*Set-AppLockerPolicy*' }).Count -eq 0)) ($manual43 -join ' / ')
$none43 = Get-M9RevertLines @{ Facts = @{ AppIDSvcStartType = 'n/a'; AppIDSvcStatus = 'n/a' } }
Assert-True '43. and where the service was never recorded, nothing is said about it - the policy is still removed and the machine still told to reload' ((@($none43 | Where-Object { $_ -like '*sc config*' }).Count -eq 0) -and (@($none43)[0] -like 'reg delete*SrpV2*') -and (@($none43)[-1] -eq 'gpupdate /force')) ($none43 -join ' / ')
$m8lines43 = @(Get-M8RegistryLines)
$m8text43 = [IO.File]::ReadAllText($driver)
$m8start43 = $m8text43.IndexOf("@{ Id = 'M8'")
$m8block43 = $(if ($m8start43 -ge 0) { $m8text43.Substring($m8start43, [Math]::Min(4000, $m8text43.Length - $m8start43)) } else { '' })
$m8missing43 = @($m8lines43 | Where-Object { $m8block43.IndexOf([string]$_, [System.StringComparison]::Ordinal) -lt 0 })
Assert-True '43. the two lines M8 applies are the two its instruction shows a person, so the instruction and the change cannot drift apart' (($m8lines43.Count -eq 2) -and ($m8missing43.Count -eq 0)) ('not in M8''s block: ' + ($m8missing43 -join ' / '))

# -------------------- 44. what the hooks may and may not decide --------------------
# The automation replaces the typing, not the checking: the precondition still says whether the machine is in the
# state the scenario needs, and the revert is still believed only after the scenario's own check reads the machine.
# Asserted on the driver's AST, because the policy scenarios need elevation and cannot run in this self-test.
Write-Output ''
Write-Output '44. the automated policy path: which scenarios have it, when it is taken, and what still decides'
$plan44 = $m8text43
$withHooks44 = @()
foreach ($id44 in @('A1', 'M1', 'M2', 'M3', 'M4', 'M7', 'M8', 'M9', 'A2', 'A3', 'A4')) {
    $start44 = $plan44.IndexOf("@{ Id = '" + $id44 + "'")
    if ($start44 -lt 0) { continue }
    $next44 = $plan44.IndexOf("@{ Id = '", $start44 + 10)
    $block44 = $(if ($next44 -gt $start44) { $plan44.Substring($start44, $next44 - $start44) } else { $plan44.Substring($start44) })
    if (($block44 -match '(?m)^\s+Apply = \{') -and ($block44 -match '(?m)^\s+Revert = \{')) { $withHooks44 += $id44 }
}
Assert-True '44. the three policy scenarios carry both hooks, and no other scenario carries either' ((($withHooks44 -join ',') -eq 'M7,M8,M9')) ('with both hooks: ' + ($withHooks44 -join ', '))
$fnScenario44 = @($ast42.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-Scenario' }, $true))
$fnCleanup44 = @($ast42.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Complete-Cleanup' }, $true))
Assert-True '44. Invoke-Scenario and Complete-Cleanup are each defined once' (($fnScenario44.Count -eq 1) -and ($fnCleanup44.Count -eq 1)) ('Invoke-Scenario: ' + $fnScenario44.Count + ', Complete-Cleanup: ' + $fnCleanup44.Count)
$applyIf44 = ''
if ($fnScenario44.Count -eq 1) {
    $applyIf44 = @($fnScenario44[0].Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] -and $n.Extent.Text -like '*$S.Apply*' }, $true) | ForEach-Object { $_.Clauses[0].Item1.Extent.Text })[0]
}
Assert-True '44. the apply is taken only where the scenario has one, -ManualPolicy was not given, and nobody is replaying answers' (($applyIf44 -like '*$S.Apply*') -and ($applyIf44 -like '*ManualPolicy*') -and ($applyIf44 -like '*AnswersTable*')) ('the condition: ' + $applyIf44)
$afterApply44 = ''
if ($fnScenario44.Count -eq 1) { $afterApply44 = [string]$fnScenario44[0].Extent.Text }
Assert-True '44. and what says the machine is in the state the scenario needs is still the precondition, run after the helper has been' (($afterApply44 -like '*$S.Precondition $ctx*') -and ($afterApply44.IndexOf('$ap = & $S.Apply') -lt $afterApply44.IndexOf('$autoApplied = $true'))) 'the precondition is not run between the apply and the flag'
$cleanupText44 = ''
if ($fnCleanup44.Count -eq 1) { $cleanupText44 = [string]$fnCleanup44[0].Extent.Text }
$revertAt44 = $cleanupText44.IndexOf('& $S.Revert $ctx')
$verifyAt44 = $cleanupText44.IndexOf('$v0 = & $S.Cleanup.Verify $ctx')
$attemptAt44 = $afterApply44.IndexOf('$rec.Attempted = $true; Save-State')
Assert-True '44. the attempt is recorded before the helper is asked, because a step can fail with the machine half changed and the revert has to run anyway' (($attemptAt44 -ge 0) -and ($attemptAt44 -lt $afterApply44.IndexOf('$ap = & $S.Apply'))) ('attempt at ' + $attemptAt44 + ', apply at ' + $afterApply44.IndexOf('$ap = & $S.Apply'))
Assert-True '44. the revert is believed only after the scenario''s own check has read the machine, never on the helper''s exit code' (($revertAt44 -ge 0) -and ($verifyAt44 -gt $revertAt44) -and ($cleanupText44 -like '*if ($v0.Ok)*')) ('revert at ' + $revertAt44 + ', verify at ' + $verifyAt44)
Assert-True '44. and a helper that could not put the machine back falls through to the prompt that asks a person, which is what the campaign did before' ($cleanupText44 -like '*did not put the machine back*') 'no fallback message in Complete-Cleanup'

# -------------------- 45. M9 is put back to what was there, not to a blank --------------------
# PR #67 round 1: the revert restores a Script policy the machine had of its own, and the check that certifies the
# revert demanded an empty, unenforced collection - so on such a machine the revert could never finish, and the
# instruction it fell back to told the person to delete the rules that had just been restored. Both the check and the
# instruction read what the scenario recorded before it changed anything now, the way M8's already did.
Write-Output ''
Write-Output '45. M9''s revert is verified against the Script policy the machine had, and its instruction says which way back'
$m9text45 = [IO.File]::ReadAllText($driver)
# From M9's own block onwards: M8's cleanup instruction is a scriptblock as well and comes first in the file,
# and evaluating that one would call a function of the driver this case has not loaded.
$m9at45 = $m9text45.IndexOf("@{ Id = 'M9'")
$i45 = $(if ($m9at45 -ge 0) { $m9text45.IndexOf('Cleanup = @{ Instruction = { param($Ctx)', $m9at45) } else { -1 })
$j45 = $(if ($i45 -ge 0) { $m9text45.IndexOf('Verify = { param($Ctx)', $i45) } else { -1 })
Assert-True '45. M9''s cleanup instruction is built from the recorded state, not a fixed sentence' (($i45 -ge 0) -and ($j45 -gt $i45)) ('instruction at ' + $i45 + ', verify at ' + $j45)
# The instruction reads which copy of the machine's own policy this campaign has (PR #67 round 7), so that function is
# loaded here as well - the block evaluated below calls it, and a self-test that left it out would be running code the
# driver does not have.
Assert-True '45. the driver defines Get-M9OwnPolicy once, and this case loads it because the instruction calls it' ($defs42.ContainsKey('Get-M9OwnPolicy') -and $defs42['Get-M9OwnPolicy'].Count -eq 1) ('definitions: ' + $(if ($defs42.ContainsKey('Get-M9OwnPolicy')) { $defs42['Get-M9OwnPolicy'].Count } else { 0 }))
if ($defs42.ContainsKey('Get-M9OwnPolicy') -and $defs42['Get-M9OwnPolicy'].Count -eq 1) { Invoke-Expression $defs42['Get-M9OwnPolicy'][0].Extent.Text }
$sb45 = $null
if (($i45 -ge 0) -and ($j45 -gt $i45)) {
    $block45 = $m9text45.Substring($i45, $j45 - $i45)
    $from45 = $block45.IndexOf('{ param($Ctx)')
    $to45 = $block45.LastIndexOf('}')
    Invoke-Expression ('$sb45 = ' + $block45.Substring($from45, $to45 - $from45 + 1))
}
$blank45 = @()
$own45 = @()
if ($null -ne $sb45) {
    $blank45 = @(& $sb45 @{ Facts = @{ ScriptEnforcementBefore = 'none'; ScriptRuleCountBefore = '0' } })
    $own45 = @(& $sb45 @{ Facts = @{ ScriptEnforcementBefore = 'Enabled'; ScriptRuleCountBefore = '3'; AppLockerPolicyBefore = 'C:\state\M9\applocker-before.xml' } })
}
Assert-True '45. where the machine had no Script policy of its own, the instruction is the one it has always been' ((@($blank45).Count -eq 2) -and (@($blank45)[0] -like 'AppLocker > Configure rule enforcement*delete the Script rules*')) ('lines: ' + (@($blank45) -join ' // '))
Assert-True '45. where it had one, the person is told to put THAT back, the saved copy is named, and nothing says delete the rules' ((@($own45).Count -eq 2) -and (@($own45)[0] -like '*put THAT back*') -and (@($own45)[0] -like '*applocker-before.xml*') -and (@($own45)[0] -notlike '*delete the Script rules*')) ('lines: ' + (@($own45) -join ' // '))
# To the end of M9's block, not a fixed number of characters: this window has been too small twice now, and a
# reading that falls short reports the code as not doing what it does (PR #67 rounds 4 and 5).
$verifyEnd45 = $(if ($j45 -gt 0) { $m9text45.IndexOf("@{ Id = '", $j45) } else { -1 })
$verify45 = $(if ($j45 -gt 0) { $(if ($verifyEnd45 -gt $j45) { $m9text45.Substring($j45, $verifyEnd45 - $j45) } else { $m9text45.Substring($j45) }) } else { '' })
Assert-True '45. and the check that certifies the revert reads the policy that was saved before the change, rather than demanding an empty collection' (($verify45 -like '*AppLockerPolicyBefore*') -and ($verify45 -like '*Get-AppLockerPolicyShape*') -and ($verify45 -notlike '*the revert asks for them deleted*')) 'the verify still demands a blank'
$stepText45 = ''
$fnStep45 = @($ast42.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-PolicyStepFile' }, $true))
if ($fnStep45.Count -eq 1) { $stepText45 = [string]$fnStep45[0].Extent.Text }
Assert-True '45. the step hands the helper the digest of the file it just hashed, so the consent given is for those commands' (($stepText45 -like '*Get-FileHash*') -and ($stepText45 -like '*$digest*') -and ($stepText45.IndexOf('Get-FileHash') -lt $stepText45.IndexOf('Start-Process'))) 'the digest is not computed before the helper is started'

# -------------------- 46. what a revert of M9 has to put back --------------------
# PR #67 round 2, three findings and all three about M9's own footing: Set-AppLockerPolicy without -Merge replaces the
# whole local policy, so a revert owes the exe, dll, msi and packaged-app collections as much as the script one; a
# mode and a rule count would certify M9's own two rules as the machine's own two; and the export that saves the
# machine's policy has to succeed before the policy is replaced, or there is nothing to put back from.
Write-Output ''
Write-Output '46. the policy a revert has to put back: every collection, by the ids of its rules'
# The shape is built by a canonicaliser of its own since PR #67 round 6 - one node as what it says rather than as it
# was written - so both definitions are loaded here, and neither may reach anything else of the driver's.
$loaded46 = @('Get-AppLockerPolicyShape', 'ConvertTo-XmlShape')
$defined46 = @($loaded46 | Where-Object { $defs42.ContainsKey($_) -and $defs42[$_].Count -eq 1 })
Assert-True '46. the driver defines Get-AppLockerPolicyShape and the canonicaliser it calls once each, so this case runs those definitions and no others' ($defined46.Count -eq $loaded46.Count) ('defined once: ' + ($defined46 -join ', ') + ' of ' + ($loaded46 -join ', '))
$needs46 = @(); $free46 = @()
if ($defined46.Count -eq $loaded46.Count) {
    foreach ($fn46 in $loaded46) {
        $needs46 += @($defs42[$fn46][0].Body.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ -and $defs42.ContainsKey($_) -and $loaded46 -notcontains $_ })
        $free46 += @(Get-FreeVariables $defs42[$fn46][0])
        Invoke-Expression $defs42[$fn46][0].Extent.Text
    }
    $needs46 = @($needs46 | Sort-Object -Unique)
    $free46 = @($free46 | Sort-Object -Unique)
}
Assert-True '46. it calls and reads nothing of the driver, so what runs here is what runs there' (($needs46.Count -eq 0) -and ($free46.Count -eq 0)) ('also needed: ' + ($needs46 -join ', ') + '; free variables: ' + ($free46 -join ', '))
$saved46 = '<AppLockerPolicy Version="1"><RuleCollection Type="Script" EnforcementMode="Enabled"><FilePathRule Id="AAA" /><FilePathRule Id="BBB" /></RuleCollection><RuleCollection Type="Exe" EnforcementMode="Enabled"><FilePathRule Id="CCC" /></RuleCollection></AppLockerPolicy>'
$m9own46 = '<AppLockerPolicy Version="1"><RuleCollection Type="Script" EnforcementMode="Enabled"><FilePathRule Id="111" /><FilePathRule Id="222" /></RuleCollection></AppLockerPolicy>'
$lostExe46 = '<AppLockerPolicy Version="1"><RuleCollection Type="Script" EnforcementMode="Enabled"><FilePathRule Id="BBB" /><FilePathRule Id="AAA" /></RuleCollection></AppLockerPolicy>'
$restored46 = '<AppLockerPolicy Version="1"><RuleCollection Type="Exe" EnforcementMode="Enabled"><FilePathRule Id="ccc" /></RuleCollection><RuleCollection Type="Script" EnforcementMode="Enabled"><FilePathRule Id="bbb" /><FilePathRule Id="aaa" /></RuleCollection></AppLockerPolicy>'
$empty46 = '<AppLockerPolicy Version="1"><RuleCollection Type="Script" EnforcementMode="NotConfigured" /><RuleCollection Type="Exe" EnforcementMode="NotConfigured" /></AppLockerPolicy>'
$shapeSaved46 = Get-AppLockerPolicyShape $saved46
Assert-True '46. a policy put back exactly - the same rules in the same collections, whatever their order and case - reads as the one that was saved' ((Get-AppLockerPolicyShape $restored46) -eq $shapeSaved46) ('restored: ' + (Get-AppLockerPolicyShape $restored46) + ' / saved: ' + $shapeSaved46)
Assert-True '46. M9''s own two rules do not read as the machine''s own two, which a mode and a count could not tell apart' ((Get-AppLockerPolicyShape $m9own46) -ne $shapeSaved46) ('m9: ' + (Get-AppLockerPolicyShape $m9own46) + ' / saved: ' + $shapeSaved46)
Assert-True '46. and a collection the revert lost is a difference too, although the script rules came back' ((Get-AppLockerPolicyShape $lostExe46) -ne $shapeSaved46) ('without the exe collection: ' + (Get-AppLockerPolicyShape $lostExe46))
Assert-True '46. nothing is nothing however it is spelled: collections with no rules and no enforcement drop out' ((Get-AppLockerPolicyShape $empty46) -eq '') ('empty policy reads as: [' + (Get-AppLockerPolicyShape $empty46) + ']')
Assert-True '46. and a saved file that is not a policy says so rather than reading as nothing, which would certify any machine' ((Get-AppLockerPolicyShape 'not a policy <<<') -eq 'unreadable') ('reads as: ' + (Get-AppLockerPolicyShape 'not a policy <<<'))
# The export is a prerequisite for the replacement, not a step that may fail quietly: a step file runs every line and
# counts the failures, so the apply has to stop itself between the two.
# M9's whole block, to its end: a window of a few thousand characters does not reach the hooks, because the
# instruction and the prerequisite that come before them are longer than that (this case's own first reading).
$m9apply46 = ''
$applyAt46 = $m9text45.IndexOf("@{ Id = 'M9'")
if ($applyAt46 -ge 0) {
    $endAt46 = $m9text45.IndexOf("@{ Id = '", $applyAt46 + 10)
    $m9apply46 = $(if ($endAt46 -gt $applyAt46) { $m9text45.Substring($applyAt46, $endAt46 - $applyAt46) } else { $m9text45.Substring($applyAt46) })
}
# The apply hook alone. M9's block holds Prepare as well, and since PR #67 round 6 Prepare reads the local policy too,
# so a search over the whole block for the export finds the wrong one - the same trap as round 5's fixed-size windows,
# and it is answered the same way: the slice ends where the next hook begins.
$m9hook46 = ''
$hookAt46 = $m9apply46.IndexOf('Apply = {')
if ($hookAt46 -ge 0) {
    $hookEnd46 = $m9apply46.IndexOf('Revert = {', $hookAt46)
    $m9hook46 = $(if ($hookEnd46 -gt $hookAt46) { $m9apply46.Substring($hookAt46, $hookEnd46 - $hookAt46) } else { $m9apply46.Substring($hookAt46) })
}
$exportAt46 = $m9hook46.IndexOf('Get-AppLockerPolicy -Local -Xml')
$guardAt46 = $m9hook46.IndexOf('exit /b 1', [Math]::Max(0, $m9hook46.IndexOf('Get-AppLockerPolicy -Local -Xml')))
$setAt46 = $m9hook46.IndexOf('Set-AppLockerPolicy -XmlPolicy')
Assert-True '46. the apply stops between saving the machine''s policy and replacing it, where the save wrote nothing' (($exportAt46 -ge 0) -and ($guardAt46 -gt $exportAt46) -and ($setAt46 -gt $guardAt46) -and ($m9apply46 -like '*if %%~zA EQU 0 exit /b 1*')) ('export at ' + $exportAt46 + ', guard at ' + $guardAt46 + ', replace at ' + $setAt46)
Assert-True '46. and the staged way back is checked against the digest recorded when it was staged, not against itself' (($m9apply46 -like '*RevertDigest*') -and ($m9apply46 -like "*Invoke-PolicyStepFile `$Ctx.Id 'revert' `$stagedRevert `$stagedHelper `$Ctx.Dir (*RevertDigest*")) 'the revert does not pass the recorded digest'
# And the helper's own footing: %SystemRoot%\Temp is writable by ordinary users, so a folder already there may carry
# an explicit write entry icacls /grant:r would leave in place - it is refused where it is a reparse point, removed,
# and made again by the elevated process before anything is copied into it.
$helperText46 = [IO.File]::ReadAllText($helper41)
$reparseAt46 = $helperText46.IndexOf('fsutil reparsepoint query')
$rdAt46 = $helperText46.IndexOf('rd /s /q')
$mdAt46 = $helperText46.IndexOf('md "%NHCSAFE%"')
$icaclsAt46 = $helperText46.IndexOf('icacls "%NHCSAFE%"')
$copyAt46 = $helperText46.IndexOf('copy /y "%~1" "%NHCSTEP%"')
Assert-True '46. the helper refuses a reparse point where its folder should be, makes the folder fresh, locks it, and only then copies into it' ((($reparseAt46 -ge 0) -and ($rdAt46 -gt $reparseAt46) -and ($mdAt46 -gt $rdAt46) -and ($icaclsAt46 -gt $mdAt46) -and ($copyAt46 -gt $icaclsAt46))) ('reparse ' + $reparseAt46 + ', rd ' + $rdAt46 + ', md ' + $mdAt46 + ', icacls ' + $icaclsAt46 + ', copy ' + $copyAt46)

# -------------------- 47. what M9 owes a machine whose own policy it replaced --------------------
# PR #67 round 3, four findings, all about the same file: applocker-before.xml is what the revert installs and what
# the check reads as its expected value, so where it lives and what it is decide whether either means anything. It is
# saved into the folder the helper locks now, a file already at that name is removed before the export, a document
# that is not a policy is not an empty policy, whether the machine had a policy of its own is read from that file
# rather than from the Script collection alone, and RECOVER.txt names the way back for a session that dies while the
# rules are enforced - where the campaign cannot start at all, because it lives in what the policy denies.
Write-Output ''
Write-Output '47. the policy M9 saves: where it is kept, what counts as one, and what a crash leaves the person'
Assert-True '47. a well-formed document that is not a policy reads as unreadable, not as an empty policy - the reading that would certify a machine whose policy was deleted and never put back' ((Get-AppLockerPolicyShape '<foo/>') -eq 'unreadable') ('reads as: [' + (Get-AppLockerPolicyShape '<foo/>') + ']')
Assert-True '47. and a policy with only an exe collection still reads as a policy, which is the case a Script-only reading missed' ((Get-AppLockerPolicyShape '<AppLockerPolicy Version="1"><RuleCollection Type="Exe" EnforcementMode="Enabled"><FilePathRule Id="CCC" /></RuleCollection></AppLockerPolicy>') -like 'Exe:Enabled:*FilePathRule*CCC*') ('reads as: ' + (Get-AppLockerPolicyShape '<AppLockerPolicy Version="1"><RuleCollection Type="Exe" EnforcementMode="Enabled"><FilePathRule Id="CCC" /></RuleCollection></AppLockerPolicy>'))
# The notes ask Get-M9OwnPolicy which copy of the machine's own policy this campaign has (PR #67 round 7), so both
# definitions are loaded here and neither may reach anything else of the driver's.
$loaded47 = @('Get-M9RecoveryLines', 'Get-M9OwnPolicy')
$defined47 = @($loaded47 | Where-Object { $defs42.ContainsKey($_) -and $defs42[$_].Count -eq 1 })
Assert-True '47. the driver defines the notes and the function they ask once each, so this case runs those definitions and no others' ($defined47.Count -eq $loaded47.Count) ('defined once: ' + ($defined47 -join ', ') + ' of ' + ($loaded47 -join ', '))
$needs47 = @(); $free47 = @()
if ($defined47.Count -eq $loaded47.Count) {
    foreach ($fn47 in $loaded47) {
        $needs47 += @($defs42[$fn47][0].Body.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ -and $defs42.ContainsKey($_) -and $loaded47 -notcontains $_ })
        $free47 += @(Get-FreeVariables $defs42[$fn47][0])
        Invoke-Expression $defs42[$fn47][0].Extent.Text
    }
    $needs47 = @($needs47 | Sort-Object -Unique)
    $free47 = @($free47 | Sort-Object -Unique)
}
Assert-True '47. it calls and reads nothing of the driver, so what runs here is what runs there' (($needs47.Count -eq 0) -and ($free47.Count -eq 0)) ('also needed: ' + ($needs47 -join ', ') + '; free variables: ' + ($free47 -join ', '))
$plain47 = @(Get-M9RecoveryLines @{})
Assert-True '47. with nothing recorded, the notes say what they have always said' ((($plain47 -join ' ') -like '*secpol.msc*delete the Script rules*') -and (($plain47 -join ' ') -notlike '*Set-AppLockerPolicy*')) ($plain47 -join ' / ')
$crash47 = @(Get-M9RecoveryLines @{ StagedRevert = 'C:\Windows\Temp\nhc-policy\nhc-policy-revert.cmd'; AppLockerPolicyBefore = 'C:\Windows\Temp\nhc-policy\applocker-before.xml'; AppIDSvcStartType = 'Manual'; AppIDSvcStatus = 'Stopped' })
$crashText47 = ($crash47 -join ' ')
Assert-True '47. where the apply staged the way back, the notes name that file first and say it needs no PowerShell - which is what a session that cannot start the campaign again has' (($crashText47 -like '*nhc-policy-revert.cmd*') -and ($crashText47 -like '*needs no PowerShell*')) $crashText47
Assert-True '47. and where this machine had a policy of its own, they say NOT to delete the rules and name the saved copy, instead of the sentence that would take that policy away' (($crashText47 -like '*Do NOT simply delete*') -and ($crashText47 -like '*Set-AppLockerPolicy -XmlPolicy "C:\Windows\Temp\nhc-policy\applocker-before.xml"*') -and ($crashText47 -notlike '*delete the Script rules; then*')) $crashText47
Assert-True '47. the service the scenario recorded is still put back by the same notes' (($crashText47 -like '*sc config AppIDSvc start= demand*') -and ($crashText47 -like '*net stop AppIDSvc*')) $crashText47
# The instruction reads the saved policy, not the Script collection alone: a machine with exe rules and no script
# rules had a policy of its own too, and the apply replaced all of it.
$dir47 = Join-Path $WorkDir 'case47'
New-Item -ItemType Directory -Force -Path $dir47 | Out-Null
$exeOnly47 = Join-Path $dir47 'applocker-before.xml'
Set-Content -LiteralPath $exeOnly47 -Encoding UTF8 -Value '<AppLockerPolicy Version="1"><RuleCollection Type="Exe" EnforcementMode="Enabled"><FilePathRule Id="CCC" /></RuleCollection></AppLockerPolicy>'
$exeFacts47 = @{ ScriptEnforcementBefore = 'none'; ScriptRuleCountBefore = '0'; AppLockerPolicyBefore = $exeOnly47 }
$exeLines47 = @()
if ($null -ne $sb45) { $exeLines47 = @(& $sb45 @{ Facts = $exeFacts47 }) }
Assert-True '47. a machine with exe rules and no script rules is a machine with a policy of its own, and the instruction says put THAT back' ((@($exeLines47).Count -eq 2) -and (@($exeLines47)[0] -like '*put THAT back*') -and (@($exeLines47)[0] -like '*applocker-before.xml*')) ('lines: ' + (@($exeLines47) -join ' // '))
# And the apply's own order: the old target removed, the export, its two guards, the copy into the locked folder and
# its guard, and only then the policy replaced - with the notes written before any of it runs.
$delAt47 = $m9hook46.IndexOf('del /f /q')
$exportAt47 = $m9hook46.IndexOf('Get-AppLockerPolicy -Local -Xml')
$copyAt47 = $m9hook46.IndexOf('copy /y "'' + $before + ''" "'' + $beforeCopy + ''"')
$setAt47 = $m9hook46.IndexOf('Set-AppLockerPolicy -XmlPolicy')
$notesAt47 = $m9hook46.IndexOf('Write-RecoveryNotes')
Assert-True '47. the export writes over nothing and into the locked folder: the old file is removed first, the copy out to the campaign''s own folder is evidence, and only then is the policy replaced' ((($delAt47 -ge 0) -and ($delAt47 -lt $exportAt47) -and ($copyAt47 -gt $exportAt47) -and ($setAt47 -gt $copyAt47))) ('del ' + $delAt47 + ', export ' + $exportAt47 + ', copy ' + $copyAt47 + ', replace ' + $setAt47)
Assert-True '47. and the notes are rewritten before the step runs, so a session that dies under the enforced rules finds the staged way back named in them' (($notesAt47 -ge 0) -and ($notesAt47 -lt $m9hook46.IndexOf('Invoke-PolicyChange'))) ('notes at ' + $notesAt47 + ', the step at ' + $m9hook46.IndexOf('Invoke-PolicyChange'))
Assert-True '47. what the revert installs and what the check reads is the copy in the locked folder, not the one in the campaign''s own' (($m9apply46 -like '*$before = Join-Path $staged ''applocker-before.xml''*') -and ($m9apply46 -like '*AppLockerPolicyBeforeCopy*')) 'the saved policy is not staged'

# -------------------- 48. the policy M9 applies, and what recorded data may do inside a command line --------------------
# The self-audit the working method asks for, run over the whole change after round 3 - looking for the family the
# reviewer had been finding three times: something read as trustworthy that is not. Two more of it. The policy M9
# applies is read from the campaign's own folder, which the account the campaign runs as can write to, and it is
# applied elevated - the same thing the commands file was before round 1, and it was not hashed. And the lines a
# revert is built from carry recorded state straight into a command line: M8's two registry values as the machine had
# them, M9's service startup type. A value with a quote in it ends the argument it sits in, and what follows is more
# command - and the state is a file under C:\Users\Public, not only the registry.
Write-Output ''
Write-Output '48. the policy applied elevated is the one this campaign read, and no recorded value can end its own command'
$loaded48 = @('Test-PolicyLineData')
Assert-True '48. the driver defines Test-PolicyLineData once, so this case runs that definition and no other' ($defs42.ContainsKey('Test-PolicyLineData') -and $defs42['Test-PolicyLineData'].Count -eq 1) ('definitions: ' + $(if ($defs42.ContainsKey('Test-PolicyLineData')) { $defs42['Test-PolicyLineData'].Count } else { 0 }))
$needs48 = @(); $free48 = @()
if ($defs42.ContainsKey('Test-PolicyLineData') -and $defs42['Test-PolicyLineData'].Count -eq 1) {
    $needs48 = @($defs42['Test-PolicyLineData'][0].Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ -and $defs42.ContainsKey($_) -and $loaded48 -notcontains $_ } | Sort-Object -Unique)
    $free48 = @(Get-FreeVariables $defs42['Test-PolicyLineData'][0])
    Invoke-Expression $defs42['Test-PolicyLineData'][0].Extent.Text
}
Assert-True '48. it calls and reads nothing of the driver, so what runs here is what runs there' (($needs48.Count -eq 0) -and ($free48.Count -eq 0)) ('also needed: ' + ($needs48 -join ', ') + '; free variables: ' + ($free48 -join ', '))
Assert-True '48. the values a machine really has pass: AllSigned, 1, an empty value, nothing recorded at all' ((Test-PolicyLineData 'AllSigned') -and (Test-PolicyLineData '1') -and (Test-PolicyLineData '') -and (Test-PolicyLineData $null)) 'a plain value was refused'
Assert-True '48. a value carrying a quote does not travel, because it would end the argument it sits in and the rest would be command' (-not (Test-PolicyLineData ('x' + [char]34 + ' & calc & ' + [char]34 + 'y'))) 'a quoted break-out was accepted'
Assert-True '48. nor do the characters cmd reads as syntax, nor a control character' ((-not (Test-PolicyLineData 'a&b')) -and (-not (Test-PolicyLineData 'a|b')) -and (-not (Test-PolicyLineData 'a>b')) -and (-not (Test-PolicyLineData ('a' + [char]10 + 'b')))) 'a value with cmd syntax in it was accepted'
$m8revert48 = ''
$m8at48 = $m9text45.IndexOf("@{ Id = 'M8'")
if ($m8at48 -ge 0) {
    $m8end48 = $m9text45.IndexOf("@{ Id = '", $m8at48 + 10)
    $m8revert48 = $(if ($m8end48 -gt $m8at48) { $m9text45.Substring($m8at48, $m8end48 - $m8at48) } else { $m9text45.Substring($m8at48) })
}
Assert-True '48. and M8''s revert asks that question of the two values it carries before it asks the helper for anything' (($m8revert48 -like '*Test-PolicyLineData*') -and ($m8revert48 -like '*RegExecutionPolicyBefore*') -and ($m8revert48 -like '*RegEnableScriptsBefore*')) 'M8''s revert does not check the values it carries'
$weird48 = @(Get-M9RevertLines @{ Facts = @{ AppIDSvcStartType = ('Weird' + [char]38 + ' calc'); AppIDSvcStatus = 'Running' } })
Assert-True '48. a service startup type Windows does not have produces no command at all, rather than one built around it' ((@($weird48 | Where-Object { $_ -like '*sc config*' }).Count -eq 0) -and (@($weird48)[0] -like 'reg delete*') -and (@($weird48)[-1] -eq 'gpupdate /force')) ($weird48 -join ' / ')
$known48 = @(Get-M9RevertLines @{ Facts = @{ AppIDSvcStartType = 'Automatic'; AppIDSvcStatus = 'Running' } })
Assert-True '48. and the reading is not vacuous: a startup type it does have still produces its line' (@($known48 | Where-Object { $_ -like 'may fail: sc config AppIDSvc start= auto*' }).Count -eq 1) ($known48 -join ' / ')
$xmlCopyAt48 = $m9apply46.IndexOf('copy /y "'' + $xml + ''" "'' + $stagedXml + ''"')
$xmlHashAt48 = $m9apply46.IndexOf('certutil -hashfile "'' + $stagedXml + ''" SHA256')
$setStagedAt48 = $m9apply46.IndexOf('Set-AppLockerPolicy -XmlPolicy ''''' + "'" + ' + $stagedXml')
Assert-True '48. the policy is copied into the locked folder, checked there against the digest this campaign took, and applied from that copy' ((($xmlCopyAt48 -ge 0) -and ($xmlHashAt48 -gt $xmlCopyAt48) -and ($m9apply46 -like '*$xmlDigest*'))) ('copy ' + $xmlCopyAt48 + ', hash ' + $xmlHashAt48 + ', digest named: ' + ($m9apply46 -like '*$xmlDigest*'))
Assert-True '48. and what is applied is the staged copy, not the one in the campaign''s own folder' (($m9apply46 -like '*Set-AppLockerPolicy -XmlPolicy*$stagedXml*') -and ($m9apply46 -notlike '*Set-AppLockerPolicy -XmlPolicy*'' + $xml + ''*')) 'the policy applied is not the staged copy'

# -------------------- 49. what round 4 asked of the three scenarios --------------------
# PR #67 round 4: the program that checks a digest is not itself checked; a backup that travels through a writable
# path is a backup that can be swapped one step later; M7 deleted a value the machine may have had of its own; M9
# changed a service whose state it had failed to read; a rule is not its id; and a revert of M8 that half succeeded
# read as done, because only the policy the two values add up to was compared.
Write-Output ''
Write-Output '49. the helper checked before it is elevated, the values put back as they were, and a rule read as a rule'
$helperDigest49 = [string](Get-FileHash -LiteralPath $helper41 -Algorithm SHA256).Hash
$driverText49 = [IO.File]::ReadAllText($driver)
$constAt49 = $driverText49.IndexOf('$PolicyHelperDigest = ')
$const49 = ''
if ($constAt49 -ge 0) {
    $quote49 = $driverText49.IndexOf("'", $constAt49)
    $end49 = $driverText49.IndexOf("'", $quote49 + 1)
    $const49 = $driverText49.Substring($quote49 + 1, $end49 - $quote49 - 1)
}
Assert-True '49. the digest the driver carries for the helper is the digest of the helper it ships with, so the constant cannot go stale unnoticed' ($const49 -eq $helperDigest49) ('driver: ' + $const49 + '; file: ' + $helperDigest49)
$stepText49 = ''
$fnStep49 = @($ast42.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-PolicyStepFile' }, $true))
if ($fnStep49.Count -eq 1) { $stepText49 = [string]$fnStep49[0].Extent.Text }
Assert-True '49. and the step compares it before it elevates anything - hashing the commands says nothing about the program that reads them' (($stepText49 -like '*PolicyHelperDigest*') -and ($stepText49.IndexOf('PolicyHelperDigest') -lt $stepText49.IndexOf('Start-Process'))) 'the helper is not checked before it is started'
# M7 puts back the value the machine had, where it had one.
$m7block49 = ''
$m7at49 = $driverText49.IndexOf("@{ Id = 'M7'")
if ($m7at49 -ge 0) {
    $m7end49 = $driverText49.IndexOf("@{ Id = '", $m7at49 + 10)
    $m7block49 = $(if ($m7end49 -gt $m7at49) { $driverText49.Substring($m7at49, $m7end49 - $m7at49) } else { $driverText49.Substring($m7at49) })
}
Assert-True '49. M7 records what __PSLockdownPolicy was before it changed it, and records whether it was there apart from what it said' (($m7block49 -like '*Prepare = {*') -and ($m7block49 -like '*LockdownExisted*') -and ($m7block49 -like '*LockdownValue*') -and ($m7block49 -like '*Get-MachineEnvRaw ''__PSLockdownPolicy''*')) 'M7 records nothing about the value it overwrites'
Assert-True '49. its revert puts that value back where there was one and deletes only where there was none, and its check compares existence and data with what was recorded' (($m7block49 -like '*setx /M __PSLockdownPolicy*$was*') -and ($m7block49 -like '*reg delete*__PSLockdownPolicy /f*') -and ($m7block49 -like '*before M7 it was*') -and ($m7block49 -like '*LockdownExisted*')) 'M7 still deletes whatever it finds'
# M9 does not change a service it could not read.
$m9prep49 = $m9apply46.IndexOf('Prepare = {')
$m9throw49 = $m9apply46.IndexOf('cannot be read (')
Assert-True '49. M9 refuses the scenario where the service state could not be read, rather than changing what nothing could put back' (($m9prep49 -ge 0) -and ($m9throw49 -gt $m9prep49) -and ($m9apply46 -like '*throw (*Application Identity service cannot be read*')) 'M9 still records n/a and goes on'
# A rule is its definition.
$sameIds49a = '<AppLockerPolicy Version="1"><RuleCollection Type="Script" EnforcementMode="Enabled"><FilePathRule Id="AAA" Action="Allow" UserOrGroupSid="S-1-1-0" /></RuleCollection></AppLockerPolicy>'
$sameIds49b = '<AppLockerPolicy Version="1"><RuleCollection Type="Script" EnforcementMode="Enabled"><FilePathRule Id="AAA" Action="Deny" UserOrGroupSid="S-1-1-0" /></RuleCollection></AppLockerPolicy>'
Assert-True '49. the same rule id with another action is another rule, which a shape built from ids read as the same one' ((Get-AppLockerPolicyShape $sameIds49a) -ne (Get-AppLockerPolicyShape $sameIds49b)) ('allow: ' + (Get-AppLockerPolicyShape $sameIds49a) + ' / deny: ' + (Get-AppLockerPolicyShape $sameIds49b))
Assert-True '49. and the reading is not vacuous: the same rule written the same way twice is the same shape' ((Get-AppLockerPolicyShape $sameIds49a) -eq (Get-AppLockerPolicyShape ($sameIds49a -replace '><', ">`r`n<"))) ('one: ' + (Get-AppLockerPolicyShape $sameIds49a))
# M8 is put back value by value.
$m8verify49 = ''
$m8at49b = $driverText49.IndexOf("@{ Id = 'M8'")
if ($m8at49b -ge 0) {
    $m8end49b = $driverText49.IndexOf("@{ Id = '", $m8at49b + 10)
    $m8verify49 = $(if ($m8end49b -gt $m8at49b) { $driverText49.Substring($m8at49b, $m8end49b - $m8at49b) } else { $driverText49.Substring($m8at49b) })
}
Assert-True '49. M8''s check reads both values back - whether each is there, its kind and its data - before the policy they add up to' (($m8verify49 -like '*GetValueKind*') -and ($m8verify49 -like '*RegExecutionPolicyKindBefore*') -and ($m8verify49 -like '*RegEnableScriptsKindBefore*') -and ($m8verify49 -like '*the revert did not put the key back as it was*')) 'M8 still certifies on the derived policy alone'

# -------------------- 50. what round 6 asked of putting the machine back --------------------
# PR #67 round 6, five findings and every one of them about the way back. A recorded __PSLockdownPolicy value that
# cannot be carried in a command line was still answered with a delete, and the delete is how it would be lost. A path
# recorded before the export ran was read as a policy that had been exported, so a consent prompt refused - which
# changes nothing on the machine - failed the revert. The shape a policy is compared by collapsed whitespace over the
# whole document, inside attribute values as well, where it is not formatting but the path a rule matches. The manual
# path was compared on a mode and a count although the whole policy could have been saved before the two paths part.
# And M8's data was compared with -ne, which folds case. Beside them, one the self-audit found: Write-RecoveryNotes is
# called at the driver's top level and calls Test-PolicyLineData, which was defined three lines below that call - and
# -and short-circuits, so the call is made only where the state says M7 recorded a value, which is every resume after
# M7 prepared, the one moment those two files matter. Measured on this runtime: the script ends with
# CommandNotFoundException there. M7's half of RECOVER.txt and undo-M7.cmd is a function of the recorded facts now, so
# the three cases are run here and not read.
Write-Output ''
Write-Output '50. the three cases of M7''s way back, a policy compared as it is written, and no top-level call that outruns its own definitions'
$loaded50 = @('Test-PolicyLineData', 'Get-M7RecoveryLines', 'Get-M7UndoCommand', 'Get-M7UndoLines')
$defined50 = @($loaded50 | Where-Object { $defs42.ContainsKey($_) -and $defs42[$_].Count -eq 1 })
Assert-True '50. the driver defines each of M7''s way-back functions once, so this case runs those definitions and no others' ($defined50.Count -eq $loaded50.Count) ('defined once: ' + ($defined50 -join ', ') + ' of ' + ($loaded50 -join ', '))
$needs50 = @(); $free50 = @()
if ($defined50.Count -eq $loaded50.Count) {
    foreach ($fn50 in $loaded50) {
        $needs50 += @($defs42[$fn50][0].Body.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ -and $defs42.ContainsKey($_) -and $loaded50 -notcontains $_ })
        $free50 += @(Get-FreeVariables $defs42[$fn50][0])
        Invoke-Expression $defs42[$fn50][0].Extent.Text
    }
}
Assert-True '50. they call and read nothing else of the driver, so what runs here is what runs there' ((@($needs50).Count -eq 0) -and (@($free50).Count -eq 0)) ('also needed: ' + (@($needs50 | Sort-Object -Unique) -join ', ') + '; free variables: ' + (@($free50 | Sort-Object -Unique) -join ', '))
$none50 = @{ LockdownExisted = 'no'; LockdownValue = '' }
$safe50 = @{ LockdownExisted = 'yes'; LockdownValue = '4' }
$unsafe50 = @{ LockdownExisted = 'yes'; LockdownValue = ('x' + [char]34 + ' & calc & ' + [char]34 + 'y') }
Assert-True '50. the value used for the third case is one the driver''s own reading refuses, and the second one it accepts - so these are its three cases and not three of mine' ((-not (Test-PolicyLineData ([string]$unsafe50.LockdownValue))) -and (Test-PolicyLineData ([string]$safe50.LockdownValue))) 'the crafted values are not the two kinds they stand for'
$notesNone50 = (@(Get-M7RecoveryLines $none50) -join "`n")
$undoNone50 = (@(Get-M7UndoLines $none50) -join "`n")
Assert-True '50. a machine that had no value is told to remove it, in the notes and in the file it names' (($notesNone50 -match 'reg delete .*__PSLockdownPolicy /f') -and ($undoNone50 -match 'reg delete .*__PSLockdownPolicy /f') -and ($undoNone50 -like '@echo off*') -and ($notesNone50 -match 'removing it is putting it back')) ($notesNone50 -replace "`n", ' / ')
$notesSafe50 = (@(Get-M7RecoveryLines $safe50) -join "`n")
$undoSafe50 = (@(Get-M7UndoLines $safe50) -join "`n")
Assert-True '50. a value that can be carried is put back by the line that carries it, and neither file offers a delete' (($notesSafe50 -match 'setx /M __PSLockdownPolicy "4"') -and ($undoSafe50 -match 'setx /M __PSLockdownPolicy "4"') -and ($notesSafe50 -notmatch 'reg delete') -and ($undoSafe50 -notmatch 'reg delete')) (($notesSafe50 + ' // ' + $undoSafe50) -replace "`n", ' / ')
$notesUnsafe50 = (@(Get-M7RecoveryLines $unsafe50) -join "`n")
$undoUnsafe50 = (@(Get-M7UndoLines $unsafe50) -join "`n")
Assert-True '50. a value that cannot be carried is answered with neither a delete nor a command line built around it, and neither file repeats the value a person would paste - both name where the machine''s own is kept instead' (($notesUnsafe50 -notmatch 'reg delete') -and ($undoUnsafe50 -notmatch 'reg delete') -and ($notesUnsafe50 -notmatch 'setx /M __PSLockdownPolicy') -and ($undoUnsafe50 -notmatch 'setx /M __PSLockdownPolicy') -and (-not $notesUnsafe50.Contains([string]$unsafe50.LockdownValue)) -and (-not $undoUnsafe50.Contains([string]$unsafe50.LockdownValue)) -and ($notesUnsafe50 -match 'Scenarios\.M7\.Facts\.LockdownValue') -and ($undoUnsafe50 -match 'Scenarios\.M7\.Facts\.LockdownValue')) (($notesUnsafe50 + ' // ' + $undoUnsafe50) -replace "`n", ' / ')
$actsUnsafe50 = @(@(Get-M7UndoLines $unsafe50) | Where-Object { $_ -notmatch '^(@echo off$|rem |echo |pause$|exit /b 1$)' })
Assert-True '50. and that file changes nothing and ends saying so: every line of it is a comment, an echo, a pause or its own exit code' (($actsUnsafe50.Count -eq 0) -and ((@(Get-M7UndoLines $unsafe50))[-1] -eq 'exit /b 1')) ('lines that act: ' + ($actsUnsafe50 -join ' / '))
$actsSafe50 = @(@(Get-M7UndoLines $safe50) | Where-Object { $_ -notmatch '^(@echo off$|rem |echo |pause$|exit /b 1$)' })
Assert-True '50. the reading is not vacuous: the file written for a value that can be carried does carry the command that puts it back' ($actsSafe50 -contains 'setx /M __PSLockdownPolicy "4"') ('lines that act: ' + ($actsSafe50 -join ' / '))
$notesFn50 = ''
if ($defs42.ContainsKey('Write-RecoveryNotes') -and $defs42['Write-RecoveryNotes'].Count -eq 1) { $notesFn50 = [string]$defs42['Write-RecoveryNotes'][0].Extent.Text }
Assert-True '50. and both files are written from these functions, with no second copy of the lines left inline - what this case drives is what a person reads' (($notesFn50 -like '*Get-M7RecoveryLines $m7Facts*') -and ($notesFn50 -like '*Get-M7UndoLines $m7Facts*') -and ($notesFn50 -notlike '*__PSLockdownPolicy*')) ('Write-RecoveryNotes still spells M7''s lines itself: ' + ($notesFn50 -like '*__PSLockdownPolicy*'))
# The shape a policy is compared by: what a rule says, not how the document was written.
$spaced50a = '<AppLockerPolicy Version="1"><RuleCollection Type="Script" EnforcementMode="Enabled"><FilePathRule Id="AAA" Action="Allow"><Conditions><FilePathCondition Path="C:\Data  Set\*" /></Conditions></FilePathRule></RuleCollection></AppLockerPolicy>'
$spaced50b = $spaced50a.Replace('C:\Data  Set\*', 'C:\Data Set\*')
Assert-True '50. two path rules that differ only by a doubled space inside the path are two rules, because those two paths are two folders' ((Get-AppLockerPolicyShape $spaced50a) -ne (Get-AppLockerPolicyShape $spaced50b)) ('two spaces: ' + (Get-AppLockerPolicyShape $spaced50a) + ' / one: ' + (Get-AppLockerPolicyShape $spaced50b))
$reformatted50 = ($spaced50a -replace '><', ">`r`n    <").Replace('Id="AAA" Action="Allow"', 'Action="Allow"  Id="AAA"')
Assert-True '50. and the reading is not vacuous: the same policy written out with newlines, indentation and its attributes in another order is the same policy' ((Get-AppLockerPolicyShape $reformatted50) -eq (Get-AppLockerPolicyShape $spaced50a)) ('reformatted: ' + (Get-AppLockerPolicyShape $reformatted50) + ' / as written: ' + (Get-AppLockerPolicyShape $spaced50a))
$said50a = '<AppLockerPolicy Version="1"><RuleCollection Type="Script" EnforcementMode="Enabled"><FilePathRule Id="AAA"><Description>two  spaces</Description></FilePathRule></RuleCollection></AppLockerPolicy>'
$said50b = $said50a.Replace('two  spaces', 'two spaces')
Assert-True '50. what a rule says in its own text is part of it as well, read the same way - and the whitespace between elements still is not' ((((Get-AppLockerPolicyShape $said50a) -ne (Get-AppLockerPolicyShape $said50b))) -and ((Get-AppLockerPolicyShape $said50a) -eq (Get-AppLockerPolicyShape ($said50a -replace '><', ">`r`n  <")))) ('said: ' + (Get-AppLockerPolicyShape $said50a) + ' / ' + (Get-AppLockerPolicyShape $said50b))
# What M9 saves before it changes anything, and what a missing file means.
$m9block50 = ''
$m9at50 = $m9text45.IndexOf("@{ Id = 'M9'")
if ($m9at50 -ge 0) {
    $m9end50 = $m9text45.IndexOf("@{ Id = '", $m9at50 + 10)
    $m9block50 = $(if ($m9end50 -gt $m9at50) { $m9text45.Substring($m9at50, $m9end50 - $m9at50) } else { $m9text45.Substring($m9at50) })
}
$preparedAt50 = $m9block50.IndexOf('applocker-before-prepare.xml')
$recordAt50 = $m9block50.IndexOf('AppLockerPolicyPrepared')
$readAt50 = $m9block50.LastIndexOf('AppLockerPolicyPrepared')
Assert-True '50. M9 saves the machine''s whole policy in Prepare, where both paths still run, and the check reads that copy - a mode and a count would take M9''s own two rules for the machine''s own two on the manual path as well' (($preparedAt50 -ge 0) -and ($recordAt50 -gt $preparedAt50) -and ($readAt50 -gt $recordAt50) -and ($m9block50 -like '*Prepare = {*') -and ($preparedAt50 -gt $m9block50.IndexOf('Prepare = {'))) ('prepare copy at ' + $preparedAt50 + ', recorded at ' + $recordAt50 + ', read at ' + $readAt50)
$missingAt50 = $m9block50.IndexOf('if ($savedPath -and -not $savedXml) {')
$applyByAt50 = $m9block50.IndexOf('applyBy')
Assert-True '50. a recorded path with no file behind it is a refusal only where the step reported the helper made the change; where nothing was applied it is no saved policy, not a failed revert' (($missingAt50 -ge 0) -and ($applyByAt50 -gt $missingAt50) -and ($applyByAt50 -lt $readAt50) -and ($m9block50 -like '*nothing here can say the machine was put back*')) ('the missing-file branch at ' + $missingAt50 + ', what applied it read at ' + $applyByAt50)
Assert-True '50. and the row says which of the two copies the machine was compared against, as the weaker comparison has said what it compared since round 5' (($m9block50 -like '*compared against {2}*') -and ($m9block50 -like '*the policy the step exported before it applied its own*') -and ($m9block50 -like '*the copy taken before the scenario started*')) 'the check does not say what it compared the machine with'
Assert-True '50. and the weaker comparison is still there for a machine that saved nothing at all, saying so in the row it writes' ($m9block50 -like '*no policy was saved, so only the Script collection is compared*') 'the manual path no longer says what it compared'
$ownNo50 = @{ AppLockerPolicyBefore = 'C:\state\applocker-before.xml'; OwnPolicyBefore = 'no'; StagedRevert = ''; AppIDSvcStartType = 'n/a' }
$ownYes50 = @{ AppLockerPolicyBefore = 'C:\state\applocker-before.xml'; OwnPolicyBefore = 'yes'; StagedRevert = ''; AppIDSvcStartType = 'n/a' }
$ownOld50 = @{ AppLockerPolicyBefore = 'C:\state\applocker-before.xml'; StagedRevert = ''; AppIDSvcStartType = 'n/a' }
$notesNo50 = (@(Get-M9RecoveryLines $ownNo50) -join "`n")
$notesYes50 = (@(Get-M9RecoveryLines $ownYes50) -join "`n")
$notesOld50 = (@(Get-M9RecoveryLines $ownOld50) -join "`n")
Assert-True '50. a machine the campaign read as having no AppLocker policy of its own is told to delete M9''s rules, and is not told it had a policy to preserve - the saved path is recorded whether or not the machine had one' (($notesNo50 -match 'no AppLocker policy of its own') -and ($notesNo50 -match 'secpol\.msc') -and ($notesNo50 -notmatch 'Do NOT simply delete')) ($notesNo50 -replace "`n", ' / ')
Assert-True '50. and the reading is not vacuous: a machine that had one still gets the careful branch with the saved copy named, and so does a record made before this was recorded at all' (($notesYes50 -match 'had an AppLocker policy of its own') -and ($notesYes50 -match 'Do NOT simply delete') -and ($notesOld50 -match 'Do NOT simply delete') -and ($notesOld50 -match 'could not be read before M9')) (($notesYes50 + ' // ' + $notesOld50) -replace "`n", ' / ')
Assert-True '50. and M9 reads that fact where the policy in force is still the machine''s own, from the policy itself rather than from a path' (($m9block50 -like '*OwnPolicyBefore*') -and ($m9block50.IndexOf('OwnPolicyBefore') -gt $m9block50.IndexOf('Prepare = {')) -and ($m9block50 -like '*Get-AppLockerPolicyShape $localXml*')) 'M9 does not record whether the machine had a policy of its own'
# M8's data, as it is written.
$m8block50 = ''
$m8at50 = $m9text45.IndexOf("@{ Id = 'M8'")
if ($m8at50 -ge 0) {
    $m8end50 = $m9text45.IndexOf("@{ Id = '", $m8at50 + 10)
    $m8block50 = $(if ($m8end50 -gt $m8at50) { $m9text45.Substring($m8at50, $m8end50 - $m8at50) } else { $m9text45.Substring($m8at50) })
}
Assert-True '50. M8 compares the data it reads back with the data it recorded case for case' (($m8block50 -like '*-cne*') -and ($m8block50 -like '*before M8 it was*')) 'M8 still compares its data with an operator that folds case'
$m7block50 = ''
$m7at50 = $m9text45.IndexOf("@{ Id = 'M7'")
if ($m7at50 -ge 0) {
    $m7end50 = $m9text45.IndexOf("@{ Id = '", $m7at50 + 10)
    $m7block50 = $(if ($m7end50 -gt $m7at50) { $m9text45.Substring($m7at50, $m7end50 - $m7at50) } else { $m9text45.Substring($m7at50) })
}
Assert-True '50. M7 compares the value it reads back the same way, since the finding is about the operator and not about that one scenario' (($m7block50 -like '*-cne $was*') -and ($m7block50 -like '*before M7 it was*')) 'M7 still compares its value with an operator that folds case'
Assert-True '50. the reading is not vacuous: PowerShell''s own -ne reads those two as the same value, and the registry does not' ((-not ('AllSigned' -ne 'allsigned')) -and ('AllSigned' -cne 'allsigned')) 'this runtime does not behave as the finding says'
# Which programs the helper's two checks are made with. This is not a supposition: the run of this very file that
# found it was started from a shell carrying GNU tools, cmd took their find.exe for the marker search, and every
# commands file the campaign had written came back refused as 'not the campaign's'. The helper sets PATH to Windows'
# own directories before it checks anything, and the commands files carry the same line because RECOVER.txt has a
# person run M9's staged way back by hand, where the PATH is the person's.
$shadow50 = Join-Path $WorkDir 'case50-shadow'
New-Item -ItemType Directory -Force -Path $shadow50 | Out-Null
foreach ($prog50 in @('find', 'certutil')) { Set-Content -LiteralPath (Join-Path $shadow50 ($prog50 + '.cmd')) -Encoding Ascii -Value @('@echo off', 'exit /b 1') }
$ours50 = Join-Path $shadow50 'ours.cmd'
Set-Content -LiteralPath $ours50 -Encoding Ascii -Value @('@echo off', 'rem NHC-POLICY-STEP SELFTEST harmless', 'ver', 'echo step=1 rc=%ERRORLEVEL%', 'exit /b 0')
$digest50 = [string](Get-FileHash -LiteralPath $ours50 -Algorithm SHA256).Hash
$result50 = Join-Path $shadow50 'result.txt'
$pathWas50 = $env:PATH
$code50 = -1
$bareFind50 = -1
$shadowWorks50 = $false
try {
    $env:PATH = $shadow50 + ';' + $pathWas50
    $ErrorActionPreference = 'Continue'
    $null = & $env:ComSpec '/c' ('find /i "NHC-POLICY-STEP" "' + $ours50 + '"') 2>&1
    $bareFind50 = $LASTEXITCODE
    $shadowWorks50 = ($bareFind50 -eq 1)
    $null = & $helper41 $ours50 $result50 $digest50 2>&1
    $code50 = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
}
finally { $env:PATH = $pathWas50; $ErrorActionPreference = 'Stop' }
$text50 = $(if (Test-Path -LiteralPath $result50) { (@(Get-Content -LiteralPath $result50 | ForEach-Object { [string]$_ }) -join ' | ') } else { '(no result file)' })
Assert-True '50. the reading is not vacuous: with that directory in front of PATH, a bare find is the other one and answers 1' $shadowWorks50 ('a bare find answered ' + $bareFind50 + ' with ' + $shadow50 + ' in front, where Windows'' own would have found the marker and answered 0')
Assert-True '50. and the helper''s checks are made with Windows'' own programs whatever PATH the campaign was started with: the campaign''s own file is still recognised, and its digest still checked' (($code50 -ne 3) -and ($code50 -ne 4) -and ($text50 -notlike '*marker*') -and ($text50 -notlike '*not the one the campaign hashed*')) ('exit ' + $code50 + '; ' + $text50)
$helperText50 = [IO.File]::ReadAllText($helper41)
$setAt50 = $helperText50.IndexOf('set "PATH=%SystemRoot%\System32;')
$findAt50 = $helperText50.IndexOf('find /i "NHC-POLICY-STEP"')
Assert-True '50. the helper sets it before it reads anything, so the marker search and the digest are both made with them' (($setAt50 -ge 0) -and ($findAt50 -gt $setAt50)) ('PATH set at ' + $setAt50 + ', the marker search at ' + $findAt50)
$stepPath50 = New-PolicyStepFile 'SELFTEST' 'pathline' @('ver') $shadow50
$stepBody50 = @(Get-Content -LiteralPath $stepPath50 | ForEach-Object { [string]$_ })
Assert-True '50. and a commands file carries the same line after its marker, for the one a person runs by hand from RECOVER.txt' (($stepBody50.Count -gt 3) -and ($stepBody50[1] -like 'rem NHC-POLICY-STEP*') -and ($stepBody50[2] -like 'set "PATH=%SystemRoot%\System32;*')) ($stepBody50 -join ' / ')
# A call at the top level is made with the definitions the file has made by then.
function Get-CallsBeforeDefined($ScriptAst) {
    # Every call a script makes at its top level, against what it had defined by then. PowerShell defines a function
    # when the statement defining it runs - there is no hoisting - so a top-level call that reaches a function defined
    # below it is a call to nothing, and short-circuiting can keep that hidden until the day the state says otherwise.
    $defs = @{}
    $callsOf = @{}
    foreach ($f in $ScriptAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        if ((-not $defs.ContainsKey($f.Name)) -or ($f.Extent.EndOffset -lt $defs[$f.Name])) { $defs[$f.Name] = $f.Extent.EndOffset }
    }
    foreach ($f in $ScriptAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        if (-not $callsOf.ContainsKey($f.Name)) { $callsOf[$f.Name] = @() }
        $callsOf[$f.Name] += @($f.Body.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ -and $defs.ContainsKey($_) })
    }
    $out = @()
    foreach ($c in @($ScriptAst.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.PipelineAst] } | ForEach-Object { $_.PipelineElements } | Where-Object { $_ -is [System.Management.Automation.Language.CommandAst] })) {
        $name = $c.GetCommandName()
        if ((-not $name) -or (-not $defs.ContainsKey($name))) { continue }
        $reach = @($name)
        $i = 0
        while ($i -lt $reach.Count) {
            foreach ($k in @($callsOf[$reach[$i]])) { if ($k -and ($reach -notcontains $k)) { $reach += $k } }
            $i++
        }
        foreach ($r in $reach) { if ($defs[$r] -gt $c.Extent.StartOffset) { $out += ($name + ' at line ' + $c.Extent.StartLineNumber + ' reaches ' + $r + ', which is defined below it') } }
    }
    return @($out)
}
$late50 = @(Get-CallsBeforeDefined $ast42)
Assert-True '50. nothing the driver calls at its top level reaches a function defined below that call' ($late50.Count -eq 0) ($late50 -join '; ')
$tokens50 = $null; $errors50 = $null
$crafted50 = [System.Management.Automation.Language.Parser]::ParseInput("function Outer(`$had) { `$safe = (`$had -and (Inner 'x')); return `$safe }`r`nOuter `$false`r`nfunction Inner([string]`$d) { return `$true }", [ref]$tokens50, [ref]$errors50)
$lateCrafted50 = @(Get-CallsBeforeDefined $crafted50)
Assert-True '50. and the reading is not vacuous: on a script shaped like the one this found - a top-level call whose function reaches a later definition behind an -and - it says so' (($lateCrafted50.Count -eq 1) -and ($lateCrafted50[0] -like '*Inner*')) ('found: ' + ($lateCrafted50 -join '; '))

# -------------------- 51. what round 7 asked: the copy the manual path has, and the line a person is shown --------------------
# PR #67 round 7, three findings. Two of them are round 1 and round 3 again, in the place round 6 left them: with
# -ManualPolicy the apply never runs, so AppLockerPolicyBefore is never set, and both the recovery notes and the
# cleanup instruction read that path alone - a person driving M9 by hand on a machine with an AppLocker policy of its
# own was told to delete the Script rules, which takes that policy with them, while the copy Prepare had saved sat
# unused beside them. And M7's cleanup instruction still interpolated a recorded value into an elevated setx line
# although the revert refuses to build that line for exactly those values. The third - that the undo file's
# '& pause & exit /b 1' runs whatever the condition - is measured below and is not what this cmd does; the
# parenthesised form is written anyway, because it cannot be read the other way by any cmd.
Write-Output ''
Write-Output '51. the copy the manual path has, the value that may not be put on a line, and what cmd does with an ungrouped if'
$loaded51 = @('Get-M9OwnPolicy')
Assert-True '51. the driver defines Get-M9OwnPolicy once, so this case runs that definition and no other' ($defs42.ContainsKey('Get-M9OwnPolicy') -and $defs42['Get-M9OwnPolicy'].Count -eq 1) ('definitions: ' + $(if ($defs42.ContainsKey('Get-M9OwnPolicy')) { $defs42['Get-M9OwnPolicy'].Count } else { 0 }))
$needs51 = @(); $free51 = @()
if ($defs42.ContainsKey('Get-M9OwnPolicy') -and $defs42['Get-M9OwnPolicy'].Count -eq 1) {
    $needs51 = @($defs42['Get-M9OwnPolicy'][0].Body.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ -and $defs42.ContainsKey($_) -and $loaded51 -notcontains $_ } | Sort-Object -Unique)
    $free51 = @(Get-FreeVariables $defs42['Get-M9OwnPolicy'][0])
}
Assert-True '51. it calls and reads nothing of the driver, so what runs here is what runs there' (($needs51.Count -eq 0) -and ($free51.Count -eq 0)) ('also needed: ' + ($needs51 -join ', ') + '; free variables: ' + ($free51 -join ', '))
# The notes, on the three ways a campaign can stand when it dies.
$manual51 = @{ AppLockerPolicyPrepared = 'C:\state\M9\applocker-before-prepare.xml'; OwnPolicyBefore = 'yes'; AppIDSvcStartType = 'n/a' }
$auto51 = @{ AppLockerPolicyBefore = 'C:\Windows\Temp\nhc-policy\applocker-before.xml'; AppLockerPolicyPrepared = 'C:\state\M9\applocker-before-prepare.xml'; OwnPolicyBefore = 'yes'; AppIDSvcStartType = 'n/a' }
$nothing51 = @{ OwnPolicyBefore = 'yes'; AppIDSvcStartType = 'n/a' }
$notesManual51 = (@(Get-M9RecoveryLines $manual51) -join "`n")
$notesAuto51 = (@(Get-M9RecoveryLines $auto51) -join "`n")
$notesNothing51 = (@(Get-M9RecoveryLines $nothing51) -join "`n")
Assert-True '51. a manual run that saved no export is put back from the copy Prepare took, which it names - not sent to delete the Script rules it would lose its own policy with' (($notesManual51 -match 'Do NOT simply delete') -and ($notesManual51 -match 'applocker-before-prepare\.xml') -and ($notesManual51 -match 'the copy taken before the scenario started') -and ($notesManual51 -notmatch 'delete the Script rules; then')) ($notesManual51 -replace "`n", ' / ')
Assert-True '51. and the reading is not vacuous: where the step did export one, that is the copy named and the notes say so' (($notesAuto51 -match 'applocker-before\.xml') -and ($notesAuto51 -match 'the policy the step exported') -and ($notesAuto51 -notmatch 'applocker-before-prepare\.xml')) ($notesAuto51 -replace "`n", ' / ')
Assert-True '51. a machine that had a policy of its own and no copy of it saved is told that, and still not to delete what it cannot restore' (($notesNothing51 -match 'Do NOT simply delete') -and ($notesNothing51 -match 'No copy of it was saved') -and ($notesNothing51 -notmatch 'saved before M9 replaced it') -and ($notesNothing51 -notmatch 'Set-AppLockerPolicy -XmlPolicy')) ($notesNothing51 -replace "`n", ' / ')
$unknown51 = @{ OwnPolicyBefore = 'unknown'; AppIDSvcStartType = 'n/a' }
$notesUnknown51 = (@(Get-M9RecoveryLines $unknown51) -join "`n")
Assert-True '51. a machine whose own policy could not be read at all is not told to delete anything either - that instruction is the one that cannot be taken back' (($notesUnknown51 -match 'could not be read before M9') -and ($notesUnknown51 -match 'No copy of it was saved') -and ($notesUnknown51 -notmatch 'delete the Script rules; then')) ($notesUnknown51 -replace "`n", ' / ')
# And the cleanup instruction, which is what a person driving the scenario by hand is actually given.
$instrManual51 = @()
if ($null -ne $sb45) { $instrManual51 = @(& $sb45 @{ Facts = @{ ScriptEnforcementBefore = 'none'; ScriptRuleCountBefore = '0'; AppLockerPolicyPrepared = 'C:\state\M9\applocker-before-prepare.xml'; OwnPolicyBefore = 'yes' } }) }
Assert-True '51. the cleanup instruction reads the same two copies in the same order, so the manual path is told to put THAT back and where from' ((@($instrManual51).Count -eq 2) -and (@($instrManual51)[0] -like '*put THAT back*') -and (@($instrManual51)[0] -like '*applocker-before-prepare.xml*') -and (@($instrManual51)[0] -notlike '*delete the Script rules*')) ('lines: ' + (@($instrManual51) -join ' // '))
# M7's cleanup instruction, driven the same way as M9's.
$m7at51 = $m9text45.IndexOf("@{ Id = 'M7'")
$i51 = $(if ($m7at51 -ge 0) { $m9text45.IndexOf('Cleanup = @{ Instruction = { param($Ctx)', $m7at51) } else { -1 })
$j51 = $(if ($i51 -ge 0) { $m9text45.IndexOf('Verify = { param($Ctx)', $i51) } else { -1 })
Assert-True '51. M7''s cleanup instruction is a scriptblock of the recorded facts, and this case runs it' (($i51 -ge 0) -and ($j51 -gt $i51)) ('instruction at ' + $i51 + ', verify at ' + $j51)
$sb51 = $null
if (($i51 -ge 0) -and ($j51 -gt $i51)) {
    $block51 = $m9text45.Substring($i51, $j51 - $i51)
    $from51 = $block51.IndexOf('{ param($Ctx)')
    $to51 = $block51.LastIndexOf('}')
    Invoke-Expression ('$sb51 = ' + $block51.Substring($from51, $to51 - $from51 + 1))
}
$badValue51 = ('x' + [char]34 + ' & calc & ' + [char]34 + 'y')
$m7unsafe51 = @(); $m7safe51 = @(); $m7none51 = @()
if ($null -ne $sb51) {
    $m7unsafe51 = @(& $sb51 @{ Facts = @{ LockdownExisted = 'yes'; LockdownValue = $badValue51 } })
    $m7safe51 = @(& $sb51 @{ Facts = @{ LockdownExisted = 'yes'; LockdownValue = '4' } })
    $m7none51 = @(& $sb51 @{ Facts = @{ LockdownExisted = 'no'; LockdownValue = '' } })
}
$unsafeText51 = (@($m7unsafe51) -join ' // ')
Assert-True '51. a recorded value the revert refuses to put on a command line is not put on one here either - the line a person copies into an elevated prompt' ((@($m7unsafe51).Count -eq 2) -and ($unsafeText51 -notlike '*setx*') -and (-not $unsafeText51.Contains($badValue51)) -and ($unsafeText51 -like '*Scenarios.M7.Facts.LockdownValue*') -and ($unsafeText51 -like '*Environment Variables*')) ('lines: ' + $unsafeText51)
Assert-True '51. and the reading is not vacuous: a value that can be carried is still shown as the line that carries it, and a machine that had none is still told to remove it' ((@($m7safe51).Count -eq 2) -and ((@($m7safe51) -join ' // ') -like '*setx /M __PSLockdownPolicy "4"*') -and (@($m7none51).Count -eq 2) -and ((@($m7none51) -join ' // ') -like '*reg delete*__PSLockdownPolicy /f*')) ('safe: ' + (@($m7safe51) -join ' // ') + '; none: ' + (@($m7none51) -join ' // '))
# What cmd does with an if and an ampersand - measured, because a claim about it decided one of this round's findings.
$dir51 = Join-Path $WorkDir 'case51'
New-Item -ItemType Directory -Force -Path $dir51 | Out-Null
function Invoke-Shape51([string]$Name, [string]$First, [string]$Line) {
    # A file shaped like undo-M7.cmd - a command, then the line that answers its exit code, then the success message -
    # with echo in place of pause, so that the case measures the parse rather than waiting for a key.
    $f = Join-Path $dir51 ($Name + '.cmd')
    Set-Content -LiteralPath $f -Encoding Ascii -Value @('@echo off', $First, $Line, 'echo REACHED-THE-END', 'exit /b 0')
    $ErrorActionPreference = 'Continue'
    $out = @(& $env:ComSpec '/c' $f 2>&1 | ForEach-Object { [string]$_ })
    $code = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    return @{ ExitCode = $code; Text = ($out -join ' | ') }
}
$undo51 = @(Get-M7UndoLines @{ LockdownExisted = 'yes'; LockdownValue = '4' })
$fail51 = @($undo51 | Where-Object { $_ -like 'if errorlevel 1*' })
Assert-True '51. undo-M7.cmd keeps the commands that answer a failure inside the condition, where a reader can see they are' ((@($fail51).Count -eq 1) -and (@($fail51)[0] -like 'if errorlevel 1 (*)') -and (@($fail51)[0] -like '*pause*') -and (@($fail51)[0] -like '*exit /b 1*')) ('the line: ' + (@($fail51) -join ' / '))
$grouped51 = Invoke-Shape51 'grouped-ok' 'ver >nul' 'if errorlevel 1 ( echo FAILED & echo WOULD-PAUSE & exit /b 1 )'
$groupedBad51 = Invoke-Shape51 'grouped-failing' 'cmd /c exit 1' 'if errorlevel 1 ( echo FAILED & echo WOULD-PAUSE & exit /b 1 )'
Assert-True '51. and that form does what it says: the run whose command succeeded reaches the success message and exits 0, the one whose command failed says so and exits 1' (($grouped51.ExitCode -eq 0) -and ($grouped51.Text -like '*REACHED-THE-END*') -and ($grouped51.Text -notlike '*WOULD-PAUSE*') -and ($groupedBad51.ExitCode -eq 1) -and ($groupedBad51.Text -like '*FAILED*') -and ($groupedBad51.Text -like '*WOULD-PAUSE*')) ('ok: exit ' + $grouped51.ExitCode + ' ' + $grouped51.Text + '; failing: exit ' + $groupedBad51.ExitCode + ' ' + $groupedBad51.Text)
$ungrouped51 = Invoke-Shape51 'ungrouped-ok' 'ver >nul' 'if errorlevel 1 echo FAILED & echo WOULD-PAUSE & exit /b 1'
Assert-True '51. the reading that an ungrouped tail runs whatever the condition is not what this cmd does - the claim was rejected on this measurement, and the parentheses were written for the reader' (($ungrouped51.ExitCode -eq 0) -and ($ungrouped51.Text -like '*REACHED-THE-END*') -and ($ungrouped51.Text -notlike '*WOULD-PAUSE*')) ('cmd ' + (Get-Item (Join-Path $env:SystemRoot 'System32\cmd.exe')).VersionInfo.ProductVersion + ': exit ' + $ungrouped51.ExitCode + ' ' + $ungrouped51.Text)

# -------------------- 52. what round 8 asked: the line a person copies, and a start type with no name --------------------
# PR #67 round 8, two findings, both about a machine that cannot be put back from what the campaign wrote down. M8's
# way back interpolated the recorded data into reg add commands - and those commands are the only manual route the
# campaign advertises, printed in RECOVER.txt and in M8's own cleanup instruction. A REG_EXPAND_SZ value holding
# %SystemRoot% expands as it is typed, a quote ends the argument and what follows is more command: the automated
# revert has refused such a value since the audit after round 3, and the line a person reads refuses it now too. And
# .NET has one name, Automatic, for both automatic and automatic-delayed start (ServiceStartMode has no member for
# the second), so a machine whose Application Identity service was delayed was recorded as Automatic, put back with
# 'sc config start= auto', and certified by a check that compares the same one name - the setting gone and nothing
# saying so. DelayedAutostart beside Start in the service's own key is what decides it, and it is recorded, put back
# and checked on its own now.
Write-Output ''
Write-Output '52. the way back as a line a person copies, and the delayed start Get-Service does not distinguish'
$loaded52 = @('Get-M8WayBack', 'Get-ServiceDelayedAuto', 'Test-DelayedAutoAgainst', 'Test-PolicyLineData')
$defined52 = @($loaded52 | Where-Object { $defs42.ContainsKey($_) -and $defs42[$_].Count -eq 1 })
Assert-True '52. the driver defines each of the four once, so this case runs those definitions and no others' ($defined52.Count -eq $loaded52.Count) ('defined once: ' + ($defined52 -join ', ') + ' of ' + ($loaded52 -join ', '))
$needs52 = @(); $free52 = @()
if ($defined52.Count -eq $loaded52.Count) {
    foreach ($fn52 in $loaded52) {
        $needs52 += @($defs42[$fn52][0].Body.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ -and $defs42.ContainsKey($_) -and $loaded52 -notcontains $_ })
        $free52 += @(Get-FreeVariables $defs42[$fn52][0])
        Invoke-Expression $defs42[$fn52][0].Extent.Text
    }
    $needs52 = @($needs52 | Sort-Object -Unique)
    $free52 = @($free52 | Sort-Object -Unique)
}
Assert-True '52. they call and read nothing of the driver beyond each other, so what runs here is what runs there' (($needs52.Count -eq 0) -and ($free52.Count -eq 0)) ('also needed: ' + ($needs52 -join ', ') + '; free variables: ' + ($free52 -join ', '))
# M8's way back, on data that cannot be carried and on data that can.
$expand52 = @(Get-M8WayBack @{ RegExecutionPolicyBefore = '%SystemRoot%\policy'; RegExecutionPolicyKindBefore = 'ExpandString'; RegEnableScriptsBefore = '1'; RegEnableScriptsKindBefore = 'DWord' })
$quote52 = @(Get-M8WayBack @{ RegExecutionPolicyBefore = ('All' + [char]34 + ' & calc & ' + [char]34 + 'Signed'); RegExecutionPolicyKindBefore = 'String'; RegEnableScriptsBefore = '1'; RegEnableScriptsKindBefore = 'DWord' })
$plain52 = @(Get-M8WayBack @{ RegExecutionPolicyBefore = 'AllSigned'; RegExecutionPolicyKindBefore = 'String'; RegEnableScriptsBefore = '1'; RegEnableScriptsKindBefore = 'DWord' })
Assert-True '52. a recorded value holding a per-cent sign gets no reg add line - typing it would expand it, and the machine would come back with other data' ((@($expand52)[0] -notlike 'reg add*') -and (@($expand52)[0] -like '*cannot be put in a command line*') -and (@($expand52)[0] -like '*Scenarios.M8.Facts.RegExecutionPolicyBefore*') -and (-not (@($expand52)[0]).Contains('%SystemRoot%'))) ('lines: ' + ($expand52 -join ' / '))
Assert-True '52. nor does one holding a quote, which would end the argument it sits in and leave the rest as command' ((@($quote52)[0] -notlike 'reg add*') -and (@($quote52)[0] -like '*regedit*')) ('lines: ' + ($quote52 -join ' / '))
Assert-True '52. and the reading is not vacuous: ordinary data is still put back by the line that carries it, and the other value is unaffected either way' ((@($plain52)[0] -like 'reg add*ExecutionPolicy*AllSigned*') -and (@($plain52)[1] -like 'reg add*EnableScripts*') -and (@($expand52)[1] -like 'reg add*EnableScripts*')) ('plain: ' + ($plain52 -join ' / '))
$m8instr52 = ''
$m8at52 = $m9text45.IndexOf("@{ Id = 'M8'")
if ($m8at52 -ge 0) {
    $m8end52 = $m9text45.IndexOf("@{ Id = '", $m8at52 + 10)
    $m8instr52 = $(if ($m8end52 -gt $m8at52) { $m9text45.Substring($m8at52, $m8end52 - $m8at52) } else { $m9text45.Substring($m8at52) })
}
Assert-True '52. and both places a person reads those lines build them with that function, so neither can drift from it' (($m8instr52 -like '*Cleanup = @{ Instruction*') -and ($m8instr52 -like '*Get-M8WayBack $Ctx.Facts*') -and ($m9text45 -like '*$m8Back = @(Get-M8WayBack*')) 'the instruction or RECOVER.txt spells M8''s way back itself'
# The delayed start, read where Windows keeps it.
Assert-True '52. a service that is not there reads as unknown, so nothing is claimed about a machine that could not be read' ((Get-ServiceDelayedAuto 'NoSuchServiceNhcSelftest') -eq 'unknown') ('reads as: ' + (Get-ServiceDelayedAuto 'NoSuchServiceNhcSelftest'))
$live52 = Get-ServiceDelayedAuto 'AppIDSvc'
Assert-True '52. and the reading is not vacuous: the Application Identity service of this machine answers yes or no, from its own key' (@('yes', 'no') -contains $live52) ('AppIDSvc reads as: ' + $live52)
# The lines that put it back, and the check that reads it.
$delayed52 = @(Get-M9RevertLines @{ Facts = @{ AppIDSvcStartType = 'Automatic'; AppIDSvcStatus = 'Running'; AppIDSvcDelayedAuto = 'yes' } })
$plainAuto52 = @(Get-M9RevertLines @{ Facts = @{ AppIDSvcStartType = 'Automatic'; AppIDSvcStatus = 'Running'; AppIDSvcDelayedAuto = 'no' } })
$unknown52 = @(Get-M9RevertLines @{ Facts = @{ AppIDSvcStartType = 'Automatic'; AppIDSvcStatus = 'Running'; AppIDSvcDelayedAuto = 'unknown' } })
Assert-True '52. a service that started delayed is put back delayed - by the word sc config has for it, and by the value it reads where sc config is refused' ((@($delayed52 | Where-Object { $_ -eq 'may fail: sc config AppIDSvc start= delayed-auto' }).Count -eq 1) -and (@($delayed52 | Where-Object { $_ -like '*DelayedAutostart*/d 1 /f' }).Count -eq 1)) ($delayed52 -join ' / ')
Assert-True '52. one that started plain automatic is put back plain, and the flag is written as 0 rather than left as it is' ((@($plainAuto52 | Where-Object { $_ -eq 'may fail: sc config AppIDSvc start= auto' }).Count -eq 1) -and (@($plainAuto52 | Where-Object { $_ -like '*DelayedAutostart*/d 0 /f' }).Count -eq 1)) ($plainAuto52 -join ' / ')
Assert-True '52. and where the flag could not be read, nothing is written for it - a campaign that does not know does not set' ((@($unknown52 | Where-Object { $_ -eq 'may fail: sc config AppIDSvc start= auto' }).Count -eq 1) -and (@($unknown52 | Where-Object { $_ -like '*DelayedAutostart*' }).Count -eq 0)) ($unknown52 -join ' / ')
$notesDelayed52 = (@(Get-M9RecoveryLines @{ AppIDSvcStartType = 'Automatic'; AppIDSvcStatus = 'Running'; AppIDSvcDelayedAuto = 'yes' }) -join "`n")
Assert-True '52. RECOVER.txt says the same, in the words a person types: the delayed start named, and the value beside Start' (($notesDelayed52 -match 'delayed start') -and ($notesDelayed52 -match 'sc config AppIDSvc start= delayed-auto') -and ($notesDelayed52 -match 'DelayedAutostart')) ($notesDelayed52 -replace "`n", ' / ')
$wantOther52 = $(if ($live52 -eq 'yes') { 'no' } else { 'yes' })
$says52 = Test-DelayedAutoAgainst @{ AppIDSvcStartType = 'Automatic'; AppIDSvcDelayedAuto = $wantOther52 } $live52
$quiet52 = Test-DelayedAutoAgainst @{ AppIDSvcStartType = 'Automatic'; AppIDSvcDelayedAuto = $live52 } $live52
$notAuto52 = Test-DelayedAutoAgainst @{ AppIDSvcStartType = 'Manual'; AppIDSvcDelayedAuto = $wantOther52 } $live52
$unread52 = Test-DelayedAutoAgainst @{ AppIDSvcStartType = 'Automatic'; AppIDSvcDelayedAuto = 'unknown' } $live52
Assert-True '52. the check refuses a machine whose flag is not the one M9 found, and names the command that puts it back' (($null -ne $says52) -and ($says52.Ok -eq $false) -and ([string]$says52.Detail -like '*sc config AppIDSvc start= *')) ('says: ' + $(if ($null -eq $says52) { '(nothing)' } else { $says52.Detail }))
Assert-True '52. and it says nothing where there is nothing to say: the flag as this machine has it, a service that was not automatic, and a flag that was never read' (($null -eq $quiet52) -and ($null -eq $notAuto52) -and ($null -eq $unread52)) ('same: ' + $(if ($null -eq $quiet52) { 'quiet' } else { $quiet52.Detail }) + '; not automatic: ' + $(if ($null -eq $notAuto52) { 'quiet' } else { $notAuto52.Detail }) + '; unread: ' + $(if ($null -eq $unread52) { 'quiet' } else { $unread52.Detail }))
$m9block52 = ''
$m9at52 = $m9text45.IndexOf("@{ Id = 'M9'")
if ($m9at52 -ge 0) {
    $m9end52 = $m9text45.IndexOf("@{ Id = '", $m9at52 + 10)
    $m9block52 = $(if ($m9end52 -gt $m9at52) { $m9text45.Substring($m9at52, $m9end52 - $m9at52) } else { $m9text45.Substring($m9at52) })
}
Assert-True '52. M9 records the flag where it records the rest of the service, and both of its checks read it - the weaker comparison included, since that is the one a manual campaign gets' (($m9block52 -like '*$delayedNow = Get-ServiceDelayedAuto ''AppIDSvc''*') -and ($m9block52 -like '*AppIDSvcDelayedAuto = $delayedNow*') -and (@([regex]::Matches($m9block52, 'Test-DelayedAutoAgainst \$Ctx\.Facts \(Get-ServiceDelayedAuto')).Count -ge 2)) ('recorded: ' + ($m9block52 -like '*AppIDSvcDelayedAuto = $delayedNow*') + '; checked ' + @([regex]::Matches($m9block52, 'Test-DelayedAutoAgainst')).Count + ' time(s)')

# -------------------- 53. what round 9 asked: the value as the registry holds it, and the two answers a check owes --------------------
# PR #67 round 9, three findings. M7 read __PSLockdownPolicy through [Environment]::GetEnvironmentVariable(..., 'Machine'),
# which expands a REG_EXPAND_SZ value and says nothing about its kind - so a machine whose value was '%SystemRoot%\x'
# was recorded as the path it expands to, put back with setx as a REG_SZ holding that text, and certified by a check
# that read the same expansion: the indirection gone and the kind gone, with every row saying the machine was as
# before. The delayed-start check returned $null where the service key could not be read NOW, and its callers read
# $null as 'nothing to object to' - a revert that left the key unreadable was certified. And setx crops an assignment
# at 1 024 characters, so a longer value passed the command-line reading, came back truncated, failed M7's own check,
# and every advertised way back repeated the same crop.
Write-Output ''
Write-Output '53. the registry''s own data and kind, the command that cannot carry them, and a flag that cannot be read now'
$loaded53 = @('Get-MachineEnvRaw')
Assert-True '53. the driver defines Get-MachineEnvRaw once, so this case runs that definition and no other' ($defs42.ContainsKey('Get-MachineEnvRaw') -and $defs42['Get-MachineEnvRaw'].Count -eq 1) ('definitions: ' + $(if ($defs42.ContainsKey('Get-MachineEnvRaw')) { $defs42['Get-MachineEnvRaw'].Count } else { 0 }))
$needs53 = @(); $free53 = @()
if ($defs42.ContainsKey('Get-MachineEnvRaw') -and $defs42['Get-MachineEnvRaw'].Count -eq 1) {
    $needs53 = @($defs42['Get-MachineEnvRaw'][0].Body.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ -and $defs42.ContainsKey($_) -and $loaded53 -notcontains $_ } | Sort-Object -Unique)
    $free53 = @(Get-FreeVariables $defs42['Get-MachineEnvRaw'][0])
    Invoke-Expression $defs42['Get-MachineEnvRaw'][0].Extent.Text
}
Assert-True '53. it calls and reads nothing of the driver, so what runs here is what runs there' (($needs53.Count -eq 0) -and ($free53.Count -eq 0)) ('also needed: ' + ($needs53 -join ', ') + '; free variables: ' + ($free53 -join ', '))
# The defect itself, on this machine's own environment block: which names read differently raw and expanded.
$envKey53 = Get-Item -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' -ErrorAction SilentlyContinue
$names53 = @()
if ($null -ne $envKey53) { $names53 = @($envKey53.GetValueNames() | Where-Object { [string]$envKey53.GetValue($_, $null, 'DoNotExpandEnvironmentNames') -cne [string][Environment]::GetEnvironmentVariable($_, 'Machine') }) }
Assert-True '53. this machine has machine variables whose stored data is not what [Environment] returns - the reading M7 used to record with' ($names53.Count -ge 1) ('names: ' + ($names53 -join ', ') + ' of ' + $(if ($null -ne $envKey53) { @($envKey53.GetValueNames()).Count } else { 0 }))
if ($names53.Count -ge 1) {
    $one53 = @($names53)[0]
    $raw53 = Get-MachineEnvRaw $one53
    Assert-True '53. and the raw read gives the data the key holds and the kind beside it, where the expanded read gives neither' (([string]$raw53.Value -ceq [string]$envKey53.GetValue($one53, $null, 'DoNotExpandEnvironmentNames')) -and ([string]$raw53.Value -cne [string][Environment]::GetEnvironmentVariable($one53, 'Machine')) -and ([string]$raw53.Kind -eq 'ExpandString') -and ([bool]$raw53.Existed)) ($one53 + ': raw "' + $raw53.Value + '" (' + $raw53.Kind + ') / expanded "' + [string][Environment]::GetEnvironmentVariable($one53, 'Machine') + '"')
}
else {
    Assert-True '53. and the raw read gives the data the key holds and the kind beside it, where the expanded read gives neither' $false 'this machine has no expandable machine variable to read'
}
$absent53 = Get-MachineEnvRaw 'NhcSelftestNoSuchMachineVariable'
Assert-True '53. a name that is not there reads as not there, rather than as an empty value - the difference M7 records as two facts' ((-not [bool]$absent53.Existed) -and ([string]$absent53.Value -eq '') -and ([string]$absent53.Kind -eq '')) ('existed=' + $absent53.Existed + ' value="' + $absent53.Value + '" kind=' + $absent53.Kind)
# The one command, by kind and by length.
$plain53 = Get-M7UndoCommand @{ LockdownExisted = 'yes'; LockdownValue = '4'; LockdownKind = 'String' }
$expand53 = Get-M7UndoCommand @{ LockdownExisted = 'yes'; LockdownValue = 'SystemRootPolicy'; LockdownKind = 'ExpandString' }
$percent53 = Get-M7UndoCommand @{ LockdownExisted = 'yes'; LockdownValue = '%SystemRoot%\policy'; LockdownKind = 'ExpandString' }
$atLimit53 = Get-M7UndoCommand @{ LockdownExisted = 'yes'; LockdownValue = ('a' * 1024); LockdownKind = 'String' }
$overLimit53 = Get-M7UndoCommand @{ LockdownExisted = 'yes'; LockdownValue = ('a' * 1025); LockdownKind = 'String' }
$multi53 = Get-M7UndoCommand @{ LockdownExisted = 'yes'; LockdownValue = 'x'; LockdownKind = 'MultiString' }
$legacy53 = Get-M7UndoCommand @{ LockdownExisted = 'yes'; LockdownValue = '4' }
$none53 = Get-M7UndoCommand @{ LockdownExisted = 'no'; LockdownValue = '' }
Assert-True '53. an expandable value comes back as one - reg add writes the kind, and setx would have written a plain string holding the same characters' (($expand53 -like 'reg add *') -and ($expand53 -like '*/t REG_EXPAND_SZ*') -and ($expand53 -like '*SystemRootPolicy*') -and ($plain53 -eq 'setx /M __PSLockdownPolicy "4"')) ('expandable: ' + $expand53)
Assert-True '53. a value longer than setx will carry has no line at all, rather than one that crops it - 1 024 characters is the documented limit, and the campaign would have failed its own check on the truncation' (($atLimit53 -like 'setx /M *') -and ($overLimit53 -eq '')) ('at the limit: ' + $(if ($atLimit53) { 'a line' } else { 'none' }) + '; one over: ' + $(if ($overLimit53) { 'a line' } else { 'none' }))
Assert-True '53. nor has a kind these commands cannot write, nor data cmd would read as syntax - and a record from before the kind was recorded is still given the line it always had' (($multi53 -eq '') -and ($percent53 -eq '') -and ($legacy53 -eq 'setx /M __PSLockdownPolicy "4"') -and ($none53 -like 'reg delete *')) ('multi: [' + $multi53 + ']; per-cent: [' + $percent53 + ']; legacy: ' + $legacy53)
# What the four readers do with that answer.
$notesOver53 = (@(Get-M7RecoveryLines @{ LockdownExisted = 'yes'; LockdownValue = ('a' * 1025); LockdownKind = 'String' }) -join "`n")
$undoOver53 = (@(Get-M7UndoLines @{ LockdownExisted = 'yes'; LockdownValue = ('a' * 1025); LockdownKind = 'String' }) -join "`n")
$notesExpand53 = (@(Get-M7RecoveryLines @{ LockdownExisted = 'yes'; LockdownValue = 'SystemRootPolicy'; LockdownKind = 'ExpandString' }) -join "`n")
Assert-True '53. a value too long for the command is answered the way an unsafe one is: no line in either file, the kind named beside the value, and nothing deleted' (($notesOver53 -match 'no command line can put back') -and ($notesOver53 -notmatch 'setx') -and ($undoOver53 -notmatch 'setx') -and ($undoOver53 -notmatch 'reg add') -and ($notesOver53 -match 'LockdownKind')) ($notesOver53 -replace "`n", ' / ')
Assert-True '53. and the reading is not vacuous: an expandable value that CAN be carried is put in both files as the reg add line that writes its kind' (($notesExpand53 -match 'REG_EXPAND_SZ') -and ((@(Get-M7UndoLines @{ LockdownExisted = 'yes'; LockdownValue = 'SystemRootPolicy'; LockdownKind = 'ExpandString' }) -join "`n") -match 'REG_EXPAND_SZ')) ($notesExpand53 -replace "`n", ' / ')
$m7block53 = ''
$m7at53 = $m9text45.IndexOf("@{ Id = 'M7'")
if ($m7at53 -ge 0) {
    $m7end53 = $m9text45.IndexOf("@{ Id = '", $m7at53 + 10)
    $m7block53 = $(if ($m7end53 -gt $m7at53) { $m9text45.Substring($m7at53, $m7end53 - $m7at53) } else { $m9text45.Substring($m7at53) })
}
Assert-True '53. M7 records the kind where it records the value, its revert asks the same function for its line, and its check compares the kind as well as the data' (($m7block53 -like '*Get-MachineEnvRaw ''__PSLockdownPolicy''*') -and ($m7block53 -like '*LockdownKind*') -and ($m7block53 -like '*Get-M7UndoCommand $Ctx.Facts*') -and ($m7block53 -like '*before M7 it was of kind*')) 'M7 still records or compares the expanded value alone'
Assert-True '53. and both readings of it are the registry''s: the check reads the raw value too, not what [Environment] would expand it to' (($m7block53 -notlike '*Get-MachineEnv ''__PSLockdownPolicy''*') -or (@([regex]::Matches($m7block53, 'Get-MachineEnvRaw')).Count -ge 2)) ('raw reads: ' + @([regex]::Matches($m7block53, 'Get-MachineEnvRaw')).Count + '; expanded reads: ' + @([regex]::Matches($m7block53, 'Get-MachineEnv ')).Count)
# A flag that cannot be read now is not a flag that agrees.
$unreadable53 = Test-DelayedAutoAgainst @{ AppIDSvcStartType = 'Automatic'; AppIDSvcDelayedAuto = 'yes' } 'unknown'
$agrees53 = Test-DelayedAutoAgainst @{ AppIDSvcStartType = 'Automatic'; AppIDSvcDelayedAuto = 'yes' } 'yes'
$differs53 = Test-DelayedAutoAgainst @{ AppIDSvcStartType = 'Automatic'; AppIDSvcDelayedAuto = 'yes' } 'no'
$neverRead53 = Test-DelayedAutoAgainst @{ AppIDSvcStartType = 'Automatic'; AppIDSvcDelayedAuto = 'unknown' } 'unknown'
Assert-True '53. where M9 recorded the flag and the machine cannot be read now, the check refuses instead of staying quiet - its callers read quiet as nothing to object to' (($null -ne $unreadable53) -and ($unreadable53.Ok -eq $false) -and ([string]$unreadable53.Detail -like '*cannot be read now*')) ('says: ' + $(if ($null -eq $unreadable53) { '(nothing)' } else { $unreadable53.Detail }))
Assert-True '53. and it is quiet in the two standings that mean nothing to compare: a flag that agrees, and one that was never read when the rest was recorded' (($null -eq $agrees53) -and ($null -eq $neverRead53) -and ($null -ne $differs53)) ('agrees: ' + $(if ($null -eq $agrees53) { 'quiet' } else { 'says something' }) + '; never read: ' + $(if ($null -eq $neverRead53) { 'quiet' } else { 'says something' }) + '; differs: ' + $(if ($null -eq $differs53) { 'quiet' } else { 'says something' }))

# -------------------- 54. what round 10 asked: not readable is not absent --------------------
# PR #67 round 10, two findings of one shape - a state the campaign could not READ was treated as a state it knew,
# and the scenario changed the machine anyway. Get-MachineEnvRaw reported a key it could not open exactly as it
# reported a value that is not there, so M7 would have recorded 'none', overwritten a value it never saw, put 'none'
# back by deleting it, and certified that deletion through the same reading. And M9 recorded an automatic service
# whose delayed-start flag could not be read, then ran sc config start= auto - which takes a delayed setting off -
# with nothing to reconstruct it from and a check that had nothing to compare. Both refuse now, the way the service's
# startup type has since round 4: a scenario that cannot read what it is about to change is not attempted at all.
Write-Output ''
Write-Output '54. a key that cannot be read is not a key with nothing in it, and a scenario that cannot read does not change'
$readable54 = Get-MachineEnvRaw 'ComSpec'
$absent54 = Get-MachineEnvRaw 'NhcSelftestNoSuchMachineVariable'
$unreadable54 = Get-MachineEnvRaw 'ComSpec' 'HKLM:\SOFTWARE\NhcSelftestNoSuchKeyAtAll'
Assert-True '54. the read tells the three apart: a value that is there, a value that is not, and a key this session cannot open' (([bool]$readable54.Readable -and [bool]$readable54.Existed) -and ([bool]$absent54.Readable -and -not [bool]$absent54.Existed) -and (-not [bool]$unreadable54.Readable -and -not [bool]$unreadable54.Existed)) ('there: readable=' + $readable54.Readable + '/existed=' + $readable54.Existed + '; absent: readable=' + $absent54.Readable + '/existed=' + $absent54.Existed + '; unreadable: readable=' + $unreadable54.Readable + '/existed=' + $unreadable54.Existed)
# M7's check, driven against each of those readings - the driver's own block, with the reading it is given controlled.
$m7at54 = $m9text45.IndexOf("@{ Id = 'M7'")
$vAt54 = $(if ($m7at54 -ge 0) { $m9text45.IndexOf('Verify = { param($Ctx)', $m7at54) } else { -1 })
$vEnd54 = $(if ($vAt54 -ge 0) { $m9text45.IndexOf("@{ Id = 'M8'", $vAt54) } else { -1 })
$sb54 = $null
if (($vAt54 -ge 0) -and ($vEnd54 -gt $vAt54)) {
    $block54 = $m9text45.Substring($vAt54, $vEnd54 - $vAt54)
    $from54 = $block54.IndexOf('{ param($Ctx)')
    $to54 = $block54.LastIndexOf('} } },')
    if ($to54 -gt $from54) { Invoke-Expression ('$sb54 = ' + $block54.Substring($from54, $to54 - $from54 + 1)) }
}
Assert-True '54. M7''s check is a scriptblock this case can run, sliced where the next scenario begins' ($null -ne $sb54) ('verify at ' + $vAt54 + ', M8 at ' + $vEnd54)
$facts54 = @{ Facts = @{ LockdownExisted = 'yes'; LockdownValue = '4'; LockdownKind = 'String' } }
$cannotRead54 = $null; $asBefore54 = $null; $otherKind54 = $null; $gone54 = $null
if ($null -ne $sb54) {
    # Each reading is given to the driver's own check in a scope of its own, so the function it calls answers what this
    # case decided and the real one is untouched for every other case in this file.
    $cannotRead54 = & { function Get-MachineEnvRaw([string]$Name, [string]$KeyPath = '') { return @{ Readable = $false; Existed = $false; Value = ''; Kind = '' } } & $sb54 $facts54 }
    $asBefore54 = & { function Get-MachineEnvRaw([string]$Name, [string]$KeyPath = '') { return @{ Readable = $true; Existed = $true; Value = '4'; Kind = 'String' } } & $sb54 $facts54 }
    $otherKind54 = & { function Get-MachineEnvRaw([string]$Name, [string]$KeyPath = '') { return @{ Readable = $true; Existed = $true; Value = '4'; Kind = 'ExpandString' } } & $sb54 $facts54 }
    $gone54 = & { function Get-MachineEnvRaw([string]$Name, [string]$KeyPath = '') { return @{ Readable = $true; Existed = $false; Value = ''; Kind = '' } } & $sb54 $facts54 }
}
Assert-True '54. a key it cannot read now is refused, not read as a value that is gone - that reading is how a deletion nobody saw gets certified' (($null -ne $cannotRead54) -and ($cannotRead54.Ok -eq $false) -and ([string]$cannotRead54.Detail -like '*cannot be read now*')) ('says: ' + $(if ($null -eq $cannotRead54) { '(nothing)' } else { $cannotRead54.Detail }))
Assert-True '54. and the reading is not vacuous: the same block passes the machine that is as it was, and refuses one whose value is gone or whose kind is another' (($asBefore54.Ok -eq $true) -and ($gone54.Ok -eq $false) -and ($otherKind54.Ok -eq $false) -and ([string]$otherKind54.Detail -like '*of kind*')) ('as before: ' + $asBefore54.Ok + '; gone: ' + $gone54.Ok + '; other kind: ' + [string]$otherKind54.Detail)
# And the two scenarios refusing to start on what they cannot read.
$m7block54 = ''
if ($m7at54 -ge 0) {
    $m7end54 = $m9text45.IndexOf("@{ Id = '", $m7at54 + 10)
    $m7block54 = $(if ($m7end54 -gt $m7at54) { $m9text45.Substring($m7at54, $m7end54 - $m7at54) } else { $m9text45.Substring($m7at54) })
}
$prepAt54 = $m7block54.IndexOf('Prepare = {')
$throwAt54 = $m7block54.IndexOf('the machine environment key cannot be read (')
$recordAt54 = $m7block54.IndexOf('LockdownExisted = $(if')
Assert-True '54. M7 refuses the scenario where that key cannot be read, before it records anything or changes the machine' (($prepAt54 -ge 0) -and ($throwAt54 -gt $prepAt54) -and ($recordAt54 -gt $throwAt54) -and ($m7block54 -like '*throw (*machine environment key cannot be read*')) ('prepare at ' + $prepAt54 + ', refusal at ' + $throwAt54 + ', record at ' + $recordAt54)
Assert-True '54. and its precondition says the key could not be read rather than that the value is not set - the two are not the same sentence' (($m7block54 -like '*Precondition = { $raw = Get-MachineEnvRaw*') -and ($m7block54 -like '*cannot be read, so whether __PSLockdownPolicy is 4 cannot be said*')) 'M7''s precondition still reads an unreadable key as "not set"'
$m9prep54 = ''
$m9at54 = $m9text45.IndexOf("@{ Id = 'M9'")
if ($m9at54 -ge 0) {
    $m9end54 = $m9text45.IndexOf("@{ Id = '", $m9at54 + 10)
    $m9prep54 = $(if ($m9end54 -gt $m9at54) { $m9text45.Substring($m9at54, $m9end54 - $m9at54) } else { $m9text45.Substring($m9at54) })
}
$delayedThrow54 = $m9prep54.IndexOf('delayed-start flag cannot be read')
$applyAt54 = $m9prep54.IndexOf('Apply = {')
Assert-True '54. M9 refuses an automatic service whose delayed-start flag it could not read, rather than setting start= auto over a setting it cannot put back' (($delayedThrow54 -ge 0) -and ($applyAt54 -gt $delayedThrow54) -and ($m9prep54 -like '*StartType -eq ''Automatic'') -and ($delayedNow -eq ''unknown'')*')) ('refusal at ' + $delayedThrow54 + ', apply at ' + $applyAt54)

# -------------------- 55. the command line that starts the helper elevated --------------------
# The campaign of 2026-09-15 on the Windows 10 Pro VM - the first time the automated policy path ever ran on a machine
# - failed every elevated step before it started: `helper exit 1; the helper wrote no result file`, with the consent
# granted. Start-Process -Verb RunAs on a .cmd goes through HKCR\cmdfile\shell\runas\command, which is
# `cmd.exe /C "%1" %*`, and cmd removes the FIRST and the LAST quote character of a line that carries more than two of
# them (cmd /?): the helper's path came out ending in a stray quote, cmd could not find it, exited 1 and ran nothing.
# Ten review rounds did not catch it because case 41 calls the helper directly and the elevated path was only ever
# read as text. This case runs the line the driver builds, unelevated - the quoting is what is under test, not the
# consent - and keeps the broken shape beside it, because a line that works proves nothing until the one that failed
# is shown failing.
Write-Output ''
Write-Output '55. the line the driver hands cmd.exe, run for real - and the shape that ran nothing'
$loaded55 = @('Get-ElevatedHelperArguments')
Assert-True '55. the driver defines Get-ElevatedHelperArguments once, so this case runs that definition and no other' ($defs42.ContainsKey('Get-ElevatedHelperArguments') -and $defs42['Get-ElevatedHelperArguments'].Count -eq 1) ('definitions: ' + $(if ($defs42.ContainsKey('Get-ElevatedHelperArguments')) { $defs42['Get-ElevatedHelperArguments'].Count } else { 0 }))
$needs55 = @(); $free55 = @()
if ($defs42.ContainsKey('Get-ElevatedHelperArguments') -and $defs42['Get-ElevatedHelperArguments'].Count -eq 1) {
    $needs55 = @($defs42['Get-ElevatedHelperArguments'][0].Body.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ -and $defs42.ContainsKey($_) -and $loaded55 -notcontains $_ } | Sort-Object -Unique)
    $free55 = @(Get-FreeVariables $defs42['Get-ElevatedHelperArguments'][0])
    Invoke-Expression $defs42['Get-ElevatedHelperArguments'][0].Extent.Text
}
Assert-True '55. it calls and reads nothing of the driver, so what runs here is what runs there' (($needs55.Count -eq 0) -and ($free55.Count -eq 0)) ('also needed: ' + ($needs55 -join ', ') + '; free variables: ' + ($free55 -join ', '))
# A probe that answers with the three arguments it was given, in a folder whose name has a space in it - a path the
# campaign's own folders do not have today and a person's profile may.
$dir55 = Join-Path $WorkDir 'case55\a folder with spaces'
New-Item -ItemType Directory -Force -Path $dir55 | Out-Null
$probe55 = Join-Path $dir55 'probe helper.cmd'
Set-Content -LiteralPath $probe55 -Encoding Ascii -Value @('@echo off', '> "%~2" echo 1=%~1', '>> "%~2" echo 2=%~2', '>> "%~2" echo 3=%~3')
$cmds55 = Join-Path $dir55 'policy-apply.cmd'
Set-Content -LiteralPath $cmds55 -Encoding Ascii -Value @('@echo off', 'rem NHC-POLICY-STEP SELFTEST harmless')
$result55 = Join-Path $dir55 'policy-apply-result.txt'
$digest55 = [string](Get-FileHash -LiteralPath $cmds55 -Algorithm SHA256).Hash
$cmdExe55 = Join-Path (Join-Path $env:SystemRoot 'System32') 'cmd.exe'
function Invoke-Line55($ArgumentList) {
    # The same call the driver makes, minus -Verb RunAs: what is under test is how cmd reads the line, which elevation
    # does not change. Elevation is what the machine campaign measures, and no self-test can raise a consent prompt.
    if ([IO.File]::Exists($result55)) { [IO.File]::Delete($result55) }
    $ErrorActionPreference = 'Continue'
    $p = Start-Process -FilePath $cmdExe55 -ArgumentList $ArgumentList -Wait -PassThru -WindowStyle Hidden
    $ErrorActionPreference = 'Stop'
    $said = @()
    if ([IO.File]::Exists($result55)) { $said = @([IO.File]::ReadAllLines($result55)) }
    return @{ ExitCode = $p.ExitCode; Lines = $said }
}
$good55 = Invoke-Line55 (Get-ElevatedHelperArguments $probe55 $cmds55 $result55 $digest55)
Assert-True '55. the line the driver builds delivers the three arguments as they were written, spaces in the paths and all, and cmd exits 0' (($good55.ExitCode -eq 0) -and (@($good55.Lines).Count -eq 3) -and (@($good55.Lines)[0] -eq ('1=' + $cmds55)) -and (@($good55.Lines)[1] -eq ('2=' + $result55)) -and (@($good55.Lines)[2] -eq ('3=' + $digest55))) ('exit ' + $good55.ExitCode + '; ' + (@($good55.Lines) -join ' | '))
# And the shape the shell's own association produces for a .cmd, which is what the campaign was sending until the
# machine run of 2026-09-15: cmd.exe /C "<helper>" "<commands>" "<result>" <digest>, with no pair to strip.
$bare55 = @('/c', ('"' + $probe55 + '" "' + $cmds55 + '" "' + $result55 + '" ' + $digest55))
$bad55 = Invoke-Line55 $bare55
Assert-True '55. and the reading is not vacuous: the shape Start-Process -Verb RunAs builds for a .cmd runs nothing at all - cmd strips the first and the last quote, the path it is left with does not exist, and no result file is written' (($bad55.ExitCode -ne 0) -and (@($bad55.Lines).Count -eq 0)) ('exit ' + $bad55.ExitCode + '; ' + $(if (@($bad55.Lines).Count) { (@($bad55.Lines) -join ' | ') } else { 'no result file, which is the defect' }))
$stepText55 = ''
$fnStep55 = @($ast42.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-PolicyStepFile' }, $true))
if ($fnStep55.Count -eq 1) { $stepText55 = [string]$fnStep55[0].Extent.Text }
Assert-True '55. and the step starts cmd.exe by its own path under System32 with that line - not the .cmd through its association, and not %ComSpec%, which a session can point elsewhere' (($stepText55 -like '*Start-Process -FilePath $cmdExe*') -and ($stepText55 -like '*Get-ElevatedHelperArguments $Helper $CmdFile $resultFile $digest*') -and ($stepText55 -like "*Join-Path (Join-Path `$env:SystemRoot 'System32') 'cmd.exe'*") -and ($stepText55 -notlike '*ComSpec*') -and ($stepText55 -notlike '*Start-Process -FilePath $Helper*')) 'the step still starts the helper through the shell association'

# -------------------- 56. a line whose exit code is not what the step is asking --------------------
# The campaign of 2026-09-15 ended M9 in FAILED with the policy applied, the service running and gpupdate done,
# because `net start AppIDSvc` exits 2 where the service is already running. The same campaign's revert exited 0 on a
# `net stop` that printed "the service could not be stopped" and did not stop it, and 5 on an `sc config` the reg add
# beside it made good. A line the scenario marks is still run and still printed - it is taken out of the count and
# nothing else.
Write-Output ''
Write-Output '56. the marker that takes a line out of the count, run for real'
$dir56 = Join-Path $WorkDir 'case56'
New-Item -ItemType Directory -Force -Path $dir56 | Out-Null
$file56 = New-PolicyStepFile 'SELFTEST' 'mayfail' @('ver', 'may fail: cmd /c exit 5', 'ver') $dir56
$body56 = @(Get-Content -LiteralPath $file56 | ForEach-Object { [string]$_ })
Assert-True '56. the marker is stripped from the command the file runs - what cmd sees is the command, not the campaign''s note about it' ((@($body56 | Where-Object { $_ -like '*may fail:*' }).Count -eq 0) -and (@($body56 | Where-Object { $_ -eq 'cmd /c exit 5' }).Count -eq 1)) ($body56 -join ' / ')
Assert-True '56. and a marked line gets no counting line, where an unmarked one does - two of the three' ((@($body56 | Where-Object { $_ -eq 'if not "%ERRORLEVEL%"=="0" set NHCFAIL=1' }).Count -eq 2) -and (@($body56 | Where-Object { $_ -like 'echo step=2 rc=*(not counted)*' }).Count -eq 1)) ($body56 -join ' / ')
$ErrorActionPreference = 'Continue'
$out56 = @(& $env:ComSpec '/c' $file56 2>&1 | ForEach-Object { [string]$_ })
$code56 = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
Assert-True '56. the step exits 0 although the marked command exited 5, and the record still carries that 5 - the command ran, it was not skipped' (($code56 -eq 0) -and (@($out56 | Where-Object { $_ -like 'step=2 rc=5*' }).Count -eq 1) -and (@($out56 | Where-Object { $_ -like 'step=2 rc=5 (not counted)*' }).Count -eq 1)) ('exit ' + $code56 + '; ' + ($out56 -join ' | '))
$file56b = New-PolicyStepFile 'SELFTEST' 'counted' @('ver', 'cmd /c exit 5', 'ver') $dir56
$ErrorActionPreference = 'Continue'
$null = & $env:ComSpec '/c' $file56b 2>&1
$code56b = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
Assert-True '56. and the reading is not vacuous: the same command without the marker still fails the step' ($code56b -ne 0) ('exit ' + $code56b)
$file56c = New-PolicyStepFile 'SELFTEST' 'mixed' @('may fail: cmd /c exit 5', 'cmd /c exit 1') $dir56
$ErrorActionPreference = 'Continue'
$null = & $env:ComSpec '/c' $file56c 2>&1
$code56c = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
Assert-True '56. a marked line does not cover for an unmarked one beside it - the step still fails on the line that must succeed' ($code56c -ne 0) ('exit ' + $code56c)

$file56d = New-PolicyStepFile 'SELFTEST' 'negative' @('cmd /c exit -1', 'ver') $dir56
$body56d = @(Get-Content -LiteralPath $file56d | ForEach-Object { [string]$_ })
$ErrorActionPreference = 'Continue'
$out56d = @(& $env:ComSpec '/c' $file56d 2>&1 | ForEach-Object { [string]$_ })
$code56d = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
# IF ERRORLEVEL n is true where the code is n or more, so every negative one passed over it. gpupdate returns -1 when
# it gives up on the computer policy - which is M9's last line - and the step that had not done its work reported
# result=OK (the campaign of 2026-09-15). The comparison is text now, and this case is what says so: the step file is
# what runs here, and it runs a command that exits -1.
Assert-True '56. a command that exits -1 is counted - IF ERRORLEVEL means that number or more, and gpupdate returns -1 where it gives up' (($code56d -ne 0) -and (@($out56d | Where-Object { $_ -like 'step=1 rc=-1*' }).Count -eq 1) -and (@($body56d | Where-Object { $_ -like 'if errorlevel*' }).Count -eq 0)) ('exit ' + $code56d + '; ' + ($out56d -join ' | '))
$file56e = New-PolicyStepFile 'SELFTEST' 'negativeold' @('cmd /c exit -1') $dir56
$body56e = @(Get-Content -LiteralPath $file56e | ForEach-Object { [string]$_ } | ForEach-Object { if ($_ -like 'if not "%ERRORLEVEL%"*') { 'if errorlevel 1 set NHCFAIL=1' } else { $_ } })
$old56 = Join-Path $dir56 'the-idiom-that-missed-it.cmd'
[IO.File]::WriteAllLines($old56, [string[]]$body56e, [Text.Encoding]::ASCII)
$ErrorActionPreference = 'Continue'
$null = & $env:ComSpec '/c' $old56 2>&1
$code56e = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
Assert-True '56. and the reading is not vacuous: the same file with the idiom this replaced lets that -1 through, which is the defect' ($code56e -eq 0) ('exit ' + $code56e + ' with if errorlevel 1, against ' + $code56d + ' with the comparison')
# -------------------- 57. the marker M9's way back writes is the marker the file honours --------------------
# Two literals, one in the builder and one in each line that carries it: this case is what says they are the same
# string. The lines the scenario generates are built into a file and the file is read back.
Write-Output ''
Write-Output '57. the lines M9 puts back, through the builder that reads the marker'
$manual57 = @(Get-M9RevertLines @{ Facts = @{ AppIDSvcStartType = 'Manual'; AppIDSvcStatus = 'Stopped' } })
$marked57 = @($manual57 | Where-Object { $_ -like 'may fail: *' })
Assert-True '57. the two service commands are the marked ones, and the registry write that makes the first of them good is not' ((@($marked57).Count -eq 2) -and (@($marked57 | Where-Object { $_ -like '*sc config AppIDSvc*' }).Count -eq 1) -and (@($marked57 | Where-Object { $_ -like '*net stop AppIDSvc*' }).Count -eq 1) -and (@($manual57 | Where-Object { $_ -like 'reg add*Start*/d 3 /f' }).Count -eq 1)) ($manual57 -join ' / ')
$dir57 = Join-Path $WorkDir 'case57'
New-Item -ItemType Directory -Force -Path $dir57 | Out-Null
$file57 = New-PolicyStepFile 'M9' 'revert' $manual57 $dir57
$body57 = @(Get-Content -LiteralPath $file57 | ForEach-Object { [string]$_ })
$counted57 = @($body57 | Where-Object { $_ -eq 'if not "%ERRORLEVEL%"=="0" set NHCFAIL=1' }).Count
Assert-True '57. the file runs every one of them, with the marker gone and two of them out of the count' ((@($body57 | Where-Object { $_ -like '*may fail:*' }).Count -eq 0) -and (@($body57 | Where-Object { $_ -eq 'sc config AppIDSvc start= demand' }).Count -eq 1) -and (@($body57 | Where-Object { $_ -eq 'net stop AppIDSvc' }).Count -eq 1) -and ($counted57 -eq (@($manual57).Count - 2))) ('counted ' + $counted57 + ' of ' + @($manual57).Count + '; ' + ($body57 -join ' / '))
Assert-True '57. and the reading is not vacuous: RECOVER.txt still gives a person the plain commands, with no marker of the campaign''s in them' ((@(Get-M9RecoveryLines @{ AppIDSvcStartType = 'Manual'; AppIDSvcStatus = 'Stopped' }) | Where-Object { $_ -like '*may fail*' }).Count -eq 0) ((Get-M9RecoveryLines @{ AppIDSvcStartType = 'Manual'; AppIDSvcStatus = 'Stopped' }) -join ' / ')

# -------------------- 58. what an apply step comes to: the machine, not the helper's account of itself --------------------
# The driver used to ask the precondition only where the helper said the step worked, although the comment above it
# said the precondition is what decides either way. On 2026-09-15 that sent the operator to do by hand what the helper
# had just finished.
Write-Output ''
Write-Output '58. the verdict an apply step comes to'
Assert-True '58. the driver defines Get-ApplyOutcome once, so this case runs that definition and no other' ($defs42.ContainsKey('Get-ApplyOutcome') -and $defs42['Get-ApplyOutcome'].Count -eq 1) ('definitions: ' + $(if ($defs42.ContainsKey('Get-ApplyOutcome')) { $defs42['Get-ApplyOutcome'].Count } else { 0 }))
$needs58 = @(); $free58 = @()
if ($defs42.ContainsKey('Get-ApplyOutcome') -and $defs42['Get-ApplyOutcome'].Count -eq 1) {
    $needs58 = @($defs42['Get-ApplyOutcome'][0].Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ -and $defs42.ContainsKey($_) } | Sort-Object -Unique)
    $free58 = @(Get-FreeVariables $defs42['Get-ApplyOutcome'][0])
    Invoke-Expression $defs42['Get-ApplyOutcome'][0].Extent.Text
}
Assert-True '58. it calls and reads nothing of the driver, so what runs here is what runs there' (($needs58.Count -eq 0) -and ($free58.Count -eq 0)) ('also needed: ' + ($needs58 -join ', ') + '; free variables: ' + ($free58 -join ', '))
$bothYes58 = Get-ApplyOutcome 'M9' @{ Ok = $true; Detail = 'helper exit 0' } @{ Ok = $true; Detail = 'Script rules enforced' }
Assert-True '58. helper says yes and the machine agrees: applied, and nothing is written over what the helper was recorded as' (($bothYes58.Applied -eq $true) -and ([string]$bothYes58.ApplyBy -eq '') -and ([string]$bothYes58.Event -like 'M9: applied by the elevated helper; precondition met - Script rules enforced*')) ('applied=' + $bothYes58.Applied + '; applyBy=' + [string]$bothYes58.ApplyBy + '; ' + [string]$bothYes58.Event)
$wrongHelper58 = Get-ApplyOutcome 'M9' @{ Ok = $false; Detail = 'helper exit 1 | step=15 rc=2 | result=FAILED' } @{ Ok = $true; Detail = 'Script rules enforced (2 rules), AppIDSvc running' }
Assert-True '58. the helper reported a failure the machine does not bear out: applied all the same, and the helper''s own account is kept beside it' (($wrongHelper58.Applied -eq $true) -and ([string]$wrongHelper58.ApplyBy -like '*step=15 rc=2*') -and ([string]$wrongHelper58.Event -like '*reported a failure the machine does not bear out*')) ('applied=' + $wrongHelper58.Applied + '; applyBy=' + [string]$wrongHelper58.ApplyBy)
Assert-True '58. and it is still the helper that made it, in the words the revert gate reads - a scenario applied this way is put back the same way, not left to a person' ([string]$wrongHelper58.ApplyBy).StartsWith('the elevated helper') ('applyBy=' + [string]$wrongHelper58.ApplyBy)
$machineNo58 = Get-ApplyOutcome 'M9' @{ Ok = $true; Detail = 'helper exit 0' } @{ Ok = $false; Detail = 'Script rules: NotConfigured' }
Assert-True '58. the helper says yes and the machine does not: not applied, and the message says which of the two was read' (($machineNo58.Applied -eq $false) -and ([string]$machineNo58.ApplyBy -eq '') -and (@($machineNo58.Message)[0] -like '*machine does not show it: Script rules: NotConfigured*')) ('applied=' + $machineNo58.Applied + '; ' + (@($machineNo58.Message) -join ' | '))
$bothNo58 = Get-ApplyOutcome 'M9' @{ Ok = $false; Detail = 'helper exit 1' } @{ Ok = $false; Detail = 'Script rules: NotConfigured' }
Assert-True '58. and where neither says so, the person is told both - what the helper said, and what the machine says now' (($bothNo58.Applied -eq $false) -and (@($bothNo58.Message)[0] -like '*helper exit 1*') -and (@($bothNo58.Message)[0] -like '*the machine says: Script rules: NotConfigured*') -and (@($bothNo58.Message).Count -eq 2)) ((@($bothNo58.Message) -join ' | '))
$stepText58 = ''
if ($defs42.ContainsKey('Invoke-Scenario') -and $defs42['Invoke-Scenario'].Count -eq 1) { $stepText58 = [string]$defs42['Invoke-Scenario'][0].Extent.Text }
if (-not $stepText58) { $stepText58 = [IO.File]::ReadAllText($driver) }
Assert-True '58. and the driver asks the machine before it decides, inside a try - a reader that throws on a half-changed machine used to take the campaign with it' (($stepText58 -like '*$outcome = Get-ApplyOutcome $id $ap $pc*') -and ($stepText58 -like '*the machine could not be read after the step*') -and ($stepText58 -notlike '*if ($ap.Ok) {*Save-State*$pc = $(if ($null -eq $S.Precondition)*')) 'the driver still reads the machine only where the helper said it worked'

# -------------------- 59. what M9's row may say about a run that wrote nothing --------------------
# AppLocker's script rules cover .cmd as well as .ps1, so a policy that does not allow the package's folder refuses
# Start-NetworkCheck.cmd itself: the package stops before its first line, nothing of ours is written, and all the
# person has is the line cmd printed. That is backlog #37, whose own text said the state had never been produced on
# any machine this project had looked at - and the campaign of 2026-09-15 produced it. The row said 'the launcher
# reported the failure', which is the one thing that had not happened.
Write-Output ''
Write-Output '59. a run that wrote nothing of its own, told apart from one that stopped and reported'
Assert-True '59. the driver defines Get-M9LauncherVerdict once, so this case runs that definition and no other' ($defs42.ContainsKey('Get-M9LauncherVerdict') -and $defs42['Get-M9LauncherVerdict'].Count -eq 1) ('definitions: ' + $(if ($defs42.ContainsKey('Get-M9LauncherVerdict')) { $defs42['Get-M9LauncherVerdict'].Count } else { 0 }))
$needs59 = @(); $free59 = @()
if ($defs42.ContainsKey('Get-M9LauncherVerdict') -and $defs42['Get-M9LauncherVerdict'].Count -eq 1) {
    $needs59 = @($defs42['Get-M9LauncherVerdict'][0].Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ -and $defs42.ContainsKey($_) } | Sort-Object -Unique)
    $free59 = @(Get-FreeVariables $defs42['Get-M9LauncherVerdict'][0])
    Invoke-Expression $defs42['Get-M9LauncherVerdict'][0].Extent.Text
}
Assert-True '59. it calls and reads nothing of the driver, so what runs here is what runs there' (($needs59.Count -eq 0) -and ($free59.Count -eq 0)) ('also needed: ' + ($needs59 -join ', ') + '; free variables: ' + ($free59 -join ', '))
# The run the machine of 2026-09-15 produced: exit 1, no launcher error report, no environment report, no report.
$refused59 = Get-M9LauncherVerdict @{ EnvironmentReports = @(); LauncherError = ''; Reports = @(); ExitCode = 1 }
Assert-True '59. a run that left no report of its own is the launcher itself refused, and the row says the person has only what Windows printed' (($refused59.Passed -eq $true) -and ([string]$refused59.What -like '*wrote nothing of its own*') -and ([string]$refused59.What -like '*#37*') -and ([string]$refused59.What -notlike '*the launcher*reported the failure*')) ('says: ' + [string]$refused59.What)
# The same exit code with the launcher's own report beside it, which is a different thing and always was.
$reported59 = Get-M9LauncherVerdict @{ EnvironmentReports = @(); LauncherError = 'NetworkHealthCheck could not run. Exit code 1.'; Reports = @(); ExitCode = 1 }
Assert-True '59. and the reading is not vacuous: the same exit code with a launcher error report beside it says the launcher stopped and wrote one' (($reported59.Passed -eq $true) -and ([string]$reported59.What -like '*the launcher stopped and wrote its own report*') -and ([string]$reported59.What -notlike '*wrote nothing of its own*')) ('says: ' + [string]$reported59.What)
$constrained59 = Get-M9LauncherVerdict @{ EnvironmentReports = @('env.txt'); LauncherError = 'ended with exit code 3'; Reports = @(); ExitCode = 3 }
Assert-True '59. a run that reached ConstrainedLanguage and fired the guard is still that, and it is a pass only where no report came out of it' (($constrained59.Passed -eq $true) -and ([string]$constrained59.What -like '*ConstrainedLanguage*')) ('says: ' + [string]$constrained59.What)
$ran59 = Get-M9LauncherVerdict @{ EnvironmentReports = @(); LauncherError = ''; Reports = @('report.html'); ExitCode = 0 }
Assert-True '59. a run that produced a report under enforced rules is not a pass, whatever else is missing - the machine is what to investigate' (($ran59.Passed -eq $false) -and ([string]$ran59.What -like '*ran unrestricted*') -and ([string]$ran59.What -like '*KB 5024351*')) ('says: ' + [string]$ran59.What)
$quiet59 = Get-M9LauncherVerdict @{ EnvironmentReports = @(); LauncherError = ''; Reports = @(); ExitCode = 0 }
Assert-True '59. and a run that did nothing at all and said so with a zero is unexplained, not a pass' (($quiet59.Passed -eq $false) -and ([string]$quiet59.What -like '*unexplained*')) ('says: ' + [string]$quiet59.What)

# -------------------- 38. two invocations of one campaign cannot choose one bundle path --------------------
Write-Output ''
Write-Output '38. the bundle name carries the time to the millisecond and the process id (backlog #25). A name good to the second collided whenever a second invocation of the same campaign fell inside the same second as the first: Compress-Archive refuses a destination that exists, and the record kept that refusal as a bundle failure - twice on GitHub Actions, both times on a commit that touched nothing the step reads. The collision is reproduced here rather than waited for: every second-precision name the clock can produce in the next five minutes is occupied before the invocation runs'
$r38a = Invoke-Campaign 'bundlename' @('-Zip', $zip, '-Scenarios', 'A3', '-SkipGui') "A3=done`r`n"
$s38a = Read-State $r38a.State
$prefix38 = 'nhc-campaign_' + $s38a.Computer + '_selftest-bundlename_'
$bundle38a = @(Get-ChildItem -LiteralPath $r38a.State -Filter 'nhc-campaign_*.zip')
Assert-True '38. the bundle carries the millisecond and the process id, under the name this campaign builds' ($bundle38a.Count -eq 1 -and $bundle38a[0].Name.StartsWith($prefix38) -and $bundle38a[0].Name -match '_\d{8}_\d{6}_\d{3}_p\d+\.zip$') ('bundles: ' + (($bundle38a | ForEach-Object { $_.Name }) -join ', ') + '; prefix ' + $prefix38)
# An empty file is enough to reproduce it: what failed was Compress-Archive refusing a destination that exists, which
# it decides on the path alone (measured on this machine, 2026-09-14).
$windowSeconds38 = 300
$start38 = Get-Date
$occupied38 = @{}
for ($i = 0; $i -le $windowSeconds38; $i++) {
    $stamp38 = $start38.AddSeconds($i).ToString('yyyyMMdd_HHmmss')
    $occupied38[$stamp38] = $true
    [IO.File]::WriteAllText((Join-Path $r38a.State ($prefix38 + $stamp38 + '.zip')), '')
}
$r38b = Invoke-Campaign 'bundlename' @('-Resume', '-Scenarios', 'A4', '-SkipGui') "A4=done`r`n"
$bundle38b = @(Get-ChildItem -LiteralPath $r38a.State -Filter 'nhc-campaign_*.zip')
$named38 = ''
if ($bundle38b.Count -eq 1 -and $bundle38b[0].Name -match '_(\d{8}_\d{6})_\d{3}_p\d+\.zip$') { $named38 = $Matches[1] }
Assert-True '38. the second invocation named its bundle for a second whose second-precision name was already taken - so the old name would have collided, and this case is not measuring an idle clock' (($named38 -ne '') -and $occupied38.ContainsKey($named38)) ('bundle: ' + (($bundle38b | ForEach-Object { $_.Name }) -join ', ') + '; window ' + $start38.ToString('yyyyMMdd_HHmmss') + ' + ' + $windowSeconds38 + ' s')
$summary38 = Get-Content -LiteralPath (Join-Path $r38a.State 'campaign_summary.md') -Raw -Encoding UTF8
Assert-True '38. nothing was recorded as a bundle failure, and the summary names the bundle that was written' (($summary38 -notmatch '\| bundle \| the campaign bundle \| FAIL \|') -and ($summary38 -notmatch '- Bundle: NOT WRITTEN') -and ($bundle38b.Count -eq 1) -and ($summary38 -match ('- Bundle: ' + [regex]::Escape($bundle38b[0].Name)))) (($summary38 -split "`n" | Where-Object { $_ -like '- Bundle:*' }) -join ' / ')
Assert-True '38. the occupied names went the way earlier bundles of a campaign go, leaving this invocation''s alone' ($bundle38b.Count -eq 1) ('bundles left: ' + $bundle38b.Count + ' of ' + ($windowSeconds38 + 2) + ' files that matched the campaign''s pattern')
Assert-True '38. exit code 0' ($r38b.ExitCode -eq 0) ('exit code ' + $r38b.ExitCode)

# -------------------- 39. the mark M2 needs: both ways to it, and which way this run took --------------------
Write-Output ''
Write-Output '39. M2 measures the warning a Mark of the Web produces, and an asset taken from a CI artifact carries none - the campaign that met this wrote the mark by hand and said so in the record by hand (backlog #30). The prerequisite names both ways to a marked download now, and every invocation''s summary says which way the file on disk got its mark, as far as its own stream accounts for it'
$r39a = Invoke-Campaign 'markways' @('-Zip', $zip, '-Scenarios', 'M2') "M2=done`r`n"
$s39a = Read-State $r39a.State
$detail39 = [string]$s39a.Scenarios.M2.Detail
Assert-True '39. the skip names both ways: the browser of this machine, and the command that writes the mark - applied to this campaign''s own download' (($detail39 -like '*download it with the browser of this machine*') -and ($detail39 -like '*Set-Content -LiteralPath*-Stream Zone.Identifier*ZoneId=3*') -and $detail39.Contains($zip)) $detail39
$summary39a = Get-Content -LiteralPath (Join-Path $r39a.State 'campaign_summary.md') -Raw -Encoding UTF8
Assert-True '39. and the summary of a run whose download has no mark says that, beside the file it read' (($summary39a -match '- Download mark: no Internet-zone mark \(no mark\)') -and ($summary39a -split "`n" | Where-Object { $_ -like '- Download mark:*' } | ForEach-Object { $_.Contains($zip) })) (($summary39a -split "`n" | Where-Object { $_ -like '- Download mark:*' }) -join ' / ')
$zipApplied39 = Join-Path $WorkDir ('NetworkHealthCheck-' + $version + '-applied.zip')
Copy-Item -LiteralPath $zip -Destination $zipApplied39 -Force
Set-Content -LiteralPath $zipApplied39 -Stream Zone.Identifier -Value "[ZoneTransfer]`r`nZoneId=3"
$r39b = Invoke-Campaign 'markapplied' @('-Zip', $zipApplied39, '-Scenarios', 'M2', '-SkipGui') "M2=done`r`n"
$summary39b = Get-Content -LiteralPath (Join-Path $r39b.State 'campaign_summary.md') -Raw -Encoding UTF8
Assert-True '39. a mark whose stream records no origin is reported as applied - and the line says what else leaves that stream, rather than calling the file hand-marked' (($summary39b -match '- Download mark: ZoneId=3, no origin recorded in the stream') -and ($summary39b -match 'a mark written by hand leaves') -and ($summary39b -match 'a browser that records no origin leaves too')) (($summary39b -split "`n" | Where-Object { $_ -like '- Download mark:*' }) -join ' / ')
$zipDownloaded39 = Join-Path $WorkDir ('NetworkHealthCheck-' + $version + '-downloaded.zip')
Copy-Item -LiteralPath $zip -Destination $zipDownloaded39 -Force
Set-Content -LiteralPath $zipDownloaded39 -Stream Zone.Identifier -Value "[ZoneTransfer]`r`nZoneId=3`r`nReferrerUrl=https://example.invalid/releases`r`nHostUrl=https://example.invalid/NetworkHealthCheck.zip"
$r39c = Invoke-Campaign 'markdownloaded' @('-Zip', $zipDownloaded39, '-Scenarios', 'M2', '-SkipGui') "M2=done`r`n"
$summary39c = Get-Content -LiteralPath (Join-Path $r39c.State 'campaign_summary.md') -Raw -Encoding UTF8
Assert-True '39. a mark whose stream records where the file came from is reported as downloaded, and the origin is quoted' (($summary39c -match '- Download mark: ZoneId=3, the stream records where it came from') -and ($summary39c -match 'HostUrl=https://example\.invalid/NetworkHealthCheck\.zip') -and ($summary39c -match 'ReferrerUrl=https://example\.invalid/releases')) (($summary39c -split "`n" | Where-Object { $_ -like '- Download mark:*' }) -join ' / ')
Assert-True '39. none of the three invocations failed for the mark it was given' (($r39a.ExitCode -eq 0) -and ($r39b.ExitCode -eq 0) -and ($r39c.ExitCode -eq 0)) ('exit codes: ' + $r39a.ExitCode + ' / ' + $r39b.ExitCode + ' / ' + $r39c.ExitCode)
# Round 3 of PR #65: M3 asks for this very download to be Unblocked, and the summary is written after that - so a
# summary that only re-reads the file reports "no mark" for every campaign that got as far as M3, losing the one thing
# this item asked it to record. The reading that saw the mark is kept in the state instead. The Unblock is made here by
# removing the stream, which is what the tick in Explorer's Properties dialog does.
Remove-Item -LiteralPath $zipApplied39 -Stream Zone.Identifier
$r39d = Invoke-Campaign 'markapplied' @('-Resume', '-Scenarios', 'A3', '-SkipGui') "A3=done`r`n"
$summary39d = Get-Content -LiteralPath (Join-Path $r39d.State 'campaign_summary.md') -Raw -Encoding UTF8
Assert-True '39. the mark this campaign ran against survives that Unblock: the summary still names it, says who read it, and says what the file carries now' (($summary39d -match '- Download mark: ZoneId=3, no origin recorded in the stream') -and ($summary39d -match 'read by the summary at ') -and ($summary39d -match 'the file carries no Internet-zone mark \(no mark\) now')) ((($summary39d -split "`n") | Where-Object { $_ -like '- Download mark:*' }) -join ' / ')
$s39d = Read-State $r39d.State
Assert-True '39. and the state keeps the reading that saw a mark, not the one that found none' (([string]$s39d.DownloadMark.Zone -eq 'ZoneId=3') -and ([string]$s39d.DownloadMark.Way -eq 'no-origin') -and ([string]$s39d.DownloadMark.By -eq 'the summary')) ('DownloadMark: ' + ($s39d.DownloadMark | ConvertTo-Json -Compress))
# And the other half of that rule: a scenario's reading is the moment the warning was measured, so it replaces one the
# summary made first. M2 is not selected in the first invocation, so it has a run of its own to make in the second.
$zipTakeover39 = Join-Path $WorkDir ('NetworkHealthCheck-' + $version + '-takeover.zip')
Copy-Item -LiteralPath $zip -Destination $zipTakeover39 -Force
Set-Content -LiteralPath $zipTakeover39 -Stream Zone.Identifier -Value "[ZoneTransfer]`r`nZoneId=3"
$desk39 = Join-Path $WorkDir 'desk39'
New-Item -ItemType Directory -Force -Path (Join-Path $desk39 'NHC-M2') | Out-Null
Copy-Item -LiteralPath $top -Destination (Join-Path $desk39 'NHC-M2') -Recurse -Force
Set-ExtractedLater (Join-Path $desk39 'NHC-M2')
# Without -SkipGui, because the flag is kept in the state and every resume of this campaign would then drop M2 before
# it could read anything - which is what the first attempt at this case measured instead of what it meant to.
$r39e = Invoke-Campaign 'marktakeover' @('-Zip', $zipTakeover39, '-Scenarios', 'A3', '-WorkRoot', $desk39) "A3=done`r`n"
$s39e = Read-State $r39e.State
Assert-True '39. a campaign whose summary saw the mark first records it as the summary''s reading' ([string]$s39e.DownloadMark.By -eq 'the summary') ('DownloadMark: ' + ($s39e.DownloadMark | ConvertTo-Json -Compress))
$r39f = Invoke-Campaign 'marktakeover' @('-Resume', '-Scenarios', 'M2') "M2=done`r`nM2/windows-showed=3`r`nM2/run-finished=done`r`n"
$s39f = Read-State $r39e.State
Assert-True '39. and M2, which measures the warning that mark produces, takes the record over when it runs' (([string]$s39f.DownloadMark.By -eq 'M2') -and ([string]$s39f.DownloadMark.Zone -eq 'ZoneId=3')) ('DownloadMark: ' + ($s39f.DownloadMark | ConvertTo-Json -Compress) + '; M2: ' + $s39f.Scenarios.M2.Result)
# The reading, not the whole summary: M3's own title in the scenario table is "Unblock, extract, ..." and would
# answer a search over the file for that word.
$markLine39d = ((($summary39d -split "`n") | Where-Object { $_ -like '- Download mark:*' }) -join ' / ')
Assert-True '39. and the Unblock is not named on that line, because M3 never ran in that campaign' ($markLine39d -notmatch 'Unblock') $markLine39d
# Where M3 IS on record and the file now has no stream, the step that asks for the Unblock is named - and what is said
# is what M3 asks for and what an Unblock does, not what happened here (PR #65, round 4). M3's result is crafted: the
# scenario itself needs an extraction and two launcher runs, and none of that is what this assertion is about.
$stateFile39 = Join-Path $r39d.State 'campaign.json'
$crafted39 = Get-Content -LiteralPath $stateFile39 -Raw -Encoding UTF8 | ConvertFrom-Json
$crafted39.Scenarios.M3.Result = 'PASS'; $crafted39.Scenarios.M3.Detail = 'crafted by the self-test'
[IO.File]::WriteAllText($stateFile39, ($crafted39 | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding($false)))
$r39h = Invoke-Campaign 'markapplied' @('-Resume', '-Scenarios', 'A4', '-SkipGui') "A4=done`r`n"
$summary39h = Get-Content -LiteralPath (Join-Path $r39h.State 'campaign_summary.md') -Raw -Encoding UTF8
Assert-True '39. with M3 on record and the stream gone, the line names the step that asks for that Unblock' (($summary39h -match 'the file carries no Internet-zone mark \(no mark\) now - M3 asked for the Unblock that removes the stream')) ((($summary39h -split "`n") | Where-Object { $_ -like '- Download mark:*' }) -join ' / ')
# And a download that is gone rather than unmarked reads as missing, which no Unblock accounts for.
Remove-Item -LiteralPath $zipApplied39 -Force
$r39i = Invoke-Campaign 'markapplied' @('-Resume', '-Scenarios', 'A3', '-SkipGui') "A3=done`r`n"
$summary39i = Get-Content -LiteralPath (Join-Path $r39i.State 'campaign_summary.md') -Raw -Encoding UTF8
$markLine39i = ((($summary39i -split "`n") | Where-Object { $_ -like '- Download mark:*' }) -join ' / ')
Assert-True '39. a download that is gone is reported as missing, with no Unblock named on that line although M3 is on record' (($markLine39i -match 'there is no file at that path now') -and ($markLine39i -notmatch 'Unblock')) $markLine39i
# The standard-user session does not go looking for the download at all (PR #65, round 5): it runs from C:\Users\Public
# because that account cannot reach the administrator's profile, where the download usually sits, and a read from there
# answers 'file missing' whether the file is gone or merely out of reach - the two raise the same exception, measured.
# This self-test runs in one session, so the guard is read off the driver's AST: it has to be the function's FIRST
# statement, before anything reads the file, or the reading it is meant to prevent has already happened.
$guard39 = $false; $guardWhy39 = 'Update-DownloadMark not found'
if ($defs37.ContainsKey('Update-DownloadMark') -and $defs37['Update-DownloadMark'].Count -eq 1) {
    $body39 = @($defs37['Update-DownloadMark'][0].Body.EndBlock.Statements)
    $reads39 = @($defs37['Update-DownloadMark'][0].Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Get-MarkOrigin' }, $true))
    $first39 = $(if ($body39.Count) { $body39[0] } else { $null })
    $isGuard39 = ($null -ne $first39) -and ($first39 -is [System.Management.Automation.Language.IfStatementAst]) -and ($first39.Extent.Text -match '\$IsStandardUser') -and ($first39.Extent.Text -match 'return')
    $guard39 = $isGuard39 -and ($reads39.Count -ge 1) -and ($reads39[0].Extent.StartOffset -gt $first39.Extent.EndOffset)
    $guardWhy39 = 'first statement is ' + $(if ($null -ne $first39) { $first39.GetType().Name } else { 'nothing' }) + ', guards the standard user: ' + $isGuard39 + ', reads of the file after it: ' + $reads39.Count
}
Assert-True '39. and the standard-user session says it did not look, before anything reads the download' $guard39 $guardWhy39
# A mark that CHANGED was not Unblocked either, so the line says both readings and names no reason for the difference:
# an explanation is not something a reading can supply.
Set-Content -LiteralPath $zipTakeover39 -Stream Zone.Identifier -Value "[ZoneTransfer]`r`nZoneId=3`r`nHostUrl=https://example.invalid/again.zip"
$r39g = Invoke-Campaign 'marktakeover' @('-Resume', '-Scenarios', 'A4') "A4=done`r`n"
$summary39g = Get-Content -LiteralPath (Join-Path $r39g.State 'campaign_summary.md') -Raw -Encoding UTF8
Assert-True '39. a mark that changed rather than went is reported as both readings, with no Unblock named for it' (($summary39g -match '- Download mark: ZoneId=3, no origin recorded in the stream') -and ($summary39g -match 'the file carries ZoneId=3, the stream records where it came from[^;]*now') -and ($summary39g -notmatch 'now, which is what M3')) ((($summary39g -split "`n") | Where-Object { $_ -like '- Download mark:*' }) -join ' / ')
# And a redo of M2 replaces M2's own earlier reading: the stream was rewritten above, so the run on record now was
# measured against the new mark, and a summary still naming the superseded one would contradict the row beside it
# (PR #65, round 6). The extraction this scenario needs is stamped ahead of the clock, so the redo passes it too.
$atBefore39 = [string]$s39f.DownloadMark.At
$r39j = Invoke-Campaign 'marktakeover' @('-Resume', '-Redo', 'M2', '-Scenarios', 'M2') "M2=done`r`nM2/windows-showed=3`r`nM2/run-finished=done`r`n"
$s39j = Read-State $r39e.State
Assert-True '39. and a redo of M2 takes the record over from M2''s own earlier reading, which the rewritten stream superseded' (([string]$s39j.DownloadMark.Way -eq 'origin-recorded') -and ([string]$s39j.DownloadMark.By -eq 'M2') -and ([string]$s39j.DownloadMark.At -ne $atBefore39)) ('was ' + $atBefore39 + '; now ' + ($s39j.DownloadMark | ConvertTo-Json -Compress))
# The line the prerequisite offers has to survive being pasted. A path with a dollar sign or an apostrophe in it is
# the case: inside double quotes PowerShell would expand or escape part of it, and the stream would go somewhere else
# or nowhere, leaving M2 skipped for a fix that looked right (PR #65, round 6).
$oddZip39 = Join-Path $WorkDir ('NetworkHealthCheck-' + $version + "-`$odd's copy.zip")
Copy-Item -LiteralPath $zip -Destination $oddZip39 -Force
$r39k = Invoke-Campaign 'markoddpath' @('-Zip', $oddZip39, '-Scenarios', 'M2') "M2=done`r`n"
$s39k = Read-State $r39k.State
$detail39k = [string]$s39k.Scenarios.M2.Detail
$wantQuoted39 = "-LiteralPath '" + ($oddZip39 -replace "'", "''") + "'"
Assert-True '39. the command it offers quotes the path as a literal, apostrophes doubled, so a path with a dollar sign in it survives being pasted' ($detail39k.Contains($wantQuoted39) -and ($detail39k -notmatch '-LiteralPath "')) ('wanted ' + $wantQuoted39 + ' in: ' + $detail39k)
# Round 9 of PR #65: a download that is not there cannot be answered by writing a mark on it. Measured on this machine:
# Set-Content -Stream against a path with no file there succeeds and leaves a 0-byte file carrying a valid ZoneId=3, so
# the prerequisite would pass on the next invocation and M2 would ask someone to extract something that is not an
# archive. The campaign above is redone with its download deleted, which is the state a resume can find.
Remove-Item -LiteralPath $oddZip39 -Force
$r39l = Invoke-Campaign 'markoddpath' @('-Resume', '-Redo', 'M2', '-Scenarios', 'M2') "M2=done`r`n"
$s39l = Read-State $r39l.State
$detail39l = [string]$s39l.Scenarios.M2.Detail
Assert-True '39. and where the download is not there at all, it asks for the release back instead of offering to write a mark on nothing' (($detail39l -like '*there is no file at*') -and ($detail39l -notlike '*Set-Content*') -and ($detail39l -like '*download it again with the browser of this machine*')) $detail39l

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


# -------------------- 35. the driver's own lines cannot go back to the success stream --------------------
# Backlog #53: every call to Invoke-Campaign is assigned, so anything it writes to the success stream lands in the
# caller's variable instead of the log, while member-access enumeration keeps $rN.ExitCode answering so that nothing
# looks wrong. This case asserts the rule on the AST of this file, not on its text: a comment mentioning Write-Output
# can neither satisfy nor trip it.
Write-Output ''
Write-Output '35. Invoke-Campaign writes the driver output to the host, and every call to it is assigned - which is why it must'
$tokens35 = $null
$errors35 = $null
$ast35 = [System.Management.Automation.Language.Parser]::ParseFile($PSCommandPath, [ref]$tokens35, [ref]$errors35)
$fn35 = @($ast35.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-Campaign' }, $true))
Assert-True '35. Invoke-Campaign is defined exactly once' ($fn35.Count -eq 1) ('definitions: ' + $fn35.Count)
$successWrites35 = @()
if ($fn35.Count -eq 1) {
    $successWrites35 = @($fn35[0].Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and @('Write-Output', 'Write-Information') -contains $n.GetCommandName() }, $true))
}
Assert-True '35. it writes nothing to the success stream' ($successWrites35.Count -eq 0) (($successWrites35 | ForEach-Object { $_.Extent.Text }) -join ' / ')
$calls35 = @($ast35.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Invoke-Campaign' }, $true))
$unassigned35 = @($calls35 | Where-Object {
    $p = $_.Parent
    while ($null -ne $p -and -not ($p -is [System.Management.Automation.Language.AssignmentStatementAst])) { $p = $p.Parent }
    $null -eq $p
})
Assert-True '35. every call to it is assigned, which is the reason for the rule above' (($calls35.Count -gt 0) -and ($unassigned35.Count -eq 0)) (('calls: ' + $calls35.Count + ', unassigned: ' + $unassigned35.Count) + $(if ($unassigned35.Count) { ' -> ' + (($unassigned35 | ForEach-Object { $_.Extent.Text }) -join ' / ') } else { '' }))
# Absence is not enough: the loop could be deleted outright, or replaced by an expression that emits implicitly,
# and the two assertions above would still pass with the log empty again. So the shape is asserted positively, and
# the behaviour is counted - over every driver line this file captures, the helper's and case 12's direct one alike,
# since the acceptance asks for every invocation's output and not only the helper's.
$hostWrites35 = @()
if ($fn35.Count -eq 1) {
    $hostWrites35 = @($fn35[0].Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Write-Host' -and $n.Extent.Text -match '\$l' }, $true))
}
Assert-True '35. it still forwards the captured lines to the host' ($hostWrites35.Count -ge 1) ('Write-Host calls over the captured line: ' + $hostWrites35.Count)
Assert-True "35. and every driver line this file captured reached the host - the helper's and case 12's alike, counted where each happens" (($capturedLines -gt 0) -and ($forwardedLines -eq $capturedLines)) ('captured ' + $capturedLines + ', forwarded ' + $forwardedLines)

# -------------------- 36. no assertion in this file can be vacuous --------------------
# Backlog #53, PR #39 round 2: case 35's own third assertion was written with an apostrophe inside a single-quoted
# name, so the string closed early and PowerShell bound the rest as positional arguments - the condition became the
# bareword 's', which is truthy, and the assertion passed while the counters it compared differed by two. It reported
# PASS against a mutant it was written to catch. Every Assert-True call must therefore carry exactly its three
# arguments, checked on the AST of this file: name, condition, detail.
Write-Output ''
Write-Output '36. every Assert-True call in this file takes exactly its three arguments, so none of them can pass on a bareword'
$tokens36 = $null
$errors36 = $null
$ast36 = [System.Management.Automation.Language.Parser]::ParseFile($PSCommandPath, [ref]$tokens36, [ref]$errors36)
$asserts36 = @($ast36.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Assert-True' }, $true))
$malformed36 = @($asserts36 | Where-Object { $_.CommandElements.Count -ne 4 })
Assert-True '36. this file has assertions to check' ($asserts36.Count -gt 100) ('Assert-True calls: ' + $asserts36.Count)
# This one reports without Assert-True on purpose: a quoting mistake in the call that reports quoting mistakes would
# bind a truthy bareword as its own condition and announce PASS, which is the defect it exists to catch (PR #39 round
# 3). An if over a counter cannot be talked out of failing by how its message is written.
if ($malformed36.Count -eq 0) {
    $script:passes++
    Write-Output '[PASS] 36. every one of them binds name, condition and detail'
} else {
    $script:fails++
    Write-Output ('[FAIL] 36. every one of them binds name, condition and detail -> ' + (($malformed36 | ForEach-Object { 'line ' + $_.Extent.StartLineNumber + ': ' + $_.CommandElements.Count + ' elements' }) -join '; '))
}
Write-Output ''
Write-Output ('Summary: {0} passed, {1} failed' -f $passes, $fails)
if ($fails -eq 0) { Write-Output 'ALL SELF-TESTS OK'; exit 0 }
exit 1
