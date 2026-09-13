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

$script:ToolVersion = "1.2.14"
$script:BaseDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path

# -----------------------------------------------------------------------------
# Backlog #18: application control (WDAC, AppLocker) can restrict PowerShell to a language mode in which a script
# may not create .NET objects. This diagnostic needs them from its very first line - the ArrayList below is already
# out of reach - so it cannot run at all there, and what the person in front of the screen would otherwise see is the
# engine's own "Cannot create type. Only core types are supported in this language mode.", which tells them nothing
# they can act on. Everything above this point and everything in Write-EnvironmentReport therefore stays inside what
# a restricted mode allows: cmdlets, operators and property reads, no .NET types, no New-Object.
# -----------------------------------------------------------------------------
function Test-IsRunningFromArchive {
    param([string]$Path)

    # Windows opens a ZIP in a temporary view and extracts the file double-clicked there into it: %TEMP%\Temp1_<name>.zip\...
    # on Windows 10, %TEMP%\<guid>_<name>.zip.<hex>\... on Windows 11, where the suffix is a few hex digits (.684, .bc4),
    # not a number (backlog #26). A run from such a folder appears to work, but the folder disappears with the view,
    # taking any file written into it.
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    return ($Path -match "\.zip(\.[0-9a-f]+)?[\\/]")
}

function Write-EnvironmentReport {
    param([string]$Reason)

    $lines = @(
        "Network Health Check - environment report",
        "=========================================",
        "The diagnostic could not run on this computer. Nothing was changed.",
        "",
        "Reason: $Reason",
        ("Date/time: " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss")),
        ("Tool version: " + $script:ToolVersion),
        ("Computer: " + $env:COMPUTERNAME),
        ("User: " + $env:USERNAME),
        ("Script folder: " + $script:BaseDirectory)
    )
    # Each fact is optional: a locked-down machine may refuse any one of these, and a missing line must not cost the
    # report the lines that did work.
    try { $lines += ("PowerShell: " + $PSVersionTable.PSVersion + " (" + $PSVersionTable.PSEdition + ")") } catch { $lines += "PowerShell: unknown" }
    try { $lines += ("Language mode: " + $ExecutionContext.SessionState.LanguageMode) } catch { $lines += "Language mode: unknown" }
    try { $lines += ("Culture: " + (Get-Culture).Name + " / UI culture: " + (Get-UICulture).Name) } catch { $lines += "Culture: unknown" }
    try { $lines += ("Operating system: " + (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).Caption) } catch { $lines += "Operating system: unknown" }
    $lines += @(
        "",
        "What IT can do:",
        "- Allow NetworkHealthCheck.ps1 in the application-control policy (WDAC / AppLocker), or",
        "- run the check on a computer that is not restricted in this way.",
        "Send this file with the support request."
    )

    # The script folder first, the temporary folder if it is not writable - the same order the reports use. With one
    # exception: a folder inside the Windows compressed-folder view is writable but disposable, and this file is the
    # only trace of a run that never reached the report stage, so it is written outside the view instead. The archive
    # warning further down never runs in this path, because the guard exits first.
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
    $reason = "PowerShell is restricted to '$mode' language mode by an application-control policy, so this script may not create the .NET objects it needs."
    $written = Write-EnvironmentReport -Reason $reason
    Write-Host ""
    Write-Host "Network Health Check cannot run on this computer."
    Write-Host $reason
    Write-Host "No network settings were read or changed."
    Write-Host "What IT can do: allow this script in the application-control policy (WDAC / AppLocker), or run the check on a computer without that restriction."
    if (Test-IsRunningFromArchive $script:BaseDirectory) {
        Write-Host "This copy is running from inside a compressed folder, so the file below was written outside it. Extract the ZIP to a real folder before running."
    }
    if (-not [string]::IsNullOrWhiteSpace($written)) { Write-Host "Details for IT were written to: $written" }
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
# Script-scope variables share the script's top-level scope with the bound parameters: never reset a parameter's
# name to a literal here (v1.2.0 wrote $false and the IT launcher opened the user layout; fixed in v1.2.1).
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

# Backlog #14: Winsock and WinHTTP error text comes from the operating system, so a machine whose system locale
# differs from the report language prints that locale's words into the report (a Chinese sentence inside an English
# report). The message moves, the code does not: SocketException.SocketErrorCode and WebException.Status are
# enumerations. The tables below turn the codes these checks can produce into one sentence in the report's language.
# The original message is always kept next to it, and an unmapped code still carries its locale-independent name, so
# the reader can look up what the operating system actually said.
function Get-NetworkErrorCauseText {
    param([object]$Exception)

    $socketCauses = @{
        "HostNotFound"        = "The name could not be resolved (no DNS record)."
        "TryAgain"            = "Name resolution failed temporarily; the DNS server did not answer."
        "NoData"              = "The name exists but has no address record of the requested type."
        "TimedOut"            = "The target did not respond within the timeout."
        "ConnectionRefused"   = "The target answered but refused the connection on that port."
        "NetworkUnreachable"  = "This machine has no route to that network."
        "HostUnreachable"     = "The network is reachable but the host is not."
        "ConnectionReset"     = "The remote host closed the connection."
        "ConnectionAborted"   = "Software on this machine aborted the connection (often security software or policy)."
        "NetworkDown"         = "The local network stack reports the network as down."
        "AddressNotAvailable" = "The address is not valid on this machine."
        "AccessDenied"        = "The socket operation was blocked by permissions or policy."
    }
    $webCauses = @{
        "Timeout"                    = "The HTTP request timed out."
        "NameResolutionFailure"      = "The host name in the URL could not be resolved."
        "ProxyNameResolutionFailure" = "The proxy server's name could not be resolved."
        "ConnectFailure"             = "The connection to the server could not be established."
        "TrustFailure"               = "The server certificate was not trusted."
        "SecureChannelFailure"       = "The TLS handshake failed (protocol or cipher mismatch)."
        "ReceiveFailure"             = "The connection was interrupted while receiving the response."
        "SendFailure"                = "The connection was interrupted while sending the request."
        "ConnectionClosed"           = "The server closed the connection unexpectedly."
        "ServerProtocolViolation"    = "The server's answer was not valid HTTP."
        "RequestProhibitedByProxy"   = "The proxy refused the request."
    }

    # PowerShell wraps a failed method call in a MethodInvocationException, a task in an AggregateException and a
    # ping in a PingException, so the socket error is usually two or three levels down.
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
            # The tool's own limit (Invoke-DnsLookup, Invoke-TcpConnectionTest) expired while the operating system was
            # still waiting: nothing answered and nothing refused, which is what a firewall that drops packets, or an
            # unreachable host, looks like. Until 1.2.3 this was a bare RuntimeException without a cause line (backlog #27).
            return "No answer within the tool's own time limit: nothing replied and nothing refused, which is what a firewall dropping packets or an unreachable host looks like. [ToolTimeout]"
        }
        $current = $current.InnerException
        $depth++
    }
    return ""
}

# The cause goes above the original text, never instead of it.
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
        return ("Cause: {0}" -f $cause)
    }
    # A per-attempt ping line and a traceroute hop status are single lines; everywhere else the original
    # message goes on the next one. The cause comes first in both shapes - that is the whole point.
    if ($SingleLine) {
        return ("Cause: {0} | {1}" -f $cause, $Text)
    }
    return (("Cause: {0}" -f $cause) + [Environment]::NewLine + $Text)
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
        $cause = Get-NetworkErrorCauseText $ErrorRecord.Exception
        if (-not [string]::IsNullOrWhiteSpace($cause)) {
            $parts = @("Cause: $cause") + $parts
        }
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
        [string]$Scope = "Main",
        [switch]$Weightless,
        [string]$Rule = "",
        [string]$Path = ""
    )

    # -Weightless marks a row that keeps its badge, its message and its place in the counts but does not decide the
    # overall result or the fingerprint (backlog #39). The marking is opt-in, one branch at a time: a row that says
    # nothing was measured, that a sample was too coarse for the threshold applied to it, or that states a fact about
    # this run's own input. Everything else keeps its weight by default - a check added later cannot become weightless
    # by forgetting something, which is the failure nobody would notice.
    # -Path is the adapter the route table selected for a ping row's probes where the lookups before and after them
    # agreed - the interface alias - and empty where they did not, or where the target was given as a name (PR #51,
    # round 4). The summary uses it to pair a near-end row with a failed gateway row: a near-end host reached through
    # one adapter says nothing about another adapter's cable, radio or switch. Additive under JSON schema 2 as well.
    # -Rule names the measurement a row's status follows from, where a row has more than one (backlog #67): a ping row
    # is decided by its loss or by its latency, and until 1.2.12 nothing outside the row's prose said which, so the
    # fingerprint titled a gateway that answered every probe slowly as one that did not answer. It is empty on every
    # row that has nothing to say - a row that passed, or one that carries a single measurement - and it is additive
    # under JSON schema 2, like Weightless.
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
    Write-UiLog -Status $Status -Text ("{0} / {1}: {2}" -f $Category, $Check, $Message)
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

    # The step carries the weight, not the tag (backlog #39). step-error is one tag over every step, and four of them
    # are quality collectors: a collector that fails completely writes a step-error row here and then its own row in
    # the analysis that follows, so demoting only the second of each pair would leave the run Test Incomplete exactly
    # as before - this decision failing at the one case it was written for. The four declare themselves at the call
    # site and their step-error rows inherit it; every other step's keeps its weight untouched.

    Set-UiProgress -Percent $Progress -Text $Name
    Write-UiLog -Status "INFO" -Text ("Starting: $Name")

    $result = $null
    try {
        $result = (& $Action)
    }
    catch {
        $details = Get-ExceptionDetails $_
        $diagnostics = Get-ExceptionDiagnostics $_
        Add-CheckResult -Category $Category -Check $Name -Status "ERROR" -Message "This item could not be executed. The error has been recorded." -Details $details -Diagnostics $diagnostics -Tag "step-error" -Scope $Scope -Weightless:$Weightless | Out-Null
        $result = $null
    }
    # backlog #65: the due-check for the reads inside the TCP window runs after every step, whatever the step did, so
    # that a read is never more than one step late; it never throws, and it reads nothing while no window is open.
    Invoke-TcpIntervalReadIfDue
    return $result
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
            PingCountMaximum             = 21
            PingTimeoutMs                = 1200
            DnsTimeoutMs                 = 4000
            TcpTimeoutMs                 = 4000
            HttpTimeoutMs                = 6000
            RetransmissionSampleSeconds  = 8
            RetransmissionIntervalSeconds = 2
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
            # backlog #60: the near-end rung of the ping ladder - a host on this computer's own subnet that is not the
            # gateway, so that the local path is measured without the gateway's control plane or the WAN in it. Absent
            # by default: the tool cannot choose one, because whether a candidate is a stable host that answers ICMP
            # is a person's judgement, so IT names it here. Given as an IPv4 address, never a name: the check has to
            # know the host is on the local subnet before anything is sent.
            NearEndTarget = [pscustomobject][ordered]@{
                Name     = "Near-end host"
                Address  = ""
                Required = $false
            }
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

# The syntax rules the four free-text fields have, in one place. Test-TcpTargetSyntax is the one that rejects:
# Set-RunOptions drops the target after the run has started, and the IT panel checks with it before, on Start,
# so a panel that disagreed with the run is not possible. The other three do not drop anything - a value they
# refuse keeps its row and is reported as a fact about this run's input (backlog #39). What they refuse is only
# what could never be sent: not a name the resolver rejects, which is an answer and stays a measurement.
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

    # Can this value become an HTTP target at all - an absolute URI with a scheme this tool speaks. The rule lives
    # here because two places ask it: the configuration validation, and the check that would otherwise send the
    # request. They disagreed until 1.2.8 (PR #41, round 1): the validation called 'example.com' unusable while the
    # check only intercepted a blank, so the request went out, failed, and was recorded as a measured connectivity
    # failure - a required target could produce Problem Detected, and a member of a required group could fail that
    # group, over a value no packet ever left for.
    $uri = $null
    if (-not [System.Uri]::TryCreate([string]$Value, [System.UriKind]::Absolute, [ref]$uri)) { return $false }
    if (-not ($uri.Scheme -eq "http" -or $uri.Scheme -eq "https")) { return $false }
    # The host inside the URL is a host name like any other: Uri.TryCreate is happy with 'http://foo..bar/',
    # and the empty label is only found when the request is already on its way, where the failure reads as a
    # site that would not answer (PR #41, round 9). The host tested is the one written in the URL, not Uri's
    # .Host: Uri lowercases and normalises the host before exposing it, and would have passed a spelling the rule
    # refuses everywhere else (PR #58, round 3). Since round 6 this is the yes/no of Get-UrlHostProblemSuffix, which
    # also refuses a URL whose written host is not the host Uri would send to.
    return (([string](Get-UrlHostProblemSuffix $Value)).Length -eq 0)
}

# Backlog #54: the rule of the host-name predicate, stated once, instead of a list of characters that reviewers found
# one at a time (PR #41, rounds 5 to 21). A configured value can be tested when the name that would go on the wire IS
# the name configured:
#   - an IPv6 literal, with or without a numeric zone id (fe80::1%12 is Windows' form, and a link-local address cannot
#     be sent without one) - the only place a colon, and so a percent sign, is allowed;
#   - otherwise labels, separated by '.' or by one of the three separators IDNA reads as a dot (U+3002, U+FF0E, U+FF61),
#     a trailing empty label being the root. Every label is judged in the form the resolver would send. A label with a
#     character beyond ASCII is encoded by IDNA (GetAscii, the resolver's own conversion) and decoded again, and what
#     comes back must be the label configured - up to case and canonical composition (NFC) - so that a character
#     IDNA drops (a zero-width space or joiner, a soft hyphen), maps (a full-width letter, an eszett) or refuses (a
#     bidirectional control, an unassigned code point) is refused here: the name asked would not be the name
#     configured, and nothing in the report would have said so. The encoded label may hold letters, digits, hyphens
#     and underscores only - the underscore because Windows hosts carry it, the stated superset of LDH - which is what
#     refuses a space, a control character, a URI delimiter and every other ASCII symbol; it is 1 to 63 characters
#     once encoded and does not start or end with a hyphen; the whole encoded name is at most 253.
# What passes could be asked as configured, and the resolver's answer - 'no such name' included - stays a measurement
# (backlog #39). What is refused could never have been asked as configured, and the reason names the first character
# that decided it, so that the operator can fix the value. Test-HostNameSyntax is this function's yes/no; the reason
# goes into the row's details. A pure-ASCII label is judged without IDNA, which leaves it exactly as it is - an
# already-encoded xn-- label included.
function Get-HostNameSyntaxProblem {
    param([string]$Value)
    $name = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($name)) { return "the value is blank" }
    if ($name.Contains(":")) {
        $parsedAddress = $null
        if ([System.Net.IPAddress]::TryParse($name, [ref]$parsedAddress) -and $parsedAddress.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6) { return "" }
        return "a colon is allowed only in an IPv6 address, and this is not one (a zone id has to be numeric, as in fe80::1%12)"
    }
    $labels = @($name.Split([char[]]@(".", [char]0x3002, [char]0xFF0E, [char]0xFF61)))
    if ($labels.Count -gt 1 -and $labels[$labels.Count - 1].Length -eq 0) { $labels = @($labels[0..($labels.Count - 2)]) }
    $idn = New-Object System.Globalization.IdnMapping
    $position = 1
    $encodedLength = 0
    # A position in a reason counts Unicode scalars from the start of the trimmed value, a surrogate pair as one
    # character, where the offsets below count UTF-16 units: an emoji before the character that decided a refusal
    # would otherwise have shifted every position after it by one (PR #58, round 7).
    $scalarPosition = { param([int]$units) $units + 1 - [regex]::Matches($name.Substring(0, [math]::Min($units, $name.Length)), '[\uD800-\uDBFF][\uDC00-\uDFFF]').Count }
    foreach ($label in $labels) {
        if ($label.Length -eq 0) { return ("an empty label at position {0}: two separators in a row, or a leading one" -f (& $scalarPosition ($position - 1))) }
        $encoded = $label
        # -cmatch, not -match: the case-insensitive one folds U+212A (the Kelvin sign) into K and U+0130 into I, and
        # had called both ASCII - the boundary test found them on its first run.
        if ($label -cmatch '[^\x00-\x7F]') {
            $normalized = $label
            $decoded = $null
            try {
                $normalized = $label.Normalize([System.Text.NormalizationForm]::FormC)
                $encoded = $idn.GetAscii($normalized)
                $decoded = $idn.GetUnicode($encoded)
            }
            catch {
                # The label as a whole is refused. The character that decided it is the one whose removal makes the
                # label encodable - probed in the label's own context, because a character probed alone or between two
                # Latin letters is judged as a different label (round 8: a right-to-left letter between "a" and "b";
                # round 9: a joiner that is valid only between the letters it joins). A label of more than 63 characters
                # is the length before anything is searched. Exactly one such character is named; none - two prohibited
                # characters, say - is searched in pairs, and the first of the first pair that works is named; more than
                # one, or a label no pair rescues, is reported as a whole.
                if ($normalized.Length -gt 63) { return ("the label at position {0} is longer than 63 characters" -f (& $scalarPosition ($position - 1))) }
                $units = New-Object System.Collections.ArrayList
                $i = 0
                while ($i -lt $normalized.Length) {
                    $unit = [string]$normalized[$i]
                    if ([char]::IsHighSurrogate($normalized[$i]) -and ($i + 1) -lt $normalized.Length -and [char]::IsLowSurrogate($normalized[$i + 1])) { $unit = $normalized.Substring($i, 2) }
                    [void]$units.Add(@{ Unit = $unit; Offset = $i })
                    $i += $unit.Length
                }
                $rescuers = @()
                for ($u = 0; $u -lt $units.Count; $u++) {
                    $without = $normalized.Substring(0, $units[$u].Offset) + $normalized.Substring($units[$u].Offset + $units[$u].Unit.Length)
                    $ok = $false
                    if ($without.Length -gt 0) { try { [void]$idn.GetAscii($without); $ok = $true } catch { $ok = $false } }
                    if ($ok) { $rescuers += $u }
                }
                $culprit = -1
                if ($rescuers.Count -eq 1) { $culprit = $rescuers[0] }
                elseif ($rescuers.Count -eq 0) {
                    for ($u = 0; $u -lt $units.Count -and $culprit -lt 0; $u++) {
                        for ($v = $u + 1; $v -lt $units.Count -and $culprit -lt 0; $v++) {
                            $without = $normalized.Substring(0, $units[$u].Offset) + $normalized.Substring($units[$u].Offset + $units[$u].Unit.Length, $units[$v].Offset - $units[$u].Offset - $units[$u].Unit.Length) + $normalized.Substring($units[$v].Offset + $units[$v].Unit.Length)
                            $ok = $false
                            if ($without.Length -gt 0) { try { [void]$idn.GetAscii($without); $ok = $true } catch { $ok = $false } }
                            if ($ok) { $culprit = $u }
                        }
                    }
                }
                if ($culprit -ge 0) {
                    $unit = [string]$units[$culprit].Unit
                    $code = $(if ($unit.Length -eq 2) { [char]::ConvertToUtf32($unit, 0) } else { [int]$unit[0] })
                    # The occurrence the search selected, not the first: a repeated character can be valid in one place and
                    # not in another (round 10), so the occurrences before it in the normalised label are counted and the
                    # same occurrence is found in the label as configured.
                    $before = 0
                    for ($w = 0; $w -lt $culprit; $w++) { if ([string]::Equals([string]$units[$w].Unit, $unit, [System.StringComparison]::Ordinal)) { $before++ } }
                    $at = -1
                    $from = 0
                    for ($w = 0; $w -le $before; $w++) { $at = $label.IndexOf($unit, $from, [System.StringComparison]::Ordinal); if ($at -lt 0) { break }; $from = $at + $unit.Length }
                    if ($at -lt 0) { $at = [int]$units[$culprit].Offset }
                    return ("U+{0:X4} at position {1} cannot be encoded for the wire: IDNA refuses it" -f $code, (& $scalarPosition ($position - 1 + $at)))
                }
                return ("the label at position {0} cannot be encoded for the wire: IDNA refuses it as a whole - more than 63 characters once encoded, or a combination no single character explains" -f (& $scalarPosition ($position - 1)))
            }
            # Case is folded before the comparison by the invariant lowercase mapping (backlog #68): IDNA lowercases
            # every letter it can, so a capital letter is not a change to the name on the wire - 'UBER.de' with a
            # capital U-diaeresis is asked as 'uber.de' with a small one, and refusing it served nobody. The simple
            # lowercase mapping is the right width because it changes only what IDNA also changes: measured on this
            # runtime (.NET Framework 4), it leaves U+00DF, U+1E9E, U+017F, U+03C2 and U+0130 exactly as they are,
            # while IDNA sends them as 'ss', 'ss', 's', a sigma and 'i'+U+0307 - so each of those still differs from
            # what came back and is still refused. What this replaced folded ASCII A-Z alone, which refused a capital
            # letter IDNA merely lowercases; what came before that was a culture-free ignore-case comparison, which
            # folded too much and let a label IDNA sends as 'asb' pass as 'a<U+017F>b' (PR #58, round 2).
            $folded = $normalized.ToLowerInvariant()
            # Ordinal, not -cne: PowerShell's string operators compare linguistically, and the invariant culture ignores a
            # zero-width joiner or a soft hyphen and equates the eszett with ss - the cases this rule exists to refuse.
            if (-not [string]::Equals($decoded, $folded, [System.StringComparison]::Ordinal)) {
                $index = 0
                $limit = [math]::Min($decoded.Length, $folded.Length)
                while ($index -lt $limit -and [int]$decoded[$index] -eq [int]$folded[$index]) { $index++ }
                if ($index -ge $normalized.Length) { $index = $normalized.Length - 1 }
                $code = [int]$normalized[$index]
                $unit = [string]$normalized[$index]
                if ([char]::IsHighSurrogate($normalized[$index]) -and ($index + 1) -lt $normalized.Length -and [char]::IsLowSurrogate($normalized[$index + 1])) { $code = [char]::ConvertToUtf32($normalized, $index); $unit = $normalized.Substring($index, 2) }
                # The position is the character's in the label as configured: NFC composition may have shortened the
                # label before this index, so the character is looked for where the operator typed it (round 5).
                $before = 0
                $from = 0
                while ($true) { $hit = $normalized.IndexOf($unit, $from, [System.StringComparison]::Ordinal); if ($hit -lt 0 -or $hit -ge $index) { break }; $before++; $from = $hit + $unit.Length }
                $at = -1
                $from = 0
                for ($w = 0; $w -le $before; $w++) { $at = $label.IndexOf($unit, $from, [System.StringComparison]::Ordinal); if ($at -lt 0) { break }; $from = $at + $unit.Length }
                if ($at -lt 0) { $at = $index }
                return ("U+{0:X4} at position {1} would be dropped or changed by IDNA, so the name asked would not be the name configured" -f $code, (& $scalarPosition ($position - 1 + $at)))
            }
        }
        # A disallowed ASCII character is looked for in the label as configured, not in the encoded form: for a label
        # beyond ASCII the encoded form is Punycode, where the character sits after 'xn--' (round 5); the encoded form is
        # checked too, in case IDNA ever produced one, and then the position is the encoded form's.
        $outside = [regex]::Match($label, '[\x00-\x7F-[A-Za-z0-9_-]]')
        if ($outside.Success) { return ("U+{0:X4} at position {1} is not a letter, a digit, a hyphen or an underscore" -f [int]$label[$outside.Index], (& $scalarPosition ($position - 1 + $outside.Index))) }
        $outside = [regex]::Match($encoded, '[^A-Za-z0-9_-]')
        if ($outside.Success) { return ("U+{0:X4} at position {1} of the encoded form is not a letter, a digit, a hyphen or an underscore" -f [int]$encoded[$outside.Index], ($outside.Index + 1)) }
        if ($encoded.Length -gt 63) { return ("the label at position {0} is longer than 63 characters" -f (& $scalarPosition ($position - 1))) }
        if ($encoded.StartsWith("-") -or $encoded.EndsWith("-")) { return ("the label at position {0} starts or ends with a hyphen" -f (& $scalarPosition ($position - 1))) }
        $encodedLength += $encoded.Length + 1
        $position += $label.Length + 1
    }
    if (($encodedLength - 1) -gt 253) { return "the name is longer than 253 characters once encoded" }
    return ""
}

# The host of a URL as it was written, not as System.Uri shows it: Uri lowercases the host and normalises an
# internationalised one before exposing .Host, so a URL judged through .Host would pass a host the rule refuses
# everywhere else - https://<capital U-umlaut>BER.de/ came back as the lowercase form (PR #58, round 3). The authority
# is what follows the scheme's "//" up to the first "/", "?" or "#"; userinfo before "@" and a port after the last
# ":" are dropped; an IPv6 literal keeps what is between its brackets. Ordinal searches throughout.
function Get-UrlConfiguredHost {
    param([string]$Url)
    $text = ([string]$Url).Trim()
    # The "//" that opens an authority follows the scheme's colon and nothing else: an absolute URI without an
    # authority whose path carries "//" later (http:path//example.com) has no host, and Uri accepts it with an
    # empty one, so a search for the first "//" anywhere named a host the client could not send to (PR #58, round 4).
    $colonAt = $text.IndexOf([char]":")
    if ($colonAt -lt 0 -or $text.Length -lt $colonAt + 3) { return "" }
    if ([int]$text[$colonAt + 1] -ne 47 -or [int]$text[$colonAt + 2] -ne 47) { return "" }
    $authority = $text.Substring($colonAt + 3)
    $end = $authority.IndexOfAny([char[]]@("/", "?", "#", "\"))
    if ($end -ge 0) { $authority = $authority.Substring(0, $end) }
    $at = $authority.LastIndexOf([char]"@")
    if ($at -ge 0) { $authority = $authority.Substring($at + 1) }
    if ($authority.Length -gt 0 -and [int]$authority[0] -eq 91) {
        $close = $authority.IndexOf([char]"]")
        if ($close -lt 0) { return "" }
        return $authority.Substring(1, $close - 1)
    }
    $colon = $authority.LastIndexOf([char]":")
    if ($colon -ge 0) { $authority = $authority.Substring(0, $colon) }
    return $authority
}

# The suffix a URL's row or configuration error carries when the URL is an absolute http(s) address whose host is what
# cannot be used (backlog #54): the host's reason, named; nothing for a URL that fails for its scheme or its shape.
function Get-UrlHostProblemSuffix {
    param([string]$Url)
    $uri = $null
    if (-not [System.Uri]::TryCreate([string]$Url, [System.UriKind]::Absolute, [ref]$uri)) { return "" }
    if (-not ($uri.Scheme -eq "http" -or $uri.Scheme -eq "https")) { return "" }
    $written = [string](Get-UrlConfiguredHost $Url)
    $problem = [string](Get-HostNameSyntaxProblem $written)
    if ($problem.Length -gt 0) { return ("; the host: " + $problem) }
    # The host the rule judged has to be the host the request would go to. The extractor mirrors Uri's parsing, and
    # every place the two could still disagree - a separator one of them knows and the other does not - would let a
    # host the rule refuses through under a name that passes; so the wire form of the written host is compared with
    # what Uri would send to (IdnHost, or the parsed address for an IPv6 literal), and a disagreement refuses the URL
    # by naming both (PR #58, round 6). Uri's own view is used only here, and only to confirm the extractor's.
    $sent = ""
    $wire = ""
    try {
        $uriHost = [string]$uri.IdnHost
        if ($written.Contains(":")) {
            $wire = [System.Net.IPAddress]::Parse($written).ToString()
            $sent = [System.Net.IPAddress]::Parse($uriHost).ToString()
        }
        else {
            $wire = (New-Object System.Globalization.IdnMapping).GetAscii($written.Normalize([System.Text.NormalizationForm]::FormC)).ToLowerInvariant()
            $sent = $uriHost.ToLowerInvariant()
        }
    }
    catch { $sent = "" }
    if ([string]::Equals($wire, $sent, [System.StringComparison]::Ordinal)) { return "" }
    return ("; the host as written, " + $written + ", is not the host the request would be sent to, " + $(if ($sent.Length -gt 0) { $sent } else { "(none)" }))
}

function Test-HostNameSyntax {
    param([string]$Value)
    return (([string](Get-HostNameSyntaxProblem $Value)).Length -eq 0)
}

function Test-PingTargetSyntax {
    param([string]$Value)

    # Can this value become a ping target at all, which is a different question from whether it answers (backlog #39).
    # A blank address, or one carrying a scheme, a path, a user or a port, cannot be turned into a target: nothing is
    # sent, so nothing is learned about the network and the row that says so is a fact about this run's input. A name
    # that is well formed and does not resolve is the opposite case - it was tested, the resolver answered, and that
    # answer is a measurement this rule must not touch. The two placeholders are targets the run resolves itself.
    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $false }
    if ($text -eq "AUTO_GATEWAY" -or $text -eq "AUTO_DNS") { return $true }
    # A name no resolver can accept is the same kind of input problem as a URL: an empty label such as
    # foo..bar, a label of more than 63 characters, a whole name of more than 253, or a label that starts or
    # ends with a hyphen. Ping.Send throws before any packet exists, and the catch around it records that as a
    # lost reply - so a required target spelled this way was reported as a measured 100% loss, which is the
    # confusion this helper exists to prevent (PR #41, round 5). Structure is all that is tested here. The
    # characters are left alone, because a well-formed name that does not resolve is the opposite case - it was
    # asked, and it was answered - and because an internationalised name has to stay usable.
    return (Test-HostNameSyntax $text)
}

# v1.2: run options come from the entry point (launcher switches) or the IT options panel; the JSON config file is never written.
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

    # An added target carries its value in the row title, so two of the same kind are told apart in the table and
    # in the summary that names the ones which did not answer (PR #35, round 2). The ping row is the exception and
    # keeps the plain name: Test-PingTargets already writes the title as "<name>: <target>", so adding the address
    # here would print it twice (round 3).
    foreach ($value in @(@($Overrides["PingTarget"]) | ForEach-Object { ([string]$_) -split '[,;\s]+' } | ForEach-Object { ([string]$_).Trim() })) {
        if ([string]::IsNullOrWhiteSpace([string]$value)) { continue }
        $raw.Ping += [string]$value
        $config.Tests.PingTargets = @($config.Tests.PingTargets) + [pscustomobject][ordered]@{ Name = "Extra ping"; Address = [string]$value; Required = $false }
        $extra.Ping += [string]$value
    }
    foreach ($value in @(@($Overrides["DnsName"]) | ForEach-Object { ([string]$_) -split '[,;\s]+' } | ForEach-Object { ([string]$_).Trim() })) {
        if ([string]::IsNullOrWhiteSpace([string]$value)) { continue }
        $raw.Dns += [string]$value
        $config.Tests.DnsNames = @($config.Tests.DnsNames) + [pscustomobject][ordered]@{ Name = ("Extra DNS " + [string]$value); Host = [string]$value; Required = $false }
        $extra.Dns += [string]$value
    }
    foreach ($value in @(@($Overrides["TcpTarget"]) | ForEach-Object { ([string]$_) -split '[,;\s]+' } | ForEach-Object { ([string]$_).Trim() })) {
        if ([string]::IsNullOrWhiteSpace([string]$value)) { continue }
        $raw.Tcp += [string]$value
        $parts = ([string]$value).Split(':')
        $port = 0
        if ($parts.Count -eq 2) { $port = ConvertTo-IntSafe $parts[1] 0 }
        if (-not (Test-TcpTargetSyntax $value)) {
            # The notice says what happened; the record is what puts a row where the result belonged (backlog #39).
            # A dropped target that leaves only a notice under Program Environment shows the reader an empty TCP
            # section, which reads as a check nobody configured rather than one that was thrown away.
            [void]$script:RunOptionMessages.Add("Ignored extra TCP target '$value': expected host:port with a host that can be used." + $(if ($parts.Count -eq 2 -and -not (Test-HostNameSyntax $parts[0])) { " The host: " + (Get-HostNameSyntaxProblem $parts[0]) + "." } else { "" }))
            [void]$script:DroppedTargets.Add([pscustomobject][ordered]@{ Kind = "Tcp"; Value = [string]$value })
            continue
        }
        $config.Tests.TcpTargets = @($config.Tests.TcpTargets) + [pscustomobject][ordered]@{ Name = ("Extra TCP " + [string]$value); Host = $parts[0]; Port = $port; Required = $false; Group = "" }
        $extra.Tcp += [string]$value
    }
    foreach ($value in @(@($Overrides["HttpUrl"]) | ForEach-Object { ([string]$_) -split '\s+' } | ForEach-Object { ([string]$_).Trim() })) {
        if ([string]::IsNullOrWhiteSpace([string]$value)) { continue }
        $raw.Http += [string]$value
        $config.Tests.HttpTargets = @($config.Tests.HttpTargets) + [pscustomobject][ordered]@{ Name = ("Extra URL " + [string]$value); Url = [string]$value; Required = $false; Group = "" }
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
        # The ceiling is never below the starting count (backlog #51): PingCount is what each ping target is sent to
        # begin with, PingCountMaximum the furthest this run will go when replies are lost. Writing the pair the
        # wrong way round does not cut the starting count down - the configuration check says so, and this takes the
        # larger of the two, so what the person asked to be sent is sent.
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
    if ($options.EntryPoint -eq "IT") { $parts += "IT entry" } else { $parts += "User entry" }
    $extras = @()
    foreach ($value in @($options.ExtraTargets.Ping)) { $extras += "ping $value" }
    foreach ($value in @($options.ExtraTargets.Dns)) { $extras += "dns $value" }
    foreach ($value in @($options.ExtraTargets.Tcp)) { $extras += "tcp $value" }
    foreach ($value in @($options.ExtraTargets.Http)) { $extras += "url $value" }
    if ($extras.Count -gt 0) { $parts += ("extra targets: {0}" -f ($extras -join ", ")) }
    $parts += ("ping count {0}" -f $options.PingCount)
    $parts += ("ping ceiling {0}" -f $options.PingCountMaximum)
    $parts += ("sample {0} s" -f $options.SampleSeconds)
    # backlog #65: named only where the reads inside the window are on, because 0 is a value and the profile lists what ran.
    $intervalSeconds = ConvertTo-IntSafe (Get-PropertyValue $options "IntervalSeconds" 0) 0
    if ($intervalSeconds -gt 0) { $parts += ("reads inside it every {0} s" -f $intervalSeconds) }
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

function Get-DhcpServerTable {
    # backlog #32: which server answered the lease. The NetTCPIP cmdlets carry the DHCP mode and not the server, so
    # the one source is Win32_NetworkAdapterConfiguration.DHCPServer - the same class the CIM fallback reads for
    # everything. One query for every IP-enabled configuration, keyed by interface index, so that the preferred path
    # pays one CIM call and not one per adapter. $null means the class could not be read at all, which the adapter
    # row reports as the datum being unavailable rather than as the adapter having no lease (closed item #5's shape:
    # an unknown is never reported as a value). The query is not attempted twice - it is not a performance-counter
    # read, and 1.2.8 recorded why the adapter-configuration queries keep their single attempt.
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
            # $null where the class could not be read; otherwise the server's address, or "" where the configuration
            # holds none (a static address, or a lease that never came).
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
    # Four lists, because a verdict cannot attach to part of a row (backlog #39). What the organisation's own standard
    # says, and what the thresholds are, is what every other row was judged against: a broken one makes the verdict
    # untrustworthy and keeps its weight. A target entry that cannot be tested, a check flag that is not a boolean and
    # a hop count out of range are facts about this run's input that undermine nothing measured - and the target
    # entries are now reported by the check that would have made the measurement, in the section it belonged in, so
    # this row no longer convicts the same typo a second time.
    $errors = New-Object System.Collections.ArrayList
    $warnings = New-Object System.Collections.ArrayList
    $inputErrors = New-Object System.Collections.ArrayList
    $inputWarnings = New-Object System.Collections.ArrayList
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
        $hostName = (ConvertTo-SafeString (Get-PropertyValue $target "Host" "")).Trim()
        $port = ConvertTo-IntSafe (Get-PropertyValue $target "Port" 0) 0
        if (-not (Test-HostNameSyntax $hostName) -or $port -lt 1 -or $port -gt 65535) {
            [void]$inputErrors.Add("The host or port for TcpTargets '$name' is invalid: Host=$hostName, Port=$port" + $(if (-not (Test-HostNameSyntax $hostName)) { "; the host: " + (Get-HostNameSyntaxProblem $hostName) } else { "" }))
        }
    }

    foreach ($target in @($tests.HttpTargets)) {
        if ($null -eq $target) { continue }
        $name = ConvertTo-SafeString (Get-PropertyValue $target "Name" "HTTP target")
        $url = ConvertTo-SafeString (Get-PropertyValue $target "Url" "")
        if (-not (Test-HttpTargetSyntax $url)) {
            [void]$inputErrors.Add("The URL for HttpTargets '$name' is invalid: $url" + (Get-UrlHostProblemSuffix $url))
        }
    }

    foreach ($target in @($tests.PingTargets)) {
        if ($null -eq $target) { continue }
        $name = ConvertTo-SafeString (Get-PropertyValue $target "Name" "Ping target")
        $address = (ConvertTo-SafeString (Get-PropertyValue $target "Address" "")).Trim()
        if (-not (Test-PingTargetSyntax $address)) {
            [void]$inputErrors.Add("The address for PingTargets '$name' cannot be used as a ping target: $address; " + (Get-HostNameSyntaxProblem $address))
        }
    }

    # The near-end target (backlog #60) has a narrower rule than the other ping targets: an IPv4 address, because the
    # run has to know it is on the local subnet before anything is sent, and a name would put that rung behind the
    # resolver. A placeholder fails the same rule - the gateway cannot serve as the near-end rung, and AUTO_DNS may
    # resolve to the gateway or to a server beyond it. Which subnet it is on is a fact about this machine, so that is
    # judged where the probes are sent, not here.
    $nearEnd = Get-PropertyValue $tests "NearEndTarget" $null
    if ($null -ne $nearEnd) {
        $nearEndAddress = (ConvertTo-SafeString (Get-PropertyValue $nearEnd "Address" "")).Trim()
        if (-not [string]::IsNullOrWhiteSpace($nearEndAddress) -and -not (Test-NearEndAddressSyntax $nearEndAddress)) {
            [void]$inputErrors.Add("The address for NearEndTarget cannot be used as the near-end target, which has to be an IPv4 address in dotted-decimal form on this computer's own subnet and not the gateway: $nearEndAddress")
        }
        elseif ([string]::IsNullOrWhiteSpace($nearEndAddress) -and [bool](Get-PropertyValue $nearEnd "Required" $false)) {
            # Blank and optional is the shipped, disabled state; blank and required is a required check with nothing
            # to check, which the run reports as a required check that did not run (PR #51, round 3).
            [void]$inputErrors.Add("NearEndTarget is marked as required but has no address: give it the address of a host on this computer's own subnet, or set Required to false")
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
            [void]$inputErrors.Add("DnsNames contains a blank Host value.")
        }
        elseif (-not (Test-HostNameSyntax $hostName)) {
            [void]$inputErrors.Add("DnsNames contains a host name that cannot be used as a DNS target: $hostName; " + (Get-HostNameSyntaxProblem $hostName))
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
            [void]$warnings.Add("$($setting.Name) must be a whole number in the supported range (current value: $($setting.Value)); the built-in default will be used.")
        }
        elseif ((ConvertTo-IntSafe $setting.Value 0) -le 0) {
            [void]$warnings.Add("$($setting.Name) should be greater than 0; the built-in minimum will be applied.")
        }
    }

    # backlog #65: the interval of the reads inside the sample window, where 0 is a value (off) and not a mistake.
    $intervalValue = Get-PropertyValue $tests "RetransmissionIntervalSeconds" $null
    if ($null -ne $intervalValue -and -not (Test-IsWholeNumber $intervalValue)) {
        [void]$warnings.Add(("RetransmissionIntervalSeconds must be a whole number of seconds - 0 switches the reads inside the sample window off (current value: {0}); the built-in default will be used." -f $intervalValue))
    }
    elseif ($null -ne $intervalValue -and (ConvertTo-IntSafe $intervalValue 0) -lt 0) {
        [void]$warnings.Add(("RetransmissionIntervalSeconds must be 0 or more (current value: {0}); the built-in default will be used." -f $intervalValue))
    }

    $checks = $script:Config.Checks
    foreach ($flagName in @("WifiRf", "RouteTable", "GatewayNeighbor", "ProxySettings", "Traceroute", "DriverInfo", "WifiRetryCounters")) {
        $flagValue = Get-PropertyValue $checks $flagName
        if ($null -ne $flagValue -and -not ($flagValue -is [bool])) {
            [void]$inputWarnings.Add("Checks.$flagName must be true or false (current value: $flagValue); the check is disabled.")
        }
    }
    $hopsValue = Get-PropertyValue $checks "TracerouteHops"
    if ($null -ne $hopsValue -and (-not (Test-IsWholeNumber $hopsValue) -or (ConvertTo-IntSafe $hopsValue 0) -lt 1 -or (ConvertTo-IntSafe $hopsValue 0) -gt 10)) {
        [void]$inputWarnings.Add("Checks.TracerouteHops must be a whole number from 1 to 10 (current value: $hopsValue); the built-in default will be used.")
    }

    $countThresholdNames = @("TcpRetransmissionCriticalCount", "MinimumTcpSegmentsForRate", "MinimumTcpRetransmissionsForVerdict", "AdapterErrorWarningDelta", "AdapterErrorCriticalDelta", "AdapterDiscardWarningDelta", "AdapterDiscardCriticalDelta")
    foreach ($thresholdName in @("PacketLossWarningPercent", "PacketLossCriticalPercent", "LatencyWarningMs", "LatencyCriticalMs", "TcpRetransmissionWarningPercent", "TcpRetransmissionCriticalPercent", "TcpRetransmissionCriticalCount", "MinimumTcpSegmentsForRate", "MinimumTcpRetransmissionsForVerdict", "AdapterErrorWarningDelta", "AdapterErrorCriticalDelta", "AdapterDiscardWarningDelta", "AdapterDiscardCriticalDelta")) {
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
        elseif (($countThresholdNames -contains $thresholdName) -and (ConvertTo-DoubleSafe $thresholdValue 0) -lt 0) {
            # A count threshold is a number of things, and a negative number of things counts nothing - while
            # until now it took the whole analysis down at the unsigned cast (PR #49, round 1). It is treated
            # like every other value this tool cannot use: the built-in default, and named here.
            [void]$warnings.Add("$thresholdName must not be negative (current value: $thresholdValue); the built-in default will be used.")
        }
    }

    # The two ping counts are an ordered pair like the thresholds are (backlog #51). A ceiling below the starting
    # count does not break a run - the starting count becomes the ceiling - but it is a configuration file saying
    # something it cannot mean, so it is reported the way the threshold pairs are.
    $startCount = ConvertTo-IntSafe $tests.PingCount 4
    $ceilingCount = ConvertTo-IntSafe $tests.PingCountMaximum 21
    if ($ceilingCount -lt $startCount) {
        [void]$warnings.Add("Ping counts are not ordered correctly: PingCount=$startCount, PingCountMaximum=$ceilingCount; the starting count will be used as the ceiling.")
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
    elseif ($warnings.Count -eq 0 -and $inputErrors.Count -eq 0 -and $inputWarnings.Count -eq 0) {
        Add-CheckResult -Category "Program Configuration" -Check "Configuration Validation" -Status "PASS" -Message "Configuration value format validation passed." -Details "" -Tag "config" | Out-Null
    }

    if ($warnings.Count -gt 0) {
        Add-CheckResult -Category "Program Configuration" -Check "Configuration Thresholds" -Status "WARN" -Message ("The configuration file contains {0} threshold value(s) that need attention." -f $warnings.Count) -Details (@($warnings) -join [Environment]::NewLine) -Tag "config" | Out-Null
    }

    if ($inputErrors.Count -gt 0) {
        Add-CheckResult -Category "Program Configuration" -Check "Configured Targets" -Status "ERROR" -Message ("{0} target(s) given to this run cannot be tested; each is reported where its own result belonged, and none of them changes the overall result." -f $inputErrors.Count) -Details (@($inputErrors) -join [Environment]::NewLine) -Tag "config" -Weightless | Out-Null
    }

    if ($inputWarnings.Count -gt 0) {
        Add-CheckResult -Category "Program Configuration" -Check "Configured Checks" -Status "WARN" -Message ("{0} option value(s) could not be used as written; a built-in default was applied or the check was disabled, and the overall result is unchanged by it." -f $inputWarnings.Count) -Details (@($inputWarnings) -join [Environment]::NewLine) -Tag "config" -Weightless | Out-Null
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

    # Four shapes, and the order matters (backlog #32). A static address has no lease, so no server is named whatever
    # the configuration holds. Then the datum being unavailable - the class could not be read - which is said as such.
    # Then the address that answered. Last, a configuration that holds no server address although nothing says the
    # address is static: DHCP that never got a lease, or a mode this run could not read.
    if ($DhcpEnabled -eq $false) { return "none (static address, no lease)" }
    if ($null -eq $DhcpServer) { return "unavailable (read from Win32_NetworkAdapterConfiguration, which could not be queried; the NetTCPIP cmdlets have no such field)" }
    if (-not [string]::IsNullOrWhiteSpace([string]$DhcpServer)) { return [string]$DhcpServer }
    return "none recorded (no server address is held for this adapter)"
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
        # backlog #32: the server that answered the lease, beside the mode it qualifies - the SOP's rogue-DHCP question
        # is answered by this line. A static address has no lease to name; a class that could not be read leaves the
        # datum unavailable rather than absent, because an empty field would read as "no server", which is a claim.
        $dhcpServerText = Get-DhcpServerText -DhcpEnabled $adapter.DhcpEnabled -DhcpServer (Get-PropertyValue $adapter "DhcpServer" $null)

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
            "DHCP server: $dhcpServerText",
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
function Get-RouteSelection {
    param([string]$Target)

    # backlog #59: which adapter a ping left by. Find-NetRoute answers what the route table would choose at the
    # moment it is asked, and Invoke-PingMeasurement then sends its probes unbound - so what this returns is a
    # selection and never a record of the path the replies took. Test-PingTargets asks twice, before and after a
    # target's probes, so that a route which changed during the test is reported rather than guessed; that is the
    # before-and-after shape the adapter counters already use. Two objects come back, measured on the reference
    # machine: the local address, which carries the source and the interface, and the route, which carries the next
    # hop. The source is read from whichever object has an IPAddress rather than from the first, because the order
    # is the cmdlet's to choose and not this tool's to rely on. Cost, measured: about 13 ms once the CIM subsystem
    # is warm, and by the time a run reaches the ping checks the adapter checks have already paid the warm-up.
    # Absence and failure are the datum being unavailable, never the row failing - closed item #5's shape.
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

    # The route object carries the next hop (PR #51, round 5): 0.0.0.0 - or :: - is an on-link route, the network the
    # adapter is attached to; any other next hop is a router, and a probe that crosses a router has not measured the
    # local path however local its target is. A /32 to a host on the subnet via the default gateway keeps the same
    # source and interface, which is why the source alone cannot attest a rung.
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

    # One side of the pair, as the row says it. Every unavailable case names its own reason, because "unavailable"
    # without one is the kind of field a reader has to guess at.
    if ($null -eq $Selection) { return "unavailable (the route selection was not read)" }
    if ($Selection.Resolved) {
        $text = ("source {0} via {1}" -f $Selection.SourceAddress, $Selection.InterfaceAlias)
        # The next hop is the part of a selection that decides whether a rung can be claimed (PR #51, round 6): on-link
        # is the connected network, anything else is a router the probes crossed. So the reading names it, and a next
        # hop that changed between the two lookups reads as a change - which is what the rung line's refusal rests on.
        # -NoHop is the comparison that asks WHICH ADAPTER and nothing more; a shape without a hop reads as before.
        $nextHop = ConvertTo-SafeString $Selection.NextHop
        if (-not $NoHop -and -not [string]::IsNullOrWhiteSpace($nextHop)) {
            if ($Selection.OnLink -eq $true) { $text += ", on-link" } else { $text += (" through {0}" -f $nextHop) }
        }
        return $text
    }
    switch ([string]$Selection.Reason) {
        "cmdlet"     { return "unavailable (Find-NetRoute is not available on this system)" }
        "noroute"    { return "unavailable (the route table returned no route for this target)" }
        "notaddress" { return "unavailable (the route table is asked by address, and no address was available for this target)" }
        "noreply"    { return "unavailable (this target is a name and nothing replied, so no address was available to look up)" }
        "error"      { return "unavailable (the route lookup failed)" }
    }
    return "unavailable (the route selection was not read)"
}

function Get-RouteMethodText {
    param([string]$Target, [string]$LookupAddress, [bool]$TargetIsAddress, [int]$ExtraCount = 0)

    # The Method line has to describe the lookup that happened, not the one the address case makes (PR #45, round 2).
    # A name is looked up once, after the probes, by the address the replies came from; a name nothing answered is
    # not looked up at all. It is a function rather than an inline string so that the unit step can hold it to that.
    if ($TargetIsAddress) {
        return ("; the route selection comes from Find-NetRoute -RemoteIPAddress {0}, read before and after the probes" -f $Target)
    }
    if ([string]::IsNullOrWhiteSpace($LookupAddress)) {
        return "; no route lookup was made, because this target is a name and nothing replied to give an address"
    }
    if ($ExtraCount -gt 0) {
        return ("; the route selection comes from Find-NetRoute -RemoteIPAddress, read once after the probes for each of the {0} addresses the replies came from" -f ($ExtraCount + 1))
    }
    return ("; the route selection comes from Find-NetRoute -RemoteIPAddress {0}, the address the replies came from, read once after the probes" -f $LookupAddress)
}

function Format-RouteSelection {
    param([object]$Before, [object]$After, [string]$LookupAddress = "", [object[]]$Others = @())

    # Three shapes out of the two lookups. Both resolved and equal is the ordinary line. Any disagreement between
    # them is reported as a change - including one resolving where the other did not, because that is a disagreement
    # about which adapter was in play and is exactly what this row exists to make visible. Two identical failures
    # say why, once.
    $beforeText = Get-RouteSelectionText $Before
    $afterText = Get-RouteSelectionText $After
    $afterKey = Get-RouteSelectionText $After -NoHop

    # A target given as a name has no address to ask the route table about until something replies, so no pair can be
    # taken and the row says so rather than implying one (PR #45, round 1). The tool does not resolve the name itself:
    # that would put the ping check behind the resolver, on a machine whose resolver is often what is being diagnosed.
    if ($null -eq $Before) {
        # The whole set is built before anything returns. Round 4 caught the earlier shape returning on an unresolved
        # first address and never reading the others, which hid a usable adapter behind one failed lookup and left the
        # Method line claiming every address had been read. Whether the first one resolved decides the wording, never
        # whether the rest are consulted.
        $agree = $true
        $primaryResolved = ($null -ne $After -and $After.Resolved)
        $allResolved = $primaryResolved
        $sameInterface = $true
        $eachText = @(("{0}: {1}" -f $LookupAddress, $afterText))
        foreach ($other in @($Others)) {
            $otherText = Get-RouteSelectionText $other.Selection
            $eachText += ("{0}: {1}" -f $other.Address, $otherText)
            if ((Get-RouteSelectionText $other.Selection -NoHop) -ne $afterKey) { $agree = $false }
            if ($null -eq $other.Selection -or -not $other.Selection.Resolved) { $allResolved = $false }
            elseif ($primaryResolved -and $other.Selection.InterfaceAlias -ne $After.InterfaceAlias) { $sameInterface = $false }
        }
        $addressCount = @($Others).Count + 1

        # A lookup that did not answer is not the route table deciding differently (PR #45, round 5). Only where every
        # address got an answer can the difference between them be called a routing difference; where one of them did
        # not, what differs is the lookups, and a transient provider failure must not be published as a conclusion
        # about the network.
        #
        # And the question this row exists to answer is WHICH ADAPTER, so that is what the comparison is on (round 6).
        # Two addresses can select the same interface from different source addresses - an IPv4 and an IPv6 reply over
        # one adapter is the ordinary way it happens - and calling that an adapter the row cannot identify would be
        # inventing an ambiguity out of a difference that is not one.
        if (-not $agree) {
            if (-not $allResolved) {
                return ("Route selection: this target is a name and its replies came from {0} addresses whose lookups did not all answer, and did not all answer the same way - {1}. This row cannot attribute the measurement to one adapter, and what differs here is the lookups rather than a decision the route table made." -f $addressCount, ($eachText -join "; "))
            }
            if ($sameInterface) {
                return ("Route selection: this target is a name and its replies came from {0} addresses which the route table sends through the same interface, {1}, from different source addresses - {2}. The adapter is not in doubt; which source the system chooses depends on which of those addresses is being reached." -f $addressCount, $After.InterfaceAlias, ($eachText -join "; "))
            }
            return ("Route selection: this target is a name and its replies came from {0} addresses which the route table does not send through the same interface - {1}. This row cannot attribute the measurement to one adapter." -f $addressCount, ($eachText -join "; "))
        }
        if ($primaryResolved) {
            $sentence = ("Route selection: {0}, looked up for {1} after the probes - this target is a name, so there was no address to ask about before them and no before-and-after pair was taken. The probes are not bound to it." -f $afterText, $LookupAddress)
            if ($addressCount -gt 1) {
                $sentence += (" Its replies came from {0} addresses and the route table selects the same source and interface for every one of them." -f $addressCount)
            }
            return $sentence
        }
        if ($addressCount -gt 1) {
            return ("Route selection: {0}, for every one of the {1} addresses its replies came from. This row cannot say which adapter the probes left by." -f $afterText, $addressCount)
        }
        return ("Route selection: {0}. This row cannot say which adapter the probes left by." -f $afterText)
    }

    if ($null -ne $Before -and $null -ne $After -and $Before.Resolved -and $After.Resolved -and
        $Before.SourceAddress -eq $After.SourceAddress -and $Before.InterfaceAlias -eq $After.InterfaceAlias -and
        [string]$Before.NextHop -eq [string]$After.NextHop) {
        return ("Route selection: {0} - the route the table chooses for this target, looked up before and after the probes. The probes are not bound to it, so this is what was selected and not the path the replies took." -f $beforeText)
    }

    if ($beforeText -eq $afterText) {
        return ("Route selection: {0}. This row cannot say which adapter the probes left by." -f $beforeText)
    }

    return ("Route selection changed during this test: {0} before the probes, {1} after them. The probes are not bound to either, so this row cannot say which of them carried them." -f $beforeText, $afterText)
}

# -----------------------------------------------------------------------------
# Adaptive ping sampling, and what a loss figure is allowed to decide (backlog #51).
# -----------------------------------------------------------------------------
function Get-PingCountForThreshold {
    param([double]$WarningPercent)

    # The smallest number of echo requests at which ONE lost reply is below the packet-loss warning threshold. One
    # lost reply out of n is 100/n per cent, so the first candidate is the smallest n with 100/n < w, which is
    # floor(100/w) + 1. That is the exact arithmetic, and the exact arithmetic is not what decides a row: the band
    # is read off the figure the row PRINTS, rounded to one decimal, which can be up to 0.05 above the exact one.
    # At a warning threshold of 4.8 %, one reply of twenty-one is 4.7619 %, prints as 4.8 and still warns - so the
    # candidate would have stopped the sample exactly where one packet still decides it, which is this item's own
    # defect one layer in (PR #49, round 1). The candidate is therefore stepped up until the printed figure really
    # is below the threshold, and the question is put to Get-LossBand so that the rule tested here can never drift
    # from the rule the row will use. The critical threshold passed in is the warning one, because the only
    # question is whether the printed figure stays under the warning threshold; which band it lands in above that
    # does not matter here.
    # The search terminates and is bounded: the printed figure reaches 0.0 at two thousand replies, and 0.0 is
    # below every positive threshold, so no positive threshold needs more than one step past that.
    # A threshold of zero or less is not something a count can get under, because every loss is at or above it. No
    # such n exists, and the caller is told so with 0 rather than with a number that would not work.
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

    # The band a loss figure falls in, computed from the figure the row prints - rounded to one decimal - so that
    # the row and the verdict can never disagree about the same number.
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

    # Whether the band this sample reached is one the sample can carry. Two questions, and a verdict is withheld
    # only where both answer yes:
    #   Coarse    - the sample is smaller than the count at which one lost reply stops reaching the warning
    #               threshold, so one packet is worth a whole band here. Four probes against the shipped 5 % is
    #               the shipped instance: one lost reply is 25 %, past the critical threshold as well, and the
    #               tool has no way to express "a little loss" at that count.
    #   OnePacket - the band would be a different one if one fewer reply had been lost. The verdict IS that packet.
    # Either on its own is ordinary, and a rule made of either alone would be wrong. Three lost of four is 75 % on
    # a coarse sample and two lost is still 50 %, so nothing there rests on one packet and the row keeps its
    # verdict; two lost of twenty-one turns on a packet, but twenty-one is a sample the threshold fits and 9.5 %
    # is a measurement. Only the pair is what this item measured.
    # The case where every reply was lost reaches here too, since PR #49 round 5: it used to be answered before
    # the loss thresholds on the ground that 100 % loss is conclusive, which is an argument about four probes and
    # was being applied to one. At one probe the two conditions below are both true and the verdict is withheld;
    # at four the second is false - three of four is still critical - and it stands. Nothing more is sent either
    # way, because no count makes 100 % loss more certain than it already is.
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

    # Whether to go on sampling this target, and how far. The configured count is where a target starts, not where
    # it stops, and what the first pass established decides which of three cases this is:
    #   every reply arrived - nothing is ambiguous, and a healthy run must not get slower than it was;
    #   nothing answered    - 100 % loss is conclusive at four probes and no larger count makes it more so, and
    #                         this is the one case where every extra probe costs a whole timeout;
    #   some but not all    - the ambiguous one. It is extended to the count at which one packet can no longer
    #                         decide the classification, or to the configured ceiling where that is lower.
    # A ceiling below the count the threshold needs is not an error and is not overridden here: the sample stays
    # coarse, and Get-PingLossClassification is what keeps a verdict off it.
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

    # How far apart the extra probes go. The seconds come out of the wait the run already owes the retransmission
    # window - Wait-ForMinimumTcpSample was going to spend them sleeping - so spreading a sample costs no
    # wall-clock time as long as it takes no more than that wait had left. Where nothing is left the gap is zero
    # and the probes go back to back, which is what a run did before this existed. The division is by the number
    # of probes and not by the gaps between them, which is one fewer, so the probes' own time has somewhere to
    # come from and the spread ends inside its budget rather than just outside it.
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

    # -Previous and -IntervalSeconds are backlog #51's adaptive sample. A measurement handed back here is added to
    # rather than replaced: the probes of the second pass carry on the attempt numbering, and every figure is
    # recomputed over the whole sample, so the row reports one measurement and not two. -IntervalSeconds spreads
    # those probes instead of sending them back to back - unlike ping.exe this sends with no delay between echoes,
    # so twenty of them land inside a fraction of a second and measure one instant twenty times, while what a
    # person is usually trying to catch is a connection that is intermittently unstable and needs span, not count.
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
                    [void]$attemptDetails.Add(("Attempt {0}: success, {1} ms, reply from {2}" -f $attempt, $reply.RoundtripTime, $reply.Address))
                }
                else {
                    [void]$attemptDetails.Add(("Attempt {0}: failed, status {1}" -f $attempt, $reply.Status))
                }
            }
            catch {
                [void]$attemptDetails.Add(("Attempt {0}: error, {1}" -f $attempt, (Add-NetworkErrorCause $_.Exception $_.Exception.Message -SingleLine)))
            }
            if ($script:GuiAvailable) {
                [System.Windows.Forms.Application]::DoEvents()
            }
            if ($IntervalSeconds -gt 0 -and $i -lt $Count) {
                # The gap is taken in short slices so that the window goes on painting and the progress line goes
                # on moving: a spread sample can occupy a minute of a run that used to spend that minute asleep.
                $slices = [int][math]::Max(1, [math]::Ceiling(($IntervalSeconds / 0.25)))
                $sliceMs = [int][math]::Round(($IntervalSeconds * 1000.0 / $slices))
                for ($slice = 1; $slice -le $slices; $slice++) {
                    if ($ProgressPercent -gt 0) {
                        Set-UiProgress -Percent $ProgressPercent -Text ("Spreading the rest of the ping sample for {0}: {1} to go" -f $Target, ($Count - $i))
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

    # The dotted-decimal spelling of an IPv4 address, or the trimmed text as given where it is not one. .NET's parser
    # accepts a single number, hexadecimal parts, fewer than four parts and leading zeros read as octal - 3221225994,
    # 0xC0.0.2.10, 192.0.2 and 192.0.2.010 all parse, the last one to 192.0.2.8 - so a comparison between a configured
    # spelling and an address the operating system reports has to be made on the parsed form (PR #51, round 2).
    $text = ([string]$Value).Trim()
    $parsed = $null
    if ([System.Net.IPAddress]::TryParse($text, [ref]$parsed) -and $parsed.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) { return $parsed.ToString() }
    return $text
}

function Test-NearEndAddressSyntax {
    param([string]$Value)

    # The near-end target's rule (backlog #60): an IPv4 address spelled the one way every parser reads alike - four
    # decimal numbers with dots and nothing else. The other forms .NET accepts mean different addresses to different
    # readers (192.0.2.010 is 192.0.2.8 to .NET and 192.0.2.10 to a person), and a row that probed one address while
    # the file named another would be the confusion this key exists to prevent. What the file says and what the probe
    # is sent to are therefore required to be the same string, here and in the configuration check.
    $text = ([string]$Value).Trim()
    if (-not (Test-IsValidIPv4Address $text)) { return $false }
    return ((Get-CanonicalIPv4Text $text) -eq $text)
}

function Test-NearEndTargetPlacement {
    param(
        [string]$Address,
        [object[]]$PrimaryAdapters
    )

    # Where the configured near-end target sits relative to this machine (backlog #60), decided before anything is
    # sent, because the row's whole claim is which segments its probes cross. Five answers: the address is one of the
    # primary adapters' gateways, so it cannot be the near-end rung - the gateway answers from its control plane and is
    # the next rung already; it is one of this computer's own addresses, so a probe to it is answered by this stack and
    # crosses no cable, radio or switch at all (PR #51, round 1); it is the network or the broadcast address of the
    # subnet it falls in, which no host holds; it is inside one of the primary adapters' IPv4 subnets, so it is the
    # near-end host; or it is none of these, so a probe to it would go through the gateway and measure the wrong thing.
    # The subnets are the address-with-prefix values the snapshot already carries; an adapter whose prefix is unknown
    # contributes no subnet, and a machine with no known subnet places nothing - which the row says rather than guessing.
    # Every comparison is made on the parsed, dotted-decimal form (PR #51, round 2): the rule the configuration check
    # applies refuses any other spelling, but the placement does not rely on that - a caller handing it 3221225994
    # gets the same answer as one handing it 192.0.2.10, and the row is told which form was placed.
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
                # The all-zeros and all-ones host parts are the subnet's own network and broadcast addresses, not a
                # host; a /31 and a /32 have neither (RFC 3021), so they are left alone.
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
    # Subnet is the address/prefix the target fell in, which the row uses to ask whether the route table really
    # selected that adapter for the probes (PR #51, round 3); empty where nothing placed it.
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

    # The route lookup a row takes after its probes (backlog #59), in one place because two callers need it now:
    # the row written straight after the first pass, and the row written later in the run for a target whose
    # sample was continued (backlog #51). Both take it after the last probe, which is what "after" has to mean.
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
        # Each further address its replies came from is looked up too, because the point of this row is which
        # adapter carried the measurement and two addresses can answer through two of them.
        foreach ($extra in @($lookupAddresses | Select-Object -Skip 1)) {
            $routeOthers += [pscustomobject][ordered]@{ Address = ConvertTo-SafeString $extra; Selection = (Get-RouteSelection -Target ([string]$extra)) }
        }
    }
    return [pscustomobject][ordered]@{ Selection = $routeAfter; LookupAddress = $lookupAddress; Others = @($routeOthers) }
}

function Get-LatencySpreadText {
    param([object]$Measurement)

    # The spread of a ping row's round-trip times, as one sentence for its details (backlog #61's other half).
    # Variability with little loss is the air's signature - an 802.11 retry is absorbed as delay, so the replies arrive
    # but not evenly - and until 1.2.13 the row kept every reply's milliseconds and computed nothing over them but the
    # average and the two ends. The figure is the sample standard deviation of the replies that arrived: a description,
    # never a verdict, since no threshold for it has a stated basis. And it names the sample it was taken over, because
    # over the four replies a target starts with it describes four moments rather than the link. The minimum below is
    # where the figure's own uncertainty falls below a quarter of itself - the relative standard error of a sample
    # standard deviation is about 1 / sqrt(2 (n - 1)), which is 25 % at n = 9 - a chosen precision, recorded with its
    # arithmetic on the repository's threshold page (docs/thresholds.md); nothing is decided at it, one sentence changes.
    $minimum = 9
    $received = ConvertTo-IntSafe (Get-PropertyValue $Measurement "Received" 0) 0
    $spread = Get-PropertyValue $Measurement "SpreadMs" $null
    if ($received -lt 2 -or $null -eq $spread) { return "" }
    $text = "Spread: standard deviation {0} ms over the {1} replies that arrived (average {2} ms, from {3} to {4}). The round-trip times are whole milliseconds, so on a link that answers in a millisecond or two a spread of about 1 ms is the timer's resolution, not the link." -f $spread, $received, $Measurement.AverageMs, $Measurement.MinimumMs, $Measurement.MaximumMs
    if ($received -lt $minimum) {
        $text += (" {0} replies describe {0} moments rather than the link: it takes {1} replies for the figure's own uncertainty to fall below a quarter of itself, so read this one beside the same target's figure from a longer sample. It decides nothing." -f $received, $minimum)
    }
    else {
        $text += (" At {0} replies - {1} or more - the figure's own uncertainty is below a quarter of itself, so it describes this run's variability towards this target; it decides nothing, because no threshold for it has a stated basis." -f $received, $minimum)
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

    # One ping row. It is a function of its own because a target whose first pass was not conclusive has its row
    # written twice - once where it belongs in the report, from the first pass, and again when the sample has been
    # continued (backlog #51) - and a row written in two places would be two rows that drift apart.
    # -Row is that second time. The report renders rows in the order they were added, so a row added late would
    # sit below the DNS and connectivity sections instead of with the other ping rows; what moves is therefore
    # what the row says, never where it is.
    $warningLoss = ConvertTo-DoubleSafe $script:Config.Thresholds.PacketLossWarningPercent 5
    $criticalLoss = ConvertTo-DoubleSafe $script:Config.Thresholds.PacketLossCriticalPercent 20
    $warningLatency = ConvertTo-DoubleSafe $script:Config.Thresholds.LatencyWarningMs 100
    $criticalLatency = ConvertTo-DoubleSafe $script:Config.Thresholds.LatencyCriticalMs 250

    # The tag is derived here rather than handed in, and the two lines below are deliberately a copy of the
    # ones in Test-PingTargets (backlog #33's document-fact step): it reads every -Tag argument off the AST and
    # resolves a variable only where every assignment to it is a literal, so a tag reaching Add-CheckResult
    # through a parameter, a property or a helper's return value would be a live tag outside every check that
    # holds the documents to the program. A copied two-line rule is the price of that step being able to see
    # this one.
    # Whether this row may claim its rung at all (PR #51, rounds 3 and 4). Subnet membership says where a host is,
    # not which interface the probes left by: they are sent unbound, and a VPN, a second connection or a more specific
    # route can carry a probe to an on-subnet address - or to a gateway's address - somewhere else entirely. A row
    # therefore claims its rung only where the route table selected, both before and after the probes, a source
    # address on one of the subnets the rung belongs to: the near-end host's own, or the subnets of the adapters that
    # supplied this gateway - the connected route, which is the adapter attached to that subnet. Where it did not, or
    # the selection changed, or the lookup was unavailable, the row keeps its title and its measurement and says why
    # it cannot claim the rung; a near-end row is then tagged as an ordinary ping target, so that the summary never
    # reads it as a witness for a path it may not have crossed, while a gateway row keeps its tag, because the gateway
    # is still the target it measured. Path - the adapter the rung was claimed on - is what the summary pairs a near-end
    # row with a failed gateway row by; round 6 moved it from "the lookups agreed" to "the rung was claimed", because
    # a selection that agreed can still run through a router. The tag assignment stays a literal for backlog #33's
    # document-fact step.
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
    # Path is the adapter whose local path this row is attested to have crossed (PR #51, round 6): set only where the
    # rung was claimed, so that the one field the summary pairs by means what the inference needs. A gateway row whose
    # lookups agreed but ran through a router, and a far-end row, which claims no rung, carry none.
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
    # Which measurement the status follows from (backlog #67): "loss" where the loss band decided it - a row nothing
    # answered included - "latency" where the replies that did arrive did, and empty where nothing did. The fingerprint
    # reads it, because a gateway that answered every probe slowly is not a gateway that did not answer.
    $rule = ""
    $loss = Get-PingLossClassification -Sent $Measurement.Sent -Lost $Measurement.Lost -WarningPercent $warningLoss -CriticalPercent $criticalLoss

    if ($Measurement.Received -eq 0) {
        $rule = "loss"
        # An optional ICMP target may intentionally block Ping. Nothing replying at all used to keep its verdict
        # however small the sample was, on the ground that 100 % loss is conclusive at four probes and no larger
        # count makes it more so - which is an argument about four and was applied to one (PR #49, round 5).
        # PingCount 1 is a value the configuration check and the IT panel both permit, and there "100 % loss" and
        # "one lost packet" are the same event: a required target was failed on a single timeout. The rule this
        # release already has settles it without inventing a number, because it asks the right question - the
        # verdict is withheld where the sample is too coarse for the threshold AND the classification would be a
        # different one had one fewer reply been lost. At four probes it would not (three of four is still
        # critical) and at one it would. Nothing more is sent either way: the expensive case stays the cheap one.
        # The sentence belongs to the case and not to the verdict (PR #49, round 6): an optional target that
        # answered nothing may simply be blocking ICMP whether or not its verdict was withheld, and round 5 had
        # tied the two together, so a one-probe optional target lost the guidance it most needs.
        $blockedIcmpNote = (-not $Required)
        if ($loss.Weightless) {
            $status = "INFO"
            $weightless = $true
            $coarseNote = ("Nothing replied to {0} echo request(s), and the classification would have been a different one had a single one of them come back, so this row is that one packet. " -f $Measurement.Sent)
        }
        else {
            $status = if ($Required) { "FAIL" } else { "INFO" }
        }
    }
    else {
        $lossStatus = "PASS"
        if ($loss.Weightless) {
            # backlog #51: a band was reached, and it was reached by one packet, on a sample too coarse for the
            # threshold applied to it. The row keeps every number it measured and stops deciding the run - this
            # item removes a verdict, never a number.
            $lossStatus = "WARN"
            $weightless = $true
            # A warning percentage of zero or less is one no count escapes, so there is no count to name and
            # printing 0 would be advice that does not work. The configuration check permits the value, so this
            # branch says the true thing instead of a number.
            if ($loss.RequiredCount -le 0) {
                $coarseNote = ("The sample is too small for this threshold: one lost reply out of {0} is {1}%, and the classification changes on that one reply. The warning threshold is {2}%, which no number of replies puts a single lost one below. " -f $Measurement.Sent, ([math]::Round((100.0 / $Measurement.Sent), 1)), $warningLoss)
            }
            else {
                $coarseNote = ("The sample is too small for this threshold: one lost reply out of {0} is {1}%, and the classification changes on that one reply. It takes {2} replies for one lost reply to stay below the {3}% warning threshold. " -f $Measurement.Sent, ([math]::Round((100.0 / $Measurement.Sent), 1)), $loss.RequiredCount, $warningLoss)
            }
        }
        elseif ($loss.Band -eq "critical") { $lossStatus = if ($Required) { "FAIL" } else { "WARN" } }
        elseif ($loss.Band -eq "warning") { $lossStatus = "WARN" }

        $latencyStatus = "PASS"
        if ($null -ne $Measurement.AverageMs -and $Measurement.AverageMs -ge $criticalLatency) { $latencyStatus = if ($Required) { "FAIL" } else { "WARN" } }
        elseif ($null -ne $Measurement.AverageMs -and $Measurement.AverageMs -ge $warningLatency) { $latencyStatus = "WARN" }

        # Loss is read first and latency second, which is the order this tool has always used. What is new is that
        # a loss figure whose verdict was withheld hands the row on to the latency rules instead of keeping it:
        # the two are different measurements over the same probes, and only the loss half is the one #51 found too
        # coarse. A latency threshold reached on the replies that did arrive is a measurement, and a row that
        # reached one keeps its weight.
        $status = $lossStatus
        if ($lossStatus -ne "PASS") { $rule = "loss" }
        if ($latencyStatus -ne "PASS" -and ($weightless -or $lossStatus -eq "PASS")) {
            $status = $latencyStatus
            $weightless = $false
            $rule = "latency"
        }
    }

    # The sentence above is about the classification alone; what follows from it is only known once this row's
    # status is (PR #49, round 2). One lost reply of four at an average of 300 ms on a required target has its loss
    # verdict withheld and its row decided by latency - and that row DOES change the overall result, so a fixed
    # "this row does not change the overall result" would be false exactly there. It sits outside the branch above
    # because the silent case can be withheld too since round 5.
    if ($coarseNote -ne "") {
        if ($weightless) { $coarseNote += "The figures above are what was measured, and this row does not change the overall result." }
        else { $coarseNote += "The figures above are what was measured; what decides this row is its latency, which is a measurement over the replies that did arrive." }
    }

    $latencyText = "No successful replies"
    if ($null -ne $Measurement.AverageMs) {
        $latencyText = ("average {0} ms (minimum {1}, maximum {2})" -f $Measurement.AverageMs, $Measurement.MinimumMs, $Measurement.MaximumMs)
    }

    $message = "Target {0}: {1}% loss ({2}/{3} successful), {4}." -f $Target, $Measurement.LossPercent, $Measurement.Received, $Measurement.Sent, $latencyText
    $detailLines = @()
    $detailLines += @($Measurement.AttemptDetails)
    # backlog #61's other half: the spread of the round-trip times, in one sentence that names the sample it was taken
    # over and decides nothing - Get-LatencySpreadText says why; a row with fewer than two replies has no line.
    $spreadLine = Get-LatencySpreadText -Measurement $Measurement
    if (-not [string]::IsNullOrWhiteSpace($spreadLine)) { $detailLines += $spreadLine }
    $detailLines += (Format-RouteSelection -Before $RouteBefore -After $RouteAfter.Selection -LookupAddress $RouteAfter.LookupAddress -Others $RouteAfter.Others)
    # backlog #60: the rung this row is, said as which segments its probes crossed and which they did not. Two rows
    # say it - the near-end host, which is what makes the ping rows a ladder at all, and the gateway, whose probes are
    # answered by a control plane rather than by a host - and the near-end row carries the reading rule, because that
    # is the row a reader looks at when they are about to subtract one rung from another. A far-end target's row does
    # not claim a rung: where an extra target sits relative to the gateway is not something this row has measured.
    if ($NearEnd -and $rungAttested) {
        $detailLines += ("Rung: near end - {0} is on a subnet this computer is attached to and is not the gateway, so these probes crossed the local path only - this computer's adapter, its cable or Wi-Fi link, and the switch or access point - and were answered by an ordinary host rather than by the gateway's control plane; they did not cross the gateway or anything beyond it. The route table selected source {1} via {2} - an address on that subnet, on-link with no next hop - before and after the probes, which is what lets this row claim the local path; the probes themselves are sent unbound. Read the ping rows as a ladder: a rung that passes clears what it crossed, at that moment; the first rung that fails puts the problem beyond the last rung that passed, and no closer than that - the figures of two rungs are separate traffic sent at separate moments, so they cannot be subtracted into a loss figure for the segment between them." -f $Target, $RouteBefore.SourceAddress, $RouteBefore.InterfaceAlias)
    }
    elseif ($NearEnd) {
        $detailLines += ("Rung: near end - not claimed. {0} is on a subnet this computer is attached to, but the probes are sent unbound, and the route selection above is not one on-link address on that subnet chosen both before and after the probes - a VPN, a second connection or a more specific route through a router may have carried them, or the lookup was unavailable - so this row cannot say which segments they crossed. It is counted as an ordinary ping target, not as the near-end rung, and the summary does not read it as a witness for the local path." -f $Target)
    }
    elseif ($pingTag -eq "ping-gateway" -and $rungAttested) {
        $detailLines += ("Rung: gateway - these probes crossed the local path - this computer's adapter, its cable or Wi-Fi link, and the switch or access point - and were answered by the gateway's own control plane; they did not cross anything beyond the gateway. The route table selected source {0} via {1} - an address on the subnet of the adapter that supplied this gateway, on-link with no next hop - before and after the probes; the probes themselves are sent unbound." -f $RouteBefore.SourceAddress, $RouteBefore.InterfaceAlias)
    }
    elseif ($pingTag -eq "ping-gateway") {
        $detailLines += "Rung: gateway - not claimed. The probes are sent unbound, and the route selection above is not one on-link address on the subnet of the adapter that supplied this gateway, chosen both before and after the probes - a VPN, a second connection or a more specific route through a router may have carried them, or the lookup was unavailable - so this row cannot say which segments they crossed. The gateway is still the target this row measured, and the summary reads its result as it always has."
    }
    if (-not [string]::IsNullOrWhiteSpace($SampleNote)) { $detailLines += $SampleNote }
    if (-not [string]::IsNullOrWhiteSpace($coarseNote)) { $detailLines += $coarseNote }
    # The method line counts the probes that were actually sent rather than the number configured: PingCount is a
    # starting count since 1.2.10, so the two are different numbers whenever a sample was continued, and the
    # manual check beside it has to be the command that reproduces what this row reports.
    $detailLines += ("Method: .NET Ping — {0} ICMP echo requests, timeout {1} ms{2}." -f $Measurement.Sent, $TimeoutMs, (Get-RouteMethodText -Target $Target -LookupAddress $RouteAfter.LookupAddress -TargetIsAddress $TargetIsAddress -ExtraCount (@($RouteAfter.Others).Count)))
    $detailLines += ("Manual check: ping -n {0} {1}" -f $Measurement.Sent, $Target)
    $details = (@($detailLines) -join [Environment]::NewLine)
    # backlog #58: the one required ping target is answered by the gateway's own stack, and network devices commonly
    # rate-limit or deprioritise ICMP addressed to themselves - so a gateway that answers promptly is good evidence that
    # the near-end path works, while one that does not answer is not proof that it is broken. The check stays Required
    # (decided 2026-09-10: a machine that cannot reach its own gateway usually does have a problem worth reporting), and
    # the failed row says what its failure does and does not establish, in the words of the field manual's
    # gateway-unreachable entry so that the two cannot drift apart. Only the FAIL row carries it: a row that passed has
    # nothing to qualify, and a row whose verdict was withheld already says why.
    if ($pingTag -eq "ping-gateway" -and $status -eq "FAIL") {
        # Two ways a required gateway row fails, and the sentence names the one that happened (PR #50, round 2):
        # replies that did not come back, or replies that came back at or above the critical latency with the loss
        # verdict passing or withheld. Both are answered from the device's control plane, so both are ambiguous in
        # the same way; what differs is the fact the row can state, and a row that lost nothing must not say it did.
        if ($latencyStatus -eq "FAIL" -and $lossStatus -ne "FAIL") {
            $gatewayFact = ("the gateway's own address answered {1} of the {2} echo requests sent to it, and slowly - an average of {0} ms, at or above the critical latency threshold. That is reason to check the local path first - link, Wi-Fi, switch - but it is not proof that the gateway forwards slowly, because a device answers pings sent to itself from its control plane, at a lower priority than the traffic it forwards." -f $Measurement.AverageMs, $Measurement.Received, $Measurement.Sent)
        }
        else {
            $gatewayFact = ("the gateway did not answer {0} of the {1} echo requests addressed to its own address. That is reason to check the local path first - link, Wi-Fi, switch - but it is not proof that the gateway is broken, because a gateway that forwards traffic can still drop or rate-limit pings sent to itself." -f $Measurement.Lost, $Measurement.Sent)
        }
        $details += [Environment]::NewLine + "What this failure does and does not establish: " + $gatewayFact + " What would show that it forwards is a passing target beyond it whose route runs through this gateway - not any passing row, since a same-subnet host, a VPN or a proxy can succeed without touching it. Read this row as a suspect, not a conviction."
    }
    # Only where the row really is an optional target that answered nothing. Until round 5 this read the status,
    # which was the same thing - and is not, now that a withheld silent verdict is INFO as well.
    if ($blockedIcmpNote) {
        $details += [Environment]::NewLine + "Informational: this optional target may simply block ICMP - see the Connectivity group for the authoritative internet verdict."
    }
    if ($null -eq $Row) {
        return (Add-CheckResult -Category "Latency and Packet Loss" -Check ("{0}: {1}" -f $Name, $Target) -Status $status -Message $message -Details $details -Tag $pingTag -Weightless:$weightless -Rule $rule -Path $path)
    }
    $Row.Status = $status
    $Row.Message = $message
    $Row.Details = $details
    $Row.Weightless = $weightless
    $Row.Rule = $rule
    $Row.Path = $path
    # The tag can move with the second pass: a near-end row whose route selection after the last probe no longer
    # matches the one before them stops claiming the rung, and the summary must see that (PR #51, round 3).
    $Row.Tag = $pingTag
    # The log is a narrative of the run, so the second reading gets a line of its own rather than quietly replacing
    # the first: a person watching the window saw the provisional figures and is owed the ones that replaced them.
    Write-UiLog -Status $status -Text ("{0} / {1}: {2}" -f $Row.Category, $Row.Check, $message)
    return $Row
}

function Complete-PingSamples {
    param(
        [datetime]$SampleStart,
        [int]$MinimumSeconds
    )

    # The second half of an adaptive ping sample (backlog #51). These probes are sent here, late in the run,
    # rather than back to back where the first pass ended, because the retransmission window already spans the
    # whole run: Wait-ForMinimumTcpSample is about to sleep out whatever is left of it, and probes spread across
    # those seconds measure a span of the network for wall-clock time the run was going to spend anyway. The
    # budget is shared between the targets still waiting, and where it is gone the probes go back to back and the
    # run is longer by what they cost - which is the honest price of a target that lost replies.
    $pending = @($script:PendingPingSamples)
    $script:PendingPingSamples = New-Object System.Collections.ArrayList
    if ($pending.Count -eq 0) { return }

    $timeout = [math]::Max(250, (ConvertTo-IntSafe $script:Config.Tests.PingTimeoutMs 1200))
    $index = 0
    foreach ($item in $pending) {
        $index++
        # The list was emptied before this loop and the row is already in the report, so nothing outside this
        # try would ever come back to this target: an exception here has to leave its row saying what happened,
        # the way every other check's failure does.
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
                # The extension is the part that can be given up: what the first pass measured is still a
                # measurement, and a row written from it is the row this tool wrote before adaptive sampling
                # existed. Only the note changes.
                $note = ("The sample could not be continued, so these figures are the first {0} echo requests alone. {1}" -f $item.Measurement.Sent, (Get-ExceptionDetails $_))
            }
            if ($measurement.Sent -gt $item.Measurement.Sent) {
                $note = ("Adaptive sample: the first {0} echo requests lost {1} of their replies, so {2} more were sent, spread across the rest of the run instead of back to back. Every figure above is over all {3}, and the time on this row is the end of the first pass, with the later probes falling after it." -f $item.Measurement.Sent, $item.Measurement.Lost, ($measurement.Sent - $item.Measurement.Sent), $measurement.Sent)
                if ($item.Plan.TargetCount -lt $item.Plan.RequiredCount) {
                    $note += (" The configured ceiling stopped it at {0}, below the {1} it would take for one lost reply to stay under the warning threshold." -f $item.Plan.TargetCount, $item.Plan.RequiredCount)
                }
            }
            # The route table is asked again, because "after the probes" has to mean after the last of them.
            $routeAfter = Get-PingRouteAfter -Target $item.Target -TargetIsAddress $item.TargetIsAddress -Measurement $measurement
            Add-PingTargetResult -Name $item.Name -Target $item.Target -ConfiguredAddress $item.Address -Required $item.Required -Measurement $measurement -RouteBefore $item.RouteBefore -RouteAfter $routeAfter -TargetIsAddress $item.TargetIsAddress -TimeoutMs $timeout -SampleNote $note -Row $item.Row -NearEnd $item.NearEnd -RungSubnets $item.RungSubnets | Out-Null
        }
        catch {
            # The row is already in the report with what the first pass measured, so what is lost here is the
            # extension and nothing else; what is added is why it did not happen.
            $item.Row.Details = ([string]$item.Row.Details + [Environment]::NewLine + ("The sample could not be continued. {0}" -f (Get-ExceptionDetails $_)))
            Write-UiLog -Status "INFO" -Text ("{0} / {1}: the sample could not be continued." -f $item.Row.Category, $item.Row.Check)
        }
    }
}

function Test-PingTargets {
    param([object[]]$PrimaryAdapters)

    $count = [math]::Max(1, (ConvertTo-IntSafe $script:Config.Tests.PingCount 4))
    # backlog #51: the furthest an adaptive sample may go. It is never below the starting count, so a
    # configuration that has the pair the wrong way round still sends what it asked for.
    $maximum = [math]::Max($count, (ConvertTo-IntSafe $script:Config.Tests.PingCountMaximum 21))
    $timeout = [math]::Max(250, (ConvertTo-IntSafe $script:Config.Tests.PingTimeoutMs 1200))
    $warningLoss = ConvertTo-DoubleSafe $script:Config.Thresholds.PacketLossWarningPercent 5

    # The ladder, in order (backlog #60): the near-end host first where one is configured, then the targets of the
    # list - the gateway, then whatever lies beyond it. The near-end entry is built here rather than read from the
    # list, so that a configuration file cannot promote a list entry to the near-end rung, and so that the traceroute
    # - which traces toward the first literal ping target - never picks the near-end host on the strength of this key.
    $entries = @()
    $nearEnd = Get-PropertyValue $script:Config.Tests "NearEndTarget" $null
    $nearEndAddress = ""
    if ($null -ne $nearEnd) { $nearEndAddress = (ConvertTo-SafeString (Get-PropertyValue $nearEnd "Address" "")).Trim() }
    # A blank address is the shipped, disabled state - unless the entry is marked required, in which case it is a
    # required check that cannot run, and dropping it would let the run pass a check it never made (PR #51, round 3).
    if (-not [string]::IsNullOrWhiteSpace($nearEndAddress) -or ($null -ne $nearEnd -and [bool](Get-PropertyValue $nearEnd "Required" $false))) {
        $entries += [pscustomobject][ordered]@{ Target = $nearEnd; NearEnd = $true }
    }
    foreach ($targetConfig in @($script:Config.Tests.PingTargets)) {
        if ($null -ne $targetConfig) { $entries += [pscustomobject][ordered]@{ Target = $targetConfig; NearEnd = $false } }
    }

    foreach ($entry in $entries) {
        $targetConfig = $entry.Target
        $isNearEnd = [bool]$entry.NearEnd

        $name = ConvertTo-SafeString (Get-PropertyValue $targetConfig "Name" $(if ($isNearEnd) { "Near-end host" } else { "Ping" }))
        $address = (ConvertTo-SafeString (Get-PropertyValue $targetConfig "Address" "")).Trim()
        $pingTag = "ping-target"
        if ($address -eq "AUTO_GATEWAY") { $pingTag = "ping-gateway" }
        if ($isNearEnd) { $pingTag = "ping-near-end" }
        $required = [bool](Get-PropertyValue $targetConfig "Required" $false)
        # Decided before anything is sent (backlog #39): a value that cannot become a ping target is a fact about this
        # run's input, and attempting it anyway would turn a typo into a measurement - 'http://example.com' resolves
        # to nothing and reports 100% loss, which reads as a network that dropped every packet. What remains below,
        # where a well-formed address resolved to nothing, is a measurement and keeps its weight.
        # The near-end target has the narrower rule the configuration check applies: an IPv4 address in dotted-decimal
        # form, never a name, a placeholder or another spelling, because the run has to place it before anything is
        # sent and the probe has to go to the address the file names (backlog #60; PR #51, round 2).
        if ($isNearEnd -and [string]::IsNullOrWhiteSpace($address)) {
            # Only a required entry reaches here with no address; an optional one was never added to the ladder.
            Add-CheckResult -Category "Latency and Packet Loss" -Check $name -Status "ERROR" -Message "The near-end target is marked as required, but no address is configured." -Details "Configured value: (blank). A required near-end target has to name a host on this computer's own subnet; with no address there is nothing to probe, and the run says so rather than passing a check it did not make." -Tag $pingTag -Weightless | Out-Null
            Add-CheckResult -Category "Latency and Packet Loss" -Check $name -Status "ERROR" -Message "This required check did not run, because no target was given." -Details "Configured value: (blank)" -Tag $pingTag | Out-Null
            continue
        }
        $usable = $(if ($isNearEnd) { Test-NearEndAddressSyntax $address } else { Test-PingTargetSyntax $address })
        if (-not $usable) {
            if ($isNearEnd) {
                Add-CheckResult -Category "Latency and Packet Loss" -Check $name -Status "ERROR" -Message "The configured near-end target cannot be used: it has to be an IPv4 address in dotted-decimal form." -Details ("Configured value: {0}. A near-end target is an IPv4 address on one of this computer's subnets that is not the gateway, given as four decimal numbers with dots - not as a single number, in hexadecimal or with leading zeros, which different parsers read as different addresses - and as an address rather than a name, because the check has to know it is on the local subnet before anything is sent and a name would put the near-end rung behind the resolver." -f $address) -Tag $pingTag -Weightless | Out-Null
            }
            else {
                Add-CheckResult -Category "Latency and Packet Loss" -Check $name -Status "ERROR" -Message "The configured address cannot be used as a ping target." -Details ("Configured value: $address; " + (Get-HostNameSyntaxProblem $address)) -Tag $pingTag -Weightless | Out-Null
            }
            if ($required) {
                Add-CheckResult -Category "Latency and Packet Loss" -Check $name -Status "ERROR" -Message "This required check did not run, because the target it was given cannot be tested." -Details ("Configured value: $address") -Tag $pingTag | Out-Null
            }
            continue
        }
        if ($isNearEnd) {
            # Placed before it is probed (backlog #60): the row's whole claim is which segments its probes crossed, so
            # a target that is the gateway, or that sits beyond it, must not be measured under that claim. The gateway
            # case is a configuration mistake and is reported as one; the off-subnet case is a fact about where this
            # machine is right now - a laptop at home with the office's configuration - and is reported as that:
            # nothing sent, nothing claimed, the overall result untouched. A required near-end target that was not
            # probed still costs the weighted row every required target costs when it did not run.
            $placement = Test-NearEndTargetPlacement -Address $address -PrimaryAdapters $PrimaryAdapters
            if ($placement.Placement -eq "gateway" -or $placement.Placement -eq "self" -or $placement.Placement -eq "not-a-host") {
                # Three configuration mistakes, one shape (PR #51, round 1 added the second and the third): the row
                # says which, and a probe that would have measured the wrong thing is not sent.
                if ($placement.Placement -eq "self") {
                    Add-CheckResult -Category "Latency and Packet Loss" -Check $name -Status "ERROR" -Message "The configured near-end target is one of this computer's own addresses, which cannot serve as the near-end rung." -Details ("Configured value: {0}. A ping to this computer's own address is answered by its own stack and crosses no cable, radio or switch; a near-end target has to be another host on the same subnet." -f $address) -Tag $pingTag -Weightless | Out-Null
                }
                elseif ($placement.Placement -eq "not-a-host") {
                    Add-CheckResult -Category "Latency and Packet Loss" -Check $name -Status "ERROR" -Message "The configured near-end target is the network or broadcast address of this computer's subnet, not a host." -Details ("Configured value: {0}. The all-zeros and all-ones addresses of a subnet belong to no host; a near-end target has to be a host on the same subnet." -f $address) -Tag $pingTag -Weightless | Out-Null
                }
                else {
                    Add-CheckResult -Category "Latency and Packet Loss" -Check $name -Status "ERROR" -Message "The configured near-end target is this computer's default gateway, which cannot serve as the near-end rung." -Details ("Configured value: {0}. The gateway answers pings from its own control plane and is already the next rung of the ladder; a near-end target has to be an ordinary host on the same subnet, so that the local path is measured without the gateway in it." -f $address) -Tag $pingTag -Weightless | Out-Null
                }
                if ($required) {
                    Add-CheckResult -Category "Latency and Packet Loss" -Check $name -Status "ERROR" -Message "This required check did not run, because the target it was given cannot be tested." -Details ("Configured value: $address") -Tag $pingTag | Out-Null
                }
                continue
            }
            if ($placement.Placement -ne "on-subnet") {
                $subnetText = "none known"
                if (@($placement.Subnets).Count -gt 0) { $subnetText = (@($placement.Subnets) -join ", ") }
                Add-CheckResult -Category "Latency and Packet Loss" -Check $name -Status "INFO" -Message "The configured near-end target is not on a subnet this computer is attached to, so it was not probed." -Details ("Configured value: {0}. This computer's IPv4 subnets: {1}. A host reached through the gateway is not a near-end rung, so nothing was sent; this row says nothing about the network and does not change the overall result." -f $address, $subnetText) -Tag $pingTag -Weightless | Out-Null
                if ($required) {
                    Add-CheckResult -Category "Latency and Packet Loss" -Check $name -Status "ERROR" -Message "This required check did not run, because the target it was given is not on this computer's network." -Details ("Configured value: {0}. This computer's IPv4 subnets: {1}." -f $address, $subnetText) -Tag $pingTag | Out-Null
                }
                continue
            }
        }
        $rungSubnets = @()
        if ($isNearEnd) { $rungSubnets = @([string]$placement.Subnet) }
        $targets = @(Resolve-PingTargets -Address $address -PrimaryAdapters $PrimaryAdapters)

        if ($targets.Count -eq 0) {
            $status = if ($required) { "FAIL" } else { "WARN" }
            $noTargetDetail = "Configured value: $address"
            if ($address -eq "AUTO_GATEWAY") {
                $noTargetDetail = "Configured value: AUTO_GATEWAY - this placeholder resolves to the current IPv4 default gateway, and none exists right now (usually the local link is down)."
            }
            Add-CheckResult -Category "Latency and Packet Loss" -Check $name -Status $status -Message "No testable target was found." -Details ($noTargetDetail + [Environment]::NewLine + ("Method: .NET Ping — {0} ICMP echo requests to begin with, up to {1} where replies are lost, timeout {2} ms." -f $count, $maximum, $timeout) + [Environment]::NewLine + "Manual check: ping -n $count <target-ip>") -Tag $pingTag | Out-Null
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
                    # Held back rather than finished here (backlog #51): the rest of this target's probes are sent
                    # late in the run, spread over seconds it already owes the retransmission window, so the extra
                    # samples span the run instead of arriving inside the same fraction of a second.
                    # The row is written here all the same, with what the first pass measured, and rewritten when
                    # the sample is finished. That keeps it among the other ping rows - and it means a run that
                    # never reaches the end still reports what it did measure, which a row held back until then
                    # would not.
                    $pendingNote = ("This sample was not conclusive: {0} of the first {1} replies were lost, so it is continued later in this run and these figures are the first {1} alone." -f $measurement.Lost, $measurement.Sent)
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
        throw (New-Object System.TimeoutException "DNS lookup timed out (more than $TimeoutMs ms).")
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
            $hostName = ([string]$dnsConfig).Trim()
            $required = $true
        }
        else {
            $name = ConvertTo-SafeString (Get-PropertyValue $dnsConfig "Name" "DNS Name Resolution")
            $hostName = (ConvertTo-SafeString (Get-PropertyValue $dnsConfig "Host" "")).Trim()
            $required = [bool](Get-PropertyValue $dnsConfig "Required" $true)
        }

        if ([string]::IsNullOrWhiteSpace($hostName)) {
        # The same cut as the TCP and HTTP targets (backlog #39): a blank host name is a fact about this run's input
        # and gets a row of its own where the result belonged - until 1.2.8 a blank DNS name produced nothing at all,
        # required or not, so the reader saw a section with no trace of a check somebody had configured. A required
        # target adds the weighted row that says the measurement did not happen.
            Add-CheckResult -Category "DNS" -Check $name -Status "ERROR" -Message "The configured host name is blank." -Details "" -Tag "dns" -Weightless | Out-Null
            if ($required) {
                Add-CheckResult -Category "DNS" -Check $name -Status "ERROR" -Message "This required check did not run, because the target it was given cannot be tested." -Details "" -Tag "dns" | Out-Null
            }
            continue
        }
        if (-not (Test-HostNameSyntax $hostName)) {
        # A name no resolver can be asked is the same fact about this run's input as a blank one, and until
        # this round it was the opposite: the lookup threw, the catch below turned the throw into a weighted
        # FAIL, and a typo became Problem Detected (PR #41, round 6).
            Add-CheckResult -Category "DNS" -Check $name -Status "ERROR" -Message "The configured host name cannot be used as a DNS target." -Details ("Configured value: $hostName; " + (Get-HostNameSyntaxProblem $hostName)) -Tag "dns" -Weightless | Out-Null
            if ($required) {
                Add-CheckResult -Category "DNS" -Check $name -Status "ERROR" -Message "This required check did not run, because the target it was given cannot be tested." -Details "" -Tag "dns" | Out-Null
            }
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
            throw (New-Object System.TimeoutException "TCP connection timed out (more than $TimeoutMs ms).")
        }
        $client.EndConnect($asyncResult)
        $stopwatch.Stop()

        # backlog #52: the two addresses the socket actually used, read before finally closes it. The remote one is
        # where the connections that follow this one go - to the address the first reached, never through the
        # resolver again - and the local one says which adapter's address the handshakes left from. Neither is a
        # measurement, so a read that fails leaves an empty string and the connection stays a success.
        $remoteAddress = ""
        $localAddress = ""
        try {
            if ($null -ne $client.Client.RemoteEndPoint) { $remoteAddress = [string]$client.Client.RemoteEndPoint.Address }
            if ($null -ne $client.Client.LocalEndPoint) { $localAddress = [string]$client.Client.LocalEndPoint.Address }
        }
        catch {}
        # backlog #52, PR #53 round 1: the socket's own account of its handshake, read before finally closes it.
        # SIO_TCP_INFO (0xD8000027, the Int32 below) fills a TCP_INFO_v0 - 88 bytes, SynRetrans the UCHAR at offset 84,
        # RttUs the ULONG at offset 20, the layout the mstcpip.h reference documents and this machine returned (read
        # 2026-09-12) - for the socket that asks, without elevation, on Windows 10 version 1703 and Windows Server
        # 2016 or later. A build that does not have it, or a socket that refuses, leaves -1 and the reason, and the
        # row falls back to reading the times against the retransmission timeout, saying so.
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
                $telemetryError = ("SIO_TCP_INFO returned {0} byte(s)" -f $infoBytes)
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
    # backlog #52: the timeout the connection times are read against is the operating system's own, not a threshold
    # of this tool. Set-NetTCPSetting documents InitialRtoMs as "the period, in milliseconds, before connect, or SYN,
    # retransmit" (300 to 3000 ms in steps of 10; read 2026-09-12), so a handshake that lasts at least that long is
    # one in which that timer expired. Asked of the Internet template, one of the two Windows ships. The reference
    # machine's Windows 11 build has no InitialRtoMs property on the object at all, while netsh int tcp show global
    # reports one global value, 1000 - the value Windows uses where none was set - so 1000 ms is assumed where the
    # cmdlet reports nothing, and the row says which of the two it got.
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

    # backlog #52: what the run measured for one target, counted here so that the text is a function of this object
    # and the unit tests hold both scripts to the counting. The first connection is the one the row's status rests
    # on; the repeats follow it in order and end at the first that failed, because the loop that made them stops
    # there - a target that stopped answering costs one more timeout and not PingCount of them.
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
    # The retransmission figure is the sockets' own where every connection that completed could be asked (PR #53,
    # round 1): SynRetrans per connection, summed. Where any could not - a build older than Windows 10 1703, a socket
    # that refused - the sample says so and the times are read against the timeout instead, as the proxy they are.
    $telemetryComplete = ($synCounts.Count -gt 0) -and (@($synCounts | Where-Object { $_ -lt 0 }).Count -eq 0)
    $retransmittedSyns = 0
    foreach ($synCount in $synCounts) { if ($synCount -gt 0) { $retransmittedSyns += $synCount } }
    # The proxy: a target given as a name has its first connection timed with the name lookup inside it - TcpClient
    # resolves the name before it sends the SYN - so that time is listed and not read against the timeout; the repeats
    # went to the address the first connection reached and are read. An address target's first connection is read
    # like the rest. With the sockets' own counts none of this matters, because a count is not a time.
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

    # backlog #52: the message carries the times and the retransmission figure - the sockets' own counts where they
    # could be read, otherwise how many of the connections read reached the timeout, named as the proxy it is - the
    # one figure a reader is owed at a glance; the rule, the timeout's provenance and the addresses are details.
    # Nothing here decides anything: the row's status was set by the first connection before this text existed.
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
    if ($telemetryError -eq "") { $telemetryError = "no error text" }

    $lead = ("{0} connection(s) timed: {1} ms" -f $timed, $timesText)
    if ($failedIndex -gt 0) {
        $lead = ("{0} connection(s) planned, {1} timed before connection {2} failed and the rest were left unattempted: {3} ms" -f $planned, $timed, $failedIndex, $timesText)
    }
    $message = ""
    if ($telemetry -and $retransmitted -eq 0) {
        $message = $lead + ("; SYN retransmissions {0}, counted by each socket." -f $synText)
    }
    elseif ($telemetry) {
        $message = $lead + ("; SYN retransmissions {0}, counted by each socket: {1} SYN(s) had to be sent again." -f $synText, $retransmitted)
    }
    elseif ($judged -eq 0) {
        $message = $lead + ("; the sockets' own retransmission counters could not be read, and a name target's first connection includes its name lookup, so nothing was read against the {0} retransmission timeout." -f $rtoText)
    }
    elseif ($reached -eq 0) {
        $message = $lead + ("; the sockets' own retransmission counters could not be read, so the times stand in: {0} of {1} took at least the {2} retransmission timeout - a proxy for a retransmitted SYN, not a count of one." -f $reached, $judged, $rtoText)
    }
    else {
        $message = $lead + ("; the sockets' own retransmission counters could not be read, so the times stand in: {0} of {1} took at least the {2} retransmission timeout, where a retransmitted SYN could appear - a proxy for a retransmitted SYN, not a count of one." -f $reached, $judged, $rtoText)
    }

    $lines = New-Object System.Collections.ArrayList
    $where = ("to {0}" -f $target)
    if ($Sample.HostIsName -and -not [string]::IsNullOrWhiteSpace([string]$Sample.RemoteAddress)) {
        $where = ("to {0}, which resolved to {1}" -f $target, $Sample.RemoteAddress)
    }
    $from = ""
    if (-not [string]::IsNullOrWhiteSpace([string]$Sample.LocalAddress)) {
        $from = (" from {0}" -f $Sample.LocalAddress)
    }
    $first = ("Connections: {0} of {1} planned, each a new TCP handshake {2}{3}; times in the order made: {4} ms." -f $attempted, $planned, $where, $from, $timesText)
    if ($Sample.HostIsName -and $telemetry) {
        if ($attempted -gt 1) { $first += (" The first connection resolved the name and its time includes that lookup; its SYN count is the socket's own and is read like the rest; the {0} that followed went to the address." -f ($attempted - 1)) }
        else { $first += " The first connection resolved the name and its time includes that lookup; its SYN count is the socket's own; no connection followed it." }
    }
    elseif ($Sample.HostIsName) {
        if ($attempted -gt 1) { $first += (" The first connection resolved the name and its time includes that lookup, so it is not read against the timeout; the {0} that followed went to the address." -f ($attempted - 1)) }
        else { $first += " The first connection resolved the name and its time includes that lookup, so it is not read against the timeout; no connection followed it." }
    }
    [void]$lines.Add($first)
    if ($failedIndex -gt 0) {
        [void]$lines.Add(("Connection {0} failed, and the ones after it were not attempted:" -f $failedIndex))
        [void]$lines.Add([string]$Sample.FailedError)
    }
    if ($telemetry) { [void]$lines.Add(("SYN retransmissions per connection: {0}; round-trip estimate per connection: {1} ms (TCP_INFO_v0 SynRetrans and RttUs, read from each socket through SIO_TCP_INFO once it had connected)." -f $synText, $rttText)) }
    else { [void]$lines.Add(("SYN retransmissions: not readable from the sockets on this computer ({0}) - SIO_TCP_INFO needs Windows 10 version 1703 or Windows Server 2016 - so the times are read against the initial retransmission timeout below instead." -f $telemetryError)) }
    $rtoLine = ("Initial retransmission timeout (RTO): {0} ms, " -f $rtoMs)
    if ([string]$Sample.RtoSource -eq "setting") { $rtoLine += "the Internet template's InitialRtoMs as Get-NetTCPSetting reports it." }
    else { $rtoLine += ("assumed: Get-NetTCPSetting reports no value on this computer, and {0} ms is the value Windows uses where none was set (netsh int tcp show global shows the value in force)." -f $rtoMs) }
    [void]$lines.Add($rtoLine)
    if ($telemetry) { [void]$lines.Add(("Reading: {0} SYN(s) sent again across {1} connection(s), counted by the sockets themselves. These are this tool's own connections, to this one target, at this moment - the figure the system-wide TCP Retransmissions rows cannot attribute - and they decide nothing: the status of this row is the first connection's. A connection that took at least the initial retransmission timeout is where a retransmitted SYN would show in the times; the socket's count says whether one did." -f $retransmitted, $timed)) }
    elseif ($judged -eq 0) { [void]$lines.Add("Reading: nothing was read - the sockets' counters were not available, and the only connection that completed carried the name lookup. These are this tool's own connections, to this one target, at this moment - the figure the system-wide TCP Retransmissions rows cannot attribute - and they decide nothing: the status of this row is the first connection's.") }
    else { [void]$lines.Add(("Reading: {0} of {1} at or above the timeout. A connection that takes at least the initial retransmission timeout is where a retransmitted SYN would show, but its time also holds whatever ran before the SYN and after the reply, so this is a proxy for a retransmission and not a count of one; and a connection below it rules a retransmission out only if the timeout read here is the one the connection used, which this tool cannot confirm - which template a connection gets cannot be read without administrator rights, and an assumed value is an assumption. These are this tool's own connections, to this one target, at this moment - the figure the system-wide TCP Retransmissions rows cannot attribute - and they decide nothing: the status of this row is the first connection's." -f $reached, $judged)) }

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
    # backlog #52: PingCount is also the number of TCP connections a target that answers gets - the one that decides
    # the row and PingCount - 1 more to the address it reached, timed one by one - so that the run holds one
    # retransmission figure it can attribute: its own SYNs, to one named target, at this moment. The system-wide
    # counters keep their rows and say what they are. The timeout the times are read against is read once, and only
    # after a connection has succeeded, so a run whose TCP targets all fail pays nothing for it.
    $connectCount = [math]::Max(1, (ConvertTo-IntSafe $script:Config.Tests.PingCount 4))
    $initialRto = $null

    foreach ($target in @($script:Config.Tests.TcpTargets)) {
        if ($null -eq $target) { continue }

        $name = ConvertTo-SafeString (Get-PropertyValue $target "Name" "TCP Connection")
        $hostName = (ConvertTo-SafeString (Get-PropertyValue $target "Host" "")).Trim()
        $port = ConvertTo-IntSafe (Get-PropertyValue $target "Port" 0) 0
        $required = [bool](Get-PropertyValue $target "Required" $false)
        $group = ConvertTo-SafeString (Get-PropertyValue $target "Group" "")

        if (-not (Test-HostNameSyntax $hostName) -or $port -lt 1 -or $port -gt 65535) {
            # Two rows, because one row would carry two claims (backlog #39): this was configured wrongly, which the
            # rule says cannot move the verdict, and - when the target is required - a measurement that had to happen
            # did not, which has to keep its weight. The notice names the value as it was given, in the section where
            # the result belonged, so an optional target that is never tested is visible instead of absent; the second
            # row is what stops a run reading Overall Healthy with a required check that never ran.
            Add-CheckResult -Category "TCP Connection" -Check $name -Status "ERROR" -Message "The configured host or port is invalid." -Details ("Host=$hostName, Port=$port" + $(if (-not (Test-HostNameSyntax $hostName)) { "; the host: " + (Get-HostNameSyntaxProblem $hostName) } else { "" })) -Tag "tcp" -Weightless | Out-Null
            if ($required) {
                Add-CheckResult -Category "TCP Connection" -Check $name -Status "ERROR" -Message "This required check did not run, because the target it was given cannot be tested." -Details ("Host=$hostName, Port=$port") -Tag "tcp" | Out-Null
            }
            continue
        }

        $result = Invoke-TcpConnectionTest -HostName $hostName -Port $port -TimeoutMs $tcpTimeout
        if ($result.Success) {
            # backlog #52: the connections that follow the one that decided the row. They go to the address the
            # first connection reached, so that a name is resolved once and the times are handshakes and nothing
            # else; and they stop at the first that fails, so that a target which stops answering costs one more
            # timeout and not PingCount of them.
            if ($null -eq $initialRto) { $initialRto = Get-TcpInitialRto }
            $repeatHost = $hostName
            if (-not [string]::IsNullOrWhiteSpace([string]$result.RemoteAddress)) { $repeatHost = [string]$result.RemoteAddress }
            $repeats = @()
            for ($i = 2; $i -le $connectCount; $i++) {
                $repeat = Invoke-TcpConnectionTest -HostName $repeatHost -Port $port -TimeoutMs $tcpTimeout
                $repeats += $repeat
                if (-not $repeat.Success) { break }
            }
            # Whether the first connection carried a name lookup is decided the way the framework decides it: TcpClient
            # hands the string to Dns, whose resolution helper parses it with IPAddress.TryParse first and queries nothing
            # for a value that parses (Dns.HostResolutionBeginHelper in the .NET Framework reference source, read
            # 2026-09-12), so the same test here says whether a resolver was ever asked.
            $parsedAddress = $null
            $hostIsName = -not [System.Net.IPAddress]::TryParse($hostName, [ref]$parsedAddress)
            $sample = New-TcpConnectSample -First $result -Repeats $repeats -Planned $connectCount -HostIsName $hostIsName -InitialRto $initialRto
            $sampleText = Get-TcpConnectSampleText -Sample $sample -HostName $hostName -Port $port
            $script:TcpConnectSampleCount++
            Add-CheckResult -Category "TCP Connection" -Check $name -Status "PASS" -Message (("Connected to {0}:{1} in {2} ms." -f $hostName, $port, $result.ElapsedMs) + " " + $sampleText.Message) -Details ((@($sampleText.Lines) + @($tcpMethod, "Manual check: Test-NetConnection $hostName -Port $port")) -join [Environment]::NewLine) -Tag "tcp" | Out-Null
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

        if (-not (Test-HttpTargetSyntax $url)) {
            # Blank was never the only way a URL cannot be used: 'example.com' has no scheme and 'ftp://host' has one
            # this tool does not speak. Both are decided here, before anything is sent, so that a value no packet
            # left for cannot be recorded as a measured connectivity failure (PR #41, round 1).
            $urlDetail = "Configured value: $url" + (Get-UrlHostProblemSuffix $url)
            Add-CheckResult -Category "HTTP/HTTPS" -Check $name -Status "ERROR" -Message "The configured URL cannot be used: it must be an absolute http:// or https:// address." -Details $urlDetail -Tag "http" -Weightless | Out-Null
            if ($required) {
                Add-CheckResult -Category "HTTP/HTTPS" -Check $name -Status "ERROR" -Message "This required check did not run, because the target it was given cannot be tested." -Details $urlDetail -Tag "http" | Out-Null
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
            Add-CheckResult -Category "Network Adapter Error Counters" -Check $name -Status $resetStatus -Message "The adapter counters were reset during the test, possibly because the adapter reconnected or restarted; a reliable delta cannot be calculated." -Details $resetDetails -Tag "adapter-errors" -Weightless | Out-Null
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

    # One reading of netsh wlan show interfaces, kept as a sample of which access point each wireless interface was
    # associated with at this moment of the run (backlog #61's other half): the BSSID is the access point's own address,
    # a change of it under the same network name is a roam, and a roam is the air-side event that explains a run with a
    # good signal and bad numbers. The envelope is returned whatever it holds, like the retry snapshot and the TCP
    # snapshot; the analysis writes the rows, with the evidence attached. -Moment says where in the run the sample was
    # taken - start, middle, end - so that the rows can say so.
    # Beside the netsh read, the WLAN service's own account of the interfaces (backlog #62): which ones exist and whether
    # each is connected, through the Native Wifi API, because netsh's text is not the state. Where desktop programs may
    # not use the location - Windows 11 24H2 and later, Settings > Privacy & security > Location - netsh prints no
    # interface at all and exits 1 (measured on the reference machine, 2026-09-12), and an output with no interface in
    # it read as a computer with no radio. The exit code and the lines are kept for the same reason: the text netsh
    # prints then is a sentence in the machine's language, which no parser should be asked to read.
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
        $sample.ErrorText = "netsh.exe was not found."
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

    # Takes one sample and keeps it with the run's others, in the order taken. The list is created here as well as at
    # the start of a run, so that a caller outside Run-AllChecks - the radio row in a test harness - never writes into
    # a list that does not exist.
    if ($null -eq $script:WifiAssociationSamples) { $script:WifiAssociationSamples = New-Object System.Collections.ArrayList }
    $sample = Get-WifiAssociationSample -Moment $Moment
    [void]$script:WifiAssociationSamples.Add($sample)
    return $sample
}

function Get-WifiInterfaceView {
    param([object]$Sample)

    # One entry per wireless interface either reader of a sample listed (backlog #62), keyed by the GUID both print, so
    # that the rows read one list: netsh's fields where netsh printed the interface; the WLAN service's state, channel
    # and radio switches where the service listed it; and Connected decided by the service where it answered - the
    # state is the service's to know, and what netsh prints for it is a translated word - or by netsh's own fields where
    # the service could not be asked, said which on every entry (ConnectedSource: wlanapi or netsh). An interface the
    # service lists and netsh does not is the case the item is about (NetshListed false): netsh printed nothing for it,
    # either because its whole output was refused - a non-zero exit code, and from the service error 5 on the
    # connection query, which is the location setting for desktop programs (Refused) - or for a reason the sample can
    # only report (NetshFailed: a non-zero exit code, the executable missing, the read that threw). A sample without
    # the service's reading - the older shape, and the test fixtures' - reads as netsh alone.
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

    # Why a sample holds no netsh interface, in one phrase for the rows that have to say it (backlog #62): the executable
    # missing, the read that threw, or - the measured case - netsh exiting with a code and printing no interface. Empty
    # where netsh ran and exited 0, which is the ordinary sample.
    if ($null -eq $Sample) { return "" }
    $error = [string](Get-PropertyValue $Sample "Error" "")
    $exitCode = ConvertTo-IntSafe (Get-PropertyValue $Sample "NetshExitCode" 0) 0
    if ($error -eq "netsh") { return "netsh.exe was not found" }
    if (-not [string]::IsNullOrWhiteSpace($error)) { return ("netsh wlan show interfaces could not be read ({0})" -f [string](Get-PropertyValue $Sample "ErrorText" "")) }
    if ($exitCode -ne 0) { return ("netsh wlan show interfaces exited with code {0} and printed no interface" -f $exitCode) }
    return ""
}

function Get-WifiRadioSwitchText {
    param([object]$View)

    # The radio switches as the WLAN service reports them, as a phrase for the rows, or nothing where they were not read:
    # a radio switched off is one of the causes the old message guessed at, and it can be stated where it is measured.
    if ($null -eq $View) { return "" }
    $software = [string](Get-PropertyValue $View "RadioSoftware" "")
    $hardware = [string](Get-PropertyValue $View "RadioHardware" "")
    $off = @()
    if ($software -eq "off") { $off += "in software" }
    if ($hardware -eq "off") { $off += "by a hardware switch" }
    if ($off.Count -gt 0) { return ("radio off ({0})" -f ($off -join " and ")) }
    # On only where both switches are known on (PR #55, round 9): one on beside one unknown names which is which, because
    # the unknown switch may still hold the radio off and a row that said on would claim more than was read.
    if ($software -eq "on" -and $hardware -eq "on") { return "radio on" }
    if ($software -eq "on") { return "radio on in software, the hardware switch unknown" }
    if ($hardware -eq "on") { return "radio on by the hardware switch, the software state unknown" }
    return ""
}

function Add-WifiRfResult {
    if (-not (Test-IsTrueFlag $script:Config.Checks.WifiRf)) { return }

    # The one read serves twice (backlog #61's other half): this row, and the middle sample of the access point that
    # Compare-WifiAssociation reads against the samples taken before the first measurement and after the last.
    # The row reads the sample through Get-WifiInterfaceView (backlog #62): the WLAN service says which interfaces exist
    # and whether each is connected, netsh supplies the fields, and an interface the service lists as connected while
    # netsh printed nothing for it is reported as connected with its fields marked not reported - never as no interface.
    $sample = Add-WifiAssociationSample -Moment "middle"
    $views = @(Get-WifiInterfaceView -Sample $sample)
    $api = Get-PropertyValue $sample "Api" $null
    $apiLine = ""
    # The line ends with this read's own outcome as a token (PR #55, round 5) - wlanapi=ok, or the reader's reason code -
    # because the chain's oracle judges a radio row without an interface GUID by the read that row was written from,
    # which the association rows' token, decided by another sample, cannot stand for.
    if ($null -eq $api) { $apiLine = "WLAN service: not read" }
    elseif (-not [string]::IsNullOrWhiteSpace([string]$api.Error)) { $apiLine = (("WLAN service: not read - {0} {1}" -f $api.Error, $api.ErrorText).Trim() + ("; wlanapi={0}" -f $api.Error)) }
    else { $apiLine = ("WLAN service: {0} wireless interface(s) listed; wlanapi=ok" -f @($api.Interfaces).Count) }
    $netshReason = Get-WifiNetshReasonText -Sample $sample
    if ([string]$sample.Error -eq "netsh" -and $views.Count -eq 0) {
        Add-CheckResult -Category "IT Diagnostics" -Check "Wi-Fi radio" -Status "INFO" -Message "netsh.exe was not found; Wi-Fi radio data is unavailable." -Details $apiLine -Tag "wifi" -Scope "IT" | Out-Null
        return
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$sample.Error) -and $views.Count -eq 0) {
        Add-CheckResult -Category "IT Diagnostics" -Check "Wi-Fi radio" -Status "ERROR" -Message "Wi-Fi radio data could not be read." -Details ((@([string]$sample.ErrorText, $apiLine) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join [Environment]::NewLine) -Diagnostics ([string]$sample.Diagnostics) -Tag "wifi" -Scope "IT" | Out-Null
        return
    }

    $netshCount = @($sample.Interfaces).Count
    $connected = @($views | Where-Object { $_.Connected })
    if ($connected.Count -eq 0) {
        # No interface connected, said from what was read rather than guessed at: each interface the WLAN service or
        # netsh listed with its state and its radio switches, and the counts. A wired computer, a radio switched off or a
        # machine without a wireless adapter are among the causes; the lines say which of them this run can see.
        $lines = @()
        foreach ($view in $views) {
            $name = $view.Name
            if ([string]::IsNullOrWhiteSpace($name)) { $name = $view.Description }
            $stateText = "not connected (netsh printed no association)"
            if ($null -ne $view.State) { $stateText = Get-WifiInterfaceStateText $view.State }
            $radio = Get-WifiRadioSwitchText -View $view
            $lines += ("{0}: {1}{2}" -f (ConvertTo-DisplayString $name), $stateText, $(if ($radio) { ", " + $radio } else { "" }))
        }
        if ($views.Count -eq 0) { $message = "No wireless interface is listed by netsh or by the WLAN service - a wired computer, for example; the details say what each reader returned." }
        else { $message = "No wireless interface is connected: {0} listed, none connected - {1}." -f $views.Count, ($lines -join "; ") }
        $details = @()
        $details += $lines
        $details += ("Wireless interfaces reported by netsh: {0}" -f $netshCount)
        $details += $apiLine
        if ($netshReason) { $details += ("netsh: " + $netshReason) }
        $details += "Method: the WLAN service (WlanEnumInterfaces) for the interfaces and their connection state, netsh wlan show interfaces for the fields."
        $details += "Manual check: netsh wlan show interfaces"
        Add-CheckResult -Category "IT Diagnostics" -Check "Wi-Fi radio" -Status "INFO" -Message $message -Details ($details -join [Environment]::NewLine) -Tag "wifi" -Scope "IT" | Out-Null
        return
    }

    foreach ($wifi in $connected) {
        $name = $wifi.Name
        if ([string]::IsNullOrWhiteSpace($name)) { $name = $wifi.Description }
        $stateSource = "the connection state from the WLAN service (WlanEnumInterfaces)"
        if ($wifi.ConnectedSource -ne "wlanapi") { $stateSource = "the connection state from the fields netsh printed, because the WLAN service could not be asked" }
        if (-not $wifi.NetshListed) {
            # Connected per the WLAN service, and netsh printed nothing for it (backlog #62): the row reports the connection
            # with the fields it cannot have, and names why. The measured cause is the location setting: netsh's whole
            # output refused, exit code 1, and the service answering the connection query with error 5 - the same query
            # netsh makes for the network name, the access point, the signal and the rates. Any other reason is said as
            # what the sample recorded, without a cause.
            $channelText = "channel not read"
            if ($null -ne $wifi.Channel) { $channelText = "channel {0}" -f $wifi.Channel }
            $queryText = "not asked"
            if ($wifi.ConnectionQuery -eq 0) { $queryText = "answered" }
            elseif ($wifi.ConnectionQuery -gt 0) { $queryText = Get-Win32ErrorText $wifi.ConnectionQuery }
            $consent = $null
            if ($null -ne $api) { $consent = Get-PropertyValue $api "LocationConsent" $null }
            $consentText = ""
            if ($null -ne $consent) { $consentText = [string](Get-PropertyValue $consent "Text" "") }
            if ($wifi.Refused) {
                $message = "{0}: connected (WLAN service), {1}; the network name, access point, signal and rates could not be read - {2}, and the WLAN service refused the connection query (error 5, access denied) while the location consent store shows Deny ({3}): on Windows 11 24H2 and later the connection's details need the location setting to allow desktop programs (Settings > Privacy & security > Location)." -f (ConvertTo-DisplayString $name), $channelText, $netshReason, $consentText
            }
            elseif ($wifi.AccessDenied) {
                # Error 5 alone is access denied and no more (PR #55, round 1): without the consent store's Deny on a build that
                # gates the details, the cause is not named - a policy that restricts WLAN queries would be sent to the wrong setting.
                $message = "{0}: connected (WLAN service), {1}; the network name, access point, signal and rates could not be read - {2}, and the WLAN service refused the connection query (error 5, access denied) while the location consent store shows no denial ({3}){4}; the cause was not identified - a policy restricting WLAN queries, for example." -f (ConvertTo-DisplayString $name), $channelText, $netshReason, $(if ($consentText) { $consentText } else { "not read" }), $(if ($null -ne $consent -and -not [bool](Get-PropertyValue $consent "Gated" $false)) { ", and this Windows predates the gating of Wi-Fi details behind that setting (24H2)" } else { "" })
            }
            else {
                $reason = $netshReason
                if ([string]::IsNullOrWhiteSpace($reason)) { $reason = "netsh wlan show interfaces did not list this interface" }
                $message = "{0}: connected (WLAN service), {1}; the network name, access point, signal and rates could not be read - {2} (connection query: {3})." -f (ConvertTo-DisplayString $name), $channelText, $reason, $queryText
            }
            $radio = Get-WifiRadioSwitchText -View $wifi
            $printed = @(Get-PropertyValue $sample "NetshLines" @())
            $netshLines = @()
            if ($printed.Count -gt 0) {
                $netshLines += "netsh printed:"
                foreach ($line in @($printed | Select-Object -First 12)) { $netshLines += ("  " + $line) }
                if ($printed.Count -gt 12) { $netshLines += ("  ... {0} more line(s)" -f ($printed.Count - 12)) }
            }
            $details = @()
            $details += ("Interface (WLAN service): {0}" -f (ConvertTo-DisplayString $wifi.Description))
            $details += ("Interface GUID: {0}" -f $wifi.Guid)
            $details += ("Connection state: {0} (WLAN service); netsh exit code {1}; connection query: {2}{3}" -f (Get-WifiInterfaceStateText $wifi.State), (ConvertTo-IntSafe (Get-PropertyValue $sample "NetshExitCode" 0) 0), $queryText, $(if ($consentText) { "; location consent: " + $consentText } else { "" }))
            $details += ("Channel: {0}{1}" -f $(if ($null -ne $wifi.Channel) { [string]$wifi.Channel } else { "not read" }), $(if ($radio) { "; " + $radio } else { "" }))
            $details += "Not reported: SSID, BSSID, band, radio type, signal, receive and transmit rates, profile"
            $details += $netshLines
            $details += "Method: the WLAN service (WlanEnumInterfaces) for the interface and its connection state, the return code of its connection query (WlanQueryInterface, current connection) for why the fields are missing, netsh wlan show interfaces for the fields it printed."
            # The manual check follows the witness (PR #55, round 2): the location setting only where the denial was witnessed,
            # a WLAN-query check for an error 5 without it, the plain read for anything else.
            if ($wifi.Refused) { $details += "Manual check: netsh wlan show interfaces (it names the setting to open); start ms-settings:privacy-location (Settings > Privacy & security > Location)" }
            elseif ($wifi.AccessDenied) { $details += "Manual check: netsh wlan show interfaces, and read the message it prints; the WLAN service refused the connection query (error 5) - a policy that restricts WLAN queries would do that" }
            else { $details += "Manual check: netsh wlan show interfaces, and read the message it prints" }
            $details += "Note: the client-side view is weaker evidence than the access point's client table."
            Add-CheckResult -Category "IT Diagnostics" -Check "Wi-Fi radio" -Status "INFO" -Message $message -Details ($details -join [Environment]::NewLine) -Tag "wifi" -Scope "IT" | Out-Null
            continue
        }
        $rssi = "?"
        if ($null -ne $wifi.SignalPercent) { $rssi = [math]::Round(($wifi.SignalPercent / 2.0) - 100, 0) }
        if ($null -ne $wifi.Rssi) { $rssi = $wifi.Rssi }
        $message = "SSID {0}: signal {1}% (about {2} dBm), {3} {4}, channel {5}, {6}/{7} Mbps." -f $wifi.Ssid, (ConvertTo-DisplayString $wifi.SignalPercent), $rssi, $wifi.RadioType, $wifi.Band, (ConvertTo-DisplayString $wifi.Channel), (ConvertTo-DisplayString $wifi.ReceiveRateMbps), (ConvertTo-DisplayString $wifi.TransmitRateMbps)
        $details = (@(
            ("Interface: {0}" -f $wifi.Name),
            $(if (-not [string]::IsNullOrWhiteSpace([string]$wifi.Guid)) { "Interface GUID: {0}" -f $wifi.Guid } else { $null }),
            ("Connection state: {0}" -f $(if ($wifi.ConnectedSource -eq "wlanapi") { "{0} (WLAN service)" -f (Get-WifiInterfaceStateText $wifi.State) } else { "connected (netsh printed an association; the WLAN service could not be asked)" })),
            ("BSSID: {0}" -f (ConvertTo-DisplayString $wifi.Bssid)),
            ("Radio: {0}, band {1}, channel {2}" -f $wifi.RadioType, (ConvertTo-DisplayString $wifi.Band), (ConvertTo-DisplayString $wifi.Channel)),
            ("Rates: receive {0} Mbps, transmit {1} Mbps" -f (ConvertTo-DisplayString $wifi.ReceiveRateMbps), (ConvertTo-DisplayString $wifi.TransmitRateMbps)),
            ("Signal: {0}% (about {1} dBm)" -f (ConvertTo-DisplayString $wifi.SignalPercent), $rssi),
            ("Profile: {0}" -f (ConvertTo-DisplayString $wifi.Profile)),
            ("Method: netsh wlan show interfaces, parsed by field position because labels are localized; {0}; dBm is estimated from the signal percentage." -f $stateSource),
            "Manual check: netsh wlan show interfaces",
            "Note: the client-side view is weaker evidence than the access point's client table."
        ) | Where-Object { $null -ne $_ }) -join [Environment]::NewLine
        Add-CheckResult -Category "IT Diagnostics" -Check "Wi-Fi radio" -Status "INFO" -Message $message -Details $details -Tag "wifi" -Scope "IT" | Out-Null
    }
}

function Test-WifiSampleReadable {
    param([object]$Sample)

    # A sample is readable where either reader answered (PR #55, round 6): netsh's read may have failed outright - the
    # executable missing, the read that threw - while the WLAN service still listed the interfaces and their state, and a
    # sample skipped on netsh's failure alone would have dropped an interface the service saw. Only a sample both readers
    # failed is unreadable, and only a run of those is the aggregate failure row.
    if ($null -eq $Sample) { return $false }
    # netsh answered only where it ran and exited 0 (PR #55, round 10): a non-zero exit with nothing listed is a failed read as
    # much as a thrown one, and beside a failed service reading it makes the aggregate row, not the wired computer's.
    if ([string]::IsNullOrWhiteSpace([string](Get-PropertyValue $Sample "Error" "")) -and (ConvertTo-IntSafe (Get-PropertyValue $Sample "NetshExitCode" 0) 0) -eq 0) { return $true }
    $api = Get-PropertyValue $Sample "Api" $null
    return ($null -ne $api -and [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $api "Error" "")))
}

function Get-WifiApiSummaryText {
    param([object]$Sample)

    # The WLAN service's reading of a sample in one clause, for the lines that report a sample beside what netsh printed
    # (backlog #62): how many interfaces it listed, or why it could not be read; nothing for a sample taken without it.
    if ($null -eq $Sample) { return "" }
    $api = Get-PropertyValue $Sample "Api" $null
    if ($null -eq $api) { return "" }
    $error = [string](Get-PropertyValue $api "Error" "")
    if (-not [string]::IsNullOrWhiteSpace($error)) { return ("WLAN service: not read - {0} {1}" -f $error, [string](Get-PropertyValue $api "ErrorText" "")).Trim() }
    return ("WLAN service: {0} wireless interface(s) listed" -f @(Get-PropertyValue $api "Interfaces" @()).Count)
}

function Compare-WifiAssociation {
    param([object[]]$Samples)

    # The access-point samples read against each other (backlog #61's other half): one row per wireless interface that
    # any sample listed, saying whether the interface stayed on one access point across the run, moved to another, or
    # reported none - and, whatever it says, that a change between two samples which returned to the same access point
    # cannot be seen, because the BSSID is sampled and not watched. That limit is stated on every row rather than
    # implied by a silence: two equal samples do not exclude a roam that came back. Windows' WLAN event log was measured
    # as the alternative and not read - it is readable without elevation, but none of its events carries the BSSID, and
    # the security re-association it does record is written for a key rotation as well as for a roam, so it could not
    # have said more than the samples do. An IT-scope row, like the radio row it extends: evidence, not a verdict.
    # The interfaces come from both readers of each sample (backlog #62, Get-WifiInterfaceView): an interface the WLAN
    # service lists while netsh printed nothing for it - the whole output refused where desktop programs may not use the
    # location - gets its row, with each such sample said as not sampled and the service's state beside it, rather than
    # the no-interface row a wired computer gets.
    $category = "IT Diagnostics"
    $check = "Wi-Fi association"
    $samples = @(@($Samples) | Where-Object { $null -ne $_ })
    $readable = @($samples | Where-Object { Test-WifiSampleReadable $_ })
    $momentText = @{ start = "before the first measurement"; middle = "with the IT diagnostics"; end = "after the last measurement" }
    $entries = @()
    $index = 0
    foreach ($sample in $samples) {
        $index++
        $moment = [string]$sample.Moment
        if ($momentText.ContainsKey($moment)) { $moment = $momentText[$moment] }
        $stamp = ""
        try { $stamp = ([datetime]$sample.Timestamp).ToString("HH:mm:ss") } catch { $stamp = "" }
        $entries += [pscustomobject]@{ Sample = $sample; Prefix = ("Sample {0} ({1}, {2})" -f $index, $moment, $stamp) }
    }
    $seconds = 0
    if ($samples.Count -ge 2) { try { $seconds = [math]::Round((([datetime]$samples[$samples.Count - 1].Timestamp) - ([datetime]$samples[0].Timestamp)).TotalSeconds, 0) } catch { $seconds = 0 } }
    # Whether the tool's own WLAN API reader answered in this run, as a token the aggregate rows carry after their reason
    # (PR #55, round 4): wlanapi=ok, or the reader's reason code - addtype, open, enumerate, error. The chain's oracle reads it
    # where netsh was refused: a reader that could not answer leaves the tool no interface to write a row for, and the
    # aggregate rows are then the right shape rather than a missing one. The last sample that carried a reading decides.
    $apiToken = ""
    foreach ($sample in $samples) {
        $sampleApi = Get-PropertyValue $sample "Api" $null
        if ($null -eq $sampleApi) { continue }
        $apiError = [string](Get-PropertyValue $sampleApi "Error" "")
        $apiToken = $(if ([string]::IsNullOrWhiteSpace($apiError)) { "ok" } else { $apiError })
    }
    $apiSuffix = $(if ($apiToken) { "; wlanapi=" + $apiToken } else { "" })
    $methodLines = @(
        ("Method: netsh wlan show interfaces, read {0} time(s) during the test - before the first measurement, with the IT diagnostics and after the last measurement - and the BSSID of each reading compared with the others; the access point is sampled, not watched. Beside each read, the WLAN service's own list of the wireless interfaces and each one's connection state (WlanEnumInterfaces), so that an interface netsh printed nothing for is still known, with its state." -f $samples.Count),
        "Manual check: netsh wlan show interfaces, repeated while the problem is happening",
        "Explanation: the BSSID is the access point's own address, so a change under the same network name is a roam - the air-side event that explains a run with a good signal and bad numbers - and a change of network name is a move to another network. A change between two samples that returned to the same access point cannot be seen here: two equal samples do not exclude one. Windows' WLAN event log records the network and not the access point, so it was not read. This row decides nothing."
    )

    if ($samples.Count -eq 0) {
        Add-CheckResult -Category $category -Check $check -Status "ERROR" -Message "No access-point sample was taken during the test, so the association cannot be compared." -Details ((@("Reading: none") + $methodLines) -join [Environment]::NewLine) -Tag "wifi-association" -Scope "IT" | Out-Null
        return
    }
    if ($readable.Count -eq 0) {
        # Every sample failed: one row, with the reason code at the end of its first details line - a language-neutral
        # token like a tag - which is how the chain's oracle tells this aggregate row from a per-interface row.
        $first = $samples[0]
        $reason = [string]$first.Error
        # netsh that ran and exited non-zero with nothing listed, beside a service reading that failed (round 10): the reason
        # token is refused, and the message says both readers, because neither answered.
        if ([string]::IsNullOrWhiteSpace($reason)) { $reason = "refused" }
        $message = "The Wi-Fi association could not be sampled: netsh.exe was not found."
        if ($reason -eq "refused") { $message = "The Wi-Fi association could not be sampled: netsh wlan show interfaces printed no interface, and the WLAN service could not be read." }
        elseif ($reason -ne "netsh") { $message = "The Wi-Fi association could not be sampled: netsh wlan show interfaces could not be read." }
        $lines = @(("Reading: {0}{1}" -f $reason, $apiSuffix))
        foreach ($entry in $entries) {
            $apiSummary = Get-WifiApiSummaryText -Sample $entry.Sample
            $netshText = [string]$entry.Sample.ErrorText
            if ([string]::IsNullOrWhiteSpace($netshText)) { $netshText = Get-WifiNetshReasonText -Sample $entry.Sample }
            $lines += ("{0}: could not be read - {1}{2}" -f $entry.Prefix, $netshText, $(if ($apiSummary) { "; " + $apiSummary } else { "" }))
        }
        Add-CheckResult -Category $category -Check $check -Status "ERROR" -Message $message -Details ((@($lines) + $methodLines) -join [Environment]::NewLine) -Diagnostics ([string]$first.Diagnostics) -Tag "wifi-association" -Scope "IT" | Out-Null
        return
    }

    # The interfaces either reader listed at any readable sample, by GUID where one was printed and by adapter address
    # where it was not, in the order first seen; the views of each sample kept for the loop below.
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
        $lines = @(("Reading: none{0}" -f $apiSuffix))
        foreach ($entry in $entries) {
            $sample = $entry.Sample
            $apiSummary = Get-WifiApiSummaryText -Sample $sample
            if ([string]::IsNullOrWhiteSpace([string]$sample.Error)) {
                $reason = Get-WifiNetshReasonText -Sample $sample
                $lines += ("{0}: no wireless interface listed{1}{2}" -f $entry.Prefix, $(if ($reason) { " - " + $reason } else { "" }), $(if ($apiSummary) { "; " + $apiSummary } else { "" }))
            }
            else { $lines += ("{0}: could not be read - {1}{2}" -f $entry.Prefix, [string]$sample.ErrorText, $(if ($apiSummary) { "; " + $apiSummary } else { "" })) }
        }
        Add-CheckResult -Category $category -Check $check -Status "INFO" -Message ("No wireless interface was listed at any of the {0} sample(s), by netsh or by the WLAN service, so there is no access point to compare - a wired computer, for example; the sample lines say what each reader returned." -f $samples.Count) -Details ((@($lines) + $methodLines) -join [Environment]::NewLine) -Tag "wifi-association" -Scope "IT" | Out-Null
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
                $lines += ("{0}: could not be read - {1}" -f $entry.Prefix, [string]$sample.ErrorText)
                # A sample that failed is still one of the run's samples (PR #54, round 1): it counts in every total the
                # message names, and it is neither a reading of the access point nor evidence that the interface was absent.
                $readings += [pscustomobject]@{ State = "failed"; Moment = [string]$sample.Moment; Bssid = ""; Ssid = ""; ApiState = $null; LocationDenied = $false }
                continue
            }
            $match = @(@($viewsBySample[$i]) | Where-Object { [string]$_.Key -eq $key } | Select-Object -First 1)
            if ($match.Count -eq 0) {
                $lines += ("{0}: interface not listed" -f $entry.Prefix)
                $readings += [pscustomobject]@{ State = "absent"; Moment = [string]$sample.Moment; Bssid = ""; Ssid = ""; ApiState = $null; LocationDenied = $false }
                continue
            }
            $view = $match[0]
            $apiState = $view.State
            $stateSuffix = ""
            if ($null -ne $apiState) { $stateSuffix = "; WLAN service: {0}" -f (Get-WifiInterfaceStateText $apiState) }
            if ((ConvertTo-IntSafe $view.ConnectionQuery -1) -gt 0) { $stateSuffix += ("; connection query: {0}" -f (Get-Win32ErrorText $view.ConnectionQuery)) }
            if (-not $view.NetshListed) {
                # Listed by the WLAN service, nothing printed by netsh (backlog #62): not a reading of the access point and
                # not an absence either - a sample at which the interface existed and could not be sampled, with the
                # reason the sample recorded and the state the service gave.
                $reason = Get-WifiNetshReasonText -Sample $sample
                if ([string]::IsNullOrWhiteSpace($reason)) { $reason = "netsh wlan show interfaces did not list this interface" }
                $lines += ("{0}: not sampled - {1}{2}" -f $entry.Prefix, $reason, $stateSuffix)
                $readings += [pscustomobject]@{ State = "refused"; Moment = [string]$sample.Moment; Bssid = ""; Ssid = ""; ApiState = $apiState; LocationDenied = [bool]$view.Refused }
                continue
            }
            $bssid = ([string]$view.Bssid).Trim().ToLowerInvariant()
            if ([string]::IsNullOrWhiteSpace($bssid)) { $lines += ("{0}: no BSSID reported{1}" -f $entry.Prefix, $stateSuffix) }
            else { $lines += (("{0}: SSID {1}, BSSID {2}" -f $entry.Prefix, (ConvertTo-DisplayString $view.Ssid), $bssid) + $stateSuffix) }
            $readings += [pscustomobject]@{ State = $(if ([string]::IsNullOrWhiteSpace($bssid)) { "nobssid" } else { "bssid" }); Moment = [string]$sample.Moment; Bssid = $bssid; Ssid = [string]$view.Ssid; ApiState = $apiState; LocationDenied = $false }
        }
        $withBssid = @($readings | Where-Object { $_.State -eq "bssid" })
        $absentCount = @($readings | Where-Object { $_.State -eq "absent" }).Count
        $failedCount = @($readings | Where-Object { $_.State -eq "failed" }).Count
        $refused = @($readings | Where-Object { $_.State -eq "refused" })
        $listedMoments = @($readings | Where-Object { $_.State -eq "bssid" -or $_.State -eq "nobssid" -or $_.State -eq "refused" } | ForEach-Object { $_.Moment })
        # The WLAN service's account of the interface, for the sentences that carry it: at how many of the samples the
        # service listed it was it connected. Never "disconnected" from an absent BSSID (backlog #62): the field can be
        # withheld from an associated radio, and the state is the service's to say.
        $apiKnown = @($readings | Where-Object { $null -ne $_.ApiState })
        $apiConnected = @($apiKnown | Where-Object { $_.ApiState -eq 1 })
        $stateSentence = ""
        if ($apiKnown.Count -gt 0) {
            if ($apiConnected.Count -eq $apiKnown.Count) { $stateSentence = " The WLAN service reported it connected at all {0} sample(s) it listed it at." -f $apiKnown.Count }
            elseif ($apiConnected.Count -eq 0) { $stateSentence = " The WLAN service reported it not connected at any of the {0} sample(s) it listed it at." -f $apiKnown.Count }
            else { $stateSentence = " The WLAN service reported it connected at {0} of the {1} samples it listed it at." -f $apiConnected.Count, $apiKnown.Count }
        }
        $locationCount = @($refused | Where-Object { $_.LocationDenied }).Count
        $refusedSentence = ""
        if ($refused.Count -gt 0) {
            if ($locationCount -eq $refused.Count) { $refusedSentence = " At {0} of the samples netsh printed no interface because desktop programs may not use the location (the WLAN service refused the connection query with error 5; Settings > Privacy & security > Location)." -f $refused.Count }
            else { $refusedSentence = " At {0} of the samples netsh printed no interface; the sample lines say what was recorded." -f $refused.Count }
        }
        if ($withBssid.Count -eq 0) {
            if ($refused.Count -gt 0 -and $refused.Count -eq $listedMoments.Count) {
                if ($locationCount -eq $refused.Count) {
                    $message = "{0}: the access point could not be sampled at any of the {1} sample(s): netsh printed no interface because desktop programs may not use the location (the WLAN service refused the connection query with error 5; Settings > Privacy & security > Location), so a roam cannot be seen here.{2}" -f $name, $readings.Count, $stateSentence
                }
                else {
                    $message = "{0}: the access point could not be sampled at any of the {1} sample(s): netsh printed no interface (the sample lines say what was recorded), so a roam cannot be seen here.{2}" -f $name, $readings.Count, $stateSentence
                }
            }
            else {
                $message = ("{0}: no access point (BSSID) was reported at any of the {1} sample(s) - the interface was not associated, or netsh did not print the field; see the Wi-Fi radio row." -f $name, $readings.Count) + $refusedSentence + $stateSentence
            }
        }
        else {
            $distinctBssids = @($withBssid | ForEach-Object { $_.Bssid } | Select-Object -Unique)
            $distinctSsids = @($withBssid | ForEach-Object { $_.Ssid } | Select-Object -Unique)
            $first = $withBssid[0]
            if ($distinctBssids.Count -eq 1 -and $distinctSsids.Count -gt 1) {
                # The same address under more than one network name (PR #54, round 2): the access point was renamed or
                # reconfigured during the run, which the steady sentence would have hidden behind the first name.
                $ssidSequence = @()
                foreach ($reading in $withBssid) { if ($ssidSequence.Count -eq 0 -or $ssidSequence[$ssidSequence.Count - 1] -cne $reading.Ssid) { $ssidSequence += $reading.Ssid } }
                $message = "{0}: the same access point (BSSID {1}) at the {2} of {3} samples that reported one, but under more than one network name - SSID {4} - so the access point was renamed or reconfigured during the run." -f $name, $first.Bssid, $withBssid.Count, $readings.Count, (@($ssidSequence | ForEach-Object { ConvertTo-DisplayString $_ }) -join ", then ")
            }
            elseif ($distinctBssids.Count -eq 1) {
                if ($withBssid.Count -eq $readings.Count) {
                    $message = "{0}: SSID {1} on the same access point (BSSID {2}) at all {3} samples over {4} seconds; a change between two samples that returned to it cannot be seen." -f $name, (ConvertTo-DisplayString $first.Ssid), $first.Bssid, $readings.Count, $seconds
                }
                else {
                    $message = "{0}: SSID {1} on the same access point (BSSID {2}) at the {3} of {4} samples that reported one; at the other(s) no BSSID was reported, netsh printed no interface, the interface was not listed, or the sample could not be read." -f $name, (ConvertTo-DisplayString $first.Ssid), $first.Bssid, $withBssid.Count, $readings.Count
                }
            }
            else {
                # The sequence of access points as sampled, consecutive repeats folded, so that A then B then A reads as
                # what it is - a roam that came back, which two samples alone would have hidden.
                $sequence = @()
                $labels = @()
                foreach ($reading in $withBssid) {
                    if ($sequence.Count -gt 0 -and $sequence[$sequence.Count - 1] -eq $reading.Bssid) { continue }
                    $sequence += $reading.Bssid
                    $labels += ("SSID {0} (BSSID {1})" -f (ConvertTo-DisplayString $reading.Ssid), $reading.Bssid)
                }
                $changes = $sequence.Count - 1
                $shape = "a roam"
                if ($changes -gt 1) {
                    $shape = "{0} roams" -f $changes
                    if ($sequence[0] -eq $sequence[$sequence.Count - 1]) { $shape += ", back to the first access point" }
                }
                if ($distinctSsids.Count -eq 1) {
                    $message = "{0}: the access point changed during the test - BSSID {1} - under the same SSID {2}: {3}. This run's figures were measured across the change." -f $name, ($sequence -join ", then "), (ConvertTo-DisplayString $first.Ssid), $shape
                }
                else {
                    $message = "{0}: the interface moved to another network during the test - {1}. This run's figures were measured across the change." -f $name, ($labels -join ", then ")
                }
            }
            $message += $refusedSentence
            # A BSSID netsh printed beside a service state that is not connected - the two reads are sequential, and the radio
            # can drop between them - is disclosed rather than hidden behind the address (PR #55, round 3): the service's
            # account is appended wherever it is not "connected at every sample it listed the interface at".
            if ($apiKnown.Count -gt 0 -and $apiConnected.Count -lt $apiKnown.Count) { $message += $stateSentence }
        }
        if ($absentCount -gt 0) { $message += (" The interface was not listed at {0} of the samples (disabled or removed at that moment)." -f $absentCount) }
        if ($failedCount -gt 0) { $message += (" {0} of the samples could not be read." -f $failedCount) }
        # The identity line ends with the samples the interface was listed at, as a language-neutral token (samples=start,middle,end):
        # the chain's oracle reads it to tell an interface present at the middle sample only - which neither of its two
        # readings can have listed - from a row naming an interface nobody listed (PR #54, round 1). A sample at which the
        # WLAN service listed the interface and netsh printed nothing counts as listed: the interface was there.
        $identity = @()
        if ($key -like "mac:*") { $identity += ("Interface address: {0}; samples={1}" -f $key.Substring(4), ($listedMoments -join ",")) } else { $identity += ("Interface GUID: {0}; samples={1}" -f $key, ($listedMoments -join ",")) }
        Add-CheckResult -Category $category -Check $check -Status "INFO" -Message $message -Details ((@($lines) + $identity + $methodLines) -join [Environment]::NewLine) -Tag "wifi-association" -Scope "IT" | Out-Null
    }
}

function Get-MacRelation {
    param([string]$First, [string]$Second)

    # How two MAC addresses stand to each other, for the access-point-is-the-gateway hint (backlog #61's other half):
    # identical; near-ul and near-last - differing only in the locally-administered bit of the first octet, or only in
    # the last octet, the shapes one device's radio and bridge addresses commonly take; vendor - the same first three
    # octets, that bit aside; different; or invalid where either is not a MAC address. Separators and case are not part
    # of the address.
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

    # The comparison behind the hint, as evidence and as the sentence (PR #54, round 3): the access point's address, how it
    # stands to the gateway's (Get-MacRelation's word, nobssid where the interface reported none, empty where nothing was
    # compared), the interface's name, and the text the row prints. The refresh after the last sample compares the address
    # and the relation, never the sentence - an interface renamed during the run changes the sentence and nothing else.

    # The hint's sentence, or nothing (backlog #61's other half). The one thing to know before trying to separate the air
    # from the wire on a wireless machine is whether there is a wire at all: the access point that answers the radio and
    # the gateway that answers the pings may be one box. The BSSID is the access point's own address and the neighbour
    # table holds the gateway's, so the two are compared - for the wireless interface whose adapter supplied this
    # gateway, matched by the adapter's own address, which netsh prints as the interface's physical address, in the
    # latest access-point sample that could be read - and published as the hint it is: identical addresses are one
    # device, but an all-in-one's radio and bridge addresses commonly differ by an octet or the locally-administered
    # bit, so a difference proves nothing. A gateway supplied by a wired adapter has no access point to compare with,
    # and the Wi-Fi data switched off leaves nothing to compare from: in both cases the line is absent.
    $evidence = [pscustomobject][ordered]@{ Text = ""; Bssid = ""; Relation = ""; Interface = "" }
    $gatewayHex = ([string]$GatewayMac) -replace '[^0-9a-fA-F]', ''
    if ($gatewayHex.Length -ne 12 -or $gatewayHex -eq "000000000000") { return $evidence }
    # The adapter is the one the neighbour entry was learned on (PR #54, round 1): on a machine whose wired and wireless
    # adapters name the same gateway address, the entry's MAC may belong to the wired network, and a comparison with the
    # wireless network's access point would then set two unrelated addresses side by side. -InterfaceIndex is the entry's
    # interface; where the entry carries none - the arp -a fallback - and more than one adapter supplies the gateway,
    # nothing is compared.
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
            $evidence.Text = ("Access point and gateway: this gateway is reached over the wireless interface {0}, for which no BSSID was reported, so the two addresses could not be compared." -f $name)
            return $evidence
        }
        $evidence.Bssid = $bssid
        $evidence.Relation = Get-MacRelation -First $GatewayMac -Second $bssid
        switch ($evidence.Relation) {
            "identical" { $evidence.Text = ("Access point and gateway: the gateway's MAC address is the BSSID of the access point {0} is associated with ({1}), so the access point and the gateway are one device - a router with its own radio - and on this network there is no boundary between the air and the wire for a wired-versus-wireless comparison to stand on." -f $name, $bssid) }
            "near-ul"   { $evidence.Text = ("Access point and gateway: the gateway's MAC address differs from the BSSID of the access point {0} is associated with ({1}) only in the locally-administered bit, the shape one device's radio and bridge addresses commonly take; read the two as probably one device - a hint, not a topology claim." -f $name, $bssid) }
            "near-last" { $evidence.Text = ("Access point and gateway: the gateway's MAC address differs from the BSSID of the access point {0} is associated with ({1}) only in its last octet, the shape one device's radio and bridge addresses commonly take; read the two as probably one device - a hint, not a topology claim." -f $name, $bssid) }
            "vendor"    { $evidence.Text = ("Access point and gateway: the gateway's MAC address shares its vendor prefix (the first three octets) with the BSSID of the access point {0} is associated with ({1}) - the same maker, one device or two; a hint, not a topology claim." -f $name, $bssid) }
            default     { $evidence.Text = ("Access point and gateway: the gateway's MAC address and the BSSID of the access point {0} is associated with ({1}) share no vendor prefix, which suggests two devices - an access point and a router - and so a boundary between the air and the wire that a wired station on the same segment could measure from; a hint, not a topology claim, since a router with its own radio can use unrelated addresses for the two." -f $name, $bssid) }
        }
        return $evidence
    }
    return $evidence
}

function Get-AccessPointGatewayText {
    param([string]$Gateway, [string]$GatewayMac, [object[]]$PrimaryAdapters, [object[]]$Samples, [int]$InterfaceIndex = 0)

    # The sentence alone, for the callers that print it; the evidence behind it is Get-AccessPointGatewayEvidence's.
    return ([string](Get-AccessPointGatewayEvidence -Gateway $Gateway -GatewayMac $GatewayMac -PrimaryAdapters $PrimaryAdapters -Samples $Samples -InterfaceIndex $InterfaceIndex).Text)
}

function Update-AccessPointGatewayHints {
    param([object[]]$Samples)

    # The hint on a gateway-neighbour row is written with the IT diagnostics, when only the first two access-point samples
    # exist; a roam between that read and the last sample would leave it comparing the gateway with an access point the
    # association row says was left (PR #54, round 2). So after the last sample the comparison is made again, against the
    # latest sample that could be read: where it reads the same, the row is untouched; where it does not, the line written
    # at the neighbour read stays - it was true at that moment - and a second line gives the comparison with the access
    # point the interface was on at the end, or says that none was reported then, and points at the association row.
    foreach ($entry in @($script:GatewayNeighborRows)) {
        if ($null -eq $entry -or $null -eq $entry.Row) { continue }
        $freshEvidence = Get-AccessPointGatewayEvidence -Gateway ([string]$entry.Gateway) -GatewayMac ([string]$entry.Mac) -PrimaryAdapters @($script:PrimaryAdapters) -Samples @($Samples) -InterfaceIndex (ConvertTo-IntSafe $entry.InterfaceIndex 0)
        # The evidence is compared, not the sentence (round 3): the same address in the same relation is the same finding,
        # whatever the interface is called by now.
        if (([string]$freshEvidence.Bssid -eq [string](Get-PropertyValue $entry "Bssid" "")) -and ([string]$freshEvidence.Relation -eq [string](Get-PropertyValue $entry "Relation" ""))) { continue }
        $fresh = [string]$freshEvidence.Text
        if ([string]::IsNullOrWhiteSpace([string]$fresh)) {
            $line = "Access point and gateway, after the last sample: no BSSID was reported for the interface any more, so the comparison above could not be repeated; the Wi-Fi association row records what the samples saw."
        }
        else {
            $line = "Access point and gateway, after the last sample: {0} At the neighbour read the interface was on another access point, or reported none - the Wi-Fi association row records the samples - so the line above, where there is one, stands for that moment and this one for the end of the run." -f ($fresh -replace '^[^:：]*[:：]\s*', '')
        }
        $lines = @(([string]$entry.Row.Details) -split "\r?\n")
        $at = -1
        if (-not [string]::IsNullOrWhiteSpace([string]$entry.Hint)) { $at = [array]::IndexOf($lines, [string]$entry.Hint) }
        if ($at -lt 0) {
            # No line was written at the neighbour read: the new one goes where that line would have been, before the method line.
            for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -like "Method:*") { $at = $i - 1; break } }
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
        Add-CheckResult -Category "IT Diagnostics" -Check "IPv4 default routes" -Status "INFO" -Message "Get-NetRoute is not available; the route table was not read." -Details "Manual check: route print -4" -Tag "routes" -Scope "IT" | Out-Null
        return
    }

    $routes = @()
    try {
        $routes = @(Sort-DefaultRoutes -Routes @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix "0.0.0.0/0" -ErrorAction Stop))
    }
    catch {
        # A CIM query that matches nothing is not an empty result in Windows PowerShell: Get-NetRoute throws
        # CimJobException (FullyQualifiedErrorId CmdletizationQuery_NotFound, category ObjectNotFound), with a message
        # in the machine's display language. That is the normal state of a machine without a default route - the
        # host-only case of backlog #19 - and until 1.2.3 it was written as an engine error (backlog #27). The id is
        # the cmdlet's own and does not follow the display language; anything else is a real failure.
        if ($_.FullyQualifiedErrorId -notmatch "^CmdletizationQuery_NotFound") {
            Add-CheckResult -Category "IT Diagnostics" -Check "IPv4 default routes" -Status "ERROR" -Message "The route table could not be read." -Details ((Get-ExceptionDetails $_) + [Environment]::NewLine + "Manual check: route print -4") -Diagnostics (Get-ExceptionDiagnostics $_) -Tag "routes" -Scope "IT" | Out-Null
            return
        }
        $routes = @()
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
        # The interface the entry was learned on, for the access-point hint below (PR #54, round 1); 0 where the arp -a
        # fallback, which prints no interface index, supplied the address.
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
            Add-CheckResult -Category "IT Diagnostics" -Check "Gateway neighbor (ARP)" -Status "ERROR" -Message "The neighbor table could not be read." -Details ((Get-ExceptionDetails $_) + [Environment]::NewLine + "Manual check: arp -a") -Diagnostics (Get-ExceptionDiagnostics $_) -Tag "gateway-neighbor" -Scope "IT" | Out-Null
            continue
        }

        $lines = @()
        if ([string]::IsNullOrWhiteSpace($mac) -or $mac -match '^(00[-:]){5}00$' -or $state -match 'Unreachable|Incomplete') { $lines += "The gateway has no resolved MAC address; Layer 2 to the router may be broken (the gateway ping above is the authoritative test)." }
        # backlog #61's other half: is the access point the gateway? The one thing to know before trying to separate the
        # air from the wire on a wireless machine, published as a hint - Get-AccessPointGatewayText says what each shape
        # of the comparison does and does not establish - and absent where the gateway's adapter is wired or the Wi-Fi
        # data was not read.
        $accessPointEvidence = Get-AccessPointGatewayEvidence -Gateway ([string]$gateway) -GatewayMac $mac -PrimaryAdapters $PrimaryAdapters -Samples @($script:WifiAssociationSamples) -InterfaceIndex $neighborIfIndex
        $accessPointLine = [string]$accessPointEvidence.Text
        if (-not [string]::IsNullOrWhiteSpace($accessPointLine)) { $lines += $accessPointLine }
        if ($null -eq $script:GatewayNeighborRows) { $script:GatewayNeighborRows = New-Object System.Collections.ArrayList }
        $lines += "Method: Get-NetNeighbor -AddressFamily IPv4 (fallback: arp -a)"
        $lines += "Manual check: arp -a"
        $message = "Gateway {0}: neighbor state {1}, MAC {2}." -f $gateway, $state, (ConvertTo-DisplayString $mac)
        $neighborRow = Add-CheckResult -Category "IT Diagnostics" -Check "Gateway neighbor (ARP)" -Status "INFO" -Message $message -Details ($lines -join [Environment]::NewLine) -Tag "gateway-neighbor" -Scope "IT"
        # Kept so that Update-AccessPointGatewayHints can make the comparison again once the last access-point sample exists (PR #54,
        # round 2) - the address and the relation, which is what the refresh compares, beside the sentence it printed (round 3).
        [void]$script:GatewayNeighborRows.Add([pscustomobject]@{ Row = $neighborRow; Gateway = [string]$gateway; Mac = [string]$mac; InterfaceIndex = $neighborIfIndex; Hint = [string]$accessPointLine; Bssid = [string]$accessPointEvidence.Bssid; Relation = [string]$accessPointEvidence.Relation })
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

function Add-DroppedTargetResults {
    # A target that was given to the run and not tested leaves a row where its result would have been, in the section
    # it belonged in (backlog #39). Taking the verdict off the Startup Notice without this row would hide the mistake
    # instead of demoting it: the reader looks where the answer belongs, finds nothing, and reads absence as a check
    # nobody asked for. The row is weightless for the same reason the notice is - it is a fact about the input.
    foreach ($dropped in @($script:DroppedTargets)) {
        $kind = [string]$dropped.Kind
        $value = [string]$dropped.Value
        if ($kind -eq "Tcp") {
            Add-CheckResult -Category "TCP Connection" -Check ("Extra TCP " + $value) -Status "ERROR" -Message "This target was given to the run and not tested, because it is not host:port with a host that can be used." -Details ("Value as given: {0}. Nothing was sent, so this row says nothing about the network; the overall result is unchanged by it." -f $value) -Tag "tcp" -Weightless | Out-Null
        }
    }
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
    param(
        [string]$ClassName,
        [int]$Attempts = 1,
        [System.Collections.IList]$FailedAttempts,
        [string[]]$RequireProperty
    )

    # The one place every CIM/WMI query of this tool passes through, and since 1.2.8 the place where a query may be
    # attempted more than once (backlog #38). A performance-counter read that waits out its eight-second limit and
    # then succeeds on a second attempt costs the run those seconds; a read that is not attempted again costs it the
    # measurement, and on the evidence of 2026-09-08 that is the first run inside a freshly extracted copy - the run
    # a person makes when something is wrong. Every attempt that failed is recorded in $FailedAttempts with the
    # seconds it spent, whether or not a later one worked: a retry that leaves no trace cannot explain the sample
    # window it lengthened. Callers that pass no -Attempts keep the single attempt they have always made.
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
                throw "No usable CIM/WMI command is available on this system."
            }
            # A query that returns nothing, or an instance without the fields the caller needs, is a read that
            # failed as surely as one that threw - and until this check moved inside the attempt it was thrown from
            # outside the loop, so it got no second attempt while a timeout did (PR #40, round 5). Only callers that
            # ask for properties are checked; the pre-window read asks for none, because its reading is discarded.
            if (@($RequireProperty).Count -gt 0) {
                if ($instance -is [array]) {
                    $instance = $instance | Select-Object -First 1
                }
                if ($null -eq $instance) {
                    throw "Performance counter class $ClassName returned no data."
                }
                foreach ($requiredName in $RequireProperty) {
                    if ($null -eq $instance.PSObject.Properties[$requiredName]) {
                        throw "Performance counter class $ClassName is missing required fields."
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

    # The one place a count threshold becomes the unsigned number the delta arithmetic compares against, because
    # the cast is where the defect was (PR #49, round 1): [uint64] of a negative value throws, so a configuration
    # with TcpRetransmissionCriticalCount = -1 turned the whole retransmission analysis into an Unable to Check
    # row instead of reporting the value - the configuration check reads a count threshold's type and its
    # integrality and never its sign. Two of the three call sites predate 1.2.10, so the fix is here rather than
    # at the new one. A negative value falls back to the built-in default, which is what every other value this
    # tool cannot use does, and Test-ConfigurationSemantics now says so in the Configuration Thresholds row.
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

    # -WarmUp: one throwaway read per class, in a pass of its own before any counter is read (backlog #38). A pass
    # of its own is the point (PR #40, round 3): interleaved with the measured reads, TCPv6's warm-up fell after
    # TCPv4's baseline stamp and so inside TCPv4's window - and a warm-up that is merely slow, which is the
    # start-up cost this feature exists to absorb, would have lengthened that window while leaving no failure to
    # explain it. Taken here, every warm-up precedes both baseline stamps, delays them equally, and lengthens no
    # window at all. The readings are discarded - this is not a measurement, and a failure of one is not a finding.
    # Failures are recorded and no more, because whether the first read of a session is the one that fails is
    # exactly the question this item leaves open.
    if ($WarmUp) {
        foreach ($protocol in @("TCPv4", "TCPv6")) {
            $className = "Win32_PerfRawData_Tcpip_$protocol"
            $warmUpAttempts = New-Object System.Collections.ArrayList
            try {
                Get-CimOrWmiInstance -ClassName $className -FailedAttempts $warmUpAttempts | Out-Null
            }
            catch {
                # Discarded on purpose: the attempt is already in $warmUpAttempts, and this read is not a reading.
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

    # Timestamp is when the whole snapshot finished; each protocol carries its own, taken when its own read returned,
    # and since 1.2.8 that is the pair a sample duration is measured from. FailedAttempts holds the measured reads
    # that failed even where a later attempt worked; WarmUpFailures holds the discarded pre-window reads that failed.
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

    # One place for the way a failed read is named, because three rows quote it: the row of a counter that could not
    # be read, the row of a protocol whose window carried the failure, and the line listing a protocol's own. A read
    # taken before the window says so wherever it appears, so that its seconds are never taken for a window's.
    return ((@($Attempts) | ForEach-Object {
        if ([string]$_.Phase -eq "warm-up") { "{0} #{1} (the discarded read before the window)" -f $_.Protocol, $_.Attempt }
        elseif ([string]$_.Phase -eq "extension") { "{0} #{1} (the read that extended the window)" -f $_.Protocol, $_.Attempt }
        elseif ([string]$_.Phase -eq "interval") { "{0} #{1} (a read between the samples)" -f $_.Protocol, $_.Attempt }
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

    # What a row says about the counter reads of its own protocol that failed in one snapshot, whether or not a later
    # attempt worked (backlog #38): one line, naming the snapshot it belongs to, with the pre-window read first
    # because it was taken first. Until 1.2.8 a read that timed out and then succeeded handed back a clean counter
    # and no record of the seconds it spent, and the row could not explain its own window. Which of these seconds
    # fell inside that window is a different question, and the note below answers it; this line is about this
    # counter, not about this window. Nothing is said about a read that behaved: a row explains what happened, not
    # what did not (backlog #40).
    $lines = @()
    $failed = @()
    $failed += @(@(Get-PropertyValue $Snapshot "WarmUpFailures" @()) | Where-Object { [string]$_.Protocol -eq $Protocol })
    $failed += @(@(Get-PropertyValue $Snapshot "FailedAttempts" @()) | Where-Object { [string]$_.Protocol -eq $Protocol })
    if (@($failed).Count -gt 0) {
        if ($Ending) {
            $lines += ("Counter reads of this protocol that failed while the ending values were taken: {0} ({1} seconds in total)." -f (Format-TcpAttemptList $failed), (Get-TcpAttemptSeconds $failed))
        }
        else {
            $lines += ("Counter reads of this protocol that failed while the baseline was taken: {0} ({1} seconds in total)." -f (Format-TcpAttemptList $failed), (Get-TcpAttemptSeconds $failed))
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
        Add-CheckResult -Category "TCP Retransmissions" -Check "System Counters" -Status "ERROR" -Message "Complete before-and-after TCP counter data is unavailable." -Details "" -Tag "tcp-retransmissions" -Weightless | Out-Null
        return
    }

    # One row per read that failed, in the order the reads were made, and the attempts behind it (backlog #38). The
    # status, the check name and the message are what they were before the retry existed - a retry that hides a real
    # failure is worse than no retry - and what the row gained is the attempts: a failure that says nothing about
    # what was tried teaches nothing afterwards. Read per snapshot, so that each error is rendered with the attempts
    # of the snapshot it came from - and with the other snapshot's attempts for that protocol when the other
    # snapshot wrote no row of its own for it (PR #40, round 4). That case is the one where they would otherwise be
    # lost entirely: a protocol whose counter could not be read in one snapshot has no reading and therefore no
    # quality row, and the quality row is the only other place those attempts are named.
    # backlog #65: the reads inside the window, one state object for the run (or none, where the reads are off or
    # the run never opened them); the line that says where they stopped goes on every row this analysis writes.
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
            Add-CheckResult -Category "TCP Retransmissions" -Check ("{0} counters" -f $errorItem.Protocol) -Status "ERROR" -Message "The TCP retransmission counter could not be read." -Details ((@($errorDetails) | Where-Object { $_ }) -join [Environment]::NewLine) -Diagnostics $errorItem.Diagnostics -Tag "tcp-retransmissions" -Weightless | Out-Null
        }
    }

    $warningPercent = ConvertTo-DoubleSafe (Get-PropertyValue $script:Config.Thresholds "TcpRetransmissionWarningPercent" 2) 2
    $criticalPercent = ConvertTo-DoubleSafe (Get-PropertyValue $script:Config.Thresholds "TcpRetransmissionCriticalPercent" 5) 5
    $criticalCount = Get-CountThreshold "TcpRetransmissionCriticalCount" 50
    $minimumSegments = Get-CountThreshold "MinimumTcpSegmentsForRate" 50
    $verdictFloor = Get-CountThreshold "MinimumTcpRetransmissionsForVerdict" 5
    # The order Get-TcpCounterSnapshot reads the two protocols in, which is what decides whose window a failed read
    # lands in (backlog #38). The reads are serial and each protocol's stamp is taken when its own read returns, so a
    # window is lengthened by a read that delayed the stamp closing it without delaying the stamp opening it. In the
    # ending snapshot that is every read at or before this protocol; in the baseline snapshot it is every read
    # *after* it - a stalled TCPv6 baseline read pushes TCPv6's opening stamp and the rest of the run alike, but not
    # TCPv4's, so it lands squarely inside TCPv4's window (PR #40, round 1: the first draft called every baseline
    # failure harmless, which is true only of the protocol read first). The pre-window reads are in neither list,
    # because they are all taken before either baseline stamp and lengthen no window (round 3).
    $readOrder = @("TCPv4", "TCPv6")
    # The protocols whose ending stamp came from a window extended once (backlog #51). An extension's failed reads
    # are inside those protocols' windows and outside every other protocol's, because a protocol the extension did
    # not close kept the stamp it already had (PR #49, round 1).
    $extendedProtocols = @(Get-PropertyValue $After "ExtendedProtocols" @())
    $configuredSeconds = [math]::Max(1, (ConvertTo-IntSafe (Get-PropertyValue $script:RunOptions "SampleSeconds" 8) 8))
    # backlog #52: where the run timed its own connections, the system-wide rows say where the attributable figure
    # is; where it did not - no TCP target, or none that answered - there is nothing to point at, and the line is
    # left out rather than promising a row that is not there.
    $attributionLine = $null
    if ($script:TcpConnectSampleCount -gt 0) { $attributionLine = "The TCP Connection rows carry what this row cannot: the tool's own connections to one named target, timed one by one, with the SYNs each of them had to send again." }

    foreach ($protocol in @("TCPv4", "TCPv6")) {
        if (-not $Before.Counters.ContainsKey($protocol) -or -not $After.Counters.ContainsKey($protocol)) {
            continue
        }

        $start = $Before.Counters[$protocol]
        $end = $After.Counters[$protocol]
        $sentDeltaDouble = [double]$end.SegmentsSent - [double]$start.SegmentsSent
        $retransDeltaDouble = [double]$end.Retransmitted - [double]$start.Retransmitted

        # The evidence a row owes about the reads behind it, gathered before any branch can return without it: the
        # counter-reset row used to be written and skipped past these lines, so a read that failed and was redeemed
        # vanished from a run whose counters had reset (PR #40, round 5). Every row of this protocol carries them.
        $sampleSeconds = [math]::Round((New-TimeSpan -Start $start.Timestamp -End $end.Timestamp).TotalSeconds, 1)
        $durationLine = "Sample duration: $sampleSeconds seconds (configured minimum: $configuredSeconds)"
        $evidenceLines = @()
        $evidenceLines += @(Get-TcpReadFailureLines -Snapshot $Before -Protocol $protocol)
        $selfIndex = $readOrder.IndexOf($protocol)
        $windowAttempts = @()
        $windowAttempts += @(@(Get-PropertyValue $Before "FailedAttempts" @()) | Where-Object { $readOrder.IndexOf([string]$_.Protocol) -gt $selfIndex })
        $closedByExtension = ($extendedProtocols -contains $protocol)
        $windowAttempts += @(@(Get-PropertyValue $After "FailedAttempts" @()) | Where-Object { $readOrder.IndexOf([string]$_.Protocol) -ge 0 -and $readOrder.IndexOf([string]$_.Protocol) -le $selfIndex -and (([string]$_.Phase -ne "extension") -or $closedByExtension) })
        # backlog #65: a read inside the window that failed lies inside both protocols' windows - it was taken after
        # both baseline stamps and before both ending stamps - except one taken while the window was being extended,
        # which is inside only the windows the extension closed.
        # PR #56, round 7: the same list decides the no-reading sentence of the placement block below - a read that failed
        # during the extension is outside the window of a protocol the extension did not close, and its block must
        # not claim the reads stopped inside a window they never reached.
        $intervalInsideAttempts = @(@(Get-PropertyValue $intervalState "FailedAttempts" @()) | Where-Object { (-not [bool]$_.Extension) -or $closedByExtension })
        $windowAttempts += $intervalInsideAttempts
        $windowNote = ""
        if (@($windowAttempts).Count -gt 0) {
            $windowNote = ("Note: {1} of these {0} seconds went on counter reads that failed inside the window ({2}); the configured minimum is {3} seconds." -f $sampleSeconds, (Get-TcpAttemptSeconds $windowAttempts), (Format-TcpAttemptList $windowAttempts), $configuredSeconds)
            $evidenceLines += $windowNote
        }
        # The reads the note above must not count and the row must still name (PR #49, round 1): where the window
        # was extended and this protocol's extended read failed, the reading kept is the first one and its window
        # had already closed, so those seconds are outside it. Backlog #38's promise is that every attempt which
        # failed is kept with the seconds it spent, so they get a line that says where they fall instead.
        $outsideAttempts = @(@(Get-PropertyValue $After "FailedAttempts" @()) | Where-Object { [string]$_.Protocol -eq $protocol -and [string]$_.Phase -eq "extension" -and -not $closedByExtension })
        # backlog #65: and this protocol's own reads inside the window that failed during the extension, for the same reason.
        $outsideAttempts += @(@(Get-PropertyValue $intervalState "FailedAttempts" @()) | Where-Object { [string]$_.Protocol -eq $protocol -and [bool]$_.Extension -and -not $closedByExtension })
        if (@($outsideAttempts).Count -gt 0) {
            $evidenceLines += ("Counter reads of this protocol that failed while the window was being extended: {0} ({1} seconds in total). This protocol's window had already closed, so those seconds are not part of the {2} above." -f (Format-TcpAttemptList $outsideAttempts), (Get-TcpAttemptSeconds $outsideAttempts), $sampleSeconds)
        }

        $evidenceLines += $intervalStopLines

        if ($sentDeltaDouble -lt 0 -or $retransDeltaDouble -lt 0) {
            # The window is a fact even where the delta is not, so this row prints the duration it spans and the
            # evidence for it. What it must not print is the sentence about the deltas above, which this row does
            # not have - the note keeps to the seconds and the reads, and the row with deltas adds that sentence
            # for itself (PR #40, round 7).
            $resetDetails = @($durationLine, ("Start Sent={0}, Retrans={1}; end Sent={2}, Retrans={3}" -f $start.SegmentsSent, $start.Retransmitted, $end.SegmentsSent, $end.Retransmitted)) + $evidenceLines
            Add-CheckResult -Category "TCP Retransmissions" -Check $protocol -Status "ERROR" -Message "The counter was reset or overflowed during the test, so the delta cannot be calculated." -Details ((@($resetDetails) | Where-Object { $_ }) -join [Environment]::NewLine) -Tag "tcp-retransmissions" -Weightless | Out-Null
            continue
        }

        $sentDelta = [uint64]$sentDeltaDouble
        $retransDelta = [uint64]$retransDeltaDouble
        $rate = 0.0
        if ($sentDelta -gt 0) {
            $rate = [math]::Round(($retransDelta * 100.0 / $sentDelta), 3)
            $script:RetransmissionRateComputed = $true
        }

        # A window in which no segment was counted as sent has no ratio, whatever the retransmitted delta is (PR #50,
        # round 2): printing 0% there described an undefined ratio, and the sentence below then claimed a division
        # that never happened. The sent counter excludes segments carrying only previously sent bytes, so such a
        # window can still carry a retransmission count - the small-sample rule below reports it - and the row says
        # what it can: how many, and why no rate.
        $rateLine = "Approximate retransmission rate: $rate%"
        $denominatorLine = "What the percentage divides by: the segments this computer sent in the window as the Segments Sent/sec counter counts them - acknowledgements included, segments carrying only retransmitted bytes excluded; a segment carrying new bytes beside retransmitted ones is in both counts. It is this tool's own ratio, not comparable with a published retransmission rate, which divides by a different quantity."
        if ($sentDelta -eq 0) {
            $rateLine = "Approximate retransmission rate: not computable - no segment was counted as sent in the window"
            if ($retransDelta -gt 0) { $rateLine += (" ({0} retransmitted segment(s) were counted all the same: the sent counter excludes segments carrying only previously sent bytes)" -f $retransDelta) }
            $denominatorLine = $null
        }
        $details = (@(
            $durationLine,
            "Sent TCP segment delta: $sentDelta",
            "Retransmitted segment delta: $retransDelta",
            $rateLine,
            "Starting cumulative values: Sent=$($start.SegmentsSent), Retrans=$($start.Retransmitted)",
            "Ending cumulative values: Sent=$($end.SegmentsSent), Retrans=$($end.Retransmitted)",
            "Method: Win32_PerfRawData_Tcpip_$protocol cumulative counters; delta over the sample window.",
            "Manual check: Get-CimInstance Win32_PerfRawData_Tcpip_$protocol — sample twice and compare the deltas.",
            "Explanation: This is a system-wide statistic for the entire computer during the test, not for a single application.",
            $attributionLine,
            # backlog #57: the denominator is the Segments Sent/sec counter as Windows defines it, and the row says so,
            # because the printed percentage is not the quantity any published retransmission rate refers to. The sentence
            # follows the counter's own help text and Microsoft's TCP Object reference (both read 2026-09-10): Segments Sent
            # excludes segments containing ONLY retransmitted bytes, Segments Retransmitted counts every segment containing one
            # or more previously transmitted bytes, so a mixed segment is in both counts. The row states the denominator and
            # does not say which way the figure errs: the acknowledgements in it pull it below a data-segment rate, the pure
            # retransmissions left out of it pull it above a byte ratio, and neither bias has been quantified on any run.
            $denominatorLine
        ) | Where-Object { $null -ne $_ }) -join [Environment]::NewLine

        if ($rate -gt 100) {
            $details += [Environment]::NewLine + "Note: a rate above 100% means retransmissions of segments sent before the sample window - read it as a ratio, not a percentage."
        }
        # Per protocol rather than per snapshot (PR #49, round 2): a protocol whose extended read failed kept the
        # first reading, its window was not extended, and the line below would go on to say its window had already
        # closed - one row contradicting itself.
        if ($closedByExtension) {
            $details += [Environment]::NewLine + "The sample window was extended once: the first window ended below MinimumTcpSegmentsForRate with at least one retransmission in it, which is the one case where waiting longer settles anything."
        }

        foreach ($line in $evidenceLines) {
            $details += [Environment]::NewLine + $line
        }
        if ($windowNote -ne "") {
            $details += [Environment]::NewLine + "The deltas above are still this protocol's own counts over the window shown."
        }

        # backlog #65: where the window counted a retransmission, where it fell. The table is this protocol's own, from
        # its own stamps, and the lines decide nothing.
        if ($null -ne $intervalState -and $intervalState.IntervalSeconds -gt 0 -and $retransDelta -gt 0) {
            $intervalTable = @(Get-TcpIntervalTable -Protocol $protocol -Start $start -End $end -Reads @(Get-PropertyValue $intervalState "Reads" @()))
            foreach ($line in @(Get-TcpDistributionLines -Protocol $protocol -Intervals $intervalTable -RetransDelta $retransDelta -SampleSeconds (New-TimeSpan -Start $start.Timestamp -End $end.Timestamp).TotalSeconds -State $intervalState -FailedInside $intervalInsideAttempts)) {
                $details += [Environment]::NewLine + $line
            }
        }

        if ($sentDelta -eq 0 -and $retransDelta -eq 0) {
            Add-CheckResult -Category "TCP Retransmissions" -Check $protocol -Status "INFO" -Message "There was not enough TCP send traffic during the sample. No retransmissions were observed, but this does not establish the long-term condition." -Details $details -Tag "tcp-retransmissions" | Out-Null
            continue
        }

        if ($sentDelta -lt $minimumSegments) {
            if ($retransDelta -gt 0) {
                # This was a WARN until 1.2.10. Closed item #39 made it weightless in 1.2.8, so the badge
                # already decided nothing, and all it did was colour a row "attention" beside a sentence saying
                # the row is not evidence - which is the contradiction a row should not carry. This is #51's
                # answer to what a small sample carrying a retransmission means: it is the record of that
                # retransmission, and not a verdict.
                # A window with nothing counted as sent has no rate, and the message - the line the report shows before the
                # details - must not print one either (PR #50, round 3). The phrase the user manual quotes is kept.
                $smallMessage = ("The traffic sample is small, but {0} retransmission(s) were observed (approximately {1}%)." -f $retransDelta, $rate)
                if ($sentDelta -eq 0) { $smallMessage = ("The traffic sample is small, but {0} retransmission(s) were observed; no segment was counted as sent, so no rate can be computed from them." -f $retransDelta) }
                Add-CheckResult -Category "TCP Retransmissions" -Check $protocol -Status "INFO" -Message $smallMessage -Details $details -Tag "tcp-retransmissions" -Weightless | Out-Null
            }
            else {
                Add-CheckResult -Category "TCP Retransmissions" -Check $protocol -Status "INFO" -Message ("The sample contains only {0} sent segment(s); no retransmissions were observed." -f $sentDelta) -Details $details -Tag "tcp-retransmissions" | Out-Null
            }
            continue
        }

        # backlog #51: a proportion is not a verdict until enough events went into it. At the smallest sample
        # this tool will rate - MinimumTcpSegmentsForRate, fifty as shipped - one retransmission is 2 %, the
        # warning threshold itself, and three are 6 %, which fails on the rate alone. The floor counts events, and
        # it gates BOTH branches: a floor on the warning branch alone would leave the coarsest sample convicting
        # harder than the one above it. What it costs is bounded by the same arithmetic - suppression needs a rate
        # at or above the warning threshold with fewer events than the floor, which is
        # sent <= (floor - 1) x 100 / warningPercent, two hundred sent segments at the shipped 5 and 2 %. That is
        # exactly the sample size at which one retransmission is a quarter of the warning threshold, and above it
        # nothing is ever suppressed.
        if ($retransDelta -lt $verdictFloor -and $rate -ge $warningPercent) {
            $details += [Environment]::NewLine + ("Fewer than {0} retransmissions went into this rate, so the rate is reported without a verdict: at this sample size one retransmission on its own is enough to carry it across a threshold. This row does not change the overall result." -f $verdictFloor)
            Add-CheckResult -Category "TCP Retransmissions" -Check $protocol -Status "INFO" -Message ("Sent {0}, retransmitted {1}, approximate retransmission rate {2}% - too few retransmissions to rate." -f $sentDelta, $retransDelta, $rate) -Details $details -Tag "tcp-retransmissions" -Weightless | Out-Null
            continue
        }

        # backlog #63, decided 2026-09-11: the count is a confidence qualifier on the rate - it may sharpen a
        # verdict the rate has already reached, and may never create one. So the standalone count trigger in the
        # WARN line goes and the conjunction in the FAIL line stays. The argument is a boundary,
        # TcpRetransmissionCriticalCount / TcpRetransmissionWarningPercent, which is 2 500 sent segments at the
        # shipped 50 and 2 %: below it, reaching fifty retransmissions means the rate is already at or above the
        # warning threshold and the standalone trigger adds nothing; above it, all the standalone trigger adds is
        # a warning on a sample whose rate is below the tool's own warning threshold.
        # And every row says which of the two decided it, because until now a reader could not tell (#63's
        # acceptance). A PASS says nothing: a row explains what happened, not what did not (backlog #40).
        $status = "PASS"
        $decided = ""
        if ($rate -ge $criticalPercent) {
            $status = "FAIL"
            $decided = ("Decided by the rate: {0}% is at or above the critical threshold of {1}%." -f $rate, $criticalPercent)
        }
        elseif ($retransDelta -ge $criticalCount -and $rate -ge $warningPercent) {
            $status = "FAIL"
            $decided = ("Decided by the rate and the count together: {0}% is at or above the warning threshold of {1}%, and {2} retransmissions are at or above {3}." -f $rate, $warningPercent, $retransDelta, $criticalCount)
        }
        elseif ($rate -ge $warningPercent) {
            $status = "WARN"
            $decided = ("Decided by the rate: {0}% is at or above the warning threshold of {1}%." -f $rate, $warningPercent)
        }
        if ($decided -ne "") { $details += [Environment]::NewLine + $decided }

        Add-CheckResult -Category "TCP Retransmissions" -Check $protocol -Status $status -Message ("Sent {0}, retransmitted {1}, approximate retransmission rate {2}%." -f $sentDelta, $retransDelta, $rate) -Details $details -Tag "tcp-retransmissions" | Out-Null
    }
}

function Test-TcpSampleNeedsExtension {
    param(
        [object]$Before,
        [object]$After
    )

    # backlog #51: the one case a longer window can settle. Below MinimumTcpSegmentsForRate the tool does not rate
    # the sample at all, and a sample below it that carried a retransmission is the ambiguous one - the row can
    # say a retransmission happened and cannot say how often. A machine idle enough to send nothing, or one that
    # sent little and retransmitted none of it, is not ambiguous: waiting longer would buy more of the same
    # nothing. A sample already at or above the floor is not extended either - it has a rate, and too few events
    # behind a rate is a count floor's business rather than a window's.
    # Since it decides whether a step runs at all, it is asked outside one, so it answers rather than throws:
    # a snapshot without counters is a run whose reads failed, and those rows are written either way.
    if ($null -eq $Before -or $null -eq $After) { return $false }
    if ($null -eq $Before.Counters -or $null -eq $After.Counters) { return $false }
    $minimumSegments = [double](Get-CountThreshold "MinimumTcpSegmentsForRate" 50)
    foreach ($protocol in @("TCPv4", "TCPv6")) {
        if (-not $Before.Counters.ContainsKey($protocol) -or -not $After.Counters.ContainsKey($protocol)) { continue }
        $sentDelta = [double]$After.Counters[$protocol].SegmentsSent - [double]$Before.Counters[$protocol].SegmentsSent
        $retransDelta = [double]$After.Counters[$protocol].Retransmitted - [double]$Before.Counters[$protocol].Retransmitted
        # A counter that went backwards is a reset or an overflow, so the delta means nothing and cannot be the
        # reason for spending more of the run waiting; the row for that protocol says so for itself (backlog #38).
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

    # The ending snapshot after a window was extended (backlog #51). Per protocol the later reading wins, because
    # it closes the longer window; where the later read failed the first one stands, so extending a window can
    # never cost a row that had already been measured. An error is kept only for a protocol that has no reading
    # from either read, and every failed attempt of both reads is kept, because the seconds they spent are seconds
    # of this window like any other.
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
    # A read that failed in the extension is marked as one, and the protocols the extension actually closed are
    # named, because whose window those seconds fall inside is not the same question for every protocol (PR #49,
    # round 1). A protocol whose extended read failed keeps the first reading and the stamp that came with it, so
    # its window ended before the extension began: counting the extension's seconds inside it would print more
    # failed seconds than the window is long. A protocol the extension did close has a window that really does
    # contain them. Compare-TcpCounters asks both questions with these two fields; nothing is discarded, and the
    # row still names every attempt that failed.
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
# Reads inside the sample window (backlog #65; v1.2.14). The two counter reads at the ends of the window give one pair
# of numbers per protocol, and a total over a window cannot tell fifty retransmissions inside ten seconds of it from
# fifty spread evenly across the whole of it - the burst the standalone count trigger fired on until 1.2.10 removed it
# (closed item #63). So the counters are read again inside the window, at least Tests.RetransmissionIntervalSeconds
# apart (2 as shipped, 0 switches it off), and a measured row places its retransmissions in time beside the
# whole-window figure. The rules that keep it honest: the reads come from the main thread only - a due-check after
# every step and once a second inside the waits - so the intervals are stamped and uneven, and the spacing is a
# minimum, not a period; a read inside the window is not the measurement and gets one attempt per class, never a
# second; the first read that fails ends the sampling for the run, so a machine whose reads run out of time pays one
# timeout and not one per interval; a failed read is kept with its seconds and named on the row, and writes no row of
# its own; and an interval is too small a sample to carry a rate, so none is computed from it, no threshold reads it
# and nothing here moves a status. Measured before it was built (reference machine, 2026-09-13): one read of both
# classes costs 102 ms at the median and 140 ms at the 95th percentile, so three reads inside an eight-second window
# cost about a third of a second, most of it inside the wait the run was going to sleep through anyway.
# ---------------------------------------------------------------------------------------------------------------------
function Get-TcpIntervalSeconds {
    # The one rule for Tests.RetransmissionIntervalSeconds: a whole number of seconds, 2 as shipped, 0 for no read
    # inside the window; anything else - a fraction, a negative value, text - falls back to the shipped 2, which is
    # what Test-ConfigurationSemantics reports for it.
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

    # Opens the window for the reads inside it: from the baseline stamp, and again from the start of the extension
    # (backlog #51). A run whose sampling a failed read stopped stays stopped through the extension - the rule is one
    # timeout per run - and an interval of 0 opens nothing. The state is one object per run, cleared with the results.
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
    # PR #56, round 5: the window's deadline - the stamp the window opened at plus the configured minimum - travels with
    # the state, and the due-check takes nothing once it has passed, whichever path asks. Rounds 2 and 3 closed two
    # paths one at a time (the wait's last sleep, the steps after the wait); the spread probes' pauses and a step
    # that overran the minimum were the third, and one rule in one place is what stops there being a fourth.
    if ($Deadline -is [datetime]) { $state.Deadline = $Deadline }
    # PR #56, round 2: the reading that closed the first window is a point of the table when the window is extended,
    # so the intervals of the first window and of the extension are told apart; it costs nothing, being the
    # measurement's own read, and it is kept whether or not the sampling is still open.
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
    # Closed before the ending read is taken, so that no read of this kind can fall after the stamp that closes the
    # window; the state itself stays, because the rows are written from it.
    if ($null -ne $script:TcpIntervalSampling) { $script:TcpIntervalSampling.Active = $false }
}

function Read-TcpIntervalCounters {
    # One read of both classes with ONE attempt each: the second attempt exists to save the measurement (backlog #38),
    # and this read is not the measurement. What it returns has the shape of a snapshot's readings, so the intervals
    # are computed from the same fields; what failed is recorded with its seconds, as every failed read is.
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
            # The attempt is already in $readAttempts: a read inside the window that failed is a fact for the row,
            # not an error of the run.
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
        # PR #56, round 1: the pass stops at the first class that failed. Reading the next class after a timeout would
        # spend a second eight seconds on a provider that has just refused - the bound is one timeout per run, not one
        # per class - and for the class not read the interval this read would have closed merges with its neighbour.
        if (@($readAttempts).Count -gt 0) { break }
    }
    return [pscustomobject][ordered]@{
        Timestamp      = Get-Date
        Counters       = $counters
        FailedAttempts = @($failed)
    }
}

function Invoke-TcpIntervalReadIfDue {
    # The due-check, called after every step and once a second inside the waits. It reads only when the last read is
    # at least the configured interval old, so a long step simply yields a longer interval - the intervals are stamped
    # and the row prints each one's length. It never throws: a failure of any kind is a failed read, recorded and
    # ending the sampling, because a check that runs after every step must not be able to fail the step.
    $state = $script:TcpIntervalSampling
    if ($null -eq $state -or -not $state.Active) { return }
    # PR #56, round 5: past the window's deadline nothing is read, from any path - the read would fall after the
    # minimum and add its whole cost to the run - and the sampling closes here for good.
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

    # The intervals of one protocol's window: its baseline reading, every reading of it taken inside the window, its
    # ending reading - in stamp order, so a reading that fell after this protocol's ending stamp (an extension that
    # closed the other protocol only) is outside by the stamps alone. Each interval carries its own seconds and
    # deltas; an empty table means a reading went backwards inside the window, and the row says so.
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

    # What a measured row says about where its retransmissions fell - only where there were any: a window that
    # retransmitted nothing has nothing to place, and a row explains what happened (backlog #40). The interval with
    # the most retransmissions is named with its share of them and its share of the window's seconds, side by side,
    # so that a reader sees a burst - most of the retransmissions in a small part of the time - without the tool
    # calling it one: no adjective, no threshold, and no rate for an interval, because a two-second interval on a
    # quiet machine is the small sample closed item #51 is about.
    $lines = @()
    if ($null -eq $State -or $State.IntervalSeconds -le 0 -or $RetransDelta -eq 0) { return $lines }
    $table = @($Intervals)
    if ($table.Count -eq 0) {
        $lines += "A counter read inside the window went backwards, so the retransmissions cannot be placed in time."
        return $lines
    }
    if ($table.Count -lt 2) {
        # PR #56, round 4: a window with no reading inside it says why, and "none was due" is only one of the reasons -
        # the reads may have stopped at a read that failed before this window had a reading, and that read is named
        # on the row with its seconds; a sentence saying none was due beside it would contradict the row.
        # Round 7: the failed reads inside THIS protocol's window, which the caller knows and the state does not.
        if (@($FailedInside).Count -gt 0) {
            $lines += "The reads inside the window stopped at a read that failed before this window had a reading inside it - that read and its seconds are named above - so the retransmissions cannot be placed in time."
        }
        else {
            $lines += ("No counter read fell inside this window between its two samples, so the retransmissions cannot be placed in time: the reads are taken between the checks and during the wait, at least {0} second(s) apart, and none was due before the window closed." -f $State.IntervalSeconds)
        }
        return $lines
    }
    $lines += ("Where the retransmissions fell inside the window (the counters were read again at least {0} second(s) apart: {1} readings, {2} intervals):" -f $State.IntervalSeconds, ($table.Count + 1), $table.Count)
    foreach ($interval in $table) {
        $lines += ("  {0}-{1} s: sent {2}, retransmitted {3}" -f $interval.FromSeconds, $interval.ToSeconds, $interval.Sent, $interval.Retransmitted)
    }
    # The most retransmissions; among equals the shorter interval, then the earlier one.
    $worst = @($table | Sort-Object -Property @{ Expression = "Retransmitted"; Descending = $true }, @{ Expression = "Seconds"; Descending = $false }, @{ Expression = "Index"; Descending = $false })[0]
    $share = [math]::Round(100.0 * [double]$worst.Retransmitted / [double]$RetransDelta)
    $timeShare = 0
    if ($SampleSeconds -gt 0) { $timeShare = [math]::Round(100.0 * $worst.Seconds / $SampleSeconds) }
    $lines += ("The interval with the most retransmissions held {0} of the {1} ({2}%) in {3} seconds, {4}% of the window." -f $worst.Retransmitted, $RetransDelta, $share, [math]::Round($worst.Seconds, 1), $timeShare)
    $lines += "These lines place the retransmissions in time and nothing more: an interval is too small a sample to carry a rate, so none is computed from it; a segment sent again is not a segment lost; and no figure here changes this row's status."
    return $lines
}

function Get-TcpIntervalStopLine {
    param([object]$State)

    # Every row this analysis writes carries this line where the sampling stopped, because a read that failed is
    # kept and named wherever it fell (backlog #38), and the reads before the failure still stand.
    if ($null -eq $State -or $null -eq $State.StoppedAt) { return @() }
    return @(("The reads inside the window stopped at {0} after a read of {1} failed ({2} seconds); the intervals before it stand, and the last interval runs to the ending sample." -f $State.StoppedAt.ToString("HH:mm:ss"), $State.StopReason, (Get-TcpAttemptSeconds @($State.FailedAttempts))))
}

# ---------------------------------------------------------------------------------------------------------------------
# Wi-Fi retransmissions (backlog #61, the retry-counter half; v1.2.12). The 802.11 MAC retries a frame whose
# acknowledgement did not come back, and a retry that succeeds is absorbed as delay: IP and TCP see no loss, the ping
# rows see a slower reply, and the TCP retransmission rows see nothing at all. The retry rate is therefore the one
# figure that separates the air between this adapter and its access point from everything behind the access point,
# and Windows exposes it through the Native Wifi API only: WlanQueryInterface with wlan_intf_opcode_statistics
# returns WLAN_STATISTICS, whose PhyCounters array carries the MAC frame counters per PHY. There is no netsh
# equivalent, so the reader is P/Invoke through Add-Type - unmanaged code in a script that is otherwise plain
# PowerShell, a choice the v1.2 design note declined for the RF data because netsh could supply it and this item
# takes because nothing else can (decided 2026-09-12, the five points in the backlog's Status line). The compile
# takes about 0.7 s on the reference machine and leaves nothing on disk; an application-control policy that refuses
# the C# compiler or an in-memory assembly stops it, and the row then says so and decides nothing.
#
# What was measured before this was written (2026-09-10 and 2026-09-12, Intel Wi-Fi 6E AX211, Windows 11): the query
# succeeds without elevation; the buffer is 1088 bytes for six PHYs, which is what the documented layout predicts; and
# the driver writes the interface's totals into EVERY PHY entry - six identical rows of counters, moving in step. So
# the entries are never added together: the interface's figure is the entry whose transmitted-frame delta is largest,
# and the row says how many entries moved and whether they agreed. A driver that attributes frames per PHY would give
# the same answer for a run on one PHY, and a run that changed PHY would be undercounted rather than counted six times.
# The rate is retries / (transmitted + abandoned): ullRetryCount counts frames that succeeded after one or more
# retransmissions, ullFailedCount the frames given up after the retry limit, which ullTransmittedFrameCount does not
# include; ullMultipleRetryCount is a subset of ullRetryCount and is listed as one. The counters are cumulative for the
# association, so the before-and-after delta over this run is what is reported, with the same backwards-counter branch
# as the TCP rows. This row decides nothing: no threshold for a wireless retry rate has a stated basis (backlog #56).
# ---------------------------------------------------------------------------------------------------------------------

function Get-WlanApiType {
    # The few lines of P/Invoke the two wireless readers share - the retry counters (backlog #61) and the interface states
    # (backlog #62) - compiled once per process and found by name afterwards. Why it could not be compiled is returned
    # rather than thrown, because the row of whichever reader asked names the reason: an application-control policy can
    # refuse Add-Type, and that is a fact about the machine, not about its network.
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
        $result.ErrorText = "The type was compiled but could not be loaded."
        return $result
    }
    $result.Type = $apiType
    return $result
}

function Get-LocationConsentState {
    # The location consent as Windows records it, read so that a denied connection query has a second witness before a
    # row may name the location setting as the cause (PR #55, round 1): error 5 is access denied and no more, and a
    # policy that restricts WLAN queries, or a Windows without the gating, would otherwise be reported as a consent
    # problem and sent to the wrong setting. The consent store (CapabilityAccessManager\ConsentStore\location) holds one
    # value per level - the user's, the device's, the desktop programs' and, under NonPackaged, netsh's own entry - and
    # Deny at any of them denies (measured at the user level and at the device level on 2026-09-12); the gating of
    # Wi-Fi details behind it exists since Windows 11 24H2, build 26100. A store that cannot be read is no witness.
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
        [pscustomobject]@{ Name = "user"; Path = ("HKCU:\" + $store) },
        [pscustomobject]@{ Name = "device"; Path = ("HKLM:\" + $store) },
        [pscustomobject]@{ Name = "desktop apps"; Path = ("HKCU:\" + $store + "\NonPackaged") },
        [pscustomobject]@{ Name = "netsh"; Path = ("HKCU:\" + $store + "\NonPackaged\C:#Windows#System32#netsh.exe") }
    )
    $readings = @()
    foreach ($level in $levels) {
        $value = "(no entry)"
        if (Test-Path -LiteralPath $level.Path) {
            $value = "(empty)"
            try {
                $consent.Known = $true
                $raw = [string](Get-PropertyValue (Get-ItemProperty -LiteralPath $level.Path -ErrorAction Stop) "Value" "")
                if (-not [string]::IsNullOrWhiteSpace($raw)) { $value = $raw }
            }
            catch { $value = "(unreadable)" }
        }
        if ($value -eq "Deny") { $consent.Denied = $true }
        $readings += [pscustomobject]@{ Name = $level.Name; Value = $value }
    }
    $consent.Levels = @($readings)
    $consent.Text = (@($readings | ForEach-Object { "{0} {1}" -f $_.Name, $_.Value }) -join ", ")
    return $consent
}

function Get-RadioSwitchState {
    param([int]$On, [int]$Off, [int]$Read)

    # One radio switch's word from the PHY entries read (PR #55, round 8): on where any PHY reports on, off only where every
    # PHY read reports off, unknown otherwise - a driver reporting some PHYs off and the rest indeterminate has not said
    # the radio is off, and a row that called a switch disabled on that would claim more than was read.
    if ($On -gt 0) { return "on" }
    if ($Read -gt 0 -and $Off -eq $Read) { return "off" }
    return "unknown"
}

function Get-WlanInterfaceStates {
    # One reading of what the WLAN service itself says about every wireless interface (backlog #62): the list of them
    # and each one's connection state (WlanEnumInterfaces), its channel (WlanQueryInterface, opcode 8) and its radio
    # switches (opcode 4) - and, for an interface the service calls connected, whether the service would hand this
    # process the connection's details at all. That last is asked with the very call netsh makes for the network name,
    # the access point, the signal and the rates (opcode 7, the current connection), and only for its return code: 5,
    # access denied, is what Windows 11 24H2 and later answer while desktop programs may not use the location - the
    # setting under which netsh prints no interface - measured on the reference machine on 2026-09-12 with the list,
    # the state, the channel, the radio switches and the retry counters all still readable. The envelope is returned
    # whatever it holds, with the same reason codes as the retry reader (addtype, open, enumerate, error).
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
            # WLAN_INTERFACE_INFO_LIST: two DWORDs, then WLAN_INTERFACE_INFO entries of a GUID, 256 WCHARs of
            # description and a DWORD state - 532 bytes each, the layout the retry reader reads.
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
            # The channel: a DWORD, read where the query answers and left empty where it does not.
            $size = [uint32]0
            $data = [IntPtr]::Zero
            $code = $apiType::WlanQueryInterface($handle, [ref]$queryGuid, 8, [IntPtr]::Zero, [ref]$size, [ref]$data, [IntPtr]::Zero)
            if ($code -eq 0) {
                try { if ($size -ge 4) { $entry.Channel = [System.Runtime.InteropServices.Marshal]::ReadInt32($data, 0) } }
                finally { $apiType::WlanFreeMemory($data) }
            }
            # The radio switches: WLAN_RADIO_STATE is a DWORD count and then, per PHY, three DWORDs - the PHY index, the
            # software state and the hardware state, each 1 for on and 2 for off. The radio is off where every PHY
            # reports off, on where any reports on, unknown otherwise.
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
            # The connection query, for its return code alone, and only where the service says connected: the data is
            # netsh's to print, and this reader wants to know whether netsh could have.
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
    # One reading of every wireless interface's MAC frame counters, with the reason where there is none. The envelope
    # is returned whatever it holds, like the TCP snapshot: the analysis writes the row, with the evidence attached.
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
            # WLAN_INTERFACE_INFO_LIST: two DWORDs, then WLAN_INTERFACE_INFO entries of a GUID, 256 WCHARs of
            # description and a DWORD state - 532 bytes each.
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
                # WLAN_STATISTICS: three ULONGLONGs, two WLAN_MAC_FRAME_STATISTICS of twelve ULONGLONGs, dwNumberOfPhys
                # at 216 with its alignment, then WLAN_PHY_FRAME_STATISTICS entries of eighteen ULONGLONGs from 224 -
                # the layout the 1088-byte buffer for six PHYs confirmed. A buffer shorter than its own count says is
                # reported as such rather than read past its end.
                $numberOfPhys = 0
                if ($size -ge 220) { $numberOfPhys = [System.Runtime.InteropServices.Marshal]::ReadInt32($data, 216) }
                if ($numberOfPhys -lt 1 -or $size -lt (224 + ($numberOfPhys * 144))) {
                    $entry.QueryError = -1
                    $entry.QueryErrorText = ("The statistics buffer ({0} bytes) does not hold the {1} PHY entries it declares." -f $size, $numberOfPhys)
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
    if ([string]::IsNullOrWhiteSpace($text)) { return ("error {0}" -f $number) }
    return ("error {0}: {1}" -f $number, $text)
}

function Get-WifiInterfaceStateText {
    param([object]$State)
    switch (ConvertTo-IntSafe $State -1) {
        0 { return "not ready" }
        1 { return "connected" }
        2 { return "ad hoc network formed" }
        3 { return "disconnecting" }
        4 { return "disconnected" }
        5 { return "associating" }
        6 { return "discovering" }
        7 { return "authenticating" }
    }
    return ("state {0}" -f $State)
}

function Compare-WifiRetryCounters {
    param([object]$Before, [object]$After)

    $category = "Wi-Fi Retransmissions"
    if ($null -eq $Before -or $null -eq $After) {
        Add-CheckResult -Category $category -Check "Wireless retries" -Status "ERROR" -Message "Complete before-and-after Wi-Fi retry counter data is unavailable." -Details "" -Tag "wifi-retry" -Weightless | Out-Null
        return
    }

    # A snapshot that could not be taken names why, once, and the row is weightless: an absent reader is a fact about
    # this machine, not a measurement of its network. No wireless interface is the ordinary wired case and reads as one.
    $bothNone = ([string]$Before.Error -eq "none" -and [string]$After.Error -eq "none")
    foreach ($pair in @(@{ Snapshot = $Before; Side = "at the start"; Other = $After }, @{ Snapshot = $After; Side = "at the end"; Other = $Before })) {
        $snapshot = $pair.Snapshot
        if ([string]::IsNullOrWhiteSpace([string]$snapshot.Error)) { continue }
        $reason = [string]$snapshot.Error
        $status = "ERROR"
        $message = ""
        switch ($reason) {
            "none"      { if ($bothNone) { $status = "INFO"; $message = "No wireless interface on this computer, so there is no wireless retry figure; the TCP retransmission rows are the link's statistics." } else { $message = "The wireless interface was listed at only one of the two readings ({0} it was not), so no delta could be calculated: the adapter was enabled or disabled during the test, or the other reading failed." -f $pair.Side } }
            "addtype"   { $message = "The Wi-Fi retry counters could not be read: the reader (a small P/Invoke type compiled at run time) could not be compiled or loaded, which an application-control policy can refuse." }
            "open"      { $message = "The Wi-Fi retry counters could not be read: the WLAN service did not answer ({0})." -f $snapshot.ErrorText }
            "enumerate" { $message = "The Wi-Fi retry counters could not be read: the wireless interfaces could not be listed ({0})." -f $snapshot.ErrorText }
            default     { $message = "The Wi-Fi retry counters could not be read {0}." -f $pair.Side }
        }
        # The first line ends with the reason code - a language-neutral token, like a tag - which is how the chain's oracle
        # tells this aggregate row from a per-interface error row that carries the same tag and status (PR #52, round 2).
        $details = @(
            ("Reading {0}: {1}" -f $pair.Side, $reason),
            $(if (-not [string]::IsNullOrWhiteSpace([string]$snapshot.ErrorText)) { [string]$snapshot.ErrorText } else { $null }),
            $(if (-not $bothNone -and -not [string]::IsNullOrWhiteSpace([string]$pair.Other.Error)) { "The other reading: {0} {1}" -f $pair.Other.Error, $pair.Other.ErrorText } else { $null }),
            "Method: Native Wifi API, WlanQueryInterface with wlan_intf_opcode_statistics through P/Invoke (wlanapi.dll), read before and after the run.",
            "Explanation: this row decides nothing; where it is absent, the TCP retransmission rows and the ping rows are the link's statistics, and a wireless retry is visible in neither."
        )
        Add-CheckResult -Category $category -Check "Wireless retries" -Status $status -Message $message -Details ((@($details) | Where-Object { $null -ne $_ }) -join [Environment]::NewLine) -Diagnostics ([string]$snapshot.Diagnostics) -Tag "wifi-retry" -Weightless | Out-Null
        return
    }

    $seconds = [math]::Round(($After.Timestamp - $Before.Timestamp).TotalSeconds, 1)
    # The method lines are the same on every per-interface row, so they are built once (round 5 moved them out of the loop).
    $methodLines = @(
        "Method: Native Wifi API, WlanQueryInterface with wlan_intf_opcode_statistics through P/Invoke (wlanapi.dll); cumulative MAC frame counters read before and after the run, delta over the window.",
        "Manual check: no built-in command prints these counters; the API is the only reader.",
        "Explanation: an 802.11 frame the adapter sent again because no acknowledgement came back is absorbed as delay, so it appears in neither the TCP retransmission rate nor the ping loss figure; this is the air between this adapter and its access point, for every application's traffic in the window. This row decides nothing: no threshold for a wireless retry rate has a stated basis."
    )
    foreach ($ending in @($After.Interfaces)) {
        $starting = @(@($Before.Interfaces) | Where-Object { [string]$_.Guid -eq [string]$ending.Guid } | Select-Object -First 1)
        $description = ConvertTo-DisplayString $ending.Description
        $guidLine = "Interface GUID: {0}" -f $ending.Guid
        $stateLine = "Connection state: {0} at the start, {1} at the end." -f $(if ($starting.Count -gt 0) { Get-WifiInterfaceStateText $starting[0].State } else { "not listed" }), (Get-WifiInterfaceStateText $ending.State)
        if ($starting.Count -eq 0) {
            Add-CheckResult -Category $category -Check "Wireless retries" -Status "ERROR" -Message ("{0}: the interface was not present at the start of the test, so there is no delta." -f $description) -Details ((@($stateLine, $guidLine) + $methodLines) -join [Environment]::NewLine) -Tag "wifi-retry" -Weightless | Out-Null
            continue
        }
        $start = $starting[0]
        if ($start.QueryError -ne 0 -or $ending.QueryError -ne 0) {
            $which = $(if ($start.QueryError -ne 0) { $start.QueryErrorText } else { $ending.QueryErrorText })
            Add-CheckResult -Category $category -Check "Wireless retries" -Status "ERROR" -Message ("{0}: the statistics query failed ({1})." -f $description, $which) -Details ((@($stateLine, $guidLine) + $methodLines) -join [Environment]::NewLine) -Tag "wifi-retry" -Weightless | Out-Null
            continue
        }

        # The PHY rule, stated where it is applied: deltas per entry, the entry with the largest transmitted delta is
        # the interface's figure, and the entries are never added together (the header of this block says why).
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
            Add-CheckResult -Category $category -Check "Wireless retries" -Status "ERROR" -Message ("{0}: the two readings hold no PHY entry in common, so there is no delta." -f $description) -Details ((@($stateLine, $guidLine) + $methodLines) -join [Environment]::NewLine) -Tag "wifi-retry" -Weightless | Out-Null
            continue
        }
        $backwards = @($deltas | Where-Object { $_.Transmitted -lt 0 -or $_.Failed -lt 0 -or $_.Retry -lt 0 -or $_.MultipleRetry -lt 0 -or $_.AckFailure -lt 0 -or $_.Received -lt 0 })
        if ($backwards.Count -gt 0) {
            $resetLines = @(("Sample window: {0} seconds." -f $seconds), $stateLine, $guidLine)
            foreach ($d in $backwards) {
                $resetLines += ("Entry {0}: start Transmitted={1}, Failed={2}, Retry={3}, MultipleRetry={4}; end Transmitted={5}, Failed={6}, Retry={7}, MultipleRetry={8}" -f $d.Index, $d.Start.Transmitted, $d.Start.Failed, $d.Start.Retry, $d.Start.MultipleRetry, $d.End.Transmitted, $d.End.Failed, $d.End.Retry, $d.End.MultipleRetry)
            }
            Add-CheckResult -Category $category -Check "Wireless retries" -Status "ERROR" -Message ("{0}: the counters went backwards during the test - the adapter reconnected or the driver reset them - so the delta cannot be calculated." -f $description) -Details ((@($resetLines) + $methodLines) -join [Environment]::NewLine) -Tag "wifi-retry" -Weightless | Out-Null
            continue
        }
        $moved = @($deltas | Where-Object { $_.Transmitted -ne 0 -or $_.Failed -ne 0 -or $_.Retry -ne 0 -or $_.MultipleRetry -ne 0 -or $_.AckFailure -ne 0 -or $_.Received -ne 0 })
        $chosen = @($deltas | Sort-Object -Property @{ Expression = "Transmitted"; Descending = $true }, @{ Expression = "Index"; Descending = $false })[0]
        $agree = $true
        foreach ($d in $moved) {
            if ($d.Transmitted -ne $chosen.Transmitted -or $d.Failed -ne $chosen.Failed -or $d.Retry -ne $chosen.Retry -or $d.MultipleRetry -ne $chosen.MultipleRetry) { $agree = $false }
        }
        $phyLine = "PHY entries: {0} reported, {1} moved during the window" -f $deltas.Count, $moved.Count
        if ($moved.Count -gt 1 -and $agree) { $phyLine += ", all with the same figures - the driver writes the interface's totals into every entry" }
        elseif ($moved.Count -gt 1) { $phyLine += (", with different figures ({0})" -f ((@($moved | ForEach-Object { "entry {0}: transmitted {1}, retries {2}, abandoned {3}" -f $_.Index, $_.Transmitted, $_.Retry, $_.Failed }) -join "; "))) }
        $phyLine += ("; the entry with the largest transmitted delta (entry {0}) is the interface's figure, and entries are never added together, because a driver that mirrors the totals would have every frame counted once per entry." -f $chosen.Index)
        $transmitted = [uint64]$chosen.Transmitted
        $failed = [uint64]$chosen.Failed
        $retry = [uint64]$chosen.Retry
        $multiple = [uint64]$chosen.MultipleRetry
        $ackFailures = [uint64]$chosen.AckFailure
        $received = [uint64]$chosen.Received
        $attempted = $transmitted + $failed
        $countLines = @(
            ("Sample window: {0} seconds." -f $seconds),
            ("Transmitted frame delta: {0}; abandoned after the retry limit: {1}; frames that needed retransmission: {2}, of which more than once: {3}; missing acknowledgements: {4}; received frame delta: {5}." -f $transmitted, $failed, $retry, $multiple, $ackFailures, $received),
            $phyLine,
            $stateLine,
            $guidLine,
            ("Starting cumulative values (entry {0}): Transmitted={1}, Failed={2}, Retry={3}, MultipleRetry={4}, ACKFailure={5}, Received={6}" -f $chosen.Index, $chosen.Start.Transmitted, $chosen.Start.Failed, $chosen.Start.Retry, $chosen.Start.MultipleRetry, $chosen.Start.AckFailure, $chosen.Start.Received),
            ("Ending cumulative values (entry {0}): Transmitted={1}, Failed={2}, Retry={3}, MultipleRetry={4}, ACKFailure={5}, Received={6}" -f $chosen.Index, $chosen.End.Transmitted, $chosen.End.Failed, $chosen.End.Retry, $chosen.End.MultipleRetry, $chosen.End.AckFailure, $chosen.End.Received)
        )
        if ($attempted -eq 0) {
            $message = "{0}: no frames were transmitted in the {1}-second window, so no retry rate can be computed." -f $description, $seconds
            Add-CheckResult -Category $category -Check "Wireless retries" -Status "INFO" -Message $message -Details ((@($countLines) + @("Retry rate: not computable - nothing was transmitted, so there is nothing to divide by.") + $methodLines) -join [Environment]::NewLine) -Tag "wifi-retry" -Weightless | Out-Null
            continue
        }
        $rate = [math]::Round(([double]$retry / [double]$attempted) * 100.0, 1)
        $message = "{0}: {1} of {2} frames needed retransmission ({3}%), {4} of them more than once, {5} abandoned, over {6} seconds." -f $description, $retry, $attempted, $rate, $multiple, $failed, $seconds
        $rateLine = "Retry rate: {0} / ({1} transmitted + {2} abandoned) = {3}%; the two retry counters are neither added together nor divided into each other." -f $retry, $transmitted, $failed, $rate
        Add-CheckResult -Category $category -Check "Wireless retries" -Status "INFO" -Message $message -Details ((@($countLines) + @($rateLine) + $methodLines) -join [Environment]::NewLine) -Tag "wifi-retry" -Weightless | Out-Null
    }
    # An interface listed at the start and not at the end (PR #52, round 5): disabled or removed during the test, so no
    # delta - its own row, since a machine with a second wireless interface keeps both readings free of errors.
    foreach ($starting in @($Before.Interfaces)) {
        if (@(@($After.Interfaces) | Where-Object { [string]$_.Guid -eq [string]$starting.Guid }).Count -gt 0) { continue }
        $description = ConvertTo-DisplayString $starting.Description
        $stateLine = "Connection state: {0} at the start, not listed at the end." -f (Get-WifiInterfaceStateText $starting.State)
        $guidLine = "Interface GUID: {0}" -f $starting.Guid
        Add-CheckResult -Category $category -Check "Wireless retries" -Status "ERROR" -Message ("{0}: the interface was listed at the start of the test and not at the end - disabled or removed during the test - so there is no delta." -f $description) -Details ((@($stateLine, $guidLine) + $methodLines) -join [Environment]::NewLine) -Tag "wifi-retry" -Weightless | Out-Null
    }
}

function Wait-ForMinimumTcpSample {
    param(
        [datetime]$StartTime,
        [int]$MinimumSeconds,
        [int]$ProgressPercent = 87
    )

    # Clock-based since 1.2.14 (backlog #65): the wait ends at the minimum whatever ran inside it, so a counter read
    # taken during the wait consumes time the run was going to sleep through and lengthens nothing. Until then the
    # count of seconds was fixed when the wait began, and anything done inside it pushed the window past the minimum.
    while ($true) {
        $elapsed = ((Get-Date) - $StartTime).TotalSeconds
        $remainingMs = [int][math]::Ceiling(($MinimumSeconds - $elapsed) * 1000.0)
        if ($remainingMs -le 0) {
            return
        }
        $remainingSeconds = [int][math]::Ceiling($remainingMs / 1000.0)
        Set-UiProgress -Percent $ProgressPercent -Text ("Sampling TCP retransmissions, approximately $remainingSeconds second(s) remaining")
        Start-Sleep -Milliseconds ([math]::Min(1000, $remainingMs))
        # PR #56, round 2: a read due on the last sleep would run after the minimum had passed and add its whole cost
        # to the run; the deadline is checked again first, and the ending read that follows closes the window.
        if (((Get-Date) - $StartTime).TotalSeconds -ge $MinimumSeconds) { return }
        Invoke-TcpIntervalReadIfDue
        if ($script:GuiAvailable) {
            [System.Windows.Forms.Application]::DoEvents()
        }
    }
}

# -----------------------------------------------------------------------------
# Result aggregation: overall precedence is FAIL > ERROR > WARN > PASS.
# -----------------------------------------------------------------------------
function Get-OverallStatus {
    # The overall result is decided by what the run measured (backlog #39). A supplementary statistic that could not
    # be taken, a sample too coarse for the threshold applied to it, and a fact about this run's own input each keep
    # their row, their badge and their place in the counts, are named in the summary, and do not change the result;
    # everything else keeps its weight, optional targets included, because an optional target that answered badly is
    # a measurement. Put the other way round: the verdict answers what the machine is like, not what the last thirty
    # seconds of typing were like. Until 1.2.8 one unreadable counter made a run in which every check passed read as
    # Test Incomplete, and the user manual had to apologise for the verdict - a document apologising for a verdict is
    # a sign the verdict is doing the wrong work.
    $weighted = @($script:Results | Where-Object { [string]$_.Scope -ne "IT" -and -not $_.Weightless })
    $failCount = @($weighted | Where-Object { $_.Status -eq "FAIL" }).Count
    $errorCount = @($weighted | Where-Object { $_.Status -eq "ERROR" }).Count
    $warnCount = @($weighted | Where-Object { $_.Status -eq "WARN" }).Count

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
# The report explained the "Unable to Check" badge and qualified a retransmission rate whether or not the run had
# produced either (backlog #40): a healthy report opened by explaining a badge nowhere on the page, which primes
# exactly the doubt it is meant to settle. Each half is now asked for separately, and the rate half turns on a
# rate having been computed rather than on a tagged row existing - a run whose counter reads both failed emits
# tagged ERROR rows and never obtains a rate.
function Get-ReportNoticeFlags {
    return [pscustomobject][ordered]@{
        Unable = (@($script:Results | Where-Object { [string]$_.Status -eq "ERROR" }).Count -gt 0)
        Rate   = [bool]$script:RetransmissionRateComputed
    }
}

# The one file to send, named once and quoted by both surfaces (backlog #46): the window and the console say the
# same thing about the same file - the one Open Report opens, which is the HTML unless it could not be written.
# What this replaces is three files in a folder and a person who did not know which of them goes to IT.
function Get-SendToItLine {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return "" }
    return ("Send this file to IT: {0}" -f $Path)
}

function Get-FingerprintSummary {
    # Every predicate below draws a conclusion, so every one of them reads the weighted rows only (backlog #39). The
    # verdict is not the only thing derived from the result set: a demoted below-minimum retransmission row would
    # otherwise leave the overall result Healthy while the key stayed quality and this section said "Connected, but
    # quality is poor" about the same run, and a demoted input notice would set the other-problem predicate, which
    # suppresses the quality key in turn. What describes the page follows the rows on the page - Get-SummaryCounts
    # and Get-ReportNoticeFlags read every row, so a weightless row keeps its badge and its explanation.
    $allResults = @($script:Results)
    $results = @($allResults | Where-Object { -not $_.Weightless })
    $overall = Get-OverallStatus

    $adaptersFail = @($results | Where-Object { $_.Tag -eq "adapters" -and $_.Status -eq "FAIL" }).Count -gt 0
    $gatewayConfigFail = @($results | Where-Object { $_.Tag -eq "gateway-config" -and $_.Status -eq "FAIL" }).Count -gt 0
    $gatewayPingPass = @($results | Where-Object { $_.Tag -eq "ping-gateway" -and $_.Status -eq "PASS" }).Count -gt 0
    # A gateway row that failed on its latency answered every probe it is judged on (backlog #67): that is a quality
    # finding on a gateway that is reachable, not a gateway that does not answer, so it takes the quality lane below
    # like any other slow target - and where something else failed as well, the mixed one. Only a row whose loss
    # decided it - replies that did not come back - can select the gateway-unreachable key.
    $gatewayLostRows = @($results | Where-Object { $_.Tag -eq "ping-gateway" -and $_.Status -eq "FAIL" -and [string]$_.Rule -ne "latency" })
    $gatewayPingBad = @($gatewayLostRows).Count -gt 0
    # The near-end rung (backlog #60) does not select a key of its own: it says which side of the gateway a failure
    # is on, which is what the gateway-unreachable summary reads it for below - and only for gateway rows whose probes
    # the route table sent through the same adapter (PR #51, round 4): on a multihomed machine a near-end host reached
    # through adapter A says nothing about the cable, radio or switch behind adapter B. Path is the interface the
    # row's two lookups agreed on; a near-end row carries one whenever it carries the tag, and a failed gateway row
    # without one, or with another, keeps the neutral line.
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
        "local" { $title = "Local link problem"; $lines = @("No working network adapter or no default gateway was found.", "The fault is on this computer or its link: cable, Wi-Fi association, adapter disabled, or DHCP not answering.", "Try another device on the same network to see whether only this computer is affected.") }
        "gateway-unreachable" {
            $title = "Gateway does not answer"
            # The second line is chosen from what the near-end rung measured (backlog #60): a near-end host that
            # answered clears the local path and leaves the gateway itself; one that did not answer either puts the
            # fault on the local path before it; without one, or with one that neither passed nor lost its replies,
            # the line names the whole stretch as it always did.
            $pathLine = "The fault is between this computer and the router: link, Wi-Fi, switch, or the router itself."
            if ($nearEndPass) { $pathLine = "A host on this computer's own network answered its pings normally (the near-end row), so the local path - adapter, cable or Wi-Fi, switch or access point - carried traffic during this run; what did not answer is the gateway itself." }
            # "Lost its replies" and not "did not answer" (PR #51, round 2): a required near-end row fails on its loss
            # band with some replies back as well as with none, and the line must not say the host was silent.
            elseif ($nearEndLost) { $pathLine = "The near-end host on this computer's own network lost its replies too - all of them, or too many - which points at the local path before the gateway: link, Wi-Fi, switch or access point. The host itself is the other possibility, so check it as well." }
            $lines = @("The default gateway is configured but did not answer the pings sent to it, or lost too many of them.", $pathLine, "Check the link light or Wi-Fi signal and whether other devices reach the router.", "A gateway that fails this check - not answering pings sent to itself - is a suspect, not a conviction: it may be forwarding traffic normally while dropping or rate-limiting those pings. A connection that succeeded proves that only if its route ran through this gateway - a same-subnet host, a VPN or a proxy can succeed without touching it - so check the link to it first and treat the gateway as unproven rather than broken.")
        }
        "gateway-up-internet-dead" { $title = "Gateway answers, internet does not"; $lines = @("The router answers, but connections beyond it fail.", "The fault is at or beyond the router: WAN link, ISP, or an upstream firewall.", "Check the router's WAN status and whether other devices lose the internet too.") }
        "dns" { $title = "Name resolution fails"; $lines = @("Direct connections by IP address work, but host names do not resolve.", "The fault is DNS: the configured DNS servers, a filtering service, or the name itself.", "Compare the DNS servers in this report with the expected company settings.") }
        "quality" { $title = "Connected, but quality is poor"; $lines = @("Connectivity works, but packet loss, latency, retransmissions, or adapter errors were above the thresholds.", "Typical causes: weak Wi-Fi, a congested link, or a faulty cable or port.", "Run the tool again while the problem is occurring and compare the numbers.") }
        "mixed" { $title = "A required check failed"; $lines = @("At least one required check failed; see the failed rows below.", "Send the report to IT as it is.") }
        "incomplete" { $title = "Some checks could not run"; $lines = @("No failure was found, but some steps could not be completed on this computer.", "Send the report to IT as it is; the reasons are recorded in the details.") }
        "attention" { $title = "Warnings to review"; $lines = @("No required check failed, but some checks raised warnings; see the highlighted rows.", "Send the report to IT as it is.") }
        default {
            $title = "Everything passed"
            # "All checks passed" was said whatever the Information rows held, so a run in which an optional target
            # failed outright - an INFO row by design - read as if nothing had failed, a few lines above the row
            # that did (backlog #35). The claim is now the one the verdict actually makes, and the targets that did
            # not answer are named where the reader is looking.
            $quietOptional = @($results | Where-Object { [string]$_.Scope -ne "IT" -and $_.Status -eq "INFO" -and (@("ping-target", "ping-near-end", "tcp", "http") -contains [string]$_.Tag) })
            if ($quietOptional.Count -gt 0) {
                $quietNames = @(@($quietOptional | ForEach-Object { [string]$_.Check }) | Select-Object -Unique)
                $lines = @("All required checks passed during this run.", ("These optional targets did not answer, which does not change the result: {0}." -f ($quietNames -join ", ")), "If the problem persists, it is likely on the application or server side, or it comes and goes; run the tool again while it is happening.")
            }
            else {
                $lines = @("All checks passed during this run.", "If the problem persists, it is likely on the application or server side, or it comes and goes; run the tool again while it is happening.")
            }
        }
    }
    # One file, not a choice between two: the window names the same file by its path, and this line names the
    # one in the reader's hand (backlog #46).
    # The summary names what could not be taken and what was dropped, and says plainly that neither changed the
    # result (backlog #39). The exclusion alone would leave a person reading a healthy verdict beside rows carrying
    # error badges with nothing to connect them; this line is what connects them, and it is additional to the
    # exclusion rather than a substitute for it.
    $weightless = @($allResults | Where-Object { [string]$_.Scope -ne "IT" -and $_.Weightless -and [string]$_.Tag -ne "startup" })
    if ($weightless.Count -gt 0) {
        # The startup notice is left out of the list because the row in the target's own section names the target
        # itself, where this one would contribute only the words "Startup Notice"; the notice keeps its own row.
        $weightlessNames = @(@($weightless | ForEach-Object { [string]$_.Check }) | Select-Object -Unique)
        $lines += ("These were not measured or could not be used as given, and none of them changes the result: {0}." -f ($weightlessNames -join ", "))
    }
    $lines += "Send this file to IT as it is. It contains the computer name, user name, adapter MAC addresses and the Wi-Fi network name."

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

    # Each half of the notice only when the run produced the thing it explains (backlog #40).
    $noticeFlags = Get-ReportNoticeFlags
    $noticeSentences = @()
    if ($noticeFlags.Unable) { $noticeSentences += '"Unable to Check" means the step could not be completed because of permissions, missing system components, company policy, or an execution error. It does not necessarily mean the network is faulty.' }
    if ($noticeFlags.Rate) { $noticeSentences += "The TCP retransmission rate is an approximate system-wide value for this sampling period." }
    $noticeHtml = ""
    if ($noticeSentences.Count -gt 0) { $noticeHtml = '    <div class="notice">' + ($noticeSentences -join " ") + '</div>' }
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
$noticeHtml
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

    # The same two halves as the HTML notice, each on the same condition (backlog #40).
    $noticeFlags = Get-ReportNoticeFlags
    $noticeSentences = @()
    if ($noticeFlags.Unable) { $noticeSentences += "'Unable to Check' means the step was not completed; it does not necessarily mean the network is faulty." }
    if ($noticeFlags.Rate) { $noticeSentences += "TCP retransmissions are approximate system-wide statistics for this sampling period." }
    if ($noticeSentences.Count -gt 0) { [void]$builder.AppendLine("Note: " + ($noticeSentences -join " ")) }
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
            $script:ReportPathLabel.Text = Get-SendToItLine $primary
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
    # Cleared with the results, not at process start: the window is reused, so a rate computed by one run would
    # otherwise still be explained in the report of a later Run Again whose counters failed (PR #35, round 1).
    $script:RetransmissionRateComputed = $false
    $script:TcpConnectSampleCount = 0
    # The same reason (backlog #51): a ping sample one run put aside must never be finished in a later run's report.
    $script:PendingPingSamples = New-Object System.Collections.ArrayList
    # And the access-point samples (backlog #61's other half): a run compares the samples it took itself.
    $script:WifiAssociationSamples = New-Object System.Collections.ArrayList
    $script:GatewayNeighborRows = New-Object System.Collections.ArrayList
    # And the reads inside the TCP window (backlog #65): one run's state, never a later run's.
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

    # Two families under one tag, and only the second is a fact about this run's input (backlog #39). The environment
    # notices keep their weight: the report directory was not writable and a fallback was used, the graphical
    # interface could not start, and the one that decides it - this copy is running from inside a compressed folder,
    # where a report is written somewhere it will not survive. Demoting the tag as a whole would let a run say Overall
    # Healthy while the file it tells the person to send is being written into a folder that disappears. The input
    # notices are marked here, where they are added, rather than given a tag of their own, so that every tag a
    # document names goes on meaning what it meant - and they may only be demoted because Add-DroppedTargetResults
    # now leaves a row where each dropped target's result belonged.
    foreach ($startupMessage in @($script:StartupMessages)) {
        Add-CheckResult -Category "Program Environment" -Check "Startup Notice" -Status "WARN" -Message $startupMessage -Details "" -Tag "startup" | Out-Null
    }
    foreach ($startupMessage in @($script:RunOptionMessages)) {
        Add-CheckResult -Category "Program Environment" -Check "Startup Notice" -Status "WARN" -Message $startupMessage -Details "" -Tag "startup" -Weightless | Out-Null
    }

    # Beside the notice it belongs to, and before anything can return: a run that ends at the unsupported
    # operating system or PowerShell branch below still writes a report, and until PR #41 round 12 that report
    # carried the notice about the dropped target with no row where its result belonged - which is the one
    # thing this release promises not to do. It was also inside the connectivity step's action, so a throw
    # inside that step took the row with it. Nothing here depends on the run: the targets were dropped while
    # the options were read, which is also why this row belongs at this point in the table.
    Add-DroppedTargetResults

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
        Add-CheckResult -Category "Program Environment" -Check "PowerShell Version" -Status "PASS" -Message ("Current version: {0}" -f $PSVersionTable.PSVersion) -Details ("Language mode: {0}. A restricted mode (application control: WDAC / AppLocker) stops this tool before any check runs; it then writes an environment report instead." -f $ExecutionContext.SessionState.LanguageMode) -Tag "environment" | Out-Null
    }

    Invoke-CheckStep -Category "System Information" -Name "Get Computer and Operating System Information" -Progress 7 -Action {
        $summary = Get-SystemSummary
        Add-CheckResult -Category "System Information" -Check "Computer" -Status "INFO" -Message ("{0}, user {1}." -f $summary.ComputerName, $summary.UserName) -Details ("Operating system: {0} ({1})`r`nPowerShell: {2}" -f $summary.OperatingSystem, $summary.OperatingVersion, $summary.PowerShellVersion) -Tag "system" | Out-Null
    } | Out-Null

    # The access point is sampled first (backlog #61's other half): one netsh read, about 0.1 s, before the first
    # measurement, so that the run's whole window lies between this sample and the one taken after the last measurement;
    # the radio row's own read at the IT diagnostics is the middle sample. The samples share the radio row's switch
    # (Checks.WifiRf), because they are the same reader: off, and no sample is taken and no association row written.
    $wifiAssociationEnabled = Test-IsTrueFlag $script:Config.Checks.WifiRf
    if ($wifiAssociationEnabled) {
        Invoke-CheckStep -Category "IT Diagnostics" -Name "Sample the Wi-Fi Access Point (start)" -Progress 8 -Scope "IT" -Action {
            Add-WifiAssociationSample -Moment "start"
        } | Out-Null
    }
    # The wireless retry counters are read before the TCP baseline, so that compiling their reader - about 0.7 s on the
    # reference machine, once per process - is paid outside the retransmission window; they are read again after the TCP
    # window has closed, and been extended where it was, so the two windows cover the same run. Off by configuration
    # (Checks.WifiRetryCounters), nothing is read and no row is written, like the IT diagnostics.
    $wifiRetryEnabled = Test-IsTrueFlag $script:Config.Checks.WifiRetryCounters
    $wifiRetryBaseline = $null
    if ($wifiRetryEnabled) {
        $wifiRetryBaseline = Invoke-CheckStep -Category "Wi-Fi Retransmissions" -Name "Get Wi-Fi Retry Baseline" -Progress 9 -Weightless -Action {
            return (Get-WifiRetrySnapshot)
        }
    }
    $tcpBaseline = Invoke-CheckStep -Category "TCP Retransmissions" -Name "Get TCP Retransmission Baseline" -Progress 10 -Weightless -Action {
        # -WarmUp on the baseline only: the throwaway read that pays whatever the counter provider charges for a
        # first query outside the sample window, where it cannot lengthen what the window reports (backlog #38).
        # The snapshot is returned whatever it holds, including a baseline where both classes failed (PR #40, round
        # 5). Throwing there sent Invoke-CheckStep's generic step-error row instead, and the snapshot - four
        # attempts, their seconds and any pre-window failures - was discarded with it, leaving the analysis to write
        # "complete before-and-after data is unavailable" and nothing about the reads. Compare-TcpCounters writes one
        # row per read that failed out of this object, which says the same thing with the evidence attached.
        return (Get-TcpCounterSnapshot -WarmUp)
    }
    $minimumSampleSeconds = [math]::Max(1, (ConvertTo-IntSafe $script:Config.Tests.RetransmissionSampleSeconds 8))
    $tcpSampleStart = Get-Date
    # The reads inside the window open at the baseline stamp and close before the ending read (backlog #65).
    Start-TcpIntervalSampling -IntervalSeconds (Get-TcpIntervalSeconds) -Since $tcpSampleStart -Deadline $tcpSampleStart.AddSeconds($minimumSampleSeconds)

    $adapterStatsBefore = Invoke-CheckStep -Category "Network Adapter Error Counters" -Name "Get Network Adapter Error Baseline" -Progress 13 -Weightless -Action {
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

    # The position is the point (backlog #51): the ping samples that were put aside are finished here, before the
    # retransmission window sleeps out the seconds it still owes, so what the spread probes spend is time the run
    # was going to spend anyway. Anywhere else in the run and they would make it longer.
    # Only where something was put aside: Invoke-CheckStep writes a "Starting: ..." line and moves the progress
    # bar on every run, and most runs put nothing aside. A line about work that did not happen is the kind of thing
    # this project spends effort removing elsewhere.
    if (@($script:PendingPingSamples).Count -gt 0) {
        Invoke-CheckStep -Category "Latency and Packet Loss" -Name "Finish the ping samples that were not conclusive" -Progress 78 -Action {
            Complete-PingSamples -SampleStart $tcpSampleStart -MinimumSeconds $minimumSampleSeconds
        } | Out-Null
    }
    Wait-ForMinimumTcpSample -StartTime $tcpSampleStart -MinimumSeconds $minimumSampleSeconds
    # PR #56, round 3: the reads inside the window close at the wait's deadline. Two steps run between the wait and
    # the ending read - the adapter counters' ending values and their analysis - and a read due after the wait would
    # have run after them, past the minimum, adding its whole cost to the run; the ending read closes the window.
    Stop-TcpIntervalSampling

    $adapterStatsAfter = Invoke-CheckStep -Category "Network Adapter Error Counters" -Name "Get Ending Network Adapter Error Values" -Progress 82 -Weightless -Action {
        return (Get-AdapterStatisticsSnapshot)
    }

    Invoke-CheckStep -Category "Network Adapter Error Counters" -Name "Analyze Adapter Errors and Discards" -Progress 85 -Action {
        if ($null -eq $adapterStatsBefore -or $null -eq $adapterStatsAfter) {
            Add-CheckResult -Category "Network Adapter Error Counters" -Check "Before/After Comparison" -Status "ERROR" -Message "The baseline or ending value is missing, so the error delta cannot be calculated." -Details "" -Tag "adapter-errors" -Weightless | Out-Null
        }
        else {
            Compare-AdapterStatistics -Before $adapterStatsBefore -After $adapterStatsAfter -Adapters $networkSnapshot
        }
    } | Out-Null

    $tcpAfter = Invoke-CheckStep -Category "TCP Retransmissions" -Name "Get Ending TCP Retransmission Values" -Progress 89 -Weightless -Action {
        Stop-TcpIntervalSampling
        return (Get-TcpCounterSnapshot)
    }

    # Extended once, and only in the ambiguous case (backlog #51): a sample below the rating floor with a
    # retransmission in it. The step itself is weightless - it is a decision about sampling rather than a
    # measurement, and the measurement is still written by the step below. The merge is per protocol, so a second
    # read that fails can never cost a reading the first one already had.
    if (Test-TcpSampleNeedsExtension -Before $tcpBaseline -After $tcpAfter) {
        $tcpExtended = Invoke-CheckStep -Category "TCP Retransmissions" -Name "Extend the TCP Sample Where It Was Too Small to Rate" -Progress 90 -Weightless -Action {
            Start-TcpIntervalSampling -IntervalSeconds (Get-TcpIntervalSeconds) -Since (Get-Date) -Extension -Boundary $tcpAfter -Deadline (Get-Date).AddSeconds($minimumSampleSeconds)
            Wait-ForMinimumTcpSample -StartTime (Get-Date) -MinimumSeconds $minimumSampleSeconds -ProgressPercent 90
            Stop-TcpIntervalSampling
            return (Merge-TcpEndingSnapshot -Original $tcpAfter -Extended (Get-TcpCounterSnapshot))
        }
        if ($null -ne $tcpExtended) { $tcpAfter = $tcpExtended }
    }

    # The ending value after the TCP window, extended or not, so that the two windows end together; the analysis after
    # the TCP analysis, in the order the report prints them.
    $wifiRetryAfter = $null
    if ($wifiRetryEnabled) {
        $wifiRetryAfter = Invoke-CheckStep -Category "Wi-Fi Retransmissions" -Name "Get Ending Wi-Fi Retry Values" -Progress 91 -Weightless -Action {
            return (Get-WifiRetrySnapshot)
        }
    }
    # The last access-point sample, after the TCP window like the retry counters' ending value, so that every measurement
    # of the run lies between the first sample and this one (backlog #61's other half).
    if ($wifiAssociationEnabled) {
        Invoke-CheckStep -Category "IT Diagnostics" -Name "Sample the Wi-Fi Access Point (end)" -Progress 91 -Scope "IT" -Action {
            Add-WifiAssociationSample -Moment "end"
        } | Out-Null
    }
    Invoke-CheckStep -Category "TCP Retransmissions" -Name "Analyze TCP Retransmissions" -Progress 92 -Action {
        Compare-TcpCounters -Before $tcpBaseline -After $tcpAfter
    } | Out-Null
    if ($wifiRetryEnabled) {
        Invoke-CheckStep -Category "Wi-Fi Retransmissions" -Name "Analyze Wi-Fi Retries" -Progress 93 -Action {
            Compare-WifiRetryCounters -Before $wifiRetryBaseline -After $wifiRetryAfter
        } | Out-Null
    }
    if ($wifiAssociationEnabled) {
        Invoke-CheckStep -Category "IT Diagnostics" -Name "Compare the Wi-Fi Access Point Across the Samples" -Progress 94 -Scope "IT" -Action {
            Compare-WifiAssociation -Samples @($script:WifiAssociationSamples)
            Update-AccessPointGatewayHints -Samples @($script:WifiAssociationSamples)
        } | Out-Null
    }

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
        # The same sentence the window shows, about the same file: HTML unless it could not be written.
        $sendLine = Get-SendToItLine ([string]@(@($report.Html, $report.Text, $report.Json) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })[0])
        if (-not [string]::IsNullOrWhiteSpace($sendLine)) { Write-Host $sendLine }
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

# Backlog #34: a run that fell back to console mode because the window could not open ends inside the black window
# the launcher opened, and the user and IT launchers close that window on exit code 0 - right for a window run, where
# the person has already closed the tool, and wrong for the fallback, where the three report paths are the last thing
# printed. The script waits here for a key when, and only when, the run was a fallback: not started with -ConsoleOnly
# (the console launcher pauses by itself, and the chain's console runs must not wait), with a person at the console
# (a scheduled task or a service has none), and with the standard input not redirected (a harness feeding NUL must
# never block). Each gate is a parameter whose default is the live value, so that the decision can be tested without
# a console; ReadKey itself is guarded, because a host without a keyboard throws. Returns whether it waited. The
# call site adds a fourth gate: only after a fallback run that ended with 0 - on any other code the launcher itself
# pauses under its own error, and a second prompt claiming report paths to read would be wrong twice over.
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
        Write-Host "The window stays open so that the report paths above can be read. Press any key to close it."
        [void][Console]::ReadKey($true)
        return $true
    }
    catch {
        return $false
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

    $controls["PingTarget"].Text = (@($options.RawTargets.Ping) -join ", ")
    $controls["DnsName"].Text = (@($options.RawTargets.Dns) -join ", ")
    $controls["TcpTarget"].Text = (@($options.RawTargets.Tcp) -join ", ")
    $controls["HttpUrl"].Text = (@($options.RawTargets.Http) -join " ")
    # A configured value above the spinner's default range (120 s for the sample) widens the range instead of
    # being clamped, so an untouched Start runs with the configured value (v1.2.1).
    # The two ping spinners' range IS the configured ceiling (backlog #51). It opened at 20 until 1.2.9 - a number
    # with no reason anywhere in this repository or the package - and the widening stays; what it widens from is
    # now a value that means something.
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

# The panel's four free-text fields against the rules the run itself uses, before the run starts. Only the extra
# TCP target has a syntax rule; the other three are read and left alone. What a rejected value costs if it is not
# caught here was measured twice: a fifteen-second run, a report carrying a warning, a verdict of Attention
# Required on a network where every check passed, and a summary telling the person to send that report to IT.
function Get-RejectedPanelValues {
    $rejected = New-Object System.Collections.ArrayList
    $controls = $script:OptionsPanel
    if ($null -eq $controls) { return @() }
    foreach ($item in @(([string]$controls["TcpTarget"].Text) -split '[,;\s]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        if (-not (Test-TcpTargetSyntax $item)) {
            [void]$rejected.Add([pscustomobject][ordered]@{ Key = "TcpTarget"; Value = [string]$item; Problem = "Extra TCP: '" + $item + "' is not host:port with a host that can be used - for example 8.8.8.8:443." + $(if (([string]$item).Split(":").Count -eq 2 -and -not (Test-HostNameSyntax (([string]$item).Split(":")[0]))) { " The host: " + (Get-HostNameSyntaxProblem (([string]$item).Split(":")[0])) + "." } else { "" }) })
        }
    }
    return @($rejected)
}

# Nothing blocks and nothing is refused: the field is marked, the problem is named with an example of the value
# the field wants, and the person is told the second choice this tool always offers - press Start again and the
# run goes ahead without that target, exactly as it did before this check existed, Startup Notice and all.
function Show-PanelRejection {
    param([object[]]$Rejected)
    $controls = $script:OptionsPanel
    foreach ($item in @($Rejected)) {
        $control = $controls[[string]$item.Key]
        if ($null -ne $control) { $control.BackColor = [System.Drawing.Color]::MistyRose }
    }
    $text = ((@($Rejected | ForEach-Object { [string]$_.Problem }) -join " ") + " " + 'Correct it, or press Start Test again to run without it.')
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
    # The IT panel is a fixed grid 880 px wide, and the window may not be made narrower than the grid it carries:
    # the panel is anchored left and right, so shrinking the form slid the third column off its edge, where no
    # amount of scrolling reaches it (PR #35, round 1). The user window carries no panel and keeps its old minimum.
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
        # One width for six labels is what clipped the longest of them: "Extra TCP (host:port)" needs 136 px in
        # the 100 the loop used to give it, and the zh-TW label 147, so both wrapped into a 22 px box and lost
        # their second line - the format was in the source and not on the screen (backlog #49). Each label now
        # carries the width its own text needs, and the two columns beside it move right to make room; the panel
        # is 880 wide and the last control ends at 875. The gui-headless step measures every control against its
        # box in both languages, so a translation that outgrows one fails the chain instead of a walk.
        foreach ($item in @(
            @{ Text = "Extra ping"; X = 12; Y = 26; W = 150 },
            @{ Text = "Extra DNS"; X = 375; Y = 26; W = 100 },
            @{ Text = "Ping count"; X = 690; Y = 26; W = 110 },
            @{ Text = "Extra TCP (host:port)"; X = 12; Y = 58; W = 150 },
            @{ Text = "Extra URL"; X = 375; Y = 58; W = 100 },
            @{ Text = "Ping ceiling"; X = 690; Y = 58; W = 110 },
            @{ Text = "Sample seconds"; X = 690; Y = 92; W = 110 }
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
        # The format lives in the control the person is typing into, as an example value rather than a notation:
        # host:port is a developer's shorthand for a shape, 8.8.8.8:443 is the thing they are about to type.
        $hints = New-Object System.Windows.Forms.ToolTip
        $script:PanelHints = $hints
        $hints.SetToolTip($controls["PingTarget"], "For example 1.1.1.1")
        $hints.SetToolTip($controls["DnsName"], "For example www.example.com")
        $hints.SetToolTip($controls["TcpTarget"], "For example 8.8.8.8:443 - a host or address, a colon, then the port")
        $hints.SetToolTip($controls["HttpUrl"], "For example https://www.example.com/")
        foreach ($key in @("PingTarget", "DnsName", "TcpTarget", "HttpUrl")) {
            $controls[$key].Add_TextChanged({ $script:PanelWarned = $false; $this.BackColor = [System.Drawing.SystemColors]::Window })
        }
        # Three spinners in one column. The two ping ranges come from the configured ceiling rather than from a
        # number of this panel's own (backlog #51); Set-OptionsPanelValues sets them again from the run options
        # whenever the panel is reset.
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
        # After the loop that creates them, not with the text fields above: a tooltip set on a control that does
        # not exist yet throws, which is how the headless GUI step found this one in both languages.
        $hints.SetToolTip($controls["PingCount"], "How many ICMP echo requests each ping target is sent to begin with")
        $hints.SetToolTip($controls["PingCountMaximum"], "The furthest this run will go for one ping target when replies are lost")
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
    # New-Object argument lists are parsed in expression mode, where the comma binds tighter than "+": keep arithmetic in its own parentheses (v1.2.1).
    $overall.Location = New-Object System.Drawing.Point(22, (84 + $offset))
    $overall.Size = New-Object System.Drawing.Size(880, 28)
    $overall.Anchor = "Top,Left,Right"
    $form.Controls.Add($overall)

    $progressLabel = New-Object System.Windows.Forms.Label
    $progressLabel.Text = "Ready"
    if ($script:Interactive) { $progressLabel.Text = "Ready - adjust the options, then select Start Test" }
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
    $startButton.Text = "Start Test"
    $startButton.Location = New-Object System.Drawing.Point(22, $bottomY)
    $startButton.Size = New-Object System.Drawing.Size(120, 34)
    $startButton.Anchor = "Bottom,Left"
    $form.Controls.Add($startButton)

    $openReportButton = New-Object System.Windows.Forms.Button
    $openReportButton.Text = "Open Report"
    $openReportButton.Location = New-Object System.Drawing.Point(152, $bottomY)
    $openReportButton.Size = New-Object System.Drawing.Size(120, 34)
    $openReportButton.Anchor = "Bottom,Left"
    $openReportButton.Enabled = $false
    $form.Controls.Add($openReportButton)

    $openFolderButton = New-Object System.Windows.Forms.Button
    $openFolderButton.Text = "Open Report Folder"
    $openFolderButton.Location = New-Object System.Drawing.Point(282, $bottomY)
    $openFolderButton.Size = New-Object System.Drawing.Size(150, 34)
    $openFolderButton.Anchor = "Bottom,Left"
    $openFolderButton.Enabled = $false
    $form.Controls.Add($openFolderButton)

    $openJsonButton = New-Object System.Windows.Forms.Button
    $openJsonButton.Text = "Open JSON"
    $openJsonButton.Location = New-Object System.Drawing.Point(442, $bottomY)
    $openJsonButton.Size = New-Object System.Drawing.Size(110, 34)
    $openJsonButton.Anchor = "Bottom,Left"
    $openJsonButton.Enabled = $false
    $form.Controls.Add($openJsonButton)

    $closeButton = New-Object System.Windows.Forms.Button
    $closeButton.Text = "Close"
    $closeButton.Location = New-Object System.Drawing.Point(782, $bottomY)
    $closeButton.Size = New-Object System.Drawing.Size(120, 34)
    $closeButton.Anchor = "Bottom,Right"
    $form.Controls.Add($closeButton)

    $reportPathLabel = New-Object System.Windows.Forms.Label
    $reportPathLabel.Text = "Report has not been generated"
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
                # Every value the panel can reject is checked before the run rather than after it (backlog #45).
                # Nothing blocks: the first press names the problem and marks the field, and a second press runs
                # without that target - which is what the run did before this check existed.
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
    $script:BaseConfig = Load-Configuration -RequestedPath $ConfigPath
    if (Test-IsRunningFromArchive $script:BaseDirectory) {
        [void]$script:StartupMessages.Add("This copy is running from inside a compressed folder. Extract the ZIP to a real folder first, or the reports will be written to a temporary location that disappears.")
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
