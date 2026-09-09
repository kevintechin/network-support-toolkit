param([string]$ScriptPath)

$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$errors)
$wanted = 'ConvertTo-SafeString', 'ConvertTo-IntSafe', 'Test-IsWholeNumber', 'ConvertFrom-NetshWlanOutput', 'Test-IsVirtualAdapter', 'ConvertTo-DisplayString', 'Get-PropertyValue', 'ConvertTo-DoubleSafe', 'Test-IsNumericValue', 'Get-ExceptionDetails', 'Get-ExceptionDiagnostics', 'Test-IsValidIPv4Address', 'Get-NetworkErrorCauseText', 'Add-NetworkErrorCause', 'Test-IsRunningFromArchive', 'ConvertTo-UInt64Safe', 'Get-CimOrWmiInstance', 'Get-TcpCounterSnapshot', 'Get-TcpReadFailureLines', 'Format-TcpAttemptList', 'Get-TcpAttemptSeconds', 'Compare-TcpCounters'
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
function Add-CheckResult {
    param([string]$Category, [string]$Check, [string]$Status, [string]$Message, [string]$Details = "", [string]$Diagnostics = "", [string]$Tag = "", [string]$Scope = "Main")
    $row = [pscustomobject]@{ Category = $Category; Check = $Check; Status = $Status; Message = $Message; Details = $Details; Diagnostics = $Diagnostics; Tag = $Tag; Scope = $Scope }
    [void]$script:TcpRows.Add($row)
    return $row
}
$script:Config = [pscustomobject]@{ Thresholds = [pscustomobject]@{ TcpRetransmissionWarningPercent = 2; TcpRetransmissionCriticalPercent = 5; TcpRetransmissionCriticalCount = 50; MinimumTcpSegmentsForRate = 50 } }
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
Assert-Equal '#38 warm-up: the run takes two snapshots' $snapshotCalls.Count 2
Assert-Equal '#38 warm-up: exactly one of them warms the provider' (@($snapshotCalls | Where-Object { $_.Extent.Text -match '-WarmUp' }).Count) 1
Assert-Equal '#38 warm-up: it is the baseline, the first of the two' ((@($snapshotCalls | Sort-Object { $_.Extent.StartOffset })[0].Extent.Text -match '-WarmUp')) True

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

Write-Output ("Summary: {0} passed, {1} failed" -f $passes, $fails)
exit $fails
