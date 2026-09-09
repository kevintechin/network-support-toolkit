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
Reset-Results; Add-Tagged "adapters" "PASS"; Add-Tagged "ping-gateway" "PASS"; Add-Tagged "dns" "FAIL"; Add-Tagged "connectivity-group" "FAIL"
Assert-Equal 'D: gateway ok, internet dead -> gateway-up-internet-dead' (Get-FingerprintSummary).Key "gateway-up-internet-dead"
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
    foreach ($item in @(@{ Key = "PingCount"; Min = 1; Max = 20 }, @{ Key = "SampleSeconds"; Min = 1; Max = 120 }, @{ Key = "TracerouteHops"; Min = 1; Max = 10 })) {
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
Assert-Equal 'I: profile text carries the configured values' ((Get-RunProfileText) -match '(ping count|Ping 次數) 30 \| (sample 300 s|取樣 300 秒)') True
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
Assert-Equal 'I: default config keeps the 1-20 ping range' $script:OptionsPanel["PingCount"].Maximum 20
Assert-Equal 'I: default config keeps the 1-120 s sample range' $script:OptionsPanel["SampleSeconds"].Maximum 120
Assert-Equal 'I: default values shown (4 / 8)' ("$($script:OptionsPanel['PingCount'].Value)/$($script:OptionsPanel['SampleSeconds'].Value)") "4/8"
Set-RunOptions -Overrides @{ EntryPoint = "IT"; PingCount = 25 } | Out-Null; Set-OptionsPanelValues
Assert-Equal 'I: a CLI -PingCount 25 above the default range is shown, not clamped' $script:OptionsPanel["PingCount"].Value 25
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

Write-Output ("Summary: {0} passed, {1} failed" -f $passes, $fails)
exit $fails
