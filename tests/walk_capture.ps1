<#
.SYNOPSIS
    Captures the evidence the user-manual walk asks for (backlog #48), so that the person walks the questions a
    person has to answer.

.DESCRIPTION
    `user-manual-walk-checklist.md` has 75 rows, and 47 of them name something in their Evidence column: eleven a
    screenshot, the rest a report, a file, a folder listing or the text a window showed. A person produced all of it
    by hand during the 1.2.4 walk, and the answers went into a conversation rather than into the sheet's Observed
    column. Most of it is machinery this folder already has - `gui_check.ps1` drives the real window through UI
    Automation, `launcher_check.ps1` starts the launchers from staged copies - and none of it kept what the person
    would have seen.

    This script runs the tool the way the sheet's rows do, keeps what it saw, and writes one manifest binding each
    answer to its row. Every row it owns is answered either with an artefact or with `not produced` naming the
    precondition that was missing, because W40 needs a VPN, W42 a machine without PowerShell, W47 an archiver stock
    Windows does not have, and W48 to W50 failures the sheet forbids manufacturing. A row is answered either way and
    never silently absent.

    What it does not do, and must not be made to do: the six questions of the sheet's "Was it usable?" section. A
    screenshot judged afterwards by whoever wrote the sheet is a review of the manual and not a walk of it, and this
    project has the measurement that says the difference matters (VALIDATION.md, 2026-09-08). This script shortens the
    walk; it does not replace it.

    Evidence comes back by hand. The bundle is written to one folder on this machine and nothing else happens to it:
    nothing is uploaded, no share is mounted, no network path is configured. A person copies the folder off the
    machine. Because a folder made beside the walked package inherits that package's location - and the 1.2.4 walk ran
    from a OneDrive-backed Desktop - the script refuses to write a bundle into a synced folder rather than quietly
    fill one.

.PARAMETER PackageDir
    The language folder to walk: an `en-US` or `zh-TW` folder holding NetworkHealthCheck.ps1 and the launchers. For a
    real walk this is the extracted release asset, not the checkout.

.PARAMETER OutDir
    Where the bundle goes. Must not be inside a synced folder. Default: %USERPROFILE%\NHC-Walk\<yyyyMMdd_HHmmss>,
    which is outside OneDrive's known-folder redirection on a default Windows 11 (the Desktop and Documents are not).

.PARAMETER Zip
    The released ZIP the package was extracted from, for the rows that turn on Windows' own dialogs (W1, W5, W5b).
    Without it those rows are answered `not produced`, naming the ZIP as the missing precondition.

.PARAMETER Rows
    Capture only these rows (e.g. -Rows W7,W9,W12). Default: every row this script owns.

.PARAMETER TimeoutSeconds
    How long to wait for a run to write its JSON report. Default 300.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\walk_capture.ps1 -PackageDir C:\NHC\en-US -Zip C:\NHC\NetworkHealthCheck-1.2.5.zip

.NOTES
    Windows PowerShell 5.1, an interactive desktop session, and nothing else. A locked screen or a disconnected RDP
    session cannot be captured, and the script refuses to run rather than writing black images and reporting success.
#>
param(
    [Parameter(Mandatory = $true)][string]$PackageDir,
    [string]$OutDir,
    [string]$Zip,
    [string[]]$Rows,
    [int]$TimeoutSeconds = 300
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type @"
using System; using System.Runtime.InteropServices;
public static class WalkCaptureWin32 {
    [DllImport("user32.dll", SetLastError = true)] public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
    // WinForms controls reach UI Automation through the MSAA bridge, where an edit box often exposes no ValuePattern.
    // WM_SETTEXT on the control's own window is what is left, and it is what a person typing into it ends up doing.
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern IntPtr SendMessageW(IntPtr hWnd, uint Msg, IntPtr wParam, string lParam);
}
"@
$AE = [System.Windows.Automation.AutomationElement]
$SCOPE = [System.Windows.Automation.TreeScope]

# ---------------------------------------------------------------- the answers
$script:Answers = New-Object System.Collections.Generic.List[object]
$script:ReportArtefact = ''
$script:Failures = 0

function Add-Answer([string]$Row, [string]$Outcome, [string]$Artefact, [string]$Note) {
    # Outcome is 'captured' or 'not produced'. A row leaves this script with one of the two and nothing else.
    $script:Answers.Add([pscustomobject]@{ Row = $Row; Outcome = $Outcome; Artefact = $Artefact; Note = $Note })
    $mark = if ($Outcome -eq 'captured') { '[CAPTURED]' } else { '[NOT PRODUCED]' }
    Write-Output ("{0} {1} {2}{3}" -f $mark, $Row, $Artefact, $(if ($Note) { " - $Note" } else { "" }))
}
function Add-NotProduced([string]$Row, [string]$Precondition) { Add-Answer $Row 'not produced' '' $Precondition }
function Answered([string]$Row) { return @($script:Answers | Where-Object { $_.Row -eq $Row }).Count -gt 0 }
# -File passes "W7,W9" as one string, and a person types it either way; both mean two rows.
if ($Rows) { $Rows = @($Rows | ForEach-Object { $_ -split '[,;\s]+' } | Where-Object { $_ }) }
function Owns([string]$Row) { return (-not $Rows) -or ($Rows -contains $Row) }

# ------------------------------------------------------------------- capture
function Save-Screen([string]$Name) {
    # The whole primary screen, so a window is seen with the space around it, as gui_check.ps1 does.
    $path = Join-Path $script:Bundle $Name
    $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bitmap = New-Object System.Drawing.Bitmap($bounds.Width, $bounds.Height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
        $bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally { $graphics.Dispose(); $bitmap.Dispose() }
    return $path
}
function Test-CaptureWorks {
    # A capture of a locked screen or a disconnected RDP session is uniformly black. One small capture decides it.
    $bitmap = New-Object System.Drawing.Bitmap(120, 120)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen(0, 0, 0, 0, (New-Object System.Drawing.Size(120, 120)))
        for ($x = 0; $x -lt 120; $x += 7) {
            for ($y = 0; $y -lt 120; $y += 7) {
                $p = $bitmap.GetPixel($x, $y)
                if ($p.R -ne 0 -or $p.G -ne 0 -or $p.B -ne 0) { return $true }
            }
        }
        return $false
    }
    catch { return $false }
    finally { $graphics.Dispose(); $bitmap.Dispose() }
}
function Save-Text([string]$Name, [string]$Text) {
    $path = Join-Path $script:Bundle $Name
    [IO.File]::WriteAllText($path, $Text, (New-Object Text.UTF8Encoding($true)))
    return $path
}
function Copy-Into([string]$Source, [string]$Name) {
    $path = Join-Path $script:Bundle $Name
    Copy-Item -LiteralPath $Source -Destination $path -Force
    return $path
}

# --------------------------------------------------------- synced-folder test
function Get-SyncRoots {
    # The roots a file written under them is copied to a cloud service from. OneDrive publishes its own; a second
    # provider (a company's own client) is caught by the same environment convention when it sets one.
    $roots = New-Object System.Collections.Generic.List[string]
    foreach ($name in @('OneDrive', 'OneDriveCommercial', 'OneDriveConsumer')) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if ($value -and (Test-Path -LiteralPath $value)) { $roots.Add((Resolve-Path -LiteralPath $value).Path) }
    }
    # Known Folder Move sends the Desktop, Documents and Pictures into OneDrive without changing %USERPROFILE%;
    # their resolved paths are what a person's "put it on the desktop" actually means.
    foreach ($folder in @('Desktop', 'MyDocuments', 'MyPictures')) {
        try {
            $p = [Environment]::GetFolderPath($folder)
            if ($p -and (Test-Path -LiteralPath $p)) {
                $resolved = (Resolve-Path -LiteralPath $p).Path
                foreach ($root in @($roots)) { if ($resolved.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { $roots.Add($resolved) } }
            }
        }
        catch { }
    }
    return @($roots | Sort-Object -Unique)
}
function Get-ZoneId([string]$Path) {
    # The same reading as the campaign's (Invoke-AcceptanceCampaign.ps1): the Zone.Identifier stream's ZoneId line,
    # 'stream present' without one, 'no mark' without a stream.
    if (-not (Test-Path -LiteralPath $Path)) { return 'file missing' }
    $stream = Get-Item -LiteralPath $Path -Stream Zone.Identifier -ErrorAction SilentlyContinue
    if ($null -eq $stream) { return 'no mark' }
    $id = @(Get-Content -LiteralPath $Path -Stream Zone.Identifier -ErrorAction SilentlyContinue | Where-Object { $_ -match '^ZoneId=' })[0]
    if ($id) { return [string]$id }
    return 'stream present'
}
function Test-InternetMark([string]$Zone) {
    # Only the Internet (3) and Restricted (4) zones raise the security warning. A stream without a ZoneId, or a
    # local, intranet or trusted zone, is not the mark this row is about - the campaign settled that in PR #11.
    return ($Zone -match '^ZoneId=[34]$')
}
function Test-PathIsSynced([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    foreach ($root in (Get-SyncRoots)) {
        if ($full.StartsWith($root.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -or $full.Equals($root, [StringComparison]::OrdinalIgnoreCase)) { return $root }
    }
    return $null
}

# ------------------------------------------------------------- window helpers
function Get-WindowText($Window) {
    @($Window.FindAll($SCOPE::Descendants, [System.Windows.Automation.Condition]::TrueCondition) | ForEach-Object {
            $r = $_.Current.BoundingRectangle
            "{0,-24} {1,5},{2,-5} {3}" -f $_.Current.ClassName, [int]$r.Left, [int]$r.Top, $_.Current.Name
        }) -join "`r`n"
}
function Find-ByName($Window, [string]$Name) {
    $Window.FindFirst($SCOPE::Descendants, (New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, $Name)))
}
function Send-Click($Element) {
    [void][WalkCaptureWin32]::PostMessage([IntPtr]$Element.Current.NativeWindowHandle, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero)   # BM_CLICK
}
function New-EmptyStdin {
    # cmd.exe reads a launcher's trailing `pause` from standard input; an empty file ends it without a keypress.
    $path = Join-Path $script:Bundle 'stdin.empty'
    if (-not (Test-Path -LiteralPath $path)) { [IO.File]::WriteAllText($path, '') }
    return $path
}
function Get-ChildProcesses([int]$ParentId) {
    $filter = "ParentProcessId = $ParentId"
    if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) { return @(Get-CimInstance -ClassName Win32_Process -Filter $filter -ErrorAction SilentlyContinue) }
    return @(Get-WmiObject -Class Win32_Process -Filter $filter -ErrorAction SilentlyContinue)
}
function Get-PowerShellDescendant([int]$ParentId) {
    $children = @(Get-ChildProcesses $ParentId)
    $hit = @($children | Where-Object { $_.Name -match '^(powershell|pwsh)\.exe$' })[0]
    if ($null -ne $hit) { return $hit }
    foreach ($c in $children) {
        $hit = @(Get-ChildProcesses ([int]$c.ProcessId) | Where-Object { $_.Name -match '^(powershell|pwsh)\.exe$' })[0]
        if ($null -ne $hit) { return $hit }
    }
    return $null
}
function Wait-ForToolWindow([int]$ProcessId, [int]$Seconds = 60) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        $win = $AE::RootElement.FindFirst($SCOPE::Children, (New-Object System.Windows.Automation.PropertyCondition($AE::ProcessIdProperty, $ProcessId)))
        if ($null -ne $win) { return $win }
    }
    return $null
}
function Get-WindowSize($Window) {
    $r = $Window.Current.BoundingRectangle
    return ("{0} x {1}" -f [int]$r.Width, [int]$r.Height)
}
function Get-NewReport([string]$ReportDir, [datetime]$Since, [string]$Extension = 'json') {
    Get-ChildItem -LiteralPath $ReportDir -Filter ("*." + $Extension) -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -gt $Since } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

# ------------------------------------------------------------------ the walk
$PackageDir = (Resolve-Path -LiteralPath $PackageDir).Path
$lang = Split-Path -Leaf $PackageDir
if ($lang -notin @('en-US', 'zh-TW')) { Write-Output "ERROR: -PackageDir must be an en-US or zh-TW folder; got '$lang'"; exit 2 }
$script:ToolNames = @{
    'en-US' = @{ Start = 'Start Test'; Close = 'Close'; Reset = 'Reset to config'; Again = 'Run Again' }
    'zh-TW' = @{ Start = [string][char]0x958B + [char]0x59CB + [char]0x6AA2 + [char]0x6E2C; Close = [string][char]0x95DC + [char]0x9589; Reset = [string][char]0x9084 + [char]0x539F + [char]0x8A2D + [char]0x5B9A + [char]0x6A94; Again = [string][char]0x91CD + [char]0x65B0 + [char]0x6AA2 + [char]0x6E2C }
}
$names = $script:ToolNames[$lang]
if (-not $OutDir) { $OutDir = Join-Path $env:USERPROFILE ('NHC-Walk\' + (Get-Date).ToString('yyyyMMdd_HHmmss')) }

Write-Output ("NetworkHealthCheck walk capture - " + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
Write-Output ("  package  " + $PackageDir)
Write-Output ("  bundle   " + $OutDir)

# Refusal 1: a session that cannot be captured. Thirty black PNGs reported as success are worse than no harness.
if (-not (Test-CaptureWorks)) {
    Write-Output "REFUSED: this session cannot be captured - the screen is locked, or an RDP session was disconnected rather than logged off. Log in at the console (or reconnect the session), then run this again."
    exit 3
}
Write-Output "  session  capturable"

# Refusal 2: a bundle written into a synced folder leaves the machine before anybody carries it (backlog #43, and
# finding 4 of the 1.2.4 walk turned on this script).
$synced = Test-PathIsSynced $OutDir
if ($synced) {
    Write-Output ("REFUSED: the bundle would be written inside a synced folder (" + $synced + "), which copies every screenshot and every report to the cloud before anyone carries it. Pass -OutDir somewhere outside it, for example C:\NHC-Walk.")
    exit 3
}
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$script:Bundle = (Resolve-Path -LiteralPath $OutDir).Path
Write-Output ("  bundle   not synced, created")

# The machine, so that a size or a format in the bundle can be read months later.
# Two DPI numbers, because they differ and the difference is the point: this script is not per-monitor DPI aware, so
# the value it sees is 96 on a scaled desktop, while the tool's own window is scaled by the desktop's AppliedDPI -
# which is why a window that asks for 940 x 700 arrives 1175 x 875 (backlog #48, review round 4).
$dpiProcess = 96
try { $g = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero); $dpiProcess = [int]$g.DpiX; $g.Dispose() } catch { }
$dpi = $dpiProcess
try {
    $applied = (Get-ItemProperty -Path 'HKCU:\Control Panel\Desktop\WindowMetrics' -Name AppliedDPI -ErrorAction Stop).AppliedDPI
    if ($applied) { $dpi = [int]$applied }
}
catch { }
$facts = @(
    "captured at      : " + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss K')
    "computer         : " + $env:COMPUTERNAME
    "user             : " + $env:USERNAME
    "os               : " + [Environment]::OSVersion.VersionString
    "powershell       : " + $PSVersionTable.PSVersion.ToString()
    "ui culture       : " + (Get-UICulture).Name
    "culture          : " + (Get-Culture).Name
    "short date       : " + (Get-Culture).DateTimeFormat.ShortDatePattern
    "primary screen   : " + [System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Width + " x " + [System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Height
    "working area     : " + [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea.Width + " x " + [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea.Height
    "dpi (desktop)    : " + $dpi + " (AppliedDPI; 96 = 100%, 120 = 125%)"
    "dpi (this script): " + $dpiProcess + " - not per-monitor aware, so this is 96 on a scaled desktop"
    "package          : " + $PackageDir
    "OneDrive env     : " + $(if ($env:OneDrive) { $env:OneDrive } else { '(not set)' })
    "desktop resolves : " + [Environment]::GetFolderPath('Desktop')
    "documents        : " + [Environment]::GetFolderPath('MyDocuments')
) -join "`r`n"
[void](Save-Text 'machine.txt' $facts)
Write-Output "  machine  machine.txt"
Write-Output ""

# --------------------------------------------------- W1 / W5 / W5b: the ZIP and Windows' own dialogs
if (Owns 'W1') {
    if (-not $Zip) { Add-NotProduced 'W1' 'no -Zip was given, so there is no downloaded archive to open Properties on' }
    elseif (-not (Test-Path -LiteralPath $Zip)) { Add-NotProduced 'W1' ("the ZIP named by -Zip does not exist: " + $Zip) }
    else {
        $zipFull = (Resolve-Path -LiteralPath $Zip).Path
        $stream = Get-Item -LiteralPath $zipFull -Stream Zone.Identifier -ErrorAction SilentlyContinue
        [void](Save-Text 'W1-zone-identifier.txt' $(
                if ($stream) { "Zone.Identifier present (" + $stream.Length + " bytes)`r`n`r`n" + (Get-Content -LiteralPath $zipFull -Stream Zone.Identifier -Raw) }
                else { "no Zone.Identifier: this copy carries no Mark of the Web, so Properties shows no Unblock box" }))
        $shell = New-Object -ComObject Shell.Application
        $item = $shell.Namespace((Split-Path -Parent $zipFull)).ParseName((Split-Path -Leaf $zipFull))
        $item.InvokeVerb('Properties')
        Start-Sleep -Seconds 3
        $shot = Save-Screen 'W1-zip-properties.png'
        Add-Answer 'W1' 'captured' (Split-Path -Leaf $shot) ('with W1-zone-identifier.txt; ' + $(if ($stream) { 'the ZIP is marked, so the Unblock box must be in the picture' } else { 'the ZIP is unmarked, so there must be no Unblock box' }))
        # The property sheet is modal to Explorer, not to this script: close it before anything else is captured.
        $props = $AE::RootElement.FindFirst($SCOPE::Children, (New-Object System.Windows.Automation.PropertyCondition($AE::ClassNameProperty, '#32770')))
        if ($null -ne $props) {
            $cancel = @($props.FindAll($SCOPE::Descendants, (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button))) |
                    Where-Object { $_.Current.AutomationId -eq '2' })[0]
            if ($null -ne $cancel) { Send-Click $cancel; Start-Sleep -Seconds 1 }
        }
    }
}
foreach ($row in @('W2', 'W3', 'W4')) {
    if (Owns $row) {
        Add-NotProduced $row 'this script does not drive Explorer''s Extract All wizard or its compressed-folder view; the sheet keeps these three rows for the person'
    }
}

# --------------------------------------------------- the runs
function Invoke-ToolRun {
    param(
        [ValidateSet('User', 'IT')][string]$Entry,
        [string]$Label,
        [switch]$ShotWhileRunning,
        [switch]$ShotAtSampling,
        [switch]$ClickReset
    )
    $launcher = Join-Path $PackageDir $(if ($Entry -eq 'IT') { 'Start-NetworkCheck-IT.cmd' } else { 'Start-NetworkCheck.cmd' })
    $reportDir = Join-Path $PackageDir 'Reports'
    $launchedAt = Get-Date
    $cmd = Join-Path $env:SystemRoot 'System32\cmd.exe'
    $proc = Start-Process -FilePath $cmd -ArgumentList @('/c', ('"' + $launcher + '"')) -WorkingDirectory $PackageDir -PassThru
    $result = [pscustomobject]@{ Entry = $Entry; Window = $null; WindowSize = ''; ReportDir = $reportDir; LaunchedAt = $launchedAt; Json = $null; Process = $proc; GuiPid = $proc.Id }
    $child = $null; $deadline = (Get-Date).AddSeconds(30)
    while ($null -eq $child -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        if ($proc.HasExited) { break }
        $child = Get-PowerShellDescendant $proc.Id
    }
    if ($null -eq $child) { return $result }
    $result.GuiPid = [int]$child.ProcessId
    $win = Wait-ForToolWindow $result.GuiPid 60
    if ($null -eq $win) { return $result }
    $result.Window = $win
    $result.WindowSize = Get-WindowSize $win
    Start-Sleep -Seconds 2
    return $result
}

# Every row whose evidence is produced by the user run, so that -Rows with any one of them still makes the run.
$UserRunRows = @('W7', 'W9', 'W9b', 'W10', 'W12', 'W14', 'W15', 'W16', 'W17', 'W18', 'W20', 'W21', 'W22', 'W24',
    'W25', 'W27', 'W38', 'W39', 'W49', 'W51', 'W53', 'W56', 'W57', 'W58', 'W60')
$userRun = $null
if (@($UserRunRows | Where-Object { Owns $_ }).Count -gt 0) {
    Write-Output ""
    Write-Output "-- the user entry, the run the sheet's sections 3 to 5 walk"
    $userRun = Invoke-ToolRun -Entry 'User'
    if ($null -eq $userRun.Window) {
        foreach ($row in @('W7', 'W9', 'W10', 'W12', 'W9b', 'W13', 'W14', 'W25')) { if (Owns $row) { Add-NotProduced $row 'the user entry opened no window on this machine (a console-mode fallback, or the launcher stopped)' } }
    }
    else {
        $win = $userRun.Window
        if (Owns 'W7') {
            $shot = Save-Screen 'W7-window-title.png'
            [void](Save-Text 'W7-window-title.txt' (@(
                        "window name  : " + $win.Current.Name
                        "resolved size: " + $userRun.WindowSize + "  (recorded, never set)"
                        "asked for    : 940 x 700 before the working-area clamp and the desktop's DPI scaling"
                        "desktop dpi  : " + $dpi
                        "working area : " + [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea.Height
                    ) -join "`r`n"))
            Add-Answer 'W7' 'captured' (Split-Path -Leaf $shot) ("window '" + $win.Current.Name + "' at " + $userRun.WindowSize + " (recorded, not set)")
        }
        if (Owns 'W9') { $shot = Save-Screen 'W9-running.png'; Add-Answer 'W9' 'captured' (Split-Path -Leaf $shot) 'the window while the run is going' }
        if (Owns 'W10') {
            # The sampling line only exists for the last seconds of the run; look for it rather than guessing a moment.
            $found = $false; $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
            while (-not $found -and (Get-Date) -lt $deadline) {
                $text = Get-WindowText $win
                if ($text -match ('Sampling TCP|TCP ' + [char]0x91CD + [char]0x50B3)) { $found = $true; break }
                Start-Sleep -Milliseconds 700
            }
            if ($found) { $shot = Save-Screen 'W10-sampling.png'; Add-Answer 'W10' 'captured' (Split-Path -Leaf $shot) 'the countdown line while the sample is running' }
            else { Add-NotProduced 'W10' 'the sampling line was not on screen while this run was watched' }
        }
        $json = $null; $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        while ($null -eq $json -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2; $json = Get-NewReport $userRun.ReportDir $userRun.LaunchedAt }
        Start-Sleep -Seconds 2
        if (Owns 'W12') {
            if ($null -ne $json) { $shot = Save-Screen 'W12-finished.png'; Add-Answer 'W12' 'captured' (Split-Path -Leaf $shot) 'the window when the run has finished' }
            else { Add-NotProduced 'W12' ("no report was written within " + $TimeoutSeconds + " s, so the finished window was never reached") }
        }
        if (Owns 'W9b') {
            $text = Get-WindowText $win
            [void](Save-Text 'W9b-window.txt' $text)
            Add-Answer 'W9b' 'captured' 'W9b-window.txt' 'every control of the window with its position and text, for the log-to-report comparison'
        }
        if ($null -ne $json) {
            # Each format is written on its own and one that fails leaves the others usable, so the manifest names the
            # files that exist and not the three the run was supposed to write - and a run that wrote fewer than three
            # is W49's own condition, met rather than manufactured.
            $stem = [IO.Path]::GetFileNameWithoutExtension($json.Name)
            $copied = New-Object System.Collections.Generic.List[string]
            $unwritten = New-Object System.Collections.Generic.List[string]
            foreach ($ext in @('html', 'txt', 'json')) {
                $file = Join-Path $userRun.ReportDir ($stem + '.' + $ext)
                if (Test-Path -LiteralPath $file) { [void](Copy-Into $file ('report-' + $ext + '.' + $ext)); $copied.Add('report-' + $ext + '.' + $ext) }
                else { $unwritten.Add($ext.ToUpper()) }
            }
            $script:ReportArtefact = ($copied -join ', ')
            $note = if ($unwritten.Count -eq 0) { 'the three files of the user run' } else { ('the ' + $copied.Count + ' format(s) this run wrote; ' + ($unwritten -join ' and ') + ' was not written') }
            foreach ($row in @('W15', 'W16', 'W17', 'W18', 'W20', 'W21', 'W22', 'W24', 'W27', 'W38', 'W39', 'W53', 'W57', 'W58', 'W60')) {
                if (Owns $row) { Add-Answer $row 'captured' $script:ReportArtefact $note }
            }
            if (Owns 'W49') {
                if ($unwritten.Count -gt 0) { Add-Answer 'W49' 'captured' $script:ReportArtefact ('this run wrote ' + $copied.Count + ' of 3 formats - ' + ($unwritten -join ' and ') + ' missing - which is the row''s own condition, met and not manufactured') }
                else { Add-NotProduced 'W49' 'all three report formats were written; the sheet says not to manufacture a partial failure, only to record it when it happens' }
            }
            $data = Get-Content -LiteralPath $json.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            if (Owns 'W51') {
                if ($data.Overall.Code -eq 'ERROR') { Add-Answer 'W51' 'captured' $script:ReportArtefact 'this run ended Test Incomplete, which is the row''s own condition' }
                else { Add-NotProduced 'W51' ("this run ended " + $data.Overall.Text + "; the row is only answered when a run is Test Incomplete, which the sheet says to record when it happens") }
            }
        }
        else {
            foreach ($row in @('W15', 'W16', 'W17', 'W18', 'W20', 'W21', 'W22', 'W24', 'W27', 'W38', 'W39', 'W49', 'W51', 'W53', 'W57', 'W58', 'W60')) { if (Owns $row) { Add-NotProduced $row 'the user run wrote no report' } }
        }
        if (Owns 'W14') {
            # The row is about the second run: a new set of three with its own time in the name, the first set still
            # there. One listing after one run cannot show it, so the button the row names is clicked.
            $again = Find-ByName $win $names.Again
            if ($null -eq $json) { Add-NotProduced 'W14' 'the first run wrote no report, so there was nothing to run again from' }
            elseif ($null -eq $again) { Add-NotProduced 'W14' ("the button the row names (" + $names.Again + ") was not found after the first run") }
            else {
                $before = @(Get-ChildItem -LiteralPath $userRun.ReportDir -File -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
                $secondFrom = Get-Date
                Send-Click $again
                $json2 = $null; $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
                while ($null -eq $json2 -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2; $json2 = Get-NewReport $userRun.ReportDir $secondFrom }
                Start-Sleep -Seconds 2
                $after = @(Get-ChildItem -LiteralPath $userRun.ReportDir -File -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
                $survived = @($before | Where-Object { $after -contains $_ }).Count
                $added = @($after | Where-Object { $before -notcontains $_ })
                [void](Save-Text 'W14-run-again.txt' (@(
                            "before Run Again (" + $before.Count + " files):"
                            ($before -join "`r`n")
                            ""
                            "after Run Again (" + $after.Count + " files, " + $survived + " of the first set still present):"
                            ($after -join "`r`n")
                            ""
                            "new in the second run: " + $(if ($added.Count) { ($added -join ', ') } else { '(none)' })
                        ) -join "`r`n"))
                if ($null -eq $json2) { Add-NotProduced 'W14' ("the second run wrote no report within " + $TimeoutSeconds + " s; W14-run-again.txt has the folder either side of the click") }
                else { Add-Answer 'W14' 'captured' 'W14-run-again.txt' ("Run Again added " + $added.Count + " file(s) and left " + $survived + " of " + $before.Count + " untouched") }
            }
        }
        if (Owns 'W25') {
            $listing = @(Get-ChildItem -LiteralPath $userRun.ReportDir -ErrorAction SilentlyContinue | ForEach-Object { "{0,-60} {1,10}  {2}" -f $_.Name, $_.Length, $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss') }) -join "`r`n"
            [void](Save-Text 'W25-reports-folder.txt' ("report directory: " + $userRun.ReportDir + "`r`n`r`n" + $listing))
            Add-Answer 'W25' 'captured' 'W25-reports-folder.txt' 'the report folder with the naming of every file in it'
        }
        if (Owns 'W56') {
            $sync = Test-PathIsSynced $userRun.ReportDir
            [void](Save-Text 'W56-report-directory.txt' ("resolved report directory: " + $userRun.ReportDir + "`r`nsynced                   : " + $(if ($sync) { 'YES - inside ' + $sync } else { 'no' }) + "`r`nOneDrive env             : " + $(if ($env:OneDrive) { $env:OneDrive } else { '(not set)' })))
            Add-Answer 'W56' 'captured' 'W56-report-directory.txt' $(if ($sync) { 'the reports of this walk are being copied to the cloud as they are written' } else { 'the report folder is not inside a synced folder on this machine' })
        }
        $close = Find-ByName $win $names.Close
        if ($null -ne $close) { Send-Click $close; [void]$userRun.Process.WaitForExit(15000) }
        if (-not $userRun.Process.HasExited) { $userRun.Process.Kill() }
    }
}

# --------------------------------------------------- the IT entry
if ((Owns 'W32') -or (Owns 'W34') -or (Owns 'W33')) {
    Write-Output ""
    Write-Output "-- the IT entry, section 7"
    $itRun = Invoke-ToolRun -Entry 'IT'
    if ($null -eq $itRun.Window) {
        foreach ($row in @('W32', 'W33', 'W34')) { if (Owns $row) { Add-NotProduced $row 'the IT entry opened no window on this machine' } }
    }
    else {
        $win = $itRun.Window
        if (Owns 'W32') {
            $shot = Save-Screen 'W32-it-panel.png'
            [void](Save-Text 'W32-it-panel.txt' ("resolved size: " + $itRun.WindowSize + "`r`n`r`n" + (Get-WindowText $win)))
            Add-Answer 'W32' 'captured' (Split-Path -Leaf $shot) ('the panel at ' + $itRun.WindowSize + ', with every control and its text in W32-it-panel.txt')
        }
        if (Owns 'W34') {
            # Reset can only be shown to work on a panel that has been changed, so every field is changed first: a
            # number goes up by one, a text field gains a marker. That is this row's own precondition and not W33,
            # which is about the person's typing and the run they make with it.
            $reset = Find-ByName $win $names.Reset
            # The panel's own fields only: the log box is an edit control too, and it is not one of the six the row is
            # about, so height keeps it out.
            $edits = @($win.FindAll($SCOPE::Descendants, [System.Windows.Automation.Condition]::TrueCondition) |
                    Where-Object { $_.Current.ClassName -match 'EDIT' -and $_.Current.BoundingRectangle.Height -lt 60 } |
                    Sort-Object { [int]$_.Current.BoundingRectangle.Top }, { [int]$_.Current.BoundingRectangle.Left })
            # The spinners are left alone on purpose. Their inner edit takes WM_SETTEXT, but the control's Value does
            # not change with it, so Reset restores a value that never moved and the picture would show the old text
            # sitting there - evidence that reads like a defect and is an artefact of the harness. Their three fields
            # stay the person's to check; the four free-text fields are changed honestly.
            $changed = 0
            $skippedNumeric = 0
            foreach ($e in $edits) {
                $old = [string]$e.Current.Name
                if ($old -match '^\d+$') { $skippedNumeric++; continue }
                $new = ($old + 'walkcapture.example').Trim()
                $set = $false
                try {
                    $vp = $e.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
                    $vp.SetValue($new)
                    $set = $true
                }
                catch { }
                if (-not $set) {
                    $handle = [IntPtr]$e.Current.NativeWindowHandle
                    if ($handle -ne [IntPtr]::Zero) {
                        [void][WalkCaptureWin32]::SendMessageW($handle, 0x000C, [IntPtr]::Zero, $new)   # WM_SETTEXT
                        Start-Sleep -Milliseconds 100
                        $set = ([string]$e.Current.Name -eq $new)
                    }
                }
                if ($set) { $changed++ }
            }
            Start-Sleep -Milliseconds 500
            $shotBefore = Save-Screen 'W34-before-reset.png'
            [void](Save-Text 'W34-before-reset.txt' ("text fields changed by this script: " + $changed + "`r`nnumeric spinners left untouched   : " + $skippedNumeric + " (their value does not follow their text; check them by hand)`r`n`r`n" + (Get-WindowText $win)))
            if ($null -eq $reset) { Add-NotProduced 'W34' ("the button the row names (" + $names.Reset + ") was not found in the panel; W34-before-reset.png has the panel as it stood") }
            elseif ($changed -eq 0) { Add-NotProduced 'W34' 'none of the panel''s text fields could be changed, so Reset had nothing to restore and the row would prove nothing' }
            else {
                Send-Click $reset
                Start-Sleep -Seconds 2
                $shot = Save-Screen 'W34-after-reset.png'
                [void](Save-Text 'W34-after-reset.txt' (Get-WindowText $win))
                Add-Answer 'W34' 'captured' ((Split-Path -Leaf $shotBefore) + ', ' + (Split-Path -Leaf $shot)) ($changed.ToString() + ' text field(s) changed and then Reset; the ' + $skippedNumeric + ' numeric spinner(s) were left untouched, so the row''s "all six" is proved for the text fields here and stays the person''s for the spinners')
            }
        }
        if (Owns 'W33') { Add-NotProduced 'W33' 'this script does not type into the panel''s six controls; the row belongs to the person, who is the one whose typing the row is about' }
        $close = Find-ByName $win $names.Close
        if ($null -ne $close) { Send-Click $close; [void]$itRun.Process.WaitForExit(15000) }
        if (-not $itRun.Process.HasExited) { $itRun.Process.Kill() }
    }
}

# --------------------------------------------------- the console entry and the launcher's error report
if (Owns 'W31') {
    Write-Output ""
    Write-Output "-- the console entry, section 6"
    $console = Join-Path $PackageDir 'Start-NetworkCheck-Console.cmd'
    if (-not (Test-Path -LiteralPath $console)) { Add-NotProduced 'W31' 'Start-NetworkCheck-Console.cmd is not in this package' }
    else {
        $out = Join-Path $script:Bundle 'W31-console.txt'
        $p = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\cmd.exe') -ArgumentList @('/c', ('"' + $console + '"')) -WorkingDirectory $PackageDir -RedirectStandardOutput $out -RedirectStandardInput (New-EmptyStdin) -NoNewWindow -PassThru -Wait
        Add-Answer 'W31' 'captured' 'W31-console.txt' ('the text-mode run as it printed, exit code ' + $p.ExitCode)
    }
}
if ((Owns 'W28') -or (Owns 'W29')) {
    Write-Output ""
    Write-Output "-- the launcher with its program file missing, section 6"
    $programFile = Join-Path $PackageDir 'NetworkHealthCheck.ps1'
    $stashed = $programFile + '.walkcapture'
    $errFile = Join-Path $PackageDir 'LauncherError.txt'
    if (Test-Path -LiteralPath $errFile) { Remove-Item -LiteralPath $errFile -Force }
    Rename-Item -LiteralPath $programFile -NewName (Split-Path -Leaf $stashed)
    try {
        $out = Join-Path $script:Bundle 'W28-launcher-window.txt'
        $launcher = Join-Path $PackageDir 'Start-NetworkCheck.cmd'
        $p = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\cmd.exe') -ArgumentList @('/c', ('"' + $launcher + '"')) -WorkingDirectory $PackageDir -RedirectStandardOutput $out -RedirectStandardInput (New-EmptyStdin) -NoNewWindow -PassThru -Wait
        if (Owns 'W28') { Add-Answer 'W28' 'captured' 'W28-launcher-window.txt' ('what the black window said, exit code ' + $p.ExitCode) }
        if (Owns 'W29') {
            if (Test-Path -LiteralPath $errFile) {
                [void](Copy-Into $errFile 'W29-LauncherError.txt')
                Add-Answer 'W29' 'captured' 'W29-LauncherError.txt' 'the file as the launcher wrote it, fields and all, for reading against section 6''s description'
            }
            else { Add-NotProduced 'W29' 'the launcher wrote no LauncherError.txt beside itself on this machine' }
        }
    }
    finally {
        if (Test-Path -LiteralPath $stashed) { Rename-Item -LiteralPath $stashed -NewName (Split-Path -Leaf $programFile) }
        if (Test-Path -LiteralPath $errFile) { Remove-Item -LiteralPath $errFile -Force }
    }
}

# --------------------------------------------------- W5 / W5b: the mark, and the dialog it raises
if ((Owns 'W5') -or (Owns 'W5b')) {
    Write-Output ""
    Write-Output "-- the Mark of the Web and the security warning, section 3"
    $launcher = Join-Path $PackageDir 'Start-NetworkCheck.cmd'
    $launcherZone = Get-ZoneId $launcher
    $marked = Test-InternetMark $launcherZone
    $zipZone = if ($Zip -and (Test-Path -LiteralPath $Zip)) { Get-ZoneId $Zip } else { '(no -Zip given)' }
    [void](Save-Text 'W5-mark-of-the-web.txt' (@(
                "ZIP                : " + $zipZone
                "extracted launcher : " + $launcher
                "                   : " + $launcherZone + $(if ($marked) { ' - the Internet or Restricted zone, which is the mark that raises the security question' } else { ' - not the mark that raises the security question' })
            ) -join "`r`n"))
    if (Owns 'W5b') {
        # W5b is the other extraction: the ZIP unblocked, extracted again, and launched with no dialog at all. This
        # script neither unblocks a file nor makes that second copy, so the row stays the person's.
        Add-NotProduced 'W5b' 'the unblocked half needs the ZIP unblocked and extracted a second time, which this script does not do; the mark this copy carries is in W5-mark-of-the-web.txt'
    }
    if (Owns 'W5') {
        if (-not $marked) {
            Add-NotProduced 'W5' ("the extracted launcher carries " + $launcherZone + ", not the Internet or Restricted mark that raises the security warning, so there is no dialog to capture; W5-mark-of-the-web.txt has the state of both files")
        }
        else {
            # ShellExecute the marked launcher: Windows raises its own dialog, which is what the row is about. The
            # dialog is captured and then cancelled - whether to run a file the machine is warning about is the
            # person's decision, not this script's.
            $shell = New-Object -ComObject Shell.Application
            $item = $shell.Namespace($PackageDir).ParseName('Start-NetworkCheck.cmd')
            $item.InvokeVerb('open')
            $dialog = $null; $deadline = (Get-Date).AddSeconds(15)
            while ($null -eq $dialog -and (Get-Date) -lt $deadline) {
                Start-Sleep -Milliseconds 500
                $dialog = $AE::RootElement.FindFirst($SCOPE::Children, (New-Object System.Windows.Automation.PropertyCondition($AE::ClassNameProperty, '#32770')))
            }
            if ($null -eq $dialog) {
                Add-NotProduced 'W5' 'the marked launcher raised no dialog within 15 s on this machine; the run may have started instead, which the sheet asks the person to note'
            }
            else {
                $shot = Save-Screen 'W5-security-warning.png'
                [void](Save-Text 'W5-security-warning.txt' ("dialog title: " + $dialog.Current.Name + "`r`n`r`n" + (Get-WindowText $dialog)))
                Add-Answer 'W5' 'captured' (Split-Path -Leaf $shot) ("dialog '" + $dialog.Current.Name + "'; every line of it is in W5-security-warning.txt, which is what a manual quotes")
                $cancel = @($dialog.FindAll($SCOPE::Descendants, [System.Windows.Automation.Condition]::TrueCondition) | Where-Object { $_.Current.AutomationId -eq '2' })[0]
                if ($null -ne $cancel) { Send-Click $cancel } else { Add-Answer 'W5' 'captured' (Split-Path -Leaf $shot) 'the dialog is still open: close it by hand' }
                Start-Sleep -Seconds 1
            }
        }
    }
}

# --------------------------------------------------- the rows whose precondition this machine may not have
# W40 is the one row whose precondition this machine may actually have, so it is answered on both sides.
if ((Owns 'W40') -and -not (Answered 'W40')) {
    $vpn = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -and ($_.InterfaceDescription -match 'VPN|TAP|WAN Miniport \(IKEv2\)|WireGuard') })
    if ($vpn.Count -eq 0) { Add-NotProduced 'W40' 'no VPN adapter is connected on this machine, and the row asks for one only if a VPN is available' }
    elseif (-not $script:ReportArtefact) { Add-NotProduced 'W40' ("a VPN adapter is connected (" + (@($vpn | ForEach-Object { $_.Name }) -join ', ') + ") but this walk captured no report to read it in") }
    else { Add-Answer 'W40' 'captured' $script:ReportArtefact ("a VPN adapter was connected during the run (" + (@($vpn | ForEach-Object { $_.Name }) -join ', ') + "), so the report has it beside the physical one; how this VPN is classified is the person's to read") }
}
$conditional = @(
    @{ Row = 'W42'; Missing = 'this machine has Windows PowerShell, and the sheet forbids breaking it to produce the row' }
    @{ Row = 'W47'; Missing = 'no archiver that extracts a whole folder into its view was driven; stock Windows stops earlier, which is W3''s row' }
    @{ Row = 'W48'; Missing = 'the sheet says not to manufacture a report-generation failure; record it if it happens' }
    @{ Row = 'W49'; Missing = 'the sheet says not to manufacture a partial report-write failure; record it if it happens' }
    @{ Row = 'W50'; Missing = 'the sheet says not to manufacture an unrecoverable error; record it if it happens' }
    @{ Row = 'W43'; Missing = 'the restricted-language-mode scenario changes a machine-wide policy and needs elevation; the campaign''s M7 owns it' }
    @{ Row = 'W44'; Missing = 'the AllSigned execution policy is a Group Policy change and needs elevation; the campaign''s M8 owns it' }
    @{ Row = 'W45'; Missing = 'the %TEMP% copy of the launcher''s error report needs the package folder made unwritable; not driven by this script' }
    @{ Row = 'W46'; Missing = 'the unwritable report folder needs an ACL change on Reports; not driven by this script' }
    @{ Row = 'W54'; Missing = 'the before-and-after captures of "it changes nothing" are backlog #42''s chain step, not a capture row' }
    @{ Row = 'W36'; Missing = 'the file table is checked by tests\doc_facts.ps1 (E1) and its reverse direction is backlog #41' }
    @{ Row = 'W37'; Missing = 'a pristine extraction is not made by this script; the same check is backlog #41' }
    @{ Row = 'W59'; Missing = 'the other language is walked by running this script against that language folder' }
    @{ Row = 'W13'; Missing = 'the report is opened in the person''s own browser, and the address bar is theirs to read' }
)
foreach ($c in $conditional) {
    if (-not (Owns $c.Row)) { continue }
    if (Answered $c.Row) { continue }   # a row answered by a capture above is not asked again here
    Add-NotProduced $c.Row $c.Missing
}
# The invariant this script is written around: every row it owns leaves with an answer.
$owedRows = @($UserRunRows + @('W1', 'W2', 'W3', 'W4', 'W5', 'W5b', 'W13', 'W28', 'W29', 'W31', 'W32', 'W33', 'W34',
        'W36', 'W37', 'W40', 'W42', 'W43', 'W44', 'W45', 'W46', 'W47', 'W48', 'W50', 'W54', 'W59') | Sort-Object -Unique)
foreach ($row in $owedRows) {
    if ((Owns $row) -and -not (Answered $row)) { Add-NotProduced $row 'this run reached no branch that answers the row - a defect in walk_capture.ps1, not a fact about the machine' }
}

# --------------------------------------------------------------- the manifest
$manifest = New-Object System.Text.StringBuilder
[void]$manifest.AppendLine('# Walk capture manifest')
[void]$manifest.AppendLine('')
[void]$manifest.AppendLine('One line per row this capture owns. `captured` names the artefact in this folder; `not produced` names the')
[void]$manifest.AppendLine('precondition that was missing. Fill the sheet''s Observed column from this file; the rows it does not name are')
[void]$manifest.AppendLine('the person''s, and so are all six questions of *Was it usable?*.')
[void]$manifest.AppendLine('')
[void]$manifest.AppendLine('| Row | Outcome | Artefact | Note |')
[void]$manifest.AppendLine('|---|---|---|---|')
foreach ($a in ($script:Answers | Sort-Object { [int]($_.Row -replace '\D', '') }, Row)) {
    [void]$manifest.AppendLine(('| {0} | {1} | {2} | {3} |' -f $a.Row, $a.Outcome, $a.Artefact, $a.Note))
}
[void]$manifest.AppendLine('')
[void]$manifest.AppendLine('Machine: see `machine.txt`. Evidence leaves this machine by hand: copy this folder off it.')
[void](Save-Text 'manifest.md' $manifest.ToString())

$captured = @($script:Answers | Where-Object { $_.Outcome -eq 'captured' }).Count
$missing = @($script:Answers | Where-Object { $_.Outcome -ne 'captured' }).Count
Write-Output ""
Write-Output ("Summary: {0} rows answered - {1} captured, {2} not produced; bundle {3}" -f $script:Answers.Count, $captured, $missing, $script:Bundle)
Write-Output "Copy the bundle off this machine by hand. Nothing here was uploaded."
exit 0
