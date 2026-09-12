<#
.SYNOPSIS
    Runs the NetworkHealthCheck validation chain against this checkout (backlog #16).

.DESCRIPTION
    One command reproduces the chain recorded in healthcheck/VALIDATION.md: the Windows PowerShell 5.1 parser, the static
    release validator and the self-test of the two AST guards, the document facts against the program's own
    identifiers, the helper unit tests, the report-stage functional
    tests, the language-mode guard, the headless Initialize-Gui smoke test, the real-window UI Automation run of both
    entry points, the console
    acceptance runs and, on request, the release-asset round trip (build, extract, validate inside the package, open the
    extracted IT entry through the real window).

    Nothing is written into the repository: every run works on a staged copy of healthcheck/<lang>/ under -WorkDir
    (default %TEMP%\nhc-tests\<timestamp>), where each step's raw output is kept as <step>_<case>.log and the final
    table as summary.md.

.PARAMETER Steps
    Steps to run (parse, validator, guards, docfacts, unit, report, envguard, launcher, campaign, gui-headless, gui,
    acceptance, resultset, package);
    comma-separated values are accepted, and the steps always execute in the chain's own order. Default: everything
    except package. The resultset step is the negative self-check of the result-set assertion; it uses the en-US user
    report of the acceptance step, or produces one through the console launcher when that step did not run.
.PARAMETER Package
    Adds the package step (the same as listing it in -Steps).
.PARAMETER SkipGui
    Drops the real-window runs (the gui step and the window part of package) for a session without an interactive desktop.
.PARAMETER RequireHealthy
    Window and acceptance runs must also end Overall Healthy. Use it on the reference machine; on a machine with a real
    network problem the warning is the tool doing its job, so it is off by default.
.PARAMETER WorkDir
    Where staged copies, reports and logs go. Created if missing.
.PARAMETER PackageDir
    The package to run against - a folder holding en-US\ and zh-TW\. Default: the checkout's healthcheck\. An extracted
    release asset works too; Invoke-PackageAcceptance.ps1 passes one (backlog #19).
.PARAMETER Python
    The Python 3 command for the release validator and the asset builder.
.PARAMETER GuiTimeoutSeconds
    How long one real-window run may take; the IT entry samples TCP retransmissions for 125 s before it reports.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\Invoke-ValidationChain.ps1
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\Invoke-ValidationChain.ps1 -Package -RequireHealthy
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\Invoke-ValidationChain.ps1 -Steps parse,validator,guards,unit,report
#>
[CmdletBinding()]
param(
    [string[]]$Steps = @('parse', 'validator', 'guards', 'docfacts', 'unit', 'report', 'envguard', 'launcher', 'campaign', 'gui-headless', 'gui', 'acceptance', 'resultset'),
    [switch]$Package,
    [switch]$SkipGui,
    [switch]$RequireHealthy,
    [string]$WorkDir,
    [string]$PackageDir,
    [string]$Python = 'python',
    [int]$GuiTimeoutSeconds = 360
)

$ErrorActionPreference = 'Stop'
$Order = @('parse', 'validator', 'guards', 'docfacts', 'unit', 'report', 'envguard', 'launcher', 'campaign', 'gui-headless', 'gui', 'acceptance', 'resultset', 'package')
$Root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
if (-not $PackageDir) { $PackageDir = Join-Path $Root 'healthcheck' }
$PackageDir = (Resolve-Path -LiteralPath $PackageDir).Path
$Languages = @('en-US', 'zh-TW')
$PsExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$CmdExe = Join-Path $env:SystemRoot 'System32\cmd.exe'

# -File passes "a,b" as one string, so the list is split here and validated by hand.
$selected = @($Steps | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
$unknown = @($selected | Where-Object { $Order -notcontains $_ })
if ($unknown.Count) { throw ('unknown step(s): ' + ($unknown -join ', ') + '; known: ' + ($Order -join ', ')) }
if ($Package) { $selected += 'package' }
if ($SkipGui) { $selected = @($selected | Where-Object { $_ -ne 'gui' }) }
$selected = @($Order | Where-Object { $selected -contains $_ })
if (-not $selected.Count) { throw 'no step selected' }

if (-not $WorkDir) { $WorkDir = Join-Path $env:TEMP ('nhc-tests\' + (Get-Date -Format 'yyyyMMdd_HHmmss')) }
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
$WorkDir = (Resolve-Path -LiteralPath $WorkDir).Path
$Results = New-Object System.Collections.ArrayList
$ChainStarted = Get-Date
$script:UserReportPath = $null   # the en-US user report the acceptance step produced in this invocation, for the resultset step
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

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
function Invoke-TestScript {
    # Runs one of the scripts in this folder in a fresh Windows PowerShell 5.1 process.
    param([string]$Name, [string[]]$ArgumentList, [string]$LogName)
    Invoke-Native -FilePath $PsExe -ArgumentList (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot $Name)) + $ArgumentList) -LogName $LogName
}
function Test-DocumentedTotal([string]$Summary, [string]$RowPattern, [string]$ValuePattern) {
    # A step's own row in README.md advertises how many cases it runs, and in this pull request alone those
    # numbers went stale four times - the result-set one in rounds 4, 10 and 15, the unit one in round 17 - and a
    # reader found every one of them. The only honest source is the run that just happened, so each step that
    # reports a total compares it here and fails when the two disagree. Returns '' when they agree, or the
    # sentence that says how they differ.
    # -Encoding UTF8, because README.md has no byte-order mark and Windows PowerShell 5.1 would otherwise read it
    # in the machine's ANSI codepage - where the multiplication sign in '353 x 2' is two characters and the
    # pattern below silently matches nothing. The first draft of this guard failed for exactly that reason, which
    # looks like a stale total and is not one.
    $row = @(Get-Content -LiteralPath (Join-Path $PSScriptRoot 'README.md') -Encoding UTF8 | Where-Object { $_ -match $RowPattern }) -join ' '
    $all = @([regex]::Matches($row, $ValuePattern))
    if ($all.Count -eq 0) { return ('README.md has no total on the row matching {0}' -f $RowPattern) }
    $m = $all[$all.Count - 1]
    $documented = $m.Groups[1].Value
    # A pair, where the pattern asks for one: 'N / N' has to be the same number twice.
    if ($m.Groups.Count -gt 2 -and $m.Groups[2].Success -and $m.Groups[2].Value -ne $documented) {
        return ('README.md advertises {0}, which is not one number twice' -f $m.Value)
    }
    $ran = [regex]::Match([string]$Summary, 'Summary: (\d+) passed')
    if (-not $ran.Success) { return 'this run reported no total to compare with README.md' }
    if ($documented -ne $ran.Groups[1].Value) { return ('README.md advertises {0}' -f $m.Value) }
    return ''
}
function Invoke-Case {
    # Runs one case of a step, records PASS / FAIL with its detail and duration, and prints the line.
    param([string]$Step, [string]$Case, [scriptblock]$Body)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try { $r = @(& $Body | Where-Object { $_ -is [hashtable] })[-1] }
    catch { $r = @{ Passed = $false; Detail = ('exception: ' + $_.Exception.Message) } }
    if ($null -eq $r) { $r = @{ Passed = $false; Detail = 'the case returned no result' } }
    $sw.Stop()
    $entry = [pscustomobject]@{
        Step = $Step; Case = $Case
        Result = $(if ($r.Passed) { 'PASS' } else { 'FAIL' })
        Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        Detail = [string]$r.Detail
    }
    [void]$Results.Add($entry)
    $color = $(if ($r.Passed) { 'Green' } else { 'Red' })
    Write-Host ('[{0}] {1} / {2}: {3} ({4} s)' -f $entry.Result, $Step, $Case, $entry.Detail, $entry.Seconds) -ForegroundColor $color
}
function Get-SummaryLine([string[]]$Lines) { [string]@($Lines | Where-Object { $_ -match '^Summary:' } | Select-Object -Last 1)[0] }
function Test-SummaryClean([string]$Line) { ($Line -match '^Summary:\s+(\d+) passed, (\d+) failed') -and ([int]$Matches[1] -gt 0) -and ([int]$Matches[2] -eq 0) }
function Read-ToolVersion {
    foreach ($line in [IO.File]::ReadLines((Join-Path $PackageDir 'en-US\NetworkHealthCheck.ps1'))) {
        if ($line -match '^\$script:ToolVersion\s*=\s*"([^"]+)"') { return $Matches[1] }
    }
    throw 'ToolVersion not found in en-US/NetworkHealthCheck.ps1'
}
function New-StagedCopy {
    # A copy of healthcheck/<lang>/ (files only - never Reports/) under the work dir, refreshed from this checkout on every
    # call so that a reused work dir never runs an older revision (its Reports/ folder is kept; reports are selected by
    # start time). -WidenSampling raises PingCount to 30 and RetransmissionSampleSeconds to 125 in the copied
    # configuration, above the IT panel's default spinner ranges: the 1.2.1 fix is that an untouched Start keeps
    # those values instead of clamping them. PingCountMaximum is raised with the starting count and not because the
    # sampling wants it - since 1.2.10 the two are an ordered pair, and a ceiling left below the starting count is a
    # Configuration Thresholds warning in every staged run (backlog #51).
    param([string]$Lang, [string]$Name, [switch]$WidenSampling)
    $dst = Join-Path $WorkDir ('stage\' + $Name + '\' + $Lang)
    New-Item -ItemType Directory -Force -Path $dst | Out-Null
    $stale = Join-Path $dst 'LauncherError.txt'
    if (Test-Path -LiteralPath $stale) { Remove-Item -LiteralPath $stale -Force }
    Get-ChildItem -LiteralPath (Join-Path $PackageDir $Lang) -File | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $dst -Force }
    if ($WidenSampling) {
        $cfg = Join-Path $dst 'NetworkHealthCheck.config.json'
        $text = [IO.File]::ReadAllText($cfg)
        $text = [regex]::Replace($text, '"PingCount"\s*:\s*\d+', '"PingCount": 30')
        $text = [regex]::Replace($text, '"PingCountMaximum"\s*:\s*\d+', '"PingCountMaximum": 30')
        $text = [regex]::Replace($text, '"RetransmissionSampleSeconds"\s*:\s*\d+', '"RetransmissionSampleSeconds": 125')
        [IO.File]::WriteAllText($cfg, $text, (New-Object System.Text.UTF8Encoding($true)))
    }
    return $dst
}
function Read-Config([string]$Dir) { Get-Content -LiteralPath (Join-Path $Dir 'NetworkHealthCheck.config.json') -Raw -Encoding UTF8 | ConvertFrom-Json }
function Get-ConfigSampling([string]$Dir) {
    $c = Read-Config $Dir
    return @{ PingCount = [int]$c.Tests.PingCount; SampleSeconds = [int]$c.Tests.RetransmissionSampleSeconds }
}
function Get-Count($Value) { if ($null -eq $Value) { return 0 }; return @($Value).Count }
function Test-TrueFlag($Value) { return (($Value -is [bool]) -and $Value) }   # the script's Test-IsTrueFlag: only a boolean true enables a check
function Get-CimOrWmiInstance([string]$ClassName) {
    # The script's own selection: Get-CimInstance when it exists, Get-WmiObject otherwise, and - like the script - an
    # exception when neither does.
    if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) { return @(Get-CimInstance -ClassName $ClassName -OperationTimeoutSec 8 -ErrorAction Stop) }
    if (Get-Command Get-WmiObject -ErrorAction SilentlyContinue) { return @(Get-WmiObject -Class $ClassName -ErrorAction Stop) }
    throw 'No usable CIM/WMI command is available on this system.'
}
function Add-PrimaryFacts([hashtable]$Facts, [object[]]$Adapters) {
    # Get-PrimaryAdapters: the adapters with an IPv4 address and a gateway, or all with an IPv4 address when none has a
    # gateway; the AUTO_GATEWAY and AUTO_DNS placeholders resolve to their distinct gateways and DNS servers.
    $withIPv4 = @($Adapters | Where-Object { $_.IPv4 -gt 0 })
    $primary = @($withIPv4 | Where-Object { @($_.Gateways).Count -gt 0 })
    if ($primary.Count -eq 0) { $primary = $withIPv4 }
    $Facts.ConnectedAdapters = @($Adapters).Count
    $Facts.Gateways = @(@($primary | ForEach-Object { @($_.Gateways) }) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Sort-Object -Unique)
    $Facts.DnsServers = @(@($primary | ForEach-Object { @($_.Dns) }) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Sort-Object -Unique)
    # The primary adapters as Test-NearEndTargetPlacement reads them - IPv4 addresses, address/prefix subnets and
    # gateways - so that the oracle can place a configured near-end target with the tool's own function rather than a
    # copy of it (backlog #60); an adapter whose prefix is unknown contributes no subnet, as in the tool.
    $Facts.PrimaryAdapters = @($primary | ForEach-Object { [pscustomobject]@{ IPv4Addresses = @($_.Addresses); IPv4WithPrefix = @($_.Subnets); Gateways = @($_.Gateways) } })
}
function Test-ConfiguredTcpTarget($Target) {
    # The host is a name like any other since round 8: a valid port with 'http://example.com' beside it used to
    # reach TcpClient.BeginConnect and be recorded as a failed connection.
    $hostName = [string](Get-Value $Target 'Host')
    if (-not (Test-HostNameSyntax $hostName)) { return $false }
    $port = ConvertTo-IntSafe (Get-Value $Target 'Port') 0
    return ($port -ge 1 -and $port -le 65535)
}
function Get-UnusablePingExtraRows($Config) {
    # The second row a required, unusable ping address adds. The address itself is already counted once by the
    # expression above, which counts every configured entry.
    $rows = 0
    foreach ($target in @($Config.Tests.PingTargets)) {
        if ($null -eq $target) { continue }
        $address = [string](Get-Value $target 'Address')
        if (Test-ConfiguredPingAddress $address) { continue }
        $required = $false
        $value = Get-Value $target 'Required'
        if ($null -ne $value) { $required = [bool]$value }
        if ($required) { $rows += 1 }
    }
    return $rows
}
function Test-ConfiguredDnsTarget($Target) {
    # A bare string is the documented short form and is treated as required; an object carries its name under Host.
    # Asking a string for a Host property called every one of them unusable (PR #41, round 2). Since round 6 the
    # name must also be one a resolver could be asked, which is the tool's own rule.
    $hostName = if ($Target -is [string]) { [string]$Target } else { [string](Get-Value $Target 'Host') }
    if ([string]::IsNullOrWhiteSpace($hostName)) { return $false }
    return (Test-HostNameSyntax $hostName)
}
function Test-ConfiguredDnsRequired($Target) {
    if ($Target -is [string]) { return $true }
    $value = Get-Value $Target 'Required'
    if ($null -eq $value) { return $true }
    return [bool]$value
}
function Test-ConfiguredHttpTarget($Target) {
    # The tool's own rule, on the URL this target carries.
    return (Test-HttpTargetSyntax ([string](Get-Value $Target 'Url')))
}
function Test-ConfiguredPingAddress([string]$Address) {
    # The tool's own rule. This was a character-for-character copy of it until PR #41 round 3, which is a copy that
    # would have kept agreeing with the old rule after the tool's changed.
    return (Test-PingTargetSyntax $Address)
}
function Get-TargetRowCount($Targets, [scriptblock]$IsUsable, [bool]$RequiredByDefault) {
    # One row per target, as before - and two for a target the run cannot test that was required: the input notice
    # that names the mistake, weightless, plus the weighted row saying the required check did not run (backlog #39).
    $rows = 0
    foreach ($target in @($Targets)) {
        if ($null -eq $target) { continue }
        $rows += 1
        if (-not (& $IsUsable $target)) {
            $required = $RequiredByDefault
            if ($target -is [string]) {
                $required = $RequiredByDefault
            }
            else {
                $value = Get-Value $target 'Required'
                if ($null -ne $value) { $required = [bool]$value }
            }
            if ($required) { $rows += 1 }
        }
    }
    return $rows
}
function Get-Value($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}
function Get-ConfigConverterSource([string]$ScriptPath) {
    # Five findings of PR #41 round 3 were one cause: this oracle re-implemented the tool's value conversion by hand,
    # and "4.0" is a whole number to the tool but not to Int32.TryParse, an explicit null becomes 0 rather than being
    # skipped, and a whole-valued double outside Int32 is not a whole number at all. The predicates below - which rows
    # a configuration produces - stay this file's own; how a value is *read* now comes from the package being tested.
    # The source is returned rather than run here: Invoke-Expression inside a function defines those functions in that
    # function's own scope, where they vanish on return, so the caller evaluates them at its scope instead. They are
    # not marking their own homework - unit_tests.ps1 asserts every one of them directly, on fixed inputs, in both
    # languages.
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path -LiteralPath $ScriptPath).Path, [ref]$tokens, [ref]$errors)
    $wanted = 'ConvertTo-DoubleSafe', 'ConvertTo-IntSafe', 'Test-IsNumericValue', 'Test-IsWholeNumber', 'Test-IsValidIPv4Address', 'Test-PingTargetSyntax', 'Test-HttpTargetSyntax', 'Test-HostNameSyntax', 'Test-IPv4InCidr', 'Resolve-PingTargets', 'Get-CanonicalIPv4Text', 'Test-NearEndAddressSyntax', 'Test-NearEndTargetPlacement', 'ConvertTo-SafeString', 'Get-RouteSelection'
    $found = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $wanted -contains $n.Name }, $true))
    $loaded = @($found | ForEach-Object { $_.Name })
    $missing = @($wanted | Where-Object { $loaded -notcontains $_ })
    if ($missing.Count -gt 0) { throw ("The package at {0} is missing: {1}" -f $ScriptPath, ($missing -join ', ')) }
    return @($found | ForEach-Object { $_.Extent.Text })
}
function Test-UsableIPAddress([string]$Value) {
    $parsed = $null
    return [System.Net.IPAddress]::TryParse([string]$Value, [ref]$parsed)
}
function Get-ConfigRowCount($Config, $Options, [hashtable]$Overrides) {
    # Test-ConfigurationSemantics writes up to four rows out of four lists, and the PASS row appears only when all
    # four are empty (backlog #39, PR #41 round 1): a configuration whose only problem is an invalid target has no
    # validation row at all, and threshold and option problems together produce two rows rather than one. The four
    # predicates are reproduced here in the order the script applies them.
    # Blank entries are skipped by the product in three of these loops, and prefix lengths are read through
    # ConvertTo-IntSafe with -1 as the default, so a blank one is invalid there (PR #41, round 3).
    # Set-RunOptions replaces three scalars in the effective configuration before Test-ConfigurationSemantics
    # reads it, and only when the switch is greater than zero, so a file value the product would warn about is
    # not warned about when a switch replaced it (PR #41, round 7). The report cannot answer this on its own,
    # because RunOptions carries the sanitised value ([math]::Max(1, ...)) and not what the switch supplied, so
    # the case states what it passed. Round 7 read those from $Expect itself, which was wrong for a window run:
    # Invoke-WindowRun fills PingCount and SampleSeconds from the folder's configuration to assert against, and a
    # user-entry run passes no switches at all (round 9). $Expect['Overrides'] is only what was really given.
    $overridden = @{}
    if ($null -ne $Overrides) {
        foreach ($pair in @(@('PingCount', 'PingCount'), @('PingCountMaximum', 'PingCountMaximum'), @('RetransmissionSampleSeconds', 'SampleSeconds'), @('TracerouteHops', 'TracerouteHops'))) {
            if ($Overrides.ContainsKey($pair[1]) -and (ConvertTo-IntSafe $Overrides[$pair[1]] 0) -gt 0) { $overridden[$pair[0]] = ConvertTo-IntSafe $Overrides[$pair[1]] 0 }
        }
    }

    $standards = 0
    $expected = $Config.Expected
    foreach ($ip in @(Get-Value $expected 'AllowedIPv4Addresses')) { if (-not [string]::IsNullOrWhiteSpace([string]$ip) -and -not (Test-IsValidIPv4Address ([string]$ip))) { $standards += 1 } }
    foreach ($cidr in @(Get-Value $expected 'AllowedIPv4Cidrs')) {
        if ([string]::IsNullOrWhiteSpace([string]$cidr)) { continue }
        $parts = ([string]$cidr).Split('/')
        $valid = ($parts.Count -eq 2) -and (Test-IsValidIPv4Address $parts[0])
        if ($valid) {
            $prefix = ConvertTo-IntSafe $parts[1] -1
            $valid = ($prefix -ge 0 -and $prefix -le 32)
        }
        if (-not $valid) { $standards += 1 }
    }
    foreach ($prefixValue in @(Get-Value $expected 'AllowedPrefixLengths')) {
        $prefix = ConvertTo-IntSafe $prefixValue -1
        if ($prefix -lt 0 -or $prefix -gt 32) { $standards += 1 }
    }
    foreach ($gateway in @(Get-Value $expected 'AllowedDefaultGateways')) { if (-not [string]::IsNullOrWhiteSpace([string]$gateway) -and -not (Test-IsValidIPv4Address ([string]$gateway))) { $standards += 1 } }
    foreach ($dns in @(Get-Value $expected 'RequiredDnsServers')) {
        if ([string]::IsNullOrWhiteSpace([string]$dns)) { continue }
        if (-not (Test-UsableIPAddress $dns)) { $standards += 1 }
    }
    $dhcp = Get-Value $expected 'DhcpEnabled'
    if ($null -ne $dhcp -and -not ($dhcp -is [bool])) { $standards += 1 }

    # Every threshold the script validates, with the two rules it applies: a value that is not a number, and a count
    # threshold that is not a whole number. The adapter deltas are thresholds too, and the first draft of this oracle
    # left all four out (PR #41, round 2).
    $thresholds = 0
    foreach ($name in @('PingCount', 'PingCountMaximum', 'PingTimeoutMs', 'DnsTimeoutMs', 'TcpTimeoutMs', 'HttpTimeoutMs', 'RetransmissionSampleSeconds')) {
        $value = Get-Value $Config.Tests $name
        if ($overridden.ContainsKey($name)) { $value = $overridden[$name] }
        # The product's two branches, in its order: a present value that is not a whole number, or - and this is the
        # branch an explicit null reaches, because ConvertTo-IntSafe hands back 0 - a value of zero or less.
        if ($null -ne $value -and -not (Test-IsWholeNumber $value)) { $thresholds += 1 }
        elseif ((ConvertTo-IntSafe $value 0) -le 0) { $thresholds += 1 }
    }
    $limits = $Config.Thresholds
    $countThresholds = @('TcpRetransmissionCriticalCount', 'MinimumTcpSegmentsForRate', 'MinimumTcpRetransmissionsForVerdict', 'AdapterErrorWarningDelta', 'AdapterErrorCriticalDelta', 'AdapterDiscardWarningDelta', 'AdapterDiscardCriticalDelta')
    foreach ($name in @('PacketLossWarningPercent', 'PacketLossCriticalPercent', 'LatencyWarningMs', 'LatencyCriticalMs', 'TcpRetransmissionWarningPercent', 'TcpRetransmissionCriticalPercent') + $countThresholds) {
        $value = Get-Value $limits $name
        if ($null -eq $value) { continue }
        # Round 3 replaced the hand-rolled conversion everywhere except here, and here is where the culture shows:
        # the product's Test-IsNumericValue parses a string in invariant culture, so "2,5" is not a number to the tool
        # while this machine's own TryParse reads it as twenty-five (PR #41, round 4).
        if (-not (Test-IsNumericValue $value)) { $thresholds += 1 }
        elseif (($countThresholds -contains $name) -and -not (Test-IsWholeNumber $value)) { $thresholds += 1 }
        # A count threshold is a number of things and a negative one counts nothing; until 1.2.10 it threw at the
        # unsigned cast instead of being reported (PR #49, round 1).
        elseif (($countThresholds -contains $name) -and (ConvertTo-DoubleSafe $value 0) -lt 0) { $thresholds += 1 }
    }
    # A warning threshold below zero, or a critical one below its warning, is one row per pair - read through
    # ConvertTo-DoubleSafe with the product's own defaults, which is what the product falls back to for a value it
    # cannot read.
    foreach ($pair in @(@('PacketLossWarningPercent', 'PacketLossCriticalPercent', 5, 20), @('LatencyWarningMs', 'LatencyCriticalMs', 100, 250), @('TcpRetransmissionWarningPercent', 'TcpRetransmissionCriticalPercent', 2, 5))) {
        $warning = ConvertTo-DoubleSafe (Get-Value $limits $pair[0]) $pair[2]
        $critical = ConvertTo-DoubleSafe (Get-Value $limits $pair[1]) $pair[3]
        if ($warning -lt 0 -or $critical -lt $warning) { $thresholds += 1 }
    }

    # backlog #51: the two ping counts are an ordered pair, checked in the same row as the threshold pairs. Both are
    # read after the switches, because Set-RunOptions writes them into the effective configuration before
    # Test-ConfigurationSemantics ever sees it.
    $startCount = ConvertTo-IntSafe $(if ($overridden.ContainsKey('PingCount')) { $overridden['PingCount'] } else { Get-Value $Config.Tests 'PingCount' }) 4
    $ceilingCount = ConvertTo-IntSafe $(if ($overridden.ContainsKey('PingCountMaximum')) { $overridden['PingCountMaximum'] } else { Get-Value $Config.Tests 'PingCountMaximum' }) 21
    if ($ceilingCount -lt $startCount) { $thresholds += 1 }

    $badTargets = 0
    foreach ($target in @($Config.Tests.TcpTargets)) { if ($null -ne $target -and -not (Test-ConfiguredTcpTarget $target)) { $badTargets += 1 } }
    foreach ($target in @($Config.Tests.HttpTargets)) { if ($null -ne $target -and -not (Test-ConfiguredHttpTarget $target)) { $badTargets += 1 } }
    foreach ($target in @($Config.Tests.DnsNames)) { if ($null -ne $target -and -not (Test-ConfiguredDnsTarget $target)) { $badTargets += 1 } }
    foreach ($target in @($Config.Tests.PingTargets)) { if ($null -ne $target -and -not (Test-ConfiguredPingAddress ([string](Get-Value $target 'Address')))) { $badTargets += 1 } }
    # The near-end target (backlog #60): a non-blank address that is not dotted-decimal IPv4, or a blank address on an
    # entry marked required, is a Configured Targets finding (PR #51, rounds 2 and 3); blank and optional is the
    # shipped, disabled state.
    $nearEndEntry = Get-Value $Config.Tests 'NearEndTarget'
    if ($null -ne $nearEndEntry) {
        $nearEndValue = ([string](Get-Value $nearEndEntry 'Address')).Trim()
        if (-not [string]::IsNullOrWhiteSpace($nearEndValue)) { if (-not (Test-NearEndAddressSyntax $nearEndValue)) { $badTargets += 1 } }
        elseif (Test-TrueFlag (Get-Value $nearEndEntry 'Required')) { $badTargets += 1 }
    }
    # Set-RunOptions appends the switch targets to the effective configuration before Test-ConfigurationSemantics
    # reads it, so an unusable -PingTarget, -DnsName or -HttpUrl is a Configured Targets row exactly as a
    # configured one is; this oracle read the file on disk and saw none of them (PR #41, round 6). A -TcpTarget is
    # not among them: since round 10 Test-TcpTargetSyntax judges the host as well as the shape, so the panel and
    # Set-RunOptions refuse the same values and an unusable one never reaches the configuration at all - it is a
    # dropped target, which has a row of its own elsewhere in this table.
    if ($null -ne $Options) {
        $extra = Get-Value $Options 'ExtraTargets'
        foreach ($value in @(Get-Value $extra 'Ping')) { if (-not (Test-ConfiguredPingAddress ([string]$value))) { $badTargets += 1 } }
        foreach ($value in @(Get-Value $extra 'Dns')) { if (-not (Test-HostNameSyntax ([string]$value))) { $badTargets += 1 } }
        foreach ($value in @(Get-Value $extra 'Http')) { if (-not (Test-HttpTargetSyntax ([string]$value))) { $badTargets += 1 } }
    }

    $options = 0
    # -NoWifi and -NoTraceroute write a real boolean into the effective configuration before it is validated, so
    # they silence a warning about an invalid file value rather than adding one (PR #41, round 8 - round 7 said
    # these needed nothing, which was true only when the file value was already valid).
    $flagOverridden = @{}
    if ($null -ne $Overrides) {
        if ($Overrides['NoWifi'] -eq $true) { $flagOverridden['WifiRf'] = $true }
        if ($Overrides['NoTraceroute'] -eq $true) { $flagOverridden['Traceroute'] = $true }
        # The IT panel's Start passes all six controls through Get-RunOptionsFromPanel, so every flag it names is
        # a real boolean in the effective configuration whatever the file said (round 9).
        if ($Overrides['Checks'] -is [hashtable]) { foreach ($key in @($Overrides['Checks'].Keys)) { $flagOverridden[[string]$key] = $true } }
    }
    foreach ($flag in @('WifiRf', 'RouteTable', 'GatewayNeighbor', 'ProxySettings', 'Traceroute', 'DriverInfo', 'WifiRetryCounters')) {
        if ($flagOverridden.ContainsKey($flag)) { continue }
        $value = Get-Value $Config.Checks $flag
        if ($null -ne $value -and -not ($value -is [bool])) { $options += 1 }
    }
    $hops = Get-Value $Config.Checks 'TracerouteHops'
    if ($overridden.ContainsKey('TracerouteHops')) { $hops = $overridden['TracerouteHops'] }
    if ($null -ne $hops -and (-not (Test-IsWholeNumber $hops) -or (ConvertTo-IntSafe $hops 0) -lt 1 -or (ConvertTo-IntSafe $hops 0) -gt 10)) { $options += 1 }

    $rows = 0
    if ($standards -gt 0) { $rows += 1 }
    elseif ($thresholds -eq 0 -and $badTargets -eq 0 -and $options -eq 0) { $rows += 1 }
    if ($thresholds -gt 0) { $rows += 1 }
    if ($badTargets -gt 0) { $rows += 1 }
    if ($options -gt 0) { $rows += 1 }
    return $rows
}
function Get-WlanInterfaceIds {
    # The interface GUIDs in `netsh wlan show interfaces`: the value of the line whose label is GUID. Every other label
    # is localized and their order differs between Windows versions, which is why the tool's own parser reads values
    # by shape; but GUID, like the SSID label the connected-interface count already relies on, is an acronym netsh
    # does not translate, and the shape alone is not enough - a network or a profile named like a UUID is printed in
    # the same block (PR #52, round 11) and so is an adapter renamed to one, and the name comes before the GUID
    # (round 12). The label is compared before the first colon, half-width or full-width.
    param([string[]]$Lines)
    $ids = @()
    foreach ($line in @($Lines)) {
        $text = [string]$line
        $split = $text.IndexOfAny(@([char]':', [char]0xFF1A))
        if ($split -lt 1) { continue }
        if ($text.Substring(0, $split).Trim().ToUpperInvariant() -ne 'GUID') { continue }
        if ($text.Substring($split + 1) -match '([0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12})') { $ids += $matches[1].ToLowerInvariant() }
    }
    return @($ids | Sort-Object -Unique)
}
function Get-MachineFacts {
    # What the script's snapshot sees, read from the operating system the way Get-NetworkSnapshot does: first
    # Get-NetIPConfiguration (an adapter counts when it is Up and has an IPv4 or IPv6 address; the gateways are those of
    # the adapters with an IPv4 address, which is what AUTO_GATEWAY resolves to); when that cmdlet throws, the script
    # writes a data-source row and falls back to CIM, and when it is missing or returns nothing it falls back without the
    # row - CIM counts every IP-enabled Win32_NetworkAdapterConfiguration and keeps its IPv4 default gateways.
    $facts = @{ ConnectedAdapters = 0; Gateways = @(); DnsServers = @(); Source = 'NetCmdlets'; DataSourceRow = $false; SnapshotStepFailed = $false; TcpCounters = @{ TCPv4 = $false; TCPv6 = $false } }
    # Which TCP performance-counter classes can be read, the way Get-TcpCounterSnapshot reads them: an instance with the
    # SegmentsSentPersec and SegmentsRetransmittedPersec fields, and - since 1.2.8 - a second attempt when the first one
    # fails, throwing or returning nothing or returning something without those fields (backlog #38). The probe must
    # give up no sooner than the product does: one that stopped after a single failure would call a class unreadable
    # that the run reads on its retry, and Test-ResultSet would then reject a correct report (PR #40, round 10).
    # unit_tests.ps1 asserts that the shipped read still asks for two attempts and for these two fields, so this mirror
    # cannot drift out of step unnoticed. An unreadable class yields an error row from each of the two samples.
    foreach ($protocol in @('TCPv4', 'TCPv6')) {
        foreach ($attempt in 1..2) {
            try {
                $counter = @(Get-CimOrWmiInstance ('Win32_PerfRawData_Tcpip_' + $protocol) | Select-Object -First 1)[0]
                if ($null -ne $counter -and $null -ne $counter.PSObject.Properties['SegmentsSentPersec'] -and $null -ne $counter.PSObject.Properties['SegmentsRetransmittedPersec']) {
                    $facts.TcpCounters[$protocol] = $true
                    break
                }
            }
            catch { }
        }
    }
    # How many wireless interfaces `netsh wlan show interfaces` reports as connected - the output Add-WifiRfResult parses,
    # which writes one wifi row per connected interface. Only a connected interface carries an SSID line, and that label
    # is not localized; without netsh, or with none connected, the script writes one row.
    $facts.WifiInterfaces = 0
    $netsh = Join-Path $env:SystemRoot 'System32\netsh.exe'
    if (Test-Path -LiteralPath $netsh) {
        try { $facts.WifiInterfaces = @(& $netsh wlan show interfaces 2>&1 | Where-Object { ([string]$_) -match '^\s*SSID\s*:' }).Count } catch { }
    }
    # How many wireless interfaces the machine has at all, connected or not - the set WlanEnumInterfaces lists, which is
    # what the Wi-Fi retry row (backlog #61) writes one row per; netsh prints one interface GUID per interface, and a
    # GUID label is not localized. A machine with none, or without the WLAN service, gets one row saying so. The GUIDs
    # themselves are kept as well (PR #52, round 6): an interface enabled or removed during the run gets a transition row
    # of its own, so the row count the oracle expects is the union of the lists read before the launch and after the report.
    $facts.WlanInterfaces = 0
    $facts.WlanInterfaceIds = @()
    if (Test-Path -LiteralPath $netsh) {
        try {
            $facts.WlanInterfaceIds = @(Get-WlanInterfaceIds -Lines @(& $netsh wlan show interfaces 2>&1 | ForEach-Object { [string]$_ }))
            $facts.WlanInterfaces = @($facts.WlanInterfaceIds).Count
        } catch { }
    }
    # Whether adapter statistics can be sampled, the way Get-AdapterStatisticsSnapshot samples them; without them both
    # sampling steps end as step-error rows and the analysis step writes one aggregate adapter-errors row.
    $facts.AdapterStatistics = $false
    if (Get-Command Get-NetAdapterStatistics -ErrorAction SilentlyContinue) {
        try { [void]@(Get-NetAdapterStatistics -ErrorAction Stop); $facts.AdapterStatistics = $true } catch { }
    }
    $useCim = $true
    if (Get-Command Get-NetIPConfiguration -ErrorAction SilentlyContinue) {
        try {
            $items = @()
            foreach ($c in @(Get-NetIPConfiguration -ErrorAction Stop)) {
                if ($null -eq $c.NetAdapter -or ([string]$c.NetAdapter.Status) -ne 'Up') { continue }
                $v4 = @($c.IPv4Address | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_.IPAddress) })
                $v6 = @($c.IPv6Address | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_.IPAddress) })
                if ($v4.Count -eq 0 -and $v6.Count -eq 0) { continue }
                $gws = @(); foreach ($g in @($c.IPv4DefaultGateway)) { if ($null -ne $g -and -not [string]::IsNullOrWhiteSpace([string]$g.NextHop)) { $gws += [string]$g.NextHop } }
                $dns = @(); if ($null -ne $c.DNSServer) { foreach ($srv in @($c.DNSServer.ServerAddresses)) { if (-not [string]::IsNullOrWhiteSpace([string]$srv)) { $dns += [string]$srv } } }
                $subs = @(); foreach ($a in $v4) { if ($null -ne $a.PrefixLength -and ([string]$a.PrefixLength) -match '^\d+$') { $subs += ('{0}/{1}' -f $a.IPAddress, $a.PrefixLength) } }
                $items += @{ IPv4 = $v4.Count; Gateways = $gws; Dns = $dns; Subnets = $subs; Addresses = @($v4 | ForEach-Object { [string]$_.IPAddress }) }
            }
            if ($items.Count -gt 0) { Add-PrimaryFacts $facts $items; $useCim = $false }
        }
        catch { $facts.DataSourceRow = $true }
    }
    if ($useCim) {
        # Every IP-enabled Win32_NetworkAdapterConfiguration, through CIM or WMI like the script. When the fallback throws
        # too (or neither command exists) the script's snapshot step ends as a step-error row and the run continues with
        # the zero-adapter shape; the facts record that.
        $facts.Source = 'CIM'
        $items = @()
        try {
            foreach ($c in @(Get-CimOrWmiInstance 'Win32_NetworkAdapterConfiguration' | Where-Object { $_.IPEnabled })) {
                $ipv4 = @(@($c.IPAddress) | Where-Object { $p = $null; [System.Net.IPAddress]::TryParse([string]$_, [ref]$p) -and $p.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork })
                $gws = @(); foreach ($g in @($c.DefaultIPGateway)) { $p = $null; if ([System.Net.IPAddress]::TryParse([string]$g, [ref]$p) -and $p.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) { $gws += [string]$g } }
                $dns = @(@($c.DNSServerSearchOrder) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
                # IPSubnet is a dotted mask on this path; the prefix is its count of one bits, the conversion the tool makes.
                $subs = @(); $allIps = @($c.IPAddress); $allMasks = @($c.IPSubnet)
                for ($i = 0; $i -lt $allIps.Count; $i++) {
                    $p = $null
                    if (-not ([System.Net.IPAddress]::TryParse([string]$allIps[$i], [ref]$p) -and $p.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) -or $i -ge $allMasks.Count) { continue }
                    $m = $null
                    if (([string]$allMasks[$i]) -match '^\d+$') { $subs += ('{0}/{1}' -f $allIps[$i], $allMasks[$i]) }
                    elseif ([System.Net.IPAddress]::TryParse([string]$allMasks[$i], [ref]$m) -and $m.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) { $subs += ('{0}/{1}' -f $allIps[$i], (@($m.GetAddressBytes() | ForEach-Object { [Convert]::ToString([int]$_, 2) }) -join '' -replace '0', '').Length) }
                }
                $items += @{ IPv4 = $ipv4.Count; Gateways = $gws; Dns = $dns; Subnets = $subs; Addresses = @($ipv4 | ForEach-Object { [string]$_ }) }
            }
        }
        catch { $items = @(); $facts.SnapshotStepFailed = $true }
        Add-PrimaryFacts $facts $items
    }
    return $facts
}
function Get-StandardRuleCount($Config) {
    # One expected-standard row per rule category the configuration defines (IPv4 address or subnet allowlist, prefix
    # lengths, gateways, DNS servers, DHCP mode), the way Test-ExpectedNetworkConfiguration writes them; blank entries
    # do not count, and a prefix length must be a whole number from 0 to 32.
    $e = $Config.Expected
    $nonBlank = { param($v) @(@($v) | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_) }).Count }
    $n = 0
    if ((& $nonBlank $e.AllowedIPv4Addresses) -gt 0 -or (& $nonBlank $e.AllowedIPv4Cidrs) -gt 0) { $n++ }
    if (@(@($e.AllowedPrefixLengths) | Where-Object { ([string]$_) -match '^\d{1,2}$' -and [int]$_ -le 32 }).Count -gt 0) { $n++ }
    if ((& $nonBlank $e.AllowedDefaultGateways) -gt 0) { $n++ }
    if ((& $nonBlank $e.RequiredDnsServers) -gt 0) { $n++ }
    if ($e.DhcpEnabled -is [bool]) { $n++ }
    return $n
}
# The row-count oracle reads configuration values through the package's own converters, loaded here from the
# package under test: how a value is read comes from the tool, while which rows it produces stays this file's own
# judgement (PR #41, round 3).
foreach ($converterSource in (Get-ConfigConverterSource (Join-Path (Join-Path $PackageDir 'en-US') 'NetworkHealthCheck.ps1'))) { Invoke-Expression $converterSource }

function Test-ResultSet {
    # The report must carry every row the configuration and the run options call for, and nothing else: one row per
    # configured or extra target, one per enabled IT diagnostic, the fixed rows (configuration, environment, system,
    # adapters, gateway and DNS settings, standard comparison, connectivity group per group, TCPv4 and TCPv6
    # retransmissions), each in its scope. Per-adapter rows depend on the machine, so they must exist and pair up (one
    # counter row per adapter row). A Run-AllChecks that skipped a diagnostic, an unknown or renamed tag, or a missing
    # row for an extra target given as a switch fails here. Returns the mismatches. $Machine (adapters and gateways as
    # the operating system reports them, see Get-MachineFacts) can be injected by the self-test.
    param($Report, $Config, [hashtable]$Expect, [hashtable]$Machine, [hashtable]$MachineAfter)
    if ($null -eq $Machine) { $Machine = Get-MachineFacts }
    if ($null -eq $MachineAfter) { $MachineAfter = $Machine }   # facts read after the run, for what the ending sample saw
    $bad = @()
    $o = $Report.RunOptions
    # An explicit null entry is skipped by the run and by the configuration check, so it is not a row here
    # either - which the DNS, TCP and HTTP helpers already knew (PR #41, round 5).
    $pingTargets = @($Config.Tests.PingTargets | Where-Object { $null -ne $_ })
    # Trimmed, because the run trims: since round 13 an address is read as ([string]$_).Trim() everywhere it is
    # used, so ' AUTO_GATEWAY ' is the placeholder to the run and would have been a literal target to this oracle
    # - one row expected where the run writes one per resolved gateway (PR #41, round 14).
    $gatewayTargets = @($pingTargets | Where-Object { ([string]$_.Address).Trim() -eq 'AUTO_GATEWAY' }).Count
    $dnsTargets = @($pingTargets | Where-Object { ([string]$_.Address).Trim() -eq 'AUTO_DNS' }).Count
    # A -TcpTarget the parser refused is in RawTargets and not in ExtraTargets; it costs one row in the TCP section
    # and one Startup Notice.
    $droppedTcp = (Get-Count $o.RawTargets.Tcp) - (Get-Count $o.ExtraTargets.Tcp)
    $gateways = @($Machine.Gateways)
    $dnsServerCount = Get-Count $Machine.DnsServers
    $connected = [int]$Machine.ConnectedAdapters
    # The near-end rung (backlog #60): none where the address is blank, which is the shipped configuration; otherwise
    # one row - the measured one, or the weightless one saying the target is the gateway, this machine's own address,
    # a network or broadcast address, not an IPv4 address or not on this network - and, where it is required and was
    # not probed, the weighted row saying the required check did not run. Where it sits is judged with the tool's own
    # placement function, loaded from the package, over the primary adapters the facts carry.
    $nearEndRows = 0
    $nearEndTargetRows = 0
    $nearEndTarget = Get-Value $Config.Tests 'NearEndTarget'
    $nearEndAddress = ([string](Get-Value $nearEndTarget 'Address')).Trim()
    $nearEndRequired = Test-TrueFlag (Get-Value $nearEndTarget 'Required')
    if ([string]::IsNullOrWhiteSpace($nearEndAddress)) {
        # Blank and required is a required check that did not run: the weightless notice and the weighted row (PR #51, round 3).
        if ($nearEndRequired) { $nearEndRows = 2 }
    }
    else {
        $nearEndRows = 1
        $nearEndPlacement = Test-NearEndTargetPlacement -Address $nearEndAddress -PrimaryAdapters @($Machine.PrimaryAdapters)
        $placed = (Test-NearEndAddressSyntax $nearEndAddress) -and ($nearEndPlacement.Placement -eq 'on-subnet')
        if (-not $placed) { if ($nearEndRequired) { $nearEndRows = 2 } }
        else {
            # A measured near-end row claims the rung - and its tag - only where the route table selects a source on
            # the target's subnet before and after the probes; otherwise the run writes it as a ping-target row. The
            # run reads the selection twice and this oracle once, so a route that changed during the run is the one
            # shape it cannot predict, and the resultset note is what says so.
            $nearEndSelection = Get-RouteSelection -Target $nearEndAddress
            if (-not ($nearEndSelection.Resolved -and $nearEndSelection.OnLink -eq $true -and (Test-IPv4InCidr -IpAddress $nearEndSelection.SourceAddress -Cidr ([string]$nearEndPlacement.Subnet)))) { $nearEndRows = 0; $nearEndTargetRows = 1 }
        }
    }
    # The two TCP counter samples are read independently (baseline, then ending): a class readable in both gives one
    # result row, unreadable in both two error rows, readable in one of them one error row and no result row. The
    # pre-launch facts stand for the baseline sample, the post-run facts for the ending one.
    $tcpBefore = $Machine.TcpCounters
    if ($null -eq $tcpBefore) { $tcpBefore = @{ TCPv4 = $true; TCPv6 = $true } }
    $tcpAfter = $MachineAfter.TcpCounters
    if ($null -eq $tcpAfter) { $tcpAfter = $tcpBefore }
    $tcpRows = 0
    foreach ($protocol in @('TCPv4', 'TCPv6')) {
        $tcpRows += $(if ([bool]$tcpBefore.$protocol -and [bool]$tcpAfter.$protocol) { 1 } elseif ((-not [bool]$tcpBefore.$protocol) -and (-not [bool]$tcpAfter.$protocol)) { 2 } else { 1 })
    }
    $statsReadable = $(if ($null -eq $Machine.AdapterStatistics) { $true } else { [bool]$Machine.AdapterStatistics })
    $wlanAfterIds = $(if ($null -ne $MachineAfter -and $null -ne $MachineAfter.WlanInterfaceIds) { @($MachineAfter.WlanInterfaceIds) } else { @($Machine.WlanInterfaceIds) })
    $wlanUnion = @(@($Machine.WlanInterfaceIds) + $wlanAfterIds | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { ([string]$_).ToLowerInvariant() } | Sort-Object -Unique).Count
    if ($null -eq $Machine.WlanInterfaceIds) { $wlanUnion = [int]$(if ($null -eq $Machine.WlanInterfaces) { 0 } else { $Machine.WlanInterfaces }) }
    # One connectivity-group row per group named on a TCP or HTTP target or listed in RequiredConnectivityGroups (a
    # required group without targets gets its own "no executable items" row), the way Test-ConnectivityTargets writes them.
    $groupKeys = @{}
    # Only a target the run can test joins its group: one refused before the request is sent leaves no group result,
    # so a group named by nothing else has no row at all (PR #41, round 2). A group listed in
    # RequiredConnectivityGroups still gets its own row, which the line below adds.
    foreach ($t in @($Config.Tests.TcpTargets)) { if ($null -ne $t -and (Test-ConfiguredTcpTarget $t)) { $g = [string]$t.Group; if (-not [string]::IsNullOrWhiteSpace($g)) { $groupKeys[$g] = $true } } }
    foreach ($t in @($Config.Tests.HttpTargets)) { if ($null -ne $t -and (Test-ConfiguredHttpTarget $t)) { $g = [string]$t.Group; if (-not [string]::IsNullOrWhiteSpace($g)) { $groupKeys[$g] = $true } } }
    $requiredGroups = @(@($Config.Tests.RequiredConnectivityGroups) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
    $groups = @(@(@($groupKeys.Keys) + $requiredGroups) | Select-Object -Unique)
    $rules = Get-StandardRuleCount $Config
    $want = [ordered]@{
        # config is one row on a configuration the tool can use as written, and up to four when it cannot: the
        # validation and threshold rows keep their weight, while the targets and options rows that name this run's
        # own input do not (backlog #39). The packaged configuration is valid, so the chain's own runs see one.
        'config-file' = 1; 'config' = (Get-ConfigRowCount $Config $o $Expect['Overrides']); 'environment' = 1; 'system' = 1; 'adapters' = 1
        'data-source' = $(if ([bool]$Machine.DataSourceRow) { 1 } else { 0 })   # the CIM fallback's warning row, only when the cmdlets threw
        # Without a connected adapter the snapshot writes the aggregate adapters row only: no gateway or DNS settings rows.
        'gateway-config' = $(if ($connected -gt 0) { 1 } else { 0 })
        'dns-config' = $(if ($connected -gt 0) { 1 } else { 0 })
        # One row per configured standard rule; one informational row without rules; one failure row without adapters.
        'expected-standard' = $(if ($rules -eq 0 -or $connected -eq 0) { 1 } else { $rules })
        'ping-gateway' = $gatewayTargets * [math]::Max(1, $gateways.Count)   # one row per resolved gateway, or one "no target" row
        # A literal target is one row; AUTO_DNS is one row per DNS server of the primary adapters, or one "no target" row.
        # A ping target that cannot be used costs the same two rows as the other families when it is required
        # (PR #41, round 2): the weightless notice, and the weighted row saying the check did not run.
        'ping-target' = ($pingTargets.Count - $gatewayTargets - $dnsTargets) + $dnsTargets * [math]::Max(1, $dnsServerCount) + (Get-Count $o.ExtraTargets.Ping) + (Get-UnusablePingExtraRows $Config) + $nearEndTargetRows
        'ping-near-end' = $nearEndRows
        # A target the run cannot test is reported where its result belonged instead of vanishing, and a required one
        # adds the weighted row saying the check did not run (backlog #39); a dropped extra target - one the parser
        # refused, so it is in RawTargets and not in ExtraTargets - leaves a row of its own in the same section, and
        # a Startup Notice besides, which is the row this table had no entry for until round 11: any startup row at
        # all was an unexpected tag, so no case could ever pass a target that gets dropped. The environment
        # notices - report folder, graphical interface, running from a ZIP - are not expected here, and a run that
        # produced one would fail this assertion, which is the intent: none of them is true of a staged run.
        'dns' = (Get-TargetRowCount $Config.Tests.DnsNames { param($t) Test-ConfiguredDnsTarget $t } $true) + (Get-Count $o.ExtraTargets.Dns)
        'tcp' = (Get-TargetRowCount $Config.Tests.TcpTargets { param($t) Test-ConfiguredTcpTarget $t } $false) + (Get-Count $o.ExtraTargets.Tcp) + $droppedTcp
        'startup' = $droppedTcp
        'http' = (Get-TargetRowCount $Config.Tests.HttpTargets { param($t) Test-ConfiguredHttpTarget $t } $false) + (Get-Count $o.ExtraTargets.Http)
        'connectivity-group' = $groups.Count
        # Per class as computed above, and that formula now covers every case: since 1.2.8 a baseline where neither
        # class could be read is returned rather than thrown away, so the analysis writes one row per read that failed
        # instead of a step-error row and one generic row (backlog #38, PR #40 rounds 5 and 9).
        'tcp-retransmissions' = $tcpRows
        # One weightless Wi-Fi retry row per wireless interface listed at either reading - the union of the GUID lists
        # read before the launch and after the report, since an interface enabled or removed during the run gets a
        # transition row of its own (PR #52, round 6) - or one row saying there is none or that the reader was
        # unavailable (backlog #61); none at all when the configuration switches it off. A fact without the list falls
        # back to the count.
        'wifi-retry' = $(if (Test-TrueFlag $Config.Checks.WifiRetryCounters) { [math]::Max(1, $wlanUnion) } else { 0 })
        # Step failures the machine facts explain: both adapter-statistics samples without the cmdlet (or one of them
        # when a sample failed on its own - see below) and the network snapshot when its fallback failed too. The TCP
        # baseline is no longer among them, whatever its counters do. Any other step-error row is unexpected.
        'step-error' = $(if ($statsReadable) { 0 } else { 2 }) + $(if ([bool]$Machine.SnapshotStepFailed) { 1 } else { 0 })
    }
    # The IT diagnostics to expect come from the configuration and the launch switches (-NoWifi / -NoTraceroute as
    # Expect['NoWifi'] / Expect['NoTraceroute']), never from the report under test; the report's own ChecksEnabled must
    # agree with them.
    $itTags = [ordered]@{ 'wifi' = (Test-TrueFlag $Config.Checks.WifiRf); 'wifi-association' = (Test-TrueFlag $Config.Checks.WifiRf); 'routes' = (Test-TrueFlag $Config.Checks.RouteTable); 'gateway-neighbor' = (Test-TrueFlag $Config.Checks.GatewayNeighbor); 'proxy' = (Test-TrueFlag $Config.Checks.ProxySettings); 'traceroute' = (Test-TrueFlag $Config.Checks.Traceroute); 'drivers' = (Test-TrueFlag $Config.Checks.DriverInfo) }
    if ($Expect['NoWifi'] -eq $true) { $itTags['wifi'] = $false; $itTags['wifi-association'] = $false }
    if ($Expect['NoTraceroute'] -eq $true) { $itTags['traceroute'] = $false }
    $reported = @{ 'wifi' = $o.ChecksEnabled.WifiRf; 'wifi-association' = $o.ChecksEnabled.WifiRf; 'routes' = $o.ChecksEnabled.RouteTable; 'gateway-neighbor' = $o.ChecksEnabled.GatewayNeighbor; 'proxy' = $o.ChecksEnabled.ProxySettings; 'traceroute' = $o.ChecksEnabled.Traceroute; 'drivers' = $o.ChecksEnabled.DriverInfo }
    if ([bool]$o.ChecksEnabled.WifiRetryCounters -ne (Test-TrueFlag $Config.Checks.WifiRetryCounters)) { $bad += ('ChecksEnabled for WifiRetryCounters reported as {0}, expected {1} from the configuration' -f $o.ChecksEnabled.WifiRetryCounters, (Test-TrueFlag $Config.Checks.WifiRetryCounters)) }
    foreach ($k in @($itTags.Keys)) {
        if ([bool]$reported[$k] -ne [bool]$itTags[$k]) { $bad += ('ChecksEnabled for {0} reported as {1}, expected {2} from the configuration and the switches' -f $k, $reported[$k], $itTags[$k]) }
        # One row per enabled diagnostic; the gateway neighbour is looked up once per resolved gateway, the Wi-Fi radio
        # reported once per connected wireless interface, and the Wi-Fi association once per wireless interface netsh
        # listed at either reading (backlog #61's other half; the union, as for the retry rows) - one row each without.
        $want[$k] = $(if (-not $itTags[$k]) { 0 } elseif ($k -eq 'gateway-neighbor') { [math]::Max(1, $gateways.Count) } elseif ($k -eq 'wifi') { [math]::Max(1, [int]$(if ($null -eq $Machine.WifiInterfaces) { 0 } else { $Machine.WifiInterfaces })) } elseif ($k -eq 'wifi-association') { [math]::Max(1, $wlanUnion) } else { 1 })
    }
    $rows = @($Report.Results)
    $byTag = @{}
    foreach ($r in $rows) { $t = [string]$r.Tag; if (-not $byTag.ContainsKey($t)) { $byTag[$t] = 0 }; $byTag[$t]++ }
    # The two adapter-statistics samples are taken independently: when exactly one of them fails on a machine where the
    # cmdlet works, the report legitimately carries one step-error row and the single aggregate "Before/After
    # Comparison" row (the only adapter-errors row the script ever writes with status ERROR) instead of one row per adapter.
    $counterRows = @($rows | Where-Object { $_.Tag -eq 'adapter-errors' })
    $oneSampleFailed = $statsReadable -and ($counterRows.Count -eq 1) -and ([string]$counterRows[0].Status -eq 'ERROR')
    if ($oneSampleFailed) { $want['step-error'] = [int]$want['step-error'] + 1 }
    # The Wi-Fi retry reader that fails before it can list the interfaces - the type refused, the WLAN service silent -
    # writes one aggregate Unable-to-Check row and no per-interface row (PR #52, rounds 1 and 2), so on a machine with
    # several wireless interfaces that single row is the shape and not a missing row. A per-interface error row - a
    # reset counter, a failed query - carries the same tag and status, so the shape is read off the row itself: the
    # aggregate row's first details line ends with the reader's reason code, a language-neutral token like a tag
    # (addtype, open, enumerate, error, or none where an interface was listed at only one reading - round 3), which the
    # per-interface rows' first line - the connection-state sentence -
    # never does; the unit tests hold both scripts to that.
    $retryRows = @($rows | Where-Object { $_.Tag -eq 'wifi-retry' })
    # Every wifi-retry row decides nothing, whatever its shape (backlog #61's decision): a weighted one would turn a
    # healthy report Test Incomplete on a reader failure, so the marking is checked on each row (PR #52, round 9).
    foreach ($r in $retryRows) { if (-not [bool]$r.Weightless) { $bad += ('wifi-retry: a row that is not weightless ({0}, {1})' -f $r.Status, $r.Check) } }
    $aggregateRetryFailure = $false
    if ($retryRows.Count -eq 1 -and [string]$retryRows[0].Status -eq 'ERROR') {
        $firstLine = [string](@(([string]$retryRows[0].Details) -split "`r`n|`n")[0])
        $aggregateRetryFailure = ($firstLine -match '[:：]\s*(addtype|open|enumerate|error|none)\s*$')
    }
    if ([int]$want['wifi-retry'] -gt 1 -and $aggregateRetryFailure) { $want['wifi-retry'] = 1 }
    # Per interface, not only in total (PR #52, round 7): every per-interface row names its interface GUID on a details
    # line, so each GUID either reading listed must have exactly one row - a transition in each direction for a
    # replacement, a measured row for the one that stayed - and no row may name a GUID neither reading listed.
    if (-not $aggregateRetryFailure -and $null -ne $Machine.WlanInterfaceIds -and (Test-TrueFlag $Config.Checks.WifiRetryCounters)) {
        $unionIds = @(@($Machine.WlanInterfaceIds) + $wlanAfterIds | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { ([string]$_).ToLowerInvariant() } | Sort-Object -Unique)
        foreach ($id in $unionIds) {
            $n = @($retryRows | Where-Object { ([string]$_.Details).ToLowerInvariant().Contains($id) }).Count
            if ($n -ne 1) { $bad += ('wifi-retry: interface {0} has {1} row(s), expected 1' -f $id, $n) }
        }
        foreach ($r in $retryRows) {
            $m = [regex]::Match([string]$r.Details, '[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}')
            if ($m.Success -and ($unionIds -notcontains $m.Value.ToLowerInvariant())) { $bad += ('wifi-retry: a row names interface {0}, which neither reading listed' -f $m.Value) }
        }
    }
    # The Wi-Fi association rows (backlog #61's other half) follow the retry rows' shape, one switch over: one row per
    # wireless interface netsh listed at either reading, each naming its GUID once; or one Information row saying no
    # interface was listed; or, where every sample failed - netsh missing, or the read threw - one aggregate
    # Unable-to-Check row whose first details line ends with the reason code (netsh, exception), which a per-interface
    # row's first line - a sample line - never does. They ride the radio row's switch (Checks.WifiRf, -NoWifi).
    $assocRows = @($rows | Where-Object { $_.Tag -eq 'wifi-association' })
    $aggregateAssocFailure = $false
    if ($assocRows.Count -eq 1 -and [string]$assocRows[0].Status -eq 'ERROR') {
        $firstLine = [string](@(([string]$assocRows[0].Details) -split "`r`n|`n")[0])
        $aggregateAssocFailure = ($firstLine -match '[:：]\s*(netsh|exception|none)\s*$')
    }
    if ([int]$want['wifi-association'] -gt 1 -and $aggregateAssocFailure) { $want['wifi-association'] = 1 }
    if (-not $aggregateAssocFailure -and $null -ne $Machine.WlanInterfaceIds -and [bool]$itTags['wifi-association']) {
        $assocIds = @(@($Machine.WlanInterfaceIds) + $wlanAfterIds | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { ([string]$_).ToLowerInvariant() } | Sort-Object -Unique)
        # The GUID is read off the identity line only - the GUID that the samples token follows (PR #54, round 2): a
        # network named like a UUID is printed in the sample lines above it, and an unanchored match would have read the
        # network as the interface and refused a valid report. A per-interface row without the token is a tool regression
        # and is refused as such; the aggregate rows (netsh, exception, none) carry neither a GUID nor the token.
        # The token's grammar (round 6): one or more of the three sample names, comma-separated, ending the line - a regression
        # that lost the listed moments would leave an empty token or a made-up name, and a match that stopped at 'samples='
        # would have passed it as a known or transient interface.
        $assocToken = 'samples=(start|middle|end)(,(start|middle|end))*(?=\r|\n|$)'
        $assocGuidOnIdentity = '([0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12})[;；]\s*' + $assocToken
        foreach ($r in $assocRows) {
            $firstLine = [string](@(([string]$r.Details) -split "`r`n|`n")[0])
            if ($firstLine -match '[:：]\s*(netsh|exception|none)\s*$') { continue }
            if (([string]$r.Details) -notmatch $assocToken) { $bad += ('wifi-association: a per-interface row carries no valid samples token ({0})' -f $r.Message) }
        }
        foreach ($id in $assocIds) {
            $n = @($assocRows | Where-Object { $m = [regex]::Match([string]$_.Details, $assocGuidOnIdentity); $m.Success -and ($m.Groups[1].Value.ToLowerInvariant() -eq $id) }).Count
            if ($n -ne 1) { $bad += ('wifi-association: interface {0} has {1} row(s), expected 1' -f $id, $n) }
        }
        # An interface the tool sampled but neither of these two readings listed has a legitimate row (PR #54, rounds 1 and
        # 4): the readings are taken before the process starts and after it exits, so an adapter enabled after the first
        # and removed before the second can be present at any of the run's three samples - the start and the end as much as
        # the middle, which round 1 alone had allowed. Every per-interface row names the samples its interface was listed
        # at as a language-neutral token, samples=start,middle,end, and a row naming a GUID outside the union with that
        # token is such a transient interface: one more expected row. What this oracle cannot see is what the samples saw
        # except through the rows, so a fabricated row with a token would pass here - the same approximation the retry
        # rows' union already accepts, one step looser - while the per-interface count above still holds every interface
        # the readings did list to exactly one row, a row without the token is refused above as a tool regression, and a
        # transient identity is held to one row as well (round 5): two rows for the same unknown GUID are a duplication,
        # not two interfaces, and the report itself is enough to see that.
        $transientSeen = @{}
        foreach ($r in $assocRows) {
            $m = [regex]::Match([string]$r.Details, $assocGuidOnIdentity)
            if (-not $m.Success -or ($assocIds -contains $m.Groups[1].Value.ToLowerInvariant())) { continue }
            $id = $m.Groups[1].Value.ToLowerInvariant()
            if (-not $transientSeen.ContainsKey($id)) { $transientSeen[$id] = 0 }
            $transientSeen[$id]++
        }
        foreach ($id in @($transientSeen.Keys)) { if ($transientSeen[$id] -ne 1) { $bad += ('wifi-association: transient interface {0} has {1} row(s), expected 1' -f $id, $transientSeen[$id]) } }
        $transientAssoc = @($transientSeen.Keys).Count
        if ($transientAssoc -gt 0) { $want['wifi-association'] = [math]::Max(1, $wlanUnion + $transientAssoc) }
    }
    foreach ($k in @($want.Keys)) {
        $have = $(if ($byTag.ContainsKey($k)) { $byTag[$k] } else { 0 })
        if ($have -ne $want[$k]) { $bad += ('{0}: {1} row(s), expected {2}' -f $k, $have, $want[$k]) }
    }
    $adapters = $(if ($byTag.ContainsKey('adapter')) { $byTag['adapter'] } else { 0 })
    $counters = $(if ($byTag.ContainsKey('adapter-errors')) { $byTag['adapter-errors'] } else { 0 })
    if ($connected -gt 0) {
        # One adapter row per connected adapter with an address, and one counter row per adapter row.
        if ($adapters -ne $connected) { $bad += ('adapter: {0} row(s), expected one per connected adapter with an address ({1})' -f $adapters, $connected) }
        if ($statsReadable -and -not $oneSampleFailed -and $counters -ne $adapters) { $bad += ('adapter-errors: {0} row(s), expected one per adapter row ({1})' -f $counters, $adapters) }
    }
    else {
        # The zero-adapter shape: the aggregate adapters row fails, there are no adapter rows, and the counter rows come
        # from whatever the counter sample named, so their number is not constrained.
        if ($adapters -ne 0) { $bad += ('adapter: {0} row(s) although the machine has no connected adapter with an address' -f $adapters) }
        $aggregate = @($rows | Where-Object { $_.Tag -eq 'adapters' })
        if ($aggregate.Count -eq 1 -and [string]$aggregate[0].Status -ne 'FAIL') { $bad += ('adapters row is {0}, expected FAIL with no connected adapter' -f $aggregate[0].Status) }
    }
    # Without adapter statistics the analysis step writes one aggregate adapter-errors row instead of one per adapter.
    if (-not $statsReadable -and $counters -ne 1) { $bad += ('adapter-errors: {0} row(s), expected the single aggregate row without adapter statistics' -f $counters) }
    $known = @($want.Keys) + @('adapter', 'adapter-errors')
    $unknown = @($byTag.Keys | Where-Object { $known -notcontains $_ })
    if ($unknown.Count) { $bad += ('unexpected tag(s): ' + ($unknown -join ', ')) }
    $expectedTotal = $adapters + $counters
    foreach ($k in @($want.Keys)) { $expectedTotal += [int]$want[$k] }
    if ($rows.Count -ne $expectedTotal) { $bad += ('{0} results, expected {1}' -f $rows.Count, $expectedTotal) }
    foreach ($r in $rows) {
        $scope = $(if ($itTags.Contains([string]$r.Tag)) { 'IT' } else { 'Main' })
        if ([string]$r.Scope -ne $scope) { $bad += ('{0} row in scope {1}, expected {2}' -f $r.Tag, $r.Scope, $scope) }
    }
    # Gateway rows by target: when the machine has default gateways, every ping-gateway row must name one of them
    # (the address is part of the check name in both languages), each gateway once.
    if ($gateways.Count -gt 0) {
        $gwRows = @($rows | Where-Object { $_.Tag -eq 'ping-gateway' })
        $named = @($gwRows | ForEach-Object { [regex]::Match([string]$_.Check, '\d{1,3}(\.\d{1,3}){3}').Value } | Where-Object { $_ })
        if ($named.Count -ne $gwRows.Count) { $bad += 'a ping-gateway row names no IPv4 address' }
        foreach ($a in $named) { if ($gateways -notcontains $a) { $bad += ('ping-gateway row for {0}, which is not a default gateway of this machine ({1})' -f $a, ($gateways -join ', ')) } }
        if (@($named | Sort-Object -Unique).Count -ne $named.Count) { $bad += 'duplicate ping-gateway rows' }
    }
    # Both protocols are named whatever happened to their counters: a class that could not be read has an error row
    # of its own, per sample, rather than a generic row for the pair (backlog #38).
    foreach ($protocol in @('TCPv4', 'TCPv6')) {
        if (@($rows | Where-Object { $_.Tag -eq 'tcp-retransmissions' -and (([string]$_.Check) -like ('*' + $protocol + '*')) }).Count -eq 0) { $bad += ('no tcp-retransmissions row for {0}' -f $protocol) }
    }
    # A TCP target that answered carries its connection sample (backlog #52): PingCount connections timed one by one and
    # read against the initial retransmission timeout, whose details line names the value in ms beside the token RTO
    # in both languages. A passed tcp row without that line is a tool that stopped sampling; a row that did not
    # connect carries no sample by design and is not held to one.
    foreach ($r in @($rows | Where-Object { $_.Tag -eq 'tcp' -and [string]$_.Status -eq 'PASS' })) {
        if (([string]$r.Details) -notmatch 'RTO[^\r\n]*?\d+ ms') { $bad += ('tcp: a row that passed carries no connection sample ({0})' -f $r.Check) }
    }
    foreach ($pair in @(@('ExtraPing', 'ping-target'), @('ExtraTcp', 'tcp'))) {
        if (-not $Expect.ContainsKey($pair[0])) { continue }
        foreach ($value in @($Expect[$pair[0]])) {
            if (@($rows | Where-Object { $_.Tag -eq $pair[1] -and (($_.Check + ' ' + $_.Message) -like ('*' + $value + '*')) }).Count -eq 0) { $bad += ('no {0} row for {1}' -f $pair[1], $value) }
        }
    }
    return $bad
}
function ConvertTo-FactsKey([hashtable]$F) {
    return ('{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}|{8}|{9}|{10}' -f $F.ConnectedAdapters, (@($F.Gateways) -join ','), (@($F.DnsServers) -join ','), $F.WifiInterfaces, [bool]$F.TcpCounters.TCPv4, [bool]$F.TcpCounters.TCPv6, [bool]$F.AdapterStatistics, [bool]$F.DataSourceRow, [bool]$F.SnapshotStepFailed, $F.WlanInterfaces, (@($F.WlanInterfaceIds) -join ','))
}
function Test-ResultSetForRun {
    # The machine can change while a run samples for two minutes (an adapter connecting or dropping, a Wi-Fi roaming),
    # so the facts are read before the launch and after the report: the report must match the pre-launch facts, or -
    # when the two readings differ - the post-run facts, and the note says which. Returns @{ Mismatches; Note }.
    param($Report, $Config, [hashtable]$Expect, [hashtable]$Before, [hashtable]$After)
    $bad = @(Test-ResultSet $Report $Config $Expect $Before $After)
    if ($bad.Count -eq 0 -or ((ConvertTo-FactsKey $Before) -eq (ConvertTo-FactsKey $After))) { return @{ Mismatches = $bad; Note = '' } }
    if (@(Test-ResultSet $Report $Config $Expect $After $After).Count -eq 0) { return @{ Mismatches = @(); Note = 'the machine changed during the run; the report matches the post-run facts' } }
    return @{ Mismatches = $bad; Note = 'the machine changed during the run; the report matches neither the pre-launch nor the post-run facts' }
}
function Get-NewestJson([string]$Dir, [datetime]$After) {
    @(Get-ChildItem -LiteralPath $Dir -Filter '*.json' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt $After } | Sort-Object LastWriteTime -Descending | Select-Object -First 1)[0]
}
function Read-Report([System.IO.FileInfo]$File) { Get-Content -LiteralPath $File.FullName -Raw -Encoding UTF8 | ConvertFrom-Json }
function Test-ReportExpectations {
    # Compares the run options a JSON report recorded with what the launch must have produced; returns the mismatches.
    param($Report, [hashtable]$Expect)
    $bad = @()
    foreach ($key in @('EntryPoint', 'PingCount', 'SampleSeconds', 'TracerouteHops')) {
        if ($Expect.ContainsKey($key) -and ([string]$Report.RunOptions.$key -ne [string]$Expect[$key])) { $bad += ('{0}={1} (expected {2})' -f $key, $Report.RunOptions.$key, $Expect[$key]) }
    }
    if ($Expect.ContainsKey('ExpandDetails') -and ([bool]$Report.RunOptions.ExpandDetails -ne [bool]$Expect['ExpandDetails'])) { $bad += ('ExpandDetails={0} (expected {1})' -f $Report.RunOptions.ExpandDetails, $Expect['ExpandDetails']) }
    # The extra targets the run recorded must be exactly the ones the launch gave - none without switches - so that a run
    # duplicating a target or adding one of its own fails here, before the rows are counted from that same list.
    foreach ($kind in @(@('ExtraPing', 'Ping'), @('ExtraDns', 'Dns'), @('ExtraTcp', 'Tcp'), @('ExtraHttp', 'Http'))) {
        $expected = @(); if ($Expect.ContainsKey($kind[0])) { $expected = @(@($Expect[$kind[0]]) | ForEach-Object { [string]$_ }) }
        $actual = @(@($Report.RunOptions.ExtraTargets.($kind[1])) | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
        if ((@($actual | Sort-Object) -join '|') -ne (@($expected | Sort-Object) -join '|')) { $bad += ('ExtraTargets.{0} = [{1}], expected exactly [{2}]' -f $kind[1], ($actual -join ', '), ($expected -join ', ')) }
    }
    if ([string]$Report.SchemaVersion -ne '2') { $bad += ('SchemaVersion={0} (expected 2)' -f $Report.SchemaVersion) }
    if ($RequireHealthy -and (-not $Expect['AllowUnhealthy']) -and ([string]$Report.Overall.Code -ne 'PASS')) { $bad += ('Overall {0}, not PASS' -f $Report.Overall.Code) }
    # backlog #14: a run whose targets cannot be reached must classify the failures by their error code, in the report
    # language, with the operating system's own message kept underneath. Which code appears depends on the network (a
    # resolver that answers for an unknown name turns a name failure into a connect failure), so any code counts - the
    # tool's own timeout included, which is classified like the others since 1.2.3 (backlog #27).
    if ($Expect['RequireErrorCause']) {
        $classified = @($Report.Results | Where-Object { ([string]$_.Details + [string]$_.Message) -match '\[(SocketError|WebExceptionStatus) \w+\]|\[ToolTimeout\]' })
        if (-not $classified.Count) { $bad += 'no result carries a [SocketError ...] / [WebExceptionStatus ...] / [ToolTimeout] cause' }
    }
    return $bad
}
function Format-ReportDetail($Report) {
    $it = @($Report.Results | Where-Object { $_.Scope -eq 'IT' }).Count
    return ('EntryPoint={0} PingCount={1} SampleSeconds={2} TracerouteHops={3}; Overall {4} ({5}); {6} results ({7} IT); fingerprint {8}' -f $Report.RunOptions.EntryPoint, $Report.RunOptions.PingCount, $Report.RunOptions.SampleSeconds, $Report.RunOptions.TracerouteHops, $Report.Overall.Text, $Report.Overall.Code, @($Report.Results).Count, $it, $Report.Fingerprint.Key)
}
function Invoke-WindowRun {
    # One real-window run through gui_check.ps1 - launched the way a person does it, through the shipped
    # Start-NetworkCheck.cmd / Start-NetworkCheck-IT.cmd - and the evidence it must leave: exit 0 (gui_check itself fails
    # on an IT entry that starts by itself, a user entry that does not, a Start click without effect, a nonzero process
    # exit code or a LauncherError.txt); the launcher's effective command line carrying -Interactive -ExpandDetails for
    # the IT entry only; a JSON report whose run options match the launch (entry point, ExpandDetails, ping count and
    # sample seconds from the folder's configuration); the title carrying the IT marker for the IT entry only ("- IT" /
    # "(IT)" right before the closing quote of the window line); the window closed through its own Close button.
    param([string]$Dir, [string]$Entry, [string]$LogName, [string]$LauncherPath)
    $expect = Get-ConfigSampling $Dir
    $expect['EntryPoint'] = $Entry
    $expect['ExpandDetails'] = ($Entry -eq 'IT')
    # An IT window run is started from the panel - the Start handler, not the Reset button - and
    # Get-RunOptionsFromPanel hands Set-RunOptions the three spinner values and all six check boxes, so those
    # reach the effective configuration as real values before it is validated, whatever the file holds (PR #41,
    # round 9). A user entry has no panel and overrides nothing. The spinners hold whatever Set-OptionsPanelValues
    # seeded them with, always within their own minimum and maximum; what matters below is only that a value is
    # supplied, so the hop count here stands for the panel's, not for a number this run asserts.
    if ($Entry -eq 'IT') {
        $expect['Overrides'] = @{
            PingCount      = $expect['PingCount']
            SampleSeconds  = $expect['SampleSeconds']
            TracerouteHops = 3
            Checks         = @{ WifiRf = $true; Traceroute = $true; RouteTable = $true; GatewayNeighbor = $true; ProxySettings = $true; DriverInfo = $true }
        }
    }
    $factsBefore = Get-MachineFacts
    $started = Get-Date
    $argList = @('-PackageDir', $Dir, '-Entry', $Entry, '-Via', 'Launcher', '-TimeoutSeconds', $GuiTimeoutSeconds)
    if ($LauncherPath) { $argList += @('-LauncherPath', $LauncherPath) }
    $r = Invoke-TestScript 'gui_check.ps1' $argList $LogName
    if ($r.ExitCode -ne 0) { return @{ Passed = $false; Detail = ('exit code {0}: {1}' -f $r.ExitCode, [string]@($r.Output | Where-Object { $_ -match 'ERROR' })[0]) } }
    $json = Get-NewestJson (Join-Path $Dir 'Reports') $started
    if ($null -eq $json) { return @{ Passed = $false; Detail = 'exit 0 but no JSON report' } }
    $factsAfter = Get-MachineFacts
    $d = Read-Report $json
    $resultSet = Test-ResultSetForRun $d (Read-Config $Dir) $expect $factsBefore $factsAfter
    $bad = @(Test-ReportExpectations $d $expect) + @($resultSet.Mismatches)
    $cmdline = [string]@($r.Output | Where-Object { $_ -match 'launcher started .* with: ' })[0]
    if (-not $cmdline) { $bad += 'the launcher command line was not captured' }
    else {
        $hasIt = ($cmdline -match '(?i)-Interactive\b') -and ($cmdline -match '(?i)-ExpandDetails\b')
        $hasAny = ($cmdline -match '(?i)-Interactive\b') -or ($cmdline -match '(?i)-ExpandDetails\b')
        if ($Entry -eq 'IT' -and -not $hasIt) { $bad += 'the IT launcher does not pass -Interactive -ExpandDetails' }
        if ($Entry -eq 'User' -and $hasAny) { $bad += 'the user launcher passes an IT switch' }
    }
    $window = [string]@($r.Output | Where-Object { $_ -match "window: '" })[0]
    $titledIt = [bool]($window -match "IT[^']{0,3}' \d+x\d+")
    if ($titledIt -ne ($Entry -eq 'IT')) { $bad += ('window title ' + $(if ($titledIt) { 'carries' } else { 'lacks' }) + ' the IT marker') }
    if (@($r.Output | Where-Object { $_ -match 'closed via the Close button; process exit code 0$' }).Count -eq 0) { $bad += 'not closed through the Close button with exit code 0' }
    $launcherLine = [string]@($r.Output | Where-Object { $_ -match '\] launcher: ' })[0] -replace '^.*launcher: ', ''
    $detail = (Format-ReportDetail $d) + '; ' + ($window -replace '^\[[^\]]+\]\s*', '') + $(if ($launcherLine) { '; via ' + $launcherLine } else { '' }) + $(if ($resultSet.Note) { '; ' + $resultSet.Note } else { '' })
    if ($bad.Count) { $detail = ($bad -join '; ') + ' | ' + $detail }
    return @{ Passed = ($bad.Count -eq 0); Detail = $detail }
}

# -------------------- The chain --------------------
$prevOutputEncoding = [Console]::OutputEncoding
try { [Console]::OutputEncoding = $Utf8NoBom } catch { }
$env:PYTHONUTF8 = '1'; $env:PYTHONIOENCODING = 'utf-8'
try {
    $ToolVersion = Read-ToolVersion
    # A clean machine has neither git nor Python (backlog #19): the header says so instead of failing. Only the
    # validator, guards and package steps need them, and those run on every commit on GitHub Actions.
    $gitHead = 'no git'; $dirty = @(); $pythonVersion = 'no python'
    if (Get-Command git -ErrorAction SilentlyContinue) {
        $g = Invoke-Native 'git' @('-C', $Root, 'rev-parse', '--short', 'HEAD') 'env_git'
        if ($g.ExitCode -eq 0) {
            $gitHead = [string]@($g.Output)[0]
            $dirty = @((Invoke-Native 'git' @('-C', $Root, 'status', '--porcelain', '--', 'healthcheck') 'env_git_status').Output | Where-Object { $_ })
        }
        else { $gitHead = 'not a git checkout' }
    }
    if (Get-Command $Python -ErrorAction SilentlyContinue) { $pythonVersion = [string]@((Invoke-Native $Python @('--version') 'env_python').Output)[0] }
    Write-Host ('NetworkHealthCheck {0} validation chain - {1}' -f $ToolVersion, (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    Write-Host ('  checkout {0} at {1}{2}' -f $Root, $gitHead, $(if ($dirty.Count) { ' (healthcheck/ has uncommitted changes)' } else { '' }))
    Write-Host ('  package {0}' -f $PackageDir)
    Write-Host ('  {0}; Windows PowerShell {1}; {2}' -f [Environment]::OSVersion.VersionString, $PSVersionTable.PSVersion, $pythonVersion)
    Write-Host ('  steps: {0}; work dir: {1}' -f ($selected -join ', '), $WorkDir)

    if ($selected -contains 'parse') {
        # Before anything is parsed: no file in tests\ carries a control byte other than its line ending or a
        # tab. A regex escape that arrives as the character it names leaves a real one behind, every test still
        # passes because the class means the same thing, and git then treats the file as binary and stops
        # normalising it - which is how one line of PR #41 round 21 rewrote all 902 (round 21 again, after the
        # same mistake had already been fixed once in the package). validate_release.py guards the package; this
        # guards the harness.
        Invoke-Case 'parse' 'no stray control bytes in tests\' {
            $bad = @()
            foreach ($file in @(Get-ChildItem -LiteralPath $PSScriptRoot -File -Recurse -Include *.ps1, *.py, *.md, *.cmd)) {
                $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
                # Position matters for one of them: 0x0D is half a line ending, so it is stray unless 0x0A follows
                # it - the same blind spot the package validator had in round 22.
                $found = New-Object System.Collections.ArrayList
                for ($i = 0; $i -lt $bytes.Length; $i++) {
                    $byte = $bytes[$i]
                    if ($byte -lt 9 -or ($byte -gt 10 -and $byte -lt 13) -or ($byte -gt 13 -and $byte -lt 32) -or $byte -eq 127) { [void]$found.Add($byte); continue }
                    if ($byte -eq 13 -and (($i + 1) -ge $bytes.Length -or $bytes[$i + 1] -ne 10)) { [void]$found.Add($byte) }
                }
                $found = @($found | Sort-Object -Unique)
                if ($found.Count -gt 0) { $bad += ('{0}: {1}' -f $file.Name, (($found | ForEach-Object { '0x{0:X2}' -f $_ }) -join ', ')) }
            }
            @{ Passed = ($bad.Count -eq 0); Detail = $(if ($bad.Count -eq 0) { 'none' } else { $bad -join '; ' }) }
        }
        foreach ($lang in $Languages) {
            Invoke-Case 'parse' $lang {
                $r = Invoke-TestScript 'parse_check.ps1' @('-Path', (Join-Path $PackageDir ($lang + '\NetworkHealthCheck.ps1'))) ('parse_' + $lang)
                @{ Passed = ($r.ExitCode -eq 0); Detail = [string]@($r.Output)[0] }
            }
        }
    }
    if ($selected -contains 'validator') {
        Invoke-Case 'validator' 'healthcheck/' {
            $r = Invoke-Native $Python @((Join-Path $PackageDir 'tools\validate_release.py'), $PackageDir) 'validator'
            $s = Get-SummaryLine $r.Output
            @{ Passed = (($r.ExitCode -eq 0) -and (Test-SummaryClean $s)); Detail = $s }
        }
    }
    if ($selected -contains 'guards') {
        Invoke-Case 'guards' 'ast_guards.ps1' {
            $r = Invoke-TestScript 'selftest_guards.ps1' @() 'guards'
            $corpus = [string]@($r.Output | Where-Object { $_ -match '^corpus:' })[0]
            @{ Passed = (($r.ExitCode -eq 0) -and ($r.Output -contains 'ALL SELF-TESTS OK')); Detail = $corpus }
        }
    }
    if ($selected -contains 'docfacts') {
        # backlog #33 tier 1: the identifiers the documents quote against the identifiers the scripts and the shipped
        # configuration define, both directions. Against an extracted package the sop/ documents are not there, so the
        # step drops them rather than failing on a path nobody shipped.
        $docArgs = @('-PackageDir', $PackageDir, '-RepoRoot', $Root)
        if ($PackageDir -ne (Join-Path $Root 'healthcheck')) { $docArgs += '-PackageOnly' }
        Invoke-Case 'docfacts' 'documents' {
            $r = Invoke-TestScript 'doc_facts.ps1' $docArgs 'docfacts'
            $s = Get-SummaryLine $r.Output
            @{ Passed = (($r.ExitCode -eq 0) -and (Test-SummaryClean $s)); Detail = $s }
        }
        Invoke-Case 'docfacts' 'self-test' {
            $r = Invoke-TestScript 'selftest_docfacts.ps1' @('-WorkDir', (Join-Path $WorkDir 'docfacts')) 'docfacts_selftest'
            $s = Get-SummaryLine $r.Output
            @{ Passed = (($r.ExitCode -eq 0) -and ($r.Output -contains 'ALL SELF-TESTS OK')); Detail = $s }
        }
    }
    if ($selected -contains 'unit') {
        foreach ($lang in $Languages) {
            Invoke-Case 'unit' $lang {
                $r = Invoke-TestScript 'unit_tests.ps1' @('-ScriptPath', (Join-Path $PackageDir ($lang + '\NetworkHealthCheck.ps1'))) ('unit_' + $lang)
                $s = Get-SummaryLine $r.Output
                $ok = (($r.ExitCode -eq 0) -and (Test-SummaryClean $s))
                $drift = Test-DocumentedTotal $s '^\|\s*`unit`' '(\d+)\s*×\s*2'
                if ($ok -and $drift) { $ok = $false }
                @{ Passed = $ok; Detail = $(if ($drift) { '{0}; {1}' -f $s, $drift } else { $s }) }
            }
        }
    }
    if ($selected -contains 'report') {
        foreach ($lang in $Languages) {
            Invoke-Case 'report' $lang {
                $dir = Join-Path $WorkDir ('report\' + $lang)
                New-Item -ItemType Directory -Force -Path $dir | Out-Null
                $r = Invoke-TestScript 'report_stage_tests.ps1' @('-ScriptPath', (Join-Path $PackageDir ($lang + '\NetworkHealthCheck.ps1')), '-WorkDir', $dir) ('report_' + $lang)
                $s = Get-SummaryLine $r.Output
                $ok = (($r.ExitCode -eq 0) -and (Test-SummaryClean $s))
                $drift = Test-DocumentedTotal $s '^\|\s*`report`' '(\d+)\s*×\s*2'
                if ($ok -and $drift) { $ok = $false }
                @{ Passed = $ok; Detail = $(if ($drift) { '{0}; {1}' -f $s, $drift } else { $s }) }
            }
        }
    }
    if ($selected -contains 'envguard') {
        foreach ($lang in $Languages) {
            Invoke-Case 'envguard' $lang {
                $r = Invoke-TestScript 'env_guard_check.ps1' @('-ScriptPath', (Join-Path $PackageDir ($lang + '\NetworkHealthCheck.ps1')), '-WorkDir', $WorkDir) ('envguard_' + $lang)
                $s = Get-SummaryLine $r.Output
                $ok = (($r.ExitCode -eq 0) -and (Test-SummaryClean $s))
                $drift = Test-DocumentedTotal $s '^\|\s*`envguard`' '(\d+)\s*×\s*2'
                if ($ok -and $drift) { $ok = $false }
                @{ Passed = $ok; Detail = $(if ($drift) { '{0}; {1}' -f $s, $drift } else { $s }) }
            }
        }
    }
    if ($selected -contains 'launcher') {
        # The six language launchers through every reason they can stop for (backlog #28): the LauncherError.txt they
        # leave suggests the action that fits the reason, not "extract the ZIP" for everything.
        Invoke-Case 'launcher' 'both languages' {
            $r = Invoke-TestScript 'launcher_check.ps1' @('-PackageDir', $PackageDir, '-WorkDir', $WorkDir) 'launcher'
            $s = Get-SummaryLine $r.Output
            @{ Passed = (($r.ExitCode -eq 0) -and (Test-SummaryClean $s)); Detail = $s }
        }
    }
    if ($selected -contains 'campaign') {
        # The acceptance campaign driver's state machine (backlog #24), replayed from answers on an asset built from
        # this checkout: skips with reasons, resume, quit, an unknown scenario, a failing scenario.
        Invoke-Case 'campaign' 'selftest_campaign.ps1' {
            $dir = Join-Path $WorkDir 'campaign'
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
            $r = Invoke-TestScript 'selftest_campaign.ps1' @('-WorkDir', $dir) 'campaign'
            $s = Get-SummaryLine $r.Output
            @{ Passed = (($r.ExitCode -eq 0) -and ($r.Output -contains 'ALL SELF-TESTS OK')); Detail = $s }
        }
    }
    if ($selected -contains 'gui-headless') {
        foreach ($lang in $Languages) {
            foreach ($entry in @('User', 'IT')) {
                Invoke-Case 'gui-headless' ($lang + ' ' + $entry) {
                    $argList = @('-ScriptPath', (Join-Path $PackageDir ($lang + '\NetworkHealthCheck.ps1')))
                    if ($entry -eq 'IT') { $argList += '-Interactive' }
                    $r = Invoke-TestScript 'gui_repro.ps1' $argList ('gui-headless_' + $entry + '_' + $lang)
                    $line = [string]@($r.Output)[0]
                    @{ Passed = (($r.ExitCode -eq 0) -and ($line -match 'Initialize-Gui body OK')); Detail = ($line -replace '^[^:]+:\s*', '') }
                }
            }
        }
    }
    if ($selected -contains 'gui') {
        foreach ($entry in @('User', 'IT')) {
            foreach ($lang in $Languages) {
                Invoke-Case 'gui' ($lang + ' ' + $entry + $(if ($entry -eq 'IT') { ' (config 30 pings / 125 s)' } else { '' })) {
                    $stage = New-StagedCopy -Lang $lang -Name ('gui-' + $entry) -WidenSampling:($entry -eq 'IT')
                    Invoke-WindowRun -Dir $stage -Entry $entry -LogName ('gui_' + $entry + '_' + $lang)
                }
            }
        }
    }
    if ($selected -contains 'acceptance') {
        # The two user runs go through the shipped console launcher (its trailing `pause` reads from NUL); the IT-switches
        # run calls the script directly because the launcher takes no arguments.
        # The second TCP value has no port, so the run drops it: that is the only case in this chain that exercises
        # the dropped-target rows end to end - the weightless row where the result belonged, and the Startup Notice
        # beside it (PR #41, round 11). The first value keeps the unreachable-but-usable half of the case intact.
        $unreachableArgs = @('-ConsoleOnly', '-PingCount', '2', '-SampleSeconds', '2', '-TracerouteHops', '2', '-ExpandDetails', '-PingTarget', 'nhc-no-such-host.invalid', '-TcpTarget', '192.0.2.1:9,8.8.8.8', '-HttpUrl', 'https://nhc-no-such-host.invalid/')
        $unreachableExpect = @{ EntryPoint = 'IT'; ExpandDetails = $true; PingCount = 2; SampleSeconds = 2; TracerouteHops = 2; Overrides = @{ PingCount = 2; SampleSeconds = 2; TracerouteHops = 2 }; ExtraPing = 'nhc-no-such-host.invalid'; ExtraTcp = '192.0.2.1:9'; ExtraHttp = 'https://nhc-no-such-host.invalid/'; AllowUnhealthy = $true; RequireErrorCause = $true }
        $acceptance = @(
            @{ Lang = 'en-US'; Case = 'en-US user (Start-NetworkCheck-Console.cmd)'; Launcher = 'Start-NetworkCheck-Console.cmd'; Expect = @{ EntryPoint = 'User'; ExpandDetails = $false } },
            @{ Lang = 'en-US'; Case = 'en-US IT switches (direct)'; Args = @('-ConsoleOnly', '-PingCount', '6', '-SampleSeconds', '6', '-PingTarget', '8.8.8.8', '-TcpTarget', '1.1.1.1:53', '-TracerouteHops', '4', '-ExpandDetails'); Expect = @{ EntryPoint = 'IT'; ExpandDetails = $true; PingCount = 6; SampleSeconds = 6; TracerouteHops = 4; Overrides = @{ PingCount = 6; SampleSeconds = 6; TracerouteHops = 4 }; ExtraPing = '8.8.8.8'; ExtraTcp = '1.1.1.1:53' } },
            @{ Lang = 'zh-TW'; Case = 'zh-TW user (Start-NetworkCheck-Console.cmd)'; Launcher = 'Start-NetworkCheck-Console.cmd'; Expect = @{ EntryPoint = 'User'; ExpandDetails = $false } },
            # Unreachable on purpose (RFC 2606 .invalid, RFC 5737 TEST-NET-1), so the ping, TCP and HTTP failure paths -
            # and with them the error-code classification of backlog #14 - are executed on every run of the chain: a
            # healthy machine never reaches them otherwise. In both languages, because the cause line exists for the
            # case where the operating system's message is in the other language (backlog #19: an en-US report on a
            # zh-TW system, a zh-TW report on an en-US one), and one of the two happens wherever the chain runs. The
            # verdict is expected to be unhealthy, so -RequireHealthy skips these two cases; everything else about them
            # is asserted as usual.
            @{ Lang = 'en-US'; Case = 'en-US unreachable targets (direct)'; Args = $unreachableArgs; Expect = $unreachableExpect },
            @{ Lang = 'zh-TW'; Case = 'zh-TW unreachable targets (direct)'; Args = $unreachableArgs; Expect = $unreachableExpect }
        )
        foreach ($a in $acceptance) {
            Invoke-Case 'acceptance' $a.Case {
                $stage = New-StagedCopy -Lang $a.Lang -Name 'console'   # refreshed from this checkout on every invocation
                $expect = @{}
                foreach ($k in $a.Expect.Keys) { $expect[$k] = $a.Expect[$k] }
                if (-not $expect.ContainsKey('PingCount')) { $s = Get-ConfigSampling $stage; $expect['PingCount'] = $s.PingCount; $expect['SampleSeconds'] = $s.SampleSeconds }
                $launcherError = Join-Path $stage 'LauncherError.txt'
                if (Test-Path -LiteralPath $launcherError) { Remove-Item -LiteralPath $launcherError -Force }
                $factsBefore = Get-MachineFacts
                $started = Get-Date
                $logName = 'acceptance_' + ($a.Case -replace '[^\w-]', '_')
                if ($a.Launcher) { $r = Invoke-Native $CmdExe @('/s', '/c', ('"' + (Join-Path $stage $a.Launcher) + '" <nul')) $logName }
                else { $r = Invoke-Native $PsExe (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $stage 'NetworkHealthCheck.ps1')) + $a.Args) $logName }
                if ($r.ExitCode -ne 0) { return @{ Passed = $false; Detail = ('exit code ' + $r.ExitCode) } }
                if (Test-Path -LiteralPath $launcherError) { return @{ Passed = $false; Detail = 'the launcher wrote LauncherError.txt' } }
                $json = Get-NewestJson (Join-Path $stage 'Reports') $started
                if ($null -eq $json) { return @{ Passed = $false; Detail = 'exit 0 but no JSON report' } }
                $factsAfter = Get-MachineFacts
                $d = Read-Report $json
                if ($a.Lang -eq 'en-US' -and $a.Expect['EntryPoint'] -eq 'User') { $script:UserReportPath = $json.FullName }
                $resultSet = Test-ResultSetForRun $d (Read-Config $stage) $expect $factsBefore $factsAfter
                $bad = @(Test-ReportExpectations $d $expect) + @($resultSet.Mismatches)
                $detail = 'exit 0; ' + (Format-ReportDetail $d) + $(if ($resultSet.Note) { '; ' + $resultSet.Note } else { '' })
                if ($bad.Count) { $detail = ($bad -join '; ') + ' | ' + $detail }
                @{ Passed = ($bad.Count -eq 0); Detail = $detail }
            }
        }
    }
    if ($selected -contains 'resultset') {
        Invoke-Case 'resultset' 'selftest_resultset.ps1 on the en-US user report' {
            $stage = Join-Path $WorkDir 'stage\console\en-US'
            $report = $script:UserReportPath
            if (-not $report -or -not (Test-Path -LiteralPath $report)) {
                # No acceptance report from this invocation: produce one the same way, through the console launcher on a
                # copy refreshed from this checkout, and take the report written after that launch - never whatever an
                # earlier invocation left in the folder.
                $stage = New-StagedCopy -Lang 'en-US' -Name 'console'
                $started = Get-Date
                $r0 = Invoke-Native $CmdExe @('/s', '/c', ('"' + (Join-Path $stage 'Start-NetworkCheck-Console.cmd') + '" <nul')) 'resultset_report'
                if ($r0.ExitCode -ne 0) { return @{ Passed = $false; Detail = ('no report for the self-check: the console launcher exited with code ' + $r0.ExitCode) } }
                $json = Get-NewestJson (Join-Path $stage 'Reports') $started
                if ($null -eq $json) { return @{ Passed = $false; Detail = 'no report for the self-check: the console launcher wrote no JSON report' } }
                $report = $json.FullName
            }
            $r = Invoke-TestScript 'selftest_resultset.ps1' @('-ReportPath', $report, '-ConfigDir', $stage) 'resultset'
            $s = Get-SummaryLine $r.Output
            $ok = (($r.ExitCode -eq 0) -and (Test-SummaryClean $s))
            $detail = [string]$s
            # The number README.md advertises for this step has gone stale three times in PR #41 - rounds 4, 10
            # and 15 - and every time a reader found it rather than a test. The only honest source for it is the
            # run that just happened, so it is checked here: the last N / N on the resultset row of that table
            # must be what this run reported.
            # Two groups rather than a backreference, because the cell reads 'N / N' and \1 written through a
            # heredoc arrives as chr(1) - the pattern then matches nothing and the guard fails for the wrong
            # reason (PR #41, round 15).
            $drift = Test-DocumentedTotal $detail '^\|\s*`resultset`' '(\d+)\s*/\s*(\d+)'
            if ($ok -and $drift) { $ok = $false; $detail = '{0}; {1}' -f $detail, $drift }
            @{ Passed = $ok; Detail = $detail }
        }
    }
    if ($selected -contains 'package') {
        $zipName = 'NetworkHealthCheck-' + $ToolVersion + '.zip'
        $extracted = Join-Path $WorkDir ('verify\NetworkHealthCheck-' + $ToolVersion)
        Invoke-Case 'package' $zipName {
            $zip = Join-Path $WorkDir $zipName
            $r = Invoke-Native $Python @((Join-Path $PSScriptRoot 'build_asset.py'), $zip) 'package_build'
            if ($r.ExitCode -ne 0) { return @{ Passed = $false; Detail = ('build_asset.py failed: ' + [string]@($r.Output)[-1]) } }
            $sha = [string]@($r.Output | Where-Object { $_ -match '^SHA256:' })[0]
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $verify = Join-Path $WorkDir 'verify'
            if (Test-Path -LiteralPath $verify) { Remove-Item -LiteralPath $verify -Recurse -Force }
            [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $verify)
            $v = Invoke-Native $Python @((Join-Path $extracted 'tools\validate_release.py')) 'package_validate'
            $s = Get-SummaryLine $v.Output
            $detail = ('{0} bytes, {1}; validator run from inside the extracted package: {2}' -f (Get-Item -LiteralPath $zip).Length, $sha, $s)
            @{ Passed = (($v.ExitCode -eq 0) -and (Test-SummaryClean $s)); Detail = $detail }
        }
        if (-not $SkipGui) {
            # The package root's launchers (README_BILINGUAL.md sends users there) open the user entry of their language;
            # the language folders' IT launchers open the IT entry.
            foreach ($root in @(@{ Lang = 'en-US'; Launcher = 'Start-English.cmd' }, @{ Lang = 'zh-TW'; Launcher = 'Start-Traditional-Chinese.cmd' })) {
                Invoke-Case 'package' ($root.Lang + ' user entry from the extracted package root (' + $root.Launcher + ', real window)') {
                    $path = Join-Path $extracted $root.Launcher
                    if (-not (Test-Path -LiteralPath $path)) { return @{ Passed = $false; Detail = ('root launcher not present: ' + $root.Launcher) } }
                    Invoke-WindowRun -Dir (Join-Path $extracted $root.Lang) -Entry 'User' -LogName ('package_gui_root_' + $root.Lang) -LauncherPath $path
                }
            }
            foreach ($lang in $Languages) {
                Invoke-Case 'package' ($lang + ' IT entry from the extracted package (Start-NetworkCheck-IT.cmd, real window)') {
                    if (-not (Test-Path -LiteralPath (Join-Path $extracted $lang))) { return @{ Passed = $false; Detail = 'extracted package not present' } }
                    Invoke-WindowRun -Dir (Join-Path $extracted $lang) -Entry 'IT' -LogName ('package_gui_IT_' + $lang)
                }
            }
        }
    }
}
finally {
    try { [Console]::OutputEncoding = $prevOutputEncoding } catch { }
}

# -------------------- Summary --------------------
$failed = @($Results | Where-Object { $_.Result -ne 'PASS' }).Count
Write-Host ''
$Results | Format-Table -AutoSize -Wrap Step, Case, Result, Seconds, Detail | Out-String -Width 250 | Write-Host
$md = @('| Step | Case | Result | s | Detail |', '|---|---|---|---:|---|') + @($Results | ForEach-Object { '| {0} | {1} | {2} | {3} | {4} |' -f $_.Step, $_.Case, $_.Result, $_.Seconds, ($_.Detail -replace '\|', '\|') })
[IO.File]::WriteAllLines((Join-Path $WorkDir 'summary.md'), [string[]]$md, $Utf8NoBom)
Write-Host ('Summary: {0} passed, {1} failed; {2:n0} s; work dir {3}' -f ($Results.Count - $failed), $failed, ((Get-Date) - $ChainStarted).TotalSeconds, $WorkDir)
exit $failed
