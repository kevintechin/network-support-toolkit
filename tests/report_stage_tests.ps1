param([string]$ScriptPath, [string]$WorkDir)

# Load every function of the script (without running its main body) into this scope.
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$errors)
$funcs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Parent -is [System.Management.Automation.Language.NamedBlockAst] }, $true)
foreach ($f in $funcs) { Invoke-Expression $f.Extent.Text }
Write-Output ("Loaded {0} functions from {1}" -f @($funcs).Count, (Split-Path -Leaf (Split-Path -Parent $ScriptPath)))

# Minimal script state the report stage needs (GUI unavailable).
$script:ToolVersion = "test"
$script:BaseDirectory = $WorkDir
$script:Results = New-Object System.Collections.ArrayList
$script:StartupMessages = New-Object System.Collections.ArrayList
$script:BaseConfig = Get-DefaultConfig
$script:Interactive = $false
$script:GuiAvailable = $false
Set-RunOptions -Overrides @{} | Out-Null
$script:OutputDirectory = $WorkDir
$script:EffectiveConfigPath = "(test)"
$script:RunStartedAt = Get-Date
$script:RunFinishedAt = Get-Date
$script:LastHtmlReport = $null; $script:LastTextReport = $null; $script:LastJsonReport = $null
Add-CheckResult -Category "Test" -Check "One" -Status "PASS" -Message "ok" -Details "" -Tag "ping-gateway" | Out-Null
Add-CheckResult -Category "Test" -Check "Two" -Status "WARN" -Message "hmm" -Details "detail" -Tag "ping-target" | Out-Null
Add-CheckResult -Category "IT" -Check "Three" -Status "INFO" -Message "it data" -Details "" -Tag "routes" -Scope "IT" | Out-Null

$fails = 0; $passes = 0
function Assert-Equal($name, $actual, $expected) {
    if ("$actual" -eq "$expected") { $script:passes++; Write-Output "[PASS] $name -> $actual" }
    else { $script:fails++; Write-Output "[FAIL] $name -> got '$actual', expected '$expected'" }
}
function Count-Fatal { @(Get-ChildItem -LiteralPath $WorkDir -Filter "NetworkHealthCheck_FATAL_*.txt" -ErrorAction SilentlyContinue).Count }
$originalWriter = ${function:Write-Utf8File}

# --- Scenario A: every format succeeds ---
$script:LastHtmlReport = $null; $script:LastTextReport = $null; $script:LastJsonReport = $null
$fatalBefore = Count-Fatal
$r = Complete-ReportStage -SaveResult (Save-Reports)
Assert-Equal 'A: Succeeded' $r.Succeeded True
Assert-Equal 'A: no failed formats' (@($r.FailedFormats).Count) 0
Assert-Equal 'A: html exists' (Test-Path -LiteralPath $r.Html) True
Assert-Equal 'A: txt exists' (Test-Path -LiteralPath $r.Text) True
Assert-Equal 'A: json exists' (Test-Path -LiteralPath $r.Json) True
Assert-Equal 'A: primary is html' ($r.PrimaryReport -eq $r.Html) True
Assert-Equal 'A: no emergency report' ((Count-Fatal) - $fatalBefore) 0
$json = Get-Content -LiteralPath $r.Json -Raw | ConvertFrom-Json
Assert-Equal 'A: schema 2' $json.SchemaVersion 2
Assert-Equal 'A: RunOptions entry point' $json.RunOptions.EntryPoint "User"
Assert-Equal 'A: fingerprint key (WARN only) = quality' $json.Fingerprint.Key "quality"
Assert-Equal 'A: result Tag serialized' $json.Results[0].Tag "ping-gateway"
Assert-Equal 'A: result Scope serialized' $json.Results[2].Scope "IT"
$html = Get-Content -LiteralPath $r.Html -Raw
Assert-Equal 'A: html has tell-IT section' ($html -match 'class="tell"') True
Assert-Equal 'A: html has IT block' ($html -match 'class="itblock"') True
Assert-Equal 'A: html has toggle script' ($html -match 'nhcToggle') True
Assert-Equal 'A: html IT row goes to IT table' (($html -split 'class="itblock"')[1] -match 'it data') True
Start-Sleep -Seconds 1

# --- Scenario B: HTML write fails, TXT/JSON succeed (backlog #3) ---
function Write-Utf8File { param([string]$Path, [string]$Content) if ($Path -like "*.html") { throw "simulated disk failure (html)" } ; & $originalWriter -Path $Path -Content $Content }
$script:LastHtmlReport = $null; $script:LastTextReport = $null; $script:LastJsonReport = $null
$fatalBefore = Count-Fatal
$r = Complete-ReportStage -SaveResult (Save-Reports)
Assert-Equal 'B: Succeeded (partial)' $r.Succeeded True
Assert-Equal 'B: failed formats = HTML' (@($r.FailedFormats) -join ",") "HTML"
Assert-Equal 'B: html null' ($null -eq $r.Html) True
Assert-Equal 'B: txt exists' (Test-Path -LiteralPath $r.Text) True
Assert-Equal 'B: json exists' (Test-Path -LiteralPath $r.Json) True
Assert-Equal 'B: primary is txt' ($r.PrimaryReport -eq $r.Text) True
Assert-Equal 'B: write error carries diagnostics' ((@($r.WriteErrors) -join "`n") -match 'Call stack|呼叫堆疊') True
Assert-Equal 'B: no emergency report for a partial failure' ((Count-Fatal) - $fatalBefore) 0
Assert-Equal 'B: EmergencyPath null' ($null -eq $r.EmergencyPath) True
Start-Sleep -Seconds 1

# --- Scenario C: all three formats fail -> exactly ONE emergency report (backlog #2) ---
function Write-Utf8File { param([string]$Path, [string]$Content) if ((Split-Path -Leaf $Path) -notlike "NetworkHealthCheck_FATAL_*") { throw "simulated disk failure (all)" } ; & $originalWriter -Path $Path -Content $Content }
$script:LastHtmlReport = $null; $script:LastTextReport = $null; $script:LastJsonReport = $null
$fatalBefore = Count-Fatal
$r = Complete-ReportStage -SaveResult (Save-Reports)
Assert-Equal 'C: Succeeded false' $r.Succeeded False
Assert-Equal 'C: failed formats = HTML,TXT,JSON' (@($r.FailedFormats) -join ",") "HTML,TXT,JSON"
Assert-Equal 'C: primary null' ($null -eq $r.PrimaryReport) True
Assert-Equal 'C: exactly one emergency report' ((Count-Fatal) - $fatalBefore) 1
Assert-Equal 'C: EmergencyPath exists' (Test-Path -LiteralPath $r.EmergencyPath) True
$fatalText = Get-Content -LiteralPath $r.EmergencyPath -Raw
Assert-Equal 'C: emergency report lists all three write errors' (([regex]::Matches($fatalText, 'Failed to write (HTML|text|JSON) report|(HTML |文字|JSON )報告寫入失敗')).Count) 3
Assert-Equal 'C: emergency report keeps call stacks' ($fatalText -match 'Call stack|呼叫堆疊') True
${function:Write-Utf8File} = $originalWriter

# --- Scenario D: fingerprint keys from tagged results (v1.2) ---
function Reset-Results { $script:Results.Clear() }
function Add-Tagged($tag, $status) { Add-CheckResult -Category "T" -Check $tag -Status $status -Message "m" -Details "" -Tag $tag | Out-Null }
Reset-Results; Add-Tagged "adapters" "FAIL"; Add-Tagged "gateway-config" "FAIL"
Assert-Equal 'D: no adapter -> local' (Get-FingerprintSummary).Key "local"
Reset-Results; Add-Tagged "adapters" "PASS"; Add-Tagged "gateway-config" "PASS"; Add-Tagged "ping-gateway" "FAIL"; Add-Tagged "connectivity-group" "FAIL"
Assert-Equal 'D: gateway silent -> gateway-unreachable' (Get-FingerprintSummary).Key "gateway-unreachable"
# backlog #58: the summary for a gateway that did not answer says what that does and does not establish - a fourth
# line before the send-to-IT one - and the summary for a gateway that answered has no such line.
Assert-Equal 'D: #58 the unreachable-gateway summary carries the suspect-not-conviction line' ((Get-FingerprintSummary).Lines.Count) 5
# The most a section can hold, which the user manual states as its maximum (PR #50, round 1: the manual said five and
# six is reachable): the gateway summary's four lines, the sentence naming the rows that were not measured, and the
# send-to-IT line. A weightless row changes no predicate, so the key stays and only the count moves.
Add-CheckResult -Category "T" -Check "TCPv4 counters" -Status "ERROR" -Message "m" -Details "" -Tag "tcp-retransmissions" -Weightless | Out-Null
Assert-Equal 'D: #58 beside a weightless row the section is six lines, the documented maximum' ((Get-FingerprintSummary).Lines.Count) 6
Assert-Equal 'D: #58 and the weightless row moved the count, not the key' (Get-FingerprintSummary).Key "gateway-unreachable"
Reset-Results; Add-Tagged "adapters" "PASS"; Add-Tagged "ping-gateway" "PASS"; Add-Tagged "dns" "FAIL"; Add-Tagged "connectivity-group" "FAIL"
Assert-Equal 'D: gateway ok, internet dead -> gateway-up-internet-dead' (Get-FingerprintSummary).Key "gateway-up-internet-dead"
Assert-Equal 'D: #58 a gateway that answered has nothing to qualify' ((Get-FingerprintSummary).Lines.Count) 4
Reset-Results; Add-Tagged "adapters" "PASS"; Add-Tagged "ping-gateway" "PASS"; Add-Tagged "dns" "FAIL"; Add-Tagged "tcp" "PASS"; Add-Tagged "connectivity-group" "PASS"
Assert-Equal 'D: dns fails, tcp by ip ok -> dns' (Get-FingerprintSummary).Key "dns"
Reset-Results; Add-Tagged "adapters" "PASS"; Add-Tagged "ping-gateway" "PASS"; Add-Tagged "tcp-retransmissions" "WARN"; Add-Tagged "connectivity-group" "PASS"
Assert-Equal 'D: retransmissions warn -> quality' (Get-FingerprintSummary).Key "quality"
Reset-Results; Add-Tagged "adapters" "PASS"; Add-Tagged "ping-gateway" "PASS"; Add-Tagged "connectivity-group" "PASS"; Add-Tagged "expected-standard" "FAIL"
Assert-Equal 'D: only a standard mismatch -> mixed' (Get-FingerprintSummary).Key "mixed"
Reset-Results; Add-Tagged "adapters" "PASS"; Add-Tagged "ping-gateway" "PASS"; Add-Tagged "connectivity-group" "PASS"; Add-Tagged "tcp-retransmissions" "ERROR"
Assert-Equal 'D: only an error -> incomplete' (Get-FingerprintSummary).Key "incomplete"
Reset-Results; Add-Tagged "adapters" "PASS"; Add-Tagged "ping-gateway" "PASS"; Add-Tagged "connectivity-group" "PASS"
Assert-Equal 'D: all pass -> healthy' (Get-FingerprintSummary).Key "healthy"
Assert-Equal 'D: every fingerprint ends with the send-to-IT line' ((Get-FingerprintSummary).Lines.Count) 3
Reset-Results; Add-Tagged "adapters" "PASS"; Add-Tagged "ping-gateway" "PASS"; Add-Tagged "connectivity-group" "PASS"; Add-Tagged "config" "WARN"
Assert-Equal 'D: config warning only -> attention, not quality (round 3)' (Get-FingerprintSummary).Key "attention"
Assert-Equal 'D: attention has two lines plus the send line' ((Get-FingerprintSummary).Lines.Count) 3
Reset-Results; Add-Tagged "adapters" "PASS"; Add-Tagged "ping-gateway" "PASS"; Add-Tagged "dns" "PASS"; Add-Tagged "dns" "WARN"; Add-Tagged "tcp" "PASS"; Add-Tagged "connectivity-group" "PASS"
Assert-Equal 'D: optional DNS fails while the main DNS passes -> attention, not dns (round 3)' (Get-FingerprintSummary).Key "attention"
Reset-Results; Add-Tagged "adapters" "PASS"; Add-Tagged "ping-gateway" "PASS"; Add-Tagged "connectivity-group" "PASS"; Add-Tagged "tcp-retransmissions" "FAIL"
Assert-Equal 'D: retransmission FAIL alone -> quality (round 3b)' (Get-FingerprintSummary).Key "quality"
Reset-Results; Add-Tagged "adapters" "PASS"; Add-Tagged "ping-gateway" "PASS"; Add-Tagged "connectivity-group" "PASS"; Add-Tagged "tcp-retransmissions" "FAIL"; Add-Tagged "expected-standard" "FAIL"
Assert-Equal 'D: retransmission FAIL plus another failure -> mixed' (Get-FingerprintSummary).Key "mixed"
Reset-Results; Add-Tagged "adapters" "PASS"; Add-Tagged "ping-gateway" "PASS"; Add-Tagged "connectivity-group" "PASS"; Add-Tagged "connectivity-group" "WARN"
Assert-Equal 'D: optional group fails while the required group passes -> attention, not internet-dead (round 5)' (Get-FingerprintSummary).Key "attention"
Reset-Results; Add-Tagged "adapters" "PASS"; Add-Tagged "ping-gateway" "PASS"; Add-Tagged "connectivity-group" "FAIL"; Add-Tagged "connectivity-group" "PASS"
Assert-Equal 'D: required group fails while another passes -> mixed, not internet-dead' (Get-FingerprintSummary).Key "mixed"
Reset-Results; Add-Tagged "adapters" "PASS"; Add-Tagged "ping-gateway" "ERROR"; Add-Tagged "connectivity-group" "PASS"
Assert-Equal 'D: gateway ping could not execute -> incomplete, not gateway-unreachable (round 5)' (Get-FingerprintSummary).Key "incomplete"
# backlog #67: the fingerprint reads which measurement decided the gateway row. A gateway that answered every probe
# slowly is reachable, so it is a quality finding - or mixed, beside another failure - and never "does not answer";
# a row decided by its loss, and a failed row that names no rule at all, keep the reading they always had.
function Add-Ruled($tag, $status, $rule) { Add-CheckResult -Category "T" -Check $tag -Status $status -Message "m" -Details "" -Tag $tag -Rule $rule | Out-Null }
Reset-Results; Add-Tagged "adapters" "PASS"; Add-Tagged "gateway-config" "PASS"; Add-Ruled "ping-gateway" "FAIL" "latency"; Add-Tagged "connectivity-group" "PASS"
Assert-Equal 'D: #67 a slow gateway alone -> quality, not gateway-unreachable' (Get-FingerprintSummary).Key "quality"
Reset-Results; Add-Tagged "adapters" "PASS"; Add-Tagged "gateway-config" "PASS"; Add-Ruled "ping-gateway" "FAIL" "latency"; Add-Tagged "connectivity-group" "FAIL"
Assert-Equal 'D: #67 a slow gateway beside a failed group -> mixed, not gateway-unreachable' (Get-FingerprintSummary).Key "mixed"
Reset-Results; Add-Tagged "adapters" "PASS"; Add-Tagged "gateway-config" "PASS"; Add-Ruled "ping-gateway" "FAIL" "loss"; Add-Tagged "connectivity-group" "FAIL"
Assert-Equal 'D: #67 a gateway that lost its replies -> gateway-unreachable' (Get-FingerprintSummary).Key "gateway-unreachable"
$silentLines = @((Get-FingerprintSummary).Lines)
Assert-Equal 'D: #67 the rule field is on every row, empty unless a row sets it' ((@($script:Results)[0].PSObject.Properties.Name -contains "Rule") -and (@($script:Results)[0].Rule -eq "")) True
# backlog #60: the near-end rung chooses the second line of that summary and nothing else about it. A near-end host
# that answered leaves the gateway itself; one that lost its replies puts the fault before it; one that answered
# slowly, or that was not measured, leaves the line as it was. The lines are prose in both packages, so what is
# asserted is which of them differ.
# Round 4: the pairing is by Path - the adapter both rows' lookups agreed on - because a near-end host reached through
# one adapter says nothing about another adapter's cable, radio or switch. The run writes a Path on every ping row
# whose lookups before and after the probes agreed, and a near-end row carries one whenever it carries its tag.
function Add-Pathed($tag, $status, $rule, $path) { Add-CheckResult -Category "T" -Check $tag -Status $status -Message "m" -Details "" -Tag $tag -Rule $rule -Path $path | Out-Null }
Reset-Results; Add-Tagged "adapters" "PASS"; Add-Tagged "gateway-config" "PASS"; Add-Pathed "ping-near-end" "PASS" "" "Wi-Fi"; Add-Pathed "ping-gateway" "FAIL" "loss" "Wi-Fi"; Add-Tagged "connectivity-group" "FAIL"
$nearPassSummary = Get-FingerprintSummary
Assert-Equal 'D: #60 a near-end host that answered leaves the key' $nearPassSummary.Key "gateway-unreachable"
Assert-Equal 'D: #60 and the line count' (@($nearPassSummary.Lines).Count) 5
Assert-Equal 'D: #60 but chooses a second line of its own' (@($nearPassSummary.Lines)[1] -eq $silentLines[1]) False
Assert-Equal 'D: #60 leaving the first line alone' (@($nearPassSummary.Lines)[0] -eq $silentLines[0]) True
Assert-Equal 'D: #60 and the third' (@($nearPassSummary.Lines)[2] -eq $silentLines[2]) True
Reset-Results; Add-Tagged "adapters" "PASS"; Add-Tagged "gateway-config" "PASS"; Add-Pathed "ping-near-end" "FAIL" "loss" "Wi-Fi"; Add-Pathed "ping-gateway" "FAIL" "loss" "Wi-Fi"; Add-Tagged "connectivity-group" "FAIL"
$nearLostSummary = Get-FingerprintSummary
Assert-Equal 'D: #60 a near-end host that lost its replies too keeps the key' $nearLostSummary.Key "gateway-unreachable"
Assert-Equal 'D: #60 and chooses a third second line' ((@($nearLostSummary.Lines)[1] -ne $silentLines[1]) -and (@($nearLostSummary.Lines)[1] -ne @($nearPassSummary.Lines)[1])) True
Reset-Results; Add-Tagged "adapters" "PASS"; Add-Tagged "gateway-config" "PASS"; Add-Pathed "ping-near-end" "FAIL" "latency" "Wi-Fi"; Add-Pathed "ping-gateway" "FAIL" "loss" "Wi-Fi"; Add-Tagged "connectivity-group" "FAIL"
Assert-Equal 'D: #60 a slow near-end host decides nothing about that line' (@((Get-FingerprintSummary).Lines)[1] -eq $silentLines[1]) True
Reset-Results; Add-Tagged "adapters" "PASS"; Add-Tagged "gateway-config" "PASS"; Add-Pathed "ping-near-end" "PASS" "" "Wi-Fi"; Add-Pathed "ping-gateway" "FAIL" "loss" "Ethernet"; Add-Tagged "connectivity-group" "FAIL"
Assert-Equal 'D: #60 a near-end host on another adapter than the failed gateway keeps the neutral line' (@((Get-FingerprintSummary).Lines)[1] -eq $silentLines[1]) True
Reset-Results; Add-Tagged "adapters" "PASS"; Add-Tagged "gateway-config" "PASS"; Add-Pathed "ping-near-end" "PASS" "" "Wi-Fi"; Add-Pathed "ping-gateway" "FAIL" "loss" ""; Add-Tagged "connectivity-group" "FAIL"
Assert-Equal 'D: #60 a failed gateway whose lookups did not agree keeps it too' (@((Get-FingerprintSummary).Lines)[1] -eq $silentLines[1]) True
Reset-Results; Add-Tagged "adapters" "PASS"; Add-Tagged "gateway-config" "PASS"; Add-Pathed "ping-near-end" "PASS" "" "Wi-Fi"; Add-Pathed "ping-gateway" "FAIL" "loss" "Wi-Fi"; Add-Pathed "ping-gateway" "FAIL" "loss" "Ethernet"; Add-Tagged "connectivity-group" "FAIL"
Assert-Equal 'D: #60 two failed gateways on different adapters keep it' (@((Get-FingerprintSummary).Lines)[1] -eq $silentLines[1]) True
Reset-Results; Add-Tagged "adapters" "PASS"; Add-Tagged "gateway-config" "PASS"; Add-Pathed "ping-near-end" "PASS" "" "Wi-Fi"; Add-Pathed "ping-gateway" "FAIL" "loss" "Wi-Fi"; Add-Pathed "ping-gateway" "FAIL" "loss" "Wi-Fi"; Add-Tagged "connectivity-group" "FAIL"
Assert-Equal 'D: #60 two failed gateways on the near-end host''s own adapter take the near-end line' (@((Get-FingerprintSummary).Lines)[1] -eq @($nearPassSummary.Lines)[1]) True
Reset-Results; Add-Tagged "adapters" "PASS"; Add-Tagged "gateway-config" "PASS"; Add-Pathed "ping-near-end" "PASS" "" ""; Add-Pathed "ping-gateway" "FAIL" "loss" "Wi-Fi"; Add-Tagged "connectivity-group" "FAIL"
Assert-Equal 'D: #60 a near-end row without a path - which the run never writes - keeps the neutral line' (@((Get-FingerprintSummary).Lines)[1] -eq $silentLines[1]) True
Assert-Equal 'D: #60 the path field is on every row, empty unless a row sets it' ((@($script:Results)[0].PSObject.Properties.Name -contains "Path") -and (@($script:Results)[0].Path -eq "")) True
Reset-Results; Add-Tagged "adapters" "PASS"; Add-Tagged "gateway-config" "PASS"; Add-CheckResult -Category "T" -Check "ping-near-end" -Status "INFO" -Message "m" -Details "" -Tag "ping-near-end" -Weightless | Out-Null; Add-Ruled "ping-gateway" "FAIL" "loss"; Add-Tagged "connectivity-group" "FAIL"
Assert-Equal 'D: #60 a near-end host that was not probed decides nothing about it either' (@((Get-FingerprintSummary).Lines)[1] -eq $silentLines[1]) True
# The near-end row is a quality row like the other rungs, and in a healthy run an optional one that answered nothing
# is named as such - while one that was not probed, because it was not on this network, is named among the rows that
# were not measured and never as one that did not answer.
Reset-Results; Add-Tagged "adapters" "PASS"; Add-Tagged "ping-gateway" "PASS"; Add-Tagged "connectivity-group" "PASS"; Add-Tagged "ping-near-end" "WARN"
Assert-Equal 'D: #60 a degraded near-end host is a quality finding' (Get-FingerprintSummary).Key "quality"
Reset-Results; Add-Tagged "adapters" "PASS"; Add-Tagged "ping-gateway" "PASS"; Add-Tagged "connectivity-group" "PASS"; Add-Tagged "ping-near-end" "INFO"
$quietNearEnd = Get-FingerprintSummary
Assert-Equal 'D: #60 an optional near-end host that did not answer is still healthy' $quietNearEnd.Key "healthy"
Assert-Equal 'D: #60 and is named as one that did not answer' ((@($quietNearEnd.Lines).Count -eq 4) -and (@($quietNearEnd.Lines)[1] -match 'ping-near-end')) True
Reset-Results; Add-Tagged "adapters" "PASS"; Add-Tagged "ping-gateway" "PASS"; Add-Tagged "connectivity-group" "PASS"; Add-CheckResult -Category "T" -Check "ping-near-end" -Status "INFO" -Message "m" -Details "" -Tag "ping-near-end" -Weightless | Out-Null
$unplacedNearEnd = Get-FingerprintSummary
Assert-Equal 'D: #60 one that was not on this network is healthy too' $unplacedNearEnd.Key "healthy"
Assert-Equal 'D: #60 named among the rows that were not measured, not as one that did not answer' ((@($unplacedNearEnd.Lines).Count -eq 4) -and (@($unplacedNearEnd.Lines)[1] -eq @((Get-FingerprintSummary).Lines)[1]) -and (@($unplacedNearEnd.Lines)[1] -ne @($quietNearEnd.Lines)[1]) -and (@($unplacedNearEnd.Lines)[2] -match 'ping-near-end')) True

# --- Scenario E: run options / profile text ---
$o = Set-RunOptions -Overrides @{ EntryPoint = "IT"; ExpandDetails = $true; PingTarget = @("10.0.0.1"); TcpTarget = @("host:445", "bad"); SampleSeconds = 20; TracerouteHops = 99; NoWifi = $true }
Assert-Equal 'E: entry point IT' $o.EntryPoint "IT"
Assert-Equal 'E: extra ping appended to config' (@($script:Config.Tests.PingTargets).Count) 3
Assert-Equal 'E: valid tcp extra appended, invalid ignored' (@($script:Config.Tests.TcpTargets).Count) 2
Assert-Equal 'E: invalid tcp reported as a per-run option notice' (@($script:RunOptionMessages | Where-Object { $_ -match 'bad' }).Count) 1
Assert-Equal 'E: startup messages untouched by option notices' (@($script:StartupMessages | Where-Object { $_ -match 'bad' }).Count) 0
Assert-Equal 'E: sample seconds override' $o.SampleSeconds 20
Assert-Equal 'E: out-of-range hops -> default 3' $o.TracerouteHops 3
Assert-Equal 'E: NoWifi disables the check' $o.ChecksEnabled.WifiRf False
Assert-Equal 'E: base config untouched' (@($script:BaseConfig.Tests.PingTargets).Count) 2
Assert-Equal 'E: profile text mentions the extra target' ((Get-RunProfileText) -match '10\.0\.0\.1') True
# The wireless retry flag (backlog #61) is a configuration switch with no panel box and no parameter: projected like the
# others, on as shipped, off only from the file, and named among the disabled in the run profile when it is off.
Assert-Equal 'E: the wireless retry flag is projected, on as shipped' $o.ChecksEnabled.WifiRetryCounters True
$script:BaseConfig.Checks.WifiRetryCounters = $false
$oOff = Set-RunOptions -Overrides @{ EntryPoint = "IT"; PingTarget = @("10.0.0.1") }
Assert-Equal 'E: and follows the configuration when it is off' $oOff.ChecksEnabled.WifiRetryCounters False
Assert-Equal 'E: the run profile names it among the disabled checks' ((Get-RunProfileText) -match 'WifiRetryCounters') True
Assert-Equal 'E: the panel override touches only the boxes it has' (@($oOff.ChecksEnabled.PSObject.Properties).Count) 7
$script:BaseConfig.Checks.WifiRetryCounters = $true
$o = Set-RunOptions -Overrides @{ EntryPoint = "IT"; ExpandDetails = $true; PingTarget = @("10.0.0.1"); TcpTarget = @("host:445", "bad"); SampleSeconds = 20; TracerouteHops = 99; NoWifi = $true }
Assert-Equal 'E: back on once the configuration says so' $o.ChecksEnabled.WifiRetryCounters True
Set-RunOptions -Overrides @{ TcpTarget = @("host:445") } | Out-Null
Assert-Equal 'E: stale option notice cleared when options are reapplied (round 3)' (@($script:RunOptionMessages).Count) 0
Set-RunOptions -Overrides @{ PingTarget = @("10.0.0.1,10.0.0.2"); TcpTarget = @("1.1.1.1:53;bad") } | Out-Null
Assert-Equal 'E: comma-separated -File values are split (round 3b)' (@($script:Config.Tests.PingTargets).Count) 4
Assert-Equal 'E: split tcp: valid appended, invalid reported once' (@($script:Config.Tests.TcpTargets).Count) 2
Assert-Equal 'E: split tcp: exactly one notice' (@($script:RunOptionMessages).Count) 1
Assert-Equal 'E: raw targets keep the invalid value for the panel (round 4)' (@($script:RunOptions.RawTargets.Tcp) -join ',') "1.1.1.1:53,bad"
Assert-Equal 'E: accepted targets exclude it' (@($script:RunOptions.ExtraTargets.Tcp) -join ',') "1.1.1.1:53"
Set-RunOptions -Overrides @{ HttpUrl = @("https://h/search?ids=1,2;3 https://b/") } | Out-Null
Assert-Equal 'E: URLs split on spaces only, commas/semicolons kept (round 5)' (@($script:RunOptions.ExtraTargets.Http) -join ' | ') "https://h/search?ids=1,2;3 | https://b/"
Assert-Equal 'E: two extra HTTP targets appended' (@($script:Config.Tests.HttpTargets).Count) 3
Set-RunOptions -Overrides @{ PingTarget = @("10.0.0.1 10.0.0.2"); DnsName = @("a.corp; b.corp"); TcpTarget = @("h1:445 h2:445") } | Out-Null
Assert-Equal 'E: whitespace-separated CLI values are split like the panel (round 6)' (@($script:RunOptions.ExtraTargets.Ping) -join ',') "10.0.0.1,10.0.0.2"
Assert-Equal 'E: mixed separators for DNS' (@($script:RunOptions.ExtraTargets.Dns) -join ',') "a.corp,b.corp"
Assert-Equal 'E: whitespace-separated TCP targets both accepted' (@($script:RunOptions.ExtraTargets.Tcp) -join ',') "h1:445,h2:445"

# --- Scenario F: IT-scoped failures never change the verdict or the counts (review round 1) ---
Set-RunOptions -Overrides @{} | Out-Null
Reset-Results; Add-Tagged "adapters" "PASS"; Add-Tagged "ping-gateway" "PASS"; Add-Tagged "connectivity-group" "PASS"
Add-CheckResult -Category "IT" -Check "routes" -Status "ERROR" -Message "could not read" -Details "" -Tag "routes" -Scope "IT" | Out-Null
Add-CheckResult -Category "IT" -Check "wifi" -Status "INFO" -Message "data" -Details "" -Tag "wifi" -Scope "IT" | Out-Null
Assert-Equal 'F: overall stays PASS with an IT-scoped ERROR' (Get-OverallStatus).Code "PASS"
Assert-Equal 'F: fingerprint stays healthy' (Get-FingerprintSummary).Key "healthy"
Assert-Equal 'F: counts exclude IT rows (Error)' (Get-SummaryCounts).Error 0
Assert-Equal 'F: counts exclude IT rows (Total)' (Get-SummaryCounts).Total 3
$stepOut = Invoke-CheckStep -Category "IT" -Name "boom" -Progress 74 -Scope "IT" -Action { throw "collector exploded" }
Assert-Equal 'F: step failure inside the IT scope is recorded in the IT scope' ($script:Results[$script:Results.Count - 1].Scope) "IT"
Assert-Equal 'F: overall still PASS after an IT step failure' (Get-OverallStatus).Code "PASS"
$stepOut = Invoke-CheckStep -Category "Main" -Name "boom2" -Progress 10 -Action { throw "main exploded" }
Assert-Equal 'F: a main-scope step failure still flips the verdict' (Get-OverallStatus).Code "ERROR"

# --- Scenario G: adapter counter rows — virtual always INFO, zero-traffic PASS -> INFO, physical errors keep their status ---
Reset-Results
function New-Stat($rxErr, $txErr, $rxDisc, $txDisc, $rxB, $txB) { [pscustomobject][ordered]@{ Name = "x"; ReceivedPacketErrors = [uint64]$rxErr; OutboundPacketErrors = [uint64]$txErr; ReceivedDiscardedPackets = [uint64]$rxDisc; OutboundDiscardedPackets = [uint64]$txDisc; ReceivedBytes = [uint64]$rxB; SentBytes = [uint64]$txB } }
$before = @{ "VPN" = (New-Stat 0 0 0 0 1000 1000); "Wi-Fi" = (New-Stat 0 0 0 0 1000 1000); "Idle" = (New-Stat 0 0 0 0 500 500) }
$after  = @{ "VPN" = (New-Stat 50 0 0 0 5000 5000); "Wi-Fi" = (New-Stat 50 0 0 0 5000 5000); "Idle" = (New-Stat 0 0 0 0 500 500) }
$adapters = @([pscustomobject]@{ Name = "VPN"; IsPhysical = $false }, [pscustomobject]@{ Name = "Wi-Fi"; IsPhysical = $true }, [pscustomobject]@{ Name = "Idle"; IsPhysical = $true })
Compare-AdapterStatistics -Before $before -After $after -Adapters $adapters
$byName = @{}; foreach ($r in $script:Results) { $byName[$r.Check] = $r }
Assert-Equal 'G: virtual adapter with 50 errors -> INFO' $byName["VPN"].Status "INFO"
Assert-Equal 'G: physical adapter with 50 errors -> FAIL' $byName["Wi-Fi"].Status "FAIL"
Assert-Equal 'G: zero-traffic physical adapter -> INFO' $byName["Idle"].Status "INFO"
Assert-Equal 'G: overall not affected by the virtual adapter alone' ((Get-OverallStatus).Code -eq "FAIL") True

# --- Scenario G2: counter reset (values decreased) — virtual adapter INFO, physical adapter WARN (review round 2) ---
Reset-Results
$before = @{ "VPN" = (New-Stat 5 0 0 0 9000 9000); "Wi-Fi" = (New-Stat 5 0 0 0 9000 9000) }
$after  = @{ "VPN" = (New-Stat 0 0 0 0 100 100); "Wi-Fi" = (New-Stat 0 0 0 0 100 100) }
Compare-AdapterStatistics -Before $before -After $after -Adapters @([pscustomobject]@{ Name = "VPN"; IsPhysical = $false }, [pscustomobject]@{ Name = "Wi-Fi"; IsPhysical = $true })
$byName = @{}; foreach ($r in $script:Results) { $byName[$r.Check] = $r }
Assert-Equal 'G2: reset on a virtual adapter -> INFO' $byName["VPN"].Status "INFO"
Assert-Equal 'G2: reset on a physical adapter -> WARN' $byName["Wi-Fi"].Status "WARN"

# --- Scenario H: default routes sorted by effective metric ---
$routes = @([pscustomobject]@{ NextHop = "10.0.0.1"; RouteMetric = 10; InterfaceMetric = 100 }, [pscustomobject]@{ NextHop = "192.168.1.1"; RouteMetric = 20; InterfaceMetric = 5 }, [pscustomobject]@{ NextHop = "172.16.0.1"; RouteMetric = 0; InterfaceMetric = 50 })
$sorted = @(Sort-DefaultRoutes -Routes $routes)
Assert-Equal 'H: lowest effective metric first' $sorted[0].NextHop "192.168.1.1"
Assert-Equal 'H: second' $sorted[1].NextHop "172.16.0.1"
Assert-Equal 'H: third' $sorted[2].NextHop "10.0.0.1"

# --- Scenario I: the IT panel keeps configured sampling values above the spinner defaults (Codex round 7 on PR #3, v1.2.1) ---
# Real WinForms controls, created headless (no form, no message loop), wired exactly like Initialize-Gui builds the panel.
Add-Type -AssemblyName System.Windows.Forms
function New-PanelControls {
    $c = @{}
    foreach ($key in @("PingTarget", "DnsName", "TcpTarget", "HttpUrl")) { $c[$key] = New-Object System.Windows.Forms.TextBox }
    foreach ($item in @(@{ Key = "PingCount"; Min = 1; Max = 21 }, @{ Key = "PingCountMaximum"; Min = 1; Max = 21 }, @{ Key = "SampleSeconds"; Min = 1; Max = 120 }, @{ Key = "TracerouteHops"; Min = 1; Max = 10 })) {
        $s = New-Object System.Windows.Forms.NumericUpDown; $s.Minimum = $item.Min; $s.Maximum = $item.Max; $c[$item.Key] = $s
    }
    foreach ($key in @("WifiRf", "RouteTable", "GatewayNeighbor", "ProxySettings", "DriverInfo", "Traceroute", "ExpandDetails")) { $c[$key] = New-Object System.Windows.Forms.CheckBox }
    return $c
}
$script:OptionsPanel = New-PanelControls
$script:BaseConfig.Tests.PingCount = 30
$script:BaseConfig.Tests.RetransmissionSampleSeconds = 300
Set-RunOptions -Overrides @{ EntryPoint = "IT"; ExpandDetails = $true } | Out-Null
Set-OptionsPanelValues
Assert-Equal 'I: panel shows the configured ping count 30 (spinner default range 1-20)' $script:OptionsPanel["PingCount"].Value 30
Assert-Equal 'I: panel shows the configured sample 300 s (spinner default range 1-120)' $script:OptionsPanel["SampleSeconds"].Value 300
Assert-Equal 'I: spinner range widened to the configured ping count' $script:OptionsPanel["PingCount"].Maximum 30
Assert-Equal 'I: spinner range widened to the configured sample seconds' $script:OptionsPanel["SampleSeconds"].Maximum 300
$o = Set-RunOptions -Overrides (Get-RunOptionsFromPanel)
Assert-Equal 'I: an untouched Start keeps ping count 30' $o.PingCount 30
Assert-Equal 'I: an untouched Start keeps sample 300 s' $o.SampleSeconds 300
Assert-Equal 'I: effective config carries the configured values' ("$($script:Config.Tests.PingCount)/$($script:Config.Tests.RetransmissionSampleSeconds)") "30/300"
Assert-Equal 'I: profile text carries the configured values' ((Get-RunProfileText) -match '(ping count|Ping 次數) 30 \| (ping ceiling|Ping 上限) 30 \| (sample 300 s|取樣 300 秒)') True
$script:OptionsPanel["PingCount"].Value = 12
$script:OptionsPanel["SampleSeconds"].Value = 45
$o = Set-RunOptions -Overrides (Get-RunOptionsFromPanel)
Assert-Equal 'I: a panel edit still wins (ping count 12)' $o.PingCount 12
Assert-Equal 'I: a panel edit still wins (sample 45 s)' $o.SampleSeconds 45
Set-RunOptions -Overrides @{ EntryPoint = "IT"; ExpandDetails = $true } | Out-Null; Set-OptionsPanelValues
Assert-Equal 'I: Reset to config restores the configured ping count' $script:OptionsPanel["PingCount"].Value 30
Assert-Equal 'I: Reset to config restores the configured sample seconds' $script:OptionsPanel["SampleSeconds"].Value 300
$script:BaseConfig.Tests.PingCount = 4
$script:BaseConfig.Tests.RetransmissionSampleSeconds = 8
Set-RunOptions -Overrides @{ EntryPoint = "IT" } | Out-Null; Set-OptionsPanelValues
# The ping spinners' range is the configured ceiling since 1.2.10 (backlog #51), not a number of the panel's own:
# it opened at 20 until then, and nothing in the repository or the package said why. The widening a configured
# value above it produces is what v1.2.1 decided and is unchanged - it is what it widens from that now means
# something, and PingCountMaximum's default is 21 because that is where one lost reply stops reaching the shipped
# 5 % warning threshold.
Assert-Equal 'I: the default config opens the ping spinners at the configured ceiling' $script:OptionsPanel["PingCount"].Maximum 21
Assert-Equal 'I: and the ceiling spinner has the same range as the count' $script:OptionsPanel["PingCountMaximum"].Maximum 21
Assert-Equal 'I: with the configured ceiling in it' $script:OptionsPanel["PingCountMaximum"].Value 21
Assert-Equal 'I: default config keeps the 1-120 s sample range' $script:OptionsPanel["SampleSeconds"].Maximum 120
Assert-Equal 'I: default values shown (4 / 8)' ("$($script:OptionsPanel['PingCount'].Value)/$($script:OptionsPanel['SampleSeconds'].Value)") "4/8"
Set-RunOptions -Overrides @{ EntryPoint = "IT"; PingCount = 25 } | Out-Null; Set-OptionsPanelValues
Assert-Equal 'I: a CLI -PingCount 25 above the default range is shown, not clamped' $script:OptionsPanel["PingCount"].Value 25
Assert-Equal 'I: and the ceiling follows it, because a ceiling below the starting count sends nothing less' $script:OptionsPanel["PingCountMaximum"].Value 25
Set-RunOptions -Overrides @{ EntryPoint = "IT"; PingCountMaximum = 40 } | Out-Null; Set-OptionsPanelValues
Assert-Equal 'I: a CLI -PingCountMaximum 40 widens both spinners' $script:OptionsPanel["PingCount"].Maximum 40
Assert-Equal 'I: and an untouched Start keeps it' ((Set-RunOptions -Overrides (Get-RunOptionsFromPanel)).PingCountMaximum) 40
Assert-Equal 'I: traceroute hops keep the shared 1-10 rule' $script:OptionsPanel["TracerouteHops"].Maximum 10
$script:OptionsPanel = $null


# --- Scenario J: the claim, the explanation, the file to send, and the field checked before the run ---
# Backlog #35, #40, #46 and #45. Every assertion is written for both languages, because both scripts ship the same
# behaviour with their own strings.

# A healthy run with one optional target that did not answer, and no counter read at all.
$script:Results = New-Object System.Collections.ArrayList
$script:RetransmissionRateComputed = $false
Add-CheckResult -Category "Test" -Check "Gateway" -Status "PASS" -Message "ok" -Details "" -Tag "ping-gateway" | Out-Null
# Two added targets of the same kind, which is where a generic row title would collapse them into one name
# (PR #35, round 2): Set-RunOptions gives every added target its value in the title, so both are named.
Add-CheckResult -Category "Test" -Check "Extra ping 10.0.0.1" -Status "INFO" -Message "no reply" -Details "" -Tag "ping-target" | Out-Null
Add-CheckResult -Category "Test" -Check "Extra TCP fileserver:445" -Status "INFO" -Message "no connection" -Details "" -Tag "tcp" | Out-Null
$summary = Get-FingerprintSummary
Assert-Equal 'J: an optional target that did not answer leaves the verdict healthy' $summary.Key "healthy"
Assert-Equal 'J: the summary claims required, not all (#35)' (@($summary.Lines)[0] -match '(All required checks passed|必要檢查都通過)') True
Assert-Equal 'J: and names both targets that did not answer' ((@($summary.Lines)[1] -match '10\.0\.0\.1') -and (@($summary.Lines)[1] -match 'fileserver:445')) True
Assert-Equal 'J: the last line names one file (#46)' ((@($summary.Lines)[-1] -match '(Send this file|把這個檔案)')) True
Assert-Equal 'J: and no longer offers a choice of two' ((@($summary.Lines)[-1] -match '(or the JSON|或 JSON)')) False
$flags = Get-ReportNoticeFlags
Assert-Equal 'J: no Unable to Check row -> no badge half (#40)' $flags.Unable False
Assert-Equal 'J: no rate computed -> no rate half (#40)' $flags.Rate False
$r = Complete-ReportStage -SaveResult (Save-Reports)
$html = Get-Content -LiteralPath $r.Html -Raw
$txt = Get-Content -LiteralPath $r.Text -Raw
# The IT block carries a notice div of its own, so the assertion is about the sentences and not the class.
Assert-Equal 'J: a healthy report explains no badge it does not carry' ($html -match '(Unable to Check" means|「無法檢查」表示)') False
Assert-Equal 'J: and qualifies no rate it never computed' ($html -match '(retransmission rate is an approximate|重傳比例為本機)') False
Assert-Equal 'J: and no Note line' ($txt -match '(?m)^(Note:|注意：)') False
Assert-Equal 'J: the window quotes the file the report stage calls primary' ((Get-SendToItLine $r.PrimaryReport) -match [regex]::Escape($r.Html)) True

# The other shape: a row that could not be checked, and a rate that was computed.
$script:Results = New-Object System.Collections.ArrayList
$script:RetransmissionRateComputed = $true
Add-CheckResult -Category "Test" -Check "Counters" -Status "ERROR" -Message "could not read" -Details "" -Tag "tcp-retransmissions" | Out-Null
$flags = Get-ReportNoticeFlags
Assert-Equal 'J: an Unable to Check row brings the badge half back' $flags.Unable True
Assert-Equal 'J: a computed rate brings the rate half back' $flags.Rate True
$r = Complete-ReportStage -SaveResult (Save-Reports)
$html = Get-Content -LiteralPath $r.Html -Raw
$txt = Get-Content -LiteralPath $r.Text -Raw
Assert-Equal 'J: the notice is back in the HTML' ($html -match '(Unable to Check" means|「無法檢查」表示)') True
Assert-Equal 'J: with both halves' (($html -match '(Unable to Check|無法檢查)') -and ($html -match '(retransmission rate|重傳比例)')) True
Assert-Equal 'J: and back in the text report' ($txt -match '(Note:|注意：)') True

# The panel checks with the rule the run itself uses (#45).
$script:OptionsPanel = New-PanelControls
$script:OptionsPanel["TcpTarget"].Text = "8.8.8.8"
$rejected = @(Get-RejectedPanelValues)
Assert-Equal 'J: the panel rejects a target with no port before the run starts' $rejected.Count 1
Assert-Equal 'J: and names an example value, not the notation' ($rejected[0].Problem -match '8\.8\.8\.8:443') True
$script:OptionsPanel["TcpTarget"].Text = "8.8.8.8:443"
Assert-Equal 'J: a well-formed target is accepted' (@(Get-RejectedPanelValues).Count) 0
$script:RunOptionMessages = New-Object System.Collections.ArrayList
Set-RunOptions -Overrides @{ EntryPoint = "IT"; TcpTarget = @("8.8.8.8") } | Out-Null
Assert-Equal 'J: the run drops exactly what the panel would have refused' ((@($script:RunOptionMessages) -join " ") -match '(expected host:port|格式應為 host:port)') True
# The accepted half of the same rule, after the message assertion because Set-RunOptions starts a new message list.
# Every added target is named here once and only once: the ping rows get their address from Test-PingTargets, which
# writes the title as "<name>: <target>", so the ping entry keeps the plain name and the other three carry the value
# themselves (PR #35, rounds 2 and 3).
Set-RunOptions -Overrides @{ EntryPoint = "IT"; PingTarget = @("10.0.0.1"); DnsName = @("a.example"); TcpTarget = @("fileserver:445"); HttpUrl = @("https://a.example/") } | Out-Null
$added = @{}
foreach ($t in @($script:Config.Tests.PingTargets)) { if ([string]$t.Address -eq '10.0.0.1') { $added['ping'] = [string]$t.Name } }
foreach ($t in @($script:Config.Tests.DnsNames)) { if ([string]$t.Host -eq 'a.example') { $added['dns'] = [string]$t.Name } }
foreach ($t in @($script:Config.Tests.TcpTargets)) { if ([string]$t.Host -eq 'fileserver') { $added['tcp'] = [string]$t.Name } }
foreach ($t in @($script:Config.Tests.HttpTargets)) { if ([string]$t.Url -eq 'https://a.example/') { $added['http'] = [string]$t.Name } }
Assert-Equal 'J: the added ping keeps the plain name, because the row adds the target itself' ($added['ping'] -match '^(Extra ping|額外 Ping)$') True
Assert-Equal 'J: the added DNS name carries its value' ($added['dns'] -match 'a\.example$') True
Assert-Equal 'J: the added TCP target carries its value' ($added['tcp'] -match 'fileserver:445$') True
Assert-Equal 'J: the added URL carries its value' ($added['http'] -match 'https://a\.example/$') True
$ruleCalls = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq "Test-TcpTargetSyntax" }, $true))
Assert-Equal 'J: one rule, called by both the run and the panel' ($ruleCalls.Count -ge 2) True
$script:OptionsPanel = $null

# --- Scenario K: what the verdict follows, and what it stops following (backlog #39) ---
# Every fixture below asserts its own row count first. Against a script without the marking, -Weightless fails to
# bind and the row is never added at all, so a verdict assertion alone would pass for the wrong reason - the run
# would be healthy because nothing was there. The count is what makes the rest of each fixture mean something.
# The rule is one sentence: the overall result is decided by what the run measured. Every assertion below is written
# for both languages, and each is paired with its opposite - the same row weighted - so that what is proved is the
# marking and not the fixture.

# A run in which every check passed and one counter could not be read: the case this decision was written for, where
# 1.2.7 said Test Incomplete on a healthy network and the manual had to apologise for the verdict.
$script:Results = New-Object System.Collections.ArrayList
$script:RetransmissionRateComputed = $false
Add-CheckResult -Category "Test" -Check "Gateway" -Status "PASS" -Message "ok" -Details "" -Tag "ping-gateway" | Out-Null
Add-CheckResult -Category "Test" -Check "TCPv4 counters" -Status "ERROR" -Message "unreadable" -Details "" -Tag "tcp-retransmissions" -Weightless | Out-Null
Assert-Equal 'K: the fixture built its 2 row(s)' (@($script:Results).Count) 2
Assert-Equal 'K: an unreadable counter leaves a healthy run healthy' (Get-OverallStatus).Code "PASS"
Assert-Equal 'K: and the fingerprint agrees with the verdict' (Get-FingerprintSummary).Key "healthy"
Assert-Equal 'K: the row keeps its badge in the counts' (Get-SummaryCounts).Error 1
Assert-Equal 'K: and the notice still explains that badge (#40)' (Get-ReportNoticeFlags).Unable True
Assert-Equal 'K: the summary names what was not measured' ((@((Get-FingerprintSummary).Lines) -join " ") -match 'TCPv4 counters') True
# The wireless retry row (backlog #61) is weightless in every shape it takes: a reader that could not be compiled
# leaves a healthy run healthy, and a measured rate - however high - decides nothing, because no threshold for it has
# a stated basis.
$script:Results = New-Object System.Collections.ArrayList
Add-CheckResult -Category "Test" -Check "Gateway" -Status "PASS" -Message "ok" -Details "" -Tag "ping-gateway" | Out-Null
Add-CheckResult -Category "Test" -Check "Wireless retries" -Status "ERROR" -Message "not compiled" -Details "" -Tag "wifi-retry" -Weightless | Out-Null
Assert-Equal 'K: the wifi-retry fixture built its 2 row(s)' (@($script:Results).Count) 2
Assert-Equal 'K: a wireless reader that could not be compiled leaves a healthy run healthy' (Get-OverallStatus).Code "PASS"
Assert-Equal 'K: and the fingerprint stays healthy' (Get-FingerprintSummary).Key "healthy"
Assert-Equal 'K: the row keeps its Unable-to-Check badge in the counts' (Get-SummaryCounts).Error 1
$script:Results = New-Object System.Collections.ArrayList
Add-CheckResult -Category "Test" -Check "Gateway" -Status "PASS" -Message "ok" -Details "" -Tag "ping-gateway" | Out-Null
Add-CheckResult -Category "Test" -Check "Wireless retries" -Status "INFO" -Message "66 of 211 (31.3%)" -Details "" -Tag "wifi-retry" -Weightless | Out-Null
Assert-Equal 'K: a measured retry rate is an Information row that decides nothing' ("{0}/{1}" -f (Get-OverallStatus).Code, (Get-FingerprintSummary).Key) "PASS/healthy"
# The same row weighted is the 1.2.7 behaviour, and it must still be reachable: nothing is weightless by default.
$script:Results = New-Object System.Collections.ArrayList
Add-CheckResult -Category "Test" -Check "Gateway" -Status "PASS" -Message "ok" -Details "" -Tag "ping-gateway" | Out-Null
Add-CheckResult -Category "Test" -Check "TCPv4 counters" -Status "ERROR" -Message "unreadable" -Details "" -Tag "tcp-retransmissions" | Out-Null
Assert-Equal 'K: the fixture built its 2 row(s)' (@($script:Results).Count) 2
Assert-Equal 'K: the same row unmarked still makes the run Test Incomplete' (Get-OverallStatus).Code "ERROR"
Assert-Equal 'K: and the fingerprint follows it' (Get-FingerprintSummary).Key "incomplete"

# A quality warning that was measured keeps its weight - the decision moves the verdict off rows that could not
# measure, and removes no number from any report.
$script:Results = New-Object System.Collections.ArrayList
Add-CheckResult -Category "Test" -Check "Gateway" -Status "PASS" -Message "ok" -Details "" -Tag "ping-gateway" | Out-Null
Add-CheckResult -Category "Test" -Check "TCPv4" -Status "WARN" -Message "measured rate" -Details "" -Tag "tcp-retransmissions" | Out-Null
Assert-Equal 'K: the fixture built its 2 row(s)' (@($script:Results).Count) 2
Assert-Equal 'K: a measured quality warning still turns the verdict' (Get-OverallStatus).Code "WARN"
Assert-Equal 'K: and still reads as a quality problem' (Get-FingerprintSummary).Key "quality"
# The same row on a sample too coarse for the threshold is weightless (#51's branch, decided here), and then the
# fingerprint must not go on calling it a quality problem - the predicate that concludes follows the weights.
$script:Results = New-Object System.Collections.ArrayList
Add-CheckResult -Category "Test" -Check "Gateway" -Status "PASS" -Message "ok" -Details "" -Tag "ping-gateway" | Out-Null
Add-CheckResult -Category "Test" -Check "TCPv4" -Status "WARN" -Message "small sample" -Details "" -Tag "tcp-retransmissions" -Weightless | Out-Null
Assert-Equal 'K: the fixture built its 2 row(s)' (@($script:Results).Count) 2
Assert-Equal 'K: a sample too small to mean anything does not turn the verdict' (Get-OverallStatus).Code "PASS"
Assert-Equal 'K: and does not leave the fingerprint saying quality' (Get-FingerprintSummary).Key "healthy"
Assert-Equal 'K: while the row is still in the counts' (Get-SummaryCounts).Warn 1

# An input notice must not suppress the quality key either: a weightless row that reached the other-problem
# predicate would turn "Connected, but quality is poor" into "Warnings to review" about the same run.
$script:Results = New-Object System.Collections.ArrayList
Add-CheckResult -Category "Test" -Check "Gateway" -Status "PASS" -Message "ok" -Details "" -Tag "ping-gateway" | Out-Null
Add-CheckResult -Category "Test" -Check "TCPv4" -Status "WARN" -Message "measured rate" -Details "" -Tag "tcp-retransmissions" | Out-Null
Add-CheckResult -Category "Test" -Check "Extra TCP 8.8.8.8" -Status "ERROR" -Message "not host:port" -Details "" -Tag "tcp" -Weightless | Out-Null
Assert-Equal 'K: the fixture built its 3 row(s)' (@($script:Results).Count) 3
Assert-Equal 'K: an input notice beside a measured warning leaves the quality key' (Get-FingerprintSummary).Key "quality"
Assert-Equal 'K: and the verdict is the warning''s, not the notice''s' (Get-OverallStatus).Code "WARN"

# A required check that did not run keeps its weight, so the run cannot read Overall Healthy with a measurement
# missing - the second half of the two-row cut.
$script:Results = New-Object System.Collections.ArrayList
Add-CheckResult -Category "Test" -Check "Gateway" -Status "PASS" -Message "ok" -Details "" -Tag "ping-gateway" | Out-Null
Add-CheckResult -Category "Test" -Check "Direct HTTPS Test" -Status "ERROR" -Message "invalid host or port" -Details "" -Tag "tcp" -Weightless | Out-Null
Add-CheckResult -Category "Test" -Check "Direct HTTPS Test" -Status "ERROR" -Message "did not run" -Details "" -Tag "tcp" | Out-Null
Assert-Equal 'K: the fixture built its 3 row(s)' (@($script:Results).Count) 3
Assert-Equal 'K: a required check that did not run still makes the run Test Incomplete' (Get-OverallStatus).Code "ERROR"
Assert-Equal 'K: the input notice beside it is named once in the summary' (([regex]::Matches(((@((Get-FingerprintSummary).Lines) -join " ")), 'Direct HTTPS Test')).Count) 1

# Scope beats nothing: an IT-scoped row is out of the verdict as it always was, marked or not.
$script:Results = New-Object System.Collections.ArrayList
Add-CheckResult -Category "Test" -Check "Gateway" -Status "PASS" -Message "ok" -Details "" -Tag "ping-gateway" | Out-Null
Add-CheckResult -Category "IT" -Check "Traceroute" -Status "FAIL" -Message "it row" -Details "" -Tag "traceroute" -Scope "IT" | Out-Null
Assert-Equal 'K: the fixture built its 2 row(s)' (@($script:Results).Count) 2
Assert-Equal 'K: an IT row never reached the verdict and still does not' (Get-OverallStatus).Code "PASS"

# The startup notice is weightless where it names a dropped target, and weighted where it names the environment -
# two families under one tag, and the run that says Overall Healthy while its report is written into a folder that
# disappears is the one this distinction prevents.
$script:Results = New-Object System.Collections.ArrayList
Add-CheckResult -Category "Test" -Check "Gateway" -Status "PASS" -Message "ok" -Details "" -Tag "ping-gateway" | Out-Null
Add-CheckResult -Category "Test" -Check "Startup Notice" -Status "WARN" -Message "compressed folder" -Details "" -Tag "startup" | Out-Null
Assert-Equal 'K: the fixture built its 2 row(s)' (@($script:Results).Count) 2
Assert-Equal 'K: an environment notice still turns the verdict' (Get-OverallStatus).Code "WARN"
$script:Results = New-Object System.Collections.ArrayList
Add-CheckResult -Category "Test" -Check "Gateway" -Status "PASS" -Message "ok" -Details "" -Tag "ping-gateway" | Out-Null
Add-CheckResult -Category "Test" -Check "Startup Notice" -Status "WARN" -Message "dropped target" -Details "" -Tag "startup" -Weightless | Out-Null
Assert-Equal 'K: the fixture built its 2 row(s)' (@($script:Results).Count) 2
Assert-Equal 'K: an input notice does not' (Get-OverallStatus).Code "PASS"
Assert-Equal 'K: and is not named in the summary, where its own section row names the target' ((@((Get-FingerprintSummary).Lines) -join " ") -match '(Startup Notice|啟動提示)') False

# The marking is opt-in, which is the property that keeps a check added later from becoming weightless by accident.
$script:Results = New-Object System.Collections.ArrayList
Add-CheckResult -Category "Test" -Check "Something new" -Status "FAIL" -Message "a check nobody marked" -Details "" -Tag "new-check" | Out-Null
Assert-Equal 'K: the fixture built its 1 row(s)' (@($script:Results).Count) 1
Assert-Equal 'K: an unmarked row is weighted by default' (Get-OverallStatus).Code "FAIL"
Assert-Equal 'K: and the field is on every row, marked or not' (@($script:Results)[0].PSObject.Properties.Name -contains "Weightless") True

# --- Scenario L: a required near-end target with no address is a required check that did not run (PR #51, round 3) ---
# Blank and optional is the shipped, disabled state; blank and required used to be dropped from the ladder without a
# row or a configuration finding, so a run could read Healthy without the check it was told to require. The ping list
# is emptied so that nothing here sends a probe; the near-end branch returns before the placement is consulted.
$script:Results = New-Object System.Collections.ArrayList
$script:PendingPingSamples = New-Object System.Collections.ArrayList
$script:Config = Get-DefaultConfig
$script:Config.Tests.PingTargets = @()
$script:Config.Tests.NearEndTarget.Required = $true
Test-PingTargets -PrimaryAdapters @()
Assert-Equal 'L: a required near-end target with no address writes two rows' (@($script:Results).Count) 2
Assert-Equal 'L: both under the near-end tag' (@(@($script:Results) | Where-Object { $_.Tag -eq "ping-near-end" }).Count) 2
Assert-Equal 'L: the first is the weightless notice' ((@($script:Results)[0].Status -eq "ERROR") -and [bool]@($script:Results)[0].Weightless) True
Assert-Equal 'L: the second is the weighted row saying the required check did not run' ((@($script:Results)[1].Status -eq "ERROR") -and -not [bool]@($script:Results)[1].Weightless) True
Assert-Equal 'L: so the run is Test Incomplete rather than Healthy' (Get-OverallStatus).Code "ERROR"
$script:Results = New-Object System.Collections.ArrayList
Test-ConfigurationSemantics
Assert-Equal 'L: and the configuration check names it in the Configured Targets row' (@(@($script:Results) | Where-Object { $_.Tag -eq "config" -and $_.Status -eq "ERROR" -and [bool]$_.Weightless }).Count) 1
$script:Results = New-Object System.Collections.ArrayList
$script:Config.Tests.NearEndTarget.Required = $false
Test-PingTargets -PrimaryAdapters @()
Assert-Equal 'L: blank and optional is the shipped, disabled state - no row' (@($script:Results).Count) 0
$script:Results = New-Object System.Collections.ArrayList
Test-ConfigurationSemantics
Assert-Equal 'L: and no configuration finding' (@(@($script:Results) | Where-Object { $_.Tag -eq "config" -and $_.Status -ne "PASS" }).Count) 0
Set-RunOptions -Overrides @{} | Out-Null

# --- Scenario M: backlog #52 - a TCP target that answers is connected to PingCount times, and the sample decides nothing ---
# Driven through Test-ConnectivityTargets with the socket and the timeout read mocked, so that nothing here needs a
# network: the mock answers with scripted times and the socket's own SYN count, fails from a chosen connection on,
# can leave the counters unreadable (PR #53, round 1), and counts what it was asked.
$originalTcp = ${function:Invoke-TcpConnectionTest}
$originalRto = ${function:Get-TcpInitialRto}
$script:MockCalls = New-Object System.Collections.ArrayList
$script:MockTimes = @(23, 7, 7, 7)
$script:MockFailAt = 0
$script:MockSynAt = 0
$script:MockNoTelemetry = $false
$script:MockRtoReads = 0
function Invoke-TcpConnectionTest {
    param([string]$HostName, [int]$Port, [int]$TimeoutMs)
    [void]$script:MockCalls.Add($HostName)
    $n = $script:MockCalls.Count
    if ($script:MockFailAt -gt 0 -and $n -ge $script:MockFailAt) {
        return [pscustomobject]@{ Success = $false; Host = $HostName; Port = $Port; ElapsedMs = [double]$TimeoutMs; Error = ('Cause: the tool''s own limit expired [ToolTimeout]' + "`r`n" + 'TCP connection timed out'); RemoteAddress = ''; LocalAddress = ''; SynRetrans = -1; RttUs = -1; TelemetryError = '' }
    }
    $syn = $(if ($script:MockNoTelemetry) { -1 } elseif ($n -eq $script:MockSynAt) { 1 } else { 0 })
    $rtt = $(if ($script:MockNoTelemetry) { -1 } else { 6301 })
    $why = $(if ($script:MockNoTelemetry) { 'The attempted operation is not supported for the type of object referenced' } else { '' })
    return [pscustomobject]@{ Success = $true; Host = $HostName; Port = $Port; ElapsedMs = [double]$script:MockTimes[[math]::Min($n, $script:MockTimes.Count) - 1]; Error = ''; RemoteAddress = '198.51.100.7'; LocalAddress = '192.0.2.10'; SynRetrans = $syn; RttUs = $rtt; TelemetryError = $why }
}
function Get-TcpInitialRto { $script:MockRtoReads++; return [pscustomobject]@{ Ms = 1000; Source = 'default' } }
function Reset-ScenarioM([int]$FailAt, [int]$PingCount, [object[]]$Targets) {
    $script:Results = New-Object System.Collections.ArrayList
    $script:TcpConnectSampleCount = 0
    $script:MockCalls.Clear(); $script:MockFailAt = $FailAt; $script:MockSynAt = 0; $script:MockNoTelemetry = $false; $script:MockRtoReads = 0
    $script:Config = Get-DefaultConfig
    $script:Config.Tests.PingCount = $PingCount
    $script:Config.Tests.HttpTargets = @()
    $script:Config.Tests.RequiredConnectivityGroups = @()
    $script:Config.Tests.TcpTargets = @($Targets)
}
function New-MTarget([string]$Name, [string]$HostName, [bool]$Required) { return [pscustomobject]@{ Name = $Name; Host = $HostName; Port = 443; Required = $Required; Group = '' } }
Reset-ScenarioM 0 4 @((New-MTarget 'Answering' '198.51.100.7' $false))
Test-ConnectivityTargets
$mRows = @($script:Results | Where-Object { $_.Tag -eq 'tcp' })
Assert-Equal 'M: a target that answers is connected to four times, all to one address' (($script:MockCalls.Count -eq 4) -and ((@($script:MockCalls | Sort-Object -Unique) -join ',') -eq '198.51.100.7')) True
Assert-Equal 'M: one row, passed, weighted, the sample and the sockets'' counts in its message, the counters and the timeout in its details' (($mRows.Count -eq 1) -and ($mRows[0].Status -eq 'PASS') -and (-not [bool]$mRows[0].Weightless) -and ($mRows[0].Message -match '23 / 7 / 7 / 7 ms') -and ($mRows[0].Message -match '0 / 0 / 0 / 0') -and ($mRows[0].Details -match 'SIO_TCP_INFO') -and ($mRows[0].Details -match 'RTO[^\r\n]*1000 ms')) True
Assert-Equal 'M: the sample count moved once and the timeout was read once' ("{0}/{1}" -f $script:TcpConnectSampleCount, $script:MockRtoReads) '1/1'
Reset-ScenarioM 0 4 @((New-MTarget 'Answering' '198.51.100.7' $true)); $script:MockSynAt = 3
Test-ConnectivityTargets
$mSyn = @($script:Results | Where-Object { $_.Tag -eq 'tcp' })[0]
Assert-Equal 'M: a SYN the third socket had to send again is in the message per connection and in total, and moves nothing' (("{0}/{1}/{2}" -f $mSyn.Status, (Get-OverallStatus).Code, ($mSyn.Message -match '0 / 0 / 1 / 0')) + '/' + ($mSyn.Message -match '(^|[^0-9.])1([^0-9.]|$)')) 'PASS/PASS/True/True'
Reset-ScenarioM 0 4 @((New-MTarget 'Answering' '198.51.100.7' $true)); $script:MockNoTelemetry = $true
Test-ConnectivityTargets
$mProxy = @($script:Results | Where-Object { $_.Tag -eq 'tcp' })[0]
Assert-Equal 'M: sockets whose counters cannot be read leave the row passed, the times read against the timeout as a proxy, and the reason in the details' (("{0}/{1}" -f $mProxy.Status, (Get-OverallStatus).Code) + '/' + ($mProxy.Message -match '1000 ms \(|1000 ms（') + '/' + ($mProxy.Message -match 'proxy|代理') + '/' + ($mProxy.Details -match 'not supported') + '/' + ($mProxy.Details -match 'RTO[^\r\n]*1000 ms')) 'PASS/PASS/True/True/True/True'
Reset-ScenarioM 0 4 @((New-MTarget 'Named' 'www.example.com' $false), (New-MTarget 'Second' '198.51.100.8' $false))
Test-ConnectivityTargets
Assert-Equal 'M: a name is asked once and its address three times; the timeout is read once for both targets' (((@($script:MockCalls)[0..3]) -join ',') + '/' + $script:MockRtoReads + '/' + $script:MockCalls.Count) 'www.example.com,198.51.100.7,198.51.100.7,198.51.100.7/1/8'
$mNamed = @($script:Results | Where-Object { $_.Tag -eq 'tcp' -and $_.Check -eq 'Named' })[0]
Assert-Equal 'M: the name row names the address it resolved to and counts all four of its sockets' (($mNamed.Details -match '198\.51\.100\.7') -and ($mNamed.Message -match '0 / 0 / 0 / 0')) True
Reset-ScenarioM 1 4 @((New-MTarget 'Down' '198.51.100.9' $true))
Test-ConnectivityTargets
$mDown = @($script:Results | Where-Object { $_.Tag -eq 'tcp' })[0]
Assert-Equal 'M: a target that does not answer costs one connection, no timeout read and no sample, and fails as before' ("{0}/{1}/{2}/{3}/{4}" -f $script:MockCalls.Count, $script:MockRtoReads, $script:TcpConnectSampleCount, $mDown.Status, ($mDown.Details -notmatch 'RTO')) '1/0/0/FAIL/True'
Reset-ScenarioM 3 4 @((New-MTarget 'Flaky' '198.51.100.7' $true))
Test-ConnectivityTargets
$mFlaky = @($script:Results | Where-Object { $_.Tag -eq 'tcp' })[0]
Assert-Equal 'M: a repeat that fails ends the repeats - three connections, not four' $script:MockCalls.Count 3
Assert-Equal 'M: the row still passes on its first connection, names the failure by position, and the run stays healthy' ("{0}/{1}/{2}" -f $mFlaky.Status, (Get-OverallStatus).Code, ($mFlaky.Message -match '(^|[^0-9.])3([^0-9.]|$)')) 'PASS/PASS/True'
Assert-Equal 'M: and its details carry the failed connection''s cause' ($mFlaky.Details -match 'ToolTimeout') True
Reset-ScenarioM 0 1 @((New-MTarget 'Once' '198.51.100.7' $false))
Test-ConnectivityTargets
Assert-Equal 'M: PingCount 1 is one connection, its socket counted, the timeout still in the details' ("{0}/{1}/{2}" -f $script:MockCalls.Count, (@($script:Results | Where-Object { $_.Tag -eq 'tcp' })[0].Message -match '(^|[^0-9.])0([^0-9.]|$)'), (@($script:Results | Where-Object { $_.Tag -eq 'tcp' })[0].Details -match 'RTO')) '1/True/True'
${function:Invoke-TcpConnectionTest} = $originalTcp
${function:Get-TcpInitialRto} = $originalRto
$script:TcpConnectSampleCount = 0
Set-RunOptions -Overrides @{} | Out-Null

# --- Scenario N: the access-point samples and their row (backlog #61, the other half; v1.2.13) ---
# The radio row's read is the middle sample, the analysis writes one IT-scope row per wireless interface netsh listed
# (or one saying there is none), and an IT row - Information or Unable to Check - changes neither the verdict nor the
# fingerprint. Real reads, whatever this machine has: a runner without a radio gets the one row that says so.
$script:Results = New-Object System.Collections.ArrayList
$script:WifiAssociationSamples = New-Object System.Collections.ArrayList
Add-CheckResult -Category "Test" -Check "Gateway" -Status "PASS" -Message "ok" -Details "" -Tag "ping-gateway" | Out-Null
[void](Add-WifiAssociationSample -Moment "start")
Add-WifiRfResult
[void](Add-WifiAssociationSample -Moment "end")
Assert-Equal 'N: three samples taken, the middle one by the radio row' (@($script:WifiAssociationSamples | ForEach-Object { $_.Moment }) -join ',') 'start,middle,end'
$rowsBefore = @($script:Results).Count
Compare-WifiAssociation -Samples @($script:WifiAssociationSamples)
$assocRows = @($script:Results | Where-Object { $_.Tag -eq 'wifi-association' })
Assert-Equal 'N: at least one association row, every one in the IT scope and unmarked' (($assocRows.Count -ge 1) -and (@($assocRows | Where-Object { $_.Scope -ne 'IT' -or $_.Weightless }).Count -eq 0)) True
Assert-Equal 'N: and the analysis wrote nothing else' (@($script:Results).Count - $rowsBefore) $assocRows.Count
Assert-Equal 'N: the rows leave a healthy run healthy' ("{0}/{1}" -f (Get-OverallStatus).Code, (Get-FingerprintSummary).Key) 'PASS/healthy'
Write-Output ('[INFO] N: ' + $assocRows.Count + ' association row(s) on this machine; the first reads: ' + $assocRows[0].Message)
$script:LastHtmlReport = $null; $script:LastTextReport = $null; $script:LastJsonReport = $null
$r = Complete-ReportStage -SaveResult (Save-Reports)
$json = Get-Content -LiteralPath $r.Json -Raw | ConvertFrom-Json
Assert-Equal 'N: the JSON report carries the rows with their tag and scope' (@($json.Results | Where-Object { $_.Tag -eq 'wifi-association' -and $_.Scope -eq 'IT' }).Count) $assocRows.Count
$html = Get-Content -LiteralPath $r.Html -Raw
Assert-Equal 'N: and the HTML puts them in the IT block' ((($html -split 'class="itblock"')[1]) -match 'wifi-association|Wi-Fi') True
Start-Sleep -Seconds 1
# Every sample failing is one Unable-to-Check row, IT-scoped like the rest, and outside the verdict like every IT row.
$script:Results = New-Object System.Collections.ArrayList
Add-CheckResult -Category "Test" -Check "Gateway" -Status "PASS" -Message "ok" -Details "" -Tag "ping-gateway" | Out-Null
Compare-WifiAssociation -Samples @([pscustomobject]@{ Moment = 'start'; Timestamp = (Get-Date); Interfaces = @(); Error = 'netsh'; ErrorText = 'not found'; Diagnostics = '' })
Assert-Equal 'N: a sampling that failed every time is one Unable-to-Check IT row' ("{0}/{1}/{2}" -f @($script:Results).Count, $script:Results[1].Status, $script:Results[1].Scope) '2/ERROR/IT'
Assert-Equal 'N: which changes neither the verdict nor the fingerprint' ("{0}/{1}" -f (Get-OverallStatus).Code, (Get-FingerprintSummary).Key) 'PASS/healthy'
# The switch: the radio row off in the file takes the samples with it - the run gates all three steps on WifiRf.
$script:BaseConfig.Checks.WifiRf = $false
$oNoWifi = Set-RunOptions -Overrides @{}
Assert-Equal 'N: WifiRf off in the file is projected off, and the profile names it' (("{0}/{1}" -f $oNoWifi.ChecksEnabled.WifiRf, ((Get-RunProfileText) -match 'WifiRf'))) 'False/True'
$script:WifiAssociationSamples = New-Object System.Collections.ArrayList
Add-WifiRfResult
Assert-Equal 'N: and the radio row takes no sample when it is off' (@($script:WifiAssociationSamples).Count) 0
$script:BaseConfig.Checks.WifiRf = $true
Set-RunOptions -Overrides @{} | Out-Null

# --- Scenario O: the radio row where netsh printed nothing and the WLAN service says connected (backlog #62; v1.2.13) ---
# The keeper is stubbed to hand the row a fixed sample; the row itself is the shipped function, and every row it writes
# is an IT-scoped Information row that moves neither the verdict nor the fingerprint. The shapes: the measured refusal
# (netsh exit 1, no block, the service refusing the connection query with error 5); netsh failing while the service
# answers; nothing connected; and netsh missing with the service unreadable.
$originalKeeper = ${function:Add-WifiAssociationSample}
$refusedO = @('There is 1 interface on the system: ', 'Network shell commands need location permission to access WLAN information.', 'start ms-settings:privacy-location', 'Function WlanQueryInterface returns error 5:', 'The requested operation requires elevation (Run as administrator).')
function New-ReadingO($state, $query, $error = '', $denied = $true) { return [pscustomobject]@{ Timestamp = (Get-Date); Interfaces = @($(if ($error) { @() } else { [pscustomobject]@{ Guid = 'e6b08c8a-3feb-4c3e-88c3-dee94dd2f0eb'; Description = 'Fixture AX211'; State = $state; Channel = 149; RadioSoftware = 'on'; RadioHardware = 'on'; ConnectionQuery = $query } })); Error = $error; ErrorText = ''; Diagnostics = ''; LocationConsent = [pscustomobject]@{ Known = $true; Denied = $denied; Build = 26200; Gated = $true; Levels = @(); Text = $(if ($denied) { 'user Deny, device Allow, desktop apps Allow, netsh (no entry)' } else { 'user Allow, device Allow, desktop apps Allow, netsh (no entry)' }) } } }
function New-SampleO($lines, $exit, $api) { return [pscustomobject]@{ Moment = 'middle'; Timestamp = (Get-Date); Interfaces = @(ConvertFrom-NetshWlanOutput -Lines $lines); Error = ''; ErrorText = ''; Diagnostics = ''; NetshExitCode = $exit; NetshLines = @($lines); Api = $api } }
$script:SampleO = New-SampleO $refusedO 1 (New-ReadingO 1 5)
function Add-WifiAssociationSample { param([string]$Moment) return $script:SampleO }
$script:Results = New-Object System.Collections.ArrayList
Add-CheckResult -Category "Test" -Check "Gateway" -Status "PASS" -Message "ok" -Details "" -Tag "ping-gateway" | Out-Null
Add-WifiRfResult
$rowsO = @($script:Results | Where-Object { $_.Tag -eq 'wifi' })
Assert-Equal 'O: one IT Information row for the interface the service lists as connected' ("{0}/{1}/{2}" -f $rowsO.Count, $rowsO[0].Status, $rowsO[0].Scope) '1/INFO/IT'
Assert-Equal 'O: it names error 5 and the interface GUID, and carries what netsh printed' ("{0}/{1}/{2}" -f ($rowsO[0].Message -match '\b5\b'), ($rowsO[0].Details -match 'e6b08c8a-3feb-4c3e-88c3-dee94dd2f0eb'), ($rowsO[0].Details -match 'ms-settings:privacy-location')) 'True/True/True'
Assert-Equal 'O: and the verdict and the fingerprint do not move' ("{0}/{1}" -f (Get-OverallStatus).Code, (Get-FingerprintSummary).Key) 'PASS/healthy'
Assert-Equal 'O r1: with the consent store at Deny the row names the setting (24H2) and carries the consent text' (("{0}/{1}" -f ($rowsO[0].Message -match '24H2'), ($rowsO[0].Details -match 'Deny'))) 'True/True'
# Error 5 without the consent store's Deny (PR #55, round 1): access denied, the cause not named, no setting to open.
$script:SampleO = New-SampleO $refusedO 1 (New-ReadingO 1 5 '' $false)
$script:Results = New-Object System.Collections.ArrayList
Add-WifiRfResult
$rowsO5 = @($script:Results | Where-Object { $_.Tag -eq 'wifi' })
Assert-Equal 'O r1: error 5 with the consent store at Allow is one row that names error 5 but not the location setting' ("{0}/{1}/{2}/{3}" -f $rowsO5.Count, $rowsO5[0].Status, ($rowsO5[0].Message -match '\b5\b'), ($rowsO5[0].Message -match '24H2')) '1/INFO/True/False'
# The manual check follows the witness (round 2): the settings URI appears once more than the netsh lines carry it only on the
# witnessed row; the unwitnessed error 5 and the plain failure carry it exactly as often as the netsh lines do.
function Count-Uri($row) { return ([regex]::Matches([string]$row.Details, 'ms-settings:privacy-location')).Count }
$uriInFixture = @($refusedO | Where-Object { $_ -match 'ms-settings:privacy-location' }).Count
Assert-Equal 'O r2: the location remedy is on the witnessed row alone - the unwitnessed error 5 carries only what netsh printed' ("{0}/{1}" -f ((Count-Uri $rowsO[0]) -eq ($uriInFixture + 1)), ((Count-Uri $rowsO5[0]) -eq $uriInFixture)) 'True/True'
$script:SampleO = New-SampleO $refusedO 1 (New-ReadingO 1 0)
$script:Results = New-Object System.Collections.ArrayList
Add-WifiRfResult
$rowsO2 = @($script:Results | Where-Object { $_.Tag -eq 'wifi' })
Assert-Equal 'O: netsh failing while the service answers the query is one row that names no error 5' ("{0}/{1}/{2}" -f $rowsO2.Count, $rowsO2[0].Status, ($rowsO2[0].Message -match '\b5\b')) '1/INFO/False'
Assert-Equal 'O r2: and the plain failure carries the settings URI only as often as netsh printed it' ((Count-Uri $rowsO2[0]) -eq $uriInFixture) True
$offO = @('There is 1 interface on the system: ', '', '    Name                   : Wi-Fi', '    Description            : Fixture', '    GUID                   : e6b08c8a-3feb-4c3e-88c3-dee94dd2f0eb', '    Physical address       : 10:f6:0a:db:fc:e5', '    State                  : disconnected', '')
$script:SampleO = New-SampleO $offO 0 (New-ReadingO 4 -1)
$script:Results = New-Object System.Collections.ArrayList
Add-WifiRfResult
$rowsO3 = @($script:Results | Where-Object { $_.Tag -eq 'wifi' })
Assert-Equal 'O: no connected interface is one Information row whose details name the interface' ("{0}/{1}/{2}" -f $rowsO3.Count, $rowsO3[0].Status, ($rowsO3[0].Details -match 'Wi-Fi')) '1/INFO/True'
$script:SampleO = [pscustomobject]@{ Moment = 'middle'; Timestamp = (Get-Date); Interfaces = @(); Error = 'netsh'; ErrorText = 'not found'; Diagnostics = ''; NetshExitCode = -1; NetshLines = @(); Api = (New-ReadingO 1 0 'addtype') }
$script:Results = New-Object System.Collections.ArrayList
Add-WifiRfResult
$rowsO4 = @($script:Results | Where-Object { $_.Tag -eq 'wifi' })
Assert-Equal 'O: netsh missing and the service unreadable is the one Information row it always was, naming the service reason' ("{0}/{1}/{2}" -f $rowsO4.Count, $rowsO4[0].Status, ($rowsO4[0].Details -match 'addtype')) '1/INFO/True'
Assert-Equal 'O r5: the radio rows written without an interface end their WLAN-service line with the read''s own token - the reason where it failed, ok where it answered' ("{0}/{1}" -f ($rowsO4[0].Details -match '(?m)wlanapi=addtype\s*$'), ($rowsO3[0].Details -match '(?m)wlanapi=ok\s*$')) 'True/True'
Set-Item -Path function:Add-WifiAssociationSample -Value $originalKeeper
$script:Results = New-Object System.Collections.ArrayList
Add-CheckResult -Category "Test" -Check "Gateway" -Status "PASS" -Message "ok" -Details "" -Tag "ping-gateway" | Out-Null

Write-Output ("Summary: {0} passed, {1} failed" -f $passes, $fails)
exit $fails
