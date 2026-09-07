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

# The copy: everything the step reads, without the report folders, which it never opens.
New-Item -ItemType Directory -Force -Path $Tree | Out-Null
foreach ($sub in @('healthcheck', 'sop')) {
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
$Guide = 'healthcheck\docs\NetworkHealthCheck_Technical_Guide_en-US.md'
$Field = 'sop\support-engineer-field-manual.md'

# 1 - the control: the copy as it stands has to pass, in both scopes.
Assert-Clean 'the untouched copy passes' @()
Assert-Clean 'the untouched copy passes with -PackageOnly' @('-PackageOnly')

# 2 - the two languages drift apart
Assert-Catches 'a result tag added to one script only' 'A1' {
    Write-All $EnScript ((Read-All $EnScript) + "`r`n# Add-CheckResult -Tag `"phantom-row`"`r`n")
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

# 6 - and the control again, to prove every mutation was put back
Assert-Clean 'the copy is clean again after every mutation' @()

Write-Output ("Summary: {0} passed, {1} failed" -f $passes, $fails)
if ($fails -eq 0) { Write-Output 'ALL SELF-TESTS OK' }
exit $fails
