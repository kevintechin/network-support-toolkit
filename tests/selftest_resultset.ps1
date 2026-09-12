param([string]$ReportPath, [string]$ReportDir, [string]$ConfigDir)
# Negative self-check of the runner's result-set assertion (Test-ResultSet in Invoke-ValidationChain.ps1): the helper
# functions are lifted out of the runner by AST; a real report from an earlier run must pass intact against the real
# machine facts (the positive control); and a fixture normalised out of that report - three adapter rows and three counter
# rows, one gateway row naming a synthetic TEST-NET gateway, gateway and DNS settings rows, one TCPv4 and one TCPv6
# retransmission row, no data-source row, a passing aggregate row - is checked against fixed synthetic facts: intact it
# must be clean, and every tampered variant must be reported (a row removed, a rogue tag, an IT row moved to the Main
# scope, an extra-target row expected but absent, the counter rows removed, an empty set, a diagnostic dropped by the run
# and by ChecksEnabled alike, a gateway row naming another address, the zero-adapter shape on a machine with adapters,
# two configured standard rules against one row, a required connectivity group without targets, the CIM fallback's
# data-source row missing, three retransmission rows with both counter classes readable, a protocol never named), while
# the zero-adapter shape on a machine without a connected adapter, a present data-source row after a cmdlet failure and
# the TCPv6 error rows with the TCPv6 class unreadable, the four error rows and no step error with neither TCP class
# readable, and the two step-error rows and one aggregate counter row without adapter statistics are accepted. Nothing
# depends on the connectivity of the machine.
#   -ReportPath: the JSON report to use (the runner passes the en-US user report the acceptance step produced)
#   -ReportDir:  for manual use instead of -ReportPath - the newest user-entry report in that Reports folder
#   -ConfigDir:  the folder holding the NetworkHealthCheck.config.json that run used
# Example: tests\selftest_resultset.ps1 -ReportPath <work dir>\stage\console\en-US\Reports\<report>.json -ConfigDir <work dir>\stage\console\en-US
$ErrorActionPreference = 'Stop'
$runner = Join-Path $PSScriptRoot 'Invoke-ValidationChain.ps1'
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($runner, [ref]$tokens, [ref]$errors)
foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in @('Read-Config', 'Get-Count', 'Test-TrueFlag', 'Get-CimOrWmiInstance', 'Add-PrimaryFacts', 'Get-MachineFacts', 'Get-StandardRuleCount', 'Test-ResultSet', 'ConvertTo-FactsKey', 'Test-ResultSetForRun', 'Get-Value', 'Get-ConfigRowCount', 'Get-TargetRowCount', 'Test-ConfiguredTcpTarget', 'Test-ConfiguredHttpTarget', 'Test-ConfiguredPingAddress', 'Test-UsableIPAddress', 'Test-ConfiguredDnsTarget', 'Test-ConfiguredDnsRequired', 'Get-UnusablePingExtraRows', 'Get-ConfigConverterSource', 'Get-WlanInterfaceIds') }, $true)) { Invoke-Expression $f.Extent.Text }
$machine = Get-MachineFacts
"machine: $($machine.ConnectedAdapters) connected adapter(s) with an address, gateway(s) $(@($machine.Gateways) -join ', '), source $($machine.Source), TCP counters v4=$($machine.TcpCounters.TCPv4) v6=$($machine.TcpCounters.TCPv6)"
foreach ($converterSource in (Get-ConfigConverterSource (Join-Path $ConfigDir 'NetworkHealthCheck.ps1'))) { Invoke-Expression $converterSource }
$cfg = Read-Config $ConfigDir
if ($ReportPath) { $json = Get-Item -LiteralPath $ReportPath }
else {
    # Manual use: the newest report of the user entry in the folder (an IT-entry report has extra rows the fixture does not model).
    $json = @(Get-ChildItem -LiteralPath $ReportDir -Filter '*.json' | Sort-Object LastWriteTime -Descending | Where-Object { ((Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json).RunOptions.EntryPoint) -eq 'User' } | Select-Object -First 1)[0]
}
if ($null -eq $json) { "no user-entry JSON report to use (-ReportPath / -ReportDir)"; exit 1 }
$text = Get-Content -LiteralPath $json.FullName -Raw -Encoding UTF8
function Load { $text | ConvertFrom-Json }

# The fixture and its facts.
$facts = @{ ConnectedAdapters = 3; Gateways = @('192.0.2.1'); DnsServers = @(); Source = 'NetCmdlets'; DataSourceRow = $false; SnapshotStepFailed = $false; TcpCounters = @{ TCPv4 = $true; TCPv6 = $true }; AdapterStatistics = $true; WifiInterfaces = 1; WlanInterfaces = 1; WlanInterfaceIds = @('e6b08c8a-3feb-4c3e-88c3-dee94dd2f0eb') }
function New-Row($Template, [string]$Tag, [string]$Check, [string]$Status, [string]$Scope = 'Main') {
    $row = $Template.PSObject.Copy(); $row.Tag = $Tag; $row.Check = $Check; $row.Status = $Status; $row.Scope = $Scope; $row.Message = 'fixture row'; return $row
}
function New-Fixture {
    $r = Load
    $template = $r.Results[0]
    # Environment-dependent rows are dropped and rebuilt, step-error rows included: the fixture's facts declare every
    # collector healthy, whatever the live machine had to say.
    $rows = @($r.Results | Where-Object { $_.Tag -notin @('adapter', 'adapter-errors', 'gateway-config', 'dns-config', 'ping-gateway', 'tcp-retransmissions', 'data-source', 'step-error', 'wifi-retry') })
    foreach ($x in $rows) { if ($x.Tag -eq 'adapters') { $x.Status = 'PASS' } }
    foreach ($i in 1..3) { $rows += New-Row $template 'adapter' "Adapter: fixture $i" 'PASS' }
    $rows += New-Row $template 'gateway-config' 'Default Gateway' 'PASS'
    $rows += New-Row $template 'dns-config' 'DNS Servers' 'PASS'
    $rows += New-Row $template 'ping-gateway' 'Default Gateway: 192.0.2.1' 'PASS'
    foreach ($i in 1..3) { $rows += New-Row $template 'adapter-errors' "fixture $i" 'PASS' }
    $rows += New-Row $template 'tcp-retransmissions' 'TCPv4' 'PASS'
    $rows += New-Row $template 'tcp-retransmissions' 'TCPv6' 'INFO'
    # The live wifi-retry row names the live machine's interface GUID (PR #52, round 8), so it is dropped above and
    # rebuilt here for the fixture's one wireless interface, whose GUID the synthetic facts declare.
    $retry = New-Row $template 'wifi-retry' 'Wireless retries' 'INFO'; $retry.Weightless = $true; $retry.Details = 'Connection state: connected at the start, connected at the end.' + [Environment]::NewLine + 'Interface GUID: e6b08c8a-3feb-4c3e-88c3-dee94dd2f0eb'
    $rows += $retry
    $r.Results = $rows
    return $r
}
function With($Facts, [hashtable]$Changes) { $copy = @{}; foreach ($k in $Facts.Keys) { $copy[$k] = $Facts[$k] }; foreach ($k in $Changes.Keys) { $copy[$k] = $Changes[$k] }; return $copy }

$fails = 0; $passes = 0
function Assert-Case([string]$Name, [string[]]$Mismatches, [bool]$ExpectClean, [string]$MustMention) {
    $clean = ($Mismatches.Count -eq 0)
    $ok = ($clean -eq $ExpectClean) -and ($ExpectClean -or ($Mismatches -join '; ') -like ('*' + $MustMention + '*'))
    if ($ok) { $script:passes++; "[PASS] $Name -> " + $(if ($clean) { 'clean' } else { $Mismatches -join '; ' }) }
    else { $script:fails++; "[FAIL] $Name -> " + $(if ($clean) { 'clean' } else { $Mismatches -join '; ' }) + " (expected " + $(if ($ExpectClean) { 'clean' } else { "a mismatch mentioning '$MustMention'" }) + ")" }
}
"report $($json.Name): $(@((Load).Results).Count) rows, EntryPoint $((Load).RunOptions.EntryPoint); fixture: $(@((New-Fixture).Results).Count) rows"
$r = Load; Assert-Case 'live report against the real machine facts (positive control)' @(Test-ResultSet $r $cfg @{}) $true ''
$r = New-Fixture; Assert-Case 'fixture against the synthetic facts' @(Test-ResultSet $r $cfg @{} $facts) $true ''
$r = New-Fixture; $r.Results = @($r.Results | Where-Object { $_.Tag -ne 'dns' }); Assert-Case 'dns row removed' @(Test-ResultSet $r $cfg @{} $facts) $false 'dns: 0 row(s)'
$r = New-Fixture; $rogue = $r.Results[0].PSObject.Copy(); $rogue.Tag = 'bogus'; $r.Results = @($r.Results) + @($rogue); Assert-Case 'rogue tag added' @(Test-ResultSet $r $cfg @{} $facts) $false 'unexpected tag(s): bogus'
$r = New-Fixture; foreach ($x in $r.Results) { if ($x.Tag -eq 'routes') { $x.Scope = 'Main' } }; Assert-Case 'routes row moved to the Main scope' @(Test-ResultSet $r $cfg @{} $facts) $false 'routes row in scope Main'
$r = New-Fixture; Assert-Case 'extra ping target expected but absent' @(Test-ResultSet $r $cfg @{ ExtraPing = '9.9.9.9' } $facts) $false 'no ping-target row for 9.9.9.9'
$r = New-Fixture; $r.Results = @($r.Results | Where-Object { $_.Tag -ne 'adapter-errors' }); Assert-Case 'every adapter counter row removed' @(Test-ResultSet $r $cfg @{} $facts) $false 'adapter-errors: 0 row(s)'
$r = New-Fixture; $r.Results = @(); Assert-Case 'empty result set' @(Test-ResultSet $r $cfg @{} $facts) $false 'adapters: 0 row(s)'
$r = New-Fixture; $r.RunOptions.ChecksEnabled.WifiRf = $false; $r.Results = @($r.Results | Where-Object { $_.Tag -ne 'wifi' }); Assert-Case 'Wi-Fi diagnostic dropped by the run and by ChecksEnabled alike' @(Test-ResultSet $r $cfg @{} $facts) $false 'ChecksEnabled for wifi reported as False'
$r = New-Fixture; foreach ($x in $r.Results) { if ($x.Tag -eq 'ping-gateway') { $x.Check = 'Default Gateway: 10.255.255.254' } }; Assert-Case 'ping-gateway row naming an address that is not a gateway of the machine' @(Test-ResultSet $r $cfg @{} $facts) $false 'not a default gateway of this machine (192.0.2.1)'
# The zero-adapter shape (all adapters disabled or disconnected): the aggregate adapters row fails and there are no
# adapter, gateway-config or dns-config rows; counter rows may still name whatever the counter sample saw. Legitimate on a
# machine without a connected adapter, a regression on a machine with three.
function ConvertTo-ZeroAdapterShape($Report) {
    $Report.Results = @($Report.Results | Where-Object { $_.Tag -notin @('adapter', 'gateway-config', 'dns-config') })
    foreach ($x in $Report.Results) { if ($x.Tag -eq 'adapters') { $x.Status = 'FAIL' } }
    return $Report
}
$r = ConvertTo-ZeroAdapterShape (New-Fixture); Assert-Case 'zero-adapter shape on a machine without a connected adapter' @(Test-ResultSet $r $cfg @{} (With $facts @{ ConnectedAdapters = 0; Gateways = @() })) $true ''
$r = ConvertTo-ZeroAdapterShape (New-Fixture); Assert-Case 'zero-adapter shape on a machine with connected adapters' @(Test-ResultSet $r $cfg @{} $facts) $false 'expected one per connected adapter with an address'
$r = New-Fixture; $cfg2 = Read-Config $ConfigDir; $cfg2.Expected.RequiredDnsServers = @('192.0.2.53'); $cfg2.Expected.AllowedDefaultGateways = @('192.0.2.1'); Assert-Case 'two standard rules configured but one standard row' @(Test-ResultSet $r $cfg2 @{} $facts) $false 'expected-standard: 1 row(s), expected 2'
# A required connectivity group without targets gets its own row; a configuration that requires two groups expects two.
$r = New-Fixture; $cfg3 = Read-Config $ConfigDir; $cfg3.Tests.RequiredConnectivityGroups = @('Internet', 'Intranet'); Assert-Case 'a required group without targets expects its own row' @(Test-ResultSet $r $cfg3 @{} $facts) $false 'connectivity-group: 1 row(s), expected 2'
# The CIM fallback after a cmdlet failure writes a data-source row; the facts say so, the report must carry exactly one.
$cimFacts = With $facts @{ Source = 'CIM'; DataSourceRow = $true }
$r = New-Fixture; Assert-Case 'facts from the CIM fallback after a cmdlet failure, report without the data-source row' @(Test-ResultSet $r $cfg @{} $cimFacts) $false 'data-source: 0 row(s), expected 1'
$r = New-Fixture; $r.Results = @($r.Results) + @(New-Row $r.Results[0] 'data-source' 'Data Source Fallback' 'WARN'); Assert-Case 'facts from the CIM fallback after a cmdlet failure, report with the data-source row' @(Test-ResultSet $r $cfg @{} $cimFacts) $true ''
# An unreadable TCP counter class yields an error row from each sample instead of a result row.
function ConvertTo-TcpV6Unreadable($Report) {
    $Report.Results = @($Report.Results | Where-Object { -not ($_.Tag -eq 'tcp-retransmissions' -and $_.Check -eq 'TCPv6') })
    foreach ($i in 1..2) { $Report.Results = @($Report.Results) + @(New-Row $Report.Results[0] 'tcp-retransmissions' 'TCPv6 counters' 'ERROR') }
    return $Report
}
$r = ConvertTo-TcpV6Unreadable (New-Fixture); Assert-Case 'TCPv6 counters unreadable: two error rows, facts agree' @(Test-ResultSet $r $cfg @{} (With $facts @{ TcpCounters = @{ TCPv4 = $true; TCPv6 = $false } })) $true ''
$r = ConvertTo-TcpV6Unreadable (New-Fixture); Assert-Case 'three retransmission rows with both counter classes readable' @(Test-ResultSet $r $cfg @{} $facts) $false 'tcp-retransmissions: 3 row(s), expected 2'
$r = New-Fixture; foreach ($x in $r.Results) { if ($x.Tag -eq 'tcp-retransmissions') { $x.Check = 'TCPv4' } }; Assert-Case 'TCPv4 named twice, TCPv6 never' @(Test-ResultSet $r $cfg @{} $facts) $false 'no tcp-retransmissions row for TCPv6'
# With neither TCP counter class readable the baseline is no longer thrown away (backlog #38): each sample writes one
# error row per class - four in all - and there is no step-error row for the baseline step at all.
function ConvertTo-TcpUnreadable($Report) {
    $Report.Results = @($Report.Results | Where-Object { $_.Tag -ne 'tcp-retransmissions' })
    foreach ($protocol in @('TCPv4', 'TCPv6')) {
        foreach ($i in 1..2) { $Report.Results = @($Report.Results) + @(New-Row $Report.Results[0] 'tcp-retransmissions' ($protocol + ' counters') 'ERROR') }
    }
    return $Report
}
$r = ConvertTo-TcpUnreadable (New-Fixture); Assert-Case 'neither TCP counter class readable: four error rows and no step error, facts agree' @(Test-ResultSet $r $cfg @{} (With $facts @{ TcpCounters = @{ TCPv4 = $false; TCPv6 = $false } })) $true ''
$r = ConvertTo-TcpUnreadable (New-Fixture); Assert-Case 'the same shape with both counter classes readable' @(Test-ResultSet $r $cfg @{} $facts) $false 'tcp-retransmissions: 4 row(s), expected 2'
# And the shape 1.2.7 produced - the baseline step failing and one generic row for the pair - is now a report the
# facts do not explain, whatever the counters did.
$r = New-Fixture
$r.Results = @($r.Results | Where-Object { $_.Tag -ne 'tcp-retransmissions' })
$r.Results = @($r.Results) + @((New-Row $r.Results[0] 'step-error' 'Get TCP Retransmission Baseline' 'ERROR'), (New-Row $r.Results[0] 'tcp-retransmissions' 'System Counters' 'ERROR'))
Assert-Case 'the pre-1.2.8 shape with neither class readable' @(Test-ResultSet $r $cfg @{} (With $facts @{ TcpCounters = @{ TCPv4 = $false; TCPv6 = $false } })) $false 'step-error: 1 row(s), expected 0'
# Without adapter statistics both sampling steps fail (two step-error rows) and the analysis writes one aggregate row.
function ConvertTo-NoAdapterStatistics($Report) {
    $Report.Results = @($Report.Results | Where-Object { $_.Tag -ne 'adapter-errors' })
    $Report.Results = @($Report.Results) + @((New-Row $Report.Results[0] 'step-error' 'Get Network Adapter Error Baseline' 'ERROR'), (New-Row $Report.Results[0] 'step-error' 'Get Ending Network Adapter Error Values' 'ERROR'), (New-Row $Report.Results[0] 'adapter-errors' 'Before/After Comparison' 'ERROR'))
    return $Report
}
$r = ConvertTo-NoAdapterStatistics (New-Fixture); Assert-Case 'adapter statistics unavailable: two step-error rows and the aggregate row, facts agree' @(Test-ResultSet $r $cfg @{} (With $facts @{ AdapterStatistics = $false })) $true ''
$r = ConvertTo-NoAdapterStatistics (New-Fixture); Assert-Case 'the same shape with adapter statistics available (one failed sample would explain one step error, not two)' @(Test-ResultSet $r $cfg @{} $facts) $false 'step-error: 2 row(s), expected 1'
$r = New-Fixture; $r.Results = @($r.Results) + @(New-Row $r.Results[0] 'step-error' 'Collect IT diagnostics' 'ERROR' 'IT'); Assert-Case 'a step-error row the facts do not explain' @(Test-ResultSet $r $cfg @{} $facts) $false 'step-error: 1 row(s), expected 0'
# An AUTO_DNS ping target expands to one row per DNS server of the primary adapters.
$cfg4 = Read-Config $ConfigDir; $cfg4.Tests.PingTargets = @($cfg4.Tests.PingTargets) + @([pscustomobject]@{ Name = 'DNS servers'; Address = 'AUTO_DNS'; Required = $false })
$dnsFacts = With $facts @{ DnsServers = @('192.0.2.53', '192.0.2.54') }
$r = New-Fixture; Assert-Case 'AUTO_DNS target against two DNS servers, rows missing' @(Test-ResultSet $r $cfg4 @{} $dnsFacts) $false 'ping-target: 1 row(s), expected 3'
$r = New-Fixture; $r.Results = @($r.Results) + @((New-Row $r.Results[0] 'ping-target' 'DNS servers: 192.0.2.53' 'PASS'), (New-Row $r.Results[0] 'ping-target' 'DNS servers: 192.0.2.54' 'PASS')); Assert-Case 'AUTO_DNS target against two DNS servers, one row each' @(Test-ResultSet $r $cfg4 @{} $dnsFacts) $true ''
# A multihomed machine: one ping-gateway row and one gateway-neighbor row per resolved gateway.
$twoGateways = With $facts @{ Gateways = @('192.0.2.1', '192.0.2.2') }
$r = New-Fixture; $r.Results = @($r.Results) + @((New-Row $r.Results[0] 'ping-gateway' 'Default Gateway: 192.0.2.2' 'PASS'), (New-Row $r.Results[0] 'gateway-neighbor' 'Gateway neighbor (ARP)' 'INFO' 'IT')); Assert-Case 'two gateways: two ping-gateway rows and two neighbour rows' @(Test-ResultSet $r $cfg @{} $twoGateways) $true ''
$r = New-Fixture; $r.Results = @($r.Results) + @(New-Row $r.Results[0] 'ping-gateway' 'Default Gateway: 192.0.2.2' 'PASS'); Assert-Case 'two gateways but one neighbour row' @(Test-ResultSet $r $cfg @{} $twoGateways) $false 'gateway-neighbor: 1 row(s), expected 2'
# Both snapshot paths failing: the data-source row, the snapshot step's step-error row, and the zero-adapter shape.
$failedFallback = With $facts @{ ConnectedAdapters = 0; Gateways = @(); Source = 'CIM'; DataSourceRow = $true; SnapshotStepFailed = $true }
function ConvertTo-FailedFallbackShape($Report) {
    $Report = ConvertTo-ZeroAdapterShape $Report
    $Report.Results = @($Report.Results) + @((New-Row $Report.Results[0] 'data-source' 'Data Source Fallback' 'WARN'), (New-Row $Report.Results[0] 'step-error' 'Get Network Adapters, IP, Gateways, and DNS' 'ERROR'))
    return $Report
}
$r = ConvertTo-FailedFallbackShape (New-Fixture); Assert-Case 'both snapshot paths failed: data-source row, step-error row, zero-adapter shape, facts agree' @(Test-ResultSet $r $cfg @{} $failedFallback) $true ''
$r = ConvertTo-FailedFallbackShape (New-Fixture); Assert-Case 'the same shape with a fallback that worked' @(Test-ResultSet $r $cfg @{} (With $failedFallback @{ SnapshotStepFailed = $false })) $false 'step-error: 1 row(s), expected 0'
# Two connected wireless interfaces: one wifi row each.
$twoWifi = With $facts @{ WifiInterfaces = 2 }
$r = New-Fixture; $r.Results = @($r.Results) + @(New-Row $r.Results[0] 'wifi' 'Wi-Fi radio' 'INFO' 'IT'); Assert-Case 'two connected wireless interfaces with two wifi rows' @(Test-ResultSet $r $cfg @{} $twoWifi) $true ''
$r = New-Fixture; Assert-Case 'two connected wireless interfaces but one wifi row' @(Test-ResultSet $r $cfg @{} $twoWifi) $false 'wifi: 1 row(s), expected 2'
# The Wi-Fi retry row (backlog #61): one per wireless interface the machine lists, none when the configuration switches
# the reader off - and the report's own ChecksEnabled has to agree with the file.
$twoWlan = With $facts @{ WlanInterfaces = 2; WlanInterfaceIds = @('e6b08c8a-3feb-4c3e-88c3-dee94dd2f0eb', '0b3f7c2e-1111-4a2b-9c3d-000000000002') }
$r = New-Fixture; $second = New-Row $r.Results[0] 'wifi-retry' 'Wireless retries' 'INFO'; $second.Weightless = $true; $second.Details = 'Connection state: connected at the start, connected at the end.' + [Environment]::NewLine + 'Interface GUID: 0b3f7c2e-1111-4a2b-9c3d-000000000002'; $r.Results = @($r.Results) + @($second); Assert-Case 'two wireless interfaces with two wifi-retry rows' @(Test-ResultSet $r $cfg @{} $twoWlan) $true ''
$r = New-Fixture; Assert-Case 'two wireless interfaces but one wifi-retry row' @(Test-ResultSet $r $cfg @{} $twoWlan) $false 'wifi-retry: 1 row(s), expected 2'
$r = New-Fixture; $agg = New-Row $r.Results[0] 'wifi-retry' 'Wireless retries' 'ERROR'; $agg.Weightless = $true; $agg.Details = 'Reading at the start: addtype'; $r.Results = @($r.Results | Where-Object { $_.Tag -ne 'wifi-retry' }) + @($agg); Assert-Case 'two wireless interfaces and the one aggregate row of a reader that failed before listing them' @(Test-ResultSet $r $cfg @{} $twoWlan) $true ''
$r = New-Fixture; $one = New-Row $r.Results[0] 'wifi-retry' 'Wireless retries' 'ERROR'; $one.Weightless = $true; $one.Details = 'Connection state: connected at the start, connected at the end.'; $r.Results = @($r.Results | Where-Object { $_.Tag -ne 'wifi-retry' }) + @($one); Assert-Case 'two wireless interfaces but one per-interface error row is a missing row, not the aggregate shape' @(Test-ResultSet $r $cfg @{} $twoWlan) $false 'wifi-retry: 1 row(s), expected 2'
# An interface that appeared or was replaced during the run (round 6): the expected count is the union of the lists read
# before the launch and after the report, one measured row plus one transition row, or two transition rows.
$transition = New-Row $r.Results[0] 'wifi-retry' 'Wireless retries' 'ERROR'; $transition.Weightless = $true; $transition.Details = 'Connection state: not listed at the start, connected at the end.' + [Environment]::NewLine + 'Interface GUID: 0b3f7c2e-1111-4a2b-9c3d-000000000002'
$gone = New-Row $r.Results[0] 'wifi-retry' 'Wireless retries' 'ERROR'; $gone.Weightless = $true; $gone.Details = 'Connection state: connected at the start, not listed at the end.' + [Environment]::NewLine + 'Interface GUID: e6b08c8a-3feb-4c3e-88c3-dee94dd2f0eb'
$r = New-Fixture; $r.Results = @($r.Results) + @($transition); Assert-Case 'a second interface enabled during the run: the union of both readings, one measured row and one transition row' @(Test-ResultSet $r $cfg @{} $facts $twoWlan) $true ''
$r = New-Fixture; Assert-Case 'a second interface enabled during the run but no transition row' @(Test-ResultSet $r $cfg @{} $facts $twoWlan) $false 'wifi-retry: 1 row(s), expected 2'
$replaced = With $facts @{ WlanInterfaceIds = @('0b3f7c2e-1111-4a2b-9c3d-000000000002') }
$r = New-Fixture; $r.Results = @($r.Results | Where-Object { $_.Tag -ne 'wifi-retry' }) + @($gone, $transition); Assert-Case 'one interface replaced by another during the run: one transition row in each direction' @(Test-ResultSet $r $cfg @{} $facts $replaced) $true ''
# The rest of the oracle's matrix, walked in one pass before round 11: a wired machine (no interface at either reading,
# one Information row), that same row where the machine lists an interface, a one-sided none, the aggregate row where
# one interface is listed, a measured row beside a per-interface error, and a row naming an interface nobody listed.
$noWlan = With $facts @{ WlanInterfaces = 0; WlanInterfaceIds = @() }
$wired = New-Row $r.Results[0] 'wifi-retry' 'Wireless retries' 'INFO'; $wired.Weightless = $true; $wired.Details = 'Reading at the start: none'
$r = New-Fixture; $r.Results = @($r.Results | Where-Object { $_.Tag -ne 'wifi-retry' }) + @($wired); Assert-Case 'a wired machine: no interface at either reading, one Information row' @(Test-ResultSet $r $cfg @{} $noWlan) $true ''
$r = New-Fixture; $r.Results = @($r.Results | Where-Object { $_.Tag -ne 'wifi-retry' }) + @($wired); Assert-Case 'the wired-machine row on a machine that lists an interface' @(Test-ResultSet $r $cfg @{} $facts) $false ('wifi-retry: interface e6b08c8a-3feb-4c3e-88c3-dee94dd2f0eb has 0 row(s), expected 1')
$oneSided = New-Row $r.Results[0] 'wifi-retry' 'Wireless retries' 'ERROR'; $oneSided.Weightless = $true; $oneSided.Details = 'Reading at the end: none'
$r = New-Fixture; $r.Results = @($r.Results | Where-Object { $_.Tag -ne 'wifi-retry' }) + @($oneSided); Assert-Case 'an interface listed at the start and none at the end: the one-sided aggregate row' @(Test-ResultSet $r $cfg @{} $facts $noWlan) $true ''
$r = New-Fixture; $r.Results = @($r.Results | Where-Object { $_.Tag -ne 'wifi-retry' }) + @($agg); Assert-Case 'one interface listed and the reader failed: the aggregate row alone' @(Test-ResultSet $r $cfg @{} $facts) $true ''
$queryFailed = New-Row $r.Results[0] 'wifi-retry' 'Wireless retries' 'ERROR'; $queryFailed.Weightless = $true; $queryFailed.Details = 'Connection state: connected at the start, connected at the end.' + [Environment]::NewLine + 'Interface GUID: 0b3f7c2e-1111-4a2b-9c3d-000000000002'
$r = New-Fixture; $r.Results = @($r.Results) + @($queryFailed); Assert-Case 'two interfaces: one measured, one whose query failed' @(Test-ResultSet $r $cfg @{} $twoWlan) $true ''
$foreign = New-Row $r.Results[0] 'wifi-retry' 'Wireless retries' 'INFO'; $foreign.Weightless = $true; $foreign.Details = 'Connection state: connected at the start, connected at the end.' + [Environment]::NewLine + 'Interface GUID: 5d1e2f3a-2222-4b3c-8d4e-000000000003'
$r = New-Fixture; $r.Results = @($r.Results | Where-Object { $_.Tag -ne 'wifi-retry' }) + @($foreign); Assert-Case 'a row naming an interface neither reading listed' @(Test-ResultSet $r $cfg @{} $facts) $false 'which neither reading listed'
# The interface GUIDs the facts read off netsh (rounds 11 and 12): the value of the GUID-labelled line, so a network, a
# profile or an adapter's own name shaped like a UUID is not an interface, and two blocks are two interfaces.
$netshLines = @('', 'There are 2 interfaces on the system:', '', '    Name                   : Wi-Fi', '    Description            : Fixture Wi-Fi 6E', '    GUID                   : e6b08c8a-3feb-4c3e-88c3-dee94dd2f0eb', '    Physical address       : 00:11:22:33:44:55', '    State                  : connected', '    SSID                   : 5d1e2f3a-2222-4b3c-8d4e-000000000003', '    BSSID                  : 66:77:88:99:aa:bb', '    Profile                : 5d1e2f3a-2222-4b3c-8d4e-000000000003', '', '    Name                   : 7c2d3e4f-3333-4c5d-9e6f-000000000004', '    Description            : Fixture USB', '    GUID                   : 0b3f7c2e-1111-4a2b-9c3d-000000000002', '    Physical address       : 00:11:22:33:44:66', '    State                  : disconnected', '')
$readIds = @(Get-WlanInterfaceIds -Lines $netshLines)
Assert-Case 'netsh: a network, a profile and an adapter name shaped like a UUID are not interfaces, and two blocks are two' @($(if (($readIds -join ',') -eq '0b3f7c2e-1111-4a2b-9c3d-000000000002,e6b08c8a-3feb-4c3e-88c3-dee94dd2f0eb') { @() } else { @('read ' + ($readIds -join ',')) })) $true ''
Assert-Case 'netsh: no block, no interface' @($(if (@(Get-WlanInterfaceIds -Lines @('', 'There is no wireless interface on the system.', '')).Count -eq 0) { @() } else { @('read something') })) $true ''
Assert-Case 'netsh: the label is read before a full-width colon too' @($(if ((@(Get-WlanInterfaceIds -Lines @('    名稱：Wi-Fi', '    GUID：e6b08c8a-3feb-4c3e-88c3-dee94dd2f0eb', '    SSID：5d1e2f3a-2222-4b3c-8d4e-000000000003')) -join ',') -eq 'e6b08c8a-3feb-4c3e-88c3-dee94dd2f0eb') { @() } else { @('read ' + (@(Get-WlanInterfaceIds -Lines @('    GUID：e6b08c8a-3feb-4c3e-88c3-dee94dd2f0eb')) -join ',')) })) $true ''
# A retry row that carries weight is a regression whatever its shape (round 9): the decision is that none of them decides.
$r = New-Fixture; $weighted = New-Row $r.Results[0] 'wifi-retry' 'Wireless retries' 'ERROR'; $weighted.Details = 'Reading at the start: addtype'; $r.Results = @($r.Results | Where-Object { $_.Tag -ne 'wifi-retry' }) + @($weighted); Assert-Case 'a reader-failure row that is not weightless' @(Test-ResultSet $r $cfg @{} $facts) $false 'wifi-retry: a row that is not weightless'
$r = New-Fixture; $r.Results = @($r.Results | Where-Object { $_.Tag -ne 'wifi-retry' }) + @($transition, $transition); Assert-Case 'the same appearing-interface row twice is not a replacement: the one that went has no row' @(Test-ResultSet $r $cfg @{} $facts $replaced) $false ('wifi-retry: interface e6b08c8a-3feb-4c3e-88c3-dee94dd2f0eb has 0 row(s), expected 1')
$cfgNoRetry = Read-Config $ConfigDir; $cfgNoRetry.Checks.WifiRetryCounters = $false
$r = New-Fixture; Assert-Case 'the reader switched off in the file but the row still written' @(Test-ResultSet $r $cfgNoRetry @{} $facts) $false 'wifi-retry: 1 row(s), expected 0'
$r = New-Fixture; $r.Results = @($r.Results | Where-Object { $_.Tag -ne 'wifi-retry' }); $r.RunOptions.ChecksEnabled.WifiRetryCounters = $false; Assert-Case 'the reader switched off: no row, and the report says so' @(Test-ResultSet $r $cfgNoRetry @{} $facts) $true ''
$r = New-Fixture; $r.Results = @($r.Results | Where-Object { $_.Tag -ne 'wifi-retry' }); Assert-Case 'the reader switched off in the file but the report claims it on' @(Test-ResultSet $r $cfgNoRetry @{} $facts) $false 'ChecksEnabled for WifiRetryCounters'
# Exactly one adapter-statistics sample failing on a machine where the cmdlet works: one step-error row and the aggregate row.
function ConvertTo-OneSampleFailed($Report) {
    $Report.Results = @($Report.Results | Where-Object { $_.Tag -ne 'adapter-errors' })
    $Report.Results = @($Report.Results) + @((New-Row $Report.Results[0] 'step-error' 'Get Ending Network Adapter Error Values' 'ERROR'), (New-Row $Report.Results[0] 'adapter-errors' 'Before/After Comparison' 'ERROR'))
    return $Report
}
$r = ConvertTo-OneSampleFailed (New-Fixture); Assert-Case 'one adapter-statistics sample failed: one step-error row and the aggregate row' @(Test-ResultSet $r $cfg @{} $facts) $true ''
# The two TCP counter samples are read independently: a class readable in one sample only leaves one error row and no
# result row for that class; both classes lost after the baseline leave two error rows and no step-error.
function Set-TcpRows($Report, [object[]]$Rows) {
    $Report.Results = @($Report.Results | Where-Object { $_.Tag -ne 'tcp-retransmissions' })
    foreach ($row in $Rows) { $Report.Results = @($Report.Results) + @(New-Row $Report.Results[0] 'tcp-retransmissions' $row[0] $row[1]) }
    return $Report
}
$v6LostAfter = With $facts @{ TcpCounters = @{ TCPv4 = $true; TCPv6 = $false } }
$r = Set-TcpRows (New-Fixture) @(@('TCPv4', 'PASS'), @('TCPv6 counters', 'ERROR')); Assert-Case 'TCPv6 readable at the baseline only: one result row and one error row' @(Test-ResultSet $r $cfg @{} $facts $v6LostAfter) $true ''
$r = Set-TcpRows (New-Fixture) @(@('TCPv4', 'PASS'), @('TCPv6 counters', 'ERROR')); Assert-Case 'TCPv6 readable at the end only: the same shape' @(Test-ResultSet $r $cfg @{} $v6LostAfter $facts) $true ''
$bothLostAfter = With $facts @{ TcpCounters = @{ TCPv4 = $false; TCPv6 = $false } }
$r = Set-TcpRows (New-Fixture) @(@('TCPv4 counters', 'ERROR'), @('TCPv6 counters', 'ERROR')); Assert-Case 'both classes lost after the baseline: two error rows, no step-error' @(Test-ResultSet $r $cfg @{} $facts $bothLostAfter) $true ''
# The machine can change during a run: the report must match the pre-launch facts, or else the post-run facts (noted).
function ConvertTo-TwoAdapters($Report) {
    $Report.Results = @($Report.Results | Where-Object { -not ($_.Tag -in @('adapter', 'adapter-errors') -and $_.Check -like '*fixture 3*') })
    return $Report
}
$twoAdapters = With $facts @{ ConnectedAdapters = 2 }
$run = Test-ResultSetForRun (New-Fixture) $cfg @{} $facts $twoAdapters; Assert-Case 'an adapter dropped during the run, report from before the drop' @($run.Mismatches) $true ''
if ($run.Note -ne '') { $script:fails++; "[FAIL] the pre-launch match must carry no note -> '$($run.Note)'" } else { $script:passes++; "[PASS] the pre-launch match carries no note" }
$run = Test-ResultSetForRun (ConvertTo-TwoAdapters (New-Fixture)) $cfg @{} $facts $twoAdapters; Assert-Case 'an adapter dropped during the run, report from after the drop' @($run.Mismatches) $true ''
if ($run.Note -like '*matches the post-run facts*') { $script:passes++; "[PASS] the post-run match is noted -> '$($run.Note)'" } else { $script:fails++; "[FAIL] the post-run match must be noted -> '$($run.Note)'" }
$run = Test-ResultSetForRun (ConvertTo-TwoAdapters (New-Fixture)) $cfg @{} $facts $facts; Assert-Case 'two adapter rows with three adapters throughout' @($run.Mismatches) $false 'adapter: 2 row(s), expected one per connected adapter with an address (3)'

# PR #41, round 2: the row-count oracle's own predicates, on configurations the packaged one does not have. Each case
# states what the product would write and asks the oracle for the same number; the packaged configuration exercises
# none of these paths, so passing 42 cases against it proved nothing about them.
function New-BrokenConfig { return (Read-Config $ConfigDir) }
$c = New-BrokenConfig; $c.Expected.AllowedIPv4Addresses = @('not-an-ip')
Assert-Case 'config rows: an invalid standard alone is the validation row' @($(if ((Get-ConfigRowCount $c) -eq 1) { @() } else { @("config rows: $(Get-ConfigRowCount $c), expected 1") })) $true ''
$c = New-BrokenConfig; $c.Expected.AllowedIPv4Addresses = @('not-an-ip'); $c.Tests.TcpTargets[0].Port = 0
Assert-Case 'config rows: a standard and a target are two rows' @($(if ((Get-ConfigRowCount $c) -eq 2) { @() } else { @("config rows: $(Get-ConfigRowCount $c), expected 2") })) $true ''
$c = New-BrokenConfig; $c.Tests.TcpTargets[0].Port = 0
Assert-Case 'config rows: a target alone suppresses the PASS row, leaving one' @($(if ((Get-ConfigRowCount $c) -eq 1) { @() } else { @("config rows: $(Get-ConfigRowCount $c), expected 1") })) $true ''
$c = New-BrokenConfig; $c.Thresholds.AdapterErrorWarningDelta = 'bad'; $c.Tests.TcpTargets[0].Port = 0
Assert-Case 'config rows: an adapter threshold and a target are two rows' @($(if ((Get-ConfigRowCount $c) -eq 2) { @() } else { @("config rows: $(Get-ConfigRowCount $c), expected 2") })) $true ''
$c = New-BrokenConfig; $c.Thresholds.LatencyWarningMs = 900; $c.Thresholds.LatencyCriticalMs = 100; $c.Checks.WifiRf = 'yes'
# Two rows, not three: with no invalid standard the validation row is not written at all, because the PASS branch is
# suppressed by any input problem. The first draft of this case expected three and the oracle was right.
Assert-Case 'config rows: thresholds and options are two rows, with no validation row between them' @($(if ((Get-ConfigRowCount $c) -eq 2) { @() } else { @("config rows: $(Get-ConfigRowCount $c), expected 2") })) $true ''
# A bare string in DnsNames is the documented short form: one lookup row, not a notice and a did-not-run row.
$c = New-BrokenConfig; $c.Tests.DnsNames = @('www.example.com')
Assert-Case 'dns rows: a bare string is a usable target' @($(if ((Get-TargetRowCount $c.Tests.DnsNames { param($t) Test-ConfiguredDnsTarget $t } $true) -eq 1) { @() } else { @('dns rows wrong') })) $true ''
Assert-Case 'config rows: and it is not counted as unusable' @($(if ((Get-ConfigRowCount $c) -eq 1) { @() } else { @("config rows: $(Get-ConfigRowCount $c), expected 1") })) $true ''
# A required ping address that cannot be used adds the weighted row beside its notice.
$c = New-BrokenConfig; $c.Tests.PingTargets = @([pscustomobject]@{ Name = 'Broken'; Address = 'http://example.com'; Required = $true })
Assert-Case 'ping rows: a required unusable address adds its second row' @($(if ((Get-UnusablePingExtraRows $c) -eq 1) { @() } else { @('ping extra rows wrong') })) $true ''
$c.Tests.PingTargets = @([pscustomobject]@{ Name = 'Broken'; Address = 'http://example.com'; Required = $false })
Assert-Case 'ping rows: an optional one does not' @($(if ((Get-UnusablePingExtraRows $c) -eq 0) { @() } else { @('ping extra rows wrong') })) $true ''

# PR #41, round 3: five findings with one cause - the oracle read configuration values with Int32.TryParse and its
# own range checks, where the product reads them through ConvertTo-IntSafe and Test-IsWholeNumber. It now loads those
# converters from the package under test; these are the five configurations the reviewer named, each paired with an
# invalid TCP target so the count distinguishes 'one row' from 'two'.
$c = New-BrokenConfig; $c.Expected.AllowedIPv4Addresses = @(''); $c.Tests.TcpTargets[0].Port = 0
Assert-Case 'config rows: a blank standard entry is skipped, exactly as the product skips it' @($(if ((Get-ConfigRowCount $c) -eq 1) { @() } else { @("config rows: $(Get-ConfigRowCount $c), expected 1") })) $true ''
$c = New-BrokenConfig; $c.Tests.PingCount = '4.0'; $c.Tests.TcpTargets[0].Port = 0
Assert-Case 'config rows: 4.0 as a string is a whole number to the tool, so no threshold row' @($(if ((Get-ConfigRowCount $c) -eq 1) { @() } else { @("config rows: $(Get-ConfigRowCount $c), expected 1") })) $true ''
# An explicit null does not skip the setting: it falls to the second branch, where ConvertTo-IntSafe makes it 0.
$c = New-BrokenConfig; $c.Tests.PingCount = $null; $c.Tests.TcpTargets[0].Port = 0
Assert-Case 'config rows: an explicit null test setting warns, adding the thresholds row' @($(if ((Get-ConfigRowCount $c) -eq 2) { @() } else { @("config rows: $(Get-ConfigRowCount $c), expected 2") })) $true ''
# Whole-valued, but outside Int32 - which Test-IsWholeNumber rejects and a floor-equality check alone would not.
$c = New-BrokenConfig; $c.Thresholds.TcpRetransmissionCriticalCount = 2147483648; $c.Tests.TcpTargets[0].Port = 0
Assert-Case 'config rows: a count threshold beyond Int32 is not a whole number' @($(if ((Get-ConfigRowCount $c) -eq 2) { @() } else { @("config rows: $(Get-ConfigRowCount $c), expected 2") })) $true ''
$c = New-BrokenConfig; $c.Tests.TcpTargets[0].Port = '443.0'
Assert-Case 'tcp target: 443.0 is a usable port, because that is how the tool parses it' @($(if (Test-ConfiguredTcpTarget $c.Tests.TcpTargets[0]) { @() } else { @('the oracle called a port the tool accepts unusable') })) $true ''

# A threshold whose decimal separator this machine's culture accepts and the tool's invariant reader does not.
# The tool warns and falls back to its default; the oracle used to agree with the machine instead (round 4).
$c = New-BrokenConfig; $c.Thresholds.PacketLossCriticalPercent = '2,5'; $c.Tests.TcpTargets[0].Port = 0
Assert-Case 'config rows: a comma decimal is not a number to the tool, so the thresholds row is written' @($(if ((Get-ConfigRowCount $c) -eq 2) { @() } else { @("config rows: $(Get-ConfigRowCount $c), expected 2") })) $true ''

# PR #41, round 6: a DNS name no resolver can be asked, and the targets a switch adds to the configuration.
$c = New-BrokenConfig; $c.Tests.DnsNames = @('foo..bar')
Assert-Case 'dns rows: a malformed name is not a usable target' @($(if (-not (Test-ConfiguredDnsTarget 'foo..bar')) { @() } else { @('the oracle called foo..bar usable') })) $true ''
Assert-Case 'config rows: and it is a configured-targets row' @($(if ((Get-ConfigRowCount $c) -eq 1) { @() } else { @("config rows: $(Get-ConfigRowCount $c), expected 1") })) $true ''
$c = New-BrokenConfig
$o = [pscustomobject]@{ ExtraTargets = [pscustomobject]@{ Ping = @('http://example.com'); Dns = @(); Tcp = @(); Http = @() } }
Assert-Case 'config rows: an unusable -PingTarget is a row the file on disk cannot show' @($(if ((Get-ConfigRowCount $c $o) -eq 1) { @() } else { @("config rows: $(Get-ConfigRowCount $c $o), expected 1") })) $true ''
$o = [pscustomobject]@{ ExtraTargets = [pscustomobject]@{ Ping = @(); Dns = @('foo..bar'); Tcp = @(); Http = @('ftp://host') } }
Assert-Case 'config rows: an unusable -DnsName and -HttpUrl are the same one row' @($(if ((Get-ConfigRowCount $c $o) -eq 1) { @() } else { @("config rows: $(Get-ConfigRowCount $c $o), expected 1") })) $true ''
$o = [pscustomobject]@{ ExtraTargets = [pscustomobject]@{ Ping = @('8.8.8.8'); Dns = @('www.example.com'); Tcp = @(); Http = @('https://example.com') } }
Assert-Case 'config rows: usable switch targets leave the PASS row alone' @($(if ((Get-ConfigRowCount $c $o) -eq 1) { @() } else { @("config rows: $(Get-ConfigRowCount $c $o), expected 1") })) $true ''

# PR #41, round 7: a URL where a DNS name belongs, and the scalar switches that replace a file value.
Assert-Case 'dns rows: a URL is not a usable name' @($(if (-not (Test-ConfiguredDnsTarget 'http://example.com')) { @() } else { @('the oracle called a URL a usable DNS name') })) $true ''
$c = New-BrokenConfig; $c.Tests.PingCount = 0; $c.Tests.TcpTargets[0].Port = 0
Assert-Case 'config rows: a file PingCount of 0 warns, so two rows' @($(if ((Get-ConfigRowCount $c) -eq 2) { @() } else { @("config rows: $(Get-ConfigRowCount $c), expected 2") })) $true ''
Assert-Case 'config rows: and -PingCount 4 replaces it, leaving one' @($(if ((Get-ConfigRowCount $c $null @{ PingCount = 4 }) -eq 1) { @() } else { @("config rows: $(Get-ConfigRowCount $c $null @{ PingCount = 4 }), expected 1") })) $true ''
$c = New-BrokenConfig; $c.Checks.TracerouteHops = 99; $c.Tests.TcpTargets[0].Port = 0
Assert-Case 'config rows: a file hop count out of range warns, so two rows' @($(if ((Get-ConfigRowCount $c) -eq 2) { @() } else { @("config rows: $(Get-ConfigRowCount $c), expected 2") })) $true ''
Assert-Case 'config rows: and -TracerouteHops 4 replaces it, leaving one' @($(if ((Get-ConfigRowCount $c $null @{ TracerouteHops = 4 }) -eq 1) { @() } else { @("config rows: $(Get-ConfigRowCount $c $null @{ TracerouteHops = 4 }), expected 1") })) $true ''

# PR #41, round 8: a TCP host that is not a name, and the boolean switches that replace an invalid file value.
$c = New-BrokenConfig; $c.Tests.TcpTargets[0].Host = 'http://example.com'
Assert-Case 'tcp target: a URL in Host is not a usable target' @($(if (-not (Test-ConfiguredTcpTarget $c.Tests.TcpTargets[0])) { @() } else { @('the oracle called a URL a usable TCP host') })) $true ''
Assert-Case 'config rows: and it is the configured-targets row' @($(if ((Get-ConfigRowCount $c) -eq 1) { @() } else { @("config rows: $(Get-ConfigRowCount $c), expected 1") })) $true ''
$c = New-BrokenConfig; $c.Checks.WifiRf = 'bad'; $c.Tests.TcpTargets[0].Port = 0
Assert-Case 'config rows: an invalid check flag warns, so two rows' @($(if ((Get-ConfigRowCount $c) -eq 2) { @() } else { @("config rows: $(Get-ConfigRowCount $c), expected 2") })) $true ''
Assert-Case 'config rows: and -NoWifi replaces it before validation, leaving one' @($(if ((Get-ConfigRowCount $c $null @{ NoWifi = $true }) -eq 1) { @() } else { @("config rows: $(Get-ConfigRowCount $c $null @{ NoWifi = $true }), expected 1") })) $true ''
# Round 8 put two cases here for an unusable -TcpTarget, and round 10 found that both expected 1 - a clean
# configuration with one bad target and a clean configuration with none produce one row either way, for opposite
# reasons. They could not fail, so they are gone; Test-TcpTargetSyntax is asserted directly in unit_tests.ps1,
# where the value it rejects is the point.

# PR #41, round 9: a URL whose host is not a name, and the panel's six check boxes.
$c = New-BrokenConfig; $c.Tests.HttpTargets[0].Url = 'http://foo..bar/'
Assert-Case 'http target: an empty label in the host is not usable' @($(if (-not (Test-ConfiguredHttpTarget $c.Tests.HttpTargets[0])) { @() } else { @('the oracle called http://foo..bar/ usable') })) $true ''
Assert-Case 'config rows: and it is the configured-targets row' @($(if ((Get-ConfigRowCount $c) -eq 1) { @() } else { @("config rows: $(Get-ConfigRowCount $c), expected 1") })) $true ''
$c = New-BrokenConfig; $c.Checks.ProxySettings = 'bad'; $c.Tests.TcpTargets[0].Port = 0
Assert-Case 'config rows: an invalid flag -NoWifi does not cover still warns' @($(if ((Get-ConfigRowCount $c $null @{ NoWifi = $true }) -eq 2) { @() } else { @("config rows: $(Get-ConfigRowCount $c $null @{ NoWifi = $true }), expected 2") })) $true ''
$panel = @{ Checks = @{ WifiRf = $true; Traceroute = $true; RouteTable = $true; GatewayNeighbor = $true; ProxySettings = $true; DriverInfo = $true } }
Assert-Case 'config rows: but the panel replaces all six, leaving one' @($(if ((Get-ConfigRowCount $c $null $panel) -eq 1) { @() } else { @("config rows: $(Get-ConfigRowCount $c $null $panel), expected 1") })) $true ''

# PR #41, round 14: the run trims an address before it decides what it is, so a padded placeholder is still the
# placeholder. Get-UnusablePingExtraRows asks Test-PingTargetSyntax, which trims; these assert the whole path.
$c = New-BrokenConfig; $c.Tests.PingTargets = @([pscustomobject]@{ Name = 'Padded'; Address = ' AUTO_GATEWAY '; Required = $true })
Assert-Case 'ping rows: a padded placeholder is usable, so it adds no second row' @($(if ((Get-UnusablePingExtraRows $c) -eq 0) { @() } else { @('a padded placeholder was called unusable') })) $true ''
Assert-Case 'config rows: and it is not a configured-targets row' @($(if ((Get-ConfigRowCount $c) -eq 1) { @() } else { @("config rows: $(Get-ConfigRowCount $c), expected 1") })) $true ''
# The three cases above exercise the product's own trim, which was already there. This one exercises the two
# lines round 14 changed: Test-ResultSet decides what a configured address is, and until now it compared the
# placeholder untrimmed. Padding every address in the packaged configuration must leave the expectation
# identical, because the run reads them all trimmed.
$padded = Read-Config $ConfigDir
foreach ($t in @($padded.Tests.PingTargets)) { $t.Address = ' ' + ([string]$t.Address) + ' ' }
$r = New-Fixture
Assert-Case 'padded addresses do not change what the report must contain' @(Test-ResultSet $r $padded @{} $facts) $true ''
$c = New-BrokenConfig; $c.Tests.PingTargets = @([pscustomobject]@{ Name = 'Padded'; Address = ' example.com '; Required = $true })
Assert-Case 'ping rows: a padded name is usable too' @($(if ((Get-UnusablePingExtraRows $c) -eq 0) { @() } else { @('a padded name was called unusable') })) $true ''

"Summary: $passes passed, $fails failed"
exit $fails
