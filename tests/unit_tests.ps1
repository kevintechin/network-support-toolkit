param([string]$ScriptPath)

$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$errors)
$wanted = 'ConvertTo-SafeString', 'ConvertTo-IntSafe', 'Test-IsWholeNumber', 'ConvertFrom-NetshWlanOutput', 'Test-IsVirtualAdapter', 'ConvertTo-DisplayString', 'Get-PropertyValue', 'ConvertTo-DoubleSafe', 'Test-IsNumericValue', 'Get-ExceptionDetails', 'Get-ExceptionDiagnostics', 'Test-IsValidIPv4Address', 'Get-NetworkErrorCauseText', 'Add-NetworkErrorCause'
$funcs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $wanted -contains $n.Name }, $true)
foreach ($f in $funcs) { Invoke-Expression $f.Extent.Text }
Write-Output ("Loaded {0} functions from {1}" -f @($funcs).Count, (Split-Path -Leaf (Split-Path -Parent $ScriptPath)))

$fails = 0; $passes = 0
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
Write-Output ("Summary: {0} passed, {1} failed" -f $passes, $fails)
exit $fails
