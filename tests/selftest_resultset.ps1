param([string]$ReportDir, [string]$ConfigDir)
# Negative self-check of the runner's result-set assertion (Test-ResultSet in Invoke-ValidationChain.ps1): the helper
# functions are lifted out of the runner by AST, then a real report from an earlier run is fed to the assertion intact
# (must be clean) and tampered with (must be reported): a row removed, a rogue tag added, an IT row moved to the Main
# scope, an extra-target row expected but absent, every adapter counter row removed, an empty result set, a diagnostic
# dropped by the run and by the report's ChecksEnabled alike, and a gateway row naming an address that is not a default
# gateway of this machine.
#   -ReportDir: a Reports folder written by NetworkHealthCheck.ps1 (the oldest JSON report in it is used)
#   -ConfigDir: the folder holding the NetworkHealthCheck.config.json that run used
# Example: tests\selftest_resultset.ps1 -ReportDir <work dir>\stage\console\en-US\Reports -ConfigDir <work dir>\stage\console\en-US
$ErrorActionPreference = 'Stop'
$runner = Join-Path $PSScriptRoot 'Invoke-ValidationChain.ps1'
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($runner, [ref]$tokens, [ref]$errors)
foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in @('Read-Config', 'Get-Count', 'Test-TrueFlag', 'Get-MachineGateways', 'Test-ResultSet') }, $true)) { Invoke-Expression $f.Extent.Text }
$cfg = Read-Config $ConfigDir
$json = @(Get-ChildItem -LiteralPath $ReportDir -Filter '*.json' | Sort-Object LastWriteTime | Select-Object -First 1)[0]
if ($null -eq $json) { "no JSON report in $ReportDir"; exit 1 }
$text = Get-Content -LiteralPath $json.FullName -Raw -Encoding UTF8
function Load { $text | ConvertFrom-Json }

$fails = 0; $passes = 0
function Assert-Case([string]$Name, [string[]]$Mismatches, [bool]$ExpectClean, [string]$MustMention) {
    $clean = ($Mismatches.Count -eq 0)
    $ok = ($clean -eq $ExpectClean) -and ($ExpectClean -or ($Mismatches -join '; ') -like ('*' + $MustMention + '*'))
    if ($ok) { $script:passes++; "[PASS] $Name -> " + $(if ($clean) { 'clean' } else { $Mismatches -join '; ' }) }
    else { $script:fails++; "[FAIL] $Name -> " + $(if ($clean) { 'clean' } else { $Mismatches -join '; ' }) + " (expected " + $(if ($ExpectClean) { 'clean' } else { "a mismatch mentioning '$MustMention'" }) + ")" }
}
"report $($json.Name): $(@((Load).Results).Count) rows, EntryPoint $((Load).RunOptions.EntryPoint)"
$r = Load; Assert-Case 'intact report' @(Test-ResultSet $r $cfg @{}) $true ''
$r = Load; $r.Results = @($r.Results | Where-Object { $_.Tag -ne 'dns' }); Assert-Case 'dns row removed' @(Test-ResultSet $r $cfg @{}) $false 'dns: 0 row(s)'
$r = Load; $rogue = $r.Results[0].PSObject.Copy(); $rogue.Tag = 'bogus'; $r.Results = @($r.Results) + @($rogue); Assert-Case 'rogue tag added' @(Test-ResultSet $r $cfg @{}) $false 'unexpected tag(s): bogus'
$r = Load; foreach ($x in $r.Results) { if ($x.Tag -eq 'routes') { $x.Scope = 'Main' } }; Assert-Case 'routes row moved to the Main scope' @(Test-ResultSet $r $cfg @{}) $false 'routes row in scope Main'
$r = Load; Assert-Case 'extra ping target expected but absent' @(Test-ResultSet $r $cfg @{ ExtraPing = '9.9.9.9' }) $false 'no ping-target row for 9.9.9.9'
$r = Load; $r.Results = @($r.Results | Where-Object { $_.Tag -ne 'adapter-errors' }); Assert-Case 'every adapter counter row removed' @(Test-ResultSet $r $cfg @{}) $false 'adapter-errors: 0 row(s)'
$r = Load; $r.Results = @(); Assert-Case 'empty result set' @(Test-ResultSet $r $cfg @{}) $false 'no adapter row'
$r = Load; $r.RunOptions.ChecksEnabled.WifiRf = $false; $r.Results = @($r.Results | Where-Object { $_.Tag -ne 'wifi' }); Assert-Case 'Wi-Fi diagnostic dropped by the run and by ChecksEnabled alike' @(Test-ResultSet $r $cfg @{}) $false 'ChecksEnabled for wifi reported as False'
$r = Load; foreach ($x in $r.Results) { if ($x.Tag -eq 'ping-gateway') { $x.Check = ($x.Check -replace '\d{1,3}(\.\d{1,3}){3}', '10.255.255.254') } }; Assert-Case 'ping-gateway row naming an address that is not a gateway of this machine' @(Test-ResultSet $r $cfg @{}) $false 'not a default gateway of this machine'
"Summary: $passes passed, $fails failed"
exit $fails
