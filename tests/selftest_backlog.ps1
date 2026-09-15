<#
.SYNOPSIS
    Negative self-test for backlog_index.ps1 (backlog #55).

.DESCRIPTION
    A check nobody has seen fail is a check nobody has tested. This copies docs\backlog.md and README.md into a work
    folder, breaks one thing at a time, and asserts that the backlog step fails - on the check that owns that
    mistake and on no other, so that a reader of a red run is pointed at one place. The untouched copy has to pass,
    or every case below would be measuring the copy rather than the mutation; and every mutation has to change the
    copy, or a case would be measuring a stale search string rather than the check.

.PARAMETER WorkDir
    Where the copy goes. Default: %TEMP%\nhc-backlog\<timestamp>.
#>
param([string]$WorkDir)

$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
if (-not $WorkDir) { $WorkDir = Join-Path $env:TEMP ('nhc-backlog\' + (Get-Date -Format 'yyyyMMdd_HHmmss')) }
$Tree = Join-Path $WorkDir 'tree'
$PsExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$Em = [string][char]0x2014

# The copy: the two files the step reads, at the paths it reads them from.
$Backlog = 'docs\backlog.md'
$Readme = 'README.md'
New-Item -ItemType Directory -Force -Path (Join-Path $Tree 'docs') | Out-Null
foreach ($rel in @($Backlog, $Readme)) { Copy-Item -LiteralPath (Join-Path $Root $rel) -Destination (Join-Path $Tree $rel) -Force }
Write-Output ("Copy: {0}" -f $Tree)

$fails = 0; $passes = 0
$saved = @{}
function Read-All([string]$rel) { [IO.File]::ReadAllText((Join-Path $Tree $rel), [Text.Encoding]::UTF8) }
function Write-All([string]$rel, [string]$text) {
    # The byte-order mark is part of the file and is kept; the first write of a file keeps its bytes for Restore-All.
    $path = Join-Path $Tree $rel
    if (-not $saved.ContainsKey($rel)) { $saved[$rel] = [IO.File]::ReadAllBytes($path) }
    $head = $saved[$rel]
    $hadBom = ($head.Length -ge 3) -and ($head[0] -eq 0xEF) -and ($head[1] -eq 0xBB) -and ($head[2] -eq 0xBF)
    [IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($hadBom)))
}
function Edit-All([string]$rel, [string]$from, [string]$to) {
    # One literal replacement that has to find its text: a search string the document no longer contains would
    # leave the copy clean, and a clean copy failing nothing would read as the check missing the mutation.
    $text = Read-All $rel
    if ($text.IndexOf($from, [StringComparison]::Ordinal) -lt 0) { throw ("mutation found nothing to change in {0}: {1}" -f $rel, $from) }
    Write-All $rel $text.Replace($from, $to)
}
function Get-Newline([string]$rel) { if ((Read-All $rel).Contains("`r`n")) { return "`r`n" } else { return "`n" } }
function Restore-All {
    foreach ($rel in @($saved.Keys)) { [IO.File]::WriteAllBytes((Join-Path $Tree $rel), $saved[$rel]) }
    $script:saved = @{}
}
function Invoke-Index {
    $ErrorActionPreference = 'Continue'   # a crash in the checker is a result to report, not the end of this run
    $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'backlog_index.ps1'), '-RepoRoot', $Tree)
    $out = @(& $PsExe @args 2>&1 | ForEach-Object { [string]$_ })
    return @{ Output = $out; ExitCode = $LASTEXITCODE }
}
function Assert-Clean([string]$name) {
    $r = Invoke-Index
    $summary = [string]@($r.Output | Where-Object { $_ -match '^Summary:' })[-1]
    $ok = ($r.ExitCode -eq 0) -and ($summary -match '^Summary:\s+\d+ passed, 0 failed')
    if ($ok) { $script:passes++; Write-Output "[PASS] $name -> $summary" }
    else { $script:fails++; Write-Output ("[FAIL] $name -> exit {0}; {1}" -f $r.ExitCode, (@($r.Output | Where-Object { $_ -like '`[FAIL`]*' }) -join ' | ')) }
}
function Assert-Catches([string]$name, [string]$expectedCheck, [scriptblock]$mutation) {
    # The mutation is applied, the step run, the copy put back; the run has to fail on the expected check and on
    # that check alone.
    try { & $mutation }
    catch { Restore-All; $script:fails++; Write-Output ("[FAIL] {0} -> the mutation could not be applied: {1}" -f $name, $_.Exception.Message); return }
    $r = Invoke-Index
    Restore-All
    $failed = @($r.Output | Where-Object { $_ -like '`[FAIL`]*' })
    $hit = @($failed | Where-Object { $_ -match ('^\[FAIL\]\s+' + [regex]::Escape($expectedCheck) + '\b') })
    $ok = ($r.ExitCode -gt 0) -and ($hit.Count -eq 1) -and ($failed.Count -eq 1)
    if ($ok) { $script:passes++; Write-Output ("[PASS] {0} -> {1} caught it, alone: {2}" -f $name, $expectedCheck, ($hit[0] -replace '^\[FAIL\]\s+', '')) }
    else { $script:fails++; Write-Output ("[FAIL] {0} -> expected {1} to fail alone; got: {2}" -f $name, $expectedCheck, $(if ($failed.Count) { $failed -join ' | ' } else { 'nothing failed' })) }
}
function Assert-StillClean([string]$name, [scriptblock]$mutation) {
    # A change the row may legitimately carry: the step has to keep passing, or a well-formed row would be refused.
    try { & $mutation }
    catch { Restore-All; $script:fails++; Write-Output ("[FAIL] {0} -> the change could not be applied: {1}" -f $name, $_.Exception.Message); return }
    $r = Invoke-Index
    Restore-All
    $summary = [string]@($r.Output | Where-Object { $_ -match '^Summary:' })[-1]
    $ok = ($r.ExitCode -eq 0) -and ($summary -match '^Summary:\s+\d+ passed, 0 failed')
    if ($ok) { $script:passes++; Write-Output "[PASS] $name -> still $summary" }
    else { $script:fails++; Write-Output ("[FAIL] {0} -> expected nothing to fail; got: {1}" -f $name, (@($r.Output | Where-Object { $_ -like '`[FAIL`]*' }) -join ' | ')) }
}
function Get-FirstMatch([string]$rel, [string]$pattern) {
    $m = [regex]::Match((Read-All $rel), $pattern)
    if (-not $m.Success) { throw ("nothing matches {0} in {1}" -f $pattern, $rel) }
    return $m
}

# 1 - the control: the copy as it stands has to pass.
Assert-Clean 'the untouched copy passes'

# 2 - the page against itself: the four statements of the item, the shape they need, and the rule behind them.
Assert-Catches 'the closed section is not there to be found' 'I0' {
    Edit-All $Backlog '## Closed items' '## The closed items'
}
Assert-Catches 'an open row whose body is gone' 'I1' {
    # The first body heading of the page, whichever item that is today; its text stays where it was, headed by nothing.
    $heading = (Get-FirstMatch $Backlog ('(?m)^### \d+ ' + $Em + ' .+$')).Value.TrimEnd("`r")
    Edit-All $Backlog $heading ''
}
Assert-Catches 'a body with no row, numbered after the highest' 'I2' {
    # The next unused number, so that the gap check has nothing to say and this is the one mistake on the page.
    $highest = ([regex]::Matches((Read-All $Backlog), '(?m)^\|\s*(\d+)\s*\|') | ForEach-Object { [int]$_.Groups[1].Value } | Measure-Object -Maximum).Maximum
    $nl = Get-Newline $Backlog
    Edit-All $Backlog ($nl + '## Closed items') ($nl + '### ' + ($highest + 1) + ' ' + $Em + ' A body with no row' + $nl + $nl + 'Raised by nobody.' + $nl + $nl + '## Closed items')
}
Assert-Catches 'a number in both tables, and the README believing the closed table' 'I3' {
    # The first open row's number gains a closed row too. The README's closed list follows the closed table, as it
    # would after a closing change that moved the number without removing the open row - so the list gains it as
    # well, and what is left is the number standing in both tables.
    $first = (Get-FirstMatch $Backlog '(?m)^\|\s*(\d+)\s*\|').Groups[1].Value
    $nl = Get-Newline $Backlog
    Edit-All $Backlog ($nl + $nl + '## Adding and closing an item') ($nl + '| ' + $first + ' | closed and still open | never |' + $nl + $nl + '## Adding and closing an item')
    Edit-All $Readme ' are closed' (', ' + $first + ' are closed')
}
Assert-Catches 'a number in neither table' 'I4' {
    # Closed item 32 leaves both the closed table and the README's list, which names it on its own between two
    # ranges; the list then still matches the table, and the number is nowhere.
    $rowLine = (Get-FirstMatch $Backlog '(?m)^\| 32 \|.*$').Value.TrimEnd("`r")
    Edit-All $Backlog ($rowLine + (Get-Newline $Backlog)) ''
    Edit-All $Readme ', 32 to 36,' ', 33 to 36,'
}
Assert-Catches 'a row numbered 0, the README listing it too' 'I4' {
    # PR #63, round 4: 0 is a number the casts keep and the range 1..highest never sees; the README's closed list
    # follows the closed table, so that the number itself is the one thing wrong.
    $nl = Get-Newline $Backlog
    Edit-All $Backlog ($nl + $nl + '## Adding and closing an item') ($nl + '| 0 | an item before the first | never |' + $nl + $nl + '## Adding and closing an item')
    Edit-All $Readme 'Numbers 1 to 21' 'Numbers 0, 1 to 21'
}
Assert-Catches 'a row and a body numbered -1, which no pattern reads' 'I6' {
    # PR #63, round 6: the row and the heading both fell outside what the two patterns read, so the number reached no
    # check; a line the step cannot read is a failure now, and this is the one thing wrong with the copy.
    $nl = Get-Newline $Backlog
    Edit-All $Backlog ($nl + 'The table is an index;') ($nl + '| -1 | an item before the first, unread | tests |' + $nl + $nl + 'The table is an index;')
    Edit-All $Backlog ($nl + '## Closed items') ($nl + '### -1 ' + $Em + ' An item before the first, unread' + $nl + $nl + 'Raised by nobody.' + $nl + $nl + '## Closed items')
}
Assert-Catches 'an item heading with a hyphen where the em dash goes' 'I6' {
    # The other way a heading falls outside the pattern; a new number, so that no row is left without its body.
    $highest = ([regex]::Matches((Read-All $Backlog), '(?m)^\|\s*(\d+)\s*\|') | ForEach-Object { [int]$_.Groups[1].Value } | Measure-Object -Maximum).Maximum
    $nl = Get-Newline $Backlog
    Edit-All $Backlog ($nl + '## Closed items') ($nl + '### ' + ($highest + 1) + ' - A body headed with a hyphen' + $nl + $nl + 'Raised by nobody.' + $nl + $nl + '## Closed items')
}
Assert-Catches 'a closed row listed twice' 'I5' {
    $rowLine = (Get-FirstMatch $Backlog '(?m)^\| 32 \|.*$').Value.TrimEnd("`r")
    Edit-All $Backlog $rowLine ($rowLine + (Get-Newline $Backlog) + $rowLine)
}

# 3 - the README's row against the page.
Assert-Catches 'the README has no Backlog row' 'R0' {
    Edit-All $Readme '| Backlog |' '| Backlogs |'
}
Assert-Catches 'the open count one too many' 'R1' {
    $count = (Get-FirstMatch $Readme '\| Backlog \| (\d+) items open').Groups[1].Value
    Edit-All $Readme ('| Backlog | ' + $count + ' items open') ('| Backlog | ' + ([int]$count + 1) + ' items open')
}
Assert-Catches 'a closed item still listed as open, its group counted right' 'R2' {
    # The number is closed, the group's count is raised with it, and the link has no body to point at: R4 leaves
    # a link without a body to I1, so only R2 sees the closed number.
    Edit-All $Readme 'four changes to the tool ([#38]' 'five changes to the tool ([#40](docs/backlog.md#40--the-report-explained-the-badge) the badge explanation, [#38]'
    Edit-All $Readme 'sum to twelve where the items are eleven' 'sum to thirteen where the items are twelve'
}
Assert-Catches 'an open item dropped from the row, its group counted right' 'R3' {
    Edit-All $Readme '[#29](docs/backlog.md#29--the-campaign-asks-a-person-to-type-what-a-script-could-do) the campaign''s manual steps, ' ''
    Edit-All $Readme 'four in `tests/`' 'three in `tests/`'
    Edit-All $Readme 'sum to twelve where the items are eleven' 'sum to eleven where the items are ten'
}
Assert-Catches 'a link to a heading the page does not have' 'R4' {
    Edit-All $Readme 'docs/backlog.md#29--the-campaign-asks-a-person-to-type-what-a-script-could-do' 'docs/backlog.md#29--the-campaign-asks-a-person-to-type-what-a-scripts-could-do'
}
Assert-Catches 'a group whose stated count is not what it lists' 'R5' {
    Edit-All $Readme 'four changes to the tool (' 'five changes to the tool ('
    Edit-All $Readme 'sum to twelve where the items are eleven' 'sum to thirteen where the items are eleven'
}
Assert-Catches 'an open item linked outside every group, its group counted right' 'R5' {
    # PR #63, round 1: the link leaves its group, the group's count follows it, and the link stands in the row's prose
    # between the last group and the closed list, where it is listed (R2, R3) and points at its heading (R4) and is
    # in no group; the overlap sentence is moved with the count so that this is the one thing R5 has to say.
    Edit-All $Readme '[#29](docs/backlog.md#29--the-campaign-asks-a-person-to-type-what-a-script-could-do) the campaign''s manual steps, ' ''
    Edit-All $Readme 'four in `tests/`' 'three in `tests/`'
    Edit-All $Readme 'sum to twelve where the items are eleven' 'sum to eleven where the items are eleven'
    Edit-All $Readme ' Numbers 1 to 21' ' [#29](docs/backlog.md#29--the-campaign-asks-a-person-to-type-what-a-script-could-do) stands outside every group. Numbers 1 to 21'
}
Assert-Catches 'the overlap sentence stating a sum the groups do not make' 'R5' {
    Edit-All $Readme 'sum to twelve where the items are eleven' 'sum to thirteen where the items are eleven'
}
Assert-Catches 'an item listed twice in the same group, the count and the sum raised with it' 'R5' {
    # PR #63, round 2: a copied link is a second membership of the same group, not of a further one; the group's count
    # and the overlap sentence are raised with it so that the duplicate is the one thing R5 has to say.
    Edit-All $Readme 'four changes to the tool ([#38](docs/backlog.md#38--the-retransmission-counter-read-fails-intermittently-and-takes-the-verdict-and-the-runs-length-with-it) the retransmission' 'five changes to the tool ([#38](docs/backlog.md#38--the-retransmission-counter-read-fails-intermittently-and-takes-the-verdict-and-the-runs-length-with-it) twice, [#38](docs/backlog.md#38--the-retransmission-counter-read-fails-intermittently-and-takes-the-verdict-and-the-runs-length-with-it) the retransmission'
    Edit-All $Readme 'sum to twelve where the items are eleven' 'sum to thirteen where the items are eleven'
}
Assert-Catches 'a number listed as closed that no closed row carries' 'R6' {
    Edit-All $Readme ' are closed' ', 999 are closed'
}
Assert-Catches 'a closed number listed twice, once in a range and once alone' 'R6' {
    # PR #63, round 3: the list still names every closed number and no other, so only the repeat is wrong.
    Edit-All $Readme 'Numbers 1 to 21, 23' 'Numbers 1 to 21, 21, 23'
}
Assert-Catches 'a second closed-numbers sentence after the first' 'R6' {
    # PR #63, round 5: the first sentence is the one read, and the second used to be ignored with everything after it.
    Edit-All $Readme ' are closed |' ' are closed. Numbers 1 to 5 are closed |'
}

# 4 - what the row may say without being misread: a date, a version and a mention between a group's count and its
# parenthesis are not the count (the self-audit before round 4 - the last number before the parenthesis used to be).
Assert-StillClean 'a date, a version and a mention between a count and its group are not the count' {
    Edit-All $Readme 'four in `tests/` (' 'four in `tests/`, as of 2026-09-13 and 1.2.14 and #25 ('
}

# 5 - and the control again, to prove every mutation was put back.
Assert-Clean 'the copy is clean again after every mutation'

Write-Output ("Summary: {0} passed, {1} failed" -f $passes, $fails)
if ($fails -eq 0) { Write-Output 'ALL SELF-TESTS OK' }
exit $fails
