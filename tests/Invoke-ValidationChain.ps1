<#
.SYNOPSIS
    Runs the NetworkHealthCheck validation chain against this checkout (backlog #16).

.DESCRIPTION
    One command reproduces the chain recorded in healthcheck/VALIDATION.md: the Windows PowerShell 5.1 parser, the static
    release validator and the self-test of its two PowerShell guards, the helper unit tests, the report-stage functional
    tests, the headless Initialize-Gui smoke test, the real-window UI Automation run of both entry points, the console
    acceptance runs and, on request, the release-asset round trip (build, extract, validate inside the package, open the
    extracted IT entry through the real window).

    Nothing is written into the repository: every run works on a staged copy of healthcheck/<lang>/ under -WorkDir
    (default %TEMP%\nhc-tests\<timestamp>), where each step's raw output is kept as <step>_<case>.log and the final
    table as summary.md.

.PARAMETER Steps
    Steps to run (parse, validator, guards, unit, report, gui-headless, gui, acceptance, resultset, package);
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
.PARAMETER Python
    The Python 3 command for the validator, the guard self-test and the asset builder.
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
    [string[]]$Steps = @('parse', 'validator', 'guards', 'unit', 'report', 'gui-headless', 'gui', 'acceptance', 'resultset'),
    [switch]$Package,
    [switch]$SkipGui,
    [switch]$RequireHealthy,
    [string]$WorkDir,
    [string]$Python = 'python',
    [int]$GuiTimeoutSeconds = 360
)

$ErrorActionPreference = 'Stop'
$Order = @('parse', 'validator', 'guards', 'unit', 'report', 'gui-headless', 'gui', 'acceptance', 'resultset', 'package')
$Root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$PackageDir = Join-Path $Root 'healthcheck'
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
    # A copy of healthcheck/<lang>/ (files only - never Reports/) under the work dir. -WidenSampling raises PingCount to 30
    # and RetransmissionSampleSeconds to 125 in the copied configuration, above the IT panel's default spinner ranges
    # (1-20 / 1-120): the 1.2.1 fix is that an untouched Start keeps those values instead of clamping them.
    param([string]$Lang, [string]$Name, [switch]$WidenSampling)
    $dst = Join-Path $WorkDir ('stage\' + $Name + '\' + $Lang)
    New-Item -ItemType Directory -Force -Path $dst | Out-Null
    Get-ChildItem -LiteralPath (Join-Path $PackageDir $Lang) -File | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $dst -Force }
    if ($WidenSampling) {
        $cfg = Join-Path $dst 'NetworkHealthCheck.config.json'
        $text = [IO.File]::ReadAllText($cfg)
        $text = [regex]::Replace($text, '"PingCount"\s*:\s*\d+', '"PingCount": 30')
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
function Get-MachineFacts {
    # What the script's snapshot sees, read from the operating system the way Get-NetworkSnapshot does: first
    # Get-NetIPConfiguration (an adapter counts when it is Up and has an IPv4 or IPv6 address; the gateways are those of
    # the adapters with an IPv4 address, which is what AUTO_GATEWAY resolves to); when that cmdlet throws, the script
    # writes a data-source row and falls back to CIM, and when it is missing or returns nothing it falls back without the
    # row - CIM counts every IP-enabled Win32_NetworkAdapterConfiguration and keeps its IPv4 default gateways.
    $facts = @{ ConnectedAdapters = 0; Gateways = @(); Source = 'NetCmdlets'; DataSourceRow = $false; TcpCounters = @{ TCPv4 = $false; TCPv6 = $false } }
    # Which TCP performance-counter classes can be read, the way Get-TcpCounterSnapshot reads them: an instance with the
    # SegmentsSentPersec and SegmentsRetransmittedPersec fields. An unreadable class yields an error row from each of the
    # two samples instead of a result row.
    foreach ($protocol in @('TCPv4', 'TCPv6')) {
        try {
            $counter = @(Get-CimInstance -ClassName ('Win32_PerfRawData_Tcpip_' + $protocol) -ErrorAction Stop | Select-Object -First 1)[0]
            if ($null -ne $counter -and $null -ne $counter.PSObject.Properties['SegmentsSentPersec'] -and $null -ne $counter.PSObject.Properties['SegmentsRetransmittedPersec']) { $facts.TcpCounters[$protocol] = $true }
        }
        catch { }
    }
    $useCim = $true
    if (Get-Command Get-NetIPConfiguration -ErrorAction SilentlyContinue) {
        try {
            $n = 0; $gws = @()
            foreach ($c in @(Get-NetIPConfiguration -ErrorAction Stop)) {
                if ($null -eq $c.NetAdapter -or ([string]$c.NetAdapter.Status) -ne 'Up') { continue }
                $v4 = @($c.IPv4Address | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_.IPAddress) })
                $v6 = @($c.IPv6Address | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_.IPAddress) })
                if ($v4.Count -eq 0 -and $v6.Count -eq 0) { continue }
                $n++
                if ($v4.Count -gt 0) {
                    foreach ($g in @($c.IPv4DefaultGateway)) { if ($null -ne $g -and -not [string]::IsNullOrWhiteSpace([string]$g.NextHop)) { $gws += [string]$g.NextHop } }
                }
            }
            if ($n -gt 0) { $facts.ConnectedAdapters = $n; $facts.Gateways = @($gws | Sort-Object -Unique); $useCim = $false }
        }
        catch { $facts.DataSourceRow = $true }
    }
    if ($useCim) {
        $facts.Source = 'CIM'
        $configs = @(Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -OperationTimeoutSec 8 -ErrorAction SilentlyContinue | Where-Object { $_.IPEnabled })
        $facts.ConnectedAdapters = $configs.Count
        $gws = @()
        foreach ($c in $configs) {
            $ipv4 = @(@($c.IPAddress) | Where-Object { $p = $null; [System.Net.IPAddress]::TryParse([string]$_, [ref]$p) -and $p.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork })
            if ($ipv4.Count -eq 0) { continue }
            foreach ($g in @($c.DefaultIPGateway)) { $p = $null; if ([System.Net.IPAddress]::TryParse([string]$g, [ref]$p) -and $p.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) { $gws += [string]$g } }
        }
        $facts.Gateways = @($gws | Sort-Object -Unique)
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
function Test-ResultSet {
    # The report must carry every row the configuration and the run options call for, and nothing else: one row per
    # configured or extra target, one per enabled IT diagnostic, the fixed rows (configuration, environment, system,
    # adapters, gateway and DNS settings, standard comparison, connectivity group per group, TCPv4 and TCPv6
    # retransmissions), each in its scope. Per-adapter rows depend on the machine, so they must exist and pair up (one
    # counter row per adapter row). A Run-AllChecks that skipped a diagnostic, an unknown or renamed tag, or a missing
    # row for an extra target given as a switch fails here. Returns the mismatches. $Machine (adapters and gateways as
    # the operating system reports them, see Get-MachineFacts) can be injected by the self-test.
    param($Report, $Config, [hashtable]$Expect, [hashtable]$Machine)
    if ($null -eq $Machine) { $Machine = Get-MachineFacts }
    $bad = @()
    $o = $Report.RunOptions
    $pingTargets = @($Config.Tests.PingTargets)
    $gatewayTargets = @($pingTargets | Where-Object { [string]$_.Address -eq 'AUTO_GATEWAY' }).Count
    $gateways = @($Machine.Gateways)
    $connected = [int]$Machine.ConnectedAdapters
    $tcpCounters = $Machine.TcpCounters
    if ($null -eq $tcpCounters) { $tcpCounters = @{ TCPv4 = $true; TCPv6 = $true } }
    # One connectivity-group row per group named on a TCP or HTTP target or listed in RequiredConnectivityGroups (a
    # required group without targets gets its own "no executable items" row), the way Test-ConnectivityTargets writes them.
    $groupKeys = @{}
    foreach ($t in @(@($Config.Tests.TcpTargets) + @($Config.Tests.HttpTargets))) { $g = [string]$t.Group; if (-not [string]::IsNullOrWhiteSpace($g)) { $groupKeys[$g] = $true } }
    $requiredGroups = @(@($Config.Tests.RequiredConnectivityGroups) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
    $groups = @(@(@($groupKeys.Keys) + $requiredGroups) | Select-Object -Unique)
    $rules = Get-StandardRuleCount $Config
    $want = [ordered]@{
        'config-file' = 1; 'config' = 1; 'environment' = 1; 'system' = 1; 'adapters' = 1
        'data-source' = $(if ([bool]$Machine.DataSourceRow) { 1 } else { 0 })   # the CIM fallback's warning row, only when the cmdlets threw
        # Without a connected adapter the snapshot writes the aggregate adapters row only: no gateway or DNS settings rows.
        'gateway-config' = $(if ($connected -gt 0) { 1 } else { 0 })
        'dns-config' = $(if ($connected -gt 0) { 1 } else { 0 })
        # One row per configured standard rule; one informational row without rules; one failure row without adapters.
        'expected-standard' = $(if ($rules -eq 0 -or $connected -eq 0) { 1 } else { $rules })
        'ping-gateway' = $gatewayTargets * [math]::Max(1, $gateways.Count)   # one row per resolved gateway, or one "no target" row
        'ping-target' = ($pingTargets.Count - $gatewayTargets) + (Get-Count $o.ExtraTargets.Ping)
        'dns' = (Get-Count $Config.Tests.DnsNames) + (Get-Count $o.ExtraTargets.Dns)
        'tcp' = (Get-Count $Config.Tests.TcpTargets) + (Get-Count $o.ExtraTargets.Tcp)
        'http' = (Get-Count $Config.Tests.HttpTargets) + (Get-Count $o.ExtraTargets.Http)
        'connectivity-group' = $groups.Count
        # One result row per readable TCP counter class, two error rows (one per sample) per unreadable one.
        'tcp-retransmissions' = $(if ([bool]$tcpCounters.TCPv4) { 1 } else { 2 }) + $(if ([bool]$tcpCounters.TCPv6) { 1 } else { 2 })
    }
    # The IT diagnostics to expect come from the configuration and the launch switches (-NoWifi / -NoTraceroute as
    # Expect['NoWifi'] / Expect['NoTraceroute']), never from the report under test; the report's own ChecksEnabled must
    # agree with them.
    $itTags = [ordered]@{ 'wifi' = (Test-TrueFlag $Config.Checks.WifiRf); 'routes' = (Test-TrueFlag $Config.Checks.RouteTable); 'gateway-neighbor' = (Test-TrueFlag $Config.Checks.GatewayNeighbor); 'proxy' = (Test-TrueFlag $Config.Checks.ProxySettings); 'traceroute' = (Test-TrueFlag $Config.Checks.Traceroute); 'drivers' = (Test-TrueFlag $Config.Checks.DriverInfo) }
    if ($Expect['NoWifi'] -eq $true) { $itTags['wifi'] = $false }
    if ($Expect['NoTraceroute'] -eq $true) { $itTags['traceroute'] = $false }
    $reported = @{ 'wifi' = $o.ChecksEnabled.WifiRf; 'routes' = $o.ChecksEnabled.RouteTable; 'gateway-neighbor' = $o.ChecksEnabled.GatewayNeighbor; 'proxy' = $o.ChecksEnabled.ProxySettings; 'traceroute' = $o.ChecksEnabled.Traceroute; 'drivers' = $o.ChecksEnabled.DriverInfo }
    foreach ($k in @($itTags.Keys)) {
        if ([bool]$reported[$k] -ne [bool]$itTags[$k]) { $bad += ('ChecksEnabled for {0} reported as {1}, expected {2} from the configuration and the switches' -f $k, $reported[$k], $itTags[$k]) }
        $want[$k] = $(if ($itTags[$k]) { 1 } else { 0 })
    }
    $rows = @($Report.Results)
    $byTag = @{}
    foreach ($r in $rows) { $t = [string]$r.Tag; if (-not $byTag.ContainsKey($t)) { $byTag[$t] = 0 }; $byTag[$t]++ }
    foreach ($k in @($want.Keys)) {
        $have = $(if ($byTag.ContainsKey($k)) { $byTag[$k] } else { 0 })
        if ($have -ne $want[$k]) { $bad += ('{0}: {1} row(s), expected {2}' -f $k, $have, $want[$k]) }
    }
    $adapters = $(if ($byTag.ContainsKey('adapter')) { $byTag['adapter'] } else { 0 })
    $counters = $(if ($byTag.ContainsKey('adapter-errors')) { $byTag['adapter-errors'] } else { 0 })
    if ($connected -gt 0) {
        # One adapter row per connected adapter with an address, and one counter row per adapter row.
        if ($adapters -ne $connected) { $bad += ('adapter: {0} row(s), expected one per connected adapter with an address ({1})' -f $adapters, $connected) }
        if ($counters -ne $adapters) { $bad += ('adapter-errors: {0} row(s), expected one per adapter row ({1})' -f $counters, $adapters) }
    }
    else {
        # The zero-adapter shape: the aggregate adapters row fails, there are no adapter rows, and the counter rows come
        # from whatever the counter sample named, so their number is not constrained.
        if ($adapters -ne 0) { $bad += ('adapter: {0} row(s) although the machine has no connected adapter with an address' -f $adapters) }
        $aggregate = @($rows | Where-Object { $_.Tag -eq 'adapters' })
        if ($aggregate.Count -eq 1 -and [string]$aggregate[0].Status -ne 'FAIL') { $bad += ('adapters row is {0}, expected FAIL with no connected adapter' -f $aggregate[0].Status) }
    }
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
    foreach ($protocol in @('TCPv4', 'TCPv6')) {
        if (@($rows | Where-Object { $_.Tag -eq 'tcp-retransmissions' -and (([string]$_.Check) -like ('*' + $protocol + '*')) }).Count -eq 0) { $bad += ('no tcp-retransmissions row for {0}' -f $protocol) }
    }
    foreach ($pair in @(@('ExtraPing', 'ping-target'), @('ExtraTcp', 'tcp'))) {
        if ($Expect.ContainsKey($pair[0]) -and @($rows | Where-Object { $_.Tag -eq $pair[1] -and (($_.Check + ' ' + $_.Message) -like ('*' + $Expect[$pair[0]] + '*')) }).Count -eq 0) { $bad += ('no {0} row for {1}' -f $pair[1], $Expect[$pair[0]]) }
    }
    return $bad
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
    if ($Expect.ContainsKey('ExtraPing') -and (@($Report.RunOptions.ExtraTargets.Ping) -notcontains $Expect['ExtraPing'])) { $bad += ('extra ping target {0} missing' -f $Expect['ExtraPing']) }
    if ($Expect.ContainsKey('ExtraTcp') -and (@($Report.RunOptions.ExtraTargets.Tcp) -notcontains $Expect['ExtraTcp'])) { $bad += ('extra TCP target {0} missing' -f $Expect['ExtraTcp']) }
    if ([string]$Report.SchemaVersion -ne '2') { $bad += ('SchemaVersion={0} (expected 2)' -f $Report.SchemaVersion) }
    if ($RequireHealthy -and ([string]$Report.Overall.Code -ne 'PASS')) { $bad += ('Overall {0}, not PASS' -f $Report.Overall.Code) }
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
    $started = Get-Date
    $argList = @('-PackageDir', $Dir, '-Entry', $Entry, '-Via', 'Launcher', '-TimeoutSeconds', $GuiTimeoutSeconds)
    if ($LauncherPath) { $argList += @('-LauncherPath', $LauncherPath) }
    $r = Invoke-TestScript 'gui_check.ps1' $argList $LogName
    if ($r.ExitCode -ne 0) { return @{ Passed = $false; Detail = ('exit code {0}: {1}' -f $r.ExitCode, [string]@($r.Output | Where-Object { $_ -match 'ERROR' })[0]) } }
    $json = Get-NewestJson (Join-Path $Dir 'Reports') $started
    if ($null -eq $json) { return @{ Passed = $false; Detail = 'exit 0 but no JSON report' } }
    $d = Read-Report $json
    $bad = @(Test-ReportExpectations $d $expect) + @(Test-ResultSet $d (Read-Config $Dir) $expect)
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
    $detail = (Format-ReportDetail $d) + '; ' + ($window -replace '^\[[^\]]+\]\s*', '') + $(if ($launcherLine) { '; via ' + $launcherLine } else { '' })
    if ($bad.Count) { $detail = ($bad -join '; ') + ' | ' + $detail }
    return @{ Passed = ($bad.Count -eq 0); Detail = $detail }
}

# -------------------- The chain --------------------
$prevOutputEncoding = [Console]::OutputEncoding
try { [Console]::OutputEncoding = $Utf8NoBom } catch { }
$env:PYTHONUTF8 = '1'; $env:PYTHONIOENCODING = 'utf-8'
try {
    $ToolVersion = Read-ToolVersion
    $gitHead = [string]@((Invoke-Native 'git' @('-C', $Root, 'rev-parse', '--short', 'HEAD') 'env_git').Output)[0]
    $dirty = @((Invoke-Native 'git' @('-C', $Root, 'status', '--porcelain', '--', 'healthcheck') 'env_git_status').Output | Where-Object { $_ })
    $pythonVersion = [string]@((Invoke-Native $Python @('--version') 'env_python').Output)[0]
    Write-Host ('NetworkHealthCheck {0} validation chain - {1}' -f $ToolVersion, (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    Write-Host ('  checkout {0} at {1}{2}' -f $Root, $gitHead, $(if ($dirty.Count) { ' (healthcheck/ has uncommitted changes)' } else { '' }))
    Write-Host ('  {0}; Windows PowerShell {1}; {2}' -f [Environment]::OSVersion.VersionString, $PSVersionTable.PSVersion, $pythonVersion)
    Write-Host ('  steps: {0}; work dir: {1}' -f ($selected -join ', '), $WorkDir)

    if ($selected -contains 'parse') {
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
        Invoke-Case 'guards' 'validate_release.py' {
            $r = Invoke-Native $Python @((Join-Path $PSScriptRoot 'selftest_guards.py')) 'guards'
            $corpus = [string]@($r.Output | Where-Object { $_ -match '^corpus:' })[0]
            @{ Passed = (($r.ExitCode -eq 0) -and ($r.Output -contains 'ALL SELF-TESTS OK')); Detail = $corpus }
        }
    }
    if ($selected -contains 'unit') {
        foreach ($lang in $Languages) {
            Invoke-Case 'unit' $lang {
                $r = Invoke-TestScript 'unit_tests.ps1' @('-ScriptPath', (Join-Path $PackageDir ($lang + '\NetworkHealthCheck.ps1'))) ('unit_' + $lang)
                $s = Get-SummaryLine $r.Output
                @{ Passed = (($r.ExitCode -eq 0) -and (Test-SummaryClean $s)); Detail = $s }
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
                @{ Passed = (($r.ExitCode -eq 0) -and (Test-SummaryClean $s)); Detail = $s }
            }
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
        $acceptance = @(
            @{ Lang = 'en-US'; Case = 'en-US user (Start-NetworkCheck-Console.cmd)'; Launcher = 'Start-NetworkCheck-Console.cmd'; Expect = @{ EntryPoint = 'User'; ExpandDetails = $false } },
            @{ Lang = 'en-US'; Case = 'en-US IT switches (direct)'; Args = @('-ConsoleOnly', '-PingCount', '6', '-SampleSeconds', '6', '-PingTarget', '8.8.8.8', '-TcpTarget', '1.1.1.1:53', '-TracerouteHops', '4', '-ExpandDetails'); Expect = @{ EntryPoint = 'IT'; ExpandDetails = $true; PingCount = 6; SampleSeconds = 6; TracerouteHops = 4; ExtraPing = '8.8.8.8'; ExtraTcp = '1.1.1.1:53' } },
            @{ Lang = 'zh-TW'; Case = 'zh-TW user (Start-NetworkCheck-Console.cmd)'; Launcher = 'Start-NetworkCheck-Console.cmd'; Expect = @{ EntryPoint = 'User'; ExpandDetails = $false } }
        )
        foreach ($a in $acceptance) {
            Invoke-Case 'acceptance' $a.Case {
                $stage = Join-Path $WorkDir ('stage\console\' + $a.Lang)
                if (-not (Test-Path -LiteralPath $stage)) { $stage = New-StagedCopy -Lang $a.Lang -Name 'console' }
                $expect = @{}
                foreach ($k in $a.Expect.Keys) { $expect[$k] = $a.Expect[$k] }
                if (-not $expect.ContainsKey('PingCount')) { $s = Get-ConfigSampling $stage; $expect['PingCount'] = $s.PingCount; $expect['SampleSeconds'] = $s.SampleSeconds }
                $launcherError = Join-Path $stage 'LauncherError.txt'
                if (Test-Path -LiteralPath $launcherError) { Remove-Item -LiteralPath $launcherError -Force }
                $started = Get-Date
                $logName = 'acceptance_' + ($a.Case -replace '[^\w-]', '_')
                if ($a.Launcher) { $r = Invoke-Native $CmdExe @('/s', '/c', ('"' + (Join-Path $stage $a.Launcher) + '" <nul')) $logName }
                else { $r = Invoke-Native $PsExe (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $stage 'NetworkHealthCheck.ps1')) + $a.Args) $logName }
                if ($r.ExitCode -ne 0) { return @{ Passed = $false; Detail = ('exit code ' + $r.ExitCode) } }
                if (Test-Path -LiteralPath $launcherError) { return @{ Passed = $false; Detail = 'the launcher wrote LauncherError.txt' } }
                $json = Get-NewestJson (Join-Path $stage 'Reports') $started
                if ($null -eq $json) { return @{ Passed = $false; Detail = 'exit 0 but no JSON report' } }
                $d = Read-Report $json
                $bad = @(Test-ReportExpectations $d $expect) + @(Test-ResultSet $d (Read-Config $stage) $expect)
                $detail = 'exit 0; ' + (Format-ReportDetail $d)
                if ($bad.Count) { $detail = ($bad -join '; ') + ' | ' + $detail }
                @{ Passed = ($bad.Count -eq 0); Detail = $detail }
            }
        }
    }
    if ($selected -contains 'resultset') {
        Invoke-Case 'resultset' 'selftest_resultset.ps1 on the en-US user report' {
            $stage = Join-Path $WorkDir 'stage\console\en-US'
            $reports = Join-Path $stage 'Reports'
            if (@(Get-ChildItem -LiteralPath $reports -Filter '*.json' -ErrorAction SilentlyContinue).Count -eq 0) {
                # No acceptance report in this work dir: produce one the same way, through the console launcher.
                if (-not (Test-Path -LiteralPath $stage)) { $stage = New-StagedCopy -Lang 'en-US' -Name 'console' }
                $r0 = Invoke-Native $CmdExe @('/s', '/c', ('"' + (Join-Path $stage 'Start-NetworkCheck-Console.cmd') + '" <nul')) 'resultset_report'
                if ($r0.ExitCode -ne 0) { return @{ Passed = $false; Detail = ('no report for the self-check: the console launcher exited with code ' + $r0.ExitCode) } }
            }
            $r = Invoke-TestScript 'selftest_resultset.ps1' @('-ReportDir', $reports, '-ConfigDir', $stage) 'resultset'
            $s = Get-SummaryLine $r.Output
            @{ Passed = (($r.ExitCode -eq 0) -and (Test-SummaryClean $s)); Detail = $s }
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
