[CmdletBinding()]
param(
    [switch]$ConsoleOnly,
    [string]$ConfigPath = "",
    [switch]$Interactive,
    [switch]$ExpandDetails,
    [string[]]$PingTarget = @(),
    [string[]]$DnsName = @(),
    [string[]]$TcpTarget = @(),
    [string[]]$HttpUrl = @(),
    [int]$SampleSeconds = 0,
    [int]$PingCount = 0,
    [int]$TracerouteHops = 0,
    [switch]$NoTraceroute,
    [switch]$NoWifi
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

$script:ToolVersion = "1.2.0"
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
$script:BaseConfig = $null
$script:RunOptions = $null
$script:Interactive = $false
$script:OptionsPanel = $null
$script:OpenJsonButton = $null

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

    if (-not (Test-IsWholeNumber $Value)) {
        return $DefaultValue
    }

    try {
        return [int](ConvertTo-DoubleSafe $Value 0)
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

function Test-IsWholeNumber {
    param([object]$Value)

    if (-not (Test-IsNumericValue $Value)) {
        return $false
    }

    $converted = ConvertTo-DoubleSafe $Value 0
    return ([math]::Floor($converted) -eq $converted -and $converted -ge [int]::MinValue -and $converted -le [int]::MaxValue)
}

function Test-IsTrueFlag {
    param([object]$Value)

    return ($Value -is [bool] -and $Value)
}

function Test-IsVirtualAdapter {
    param(
        [string]$Description,
        [object]$VirtualFlag,
        [object]$HardwareFlag
    )

    if ($VirtualFlag -is [bool] -and $VirtualFlag) {
        return $true
    }
    if ($HardwareFlag -is [bool]) {
        return (-not $HardwareFlag)
    }
    if (-not [string]::IsNullOrWhiteSpace($Description) -and $Description -match 'virtual|vmware|virtualbox|hyper-v|vethernet|tap-|tunnel|loopback|wan miniport|npcap|wintun|wireguard|zerotier|tailscale|hamachi|docker|vpn|pseudo|isatap|teredo|6to4') {
        return $true
    }
    return $false
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
        [string]$Diagnostics = "",
        [string]$Tag = "",
        [string]$Scope = "Main"
    )

    $item = [pscustomobject][ordered]@{
        Time     = Get-Date
        Category = $Category
        Check    = $Check
        Status   = $Status
        Message  = $Message
        Details     = $Details
        Diagnostics = $Diagnostics
        Tag         = $Tag
        Scope       = $Scope
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
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [string]$Scope = "Main"
    )

    Set-UiProgress -Percent $Progress -Text $Name
    Write-UiLog -Status "INFO" -Text ("Starting: $Name")

    try {
        return (& $Action)
    }
    catch {
        $details = Get-ExceptionDetails $_
        $diagnostics = Get-ExceptionDiagnostics $_
        Add-CheckResult -Category $Category -Check $Name -Status "ERROR" -Message "This item could not be executed. The error has been recorded." -Details $details -Diagnostics $diagnostics -Tag "step-error" -Scope $Scope | Out-Null
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
        Checks = [pscustomobject][ordered]@{
            WifiRf           = $true
            RouteTable       = $true
            GatewayNeighbor  = $true
            ProxySettings    = $true
            Traceroute       = $true
            TracerouteHops   = 3
            DriverInfo       = $true
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

# v1.2: run options come from the entry point (launcher switches) or the IT options panel; the JSON config file is never written.
function Set-RunOptions {
    param([hashtable]$Overrides)

    if ($null -eq $Overrides) {
        $Overrides = @{}
    }
    $config = ($script:BaseConfig | ConvertTo-Json -Depth 10) | ConvertFrom-Json
    $extra = [ordered]@{ Ping = @(); Dns = @(); Tcp = @(); Http = @() }

    foreach ($value in @($Overrides["PingTarget"])) {
        if ([string]::IsNullOrWhiteSpace([string]$value)) { continue }
        $config.Tests.PingTargets = @($config.Tests.PingTargets) + [pscustomobject][ordered]@{ Name = "Extra ping"; Address = [string]$value; Required = $false }
        $extra.Ping += [string]$value
    }
    foreach ($value in @($Overrides["DnsName"])) {
        if ([string]::IsNullOrWhiteSpace([string]$value)) { continue }
        $config.Tests.DnsNames = @($config.Tests.DnsNames) + [pscustomobject][ordered]@{ Name = "Extra DNS"; Host = [string]$value; Required = $false }
        $extra.Dns += [string]$value
    }
    foreach ($value in @($Overrides["TcpTarget"])) {
        if ([string]::IsNullOrWhiteSpace([string]$value)) { continue }
        $parts = ([string]$value).Split(':')
        $port = 0
        if ($parts.Count -eq 2) { $port = ConvertTo-IntSafe $parts[1] 0 }
        if ($parts.Count -ne 2 -or $port -lt 1 -or $port -gt 65535 -or [string]::IsNullOrWhiteSpace($parts[0])) {
            [void]$script:StartupMessages.Add("Ignored extra TCP target '$value': expected host:port.")
            continue
        }
        $config.Tests.TcpTargets = @($config.Tests.TcpTargets) + [pscustomobject][ordered]@{ Name = "Extra TCP"; Host = $parts[0]; Port = $port; Required = $false; Group = "" }
        $extra.Tcp += [string]$value
    }
    foreach ($value in @($Overrides["HttpUrl"])) {
        if ([string]::IsNullOrWhiteSpace([string]$value)) { continue }
        $config.Tests.HttpTargets = @($config.Tests.HttpTargets) + [pscustomobject][ordered]@{ Name = "Extra URL"; Url = [string]$value; Required = $false; Group = "" }
        $extra.Http += [string]$value
    }

    if ((ConvertTo-IntSafe $Overrides["SampleSeconds"] 0) -gt 0) { $config.Tests.RetransmissionSampleSeconds = ConvertTo-IntSafe $Overrides["SampleSeconds"] 0 }
    if ((ConvertTo-IntSafe $Overrides["PingCount"] 0) -gt 0) { $config.Tests.PingCount = ConvertTo-IntSafe $Overrides["PingCount"] 0 }
    if ((ConvertTo-IntSafe $Overrides["TracerouteHops"] 0) -gt 0) { $config.Checks.TracerouteHops = ConvertTo-IntSafe $Overrides["TracerouteHops"] 0 }
    if ($Overrides["NoTraceroute"] -eq $true) { $config.Checks.Traceroute = $false }
    if ($Overrides["NoWifi"] -eq $true) { $config.Checks.WifiRf = $false }
    if ($Overrides["Checks"] -is [hashtable]) {
        foreach ($key in @($Overrides["Checks"].Keys)) {
            if ($null -ne $config.Checks.PSObject.Properties[[string]$key]) {
                $config.Checks.$key = [bool]$Overrides["Checks"][$key]
            }
        }
    }

    $entryPoint = "User"
    if ([string]$Overrides["EntryPoint"] -eq "IT") { $entryPoint = "IT" }
    $hops = ConvertTo-IntSafe $config.Checks.TracerouteHops 3
    if ($hops -lt 1 -or $hops -gt 10) { $hops = 3 }

    $script:Config = $config
    $script:RunOptions = [pscustomobject][ordered]@{
        EntryPoint     = $entryPoint
        ExpandDetails  = ($Overrides["ExpandDetails"] -eq $true)
        ExtraTargets   = [pscustomobject]$extra
        PingCount      = [math]::Max(1, (ConvertTo-IntSafe $config.Tests.PingCount 4))
        SampleSeconds  = [math]::Max(1, (ConvertTo-IntSafe $config.Tests.RetransmissionSampleSeconds 8))
        TracerouteHops = $hops
        ChecksEnabled  = [pscustomobject][ordered]@{
            WifiRf          = Test-IsTrueFlag $config.Checks.WifiRf
            RouteTable      = Test-IsTrueFlag $config.Checks.RouteTable
            GatewayNeighbor = Test-IsTrueFlag $config.Checks.GatewayNeighbor
            ProxySettings   = Test-IsTrueFlag $config.Checks.ProxySettings
            Traceroute      = Test-IsTrueFlag $config.Checks.Traceroute
            DriverInfo      = Test-IsTrueFlag $config.Checks.DriverInfo
        }
    }
    return $script:RunOptions
}

function Get-RunProfileText {
    $options = $script:RunOptions
    if ($null -eq $options) {
        return ""
    }

    $parts = @()
    if ($options.EntryPoint -eq "IT") { $parts += "IT entry" } else { $parts += "User entry" }
    $extras = @()
    foreach ($value in @($options.ExtraTargets.Ping)) { $extras += "ping $value" }
    foreach ($value in @($options.ExtraTargets.Dns)) { $extras += "dns $value" }
    foreach ($value in @($options.ExtraTargets.Tcp)) { $extras += "tcp $value" }
    foreach ($value in @($options.ExtraTargets.Http)) { $extras += "url $value" }
    if ($extras.Count -gt 0) { $parts += ("extra targets: {0}" -f ($extras -join ", ")) }
    $parts += ("ping count {0}" -f $options.PingCount)
    $parts += ("sample {0} s" -f $options.SampleSeconds)
    if ($options.ChecksEnabled.Traceroute) { $parts += ("traceroute {0} hops" -f $options.TracerouteHops) }
    $disabled = @()
    foreach ($property in $options.ChecksEnabled.PSObject.Properties) {
        if (-not $property.Value) { $disabled += $property.Name }
    }
    if ($disabled.Count -gt 0) { $parts += ("disabled: {0}" -f ($disabled -join ", ")) }
    return ($parts -join " | ")
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
            IsPhysical      = -not (Test-IsVirtualAdapter -Description ([string]$adapter.InterfaceDescription) -VirtualFlag (Get-PropertyValue $adapter "Virtual") -HardwareFlag (Get-PropertyValue $adapter "HardwareInterface"))
            MediaType       = ConvertTo-SafeString (Get-PropertyValue $adapter "PhysicalMediaType" "")
            DriverVersion   = ConvertTo-SafeString (Get-PropertyValue $adapter "DriverVersion" "")
            DriverDate      = ConvertTo-SafeString (Get-PropertyValue $adapter "DriverDate" "")
            DriverProvider  = ConvertTo-SafeString (Get-PropertyValue $adapter "DriverProvider" "")
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

        $physicalFlag = $null
        $mediaType = ""
        if ($null -ne $adapter) {
            $physicalFlag = Get-PropertyValue $adapter "PhysicalAdapter"
            $mediaType = ConvertTo-SafeString (Get-PropertyValue $adapter "AdapterType" "")
        }
        $isPhysical = -not (Test-IsVirtualAdapter -Description $description -VirtualFlag $null -HardwareFlag $physicalFlag)

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
            IsPhysical      = $isPhysical
            MediaType       = $mediaType
            DriverVersion   = ""
            DriverDate      = ""
            DriverProvider  = ""
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
            Add-CheckResult -Category "Network Adapter and IP" -Check "Data Source Fallback" -Status "WARN" -Message "Get-NetIPConfiguration could not retrieve data. CIM/WMI will be used instead." -Details (Get-ExceptionDetails $_) -Diagnostics (Get-ExceptionDiagnostics $_) -Tag "data-source" | Out-Null
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
        if ($null -ne $setting.Value -and -not (Test-IsWholeNumber $setting.Value)) {
            [void]$warnings.Add("$($setting.Name) must be a whole number in the supported range (current value: $($setting.Value)); the built-in default will be used.")
        }
        elseif ((ConvertTo-IntSafe $setting.Value 0) -le 0) {
            [void]$warnings.Add("$($setting.Name) should be greater than 0; the built-in minimum will be applied.")
        }
    }

    $checks = $script:Config.Checks
    foreach ($flagName in @("WifiRf", "RouteTable", "GatewayNeighbor", "ProxySettings", "Traceroute", "DriverInfo")) {
        $flagValue = Get-PropertyValue $checks $flagName
        if ($null -ne $flagValue -and -not ($flagValue -is [bool])) {
            [void]$warnings.Add("Checks.$flagName must be true or false (current value: $flagValue); the check is disabled.")
        }
    }
    $hopsValue = Get-PropertyValue $checks "TracerouteHops"
    if ($null -ne $hopsValue -and (-not (Test-IsWholeNumber $hopsValue) -or (ConvertTo-IntSafe $hopsValue 0) -lt 1 -or (ConvertTo-IntSafe $hopsValue 0) -gt 10)) {
        [void]$warnings.Add("Checks.TracerouteHops must be a whole number from 1 to 10 (current value: $hopsValue); the built-in default will be used.")
    }

    $countThresholdNames = @("TcpRetransmissionCriticalCount", "MinimumTcpSegmentsForRate", "AdapterErrorWarningDelta", "AdapterErrorCriticalDelta", "AdapterDiscardWarningDelta", "AdapterDiscardCriticalDelta")
    foreach ($thresholdName in @("PacketLossWarningPercent", "PacketLossCriticalPercent", "LatencyWarningMs", "LatencyCriticalMs", "TcpRetransmissionWarningPercent", "TcpRetransmissionCriticalPercent", "TcpRetransmissionCriticalCount", "MinimumTcpSegmentsForRate", "AdapterErrorWarningDelta", "AdapterErrorCriticalDelta", "AdapterDiscardWarningDelta", "AdapterDiscardCriticalDelta")) {
        $thresholdValue = Get-PropertyValue $thresholds $thresholdName
        if ($null -eq $thresholdValue) {
            continue
        }
        if (-not (Test-IsNumericValue $thresholdValue)) {
            [void]$warnings.Add("$thresholdName is not a number (current value: $thresholdValue); the built-in default will be used.")
        }
        elseif (($countThresholdNames -contains $thresholdName) -and -not (Test-IsWholeNumber $thresholdValue)) {
            [void]$warnings.Add("$thresholdName must be a whole number in the supported range (current value: $thresholdValue); the built-in default will be used.")
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
        Add-CheckResult -Category "Program Configuration" -Check "Configuration Validation" -Status "ERROR" -Message ("The configuration file contains {0} invalid value(s). The program will continue, but related results may not be meaningful." -f $errors.Count) -Details (@($errors) -join [Environment]::NewLine) -Tag "config" | Out-Null
    }
    elseif ($warnings.Count -eq 0) {
        Add-CheckResult -Category "Program Configuration" -Check "Configuration Validation" -Status "PASS" -Message "Configuration value format validation passed." -Details "" -Tag "config" | Out-Null
    }

    if ($warnings.Count -gt 0) {
        Add-CheckResult -Category "Program Configuration" -Check "Configuration Thresholds" -Status "WARN" -Message ("The configuration file contains {0} threshold value(s) that need attention." -f $warnings.Count) -Details (@($warnings) -join [Environment]::NewLine) -Tag "config" | Out-Null
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
        Add-CheckResult -Category "Network Adapter and IP" -Check "Usable Network Adapters" -Status "FAIL" -Message "No connected network adapter with an IP address was found." -Details "Check the network cable, Wi-Fi, airplane mode, adapter driver, and whether the adapter is disabled." -Tag "adapters" | Out-Null
        return
    }

    $physical = @($Adapters | Where-Object { $_.IsPhysical -eq $true })
    $virtual = @($Adapters | Where-Object { $_.IsPhysical -ne $true })
    $anyGateway = @($Adapters | Where-Object { @($_.Gateways).Count -gt 0 }).Count -gt 0
    $adapterSummary = "Found {0} connected network adapter(s): {1} physical, {2} virtual." -f $Adapters.Count, $physical.Count, $virtual.Count
    if ($physical.Count -gt 0) {
        Add-CheckResult -Category "Network Adapter and IP" -Check "Usable Network Adapters" -Status "PASS" -Message $adapterSummary -Details "" -Tag "adapters" | Out-Null
    }
    elseif ($anyGateway) {
        Add-CheckResult -Category "Network Adapter and IP" -Check "Usable Network Adapters" -Status "WARN" -Message "No physical network adapter is connected; connectivity is carried only by virtual adapters (VPN or virtualization)." -Details $adapterSummary -Tag "adapters" | Out-Null
    }
    else {
        Add-CheckResult -Category "Network Adapter and IP" -Check "Usable Network Adapters" -Status "FAIL" -Message "No physical network adapter is connected." -Details $adapterSummary -Tag "adapters" | Out-Null
    }

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
            ("Adapter type: {0}" -f $(if ($adapter.IsPhysical -eq $true) { "Physical" } else { "Virtual" })),
            ("Media: {0}" -f (ConvertTo-DisplayString $adapter.MediaType)),
            ("Driver: {0}" -f (ConvertTo-DisplayString (@($adapter.DriverVersion, $adapter.DriverDate, $adapter.DriverProvider) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }))),
            "Data source: $($adapter.Source)"
        ) -join [Environment]::NewLine

        $hasApipa = $false
        foreach ($ip in @($adapter.IPv4Addresses)) {
            if ([string]$ip -like "169.254.*") {
                $hasApipa = $true
                break
            }
        }

        if ($adapter.IsPhysical -ne $true) {
            Add-CheckResult -Category "Network Adapter and IP" -Check ("Adapter: {0}" -f $adapter.Name) -Status "INFO" -Message ("Virtual adapter (not counted as physical connectivity). IPv4: {0}" -f (ConvertTo-DisplayString $adapter.IPv4WithPrefix)) -Details $details -Tag "adapter" | Out-Null
        }
        elseif ($hasApipa) {
            Add-CheckResult -Category "Network Adapter and IP" -Check ("Adapter: {0}" -f $adapter.Name) -Status "FAIL" -Message "A 169.254.x.x automatic private IP address was detected, which usually means DHCP did not provide an address." -Details $details -Tag "adapter" | Out-Null
        }
        elseif (@($adapter.IPv4Addresses).Count -eq 0) {
            Add-CheckResult -Category "Network Adapter and IP" -Check ("Adapter: {0}" -f $adapter.Name) -Status "WARN" -Message "This adapter has no IPv4 address." -Details $details -Tag "adapter" | Out-Null
        }
        else {
            Add-CheckResult -Category "Network Adapter and IP" -Check ("Adapter: {0}" -f $adapter.Name) -Status "PASS" -Message ("Current IPv4: {0}" -f (ConvertTo-DisplayString $adapter.IPv4WithPrefix)) -Details $details -Tag "adapter" | Out-Null
        }
    }

    $gateways = @()
    foreach ($adapter in $Adapters) {
        $gateways += @($adapter.Gateways)
    }
    $gateways = @($gateways | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)

    if ($gateways.Count -eq 0) {
        Add-CheckResult -Category "Network Adapter and IP" -Check "Default Gateway" -Status "FAIL" -Message "No IPv4 default gateway was found. Access to other networks or the internet is usually unavailable." -Details "" -Tag "gateway-config" | Out-Null
    }
    else {
        Add-CheckResult -Category "Network Adapter and IP" -Check "Default Gateway" -Status "PASS" -Message ("Configured: {0}" -f ($gateways -join ", ")) -Details "" -Tag "gateway-config" | Out-Null
    }

    $dnsServers = @()
    foreach ($adapter in $Adapters) {
        $dnsServers += @($adapter.DnsServers)
    }
    $dnsServers = @($dnsServers | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)

    if ($dnsServers.Count -eq 0) {
        Add-CheckResult -Category "Network Adapter and IP" -Check "DNS Servers" -Status "FAIL" -Message "No DNS server configuration was found." -Details "Without DNS, connections by host name usually fail, although connections by IP address may still work." -Tag "dns-config" | Out-Null
    }
    else {
        Add-CheckResult -Category "Network Adapter and IP" -Check "DNS Servers" -Status "PASS" -Message ("Configured: {0}" -f ($dnsServers -join ", ")) -Details "" -Tag "dns-config" | Out-Null
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
        Add-CheckResult -Category "Company Standard Comparison" -Check "Standard Configuration" -Status "INFO" -Message "No company standard has been defined in the configuration file. The current settings can be displayed, but compliance cannot be determined." -Details "Ask IT staff to edit the Expected section of NetworkHealthCheck.config.json." -Tag "expected-standard" | Out-Null
        return
    }

    if ($Adapters.Count -eq 0) {
        Add-CheckResult -Category "Company Standard Comparison" -Check "Standard Configuration" -Status "FAIL" -Message "No usable network adapter is available, so company-standard comparison cannot be performed." -Details "" -Tag "expected-standard" | Out-Null
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
            Add-CheckResult -Category "Company Standard Comparison" -Check "IPv4 Address/Subnet" -Status "PASS" -Message ("Current IP $matchedIp matches the allowlist.") -Details ("Allowed IP addresses: {0}`r`nAllowed subnets: {1}" -f (ConvertTo-DisplayString $allowedIps), (ConvertTo-DisplayString $allowedCidrs)) -Tag "expected-standard" | Out-Null
        }
        else {
            Add-CheckResult -Category "Company Standard Comparison" -Check "IPv4 Address/Subnet" -Status "FAIL" -Message ("The current IP address does not match the allowlist: {0}" -f (ConvertTo-DisplayString $allIps)) -Details ("Allowed IP addresses: {0}`r`nAllowed subnets: {1}" -f (ConvertTo-DisplayString $allowedIps), (ConvertTo-DisplayString $allowedCidrs)) -Tag "expected-standard" | Out-Null
        }
    }

    if ($allowedPrefixes.Count -gt 0) {
        $prefixMatches = @($allPrefixes | Where-Object { $allowedPrefixes -contains [int]$_ })
        if ($prefixMatches.Count -gt 0) {
            Add-CheckResult -Category "Company Standard Comparison" -Check "Subnet Prefix" -Status "PASS" -Message ("Current prefix length matches: /{0}" -f (($prefixMatches | Select-Object -Unique) -join ", /")) -Details ("Allowed values: /{0}" -f ($allowedPrefixes -join ", /")) -Tag "expected-standard" | Out-Null
        }
        else {
            Add-CheckResult -Category "Company Standard Comparison" -Check "Subnet Prefix" -Status "FAIL" -Message ("Current prefix length does not match: /{0}" -f ($allPrefixes -join ", /")) -Details ("Allowed values: /{0}" -f ($allowedPrefixes -join ", /")) -Tag "expected-standard" | Out-Null
        }
    }

    if ($allowedGateways.Count -gt 0) {
        $gatewayMatches = @($allGateways | Where-Object { $allowedGateways -contains [string]$_ })
        if ($gatewayMatches.Count -gt 0) {
            Add-CheckResult -Category "Company Standard Comparison" -Check "Default Gateway" -Status "PASS" -Message ("Matched: {0}" -f ($gatewayMatches -join ", ")) -Details ("Allowed values: {0}" -f ($allowedGateways -join ", ")) -Tag "expected-standard" | Out-Null
        }
        else {
            Add-CheckResult -Category "Company Standard Comparison" -Check "Default Gateway" -Status "FAIL" -Message ("Current gateway does not match: {0}" -f (ConvertTo-DisplayString $allGateways)) -Details ("Allowed values: {0}" -f ($allowedGateways -join ", ")) -Tag "expected-standard" | Out-Null
        }
    }

    if ($requiredDns.Count -gt 0) {
        $missingDns = @($requiredDns | Where-Object { $allDns -notcontains [string]$_ })
        if ($missingDns.Count -eq 0) {
            Add-CheckResult -Category "Company Standard Comparison" -Check "DNS Servers" -Status "PASS" -Message "All required DNS servers are present." -Details ("Required values: {0}`r`nCurrent values: {1}" -f ($requiredDns -join ", "), (ConvertTo-DisplayString $allDns)) -Tag "expected-standard" | Out-Null
        }
        else {
            Add-CheckResult -Category "Company Standard Comparison" -Check "DNS Servers" -Status "FAIL" -Message ("Missing required DNS servers: {0}" -f ($missingDns -join ", ")) -Details ("Required values: {0}`r`nCurrent values: {1}" -f ($requiredDns -join ", "), (ConvertTo-DisplayString $allDns)) -Tag "expected-standard" | Out-Null
        }
    }

    if ($hasValidDhcpRule) {
        $expectedBool = [bool]$expectedDhcp
        if ($allDhcp.Count -eq 0) {
            Add-CheckResult -Category "Company Standard Comparison" -Check "DHCP Mode" -Status "ERROR" -Message "The current DHCP state could not be retrieved." -Details ("Expected value: {0}" -f $(if ($expectedBool) { "Enabled" } else { "Disabled" })) -Tag "expected-standard" | Out-Null
        }
        else {
            $mismatches = @($allDhcp | Where-Object { [bool]$_ -ne $expectedBool })
            if ($mismatches.Count -eq 0) {
                Add-CheckResult -Category "Company Standard Comparison" -Check "DHCP Mode" -Status "PASS" -Message ("Matches expected value: {0}" -f $(if ($expectedBool) { "Enabled" } else { "Disabled (static IP)" })) -Details "" -Tag "expected-standard" | Out-Null
            }
            else {
                Add-CheckResult -Category "Company Standard Comparison" -Check "DHCP Mode" -Status "FAIL" -Message ("The DHCP mode does not match. Expected: {0}" -f $(if ($expectedBool) { "Enabled" } else { "Disabled (static IP)" })) -Details ("Current state: {0}" -f (($allDhcp | ForEach-Object { if ($_){"Enabled"}else{"Disabled"} }) -join ", ")) -Tag "expected-standard" | Out-Null
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
        $pingTag = "ping-target"
        if ($address -eq "AUTO_GATEWAY") { $pingTag = "ping-gateway" }
        $required = [bool](Get-PropertyValue $targetConfig "Required" $false)
        $targets = @(Resolve-PingTargets -Address $address -PrimaryAdapters $PrimaryAdapters)

        if ($targets.Count -eq 0) {
            $status = if ($required) { "FAIL" } else { "WARN" }
            $noTargetDetail = "Configured value: $address"
            if ($address -eq "AUTO_GATEWAY") {
                $noTargetDetail = "Configured value: AUTO_GATEWAY - this placeholder resolves to the current IPv4 default gateway, and none exists right now (usually the local link is down)."
            }
            Add-CheckResult -Category "Latency and Packet Loss" -Check $name -Status $status -Message "No testable target was found." -Details ($noTargetDetail + [Environment]::NewLine + ("Method: .NET Ping — {0} ICMP echo requests, timeout {1} ms." -f $count, $timeout) + [Environment]::NewLine + "Manual check: ping -n $count <target-ip>") -Tag $pingTag | Out-Null
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
                Add-CheckResult -Category "Latency and Packet Loss" -Check ("{0}: {1}" -f $name, $target) -Status $status -Message $message -Details $details -Tag $pingTag | Out-Null
            }
            catch {
                $status = if ($required) { "ERROR" } else { "INFO" }
                Add-CheckResult -Category "Latency and Packet Loss" -Check ("{0}: {1}" -f $name, $target) -Status $status -Message "The ping test could not be performed." -Details (Get-ExceptionDetails $_) -Diagnostics (Get-ExceptionDiagnostics $_) -Tag $pingTag | Out-Null
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
                Add-CheckResult -Category "DNS" -Check $name -Status "PASS" -Message ("{0} resolved to {1} ({2} ms)." -f $hostName, ($result.Addresses -join ", "), $result.ElapsedMs) -Details ($methodText + [Environment]::NewLine + "Manual check: nslookup $hostName") -Tag "dns" | Out-Null
            }
            else {
                $status = if ($required) { "FAIL" } else { "WARN" }
                Add-CheckResult -Category "DNS" -Check $name -Status $status -Message ("$hostName returned no IP address.") -Details ($methodText + [Environment]::NewLine + "Manual check: nslookup $hostName") -Tag "dns" | Out-Null
            }
        }
        catch {
            $status = if ($required) { "FAIL" } else { "WARN" }
            Add-CheckResult -Category "DNS" -Check $name -Status $status -Message ("Unable to resolve $hostName.") -Details ((Get-ExceptionDetails $_) + [Environment]::NewLine + $methodText + [Environment]::NewLine + "Manual check: nslookup $hostName") -Diagnostics (Get-ExceptionDiagnostics $_) -Tag "dns" | Out-Null
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
        Add-CheckResult -Category "Connectivity" -Check ("Group: $GroupName") -Status $status -Message "This group has no executable test items." -Details "Check the Group names and test targets in the configuration file." -Tag "connectivity-group" | Out-Null
        return
    }

    $successful = @($entries | Where-Object { $_.Success })
    if ($successful.Count -gt 0) {
        $names = @($successful | ForEach-Object { $_.Name })
        Add-CheckResult -Category "Connectivity" -Check ("Group: $GroupName") -Status "PASS" -Message ("At least one connectivity method succeeded: {0}" -f ($names -join ", ")) -Details (("{0}/{1} item(s) succeeded." -f $successful.Count, $entries.Count) + [Environment]::NewLine + "Method: the group passes if at least one member connectivity test succeeds.") -Tag "connectivity-group" | Out-Null
    }
    else {
        $status = if ($Required) { "FAIL" } else { "WARN" }
        $details = (@($entries | ForEach-Object { "{0}: {1}" -f $_.Name, $_.Error }) + "Method: the group passes if at least one member connectivity test succeeds.") -join [Environment]::NewLine
        Add-CheckResult -Category "Connectivity" -Check ("Group: $GroupName") -Status $status -Message "All connectivity methods failed." -Details $details -Tag "connectivity-group" | Out-Null
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
                Add-CheckResult -Category "TCP Connection" -Check $name -Status "ERROR" -Message "The configured host or port is invalid." -Details ("Host=$hostName, Port=$port") -Tag "tcp" | Out-Null
            }
            continue
        }

        $result = Invoke-TcpConnectionTest -HostName $hostName -Port $port -TimeoutMs $tcpTimeout
        if ($result.Success) {
            Add-CheckResult -Category "TCP Connection" -Check $name -Status "PASS" -Message ("Connected to {0}:{1} in {2} ms." -f $hostName, $port, $result.ElapsedMs) -Details ($tcpMethod + [Environment]::NewLine + "Manual check: Test-NetConnection $hostName -Port $port") -Tag "tcp" | Out-Null
        }
        else {
            $status = if ($required) { "FAIL" } else { "INFO" }
            Add-CheckResult -Category "TCP Connection" -Check $name -Status $status -Message ("Unable to connect to {0}:{1}." -f $hostName, $port) -Details ($result.Error + [Environment]::NewLine + $tcpMethod + [Environment]::NewLine + "Manual check: Test-NetConnection $hostName -Port $port") -Tag "tcp" | Out-Null
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
                Add-CheckResult -Category "HTTP/HTTPS" -Check $name -Status "ERROR" -Message "The configured URL is blank." -Details "" -Tag "http" | Out-Null
            }
            continue
        }

        $result = Invoke-HttpConnectionTest -Url $url -TimeoutMs $httpTimeout
        if ($result.Success) {
            Add-CheckResult -Category "HTTP/HTTPS" -Check $name -Status "PASS" -Message ("HTTP {0}, elapsed {1} ms." -f $result.StatusCode, $result.ElapsedMs) -Details ("Original URL: {0}`r`nFinal URL: {1}`r`nStatus: {2}`r`n{3}`r`nManual check: Invoke-WebRequest {0} -UseBasicParsing" -f $url, $result.FinalUrl, $result.StatusText, $httpMethod) -Tag "http" | Out-Null
        }
        else {
            $status = if ($required) { "FAIL" } else { "INFO" }
            Add-CheckResult -Category "HTTP/HTTPS" -Check $name -Status $status -Message ("Unable to connect: $url") -Details ($result.Error + [Environment]::NewLine + $httpMethod + [Environment]::NewLine + "Manual check: Invoke-WebRequest $url -UseBasicParsing") -Tag "http" | Out-Null
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
    $adapterByName = @{}
    foreach ($adapterItem in @($Adapters)) {
        if ($null -ne $adapterItem -and -not [string]::IsNullOrWhiteSpace([string]$adapterItem.Name)) {
            $adapterByName[[string]$adapterItem.Name] = $adapterItem
        }
    }
    if ($adapterNames.Count -eq 0) {
        $adapterNames = @($After.Keys)
    }

    foreach ($name in $adapterNames) {
        if (-not $Before.ContainsKey($name) -or -not $After.ContainsKey($name)) {
            Add-CheckResult -Category "Network Adapter Error Counters" -Check $name -Status "INFO" -Message "Complete before-and-after comparison data could not be retrieved." -Details "The adapter may have switched, reconnected, or changed name during the test." -Tag "adapter-errors" | Out-Null
            continue
        }

        $beforeItem = $Before[$name]
        $afterItem = $After[$name]
        $isVirtualAdapter = $false
        if ($adapterByName.ContainsKey($name)) {
            $isVirtualAdapter = ($adapterByName[$name].IsPhysical -ne $true)
        }

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
            $resetStatus = "WARN"
            if ($isVirtualAdapter) { $resetStatus = "INFO" }
            Add-CheckResult -Category "Network Adapter Error Counters" -Check $name -Status $resetStatus -Message "The adapter counters were reset during the test, possibly because the adapter reconnected or restarted; a reliable delta cannot be calculated." -Details $resetDetails -Tag "adapter-errors" | Out-Null
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
        $trafficDelta = ([double]$afterItem.ReceivedBytes - [double]$beforeItem.ReceivedBytes) + ([double]$afterItem.SentBytes - [double]$beforeItem.SentBytes)
        if ($isVirtualAdapter) {
            $status = "INFO"
            $message = "Virtual adapter: errors increased by {0} and discards by {1} (informational)." -f $errorDelta, $discardDelta
        }
        elseif ($status -eq "PASS" -and $trafficDelta -le 0) {
            $status = "INFO"
            $message = "No traffic passed through this adapter during the sample, so its error counters cannot testify (0 errors is vacuous)."
        }
        $details = @(
            "Receive error delta: $rxErrorDelta (cumulative $($afterItem.ReceivedPacketErrors))",
            "Send error delta: $txErrorDelta (cumulative $($afterItem.OutboundPacketErrors))",
            "Receive discard delta: $rxDiscardDelta (cumulative $($afterItem.ReceivedDiscardedPackets))",
            "Send discard delta: $txDiscardDelta (cumulative $($afterItem.OutboundDiscardedPackets))",
            "Cumulative received bytes: $($afterItem.ReceivedBytes)",
            "Cumulative sent bytes: $($afterItem.SentBytes)",
            ("Traffic during sample: {0} bytes" -f [uint64][math]::Max(0, $trafficDelta)),
            "Method: Get-NetAdapterStatistics sampled before and after the test; deltas shown.",
            "Manual check: Get-NetAdapterStatistics -Name '$name'"
        ) -join [Environment]::NewLine

        Add-CheckResult -Category "Network Adapter Error Counters" -Check $name -Status $status -Message $message -Details $details -Tag "adapter-errors" | Out-Null
    }
}

# v1.2 IT diagnostics: informational data for IT (never changes the overall result), shown in the collapsed IT section.
function ConvertFrom-NetshWlanOutput {
    param([string[]]$Lines)

    $pairs = New-Object System.Collections.ArrayList
    foreach ($rawLine in @($Lines)) {
        $line = [string]$rawLine
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $separator = $line.IndexOf(':')
        $wide = $line.IndexOf([char]0xFF1A)
        if ($separator -lt 1 -or ($wide -ge 1 -and $wide -lt $separator)) { $separator = $wide }
        if ($separator -lt 1) { continue }
        [void]$pairs.Add([pscustomobject]@{ Label = $line.Substring(0, $separator).Trim(); Value = $line.Substring($separator + 1).Trim() })
    }

    $guidPattern = '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'
    $macPattern = '^[0-9a-fA-F]{2}([:-][0-9a-fA-F]{2}){5}$'
    $starts = @()
    for ($i = 0; $i -lt $pairs.Count; $i++) {
        if ($pairs[$i].Value -match $guidPattern -and $i -ge 2) { $starts += ($i - 2) }
    }

    $interfaces = New-Object System.Collections.ArrayList
    for ($b = 0; $b -lt $starts.Count; $b++) {
        $from = $starts[$b]
        $to = $pairs.Count - 1
        if ($b + 1 -lt $starts.Count) { $to = $starts[$b + 1] - 1 }
        $block = @($pairs[$from..$to])

        # Values are matched by shape (MAC, percentage, 802.11x, GHz, plain numbers) because labels are localized
        # and their order differs between Windows 10 and Windows 11 builds.
        $macs = @($block | Where-Object { $_.Value -match $macPattern })
        $bssidIndex = -1
        for ($k = 0; $k -lt $block.Count; $k++) {
            if ($block[$k].Value -match $macPattern -and $macs.Count -ge 2 -and $block[$k].Value -eq $macs[1].Value) { $bssidIndex = $k; break }
        }
        $ssid = ""
        if ($bssidIndex -gt 0) { $ssid = $block[$bssidIndex - 1].Value }

        $signalIndex = -1
        $signal = $null
        $rssiIndex = -1
        $rssi = $null
        $radio = ""
        $band = ""
        for ($k = 0; $k -lt $block.Count; $k++) {
            $value = $block[$k].Value
            if ($signalIndex -lt 0 -and $value -match '^\d{1,3}\s*%$') { $signalIndex = $k; $signal = ConvertTo-IntSafe ($value -replace '[^0-9]', '') 0 }
            elseif ($rssiIndex -lt 0 -and $value -match '^-\d{1,3}$') { $rssiIndex = $k; $rssi = ConvertTo-IntSafe $value 0 }
            elseif ([string]::IsNullOrWhiteSpace($radio) -and $value -match '^802\.11') { $radio = $value }
            elseif ([string]::IsNullOrWhiteSpace($band) -and $value -match '^\d(\.\d)?\s*GHz$') { $band = $value }
        }

        $channel = $null
        $receive = $null
        $transmit = $null
        $profile = ""
        if ($bssidIndex -ge 0) {
            $upper = $block.Count
            if ($signalIndex -ge 0) { $upper = $signalIndex }
            $numeric = @()
            for ($k = $bssidIndex + 1; $k -lt $upper; $k++) {
                if ($block[$k].Value -match '^\d+(\.\d+)?$') { $numeric += $block[$k].Value }
            }
            if ($numeric.Count -ge 2) {
                $receive = ConvertTo-DoubleSafe $numeric[$numeric.Count - 2] 0
                $transmit = ConvertTo-DoubleSafe $numeric[$numeric.Count - 1] 0
            }
            if ($numeric.Count -ge 3 -or $numeric.Count -eq 1) { $channel = ConvertTo-IntSafe $numeric[0] 0 }
            if ([string]::IsNullOrWhiteSpace($band) -and $null -ne $channel) {
                if ($channel -le 14) { $band = "2.4 GHz" } else { $band = "5 GHz" }
            }
            $profileFrom = [math]::Max($signalIndex, $rssiIndex) + 1
            if ($profileFrom -gt 0) {
                for ($k = $profileFrom; $k -lt $block.Count; $k++) {
                    $value = $block[$k].Value
                    if ($value -match '^-?\d+(\.\d+)?$' -or $value -match '^\d{1,3}\s*%$') { continue }
                    $profile = $value
                    break
                }
            }
        }

        [void]$interfaces.Add([pscustomobject][ordered]@{
            Name             = $block[0].Value
            Description      = $block[1].Value
            PhysicalAddress  = $(if ($macs.Count -ge 1) { $macs[0].Value } else { "" })
            Connected        = ($bssidIndex -ge 0)
            Ssid             = $ssid
            Bssid            = $(if ($bssidIndex -ge 0) { $block[$bssidIndex].Value } else { "" })
            RadioType        = $radio
            Band             = $band
            Channel          = $channel
            ReceiveRateMbps  = $receive
            TransmitRateMbps = $transmit
            SignalPercent    = $signal
            Rssi             = $rssi
            Profile          = $profile
        })
    }

    return @($interfaces)
}

function Add-WifiRfResult {
    if (-not (Test-IsTrueFlag $script:Config.Checks.WifiRf)) { return }

    $netsh = Join-Path $env:SystemRoot "System32\netsh.exe"
    if (-not (Test-Path -LiteralPath $netsh)) {
        Add-CheckResult -Category "IT Diagnostics" -Check "Wi-Fi radio" -Status "INFO" -Message "netsh.exe was not found; Wi-Fi radio data is unavailable." -Details "" -Tag "wifi" -Scope "IT" | Out-Null
        return
    }

    $lines = @()
    try {
        $lines = @(& $netsh wlan show interfaces 2>&1 | ForEach-Object { [string]$_ })
    }
    catch {
        Add-CheckResult -Category "IT Diagnostics" -Check "Wi-Fi radio" -Status "ERROR" -Message "Wi-Fi radio data could not be read." -Details (Get-ExceptionDetails $_) -Diagnostics (Get-ExceptionDiagnostics $_) -Tag "wifi" -Scope "IT" | Out-Null
        return
    }

    $interfaces = @(ConvertFrom-NetshWlanOutput -Lines $lines)
    $connected = @($interfaces | Where-Object { $_.Connected })
    if ($connected.Count -eq 0) {
        Add-CheckResult -Category "IT Diagnostics" -Check "Wi-Fi radio" -Status "INFO" -Message "No connected Wi-Fi interface (wired connection, Wi-Fi off, or no wireless adapter)." -Details (("Wireless interfaces reported by netsh: {0}" -f $interfaces.Count) + [Environment]::NewLine + "Manual check: netsh wlan show interfaces") -Tag "wifi" -Scope "IT" | Out-Null
        return
    }

    foreach ($wifi in $connected) {
        $rssi = "?"
        if ($null -ne $wifi.SignalPercent) { $rssi = [math]::Round(($wifi.SignalPercent / 2.0) - 100, 0) }
        if ($null -ne $wifi.Rssi) { $rssi = $wifi.Rssi }
        $message = "SSID {0}: signal {1}% (about {2} dBm), {3} {4}, channel {5}, {6}/{7} Mbps." -f $wifi.Ssid, (ConvertTo-DisplayString $wifi.SignalPercent), $rssi, $wifi.RadioType, $wifi.Band, (ConvertTo-DisplayString $wifi.Channel), (ConvertTo-DisplayString $wifi.ReceiveRateMbps), (ConvertTo-DisplayString $wifi.TransmitRateMbps)
        $details = @(
            ("Interface: {0}" -f $wifi.Name),
            ("BSSID: {0}" -f (ConvertTo-DisplayString $wifi.Bssid)),
            ("Radio: {0}, band {1}, channel {2}" -f $wifi.RadioType, (ConvertTo-DisplayString $wifi.Band), (ConvertTo-DisplayString $wifi.Channel)),
            ("Rates: receive {0} Mbps, transmit {1} Mbps" -f (ConvertTo-DisplayString $wifi.ReceiveRateMbps), (ConvertTo-DisplayString $wifi.TransmitRateMbps)),
            ("Signal: {0}% (about {1} dBm)" -f (ConvertTo-DisplayString $wifi.SignalPercent), $rssi),
            ("Profile: {0}" -f (ConvertTo-DisplayString $wifi.Profile)),
            "Method: netsh wlan show interfaces, parsed by field position because labels are localized; dBm is estimated from the signal percentage.",
            "Manual check: netsh wlan show interfaces",
            "Note: the client-side view is weaker evidence than the access point's client table."
        ) -join [Environment]::NewLine
        Add-CheckResult -Category "IT Diagnostics" -Check "Wi-Fi radio" -Status "INFO" -Message $message -Details $details -Tag "wifi" -Scope "IT" | Out-Null
    }
}

function Sort-DefaultRoutes {
    param([object[]]$Routes)

    return @($Routes | Sort-Object @{ Expression = { (ConvertTo-IntSafe $_.RouteMetric 0) + (ConvertTo-IntSafe $_.InterfaceMetric 0) } }, @{ Expression = { ConvertTo-IntSafe $_.RouteMetric 0 } })
}

function Add-RouteTableResult {
    if (-not (Test-IsTrueFlag $script:Config.Checks.RouteTable)) { return }

    if (-not (Get-Command Get-NetRoute -ErrorAction SilentlyContinue)) {
        Add-CheckResult -Category "IT Diagnostics" -Check "IPv4 default routes" -Status "INFO" -Message "Get-NetRoute is not available; the route table was not read." -Details "Manual check: route print -4" -Tag "routes" -Scope "IT" | Out-Null
        return
    }

    $routes = @()
    try {
        $routes = @(Sort-DefaultRoutes -Routes @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix "0.0.0.0/0" -ErrorAction Stop))
    }
    catch {
        Add-CheckResult -Category "IT Diagnostics" -Check "IPv4 default routes" -Status "ERROR" -Message "The route table could not be read." -Details ((Get-ExceptionDetails $_) + [Environment]::NewLine + "Manual check: route print -4") -Diagnostics (Get-ExceptionDiagnostics $_) -Tag "routes" -Scope "IT" | Out-Null
        return
    }

    if ($routes.Count -eq 0) {
        Add-CheckResult -Category "IT Diagnostics" -Check "IPv4 default routes" -Status "INFO" -Message "No IPv4 default route exists." -Details ("Method: Get-NetRoute -AddressFamily IPv4 -DestinationPrefix 0.0.0.0/0" + [Environment]::NewLine + "Manual check: route print -4") -Tag "routes" -Scope "IT" | Out-Null
        return
    }

    $lines = @()
    foreach ($route in $routes) {
        $lines += ("{0} via {1} (ifIndex {2}), route metric {3}, interface metric {4}, effective metric {5}, {6}" -f $route.NextHop, $route.InterfaceAlias, $route.InterfaceIndex, $route.RouteMetric, $route.InterfaceMetric, ((ConvertTo-IntSafe $route.RouteMetric 0) + (ConvertTo-IntSafe $route.InterfaceMetric 0)), $route.State)
    }
    $interfaceCount = @($routes | ForEach-Object { [string]$_.InterfaceIndex } | Select-Object -Unique).Count
    if ($interfaceCount -gt 1) { $lines += "Multiple default routes: Windows prefers the lowest combined metric; check for VPN split-tunnel or a second connection." }
    $lines += "Method: Get-NetRoute -AddressFamily IPv4 -DestinationPrefix 0.0.0.0/0"
    $lines += "Manual check: route print -4"
    $message = "{0} IPv4 default route(s); preferred: {1} via {2}." -f $routes.Count, $routes[0].NextHop, $routes[0].InterfaceAlias
    Add-CheckResult -Category "IT Diagnostics" -Check "IPv4 default routes" -Status "INFO" -Message $message -Details ($lines -join [Environment]::NewLine) -Tag "routes" -Scope "IT" | Out-Null
}

function Add-GatewayNeighborResult {
    param([object[]]$PrimaryAdapters)

    if (-not (Test-IsTrueFlag $script:Config.Checks.GatewayNeighbor)) { return }

    $gateways = @(Resolve-PingTargets -Address "AUTO_GATEWAY" -PrimaryAdapters $PrimaryAdapters)
    if ($gateways.Count -eq 0) {
        Add-CheckResult -Category "IT Diagnostics" -Check "Gateway neighbor (ARP)" -Status "INFO" -Message "No IPv4 default gateway to look up." -Details "Manual check: arp -a" -Tag "gateway-neighbor" -Scope "IT" | Out-Null
        return
    }

    foreach ($gateway in $gateways) {
        $state = "(unknown)"
        $mac = ""
        try {
            if (Get-Command Get-NetNeighbor -ErrorAction SilentlyContinue) {
                $neighbor = Get-NetNeighbor -IPAddress ([string]$gateway) -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($null -ne $neighbor) {
                    $state = [string]$neighbor.State
                    $mac = [string]$neighbor.LinkLayerAddress
                }
            }
            else {
                $arpLines = @(& arp -a 2>&1 | ForEach-Object { [string]$_ } | Where-Object { $_ -match ('\s' + [regex]::Escape([string]$gateway) + '\s') })
                if ($arpLines.Count -gt 0 -and $arpLines[0] -match '([0-9a-fA-F]{2}[-:]){5}[0-9a-fA-F]{2}') {
                    $mac = $matches[0]
                    $state = "arp"
                }
            }
        }
        catch {
            Add-CheckResult -Category "IT Diagnostics" -Check "Gateway neighbor (ARP)" -Status "ERROR" -Message "The neighbor table could not be read." -Details ((Get-ExceptionDetails $_) + [Environment]::NewLine + "Manual check: arp -a") -Diagnostics (Get-ExceptionDiagnostics $_) -Tag "gateway-neighbor" -Scope "IT" | Out-Null
            continue
        }

        $lines = @()
        if ([string]::IsNullOrWhiteSpace($mac) -or $mac -match '^(00[-:]){5}00$' -or $state -match 'Unreachable|Incomplete') { $lines += "The gateway has no resolved MAC address; Layer 2 to the router may be broken (the gateway ping above is the authoritative test)." }
        $lines += "Method: Get-NetNeighbor -AddressFamily IPv4 (fallback: arp -a)"
        $lines += "Manual check: arp -a"
        $message = "Gateway {0}: neighbor state {1}, MAC {2}." -f $gateway, $state, (ConvertTo-DisplayString $mac)
        Add-CheckResult -Category "IT Diagnostics" -Check "Gateway neighbor (ARP)" -Status "INFO" -Message $message -Details ($lines -join [Environment]::NewLine) -Tag "gateway-neighbor" -Scope "IT" | Out-Null
    }
}

function Add-ProxySettingsResult {
    if (-not (Test-IsTrueFlag $script:Config.Checks.ProxySettings)) { return }

    $lines = @()
    $userProxy = "off"
    try {
        $registry = Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" -ErrorAction Stop
        $enabled = ((ConvertTo-IntSafe (Get-PropertyValue $registry "ProxyEnable" 0) 0) -eq 1)
        $server = ConvertTo-SafeString (Get-PropertyValue $registry "ProxyServer" "")
        $pac = ConvertTo-SafeString (Get-PropertyValue $registry "AutoConfigURL" "")
        if ($enabled -and -not [string]::IsNullOrWhiteSpace($server)) { $userProxy = $server }
        elseif (-not [string]::IsNullOrWhiteSpace($pac)) { $userProxy = "PAC " + $pac }
        $lines += ("User proxy enabled: {0}, server: {1}, PAC URL: {2}" -f $enabled, (ConvertTo-DisplayString $server), (ConvertTo-DisplayString $pac))
    }
    catch {
        $lines += ("User proxy settings could not be read: {0}" -f $_.Exception.Message)
    }

    $probeUrl = "https://www.microsoft.com/"
    foreach ($target in @($script:Config.Tests.HttpTargets)) {
        $candidate = ConvertTo-SafeString (Get-PropertyValue $target "Url" "")
        if (-not [string]::IsNullOrWhiteSpace($candidate)) { $probeUrl = $candidate; break }
    }
    $effective = "direct"
    try {
        $probe = New-Object System.Uri($probeUrl)
        $resolved = [System.Net.WebRequest]::GetSystemWebProxy().GetProxy($probe)
        if ($null -ne $resolved -and $resolved.AbsoluteUri -ne $probe.AbsoluteUri) { $effective = $resolved.AbsoluteUri }
    }
    catch {
        $effective = "(unknown)"
    }
    $lines += ("Effective proxy for {0}: {1}" -f $probeUrl, $effective)

    try {
        $winhttp = @(& netsh winhttp show proxy 2>&1 | ForEach-Object { ([string]$_).Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($winhttp.Count -gt 0) { $lines += ("WinHTTP: {0}" -f (($winhttp | Select-Object -First 3) -join " / ")) }
    }
    catch {
        # WinHTTP information is optional.
    }
    $lines += "A proxy explains cases where TCP to port 443 passes but HTTPS fails."
    $lines += "Method: HKCU Internet Settings registry values, WebRequest.GetSystemWebProxy, netsh winhttp show proxy"
    $lines += "Manual check: netsh winhttp show proxy"
    Add-CheckResult -Category "IT Diagnostics" -Check "Proxy settings" -Status "INFO" -Message ("User proxy: {0}; effective proxy for HTTPS: {1}." -f $userProxy, $effective) -Details ($lines -join [Environment]::NewLine) -Tag "proxy" -Scope "IT" | Out-Null
}

function Invoke-TraceRoute {
    param(
        [string]$Target,
        [int]$MaxHops,
        [int]$TimeoutMs
    )

    $hops = New-Object System.Collections.ArrayList
    $ping = New-Object System.Net.NetworkInformation.Ping
    $buffer = New-Object byte[] 32
    try {
        for ($ttl = 1; $ttl -le $MaxHops; $ttl++) {
            $options = New-Object System.Net.NetworkInformation.PingOptions($ttl, $true)
            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            $address = "*"
            $status = "TimedOut"
            $reached = $false
            try {
                $reply = $ping.Send($Target, $TimeoutMs, $buffer, $options)
                $stopwatch.Stop()
                $status = [string]$reply.Status
                if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::TtlExpired -or $reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                    $address = [string]$reply.Address
                }
                if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) { $reached = $true }
            }
            catch {
                $stopwatch.Stop()
                $status = $_.Exception.Message
            }
            [void]$hops.Add([pscustomobject][ordered]@{
                Hop       = $ttl
                Address   = $address
                Status    = $status
                ElapsedMs = [math]::Round($stopwatch.Elapsed.TotalMilliseconds, 0)
                Reached   = $reached
            })
            if ($reached) { break }
            if ($script:GuiAvailable) {
                [System.Windows.Forms.Application]::DoEvents()
            }
        }
    }
    finally {
        $ping.Dispose()
    }
    return @($hops)
}

function Add-TracerouteResult {
    if (-not (Test-IsTrueFlag $script:Config.Checks.Traceroute)) { return }

    $maxHops = ConvertTo-IntSafe $script:Config.Checks.TracerouteHops 3
    if ($maxHops -lt 1 -or $maxHops -gt 10) { $maxHops = 3 }
    $target = "1.1.1.1"
    foreach ($candidate in @($script:Config.Tests.PingTargets)) {
        $address = ConvertTo-SafeString (Get-PropertyValue $candidate "Address" "")
        if (-not [string]::IsNullOrWhiteSpace($address) -and $address -ne "AUTO_GATEWAY" -and $address -ne "AUTO_DNS") { $target = $address; break }
    }

    $hops = @()
    try {
        $hops = @(Invoke-TraceRoute -Target $target -MaxHops $maxHops -TimeoutMs 1000)
    }
    catch {
        Add-CheckResult -Category "IT Diagnostics" -Check "Traceroute (first hops)" -Status "ERROR" -Message "Traceroute could not run." -Details (Get-ExceptionDetails $_) -Diagnostics (Get-ExceptionDiagnostics $_) -Tag "traceroute" -Scope "IT" | Out-Null
        return
    }

    $lines = @()
    foreach ($hop in $hops) {
        $lines += ("Hop {0}: {1} ({2}) {3} ms" -f $hop.Hop, $hop.Address, $hop.Status, $hop.ElapsedMs)
    }
    $lines += ("Method: .NET Ping with TTL 1..{0}, 1000 ms per hop; hops that stay silent show as *." -f $maxHops)
    $lines += ("Manual check: tracert -d -h {0} {1}" -f $maxHops, $target)
    $reachedText = "no"
    if (@($hops | Where-Object { $_.Reached }).Count -gt 0) { $reachedText = "yes" }
    Add-CheckResult -Category "IT Diagnostics" -Check "Traceroute (first hops)" -Status "INFO" -Message ("{0}: {1} hop(s) probed, destination reached: {2}." -f $target, $hops.Count, $reachedText) -Details ($lines -join [Environment]::NewLine) -Tag "traceroute" -Scope "IT" | Out-Null
}

function Add-DriverInfoResult {
    param([object[]]$Adapters)

    if (-not (Test-IsTrueFlag $script:Config.Checks.DriverInfo)) { return }

    $physical = @($Adapters | Where-Object { $_.IsPhysical -eq $true })
    if ($physical.Count -eq 0) {
        Add-CheckResult -Category "IT Diagnostics" -Check "Adapter drivers" -Status "INFO" -Message "No physical adapter is connected; no driver information." -Details "Manual check: Get-NetAdapter | Format-List Name, DriverVersion, DriverDate" -Tag "drivers" -Scope "IT" | Out-Null
        return
    }

    $lines = @()
    foreach ($adapter in $physical) {
        $lines += ("{0}: {1} - driver {2} ({3}, {4}), media {5}" -f $adapter.Name, $adapter.Description, (ConvertTo-DisplayString $adapter.DriverVersion), (ConvertTo-DisplayString $adapter.DriverDate), (ConvertTo-DisplayString $adapter.DriverProvider), (ConvertTo-DisplayString $adapter.MediaType))
    }
    $lines += "Method: Get-NetAdapter DriverVersion / DriverDate / DriverProvider"
    $lines += "Manual check: Get-NetAdapter | Format-List Name, DriverVersion, DriverDate"
    Add-CheckResult -Category "IT Diagnostics" -Check "Adapter drivers" -Status "INFO" -Message ("{0} physical adapter(s); driver versions are listed in the details." -f $physical.Count) -Details ($lines -join [Environment]::NewLine) -Tag "drivers" -Scope "IT" | Out-Null
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
        Add-CheckResult -Category "TCP Retransmissions" -Check "System Counters" -Status "ERROR" -Message "Complete before-and-after TCP counter data is unavailable." -Details "" -Tag "tcp-retransmissions" | Out-Null
        return
    }

    $counterErrors = @()
    $counterErrors += @($Before.Errors)
    $counterErrors += @($After.Errors)
    foreach ($errorItem in $counterErrors) {
        Add-CheckResult -Category "TCP Retransmissions" -Check ("{0} counters" -f $errorItem.Protocol) -Status "ERROR" -Message "The TCP retransmission counter could not be read." -Details $errorItem.Error -Diagnostics $errorItem.Diagnostics -Tag "tcp-retransmissions" | Out-Null
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
            Add-CheckResult -Category "TCP Retransmissions" -Check $protocol -Status "ERROR" -Message "The counter was reset or overflowed during the test, so the delta cannot be calculated." -Details ("Start Sent={0}, Retrans={1}; end Sent={2}, Retrans={3}" -f $start.SegmentsSent, $start.Retransmitted, $end.SegmentsSent, $end.Retransmitted) -Tag "tcp-retransmissions" | Out-Null
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
            Add-CheckResult -Category "TCP Retransmissions" -Check $protocol -Status "INFO" -Message "There was not enough TCP send traffic during the sample. No retransmissions were observed, but this does not establish the long-term condition." -Details $details -Tag "tcp-retransmissions" | Out-Null
            continue
        }

        if ($sentDelta -lt $minimumSegments) {
            if ($retransDelta -gt 0) {
                Add-CheckResult -Category "TCP Retransmissions" -Check $protocol -Status "WARN" -Message ("The traffic sample is small, but {0} retransmission(s) were observed (approximately {1}%)." -f $retransDelta, $rate) -Details $details -Tag "tcp-retransmissions" | Out-Null
            }
            else {
                Add-CheckResult -Category "TCP Retransmissions" -Check $protocol -Status "INFO" -Message ("The sample contains only {0} sent segment(s); no retransmissions were observed." -f $sentDelta) -Details $details -Tag "tcp-retransmissions" | Out-Null
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

        Add-CheckResult -Category "TCP Retransmissions" -Check $protocol -Status $status -Message ("Sent {0}, retransmitted {1}, approximate retransmission rate {2}%." -f $sentDelta, $retransDelta, $rate) -Details $details -Tag "tcp-retransmissions" | Out-Null
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
    $failCount = @($script:Results | Where-Object { [string]$_.Scope -ne "IT" -and $_.Status -eq "FAIL" }).Count
    $errorCount = @($script:Results | Where-Object { [string]$_.Scope -ne "IT" -and $_.Status -eq "ERROR" }).Count
    $warnCount = @($script:Results | Where-Object { [string]$_.Scope -ne "IT" -and $_.Status -eq "WARN" }).Count

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
    $mainResults = @($script:Results | Where-Object { [string]$_.Scope -ne "IT" })
    return [pscustomobject][ordered]@{
        Pass  = @($mainResults | Where-Object { $_.Status -eq "PASS" }).Count
        Warn  = @($mainResults | Where-Object { $_.Status -eq "WARN" }).Count
        Fail  = @($mainResults | Where-Object { $_.Status -eq "FAIL" }).Count
        Info  = @($mainResults | Where-Object { $_.Status -eq "INFO" }).Count
        Error = @($mainResults | Where-Object { $_.Status -eq "ERROR" }).Count
        Total = $mainResults.Count
    }
}

# -----------------------------------------------------------------------------
# Reporting: generate HTML, text, and JSON; preserve detailed exceptions on write failures.
# -----------------------------------------------------------------------------
# v1.2: language-neutral fingerprint over result tags; feeds the "What to tell IT" section and the wizard.
function Get-FingerprintSummary {
    $results = @($script:Results)
    $overall = Get-OverallStatus

    $adaptersFail = @($results | Where-Object { $_.Tag -eq "adapters" -and $_.Status -eq "FAIL" }).Count -gt 0
    $gatewayConfigFail = @($results | Where-Object { $_.Tag -eq "gateway-config" -and $_.Status -eq "FAIL" }).Count -gt 0
    $gatewayPingPass = @($results | Where-Object { $_.Tag -eq "ping-gateway" -and $_.Status -eq "PASS" }).Count -gt 0
    $gatewayPingBad = @($results | Where-Object { $_.Tag -eq "ping-gateway" -and ($_.Status -eq "FAIL" -or $_.Status -eq "ERROR") }).Count -gt 0
    $groupFail = @($results | Where-Object { $_.Tag -eq "connectivity-group" -and ($_.Status -eq "FAIL" -or $_.Status -eq "WARN") }).Count -gt 0
    $groupPass = @($results | Where-Object { $_.Tag -eq "connectivity-group" -and $_.Status -eq "PASS" }).Count -gt 0
    $dnsFail = @($results | Where-Object { $_.Tag -eq "dns" -and ($_.Status -eq "FAIL" -or $_.Status -eq "WARN") }).Count -gt 0
    $tcpPass = @($results | Where-Object { $_.Tag -eq "tcp" -and $_.Status -eq "PASS" }).Count -gt 0
    $qualityIssue = @($results | Where-Object { ($_.Tag -eq "ping-target" -or $_.Tag -eq "ping-gateway" -or $_.Tag -eq "tcp-retransmissions" -or $_.Tag -eq "adapter-errors") -and ($_.Status -eq "WARN" -or $_.Status -eq "FAIL") }).Count -gt 0

    $key = "healthy"
    if ($adaptersFail -or $gatewayConfigFail) { $key = "local" }
    elseif ($gatewayPingBad -and -not $gatewayPingPass) { $key = "gateway-unreachable" }
    elseif ($gatewayPingPass -and $groupFail) { $key = "gateway-up-internet-dead" }
    elseif ($dnsFail -and ($groupPass -or $tcpPass)) { $key = "dns" }
    elseif ($overall.Code -eq "FAIL") { $key = "mixed" }
    elseif ($overall.Code -eq "ERROR") { $key = "incomplete" }
    elseif ($qualityIssue -or $overall.Code -eq "WARN") { $key = "quality" }

    $title = ""
    $lines = @()
    switch ($key) {
        "local" { $title = "Local link problem"; $lines = @("No working network adapter or no default gateway was found.", "The fault is on this computer or its link: cable, Wi-Fi association, adapter disabled, or DHCP not answering.", "Try another device on the same network to see whether only this computer is affected.") }
        "gateway-unreachable" { $title = "Gateway does not answer"; $lines = @("The default gateway is configured but does not answer pings.", "The fault is between this computer and the router: link, Wi-Fi, switch, or the router itself.", "Check the link light or Wi-Fi signal and whether other devices reach the router.") }
        "gateway-up-internet-dead" { $title = "Gateway answers, internet does not"; $lines = @("The router answers, but connections beyond it fail.", "The fault is at or beyond the router: WAN link, ISP, or an upstream firewall.", "Check the router's WAN status and whether other devices lose the internet too.") }
        "dns" { $title = "Name resolution fails"; $lines = @("Direct connections by IP address work, but host names do not resolve.", "The fault is DNS: the configured DNS servers, a filtering service, or the name itself.", "Compare the DNS servers in this report with the expected company settings.") }
        "quality" { $title = "Connected, but quality is poor"; $lines = @("Connectivity works, but packet loss, latency, retransmissions, or adapter errors were above the thresholds.", "Typical causes: weak Wi-Fi, a congested link, or a faulty cable or port.", "Run the tool again while the problem is occurring and compare the numbers.") }
        "mixed" { $title = "A required check failed"; $lines = @("At least one required check failed; see the failed rows below.", "Send the report to IT as it is.") }
        "incomplete" { $title = "Some checks could not run"; $lines = @("No failure was found, but some steps could not be completed on this computer.", "Send the report to IT as it is; the reasons are recorded in the details.") }
        default { $title = "Everything passed"; $lines = @("All checks passed during this run.", "If the problem persists, it is likely on the application or server side, or it comes and goes; run the tool again while it is happening.") }
    }
    $lines += "Send the HTML report (or the JSON file) to IT. It contains the computer name, user name, adapter MAC addresses and the Wi-Fi network name."

    return [pscustomobject][ordered]@{
        Key   = $key
        Title = $title
        Lines = @($lines)
    }
}

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
    $itRows = New-Object System.Text.StringBuilder
    $itCount = 0
    $detailsOpen = ""
    if ($null -ne $script:RunOptions -and $script:RunOptions.ExpandDetails) { $detailsOpen = " open" }
    $fingerprint = Get-FingerprintSummary
    $fingerprintItems = (@($fingerprint.Lines | ForEach-Object { "      <li>" + (ConvertTo-HtmlEncoded $_) + "</li>" }) -join [Environment]::NewLine)
    $runProfile = ConvertTo-HtmlEncoded (Get-RunProfileText)
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
            $detailsHtml = "<details$detailsOpen><summary>Show Details</summary><pre>$detailsEncoded</pre></details>"
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
        if ([string]$result.Scope -eq "IT") {
            [void]$itRows.AppendLine($rowHtml)
            $itCount++
        }
        else {
            [void]$rows.AppendLine($rowHtml)
        }
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
.tools { margin-bottom: 8px; } .tools button { border: 1px solid #cbd5e0; background: #edf2f7; border-radius: 6px; padding: 5px 12px; cursor: pointer; font: inherit; }
.tell ul { margin: 6px 0 0 18px; } .tell li { margin: 3px 0; }
details.itblock > summary { cursor: pointer; } .ith2 { font-size: 19px; font-weight: 700; }
@media (max-width: 800px) { .cards { grid-template-columns: repeat(3, 1fr); } .meta { grid-template-columns: 1fr; } table { display: block; overflow-x: auto; } }
</style>
</head>
<body>
<header>
  <h1>Network Health Check Report</h1>
  <p>Organization: $(ConvertTo-HtmlEncoded $organization) &nbsp;|&nbsp; Computer: $(ConvertTo-HtmlEncoded $SystemSummary.ComputerName)</p>
  <p>Generated: $(ConvertTo-HtmlEncoded $generatedAt) &nbsp;|&nbsp; Test duration: approximately $(ConvertTo-HtmlEncoded $duration) seconds</p>
  <p>Run profile: $runProfile</p>
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

  <section class="tell">
    <h2>What to tell IT</h2>
    <p><strong>$(ConvertTo-HtmlEncoded $fingerprint.Title)</strong></p>
    <ul>
$fingerprintItems
    </ul>
  </section>

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
    <div class="tools"><button type="button" onclick="nhcToggle(true)">Expand all</button> <button type="button" onclick="nhcToggle(false)">Collapse all</button></div>
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

  <section>
    <details class="itblock"$detailsOpen>
      <summary><span class="ith2">$(ConvertTo-HtmlEncoded ("IT diagnostics ({0} items)" -f $itCount))</span></summary>
      <div class="notice" style="margin-top:12px;">Informational data for IT (routes, gateway neighbor, proxy, traceroute, Wi-Fi radio, drivers). These rows never change the overall result.</div>
      <div style="overflow-x:auto; margin-top:14px;">
        <table>
        <thead><tr><th>Time</th><th>Category</th><th>Check</th><th>Result</th><th>Description</th></tr></thead>
          <tbody>
$($itRows.ToString())
          </tbody>
        </table>
      </div>
    </details>
  </section>

  <footer>NetworkHealthCheck $($script:ToolVersion). This tool only reads system information and performs connectivity tests. It does not modify IP, DNS, routing, or firewall settings.</footer>
</main>
<script>function nhcToggle(open){var items=document.querySelectorAll('details');for(var i=0;i<items.length;i++){items[i].open=open;}}</script>
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
    [void]$builder.AppendLine("Run profile: $(Get-RunProfileText)")
    $fingerprint = Get-FingerprintSummary
    [void]$builder.AppendLine("What to tell IT: $($fingerprint.Title)")
    foreach ($line in @($fingerprint.Lines)) {
        [void]$builder.AppendLine("  - $line")
    }
    $itHeaderWritten = $false
    [void]$builder.AppendLine("")

    foreach ($result in @(@($script:Results | Where-Object { [string]$_.Scope -ne "IT" }) + @($script:Results | Where-Object { [string]$_.Scope -eq "IT" }))) {
        if ([string]$result.Scope -eq "IT" -and -not $itHeaderWritten) {
            [void]$builder.AppendLine("IT diagnostics")
            [void]$builder.AppendLine("-" * 40)
            $itHeaderWritten = $true
        }
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
        SchemaVersion = 2
        ToolVersion   = $script:ToolVersion
        RunOptions    = $script:RunOptions
        Fingerprint   = (Get-FingerprintSummary)
        Overall       = $overall
        Counts        = $counts
        System        = $systemSummary
        StartedAt     = $script:RunStartedAt
        FinishedAt    = $script:RunFinishedAt
        Results       = @($script:Results)
    }

    $writeErrors = New-Object System.Collections.ArrayList
    $failedFormats = New-Object System.Collections.ArrayList

    try {
        $html = New-HtmlReportContent -SystemSummary $systemSummary -Overall $overall -Counts $counts
        Write-Utf8File -Path $htmlPath -Content $html
        $script:LastHtmlReport = $htmlPath
    }
    catch {
        [void]$failedFormats.Add("HTML")
        [void]$writeErrors.Add("Failed to write HTML report: $(Get-ExceptionDetails $_ -IncludeDiagnostics)")
    }

    try {
        $text = New-TextReportContent -SystemSummary $systemSummary -Overall $overall -Counts $counts
        Write-Utf8File -Path $textPath -Content $text
        $script:LastTextReport = $textPath
    }
    catch {
        [void]$failedFormats.Add("TXT")
        [void]$writeErrors.Add("Failed to write text report: $(Get-ExceptionDetails $_ -IncludeDiagnostics)")
    }

    try {
        $json = $reportObject | ConvertTo-Json -Depth 10
        Write-Utf8File -Path $jsonPath -Content $json
        $script:LastJsonReport = $jsonPath
    }
    catch {
        [void]$failedFormats.Add("JSON")
        [void]$writeErrors.Add("Failed to write JSON report: $(Get-ExceptionDetails $_ -IncludeDiagnostics)")
    }

    foreach ($writeError in $writeErrors) {
        Write-UiLog -Status "ERROR" -Text $writeError
    }

    return [pscustomobject]@{
        Html          = $script:LastHtmlReport
        Text          = $script:LastTextReport
        Json          = $script:LastJsonReport
        Overall       = $overall
        Counts        = $counts
        FailedFormats = @($failedFormats)
        WriteErrors   = @($writeErrors)
    }
}

# Backlog #3: formats that succeeded stay usable; a single emergency report only when all three failed.
function Complete-ReportStage {
    param([object]$SaveResult)

    $available = @(@($SaveResult.Html, $SaveResult.Text, $SaveResult.Json) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    $primary = $null
    if ($available.Count -gt 0) {
        $primary = [string]$available[0]
    }
    $failedFormats = @($SaveResult.FailedFormats)
    $writeErrors = @($SaveResult.WriteErrors)
    $emergencyPath = $null

    if ($null -eq $primary) {
        Write-UiLog -Status "ERROR" -Text "Report generation failed."
        $emergencyPath = Write-EmergencyReport -Title "Network Health Check Report Generation Failed" -ErrorDetails ($writeErrors -join [Environment]::NewLine)
        Set-UiProgress -Percent 100 -Text "Report generation failed"
        Update-OverallUi -Overall $SaveResult.Overall
        if ($script:GuiAvailable) {
            $script:ReportPathLabel.Text = "Report could not be written"
            $script:OpenFolderButton.Enabled = [bool](Test-Path -LiteralPath $script:OutputDirectory)
            $message = "Report generation failed."
            if ($null -ne $emergencyPath) {
                $message += "`r`nEmergency error report written to: $emergencyPath"
            }
            [System.Windows.Forms.MessageBox]::Show($message, "Network Health Check Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        }
    }
    elseif ($failedFormats.Count -gt 0) {
        Set-UiProgress -Percent 100 -Text "Test Complete"
        Write-UiLog -Status "WARN" -Text ("Report generated, but {0} format(s) could not be written ({1}). Primary report: {2}" -f $failedFormats.Count, ($failedFormats -join ", "), $primary)
        Update-OverallUi -Overall $SaveResult.Overall
        if ($script:GuiAvailable) {
            $script:ReportPathLabel.Text = "Report: $primary"
            $script:OpenReportButton.Enabled = $true
            $script:OpenJsonButton.Enabled = (-not [string]::IsNullOrWhiteSpace([string]$SaveResult.Json))
            $script:OpenFolderButton.Enabled = $true
            [System.Windows.Forms.MessageBox]::Show(("{0} of 3 report formats could not be written ({1}). The report was saved as: {2}" -f $failedFormats.Count, ($failedFormats -join ", "), $primary), "Network Health Check Warning", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        }
    }
    else {
        Set-UiProgress -Percent 100 -Text "Test Complete"
        Write-UiLog -Status "PASS" -Text ("Report generated: {0}" -f $primary)
        Update-OverallUi -Overall $SaveResult.Overall
        if ($script:GuiAvailable) {
            $script:ReportPathLabel.Text = "Report: $primary"
            $script:OpenReportButton.Enabled = $true
            $script:OpenJsonButton.Enabled = (-not [string]::IsNullOrWhiteSpace([string]$SaveResult.Json))
            $script:OpenFolderButton.Enabled = $true
        }
    }

    return [pscustomobject]@{
        Html          = $SaveResult.Html
        Text          = $SaveResult.Text
        Json          = $SaveResult.Json
        Overall       = $SaveResult.Overall
        Counts        = $SaveResult.Counts
        PrimaryReport = $primary
        FailedFormats = $failedFormats
        WriteErrors   = $writeErrors
        EmergencyPath = $emergencyPath
        Succeeded     = ($null -ne $primary)
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
        $script:OpenJsonButton.Enabled = $false
        $script:OverallLabel.Text = "Result: Test in progress"
        $script:OverallLabel.ForeColor = [System.Drawing.Color]::FromArgb(31, 41, 51)
        $script:ReportPathLabel.Text = "Report has not been generated"
    }

    Write-UiLog -Status "INFO" -Text "Network health check started. The test is read-only and will not modify network settings."
    Set-UiProgress -Percent 2 -Text "Initializing"

    if ($null -ne $script:ConfigLoadError) {
        Add-CheckResult -Category "Program Configuration" -Check "Configuration File" -Status "ERROR" -Message "The configuration file could not be loaded. Built-in defaults were used." -Details $script:ConfigLoadError -Diagnostics $script:ConfigLoadDiagnostics -Tag "config-file" | Out-Null
    }
    else {
        Add-CheckResult -Category "Program Configuration" -Check "Configuration File" -Status "PASS" -Message ("Loaded: {0}" -f $script:EffectiveConfigPath) -Details "" -Tag "config-file" | Out-Null
    }

    foreach ($startupMessage in @($script:StartupMessages)) {
        Add-CheckResult -Category "Program Environment" -Check "Startup Notice" -Status "WARN" -Message $startupMessage -Details "" -Tag "startup" | Out-Null
    }

    Invoke-CheckStep -Category "Program Configuration" -Name "Validate Configuration" -Progress 4 -Action {
        Test-ConfigurationSemantics
    } | Out-Null

    if (-not (Test-IsWindowsPlatform)) {
        Add-CheckResult -Category "Program Environment" -Check "Operating System" -Status "FAIL" -Message "This version supports only Windows 10/11 or compatible Windows Server versions." -Details ([System.Environment]::OSVersion.VersionString) -Tag "environment" | Out-Null
        $script:RunFinishedAt = Get-Date
        return (Complete-ReportStage -SaveResult (Save-Reports))
    }

    if ($PSVersionTable.PSVersion.Major -lt 5) {
        Add-CheckResult -Category "Program Environment" -Check "PowerShell Version" -Status "FAIL" -Message "PowerShell 5.1 or later is required." -Details ("Current version: {0}" -f $PSVersionTable.PSVersion) -Tag "environment" | Out-Null
        $script:RunFinishedAt = Get-Date
        return (Complete-ReportStage -SaveResult (Save-Reports))
    }
    else {
        Add-CheckResult -Category "Program Environment" -Check "PowerShell Version" -Status "PASS" -Message ("Current version: {0}" -f $PSVersionTable.PSVersion) -Details "" -Tag "environment" | Out-Null
    }

    Invoke-CheckStep -Category "System Information" -Name "Get Computer and Operating System Information" -Progress 7 -Action {
        $summary = Get-SystemSummary
        Add-CheckResult -Category "System Information" -Check "Computer" -Status "INFO" -Message ("{0}, user {1}." -f $summary.ComputerName, $summary.UserName) -Details ("Operating system: {0} ({1})`r`nPowerShell: {2}" -f $summary.OperatingSystem, $summary.OperatingVersion, $summary.PowerShellVersion) -Tag "system" | Out-Null
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

    Invoke-CheckStep -Category "IT Diagnostics" -Name "Collect IT diagnostics (Wi-Fi, routes, gateway neighbor, proxy, traceroute, drivers)" -Progress 74 -Scope "IT" -Action {
        Add-WifiRfResult
        Add-RouteTableResult
        Add-GatewayNeighborResult -PrimaryAdapters $script:PrimaryAdapters
        Add-ProxySettingsResult
        Add-TracerouteResult
        Add-DriverInfoResult -Adapters $networkSnapshot
    } | Out-Null

    $minimumSampleSeconds = [math]::Max(1, (ConvertTo-IntSafe $script:Config.Tests.RetransmissionSampleSeconds 8))
    Wait-ForMinimumTcpSample -StartTime $tcpSampleStart -MinimumSeconds $minimumSampleSeconds

    $adapterStatsAfter = Invoke-CheckStep -Category "Network Adapter Error Counters" -Name "Get Ending Network Adapter Error Values" -Progress 82 -Action {
        return (Get-AdapterStatisticsSnapshot)
    }

    Invoke-CheckStep -Category "Network Adapter Error Counters" -Name "Analyze Adapter Errors and Discards" -Progress 85 -Action {
        if ($null -eq $adapterStatsBefore -or $null -eq $adapterStatsAfter) {
            Add-CheckResult -Category "Network Adapter Error Counters" -Check "Before/After Comparison" -Status "ERROR" -Message "The baseline or ending value is missing, so the error delta cannot be calculated." -Details "" -Tag "adapter-errors" | Out-Null
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
        return (Complete-ReportStage -SaveResult (Save-Reports))
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
        # Backlog #2: an unexpected failure inside the report stage is handled once, here, and never re-thrown.
        return [pscustomobject]@{
            Html          = $null
            Text          = $null
            Json          = $null
            Overall       = (Get-OverallStatus)
            Counts        = (Get-SummaryCounts)
            PrimaryReport = $null
            FailedFormats = @("HTML", "TXT", "JSON")
            WriteErrors   = @($details)
            EmergencyPath = $emergencyPath
            Succeeded     = $false
        }
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
        Write-Host ("HTML report: {0}" -f (ConvertTo-DisplayString $report.Html "(not written)"))
        Write-Host ("Text report: {0}" -f (ConvertTo-DisplayString $report.Text "(not written)"))
        Write-Host ("JSON report: {0}" -f (ConvertTo-DisplayString $report.Json "(not written)"))
        if (@($report.FailedFormats).Count -gt 0) {
            Write-Host ("Report formats not written: {0}" -f (@($report.FailedFormats) -join ", ")) -ForegroundColor Yellow
        }
        if ($null -ne $report.EmergencyPath) {
            Write-Host "Emergency error report: $($report.EmergencyPath)"
        }
        if ($report.Succeeded) {
            return 0
        }
        return 1
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
function Set-OptionsPanelValues {
    $controls = $script:OptionsPanel
    $options = $script:RunOptions
    if ($null -eq $controls -or $null -eq $options) {
        return
    }

    $controls["PingTarget"].Text = (@($options.ExtraTargets.Ping) -join ", ")
    $controls["DnsName"].Text = (@($options.ExtraTargets.Dns) -join ", ")
    $controls["TcpTarget"].Text = (@($options.ExtraTargets.Tcp) -join ", ")
    $controls["HttpUrl"].Text = (@($options.ExtraTargets.Http) -join ", ")
    $controls["PingCount"].Value = [math]::Min(20, [math]::Max(1, $options.PingCount))
    $controls["SampleSeconds"].Value = [math]::Min(120, [math]::Max(1, $options.SampleSeconds))
    $controls["TracerouteHops"].Value = [math]::Min(10, [math]::Max(1, $options.TracerouteHops))
    $controls["WifiRf"].Checked = [bool]$options.ChecksEnabled.WifiRf
    $controls["RouteTable"].Checked = [bool]$options.ChecksEnabled.RouteTable
    $controls["GatewayNeighbor"].Checked = [bool]$options.ChecksEnabled.GatewayNeighbor
    $controls["ProxySettings"].Checked = [bool]$options.ChecksEnabled.ProxySettings
    $controls["DriverInfo"].Checked = [bool]$options.ChecksEnabled.DriverInfo
    $controls["Traceroute"].Checked = [bool]$options.ChecksEnabled.Traceroute
    $controls["ExpandDetails"].Checked = [bool]$options.ExpandDetails
}

function Get-RunOptionsFromPanel {
    $controls = $script:OptionsPanel
    return @{
        EntryPoint     = "IT"
        ExpandDetails  = [bool]$controls["ExpandDetails"].Checked
        PingTarget     = @(([string]$controls["PingTarget"].Text) -split '[,;\s]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        DnsName        = @(([string]$controls["DnsName"].Text) -split '[,;\s]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        TcpTarget      = @(([string]$controls["TcpTarget"].Text) -split '[,;\s]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        HttpUrl        = @(([string]$controls["HttpUrl"].Text) -split '[,;\s]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        PingCount      = [int]$controls["PingCount"].Value
        SampleSeconds  = [int]$controls["SampleSeconds"].Value
        TracerouteHops = [int]$controls["TracerouteHops"].Value
        Checks         = @{
            WifiRf          = [bool]$controls["WifiRf"].Checked
            Traceroute      = [bool]$controls["Traceroute"].Checked
            RouteTable      = [bool]$controls["RouteTable"].Checked
            GatewayNeighbor = [bool]$controls["GatewayNeighbor"].Checked
            ProxySettings   = [bool]$controls["ProxySettings"].Checked
            DriverInfo      = [bool]$controls["DriverInfo"].Checked
        }
    }
}

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
    if ($script:Interactive) { $form.Text += " - IT" }
    $form.StartPosition = "CenterScreen"
    $offset = 0
    if ($script:Interactive) { $offset = 190 }
    $form.Size = New-Object System.Drawing.Size(940, 700 + $offset)
    $form.MinimumSize = New-Object System.Drawing.Size(780, 560 + $offset)
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

    $script:OptionsPanel = $null
    if ($script:Interactive) {
        $panel = New-Object System.Windows.Forms.GroupBox
        $panel.Text = "Run options (IT)"
        $panel.Location = New-Object System.Drawing.Point(22, 84)
        $panel.Size = New-Object System.Drawing.Size(880, 180)
        $panel.Anchor = "Top,Left,Right"
        $form.Controls.Add($panel)

        $controls = @{}
        foreach ($item in @(
            @{ Text = "Extra ping"; X = 12; Y = 26 },
            @{ Text = "Extra DNS"; X = 320; Y = 26 },
            @{ Text = "Ping count"; X = 630; Y = 26 },
            @{ Text = "Extra TCP (host:port)"; X = 12; Y = 58 },
            @{ Text = "Extra URL"; X = 320; Y = 58 },
            @{ Text = "Sample seconds"; X = 630; Y = 58 }
        )) {
            $label = New-Object System.Windows.Forms.Label
            $label.Text = $item.Text
            $label.Location = New-Object System.Drawing.Point($item.X, $item.Y)
            $label.Size = New-Object System.Drawing.Size(100, 22)
            $panel.Controls.Add($label)
        }
        foreach ($item in @(@{ Key = "PingTarget"; X = 115; Y = 23 }, @{ Key = "DnsName"; X = 423; Y = 23 }, @{ Key = "TcpTarget"; X = 115; Y = 55 }, @{ Key = "HttpUrl"; X = 423; Y = 55 })) {
            $box = New-Object System.Windows.Forms.TextBox
            $box.Location = New-Object System.Drawing.Point($item.X, $item.Y)
            $box.Size = New-Object System.Drawing.Size(195, 24)
            $panel.Controls.Add($box)
            $controls[$item.Key] = $box
        }
        foreach ($item in @(@{ Key = "PingCount"; X = 735; Y = 23; Min = 1; Max = 20 }, @{ Key = "SampleSeconds"; X = 735; Y = 55; Min = 1; Max = 120 })) {
            $spinner = New-Object System.Windows.Forms.NumericUpDown
            $spinner.Location = New-Object System.Drawing.Point($item.X, $item.Y)
            $spinner.Size = New-Object System.Drawing.Size(70, 24)
            $spinner.Minimum = $item.Min
            $spinner.Maximum = $item.Max
            $panel.Controls.Add($spinner)
            $controls[$item.Key] = $spinner
        }
        $x = 12
        foreach ($item in @(@{ Key = "WifiRf"; Text = "Wi-Fi RF"; Width = 110 }, @{ Key = "Traceroute"; Text = "Traceroute"; Width = 110 })) {
            $check = New-Object System.Windows.Forms.CheckBox
            $check.Text = $item.Text
            $check.Location = New-Object System.Drawing.Point($x, 90)
            $check.Size = New-Object System.Drawing.Size($item.Width, 24)
            $panel.Controls.Add($check)
            $controls[$item.Key] = $check
            $x += $item.Width + 6
        }
        $hopsLabel = New-Object System.Windows.Forms.Label
        $hopsLabel.Text = "Traceroute hops"
        $hopsLabel.Location = New-Object System.Drawing.Point($x, 92)
        $hopsLabel.Size = New-Object System.Drawing.Size(115, 22)
        $panel.Controls.Add($hopsLabel)
        $hops = New-Object System.Windows.Forms.NumericUpDown
        $hops.Location = New-Object System.Drawing.Point(($x + 118), 89)
        $hops.Size = New-Object System.Drawing.Size(55, 24)
        $hops.Minimum = 1
        $hops.Maximum = 10
        $panel.Controls.Add($hops)
        $controls["TracerouteHops"] = $hops
        $expand = New-Object System.Windows.Forms.CheckBox
        $expand.Text = "Expand details in HTML"
        $expand.Location = New-Object System.Drawing.Point(($x + 185), 90)
        $expand.Size = New-Object System.Drawing.Size(220, 24)
        $panel.Controls.Add($expand)
        $controls["ExpandDetails"] = $expand
        $x = 12
        foreach ($item in @(@{ Key = "RouteTable"; Text = "Routes"; Width = 100 }, @{ Key = "GatewayNeighbor"; Text = "Gateway ARP"; Width = 130 }, @{ Key = "ProxySettings"; Text = "Proxy"; Width = 90 }, @{ Key = "DriverInfo"; Text = "Drivers"; Width = 110 })) {
            $check = New-Object System.Windows.Forms.CheckBox
            $check.Text = $item.Text
            $check.Location = New-Object System.Drawing.Point($x, 120)
            $check.Size = New-Object System.Drawing.Size($item.Width, 24)
            $panel.Controls.Add($check)
            $controls[$item.Key] = $check
            $x += $item.Width + 6
        }
        $resetButton = New-Object System.Windows.Forms.Button
        $resetButton.Text = "Reset to config"
        $resetButton.Location = New-Object System.Drawing.Point(12, 148)
        $resetButton.Size = New-Object System.Drawing.Size(140, 26)
        $panel.Controls.Add($resetButton)
        $script:OptionsPanel = $controls
        Set-OptionsPanelValues
        $resetButton.Add_Click({
            Set-RunOptions -Overrides @{ EntryPoint = "IT"; ExpandDetails = $true } | Out-Null
            Set-OptionsPanelValues
        })
    }

    $overall = New-Object System.Windows.Forms.Label
    $overall.Text = "Result: Not started"
    $overall.Font = New-Object System.Drawing.Font($form.Font.FontFamily, 11, [System.Drawing.FontStyle]::Bold)
    $overall.AutoSize = $false
    $overall.Location = New-Object System.Drawing.Point(22, 84 + $offset)
    $overall.Size = New-Object System.Drawing.Size(880, 28)
    $overall.Anchor = "Top,Left,Right"
    $form.Controls.Add($overall)

    $progressLabel = New-Object System.Windows.Forms.Label
    $progressLabel.Text = "Ready"
    if ($script:Interactive) { $progressLabel.Text = "Ready - adjust the options, then select Start Test" }
    $progressLabel.Location = New-Object System.Drawing.Point(22, 119 + $offset)
    $progressLabel.Size = New-Object System.Drawing.Size(880, 22)
    $progressLabel.Anchor = "Top,Left,Right"
    $form.Controls.Add($progressLabel)

    $progress = New-Object System.Windows.Forms.ProgressBar
    $progress.Location = New-Object System.Drawing.Point(22, 143 + $offset)
    $progress.Size = New-Object System.Drawing.Size(880, 22)
    $progress.Minimum = 0
    $progress.Maximum = 100
    $progress.Value = 0
    $progress.Anchor = "Top,Left,Right"
    $form.Controls.Add($progress)

    $log = New-Object System.Windows.Forms.RichTextBox
    $log.Location = New-Object System.Drawing.Point(22, 178 + $offset)
    $log.Size = New-Object System.Drawing.Size(880, 390)
    $log.Anchor = "Top,Bottom,Left,Right"
    $log.ReadOnly = $true
    $log.DetectUrls = $false
    $log.BackColor = [System.Drawing.Color]::White
    $log.Font = New-Object System.Drawing.Font("Consolas", 9.5)
    $form.Controls.Add($log)

    $startButton = New-Object System.Windows.Forms.Button
    $startButton.Text = "Start Test"
    $startButton.Location = New-Object System.Drawing.Point(22, 584 + $offset)
    $startButton.Size = New-Object System.Drawing.Size(120, 34)
    $startButton.Anchor = "Bottom,Left"
    $form.Controls.Add($startButton)

    $openReportButton = New-Object System.Windows.Forms.Button
    $openReportButton.Text = "Open Report"
    $openReportButton.Location = New-Object System.Drawing.Point(152, 584 + $offset)
    $openReportButton.Size = New-Object System.Drawing.Size(120, 34)
    $openReportButton.Anchor = "Bottom,Left"
    $openReportButton.Enabled = $false
    $form.Controls.Add($openReportButton)

    $openFolderButton = New-Object System.Windows.Forms.Button
    $openFolderButton.Text = "Open Report Folder"
    $openFolderButton.Location = New-Object System.Drawing.Point(282, 584 + $offset)
    $openFolderButton.Size = New-Object System.Drawing.Size(150, 34)
    $openFolderButton.Anchor = "Bottom,Left"
    $openFolderButton.Enabled = $false
    $form.Controls.Add($openFolderButton)

    $openJsonButton = New-Object System.Windows.Forms.Button
    $openJsonButton.Text = "Open JSON"
    $openJsonButton.Location = New-Object System.Drawing.Point(442, 584 + $offset)
    $openJsonButton.Size = New-Object System.Drawing.Size(110, 34)
    $openJsonButton.Anchor = "Bottom,Left"
    $openJsonButton.Enabled = $false
    $form.Controls.Add($openJsonButton)

    $closeButton = New-Object System.Windows.Forms.Button
    $closeButton.Text = "Close"
    $closeButton.Location = New-Object System.Drawing.Point(782, 584 + $offset)
    $closeButton.Size = New-Object System.Drawing.Size(120, 34)
    $closeButton.Anchor = "Bottom,Right"
    $form.Controls.Add($closeButton)

    $reportPathLabel = New-Object System.Windows.Forms.Label
    $reportPathLabel.Text = "Report has not been generated"
    $reportPathLabel.Location = New-Object System.Drawing.Point(22, 628 + $offset)
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
    $script:OpenJsonButton = $openJsonButton
    $script:ReportPathLabel = $reportPathLabel

    $startButton.Add_Click({
        try {
            if ($script:Interactive -and $null -ne $script:OptionsPanel) {
                Set-RunOptions -Overrides (Get-RunOptionsFromPanel) | Out-Null
            }
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
            $target = $null
            foreach ($candidate in @($script:LastHtmlReport, $script:LastTextReport, $script:LastJsonReport)) {
                if (-not [string]::IsNullOrWhiteSpace([string]$candidate) -and (Test-Path -LiteralPath $candidate)) {
                    $target = $candidate
                    break
                }
            }
            if ($null -ne $target) {
                Start-Process -FilePath $target -ErrorAction Stop
            }
            else {
                throw "No report file was found."
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

    $openJsonButton.Add_Click({
        try {
            if ($null -ne $script:LastJsonReport -and (Test-Path -LiteralPath $script:LastJsonReport)) {
                Start-Process -FilePath "notepad.exe" -ArgumentList ('"{0}"' -f $script:LastJsonReport) -ErrorAction Stop
            }
            else {
                throw "The JSON report was not found."
            }
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show(("Unable to open the JSON report: {0}" -f $_.Exception.Message), "Open JSON Failed", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
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
        if ($script:Interactive) { return }
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
    $script:Interactive = [bool]$Interactive
    $script:BaseConfig = Load-Configuration -RequestedPath $ConfigPath
    $entryPoint = "User"
    if ($Interactive -or $ExpandDetails) { $entryPoint = "IT" }
    Set-RunOptions -Overrides @{
        EntryPoint = $entryPoint; ExpandDetails = [bool]$ExpandDetails
        PingTarget = @($PingTarget); DnsName = @($DnsName); TcpTarget = @($TcpTarget); HttpUrl = @($HttpUrl)
        SampleSeconds = $SampleSeconds; PingCount = $PingCount; TracerouteHops = $TracerouteHops
        NoTraceroute = [bool]$NoTraceroute; NoWifi = [bool]$NoWifi
    } | Out-Null
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
