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
Assert-True '1. the campaign bundle was written' ($bundle1.Count -eq 1) ('bundles: ' + $bundle1.Count)

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
$r5 = Invoke-Campaign 'fail' @('-Zip', $zip, '-Scenarios', 'M1', '-SkipGui') "M1=done`r`n"
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
