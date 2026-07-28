[CmdletBinding()]
param(
    [switch]$ConsoleOnly,
    [string]$ConfigPath = ""
)

# NetworkHealthCheck.ps1
# Windows 10/11 免安裝、唯讀網路診斷工具。
# 目標執行環境為 Windows PowerShell 5.1 與 Windows 上的 PowerShell 7。
#
# 架構概覽
# --------
# 1. 設定：載入 JSON、與安全預設值合併，再驗證格式與語意。無效設定會寫入
#    報告，而不是讓整個檢測直接中止。
# 2. 資料收集：優先使用 NetTCPIP/NetAdapter 指令；不可用時改用 CIM/WMI。
# 3. 主動測試：依設定執行 ICMP Ping、DNS、TCP 連線與 HTTP/HTTPS 請求。
# 4. 計數器：在檢測前後讀取網卡錯誤/丟棄與系統級 TCP 傳送/重傳累積值，
#    再計算非負增量。
# 5. 結果模型：每項結果為 PASS、WARN、FAIL、INFO 或 ERROR。ERROR 代表該項
#    無法完成，刻意與「檢查已執行但未通過」的 FAIL 分開。
# 6. 報告：輸出 HTML、TXT、JSON；原目錄不可寫入時改存使用者暫存目錄。
# 7. 介面：可使用 Windows Forms；GUI 初始化失敗時自動切換文字模式。
#
# 安全特性
# --------
# - 唯讀：不變更 IP、DNS、路由、防火牆或網卡狀態。
# - 錯誤隔離：單一檢測失敗不阻止其他檢測繼續。
# - 可追溯：PowerShell 可提供時，報告會保存例外類型、訊息、位置與堆疊。

$script:ToolVersion = "1.1.2"
$script:BaseDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:Results = New-Object System.Collections.ArrayList
$script:StartupMessages = New-Object System.Collections.ArrayList
$script:NetworkSnapshot = @()
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
$script:UsingFallbackOutputDirectory = $false

try {
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
}
catch {
    # GUI and file reports still use Unicode if the console encoding cannot be changed.
}

# -----------------------------------------------------------------------------
# 核心輔助函式與統一結果模型：安全轉型、例外資訊、狀態文字、畫面紀錄。
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
        [string]$EmptyText = "（無）"
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

    if ($null -eq $Value) {
        return $DefaultValue
    }

    try {
        return [int]$Value
    }
    catch {
        return $DefaultValue
    }
}

function Get-ExceptionDetails {
    param([object]$ErrorRecord)

    if ($null -eq $ErrorRecord) {
        return "未知錯誤"
    }

    try {
        $message = $ErrorRecord.Exception.Message
        $typeName = $ErrorRecord.Exception.GetType().FullName
        $position = ConvertTo-SafeString $ErrorRecord.InvocationInfo.PositionMessage
        $stack = ConvertTo-SafeString $ErrorRecord.ScriptStackTrace

        $parts = @("錯誤類型：$typeName", "訊息：$message")
        $inner = $ErrorRecord.Exception.InnerException
        $innerIndex = 1
        while ($null -ne $inner -and $innerIndex -le 5) {
            $parts += ("內部錯誤 {0}：{1} — {2}" -f $innerIndex, $inner.GetType().FullName, $inner.Message)
            $inner = $inner.InnerException
            $innerIndex++
        }
        if (-not [string]::IsNullOrWhiteSpace($position)) {
            $parts += "位置：$position"
        }
        if (-not [string]::IsNullOrWhiteSpace($stack)) {
            $parts += "呼叫堆疊：$stack"
        }
        return ($parts -join [Environment]::NewLine)
    }
    catch {
        return [string]$ErrorRecord
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
        "PASS"  { return "正常" }
        "WARN"  { return "需注意" }
        "FAIL"  { return "異常" }
        "INFO"  { return "資訊" }
        "ERROR" { return "無法檢查" }
        default  { return $Status }
    }
}

function Get-StatusPrefix {
    param([string]$Status)

    switch ($Status) {
        "PASS"  { return "[正常]" }
        "WARN"  { return "[注意]" }
        "FAIL"  { return "[異常]" }
        "INFO"  { return "[資訊]" }
        "ERROR" { return "[錯誤]" }
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
        [string]$Details = ""
    )

    $item = [pscustomobject][ordered]@{
        Time     = Get-Date
        Category = $Category
        Check    = $Check
        Status   = $Status
        Message  = $Message
        Details  = $Details
    }

    [void]$script:Results.Add($item)
    Write-UiLog -Status $Status -Text ("{0}／{1}：{2}" -f $Category, $Check, $Message)
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
    Write-UiLog -Status "INFO" -Text ("開始：$Name")

    try {
        return (& $Action)
    }
    catch {
        $details = Get-ExceptionDetails $_
        Add-CheckResult -Category $Category -Check $Name -Status "ERROR" -Message "此項目無法執行，已記錄錯誤。" -Details $details | Out-Null
        return $null
    }
}

# -----------------------------------------------------------------------------
# 設定處理：建立安全預設值、合併 JSON、自動切換報告輸出目錄。
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
                    Name     = "預設閘道"
                    Address  = "AUTO_GATEWAY"
                    Required = $true
                },
                [pscustomobject][ordered]@{
                    Name     = "公網 IP"
                    Address  = "1.1.1.1"
                    Required = $false
                }
            )
            DnsNames = @(
                [pscustomobject][ordered]@{
                    Name     = "DNS 名稱解析"
                    Host     = "www.microsoft.com"
                    Required = $true
                }
            )
            TcpTargets = @(
                [pscustomobject][ordered]@{
                    Name     = "HTTPS 直連測試"
                    Host     = "1.1.1.1"
                    Port     = 443
                    Required = $false
                    Group    = "Internet"
                }
            )
            HttpTargets = @(
                [pscustomobject][ordered]@{
                    Name     = "HTTPS 網頁測試"
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
        $script:ConfigLoadError = "找不到設定檔：$path。程式已改用內建預設值。"
        return $defaultConfig
    }

    try {
        $raw = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
        $overrideConfig = $raw | ConvertFrom-Json -ErrorAction Stop
        return (Merge-ConfigObject -DefaultObject $defaultConfig -OverrideObject $overrideConfig)
    }
    catch {
        $script:ConfigLoadError = "設定檔格式錯誤，程式已改用內建預設值。`r`n$(Get-ExceptionDetails $_)"
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
        [void]$script:StartupMessages.Add("原始報告目錄無法寫入，已改存到：$fallback。原始錯誤：$($_.Exception.Message)")
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
# 系統與網路資訊收集：優先使用 NetTCPIP/NetAdapter，失敗時改用 CIM/WMI。
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
        return "未知"
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
        throw "系統沒有可用的 CIM/WMI 指令。"
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
        $linkSpeed = "未知"

        if ($null -ne $adapter) {
            if (-not [string]::IsNullOrWhiteSpace([string]$adapter.NetConnectionID)) {
                $name = [string]$adapter.NetConnectionID
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$adapter.Name)) {
                $description = [string]$adapter.Name
            }
            $linkSpeed = Convert-LinkSpeedToText $adapter.Speed
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
            Gateways        = @($config.DefaultIPGateway)
            DnsServers      = @($config.DNSServerSearchOrder)
            DhcpEnabled     = [bool]$config.DHCPEnabled
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
            Add-CheckResult -Category "網卡與 IP" -Check "資料來源切換" -Status "WARN" -Message "Get-NetIPConfiguration 無法取得資料，已改用 CIM/WMI。" -Details (Get-ExceptionDetails $_) | Out-Null
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
# 設定語意驗證與公司規範比對：檢查 IP、CIDR、前綴、閘道、DNS、DHCP。
# -----------------------------------------------------------------------------
function Test-ConfigurationSemantics {
    $errors = New-Object System.Collections.ArrayList
    $warnings = New-Object System.Collections.ArrayList
    $expected = $script:Config.Expected
    $tests = $script:Config.Tests
    $thresholds = $script:Config.Thresholds

    foreach ($ip in @($expected.AllowedIPv4Addresses)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$ip) -and -not (Test-IsValidIPv4Address ([string]$ip))) {
            [void]$errors.Add("AllowedIPv4Addresses 含有無效 IPv4：$ip")
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
            [void]$errors.Add("AllowedIPv4Cidrs 含有無效 CIDR：$cidr")
        }
    }

    foreach ($prefixValue in @($expected.AllowedPrefixLengths)) {
        $prefix = ConvertTo-IntSafe $prefixValue -1
        if ($prefix -lt 0 -or $prefix -gt 32) {
            [void]$errors.Add("AllowedPrefixLengths 含有無效值：$prefixValue")
        }
    }

    foreach ($gateway in @($expected.AllowedDefaultGateways)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$gateway) -and -not (Test-IsValidIPv4Address ([string]$gateway))) {
            [void]$errors.Add("AllowedDefaultGateways 含有無效 IPv4：$gateway")
        }
    }

    foreach ($dns in @($expected.RequiredDnsServers)) {
        if ([string]::IsNullOrWhiteSpace([string]$dns)) { continue }
        $parsedDns = $null
        if (-not [System.Net.IPAddress]::TryParse([string]$dns, [ref]$parsedDns)) {
            [void]$errors.Add("RequiredDnsServers 含有無效 IP：$dns")
        }
    }

    if ($null -ne $expected.DhcpEnabled -and -not ($expected.DhcpEnabled -is [System.Boolean])) {
        [void]$errors.Add("DhcpEnabled 必須是 true、false 或 null；目前值：$($expected.DhcpEnabled)")
    }

    foreach ($target in @($tests.TcpTargets)) {
        if ($null -eq $target) { continue }
        $name = ConvertTo-SafeString (Get-PropertyValue $target "Name" "TCP target")
        $hostName = ConvertTo-SafeString (Get-PropertyValue $target "Host" "")
        $port = ConvertTo-IntSafe (Get-PropertyValue $target "Port" 0) 0
        if ([string]::IsNullOrWhiteSpace($hostName) -or $port -lt 1 -or $port -gt 65535) {
            [void]$errors.Add("TcpTargets 的「$name」主機或連接埠無效：Host=$hostName, Port=$port")
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
            [void]$errors.Add("HttpTargets 的「$name」URL 無效：$url")
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
            [void]$errors.Add("DnsNames 含有空白的 Host。")
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
            [void]$warnings.Add("$($setting.Name) 應大於 0；程式將套用內建最低值。")
        }
    }

    $warningLoss = ConvertTo-IntSafe $thresholds.PacketLossWarningPercent 5
    $criticalLoss = ConvertTo-IntSafe $thresholds.PacketLossCriticalPercent 20
    if ($warningLoss -lt 0 -or $criticalLoss -lt $warningLoss) {
        [void]$warnings.Add("封包遺失門檻順序不合理：Warning=$warningLoss, Critical=$criticalLoss。")
    }

    $warningRetrans = [double](Get-PropertyValue $thresholds "TcpRetransmissionWarningPercent" 2)
    $criticalRetrans = [double](Get-PropertyValue $thresholds "TcpRetransmissionCriticalPercent" 5)
    if ($warningRetrans -lt 0 -or $criticalRetrans -lt $warningRetrans) {
        [void]$warnings.Add("TCP 重傳門檻順序不合理：Warning=$warningRetrans, Critical=$criticalRetrans。")
    }

    if ($errors.Count -gt 0) {
        Add-CheckResult -Category "程式設定" -Check "設定值驗證" -Status "ERROR" -Message ("設定檔有 {0} 個無效值；程式會繼續執行，但相關結果可能不具判斷意義。" -f $errors.Count) -Details (@($errors) -join [Environment]::NewLine) | Out-Null
    }
    elseif ($warnings.Count -eq 0) {
        Add-CheckResult -Category "程式設定" -Check "設定值驗證" -Status "PASS" -Message "設定值格式檢查通過。" -Details "" | Out-Null
    }

    if ($warnings.Count -gt 0) {
        Add-CheckResult -Category "程式設定" -Check "設定值門檻" -Status "WARN" -Message ("設定檔有 {0} 個需要注意的門檻值。" -f $warnings.Count) -Details (@($warnings) -join [Environment]::NewLine) | Out-Null
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
        Add-CheckResult -Category "網卡與 IP" -Check "可用網卡" -Status "FAIL" -Message "沒有找到已連線且具有 IP 位址的網卡。" -Details "請確認網路線、Wi-Fi、飛航模式、網卡驅動程式與網卡是否停用。" | Out-Null
        return
    }

    Add-CheckResult -Category "網卡與 IP" -Check "可用網卡" -Status "PASS" -Message ("找到 {0} 張已連線網卡。" -f $Adapters.Count) -Details "" | Out-Null

    foreach ($adapter in $Adapters) {
        $dhcpText = "未知"
        if ($adapter.DhcpEnabled -eq $true) { $dhcpText = "啟用" }
        elseif ($adapter.DhcpEnabled -eq $false) { $dhcpText = "停用（固定 IP）" }

        $details = @(
            "介面名稱：$($adapter.Name)",
            "介面描述：$($adapter.Description)",
            "介面索引：$($adapter.InterfaceIndex)",
            "連線速度：$($adapter.LinkSpeed)",
            "MAC 位址：$(ConvertTo-DisplayString $adapter.MacAddress)",
            "網路設定檔：$(ConvertTo-DisplayString $adapter.ProfileName)",
            "IPv4：$(ConvertTo-DisplayString $adapter.IPv4WithPrefix)",
            "IPv6：$(ConvertTo-DisplayString $adapter.IPv6Addresses)",
            "預設閘道：$(ConvertTo-DisplayString $adapter.Gateways)",
            "DNS：$(ConvertTo-DisplayString $adapter.DnsServers)",
            "DHCP：$dhcpText",
            "資料來源：$($adapter.Source)"
        ) -join [Environment]::NewLine

        $hasApipa = $false
        foreach ($ip in @($adapter.IPv4Addresses)) {
            if ([string]$ip -like "169.254.*") {
                $hasApipa = $true
                break
            }
        }

        if ($hasApipa) {
            Add-CheckResult -Category "網卡與 IP" -Check ("網卡：{0}" -f $adapter.Name) -Status "FAIL" -Message "偵測到 169.254.x.x 自動私人 IP，通常表示無法取得 DHCP 位址。" -Details $details | Out-Null
        }
        elseif (@($adapter.IPv4Addresses).Count -eq 0) {
            Add-CheckResult -Category "網卡與 IP" -Check ("網卡：{0}" -f $adapter.Name) -Status "WARN" -Message "此網卡沒有 IPv4 位址。" -Details $details | Out-Null
        }
        else {
            Add-CheckResult -Category "網卡與 IP" -Check ("網卡：{0}" -f $adapter.Name) -Status "PASS" -Message ("目前 IPv4：{0}" -f (ConvertTo-DisplayString $adapter.IPv4WithPrefix)) -Details $details | Out-Null
        }
    }

    $gateways = @()
    foreach ($adapter in $Adapters) {
        $gateways += @($adapter.Gateways)
    }
    $gateways = @($gateways | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)

    if ($gateways.Count -eq 0) {
        Add-CheckResult -Category "網卡與 IP" -Check "預設閘道" -Status "FAIL" -Message "沒有找到 IPv4 預設閘道，通常無法連到其他網段或網際網路。" -Details "" | Out-Null
    }
    else {
        Add-CheckResult -Category "網卡與 IP" -Check "預設閘道" -Status "PASS" -Message ("已設定：{0}" -f ($gateways -join ", ")) -Details "" | Out-Null
    }

    $dnsServers = @()
    foreach ($adapter in $Adapters) {
        $dnsServers += @($adapter.DnsServers)
    }
    $dnsServers = @($dnsServers | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)

    if ($dnsServers.Count -eq 0) {
        Add-CheckResult -Category "網卡與 IP" -Check "DNS 伺服器" -Status "FAIL" -Message "沒有找到 DNS 伺服器設定。" -Details "沒有 DNS 時，通常無法使用網址連線，但仍可能用 IP 位址連線。" | Out-Null
    }
    else {
        Add-CheckResult -Category "網卡與 IP" -Check "DNS 伺服器" -Status "PASS" -Message ("已設定：{0}" -f ($dnsServers -join ", ")) -Details "" | Out-Null
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
        Add-CheckResult -Category "公司規範比對" -Check "標準設定" -Status "INFO" -Message "設定檔尚未填入公司標準，因此只能顯示目前設定，不能判定 IP 是否符合公司規範。" -Details "請由 IT 人員編輯 NetworkHealthCheck.config.json 的 Expected 區段。" | Out-Null
        return
    }

    if ($Adapters.Count -eq 0) {
        Add-CheckResult -Category "公司規範比對" -Check "標準設定" -Status "FAIL" -Message "沒有可用網卡，無法比對公司標準。" -Details "" | Out-Null
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
            Add-CheckResult -Category "公司規範比對" -Check "IPv4 位址/網段" -Status "PASS" -Message ("目前 IP $matchedIp 符合允許清單。") -Details ("允許的 IP：{0}`r`n允許的網段：{1}" -f (ConvertTo-DisplayString $allowedIps), (ConvertTo-DisplayString $allowedCidrs)) | Out-Null
        }
        else {
            Add-CheckResult -Category "公司規範比對" -Check "IPv4 位址/網段" -Status "FAIL" -Message ("目前 IP 不符合允許清單：{0}" -f (ConvertTo-DisplayString $allIps)) -Details ("允許的 IP：{0}`r`n允許的網段：{1}" -f (ConvertTo-DisplayString $allowedIps), (ConvertTo-DisplayString $allowedCidrs)) | Out-Null
        }
    }

    if ($allowedPrefixes.Count -gt 0) {
        $prefixMatches = @($allPrefixes | Where-Object { $allowedPrefixes -contains [int]$_ })
        if ($prefixMatches.Count -gt 0) {
            Add-CheckResult -Category "公司規範比對" -Check "子網路前綴" -Status "PASS" -Message ("目前前綴長度符合：/{0}" -f (($prefixMatches | Select-Object -Unique) -join ", /")) -Details ("允許值：/{0}" -f ($allowedPrefixes -join ", /")) | Out-Null
        }
        else {
            Add-CheckResult -Category "公司規範比對" -Check "子網路前綴" -Status "FAIL" -Message ("目前前綴長度不符合：/{0}" -f ($allPrefixes -join ", /")) -Details ("允許值：/{0}" -f ($allowedPrefixes -join ", /")) | Out-Null
        }
    }

    if ($allowedGateways.Count -gt 0) {
        $gatewayMatches = @($allGateways | Where-Object { $allowedGateways -contains [string]$_ })
        if ($gatewayMatches.Count -gt 0) {
            Add-CheckResult -Category "公司規範比對" -Check "預設閘道" -Status "PASS" -Message ("符合：{0}" -f ($gatewayMatches -join ", ")) -Details ("允許值：{0}" -f ($allowedGateways -join ", ")) | Out-Null
        }
        else {
            Add-CheckResult -Category "公司規範比對" -Check "預設閘道" -Status "FAIL" -Message ("目前閘道不符合：{0}" -f (ConvertTo-DisplayString $allGateways)) -Details ("允許值：{0}" -f ($allowedGateways -join ", ")) | Out-Null
        }
    }

    if ($requiredDns.Count -gt 0) {
        $missingDns = @($requiredDns | Where-Object { $allDns -notcontains [string]$_ })
        if ($missingDns.Count -eq 0) {
            Add-CheckResult -Category "公司規範比對" -Check "DNS 伺服器" -Status "PASS" -Message "已包含所有必要 DNS 伺服器。" -Details ("必要值：{0}`r`n目前值：{1}" -f ($requiredDns -join ", "), (ConvertTo-DisplayString $allDns)) | Out-Null
        }
        else {
            Add-CheckResult -Category "公司規範比對" -Check "DNS 伺服器" -Status "FAIL" -Message ("缺少必要 DNS：{0}" -f ($missingDns -join ", ")) -Details ("必要值：{0}`r`n目前值：{1}" -f ($requiredDns -join ", "), (ConvertTo-DisplayString $allDns)) | Out-Null
        }
    }

    if ($hasValidDhcpRule) {
        $expectedBool = [bool]$expectedDhcp
        if ($allDhcp.Count -eq 0) {
            Add-CheckResult -Category "公司規範比對" -Check "DHCP 模式" -Status "ERROR" -Message "無法取得目前 DHCP 狀態。" -Details ("預期值：{0}" -f $(if ($expectedBool) { "啟用" } else { "停用" })) | Out-Null
        }
        else {
            $mismatches = @($allDhcp | Where-Object { [bool]$_ -ne $expectedBool })
            if ($mismatches.Count -eq 0) {
                Add-CheckResult -Category "公司規範比對" -Check "DHCP 模式" -Status "PASS" -Message ("符合預期：{0}" -f $(if ($expectedBool) { "啟用" } else { "停用（固定 IP）" })) -Details "" | Out-Null
            }
            else {
                Add-CheckResult -Category "公司規範比對" -Check "DHCP 模式" -Status "FAIL" -Message ("DHCP 模式不符合，預期：{0}" -f $(if ($expectedBool) { "啟用" } else { "停用（固定 IP）" })) -Details ("目前狀態：{0}" -f (($allDhcp | ForEach-Object { if ($_){"啟用"}else{"停用"} }) -join ", ")) | Out-Null
            }
        }
    }
}

# -----------------------------------------------------------------------------
# 主動連線測試：Ping、DNS、TCP 與 HTTP/HTTPS；每項測試都有逾時及錯誤隔離。
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
                    [void]$attemptDetails.Add(("第 {0} 次：成功，{1} ms，回覆 {2}" -f $i, $reply.RoundtripTime, $reply.Address))
                }
                else {
                    [void]$attemptDetails.Add(("第 {0} 次：失敗，狀態 {1}" -f $i, $reply.Status))
                }
            }
            catch {
                [void]$attemptDetails.Add(("第 {0} 次：錯誤，{1}" -f $i, $_.Exception.Message))
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
    $warningLoss = [double](ConvertTo-IntSafe $script:Config.Thresholds.PacketLossWarningPercent 5)
    $criticalLoss = [double](ConvertTo-IntSafe $script:Config.Thresholds.PacketLossCriticalPercent 20)
    $warningLatency = [double](ConvertTo-IntSafe $script:Config.Thresholds.LatencyWarningMs 100)
    $criticalLatency = [double](ConvertTo-IntSafe $script:Config.Thresholds.LatencyCriticalMs 250)

    foreach ($targetConfig in @($script:Config.Tests.PingTargets)) {
        if ($null -eq $targetConfig) { continue }

        $name = ConvertTo-SafeString (Get-PropertyValue $targetConfig "Name" "Ping")
        $address = ConvertTo-SafeString (Get-PropertyValue $targetConfig "Address" "")
        $required = [bool](Get-PropertyValue $targetConfig "Required" $false)
        $targets = @(Resolve-PingTargets -Address $address -PrimaryAdapters $PrimaryAdapters)

        if ($targets.Count -eq 0) {
            $status = if ($required) { "FAIL" } else { "WARN" }
            Add-CheckResult -Category "延遲與封包遺失" -Check $name -Status $status -Message "找不到可測試的目標。" -Details ("設定值：$address" + [Environment]::NewLine + ("檢測方式：.NET Ping — {0} 次 ICMP echo，逾時 {1} ms。" -f $count, $timeout) + [Environment]::NewLine + "手動驗證：ping -n $count <目標 IP>") | Out-Null
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

                $latencyText = "無成功回覆"
                if ($null -ne $measurement.AverageMs) {
                    $latencyText = ("平均 {0} ms（最低 {1}、最高 {2}）" -f $measurement.AverageMs, $measurement.MinimumMs, $measurement.MaximumMs)
                }

                $message = "目標 {0}：遺失 {1}%（{2}/{3} 成功），{4}。" -f $target, $measurement.LossPercent, $measurement.Received, $measurement.Sent, $latencyText
                $details = (@($measurement.AttemptDetails) + ("檢測方式：.NET Ping — {0} 次 ICMP echo，逾時 {1} ms。" -f $count, $timeout) + ("手動驗證：ping -n {0} {1}" -f $count, $target)) -join [Environment]::NewLine
                Add-CheckResult -Category "延遲與封包遺失" -Check ("{0}：{1}" -f $name, $target) -Status $status -Message $message -Details $details | Out-Null
            }
            catch {
                $status = if ($required) { "ERROR" } else { "INFO" }
                Add-CheckResult -Category "延遲與封包遺失" -Check ("{0}：{1}" -f $name, $target) -Status $status -Message "Ping 測試無法執行。" -Details (Get-ExceptionDetails $_) | Out-Null
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
        throw "DNS 查詢逾時（超過 $TimeoutMs ms）。"
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
    $methodText = "檢測方式：System.Net.Dns.GetHostAddressesAsync 經作業系統解析，逾時 $timeout ms。"

    foreach ($dnsConfig in @($script:Config.Tests.DnsNames)) {
        if ($null -eq $dnsConfig) { continue }

        if ($dnsConfig -is [string]) {
            $name = "DNS 名稱解析"
            $hostName = [string]$dnsConfig
            $required = $true
        }
        else {
            $name = ConvertTo-SafeString (Get-PropertyValue $dnsConfig "Name" "DNS 名稱解析")
            $hostName = ConvertTo-SafeString (Get-PropertyValue $dnsConfig "Host" "")
            $required = [bool](Get-PropertyValue $dnsConfig "Required" $true)
        }

        if ([string]::IsNullOrWhiteSpace($hostName)) {
            continue
        }

        try {
            $result = Invoke-DnsLookup -HostName $hostName -TimeoutMs $timeout
            if ($result.Addresses.Count -gt 0) {
                Add-CheckResult -Category "DNS" -Check $name -Status "PASS" -Message ("{0} 已解析為 {1}（{2} ms）。" -f $hostName, ($result.Addresses -join ", "), $result.ElapsedMs) -Details ($methodText + [Environment]::NewLine + "手動驗證：nslookup $hostName") | Out-Null
            }
            else {
                $status = if ($required) { "FAIL" } else { "WARN" }
                Add-CheckResult -Category "DNS" -Check $name -Status $status -Message ("$hostName 沒有回傳 IP 位址。") -Details ($methodText + [Environment]::NewLine + "手動驗證：nslookup $hostName") | Out-Null
            }
        }
        catch {
            $status = if ($required) { "FAIL" } else { "WARN" }
            Add-CheckResult -Category "DNS" -Check $name -Status $status -Message ("無法解析 $hostName。") -Details ((Get-ExceptionDetails $_) + [Environment]::NewLine + $methodText + [Environment]::NewLine + "手動驗證：nslookup $hostName") | Out-Null
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
            throw "TCP 連線逾時（超過 $TimeoutMs ms）。"
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
                Error        = "已收到 HTTP 回應，代表網路路徑可達；伺服器回傳非成功狀態。"
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
        Add-CheckResult -Category "連線能力" -Check ("群組：$GroupName") -Status $status -Message "此群組沒有可執行的測試項目。" -Details "請檢查設定檔中的 Group 名稱與測試目標。" | Out-Null
        return
    }

    $successful = @($entries | Where-Object { $_.Success })
    if ($successful.Count -gt 0) {
        $names = @($successful | ForEach-Object { $_.Name })
        Add-CheckResult -Category "連線能力" -Check ("群組：$GroupName") -Status "PASS" -Message ("至少一種連線方式成功：{0}" -f ($names -join ", ")) -Details (("成功 {0}/{1} 項。" -f $successful.Count, $entries.Count) + [Environment]::NewLine + "檢測方式：群組內任一連線測試成功即通過。") | Out-Null
    }
    else {
        $status = if ($Required) { "FAIL" } else { "WARN" }
        $details = (@($entries | ForEach-Object { "{0}：{1}" -f $_.Name, $_.Error }) + "檢測方式：群組內任一連線測試成功即通過。") -join [Environment]::NewLine
        Add-CheckResult -Category "連線能力" -Check ("群組：$GroupName") -Status $status -Message "所有連線方式都失敗。" -Details $details | Out-Null
    }
}

function Test-ConnectivityTargets {
    $tcpTimeout = [math]::Max(500, (ConvertTo-IntSafe $script:Config.Tests.TcpTimeoutMs 4000))
    $httpTimeout = [math]::Max(500, (ConvertTo-IntSafe $script:Config.Tests.HttpTimeoutMs 6000))
    $tcpMethod = "檢測方式：TcpClient.BeginConnect，逾時 $tcpTimeout ms。"
    $httpMethod = "檢測方式：HttpWebRequest GET（系統 Proxy、TLS 1.2），逾時 $httpTimeout ms。"
    $groupResults = @{}

    foreach ($target in @($script:Config.Tests.TcpTargets)) {
        if ($null -eq $target) { continue }

        $name = ConvertTo-SafeString (Get-PropertyValue $target "Name" "TCP 連線")
        $hostName = ConvertTo-SafeString (Get-PropertyValue $target "Host" "")
        $port = ConvertTo-IntSafe (Get-PropertyValue $target "Port" 0) 0
        $required = [bool](Get-PropertyValue $target "Required" $false)
        $group = ConvertTo-SafeString (Get-PropertyValue $target "Group" "")

        if ([string]::IsNullOrWhiteSpace($hostName) -or $port -lt 1 -or $port -gt 65535) {
            if ($required) {
                Add-CheckResult -Category "TCP 連線" -Check $name -Status "ERROR" -Message "設定的主機或連接埠無效。" -Details ("Host=$hostName, Port=$port") | Out-Null
            }
            continue
        }

        $result = Invoke-TcpConnectionTest -HostName $hostName -Port $port -TimeoutMs $tcpTimeout
        if ($result.Success) {
            Add-CheckResult -Category "TCP 連線" -Check $name -Status "PASS" -Message ("可連線至 {0}:{1}，耗時 {2} ms。" -f $hostName, $port, $result.ElapsedMs) -Details ($tcpMethod + [Environment]::NewLine + "手動驗證：Test-NetConnection $hostName -Port $port") | Out-Null
        }
        else {
            $status = if ($required) { "FAIL" } else { "INFO" }
            Add-CheckResult -Category "TCP 連線" -Check $name -Status $status -Message ("無法連線至 {0}:{1}。" -f $hostName, $port) -Details ($result.Error + [Environment]::NewLine + $tcpMethod + [Environment]::NewLine + "手動驗證：Test-NetConnection $hostName -Port $port") | Out-Null
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

        $name = ConvertTo-SafeString (Get-PropertyValue $target "Name" "HTTP/HTTPS 連線")
        $url = ConvertTo-SafeString (Get-PropertyValue $target "Url" "")
        $required = [bool](Get-PropertyValue $target "Required" $false)
        $group = ConvertTo-SafeString (Get-PropertyValue $target "Group" "")

        if ([string]::IsNullOrWhiteSpace($url)) {
            if ($required) {
                Add-CheckResult -Category "HTTP/HTTPS" -Check $name -Status "ERROR" -Message "URL 設定為空白。" -Details "" | Out-Null
            }
            continue
        }

        $result = Invoke-HttpConnectionTest -Url $url -TimeoutMs $httpTimeout
        if ($result.Success) {
            Add-CheckResult -Category "HTTP/HTTPS" -Check $name -Status "PASS" -Message ("HTTP {0}，耗時 {1} ms。" -f $result.StatusCode, $result.ElapsedMs) -Details ("原始網址：{0}`r`n最終網址：{1}`r`n狀態：{2}`r`n{3}`r`n手動驗證：Invoke-WebRequest {0} -UseBasicParsing" -f $url, $result.FinalUrl, $result.StatusText, $httpMethod) | Out-Null
        }
        else {
            $status = if ($required) { "FAIL" } else { "INFO" }
            Add-CheckResult -Category "HTTP/HTTPS" -Check $name -Status $status -Message ("無法連線：$url") -Details ($result.Error + [Environment]::NewLine + $httpMethod + [Environment]::NewLine + "手動驗證：Invoke-WebRequest $url -UseBasicParsing") | Out-Null
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
# 計數器取樣：比較網卡錯誤/丟棄與 TCP 傳送/重傳的前後累積值。
# -----------------------------------------------------------------------------
function Get-AdapterStatisticsSnapshot {
    if (-not (Get-Command Get-NetAdapterStatistics -ErrorAction SilentlyContinue)) {
        throw "此系統沒有 Get-NetAdapterStatistics 指令。"
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
            Add-CheckResult -Category "網卡錯誤計數" -Check $name -Status "INFO" -Message "無法取得完整的前後比較資料。" -Details "網卡可能在檢測期間切換、重新連線或名稱不同。" | Out-Null
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
                "起始：RxErrors=$($beforeItem.ReceivedPacketErrors), TxErrors=$($beforeItem.OutboundPacketErrors), RxDiscards=$($beforeItem.ReceivedDiscardedPackets), TxDiscards=$($beforeItem.OutboundDiscardedPackets), RxBytes=$($beforeItem.ReceivedBytes), TxBytes=$($beforeItem.SentBytes)",
                "結束：RxErrors=$($afterItem.ReceivedPacketErrors), TxErrors=$($afterItem.OutboundPacketErrors), RxDiscards=$($afterItem.ReceivedDiscardedPackets), TxDiscards=$($afterItem.OutboundDiscardedPackets), RxBytes=$($afterItem.ReceivedBytes), TxBytes=$($afterItem.SentBytes)"
            ) -join [Environment]::NewLine
            Add-CheckResult -Category "網卡錯誤計數" -Check $name -Status "WARN" -Message "網卡計數器在檢測期間重設，可能曾重新連線或重啟；無法可靠計算增量。" -Details $resetDetails | Out-Null
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

        $message = "檢測期間新增錯誤 {0}、丟棄 {1}。" -f $errorDelta, $discardDelta
        $details = @(
            "接收錯誤增量：$rxErrorDelta（累積 $($afterItem.ReceivedPacketErrors)）",
            "傳送錯誤增量：$txErrorDelta（累積 $($afterItem.OutboundPacketErrors)）",
            "接收丟棄增量：$rxDiscardDelta（累積 $($afterItem.ReceivedDiscardedPackets)）",
            "傳送丟棄增量：$txDiscardDelta（累積 $($afterItem.OutboundDiscardedPackets)）",
            "接收位元組累積：$($afterItem.ReceivedBytes)",
            "傳送位元組累積：$($afterItem.SentBytes)",
            "檢測方式：Get-NetAdapterStatistics 測試前後取樣，顯示增量。",
            "手動驗證：Get-NetAdapterStatistics -Name '$name'"
        ) -join [Environment]::NewLine

        Add-CheckResult -Category "網卡錯誤計數" -Check $name -Status $status -Message $message -Details $details | Out-Null
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
    throw "系統沒有可用的 CIM/WMI 指令。"
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
                throw "效能計數器類別 $className 沒有回傳資料。"
            }
            if ($null -eq $counter.PSObject.Properties["SegmentsSentPersec"] -or
                $null -eq $counter.PSObject.Properties["SegmentsRetransmittedPersec"]) {
                throw "效能計數器類別 $className 缺少必要欄位。"
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
                Protocol = $protocol
                Error    = Get-ExceptionDetails $_
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
        Add-CheckResult -Category "TCP 重傳" -Check "系統計數器" -Status "ERROR" -Message "沒有完整的前後 TCP 計數器資料。" -Details "" | Out-Null
        return
    }

    $counterErrors = @()
    $counterErrors += @($Before.Errors)
    $counterErrors += @($After.Errors)
    foreach ($errorItem in $counterErrors) {
        Add-CheckResult -Category "TCP 重傳" -Check ("{0} 計數器" -f $errorItem.Protocol) -Status "ERROR" -Message "無法讀取 TCP 重傳計數器。" -Details $errorItem.Error | Out-Null
    }

    $warningPercent = [double](Get-PropertyValue $script:Config.Thresholds "TcpRetransmissionWarningPercent" 2)
    $criticalPercent = [double](Get-PropertyValue $script:Config.Thresholds "TcpRetransmissionCriticalPercent" 5)
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
            Add-CheckResult -Category "TCP 重傳" -Check $protocol -Status "ERROR" -Message "計數器在檢測期間重設或溢位，無法計算增量。" -Details ("起始 Sent={0}, Retrans={1}; 結束 Sent={2}, Retrans={3}" -f $start.SegmentsSent, $start.Retransmitted, $end.SegmentsSent, $end.Retransmitted) | Out-Null
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
            "取樣時間：$sampleSeconds 秒",
            "傳送 TCP Segments 增量：$sentDelta",
            "重傳 Segments 增量：$retransDelta",
            "近似重傳比例：$rate%",
            "起始累積：Sent=$($start.SegmentsSent), Retrans=$($start.Retransmitted)",
            "結束累積：Sent=$($end.SegmentsSent), Retrans=$($end.Retransmitted)",
            "檢測方式：Win32_PerfRawData_Tcpip_$protocol 累積計數器，取樣期間增量。",
            "手動驗證：Get-CimInstance Win32_PerfRawData_Tcpip_$protocol（取樣兩次比較增量）",
            "說明：此為整台電腦在檢測期間的系統級統計，不只包含單一程式。"
        ) -join [Environment]::NewLine

        if ($sentDelta -eq 0 -and $retransDelta -eq 0) {
            Add-CheckResult -Category "TCP 重傳" -Check $protocol -Status "INFO" -Message "取樣期間沒有足夠的 TCP 傳送流量，未發現重傳，但不能據此判定長時間狀況。" -Details $details | Out-Null
            continue
        }

        if ($sentDelta -lt $minimumSegments) {
            if ($retransDelta -gt 0) {
                Add-CheckResult -Category "TCP 重傳" -Check $protocol -Status "WARN" -Message ("流量樣本偏少，但觀察到 {0} 次重傳（近似 {1}%）。" -f $retransDelta, $rate) -Details $details | Out-Null
            }
            else {
                Add-CheckResult -Category "TCP 重傳" -Check $protocol -Status "INFO" -Message ("樣本只有 {0} 個傳送 segment，未觀察到重傳。" -f $sentDelta) -Details $details | Out-Null
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

        Add-CheckResult -Category "TCP 重傳" -Check $protocol -Status $status -Message ("傳送 {0}、重傳 {1}，近似重傳比例 {2}%。" -f $sentDelta, $retransDelta, $rate) -Details $details | Out-Null
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
        Set-UiProgress -Percent 87 -Text ("TCP 重傳取樣中，尚餘約 $i 秒")
        Start-Sleep -Seconds 1
        if ($script:GuiAvailable) {
            [System.Windows.Forms.Application]::DoEvents()
        }
    }
}

# -----------------------------------------------------------------------------
# 結果彙總：整體狀態優先序為 FAIL > ERROR > WARN > PASS。
# -----------------------------------------------------------------------------
function Get-OverallStatus {
    $failCount = @($script:Results | Where-Object { $_.Status -eq "FAIL" }).Count
    $errorCount = @($script:Results | Where-Object { $_.Status -eq "ERROR" }).Count
    $warnCount = @($script:Results | Where-Object { $_.Status -eq "WARN" }).Count

    if ($failCount -gt 0) {
        return [pscustomobject]@{
            Code = "FAIL"
            Text = "偵測到異常"
            Description = "至少一項必要檢查未通過。"
        }
    }
    if ($errorCount -gt 0) {
        return [pscustomobject]@{
            Code = "ERROR"
            Text = "檢測未完整"
            Description = "部分檢查因權限、系統元件或執行錯誤而無法完成。"
        }
    }
    if ($warnCount -gt 0) {
        return [pscustomobject]@{
            Code = "WARN"
            Text = "需要注意"
            Description = "沒有必要項目失敗，但有警告或品質異常。"
        }
    }
    return [pscustomobject]@{
        Code = "PASS"
        Text = "整體正常"
        Description = "本次可執行的必要檢查均通過。"
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
# 報告輸出：產生 HTML、TXT、JSON；任一寫入錯誤都會留下詳細例外。
# -----------------------------------------------------------------------------
function New-HtmlReportContent {
    param(
        [object]$SystemSummary,
        [object]$Overall,
        [object]$Counts
    )

    $organization = ConvertTo-SafeString $script:Config.OrganizationName
    if ([string]::IsNullOrWhiteSpace($organization)) {
        $organization = "未指定單位"
    }

    $rows = New-Object System.Text.StringBuilder
    foreach ($result in $script:Results) {
        $statusClass = ([string]$result.Status).ToLowerInvariant()
        $detailsHtml = ""
        if (-not [string]::IsNullOrWhiteSpace([string]$result.Details)) {
            $detailsEncoded = ConvertTo-HtmlEncoded $result.Details
            $detailsHtml = "<details><summary>顯示詳細資料</summary><pre>$detailsEncoded</pre></details>"
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
<html lang="zh-Hant">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>網路健檢報告 - $(ConvertTo-HtmlEncoded $env:COMPUTERNAME)</title>
<style>
:root { color-scheme: light; }
body { margin: 0; font-family: "Microsoft JhengHei UI", "Microsoft JhengHei", Arial, sans-serif; background: #f4f6f8; color: #1f2933; }
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
  <h1>網路健檢報告</h1>
  <p>單位：$(ConvertTo-HtmlEncoded $organization)　電腦：$(ConvertTo-HtmlEncoded $SystemSummary.ComputerName)</p>
  <p>產生時間：$(ConvertTo-HtmlEncoded $generatedAt)　檢測耗時：約 $(ConvertTo-HtmlEncoded $duration) 秒</p>
</header>
<main>
  <div class="overall $overallClass">
    <h2>$(ConvertTo-HtmlEncoded $Overall.Text)</h2>
    <div>$(ConvertTo-HtmlEncoded $Overall.Description)</div>
  </div>

  <div class="cards">
    <div class="card">正常<strong>$($Counts.Pass)</strong></div>
    <div class="card">需注意<strong>$($Counts.Warn)</strong></div>
    <div class="card">異常<strong>$($Counts.Fail)</strong></div>
    <div class="card">無法檢查<strong>$($Counts.Error)</strong></div>
    <div class="card">資訊<strong>$($Counts.Info)</strong></div>
    <div class="card">合計<strong>$($Counts.Total)</strong></div>
  </div>

  <section>
    <h2>電腦與執行資訊</h2>
    <div class="meta">
      <div>電腦名稱</div><div>$(ConvertTo-HtmlEncoded $SystemSummary.ComputerName)</div>
      <div>使用者</div><div>$(ConvertTo-HtmlEncoded $SystemSummary.UserName)</div>
      <div>作業系統</div><div>$(ConvertTo-HtmlEncoded $SystemSummary.OperatingSystem) ($(ConvertTo-HtmlEncoded $SystemSummary.OperatingVersion))</div>
      <div>PowerShell</div><div>$(ConvertTo-HtmlEncoded $SystemSummary.PowerShellVersion)</div>
      <div>工具版本</div><div>$(ConvertTo-HtmlEncoded $SystemSummary.ToolVersion)</div>
      <div>設定檔</div><div>$(ConvertTo-HtmlEncoded $SystemSummary.ConfigPath)</div>
      <div>報告目錄</div><div>$(ConvertTo-HtmlEncoded $SystemSummary.ReportDirectory)</div>
    </div>
  </section>

  <section>
    <h2>檢測結果</h2>
    <div class="notice">「無法檢查」表示該步驟因權限、系統元件、公司政策或執行錯誤而沒有完成，不等同於網路本身一定異常。TCP 重傳比例為本機在本次取樣期間的系統級近似值。</div>
    <div style="overflow-x:auto; margin-top:14px;">
      <table>
        <thead><tr><th>時間</th><th>分類</th><th>檢查項目</th><th>結果</th><th>說明</th></tr></thead>
        <tbody>
$($rows.ToString())
        </tbody>
      </table>
    </div>
  </section>

  <footer>NetworkHealthCheck $($script:ToolVersion)。本工具只讀取系統資訊並執行連線測試，不會修改 IP、DNS、路由或防火牆設定。</footer>
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
    [void]$builder.AppendLine("網路健檢報告")
    [void]$builder.AppendLine("=" * 72)
    [void]$builder.AppendLine("整體結果：$($Overall.Text)")
    [void]$builder.AppendLine("說明：$($Overall.Description)")
    [void]$builder.AppendLine("電腦名稱：$($SystemSummary.ComputerName)")
    [void]$builder.AppendLine("使用者：$($SystemSummary.UserName)")
    [void]$builder.AppendLine("作業系統：$($SystemSummary.OperatingSystem) ($($SystemSummary.OperatingVersion))")
    [void]$builder.AppendLine("PowerShell：$($SystemSummary.PowerShellVersion)")
    [void]$builder.AppendLine("工具版本：$($SystemSummary.ToolVersion)")
    [void]$builder.AppendLine("開始時間：$($script:RunStartedAt.ToString('yyyy-MM-dd HH:mm:ss'))")
    [void]$builder.AppendLine("結束時間：$($script:RunFinishedAt.ToString('yyyy-MM-dd HH:mm:ss'))")
    [void]$builder.AppendLine("設定檔：$($SystemSummary.ConfigPath)")
    [void]$builder.AppendLine("報告目錄：$($SystemSummary.ReportDirectory)")
    [void]$builder.AppendLine("統計：正常 $($Counts.Pass)、需注意 $($Counts.Warn)、異常 $($Counts.Fail)、無法檢查 $($Counts.Error)、資訊 $($Counts.Info)，合計 $($Counts.Total)")
    [void]$builder.AppendLine("")

    foreach ($result in $script:Results) {
        [void]$builder.AppendLine(("[{0}] [{1}] {2}／{3}" -f (Get-StatusText $result.Status), $result.Time.ToString("HH:mm:ss"), $result.Category, $result.Check))
        [void]$builder.AppendLine("  $($result.Message)")
        if (-not [string]::IsNullOrWhiteSpace([string]$result.Details)) {
            foreach ($line in ([string]$result.Details -split "`r?`n")) {
                [void]$builder.AppendLine("    $line")
            }
        }
        [void]$builder.AppendLine("")
    }

    [void]$builder.AppendLine("注意：『無法檢查』表示該步驟沒有完成，不等同於網路一定異常。TCP 重傳為整台電腦在本次取樣期間的系統級近似統計。")
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
        [void]$writeErrors.Add("HTML 報告寫入失敗：$(Get-ExceptionDetails $_)")
    }

    try {
        $text = New-TextReportContent -SystemSummary $systemSummary -Overall $overall -Counts $counts
        Write-Utf8File -Path $textPath -Content $text
        $script:LastTextReport = $textPath
    }
    catch {
        [void]$writeErrors.Add("文字報告寫入失敗：$(Get-ExceptionDetails $_)")
    }

    try {
        $json = $reportObject | ConvertTo-Json -Depth 10
        Write-Utf8File -Path $jsonPath -Content $json
        $script:LastJsonReport = $jsonPath
    }
    catch {
        [void]$writeErrors.Add("JSON 報告寫入失敗：$(Get-ExceptionDetails $_)")
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

    $partialResults = "（尚無檢測結果）"
    if ($null -ne $script:Results -and $script:Results.Count -gt 0) {
        $partialBuilder = New-Object System.Text.StringBuilder
        foreach ($result in $script:Results) {
            [void]$partialBuilder.AppendLine(("[{0}] {1}／{2}：{3}" -f (Get-StatusText $result.Status), $result.Category, $result.Check, $result.Message))
            if (-not [string]::IsNullOrWhiteSpace([string]$result.Details)) {
                [void]$partialBuilder.AppendLine([string]$result.Details)
            }
            [void]$partialBuilder.AppendLine("")
        }
        $partialResults = $partialBuilder.ToString()
    }

    $content = @"
$Title

時間：$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
電腦：$env:COMPUTERNAME
使用者：$([System.Environment]::UserName)
PowerShell：$($PSVersionTable.PSVersion)
腳本路徑：$(Join-Path $script:BaseDirectory "NetworkHealthCheck.ps1")
設定檔：$script:EffectiveConfigPath

錯誤內容：
$ErrorDetails

發生錯誤前已完成的檢測：
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
        $script:OverallLabel.Text = "結果：$($Overall.Text) — $($Overall.Description)"
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
# 執行流程協調：按固定順序執行檢測，單一步驟失敗不阻止後續步驟。
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
        $script:OverallLabel.Text = "結果：檢測進行中"
        $script:OverallLabel.ForeColor = [System.Drawing.Color]::FromArgb(31, 41, 51)
        $script:ReportPathLabel.Text = "報告尚未產生"
    }

    Write-UiLog -Status "INFO" -Text "網路健檢開始。檢測只讀取資訊，不會修改網路設定。"
    Set-UiProgress -Percent 2 -Text "初始化"

    if ($null -ne $script:ConfigLoadError) {
        Add-CheckResult -Category "程式設定" -Check "設定檔" -Status "ERROR" -Message "設定檔無法載入，已使用內建預設值。" -Details $script:ConfigLoadError | Out-Null
    }
    else {
        Add-CheckResult -Category "程式設定" -Check "設定檔" -Status "PASS" -Message ("已載入：{0}" -f $script:EffectiveConfigPath) -Details "" | Out-Null
    }

    foreach ($startupMessage in @($script:StartupMessages)) {
        Add-CheckResult -Category "程式環境" -Check "啟動提示" -Status "WARN" -Message $startupMessage -Details "" | Out-Null
    }

    Invoke-CheckStep -Category "程式設定" -Name "驗證設定值" -Progress 4 -Action {
        Test-ConfigurationSemantics
    } | Out-Null

    if (-not (Test-IsWindowsPlatform)) {
        Add-CheckResult -Category "程式環境" -Check "作業系統" -Status "FAIL" -Message "此版本只支援 Windows 10/11 或相容 Windows Server。" -Details ([System.Environment]::OSVersion.VersionString) | Out-Null
        $script:RunFinishedAt = Get-Date
        $report = Save-Reports
        return $report
    }

    if ($PSVersionTable.PSVersion.Major -lt 5) {
        Add-CheckResult -Category "程式環境" -Check "PowerShell 版本" -Status "FAIL" -Message "需要 PowerShell 5.1 或更新版本。" -Details ("目前版本：{0}" -f $PSVersionTable.PSVersion) | Out-Null
        $script:RunFinishedAt = Get-Date
        $report = Save-Reports
        return $report
    }
    else {
        Add-CheckResult -Category "程式環境" -Check "PowerShell 版本" -Status "PASS" -Message ("目前版本：{0}" -f $PSVersionTable.PSVersion) -Details "" | Out-Null
    }

    $systemSummary = Invoke-CheckStep -Category "系統資訊" -Name "取得電腦與作業系統資訊" -Progress 7 -Action {
        $summary = Get-SystemSummary
        Add-CheckResult -Category "系統資訊" -Check "電腦" -Status "INFO" -Message ("{0}，使用者 {1}。" -f $summary.ComputerName, $summary.UserName) -Details ("作業系統：{0} ({1})`r`nPowerShell：{2}" -f $summary.OperatingSystem, $summary.OperatingVersion, $summary.PowerShellVersion) | Out-Null
        return $summary
    }

    $tcpBaseline = Invoke-CheckStep -Category "TCP 重傳" -Name "取得 TCP 重傳基準值" -Progress 10 -Action {
        $snapshot = Get-TcpCounterSnapshot
        if ($snapshot.Counters.Count -eq 0) {
            throw "TCPv4 與 TCPv6 計數器都無法讀取。"
        }
        return $snapshot
    }
    $tcpSampleStart = Get-Date

    $adapterStatsBefore = Invoke-CheckStep -Category "網卡錯誤計數" -Name "取得網卡錯誤基準值" -Progress 13 -Action {
        return (Get-AdapterStatisticsSnapshot)
    }

    $networkSnapshot = Invoke-CheckStep -Category "網卡與 IP" -Name "取得網卡、IP、閘道與 DNS" -Progress 20 -Action {
        return @(Get-NetworkSnapshot)
    }

    if ($null -eq $networkSnapshot) {
        $networkSnapshot = @()
    }
    else {
        $networkSnapshot = @($networkSnapshot)
    }
    $script:NetworkSnapshot = $networkSnapshot
    $script:PrimaryAdapters = @(Get-PrimaryAdapters -Adapters $networkSnapshot)

    Invoke-CheckStep -Category "網卡與 IP" -Name "檢查目前網路設定" -Progress 28 -Action {
        Add-NetworkSnapshotResults -Adapters $networkSnapshot
    } | Out-Null

    Invoke-CheckStep -Category "公司規範比對" -Name "比對公司標準 IP 設定" -Progress 36 -Action {
        Test-ExpectedNetworkConfiguration -Adapters $script:PrimaryAdapters
    } | Out-Null

    Invoke-CheckStep -Category "延遲與封包遺失" -Name "測試預設閘道與網路品質" -Progress 46 -Action {
        Test-PingTargets -PrimaryAdapters $script:PrimaryAdapters
    } | Out-Null

    Invoke-CheckStep -Category "DNS" -Name "測試 DNS 名稱解析" -Progress 60 -Action {
        Test-DnsNames
    } | Out-Null

    Invoke-CheckStep -Category "連線能力" -Name "測試 TCP 與 HTTP/HTTPS 連線" -Progress 70 -Action {
        Test-ConnectivityTargets
    } | Out-Null

    $minimumSampleSeconds = [math]::Max(1, (ConvertTo-IntSafe $script:Config.Tests.RetransmissionSampleSeconds 8))
    Wait-ForMinimumTcpSample -StartTime $tcpSampleStart -MinimumSeconds $minimumSampleSeconds

    $adapterStatsAfter = Invoke-CheckStep -Category "網卡錯誤計數" -Name "取得網卡錯誤結束值" -Progress 82 -Action {
        return (Get-AdapterStatisticsSnapshot)
    }

    Invoke-CheckStep -Category "網卡錯誤計數" -Name "分析網卡錯誤與丟棄" -Progress 85 -Action {
        if ($null -eq $adapterStatsBefore -or $null -eq $adapterStatsAfter) {
            Add-CheckResult -Category "網卡錯誤計數" -Check "前後比較" -Status "ERROR" -Message "缺少基準值或結束值，無法計算錯誤增量。" -Details "" | Out-Null
        }
        else {
            Compare-AdapterStatistics -Before $adapterStatsBefore -After $adapterStatsAfter -Adapters $networkSnapshot
        }
    } | Out-Null

    $tcpAfter = Invoke-CheckStep -Category "TCP 重傳" -Name "取得 TCP 重傳結束值" -Progress 89 -Action {
        return (Get-TcpCounterSnapshot)
    }

    Invoke-CheckStep -Category "TCP 重傳" -Name "分析 TCP 重傳" -Progress 92 -Action {
        Compare-TcpCounters -Before $tcpBaseline -After $tcpAfter
    } | Out-Null

    $script:RunFinishedAt = Get-Date
    Set-UiProgress -Percent 96 -Text "產生報告"
    Write-UiLog -Status "INFO" -Text "正在產生 HTML、文字與 JSON 報告。"

    try {
        $report = Save-Reports
        Set-UiProgress -Percent 100 -Text "檢測完成"
        Write-UiLog -Status "PASS" -Text ("報告已產生：{0}" -f $report.Html)
        Update-OverallUi -Overall $report.Overall

        if ($script:GuiAvailable) {
            $script:ReportPathLabel.Text = "報告：$($report.Html)"
            $script:OpenReportButton.Enabled = $true
            $script:OpenFolderButton.Enabled = $true
        }

        return $report
    }
    catch {
        $details = Get-ExceptionDetails $_
        Write-UiLog -Status "ERROR" -Text "報告產生失敗。"
        $emergencyPath = Write-EmergencyReport -Title "網路健檢報告產生失敗" -ErrorDetails $details
        if ($script:GuiAvailable) {
            $message = "報告產生失敗。"
            if ($null -ne $emergencyPath) {
                $message += "`r`n已寫入緊急錯誤報告：$emergencyPath"
            }
            [System.Windows.Forms.MessageBox]::Show($message, "網路健檢錯誤", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        }
        throw
    }
    finally {
        $script:IsRunning = $false
        if ($script:GuiAvailable) {
            $script:StartButton.Enabled = $true
            $script:StartButton.Text = "重新檢測"
        }
    }
}

function Start-ConsoleMode {
    try {
        $report = Run-AllChecks
        Write-Host ""
        Write-Host ("整體結果：{0}" -f $report.Overall.Text)
        Write-Host ("HTML 報告：{0}" -f $report.Html)
        Write-Host ("文字報告：{0}" -f $report.Text)
        Write-Host ("JSON 報告：{0}" -f $report.Json)
        return 0
    }
    catch {
        $details = Get-ExceptionDetails $_
        Write-Host "網路健檢發生未處理錯誤。" -ForegroundColor Red
        Write-Host $details
        $emergencyPath = Write-EmergencyReport -Title "網路健檢未處理錯誤" -ErrorDetails $details
        if ($null -ne $emergencyPath) {
            Write-Host "緊急錯誤報告：$emergencyPath"
        }
        return 1
    }
}

# -----------------------------------------------------------------------------
# 使用者介面：Windows Forms 圖形介面；無法載入時由外層切換至文字模式。
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
        [void]$script:StartupMessages.Add("圖形介面無法啟動，已改用文字模式。錯誤：$($_.Exception.Message)")
        return $false
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "網路健檢工具 $($script:ToolVersion)"
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
    $header.Text = "Windows 網路健檢"
    $header.Font = New-Object System.Drawing.Font($form.Font.FontFamily, 18, [System.Drawing.FontStyle]::Bold)
    $header.AutoSize = $true
    $header.Location = New-Object System.Drawing.Point(20, 16)
    $form.Controls.Add($header)

    $subtitle = New-Object System.Windows.Forms.Label
    $subtitle.Text = "自動檢查網卡、IP、閘道、DNS、封包遺失、服務連線、網卡錯誤與 TCP 重傳。"
    $subtitle.AutoSize = $true
    $subtitle.Location = New-Object System.Drawing.Point(22, 54)
    $form.Controls.Add($subtitle)

    $overall = New-Object System.Windows.Forms.Label
    $overall.Text = "結果：尚未開始"
    $overall.Font = New-Object System.Drawing.Font($form.Font.FontFamily, 11, [System.Drawing.FontStyle]::Bold)
    $overall.AutoSize = $false
    $overall.Location = New-Object System.Drawing.Point(22, 84)
    $overall.Size = New-Object System.Drawing.Size(880, 28)
    $overall.Anchor = "Top,Left,Right"
    $form.Controls.Add($overall)

    $progressLabel = New-Object System.Windows.Forms.Label
    $progressLabel.Text = "準備中"
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
    $startButton.Text = "開始檢測"
    $startButton.Location = New-Object System.Drawing.Point(22, 584)
    $startButton.Size = New-Object System.Drawing.Size(120, 34)
    $startButton.Anchor = "Bottom,Left"
    $form.Controls.Add($startButton)

    $openReportButton = New-Object System.Windows.Forms.Button
    $openReportButton.Text = "開啟報告"
    $openReportButton.Location = New-Object System.Drawing.Point(152, 584)
    $openReportButton.Size = New-Object System.Drawing.Size(120, 34)
    $openReportButton.Anchor = "Bottom,Left"
    $openReportButton.Enabled = $false
    $form.Controls.Add($openReportButton)

    $openFolderButton = New-Object System.Windows.Forms.Button
    $openFolderButton.Text = "開啟報告資料夾"
    $openFolderButton.Location = New-Object System.Drawing.Point(282, 584)
    $openFolderButton.Size = New-Object System.Drawing.Size(150, 34)
    $openFolderButton.Anchor = "Bottom,Left"
    $openFolderButton.Enabled = $false
    $form.Controls.Add($openFolderButton)

    $closeButton = New-Object System.Windows.Forms.Button
    $closeButton.Text = "關閉"
    $closeButton.Location = New-Object System.Drawing.Point(782, 584)
    $closeButton.Size = New-Object System.Drawing.Size(120, 34)
    $closeButton.Anchor = "Bottom,Right"
    $form.Controls.Add($closeButton)

    $reportPathLabel = New-Object System.Windows.Forms.Label
    $reportPathLabel.Text = "報告尚未產生"
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
            $details = Get-ExceptionDetails $_
            Write-UiLog -Status "ERROR" -Text "檢測發生未處理錯誤。"
            $emergencyPath = Write-EmergencyReport -Title "網路健檢未處理錯誤" -ErrorDetails $details
            $message = "檢測無法完成。"
            if ($null -ne $emergencyPath) {
                $message += "`r`n錯誤報告：$emergencyPath"
            }
            [System.Windows.Forms.MessageBox]::Show($message, "網路健檢錯誤", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
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
                throw "找不到 HTML 報告。"
            }
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show("無法開啟報告：$($_.Exception.Message)", "開啟報告失敗", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        }
    })

    $openFolderButton.Add_Click({
        try {
            if (Test-Path -LiteralPath $script:OutputDirectory) {
                Start-Process -FilePath "explorer.exe" -ArgumentList ('"{0}"' -f $script:OutputDirectory) -ErrorAction Stop
            }
            else {
                throw "找不到報告資料夾。"
            }
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show("無法開啟資料夾：$($_.Exception.Message)", "開啟資料夾失敗", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
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
    $details = Get-ExceptionDetails $_
    Write-Host "網路健檢無法啟動。" -ForegroundColor Red
    Write-Host $details
    $emergencyPath = Write-EmergencyReport -Title "網路健檢啟動失敗" -ErrorDetails $details

    if ($script:GuiAvailable) {
        $message = "網路健檢無法啟動。"
        if ($null -ne $emergencyPath) {
            $message += "`r`n錯誤報告：$emergencyPath"
        }
        [System.Windows.Forms.MessageBox]::Show($message, "網路健檢錯誤", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    }

    $exitCode = 1
}

exit $exitCode
