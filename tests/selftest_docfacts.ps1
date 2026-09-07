<#
.SYNOPSIS
    Negative self-test for doc_facts.ps1 (backlog #33, tier 1).

.DESCRIPTION
    A check nobody has seen fail is a check nobody has tested. This copies the package and the sop/ documents into a
    work folder, breaks one thing at a time, and asserts that the document-fact step fails - and fails on the check
    that owns that mistake, not on another one. The untouched copy has to pass, or every case below would be measuring
    the copy rather than the mutation.

.PARAMETER WorkDir
    Where the copy goes. Default: %TEMP%\nhc-docfacts\<timestamp>.
#>
param([string]$WorkDir)

$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
if (-not $WorkDir) { $WorkDir = Join-Path $env:TEMP ('nhc-docfacts\' + (Get-Date -Format 'yyyyMMdd_HHmmss')) }
$Tree = Join-Path $WorkDir 'tree'
$PsExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

# The copy: everything the step reads, without the report folders, which it never opens. docs/ is part of it because
# the technical guides point at the repository design note that lives there, and the step resolves such a path.
New-Item -ItemType Directory -Force -Path $Tree | Out-Null
foreach ($sub in @('healthcheck', 'sop', 'docs')) {
    $src = Join-Path $Root $sub
    Get-ChildItem -LiteralPath $src -Recurse -File | Where-Object { $_.FullName -notlike '*\Reports\*' } | ForEach-Object {
        $rel = $_.FullName.Substring($Root.Length).TrimStart('\')
        $dst = Join-Path $Tree $rel
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
        Copy-Item -LiteralPath $_.FullName -Destination $dst -Force
    }
}
$Package = Join-Path $Tree 'healthcheck'
Write-Output ("Copy: {0}" -f $Tree)

$fails = 0; $passes = 0
$saved = @{}
function Read-All([string]$rel) { [IO.File]::ReadAllText((Join-Path $Tree $rel), [Text.Encoding]::UTF8) }
function Write-All([string]$rel, [string]$text) {
    # The byte-order mark is part of the file: Windows PowerShell reads a script without one in the machine's ANSI code
    # page, which turns the zh-TW strings into something that no longer parses - a broken copy, not a mutation.
    $path = Join-Path $Tree $rel
    if (-not $saved.ContainsKey($rel)) { $saved[$rel] = [IO.File]::ReadAllBytes($path) }
    $head = $saved[$rel]
    $hadBom = ($head.Length -ge 3) -and ($head[0] -eq 0xEF) -and ($head[1] -eq 0xBB) -and ($head[2] -eq 0xBF)
    [IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($hadBom)))
}
function Restore-All {
    foreach ($rel in @($saved.Keys)) { [IO.File]::WriteAllBytes((Join-Path $Tree $rel), $saved[$rel]) }
    $script:saved = @{}
}
function Invoke-DocFacts([string[]]$extra) {
    $ErrorActionPreference = 'Continue'   # a crash in the checker is a result to report, not the end of this run
    $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'doc_facts.ps1'), '-PackageDir', $Package, '-RepoRoot', $Tree) + $extra
    $out = @(& $PsExe @args 2>&1 | ForEach-Object { [string]$_ })
    return @{ Output = $out; ExitCode = $LASTEXITCODE }
}
function Assert-Clean([string]$name, [string[]]$extra) {
    $r = Invoke-DocFacts $extra
    $summary = [string]@($r.Output | Where-Object { $_ -match '^Summary:' })[-1]
    $ok = ($r.ExitCode -eq 0) -and ($summary -match '^Summary:\s+\d+ passed, 0 failed')
    if ($ok) { $script:passes++; Write-Output "[PASS] $name -> $summary" }
    else { $script:fails++; Write-Output ("[FAIL] $name -> exit {0}; {1}" -f $r.ExitCode, (@($r.Output | Where-Object { $_ -like '`[FAIL`]*' }) -join ' | ')) }
}
function Assert-Catches([string]$name, [string]$expectedCheck, [scriptblock]$mutation) {
    & $mutation
    $r = Invoke-DocFacts @()
    Restore-All
    $failed = @($r.Output | Where-Object { $_ -like '`[FAIL`]*' })
    $hit = @($failed | Where-Object { $_ -match ('^\[FAIL\]\s+' + [regex]::Escape($expectedCheck)) })
    $ok = ($r.ExitCode -gt 0) -and ($hit.Count -gt 0)
    if ($ok) { $script:passes++; Write-Output ("[PASS] {0} -> {1} caught it: {2}" -f $name, $expectedCheck, ($hit[0] -replace '^\[FAIL\]\s+', '')) }
    else { $script:fails++; Write-Output ("[FAIL] {0} -> expected {1} to fail; got: {2}" -f $name, $expectedCheck, $(if ($failed.Count) { $failed -join ' | ' } else { 'nothing failed' })) }
}

$EnScript = 'healthcheck\en-US\NetworkHealthCheck.ps1'
$ZhScript = 'healthcheck\zh-TW\NetworkHealthCheck.ps1'
$EnConfig = 'healthcheck\en-US\NetworkHealthCheck.config.json'
$ZhConfig = 'healthcheck\zh-TW\NetworkHealthCheck.config.json'
$EnIt = 'healthcheck\en-US\NetworkHealthCheck_IT_Deployment_Manual_en-US.md'
$ZhIt = 'healthcheck\zh-TW\NetworkHealthCheck_IT_Deployment_Manual_zh-TW.md'
$EnItHtml = 'healthcheck\en-US\NetworkHealthCheck_IT_Deployment_Manual_en-US.html'
$EnUser = 'healthcheck\en-US\NetworkHealthCheck_User_Manual_en-US.md'
$Guide = 'healthcheck\docs\NetworkHealthCheck_Technical_Guide_en-US.md'
$Field = 'sop\support-engineer-field-manual.md'
$FieldHtml = 'sop\support-engineer-field-manual.html'

# 1 - the control: the copy as it stands has to pass, in both scopes.
Assert-Clean 'the untouched copy passes' @()
Assert-Clean 'the untouched copy passes with -PackageOnly' @('-PackageOnly')

# 2 - the two languages drift apart
Assert-Catches 'a result tag added to one script only' 'A1' {
    # A real call, not a comment: the step reads the -Tag arguments off the AST, so a commented-out one is invisible
    # to it - which is right, and is what this case measured until the AST replaced the regular expression.
    Write-All $EnScript ((Read-All $EnScript) + "`r`nAdd-CheckResult -Check `"x`" -Tag `"phantom-row`" | Out-Null`r`n")
}
Assert-Catches 'a fingerprint key renamed in one script' 'A2' {
    Write-All $ZhScript ((Read-All $ZhScript) -replace '\$key = "quality"', '$key = "quality-2"')
}
Assert-Catches 'a configuration key added to one file only' 'A4' {
    Write-All $EnConfig ((Read-All $EnConfig) -replace '"OrganizationName"', '"OneSidedKey": 1, "OrganizationName"')
}
Assert-Catches 'a fingerprint the switch has no title for' 'A5' {
    foreach ($s in @($EnScript, $ZhScript)) { Write-All $s ((Read-All $s) -replace '\$key = "mixed"', '$key = "mixed-new"') }
}

# 3 - the configuration file and the IT deployment manual
Assert-Catches 'a configuration key nobody documented' 'B1' {
    foreach ($c in @($EnConfig, $ZhConfig)) { Write-All $c ((Read-All $c) -replace '"OrganizationName"', '"UndocumentedSetting": 1, "OrganizationName"') }
}
Assert-Catches 'a container the manual never names' 'B2' {
    foreach ($c in @($EnConfig, $ZhConfig)) { Write-All $c ((Read-All $c) -replace '"Checks"', '"ChecksRenamed"') }
}
Assert-Catches 'a key in an example that does not exist' 'B3' {
    Write-All $EnIt ((Read-All $EnIt) + "`r`n```````json`r`n{ `"Tests`": { `"NotAKeyAtAll`": 1 } }`r`n```````r`n")
}

# 4 - the fingerprint keys and the tags
Assert-Catches 'a fingerprint the guide stopped naming' 'C1' {
    Write-All $Guide ((Read-All $Guide) -replace 'gateway-up-internet-dead', 'gateway-up-internet-gone')
}
Assert-Catches 'an internal-tag waiver the script no longer has' 'D1' {
    Write-All $EnScript ((Read-All $EnScript) -replace 'Tag "step-error"', 'Tag "step-failure"')
}
Assert-Catches 'a documented tag dropped from the field manual' 'D2' {
    Write-All $Field ((Read-All $Field) -replace '`traceroute`', '`traceroute-row`')
}

# 5 - the names and the numbers a document sends people to
Assert-Catches 'a launcher name that is not in the package' 'E1' {
    Write-All $EnIt ((Read-All $EnIt) + "`r`nRun ``Start-NetworkCheck-Nowhere.cmd`` from the package root.`r`n")
}
Assert-Catches 'a section number that does not exist' 'F1' {
    Write-All $EnIt ((Read-All $EnIt) + "`r`nThe rest is in section 99.4 below.`r`n")
}

# 5b - the forms round 1 of PR #23 found unguarded: a tag reached through a variable, a section reference in the
# zh-TW spelling, the second number of a compound reference, and a file name that carries its folder.
Assert-Catches 'a tag reached through a variable, drifting in one script' 'A1' {
    Write-All $EnScript ((Read-All $EnScript) -replace '\$pingTag = "ping-target"', '$pingTag = "ping-probe"')
}
Assert-Catches 'a -Tag argument that resolves to nothing' 'A6' {
    Write-All $EnScript ((Read-All $EnScript) + "`r`nAdd-CheckResult -Check `"x`" -Tag `$tagFromNowhere | Out-Null`r`n")
}
Assert-Catches 'a section reference in the zh-TW spelling' 'F1' {
    # "<di> 99 <jie>" - the two characters that bracket a section number in Chinese, built from their code points so
    # that this file stays ASCII and needs no byte-order mark.
    $reference = [string][char]0x7B2C + ' 99 ' + [char]0x7BC0
    Write-All $ZhIt ((Read-All $ZhIt) + "`r`n" + $reference + "`r`n")
}
Assert-Catches 'the second number of a compound reference' 'F1' {
    Write-All $EnIt ((Read-All $EnIt) + "`r`nBoth are covered, in sections 3.1 and 97.`r`n")
}
Assert-Catches 'a launcher name that carries its folder' 'E1' {
    Write-All $EnIt ((Read-All $EnIt) + "`r`nRun ``en-US\Start-NetworkCheck-Nowhere.cmd`` from the package root.`r`n")
}
Assert-Catches 'a program the package does not carry' 'E1' {
    Write-All $EnIt ((Read-All $EnIt) + "`r`nThe validator is ``tools\validate_release_missing.py``.`r`n")
}

# 5c - the forms round 2 of PR #23 found unguarded: a tag variable that is also assigned something computed, the
# zh-TW compound that repeats its marker, and an executable inside a quoted command line.
Assert-Catches 'a tag variable that is also assigned a computed value' 'A6' {
    Write-All $EnScript ((Read-All $EnScript) + "`r`n`$pingTag = Get-CustomTag`r`n")
}
Assert-Catches 'the first number of a zh-TW compound reference' 'F1' {
    # "<di> 98 <yu><di> 3 <jie>" - the compound form the zh-TW manuals actually use, with the first number wrong.
    $reference = [string][char]0x7B2C + ' 98 ' + [char]0x8207 + [char]0x7B2C + ' 3 ' + [char]0x7BC0
    Write-All $ZhIt ((Read-All $ZhIt) + "`r`n" + $reference + "`r`n")
}
Assert-Catches 'an executable misspelt inside a command span' 'E1' {
    Write-All $EnIt ((Read-All $EnIt) + "`r`nRun ``powershell -NoProfile -File NetworkHealthCheckX.ps1 -ConsoleOnly`` to see it.`r`n")
}

# 5d - the forms round 3 of PR #23 found unguarded: an exit code reached through a variable, a tag dropped from the
# page and not from the markdown, a path read from the document's own folder, and the section-sign form.
Assert-Catches 'an exit code changed in one language' 'A3' {
    Write-All $ZhScript ((Read-All $ZhScript) -replace '\$exitCode = 1', '$exitCode = 2')
}
Assert-Catches 'what one script exits with, where it is not a literal' 'A3b' {
    Write-All $ZhScript ((Read-All $ZhScript) -replace 'Start-ConsoleMode', 'Start-OtherMode')
}
Assert-Catches 'a tag dropped from the field manual page only' 'D2' {
    Write-All $FieldHtml ((Read-All $FieldHtml) -replace '<code>routes</code>', '<code>routes-x</code>')
}
Assert-Catches 'a parent-relative path that resolves to nothing' 'E1' {
    Write-All $Guide ((Read-All $Guide) + "`r`nThe record is ``../VALIDATIONX.md``.`r`n")
}
Assert-Catches 'a section-sign reference that does not exist' 'F1' {
    # The filler keeps the reference clear of the closing list, which names other documents: a reference within 40
    # characters of one of those names is read as pointing at them, and would be skipped for the right reason.
    Write-All $Field ((Read-All $Field) + "`r`n" + ('-' * 60) + "`r`nSee " + [char]0x00A7 + "99 for the rest.`r`n")
}

# 5e - the forms round 4 of PR #23 found unguarded: the code a called function returns, an executable inside a fenced
# block, a link destination, and a reference on an HTML page.
Assert-Catches 'a code the console mode returns, changed in one language' 'A3' {
    Write-All $ZhScript ((Read-All $ZhScript) -replace 'return 1', 'return 2')
}
Assert-Catches 'an executable misspelt in a fenced command block' 'E1' {
    Write-All $EnIt ((Read-All $EnIt) + "`r`n``````" + "text`r`npowershell -NoProfile -File NetworkHealthCheckY.ps1 -ConsoleOnly`r`n" + "``````" + "`r`n")
}
Assert-Catches 'a link that resolves to nothing' 'E2' {
    Write-All $Field ((Read-All $Field) + "`r`nSee [the SOP](network-troubleshooting-sopX.md).`r`n")
}
Assert-Catches 'a section reference on an HTML page' 'F1' {
    Write-All $EnItHtml ((Read-All $EnItHtml) -replace '</body>', '<p>The rest is in section 97.</p></body>')
}

# 5f - the forms round 5 of PR #23 found unguarded: an exit code the package cannot produce, a link that resolves
# somewhere other than beside its document, a dot-relative program name, and a single-quoted href.
Assert-Catches 'an exit code no part of the package produces' 'A7' {
    Write-All $EnUser ((Read-All $EnUser) + "`r`nThe window closes with exit code 7 when that happens.`r`n")
}
Assert-Catches 'a link to a file that exists somewhere else in the package' 'E2' {
    Write-All $Field ((Read-All $Field) + "`r`nSee [the guide](NetworkHealthCheck_Technical_Guide_en-US.md).`r`n")
}
Assert-Catches 'a dot-relative program name that does not exist' 'E1' {
    Write-All $EnIt ((Read-All $EnIt) + "`r`n``````" + "text`r`npowershell -NoProfile -File .\NetworkHealthCheckZ.ps1`r`n" + "``````" + "`r`n")
}
Assert-Catches 'a single-quoted href that resolves to nothing' 'E2' {
    Write-All $EnItHtml ((Read-All $EnItHtml) -replace '</body>', "<p><a href='missing-page.html'>more</a></p></body>")
}

# 6 - and the control again, to prove every mutation was put back
Assert-Clean 'the copy is clean again after every mutation' @()

Write-Output ("Summary: {0} passed, {1} failed" -f $passes, $fails)
if ($fails -eq 0) { Write-Output 'ALL SELF-TESTS OK' }
exit $fails
