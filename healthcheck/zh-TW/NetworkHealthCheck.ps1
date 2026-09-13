# PositionalBinding is off, so a value that no switch claimed is refused by PowerShell before the script starts
# rather than binding to -ConfigPath: "-PingTarget a b" used to test a, record "Configuration file not found: b"
# as an Unable to Check row, run on the built-in defaults and end Test Incomplete, losing the second target in
# silence (backlog #36).
[CmdletBinding(PositionalBinding = $false)]
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
    [int]$PingCountMaximum = 0,
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

$script:ToolVersion = "1.2.14"
$script:BaseDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path

# -----------------------------------------------------------------------------
# Backlog #18：應用程式控制政策（WDAC、AppLocker）可能把 PowerShell 限制在受限語言模式，該模式下腳本不得建立 .NET
# 物件。本工具從第一行就需要它們——下面那個 ArrayList 就已經不被允許——因此在那種機器上根本無法執行，而使用者只會
# 看到引擎自己的「Cannot create type. Only core types are supported in this language mode.」，那句話對他毫無幫助。
# 所以這一行以上的程式碼與 Write-EnvironmentReport 都只用受限模式允許的東西：cmdlet、運算子與屬性讀取，不用 .NET
# 型別、不用 New-Object。
# -----------------------------------------------------------------------------
function Test-IsRunningFromArchive {
    param([string]$Path)

    # Windows 會把 ZIP 開在暫時檢視中，並把被按兩下的那個檔案解到裡面：Windows 10 是 %TEMP%\Temp1_<名稱>.zip\...，
    # Windows 11 是 %TEMP%\<guid>_<名稱>.zip.<hex>\...，後綴是幾位十六進位數字（.684、.bc4），不是十進位數字（待辦 #26）。
    # 從那裡執行看似可以，但該資料夾會隨檢視消失，寫進去的檔案也一起消失。
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    return ($Path -match "\.zip(\.[0-9a-f]+)?[\\/]")
}

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

    # 先寫腳本資料夾，不可寫時改寫暫存資料夾——與報告採用相同的順序。唯一的例外是 Windows 壓縮檔檢視內的資料夾：
    # 它可寫但會消失，而這個檔案是一次來不及產出報告的執行所留下的唯一痕跡，因此改寫到檢視之外。下方的壓縮檔警告
    # 在這條路徑上永遠不會執行，因為守門會先結束程式。
    $name = "NetworkHealthCheck_ENVIRONMENT_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".txt"
    $folders = @()
    if (-not (Test-IsRunningFromArchive $script:BaseDirectory)) { $folders += $script:BaseDirectory }
    $folders += $env:TEMP
    foreach ($folder in $folders) {
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
    if (Test-IsRunningFromArchive $script:BaseDirectory) {
        Write-Host "目前是從壓縮檔內執行，因此下面這個檔案已改寫到壓縮檔檢視之外。請先將 ZIP 解壓縮到實際的資料夾再執行。"
    }
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
$script:DroppedTargets = New-Object System.Collections.ArrayList
$script:RetransmissionRateComputed = $false
$script:TcpConnectSampleCount = 0
$script:PendingPingSamples = New-Object System.Collections.ArrayList
$script:TcpIntervalSampling = $null
$script:PanelWarned = $false
$script:PanelHints = $null
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
        if ($current -is [System.TimeoutException]) {
            # 本工具自己的時限（Invoke-DnsLookup、Invoke-TcpConnectionTest）到期時作業系統仍在等待：沒有回應也沒有被拒絕，
            # 這正是防火牆默默丟棄封包或主機無法到達時的樣子。1.2.3 之前這只是一個沒有原因行的 RuntimeException（待辦 #27）。
            return "在本工具自訂的時限內沒有回應：沒有任何回覆，也沒有被拒絕——這通常是防火牆默默丟棄封包，或主機無法到達。[ToolTimeout]"
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
        [string]$Scope = "Main",
        [switch]$Weightless,
        [string]$Rule = "",
        [string]$Path = ""
    )

    # -Weightless 標記一種列：徽章、訊息與統計數字都照舊，但不決定整體結果，也不影響 fingerprint（backlog #39）。
    # 標記是逐一分支加上去的：說「什麼都沒量到」的列、樣本比套用的門檻還粗的列，或陳述本次執行輸入的列。其餘一律
    # 預設保有權重——後來新增的檢查不會因為漏寫什麼而變得沒有權重，那種失誤沒有人會發現。
    # -Path 是路由表為 ping 列的探測選的那張網卡——探測前後兩次查詢一致時的介面別名——不一致、或目標以名稱給定時是空的
    # （PR #51 第 4 輪）。摘要用它把近端列和失敗的閘道列配對：經由某張網卡到達的近端主機，說明不了另一張網卡後面的網路線、
    # 無線電或交換器。同樣是在 JSON schema 2 之下附加的欄位。
    # -Rule 寫的是這一列的狀態是由哪一種量測決定的，只用在一列有不只一種量測的時候（backlog #67）：ping 的列由遺失
    # 或由延遲決定，而在 1.2.12 之前，除了這一列的文字之外沒有東西說得出是哪一種，於是 fingerprint 把一個每次探測
    # 都回應、只是回應得慢的閘道，標成「沒有回應」的閘道。沒有話可說的列——通過的列，或只有一種量測的列——這個欄位
    # 是空的；它和 Weightless 一樣，是在 JSON schema 2 之下附加的欄位。
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
        Weightless  = [bool]$Weightless
        Rule        = $Rule
        Path        = $Path
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
        [string]$Scope = "Main",
        [switch]$Weightless
    )

    # 權重跟著步驟走，不跟著標籤走（backlog #39）。step-error 是所有步驟共用的一個標籤，其中四個是品質資料的收集
    # 步驟：完全失敗的收集步驟會在這裡寫下一列 step-error，接著在後續分析裡再寫一列自己的，所以只降權後者，執行
    # 仍舊會是「檢測未完整」——這個決定會在它唯一為之而寫的那個案例上失效。那四個步驟在呼叫處自行宣告，它們產生的
    # step-error 列繼承這個標記；其餘每個步驟的 step-error 權重完全不變。

    Set-UiProgress -Percent $Progress -Text $Name
    Write-UiLog -Status "INFO" -Text ("開始：$Name")

    $result = $null
    try {
        $result = (& $Action)
    }
    catch {
        $details = Get-ExceptionDetails $_
        $diagnostics = Get-ExceptionDiagnostics $_
        Add-CheckResult -Category $Category -Check $Name -Status "ERROR" -Message "此項目無法執行，已記錄錯誤。" -Details $details -Diagnostics $diagnostics -Tag "step-error" -Scope $Scope -Weightless:$Weightless | Out-Null
        $result = $null
    }
    # backlog #65：TCP 取樣窗內讀取的到期檢查在每個步驟之後都跑一次，不論步驟做了什麼，這樣讀取最多只晚一個步驟；
    # 它絕不擲出例外，沒有開窗時什麼都不讀。
    Invoke-TcpIntervalReadIfDue
    return $result
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
            PingCountMaximum             = 21
            PingTimeoutMs                = 1200
            DnsTimeoutMs                 = 4000
            TcpTimeoutMs                 = 4000
            HttpTimeoutMs                = 6000
            RetransmissionSampleSeconds  = 8
            RetransmissionIntervalSeconds = 2
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
            # backlog #60：ping 階梯的近端那一階——這台電腦自己子網段上、不是閘道的一台主機，讓本地路徑能在沒有閘道
            # 控制平面、也沒有 WAN 參與的情況下被量到。預設不存在：工具選不出來，因為某個候選主機是不是穩定、會不會
            # 回應 ICMP，是人的判斷，所以由 IT 在這裡指定。以 IPv4 位址給定，絕不是名稱：檢查必須在送出任何東西
            # 之前就知道這台主機在本地子網段上。
            NearEndTarget = [pscustomobject][ordered]@{
                Name     = "近端主機"
                Address  = ""
                Required = $false
            }
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
            MinimumTcpRetransmissionsForVerdict = 5
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
            WifiRetryCounters = $true
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

# 四個自由輸入欄位的格式規則，只寫在這一個地方。會退回目標的只有 Test-TcpTargetSyntax：Set-RunOptions 在執行
# 開始之後用它丟掉目標，IT 面板在按下「開始檢測」時、執行開始之前也用它檢查，所以面板不可能和實際執行的
# 判斷不一致。另外三條規則不丟掉任何東西——被它們退回的值仍然保留自己的列，並以「本次執行輸入」的事實報出
# （backlog #39）。它們只退回根本送不出去的值：不包括解析器不接受的名稱，那是一個答案，仍然是量測。
function Test-TcpTargetSyntax {
    param([string]$Value)
    $parts = ([string]$Value).Split(":")
    if ($parts.Count -ne 2) { return $false }
    if (-not (Test-HostNameSyntax $parts[0])) { return $false }
    $port = ConvertTo-IntSafe $parts[1] 0
    return (($port -ge 1) -and ($port -le 65535))
}

function Test-HttpTargetSyntax {
    param([string]$Value)

    # 這個值到底能不能成為 HTTP 目標——必須是絕對 URI，而且用的是本工具會講的 scheme。規則放在這裡，是因為有兩個
    # 地方要問它：設定驗證，以及那個不然就會把請求送出去的檢查。1.2.8 之前這兩邊講的不一樣（PR #41 第 1 輪）：驗證
    # 說「example.com」不可用，檢查卻只攔空白，於是請求真的送出去、失敗，然後被記成一次量到的連線失敗——必要目標
    # 因此可能顯示「發現問題」，必要群組的成員甚至會讓整個群組失敗，而那個值根本沒讓任何封包離開過。
    $uri = $null
    if (-not [System.Uri]::TryCreate([string]$Value, [System.UriKind]::Absolute, [ref]$uri)) { return $false }
    if (-not ($uri.Scheme -eq "http" -or $uri.Scheme -eq "https")) { return $false }
    # 網址裡面的主機名稱也是一個主機名稱：Uri.TryCreate 會接受 'http://foo..bar/'，而那個空標籤要等到
    # 請求已經送出去才會被發現，到時候看起來就像網站不回應（PR #41，第 9 輪）。Uri 會拿掉 IPv6 文字
    # 位址的方括號，也不會把使用者資訊留在 Host 裡，所以這裡檢查的就是名稱本身。
    return (Test-HostNameSyntax $uri.Host)
}

# 待辦 #54：主機名稱判定的規則寫在這一處，取代審查者一次一個找出來的字元清單（PR #41 第 5 到 21 輪）。設定的值能被
# 檢測，條件是「送到線上的名字就是設定的名字」：
#   - IPv6 字面值，可帶數字的 zone id（fe80::1%12 是 Windows 的形式，link-local 位址沒有它送不出去）——冒號、因而
#     百分號，只准出現在這裡；
#   - 否則就是標籤，以「.」或 IDNA 當成點的三個分隔符（U+3002、U+FF0E、U+FF61）分開，結尾的空標籤是根。每個標籤都
#     以解析器會送出的形式來判定。含有 ASCII 以外字元的標籤先經 IDNA 編碼（GetAscii，解析器自己的轉換）再解碼，
#     回來的必須就是設定的那個標籤——只容許 ASCII 大小寫與正規組合（NFC）的差異——所以 IDNA 會移除（零寬空白或連
#     接子、軟連字號）、改寫（全形字母、ß）或拒絕（雙向控制字元、未指派的碼位）的字元在這裡就被拒絕：送出去問的
#     名字會不是設定的名字，而報告裡沒有任何地方會說。編碼後的標籤只能有字母、數字、連字號和底線——底線是因為
#     Windows 主機名常帶著它，這是 LDH 明說的超集——空白、控制字元、URI 分隔符和其他所有 ASCII 符號就是被這一條
#     拒絕的；編碼後 1 到 63 個字元、不以連字號開頭或結尾；整個編碼後的名稱最多 253。
# 通過的值可以照設定的樣子問出去，解析器的回答——包括「沒有這個名字」——仍是量測（待辦 #39）。被拒絕的值從來
# 不可能照設定的樣子問出去，而理由會寫出決定它的第一個字元，好讓操作者修正設定。Test-HostNameSyntax 是這個函式的
# 是／否；理由進到該列的詳細內容。純 ASCII 的標籤不經 IDNA，原樣判定——已經編碼過的 xn-- 標籤也是。
function Get-HostNameSyntaxProblem {
    param([string]$Value)
    $name = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($name)) { return "值是空白的" }
    if ($name.Contains(":")) {
        $parsedAddress = $null
        if ([System.Net.IPAddress]::TryParse($name, [ref]$parsedAddress) -and $parsedAddress.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6) { return "" }
        return "冒號只能出現在 IPv6 位址裡，而這不是 IPv6 位址（zone id 必須是數字，例如 fe80::1%12）"
    }
    $labels = @($name.Split([char[]]@(".", [char]0x3002, [char]0xFF0E, [char]0xFF61)))
    if ($labels.Count -gt 1 -and $labels[$labels.Count - 1].Length -eq 0) { $labels = @($labels[0..($labels.Count - 2)]) }
    $idn = New-Object System.Globalization.IdnMapping
    $position = 1
    $encodedLength = 0
    foreach ($label in $labels) {
        if ($label.Length -eq 0) { return ("位置 {0} 有空的標籤：連續兩個分隔符，或開頭就是分隔符" -f $position) }
        $encoded = $label
        # 用 -cmatch 而不是 -match：不分大小寫的那個會把 U+212A（Kelvin 符號）折疊成 K、U+0130 折疊成 I，把兩者都當成
        # ASCII——邊界測試第一次跑就抓到了。
        if ($label -cmatch '[^\x00-\x7F]') {
            $normalized = $label
            $decoded = $null
            try {
                $normalized = $label.Normalize([System.Text.NormalizationForm]::FormC)
                $encoded = $idn.GetAscii($normalized)
                $decoded = $idn.GetUnicode($encoded)
            }
            catch {
                # 整個標籤被拒絕；決定它的字元一次一個找出來（代理對算一個），好讓理由寫得出它。一個都找不到就表示
                # 標籤編碼後太長。
                $i = 0
                while ($i -lt $normalized.Length) {
                    $unit = [string]$normalized[$i]
                    if ([char]::IsHighSurrogate($normalized[$i]) -and ($i + 1) -lt $normalized.Length -and [char]::IsLowSurrogate($normalized[$i + 1])) { $unit = $normalized.Substring($i, 2) }
                    $refused = $false
                    try { [void]$idn.GetAscii("a" + $unit + "b") } catch { $refused = $true }
                    if ($refused) { return ("位置 {1} 的 U+{0:X4} 無法編碼送上線：IDNA 拒絕它" -f [char]::ConvertToUtf32($unit, 0), ($position + $i)) }
                    $i += $unit.Length
                }
                return ("位置 {0} 的標籤無法編碼送上線：IDNA 拒絕它，或編碼後超過 63 個字元" -f $position)
            }
            if (-not [string]::Equals($decoded, $normalized, [System.StringComparison]::OrdinalIgnoreCase)) {
                $index = 0
                $limit = [math]::Min($decoded.Length, $normalized.Length)
                while ($index -lt $limit -and [char]::ToUpperInvariant($decoded[$index]) -eq [char]::ToUpperInvariant($normalized[$index])) { $index++ }
                if ($index -ge $normalized.Length) { $index = $normalized.Length - 1 }
                $code = [int]$normalized[$index]
                if ([char]::IsHighSurrogate($normalized[$index]) -and ($index + 1) -lt $normalized.Length) { $code = [char]::ConvertToUtf32($normalized, $index) }
                return ("位置 {1} 的 U+{0:X4} 會被 IDNA 移除或改寫，送出去問的名字就不會是設定的名字" -f $code, ($position + $index))
            }
        }
        $outside = [regex]::Match($encoded, '[^A-Za-z0-9_-]')
        if ($outside.Success) { return ("位置 {1} 的 U+{0:X4} 不是字母、數字、連字號或底線" -f [int]$encoded[$outside.Index], ($position + $outside.Index)) }
        if ($encoded.Length -gt 63) { return ("位置 {0} 的標籤超過 63 個字元" -f $position) }
        if ($encoded.StartsWith("-") -or $encoded.EndsWith("-")) { return ("位置 {0} 的標籤以連字號開頭或結尾" -f $position) }
        $encodedLength += $encoded.Length + 1
        $position += $label.Length + 1
    }
    if (($encodedLength - 1) -gt 253) { return "名稱編碼後超過 253 個字元" }
    return ""
}

# URL 的列或設定錯誤要帶的後綴：URL 本身是絕對的 http(s) 位址、問題出在主機名稱時，寫出主機的理由（待辦 #54）；
# URL 因 scheme 或形狀而失敗時什麼都不加，讓它保有自己的訊息。
function Get-UrlHostProblemSuffix {
    param([string]$Url)
    $uri = $null
    if (-not [System.Uri]::TryCreate([string]$Url, [System.UriKind]::Absolute, [ref]$uri)) { return "" }
    if (-not ($uri.Scheme -eq "http" -or $uri.Scheme -eq "https")) { return "" }
    $problem = [string](Get-HostNameSyntaxProblem $uri.Host)
    if ($problem.Length -eq 0) { return "" }
    return ("；主機：" + $problem)
}

function Test-HostNameSyntax {
    param([string]$Value)
    return (([string](Get-HostNameSyntaxProblem $Value)).Length -eq 0)
}

function Test-PingTargetSyntax {
    param([string]$Value)

    # 這個值到底能不能成為一個 ping 目標——這和「它會不會回應」是兩個問題（backlog #39）。空白的位址，或帶了通訊
    # 協定、路徑、使用者或連接埠的位址，根本組不成目標：什麼都沒送出去，也就沒學到任何關於網路的事，說明這件事的
    # 那一列是關於本次輸入的事實。格式正確但解析不到的名稱則相反——它被實際檢測過，解析器回答了，那個回答是量測，
    # 這條規則不能碰。兩個佔位符是由執行自己解析的目標。
    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $false }
    if ($text -eq "AUTO_GATEWAY" -or $text -eq "AUTO_DNS") { return $true }
    # 解析器根本無法接受的名稱，跟網址一樣屬於輸入問題：foo..bar 這種空標籤、超過 63 個字元的
    # 標籤、超過 253 個字元的完整名稱，或以連字號開頭或結尾的標籤。Ping.Send 會在封包產生之前就擲回例外，
    # 而包在外層的 catch 會把它記成一次遺失的回覆 - 因此這樣拼寫的必要目標會被報成量測到的 100% 遺失，
    # 而這正是這個函式要防止的混淆（PR #41，第 5 輪）。這裡只檢查結構，不限制字元：格式正確但無法解析的
    # 名稱屬於相反的情況 - 問過也得到答覆了 - 而國際化名稱也必須維持可用。
    return (Test-HostNameSyntax $text)
}

# v1.2：執行選項來自入口（啟動器參數）或 IT 選項面板；JSON 設定檔永遠不會被寫入。
function Set-RunOptions {
    param([hashtable]$Overrides)

    if ($null -eq $Overrides) {
        $Overrides = @{}
    }
    $script:RunOptionMessages = New-Object System.Collections.ArrayList
    $script:DroppedTargets = New-Object System.Collections.ArrayList
    $config = ($script:BaseConfig | ConvertTo-Json -Depth 10) | ConvertFrom-Json
    $extra = [ordered]@{ Ping = @(); Dns = @(); Tcp = @(); Http = @() }
    $raw = [ordered]@{ Ping = @(); Dns = @(); Tcp = @(); Http = @() }

    # 額外目標的列標題帶著它自己的值，於是同一種的兩個目標在表格裡、以及在點名沒有回應者的結語裡，都分得出來
    #（PR #35 第 2 輪）。Ping 那一列是例外，維持原本的名稱：Test-PingTargets 本來就把標題寫成「<名稱>：<目標>」，
    # 在這裡再加一次位址會印兩遍（第 3 輪）。
    foreach ($value in @(@($Overrides["PingTarget"]) | ForEach-Object { ([string]$_) -split '[,;\s]+' } | ForEach-Object { ([string]$_).Trim() })) {
        if ([string]::IsNullOrWhiteSpace([string]$value)) { continue }
        $raw.Ping += [string]$value
        $config.Tests.PingTargets = @($config.Tests.PingTargets) + [pscustomobject][ordered]@{ Name = "額外 Ping"; Address = [string]$value; Required = $false }
        $extra.Ping += [string]$value
    }
    foreach ($value in @(@($Overrides["DnsName"]) | ForEach-Object { ([string]$_) -split '[,;\s]+' } | ForEach-Object { ([string]$_).Trim() })) {
        if ([string]::IsNullOrWhiteSpace([string]$value)) { continue }
        $raw.Dns += [string]$value
        $config.Tests.DnsNames = @($config.Tests.DnsNames) + [pscustomobject][ordered]@{ Name = ("額外 DNS " + [string]$value); Host = [string]$value; Required = $false }
        $extra.Dns += [string]$value
    }
    foreach ($value in @(@($Overrides["TcpTarget"]) | ForEach-Object { ([string]$_) -split '[,;\s]+' } | ForEach-Object { ([string]$_).Trim() })) {
        if ([string]::IsNullOrWhiteSpace([string]$value)) { continue }
        $raw.Tcp += [string]$value
        $parts = ([string]$value).Split(':')
        $port = 0
        if ($parts.Count -eq 2) { $port = ConvertTo-IntSafe $parts[1] 0 }
        if (-not (Test-TcpTargetSyntax $value)) {
            # 提示說明發生了什麼事；這筆紀錄則是為了在「結果本該出現的地方」留下一列（backlog #39）。被丟棄的
            # 目標若只留下程式環境區的一則提示，讀者看到的是空的 TCP 區段，那讀起來像沒有人設定過這項檢查，而
            # 不是它被丟掉了。
            [void]$script:RunOptionMessages.Add("已忽略額外 TCP 目標「$value」：格式應為 host:port，且主機名稱必須可以使用。" + $(if ($parts.Count -eq 2 -and -not (Test-HostNameSyntax $parts[0])) { "主機：" + (Get-HostNameSyntaxProblem $parts[0]) + "。" } else { "" }))
            [void]$script:DroppedTargets.Add([pscustomobject][ordered]@{ Kind = "Tcp"; Value = [string]$value })
            continue
        }
        $config.Tests.TcpTargets = @($config.Tests.TcpTargets) + [pscustomobject][ordered]@{ Name = ("額外 TCP " + [string]$value); Host = $parts[0]; Port = $port; Required = $false; Group = "" }
        $extra.Tcp += [string]$value
    }
    foreach ($value in @(@($Overrides["HttpUrl"]) | ForEach-Object { ([string]$_) -split '\s+' } | ForEach-Object { ([string]$_).Trim() })) {
        if ([string]::IsNullOrWhiteSpace([string]$value)) { continue }
        $raw.Http += [string]$value
        $config.Tests.HttpTargets = @($config.Tests.HttpTargets) + [pscustomobject][ordered]@{ Name = ("額外 URL " + [string]$value); Url = [string]$value; Required = $false; Group = "" }
        $extra.Http += [string]$value
    }

    if ((ConvertTo-IntSafe $Overrides["SampleSeconds"] 0) -gt 0) { $config.Tests.RetransmissionSampleSeconds = ConvertTo-IntSafe $Overrides["SampleSeconds"] 0 }
    if ((ConvertTo-IntSafe $Overrides["PingCount"] 0) -gt 0) { $config.Tests.PingCount = ConvertTo-IntSafe $Overrides["PingCount"] 0 }
    if ((ConvertTo-IntSafe $Overrides["PingCountMaximum"] 0) -gt 0) { $config.Tests.PingCountMaximum = ConvertTo-IntSafe $Overrides["PingCountMaximum"] 0 }
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
        # 上限永遠不會低於起始次數（backlog #51）：PingCount 是每個 ping 目標一開始送出的次數，
        # PingCountMaximum 則是回覆有遺失時這次執行最多會加到多少。兩者順序寫反不會把起始次數砍掉——
        # 設定檢查會提出警告，而這裡取兩者的較大值，所以使用者要求送出的次數一定會送出。
        PingCountMaximum = [math]::Max([math]::Max(1, (ConvertTo-IntSafe $config.Tests.PingCount 4)), (ConvertTo-IntSafe $config.Tests.PingCountMaximum 21))
        SampleSeconds  = [math]::Max(1, (ConvertTo-IntSafe $config.Tests.RetransmissionSampleSeconds 8))
        IntervalSeconds = Get-TcpIntervalSeconds
        TracerouteHops = $hops
        ChecksEnabled  = [pscustomobject][ordered]@{
            WifiRf          = Test-IsTrueFlag $config.Checks.WifiRf
            RouteTable      = Test-IsTrueFlag $config.Checks.RouteTable
            GatewayNeighbor = Test-IsTrueFlag $config.Checks.GatewayNeighbor
            ProxySettings   = Test-IsTrueFlag $config.Checks.ProxySettings
            Traceroute      = Test-IsTrueFlag $config.Checks.Traceroute
            DriverInfo      = Test-IsTrueFlag $config.Checks.DriverInfo
            WifiRetryCounters = Test-IsTrueFlag $config.Checks.WifiRetryCounters
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
    $parts += ("Ping 上限 {0}" -f $options.PingCountMaximum)
    $parts += ("取樣 {0} 秒" -f $options.SampleSeconds)
    # backlog #65：只在窗內讀取開著時才寫，因為 0 是一個值，而執行設定檔寫的是有跑的東西。
    $intervalSeconds = ConvertTo-IntSafe (Get-PropertyValue $options "IntervalSeconds" 0) 0
    if ($intervalSeconds -gt 0) { $parts += ("窗內每 {0} 秒再讀一次" -f $intervalSeconds) }
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

function Get-DhcpServerTable {
    # backlog #32：是哪一台伺服器回應了租約。NetTCPIP 指令帶的是 DHCP 模式而不是伺服器，所以唯一的來源是
    # Win32_NetworkAdapterConfiguration.DHCPServer——CIM 備援路徑讀所有東西用的同一個類別。對每一個啟用 IP 的設定
    # 查一次、以介面索引為鍵，讓偏好路徑只多付一次 CIM 呼叫，而不是每張網卡一次。$null 代表整個類別讀不到，網卡
    # 那一列會把它報成「資料無法取得」而不是「這張網卡沒有租約」（已結案項目 #5 的形狀：未知絕不報成一個值）。
    # 這個查詢不會嘗試第二次——它不是效能計數器的讀取，1.2.8 記錄了網卡設定查詢為什麼維持單次嘗試。
    $table = @{}
    try {
        $configs = @(Get-CimOrWmiInstance -ClassName "Win32_NetworkAdapterConfiguration" | Where-Object { $null -ne $_ -and $_.IPEnabled })
    }
    catch {
        return $null
    }
    foreach ($config in $configs) {
        $table[(ConvertTo-IntSafe $config.InterfaceIndex -1)] = (ConvertTo-SafeString (Get-PropertyValue $config "DHCPServer" "")).Trim()
    }
    return $table
}

function Get-NetworkSnapshotFromNetCmdlets {
    $items = New-Object System.Collections.ArrayList
    $configs = @(Get-NetIPConfiguration -ErrorAction Stop)
    $dhcpServers = Get-DhcpServerTable

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
            # 類別讀不到時是 $null；否則是伺服器位址，或設定裡沒有伺服器時的 ""（固定位址，或從來沒拿到的租約）。
            DhcpServer      = $(if ($null -eq $dhcpServers) { $null } elseif ($dhcpServers.ContainsKey((ConvertTo-IntSafe -Value $config.InterfaceIndex -DefaultValue 0))) { [string]$dhcpServers[(ConvertTo-IntSafe -Value $config.InterfaceIndex -DefaultValue 0)] } else { "" })
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
            DhcpServer      = (ConvertTo-SafeString (Get-PropertyValue $config "DHCPServer" "")).Trim()
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
    # 四個清單，因為判定無法只附著在一列的一半上（backlog #39）。組織自己的標準與門檻值，是其他每一列被拿來比對的
    # 基準：其中一項壞掉，判定就不可信，因此保有權重。無法檢測的目標項目、不是布林值的檢查旗標、超出範圍的 hop 數，
    # 則是關於本次執行輸入的事實，不會動搖任何已量到的東西——而且那些目標項目現在會由「本來要做那個量測的檢查」在它
    # 所屬的區段報告，所以這一列不再對同一個打錯的值定罪第二次。
    $errors = New-Object System.Collections.ArrayList
    $warnings = New-Object System.Collections.ArrayList
    $inputErrors = New-Object System.Collections.ArrayList
    $inputWarnings = New-Object System.Collections.ArrayList
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
        $hostName = (ConvertTo-SafeString (Get-PropertyValue $target "Host" "")).Trim()
        $port = ConvertTo-IntSafe (Get-PropertyValue $target "Port" 0) 0
        if (-not (Test-HostNameSyntax $hostName) -or $port -lt 1 -or $port -gt 65535) {
            [void]$inputErrors.Add("TcpTargets 的「$name」主機或連接埠無效：Host=$hostName, Port=$port" + $(if (-not (Test-HostNameSyntax $hostName)) { "；主機：" + (Get-HostNameSyntaxProblem $hostName) } else { "" }))
        }
    }

    foreach ($target in @($tests.HttpTargets)) {
        if ($null -eq $target) { continue }
        $name = ConvertTo-SafeString (Get-PropertyValue $target "Name" "HTTP target")
        $url = ConvertTo-SafeString (Get-PropertyValue $target "Url" "")
        if (-not (Test-HttpTargetSyntax $url)) {
            [void]$inputErrors.Add("HttpTargets 的「$name」URL 無效：$url" + (Get-UrlHostProblemSuffix $url))
        }
    }

    foreach ($target in @($tests.PingTargets)) {
        if ($null -eq $target) { continue }
        $name = ConvertTo-SafeString (Get-PropertyValue $target "Name" "Ping 目標")
        $address = (ConvertTo-SafeString (Get-PropertyValue $target "Address" "")).Trim()
        if (-not (Test-PingTargetSyntax $address)) {
            [void]$inputErrors.Add("PingTargets「$name」的位址無法當成 ping 目標：$address；" + (Get-HostNameSyntaxProblem $address))
        }
    }

    # 近端目標（backlog #60）的規則比其他 ping 目標窄：必須是 IPv4 位址，因為執行時必須在送出任何東西之前就知道它
    # 在本地子網段上，名稱會讓這一階落在解析器之後。佔位符同樣不合這條規則——閘道不能當近端這一階，而 AUTO_DNS
    # 可能解析成閘道、或閘道之外的伺服器。它在哪個子網段上是關於這台機器的事實，所以在送出探測的地方判斷，不在
    # 這裡。
    $nearEnd = Get-PropertyValue $tests "NearEndTarget" $null
    if ($null -ne $nearEnd) {
        $nearEndAddress = (ConvertTo-SafeString (Get-PropertyValue $nearEnd "Address" "")).Trim()
        if (-not [string]::IsNullOrWhiteSpace($nearEndAddress) -and -not (Test-NearEndAddressSyntax $nearEndAddress)) {
            [void]$inputErrors.Add("NearEndTarget 的位址無法當成近端目標——它必須是點分十進位形式、位於這台電腦自己子網段上、而且不是閘道的 IPv4 位址：$nearEndAddress")
        }
        elseif ([string]::IsNullOrWhiteSpace($nearEndAddress) -and [bool](Get-PropertyValue $nearEnd "Required" $false)) {
            # 空白且選用是出廠的、停用的狀態；空白卻必要，是一項沒有東西可查的必要檢查，執行時會報成沒有執行的必要檢查
            # （PR #51 第 3 輪）。
            [void]$inputErrors.Add("NearEndTarget 標記為必要卻沒有位址：給它這台電腦自己子網段上一台主機的位址，或把 Required 設為 false")
        }
    }

    foreach ($dnsTarget in @($tests.DnsNames)) {
        if ($null -eq $dnsTarget) { continue }
        if ($dnsTarget -is [string]) {
            $hostName = ([string]$dnsTarget).Trim()
        }
        else {
            $hostName = (ConvertTo-SafeString (Get-PropertyValue $dnsTarget "Host" "")).Trim()
        }
        if ([string]::IsNullOrWhiteSpace($hostName)) {
            [void]$inputErrors.Add("DnsNames 含有空白的 Host。")
        }
        elseif (-not (Test-HostNameSyntax $hostName)) {
            [void]$inputErrors.Add("DnsNames 含有無法當成 DNS 目標的主機名稱：$hostName；" + (Get-HostNameSyntaxProblem $hostName))
        }
    }

    foreach ($setting in @(
        [pscustomobject]@{ Name = "PingCount"; Value = $tests.PingCount },
        [pscustomobject]@{ Name = "PingCountMaximum"; Value = $tests.PingCountMaximum },
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

    # backlog #65：取樣窗內讀取的間隔，0 是一個值（關閉），不是錯誤。
    $intervalValue = Get-PropertyValue $tests "RetransmissionIntervalSeconds" $null
    if ($null -ne $intervalValue -and -not (Test-IsWholeNumber $intervalValue)) {
        [void]$warnings.Add(("RetransmissionIntervalSeconds 必須是整數秒數——0 代表關閉取樣窗內的讀取（目前值：{0}），將改用內建預設值。" -f $intervalValue))
    }
    elseif ($null -ne $intervalValue -and (ConvertTo-IntSafe $intervalValue 0) -lt 0) {
        [void]$warnings.Add(("RetransmissionIntervalSeconds 必須是 0 以上（目前值：{0}），將改用內建預設值。" -f $intervalValue))
    }

    $checks = $script:Config.Checks
    foreach ($flagName in @("WifiRf", "RouteTable", "GatewayNeighbor", "ProxySettings", "Traceroute", "DriverInfo", "WifiRetryCounters")) {
        $flagValue = Get-PropertyValue $checks $flagName
        if ($null -ne $flagValue -and -not ($flagValue -is [bool])) {
            [void]$inputWarnings.Add("Checks.$flagName 必須是 true 或 false（目前值：$flagValue），該檢查已停用。")
        }
    }
    $hopsValue = Get-PropertyValue $checks "TracerouteHops"
    if ($null -ne $hopsValue -and (-not (Test-IsWholeNumber $hopsValue) -or (ConvertTo-IntSafe $hopsValue 0) -lt 1 -or (ConvertTo-IntSafe $hopsValue 0) -gt 10)) {
        [void]$inputWarnings.Add("Checks.TracerouteHops 必須是 1 到 10 的整數（目前值：$hopsValue），將改用內建預設值。")
    }

    $countThresholdNames = @("TcpRetransmissionCriticalCount", "MinimumTcpSegmentsForRate", "MinimumTcpRetransmissionsForVerdict", "AdapterErrorWarningDelta", "AdapterErrorCriticalDelta", "AdapterDiscardWarningDelta", "AdapterDiscardCriticalDelta")
    foreach ($thresholdName in @("PacketLossWarningPercent", "PacketLossCriticalPercent", "LatencyWarningMs", "LatencyCriticalMs", "TcpRetransmissionWarningPercent", "TcpRetransmissionCriticalPercent", "TcpRetransmissionCriticalCount", "MinimumTcpSegmentsForRate", "MinimumTcpRetransmissionsForVerdict", "AdapterErrorWarningDelta", "AdapterErrorCriticalDelta", "AdapterDiscardWarningDelta", "AdapterDiscardCriticalDelta")) {
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
        elseif (($countThresholdNames -contains $thresholdName) -and (ConvertTo-DoubleSafe $thresholdValue 0) -lt 0) {
            # 計數類門檻是一個次數，負的次數什麼也數不到 —— 而在這之前它會在轉型成無號數的地方把整個分析弄掉
            # （PR #49 第 1 輪）。現在它跟其他用不了的值一樣：退回內建預設值，並且在這裡被點名。
            [void]$warnings.Add("$thresholdName 不能是負數（目前值：$thresholdValue），將改用內建預設值。")
        }
    }

    # 兩個 ping 次數也是一對有順序的設定值，跟門檻一樣（backlog #51）。上限低於起始次數並不會讓執行失敗——
    # 起始次數就是上限——但那是設定檔說了一件它做不到的事，所以這裡照門檻的成對檢查方式講出來。
    $startCount = ConvertTo-IntSafe $tests.PingCount 4
    $ceilingCount = ConvertTo-IntSafe $tests.PingCountMaximum 21
    if ($ceilingCount -lt $startCount) {
        [void]$warnings.Add("Ping 次數順序不合理：PingCount=$startCount, PingCountMaximum=$ceilingCount；將以起始次數作為上限。")
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
    elseif ($warnings.Count -eq 0 -and $inputErrors.Count -eq 0 -and $inputWarnings.Count -eq 0) {
        Add-CheckResult -Category "程式設定" -Check "設定值驗證" -Status "PASS" -Message "設定值格式檢查通過。" -Details "" -Tag "config" | Out-Null
    }

    if ($warnings.Count -gt 0) {
        Add-CheckResult -Category "程式設定" -Check "設定值門檻" -Status "WARN" -Message ("設定檔有 {0} 個需要注意的門檻值。" -f $warnings.Count) -Details (@($warnings) -join [Environment]::NewLine) -Tag "config" | Out-Null
    }

    if ($inputErrors.Count -gt 0) {
        Add-CheckResult -Category "程式設定" -Check "設定的目標" -Status "ERROR" -Message ("這次執行拿到的目標裡有 {0} 個無法檢測；每一個都會在它自己結果本該出現的地方被報告，而且都不改變整體結果。" -f $inputErrors.Count) -Details (@($inputErrors) -join [Environment]::NewLine) -Tag "config" -Weightless | Out-Null
    }

    if ($inputWarnings.Count -gt 0) {
        Add-CheckResult -Category "程式設定" -Check "設定的檢查項目" -Status "WARN" -Message ("有 {0} 個選項值無法依原樣使用；已改用內建預設值或停用該項檢查，整體結果不因它改變。" -f $inputWarnings.Count) -Details (@($inputWarnings) -join [Environment]::NewLine) -Tag "config" -Weightless | Out-Null
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

function Get-DhcpServerText {
    param([object]$DhcpEnabled, [object]$DhcpServer)

    # 四種形狀，而且順序有關係（backlog #32）。固定位址沒有租約，所以不論設定裡放著什麼都不點名伺服器。再來是資料
    # 無法取得——類別讀不到——照實說。再來是回應租約的那個位址。最後是設定裡沒有伺服器位址、卻也沒有東西說位址是
    # 固定的：從來沒拿到租約的 DHCP，或這次執行讀不到的模式。
    if ($DhcpEnabled -eq $false) { return "無（固定位址，沒有租約）" }
    if ($null -eq $DhcpServer) { return "無法取得（此欄位讀自 Win32_NetworkAdapterConfiguration，而它無法查詢；NetTCPIP 指令沒有這個欄位）" }
    if (-not [string]::IsNullOrWhiteSpace([string]$DhcpServer)) { return [string]$DhcpServer }
    return "無記錄（這張網卡沒有記錄任何伺服器位址）"
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
        # backlog #32：回應租約的那台伺服器，就寫在它所修飾的模式旁邊——SOP 的「誰在發 DHCP」這個問題由這一行回答。
        # 固定位址沒有租約可以點名；類別讀不到時要說「無法取得」而不是留白，因為空白會被讀成「沒有伺服器」，那是一個
        # 主張。
        $dhcpServerText = Get-DhcpServerText -DhcpEnabled $adapter.DhcpEnabled -DhcpServer (Get-PropertyValue $adapter "DhcpServer" $null)

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
            "DHCP 伺服器：$dhcpServerText",
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
function Get-RouteSelection {
    param([string]$Target)

    # backlog #59：ping 是從哪一張網路卡送出的。Find-NetRoute 回答的是「查詢當下」路由表會選哪一條，而
    # Invoke-PingMeasurement 送出的探測並沒有綁定來源 —— 所以這裡回傳的是「被選出的路由」，永遠不是回應實際
    # 走過的路徑。Test-PingTargets 在每個目標的探測前後各查一次，讓檢測途中改變的路由被「報告」出來而不是被
    # 猜測；這與網路卡計數器採用的前後取樣是同一個形狀。在參考機上量到的回傳是兩個物件：本機位址（帶來源與介面）
    # 與路由（帶 next hop）。來源取自「有 IPAddress 的那一個」而不是第一個，因為順序是該 Cmdlet 決定的，不是這個
    # 工具可以依賴的。成本量測：CIM 暖機後約 13 ms，而執行到 ping 檢查時，網路卡檢查早已付過暖機成本。
    # Cmdlet 不存在或查詢失敗一律是「這個資料無法取得」，絕不是讓這一列失敗 —— 這是已結案項目 #5 的形狀。
    if (-not (Get-Command Find-NetRoute -ErrorAction SilentlyContinue)) {
        return [pscustomobject][ordered]@{ Resolved = $false; Reason = "cmdlet"; SourceAddress = ""; InterfaceAlias = ""; NextHop = ""; OnLink = $false }
    }

    # An empty result is not one outcome, and round 1 of PR #45 was right that calling it 'no route' publishes a
    # false sentence. The cmdlet reports both by a non-terminating error, so -ErrorVariable carries the answer and
    # the id is the discriminator, not the message - the same rule backlog #27 settled for CIM errors, and for the
    # same reason: the message follows the machine's locale while the id does not. Measured on the reference machine
    # on 2026-09-11: an unroutable address gives Windows System Error 1231 (the network location cannot be reached)
    # and a name gives 87 (invalid parameter), because RemoteIPAddress is documented as an address. Anything else is
    # a failure of the lookup itself and says so rather than borrowing either meaning.
    $found = @()
    $lookupErrors = $null
    try {
        $found = @(Find-NetRoute -RemoteIPAddress ([string]$Target) -ErrorAction SilentlyContinue -ErrorVariable lookupErrors)
    }
    catch {
        return [pscustomobject][ordered]@{ Resolved = $false; Reason = "error"; SourceAddress = ""; InterfaceAlias = ""; NextHop = ""; OnLink = $false }
    }

    $localAddress = @($found | Where-Object { -not [string]::IsNullOrWhiteSpace((ConvertTo-SafeString $_.IPAddress)) } | Select-Object -First 1)
    if ($localAddress.Count -eq 0) {
        $reason = "error"
        $firstError = @($lookupErrors) | Select-Object -First 1
        $errorId = ""
        if ($null -ne $firstError) { $errorId = ConvertTo-SafeString $firstError.FullyQualifiedErrorId }
        if ($errorId -match 'Error 1231') { $reason = "noroute" }
        elseif ($errorId -match 'Error 87') { $reason = "notaddress" }
        elseif ([string]::IsNullOrWhiteSpace($errorId)) { $reason = "noroute" }
        return [pscustomobject][ordered]@{ Resolved = $false; Reason = $reason; SourceAddress = ""; InterfaceAlias = ""; NextHop = ""; OnLink = $false }
    }

    # 路由物件帶著下一跳（PR #51 第 5 輪）：0.0.0.0——或 ::——是直連路由，也就是網卡接著的那個網路；其他的下一跳都是路由器，
    # 而經過路由器的探測不論目標多近，都沒有量到本地路徑。一條經預設閘道往子網段內某台主機的 /32 路由，來源與網卡都不變，
    # 這就是為什麼光靠來源證明不了一階。
    $route = @($found | Where-Object { $null -ne $_.PSObject.Properties["NextHop"] } | Select-Object -First 1)
    $nextHop = ""
    if ($route.Count -gt 0) { $nextHop = ConvertTo-SafeString $route[0].NextHop }
    return [pscustomobject][ordered]@{
        Resolved       = $true
        Reason         = ""
        SourceAddress  = ConvertTo-SafeString $localAddress[0].IPAddress
        InterfaceAlias = ConvertTo-SafeString $localAddress[0].InterfaceAlias
        NextHop        = $nextHop
        OnLink         = ($nextHop -eq "0.0.0.0" -or $nextHop -eq "::")
    }
}

function Get-RouteSelectionText {
    param([object]$Selection, [switch]$NoHop)

    # 這一對查詢的其中一側，照這一列會說出來的樣子。每一種「無法取得」都自己說明原因，因為沒有原因的「無法取得」
    # 只會讓讀的人去猜。
    if ($null -eq $Selection) { return "無法取得（沒有讀取路由選擇）" }
    if ($Selection.Resolved) {
        $text = ("來源 {0}，經由 {1}" -f $Selection.SourceAddress, $Selection.InterfaceAlias)
        # 下一跳是路由選擇裡決定能不能主張一階的那一部分（PR #51 第 6 輪）：直連就是連接的網路，其他都是探測經過的路由器。
        # 所以讀法把它寫出來，而兩次查詢之間下一跳變了就讀成改變——階梯句的拒絕就是建立在這上面。
        # -NoHop 是只問「哪一張網卡」的比較；沒有下一跳的形狀照舊讀。
        $nextHop = ConvertTo-SafeString $Selection.NextHop
        if (-not $NoHop -and -not [string]::IsNullOrWhiteSpace($nextHop)) {
            if ($Selection.OnLink -eq $true) { $text += "，直連" } else { $text += ("，下一跳 {0}" -f $nextHop) }
        }
        return $text
    }
    switch ([string]$Selection.Reason) {
        "cmdlet"     { return "無法取得（這個系統沒有 Find-NetRoute）" }
        "noroute"    { return "無法取得（路由表對這個目標沒有回傳路由）" }
        "notaddress" { return "無法取得（路由表是用位址問的，而這個目標沒有可用的位址）" }
        "noreply"    { return "無法取得（這個目標是名稱，而且沒有任何回應，所以沒有可以查的位址）" }
        "error"      { return "無法取得（路由查詢失敗）" }
    }
    return "無法取得（沒有讀取路由選擇）"
}

function Get-RouteMethodText {
    param([string]$Target, [string]$LookupAddress, [bool]$TargetIsAddress, [int]$ExtraCount = 0)

    # 這一行必須描述「實際做了的查詢」，而不是位址目標那一種的查詢（PR #45 第 2 輪）。
    # 名稱目標是在探測之後、用回應所來的位址只查一次；沒人回應的名稱則根本沒有查。
    # 寫成函式而不是內嵌字串，是為了讓 unit 步驟能把它釘住。
    if ($TargetIsAddress) {
        return ("；路由選擇來自 Find-NetRoute -RemoteIPAddress {0}，在探測前後各讀一次" -f $Target)
    }
    if ([string]::IsNullOrWhiteSpace($LookupAddress)) {
        return "；沒有做路由查詢，因為這個目標是名稱，而且沒有任何回應可以提供位址"
    }
    if ($ExtraCount -gt 0) {
        return ("；路由選擇來自 Find-NetRoute -RemoteIPAddress，在探測之後對回應所來的 {0} 個位址各讀一次" -f ($ExtraCount + 1))
    }
    return ("；路由選擇來自 Find-NetRoute -RemoteIPAddress {0}，也就是回應所來的位址，在探測之後讀一次" -f $LookupAddress)
}

function Format-RouteSelection {
    param([object]$Before, [object]$After, [string]$LookupAddress = "", [object[]]$Others = @())

    # 兩次查詢會產生三種句子。兩次都查到而且相同，是一般情況的那一句。兩者只要不一致就報告為「改變」——
    # 包含一次查到、另一次沒查到，因為那同樣是對「當時是哪一張網路卡」的不一致，也正是這一列存在的理由。
    # 兩次都失敗而且原因相同時，原因只說一次。
    $beforeText = Get-RouteSelectionText $Before
    $afterText = Get-RouteSelectionText $After
    $afterKey = Get-RouteSelectionText $After -NoHop

    # 以名稱給定的目標，在有回應之前沒有任何位址可以拿去問路由表，所以根本組不成一對，
    # 這一列就直接說出來而不是暗示有一對（PR #45 第 1 輪）。工具不自己去解析名稱：那會讓 ping
    # 檢查變成依賴解析器，而正在被診斷的機器往往就是解析器壞掉的那一台。
    if ($null -eq $Before) {
        # 整組位址在任何 return 之前就先組好。第 4 輪抓到舊寫法在第一個位址查不到時直接 return，
        # 從來不讀其餘的 —— 把一張其實可用的網路卡藏在一次失敗的查詢後面，也讓 Method 行的「每一個都讀了」變成假的。
        # 第一個有沒有查到，只決定措辭，不決定要不要看其餘的。
        $agree = $true
        $primaryResolved = ($null -ne $After -and $After.Resolved)
        $allResolved = $primaryResolved
        $sameInterface = $true
        $eachText = @(("{0}：{1}" -f $LookupAddress, $afterText))
        foreach ($other in @($Others)) {
            $otherText = Get-RouteSelectionText $other.Selection
            $eachText += ("{0}：{1}" -f $other.Address, $otherText)
            if ((Get-RouteSelectionText $other.Selection -NoHop) -ne $afterKey) { $agree = $false }
            if ($null -eq $other.Selection -or -not $other.Selection.Resolved) { $allResolved = $false }
            elseif ($primaryResolved -and $other.Selection.InterfaceAlias -ne $After.InterfaceAlias) { $sameInterface = $false }
        }
        $addressCount = @($Others).Count + 1

        # 查不到不等於「路由表做了不同的判斷」（PR #45 第 5 輪）。只有每一個位址都得到答案時，
        # 它們之間的差異才能被稱為路由上的差異；若有一個沒有，那麼不同的是「查詢結果」，
        # 而一次可能只是暫時性的提供者失敗，不可以被當成關於網路的結論發布。
        #
        # 而這一列要回答的問題是「哪一張網路卡」，所以比對的就是網路卡（第 6 輪）。兩個位址可以走同一個
        # 介面而來源位址不同 —— IPv4 與 IPv6 各回一次就是最常見的情形 —— 把那稱為「無法確定網路卡」，
        # 是從一個根本不是差異的差異裡發明出模糊性。
        if (-not $agree) {
            if (-not $allResolved) {
                return ("路由選擇：這個目標是名稱，而它的回應來自 {0} 個位址，這些查詢並非每一個都有答案，也並非給出相同的答案 —— {1}。這一列無法把這次量測歸給單一一張網路卡；而這裡不同的是查詢結果，不是路由表做的判斷。" -f $addressCount, ($eachText -join "；"))
            }
            if ($sameInterface) {
                return ("路由選擇：這個目標是名稱，而它的回應來自 {0} 個位址，路由表把它們都送往同一個介面 {1}，只是來源位址不同 —— {2}。網路卡沒有疑問；會選出哪個來源，取決於要抵達的是其中哪一個位址。" -f $addressCount, $After.InterfaceAlias, ($eachText -join "；"))
            }
            return ("路由選擇：這個目標是名稱，而它的回應來自 {0} 個位址，路由表並沒有把它們送往同一個介面 —— {1}。這一列無法把這次量測歸給單一一張網路卡。" -f $addressCount, ($eachText -join "；"))
        }
        if ($primaryResolved) {
            $sentence = ("路由選擇：{0}，是在探測之後針對 {1} 查的 —— 這個目標是名稱，探測之前沒有位址可以問，因此沒有取得前後兩次的對照。探測本身沒有綁定它。" -f $afterText, $LookupAddress)
            if ($addressCount -gt 1) {
                $sentence += ("它的回應來自 {0} 個位址，而路由表對每一個都選出相同的來源與介面。" -f $addressCount)
            }
            return $sentence
        }
        if ($addressCount -gt 1) {
            return ("路由選擇：{0}，而且它回應所來的 {1} 個位址每一個都是如此。這一列無法說出這些探測是從哪一張網路卡送出的。" -f $afterText, $addressCount)
        }
        return ("路由選擇：{0}。這一列無法說出這些探測是從哪一張網路卡送出的。" -f $afterText)
    }

    if ($null -ne $Before -and $null -ne $After -and $Before.Resolved -and $After.Resolved -and
        $Before.SourceAddress -eq $After.SourceAddress -and $Before.InterfaceAlias -eq $After.InterfaceAlias -and
        [string]$Before.NextHop -eq [string]$After.NextHop) {
        return ("路由選擇：{0} —— 這是路由表為這個目標選出的路由，在探測前後各查一次。探測本身沒有綁定它，所以這是「被選出的路由」，不是回應實際走過的路徑。" -f $beforeText)
    }

    if ($beforeText -eq $afterText) {
        return ("路由選擇：{0}。這一列無法說出這些探測是從哪一張網路卡送出的。" -f $beforeText)
    }

    return ("路由選擇在這次檢測中改變了：探測前是 {0}，探測後是 {1}。探測沒有綁定其中任何一個，所以這一列無法說出實際是哪一個承載了它們。" -f $beforeText, $afterText)
}

# -----------------------------------------------------------------------------
# 自適應 ping 取樣，以及一個遺失數字可以決定什麼（backlog #51）。
# -----------------------------------------------------------------------------
function Get-PingCountForThreshold {
    param([double]$WarningPercent)

    # 「單一次遺失仍低於封包遺失警告門檻」所需的最小 echo 次數。n 次裡遺失一次是 100/n 個百分點，所以第一個候選
    # 值是滿足 100/n < w 的最小 n，也就是 floor(100/w) + 1。那是精確算術，而決定一列結果的並不是精確算術：級別
    # 是用這一列**印出來**的數字判的，四捨五入到小數第一位，最多可能比精確值高 0.05。在警告門檻 4.8 % 下，21 次
    # 裡遺失一次是 4.7619 %，印出來是 4.8，仍然會警告 —— 於是候選值會剛好把取樣停在「一個封包仍然決定得了」的
    # 地方，那正是本項目自己的缺陷再往裡一層（PR #49 第 1 輪）。因此候選值會一直往上加，直到印出來的數字真的低於
    # 門檻為止；而且這個問題是丟給 Get-LossBand 回答的，讓這裡測的規則永遠不會跟那一列將要用的規則分岔。傳進去
    # 的嚴重門檻就用警告門檻，因為這裡唯一要問的是「印出來的數字有沒有低於警告門檻」，高於它之後落在哪一級並不
    # 影響這個答案。
    # 這個搜尋會結束而且有界：印出來的數字在兩千次時就變成 0.0，而 0.0 低於任何正的門檻，所以任何正門檻都不會
    # 需要比那再多一步以上。
    # 門檻是 0 或更小時，沒有任何次數躲得過它，因為任何遺失都會達到門檻。這種 n 並不存在，所以回 0 告訴呼叫者，
    # 而不是回一個其實沒用的數字。
    if ($WarningPercent -le 0) { return 0 }
    $start = [math]::Floor(100.0 / $WarningPercent) + 1
    if ($start -gt 2000) { $start = 2000 }
    if ($start -lt 1) { $start = 1 }
    for ($count = [int]$start; $count -le 2001; $count++) {
        if ((Get-LossBand -Sent $count -Lost 1 -WarningPercent $WarningPercent -CriticalPercent $WarningPercent) -eq "pass") { return $count }
    }
    return 0
}

function Get-LossBand {
    param(
        [int]$Sent,
        [int]$Lost,
        [double]$WarningPercent,
        [double]$CriticalPercent
    )

    # 一個遺失數字落在哪一級，用的是這一列實際印出來的數字——四捨五入到小數第一位——所以列上的數字跟判定
    # 永遠不會對同一個數字有兩種說法。
    if ($Sent -le 0) { return "pass" }
    $percent = [math]::Round(([math]::Max(0, $Lost) * 100.0 / $Sent), 1)
    if ($percent -ge $CriticalPercent) { return "critical" }
    if ($percent -ge $WarningPercent) { return "warning" }
    return "pass"
}

function Get-PingLossClassification {
    param(
        [int]$Sent,
        [int]$Lost,
        [double]$WarningPercent,
        [double]$CriticalPercent
    )

    # 這個取樣數撐不撐得起它達到的那一級。要問兩件事，兩件都成立才會收回判定：
    #   Coarse    - 取樣數小於「單一次遺失不再達到警告門檻」所需的次數，也就是在這裡一個封包就值一整級。
    #               出貨設定就是這個樣子：4 次對 5 % 的門檻，一次遺失是 25 %，連嚴重門檻都越過了，工具根本
    #               沒有辦法在這個次數下表達「有一點點遺失」。
    #   OnePacket - 少遺失一次，級別就會不一樣。也就是說這個判定「就是」那一個封包。
    # 只成立一件是很平常的事，只憑其中一件寫成的規則都會是錯的。4 次遺失 3 次是 75 %，取樣雖粗，但少一次還有
    # 50 %，沒有任何東西是靠那一個封包撐著的，所以這一列保有判定；21 次遺失 2 次確實會因一個封包而改變級別，
    # 但 21 次是這個門檻撐得住的取樣數，9.5 % 是一次量測。只有兩件同時成立，才是本項目真正量到的那個情況。
    # 全部都沒有回覆的情況，從 PR #49 第 5 輪起也會走到這裡：它以前在遺失門檻之前就被回答掉了，理由是
    # 「100 % 遺失就是結論」—— 那是一個關於四次探測的論證，卻被套用在一次上。一次探測時，下面兩個條件都成立，
    # 判定會被收回；四次時第二個不成立（四次掉三次仍然是嚴重），判定照樣算數。兩種情況都不會多送，因為再多的
    # 次數也不會讓 100 % 遺失比現在更確定。
    $band = Get-LossBand -Sent $Sent -Lost $Lost -WarningPercent $WarningPercent -CriticalPercent $CriticalPercent
    $required = Get-PingCountForThreshold -WarningPercent $WarningPercent
    $coarse = ($Sent -gt 0) -and (($required -le 0) -or ($Sent -lt $required))
    $onePacket = $false
    if ($Lost -ge 1) {
        $onePacket = ($band -ne (Get-LossBand -Sent $Sent -Lost ($Lost - 1) -WarningPercent $WarningPercent -CriticalPercent $CriticalPercent))
    }
    return [pscustomobject][ordered]@{
        Band          = $band
        Coarse        = $coarse
        OnePacket     = $onePacket
        RequiredCount = $required
        Weightless    = (($band -ne "pass") -and $coarse -and $onePacket)
    }
}

function Get-PingExtensionPlan {
    param(
        [int]$Sent,
        [int]$Received,
        [int]$MaximumCount,
        [double]$WarningPercent
    )

    # 這個目標要不要繼續取樣、要加到哪裡。設定的次數是一個目標「開始」的次數，不是它停下來的次數；第一輪量到
    # 什麼，決定這是三種情況裡的哪一種：
    #   全部都有回覆 - 沒有什麼模稜兩可的事要釐清，而且健康的一次執行絕不能變得比以前慢；
    #   完全沒有回覆 - 4 次就足以斷定 100 % 遺失，再多次也不會更確定，而這正是每多一次都要付一整個逾時的情況；
    #   有回覆但有遺失 - 這才是模稜兩可的那一種，會加到「一個封包再也決定不了分類」的次數；若設定的上限更低，
    #                    就加到上限為止。
    # 上限低於門檻所需的次數不是錯誤，這裡也不會蓋過它：取樣就是維持粗糙，而擋住判定的是
    # Get-PingLossClassification。
    $required = 0
    $reason = "nothing-sent"
    $target = $Sent
    if ($Sent -gt 0) {
        if ($Received -ge $Sent) { $reason = "complete" }
        elseif ($Received -le 0) { $reason = "silent" }
        else {
            $required = Get-PingCountForThreshold -WarningPercent $WarningPercent
            if ($required -le 0) { $reason = "no-threshold" }
            else {
                $target = [math]::Min($required, [math]::Max(1, $MaximumCount))
                if ($target -le $Sent) { $reason = "at-ceiling"; $target = $Sent }
                else { $reason = "extend" }
            }
        }
    }
    return [pscustomobject][ordered]@{
        Extend          = ($reason -eq "extend")
        AdditionalCount = $(if ($reason -eq "extend") { $target - $Sent } else { 0 })
        TargetCount     = $target
        RequiredCount   = $required
        Reason          = $reason
    }
}

function Get-PingSampleInterval {
    param(
        [double]$RemainingSeconds,
        [int]$RemainingProbes
    )

    # 多出來的探測彼此要隔多遠。這些秒數是從「這次執行本來就欠重傳取樣視窗的等待」裡拿的——
    # Wait-ForMinimumTcpSample 原本就要把它們睡掉——所以只要花的不超過那段等待剩下的時間，把取樣分散開來就
    # 不佔用任何實際時間。剩餘時間歸零時間隔就是 0，探測連續送出，也就是這個功能存在之前的行為。除的是探測
    # 次數而不是間隔數（後者少一個），讓探測本身花的時間有地方可出，分散才會在預算之內結束，而不是剛好超出。
    if ($RemainingProbes -le 0) { return 0.0 }
    if ($RemainingSeconds -le 0) { return 0.0 }
    return [math]::Round(($RemainingSeconds / $RemainingProbes), 2)
}

function Invoke-PingMeasurement {
    param(
        [string]$Target,
        [int]$Count,
        [int]$TimeoutMs,
        [object]$Previous = $null,
        [double]$IntervalSeconds = 0,
        [int]$ProgressPercent = 0
    )

    # -Previous 與 -IntervalSeconds 就是 backlog #51 的自適應取樣。傳進來的量測會被「加上去」而不是取代：第二
    # 輪的探測沿用同一組次數編號，而所有數字都在整個取樣上重算一次，所以這一列回報的是一次量測而不是兩次。
    # -IntervalSeconds 把那些探測分散開來，而不是連續送出——跟 ping.exe 不同，這裡的 echo 之間沒有延遲，二十
    # 次會全部落在不到一秒之內，等於把同一個瞬間量了二十次；而使用者通常想抓的是時好時壞的連線，那需要的是
    # 「時間跨度」而不是「次數」。
    $successes = New-Object System.Collections.ArrayList
    $attemptDetails = New-Object System.Collections.ArrayList
    $repliedAddresses = New-Object System.Collections.ArrayList
    $alreadySent = 0
    if ($null -ne $Previous) {
        foreach ($value in @(Get-PropertyValue $Previous "SuccessMs" @())) { [void]$successes.Add([double]$value) }
        foreach ($value in @(Get-PropertyValue $Previous "AttemptDetails" @())) { [void]$attemptDetails.Add($value) }
        foreach ($value in @(Get-PropertyValue $Previous "RepliedAddresses" @())) { [void]$repliedAddresses.Add($value) }
        $alreadySent = [math]::Max(0, (ConvertTo-IntSafe (Get-PropertyValue $Previous "Sent" 0) 0))
    }
    $ping = New-Object System.Net.NetworkInformation.Ping

    try {
        for ($i = 1; $i -le $Count; $i++) {
            $attempt = $alreadySent + $i
            try {
                $reply = $ping.Send($Target, $TimeoutMs)
                if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                    # backlog #59: the addresses the echoes actually reached, kept because a target given as a name is
                    # not something the route table can be asked about - these are the addresses that can be. Every
                    # distinct one is kept, in the order they first answered: .NET resolves the name per send, so a
                    # name behind round-robin DNS or a TTL that expires mid-run can answer from more than one, and a
                    # row that named the first as 'the address the replies came from' would be claiming the rest
                    # (PR #45, round 3).
                    $thisAddress = [string]$reply.Address
                    if (-not [string]::IsNullOrWhiteSpace($thisAddress) -and @($repliedAddresses) -notcontains $thisAddress) {
                        [void]$repliedAddresses.Add($thisAddress)
                    }
                    [void]$successes.Add([double]$reply.RoundtripTime)
                    [void]$attemptDetails.Add(("第 {0} 次：成功，{1} ms，回覆 {2}" -f $attempt, $reply.RoundtripTime, $reply.Address))
                }
                else {
                    [void]$attemptDetails.Add(("第 {0} 次：失敗，狀態 {1}" -f $attempt, $reply.Status))
                }
            }
            catch {
                [void]$attemptDetails.Add(("第 {0} 次：錯誤，{1}" -f $attempt, (Add-NetworkErrorCause $_.Exception $_.Exception.Message -SingleLine)))
            }
            if ($script:GuiAvailable) {
                [System.Windows.Forms.Application]::DoEvents()
            }
            if ($IntervalSeconds -gt 0 -and $i -lt $Count) {
                # 間隔切成小片來睡，讓視窗持續重繪、進度文字持續在動：分散取樣可能佔掉一次執行裡的一分鐘，而那
                # 一分鐘以前是睡過去的。
                $slices = [int][math]::Max(1, [math]::Ceiling(($IntervalSeconds / 0.25)))
                $sliceMs = [int][math]::Round(($IntervalSeconds * 1000.0 / $slices))
                for ($slice = 1; $slice -le $slices; $slice++) {
                    if ($ProgressPercent -gt 0) {
                        Set-UiProgress -Percent $ProgressPercent -Text ("正在分散送出 {0} 剩下的 ping 取樣，還有 {1} 次" -f $Target, ($Count - $i))
                    }
                    if ($sliceMs -gt 0) { Start-Sleep -Milliseconds $sliceMs }
                    Invoke-TcpIntervalReadIfDue
                    if ($script:GuiAvailable) {
                        [System.Windows.Forms.Application]::DoEvents()
                    }
                }
            }
        }
    }
    finally {
        $ping.Dispose()
    }

    $sent = $alreadySent + [math]::Max(0, $Count)
    $received = $successes.Count
    $lost = $sent - $received
    $lossPercent = 0
    if ($sent -gt 0) {
        $lossPercent = [math]::Round(($lost * 100.0 / $sent), 1)
    }

    $average = $null
    $minimum = $null
    $maximum = $null
    if ($received -gt 0) {
        $average = [math]::Round((($successes | Measure-Object -Average).Average), 1)
        $minimum = [math]::Round((($successes | Measure-Object -Minimum).Minimum), 1)
        $maximum = [math]::Round((($successes | Measure-Object -Maximum).Maximum), 1)
    }
    # backlog #61's other half: the sample standard deviation of the replies that arrived, over the whole sample where
    # one was continued, like every other figure here; two replies are the least a spread can be taken over.
    $spread = $null
    if ($received -ge 2) {
        $mean = ($successes | Measure-Object -Average).Average
        $squares = 0.0
        foreach ($value in $successes) { $squares += ([double]$value - $mean) * ([double]$value - $mean) }
        $spread = [math]::Round([math]::Sqrt($squares / ($received - 1)), 1)
    }

    return [pscustomobject][ordered]@{
        Target         = $Target
        Sent           = $sent
        Received       = $received
        Lost           = $lost
        LossPercent    = $lossPercent
        AverageMs      = $average
        MinimumMs      = $minimum
        MaximumMs      = $maximum
        SpreadMs       = $spread
        SuccessMs      = @($successes)
        RepliedAddresses = @($repliedAddresses)
        AttemptDetails = @($attemptDetails)
    }
}

function Get-CanonicalIPv4Text {
    param([string]$Value)

    # IPv4 位址的點分十進位寫法；不是 IPv4 位址時，回傳去掉頭尾空白的原文。.NET 的解析器接受單一個數字、十六進位的
    # 段、不足四段，以及被讀成八進位的前導零——3221225994、0xC0.0.2.10、192.0.2 和 192.0.2.010 都解析得過，最後
    # 一個解析成 192.0.2.8——所以設定檔裡的寫法和作業系統回報的位址要比較，必須比較解析後的形式（PR #51 第 2 輪）。
    $text = ([string]$Value).Trim()
    $parsed = $null
    if ([System.Net.IPAddress]::TryParse($text, [ref]$parsed) -and $parsed.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) { return $parsed.ToString() }
    return $text
}

function Test-NearEndAddressSyntax {
    param([string]$Value)

    # 近端目標的規則（backlog #60）：以每一種解析器都讀成同一個意思的那一種寫法給定的 IPv4 位址——四個十進位數字加
    # 點，別無其他。.NET 也接受的其他形式對不同的讀者是不同的位址（192.0.2.010 對 .NET 是 192.0.2.8、對人是
    # 192.0.2.10），而一列探測了一個位址、設定檔卻寫著另一個，正是這個鍵存在是為了避免的混淆。所以設定檔寫的和
    # 探測送去的必須是同一個字串，這裡和設定檢查都是。
    $text = ([string]$Value).Trim()
    if (-not (Test-IsValidIPv4Address $text)) { return $false }
    return ((Get-CanonicalIPv4Text $text) -eq $text)
}

function Test-NearEndTargetPlacement {
    param(
        [string]$Address,
        [object[]]$PrimaryAdapters
    )

    # 設定的近端目標相對於這台機器在哪裡（backlog #60），在送出任何東西之前就決定，因為這一列的整個主張就是它的探測
    # 經過了哪些路段。五種答案：位址是主要網卡的某個閘道，所以不能當近端這一階——閘道是用控制平面回應的，而且它已經
    # 是下一階了；位址是這台電腦自己的位址之一，所以送給它的探測是由這個堆疊自己回應的，完全沒有經過網路線、無線電
    # 或交換器（PR #51 第 1 輪）；位址是它所在子網段的網路位址或廣播位址，沒有任何主機持有它；位址在主要網卡的某個
    # IPv4 子網段裡，所以它就是近端主機；或以上都不是，那麼送給它的探測會經過閘道，量到的是錯的東西。子網段是快照
    # 本來就帶著的「位址/前綴」值；前綴未知的網卡不貢獻子網段，而一台沒有任何已知子網段的機器什麼都放不了——那一列
    # 會照實說，而不是猜。
    # 每一次比較都用解析後的點分十進位形式（PR #51 第 2 輪）：設定檢查套用的規則會拒絕其他寫法，但這裡不倚賴那一點——
    # 呼叫者給 3221225994 和給 192.0.2.10 得到同樣的答案，而那一列會被告知放到位的是哪一種形式。
    $canonical = Get-CanonicalIPv4Text $Address
    $subnets = @()
    $ownAddresses = @()
    foreach ($adapter in @($PrimaryAdapters)) {
        foreach ($entry in @($adapter.IPv4WithPrefix)) {
            if (([string]$entry) -match '/\d+$') { $subnets += [string]$entry }
        }
        foreach ($own in @($adapter.IPv4Addresses)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$own)) { $ownAddresses += (Get-CanonicalIPv4Text $own) }
        }
    }
    $gateways = @(@(Resolve-PingTargets -Address "AUTO_GATEWAY" -PrimaryAdapters $PrimaryAdapters) | ForEach-Object { Get-CanonicalIPv4Text $_ })
    $placement = "off-subnet"
    $matchedSubnet = ""
    if ($gateways -contains $canonical) { $placement = "gateway" }
    elseif ($ownAddresses -contains $canonical) { $placement = "self" }
    else {
        foreach ($subnet in $subnets) {
            if (Test-IPv4InCidr -IpAddress $canonical -Cidr $subnet) {
                $placement = "on-subnet"
                $matchedSubnet = [string]$subnet
                # 主機部分全 0 與全 1 是子網段自己的網路位址與廣播位址，不是主機；/31 與 /32 兩者都沒有（RFC 3021），
                # 所以不動它們。
                $prefix = [int]($subnet.Split('/')[1])
                if ($prefix -le 30) {
                    $bytes = [System.Net.IPAddress]::Parse($canonical).GetAddressBytes()
                    $value = ([int64]$bytes[0] * 16777216) + ([int64]$bytes[1] * 65536) + ([int64]$bytes[2] * 256) + [int64]$bytes[3]
                    $hostMax = [int64][math]::Pow(2, (32 - $prefix)) - 1
                    $hostPart = $value -band $hostMax
                    if ($hostPart -eq 0 -or $hostPart -eq $hostMax) { $placement = "not-a-host" }
                }
                break
            }
        }
    }
    # Subnet 是目標落在哪個「位址/前綴」裡，那一列用它來問路由表是不是真的為探測選了那張網卡（PR #51 第 3 輪）；
    # 什麼都沒放到位時是空的。
    return [pscustomobject][ordered]@{
        Placement = $placement
        Canonical = $canonical
        Subnet    = $matchedSubnet
        Subnets   = @($subnets | Select-Object -Unique)
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

function Get-PingRouteAfter {
    param(
        [string]$Target,
        [bool]$TargetIsAddress,
        [object]$Measurement
    )

    # 一列在探測之後做的路由查詢（backlog #59），獨立成一個函式是因為現在有兩個呼叫者：第一輪之後馬上寫出來
    # 的那一列，以及取樣被延續、在執行後段才寫出來的那一列（backlog #51）。兩者都在最後一次探測之後才查，
    # 「之後」本來就只能是這個意思。
    $lookupAddresses = @([string]$Target)
    if (-not $TargetIsAddress) { $lookupAddresses = @(Get-PropertyValue $Measurement "RepliedAddresses" @()) }
    $lookupAddress = ""
    if (@($lookupAddresses).Count -gt 0) { $lookupAddress = ConvertTo-SafeString @($lookupAddresses)[0] }
    $routeOthers = @()
    if ([string]::IsNullOrWhiteSpace($lookupAddress)) {
        $routeAfter = [pscustomobject][ordered]@{ Resolved = $false; Reason = "noreply"; SourceAddress = ""; InterfaceAlias = ""; NextHop = ""; OnLink = $false }
    }
    else {
        $routeAfter = Get-RouteSelection -Target $lookupAddress
        # Each further address its replies came from is looked up too, because the point of this row is
        # which adapter carried the measurement and two addresses can answer through two of them.
        foreach ($extra in @($lookupAddresses | Select-Object -Skip 1)) {
            $routeOthers += [pscustomobject][ordered]@{ Address = ConvertTo-SafeString $extra; Selection = (Get-RouteSelection -Target ([string]$extra)) }
        }
    }
    return [pscustomobject][ordered]@{ Selection = $routeAfter; LookupAddress = $lookupAddress; Others = @($routeOthers) }
}

function Get-LatencySpreadText {
    param([object]$Measurement)

    # 一列 ping 的往返時間離散度，寫成 details 裡的一句話（backlog #61 的另一半）。遺失很少、變異卻大，是空氣的
    # 特徵——802.11 重試被吸收成延遲，所以回覆會到、只是不均勻——而在 1.2.13 之前，這一列留著每筆回覆的毫秒數，
    # 卻只算平均值和兩端。這個數字是有到達的回覆的樣本標準差：是描述，絕不是判定，因為沒有任何門檻對它有陳述過的
    # 依據。而且它會說明自己取自多大的樣本，因為在一個目標起始的四筆回覆上，它描述的是四個時刻而不是這條連線。
    # 下面的最小值是這個數字自身的不確定度降到自身四分之一以下的點——樣本標準差的相對標準誤約為 1 / sqrt(2 (n - 1))，
    # n = 9 時是 25 %——一個選定的精度，連同算式記錄在儲存庫的門檻頁（docs/thresholds.md）；到了那個點什麼都不判定，
    # 只換一句話。
    $minimum = 9
    $received = ConvertTo-IntSafe (Get-PropertyValue $Measurement "Received" 0) 0
    $spread = Get-PropertyValue $Measurement "SpreadMs" $null
    if ($received -lt 2 -or $null -eq $spread) { return "" }
    $text = "離散度：有到達的 {1} 筆回覆的標準差 {0} ms（平均 {2} ms，範圍 {3} 到 {4}）。往返時間是整數毫秒，所以在一、兩毫秒就回應的連線上，約 1 ms 的離散度是計時器的解析度，不是連線。" -f $spread, $received, $Measurement.AverageMs, $Measurement.MinimumMs, $Measurement.MaximumMs
    if ($received -lt $minimum) {
        $text += ("{0} 筆回覆描述的是 {0} 個時刻而不是這條連線：要 {1} 筆回覆這個數字自身的不確定度才會降到自身的四分之一以下，所以請把它放在同一目標較長樣本的數字旁邊讀。它不影響任何判定。" -f $received, $minimum)
    }
    else {
        $text += ("在 {0} 筆回覆時（{1} 筆以上）這個數字自身的不確定度已低於自身的四分之一，所以它描述的是本次執行對這個目標的變異；它不影響任何判定，因為沒有任何門檻對它有陳述過的依據。" -f $received, $minimum)
    }
    return $text
}

function Add-PingTargetResult {
    param(
        [string]$Name,
        [string]$Target,
        [string]$ConfiguredAddress,
        [bool]$Required,
        [object]$Measurement,
        [object]$RouteBefore,
        [object]$RouteAfter,
        [bool]$TargetIsAddress,
        [int]$TimeoutMs,
        [string]$SampleNote = "",
        [object]$Row = $null,
        [bool]$NearEnd = $false,
        [string[]]$RungSubnets = @()
    )

    # 一列 ping 結果。它獨立成一個函式，是因為第一輪不足以下結論的目標，這一列會被寫兩次——一次是在報告裡它該
    # 在的位置、用第一輪的結果寫出來，另一次是在取樣延續完成之後（backlog #51）——而寫在兩個地方的一列，遲早會
    # 變成兩列不一樣的東西。
    # -Row 就是第二次。報告是照加入順序呈現各列的，所以太晚加入的一列會掉到 DNS 與連線能力那些段落下面，而不是
    # 跟其他 ping 的列在一起；因此會變的是這一列「說什麼」，絕不是它「在哪裡」。
    $warningLoss = ConvertTo-DoubleSafe $script:Config.Thresholds.PacketLossWarningPercent 5
    $criticalLoss = ConvertTo-DoubleSafe $script:Config.Thresholds.PacketLossCriticalPercent 20
    $warningLatency = ConvertTo-DoubleSafe $script:Config.Thresholds.LatencyWarningMs 100
    $criticalLatency = ConvertTo-DoubleSafe $script:Config.Thresholds.LatencyCriticalMs 250

    # 標籤在這裡自己推導，而不是由外面傳進來；下面兩行是刻意複製 Test-PingTargets 裡那兩行的（backlog #33
    # 的文件事實步驟）：它會從 AST 讀出每一個 -Tag 引數，而且只有在「對某個變數的每一次指派都是常值」時才
    # 解析得出來，所以透過參數、屬性或輔助函式回傳值送到 Add-CheckResult 的標籤，會變成一個存在於程式裡、
    # 卻在所有「用文件核對程式」的檢查之外的標籤。複製這兩行，是讓那個步驟看得見這一條規則的代價。
    # 這一列到底能不能主張它那一階（PR #51 第 3、4 輪）。在子網段內只說明主機在哪裡，不說明探測是從哪張網卡出去的：探測
    # 沒有綁定，而 VPN、第二條連線或更明確的路由可以把送往子網段內位址——或閘道位址——的探測帶到完全不同的地方。所以只有
    # 路由表在探測前後都選了這一階所屬子網段之一上的來源位址——近端主機自己的子網段，或提供這個閘道的那些網卡的子網段，
    # 也就是連接路由，接在那個子網段上的那張網卡——這一列才主張這一階。若不是、或選擇變了、或查詢無法取得，這一列保留
    # 標題與量測並說明它為什麼不能主張這一階；近端列此時標成一般的 ping 目標，讓摘要永遠不會把它當成一條它可能沒走過的
    # 路徑的證人，閘道列則保留標籤，因為閘道仍然是它量測的目標。Path——主張了那一階時的那張網卡——是摘要用來把近端列和失敗的閘道列配對的欄位；
    # 第 6 輪把它從「兩次查詢一致」改成「主張了那一階」，因為一致的選擇仍可能經過路由器。標籤的指派維持常值，這是 backlog #33 文件事實步驟的要求。
    $selectionAgreed = ($null -ne $RouteBefore -and $null -ne $RouteAfter.Selection -and $RouteBefore.Resolved -and $RouteAfter.Selection.Resolved -and
        $RouteBefore.SourceAddress -eq $RouteAfter.Selection.SourceAddress -and $RouteBefore.InterfaceAlias -eq $RouteAfter.Selection.InterfaceAlias -and
        [string]$RouteBefore.NextHop -eq [string]$RouteAfter.Selection.NextHop)
    $rungAttested = $false
    # On-link as well (PR #51, round 5): a next hop is a router, and a probe through a router has not measured the
    # local path however local its target is.
    if ($selectionAgreed -and $RouteBefore.OnLink -eq $true) {
        foreach ($rungSubnet in @($RungSubnets)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$rungSubnet) -and (Test-IPv4InCidr -IpAddress $RouteBefore.SourceAddress -Cidr ([string]$rungSubnet))) { $rungAttested = $true; break }
        }
    }
    # Path 是這一列經證明走過本地路徑的那張網卡（PR #51 第 6 輪）：只在主張了那一階時才寫，讓摘要用來配對的那個欄位
    # 就是推論需要的意思。查詢一致卻經過路由器的閘道列，以及從不主張任何一階的遠端列，都不帶它。
    $path = ""
    if ($rungAttested) { $path = [string]$RouteBefore.InterfaceAlias }
    $pingTag = "ping-target"
    if ($ConfiguredAddress -eq "AUTO_GATEWAY") { $pingTag = "ping-gateway" }
    if ($NearEnd -and $rungAttested) { $pingTag = "ping-near-end" }
    $status = "PASS"
    $weightless = $false
    $coarseNote = ""
    $blockedIcmpNote = $false
    $lossStatus = ""
    $latencyStatus = ""
    # 狀態是由哪一種量測決定的（backlog #67）：由遺失級別決定的寫 "loss"——完全沒有回應的列也算——由真的回來的那些
    # 回覆決定的寫 "latency"，什麼都沒決定的留空。fingerprint 會讀它，因為每次探測都回應、只是回應得慢的閘道，不是
    # 「沒有回應」的閘道。
    $rule = ""
    $loss = Get-PingLossClassification -Sent $Measurement.Sent -Lost $Measurement.Lost -WarningPercent $warningLoss -CriticalPercent $criticalLoss

    if ($Measurement.Received -eq 0) {
        $rule = "loss"
        # 非必要的 ICMP 目標本來就可能刻意封鎖 Ping。完全沒有回覆以前不論取樣多小都保有判定，理由是「四次探測
        # 下 100 % 遺失就是結論，再多次也不會更確定」—— 那是一個關於「四」的論證，卻被套用在「一」上（PR #49
        # 第 5 輪）。PingCount 設成 1 是設定檢查與 IT 面板都允許的值，而在那裡「100 % 遺失」和「掉了一個封包」
        # 是同一件事：一次逾時就讓必要目標異常。這個版本已經有的規則不必發明新數字就能解決它，因為它問的正是
        # 對的問題 —— 取樣對門檻來說太粗，「而且」少遺失一次分類就會不一樣時，才收回判定。四次探測不會（四次
        # 掉三次仍然是嚴重），一次會。而且兩種情況都不會多送：最貴的那一種仍然是最便宜的那一種。
        # 那句話屬於「情況」，不屬於「判定」（PR #49 第 6 輪）：非必要目標完全沒有回覆時，不論判定有沒有被收回，
        # 它都可能只是封鎖了 ICMP；第 5 輪把兩者綁在一起，結果一次探測的非必要目標反而失去了它最需要的那句指引。
        $blockedIcmpNote = (-not $Required)
        if ($loss.Weightless) {
            $status = "INFO"
            $weightless = $true
            $coarseNote = ("{0} 次探測全部沒有回覆，而只要其中任何一次回來，分類就會不一樣，所以這一列就是那一個封包。" -f $Measurement.Sent)
        }
        else {
            $status = if ($Required) { "FAIL" } else { "INFO" }
        }
    }
    else {
        $lossStatus = "PASS"
        if ($loss.Weightless) {
            # backlog #51：級別是達到了，但它是靠一個封包達到的，而取樣對這個門檻來說太粗。這一列保留量到的每
            # 一個數字，並且不再決定這次執行——本項目拿掉的是判定，從來不是數字。
            $lossStatus = "WARN"
            $weightless = $true
            # 警告門檻是 0 或更小時，沒有任何次數躲得過它，於是也沒有「需要幾次」可以寫——寫出 0 會是一句
            # 假的建議。設定檢查允許這個值，所以這個分支寫的是真話而不是一個數字。
            if ($loss.RequiredCount -le 0) {
                $coarseNote = ("此取樣數對這個門檻來說太小：{0} 次裡有一次沒有回覆就是 {1}%，而分類會因為那一次而改變。警告門檻是 {2}%，沒有任何回覆次數能讓單一次遺失低於它。" -f $Measurement.Sent, ([math]::Round((100.0 / $Measurement.Sent), 1)), $warningLoss)
            }
            else {
                $coarseNote = ("此取樣數對這個門檻來說太小：{0} 次裡有一次沒有回覆就是 {1}%，而分類會因為那一次而改變。要讓單一次遺失仍低於 {3}% 的警告門檻，需要 {2} 次回覆。" -f $Measurement.Sent, ([math]::Round((100.0 / $Measurement.Sent), 1)), $loss.RequiredCount, $warningLoss)
            }
        }
        elseif ($loss.Band -eq "critical") { $lossStatus = if ($Required) { "FAIL" } else { "WARN" } }
        elseif ($loss.Band -eq "warning") { $lossStatus = "WARN" }

        $latencyStatus = "PASS"
        if ($null -ne $Measurement.AverageMs -and $Measurement.AverageMs -ge $criticalLatency) { $latencyStatus = if ($Required) { "FAIL" } else { "WARN" } }
        elseif ($null -ne $Measurement.AverageMs -and $Measurement.AverageMs -ge $warningLatency) { $latencyStatus = "WARN" }

        # 先看遺失、再看延遲，這是這個工具一向的順序。新的地方是：判定被收回的遺失數字，會把這一列交給延遲規
        # 則，而不是自己留著——兩者是對同一批探測做的兩種量測，而 #51 認為太粗的只有遺失那一半。真的回來的那
        # 些回覆所達到的延遲門檻是一次量測，達到它的一列保有權重。
        $status = $lossStatus
        if ($lossStatus -ne "PASS") { $rule = "loss" }
        if ($latencyStatus -ne "PASS" -and ($weightless -or $lossStatus -eq "PASS")) {
            $status = $latencyStatus
            $weightless = $false
            $rule = "latency"
        }
    }

    # 上面那句話只講分類本身，後果這一句要等這一列的狀態定下來才寫（PR #49 第 2 輪）：4 次掉 1 次、平均 300 ms
    # 的必要目標，遺失判定被收回，決定這一列的是延遲，而這一列**會**改變整體結果。一句寫死的「這一列不會改變整體
    # 結果」在那裡就是假的。它放在那個分支外面，是因為從第 5 輪起，完全沒有回覆的情況也可能被收回判定。
    if ($coarseNote -ne "") {
        if ($weightless) { $coarseNote += "上面的數字就是實際量到的，而這一列不會改變整體結果。" }
        else { $coarseNote += "上面的數字就是實際量到的；決定這一列的是它的延遲——那是對真的回來的那些回覆所做的量測。" }
    }

    $latencyText = "無成功回覆"
    if ($null -ne $Measurement.AverageMs) {
        $latencyText = ("平均 {0} ms（最低 {1}、最高 {2}）" -f $Measurement.AverageMs, $Measurement.MinimumMs, $Measurement.MaximumMs)
    }

    $message = "目標 {0}：遺失 {1}%（{2}/{3} 成功），{4}。" -f $Target, $Measurement.LossPercent, $Measurement.Received, $Measurement.Sent, $latencyText
    $detailLines = @()
    $detailLines += @($Measurement.AttemptDetails)
    # backlog #61 的另一半：往返時間的離散度，一句話，說明自己取自多大的樣本、而且不影響任何判定——理由寫在
    # Get-LatencySpreadText；回覆不到兩筆的列沒有這一行。
    $spreadLine = Get-LatencySpreadText -Measurement $Measurement
    if (-not [string]::IsNullOrWhiteSpace($spreadLine)) { $detailLines += $spreadLine }
    $detailLines += (Format-RouteSelection -Before $RouteBefore -After $RouteAfter.Selection -LookupAddress $RouteAfter.LookupAddress -Others $RouteAfter.Others)
    # backlog #60：這一列是哪一階，寫成「探測經過了哪些路段、沒有經過哪些」。只有兩列會寫——近端主機那一列，因為
    # 有它各列 ping 才成為一道階梯；以及閘道那一列，因為它的探測是由控制平面而不是主機回應的——而讀法規則寫在近端
    # 那一列，因為讀者正要拿一階減另一階時，看的就是那一列。遠端目標的列不主張自己是哪一階：額外目標在閘道的哪一
    # 邊，不是這一列量過的東西。
    if ($NearEnd -and $rungAttested) {
        $detailLines += ("階梯：近端——{0} 位於這台電腦所在的子網段、而且不是閘道，所以這些探測只經過本地路徑——這台電腦的網卡、它的網路線或 Wi-Fi 連線、以及交換器或存取點——並由一台普通主機回應，而不是由閘道的控制平面回應；它們沒有經過閘道，也沒有經過閘道之外的任何東西。路由表在探測前後都選了來源 {1}、經由 {2}——那是同一子網段上的位址，直連、沒有下一跳——這是這一列能主張本地路徑的依據；探測本身沒有綁定。把各列 ping 當成一道階梯來讀：通過的一階，說明它經過的路段在那一刻是通的；第一個失敗的一階，把問題放在最後一個通過的階之外——但不會更近——因為兩階的數字是不同時刻送出的不同流量，不能相減成兩階之間那一段的遺失率。" -f $Target, $RouteBefore.SourceAddress, $RouteBefore.InterfaceAlias)
    }
    elseif ($NearEnd) {
        $detailLines += ("階梯：近端——不主張。{0} 位於這台電腦所在的子網段，但探測沒有綁定，而上面的路由選擇不是探測前後都選中同一子網段上、直連的同一個位址——VPN、第二條連線或經過路由器的更明確路由可能帶走了探測，或查詢無法取得——所以這一列說不出它們經過了哪些路段。它算作一般的 ping 目標，不算近端這一階，摘要也不把它當成本地路徑的證人。" -f $Target)
    }
    elseif ($pingTag -eq "ping-gateway" -and $rungAttested) {
        $detailLines += ("階梯：閘道——這些探測經過本地路徑——這台電腦的網卡、它的網路線或 Wi-Fi 連線、以及交換器或存取點——並由閘道自己的控制平面回應；它們沒有經過閘道之外的任何東西。路由表在探測前後都選了來源 {0}、經由 {1}——那是提供這個閘道的那張網卡所在子網段上的位址，直連、沒有下一跳；探測本身沒有綁定。" -f $RouteBefore.SourceAddress, $RouteBefore.InterfaceAlias)
    }
    elseif ($pingTag -eq "ping-gateway") {
        $detailLines += "階梯：閘道——不主張。探測沒有綁定，而上面的路由選擇不是探測前後都選中提供這個閘道的那張網卡所在子網段上、直連的同一個位址——VPN、第二條連線或經過路由器的更明確路由可能帶走了探測，或查詢無法取得——所以這一列說不出它們經過了哪些路段。閘道仍然是這一列量測的目標，摘要照舊讀它的結果。"
    }
    if (-not [string]::IsNullOrWhiteSpace($SampleNote)) { $detailLines += $SampleNote }
    if (-not [string]::IsNullOrWhiteSpace($coarseNote)) { $detailLines += $coarseNote }
    # 檢測方式這一行算的是實際送出的探測次數，而不是設定的次數：從 1.2.10 起 PingCount 是起始次數，只要取樣
    # 被延續過，兩者就是不同的數字；而旁邊的手動驗證，必須是能重現這一列所回報內容的那一道指令。
    $detailLines += ("檢測方式：.NET Ping — {0} 次 ICMP echo，逾時 {1} ms{2}。" -f $Measurement.Sent, $TimeoutMs, (Get-RouteMethodText -Target $Target -LookupAddress $RouteAfter.LookupAddress -TargetIsAddress $TargetIsAddress -ExtraCount (@($RouteAfter.Others).Count)))
    $detailLines += ("手動驗證：ping -n {0} {1}" -f $Measurement.Sent, $Target)
    $details = (@($detailLines) -join [Environment]::NewLine)
    # backlog #58：唯一的必要 ping 目標是由閘道自己的 stack 回應的，而網路設備通常會對送給自己的 ICMP 限速或降低優先權——
    # 所以閘道爽快回應是「近端路徑正常」的好證據，閘道不回應卻不是「它壞了」的證明。這項檢查維持必要（2026-09-10 決定：
    # 連自己閘道都到不了的機器通常真的有問題值得回報），而失敗的那一列要說清楚這個失敗能說明什麼、不能說明什麼，措辭沿用
    # 現場手冊 gateway-unreachable 那一格，讓兩邊不會各說各話。只有 FAIL 列帶這句：通過的列沒有東西要補充，判定被收回的列
    # 已經說明了原因。
    if ($pingTag -eq "ping-gateway" -and $status -eq "FAIL") {
        # 必要閘道列失敗有兩種方式，句子要點名發生的是哪一種（PR #50 第 2 輪）：回應沒有回來，或回應回來了但平均延遲達到
        # 嚴重門檻、而遺失判定是通過或被收回的。兩種都是設備的控制平面在回應，所以模稜兩可的方式相同；不同的是這一列能陳述
        # 的事實——一列什麼都沒遺失的列，不能說它遺失了。
        if ($latencyStatus -eq "FAIL" -and $lossStatus -ne "FAIL") {
            $gatewayFact = ("閘道自己的位址回應了送給它的 {2} 次 echo 請求中的 {1} 次，但很慢——平均 {0} ms，達到嚴重延遲門檻。這是先查本地路徑——連線、Wi-Fi、交換器——的理由，但不證明閘道轉送得慢：設備是用控制平面回應送給自己的 Ping，優先權低於它轉送的流量。" -f $Measurement.AverageMs, $Measurement.Received, $Measurement.Sent)
        }
        else {
            $gatewayFact = ("閘道沒有回應送到它自己位址的 {1} 次 echo 請求中的 {0} 次。這是先查本地路徑——連線、Wi-Fi、交換器——的理由，但不證明閘道壞了：正常轉送流量的閘道仍可能丟棄或限速送給它自己的 Ping。" -f $Measurement.Lost, $Measurement.Sent)
        }
        $details += [Environment]::NewLine + "這個失敗能說明什麼、不能說明什麼：" + $gatewayFact + "能證明它有在轉送的，是一個位於它之外、路由經過這個閘道而且通過的目標——不是隨便一列通過就算，因為同網段的主機、VPN 或 Proxy 都可能完全沒經過它就成功。把這一列當成嫌疑，不是定罪。"
    }
    # 只有在這一列真的是「非必要目標完全沒有回覆」時才加。第 5 輪之前這是看狀態判斷的，那時兩者等價 —— 但現在
    # 被收回判定的「完全沒有回覆」同樣是 INFO，就不等價了。
    if ($blockedIcmpNote) {
        $details += [Environment]::NewLine + "補充說明：此為非必要目標，可能單純封鎖 ICMP——網際網路的權威判定請看「連線能力」群組。"
    }
    if ($null -eq $Row) {
        return (Add-CheckResult -Category "延遲與封包遺失" -Check ("{0}：{1}" -f $Name, $Target) -Status $status -Message $message -Details $details -Tag $pingTag -Weightless:$weightless -Rule $rule -Path $path)
    }
    $Row.Status = $status
    $Row.Message = $message
    $Row.Details = $details
    $Row.Weightless = $weightless
    $Row.Rule = $rule
    $Row.Path = $path
    # 標籤可能隨第二輪而動：近端列在最後一次探測之後的路由選擇若不再和探測之前的一致，就不再主張這一階，而摘要必須
    # 看得到這一點（PR #51 第 3 輪）。
    $Row.Tag = $pingTag
    # 執行紀錄是這次執行的敘事，所以第二次的讀數會自己占一行，而不是悄悄把第一次蓋掉：盯著視窗看的人看過那組
    # 暫時的數字，就該看到取代它們的那一組。
    Write-UiLog -Status $status -Text ("{0} / {1}: {2}" -f $Row.Category, $Row.Check, $message)
    return $Row
}

function Complete-PingSamples {
    param(
        [datetime]$SampleStart,
        [int]$MinimumSeconds
    )

    # 自適應 ping 取樣的後半段（backlog #51）。這些探測在這裡、也就是執行的後段才送出，而不是接在第一輪後面
    # 連續送完，因為重傳取樣視窗本來就橫跨整次執行：Wait-ForMinimumTcpSample 正要把剩下的秒數睡掉，而分散在
    # 那些秒數裡的探測，用的是這次執行本來就要花掉的實際時間，量到的卻是一段時間跨度。預算由還在等的目標平
    # 分；預算用完時探測就連續送出，執行時間會多出它們所花的時間——那是一個真的掉了回覆的目標該付的誠實代價。
    $pending = @($script:PendingPingSamples)
    $script:PendingPingSamples = New-Object System.Collections.ArrayList
    if ($pending.Count -eq 0) { return }

    $timeout = [math]::Max(250, (ConvertTo-IntSafe $script:Config.Tests.PingTimeoutMs 1200))
    $index = 0
    foreach ($item in $pending) {
        $index++
        # 清單在進入這個迴圈之前就已經清空，而那一列早就在報告裡了，所以這個 try 以外的任何東西都不會再回到
        # 這個目標：這裡拋出例外，一定要讓它那一列說出發生了什麼事，就像其他每一項檢查失敗時一樣。
        try {
            $budget = 0.0
            $elapsed = ((Get-Date) - $SampleStart).TotalSeconds
            if ($MinimumSeconds -gt $elapsed) { $budget = ($MinimumSeconds - $elapsed) / ($pending.Count - $index + 1) }
            $interval = Get-PingSampleInterval -RemainingSeconds $budget -RemainingProbes $item.Plan.AdditionalCount
            $measurement = $item.Measurement
            $note = ""
            try {
                $measurement = Invoke-PingMeasurement -Target $item.Target -Count $item.Plan.AdditionalCount -TimeoutMs $timeout -Previous $item.Measurement -IntervalSeconds $interval -ProgressPercent 78
            }
            catch {
                # 可以放棄的是延伸的那一段：第一輪量到的仍然是一次量測，用它寫出來的那一列，就是自適應取樣出
                # 現之前這個工具會寫的那一列。只有附註會不一樣。
                $note = ("取樣無法繼續，因此這些數字只涵蓋最前面的 {0} 次 ICMP echo。{1}" -f $item.Measurement.Sent, (Get-ExceptionDetails $_))
            }
            if ($measurement.Sent -gt $item.Measurement.Sent) {
                $note = ("自適應取樣：前 {0} 次 ICMP echo 有 {1} 次沒有回覆，因此再送出 {2} 次，並分散在本次執行剩下的時間裡，而不是連續送出。上面每個數字都是這 {3} 次的合計；這一列上的時間是第一輪結束的時刻，後面那些探測都在它之後。" -f $item.Measurement.Sent, $item.Measurement.Lost, ($measurement.Sent - $item.Measurement.Sent), $measurement.Sent)
                if ($item.Plan.TargetCount -lt $item.Plan.RequiredCount) {
                    $note += ("（設定的上限讓它停在 {0} 次，低於「讓單一次遺失仍低於警告門檻」所需的 {1} 次。）" -f $item.Plan.TargetCount, $item.Plan.RequiredCount)
                }
            }
            # 路由表再問一次，因為「探測之後」本來就得是「最後一次探測之後」。
            $routeAfter = Get-PingRouteAfter -Target $item.Target -TargetIsAddress $item.TargetIsAddress -Measurement $measurement
            Add-PingTargetResult -Name $item.Name -Target $item.Target -ConfiguredAddress $item.Address -Required $item.Required -Measurement $measurement -RouteBefore $item.RouteBefore -RouteAfter $routeAfter -TargetIsAddress $item.TargetIsAddress -TimeoutMs $timeout -SampleNote $note -Row $item.Row -NearEnd $item.NearEnd -RungSubnets $item.RungSubnets | Out-Null
        }
        catch {
            # 這一列早就帶著第一輪量到的結果在報告裡了，所以這裡失去的只有延伸的那一段；多出來的是它為什麼沒發生。
            $item.Row.Details = ([string]$item.Row.Details + [Environment]::NewLine + ("取樣無法繼續。{0}" -f (Get-ExceptionDetails $_)))
            Write-UiLog -Status "INFO" -Text ("{0} / {1}：取樣無法繼續。" -f $item.Row.Category, $item.Row.Check)
        }
    }
}

function Test-PingTargets {
    param([object[]]$PrimaryAdapters)

    $count = [math]::Max(1, (ConvertTo-IntSafe $script:Config.Tests.PingCount 4))
    # backlog #51：自適應取樣最多能加到哪裡。它永遠不會低於起始次數，所以就算設定把這一對寫反了，該送出的
    # 次數還是會送出。
    $maximum = [math]::Max($count, (ConvertTo-IntSafe $script:Config.Tests.PingCountMaximum 21))
    $timeout = [math]::Max(250, (ConvertTo-IntSafe $script:Config.Tests.PingTimeoutMs 1200))
    $warningLoss = ConvertTo-DoubleSafe $script:Config.Thresholds.PacketLossWarningPercent 5

    # 階梯，按順序（backlog #60）：有設定近端主機時它排第一，然後是清單裡的目標——閘道，再來是閘道之外的東西。近端
    # 這一項是在這裡組出來的，而不是從清單讀出來的，這樣設定檔就不能把清單裡的某一項升格成近端這一階，而 traceroute
    # ——它是往第一個字面 ping 目標追蹤的——也永遠不會因為這個鍵而挑到近端主機。
    $entries = @()
    $nearEnd = Get-PropertyValue $script:Config.Tests "NearEndTarget" $null
    $nearEndAddress = ""
    if ($null -ne $nearEnd) { $nearEndAddress = (ConvertTo-SafeString (Get-PropertyValue $nearEnd "Address" "")).Trim() }
    # 空白位址是出廠的、停用的狀態——除非這一項標記為必要，那就是一項無法執行的必要檢查，直接丟掉會讓這次執行通過一項
    # 它從來沒做的檢查（PR #51 第 3 輪）。
    if (-not [string]::IsNullOrWhiteSpace($nearEndAddress) -or ($null -ne $nearEnd -and [bool](Get-PropertyValue $nearEnd "Required" $false))) {
        $entries += [pscustomobject][ordered]@{ Target = $nearEnd; NearEnd = $true }
    }
    foreach ($targetConfig in @($script:Config.Tests.PingTargets)) {
        if ($null -ne $targetConfig) { $entries += [pscustomobject][ordered]@{ Target = $targetConfig; NearEnd = $false } }
    }

    foreach ($entry in $entries) {
        $targetConfig = $entry.Target
        $isNearEnd = [bool]$entry.NearEnd

        $name = ConvertTo-SafeString (Get-PropertyValue $targetConfig "Name" $(if ($isNearEnd) { "近端主機" } else { "Ping" }))
        $address = (ConvertTo-SafeString (Get-PropertyValue $targetConfig "Address" "")).Trim()
        $pingTag = "ping-target"
        if ($address -eq "AUTO_GATEWAY") { $pingTag = "ping-gateway" }
        if ($isNearEnd) { $pingTag = "ping-near-end" }
        $required = [bool](Get-PropertyValue $targetConfig "Required" $false)
        # 在送出任何東西之前就決定（backlog #39）：無法成為 ping 目標的值是關於本次執行輸入的事實，硬要嘗試會把
        # 打錯字變成一次量測——「http://example.com」解析不到任何位址，卻回報 100% 遺失，讀起來像網路把每個封包
        # 都丟掉了。下面那個「格式正確卻解析不到」的分支則是量測，保有權重。
        # 近端目標用的是設定檢查套用的那條較窄的規則：點分十進位形式的 IPv4 位址，絕不是名稱、佔位符或另一種寫法，
        # 因為執行時必須在送出任何東西之前就把它放到位，而探測必須送到設定檔寫的那個位址（backlog #60；PR #51 第 2 輪）。
        if ($isNearEnd -and [string]::IsNullOrWhiteSpace($address)) {
            # 只有標記為必要的項目會沒有位址而走到這裡；選用的那一種從來不會被加進階梯。
            Add-CheckResult -Category "延遲與封包遺失" -Check $name -Status "ERROR" -Message "近端目標標記為必要，但沒有設定位址。" -Details "設定值：（空白）。必要的近端目標必須指名這台電腦自己子網段上的一台主機；沒有位址就沒有東西可以探測，執行時會照實說，而不是讓一項沒做的檢查通過。" -Tag $pingTag -Weightless | Out-Null
            Add-CheckResult -Category "延遲與封包遺失" -Check $name -Status "ERROR" -Message "這項必要檢查沒有執行，因為沒有給它目標。" -Details "設定值：（空白）" -Tag $pingTag | Out-Null
            continue
        }
        $usable = $(if ($isNearEnd) { Test-NearEndAddressSyntax $address } else { Test-PingTargetSyntax $address })
        if (-not $usable) {
            if ($isNearEnd) {
                Add-CheckResult -Category "延遲與封包遺失" -Check $name -Status "ERROR" -Message "設定的近端目標無法使用：它必須是點分十進位形式的 IPv4 位址。" -Details ("設定值：{0}。近端目標是這台電腦所在子網段上、且不是閘道的一個 IPv4 位址，以四個十進位數字加點給定——不是單一個數字、不是十六進位、也不帶前導零，因為不同的解析器會把那些形式讀成不同的位址——而且以位址而不是名稱給定，因為檢查必須在送出任何東西之前就知道它在本地子網段上，而名稱會讓近端這一階落在解析器之後。" -f $address) -Tag $pingTag -Weightless | Out-Null
            }
            else {
                Add-CheckResult -Category "延遲與封包遺失" -Check $name -Status "ERROR" -Message "設定的位址無法當成 ping 目標。" -Details ("Configured value: $address; " + (Get-HostNameSyntaxProblem $address)) -Tag $pingTag -Weightless | Out-Null
            }
            if ($required) {
                Add-CheckResult -Category "延遲與封包遺失" -Check $name -Status "ERROR" -Message "這項必要檢查沒有執行，因為給它的目標無法檢測。" -Details ("Configured value: $address") -Tag $pingTag | Out-Null
            }
            continue
        }
        if ($isNearEnd) {
            # 在探測之前先放到位（backlog #60）：這一列的整個主張就是它的探測經過了哪些路段，所以一個其實是閘道、或
            # 位於閘道之外的目標，不可以在那個主張之下被量。閘道那一種是設定錯誤，就照設定錯誤回報；子網段之外那一
            # 種是關於這台機器此刻在哪裡的事實——帶著公司設定檔在家裡的筆電——就照事實回報：什麼都沒送、什麼都沒
            # 主張、整體結果不動。沒有探測的必要近端目標，仍然要付每一個沒有執行的必要目標都要付的那一列有權重的列。
            $placement = Test-NearEndTargetPlacement -Address $address -PrimaryAdapters $PrimaryAdapters
            if ($placement.Placement -eq "gateway" -or $placement.Placement -eq "self" -or $placement.Placement -eq "not-a-host") {
                # 三種設定錯誤，同一種形狀（第二與第三種是 PR #51 第 1 輪加的）：那一列說是哪一種，而一個會量到錯的
                # 東西的探測不會被送出。
                if ($placement.Placement -eq "self") {
                    Add-CheckResult -Category "延遲與封包遺失" -Check $name -Status "ERROR" -Message "設定的近端目標是這台電腦自己的位址之一，它不能當作近端這一階。" -Details ("設定值：{0}。送到這台電腦自己位址的 Ping 由它自己的堆疊回應，沒有經過任何網路線、無線電或交換器；近端目標必須是同一子網段上的另一台主機。" -f $address) -Tag $pingTag -Weightless | Out-Null
                }
                elseif ($placement.Placement -eq "not-a-host") {
                    Add-CheckResult -Category "延遲與封包遺失" -Check $name -Status "ERROR" -Message "設定的近端目標是這台電腦子網段的網路位址或廣播位址，不是主機。" -Details ("設定值：{0}。子網段裡全 0 與全 1 的位址不屬於任何主機；近端目標必須是同一子網段上的一台主機。" -f $address) -Tag $pingTag -Weightless | Out-Null
                }
                else {
                    Add-CheckResult -Category "延遲與封包遺失" -Check $name -Status "ERROR" -Message "設定的近端目標就是這台電腦的預設閘道，它不能當作近端這一階。" -Details ("設定值：{0}。閘道是用自己的控制平面回應 Ping 的，而且它已經是階梯的下一階；近端目標必須是同一子網段上的普通主機，本地路徑才能在沒有閘道參與的情況下被量到。" -f $address) -Tag $pingTag -Weightless | Out-Null
                }
                if ($required) {
                    Add-CheckResult -Category "延遲與封包遺失" -Check $name -Status "ERROR" -Message "這項必要檢查沒有執行，因為給它的目標無法檢測。" -Details ("Configured value: $address") -Tag $pingTag | Out-Null
                }
                continue
            }
            if ($placement.Placement -ne "on-subnet") {
                $subnetText = "無已知子網段"
                if (@($placement.Subnets).Count -gt 0) { $subnetText = (@($placement.Subnets) -join ", ") }
                Add-CheckResult -Category "延遲與封包遺失" -Check $name -Status "INFO" -Message "設定的近端目標不在這台電腦所在的任何子網段上，因此沒有探測。" -Details ("設定值：{0}。這台電腦的 IPv4 子網段：{1}。經過閘道才到得了的主機不是近端這一階，所以沒有送出任何東西；這一列沒有說明任何網路狀況，也不改變整體結果。" -f $address, $subnetText) -Tag $pingTag -Weightless | Out-Null
                if ($required) {
                    Add-CheckResult -Category "延遲與封包遺失" -Check $name -Status "ERROR" -Message "這項必要檢查沒有執行，因為給它的目標不在這台電腦的網路上。" -Details ("設定值：{0}。這台電腦的 IPv4 子網段：{1}。" -f $address, $subnetText) -Tag $pingTag | Out-Null
                }
                continue
            }
        }
        $rungSubnets = @()
        if ($isNearEnd) { $rungSubnets = @([string]$placement.Subnet) }
        $targets = @(Resolve-PingTargets -Address $address -PrimaryAdapters $PrimaryAdapters)

        if ($targets.Count -eq 0) {
            $status = if ($required) { "FAIL" } else { "WARN" }
            $noTargetDetail = "設定值：$address"
            if ($address -eq "AUTO_GATEWAY") {
                $noTargetDetail = "設定值：AUTO_GATEWAY——此為佔位符，執行時解析為目前的 IPv4 預設閘道；目前不存在（通常代表本地連線中斷）。"
            }
            Add-CheckResult -Category "延遲與封包遺失" -Check $name -Status $status -Message "找不到可測試的目標。" -Details ($noTargetDetail + [Environment]::NewLine + ("檢測方式：.NET Ping — 先送 {0} 次 ICMP echo，若有回覆遺失最多加到 {1} 次，逾時 {2} ms。" -f $count, $maximum, $timeout) + [Environment]::NewLine + "手動驗證：ping -n $count <目標 IP>") -Tag $pingTag | Out-Null
            continue
        }

        foreach ($target in $targets) {
            try {
                # Only an address can be asked of the route table, so a target given as a name is looked up by the
                # address its replies came from, after the probes - and where nothing replied there is no address at
                # all, which the row says instead of naming a route nobody took (PR #45, round 1).
                $parsedTarget = $null
                $targetIsAddress = [System.Net.IPAddress]::TryParse([string]$target, [ref]$parsedTarget)
                $targetRungSubnets = @($rungSubnets)
                if ($address -eq "AUTO_GATEWAY") {
                    foreach ($adapter in @($PrimaryAdapters)) {
                        if (@($adapter.Gateways) -contains [string]$target) {
                            foreach ($entry in @($adapter.IPv4WithPrefix)) { if (([string]$entry) -match '/\d+$') { $targetRungSubnets += [string]$entry } }
                        }
                    }
                }
                $routeBefore = $null
                if ($targetIsAddress) { $routeBefore = Get-RouteSelection -Target ([string]$target) }
                $measurement = Invoke-PingMeasurement -Target ([string]$target) -Count $count -TimeoutMs $timeout
                $plan = Get-PingExtensionPlan -Sent $measurement.Sent -Received $measurement.Received -MaximumCount $maximum -WarningPercent $warningLoss
                $routeAfter = Get-PingRouteAfter -Target ([string]$target) -TargetIsAddress $targetIsAddress -Measurement $measurement
                if ($plan.Extend) {
                    # 先擱著而不是在這裡送完（backlog #51）：這個目標剩下的探測會在執行後段送出，分散在它本來
                    # 就欠重傳視窗的那些秒數裡，讓多出來的取樣橫跨整次執行，而不是擠在同一個不到一秒的瞬間。
                    # 不過這一列照樣在這裡就寫出來，內容是第一輪量到的結果，等取樣完成之後再改寫。這樣它才會跟
                    # 其他 ping 的列待在一起——而且一次沒能走到最後的執行，仍然會報出它確實量到的東西，這是把
                    # 整列壓到最後才寫所做不到的。
                    $pendingNote = ("這次取樣還不足以下結論：最前面 {1} 次裡有 {0} 次沒有回覆，因此會在本次執行的後段繼續，而這裡的數字只涵蓋那 {1} 次。" -f $measurement.Lost, $measurement.Sent)
                    $pendingRow = Add-PingTargetResult -Name $name -Target ([string]$target) -ConfiguredAddress $address -Required $required -Measurement $measurement -RouteBefore $routeBefore -RouteAfter $routeAfter -TargetIsAddress $targetIsAddress -TimeoutMs $timeout -SampleNote $pendingNote -NearEnd $isNearEnd -RungSubnets $targetRungSubnets
                    [void]$script:PendingPingSamples.Add([pscustomobject][ordered]@{
                        Name            = $name
                        Target          = [string]$target
                        Address         = $address
                        Required        = $required
                        RouteBefore     = $routeBefore
                        TargetIsAddress = $targetIsAddress
                        Measurement     = $measurement
                        Plan            = $plan
                        Row             = $pendingRow
                        NearEnd         = $isNearEnd
                        RungSubnets     = $targetRungSubnets
                    })
                    continue
                }
                Add-PingTargetResult -Name $name -Target ([string]$target) -ConfiguredAddress $address -Required $required -Measurement $measurement -RouteBefore $routeBefore -RouteAfter $routeAfter -TargetIsAddress $targetIsAddress -TimeoutMs $timeout -NearEnd $isNearEnd -RungSubnets $targetRungSubnets | Out-Null
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
        throw (New-Object System.TimeoutException "DNS 查詢逾時（超過 $TimeoutMs ms）。")
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
            $hostName = ([string]$dnsConfig).Trim()
            $required = $true
        }
        else {
            $name = ConvertTo-SafeString (Get-PropertyValue $dnsConfig "Name" "DNS 名稱解析")
            $hostName = (ConvertTo-SafeString (Get-PropertyValue $dnsConfig "Host" "")).Trim()
            $required = [bool](Get-PropertyValue $dnsConfig "Required" $true)
        }

        if ([string]::IsNullOrWhiteSpace($hostName)) {
        # 與 TCP、HTTP 目標同一種切法（backlog #39）：空白的主機名稱是關於本次執行輸入的事實，會在結果本該出現的
        # 地方留下一列——1.2.8 之前，空白的 DNS 名稱不論必要與否都什麼都不寫，讀者在那個區段看不到任何痕跡，儘管
        # 有人設定過這項檢查。必要目標再加上那列「量測沒有發生」的有權重列。
            Add-CheckResult -Category "DNS" -Check $name -Status "ERROR" -Message "設定的主機名稱是空白的。" -Details "" -Tag "dns" -Weightless | Out-Null
            if ($required) {
                Add-CheckResult -Category "DNS" -Check $name -Status "ERROR" -Message "這項必要檢查沒有執行，因為給它的目標無法檢測。" -Details "" -Tag "dns" | Out-Null
            }
            continue
        }
        if (-not (Test-HostNameSyntax $hostName)) {
        # 根本問不出去的名稱，跟空白名稱一樣是關於本次執行輸入的事實；而在這一輪之前它是相反的：
        # 查詢擲回例外，下方的 catch 把例外變成有權重的 FAIL，一個錯字就成了「發現問題」
        # （PR #41，第 6 輪）。
            Add-CheckResult -Category "DNS" -Check $name -Status "ERROR" -Message "設定的主機名稱無法當成 DNS 目標。" -Details ("設定值：$hostName；" + (Get-HostNameSyntaxProblem $hostName)) -Tag "dns" -Weightless | Out-Null
            if ($required) {
                Add-CheckResult -Category "DNS" -Check $name -Status "ERROR" -Message "這項必要檢查沒有執行，因為給它的目標無法檢測。" -Details "" -Tag "dns" | Out-Null
            }
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
            throw (New-Object System.TimeoutException "TCP 連線逾時（超過 $TimeoutMs ms）。")
        }
        $client.EndConnect($asyncResult)
        $stopwatch.Stop()

        # backlog #52：socket 實際使用的兩個位址，在 finally 關閉它之前讀取。遠端位址是後續連線要去的地方——連到第一次
        # 到達的位址，不再經過解析器——本機位址則說明交握是從哪一張網卡的位址送出的。兩者都不是量測，所以讀取失敗只留下
        # 空字串，連線仍算成功。
        $remoteAddress = ""
        $localAddress = ""
        try {
            if ($null -ne $client.Client.RemoteEndPoint) { $remoteAddress = [string]$client.Client.RemoteEndPoint.Address }
            if ($null -ne $client.Client.LocalEndPoint) { $localAddress = [string]$client.Client.LocalEndPoint.Address }
        }
        catch {}
        # backlog #52、PR #53 第 1 輪：socket 自己對這次交握的交代，在 finally 關閉它之前讀取。SIO_TCP_INFO（0xD8000027，
        # 即下面那個 Int32）填入一個 TCP_INFO_v0——88 個位元組，SynRetrans 是位移 84 的 UCHAR，RttUs 是位移 20 的 ULONG，
        # 這是 mstcpip.h 參考文件記載、也是這台機器回傳的配置（2026-09-12 讀取）——只針對發問的那個 socket、不需提權，
        # Windows 10 1703 版與 Windows Server 2016 起支援。沒有它的版本、或拒絕的 socket，留下 -1 與原因，該列改拿各次
        # 時間和重傳逾時比較，並寫明。
        $synRetrans = -1
        $rttUs = -1
        $telemetryError = ""
        try {
            $infoOut = New-Object byte[] 128
            $infoBytes = $client.Client.IOControl([int]-671088601, [System.BitConverter]::GetBytes([uint32]0), $infoOut)
            if ($infoBytes -ge 88) {
                $synRetrans = [int]$infoOut[84]
                $rttUs = [int][System.BitConverter]::ToUInt32($infoOut, 20)
            }
            else {
                $telemetryError = ("SIO_TCP_INFO 回傳 {0} 個位元組" -f $infoBytes)
            }
        }
        catch {
            $telemetryError = [string]$_.Exception.Message
        }

        return [pscustomobject][ordered]@{
            Success        = $true
            Host           = $HostName
            Port           = $Port
            ElapsedMs      = [math]::Round($stopwatch.Elapsed.TotalMilliseconds, 0)
            Error          = ""
            RemoteAddress  = $remoteAddress
            LocalAddress   = $localAddress
            SynRetrans     = $synRetrans
            RttUs          = $rttUs
            TelemetryError = $telemetryError
        }
    }
    catch {
        $stopwatch.Stop()
        return [pscustomobject][ordered]@{
            Success       = $false
            Host          = $HostName
            Port          = $Port
            ElapsedMs     = [math]::Round($stopwatch.Elapsed.TotalMilliseconds, 0)
            Error         = (Add-NetworkErrorCause $_.Exception $_.Exception.Message)
            RemoteAddress  = ""
            LocalAddress   = ""
            SynRetrans     = -1
            RttUs          = -1
            TelemetryError = ""
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

function Get-TcpInitialRto {
    # backlog #52：連線時間拿來比較的逾時值是作業系統自己的，不是這支工具的門檻。Set-NetTCPSetting 把 InitialRtoMs 記載為
    # 「connect（即 SYN）重送之前的時間（毫秒）」（300 到 3000 ms，以 10 為級距；2026-09-12 讀取），所以一次交握若至少持續
    # 這麼久，就代表那個計時器到期過。向 Internet 範本詢問——Windows 出廠兩個範本之一。參考機的 Windows 11 版本，物件上根本
    # 沒有 InitialRtoMs 這個屬性，而 netsh int tcp show global 回報一個全域值 1000——Windows 未另行設定時採用的值——所以
    # cmdlet 沒回報時就假設 1000 ms，而那一列會寫明拿到的是哪一種。
    $rto = [pscustomobject][ordered]@{
        Ms     = 1000
        Source = "default"
    }
    try {
        $setting = @(Get-NetTCPSetting -SettingName "Internet" -ErrorAction Stop)
        $value = 0
        if ($setting.Count -gt 0) { $value = ConvertTo-IntSafe (Get-PropertyValue $setting[0] "InitialRtoMs" $null) 0 }
        if ($value -gt 0) {
            $rto.Ms = $value
            $rto.Source = "setting"
        }
    }
    catch {}
    return $rto
}

function New-TcpConnectSample {
    param(
        [object]$First,
        [object[]]$Repeats,
        [int]$Planned,
        [bool]$HostIsName,
        [object]$InitialRto
    )

    # backlog #52：這次執行對單一目標量到的東西，在這裡計數，讓文字成為這個物件的函數，也讓 unit test 能拿同一套計數規則
    # 檢驗兩支腳本。第一次連線是這一列狀態所依據的那一次；後續連線依序跟在後面，在第一次失敗處結束，因為做這些連線的
    # 迴圈就停在那裡——停止回應的目標多花的是一次逾時，不是 PingCount 次。
    $results = @(@(@($First) + @($Repeats)) | Where-Object { $null -ne $_ })
    $times = New-Object System.Collections.ArrayList
    $synCounts = New-Object System.Collections.ArrayList
    $rtts = New-Object System.Collections.ArrayList
    $telemetryError = ""
    $failedIndex = 0
    $failedError = ""
    for ($i = 0; $i -lt $results.Count; $i++) {
        if ($results[$i].Success) {
            [void]$times.Add([int](ConvertTo-IntSafe $results[$i].ElapsedMs 0))
            $synCount = [int](ConvertTo-IntSafe (Get-PropertyValue $results[$i] "SynRetrans" -1) -1)
            [void]$synCounts.Add($synCount)
            [void]$rtts.Add([int](ConvertTo-IntSafe (Get-PropertyValue $results[$i] "RttUs" -1) -1))
            if ($synCount -lt 0 -and $telemetryError -eq "") { $telemetryError = [string](Get-PropertyValue $results[$i] "TelemetryError" "") }
        }
        elseif ($failedIndex -eq 0) {
            $failedIndex = $i + 1
            $failedError = [string]$results[$i].Error
        }
    }
    # 每一次完成的連線都問得到 socket 時，重傳數字就是 socket 自己的（PR #53 第 1 輪）：各次的 SynRetrans 加總。只要有一次
    # 問不到——比 Windows 10 1703 舊的版本、拒絕的 socket——樣本就寫明，改拿各次時間和逾時比較，當作它本來就是的代理指標。
    $telemetryComplete = ($synCounts.Count -gt 0) -and (@($synCounts | Where-Object { $_ -lt 0 }).Count -eq 0)
    $retransmittedSyns = 0
    foreach ($synCount in $synCounts) { if ($synCount -gt 0) { $retransmittedSyns += $synCount } }
    # 代理指標的規則：以名稱給定的目標，第一次連線的計時裡含名稱查詢——TcpClient 先解析名稱再送 SYN——所以那個時間會列出，
    # 但不拿來和逾時比較；後續連線連的是第一次到達的位址，會拿來比較。以位址給定的目標，第一次連線和其他各次一樣比較。
    # 有 socket 自己的計數時這些都不重要，因為計數不是時間。
    $judged = @($times)
    if ($HostIsName -and $judged.Count -gt 0) { $judged = @($judged | Select-Object -Skip 1) }
    $rtoMs = [math]::Max(1, (ConvertTo-IntSafe (Get-PropertyValue $InitialRto "Ms" 1000) 1000))
    $atOrAbove = @($judged | Where-Object { $_ -ge $rtoMs })

    return [pscustomobject][ordered]@{
        Planned           = [math]::Max(1, $Planned)
        Attempted         = $results.Count
        Times             = @($times)
        SynRetrans        = @($synCounts)
        RttUs             = @($rtts)
        TelemetryComplete = [bool]$telemetryComplete
        TelemetryError    = $telemetryError
        RetransmittedSyns = $retransmittedSyns
        Judged            = $judged.Count
        AtOrAbove         = @($atOrAbove)
        RtoMs             = $rtoMs
        RtoSource         = [string](Get-PropertyValue $InitialRto "Source" "default")
        RemoteAddress     = [string](Get-PropertyValue $First "RemoteAddress" "")
        LocalAddress      = [string](Get-PropertyValue $First "LocalAddress" "")
        HostIsName        = [bool]$HostIsName
        FailedIndex       = $failedIndex
        FailedError       = $failedError
    }
}

function Get-TcpConnectSampleText {
    param(
        [object]$Sample,
        [string]$HostName,
        [int]$Port
    )

    # backlog #52：訊息帶著各次時間與重傳數字——讀得到時是 socket 自己的計數，否則是被比較的連線裡有幾次達到逾時，並標明
    # 那是代理指標——讀者一眼該看到的那一個數字；規則、逾時值的出處與位址則放在詳細資料。這裡不決定任何事：這一列的狀態
    # 在這段文字存在之前，就已由第一次連線決定。
    $target = "{0}:{1}" -f $HostName, $Port
    $timesText = (@($Sample.Times) | ForEach-Object { [string]$_ }) -join " / "
    $synText = (@($Sample.SynRetrans) | ForEach-Object { [string]$_ }) -join " / "
    $rttText = (@($Sample.RttUs) | ForEach-Object { [string]([math]::Round($_ / 1000.0, 1)) }) -join " / "
    $telemetry = [bool]$Sample.TelemetryComplete
    $retransmitted = [int]$Sample.RetransmittedSyns
    $timed = @($Sample.Times).Count
    $reached = @($Sample.AtOrAbove).Count
    $judged = [int]$Sample.Judged
    $attempted = [int]$Sample.Attempted
    $planned = [int]$Sample.Planned
    $rtoMs = [int]$Sample.RtoMs
    $failedIndex = [int]$Sample.FailedIndex
    $rtoText = ("{0} ms" -f $rtoMs)
    if ([string]$Sample.RtoSource -ne "setting") { $rtoText = ("{0} ms (assumed)" -f $rtoMs) }
    $telemetryError = [string]$Sample.TelemetryError
    if ($telemetryError -eq "") { $telemetryError = "沒有錯誤文字" }

    $lead = ("{0} 次連線計時：{1} ms" -f $timed, $timesText)
    if ($failedIndex -gt 0) {
        $lead = ("計畫 {0} 次連線，完成計時 {1} 次，第 {2} 次失敗、其餘未再嘗試：{3} ms" -f $planned, $timed, $failedIndex, $timesText)
    }
    $message = ""
    if ($telemetry -and $retransmitted -eq 0) {
        $message = $lead + ("；各次 SYN 重傳 {0}，由各個 socket 自己計數。" -f $synText)
    }
    elseif ($telemetry) {
        $message = $lead + ("；各次 SYN 重傳 {0}，由各個 socket 自己計數：共 {1} 個 SYN 曾被重送。" -f $synText, $retransmitted)
    }
    elseif ($judged -eq 0) {
        $message = $lead + ("；socket 自己的重傳計數器讀不到，而名稱目標的第一次連線含名稱查詢，因此沒有東西拿來和重傳逾時 {0} 比較。" -f $rtoText)
    }
    elseif ($reached -eq 0) {
        $message = $lead + ("；socket 自己的重傳計數器讀不到，改以時間代替：{1} 次中有 {0} 次達到重傳逾時 {2}——這是 SYN 重傳的代理指標，不是計數。" -f $reached, $judged, $rtoText)
    }
    else {
        $message = $lead + ("；socket 自己的重傳計數器讀不到，改以時間代替：{1} 次中有 {0} 次達到重傳逾時 {2}——那是重傳的 SYN 可能出現的地方——這是 SYN 重傳的代理指標，不是計數。" -f $reached, $judged, $rtoText)
    }

    $lines = New-Object System.Collections.ArrayList
    $where = ("連到 {0}" -f $target)
    if ($Sample.HostIsName -and -not [string]::IsNullOrWhiteSpace([string]$Sample.RemoteAddress)) {
        $where = ("連到 {0}（解析為 {1}）" -f $target, $Sample.RemoteAddress)
    }
    $from = ""
    if (-not [string]::IsNullOrWhiteSpace([string]$Sample.LocalAddress)) {
        $from = ("、從 {0} 送出" -f $Sample.LocalAddress)
    }
    $first = ("連線：計畫 {1} 次、實際 {0} 次，每一次都是一次新的 TCP 交握，{2}{3}；依序耗時：{4} ms。" -f $attempted, $planned, $where, $from, $timesText)
    if ($Sample.HostIsName -and $telemetry) {
        if ($attempted -gt 1) { $first += (" 第一次連線解析了名稱，耗時含那次查詢；它的 SYN 計數是 socket 自己的，和其他各次一樣採用；後面 {0} 次連到解析出的位址。" -f ($attempted - 1)) }
        else { $first += " 第一次連線解析了名稱，耗時含那次查詢；它的 SYN 計數是 socket 自己的；之後沒有再連線。" }
    }
    elseif ($Sample.HostIsName) {
        if ($attempted -gt 1) { $first += (" 第一次連線解析了名稱，耗時含那次查詢，因此不拿它和逾時比較；後面 {0} 次連到解析出的位址。" -f ($attempted - 1)) }
        else { $first += " 第一次連線解析了名稱，耗時含那次查詢，因此不拿它和逾時比較；之後沒有再連線。" }
    }
    [void]$lines.Add($first)
    if ($failedIndex -gt 0) {
        [void]$lines.Add(("第 {0} 次連線失敗，其後的連線未再嘗試：" -f $failedIndex))
        [void]$lines.Add([string]$Sample.FailedError)
    }
    if ($telemetry) { [void]$lines.Add(("各次連線的 SYN 重傳：{0}；各次連線的往返時間估計：{1} ms（TCP_INFO_v0 的 SynRetrans 與 RttUs，連線建立後經 SIO_TCP_INFO 從各個 socket 讀取）。" -f $synText, $rttText)) }
    else { [void]$lines.Add(("SYN 重傳：這台電腦的 socket 讀不到（{0}）——SIO_TCP_INFO 需要 Windows 10 1703 版或 Windows Server 2016——因此改拿各次時間和下面的初始重傳逾時比較。" -f $telemetryError)) }
    $rtoLine = ("初始重傳逾時（RTO）：{0} ms，" -f $rtoMs)
    if ([string]$Sample.RtoSource -eq "setting") { $rtoLine += "取自 Get-NetTCPSetting 回報的 Internet 範本 InitialRtoMs。" }
    else { $rtoLine += ("為假設值：這台電腦的 Get-NetTCPSetting 沒有回報數值，而 {0} ms 是 Windows 未另行設定時採用的值（netsh int tcp show global 會顯示生效中的值）。" -f $rtoMs) }
    [void]$lines.Add($rtoLine)
    if ($telemetry) { [void]$lines.Add(("判讀：{1} 次連線共有 {0} 個 SYN 曾被重送，由 socket 自己計數。這些是工具自己的連線、對這一個目標、在這一刻——正是系統級「TCP 重傳」列無法歸屬的數字——而且它們不做判定：這一列的狀態由第一次連線決定。耗時達到初始重傳逾時的連線，是重傳的 SYN 可能在時間上顯現的地方；有沒有真的重送，以 socket 的計數為準。" -f $retransmitted, $timed)) }
    elseif ($judged -eq 0) { [void]$lines.Add("判讀：什麼都沒有比較——socket 的計數器讀不到，而唯一完成的那一次連線含名稱查詢。這些是工具自己的連線、對這一個目標、在這一刻——正是系統級「TCP 重傳」列無法歸屬的數字——而且它們不做判定：這一列的狀態由第一次連線決定。") }
    else { [void]$lines.Add(("判讀：{1} 次中有 {0} 次達到或超過逾時。耗時達到初始重傳逾時的連線，是重傳的 SYN 會顯現的地方，但這段時間也包含 SYN 之前與回覆之後所發生的事，所以它是重傳的代理指標，不是計數；而低於它的連線，只有在這裡讀到的逾時值正是該連線所用的那一個時，才排除得了重傳——這一點本工具無法確認：連線套用哪個範本沒有系統管理員權限讀不到，而假設值只是假設。這些是工具自己的連線、對這一個目標、在這一刻——正是系統級「TCP 重傳」列無法歸屬的數字——而且它們不做判定：這一列的狀態由第一次連線決定。" -f $reached, $judged)) }

    return [pscustomobject][ordered]@{
        Message = $message
        Lines   = @($lines)
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
    # backlog #52：PingCount 也是「有回應的 TCP 目標」會被連線的次數——決定這一列的那一次，加上再連 PingCount - 1 次到它
    # 到達的位址、逐次計時——讓這次執行握有一個歸屬得了的重傳數字：自己的 SYN、對單一具名目標、在這一刻。系統級計數器
    # 的列保留，並寫明它們是什麼。比較用的逾時值只讀一次，而且只在某次連線成功之後才讀，所以 TCP 目標全數失敗的執行
    # 不為它付出任何代價。
    $connectCount = [math]::Max(1, (ConvertTo-IntSafe $script:Config.Tests.PingCount 4))
    $initialRto = $null

    foreach ($target in @($script:Config.Tests.TcpTargets)) {
        if ($null -eq $target) { continue }

        $name = ConvertTo-SafeString (Get-PropertyValue $target "Name" "TCP 連線")
        $hostName = (ConvertTo-SafeString (Get-PropertyValue $target "Host" "")).Trim()
        $port = ConvertTo-IntSafe (Get-PropertyValue $target "Port" 0) 0
        $required = [bool](Get-PropertyValue $target "Required" $false)
        $group = ConvertTo-SafeString (Get-PropertyValue $target "Group" "")

        if (-not (Test-HostNameSyntax $hostName) -or $port -lt 1 -or $port -gt 65535) {
            # 兩列，因為一列會同時承載兩個主張（backlog #39）：這個值設定錯了——規則說它不能左右判定；以及，當
            # 該目標是必要的，本來該發生的量測沒有發生——那必須保有權重。提示列在結果本該出現的區段寫出輸入的原
            # 值，讓沒被檢測的選用目標看得見、而不是整段消失；第二列則是避免「必要檢查從未執行，卻顯示整體正常」。
            Add-CheckResult -Category "TCP 連線" -Check $name -Status "ERROR" -Message "設定的主機或連接埠無效。" -Details ("Host=$hostName, Port=$port" + $(if (-not (Test-HostNameSyntax $hostName)) { "；主機：" + (Get-HostNameSyntaxProblem $hostName) } else { "" })) -Tag "tcp" -Weightless | Out-Null
            if ($required) {
                Add-CheckResult -Category "TCP 連線" -Check $name -Status "ERROR" -Message "這項必要檢查沒有執行，因為給它的目標無法檢測。" -Details ("Host=$hostName, Port=$port") -Tag "tcp" | Out-Null
            }
            continue
        }

        $result = Invoke-TcpConnectionTest -HostName $hostName -Port $port -TimeoutMs $tcpTimeout
        if ($result.Success) {
            # backlog #52：跟在決定這一列那一次之後的連線。它們連到第一次連線到達的位址，所以名稱只解析一次，各次時間
            # 就純粹是交握；並且在第一次失敗處停止，所以停止回應的目標多花的是一次逾時，不是 PingCount 次。
            if ($null -eq $initialRto) { $initialRto = Get-TcpInitialRto }
            $repeatHost = $hostName
            if (-not [string]::IsNullOrWhiteSpace([string]$result.RemoteAddress)) { $repeatHost = [string]$result.RemoteAddress }
            $repeats = @()
            for ($i = 2; $i -le $connectCount; $i++) {
                $repeat = Invoke-TcpConnectionTest -HostName $repeatHost -Port $port -TimeoutMs $tcpTimeout
                $repeats += $repeat
                if (-not $repeat.Success) { break }
            }
            # 第一次連線是否含名稱查詢，照 framework 自己的判斷方式決定：TcpClient 把字串交給 Dns，其解析輔助函數先用
            # IPAddress.TryParse 解析，解析得出的值不查詢任何東西（.NET Framework 參考原始碼的 Dns.HostResolutionBeginHelper，
            # 2026-09-12 讀取），所以這裡用同一個測試就能說出解析器有沒有被問過。
            $parsedAddress = $null
            $hostIsName = -not [System.Net.IPAddress]::TryParse($hostName, [ref]$parsedAddress)
            $sample = New-TcpConnectSample -First $result -Repeats $repeats -Planned $connectCount -HostIsName $hostIsName -InitialRto $initialRto
            $sampleText = Get-TcpConnectSampleText -Sample $sample -HostName $hostName -Port $port
            $script:TcpConnectSampleCount++
            Add-CheckResult -Category "TCP 連線" -Check $name -Status "PASS" -Message (("可連線至 {0}:{1}，耗時 {2} ms。" -f $hostName, $port, $result.ElapsedMs) + " " + $sampleText.Message) -Details ((@($sampleText.Lines) + @($tcpMethod, "手動驗證：Test-NetConnection $hostName -Port $port")) -join [Environment]::NewLine) -Tag "tcp" | Out-Null
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

        if (-not (Test-HttpTargetSyntax $url)) {
            # 空白從來不是 URL 唯一不能用的方式：「example.com」沒有 scheme，「ftp://host」的 scheme 這個工具不會
            # 講。兩者都在這裡決定，在送出任何東西之前，這樣「沒讓任何封包離開過的值」就不會被記成一次量到的連線
            # 失敗（PR #41 第 1 輪）。
            $urlDetail = "設定值：$url" + (Get-UrlHostProblemSuffix $url)
            Add-CheckResult -Category "HTTP/HTTPS" -Check $name -Status "ERROR" -Message "設定的 URL 無法使用：必須是絕對的 http:// 或 https:// 位址。" -Details $urlDetail -Tag "http" -Weightless | Out-Null
            if ($required) {
                Add-CheckResult -Category "HTTP/HTTPS" -Check $name -Status "ERROR" -Message "這項必要檢查沒有執行，因為給它的目標無法檢測。" -Details $urlDetail -Tag "http" | Out-Null
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
            Add-CheckResult -Category "網卡錯誤計數" -Check $name -Status $resetStatus -Message "網卡計數器在檢測期間重設，可能曾重新連線或重啟；無法可靠計算增量。" -Details $resetDetails -Tag "adapter-errors" -Weightless | Out-Null
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
    # An interface block begins two lines above its GUID (the name and the description come first). The GUID line is
    # found by its LABEL - GUID, which netsh does not translate, like SSID - rather than by the shape of its value
    # (backlog #61's other half; PR #52 rounds 11 and 12 met the same exposure in the test chain's reader): a network
    # or a profile named like a UUID, or an adapter renamed to one, is printed inside the block, and by shape each of
    # them would have started an interface of its own. The shape rule stays as the fallback for an output that carries
    # no GUID label at all, so that a build this parser has never seen still yields its interfaces.
    $starts = @()
    for ($i = 0; $i -lt $pairs.Count; $i++) {
        if ($pairs[$i].Label.ToUpperInvariant() -eq 'GUID' -and $pairs[$i].Value -match $guidPattern -and $i -ge 2) { $starts += ($i - 2) }
    }
    if ($starts.Count -eq 0) {
        for ($i = 0; $i -lt $pairs.Count; $i++) {
            if ($pairs[$i].Value -match $guidPattern -and $i -ge 2) { $starts += ($i - 2) }
        }
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
        # The BSSID by its LABEL first (PR #54, round 3): netsh does not translate the acronym - the label is BSSID on Windows
        # 10 and AP BSSID on Windows 11 - and a network named like a MAC address would otherwise be the block's second MAC-shaped
        # value and be stored as the access point, with the connection state as the network's name. The second-MAC rule stays
        # as the fallback for an output without the label; the SSID is read from its own label the same way, else from the
        # line before the BSSID, which is where both layouts print it.
        $bssidIndex = -1
        for ($k = 0; $k -lt $block.Count; $k++) {
            if ($block[$k].Label -match '(^|\s)BSSID$' -and $block[$k].Value -match $macPattern) { $bssidIndex = $k; break }
        }
        if ($bssidIndex -lt 0) {
            for ($k = 0; $k -lt $block.Count; $k++) {
                if ($block[$k].Value -match $macPattern -and $macs.Count -ge 2 -and $block[$k].Value -eq $macs[1].Value) { $bssidIndex = $k; break }
            }
        }
        $ssid = ""
        $ssidLine = @($block | Where-Object { $_.Label -match '^SSID$' } | Select-Object -First 1)
        if ($ssidLine.Count -gt 0) { $ssid = $ssidLine[0].Value }
        elseif ($bssidIndex -gt 0) { $ssid = $block[$bssidIndex - 1].Value }
        # The interface's own GUID, kept lower-case: it is what the association rows are keyed and named by.
        $guid = ""
        if ($block.Count -ge 3 -and $block[2].Value -match $guidPattern) { $guid = $block[2].Value.ToLowerInvariant() }

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
            Guid             = $guid
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

function Get-WifiAssociationSample {
    param([string]$Moment)

    # netsh wlan show interfaces 的一次讀取，留作「執行到這一刻、每張無線介面連在哪個存取點」的樣本（backlog #61 的另一半）：
    # BSSID 是存取點自己的位址，同一個網路名稱下 BSSID 改變就是漫遊，而漫遊正是那種能解釋「訊號好、數字卻差」的空中
    # 事件。不論內容為何都回傳整個信封，和重傳快照、TCP 快照一樣；由分析函式把列寫出來，證據附在旁邊。-Moment 記下
    # 這個樣本取自執行的哪一刻——start、middle、end——讓列能說出來。
    # netsh 讀取旁邊，另外讀 WLAN 服務自己對介面的說法（backlog #62）：有哪些介面、各自是否已連線，走 Native Wifi API，
    # 因為 netsh 的文字不是狀態本身。桌面應用程式不被允許存取位置時——Windows 11 24H2 及之後，設定 > 隱私權與安全性 >
    # 位置——netsh 一個介面都不印、以 1 結束（2026-09-12 在參考機器量到），而沒有介面的輸出過去會被讀成沒有無線電的電腦。
    # 結束碼與各行也留下來，理由相同：那時 netsh 印的是一段機器語言的句子，不該要求任何解析器去讀它。
    $sample = [pscustomobject][ordered]@{
        Moment        = $Moment
        Timestamp     = Get-Date
        Interfaces    = @()
        Error         = ""
        ErrorText     = ""
        Diagnostics   = ""
        NetshExitCode = -1
        NetshLines    = @()
        Api           = $null
    }
    $netsh = Join-Path $env:SystemRoot "System32\netsh.exe"
    if (-not (Test-Path -LiteralPath $netsh)) {
        $sample.Error = "netsh"
        $sample.ErrorText = "找不到 netsh.exe。"
    }
    else {
        try {
            $lines = @(& $netsh wlan show interfaces 2>&1 | ForEach-Object { [string]$_ })
            $sample.NetshExitCode = ConvertTo-IntSafe $LASTEXITCODE 0
            $sample.NetshLines = @($lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })
            $sample.Interfaces = @(ConvertFrom-NetshWlanOutput -Lines $lines)
        }
        catch {
            $sample.Error = "exception"
            $sample.ErrorText = Get-ExceptionDetails $_
            $sample.Diagnostics = Get-ExceptionDiagnostics $_
        }
    }
    $sample.Api = Get-WlanInterfaceStates
    return $sample
}

function Add-WifiAssociationSample {
    param([string]$Moment)

    # 取一個樣本，依取樣順序和本次執行的其他樣本放在一起。清單在這裡也會建立，不只在一次執行開始時建立，
    # 讓 Run-AllChecks 之外的呼叫者——測試環境裡的無線訊號列——永遠不會寫進一個不存在的清單。
    if ($null -eq $script:WifiAssociationSamples) { $script:WifiAssociationSamples = New-Object System.Collections.ArrayList }
    $sample = Get-WifiAssociationSample -Moment $Moment
    [void]$script:WifiAssociationSamples.Add($sample)
    return $sample
}

function Get-WifiInterfaceView {
    param([object]$Sample)

    # 一次樣本裡，兩個讀取來源任一方列出的每張無線介面各一筆（backlog #62），以兩者都會印的 GUID 為鍵，讓各列讀的是同一份
    # 清單：netsh 有印出的介面用 netsh 的欄位；WLAN 服務有列出的介面帶服務給的狀態、頻道與無線電開關；Connected 由服務
    # 決定（服務有回答時）——狀態本來就是服務知道的事，netsh 印的只是一個翻譯過的詞——服務問不到時才由 netsh 自己的
    # 欄位決定，每一筆都寫明是哪一個（ConnectedSource：wlanapi 或 netsh）。服務有列、netsh 沒印的介面就是這個項目講的
    # 情況（NetshListed 為 false）：netsh 對它什麼都沒印，若不是整段輸出被拒——結束碼非零，且服務對連線查詢回錯誤 5，
    # 也就是桌面應用程式的位置設定（Refused）——就是樣本只能如實記錄的原因（NetshFailed：結束碼非零、找不到執行檔、
    # 讀取時擲出例外）。沒有服務讀數的樣本——舊的形狀，以及測試夾具——就當作只有 netsh。
    if ($null -eq $Sample) { return @() }
    $views = @()
    $api = Get-PropertyValue $Sample "Api" $null
    $apiInterfaces = @()
    if ($null -ne $api -and [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $api "Error" ""))) { $apiInterfaces = @(Get-PropertyValue $api "Interfaces" @()) }
    $exitCode = ConvertTo-IntSafe (Get-PropertyValue $Sample "NetshExitCode" 0) 0
    $netshFailed = (-not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $Sample "Error" ""))) -or ($exitCode -ne 0)
    $consent = $null
    if ($null -ne $api) { $consent = Get-PropertyValue $api "LocationConsent" $null }
    $locationDenied = ($null -ne $consent -and [bool](Get-PropertyValue $consent "Denied" $false) -and [bool](Get-PropertyValue $consent "Gated" $false))
    $seen = @{}
    foreach ($wifi in @(Get-PropertyValue $Sample "Interfaces" @())) {
        if ($null -eq $wifi) { continue }
        $guid = ([string](Get-PropertyValue $wifi "Guid" "")).ToLowerInvariant()
        $key = $guid
        if ([string]::IsNullOrWhiteSpace($key)) { $key = "mac:" + ([string](Get-PropertyValue $wifi "PhysicalAddress" "")).ToLowerInvariant() }
        $entry = $null
        if (-not [string]::IsNullOrWhiteSpace($guid)) {
            $found = @($apiInterfaces | Where-Object { ([string]$_.Guid).ToLowerInvariant() -eq $guid } | Select-Object -First 1)
            if ($found.Count -gt 0) { $entry = $found[0] }
        }
        $state = $null
        if ($null -ne $entry) { $state = ConvertTo-IntSafe $entry.State -1 }
        $channel = Get-PropertyValue $wifi "Channel" $null
        if ($null -eq $channel -and $null -ne $entry) { $channel = $entry.Channel }
        $views += [pscustomobject][ordered]@{
            Key              = $key
            Guid             = $guid
            Name             = [string](Get-PropertyValue $wifi "Name" "")
            Description      = [string](Get-PropertyValue $wifi "Description" "")
            PhysicalAddress  = [string](Get-PropertyValue $wifi "PhysicalAddress" "")
            Connected        = $(if ($null -ne $state) { ($state -eq 1) } else { [bool](Get-PropertyValue $wifi "Connected" $false) })
            ConnectedSource  = $(if ($null -ne $state) { "wlanapi" } else { "netsh" })
            State            = $state
            Ssid             = [string](Get-PropertyValue $wifi "Ssid" "")
            Bssid            = [string](Get-PropertyValue $wifi "Bssid" "")
            RadioType        = [string](Get-PropertyValue $wifi "RadioType" "")
            Band             = [string](Get-PropertyValue $wifi "Band" "")
            Channel          = $channel
            ReceiveRateMbps  = Get-PropertyValue $wifi "ReceiveRateMbps" $null
            TransmitRateMbps = Get-PropertyValue $wifi "TransmitRateMbps" $null
            SignalPercent    = Get-PropertyValue $wifi "SignalPercent" $null
            Rssi             = Get-PropertyValue $wifi "Rssi" $null
            Profile          = [string](Get-PropertyValue $wifi "Profile" "")
            RadioSoftware    = $(if ($null -ne $entry) { [string]$entry.RadioSoftware } else { "" })
            RadioHardware    = $(if ($null -ne $entry) { [string]$entry.RadioHardware } else { "" })
            ConnectionQuery  = $(if ($null -ne $entry) { ConvertTo-IntSafe $entry.ConnectionQuery -1 } else { -1 })
            NetshListed      = $true
            ApiListed        = ($null -ne $entry)
            NetshFailed      = $netshFailed
            AccessDenied     = $false
            Refused          = $false
        }
        $seen[$key] = $true
    }
    foreach ($entry in $apiInterfaces) {
        if ($null -eq $entry) { continue }
        $guid = ([string]$entry.Guid).ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($guid) -or $seen.ContainsKey($guid)) { continue }
        $state = ConvertTo-IntSafe $entry.State -1
        $query = ConvertTo-IntSafe $entry.ConnectionQuery -1
        $views += [pscustomobject][ordered]@{
            Key              = $guid
            Guid             = $guid
            Name             = ""
            Description      = [string]$entry.Description
            PhysicalAddress  = ""
            Connected        = ($state -eq 1)
            ConnectedSource  = "wlanapi"
            State            = $state
            Ssid             = ""
            Bssid            = ""
            RadioType        = ""
            Band             = ""
            Channel          = $entry.Channel
            ReceiveRateMbps  = $null
            TransmitRateMbps = $null
            SignalPercent    = $null
            Rssi             = $null
            Profile          = ""
            RadioSoftware    = [string]$entry.RadioSoftware
            RadioHardware    = [string]$entry.RadioHardware
            ConnectionQuery  = $query
            NetshListed      = $false
            ApiListed        = $true
            NetshFailed      = $netshFailed
            AccessDenied     = ($netshFailed -and $query -eq 5)
            Refused          = ($netshFailed -and $query -eq 5 -and $locationDenied)
        }
        $seen[$guid] = $true
    }
    return @($views)
}

function Get-WifiNetshReasonText {
    param([object]$Sample)

    # 一次樣本裡沒有任何 netsh 介面的原因，用一個片語說給需要說它的列（backlog #62）：找不到執行檔、讀取時擲出例外，或者——
    # 量到的那種——netsh 帶著結束碼結束、一個介面都沒印。netsh 有執行且以 0 結束時是空字串，那是普通的樣本。
    if ($null -eq $Sample) { return "" }
    $error = [string](Get-PropertyValue $Sample "Error" "")
    $exitCode = ConvertTo-IntSafe (Get-PropertyValue $Sample "NetshExitCode" 0) 0
    if ($error -eq "netsh") { return "找不到 netsh.exe" }
    if (-not [string]::IsNullOrWhiteSpace($error)) { return ("netsh wlan show interfaces 無法讀取（{0}）" -f [string](Get-PropertyValue $Sample "ErrorText" "")) }
    if ($exitCode -ne 0) { return ("netsh wlan show interfaces 以結束碼 {0} 結束，沒有印出任何介面" -f $exitCode) }
    return ""
}

function Get-WifiRadioSwitchText {
    param([object]$View)

    # WLAN 服務回報的無線電開關，寫成列裡的一個片語；沒讀到就不寫：無線電關閉是舊訊息用猜的原因之一，量得到的地方就直接說。
    if ($null -eq $View) { return "" }
    $software = [string](Get-PropertyValue $View "RadioSoftware" "")
    $hardware = [string](Get-PropertyValue $View "RadioHardware" "")
    $off = @()
    if ($software -eq "off") { $off += "軟體" }
    if ($hardware -eq "off") { $off += "硬體開關" }
    if ($off.Count -gt 0) { return ("無線電關閉（{0}）" -f ($off -join "與")) }
    # 兩個開關都確定是開才寫開啟（PR #55，第 9 回合）：一個開、另一個未知時寫明是哪一個，因為未知的那個開關仍可能把無線電
    # 關著，寫成開啟的列會宣稱得比讀到的多。
    if ($software -eq "on" -and $hardware -eq "on") { return "無線電開啟" }
    if ($software -eq "on") { return "軟體無線電開啟，硬體開關未知" }
    if ($hardware -eq "on") { return "硬體開關開啟，軟體狀態未知" }
    return ""
}

function Add-WifiRfResult {
    if (-not (Test-IsTrueFlag $script:Config.Checks.WifiRf)) { return }

    # 這一次讀取一次做兩件事（backlog #61 的另一半）：這一列，以及存取點的中間樣本——Compare-WifiAssociation 會拿它
    # 和第一項量測之前、最後一項量測之後取的樣本比較。
    # 這一列透過 Get-WifiInterfaceView 讀樣本（backlog #62）：WLAN 服務說有哪些介面、各自是否已連線，netsh 提供欄位；
    # 服務列為已連線而 netsh 什麼都沒印的介面，會被寫成已連線、欄位標為未回報——絕不寫成沒有介面。
    $sample = Add-WifiAssociationSample -Moment "middle"
    $views = @(Get-WifiInterfaceView -Sample $sample)
    $api = Get-PropertyValue $sample "Api" $null
    $apiLine = ""
    # 這一行以這次讀取自己的結果做記號收尾（PR #55，第 5 回合）——wlanapi=ok，或讀取器的原因代碼——因為測試鏈的 oracle 判斷沒有
    # 介面 GUID 的無線訊號列時，看的是寫出這一列的那次讀取，而存取點列的記號由另一個樣本決定，代表不了它。
    if ($null -eq $api) { $apiLine = "WLAN 服務：未讀取" }
    elseif (-not [string]::IsNullOrWhiteSpace([string]$api.Error)) { $apiLine = (("WLAN 服務：未讀取——{0} {1}" -f $api.Error, $api.ErrorText).Trim() + ("; wlanapi={0}" -f $api.Error)) }
    else { $apiLine = ("WLAN 服務：列出 {0} 個無線介面; wlanapi=ok" -f @($api.Interfaces).Count) }
    $netshReason = Get-WifiNetshReasonText -Sample $sample
    if ([string]$sample.Error -eq "netsh" -and $views.Count -eq 0) {
        Add-CheckResult -Category "IT 診斷資料" -Check "Wi-Fi 無線訊號" -Status "INFO" -Message "找不到 netsh.exe，無法取得 Wi-Fi 無線資料。" -Details $apiLine -Tag "wifi" -Scope "IT" | Out-Null
        return
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$sample.Error) -and $views.Count -eq 0) {
        Add-CheckResult -Category "IT 診斷資料" -Check "Wi-Fi 無線訊號" -Status "ERROR" -Message "無法讀取 Wi-Fi 無線資料。" -Details ((@([string]$sample.ErrorText, $apiLine) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join [Environment]::NewLine) -Diagnostics ([string]$sample.Diagnostics) -Tag "wifi" -Scope "IT" | Out-Null
        return
    }

    $netshCount = @($sample.Interfaces).Count
    $connected = @($views | Where-Object { $_.Connected })
    if ($connected.Count -eq 0) {
        # 沒有介面已連線，用讀到的說、不用猜的：WLAN 服務或 netsh 列出的每張介面各附狀態與無線電開關，再加上數量。有線
        # 電腦、無線電被關閉、沒有無線網卡都是可能的原因；這幾行寫的是這次執行看得見的那些。
        $lines = @()
        foreach ($view in $views) {
            $name = $view.Name
            if ([string]::IsNullOrWhiteSpace($name)) { $name = $view.Description }
            $stateText = "未連線（netsh 沒有印出關聯資料）"
            if ($null -ne $view.State) { $stateText = Get-WifiInterfaceStateText $view.State }
            $radio = Get-WifiRadioSwitchText -View $view
            $lines += ("{0}：{1}{2}" -f (ConvertTo-DisplayString $name), $stateText, $(if ($radio) { "，" + $radio } else { "" }))
        }
        if ($views.Count -eq 0) { $message = "netsh 與 WLAN 服務都沒有列出任何無線介面——例如有線電腦；詳細資料寫著兩個讀取來源各自回報了什麼。" }
        else { $message = "沒有已連線的無線介面：列出 {0} 個，都未連線——{1}。" -f $views.Count, ($lines -join "；") }
        $details = @()
        $details += $lines
        $details += ("netsh 回報的無線介面數：{0}" -f $netshCount)
        $details += $apiLine
        if ($netshReason) { $details += ("netsh：" + $netshReason) }
        $details += "檢測方式：介面與連線狀態來自 WLAN 服務（WlanEnumInterfaces），欄位來自 netsh wlan show interfaces。"
        $details += "手動驗證：netsh wlan show interfaces"
        Add-CheckResult -Category "IT 診斷資料" -Check "Wi-Fi 無線訊號" -Status "INFO" -Message $message -Details ($details -join [Environment]::NewLine) -Tag "wifi" -Scope "IT" | Out-Null
        return
    }

    foreach ($wifi in $connected) {
        $name = $wifi.Name
        if ([string]::IsNullOrWhiteSpace($name)) { $name = $wifi.Description }
        $stateSource = "連線狀態來自 WLAN 服務（WlanEnumInterfaces）"
        if ($wifi.ConnectedSource -ne "wlanapi") { $stateSource = "連線狀態來自 netsh 印出的欄位，因為無法詢問 WLAN 服務" }
        if (-not $wifi.NetshListed) {
            # WLAN 服務說已連線，netsh 卻什麼都沒印（backlog #62）：這一列回報連線，並把它拿不到的欄位標出來、說明原因。量到的
            # 原因是位置設定：netsh 整段輸出被拒、結束碼 1，而服務對連線查詢回錯誤 5——netsh 拿網路名稱、存取點、訊號與速率
            # 用的正是這個查詢。其他原因只寫樣本記錄到的內容，不指認原因。
            $channelText = "頻道未讀取"
            if ($null -ne $wifi.Channel) { $channelText = "頻道 {0}" -f $wifi.Channel }
            $queryText = "未詢問"
            if ($wifi.ConnectionQuery -eq 0) { $queryText = "已回答" }
            elseif ($wifi.ConnectionQuery -gt 0) { $queryText = Get-Win32ErrorText $wifi.ConnectionQuery }
            $consent = $null
            if ($null -ne $api) { $consent = Get-PropertyValue $api "LocationConsent" $null }
            $consentText = ""
            if ($null -ne $consent) { $consentText = [string](Get-PropertyValue $consent "Text" "") }
            if ($wifi.Refused) {
                $message = "{0}：已連線（WLAN 服務），{1}；無法讀取網路名稱、存取點、訊號與速率——{2}，且 WLAN 服務拒絕了連線查詢（錯誤 5，存取被拒），而位置權限存放區顯示 Deny（{3}）：在 Windows 11 24H2 及之後的版本，連線細節需要位置設定允許桌面應用程式（設定 > 隱私權與安全性 > 位置）。" -f (ConvertTo-DisplayString $name), $channelText, $netshReason, $consentText
            }
            elseif ($wifi.AccessDenied) {
                # 錯誤 5 只是存取被拒、沒有更多（PR #55，第 1 回合）：沒有權限存放區的 Deny、也沒有會擋住細節的版本，就不指認原因——
                # 限制 WLAN 查詢的原則否則會被指向錯的設定。
                $message = "{0}：已連線（WLAN 服務），{1}；無法讀取網路名稱、存取點、訊號與速率——{2}，且 WLAN 服務拒絕了連線查詢（錯誤 5，存取被拒），但位置權限存放區沒有顯示拒絕（{3}）{4}；原因未能確認——例如限制 WLAN 查詢的原則。" -f (ConvertTo-DisplayString $name), $channelText, $netshReason, $(if ($consentText) { $consentText } else { "未讀取" }), $(if ($null -ne $consent -and -not [bool](Get-PropertyValue $consent "Gated" $false)) { "，而且這個 Windows 早於把 Wi-Fi 細節擋在那個設定後面的版本（24H2）" } else { "" })
            }
            else {
                $reason = $netshReason
                if ([string]::IsNullOrWhiteSpace($reason)) { $reason = "netsh wlan show interfaces 沒有列出這個介面" }
                $message = "{0}：已連線（WLAN 服務），{1}；無法讀取網路名稱、存取點、訊號與速率——{2}（連線查詢：{3}）。" -f (ConvertTo-DisplayString $name), $channelText, $reason, $queryText
            }
            $radio = Get-WifiRadioSwitchText -View $wifi
            $printed = @(Get-PropertyValue $sample "NetshLines" @())
            $netshLines = @()
            if ($printed.Count -gt 0) {
                $netshLines += "netsh 印出："
                foreach ($line in @($printed | Select-Object -First 12)) { $netshLines += ("  " + $line) }
                if ($printed.Count -gt 12) { $netshLines += ("  ……還有 {0} 行" -f ($printed.Count - 12)) }
            }
            $details = @()
            $details += ("介面（WLAN 服務）：{0}" -f (ConvertTo-DisplayString $wifi.Description))
            $details += ("介面 GUID：{0}" -f $wifi.Guid)
            $details += ("連線狀態：{0}（WLAN 服務）；netsh 結束碼 {1}；連線查詢：{2}{3}" -f (Get-WifiInterfaceStateText $wifi.State), (ConvertTo-IntSafe (Get-PropertyValue $sample "NetshExitCode" 0) 0), $queryText, $(if ($consentText) { "；位置權限：" + $consentText } else { "" }))
            $details += ("頻道：{0}{1}" -f $(if ($null -ne $wifi.Channel) { [string]$wifi.Channel } else { "未讀取" }), $(if ($radio) { "；" + $radio } else { "" }))
            $details += "未回報：SSID、BSSID、頻段、無線規格、訊號、接收與傳送速率、設定檔"
            $details += $netshLines
            $details += "檢測方式：介面與連線狀態來自 WLAN 服務（WlanEnumInterfaces），欄位缺少的原因來自它連線查詢的回傳碼（WlanQueryInterface，目前連線），印出的欄位來自 netsh wlan show interfaces。"
            # 手動驗證跟著見證走（PR #55，第 2 回合）：有見證的拒絕才指向位置設定，沒有見證的錯誤 5 給 WLAN 查詢的檢查，其他情況
            # 只叫人讀 netsh 的輸出。
            if ($wifi.Refused) { $details += "手動驗證：netsh wlan show interfaces（它會指出要開啟的設定）；start ms-settings:privacy-location（設定 > 隱私權與安全性 > 位置）" }
            elseif ($wifi.AccessDenied) { $details += "手動驗證：netsh wlan show interfaces，並讀它印出的訊息；WLAN 服務拒絕了連線查詢（錯誤 5）——限制 WLAN 查詢的原則會造成這種結果" }
            else { $details += "手動驗證：netsh wlan show interfaces，並讀它印出的訊息" }
            $details += "說明：用戶端看到的數值，證據力低於 AP 的用戶端列表。"
            Add-CheckResult -Category "IT 診斷資料" -Check "Wi-Fi 無線訊號" -Status "INFO" -Message $message -Details ($details -join [Environment]::NewLine) -Tag "wifi" -Scope "IT" | Out-Null
            continue
        }
        $rssi = "?"
        if ($null -ne $wifi.SignalPercent) { $rssi = [math]::Round(($wifi.SignalPercent / 2.0) - 100, 0) }
        if ($null -ne $wifi.Rssi) { $rssi = $wifi.Rssi }
        $message = "SSID {0}：訊號 {1}%（約 {2} dBm），{3} {4}，頻道 {5}，{6}/{7} Mbps。" -f $wifi.Ssid, (ConvertTo-DisplayString $wifi.SignalPercent), $rssi, $wifi.RadioType, $wifi.Band, (ConvertTo-DisplayString $wifi.Channel), (ConvertTo-DisplayString $wifi.ReceiveRateMbps), (ConvertTo-DisplayString $wifi.TransmitRateMbps)
        $details = (@(
            ("介面：{0}" -f $wifi.Name),
            $(if (-not [string]::IsNullOrWhiteSpace([string]$wifi.Guid)) { "介面 GUID：{0}" -f $wifi.Guid } else { $null }),
            ("連線狀態：{0}" -f $(if ($wifi.ConnectedSource -eq "wlanapi") { "{0}（WLAN 服務）" -f (Get-WifiInterfaceStateText $wifi.State) } else { "已連線（netsh 印出了關聯資料；無法詢問 WLAN 服務）" })),
            ("BSSID：{0}" -f (ConvertTo-DisplayString $wifi.Bssid)),
            ("無線規格：{0}，頻段 {1}，頻道 {2}" -f $wifi.RadioType, (ConvertTo-DisplayString $wifi.Band), (ConvertTo-DisplayString $wifi.Channel)),
            ("速率：接收 {0} Mbps，傳送 {1} Mbps" -f (ConvertTo-DisplayString $wifi.ReceiveRateMbps), (ConvertTo-DisplayString $wifi.TransmitRateMbps)),
            ("訊號：{0}%（約 {1} dBm）" -f (ConvertTo-DisplayString $wifi.SignalPercent), $rssi),
            ("設定檔：{0}" -f (ConvertTo-DisplayString $wifi.Profile)),
            ("檢測方式：netsh wlan show interfaces，因標籤隨語系不同而改以欄位位置解析；{0}；dBm 由訊號百分比估算。" -f $stateSource),
            "手動驗證：netsh wlan show interfaces",
            "說明：用戶端看到的數值，證據力低於 AP 的用戶端列表。"
        ) | Where-Object { $null -ne $_ }) -join [Environment]::NewLine
        Add-CheckResult -Category "IT 診斷資料" -Check "Wi-Fi 無線訊號" -Status "INFO" -Message $message -Details $details -Tag "wifi" -Scope "IT" | Out-Null
    }
}

function Test-WifiSampleReadable {
    param([object]$Sample)

    # 兩個讀取來源任一方有回答，樣本就算可讀（PR #55，第 6 回合）：netsh 的讀取可能整個失敗——找不到執行檔、讀取時擲出例外——
    # 而 WLAN 服務仍然列出了介面與狀態，只因 netsh 失敗就跳過的樣本會漏掉服務看見的介面。兩個讀取來源都失敗的樣本才算
    # 不可讀，而每次樣本都如此才是彙總失敗列。
    if ($null -eq $Sample) { return $false }
    # netsh 有執行且以 0 結束才算有回答（PR #55，第 10 回合）：非零結束碼、什麼都沒列，和擲出例外一樣是失敗的讀取，旁邊的
    # 服務讀取也失敗時，得到的是彙總列，不是有線電腦那一列。
    if ([string]::IsNullOrWhiteSpace([string](Get-PropertyValue $Sample "Error" "")) -and (ConvertTo-IntSafe (Get-PropertyValue $Sample "NetshExitCode" 0) 0) -eq 0) { return $true }
    $api = Get-PropertyValue $Sample "Api" $null
    return ($null -ne $api -and [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $api "Error" "")))
}

function Get-WifiApiSummaryText {
    param([object]$Sample)

    # WLAN 服務對一次樣本的讀數，濃縮成一個子句，給那些在 netsh 印出的內容旁邊回報樣本的行（backlog #62）：列出了幾張介面，
    # 或者為什麼讀不到；沒有帶服務讀數的樣本則什麼都不寫。
    if ($null -eq $Sample) { return "" }
    $api = Get-PropertyValue $Sample "Api" $null
    if ($null -eq $api) { return "" }
    $error = [string](Get-PropertyValue $api "Error" "")
    if (-not [string]::IsNullOrWhiteSpace($error)) { return ("WLAN 服務：未讀取——{0} {1}" -f $error, [string](Get-PropertyValue $api "ErrorText" "")).Trim() }
    return ("WLAN 服務：列出 {0} 個無線介面" -f @(Get-PropertyValue $api "Interfaces" @()).Count)
}

function Compare-WifiAssociation {
    param([object[]]$Samples)

    # 把各次存取點樣本互相比對（backlog #61 的另一半）：任何一次樣本列出的每張無線介面各一列，說它整段執行是留在同一個
    # 存取點、換到了另一個，還是根本沒回報存取點——而不論它說什麼，都要說明「兩個樣本之間換出去又回到同一個存取點」
    # 是看不見的，因為 BSSID 是取樣的，不是持續監看的。這個限制寫在每一列上，而不是靠沉默暗示：兩個相同的樣本不能
    # 排除一次繞回來的漫遊。Windows 的 WLAN 事件記錄作為替代方案量測過、沒有採用——不提權就能讀，但沒有任何事件
    # 帶 BSSID，而它記錄的安全性重新關聯，換金鑰和漫遊都會寫，所以它說不出比樣本更多的東西。IT 範圍的列，和它所延伸的
    # 無線訊號列一樣：是證據，不是判定。
    # 介面來自每次樣本的兩個讀取來源（backlog #62，Get-WifiInterfaceView）：WLAN 服務有列出、netsh 卻什麼都沒印的介面——
    # 桌面應用程式不被允許存取位置時整段輸出被拒——也有自己的一列，每個這樣的樣本寫成「未取樣」並附上服務給的狀態，
    # 而不是有線電腦才會拿到的那一列「沒有介面」。
    $category = "IT 診斷資料"
    $check = "Wi-Fi 存取點"
    $samples = @(@($Samples) | Where-Object { $null -ne $_ })
    $readable = @($samples | Where-Object { Test-WifiSampleReadable $_ })
    $momentText = @{ start = "第一項量測之前"; middle = "收集 IT 診斷資料時"; end = "最後一項量測之後" }
    $entries = @()
    $index = 0
    foreach ($sample in $samples) {
        $index++
        $moment = [string]$sample.Moment
        if ($momentText.ContainsKey($moment)) { $moment = $momentText[$moment] }
        $stamp = ""
        try { $stamp = ([datetime]$sample.Timestamp).ToString("HH:mm:ss") } catch { $stamp = "" }
        $entries += [pscustomobject]@{ Sample = $sample; Prefix = ("樣本 {0}（{1}，{2}）" -f $index, $moment, $stamp) }
    }
    $seconds = 0
    if ($samples.Count -ge 2) { try { $seconds = [math]::Round((([datetime]$samples[$samples.Count - 1].Timestamp) - ([datetime]$samples[0].Timestamp)).TotalSeconds, 0) } catch { $seconds = 0 } }
    # 這次執行裡工具自己的 WLAN API 讀取器有沒有回答，做成彙總列在原因後面帶的記號（PR #55，第 4 回合）：wlanapi=ok，或讀取器的
    # 原因代碼——addtype、open、enumerate、error。測試鏈的 oracle 在 netsh 被拒時讀它：讀取器答不出來，工具就沒有介面可以
    # 寫列，彙總列這時是對的形狀、不是漏掉的列。以最後一個帶讀數的樣本為準。
    $apiToken = ""
    foreach ($sample in $samples) {
        $sampleApi = Get-PropertyValue $sample "Api" $null
        if ($null -eq $sampleApi) { continue }
        $apiError = [string](Get-PropertyValue $sampleApi "Error" "")
        $apiToken = $(if ([string]::IsNullOrWhiteSpace($apiError)) { "ok" } else { $apiError })
    }
    $apiSuffix = $(if ($apiToken) { "; wlanapi=" + $apiToken } else { "" })
    $methodLines = @(
        ("檢測方式：netsh wlan show interfaces，本次測試共讀取 {0} 次——第一項量測之前、收集 IT 診斷資料時、最後一項量測之後——並把各次讀到的 BSSID 互相比較；存取點是取樣的，不是持續監看的。每次讀取旁邊另有 WLAN 服務自己列出的無線介面與各介面的連線狀態（WlanEnumInterfaces），所以 netsh 什麼都沒印的介面仍然知道存在、狀態也知道。" -f $samples.Count),
        "手動驗證：問題發生時反覆執行 netsh wlan show interfaces",
        "說明：BSSID 是存取點自己的位址，所以同一個網路名稱下 BSSID 改變就是漫遊——正是那種能解釋「訊號好、數字卻差」的空中事件——網路名稱也變了則是換到另一個網路。兩個樣本之間換出去又回到同一個存取點的變化，這裡看不見：兩個相同的樣本不能排除它。Windows 的 WLAN 事件記錄只記網路、不記存取點，所以沒有讀取。這一列不影響任何判定。"
    )

    if ($samples.Count -eq 0) {
        Add-CheckResult -Category $category -Check $check -Status "ERROR" -Message "測試期間沒有取得任何存取點樣本，無法比較連線的存取點。" -Details ((@("讀取：none") + $methodLines) -join [Environment]::NewLine) -Tag "wifi-association" -Scope "IT" | Out-Null
        return
    }
    if ($readable.Count -eq 0) {
        # 每一次樣本都失敗：一列，原因代碼放在 details 第一行的結尾——和 tag 一樣不隨語言改變的記號——測試鏈的 oracle 靠它
        # 分辨這個彙總列和逐介面的列。
        $first = $samples[0]
        $reason = [string]$first.Error
        # netsh 有執行、以非零結束碼結束、什麼都沒列，旁邊的服務讀取也失敗（第 10 回合）：原因記號是 refused，訊息寫出兩個讀取來源，
        # 因為兩邊都沒回答。
        if ([string]::IsNullOrWhiteSpace($reason)) { $reason = "refused" }
        $message = "無法取樣 Wi-Fi 存取點：找不到 netsh.exe。"
        if ($reason -eq "refused") { $message = "無法取樣 Wi-Fi 存取點：netsh wlan show interfaces 沒有印出任何介面，而 WLAN 服務也無法讀取。" }
        elseif ($reason -ne "netsh") { $message = "無法取樣 Wi-Fi 存取點：netsh wlan show interfaces 無法讀取。" }
        $lines = @(("讀取：{0}{1}" -f $reason, $apiSuffix))
        foreach ($entry in $entries) {
            $apiSummary = Get-WifiApiSummaryText -Sample $entry.Sample
            $netshText = [string]$entry.Sample.ErrorText
            if ([string]::IsNullOrWhiteSpace($netshText)) { $netshText = Get-WifiNetshReasonText -Sample $entry.Sample }
            $lines += ("{0}：無法讀取——{1}{2}" -f $entry.Prefix, $netshText, $(if ($apiSummary) { "；" + $apiSummary } else { "" }))
        }
        Add-CheckResult -Category $category -Check $check -Status "ERROR" -Message $message -Details ((@($lines) + $methodLines) -join [Environment]::NewLine) -Diagnostics ([string]$first.Diagnostics) -Tag "wifi-association" -Scope "IT" | Out-Null
        return
    }

    # 任何一次可讀樣本裡、兩個讀取來源任一方列出的介面：有印 GUID 就以 GUID 為鍵，沒有就以網卡位址為鍵，依第一次出現的
    # 順序；每次樣本的檢視留給下面的迴圈用。
    $keys = New-Object System.Collections.ArrayList
    $names = @{}
    $viewsBySample = @{}
    for ($i = 0; $i -lt $entries.Count; $i++) {
        $sample = $entries[$i].Sample
        if (-not (Test-WifiSampleReadable $sample)) { continue }
        $views = @(Get-WifiInterfaceView -Sample $sample)
        $viewsBySample[$i] = $views
        foreach ($view in $views) {
            $key = [string]$view.Key
            if (-not $names.ContainsKey($key)) {
                [void]$keys.Add($key)
                $names[$key] = $(if (-not [string]::IsNullOrWhiteSpace([string]$view.Name)) { [string]$view.Name } else { [string]$view.Description })
            }
        }
    }
    if ($keys.Count -eq 0) {
        $lines = @(("讀取：none{0}" -f $apiSuffix))
        foreach ($entry in $entries) {
            $sample = $entry.Sample
            $apiSummary = Get-WifiApiSummaryText -Sample $sample
            if ([string]::IsNullOrWhiteSpace([string]$sample.Error)) {
                $reason = Get-WifiNetshReasonText -Sample $sample
                $lines += ("{0}：未列出任何無線介面{1}{2}" -f $entry.Prefix, $(if ($reason) { "——" + $reason } else { "" }), $(if ($apiSummary) { "；" + $apiSummary } else { "" }))
            }
            else { $lines += ("{0}：無法讀取——{1}{2}" -f $entry.Prefix, [string]$sample.ErrorText, $(if ($apiSummary) { "；" + $apiSummary } else { "" })) }
        }
        Add-CheckResult -Category $category -Check $check -Status "INFO" -Message ("{0} 次樣本都沒有列出任何無線介面——netsh 與 WLAN 服務都沒有——所以沒有存取點可以比較；例如有線電腦，樣本行寫著兩個讀取來源各自回報了什麼。" -f $samples.Count) -Details ((@($lines) + $methodLines) -join [Environment]::NewLine) -Tag "wifi-association" -Scope "IT" | Out-Null
        return
    }

    foreach ($key in $keys) {
        $name = ConvertTo-DisplayString $names[$key]
        $readings = @()
        $lines = @()
        for ($i = 0; $i -lt $entries.Count; $i++) {
            $entry = $entries[$i]
            $sample = $entry.Sample
            if (-not (Test-WifiSampleReadable $sample)) {
                $lines += ("{0}：無法讀取——{1}" -f $entry.Prefix, [string]$sample.ErrorText)
                # 失敗的樣本仍然是這次執行的樣本之一（PR #54，第 1 回合）：訊息裡的每個總數都要算它，而它既不是存取點的一次
                # 讀數，也不是介面不在場的證據。
                $readings += [pscustomobject]@{ State = "failed"; Moment = [string]$sample.Moment; Bssid = ""; Ssid = ""; ApiState = $null; LocationDenied = $false }
                continue
            }
            $match = @(@($viewsBySample[$i]) | Where-Object { [string]$_.Key -eq $key } | Select-Object -First 1)
            if ($match.Count -eq 0) {
                $lines += ("{0}：介面未列出" -f $entry.Prefix)
                $readings += [pscustomobject]@{ State = "absent"; Moment = [string]$sample.Moment; Bssid = ""; Ssid = ""; ApiState = $null; LocationDenied = $false }
                continue
            }
            $view = $match[0]
            $apiState = $view.State
            $stateSuffix = ""
            if ($null -ne $apiState) { $stateSuffix = "；WLAN 服務：{0}" -f (Get-WifiInterfaceStateText $apiState) }
            if ((ConvertTo-IntSafe $view.ConnectionQuery -1) -gt 0) { $stateSuffix += ("；連線查詢：{0}" -f (Get-Win32ErrorText $view.ConnectionQuery)) }
            if (-not $view.NetshListed) {
                # WLAN 服務有列出、netsh 什麼都沒印（backlog #62）：既不是存取點的一次讀數，也不是不在場——是介面存在卻無法
                # 取樣的一次樣本，附上樣本記錄到的原因和服務給的狀態。
                $reason = Get-WifiNetshReasonText -Sample $sample
                if ([string]::IsNullOrWhiteSpace($reason)) { $reason = "netsh wlan show interfaces 沒有列出這個介面" }
                $lines += ("{0}：未取樣——{1}{2}" -f $entry.Prefix, $reason, $stateSuffix)
                $readings += [pscustomobject]@{ State = "refused"; Moment = [string]$sample.Moment; Bssid = ""; Ssid = ""; ApiState = $apiState; LocationDenied = [bool]$view.Refused }
                continue
            }
            $bssid = ([string]$view.Bssid).Trim().ToLowerInvariant()
            if ([string]::IsNullOrWhiteSpace($bssid)) { $lines += ("{0}：未回報 BSSID{1}" -f $entry.Prefix, $stateSuffix) }
            else { $lines += (("{0}：SSID {1}，BSSID {2}" -f $entry.Prefix, (ConvertTo-DisplayString $view.Ssid), $bssid) + $stateSuffix) }
            $readings += [pscustomobject]@{ State = $(if ([string]::IsNullOrWhiteSpace($bssid)) { "nobssid" } else { "bssid" }); Moment = [string]$sample.Moment; Bssid = $bssid; Ssid = [string]$view.Ssid; ApiState = $apiState; LocationDenied = $false }
        }
        $withBssid = @($readings | Where-Object { $_.State -eq "bssid" })
        $absentCount = @($readings | Where-Object { $_.State -eq "absent" }).Count
        $failedCount = @($readings | Where-Object { $_.State -eq "failed" }).Count
        $refused = @($readings | Where-Object { $_.State -eq "refused" })
        $listedMoments = @($readings | Where-Object { $_.State -eq "bssid" -or $_.State -eq "nobssid" -or $_.State -eq "refused" } | ForEach-Object { $_.Moment })
        # WLAN 服務對這張介面的說法，給需要它的句子用：在服務有列出它的樣本裡，有幾次是已連線。沒有 BSSID 絕不寫成「已斷線」
        # （backlog #62）：已關聯的無線電也可能被扣住這個欄位，而狀態是服務說了算。
        $apiKnown = @($readings | Where-Object { $null -ne $_.ApiState })
        $apiConnected = @($apiKnown | Where-Object { $_.ApiState -eq 1 })
        $stateSentence = ""
        if ($apiKnown.Count -gt 0) {
            if ($apiConnected.Count -eq $apiKnown.Count) { $stateSentence = "WLAN 服務回報它在列出它的 {0} 次樣本都是已連線。" -f $apiKnown.Count }
            elseif ($apiConnected.Count -eq 0) { $stateSentence = "WLAN 服務回報它在列出它的 {0} 次樣本都不是已連線。" -f $apiKnown.Count }
            else { $stateSentence = "WLAN 服務回報它在列出它的 {1} 次樣本中有 {0} 次已連線。" -f $apiConnected.Count, $apiKnown.Count }
        }
        $locationCount = @($refused | Where-Object { $_.LocationDenied }).Count
        $refusedSentence = ""
        if ($refused.Count -gt 0) {
            if ($locationCount -eq $refused.Count) { $refusedSentence = "其中 {0} 次樣本 netsh 沒有印出任何介面，因為桌面應用程式不被允許存取位置（WLAN 服務以錯誤 5 拒絕了連線查詢；設定 > 隱私權與安全性 > 位置）。" -f $refused.Count }
            else { $refusedSentence = "其中 {0} 次樣本 netsh 沒有印出任何介面；樣本行寫著記錄到的內容。" -f $refused.Count }
        }
        if ($withBssid.Count -eq 0) {
            if ($refused.Count -gt 0 -and $refused.Count -eq $listedMoments.Count) {
                if ($locationCount -eq $refused.Count) {
                    $message = "{0}：{1} 次樣本都無法取樣存取點：netsh 沒有印出任何介面，因為桌面應用程式不被允許存取位置（WLAN 服務以錯誤 5 拒絕了連線查詢；設定 > 隱私權與安全性 > 位置），所以在這裡看不見漫遊。{2}" -f $name, $readings.Count, $stateSentence
                }
                else {
                    $message = "{0}：{1} 次樣本都無法取樣存取點：netsh 沒有印出任何介面（樣本行寫著記錄到的內容），所以在這裡看不見漫遊。{2}" -f $name, $readings.Count, $stateSentence
                }
            }
            else {
                $message = ("{0}：{1} 次樣本都沒有回報存取點（BSSID）——介面未關聯，或 netsh 沒有印出這個欄位；請看 Wi-Fi 無線訊號那一列。" -f $name, $readings.Count) + $refusedSentence + $stateSentence
            }
        }
        else {
            $distinctBssids = @($withBssid | ForEach-Object { $_.Bssid } | Select-Object -Unique)
            $distinctSsids = @($withBssid | ForEach-Object { $_.Ssid } | Select-Object -Unique)
            $first = $withBssid[0]
            if ($distinctBssids.Count -eq 1 -and $distinctSsids.Count -gt 1) {
                # 同一個位址、卻不只一個網路名稱（PR #54，第 2 回合）：存取點在執行期間被改名或重新設定，穩定不變那一句會把它藏在
                # 第一個名稱後面。
                $ssidSequence = @()
                foreach ($reading in $withBssid) { if ($ssidSequence.Count -eq 0 -or $ssidSequence[$ssidSequence.Count - 1] -cne $reading.Ssid) { $ssidSequence += $reading.Ssid } }
                $message = "{0}：有回報存取點的 {2} 次樣本（共 {3} 次）都是同一個存取點（BSSID {1}），但網路名稱不只一個——SSID {4}——所以存取點在執行期間被改名或重新設定。" -f $name, $first.Bssid, $withBssid.Count, $readings.Count, (@($ssidSequence | ForEach-Object { ConvertTo-DisplayString $_ }) -join "、然後 ")
            }
            elseif ($distinctBssids.Count -eq 1) {
                if ($withBssid.Count -eq $readings.Count) {
                    $message = "{0}：SSID {1}，{3} 次樣本（跨 {4} 秒）都在同一個存取點（BSSID {2}）；兩個樣本之間換出去又回到它的變化看不見。" -f $name, (ConvertTo-DisplayString $first.Ssid), $first.Bssid, $readings.Count, $seconds
                }
                else {
                    $message = "{0}：SSID {1}，有回報存取點的 {3} 次樣本（共 {4} 次）都是同一個（BSSID {2}）；其餘樣本沒有回報 BSSID、netsh 沒有印出任何介面、介面未列出，或樣本無法讀取。" -f $name, (ConvertTo-DisplayString $first.Ssid), $first.Bssid, $withBssid.Count, $readings.Count
                }
            }
            else {
                # 依取樣順序列出存取點，連續重複的摺起來，讓「A、然後 B、然後 A」讀起來就是它本來的樣子——一次繞回來的漫遊，
                # 只取兩個樣本會把它藏起來。
                $sequence = @()
                $labels = @()
                foreach ($reading in $withBssid) {
                    if ($sequence.Count -gt 0 -and $sequence[$sequence.Count - 1] -eq $reading.Bssid) { continue }
                    $sequence += $reading.Bssid
                    $labels += ("SSID {0}（BSSID {1}）" -f (ConvertTo-DisplayString $reading.Ssid), $reading.Bssid)
                }
                $changes = $sequence.Count - 1
                $shape = "一次漫遊"
                if ($changes -gt 1) {
                    $shape = "{0} 次漫遊" -f $changes
                    if ($sequence[0] -eq $sequence[$sequence.Count - 1]) { $shape += "，回到最初的存取點" }
                }
                if ($distinctSsids.Count -eq 1) {
                    $message = "{0}：測試期間存取點改變——BSSID {1}——SSID {2} 不變：{3}。本次執行的數字是跨著這個變化量到的。" -f $name, ($sequence -join "、然後 "), (ConvertTo-DisplayString $first.Ssid), $shape
                }
                else {
                    $message = "{0}：測試期間介面換到了另一個網路——{1}。本次執行的數字是跨著這個變化量到的。" -f $name, ($labels -join "、然後 ")
                }
            }
            $message += $refusedSentence
            # netsh 印了 BSSID、服務卻說不是已連線——兩次讀取是先後進行的，無線電可能在中間掉線——要說出來，不能藏在位址後面
            # （PR #55，第 3 回合）：只要服務的說法不是「列出它的每次樣本都已連線」，就把服務的說法接在後面。
            if ($apiKnown.Count -gt 0 -and $apiConnected.Count -lt $apiKnown.Count) { $message += $stateSentence }
        }
        if ($absentCount -gt 0) { $message += ("介面在其中 {0} 次樣本未列出（那一刻被停用或移除）。" -f $absentCount) }
        if ($failedCount -gt 0) { $message += ("其中 {0} 次樣本無法讀取。" -f $failedCount) }
        # 身分那一行以介面被列出的樣本收尾，用不隨語言改變的記號（samples=start,middle,end）：測試鏈的 oracle 靠它分辨「只在中間
        # 樣本出現的介面」——它的兩次讀取都不可能列出——和「寫了一張誰都沒列出的介面」的列（PR #54，第 1 回合）。WLAN 服務有
        # 列出、netsh 什麼都沒印的樣本也算列出：介面當時就在。
        $identity = @()
        if ($key -like "mac:*") { $identity += ("介面位址：{0}；samples={1}" -f $key.Substring(4), ($listedMoments -join ",")) } else { $identity += ("介面 GUID：{0}；samples={1}" -f $key, ($listedMoments -join ",")) }
        Add-CheckResult -Category $category -Check $check -Status "INFO" -Message $message -Details ((@($lines) + $identity + $methodLines) -join [Environment]::NewLine) -Tag "wifi-association" -Scope "IT" | Out-Null
    }
}

function Get-MacRelation {
    param([string]$First, [string]$Second)

    # 兩個 MAC 位址之間的關係，供「存取點就是閘道」的提示使用（backlog #61 的另一半）：identical 完全相同；near-ul 與
    # near-last 只差在第一個八位元組的本地管理位元、或只差在最後一個八位元組——同一台設備的無線電位址和橋接位址常見的
    # 形狀；vendor 前三個八位元組相同（那個位元除外）；different 不同；兩者之一不是 MAC 位址則為 invalid。分隔符號和
    # 大小寫不屬於位址的一部分。
    $a = ([string]$First) -replace '[^0-9a-fA-F]', ''
    $b = ([string]$Second) -replace '[^0-9a-fA-F]', ''
    if ($a.Length -ne 12 -or $b.Length -ne 12) { return "invalid" }
    $a = $a.ToUpperInvariant()
    $b = $b.ToUpperInvariant()
    if ($a -eq $b) { return "identical" }
    $firstA = [Convert]::ToInt32($a.Substring(0, 2), 16)
    $firstB = [Convert]::ToInt32($b.Substring(0, 2), 16)
    if (($firstA -bxor $firstB) -eq 2 -and $a.Substring(2) -eq $b.Substring(2)) { return "near-ul" }
    if ($a.Substring(0, 10) -eq $b.Substring(0, 10)) { return "near-last" }
    if (($firstA -band 0xFD) -eq ($firstB -band 0xFD) -and $a.Substring(2, 4) -eq $b.Substring(2, 4)) { return "vendor" }
    return "different"
}

function Get-AccessPointGatewayEvidence {
    param([string]$Gateway, [string]$GatewayMac, [object[]]$PrimaryAdapters, [object[]]$Samples, [int]$InterfaceIndex = 0)

    # 提示背後的比較，同時以證據和句子的形式給出（PR #54，第 3 回合）：存取點的位址、它和閘道位址的關係（Get-MacRelation 的字眼，
    # 介面沒有回報存取點時是 nobssid，什麼都沒比時是空的）、介面名稱，以及這一列印出的文字。最後一次樣本之後的重比對比的是位址
    # 和關係，絕不是句子——執行期間被改名的介面只會改變句子，其他什麼都不變。

    # 提示的那一句話，或者什麼都不寫（backlog #61 的另一半）。在無線機器上想把空氣和有線分開之前，最該先知道的是到底
    # 有沒有一段有線：回應無線電的存取點和回應 ping 的閘道可能是同一台盒子。BSSID 是存取點自己的位址，鄰居表裡有閘道
    # 的位址，所以兩者拿來比較——比的是提供這個閘道的那張網卡所對應的無線介面，用網卡自己的位址對上（netsh 印成介面的
    # 實體位址），取自最近一次讀得到的存取點樣本——並照它本來的身分發表：提示。位址完全相同就是同一台設備，但一體機的
    # 無線電位址和橋接位址常常只差一個八位元組或本地管理位元，所以不同並不能證明什麼。閘道由有線網卡提供時沒有存取點
    # 可比，Wi-Fi 資料關掉時沒有東西可比：兩種情況都不寫這一行。
    $evidence = [pscustomobject][ordered]@{ Text = ""; Bssid = ""; Relation = ""; Interface = "" }
    $gatewayHex = ([string]$GatewayMac) -replace '[^0-9a-fA-F]', ''
    if ($gatewayHex.Length -ne 12 -or $gatewayHex -eq "000000000000") { return $evidence }
    # 網卡取「鄰居項目是在哪張介面上學到的」那一張（PR #54，第 1 回合）：有線和無線網卡指向同一個閘道位址的機器上，項目的 MAC
    # 可能屬於有線那個網路，拿它和無線網路的存取點比較，就是把兩個毫不相關的位址擺在一起。-InterfaceIndex 是項目的介面；項目
    # 沒帶介面時——arp -a 備援——而且提供這個閘道的網卡不只一張，就什麼都不比。
    $adapterMacs = @()
    $candidates = 0
    foreach ($adapter in @($PrimaryAdapters)) {
        if ($null -eq $adapter -or @($adapter.Gateways) -notcontains [string]$Gateway) { continue }
        $candidates++
        if ($InterfaceIndex -gt 0 -and (ConvertTo-IntSafe (Get-PropertyValue $adapter "InterfaceIndex" 0) 0) -ne $InterfaceIndex) { continue }
        $adapterMac = ([string](Get-PropertyValue $adapter "MacAddress" "")) -replace '[^0-9a-fA-F]', ''
        if ($adapterMac.Length -eq 12) { $adapterMacs += $adapterMac.ToUpperInvariant() }
    }
    if ($adapterMacs.Count -eq 0) { return $evidence }
    if ($InterfaceIndex -le 0 -and $candidates -gt 1) { return $evidence }
    $latest = @(@($Samples) | Where-Object { $null -ne $_ -and [string]::IsNullOrWhiteSpace([string]$_.Error) } | Select-Object -Last 1)
    if ($latest.Count -eq 0) { return $evidence }
    foreach ($wifi in @($latest[0].Interfaces)) {
        $physical = ([string]$wifi.PhysicalAddress) -replace '[^0-9a-fA-F]', ''
        if ($physical.Length -ne 12 -or $adapterMacs -notcontains $physical.ToUpperInvariant()) { continue }
        $name = ConvertTo-DisplayString $wifi.Name
        $bssid = ([string]$wifi.Bssid).Trim().ToLowerInvariant()
        $evidence.Interface = $name
        if ([string]::IsNullOrWhiteSpace($bssid)) {
            $evidence.Relation = "nobssid"
            $evidence.Text = ("存取點與閘道：這個閘道經由無線介面 {0} 到達，但該介面沒有回報 BSSID，兩個位址無法比較。" -f $name)
            return $evidence
        }
        $evidence.Bssid = $bssid
        $evidence.Relation = Get-MacRelation -First $GatewayMac -Second $bssid
        switch ($evidence.Relation) {
            "identical" { $evidence.Text = ("存取點與閘道：閘道的 MAC 位址就是 {0} 所連存取點的 BSSID（{1}），所以存取點和閘道是同一台設備——自帶無線電的路由器——在這個網路上，空氣與有線之間沒有可供「有線對無線」比較立足的邊界。" -f $name, $bssid) }
            "near-ul"   { $evidence.Text = ("存取點與閘道：閘道的 MAC 位址與 {0} 所連存取點的 BSSID（{1}）只差在本地管理位元，這是同一台設備的無線電位址和橋接位址常見的形狀；把兩者當成大概是同一台設備——這是提示，不是拓樸結論。" -f $name, $bssid) }
            "near-last" { $evidence.Text = ("存取點與閘道：閘道的 MAC 位址與 {0} 所連存取點的 BSSID（{1}）只差在最後一個八位元組，這是同一台設備的無線電位址和橋接位址常見的形狀；把兩者當成大概是同一台設備——這是提示，不是拓樸結論。" -f $name, $bssid) }
            "vendor"    { $evidence.Text = ("存取點與閘道：閘道的 MAC 位址與 {0} 所連存取點的 BSSID（{1}）的廠商前綴（前三個八位元組）相同——同一家廠商，可能是一台設備、也可能是兩台；這是提示，不是拓樸結論。" -f $name, $bssid) }
            default     { $evidence.Text = ("存取點與閘道：閘道的 MAC 位址與 {0} 所連存取點的 BSSID（{1}）廠商前綴不同，暗示是兩台設備——一台存取點加一台路由器——因此空氣與有線之間有一道邊界，同一網段上的有線工作站可以從那裡量起；這是提示，不是拓樸結論，因為自帶無線電的路由器也可能為兩者使用毫不相關的位址。" -f $name, $bssid) }
        }
        return $evidence
    }
    return $evidence
}

function Get-AccessPointGatewayText {
    param([string]$Gateway, [string]$GatewayMac, [object[]]$PrimaryAdapters, [object[]]$Samples, [int]$InterfaceIndex = 0)

    # 只給句子，供印出它的呼叫者使用；背後的證據在 Get-AccessPointGatewayEvidence。
    return ([string](Get-AccessPointGatewayEvidence -Gateway $Gateway -GatewayMac $GatewayMac -PrimaryAdapters $PrimaryAdapters -Samples $Samples -InterfaceIndex $InterfaceIndex).Text)
}

function Update-AccessPointGatewayHints {
    param([object[]]$Samples)

    # 閘道鄰居列上的提示是在收集 IT 診斷資料時寫的，那時只有前兩次存取點樣本；那次讀取和最後一次樣本之間的漫遊，會讓它拿閘道
    # 去比一個存取點列說已經離開的存取點（PR #54，第 2 回合）。所以最後一次樣本之後再比一次，對象是最近一次讀得到的樣本：讀出來
    # 一樣就不動這一列；不一樣時，鄰居表讀取時寫的那一行留著——它在那一刻是真的——再加一行給出「介面在結束時所連存取點」的比較，
    # 或者說那時已沒有回報存取點，並指向存取點列。
    foreach ($entry in @($script:GatewayNeighborRows)) {
        if ($null -eq $entry -or $null -eq $entry.Row) { continue }
        $freshEvidence = Get-AccessPointGatewayEvidence -Gateway ([string]$entry.Gateway) -GatewayMac ([string]$entry.Mac) -PrimaryAdapters @($script:PrimaryAdapters) -Samples @($Samples) -InterfaceIndex (ConvertTo-IntSafe $entry.InterfaceIndex 0)
        # 比的是證據，不是句子（第 3 回合）：同一個位址、同一種關係就是同一個發現，不管介面現在叫什麼名字。
        if (([string]$freshEvidence.Bssid -eq [string](Get-PropertyValue $entry "Bssid" "")) -and ([string]$freshEvidence.Relation -eq [string](Get-PropertyValue $entry "Relation" ""))) { continue }
        $fresh = [string]$freshEvidence.Text
        if ([string]::IsNullOrWhiteSpace([string]$fresh)) {
            $line = "存取點與閘道（最後一次樣本之後）：介面已不再回報 BSSID，所以上面的比較無法重做；Wi-Fi 存取點列記錄了各次樣本看到的東西。"
        }
        else {
            $line = "存取點與閘道（最後一次樣本之後）：{0}鄰居表讀取時介面連的是另一個存取點、或沒有回報存取點——Wi-Fi 存取點列記錄了各次樣本——所以上面那一行（如果有）代表那一刻，這一行代表執行結束時。" -f ($fresh -replace '^[^:：]*[:：]\s*', '')
        }
        $lines = @(([string]$entry.Row.Details) -split "\r?\n")
        $at = -1
        if (-not [string]::IsNullOrWhiteSpace([string]$entry.Hint)) { $at = [array]::IndexOf($lines, [string]$entry.Hint) }
        if ($at -lt 0) {
            # 鄰居表讀取時沒有寫這一行：新的一行放在它本來會在的位置，也就是檢測方式那一行之前。
            for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -like "檢測方式：*") { $at = $i - 1; break } }
        }
        if ($at -lt 0) { $lines = @($lines) + @($line) }
        else { $lines = @($(if ($at -ge 0) { $lines[0..$at] } else { @() })) + @($line) + @($(if ($at + 1 -lt $lines.Count) { $lines[($at + 1)..($lines.Count - 1)] } else { @() })) }
        $entry.Row.Details = ($lines -join [Environment]::NewLine)
        $entry.Hint = [string]$fresh
        $entry.Bssid = [string]$freshEvidence.Bssid
        $entry.Relation = [string]$freshEvidence.Relation
        Write-UiLog -Status "INFO" -Text ("{0} / {1}: {2}" -f $entry.Row.Category, $entry.Row.Check, $line)
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
        # 在 Windows PowerShell 裡，CIM 查詢沒有符合項目並不是空結果：Get-NetRoute 會拋出 CimJobException
        # （FullyQualifiedErrorId 為 CmdletizationQuery_NotFound，分類 ObjectNotFound），訊息用的是機器的顯示語言。
        # 這是沒有預設路由的機器的正常狀態（待辦 #19 的 host-only 情境），1.2.3 之前卻被寫成引擎錯誤（待辦 #27）。
        # 這個識別碼是 cmdlet 自己的，不隨顯示語言改變；其他任何錯誤都是真的失敗。
        if ($_.FullyQualifiedErrorId -notmatch "^CmdletizationQuery_NotFound") {
            Add-CheckResult -Category "IT 診斷資料" -Check "IPv4 預設路由" -Status "ERROR" -Message "無法讀取路由表。" -Details ((Get-ExceptionDetails $_) + [Environment]::NewLine + "手動驗證：route print -4") -Diagnostics (Get-ExceptionDiagnostics $_) -Tag "routes" -Scope "IT" | Out-Null
            return
        }
        $routes = @()
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
        # 項目是在哪張介面上學到的，供下面的存取點提示使用（PR #54，第 1 回合）；arp -a 備援不印介面索引，由它提供位址時為 0。
        $neighborIfIndex = 0
        try {
            if (Get-Command Get-NetNeighbor -ErrorAction SilentlyContinue) {
                $neighbor = Get-NetNeighbor -IPAddress ([string]$gateway) -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($null -ne $neighbor) {
                    $state = [string]$neighbor.State
                    $mac = [string]$neighbor.LinkLayerAddress
                    $neighborIfIndex = ConvertTo-IntSafe (Get-PropertyValue $neighbor "InterfaceIndex" 0) 0
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
        # backlog #61 的另一半：存取點就是閘道嗎？在無線機器上想把空氣和有線分開之前最該先知道的一件事，以提示的身分
        # 發表——Get-AccessPointGatewayText 說明比較的每一種形狀能確立什麼、不能確立什麼——閘道的網卡是有線的、或 Wi-Fi
        # 資料沒有讀取時，這一行不出現。
        $accessPointEvidence = Get-AccessPointGatewayEvidence -Gateway ([string]$gateway) -GatewayMac $mac -PrimaryAdapters $PrimaryAdapters -Samples @($script:WifiAssociationSamples) -InterfaceIndex $neighborIfIndex
        $accessPointLine = [string]$accessPointEvidence.Text
        if (-not [string]::IsNullOrWhiteSpace($accessPointLine)) { $lines += $accessPointLine }
        if ($null -eq $script:GatewayNeighborRows) { $script:GatewayNeighborRows = New-Object System.Collections.ArrayList }
        $lines += "檢測方式：Get-NetNeighbor -AddressFamily IPv4（備援：arp -a）"
        $lines += "手動驗證：arp -a"
        $message = "閘道 {0}：鄰居狀態 {1}，MAC {2}。" -f $gateway, $state, (ConvertTo-DisplayString $mac)
        $neighborRow = Add-CheckResult -Category "IT 診斷資料" -Check "閘道鄰居（ARP）" -Status "INFO" -Message $message -Details ($lines -join [Environment]::NewLine) -Tag "gateway-neighbor" -Scope "IT"
        # 留下來，讓 Update-AccessPointGatewayHints 在最後一次存取點樣本出現後再比一次（PR #54，第 2 回合）——重比對比的是位址和關係，
        # 印出的句子放在旁邊（第 3 回合）。
        [void]$script:GatewayNeighborRows.Add([pscustomobject]@{ Row = $neighborRow; Gateway = [string]$gateway; Mac = [string]$mac; InterfaceIndex = $neighborIfIndex; Hint = [string]$accessPointLine; Bssid = [string]$accessPointEvidence.Bssid; Relation = [string]$accessPointEvidence.Relation })
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
        $address = (ConvertTo-SafeString (Get-PropertyValue $candidate "Address" "")).Trim()
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

function Add-DroppedTargetResults {
    # 交給了這次執行卻沒有被檢測的目標，會在它結果本該出現的地方、它所屬的區段留下一列（backlog #39）。只把判定
    # 從啟動提示上拿掉、卻不補這一列，等於把錯誤藏起來而不是降權：讀者往答案該在的地方看，看到的是空白，於是把
    # 「沒有」讀成「沒有人要求過這項檢查」。這一列沒有權重，理由和那則提示一樣——它是關於輸入的事實。
    foreach ($dropped in @($script:DroppedTargets)) {
        $kind = [string]$dropped.Kind
        $value = [string]$dropped.Value
        if ($kind -eq "Tcp") {
            Add-CheckResult -Category "TCP 連線" -Check ("額外 TCP " + $value) -Status "ERROR" -Message "這個目標交給了這次執行，但沒有被檢測，因為它不是 host:port 格式，或主機名稱無法使用。" -Details ("輸入的值：{0}。沒有送出任何封包，所以這一列不說明網路的任何事；整體結果不因它改變。" -f $value) -Tag "tcp" -Weightless | Out-Null
        }
    }
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
    param(
        [string]$ClassName,
        [int]$Attempts = 1,
        [System.Collections.IList]$FailedAttempts,
        [string[]]$RequireProperty
    )

    # 本工具所有 CIM/WMI 查詢的唯一入口；從 1.2.8 起，這裡也是查詢可以嘗試一次以上的地方（backlog #38）。效能計數器
    # 讀取若耗盡八秒上限、第二次才成功，代價是這幾秒；若不再嘗試，代價是整個量測——而依 2026-09-08 的證據，付出代價
    # 的正是剛解壓縮的副本裡的第一次執行，也就是使用者出問題時會做的那一次。每一次失敗的嘗試都會連同耗時記錄到
    # $FailedAttempts，無論後續是否成功：不留痕跡的重試無法解釋它拉長的取樣窗。未指定 -Attempts 的呼叫者維持原本的
    # 單次嘗試。
    if ($Attempts -lt 1) { $Attempts = 1 }
    $lastError = $null
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        $attemptStarted = Get-Date
        try {
            $instance = $null
            if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) {
                $instance = Get-CimInstance -ClassName $ClassName -OperationTimeoutSec 8 -ErrorAction Stop
            }
            elseif (Get-Command Get-WmiObject -ErrorAction SilentlyContinue) {
                $instance = Get-WmiObject -Class $ClassName -ErrorAction Stop
            }
            else {
                throw "系統沒有可用的 CIM/WMI 指令。"
            }
            # 查詢沒有回傳任何東西，或回傳的實例缺少呼叫者要的欄位，同樣是一次失敗的讀取，和拋出例外沒有兩樣——
            # 這個檢查搬進嘗試之前是寫在迴圈外的，於是逾時有第二次機會、它卻沒有（PR #40 第 5 輪）。只有指名欄位的
            # 呼叫者會被檢查；窗前讀取不指名任何欄位，因為它的讀數本來就要丟棄。
            if (@($RequireProperty).Count -gt 0) {
                if ($instance -is [array]) {
                    $instance = $instance | Select-Object -First 1
                }
                if ($null -eq $instance) {
                    throw "效能計數器類別 $ClassName 沒有回傳資料。"
                }
                foreach ($requiredName in $RequireProperty) {
                    if ($null -eq $instance.PSObject.Properties[$requiredName]) {
                        throw "效能計數器類別 $ClassName 缺少必要欄位。"
                    }
                }
            }
            return $instance
        }
        catch {
            $lastError = $_
            if ($null -ne $FailedAttempts) {
                [void]$FailedAttempts.Add([pscustomobject][ordered]@{
                    ClassName = $ClassName
                    Attempt   = $attempt
                    Seconds   = [math]::Round(((Get-Date) - $attemptStarted).TotalSeconds, 1)
                    Error     = Get-ExceptionDetails $_
                })
            }
        }
    }
    throw $lastError
}

function Get-CountThreshold {
    param(
        [string]$Name,
        [int]$DefaultValue
    )

    # 計數類門檻變成增量比較所需的無號數，就只有這一個地方，因為缺陷出在那個轉型上（PR #49 第 1 輪）：對負數做
    # [uint64] 會拋例外，所以只要設定檔寫了 TcpRetransmissionCriticalCount = -1，整個重傳分析就會變成一列「無法
    # 檢查」，而不是把那個值報出來 —— 設定檢查看的是計數類門檻的型別與整數性，從來沒看過正負號。三個呼叫點裡有
    # 兩個在 1.2.10 之前就存在，所以修的是這裡，不是那個新加的鍵。負值會退回內建預設值，跟這個工具處理任何其他
    # 用不了的值一樣，而 Test-ConfigurationSemantics 現在也會在「設定值門檻」那一列說出來。
    $value = ConvertTo-IntSafe (Get-PropertyValue $script:Config.Thresholds $Name $DefaultValue) $DefaultValue
    if ($value -lt 0) { $value = $DefaultValue }
    return [uint64]$value
}

function Get-TcpCounterSnapshot {
    param([switch]$WarmUp)

    $snapshot = @{}
    $errors = New-Object System.Collections.ArrayList
    $failedAttempts = New-Object System.Collections.ArrayList
    $warmUpFailures = New-Object System.Collections.ArrayList

    # -WarmUp：每個類別做一次會被丟掉的讀取，而且自成一輪，排在任何計數器被讀取之前（backlog #38）。自成一輪正是
    # 重點（PR #40 第 3 輪）：和量測讀取交錯時，TCPv6 的暖身落在 TCPv4 的基準時間戳之後，也就是落在 TCPv4 的窗內
    # ——而只是「比較慢」的暖身，正是這個機制要吸收的啟動成本，會拉長那個窗、卻留不下任何失敗紀錄可以解釋它。放在
    # 這裡，每次暖身都在兩個基準時間戳之前，對它們的延後一視同仁，因此拉長不了任何窗。讀數會被丟棄——這不是量測，
    # 它失敗也不是發現。失敗只記錄、不做別的，因為「一個工作階段的第一次讀取是不是失敗的那一次」正是這個項目還沒
    # 有答案的問題。
    if ($WarmUp) {
        foreach ($protocol in @("TCPv4", "TCPv6")) {
            $className = "Win32_PerfRawData_Tcpip_$protocol"
            $warmUpAttempts = New-Object System.Collections.ArrayList
            try {
                Get-CimOrWmiInstance -ClassName $className -FailedAttempts $warmUpAttempts | Out-Null
            }
            catch {
                # 刻意丟棄：這次嘗試已經記在 $warmUpAttempts，而這次讀取本來就不是讀數。
            }
            foreach ($item in $warmUpAttempts) {
                [void]$warmUpFailures.Add([pscustomobject][ordered]@{
                    Protocol = $protocol
                    Phase    = "warm-up"
                    Attempt  = $item.Attempt
                    Seconds  = $item.Seconds
                    Error    = $item.Error
                })
            }
        }
    }

    foreach ($protocol in @("TCPv4", "TCPv6")) {
        $className = "Win32_PerfRawData_Tcpip_$protocol"
        $readAttempts = New-Object System.Collections.ArrayList
        try {
            $counter = Get-CimOrWmiInstance -ClassName $className -Attempts 2 -FailedAttempts $readAttempts -RequireProperty @("SegmentsSentPersec", "SegmentsRetransmittedPersec")

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
        foreach ($item in $readAttempts) {
            [void]$failedAttempts.Add([pscustomobject][ordered]@{
                Protocol = $protocol
                Phase    = "read"
                Attempt  = $item.Attempt
                Seconds  = $item.Seconds
                Error    = $item.Error
            })
        }
    }

    # Timestamp 是整份快照完成的時間；每個通訊協定另有自己的時間戳，在它自己的讀取回來時取得，1.2.8 起取樣時間就是
    # 由那一對時間戳計算。FailedAttempts 保留量測讀取中失敗的嘗試（即使之後成功也保留）；WarmUpFailures 則是取樣窗
    # 之前那次會被丟棄的讀取失敗的紀錄。
    return [pscustomobject][ordered]@{
        Timestamp      = Get-Date
        Counters       = $snapshot
        Errors         = @($errors)
        FailedAttempts = @($failedAttempts)
        WarmUpFailures = @($warmUpFailures)
    }
}

function Format-TcpAttemptList {
    param([object[]]$Attempts)

    # 失敗讀取要怎麼稱呼，只有這一個地方決定，因為有三種列會引用它：讀不到的計數器那一列、窗內承受了該失敗的通訊
    # 協定那一列，以及列出某個通訊協定自己失敗讀取的那一行。窗前的讀取不論出現在哪裡都會標明，這樣它的秒數就不會
    # 被當成某個窗裡的秒數。
    return ((@($Attempts) | ForEach-Object {
        if ([string]$_.Phase -eq "warm-up") { "{0} #{1}（窗前捨棄的讀取）" -f $_.Protocol, $_.Attempt }
        elseif ([string]$_.Phase -eq "extension") { "{0} #{1}（延長取樣窗時的那次讀取）" -f $_.Protocol, $_.Attempt }
        elseif ([string]$_.Phase -eq "interval") { "{0} #{1}（取樣之間的讀取）" -f $_.Protocol, $_.Attempt }
        else { "{0} #{1}" -f $_.Protocol, $_.Attempt }
    }) -join ", ")
}

function Get-TcpAttemptSeconds {
    param([object[]]$Attempts)

    if (@($Attempts).Count -eq 0) { return 0 }
    return [math]::Round(((@($Attempts) | Measure-Object -Property Seconds -Sum).Sum), 1)
}

function Get-TcpReadFailureLines {
    param(
        [object]$Snapshot,
        [string]$Protocol,
        [switch]$Ending
    )

    # 一列在單一快照中，對於自己這個通訊協定失敗的計數器讀取所要說的話——不論後續嘗試是否成功（backlog #38）：
    # 寫成一行，指明它屬於哪一次快照，窗前的讀取排在最前面，因為它最先發生。1.2.8 之前，逾時後才成功的讀取會交回
    # 乾淨的計數器、卻不留下它花掉幾秒的紀錄，該列也就無法解釋自己的取樣窗。這些秒數有哪些落在窗內是另一個問題，
    # 由下面那句補充回答；這一行講的是這個計數器，不是這個窗。讀取正常時什麼都不說：一列只解釋發生過的事，不解釋
    # 沒發生的事（backlog #40）。
    $lines = @()
    $failed = @()
    $failed += @(@(Get-PropertyValue $Snapshot "WarmUpFailures" @()) | Where-Object { [string]$_.Protocol -eq $Protocol })
    $failed += @(@(Get-PropertyValue $Snapshot "FailedAttempts" @()) | Where-Object { [string]$_.Protocol -eq $Protocol })
    if (@($failed).Count -gt 0) {
        if ($Ending) {
            $lines += ("取結束值時，這個通訊協定讀取失敗的嘗試：{0}（合計 {1} 秒）。" -f (Format-TcpAttemptList $failed), (Get-TcpAttemptSeconds $failed))
        }
        else {
            $lines += ("取基準值時，這個通訊協定讀取失敗的嘗試：{0}（合計 {1} 秒）。" -f (Format-TcpAttemptList $failed), (Get-TcpAttemptSeconds $failed))
        }
    }
    return $lines
}

function Compare-TcpCounters {
    param(
        [object]$Before,
        [object]$After
    )

    if ($null -eq $Before -or $null -eq $After) {
        Add-CheckResult -Category "TCP 重傳" -Check "系統計數器" -Status "ERROR" -Message "沒有完整的前後 TCP 計數器資料。" -Details "" -Tag "tcp-retransmissions" -Weightless | Out-Null
        return
    }

    # 每一次失敗的讀取一列，順序就是讀取的順序，後面附上嘗試紀錄（backlog #38）。狀態、檢查名稱與訊息維持重試出現
    # 之前的樣子——會掩蓋真實失敗的重試比不重試更糟——這一列多出來的是嘗試紀錄：不說明試過什麼的失敗，事後教不了
    # 任何事。逐份快照讀取，讓每個錯誤都配上它自己那份快照的嘗試紀錄；另一份快照若沒有為同一個通訊協定寫出自己的
    # 列，它的嘗試紀錄也一併附在這裡（PR #40 第 4 輪）。那正是它們原本會完全消失的情況：某個通訊協定的計數器在其中
    # 一份快照讀不到，就沒有讀數、也就沒有品質列，而品質列是唯一另一個會提到那些嘗試的地方。
    # backlog #65：窗內的讀取，每次執行一個狀態物件（關閉或從未開窗時則沒有）；說明讀取在哪裡停止的那一行，這個分析
    # 寫出的每一列都帶。
    $intervalState = $script:TcpIntervalSampling
    $intervalStopLines = @(Get-TcpIntervalStopLine -State $intervalState)
    foreach ($isEnding in @($false, $true)) {
        $snapshot = $Before
        $other = $After
        if ($isEnding) {
            $snapshot = $After
            $other = $Before
        }
        foreach ($errorItem in @($snapshot.Errors)) {
            $errorProtocol = [string]$errorItem.Protocol
            $errorDetails = @([string]$errorItem.Error) + @(Get-TcpReadFailureLines -Snapshot $snapshot -Protocol $errorProtocol -Ending:$isEnding)
            if (@(@($other.Errors) | Where-Object { [string]$_.Protocol -eq $errorProtocol }).Count -eq 0) {
                $errorDetails += @(Get-TcpReadFailureLines -Snapshot $other -Protocol $errorProtocol -Ending:(-not $isEnding))
            }
            $errorDetails += $intervalStopLines
            Add-CheckResult -Category "TCP 重傳" -Check ("{0} 計數器" -f $errorItem.Protocol) -Status "ERROR" -Message "無法讀取 TCP 重傳計數器。" -Details ((@($errorDetails) | Where-Object { $_ }) -join [Environment]::NewLine) -Diagnostics $errorItem.Diagnostics -Tag "tcp-retransmissions" -Weightless | Out-Null
        }
    }

    $warningPercent = ConvertTo-DoubleSafe (Get-PropertyValue $script:Config.Thresholds "TcpRetransmissionWarningPercent" 2) 2
    $criticalPercent = ConvertTo-DoubleSafe (Get-PropertyValue $script:Config.Thresholds "TcpRetransmissionCriticalPercent" 5) 5
    $criticalCount = Get-CountThreshold "TcpRetransmissionCriticalCount" 50
    $minimumSegments = Get-CountThreshold "MinimumTcpSegmentsForRate" 50
    $verdictFloor = Get-CountThreshold "MinimumTcpRetransmissionsForVerdict" 5
    # Get-TcpCounterSnapshot 讀取兩個通訊協定的順序，決定失敗的讀取落在誰的窗裡（backlog #38）。讀取是循序的，每個
    # 通訊協定的時間戳都在它自己的讀取回來時取得，因此會拉長某個窗的，是那些延後了它的結束時間戳、卻沒有延後它的
    # 起始時間戳的讀取。在結束快照裡，那是排在這個通訊協定之前（含自己）的每次讀取；在基準快照裡，則是排在它*之後*
    # 的每次讀取——卡住的 TCPv6 基準讀取會把 TCPv6 的起始時間戳連同後面整段執行一起往後推，卻推不動 TCPv4 的，
    # 於是它正好落在 TCPv4 的窗內（PR #40 第 1 輪：初稿說基準快照的失敗一律無害，那只對最先讀取的通訊協定成立）。
    # 窗前讀取兩份清單都不列入，因為它們全都在兩個基準時間戳之前完成，拉長不了任何窗（第 3 輪）。
    $readOrder = @("TCPv4", "TCPv6")
    # 結束時間戳來自「延長過一次的窗」的那些通訊協定（backlog #51）。延長那一輪失敗的讀取，落在這些通訊協定的窗
    # 內，而落在其他每一個通訊協定的窗外，因為延長沒有關掉的那些，保留的是它原本就有的時間戳（PR #49 第 1 輪）。
    $extendedProtocols = @(Get-PropertyValue $After "ExtendedProtocols" @())
    $configuredSeconds = [math]::Max(1, (ConvertTo-IntSafe (Get-PropertyValue $script:RunOptions "SampleSeconds" 8) 8))
    # backlog #52：這次執行有替自己的連線計時時，系統級的列就指出歸屬得了的數字在哪裡；沒有時——沒有 TCP 目標，或沒有一個
    # 有回應——就沒有東西可指，這一行寧可不寫，也不承諾一個不存在的列。
    $attributionLine = $null
    if ($script:TcpConnectSampleCount -gt 0) { $attributionLine = "「TCP 連線」那幾列有這一列給不了的東西：工具自己對單一具名目標的連線、逐次計時，以及各次不得不重送的 SYN。" }

    foreach ($protocol in @("TCPv4", "TCPv6")) {
        if (-not $Before.Counters.ContainsKey($protocol) -or -not $After.Counters.ContainsKey($protocol)) {
            continue
        }

        $start = $Before.Counters[$protocol]
        $end = $After.Counters[$protocol]
        $sentDeltaDouble = [double]$end.SegmentsSent - [double]$start.SegmentsSent
        $retransDeltaDouble = [double]$end.Retransmitted - [double]$start.Retransmitted

        # 一列對於它背後那些讀取應該交代的證據，在任何分支可能提前返回之前就先備妥：計數器重設那一列以前是寫完就
        # 跳過這幾行的，於是在計數器重設的執行裡，失敗後又被救回的讀取就消失了（PR #40 第 5 輪）。這個通訊協定的每
        # 一列都會帶著它們。
        $sampleSeconds = [math]::Round((New-TimeSpan -Start $start.Timestamp -End $end.Timestamp).TotalSeconds, 1)
        $durationLine = "取樣時間：$sampleSeconds 秒（設定的最短時間：$configuredSeconds 秒）"
        $evidenceLines = @()
        $evidenceLines += @(Get-TcpReadFailureLines -Snapshot $Before -Protocol $protocol)
        $selfIndex = $readOrder.IndexOf($protocol)
        $windowAttempts = @()
        $windowAttempts += @(@(Get-PropertyValue $Before "FailedAttempts" @()) | Where-Object { $readOrder.IndexOf([string]$_.Protocol) -gt $selfIndex })
        $closedByExtension = ($extendedProtocols -contains $protocol)
        $windowAttempts += @(@(Get-PropertyValue $After "FailedAttempts" @()) | Where-Object { $readOrder.IndexOf([string]$_.Protocol) -ge 0 -and $readOrder.IndexOf([string]$_.Protocol) -le $selfIndex -and (([string]$_.Phase -ne "extension") -or $closedByExtension) })
        # backlog #65：窗內失敗的讀取落在兩個通訊協定的窗裡——它在兩個基準時間戳之後、兩個結束時間戳之前——只有延長
        # 取樣窗期間的那些例外，它們只落在延長真的關閉的那些窗裡。
        # PR #56 第 7 輪：下面定位區塊的「沒有讀數」那一句也由同一份清單決定——延長期間失敗的讀取，對延長沒有關閉的
        # 通訊協定來說落在它的窗之外，它的區塊不能說讀取停在一個它們根本沒到過的窗裡。
        $intervalInsideAttempts = @(@(Get-PropertyValue $intervalState "FailedAttempts" @()) | Where-Object { (-not [bool]$_.Extension) -or $closedByExtension })
        $windowAttempts += $intervalInsideAttempts
        $windowNote = ""
        if (@($windowAttempts).Count -gt 0) {
            $windowNote = ("補充：這 {0} 秒當中有 {1} 秒花在取樣窗內失敗的計數器讀取（{2}）；設定的最短時間是 {3} 秒。" -f $sampleSeconds, (Get-TcpAttemptSeconds $windowAttempts), (Format-TcpAttemptList $windowAttempts), $configuredSeconds)
            $evidenceLines += $windowNote
        }
        # 上面那一行不能算、但這一列仍然要寫出來的讀取（PR #49 第 1 輪）：窗被延長過、而這個通訊協定的延長讀取失敗
        # 時，保留的是第一次的讀數，它的窗早就關了，所以那些秒數在窗外。backlog #38 的承諾是「每一次失敗的嘗試都
        # 連同它花掉的秒數保留下來」，所以改用一行寫清楚它們落在哪裡。
        $outsideAttempts = @(@(Get-PropertyValue $After "FailedAttempts" @()) | Where-Object { [string]$_.Protocol -eq $protocol -and [string]$_.Phase -eq "extension" -and -not $closedByExtension })
        # backlog #65：還有這個通訊協定自己在延長期間失敗的窗內讀取，理由相同。
        $outsideAttempts += @(@(Get-PropertyValue $intervalState "FailedAttempts" @()) | Where-Object { [string]$_.Protocol -eq $protocol -and [bool]$_.Extension -and -not $closedByExtension })
        if (@($outsideAttempts).Count -gt 0) {
            $evidenceLines += ("本通訊協定在延長取樣窗時失敗的計數器讀取：{0}（合計 {1} 秒）。這個通訊協定的窗當時已經關閉，所以那些秒數不屬於上面的 {2} 秒。" -f (Format-TcpAttemptList $outsideAttempts), (Get-TcpAttemptSeconds $outsideAttempts), $sampleSeconds)
        }

        $evidenceLines += $intervalStopLines

        if ($sentDeltaDouble -lt 0 -or $retransDeltaDouble -lt 0) {
            # 即使增量算不出來，窗仍然是事實，所以這一列會印出它跨越的時間長度與相應證據。不該印的是關於「上面的
            # 增量」那句話——這一列根本沒有增量。補充句只講秒數與讀取，那句關於增量的話由有增量的那一列自己加上
            # （PR #40 第 7 輪）。
            $resetDetails = @($durationLine, ("起始 Sent={0}, Retrans={1}; 結束 Sent={2}, Retrans={3}" -f $start.SegmentsSent, $start.Retransmitted, $end.SegmentsSent, $end.Retransmitted)) + $evidenceLines
            Add-CheckResult -Category "TCP 重傳" -Check $protocol -Status "ERROR" -Message "計數器在檢測期間重設或溢位，無法計算增量。" -Details ((@($resetDetails) | Where-Object { $_ }) -join [Environment]::NewLine) -Tag "tcp-retransmissions" -Weightless | Out-Null
            continue
        }

        $sentDelta = [uint64]$sentDeltaDouble
        $retransDelta = [uint64]$retransDeltaDouble
        $rate = 0.0
        if ($sentDelta -gt 0) {
            $rate = [math]::Round(($retransDelta * 100.0 / $sentDelta), 3)
            $script:RetransmissionRateComputed = $true
        }

        # 窗內沒有任何 segment 被算成「送出」時就沒有比值，不論重傳增量是多少（PR #50 第 2 輪）：在那裡印 0% 是在描述一個
        # 沒有定義的比值，下面那句還會宣稱做了一次根本沒發生的除法。sent 計數器不含只帶先前傳過位元組的 segment，所以這種窗
        # 仍可能帶著重傳次數——下面的小樣本規則會報告它——這一列就說它能說的：有幾次，以及為什麼沒有比例。
        $rateLine = "近似重傳比例：$rate%"
        $denominatorLine = "百分比除的是什麼：這台電腦在取樣窗內送出的 segment 數，照 Segments Sent/sec 計數器的算法——含 ACK，但不含只帶重傳位元組的 segment；新位元組和重傳位元組同在一個 segment 裡時兩個計數都算到它。這是本工具自己的比值，分母和公開發表的重傳率不同，不能拿來比較。"
        if ($sentDelta -eq 0) {
            $rateLine = "近似重傳比例：無法計算——取樣窗內沒有任何 segment 被算成送出"
            if ($retransDelta -gt 0) { $rateLine += ("（仍算到 {0} 個重傳 segment：sent 計數器不含只帶先前傳過位元組的 segment）" -f $retransDelta) }
            $denominatorLine = $null
        }
        $details = (@(
            $durationLine,
            "傳送 TCP Segments 增量：$sentDelta",
            "重傳 Segments 增量：$retransDelta",
            $rateLine,
            "起始累積：Sent=$($start.SegmentsSent), Retrans=$($start.Retransmitted)",
            "結束累積：Sent=$($end.SegmentsSent), Retrans=$($end.Retransmitted)",
            "檢測方式：Win32_PerfRawData_Tcpip_$protocol 累積計數器，取樣期間增量。",
            "手動驗證：Get-CimInstance Win32_PerfRawData_Tcpip_$protocol（取樣兩次比較增量）",
            "說明：此為整台電腦在檢測期間的系統級統計，不只包含單一程式。",
            $attributionLine,
            # backlog #57：分母是 Windows 定義下的 Segments Sent/sec 計數器，這一列要把它說出來，因為印出來的百分比並不是
            # 任何公開發表的重傳率所指的那個量。句子依據計數器自己的說明文字與 Microsoft 的 TCP Object 參考（皆於 2026-09-10
            # 讀取）：Segments Sent 不含「只帶重傳位元組」的 segment，Segments Retransmitted 則算入每一個「帶有一個以上先前
            # 傳過的位元組」的 segment，所以混合的 segment 兩邊都算。這一列只說分母是什麼，不說數字偏哪一邊：裡面的 ACK 把它
            # 拉得比資料 segment 比例低、被排除的純重傳把它拉得比位元組比值高，而這兩個偏差都沒有在任何一次執行上量化過。
            $denominatorLine
        ) | Where-Object { $null -ne $_ }) -join [Environment]::NewLine

        if ($rate -gt 100) {
            $details += [Environment]::NewLine + "補充：比例超過 100% 代表重傳的是取樣窗之前送出的 segment——請視為比值而非百分比。"
        }
        # 逐通訊協定判斷，不看快照層級的旗標（PR #49 第 2 輪）：延長讀取失敗的通訊協定保留的是第一次的讀數，
        # 它的窗並沒有被延長，而下面那一行還會說它的窗當時已經關閉——同一列自相矛盾。
        if ($closedByExtension) {
            $details += [Environment]::NewLine + "取樣窗已延長一次：第一個窗結束時傳送量低於 MinimumTcpSegmentsForRate，而窗內至少有一次重傳——那是唯一一種「等久一點真的有用」的情況。"
        }

        foreach ($line in $evidenceLines) {
            $details += [Environment]::NewLine + $line
        }
        if ($windowNote -ne "") {
            $details += [Environment]::NewLine + "上面的增量仍然是這個通訊協定在所示窗內自己的計數。"
        }

        # backlog #65：窗內數到重傳時，說它們落在哪裡。這張表是這個通訊協定自己的、由它自己的時間戳算出，這幾行不做任何判定。
        if ($null -ne $intervalState -and $intervalState.IntervalSeconds -gt 0 -and $retransDelta -gt 0) {
            $intervalTable = @(Get-TcpIntervalTable -Protocol $protocol -Start $start -End $end -Reads @(Get-PropertyValue $intervalState "Reads" @()))
            foreach ($line in @(Get-TcpDistributionLines -Protocol $protocol -Intervals $intervalTable -RetransDelta $retransDelta -SampleSeconds (New-TimeSpan -Start $start.Timestamp -End $end.Timestamp).TotalSeconds -State $intervalState -FailedInside $intervalInsideAttempts)) {
                $details += [Environment]::NewLine + $line
            }
        }

        if ($sentDelta -eq 0 -and $retransDelta -eq 0) {
            Add-CheckResult -Category "TCP 重傳" -Check $protocol -Status "INFO" -Message "取樣期間沒有足夠的 TCP 傳送流量，未發現重傳，但不能據此判定長時間狀況。" -Details $details -Tag "tcp-retransmissions" | Out-Null
            continue
        }

        if ($sentDelta -lt $minimumSegments) {
            if ($retransDelta -gt 0) {
                # 1.2.10 之前這是 WARN。1.2.8（已結案的 #39）已經把它變成 weightless，所以那個徽章不再決定任何
                # 事情，它唯一的作用就是在一句「這不是證據」旁邊把一列標成需要注意——這正是這一列不該帶的矛盾。
                # 這是 #51 要求「決定一個帶著重傳的小樣本代表什麼」的回答：它是那次重傳的紀錄，不是一個判定。
                # 沒有任何 segment 被算成送出的窗沒有比例，訊息——報告裡排在詳細資料前面的那一行——也不能印出一個來
                # （PR #50 第 3 輪）。使用手冊引用的那個片語保持不變。
                $smallMessage = ("流量樣本偏少，但觀察到 {0} 次重傳（近似 {1}%）。" -f $retransDelta, $rate)
                if ($sentDelta -eq 0) { $smallMessage = ("流量樣本偏少，但觀察到 {0} 次重傳；沒有任何 segment 被算成送出，算不出比例。" -f $retransDelta) }
                Add-CheckResult -Category "TCP 重傳" -Check $protocol -Status "INFO" -Message $smallMessage -Details $details -Tag "tcp-retransmissions" -Weightless | Out-Null
            }
            else {
                Add-CheckResult -Category "TCP 重傳" -Check $protocol -Status "INFO" -Message ("樣本只有 {0} 個傳送 segment，未觀察到重傳。" -f $sentDelta) -Details $details -Tag "tcp-retransmissions" | Out-Null
            }
            continue
        }

        # backlog #51：一個比例要有足夠多的事件撐著，才算得上一個判定。在這個工具願意評分的最小樣本
        # （MinimumTcpSegmentsForRate，出貨值 50）上，一次重傳就是 2 %，剛好就是警告門檻本身；三次是 6 %，
        # 光靠比例就會 FAIL。這個下限算的是事件次數，而且**兩個分支都要過**：只擋警告分支的下限，會讓最粗
        # 的樣本判得比它上面那一階更重。它的代價也被同一段算式框住：要被壓下來，必須比例達到警告門檻、同時
        # 事件數少於下限，也就是 sent <= (下限 - 1) x 100 / warningPercent——在出貨的 5 與 2 % 下是 200 個傳送
        # segment，正好是「一次重傳只值警告門檻四分之一」的樣本數。超過這個數，什麼都不會被壓下來。
        if ($retransDelta -lt $verdictFloor -and $rate -ge $warningPercent) {
            $details += [Environment]::NewLine + ("這個比例背後的重傳次數不到 {0}，因此只報出比例而不下判定：在這個樣本數上，單單一次重傳就足以把它推過門檻。這一列不會改變整體結果。" -f $verdictFloor)
            Add-CheckResult -Category "TCP 重傳" -Check $protocol -Status "INFO" -Message ("傳送 {0}、重傳 {1}，近似重傳比例 {2}%——重傳次數太少，不足以評分。" -f $sentDelta, $retransDelta, $rate) -Details $details -Tag "tcp-retransmissions" -Weightless | Out-Null
            continue
        }

        # backlog #63 的決議，2026-09-11：這個次數是比例的信心修飾語——它可以把比例已經下出來的判定加重，但
        # 永遠不能自己造出一個判定。所以 WARN 那一行的獨立次數觸發條件拿掉了，FAIL 那一行的「兩者並存」留著。
        # 理由是一道界線：TcpRetransmissionCriticalCount ÷ TcpRetransmissionWarningPercent（出貨的 50 與 2 %
        # 下是 2 500 個傳送 segment）。在那之下，要達到 50 次重傳，比例早就到警告門檻了，獨立觸發什麼也沒加；
        # 在那之上，它唯一的作用就是在比例低於本工具自己門檻的樣本上發出警告。
        # 而且每一列都要說出是哪一個規則決定的，因為在這之前讀的人分辨不出來（#63 的驗收條件）。
        $status = "PASS"
        $decided = ""
        if ($rate -ge $criticalPercent) {
            $status = "FAIL"
            $decided = ("由比例決定：{0}% 已達或超過嚴重門檻 {1}%。" -f $rate, $criticalPercent)
        }
        elseif ($retransDelta -ge $criticalCount -and $rate -ge $warningPercent) {
            $status = "FAIL"
            $decided = ("由比例與次數共同決定：{0}% 已達或超過警告門檻 {1}%，而且 {2} 次重傳已達或超過 {3}。" -f $rate, $warningPercent, $retransDelta, $criticalCount)
        }
        elseif ($rate -ge $warningPercent) {
            $status = "WARN"
            $decided = ("由比例決定：{0}% 已達或超過警告門檻 {1}%。" -f $rate, $warningPercent)
        }
        if ($decided -ne "") { $details += [Environment]::NewLine + $decided }

        Add-CheckResult -Category "TCP 重傳" -Check $protocol -Status $status -Message ("傳送 {0}、重傳 {1}，近似重傳比例 {2}%。" -f $sentDelta, $retransDelta, $rate) -Details $details -Tag "tcp-retransmissions" | Out-Null
    }
}

function Test-TcpSampleNeedsExtension {
    param(
        [object]$Before,
        [object]$After
    )

    # backlog #51：唯一一種「窗開久一點真的能定案」的情況。傳送量低於 MinimumTcpSegmentsForRate 時，這個工具
    # 根本不會給這個樣本評分；而在那底下又帶著重傳的樣本，就是那個模稜兩可的情況——這一列只能說「發生過重傳」，
    # 說不出「多常發生」。閒置到什麼都沒送、或送得很少而且一次都沒重傳的機器，並不模稜兩可：等久一點只會換來
    # 更多的「什麼都沒有」。已經到達或超過下限的樣本也不延長：它已經有比例了，而「比例背後的事件太少」是次數
    # 下限要管的事，不是窗長要管的。
    # Since it decides whether a step runs at all, it is asked outside one, so it answers rather than throws:
    # a snapshot without counters is a run whose reads failed, and those rows are written either way.
    if ($null -eq $Before -or $null -eq $After) { return $false }
    if ($null -eq $Before.Counters -or $null -eq $After.Counters) { return $false }
    $minimumSegments = [double](Get-CountThreshold "MinimumTcpSegmentsForRate" 50)
    foreach ($protocol in @("TCPv4", "TCPv6")) {
        if (-not $Before.Counters.ContainsKey($protocol) -or -not $After.Counters.ContainsKey($protocol)) { continue }
        $sentDelta = [double]$After.Counters[$protocol].SegmentsSent - [double]$Before.Counters[$protocol].SegmentsSent
        $retransDelta = [double]$After.Counters[$protocol].Retransmitted - [double]$Before.Counters[$protocol].Retransmitted
        # 計數器倒退代表重置或溢位，這個增量沒有意義，不能拿來決定要不要多等一段（backlog #38 的那一列會自己
        # 說明這件事）。
        if ($sentDelta -lt 0 -or $retransDelta -le 0) { continue }
        if ($sentDelta -lt $minimumSegments) { return $true }
    }
    return $false
}

function Merge-TcpEndingSnapshot {
    param(
        [object]$Original,
        [object]$Extended
    )

    # 延長取樣窗之後的結束快照（backlog #51）。每個通訊協定各自以「比較晚的那次讀取」為準，因為它關的是比較
    # 長的那個窗；哪個通訊協定晚讀失敗了，就沿用第一次的讀數，所以延長一個窗永遠不會弄丟一列已經量到的結果。
    # 只有兩次讀取都沒讀到的通訊協定才會保留錯誤，而兩次讀取裡失敗的嘗試全部保留——它們花掉的秒數，跟這個窗
    # 裡其他任何秒數一樣，都是這個窗的秒數。
    if ($null -eq $Extended) { return $Original }
    if ($null -eq $Original) { return $Extended }
    $counters = @{}
    foreach ($protocol in @($Original.Counters.Keys)) { $counters[$protocol] = $Original.Counters[$protocol] }
    foreach ($protocol in @($Extended.Counters.Keys)) { $counters[$protocol] = $Extended.Counters[$protocol] }
    $errors = @()
    foreach ($item in (@($Original.Errors) + @($Extended.Errors))) {
        if ($null -eq $item) { continue }
        if ($counters.ContainsKey([string]$item.Protocol)) { continue }
        if (@($errors | Where-Object { [string]$_.Protocol -eq [string]$item.Protocol }).Count -gt 0) { continue }
        $errors += $item
    }
    # 在延長那一輪失敗的讀取會被標記出來，而延長實際關掉了哪些通訊協定的窗也會寫下來，因為「那些秒數落在誰的窗
    # 裡」對每個通訊協定並不是同一個問題（PR #49 第 1 輪）。延長讀取失敗的通訊協定，保留的是第一次的讀數與隨它而
    # 來的時間戳，所以它的窗在延長開始之前就結束了：把延長的秒數算進去，會印出比那個窗還長的失敗秒數。而延長真的
    # 關掉的通訊協定，它的窗確實包含那些秒數。Compare-TcpCounters 用這兩個欄位分別回答這兩個問題；什麼都沒有被
    # 丟掉，那一列仍然會把每一次失敗的嘗試都寫出來。
    $extendedAttempts = @()
    foreach ($item in @(Get-PropertyValue $Extended "FailedAttempts" @())) {
        if ($null -eq $item) { continue }
        $extendedAttempts += [pscustomobject][ordered]@{ Protocol = $item.Protocol; Phase = "extension"; Attempt = $item.Attempt; Seconds = $item.Seconds; Error = $item.Error }
    }
    return [pscustomobject][ordered]@{
        Timestamp      = $Extended.Timestamp
        Counters       = $counters
        Errors         = @($errors)
        FailedAttempts = @(@(Get-PropertyValue $Original "FailedAttempts" @()) + $extendedAttempts)
        WarmUpFailures = @(@(Get-PropertyValue $Original "WarmUpFailures" @()) + @(Get-PropertyValue $Extended "WarmUpFailures" @()))
        Extended       = $true
        ExtendedProtocols = @(@($Extended.Counters.Keys) | ForEach-Object { [string]$_ })
    }
}

# ---------------------------------------------------------------------------------------------------------------------
# 取樣窗內的讀取（backlog #65；v1.2.14）。窗頭窗尾各讀一次計數器，每個通訊協定只得到一對數字，而整個窗的總量分不出
# 「窗裡某十秒內重傳了 50 次」與「50 次平均散布在整個窗」——那正是 1.2.10 移除獨立次數觸發條件（已結案的 #63）之前
# 它會反應的突發。所以計數器在窗內再讀幾次，至少相隔 Tests.RetransmissionIntervalSeconds 秒（出廠 2 秒，0 代表關閉），
# 有量測結果的列在整個窗的數字旁邊，把重傳放到時間軸上。讓它站得住的規則：讀取只在主執行緒進行——每個步驟之後
# 檢查一次到期、等待期間每秒檢查一次——所以各段都有時間戳、長短不一，間隔是最小值而不是週期；窗內的讀取不是量測
# 本身，每個類別只嘗試一次、絕不第二次；第一次失敗的讀取就結束這次執行的窗內取樣，所以讀取會逾時的機器只付一次
# 逾時、不是每段付一次；失敗的讀取連同秒數保留並在列上點名，但不自成一列；一段的樣本太小撐不起比例，所以不算比例、
# 沒有門檻讀它、這裡沒有任何東西會改變狀態。建置前先量過（參考機器，2026-09-13）：兩個類別讀一次，中位數 102 ms、
# 第 95 百分位 140 ms，所以八秒窗內讀三次約三分之一秒，而且大多落在執行本來就要睡掉的等待裡。
# ---------------------------------------------------------------------------------------------------------------------
function Get-TcpIntervalSeconds {
    # Tests.RetransmissionIntervalSeconds 的唯一規則：整數秒，出廠 2，0 代表窗內不讀；其他值——小數、負數、文字——
    # 都退回出廠的 2，Test-ConfigurationSemantics 會這樣報告它。
    $value = Get-PropertyValue $script:Config.Tests "RetransmissionIntervalSeconds" 2
    if ($null -eq $value -or -not (Test-IsWholeNumber $value)) { return 2 }
    $seconds = ConvertTo-IntSafe $value 2
    if ($seconds -lt 0) { return 2 }
    return $seconds
}

function Start-TcpIntervalSampling {
    param(
        [int]$IntervalSeconds,
        [datetime]$Since,
        [switch]$Extension,
        [object]$Boundary,
        [object]$Deadline
    )

    # 打開窗內讀取：從基準時間戳開始，延長取樣窗（backlog #51）時再從延長的起點開始。被失敗讀取停掉的取樣在延長期間
    # 也維持停止——規則是每次執行只付一次逾時——間隔為 0 則什麼都不開。狀態是每次執行一個物件，隨結果一起清除。
    if ($null -eq $script:TcpIntervalSampling) {
        $script:TcpIntervalSampling = [pscustomobject][ordered]@{
            Active          = $false
            IntervalSeconds = [math]::Max(0, $IntervalSeconds)
            LastRead        = $Since
            Extension       = $false
            Reads           = New-Object System.Collections.ArrayList
            FailedAttempts  = New-Object System.Collections.ArrayList
            StoppedAt       = $null
            StopReason      = ""
            Deadline        = $null
        }
    }
    $state = $script:TcpIntervalSampling
    $state.Extension = [bool]$Extension
    $state.LastRead = $Since
    # PR #56 第 5 輪：窗的期限——開窗的時間戳加上設定的最短時間——隨狀態一起帶著，期限一過，不論哪條路來問，到期檢查
    # 都不再讀。第 2、3 輪各關掉一條路（等待的最後一次睡眠、等待之後的步驟）；分散 ping 探測的停頓和超過最短時間的
    # 步驟是第三條，把規則放在一個地方才不會有第四條。
    if ($Deadline -is [datetime]) { $state.Deadline = $Deadline }
    # PR #56 第 2 輪：延長取樣窗時，關閉第一個窗的那次讀數是表裡的一個點，這樣第一個窗與延長段的各段才分得開；它不花任何
    # 成本——那是量測自己的讀取——而且不論取樣是否還開著都保留。
    if ($null -ne $Boundary -and $null -ne $Boundary.Counters) {
        [void]$state.Reads.Add([pscustomobject][ordered]@{ Timestamp = $Boundary.Timestamp; Counters = $Boundary.Counters; FailedAttempts = @(); Extension = $false; Boundary = $true })
    }
    if ($state.IntervalSeconds -le 0 -or $null -ne $state.StoppedAt) {
        $state.Active = $false
        return
    }
    $state.Active = $true
}

function Stop-TcpIntervalSampling {
    # 在讀取結束值之前關閉，這樣就不會有任何這類讀取落在關窗的時間戳之後；狀態本身留著，因為各列要靠它寫出來。
    if ($null -ne $script:TcpIntervalSampling) { $script:TcpIntervalSampling.Active = $false }
}

function Read-TcpIntervalCounters {
    # 兩個類別各讀一次、各只嘗試「一次」：第二次嘗試是為了保住量測（backlog #38），而這次讀取不是量測。回傳的形狀
    # 和快照的讀數相同，所以各段可以用同樣的欄位算出來；失敗的部分連同秒數記下，就像每一次失敗的讀取一樣。
    $counters = @{}
    $failed = New-Object System.Collections.ArrayList
    foreach ($protocol in @("TCPv4", "TCPv6")) {
        $className = "Win32_PerfRawData_Tcpip_$protocol"
        $readAttempts = New-Object System.Collections.ArrayList
        try {
            $counter = Get-CimOrWmiInstance -ClassName $className -FailedAttempts $readAttempts -RequireProperty @("SegmentsSentPersec", "SegmentsRetransmittedPersec")
            $counters[$protocol] = [pscustomobject][ordered]@{
                Protocol      = $protocol
                Timestamp     = Get-Date
                SegmentsSent  = ConvertTo-UInt64Safe $counter.SegmentsSentPersec
                Retransmitted = ConvertTo-UInt64Safe $counter.SegmentsRetransmittedPersec
            }
        }
        catch {
            # 該次嘗試已經在 $readAttempts 裡：窗內讀取失敗是列上的一個事實，不是這次執行的錯誤。
        }
        foreach ($item in $readAttempts) {
            [void]$failed.Add([pscustomobject][ordered]@{
                Protocol = $protocol
                Phase    = "interval"
                Attempt  = $item.Attempt
                Seconds  = $item.Seconds
                Error    = $item.Error
            })
        }
        # PR #56 第 1 輪：這一輪讀取在第一個失敗的類別就停下。逾時之後再讀下一個類別，等於在剛拒絕過的提供者身上再花八秒——
        # 上限是每次執行一次逾時，不是每個類別一次——沒讀到的那個類別，這次讀取本來會關閉的那一段就併入相鄰的一段。
        if (@($readAttempts).Count -gt 0) { break }
    }
    return [pscustomobject][ordered]@{
        Timestamp      = Get-Date
        Counters       = $counters
        FailedAttempts = @($failed)
    }
}

function Invoke-TcpIntervalReadIfDue {
    # 到期檢查，每個步驟之後與等待期間每秒各呼叫一次。只有上一次讀取距今至少一個設定間隔時才讀，所以較長的步驟
    # 只是產生較長的一段——各段都有時間戳，列上會印出每段的長度。它絕不擲出例外：任何失敗都當成一次失敗的讀取，
    # 記錄下來並結束取樣，因為每個步驟之後都會跑的檢查絕不能讓步驟失敗。
    $state = $script:TcpIntervalSampling
    if ($null -eq $state -or -not $state.Active) { return }
    # PR #56 第 5 輪：窗的期限一過，不論從哪條路來都不再讀——那次讀取會落在最短時間之後，把整個成本疊到執行上——取樣也就在
    # 這裡徹底關閉。
    if ($null -ne $state.Deadline -and (Get-Date) -ge $state.Deadline) { $state.Active = $false; return }
    if (((Get-Date) - $state.LastRead).TotalSeconds -lt $state.IntervalSeconds) { return }
    $reading = $null
    try {
        $reading = Read-TcpIntervalCounters
    }
    catch {
        $reading = [pscustomobject][ordered]@{
            Timestamp      = Get-Date
            Counters       = @{}
            FailedAttempts = @([pscustomobject][ordered]@{ Protocol = "TCP"; Phase = "interval"; Attempt = 1; Seconds = 0; Error = (Get-ExceptionDetails $_) })
        }
    }
    $reading | Add-Member -NotePropertyName "Extension" -NotePropertyValue ([bool]$state.Extension) -Force
    [void]$state.Reads.Add($reading)
    foreach ($item in @($reading.FailedAttempts)) {
        [void]$state.FailedAttempts.Add([pscustomobject][ordered]@{
            Protocol  = $item.Protocol
            Phase     = $item.Phase
            Attempt   = $item.Attempt
            Seconds   = $item.Seconds
            Error     = $item.Error
            Extension = [bool]$state.Extension
        })
    }
    $state.LastRead = $reading.Timestamp
    if (@($reading.FailedAttempts).Count -gt 0) {
        $state.Active = $false
        $state.StoppedAt = $reading.Timestamp
        $state.StopReason = ((@($reading.FailedAttempts) | ForEach-Object { [string]$_.Protocol }) -join ", ")
    }
}

function Get-TcpIntervalTable {
    param(
        [string]$Protocol,
        [object]$Start,
        [object]$End,
        [object[]]$Reads
    )

    # 一個通訊協定的窗切成的各段：它的基準讀數、窗內每一次它的讀數、它的結束讀數——依時間戳排序，所以落在這個通訊
    # 協定結束時間戳之後的讀數（只延長了另一個通訊協定的窗時）光靠時間戳就被排除。每段帶自己的秒數與增量；空表代表
    # 窗內有讀數倒退，列上會這麼說。
    if ($null -eq $Start -or $null -eq $End) { return @() }
    $points = @($Start)
    $points += @(@($Reads) | Where-Object { $null -ne $_ -and $null -ne $_.Counters -and $_.Counters.ContainsKey($Protocol) } | ForEach-Object { $_.Counters[$Protocol] } | Where-Object { $_.Timestamp -gt $Start.Timestamp -and $_.Timestamp -lt $End.Timestamp } | Sort-Object -Property Timestamp)
    $points += $End
    $table = @()
    for ($i = 1; $i -lt $points.Count; $i++) {
        $from = $points[$i - 1]
        $to = $points[$i]
        $sent = [double]$to.SegmentsSent - [double]$from.SegmentsSent
        $retrans = [double]$to.Retransmitted - [double]$from.Retransmitted
        if ($sent -lt 0 -or $retrans -lt 0) { return @() }
        $table += [pscustomobject][ordered]@{
            Index         = $i
            FromSeconds   = [math]::Round(($from.Timestamp - $Start.Timestamp).TotalSeconds, 1)
            ToSeconds     = [math]::Round(($to.Timestamp - $Start.Timestamp).TotalSeconds, 1)
            Seconds       = ($to.Timestamp - $from.Timestamp).TotalSeconds
            Sent          = [uint64]$sent
            Retransmitted = [uint64]$retrans
        }
    }
    return @($table)
}

function Get-TcpDistributionLines {
    param(
        [string]$Protocol,
        [object[]]$Intervals,
        [uint64]$RetransDelta,
        [double]$SampleSeconds,
        [object]$State,
        [object[]]$FailedInside
    )

    # 有量測結果的列對「重傳落在哪裡」要說的話——只在有重傳時才說：沒有重傳的窗沒有東西可放，一列只解釋發生過的事
    # （backlog #40）。重傳最多的一段會並列寫出它佔全部重傳的比例與佔整個窗秒數的比例，讓讀者自己看出突發——大部分
    # 的重傳集中在一小段時間裡——而工具不替它下這個字：沒有形容詞、沒有門檻、也不替任何一段算比例，因為安靜的機器
    # 上兩秒的一段正是已結案的 #51 所說的小樣本。
    $lines = @()
    if ($null -eq $State -or $State.IntervalSeconds -le 0 -or $RetransDelta -eq 0) { return $lines }
    $table = @($Intervals)
    if ($table.Count -eq 0) {
        $lines += "窗內有一次計數器讀數倒退了，所以無法把重傳放到時間軸上。"
        return $lines
    }
    if ($table.Count -lt 2) {
        # PR #56 第 4 輪：窗內沒有讀數的窗要說出原因，而「沒有一次到期」只是原因之一——讀取可能在這個窗還沒有窗內讀數之前，
        # 就停在一次失敗的讀取上，而那次讀取連同秒數已經在列上點名；旁邊再寫一句「沒有一次到期」就自相矛盾了。
        # 第 7 輪：落在「這個」通訊協定的窗內的失敗讀取——呼叫端知道，狀態物件不知道。
        if (@($FailedInside).Count -gt 0) {
            $lines += "窗內的讀取在這個窗還沒有任何窗內讀數之前，就停在一次失敗的讀取上——那次讀取和它的秒數在上面點名了——所以無法把重傳放到時間軸上。"
        }
        else {
            $lines += ("這個窗的兩次取樣之間沒有任何一次計數器讀取落在窗內，所以無法把重傳放到時間軸上：這些讀取安排在各項檢查之間與等待期間，至少每 {0} 秒一次，而窗關閉前沒有一次到期。" -f $State.IntervalSeconds)
        }
        return $lines
    }
    $lines += ("重傳落在窗內的哪一段（計數器在窗內至少每 {0} 秒再讀一次：{1} 次讀數、{2} 段）：" -f $State.IntervalSeconds, ($table.Count + 1), $table.Count)
    foreach ($interval in $table) {
        $lines += ("  {0}-{1} 秒：傳送 {2}，重傳 {3}" -f $interval.FromSeconds, $interval.ToSeconds, $interval.Sent, $interval.Retransmitted)
    }
    # 重傳最多者優先；相同時取較短的一段，再相同取較早的一段。
    $worst = @($table | Sort-Object -Property @{ Expression = "Retransmitted"; Descending = $true }, @{ Expression = "Seconds"; Descending = $false }, @{ Expression = "Index"; Descending = $false })[0]
    $share = [math]::Round(100.0 * [double]$worst.Retransmitted / [double]$RetransDelta)
    $timeShare = 0
    if ($SampleSeconds -gt 0) { $timeShare = [math]::Round(100.0 * $worst.Seconds / $SampleSeconds) }
    $lines += ("重傳最多的一段：{1} 次當中的 {0} 次（{2}%）落在 {3} 秒內，佔整個窗的 {4}%。" -f $worst.Retransmitted, $RetransDelta, $share, [math]::Round($worst.Seconds, 1), $timeShare)
    $lines += "這幾行只把重傳放到時間軸上，別無他意：一段的樣本太小，撐不起一個比例，所以不算；重送的 segment 不等於遺失的 segment；這裡沒有任何數字會改變這一列的狀態。"
    return $lines
}

function Get-TcpIntervalStopLine {
    param([object]$State)

    # 取樣停止時，這個分析寫出的每一列都帶這一行，因為失敗的讀取不論落在哪裡都要保留並點名（backlog #38），而失敗
    # 之前的讀取仍然成立。
    if ($null -eq $State -or $null -eq $State.StoppedAt) { return @() }
    return @(("窗內的讀取在 {0} 停止：{1} 的一次讀取失敗（{2} 秒）；之前的各段照樣成立，最後一段一直算到結束取樣。" -f $State.StoppedAt.ToString("HH:mm:ss"), $State.StopReason, (Get-TcpAttemptSeconds @($State.FailedAttempts))))
}

# ---------------------------------------------------------------------------------------------------------------------
# Wi-Fi 重傳（backlog #61 的重傳計數器半邊；v1.2.12）。802.11 MAC 會把沒收到確認的框重送，而重送成功的框被吸收成延遲：IP 與
# TCP 看不到遺失，ping 列看到的是慢一點的回覆，TCP 重傳列則什麼都看不到。所以重傳率是唯一能把這張網卡與基地台之間的空氣、
# 和基地台後面的一切分開的數字，而 Windows 只透過 Native Wifi API 提供它：以 wlan_intf_opcode_statistics 呼叫 WlanQueryInterface
# 會回傳 WLAN_STATISTICS，其中 PhyCounters 陣列帶著每個 PHY 的 MAC 框計數器。netsh 沒有對應項，所以讀取器是透過 Add-Type 的
# P/Invoke——一支原本是純 PowerShell 的腳本裡的 unmanaged code。v1.2 設計筆記為射頻資料拒絕過這個選擇，因為 netsh 供得了；
# 這一項採用它，因為別無他法（2026-09-12 決定，五點寫在 backlog 的 Status 行）。編譯在參考機上約 0.7 秒，磁碟上不留任何東西；
# 拒絕 C# 編譯器或記憶體內組件的應用程式控制政策會擋下它，這一列就寫明並且不決定任何結果。
#
# 寫這段之前量到的事（2026-09-10 與 2026-09-12，Intel Wi-Fi 6E AX211、Windows 11）：查詢不需要提權；六個 PHY 的緩衝區是 1088
# 位元組，正是文件版面所預測的；而驅動程式把介面的總計寫進「每一個」PHY 項目——六列完全相同的計數器，同步變動。所以項目之間
# 絕不相加：介面的數字是傳送框差值最大的那個項目，這一列寫出有幾個項目變動、是否一致。逐 PHY 歸屬框的驅動程式在單一 PHY
# 的執行裡會給出同樣的答案，而換過 PHY 的執行會被少算，不會被算六次。比率是重傳 ÷（傳送 + 放棄）：ullRetryCount 算的是
# 重送一次以上後成功的框，ullFailedCount 是到達重傳上限後放棄的框，ullTransmittedFrameCount 不含後者；ullMultipleRetryCount
# 是 ullRetryCount 的子集，照子集列出。計數器是這次關聯的累積值，所以報告的是這次執行前後的差值，並沿用 TCP 列的計數倒退
# 分支。這一列不決定任何結果：無線重傳率沒有任何有依據的門檻（backlog #56）。
# ---------------------------------------------------------------------------------------------------------------------

function Get-WlanApiType {
    # 兩個無線讀取器共用的那幾行 P/Invoke——重試計數器（backlog #61）與介面狀態（backlog #62）——每個程序只編譯一次，之後
    # 以名稱找回來。編譯不成的原因用回傳的、不用擲出的，因為發問的那個讀取器的列要寫出原因：應用程式控制原則可以拒絕
    # Add-Type，那是這台機器的事實，不是它網路的事實。
    $result = [pscustomobject][ordered]@{ Type = $null; Error = ""; ErrorText = ""; Diagnostics = "" }
    $apiType = "NetworkHealthCheck.WlanApi" -as [type]
    if ($null -ne $apiType) { $result.Type = $apiType; return $result }
    $definition = @'
[DllImport("wlanapi.dll")] public static extern uint WlanOpenHandle(uint dwClientVersion, IntPtr pReserved, out uint pdwNegotiatedVersion, out IntPtr phClientHandle);
[DllImport("wlanapi.dll")] public static extern uint WlanCloseHandle(IntPtr hClientHandle, IntPtr pReserved);
[DllImport("wlanapi.dll")] public static extern uint WlanEnumInterfaces(IntPtr hClientHandle, IntPtr pReserved, out IntPtr ppInterfaceList);
[DllImport("wlanapi.dll")] public static extern uint WlanQueryInterface(IntPtr hClientHandle, ref Guid pInterfaceGuid, int OpCode, IntPtr pReserved, out uint pdwDataSize, out IntPtr ppData, IntPtr pWlanOpcodeValueType);
[DllImport("wlanapi.dll")] public static extern void WlanFreeMemory(IntPtr pMemory);
'@
    try {
        Add-Type -Namespace NetworkHealthCheck -Name WlanApi -MemberDefinition $definition -ErrorAction Stop
        $apiType = "NetworkHealthCheck.WlanApi" -as [type]
    }
    catch {
        $result.Error = "addtype"
        $result.ErrorText = Get-ExceptionDetails $_
        $result.Diagnostics = Get-ExceptionDiagnostics $_
        return $result
    }
    if ($null -eq $apiType) {
        $result.Error = "addtype"
        $result.ErrorText = "型別已編譯但無法載入。"
        return $result
    }
    $result.Type = $apiType
    return $result
}

function Get-LocationConsentState {
    # Windows 記錄的位置權限，讀出來當作第二個見證：連線查詢被拒之後，這一列要先有它才可以把位置設定指認為原因（PR #55，
    # 第 1 回合）：錯誤 5 只是存取被拒、沒有更多，限制 WLAN 查詢的原則、或沒有這道閘門的 Windows，否則都會被寫成權限問題、
    # 被指向錯的設定。權限存放區（CapabilityAccessManager\ConsentStore\location）每一層一個值——使用者、裝置、桌面應用程式，
    # 以及 NonPackaged 底下 netsh 自己的項目——任一層是 Deny 就是拒絕（2026-09-12 在使用者層與裝置層量到）；Wi-Fi 細節被擋在
    # 它後面，是從 Windows 11 24H2、build 26100 開始的事。讀不到的存放區不算見證。
    $consent = [pscustomobject][ordered]@{
        Known  = $false
        Denied = $false
        Build  = 0
        Gated  = $false
        Levels = @()
        Text   = ""
    }
    try { $consent.Build = [int][Environment]::OSVersion.Version.Build } catch { $consent.Build = 0 }
    $consent.Gated = ($consent.Build -ge 26100)
    $store = "Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location"
    $levels = @(
        [pscustomobject]@{ Name = "使用者"; Path = ("HKCU:\" + $store) },
        [pscustomobject]@{ Name = "裝置"; Path = ("HKLM:\" + $store) },
        [pscustomobject]@{ Name = "桌面應用程式"; Path = ("HKCU:\" + $store + "\NonPackaged") },
        [pscustomobject]@{ Name = "netsh"; Path = ("HKCU:\" + $store + "\NonPackaged\C:#Windows#System32#netsh.exe") }
    )
    $readings = @()
    foreach ($level in $levels) {
        $value = "（無項目）"
        if (Test-Path -LiteralPath $level.Path) {
            $value = "（空白）"
            try {
                $consent.Known = $true
                $raw = [string](Get-PropertyValue (Get-ItemProperty -LiteralPath $level.Path -ErrorAction Stop) "Value" "")
                if (-not [string]::IsNullOrWhiteSpace($raw)) { $value = $raw }
            }
            catch { $value = "（無法讀取）" }
        }
        if ($value -eq "Deny") { $consent.Denied = $true }
        $readings += [pscustomobject]@{ Name = $level.Name; Value = $value }
    }
    $consent.Levels = @($readings)
    $consent.Text = (@($readings | ForEach-Object { "{0} {1}" -f $_.Name, $_.Value }) -join "、")
    return $consent
}

function Get-RadioSwitchState {
    param([int]$On, [int]$Off, [int]$Read)

    # 從讀到的 PHY 項目得出一個無線電開關的字（PR #55，第 8 回合）：任一 PHY 回報開就是開，讀到的每個 PHY 都回報關才是關，其餘
    # 為未知——驅動程式把一部分 PHY 回報為關、其餘不確定，並沒有說無線電是關的，據此把開關寫成關閉的列就是宣稱得比讀到的多。
    if ($On -gt 0) { return "on" }
    if ($Read -gt 0 -and $Off -eq $Read) { return "off" }
    return "unknown"
}

function Get-WlanInterfaceStates {
    # WLAN 服務自己對每張無線介面的說法，一次讀取（backlog #62）：介面清單與各介面的連線狀態（WlanEnumInterfaces）、頻道
    # （WlanQueryInterface，opcode 8）與無線電開關（opcode 4）——而對服務稱為已連線的介面，再問服務願不願意把連線細節交給
    # 這個程序。最後這一問用的正是 netsh 拿網路名稱、存取點、訊號與速率的那個呼叫（opcode 7，目前連線），而且只看回傳碼：
    # 5（存取被拒）是 Windows 11 24H2 及之後在桌面應用程式不被允許存取位置時的回答——也就是 netsh 一個介面都不印的那個
    # 設定——2026-09-12 在參考機器量到，當時清單、狀態、頻道、無線電開關與重試計數器都仍讀得到。不論內容為何都回傳
    # 這個信封，原因代碼和重試讀取器相同（addtype、open、enumerate、error）。
    $reading = [pscustomobject][ordered]@{
        Timestamp   = Get-Date
        Interfaces  = @()
        Error       = ""
        ErrorText   = ""
        Diagnostics = ""
        LocationConsent = $null
    }
    $reading.LocationConsent = Get-LocationConsentState
    $api = Get-WlanApiType
    if ($null -eq $api.Type) {
        $reading.Error = $api.Error
        $reading.ErrorText = $api.ErrorText
        $reading.Diagnostics = $api.Diagnostics
        return $reading
    }
    $apiType = $api.Type
    $handle = [IntPtr]::Zero
    $list = [IntPtr]::Zero
    try {
        $version = [uint32]0
        $code = $apiType::WlanOpenHandle(2, [IntPtr]::Zero, [ref]$version, [ref]$handle)
        if ($code -ne 0) {
            $reading.Error = "open"
            $reading.ErrorText = Get-Win32ErrorText $code
            return $reading
        }
        $code = $apiType::WlanEnumInterfaces($handle, [IntPtr]::Zero, [ref]$list)
        if ($code -ne 0) {
            $reading.Error = "enumerate"
            $reading.ErrorText = Get-Win32ErrorText $code
            return $reading
        }
        $count = [System.Runtime.InteropServices.Marshal]::ReadInt32($list, 0)
        $interfaces = @()
        for ($index = 0; $index -lt $count; $index++) {
            # WLAN_INTERFACE_INFO_LIST：兩個 DWORD，接著是一筆筆 WLAN_INTERFACE_INFO——一個 GUID、256 個 WCHAR 的描述、
            # 一個 DWORD 的狀態——每筆 532 位元組，和重試讀取器讀的版面相同。
            $base = [IntPtr]($list.ToInt64() + 8 + ($index * 532))
            $guidBytes = New-Object byte[] 16
            [System.Runtime.InteropServices.Marshal]::Copy($base, $guidBytes, 0, 16)
            $guid = New-Object System.Guid (,$guidBytes)
            $description = ([System.Runtime.InteropServices.Marshal]::PtrToStringUni([IntPtr]($base.ToInt64() + 16), 256)).TrimEnd([char]0)
            $state = [System.Runtime.InteropServices.Marshal]::ReadInt32($base, 528)
            $entry = [pscustomobject][ordered]@{
                Guid            = $guid.ToString().ToLowerInvariant()
                Description     = $description
                State           = $state
                Channel         = $null
                RadioSoftware   = ""
                RadioHardware   = ""
                ConnectionQuery = -1
            }
            $queryGuid = $guid
            # 頻道：一個 DWORD，查詢有回答就讀，沒回答就留空。
            $size = [uint32]0
            $data = [IntPtr]::Zero
            $code = $apiType::WlanQueryInterface($handle, [ref]$queryGuid, 8, [IntPtr]::Zero, [ref]$size, [ref]$data, [IntPtr]::Zero)
            if ($code -eq 0) {
                try { if ($size -ge 4) { $entry.Channel = [System.Runtime.InteropServices.Marshal]::ReadInt32($data, 0) } }
                finally { $apiType::WlanFreeMemory($data) }
            }
            # 無線電開關：WLAN_RADIO_STATE 是一個 DWORD 的數量，接著每個 PHY 三個 DWORD——PHY 索引、軟體狀態、硬體狀態，
            # 各以 1 表示開、2 表示關。每個 PHY 都回報關才算關，任一個回報開就算開，其餘為未知。
            $size = [uint32]0
            $data = [IntPtr]::Zero
            $code = $apiType::WlanQueryInterface($handle, [ref]$queryGuid, 4, [IntPtr]::Zero, [ref]$size, [ref]$data, [IntPtr]::Zero)
            if ($code -eq 0) {
                try {
                    $phys = 0
                    if ($size -ge 4) { $phys = [System.Runtime.InteropServices.Marshal]::ReadInt32($data, 0) }
                    $softwareOn = 0; $softwareOff = 0; $hardwareOn = 0; $hardwareOff = 0; $phyRead = 0
                    for ($phy = 0; $phy -lt $phys; $phy++) {
                        $offset = 4 + ($phy * 12)
                        if ($size -lt ($offset + 12)) { break }
                        $phyRead++
                        $softwareState = [System.Runtime.InteropServices.Marshal]::ReadInt32($data, $offset + 4)
                        $hardwareState = [System.Runtime.InteropServices.Marshal]::ReadInt32($data, $offset + 8)
                        if ($softwareState -eq 1) { $softwareOn++ } elseif ($softwareState -eq 2) { $softwareOff++ }
                        if ($hardwareState -eq 1) { $hardwareOn++ } elseif ($hardwareState -eq 2) { $hardwareOff++ }
                    }
                    $entry.RadioSoftware = Get-RadioSwitchState -On $softwareOn -Off $softwareOff -Read $phyRead
                    $entry.RadioHardware = Get-RadioSwitchState -On $hardwareOn -Off $hardwareOff -Read $phyRead
                }
                finally { $apiType::WlanFreeMemory($data) }
            }
            # 連線查詢只看回傳碼，而且只在服務說已連線時才問：資料是 netsh 要印的，這個讀取器只想知道 netsh 印不印得出來。
            if ($state -eq 1) {
                $size = [uint32]0
                $data = [IntPtr]::Zero
                $code = $apiType::WlanQueryInterface($handle, [ref]$queryGuid, 7, [IntPtr]::Zero, [ref]$size, [ref]$data, [IntPtr]::Zero)
                $entry.ConnectionQuery = [int]$code
                if ($code -eq 0 -and $data -ne [IntPtr]::Zero) { $apiType::WlanFreeMemory($data) }
            }
            $interfaces += $entry
        }
        $reading.Interfaces = @($interfaces)
        $reading.Timestamp = Get-Date
        return $reading
    }
    catch {
        $reading.Error = "error"
        $reading.ErrorText = Get-ExceptionDetails $_
        $reading.Diagnostics = Get-ExceptionDiagnostics $_
        return $reading
    }
    finally {
        if ($list -ne [IntPtr]::Zero) { $apiType::WlanFreeMemory($list) }
        if ($handle -ne [IntPtr]::Zero) { [void]$apiType::WlanCloseHandle($handle, [IntPtr]::Zero) }
    }
}

function Get-WifiRetrySnapshot {
    # 每個無線介面 MAC 框計數器的一次讀取，沒有的話帶著原因。不論內容為何都回傳這個信封，和 TCP 快照一樣：由分析那一步
    # 寫出那一列，並附上證據。
    $snapshot = [pscustomobject][ordered]@{
        Timestamp   = Get-Date
        Interfaces  = @()
        Error       = ""
        ErrorText   = ""
        Diagnostics = ""
    }
    $api = Get-WlanApiType
    if ($null -eq $api.Type) {
        $snapshot.Error = $api.Error
        $snapshot.ErrorText = $api.ErrorText
        $snapshot.Diagnostics = $api.Diagnostics
        return $snapshot
    }
    $apiType = $api.Type

    $handle = [IntPtr]::Zero
    $list = [IntPtr]::Zero
    try {
        $version = [uint32]0
        $code = $apiType::WlanOpenHandle(2, [IntPtr]::Zero, [ref]$version, [ref]$handle)
        if ($code -ne 0) {
            $snapshot.Error = "open"
            $snapshot.ErrorText = Get-Win32ErrorText $code
            return $snapshot
        }
        $code = $apiType::WlanEnumInterfaces($handle, [IntPtr]::Zero, [ref]$list)
        if ($code -ne 0) {
            $snapshot.Error = "enumerate"
            $snapshot.ErrorText = Get-Win32ErrorText $code
            return $snapshot
        }
        $count = [System.Runtime.InteropServices.Marshal]::ReadInt32($list, 0)
        if ($count -le 0) {
            $snapshot.Error = "none"
            return $snapshot
        }
        $interfaces = @()
        for ($index = 0; $index -lt $count; $index++) {
            # WLAN_INTERFACE_INFO_LIST：兩個 DWORD，接著每個 WLAN_INTERFACE_INFO 項目是一個 GUID、256 個 WCHAR 的描述和一個
            # DWORD 狀態——每項 532 位元組。
            $base = [IntPtr]($list.ToInt64() + 8 + ($index * 532))
            $guidBytes = New-Object byte[] 16
            [System.Runtime.InteropServices.Marshal]::Copy($base, $guidBytes, 0, 16)
            $guid = New-Object System.Guid (,$guidBytes)
            $description = ([System.Runtime.InteropServices.Marshal]::PtrToStringUni([IntPtr]($base.ToInt64() + 16), 256)).TrimEnd([char]0)
            $state = [System.Runtime.InteropServices.Marshal]::ReadInt32($base, 528)
            $entry = [pscustomobject][ordered]@{
                Guid           = $guid.ToString()
                Description    = $description
                State          = $state
                Phys           = @()
                QueryError     = 0
                QueryErrorText = ""
            }
            $size = [uint32]0
            $data = [IntPtr]::Zero
            $queryGuid = $guid
            $code = $apiType::WlanQueryInterface($handle, [ref]$queryGuid, 0x10000101, [IntPtr]::Zero, [ref]$size, [ref]$data, [IntPtr]::Zero)
            if ($code -ne 0) {
                $entry.QueryError = [int]$code
                $entry.QueryErrorText = Get-Win32ErrorText $code
                $interfaces += $entry
                continue
            }
            try {
                # WLAN_STATISTICS：三個 ULONGLONG、兩個各十二個 ULONGLONG 的 WLAN_MAC_FRAME_STATISTICS、位移 216 的 dwNumberOfPhys
                # 及其對齊，然後從 224 起是每個十八個 ULONGLONG 的 WLAN_PHY_FRAME_STATISTICS 項目——六個 PHY 的 1088 位元組緩衝區
                # 證實了這個版面。比自己宣告的數量還短的緩衝區照實回報，不會讀過它的尾端。
                $numberOfPhys = 0
                if ($size -ge 220) { $numberOfPhys = [System.Runtime.InteropServices.Marshal]::ReadInt32($data, 216) }
                if ($numberOfPhys -lt 1 -or $size -lt (224 + ($numberOfPhys * 144))) {
                    $entry.QueryError = -1
                    $entry.QueryErrorText = ("統計緩衝區（{0} 位元組）容不下它宣告的 {1} 個 PHY 項目。" -f $size, $numberOfPhys)
                }
                else {
                    $phys = @()
                    for ($phy = 0; $phy -lt $numberOfPhys; $phy++) {
                        $offset = 224 + ($phy * 144)
                        $phys += [pscustomobject][ordered]@{
                            Index         = $phy
                            Transmitted   = [uint64][System.Runtime.InteropServices.Marshal]::ReadInt64($data, $offset)
                            Failed        = [uint64][System.Runtime.InteropServices.Marshal]::ReadInt64($data, $offset + 16)
                            Retry         = [uint64][System.Runtime.InteropServices.Marshal]::ReadInt64($data, $offset + 24)
                            MultipleRetry = [uint64][System.Runtime.InteropServices.Marshal]::ReadInt64($data, $offset + 32)
                            AckFailure    = [uint64][System.Runtime.InteropServices.Marshal]::ReadInt64($data, $offset + 72)
                            Received      = [uint64][System.Runtime.InteropServices.Marshal]::ReadInt64($data, $offset + 80)
                        }
                    }
                    $entry.Phys = $phys
                }
            }
            finally {
                $apiType::WlanFreeMemory($data)
            }
            $interfaces += $entry
        }
        $snapshot.Interfaces = @($interfaces)
        $snapshot.Timestamp = Get-Date
        return $snapshot
    }
    catch {
        $snapshot.Error = "error"
        $snapshot.ErrorText = Get-ExceptionDetails $_
        $snapshot.Diagnostics = Get-ExceptionDiagnostics $_
        return $snapshot
    }
    finally {
        if ($list -ne [IntPtr]::Zero) { $apiType::WlanFreeMemory($list) }
        if ($handle -ne [IntPtr]::Zero) { [void]$apiType::WlanCloseHandle($handle, [IntPtr]::Zero) }
    }
}

function Get-Win32ErrorText {
    param([object]$Code)
    $number = ConvertTo-IntSafe $Code 0
    $text = ""
    try { $text = (New-Object System.ComponentModel.Win32Exception($number)).Message } catch { $text = "" }
    if ([string]::IsNullOrWhiteSpace($text)) { return ("錯誤 {0}" -f $number) }
    return ("錯誤 {0}：{1}" -f $number, $text)
}

function Get-WifiInterfaceStateText {
    param([object]$State)
    switch (ConvertTo-IntSafe $State -1) {
        0 { return "未就緒" }
        1 { return "已連線" }
        2 { return "已建立 ad hoc 網路" }
        3 { return "中斷連線中" }
        4 { return "已中斷連線" }
        5 { return "關聯中" }
        6 { return "探索中" }
        7 { return "驗證中" }
    }
    return ("狀態 {0}" -f $State)
}

function Compare-WifiRetryCounters {
    param([object]$Before, [object]$After)

    $category = "Wi-Fi 重傳"
    if ($null -eq $Before -or $null -eq $After) {
        Add-CheckResult -Category $category -Check "無線重傳" -Status "ERROR" -Message "缺少完整的 Wi-Fi 重傳計數前後資料。" -Details "" -Tag "wifi-retry" -Weightless | Out-Null
        return
    }

    # 取不到的快照說明原因，說一次，而且那一列不計權重：讀取器不存在是這台機器的事實，不是它網路的量測。沒有無線介面是
    # 一般有線機器的情形，也照那樣讀。
    $bothNone = ([string]$Before.Error -eq "none" -and [string]$After.Error -eq "none")
    foreach ($pair in @(@{ Snapshot = $Before; Side = "開始時"; Other = $After }, @{ Snapshot = $After; Side = "結束時"; Other = $Before })) {
        $snapshot = $pair.Snapshot
        if ([string]::IsNullOrWhiteSpace([string]$snapshot.Error)) { continue }
        $reason = [string]$snapshot.Error
        $status = "ERROR"
        $message = ""
        switch ($reason) {
            "none"      { if ($bothNone) { $status = "INFO"; $message = "這台電腦沒有無線介面，所以沒有無線重傳數字；連線的統計看 TCP 重傳那幾列。" } else { $message = "兩次讀取只有一次列出了無線介面（{0}沒有），所以無法計算差值：網卡在檢測期間被啟用或停用，或另一次讀取失敗了。" -f $pair.Side } }
            "addtype"   { $message = "無法讀取 Wi-Fi 重傳計數器：讀取器（執行時編譯的一個小型 P/Invoke 型別）無法編譯或載入，應用程式控制政策可能會拒絕它。" }
            "open"      { $message = "無法讀取 Wi-Fi 重傳計數器：WLAN 服務沒有回應（{0}）。" -f $snapshot.ErrorText }
            "enumerate" { $message = "無法讀取 Wi-Fi 重傳計數器：無法列出無線介面（{0}）。" -f $snapshot.ErrorText }
            default     { $message = "無法讀取 Wi-Fi 重傳計數器（{0}）。" -f $pair.Side }
        }
        # 第一行以原因代碼結尾——語言中立的記號，像標籤一樣——chain 的 oracle 靠它把這列彙總列和帶同樣標籤、同樣狀態的
        # 逐介面錯誤列分開（PR #52 第 2 輪）。
        $details = @(
            ("讀取{0}：{1}" -f $pair.Side, $reason),
            $(if (-not [string]::IsNullOrWhiteSpace([string]$snapshot.ErrorText)) { [string]$snapshot.ErrorText } else { $null }),
            $(if (-not $bothNone -and -not [string]::IsNullOrWhiteSpace([string]$pair.Other.Error)) { "另一次讀取：{0} {1}" -f $pair.Other.Error, $pair.Other.ErrorText } else { $null }),
            "方法：Native Wifi API，透過 P/Invoke（wlanapi.dll）以 wlan_intf_opcode_statistics 呼叫 WlanQueryInterface，在執行前後各讀一次。",
            "說明：這一列不決定任何結果；它不存在時，連線的統計看 TCP 重傳列與 ping 列，而無線重傳在這兩者裡都看不到。"
        )
        Add-CheckResult -Category $category -Check "無線重傳" -Status $status -Message $message -Details ((@($details) | Where-Object { $null -ne $_ }) -join [Environment]::NewLine) -Diagnostics ([string]$snapshot.Diagnostics) -Tag "wifi-retry" -Weightless | Out-Null
        return
    }

    $seconds = [math]::Round(($After.Timestamp - $Before.Timestamp).TotalSeconds, 1)
    # 方法那幾行在每一列逐介面的列上都一樣，所以只建一次（第 5 輪把它們移出迴圈）。
    $methodLines = @(
        "方法：Native Wifi API，透過 P/Invoke（wlanapi.dll）以 wlan_intf_opcode_statistics 呼叫 WlanQueryInterface；MAC 框累積計數器在執行前後各讀一次，取視窗內的差值。",
        "手動檢查：沒有內建指令會印出這些計數器；API 是唯一的讀法。",
        "說明：網卡因為沒收到確認而重送的 802.11 框會被吸收成延遲，所以在 TCP 重傳率和 ping 遺失率裡都看不到；這是這張網卡和它的基地台之間的空氣，包含視窗內所有程式的流量。這一列不決定任何結果：無線重傳率沒有任何有依據的門檻。"
    )
    foreach ($ending in @($After.Interfaces)) {
        $starting = @(@($Before.Interfaces) | Where-Object { [string]$_.Guid -eq [string]$ending.Guid } | Select-Object -First 1)
        $description = ConvertTo-DisplayString $ending.Description
        $guidLine = "介面 GUID：{0}" -f $ending.Guid
        $stateLine = "連線狀態：開始時{0}，結束時{1}。" -f $(if ($starting.Count -gt 0) { Get-WifiInterfaceStateText $starting[0].State } else { "未列出" }), (Get-WifiInterfaceStateText $ending.State)
        if ($starting.Count -eq 0) {
            Add-CheckResult -Category $category -Check "無線重傳" -Status "ERROR" -Message ("{0}：這個介面在檢測開始時不存在，所以沒有差值。" -f $description) -Details ((@($stateLine, $guidLine) + $methodLines) -join [Environment]::NewLine) -Tag "wifi-retry" -Weightless | Out-Null
            continue
        }
        $start = $starting[0]
        if ($start.QueryError -ne 0 -or $ending.QueryError -ne 0) {
            $which = $(if ($start.QueryError -ne 0) { $start.QueryErrorText } else { $ending.QueryErrorText })
            Add-CheckResult -Category $category -Check "無線重傳" -Status "ERROR" -Message ("{0}：統計查詢失敗（{1}）。" -f $description, $which) -Details ((@($stateLine, $guidLine) + $methodLines) -join [Environment]::NewLine) -Tag "wifi-retry" -Weightless | Out-Null
            continue
        }

        # PHY 規則寫在套用它的地方：逐項目算差值，傳送差值最大的項目是介面的數字，項目之間絕不相加（這一段的開頭說了為什麼）。
        $deltas = @()
        foreach ($endPhy in @($ending.Phys)) {
            $startPhy = @(@($start.Phys) | Where-Object { $_.Index -eq $endPhy.Index } | Select-Object -First 1)
            if ($startPhy.Count -eq 0) { continue }
            $deltas += [pscustomobject][ordered]@{
                Index         = $endPhy.Index
                Start         = $startPhy[0]
                End           = $endPhy
                Transmitted   = [double]$endPhy.Transmitted - [double]$startPhy[0].Transmitted
                Failed        = [double]$endPhy.Failed - [double]$startPhy[0].Failed
                Retry         = [double]$endPhy.Retry - [double]$startPhy[0].Retry
                MultipleRetry = [double]$endPhy.MultipleRetry - [double]$startPhy[0].MultipleRetry
                AckFailure    = [double]$endPhy.AckFailure - [double]$startPhy[0].AckFailure
                Received      = [double]$endPhy.Received - [double]$startPhy[0].Received
            }
        }
        if ($deltas.Count -eq 0) {
            Add-CheckResult -Category $category -Check "無線重傳" -Status "ERROR" -Message ("{0}：兩次讀取沒有共同的 PHY 項目，所以沒有差值。" -f $description) -Details ((@($stateLine, $guidLine) + $methodLines) -join [Environment]::NewLine) -Tag "wifi-retry" -Weightless | Out-Null
            continue
        }
        $backwards = @($deltas | Where-Object { $_.Transmitted -lt 0 -or $_.Failed -lt 0 -or $_.Retry -lt 0 -or $_.MultipleRetry -lt 0 -or $_.AckFailure -lt 0 -or $_.Received -lt 0 })
        if ($backwards.Count -gt 0) {
            $resetLines = @(("取樣視窗：{0} 秒。" -f $seconds), $stateLine, $guidLine)
            foreach ($d in $backwards) {
                $resetLines += ("項目 {0}：開始 Transmitted={1}、Failed={2}、Retry={3}、MultipleRetry={4}；結束 Transmitted={5}、Failed={6}、Retry={7}、MultipleRetry={8}" -f $d.Index, $d.Start.Transmitted, $d.Start.Failed, $d.Start.Retry, $d.Start.MultipleRetry, $d.End.Transmitted, $d.End.Failed, $d.End.Retry, $d.End.MultipleRetry)
            }
            Add-CheckResult -Category $category -Check "無線重傳" -Status "ERROR" -Message ("{0}：計數器在檢測期間倒退——網卡重新連線或驅動程式重設了它們——所以無法計算差值。" -f $description) -Details ((@($resetLines) + $methodLines) -join [Environment]::NewLine) -Tag "wifi-retry" -Weightless | Out-Null
            continue
        }
        $moved = @($deltas | Where-Object { $_.Transmitted -ne 0 -or $_.Failed -ne 0 -or $_.Retry -ne 0 -or $_.MultipleRetry -ne 0 -or $_.AckFailure -ne 0 -or $_.Received -ne 0 })
        $chosen = @($deltas | Sort-Object -Property @{ Expression = "Transmitted"; Descending = $true }, @{ Expression = "Index"; Descending = $false })[0]
        $agree = $true
        foreach ($d in $moved) {
            if ($d.Transmitted -ne $chosen.Transmitted -or $d.Failed -ne $chosen.Failed -or $d.Retry -ne $chosen.Retry -or $d.MultipleRetry -ne $chosen.MultipleRetry) { $agree = $false }
        }
        $phyLine = "PHY 項目：回報 {0} 個，視窗內有 {1} 個變動" -f $deltas.Count, $moved.Count
        if ($moved.Count -gt 1 -and $agree) { $phyLine += "，數字全部相同——驅動程式把介面總計寫進每一個項目" }
        elseif ($moved.Count -gt 1) { $phyLine += ("，數字不同（{0}）" -f ((@($moved | ForEach-Object { "項目 {0}：傳送 {1}、重傳 {2}、放棄 {3}" -f $_.Index, $_.Transmitted, $_.Retry, $_.Failed }) -join "；"))) }
        $phyLine += ("；傳送差值最大的項目（項目 {0}）就是介面的數字，項目之間絕不相加，因為鏡射總計的驅動程式會讓每一個框在每個項目各算一次。" -f $chosen.Index)
        $transmitted = [uint64]$chosen.Transmitted
        $failed = [uint64]$chosen.Failed
        $retry = [uint64]$chosen.Retry
        $multiple = [uint64]$chosen.MultipleRetry
        $ackFailures = [uint64]$chosen.AckFailure
        $received = [uint64]$chosen.Received
        $attempted = $transmitted + $failed
        $countLines = @(
            ("取樣視窗：{0} 秒。" -f $seconds),
            ("傳送框差值：{0}；重傳到上限後放棄：{1}；需要重傳的框：{2}，其中重傳超過一次：{3}；沒收到確認：{4}；接收框差值：{5}。" -f $transmitted, $failed, $retry, $multiple, $ackFailures, $received),
            $phyLine,
            $stateLine,
            $guidLine,
            ("開始累積值（項目 {0}）：Transmitted={1}、Failed={2}、Retry={3}、MultipleRetry={4}、ACKFailure={5}、Received={6}" -f $chosen.Index, $chosen.Start.Transmitted, $chosen.Start.Failed, $chosen.Start.Retry, $chosen.Start.MultipleRetry, $chosen.Start.AckFailure, $chosen.Start.Received),
            ("結束累積值（項目 {0}）：Transmitted={1}、Failed={2}、Retry={3}、MultipleRetry={4}、ACKFailure={5}、Received={6}" -f $chosen.Index, $chosen.End.Transmitted, $chosen.End.Failed, $chosen.End.Retry, $chosen.End.MultipleRetry, $chosen.End.AckFailure, $chosen.End.Received)
        )
        if ($attempted -eq 0) {
            $message = "{0}：{1} 秒的視窗內沒有傳送任何框，所以無法計算重傳率。" -f $description, $seconds
            Add-CheckResult -Category $category -Check "無線重傳" -Status "INFO" -Message $message -Details ((@($countLines) + @("重傳率：無法計算——沒有傳送任何東西，所以沒有分母。") + $methodLines) -join [Environment]::NewLine) -Tag "wifi-retry" -Weightless | Out-Null
            continue
        }
        $rate = [math]::Round(([double]$retry / [double]$attempted) * 100.0, 1)
        $message = "{0}：{2} 個框中有 {1} 個需要重傳（{3}%），其中 {4} 個重傳超過一次，{5} 個放棄，視窗 {6} 秒。" -f $description, $retry, $attempted, $rate, $multiple, $failed, $seconds
        $rateLine = "重傳率：{0} ÷（{1} 傳送 + {2} 放棄）= {3}%；兩個重傳計數器不相加、也不互除。" -f $retry, $transmitted, $failed, $rate
        Add-CheckResult -Category $category -Check "無線重傳" -Status "INFO" -Message $message -Details ((@($countLines) + @($rateLine) + $methodLines) -join [Environment]::NewLine) -Tag "wifi-retry" -Weightless | Out-Null
    }
    # 開始時有列出、結束時沒有的介面（PR #52 第 5 輪）：檢測期間被停用或移除，所以沒有差值——自成一列，因為有第二張無線
    # 網卡的機器兩次讀取都不會帶錯誤。
    foreach ($starting in @($Before.Interfaces)) {
        if (@(@($After.Interfaces) | Where-Object { [string]$_.Guid -eq [string]$starting.Guid }).Count -gt 0) { continue }
        $description = ConvertTo-DisplayString $starting.Description
        $stateLine = "連線狀態：開始時{0}，結束時未列出。" -f (Get-WifiInterfaceStateText $starting.State)
        $guidLine = "介面 GUID：{0}" -f $starting.Guid
        Add-CheckResult -Category $category -Check "無線重傳" -Status "ERROR" -Message ("{0}：這個介面在檢測開始時有列出、結束時沒有——檢測期間被停用或移除——所以沒有差值。" -f $description) -Details ((@($stateLine, $guidLine) + $methodLines) -join [Environment]::NewLine) -Tag "wifi-retry" -Weightless | Out-Null
    }
}

function Wait-ForMinimumTcpSample {
    param(
        [datetime]$StartTime,
        [int]$MinimumSeconds,
        [int]$ProgressPercent = 87
    )

    # 自 1.2.14 起以時鐘為準（backlog #65）：不論等待期間跑了什麼，等待都在最短時間結束，所以等待期間讀一次計數器用掉
    # 的是本來就要睡掉的時間，什麼都不會拉長。在此之前秒數在等待開始時就定死了，等待期間做的任何事都會把窗推過最短時間。
    while ($true) {
        $elapsed = ((Get-Date) - $StartTime).TotalSeconds
        $remainingMs = [int][math]::Ceiling(($MinimumSeconds - $elapsed) * 1000.0)
        if ($remainingMs -le 0) {
            return
        }
        $remainingSeconds = [int][math]::Ceiling($remainingMs / 1000.0)
        Set-UiProgress -Percent $ProgressPercent -Text ("TCP 重傳取樣中，尚餘約 $remainingSeconds 秒")
        Start-Sleep -Milliseconds ([math]::Min(1000, $remainingMs))
        # PR #56 第 2 輪：在最後一次睡眠時到期的讀取會在最短時間過後才跑，把整個成本疊到執行上；所以先再檢查一次
        # 期限，接著的結束讀取就會關窗。
        if (((Get-Date) - $StartTime).TotalSeconds -ge $MinimumSeconds) { return }
        Invoke-TcpIntervalReadIfDue
        if ($script:GuiAvailable) {
            [System.Windows.Forms.Application]::DoEvents()
        }
    }
}

# -----------------------------------------------------------------------------
# 結果彙總：整體狀態優先序為 FAIL > ERROR > WARN > PASS。
# -----------------------------------------------------------------------------
function Get-OverallStatus {
    # 整體結果由這次執行「量到了什麼」決定（backlog #39）。量不到的補充統計、樣本比所套用門檻還粗的量測，以及關於
    # 本次執行輸入的事實，都保有自己的列、徽章與統計數字，也會在摘要裡被點名，但不改變整體結果；其餘一律保有權重，
    # 包含選用目標——選用目標回應不良是一次量測。反過來說：判定回答的是「這台機器怎麼樣」，不是「最後三十秒打了
    # 什麼字」。1.2.8 之前，一次讀不到的計數器就會讓每項檢查都通過的執行顯示為「檢測未完整」，使用者手冊還得為這個
    # 判定辯解——手冊要為判定辯解，就是判定做錯事的徵兆。
    $weighted = @($script:Results | Where-Object { [string]$_.Scope -ne "IT" -and -not $_.Weightless })
    $failCount = @($weighted | Where-Object { $_.Status -eq "FAIL" }).Count
    $errorCount = @($weighted | Where-Object { $_.Status -eq "ERROR" }).Count
    $warnCount = @($weighted | Where-Object { $_.Status -eq "WARN" }).Count

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
# 不論這次執行有沒有產生，報告都會解釋「無法檢查」徽章、也都會替重傳比例加註（待辦 #40）：一份健康的報告，
# 開頭就在解釋一個整頁都找不到的徽章，正好挑起它本來要消除的懷疑。現在兩半各自判斷，而且比例那一半看的是
# 「有沒有真的算出比例」，不是「有沒有那個標籤的列」—— 計數器兩邊都讀失敗的執行，同樣會留下標籤列，卻從來沒有比例。
function Get-ReportNoticeFlags {
    return [pscustomobject][ordered]@{
        Unable = (@($script:Results | Where-Object { [string]$_.Status -eq "ERROR" }).Count -gt 0)
        Rate   = [bool]$script:RetransmissionRateComputed
    }
}

# 要交出去的那一個檔案，只寫一次，兩個介面都引用它（待辦 #46）：視窗和文字模式說的是同一個檔案 —— 也就是「開啟報告」
# 打開的那一個，除非它寫不出來，否則就是 HTML。這句話取代的，是資料夾裡三個檔案、而人不知道該送哪一個。
function Get-SendToItLine {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return "" }
    return ("把這個檔案交給 IT：{0}" -f $Path)
}

function Get-FingerprintSummary {
    # 下面每一個判斷式都在下結論，所以每一個都只讀有權重的列（backlog #39）。判定不是唯一由結果集推導出來的東西：
    # 否則，被降權的「樣本不足」重傳列會讓整體結果是「正常」，fingerprint 卻仍是 quality，同一次執行的這一段又寫
    # 「連線可用，但品質不佳」；而被降權的輸入提示會觸發 other-problem 判斷式，反過來壓掉 quality。描述頁面的東西
    # 跟著頁面上的列走——Get-SummaryCounts 與 Get-ReportNoticeFlags 仍讀每一列，所以沒有權重的列保有徽章與說明。
    $allResults = @($script:Results)
    $results = @($allResults | Where-Object { -not $_.Weightless })
    $overall = Get-OverallStatus

    $adaptersFail = @($results | Where-Object { $_.Tag -eq "adapters" -and $_.Status -eq "FAIL" }).Count -gt 0
    $gatewayConfigFail = @($results | Where-Object { $_.Tag -eq "gateway-config" -and $_.Status -eq "FAIL" }).Count -gt 0
    $gatewayPingPass = @($results | Where-Object { $_.Tag -eq "ping-gateway" -and $_.Status -eq "PASS" }).Count -gt 0
    # 因為延遲而失敗的閘道列，每一次被拿來判斷的探測它都回應了（backlog #67）：那是一個「到得了的閘道」的品質問題，
    # 不是「沒有回應的閘道」，所以它走下面的品質那一條，跟其他回應得慢的目標一樣——而如果還有別的東西失敗，就走
    # mixed 那一條。只有由遺失決定的列——回覆沒有回來——才能選到 gateway-unreachable 這個鍵。
    $gatewayLostRows = @($results | Where-Object { $_.Tag -eq "ping-gateway" -and $_.Status -eq "FAIL" -and [string]$_.Rule -ne "latency" })
    $gatewayPingBad = @($gatewayLostRows).Count -gt 0
    # 近端那一階（backlog #60）不選自己的鍵：它說的是失敗在閘道的哪一邊，下面 gateway-unreachable 的摘要就是為此讀它——
    # 而且只讀路由表經由同一張網卡送出探測的閘道列（PR #51 第 4 輪）：多網卡機器上，經由網卡 A 到達的近端主機說明不了
    # 網卡 B 後面的網路線、無線電或交換器。Path 是這一列兩次查詢一致的那張網卡；近端列只要帶著標籤就帶著它，而沒有它、
    # 或帶著另一個的失敗閘道列，保留中性的那一行。
    $nearEndPass = $false
    $nearEndLost = $false
    foreach ($nearEndRow in @($results | Where-Object { $_.Tag -eq "ping-near-end" })) {
        $nearEndPath = [string]$nearEndRow.Path
        if ([string]::IsNullOrWhiteSpace($nearEndPath)) { continue }
        if (@($gatewayLostRows | Where-Object { [string]$_.Path -ne $nearEndPath }).Count -gt 0) { continue }
        if ($nearEndRow.Status -eq "PASS") { $nearEndPass = $true }
        elseif ($nearEndRow.Status -eq "FAIL" -and [string]$nearEndRow.Rule -ne "latency") { $nearEndLost = $true }
    }
    $groupFail = @($results | Where-Object { $_.Tag -eq "connectivity-group" -and $_.Status -eq "FAIL" }).Count -gt 0
    $groupPass = @($results | Where-Object { $_.Tag -eq "connectivity-group" -and $_.Status -eq "PASS" }).Count -gt 0
    $dnsFail = @($results | Where-Object { $_.Tag -eq "dns" -and ($_.Status -eq "FAIL" -or $_.Status -eq "WARN") }).Count -gt 0
    $dnsPass = @($results | Where-Object { $_.Tag -eq "dns" -and $_.Status -eq "PASS" }).Count -gt 0
    $tcpPass = @($results | Where-Object { $_.Tag -eq "tcp" -and $_.Status -eq "PASS" }).Count -gt 0
    $qualityTags = @("ping-target", "ping-gateway", "ping-near-end", "tcp-retransmissions", "adapter-errors")
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
        "gateway-unreachable" {
            $title = "閘道沒有回應"
            # 第二行是依近端那一階量到的結果選的（backlog #60）：近端主機有回應，就洗清了本地路徑、只剩閘道本身；
            # 近端主機也沒回應，就把問題放在閘道之前的本地路徑；沒有近端主機，或它既沒通過、也沒丟回覆，這一行就
            # 像以前一樣點出整段。
            $pathLine = "問題在這台電腦和路由器之間：連線、Wi-Fi、交換器或路由器本身。"
            if ($nearEndPass) { $pathLine = "這台電腦自己網路上的一台主機正常回應了 Ping（近端那一列），所以本地路徑——網卡、網路線或 Wi-Fi、交換器或存取點——在這次執行中是通的；沒有回應的是閘道本身。" }
            # 是「丟了回覆」而不是「沒有回應」（PR #51 第 2 輪）：必要的近端列因遺失級別失敗時，可能有部分回覆回來、也可能
            # 一個都沒有，這一行不能說那台主機沒有出聲。
            elseif ($nearEndLost) { $pathLine = "這台電腦自己網路上的近端主機也丟了回覆——全部，或太多——這指向閘道之前的本地路徑：連線、Wi-Fi、交換器或存取點。另一個可能是那台主機本身，也要一併查。" }
            $lines = @("已設定預設閘道，但閘道沒有回應送給它的 Ping，或遺失得太多。", $pathLine, "確認連線燈號或 Wi-Fi 訊號，以及其他裝置能否連到路由器。", "這項檢查失敗的閘道——不回應送給它自己的 Ping——是嫌疑、不是定罪：它可能一邊正常轉送流量、一邊丟棄或限速這種 Ping。有連線成功，只有在那條連線的路由經過這個閘道時才算證明——同網段的主機、VPN 或 Proxy 都可能沒經過它就成功——所以先查到它的那段連線，把閘道當成未證實，而不是壞掉。")
        }
        "gateway-up-internet-dead" { $title = "閘道正常，網際網路不通"; $lines = @("路由器有回應，但往外的連線失敗。", "問題在路由器或更外層：WAN 連線、ISP 或上游防火牆。", "查看路由器的 WAN 狀態，以及其他裝置是否同樣無法上網。") }
        "dns" { $title = "名稱解析失敗"; $lines = @("用 IP 直接連線正常，但主機名稱無法解析。", "問題在 DNS：設定的 DNS 伺服器、過濾服務或名稱本身。", "把報告中的 DNS 伺服器和公司預期設定比對。") }
        "quality" { $title = "連線正常但品質不佳"; $lines = @("連線可用，但封包遺失、延遲、重傳或網卡錯誤超過門檻。", "常見原因：Wi-Fi 訊號弱、線路壅塞、網路線或連接埠故障。", "問題發生時再跑一次並比較數字。") }
        "mixed" { $title = "有必要檢查未通過"; $lines = @("至少一項必要檢查未通過，請看下方失敗的項目。", "把報告原樣交給 IT。") }
        "incomplete" { $title = "部分檢查無法執行"; $lines = @("沒有發現故障，但部分步驟在這台電腦上無法完成。", "把報告原樣交給 IT，原因記錄在詳細資料中。") }
        "attention" { $title = "有需要注意的警告"; $lines = @("沒有必要檢查失敗，但有檢查提出警告，請看標示的項目。", "把報告原樣交給 IT。") }
        default {
            $title = "全部通過"
            # 不論「資訊」列裡寫了什麼，這裡都說「所有檢查都通過」，於是一個選用目標明明失敗了（依設計是 INFO 列），
            # 結語讀起來卻像什麼都沒發生，而那一列就在幾行之下（待辦 #35）。現在說的是判定真正做過的宣稱，
            # 沒有回應的選用目標也直接寫在讀者眼前。
            $quietOptional = @($results | Where-Object { [string]$_.Scope -ne "IT" -and $_.Status -eq "INFO" -and (@("ping-target", "ping-near-end", "tcp", "http") -contains [string]$_.Tag) })
            if ($quietOptional.Count -gt 0) {
                $quietNames = @(@($quietOptional | ForEach-Object { [string]$_.Check }) | Select-Object -Unique)
                $lines = @("本次執行的所有必要檢查都通過。", ("下列選用目標沒有回應，這不影響整體結果：{0}。" -f ($quietNames -join "、")), "若問題仍然存在，可能在應用程式或伺服器端，或是時好時壞；問題發生時再跑一次。")
            }
            else {
                $lines = @("本次執行的所有檢查都通過。", "若問題仍然存在，可能在應用程式或伺服器端，或是時好時壞；問題發生時再跑一次。")
            }
        }
    }
    # 一個檔案，而不是兩者之一：視窗用路徑指出同一個檔案，這一行指的是讀者手上的這一份（待辦 #46）。
    # 摘要會點名「量不到的」與「被丟棄的」，並明說兩者都沒有改變結果（backlog #39）。只做排除，讀者會看到一個
    # 健康的判定旁邊掛著幾個錯誤徽章，卻沒有東西把它們連起來；這一行就是那個連結，它是排除之外的補充，不是替代。
    $weightless = @($allResults | Where-Object { [string]$_.Scope -ne "IT" -and $_.Weightless -and [string]$_.Tag -ne "startup" })
    if ($weightless.Count -gt 0) {
        # 啟動提示不列進來，因為目標所屬區段的那一列會寫出目標本身，而這一則在名單裡只會貢獻「啟動提示」四個
        # 字；那一列本身仍然保留。
        $weightlessNames = @(@($weightless | ForEach-Object { [string]$_.Check }) | Select-Object -Unique)
        $lines += ("以下項目沒有量到、或無法照原樣使用，它們都不改變結果：{0}。" -f ($weightlessNames -join ", "))
    }
    $lines += "把這個檔案原樣交給 IT。報告內含電腦名稱、使用者名稱、網卡 MAC 位址與 Wi-Fi 網路名稱。"

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

    # 這段說明的每一半，只在這次執行真的產生了它要解釋的東西時才出現（待辦 #40）。
    $noticeFlags = Get-ReportNoticeFlags
    $noticeSentences = @()
    if ($noticeFlags.Unable) { $noticeSentences += "「無法檢查」表示該步驟因權限、系統元件、公司政策或執行錯誤而沒有完成，不等同於網路本身一定異常。" }
    if ($noticeFlags.Rate) { $noticeSentences += "TCP 重傳比例為本機在本次取樣期間的系統級近似值。" }
    $noticeHtml = ""
    if ($noticeSentences.Count -gt 0) { $noticeHtml = '    <div class="notice">' + ($noticeSentences -join "") + '</div>' }
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
$noticeHtml
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

    # 和 HTML 那段說明的兩半相同，條件也相同（待辦 #40）。
    $noticeFlags = Get-ReportNoticeFlags
    $noticeSentences = @()
    if ($noticeFlags.Unable) { $noticeSentences += "「無法檢查」表示該步驟沒有完成，不等同於網路本身一定異常。" }
    if ($noticeFlags.Rate) { $noticeSentences += "TCP 重傳為本機在本次取樣期間的系統級近似統計。" }
    if ($noticeSentences.Count -gt 0) { [void]$builder.AppendLine("注意：" + ($noticeSentences -join "")) }
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
            $script:ReportPathLabel.Text = Get-SendToItLine $primary
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
            $script:ReportPathLabel.Text = Get-SendToItLine $primary
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
    # 跟著結果一起清掉，而不是只在行程啟動時設定一次：視窗會被重複使用，否則某一次算出的比例，會被拿去解釋之後
    # 那次「重新檢測」的報告 —— 即使那一次的計數器根本讀失敗（PR #35 第 1 輪）。
    $script:RetransmissionRateComputed = $false
    $script:TcpConnectSampleCount = 0
    # 同樣的理由（backlog #51）：一次執行擱下的 ping 取樣，絕不能跑到下一次執行的報告裡。
    $script:PendingPingSamples = New-Object System.Collections.ArrayList
    # And the access-point samples (backlog #61's other half): a run compares the samples it took itself.
    $script:WifiAssociationSamples = New-Object System.Collections.ArrayList
    $script:GatewayNeighborRows = New-Object System.Collections.ArrayList
    # 還有 TCP 取樣窗內的讀取（backlog #65）：狀態是這一次執行的，絕不是之後某次執行的。
    $script:TcpIntervalSampling = $null
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

    # 同一個標籤下有兩種家族，只有第二種是關於本次執行輸入的事實（backlog #39）。環境提示保有權重：報告資料夾不可
    # 寫而改用後援位置、圖形介面無法啟動，以及決定這件事的那一則——這份副本正在壓縮資料夾裡執行，報告會被寫到一個
    # 不會留存的地方。整個標籤一起降權，會讓某次執行說「整體正常」，而它要人送出的那個檔案正被寫進一個會消失的資料
    # 夾。輸入提示在加入處標記，而不是另給一個標籤，讓文件提到的每個標籤仍然是原本的意思——而它們之所以可以降權，
    # 是因為 Add-DroppedTargetResults 現在會在每個被丟棄目標的結果本該出現的地方留下一列。
    foreach ($startupMessage in @($script:StartupMessages)) {
        Add-CheckResult -Category "程式環境" -Check "啟動提示" -Status "WARN" -Message $startupMessage -Details "" -Tag "startup" | Out-Null
    }
    foreach ($startupMessage in @($script:RunOptionMessages)) {
        Add-CheckResult -Category "程式環境" -Check "啟動提示" -Status "WARN" -Message $startupMessage -Details "" -Tag "startup" -Weightless | Out-Null
    }

    # 就寫在它所屬的提示旁邊，也在任何 return 之前：執行如果在下方的作業系統或 PowerShell 分支結束，也仍然會
    # 寫出報告；而在 PR #41 第 12 輪之前，那份報告只有被丟掉目標的提示，結果本該出現的地方卻沒有列 ——
    # 而這正是這次改版承諾不會發生的事。它原本還寫在連線步驟的 action 裡，那個步驟一擲回例外就會把這列一起帶走。
    # 這裡不依賴任何執行結果：目標是在讀取執行選項時就被丟掉的，這也是這一列應該排在表格這個位置的原因。
    Add-DroppedTargetResults

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

    # 存取點最先取樣（backlog #61 的另一半）：一次 netsh 讀取，約 0.1 秒，在第一項量測之前，讓整段執行的視窗落在這個
    # 樣本和最後一項量測之後那個樣本之間；無線訊號列在收集 IT 診斷資料時自己的那次讀取就是中間樣本。樣本和無線訊號列
    # 共用同一個開關（Checks.WifiRf），因為它們是同一個讀取器：關掉就不取樣本、也不寫任何存取點列。
    $wifiAssociationEnabled = Test-IsTrueFlag $script:Config.Checks.WifiRf
    if ($wifiAssociationEnabled) {
        Invoke-CheckStep -Category "IT 診斷資料" -Name "取樣 Wi-Fi 存取點（開始）" -Progress 8 -Scope "IT" -Action {
            Add-WifiAssociationSample -Moment "start"
        } | Out-Null
    }
    # 無線重傳計數器在 TCP 基準值之前讀，讓讀取器的編譯——參考機上約 0.7 秒，每個程序一次——在重傳視窗之外付掉；TCP 視窗結束
    # （有延長就延長之後）再讀一次，所以兩個視窗涵蓋同一次執行。設定關掉（Checks.WifiRetryCounters）時什麼都不讀、不寫任何列，
    # 和 IT 診斷資料一樣。
    $wifiRetryEnabled = Test-IsTrueFlag $script:Config.Checks.WifiRetryCounters
    $wifiRetryBaseline = $null
    if ($wifiRetryEnabled) {
        $wifiRetryBaseline = Invoke-CheckStep -Category "Wi-Fi 重傳" -Name "取得 Wi-Fi 重傳基準值" -Progress 9 -Weightless -Action {
            return (Get-WifiRetrySnapshot)
        }
    }
    $tcpBaseline = Invoke-CheckStep -Category "TCP 重傳" -Name "取得 TCP 重傳基準值" -Progress 10 -Weightless -Action {
        # 只有基準值使用 -WarmUp：這次會被丟棄的讀取，把計數器提供者第一次查詢要收的成本付在取樣窗之外，
        # 在那裡它不會拉長窗所回報的數字（backlog #38）。
        # 不論快照裡有什麼都照樣回傳，包括兩個類別都失敗的基準快照（PR #40 第 5 輪）。在那裡拋出例外，換來的是
        # Invoke-CheckStep 的通用步驟錯誤列，而快照——四次嘗試、它們的秒數，以及任何窗前失敗——會跟著被丟掉，分析
        # 階段只能寫出「沒有完整的前後資料」，對那些讀取隻字未提。Compare-TcpCounters 會從這個物件為每一次失敗的
        # 讀取寫出一列，說的是同一件事，但證據都在。
        return (Get-TcpCounterSnapshot -WarmUp)
    }
    $minimumSampleSeconds = [math]::Max(1, (ConvertTo-IntSafe $script:Config.Tests.RetransmissionSampleSeconds 8))
    $tcpSampleStart = Get-Date
    # 窗內讀取從基準時間戳打開，在讀取結束值之前關閉（backlog #65）。
    Start-TcpIntervalSampling -IntervalSeconds (Get-TcpIntervalSeconds) -Since $tcpSampleStart -Deadline $tcpSampleStart.AddSeconds($minimumSampleSeconds)

    $adapterStatsBefore = Invoke-CheckStep -Category "網卡錯誤計數" -Name "取得網卡錯誤基準值" -Progress 13 -Weightless -Action {
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

    # 位置就是重點（backlog #51）：擱下的 ping 取樣在這裡送完，也就是在重傳視窗把剩餘秒數睡掉之前，因此那些
    # 探測分散用掉的是本來就要花的等待時間。放在別處都會讓一次執行變長。
    # 有東西擱著才走這一步：Invoke-CheckStep 每次都會寫一行「開始：…」並推進進度列，而大多數的執行根本
    # 沒有任何取樣被擱下，一行講一件沒發生的事的紀錄，就是這個專案在別處花力氣移除的那種東西。
    if (@($script:PendingPingSamples).Count -gt 0) {
        Invoke-CheckStep -Category "延遲與封包遺失" -Name "送完尚未足以下結論的 ping 取樣" -Progress 78 -Action {
            Complete-PingSamples -SampleStart $tcpSampleStart -MinimumSeconds $minimumSampleSeconds
        } | Out-Null
    }
    Wait-ForMinimumTcpSample -StartTime $tcpSampleStart -MinimumSeconds $minimumSampleSeconds
    # PR #56 第 3 輪：窗內讀取在等待的期限就關閉。等待與結束讀取之間還有兩個步驟——網卡計數器的結束值和它們的分析——
    # 等待之後才到期的讀取會在那兩步之後、最短時間過後才跑，把整個成本疊到執行上；接著的結束讀取就會關窗。
    Stop-TcpIntervalSampling

    $adapterStatsAfter = Invoke-CheckStep -Category "網卡錯誤計數" -Name "取得網卡錯誤結束值" -Progress 82 -Weightless -Action {
        return (Get-AdapterStatisticsSnapshot)
    }

    Invoke-CheckStep -Category "網卡錯誤計數" -Name "分析網卡錯誤與丟棄" -Progress 85 -Action {
        if ($null -eq $adapterStatsBefore -or $null -eq $adapterStatsAfter) {
            Add-CheckResult -Category "網卡錯誤計數" -Check "前後比較" -Status "ERROR" -Message "缺少基準值或結束值，無法計算錯誤增量。" -Details "" -Tag "adapter-errors" -Weightless | Out-Null
        }
        else {
            Compare-AdapterStatistics -Before $adapterStatsBefore -After $adapterStatsAfter -Adapters $networkSnapshot
        }
    } | Out-Null

    $tcpAfter = Invoke-CheckStep -Category "TCP 重傳" -Name "取得 TCP 重傳結束值" -Progress 89 -Weightless -Action {
        Stop-TcpIntervalSampling
        return (Get-TcpCounterSnapshot)
    }

    # 延長一次，而且只在那個模稜兩可的情況下（backlog #51）：樣本低於評分下限，而窗內有過重傳。延長步驟本身
    # 是 weightless 的——它是一次取樣的決定，不是一次量測；真正的量測仍然由下面那一步寫出來。合併是逐通訊協定
    # 做的，所以第二次讀取失敗絕不會弄丟第一次已經讀到的結果。
    if (Test-TcpSampleNeedsExtension -Before $tcpBaseline -After $tcpAfter) {
        $tcpExtended = Invoke-CheckStep -Category "TCP 重傳" -Name "樣本太小無法評分時延長 TCP 取樣窗" -Progress 90 -Weightless -Action {
            Start-TcpIntervalSampling -IntervalSeconds (Get-TcpIntervalSeconds) -Since (Get-Date) -Extension -Boundary $tcpAfter -Deadline (Get-Date).AddSeconds($minimumSampleSeconds)
            Wait-ForMinimumTcpSample -StartTime (Get-Date) -MinimumSeconds $minimumSampleSeconds -ProgressPercent 90
            Stop-TcpIntervalSampling
            return (Merge-TcpEndingSnapshot -Original $tcpAfter -Extended (Get-TcpCounterSnapshot))
        }
        if ($null -ne $tcpExtended) { $tcpAfter = $tcpExtended }
    }

    # 結束值在 TCP 視窗（不論有沒有延長）之後讀，讓兩個視窗一起結束；分析放在 TCP 分析之後，也就是報告印出的順序。
    $wifiRetryAfter = $null
    if ($wifiRetryEnabled) {
        $wifiRetryAfter = Invoke-CheckStep -Category "Wi-Fi 重傳" -Name "取得 Wi-Fi 重傳結束值" -Progress 91 -Weightless -Action {
            return (Get-WifiRetrySnapshot)
        }
    }
    # 最後一次存取點樣本，和重傳計數器的結束值一樣放在 TCP 視窗之後，讓本次執行的每一項量測都落在第一個樣本和這個
    # 樣本之間（backlog #61 的另一半）。
    if ($wifiAssociationEnabled) {
        Invoke-CheckStep -Category "IT 診斷資料" -Name "取樣 Wi-Fi 存取點（結束）" -Progress 91 -Scope "IT" -Action {
            Add-WifiAssociationSample -Moment "end"
        } | Out-Null
    }
    Invoke-CheckStep -Category "TCP 重傳" -Name "分析 TCP 重傳" -Progress 92 -Action {
        Compare-TcpCounters -Before $tcpBaseline -After $tcpAfter
    } | Out-Null
    if ($wifiRetryEnabled) {
        Invoke-CheckStep -Category "Wi-Fi 重傳" -Name "分析 Wi-Fi 重傳" -Progress 93 -Action {
            Compare-WifiRetryCounters -Before $wifiRetryBaseline -After $wifiRetryAfter
        } | Out-Null
    }
    if ($wifiAssociationEnabled) {
        Invoke-CheckStep -Category "IT 診斷資料" -Name "比較各次樣本的 Wi-Fi 存取點" -Progress 94 -Scope "IT" -Action {
            Compare-WifiAssociation -Samples @($script:WifiAssociationSamples)
            Update-AccessPointGatewayHints -Samples @($script:WifiAssociationSamples)
        } | Out-Null
    }

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
        # 和視窗上那一行同一句話、同一個檔案：除非 HTML 寫不出來，否則就是 HTML。
        $sendLine = Get-SendToItLine ([string]@(@($report.Html, $report.Text, $report.Json) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })[0])
        if (-not [string]::IsNullOrWhiteSpace($sendLine)) { Write-Host $sendLine }
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

# 待辦 #34：視窗開不起來而退回文字模式的執行，是在啟動器開的那個黑色視窗裡結束的，而使用者與 IT 啟動器在結束代碼
# 0 時會關掉那個視窗——視窗模式這樣是對的，人已經自己關掉工具了；退回模式卻不對，三個報告路徑是最後印出的東西。
# 腳本只在這次執行確實是退回模式時才在這裡等一個按鍵：不是以 -ConsoleOnly 啟動（文字模式啟動器自己會暫停，而驗證
# 鏈的文字模式執行不能等）、主控台前有人（排程工作或服務沒有）、而且標準輸入沒有被導向（餵 NUL 的測試工具絕不能被
# 卡住）。每個條件都是參數、預設值就是即時的值，讓這個決定不需要主控台也能測；ReadKey 本身也有防護，因為沒有鍵盤的
# 主機會擲出例外。回傳值是有沒有等。呼叫端再加第四個條件：只在退回執行以 0 結束之後——其他結束代碼由啟動器自己
# 在它的錯誤下方暫停，再多一個宣稱有報告路徑可讀的提示會錯兩次。
function Wait-ForConsoleClose {
    param(
        [bool]$ConsoleOnlyRun = [bool]$ConsoleOnly,
        [bool]$UserInteractive = [Environment]::UserInteractive,
        [bool]$InputRedirected = [Console]::IsInputRedirected
    )
    if ($ConsoleOnlyRun -or (-not $UserInteractive) -or $InputRedirected) {
        return $false
    }
    try {
        Write-Host ""
        Write-Host "視窗會留著，好讓上面的報告路徑能被讀到。請按任意鍵關閉。"
        [void][Console]::ReadKey($true)
        return $true
    }
    catch {
        return $false
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
    # 設定值超過旋轉鈕預設範圍（取樣 120 秒）時放寬範圍而不截斷，未更動就開始也會以設定值執行（v1.2.1）。
    # 兩個 ping 旋轉鈕的範圍「就是」設定的上限（backlog #51）。到 1.2.9 為止它開在 20——一個在這個儲存庫或套件
    # 裡任何地方都找不到理由的數字；放寬的行為留著，只是現在被放寬的那個起點是一個有意義的值。
    $pingRange = [math]::Max($options.PingCountMaximum, $options.PingCount)
    $controls["PingCount"].Maximum = $pingRange
    $controls["PingCount"].Value = [math]::Max(1, $options.PingCount)
    $controls["PingCountMaximum"].Maximum = $pingRange
    $controls["PingCountMaximum"].Value = [math]::Max(1, $options.PingCountMaximum)
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

# 在執行開始之前，用實際執行所用的規則檢查面板的四個自由輸入欄位。只有額外 TCP 目標有格式規則，另外三個讀過就
# 放行。沒有在這裡攔下來的代價量過兩次：一次十五秒的執行、一份帶警告的報告、在每項檢查都通過的網路上得到
# 「需要注意」，以及一段叫人把那份報告交給 IT 的結語。
function Get-RejectedPanelValues {
    $rejected = New-Object System.Collections.ArrayList
    $controls = $script:OptionsPanel
    if ($null -eq $controls) { return @() }
    foreach ($item in @(([string]$controls["TcpTarget"].Text) -split '[,;\s]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        if (-not (Test-TcpTargetSyntax $item)) {
            [void]$rejected.Add([pscustomobject][ordered]@{ Key = "TcpTarget"; Value = [string]$item; Problem = "額外 TCP：「" + $item + "」不是 host:port 格式，或主機名稱無法使用 —— 例如 8.8.8.8:443。" + $(if (([string]$item).Split(":").Count -eq 2 -and -not (Test-HostNameSyntax (([string]$item).Split(":")[0]))) { "主機：" + (Get-HostNameSyntaxProblem (([string]$item).Split(":")[0])) + "。" } else { "" }) })
        }
    }
    return @($rejected)
}

# 不擋、也不拒絕：標記欄位、說出問題，並給出這個欄位要的那種值當範例，同時告訴對方這個工具一向提供的第二個
# 選擇 —— 再按一次「開始檢測」就照樣執行，只是不帶那個目標，跟這個檢查存在之前一模一樣，啟動提示照舊。
function Show-PanelRejection {
    param([object[]]$Rejected)
    $controls = $script:OptionsPanel
    foreach ($item in @($Rejected)) {
        $control = $controls[[string]$item.Key]
        if ($null -ne $control) { $control.BackColor = [System.Drawing.Color]::MistyRose }
    }
    $text = ((@($Rejected | ForEach-Object { [string]$_.Problem }) -join " ") + " " + '請修正，或再按一次「開始檢測」，不帶這個目標直接執行。')
    Set-UiProgress -Percent 0 -Text $text
    Write-UiLog -Status "INFO" -Text $text
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
        PingCountMaximum = [int]$controls["PingCountMaximum"].Value
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
    # IT 面板是一個寬 880 px 的固定格線，視窗不能被縮得比它所承載的格線還窄：面板向左右錨定，縮小視窗會把第三欄
    # 推出面板邊緣，而那裡是捲不到的地方（PR #35 第 1 輪）。使用者視窗沒有這個面板，維持原本的最小寬度。
    $minWidth = 780
    if ($script:Interactive) { $minWidth = 940 }
    $form.MinimumSize = New-Object System.Drawing.Size($minWidth, [math]::Min(560 + $offset, $formHeight))
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
        # 六個標籤共用一個寬度，正是最長的那個被裁掉的原因：「額外 TCP（host:port）」在 100 px 的框裡需要 147 px
        # （英文標籤 136 px），於是換行、第二行在 22 px 高的框裡被切掉 —— 格式在原始碼裡，不在螢幕上（待辦 #49）。
        # 現在每個標籤帶著自己需要的寬度，旁邊兩欄跟著右移；面板寬 880，最後一個控制項結束在 875。
        # gui-headless 步驟會在兩種語言下量每個控制項與它的框，翻譯長出框會讓鏈失敗，而不是等下一次走查。
        foreach ($item in @(
            @{ Text = "額外 Ping"; X = 12; Y = 26; W = 150 },
            @{ Text = "額外 DNS"; X = 375; Y = 26; W = 100 },
            @{ Text = "Ping 次數"; X = 690; Y = 26; W = 110 },
            @{ Text = "額外 TCP（host:port）"; X = 12; Y = 58; W = 150 },
            @{ Text = "額外 URL"; X = 375; Y = 58; W = 100 },
            @{ Text = "Ping 上限"; X = 690; Y = 58; W = 110 },
            @{ Text = "取樣秒數"; X = 690; Y = 92; W = 110 }
        )) {
            $label = New-Object System.Windows.Forms.Label
            $label.Text = $item.Text
            $label.Location = New-Object System.Drawing.Point($item.X, $item.Y)
            $label.Size = New-Object System.Drawing.Size($item.W, 22)
            $panel.Controls.Add($label)
        }
        foreach ($item in @(@{ Key = "PingTarget"; X = 165; Y = 23 }, @{ Key = "DnsName"; X = 478; Y = 23 }, @{ Key = "TcpTarget"; X = 165; Y = 55 }, @{ Key = "HttpUrl"; X = 478; Y = 55 })) {
            $box = New-Object System.Windows.Forms.TextBox
            $box.Location = New-Object System.Drawing.Point($item.X, $item.Y)
            $box.Size = New-Object System.Drawing.Size(195, 24)
            $panel.Controls.Add($box)
            $controls[$item.Key] = $box
        }
        # 格式寫在人正在打字的那個控制項上，而且是範例值而不是記法：host:port 是開發者用來描述形狀的簡寫，
        # 8.8.8.8:443 才是對方接下來要打的那種東西。
        $hints = New-Object System.Windows.Forms.ToolTip
        $script:PanelHints = $hints
        $hints.SetToolTip($controls["PingTarget"], "例如 1.1.1.1")
        $hints.SetToolTip($controls["DnsName"], "例如 www.example.com")
        $hints.SetToolTip($controls["TcpTarget"], "例如 8.8.8.8:443 —— 主機或位址、冒號、連接埠")
        $hints.SetToolTip($controls["HttpUrl"], "例如 https://www.example.com/")
        foreach ($key in @("PingTarget", "DnsName", "TcpTarget", "HttpUrl")) {
            $controls[$key].Add_TextChanged({ $script:PanelWarned = $false; $this.BackColor = [System.Drawing.SystemColors]::Window })
        }
        # 三個旋轉鈕排成同一欄。兩個 ping 的範圍來自設定的上限，不是這個面板自己的數字（backlog #51）；面板
        # 重設時 Set-OptionsPanelValues 會再依執行選項設定一次。
        $pingSpinnerRange = [math]::Max(1, (ConvertTo-IntSafe (Get-PropertyValue $script:RunOptions "PingCountMaximum" 21) 21))
        foreach ($item in @(@{ Key = "PingCount"; X = 805; Y = 23; Min = 1; Max = $pingSpinnerRange }, @{ Key = "PingCountMaximum"; X = 805; Y = 55; Min = 1; Max = $pingSpinnerRange }, @{ Key = "SampleSeconds"; X = 805; Y = 89; Min = 1; Max = 120 })) {
            $spinner = New-Object System.Windows.Forms.NumericUpDown
            $spinner.Location = New-Object System.Drawing.Point($item.X, $item.Y)
            $spinner.Size = New-Object System.Drawing.Size(70, 24)
            $spinner.Minimum = $item.Min
            $spinner.Maximum = $item.Max
            $panel.Controls.Add($spinner)
            $controls[$item.Key] = $spinner
        }
        # 放在建立它們的迴圈之後，而不是跟上面的文字欄位放在一起：對一個還不存在的控制項設 tooltip 會拋出例外，
        # 而 headless GUI 步驟就是這樣在兩種語言下抳到這一個的。
        $hints.SetToolTip($controls["PingCount"], "每個 ping 目標一開始送出的 ICMP echo 次數")
        $hints.SetToolTip($controls["PingCountMaximum"], "有回覆遺失時，本次執行對單一 ping 目標最多送到幾次")
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
                # 面板攔得下來的值，在執行開始之前就檢查，而不是之後（待辦 #45）。不擋任何事：第一次按會說出問題
                # 並標記欄位，再按一次就不帶那個目標執行 —— 也就是這個檢查存在之前的行為。
                if (-not $script:PanelWarned) {
                    $rejected = @(Get-RejectedPanelValues)
                    if ($rejected.Count -gt 0) {
                        Show-PanelRejection -Rejected $rejected
                        $script:PanelWarned = $true
                        return
                    }
                }
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
        SampleSeconds = $SampleSeconds; PingCount = $PingCount; PingCountMaximum = $PingCountMaximum; TracerouteHops = $TracerouteHops
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
            if ($exitCode -eq 0) { [void](Wait-ForConsoleClose) }
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
