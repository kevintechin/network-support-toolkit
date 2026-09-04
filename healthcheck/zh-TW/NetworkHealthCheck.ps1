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
# - 可追溯：報告保存例外類型、訊息與內部例外；腳本位置與呼叫堆疊只寫入 JSON 報告（Diagnostics）。

$script:ToolVersion = "1.2.2"
$script:BaseDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path

# -----------------------------------------------------------------------------
# Backlog #18：應用程式控制政策（WDAC、AppLocker）可能把 PowerShell 限制在受限語言模式，該模式下腳本不得建立 .NET
# 物件。本工具從第一行就需要它們——下面那個 ArrayList 就已經不被允許——因此在那種機器上根本無法執行，而使用者只會
# 看到引擎自己的「Cannot create type. Only core types are supported in this language mode.」，那句話對他毫無幫助。
# 所以這一行以上的程式碼與 Write-EnvironmentReport 都只用受限模式允許的東西：cmdlet、運算子與屬性讀取，不用 .NET
# 型別、不用 New-Object。
# -----------------------------------------------------------------------------
function Write-EnvironmentReport {
    param([string]$Reason)

    $lines = @(
        "網路健檢工具 - 環境報告",
        "=========================================",
        "本工具無法在這台電腦上執行，且未變更任何設定。",
        "",
        "原因：$Reason",
        ("日期時間：" + (Get-Date -Format "yyyy-MM-dd HH:mm:ss")),
        ("工具版本：" + $script:ToolVersion),
        ("電腦名稱：" + $env:COMPUTERNAME),
        ("使用者：" + $env:USERNAME),
        ("腳本資料夾：" + $script:BaseDirectory)
    )
    # 每一項資訊都是選擇性的：被鎖定的機器可能拒絕其中任何一項，少一行不該讓其他成功取得的資訊一起消失。
    try { $lines += ("PowerShell：" + $PSVersionTable.PSVersion + "（" + $PSVersionTable.PSEdition + "）") } catch { $lines += "PowerShell：未知" }
    try { $lines += ("語言模式：" + $ExecutionContext.SessionState.LanguageMode) } catch { $lines += "語言模式：未知" }
    try { $lines += ("地區設定：" + (Get-Culture).Name + " / 介面語言：" + (Get-UICulture).Name) } catch { $lines += "地區設定：未知" }
    try { $lines += ("作業系統：" + (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).Caption) } catch { $lines += "作業系統：未知" }
    $lines += @(
        "",
        "IT 可以怎麼做：",
        "- 在應用程式控制政策（WDAC / AppLocker）中放行 NetworkHealthCheck.ps1，或",
        "- 改在沒有這項限制的電腦上執行檢測。",
        "請將本檔案一併附在報修單中。"
    )

    # 先寫腳本資料夾，不可寫時改寫暫存資料夾——與報告採用相同的順序。
    $name = "NetworkHealthCheck_ENVIRONMENT_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".txt"
    foreach ($folder in @($script:BaseDirectory, $env:TEMP)) {
        if ([string]::IsNullOrWhiteSpace($folder)) { continue }
        $path = Join-Path $folder $name
        try {
            Set-Content -LiteralPath $path -Value $lines -Encoding UTF8 -ErrorAction Stop
            return $path
        }
        catch { }
    }
    return ""
}

if ([string]$ExecutionContext.SessionState.LanguageMode -ne "FullLanguage") {
    $mode = [string]$ExecutionContext.SessionState.LanguageMode
    $reason = "PowerShell 被應用程式控制政策限制在「$mode」語言模式，本腳本因此不得建立所需的 .NET 物件。"
    $written = Write-EnvironmentReport -Reason $reason
    Write-Host ""
    Write-Host "網路健檢工具無法在這台電腦上執行。"
    Write-Host $reason
    Write-Host "本工具未讀取或變更任何網路設定。"
    Write-Host "IT 可以怎麼做：在應用程式控制政策（WDAC / AppLocker）中放行本腳本，或改在沒有這項限制的電腦上執行檢測。"
    if (-not [string]::IsNullOrWhiteSpace($written)) { Write-Host "已將供 IT 參考的資訊寫入：$written" }
    Write-Host ""
    exit 3
}

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
$script:RunOptionMessages = New-Object System.Collections.ArrayList
# 腳本層級變數與已繫結的參數同屬頂層作用域：這裡絕不能把參數同名變數重設為常值（v1.2.0 寫成 $false，IT 入口因此開成使用者版面；v1.2.1 修正）。
$script:Interactive = [bool]$Interactive
$script:OptionsPanel = $null
$script:OpenJsonButton = $null

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

function Test-IsRunningFromArchive {
    param([string]$Path)

    # Windows 會把 ZIP 開在類似 %TEMP%\Temp1_NetworkHealthCheck-1.2.2.zip\... 的暫時檢視中；從那裡直接按兩下看似
    # 可以執行，但報告會寫進一個隨檢視消失的資料夾，等使用者要把證據交給 IT 時已經找不到了。
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    return ($Path -match "\.zip[\\/]")
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

# Backlog #14：Winsock 與 WinHTTP 的錯誤字串由作業系統提供，因此系統地區設定與報告語言不同的機器，會把該地區的文字
# 印進報告（英文報告裡出現中文句子）。訊息會變，錯誤碼不會：SocketException.SocketErrorCode 與 WebException.Status
# 都是列舉。下面兩張表把這些檢查會遇到的錯誤碼轉成報告語言的一句話；原始訊息一律保留在旁邊，未收錄的錯誤碼也仍會附上
# 與語系無關的代碼名稱，讓讀的人查得到作業系統實際說了什麼。
function Get-NetworkErrorCauseText {
    param([object]$Exception)

    $socketCauses = @{
        "HostNotFound"        = "無法解析這個名稱（DNS 沒有紀錄）。"
        "TryAgain"            = "名稱解析暫時失敗，DNS 伺服器沒有回應。"
        "NoData"              = "名稱存在，但沒有所要求類型的位址紀錄。"
        "TimedOut"            = "目標在逾時前沒有回應。"
        "ConnectionRefused"   = "目標有回應，但拒絕該連接埠的連線。"
        "NetworkUnreachable"  = "這台機器沒有到該網路的路由。"
        "HostUnreachable"     = "網路可達，但主機不可達。"
        "ConnectionReset"     = "連線被遠端主機強制關閉。"
        "ConnectionAborted"   = "連線被本機軟體中止（常見於安全性軟體或政策）。"
        "NetworkDown"         = "本機的網路堆疊回報網路已中斷。"
        "AddressNotAvailable" = "這個位址在本機無效。"
        "AccessDenied"        = "Socket 操作被權限或政策封鎖。"
    }
    $webCauses = @{
        "Timeout"                    = "HTTP 要求逾時。"
        "NameResolutionFailure"      = "無法解析 URL 中的主機名稱。"
        "ProxyNameResolutionFailure" = "無法解析 Proxy 伺服器的名稱。"
        "ConnectFailure"             = "無法建立到伺服器的連線。"
        "TrustFailure"               = "伺服器憑證不受信任。"
        "SecureChannelFailure"       = "TLS 交握失敗（通訊協定或加密套件不符）。"
        "ReceiveFailure"             = "接收回應的過程中連線中斷。"
        "SendFailure"                = "傳送要求的過程中連線中斷。"
        "ConnectionClosed"           = "伺服器意外關閉連線。"
        "ServerProtocolViolation"    = "伺服器的回應不是有效的 HTTP。"
        "RequestProhibitedByProxy"   = "Proxy 拒絕了這個要求。"
    }

    # PowerShell 會把失敗的方法呼叫包成 MethodInvocationException、把工作包成 AggregateException、把 ping 包成
    # PingException，所以 socket 錯誤通常在往內兩三層的地方。
    $current = $Exception
    $depth = 0
    while ($null -ne $current -and $depth -le 5) {
        if ($current -is [System.Net.Sockets.SocketException]) {
            $code = [string]$current.SocketErrorCode
            if ($socketCauses.ContainsKey($code)) {
                return ("{0} [SocketError {1}]" -f $socketCauses[$code], $code)
            }
            return ("[SocketError {0}]" -f $code)
        }
        if ($current -is [System.Net.WebException]) {
            $status = [string]$current.Status
            if ($webCauses.ContainsKey($status)) {
                return ("{0} [WebExceptionStatus {1}]" -f $webCauses[$status], $status)
            }
            return ("[WebExceptionStatus {0}]" -f $status)
        }
        $current = $current.InnerException
        $depth++
    }
    return ""
}

# 原因放在原始訊息上方，而不是取代它。
function Add-NetworkErrorCause {
    param(
        [object]$Exception,
        [string]$Text,
        [switch]$SingleLine
    )

    $cause = Get-NetworkErrorCauseText $Exception
    if ([string]::IsNullOrWhiteSpace($cause)) {
        return $Text
    }
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ("原因：{0}" -f $cause)
    }
    # Ping 的逐次紀錄與 traceroute 的躍點狀態是單行，其餘則把原始訊息放到下一行。兩種形狀都是原因在前——
    # 這正是整件事的重點。
    if ($SingleLine) {
        return ("原因：{0}｜{1}" -f $cause, $Text)
    }
    return (("原因：{0}" -f $cause) + [Environment]::NewLine + $Text)
}

# Backlog #11：只回傳人類可讀的摘要；腳本位置與呼叫堆疊改由 Get-ExceptionDiagnostics 提供（僅寫入 JSON 報告）。
function Get-ExceptionDetails {
    param(
        [object]$ErrorRecord,
        [switch]$IncludeDiagnostics
    )

    if ($null -eq $ErrorRecord) {
        return "未知錯誤"
    }

    try {
        $message = $ErrorRecord.Exception.Message
        $typeName = $ErrorRecord.Exception.GetType().FullName
        $parts = @("錯誤類型：$typeName", "訊息：$message")
        $cause = Get-NetworkErrorCauseText $ErrorRecord.Exception
        if (-not [string]::IsNullOrWhiteSpace($cause)) {
            $parts = @("原因：$cause") + $parts
        }
        $inner = $ErrorRecord.Exception.InnerException
        $innerIndex = 1
        while ($null -ne $inner -and $innerIndex -le 5) {
            $parts += ("內部錯誤 {0}：{1} — {2}" -f $innerIndex, $inner.GetType().FullName, $inner.Message)
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
            $parts += "位置：$position"
        }
        if (-not [string]::IsNullOrWhiteSpace($stack)) {
            $parts += "呼叫堆疊：$stack"
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
    Write-UiLog -Status $Status -Text ("{0}／{1}：{2}" -f $Category, $Check, $Message)
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
    Write-UiLog -Status "INFO" -Text ("開始：$Name")

    try {
        return (& $Action)
    }
    catch {
        $details = Get-ExceptionDetails $_
        $diagnostics = Get-ExceptionDiagnostics $_
        Add-CheckResult -Category $Category -Check $Name -Status "ERROR" -Message "此項目無法執行，已記錄錯誤。" -Details $details -Diagnostics $diagnostics -Tag "step-error" -Scope $Scope | Out-Null
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
        $script:ConfigLoadError = "找不到設定檔：$path。程式已改用內建預設值。"
        return $defaultConfig
    }

    try {
        $raw = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
        $overrideConfig = $raw | ConvertFrom-Json -ErrorAction Stop
        return (Merge-ConfigObject -DefaultObject $defaultConfig -OverrideObject $overrideConfig)
    }
    catch {
        $script:ConfigLoadDiagnostics = Get-ExceptionDiagnostics $_
        $script:ConfigLoadError = "設定檔格式錯誤，程式已改用內建預設值。`r`n$(Get-ExceptionDetails $_)"
        return $defaultConfig
    }
}

# v1.2：執行選項來自入口（啟動器參數）或 IT 選項面板；JSON 設定檔永遠不會被寫入。
function Set-RunOptions {
    param([hashtable]$Overrides)

    if ($null -eq $Overrides) {
        $Overrides = @{}
    }
    $script:RunOptionMessages = New-Object System.Collections.ArrayList
    $config = ($script:BaseConfig | ConvertTo-Json -Depth 10) | ConvertFrom-Json
    $extra = [ordered]@{ Ping = @(); Dns = @(); Tcp = @(); Http = @() }
    $raw = [ordered]@{ Ping = @(); Dns = @(); Tcp = @(); Http = @() }

    foreach ($value in @(@($Overrides["PingTarget"]) | ForEach-Object { ([string]$_) -split '[,;\s]+' } | ForEach-Object { ([string]$_).Trim() })) {
        if ([string]::IsNullOrWhiteSpace([string]$value)) { continue }
        $raw.Ping += [string]$value
        $config.Tests.PingTargets = @($config.Tests.PingTargets) + [pscustomobject][ordered]@{ Name = "額外 Ping"; Address = [string]$value; Required = $false }
        $extra.Ping += [string]$value
    }
    foreach ($value in @(@($Overrides["DnsName"]) | ForEach-Object { ([string]$_) -split '[,;\s]+' } | ForEach-Object { ([string]$_).Trim() })) {
        if ([string]::IsNullOrWhiteSpace([string]$value)) { continue }
        $raw.Dns += [string]$value
        $config.Tests.DnsNames = @($config.Tests.DnsNames) + [pscustomobject][ordered]@{ Name = "額外 DNS"; Host = [string]$value; Required = $false }
        $extra.Dns += [string]$value
    }
    foreach ($value in @(@($Overrides["TcpTarget"]) | ForEach-Object { ([string]$_) -split '[,;\s]+' } | ForEach-Object { ([string]$_).Trim() })) {
        if ([string]::IsNullOrWhiteSpace([string]$value)) { continue }
        $raw.Tcp += [string]$value
        $parts = ([string]$value).Split(':')
        $port = 0
        if ($parts.Count -eq 2) { $port = ConvertTo-IntSafe $parts[1] 0 }
        if ($parts.Count -ne 2 -or $port -lt 1 -or $port -gt 65535 -or [string]::IsNullOrWhiteSpace($parts[0])) {
            [void]$script:RunOptionMessages.Add("已忽略額外 TCP 目標「$value」：格式應為 host:port。")
            continue
        }
        $config.Tests.TcpTargets = @($config.Tests.TcpTargets) + [pscustomobject][ordered]@{ Name = "額外 TCP"; Host = $parts[0]; Port = $port; Required = $false; Group = "" }
        $extra.Tcp += [string]$value
    }
    foreach ($value in @(@($Overrides["HttpUrl"]) | ForEach-Object { ([string]$_) -split '\s+' } | ForEach-Object { ([string]$_).Trim() })) {
        if ([string]::IsNullOrWhiteSpace([string]$value)) { continue }
        $raw.Http += [string]$value
        $config.Tests.HttpTargets = @($config.Tests.HttpTargets) + [pscustomobject][ordered]@{ Name = "額外 URL"; Url = [string]$value; Required = $false; Group = "" }
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
        RawTargets     = [pscustomobject]$raw
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
    if ($options.EntryPoint -eq "IT") { $parts += "IT 入口" } else { $parts += "使用者入口" }
    $extras = @()
    foreach ($value in @($options.ExtraTargets.Ping)) { $extras += "ping $value" }
    foreach ($value in @($options.ExtraTargets.Dns)) { $extras += "dns $value" }
    foreach ($value in @($options.ExtraTargets.Tcp)) { $extras += "tcp $value" }
    foreach ($value in @($options.ExtraTargets.Http)) { $extras += "url $value" }
    if ($extras.Count -gt 0) { $parts += ("額外目標：{0}" -f ($extras -join ", ")) }
    $parts += ("Ping 次數 {0}" -f $options.PingCount)
    $parts += ("取樣 {0} 秒" -f $options.SampleSeconds)
    if ($options.ChecksEnabled.Traceroute) { $parts += ("traceroute {0} 跳" -f $options.TracerouteHops) }
    $disabled = @()
    foreach ($property in $options.ChecksEnabled.PSObject.Properties) {
        if (-not $property.Value) { $disabled += $property.Name }
    }
    if ($disabled.Count -gt 0) { $parts += ("已停用：{0}" -f ($disabled -join ", ")) }
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

        # Backlog #5：只保留 IPv4 閘道（DefaultIPGateway 也可能列出 IPv6 下一跳），並保留「未知」的 DHCP 狀態。
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
            Add-CheckResult -Category "網卡與 IP" -Check "資料來源切換" -Status "WARN" -Message "Get-NetIPConfiguration 無法取得資料，已改用 CIM/WMI。" -Details (Get-ExceptionDetails $_) -Diagnostics (Get-ExceptionDiagnostics $_) -Tag "data-source" | Out-Null
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
        if ($null -ne $setting.Value -and -not (Test-IsWholeNumber $setting.Value)) {
            [void]$warnings.Add("$($setting.Name) 必須是支援範圍內的整數（目前值：$($setting.Value)），將改用內建預設值。")
        }
        elseif ((ConvertTo-IntSafe $setting.Value 0) -le 0) {
            [void]$warnings.Add("$($setting.Name) 應大於 0；程式將套用內建最低值。")
        }
    }

    $checks = $script:Config.Checks
    foreach ($flagName in @("WifiRf", "RouteTable", "GatewayNeighbor", "ProxySettings", "Traceroute", "DriverInfo")) {
        $flagValue = Get-PropertyValue $checks $flagName
        if ($null -ne $flagValue -and -not ($flagValue -is [bool])) {
            [void]$warnings.Add("Checks.$flagName 必須是 true 或 false（目前值：$flagValue），該檢查已停用。")
        }
    }
    $hopsValue = Get-PropertyValue $checks "TracerouteHops"
    if ($null -ne $hopsValue -and (-not (Test-IsWholeNumber $hopsValue) -or (ConvertTo-IntSafe $hopsValue 0) -lt 1 -or (ConvertTo-IntSafe $hopsValue 0) -gt 10)) {
        [void]$warnings.Add("Checks.TracerouteHops 必須是 1 到 10 的整數（目前值：$hopsValue），將改用內建預設值。")
    }

    $countThresholdNames = @("TcpRetransmissionCriticalCount", "MinimumTcpSegmentsForRate", "AdapterErrorWarningDelta", "AdapterErrorCriticalDelta", "AdapterDiscardWarningDelta", "AdapterDiscardCriticalDelta")
    foreach ($thresholdName in @("PacketLossWarningPercent", "PacketLossCriticalPercent", "LatencyWarningMs", "LatencyCriticalMs", "TcpRetransmissionWarningPercent", "TcpRetransmissionCriticalPercent", "TcpRetransmissionCriticalCount", "MinimumTcpSegmentsForRate", "AdapterErrorWarningDelta", "AdapterErrorCriticalDelta", "AdapterDiscardWarningDelta", "AdapterDiscardCriticalDelta")) {
        $thresholdValue = Get-PropertyValue $thresholds $thresholdName
        if ($null -eq $thresholdValue) {
            continue
        }
        if (-not (Test-IsNumericValue $thresholdValue)) {
            [void]$warnings.Add("$thresholdName 不是數值（目前值：$thresholdValue），將改用內建預設值。")
        }
        elseif (($countThresholdNames -contains $thresholdName) -and -not (Test-IsWholeNumber $thresholdValue)) {
            [void]$warnings.Add("$thresholdName 必須是支援範圍內的整數（目前值：$thresholdValue），將改用內建預設值。")
        }
    }

    $warningLoss = ConvertTo-DoubleSafe $thresholds.PacketLossWarningPercent 5
    $criticalLoss = ConvertTo-DoubleSafe $thresholds.PacketLossCriticalPercent 20
    if ($warningLoss -lt 0 -or $criticalLoss -lt $warningLoss) {
        [void]$warnings.Add("封包遺失門檻順序不合理：Warning=$warningLoss, Critical=$criticalLoss。")
    }

    $warningLatency = ConvertTo-DoubleSafe $thresholds.LatencyWarningMs 100
    $criticalLatency = ConvertTo-DoubleSafe $thresholds.LatencyCriticalMs 250
    if ($warningLatency -lt 0 -or $criticalLatency -lt $warningLatency) {
        [void]$warnings.Add("延遲門檻順序不合理：Warning=$warningLatency, Critical=$criticalLatency。")
    }

    $warningRetrans = ConvertTo-DoubleSafe (Get-PropertyValue $thresholds "TcpRetransmissionWarningPercent" 2) 2
    $criticalRetrans = ConvertTo-DoubleSafe (Get-PropertyValue $thresholds "TcpRetransmissionCriticalPercent" 5) 5
    if ($warningRetrans -lt 0 -or $criticalRetrans -lt $warningRetrans) {
        [void]$warnings.Add("TCP 重傳門檻順序不合理：Warning=$warningRetrans, Critical=$criticalRetrans。")
    }

    if ($errors.Count -gt 0) {
        Add-CheckResult -Category "程式設定" -Check "設定值驗證" -Status "ERROR" -Message ("設定檔有 {0} 個無效值；程式會繼續執行，但相關結果可能不具判斷意義。" -f $errors.Count) -Details (@($errors) -join [Environment]::NewLine) -Tag "config" | Out-Null
    }
    elseif ($warnings.Count -eq 0) {
        Add-CheckResult -Category "程式設定" -Check "設定值驗證" -Status "PASS" -Message "設定值格式檢查通過。" -Details "" -Tag "config" | Out-Null
    }

    if ($warnings.Count -gt 0) {
        Add-CheckResult -Category "程式設定" -Check "設定值門檻" -Status "WARN" -Message ("設定檔有 {0} 個需要注意的門檻值。" -f $warnings.Count) -Details (@($warnings) -join [Environment]::NewLine) -Tag "config" | Out-Null
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
        Add-CheckResult -Category "網卡與 IP" -Check "可用網卡" -Status "FAIL" -Message "沒有找到已連線且具有 IP 位址的網卡。" -Details "請確認網路線、Wi-Fi、飛航模式、網卡驅動程式與網卡是否停用。" -Tag "adapters" | Out-Null
        return
    }

    $physical = @($Adapters | Where-Object { $_.IsPhysical -eq $true })
    $virtual = @($Adapters | Where-Object { $_.IsPhysical -ne $true })
    $anyGateway = @($Adapters | Where-Object { @($_.Gateways).Count -gt 0 }).Count -gt 0
    $adapterSummary = "找到 {0} 張已連線網卡：實體 {1} 張、虛擬 {2} 張。" -f $Adapters.Count, $physical.Count, $virtual.Count
    if ($physical.Count -gt 0) {
        Add-CheckResult -Category "網卡與 IP" -Check "可用網卡" -Status "PASS" -Message $adapterSummary -Details "" -Tag "adapters" | Out-Null
    }
    elseif ($anyGateway) {
        Add-CheckResult -Category "網卡與 IP" -Check "可用網卡" -Status "WARN" -Message "沒有已連線的實體網卡；目前只有虛擬網卡（VPN 或虛擬化）承載連線。" -Details $adapterSummary -Tag "adapters" | Out-Null
    }
    else {
        Add-CheckResult -Category "網卡與 IP" -Check "可用網卡" -Status "FAIL" -Message "沒有已連線的實體網卡。" -Details $adapterSummary -Tag "adapters" | Out-Null
    }

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
            ("網卡類型：{0}" -f $(if ($adapter.IsPhysical -eq $true) { "實體" } else { "虛擬" })),
            ("媒體類型：{0}" -f (ConvertTo-DisplayString $adapter.MediaType)),
            ("驅動程式：{0}" -f (ConvertTo-DisplayString (@($adapter.DriverVersion, $adapter.DriverDate, $adapter.DriverProvider) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }))),
            "資料來源：$($adapter.Source)"
        ) -join [Environment]::NewLine

        $hasApipa = $false
        foreach ($ip in @($adapter.IPv4Addresses)) {
            if ([string]$ip -like "169.254.*") {
                $hasApipa = $true
                break
            }
        }

        if ($adapter.IsPhysical -ne $true) {
            Add-CheckResult -Category "網卡與 IP" -Check ("網卡：{0}" -f $adapter.Name) -Status "INFO" -Message ("虛擬網卡（不計入實體連線）。IPv4：{0}" -f (ConvertTo-DisplayString $adapter.IPv4WithPrefix)) -Details $details -Tag "adapter" | Out-Null
        }
        elseif ($hasApipa) {
            Add-CheckResult -Category "網卡與 IP" -Check ("網卡：{0}" -f $adapter.Name) -Status "FAIL" -Message "偵測到 169.254.x.x 自動私人 IP，通常表示無法取得 DHCP 位址。" -Details $details -Tag "adapter" | Out-Null
        }
        elseif (@($adapter.IPv4Addresses).Count -eq 0) {
            Add-CheckResult -Category "網卡與 IP" -Check ("網卡：{0}" -f $adapter.Name) -Status "WARN" -Message "此網卡沒有 IPv4 位址。" -Details $details -Tag "adapter" | Out-Null
        }
        else {
            Add-CheckResult -Category "網卡與 IP" -Check ("網卡：{0}" -f $adapter.Name) -Status "PASS" -Message ("目前 IPv4：{0}" -f (ConvertTo-DisplayString $adapter.IPv4WithPrefix)) -Details $details -Tag "adapter" | Out-Null
        }
    }

    $gateways = @()
    foreach ($adapter in $Adapters) {
        $gateways += @($adapter.Gateways)
    }
    $gateways = @($gateways | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)

    if ($gateways.Count -eq 0) {
        Add-CheckResult -Category "網卡與 IP" -Check "預設閘道" -Status "FAIL" -Message "沒有找到 IPv4 預設閘道，通常無法連到其他網段或網際網路。" -Details "" -Tag "gateway-config" | Out-Null
    }
    else {
        Add-CheckResult -Category "網卡與 IP" -Check "預設閘道" -Status "PASS" -Message ("已設定：{0}" -f ($gateways -join ", ")) -Details "" -Tag "gateway-config" | Out-Null
    }

    $dnsServers = @()
    foreach ($adapter in $Adapters) {
        $dnsServers += @($adapter.DnsServers)
    }
    $dnsServers = @($dnsServers | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)

    if ($dnsServers.Count -eq 0) {
        Add-CheckResult -Category "網卡與 IP" -Check "DNS 伺服器" -Status "FAIL" -Message "沒有找到 DNS 伺服器設定。" -Details "沒有 DNS 時，通常無法使用網址連線，但仍可能用 IP 位址連線。" -Tag "dns-config" | Out-Null
    }
    else {
        Add-CheckResult -Category "網卡與 IP" -Check "DNS 伺服器" -Status "PASS" -Message ("已設定：{0}" -f ($dnsServers -join ", ")) -Details "" -Tag "dns-config" | Out-Null
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
        Add-CheckResult -Category "公司規範比對" -Check "標準設定" -Status "INFO" -Message "設定檔尚未填入公司標準，因此只能顯示目前設定，不能判定 IP 是否符合公司規範。" -Details "請由 IT 人員編輯 NetworkHealthCheck.config.json 的 Expected 區段。" -Tag "expected-standard" | Out-Null
        return
    }

    if ($Adapters.Count -eq 0) {
        Add-CheckResult -Category "公司規範比對" -Check "標準設定" -Status "FAIL" -Message "沒有可用網卡，無法比對公司標準。" -Details "" -Tag "expected-standard" | Out-Null
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
            Add-CheckResult -Category "公司規範比對" -Check "IPv4 位址/網段" -Status "PASS" -Message ("目前 IP $matchedIp 符合允許清單。") -Details ("允許的 IP：{0}`r`n允許的網段：{1}" -f (ConvertTo-DisplayString $allowedIps), (ConvertTo-DisplayString $allowedCidrs)) -Tag "expected-standard" | Out-Null
        }
        else {
            Add-CheckResult -Category "公司規範比對" -Check "IPv4 位址/網段" -Status "FAIL" -Message ("目前 IP 不符合允許清單：{0}" -f (ConvertTo-DisplayString $allIps)) -Details ("允許的 IP：{0}`r`n允許的網段：{1}" -f (ConvertTo-DisplayString $allowedIps), (ConvertTo-DisplayString $allowedCidrs)) -Tag "expected-standard" | Out-Null
        }
    }

    if ($allowedPrefixes.Count -gt 0) {
        $prefixMatches = @($allPrefixes | Where-Object { $allowedPrefixes -contains [int]$_ })
        if ($prefixMatches.Count -gt 0) {
            Add-CheckResult -Category "公司規範比對" -Check "子網路前綴" -Status "PASS" -Message ("目前前綴長度符合：/{0}" -f (($prefixMatches | Select-Object -Unique) -join ", /")) -Details ("允許值：/{0}" -f ($allowedPrefixes -join ", /")) -Tag "expected-standard" | Out-Null
        }
        else {
            Add-CheckResult -Category "公司規範比對" -Check "子網路前綴" -Status "FAIL" -Message ("目前前綴長度不符合：/{0}" -f ($allPrefixes -join ", /")) -Details ("允許值：/{0}" -f ($allowedPrefixes -join ", /")) -Tag "expected-standard" | Out-Null
        }
    }

    if ($allowedGateways.Count -gt 0) {
        $gatewayMatches = @($allGateways | Where-Object { $allowedGateways -contains [string]$_ })
        if ($gatewayMatches.Count -gt 0) {
            Add-CheckResult -Category "公司規範比對" -Check "預設閘道" -Status "PASS" -Message ("符合：{0}" -f ($gatewayMatches -join ", ")) -Details ("允許值：{0}" -f ($allowedGateways -join ", ")) -Tag "expected-standard" | Out-Null
        }
        else {
            Add-CheckResult -Category "公司規範比對" -Check "預設閘道" -Status "FAIL" -Message ("目前閘道不符合：{0}" -f (ConvertTo-DisplayString $allGateways)) -Details ("允許值：{0}" -f ($allowedGateways -join ", ")) -Tag "expected-standard" | Out-Null
        }
    }

    if ($requiredDns.Count -gt 0) {
        $missingDns = @($requiredDns | Where-Object { $allDns -notcontains [string]$_ })
        if ($missingDns.Count -eq 0) {
            Add-CheckResult -Category "公司規範比對" -Check "DNS 伺服器" -Status "PASS" -Message "已包含所有必要 DNS 伺服器。" -Details ("必要值：{0}`r`n目前值：{1}" -f ($requiredDns -join ", "), (ConvertTo-DisplayString $allDns)) -Tag "expected-standard" | Out-Null
        }
        else {
            Add-CheckResult -Category "公司規範比對" -Check "DNS 伺服器" -Status "FAIL" -Message ("缺少必要 DNS：{0}" -f ($missingDns -join ", ")) -Details ("必要值：{0}`r`n目前值：{1}" -f ($requiredDns -join ", "), (ConvertTo-DisplayString $allDns)) -Tag "expected-standard" | Out-Null
        }
    }

    if ($hasValidDhcpRule) {
        $expectedBool = [bool]$expectedDhcp
        if ($allDhcp.Count -eq 0) {
            Add-CheckResult -Category "公司規範比對" -Check "DHCP 模式" -Status "ERROR" -Message "無法取得目前 DHCP 狀態。" -Details ("預期值：{0}" -f $(if ($expectedBool) { "啟用" } else { "停用" })) -Tag "expected-standard" | Out-Null
        }
        else {
            $mismatches = @($allDhcp | Where-Object { [bool]$_ -ne $expectedBool })
            if ($mismatches.Count -eq 0) {
                Add-CheckResult -Category "公司規範比對" -Check "DHCP 模式" -Status "PASS" -Message ("符合預期：{0}" -f $(if ($expectedBool) { "啟用" } else { "停用（固定 IP）" })) -Details "" -Tag "expected-standard" | Out-Null
            }
            else {
                Add-CheckResult -Category "公司規範比對" -Check "DHCP 模式" -Status "FAIL" -Message ("DHCP 模式不符合，預期：{0}" -f $(if ($expectedBool) { "啟用" } else { "停用（固定 IP）" })) -Details ("目前狀態：{0}" -f (($allDhcp | ForEach-Object { if ($_){"啟用"}else{"停用"} }) -join ", ")) -Tag "expected-standard" | Out-Null
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
                [void]$attemptDetails.Add(("第 {0} 次：錯誤，{1}" -f $i, (Add-NetworkErrorCause $_.Exception $_.Exception.Message -SingleLine)))
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
            $noTargetDetail = "設定值：$address"
            if ($address -eq "AUTO_GATEWAY") {
                $noTargetDetail = "設定值：AUTO_GATEWAY——此為佔位符，執行時解析為目前的 IPv4 預設閘道；目前不存在（通常代表本地連線中斷）。"
            }
            Add-CheckResult -Category "延遲與封包遺失" -Check $name -Status $status -Message "找不到可測試的目標。" -Details ($noTargetDetail + [Environment]::NewLine + ("檢測方式：.NET Ping — {0} 次 ICMP echo，逾時 {1} ms。" -f $count, $timeout) + [Environment]::NewLine + "手動驗證：ping -n $count <目標 IP>") -Tag $pingTag | Out-Null
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
                if ($status -eq "INFO") {
                    $details += [Environment]::NewLine + "補充說明：此為非必要目標，可能單純封鎖 ICMP——網際網路的權威判定請看「連線能力」群組。"
                }
                Add-CheckResult -Category "延遲與封包遺失" -Check ("{0}：{1}" -f $name, $target) -Status $status -Message $message -Details $details -Tag $pingTag | Out-Null
            }
            catch {
                $status = if ($required) { "ERROR" } else { "INFO" }
                Add-CheckResult -Category "延遲與封包遺失" -Check ("{0}：{1}" -f $name, $target) -Status $status -Message "Ping 測試無法執行。" -Details (Get-ExceptionDetails $_) -Diagnostics (Get-ExceptionDiagnostics $_) -Tag $pingTag | Out-Null
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
                Add-CheckResult -Category "DNS" -Check $name -Status "PASS" -Message ("{0} 已解析為 {1}（{2} ms）。" -f $hostName, ($result.Addresses -join ", "), $result.ElapsedMs) -Details ($methodText + [Environment]::NewLine + "手動驗證：nslookup $hostName") -Tag "dns" | Out-Null
            }
            else {
                $status = if ($required) { "FAIL" } else { "WARN" }
                Add-CheckResult -Category "DNS" -Check $name -Status $status -Message ("$hostName 沒有回傳 IP 位址。") -Details ($methodText + [Environment]::NewLine + "手動驗證：nslookup $hostName") -Tag "dns" | Out-Null
            }
        }
        catch {
            $status = if ($required) { "FAIL" } else { "WARN" }
            Add-CheckResult -Category "DNS" -Check $name -Status $status -Message ("無法解析 $hostName。") -Details ((Get-ExceptionDetails $_) + [Environment]::NewLine + $methodText + [Environment]::NewLine + "手動驗證：nslookup $hostName") -Diagnostics (Get-ExceptionDiagnostics $_) -Tag "dns" | Out-Null
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
            Error     = (Add-NetworkErrorCause $_.Exception $_.Exception.Message)
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
            Error        = (Add-NetworkErrorCause $_.Exception $_.Exception.Message)
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
            Error        = (Add-NetworkErrorCause $_.Exception $_.Exception.Message)
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
        Add-CheckResult -Category "連線能力" -Check ("群組：$GroupName") -Status $status -Message "此群組沒有可執行的測試項目。" -Details "請檢查設定檔中的 Group 名稱與測試目標。" -Tag "connectivity-group" | Out-Null
        return
    }

    $successful = @($entries | Where-Object { $_.Success })
    if ($successful.Count -gt 0) {
        $names = @($successful | ForEach-Object { $_.Name })
        Add-CheckResult -Category "連線能力" -Check ("群組：$GroupName") -Status "PASS" -Message ("至少一種連線方式成功：{0}" -f ($names -join ", ")) -Details (("成功 {0}/{1} 項。" -f $successful.Count, $entries.Count) + [Environment]::NewLine + "檢測方式：群組內任一連線測試成功即通過。") -Tag "connectivity-group" | Out-Null
    }
    else {
        $status = if ($Required) { "FAIL" } else { "WARN" }
        $details = (@($entries | ForEach-Object { "{0}：{1}" -f $_.Name, $_.Error }) + "檢測方式：群組內任一連線測試成功即通過。") -join [Environment]::NewLine
        Add-CheckResult -Category "連線能力" -Check ("群組：$GroupName") -Status $status -Message "所有連線方式都失敗。" -Details $details -Tag "connectivity-group" | Out-Null
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
                Add-CheckResult -Category "TCP 連線" -Check $name -Status "ERROR" -Message "設定的主機或連接埠無效。" -Details ("Host=$hostName, Port=$port") -Tag "tcp" | Out-Null
            }
            continue
        }

        $result = Invoke-TcpConnectionTest -HostName $hostName -Port $port -TimeoutMs $tcpTimeout
        if ($result.Success) {
            Add-CheckResult -Category "TCP 連線" -Check $name -Status "PASS" -Message ("可連線至 {0}:{1}，耗時 {2} ms。" -f $hostName, $port, $result.ElapsedMs) -Details ($tcpMethod + [Environment]::NewLine + "手動驗證：Test-NetConnection $hostName -Port $port") -Tag "tcp" | Out-Null
        }
        else {
            $status = if ($required) { "FAIL" } else { "INFO" }
            Add-CheckResult -Category "TCP 連線" -Check $name -Status $status -Message ("無法連線至 {0}:{1}。" -f $hostName, $port) -Details ($result.Error + [Environment]::NewLine + $tcpMethod + [Environment]::NewLine + "手動驗證：Test-NetConnection $hostName -Port $port") -Tag "tcp" | Out-Null
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
                Add-CheckResult -Category "HTTP/HTTPS" -Check $name -Status "ERROR" -Message "URL 設定為空白。" -Details "" -Tag "http" | Out-Null
            }
            continue
        }

        $result = Invoke-HttpConnectionTest -Url $url -TimeoutMs $httpTimeout
        if ($result.Success) {
            Add-CheckResult -Category "HTTP/HTTPS" -Check $name -Status "PASS" -Message ("HTTP {0}，耗時 {1} ms。" -f $result.StatusCode, $result.ElapsedMs) -Details ("原始網址：{0}`r`n最終網址：{1}`r`n狀態：{2}`r`n{3}`r`n手動驗證：Invoke-WebRequest {0} -UseBasicParsing" -f $url, $result.FinalUrl, $result.StatusText, $httpMethod) -Tag "http" | Out-Null
        }
        else {
            $status = if ($required) { "FAIL" } else { "INFO" }
            Add-CheckResult -Category "HTTP/HTTPS" -Check $name -Status $status -Message ("無法連線：$url") -Details ($result.Error + [Environment]::NewLine + $httpMethod + [Environment]::NewLine + "手動驗證：Invoke-WebRequest $url -UseBasicParsing") -Tag "http" | Out-Null
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
            Add-CheckResult -Category "網卡錯誤計數" -Check $name -Status "INFO" -Message "無法取得完整的前後比較資料。" -Details "網卡可能在檢測期間切換、重新連線或名稱不同。" -Tag "adapter-errors" | Out-Null
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
                "起始：RxErrors=$($beforeItem.ReceivedPacketErrors), TxErrors=$($beforeItem.OutboundPacketErrors), RxDiscards=$($beforeItem.ReceivedDiscardedPackets), TxDiscards=$($beforeItem.OutboundDiscardedPackets), RxBytes=$($beforeItem.ReceivedBytes), TxBytes=$($beforeItem.SentBytes)",
                "結束：RxErrors=$($afterItem.ReceivedPacketErrors), TxErrors=$($afterItem.OutboundPacketErrors), RxDiscards=$($afterItem.ReceivedDiscardedPackets), TxDiscards=$($afterItem.OutboundDiscardedPackets), RxBytes=$($afterItem.ReceivedBytes), TxBytes=$($afterItem.SentBytes)"
            ) -join [Environment]::NewLine
            $resetStatus = "WARN"
            if ($isVirtualAdapter) { $resetStatus = "INFO" }
            Add-CheckResult -Category "網卡錯誤計數" -Check $name -Status $resetStatus -Message "網卡計數器在檢測期間重設，可能曾重新連線或重啟；無法可靠計算增量。" -Details $resetDetails -Tag "adapter-errors" | Out-Null
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
        $trafficDelta = ([double]$afterItem.ReceivedBytes - [double]$beforeItem.ReceivedBytes) + ([double]$afterItem.SentBytes - [double]$beforeItem.SentBytes)
        if ($isVirtualAdapter) {
            $status = "INFO"
            $message = "虛擬網卡：檢測期間新增錯誤 {0}、丟棄 {1}（僅供參考）。" -f $errorDelta, $discardDelta
        }
        elseif ($status -eq "PASS" -and $trafficDelta -le 0) {
            $status = "INFO"
            $message = "取樣期間此網卡沒有流量，錯誤計數器無法作證（0 錯誤不具意義）。"
        }
        $details = @(
            "接收錯誤增量：$rxErrorDelta（累積 $($afterItem.ReceivedPacketErrors)）",
            "傳送錯誤增量：$txErrorDelta（累積 $($afterItem.OutboundPacketErrors)）",
            "接收丟棄增量：$rxDiscardDelta（累積 $($afterItem.ReceivedDiscardedPackets)）",
            "傳送丟棄增量：$txDiscardDelta（累積 $($afterItem.OutboundDiscardedPackets)）",
            "接收位元組累積：$($afterItem.ReceivedBytes)",
            "傳送位元組累積：$($afterItem.SentBytes)",
            ("取樣期間流量：{0} 位元組" -f [uint64][math]::Max(0, $trafficDelta)),
            "檢測方式：Get-NetAdapterStatistics 測試前後取樣，顯示增量。",
            "手動驗證：Get-NetAdapterStatistics -Name '$name'"
        ) -join [Environment]::NewLine

        Add-CheckResult -Category "網卡錯誤計數" -Check $name -Status $status -Message $message -Details $details -Tag "adapter-errors" | Out-Null
    }
}

# v1.2 IT 診斷資料：給 IT 的參考資料（不影響整體結果），顯示在收合的 IT 區段。
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
        Add-CheckResult -Category "IT 診斷資料" -Check "Wi-Fi 無線訊號" -Status "INFO" -Message "找不到 netsh.exe，無法取得 Wi-Fi 無線資料。" -Details "" -Tag "wifi" -Scope "IT" | Out-Null
        return
    }

    $lines = @()
    try {
        $lines = @(& $netsh wlan show interfaces 2>&1 | ForEach-Object { [string]$_ })
    }
    catch {
        Add-CheckResult -Category "IT 診斷資料" -Check "Wi-Fi 無線訊號" -Status "ERROR" -Message "無法讀取 Wi-Fi 無線資料。" -Details (Get-ExceptionDetails $_) -Diagnostics (Get-ExceptionDiagnostics $_) -Tag "wifi" -Scope "IT" | Out-Null
        return
    }

    $interfaces = @(ConvertFrom-NetshWlanOutput -Lines $lines)
    $connected = @($interfaces | Where-Object { $_.Connected })
    if ($connected.Count -eq 0) {
        Add-CheckResult -Category "IT 診斷資料" -Check "Wi-Fi 無線訊號" -Status "INFO" -Message "沒有已連線的 Wi-Fi 介面（有線連線、Wi-Fi 關閉或沒有無線網卡）。" -Details (("netsh 回報的無線介面數：{0}" -f $interfaces.Count) + [Environment]::NewLine + "手動驗證：netsh wlan show interfaces") -Tag "wifi" -Scope "IT" | Out-Null
        return
    }

    foreach ($wifi in $connected) {
        $rssi = "?"
        if ($null -ne $wifi.SignalPercent) { $rssi = [math]::Round(($wifi.SignalPercent / 2.0) - 100, 0) }
        if ($null -ne $wifi.Rssi) { $rssi = $wifi.Rssi }
        $message = "SSID {0}：訊號 {1}%（約 {2} dBm），{3} {4}，頻道 {5}，{6}/{7} Mbps。" -f $wifi.Ssid, (ConvertTo-DisplayString $wifi.SignalPercent), $rssi, $wifi.RadioType, $wifi.Band, (ConvertTo-DisplayString $wifi.Channel), (ConvertTo-DisplayString $wifi.ReceiveRateMbps), (ConvertTo-DisplayString $wifi.TransmitRateMbps)
        $details = @(
            ("介面：{0}" -f $wifi.Name),
            ("BSSID：{0}" -f (ConvertTo-DisplayString $wifi.Bssid)),
            ("無線規格：{0}，頻段 {1}，頻道 {2}" -f $wifi.RadioType, (ConvertTo-DisplayString $wifi.Band), (ConvertTo-DisplayString $wifi.Channel)),
            ("速率：接收 {0} Mbps，傳送 {1} Mbps" -f (ConvertTo-DisplayString $wifi.ReceiveRateMbps), (ConvertTo-DisplayString $wifi.TransmitRateMbps)),
            ("訊號：{0}%（約 {1} dBm）" -f (ConvertTo-DisplayString $wifi.SignalPercent), $rssi),
            ("設定檔：{0}" -f (ConvertTo-DisplayString $wifi.Profile)),
            "檢測方式：netsh wlan show interfaces，因標籤隨語系不同而改以欄位位置解析；dBm 由訊號百分比估算。",
            "手動驗證：netsh wlan show interfaces",
            "說明：用戶端看到的數值，證據力低於 AP 的用戶端列表。"
        ) -join [Environment]::NewLine
        Add-CheckResult -Category "IT 診斷資料" -Check "Wi-Fi 無線訊號" -Status "INFO" -Message $message -Details $details -Tag "wifi" -Scope "IT" | Out-Null
    }
}

function Sort-DefaultRoutes {
    param([object[]]$Routes)

    return @($Routes | Sort-Object @{ Expression = { (ConvertTo-IntSafe $_.RouteMetric 0) + (ConvertTo-IntSafe $_.InterfaceMetric 0) } }, @{ Expression = { ConvertTo-IntSafe $_.RouteMetric 0 } })
}

function Add-RouteTableResult {
    if (-not (Test-IsTrueFlag $script:Config.Checks.RouteTable)) { return }

    if (-not (Get-Command Get-NetRoute -ErrorAction SilentlyContinue)) {
        Add-CheckResult -Category "IT 診斷資料" -Check "IPv4 預設路由" -Status "INFO" -Message "沒有 Get-NetRoute，未讀取路由表。" -Details "手動驗證：route print -4" -Tag "routes" -Scope "IT" | Out-Null
        return
    }

    $routes = @()
    try {
        $routes = @(Sort-DefaultRoutes -Routes @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix "0.0.0.0/0" -ErrorAction Stop))
    }
    catch {
        Add-CheckResult -Category "IT 診斷資料" -Check "IPv4 預設路由" -Status "ERROR" -Message "無法讀取路由表。" -Details ((Get-ExceptionDetails $_) + [Environment]::NewLine + "手動驗證：route print -4") -Diagnostics (Get-ExceptionDiagnostics $_) -Tag "routes" -Scope "IT" | Out-Null
        return
    }

    if ($routes.Count -eq 0) {
        Add-CheckResult -Category "IT 診斷資料" -Check "IPv4 預設路由" -Status "INFO" -Message "沒有 IPv4 預設路由。" -Details ("檢測方式：Get-NetRoute -AddressFamily IPv4 -DestinationPrefix 0.0.0.0/0" + [Environment]::NewLine + "手動驗證：route print -4") -Tag "routes" -Scope "IT" | Out-Null
        return
    }

    $lines = @()
    foreach ($route in $routes) {
        $lines += ("{0} 經由 {1}（ifIndex {2}），路由計量 {3}，介面計量 {4}，有效計量 {5}，{6}" -f $route.NextHop, $route.InterfaceAlias, $route.InterfaceIndex, $route.RouteMetric, $route.InterfaceMetric, ((ConvertTo-IntSafe $route.RouteMetric 0) + (ConvertTo-IntSafe $route.InterfaceMetric 0)), $route.State)
    }
    $interfaceCount = @($routes | ForEach-Object { [string]$_.InterfaceIndex } | Select-Object -Unique).Count
    if ($interfaceCount -gt 1) { $lines += "多條預設路由：Windows 依合計計量最低者優先；請檢查 VPN 分流或第二條連線。" }
    $lines += "檢測方式：Get-NetRoute -AddressFamily IPv4 -DestinationPrefix 0.0.0.0/0"
    $lines += "手動驗證：route print -4"
    $message = "{0} 條 IPv4 預設路由；優先：{1} 經由 {2}。" -f $routes.Count, $routes[0].NextHop, $routes[0].InterfaceAlias
    Add-CheckResult -Category "IT 診斷資料" -Check "IPv4 預設路由" -Status "INFO" -Message $message -Details ($lines -join [Environment]::NewLine) -Tag "routes" -Scope "IT" | Out-Null
}

function Add-GatewayNeighborResult {
    param([object[]]$PrimaryAdapters)

    if (-not (Test-IsTrueFlag $script:Config.Checks.GatewayNeighbor)) { return }

    $gateways = @(Resolve-PingTargets -Address "AUTO_GATEWAY" -PrimaryAdapters $PrimaryAdapters)
    if ($gateways.Count -eq 0) {
        Add-CheckResult -Category "IT 診斷資料" -Check "閘道鄰居（ARP）" -Status "INFO" -Message "沒有可查詢的 IPv4 預設閘道。" -Details "手動驗證：arp -a" -Tag "gateway-neighbor" -Scope "IT" | Out-Null
        return
    }

    foreach ($gateway in $gateways) {
        $state = "（未知）"
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
            Add-CheckResult -Category "IT 診斷資料" -Check "閘道鄰居（ARP）" -Status "ERROR" -Message "無法讀取鄰居表。" -Details ((Get-ExceptionDetails $_) + [Environment]::NewLine + "手動驗證：arp -a") -Diagnostics (Get-ExceptionDiagnostics $_) -Tag "gateway-neighbor" -Scope "IT" | Out-Null
            continue
        }

        $lines = @()
        if ([string]::IsNullOrWhiteSpace($mac) -or $mac -match '^(00[-:]){5}00$' -or $state -match 'Unreachable|Incomplete') { $lines += "閘道沒有解析到 MAC 位址，到路由器的第二層可能中斷（以上方的閘道 Ping 為準）。" }
        $lines += "檢測方式：Get-NetNeighbor -AddressFamily IPv4（備援：arp -a）"
        $lines += "手動驗證：arp -a"
        $message = "閘道 {0}：鄰居狀態 {1}，MAC {2}。" -f $gateway, $state, (ConvertTo-DisplayString $mac)
        Add-CheckResult -Category "IT 診斷資料" -Check "閘道鄰居（ARP）" -Status "INFO" -Message $message -Details ($lines -join [Environment]::NewLine) -Tag "gateway-neighbor" -Scope "IT" | Out-Null
    }
}

function Add-ProxySettingsResult {
    if (-not (Test-IsTrueFlag $script:Config.Checks.ProxySettings)) { return }

    $lines = @()
    $userProxy = "關閉"
    try {
        $registry = Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" -ErrorAction Stop
        $enabled = ((ConvertTo-IntSafe (Get-PropertyValue $registry "ProxyEnable" 0) 0) -eq 1)
        $server = ConvertTo-SafeString (Get-PropertyValue $registry "ProxyServer" "")
        $pac = ConvertTo-SafeString (Get-PropertyValue $registry "AutoConfigURL" "")
        if ($enabled -and -not [string]::IsNullOrWhiteSpace($server)) { $userProxy = $server }
        elseif (-not [string]::IsNullOrWhiteSpace($pac)) { $userProxy = "PAC " + $pac }
        $lines += ("使用者 Proxy 啟用：{0}，伺服器：{1}，PAC URL：{2}" -f $enabled, (ConvertTo-DisplayString $server), (ConvertTo-DisplayString $pac))
    }
    catch {
        $lines += ("無法讀取使用者 Proxy 設定：{0}" -f $_.Exception.Message)
    }

    $probeUrl = "https://www.microsoft.com/"
    foreach ($target in @($script:Config.Tests.HttpTargets)) {
        $candidate = ConvertTo-SafeString (Get-PropertyValue $target "Url" "")
        if (-not [string]::IsNullOrWhiteSpace($candidate)) { $probeUrl = $candidate; break }
    }
    $effective = "直連"
    try {
        $probe = New-Object System.Uri($probeUrl)
        $resolved = [System.Net.WebRequest]::GetSystemWebProxy().GetProxy($probe)
        if ($null -ne $resolved -and $resolved.AbsoluteUri -ne $probe.AbsoluteUri) { $effective = $resolved.AbsoluteUri }
    }
    catch {
        $effective = "（未知）"
    }
    $lines += ("{0} 實際使用的 Proxy：{1}" -f $probeUrl, $effective)

    try {
        $winhttp = @(& netsh winhttp show proxy 2>&1 | ForEach-Object { ([string]$_).Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($winhttp.Count -gt 0) { $lines += ("WinHTTP：{0}" -f (($winhttp | Select-Object -First 3) -join " / ")) }
    }
    catch {
        # WinHTTP information is optional.
    }
    $lines += "若 TCP 443 通但 HTTPS 失敗，通常和 Proxy 有關。"
    $lines += "檢測方式：HKCU Internet Settings 登錄值、WebRequest.GetSystemWebProxy、netsh winhttp show proxy"
    $lines += "手動驗證：netsh winhttp show proxy"
    Add-CheckResult -Category "IT 診斷資料" -Check "Proxy 設定" -Status "INFO" -Message ("使用者 Proxy：{0}；HTTPS 實際使用的 Proxy：{1}。" -f $userProxy, $effective) -Details ($lines -join [Environment]::NewLine) -Tag "proxy" -Scope "IT" | Out-Null
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
                $status = Add-NetworkErrorCause $_.Exception $_.Exception.Message -SingleLine
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
        Add-CheckResult -Category "IT 診斷資料" -Check "Traceroute（前幾跳）" -Status "ERROR" -Message "Traceroute 無法執行。" -Details (Get-ExceptionDetails $_) -Diagnostics (Get-ExceptionDiagnostics $_) -Tag "traceroute" -Scope "IT" | Out-Null
        return
    }

    $lines = @()
    foreach ($hop in $hops) {
        $lines += ("第 {0} 跳：{1}（{2}）{3} ms" -f $hop.Hop, $hop.Address, $hop.Status, $hop.ElapsedMs)
    }
    $lines += ("檢測方式：.NET Ping 以 TTL 1..{0} 逐跳探測，每跳 1000 ms；沒有回應的跳顯示為 *。" -f $maxHops)
    $lines += ("手動驗證：tracert -d -h {0} {1}" -f $maxHops, $target)
    $reachedText = "否"
    if (@($hops | Where-Object { $_.Reached }).Count -gt 0) { $reachedText = "是" }
    Add-CheckResult -Category "IT 診斷資料" -Check "Traceroute（前幾跳）" -Status "INFO" -Message ("{0}：探測 {1} 跳，抵達目的地：{2}。" -f $target, $hops.Count, $reachedText) -Details ($lines -join [Environment]::NewLine) -Tag "traceroute" -Scope "IT" | Out-Null
}

function Add-DriverInfoResult {
    param([object[]]$Adapters)

    if (-not (Test-IsTrueFlag $script:Config.Checks.DriverInfo)) { return }

    $physical = @($Adapters | Where-Object { $_.IsPhysical -eq $true })
    if ($physical.Count -eq 0) {
        Add-CheckResult -Category "IT 診斷資料" -Check "網卡驅動程式" -Status "INFO" -Message "沒有已連線的實體網卡，無驅動程式資訊。" -Details "手動驗證：Get-NetAdapter | Format-List Name, DriverVersion, DriverDate" -Tag "drivers" -Scope "IT" | Out-Null
        return
    }

    $lines = @()
    foreach ($adapter in $physical) {
        $lines += ("{0}：{1}，驅動 {2}（{3}，{4}），媒體 {5}" -f $adapter.Name, $adapter.Description, (ConvertTo-DisplayString $adapter.DriverVersion), (ConvertTo-DisplayString $adapter.DriverDate), (ConvertTo-DisplayString $adapter.DriverProvider), (ConvertTo-DisplayString $adapter.MediaType))
    }
    $lines += "檢測方式：Get-NetAdapter 的 DriverVersion / DriverDate / DriverProvider"
    $lines += "手動驗證：Get-NetAdapter | Format-List Name, DriverVersion, DriverDate"
    Add-CheckResult -Category "IT 診斷資料" -Check "網卡驅動程式" -Status "INFO" -Message ("{0} 張實體網卡；驅動版本列於詳細資料。" -f $physical.Count) -Details ($lines -join [Environment]::NewLine) -Tag "drivers" -Scope "IT" | Out-Null
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
        Add-CheckResult -Category "TCP 重傳" -Check "系統計數器" -Status "ERROR" -Message "沒有完整的前後 TCP 計數器資料。" -Details "" -Tag "tcp-retransmissions" | Out-Null
        return
    }

    $counterErrors = @()
    $counterErrors += @($Before.Errors)
    $counterErrors += @($After.Errors)
    foreach ($errorItem in $counterErrors) {
        Add-CheckResult -Category "TCP 重傳" -Check ("{0} 計數器" -f $errorItem.Protocol) -Status "ERROR" -Message "無法讀取 TCP 重傳計數器。" -Details $errorItem.Error -Diagnostics $errorItem.Diagnostics -Tag "tcp-retransmissions" | Out-Null
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
            Add-CheckResult -Category "TCP 重傳" -Check $protocol -Status "ERROR" -Message "計數器在檢測期間重設或溢位，無法計算增量。" -Details ("起始 Sent={0}, Retrans={1}; 結束 Sent={2}, Retrans={3}" -f $start.SegmentsSent, $start.Retransmitted, $end.SegmentsSent, $end.Retransmitted) -Tag "tcp-retransmissions" | Out-Null
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

        if ($rate -gt 100) {
            $details += [Environment]::NewLine + "補充：比例超過 100% 代表重傳的是取樣窗之前送出的 segment——請視為比值而非百分比。"
        }

        if ($sentDelta -eq 0 -and $retransDelta -eq 0) {
            Add-CheckResult -Category "TCP 重傳" -Check $protocol -Status "INFO" -Message "取樣期間沒有足夠的 TCP 傳送流量，未發現重傳，但不能據此判定長時間狀況。" -Details $details -Tag "tcp-retransmissions" | Out-Null
            continue
        }

        if ($sentDelta -lt $minimumSegments) {
            if ($retransDelta -gt 0) {
                Add-CheckResult -Category "TCP 重傳" -Check $protocol -Status "WARN" -Message ("流量樣本偏少，但觀察到 {0} 次重傳（近似 {1}%）。" -f $retransDelta, $rate) -Details $details -Tag "tcp-retransmissions" | Out-Null
            }
            else {
                Add-CheckResult -Category "TCP 重傳" -Check $protocol -Status "INFO" -Message ("樣本只有 {0} 個傳送 segment，未觀察到重傳。" -f $sentDelta) -Details $details -Tag "tcp-retransmissions" | Out-Null
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

        Add-CheckResult -Category "TCP 重傳" -Check $protocol -Status $status -Message ("傳送 {0}、重傳 {1}，近似重傳比例 {2}%。" -f $sentDelta, $retransDelta, $rate) -Details $details -Tag "tcp-retransmissions" | Out-Null
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
    $failCount = @($script:Results | Where-Object { [string]$_.Scope -ne "IT" -and $_.Status -eq "FAIL" }).Count
    $errorCount = @($script:Results | Where-Object { [string]$_.Scope -ne "IT" -and $_.Status -eq "ERROR" }).Count
    $warnCount = @($script:Results | Where-Object { [string]$_.Scope -ne "IT" -and $_.Status -eq "WARN" }).Count

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
# 報告輸出：產生 HTML、TXT、JSON；任一寫入錯誤都會留下詳細例外。
# -----------------------------------------------------------------------------
# v1.2：以結果標籤判定的語言中立指紋；供「要告訴 IT 的話」區段與精靈使用。
function Get-FingerprintSummary {
    $results = @($script:Results)
    $overall = Get-OverallStatus

    $adaptersFail = @($results | Where-Object { $_.Tag -eq "adapters" -and $_.Status -eq "FAIL" }).Count -gt 0
    $gatewayConfigFail = @($results | Where-Object { $_.Tag -eq "gateway-config" -and $_.Status -eq "FAIL" }).Count -gt 0
    $gatewayPingPass = @($results | Where-Object { $_.Tag -eq "ping-gateway" -and $_.Status -eq "PASS" }).Count -gt 0
    $gatewayPingBad = @($results | Where-Object { $_.Tag -eq "ping-gateway" -and $_.Status -eq "FAIL" }).Count -gt 0
    $groupFail = @($results | Where-Object { $_.Tag -eq "connectivity-group" -and $_.Status -eq "FAIL" }).Count -gt 0
    $groupPass = @($results | Where-Object { $_.Tag -eq "connectivity-group" -and $_.Status -eq "PASS" }).Count -gt 0
    $dnsFail = @($results | Where-Object { $_.Tag -eq "dns" -and ($_.Status -eq "FAIL" -or $_.Status -eq "WARN") }).Count -gt 0
    $dnsPass = @($results | Where-Object { $_.Tag -eq "dns" -and $_.Status -eq "PASS" }).Count -gt 0
    $tcpPass = @($results | Where-Object { $_.Tag -eq "tcp" -and $_.Status -eq "PASS" }).Count -gt 0
    $qualityTags = @("ping-target", "ping-gateway", "tcp-retransmissions", "adapter-errors")
    $qualityIssue = @($results | Where-Object { ($qualityTags -contains $_.Tag) -and ($_.Status -eq "WARN" -or $_.Status -eq "FAIL") }).Count -gt 0
    $otherProblem = @($results | Where-Object { [string]$_.Scope -ne "IT" -and ($_.Status -eq "WARN" -or $_.Status -eq "FAIL") -and ($qualityTags -notcontains $_.Tag) }).Count -gt 0

    $key = "healthy"
    if ($adaptersFail -or $gatewayConfigFail) { $key = "local" }
    elseif ($gatewayPingBad -and -not $gatewayPingPass) { $key = "gateway-unreachable" }
    elseif ($gatewayPingPass -and $groupFail -and -not $groupPass) { $key = "gateway-up-internet-dead" }
    elseif ($dnsFail -and -not $dnsPass -and ($groupPass -or $tcpPass)) { $key = "dns" }
    elseif ($qualityIssue -and -not $otherProblem) { $key = "quality" }
    elseif ($overall.Code -eq "FAIL") { $key = "mixed" }
    elseif ($overall.Code -eq "ERROR") { $key = "incomplete" }
    elseif ($overall.Code -eq "WARN") { $key = "attention" }

    $title = ""
    $lines = @()
    switch ($key) {
        "local" { $title = "本機連線問題"; $lines = @("找不到可用的網卡或預設閘道。", "問題在這台電腦或它的連線：網路線、Wi-Fi 連線、網卡停用或 DHCP 沒有回應。", "用同一個網路上的另一台裝置測試，確認是否只有這台電腦有問題。") }
        "gateway-unreachable" { $title = "閘道沒有回應"; $lines = @("已設定預設閘道，但閘道不回應 Ping。", "問題在這台電腦和路由器之間：連線、Wi-Fi、交換器或路由器本身。", "確認連線燈號或 Wi-Fi 訊號，以及其他裝置能否連到路由器。") }
        "gateway-up-internet-dead" { $title = "閘道正常，網際網路不通"; $lines = @("路由器有回應，但往外的連線失敗。", "問題在路由器或更外層：WAN 連線、ISP 或上游防火牆。", "查看路由器的 WAN 狀態，以及其他裝置是否同樣無法上網。") }
        "dns" { $title = "名稱解析失敗"; $lines = @("用 IP 直接連線正常，但主機名稱無法解析。", "問題在 DNS：設定的 DNS 伺服器、過濾服務或名稱本身。", "把報告中的 DNS 伺服器和公司預期設定比對。") }
        "quality" { $title = "連線正常但品質不佳"; $lines = @("連線可用，但封包遺失、延遲、重傳或網卡錯誤超過門檻。", "常見原因：Wi-Fi 訊號弱、線路壅塞、網路線或連接埠故障。", "問題發生時再跑一次並比較數字。") }
        "mixed" { $title = "有必要檢查未通過"; $lines = @("至少一項必要檢查未通過，請看下方失敗的項目。", "把報告原樣交給 IT。") }
        "incomplete" { $title = "部分檢查無法執行"; $lines = @("沒有發現故障，但部分步驟在這台電腦上無法完成。", "把報告原樣交給 IT，原因記錄在詳細資料中。") }
        "attention" { $title = "有需要注意的警告"; $lines = @("沒有必要檢查失敗，但有檢查提出警告，請看標示的項目。", "把報告原樣交給 IT。") }
        default { $title = "全部通過"; $lines = @("本次執行的所有檢查都通過。", "若問題仍然存在，可能在應用程式或伺服器端，或是時好時壞；問題發生時再跑一次。") }
    }
    $lines += "把 HTML 報告（或 JSON 檔）交給 IT。報告內含電腦名稱、使用者名稱、網卡 MAC 位址與 Wi-Fi 網路名稱。"

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
        $organization = "未指定單位"
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
            $diagnosticsNote = "技術診斷資訊（腳本位置與呼叫堆疊）只記錄在 JSON 報告中。"
            if ([string]::IsNullOrWhiteSpace($detailsText)) {
                $detailsText = $diagnosticsNote
            }
            else {
                $detailsText += [Environment]::NewLine + $diagnosticsNote
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($detailsText)) {
            $detailsEncoded = ConvertTo-HtmlEncoded $detailsText
            $detailsHtml = "<details$detailsOpen><summary>顯示詳細資料</summary><pre>$detailsEncoded</pre></details>"
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
.tools { margin-bottom: 8px; } .tools button { border: 1px solid #cbd5e0; background: #edf2f7; border-radius: 6px; padding: 5px 12px; cursor: pointer; font: inherit; }
.tell ul { margin: 6px 0 0 18px; } .tell li { margin: 3px 0; }
details.itblock > summary { cursor: pointer; } .ith2 { font-size: 19px; font-weight: 700; }
@media (max-width: 800px) { .cards { grid-template-columns: repeat(3, 1fr); } .meta { grid-template-columns: 1fr; } table { display: block; overflow-x: auto; } }
</style>
</head>
<body>
<header>
  <h1>網路健檢報告</h1>
  <p>單位：$(ConvertTo-HtmlEncoded $organization)　電腦：$(ConvertTo-HtmlEncoded $SystemSummary.ComputerName)</p>
  <p>產生時間：$(ConvertTo-HtmlEncoded $generatedAt)　檢測耗時：約 $(ConvertTo-HtmlEncoded $duration) 秒</p>
  <p>執行設定：$runProfile</p>
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

  <section class="tell">
    <h2>要告訴 IT 的話</h2>
    <p><strong>$(ConvertTo-HtmlEncoded $fingerprint.Title)</strong></p>
    <ul>
$fingerprintItems
    </ul>
  </section>

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
    <div class="tools"><button type="button" onclick="nhcToggle(true)">全部展開</button> <button type="button" onclick="nhcToggle(false)">全部收合</button></div>
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

  <section>
    <details class="itblock"$detailsOpen>
      <summary><span class="ith2">$(ConvertTo-HtmlEncoded ("IT 診斷資料（{0} 項）" -f $itCount))</span></summary>
      <div class="notice" style="margin-top:12px;">給 IT 的參考資料（路由、閘道鄰居、Proxy、traceroute、Wi-Fi 無線、驅動程式）。這些項目不影響整體結果。</div>
      <div style="overflow-x:auto; margin-top:14px;">
        <table>
        <thead><tr><th>時間</th><th>分類</th><th>檢查項目</th><th>結果</th><th>說明</th></tr></thead>
          <tbody>
$($itRows.ToString())
          </tbody>
        </table>
      </div>
    </details>
  </section>

  <footer>NetworkHealthCheck $($script:ToolVersion)。本工具只讀取系統資訊並執行連線測試，不會修改 IP、DNS、路由或防火牆設定。</footer>
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
    [void]$builder.AppendLine("執行設定：$(Get-RunProfileText)")
    $fingerprint = Get-FingerprintSummary
    [void]$builder.AppendLine("要告訴 IT 的話：$($fingerprint.Title)")
    foreach ($line in @($fingerprint.Lines)) {
        [void]$builder.AppendLine("  - $line")
    }
    $itHeaderWritten = $false
    [void]$builder.AppendLine("")

    foreach ($result in @(@($script:Results | Where-Object { [string]$_.Scope -ne "IT" }) + @($script:Results | Where-Object { [string]$_.Scope -eq "IT" }))) {
        if ([string]$result.Scope -eq "IT" -and -not $itHeaderWritten) {
            [void]$builder.AppendLine("IT 診斷資料")
            [void]$builder.AppendLine("-" * 40)
            $itHeaderWritten = $true
        }
        [void]$builder.AppendLine(("[{0}] [{1}] {2}／{3}" -f (Get-StatusText $result.Status), $result.Time.ToString("HH:mm:ss"), $result.Category, $result.Check))
        [void]$builder.AppendLine("  $($result.Message)")
        if (-not [string]::IsNullOrWhiteSpace([string]$result.Details)) {
            foreach ($line in ([string]$result.Details -split "`r?`n")) {
                [void]$builder.AppendLine("    $line")
            }
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$result.Diagnostics)) {
            [void]$builder.AppendLine("    技術診斷資訊（腳本位置與呼叫堆疊）只記錄在 JSON 報告中。")
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
        [void]$writeErrors.Add("HTML 報告寫入失敗：$(Get-ExceptionDetails $_ -IncludeDiagnostics)")
    }

    try {
        $text = New-TextReportContent -SystemSummary $systemSummary -Overall $overall -Counts $counts
        Write-Utf8File -Path $textPath -Content $text
        $script:LastTextReport = $textPath
    }
    catch {
        [void]$failedFormats.Add("TXT")
        [void]$writeErrors.Add("文字報告寫入失敗：$(Get-ExceptionDetails $_ -IncludeDiagnostics)")
    }

    try {
        $json = $reportObject | ConvertTo-Json -Depth 10
        Write-Utf8File -Path $jsonPath -Content $json
        $script:LastJsonReport = $jsonPath
    }
    catch {
        [void]$failedFormats.Add("JSON")
        [void]$writeErrors.Add("JSON 報告寫入失敗：$(Get-ExceptionDetails $_ -IncludeDiagnostics)")
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

# Backlog #3：成功寫入的格式仍可使用；三種格式全部失敗時才寫一份緊急報告。
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
        Write-UiLog -Status "ERROR" -Text "報告產生失敗。"
        $emergencyPath = Write-EmergencyReport -Title "網路健檢報告產生失敗" -ErrorDetails ($writeErrors -join [Environment]::NewLine)
        Set-UiProgress -Percent 100 -Text "報告產生失敗"
        Update-OverallUi -Overall $SaveResult.Overall
        if ($script:GuiAvailable) {
            $script:ReportPathLabel.Text = "報告無法寫入"
            $script:OpenFolderButton.Enabled = [bool](Test-Path -LiteralPath $script:OutputDirectory)
            $message = "報告產生失敗。"
            if ($null -ne $emergencyPath) {
                $message += "`r`n已寫入緊急錯誤報告：$emergencyPath"
            }
            [System.Windows.Forms.MessageBox]::Show($message, "網路健檢錯誤", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        }
    }
    elseif ($failedFormats.Count -gt 0) {
        Set-UiProgress -Percent 100 -Text "檢測完成"
        Write-UiLog -Status "WARN" -Text ("報告已產生，但有 {0} 種格式無法寫入（{1}）。主要報告：{2}" -f $failedFormats.Count, ($failedFormats -join ", "), $primary)
        Update-OverallUi -Overall $SaveResult.Overall
        if ($script:GuiAvailable) {
            $script:ReportPathLabel.Text = "報告：$primary"
            $script:OpenReportButton.Enabled = $true
            $script:OpenJsonButton.Enabled = (-not [string]::IsNullOrWhiteSpace([string]$SaveResult.Json))
            $script:OpenFolderButton.Enabled = $true
            [System.Windows.Forms.MessageBox]::Show(("3 種報告格式中有 {0} 種無法寫入（{1}）。報告已存為：{2}" -f $failedFormats.Count, ($failedFormats -join ", "), $primary), "網路健檢警告", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        }
    }
    else {
        Set-UiProgress -Percent 100 -Text "檢測完成"
        Write-UiLog -Status "PASS" -Text ("報告已產生：{0}" -f $primary)
        Update-OverallUi -Overall $SaveResult.Overall
        if ($script:GuiAvailable) {
            $script:ReportPathLabel.Text = "報告：$primary"
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

    $partialResults = "（尚無檢測結果）"
    if ($null -ne $script:Results -and $script:Results.Count -gt 0) {
        $partialBuilder = New-Object System.Text.StringBuilder
        foreach ($result in $script:Results) {
            [void]$partialBuilder.AppendLine(("[{0}] {1}／{2}：{3}" -f (Get-StatusText $result.Status), $result.Category, $result.Check, $result.Message))
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
        $script:OpenJsonButton.Enabled = $false
        $script:OverallLabel.Text = "結果：檢測進行中"
        $script:OverallLabel.ForeColor = [System.Drawing.Color]::FromArgb(31, 41, 51)
        $script:ReportPathLabel.Text = "報告尚未產生"
    }

    Write-UiLog -Status "INFO" -Text "網路健檢開始。檢測只讀取資訊，不會修改網路設定。"
    Set-UiProgress -Percent 2 -Text "初始化"

    if ($null -ne $script:ConfigLoadError) {
        Add-CheckResult -Category "程式設定" -Check "設定檔" -Status "ERROR" -Message "設定檔無法載入，已使用內建預設值。" -Details $script:ConfigLoadError -Diagnostics $script:ConfigLoadDiagnostics -Tag "config-file" | Out-Null
    }
    else {
        Add-CheckResult -Category "程式設定" -Check "設定檔" -Status "PASS" -Message ("已載入：{0}" -f $script:EffectiveConfigPath) -Details "" -Tag "config-file" | Out-Null
    }

    foreach ($startupMessage in @(@($script:StartupMessages) + @($script:RunOptionMessages))) {
        Add-CheckResult -Category "程式環境" -Check "啟動提示" -Status "WARN" -Message $startupMessage -Details "" -Tag "startup" | Out-Null
    }

    Invoke-CheckStep -Category "程式設定" -Name "驗證設定值" -Progress 4 -Action {
        Test-ConfigurationSemantics
    } | Out-Null

    if (-not (Test-IsWindowsPlatform)) {
        Add-CheckResult -Category "程式環境" -Check "作業系統" -Status "FAIL" -Message "此版本只支援 Windows 10/11 或相容 Windows Server。" -Details ([System.Environment]::OSVersion.VersionString) -Tag "environment" | Out-Null
        $script:RunFinishedAt = Get-Date
        return (Complete-ReportStage -SaveResult (Save-Reports))
    }

    if ($PSVersionTable.PSVersion.Major -lt 5) {
        Add-CheckResult -Category "程式環境" -Check "PowerShell 版本" -Status "FAIL" -Message "需要 PowerShell 5.1 或更新版本。" -Details ("目前版本：{0}" -f $PSVersionTable.PSVersion) -Tag "environment" | Out-Null
        $script:RunFinishedAt = Get-Date
        return (Complete-ReportStage -SaveResult (Save-Reports))
    }
    else {
        Add-CheckResult -Category "程式環境" -Check "PowerShell 版本" -Status "PASS" -Message ("目前版本：{0}" -f $PSVersionTable.PSVersion) -Details ("語言模式：{0}。受限模式（應用程式控制：WDAC／AppLocker）會讓本工具在任何檢測開始前就停止，並改為輸出環境報告。" -f $ExecutionContext.SessionState.LanguageMode) -Tag "environment" | Out-Null
    }

    Invoke-CheckStep -Category "系統資訊" -Name "取得電腦與作業系統資訊" -Progress 7 -Action {
        $summary = Get-SystemSummary
        Add-CheckResult -Category "系統資訊" -Check "電腦" -Status "INFO" -Message ("{0}，使用者 {1}。" -f $summary.ComputerName, $summary.UserName) -Details ("作業系統：{0} ({1})`r`nPowerShell：{2}" -f $summary.OperatingSystem, $summary.OperatingVersion, $summary.PowerShellVersion) -Tag "system" | Out-Null
    } | Out-Null

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

    Invoke-CheckStep -Category "IT 診斷資料" -Name "收集 IT 診斷資料（Wi-Fi、路由、閘道鄰居、Proxy、traceroute、驅動程式）" -Progress 74 -Scope "IT" -Action {
        Add-WifiRfResult
        Add-RouteTableResult
        Add-GatewayNeighborResult -PrimaryAdapters $script:PrimaryAdapters
        Add-ProxySettingsResult
        Add-TracerouteResult
        Add-DriverInfoResult -Adapters $networkSnapshot
    } | Out-Null

    $minimumSampleSeconds = [math]::Max(1, (ConvertTo-IntSafe $script:Config.Tests.RetransmissionSampleSeconds 8))
    Wait-ForMinimumTcpSample -StartTime $tcpSampleStart -MinimumSeconds $minimumSampleSeconds

    $adapterStatsAfter = Invoke-CheckStep -Category "網卡錯誤計數" -Name "取得網卡錯誤結束值" -Progress 82 -Action {
        return (Get-AdapterStatisticsSnapshot)
    }

    Invoke-CheckStep -Category "網卡錯誤計數" -Name "分析網卡錯誤與丟棄" -Progress 85 -Action {
        if ($null -eq $adapterStatsBefore -or $null -eq $adapterStatsAfter) {
            Add-CheckResult -Category "網卡錯誤計數" -Check "前後比較" -Status "ERROR" -Message "缺少基準值或結束值，無法計算錯誤增量。" -Details "" -Tag "adapter-errors" | Out-Null
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
        return (Complete-ReportStage -SaveResult (Save-Reports))
    }
    catch {
        $details = Get-ExceptionDetails $_ -IncludeDiagnostics
        Write-UiLog -Status "ERROR" -Text "報告產生失敗。"
        $emergencyPath = Write-EmergencyReport -Title "網路健檢報告產生失敗" -ErrorDetails $details
        if ($script:GuiAvailable) {
            $message = "報告產生失敗。"
            if ($null -ne $emergencyPath) {
                $message += "`r`n已寫入緊急錯誤報告：$emergencyPath"
            }
            [System.Windows.Forms.MessageBox]::Show($message, "網路健檢錯誤", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        }
        # Backlog #2：報告階段的非預期錯誤只在這裡處理一次，不再重新拋出。
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
            $script:StartButton.Text = "重新檢測"
        }
    }
}

function Start-ConsoleMode {
    try {
        $report = Run-AllChecks
        Write-Host ""
        Write-Host ("整體結果：{0}" -f $report.Overall.Text)
        Write-Host ("HTML 報告：{0}" -f (ConvertTo-DisplayString $report.Html "（未寫入）"))
        Write-Host ("文字報告：{0}" -f (ConvertTo-DisplayString $report.Text "（未寫入）"))
        Write-Host ("JSON 報告：{0}" -f (ConvertTo-DisplayString $report.Json "（未寫入）"))
        if (@($report.FailedFormats).Count -gt 0) {
            Write-Host ("未寫入的報告格式：{0}" -f (@($report.FailedFormats) -join ", ")) -ForegroundColor Yellow
        }
        if ($null -ne $report.EmergencyPath) {
            Write-Host "緊急錯誤報告：$($report.EmergencyPath)"
        }
        if ($report.Succeeded) {
            return 0
        }
        return 1
    }
    catch {
        $details = Get-ExceptionDetails $_ -IncludeDiagnostics
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
function Set-OptionsPanelValues {
    $controls = $script:OptionsPanel
    $options = $script:RunOptions
    if ($null -eq $controls -or $null -eq $options) {
        return
    }

    $controls["PingTarget"].Text = (@($options.RawTargets.Ping) -join ", ")
    $controls["DnsName"].Text = (@($options.RawTargets.Dns) -join ", ")
    $controls["TcpTarget"].Text = (@($options.RawTargets.Tcp) -join ", ")
    $controls["HttpUrl"].Text = (@($options.RawTargets.Http) -join " ")
    # 設定值超過旋轉鈕預設範圍（Ping 20 次、取樣 120 秒）時放寬範圍而不截斷，未更動就開始也會以設定值執行（v1.2.1）。
    $controls["PingCount"].Maximum = [math]::Max(20, $options.PingCount)
    $controls["PingCount"].Value = [math]::Max(1, $options.PingCount)
    $controls["SampleSeconds"].Maximum = [math]::Max(120, $options.SampleSeconds)
    $controls["SampleSeconds"].Value = [math]::Max(1, $options.SampleSeconds)
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
        HttpUrl        = @(([string]$controls["HttpUrl"].Text) -split '\s+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
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
        [void]$script:StartupMessages.Add("圖形介面無法啟動，已改用文字模式。錯誤：$($_.Exception.Message)")
        return $false
    }

    try {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "網路健檢工具 $($script:ToolVersion)"
    if ($script:Interactive) { $form.Text += "（IT）" }
    $form.StartPosition = "CenterScreen"
    $offset = 0
    if ($script:Interactive) { $offset = 190 }
    $formHeight = 700 + $offset
    try {
        $workingHeight = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea.Height
        if ($formHeight -gt $workingHeight - 40) { $formHeight = [math]::Max(400, $workingHeight - 40) }
    }
    catch {
        $formHeight = 700 + $offset
    }
    $bottomY = $formHeight - 116
    $form.Size = New-Object System.Drawing.Size(940, $formHeight)
    $form.MinimumSize = New-Object System.Drawing.Size(780, [math]::Min(560 + $offset, $formHeight))
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

    $script:OptionsPanel = $null
    if ($script:Interactive) {
        $panel = New-Object System.Windows.Forms.GroupBox
        $panel.Text = "執行選項（IT）"
        $panel.Location = New-Object System.Drawing.Point(22, 84)
        $panel.Size = New-Object System.Drawing.Size(880, 180)
        $panel.Anchor = "Top,Left,Right"
        $form.Controls.Add($panel)

        $controls = @{}
        foreach ($item in @(
            @{ Text = "額外 Ping"; X = 12; Y = 26 },
            @{ Text = "額外 DNS"; X = 320; Y = 26 },
            @{ Text = "Ping 次數"; X = 630; Y = 26 },
            @{ Text = "額外 TCP（host:port）"; X = 12; Y = 58 },
            @{ Text = "額外 URL"; X = 320; Y = 58 },
            @{ Text = "取樣秒數"; X = 630; Y = 58 }
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
        foreach ($item in @(@{ Key = "WifiRf"; Text = "Wi-Fi 無線"; Width = 110 }, @{ Key = "Traceroute"; Text = "Traceroute"; Width = 110 })) {
            $check = New-Object System.Windows.Forms.CheckBox
            $check.Text = $item.Text
            $check.Location = New-Object System.Drawing.Point($x, 90)
            $check.Size = New-Object System.Drawing.Size($item.Width, 24)
            $panel.Controls.Add($check)
            $controls[$item.Key] = $check
            $x += $item.Width + 6
        }
        $hopsLabel = New-Object System.Windows.Forms.Label
        $hopsLabel.Text = "Traceroute 跳數"
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
        $expand.Text = "HTML 預設展開細節"
        $expand.Location = New-Object System.Drawing.Point(($x + 185), 90)
        $expand.Size = New-Object System.Drawing.Size(220, 24)
        $panel.Controls.Add($expand)
        $controls["ExpandDetails"] = $expand
        $x = 12
        foreach ($item in @(@{ Key = "RouteTable"; Text = "路由"; Width = 100 }, @{ Key = "GatewayNeighbor"; Text = "閘道 ARP"; Width = 130 }, @{ Key = "ProxySettings"; Text = "Proxy"; Width = 90 }, @{ Key = "DriverInfo"; Text = "驅動程式"; Width = 110 })) {
            $check = New-Object System.Windows.Forms.CheckBox
            $check.Text = $item.Text
            $check.Location = New-Object System.Drawing.Point($x, 120)
            $check.Size = New-Object System.Drawing.Size($item.Width, 24)
            $panel.Controls.Add($check)
            $controls[$item.Key] = $check
            $x += $item.Width + 6
        }
        $resetButton = New-Object System.Windows.Forms.Button
        $resetButton.Text = "還原設定檔"
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
    $overall.Text = "結果：尚未開始"
    $overall.Font = New-Object System.Drawing.Font($form.Font.FontFamily, 11, [System.Drawing.FontStyle]::Bold)
    $overall.AutoSize = $false
    # New-Object 的引數以運算式模式解析，逗號優先於「+」：算術運算一律另外加括號（v1.2.1）。
    $overall.Location = New-Object System.Drawing.Point(22, (84 + $offset))
    $overall.Size = New-Object System.Drawing.Size(880, 28)
    $overall.Anchor = "Top,Left,Right"
    $form.Controls.Add($overall)

    $progressLabel = New-Object System.Windows.Forms.Label
    $progressLabel.Text = "準備中"
    if ($script:Interactive) { $progressLabel.Text = "就緒，調整選項後按「開始檢測」" }
    $progressLabel.Location = New-Object System.Drawing.Point(22, (119 + $offset))
    $progressLabel.Size = New-Object System.Drawing.Size(880, 22)
    $progressLabel.Anchor = "Top,Left,Right"
    $form.Controls.Add($progressLabel)

    $progress = New-Object System.Windows.Forms.ProgressBar
    $progress.Location = New-Object System.Drawing.Point(22, (143 + $offset))
    $progress.Size = New-Object System.Drawing.Size(880, 22)
    $progress.Minimum = 0
    $progress.Maximum = 100
    $progress.Value = 0
    $progress.Anchor = "Top,Left,Right"
    $form.Controls.Add($progress)

    $log = New-Object System.Windows.Forms.RichTextBox
    $log.Location = New-Object System.Drawing.Point(22, (178 + $offset))
    $logHeight = $bottomY - 16 - (178 + $offset)
    if ($logHeight -lt 36) {
        $logHeight = 36
        $form.AutoScroll = $true
        $form.AutoScrollMinSize = New-Object System.Drawing.Size(900, (700 + $offset))
    }
    $log.Size = New-Object System.Drawing.Size(880, $logHeight)
    $log.Anchor = "Top,Bottom,Left,Right"
    $log.ReadOnly = $true
    $log.DetectUrls = $false
    $log.BackColor = [System.Drawing.Color]::White
    $log.Font = New-Object System.Drawing.Font("Consolas", 9.5)
    $form.Controls.Add($log)

    $startButton = New-Object System.Windows.Forms.Button
    $startButton.Text = "開始檢測"
    $startButton.Location = New-Object System.Drawing.Point(22, $bottomY)
    $startButton.Size = New-Object System.Drawing.Size(120, 34)
    $startButton.Anchor = "Bottom,Left"
    $form.Controls.Add($startButton)

    $openReportButton = New-Object System.Windows.Forms.Button
    $openReportButton.Text = "開啟報告"
    $openReportButton.Location = New-Object System.Drawing.Point(152, $bottomY)
    $openReportButton.Size = New-Object System.Drawing.Size(120, 34)
    $openReportButton.Anchor = "Bottom,Left"
    $openReportButton.Enabled = $false
    $form.Controls.Add($openReportButton)

    $openFolderButton = New-Object System.Windows.Forms.Button
    $openFolderButton.Text = "開啟報告資料夾"
    $openFolderButton.Location = New-Object System.Drawing.Point(282, $bottomY)
    $openFolderButton.Size = New-Object System.Drawing.Size(150, 34)
    $openFolderButton.Anchor = "Bottom,Left"
    $openFolderButton.Enabled = $false
    $form.Controls.Add($openFolderButton)

    $openJsonButton = New-Object System.Windows.Forms.Button
    $openJsonButton.Text = "開啟 JSON"
    $openJsonButton.Location = New-Object System.Drawing.Point(442, $bottomY)
    $openJsonButton.Size = New-Object System.Drawing.Size(110, 34)
    $openJsonButton.Anchor = "Bottom,Left"
    $openJsonButton.Enabled = $false
    $form.Controls.Add($openJsonButton)

    $closeButton = New-Object System.Windows.Forms.Button
    $closeButton.Text = "關閉"
    $closeButton.Location = New-Object System.Drawing.Point(782, $bottomY)
    $closeButton.Size = New-Object System.Drawing.Size(120, 34)
    $closeButton.Anchor = "Bottom,Right"
    $form.Controls.Add($closeButton)

    $reportPathLabel = New-Object System.Windows.Forms.Label
    $reportPathLabel.Text = "報告尚未產生"
    $reportPathLabel.Location = New-Object System.Drawing.Point(22, ($bottomY + 44))
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
                throw "找不到報告檔案。"
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

    $openJsonButton.Add_Click({
        try {
            if ($null -ne $script:LastJsonReport -and (Test-Path -LiteralPath $script:LastJsonReport)) {
                Start-Process -FilePath "notepad.exe" -ArgumentList ('"{0}"' -f $script:LastJsonReport) -ErrorAction Stop
            }
            else {
                throw "找不到 JSON 報告。"
            }
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show(("無法開啟 JSON 報告：{0}" -f $_.Exception.Message), "開啟 JSON 失敗", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
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
        [void]$script:StartupMessages.Add("圖形介面無法啟動，已改用文字模式。錯誤：$($_.Exception.Message)")
        return $false
    }
}

# -------------------- Program entry point --------------------
$exitCode = 0

try {
    $script:BaseConfig = Load-Configuration -RequestedPath $ConfigPath
    if (Test-IsRunningFromArchive $script:BaseDirectory) {
        [void]$script:StartupMessages.Add("目前是從壓縮檔內執行。請先將 ZIP 解壓縮到實際的資料夾，否則報告會寫進隨後消失的暫存位置。")
    }
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
