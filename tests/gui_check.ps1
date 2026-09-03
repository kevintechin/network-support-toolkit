param([string]$PackageDir, [ValidateSet("User", "IT")][string]$Entry = "IT", [int]$TimeoutSeconds = 300)
# End-to-end check through the real WinForms window (UI Automation), the way a person would use the launchers:
#   User entry: NetworkHealthCheck.ps1 (no switches) - the run starts by itself when the window is shown.
#   IT entry:   NetworkHealthCheck.ps1 -Interactive -ExpandDetails - read the panel's numeric fields, click Start untouched.
# Then wait for the JSON report, print the run options it recorded, and close the window with its Close button.
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
$ps = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
$script = Join-Path $PackageDir "NetworkHealthCheck.ps1"
$reports = Join-Path $PackageDir "Reports"
$psArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $script)
if ($Entry -eq "IT") { $psArgs += @("-Interactive", "-ExpandDetails") }
"[$lang $Entry] arguments: " + ($psArgs -join " ")
$launchedAt = Get-Date
$proc = Start-Process -FilePath $ps -ArgumentList $psArgs -PassThru
"[$lang $Entry] launched pid $($proc.Id) at " + $launchedAt.ToString("HH:mm:ss")
try {
    $win = $null; $deadline = (Get-Date).AddSeconds(60)
    while ($null -eq $win -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        if ($proc.HasExited) { throw "process exited early with code $($proc.ExitCode) (GUI fallback to console mode?)" }
        $cond = New-Object System.Windows.Automation.PropertyCondition($AE::ProcessIdProperty, $proc.Id)
        $win = $AE::RootElement.FindFirst($scope::Children, $cond)
    }
    if ($null -eq $win) { throw "main window not found within 60 s" }
    "[$lang $Entry] window: '$($win.Current.Name)' " + [int]$win.Current.BoundingRectangle.Width + "x" + [int]$win.Current.BoundingRectangle.Height
    Start-Sleep -Seconds 2

    if ($Entry -eq "IT") {
        # What the panel shows: every Edit / Spinner descendant with its name, value and position (top to bottom).
        $fields = @()
        foreach ($e in $win.FindAll($scope::Descendants, [System.Windows.Automation.Condition]::TrueCondition)) {
            $t = $e.Current.ControlType.ProgrammaticName
            if ($t -notmatch 'Edit|Spinner') { continue }
            $v = ''
            try { $v = $e.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value } catch { $v = '(no ValuePattern)' }
            $fields += [pscustomobject]@{ Top = [int]$e.Current.BoundingRectangle.Top; Left = [int]$e.Current.BoundingRectangle.Left; Type = $t.Replace('ControlType.', ''); Name = $e.Current.Name; Value = $v }
        }
        foreach ($f in ($fields | Sort-Object Top, Left)) { "[$lang $Entry]   $($f.Type) name='$($f.Name)' value='$($f.Value)' at $($f.Left),$($f.Top)" }
        $btnCond = New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, $startNames[$lang])
        $btn = $win.FindFirst($scope::Descendants, $btnCond)
        if ($null -eq $btn) { throw "Start button not found" }
        [void][Win32Msg]::PostMessage([IntPtr]$btn.Current.NativeWindowHandle, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero)   # BM_CLICK
        "[$lang $Entry] clicked Start with the panel untouched at " + (Get-Date).ToString("HH:mm:ss")
    }

    $json = $null; $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ($null -eq $json -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3
        $json = Get-ChildItem -LiteralPath $reports -Filter "*.json" -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt $launchedAt } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    }
    if ($null -eq $json) { throw "no JSON report within $TimeoutSeconds s" }
    Start-Sleep -Seconds 2
    $d = Get-Content -LiteralPath $json.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    "[$lang $Entry] report $($json.Name) at " + $json.LastWriteTime.ToString("HH:mm:ss") + ": ToolVersion=$($d.ToolVersion) EntryPoint=$($d.RunOptions.EntryPoint) PingCount=$($d.RunOptions.PingCount) SampleSeconds=$($d.RunOptions.SampleSeconds) TracerouteHops=$($d.RunOptions.TracerouteHops) Overall=$($d.Overall.Code) Fingerprint=$($d.Fingerprint.Key) Results=$(@($d.Results).Count)"
    $gw = @($d.Results | Where-Object { $_.Tag -eq 'ping-gateway' })
    if ($gw.Count -gt 0) { "[$lang $Entry] gateway ping row: " + $gw[0].Message }

    $closeCond = New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, $closeNames[$lang])
    $close = $win.FindFirst($scope::Descendants, $closeCond)
    if ($null -ne $close) { [void][Win32Msg]::PostMessage([IntPtr]$close.Current.NativeWindowHandle, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero) }
    if (-not $proc.WaitForExit(15000)) { "[$lang $Entry] window did not close in 15 s; killing"; $proc.Kill() } else { "[$lang $Entry] closed via the Close button; process exit code $($proc.ExitCode)" }
    exit 0
}
catch {
    "[$lang $Entry] ERROR: " + $_.Exception.Message
    if (-not $proc.HasExited) { $proc.Kill(); "[$lang $Entry] process killed" }
    exit 1
}
