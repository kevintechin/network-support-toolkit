<#
.SYNOPSIS
    Writes the facts of this machine that the NetworkHealthCheck validation record needs, with nothing installed (backlog #19).

.DESCRIPTION
    Runs on Windows PowerShell 5.1 alone - no Python, no git - and prints what a report from this machine has to be read
    against: operating system, edition and build; display language, system locale, code page and time zone; PowerShell
    version, language mode and execution policies; application control (WDAC, AppLocker), Defender and SmartScreen
    state; the account's rights and the session; the display; every network adapter with the flags and the description
    the tool classifies it by, the addresses, gateways and DNS servers, the wireless service and interfaces, the proxy;
    and, with -PackageDir, the Mark-of-the-Web state of the package files and how the shipped Test-IsVirtualAdapter
    classifies each adapter.

    Every fact is read on its own, so a fact the machine refuses costs one line, not the report. Nothing here needs
    FullLanguage - cmdlets, operators and property reads only, the discipline of the tool's own environment report - so
    a machine restricted by application control can be described too; the two facts that do need .NET (the desktop
    working area, the classification through the shipped function) say so when the mode refuses them.

    The lines go to the console and to environment_probe_<computer>_<time>.txt in -OutDir (UTF-8 with a byte-order
    mark, so adapter names in any language survive). Exit code 0; 1 only when the file cannot be written.

.PARAMETER OutDir
    Where the file goes. Default: this script's folder.
.PARAMETER PackageDir
    An extracted package (the folder holding en-US\ and zh-TW\) or one language folder: its files are listed with their
    Zone.Identifier stream (the Mark of the Web), and the en-US script's Test-IsVirtualAdapter is applied to the adapters.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\environment_probe.ps1
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\environment_probe.ps1 -OutDir "$env:USERPROFILE\Desktop" -PackageDir C:\NetworkHealthCheck-1.2.2
#>
param([string]$OutDir, [string]$PackageDir)

$ErrorActionPreference = 'Continue'
$script:lines = @()
function Add-Line([string]$Text) { $script:lines += $Text }
function Add-Section([string]$Title) { Add-Line ''; Add-Line $Title }
function Add-Fact([string]$Name, [scriptblock]$Read) {
    # One fact per call on its own try: a refused fact is one line, and the next fact is still read.
    try {
        $value = @(& $Read | ForEach-Object { if ($null -ne $_) { [string]$_ } } | Where-Object { $_ -ne '' })
        if ($value.Count -eq 0) { $value = @('(none)') }
        Add-Line ('  {0}: {1}' -f $Name, ($value -join '; '))
    }
    catch { Add-Line ('  {0}: unavailable ({1})' -f $Name, $_.Exception.Message) }
}
function Add-List([string]$Name, [scriptblock]$Read) {
    # Like Add-Fact, one line per item.
    try {
        $items = @(& $Read | ForEach-Object { if ($null -ne $_) { [string]$_ } } | Where-Object { $_ -ne '' })
        Add-Line ('  {0}: {1}' -f $Name, $items.Count)
        foreach ($item in $items) { Add-Line ('    - ' + $item) }
    }
    catch { Add-Line ('  {0}: unavailable ({1})' -f $Name, $_.Exception.Message) }
}
function Get-Reg([string]$Path, [string]$Name) {
    # A registry value, or $null when the key or the value does not exist.
    $item = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $item) { return $null }
    return $item.$Name
}
function Get-CimOrWmi([string]$ClassName, [string]$Namespace) {
    # Get-CimInstance where it exists, Get-WmiObject otherwise - the tool's own choice.
    if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) {
        if ($Namespace) { return @(Get-CimInstance -Namespace $Namespace -ClassName $ClassName -ErrorAction Stop) }
        return @(Get-CimInstance -ClassName $ClassName -ErrorAction Stop)
    }
    if ($Namespace) { return @(Get-WmiObject -Namespace $Namespace -Class $ClassName -ErrorAction Stop) }
    return @(Get-WmiObject -Class $ClassName -ErrorAction Stop)
}
function Invoke-Exe([string]$Name, [string[]]$Arguments) {
    # A System32 executable, its merged output as lines (native commands work in every language mode).
    $exe = Join-Path $env:SystemRoot ('System32\' + $Name)
    return @(& $exe @Arguments 2>&1 | ForEach-Object { [string]$_ })
}

$mode = [string]$ExecutionContext.SessionState.LanguageMode
Add-Line ('NetworkHealthCheck environment probe - {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Add-Line ('  computer {0}; user {1}; language mode {2}' -f $env:COMPUTERNAME, $env:USERNAME, $mode)

Add-Section 'Operating system'
Add-Fact 'Caption / version / build / architecture (Win32_OperatingSystem)' { $os = @(Get-CimOrWmi 'Win32_OperatingSystem')[0]; '{0}; {1}; build {2}; {3}' -f $os.Caption, $os.Version, $os.BuildNumber, $os.OSArchitecture }
Add-Fact 'Display version / edition / build.UBR (registry)' { $k = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'; '{0}; {1}; {2}.{3}' -f (Get-Reg $k 'DisplayVersion'), (Get-Reg $k 'EditionID'), (Get-Reg $k 'CurrentBuild'), (Get-Reg $k 'UBR') }
Add-Fact 'OS language / locale / MUI languages (Win32_OperatingSystem)' { $os = @(Get-CimOrWmi 'Win32_OperatingSystem')[0]; '{0}; {1}; {2}' -f $os.OSLanguage, $os.Locale, (@($os.MUILanguages) -join ',') }
Add-Fact 'Install date / last boot (Win32_OperatingSystem)' { $os = @(Get-CimOrWmi 'Win32_OperatingSystem')[0]; '{0}; {1}' -f $os.InstallDate, $os.LastBootUpTime }
Add-Fact 'Manufacturer / model / hypervisor present / domain (Win32_ComputerSystem)' { $cs = @(Get-CimOrWmi 'Win32_ComputerSystem')[0]; '{0}; {1}; hypervisor {2}; {3} (joined: {4})' -f $cs.Manufacturer, $cs.Model, $cs.HypervisorPresent, $cs.Domain, $cs.PartOfDomain }

Add-Section 'Culture'
Add-Fact 'Formats (Get-Culture)' { $c = Get-Culture; '{0} - {1}' -f $c.Name, $c.DisplayName }
Add-Fact 'Display language (Get-UICulture)' { $c = Get-UICulture; '{0} - {1}' -f $c.Name, $c.DisplayName }
Add-Fact 'System locale, decides the code page (Get-WinSystemLocale)' { $l = Get-WinSystemLocale; '{0} - {1}' -f $l.Name, $l.DisplayName }
Add-Fact 'User language list (Get-WinUserLanguageList)' { @(Get-WinUserLanguageList | ForEach-Object { $_.LanguageTag }) -join ',' }
Add-Fact 'Active code page (chcp)' { $out = [string](Invoke-Exe 'chcp.com' @()); if ($out -match '(\d+)') { $Matches[1] } else { $out } }
Add-Fact 'Time zone (Get-TimeZone)' { $tz = Get-TimeZone; '{0} ({1})' -f $tz.Id, $tz.DisplayName }
Add-Fact 'Date and time as this culture writes them' { Get-Date -Format 'F' }

Add-Section 'PowerShell'
Add-Fact 'Version / edition / CLR (PSVersionTable)' { '{0}; {1}; CLR {2}' -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition, $PSVersionTable.CLRVersion }
Add-Fact 'Language mode' { $mode }
Add-Fact '__PSLockdownPolicy (environment; 4 = every new PowerShell starts in ConstrainedLanguage)' { if ($null -eq $env:__PSLockdownPolicy) { 'not set' } else { $env:__PSLockdownPolicy } }
Add-Fact 'Execution policy by scope (MachinePolicy and UserPolicy come from Group Policy and win over the process-scoped Bypass the launcher passes)' { @(Get-ExecutionPolicy -List | ForEach-Object { '{0}={1}' -f $_.Scope, $_.ExecutionPolicy }) -join ', ' }
Add-Fact '.NET Framework 4.x (registry)' { $k = 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full'; '{0} (release {1})' -f (Get-Reg $k 'Version'), (Get-Reg $k 'Release') }
Add-Fact 'PowerShell 7 (pwsh) present' { if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'yes' } else { 'no' } }

Add-Section 'Application control and protection'
Add-Fact 'WDAC / Device Guard (Win32_DeviceGuard: 0 off, 1 audit, 2 enforced)' { $dg = @(Get-CimOrWmi 'Win32_DeviceGuard' 'root\Microsoft\Windows\DeviceGuard')[0]; 'code integrity policy {0}; user-mode policy {1}; security services running {2}' -f $dg.CodeIntegrityPolicyEnforcementStatus, $dg.UsermodeCodeIntegrityPolicyEnforcementStatus, (@($dg.SecurityServicesRunning) -join ',') }
Add-Fact 'AppLocker effective policy (Get-AppLockerPolicy -Effective)' { $p = Get-AppLockerPolicy -Effective -ErrorAction Stop; $c = @($p.RuleCollections | ForEach-Object { '{0}: {1} rules, {2}' -f $_.RuleCollectionType, $_.Count, $_.EnforcementMode }); if ($c.Count) { $c -join '; ' } else { 'no rule collections' } }
Add-Fact 'Application Identity service (AppIDSvc; AppLocker enforces only while it runs)' { $s = Get-Service -Name AppIDSvc -ErrorAction Stop; '{0} ({1})' -f $s.Status, $s.StartType }
Add-Fact 'Defender (Get-MpComputerStatus)' { $m = Get-MpComputerStatus -ErrorAction Stop; 'antimalware enabled {0}; real-time protection {1}; engine {2}' -f $m.AMServiceEnabled, $m.RealTimeProtectionEnabled, $m.AMEngineVersion }
Add-Fact 'Attack surface reduction rules in block mode (Get-MpPreference)' { $p = Get-MpPreference -ErrorAction Stop; $ids = @($p.AttackSurfaceReductionRules_Ids); $acts = @($p.AttackSurfaceReductionRules_Actions); $n = 0; for ($i = 0; $i -lt $ids.Count; $i++) { if ([string]$acts[$i] -eq '1') { $n++ } }; '{0} of {1} configured' -f $n, $ids.Count }
Add-Fact 'SmartScreen for apps and files (registry SmartScreenEnabled)' { $v = Get-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' 'SmartScreenEnabled'; if ($null -eq $v) { 'not set' } else { $v } }
Add-Fact 'Attachment manager SaveZoneInformation (1 = the Mark of the Web is not written to downloads)' { $v = Get-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Attachments' 'SaveZoneInformation'; if ($null -eq $v) { 'not set (marks are written)' } else { $v } }
Add-Fact 'UAC (EnableLUA)' { Get-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'EnableLUA' }

Add-Section 'Account and session'
Add-Fact 'Administrators group in the token (whoami /groups, S-1-5-32-544)' { $g = [string](Invoke-Exe 'whoami.exe' @('/groups', '/fo', 'csv', '/nh')); if ($g -match 'S-1-5-32-544') { 'present' } else { 'absent (standard user)' } }
Add-Fact 'Elevated (net session succeeds only in an elevated process)' { $null = Invoke-Exe 'net.exe' @('session'); if ($LASTEXITCODE -eq 0) { 'yes' } else { 'no (exit code {0})' -f $LASTEXITCODE } }
Add-Fact 'Session name (SESSIONNAME)' { $env:SESSIONNAME }
Add-Fact 'Profile / TEMP' { '{0}; {1}' -f $env:USERPROFILE, $env:TEMP }

Add-Section 'Display'
Add-List 'Video controllers (Win32_VideoController)' { Get-CimOrWmi 'Win32_VideoController' | ForEach-Object { '{0}: {1}x{2}' -f $_.Name, $_.CurrentHorizontalResolution, $_.CurrentVerticalResolution } }
Add-Fact 'Applied DPI (registry)' { Get-Reg 'HKCU:\Control Panel\Desktop\WindowMetrics' 'AppliedDPI' }
Add-Fact 'Primary screen working area (WinForms; the tool clamps its window to this height minus 40 px)' { Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop; $s = [System.Windows.Forms.Screen]::PrimaryScreen; '{0}x{1} (bounds {2}x{3})' -f $s.WorkingArea.Width, $s.WorkingArea.Height, $s.Bounds.Width, $s.Bounds.Height }

Add-Section 'Network'
Add-List 'Adapters (Get-NetAdapter: name | description | status | Virtual | HardwareInterface | driver)' { Get-NetAdapter -ErrorAction Stop | Sort-Object ifIndex | ForEach-Object { '{0} | {1} | {2} | Virtual={3} | HardwareInterface={4} | {5} {6}' -f $_.Name, $_.InterfaceDescription, $_.Status, $_.Virtual, $_.HardwareInterface, $_.DriverProvider, $_.DriverVersionString } }
Add-List 'Adapters (Win32_NetworkAdapter, the CIM fallback: name | type | PhysicalAdapter | NetEnabled)' { Get-CimOrWmi 'Win32_NetworkAdapter' | Where-Object { $null -ne $_.NetConnectionID -or $_.PhysicalAdapter } | ForEach-Object { '{0} | {1} | PhysicalAdapter={2} | NetEnabled={3}' -f $_.Name, $_.AdapterType, $_.PhysicalAdapter, $_.NetEnabled } }
Add-List 'IP configuration (Get-NetIPConfiguration: alias | IPv4 | IPv4 gateway | DNS)' { Get-NetIPConfiguration -ErrorAction Stop | ForEach-Object { '{0} | {1} | {2} | {3}' -f $_.InterfaceAlias, (@($_.IPv4Address | ForEach-Object { $_.IPAddress }) -join ','), (@($_.IPv4DefaultGateway | ForEach-Object { $_.NextHop }) -join ','), (@($_.DNSServer | ForEach-Object { $_.ServerAddresses }) -join ',') } }
Add-List 'IP configuration (Win32_NetworkAdapterConfiguration, IP-enabled: description | addresses | gateways | DNS | DHCP)' { Get-CimOrWmi 'Win32_NetworkAdapterConfiguration' | Where-Object { $_.IPEnabled } | ForEach-Object { '{0} | {1} | {2} | {3} | DHCP={4}' -f $_.Description, (@($_.IPAddress) -join ','), (@($_.DefaultIPGateway) -join ','), (@($_.DNSServerSearchOrder) -join ','), $_.DHCPEnabled } }
Add-Fact 'WLAN AutoConfig service (WlanSvc)' { $s = Get-Service -Name WlanSvc -ErrorAction Stop; '{0} ({1})' -f $s.Status, $s.StartType }
Add-Fact 'Wireless interfaces connected (netsh wlan show interfaces, SSID lines)' { @(Invoke-Exe 'netsh.exe' @('wlan', 'show', 'interfaces') | Where-Object { $_ -match '^\s*SSID\s*:' }).Count }
Add-List 'netsh wlan show interfaces, as printed (the layout differs between Windows versions and languages)' { Invoke-Exe 'netsh.exe' @('wlan', 'show', 'interfaces') | Where-Object { $_.Trim() -ne '' } | Select-Object -First 60 }
Add-Fact 'TCPv4 / TCPv6 retransmission counters readable (Win32_PerfRawData_Tcpip_*)' { @('TCPv4', 'TCPv6') | ForEach-Object { $c = @(Get-CimOrWmi ('Win32_PerfRawData_Tcpip_' + $_))[0]; '{0}={1}' -f $_, $(if ($null -ne $c -and $null -ne $c.SegmentsSentPersec) { 'yes' } else { 'no' }) } }
Add-Fact 'Adapter statistics (Get-NetAdapterStatistics)' { 'available for {0} adapters' -f @(Get-NetAdapterStatistics -ErrorAction Stop).Count }
Add-Fact 'WinHTTP proxy (netsh winhttp show proxy)' { @(Invoke-Exe 'netsh.exe' @('winhttp', 'show', 'proxy') | Where-Object { $_.Trim() -ne '' }) -join ' / ' }
Add-Fact 'User proxy (registry Internet Settings)' { $k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'; 'ProxyEnable={0}; ProxyServer={1}; AutoConfigURL={2}' -f (Get-Reg $k 'ProxyEnable'), (Get-Reg $k 'ProxyServer'), (Get-Reg $k 'AutoConfigURL') }

if ($PackageDir) {
    $PackageDir = (Resolve-Path -LiteralPath $PackageDir).Path   # a full path, so the file list below can be made relative to it
    Add-Section ('Package at ' + $PackageDir)
    Add-Fact 'Path shape' {
        $flags = @()
        if ($PackageDir -match '\\Temp\d*_[^\\]*\.zip\\') { $flags += 'inside a Windows compressed-folder view (Temp1_*.zip)' }
        if ($env:TEMP -and ($PackageDir -like ($env:TEMP + '*'))) { $flags += 'under TEMP' }
        if ($PackageDir -match '^\\\\') { $flags += 'a network path' }
        if ($flags.Count) { $flags -join '; ' } else { 'a local folder' }
    }
    Add-List 'Files and their Mark of the Web (Zone.Identifier stream; ZoneId=3 is the internet zone)' {
        Get-ChildItem -LiteralPath $PackageDir -Recurse -File -ErrorAction Stop | Where-Object { $_.FullName -notmatch '\\Reports\\' -and $_.Extension -match '^\.(cmd|ps1|json|zip|txt|md)$' } | ForEach-Object {
            $zone = 'no mark'
            $stream = Get-Item -LiteralPath $_.FullName -Stream Zone.Identifier -ErrorAction SilentlyContinue
            if ($null -ne $stream) {
                $id = @(Get-Content -LiteralPath $_.FullName -Stream Zone.Identifier -ErrorAction SilentlyContinue | Where-Object { $_ -match '^ZoneId=' })[0]
                $zone = $(if ($id) { [string]$id } else { 'stream present' })
            }
            '{0} | {1}' -f $_.FullName.Substring($PackageDir.Length).TrimStart('\'), $zone
        }
    }
    Add-List 'Adapter classification by the shipped Test-IsVirtualAdapter (a true Virtual flag, else the HardwareInterface flag, else the description)' {
        $script = Join-Path $PackageDir 'en-US\NetworkHealthCheck.ps1'
        if (-not (Test-Path -LiteralPath $script)) { $script = Join-Path $PackageDir 'NetworkHealthCheck.ps1' }
        if (-not (Test-Path -LiteralPath $script)) { throw 'NetworkHealthCheck.ps1 not found under the package folder' }
        if ($mode -ne 'FullLanguage') { throw ('not possible in ' + $mode + ': loading a function out of the script needs the parser') }
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$tokens, [ref]$errors)
        $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-IsVirtualAdapter' }, $true)
        if ($null -eq $fn) { throw 'Test-IsVirtualAdapter not found in the script' }
        Invoke-Expression $fn.Extent.Text
        Get-NetAdapter -ErrorAction Stop | Sort-Object ifIndex | ForEach-Object {
            $virtual = Test-IsVirtualAdapter -Description ([string]$_.InterfaceDescription) -VirtualFlag $_.Virtual -HardwareFlag $_.HardwareInterface
            '{0} ({1}): {2}' -f $_.Name, $_.InterfaceDescription, $(if ($virtual) { 'Virtual' } else { 'Physical' })
        }
    }
}

if (-not $OutDir) { $OutDir = $PSScriptRoot }
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }
$file = Join-Path $OutDir ('environment_probe_{0}_{1}.txt' -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd_HHmmss'))
foreach ($line in $script:lines) { Write-Output $line }
try {
    Set-Content -LiteralPath $file -Value $script:lines -Encoding UTF8 -ErrorAction Stop
    Write-Output ('written: ' + $file)
    exit 0
}
catch {
    Write-Output ('could not write ' + $file + ': ' + $_.Exception.Message)
    exit 1
}
