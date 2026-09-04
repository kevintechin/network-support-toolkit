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
# the TCPv6 error rows with the TCPv6 class unreadable, the one step-error row and one generic row with neither TCP class
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
foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in @('Read-Config', 'Get-Count', 'Test-TrueFlag', 'Get-MachineFacts', 'Get-StandardRuleCount', 'Test-ResultSet') }, $true)) { Invoke-Expression $f.Extent.Text }
$machine = Get-MachineFacts
"machine: $($machine.ConnectedAdapters) connected adapter(s) with an address, gateway(s) $(@($machine.Gateways) -join ', '), source $($machine.Source), TCP counters v4=$($machine.TcpCounters.TCPv4) v6=$($machine.TcpCounters.TCPv6)"
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
$facts = @{ ConnectedAdapters = 3; Gateways = @('192.0.2.1'); Source = 'NetCmdlets'; DataSourceRow = $false; TcpCounters = @{ TCPv4 = $true; TCPv6 = $true }; AdapterStatistics = $true }
function New-Row($Template, [string]$Tag, [string]$Check, [string]$Status, [string]$Scope = 'Main') {
    $row = $Template.PSObject.Copy(); $row.Tag = $Tag; $row.Check = $Check; $row.Status = $Status; $row.Scope = $Scope; $row.Message = 'fixture row'; return $row
}
function New-Fixture {
    $r = Load
    $template = $r.Results[0]
    $rows = @($r.Results | Where-Object { $_.Tag -notin @('adapter', 'adapter-errors', 'gateway-config', 'dns-config', 'ping-gateway', 'tcp-retransmissions', 'data-source') })
    foreach ($x in $rows) { if ($x.Tag -eq 'adapters') { $x.Status = 'PASS' } }
    foreach ($i in 1..3) { $rows += New-Row $template 'adapter' "Adapter: fixture $i" 'PASS' }
    $rows += New-Row $template 'gateway-config' 'Default Gateway' 'PASS'
    $rows += New-Row $template 'dns-config' 'DNS Servers' 'PASS'
    $rows += New-Row $template 'ping-gateway' 'Default Gateway: 192.0.2.1' 'PASS'
    foreach ($i in 1..3) { $rows += New-Row $template 'adapter-errors' "fixture $i" 'PASS' }
    $rows += New-Row $template 'tcp-retransmissions' 'TCPv4' 'PASS'
    $rows += New-Row $template 'tcp-retransmissions' 'TCPv6' 'INFO'
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
# With neither TCP counter class readable the baseline step fails (one step-error row) and the analysis writes the single
# generic "System Counters" row.
function ConvertTo-TcpUnreadable($Report) {
    $Report.Results = @($Report.Results | Where-Object { $_.Tag -ne 'tcp-retransmissions' })
    $Report.Results = @($Report.Results) + @((New-Row $Report.Results[0] 'step-error' 'Get TCP Retransmission Baseline' 'ERROR'), (New-Row $Report.Results[0] 'tcp-retransmissions' 'System Counters' 'ERROR'))
    return $Report
}
$r = ConvertTo-TcpUnreadable (New-Fixture); Assert-Case 'neither TCP counter class readable: one step-error row and the generic row, facts agree' @(Test-ResultSet $r $cfg @{} (With $facts @{ TcpCounters = @{ TCPv4 = $false; TCPv6 = $false } })) $true ''
$r = ConvertTo-TcpUnreadable (New-Fixture); Assert-Case 'the same shape with both counter classes readable' @(Test-ResultSet $r $cfg @{} $facts) $false 'step-error: 1 row(s), expected 0'
# Without adapter statistics both sampling steps fail (two step-error rows) and the analysis writes one aggregate row.
function ConvertTo-NoAdapterStatistics($Report) {
    $Report.Results = @($Report.Results | Where-Object { $_.Tag -ne 'adapter-errors' })
    $Report.Results = @($Report.Results) + @((New-Row $Report.Results[0] 'step-error' 'Get Network Adapter Error Baseline' 'ERROR'), (New-Row $Report.Results[0] 'step-error' 'Get Ending Network Adapter Error Values' 'ERROR'), (New-Row $Report.Results[0] 'adapter-errors' 'Before/After Comparison' 'ERROR'))
    return $Report
}
$r = ConvertTo-NoAdapterStatistics (New-Fixture); Assert-Case 'adapter statistics unavailable: two step-error rows and the aggregate row, facts agree' @(Test-ResultSet $r $cfg @{} (With $facts @{ AdapterStatistics = $false })) $true ''
$r = ConvertTo-NoAdapterStatistics (New-Fixture); Assert-Case 'the same shape with adapter statistics available' @(Test-ResultSet $r $cfg @{} $facts) $false 'adapter-errors: 1 row(s), expected one per adapter row (3)'
$r = New-Fixture; $r.Results = @($r.Results) + @(New-Row $r.Results[0] 'step-error' 'Collect IT diagnostics' 'ERROR' 'IT'); Assert-Case 'a step-error row the facts do not explain' @(Test-ResultSet $r $cfg @{} $facts) $false 'step-error: 1 row(s), expected 0'
"Summary: $passes passed, $fails failed"
exit $fails
