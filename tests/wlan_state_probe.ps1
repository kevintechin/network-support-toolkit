# probe_wlan_state.ps1 - READ-ONLY: what the Native Wifi API and netsh say about each wireless interface on this machine.
# Changes nothing. Meant to be run twice by the owner: once with location consent as it is (Allow), once with
# Settings > Privacy & security > Location > "Let desktop apps access your location" switched off (backlog #62's measurement).
param([switch]$Mask)

$ErrorActionPreference = 'Stop'
$code = @'
[DllImport("wlanapi.dll")] public static extern uint WlanOpenHandle(uint dwClientVersion, IntPtr pReserved, out uint pdwNegotiatedVersion, out IntPtr phClientHandle);
[DllImport("wlanapi.dll")] public static extern uint WlanCloseHandle(IntPtr hClientHandle, IntPtr pReserved);
[DllImport("wlanapi.dll")] public static extern uint WlanEnumInterfaces(IntPtr hClientHandle, IntPtr pReserved, out IntPtr ppInterfaceList);
[DllImport("wlanapi.dll")] public static extern uint WlanQueryInterface(IntPtr hClientHandle, ref Guid pInterfaceGuid, int OpCode, IntPtr pReserved, out uint pdwDataSize, out IntPtr ppData, IntPtr pWlanOpcodeValueType);
[DllImport("wlanapi.dll")] public static extern void WlanFreeMemory(IntPtr pMemory);
'@
$api = "Probe62.WlanApi" -as [type]
if ($null -eq $api) {
    Add-Type -Namespace Probe62 -Name WlanApi -MemberDefinition $code -ErrorAction Stop
    $api = "Probe62.WlanApi" -as [type]
}
$M = [System.Runtime.InteropServices.Marshal]

function Mask-Mac([string]$s) { if ($Mask) { return ($s -replace '([0-9a-fA-F]{2}[:-]){3}[0-9a-fA-F]{2}([:-][0-9a-fA-F]{2}){2}', 'xx:xx:xx:xx:xx:xx') } return $s }
function Win32Text([uint32]$c) { try { return ("{0} ({1})" -f $c, (New-Object System.ComponentModel.Win32Exception([int]$c)).Message) } catch { return "$c" } }
function StateText([int]$s) { switch ($s) { 0 {'not ready'} 1 {'connected'} 2 {'ad hoc network formed'} 3 {'disconnecting'} 4 {'disconnected'} 5 {'associating'} 6 {'discovering'} 7 {'authenticating'} default {"state $s"} } }

"== consent (read-only)"
foreach ($p in 'HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location\NonPackaged') {
    try { "  {0} = {1}" -f $p.Replace('Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\', '...\'), (Get-ItemProperty -Path $p -ErrorAction Stop).Value } catch { "  $p : $($_.Exception.Message)" }
}
$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
"  OS {0} {1} build {2}.{3}; culture {4}; ui {5}; time {6:HH:mm:ss}" -f $cv.ProductName, $cv.DisplayVersion, $cv.CurrentBuild, $cv.UBR, (Get-Culture).Name, (Get-UICulture).Name, (Get-Date)

"== Native Wifi API"
$handle = [IntPtr]::Zero; $list = [IntPtr]::Zero
try {
    $version = [uint32]0
    $rc = $api::WlanOpenHandle(2, [IntPtr]::Zero, [ref]$version, [ref]$handle)
    "  WlanOpenHandle: {0}, negotiated version {1}" -f (Win32Text $rc), $version
    if ($rc -ne 0) { return }
    $rc = $api::WlanEnumInterfaces($handle, [IntPtr]::Zero, [ref]$list)
    "  WlanEnumInterfaces: {0}" -f (Win32Text $rc)
    if ($rc -ne 0) { return }
    $count = $M::ReadInt32($list, 0)
    "  interfaces: $count"
    for ($i = 0; $i -lt $count; $i++) {
        $base = [IntPtr]($list.ToInt64() + 8 + ($i * 532))
        $gb = New-Object byte[] 16; $M::Copy($base, $gb, 0, 16); $guid = New-Object System.Guid (,$gb)
        $desc = ($M::PtrToStringUni([IntPtr]($base.ToInt64() + 16), 256)).TrimEnd([char]0)
        $isState = $M::ReadInt32($base, 528)
        "  [{0}] {1} - {2}" -f $i, $guid, $desc
        "      WLAN_INTERFACE_INFO.isState = {0} = {1}" -f $isState, (StateText $isState)
        $q = $guid
        # wlan_intf_opcode_interface_state = 6 -> a DWORD WLAN_INTERFACE_STATE
        $size = [uint32]0; $data = [IntPtr]::Zero
        $rc = $api::WlanQueryInterface($handle, [ref]$q, 6, [IntPtr]::Zero, [ref]$size, [ref]$data, [IntPtr]::Zero)
        if ($rc -eq 0) { try { "      opcode 6 interface_state: {0} bytes -> {1} = {2}" -f $size, $M::ReadInt32($data, 0), (StateText ($M::ReadInt32($data, 0))) } finally { $api::WlanFreeMemory($data) } }
        else { "      opcode 6 interface_state: {0}" -f (Win32Text $rc) }
        # wlan_intf_opcode_current_connection = 7 -> WLAN_CONNECTION_ATTRIBUTES (isState 0, mode 4, profile 8..520,
        # association: SSID length 520 + bytes 524, bssType 556, BSSID 560..566, phyType 568, phyIndex 572, signal 576, rx 580, tx 584)
        $size = [uint32]0; $data = [IntPtr]::Zero
        $rc = $api::WlanQueryInterface($handle, [ref]$q, 7, [IntPtr]::Zero, [ref]$size, [ref]$data, [IntPtr]::Zero)
        if ($rc -eq 0) {
            try {
                $st = $M::ReadInt32($data, 0); $mode = $M::ReadInt32($data, 4)
                $profile = ($M::PtrToStringUni([IntPtr]($data.ToInt64() + 8), 256)).TrimEnd([char]0)
                $ssidLen = $M::ReadInt32($data, 520); $ssidBytes = New-Object byte[] 32; $M::Copy([IntPtr]($data.ToInt64() + 524), $ssidBytes, 0, 32)
                $ssid = [System.Text.Encoding]::UTF8.GetString($ssidBytes, 0, [math]::Min([math]::Max($ssidLen, 0), 32))
                $bss = New-Object byte[] 6; $M::Copy([IntPtr]($data.ToInt64() + 560), $bss, 0, 6)
                $bssid = ($bss | ForEach-Object { $_.ToString('x2') }) -join ':'
                "      opcode 7 current_connection: {0} bytes; isState {1} = {2}; mode {3}; profile '{4}'; SSID '{5}' (len {6}); bssType {7}; BSSID {8}; phyType {9}; signal {10}%; rx {11} kbps; tx {12} kbps" -f $size, $st, (StateText $st), $mode, $profile, $ssid, $ssidLen, $M::ReadInt32($data, 556), (Mask-Mac $bssid), $M::ReadInt32($data, 568), $M::ReadInt32($data, 576), $M::ReadInt32($data, 580), $M::ReadInt32($data, 584)
            } finally { $api::WlanFreeMemory($data) }
        }
        else { "      opcode 7 current_connection: {0}" -f (Win32Text $rc) }
        # wlan_intf_opcode_radio_state = 4 -> WLAN_RADIO_STATE { dwNumberOfPhys; { dwPhyIndex, software, hardware } x 64 } (DOT11_RADIO_STATE: 0 unknown, 1 on, 2 off)
        $size = [uint32]0; $data = [IntPtr]::Zero
        $rc = $api::WlanQueryInterface($handle, [ref]$q, 4, [IntPtr]::Zero, [ref]$size, [ref]$data, [IntPtr]::Zero)
        if ($rc -eq 0) { try { $n = 0; if ($size -ge 4) { $n = $M::ReadInt32($data, 0) }; $phys = @(); for ($p = 0; $p -lt [math]::Min($n, 64); $p++) { $o = 4 + ($p * 12); if ($size -lt ($o + 12)) { break }; $phys += ("phy{0}: software {1}, hardware {2}" -f $M::ReadInt32($data, $o), $M::ReadInt32($data, $o + 4), $M::ReadInt32($data, $o + 8)) }; "      opcode 4 radio_state: {0} bytes; {1} PHY(s); {2}" -f $size, $n, ($phys -join '; ') } finally { $api::WlanFreeMemory($data) } }
        else { "      opcode 4 radio_state: {0}" -f (Win32Text $rc) }
        # wlan_intf_opcode_channel_number = 8 -> a DWORD
        $size = [uint32]0; $data = [IntPtr]::Zero
        $rc = $api::WlanQueryInterface($handle, [ref]$q, 8, [IntPtr]::Zero, [ref]$size, [ref]$data, [IntPtr]::Zero)
        if ($rc -eq 0) { try { "      opcode 8 channel_number: {0} bytes -> {1}" -f $size, $(if ($size -ge 4) { $M::ReadInt32($data, 0) } else { '?' }) } finally { $api::WlanFreeMemory($data) } }
        else { "      opcode 8 channel_number: {0}" -f (Win32Text $rc) }
        # wlan_intf_opcode_statistics = 0x10000101 (what the retry half reads) - return code only
        $size = [uint32]0; $data = [IntPtr]::Zero
        $rc = $api::WlanQueryInterface($handle, [ref]$q, 0x10000101, [IntPtr]::Zero, [ref]$size, [ref]$data, [IntPtr]::Zero)
        if ($rc -eq 0) { try { "      opcode statistics: {0} bytes" -f $size } finally { $api::WlanFreeMemory($data) } } else { "      opcode statistics: {0}" -f (Win32Text $rc) }
    }
}
finally {
    if ($list -ne [IntPtr]::Zero) { $api::WlanFreeMemory($list) }
    if ($handle -ne [IntPtr]::Zero) { [void]$api::WlanCloseHandle($handle, [IntPtr]::Zero) }
}

"== netsh wlan show interfaces"
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$raw = & "$env:SystemRoot\System32\netsh.exe" wlan show interfaces 2>&1 | ForEach-Object { [string]$_ }
$sw.Stop()
"  ({0} ms, {1} lines, exit {2})" -f $sw.ElapsedMilliseconds, $raw.Count, $LASTEXITCODE
$raw | ForEach-Object { "  " + (Mask-Mac $_) }
"== Get-NetConnectionProfile"
Get-NetConnectionProfile -ErrorAction SilentlyContinue | ForEach-Object { "  {0} | {1} (ifIndex {2}) | {3} | v4 {4} | v6 {5}" -f $_.Name, $_.InterfaceAlias, $_.InterfaceIndex, $_.NetworkCategory, $_.IPv4Connectivity, $_.IPv6Connectivity }
