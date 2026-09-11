param([string]$ScriptPath)

$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$errors)
$wanted = 'ConvertTo-SafeString', 'ConvertTo-IntSafe', 'Test-IsWholeNumber', 'ConvertFrom-NetshWlanOutput', 'Test-IsVirtualAdapter', 'ConvertTo-DisplayString', 'Get-PropertyValue', 'ConvertTo-DoubleSafe', 'Test-IsNumericValue', 'Get-ExceptionDetails', 'Get-ExceptionDiagnostics', 'Test-IsValidIPv4Address', 'Get-NetworkErrorCauseText', 'Add-NetworkErrorCause', 'Test-IsRunningFromArchive', 'ConvertTo-UInt64Safe', 'Get-CimOrWmiInstance', 'Get-TcpCounterSnapshot', 'Get-TcpReadFailureLines', 'Format-TcpAttemptList', 'Get-TcpAttemptSeconds', 'Compare-TcpCounters', 'Test-PingTargetSyntax', 'Test-HttpTargetSyntax', 'Test-HostNameSyntax', 'Test-TcpTargetSyntax', 'Get-RouteSelection', 'Get-RouteSelectionText', 'Format-RouteSelection', 'Get-RouteMethodText', 'Get-PingCountForThreshold', 'Get-LossBand', 'Get-CountThreshold', 'Get-PingLossClassification', 'Get-PingExtensionPlan', 'Get-PingSampleInterval', 'Add-PingTargetResult', 'Test-TcpSampleNeedsExtension', 'Merge-TcpEndingSnapshot', 'Test-NearEndTargetPlacement', 'Resolve-PingTargets', 'Test-IPv4InCidr', 'Get-DhcpServerText', 'Get-CanonicalIPv4Text', 'Test-NearEndAddressSyntax'
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
# Five since 1.2.10. The fifth is the step that extends the TCP window (progress 90, backlog #51): it decides
# how to sample rather than what the network is like, and the analysis step below it writes the measurement
# either way - a step-error row from it must not make a run Test Incomplete.
Assert-Equal '#39 steps: five of them declare the marking' $weightlessSteps.Count 5
Assert-Equal '#39 steps: and they are the collectors, by their progress points' ((@($weightlessSteps | ForEach-Object { Get-StepProgress $_ } | Sort-Object) -join ',')) '10,13,82,89,90'
Assert-Equal '#39 steps: the analysis steps beside them keep their weight' (@($stepCalls | Where-Object { (Get-StepProgress $_) -in @(85, 92) -and (Get-StepParameter $_ 'Weightless').Count -gt 0 }).Count) 0

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
Assert-Equal '#60 path: an attested near-end row names the adapter its lookups agreed on' $rowAttested.Path 'Ethernet'
Assert-Equal '#60 path: so does a gateway row' $rowGatewayPass.Path 'Wi-Fi'
Assert-Equal '#60 path: and a far-end row whose lookups agreed' $rowFarEnd.Path 'Wi-Fi'
Assert-Equal '#60 path: a near-end row off its subnet still says which adapter it was selected for' $rowElsewhere.Path 'Wi-Fi'
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
Assert-Equal '#60 rung: though its lookups agreed, so the row still names the adapter' $rowViaRouter.Path 'Ethernet'
$rowHopChanged = Get-NearEndRow $nearRoute.Selection $viaRouter @('203.0.113.0/24')
Assert-Equal '#60 rung: a next hop that changed between the lookups is a changed selection' $rowHopChanged.Path ''
$script:TcpRows = New-Object System.Collections.ArrayList
Add-PingTargetResult -Name 'Default Gateway' -Target '203.0.113.9' -ConfiguredAddress 'AUTO_GATEWAY' -Required $true -Measurement (New-PingFixture 4 4 5) -RouteBefore $viaRouter.Selection -RouteAfter $viaRouter -TargetIsAddress $true -TimeoutMs 1200 -RungSubnets @('203.0.113.0/24') | Out-Null
$rowGatewayViaRouter = @($script:TcpRows)[0]
Assert-Equal '#60 rung: a gateway reached through a router does not claim its rung' ((Get-DetailLineAt $rowGatewayViaRouter 2) -eq (Get-DetailLineAt $rowGatewayPass 2)) False
Assert-Equal '#60 rung: and keeps its tag' $rowGatewayViaRouter.Tag 'ping-gateway'
Assert-Equal '#60 rung: the attestation reads the on-link flag' ((Get-FunctionBody 'Add-PingTargetResult') -match '\$RouteBefore\.OnLink -eq \$true') True
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

Write-Output ("Summary: {0} passed, {1} failed" -f $passes, $fails)
exit $fails
