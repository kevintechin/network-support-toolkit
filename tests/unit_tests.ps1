param([string]$ScriptPath)

$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$errors)
$wanted = 'ConvertTo-SafeString', 'ConvertTo-IntSafe', 'Test-IsWholeNumber', 'ConvertFrom-NetshWlanOutput', 'Test-IsVirtualAdapter', 'ConvertTo-DisplayString', 'Get-PropertyValue', 'ConvertTo-DoubleSafe', 'Test-IsNumericValue', 'Get-ExceptionDetails', 'Get-ExceptionDiagnostics', 'Test-IsValidIPv4Address', 'Get-NetworkErrorCauseText', 'Add-NetworkErrorCause', 'Test-IsRunningFromArchive', 'ConvertTo-UInt64Safe', 'Get-CimOrWmiInstance', 'Get-TcpCounterSnapshot', 'Get-TcpReadFailureLines', 'Format-TcpAttemptList', 'Get-TcpAttemptSeconds', 'Compare-TcpCounters', 'Test-PingTargetSyntax', 'Test-HttpTargetSyntax', 'Test-HostNameSyntax', 'Test-TcpTargetSyntax', 'Get-RouteSelection', 'Get-RouteSelectionText', 'Format-RouteSelection', 'Get-RouteMethodText', 'Get-PingCountForThreshold', 'Get-LossBand', 'Get-CountThreshold', 'Get-PingLossClassification', 'Get-PingExtensionPlan', 'Get-PingSampleInterval', 'Add-PingTargetResult', 'Test-TcpSampleNeedsExtension', 'Merge-TcpEndingSnapshot', 'Test-NearEndTargetPlacement', 'Resolve-PingTargets', 'Test-IPv4InCidr', 'Get-DhcpServerText', 'Get-CanonicalIPv4Text', 'Test-NearEndAddressSyntax', 'Compare-WifiRetryCounters', 'Get-WifiRetrySnapshot', 'Get-WifiInterfaceStateText', 'Get-Win32ErrorText', 'Get-TcpInitialRto', 'New-TcpConnectSample', 'Get-TcpConnectSampleText', 'Invoke-TcpConnectionTest', 'Get-LatencySpreadText', 'Get-WifiAssociationSample', 'Add-WifiAssociationSample', 'Compare-WifiAssociation', 'Get-MacRelation', 'Get-AccessPointGatewayText', 'Get-AccessPointGatewayEvidence', 'Update-AccessPointGatewayHints', 'Get-WlanApiType', 'Get-WlanInterfaceStates', 'Get-WifiInterfaceView', 'Get-WifiNetshReasonText', 'Get-WifiRadioSwitchText', 'Get-WifiApiSummaryText', 'Get-LocationConsentState', 'Test-WifiSampleReadable', 'Get-RadioSwitchState', 'Get-TcpIntervalSeconds', 'Start-TcpIntervalSampling', 'Stop-TcpIntervalSampling', 'Read-TcpIntervalCounters', 'Invoke-TcpIntervalReadIfDue', 'Get-TcpIntervalTable', 'Get-TcpDistributionLines', 'Get-TcpIntervalStopLine', 'Wait-ForMinimumTcpSample', 'Wait-ForConsoleClose', 'Get-HostNameSyntaxProblem', 'Get-UrlHostProblemSuffix', 'Get-UrlConfiguredHost'
$funcs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $wanted -contains $n.Name }, $true)
foreach ($f in $funcs) { Invoke-Expression $f.Extent.Text }
Write-Output ("Loaded {0} functions from {1}" -f @($funcs).Count, (Split-Path -Leaf (Split-Path -Parent $ScriptPath)))

# Two guards over this file itself. A case that calls a function nobody loaded is a statement-terminating error:
# PowerShell prints it, carries on with the next line, and the summary counts only the assertions that ran - so
# six new cases of PR #41 round 10 reported nothing at all and the step still passed. Counting the Assert-Equal
# calls in this file would not catch that, because several of them run inside loops.
# The first guard is for a name the script no longer defines - the list below asks for something that is gone.
# The trap is for the other direction, and it is the one that catches the round-10 bug: a call to anything not
# loaded, whether the name was left out of the list or misspelled in the case. Both were checked against a
# mutant of this file before being trusted.
$missing = @($wanted | Where-Object { $loaded = @($funcs | ForEach-Object { $_.Name }); $loaded -notcontains $_ })
if ($missing.Count -gt 0) {
    Write-Output ("[FAIL] harness: the script does not define {0}" -f ($missing -join ", "))
    Write-Output ("Summary: 0 passed, {0} failed" -f $missing.Count)
    exit $missing.Count
}
trap [System.Management.Automation.CommandNotFoundException] {
    Write-Output ("[FAIL] harness: an assertion called something that is not loaded - {0}" -f $_.Exception.Message)
    Write-Output "Summary: 0 passed, 1 failed"
    exit 1
}

$fails = 0; $passes = 0
# The other direction of the hole the two guards above cover. A statement-terminating error anywhere below stops
# this file where it stands: it ends with no Summary line at all and exits 0, so a person running it by hand sees
# a stack of PASS lines and nothing saying it stopped. The chain's step rejects a run with no summary, but the
# person is the one who needs telling. A mutant written for PR #49 round 1 - Compare-TcpCounters casting a
# negative threshold to [uint64] - ended exactly that way, which is how this guard came to be written.
trap {
    Write-Output ("[FAIL] harness: the run stopped on an error - {0}" -f $_.Exception.Message)
    Write-Output ("Summary: {0} passed, {1} failed" -f $script:passes, ($script:fails + 1))
    exit ($script:fails + 1)
}
function Assert-Equal($name, $actual, $expected) {
    if ("$actual" -eq "$expected") { $script:passes++; Write-Output "[PASS] $name -> $actual" }
    else { $script:fails++; Write-Output "[FAIL] $name -> got '$actual', expected '$expected'" }
}

# backlog #4: culture-invariant, non-throwing double parsing that keeps decimals
Assert-Equal 'double: int 5' (ConvertTo-DoubleSafe 5 1) 5
Assert-Equal 'double: decimal 2.5' (ConvertTo-DoubleSafe 2.5 1) 2.5
Assert-Equal 'double: string "2.5"' (ConvertTo-DoubleSafe "2.5" 1) 2.5
Assert-Equal 'double: string "1e2"' (ConvertTo-DoubleSafe "1e2" 1) 100
Assert-Equal 'double: string "abc" -> default' (ConvertTo-DoubleSafe "abc" 7) 7
Assert-Equal 'double: string "5%" -> default' (ConvertTo-DoubleSafe "5%" 7) 7
Assert-Equal 'double: null -> default' (ConvertTo-DoubleSafe $null 3) 3
Assert-Equal 'double: bool -> default' (ConvertTo-DoubleSafe $true 4) 4
Assert-Equal 'double: "2,5" -> default (invariant culture)' (ConvertTo-DoubleSafe "2,5" 9) 9
Assert-Equal 'double: 100.5 keeps decimals' (ConvertTo-DoubleSafe 100.5 0) 100.5
Assert-Equal 'int: 2.5 -> default (round 3: no silent rounding)' (ConvertTo-IntSafe 2.5 0) 0
Assert-Equal 'numeric: 5' (Test-IsNumericValue 5) True
Assert-Equal 'numeric: "2.5"' (Test-IsNumericValue "2.5") True
Assert-Equal 'numeric: "abc"' (Test-IsNumericValue "abc") False
Assert-Equal 'numeric: null' (Test-IsNumericValue $null) False
Assert-Equal 'numeric: bool' (Test-IsNumericValue $false) False
Assert-Equal 'numeric: decimal 1.25' (Test-IsNumericValue ([decimal]1.25)) True

# backlog #11: summary vs diagnostics split
try { throw "boom" } catch { $er = $_ }
$summary = Get-ExceptionDetails $er
$diag = Get-ExceptionDiagnostics $er
$full = Get-ExceptionDetails $er -IncludeDiagnostics
Assert-Equal 'summary has message' ($summary -match 'boom') True
Assert-Equal 'summary has no call stack' ($summary -notmatch 'Call stack|呼叫堆疊') True
Assert-Equal 'summary has no location' ($summary -notmatch 'Location:|位置：') True
Assert-Equal 'diagnostics has call stack' ($diag -match 'Call stack|呼叫堆疊') True
Assert-Equal 'diagnostics has location' ($diag -match 'Location:|位置：') True
Assert-Equal 'full includes diagnostics' ($full -match 'Call stack|呼叫堆疊') True
Assert-Equal 'diagnostics of null is empty' ((Get-ExceptionDiagnostics $null) -eq "") True

# backlog #5: IPv4-only gateway filter
$gw = @("192.168.1.1", "fe80::1", "", $null, "2001:db8::1", "10.0.0.254") | Where-Object { Test-IsValidIPv4Address ([string]$_) }
Assert-Equal 'gateway filter keeps IPv4 only' (@($gw) -join ',') '192.168.1.1,10.0.0.254'
$dhcpNull = $null; if ($null -ne $null) { $dhcpNull = [bool]$null }
Assert-Equal 'null DHCPEnabled stays null (unknown)' ($null -eq $dhcpNull) True

# review round 1 (Codex): Booleans never become integers; NaN / infinities are not thresholds
Assert-Equal 'int: bool -> default' (ConvertTo-IntSafe $true 10) 10
Assert-Equal 'int: "abc" -> default' (ConvertTo-IntSafe "abc" 10) 10
Assert-Equal 'int: "7" -> 7' (ConvertTo-IntSafe "7" 10) 7
Assert-Equal 'double: "NaN" -> default' (ConvertTo-DoubleSafe "NaN" 5) 5
Assert-Equal 'double: "Infinity" -> default' (ConvertTo-DoubleSafe "Infinity" 5) 5
Assert-Equal 'double: "-Infinity" -> default' (ConvertTo-DoubleSafe "-Infinity" 5) 5
Assert-Equal 'double: [double]::NaN -> default' (ConvertTo-DoubleSafe ([double]::NaN) 5) 5
Assert-Equal 'numeric: "NaN"' (Test-IsNumericValue "NaN") False
Assert-Equal 'numeric: "Infinity"' (Test-IsNumericValue "Infinity") False
Assert-Equal 'numeric: [double]::PositiveInfinity' (Test-IsNumericValue ([double]::PositiveInfinity)) False

# review round 3 (Codex): count thresholds and integer settings must be whole numbers
Assert-Equal 'int: 2.4 -> default' (ConvertTo-IntSafe 2.4 10) 10
Assert-Equal 'int: "2.4" -> default' (ConvertTo-IntSafe "2.4" 10) 10
Assert-Equal 'int: 24.0 -> 24' (ConvertTo-IntSafe 24.0 10) 24
Assert-Equal 'int: "24" -> 24' (ConvertTo-IntSafe "24" 10) 24
Assert-Equal 'int: [uint32]7 -> 7' (ConvertTo-IntSafe ([uint32]7) 10) 7
Assert-Equal 'int: 1e3 -> 1000' (ConvertTo-IntSafe 1e3 10) 1000
Assert-Equal 'int: -1 -> -1' (ConvertTo-IntSafe -1 10) -1
Assert-Equal 'int: 3000000000 (> Int32) -> default' (ConvertTo-IntSafe 3000000000 10) 10
Assert-Equal 'int: null -> default' (ConvertTo-IntSafe $null 10) 10
Assert-Equal 'whole: 2' (Test-IsWholeNumber 2) True
Assert-Equal 'whole: 2.0' (Test-IsWholeNumber 2.0) True
Assert-Equal 'whole: 2.4' (Test-IsWholeNumber 2.4) False
Assert-Equal 'whole: "3"' (Test-IsWholeNumber "3") True
Assert-Equal 'whole: "abc"' (Test-IsWholeNumber "abc") False
Assert-Equal 'whole: null' (Test-IsWholeNumber $null) False
Assert-Equal 'whole: bool' (Test-IsWholeNumber $true) False

# review round 4 (Codex): whole-number check includes the Int32 range, matching ConvertTo-IntSafe
Assert-Equal 'whole: 3000000000 (> Int32)' (Test-IsWholeNumber 3000000000) False
Assert-Equal 'whole: -2147483649 (< Int32)' (Test-IsWholeNumber -2147483649) False
Assert-Equal 'whole: 2147483647 (Int32 max)' (Test-IsWholeNumber 2147483647) True
Assert-Equal 'int: 2147483647 -> 2147483647' (ConvertTo-IntSafe 2147483647 10) 2147483647
Assert-Equal 'whole: "3000000000"' (Test-IsWholeNumber "3000000000") False

# v1.2: netsh wlan parser — Windows 11 layout (Band/Channel before Radio type, Rssi line present)
$win11 = @(
"There is 1 interface on the system: ", "",
"    Name                   : Wi-Fi",
"    Description            : Intel(R) Wi-Fi 6E AX211 160MHz",
"    GUID                   : e6b08c8a-3feb-4c3e-88c3-dee94dd2f0eb",
"    Physical address       : 10:f6:0a:db:fc:e5",
"    Interface type         : Primary",
"    State                  : connected",
"    SSID                   : kevin_5g",
"    AP BSSID               : ac:b6:87:a6:81:a0",
"    Band                   : 5 GHz",
"    Channel                : 149",
"    Connected Akm-cipher   : [ akm = 00-0f-ac:02, cipher =  00-0f-ac:04 ]",
"    Network type           : Infrastructure",
"    Radio type             : 802.11ac",
"    Authentication         : WPA2-Personal",
"    Cipher                 : CCMP",
"    Connection mode        : Auto Connect",
"    Receive rate (Mbps)    : 390",
"    Transmit rate (Mbps)   : 390",
"    Signal                 : 78% ",
"    Rssi                   : -65",
"    Profile                : kevin_5g ",
"    QoS MSCS Configured         : 0",
"    QoS Map Configured          : 0")
$w = @(ConvertFrom-NetshWlanOutput -Lines $win11)
Assert-Equal 'wifi11: one interface' $w.Count 1
Assert-Equal 'wifi11: connected' $w[0].Connected True
Assert-Equal 'wifi11: ssid' $w[0].Ssid "kevin_5g"
Assert-Equal 'wifi11: bssid' $w[0].Bssid "ac:b6:87:a6:81:a0"
Assert-Equal 'wifi11: band' $w[0].Band "5 GHz"
Assert-Equal 'wifi11: channel' $w[0].Channel 149
Assert-Equal 'wifi11: radio' $w[0].RadioType "802.11ac"
Assert-Equal 'wifi11: receive' $w[0].ReceiveRateMbps 390
Assert-Equal 'wifi11: transmit' $w[0].TransmitRateMbps 390
Assert-Equal 'wifi11: signal %' $w[0].SignalPercent 78
Assert-Equal 'wifi11: rssi' $w[0].Rssi -65
Assert-Equal 'wifi11: profile' $w[0].Profile "kevin_5g"

# v1.2: Windows 10 layout with localized labels, no Band/Rssi lines, 2.4 GHz channel, decimal rates
$win10zh = @(
"系統上有 1 個介面: ", "",
"    名稱                   : Wi-Fi 2",
"    描述                   : Realtek 8822CE Wireless LAN 802.11ac PCI-E NIC",
"    GUID                   : 0f7a2d2e-1c1b-4c6a-9a0f-2b1f0e5e0a11",
"    實體位址               : 34:2e:b7:aa:bb:cc",
"    狀態                   : 已連線",
"    SSID                   : Office-2G",
"    BSSID                  : 5c:e2:8c:11:22:33",
"    網路類型               : 基礎結構",
"    無線電類型             : 802.11n",
"    驗證                   : WPA2-Enterprise",
"    加密                   : CCMP",
"    連線模式               : 自動連線",
"    通道                   : 6",
"    接收速率 (Mbps)        : 144.4",
"    傳輸速率 (Mbps)        : 144.4",
"    訊號                   : 55%",
"    設定檔                 : Office-2G",
"", "    裝載的網路狀態         : 無法使用")
$w = @(ConvertFrom-NetshWlanOutput -Lines $win10zh)
Assert-Equal 'wifi10zh: connected' $w[0].Connected True
Assert-Equal 'wifi10zh: ssid' $w[0].Ssid "Office-2G"
Assert-Equal 'wifi10zh: channel' $w[0].Channel 6
Assert-Equal 'wifi10zh: band inferred' $w[0].Band "2.4 GHz"
Assert-Equal 'wifi10zh: radio' $w[0].RadioType "802.11n"
Assert-Equal 'wifi10zh: receive' $w[0].ReceiveRateMbps 144.4
Assert-Equal 'wifi10zh: signal' $w[0].SignalPercent 55
Assert-Equal 'wifi10zh: rssi absent' ($null -eq $w[0].Rssi) True
Assert-Equal 'wifi10zh: profile' $w[0].Profile "Office-2G"

# v1.2: disconnected interface (no SSID/BSSID lines)
$off = @(
"There is 1 interface on the system: ", "",
"    Name                   : Wi-Fi",
"    Description            : Intel(R) Wi-Fi 6E AX211 160MHz",
"    GUID                   : e6b08c8a-3feb-4c3e-88c3-dee94dd2f0eb",
"    Physical address       : 10:f6:0a:db:fc:e5",
"    Interface type         : Primary",
"    State                  : disconnected",
"    Radio status           : Hardware On",
"                             Software On", "",
"    Hosted network status  : Not available")
$w = @(ConvertFrom-NetshWlanOutput -Lines $off)
Assert-Equal 'wifioff: one interface' $w.Count 1
Assert-Equal 'wifioff: not connected' $w[0].Connected False
Assert-Equal 'wifioff: physical address kept' $w[0].PhysicalAddress "10:f6:0a:db:fc:e5"
Assert-Equal 'wifi: empty input -> no interfaces' (@(ConvertFrom-NetshWlanOutput -Lines @()).Count) 0

# v1.2: adapter classification
Assert-Equal 'virt: Virtual flag wins' (Test-IsVirtualAdapter -Description "Intel(R) Ethernet" -VirtualFlag $true -HardwareFlag $true) True
Assert-Equal 'virt: hardware flag false -> virtual' (Test-IsVirtualAdapter -Description "Something" -VirtualFlag $false -HardwareFlag $false) True
Assert-Equal 'virt: hardware flag true -> physical even with VPN in name' (Test-IsVirtualAdapter -Description "Corp VPN NIC" -VirtualFlag $false -HardwareFlag $true) False
Assert-Equal 'virt: no flags, VirtualBox by description' (Test-IsVirtualAdapter -Description "VirtualBox Host-Only Ethernet Adapter" -VirtualFlag $null -HardwareFlag $null) True
Assert-Equal 'virt: no flags, Hyper-V vEthernet' (Test-IsVirtualAdapter -Description "Hyper-V Virtual Ethernet Adapter" -VirtualFlag $null -HardwareFlag $null) True
Assert-Equal 'virt: no flags, real NIC' (Test-IsVirtualAdapter -Description "Intel(R) Wi-Fi 6E AX211 160MHz" -VirtualFlag $null -HardwareFlag $null) False
Assert-Equal 'virt: CIM PhysicalAdapter=true -> physical' (Test-IsVirtualAdapter -Description "Hyper-V Network Adapter" -VirtualFlag $null -HardwareFlag $true) False


# backlog #14: network error text is classified by its error code, never by the operating system's wording. The
# expected sentences differ per language, so the assertions below check language-independent properties: the code
# name is always there, a mapped code adds a sentence in front of it, an unmapped code adds none, the original text
# is never dropped, and both language files carry the same table keys.
$socketCodes = 'HostNotFound', 'TryAgain', 'NoData', 'TimedOut', 'ConnectionRefused', 'NetworkUnreachable', 'HostUnreachable', 'ConnectionReset', 'ConnectionAborted', 'NetworkDown', 'AddressNotAvailable', 'AccessDenied'
$webStatuses = 'Timeout', 'NameResolutionFailure', 'ProxyNameResolutionFailure', 'ConnectFailure', 'TrustFailure', 'SecureChannelFailure', 'ReceiveFailure', 'SendFailure', 'ConnectionClosed', 'ServerProtocolViolation', 'RequestProhibitedByProxy'
foreach ($code in $socketCodes) {
    # A constructed SocketException carries .NET's own text, not the operating system's; the code is what is read.
    $marker = "[SocketError $code]"
    $text = Get-NetworkErrorCauseText (New-Object System.Net.Sockets.SocketException ([int][System.Net.Sockets.SocketError]::$code))
    Assert-Equal ("cause: SocketError $code names the code") ($text.EndsWith($marker)) True
    Assert-Equal ("cause: SocketError $code has a sentence") ($text.Length -gt ($marker.Length + 8)) True
}
foreach ($status in $webStatuses) {
    $marker = "[WebExceptionStatus $status]"
    $text = Get-NetworkErrorCauseText (New-Object System.Net.WebException 'x', $null, ([System.Net.WebExceptionStatus]::$status), $null)
    Assert-Equal ("cause: WebExceptionStatus $status names the status") ($text.EndsWith($marker)) True
    Assert-Equal ("cause: WebExceptionStatus $status has a sentence") ($text.Length -gt ($marker.Length + 8)) True
}
$refused = New-Object System.Net.Sockets.SocketException ([int][System.Net.Sockets.SocketError]::ConnectionRefused)
Assert-Equal 'cause: unmapped code is the code alone' (Get-NetworkErrorCauseText (New-Object System.Net.Sockets.SocketException ([int][System.Net.Sockets.SocketError]::NetworkReset))) '[SocketError NetworkReset]'
Assert-Equal 'cause: unmapped web status is the status alone' (Get-NetworkErrorCauseText (New-Object System.Net.WebException 'x', $null, ([System.Net.WebExceptionStatus]::KeepAliveFailure), $null)) '[WebExceptionStatus KeepAliveFailure]'
# The socket error is two or three levels down in every real failure: a task, a ping and a method call all wrap it.
$nested = New-Object System.AggregateException 'wrapper', (New-Object System.Net.NetworkInformation.PingException 'ping', $refused)
Assert-Equal 'cause: found through AggregateException and PingException' ((Get-NetworkErrorCauseText $nested).EndsWith('[SocketError ConnectionRefused]')) True
Assert-Equal 'cause: non-network exception has none' (Get-NetworkErrorCauseText (New-Object System.InvalidOperationException 'nope')) ''
Assert-Equal 'cause: null has none' (Get-NetworkErrorCauseText $null) ''
# Depth is bounded, so a self-referencing or very deep chain cannot loop.
$deep = $refused
foreach ($i in 1..8) { $deep = New-Object System.InvalidOperationException ('level ' + $i), $deep }
Assert-Equal 'cause: deeper than the walk gives none' (Get-NetworkErrorCauseText $deep) ''
# backlog #27: the tool's own limits (Invoke-DnsLookup, Invoke-TcpConnectionTest) throw a TimeoutException and get a
# cause line like any other network failure - until 1.2.3 they were bare RuntimeExceptions with no cause at all.
$timedOut = New-Object System.TimeoutException 'DNS lookup timed out (more than 1 ms).'
Assert-Equal 'cause: the tool''s own timeout names its marker' ((Get-NetworkErrorCauseText $timedOut).EndsWith('[ToolTimeout]')) True
Assert-Equal 'cause: the tool''s own timeout has a sentence' ((Get-NetworkErrorCauseText $timedOut).Length -gt ('[ToolTimeout]'.Length + 8)) True
Assert-Equal 'cause: the tool''s own timeout is found when wrapped' ((Get-NetworkErrorCauseText (New-Object System.InvalidOperationException 'wrap', $timedOut)).EndsWith('[ToolTimeout]')) True
try { throw $timedOut } catch { $timedOutRecord = $_ }
$timedOutDetails = @((Get-ExceptionDetails $timedOutRecord) -split "`r`n")
Assert-Equal 'details: the tool''s own timeout has the cause first' ($timedOutDetails[0].EndsWith('[ToolTimeout]')) True
Assert-Equal 'details: the tool''s own timeout is not a RuntimeException' (@($timedOutDetails | Where-Object { $_ -match 'RuntimeException' }).Count) 0
Assert-Equal 'details: the tool''s own timeout keeps its message' (@($timedOutDetails | Where-Object { $_ -like '*more than 1 ms*' }).Count -gt 0) True
# And the two functions really throw that type: read off the AST, because a real timeout needs a network that drops
# packets, which the machine running this may not have.
$tokens = $null; $errors = $null
$scriptAst = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$errors)
foreach ($timeoutFunction in @('Invoke-DnsLookup', 'Invoke-TcpConnectionTest')) {
    $fn = $scriptAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $timeoutFunction }, $true)
    $throws = @($fn.FindAll({ param($n) $n -is [System.Management.Automation.Language.ThrowStatementAst] }, $true))
    Assert-Equal "throws: $timeoutFunction has one throw" $throws.Count 1
    Assert-Equal "throws: $timeoutFunction throws a TimeoutException" (($throws | ForEach-Object { $_.Extent.Text }) -match 'New-Object System\.TimeoutException') True
}
$withCause = Add-NetworkErrorCause $refused 'ORIGINAL'
Assert-Equal 'add: original text kept' ($withCause.EndsWith('ORIGINAL')) True
Assert-Equal 'add: cause on its own first line' (@($withCause -split "`r`n").Count) 2
Assert-Equal 'add: first line names the code' ((@($withCause -split "`r`n")[0]).EndsWith('[SocketError ConnectionRefused]')) True
Assert-Equal 'add: no cause returns the text unchanged' (Add-NetworkErrorCause (New-Object System.InvalidOperationException 'nope') 'ORIGINAL') 'ORIGINAL'
Assert-Equal 'add: empty text yields the cause line only' ((Add-NetworkErrorCause $refused '').EndsWith('[SocketError ConnectionRefused]')) True
$oneLine = Add-NetworkErrorCause $refused 'ORIGINAL' -SingleLine
Assert-Equal 'add -SingleLine: one line' (@($oneLine -split "`r`n").Count) 1
Assert-Equal 'add -SingleLine: original text kept' ($oneLine.EndsWith('ORIGINAL')) True
Assert-Equal 'add -SingleLine: cause before the original' (($oneLine.IndexOf('[SocketError ConnectionRefused]')) -lt ($oneLine.IndexOf('ORIGINAL'))) True
Assert-Equal 'add -SingleLine: no cause returns the text unchanged' (Add-NetworkErrorCause (New-Object System.InvalidOperationException 'nope') 'ORIGINAL' -SingleLine) 'ORIGINAL'
# Get-ExceptionDetails puts the cause first, above the type and the operating system's own message.
try { throw $refused } catch { $record = $_ }
$details = @((Get-ExceptionDetails $record) -split "`r`n")
Assert-Equal 'details: cause is the first line' ($details[0].EndsWith('[SocketError ConnectionRefused]')) True
Assert-Equal 'details: original message still present' (@($details | Where-Object { $_ -like ("*" + $refused.Message + "*") }).Count -gt 0) True
try { throw (New-Object System.InvalidOperationException 'plain') } catch { $plainRecord = $_ }
Assert-Equal 'details: no cause line for a non-network error' ((@((Get-ExceptionDetails $plainRecord) -split "`r`n")).Count) 2

# The two language files must offer the same codes: a key misspelled in one of them would silently lose its
# sentence there, and the validator's skeleton comparison cannot see it (it compares string count, not content).
function Get-CauseTableKeys([string]$Path) {
    $tokens = $null; $errors = $null
    $fileAst = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    $fn = $fileAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-NetworkErrorCauseText' }, $true)
    if ($null -eq $fn) { return @() }
    $keys = New-Object System.Collections.ArrayList
    foreach ($table in $fn.FindAll({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true)) {
        foreach ($pair in $table.KeyValuePairs) { [void]$keys.Add($pair.Item1.Extent.Text.Trim('"')) }
    }
    return @($keys | Sort-Object)
}
$thisLang = Split-Path -Leaf (Split-Path -Parent $ScriptPath)
$peerLang = $(if ($thisLang -eq 'en-US') { 'zh-TW' } else { 'en-US' })
$peerPath = Join-Path (Split-Path -Parent (Split-Path -Parent $ScriptPath)) ($peerLang + '\NetworkHealthCheck.ps1')
Assert-Equal "tables: peer file $peerLang is present" (Test-Path -LiteralPath $peerPath) True
$thisKeys = @(Get-CauseTableKeys $ScriptPath)
$peerKeys = @(Get-CauseTableKeys $peerPath)
Assert-Equal 'tables: this file holds every mapped code' (($thisKeys -join ',')) ((@($socketCodes + $webStatuses) | Sort-Object) -join ',')
Assert-Equal "tables: $peerLang holds the same keys" ($peerKeys -join ',') ($thisKeys -join ',')

# backlog #18: a copy started from inside the compressed folder writes its reports into a temporary view that
# disappears with it, so the evidence the user was told to send to IT is gone by the time they look for it.
Assert-Equal 'archive: extracted folder' (Test-IsRunningFromArchive 'C:\Tools\NetworkHealthCheck\en-US') False
Assert-Equal 'archive: Windows compressed-folder view' (Test-IsRunningFromArchive 'C:\Users\x\AppData\Local\Temp\Temp1_NetworkHealthCheck-1.2.2.zip\NetworkHealthCheck-1.2.2\en-US') True
Assert-Equal 'archive: forward slashes' (Test-IsRunningFromArchive 'C:/Temp/Temp1_pack.zip/en-US') True
# backlog #26: Windows 11 extracts into %TEMP%\<guid>_<name>.zip.<hex>\ - the suffix is a few hex digits (.684, .bc4),
# not a number, and the 1.2.2 pattern (".zip" followed by a separator) missed it.
Assert-Equal 'archive: Windows 11 view folder' (Test-IsRunningFromArchive 'C:\Users\x\AppData\Local\Temp\388e11bd-2056-4e77-a266-27df0c2ad684_NetworkHealthCheck-1.2.2.zip.684\NetworkHealthCheck-1.2.2\en-US') True
Assert-Equal 'archive: Windows 11 view folder, letters in the suffix' (Test-IsRunningFromArchive 'C:\Users\x\AppData\Local\Temp\5d2b5f20-1111-4222-8333-e2e558bb2bc4_NetworkHealthCheck-1.2.2.zip.bc4\NetworkHealthCheck-1.2.2\zh-TW') True
Assert-Equal 'archive: Windows 11 view folder, forward slashes' (Test-IsRunningFromArchive 'C:/Temp/5d2b5f20-1111-4222-8333-e2e558bb2bc4_pack.zip.bc4/en-US') True
Assert-Equal 'archive: the Windows 11 view folder itself, not a folder inside it' (Test-IsRunningFromArchive 'C:\Temp\5d2b5f20-1111-4222-8333-e2e558bb2bc4_pack.zip.bc4') False
Assert-Equal 'archive: a backup folder named after the archive' (Test-IsRunningFromArchive 'C:\Backups\pack.zip.old\en-US') False
Assert-Equal 'archive: a folder merely named zipped' (Test-IsRunningFromArchive 'C:\zipped\en-US') False
Assert-Equal 'archive: the archive itself, not a folder inside it' (Test-IsRunningFromArchive 'C:\Downloads\pack.zip') False
Assert-Equal 'archive: empty path' (Test-IsRunningFromArchive '') False
Assert-Equal 'archive: null path' (Test-IsRunningFromArchive $null) False

# ---------------------------------------------------------------------------
# backlog #38: a counter read that fails takes the measurement and the run's length with it. The measured reads now
# get a second attempt, the pre-window read pays the provider's first-query cost outside the sample window, and a row
# whose window ran long says so with the seconds and the attempts that account for it. Everything asserted below is
# language-neutral - statuses, tags, numbers and the "TCPv4 #1" token are the same in both packages - because these
# cases run against each of them; the prose around those tokens is not compared here.
# ---------------------------------------------------------------------------
$script:TcpRows = New-Object System.Collections.ArrayList
# The window's running log, stubbed because a row that is rewritten writes one of its own (backlog #51) and
# there is no window here. What it says is not asserted: it is the same sentence the row carries.
function Write-UiLog { param([string]$Status, [string]$Text) }
function Add-CheckResult {
    # -Weightless is bound rather than left to $args since 1.2.10: backlog #51's acceptance asks for rows that
    # differ in what they decide and not only in what they say, and a stub that swallowed the switch could not
    # tell the two apart.
    # -Rule the same way since 1.2.12 (backlog #67): a row rewritten by its second pass assigns it, and a stub
    # without the field would stop the harness there.
    param([string]$Category, [string]$Check, [string]$Status, [string]$Message, [string]$Details = "", [string]$Diagnostics = "", [string]$Tag = "", [string]$Scope = "Main", [switch]$Weightless, [string]$Rule = "", [string]$Path = "")
    $row = [pscustomobject]@{ Category = $Category; Check = $Check; Status = $Status; Message = $Message; Details = $Details; Diagnostics = $Diagnostics; Tag = $Tag; Scope = $Scope; Weightless = [bool]$Weightless; Rule = $Rule; Path = $Path }
    [void]$script:TcpRows.Add($row)
    return $row
}
$script:Config = [pscustomobject]@{ Thresholds = [pscustomobject]@{ TcpRetransmissionWarningPercent = 2; TcpRetransmissionCriticalPercent = 5; TcpRetransmissionCriticalCount = 50; MinimumTcpSegmentsForRate = 50; MinimumTcpRetransmissionsForVerdict = 5; PacketLossWarningPercent = 5; PacketLossCriticalPercent = 20; LatencyWarningMs = 100; LatencyCriticalMs = 250 } }
$script:RunOptions = [pscustomobject]@{ SampleSeconds = 8 }
$script:RetransmissionRateComputed = $false

# The stub stands where Get-CimInstance stands, so what runs above it is the helper's own retry loop and the snapshot
# function's own bookkeeping. $CimPlan holds one outcome per call per class ('fail', anything else succeeds) and calls
# past the plan succeed; the counters it returns rise with each call of that class, so a later snapshot is always
# ahead of an earlier one. The exception is the one the walk recorded on win11-enUS on 2026-09-08 - a real timeout
# needs a machine under load, which a unit test cannot arrange and tests\tcp_counter_rate.ps1 measures instead.
$script:CimPlan = @{}
$script:CimCalls = New-Object System.Collections.ArrayList
function Get-CimInstance {
    [CmdletBinding()]
    param([string]$ClassName, [int]$OperationTimeoutSec)
    $index = @($script:CimCalls | Where-Object { $_ -eq $ClassName }).Count
    [void]$script:CimCalls.Add($ClassName)
    $plan = @($script:CimPlan[$ClassName])
    $outcome = ''
    if ($index -lt $plan.Count) { $outcome = [string]$plan[$index] }
    if ($outcome -eq 'fail') {
        throw (New-Object Microsoft.Management.Infrastructure.CimException "Timed out")
    }
    # The other two ways a read fails without throwing: nothing comes back, or what comes back has no counters on it.
    if ($outcome -eq 'empty') { return $null }
    if ($outcome -eq 'partial') { return [pscustomobject]@{ Name = 'an instance with no counters on it' } }
    return [pscustomobject]@{ SegmentsSentPersec = [uint64](1000 + 100 * $index); SegmentsRetransmittedPersec = [uint64](10 + $index) }
}
function Reset-CimStub($plan) {
    $script:CimPlan = $plan
    $script:CimCalls = New-Object System.Collections.ArrayList
    $script:TcpRows = New-Object System.Collections.ArrayList
}
function Get-CimCallCount($className) { @($script:CimCalls | Where-Object { $_ -eq $className }).Count }
$v4Class = 'Win32_PerfRawData_Tcpip_TCPv4'
$v6Class = 'Win32_PerfRawData_Tcpip_TCPv6'

# The helper attempts once unless asked for more, and records the attempt that failed even so.
Reset-CimStub @{ 'X' = @('fail') }
$attemptLog = New-Object System.Collections.ArrayList
$helperThrew = $false
try { Get-CimOrWmiInstance -ClassName 'X' -FailedAttempts $attemptLog | Out-Null } catch { $helperThrew = $true }
Assert-Equal '#38 helper: one attempt unless more are asked for' $helperThrew True
Assert-Equal '#38 helper: one call was made' (Get-CimCallCount 'X') 1
Assert-Equal '#38 helper: the failed attempt is recorded' (@($attemptLog).Count) 1
Assert-Equal '#38 helper: the record names the attempt' (@($attemptLog)[0].Attempt) 1
Assert-Equal '#38 helper: the record carries the seconds it spent' (@($attemptLog)[0].Seconds -ge 0) True
# Two attempts that both fail reach the caller as the failure, not as a reading: a retry that hides a real failure is
# worse than no retry.
Reset-CimStub @{ 'X' = @('fail', 'fail') }
$helperError = $null
try { Get-CimOrWmiInstance -ClassName 'X' -Attempts 2 | Out-Null } catch { $helperError = $_ }
Assert-Equal '#38 helper: the failure still reaches the caller' ((Get-ExceptionDetails $helperError) -match 'Timed out') True
Assert-Equal '#38 helper: it stops at the attempts it was given' (Get-CimCallCount 'X') 2

# A read that times out once and works on the second attempt is a reading, not an Unable to Check row - and the
# attempt it spent is kept, because the row that explains a long window is written from it.
Reset-CimStub @{ $v4Class = @('fail') }
$snapRetry = Get-TcpCounterSnapshot
Assert-Equal '#38 retry: both protocols are read' $snapRetry.Counters.Count 2
Assert-Equal '#38 retry: nothing is reported as unreadable' (@($snapRetry.Errors).Count) 0
Assert-Equal '#38 retry: the read that failed was attempted twice' (Get-CimCallCount $v4Class) 2
Assert-Equal '#38 retry: the read that worked was attempted once' (Get-CimCallCount $v6Class) 1
Assert-Equal '#38 retry: the failed attempt survives the success' (@($snapRetry.FailedAttempts).Count) 1
Assert-Equal '#38 retry: it names its protocol and its number' ("{0} #{1}" -f @($snapRetry.FailedAttempts)[0].Protocol, @($snapRetry.FailedAttempts)[0].Attempt) 'TCPv4 #1'

# Both attempts failing produces what today produced: no counter, one error, and no third attempt.
Reset-CimStub @{ $v4Class = @('fail', 'fail') }
$snapFailed = Get-TcpCounterSnapshot
Assert-Equal '#38 both fail: no counter is invented' ($snapFailed.Counters.ContainsKey('TCPv4')) False
Assert-Equal '#38 both fail: the error is recorded' (@($snapFailed.Errors).Count) 1
Assert-Equal '#38 both fail: the error names the protocol' (@($snapFailed.Errors)[0].Protocol) 'TCPv4'
Assert-Equal '#38 both fail: exactly two attempts were made' (Get-CimCallCount $v4Class) 2
Assert-Equal '#38 both fail: both attempts are kept' (@($snapFailed.FailedAttempts).Count) 2
Assert-Equal '#38 both fail: the other protocol is unaffected' ($snapFailed.Counters.ContainsKey('TCPv6')) True

# -WarmUp takes one throwaway read per class before the measured one. Its reading is discarded and its failure is
# neither an error nor a measured attempt: TCPv4 fails the warm-up and the first measured attempt here, and the
# counter is still read on the second - three calls, one warm-up failure, one measured failure, no error row.
Reset-CimStub @{ $v4Class = @('fail', 'fail') }
$snapWarm = Get-TcpCounterSnapshot -WarmUp
Assert-Equal '#38 warm-up: the throwaway read is taken as well' (Get-CimCallCount $v4Class) 3
Assert-Equal '#38 warm-up: the other protocol is warmed too' (Get-CimCallCount $v6Class) 2
Assert-Equal '#38 warm-up: the counter is still read' ($snapWarm.Counters.ContainsKey('TCPv4')) True
Assert-Equal '#38 warm-up: a failed warm-up is not an error' (@($snapWarm.Errors).Count) 0
Assert-Equal '#38 warm-up: its failure is kept apart' (@($snapWarm.WarmUpFailures).Count) 1
Assert-Equal '#38 warm-up: and is not counted as a measured attempt' (@($snapWarm.FailedAttempts).Count) 1
Assert-Equal '#38 warm-up: the throwaway read is attempted once, not twice' (@($snapWarm.WarmUpFailures)[0].Attempt) 1

# PR #40, round 3: the warm-ups are a pass of their own, taken before any counter is read. Interleaved with the
# measured reads, TCPv6's warm-up fell after TCPv4's baseline stamp and so inside TCPv4's window - and a warm-up that
# is merely slow, which is the start-up cost the feature exists to absorb, would have lengthened that window while
# leaving no failure behind to explain it. The call order is the assertion: both classes warmed, then both read.
Reset-CimStub @{}
$snapOrdered = Get-TcpCounterSnapshot -WarmUp
Assert-Equal '#38 warm-up: every protocol is warmed before any counter is read' ($script:CimCalls -join ',') ("{0},{1},{0},{1}" -f $v4Class, $v6Class)
Assert-Equal '#38 warm-up: and both counters are still read' $snapOrdered.Counters.Count 2

# Where the warm-up goes: the baseline snapshot takes it, the ending one does not - a throwaway read inside the
# sample window would lengthen the very thing it is there to protect. Read off the AST, because the run itself needs
# a machine with counters on it.
$snapshotCalls = @($scriptAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Get-TcpCounterSnapshot' }, $true))
# Three since 1.2.10: the baseline, the ending one, and the read that closes a window extended once because the
# sample was below the rating floor with a retransmission in it (backlog #51). The warm-up assertions are what
# they were and are what matter here - the extra read is at the END of a window, where a warm-up would be the
# very thing #38 removed.
Assert-Equal '#38 warm-up: the run takes three snapshots' $snapshotCalls.Count 3
Assert-Equal '#38 warm-up: exactly one of them warms the provider' (@($snapshotCalls | Where-Object { $_.Extent.Text -match '-WarmUp' }).Count) 1
Assert-Equal '#38 warm-up: it is the baseline, the first of the three' ((@($snapshotCalls | Sort-Object { $_.Extent.StartOffset })[0].Extent.Text -match '-WarmUp')) True
Assert-Equal '#51 extension: the third read is not a warm-up' ((@($snapshotCalls | Sort-Object { $_.Extent.StartOffset })[2].Extent.Text -match '-WarmUp')) False

# PR #40, round 10: the chain's own fact probe (tests\Invoke-ValidationChain.ps1, Get-MachineFacts) mirrors the
# measured read - two attempts, and these two fields - so that it never calls a class unreadable that the run reads on
# its retry, which would make Test-ResultSet reject a correct report. The mirror is only safe while the shipped call
# says what the probe assumes, and this is where that is checked.
$counterReads = @($scriptAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Get-CimOrWmiInstance' -and $n.Extent.Text -match '-Attempts' }, $true))
Assert-Equal '#38 probe: one counter read asks for more than a single attempt' $counterReads.Count 1
Assert-Equal '#38 probe: it asks for two of them' ($counterReads[0].Extent.Text -match '-Attempts 2') True
Assert-Equal '#38 probe: and requires the two fields the probe looks for' ((($counterReads[0].Extent.Text -match 'SegmentsSentPersec') -and ($counterReads[0].Extent.Text -match 'SegmentsRetransmittedPersec'))) True

# The duration a row reports comes from that protocol's own two stamps. The fixture is the shape of the failure the
# walk found: the ending TCPv4 read waits out its limit twice (8 seconds each) and TCPv6, read after it, is stamped
# 24.5 seconds after its own baseline stamp - while the snapshots enclosing the pair are 26 seconds apart, which is
# the number this row printed until 1.2.8 and the one nobody could explain.
function New-CounterFixture($protocol, $stamp, $sent, $retransmitted) {
    return [pscustomobject]@{ Protocol = $protocol; Timestamp = $stamp; SegmentsSent = [uint64]$sent; Retransmitted = [uint64]$retransmitted }
}
$fixtureStart = Get-Date '2026-09-08T12:47:00'
$beforeFixture = [pscustomobject]@{
    Timestamp = $fixtureStart.AddSeconds(1.0)
    Counters  = @{ 'TCPv4' = (New-CounterFixture 'TCPv4' $fixtureStart 1000 10); 'TCPv6' = (New-CounterFixture 'TCPv6' $fixtureStart.AddSeconds(0.5) 1000 10) }
    Errors    = @()
    FailedAttempts = @()
    WarmUpFailures = @([pscustomobject]@{ Protocol = 'TCPv6'; Attempt = 1; Seconds = 8.0; Error = 'Timed out' })
}
$afterFixture = [pscustomobject]@{
    Timestamp = $fixtureStart.AddSeconds(27.0)
    Counters  = @{ 'TCPv6' = (New-CounterFixture 'TCPv6' $fixtureStart.AddSeconds(25.0) 1100 11) }
    Errors    = @([pscustomobject]@{ Protocol = 'TCPv4'; Error = 'Timed out'; Diagnostics = '' })
    FailedAttempts = @(
        [pscustomobject]@{ Protocol = 'TCPv4'; Attempt = 1; Seconds = 8.0; Error = 'Timed out' },
        [pscustomobject]@{ Protocol = 'TCPv4'; Attempt = 2; Seconds = 8.0; Error = 'Timed out' })
    WarmUpFailures = @()
}
$script:TcpRows = New-Object System.Collections.ArrayList
Compare-TcpCounters -Before $beforeFixture -After $afterFixture
$rowsUnreadable = @($script:TcpRows | Where-Object { $_.Status -eq 'ERROR' })
$rowV6 = @($script:TcpRows | Where-Object { $_.Check -eq 'TCPv6' })
Assert-Equal '#38 rows: the read that failed keeps its own row' $rowsUnreadable.Count 1
Assert-Equal '#38 rows: that row is still about TCPv4' ($rowsUnreadable[0].Check -like 'TCPv4*') True
Assert-Equal '#38 rows: it carries the original error text' ($rowsUnreadable[0].Details -match 'Timed out') True
Assert-Equal '#38 rows: and the attempts behind it' ($rowsUnreadable[0].Details -match 'TCPv4 #1, TCPv4 #2') True
Assert-Equal '#38 rows: it says nothing about the other protocol' ($rowsUnreadable[0].Details -match 'TCPv6') False
Assert-Equal '#38 rows: the protocol that was read still has its own' $rowV6.Count 1
Assert-Equal '#38 duration: the window is this protocol''s own, from its own stamps' ($rowV6[0].Details -match '24\.5') True
Assert-Equal '#38 duration: not the span of the snapshots enclosing it' ($rowV6[0].Details -match '(?<![\d.])26(?![\d.])') False
Assert-Equal '#38 duration: the configured minimum stands beside it' ($rowV6[0].Details -match '(?<![\d.])8(?![\d.])') True
Assert-Equal '#38 window: the seconds that went on failed reads are named' ($rowV6[0].Details -match '(?<![\d.])16(?![\d.])') True
Assert-Equal '#38 window: and the attempts they went on' ($rowV6[0].Details -match 'TCPv4 #1, TCPv4 #2') True
Assert-Equal '#38 window: the pre-window read that failed is named too' ($rowV6[0].Details -match 'TCPv6 #1') True
Assert-Equal '#38 window: the reading itself is unaffected' ($rowV6[0].Status) 'PASS'
Assert-Equal '#38 window: and its delta is the one the counters give' ($rowV6[0].Details -match '(?<![\d.])100(?![\d.])') True

# Nothing failed: no attempt line, no note, and the duration is still the protocol's own.
$cleanBefore = [pscustomobject]@{
    Timestamp = $fixtureStart.AddSeconds(1.0)
    Counters  = @{ 'TCPv4' = (New-CounterFixture 'TCPv4' $fixtureStart 1000 10); 'TCPv6' = (New-CounterFixture 'TCPv6' $fixtureStart.AddSeconds(0.5) 1000 10) }
    Errors    = @(); FailedAttempts = @(); WarmUpFailures = @()
}
$cleanAfter = [pscustomobject]@{
    Timestamp = $fixtureStart.AddSeconds(12.0)
    Counters  = @{ 'TCPv4' = (New-CounterFixture 'TCPv4' $fixtureStart.AddSeconds(10.5) 1100 11); 'TCPv6' = (New-CounterFixture 'TCPv6' $fixtureStart.AddSeconds(11.0) 1100 11) }
    Errors    = @(); FailedAttempts = @(); WarmUpFailures = @()
}
$script:TcpRows = New-Object System.Collections.ArrayList
Compare-TcpCounters -Before $cleanBefore -After $cleanAfter
$cleanV4 = @($script:TcpRows | Where-Object { $_.Check -eq 'TCPv4' })
Assert-Equal '#38 clean run: one row per protocol' (@($script:TcpRows).Count) 2
Assert-Equal '#38 clean run: no row is about an unreadable counter' (@($script:TcpRows | Where-Object { $_.Status -eq 'ERROR' }).Count) 0
# backlog #52: the system-wide rows point at the attributable figure - the TCP Connection rows' connection times - only
# where the run took one, so that a run without a TCP target that answered is not sent to a row it does not have.
$script:TcpConnectSampleCount = 0
$script:TcpRows = New-Object System.Collections.ArrayList
Compare-TcpCounters -Before $cleanBefore -After $cleanAfter
$withoutSample = @($script:TcpRows | Where-Object { $_.Check -eq 'TCPv4' })[0]
$script:TcpConnectSampleCount = 1
$script:TcpRows = New-Object System.Collections.ArrayList
Compare-TcpCounters -Before $cleanBefore -After $cleanAfter
$withSample = @($script:TcpRows | Where-Object { $_.Check -eq 'TCPv4' })[0]
$script:TcpConnectSampleCount = 0
Assert-Equal '#52 rows: the system-wide row names the TCP Connection rows only where a sample was taken' (("{0}/{1}/{2}" -f (@($withSample.Details -split "`r`n").Count - @($withoutSample.Details -split "`r`n").Count), ($withSample.Details -match 'TCP Connection|TCP 連線'), ($withoutSample.Details -match 'TCP Connection|TCP 連線'))) '1/True/False'
Assert-Equal '#38 clean run: the window is the protocol''s own' ($cleanV4[0].Details -match '10\.5') True
Assert-Equal '#38 clean run: nothing is said about attempts that did not fail' ($cleanV4[0].Details -match '#') False

# ---- backlog #57: the row says what its percentage divides by, and the arithmetic is pinned to that statement ----
# The denominator is the Segments Sent/sec counter's delta - every segment this computer sent, acknowledgements
# included, segments carrying only retransmitted bytes excluded - and the numerator the Segments Retransmitted/sec
# delta. The sentence names that counter, which is the same token in both packages, and the figure is checked
# against the same two deltas by hand, so a change to either the sentence or the division fails here.
$denominatorBefore = [pscustomobject]@{
    Timestamp = $fixtureStart.AddSeconds(1.0)
    Counters  = @{ 'TCPv4' = (New-CounterFixture 'TCPv4' $fixtureStart 5000 100); 'TCPv6' = (New-CounterFixture 'TCPv6' $fixtureStart.AddSeconds(0.5) 700 3) }
    Errors    = @(); FailedAttempts = @(); WarmUpFailures = @()
}
$denominatorAfter = [pscustomobject]@{
    Timestamp = $fixtureStart.AddSeconds(12.0)
    Counters  = @{ 'TCPv4' = (New-CounterFixture 'TCPv4' $fixtureStart.AddSeconds(10.5) 9000 171); 'TCPv6' = (New-CounterFixture 'TCPv6' $fixtureStart.AddSeconds(11.0) 700 3) }
    Errors    = @(); FailedAttempts = @(); WarmUpFailures = @()
}
$script:TcpRows = New-Object System.Collections.ArrayList
Compare-TcpCounters -Before $denominatorBefore -After $denominatorAfter
$rateRow = @($script:TcpRows | Where-Object { $_.Check -eq 'TCPv4' })[0]
$quietRow = @($script:TcpRows | Where-Object { $_.Check -eq 'TCPv6' })[0]
Assert-Equal '#57 rate: the sent delta is the Segments Sent counter''s, 9 000 less 5 000' ($rateRow.Details -match '(?<![\d.])4000(?![\d.])') True
Assert-Equal '#57 rate: the retransmitted delta is the other counter''s, 171 less 100' ($rateRow.Details -match '(?<![\d.])71(?![\d.])') True
Assert-Equal '#57 rate: and the percentage is the one over the other, 1.775' ($rateRow.Details -match '(?<![\d.])1\.775%') True
Assert-Equal '#57 rate: the row names the counter its denominator comes from' ($rateRow.Details -match 'Segments Sent/sec') True
# A window in which nothing was counted as sent has no ratio (PR #50, round 2): no 0%, and no sentence about what a
# percentage divides by. And under the documented semantics such a window can still carry retransmissions - the sent
# counter excludes segments carrying only previously sent bytes - so that row keeps its count and still prints no rate.
Assert-Equal '#57 rate: a row in which nothing was sent prints no denominator sentence' ($quietRow.Details -match 'Segments Sent/sec') False
Assert-Equal '#57 rate: and no 0% either, because 0 over 0 is not a ratio' ($quietRow.Details -match '(?<![\d.])0%') False
$pureBefore = [pscustomobject]@{
    Timestamp = $fixtureStart.AddSeconds(1.0)
    Counters  = @{ 'TCPv4' = (New-CounterFixture 'TCPv4' $fixtureStart 700 3) }
    Errors    = @(); FailedAttempts = @(); WarmUpFailures = @()
}
$pureAfter = [pscustomobject]@{
    Timestamp = $fixtureStart.AddSeconds(12.0)
    Counters  = @{ 'TCPv4' = (New-CounterFixture 'TCPv4' $fixtureStart.AddSeconds(10.5) 700 5) }
    Errors    = @(); FailedAttempts = @(); WarmUpFailures = @()
}
$script:TcpRows = New-Object System.Collections.ArrayList
Compare-TcpCounters -Before $pureBefore -After $pureAfter
$pureRow = @($script:TcpRows)[0]
Assert-Equal '#57 rate: two retransmissions and nothing counted as sent is the small-sample Information row' $pureRow.Status 'INFO'
Assert-Equal '#57 rate: which names the two' ($pureRow.Details -match '(?<![\d.])2(?![\d.])') True
Assert-Equal '#57 rate: prints no 0%' ($pureRow.Details -match '(?<![\d.])0%') False
Assert-Equal '#57 rate: and no denominator sentence, since it divided nothing' ($pureRow.Details -match 'Segments Sent/sec') False
# The message is the line the report shows before the details, and round 2's assertions stopped at the details
# (PR #50, round 3): it must not print the 0% the details no longer do, and it still names what was counted.
Assert-Equal '#57 rate: nor does its message, which the report shows first' ($pureRow.Message -match '(?<![\d.])0%') False
Assert-Equal '#57 rate: while the message still names the two it counted' ($pureRow.Message -match '(?<![\d.])2(?![\d.])') True
Assert-Equal '#38 clean run: and nothing about a window that did not run long' (@(Get-TcpReadFailureLines -Snapshot $cleanBefore -Protocol 'TCPv4').Count) 0

# PR #40, round 1: a baseline read that stalls delays every stamp taken after it, so it lands inside the window of
# each protocol read *before* it - the first draft of this change called every baseline failure harmless, which is
# true only of the protocol read first. Here TCPv6's pre-window read and its first measured attempt both fail (7.3 s
# and 8.9 s). Only the measured one is inside TCPv4's window: since round 3 the warm-ups are a pass of their own,
# before either baseline stamp, so a pre-window read lengthens nobody's window and appears only as the failed read
# of its own protocol. TCPv6's own window opens after both and is untouched either way.
$baselineDelayBefore = [pscustomobject]@{
    Timestamp = $fixtureStart.AddSeconds(17.0)
    Counters  = @{ 'TCPv4' = (New-CounterFixture 'TCPv4' $fixtureStart 1000 10); 'TCPv6' = (New-CounterFixture 'TCPv6' $fixtureStart.AddSeconds(16.5) 1000 10) }
    Errors    = @()
    FailedAttempts = @([pscustomobject]@{ Protocol = 'TCPv6'; Phase = 'read'; Attempt = 1; Seconds = 8.9; Error = 'Timed out' })
    WarmUpFailures = @([pscustomobject]@{ Protocol = 'TCPv6'; Phase = 'warm-up'; Attempt = 1; Seconds = 7.3; Error = 'Timed out' })
}
$baselineDelayAfter = [pscustomobject]@{
    Timestamp = $fixtureStart.AddSeconds(26.0)
    Counters  = @{ 'TCPv4' = (New-CounterFixture 'TCPv4' $fixtureStart.AddSeconds(25.0) 1100 11); 'TCPv6' = (New-CounterFixture 'TCPv6' $fixtureStart.AddSeconds(25.5) 1100 11) }
    Errors    = @(); FailedAttempts = @(); WarmUpFailures = @()
}
$script:TcpRows = New-Object System.Collections.ArrayList
Compare-TcpCounters -Before $baselineDelayBefore -After $baselineDelayAfter
$delayV4 = @($script:TcpRows | Where-Object { $_.Check -eq 'TCPv4' })[0]
$delayV6 = @($script:TcpRows | Where-Object { $_.Check -eq 'TCPv6' })[0]
Assert-Equal '#38 baseline delay: the earlier protocol reports the window it really measured' ($delayV4.Details -match '(?<![\d.])25(?![\d.])') True
Assert-Equal '#38 baseline delay: and says the later protocol''s failed measured read is inside it' ($delayV4.Details -match '8\.9') True
Assert-Equal '#38 baseline delay: naming it, once' (([regex]::Matches($delayV4.Details, 'TCPv6 #1')).Count) 1
Assert-Equal '#38 baseline delay: the pre-window read is not among them, being taken before either baseline stamp' ($delayV4.Details -match 'TCPv6 #1 \(the discarded|TCPv6 #1（窗前捨棄') False
Assert-Equal '#38 baseline delay: so the seconds are the measured attempt''s alone' ($delayV4.Details -match '16\.2') False
Assert-Equal '#38 baseline delay: the later protocol''s own window opened after them' ($delayV6.Details -match '(?<![\d.])9(?![\d.])') True
Assert-Equal '#38 baseline delay: so its row names them once, as its own reads, and not as its window''s' (([regex]::Matches($delayV6.Details, 'TCPv6 #1')).Count) 2
Assert-Equal '#38 baseline delay: with the pre-window read marked as one there' ($delayV6.Details -match 'TCPv6 #1 \(the discarded|TCPv6 #1（窗前捨棄') True
Assert-Equal '#38 baseline delay: neither reading is disturbed' (("{0}/{1}" -f $delayV4.Status, $delayV6.Status)) 'PASS/PASS'

# A baseline read of the protocol read *first* stalls: it pushes its own stamp, the other protocol's and the sample
# start alike, so it lengthens no window at all and no row mentions it except as TCPv4's own failed read.
$firstDelayBefore = [pscustomobject]@{
    Timestamp = $fixtureStart.AddSeconds(9.0)
    Counters  = @{ 'TCPv4' = (New-CounterFixture 'TCPv4' $fixtureStart.AddSeconds(8.0) 1000 10); 'TCPv6' = (New-CounterFixture 'TCPv6' $fixtureStart.AddSeconds(8.5) 1000 10) }
    Errors    = @()
    FailedAttempts = @([pscustomobject]@{ Protocol = 'TCPv4'; Phase = 'read'; Attempt = 1; Seconds = 8.0; Error = 'Timed out' })
    WarmUpFailures = @()
}
$script:TcpRows = New-Object System.Collections.ArrayList
Compare-TcpCounters -Before $firstDelayBefore -After $cleanAfter
$firstV4 = @($script:TcpRows | Where-Object { $_.Check -eq 'TCPv4' })[0]
$firstV6 = @($script:TcpRows | Where-Object { $_.Check -eq 'TCPv6' })[0]
Assert-Equal '#38 first-read delay: it is named once, as TCPv4''s own failed read' (([regex]::Matches($firstV4.Details, 'TCPv4 #1')).Count) 1
Assert-Equal '#38 first-read delay: and not against the other protocol''s window' ($firstV6.Details -match 'TCPv4 #1') False
Assert-Equal '#38 first-read delay: the windows are the ones the stamps give' ((("{0}|{1}" -f ($firstV4.Details -match '(?<![\d.])2\.5(?![\d.])'), ($firstV6.Details -match '(?<![\d.])2\.5(?![\d.])')))) 'True|True'

# PR #40, round 4: a protocol whose counter could not be read has no reading, so no quality row - and the row that
# says it could not be read was the only place its attempts could still appear. Rendering only the failing snapshot's
# attempts therefore threw away the other snapshot's: a failed baseline warm-up before a successful baseline read
# vanished when the ending read failed twice, and a redeemed ending attempt vanished when the baseline read failed.
$lostEndingBefore = [pscustomobject]@{
    Timestamp = $fixtureStart.AddSeconds(0.6)
    Counters  = @{ 'TCPv4' = (New-CounterFixture 'TCPv4' $fixtureStart 1000 10); 'TCPv6' = (New-CounterFixture 'TCPv6' $fixtureStart.AddSeconds(0.5) 1000 10) }
    Errors    = @()
    FailedAttempts = @()
    WarmUpFailures = @([pscustomobject]@{ Protocol = 'TCPv4'; Phase = 'warm-up'; Attempt = 1; Seconds = 6.1; Error = 'Timed out' })
}
$lostEndingAfter = [pscustomobject]@{
    Timestamp = $fixtureStart.AddSeconds(21.0)
    Counters  = @{ 'TCPv6' = (New-CounterFixture 'TCPv6' $fixtureStart.AddSeconds(20.5) 1100 11) }
    Errors    = @([pscustomobject]@{ Protocol = 'TCPv4'; Error = 'Timed out'; Diagnostics = '' })
    FailedAttempts = @(
        [pscustomobject]@{ Protocol = 'TCPv4'; Phase = 'read'; Attempt = 1; Seconds = 8.0; Error = 'Timed out' },
        [pscustomobject]@{ Protocol = 'TCPv4'; Phase = 'read'; Attempt = 2; Seconds = 8.0; Error = 'Timed out' })
    WarmUpFailures = @()
}
$script:TcpRows = New-Object System.Collections.ArrayList
Compare-TcpCounters -Before $lostEndingBefore -After $lostEndingAfter
$lostEndingRow = @($script:TcpRows | Where-Object { $_.Status -eq 'ERROR' })
Assert-Equal '#38 lost reading: one row says the counter could not be read' $lostEndingRow.Count 1
Assert-Equal '#38 lost reading: it carries the attempts that failed' ($lostEndingRow[0].Details -match 'TCPv4 #1, TCPv4 #2') True
Assert-Equal '#38 lost reading: and the baseline warm-up that has nowhere else to go' ($lostEndingRow[0].Details -match 'TCPv4 #1 \(the discarded|TCPv4 #1（窗前捨棄') True
Assert-Equal '#38 lost reading: with its own seconds' ($lostEndingRow[0].Details -match '6\.1') True
# A line that does not say which snapshot it came from would let a baseline failure read as an ending one, and this
# row now carries both. Mutation Q3 of this round - the ending line labelled as the baseline's - passed every other
# assertion in the file, which is why these three exist.
Assert-Equal '#38 lost reading: the ending attempts say they are the ending''s' ($lostEndingRow[0].Details -match 'while the ending values were taken|取結束值時') True
Assert-Equal '#38 lost reading: and the baseline one says it is the baseline''s' ($lostEndingRow[0].Details -match 'while the baseline was taken|取基準值時') True

# The mirror image: the baseline read fails twice, and the ending read of the same protocol failed once before
# succeeding. That redeemed attempt is recorded, and this row is the only place it can be read.
$lostBaselineBefore = [pscustomobject]@{
    Timestamp = $fixtureStart.AddSeconds(16.6)
    Counters  = @{ 'TCPv6' = (New-CounterFixture 'TCPv6' $fixtureStart.AddSeconds(16.5) 1000 10) }
    Errors    = @([pscustomobject]@{ Protocol = 'TCPv4'; Error = 'Timed out'; Diagnostics = '' })
    FailedAttempts = @(
        [pscustomobject]@{ Protocol = 'TCPv4'; Phase = 'read'; Attempt = 1; Seconds = 8.0; Error = 'Timed out' },
        [pscustomobject]@{ Protocol = 'TCPv4'; Phase = 'read'; Attempt = 2; Seconds = 8.0; Error = 'Timed out' })
    WarmUpFailures = @()
}
$lostBaselineAfter = [pscustomobject]@{
    Timestamp = $fixtureStart.AddSeconds(33.0)
    Counters  = @{ 'TCPv4' = (New-CounterFixture 'TCPv4' $fixtureStart.AddSeconds(32.0) 1100 11); 'TCPv6' = (New-CounterFixture 'TCPv6' $fixtureStart.AddSeconds(32.5) 1100 11) }
    Errors    = @()
    FailedAttempts = @([pscustomobject]@{ Protocol = 'TCPv4'; Phase = 'read'; Attempt = 1; Seconds = 7.4; Error = 'Timed out' })
    WarmUpFailures = @()
}
$script:TcpRows = New-Object System.Collections.ArrayList
Compare-TcpCounters -Before $lostBaselineBefore -After $lostBaselineAfter
$lostBaselineRow = @($script:TcpRows | Where-Object { $_.Status -eq 'ERROR' })
Assert-Equal '#38 redeemed attempt: one row again' $lostBaselineRow.Count 1
Assert-Equal '#38 redeemed attempt: the ending attempt that a later one redeemed is in it' ($lostBaselineRow[0].Details -match '7\.4') True
Assert-Equal '#38 redeemed attempt: three attempts in all, two failed and one redeemed' (([regex]::Matches($lostBaselineRow[0].Details, 'TCPv4 #')).Count) 3
Assert-Equal '#38 redeemed attempt: no reading is invented for the protocol that lost its baseline' (@($script:TcpRows | Where-Object { $_.Check -eq 'TCPv4' }).Count) 0

# Both snapshots fail for the same protocol: each row carries its own attempts and neither repeats the other's,
# because each snapshot already has a row of its own to be read in.
$bothFailBefore = [pscustomobject]@{
    Timestamp = $fixtureStart.AddSeconds(16.6)
    Counters  = @{ 'TCPv6' = (New-CounterFixture 'TCPv6' $fixtureStart.AddSeconds(16.5) 1000 10) }
    Errors    = @([pscustomobject]@{ Protocol = 'TCPv4'; Error = 'Timed out'; Diagnostics = '' })
    FailedAttempts = @(
        [pscustomobject]@{ Protocol = 'TCPv4'; Phase = 'read'; Attempt = 1; Seconds = 8.0; Error = 'Timed out' },
        [pscustomobject]@{ Protocol = 'TCPv4'; Phase = 'read'; Attempt = 2; Seconds = 8.0; Error = 'Timed out' })
    WarmUpFailures = @()
}
$bothFailAfter = [pscustomobject]@{
    Timestamp = $fixtureStart.AddSeconds(33.0)
    Counters  = @{ 'TCPv6' = (New-CounterFixture 'TCPv6' $fixtureStart.AddSeconds(32.5) 1100 11) }
    Errors    = @([pscustomobject]@{ Protocol = 'TCPv4'; Error = 'Timed out'; Diagnostics = '' })
    FailedAttempts = @(
        [pscustomobject]@{ Protocol = 'TCPv4'; Phase = 'read'; Attempt = 1; Seconds = 8.0; Error = 'Timed out' },
        [pscustomobject]@{ Protocol = 'TCPv4'; Phase = 'read'; Attempt = 2; Seconds = 8.0; Error = 'Timed out' })
    WarmUpFailures = @()
}
$script:TcpRows = New-Object System.Collections.ArrayList
Compare-TcpCounters -Before $bothFailBefore -After $bothFailAfter
$bothFailRows = @($script:TcpRows | Where-Object { $_.Status -eq 'ERROR' })
Assert-Equal '#38 both snapshots fail: one row each' $bothFailRows.Count 2
Assert-Equal '#38 both snapshots fail: the first names two attempts, not four' (([regex]::Matches($bothFailRows[0].Details, 'TCPv4 #')).Count) 2
Assert-Equal '#38 both snapshots fail: and so does the second' (([regex]::Matches($bothFailRows[1].Details, 'TCPv4 #')).Count) 2
Assert-Equal '#38 both snapshots fail: the first is the baseline''s and says so' ((("{0}|{1}" -f ($bothFailRows[0].Details -match 'while the baseline was taken|取基準值時'), ($bothFailRows[0].Details -match 'while the ending values were taken|取結束值時')))) 'True|False'
Assert-Equal '#38 both snapshots fail: the second is the ending''s and says so' ((("{0}|{1}" -f ($bothFailRows[1].Details -match 'while the ending values were taken|取結束值時'), ($bothFailRows[1].Details -match 'while the baseline was taken|取基準值時')))) 'True|False'

# PR #40, round 5. A query that returns nothing, or an instance without the fields the caller needs, is a read that
# failed as surely as one that threw - and the check for it used to sit outside the retry loop, so a timeout got a
# second attempt and an empty result did not.
Reset-CimStub @{ $v4Class = @('empty') }
$snapEmpty = Get-TcpCounterSnapshot
Assert-Equal '#38 empty result: it is attempted again' (Get-CimCallCount $v4Class) 2
Assert-Equal '#38 empty result: and the counter is read on the second attempt' ($snapEmpty.Counters.ContainsKey('TCPv4')) True
Assert-Equal '#38 empty result: the attempt that returned nothing is kept' (@($snapEmpty.FailedAttempts).Count) 1
Assert-Equal '#38 empty result: nothing is reported as unreadable' (@($snapEmpty.Errors).Count) 0
Reset-CimStub @{ $v4Class = @('partial', 'partial') }
$snapPartial = Get-TcpCounterSnapshot
Assert-Equal '#38 missing fields: two attempts, and no third' (Get-CimCallCount $v4Class) 2
Assert-Equal '#38 missing fields: no counter is invented from an instance without them' ($snapPartial.Counters.ContainsKey('TCPv4')) False
Assert-Equal '#38 missing fields: the row that says so is written' (@($snapPartial.Errors).Count) 1
Assert-Equal '#38 missing fields: both attempts are kept' (@($snapPartial.FailedAttempts).Count) 2
# The pre-window read asks for no properties, because its reading is discarded: an empty answer to it is not a
# failure and must not be recorded as one.
Reset-CimStub @{ $v4Class = @('empty') }
$snapWarmEmpty = Get-TcpCounterSnapshot -WarmUp
Assert-Equal '#38 empty result: an empty pre-window read is not a failure' (@($snapWarmEmpty.WarmUpFailures).Count) 0
Assert-Equal '#38 empty result: and it costs the measured read nothing' (@($snapWarmEmpty.FailedAttempts).Count) 0

# A counter that reset or overflowed writes its own row and skips the rest of the loop - and used to skip the
# evidence with it, so a read that failed and was redeemed vanished from a run whose counters had reset.
$resetBefore = [pscustomobject]@{
    Timestamp = $fixtureStart.AddSeconds(0.6)
    Counters  = @{ 'TCPv4' = (New-CounterFixture 'TCPv4' $fixtureStart 5000 50); 'TCPv6' = (New-CounterFixture 'TCPv6' $fixtureStart.AddSeconds(0.5) 1000 10) }
    Errors    = @(); FailedAttempts = @(); WarmUpFailures = @()
}
$resetAfter = [pscustomobject]@{
    Timestamp = $fixtureStart.AddSeconds(19.0)
    Counters  = @{ 'TCPv4' = (New-CounterFixture 'TCPv4' $fixtureStart.AddSeconds(18.0) 120 2); 'TCPv6' = (New-CounterFixture 'TCPv6' $fixtureStart.AddSeconds(18.5) 1100 11) }
    Errors    = @()
    FailedAttempts = @([pscustomobject]@{ Protocol = 'TCPv4'; Phase = 'read'; Attempt = 1; Seconds = 8.0; Error = 'Timed out' })
    WarmUpFailures = @()
}
$script:TcpRows = New-Object System.Collections.ArrayList
Compare-TcpCounters -Before $resetBefore -After $resetAfter
$resetRow = @($script:TcpRows | Where-Object { $_.Check -eq 'TCPv4' })
Assert-Equal '#38 counter reset: the row still says the delta cannot be calculated' ("{0}/{1}" -f $resetRow.Count, $resetRow[0].Status) '1/ERROR'
Assert-Equal '#38 counter reset: it keeps the cumulative values it always printed' ($resetRow[0].Details -match '5000') True
Assert-Equal '#38 counter reset: and now carries the attempt that failed inside its window' ($resetRow[0].Details -match 'TCPv4 #1') True
# PR #40, round 7: the note the row borrows speaks of "these N seconds", so the row prints the window it spans - and
# it must not borrow the sentence about the deltas above, which a row reporting an uncalculable delta does not have.
Assert-Equal '#38 counter reset: the window it spans is printed, so the note has a referent' (([regex]::Matches($resetRow[0].Details, '(?<![\d.])18(?![\d.])')).Count) 2
Assert-Equal '#38 counter reset: and it claims nothing about deltas it does not have' ($resetRow[0].Details -match "deltas above|上面的增量") False
Assert-Equal '#38 window: a row that does have deltas still says they are its own' ($rowV6[0].Details -match "deltas above|上面的增量") True

# A baseline where both classes failed is returned rather than thrown away: Compare-TcpCounters writes one row per
# read that failed out of it, instead of the generic "no complete data" row with no evidence behind it.
$deadBaseline = [pscustomobject]@{
    Timestamp = $fixtureStart.AddSeconds(32.0)
    Counters  = @{}
    Errors    = @(
        [pscustomobject]@{ Protocol = 'TCPv4'; Error = 'Timed out'; Diagnostics = '' },
        [pscustomobject]@{ Protocol = 'TCPv6'; Error = 'Timed out'; Diagnostics = '' })
    FailedAttempts = @(
        [pscustomobject]@{ Protocol = 'TCPv4'; Phase = 'read'; Attempt = 1; Seconds = 8.0; Error = 'Timed out' },
        [pscustomobject]@{ Protocol = 'TCPv4'; Phase = 'read'; Attempt = 2; Seconds = 8.0; Error = 'Timed out' },
        [pscustomobject]@{ Protocol = 'TCPv6'; Phase = 'read'; Attempt = 1; Seconds = 8.0; Error = 'Timed out' },
        [pscustomobject]@{ Protocol = 'TCPv6'; Phase = 'read'; Attempt = 2; Seconds = 8.0; Error = 'Timed out' })
    WarmUpFailures = @([pscustomobject]@{ Protocol = 'TCPv4'; Phase = 'warm-up'; Attempt = 1; Seconds = 5.5; Error = 'Timed out' })
}
$script:TcpRows = New-Object System.Collections.ArrayList
Compare-TcpCounters -Before $deadBaseline -After $cleanAfter
Assert-Equal '#38 dead baseline: one row per read that failed, and no others' ("{0}/{1}" -f @($script:TcpRows).Count, @($script:TcpRows | Where-Object { $_.Status -eq 'ERROR' }).Count) '2/2'
Assert-Equal '#38 dead baseline: the first is about TCPv4' (@($script:TcpRows)[0].Check -like 'TCPv4*') True
Assert-Equal '#38 dead baseline: with its two attempts and its pre-window read' (([regex]::Matches(@($script:TcpRows)[0].Details, 'TCPv4 #')).Count) 3
Assert-Equal '#38 dead baseline: the second is about TCPv6, with its two' ("{0}/{1}" -f (@($script:TcpRows)[1].Check -like 'TCPv6*'), ([regex]::Matches(@($script:TcpRows)[1].Details, 'TCPv6 #')).Count) 'True/2'
# And the step that takes the baseline no longer throws it away: Invoke-CheckStep would have returned $null, taking
# every attempt with it. Read off the AST, because the run needs a machine whose counters both fail.
$warmCall = @($snapshotCalls | Where-Object { $_.Extent.Text -match '-WarmUp' })[0]
$enclosingBlock = $warmCall.Parent
while ($null -ne $enclosingBlock -and -not ($enclosingBlock -is [System.Management.Automation.Language.ScriptBlockExpressionAst])) { $enclosingBlock = $enclosingBlock.Parent }
Assert-Equal '#38 dead baseline: the baseline step has a script block to read' ($null -ne $enclosingBlock) True
Assert-Equal '#38 dead baseline: and it throws nothing away' (@($enclosingBlock.FindAll({ param($n) $n -is [System.Management.Automation.Language.ThrowStatementAst] }, $true)).Count) 0

# ---------------------------------------------------------------------------
# backlog #39: the overall result is decided by what the run measured. Two things are asserted here that the
# report-stage scenarios cannot see: which call sites declare the marking, and which functions read it.
# ---------------------------------------------------------------------------
# Can this value become a ping target at all - asked before anything is sent, because attempting a value that cannot
# be one turns a typo into a measurement: 'http://example.com' reports 100% loss, which reads as a network that
# dropped every packet.
Assert-Equal '#39 ping syntax: a literal address' (Test-PingTargetSyntax '1.1.1.1') True
Assert-Equal '#39 ping syntax: a host name' (Test-PingTargetSyntax 'www.example.com') True
Assert-Equal '#39 ping syntax: an IPv6 literal' (Test-PingTargetSyntax 'fe80::1') True
Assert-Equal '#39 ping syntax: the gateway placeholder' (Test-PingTargetSyntax 'AUTO_GATEWAY') True
Assert-Equal '#39 ping syntax: the DNS placeholder' (Test-PingTargetSyntax 'AUTO_DNS') True
Assert-Equal '#39 ping syntax: blank' (Test-PingTargetSyntax '') False
Assert-Equal '#39 ping syntax: whitespace only' (Test-PingTargetSyntax '   ') False
Assert-Equal '#39 ping syntax: a URL' (Test-PingTargetSyntax 'http://example.com') False
Assert-Equal '#39 ping syntax: a host and port' (Test-PingTargetSyntax '8.8.8.8:443') False
Assert-Equal '#39 ping syntax: an empty label (round 5)' (Test-PingTargetSyntax 'foo..bar') False
Assert-Equal '#39 ping syntax: nothing but a dot' (Test-PingTargetSyntax '.') False
Assert-Equal '#39 ping syntax: a trailing root dot is still a name' (Test-PingTargetSyntax 'www.example.com.') True
Assert-Equal '#39 ping syntax: a label starting with a hyphen' (Test-PingTargetSyntax '-foo.example.com') False
Assert-Equal '#39 ping syntax: a label ending with a hyphen' (Test-PingTargetSyntax 'foo-.example.com') False
Assert-Equal '#39 ping syntax: a label of 64 characters' (Test-PingTargetSyntax (('a' * 64) + '.example.com')) False
Assert-Equal '#39 ping syntax: a name of more than 253 characters' (Test-PingTargetSyntax ((('a' * 63 + '.') * 4) + 'abc')) False
Assert-Equal '#39 ping syntax: an internationalised name in its wire form stays usable' (Test-PingTargetSyntax 'xn--kpry57d.tw') True
Assert-Equal '#39 ping syntax: an underscore is left alone, because structure is what is tested' (Test-PingTargetSyntax 'my_host.example.com') True
# Round 6: the same rule, now a function of its own, because the DNS family needs it too.
Assert-Equal '#39 host syntax: a name' (Test-HostNameSyntax 'www.example.com') True
Assert-Equal '#39 host syntax: a single label' (Test-HostNameSyntax 'router') True
Assert-Equal '#39 host syntax: an IPv4 literal reads as labels' (Test-HostNameSyntax '8.8.8.8') True
Assert-Equal '#39 host syntax: an empty label' (Test-HostNameSyntax 'foo..bar') False
Assert-Equal '#39 host syntax: a leading dot' (Test-HostNameSyntax '.example.com') False
Assert-Equal '#39 host syntax: blank' (Test-HostNameSyntax '') False
Assert-Equal '#39 host syntax: a 64-character label' (Test-HostNameSyntax (('a' * 64) + '.example.com')) False
Assert-Equal '#39 host syntax: a hyphen at the edge' (Test-HostNameSyntax '-foo.example.com') False
# Round 7: the delimiters the ping family always refused, now refused for DNS names too.
Assert-Equal '#39 host syntax: a URL' (Test-HostNameSyntax 'http://example.com') False
Assert-Equal '#39 host syntax: a host and port' (Test-HostNameSyntax 'example.com:80') False
Assert-Equal '#39 host syntax: a user in the value' (Test-HostNameSyntax 'user@example.com') False
Assert-Equal '#39 host syntax: a space inside' (Test-HostNameSyntax 'foo bar') False
Assert-Equal '#39 host syntax: an IPv6 literal is not labels' (Test-HostNameSyntax 'fe80::1') True
# Round 9: the host inside a URL, which Uri.TryCreate does not judge.
Assert-Equal '#39 url syntax: an empty label in the host' (Test-HttpTargetSyntax 'http://foo..bar/') False
Assert-Equal '#39 url syntax: a hyphen at the edge of the host' (Test-HttpTargetSyntax 'https://-foo.example.com/x') False
Assert-Equal '#39 url syntax: a name with a path and a query' (Test-HttpTargetSyntax 'https://example.com/a/b?c=d') True
Assert-Equal '#39 url syntax: a port is not part of the host' (Test-HttpTargetSyntax 'https://example.com:8443/') True
Assert-Equal '#39 url syntax: an IPv6 literal in brackets' (Test-HttpTargetSyntax 'http://[fe80::1]/') True
Assert-Equal '#39 url syntax: a user in the URL is not part of the host' (Test-HttpTargetSyntax 'https://user@example.com/') True
# Round 10: the panel's pre-check and the run's rule are the same rule, so neither can refuse what the other takes.
Assert-Equal '#39 tcp syntax: a host and port' (Test-TcpTargetSyntax '8.8.8.8:443') True
Assert-Equal '#39 tcp syntax: a name and port' (Test-TcpTargetSyntax 'example.com:443') True
Assert-Equal '#39 tcp syntax: an empty label in the host' (Test-TcpTargetSyntax 'foo..bar:443') False
Assert-Equal '#39 tcp syntax: a hyphen at the edge of the host' (Test-TcpTargetSyntax '-foo.example.com:443') False
Assert-Equal '#39 tcp syntax: a blank host' (Test-TcpTargetSyntax ':443') False
Assert-Equal '#39 tcp syntax: a port out of range' (Test-TcpTargetSyntax 'example.com:70000') False
Assert-Equal '#39 ping syntax: two values in one' (Test-PingTargetSyntax '1.1.1.1 8.8.8.8') False
Assert-Equal '#39 ping syntax: a path' (Test-PingTargetSyntax 'example.com/health') False
# A name that is well formed and does not resolve is the opposite case: it is tested, the resolver answers, and that
# answer is a measurement this rule must not touch.
Assert-Equal '#39 ping syntax: a name that will not resolve is still a usable target' (Test-PingTargetSyntax 'nhc-no-such-host.invalid') True

# The same question for a URL, and the reason it has one place (PR #41, round 1): the configuration validation called
# 'example.com' unusable while the check intercepted only a blank, so the request went out, failed, and was recorded
# as a measured connectivity failure - a required target could produce Problem Detected over a value no packet ever
# left for, and a member of a required group could fail that group with it.
Assert-Equal '#39 url syntax: https' (Test-HttpTargetSyntax 'https://www.example.com/') True
Assert-Equal '#39 url syntax: http' (Test-HttpTargetSyntax 'http://10.0.0.1:8080/health') True
Assert-Equal '#39 url syntax: blank' (Test-HttpTargetSyntax '') False
Assert-Equal '#39 url syntax: no scheme' (Test-HttpTargetSyntax 'example.com') False
Assert-Equal '#39 url syntax: a scheme this tool does not speak' (Test-HttpTargetSyntax 'ftp://files.example.com/') False
Assert-Equal '#39 url syntax: a relative path' (Test-HttpTargetSyntax '/health') False
# And the check asks that helper rather than repeating the rule, so the two cannot drift apart again.
$httpCheck = $scriptAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-ConnectivityTargets' }, $true)
Assert-Equal '#39 url syntax: the check consults it' ($httpCheck.Extent.Text -match 'Test-HttpTargetSyntax') True
$configCheck = $scriptAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-ConfigurationSemantics' }, $true)
Assert-Equal '#39 url syntax: and so does the configuration validation' ($configCheck.Extent.Text -match 'Test-HttpTargetSyntax') True
Assert-Equal '#39 url syntax: neither keeps a rule of its own' ((($httpCheck.Extent.Text + $configCheck.Extent.Text) -match 'UriKind\]::Absolute')) False

# The step carries the weight, not the tag: the four quality collectors declare the marking at their call site and
# their step-error rows inherit it, while the two analysis steps beside them keep theirs. Read off the AST, because
# a run that proves it needs a machine whose counters and adapter statistics both fail.
$stepCalls = @($scriptAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Invoke-CheckStep' }, $true))
# The parameter, not the text: a step's extent includes its whole -Action block, and one of those blocks writes a
# row that carries the marking of its own, which made the first draft of this assertion count five steps.
function Get-StepParameter($Call, [string]$Name) {
    return @($Call.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq $Name })
}
function Get-StepProgress($Call) {
    $elements = @($Call.CommandElements)
    for ($i = 0; $i -lt $elements.Count - 1; $i++) {
        if ($elements[$i] -is [System.Management.Automation.Language.CommandParameterAst] -and $elements[$i].ParameterName -eq 'Progress') {
            return [int]$elements[$i + 1].Extent.Text
        }
    }
    return -1
}
$weightlessSteps = @($stepCalls | Where-Object { (Get-StepParameter $_ 'Weightless').Count -gt 0 })
# Five since 1.2.10, seven since 1.2.12. The fifth is the step that extends the TCP window (progress 90, backlog #51):
# it decides how to sample rather than what the network is like, and the analysis step below it writes the
# measurement either way - a step-error row from it must not make a run Test Incomplete. The sixth and seventh are the
# two Wi-Fi retry readings (9 and 91, backlog #61), collectors like the TCP ones.
Assert-Equal '#39 steps: seven of them declare the marking' $weightlessSteps.Count 7
Assert-Equal '#39 steps: and they are the collectors, by their progress points' ((@($weightlessSteps | ForEach-Object { Get-StepProgress $_ } | Sort-Object) -join ',')) '9,10,13,82,89,90,91'
Assert-Equal '#39 steps: the analysis steps beside them keep their weight' (@($stepCalls | Where-Object { (Get-StepProgress $_) -in @(85, 92, 93) -and (Get-StepParameter $_ 'Weightless').Count -gt 0 }).Count) 0

# The dropped-target rows must exist in every report this tool writes, including the two that end early - the
# unsupported operating system and the unsupported PowerShell - because a notice about a target with no row where
# its result belonged is exactly the absence backlog #39 set out to remove. Read off the AST by position, because
# proving it by running needs a machine this tool refuses to run on (PR #41, round 12).
$mainBody = $scriptAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Run-AllChecks' }, $true)
$droppedCall = $mainBody.Find({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Add-DroppedTargetResults' }, $true)
$platformCall = $mainBody.Find({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Test-IsWindowsPlatform' }, $true)
Assert-Equal '#39 dropped rows: the run writes them' ($null -ne $droppedCall) True
Assert-Equal '#39 dropped rows: and before the branch that can return early' ($droppedCall.Extent.StartOffset -lt $platformCall.Extent.StartOffset) True
Assert-Equal '#39 dropped rows: exactly once' (@($mainBody.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Add-DroppedTargetResults' }, $true)).Count) 1
# And not inside a step's action, where a throw in the step would take the row with it.
Assert-Equal '#39 dropped rows: not inside a check step' (@($stepCalls | Where-Object { $_.Extent.Text -match 'Add-DroppedTargetResults' }).Count) 0

# Test-HostNameSyntax trims before it judges, so ' example.com ' is a usable name - and until PR #41 round 13 the
# checks then handed the untrimmed value to Ping.Send, GetHostAddressesAsync and TcpClient.BeginConnect, which
# reject it. The rule and the run have to see the same string, or the classification this release is about is
# decided on one value and carried out on another. The HTTP family needs nothing: Uri.TryCreate and
# HttpWebRequest.Create both trim, so its two sides already agree.
$scriptText = $scriptAst.Extent.Text
$hostReads = @([regex]::Matches($scriptText, 'ConvertTo-SafeString \(Get-PropertyValue \$\w+ "(?:Host|Address)" ""\)'))
$trimmedReads = @([regex]::Matches($scriptText, '\(ConvertTo-SafeString \(Get-PropertyValue \$\w+ "(?:Host|Address)" ""\)\)\.Trim\(\)'))
# Seven, not six: the count is asserted so that a new read site has to be looked at rather than quietly joining
# the untrimmed ones - which is how the traceroute target was found, a site the review did not name. Nine since
# 1.2.12: the near-end target's address is read in the configuration check and again where the probes are sent
# (backlog #60), both trimmed, and both looked at here on the way in.
Assert-Equal '#39 host values: the script reads nine of them' $hostReads.Count 9
Assert-Equal '#39 host values: and every one is trimmed' $trimmedReads.Count $hostReads.Count
Assert-Equal '#39 host values: the bare-string DNS form too' (@([regex]::Matches($scriptText, '\$hostName = \(\[string\]\$dns\w+\)\.Trim\(\)')).Count) 2
Assert-Equal '#39 host values: and none of it is read raw' ($scriptText -match '\$hostName = \[string\]\$dns') False
Assert-Equal '#39 host values: a padded name is usable, which is why the run must trim it' (Test-HostNameSyntax ' example.com ') True

# Round 18: 63 is a limit on the encoded label, not on the characters typed. Written as code points so that the
# assertion cannot be changed by how this file is saved or read - the same mistake made the first probe of this
# say a perfectly good Chinese name was invalid.
$twName = [string][char]0x53F0 + [string][char]0x7063 + '.tw'
$umlautName = [string][char]0x00FC + 'ber.example.com'
$longIdn = (([string][char]0x00E9) * 58) + '.tw'
Assert-Equal '#39 idn: a Chinese name is usable' (Test-HostNameSyntax $twName) True
Assert-Equal '#39 idn: so is a label with an umlaut' (Test-HostNameSyntax $umlautName) True
Assert-Equal '#39 idn: 58 accented letters fit here and not on the wire' (Test-HostNameSyntax $longIdn) False
Assert-Equal '#39 idn: and its label really is 58 characters' (($longIdn -split '\.')[0].Length) 58
# Round 19: the separators IDNA turns into an ASCII dot. A name written with one of these carries no ASCII dot on
# the way in and a trailing one on the way out, which is why the root dot is taken off after the conversion.
$twBase = [string][char]0x53F0 + [string][char]0x7063
Assert-Equal '#39 idn: an ideographic full stop as the root dot' (Test-HostNameSyntax ($twBase + [string][char]0x3002)) True
Assert-Equal '#39 idn: a fullwidth full stop' (Test-HostNameSyntax ($twBase + [string][char]0xFF0E)) True
Assert-Equal '#39 idn: a halfwidth ideographic full stop' (Test-HostNameSyntax ($twBase + [string][char]0xFF61)) True
Assert-Equal '#39 idn: and one used as a separator, not as the root' (Test-HostNameSyntax ($twBase + [string][char]0x3002 + 'tw')) True
Assert-Equal '#39 idn: a separator on its own is still nothing' (Test-HostNameSyntax ([string][char]0x3002)) False
# Round 20: the compatibility characters IDNA turns into delimiters. Each of these passes the delimiter rules as
# typed and fails them as sent, which is why the conversion runs before them.
Assert-Equal '#39 idn: a fullwidth solidus becomes a path separator' (Test-HostNameSyntax ('foo' + [string][char]0xFF0F + 'bar')) False
Assert-Equal '#39 idn: a fullwidth colon becomes a port separator' (Test-HostNameSyntax ('foo' + [string][char]0xFF1A + '80')) False
Assert-Equal '#39 idn: an ideographic space becomes a space' (Test-HostNameSyntax ('foo' + [string][char]0x3000 + 'bar')) False
Assert-Equal '#39 idn: a fullwidth at sign becomes a user separator' (Test-HostNameSyntax ('user' + [string][char]0xFF20 + 'example.com')) False
Assert-Equal '#39 idn: a fullwidth question mark becomes a query separator' (Test-HostNameSyntax ('foo' + [string][char]0xFF1F + 'bar')) False
# Round 21: control characters, which are neither delimiters nor whitespace. A JSON \u0000 reached Dns.Send and
# came back as a SocketException - the same exception an unresolvable name gives, so it was measured, not reported.
Assert-Equal '#39 controls: an embedded NUL' (Test-HostNameSyntax ('foo' + [string][char]0 + 'bar')) False
Assert-Equal '#39 controls: a start-of-heading' (Test-HostNameSyntax ('foo' + [string][char]1 + 'bar')) False
Assert-Equal '#39 controls: a delete' (Test-HostNameSyntax ('foo' + [string][char]0x7F + 'bar')) False
Assert-Equal '#39 controls: a tab, which the whitespace rule already refused' (Test-HostNameSyntax ('foo' + [string][char]9 + 'bar')) False

# What concludes follows the weights; what describes the page follows the rows on the page. Round 8 of PR #37 found
# the first draft of that sentence saying "every predicate that reads the result set", which would have taken the
# Unable flag with it - the flag whose only job is to explain a badge the weightless row still carries.
function Get-FunctionBody([string]$Name) {
    $fn = $scriptAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true)
    if ($null -eq $fn) { return "" }
    return $fn.Extent.Text
}
Assert-Equal '#39 verdict: Get-OverallStatus reads the weighted rows' ((Get-FunctionBody 'Get-OverallStatus') -match '-not \$_\.Weightless') True
Assert-Equal '#39 fingerprint: its predicates read the weighted rows' ((Get-FunctionBody 'Get-FingerprintSummary') -match '-not \$_\.Weightless') True
Assert-Equal '#39 counts: Get-SummaryCounts describes the page and reads every row' ((Get-FunctionBody 'Get-SummaryCounts') -match 'Weightless') False
Assert-Equal '#39 notice: Get-ReportNoticeFlags does too, so a badge keeps its explanation' ((Get-FunctionBody 'Get-ReportNoticeFlags') -match 'Weightless') False
# The marking is opt-in, and that is a property of Add-CheckResult itself: a switch, defaulting to unmarked.
Assert-Equal '#39 marking: the row carries the field' ((Get-FunctionBody 'Add-CheckResult') -match 'Weightless  = \[bool\]\$Weightless') True
Assert-Equal '#39 marking: and it is a switch, so a row is weighted unless it is named' ((Get-FunctionBody 'Add-CheckResult') -match '\[switch\]\$Weightless') True


# backlog #59: the route selection a ping row names. The stub stands where Find-NetRoute stands, so what runs above
# it is the shipped selector and the shipped formatter. Every assertion here is language-independent by design - the
# selector returns data rather than sentences, and the formatter is checked on the values it interpolates and on the
# shape it produces, which is the same rule the error-cause cases above follow.
$script:RoutePlan = @()
$script:RouteCalls = 0
function Find-NetRoute {
    [CmdletBinding()]
    param([string]$RemoteIPAddress)
    $index = $script:RouteCalls
    $script:RouteCalls++
    $outcome = ''
    if ($index -lt $script:RoutePlan.Count) { $outcome = [string]$script:RoutePlan[$index] }
    if ($outcome -eq 'throw') { throw "route lookup failed" }
    # The cmdlet reports both 'no route' and 'that is not an address' as NON-terminating errors, so the stub emits
    # them the way it does - a Write-Error whose id the selector reads. Measured ids, 2026-09-11: 1231 for an
    # unroutable address, 87 for a name. 'none' is the fourth way out: nothing back and nothing said.
    if ($outcome -eq 'err1231') { Write-Error -Message 'The network location cannot be reached.' -ErrorId 'Windows System Error 1231'; return @() }
    if ($outcome -eq 'err87') { Write-Error -Message 'The parameter is incorrect.' -ErrorId 'Windows System Error 87'; return @() }
    if ($outcome -eq 'errother') { Write-Error -Message 'The CIM provider fell over.' -ErrorId 'Windows System Error 1722'; return @() }
    if ($outcome -eq 'none') { return @() }
    # Two objects come back and only one of them carries an address. The order here is deliberately the OPPOSITE of
    # the reference machine's, so a selector that trusted the first object instead of the one with an IPAddress
    # fails this case rather than passing it by luck.
    $parts = $outcome.Split('|')
    # A third part, 'onlink', models the connected route - next hop 0.0.0.0 - which is what lets a rung be claimed
    # (PR #51, round 5); without it the stub is the default route through a router, as on the reference machine.
    $onLink = ($parts.Count -gt 2 -and $parts[2] -eq 'onlink')
    return @(
        [pscustomobject]@{ IPAddress = ''; InterfaceAlias = $parts[1]; NextHop = $(if ($onLink) { '0.0.0.0' } else { '192.168.1.1' }); DestinationPrefix = $(if ($onLink) { '192.168.1.0/24' } else { '0.0.0.0/0' }) },
        [pscustomobject]@{ IPAddress = $parts[0]; InterfaceAlias = $parts[1] }
    )
}
function Reset-RouteStub($plan) { $script:RoutePlan = @($plan); $script:RouteCalls = 0 }

Reset-RouteStub @('192.168.1.106|Wi-Fi')
$routeResolved = Get-RouteSelection -Target '1.1.1.1'
Assert-Equal 'route #59: resolved' $routeResolved.Resolved True
Assert-Equal 'route #59: source is read from the object that has one, not the first' $routeResolved.SourceAddress '192.168.1.106'
Assert-Equal 'route #59: interface' $routeResolved.InterfaceAlias 'Wi-Fi'
Assert-Equal 'route #59: resolved carries no reason' $routeResolved.Reason ''
Assert-Equal 'route #60: the next hop is kept' $routeResolved.NextHop '192.168.1.1'
Assert-Equal 'route #60: a route through a router is not on-link' $routeResolved.OnLink False
Reset-RouteStub @('192.168.1.106|Wi-Fi|onlink')
$routeOnLink = Get-RouteSelection -Target '192.168.1.20'
Assert-Equal 'route #60: a connected route is on-link' $routeOnLink.OnLink True
Assert-Equal 'route #60: and its next hop is the unspecified address' $routeOnLink.NextHop '0.0.0.0'

Reset-RouteStub @('none')
$routeNone = Get-RouteSelection -Target '169.254.99.99'
Assert-Equal 'route #59: no route -> unresolved' $routeNone.Resolved False
Assert-Equal 'route #59: no route -> reason' $routeNone.Reason 'noroute'
Assert-Equal 'route #59: no route -> no source' $routeNone.SourceAddress ''

Reset-RouteStub @('throw')
$routeError = Get-RouteSelection -Target '1.1.1.1'
Assert-Equal 'route #59: lookup throws -> unresolved, not a failed row' $routeError.Resolved False
Assert-Equal 'route #59: lookup throws -> reason' $routeError.Reason 'error'

# The fourth shape: the cmdlet is absent. Get-Command is what the selector asks, so that is what is stubbed - and it
# is removed immediately afterwards, because two other loaded helpers ask Get-Command for their own names.
function Get-Command {
    [CmdletBinding()]
    param([Parameter(Position = 0)][string]$Name)
    if ($Name -eq 'Find-NetRoute') { return $null }
    return [pscustomobject]@{ Name = $Name }
}
$routeAbsent = Get-RouteSelection -Target '1.1.1.1'
Remove-Item function:Get-Command -ErrorAction SilentlyContinue
Assert-Equal 'route #59: cmdlet absent -> unresolved' $routeAbsent.Resolved False
Assert-Equal 'route #59: cmdlet absent -> reason' $routeAbsent.Reason 'cmdlet'
Assert-Equal 'route #59: Get-Command stub removed' ([bool](Get-Command Get-RouteSelection -ErrorAction SilentlyContinue)) True

# The formatter. Values first, because they are the same in both languages.
$selA = [pscustomobject]@{ Resolved = $true; Reason = ''; SourceAddress = '192.168.1.106'; InterfaceAlias = 'Wi-Fi' }
$selB = [pscustomobject]@{ Resolved = $true; Reason = ''; SourceAddress = '10.0.0.5'; InterfaceAlias = 'Ethernet' }
$selNone = [pscustomobject]@{ Resolved = $false; Reason = 'noroute'; SourceAddress = ''; InterfaceAlias = '' }
$selCmdlet = [pscustomobject]@{ Resolved = $false; Reason = 'cmdlet'; SourceAddress = ''; InterfaceAlias = '' }
$selErr = [pscustomobject]@{ Resolved = $false; Reason = 'error'; SourceAddress = ''; InterfaceAlias = '' }

$sameText = Format-RouteSelection -Before $selA -After $selA
Assert-Equal 'route #59: unchanged names the source' ($sameText -match '192\.168\.1\.106') True
Assert-Equal 'route #59: unchanged names the interface' ($sameText -match 'Wi-Fi') True
Assert-Equal 'route #59: unchanged does not name a second interface' ($sameText -match 'Ethernet') False

$changedText = Format-RouteSelection -Before $selA -After $selB
Assert-Equal 'route #59: changed names the address before' ($changedText -match '192\.168\.1\.106') True
Assert-Equal 'route #59: changed names the address after' ($changedText -match '10\.0\.0\.5') True
Assert-Equal 'route #59: changed names both interfaces' (($changedText -match 'Wi-Fi') -and ($changedText -match 'Ethernet')) True
Assert-Equal 'route #59: changed is not the unchanged sentence' ($changedText -eq $sameText) False

# A disagreement includes one side resolving where the other did not: that is still a change of which adapter was in
# play, and the row has to say so rather than picking one of the two readings.
$halfText = Format-RouteSelection -Before $selA -After $selNone
$noneText = Format-RouteSelection -Before $selNone -After $selNone
Assert-Equal 'route #59: resolved then unresolved is reported as a change' ($halfText -eq $noneText) False
Assert-Equal 'route #59: resolved then unresolved still names the address it did get' ($halfText -match '192\.168\.1\.106') True
# The rule this pins is the one #59's acceptance states and the code invents the shape for: a disagreement includes
# one side resolving where the other did not, so the sentence has to carry BOTH readings rather than the first.
Assert-Equal 'route #59: resolved then unresolved names both readings' (($halfText -match '192\.168\.1\.106') -and ($halfText.Contains((Get-RouteSelectionText $selNone)))) True
Assert-Equal 'route #59: two identical failures are one sentence, not a change' ($noneText -match '192\.168\.1\.106') False

# Each unavailable reason says which one it is, and the cmdlet case names the cmdlet in both languages because the
# name is not translated.
Assert-Equal 'route #59: cmdlet-absent text names Find-NetRoute' ((Format-RouteSelection -Before $selCmdlet -After $selCmdlet) -match 'Find-NetRoute') True
$reasonTexts = @((Get-RouteSelectionText $selNone), (Get-RouteSelectionText $selCmdlet), (Get-RouteSelectionText $selErr), (Get-RouteSelectionText $null))
Assert-Equal 'route #59: four unavailable reasons, four distinct sentences' (@($reasonTexts | Select-Object -Unique).Count) 4
Assert-Equal 'route #59: a resolved side is not an unavailable sentence' ((Get-RouteSelectionText $selA) -eq (Get-RouteSelectionText $selNone)) False


# PR #45 round 1: an empty result is four different outcomes, and calling them all 'no route' publishes a sentence
# that is false three times out of four. The id is the discriminator because the message follows the locale, which
# is backlog #27's rule applied where it applies again.
Reset-RouteStub @('err1231')
Assert-Equal 'route #59: error 1231 is no route' (Get-RouteSelection -Target '169.254.99.99').Reason 'noroute'
Reset-RouteStub @('err87')
Assert-Equal 'route #59: error 87 is not-an-address, not no-route' (Get-RouteSelection -Target 'a-name').Reason 'notaddress'
Reset-RouteStub @('errother')
Assert-Equal 'route #59: any other error id is a failed lookup' (Get-RouteSelection -Target '1.1.1.1').Reason 'error'
Reset-RouteStub @('none')
Assert-Equal 'route #59: nothing back and nothing said stays no route' (Get-RouteSelection -Target '1.1.1.1').Reason 'noroute'

# A target given as a name: no address exists to ask about until something replies, so there is no pair. $null on the
# before side is what says that, and the sentence has to name the address that WAS looked up.
$selName = [pscustomobject]@{ Resolved = $true; Reason = ''; SourceAddress = '192.168.1.106'; InterfaceAlias = 'Wi-Fi' }
$nameText = Format-RouteSelection -Before $null -After $selName -LookupAddress '93.184.216.34'
Assert-Equal 'route #59: a name target names the address that was looked up' ($nameText -match '93\.184\.216\.34') True
Assert-Equal 'route #59: a name target still names the interface' ($nameText -match 'Wi-Fi') True
Assert-Equal 'route #59: a name target is not the ordinary two-lookup sentence' ($nameText -eq (Format-RouteSelection -Before $selName -After $selName)) False

$selNoReply = [pscustomobject]@{ Resolved = $false; Reason = 'noreply'; SourceAddress = ''; InterfaceAlias = '' }
$noReplyText = Format-RouteSelection -Before $null -After $selNoReply -LookupAddress ''
Assert-Equal 'route #59: a name that never answered names no address' ($noReplyText -match '\d+\.\d+\.\d+\.\d+') False
$selNotAddress = [pscustomobject]@{ Resolved = $false; Reason = 'notaddress'; SourceAddress = ''; InterfaceAlias = '' }
$reasonTexts2 = @((Get-RouteSelectionText $selNoReply), (Get-RouteSelectionText $selNotAddress), (Get-RouteSelectionText $selNone), (Get-RouteSelectionText $selCmdlet), (Get-RouteSelectionText $selErr), (Get-RouteSelectionText $null))
Assert-Equal 'route #59: six unavailable reasons, six distinct sentences' (@($reasonTexts2 | Select-Object -Unique).Count) 6


# PR #45 round 2: the Method line described the address case's lookup even for a name, so a correct route sentence
# was followed by a contradictory account of how it was obtained. Language-independent assertions again: which
# address the text names, and which it does not.
$methodAddress = Get-RouteMethodText -Target '1.1.1.1' -LookupAddress '1.1.1.1' -TargetIsAddress $true
$methodName = Get-RouteMethodText -Target 'www.example.com' -LookupAddress '93.184.216.34' -TargetIsAddress $false
$methodNoReply = Get-RouteMethodText -Target 'www.example.com' -LookupAddress '' -TargetIsAddress $false
Assert-Equal 'route #59: method line for an address names the target' ($methodAddress -match '1\.1\.1\.1') True
Assert-Equal 'route #59: method line for a name names the address, not the name' (($methodName -match '93\.184\.216\.34') -and -not ($methodName -match 'www\.example\.com')) True
Assert-Equal 'route #59: method line for a name is not the address one' ($methodName -eq $methodAddress) False
Assert-Equal 'route #59: nothing replied, so no lookup is claimed' ($methodNoReply -match 'Find-NetRoute') False
Assert-Equal 'route #59: nothing replied, so no address is named' ($methodNoReply -match '\d+\.\d+\.\d+\.\d+') False


# PR #45 round 3: .NET resolves a name per send, so a name behind round-robin DNS can answer from more than one
# address and the row may not name the first as if it were all of them. Not reproducible on this machine - eight
# sends to www.microsoft.com and six to outlook.office365.com each answered from one address, the resolver cache
# holding it for its TTL - so the shapes are pinned here instead.
$selEth = [pscustomobject]@{ Resolved = $true; Reason = ''; SourceAddress = '10.0.0.5'; InterfaceAlias = 'Ethernet' }
$othersAgree = @([pscustomobject]@{ Address = '23.39.61.99'; Selection = $selName })
$othersDiffer = @([pscustomobject]@{ Address = '23.39.61.99'; Selection = $selEth })
$oneText = Format-RouteSelection -Before $null -After $selName -LookupAddress '93.184.216.34'
$agreeText = Format-RouteSelection -Before $null -After $selName -LookupAddress '93.184.216.34' -Others $othersAgree
$differText = Format-RouteSelection -Before $null -After $selName -LookupAddress '93.184.216.34' -Others $othersDiffer
Assert-Equal 'route #59: two addresses that agree say so' ($agreeText -eq $oneText) False
Assert-Equal 'route #59: two addresses that agree still name the one looked up first' ($agreeText -match '93\.184\.216\.34') True
Assert-Equal 'route #59: two addresses that disagree name both' (($differText -match '93\.184\.216\.34') -and ($differText -match '23\.39\.61\.99')) True
Assert-Equal 'route #59: two addresses that disagree name both interfaces' (($differText -match 'Wi-Fi') -and ($differText -match 'Ethernet')) True
Assert-Equal 'route #59: disagreeing is not the agreeing sentence' ($differText -eq $agreeText) False
Assert-Equal 'route #59: method line for several addresses names none of them' ((Get-RouteMethodText -Target 'a-name' -LookupAddress '93.184.216.34' -TargetIsAddress $false -ExtraCount 1) -match '93\.184\.216\.34') False
Assert-Equal 'route #59: method line for several addresses counts them' ((Get-RouteMethodText -Target 'a-name' -LookupAddress '93.184.216.34' -TargetIsAddress $false -ExtraCount 1) -match '2') True


# PR #45 round 4: the earlier shape returned on an unresolved first address and never read the others, hiding a
# usable adapter behind one failed lookup while the Method line claimed every address had been read.
$othersUsable = @([pscustomobject]@{ Address = '23.39.61.99'; Selection = $selEth })
$primaryDeadText = Format-RouteSelection -Before $null -After $selNone -LookupAddress '93.184.216.34' -Others $othersUsable
Assert-Equal 'route #59: an unresolved first address no longer hides the others' ($primaryDeadText -match '23\.39\.61\.99') True
Assert-Equal 'route #59: and it names the adapter that other address selects' ($primaryDeadText -match 'Ethernet') True
$othersAllDead = @([pscustomobject]@{ Address = '23.39.61.99'; Selection = $selNone })
$allDeadText = Format-RouteSelection -Before $null -After $selNone -LookupAddress '93.184.216.34' -Others $othersAllDead
Assert-Equal 'route #59: several addresses that all fail the same way say so once' ($allDeadText -match '23\.39\.61\.99') False
Assert-Equal 'route #59: and they are not the single-address sentence' ($allDeadText -eq (Format-RouteSelection -Before $null -After $selNone -LookupAddress '93.184.216.34')) False


# PR #45 round 5: a lookup that did not answer is not the route table deciding differently. Only where every address
# answered can the difference between them be called a routing difference.
$othersMixed = @([pscustomobject]@{ Address = '23.39.61.99'; Selection = $selErr })
$mixedText = Format-RouteSelection -Before $null -After $selName -LookupAddress '93.184.216.34' -Others $othersMixed
Assert-Equal 'route #59: a failed lookup beside a good one is not a routing difference' ($mixedText -eq $differText) False
Assert-Equal 'route #59: the mixed case still names both addresses' (($mixedText -match '93\.184\.216\.34') -and ($mixedText -match '23\.39\.61\.99')) True
Assert-Equal 'route #59: the mixed case still refuses to attribute the measurement' ($mixedText.Length -gt 40) True
Assert-Equal 'route #59: two resolved selections that differ are still a routing difference' ($differText -eq (Format-RouteSelection -Before $null -After $selName -LookupAddress '93.184.216.34' -Others $othersDiffer)) True


# PR #45 round 6: the question this row answers is WHICH ADAPTER, so that is what the comparison is on. Two addresses
# can select one interface from two source addresses - an IPv4 and an IPv6 reply over one adapter is the ordinary way
# it happens - and that is not an adapter the row cannot identify.
$selSameAliasOtherSource = [pscustomobject]@{ Resolved = $true; Reason = ''; SourceAddress = 'fe80::1'; InterfaceAlias = 'Wi-Fi' }
$othersSameAlias = @([pscustomobject]@{ Address = '2606:2800::1'; Selection = $selSameAliasOtherSource })
$sameAliasText = Format-RouteSelection -Before $null -After $selName -LookupAddress '93.184.216.34' -Others $othersSameAlias
Assert-Equal 'route #59: one interface from two sources is not adapter ambiguity' ($sameAliasText -eq (Format-RouteSelection -Before $null -After $selName -LookupAddress '93.184.216.34' -Others $othersDiffer)) False
# Round 6: the next hop is part of the reading and of the two-lookup comparison - and only of those: a name's several
# addresses are still asked WHICH ADAPTER, so a hop that differs between them is not a routing difference.
$selOnLink = [pscustomobject]@{ Resolved = $true; Reason = ''; SourceAddress = '192.168.1.106'; InterfaceAlias = 'Wi-Fi'; NextHop = '0.0.0.0'; OnLink = $true }
$selViaRouter = [pscustomobject]@{ Resolved = $true; Reason = ''; SourceAddress = '192.168.1.106'; InterfaceAlias = 'Wi-Fi'; NextHop = '192.168.1.1'; OnLink = $false }
$onLinkText = Get-RouteSelectionText $selOnLink
$viaRouterText = Get-RouteSelectionText $selViaRouter
Assert-Equal 'route #60: a route through a router names its next hop' ($viaRouterText -match '192\.168\.1\.1$') True
Assert-Equal 'route #60: an on-link route names none, and reads differently' (($onLinkText -match '192\.168\.1\.1$') -or ($onLinkText -eq $viaRouterText)) False
Assert-Equal 'route #60: both read differently from a selection that carries no hop' (($onLinkText -eq (Get-RouteSelectionText $selA)) -or ($viaRouterText -eq (Get-RouteSelectionText $selA))) False
Assert-Equal 'route #60: without the hop, both read as the adapter alone' (((Get-RouteSelectionText $selOnLink -NoHop) -eq (Get-RouteSelectionText $selA)) -and ((Get-RouteSelectionText $selViaRouter -NoHop) -eq (Get-RouteSelectionText $selA))) True
$onLinkSameText = Format-RouteSelection -Before $selOnLink -After $selOnLink
$hopChangedText = Format-RouteSelection -Before $selOnLink -After $selViaRouter
Assert-Equal 'route #60: an unchanged on-link pair reads as one selection' ($onLinkSameText.Contains($onLinkText) -and -not $onLinkSameText.Contains($viaRouterText)) True
Assert-Equal 'route #60: a next hop that changed between the lookups is a changed selection, with both hops named' ($hopChangedText.Contains($onLinkText) -and $hopChangedText.Contains($viaRouterText) -and ($hopChangedText -ne $onLinkSameText)) True
$othersHopDiffers = @([pscustomobject]@{ Address = '23.39.61.99'; Selection = $selViaRouter })
$othersHopSame = @([pscustomobject]@{ Address = '23.39.61.99'; Selection = $selOnLink })
$twoHopsText = Format-RouteSelection -Before $null -After $selOnLink -LookupAddress '93.184.216.34' -Others $othersHopDiffers
Assert-Equal 'route #60: two addresses of a name through one adapter by different hops still agree on the adapter' ($twoHopsText -eq (Format-RouteSelection -Before $null -After $selOnLink -LookupAddress '93.184.216.34' -Others $othersHopSame)) True
Assert-Equal 'route #60: and are not reported as a routing difference' ($twoHopsText -eq (Format-RouteSelection -Before $null -After $selOnLink -LookupAddress '93.184.216.34' -Others $othersDiffer)) False
Assert-Equal 'route #59: it names the one interface they share' ($sameAliasText -match 'Wi-Fi') True
Assert-Equal 'route #59: it still names both source addresses' (($sameAliasText -match 'fe80::1') -and ($sameAliasText -match '192\.168\.1\.106')) True
Assert-Equal 'route #59: two interfaces are still adapter ambiguity' ($differText -match 'Ethernet') True


# ---------------------------------------------------------------------------
# backlog #51: a quality verdict may not rest on a single packet, and a sample
# that is too coarse for its threshold is continued rather than convicted on.
# backlog #63: the retransmission count qualifies the rate and may not act alone.
# ---------------------------------------------------------------------------

# The arithmetic the whole item turns on, and the off-by-one-factor its own first draft got wrong: twenty pings is
# exactly 5 % for one lost reply, twenty-one is 4.8 %. The same slip put MinimumTcpSegmentsForRate at 100/2 = 50,
# where one retransmission IS the 2 % warning threshold.
Assert-Equal '#51 count: 5% warning needs 21 pings' (Get-PingCountForThreshold 5) 21
Assert-Equal '#51 count: 20 is exactly the threshold, so it is not enough' ((Get-LossBand 20 1 5 20)) 'warning'
Assert-Equal '#51 count: 21 is' ((Get-LossBand 21 1 5 20)) 'pass'
# 51 is what the exact arithmetic gives and it is not enough: 100/51 is 1.9607 %, which prints as 2.0 and still
# warns. The count is the smallest one whose PRINTED figure is below the threshold (PR #49, round 1).
Assert-Equal '#51 count: 2% would need 52, not the 51 the exact arithmetic gives' (Get-PingCountForThreshold 2) 52
Assert-Equal '#51 count: because 51 prints as the threshold itself' ((Get-LossBand 51 1 2 5)) 'warning'
Assert-Equal '#51 count: and 52 prints below it' ((Get-LossBand 52 1 2 5)) 'pass'
Assert-Equal '#51 count: a decimal threshold of 4.8% needs 22' (Get-PingCountForThreshold 4.8) 22
Assert-Equal '#51 count: because one of twenty-one prints as 4.8 and still warns' ((Get-LossBand 21 1 4.8 20)) 'warning'
Assert-Equal '#51 count: so twenty-one is coarse at 4.8%, where the exact arithmetic called it enough' ((Get-PingLossClassification -Sent 21 -Lost 1 -WarningPercent 4.8 -CriticalPercent 20).Coarse) True
Assert-Equal '#51 count: and that one packet carries no verdict' ((Get-PingLossClassification -Sent 21 -Lost 1 -WarningPercent 4.8 -CriticalPercent 20).Weightless) True
Assert-Equal '#51 count: 20% needs 6' (Get-PingCountForThreshold 20) 6
Assert-Equal '#51 count: a threshold of zero has no such count' (Get-PingCountForThreshold 0) 0
Assert-Equal '#51 count: nor has a negative one' (Get-PingCountForThreshold -3) 0
$tinyCount = Get-PingCountForThreshold 0.0000001
Assert-Equal '#51 count: a tiny threshold does not overflow the return' (($tinyCount -gt 0) -and ($tinyCount -le [int]::MaxValue)) True
Assert-Equal '#51 count: and the count it gives really is below it' ((Get-LossBand $tinyCount 1 0.0000001 100)) 'pass'

# The band is read off the figure the row prints, rounded to one decimal.
Assert-Equal '#51 band: 1 of 4 is 25%, critical' ((Get-LossBand 4 1 5 20)) 'critical'
Assert-Equal '#51 band: 0 of 4 is a pass' ((Get-LossBand 4 0 5 20)) 'pass'
Assert-Equal '#51 band: 2 of 21 is 9.5%, a warning' ((Get-LossBand 21 2 5 20)) 'warning'
Assert-Equal '#51 band: nothing sent is a pass rather than a divide' ((Get-LossBand 0 0 5 20)) 'pass'

# The rule itself: a coarse sample AND a verdict made of one packet. Either alone leaves the verdict standing.
$lossFour = Get-PingLossClassification -Sent 4 -Lost 1 -WarningPercent 5 -CriticalPercent 20
Assert-Equal '#51 loss: one of four reaches the critical band' $lossFour.Band 'critical'
Assert-Equal '#51 loss: four probes is coarse for a 5% threshold' $lossFour.Coarse True
Assert-Equal '#51 loss: and the band turns on that one reply' $lossFour.OnePacket True
Assert-Equal '#51 loss: so the verdict is withheld' $lossFour.Weightless True
Assert-Equal '#51 loss: the row can say what it would have taken' $lossFour.RequiredCount 21

$lossTwentyOne = Get-PingLossClassification -Sent 21 -Lost 1 -WarningPercent 5 -CriticalPercent 20
Assert-Equal '#51 loss: one of twenty-one is a pass' $lossTwentyOne.Band 'pass'
Assert-Equal '#51 loss: twenty-one is not coarse for this threshold' $lossTwentyOne.Coarse False
Assert-Equal '#51 loss: and nothing is withheld from a pass' $lossTwentyOne.Weightless False

$lossTwoOfTwentyOne = Get-PingLossClassification -Sent 21 -Lost 2 -WarningPercent 5 -CriticalPercent 20
Assert-Equal '#51 loss: two of twenty-one is a warning' $lossTwoOfTwentyOne.Band 'warning'
Assert-Equal '#51 loss: it does turn on one packet' $lossTwoOfTwentyOne.OnePacket True
Assert-Equal '#51 loss: but the sample fits the threshold, so it keeps its verdict' $lossTwoOfTwentyOne.Weightless False

$lossThreeOfFour = Get-PingLossClassification -Sent 4 -Lost 3 -WarningPercent 5 -CriticalPercent 20
Assert-Equal '#51 loss: three of four is critical' $lossThreeOfFour.Band 'critical'
Assert-Equal '#51 loss: the sample is coarse' $lossThreeOfFour.Coarse True
Assert-Equal '#51 loss: but 50% is still critical, so it does not rest on one packet' $lossThreeOfFour.OnePacket False
Assert-Equal '#51 loss: and the verdict stands' $lossThreeOfFour.Weightless False

$lossOneOfSix = Get-PingLossClassification -Sent 6 -Lost 1 -WarningPercent 5 -CriticalPercent 20
Assert-Equal '#51 loss: one of six is a warning rather than critical' $lossOneOfSix.Band 'warning'
Assert-Equal '#51 loss: and it is still one packet on a coarse sample' $lossOneOfSix.Weightless True
Assert-Equal '#51 loss: no loss at all withholds nothing' ((Get-PingLossClassification -Sent 4 -Lost 0 -WarningPercent 5 -CriticalPercent 20).Weightless) False
Assert-Equal '#51 loss: a warning threshold of zero leaves every sample coarse' ((Get-PingLossClassification -Sent 4 -Lost 1 -WarningPercent 0 -CriticalPercent 20).Coarse) True

# The extension fires in the ambiguous case and only there.
$planComplete = Get-PingExtensionPlan -Sent 4 -Received 4 -MaximumCount 21 -WarningPercent 5
Assert-Equal '#51 plan: every reply arrived, so nothing is extended' $planComplete.Extend False
Assert-Equal '#51 plan: and the row says why' $planComplete.Reason 'complete'
$planSilent = Get-PingExtensionPlan -Sent 4 -Received 0 -MaximumCount 21 -WarningPercent 5
Assert-Equal '#51 plan: nothing answered, which no larger count improves' $planSilent.Extend False
Assert-Equal '#51 plan: and that is the expensive case, named' $planSilent.Reason 'silent'
$planExtend = Get-PingExtensionPlan -Sent 4 -Received 3 -MaximumCount 21 -WarningPercent 5
Assert-Equal '#51 plan: some but not all is the ambiguous case' $planExtend.Extend True
Assert-Equal '#51 plan: it goes to the count the threshold needs' $planExtend.TargetCount 21
Assert-Equal '#51 plan: which is seventeen more probes' $planExtend.AdditionalCount 17
$planCapped = Get-PingExtensionPlan -Sent 4 -Received 3 -MaximumCount 10 -WarningPercent 5
Assert-Equal '#51 plan: a lower ceiling caps it rather than being overridden' $planCapped.TargetCount 10
Assert-Equal '#51 plan: and the row can say what it would have taken' $planCapped.RequiredCount 21
Assert-Equal '#51 plan: already at the ceiling, nothing more is sent' ((Get-PingExtensionPlan -Sent 21 -Received 20 -MaximumCount 21 -WarningPercent 5).Reason) 'at-ceiling'
Assert-Equal '#51 plan: a threshold no count escapes extends nothing' ((Get-PingExtensionPlan -Sent 4 -Received 3 -MaximumCount 21 -WarningPercent 0).Reason) 'no-threshold'

# The spread takes its seconds from the wait the run already owed, and never divides by zero.
Assert-Equal '#51 spread: eight seconds over seventeen probes' (Get-PingSampleInterval 8 17) 0.47
Assert-Equal '#51 spread: no budget left means back to back' (Get-PingSampleInterval 0 17) 0
Assert-Equal '#51 spread: a budget with nothing to spread is zero' (Get-PingSampleInterval 8 0) 0
Assert-Equal '#51 spread: a negative budget is not a negative gap' (Get-PingSampleInterval -4 17) 0

# The row itself, so that the rule above is not merely computed somewhere: the verdict has to leave the row.
function New-PingFixture($sent, $received, $average) {
    $lost = $sent - $received
    return [pscustomobject]@{
        Target = '203.0.113.9'; Sent = $sent; Received = $received; Lost = $lost
        LossPercent = [math]::Round(($lost * 100.0 / $sent), 1)
        AverageMs = $average; MinimumMs = $average; MaximumMs = $average
        SuccessMs = @($average); RepliedAddresses = @('203.0.113.9')
        AttemptDetails = @('Attempt 1: success, 5 ms, reply from 203.0.113.9')
    }
}
$pingRoute = [pscustomobject]@{
    Selection     = [pscustomobject]@{ Resolved = $true; Reason = ''; SourceAddress = '192.168.1.106'; InterfaceAlias = 'Wi-Fi'; NextHop = '0.0.0.0'; OnLink = $true }
    LookupAddress = '203.0.113.9'
    Others        = @()
}
# The prose of a row is not compared here, because these cases run against both packages: what is compared is
# statuses, markings, numbers and the shape of the details. This counts the lines of a row's details, which is how
# a sentence that was added can be asserted without reading it.
function Get-DetailLineCount($row) {
    return @([string]$row.Details -split "`r`n|`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
}
# Whether one line of a row's details carries both numbers. The window note pairs the seconds that went on
# failed reads with the seconds of the window they fell inside, so what a wrong attribution looks like is a line
# pairing more of the first than the second has room for (PR #49, round 1).
# The one line of a row's details that matches - used to compare the same sentence between two rows without
# reading either of them, because the prose differs between the packages and the numbers in it do not.
# How many times a row's details match - the ICMP sentence is prose, but the token ICMP is in both packages and
# the method line carries one of its own, so the count separates a row that has the sentence from one that does not.
function Get-DetailMatchCount($row, $pattern) {
    return ([regex]::Matches([string]$row.Details, $pattern)).Count
}
function Get-DetailLine($row, $pattern) {
    $lines = @([string]$row.Details -split "`r`n|`n")
    return [string]@($lines | Where-Object { $_ -match $pattern })[0]
}
function Test-DetailLinePairs($row, $first, $second) {
    $lines = @([string]$row.Details -split "`r`n|`n")
    $a = '(?<![\d.])' + $first + '(?![\d.])'
    $b = '(?<![\d.])' + $second + '(?![\d.])'
    return (@($lines | Where-Object { $_ -match $a -and $_ -match $b }).Count -gt 0)
}
function Get-TcpDecisionLine($row) {
    $lines = @([string]$row.Details -split "`r`n|`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    return $lines[$lines.Count - 1]
}
function Get-PingRow($sent, $received, $average, $required) {
    $script:TcpRows = New-Object System.Collections.ArrayList
    # The gateway rung is claimed where the selection before and after the probes is a source on the subnet of the
    # adapter that supplied the gateway (PR #51, round 4); $pingRoute's source is 192.168.1.106, so that subnet is it.
    Add-PingTargetResult -Name 'Default Gateway' -Target '203.0.113.9' -ConfiguredAddress 'AUTO_GATEWAY' -Required $required -Measurement (New-PingFixture $sent $received $average) -RouteBefore $pingRoute.Selection -RouteAfter $pingRoute -TargetIsAddress $true -TimeoutMs 1200 -RungSubnets @('192.168.1.0/24') | Out-Null
    return @($script:TcpRows)[0]
}
$rowOneOfFour = Get-PingRow 4 3 5 $true
Assert-Equal '#51 row: one lost of four on a required target no longer fails the run' $rowOneOfFour.Status 'WARN'
Assert-Equal '#51 row: and it decides nothing' $rowOneOfFour.Weightless True
Assert-Equal '#51 row: while keeping the figure it measured' ($rowOneOfFour.Message -match '25%') True
Assert-Equal '#51 row: and saying what the sample would have needed' ($rowOneOfFour.Details -match '(?<![\d.])21(?![\d.])') True
# The manual check is the same command in both packages, and since 1.2.10 its count is what was sent rather than
# what was configured - the two are different numbers the moment a sample is continued.
Assert-Equal '#51 row: the manual check reproduces what was actually sent' ($rowOneOfFour.Details -match 'ping -n 4 ') True
$rowOneOfTwentyOne = Get-PingRow 21 20 5 $true
Assert-Equal '#51 row: the same one lost reply out of twenty-one is a pass' $rowOneOfTwentyOne.Status 'PASS'
Assert-Equal '#51 row: a pass carries no coarse-sample line, and the withheld one carries exactly one' ((Get-DetailLineCount $rowOneOfFour) - (Get-DetailLineCount $rowOneOfTwentyOne)) 1
$rowThreeOfFour = Get-PingRow 4 1 5 $true
Assert-Equal '#51 row: three lost of four still fails a required target' $rowThreeOfFour.Status 'FAIL'
Assert-Equal '#51 row: and still decides the run' $rowThreeOfFour.Weightless False
$rowSlow = Get-PingRow 4 3 300 $true
Assert-Equal '#51 row: a withheld loss verdict does not hide a latency one' $rowSlow.Status 'FAIL'
Assert-Equal '#51 row: which keeps its weight, because latency was measured' $rowSlow.Weightless False
# And the sentence about the coarse sample may only claim what is true of the row it ends up on (PR #49, round 2).
# The line is found by the count it names - twenty-one - which is the same number in both packages; what it says
# after that is prose, so the two rows are compared with each other rather than read.
$coarseLineWeightless = Get-DetailLine $rowOneOfFour '(?<![\d.])21(?![\d.])'
$coarseLineWeighted = Get-DetailLine $rowSlow '(?<![\d.])21(?![\d.])'
Assert-Equal '#49 note: both rows explain the sample that was too coarse' (($coarseLineWeightless.Length -gt 40) -and ($coarseLineWeighted.Length -gt 40)) True
Assert-Equal '#49 note: they say the same thing about the measurement' ($coarseLineWeighted.Substring(0, 40) -eq $coarseLineWeightless.Substring(0, 40)) True
Assert-Equal '#49 note: and a different thing about what the row decides' ($coarseLineWeighted -eq $coarseLineWeightless) False
$rowSilent = Get-PingRow 4 0 $null $true
Assert-Equal '#51 row: nothing replying at all still fails a required target at four probes' $rowSilent.Status 'FAIL'
Assert-Equal '#51 row: and decides the run' $rowSilent.Weightless False
# "100 % loss is conclusive" is an argument about four probes, and it was applied to one (PR #49, round 5).
# PingCount 1 is a value the configuration check and the panel both permit, and there the verdict IS the single
# packet: the rule this release already has says so without a new number, and nothing more is sent either way.
$rowSilentOne = Get-PingRow 1 0 $null $true
Assert-Equal '#49 silent: one probe and one timeout no longer fails a required target' $rowSilentOne.Status 'INFO'
Assert-Equal '#49 silent: because that verdict would be the one packet' $rowSilentOne.Weightless True
Assert-Equal '#49 silent: and the row still reports the loss it measured' ($rowSilentOne.Message -match '100%') True
$rowSilentTwo = Get-PingRow 2 0 $null $true
Assert-Equal '#49 silent: two probes is already past it, because one reply back is still critical' $rowSilentTwo.Status 'FAIL'
Assert-Equal '#49 silent: so that row decides the run' $rowSilentTwo.Weightless False
# The sentence about an optional target that may simply be blocking ICMP belongs to that case alone - it was
# gated on the status, which was the same thing until a withheld silent verdict became INFO as well.
$rowSilentOptional = Get-PingRow 4 0 $null $false
# Two matches: the method line names the probes as ICMP echo requests in both packages, and the sentence about a
# target that may simply be blocking ICMP is the second. One match is that sentence absent.
Assert-Equal '#49 silent: an optional target that answered nothing keeps its ICMP sentence' (Get-DetailMatchCount $rowSilentOptional 'ICMP') 2
Assert-Equal '#49 silent: a required one whose verdict was withheld does not' (Get-DetailMatchCount $rowSilentOne 'ICMP') 1
# The sentence belongs to the case, not to the verdict (PR #49, round 6): an optional target that answered nothing
# may simply be blocking ICMP whether or not the verdict was withheld, and round 5 had tied the two together.
$rowSilentOneOptional = Get-PingRow 1 0 $null $false
Assert-Equal '#49 silent: a one-probe optional target has its verdict withheld' $rowSilentOneOptional.Weightless True
Assert-Equal '#49 silent: and keeps the ICMP sentence all the same' (Get-DetailMatchCount $rowSilentOneOptional 'ICMP') 2

# ---- backlog #58: the failed gateway row says what its failure does and does not establish ----
# The one required ping target is answered by the gateway's own stack, which may rate-limit ICMP addressed to
# itself, so its FAIL row carries a sentence saying so - and only its FAIL row: a gateway that answered has nothing
# to qualify, and a failed target that is not the gateway is not answering for itself. The sentence is prose in
# both packages; the token "echo" is what is language-neutral, carried once by the method line in both, so a row
# with the sentence matches it twice and a row without it once.
Assert-Equal '#58 row: a failed gateway ping says what its failure does and does not establish' (Get-DetailMatchCount $rowThreeOfFour 'echo') 2
Assert-Equal '#58 row: a gateway that answered nothing at four probes carries it too' (Get-DetailMatchCount $rowSilent 'echo') 2
Assert-Equal '#58 row: a gateway that passed does not' (Get-DetailMatchCount $rowOneOfTwentyOne 'echo') 1
Assert-Equal '#58 row: so the failed row is exactly one line longer than the passing one' ((Get-DetailLineCount $rowThreeOfFour) - (Get-DetailLineCount $rowOneOfTwentyOne)) 1
$script:TcpRows = New-Object System.Collections.ArrayList
Add-PingTargetResult -Name 'Internet' -Target '1.1.1.1' -ConfiguredAddress '1.1.1.1' -Required $true -Measurement (New-PingFixture 4 1 5) -RouteBefore $pingRoute.Selection -RouteAfter $pingRoute -TargetIsAddress $true -TimeoutMs 1200 | Out-Null
$rowOtherFail = @($script:TcpRows)[0]
Assert-Equal '#58 row: a failed target that is not the gateway fails all the same' $rowOtherFail.Status 'FAIL'
Assert-Equal '#58 row: and does not carry it, because it is not answering for itself' (Get-DetailMatchCount $rowOtherFail 'echo') 1
# A required gateway row fails two ways (PR #50, round 2), and the sentence must name the one that happened: a row that
# answered every probe slowly must not say the gateway did not answer. The sentence is the row's last line; the
# average and the counts in it are the same numbers in both packages.
$rowSlowGateway = Get-PingRow 4 4 300 $true
Assert-Equal '#58 row: a gateway that answered everything slowly fails on latency' $rowSlowGateway.Status 'FAIL'
Assert-Equal '#58 row: and carries the sentence' (Get-DetailMatchCount $rowSlowGateway 'echo') 2
Assert-Equal '#58 row: which names the average it measured' ((Get-TcpDecisionLine $rowSlowGateway) -match '(?<![\d.])300(?![\d.])') True
Assert-Equal '#58 row: while the row that lost three of four names those counts' (((Get-TcpDecisionLine $rowThreeOfFour) -match '(?<![\d.])3(?![\d.])') -and ((Get-TcpDecisionLine $rowThreeOfFour) -match '(?<![\d.])4(?![\d.])')) True
Assert-Equal '#58 row: so the two sentences are not the same sentence' ((Get-TcpDecisionLine $rowSlowGateway) -eq (Get-TcpDecisionLine $rowThreeOfFour)) False

# A continued sample rewrites the row it already has rather than adding a second one: the report renders rows in
# the order they were added, so a row written late would leave the ping section in two pieces.
$script:TcpRows = New-Object System.Collections.ArrayList
$provisional = Add-PingTargetResult -Name 'Default Gateway' -Target '203.0.113.9' -ConfiguredAddress 'AUTO_GATEWAY' -Required $true -Measurement (New-PingFixture 4 3 5) -RouteBefore $pingRoute.Selection -RouteAfter $pingRoute -TargetIsAddress $true -TimeoutMs 1200
Assert-Equal '#51 row: the first pass writes a row where it belongs' (@($script:TcpRows).Count) 1
Assert-Equal '#51 row: under the tag the configured address decides' $provisional.Tag 'ping-gateway'
Assert-Equal '#51 row: and it decides nothing while it is provisional' $provisional.Weightless True
Add-PingTargetResult -Name 'Default Gateway' -Target '203.0.113.9' -ConfiguredAddress 'AUTO_GATEWAY' -Required $true -Measurement (New-PingFixture 21 20 5) -RouteBefore $pingRoute.Selection -RouteAfter $pingRoute -TargetIsAddress $true -TimeoutMs 1200 -Row $provisional | Out-Null
Assert-Equal '#51 row: finishing the sample adds no second row' (@($script:TcpRows).Count) 1
Assert-Equal '#51 row: the row it already had now carries the whole sample' ($provisional.Message -match '20/21') True
Assert-Equal '#51 row: and the verdict that sample can carry' $provisional.Status 'PASS'
Assert-Equal '#51 row: which decides the run again' $provisional.Weightless False

# ---- backlog #67: which measurement decided a ping row is on the row, not only in its prose ----
# Rule is "loss" where the loss band decided the status - a row nothing answered included, and a withheld one, since
# the band it reached was a loss band - "latency" where the replies that did arrive did, and empty where nothing did.
# The values are the same literals in both packages.
Assert-Equal '#67 rule: a row that passed names none' $rowOneOfTwentyOne.Rule ''
Assert-Equal '#67 rule: three lost of four was decided by its loss' $rowThreeOfFour.Rule 'loss'
Assert-Equal '#67 rule: nothing answering was decided by its loss too' $rowSilent.Rule 'loss'
Assert-Equal '#67 rule: a withheld loss verdict still names the loss band it reached' $rowOneOfFour.Rule 'loss'
Assert-Equal '#67 rule: a gateway that answered everything slowly was decided by its latency' $rowSlowGateway.Rule 'latency'
Assert-Equal '#67 rule: and so was the row whose loss verdict was withheld and whose latency was not' $rowSlow.Rule 'latency'
$rowSlowOptional = Get-PingRow 4 4 300 $false
Assert-Equal '#67 rule: an optional target answering slowly warns' $rowSlowOptional.Status 'WARN'
Assert-Equal '#67 rule: and names its latency all the same' $rowSlowOptional.Rule 'latency'
Assert-Equal '#67 rule: a sample that finished as a pass has its rule cleared with its status' $provisional.Rule ''
# The fingerprint is what the field exists for: it reads it, and the row that carried the old blindness - a
# gateway failed on latency - is kept out of the gateway-unreachable predicate by it. Asserted on the function
# body, the way the #39 weightless rule is, because a predicate that stopped reading the field would fail no row.
Assert-Equal '#67 fingerprint: its gateway predicate reads the rule' ((Get-FunctionBody 'Get-FingerprintSummary') -match '"ping-gateway"[^\r\n]*\$_\.Rule -ne "latency"') True

# ---- backlog #60: the near-end rung ----
# The rung line is prose in both packages. What is language-neutral: a near-end row and a gateway row each carry
# exactly one line more than a far-end row over the same measurement; the near-end line - the third, after the
# one attempt and the route line - names the host it places, the gateway's names no address, and a far-end row
# goes straight from its route line to its method line, which names ICMP in both packages.
function Get-DetailLineAt($row, $index) { return [string]@([string]$row.Details -split "`r`n|`n")[$index] }
# A route selection on the target's own subnet, before and after the probes, is what lets a near-end row claim the
# rung at all (PR #51, round 3); the fixture below is that, and $pingRoute - a source on another subnet - is not.
$nearRoute = [pscustomobject]@{
    Selection     = [pscustomobject]@{ Resolved = $true; Reason = ''; SourceAddress = '203.0.113.5'; InterfaceAlias = 'Ethernet'; NextHop = '0.0.0.0'; OnLink = $true }
    LookupAddress = '203.0.113.9'
    Others        = @()
}
$script:TcpRows = New-Object System.Collections.ArrayList
Add-PingTargetResult -Name 'Near-end host' -Target '203.0.113.9' -ConfiguredAddress '203.0.113.9' -Required $false -Measurement (New-PingFixture 4 4 5) -RouteBefore $nearRoute.Selection -RouteAfter $nearRoute -TargetIsAddress $true -TimeoutMs 1200 -NearEnd $true -RungSubnets @('203.0.113.0/24') | Out-Null
$rowNearEnd = @($script:TcpRows)[0]
$script:TcpRows = New-Object System.Collections.ArrayList
Add-PingTargetResult -Name 'Internet' -Target '203.0.113.9' -ConfiguredAddress '203.0.113.9' -Required $false -Measurement (New-PingFixture 4 4 5) -RouteBefore $pingRoute.Selection -RouteAfter $pingRoute -TargetIsAddress $true -TimeoutMs 1200 | Out-Null
$rowFarEnd = @($script:TcpRows)[0]
$rowGatewayPass = Get-PingRow 4 4 5 $true
Assert-Equal '#60 rung: the near-end row carries its own tag' $rowNearEnd.Tag 'ping-near-end'
Assert-Equal '#60 rung: a far-end target keeps the plain one' $rowFarEnd.Tag 'ping-target'
Assert-Equal '#60 rung: the near-end row is one line longer than a far-end row over the same measurement' ((Get-DetailLineCount $rowNearEnd) - (Get-DetailLineCount $rowFarEnd)) 1
Assert-Equal '#60 rung: and so is the gateway row' ((Get-DetailLineCount $rowGatewayPass) - (Get-DetailLineCount $rowFarEnd)) 1
Assert-Equal '#60 rung: the near-end line names the host it places' ((Get-DetailLineAt $rowNearEnd 2) -match '203\.0\.113\.9') True
Assert-Equal '#60 rung: the gateway line names the source it was attested on' ((Get-DetailLineAt $rowGatewayPass 2) -match '192\.168\.1\.106') True
Assert-Equal '#60 rung: the two rung lines are different sentences' ((Get-DetailLineAt $rowNearEnd 2) -eq (Get-DetailLineAt $rowGatewayPass 2)) False
Assert-Equal '#60 rung: a far-end row goes straight to its method line' ((Get-DetailLineAt $rowFarEnd 2) -match 'ICMP') True
Assert-Equal '#60 rung: a near-end row that passed carries no gateway sentence' (Get-DetailMatchCount $rowNearEnd 'echo') 1
# Where the near-end target sits, decided before anything is sent: the gateway itself, inside a primary adapter's
# IPv4 subnet, or neither. An adapter whose prefix is unknown contributes no subnet, and the gateway is refused
# before any subnet is consulted. The subnet test underneath is asserted on its own first, because the chain's
# result-set oracle loads it from the package as one of the converters it does not re-implement.
Assert-Equal '#60 cidr: the last address of a /24 is inside it' (Test-IPv4InCidr -IpAddress '192.0.2.255' -Cidr '192.0.2.10/24') True
Assert-Equal '#60 cidr: the next network is not' (Test-IPv4InCidr -IpAddress '192.0.3.1' -Cidr '192.0.2.10/24') False
Assert-Equal '#60 cidr: a bare address is no subnet' (Test-IPv4InCidr -IpAddress '192.0.2.20' -Cidr '192.0.2.10') False
$nearAdapters = @([pscustomobject]@{ IPv4Addresses = @('192.0.2.10'); IPv4WithPrefix = @('192.0.2.10/24'); Gateways = @('192.0.2.1'); DnsServers = @() })
Assert-Equal '#60 placement: the gateway itself' (Test-NearEndTargetPlacement -Address '192.0.2.1' -PrimaryAdapters $nearAdapters).Placement 'gateway'
Assert-Equal '#60 placement: a host inside the subnet' (Test-NearEndTargetPlacement -Address '192.0.2.20' -PrimaryAdapters $nearAdapters).Placement 'on-subnet'
Assert-Equal '#60 placement: a host outside it' (Test-NearEndTargetPlacement -Address '198.51.100.5' -PrimaryAdapters $nearAdapters).Placement 'off-subnet'
Assert-Equal '#60 placement: the subnets it judged by are reported' ((Test-NearEndTargetPlacement -Address '198.51.100.5' -PrimaryAdapters $nearAdapters).Subnets -join ',') '192.0.2.10/24'
$twoAdapters = $nearAdapters + @([pscustomobject]@{ IPv4Addresses = @('10.0.0.5'); IPv4WithPrefix = @('10.0.0.5/8'); Gateways = @('10.0.0.254'); DnsServers = @() })
Assert-Equal '#60 placement: on a multihomed machine any primary subnet places it' (Test-NearEndTargetPlacement -Address '10.20.30.40' -PrimaryAdapters $twoAdapters).Placement 'on-subnet'
Assert-Equal '#60 placement: and either gateway is refused' (Test-NearEndTargetPlacement -Address '10.0.0.254' -PrimaryAdapters $twoAdapters).Placement 'gateway'
$bareAdapters = @([pscustomobject]@{ IPv4Addresses = @('192.0.2.10'); IPv4WithPrefix = @('192.0.2.10'); Gateways = @('192.0.2.1'); DnsServers = @() })
Assert-Equal '#60 placement: an adapter whose prefix is unknown places nothing' (Test-NearEndTargetPlacement -Address '192.0.2.20' -PrimaryAdapters $bareAdapters).Placement 'off-subnet'
Assert-Equal '#60 placement: and says it judged by no subnet' (@((Test-NearEndTargetPlacement -Address '192.0.2.20' -PrimaryAdapters $bareAdapters).Subnets).Count) 0
Assert-Equal '#60 placement: the gateway is refused before any subnet is consulted' (Test-NearEndTargetPlacement -Address '192.0.2.1' -PrimaryAdapters $bareAdapters).Placement 'gateway'
# This computer's own address is inside its own subnet, and a probe to it is answered by this stack without crossing
# anything (PR #51, round 1); so are the subnet's network and broadcast addresses, which no host holds. All three are
# configuration mistakes, refused before the subnet test can call them the near-end host.
Assert-Equal '#60 placement: this computer''s own address is refused' (Test-NearEndTargetPlacement -Address '192.0.2.10' -PrimaryAdapters $nearAdapters).Placement 'self'
Assert-Equal '#60 placement: and refused before the subnet is consulted' (Test-NearEndTargetPlacement -Address '192.0.2.10' -PrimaryAdapters $bareAdapters).Placement 'self'
Assert-Equal '#60 placement: on a multihomed machine either own address is refused' (Test-NearEndTargetPlacement -Address '10.0.0.5' -PrimaryAdapters $twoAdapters).Placement 'self'
Assert-Equal '#60 placement: the subnet''s broadcast address is not a host' (Test-NearEndTargetPlacement -Address '192.0.2.255' -PrimaryAdapters $nearAdapters).Placement 'not-a-host'
Assert-Equal '#60 placement: nor is its network address' (Test-NearEndTargetPlacement -Address '192.0.2.0' -PrimaryAdapters $nearAdapters).Placement 'not-a-host'
Assert-Equal '#60 placement: the last host before the broadcast address is a host' (Test-NearEndTargetPlacement -Address '192.0.2.254' -PrimaryAdapters $nearAdapters).Placement 'on-subnet'
$pointToPoint = @([pscustomobject]@{ IPv4Addresses = @('192.0.2.10'); IPv4WithPrefix = @('192.0.2.10/31'); Gateways = @('192.0.2.11'); DnsServers = @() })
Assert-Equal '#60 placement: a /31 has no broadcast address, so its all-ones host is left to the gateway test' (Test-NearEndTargetPlacement -Address '192.0.2.11' -PrimaryAdapters $pointToPoint).Placement 'gateway'
$wide = @([pscustomobject]@{ IPv4Addresses = @('10.1.2.3'); IPv4WithPrefix = @('10.1.2.3/8'); Gateways = @('10.0.0.1'); DnsServers = @() })
Assert-Equal '#60 placement: the broadcast address of a /8 is found across the octets' (Test-NearEndTargetPlacement -Address '10.255.255.255' -PrimaryAdapters $wide).Placement 'not-a-host'
Assert-Equal '#60 placement: and a host whose last octet is 255 inside a /8 is a host' (Test-NearEndTargetPlacement -Address '10.1.2.255' -PrimaryAdapters $wide).Placement 'on-subnet'
# .NET parses spellings a person does not mean - a single number, hexadecimal parts, three parts, a leading zero read
# as octal - and a string comparison against the machine's own addresses misses every one of them (PR #51, round 2).
# The rule refuses every spelling but dotted decimal, so that what the file says and what the probe is sent to are the
# same string; the placement compares parsed forms all the same, so a caller that skipped the rule gets the same answer.
Assert-Equal '#60 syntax: dotted decimal passes' (Test-NearEndAddressSyntax '192.0.2.10') True
Assert-Equal '#60 syntax: a single number is refused although .NET parses it' (Test-NearEndAddressSyntax '3221225994') False
Assert-Equal '#60 syntax: hexadecimal parts are refused' (Test-NearEndAddressSyntax '0xC0.0.2.10') False
Assert-Equal '#60 syntax: a leading zero is refused, because .NET reads it as octal' (Test-NearEndAddressSyntax '192.0.2.010') False
Assert-Equal '#60 syntax: three parts are refused' (Test-NearEndAddressSyntax '192.0.2') False
Assert-Equal '#60 syntax: an IPv6 address is refused' (Test-NearEndAddressSyntax '2001:db8::1') False
Assert-Equal '#60 syntax: a name is refused' (Test-NearEndAddressSyntax 'printer.example') False
Assert-Equal '#60 syntax: the canonical form of a number is what the parser meant' (Get-CanonicalIPv4Text '3221225994') '192.0.2.10'
Assert-Equal '#60 syntax: and of a leading zero, which is not what a person meant' (Get-CanonicalIPv4Text '192.0.2.010') '192.0.2.8'
Assert-Equal '#60 syntax: text that is not an address comes back as given' (Get-CanonicalIPv4Text 'printer.example') 'printer.example'
Assert-Equal '#60 placement: a numeric spelling of this computer''s own address is still refused' (Test-NearEndTargetPlacement -Address '3221225994' -PrimaryAdapters $nearAdapters).Placement 'self'
Assert-Equal '#60 placement: a numeric spelling of the gateway is still the gateway' (Test-NearEndTargetPlacement -Address '3221225985' -PrimaryAdapters $nearAdapters).Placement 'gateway'
Assert-Equal '#60 placement: a hexadecimal spelling of the broadcast address is still not a host' (Test-NearEndTargetPlacement -Address '0xC0.0.2.255' -PrimaryAdapters $nearAdapters).Placement 'not-a-host'
Assert-Equal '#60 placement: and the form that was placed is reported' (Test-NearEndTargetPlacement -Address '3221225994' -PrimaryAdapters $nearAdapters).Canonical '192.0.2.10'
Assert-Equal '#60 syntax: the run applies the rule' ((Get-FunctionBody 'Test-PingTargets') -match 'Test-NearEndAddressSyntax') True
Assert-Equal '#60 syntax: and so does the configuration check' ((Get-FunctionBody 'Test-ConfigurationSemantics') -match 'Test-NearEndAddressSyntax') True
# Subnet membership says where the host is, not which interface the unbound probes left by (PR #51, round 3): a VPN,
# a second connection or a more specific route can carry them elsewhere. The row claims the rung only where the route
# table selected a source on the target's subnet before and after the probes; otherwise it keeps its title and its
# measurement, says why, and is tagged as an ordinary ping target so that the fingerprint never reads it as a witness.
function Get-NearEndRow($routeBefore, $routeAfter, $subnets) {
    $script:TcpRows = New-Object System.Collections.ArrayList
    Add-PingTargetResult -Name 'Near-end host' -Target '203.0.113.9' -ConfiguredAddress '203.0.113.9' -Required $false -Measurement (New-PingFixture 4 4 5) -RouteBefore $routeBefore -RouteAfter $routeAfter -TargetIsAddress $true -TimeoutMs 1200 -NearEnd $true -RungSubnets $subnets | Out-Null
    return @($script:TcpRows)[0]
}
$rowAttested = Get-NearEndRow $nearRoute.Selection $nearRoute @('203.0.113.0/24')
Assert-Equal '#60 rung: a source on the subnet before and after the probes claims the rung' $rowAttested.Tag 'ping-near-end'
Assert-Equal '#60 rung: and the rung line names that source' ((Get-DetailLineAt $rowAttested 2) -match '203\.0\.113\.5') True
$rowElsewhere = Get-NearEndRow $pingRoute.Selection $pingRoute @('203.0.113.0/24')
Assert-Equal '#60 rung: a source off the subnet - a VPN, a second connection - does not claim it' $rowElsewhere.Tag 'ping-target'
Assert-Equal '#60 rung: the row still explains itself, one line longer than a far-end row' ((Get-DetailLineCount $rowElsewhere) - (Get-DetailLineCount $rowFarEnd)) 1
Assert-Equal '#60 rung: naming the host and no source it did not have' (((Get-DetailLineAt $rowElsewhere 2) -match '203\.0\.113\.9') -and -not ((Get-DetailLineAt $rowElsewhere 2) -match '203\.0\.113\.5')) True
Assert-Equal '#60 rung: and the two rung lines are different sentences' ((Get-DetailLineAt $rowElsewhere 2) -eq (Get-DetailLineAt $rowAttested 2)) False
$rowChanged = Get-NearEndRow $nearRoute.Selection $pingRoute @('203.0.113.0/24')
Assert-Equal '#60 rung: a selection that changed during the probes does not claim it' $rowChanged.Tag 'ping-target'
$rowUnresolved = Get-NearEndRow ([pscustomobject]@{ Resolved = $false; Reason = 'cmdlet'; SourceAddress = ''; InterfaceAlias = '' }) $nearRoute @('203.0.113.0/24')
Assert-Equal '#60 rung: an unavailable lookup does not claim it' $rowUnresolved.Tag 'ping-target'
$rowNoSubnet = Get-NearEndRow $nearRoute.Selection $nearRoute @()
Assert-Equal '#60 rung: and no subnet to test against does not claim it' $rowNoSubnet.Tag 'ping-target'
Assert-Equal '#60 rung: whichever way, the measurement is the same' (($rowAttested.Message -eq $rowElsewhere.Message) -and ($rowAttested.Status -eq $rowElsewhere.Status)) True
# The second pass can withdraw the claim: a row rewritten after the last probe with a selection that moved changes tag.
$script:TcpRows = New-Object System.Collections.ArrayList
$provisionalNear = Add-PingTargetResult -Name 'Near-end host' -Target '203.0.113.9' -ConfiguredAddress '203.0.113.9' -Required $false -Measurement (New-PingFixture 4 3 5) -RouteBefore $nearRoute.Selection -RouteAfter $nearRoute -TargetIsAddress $true -TimeoutMs 1200 -NearEnd $true -RungSubnets @('203.0.113.0/24')
Assert-Equal '#60 rung: the first pass claims the rung' $provisionalNear.Tag 'ping-near-end'
Add-PingTargetResult -Name 'Near-end host' -Target '203.0.113.9' -ConfiguredAddress '203.0.113.9' -Required $false -Measurement (New-PingFixture 21 20 5) -RouteBefore $nearRoute.Selection -RouteAfter $pingRoute -TargetIsAddress $true -TimeoutMs 1200 -Row $provisionalNear -NearEnd $true -RungSubnets @('203.0.113.0/24') | Out-Null
Assert-Equal '#60 rung: and the second pass withdraws it when the selection moved' $provisionalNear.Tag 'ping-target'
Assert-Equal '#60 ladder: the run hands the rung''s subnets to the row' ((Get-FunctionBody 'Test-PingTargets') -match '-RungSubnets \$targetRungSubnets') True
Assert-Equal '#60 ladder: the gateway''s are the subnets of the adapters that supplied it' ((Get-FunctionBody 'Test-PingTargets') -match '\$targetRungSubnets \+= \[string\]\$entry') True
Assert-Equal '#60 ladder: and the second pass hands them on' ((Get-FunctionBody 'Complete-PingSamples') -match '-RungSubnets \$item\.RungSubnets') True
# Round 4: the gateway row claims its rung on the same terms - a selection on the subnet of the adapter that supplied
# the gateway, before and after the probes - and every ping row whose two lookups agreed carries Path, the interface
# they agreed on, which is what the fingerprint pairs a near-end row with a failed gateway row by.
$script:TcpRows = New-Object System.Collections.ArrayList
Add-PingTargetResult -Name 'Default Gateway' -Target '203.0.113.9' -ConfiguredAddress 'AUTO_GATEWAY' -Required $true -Measurement (New-PingFixture 4 4 5) -RouteBefore $pingRoute.Selection -RouteAfter $pingRoute -TargetIsAddress $true -TimeoutMs 1200 -RungSubnets @('203.0.113.0/24') | Out-Null
$rowGatewayElsewhere = @($script:TcpRows)[0]
Assert-Equal '#60 rung: a gateway reached through another adapter''s selection does not claim its rung' ((Get-DetailLineAt $rowGatewayElsewhere 2) -eq (Get-DetailLineAt $rowGatewayPass 2)) False
Assert-Equal '#60 rung: but keeps its tag, because the gateway is still what it measured' $rowGatewayElsewhere.Tag 'ping-gateway'
Assert-Equal '#60 rung: and its line names no address it did not have' ((Get-DetailLineAt $rowGatewayElsewhere 2) -match '\d+\.\d+\.\d+\.\d+') False
Assert-Equal '#60 rung: still one line longer than a far-end row' ((Get-DetailLineCount $rowGatewayElsewhere) - (Get-DetailLineCount $rowFarEnd)) 1
Assert-Equal '#60 path: an attested near-end row names the adapter it claimed its rung on' $rowAttested.Path 'Ethernet'
Assert-Equal '#60 path: so does a gateway row' $rowGatewayPass.Path 'Wi-Fi'
Assert-Equal '#60 path: a far-end row claims no rung, so it carries none' $rowFarEnd.Path ''
Assert-Equal '#60 path: a near-end row off its subnet claimed nothing, so it carries none' $rowElsewhere.Path ''
Assert-Equal '#60 path: a selection that changed leaves it empty' $rowChanged.Path ''
Assert-Equal '#60 path: an unavailable lookup leaves it empty' $rowUnresolved.Path ''
Assert-Equal '#60 path: the second pass rewrites it with the tag' $provisionalNear.Path ''
Assert-Equal '#60 path: the fingerprint pairs the two rows by it' ((Get-FunctionBody 'Get-FingerprintSummary') -match '\$_\.Path -ne \$nearEndPath') True
# Round 5: the same source and interface can still be a route through a router - a /32 to the host via the default
# gateway - so a rung is claimed only where the selection is on-link, with no next hop, before and after the probes.
$viaRouter = [pscustomobject]@{
    Selection     = [pscustomobject]@{ Resolved = $true; Reason = ''; SourceAddress = '203.0.113.5'; InterfaceAlias = 'Ethernet'; NextHop = '203.0.113.1'; OnLink = $false }
    LookupAddress = '203.0.113.9'
    Others        = @()
}
$rowViaRouter = Get-NearEndRow $viaRouter.Selection $viaRouter @('203.0.113.0/24')
Assert-Equal '#60 rung: a route through a router, same source and interface, does not claim the rung' $rowViaRouter.Tag 'ping-target'
Assert-Equal '#60 rung: and though its lookups agreed, it names no path, so the summary cannot pair it' $rowViaRouter.Path ''
Assert-Equal '#60 rung: its route line reads the hop it went through' ((Get-DetailLineAt $rowViaRouter 1) -match '203\.0\.113\.1(?!\d)') True
$rowHopChanged = Get-NearEndRow $nearRoute.Selection $viaRouter @('203.0.113.0/24')
Assert-Equal '#60 rung: a next hop that changed between the lookups is a changed selection' $rowHopChanged.Path ''
Assert-Equal '#60 rung: and its route line says so, rather than reading as unchanged beside a refused rung' (((Get-DetailLineAt $rowHopChanged 1) -eq (Get-DetailLineAt $rowAttested 1)) -or -not ((Get-DetailLineAt $rowHopChanged 1) -match '203\.0\.113\.1(?!\d)')) False
$script:TcpRows = New-Object System.Collections.ArrayList
Add-PingTargetResult -Name 'Default Gateway' -Target '203.0.113.9' -ConfiguredAddress 'AUTO_GATEWAY' -Required $true -Measurement (New-PingFixture 4 4 5) -RouteBefore $viaRouter.Selection -RouteAfter $viaRouter -TargetIsAddress $true -TimeoutMs 1200 -RungSubnets @('203.0.113.0/24') | Out-Null
$rowGatewayViaRouter = @($script:TcpRows)[0]
Assert-Equal '#60 rung: a gateway reached through a router does not claim its rung' ((Get-DetailLineAt $rowGatewayViaRouter 2) -eq (Get-DetailLineAt $rowGatewayPass 2)) False
Assert-Equal '#60 rung: and keeps its tag' $rowGatewayViaRouter.Tag 'ping-gateway'
Assert-Equal '#60 rung: the attestation reads the on-link flag' ((Get-FunctionBody 'Add-PingTargetResult') -match '\$RouteBefore\.OnLink -eq \$true') True
Assert-Equal '#60 rung: a gateway reached through a router carries no path either' $rowGatewayViaRouter.Path ''
Assert-Equal '#60 path: the field reads the attestation, not the agreement' ((Get-FunctionBody 'Add-PingTargetResult') -match 'if \(\$rungAttested\) \{ \$path = ') True
Assert-Equal '#60 placement: the subnet the target fell in is reported' (Test-NearEndTargetPlacement -Address '192.0.2.20' -PrimaryAdapters $nearAdapters).Subnet '192.0.2.10/24'
Assert-Equal '#60 placement: and is empty where nothing placed it' (Test-NearEndTargetPlacement -Address '198.51.100.5' -PrimaryAdapters $nearAdapters).Subnet ''
# The near-end entry is built in the run and never read from the ping list, so a list entry cannot promote itself
# to the rung, and the traceroute - which walks the list for its target - never meets it.
Assert-Equal '#60 ladder: the near-end entry is built by the run' ((Get-FunctionBody 'Test-PingTargets') -match 'NearEnd = \$true') True
Assert-Equal '#60 ladder: the traceroute never sees the near-end target' ((Get-FunctionBody 'Add-TracerouteResult') -match 'NearEndTarget') False

# ---- backlog #32: the server that answered the lease, beside the mode on the adapter row ----
# Four shapes, in the order the function decides them: a static address names no server whatever the configuration
# holds, an unreadable class says so and names the class, a lease names its server, and a configuration holding no
# server address says that. The address is the language-neutral token; the other three are compared with each other.
$dhcpStatic = Get-DhcpServerText -DhcpEnabled $false -DhcpServer '192.0.2.1'
$dhcpUnavailable = Get-DhcpServerText -DhcpEnabled $true -DhcpServer $null
$dhcpLease = Get-DhcpServerText -DhcpEnabled $true -DhcpServer '192.0.2.1'
$dhcpNone = Get-DhcpServerText -DhcpEnabled $true -DhcpServer ''
Assert-Equal '#32 dhcp server: a lease names the server that answered it' $dhcpLease '192.0.2.1'
Assert-Equal '#32 dhcp server: an unknown mode with a server still names it' (Get-DhcpServerText -DhcpEnabled $null -DhcpServer '192.0.2.1') '192.0.2.1'
Assert-Equal '#32 dhcp server: a static address names no server, whatever the configuration holds' ($dhcpStatic -match '192\.0\.2\.1') False
Assert-Equal '#32 dhcp server: an unreadable class says which class' ($dhcpUnavailable -match 'Win32_NetworkAdapterConfiguration') True
Assert-Equal '#32 dhcp server: a static address does not borrow that sentence' ($dhcpStatic -match 'Win32_NetworkAdapterConfiguration') False
Assert-Equal '#32 dhcp server: no server held is a sentence of its own' (@($dhcpStatic, $dhcpUnavailable, $dhcpLease) -contains $dhcpNone) False
Assert-Equal '#32 dhcp server: and every shape says something' (($dhcpStatic.Length -gt 0) -and ($dhcpNone.Length -gt 0)) True
Assert-Equal '#32 dhcp server: the adapter row prints it' ((Get-FunctionBody 'Add-NetworkSnapshotResults') -match 'Get-DhcpServerText') True
Assert-Equal '#32 dhcp server: the chain''s own probe records the same field' ((Get-Content -LiteralPath (Join-Path $PSScriptRoot 'environment_probe.ps1') -Raw) -match 'DHCPServer=\{5\}') True

# ---- the TCP half: the count floor, and #63's standalone trigger removed ----
function New-TcpPair($sent, $retransmitted) {
    $stamp = Get-Date '2026-09-11T09:00:00'
    $before = [pscustomobject]@{
        Timestamp = $stamp
        Counters  = @{ 'TCPv4' = (New-CounterFixture 'TCPv4' $stamp 100000 1000) }
        Errors    = @(); FailedAttempts = @(); WarmUpFailures = @()
    }
    $after = [pscustomobject]@{
        Timestamp = $stamp.AddSeconds(9)
        Counters  = @{ 'TCPv4' = (New-CounterFixture 'TCPv4' $stamp.AddSeconds(9) (100000 + $sent) (1000 + $retransmitted)) }
        Errors    = @(); FailedAttempts = @(); WarmUpFailures = @()
    }
    return @($before, $after)
}
function Get-TcpRow($sent, $retransmitted) {
    $pair = New-TcpPair $sent $retransmitted
    $script:TcpRows = New-Object System.Collections.ArrayList
    Compare-TcpCounters -Before $pair[0] -After $pair[1]
    return @($script:TcpRows | Where-Object { $_.Check -eq 'TCPv4' })[0]
}

# The case the acceptance names: three retransmissions in fifty segments is 6 %, which fails on the rate alone
# today. A change that guarded only the warning branch would leave it a FAIL, so the assertion is on the status.
$rowFloorFail = Get-TcpRow 50 3
Assert-Equal '#51 tcp: 3 of 50 is 6% and used to FAIL on the rate alone' $rowFloorFail.Status 'INFO'
Assert-Equal '#51 tcp: it carries no verdict' $rowFloorFail.Weightless True
Assert-Equal '#51 tcp: and keeps its rate' ($rowFloorFail.Message -match '6%') True
$rowTwoOfEightyFour = Get-TcpRow 84 2
Assert-Equal '#51 tcp: 2 of 84 is 2.381% and used to WARN' $rowTwoOfEightyFour.Status 'INFO'
Assert-Equal '#51 tcp: on too few events to rate' $rowTwoOfEightyFour.Weightless True
$rowSmallSample = Get-TcpRow 40 1
Assert-Equal '#51 tcp: a sample below the rating floor is information, not a warning' $rowSmallSample.Status 'INFO'
Assert-Equal '#51 tcp: and has been weightless since 1.2.8' $rowSmallSample.Weightless True
$rowSmallClean = Get-TcpRow 40 0
Assert-Equal '#51 tcp: a small sample with no retransmission is unchanged' $rowSmallClean.Status 'INFO'
$rowReal = Get-TcpRow 2906 251
Assert-Equal '#51 tcp: 251 of 2906 is untouched' $rowReal.Status 'FAIL'
Assert-Equal '#51 tcp: and still decides the run' $rowReal.Weightless False

# #63's two measured cases: both rates are below the shipped 2 % warning threshold, and both warned only because
# fifty retransmissions warned on their own.
$rowBusyUser = Get-TcpRow 3832 57
Assert-Equal '#63 tcp: 57 of 3832 is 1.487%, below both thresholds' $rowBusyUser.Status 'PASS'
Assert-Equal '#63 tcp: 482 of 27594 is 1.747%' ((Get-TcpRow 27594 482).Status) 'PASS'
$rowSharpened = Get-TcpRow 2000 60
Assert-Equal '#63 tcp: the count still sharpens a verdict the rate reached' $rowSharpened.Status 'FAIL'
$rowWarn = Get-TcpRow 400 10
Assert-Equal '#63 tcp: a warning rate on enough events is still a warning' $rowWarn.Status 'WARN'

# #63's acceptance asks that the row say which of the two decided it. The sentence itself is prose and differs
# between the packages, so what is asserted is that there IS one and that the three cases do not share it: a pass
# ends on the line every row ends on, and each of the other three ends on a sentence of its own.
$tcpPassTail = Get-TcpDecisionLine $rowBusyUser
Assert-Equal '#63 tcp: a pass adds nothing, because nothing decided it' ((Get-TcpDecisionLine (Get-TcpRow 2000 10)) -eq $tcpPassTail) True
Assert-Equal '#63 tcp: a fail on the rate adds a sentence' ((Get-TcpDecisionLine $rowReal) -eq $tcpPassTail) False
Assert-Equal '#63 tcp: so does a warning' ((Get-TcpDecisionLine $rowWarn) -eq $tcpPassTail) False
Assert-Equal '#63 tcp: and the rate-and-count sentence is not the rate one' ((Get-TcpDecisionLine $rowSharpened) -eq (Get-TcpDecisionLine $rowReal)) False
Assert-Equal '#63 tcp: the sharpened one names the count threshold it reached' ((Get-TcpDecisionLine $rowSharpened) -match '(?<![\d.])50(?!\d)') True
Assert-Equal '#63 tcp: the rate one does not, because no count decided it' ((Get-TcpDecisionLine $rowReal) -match '(?<![\d.])50(?!\d)') False

# The window is extended once, in the ambiguous case and only there.
$extendPair = New-TcpPair 40 1
Assert-Equal '#51 extend: a small sample carrying a retransmission is extended' (Test-TcpSampleNeedsExtension -Before $extendPair[0] -After $extendPair[1]) True
$quietPair = New-TcpPair 40 0
Assert-Equal '#51 extend: a small sample with no retransmission is not' (Test-TcpSampleNeedsExtension -Before $quietPair[0] -After $quietPair[1]) False
$bigPair = New-TcpPair 2906 251
Assert-Equal '#51 extend: a sample that already has a rate is not' (Test-TcpSampleNeedsExtension -Before $bigPair[0] -After $bigPair[1]) False
$resetPair = New-TcpPair -20 1
Assert-Equal '#51 extend: a counter that went backwards is not a reason to wait' (Test-TcpSampleNeedsExtension -Before $resetPair[0] -After $resetPair[1]) False
Assert-Equal '#51 extend: a missing snapshot extends nothing' (Test-TcpSampleNeedsExtension -Before $null -After $extendPair[1]) False

# Merging the second read: the later reading wins, a failed second read costs nothing that was already measured.
$mergeStamp = Get-Date '2026-09-11T09:00:00'
$mergeOriginal = [pscustomobject]@{
    Timestamp = $mergeStamp.AddSeconds(9)
    Counters  = @{ 'TCPv4' = (New-CounterFixture 'TCPv4' $mergeStamp.AddSeconds(9) 100040 1001); 'TCPv6' = (New-CounterFixture 'TCPv6' $mergeStamp.AddSeconds(9) 200010 2000) }
    Errors    = @(); FailedAttempts = @(); WarmUpFailures = @()
}
$mergeExtended = [pscustomobject]@{
    Timestamp = $mergeStamp.AddSeconds(18)
    Counters  = @{ 'TCPv6' = (New-CounterFixture 'TCPv6' $mergeStamp.AddSeconds(18) 200600 2003) }
    Errors    = @([pscustomobject]@{ Protocol = 'TCPv4'; Error = 'Timed out'; Diagnostics = '' })
    FailedAttempts = @([pscustomobject]@{ Protocol = 'TCPv4'; Phase = 'read'; Attempt = 1; Seconds = 8.0; Error = 'Timed out' })
    WarmUpFailures = @()
}
$merged = Merge-TcpEndingSnapshot -Original $mergeOriginal -Extended $mergeExtended
Assert-Equal '#51 merge: the longer window wins where it was read' $merged.Counters['TCPv6'].SegmentsSent 200600
Assert-Equal '#51 merge: a second read that failed keeps the first reading' $merged.Counters['TCPv4'].SegmentsSent 100040
Assert-Equal '#51 merge: so no row is lost to an extension' (@($merged.Errors).Count) 0
Assert-Equal '#51 merge: the failed attempt is still on the record' (@($merged.FailedAttempts).Count) 1
Assert-Equal '#51 merge: and the row can say the window was extended' $merged.Extended True
$mergeBaseline = [pscustomobject]@{
    Timestamp = $mergeStamp
    Counters  = @{ 'TCPv4' = (New-CounterFixture 'TCPv4' $mergeStamp 100000 1000); 'TCPv6' = (New-CounterFixture 'TCPv6' $mergeStamp 200000 2000) }
    Errors    = @(); FailedAttempts = @(); WarmUpFailures = @()
}
$script:TcpRows = New-Object System.Collections.ArrayList
Compare-TcpCounters -Before $mergeBaseline -After $merged
$mergedRow = @($script:TcpRows | Where-Object { $_.Check -eq 'TCPv6' })[0]
Assert-Equal '#51 merge: the row says which floor the first window fell under' ($mergedRow.Details -match 'MinimumTcpSegmentsForRate') True
Assert-Equal '#51 merge: and rates the longer window it closed' ($mergedRow.Message -match '(?<![\d.])600(?![\d.])') True
$mergedNothing = Merge-TcpEndingSnapshot -Original $mergeOriginal -Extended $null
Assert-Equal '#51 merge: an extension that produced nothing leaves the original alone' $mergedNothing.Counters['TCPv6'].SegmentsSent 200010



# PR #49, round 1: a count threshold is a number of things, and [uint64] of a negative one throws - which took the
# whole retransmission analysis down as an Unable to Check row rather than reporting the value. The cast was the
# defect, so one function does it for all three counts and a negative falls back to the built-in default.
$script:Config.Thresholds.MinimumTcpRetransmissionsForVerdict = -1
Assert-Equal '#49 count threshold: a negative floor falls back to its default' (Get-CountThreshold "MinimumTcpRetransmissionsForVerdict" 5) 5
$negativeFloorRow = Get-TcpRow 50 3
Assert-Equal '#49 count threshold: and the analysis still writes its row' $negativeFloorRow.Status 'INFO'
$script:Config.Thresholds.TcpRetransmissionCriticalCount = -50
Assert-Equal '#49 count threshold: the two counts that predate 1.2.10 are the same cast' (Get-CountThreshold "TcpRetransmissionCriticalCount" 50) 50
$script:Config.Thresholds.MinimumTcpSegmentsForRate = -50
Assert-Equal '#49 count threshold: all three of them' (Get-CountThreshold "MinimumTcpSegmentsForRate" 50) 50
$script:Config.Thresholds.MinimumTcpSegmentsForRate = 60
Assert-Equal '#49 count threshold: a value it can use is used' (Get-CountThreshold "MinimumTcpSegmentsForRate" 50) 60
$script:Config.Thresholds.MinimumTcpRetransmissionsForVerdict = 5
$script:Config.Thresholds.TcpRetransmissionCriticalCount = 50
$script:Config.Thresholds.MinimumTcpSegmentsForRate = 50
Assert-Equal '#49 count threshold: and the thresholds are back where the rest of this file expects them' ((Get-TcpRow 2906 251).Status) 'FAIL'

# PR #49, round 1: whose window an extension's failed reads fall inside is not the same question for every
# protocol. TCPv6 is closed by the extension and its window really does contain them; TCPv4's extended read failed,
# so TCPv4 kept the stamp it already had and its window ended before those seconds were spent. Counting them there
# would print more failed seconds than the window is long.
$splitStamp = Get-Date '2026-09-11T10:00:00'
$splitBefore = [pscustomobject]@{
    Timestamp = $splitStamp
    Counters  = @{ 'TCPv4' = (New-CounterFixture 'TCPv4' $splitStamp 100000 1000); 'TCPv6' = (New-CounterFixture 'TCPv6' $splitStamp 200000 2000) }
    Errors    = @(); FailedAttempts = @(); WarmUpFailures = @()
}
$splitOriginal = [pscustomobject]@{
    Timestamp = $splitStamp.AddSeconds(9)
    Counters  = @{ 'TCPv4' = (New-CounterFixture 'TCPv4' $splitStamp.AddSeconds(9) 100040 1001); 'TCPv6' = (New-CounterFixture 'TCPv6' $splitStamp.AddSeconds(9) 200010 2000) }
    Errors    = @()
    # Three seconds of TCPv4's own ending read really are inside TCPv4's nine-second window, which is what makes
    # the numbers separate: the note on that row must say three, and nineteen - those three plus the extension's
    # sixteen - must appear on no line of it at all, because nineteen seconds do not fit inside nine.
    FailedAttempts = @([pscustomobject]@{ Protocol = 'TCPv4'; Phase = 'read'; Attempt = 1; Seconds = 3.0; Error = 'Timed out' })
    WarmUpFailures = @()
}
$splitExtended = [pscustomobject]@{
    Timestamp = $splitStamp.AddSeconds(26)
    Counters  = @{ 'TCPv6' = (New-CounterFixture 'TCPv6' $splitStamp.AddSeconds(26) 200600 2003) }
    Errors    = @([pscustomobject]@{ Protocol = 'TCPv4'; Error = 'Timed out'; Diagnostics = '' })
    FailedAttempts = @(
        [pscustomobject]@{ Protocol = 'TCPv4'; Phase = 'read'; Attempt = 1; Seconds = 8.0; Error = 'Timed out' },
        [pscustomobject]@{ Protocol = 'TCPv4'; Phase = 'read'; Attempt = 2; Seconds = 8.0; Error = 'Timed out' })
    WarmUpFailures = @()
}
$splitMerged = Merge-TcpEndingSnapshot -Original $splitOriginal -Extended $splitExtended
Assert-Equal '#49 extension: the protocols the extension closed are named' ((@($splitMerged.ExtendedProtocols) -join ',')) 'TCPv6'
Assert-Equal '#49 extension: and its failed reads are marked as the extension''s' ((@($splitMerged.FailedAttempts | Where-Object { $_.Phase -eq 'extension' }).Count)) 2
$script:TcpRows = New-Object System.Collections.ArrayList
Compare-TcpCounters -Before $splitBefore -After $splitMerged
$splitV4 = @($script:TcpRows | Where-Object { $_.Check -eq 'TCPv4' })[0]
$splitV6 = @($script:TcpRows | Where-Object { $_.Check -eq 'TCPv6' })[0]
Assert-Equal '#49 extension: the note on the protocol that kept the first reading claims three of its nine seconds' (Test-DetailLinePairs $splitV4 3 9) True
Assert-Equal '#49 extension: and no line of it claims nineteen, which is those three plus the extension''s sixteen' ($splitV4.Details -match '(?<![\d.])19(?![\d.])') False
Assert-Equal '#49 extension: while it still names the sixteen seconds and says where they fell' ($splitV4.Details -match '(?<![\d.])16(?![\d.])') True
Assert-Equal '#49 extension: the protocol the extension closed has all nineteen inside its twenty-six' (Test-DetailLinePairs $splitV6 19 26) True
Assert-Equal '#49 extension: and the reads that failed are named on the row of the protocol they belong to' ($splitV4.Details -match 'TCPv4 #1') True
# The sentence that says a window was extended belongs to the protocols the extension closed, and to no others -
# the snapshot carries one flag, and the row that kept the first reading would otherwise claim an extension and
# then say its window had already closed (PR #49, round 2).
Assert-Equal '#49 extension: the protocol the extension closed says its window was extended' ($splitV6.Details -match 'MinimumTcpSegmentsForRate') True
Assert-Equal '#49 extension: the one that kept the first reading does not, because its window was not' ($splitV4.Details -match 'MinimumTcpSegmentsForRate') False

# --- Wi-Fi retry counters (backlog #61, the retry half; v1.2.12) ---
# The analysis is pure and is tested on fixtures shaped like the reader's envelope; the reader is read off the AST
# where the machine cannot be arranged, and called once for real, whatever this machine has.
function New-WifiPhy($index, $tx, $failed, $retry, $multi, $ack, $rx) { return [pscustomobject]@{ Index = $index; Transmitted = [uint64]$tx; Failed = [uint64]$failed; Retry = [uint64]$retry; MultipleRetry = [uint64]$multi; AckFailure = [uint64]$ack; Received = [uint64]$rx } }
function New-WifiInterface($guid, $state, $phys, $queryError = 0, $queryErrorText = '') { return [pscustomobject]@{ Guid = $guid; Description = 'Fixture Wi-Fi 6E'; State = $state; Phys = @($phys); QueryError = $queryError; QueryErrorText = $queryErrorText } }
function New-WifiSnapshot($stamp, $interfaces, $error = '', $errorText = '') { return [pscustomobject]@{ Timestamp = $stamp; Interfaces = @($interfaces); Error = $error; ErrorText = $errorText; Diagnostics = '' } }
function Get-WifiRows($before, $after) { $script:TcpRows = New-Object System.Collections.ArrayList; Compare-WifiRetryCounters -Before $before -After $after; return @($script:TcpRows) }
$wifiT0 = Get-Date '2026-09-12 10:00:00'; $wifiT1 = $wifiT0.AddSeconds(24)
$wifiGuid = 'e6b08c8a-3feb-4c3e-88c3-dee94dd2f0eb'
# Six mirrored entries - the reference machine's driver writes the interface's totals into every one: one figure, counted once.
$mirrorBefore = New-WifiSnapshot $wifiT0 (New-WifiInterface $wifiGuid 1 @(0..5 | ForEach-Object { New-WifiPhy $_ 1000 0 100 20 300 5000 }))
$mirrorAfter = New-WifiSnapshot $wifiT1 (New-WifiInterface $wifiGuid 1 @(0..5 | ForEach-Object { New-WifiPhy $_ 1211 0 166 42 498 5342 }))
$wifiRows = @(Get-WifiRows $mirrorBefore $mirrorAfter)
Assert-Equal '#61 retry: one row for one interface' $wifiRows.Count 1
$mirrorRow = $wifiRows[0]
Assert-Equal '#61 retry: the row is informational, weightless and tagged' ("{0}/{1}/{2}" -f $mirrorRow.Status, $mirrorRow.Weightless, $mirrorRow.Tag) 'INFO/True/wifi-retry'
Assert-Equal '#61 retry: the rate is retries over frames transmitted plus abandoned - 66 of 211, 31.3%' (($mirrorRow.Message -match '\b66\b') -and ($mirrorRow.Message -match '\b211\b') -and ($mirrorRow.Message -match '31\.3')) True
Assert-Equal '#61 retry: the message names the interface and the window' (($mirrorRow.Message -match 'Fixture Wi-Fi 6E') -and ($mirrorRow.Message -match '\b24\b')) True
Assert-Equal '#61 retry: the multiple-retry subset is listed and not added to the retries' (($mirrorRow.Message -match '\b22\b') -and -not ($mirrorRow.Message -match '\b88\b')) True
Assert-Equal '#61 retry: the details carry the start and end values of the entry used' (($mirrorRow.Details -match 'Transmitted=1000') -and ($mirrorRow.Details -match 'Transmitted=1211') -and ($mirrorRow.Details -match 'ACKFailure=498')) True
Assert-Equal '#61 retry: six entries moved and the figure is not six times larger' ($mirrorRow.Message -match '\b1266\b') False
# Only entry 0 moved: the same figure, and a different sentence about the entries.
$singleAfter = New-WifiSnapshot $wifiT1 (New-WifiInterface $wifiGuid 1 (@(New-WifiPhy 0 1211 0 166 42 498 5342) + @(1..5 | ForEach-Object { New-WifiPhy $_ 1000 0 100 20 300 5000 })))
$singleRow = (Get-WifiRows $mirrorBefore $singleAfter)[0]
Assert-Equal '#61 retry: one entry moving gives the same figure as six mirrored ones' $singleRow.Message $mirrorRow.Message
Assert-Equal '#61 retry: and the entries line says which shape it was' ($singleRow.Details -eq $mirrorRow.Details) False
# Two entries moved with different figures: the larger transmitted delta is the interface's figure, both are listed, nothing is added.
$twoAfter = New-WifiSnapshot $wifiT1 (New-WifiInterface $wifiGuid 1 (@((New-WifiPhy 0 1211 0 166 42 498 5342), (New-WifiPhy 1 1300 0 130 20 300 5000)) + @(2..5 | ForEach-Object { New-WifiPhy $_ 1000 0 100 20 300 5000 })))
$twoRow = (Get-WifiRows $mirrorBefore $twoAfter)[0]
Assert-Equal '#61 retry: the entry with the larger transmitted delta is used - 30 of 300, not 66 of 211' (($twoRow.Message -match '\b30\b') -and ($twoRow.Message -match '\b300\b') -and -not ($twoRow.Message -match '\b211\b')) True
Assert-Equal '#61 retry: and never their sum' ($twoRow.Message -match '\b511\b') False
Assert-Equal '#61 retry: the differing entries are both listed in the details' (($twoRow.Details -match '\b211\b') -and ($twoRow.Details -match '\b300\b')) True
# Abandoned frames are in the denominator: 30 retries over 100 transmitted + 20 abandoned is 25%, not 30%.
$failedAfter = New-WifiSnapshot $wifiT1 (New-WifiInterface $wifiGuid 1 @(0..5 | ForEach-Object { New-WifiPhy $_ 1100 20 130 25 400 5100 }))
$failedRow = (Get-WifiRows $mirrorBefore $failedAfter)[0]
Assert-Equal '#61 retry: frames abandoned after the retry limit are in the denominator' (($failedRow.Message -match '\b25%') -and -not ($failedRow.Message -match '\b30%')) True
Assert-Equal '#61 retry: and are named in the message' ($failedRow.Message -match '\b20\b') True
# Nothing transmitted: the counts are reported and no rate is computed.
$idleAfter = New-WifiSnapshot $wifiT1 (New-WifiInterface $wifiGuid 1 @(0..5 | ForEach-Object { New-WifiPhy $_ 1000 0 100 20 300 5000 }))
$idleRow = (Get-WifiRows $mirrorBefore $idleAfter)[0]
Assert-Equal '#61 retry: nothing transmitted is an Information row with no rate' (($idleRow.Status -eq 'INFO') -and -not ($idleRow.Message -match '%')) True
Assert-Equal '#61 retry: and it is not the measured sentence' ($idleRow.Message -eq $mirrorRow.Message) False
# The counters went backwards: the delta is not computed, both readings are shown.
$resetAfter = New-WifiSnapshot $wifiT1 (New-WifiInterface $wifiGuid 1 @(0..5 | ForEach-Object { New-WifiPhy $_ 900 0 10 2 30 500 }))
$resetRow = (Get-WifiRows $mirrorBefore $resetAfter)[0]
Assert-Equal '#61 retry: a counter that went backwards is an Unable-to-Check row' ("{0}/{1}" -f $resetRow.Status, $resetRow.Weightless) 'ERROR/True'
Assert-Equal '#61 retry: naming both readings' (($resetRow.Details -match 'Transmitted=1000') -and ($resetRow.Details -match 'Transmitted=900')) True
# Readings that could not be taken: one row, weightless, the reason in it; no wireless interface is Information.
$noneRows = @(Get-WifiRows (New-WifiSnapshot $wifiT0 @() 'none') (New-WifiSnapshot $wifiT1 @() 'none'))
Assert-Equal '#61 retry: no wireless interface is one Information row' ("{0}/{1}/{2}" -f $noneRows.Count, $noneRows[0].Status, $noneRows[0].Weightless) '1/INFO/True'
$addTypeRow = (Get-WifiRows (New-WifiSnapshot $wifiT0 @() 'addtype' 'refused by policy') $mirrorAfter)[0]
Assert-Equal '#61 retry: a reader that could not be compiled is Unable to Check' ("{0}/{1}" -f $addTypeRow.Status, $addTypeRow.Weightless) 'ERROR/True'
Assert-Equal '#61 retry: with the exception text in the details' ($addTypeRow.Details -match 'refused by policy') True
$openRow = (Get-WifiRows $mirrorBefore (New-WifiSnapshot $wifiT1 @() 'open' 'error 1062: The service has not been started'))[0]
Assert-Equal '#61 retry: a service that did not answer names its error' ($openRow.Message -match '1062') True
Assert-Equal '#61 retry: one row when the ending reading failed and the baseline did not' (@(Get-WifiRows $mirrorBefore (New-WifiSnapshot $wifiT1 @() 'error' 'boom'))).Count 1
Assert-Equal '#61 retry: no data at all is one Unable-to-Check row' ((Get-WifiRows $null $mirrorAfter)[0].Status) 'ERROR'
$missingRow = (Get-WifiRows (New-WifiSnapshot $wifiT0 @()) $mirrorAfter)[0]
Assert-Equal '#61 retry: an interface absent from the baseline has no delta' $missingRow.Status 'ERROR'
$queryRow = (Get-WifiRows $mirrorBefore (New-WifiSnapshot $wifiT1 (New-WifiInterface $wifiGuid 1 @() 5 'error 5: Access is denied')))[0]
Assert-Equal '#61 retry: a failed statistics query names its error' (($queryRow.Status -eq 'ERROR') -and ($queryRow.Message -match 'Access is denied')) True
$everyWifiRow = @($mirrorRow, $singleRow, $twoRow, $failedRow, $idleRow, $resetRow, $noneRows[0], $addTypeRow, $openRow, $missingRow, $queryRow)
Assert-Equal '#61 retry: every row this analysis writes is weightless' (@($everyWifiRow | Where-Object { -not $_.Weightless }).Count) 0
Assert-Equal '#61 retry: and every one carries the tag' (@($everyWifiRow | Where-Object { $_.Tag -ne 'wifi-retry' }).Count) 0
# The chain's oracle tells the aggregate reader-failure row from a per-interface error row by the first details line,
# which ends with the reader's language-neutral reason code on the aggregate row and never on the others (PR #52, round 2).
$reasonTail = '[:：]\s*(addtype|open|enumerate|error|none)\s*$'
$errorRow = (Get-WifiRows $mirrorBefore (New-WifiSnapshot $wifiT1 @() 'error' 'boom'))[0]
# An interface listed at only one of the two readings is a transition, not a wired machine (round 3): Unable to Check,
# weightless, the aggregate shape, naming the side that listed none and the other reading's failure where it had one.
$noneBeforeRow = (Get-WifiRows (New-WifiSnapshot $wifiT0 @() 'none') $mirrorAfter)[0]
$noneAfterRow = (Get-WifiRows $mirrorBefore (New-WifiSnapshot $wifiT1 @() 'none'))[0]
Assert-Equal '#61 retry: an interface listed at only one reading is Unable to Check, not a wired machine' ("{0}/{1}/{2}/{3}" -f $noneBeforeRow.Status, $noneBeforeRow.Weightless, $noneAfterRow.Status, $noneAfterRow.Weightless) 'ERROR/True/ERROR/True'
Assert-Equal '#61 retry: and its sentence is not the wired-machine sentence' (($noneBeforeRow.Message -eq $noneRows[0].Message) -or ($noneAfterRow.Message -eq $noneRows[0].Message)) False
Assert-Equal '#61 retry: a none beside a failed reading names the other failure too' (((Get-WifiRows (New-WifiSnapshot $wifiT0 @() 'none') (New-WifiSnapshot $wifiT1 @() 'open' 'error 1062: stopped'))[0]).Details -match '1062') True
Assert-Equal '#61 shape: an aggregate reader-failure row ends its first details line with the reason code' (@(@($addTypeRow, $openRow, $errorRow, $noneBeforeRow, $noneAfterRow) | Where-Object { (Get-DetailLineAt $_ 0) -match $reasonTail }).Count) 5
Assert-Equal '#61 shape: and no per-interface error row does' (@(@($resetRow, $missingRow, $queryRow) | Where-Object { (Get-DetailLineAt $_ 0) -match $reasonTail }).Count) 0
# A second interface listed at the start and not at the end (round 5): its own Unable-to-Check row, per-interface shaped,
# while the interface that stayed is measured exactly as before.
$guidB = '0b3f7c2e-1111-4a2b-9c3d-000000000002'
$twoStart = New-WifiSnapshot $wifiT0 @((New-WifiInterface $wifiGuid 1 @(0..5 | ForEach-Object { New-WifiPhy $_ 1000 0 100 20 300 5000 })), (New-WifiInterface $guidB 1 @(New-WifiPhy 0 10 0 1 0 1 10)))
$goneRows = @(Get-WifiRows $twoStart $mirrorAfter)
Assert-Equal '#61 retry: an interface listed at the start and not at the end gets its own row' $goneRows.Count 2
$goneRow = @($goneRows | Where-Object { $_.Status -eq 'ERROR' })
Assert-Equal '#61 retry: and it is Unable to Check, weightless, and not the aggregate shape' ("{0}/{1}/{2}" -f $goneRow.Count, $goneRow[0].Weightless, ((Get-DetailLineAt $goneRow[0] 0) -match $reasonTail)) '1/True/False'
Assert-Equal '#61 retry: while the interface that stayed is measured as before' (@($goneRows | Where-Object { $_.Status -eq 'INFO' })[0].Message) $mirrorRow.Message
# Every per-interface row names its interface GUID on a details line (round 7), which is what lets the oracle hold each
# interface to exactly one row; the aggregate rows name none.
Assert-Equal '#61 shape: every per-interface row names its interface GUID' (@(@($mirrorRow, $idleRow, $resetRow, $missingRow, $queryRow, $goneRow[0]) | Where-Object { $_.Details -notmatch ([regex]::Escape($wifiGuid)) -and $_.Details -notmatch ([regex]::Escape($guidB)) }).Count) 0
Assert-Equal '#61 shape: and the aggregate rows name none' (@(@($addTypeRow, $openRow, $errorRow, $noneBeforeRow, $noneRows[0]) | Where-Object { $_.Details -match '[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}' }).Count) 0
# The rest of the matrix, walked in one pass before round 11 (PR #52): both readings failing, a failure beside a
# one-sided none, an interface that stayed beside one that came and one that went, no PHY entry in common, and a
# query that failed at the start rather than at the end.
$bothFailedRow = (Get-WifiRows (New-WifiSnapshot $wifiT0 @() 'addtype' 'refused') (New-WifiSnapshot $wifiT1 @() 'open' 'error 1062: stopped'))[0]
Assert-Equal '#61 matrix: two failed readings are one row for the first, naming the second' (($bothFailedRow.Status -eq 'ERROR') -and ((Get-DetailLineAt $bothFailedRow 0) -match $reasonTail) -and ($bothFailedRow.Details -match '1062')) True
$failThenNoneRow = (Get-WifiRows (New-WifiSnapshot $wifiT0 @() 'enumerate' 'error 5: denied') (New-WifiSnapshot $wifiT1 @() 'none'))[0]
Assert-Equal '#61 matrix: a failed reading beside a one-sided none reports the failure and names the none' (($failThenNoneRow.Status -eq 'ERROR') -and ((Get-DetailLineAt $failThenNoneRow 0) -match 'enumerate\s*$') -and ($failThenNoneRow.Details -match 'none')) True
$guidC = '5d1e2f3a-2222-4b3c-8d4e-000000000003'
$mixedAfter = New-WifiSnapshot $wifiT1 @((New-WifiInterface $wifiGuid 1 @(0..5 | ForEach-Object { New-WifiPhy $_ 1211 0 166 42 498 5342 })), (New-WifiInterface $guidC 1 @(New-WifiPhy 0 5 0 0 0 0 5)))
$mixedRows = @(Get-WifiRows $twoStart $mixedAfter)
Assert-Equal '#61 matrix: one that stayed, one that went and one that came are three rows' $mixedRows.Count 3
Assert-Equal '#61 matrix: each naming its own interface once' ((@($mixedRows | Where-Object { $_.Details -match ([regex]::Escape($wifiGuid)) }).Count -eq 1) -and (@($mixedRows | Where-Object { $_.Details -match ([regex]::Escape($guidB)) }).Count -eq 1) -and (@($mixedRows | Where-Object { $_.Details -match ([regex]::Escape($guidC)) }).Count -eq 1)) True
Assert-Equal '#61 matrix: the two transitions are Unable to Check and the one that stayed is measured' ((@($mixedRows | Where-Object { $_.Status -eq 'ERROR' }).Count -eq 2) -and (@($mixedRows | Where-Object { $_.Status -eq 'INFO' })[0].Message -eq $mirrorRow.Message)) True
$noCommonAfter = New-WifiSnapshot $wifiT1 (New-WifiInterface $wifiGuid 1 @((New-WifiPhy 6 1 0 0 0 0 1), (New-WifiPhy 7 1 0 0 0 0 1)))
$noCommonRow = (Get-WifiRows $mirrorBefore $noCommonAfter)[0]
Assert-Equal '#61 matrix: readings with no PHY entry in common are Unable to Check, weightless, named' (($noCommonRow.Status -eq 'ERROR') -and $noCommonRow.Weightless -and ($noCommonRow.Details -match ([regex]::Escape($wifiGuid)))) True
$startQueryRow = (Get-WifiRows (New-WifiSnapshot $wifiT0 (New-WifiInterface $wifiGuid 1 @() 5 'error 5: Access is denied at the start')) $mirrorAfter)[0]
Assert-Equal '#61 matrix: a query that failed at the start names that failure' (($startQueryRow.Status -eq 'ERROR') -and ($startQueryRow.Message -match 'at the start')) True
Assert-Equal '#61 retry: the connection states are words' (((Get-WifiInterfaceStateText 1) -ne (Get-WifiInterfaceStateText 4)) -and -not [string]::IsNullOrWhiteSpace((Get-WifiInterfaceStateText 1))) True
Assert-Equal '#61 retry: an unknown state keeps its number' ((Get-WifiInterfaceStateText 9) -match '9') True
Assert-Equal '#61 retry: a Win32 error keeps its number' ((Get-Win32ErrorText 1062) -match '1062') True
# The reader: read off the AST, then a refused compile, then for real on whatever this machine is.
# The Add-Type lives in Get-WlanApiType since backlog #62, shared by the retry reader and the interface-state reader;
# the two properties the retry half pinned - inside a try, and only where the type is not there yet - are held there.
Assert-Equal '#61 reader: Add-Type is called inside a try' ((Get-FunctionBody 'Get-WlanApiType') -match 'try \{\s*Add-Type -Namespace NetworkHealthCheck') True
Assert-Equal '#61 reader: and only where the type is not there yet' ((Get-FunctionBody 'Get-WlanApiType') -match '"NetworkHealthCheck\.WlanApi" -as \[type\]') True
Assert-Equal '#62 reader: the retry reader and the state reader both take the type from Get-WlanApiType and neither compiles its own' (((Get-FunctionBody 'Get-WifiRetrySnapshot') -match 'Get-WlanApiType') -and ((Get-FunctionBody 'Get-WlanInterfaceStates') -match 'Get-WlanApiType') -and ((Get-FunctionBody 'Get-WifiRetrySnapshot') -notmatch 'Add-Type') -and ((Get-FunctionBody 'Get-WlanInterfaceStates') -notmatch 'Add-Type')) True
$analysisBody = Get-FunctionBody 'Compare-WifiRetryCounters'
Assert-Equal '#61 analysis: every row it writes declares the marking' (([regex]::Matches($analysisBody, 'Add-CheckResult ')).Count -eq ([regex]::Matches($analysisBody, ' -Weightless')).Count) True
Assert-Equal '#61 analysis: and the tag is the same literal on every one' (([regex]::Matches($analysisBody, '-Tag "wifi-retry"')).Count -eq ([regex]::Matches($analysisBody, 'Add-CheckResult ')).Count) True
Assert-Equal '#61 options: the flag is validated with the other check flags' ((Get-FunctionBody 'Test-ConfigurationSemantics') -match '"DriverInfo", "WifiRetryCounters"') True
Assert-Equal '#61 options: and projected into the run options' ((Get-FunctionBody 'Set-RunOptions') -match 'WifiRetryCounters = Test-IsTrueFlag \$config\.Checks\.WifiRetryCounters') True
Assert-Equal '#61 steps: the run reads and analyses the counters only where the flag is on' (([regex]::Matches((Get-FunctionBody 'Run-AllChecks'), 'if \(\$wifiRetryEnabled\) \{')).Count) 3
function Add-Type { [CmdletBinding()] param($Namespace, $Name, $MemberDefinition) throw "compiler refused" }
$refused = Get-WifiRetrySnapshot
Remove-Item function:Add-Type -ErrorAction SilentlyContinue
Assert-Equal '#61 reader: a refused compile is the addtype reason, with the text' ("{0}/{1}" -f $refused.Error, ($refused.ErrorText -match 'compiler refused')) 'addtype/True'
$live = Get-WifiRetrySnapshot
# A listed interface whose statistics query failed - a disconnected or driver-incompatible adapter - is a supported
# reading too (round 10): it carries the query's error and no PHY entries, and the tool writes its Unable-to-Check row.
Assert-Equal '#61 reader: read for real on this machine - every interface with PHY entries or a query error, or a named reason' ((([string]$live.Error -eq '') -and (@($live.Interfaces).Count -ge 1) -and (@(@($live.Interfaces) | Where-Object { -not ((@($_.Phys).Count -ge 1) -or ([int]$_.QueryError -ne 0)) }).Count -eq 0)) -or ([string]$live.Error -in @('none', 'open', 'enumerate'))) True
$liveText = 'no reading: ' + $live.Error + ' ' + $live.ErrorText
if ([string]$live.Error -eq '') { $liveText = ('{0} interface(s); first: {1}, state {2}, {3} PHY entries' -f @($live.Interfaces).Count, $live.Interfaces[0].Description, $live.Interfaces[0].State, @($live.Interfaces[0].Phys).Count) }
Write-Output ('[INFO] #61 reader on this machine: ' + $liveText)

# backlog #52: the connection times of a TCP target that answered, and the SYN retransmissions its sockets counted -
# the one retransmission figure a run can attribute to a target. New-TcpConnectSample does the counting and
# Get-TcpConnectSampleText the wording, on synthetic results, so that both scripts are held to the same rules without
# a network - with the sockets' own counts, and without them, where the times stand in as a proxy (PR #53, round 1);
# Get-TcpInitialRto is held to its two sources with the cmdlet mocked, then read for real; Invoke-TcpConnectionTest is
# run for real against a listener on the loopback, which every machine has.
function New-TcpResult([bool]$Success, [int]$Ms, [string]$Remote = '203.0.113.5', [string]$Local = '192.0.2.10', [int]$SynRetrans = 0, [int]$RttUs = 6301, [string]$TelemetryError = '') {
    $errorText = ''
    if (-not $Success) { $errorText = 'Cause: the target refused the connection [SocketError ConnectionRefused]' + "`r`n" + 'No connection could be made because the target machine actively refused it' }
    return [pscustomobject]@{ Success = $Success; Host = 'h'; Port = 443; ElapsedMs = [double]$Ms; Error = $errorText; RemoteAddress = $(if ($Success) { $Remote } else { '' }); LocalAddress = $(if ($Success) { $Local } else { '' }); SynRetrans = $(if ($Success) { $SynRetrans } else { -1 }); RttUs = $(if ($Success) { $RttUs } else { -1 }); TelemetryError = $TelemetryError }
}
function New-TcpResultNoTelemetry([bool]$Success, [int]$Ms) { return (New-TcpResult $Success $Ms '203.0.113.5' '192.0.2.10' -1 -1 'The attempted operation is not supported for the type of object referenced') }
function Test-HasNumber([string]$Text, [int]$Number) { return ($Text -match ('(^|[^0-9.])' + $Number + '([^0-9.]|$)')) }
$rto1000 = [pscustomobject]@{ Ms = 1000; Source = 'default' }
# Counting, with the sockets' own counts and without them.
$quiet = New-TcpConnectSample -First (New-TcpResult $true 23) -Repeats @((New-TcpResult $true 7), (New-TcpResult $true 7), (New-TcpResult $true 7)) -Planned 4 -HostIsName $false -InitialRto $rto1000
Assert-Equal '#52 sample: four connections to an address are four times, four counts of zero, complete' ("{0}/{1}/{2}/{3}/{4}" -f $quiet.Attempted, (@($quiet.Times) -join ','), (@($quiet.SynRetrans) -join ','), $quiet.TelemetryComplete, $quiet.RetransmittedSyns) '4/23,7,7,7/0,0,0,0/True/0'
$slow = New-TcpConnectSample -First (New-TcpResult $true 1032 '203.0.113.5' '192.0.2.10' 1) -Repeats @((New-TcpResult $true 7), (New-TcpResult $true 7), (New-TcpResult $true 7)) -Planned 4 -HostIsName $false -InitialRto $rto1000
Assert-Equal '#52 sample: a SYN the socket counted as sent again is summed, and the slow time beside it is above the timeout too' ("{0}/{1}/{2}" -f (@($slow.SynRetrans) -join ','), $slow.RetransmittedSyns, (@($slow.AtOrAbove) -join ',')) '1,0,0,0/1/1032'
$twice = New-TcpConnectSample -First (New-TcpResult $true 3100 '203.0.113.5' '192.0.2.10' 2) -Repeats @((New-TcpResult $true 1050 '203.0.113.5' '192.0.2.10' 1)) -Planned 2 -HostIsName $false -InitialRto $rto1000
Assert-Equal '#52 sample: counts add across connections' $twice.RetransmittedSyns 3
$atBoundary = New-TcpConnectSample -First (New-TcpResultNoTelemetry $true 1000) -Repeats @() -Planned 1 -HostIsName $false -InitialRto $rto1000
$underBoundary = New-TcpConnectSample -First (New-TcpResultNoTelemetry $true 999) -Repeats @() -Planned 1 -HostIsName $false -InitialRto $rto1000
Assert-Equal '#52 sample: without the counters the proxy is the time, its boundary inclusive, and the count is marked incomplete' ("{0}/{1}/{2}" -f @($atBoundary.AtOrAbove).Count, @($underBoundary.AtOrAbove).Count, $atBoundary.TelemetryComplete) '1/0/False'
$named = New-TcpConnectSample -First (New-TcpResult $true 24) -Repeats @((New-TcpResult $true 9), (New-TcpResult $true 6), (New-TcpResult $true 7)) -Planned 4 -HostIsName $true -InitialRto $rto1000
Assert-Equal '#52 sample: a name target with the counters lists four times and four counts, where the proxy would read three' ("{0}/{1}/{2}" -f (@($named.Times) -join ','), @($named.SynRetrans).Count, $named.Judged) '24,9,6,7/4/3'
$namedProxy = New-TcpConnectSample -First (New-TcpResultNoTelemetry $true 1500) -Repeats @((New-TcpResultNoTelemetry $true 9)) -Planned 2 -HostIsName $true -InitialRto $rto1000
Assert-Equal '#52 sample: without the counters a slow first connection of a name target is not read as a retransmission' ("{0}/{1}" -f @($namedProxy.AtOrAbove).Count, $namedProxy.Judged) '0/1'
$partial = New-TcpConnectSample -First (New-TcpResult $true 23) -Repeats @((New-TcpResultNoTelemetry $true 7)) -Planned 2 -HostIsName $false -InitialRto $rto1000
Assert-Equal '#52 sample: one socket that could not be asked makes the count incomplete, and the reason travels' ("{0}/{1}" -f $partial.TelemetryComplete, ($partial.TelemetryError -match 'not supported')) 'False/True'
$broken = New-TcpConnectSample -First (New-TcpResult $true 23) -Repeats @((New-TcpResult $false 4000)) -Planned 4 -HostIsName $false -InitialRto $rto1000
Assert-Equal '#52 sample: a failed repeat is named by its position and keeps its error; the times and counts are the successes' ("{0}/{1}/{2}/{3}/{4}" -f $broken.Attempted, $broken.FailedIndex, (@($broken.Times) -join ','), (@($broken.SynRetrans) -join ','), ($broken.FailedError -match 'ConnectionRefused')) '2/2/23/0/True'
Assert-Equal '#52 sample: the timeout and its source travel with the sample, the addresses come from the first connection' ("{0}/{1}/{2}/{3}" -f $quiet.RtoMs, $quiet.RtoSource, $quiet.RemoteAddress, $quiet.LocalAddress) '1000/default/203.0.113.5/192.0.2.10'
$custom = New-TcpConnectSample -First (New-TcpResultNoTelemetry $true 1500) -Repeats @() -Planned 1 -HostIsName $false -InitialRto ([pscustomobject]@{ Ms = 2000; Source = 'setting' })
Assert-Equal '#52 sample: a timeout the setting reports is the one the proxy reads against' ("{0}/{1}" -f $custom.RtoMs, @($custom.AtOrAbove).Count) '2000/0'
# The text, in whichever language this script speaks: the numbers a reader is owed are in it. The reading line is
# always the last.
$quietText = Get-TcpConnectSampleText -Sample $quiet -HostName '1.1.1.1' -Port 443
Assert-Equal '#52 text: with the counters the message lists the times and the four counts, and neither the timeout nor a proxy' (($quietText.Message -match '23 / 7 / 7 / 7 ms') -and ($quietText.Message -match '0 / 0 / 0 / 0') -and ($quietText.Message -notmatch '1000 ms') -and ($quietText.Message -notmatch 'proxy|代理')) True
$slowText = Get-TcpConnectSampleText -Sample $slow -HostName '1.1.1.1' -Port 443
Assert-Equal '#52 text: a counted retransmission is in the message per connection and in total' (($slowText.Message -match '1 / 0 / 0 / 0') -and (Test-HasNumber $slowText.Message 1) -and ($slowText.Message -match 'SYN')) True
$quietCounters = @($quietText.Lines | Where-Object { $_ -match 'SIO_TCP_INFO' })
Assert-Equal '#52 text: the counters line names the source, the counts and the round-trip estimates in ms' (($quietCounters.Count -eq 1) -and ($quietCounters[0] -match '0 / 0 / 0 / 0') -and ($quietCounters[0] -match '6\.3 / 6\.3 / 6\.3 / 6\.3 ms') -and ($quietCounters[0] -match 'SynRetrans')) True
$quietRto = @($quietText.Lines | Where-Object { $_ -match 'RTO' })
Assert-Equal '#52 text: the first line names the target and the local address; the RTO line carries the value, its source and the check' ((@($quietText.Lines)[0] -match '1\.1\.1\.1:443') -and (@($quietText.Lines)[0] -match '192\.0\.2\.10') -and ($quietRto.Count -eq 1) -and ($quietRto[0] -match '1000 ms') -and ($quietRto[0] -match 'Get-NetTCPSetting') -and ($quietRto[0] -match 'netsh int tcp show global')) True
$quietReading = [string](@($quietText.Lines)[-1])
Assert-Equal '#52 text: the reading line with the counters carries the total and the connection count, and no proxy' ((Test-HasNumber $quietReading 0) -and (Test-HasNumber $quietReading 4) -and ($quietReading -match 'SYN') -and ($quietReading -notmatch 'proxy|代理')) True
$customText = Get-TcpConnectSampleText -Sample $custom -HostName '1.1.1.1' -Port 443
$customRto = @($customText.Lines | Where-Object { $_ -match 'RTO' })
Assert-Equal '#52 text: a timeout read from the setting names the property and does not call itself assumed' (($customRto.Count -eq 1) -and ($customRto[0] -match '2000 ms') -and ($customRto[0] -match 'InitialRtoMs') -and ($customRto[0] -notmatch 'netsh') -and ($customText.Message -match '2000 ms') -and ($customText.Message -notmatch '2000 ms \(|2000 ms（')) True
$proxyText = Get-TcpConnectSampleText -Sample $atBoundary -HostName '1.1.1.1' -Port 443
Assert-Equal '#52 text: without the counters the message names the assumed timeout as assumed and the count as a proxy, and the details say why' (($proxyText.Message -match '1000 ms \(|1000 ms（') -and ($proxyText.Message -match 'proxy|代理') -and (Test-HasNumber $proxyText.Message 1) -and (@($proxyText.Lines | Where-Object { $_ -match 'SIO_TCP_INFO' -and $_ -match '1703' -and $_ -match 'not supported' }).Count -eq 1) -and ([string](@($proxyText.Lines)[-1]) -match 'proxy|代理')) True
Assert-Equal '#52 text: the proxy reading rules nothing out below the timeout without saying the timeout may not be the connection''s; the counted reading has no such clause' ((([string](@($proxyText.Lines)[-1]) -match 'cannot confirm|無法確認') -and ($quietReading -notmatch 'cannot confirm|無法確認'))) True
$slowProxy = New-TcpConnectSample -First (New-TcpResultNoTelemetry $true 1032) -Repeats @((New-TcpResultNoTelemetry $true 7), (New-TcpResultNoTelemetry $true 7), (New-TcpResultNoTelemetry $true 7)) -Planned 4 -HostIsName $false -InitialRto $rto1000
$slowProxyText = Get-TcpConnectSampleText -Sample $slowProxy -HostName '1.1.1.1' -Port 443
Assert-Equal '#52 text: the proxy says one of four reached the timeout, with the SYN sentence and the proxy caveat' (($slowProxyText.Message -match '1032 / 7 / 7 / 7 ms') -and (Test-HasNumber $slowProxyText.Message 1) -and (Test-HasNumber $slowProxyText.Message 4) -and ($slowProxyText.Message -match 'SYN') -and ($slowProxyText.Message -match 'proxy|代理')) True
Assert-Equal '#52 text: and the proxy message calls the boundary a place a retransmission could appear, never the moment one happened' (($slowProxyText.Message -match 'could appear|可能出現') -and ($slowProxyText.Message -notmatch 'is when a SYN is sent again|正是 SYN 被重送')) True
$namedText = Get-TcpConnectSampleText -Sample $named -HostName 'www.example.com' -Port 443
Assert-Equal '#52 text: a name target with the counters names the address it resolved to and counts all four' ((@($namedText.Lines)[0] -match 'www\.example\.com:443') -and (@($namedText.Lines)[0] -match '203\.0\.113\.5') -and ($namedText.Message -match '0 / 0 / 0 / 0')) True
$namedProxyText = Get-TcpConnectSampleText -Sample (New-TcpConnectSample -First (New-TcpResultNoTelemetry $true 24) -Repeats @((New-TcpResultNoTelemetry $true 9), (New-TcpResultNoTelemetry $true 6), (New-TcpResultNoTelemetry $true 7)) -Planned 4 -HostIsName $true -InitialRto $rto1000) -HostName 'www.example.com' -Port 443
Assert-Equal '#52 text: a name target without the counters reads three of four and names the address it resolved to' ((Test-HasNumber $namedProxyText.Message 3) -and (Test-HasNumber $namedProxyText.Message 0) -and (@($namedProxyText.Lines)[0] -match '203\.0\.113\.5')) True
$aloneText = Get-TcpConnectSampleText -Sample (New-TcpConnectSample -First (New-TcpResultNoTelemetry $true 24) -Repeats @() -Planned 1 -HostIsName $true -InitialRto $rto1000) -HostName 'www.example.com' -Port 443
Assert-Equal '#52 text: a name target with one connection and no counters says nothing was read, and prints no count of nothing' (($aloneText.Message -match '1000 ms') -and ($aloneText.Message -notmatch '0[^0-9]+0') -and ([string](@($aloneText.Lines)[-1]) -notmatch '(^|[^0-9.])0([^0-9.]|$).*(^|[^0-9.])0([^0-9.]|$)')) True
$brokenText = Get-TcpConnectSampleText -Sample $broken -HostName '1.1.1.1' -Port 443
Assert-Equal '#52 text: a failed repeat is in the message by its position and in the details with its error' ((Test-HasNumber $brokenText.Message 2) -and ((@($brokenText.Lines) -join "`n") -match 'ConnectionRefused')) True
# The timeout: its two sources, with the cmdlet mocked, then the real one.
function Get-NetTCPSetting { param($SettingName, $ErrorAction) return [pscustomobject]@{ SettingName = $SettingName; InitialRtoMs = [uint32]2000 } }
$fromSetting = Get-TcpInitialRto
Assert-Equal '#52 rto: a value the cmdlet reports is used and named as the setting' ("{0}/{1}" -f $fromSetting.Ms, $fromSetting.Source) '2000/setting'
function Get-NetTCPSetting { param($SettingName, $ErrorAction) return [pscustomobject]@{ SettingName = $SettingName; InitialRtoMs = $null } }
$fromNull = Get-TcpInitialRto
function Get-NetTCPSetting { param($SettingName, $ErrorAction) return [pscustomobject]@{ SettingName = $SettingName } }
$fromAbsent = Get-TcpInitialRto
function Get-NetTCPSetting { param($SettingName, $ErrorAction) throw 'no such cmdlet' }
$fromThrow = Get-TcpInitialRto
Remove-Item function:Get-NetTCPSetting -ErrorAction SilentlyContinue
Assert-Equal '#52 rto: an empty value, an absent property and a cmdlet that throws are all the 1000 ms default, and say so' ("{0}/{1}|{2}/{3}|{4}/{5}" -f $fromNull.Ms, $fromNull.Source, $fromAbsent.Ms, $fromAbsent.Source, $fromThrow.Ms, $fromThrow.Source) '1000/default|1000/default|1000/default'
$liveRto = Get-TcpInitialRto
Assert-Equal '#52 rto: read for real on this machine - within the documented 300 to 3000 ms, from one of the two sources' (($liveRto.Ms -ge 300) -and ($liveRto.Ms -le 3000) -and ($liveRto.Source -in @('setting', 'default'))) True
Write-Output ('[INFO] #52 initial RTO on this machine: ' + $liveRto.Ms + ' ms (' + $liveRto.Source + ')')
# The socket, for real, on the loopback: the addresses it reports are the ones the repeats and the row use, and its
# own counters are read where this build has SIO_TCP_INFO (Windows 10 version 1703 and later) - else the reason is kept.
$listener = New-Object System.Net.Sockets.TcpListener -ArgumentList ([System.Net.IPAddress]::Loopback), 0
$listener.Start()
try {
    $loopback = Invoke-TcpConnectionTest -HostName '127.0.0.1' -Port ([int]$listener.LocalEndpoint.Port) -TimeoutMs 4000
    Assert-Equal '#52 connect: a real handshake on the loopback reports both addresses beside its time' ("{0}/{1}/{2}/{3}" -f $loopback.Success, $loopback.RemoteAddress, $loopback.LocalAddress, ($loopback.ElapsedMs -ge 0)) 'True/127.0.0.1/127.0.0.1/True'
    Assert-Equal '#52 connect: and the socket''s own counters - no SYN sent again, a round-trip estimate - or the reason they could not be read' ((($loopback.SynRetrans -eq 0) -and ($loopback.RttUs -ge 0) -and ([string]$loopback.TelemetryError -eq '')) -or (($loopback.SynRetrans -eq -1) -and -not [string]::IsNullOrWhiteSpace([string]$loopback.TelemetryError))) True
    Write-Output ('[INFO] #52 loopback socket on this machine: SynRetrans ' + $loopback.SynRetrans + ', RttUs ' + $loopback.RttUs + $(if ([string]$loopback.TelemetryError -ne '') { ' (' + $loopback.TelemetryError + ')' } else { '' }))
}
finally { $listener.Stop() }
# The run and the read: off the AST, because the loop needs a target that answers and the struct layout is a contract.
$connectivityBody = Get-FunctionBody 'Test-ConnectivityTargets'
Assert-Equal '#52 run: the repeats are made only after a connection succeeded, go to the address it reached, and stop at the first that fails' ($connectivityBody -match '(?s)if \(\$result\.Success\) \{.*?\$repeatHost = \[string\]\$result\.RemoteAddress.*?for \(\$i = 2; \$i -le \$connectCount; \$i\+\+\) \{.*?if \(-not \$repeat\.Success\) \{ break \}') True
Assert-Equal '#52 run: the count is PingCount, never below one, and the timeout is read once a connection has succeeded' (($connectivityBody -match '\$connectCount = \[math\]::Max\(1, \(ConvertTo-IntSafe \$script:Config\.Tests\.PingCount 4\)\)') -and ($connectivityBody -match '(?s)if \(\$result\.Success\) \{.*?if \(\$null -eq \$initialRto\) \{ \$initialRto = Get-TcpInitialRto \}')) True
$connectBody = Get-FunctionBody 'Invoke-TcpConnectionTest'
Assert-Equal '#52 read: SIO_TCP_INFO is asked for version 0 inside a try, and SynRetrans and RttUs are read at the documented offsets of TCP_INFO_v0' ($connectBody -match '(?s)try \{\s*\$infoOut = New-Object byte\[\] 128.*?IOControl\(\[int\]-671088601, \[System\.BitConverter\]::GetBytes\(\[uint32\]0\), \$infoOut\).*?if \(\$infoBytes -ge 88\).*?\$infoOut\[84\].*?ToUInt32\(\$infoOut, 20\).*?catch') True

# --- backlog #61, the other half (v1.2.13): the access point sampled, the access-point-is-the-gateway hint, the spread ---
# Language-independent throughout, as the retry half's cases are: statuses, scopes, tags, the values a sentence
# interpolates and the shape of the details, never the wording.
$macShape = '([0-9a-fA-F]{2}[:-]){5}[0-9a-fA-F]{2}'
$guidShape = '[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}'
# The parser keeps the interface's own GUID, found by its label rather than by its shape (the tool's copy of the exposure
# PR #52 rounds 11 and 12 closed in the chain's reader): a network, a profile and an adapter renamed to a UUID sit inside
# the block and start no interface of their own.
$w = @(ConvertFrom-NetshWlanOutput -Lines $win11)
Assert-Equal '#61 parser: the interface GUID is kept, lower-case' $w[0].Guid 'e6b08c8a-3feb-4c3e-88c3-dee94dd2f0eb'
$uuidNamed = @('', 'There are 2 interfaces on the system:', '', '    Name                   : Wi-Fi', '    Description            : Fixture Wi-Fi 6E', '    GUID                   : E6B08C8A-3FEB-4C3E-88C3-DEE94DD2F0EB', '    Physical address       : 00:11:22:33:44:55', '    State                  : connected', '    SSID                   : 5d1e2f3a-2222-4b3c-8d4e-000000000003', '    BSSID                  : 66:77:88:99:aa:bb', '    Radio type             : 802.11ax', '    Channel                : 36', '    Receive rate (Mbps)    : 100', '    Transmit rate (Mbps)   : 100', '    Signal                 : 70%', '    Profile                : 5d1e2f3a-2222-4b3c-8d4e-000000000003', '', '    Name                   : 7c2d3e4f-3333-4c5d-9e6f-000000000004', '    Description            : Fixture USB', '    GUID                   : 0b3f7c2e-1111-4a2b-9c3d-000000000002', '    Physical address       : 00:11:22:33:44:66', '    State                  : disconnected', '')
$w = @(ConvertFrom-NetshWlanOutput -Lines $uuidNamed)
Assert-Equal '#61 parser: a UUID-shaped network, profile and adapter name start no interface - two blocks are two' $w.Count 2
Assert-Equal '#61 parser: and the two GUIDs are the labelled ones' (($w | ForEach-Object { $_.Guid }) -join ',') 'e6b08c8a-3feb-4c3e-88c3-dee94dd2f0eb,0b3f7c2e-1111-4a2b-9c3d-000000000002'
Assert-Equal '#61 parser: the UUID-shaped SSID is still the SSID and the BSSID is still read' ("{0}/{1}/{2}" -f $w[0].Connected, $w[0].Ssid, $w[0].Bssid) 'True/5d1e2f3a-2222-4b3c-8d4e-000000000003/66:77:88:99:aa:bb'
Assert-Equal '#61 parser: the renamed adapter keeps its name and is not connected' ("{0}/{1}" -f $w[1].Name, $w[1].Connected) '7c2d3e4f-3333-4c5d-9e6f-000000000004/False'
$fullWidth = @('    名稱：Wi-Fi', '    描述：Fixture', '    GUID：e6b08c8a-3feb-4c3e-88c3-dee94dd2f0eb', '    實體位址：10:f6:0a:db:fc:e5', '    狀態：已連線', '    SSID：Office', '    BSSID：5c:e2:8c:11:22:33', '    訊號：55%')
$w = @(ConvertFrom-NetshWlanOutput -Lines $fullWidth)
Assert-Equal '#61 parser: the GUID label is read before a full-width colon too' ("{0}/{1}/{2}" -f $w.Count, $w[0].Guid, $w[0].Bssid) '1/e6b08c8a-3feb-4c3e-88c3-dee94dd2f0eb/5c:e2:8c:11:22:33'
$noLabel = @($win11 | ForEach-Object { $_ -replace '^    GUID  ', '    識別碼' })
$w = @(ConvertFrom-NetshWlanOutput -Lines $noLabel)
Assert-Equal '#61 parser: an output with no GUID label falls back to the shape rule and still yields the interface' ("{0}/{1}/{2}" -f $w.Count, $w[0].Guid, $w[0].Bssid) '1/e6b08c8a-3feb-4c3e-88c3-dee94dd2f0eb/ac:b6:87:a6:81:a0'

# The sample envelope, once for real on whatever this machine has, and its keeper.
$liveSample = Get-WifiAssociationSample -Moment 'start'
Assert-Equal '#61 sample: a real reading names its moment and carries a time' ("{0}/{1}" -f $liveSample.Moment, ($liveSample.Timestamp -is [datetime])) 'start/True'
Assert-Equal '#61 sample: and either lists interfaces without an error or names the reason' ((([string]$liveSample.Error -eq '') -and ($null -ne $liveSample.Interfaces)) -or ([string]$liveSample.Error -in @('netsh', 'exception'))) True
Write-Output ('[INFO] #61 access-point sample on this machine: ' + @($liveSample.Interfaces).Count + ' interface(s)' + $(if ([string]$liveSample.Error -ne '') { ', error ' + $liveSample.Error } else { '' }))
$script:WifiAssociationSamples = $null
$kept = Add-WifiAssociationSample -Moment 'end'
Assert-Equal '#61 sample: the keeper creates the list when there is none and appends in order' ("{0}/{1}" -f @($script:WifiAssociationSamples).Count, $script:WifiAssociationSamples[0].Moment) '1/end'
[void](Add-WifiAssociationSample -Moment 'middle')
Assert-Equal '#61 sample: and goes on appending' (@($script:WifiAssociationSamples | ForEach-Object { $_.Moment }) -join ',') 'end,middle'

# The analysis, on fixtures shaped like the envelope.
function New-AssocInterface($guid, $name, $mac, $ssid, $bssid) { return [pscustomobject]@{ Name = $name; Description = 'Fixture'; Guid = $guid; PhysicalAddress = $mac; Connected = (-not [string]::IsNullOrWhiteSpace($bssid)); Ssid = $ssid; Bssid = $bssid } }
function New-AssocSample($moment, $stamp, $interfaces, $error = '', $errorText = '') { return [pscustomobject]@{ Moment = $moment; Timestamp = $stamp; Interfaces = @($interfaces); Error = $error; ErrorText = $errorText; Diagnostics = '' } }
function Get-AssocRows($samples) { $script:TcpRows = New-Object System.Collections.ArrayList; Compare-WifiAssociation -Samples @($samples); return @($script:TcpRows) }
$assocT0 = Get-Date '2026-09-12 10:00:00'; $assocT1 = $assocT0.AddSeconds(12); $assocT2 = $assocT0.AddSeconds(25)
$apA = 'ac:b6:87:a6:81:a0'; $apB = '08:26:97:7f:28:91'
$ifA = { param($bssid, $ssid = 'kevin_5g') New-AssocInterface 'e6b08c8a-3feb-4c3e-88c3-dee94dd2f0eb' 'Wi-Fi' '10:f6:0a:db:fc:e5' $ssid $bssid }
$steady = @((New-AssocSample 'start' $assocT0 (& $ifA $apA)), (New-AssocSample 'middle' $assocT1 (& $ifA $apA)), (New-AssocSample 'end' $assocT2 (& $ifA $apA)))
$steadyRows = @(Get-AssocRows $steady)
Assert-Equal '#61 assoc: one interface on one access point is one row' $steadyRows.Count 1
$steadyRow = $steadyRows[0]
Assert-Equal '#61 assoc: an Information row in the IT scope, tagged, and not marked (IT rows carry no weight to remove)' ("{0}/{1}/{2}/{3}" -f $steadyRow.Status, $steadyRow.Scope, $steadyRow.Tag, $steadyRow.Weightless) 'INFO/IT/wifi-association/False'
Assert-Equal '#61 assoc: the message names the access point, the sample count and the seconds between the first and the last' (($steadyRow.Message -match [regex]::Escape($apA)) -and ($steadyRow.Message -match '\b3\b') -and ($steadyRow.Message -match '\b25\b')) True
Assert-Equal '#61 assoc: the details list every sample with its access point and name the interface GUID once' ("{0}/{1}" -f ([regex]::Matches($steadyRow.Details, [regex]::Escape($apA))).Count, ([regex]::Matches($steadyRow.Details, 'e6b08c8a-3feb-4c3e-88c3-dee94dd2f0eb')).Count) '3/1'
Assert-Equal '#61 assoc: and the first details line is a sample line, not a reason token' ((Get-DetailLineAt $steadyRow 0) -match '[:：]\s*(netsh|exception|none)\s*$') False
# A roam: the same network name, another access point at the end.
$roamRow = (Get-AssocRows @((New-AssocSample 'start' $assocT0 (& $ifA $apA)), (New-AssocSample 'middle' $assocT1 (& $ifA $apA)), (New-AssocSample 'end' $assocT2 (& $ifA $apB))))[0]
Assert-Equal '#61 assoc: a roam names both access points in the message' (($roamRow.Message -match [regex]::Escape($apA)) -and ($roamRow.Message -match [regex]::Escape($apB))) True
Assert-Equal '#61 assoc: and is not the steady sentence' ($roamRow.Message -eq $steadyRow.Message) False
# A roam that came back inside the window - visible only because the middle sample caught it - reads as more than one change.
$returnRow = (Get-AssocRows @((New-AssocSample 'start' $assocT0 (& $ifA $apA)), (New-AssocSample 'middle' $assocT1 (& $ifA $apB)), (New-AssocSample 'end' $assocT2 (& $ifA $apA))))[0]
Assert-Equal '#61 assoc: A then B then A names both and is neither the steady nor the single-roam sentence' (($returnRow.Message -match [regex]::Escape($apB)) -and ($returnRow.Message -ne $steadyRow.Message) -and ($returnRow.Message -ne $roamRow.Message)) True
Assert-Equal '#61 assoc: and its message carries the count of changes' ($returnRow.Message -match '\b2\b') True
# Another network altogether: the SSID changed with the BSSID.
$networkRow = (Get-AssocRows @((New-AssocSample 'start' $assocT0 (& $ifA $apA 'Office')), (New-AssocSample 'end' $assocT2 (& $ifA $apB 'Guest'))))[0]
Assert-Equal '#61 assoc: a change of network names both SSIDs' (($networkRow.Message -match 'Office') -and ($networkRow.Message -match 'Guest') -and ($networkRow.Message -ne $roamRow.Message)) True
# An access point at the start and none at the end: reported as not reported, never as disconnected (backlog #62).
$droppedRow = (Get-AssocRows @((New-AssocSample 'start' $assocT0 (& $ifA $apA)), (New-AssocSample 'middle' $assocT1 (& $ifA $apA)), (New-AssocSample 'end' $assocT2 (& $ifA ''))))[0]
Assert-Equal '#61 assoc: a BSSID reported at two of three samples keeps the access point and says how many reported it' (($droppedRow.Message -match [regex]::Escape($apA)) -and ($droppedRow.Message -match '\b2\b') -and ($droppedRow.Message -match '\b3\b') -and ($droppedRow.Message -ne $steadyRow.Message)) True
Assert-Equal '#61 assoc: and the details carry it twice' ([regex]::Matches($droppedRow.Details, [regex]::Escape($apA))).Count 2
$noneRow = (Get-AssocRows @((New-AssocSample 'start' $assocT0 (& $ifA '')), (New-AssocSample 'end' $assocT2 (& $ifA ''))))[0]
Assert-Equal '#61 assoc: no BSSID at any sample is an Information row naming no access point' (("{0}/{1}" -f $noneRow.Status, ($noneRow.Message -match $macShape))) 'INFO/False'
# The interface absent from the middle sample: disabled or removed at that moment, said in the message and listed in the details.
$absentRow = (Get-AssocRows @((New-AssocSample 'start' $assocT0 (& $ifA $apA)), (New-AssocSample 'middle' $assocT1 @()), (New-AssocSample 'end' $assocT2 (& $ifA $apA))))[0]
Assert-Equal '#61 assoc: an interface missing from one sample is one row, its message not the steady one, its details still three sample lines' ("{0}/{1}" -f ($absentRow.Message -ne $steadyRow.Message), ((Get-DetailLineCount $absentRow) -eq (Get-DetailLineCount $steadyRow))) 'True/True'
# Two interfaces: a row each, naming its own GUID and not the other's.
$guidUsb = '0b3f7c2e-1111-4a2b-9c3d-000000000002'
$usb = New-AssocInterface $guidUsb 'Wi-Fi 2' '00:11:22:33:44:66' '' ''
$twoRows = @(Get-AssocRows @((New-AssocSample 'start' $assocT0 @((& $ifA $apA), $usb)), (New-AssocSample 'end' $assocT2 @((& $ifA $apA), $usb))))
Assert-Equal '#61 assoc: two interfaces are two rows' $twoRows.Count 2
Assert-Equal '#61 assoc: each naming its own GUID exactly once and the other not at all' (@($twoRows | Where-Object { (([regex]::Matches($_.Details, $guidShape)).Count -eq 1) }).Count) 2
# An interface netsh printed no GUID for is keyed and named by its address.
$noGuidRow = (Get-AssocRows @((New-AssocSample 'start' $assocT0 (New-AssocInterface '' 'Wi-Fi' '10:f6:0a:db:fc:e5' 'kevin_5g' $apA)), (New-AssocSample 'end' $assocT2 (New-AssocInterface '' 'Wi-Fi' '10:f6:0a:db:fc:e5' 'kevin_5g' $apA))))[0]
Assert-Equal '#61 assoc: without a GUID the row names the adapter address and no GUID' (($noGuidRow.Details -match '10:f6:0a:db:fc:e5') -and ($noGuidRow.Details -notmatch $guidShape)) True
# Samples that failed: one beside two that worked is named in the details; all of them failing is one aggregate row
# whose first details line ends with the reason code, like the retry reader's.
$oneFailedRow = (Get-AssocRows @((New-AssocSample 'start' $assocT0 @() 'exception' 'boom'), (New-AssocSample 'middle' $assocT1 (& $ifA $apA)), (New-AssocSample 'end' $assocT2 (& $ifA $apA))))[0]
Assert-Equal '#61 assoc: a failed sample beside good ones is named in the details and the row is still measured' (("{0}/{1}" -f $oneFailedRow.Status, ($oneFailedRow.Details -match 'boom'))) 'INFO/True'
$assocReasonTail = '[:：]\s*(netsh|exception|none)\s*$'
$allFailedRows = @(Get-AssocRows @((New-AssocSample 'start' $assocT0 @() 'netsh' 'not found'), (New-AssocSample 'end' $assocT2 @() 'netsh' 'not found')))
Assert-Equal '#61 assoc: every sample failing is one Unable-to-Check row in the IT scope, its first line ending with the reason' ("{0}/{1}/{2}/{3}" -f $allFailedRows.Count, $allFailedRows[0].Status, $allFailedRows[0].Scope, ((Get-DetailLineAt $allFailedRows[0] 0) -match $assocReasonTail)) '1/ERROR/IT/True'
$exceptionRow = (Get-AssocRows @((New-AssocSample 'start' $assocT0 @() 'exception' 'boom')))[0]
Assert-Equal '#61 assoc: an exception is the other aggregate reason, with its text' (("{0}/{1}/{2}" -f $exceptionRow.Status, ((Get-DetailLineAt $exceptionRow 0) -match 'exception\s*$'), ($exceptionRow.Details -match 'boom'))) 'ERROR/True/True'
$wiredRows = @(Get-AssocRows @((New-AssocSample 'start' $assocT0 @()), (New-AssocSample 'middle' $assocT1 @()), (New-AssocSample 'end' $assocT2 @())))
Assert-Equal '#61 assoc: no interface at any sample is one Information row ending its first line with none, naming no GUID' ("{0}/{1}/{2}/{3}" -f $wiredRows.Count, $wiredRows[0].Status, ((Get-DetailLineAt $wiredRows[0] 0) -match 'none\s*$'), ($wiredRows[0].Details -match $guidShape)) '1/INFO/True/False'
$noSampleRows = @(Get-AssocRows @())
Assert-Equal '#61 assoc: no sample at all is one Unable-to-Check row' ("{0}/{1}" -f $noSampleRows.Count, $noSampleRows[0].Status) '1/ERROR'
$everyAssocRow = @($steadyRow, $roamRow, $returnRow, $networkRow, $droppedRow, $noneRow, $absentRow, $noGuidRow, $oneFailedRow, $allFailedRows[0], $exceptionRow, $wiredRows[0], $noSampleRows[0]) + $twoRows
Assert-Equal '#61 assoc: every row this analysis writes is in the IT scope and carries the tag' (@($everyAssocRow | Where-Object { $_.Scope -ne 'IT' -or $_.Tag -ne 'wifi-association' }).Count) 0
Assert-Equal '#61 shape: the per-interface rows never end their first details line with a reason token' (@(@($steadyRow, $roamRow, $returnRow, $networkRow, $droppedRow, $noneRow, $absentRow, $noGuidRow, $oneFailedRow) + $twoRows | Where-Object { (Get-DetailLineAt $_ 0) -match $assocReasonTail }).Count) 0

# The relation between two MAC addresses, which is what the hint is built on.
Assert-Equal '#61 mac: separators and case are not part of the address' (Get-MacRelation -First '08-26-97-7F-28-91' -Second '08:26:97:7f:28:91') 'identical'
Assert-Equal '#61 mac: the locally-administered bit alone is near' (Get-MacRelation -First '08:26:97:7f:28:91' -Second '0a:26:97:7f:28:91') 'near-ul'
Assert-Equal '#61 mac: the last octet alone is near' (Get-MacRelation -First '08:26:97:7f:28:91' -Second '08:26:97:7f:28:92') 'near-last'
Assert-Equal '#61 mac: the same first three octets is the vendor' (Get-MacRelation -First '08:26:97:7f:28:91' -Second '08:26:97:11:22:33') 'vendor'
Assert-Equal '#61 mac: the vendor prefix is compared with that bit aside' (Get-MacRelation -First '08:26:97:7f:28:91' -Second '0a:26:97:11:22:33') 'vendor'
Assert-Equal '#61 mac: that bit and the last octet together are the vendor, not near' (Get-MacRelation -First '08:26:97:7f:28:91' -Second '0a:26:97:7f:28:92') 'vendor'
Assert-Equal '#61 mac: different prefixes are different' (Get-MacRelation -First '08:26:97:7f:28:91' -Second 'ac:b6:87:a6:81:a0') 'different'
Assert-Equal '#61 mac: a value that is not an address is invalid, either side' ("{0}/{1}/{2}" -f (Get-MacRelation -First '' -Second 'ac:b6:87:a6:81:a0'), (Get-MacRelation -First '08:26:97:7f:28' -Second 'ac:b6:87:a6:81:a0'), (Get-MacRelation -First 'ac:b6:87:a6:81:a0' -Second '(unknown)')) 'invalid/invalid/invalid'

# The hint itself: the wireless interface whose adapter supplied the gateway, matched by address, against the gateway's.
$hintAdapters = @([pscustomobject]@{ Name = 'Wi-Fi'; Gateways = @('192.0.2.1'); MacAddress = '10-F6-0A-DB-FC-E5' }, [pscustomobject]@{ Name = 'Ethernet'; Gateways = @('192.0.2.254'); MacAddress = '00-11-22-33-44-55' })
function Get-HintFor($gatewayMac, $bssid, $gateway = '192.0.2.1') { return (Get-AccessPointGatewayText -Gateway $gateway -GatewayMac $gatewayMac -PrimaryAdapters $hintAdapters -Samples @((New-AssocSample 'middle' $assocT1 (& $ifA $bssid)))) }
$hintTexts = @{}
foreach ($pair in @(@('identical', $apA), @('near-ul', 'ae:b6:87:a6:81:a0'), @('near-last', 'ac:b6:87:a6:81:a1'), @('vendor', 'ac:b6:87:11:22:33'), @('different', $apB))) { $hintTexts[$pair[0]] = Get-HintFor $pair[1] $apA }
Assert-Equal '#61 hint: each of the five relations gives a sentence naming the BSSID' (@($hintTexts.Values | Where-Object { [string]::IsNullOrWhiteSpace($_) -or ($_ -notmatch [regex]::Escape($apA)) }).Count) 0
Assert-Equal '#61 hint: and the five sentences are five' (@($hintTexts.Values | Sort-Object -Unique).Count) 5
Assert-Equal '#61 hint: a wireless interface that reported no BSSID gets its own sentence, naming no address' ((-not [string]::IsNullOrWhiteSpace((Get-HintFor $apA ''))) -and ((Get-HintFor $apA '') -notmatch $macShape)) True
Assert-Equal '#61 hint: a gateway supplied by a wired adapter has no line' (Get-HintFor $apA $apA '192.0.2.254') ''
Assert-Equal '#61 hint: an unresolved or all-zero gateway address has no line' ("{0}/{1}" -f (Get-HintFor '' $apA), (Get-HintFor '00-00-00-00-00-00' $apA)) '/'
Assert-Equal '#61 hint: no readable sample has no line' (Get-AccessPointGatewayText -Gateway '192.0.2.1' -GatewayMac $apA -PrimaryAdapters $hintAdapters -Samples @((New-AssocSample 'start' $assocT0 @() 'netsh' 'not found'))) ''
Assert-Equal '#61 hint: the latest readable sample is the one compared' ((Get-AccessPointGatewayText -Gateway '192.0.2.1' -GatewayMac $apA -PrimaryAdapters $hintAdapters -Samples @((New-AssocSample 'start' $assocT0 (& $ifA $apB)), (New-AssocSample 'end' $assocT2 (& $ifA $apA)), (New-AssocSample 'late' $assocT2 @() 'exception' 'boom'))) -eq $hintTexts['identical']) True
Assert-Equal '#61 hint: the gateway row calls for it' ((Get-FunctionBody 'Add-GatewayNeighborResult') -match 'Get-AccessPointGatewayEvidence -Gateway \(\[string\]\$gateway\) -GatewayMac \$mac') True

# The spread: the sentence on the numbers it is given, and the row that carries it.
function New-SpreadFixture($received, $spread) { $m = New-PingFixture ([math]::Max(1, $received)) $received 5; if ($received -eq 0) { $m.Received = 0; $m.Sent = 4; $m.Lost = 4; $m.LossPercent = 100 }; if ($null -ne $spread) { $m | Add-Member -NotePropertyName SpreadMs -NotePropertyValue $spread }; return $m }
Assert-Equal '#61 spread: nothing replied, no sentence' (Get-LatencySpreadText -Measurement (New-SpreadFixture 0 $null)) ''
Assert-Equal '#61 spread: one reply has no sentence either - a spread needs two' (Get-LatencySpreadText -Measurement (New-SpreadFixture 1 $null)) ''
$fourSpread = Get-LatencySpreadText -Measurement (New-SpreadFixture 4 0.5)
Assert-Equal '#61 spread: four replies name the figure, the count and the minimum sample of nine' (($fourSpread -match '\b0\.5\b') -and ($fourSpread -match '\b4\b') -and ($fourSpread -match '\b9\b')) True
$thirtySpread = Get-LatencySpreadText -Measurement (New-SpreadFixture 30 0.4)
Assert-Equal '#61 spread: thirty replies name the figure and the count, and the sentence is the other one' (($thirtySpread -match '\b0\.4\b') -and ($thirtySpread -match '\b30\b') -and ($thirtySpread -match '\b9\b') -and (($thirtySpread -replace '[\d.]+', '#') -ne ($fourSpread -replace '[\d.]+', '#'))) True
Assert-Equal '#61 spread: nine replies is the minimum itself and takes the longer-sample sentence' ((((Get-LatencySpreadText -Measurement (New-SpreadFixture 9 1.2)) -replace '[\d.]+', '#')) -eq ($thirtySpread -replace '[\d.]+', '#')) True
Assert-Equal '#61 spread: eight takes the shorter-sample one' ((((Get-LatencySpreadText -Measurement (New-SpreadFixture 8 1.2)) -replace '[\d.]+', '#')) -eq ($fourSpread -replace '[\d.]+', '#')) True
Assert-Equal '#61 spread: a measurement of the old shape, with no spread field, has no sentence' (Get-LatencySpreadText -Measurement (New-PingFixture 4 4 5)) ''
$script:TcpRows = New-Object System.Collections.ArrayList
$plainRow = Add-PingTargetResult -Name 'Internet' -Target '203.0.113.9' -ConfiguredAddress '203.0.113.9' -Required $false -Measurement (New-PingFixture 4 4 5) -RouteBefore $pingRoute.Selection -RouteAfter $pingRoute -TargetIsAddress $true -TimeoutMs 1200
$spreadRow = Add-PingTargetResult -Name 'Internet' -Target '203.0.113.9' -ConfiguredAddress '203.0.113.9' -Required $false -Measurement (New-SpreadFixture 4 2.5) -RouteBefore $pingRoute.Selection -RouteAfter $pingRoute -TargetIsAddress $true -TimeoutMs 1200
Assert-Equal '#61 spread: the row carries the sentence as one details line, with the figure' ("{0}/{1}" -f ((Get-DetailLineCount $spreadRow) - (Get-DetailLineCount $plainRow)), ($spreadRow.Details -match '\b2\.5\b')) '1/True'
Assert-Equal '#61 spread: and it changes neither the status nor the message' ("{0}/{1}" -f ($spreadRow.Status -eq $plainRow.Status), ($spreadRow.Message -eq $plainRow.Message)) 'True/True'
$pingBody = Get-FunctionBody 'Invoke-PingMeasurement'
Assert-Equal '#61 spread: the measurement computes the sample standard deviation over two or more replies, n - 1, rounded to a tenth' (($pingBody -match 'if \(\$received -ge 2\) \{') -and ($pingBody -match '\[math\]::Round\(\[math\]::Sqrt\(\$squares / \(\$received - 1\)\), 1\)') -and ($pingBody -match 'SpreadMs\s+= \$spread')) True

# The run: the two extra samples and the analysis are IT-scoped steps at 8, 91 and 94, unmarked - an IT step's error row
# is outside the verdict already - and the radio row supplies the middle sample; the samples are reset with the results.
$sampleSteps = @($stepCalls | Where-Object { $_.Extent.Text -match 'Add-WifiAssociationSample -Moment' })
Assert-Equal '#61 run: two sampling steps, at 8 and 91, both in the IT scope and neither marked' ("{0}/{1}/{2}" -f $sampleSteps.Count, ((@($sampleSteps | ForEach-Object { Get-StepProgress $_ } | Sort-Object) -join ',')), (@($sampleSteps | Where-Object { (Get-StepParameter $_ 'Scope').Count -eq 1 -and (Get-StepParameter $_ 'Weightless').Count -eq 0 }).Count)) '2/8,91/2'
$compareSteps = @($stepCalls | Where-Object { $_.Extent.Text -match 'Compare-WifiAssociation -Samples' })
Assert-Equal '#61 run: one analysis step, at 94, in the IT scope' ("{0}/{1}/{2}" -f $compareSteps.Count, (Get-StepProgress $compareSteps[0]), ((Get-StepParameter $compareSteps[0] 'Scope').Count)) '1/94/1'
Assert-Equal '#61 run: the steps share the radio row''s switch' ((Get-FunctionBody 'Run-AllChecks') -match '\$wifiAssociationEnabled = Test-IsTrueFlag \$script:Config\.Checks\.WifiRf') True
Assert-Equal '#61 run: the samples are reset with the results' ((Get-FunctionBody 'Run-AllChecks') -match '\$script:WifiAssociationSamples = New-Object System\.Collections\.ArrayList') True
Assert-Equal '#61 run: the radio row takes the middle sample from the same read' ((Get-FunctionBody 'Add-WifiRfResult') -match 'Add-WifiAssociationSample -Moment "middle"') True

# PR #54, round 1: a failed sample stays in the totals; the identity line names the samples the interface was listed at;
# the hint pairs the neighbour entry with the adapter it was learned on.
Assert-Equal '#61 assoc r1: a failed sample beside two good ones keeps three in the total and two in the count' (($oneFailedRow.Message -match '\b3\b') -and ($oneFailedRow.Message -match '\b2\b') -and ($oneFailedRow.Message -ne $steadyRow.Message)) True
Assert-Equal '#61 assoc r1: and its details still list three samples' (Get-DetailLineCount $oneFailedRow) (Get-DetailLineCount $steadyRow)
Assert-Equal '#61 assoc r1: the identity line names the samples the interface was listed at' (($steadyRow.Details -match 'samples=start,middle,end') -and ($absentRow.Details -match 'samples=start,end') -and ($oneFailedRow.Details -match 'samples=middle,end')) True
$middleOnlyRow = (Get-AssocRows @((New-AssocSample 'start' $assocT0 @()), (New-AssocSample 'middle' $assocT1 (& $ifA $apA)), (New-AssocSample 'end' $assocT2 @())))[0]
Assert-Equal '#61 assoc r1: an interface present at the middle sample only is one row whose token names the middle alone' ("{0}/{1}" -f $middleOnlyRow.Status, ($middleOnlyRow.Details -match 'samples=middle\s*$|samples=middle\r?$|samples=middle\r?\n')) 'INFO/True'
Assert-Equal '#61 assoc r1: the token is on the GUID line' (([regex]::Match($middleOnlyRow.Details, '(?m)^[^\r\n]*e6b08c8a-3feb-4c3e-88c3-dee94dd2f0eb[^\r\n]*')).Value -match 'samples=middle') True
$dualAdapters = @([pscustomobject]@{ Name = 'Ethernet'; InterfaceIndex = 5; Gateways = @('192.0.2.1'); MacAddress = '00-11-22-33-44-55' }, [pscustomobject]@{ Name = 'Wi-Fi'; InterfaceIndex = 12; Gateways = @('192.0.2.1'); MacAddress = '10-F6-0A-DB-FC-E5' })
$dualSample = @((New-AssocSample 'middle' $assocT1 (& $ifA $apA)))
Assert-Equal '#61 hint r1: an entry learned on the wired adapter of a dual-homed machine leaves no line' (Get-AccessPointGatewayText -Gateway '192.0.2.1' -GatewayMac $apA -PrimaryAdapters $dualAdapters -Samples $dualSample -InterfaceIndex 5) ''
Assert-Equal '#61 hint r1: the same entry learned on the wireless adapter is compared' ((Get-AccessPointGatewayText -Gateway '192.0.2.1' -GatewayMac $apA -PrimaryAdapters $dualAdapters -Samples $dualSample -InterfaceIndex 12) -eq $hintTexts['identical']) True
Assert-Equal '#61 hint r1: no interface on the entry and two adapters supplying the gateway: nothing is compared' (Get-AccessPointGatewayText -Gateway '192.0.2.1' -GatewayMac $apA -PrimaryAdapters $dualAdapters -Samples $dualSample -InterfaceIndex 0) ''
Assert-Equal '#61 hint r1: no interface on the entry and one adapter: compared as before' ((Get-AccessPointGatewayText -Gateway '192.0.2.1' -GatewayMac $apA -PrimaryAdapters $hintAdapters -Samples $dualSample -InterfaceIndex 0) -eq $hintTexts['identical']) True
Assert-Equal '#61 hint r1: an interface index no primary adapter carries leaves no line' (Get-AccessPointGatewayText -Gateway '192.0.2.1' -GatewayMac $apA -PrimaryAdapters $dualAdapters -Samples $dualSample -InterfaceIndex 99) ''
$gatewayBody = Get-FunctionBody 'Add-GatewayNeighborResult'
Assert-Equal '#61 hint r1: the gateway row reads the entry''s interface index and hands it to the hint' (($gatewayBody -match '\$neighborIfIndex = ConvertTo-IntSafe \(Get-PropertyValue \$neighbor "InterfaceIndex" 0\) 0') -and ($gatewayBody -match '-Samples @\(\$script:WifiAssociationSamples\) -InterfaceIndex \$neighborIfIndex')) True

# PR #54, round 2: the same address under another network name is a renamed access point; the identity line's GUID is the one
# the samples token follows, whatever the network is called; and the gateway hint is compared again after the last sample.
$renamedRow = (Get-AssocRows @((New-AssocSample 'start' $assocT0 (& $ifA $apA 'Office')), (New-AssocSample 'middle' $assocT1 (& $ifA $apA 'Office')), (New-AssocSample 'end' $assocT2 (& $ifA $apA 'Office-5G'))))[0]
Assert-Equal '#61 assoc r2: the same BSSID under two network names names both and is not the steady sentence' (($renamedRow.Message -match 'Office-5G') -and ($renamedRow.Message -match 'Office\b') -and ($renamedRow.Message -match [regex]::Escape($apA)) -and (($renamedRow.Message -replace '[\d.]+', '#') -ne ($steadyRow.Message -replace '[\d.]+', '#'))) True
$uuidSsidRow = (Get-AssocRows @((New-AssocSample 'start' $assocT0 (& $ifA $apA '5d1e2f3a-2222-4b3c-8d4e-000000000003')), (New-AssocSample 'end' $assocT2 (& $ifA $apA '5d1e2f3a-2222-4b3c-8d4e-000000000003'))))[0]
$identityGuid = [regex]::Match($uuidSsidRow.Details, '([0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12})[;；]\s*samples=')
Assert-Equal '#61 assoc r2: with a UUID-shaped network name the GUID the samples token follows is still the interface' ("{0}/{1}" -f $identityGuid.Success, $identityGuid.Groups[1].Value) 'True/e6b08c8a-3feb-4c3e-88c3-dee94dd2f0eb'
Assert-Equal '#61 assoc r2: while the first GUID-shaped value in the details is the network, which is the trap' (([regex]::Match($uuidSsidRow.Details, '[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}')).Value) '5d1e2f3a-2222-4b3c-8d4e-000000000003'
# The hint refreshed after the last sample, on a row shaped like the gateway-neighbour row's details.
$script:PrimaryAdapters = $hintAdapters
# The method line carries each language's own prefix, and the refresh finds it by that prefix - so the fixture takes the prefix from the script under test.
$methodPrefix = $(if ((Get-FunctionBody 'Update-AccessPointGatewayHints') -match '檢測方式') { '檢測方式：' } else { 'Method: ' })
function New-HintRow($hint) { $rowLines = @('Gateway 192.0.2.1: neighbor state Reachable', $hint, ($methodPrefix + 'Get-NetNeighbor -AddressFamily IPv4 (fallback: arp -a)'), 'Manual check: arp -a') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }; return [pscustomobject]@{ Category = 'IT'; Check = 'Gateway neighbor (ARP)'; Details = ($rowLines -join [Environment]::NewLine) } }
function Get-RefreshedRow($hint, $endSample) { $script:GatewayNeighborRows = New-Object System.Collections.ArrayList; $row = New-HintRow $hint; [void]$script:GatewayNeighborRows.Add([pscustomobject]@{ Row = $row; Gateway = '192.0.2.1'; Mac = $apA; InterfaceIndex = 0; Hint = $hint; Bssid = $(if ($hint) { $apA } else { '' }); Relation = $(if ($hint) { 'identical' } else { '' }) }); Update-AccessPointGatewayHints -Samples @((New-AssocSample 'start' $assocT0 (& $ifA $apA)), (New-AssocSample 'middle' $assocT1 (& $ifA $apA)), $endSample); return $row }
$sameHint = $hintTexts['identical']
$unchanged = Get-RefreshedRow $sameHint (New-AssocSample 'end' $assocT2 (& $ifA $apA))
Assert-Equal '#61 hint r2: the same access point at the end leaves the row untouched' ($unchanged.Details -eq (New-HintRow $sameHint).Details) True
$moved = Get-RefreshedRow $sameHint (New-AssocSample 'end' $assocT2 (& $ifA $apB))
$movedLines = @($moved.Details -split "`r`n|`n")
Assert-Equal '#61 hint r2: a roam before the last sample adds one line after the original, which stays as written' ("{0}/{1}/{2}" -f $movedLines.Count, ($movedLines[1] -eq $sameHint), ($movedLines[2] -match [regex]::Escape($apB))) '5/True/True'
Assert-Equal '#61 hint r2: and the added line carries the new comparison without the sentence prefix twice' (([regex]::Matches($movedLines[2], [regex]::Escape($apB))).Count) 1
$gone = Get-RefreshedRow $sameHint (New-AssocSample 'end' $assocT2 (& $ifA ''))
$goneLines = @($gone.Details -split "`r`n|`n")
Assert-Equal '#61 hint r2: no BSSID at the end adds a line that names no address and keeps the original' ("{0}/{1}/{2}" -f $goneLines.Count, ($goneLines[1] -eq $sameHint), ($goneLines[2] -match $macShape)) '5/True/False'
$late = Get-RefreshedRow '' (New-AssocSample 'end' $assocT2 (& $ifA $apA))
$lateLines = @($late.Details -split "`r`n|`n")
Assert-Equal '#61 hint r2: no line at the neighbour read and an access point at the end: the line goes before the method line' ("{0}/{1}/{2}" -f $lateLines.Count, ($lateLines[1] -match [regex]::Escape($apA)), ($lateLines[2].StartsWith($methodPrefix))) '4/True/True'
Assert-Equal '#61 hint r2: the analysis step refreshes the hints after the association rows' ((@($stepCalls | Where-Object { $_.Extent.Text -match 'Compare-WifiAssociation -Samples' })[0]).Extent.Text -match '(?s)Compare-WifiAssociation -Samples @\(\$script:WifiAssociationSamples\)\s*Update-AccessPointGatewayHints -Samples @\(\$script:WifiAssociationSamples\)') True
Assert-Equal '#61 hint r2: the gateway row keeps what the refresh needs, and the run resets the list' ((($gatewayBody = Get-FunctionBody 'Add-GatewayNeighborResult') -match '\$script:GatewayNeighborRows\.Add\(\[pscustomobject\]@\{ Row = \$neighborRow; Gateway = \[string\]\$gateway; Mac = \[string\]\$mac; InterfaceIndex = \$neighborIfIndex; Hint = \[string\]\$accessPointLine; ') -and ((Get-FunctionBody 'Run-AllChecks') -match '\$script:GatewayNeighborRows = New-Object System\.Collections\.ArrayList')) True

# PR #54, round 3: the BSSID and the SSID by their labels, network names compared case-sensitively, and the hint refresh
# comparing evidence - the address and the relation - rather than the sentence.
$macNamed = @($win11 | ForEach-Object { $_ -replace '^    SSID                   : kevin_5g$', '    SSID                   : aa:bb:cc:dd:ee:ff' })
$w = @(ConvertFrom-NetshWlanOutput -Lines $macNamed)
Assert-Equal '#61 parser r3: a network named like a MAC address is the SSID, and the labelled AP BSSID is the access point' ("{0}/{1}/{2}/{3}" -f $w[0].Connected, $w[0].Ssid, $w[0].Bssid, $w[0].Channel) 'True/aa:bb:cc:dd:ee:ff/ac:b6:87:a6:81:a0/149'
Assert-Equal '#61 parser r3: the Windows 10 label BSSID is read the same way' ("{0}/{1}" -f (@(ConvertFrom-NetshWlanOutput -Lines $win10zh))[0].Ssid, (@(ConvertFrom-NetshWlanOutput -Lines $win10zh))[0].Bssid) 'Office-2G/5c:e2:8c:11:22:33'
$noLabels = @($win10zh | ForEach-Object { $_ -replace '^    SSID  ', '    網路名稱' -replace '^    BSSID ', '    基地台' })
$w = @(ConvertFrom-NetshWlanOutput -Lines $noLabels)
Assert-Equal '#61 parser r3: without the SSID and BSSID labels the shape rules still yield both' ("{0}/{1}/{2}" -f $w[0].Connected, $w[0].Ssid, $w[0].Bssid) 'True/Office-2G/5c:e2:8c:11:22:33'
$caseRow = (Get-AssocRows @((New-AssocSample 'start' $assocT0 (& $ifA $apA 'Office')), (New-AssocSample 'end' $assocT2 (& $ifA $apA 'OFFICE'))))[0]
Assert-Equal '#61 assoc r3: network names that differ only by case are both listed, in order' (($caseRow.Message -cmatch 'Office\b') -and ($caseRow.Message -cmatch 'OFFICE') -and ($caseRow.Message.IndexOf('Office') -lt $caseRow.Message.IndexOf('OFFICE'))) True
$ev = Get-AccessPointGatewayEvidence -Gateway '192.0.2.1' -GatewayMac $apA -PrimaryAdapters $hintAdapters -Samples @((New-AssocSample 'middle' $assocT1 (& $ifA $apA)))
Assert-Equal '#61 hint r3: the evidence carries the address, the relation, the interface and the sentence' ("{0}/{1}/{2}/{3}" -f $ev.Bssid, $ev.Relation, $ev.Interface, ($ev.Text -eq $hintTexts['identical'])) ("{0}/identical/Wi-Fi/True" -f $apA)
$evNone = Get-AccessPointGatewayEvidence -Gateway '192.0.2.1' -GatewayMac $apA -PrimaryAdapters $hintAdapters -Samples @((New-AssocSample 'middle' $assocT1 (& $ifA '')))
$evSilent = Get-AccessPointGatewayEvidence -Gateway '192.0.2.254' -GatewayMac $apA -PrimaryAdapters $hintAdapters -Samples @((New-AssocSample 'middle' $assocT1 (& $ifA $apA)))
Assert-Equal '#61 hint r3: no BSSID is the nobssid relation with its sentence; a wired gateway is empty evidence' ("{0}/{1}/{2}/{3}" -f $evNone.Relation, (-not [string]::IsNullOrWhiteSpace($evNone.Text)), $evSilent.Relation, $evSilent.Text) 'nobssid/True//'
Assert-Equal '#61 hint r3: the text function is the evidence''s sentence' ((Get-AccessPointGatewayText -Gateway '192.0.2.1' -GatewayMac $apA -PrimaryAdapters $hintAdapters -Samples @((New-AssocSample 'middle' $assocT1 (& $ifA $apA)))) -eq $ev.Text) True
# The refresh on evidence: a renamed interface with the same access point adds nothing; a new address still does.
function Get-RefreshedRow3($evidence, $endSample) { $script:GatewayNeighborRows = New-Object System.Collections.ArrayList; $row = New-HintRow ([string]$evidence.Text); [void]$script:GatewayNeighborRows.Add([pscustomobject]@{ Row = $row; Gateway = '192.0.2.1'; Mac = $apA; InterfaceIndex = 0; Hint = [string]$evidence.Text; Bssid = [string]$evidence.Bssid; Relation = [string]$evidence.Relation }); Update-AccessPointGatewayHints -Samples @((New-AssocSample 'start' $assocT0 (& $ifA $apA)), (New-AssocSample 'middle' $assocT1 (& $ifA $apA)), $endSample); return $row }
$renamedIf = Get-RefreshedRow3 $ev (New-AssocSample 'end' $assocT2 (New-AssocInterface 'e6b08c8a-3feb-4c3e-88c3-dee94dd2f0eb' 'WLAN' '10:f6:0a:db:fc:e5' 'kevin_5g' $apA))
Assert-Equal '#61 hint r3: an interface renamed during the run, same access point, leaves the row untouched' ($renamedIf.Details -eq (New-HintRow $ev.Text).Details) True
$movedIf = Get-RefreshedRow3 $ev (New-AssocSample 'end' $assocT2 (New-AssocInterface 'e6b08c8a-3feb-4c3e-88c3-dee94dd2f0eb' 'WLAN' '10:f6:0a:db:fc:e5' 'kevin_5g' $apB))
Assert-Equal '#61 hint r3: a renamed interface on another access point still gets the line' ((@($movedIf.Details -split "`r`n|`n")).Count -eq 5 -and ($movedIf.Details -match [regex]::Escape($apB))) True
Assert-Equal '#61 hint r3: the gateway row keeps the address and the relation beside the sentence' ((Get-FunctionBody 'Add-GatewayNeighborResult') -match 'Hint = \[string\]\$accessPointLine; Bssid = \[string\]\$accessPointEvidence\.Bssid; Relation = \[string\]\$accessPointEvidence\.Relation \}\)') True
Assert-Equal '#61 hint r3: and the refresh compares them, not the sentence' ((Get-FunctionBody 'Update-AccessPointGatewayHints') -match '\$freshEvidence\.Bssid -eq \[string\]\(Get-PropertyValue \$entry "Bssid" ""\)\) -and \(\[string\]\$freshEvidence\.Relation -eq') True

# --- backlog #62 (v1.2.13): the connected state from the WLAN service, and what netsh prints where the location is denied ---
# Measured on the reference machine (Windows 11 25H2, 2026-09-12) with desktop programs denied the location: netsh wlan
# show interfaces prints its count line, a refusal naming ms-settings:privacy-location and the failing call, no interface
# block at all, and exits 1; the WLAN service still lists the interface as connected and refuses only the connection
# query (error 5). The two outputs, English and Traditional Chinese, are the fixtures; the parser yields nothing from
# either, which is what had made the radio row call a connected machine wired. Language-independent throughout: statuses,
# scopes, counts, tokens, the values a sentence interpolates and the shape of the details, never the wording.
$refusedEn = @('', 'There is 1 interface on the system: ', 'Network shell commands need location permission to access WLAN information. Turn on Location services on the Location page in Privacy & security settings.', 'Here is the URI for the Location page in the Settings app: ms-settings:privacy-location', 'To open the Location page in the Settings app, run the following command:', 'start ms-settings:privacy-location', '', 'Or, to open the Location page from the Run dialog box, press Windows logo key + R, and then copy and paste the URI above.', '', 'Function WlanQueryInterface returns error 5:', 'The requested operation requires elevation (Run as administrator).', '')
$refusedZh = @('', '系統上有 1 個介面: ', '網路殼層命令需要位置權限才能存取 WLAN 資訊。在 [隱私權和安全性設定] 的 [位置] 頁面上開啟定位服務。', '這是 [設定] 應用程式中 [位置] 頁面的 URI: ms-settings:privacy-location', '若要在 [設定] 應用程式中開啟 [位置] 頁面，請執行下列命令:', 'start ms-settings:privacy-location', '', '或者，若要從 [執行] 對話框開啟 [位置] 頁面，請按 Windows 鍵 + R，然後複製並貼上上方的 URI。', '', '函數  WlanQueryInterface 傳回錯誤 5:', '要求的作業需要提高的權限 (以系統管理員身分執行)。', '')
Assert-Equal '#62 parser: the refused output yields no interface, in either language' ("{0}/{1}" -f @(ConvertFrom-NetshWlanOutput -Lines $refusedEn).Count, @(ConvertFrom-NetshWlanOutput -Lines $refusedZh).Count) '0/0'
function New-Consent62($denied = $true, $gated = $true) { return [pscustomobject]@{ Known = $true; Denied = $denied; Build = $(if ($gated) { 26200 } else { 19045 }); Gated = $gated; Levels = @(); Text = $(if ($denied) { 'user Deny, device Allow, desktop apps Allow, netsh (no entry)' } else { 'user Allow, device Allow, desktop apps Allow, netsh (no entry)' }) } }
function New-ApiReading62($state, $query, $channel = 149, $software = 'on', $hardware = 'on', $error = '', $guid = 'e6b08c8a-3feb-4c3e-88c3-dee94dd2f0eb', $consent = $null) { if ($null -eq $consent) { $consent = New-Consent62 }; return [pscustomobject]@{ Timestamp = (Get-Date); Interfaces = @($(if ($error) { @() } else { [pscustomobject]@{ Guid = $guid; Description = 'Fixture AX211'; State = $state; Channel = $channel; RadioSoftware = $software; RadioHardware = $hardware; ConnectionQuery = $query } })); Error = $error; ErrorText = $(if ($error) { 'fixture' } else { '' }); Diagnostics = ''; LocationConsent = $consent } }
function New-Sample62($moment, $lines, $exit, $api, $error = '') { return [pscustomobject]@{ Moment = $moment; Timestamp = $assocT0; Interfaces = @(ConvertFrom-NetshWlanOutput -Lines $lines); Error = $error; ErrorText = $(if ($error) { 'fixture' } else { '' }); Diagnostics = ''; NetshExitCode = $exit; NetshLines = @($lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() }); Api = $api } }
# The view: one list from the two readers, the service deciding the state where it answered.
$view62 = @(Get-WifiInterfaceView -Sample (New-Sample62 'middle' $refusedEn 1 (New-ApiReading62 1 5)))
Assert-Equal '#62 view: connected per the WLAN service, nothing from netsh, refused by the location setting' ("{0}/{1}/{2}/{3}/{4}/{5}" -f $view62.Count, $view62[0].Connected, $view62[0].ConnectedSource, $view62[0].NetshListed, $view62[0].Refused, $view62[0].Channel) '1/True/wlanapi/False/True/149'
$view62b = @(Get-WifiInterfaceView -Sample (New-Sample62 'middle' $refusedEn 1 (New-ApiReading62 1 0)))
Assert-Equal '#62 view: netsh failing while the service answers the connection query is not the location case' ("{0}/{1}/{2}/{3}" -f $view62b[0].Connected, $view62b[0].NetshFailed, $view62b[0].Refused, $view62b[0].AccessDenied) 'True/True/False/False'
# Error 5 is access denied and no more (PR #55, round 1): the location setting is the cause only with the consent store's
# Deny on a build that gates the details; without either, or without the reading at all, the entry is AccessDenied and not Refused.
$view62h = @(Get-WifiInterfaceView -Sample (New-Sample62 'middle' $refusedEn 1 (New-ApiReading62 1 5 149 'on' 'on' '' 'e6b08c8a-3feb-4c3e-88c3-dee94dd2f0eb' (New-Consent62 $false $true))))
Assert-Equal '#62 view r1: error 5 with the consent store at Allow is access denied, not the location case' ("{0}/{1}" -f $view62h[0].AccessDenied, $view62h[0].Refused) 'True/False'
$view62i = @(Get-WifiInterfaceView -Sample (New-Sample62 'middle' $refusedEn 1 (New-ApiReading62 1 5 149 'on' 'on' '' 'e6b08c8a-3feb-4c3e-88c3-dee94dd2f0eb' (New-Consent62 $true $false))))
Assert-Equal '#62 view r1: error 5 with Deny on a build below 26100 is access denied, not the location case' ("{0}/{1}" -f $view62i[0].AccessDenied, $view62i[0].Refused) 'True/False'
$noConsent = New-ApiReading62 1 5; $noConsent.LocationConsent = $null
$view62j = @(Get-WifiInterfaceView -Sample (New-Sample62 'middle' $refusedEn 1 $noConsent))
Assert-Equal '#62 view r1: error 5 without a consent reading is access denied, not the location case' ("{0}/{1}" -f $view62j[0].AccessDenied, $view62j[0].Refused) 'True/False'
$live62c = Get-LocationConsentState
Assert-Equal '#62 consent r1: a real reading carries the build, the gating that follows from it, four levels and a text, and Deny only where a level says so' ("{0}/{1}/{2}/{3}" -f ($live62c.Build -gt 0), ($live62c.Gated -eq ($live62c.Build -ge 26100)), @($live62c.Levels).Count, ($live62c.Denied -eq (@($live62c.Levels | Where-Object { $_.Value -eq 'Deny' }).Count -gt 0))) 'True/True/4/True'
Write-Output ('[INFO] #62 location consent on this machine: ' + $live62c.Text + '; build ' + $live62c.Build + ', gated ' + $live62c.Gated + ', denied ' + $live62c.Denied)
$view62c = @(Get-WifiInterfaceView -Sample (New-Sample62 'middle' $off 0 (New-ApiReading62 4 -1 0 'off' 'on')))
Assert-Equal '#62 view: a disconnected interface listed by both readers, the service deciding, the radio switch read' ("{0}/{1}/{2}/{3}/{4}" -f $view62c.Count, $view62c[0].Connected, $view62c[0].ConnectedSource, $view62c[0].NetshListed, ((Get-WifiRadioSwitchText -View $view62c[0]) -ne '')) '1/False/wlanapi/True/True'
$view62d = @(Get-WifiInterfaceView -Sample (New-Sample62 'middle' $win11 0 (New-ApiReading62 1 0)))
Assert-Equal '#62 view: the ordinary block keeps its fields and takes the state from the service' ("{0}/{1}/{2}/{3}" -f $view62d[0].Connected, $view62d[0].ConnectedSource, $view62d[0].Bssid, $view62d[0].Ssid) 'True/wlanapi/ac:b6:87:a6:81:a0/kevin_5g'
$view62e = @(Get-WifiInterfaceView -Sample (New-Sample62 'middle' $win11 0 (New-ApiReading62 1 0 149 'on' 'on' 'addtype')))
Assert-Equal '#62 view: the service unreadable, netsh decides and says so' ("{0}/{1}/{2}" -f $view62e[0].Connected, $view62e[0].ConnectedSource, $view62e[0].ApiListed) 'True/netsh/False'
$view62f = @(Get-WifiInterfaceView -Sample (New-Sample62 'middle' $win11 0 (New-ApiReading62 4 -1)))
Assert-Equal '#62 view: the service outranks a BSSID in the block - state 4 is not connected' ("{0}/{1}" -f $view62f[0].Connected, $view62f[0].Bssid) 'False/ac:b6:87:a6:81:a0'
Assert-Equal '#62 view: the older envelope, without the service, reads as netsh alone' ((Get-WifiInterfaceView -Sample (New-AssocSample 'start' $assocT0 (& $ifA $apA)))[0].ConnectedSource) 'netsh'
Assert-Equal '#62 view: nothing from nothing' (@(Get-WifiInterfaceView -Sample $null).Count) 0
$twoApi = New-ApiReading62 1 0; $twoApi.Interfaces = @($twoApi.Interfaces) + @([pscustomobject]@{ Guid = '0b3f7c2e-1111-4a2b-9c3d-000000000002'; Description = 'Second'; State = 4; Channel = $null; RadioSoftware = 'on'; RadioHardware = 'on'; ConnectionQuery = -1 })
$view62g = @(Get-WifiInterfaceView -Sample (New-Sample62 'middle' $win11 0 $twoApi))
Assert-Equal '#62 view: an interface only the service lists follows the one netsh printed, not connected, not refused' ("{0}/{1}/{2}/{3}" -f $view62g.Count, $view62g[1].Guid, $view62g[1].Connected, $view62g[1].Refused) '2/0b3f7c2e-1111-4a2b-9c3d-000000000002/False/False'
# The phrases: shapes, not words.
Assert-Equal '#62 reason: nothing for an ordinary sample; something for exit 1, the executable missing, the read that threw' ("{0}/{1}/{2}/{3}" -f ((Get-WifiNetshReasonText -Sample (New-Sample62 'm' $win11 0 $null)) -eq ''), ((Get-WifiNetshReasonText -Sample (New-Sample62 'm' $refusedEn 1 $null)) -match '\b1\b'), ((Get-WifiNetshReasonText -Sample (New-Sample62 'm' @() -1 $null 'netsh')) -match 'netsh\.exe'), ((Get-WifiNetshReasonText -Sample (New-Sample62 'm' @() -1 $null 'exception')) -match 'fixture')) 'True/True/True/True'
Assert-Equal '#62 summary: the service count, its reason code, or nothing for the older envelope' ("{0}/{1}/{2}" -f ((Get-WifiApiSummaryText -Sample (New-Sample62 'm' $win11 0 (New-ApiReading62 1 0))) -match '\b1\b'), ((Get-WifiApiSummaryText -Sample (New-Sample62 'm' $win11 0 (New-ApiReading62 1 0 149 'on' 'on' 'open'))) -match 'open'), ((Get-WifiApiSummaryText -Sample (New-AssocSample 'start' $assocT0 @())) -eq '')) 'True/True/True'
# A switch is off only where every PHY read reports off (PR #55, round 8); some off and the rest indeterminate is unknown.
Assert-Equal '#62 radio r8: any on is on; all read off is off; off beside unknown is unknown; nothing read is unknown' ("{0}/{1}/{2}/{3}/{4}" -f (Get-RadioSwitchState -On 1 -Off 5 -Read 6), (Get-RadioSwitchState -On 0 -Off 6 -Read 6), (Get-RadioSwitchState -On 0 -Off 2 -Read 6), (Get-RadioSwitchState -On 0 -Off 0 -Read 0), (Get-RadioSwitchState -On 0 -Off 0 -Read 3)) 'on/off/unknown/unknown/unknown'
Assert-Equal '#62 radio r8: the reader takes both switches from that rule' ((Get-FunctionBody 'Get-WlanInterfaceStates') -match 'Get-RadioSwitchState -On \$softwareOn -Off \$softwareOff -Read \$phyRead' -and (Get-FunctionBody 'Get-WlanInterfaceStates') -match 'Get-RadioSwitchState -On \$hardwareOn -Off \$hardwareOff -Read \$phyRead') True
Assert-Equal '#62 radio r9: on needs both switches known on; one on beside one unknown is its own phrase, distinct per switch; unknown beside unknown is silent' ("{0}/{1}/{2}/{3}" -f ((Get-WifiRadioSwitchText -View ([pscustomobject]@{ RadioSoftware = 'on'; RadioHardware = 'unknown' })) -ne (Get-WifiRadioSwitchText -View ([pscustomobject]@{ RadioSoftware = 'on'; RadioHardware = 'on' }))), ((Get-WifiRadioSwitchText -View ([pscustomobject]@{ RadioSoftware = 'on'; RadioHardware = 'unknown' })) -ne ''), ((Get-WifiRadioSwitchText -View ([pscustomobject]@{ RadioSoftware = 'unknown'; RadioHardware = 'on' })) -ne (Get-WifiRadioSwitchText -View ([pscustomobject]@{ RadioSoftware = 'on'; RadioHardware = 'unknown' }))), ((Get-WifiRadioSwitchText -View ([pscustomobject]@{ RadioSoftware = 'unknown'; RadioHardware = 'unknown' })) -eq '')) 'True/True/True/True'
Assert-Equal '#62 radio text: off is said, on is said, unread is silent, and both switches off differs from one' ("{0}/{1}/{2}/{3}" -f ((Get-WifiRadioSwitchText -View ([pscustomobject]@{ RadioSoftware = 'off'; RadioHardware = 'on' })) -ne ''), ((Get-WifiRadioSwitchText -View ([pscustomobject]@{ RadioSoftware = 'on'; RadioHardware = 'on' })) -ne ''), ((Get-WifiRadioSwitchText -View ([pscustomobject]@{ RadioSoftware = ''; RadioHardware = '' })) -eq ''), ((Get-WifiRadioSwitchText -View ([pscustomobject]@{ RadioSoftware = 'off'; RadioHardware = 'off' })) -ne (Get-WifiRadioSwitchText -View ([pscustomobject]@{ RadioSoftware = 'off'; RadioHardware = 'on' })))) 'True/True/True/True'
# The association rows over refused samples: a row for the interface the service listed, never the wired row.
$allRefused = @(Get-AssocRows @((New-Sample62 'start' $refusedEn 1 (New-ApiReading62 1 5)), (New-Sample62 'middle' $refusedZh 1 (New-ApiReading62 1 5)), (New-Sample62 'end' $refusedEn 1 (New-ApiReading62 1 5))))
Assert-Equal '#62 assoc: three refused samples are one Information row for the interface the service listed, its token naming all three' ("{0}/{1}/{2}/{3}" -f $allRefused.Count, $allRefused[0].Status, ($allRefused[0].Details -match 'e6b08c8a-3feb-4c3e-88c3-dee94dd2f0eb[;；]\s*samples=start,middle,end'), ($allRefused[0].Message -match '\b3\b')) '1/INFO/True/True'
Assert-Equal '#62 assoc: the message names error 5 and no address, and every sample line carries the service state' ("{0}/{1}/{2}" -f ($allRefused[0].Message -match '\b5\b'), ($allRefused[0].Message -match $macShape), (@(($allRefused[0].Details -split "`r`n|`n") | Where-Object { $_ -match 'WLAN' }).Count -ge 3)) 'True/False/True'
$mixed = @(Get-AssocRows @((New-Sample62 'start' $win11 0 (New-ApiReading62 1 0)), (New-Sample62 'middle' $refusedEn 1 (New-ApiReading62 1 5)), (New-Sample62 'end' $refusedEn 1 (New-ApiReading62 1 5))))
Assert-Equal '#62 assoc: one address and two refused samples keep the address and count the refusals' ("{0}/{1}/{2}/{3}" -f $mixed.Count, ($mixed[0].Message -match 'ac:b6:87:a6:81:a0'), ($mixed[0].Message -match '\b2\b'), ($mixed[0].Details -match 'samples=start,middle,end')) '1/True/True/True'
$otherFail = @(Get-AssocRows @((New-Sample62 'start' $refusedEn 1 (New-ApiReading62 1 0)), (New-Sample62 'end' $refusedEn 1 (New-ApiReading62 1 0))))
Assert-Equal '#62 assoc: netsh failing while the service answers is said without the location cause - no error 5 in the message' ("{0}/{1}" -f $otherFail.Count, ($otherFail[0].Message -match '\b5\b')) '1/False'
$deniedNoWitness = @(Get-AssocRows @((New-Sample62 'start' $refusedEn 1 (New-ApiReading62 1 5 149 'on' 'on' '' 'e6b08c8a-3feb-4c3e-88c3-dee94dd2f0eb' (New-Consent62 $false $true))), (New-Sample62 'end' $refusedEn 1 (New-ApiReading62 1 5 149 'on' 'on' '' 'e6b08c8a-3feb-4c3e-88c3-dee94dd2f0eb' (New-Consent62 $false $true)))))
Assert-Equal '#62 assoc r1: error 5 without the consent witness names no location cause in the message, and the sample lines carry the error' ("{0}/{1}/{2}" -f $deniedNoWitness.Count, ($deniedNoWitness[0].Message -match '\b5\b'), (@(($deniedNoWitness[0].Details -split "`r`n|`n") | Where-Object { $_ -match '\b5\b' }).Count -ge 2)) '1/False/True'
# Neither reader listing anything while both answered - netsh's count line alone, exit 0, the service listing none - is the
# no-interface row (wlanapi=ok on its first line); netsh exiting non-zero beside a failed service reading is not that row
# but the aggregate Unable-to-Check one (round 10).
$emptyApi = New-ApiReading62 1 0; $emptyApi.Interfaces = @()
$noneAtAll = @(Get-AssocRows @((New-Sample62 'start' @('There is 0 interface on the system:') 0 $emptyApi), (New-Sample62 'end' @('There is 0 interface on the system:') 0 $emptyApi)))
Assert-Equal '#62 assoc: neither reader listing anything is the one no-interface row, its first line the none token and, since round 4, the reader''s token' ("{0}/{1}/{2}" -f $noneAtAll.Count, $noneAtAll[0].Status, ((($noneAtAll[0].Details -split "`r`n|`n")[0]) -match '[:：]\s*none;\s*wlanapi=ok\s*$')) '1/INFO/True'
$refusedOpen = @(Get-AssocRows @((New-Sample62 'start' $refusedEn 1 (New-ApiReading62 1 0 149 'on' 'on' 'open')), (New-Sample62 'end' $refusedEn 1 (New-ApiReading62 1 0 149 'on' 'on' 'open'))))
Assert-Equal '#62 assoc r10: netsh exiting non-zero beside a service that did not answer is the aggregate row with the reason refused and the reader''s token' ("{0}/{1}/{2}" -f $refusedOpen.Count, $refusedOpen[0].Status, ((($refusedOpen[0].Details -split "`r`n|`n")[0]) -match '[:：]\s*refused;\s*wlanapi=open\s*$')) '1/ERROR/True'
Assert-Equal '#62 assoc r4: the reader''s reason is the token on the aggregate line, and the older envelope carries no token' ("{0}/{1}" -f (((@(Get-AssocRows @((New-Sample62 'start' $refusedEn 1 (New-ApiReading62 1 0 149 'on' 'on' 'error'))))[0].Details -split "`r`n|`n")[0]) -match 'wlanapi=error\s*$'), (((@(Get-AssocRows @((New-AssocSample 'start' $assocT0 @())))[0].Details -split "`r`n|`n")[0]) -match '[:：]\s*none\s*$')) 'True/True'
# A BSSID netsh printed beside a service state that is not connected (PR #55, round 3): every BSSID sample line carries
# the service's state, and the message discloses the account that is not 'connected at every listed sample'.
$steadyBoth = @(Get-AssocRows @((New-Sample62 'start' $win11 0 (New-ApiReading62 1 0)), (New-Sample62 'end' $win11 0 (New-ApiReading62 1 0))))
$conflict = @(Get-AssocRows @((New-Sample62 'start' $win11 0 (New-ApiReading62 1 0)), (New-Sample62 'end' $win11 0 (New-ApiReading62 4 -1))))
Assert-Equal '#62 assoc r3: every BSSID sample line carries the service state, and a state that is not connected reaches the message' ("{0}/{1}/{2}/{3}" -f (@(($steadyBoth[0].Details -split "`r`n|`n") | Where-Object { $_ -match [regex]::Escape($apA) -and $_ -match 'WLAN' }).Count), (@(($conflict[0].Details -split "`r`n|`n") | Where-Object { $_ -match [regex]::Escape($apA) -and $_ -match 'WLAN' }).Count), ($conflict[0].Message -ne $steadyBoth[0].Message), ($conflict[0].Message.Length -gt $steadyBoth[0].Message.Length)) '2/2/True/True'
Assert-Equal '#62 assoc r3: and the steady row, connected at every sample the service listed, adds no state sentence' (($steadyBoth[0].Message -match [regex]::Escape($apA)) -and ($steadyBoth[0].Message -notmatch 'WLAN')) True
# netsh failing outright while the service answers (PR #55, round 6): the sample is readable, the interface the service
# listed gets its row with the samples said as not sampled, and only a sample both readers failed is skipped.
$netshGone = @(Get-AssocRows @((New-Sample62 'start' @() -1 (New-ApiReading62 1 0) 'netsh'), (New-Sample62 'middle' @() -1 (New-ApiReading62 1 0) 'netsh'), (New-Sample62 'end' @() -1 (New-ApiReading62 1 0) 'netsh')))
Assert-Equal '#62 assoc r6: netsh missing at every sample while the service lists the interface is one Information row for it, its token naming all three' ("{0}/{1}/{2}" -f $netshGone.Count, $netshGone[0].Status, ($netshGone[0].Details -match 'e6b08c8a-3feb-4c3e-88c3-dee94dd2f0eb[;；]\s*samples=start,middle,end')) '1/INFO/True'
$netshThrew = @(Get-AssocRows @((New-Sample62 'start' $win11 0 (New-ApiReading62 1 0)), (New-Sample62 'middle' @() -1 (New-ApiReading62 1 0) 'exception'), (New-Sample62 'end' $win11 0 (New-ApiReading62 1 0))))
Assert-Equal '#62 assoc r6: a read that threw between two with a BSSID keeps the address, counts one not-sampled and no failed sample' ("{0}/{1}/{2}/{3}" -f $netshThrew.Count, ($netshThrew[0].Message -match [regex]::Escape($apA)), ($netshThrew[0].Message -match '\b1\b'), ($netshThrew[0].Details -match 'samples=start,middle,end')) '1/True/True/True'
$bothFailed = @(Get-AssocRows @((New-Sample62 'start' @() -1 (New-ApiReading62 1 0 149 'on' 'on' 'open') 'netsh'), (New-Sample62 'end' @() -1 (New-ApiReading62 1 0 149 'on' 'on' 'open') 'netsh')))
Assert-Equal '#62 assoc r6: both readers failing at every sample is still the one aggregate Unable-to-Check row with the netsh reason and the reader token' ("{0}/{1}/{2}" -f $bothFailed.Count, $bothFailed[0].Status, ((($bothFailed[0].Details -split "`r`n|`n")[0]) -match '[:：]\s*netsh;\s*wlanapi=open\s*$')) '1/ERROR/True'
$refusedBoth = @(Get-AssocRows @((New-Sample62 'start' $refusedEn 1 (New-ApiReading62 1 0 149 'on' 'on' 'addtype')), (New-Sample62 'end' $refusedEn 1 (New-ApiReading62 1 0 149 'on' 'on' 'addtype'))))
Assert-Equal '#62 assoc r10: netsh exiting non-zero with nothing listed beside a failed service reading at every sample is the aggregate Unable-to-Check row, reason refused, not the wired computer''s' ("{0}/{1}/{2}" -f $refusedBoth.Count, $refusedBoth[0].Status, ((($refusedBoth[0].Details -split "`r`n|`n")[0]) -match '[:：]\s*refused;\s*wlanapi=addtype\s*$')) '1/ERROR/True'
Assert-Equal '#62 readable r10: netsh exiting non-zero is not an answer - readable only where the service answered' ("{0}/{1}" -f (Test-WifiSampleReadable (New-Sample62 'm' $refusedEn 1 (New-ApiReading62 1 0 149 'on' 'on' 'addtype'))), (Test-WifiSampleReadable (New-Sample62 'm' $refusedEn 1 (New-ApiReading62 1 5)))) 'False/True'
Assert-Equal '#62 readable r6: netsh ok, or the service answering, or neither' ("{0}/{1}/{2}/{3}" -f (Test-WifiSampleReadable (New-Sample62 'm' $win11 0 $null)), (Test-WifiSampleReadable (New-Sample62 'm' @() -1 (New-ApiReading62 1 0) 'netsh')), (Test-WifiSampleReadable (New-Sample62 'm' @() -1 (New-ApiReading62 1 0 149 'on' 'on' 'addtype') 'exception')), (Test-WifiSampleReadable (New-AssocSample 'start' $assocT0 @() 'netsh'))) 'True/True/False/False'
$disconnectedRow = @(Get-AssocRows @((New-Sample62 'start' $off 0 (New-ApiReading62 4 -1)), (New-Sample62 'end' $off 0 (New-ApiReading62 4 -1))))
Assert-Equal '#62 assoc: no BSSID with the service saying disconnected names no address and stays Information' ("{0}/{1}/{2}" -f $disconnectedRow.Count, $disconnectedRow[0].Status, ($disconnectedRow[0].Message -match $macShape)) '1/INFO/False'
# The state reader and the envelope, for real on whatever this machine has.
$live62 = Get-WlanInterfaceStates
Assert-Equal '#62 reader: a real reading either lists interfaces without an error or names the reason' ((([string]$live62.Error -eq '') -and ($null -ne $live62.Interfaces)) -or ([string]$live62.Error -in @('addtype', 'open', 'enumerate', 'error'))) True
Assert-Equal '#62 reader: every listed interface carries a GUID, a state and a connection-query code' (@(@($live62.Interfaces) | Where-Object { -not ($_.Guid -match $guidShape) -or $null -eq $_.State -or $null -eq $_.ConnectionQuery }).Count) 0
Write-Output ('[INFO] #62 state reader on this machine: ' + @($live62.Interfaces).Count + ' interface(s)' + $(if ([string]$live62.Error -ne '') { ', error ' + $live62.Error } elseif (@($live62.Interfaces).Count -gt 0) { ', first state ' + $live62.Interfaces[0].State + ', connection query ' + $live62.Interfaces[0].ConnectionQuery } else { '' }))
$liveSample62 = Get-WifiAssociationSample -Moment 'start'
Assert-Equal '#62 sample: the envelope carries the exit code, the lines and the service reading' ("{0}/{1}/{2}" -f ($null -ne (Get-PropertyValue $liveSample62 'NetshExitCode' $null)), ($null -ne (Get-PropertyValue $liveSample62 'NetshLines' $null)), ($null -ne (Get-PropertyValue $liveSample62 'Api' $null))) 'True/True/True'
Assert-Equal '#62 sample: a live read that listed an interface exited 0 - the code is recorded, not left at its default' ((@($liveSample62.Interfaces).Count -eq 0) -or ((ConvertTo-IntSafe $liveSample62.NetshExitCode -1) -eq 0)) True
# The radio row, off the AST: it reads the sample through the view, writes the not-listed branch before the ordinary row,
# and the ordinary row says where its state came from.
$rfBody = Get-FunctionBody 'Add-WifiRfResult'
Assert-Equal '#62 row: the radio row reads the sample through the view and has the branch for an interface netsh printed nothing for' (($rfBody -match 'Get-WifiInterfaceView -Sample \$sample') -and ($rfBody -match '(?s)if \(-not \$wifi\.NetshListed\) \{.*?continue\s*\}.*?\$rssi = ')) True
Assert-Equal '#62 row: the ordinary row names the source of its state' ($rfBody -match '\$stateSource') True
Assert-Equal '#62 row r2: the manual check of the not-listed row is chosen by the witness - Refused, then AccessDenied, then the plain read' ($rfBody -match '(?s)if \(\$wifi\.Refused\) \{ \$details \+= "[^"]*ms-settings:privacy-location[^"]*" \}\s*elseif \(\$wifi\.AccessDenied\) \{ \$details \+= "[^"]*" \}\s*else \{ \$details \+= "[^"]*" \}') True

# ---------------------------------------------------------------------------
# backlog #65: the counters read again inside the sample window, at least Tests.RetransmissionIntervalSeconds apart,
# and a measured row placing its retransmissions in time beside the whole-window figure. Language-neutral throughout -
# numbers, tokens, statuses and line counts; the prose is each package's own.
# ---------------------------------------------------------------------------
# The one rule for the interval: 2 as shipped, 0 is off, and anything the file gets wrong is the shipped 2.
$thresholds65 = $script:Config.Thresholds
function Set-Interval65($value) {
    if ($null -eq $value) { $script:Config = [pscustomobject]@{ Thresholds = $thresholds65; Tests = [pscustomobject]@{} } }
    else { $script:Config = [pscustomobject]@{ Thresholds = $thresholds65; Tests = [pscustomobject]@{ RetransmissionIntervalSeconds = $value } } }
}
Set-Interval65 $null
Assert-Equal '#65 interval: absent from the file is the shipped 2' (Get-TcpIntervalSeconds) 2
Set-Interval65 0
Assert-Equal '#65 interval: 0 is off, not a mistake' (Get-TcpIntervalSeconds) 0
Set-Interval65 3
Assert-Equal '#65 interval: a whole number is taken as it is' (Get-TcpIntervalSeconds) 3
Set-Interval65 -1
Assert-Equal '#65 interval: a negative value is the shipped 2' (Get-TcpIntervalSeconds) 2
Set-Interval65 2.5
Assert-Equal '#65 interval: a fraction is the shipped 2' (Get-TcpIntervalSeconds) 2
Set-Interval65 'abc'
Assert-Equal '#65 interval: text is the shipped 2' (Get-TcpIntervalSeconds) 2
Set-Interval65 2

# The read inside the window: one attempt per class, never a second, its failure kept with the phase that names it.
Reset-CimStub @{ $v4Class = @('fail') }
$intervalRead = Read-TcpIntervalCounters
Assert-Equal '#65 read: the class that failed was attempted once' (Get-CimCallCount $v4Class) 1
Assert-Equal '#65 read: the class after the one that failed is not attempted in that pass (PR #56, round 1)' ("{0}/{1}" -f (Get-CimCallCount $v6Class), $intervalRead.Counters.ContainsKey('TCPv6')) '0/False'
Assert-Equal '#65 read: no counter is invented for the one that failed' ($intervalRead.Counters.ContainsKey('TCPv4')) False
Assert-Equal '#65 read: the failed attempt is kept with its phase and its number' ("{0}/{1}/{2}" -f @($intervalRead.FailedAttempts).Count, @($intervalRead.FailedAttempts)[0].Phase, @($intervalRead.FailedAttempts)[0].Attempt) '1/interval/1'
Assert-Equal '#65 read: and is named apart from a measured read of the same number' ((Format-TcpAttemptList @($intervalRead.FailedAttempts)) -ne (Format-TcpAttemptList @([pscustomobject]@{ Protocol = 'TCPv4'; Phase = 'read'; Attempt = 1 }))) True
Reset-CimStub @{}
$intervalClean = Read-TcpIntervalCounters
Assert-Equal '#65 read: a clean read carries both classes and no failure' ("{0}/{1}" -f $intervalClean.Counters.Count, @($intervalClean.FailedAttempts).Count) '2/0'
Assert-Equal '#65 read: the reader passes no attempt count, so the helper makes its single attempt' ((Get-FunctionBody 'Read-TcpIntervalCounters') -match '-Attempts') False

# The due-check: nothing before the interval has passed, one read once it has, none at all where the interval is 0,
# and after a read that failed nothing more for the run - not even through the extension.
$script:TcpIntervalSampling = $null
Reset-CimStub @{}
Start-TcpIntervalSampling -IntervalSeconds 2 -Since (Get-Date)
Invoke-TcpIntervalReadIfDue
Assert-Equal '#65 due: not yet' (@($script:TcpIntervalSampling.Reads).Count) 0
$script:TcpIntervalSampling.LastRead = (Get-Date).AddSeconds(-3)
Invoke-TcpIntervalReadIfDue
Assert-Equal '#65 due: one read once the interval has passed' (@($script:TcpIntervalSampling.Reads).Count) 1
Assert-Equal '#65 due: the reading carries both classes' ($script:TcpIntervalSampling.Reads[0].Counters.Count) 2
Invoke-TcpIntervalReadIfDue
Assert-Equal '#65 due: and not again until the next interval' (@($script:TcpIntervalSampling.Reads).Count) 1
Assert-Equal '#65 due: the last read is the reference for the next' (((Get-Date) - $script:TcpIntervalSampling.LastRead).TotalSeconds -lt 2) True
Stop-TcpIntervalSampling
$script:TcpIntervalSampling.LastRead = (Get-Date).AddSeconds(-3)
Invoke-TcpIntervalReadIfDue
Assert-Equal '#65 due: nothing after the window is closed' (@($script:TcpIntervalSampling.Reads).Count) 1
$script:TcpIntervalSampling = $null
Reset-CimStub @{}
Start-TcpIntervalSampling -IntervalSeconds 0 -Since (Get-Date).AddSeconds(-10)
Invoke-TcpIntervalReadIfDue
Assert-Equal '#65 due: an interval of 0 reads nothing' ("{0}/{1}" -f @($script:TcpIntervalSampling.Reads).Count, $script:TcpIntervalSampling.Active) '0/False'
$script:TcpIntervalSampling = $null
Reset-CimStub @{ $v4Class = @('fail') }
Start-TcpIntervalSampling -IntervalSeconds 2 -Since (Get-Date).AddSeconds(-3)
Invoke-TcpIntervalReadIfDue
$stopped65 = $script:TcpIntervalSampling
Assert-Equal '#65 stop: the failed read is kept, with its attempt' ("{0}/{1}" -f @($stopped65.Reads).Count, @($stopped65.FailedAttempts).Count) '1/1'
Assert-Equal '#65 stop: the sampling is over, named by the class that failed' ("{0}/{1}/{2}" -f $stopped65.Active, ($null -ne $stopped65.StoppedAt), $stopped65.StopReason) 'False/True/TCPv4'
Assert-Equal '#65 stop: the class that failed was attempted once, not twice' (Get-CimCallCount $v4Class) 1
Assert-Equal '#65 stop: the pass stopped at the class that failed - the other was not attempted' ("{0}/{1}" -f (Get-CimCallCount $v6Class), $stopped65.Reads[0].Counters.ContainsKey('TCPv6')) '0/False'
Start-TcpIntervalSampling -IntervalSeconds 2 -Since (Get-Date).AddSeconds(-3) -Extension
Invoke-TcpIntervalReadIfDue
Assert-Equal '#65 stop: the extension does not reopen a stopped sampling' ("{0}/{1}" -f $stopped65.Active, @($stopped65.Reads).Count) 'False/1'
Assert-Equal '#65 stop: the stop line names the class' ((@(Get-TcpIntervalStopLine -State $stopped65) -join '') -match 'TCPv4') True
Assert-Equal '#65 stop: no stop line without a stop' (@(Get-TcpIntervalStopLine -State ([pscustomobject]@{ StoppedAt = $null })).Count) 0

# The table: the window's own readings in stamp order, a reading outside the window left out, deltas per interval.
$t65 = Get-Date '2026-09-13T07:00:00'
function New-Read65($offset, $v4Sent, $v4Retrans, $v6Sent = 5000, $v6Retrans = 0, $extension = $false) {
    return [pscustomobject]@{ Timestamp = $t65.AddSeconds($offset); Counters = @{ 'TCPv4' = (New-CounterFixture 'TCPv4' $t65.AddSeconds($offset) $v4Sent $v4Retrans); 'TCPv6' = (New-CounterFixture 'TCPv6' $t65.AddSeconds($offset + 0.1) $v6Sent $v6Retrans) }; FailedAttempts = @(); Extension = $extension }
}
$start65 = New-CounterFixture 'TCPv4' $t65 100000 1000
$end65 = New-CounterFixture 'TCPv4' $t65.AddSeconds(8.8) 103000 1057
$burstReads = @((New-Read65 2.1 100120 1000), (New-Read65 4.3 100460 1048), (New-Read65 6.4 100670 1053), (New-Read65 12.0 200000 9999))
$burstTable = @(Get-TcpIntervalTable -Protocol 'TCPv4' -Start $start65 -End $end65 -Reads $burstReads)
Assert-Equal '#65 table: three readings inside the window make four intervals, the one after it left out' $burstTable.Count 4
Assert-Equal '#65 table: each interval carries its own deltas' ((@($burstTable | ForEach-Object { "{0}/{1}" -f $_.Sent, $_.Retransmitted })) -join ',') '120/0,340/48,210/5,2330/4'
Assert-Equal '#65 table: and its own seconds, from the stamps' ((@($burstTable | ForEach-Object { [math]::Round($_.Seconds, 1) })) -join ',') '2.1,2.2,2.1,2.4'
Assert-Equal '#65 table: the offsets run from the baseline stamp' ("{0}-{1}" -f $burstTable[1].FromSeconds, $burstTable[1].ToSeconds) '2.1-4.3'
Assert-Equal '#65 table: a reading that went backwards empties the table' (@(Get-TcpIntervalTable -Protocol 'TCPv4' -Start $start65 -End $end65 -Reads @((New-Read65 3.0 99000 1000))).Count) 0
Assert-Equal '#65 table: no reading inside the window is one interval' (@(Get-TcpIntervalTable -Protocol 'TCPv4' -Start $start65 -End $end65 -Reads @()).Count) 1
# A pass that stopped at TCPv6 (PR #56, round 1) carries TCPv4's reading alone: TCPv4's table takes it, TCPv6's skips it.
$partialRead65 = [pscustomobject]@{ Timestamp = $t65.AddSeconds(2); Counters = @{ 'TCPv4' = (New-CounterFixture 'TCPv4' $t65.AddSeconds(2) 100100 1000) }; FailedAttempts = @() }
Assert-Equal '#65 table: a read where the second class failed keeps the first class''s reading, and the other table skips it' ("{0}/{1}" -f (@(Get-TcpIntervalTable -Protocol 'TCPv4' -Start $start65 -End $end65 -Reads @($partialRead65))).Count, (@(Get-TcpIntervalTable -Protocol 'TCPv6' -Start (New-CounterFixture 'TCPv6' $t65 5000 0) -End (New-CounterFixture 'TCPv6' $t65.AddSeconds(8.9) 5000 0) -Reads @($partialRead65))).Count) '2/1'
function New-State65($reads, $interval = 2, $failed = @(), $stoppedAt = $null, $reason = '') {
    return [pscustomobject]@{ Active = $false; IntervalSeconds = $interval; LastRead = $t65; Extension = $false; Reads = @($reads); FailedAttempts = @($failed); StoppedAt = $stoppedAt; StopReason = $reason }
}
Assert-Equal '#65 lines: a backwards reading is one sentence' (@(Get-TcpDistributionLines -Protocol 'TCPv4' -Intervals @() -RetransDelta 5 -SampleSeconds 8 -State (New-State65 @())).Count) 1
Assert-Equal '#65 lines: nothing to place where nothing was retransmitted' (@(Get-TcpDistributionLines -Protocol 'TCPv4' -Intervals $burstTable -RetransDelta 0 -SampleSeconds 8.8 -State (New-State65 $burstReads)).Count) 0
Assert-Equal '#65 lines: nothing where the reads are off' (@(Get-TcpDistributionLines -Protocol 'TCPv4' -Intervals $burstTable -RetransDelta 57 -SampleSeconds 8.8 -State (New-State65 $burstReads 0)).Count) 0
Assert-Equal '#65 lines: the header, four intervals, the worst and the disclaimer' (@(Get-TcpDistributionLines -Protocol 'TCPv4' -Intervals $burstTable -RetransDelta 57 -SampleSeconds 8.8 -State (New-State65 $burstReads)).Count) 7

# The acceptance's two cases: a burst inside a healthy window and an even spread that reach the same totals - the same
# status and the same message, and only the placement telling them apart.
function Get-Rows65($reads, $sent, $retrans, $interval = 2, $failed = @(), $stoppedAt = $null, $reason = '') {
    $script:TcpIntervalSampling = New-State65 $reads $interval $failed $stoppedAt $reason
    $before = [pscustomobject]@{ Timestamp = $t65; Counters = @{ 'TCPv4' = (New-CounterFixture 'TCPv4' $t65 100000 1000); 'TCPv6' = (New-CounterFixture 'TCPv6' $t65.AddSeconds(0.1) 5000 0) }; Errors = @(); FailedAttempts = @(); WarmUpFailures = @() }
    $after = [pscustomobject]@{ Timestamp = $t65.AddSeconds(8.9); Counters = @{ 'TCPv4' = (New-CounterFixture 'TCPv4' $t65.AddSeconds(8.8) (100000 + $sent) (1000 + $retrans)); 'TCPv6' = (New-CounterFixture 'TCPv6' $t65.AddSeconds(8.9) 5000 0) }; Errors = @(); FailedAttempts = @(); WarmUpFailures = @() }
    $script:TcpRows = New-Object System.Collections.ArrayList
    Compare-TcpCounters -Before $before -After $after
    return @($script:TcpRows)
}
$burstRows = Get-Rows65 $burstReads 3000 57
$burstV4 = @($burstRows | Where-Object { $_.Check -eq 'TCPv4' })[0]
$evenReads = @((New-Read65 2.1 100750 1014), (New-Read65 4.3 101500 1028), (New-Read65 6.4 102250 1043))
$evenRows = Get-Rows65 $evenReads 3000 57
$evenV4 = @($evenRows | Where-Object { $_.Check -eq 'TCPv4' })[0]
Assert-Equal '#65 rows: 57 of 3000 is 1.9% either way, a pass either way' ("{0}/{1}" -f $burstV4.Status, $evenV4.Status) 'PASS/PASS'
Assert-Equal '#65 rows: and the same message' ($burstV4.Message -eq $evenV4.Message) True
# The worst-interval sentence orders its numbers differently in the two packages, so a line is asked for all of them at once.
function Test-DetailLineHasAll($row, [string[]]$numbers) {
    $lines = @([string]$row.Details -split "`r`n|`n")
    return (@($lines | Where-Object { $line = $_; @($numbers | Where-Object { $line -match ('(?<![\d.])' + [regex]::Escape($_) + '(?![\d.])') }).Count -eq $numbers.Count }).Count -gt 0)
}
Assert-Equal '#65 rows: the burst names 48 of the 57 in one interval, 84%' (Test-DetailLineHasAll $burstV4 @('48', '57', '84')) True
Assert-Equal '#65 rows: in 2.2 seconds, a quarter of the window' (Test-DetailLineHasAll $burstV4 @('84', '2.2', '25')) True
Assert-Equal '#65 rows: the even spread names 15 of the 57, 26%' (Test-DetailLineHasAll $evenV4 @('15', '57', '26')) True
Assert-Equal '#65 rows: four interval lines on each' ("{0}/{1}" -f (Get-DetailMatchCount $burstV4 '(?m)^  [\d.]+-[\d.]+ '), (Get-DetailMatchCount $evenV4 '(?m)^  [\d.]+-[\d.]+ ')) '4/4'
Assert-Equal '#65 rows: the interval lines carry counts and no percentage' ((@(([string]$burstV4.Details -split "`r`n|`n") | Where-Object { $_ -match '^  [\d.]+-[\d.]+ ' -and $_ -match '%' })).Count) 0
Assert-Equal '#65 rows: the whole-window figures are untouched' (($burstV4.Details -match '(?<![\d.])3000(?![\d.])') -and ($burstV4.Message -match '(?<![\d.])57(?![\d.])')) True
Assert-Equal '#65 rows: the row decides the run as it did' $burstV4.Weightless False
Assert-Equal '#65 rows: the other protocol, with nothing retransmitted, places nothing' (Get-DetailMatchCount @($burstRows | Where-Object { $_.Check -eq 'TCPv6' })[0] '(?m)^  [\d.]+-[\d.]+ ') 0
$quietV4 = @((Get-Rows65 $burstReads 3000 0) | Where-Object { $_.Check -eq 'TCPv4' })[0]
Assert-Equal '#65 rows: a window without a retransmission has nothing to place, and says nothing' (Get-DetailMatchCount $quietV4 '(?m)^  [\d.]+-[\d.]+ ') 0
$offV4 = @((Get-Rows65 $burstReads 3000 57 0) | Where-Object { $_.Check -eq 'TCPv4' })[0]
Assert-Equal '#65 rows: with the reads off, the row is the row it was' ("{0}/{1}" -f (Get-DetailMatchCount $offV4 '(?m)^  [\d.]+-[\d.]+ '), $offV4.Status) '0/PASS'
$noneInsideV4 = @((Get-Rows65 @() 3000 57) | Where-Object { $_.Check -eq 'TCPv4' })[0]
Assert-Equal '#65 rows: no read inside the window is one sentence more than the row with the reads off, and no interval line' ("{0}/{1}" -f (Get-DetailMatchCount $noneInsideV4 '(?m)^  [\d.]+-[\d.]+ '), ((Get-DetailLineCount $noneInsideV4) - (Get-DetailLineCount $offV4))) '0/1'

# A read inside the window that failed: named on both protocols' rows - it lies inside both windows - with its seconds
# in the note and the stop line on every row; no row of its own, no status moved, the intervals before it standing.
$failed65 = @([pscustomobject]@{ Protocol = 'TCPv4'; Phase = 'interval'; Attempt = 1; Seconds = 8.3; Error = 'Timed out'; Extension = $false })
$stopReads = @((New-Read65 2.1 100120 1000), [pscustomobject]@{ Timestamp = $t65.AddSeconds(4.5); Counters = @{}; FailedAttempts = $failed65; Extension = $false })
$stopRows = Get-Rows65 $stopReads 3000 57 2 $failed65 $t65.AddSeconds(4.5) 'TCPv4'
Assert-Equal '#65 failure: still one row per protocol, no row for the failed read' (@($stopRows).Count) 2
$stopV4 = @($stopRows | Where-Object { $_.Check -eq 'TCPv4' })[0]
$stopV6 = @($stopRows | Where-Object { $_.Check -eq 'TCPv6' })[0]
Assert-Equal '#65 failure: the seconds it spent are in both rows'' window notes' (($stopV4.Details -match '(?<![\d.])8\.3(?![\d.])') -and ($stopV6.Details -match '(?<![\d.])8\.3(?![\d.])')) True
Assert-Equal '#65 failure: named as a read between the samples on both' (($stopV4.Details -match 'TCPv4 #1') -and ($stopV6.Details -match 'TCPv4 #1')) True
Assert-Equal '#65 failure: the stop line is on both rows, with the time' (($stopV4.Details -match '07:00:04') -and ($stopV6.Details -match '07:00:04')) True
Assert-Equal '#65 failure: the status is the measurement''s' $stopV4.Status 'PASS'
Assert-Equal '#65 failure: the intervals before it stand - two, the last running to the ending sample' (Get-DetailMatchCount $stopV4 '(?m)^  [\d.]+-[\d.]+ ') 2
# And where a counter could not be read at all, its Unable to Check row carries the stop line as well - the failed
# read is named on every row this analysis writes.
$script:TcpIntervalSampling = New-State65 $stopReads 2 $failed65 $t65.AddSeconds(4.5) 'TCPv4'
$errBefore65 = [pscustomobject]@{ Timestamp = $t65; Counters = @{ 'TCPv4' = (New-CounterFixture 'TCPv4' $t65 100000 1000); 'TCPv6' = (New-CounterFixture 'TCPv6' $t65.AddSeconds(0.1) 5000 0) }; Errors = @(); FailedAttempts = @(); WarmUpFailures = @() }
$errAfter65 = [pscustomobject]@{ Timestamp = $t65.AddSeconds(24.9); Counters = @{ 'TCPv6' = (New-CounterFixture 'TCPv6' $t65.AddSeconds(24.9) 5000 0) }; Errors = @([pscustomobject]@{ Protocol = 'TCPv4'; Error = 'Timed out'; Diagnostics = '' }); FailedAttempts = @([pscustomobject]@{ Protocol = 'TCPv4'; Attempt = 1; Seconds = 8.0; Error = 'Timed out' }, [pscustomobject]@{ Protocol = 'TCPv4'; Attempt = 2; Seconds = 8.0; Error = 'Timed out' }); WarmUpFailures = @() }
$script:TcpRows = New-Object System.Collections.ArrayList
Compare-TcpCounters -Before $errBefore65 -After $errAfter65
$errRow65 = @($script:TcpRows | Where-Object { $_.Status -eq 'ERROR' })[0]
Assert-Equal '#65 failure: the row of a counter that could not be read carries the stop line too' ($errRow65.Details -match '07:00:04') True
# The window note of the protocol that was read sums the ending read's two failed attempts (8 + 8) and the failed read
# inside the window (8.3) on the line that names them - 24.3, which a note that left the interior read out cannot print.
Assert-Equal '#65 failure: and the protocol that was read still names the failed read inside its window, its seconds in the note' ((Get-DetailLine @($script:TcpRows | Where-Object { $_.Check -eq 'TCPv6' })[0] 'TCPv4 #1') -match '(?<![\d.])24\.3(?![\d.])') True

# Through an extension: a failed read taken while the window was being extended is inside only the windows the
# extension closed - TCPv4 here - and outside TCPv6's, whose reading kept the first stamp; the stop line is on both.
$extFailed = @([pscustomobject]@{ Protocol = 'TCPv4'; Phase = 'interval'; Attempt = 1; Seconds = 8.0; Error = 'Timed out'; Extension = $true })
$script:TcpIntervalSampling = New-State65 @((New-Read65 2.1 100120 1000), [pscustomobject]@{ Timestamp = $t65.AddSeconds(10.5); Counters = @{}; FailedAttempts = $extFailed; Extension = $true }) 2 $extFailed $t65.AddSeconds(10.5) 'TCPv4'
$extBefore = [pscustomobject]@{ Timestamp = $t65; Counters = @{ 'TCPv4' = (New-CounterFixture 'TCPv4' $t65 100000 1000); 'TCPv6' = (New-CounterFixture 'TCPv6' $t65.AddSeconds(0.1) 5000 0) }; Errors = @(); FailedAttempts = @(); WarmUpFailures = @() }
$extAfter = [pscustomobject]@{ Timestamp = $t65.AddSeconds(18.9); Counters = @{ 'TCPv4' = (New-CounterFixture 'TCPv4' $t65.AddSeconds(18.8) 100400 1006); 'TCPv6' = (New-CounterFixture 'TCPv6' $t65.AddSeconds(8.9) 5000 0) }; Errors = @(); FailedAttempts = @(); WarmUpFailures = @(); Extended = $true; ExtendedProtocols = @('TCPv4') }
$script:TcpRows = New-Object System.Collections.ArrayList
Compare-TcpCounters -Before $extBefore -After $extAfter
$extV4 = @($script:TcpRows | Where-Object { $_.Check -eq 'TCPv4' })[0]
$extV6 = @($script:TcpRows | Where-Object { $_.Check -eq 'TCPv6' })[0]
Assert-Equal '#65 extension: the failed read is inside the window the extension closed' ($extV4.Details -match '(?<![\d.])8(?![\d.])[^\r\n]*TCPv4 #1') True
Assert-Equal '#65 extension: and not inside the one it did not close' ($extV6.Details -match 'TCPv4 #1') False
Assert-Equal '#65 extension: the stop line is on both' (($extV4.Details -match '07:00:10') -and ($extV6.Details -match '07:00:10')) True
$script:TcpIntervalSampling = $null

# Where the reads are taken, read off the AST: after every step, inside the wait, inside the spread probes' slices;
# opened at the baseline stamp, closed before the ending read, reopened for the extension and closed before its read;
# the state cleared with the results; and no fourth snapshot call - the read inside the window is its own reader.
Assert-Equal '#65 ast: the step wrapper runs the due-check once, after its try and catch' ((Get-FunctionBody 'Invoke-CheckStep') -match '(?s)catch \{.*\}\s*(#[^\r\n]*\s*)*Invoke-TcpIntervalReadIfDue\s*return \$result') True
Assert-Equal '#65 ast: and only once' (([regex]::Matches((Get-FunctionBody 'Invoke-CheckStep'), 'Invoke-TcpIntervalReadIfDue')).Count) 1
Assert-Equal '#65 ast: the wait loop runs it after every sleep - behind the deadline recheck since round 2' ((Get-FunctionBody 'Wait-ForMinimumTcpSample') -match 'Start-Sleep -Milliseconds[^\r\n]*\s*(#[^\r\n]*\s*)*if [^\r\n]*\s*Invoke-TcpIntervalReadIfDue') True
Assert-Equal '#65 ast: and the wait is clock-based, so a read inside it lengthens nothing' ((Get-FunctionBody 'Wait-ForMinimumTcpSample') -match 'while \(\$true\)') True
Assert-Equal '#65 ast: the spread probes run it after every slice' ((Get-FunctionBody 'Invoke-PingMeasurement') -match 'Start-Sleep -Milliseconds \$sliceMs \}\s*Invoke-TcpIntervalReadIfDue') True
$runBody65 = Get-FunctionBody 'Run-AllChecks'
Assert-Equal '#65 ast: the run clears the state with the results' ($runBody65 -match '\$script:TcpIntervalSampling = \$null') True
Assert-Equal '#65 ast: opens the reads at the baseline stamp' ($runBody65 -match '\$tcpSampleStart = Get-Date\s*(#[^\r\n]*\s*)*Start-TcpIntervalSampling -IntervalSeconds \(Get-TcpIntervalSeconds\) -Since \$tcpSampleStart') True
Assert-Equal '#65 ast: closes them before the ending read' ($runBody65 -match 'Stop-TcpIntervalSampling\s*return \(Get-TcpCounterSnapshot\)') True
Assert-Equal '#65 ast: reopens them for the extension, with the first ending snapshot as the boundary point and the extension''s deadline, and closes them before its read' ($runBody65 -match '(?s)Start-TcpIntervalSampling -IntervalSeconds \(Get-TcpIntervalSeconds\) -Since \(Get-Date\) -Extension -Boundary \$tcpAfter -Deadline \(Get-Date\)\.AddSeconds\(\$minimumSampleSeconds\)\s*Wait-ForMinimumTcpSample[^\r\n]*\s*Stop-TcpIntervalSampling\s*return \(Merge-TcpEndingSnapshot') True
Assert-Equal '#65 ast: the configuration check names the key' ((Get-FunctionBody 'Test-ConfigurationSemantics') -match 'RetransmissionIntervalSeconds') True
Assert-Equal '#65 ast: the run options carry it for the profile' ((Get-FunctionBody 'Set-RunOptions') -match 'IntervalSeconds = Get-TcpIntervalSeconds') True
Assert-Equal '#65 ast: no snapshot call was added' (@($scriptAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Get-TcpCounterSnapshot' }, $true)).Count) 3


# PR #56, round 2. (a) A read due on the last sleep of the wait would run after the minimum had passed and add its whole
# cost to the run: the wait is loaded with the progress writer stubbed, and the clock decides, so these take a few seconds.
function Set-UiProgress { param([int]$Percent, [string]$Text) }
$script:GuiAvailable = $false
$script:TcpIntervalSampling = $null
Reset-CimStub @{}
Start-TcpIntervalSampling -IntervalSeconds 1 -Since (Get-Date).AddSeconds(-5)
Wait-ForMinimumTcpSample -StartTime (Get-Date).AddSeconds(-5) -MinimumSeconds 1
Assert-Equal '#65 wait r2: a wait already past its minimum reads nothing' (@($script:TcpIntervalSampling.Reads).Count) 0
Wait-ForMinimumTcpSample -StartTime (Get-Date).AddSeconds(-0.8) -MinimumSeconds 1
Assert-Equal '#65 wait r2: a read due on the last sleep is not taken, because the minimum had passed' (@($script:TcpIntervalSampling.Reads).Count) 0
$waitStarted65 = Get-Date
Wait-ForMinimumTcpSample -StartTime (Get-Date) -MinimumSeconds 3
$waited65 = ((Get-Date) - $waitStarted65).TotalSeconds
Assert-Equal '#65 wait r2: with time left the reads are taken inside the wait, and the wait still ends at its minimum' ("{0}/{1}" -f (@($script:TcpIntervalSampling.Reads).Count -ge 1), (($waited65 -ge 3) -and ($waited65 -lt 4.5))) 'True/True'
Assert-Equal '#65 wait r2: the deadline is checked between the sleep and the due-check, off the AST' ((Get-FunctionBody 'Wait-ForMinimumTcpSample') -match 'Start-Sleep -Milliseconds[^\r\n]*\s*(#[^\r\n]*\s*)*if \(\(\(Get-Date\) - \$StartTime\)\.TotalSeconds -ge \$MinimumSeconds\) \{ return \}\s*Invoke-TcpIntervalReadIfDue') True
# (b) The reading that closed the first window stays a point of the table when the window is extended, so the intervals
# of the first window and of the extension are told apart; a protocol the extension did not close, whose ending stamp is
# that very reading, does not count it twice.
$script:TcpIntervalSampling = $null
$boundary65 = [pscustomobject]@{ Timestamp = $t65.AddSeconds(8.9); Counters = @{ 'TCPv4' = (New-CounterFixture 'TCPv4' $t65.AddSeconds(8.8) 100300 1004); 'TCPv6' = (New-CounterFixture 'TCPv6' $t65.AddSeconds(8.9) 5000 0) }; Errors = @(); FailedAttempts = @(); WarmUpFailures = @() }
Start-TcpIntervalSampling -IntervalSeconds 2 -Since (Get-Date) -Extension -Boundary $boundary65
Assert-Equal '#65 boundary r2: reopening for the extension adds the first ending reading as a point, marked as one' ("{0}/{1}/{2}" -f @($script:TcpIntervalSampling.Reads).Count, [bool]@($script:TcpIntervalSampling.Reads)[0].Boundary, @($script:TcpIntervalSampling.Reads)[0].Counters.Count) '1/True/2'
$script:TcpIntervalSampling = $null
Start-TcpIntervalSampling -IntervalSeconds 2 -Since (Get-Date)
Assert-Equal '#65 boundary r2: the first opening adds no point' (@($script:TcpIntervalSampling.Reads).Count) 0
$extReads65 = @((New-Read65 2.1 100120 1000), [pscustomobject]@{ Timestamp = $t65.AddSeconds(8.9); Counters = $boundary65.Counters; FailedAttempts = @(); Extension = $false; Boundary = $true }, [pscustomobject]@{ Timestamp = $t65.AddSeconds(10.5); Counters = @{}; FailedAttempts = $extFailed; Extension = $true })
$extV4Table65 = @(Get-TcpIntervalTable -Protocol 'TCPv4' -Start (New-CounterFixture 'TCPv4' $t65 100000 1000) -End (New-CounterFixture 'TCPv4' $t65.AddSeconds(18.8) 100400 1006) -Reads $extReads65)
Assert-Equal '#65 boundary r2: the extended window is told apart from the first - three intervals, the boundary at 8.8' ("{0}/{1}" -f $extV4Table65.Count, $extV4Table65[1].ToSeconds) '3/8.8'
Assert-Equal '#65 boundary r2: with the first window''s and the extension''s retransmissions apart' ((@($extV4Table65 | ForEach-Object { $_.Retransmitted })) -join ',') '0,4,2'
Assert-Equal '#65 boundary r2: a protocol the extension did not close does not count the boundary twice' (@(Get-TcpIntervalTable -Protocol 'TCPv6' -Start (New-CounterFixture 'TCPv6' $t65.AddSeconds(0.1) 5000 0) -End (New-CounterFixture 'TCPv6' $t65.AddSeconds(8.9) 5000 0) -Reads $extReads65).Count) 2
$script:TcpIntervalSampling = $null

# PR #56, round 3: the reads close at the wait's deadline, before the two steps that run between the wait and the ending
# read - so no read is taken after the minimum on that path either.
Assert-Equal '#65 ast r3: the run closes the reads at the wait''s deadline' ((Get-FunctionBody 'Run-AllChecks') -match 'Wait-ForMinimumTcpSample -StartTime \$tcpSampleStart -MinimumSeconds \$minimumSampleSeconds\s*(#[^\r\n]*\s*)*Stop-TcpIntervalSampling') True

# PR #56, round 4: a window with retransmissions and no reading inside it says why - none was due, or the reads stopped at
# a read that failed before this window had one - and the two sentences differ, because the second row also names the
# failed read and its seconds, which "none was due" beside them would contradict.
$oneInterval65 = @(Get-TcpIntervalTable -Protocol 'TCPv4' -Start $start65 -End $end65 -Reads @())
$noneDueLine65 = @(Get-TcpDistributionLines -Protocol 'TCPv4' -Intervals $oneInterval65 -RetransDelta 57 -SampleSeconds 8.8 -State (New-State65 @()))[0]
$failedFirstLine65 = @(Get-TcpDistributionLines -Protocol 'TCPv4' -Intervals $oneInterval65 -RetransDelta 57 -SampleSeconds 8.8 -State (New-State65 @() 2 $failed65 $t65.AddSeconds(2.5) 'TCPv4') -FailedInside $failed65)[0]
Assert-Equal '#65 lines r4: one sentence either way' ("{0}/{1}" -f @(Get-TcpDistributionLines -Protocol 'TCPv4' -Intervals $oneInterval65 -RetransDelta 57 -SampleSeconds 8.8 -State (New-State65 @())).Count, @(Get-TcpDistributionLines -Protocol 'TCPv4' -Intervals $oneInterval65 -RetransDelta 57 -SampleSeconds 8.8 -State (New-State65 @() 2 $failed65 $t65.AddSeconds(2.5) 'TCPv4') -FailedInside $failed65).Count) '1/1'
Assert-Equal '#65 lines r4: and not the same sentence - a failed first read is not "none was due"' ($failedFirstLine65 -ne $noneDueLine65) True
$failedFirstRows65 = Get-Rows65 @([pscustomobject]@{ Timestamp = $t65.AddSeconds(2.5); Counters = @{}; FailedAttempts = $failed65; Extension = $false }) 3000 57 2 $failed65 $t65.AddSeconds(2.5) 'TCPv4'
$failedFirstV4 = @($failedFirstRows65 | Where-Object { $_.Check -eq 'TCPv4' })[0]
Assert-Equal '#65 rows r4: the row whose first read inside the window failed carries that sentence, the failed read and the stop line, and not "none was due"' ("{0}/{1}/{2}/{3}" -f ($failedFirstV4.Details -like ('*' + $failedFirstLine65 + '*')), ($failedFirstV4.Details -like ('*' + $noneDueLine65 + '*')), ($failedFirstV4.Details -match 'TCPv4 #1'), ($failedFirstV4.Details -match '07:00:02')) 'True/False/True/True'
Assert-Equal '#65 rows r4: the row with no read due keeps its own sentence' ($noneInsideV4.Details -like ('*' + $noneDueLine65 + '*')) True

# PR #56, round 5: the window's deadline travels with the state, and the due-check takes nothing once it has passed -
# from any path - which is the one rule behind the three paths rounds 2, 3 and 5 found one at a time.
$script:TcpIntervalSampling = $null
Reset-CimStub @{}
Start-TcpIntervalSampling -IntervalSeconds 1 -Since (Get-Date).AddSeconds(-5) -Deadline (Get-Date).AddSeconds(-1)
Invoke-TcpIntervalReadIfDue
Assert-Equal '#65 deadline r5: a read due after the deadline is not taken, and the sampling closes' ("{0}/{1}" -f @($script:TcpIntervalSampling.Reads).Count, $script:TcpIntervalSampling.Active) '0/False'
$script:TcpIntervalSampling = $null
Start-TcpIntervalSampling -IntervalSeconds 1 -Since (Get-Date).AddSeconds(-5) -Deadline (Get-Date).AddSeconds(30)
Invoke-TcpIntervalReadIfDue
Assert-Equal '#65 deadline r5: before the deadline the read is taken' (@($script:TcpIntervalSampling.Reads).Count) 1
$script:TcpIntervalSampling = $null
Start-TcpIntervalSampling -IntervalSeconds 1 -Since (Get-Date).AddSeconds(-5)
Invoke-TcpIntervalReadIfDue
Assert-Equal '#65 deadline r5: a state opened without a deadline reads as before' (@($script:TcpIntervalSampling.Reads).Count) 1
$script:TcpIntervalSampling = $null
Assert-Equal '#65 deadline r5: the run opens the reads with the window''s deadline - the baseline stamp plus the configured minimum' ($runBody65 -match 'Start-TcpIntervalSampling -IntervalSeconds \(Get-TcpIntervalSeconds\) -Since \$tcpSampleStart -Deadline \$tcpSampleStart\.AddSeconds\(\$minimumSampleSeconds\)') True
Assert-Equal '#65 deadline r5: and the minimum is computed before the window opens' ($runBody65.IndexOf('$minimumSampleSeconds = [math]::Max(1,') -lt $runBody65.IndexOf('$tcpSampleStart = Get-Date')) True
Assert-Equal '#65 deadline r5: the due-check refuses past the deadline before it asks whether a read is due' ((Get-FunctionBody 'Invoke-TcpIntervalReadIfDue') -match '(?s)if \(\$null -ne \$state\.Deadline -and \(Get-Date\) -ge \$state\.Deadline\) \{ \$state\.Active = \$false; return \}.*?TotalSeconds -lt \$state\.IntervalSeconds') True

# PR #56, round 7: the sentence follows the failed reads inside THIS protocol's window. A read that failed during the
# extension is outside the window of a protocol the extension did not close - its ending stamp is the first one - so
# its block says none was due, while the protocol the extension closed, with that read inside its window, says the
# reads stopped at it.
$script:TcpIntervalSampling = New-State65 @([pscustomobject]@{ Timestamp = $t65.AddSeconds(10.5); Counters = @{}; FailedAttempts = $extFailed; Extension = $true }) 2 $extFailed $t65.AddSeconds(10.5) 'TCPv4'
$r7Before = [pscustomobject]@{ Timestamp = $t65; Counters = @{ 'TCPv4' = (New-CounterFixture 'TCPv4' $t65 100000 1000); 'TCPv6' = (New-CounterFixture 'TCPv6' $t65.AddSeconds(0.1) 5000 100) }; Errors = @(); FailedAttempts = @(); WarmUpFailures = @() }
$r7After = [pscustomobject]@{ Timestamp = $t65.AddSeconds(18.9); Counters = @{ 'TCPv4' = (New-CounterFixture 'TCPv4' $t65.AddSeconds(18.8) 100400 1006); 'TCPv6' = (New-CounterFixture 'TCPv6' $t65.AddSeconds(8.9) 5400 106) }; Errors = @(); FailedAttempts = @(); WarmUpFailures = @(); Extended = $true; ExtendedProtocols = @('TCPv4') }
$script:TcpRows = New-Object System.Collections.ArrayList
Compare-TcpCounters -Before $r7Before -After $r7After
$r7V4 = @($script:TcpRows | Where-Object { $_.Check -eq 'TCPv4' })[0]
$r7V6 = @($script:TcpRows | Where-Object { $_.Check -eq 'TCPv6' })[0]
$noneDue7 = @(Get-TcpDistributionLines -Protocol 'TCPv6' -Intervals @(Get-TcpIntervalTable -Protocol 'TCPv6' -Start $r7Before.Counters['TCPv6'] -End $r7After.Counters['TCPv6'] -Reads @()) -RetransDelta 6 -SampleSeconds 8.8 -State $script:TcpIntervalSampling -FailedInside @())[0]
$failedFirst7 = @(Get-TcpDistributionLines -Protocol 'TCPv4' -Intervals @(Get-TcpIntervalTable -Protocol 'TCPv4' -Start $r7Before.Counters['TCPv4'] -End $r7After.Counters['TCPv4'] -Reads @()) -RetransDelta 6 -SampleSeconds 18.8 -State $script:TcpIntervalSampling -FailedInside $extFailed)[0]
Assert-Equal '#65 rows r7: a protocol the extension did not close, the failed read outside its window, says none was due' ("{0}/{1}" -f ($r7V6.Details -like ('*' + $noneDue7 + '*')), ($r7V6.Details -like ('*' + $failedFirst7 + '*'))) 'True/False'
Assert-Equal '#65 rows r7: the protocol the extension closed, that read inside its window, says the reads stopped at it' ("{0}/{1}" -f ($r7V4.Details -like ('*' + $failedFirst7 + '*')), ($r7V4.Details -like ('*' + $noneDue7 + '*'))) 'True/False'
$script:TcpIntervalSampling = $null

# backlog #34: a run that fell back to console mode inside a window launcher's black window waits for a key, so that
# the report paths stay on the screen - and only then. The three gates are parameters whose defaults are the live
# values; a case that passed all three would block on ReadKey, so none does, and that fourth combination is the
# manual check recorded in VALIDATION.md. The call site is pinned on the AST: once, in the else branch of the
# Initialize-Gui test after the console run, never on the window path and never on the -ConsoleOnly path (the console
# launcher pauses by itself, and the chain's console runs read from NUL).
Assert-Equal '#34 fallback wait: a -ConsoleOnly run does not wait' (Wait-ForConsoleClose -ConsoleOnlyRun $true -UserInteractive $true -InputRedirected $false) $false
Assert-Equal '#34 fallback wait: no person at the console, no wait' (Wait-ForConsoleClose -ConsoleOnlyRun $false -UserInteractive $false -InputRedirected $false) $false
Assert-Equal '#34 fallback wait: a redirected input, no wait' (Wait-ForConsoleClose -ConsoleOnlyRun $false -UserInteractive $true -InputRedirected $true) $false
$waitFn = $scriptAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Wait-ForConsoleClose' }, $true)
$waitDefaults = @($waitFn.Body.ParamBlock.Parameters | ForEach-Object { [string]$_.DefaultValue.Extent.Text }) -join ' '
Assert-Equal '#34 gates: the defaults are the live values - the switch, the session, the input' (($waitDefaults -match '\$ConsoleOnly') -and ($waitDefaults -match 'UserInteractive') -and ($waitDefaults -match 'IsInputRedirected')) True
Assert-Equal '#34 gates: the key is read through ReadKey, guarded' (($waitFn.Extent.Text -match 'ReadKey') -and ($waitFn.Extent.Text -match 'catch')) True
$waitCalls = @($scriptAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Wait-ForConsoleClose' }, $true))
Assert-Equal '#34 call site: exactly one call' $waitCalls.Count 1
$guiIf = $scriptAst.Find({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -match 'Initialize-Gui' }, $true)
Assert-Equal '#34 call site: in the else branch of the Initialize-Gui test, after the console run' (($null -ne $guiIf) -and ($null -ne $guiIf.ElseClause) -and ($guiIf.ElseClause.Extent.Text -match 'Start-ConsoleMode[\s\S]*Wait-ForConsoleClose')) True
Assert-Equal '#34 call site: not on the window path' (($null -ne $guiIf) -and ($guiIf.Clauses[0].Item2.Extent.Text -notmatch 'Wait-ForConsoleClose')) True
# PR #57 round 2: only after a fallback run that exited 0 - on any other code the launcher pauses under its own error,
# and a second prompt about report paths that were not written would be wrong twice.
Assert-Equal '#34 call site: only after a run that exited 0' (($null -ne $guiIf) -and ($guiIf.ElseClause.Extent.Text -match 'if \(\$exitCode -eq 0\)\s*\{\s*\[void\]\(Wait-ForConsoleClose\)\s*\}')) True
$consoleOnlyIf = $scriptAst.Find({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -match '^\(?\s*\$ConsoleOnly\s*\)?$' }, $true)
Assert-Equal '#34 call site: not on the -ConsoleOnly path' (($null -ne $consoleOnlyIf) -and ($consoleOnlyIf.Clauses[0].Item2.Extent.Text -notmatch 'Wait-ForConsoleClose')) True

# backlog #54: the host-name rule, tested at its boundary rather than by its members. The oracle below restates the
# rule from the item's decision in the plainest form - IPv6 literal with an optional numeric zone; otherwise labels
# split on the four separators, the root dropped, each label IDNA-encoded and decoded back equal to itself up to
# case and NFC, the encoded label letters, digits, hyphen and underscore only, 1-63 long, no hyphen at an edge, 253
# in all - and the shipped predicate must agree with it on every code point of the Basic Multilingual Plane placed
# inside a label. A mutant of the predicate that drops the fidelity clause, widens the alphabet, ignores a separator
# or the root, or skips a length disagrees on hundreds of them; the sweep prints the first disagreements by code point.
function Test-HostNameOracle([string]$x) {
    $idn = New-Object System.Globalization.IdnMapping
    $v = $x.Trim(); if ($v -eq '') { return $false }
    if ($v.Contains(':')) { $ip = $null; return ([System.Net.IPAddress]::TryParse($v, [ref]$ip) -and $ip.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6) }
    $labels = @([regex]::Split($v, '[.。．｡]'))
    if ($labels.Count -gt 1 -and $labels[-1] -eq '') { $labels = @($labels[0..($labels.Count - 2)]) }
    $total = 0
    foreach ($l in $labels) {
        if ($l -eq '') { return $false }
        $a = $l
        if ($l -cmatch '[^\x00-\x7F]') {   # -cmatch: -match folds U+212A into K and U+0130 into I, found by this sweep's first run
            try { $n = $l.Normalize([Text.NormalizationForm]::FormC); $a = $idn.GetAscii($n); $u = $idn.GetUnicode($a) } catch { return $false }
            $nf = [regex]::Replace($n, '[A-Z]', [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $m.Value.ToLowerInvariant() })   # ASCII case alone (PR #58, round 2)
            if ([string]::CompareOrdinal($u, $nf) -ne 0) { return $false }   # ordinal: -cne is a linguistic comparison that ignores a zero-width joiner and equates the eszett with ss
        }
        if ($a -cnotmatch '^[A-Za-z0-9_-]+$') { return $false }
        if ($a.Length -gt 63 -or $a.StartsWith('-') -or $a.EndsWith('-')) { return $false }
        $total += $a.Length + 1
    }
    return (($total - 1) -le 253)
}
$disagreements = New-Object System.Collections.Generic.List[string]
$swept = 0
# Every UTF-16 code unit, the lone surrogates included - a JSON escape of one half reaches the predicate as one - and
# a predicate that throws instead of answering counts as a disagreement (PR #58, round 1).
for ($c = 0; $c -le 0xFFFF; $c++) {
    $x = 'a' + [string][char]$c + 'b.example.com'
    $swept++
    $answer = $(try { Test-HostNameSyntax $x } catch { 'threw' })
    if ($answer -ne (Test-HostNameOracle $x)) { $disagreements.Add(('U+{0:X4}' -f $c)) }
}
Assert-Equal ('#54 property: the predicate agrees with the rule on every BMP code unit inside a label, lone surrogates included ({0} swept)' -f $swept) (@($disagreements | Select-Object -First 12) -join ' ') ''
# The three candidates the item named, answered - and the boundary's neighbours.
Assert-Equal '#54 zero-width space is refused: IDNA would drop it and the name asked would differ' (Test-HostNameSyntax ('foo' + [string][char]0x200B + 'bar.example.com')) False
Assert-Equal '#54 zero-width joiner is refused' (Test-HostNameSyntax ('foo' + [string][char]0x200D + 'bar.example.com')) False
Assert-Equal '#54 zero-width non-joiner is refused' (Test-HostNameSyntax ('foo' + [string][char]0x200C + 'bar.example.com')) False
Assert-Equal '#54 soft hyphen is refused' (Test-HostNameSyntax ('foo' + [string][char]0x00AD + 'bar.example.com')) False
Assert-Equal '#54 bidirectional override is refused: IDNA refuses it' (Test-HostNameSyntax ('foo' + [string][char]0x202E + 'bar.example.com')) False
Assert-Equal '#54 IPv6 literal with a numeric zone id is usable' (Test-HostNameSyntax 'fe80::1%12') True
Assert-Equal '#54 IPv6 literal with a named zone id is not (not Windows'' form)' (Test-HostNameSyntax 'fe80::1%eth0') False
Assert-Equal '#54 a percent sign in a name is refused' (Test-HostNameSyntax 'foo%bar.example.com') False
Assert-Equal '#54 an asterisk is refused' (Test-HostNameSyntax '*.example.com') False
Assert-Equal '#54 a plus sign is refused' (Test-HostNameSyntax 'foo+bar.example.com') False
Assert-Equal '#54 an underscore is usable: Windows hosts carry it' (Test-HostNameSyntax '_dmarc.example.com') True
Assert-Equal '#54 an eszett is refused: IDNA maps it to ss' (Test-HostNameSyntax ('stra' + [string][char]0xDF + 'e.de')) False
Assert-Equal '#54 full-width letters are refused: IDNA maps them to ASCII' (Test-HostNameSyntax ([string]([char]0xFF45 + [char]0xFF58) + '.example.com')) False
Assert-Equal '#54 a decomposed umlaut is usable: canonical composition is not a change' (Test-HostNameSyntax ('m' + [string][char]0x75 + [string][char]0x0308 + 'nchen.de')) True
Assert-Equal '#54 a precomposed umlaut is usable' (Test-HostNameSyntax ('m' + [string][char]0xFC + 'nchen.de')) True
Assert-Equal '#54 ASCII case is not a change' (Test-HostNameSyntax 'Example.COM') True
# PR #58 round 2: only ASCII case may differ. A culture-free ignore-case comparison had let the long s pass as 's'.
Assert-Equal '#54 the long s is refused: IDNA sends it as s' (Test-HostNameSyntax ('a' + [string][char]0x017F + 'b.example.com')) False
Assert-Equal '#54 reason: the long s is named' (([string](Get-HostNameSyntaxProblem ('a' + [string][char]0x017F + 'b.example.com'))) -match 'U\+017F') True
Assert-Equal '#54 the final sigma is refused: IDNA sends it as sigma' (Test-HostNameSyntax ('a' + [string][char]0x03C2 + '.example.com')) False
Assert-Equal '#54 a capital non-ASCII letter is refused: the rule allows ASCII case only, and IDNA lowercases it' (Test-HostNameSyntax ([string][char]0xDC + 'BER.de')) False
Assert-Equal '#54 the same letter in lowercase is usable' (Test-HostNameSyntax ([string][char]0xFC + 'ber.de')) True
Assert-Equal '#54 ASCII capitals beside a non-ASCII letter are still not a change' (Test-HostNameSyntax ('Z' + [string][char]0xFC + 'RICH.ch')) True
Assert-Equal '#54 an already-encoded label is an ASCII label' (Test-HostNameSyntax 'xn--kpry57d.tw') True
Assert-Equal '#54 a bracketed IPv6 literal is usable' (Test-HostNameSyntax '[fe80::1]') True
Assert-Equal '#54 a space inside a label is refused by the alphabet' (Test-HostNameSyntax 'foo bar.example.com') False
Assert-Equal '#54 253 encoded characters fit' (Test-HostNameSyntax ((('a' * 63) + '.') * 3 + ('b' * 61))) True
Assert-Equal '#54 254 encoded characters do not' (Test-HostNameSyntax ((('a' * 63) + '.') * 3 + ('b' * 62))) False
# The reasons: language-neutral parts only - the code point and the position, and emptiness for a usable name.
Assert-Equal '#54 reason: a usable name has none' ([string](Get-HostNameSyntaxProblem 'www.example.com')) ''
Assert-Equal '#54 reason: the zero-width space is named by code point and position' (([string](Get-HostNameSyntaxProblem ('foo' + [string][char]0x200B + 'bar.example.com'))) -match 'U\+200B' -and ([string](Get-HostNameSyntaxProblem ('foo' + [string][char]0x200B + 'bar.example.com'))) -match '(^|\D)4(\D|$)') True
Assert-Equal '#54 reason: the percent sign is named by code point and position' (([string](Get-HostNameSyntaxProblem 'ab%cd.example.com')) -match 'U\+0025' -and ([string](Get-HostNameSyntaxProblem 'ab%cd.example.com')) -match '(^|\D)3(\D|$)') True
Assert-Equal '#54 reason: the eszett is named where IDNA changes it' (([string](Get-HostNameSyntaxProblem ('stra' + [string][char]0xDF + 'e.de'))) -match 'U\+00DF') True
Assert-Equal '#54 reason: a full-width letter in the second label is placed after the first label' (([string](Get-HostNameSyntaxProblem ('ab.' + [string][char]0xFF45 + 'x.com'))) -match '(^|\D)4(\D|$)') True
# PR #58 round 5: a position belongs to the label as configured. The alphabet check on a non-ASCII label used to read the
# Punycode form ('xn--%-dha' for an umlaut and a percent sign), and NFC composition can shorten a label before the index.
$umlautPercent = [string](Get-HostNameSyntaxProblem ('a.' + [string][char]0xFC + '%.com'))
Assert-Equal '#54 reason: a percent sign after an umlaut is placed in the configured label, not in the Punycode' (($umlautPercent -match 'U\+0025') -and ($umlautPercent -match '(^|\D)4(\D|$)')) True
$decomposedPercent = [string](Get-HostNameSyntaxProblem ('a.u' + [string][char]0x0308 + '%.com'))
Assert-Equal '#54 reason: a percent sign after a decomposed umlaut keeps its typed position, which NFC would have shifted' (($decomposedPercent -match 'U\+0025') -and ($decomposedPercent -match '(^|\D)5(\D|$)')) True
$decomposedEszett = [string](Get-HostNameSyntaxProblem ('u' + [string][char]0x0308 + [string][char]0xDF + '.de'))
Assert-Equal '#54 reason: an eszett after a decomposed umlaut is placed where it was typed' (($decomposedEszett -match 'U\+00DF') -and ($decomposedEszett -match '(^|\D)3(\D|$)')) True
Assert-Equal '#54 reason: a bidirectional override after a decomposed umlaut is placed where it was typed' (([string](Get-HostNameSyntaxProblem ('u' + [string][char]0x0308 + [string][char]0x202E + 'x.de'))) -match '(^|\D)3(\D|$)') True
Assert-Equal '#54 reason: the bidirectional override is named' (([string](Get-HostNameSyntaxProblem ('foo' + [string][char]0x202E + 'bar.example.com'))) -match 'U\+202E') True
Assert-Equal '#54 reason: a blank has one' (([string](Get-HostNameSyntaxProblem '   ')).Length -gt 0) True
# A lone surrogate has no code point; the reason names its UTF-16 value instead of throwing (PR #58, round 1). The calls
# are wrapped so that a throw is a failed assertion, not a skipped one.
$loneHigh = $(try { [string](Get-HostNameSyntaxProblem ('foo' + [string][char]0xD800 + 'bar.example.com')) } catch { 'THREW: ' + $_.Exception.Message })
Assert-Equal '#54 reason: a lone high surrogate is refused and named by its UTF-16 value' (($loneHigh -match 'U\+D800') -and ($loneHigh -match '(^|\D)4(\D|$)')) True
$loneLow = $(try { [string](Get-HostNameSyntaxProblem ('foo' + [string][char]0xDC00 + 'bar.example.com')) } catch { 'THREW: ' + $_.Exception.Message })
Assert-Equal '#54 reason: a lone low surrogate too' ($loneLow -match 'U\+DC00') True
$highThenLetter = $(try { [string](Get-HostNameSyntaxProblem ('foo' + [string][char]0xD83D + 'x.example.com')) } catch { 'THREW: ' + $_.Exception.Message })
Assert-Equal '#54 reason: a high surrogate followed by a letter is named by its own value' ($highThenLetter -match 'U\+D83D') True
$pair = $(try { [string](Get-HostNameSyntaxProblem ('foo' + [char]::ConvertFromUtf32(0x1F600) + 'bar.example.com')) } catch { 'THREW: ' + $_.Exception.Message })
Assert-Equal '#54 reason: a valid pair that IDNA accepts is a usable label' $pair ''
Assert-Equal '#54 reason: a URL with a usable host adds nothing' ([string](Get-UrlHostProblemSuffix 'https://www.example.com/')) ''
Assert-Equal '#54 reason: a URL whose host carries a zero-width space names it' (([string](Get-UrlHostProblemSuffix ('https://foo' + [string][char]0x200B + 'bar.example.com/'))) -match 'U\+200B') True
Assert-Equal '#54 reason: a URL that fails for its scheme adds nothing' ([string](Get-UrlHostProblemSuffix 'ftp://example.com/')) ''
# PR #58 round 3: the URL's host is judged as written. System.Uri lowercases the host and normalises an internationalised
# one before exposing .Host, which would have passed a spelling the rule refuses in a ping, DNS or TCP target.
Assert-Equal '#54 url: a capital non-ASCII letter in the host is refused, as it is elsewhere' (Test-HttpTargetSyntax ('https://' + [string][char]0xDC + 'BER.de/')) False
Assert-Equal '#54 url: the lowercase form is usable' (Test-HttpTargetSyntax ('https://' + [string][char]0xFC + 'ber.de/')) True
Assert-Equal '#54 url: reason names the capital letter as written' (([string](Get-UrlHostProblemSuffix ('https://' + [string][char]0xDC + 'BER.de/'))) -match 'U\+00DC') True
Assert-Equal '#54 url: a zero-width space in the host is refused' (Test-HttpTargetSyntax ('https://foo' + [string][char]0x200B + 'bar.example.com/')) False
Assert-Equal '#54 url: userinfo, port, path and query are not the host' (Test-HttpTargetSyntax 'https://user:pw@Example.COM:8443/a/b?c=d#e') True
Assert-Equal '#54 url: the configured host is what the extractor returns' (Get-UrlConfiguredHost 'https://user:pw@Example.COM:8443/a/b?c=d#e') 'Example.COM'
Assert-Equal '#54 url: an IPv6 literal keeps what is between the brackets' (Get-UrlConfiguredHost 'http://[fe80::1]:8080/x') 'fe80::1'
Assert-Equal '#54 url: no authority, no host' (Get-UrlConfiguredHost 'https:///path') ''
# PR #58 round 4: the authority marker is the "//" right after the scheme's colon, not the first "//" anywhere.
Assert-Equal '#54 url: an absolute URI without an authority is refused even when its path carries // later' (Test-HttpTargetSyntax 'http:path//example.com') False
Assert-Equal '#54 url: and the extractor names no host for it' (Get-UrlConfiguredHost 'http:path//example.com') ''
Assert-Equal '#54 url: an upper-case scheme still opens the authority' (Get-UrlConfiguredHost 'HTTP://Example.COM/x//y') 'Example.COM'
$urlFns = @('Test-HttpTargetSyntax', 'Get-UrlHostProblemSuffix') | ForEach-Object { $n = $_; $scriptAst.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq $n }, $true).Extent.Text }
Assert-Equal '#54 url: neither URL function judges Uri''s own .Host' ((($urlFns -join ' ') -match '\$uri\.Host') -eq $false -and (($urlFns -join ' ') -match 'Get-UrlConfiguredHost')) True   # the code, not the comment that says why
# The rule lives in one place: the predicate is the reason's yes/no, and IDNA is consulted nowhere else.
$hostFn = $scriptAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-HostNameSyntax' }, $true)
Assert-Equal '#54 one place: Test-HostNameSyntax only asks Get-HostNameSyntaxProblem' ((@($hostFn.Body.EndBlock.Statements).Count -eq 1) -and ($hostFn.Extent.Text -match 'Get-HostNameSyntaxProblem') -and ($hostFn.Extent.Text -notmatch 'IdnMapping|-match|Split')) True
$idnUses = @($scriptAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.TypeExpressionAst] -and $n.TypeName.Name -match 'IdnMapping' }, $true) + $scriptAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $n.Value -match 'IdnMapping' }, $true))
$problemFn = $scriptAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-HostNameSyntaxProblem' }, $true)
Assert-Equal '#54 one place: IDNA is consulted inside Get-HostNameSyntaxProblem and nowhere else' ((@($idnUses).Count -ge 1) -and (@($idnUses | Where-Object { $_.Extent.StartOffset -lt $problemFn.Extent.StartOffset -or $_.Extent.EndOffset -gt $problemFn.Extent.EndOffset }).Count -eq 0)) True

Write-Output ("Summary: {0} passed, {1} failed" -f $passes, $fails)
exit $fails
