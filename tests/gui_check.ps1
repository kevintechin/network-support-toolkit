param(
    [string]$PackageDir,
    [ValidateSet("User", "IT")][string]$Entry = "IT",
    [ValidateSet("Launcher", "Direct")][string]$Via = "Launcher",
    [string]$LauncherPath,
    [int]$TimeoutSeconds = 300
)
# End-to-end check through the real WinForms window (UI Automation), the way a person would use the package:
#   -Via Launcher (default): the double-click path - cmd.exe runs the shipped Start-NetworkCheck.cmd (User) or
#                            Start-NetworkCheck-IT.cmd (IT) from the package folder, or the launcher given as
#                            -LauncherPath (the package root's Start-English.cmd / Start-Traditional-Chinese.cmd, which
#                            call the language folder's user launcher); the window belongs to the PowerShell process the
#                            launcher starts, and the launcher's effective command line is printed.
#   -Via Direct:             powershell.exe -STA -File NetworkHealthCheck.ps1 [-Interactive -ExpandDetails], for debugging.
#   User entry: the run must start by itself - Start disabled or the window changing within 10 s, nobody clicking.
#   IT entry:   the window must be idle first - Start enabled, no report since launch, nothing in the window changing over
#               a 3-second hold - then Start is clicked with the panel untouched and the click must take effect (Start
#               disabled or the window changing within 10 s).
# Then wait for the JSON report, print the run options it recorded, close the window with its Close button, and exit
# nonzero if anything above failed, if the launched process (or the launcher) did not exit 0, or if the launcher wrote
# LauncherError.txt. WinForms controls surface as generic panes through UI Automation here, but their names, enabled
# state and window classes are exact; the spinner values show up as the names of their inner edit controls.
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type @"
using System; using System.Runtime.InteropServices;
public static class Win32Msg {
    [DllImport("user32.dll", SetLastError = true)] public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
}
"@
$AE = [System.Windows.Automation.AutomationElement]
$scope = [System.Windows.Automation.TreeScope]
$lang = Split-Path -Leaf $PackageDir
$startNames = @{ "en-US" = "Start Test"; "zh-TW" = ([string][char]0x958B + [char]0x59CB + [char]0x6AA2 + [char]0x6E2C) }   # 開始檢測
$closeNames = @{ "en-US" = "Close"; "zh-TW" = ([string][char]0x95DC + [char]0x9589) }                                      # 關閉
if (-not $startNames.ContainsKey($lang)) { "[$lang] ERROR: the package folder must be named en-US or zh-TW"; exit 1 }
$tag = "[$lang $Entry]"
$ps = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
$cmd = Join-Path $env:SystemRoot "System32\cmd.exe"
$script = Join-Path $PackageDir "NetworkHealthCheck.ps1"
$reports = Join-Path $PackageDir "Reports"
$launcherError = Join-Path $PackageDir "LauncherError.txt"
if (Test-Path -LiteralPath $launcherError) { Remove-Item -LiteralPath $launcherError -Force }

function Get-NewReport([datetime]$Since) {
    Get-ChildItem -LiteralPath $reports -Filter "*.json" -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt $Since } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
}
function Get-WindowSnapshot($Window) {
    # Every descendant as class|name|enabled; an unchanged snapshot means nothing in the window moved.
    @($Window.FindAll($scope::Descendants, [System.Windows.Automation.Condition]::TrueCondition) | ForEach-Object { $_.Current.ClassName + "|" + $_.Current.Name + "|" + $_.Current.IsEnabled }) -join "`n"
}
function Find-ByName($Window, [string]$Name) {
    $Window.FindFirst($scope::Descendants, (New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, $Name)))
}
function Send-Click($Element) {
    [void][Win32Msg]::PostMessage([IntPtr]$Element.Current.NativeWindowHandle, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero)   # BM_CLICK
}
function Get-ChildProcesses([int]$ParentId) {
    # Win32_Process through CIM when it exists and WMI otherwise - the same selection the script makes for its own
    # CIM / WMI queries, so the driver works wherever the script does.
    $filter = "ParentProcessId = $ParentId"
    if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) { return @(Get-CimInstance -ClassName Win32_Process -Filter $filter -ErrorAction Stop) }
    if (Get-Command Get-WmiObject -ErrorAction SilentlyContinue) { return @(Get-WmiObject -Class Win32_Process -Filter $filter -ErrorAction Stop) }
    throw "Neither Get-CimInstance nor Get-WmiObject is available to find the launched process."
}
function Get-PowerShellDescendant([int]$ParentId) {
    # The PowerShell process under the launcher: a direct child of cmd.exe (the language launchers, and the root
    # launchers, which `call` them in the same cmd.exe), or a grandchild should a launcher ever spawn a nested cmd.exe.
    $children = @(Get-ChildProcesses $ParentId)
    $hit = @($children | Where-Object { $_.Name -match '^(powershell|pwsh)\.exe$' })[0]
    if ($null -ne $hit) { return $hit }
    foreach ($c in $children) {
        $hit = @(Get-ChildProcesses ([int]$c.ProcessId) | Where-Object { $_.Name -match '^(powershell|pwsh)\.exe$' })[0]
        if ($null -ne $hit) { return $hit }
    }
    return $null
}

$launchedAt = Get-Date
if ($Via -eq "Launcher") {
    $launcher = $LauncherPath
    if (-not $launcher) { $launcher = Join-Path $PackageDir $(if ($Entry -eq "IT") { "Start-NetworkCheck-IT.cmd" } else { "Start-NetworkCheck.cmd" }) }
    if (-not (Test-Path -LiteralPath $launcher)) { "$tag ERROR: launcher not found: $launcher"; exit 1 }
    "$tag launcher: " + (Split-Path -Leaf $launcher)
    $proc = Start-Process -FilePath $cmd -ArgumentList @("/c", ('"' + $launcher + '"')) -WorkingDirectory (Split-Path -Parent $launcher) -PassThru
}
else {
    $psArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-STA", "-File", $script)
    if ($Entry -eq "IT") { $psArgs += @("-Interactive", "-ExpandDetails") }
    "$tag arguments: " + ($psArgs -join " ")
    $proc = Start-Process -FilePath $ps -ArgumentList $psArgs -PassThru
}
"$tag launched pid $($proc.Id) at " + $launchedAt.ToString("HH:mm:ss")
$guiPid = $proc.Id
try {
    if ($Via -eq "Launcher") {
        # The window belongs to the PowerShell process the launcher starts, not to cmd.exe.
        $child = $null; $deadline = (Get-Date).AddSeconds(30)
        while ($null -eq $child -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 500
            if ($proc.HasExited) { throw "the launcher exited early with code $($proc.ExitCode)" }
            $child = Get-PowerShellDescendant $proc.Id
        }
        if ($null -eq $child) { throw "the launcher started no PowerShell process within 30 s" }
        $guiPid = [int]$child.ProcessId
        "$tag launcher started $($child.Name) pid $guiPid with: " + ($child.CommandLine -replace '^"[^"]*"\s*', '')
    }
    $win = $null; $deadline = (Get-Date).AddSeconds(60)
    while ($null -eq $win -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        if ($proc.HasExited) { throw "process exited early with code $($proc.ExitCode) (GUI fallback to console mode?)" }
        $win = $AE::RootElement.FindFirst($scope::Children, (New-Object System.Windows.Automation.PropertyCondition($AE::ProcessIdProperty, $guiPid)))
    }
    if ($null -eq $win) { throw "main window not found within 60 s" }
    "$tag window: '$($win.Current.Name)' " + [int]$win.Current.BoundingRectangle.Width + "x" + [int]$win.Current.BoundingRectangle.Height
    Start-Sleep -Seconds 2
    $startButton = Find-ByName $win $startNames[$lang]
    if ($null -eq $startButton) { throw "Start button not found" }

    if ($Entry -eq "IT") {
        # What the panel shows: every edit control (text boxes and the spinners' inner edits) with its text, top to bottom.
        $fields = @()
        foreach ($e in $win.FindAll($scope::Descendants, [System.Windows.Automation.Condition]::TrueCondition)) {
            if ($e.Current.ClassName -notmatch 'EDIT') { continue }
            $fields += [pscustomobject]@{ Top = [int]$e.Current.BoundingRectangle.Top; Left = [int]$e.Current.BoundingRectangle.Left; Value = $e.Current.Name }
        }
        "$tag panel edit fields (top to bottom): " + (@($fields | Sort-Object Top, Left | ForEach-Object { "'" + $_.Value + "'" }) -join " ")
        # Idle check: the IT entry must not start by itself. Start enabled, no report since launch, and nothing in the
        # window changing over a 3-second hold; an auto-started run disables Start at once and moves the progress texts.
        if (-not $startButton.Current.IsEnabled) { throw "Start is disabled before it was clicked: the run started by itself" }
        if ($null -ne (Get-NewReport $launchedAt)) { throw "a report appeared before Start was clicked: the run started by itself" }
        $before = Get-WindowSnapshot $win
        Start-Sleep -Seconds 3
        $after = Get-WindowSnapshot $win
        if ($after -ne $before) { throw "the window changed during the 3-second idle hold: the run started by itself" }
        if (-not $startButton.Current.IsEnabled) { throw "Start became disabled during the idle hold: the run started by itself" }
        if ($null -ne (Get-NewReport $launchedAt)) { throw "a report appeared during the idle hold: the run started by itself" }
        "$tag idle for 3 s with Start enabled and no report: the IT entry did not start by itself"
        Send-Click $startButton
        "$tag clicked Start with the panel untouched at " + (Get-Date).ToString("HH:mm:ss")
        # The click must take effect: Run-AllChecks disables Start immediately and the progress texts move.
        $deadline = (Get-Date).AddSeconds(10); $started = $false
        while (-not $started -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 500
            $started = (-not $startButton.Current.IsEnabled) -or ((Get-WindowSnapshot $win) -ne $after)
        }
        if (-not $started) { throw "the Start click had no effect within 10 s (Start still enabled, window unchanged)" }
        "$tag the run started after the click"
    }
    else {
        # The user entry must start by itself: Start disabled or the window changing within 10 s, with nobody clicking.
        $snapshot = Get-WindowSnapshot $win
        $deadline = (Get-Date).AddSeconds(10); $started = $false
        while (-not $started -and (Get-Date) -lt $deadline) {
            $started = (-not $startButton.Current.IsEnabled) -or ((Get-WindowSnapshot $win) -ne $snapshot) -or ($null -ne (Get-NewReport $launchedAt))
            if (-not $started) { Start-Sleep -Milliseconds 500 }
        }
        if (-not $started) { throw "the user entry did not start by itself within 10 s" }
        "$tag the run started by itself (nothing was clicked)"
    }

    $json = $null; $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ($null -eq $json -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3
        $json = Get-NewReport $launchedAt
    }
    if ($null -eq $json) { throw "no JSON report within $TimeoutSeconds s" }
    Start-Sleep -Seconds 2
    $d = Get-Content -LiteralPath $json.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    "$tag report $($json.Name) at " + $json.LastWriteTime.ToString("HH:mm:ss") + ": ToolVersion=$($d.ToolVersion) EntryPoint=$($d.RunOptions.EntryPoint) ExpandDetails=$($d.RunOptions.ExpandDetails) PingCount=$($d.RunOptions.PingCount) SampleSeconds=$($d.RunOptions.SampleSeconds) TracerouteHops=$($d.RunOptions.TracerouteHops) Overall=$($d.Overall.Code) Fingerprint=$($d.Fingerprint.Key) Results=$(@($d.Results).Count)"
    $gw = @($d.Results | Where-Object { $_.Tag -eq 'ping-gateway' })
    if ($gw.Count -gt 0) { "$tag gateway ping row: " + $gw[0].Message }

    $close = Find-ByName $win $closeNames[$lang]
    if ($null -eq $close) { throw "Close button not found" }
    Send-Click $close
    if (-not $proc.WaitForExit(15000)) { throw "the window did not close within 15 s of the Close click" }
    "$tag closed via the Close button; process exit code $($proc.ExitCode)"
    if (Test-Path -LiteralPath $launcherError) { throw "the launcher wrote LauncherError.txt: " + ((Get-Content -LiteralPath $launcherError -Raw) -replace '\s+', ' ') }
    if ($proc.ExitCode -ne 0) { throw "the launched process exited with code $($proc.ExitCode)" }
    exit 0
}
catch {
    "$tag ERROR: " + $_.Exception.Message
    if (-not $proc.HasExited) { $proc.Kill(); "$tag process $($proc.Id) killed" }
    if ($guiPid -ne $proc.Id) {
        $gui = Get-Process -Id $guiPid -ErrorAction SilentlyContinue
        if ($null -ne $gui) { $gui.Kill(); "$tag GUI process $guiPid killed" }
    }
    exit 1
}
