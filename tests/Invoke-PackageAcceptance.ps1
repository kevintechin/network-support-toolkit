<#
.SYNOPSIS
    Accepts a NetworkHealthCheck release asset on this machine with Windows PowerShell alone (backlog #19).

.DESCRIPTION
    The path a user takes, made repeatable on a machine that has nothing installed. The downloaded ZIP is checked
    against its published SHA256, extracted, checked against its own manifest (SHA256SUMS.txt) and line-ending rule,
    described by environment_probe.ps1, and then run through every step of the validation chain that needs neither
    Python nor git - the parser, the helper unit tests, the report-stage tests, the language-mode guard, the headless
    and the real-window GUI runs, the console acceptance runs (both languages against unreachable targets included) and
    the result-set self-check - plus the package root's launchers, which README_BILINGUAL.md sends people to. The steps
    that need Python or git (validator, guards, package) run on every commit on GitHub Actions instead.

    Everything ends up in one bundle - acceptance_summary.md, the chain's summary and logs, every report the runs wrote,
    the environment probe, and the checklist for the observations only a person can make - named by machine, label and
    time, next to the ZIP. Cases the chain did not reach are listed as NOT RUN, so a gap is visible rather than silent;
    cases dropped on purpose by -SkipGui are listed as SKIPPED. The exit code is the number of failed and not-run cases,
    and a bundle that cannot be written is a failed case: the bundle is the evidence, so a run without one is not a pass.

    On a machine restricted to a limited language mode the chain cannot run at all (its first New-Object is refused);
    the probe is written, the situation is stated, and the exit code is 3 - like the tool's own guard.

.PARAMETER Zip
    The downloaded release asset (NetworkHealthCheck-<version>.zip).
.PARAMETER PackageDir
    Alternatively, an already extracted package: the folder holding en-US\ and zh-TW\. The root launchers then write
    their reports into that folder's language subfolders, as a user's run would.
.PARAMETER ExpectedSha256
    The digest from the release notes. When given, a mismatch stops everything after the asset case.
.PARAMETER Label
    A short name for the scenario (e.g. win10-zhTW-nat-e1000e), used in the bundle name and the summary.
.PARAMETER WorkDir
    Where the extraction, staged copies, reports and logs go. Default: %TEMP%\nhc-acceptance\<timestamp>.
.PARAMETER BundleDir
    Where the bundle ZIP goes. Default: the folder of -Zip, or the parent of the work dir with -PackageDir.
.PARAMETER ChainSteps
    The chain steps to run, from parse, unit, report, envguard, gui-headless, gui, acceptance, resultset (all by
    default). The acceptance campaign runs acceptance,resultset only for a scenario that changes the network.
.PARAMETER SkipGui
    No real windows (a session without an interactive desktop): drops the gui step and the root launchers.
.PARAMETER RequireHealthy
    Window and console runs must also end Overall Healthy (the reference machine; off by default, because on a machine
    with a real network problem the warning is the tool doing its job).
.PARAMETER GuiTimeoutSeconds
    How long one real-window run may take; the IT entry samples TCP retransmissions for 125 s before it reports.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\Invoke-PackageAcceptance.ps1 -Zip "$env:USERPROFILE\Downloads\NetworkHealthCheck-1.2.2.zip" -ExpectedSha256 5dde92c7f6a5e05a525b92b401beb65edc850a4f92fda7a41adfc5b4e4ea78f7 -Label win10-zhTW-nat
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\Invoke-PackageAcceptance.ps1 -Zip C:\Users\test\Downloads\NetworkHealthCheck-1.2.2.zip -Label win11-enUS-hostonly -SkipGui
#>
[CmdletBinding()]
param(
    [string]$Zip,
    [string]$PackageDir,
    [string]$ExpectedSha256,
    [string]$Label = 'acceptance',
    [string]$WorkDir,
    [string]$BundleDir,
    [string]$ChainSteps = 'parse,unit,report,envguard,gui-headless,gui,acceptance,resultset',
    [switch]$SkipGui,
    [switch]$RequireHealthy,
    [int]$GuiTimeoutSeconds = 360
)

$ErrorActionPreference = 'Stop'
$PsExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$Tests = $PSScriptRoot
$Label = ($Label -replace '[^\w.-]', '_')
$Stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
# The chain steps that need neither Python nor git, with the number of cases each one has.
$ChainCases = [ordered]@{ 'parse' = 2; 'unit' = 2; 'report' = 2; 'envguard' = 2; 'gui-headless' = 4; 'gui' = 4; 'acceptance' = 5; 'resultset' = 1 }
$SelectedSteps = @($ChainSteps -split ',' | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
$unknownSteps = @($SelectedSteps | Where-Object { -not $ChainCases.Contains($_) })
if ($unknownSteps.Count) { throw ('unknown chain step(s): ' + ($unknownSteps -join ', ') + '; known: ' + (@($ChainCases.Keys) -join ', ')) }
$SelectedSteps = @($ChainCases.Keys | Where-Object { $SelectedSteps -contains $_ })
if (-not $SelectedSteps.Count) { throw 'no chain step selected' }
$Steps = $SelectedSteps -join ','
if (-not $Zip -and -not $PackageDir) { throw 'give -Zip (the downloaded release asset) or -PackageDir (an extracted package)' }
if (-not $WorkDir) { $WorkDir = Join-Path $env:TEMP ('nhc-acceptance\' + $Stamp) }
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
$WorkDir = (Resolve-Path -LiteralPath $WorkDir).Path
# Windows PowerShell stops at 260 characters of path; the deepest file this run writes sits about 110 characters below
# the work dir (chain\stage\gui-IT\zh-TW\Reports\NetworkHealthCheck_<time>_<computer>.json), so a long work dir is
# said so up front rather than discovered when the bundle fails.
if ($WorkDir.Length -gt 120) { Write-Host ('WARNING: the work dir is {0} characters long; paths under it may exceed the 260-character limit of Windows PowerShell - use a shorter -WorkDir if the run fails on a path' -f $WorkDir.Length) -ForegroundColor Yellow }
# A reused -WorkDir may hold an earlier invocation's chain output - its summary, its logs, its reports. It goes first,
# before anything else can complete early and bundle it as this run's (PR #10 rounds 2 to 4): a run that stops at the
# asset digest or at the extraction must leave a bundle with nothing but its own files in it.
$chainDir = Join-Path $WorkDir 'chain'
if (Test-Path -LiteralPath $chainDir) { Remove-Item -LiteralPath $chainDir -Recurse -Force -ErrorAction Stop }

# A restricted language mode (what application control creates) refuses the chain's first New-Object, the way it
# refuses the tool's: describe the machine, say so, exit 3 like the tool's own guard.
$mode = [string]$ExecutionContext.SessionState.LanguageMode
if ($mode -ne 'FullLanguage') {
    Write-Host ('PowerShell runs in {0} language mode on this machine: the validation chain cannot run here. Writing the environment probe only.' -f $mode)
    & $PsExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Tests 'environment_probe.ps1') -OutDir $WorkDir
    Write-Host ('work dir {0}' -f $WorkDir)
    exit 3
}

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$Results = New-Object System.Collections.ArrayList
$Started = Get-Date
$script:PackageRoot = $null
$script:ToolVersion = 'unknown'

function Invoke-Native {
    # Runs a native command; returns its merged output lines and exit code, and keeps the raw output as <LogName>.log.
    param([string]$FilePath, [string[]]$ArgumentList, [string]$LogName)
    $ErrorActionPreference = 'Continue'   # a native command's stderr must not become a terminating error
    if ($null -eq $ArgumentList) { $ArgumentList = @() }
    $lines = @(& $FilePath @ArgumentList 2>&1 | ForEach-Object { if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { [string]$_ } })
    $code = $LASTEXITCODE
    $header = @(('> ' + $FilePath + ' ' + ($ArgumentList -join ' ')), ('exit code ' + $code), '')
    [IO.File]::WriteAllLines((Join-Path $WorkDir ($LogName + '.log')), [string[]]($header + $lines), $Utf8NoBom)
    return @{ Output = $lines; ExitCode = $code }
}
function Invoke-Case {
    # Runs one case, records PASS / FAIL with its detail and duration, and prints the line.
    param([string]$Step, [string]$Case, [scriptblock]$Body)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try { $r = @(& $Body | Where-Object { $_ -is [hashtable] })[-1] }
    catch { $r = @{ Passed = $false; Detail = ('exception: ' + $_.Exception.Message) } }
    if ($null -eq $r) { $r = @{ Passed = $false; Detail = 'the case returned no result' } }
    $sw.Stop()
    $entry = [pscustomobject]@{ Step = $Step; Case = $Case; Result = $(if ($r.Passed) { 'PASS' } else { 'FAIL' }); Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1); Detail = [string]$r.Detail }
    [void]$Results.Add($entry)
    Write-Host ('[{0}] {1} / {2}: {3} ({4} s)' -f $entry.Result, $Step, $Case, $entry.Detail, $entry.Seconds) -ForegroundColor $(if ($r.Passed) { 'Green' } else { 'Red' })
}
function Add-NotRun([string]$Step, [string]$Case, [string]$Why) {
    # A case that should have run and did not: listed, and counted in the exit code like a failure.
    [void]$Results.Add([pscustomobject]@{ Step = $Step; Case = $Case; Result = 'NOT RUN'; Seconds = ''; Detail = $Why })
    Write-Host ('[NOT RUN] {0} / {1}: {2}' -f $Step, $Case, $Why) -ForegroundColor Yellow
}
function Add-Skipped([string]$Step, [string]$Case, [string]$Why) {
    # A case dropped on purpose (-SkipGui): listed so that the summary says what this run did not cover, not counted.
    [void]$Results.Add([pscustomobject]@{ Step = $Step; Case = $Case; Result = 'SKIPPED'; Seconds = ''; Detail = $Why })
    Write-Host ('[SKIPPED] {0} / {1}: {2}' -f $Step, $Case, $Why) -ForegroundColor DarkGray
}
function Write-Summary {
    # acceptance_summary.md from the results so far; returns the counts. Written before the bundle (it goes into it) and
    # again when the bundle fails, so that the file on disk carries that failure too.
    $passed = @($Results | Where-Object { $_.Result -eq 'PASS' }).Count
    $failed = @($Results | Where-Object { $_.Result -eq 'FAIL' }).Count
    $notRun = @($Results | Where-Object { $_.Result -eq 'NOT RUN' }).Count
    $skipped = @($Results | Where-Object { $_.Result -eq 'SKIPPED' }).Count
    $elapsed = [math]::Round(((Get-Date) - $Started).TotalSeconds)
    $md = @()
    $md += ('# NetworkHealthCheck {0} package acceptance - {1}' -f $script:ToolVersion, $Label)
    $md += ''
    $md += ('- Machine: {0}; {1}; Windows PowerShell {2}; user {3}' -f $env:COMPUTERNAME, [Environment]::OSVersion.VersionString, $PSVersionTable.PSVersion, $env:USERNAME)
    $md += ('- Date: {0}; {1} s' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $elapsed)
    $md += ('- Asset: {0}' -f $(if ($Zip) { $Zip } else { $script:PackageRoot + ' (given as -PackageDir)' }))
    $md += ('- Steps: {0}{1}; root launchers {2}' -f $Steps, $(if ($SkipGui) { ' with -SkipGui' } else { '' }), $(if ($SkipGui) { 'skipped' } else { 'run' }))
    $md += ('- Work dir: {0}' -f $WorkDir)
    $md += ''
    $md += '| Step | Case | Result | s | Detail |'
    $md += '|---|---|---|---:|---|'
    $md += @($Results | ForEach-Object { '| {0} | {1} | {2} | {3} | {4} |' -f $_.Step, $_.Case, $_.Result, $_.Seconds, ($_.Detail -replace '\|', '\|') })
    $md += ''
    $md += ('Summary: {0} passed, {1} failed, {2} not run, {3} skipped; {4} s' -f $passed, $failed, $notRun, $skipped, $elapsed)
    [IO.File]::WriteAllLines((Join-Path $WorkDir 'acceptance_summary.md'), [string[]]$md, $Utf8NoBom)
    return @{ Passed = $passed; Failed = $failed; NotRun = $notRun; Skipped = $skipped; Line = $md[-1] }
}
function Complete-Run {
    # The summary, the bundle, the exit code. Called at the end and after a failed asset case. The bundle is the
    # evidence this script exists to produce, so a bundle that cannot be written is a failed case and a nonzero exit code
    # even when every other case passed (PR #10 round 1).
    $counts = Write-Summary
    $summaryPath = Join-Path $WorkDir 'acceptance_summary.md'
    Write-Host ''
    $Results | Format-Table -AutoSize -Wrap Step, Case, Result, Seconds, Detail | Out-String -Width 250 | Write-Host
    Write-Host $counts.Line
    $zipName = 'nhc-acceptance_{0}_{1}_{2}.zip' -f $env:COMPUTERNAME, $Label, $Stamp
    try {
        $bundle = Join-Path $WorkDir 'bundle'
        if (Test-Path -LiteralPath $bundle) { Remove-Item -LiteralPath $bundle -Recurse -Force }
        New-Item -ItemType Directory -Force -Path $bundle | Out-Null
        Copy-Item -LiteralPath $summaryPath -Destination $bundle
        # This invocation's files only: a reused work dir may still hold an earlier run's logs and probe.
        Get-ChildItem -LiteralPath $WorkDir -File | Where-Object { ($_.Extension -eq '.log' -or $_.Name -like 'environment_probe_*.txt') -and $_.LastWriteTime -ge $Started } | Copy-Item -Destination $bundle
        $chainDir = Join-Path $WorkDir 'chain'
        if (Test-Path -LiteralPath $chainDir) {
            $chainBundle = Join-Path $bundle 'chain'
            New-Item -ItemType Directory -Force -Path $chainBundle | Out-Null
            Get-ChildItem -LiteralPath $chainDir -File | Where-Object { $_.Name -eq 'summary.md' -or $_.Extension -eq '.log' } | Copy-Item -Destination $chainBundle
            # Every report the chain's runs wrote, named by the staged copy that wrote it (stage\console\en-US\Reports\x
            # becomes console\en-US\x - shorter, because Windows PowerShell stops at 260 characters of path and a deep
            # work dir eats most of them), and the environment reports of the envguard step.
            Get-ChildItem -LiteralPath $chainDir -Recurse -File | Where-Object { $_.FullName -match '\\Reports\\' -or $_.Name -like 'NetworkHealthCheck_ENVIRONMENT_*.txt' } | ForEach-Object {
                $target = Join-Path $chainBundle (($_.FullName.Substring($chainDir.Length).TrimStart('\')) -replace '^stage\\', '' -replace '\\Reports\\', '\')
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
                Copy-Item -LiteralPath $_.FullName -Destination $target
            }
        }
        if ($script:PackageRoot) {
            foreach ($lang in @('en-US', 'zh-TW')) {   # the root launchers' reports, written since this run started
                $reports = Join-Path $script:PackageRoot ($lang + '\Reports')
                if (Test-Path -LiteralPath $reports) {
                    $target = Join-Path $bundle ('root-launcher\' + $lang + '\Reports')
                    New-Item -ItemType Directory -Force -Path $target | Out-Null
                    Get-ChildItem -LiteralPath $reports -File | Where-Object { $_.LastWriteTime -gt $Started } | Copy-Item -Destination $target
                }
            }
        }
        $checklist = Join-Path $Tests 'package-acceptance-checklist.md'
        if (Test-Path -LiteralPath $checklist) { Copy-Item -LiteralPath $checklist -Destination (Join-Path $bundle ('checklist_' + $Label + '.md')) }
        New-Item -ItemType Directory -Force -Path $BundleDir -ErrorAction Stop | Out-Null
        $zipOut = Join-Path (Resolve-Path -LiteralPath $BundleDir).Path $zipName
        if (Test-Path -LiteralPath $zipOut) { Remove-Item -LiteralPath $zipOut -Force }
        Compress-Archive -Path (Join-Path $bundle '*') -DestinationPath $zipOut -ErrorAction Stop
        Write-Host ('bundle {0} ({1} bytes, SHA256 {2})' -f $zipOut, (Get-Item -LiteralPath $zipOut).Length, (Get-FileHash -LiteralPath $zipOut -Algorithm SHA256).Hash.ToLowerInvariant())
    }
    catch {
        [void]$Results.Add([pscustomobject]@{ Step = 'bundle'; Case = $zipName; Result = 'FAIL'; Seconds = ''; Detail = ('not written: ' + $_.Exception.Message + '; the work dir still holds everything: ' + $WorkDir) })
        Write-Host ('[FAIL] bundle / {0}: not written: {1}' -f $zipName, $_.Exception.Message) -ForegroundColor Red
        $counts = Write-Summary   # the file on disk carries the bundle failure as well
        Write-Host $counts.Line
    }
    exit ($counts.Failed + $counts.NotRun)
}

Write-Host ('NetworkHealthCheck package acceptance - {0} - {1} on {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Label, $env:COMPUTERNAME)
Write-Host ('  {0}; Windows PowerShell {1}; work dir {2}' -f [Environment]::OSVersion.VersionString, $PSVersionTable.PSVersion, $WorkDir)

# -------------------- The asset --------------------
if ($Zip) {
    $Zip = (Resolve-Path -LiteralPath $Zip).Path
    if (-not $BundleDir) { $BundleDir = Split-Path -Parent $Zip }
    Invoke-Case 'asset' (Split-Path -Leaf $Zip) {
        $hash = (Get-FileHash -LiteralPath $Zip -Algorithm SHA256).Hash.ToLowerInvariant()
        $size = (Get-Item -LiteralPath $Zip).Length
        if ($ExpectedSha256) {
            $want = $ExpectedSha256.Trim().ToLowerInvariant()
            $ok = ($hash -eq $want)
            return @{ Passed = $ok; Detail = ('{0} bytes, SHA256 {1}; expected {2}: {3}' -f $size, $hash, $want, $(if ($ok) { 'match' } else { 'MISMATCH' })) }
        }
        @{ Passed = $true; Detail = ('{0} bytes, SHA256 {1}; no expected digest given - compare it with the release notes' -f $size, $hash) }
    }
    if (@($Results | Where-Object { $_.Result -ne 'PASS' }).Count) { Add-NotRun 'asset' 'extract and everything after it' 'the asset is not the published one'; Complete-Run }
    Invoke-Case 'asset' 'extract' {
        $dest = Join-Path $WorkDir 'package'
        if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
        Expand-Archive -LiteralPath $Zip -DestinationPath $dest -Force
        $tops = @(Get-ChildItem -LiteralPath $dest -Directory)
        if ($tops.Count -ne 1 -or $tops[0].Name -notlike 'NetworkHealthCheck-*') { return @{ Passed = $false; Detail = ('expected one NetworkHealthCheck-<version> folder at the top of the ZIP, found: ' + (@($tops | ForEach-Object { $_.Name }) -join ', ')) } }
        $script:PackageRoot = $tops[0].FullName
        @{ Passed = $true; Detail = ('{0}; {1} files' -f $script:PackageRoot, @(Get-ChildItem -LiteralPath $script:PackageRoot -Recurse -File).Count) }
    }
}
else {
    $script:PackageRoot = (Resolve-Path -LiteralPath $PackageDir).Path
    if (-not $BundleDir) { $BundleDir = Split-Path -Parent $WorkDir }
}
if (-not $script:PackageRoot) { Add-NotRun 'package' 'everything after the extraction' 'no package folder'; Complete-Run }

# -------------------- The package --------------------
Invoke-Case 'package' 'layout and version' {
    $missing = @()
    foreach ($rel in @('en-US\NetworkHealthCheck.ps1', 'en-US\NetworkHealthCheck.config.json', 'en-US\Start-NetworkCheck.cmd', 'en-US\Start-NetworkCheck-IT.cmd', 'en-US\Start-NetworkCheck-Console.cmd', 'zh-TW\NetworkHealthCheck.ps1', 'zh-TW\NetworkHealthCheck.config.json', 'zh-TW\Start-NetworkCheck.cmd', 'zh-TW\Start-NetworkCheck-IT.cmd', 'zh-TW\Start-NetworkCheck-Console.cmd', 'Start-English.cmd', 'Start-Traditional-Chinese.cmd', 'README_BILINGUAL.md', 'SHA256SUMS.txt')) {
        if (-not (Test-Path -LiteralPath (Join-Path $script:PackageRoot $rel))) { $missing += $rel }
    }
    if ($missing.Count) { return @{ Passed = $false; Detail = ('missing: ' + ($missing -join ', ')) } }
    foreach ($line in [IO.File]::ReadLines((Join-Path $script:PackageRoot 'en-US\NetworkHealthCheck.ps1'))) {
        if ($line -match '^\$script:ToolVersion\s*=\s*"([^"]+)"') { $script:ToolVersion = $Matches[1]; break }
    }
    $zhVersion = ''
    foreach ($line in [IO.File]::ReadLines((Join-Path $script:PackageRoot 'zh-TW\NetworkHealthCheck.ps1'))) {
        if ($line -match '^\$script:ToolVersion\s*=\s*"([^"]+)"') { $zhVersion = $Matches[1]; break }
    }
    if ($script:ToolVersion -eq 'unknown' -or $zhVersion -ne $script:ToolVersion) { return @{ Passed = $false; Detail = ('tool version en-US {0}, zh-TW {1}' -f $script:ToolVersion, $zhVersion) } }
    @{ Passed = $true; Detail = ('tool version {0} in both languages; every launcher and script present' -f $script:ToolVersion) }
}
Invoke-Case 'package' 'SHA256SUMS.txt' {
    $manifest = Join-Path $script:PackageRoot 'SHA256SUMS.txt'
    $entries = 0
    $bad = @()
    foreach ($line in [IO.File]::ReadLines($manifest)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        # Every non-blank line must be an entry: a truncated or malformed one would leave its file unverified while the
        # case passed on the others (PR #10 round 2).
        if ($line -notmatch '^([0-9a-fA-F]{64})\s+\*?(.+?)\s*$') { $bad += ('unparsable line: ' + $line.Trim()); continue }
        $want = $Matches[1].ToLowerInvariant()
        $rel = $Matches[2] -replace '/', '\'
        $entries++
        $path = Join-Path $script:PackageRoot $rel
        if (-not (Test-Path -LiteralPath $path)) { $bad += ($rel + ' missing'); continue }
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $want) { $bad += ($rel + ' differs') }
    }
    @{ Passed = ($entries -gt 0 -and $bad.Count -eq 0); Detail = ('{0} entries, {1} wrong{2}' -f $entries, $bad.Count, $(if ($bad.Count) { ': ' + ($bad -join ', ') } else { '' })) }
}
Invoke-Case 'package' 'line endings (.ps1, .cmd and .config.json are CRLF)' {
    $files = @(Get-ChildItem -LiteralPath $script:PackageRoot -Recurse -File | Where-Object { $_.Extension -match '^\.(ps1|cmd)$' -or $_.Name -like '*.config.json' })
    $bad = @($files | Where-Object { ([IO.File]::ReadAllText($_.FullName) -replace "`r`n", '') -match "`n" } | ForEach-Object { $_.Name })
    @{ Passed = ($files.Count -gt 0 -and $bad.Count -eq 0); Detail = ('{0} files, {1} with a stray LF{2}' -f $files.Count, $bad.Count, $(if ($bad.Count) { ': ' + ($bad -join ', ') } else { '' })) }
}

# -------------------- The machine --------------------
Invoke-Case 'probe' 'environment_probe.ps1' {
    $r = Invoke-Native $PsExe @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Tests 'environment_probe.ps1'), '-OutDir', $WorkDir, '-PackageDir', $script:PackageRoot) 'probe'
    $file = [string]@($r.Output | Where-Object { $_ -match '^written: ' })[0] -replace '^written: ', ''
    $os = [string]@($r.Output | Where-Object { $_ -match 'Caption / version' })[0] -replace '^\s*[^:]+:\s*', ''
    $lm = [string]@($r.Output | Where-Object { $_ -match '^\s*Language mode:' })[0] -replace '^\s*[^:]+:\s*', ''
    @{ Passed = (($r.ExitCode -eq 0) -and $file -and (Test-Path -LiteralPath $file)); Detail = ('{0}; language mode {1}; {2}' -f $os, $lm, (Split-Path -Leaf $file)) }
}

# -------------------- The chain --------------------
$chainArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Tests 'Invoke-ValidationChain.ps1'), '-PackageDir', $script:PackageRoot, '-Steps', $Steps, '-WorkDir', $chainDir, '-GuiTimeoutSeconds', $GuiTimeoutSeconds)
if ($SkipGui) { $chainArgs += '-SkipGui' }
if ($RequireHealthy) { $chainArgs += '-RequireHealthy' }
Write-Host ''
Write-Host ('--- Invoke-ValidationChain.ps1 -Steps {0}{1} against the extracted package ---' -f $Steps, $(if ($SkipGui) { ' -SkipGui' } else { '' }))
$chainLines = @()
# The chain's folder was cleared at the start; a summary older than this launch is still not accepted, so that a child
# that dies before writing its own is never read as an earlier one.
$summary = Join-Path $chainDir 'summary.md'
$chainLaunched = Get-Date
$ErrorActionPreference = 'Continue'   # the child's stderr must not become a terminating error here
$prevOutputEncoding = [Console]::OutputEncoding
try { [Console]::OutputEncoding = $Utf8NoBom } catch { }   # the chain writes UTF-8; read it as such, so zh-TW text survives into chain.log
& $PsExe @chainArgs 2>&1 | ForEach-Object {
    $text = $(if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { [string]$_ })
    Write-Host ('  ' + $text)
    $chainLines += $text
}
$chainExit = $LASTEXITCODE
try { [Console]::OutputEncoding = $prevOutputEncoding } catch { }
$ErrorActionPreference = 'Stop'
[IO.File]::WriteAllLines((Join-Path $WorkDir 'chain.log'), [string[]]$chainLines, $Utf8NoBom)
Write-Host ('--- chain exit code {0} ---' -f $chainExit)

# The chain's own table becomes part of this one; whatever it did not reach is listed as NOT RUN, per step, from the
# number of cases each step has.
$expected = [ordered]@{}
foreach ($step in $SelectedSteps) { $expected[$step] = $ChainCases[$step] }
if ($SkipGui -and $expected.Contains('gui')) { $expected['gui'] = 0; Add-Skipped 'chain/gui' '4 real-window cases' '-SkipGui' }
$seen = @{}
$summaryFresh = (Test-Path -LiteralPath $summary) -and ((Get-Item -LiteralPath $summary).LastWriteTime -ge $chainLaunched)
if ($summaryFresh) {
    foreach ($line in [IO.File]::ReadLines($summary)) {
        if ($line -notmatch '^\|\s*(?<step>[^|]+?)\s*\|\s*(?<case>[^|]+?)\s*\|\s*(?<result>PASS|FAIL)\s*\|\s*(?<s>[^|]*?)\s*\|\s*(?<detail>.*)\|\s*$') { continue }
        $step = $Matches['step']
        [void]$Results.Add([pscustomobject]@{ Step = 'chain/' + $step; Case = $Matches['case']; Result = $Matches['result']; Seconds = $Matches['s']; Detail = ($Matches['detail'] -replace '\\\|', '|') })
        $seen[$step] = $(if ($seen.ContainsKey($step)) { $seen[$step] + 1 } else { 1 })
    }
}
foreach ($step in @($expected.Keys)) {
    $have = $(if ($seen.ContainsKey($step)) { $seen[$step] } else { 0 })
    for ($i = $have; $i -lt $expected[$step]; $i++) {
        Add-NotRun ('chain/' + $step) ('case {0} of {1}' -f ($i + 1), $expected[$step]) $(if ($summaryFresh) { 'the chain ended before this case' } else { ('no summary.md from this invocation - the chain exited with code {0}; see chain.log' -f $chainExit) })
    }
}

# -------------------- The package root's launchers --------------------
# README_BILINGUAL.md sends people to Start-English.cmd / Start-Traditional-Chinese.cmd at the package root, which open
# the user entry of their language. The language folders' own launchers were exercised by the gui step above, with the
# result-set assertion; here the window must open, start by itself, report as the user entry and close cleanly.
if ($SkipGui) { Add-Skipped 'root-launcher' 'Start-English.cmd, Start-Traditional-Chinese.cmd' '-SkipGui' }
else {
    foreach ($root in @(@{ Lang = 'en-US'; Launcher = 'Start-English.cmd' }, @{ Lang = 'zh-TW'; Launcher = 'Start-Traditional-Chinese.cmd' })) {
        Invoke-Case 'root-launcher' ($root.Launcher + ' (' + $root.Lang + ' user entry, real window)') {
            $launcher = Join-Path $script:PackageRoot $root.Launcher
            $dir = Join-Path $script:PackageRoot $root.Lang
            $started = Get-Date
            $r = Invoke-Native $PsExe @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Tests 'gui_check.ps1'), '-PackageDir', $dir, '-Entry', 'User', '-Via', 'Launcher', '-LauncherPath', $launcher, '-TimeoutSeconds', $GuiTimeoutSeconds) ('root_' + $root.Lang)
            if ($r.ExitCode -ne 0) { return @{ Passed = $false; Detail = ('exit code {0}: {1}' -f $r.ExitCode, [string]@($r.Output | Where-Object { $_ -match 'ERROR' })[0]) } }
            $json = @(Get-ChildItem -LiteralPath (Join-Path $dir 'Reports') -Filter '*.json' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt $started } | Sort-Object LastWriteTime -Descending | Select-Object -First 1)[0]
            if ($null -eq $json) { return @{ Passed = $false; Detail = 'exit 0 but no JSON report' } }
            $d = Get-Content -LiteralPath $json.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            $bad = @()
            if ([string]$d.RunOptions.EntryPoint -ne 'User') { $bad += ('EntryPoint=' + $d.RunOptions.EntryPoint) }
            if ([bool]$d.RunOptions.ExpandDetails) { $bad += 'ExpandDetails=True' }
            if ([string]$d.SchemaVersion -ne '2') { $bad += ('SchemaVersion=' + $d.SchemaVersion) }
            if ($RequireHealthy -and ([string]$d.Overall.Code -ne 'PASS')) { $bad += ('Overall {0}, not PASS' -f $d.Overall.Code) }
            $cmdline = [string]@($r.Output | Where-Object { $_ -match 'launcher started .* with: ' })[0]
            if (-not $cmdline) { $bad += 'the launcher command line was not captured' }
            elseif (($cmdline -match '(?i)-Interactive\b') -or ($cmdline -match '(?i)-ExpandDetails\b')) { $bad += 'the user launcher passes an IT switch' }
            if (@($r.Output | Where-Object { $_ -match 'closed via the Close button; process exit code 0$' }).Count -eq 0) { $bad += 'not closed through the Close button with exit code 0' }
            $window = [string]@($r.Output | Where-Object { $_ -match "window: '" })[0] -replace '^\[[^\]]+\]\s*', ''
            $detail = ('Overall {0} ({1}); {2} results; {3}' -f $d.Overall.Text, $d.Overall.Code, @($d.Results).Count, $window)
            if ($bad.Count) { $detail = ($bad -join '; ') + ' | ' + $detail }
            @{ Passed = ($bad.Count -eq 0); Detail = $detail }
        }
    }
}

Complete-Run
