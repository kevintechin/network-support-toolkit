[CmdletBinding()]
param(
    [switch]$ConsoleOnly,
    [string]$ConfigPath = ""
)

# NetworkHealthCheck.ps1
# Portable, read-only network diagnostic tool for Windows 10/11.
# Designed for Windows PowerShell 5.1 and PowerShell 7 on Windows.
#
# Architecture overview
# ---------------------
# 1. Configuration: loads JSON, merges it with safe defaults, then validates syntax
#    and semantic constraints. Invalid settings are reported instead of terminating
#    the entire diagnostic run.
# 2. Data collection: uses modern NetTCPIP/NetAdapter cmdlets where available and
#    falls back to CIM/WMI for compatible Windows systems.
# 3. Active tests: performs ICMP ping, DNS lookup, TCP connection, and HTTP/HTTPS
#    requests using configurable targets and timeouts.
# 4. Counter sampling: takes before/after snapshots of adapter errors/discards and
#    system-wide TCP sent/retransmitted counters, then calculates non-negative deltas.
# 5. Result model: every check produces PASS, WARN, FAIL, INFO, or ERROR. ERROR means
#    the check could not be completed; it is intentionally different from FAIL.
# 6. Reporting: writes HTML, text, and JSON reports. If the normal output directory
#    is not writable, the tool falls back to the user's Windows temporary directory.
# 7. User interface: runs in Windows Forms when available and automatically falls
#    back to console mode if GUI initialization fails.
#
# Safety properties
# -----------------
# - Read-only: the script does not change IP, DNS, routes, firewall, or adapter state.
# - Fault isolation: each diagnostic step is wrapped so one failure does not prevent
#   the remaining checks from running.
# - Traceability: exception type, message, and inner exceptions are stored in every
#   report; script location and call stack go to the JSON report only (Diagnostics).

$script:ToolVersion = "1.1.4"
$script:BaseDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:Results = New-Object System.Collections.ArrayList
$script:StartupMessages = New-Object System.Collections.ArrayList
$script:PrimaryAdapters = @()
$script:LastHtmlReport = $null
$script:LastTextReport = $null
$script:LastJsonReport = $null
$script:OutputDirectory = $null
$script:RunStartedAt = $null
$script:RunFinishedAt = $null
$script:GuiAvailable = $false
$script:IsRunning = $false
$script:Form = $null
$script:LogBox = $null
$script:ProgressBar = $null
$script:ProgressLabel = $null
$script:OverallLabel = $null
$script:StartButton = $null
$script:OpenReportButton = $null
$script:OpenFolderButton = $null
$script:ReportPathLabel = $null
$script:Config = $null
$script:ConfigLoadError = $null
$script:ConfigLoadDiagnostics = ""
$script:UsingFallbackOutputDirectory = $false

try {
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
}
catch {
    # GUI and file reports still use Unicode if the console encoding cannot be changed.
}

# -----------------------------------------------------------------------------
# Core helpers and result model: safe conversions, exception details, status text, and UI logging.
# -----------------------------------------------------------------------------
function ConvertTo-SafeString {
    param([object]$Value)

    if ($null -eq $Value) {
        return ""
    }

    try {
        return [string]$Value
    }
    catch {
        return ""
    }
}

function ConvertTo-DisplayString {
    param(
        [object]$Value,
        [string]$EmptyText = "(none)"
    )

    if ($null -eq $Value) {
        return $EmptyText
    }

    if ($Value -is [string]) {
        if ([string]::IsNullOrWhiteSpace($Value)) {
            return $EmptyText
        }
        return $Value
    }

    if ($Value -is [System.Collections.IEnumerable]) {
        $items = @()
        foreach ($item in $Value) {
            if ($null -ne $item -and -not [string]::IsNullOrWhiteSpace([string]$item)) {
                $items += [string]$item
            }
        }
        if ($items.Count -eq 0) {
            return $EmptyText
        }
        return ($items -join ", ")
    }

    return [string]$Value
}

function ConvertTo-UInt64Safe {
    param([object]$Value)

    if ($null -eq $Value) {
        return [uint64]0
    }

    try {
        return [uint64]$Value
    }
    catch {
        return [uint64]0
    }
}

function ConvertTo-IntSafe {
    param(
        [object]$Value,
        [int]$DefaultValue = 0
    )

    if ($null -eq $Value -or $Value -is [bool]) {
        return $DefaultValue
    }

    try {
        return [int]$Value
    }
    catch {
        return $DefaultValue
    }
}

function ConvertTo-DoubleSafe {
    param(
        [object]$Value,
        [double]$DefaultValue = 0
    )

    if ($null -eq $Value -or $Value -is [bool]) {
        return $DefaultValue
    }

    try {
        if ($Value -is [string]) {
            $parsed = 0.0
            if ([double]::TryParse($Value, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed) -and -not [double]::IsNaN($parsed) -and -not [double]::IsInfinity($parsed)) {
                return $parsed
            }
            return $DefaultValue
        }
        $converted = [double]$Value
        if ([double]::IsNaN($converted) -or [double]::IsInfinity($converted)) {
            return $DefaultValue
        }
        return $converted
    }
    catch {
        return $DefaultValue
    }
}

function Test-IsNumericValue {
    param([object]$Value)

    if ($null -eq $Value -or $Value -is [bool]) {
        return $false
    }

    if ($Value -is [string]) {
        $parsed = 0.0
        if (-not [double]::TryParse($Value, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
            return $false
        }
        return (-not [double]::IsNaN($parsed) -and -not [double]::IsInfinity($parsed))
    }

    try {
        $converted = [double]$Value
        return (-not [double]::IsNaN($converted) -and -not [double]::IsInfinity($converted))
    }
    catch {
        return $false
    }
}

# Backlog #11: human-readable summary only; script location and call stack go to Get-ExceptionDiagnostics (JSON report).
function Get-ExceptionDetails {
    param(
        [object]$ErrorRecord,
        [switch]$IncludeDiagnostics
    )

    if ($null -eq $ErrorRecord) {
        return "Unknown error"
    }

    try {
        $message = $ErrorRecord.Exception.Message
        $typeName = $ErrorRecord.Exception.GetType().FullName
        $parts = @("Error type: $typeName", "Message: $message")
        $inner = $ErrorRecord.Exception.InnerException
        $innerIndex = 1
        while ($null -ne $inner -and $innerIndex -le 5) {
            $parts += ("Inner error {0}: {1} — {2}" -f $innerIndex, $inner.GetType().FullName, $inner.Message)
            $inner = $inner.InnerException
            $innerIndex++
        }
        if ($IncludeDiagnostics) {
            $diagnostics = Get-ExceptionDiagnostics $ErrorRecord
            if (-not [string]::IsNullOrWhiteSpace($diagnostics)) {
                $parts += $diagnostics
            }
        }
        return ($parts -join [Environment]::NewLine)
    }
    catch {
        return [string]$ErrorRecord
    }
}

function Get-ExceptionDiagnostics {
    param([object]$ErrorRecord)

    if ($null -eq $ErrorRecord) {
        return ""
    }

    try {
        $position = ConvertTo-SafeString $ErrorRecord.InvocationInfo.PositionMessage
        $stack = ConvertTo-SafeString $ErrorRecord.ScriptStackTrace

        $parts = @()
        if (-not [string]::IsNullOrWhiteSpace($position)) {
            $parts += "Location: $position"
        }
        if (-not [string]::IsNullOrWhiteSpace($stack)) {
            $parts += "Call stack: $stack"
        }
        return ($parts -join [Environment]::NewLine)
    }
    catch {
        return ""
    }
}

function Write-Utf8File {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )

    $encoding = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function ConvertTo-HtmlEncoded {
    param([object]$Value)

    $text = ConvertTo-SafeString $Value
    try {
        return [System.Net.WebUtility]::HtmlEncode($text)
    }
    catch {
        $encoded = $text -replace '&', '&amp;'
        $encoded = $encoded -replace '<', '&lt;'
        $encoded = $encoded -replace '>', '&gt;'
        $encoded = $encoded -replace '"', '&quot;'
        return $encoded
    }
}

function Get-StatusText {
    param([string]$Status)

    switch ($Status) {
        "PASS"  { return "Pass" }
        "WARN"  { return "Warning" }
        "FAIL"  { return "Fail" }
        "INFO"  { return "Information" }
        "ERROR" { return "Unable to Check" }
        default  { return $Status }
    }
}

function Get-StatusPrefix {
    param([string]$Status)

    switch ($Status) {
        "PASS"  { return "[Pass]" }
        "WARN"  { return "[Warning]" }
        "FAIL"  { return "[Fail]" }
        "INFO"  { return "[Information]" }
        "ERROR" { return "[Error]" }
        default  { return "[$Status]" }
    }
}

function Write-UiLog {
    param(
        [string]$Status,
        [string]$Text
    )

    $line = "{0} {1} {2}" -f (Get-Date -Format "HH:mm:ss"), (Get-StatusPrefix $Status), $Text
    Write-Host $line

    if ($script:GuiAvailable -and $null -ne $script:LogBox) {
        try {
            $script:LogBox.AppendText($line + [Environment]::NewLine)
            $script:LogBox.SelectionStart = $script:LogBox.TextLength
            $script:LogBox.ScrollToCaret()
            [System.Windows.Forms.Application]::DoEvents()
        }
        catch {
            # The console output remains available even if the GUI log cannot be updated.
        }
    }
}

function Set-UiProgress {
    param(
        [int]$Percent,
        [string]$Text
    )

    if ($Percent -lt 0) { $Percent = 0 }
    if ($Percent -gt 100) { $Percent = 100 }

    if ($script:GuiAvailable) {
        try {
            if ($null -ne $script:ProgressBar) {
                $script:ProgressBar.Value = $Percent
            }
            if ($null -ne $script:ProgressLabel) {
                $script:ProgressLabel.Text = $Text
            }
            [System.Windows.Forms.Application]::DoEvents()
        }
        catch {
            # Continue in console/report mode.
        }
    }
}

function Add-CheckResult {
    param(
        [Parameter(Mandatory = $true)][string]$Category,
        [Parameter(Mandatory = $true)][string]$Check,
        [Parameter(Mandatory = $true)][ValidateSet("PASS", "WARN", "FAIL", "INFO", "ERROR")][string]$Status,
        [Parameter(Mandatory = $true)][string]$Message,
        [string]$Details = "",
        [string]$Diagnostics = ""
    )

    $item = [pscustomobject][ordered]@{
        Time     = Get-Date
        Category = $Category
        Check    = $Check
        Status   = $Status
        Message  = $Message
        Details     = $Details
        Diagnostics = $Diagnostics
    }

    [void]$script:Results.Add($item)
    Write-UiLog -Status $Status -Text ("{0} / {1}: {2}" -f $Category, $Check, $Message)
    return $item
}

function Invoke-CheckStep {
    param(
        [Parameter(Mandatory = $true)][string]$Category,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][int]$Progress,
        [Parameter(Mandatory = $true)][scriptblock]$Action
    )

    Set-UiProgress -Percent $Progress -Text $Name
    Write-UiLog -Status "INFO" -Text ("Starting: $Name")

    try {
        return (& $Action)
    }
    catch {
        $details = Get-ExceptionDetails $_
        $diagnostics = Get-ExceptionDiagnostics $_
        Add-CheckResult -Category $Category -Check $Name -Status "ERROR" -Message "This item could not be executed. The error has been recorded." -Details $details -Diagnostics $diagnostics | Out-Null
        return $null
    }
}

# -----------------------------------------------------------------------------
# Configuration: safe defaults, JSON merge, and writable report-directory selection.
# -----------------------------------------------------------------------------
function Get-DefaultConfig {
    return [pscustomobject][ordered]@{
        OrganizationName = ""
        ReportFolderName = "Reports"
        Expected = [pscustomobject][ordered]@{
            AllowedIPv4Addresses    = @()
            AllowedIPv4Cidrs        = @()
            AllowedPrefixLengths    = @()
            AllowedDefaultGateways  = @()
            RequiredDnsServers      = @()
            DhcpEnabled             = $null
        }
        Tests = [pscustomobject][ordered]@{
            PingCount                    = 4
            PingTimeoutMs                = 1200
            DnsTimeoutMs                 = 4000
            TcpTimeoutMs                 = 4000
            HttpTimeoutMs                = 6000
            RetransmissionSampleSeconds  = 8
            PingTargets = @(
                [pscustomobject][ordered]@{
                    Name     = "Default Gateway"
                    Address  = "AUTO_GATEWAY"
                    Required = $true
                },
                [pscustomobject][ordered]@{
                    Name     = "Public IP"
                    Address  = "1.1.1.1"
                    Required = $false
                }
            )
            DnsNames = @(
                [pscustomobject][ordered]@{
                    Name     = "DNS Name Resolution"
                    Host     = "www.microsoft.com"
                    Required = $true
                }
            )
            TcpTargets = @(
                [pscustomobject][ordered]@{
                    Name     = "Direct HTTPS Test"
                    Host     = "1.1.1.1"
                    Port     = 443
                    Required = $false
                    Group    = "Internet"
                }
            )
            HttpTargets = @(
                [pscustomobject][ordered]@{
                    Name     = "HTTPS Web Test"
                    Url      = "https://www.microsoft.com/"
                    Required = $false
                    Group    = "Internet"
                }
            )
            RequiredConnectivityGroups = @("Internet")
        }
        Thresholds = [pscustomobject][ordered]@{
            PacketLossWarningPercent          = 5
            PacketLossCriticalPercent         = 20
            LatencyWarningMs                  = 100
            LatencyCriticalMs                 = 250
            TcpRetransmissionWarningPercent   = 2
            TcpRetransmissionCriticalPercent  = 5
            TcpRetransmissionCriticalCount    = 50
            MinimumTcpSegmentsForRate         = 50
            AdapterErrorWarningDelta          = 1
            AdapterErrorCriticalDelta         = 10
            AdapterDiscardWarningDelta        = 1
            AdapterDiscardCriticalDelta       = 100
        }
    }
}

function Merge-ConfigObject {
    param(
        [Parameter(Mandatory = $true)][object]$DefaultObject,
        [object]$OverrideObject
    )

    $merged = [ordered]@{}

    foreach ($property in $DefaultObject.PSObject.Properties) {
        $overrideProperty = $null
        if ($null -ne $OverrideObject) {
            $overrideProperty = $OverrideObject.PSObject.Properties[$property.Name]
        }

        if ($null -ne $overrideProperty) {
            if (($property.Value -is [System.Management.Automation.PSCustomObject]) -and
                ($overrideProperty.Value -is [System.Management.Automation.PSCustomObject])) {
                $merged[$property.Name] = Merge-ConfigObject -DefaultObject $property.Value -OverrideObject $overrideProperty.Value
            }
            else {
                $merged[$property.Name] = $overrideProperty.Value
            }
        }
        else {
            $merged[$property.Name] = $property.Value
        }
    }

    if ($null -ne $OverrideObject) {
        foreach ($property in $OverrideObject.PSObject.Properties) {
            if (-not $merged.Contains($property.Name)) {
                $merged[$property.Name] = $property.Value
            }
        }
    }

    return [pscustomobject]$merged
}

function Load-Configuration {
    param([string]$RequestedPath)

    $defaultConfig = Get-DefaultConfig
    $path = $RequestedPath

    if ([string]::IsNullOrWhiteSpace($path)) {
        $path = Join-Path $script:BaseDirectory "NetworkHealthCheck.config.json"
    }

    $script:EffectiveConfigPath = $path

    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $script:ConfigLoadError = "Configuration file not found: $path. Built-in defaults will be used."
        return $defaultConfig
    }

    try {
        $raw = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
        $overrideConfig = $raw | ConvertFrom-Json -ErrorAction Stop
        return (Merge-ConfigObject -DefaultObject $defaultConfig -OverrideObject $overrideConfig)
    }
    catch {
        $script:ConfigLoadDiagnostics = Get-ExceptionDiagnostics $_
        $script:ConfigLoadError = "The configuration file is invalid. Built-in defaults will be used.`r`n$(Get-ExceptionDetails $_)"
        return $defaultConfig
    }
}

function Initialize-OutputDirectory {
    $folderName = ConvertTo-SafeString $script:Config.ReportFolderName
    if ([string]::IsNullOrWhiteSpace($folderName)) {
        $folderName = "Reports"
    }

    if ([System.IO.Path]::IsPathRooted($folderName)) {
        $preferred = $folderName
    }
    else {
        $preferred = Join-Path $script:BaseDirectory $folderName
    }

    try {
        if (-not (Test-Path -LiteralPath $preferred)) {
            [void](New-Item -ItemType Directory -Path $preferred -Force -ErrorAction Stop)
        }
        $testFile = Join-Path $preferred (".write_test_{0}.tmp" -f [guid]::NewGuid().ToString("N"))
        [System.IO.File]::WriteAllText($testFile, "test")
        Remove-Item -LiteralPath $testFile -Force -ErrorAction SilentlyContinue
        $script:OutputDirectory = $preferred
        return
    }
    catch {
        $fallback = Join-Path ([System.IO.Path]::GetTempPath()) "NetworkHealthCheck\Reports"
        if (-not (Test-Path -LiteralPath $fallback)) {
            [void](New-Item -ItemType Directory -Path $fallback -Force -ErrorAction Stop)
        }
        $script:OutputDirectory = $fallback
        $script:UsingFallbackOutputDirectory = $true
        [void]$script:StartupMessages.Add("The original report directory is not writable. Reports will be saved to: $fallback. Original error: $($_.Exception.Message)")
    }
}

function Get-PropertyValue {
    param(
        [object]$Object,
        [string]$Name,
        [object]$DefaultValue = $null
    )

    if ($null -eq $Object) {
        return $DefaultValue
    }

    try {
        $property = $Object.PSObject.Properties[$Name]
        if ($null -eq $property) {
            return $DefaultValue
        }
        return $property.Value
    }
    catch {
        return $DefaultValue
    }
}

# -----------------------------------------------------------------------------
# System/network discovery: prefer NetTCPIP/NetAdapter and fall back to CIM/WMI.
# -----------------------------------------------------------------------------
function Test-IsWindowsPlatform {
    if ($env:OS -eq "Windows_NT") {
        return $true
    }

    try {
        return ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
    }
    catch {
        return $false
    }
}

function Get-SystemSummary {
    $osName = [System.Environment]::OSVersion.VersionString
    $osVersion = [System.Environment]::OSVersion.Version.ToString()

    try {
        if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) {
            $os = Get-CimInstance -ClassName Win32_OperatingSystem -OperationTimeoutSec 8 -ErrorAction Stop
            if ($null -ne $os) {
                if (-not [string]::IsNullOrWhiteSpace([string]$os.Caption)) {
                    $osName = [string]$os.Caption
                }
                if (-not [string]::IsNullOrWhiteSpace([string]$os.Version)) {
                    $osVersion = [string]$os.Version
                }
            }
        }
    }
    catch {
        # Basic Environment values remain available.
    }

    return [pscustomobject][ordered]@{
        ComputerName       = $env:COMPUTERNAME
        UserName           = [System.Environment]::UserName
        OperatingSystem    = $osName
        OperatingVersion   = $osVersion
        PowerShellVersion  = $PSVersionTable.PSVersion.ToString()
        ToolVersion        = $script:ToolVersion
        TestStartTime      = $script:RunStartedAt
        ConfigPath         = $script:EffectiveConfigPath
        ReportDirectory    = $script:OutputDirectory
    }
}

function Convert-SubnetMaskToPrefixLength {
    param([string]$Mask)

    if ([string]::IsNullOrWhiteSpace($Mask)) {
        return $null
    }

    try {
        $bytes = [System.Net.IPAddress]::Parse($Mask).GetAddressBytes()
        if ($bytes.Count -ne 4) {
            return $null
        }
        $count = 0
        foreach ($byteValue in $bytes) {
            $value = [int]$byteValue
            for ($i = 0; $i -lt 8; $i++) {
                $count += ($value -band 1)
                $value = $value -shr 1
            }
        }
        return $count
    }
    catch {
        return $null
    }
}

function Convert-LinkSpeedToText {
    param([object]$LinkSpeed)

    if ($null -eq $LinkSpeed) {
        return "Unknown"
    }

    if ($LinkSpeed -is [string]) {
        return [string]$LinkSpeed
    }

    try {
        $value = [double]$LinkSpeed
        if ($value -ge 1000000000) {
            return ("{0:N2} Gbps" -f ($value / 1000000000))
        }
        if ($value -ge 1000000) {
            return ("{0:N0} Mbps" -f ($value / 1000000))
        }
        if ($value -ge 1000) {
            return ("{0:N0} Kbps" -f ($value / 1000))
        }
        return ("{0:N0} bps" -f $value)
    }
    catch {
        return [string]$LinkSpeed
    }
}

function Get-NetworkSnapshotFromNetCmdlets {
    $items = New-Object System.Collections.ArrayList
    $configs = @(Get-NetIPConfiguration -ErrorAction Stop)

    foreach ($config in $configs) {
        $adapter = $config.NetAdapter
        if ($null -eq $adapter) {
            continue
        }
        if ([string]$adapter.Status -ne "Up") {
            continue
        }

        $ipv4Entries = @($config.IPv4Address | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_.IPAddress) })
        $ipv6Entries = @($config.IPv6Address | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_.IPAddress) })

        if ($ipv4Entries.Count -eq 0 -and $ipv6Entries.Count -eq 0) {
            continue
        }

        $ipv4Addresses = @()
        $ipv4Prefixes = @()
        $ipv4WithPrefix = @()
        foreach ($entry in $ipv4Entries) {
            $address = [string]$entry.IPAddress
            $prefix = ConvertTo-IntSafe -Value $entry.PrefixLength -DefaultValue -1
            $ipv4Addresses += $address
            if ($prefix -ge 0) {
                $ipv4Prefixes += $prefix
                $ipv4WithPrefix += ("{0}/{1}" -f $address, $prefix)
            }
            else {
                $ipv4WithPrefix += $address
            }
        }

        $ipv6Addresses = @()
        foreach ($entry in $ipv6Entries) {
            $ipv6Addresses += [string]$entry.IPAddress
        }

        $gateways = @()
        foreach ($gateway in @($config.IPv4DefaultGateway)) {
            if ($null -ne $gateway -and -not [string]::IsNullOrWhiteSpace([string]$gateway.NextHop)) {
                $gateways += [string]$gateway.NextHop
            }
        }

        $dnsServers = @()
        if ($null -ne $config.DNSServer) {
            foreach ($server in @($config.DNSServer.ServerAddresses)) {
                if (-not [string]::IsNullOrWhiteSpace([string]$server)) {
                    $dnsServers += [string]$server
                }
            }
        }

        $dhcpEnabled = $null
        try {
            if (Get-Command Get-NetIPInterface -ErrorAction SilentlyContinue) {
                $interface = Get-NetIPInterface -InterfaceIndex $config.InterfaceIndex -AddressFamily IPv4 -ErrorAction Stop | Select-Object -First 1
                if ($null -ne $interface) {
                    if ([string]$interface.Dhcp -eq "Enabled") {
                        $dhcpEnabled = $true
                    }
                    elseif ([string]$interface.Dhcp -eq "Disabled") {
                        $dhcpEnabled = $false
                    }
                }
            }
        }
        catch {
            $dhcpEnabled = $null
        }

        $profileName = ""
        try {
            if ($null -ne $config.NetProfile) {
                $profileName = [string]$config.NetProfile.Name
            }
        }
        catch {
            $profileName = ""
        }

        [void]$items.Add([pscustomobject][ordered]@{
            Name            = [string]$adapter.Name
            Description     = [string]$adapter.InterfaceDescription
            InterfaceIndex  = ConvertTo-IntSafe -Value $config.InterfaceIndex -DefaultValue 0
            Status          = [string]$adapter.Status
            MacAddress      = [string]$adapter.MacAddress
            LinkSpeed       = Convert-LinkSpeedToText $adapter.LinkSpeed
            ProfileName     = $profileName
            IPv4Addresses   = $ipv4Addresses
            IPv4Prefixes    = $ipv4Prefixes
            IPv4WithPrefix  = $ipv4WithPrefix
            IPv6Addresses   = $ipv6Addresses
            Gateways        = $gateways
            DnsServers      = $dnsServers
            DhcpEnabled     = $dhcpEnabled
            Source          = "NetTCPIP"
        })
    }

    return @($items)
}

function Get-NetworkSnapshotFromCim {
    $items = New-Object System.Collections.ArrayList

    if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) {
        $configs = @(Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -OperationTimeoutSec 8 -ErrorAction Stop | Where-Object { $_.IPEnabled })
        $adapters = @(Get-CimInstance -ClassName Win32_NetworkAdapter -OperationTimeoutSec 8 -ErrorAction SilentlyContinue)
    }
    elseif (Get-Command Get-WmiObject -ErrorAction SilentlyContinue) {
        $configs = @(Get-WmiObject -Class Win32_NetworkAdapterConfiguration -ErrorAction Stop | Where-Object { $_.IPEnabled })
        $adapters = @(Get-WmiObject -Class Win32_NetworkAdapter -ErrorAction SilentlyContinue)
    }
    else {
        throw "No usable CIM/WMI command is available on this system."
    }

    foreach ($config in $configs) {
        $adapter = $null
        foreach ($candidate in $adapters) {
            if ((ConvertTo-IntSafe $candidate.InterfaceIndex -1) -eq (ConvertTo-IntSafe $config.InterfaceIndex -2)) {
                $adapter = $candidate
                break
            }
        }

        $allIps = @($config.IPAddress)
        $allMasks = @($config.IPSubnet)
        $ipv4Addresses = @()
        $ipv4Prefixes = @()
        $ipv4WithPrefix = @()
        $ipv6Addresses = @()

        for ($i = 0; $i -lt $allIps.Count; $i++) {
            $address = [string]$allIps[$i]
            if ([string]::IsNullOrWhiteSpace($address)) {
                continue
            }

            $parsed = $null
            if (-not [System.Net.IPAddress]::TryParse($address, [ref]$parsed)) {
                continue
            }

            if ($parsed.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
                $ipv4Addresses += $address
                $prefix = $null
                if ($i -lt $allMasks.Count) {
                    $maskOrPrefix = [string]$allMasks[$i]
                    if ($maskOrPrefix -match '^\d+$') {
                        $prefix = ConvertTo-IntSafe $maskOrPrefix -1
                    }
                    else {
                        $prefix = Convert-SubnetMaskToPrefixLength $maskOrPrefix
                    }
                }
                if ($null -ne $prefix -and $prefix -ge 0) {
                    $ipv4Prefixes += [int]$prefix
                    $ipv4WithPrefix += ("{0}/{1}" -f $address, $prefix)
                }
                else {
                    $ipv4WithPrefix += $address
                }
            }
            elseif ($parsed.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6) {
                $ipv6Addresses += $address
            }
        }

        $name = [string]$config.Description
        $description = [string]$config.Description
        $status = "Up"
        $linkSpeed = "Unknown"

        if ($null -ne $adapter) {
            if (-not [string]::IsNullOrWhiteSpace([string]$adapter.NetConnectionID)) {
                $name = [string]$adapter.NetConnectionID
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$adapter.Name)) {
                $description = [string]$adapter.Name
            }
            $linkSpeed = Convert-LinkSpeedToText $adapter.Speed
        }

        # Backlog #5: keep only IPv4 gateways (DefaultIPGateway may also list IPv6 next hops) and preserve an unknown DHCP state.
        $gateways = @()
        foreach ($gateway in @($config.DefaultIPGateway)) {
            if (Test-IsValidIPv4Address ([string]$gateway)) {
                $gateways += [string]$gateway
            }
        }

        $dhcpEnabled = $null
        if ($null -ne $config.DHCPEnabled) {
            $dhcpEnabled = [bool]$config.DHCPEnabled
        }

        [void]$items.Add([pscustomobject][ordered]@{
            Name            = $name
            Description     = $description
            InterfaceIndex  = ConvertTo-IntSafe -Value $config.InterfaceIndex -DefaultValue 0
            Status          = $status
            MacAddress      = [string]$config.MACAddress
            LinkSpeed       = $linkSpeed
            ProfileName     = ""
            IPv4Addresses   = $ipv4Addresses
            IPv4Prefixes    = $ipv4Prefixes
            IPv4WithPrefix  = $ipv4WithPrefix
            IPv6Addresses   = $ipv6Addresses
            Gateways        = $gateways
            DnsServers      = @($config.DNSServerSearchOrder)
            DhcpEnabled     = $dhcpEnabled
            Source          = "CIM/WMI"
        })
    }

    return @($items)
}

function Get-NetworkSnapshot {
    if (Get-Command Get-NetIPConfiguration -ErrorAction SilentlyContinue) {
        try {
            $snapshot = @(Get-NetworkSnapshotFromNetCmdlets)
            if ($snapshot.Count -gt 0) {
                return $snapshot
            }
        }
        catch {
            Add-CheckResult -Category "Network Adapter and IP" -Check "Data Source Fallback" -Status "WARN" -Message "Get-NetIPConfiguration could not retrieve data. CIM/WMI will be used instead." -Details (Get-ExceptionDetails $_) -Diagnostics (Get-ExceptionDiagnostics $_) | Out-Null
        }
    }

    return @(Get-NetworkSnapshotFromCim)
}

function Test-IPv4InCidr {
    param(
        [Parameter(Mandatory = $true)][string]$IpAddress,
        [Parameter(Mandatory = $true)][string]$Cidr
    )

    try {
        $parts = $Cidr.Split('/')
        if ($parts.Count -ne 2) {
            return $false
        }

        $prefix = [int]$parts[1]
        if ($prefix -lt 0 -or $prefix -gt 32) {
            return $false
        }

        $ip = [System.Net.IPAddress]::Parse($IpAddress)
        $network = [System.Net.IPAddress]::Parse($parts[0])
        if ($ip.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork -or
            $network.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
            return $false
        }

        $ipBytes = $ip.GetAddressBytes()
        $networkBytes = $network.GetAddressBytes()

        for ($i = 0; $i -lt 4; $i++) {
            $remaining = $prefix - ($i * 8)
            if ($remaining -ge 8) {
                $mask = 255
            }
            elseif ($remaining -le 0) {
                $mask = 0
            }
            else {
                $mask = 256 - [math]::Pow(2, (8 - $remaining))
            }

            if (([int]$ipBytes[$i] -band [int]$mask) -ne ([int]$networkBytes[$i] -band [int]$mask)) {
                return $false
            }
        }

        return $true
    }
    catch {
        return $false
    }
}

function Test-IsValidIPv4Address {
    param([string]$Address)

    if ([string]::IsNullOrWhiteSpace($Address)) {
        return $false
    }

    try {
        $parsed = $null
        if (-not [System.Net.IPAddress]::TryParse($Address, [ref]$parsed)) {
            return $false
        }
        return ($parsed.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork)
    }
    catch {
        return $false
    }
}

# -----------------------------------------------------------------------------
# Semantic validation and company-standard comparison for IP, CIDR, prefix, gateway, DNS, and DHCP.
# -----------------------------------------------------------------------------
function Test-ConfigurationSemantics {
    $errors = New-Object System.Collections.ArrayList
    $warnings = New-Object System.Collections.ArrayList
    $expected = $script:Config.Expected
    $tests = $script:Config.Tests
    $thresholds = $script:Config.Thresholds

    foreach ($ip in @($expected.AllowedIPv4Addresses)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$ip) -and -not (Test-IsValidIPv4Address ([string]$ip))) {
            [void]$errors.Add("AllowedIPv4Addresses contains an invalid IPv4 address: $ip")
        }
    }

    foreach ($cidr in @($expected.AllowedIPv4Cidrs)) {
        if ([string]::IsNullOrWhiteSpace([string]$cidr)) { continue }
        $parts = ([string]$cidr).Split('/')
        $valid = $parts.Count -eq 2 -and (Test-IsValidIPv4Address $parts[0])
        if ($valid) {
            $prefix = ConvertTo-IntSafe $parts[1] -1
            $valid = ($prefix -ge 0 -and $prefix -le 32)
        }
        if (-not $valid) {
            [void]$errors.Add("AllowedIPv4Cidrs contains an invalid CIDR: $cidr")
        }
    }

    foreach ($prefixValue in @($expected.AllowedPrefixLengths)) {
        $prefix = ConvertTo-IntSafe $prefixValue -1
        if ($prefix -lt 0 -or $prefix -gt 32) {
            [void]$errors.Add("AllowedPrefixLengths contains an invalid value: $prefixValue")
        }
    }

    foreach ($gateway in @($expected.AllowedDefaultGateways)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$gateway) -and -not (Test-IsValidIPv4Address ([string]$gateway))) {
            [void]$errors.Add("AllowedDefaultGateways contains an invalid IPv4 address: $gateway")
        }
    }

    foreach ($dns in @($expected.RequiredDnsServers)) {
        if ([string]::IsNullOrWhiteSpace([string]$dns)) { continue }
        $parsedDns = $null
        if (-not [System.Net.IPAddress]::TryParse([string]$dns, [ref]$parsedDns)) {
            [void]$errors.Add("RequiredDnsServers contains an invalid IP address: $dns")
        }
    }

    if ($null -ne $expected.DhcpEnabled -and -not ($expected.DhcpEnabled -is [System.Boolean])) {
        [void]$errors.Add("DhcpEnabled must be true, false, or null; current value: $($expected.DhcpEnabled)")
    }

    foreach ($target in @($tests.TcpTargets)) {
        if ($null -eq $target) { continue }
        $name = ConvertTo-SafeString (Get-PropertyValue $target "Name" "TCP target")
        $hostName = ConvertTo-SafeString (Get-PropertyValue $target "Host" "")
        $port = ConvertTo-IntSafe (Get-PropertyValue $target "Port" 0) 0
        if ([string]::IsNullOrWhiteSpace($hostName) -or $port -lt 1 -or $port -gt 65535) {
            [void]$errors.Add("The host or port for TcpTargets '$name' is invalid: Host=$hostName, Port=$port")
        }
    }

    foreach ($target in @($tests.HttpTargets)) {
        if ($null -eq $target) { continue }
        $name = ConvertTo-SafeString (Get-PropertyValue $target "Name" "HTTP target")
        $url = ConvertTo-SafeString (Get-PropertyValue $target "Url" "")
        $uri = $null
        $validUri = [System.Uri]::TryCreate($url, [System.UriKind]::Absolute, [ref]$uri)
        if ($validUri) {
            $validUri = ($uri.Scheme -eq "http" -or $uri.Scheme -eq "https")
        }
        if (-not $validUri) {
            [void]$errors.Add("The URL for HttpTargets '$name' is invalid: $url")
        }
    }

    foreach ($dnsTarget in @($tests.DnsNames)) {
        if ($null -eq $dnsTarget) { continue }
        if ($dnsTarget -is [string]) {
            $hostName = [string]$dnsTarget
        }
        else {
            $hostName = ConvertTo-SafeString (Get-PropertyValue $dnsTarget "Host" "")
        }
        if ([string]::IsNullOrWhiteSpace($hostName)) {
            [void]$errors.Add("DnsNames contains a blank Host value.")
        }
    }

    foreach ($setting in @(
        [pscustomobject]@{ Name = "PingCount"; Value = $tests.PingCount },
        [pscustomobject]@{ Name = "PingTimeoutMs"; Value = $tests.PingTimeoutMs },
        [pscustomobject]@{ Name = "DnsTimeoutMs"; Value = $tests.DnsTimeoutMs },
        [pscustomobject]@{ Name = "TcpTimeoutMs"; Value = $tests.TcpTimeoutMs },
        [pscustomobject]@{ Name = "HttpTimeoutMs"; Value = $tests.HttpTimeoutMs },
        [pscustomobject]@{ Name = "RetransmissionSampleSeconds"; Value = $tests.RetransmissionSampleSeconds }
    )) {
        if ((ConvertTo-IntSafe $setting.Value 0) -le 0) {
            [void]$warnings.Add("$($setting.Name) should be greater than 0; the built-in minimum will be applied.")
        }
    }

    foreach ($thresholdName in @("PacketLossWarningPercent", "PacketLossCriticalPercent", "LatencyWarningMs", "LatencyCriticalMs", "TcpRetransmissionWarningPercent", "TcpRetransmissionCriticalPercent", "TcpRetransmissionCriticalCount", "MinimumTcpSegmentsForRate", "AdapterErrorWarningDelta", "AdapterErrorCriticalDelta", "AdapterDiscardWarningDelta", "AdapterDiscardCriticalDelta")) {
        $thresholdValue = Get-PropertyValue $thresholds $thresholdName
        if ($null -ne $thresholdValue -and -not (Test-IsNumericValue $thresholdValue)) {
            [void]$warnings.Add("$thresholdName is not a number (current value: $thresholdValue); the built-in default will be used.")
        }
    }

    $warningLoss = ConvertTo-DoubleSafe $thresholds.PacketLossWarningPercent 5
    $criticalLoss = ConvertTo-DoubleSafe $thresholds.PacketLossCriticalPercent 20
    if ($warningLoss -lt 0 -or $criticalLoss -lt $warningLoss) {
        [void]$warnings.Add("Packet-loss thresholds are not ordered correctly: Warning=$warningLoss, Critical=$criticalLoss.")
    }

    $warningLatency = ConvertTo-DoubleSafe $thresholds.LatencyWarningMs 100
    $criticalLatency = ConvertTo-DoubleSafe $thresholds.LatencyCriticalMs 250
    if ($warningLatency -lt 0 -or $criticalLatency -lt $warningLatency) {
        [void]$warnings.Add("Latency thresholds are not ordered correctly: Warning=$warningLatency, Critical=$criticalLatency.")
    }

    $warningRetrans = ConvertTo-DoubleSafe (Get-PropertyValue $thresholds "TcpRetransmissionWarningPercent" 2) 2
    $criticalRetrans = ConvertTo-DoubleSafe (Get-PropertyValue $thresholds "TcpRetransmissionCriticalPercent" 5) 5
    if ($warningRetrans -lt 0 -or $criticalRetrans -lt $warningRetrans) {
        [void]$warnings.Add("TCP retransmission thresholds are not ordered correctly: Warning=$warningRetrans, Critical=$criticalRetrans.")
    }

    if ($errors.Count -gt 0) {
        Add-CheckResult -Category "Program Configuration" -Check "Configuration Validation" -Status "ERROR" -Message ("The configuration file contains {0} invalid value(s). The program will continue, but related results may not be meaningful." -f $errors.Count) -Details (@($errors) -join [Environment]::NewLine) | Out-Null
    }
    elseif ($warnings.Count -eq 0) {
        Add-CheckResult -Category "Program Configuration" -Check "Configuration Validation" -Status "PASS" -Message "Configuration value format validation passed." -Details "" | Out-Null
    }

    if ($warnings.Count -gt 0) {
        Add-CheckResult -Category "Program Configuration" -Check "Configuration Thresholds" -Status "WARN" -Message ("The configuration file contains {0} threshold value(s) that need attention." -f $warnings.Count) -Details (@($warnings) -join [Environment]::NewLine) | Out-Null
    }
}

function Get-PrimaryAdapters {
    param([object[]]$Adapters)

    $withGateway = @($Adapters | Where-Object { @($_.IPv4Addresses).Count -gt 0 -and @($_.Gateways).Count -gt 0 })
    if ($withGateway.Count -gt 0) {
        return $withGateway
    }

    return @($Adapters | Where-Object { @($_.IPv4Addresses).Count -gt 0 })
}

function Add-NetworkSnapshotResults {
    param([object[]]$Adapters)

    if ($Adapters.Count -eq 0) {
        Add-CheckResult -Category "Network Adapter and IP" -Check "Usable Network Adapters" -Status "FAIL" -Message "No connected network adapter with an IP address was found." -Details "Check the network cable, Wi-Fi, airplane mode, adapter driver, and whether the adapter is disabled." | Out-Null
        return
    }

    Add-CheckResult -Category "Network Adapter and IP" -Check "Usable Network Adapters" -Status "PASS" -Message ("Found {0} connected network adapter(s)." -f $Adapters.Count) -Details "" | Out-Null

    foreach ($adapter in $Adapters) {
        $dhcpText = "Unknown"
        if ($adapter.DhcpEnabled -eq $true) { $dhcpText = "Enabled" }
        elseif ($adapter.DhcpEnabled -eq $false) { $dhcpText = "Disabled (static IP)" }

        $details = @(
            "Interface name: $($adapter.Name)",
            "Interface description: $($adapter.Description)",
            "Interface index: $($adapter.InterfaceIndex)",
            "Link speed: $($adapter.LinkSpeed)",
            "MAC address: $(ConvertTo-DisplayString $adapter.MacAddress)",
            "Network profile: $(ConvertTo-DisplayString $adapter.ProfileName)",
            "IPv4: $(ConvertTo-DisplayString $adapter.IPv4WithPrefix)",
            "IPv6: $(ConvertTo-DisplayString $adapter.IPv6Addresses)",
            "Default Gateway: $(ConvertTo-DisplayString $adapter.Gateways)",
            "DNS: $(ConvertTo-DisplayString $adapter.DnsServers)",
            "DHCP: $dhcpText",
            "Data source: $($adapter.Source)"
        ) -join [Environment]::NewLine

        $hasApipa = $false
        foreach ($ip in @($adapter.IPv4Addresses)) {
            if ([string]$ip -like "169.254.*") {
                $hasApipa = $true
                break
            }
        }

        if ($hasApipa) {
            Add-CheckResult -Category "Network Adapter and IP" -Check ("Adapter: {0}" -f $adapter.Name) -Status "FAIL" -Message "A 169.254.x.x automatic private IP address was detected, which usually means DHCP did not provide an address." -Details $details | Out-Null
        }
        elseif (@($adapter.IPv4Addresses).Count -eq 0) {
            Add-CheckResult -Category "Network Adapter and IP" -Check ("Adapter: {0}" -f $adapter.Name) -Status "WARN" -Message "This adapter has no IPv4 address." -Details $details | Out-Null
        }
        else {
            Add-CheckResult -Category "Network Adapter and IP" -Check ("Adapter: {0}" -f $adapter.Name) -Status "PASS" -Message ("Current IPv4: {0}" -f (ConvertTo-DisplayString $adapter.IPv4WithPrefix)) -Details $details | Out-Null
        }
    }

    $gateways = @()
    foreach ($adapter in $Adapters) {
        $gateways += @($adapter.Gateways)
    }
    $gateways = @($gateways | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)

    if ($gateways.Count -eq 0) {
        Add-CheckResult -Category "Network Adapter and IP" -Check "Default Gateway" -Status "FAIL" -Message "No IPv4 default gateway was found. Access to other networks or the internet is usually unavailable." -Details "" | Out-Null
    }
    else {
        Add-CheckResult -Category "Network Adapter and IP" -Check "Default Gateway" -Status "PASS" -Message ("Configured: {0}" -f ($gateways -join ", ")) -Details "" | Out-Null
    }

    $dnsServers = @()
    foreach ($adapter in $Adapters) {
        $dnsServers += @($adapter.DnsServers)
    }
    $dnsServers = @($dnsServers | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)

    if ($dnsServers.Count -eq 0) {
        Add-CheckResult -Category "Network Adapter and IP" -Check "DNS Servers" -Status "FAIL" -Message "No DNS server configuration was found." -Details "Without DNS, connections by host name usually fail, although connections by IP address may still work." | Out-Null
    }
    else {
        Add-CheckResult -Category "Network Adapter and IP" -Check "DNS Servers" -Status "PASS" -Message ("Configured: {0}" -f ($dnsServers -join ", ")) -Details "" | Out-Null
    }
}

function Test-ExpectedNetworkConfiguration {
    param([object[]]$Adapters)

    $expected = $script:Config.Expected
    $allowedIps = @($expected.AllowedIPv4Addresses | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    $allowedCidrs = @($expected.AllowedIPv4Cidrs | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    $allowedPrefixes = @($expected.AllowedPrefixLengths | ForEach-Object { ConvertTo-IntSafe $_ -1 } | Where-Object { $_ -ge 0 -and $_ -le 32 })
    $allowedGateways = @($expected.AllowedDefaultGateways | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    $requiredDns = @($expected.RequiredDnsServers | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    $expectedDhcp = $expected.DhcpEnabled

    $hasValidDhcpRule = ($expectedDhcp -is [System.Boolean])
    $hasAnyRule = ($allowedIps.Count -gt 0 -or $allowedCidrs.Count -gt 0 -or $allowedPrefixes.Count -gt 0 -or
                   $allowedGateways.Count -gt 0 -or $requiredDns.Count -gt 0 -or $hasValidDhcpRule)

    if (-not $hasAnyRule) {
        Add-CheckResult -Category "Company Standard Comparison" -Check "Standard Configuration" -Status "INFO" -Message "No company standard has been defined in the configuration file. The current settings can be displayed, but compliance cannot be determined." -Details "Ask IT staff to edit the Expected section of NetworkHealthCheck.config.json." | Out-Null
        return
    }

    if ($Adapters.Count -eq 0) {
        Add-CheckResult -Category "Company Standard Comparison" -Check "Standard Configuration" -Status "FAIL" -Message "No usable network adapter is available, so company-standard comparison cannot be performed." -Details "" | Out-Null
        return
    }

    $allIps = @()
    $allPrefixes = @()
    $allGateways = @()
    $allDns = @()
    $allDhcp = @()

    foreach ($adapter in $Adapters) {
        $allIps += @($adapter.IPv4Addresses)
        $allPrefixes += @($adapter.IPv4Prefixes)
        $allGateways += @($adapter.Gateways)
        $allDns += @($adapter.DnsServers)
        if ($null -ne $adapter.DhcpEnabled) {
            $allDhcp += [bool]$adapter.DhcpEnabled
        }
    }

    $allIps = @($allIps | Select-Object -Unique)
    $allPrefixes = @($allPrefixes | Select-Object -Unique)
    $allGateways = @($allGateways | Select-Object -Unique)
    $allDns = @($allDns | Select-Object -Unique)

    if ($allowedIps.Count -gt 0 -or $allowedCidrs.Count -gt 0) {
        $matchedIp = $null
        foreach ($ip in $allIps) {
            if ($allowedIps -contains [string]$ip) {
                $matchedIp = [string]$ip
                break
            }
            foreach ($cidr in $allowedCidrs) {
                if (Test-IPv4InCidr -IpAddress ([string]$ip) -Cidr ([string]$cidr)) {
                    $matchedIp = [string]$ip
                    break
                }
            }
            if ($null -ne $matchedIp) { break }
        }

        if ($null -ne $matchedIp) {
            Add-CheckResult -Category "Company Standard Comparison" -Check "IPv4 Address/Subnet" -Status "PASS" -Message ("Current IP $matchedIp matches the allowlist.") -Details ("Allowed IP addresses: {0}`r`nAllowed subnets: {1}" -f (ConvertTo-DisplayString $allowedIps), (ConvertTo-DisplayString $allowedCidrs)) | Out-Null
        }
        else {
            Add-CheckResult -Category "Company Standard Comparison" -Check "IPv4 Address/Subnet" -Status "FAIL" -Message ("The current IP address does not match the allowlist: {0}" -f (ConvertTo-DisplayString $allIps)) -Details ("Allowed IP addresses: {0}`r`nAllowed subnets: {1}" -f (ConvertTo-DisplayString $allowedIps), (ConvertTo-DisplayString $allowedCidrs)) | Out-Null
        }
    }

    if ($allowedPrefixes.Count -gt 0) {
        $prefixMatches = @($allPrefixes | Where-Object { $allowedPrefixes -contains [int]$_ })
        if ($prefixMatches.Count -gt 0) {
            Add-CheckResult -Category "Company Standard Comparison" -Check "Subnet Prefix" -Status "PASS" -Message ("Current prefix length matches: /{0}" -f (($prefixMatches | Select-Object -Unique) -join ", /")) -Details ("Allowed values: /{0}" -f ($allowedPrefixes -join ", /")) | Out-Null
        }
        else {
            Add-CheckResult -Category "Company Standard Comparison" -Check "Subnet Prefix" -Status "FAIL" -Message ("Current prefix length does not match: /{0}" -f ($allPrefixes -join ", /")) -Details ("Allowed values: /{0}" -f ($allowedPrefixes -join ", /")) | Out-Null
        }
    }

    if ($allowedGateways.Count -gt 0) {
        $gatewayMatches = @($allGateways | Where-Object { $allowedGateways -contains [string]$_ })
        if ($gatewayMatches.Count -gt 0) {
            Add-CheckResult -Category "Company Standard Comparison" -Check "Default Gateway" -Status "PASS" -Message ("Matched: {0}" -f ($gatewayMatches -join ", ")) -Details ("Allowed values: {0}" -f ($allowedGateways -join ", ")) | Out-Null
        }
        else {
            Add-CheckResult -Category "Company Standard Comparison" -Check "Default Gateway" -Status "FAIL" -Message ("Current gateway does not match: {0}" -f (ConvertTo-DisplayString $allGateways)) -Details ("Allowed values: {0}" -f ($allowedGateways -join ", ")) | Out-Null
        }
    }

    if ($requiredDns.Count -gt 0) {
        $missingDns = @($requiredDns | Where-Object { $allDns -notcontains [string]$_ })
        if ($missingDns.Count -eq 0) {
            Add-CheckResult -Category "Company Standard Comparison" -Check "DNS Servers" -Status "PASS" -Message "All required DNS servers are present." -Details ("Required values: {0}`r`nCurrent values: {1}" -f ($requiredDns -join ", "), (ConvertTo-DisplayString $allDns)) | Out-Null
        }
        else {
            Add-CheckResult -Category "Company Standard Comparison" -Check "DNS Servers" -Status "FAIL" -Message ("Missing required DNS servers: {0}" -f ($missingDns -join ", ")) -Details ("Required values: {0}`r`nCurrent values: {1}" -f ($requiredDns -join ", "), (ConvertTo-DisplayString $allDns)) | Out-Null
        }
    }

    if ($hasValidDhcpRule) {
        $expectedBool = [bool]$expectedDhcp
        if ($allDhcp.Count -eq 0) {
            Add-CheckResult -Category "Company Standard Comparison" -Check "DHCP Mode" -Status "ERROR" -Message "The current DHCP state could not be retrieved." -Details ("Expected value: {0}" -f $(if ($expectedBool) { "Enabled" } else { "Disabled" })) | Out-Null
        }
        else {
            $mismatches = @($allDhcp | Where-Object { [bool]$_ -ne $expectedBool })
            if ($mismatches.Count -eq 0) {
                Add-CheckResult -Category "Company Standard Comparison" -Check "DHCP Mode" -Status "PASS" -Message ("Matches expected value: {0}" -f $(if ($expectedBool) { "Enabled" } else { "Disabled (static IP)" })) -Details "" | Out-Null
            }
            else {
                Add-CheckResult -Category "Company Standard Comparison" -Check "DHCP Mode" -Status "FAIL" -Message ("The DHCP mode does not match. Expected: {0}" -f $(if ($expectedBool) { "Enabled" } else { "Disabled (static IP)" })) -Details ("Current state: {0}" -f (($allDhcp | ForEach-Object { if ($_){"Enabled"}else{"Disabled"} }) -join ", ")) | Out-Null
            }
        }
    }
}

# -----------------------------------------------------------------------------
# Active connectivity tests: ping, DNS, TCP, and HTTP/HTTPS with timeouts and fault isolation.
# -----------------------------------------------------------------------------
function Invoke-PingMeasurement {
    param(
        [string]$Target,
        [int]$Count,
        [int]$TimeoutMs
    )

    $successes = New-Object System.Collections.ArrayList
    $attemptDetails = New-Object System.Collections.ArrayList
    $ping = New-Object System.Net.NetworkInformation.Ping

    try {
        for ($i = 1; $i -le $Count; $i++) {
            try {
                $reply = $ping.Send($Target, $TimeoutMs)
                if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                    [void]$successes.Add([double]$reply.RoundtripTime)
                    [void]$attemptDetails.Add(("Attempt {0}: success, {1} ms, reply from {2}" -f $i, $reply.RoundtripTime, $reply.Address))
                }
                else {
                    [void]$attemptDetails.Add(("Attempt {0}: failed, status {1}" -f $i, $reply.Status))
                }
            }
            catch {
                [void]$attemptDetails.Add(("Attempt {0}: error, {1}" -f $i, $_.Exception.Message))
            }
            if ($script:GuiAvailable) {
                [System.Windows.Forms.Application]::DoEvents()
            }
        }
    }
    finally {
        $ping.Dispose()
    }

    $received = $successes.Count
    $lost = $Count - $received
    $lossPercent = 0
    if ($Count -gt 0) {
        $lossPercent = [math]::Round(($lost * 100.0 / $Count), 1)
    }

    $average = $null
    $minimum = $null
    $maximum = $null
    if ($received -gt 0) {
        $average = [math]::Round((($successes | Measure-Object -Average).Average), 1)
        $minimum = [math]::Round((($successes | Measure-Object -Minimum).Minimum), 1)
        $maximum = [math]::Round((($successes | Measure-Object -Maximum).Maximum), 1)
    }

    return [pscustomobject][ordered]@{
        Target         = $Target
        Sent           = $Count
        Received       = $received
        Lost           = $lost
        LossPercent    = $lossPercent
        AverageMs      = $average
        MinimumMs      = $minimum
        MaximumMs      = $maximum
        AttemptDetails = @($attemptDetails)
    }
}

function Resolve-PingTargets {
    param(
        [string]$Address,
        [object[]]$PrimaryAdapters
    )

    if ($Address -eq "AUTO_GATEWAY") {
        $values = @()
        foreach ($adapter in $PrimaryAdapters) {
            $values += @($adapter.Gateways)
        }
        return @($values | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
    }

    if ($Address -eq "AUTO_DNS") {
        $values = @()
        foreach ($adapter in $PrimaryAdapters) {
            $values += @($adapter.DnsServers)
        }
        return @($values | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
    }

    if ([string]::IsNullOrWhiteSpace($Address)) {
        return @()
    }

    return @($Address)
}

function Test-PingTargets {
    param([object[]]$PrimaryAdapters)

    $count = [math]::Max(1, (ConvertTo-IntSafe $script:Config.Tests.PingCount 4))
    $timeout = [math]::Max(250, (ConvertTo-IntSafe $script:Config.Tests.PingTimeoutMs 1200))
    $warningLoss = ConvertTo-DoubleSafe $script:Config.Thresholds.PacketLossWarningPercent 5
    $criticalLoss = ConvertTo-DoubleSafe $script:Config.Thresholds.PacketLossCriticalPercent 20
    $warningLatency = ConvertTo-DoubleSafe $script:Config.Thresholds.LatencyWarningMs 100
    $criticalLatency = ConvertTo-DoubleSafe $script:Config.Thresholds.LatencyCriticalMs 250

    foreach ($targetConfig in @($script:Config.Tests.PingTargets)) {
        if ($null -eq $targetConfig) { continue }

        $name = ConvertTo-SafeString (Get-PropertyValue $targetConfig "Name" "Ping")
        $address = ConvertTo-SafeString (Get-PropertyValue $targetConfig "Address" "")
        $required = [bool](Get-PropertyValue $targetConfig "Required" $false)
        $targets = @(Resolve-PingTargets -Address $address -PrimaryAdapters $PrimaryAdapters)

        if ($targets.Count -eq 0) {
            $status = if ($required) { "FAIL" } else { "WARN" }
            $noTargetDetail = "Configured value: $address"
            if ($address -eq "AUTO_GATEWAY") {
                $noTargetDetail = "Configured value: AUTO_GATEWAY - this placeholder resolves to the current IPv4 default gateway, and none exists right now (usually the local link is down)."
            }
            Add-CheckResult -Category "Latency and Packet Loss" -Check $name -Status $status -Message "No testable target was found." -Details ($noTargetDetail + [Environment]::NewLine + ("Method: .NET Ping — {0} ICMP echo requests, timeout {1} ms." -f $count, $timeout) + [Environment]::NewLine + "Manual check: ping -n $count <target-ip>") | Out-Null
            continue
        }

        foreach ($target in $targets) {
            try {
                $measurement = Invoke-PingMeasurement -Target ([string]$target) -Count $count -TimeoutMs $timeout
                $status = "PASS"

                if ($measurement.Received -eq 0) {
                    # An optional ICMP target may intentionally block Ping.
                    $status = if ($required) { "FAIL" } else { "INFO" }
                }
                elseif ($measurement.LossPercent -ge $criticalLoss) {
                    $status = if ($required) { "FAIL" } else { "WARN" }
                }
                elseif ($measurement.LossPercent -ge $warningLoss) {
                    $status = "WARN"
                }
                elseif ($null -ne $measurement.AverageMs -and $measurement.AverageMs -ge $criticalLatency) {
                    $status = if ($required) { "FAIL" } else { "WARN" }
                }
                elseif ($null -ne $measurement.AverageMs -and $measurement.AverageMs -ge $warningLatency) {
                    $status = "WARN"
                }

                $latencyText = "No successful replies"
                if ($null -ne $measurement.AverageMs) {
                    $latencyText = ("average {0} ms (minimum {1}, maximum {2})" -f $measurement.AverageMs, $measurement.MinimumMs, $measurement.MaximumMs)
                }

                $message = "Target {0}: {1}% loss ({2}/{3} successful), {4}." -f $target, $measurement.LossPercent, $measurement.Received, $measurement.Sent, $latencyText
                $details = (@($measurement.AttemptDetails) + ("Method: .NET Ping — {0} ICMP echo requests, timeout {1} ms." -f $count, $timeout) + ("Manual check: ping -n {0} {1}" -f $count, $target)) -join [Environment]::NewLine
                if ($status -eq "INFO") {
                    $details += [Environment]::NewLine + "Informational: this optional target may simply block ICMP - see the Connectivity group for the authoritative internet verdict."
                }
                Add-CheckResult -Category "Latency and Packet Loss" -Check ("{0}: {1}" -f $name, $target) -Status $status -Message $message -Details $details | Out-Null
            }
            catch {
                $status = if ($required) { "ERROR" } else { "INFO" }
                Add-CheckResult -Category "Latency and Packet Loss" -Check ("{0}: {1}" -f $name, $target) -Status $status -Message "The ping test could not be performed." -Details (Get-ExceptionDetails $_) -Diagnostics (Get-ExceptionDiagnostics $_) | Out-Null
            }
        }
    }
}

function Invoke-DnsLookup {
    param(
        [string]$HostName,
        [int]$TimeoutMs
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $task = [System.Net.Dns]::GetHostAddressesAsync($HostName)
    if (-not $task.Wait($TimeoutMs)) {
        throw "DNS lookup timed out (more than $TimeoutMs ms)."
    }

    $addresses = @()
    foreach ($address in @($task.Result)) {
        $addresses += $address.ToString()
    }
    $stopwatch.Stop()

    return [pscustomobject][ordered]@{
        HostName   = $HostName
        Addresses  = @($addresses | Select-Object -Unique)
        ElapsedMs  = [math]::Round($stopwatch.Elapsed.TotalMilliseconds, 0)
    }
}

function Test-DnsNames {
    $timeout = [math]::Max(500, (ConvertTo-IntSafe $script:Config.Tests.DnsTimeoutMs 4000))
    $methodText = "Method: System.Net.Dns.GetHostAddressesAsync via the OS resolver, timeout $timeout ms."

    foreach ($dnsConfig in @($script:Config.Tests.DnsNames)) {
        if ($null -eq $dnsConfig) { continue }

        if ($dnsConfig -is [string]) {
            $name = "DNS Name Resolution"
            $hostName = [string]$dnsConfig
            $required = $true
        }
        else {
            $name = ConvertTo-SafeString (Get-PropertyValue $dnsConfig "Name" "DNS Name Resolution")
            $hostName = ConvertTo-SafeString (Get-PropertyValue $dnsConfig "Host" "")
            $required = [bool](Get-PropertyValue $dnsConfig "Required" $true)
        }

        if ([string]::IsNullOrWhiteSpace($hostName)) {
            continue
        }

        try {
            $result = Invoke-DnsLookup -HostName $hostName -TimeoutMs $timeout
            if ($result.Addresses.Count -gt 0) {
                Add-CheckResult -Category "DNS" -Check $name -Status "PASS" -Message ("{0} resolved to {1} ({2} ms)." -f $hostName, ($result.Addresses -join ", "), $result.ElapsedMs) -Details ($methodText + [Environment]::NewLine + "Manual check: nslookup $hostName") | Out-Null
            }
            else {
                $status = if ($required) { "FAIL" } else { "WARN" }
                Add-CheckResult -Category "DNS" -Check $name -Status $status -Message ("$hostName returned no IP address.") -Details ($methodText + [Environment]::NewLine + "Manual check: nslookup $hostName") | Out-Null
            }
        }
        catch {
            $status = if ($required) { "FAIL" } else { "WARN" }
            Add-CheckResult -Category "DNS" -Check $name -Status $status -Message ("Unable to resolve $hostName.") -Details ((Get-ExceptionDetails $_) + [Environment]::NewLine + $methodText + [Environment]::NewLine + "Manual check: nslookup $hostName") -Diagnostics (Get-ExceptionDiagnostics $_) | Out-Null
        }
    }
}

function Invoke-TcpConnectionTest {
    param(
        [string]$HostName,
        [int]$Port,
        [int]$TimeoutMs
    )

    $client = New-Object System.Net.Sockets.TcpClient
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $asyncResult = $null

    try {
        $asyncResult = $client.BeginConnect($HostName, $Port, $null, $null)
        if (-not $asyncResult.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) {
            throw "TCP connection timed out (more than $TimeoutMs ms)."
        }
        $client.EndConnect($asyncResult)
        $stopwatch.Stop()

        return [pscustomobject][ordered]@{
            Success   = $true
            Host      = $HostName
            Port      = $Port
            ElapsedMs = [math]::Round($stopwatch.Elapsed.TotalMilliseconds, 0)
            Error     = ""
        }
    }
    catch {
        $stopwatch.Stop()
        return [pscustomobject][ordered]@{
            Success   = $false
            Host      = $HostName
            Port      = $Port
            ElapsedMs = [math]::Round($stopwatch.Elapsed.TotalMilliseconds, 0)
            Error     = $_.Exception.Message
        }
    }
    finally {
        try {
            if ($null -ne $asyncResult -and $null -ne $asyncResult.AsyncWaitHandle) {
                $asyncResult.AsyncWaitHandle.Close()
            }
        }
        catch {}
        $client.Close()
    }
}

function Invoke-HttpConnectionTest {
    param(
        [string]$Url,
        [int]$TimeoutMs
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $response = $null
    $stream = $null

    try {
        try {
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
        }
        catch {}

        $request = [System.Net.HttpWebRequest]::Create($Url)
        $request.Method = "GET"
        $request.Timeout = $TimeoutMs
        $request.ReadWriteTimeout = $TimeoutMs
        $request.AllowAutoRedirect = $true
        $request.UserAgent = "NetworkHealthCheck/$($script:ToolVersion)"
        $request.Proxy = [System.Net.WebRequest]::GetSystemWebProxy()
        if ($null -ne $request.Proxy) {
            $request.Proxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials
        }
        $response = [System.Net.HttpWebResponse]$request.GetResponse()
        $stream = $response.GetResponseStream()
        if ($null -ne $stream) {
            [void]$stream.ReadByte()
        }
        $stopwatch.Stop()

        return [pscustomobject][ordered]@{
            Success      = $true
            Url          = $Url
            StatusCode   = [int]$response.StatusCode
            StatusText   = [string]$response.StatusDescription
            FinalUrl     = [string]$response.ResponseUri
            ElapsedMs    = [math]::Round($stopwatch.Elapsed.TotalMilliseconds, 0)
            Error        = ""
        }
    }
    catch [System.Net.WebException] {
        $stopwatch.Stop()
        if ($null -ne $_.Exception.Response) {
            $response = [System.Net.HttpWebResponse]$_.Exception.Response
            return [pscustomobject][ordered]@{
                Success      = $true
                Url          = $Url
                StatusCode   = [int]$response.StatusCode
                StatusText   = [string]$response.StatusDescription
                FinalUrl     = [string]$response.ResponseUri
                ElapsedMs    = [math]::Round($stopwatch.Elapsed.TotalMilliseconds, 0)
                Error        = "An HTTP response was received, so the network path is reachable; the server returned a non-success status."
            }
        }

        return [pscustomobject][ordered]@{
            Success      = $false
            Url          = $Url
            StatusCode   = 0
            StatusText   = ""
            FinalUrl     = ""
            ElapsedMs    = [math]::Round($stopwatch.Elapsed.TotalMilliseconds, 0)
            Error        = $_.Exception.Message
        }
    }
    catch {
        $stopwatch.Stop()
        return [pscustomobject][ordered]@{
            Success      = $false
            Url          = $Url
            StatusCode   = 0
            StatusText   = ""
            FinalUrl     = ""
            ElapsedMs    = [math]::Round($stopwatch.Elapsed.TotalMilliseconds, 0)
            Error        = $_.Exception.Message
        }
    }
    finally {
        if ($null -ne $stream) {
            try { $stream.Dispose() } catch {}
        }
        if ($null -ne $response) {
            try { $response.Close() } catch {}
        }
    }
}

function Add-ConnectivityGroupResult {
    param(
        [hashtable]$GroupResults,
        [string]$GroupName,
        [bool]$Required
    )

    $entries = @()
    if ($GroupResults.ContainsKey($GroupName)) {
        $entries = @($GroupResults[$GroupName])
    }

    if ($entries.Count -eq 0) {
        $status = if ($Required) { "ERROR" } else { "INFO" }
        Add-CheckResult -Category "Connectivity" -Check ("Group: $GroupName") -Status $status -Message "This group has no executable test items." -Details "Check the Group names and test targets in the configuration file." | Out-Null
        return
    }

    $successful = @($entries | Where-Object { $_.Success })
    if ($successful.Count -gt 0) {
        $names = @($successful | ForEach-Object { $_.Name })
        Add-CheckResult -Category "Connectivity" -Check ("Group: $GroupName") -Status "PASS" -Message ("At least one connectivity method succeeded: {0}" -f ($names -join ", ")) -Details (("{0}/{1} item(s) succeeded." -f $successful.Count, $entries.Count) + [Environment]::NewLine + "Method: the group passes if at least one member connectivity test succeeds.") | Out-Null
    }
    else {
        $status = if ($Required) { "FAIL" } else { "WARN" }
        $details = (@($entries | ForEach-Object { "{0}: {1}" -f $_.Name, $_.Error }) + "Method: the group passes if at least one member connectivity test succeeds.") -join [Environment]::NewLine
        Add-CheckResult -Category "Connectivity" -Check ("Group: $GroupName") -Status $status -Message "All connectivity methods failed." -Details $details | Out-Null
    }
}

function Test-ConnectivityTargets {
    $tcpTimeout = [math]::Max(500, (ConvertTo-IntSafe $script:Config.Tests.TcpTimeoutMs 4000))
    $httpTimeout = [math]::Max(500, (ConvertTo-IntSafe $script:Config.Tests.HttpTimeoutMs 6000))
    $tcpMethod = "Method: TcpClient.BeginConnect, timeout $tcpTimeout ms."
    $httpMethod = "Method: HttpWebRequest GET via the system proxy, TLS 1.2, timeout $httpTimeout ms."
    $groupResults = @{}

    foreach ($target in @($script:Config.Tests.TcpTargets)) {
        if ($null -eq $target) { continue }

        $name = ConvertTo-SafeString (Get-PropertyValue $target "Name" "TCP Connection")
        $hostName = ConvertTo-SafeString (Get-PropertyValue $target "Host" "")
        $port = ConvertTo-IntSafe (Get-PropertyValue $target "Port" 0) 0
        $required = [bool](Get-PropertyValue $target "Required" $false)
        $group = ConvertTo-SafeString (Get-PropertyValue $target "Group" "")

        if ([string]::IsNullOrWhiteSpace($hostName) -or $port -lt 1 -or $port -gt 65535) {
            if ($required) {
                Add-CheckResult -Category "TCP Connection" -Check $name -Status "ERROR" -Message "The configured host or port is invalid." -Details ("Host=$hostName, Port=$port") | Out-Null
            }
            continue
        }

        $result = Invoke-TcpConnectionTest -HostName $hostName -Port $port -TimeoutMs $tcpTimeout
        if ($result.Success) {
            Add-CheckResult -Category "TCP Connection" -Check $name -Status "PASS" -Message ("Connected to {0}:{1} in {2} ms." -f $hostName, $port, $result.ElapsedMs) -Details ($tcpMethod + [Environment]::NewLine + "Manual check: Test-NetConnection $hostName -Port $port") | Out-Null
        }
        else {
            $status = if ($required) { "FAIL" } else { "INFO" }
            Add-CheckResult -Category "TCP Connection" -Check $name -Status $status -Message ("Unable to connect to {0}:{1}." -f $hostName, $port) -Details ($result.Error + [Environment]::NewLine + $tcpMethod + [Environment]::NewLine + "Manual check: Test-NetConnection $hostName -Port $port") | Out-Null
        }

        if (-not [string]::IsNullOrWhiteSpace($group)) {
            if (-not $groupResults.ContainsKey($group)) {
                $groupResults[$group] = New-Object System.Collections.ArrayList
            }
            [void]$groupResults[$group].Add([pscustomobject]@{
                Name    = $name
                Success = $result.Success
                Error   = $result.Error
            })
        }
    }

    foreach ($target in @($script:Config.Tests.HttpTargets)) {
        if ($null -eq $target) { continue }

        $name = ConvertTo-SafeString (Get-PropertyValue $target "Name" "HTTP/HTTPS Connection")
        $url = ConvertTo-SafeString (Get-PropertyValue $target "Url" "")
        $required = [bool](Get-PropertyValue $target "Required" $false)
        $group = ConvertTo-SafeString (Get-PropertyValue $target "Group" "")

        if ([string]::IsNullOrWhiteSpace($url)) {
            if ($required) {
                Add-CheckResult -Category "HTTP/HTTPS" -Check $name -Status "ERROR" -Message "The configured URL is blank." -Details "" | Out-Null
            }
            continue
        }

        $result = Invoke-HttpConnectionTest -Url $url -TimeoutMs $httpTimeout
        if ($result.Success) {
            Add-CheckResult -Category "HTTP/HTTPS" -Check $name -Status "PASS" -Message ("HTTP {0}, elapsed {1} ms." -f $result.StatusCode, $result.ElapsedMs) -Details ("Original URL: {0}`r`nFinal URL: {1}`r`nStatus: {2}`r`n{3}`r`nManual check: Invoke-WebRequest {0} -UseBasicParsing" -f $url, $result.FinalUrl, $result.StatusText, $httpMethod) | Out-Null
        }
        else {
            $status = if ($required) { "FAIL" } else { "INFO" }
            Add-CheckResult -Category "HTTP/HTTPS" -Check $name -Status $status -Message ("Unable to connect: $url") -Details ($result.Error + [Environment]::NewLine + $httpMethod + [Environment]::NewLine + "Manual check: Invoke-WebRequest $url -UseBasicParsing") | Out-Null
        }

        if (-not [string]::IsNullOrWhiteSpace($group)) {
            if (-not $groupResults.ContainsKey($group)) {
                $groupResults[$group] = New-Object System.Collections.ArrayList
            }
            [void]$groupResults[$group].Add([pscustomobject]@{
                Name    = $name
                Success = $result.Success
                Error   = $result.Error
            })
        }
    }

    $requiredGroups = @($script:Config.Tests.RequiredConnectivityGroups | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    $allGroups = @()
    foreach ($groupKey in $groupResults.Keys) {
        $allGroups += [string]$groupKey
    }
    $allGroups += @($requiredGroups)
    $allGroups = @($allGroups | Select-Object -Unique)

    foreach ($group in $allGroups) {
        Add-ConnectivityGroupResult -GroupResults $groupResults -GroupName ([string]$group) -Required ($requiredGroups -contains [string]$group)
    }
}

# -----------------------------------------------------------------------------
# Counter sampling: compare before/after adapter error/discard and TCP sent/retransmitted totals.
# -----------------------------------------------------------------------------
function Get-AdapterStatisticsSnapshot {
    if (-not (Get-Command Get-NetAdapterStatistics -ErrorAction SilentlyContinue)) {
        throw "Get-NetAdapterStatistics is not available on this system."
    }

    $data = @{}
    foreach ($stat in @(Get-NetAdapterStatistics -ErrorAction Stop)) {
        $name = [string]$stat.Name
        if ([string]::IsNullOrWhiteSpace($name)) {
            continue
        }
        $data[$name] = [pscustomobject][ordered]@{
            Name                       = $name
            ReceivedPacketErrors       = ConvertTo-UInt64Safe $stat.ReceivedPacketErrors
            OutboundPacketErrors       = ConvertTo-UInt64Safe $stat.OutboundPacketErrors
            ReceivedDiscardedPackets   = ConvertTo-UInt64Safe $stat.ReceivedDiscardedPackets
            OutboundDiscardedPackets   = ConvertTo-UInt64Safe $stat.OutboundDiscardedPackets
            ReceivedBytes              = ConvertTo-UInt64Safe $stat.ReceivedBytes
            SentBytes                  = ConvertTo-UInt64Safe $stat.SentBytes
        }
    }
    return $data
}

function Compare-AdapterStatistics {
    param(
        [hashtable]$Before,
        [hashtable]$After,
        [object[]]$Adapters
    )

    if ($null -eq $Before -or $null -eq $After) {
        return
    }

    $warningErrors = [uint64][math]::Max(1, (ConvertTo-IntSafe $script:Config.Thresholds.AdapterErrorWarningDelta 1))
    $criticalErrors = [uint64][math]::Max($warningErrors, (ConvertTo-IntSafe $script:Config.Thresholds.AdapterErrorCriticalDelta 10))
    $warningDiscards = [uint64][math]::Max(1, (ConvertTo-IntSafe $script:Config.Thresholds.AdapterDiscardWarningDelta 1))
    $criticalDiscards = [uint64][math]::Max($warningDiscards, (ConvertTo-IntSafe $script:Config.Thresholds.AdapterDiscardCriticalDelta 100))

    $adapterNames = @($Adapters | ForEach-Object { [string]$_.Name } | Select-Object -Unique)
    if ($adapterNames.Count -eq 0) {
        $adapterNames = @($After.Keys)
    }

    foreach ($name in $adapterNames) {
        if (-not $Before.ContainsKey($name) -or -not $After.ContainsKey($name)) {
            Add-CheckResult -Category "Network Adapter Error Counters" -Check $name -Status "INFO" -Message "Complete before-and-after comparison data could not be retrieved." -Details "The adapter may have switched, reconnected, or changed name during the test." | Out-Null
            continue
        }

        $beforeItem = $Before[$name]
        $afterItem = $After[$name]

        $counterReset = (
            [double]$afterItem.ReceivedPacketErrors -lt [double]$beforeItem.ReceivedPacketErrors -or
            [double]$afterItem.OutboundPacketErrors -lt [double]$beforeItem.OutboundPacketErrors -or
            [double]$afterItem.ReceivedDiscardedPackets -lt [double]$beforeItem.ReceivedDiscardedPackets -or
            [double]$afterItem.OutboundDiscardedPackets -lt [double]$beforeItem.OutboundDiscardedPackets -or
            [double]$afterItem.ReceivedBytes -lt [double]$beforeItem.ReceivedBytes -or
            [double]$afterItem.SentBytes -lt [double]$beforeItem.SentBytes
        )

        if ($counterReset) {
            $resetDetails = @(
                "Start: RxErrors=$($beforeItem.ReceivedPacketErrors), TxErrors=$($beforeItem.OutboundPacketErrors), RxDiscards=$($beforeItem.ReceivedDiscardedPackets), TxDiscards=$($beforeItem.OutboundDiscardedPackets), RxBytes=$($beforeItem.ReceivedBytes), TxBytes=$($beforeItem.SentBytes)",
                "End: RxErrors=$($afterItem.ReceivedPacketErrors), TxErrors=$($afterItem.OutboundPacketErrors), RxDiscards=$($afterItem.ReceivedDiscardedPackets), TxDiscards=$($afterItem.OutboundDiscardedPackets), RxBytes=$($afterItem.ReceivedBytes), TxBytes=$($afterItem.SentBytes)"
            ) -join [Environment]::NewLine
            Add-CheckResult -Category "Network Adapter Error Counters" -Check $name -Status "WARN" -Message "The adapter counters were reset during the test, possibly because the adapter reconnected or restarted; a reliable delta cannot be calculated." -Details $resetDetails | Out-Null
            continue
        }

        $rxErrorDelta = [uint64][math]::Max(0, ([double]$afterItem.ReceivedPacketErrors - [double]$beforeItem.ReceivedPacketErrors))
        $txErrorDelta = [uint64][math]::Max(0, ([double]$afterItem.OutboundPacketErrors - [double]$beforeItem.OutboundPacketErrors))
        $rxDiscardDelta = [uint64][math]::Max(0, ([double]$afterItem.ReceivedDiscardedPackets - [double]$beforeItem.ReceivedDiscardedPackets))
        $txDiscardDelta = [uint64][math]::Max(0, ([double]$afterItem.OutboundDiscardedPackets - [double]$beforeItem.OutboundDiscardedPackets))
        $errorDelta = $rxErrorDelta + $txErrorDelta
        $discardDelta = $rxDiscardDelta + $txDiscardDelta

        $status = "PASS"
        if ($errorDelta -ge $criticalErrors -or $discardDelta -ge $criticalDiscards) {
            $status = "FAIL"
        }
        elseif ($errorDelta -ge $warningErrors -or $discardDelta -ge $warningDiscards) {
            $status = "WARN"
        }

        $message = "During the test, errors increased by {0} and discards increased by {1}." -f $errorDelta, $discardDelta
        $details = @(
            "Receive error delta: $rxErrorDelta (cumulative $($afterItem.ReceivedPacketErrors))",
            "Send error delta: $txErrorDelta (cumulative $($afterItem.OutboundPacketErrors))",
            "Receive discard delta: $rxDiscardDelta (cumulative $($afterItem.ReceivedDiscardedPackets))",
            "Send discard delta: $txDiscardDelta (cumulative $($afterItem.OutboundDiscardedPackets))",
            "Cumulative received bytes: $($afterItem.ReceivedBytes)",
            "Cumulative sent bytes: $($afterItem.SentBytes)",
            "Method: Get-NetAdapterStatistics sampled before and after the test; deltas shown.",
            "Manual check: Get-NetAdapterStatistics -Name '$name'"
        ) -join [Environment]::NewLine

        Add-CheckResult -Category "Network Adapter Error Counters" -Check $name -Status $status -Message $message -Details $details | Out-Null
    }
}

function Get-CimOrWmiInstance {
    param([string]$ClassName)

    if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) {
        return Get-CimInstance -ClassName $ClassName -OperationTimeoutSec 8 -ErrorAction Stop
    }
    if (Get-Command Get-WmiObject -ErrorAction SilentlyContinue) {
        return Get-WmiObject -Class $ClassName -ErrorAction Stop
    }
    throw "No usable CIM/WMI command is available on this system."
}

function Get-TcpCounterSnapshot {
    $snapshot = @{}
    $errors = New-Object System.Collections.ArrayList

    foreach ($protocol in @("TCPv4", "TCPv6")) {
        $className = "Win32_PerfRawData_Tcpip_$protocol"
        try {
            $counter = Get-CimOrWmiInstance -ClassName $className
            if ($counter -is [array]) {
                $counter = $counter | Select-Object -First 1
            }
            if ($null -eq $counter) {
                throw "Performance counter class $className returned no data."
            }
            if ($null -eq $counter.PSObject.Properties["SegmentsSentPersec"] -or
                $null -eq $counter.PSObject.Properties["SegmentsRetransmittedPersec"]) {
                throw "Performance counter class $className is missing required fields."
            }

            $snapshot[$protocol] = [pscustomobject][ordered]@{
                Protocol        = $protocol
                Timestamp       = Get-Date
                SegmentsSent    = ConvertTo-UInt64Safe $counter.SegmentsSentPersec
                Retransmitted   = ConvertTo-UInt64Safe $counter.SegmentsRetransmittedPersec
            }
        }
        catch {
            [void]$errors.Add([pscustomobject]@{
                Protocol    = $protocol
                Error       = Get-ExceptionDetails $_
                Diagnostics = Get-ExceptionDiagnostics $_
            })
        }
    }

    return [pscustomobject][ordered]@{
        Timestamp = Get-Date
        Counters  = $snapshot
        Errors    = @($errors)
    }
}

function Compare-TcpCounters {
    param(
        [object]$Before,
        [object]$After
    )

    if ($null -eq $Before -or $null -eq $After) {
        Add-CheckResult -Category "TCP Retransmissions" -Check "System Counters" -Status "ERROR" -Message "Complete before-and-after TCP counter data is unavailable." -Details "" | Out-Null
        return
    }

    $counterErrors = @()
    $counterErrors += @($Before.Errors)
    $counterErrors += @($After.Errors)
    foreach ($errorItem in $counterErrors) {
        Add-CheckResult -Category "TCP Retransmissions" -Check ("{0} counters" -f $errorItem.Protocol) -Status "ERROR" -Message "The TCP retransmission counter could not be read." -Details $errorItem.Error -Diagnostics $errorItem.Diagnostics | Out-Null
    }

    $warningPercent = ConvertTo-DoubleSafe (Get-PropertyValue $script:Config.Thresholds "TcpRetransmissionWarningPercent" 2) 2
    $criticalPercent = ConvertTo-DoubleSafe (Get-PropertyValue $script:Config.Thresholds "TcpRetransmissionCriticalPercent" 5) 5
    $criticalCount = [uint64](ConvertTo-IntSafe (Get-PropertyValue $script:Config.Thresholds "TcpRetransmissionCriticalCount" 50) 50)
    $minimumSegments = [uint64](ConvertTo-IntSafe (Get-PropertyValue $script:Config.Thresholds "MinimumTcpSegmentsForRate" 50) 50)

    foreach ($protocol in @("TCPv4", "TCPv6")) {
        if (-not $Before.Counters.ContainsKey($protocol) -or -not $After.Counters.ContainsKey($protocol)) {
            continue
        }

        $start = $Before.Counters[$protocol]
        $end = $After.Counters[$protocol]
        $sentDeltaDouble = [double]$end.SegmentsSent - [double]$start.SegmentsSent
        $retransDeltaDouble = [double]$end.Retransmitted - [double]$start.Retransmitted

        if ($sentDeltaDouble -lt 0 -or $retransDeltaDouble -lt 0) {
            Add-CheckResult -Category "TCP Retransmissions" -Check $protocol -Status "ERROR" -Message "The counter was reset or overflowed during the test, so the delta cannot be calculated." -Details ("Start Sent={0}, Retrans={1}; end Sent={2}, Retrans={3}" -f $start.SegmentsSent, $start.Retransmitted, $end.SegmentsSent, $end.Retransmitted) | Out-Null
            continue
        }

        $sentDelta = [uint64]$sentDeltaDouble
        $retransDelta = [uint64]$retransDeltaDouble
        $rate = 0.0
        if ($sentDelta -gt 0) {
            $rate = [math]::Round(($retransDelta * 100.0 / $sentDelta), 3)
        }

        $sampleSeconds = [math]::Round((New-TimeSpan -Start $Before.Timestamp -End $After.Timestamp).TotalSeconds, 1)
        $details = @(
            "Sample duration: $sampleSeconds seconds",
            "Sent TCP segment delta: $sentDelta",
            "Retransmitted segment delta: $retransDelta",
            "Approximate retransmission rate: $rate%",
            "Starting cumulative values: Sent=$($start.SegmentsSent), Retrans=$($start.Retransmitted)",
            "Ending cumulative values: Sent=$($end.SegmentsSent), Retrans=$($end.Retransmitted)",
            "Method: Win32_PerfRawData_Tcpip_$protocol cumulative counters; delta over the sample window.",
            "Manual check: Get-CimInstance Win32_PerfRawData_Tcpip_$protocol — sample twice and compare the deltas.",
            "Explanation: This is a system-wide statistic for the entire computer during the test, not for a single application."
        ) -join [Environment]::NewLine

        if ($rate -gt 100) {
            $details += [Environment]::NewLine + "Note: a rate above 100% means retransmissions of segments sent before the sample window - read it as a ratio, not a percentage."
        }

        if ($sentDelta -eq 0 -and $retransDelta -eq 0) {
            Add-CheckResult -Category "TCP Retransmissions" -Check $protocol -Status "INFO" -Message "There was not enough TCP send traffic during the sample. No retransmissions were observed, but this does not establish the long-term condition." -Details $details | Out-Null
            continue
        }

        if ($sentDelta -lt $minimumSegments) {
            if ($retransDelta -gt 0) {
                Add-CheckResult -Category "TCP Retransmissions" -Check $protocol -Status "WARN" -Message ("The traffic sample is small, but {0} retransmission(s) were observed (approximately {1}%)." -f $retransDelta, $rate) -Details $details | Out-Null
            }
            else {
                Add-CheckResult -Category "TCP Retransmissions" -Check $protocol -Status "INFO" -Message ("The sample contains only {0} sent segment(s); no retransmissions were observed." -f $sentDelta) -Details $details | Out-Null
            }
            continue
        }

        $status = "PASS"
        if ($rate -ge $criticalPercent -or ($retransDelta -ge $criticalCount -and $rate -ge $warningPercent)) {
            $status = "FAIL"
        }
        elseif ($rate -ge $warningPercent -or $retransDelta -ge $criticalCount) {
            $status = "WARN"
        }

        Add-CheckResult -Category "TCP Retransmissions" -Check $protocol -Status $status -Message ("Sent {0}, retransmitted {1}, approximate retransmission rate {2}%." -f $sentDelta, $retransDelta, $rate) -Details $details | Out-Null
    }
}

function Wait-ForMinimumTcpSample {
    param(
        [datetime]$StartTime,
        [int]$MinimumSeconds
    )

    $elapsed = ((Get-Date) - $StartTime).TotalSeconds
    $remaining = [math]::Ceiling($MinimumSeconds - $elapsed)
    if ($remaining -le 0) {
        return
    }

    for ($i = $remaining; $i -gt 0; $i--) {
        Set-UiProgress -Percent 87 -Text ("Sampling TCP retransmissions, approximately $i second(s) remaining")
        Start-Sleep -Seconds 1
        if ($script:GuiAvailable) {
            [System.Windows.Forms.Application]::DoEvents()
        }
    }
}

# -----------------------------------------------------------------------------
# Result aggregation: overall precedence is FAIL > ERROR > WARN > PASS.
# -----------------------------------------------------------------------------
function Get-OverallStatus {
    $failCount = @($script:Results | Where-Object { $_.Status -eq "FAIL" }).Count
    $errorCount = @($script:Results | Where-Object { $_.Status -eq "ERROR" }).Count
    $warnCount = @($script:Results | Where-Object { $_.Status -eq "WARN" }).Count

    if ($failCount -gt 0) {
        return [pscustomobject]@{
            Code = "FAIL"
            Text = "Problem Detected"
            Description = "At least one required check failed."
        }
    }
    if ($errorCount -gt 0) {
        return [pscustomobject]@{
            Code = "ERROR"
            Text = "Test Incomplete"
            Description = "Some checks could not be completed because of permissions, system components, or execution errors."
        }
    }
    if ($warnCount -gt 0) {
        return [pscustomobject]@{
            Code = "WARN"
            Text = "Attention Required"
            Description = "No required check failed, but warnings or quality issues were detected."
        }
    }
    return [pscustomobject]@{
        Code = "PASS"
        Text = "Overall Healthy"
        Description = "All required checks that could be executed passed."
    }
}

function Get-SummaryCounts {
    return [pscustomobject][ordered]@{
        Pass  = @($script:Results | Where-Object { $_.Status -eq "PASS" }).Count
        Warn  = @($script:Results | Where-Object { $_.Status -eq "WARN" }).Count
        Fail  = @($script:Results | Where-Object { $_.Status -eq "FAIL" }).Count
        Info  = @($script:Results | Where-Object { $_.Status -eq "INFO" }).Count
        Error = @($script:Results | Where-Object { $_.Status -eq "ERROR" }).Count
        Total = $script:Results.Count
    }
}

# -----------------------------------------------------------------------------
# Reporting: generate HTML, text, and JSON; preserve detailed exceptions on write failures.
# -----------------------------------------------------------------------------
function New-HtmlReportContent {
    param(
        [object]$SystemSummary,
        [object]$Overall,
        [object]$Counts
    )

    $organization = ConvertTo-SafeString $script:Config.OrganizationName
    if ([string]::IsNullOrWhiteSpace($organization)) {
        $organization = "Organization Not Specified"
    }

    $rows = New-Object System.Text.StringBuilder
    foreach ($result in $script:Results) {
        $statusClass = ([string]$result.Status).ToLowerInvariant()
        $detailsHtml = ""
        $detailsText = [string]$result.Details
        if (-not [string]::IsNullOrWhiteSpace([string]$result.Diagnostics)) {
            $diagnosticsNote = "Technical diagnostics (script location and call stack) are recorded in the JSON report only."
            if ([string]::IsNullOrWhiteSpace($detailsText)) {
                $detailsText = $diagnosticsNote
            }
            else {
                $detailsText += [Environment]::NewLine + $diagnosticsNote
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($detailsText)) {
            $detailsEncoded = ConvertTo-HtmlEncoded $detailsText
            $detailsHtml = "<details><summary>Show Details</summary><pre>$detailsEncoded</pre></details>"
        }

        $rowHtml = @"
<tr class="$statusClass">
  <td>$(ConvertTo-HtmlEncoded ($result.Time.ToString("HH:mm:ss")))</td>
  <td>$(ConvertTo-HtmlEncoded $result.Category)</td>
  <td>$(ConvertTo-HtmlEncoded $result.Check)</td>
  <td><span class="badge $statusClass">$(ConvertTo-HtmlEncoded (Get-StatusText $result.Status))</span></td>
  <td>$(ConvertTo-HtmlEncoded $result.Message)$detailsHtml</td>
</tr>
"@
        [void]$rows.AppendLine($rowHtml)
    }

    $overallClass = $Overall.Code.ToLowerInvariant()
    $generatedAt = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $duration = 0
    if ($null -ne $script:RunStartedAt -and $null -ne $script:RunFinishedAt) {
        $duration = [math]::Round(($script:RunFinishedAt - $script:RunStartedAt).TotalSeconds, 1)
    }

    return @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Network Health Check Report - $(ConvertTo-HtmlEncoded $env:COMPUTERNAME)</title>
<style>
:root { color-scheme: light; }
body { margin: 0; font-family: "Segoe UI", Arial, sans-serif; background: #f4f6f8; color: #1f2933; }
header { background: #17324d; color: white; padding: 24px 32px; }
header h1 { margin: 0 0 8px; font-size: 26px; }
header p { margin: 4px 0; opacity: .92; }
main { max-width: 1180px; margin: 24px auto; padding: 0 18px 40px; }
.overall { border-radius: 12px; padding: 20px 22px; margin-bottom: 18px; border-left: 8px solid; background: white; box-shadow: 0 2px 8px rgba(0,0,0,.08); }
.overall.pass { border-color: #14804a; }
.overall.warn { border-color: #b7791f; }
.overall.fail { border-color: #c53030; }
.overall.error { border-color: #805ad5; }
.overall h2 { margin: 0 0 6px; }
.cards { display: grid; grid-template-columns: repeat(6, minmax(100px, 1fr)); gap: 10px; margin-bottom: 18px; }
.card { background: white; border-radius: 10px; padding: 14px; text-align: center; box-shadow: 0 2px 8px rgba(0,0,0,.06); }
.card strong { display: block; font-size: 25px; margin-top: 5px; }
section { background: white; border-radius: 12px; margin-bottom: 18px; padding: 18px 20px; box-shadow: 0 2px 8px rgba(0,0,0,.06); }
section h2 { margin-top: 0; font-size: 19px; }
.meta { display: grid; grid-template-columns: 190px 1fr; gap: 8px 14px; }
.meta div:nth-child(odd) { font-weight: 700; color: #52606d; }
table { width: 100%; border-collapse: collapse; font-size: 14px; }
th { background: #edf2f7; text-align: left; padding: 10px; border-bottom: 2px solid #cbd5e0; position: sticky; top: 0; }
td { padding: 10px; border-bottom: 1px solid #e2e8f0; vertical-align: top; }
tr.fail td { background: #fff5f5; }
tr.error td { background: #faf5ff; }
tr.warn td { background: #fffaf0; }
.badge { display: inline-block; border-radius: 999px; padding: 3px 9px; font-weight: 700; white-space: nowrap; }
.badge.pass { background: #c6f6d5; color: #22543d; }
.badge.warn { background: #feebc8; color: #7b341e; }
.badge.fail { background: #fed7d7; color: #822727; }
.badge.info { background: #bee3f8; color: #2a4365; }
.badge.error { background: #e9d8fd; color: #553c9a; }
details { margin-top: 7px; }
summary { cursor: pointer; color: #2b6cb0; }
pre { white-space: pre-wrap; word-break: break-word; background: #f7fafc; padding: 10px; border-radius: 6px; border: 1px solid #e2e8f0; }
.notice { border-left: 5px solid #3182ce; background: #ebf8ff; padding: 12px 14px; border-radius: 6px; }
footer { color: #718096; font-size: 13px; margin-top: 16px; }
@media (max-width: 800px) { .cards { grid-template-columns: repeat(3, 1fr); } .meta { grid-template-columns: 1fr; } table { display: block; overflow-x: auto; } }
</style>
</head>
<body>
<header>
  <h1>Network Health Check Report</h1>
  <p>Organization: $(ConvertTo-HtmlEncoded $organization) &nbsp;|&nbsp; Computer: $(ConvertTo-HtmlEncoded $SystemSummary.ComputerName)</p>
  <p>Generated: $(ConvertTo-HtmlEncoded $generatedAt) &nbsp;|&nbsp; Test duration: approximately $(ConvertTo-HtmlEncoded $duration) seconds</p>
</header>
<main>
  <div class="overall $overallClass">
    <h2>$(ConvertTo-HtmlEncoded $Overall.Text)</h2>
    <div>$(ConvertTo-HtmlEncoded $Overall.Description)</div>
  </div>

  <div class="cards">
    <div class="card">Pass<strong>$($Counts.Pass)</strong></div>
    <div class="card">Warning<strong>$($Counts.Warn)</strong></div>
    <div class="card">Fail<strong>$($Counts.Fail)</strong></div>
    <div class="card">Unable to Check<strong>$($Counts.Error)</strong></div>
    <div class="card">Information<strong>$($Counts.Info)</strong></div>
    <div class="card">Total<strong>$($Counts.Total)</strong></div>
  </div>

  <section>
    <h2>Computer and Run Information</h2>
    <div class="meta">
      <div>Computer Name</div><div>$(ConvertTo-HtmlEncoded $SystemSummary.ComputerName)</div>
      <div>User</div><div>$(ConvertTo-HtmlEncoded $SystemSummary.UserName)</div>
      <div>Operating System</div><div>$(ConvertTo-HtmlEncoded $SystemSummary.OperatingSystem) ($(ConvertTo-HtmlEncoded $SystemSummary.OperatingVersion))</div>
      <div>PowerShell</div><div>$(ConvertTo-HtmlEncoded $SystemSummary.PowerShellVersion)</div>
      <div>Tool Version</div><div>$(ConvertTo-HtmlEncoded $SystemSummary.ToolVersion)</div>
      <div>Configuration File</div><div>$(ConvertTo-HtmlEncoded $SystemSummary.ConfigPath)</div>
      <div>Report Directory</div><div>$(ConvertTo-HtmlEncoded $SystemSummary.ReportDirectory)</div>
    </div>
  </section>

  <section>
    <h2>Test Results</h2>
    <div class="notice">"Unable to Check" means the step could not be completed because of permissions, missing system components, company policy, or an execution error. It does not necessarily mean the network is faulty. The TCP retransmission rate is an approximate system-wide value for this sampling period.</div>
    <div style="overflow-x:auto; margin-top:14px;">
      <table>
        <thead><tr><th>Time</th><th>Category</th><th>Check</th><th>Result</th><th>Description</th></tr></thead>
        <tbody>
$($rows.ToString())
        </tbody>
      </table>
    </div>
  </section>

  <footer>NetworkHealthCheck $($script:ToolVersion). This tool only reads system information and performs connectivity tests. It does not modify IP, DNS, routing, or firewall settings.</footer>
</main>
</body>
</html>
"@
}

function New-TextReportContent {
    param(
        [object]$SystemSummary,
        [object]$Overall,
        [object]$Counts
    )

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.AppendLine("Network Health Check Report")
    [void]$builder.AppendLine("=" * 72)
    [void]$builder.AppendLine("Overall result: $($Overall.Text)")
    [void]$builder.AppendLine("Description: $($Overall.Description)")
    [void]$builder.AppendLine("Computer name: $($SystemSummary.ComputerName)")
    [void]$builder.AppendLine("User: $($SystemSummary.UserName)")
    [void]$builder.AppendLine("Operating system: $($SystemSummary.OperatingSystem) ($($SystemSummary.OperatingVersion))")
    [void]$builder.AppendLine("PowerShell: $($SystemSummary.PowerShellVersion)")
    [void]$builder.AppendLine("Tool version: $($SystemSummary.ToolVersion)")
    [void]$builder.AppendLine("Start time: $($script:RunStartedAt.ToString('yyyy-MM-dd HH:mm:ss'))")
    [void]$builder.AppendLine("End time: $($script:RunFinishedAt.ToString('yyyy-MM-dd HH:mm:ss'))")
    [void]$builder.AppendLine("Configuration file: $($SystemSummary.ConfigPath)")
    [void]$builder.AppendLine("Report directory: $($SystemSummary.ReportDirectory)")
    [void]$builder.AppendLine("Summary: Pass $($Counts.Pass), Warning $($Counts.Warn), Fail $($Counts.Fail), Unable to Check $($Counts.Error), Information $($Counts.Info), Total $($Counts.Total)")
    [void]$builder.AppendLine("")

    foreach ($result in $script:Results) {
        [void]$builder.AppendLine(("[{0}] [{1}] {2} / {3}" -f (Get-StatusText $result.Status), $result.Time.ToString("HH:mm:ss"), $result.Category, $result.Check))
        [void]$builder.AppendLine("  $($result.Message)")
        if (-not [string]::IsNullOrWhiteSpace([string]$result.Details)) {
            foreach ($line in ([string]$result.Details -split "`r?`n")) {
                [void]$builder.AppendLine("    $line")
            }
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$result.Diagnostics)) {
            [void]$builder.AppendLine("    Technical diagnostics (script location and call stack) are recorded in the JSON report only.")
        }
        [void]$builder.AppendLine("")
    }

    [void]$builder.AppendLine("Note: 'Unable to Check' means the step was not completed; it does not necessarily mean the network is faulty. TCP retransmissions are approximate system-wide statistics for this sampling period.")
    return $builder.ToString()
}

function Save-Reports {
    $systemSummary = Get-SystemSummary
    $overall = Get-OverallStatus
    $counts = Get-SummaryCounts
    $safeComputerName = ($env:COMPUTERNAME -replace '[^A-Za-z0-9_.-]', '_')
    if ([string]::IsNullOrWhiteSpace($safeComputerName)) {
        $safeComputerName = "Computer"
    }
    $baseName = "NetworkHealthCheck_{0}_{1}" -f (Get-Date -Format "yyyyMMdd_HHmmss"), $safeComputerName

    $htmlPath = Join-Path $script:OutputDirectory ($baseName + ".html")
    $textPath = Join-Path $script:OutputDirectory ($baseName + ".txt")
    $jsonPath = Join-Path $script:OutputDirectory ($baseName + ".json")

    $reportObject = [pscustomobject][ordered]@{
        SchemaVersion = 1
        ToolVersion   = $script:ToolVersion
        Overall       = $overall
        Counts        = $counts
        System        = $systemSummary
        StartedAt     = $script:RunStartedAt
        FinishedAt    = $script:RunFinishedAt
        Results       = @($script:Results)
    }

    $writeErrors = New-Object System.Collections.ArrayList

    try {
        $html = New-HtmlReportContent -SystemSummary $systemSummary -Overall $overall -Counts $counts
        Write-Utf8File -Path $htmlPath -Content $html
        $script:LastHtmlReport = $htmlPath
    }
    catch {
        [void]$writeErrors.Add("Failed to write HTML report: $(Get-ExceptionDetails $_)")
    }

    try {
        $text = New-TextReportContent -SystemSummary $systemSummary -Overall $overall -Counts $counts
        Write-Utf8File -Path $textPath -Content $text
        $script:LastTextReport = $textPath
    }
    catch {
        [void]$writeErrors.Add("Failed to write text report: $(Get-ExceptionDetails $_)")
    }

    try {
        $json = $reportObject | ConvertTo-Json -Depth 10
        Write-Utf8File -Path $jsonPath -Content $json
        $script:LastJsonReport = $jsonPath
    }
    catch {
        [void]$writeErrors.Add("Failed to write JSON report: $(Get-ExceptionDetails $_)")
    }

    if ($writeErrors.Count -gt 0) {
        foreach ($writeError in $writeErrors) {
            Write-UiLog -Status "ERROR" -Text $writeError
        }
        throw ($writeErrors -join [Environment]::NewLine)
    }

    return [pscustomobject]@{
        Html = $htmlPath
        Text = $textPath
        Json = $jsonPath
        Overall = $overall
        Counts = $counts
    }
}

function Write-EmergencyReport {
    param(
        [string]$Title,
        [string]$ErrorDetails
    )

    $directory = $script:OutputDirectory
    if ([string]::IsNullOrWhiteSpace($directory)) {
        $directory = Join-Path ([System.IO.Path]::GetTempPath()) "NetworkHealthCheck\Reports"
    }

    try {
        if (-not (Test-Path -LiteralPath $directory)) {
            [void](New-Item -ItemType Directory -Path $directory -Force -ErrorAction Stop)
        }
    }
    catch {
        $directory = [System.IO.Path]::GetTempPath()
    }

    $path = Join-Path $directory ("NetworkHealthCheck_FATAL_{0}.txt" -f (Get-Date -Format "yyyyMMdd_HHmmss"))

    $partialResults = "(no test results yet)"
    if ($null -ne $script:Results -and $script:Results.Count -gt 0) {
        $partialBuilder = New-Object System.Text.StringBuilder
        foreach ($result in $script:Results) {
            [void]$partialBuilder.AppendLine(("[{0}] {1} / {2}: {3}" -f (Get-StatusText $result.Status), $result.Category, $result.Check, $result.Message))
            if (-not [string]::IsNullOrWhiteSpace([string]$result.Details)) {
                [void]$partialBuilder.AppendLine([string]$result.Details)
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$result.Diagnostics)) {
                [void]$partialBuilder.AppendLine([string]$result.Diagnostics)
            }
            [void]$partialBuilder.AppendLine("")
        }
        $partialResults = $partialBuilder.ToString()
    }

    $content = @"
$Title

Time: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
Computer: $env:COMPUTERNAME
User: $([System.Environment]::UserName)
PowerShell: $($PSVersionTable.PSVersion)
Script path: $(Join-Path $script:BaseDirectory "NetworkHealthCheck.ps1")
Configuration file: $script:EffectiveConfigPath

Error details:
$ErrorDetails

Checks completed before the error:
$partialResults
"@

    try {
        Write-Utf8File -Path $path -Content $content
        return $path
    }
    catch {
        return $null
    }
}

function Update-OverallUi {
    param([object]$Overall)

    if (-not $script:GuiAvailable -or $null -eq $script:OverallLabel) {
        return
    }

    try {
        $script:OverallLabel.Text = "Result: $($Overall.Text) — $($Overall.Description)"
        switch ($Overall.Code) {
            "PASS"  { $script:OverallLabel.ForeColor = [System.Drawing.Color]::FromArgb(20, 128, 74) }
            "WARN"  { $script:OverallLabel.ForeColor = [System.Drawing.Color]::FromArgb(183, 121, 31) }
            "FAIL"  { $script:OverallLabel.ForeColor = [System.Drawing.Color]::FromArgb(197, 48, 48) }
            "ERROR" { $script:OverallLabel.ForeColor = [System.Drawing.Color]::FromArgb(128, 90, 213) }
        }
    }
    catch {}
}

# -----------------------------------------------------------------------------
# Orchestration: execute checks in a fixed order; one failed step does not stop later checks.
# -----------------------------------------------------------------------------
function Run-AllChecks {
    $script:IsRunning = $true
    $script:Results.Clear()
    $script:LastHtmlReport = $null
    $script:LastTextReport = $null
    $script:LastJsonReport = $null
    $script:RunStartedAt = Get-Date
    $script:RunFinishedAt = $null

    if ($script:GuiAvailable) {
        $script:LogBox.Clear()
        $script:StartButton.Enabled = $false
        $script:OpenReportButton.Enabled = $false
        $script:OpenFolderButton.Enabled = $false
        $script:OverallLabel.Text = "Result: Test in progress"
        $script:OverallLabel.ForeColor = [System.Drawing.Color]::FromArgb(31, 41, 51)
        $script:ReportPathLabel.Text = "Report has not been generated"
    }

    Write-UiLog -Status "INFO" -Text "Network health check started. The test is read-only and will not modify network settings."
    Set-UiProgress -Percent 2 -Text "Initializing"

    if ($null -ne $script:ConfigLoadError) {
        Add-CheckResult -Category "Program Configuration" -Check "Configuration File" -Status "ERROR" -Message "The configuration file could not be loaded. Built-in defaults were used." -Details $script:ConfigLoadError -Diagnostics $script:ConfigLoadDiagnostics | Out-Null
    }
    else {
        Add-CheckResult -Category "Program Configuration" -Check "Configuration File" -Status "PASS" -Message ("Loaded: {0}" -f $script:EffectiveConfigPath) -Details "" | Out-Null
    }

    foreach ($startupMessage in @($script:StartupMessages)) {
        Add-CheckResult -Category "Program Environment" -Check "Startup Notice" -Status "WARN" -Message $startupMessage -Details "" | Out-Null
    }

    Invoke-CheckStep -Category "Program Configuration" -Name "Validate Configuration" -Progress 4 -Action {
        Test-ConfigurationSemantics
    } | Out-Null

    if (-not (Test-IsWindowsPlatform)) {
        Add-CheckResult -Category "Program Environment" -Check "Operating System" -Status "FAIL" -Message "This version supports only Windows 10/11 or compatible Windows Server versions." -Details ([System.Environment]::OSVersion.VersionString) | Out-Null
        $script:RunFinishedAt = Get-Date
        $report = Save-Reports
        return $report
    }

    if ($PSVersionTable.PSVersion.Major -lt 5) {
        Add-CheckResult -Category "Program Environment" -Check "PowerShell Version" -Status "FAIL" -Message "PowerShell 5.1 or later is required." -Details ("Current version: {0}" -f $PSVersionTable.PSVersion) | Out-Null
        $script:RunFinishedAt = Get-Date
        $report = Save-Reports
        return $report
    }
    else {
        Add-CheckResult -Category "Program Environment" -Check "PowerShell Version" -Status "PASS" -Message ("Current version: {0}" -f $PSVersionTable.PSVersion) -Details "" | Out-Null
    }

    Invoke-CheckStep -Category "System Information" -Name "Get Computer and Operating System Information" -Progress 7 -Action {
        $summary = Get-SystemSummary
        Add-CheckResult -Category "System Information" -Check "Computer" -Status "INFO" -Message ("{0}, user {1}." -f $summary.ComputerName, $summary.UserName) -Details ("Operating system: {0} ({1})`r`nPowerShell: {2}" -f $summary.OperatingSystem, $summary.OperatingVersion, $summary.PowerShellVersion) | Out-Null
    } | Out-Null

    $tcpBaseline = Invoke-CheckStep -Category "TCP Retransmissions" -Name "Get TCP Retransmission Baseline" -Progress 10 -Action {
        $snapshot = Get-TcpCounterSnapshot
        if ($snapshot.Counters.Count -eq 0) {
            throw "Neither the TCPv4 nor TCPv6 counters could be read."
        }
        return $snapshot
    }
    $tcpSampleStart = Get-Date

    $adapterStatsBefore = Invoke-CheckStep -Category "Network Adapter Error Counters" -Name "Get Network Adapter Error Baseline" -Progress 13 -Action {
        return (Get-AdapterStatisticsSnapshot)
    }

    $networkSnapshot = Invoke-CheckStep -Category "Network Adapter and IP" -Name "Get Network Adapters, IP, Gateways, and DNS" -Progress 20 -Action {
        return @(Get-NetworkSnapshot)
    }

    if ($null -eq $networkSnapshot) {
        $networkSnapshot = @()
    }
    else {
        $networkSnapshot = @($networkSnapshot)
    }
    $script:PrimaryAdapters = @(Get-PrimaryAdapters -Adapters $networkSnapshot)

    Invoke-CheckStep -Category "Network Adapter and IP" -Name "Check Current Network Configuration" -Progress 28 -Action {
        Add-NetworkSnapshotResults -Adapters $networkSnapshot
    } | Out-Null

    Invoke-CheckStep -Category "Company Standard Comparison" -Name "Compare Company-Standard IP Configuration" -Progress 36 -Action {
        Test-ExpectedNetworkConfiguration -Adapters $script:PrimaryAdapters
    } | Out-Null

    Invoke-CheckStep -Category "Latency and Packet Loss" -Name "Test Default Gateway and Network Quality" -Progress 46 -Action {
        Test-PingTargets -PrimaryAdapters $script:PrimaryAdapters
    } | Out-Null

    Invoke-CheckStep -Category "DNS" -Name "Test DNS Name Resolution" -Progress 60 -Action {
        Test-DnsNames
    } | Out-Null

    Invoke-CheckStep -Category "Connectivity" -Name "Test TCP and HTTP/HTTPS Connectivity" -Progress 70 -Action {
        Test-ConnectivityTargets
    } | Out-Null

    $minimumSampleSeconds = [math]::Max(1, (ConvertTo-IntSafe $script:Config.Tests.RetransmissionSampleSeconds 8))
    Wait-ForMinimumTcpSample -StartTime $tcpSampleStart -MinimumSeconds $minimumSampleSeconds

    $adapterStatsAfter = Invoke-CheckStep -Category "Network Adapter Error Counters" -Name "Get Ending Network Adapter Error Values" -Progress 82 -Action {
        return (Get-AdapterStatisticsSnapshot)
    }

    Invoke-CheckStep -Category "Network Adapter Error Counters" -Name "Analyze Adapter Errors and Discards" -Progress 85 -Action {
        if ($null -eq $adapterStatsBefore -or $null -eq $adapterStatsAfter) {
            Add-CheckResult -Category "Network Adapter Error Counters" -Check "Before/After Comparison" -Status "ERROR" -Message "The baseline or ending value is missing, so the error delta cannot be calculated." -Details "" | Out-Null
        }
        else {
            Compare-AdapterStatistics -Before $adapterStatsBefore -After $adapterStatsAfter -Adapters $networkSnapshot
        }
    } | Out-Null

    $tcpAfter = Invoke-CheckStep -Category "TCP Retransmissions" -Name "Get Ending TCP Retransmission Values" -Progress 89 -Action {
        return (Get-TcpCounterSnapshot)
    }

    Invoke-CheckStep -Category "TCP Retransmissions" -Name "Analyze TCP Retransmissions" -Progress 92 -Action {
        Compare-TcpCounters -Before $tcpBaseline -After $tcpAfter
    } | Out-Null

    $script:RunFinishedAt = Get-Date
    Set-UiProgress -Percent 96 -Text "Generate Reports"
    Write-UiLog -Status "INFO" -Text "Generating HTML, text, and JSON reports."

    try {
        $report = Save-Reports
        Set-UiProgress -Percent 100 -Text "Test Complete"
        Write-UiLog -Status "PASS" -Text ("Report generated: {0}" -f $report.Html)
        Update-OverallUi -Overall $report.Overall

        if ($script:GuiAvailable) {
            $script:ReportPathLabel.Text = "Report: $($report.Html)"
            $script:OpenReportButton.Enabled = $true
            $script:OpenFolderButton.Enabled = $true
        }

        return $report
    }
    catch {
        $details = Get-ExceptionDetails $_ -IncludeDiagnostics
        Write-UiLog -Status "ERROR" -Text "Report generation failed."
        $emergencyPath = Write-EmergencyReport -Title "Network Health Check Report Generation Failed" -ErrorDetails $details
        if ($script:GuiAvailable) {
            $message = "Report generation failed."
            if ($null -ne $emergencyPath) {
                $message += "`r`nEmergency error report written to: $emergencyPath"
            }
            [System.Windows.Forms.MessageBox]::Show($message, "Network Health Check Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        }
        throw
    }
    finally {
        $script:IsRunning = $false
        if ($script:GuiAvailable) {
            $script:StartButton.Enabled = $true
            $script:StartButton.Text = "Run Again"
        }
    }
}

function Start-ConsoleMode {
    try {
        $report = Run-AllChecks
        Write-Host ""
        Write-Host ("Overall result: {0}" -f $report.Overall.Text)
        Write-Host ("HTML report: {0}" -f $report.Html)
        Write-Host ("Text report: {0}" -f $report.Text)
        Write-Host ("JSON report: {0}" -f $report.Json)
        return 0
    }
    catch {
        $details = Get-ExceptionDetails $_ -IncludeDiagnostics
        Write-Host "An unhandled error occurred during the network health check." -ForegroundColor Red
        Write-Host $details
        $emergencyPath = Write-EmergencyReport -Title "Network Health Check Unhandled Error" -ErrorDetails $details
        if ($null -ne $emergencyPath) {
            Write-Host "Emergency error report: $emergencyPath"
        }
        return 1
    }
}

# -----------------------------------------------------------------------------
# User interface: Windows Forms GUI; the outer entry point falls back to console mode if unavailable.
# -----------------------------------------------------------------------------
function Initialize-Gui {
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        [System.Windows.Forms.Application]::EnableVisualStyles()
        $script:GuiAvailable = $true
    }
    catch {
        $script:GuiAvailable = $false
        [void]$script:StartupMessages.Add("The graphical interface could not be started. Console mode will be used. Error: $($_.Exception.Message)")
        return $false
    }

    try {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Network Health Check Tool $($script:ToolVersion)"
    $form.StartPosition = "CenterScreen"
    $form.Size = New-Object System.Drawing.Size(940, 700)
    $form.MinimumSize = New-Object System.Drawing.Size(780, 560)
    $form.MaximizeBox = $true
    $form.FormBorderStyle = "Sizable"

    try {
        $form.Font = New-Object System.Drawing.Font("Microsoft JhengHei UI", 10)
    }
    catch {
        $form.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    }

    $header = New-Object System.Windows.Forms.Label
    $header.Text = "Windows Network Health Check"
    $header.Font = New-Object System.Drawing.Font($form.Font.FontFamily, 18, [System.Drawing.FontStyle]::Bold)
    $header.AutoSize = $true
    $header.Location = New-Object System.Drawing.Point(20, 16)
    $form.Controls.Add($header)

    $subtitle = New-Object System.Windows.Forms.Label
    $subtitle.Text = "Automatically checks network adapters, IP settings, gateways, DNS, packet loss, service connectivity, adapter errors, and TCP retransmissions."
    $subtitle.AutoSize = $true
    $subtitle.Location = New-Object System.Drawing.Point(22, 54)
    $form.Controls.Add($subtitle)

    $overall = New-Object System.Windows.Forms.Label
    $overall.Text = "Result: Not started"
    $overall.Font = New-Object System.Drawing.Font($form.Font.FontFamily, 11, [System.Drawing.FontStyle]::Bold)
    $overall.AutoSize = $false
    $overall.Location = New-Object System.Drawing.Point(22, 84)
    $overall.Size = New-Object System.Drawing.Size(880, 28)
    $overall.Anchor = "Top,Left,Right"
    $form.Controls.Add($overall)

    $progressLabel = New-Object System.Windows.Forms.Label
    $progressLabel.Text = "Ready"
    $progressLabel.Location = New-Object System.Drawing.Point(22, 119)
    $progressLabel.Size = New-Object System.Drawing.Size(880, 22)
    $progressLabel.Anchor = "Top,Left,Right"
    $form.Controls.Add($progressLabel)

    $progress = New-Object System.Windows.Forms.ProgressBar
    $progress.Location = New-Object System.Drawing.Point(22, 143)
    $progress.Size = New-Object System.Drawing.Size(880, 22)
    $progress.Minimum = 0
    $progress.Maximum = 100
    $progress.Value = 0
    $progress.Anchor = "Top,Left,Right"
    $form.Controls.Add($progress)

    $log = New-Object System.Windows.Forms.RichTextBox
    $log.Location = New-Object System.Drawing.Point(22, 178)
    $log.Size = New-Object System.Drawing.Size(880, 390)
    $log.Anchor = "Top,Bottom,Left,Right"
    $log.ReadOnly = $true
    $log.DetectUrls = $false
    $log.BackColor = [System.Drawing.Color]::White
    $log.Font = New-Object System.Drawing.Font("Consolas", 9.5)
    $form.Controls.Add($log)

    $startButton = New-Object System.Windows.Forms.Button
    $startButton.Text = "Start Test"
    $startButton.Location = New-Object System.Drawing.Point(22, 584)
    $startButton.Size = New-Object System.Drawing.Size(120, 34)
    $startButton.Anchor = "Bottom,Left"
    $form.Controls.Add($startButton)

    $openReportButton = New-Object System.Windows.Forms.Button
    $openReportButton.Text = "Open Report"
    $openReportButton.Location = New-Object System.Drawing.Point(152, 584)
    $openReportButton.Size = New-Object System.Drawing.Size(120, 34)
    $openReportButton.Anchor = "Bottom,Left"
    $openReportButton.Enabled = $false
    $form.Controls.Add($openReportButton)

    $openFolderButton = New-Object System.Windows.Forms.Button
    $openFolderButton.Text = "Open Report Folder"
    $openFolderButton.Location = New-Object System.Drawing.Point(282, 584)
    $openFolderButton.Size = New-Object System.Drawing.Size(150, 34)
    $openFolderButton.Anchor = "Bottom,Left"
    $openFolderButton.Enabled = $false
    $form.Controls.Add($openFolderButton)

    $closeButton = New-Object System.Windows.Forms.Button
    $closeButton.Text = "Close"
    $closeButton.Location = New-Object System.Drawing.Point(782, 584)
    $closeButton.Size = New-Object System.Drawing.Size(120, 34)
    $closeButton.Anchor = "Bottom,Right"
    $form.Controls.Add($closeButton)

    $reportPathLabel = New-Object System.Windows.Forms.Label
    $reportPathLabel.Text = "Report has not been generated"
    $reportPathLabel.Location = New-Object System.Drawing.Point(22, 628)
    $reportPathLabel.Size = New-Object System.Drawing.Size(880, 24)
    $reportPathLabel.Anchor = "Bottom,Left,Right"
    $reportPathLabel.AutoEllipsis = $true
    $form.Controls.Add($reportPathLabel)

    $script:Form = $form
    $script:LogBox = $log
    $script:ProgressBar = $progress
    $script:ProgressLabel = $progressLabel
    $script:OverallLabel = $overall
    $script:StartButton = $startButton
    $script:OpenReportButton = $openReportButton
    $script:OpenFolderButton = $openFolderButton
    $script:ReportPathLabel = $reportPathLabel

    $startButton.Add_Click({
        try {
            [void](Run-AllChecks)
        }
        catch {
            $details = Get-ExceptionDetails $_ -IncludeDiagnostics
            Write-UiLog -Status "ERROR" -Text "An unhandled error occurred during the test."
            $emergencyPath = Write-EmergencyReport -Title "Network Health Check Unhandled Error" -ErrorDetails $details
            $message = "The test could not be completed."
            if ($null -ne $emergencyPath) {
                $message += "`r`nError report: $emergencyPath"
            }
            [System.Windows.Forms.MessageBox]::Show($message, "Network Health Check Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        }
        finally {
            $script:IsRunning = $false
            $script:StartButton.Enabled = $true
        }
    })

    $openReportButton.Add_Click({
        try {
            if ($null -ne $script:LastHtmlReport -and (Test-Path -LiteralPath $script:LastHtmlReport)) {
                Start-Process -FilePath $script:LastHtmlReport -ErrorAction Stop
            }
            else {
                throw "The HTML report was not found."
            }
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show("Unable to open the report: $($_.Exception.Message)", "Open Report Failed", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        }
    })

    $openFolderButton.Add_Click({
        try {
            if (Test-Path -LiteralPath $script:OutputDirectory) {
                Start-Process -FilePath "explorer.exe" -ArgumentList ('"{0}"' -f $script:OutputDirectory) -ErrorAction Stop
            }
            else {
                throw "The report folder was not found."
            }
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show("Unable to open the folder: $($_.Exception.Message)", "Open Folder Failed", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        }
    })

    $closeButton.Add_Click({
        if (-not $script:IsRunning) {
            $form.Close()
        }
    })

    $form.Add_FormClosing({
        param($sender, $eventArgs)
        if ($script:IsRunning) {
            $eventArgs.Cancel = $true
        }
    })

    $form.Add_Shown({
        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = 600
        $timer.Add_Tick({
            param($sender, $eventArgs)
            $sender.Stop()
            $sender.Dispose()
            $script:StartButton.PerformClick()
        })
        $timer.Start()
    })

    return $true
    }
    catch {
        $script:GuiAvailable = $false
        [void]$script:StartupMessages.Add("The graphical interface could not be started. Console mode will be used. Error: $($_.Exception.Message)")
        return $false
    }
}

# -------------------- Program entry point --------------------
$exitCode = 0

try {
    $script:Config = Load-Configuration -RequestedPath $ConfigPath
    Initialize-OutputDirectory

    if ($ConsoleOnly) {
        $exitCode = Start-ConsoleMode
    }
    else {
        if (Initialize-Gui) {
            [void]$script:Form.ShowDialog()
            $exitCode = 0
        }
        else {
            $exitCode = Start-ConsoleMode
        }
    }
}
catch {
    $details = Get-ExceptionDetails $_ -IncludeDiagnostics
    Write-Host "The network health check could not be started." -ForegroundColor Red
    Write-Host $details
    $emergencyPath = Write-EmergencyReport -Title "Network Health Check Startup Failure" -ErrorDetails $details

    if ($script:GuiAvailable) {
        $message = "The network health check could not be started."
        if ($null -ne $emergencyPath) {
            $message += "`r`nError report: $emergencyPath"
        }
        [System.Windows.Forms.MessageBox]::Show($message, "Network Health Check Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    }

    $exitCode = 1
}

exit $exitCode
