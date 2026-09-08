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
    // A console window taller than the screen hides the very line the pause row is about, so it is fitted to the
    // working area before the picture is taken. Nothing about the run changes; only what the camera can see.
    [DllImport("user32.dll", SetLastError = true)] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    // A dialog this script asked to close is looked at again rather than assumed gone: the walk of 2026-09-09
    // left one on the screen while the manifest said it had been cancelled.
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
}
"@
$AE = [System.Windows.Automation.AutomationElement]
$SCOPE = [System.Windows.Automation.TreeScope]

# ---------------------------------------------------------------- the answers
$script:Answers = New-Object System.Collections.Generic.List[object]
$script:ReportArtefact = ''
$script:ReportJsonPath = ''
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

# The rows this script owns. -Rows is checked against it, because a typo that answers nothing and exits 0 is the
# silent absence this script exists to prevent.
# Every row whose evidence is produced by the user run, so that -Rows with any one of them still makes the run.
$UserRunRows = @('W7', 'W9', 'W9b', 'W10', 'W12', 'W14', 'W15', 'W16', 'W17', 'W18', 'W20', 'W21', 'W22', 'W24',
    'W25', 'W27', 'W38', 'W39', 'W40', 'W48', 'W49', 'W50', 'W51', 'W53', 'W56', 'W57', 'W58', 'W59', 'W60')
$OwnedRows = @($UserRunRows + @('W1', 'W2', 'W3', 'W4', 'W5', 'W5b', 'W13', 'W28', 'W29', 'W31', 'W32', 'W33',
        'W34', 'W36', 'W37', 'W42', 'W43', 'W44', 'W45', 'W46', 'W47', 'W48', 'W50', 'W54', 'W59') | Sort-Object -Unique | Sort-Object { [int]($_ -replace '\D', '') }, { $_ })
if ($Rows) {
    $unknown = @($Rows | Where-Object { $OwnedRows -notcontains $_ })
    if ($unknown.Count) {
        Write-Output ('ERROR: -Rows names ' + ($unknown -join ', ') + ', which this script does not own. It owns: ' + ($OwnedRows -join ', '))
        exit 2
    }
}

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
    # A capture of a locked screen or a disconnected RDP session is uniformly black. A corner is not evidence of that
    # - a black wallpaper, hidden icons or one dark window would fail a corner test on a perfectly usable desktop -
    # so the whole primary screen is sampled on a grid, and one non-black pixel anywhere is enough.
    $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bitmap = New-Object System.Drawing.Bitmap($bounds.Width, $bounds.Height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
        $stepX = [Math]::Max(1, [int]($bounds.Width / 40))
        $stepY = [Math]::Max(1, [int]($bounds.Height / 40))
        for ($x = 0; $x -lt $bounds.Width; $x += $stepX) {
            for ($y = 0; $y -lt $bounds.Height; $y += $stepY) {
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
function Test-WindowGone([IntPtr]$Hwnd, [int]$Seconds = 3) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        if (-not [WalkCaptureWin32]::IsWindow($Hwnd)) { return $true }
        Start-Sleep -Milliseconds 300
    }
    return (-not [WalkCaptureWin32]::IsWindow($Hwnd))
}
function Close-Dialog($Dialog) {
    # Windows' own dialogs are not this script's to answer, but the ones it opened are its to close. A posted
    # BM_CLICK was all this did, and on a shell dialog it does not always land: the walk of 2026-09-09 left a
    # security warning on the screen under a manifest line that said it had been cancelled. Three ways are tried
    # in order - Cancel through UI Automation, a posted click on it, then WM_CLOSE on the dialog itself, which
    # needs no button and no language - and each is followed by a look at the window. The caller is told which
    # one worked, or that the dialog is still there, and says so in the row's note.
    $hwnd = [IntPtr]$Dialog.Current.NativeWindowHandle
    $tried = New-Object System.Collections.Generic.List[string]
    $cancel = @($Dialog.FindAll($SCOPE::Descendants, (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button))) |
            Where-Object { $_.Current.AutomationId -eq '2' })[0]
    if ($null -ne $cancel) {
        $invoked = $false
        try {
            $cancel.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
            $invoked = $true
        }
        catch { }
        $tried.Add($(if ($invoked) { 'Cancel invoked through UI Automation' } else { 'Cancel would not take an Invoke' }))
        if ($invoked -and (Test-WindowGone $hwnd)) { return [pscustomobject]@{ Closed = $true; How = ($tried -join ', ') } }
        Send-Click $cancel
        $tried.Add('BM_CLICK posted to Cancel')
        if (Test-WindowGone $hwnd) { return [pscustomobject]@{ Closed = $true; How = ($tried -join ', ') } }
    }
    else { $tried.Add('the dialog carries no Cancel button (AutomationId 2)') }
    [void][WalkCaptureWin32]::PostMessage($hwnd, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)   # WM_CLOSE
    $tried.Add('WM_CLOSE posted to the dialog')
    return [pscustomobject]@{ Closed = (Test-WindowGone $hwnd); How = ($tried -join ', ') }
}
function Start-ShellVerb([string]$Path, [string]$Verb) {
    # ShellExecute does not return until a dialog it raised has been answered, and the security warning is raised
    # inside the call: a script that invokes the verb on its own thread is blocked for exactly as long as the
    # dialog it is waiting to photograph is on the screen. The walk of 2026-09-09 recorded W5 as not produced with
    # the dialog standing there. The verb runs on a background STA runspace instead - shell COM needs an STA -
    # and the caller polls the desktop while it is still open.
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions = 'ReuseThread'
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
            param($folder, $leaf, $verb)
            (New-Object -ComObject Shell.Application).Namespace($folder).ParseName($leaf).InvokeVerb($verb)
        }).AddArgument((Split-Path -Parent $Path)).AddArgument((Split-Path -Leaf $Path)).AddArgument($Verb)
    return [pscustomobject]@{ Shell = $ps; Runspace = $rs; Handle = $ps.BeginInvoke() }
}
function Stop-ShellVerb($Opener) {
    # A call that has returned is cleaned up; one still blocked on a dialog nobody answered is left alone, because
    # disposing its runspace would take the dialog with it and the row has already said it is on the screen.
    if ($null -eq $Opener) { return }
    if (-not $Opener.Handle.IsCompleted) { return }
    try { [void]$Opener.Shell.EndInvoke($Opener.Handle) } catch { }
    try { $Opener.Shell.Dispose(); $Opener.Runspace.Dispose() } catch { }
}
function New-EmptyStdin {
    # cmd.exe reads a launcher's trailing `pause` from standard input; an empty file ends it without a keypress.
    $path = Join-Path $script:Bundle 'stdin.empty'
    if (-not (Test-Path -LiteralPath $path)) { [IO.File]::WriteAllText($path, '') }
    return $path
}
function Save-Stderr([string]$Path) {
    # A launcher can fail on the one line that says the run succeeded and say so on standard error and nowhere
    # else: the zh-TW walk of 2026-09-09 lost exactly that, because only standard output was redirected, and the
    # evidence survived only in a screenshot taken beside it. An empty file is deleted rather than kept, so the
    # bundle never carries an artefact that says nothing.
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    if ((Get-Item -LiteralPath $Path).Length -gt 0) { return $true }
    Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    return $false
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
function Get-ExplorerWindows {
    # What Explorer has open, by window identity and not by path: the folder may already be open, and a second window
    # on the same folder is exactly what the button under test opens.
    $out = New-Object System.Collections.Generic.List[object]
    try {
        $shell = New-Object -ComObject Shell.Application
        foreach ($w in @($shell.Windows())) {
            try { $out.Add([pscustomobject]@{ Hwnd = [int64]$w.HWND; Url = [string]$w.LocationURL }) } catch { }
        }
    }
    catch { }
    # ToArray, not @(...): the array subexpression over a List[object] throws ArgumentException in Windows PowerShell
    # 5.1 here, which cost this script a run to find.
    return $out.ToArray()
}
function Close-ExplorerWindow([int64]$Hwnd) {
    try {
        $shell = New-Object -ComObject Shell.Application
        foreach ($w in @($shell.Windows())) {
            try { if ([int64]$w.HWND -eq $Hwnd) { $w.Quit() } } catch { }
        }
    }
    catch { }
}
function Get-AnyNewReport([string]$ReportDir, [datetime]$Since) {
    # Save-Reports writes each format on its own, so a run whose JSON failed still wrote the other two - and waiting
    # for the JSON alone would call that run reportless and lose exactly the evidence W49 is for.
    # The emergency and environment files are named NetworkHealthCheck_FATAL_* and NetworkHealthCheck_ENVIRONMENT_*
    # and are not report formats: taking one as the run's report would turn a total failure into a "1 of 3 written"
    # partial and answer W49 with it while leaving W48 unproduced.
    @(Get-ChildItem -LiteralPath $ReportDir -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in @('.html', '.txt', '.json') -and $_.Name -like 'NetworkHealthCheck_*' -and $_.Name -notmatch '^NetworkHealthCheck_(FATAL|ENVIRONMENT)_' -and $_.LastWriteTime -gt $Since } |
            Sort-Object LastWriteTime -Descending)[0]
}
function Get-NewEmergencyFile([string]$ReportDir, [datetime]$Since) {
    @(Get-ChildItem -LiteralPath $ReportDir -Filter 'NetworkHealthCheck_FATAL_*' -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -gt $Since } | Sort-Object LastWriteTime -Descending)[0]
}

# ------------------------------------------------------------------ the walk
$PackageDir = (Resolve-Path -LiteralPath $PackageDir).Path
$lang = Split-Path -Leaf $PackageDir
if ($lang -notin @('en-US', 'zh-TW')) { Write-Output "ERROR: -PackageDir must be an en-US or zh-TW folder; got '$lang'"; exit 2 }
$script:ToolNames = @{
    'en-US' = @{ Start = 'Start Test'; Close = 'Close'; Reset = 'Reset to config'; Again = 'Run Again'; Folder = 'Open Report Folder'; Report = 'Open Report' }
    'zh-TW' = @{ Start = [string][char]0x958B + [char]0x59CB + [char]0x6AA2 + [char]0x6E2C; Close = [string][char]0x95DC + [char]0x9589; Reset = [string][char]0x9084 + [char]0x539F + [char]0x8A2D + [char]0x5B9A + [char]0x6A94; Again = [string][char]0x91CD + [char]0x65B0 + [char]0x6AA2 + [char]0x6E2C; Folder = [string][char]0x958B + [char]0x555F + [char]0x5831 + [char]0x544A + [char]0x8CC7 + [char]0x6599 + [char]0x593E; Report = [string][char]0x958B + [char]0x555F + [char]0x5831 + [char]0x544A }
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

# Elevation is a fact about every run this makes, not only about W39: a launcher started from an elevated harness
# runs the tool with an administrator token, and the person the sheet is written for does not have one.
$script:Elevated = $false
try { $script:Elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { }
if ($script:Elevated) { Write-Output "  WARNING  this harness is elevated: every run it makes inherits an administrator token, so W39 cannot be answered and the other rows are not what a user would see" }

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
    "elevated         : " + $(if ($script:Elevated) { 'YES - the runs this harness makes inherit an administrator token, which is not what a user has' } else { 'no' })
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
        # The Unblock box follows the same rule as the security warning: the Internet or Restricted zone, not merely a
        # stream. A local, intranet or trusted mark shows no box, and the manifest must not contradict the picture.
        $zipZoneW1 = Get-ZoneId $zipFull
        $zipMarkedW1 = Test-InternetMark $zipZoneW1
        [void](Save-Text 'W1-zone-identifier.txt' $(
                if ($zipZoneW1 -eq 'no mark') { "no Zone.Identifier: this copy carries no Mark of the Web, so Properties shows no Unblock box" }
                else { $zipZoneW1 + "`r`n`r`n" + (Get-Content -LiteralPath $zipFull -Stream Zone.Identifier -Raw -ErrorAction SilentlyContinue) }))
        # The property sheet this script opened, told apart from anything already on screen by its handle: an
        # unrelated dialog would otherwise be photographed as the ZIP's properties and cancelled in its place.
        $dialogCondition = New-Object System.Windows.Automation.PropertyCondition($AE::ClassNameProperty, '#32770')
        $dialogsBefore = @($AE::RootElement.FindAll($SCOPE::Children, $dialogCondition) | ForEach-Object { [int64]$_.Current.NativeWindowHandle })
        $shell = New-Object -ComObject Shell.Application
        $item = $shell.Namespace((Split-Path -Parent $zipFull)).ParseName((Split-Path -Leaf $zipFull))
        # Properties opens a modeless sheet and this call returns at once, which is why it is made on this thread
        # and the open verb below is not: that one does not return while the dialog it raised is on the screen.
        $item.InvokeVerb('Properties')
        # Wait for the sheet this script opened before photographing anything: a screenshot taken on a timer
        # would otherwise be the desktop, answered as the ZIP's properties.
        $props = $null; $deadline = (Get-Date).AddSeconds(15)
        while ($null -eq $props -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 500
            $props = @($AE::RootElement.FindAll($SCOPE::Children, $dialogCondition) |
                    Where-Object { $dialogsBefore -notcontains [int64]$_.Current.NativeWindowHandle })[0]
        }
        if ($null -eq $props) {
            Add-NotProduced 'W1' 'Explorer opened no property sheet for the ZIP within 15 s, so there was nothing to photograph; W1-zone-identifier.txt has the mark this copy carries'
        }
        else {
        Start-Sleep -Seconds 1
        $shot = Save-Screen 'W1-zip-properties.png'
        # The property sheet is modal to Explorer, not to this script: close the one this script opened, and only
        # it - and look at the window afterwards, because a click that did not land was recorded here as one that did.
        $closedW1 = Close-Dialog $props
        Add-Answer 'W1' 'captured' (Split-Path -Leaf $shot) ('with W1-zone-identifier.txt; the ZIP carries ' + $zipZoneW1 + ', so ' + $(if ($zipMarkedW1) { 'the Unblock box must be in the picture' } else { 'there must be no Unblock box' }) + $(if ($closedW1.Closed) { '' } else { '. The property sheet did not close (' + $closedW1.How + '), so it is still on the screen: close it by hand' }))
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

$userRun = $null
if (@($UserRunRows | Where-Object { Owns $_ }).Count -gt 0) {
    Write-Output ""
    Write-Output "-- the user entry, the run the sheet's sections 3 to 5 walk"
    $userRun = Invoke-ToolRun -Entry 'User'
    # A run without a window is not a run without a report: the tool falls back to console mode and writes its three
    # files anyway, and that fallback is one of the things the sheet's section 6 is about. The window rows are
    # answered here; the report rows are answered from the report below, window or no window.
    if ($null -eq $userRun.Window) {
        foreach ($row in @('W7', 'W9', 'W10', 'W12', 'W9b', 'W14', 'W25')) { if (Owns $row) { Add-NotProduced $row 'the user entry opened no window on this machine - a console-mode fallback, or the launcher stopped; what the run wrote is answered from the report' } }
    }
    $win = $userRun.Window
        if ((Owns 'W7') -and $null -ne $win) {
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
        if ((Owns 'W9') -and $null -ne $win) { $shot = Save-Screen 'W9-running.png'; Add-Answer 'W9' 'captured' (Split-Path -Leaf $shot) 'the window while the run is going' }
        if ((Owns 'W10') -and $null -ne $win) {
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
        $report = $null; $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        while ($null -eq $report -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2; $report = Get-AnyNewReport $userRun.ReportDir $userRun.LaunchedAt }
        Start-Sleep -Seconds 2
        # An emergency file is looked for whether or not a report appeared - inside the has-a-report branch it
        # could never have seen the case it is about - and it belongs to the row its own title names: the tool
        # writes the same NetworkHealthCheck_FATAL_* name for a report-generation failure (W48), an unhandled
        # error (W50) and a startup failure (neither row). The message box is part of both rows, so it is
        # captured and dismissed rather than left modal in front of the clicks that follow.
        if ((Owns 'W48') -or (Owns 'W50')) {
            $fatal = Get-NewEmergencyFile $userRun.ReportDir $userRun.LaunchedAt
            if ($null -ne $fatal) {
                $fatalText = ''
                try { $fatalText = Get-Content -LiteralPath $fatal.FullName -Raw -Encoding UTF8 } catch { }
                $fatalRow = if ($fatalText -match 'Report Generation Failed|' + [char]0x5831 + [char]0x544A + [char]0x7522 + [char]0x751F + [char]0x5931 + [char]0x6557) { 'W48' }
                elseif ($fatalText -match 'Unhandled Error|' + [char]0x672A + [char]0x8655 + [char]0x7406 + [char]0x932F + [char]0x8AA4) { 'W50' }
                else { '' }
                [void](Copy-Into $fatal.FullName 'FATAL.txt')
                $fatalShot = $null
                $fatalDialog = $null
                if ($null -ne $win) {
                    $fatalDialog = $AE::RootElement.FindFirst($SCOPE::Children, (New-Object System.Windows.Automation.AndCondition(
                                (New-Object System.Windows.Automation.PropertyCondition($AE::ProcessIdProperty, $userRun.GuiPid)),
                                (New-Object System.Windows.Automation.PropertyCondition($AE::ClassNameProperty, '#32770')))))
                }
                if ($null -ne $fatalDialog) {
                    $fatalShot = Save-Screen 'FATAL-dialog.png'
                    [void](Save-Text 'FATAL-dialog.txt' ("dialog title: " + $fatalDialog.Current.Name + "`r`n`r`n" + (Get-WindowText $fatalDialog)))
                    $okButton = @($fatalDialog.FindAll($SCOPE::Descendants, [System.Windows.Automation.Condition]::TrueCondition) | Where-Object { $_.Current.AutomationId -in @('1', '2') })[0]
                    if ($null -ne $okButton) { Send-Click $okButton; Start-Sleep -Seconds 1 }
                }
                if ($fatalRow -and (Owns $fatalRow)) {
                    if ($null -ne $fatalDialog) { Add-Answer $fatalRow 'captured' ('FATAL.txt, FATAL-dialog.png, FATAL-dialog.txt') ('this run left ' + $fatal.Name + ' and the tool put up the message box that names it - the row''s own condition, met and not manufactured') }
                    else { Add-Answer $fatalRow 'not produced' 'FATAL.txt' ('this run left ' + $fatal.Name + ', but no message box from the tool was on screen to capture, and the row is about that box naming the file') }
                }
                elseif (-not $fatalRow) { Write-Output ('  note: ' + $fatal.Name + ' names neither row (a startup failure); it is in the bundle as FATAL.txt') }
            }
        }
        if ((Owns 'W12') -and $null -ne $win) {
            if ($null -ne $report) { $shot = Save-Screen 'W12-finished.png'; Add-Answer 'W12' 'captured' (Split-Path -Leaf $shot) 'the window when the run has finished' }
            else { Add-NotProduced 'W12' ("no report was written within " + $TimeoutSeconds + " s, so the finished window was never reached") }
        }
        if ((Owns 'W9b') -and $null -ne $win) {
            # The row is a comparison of the window's log with the report's rows, so the window's text alone does not
            # answer it: without a report there is nothing to compare it against.
            $text = Get-WindowText $win
            [void](Save-Text 'W9b-window.txt' $text)
            if ($null -ne $report) { Add-Answer 'W9b' 'captured' 'W9b-window.txt' 'every control of the window with its position and text, to be read against the report''s rows in order' }
            else { Add-Answer 'W9b' 'not produced' 'W9b-window.txt' 'the window''s text is here, but this run wrote no report, so the comparison the row asks for cannot be made' }
        }
        if ($null -ne $report) {
            # Each format is written on its own and one that fails leaves the others usable, so the manifest names the
            # files that exist and not the three the run was supposed to write - and a run that wrote fewer than three
            # is W49's own condition, met rather than manufactured.
            $stem = [IO.Path]::GetFileNameWithoutExtension($report.Name)
            $copied = New-Object System.Collections.Generic.List[string]
            $unwritten = New-Object System.Collections.Generic.List[string]
            foreach ($ext in @('html', 'txt', 'json')) {
                $file = Join-Path $userRun.ReportDir ($stem + '.' + $ext)
                if (Test-Path -LiteralPath $file) { [void](Copy-Into $file ('report-' + $ext + '.' + $ext)); $copied.Add('report-' + $ext + '.' + $ext) }
                else { $unwritten.Add($ext.ToUpper()) }
            }
            $script:ReportArtefact = ($copied -join ', ')
            $note = if ($unwritten.Count -eq 0) { 'the three files of the user run' } else { ('the ' + $copied.Count + ' format(s) this run wrote; ' + ($unwritten -join ' and ') + ' was not written') }
            foreach ($row in @('W15', 'W16', 'W17', 'W22', 'W27', 'W38', 'W53', 'W57', 'W60')) {
                if (Owns $row) { Add-Answer $row 'captured' $script:ReportArtefact $note }
            }
            # Show Details, the badges as they render and the IT diagnostics collapsed at the bottom exist in the
            # HTML report and nowhere else, so the surviving formats cannot answer these three.
            $htmlWritten = $copied -contains 'report-html.html'
            foreach ($row in @('W18', 'W20', 'W21')) {
                if (-not (Owns $row)) { continue }
                if ($htmlWritten) { Add-Answer $row 'captured' 'report-html.html' 'the HTML report, which is where this row''s controls and badges are' }
                else { Add-Answer $row 'not produced' $script:ReportArtefact 'this run wrote no HTML report, and the row is about what the HTML shows' }
            }
            # W59 is answered by walking the Chinese package, which is this script run against the zh-TW folder.
            if (Owns 'W59') {
                if ($lang -eq 'zh-TW') { Add-Answer 'W59' 'captured' $script:ReportArtefact 'the Traditional Chinese package produced this report on this machine, interface and all' }
                else { Add-NotProduced 'W59' 'this walk ran the en-US package; the row is answered by running this script against the zh-TW folder' }
            }
            # W24 compares the three formats with each other, so two of them cannot answer it - the missing one is
            # W49's evidence and W24's absence.
            if (Owns 'W24') {
                if ($unwritten.Count -eq 0) { Add-Answer 'W24' 'captured' $script:ReportArtefact 'all three formats of the same run, for the comparison the row asks for' }
                else { Add-Answer 'W24' 'not produced' $script:ReportArtefact ('this run wrote ' + $copied.Count + ' of the 3 formats (' + ($unwritten -join ' and ') + ' missing), so the three cannot be compared with each other; the same fact answers W49') }
            }
            # W39 is a claim about the run's rights, and a run started from an elevated harness inherits that token
            # while the report says nothing about it - so the row is answered from what this process is, not from the
            # report's existence.
            if (Owns 'W39') {
                if ($script:Elevated) { Add-Answer 'W39' 'not produced' $script:ReportArtefact 'this harness is running elevated, so the run it made inherited an administrator token; the row is about a run made without one' }
                else { Add-Answer 'W39' 'captured' $script:ReportArtefact 'the run was made by this unelevated harness, which is the row''s precondition' }
            }
            if (Owns 'W49') {
                # The row is the message box that names the count and the surviving file, not the missing files: a
                # partial write with no dialog is a defect the row exists to catch, so the dialog decides.
                if ($unwritten.Count -eq 0) { Add-NotProduced 'W49' 'all three report formats were written; the sheet says not to manufacture a partial failure, only to record it when it happens' }
                else {
                    $toolDialog = $null
                    if ($null -ne $win) {
                        $toolDialog = $AE::RootElement.FindFirst($SCOPE::Children, (New-Object System.Windows.Automation.AndCondition(
                                    (New-Object System.Windows.Automation.PropertyCondition($AE::ProcessIdProperty, $userRun.GuiPid)),
                                    (New-Object System.Windows.Automation.PropertyCondition($AE::ClassNameProperty, '#32770')))))
                    }
                    if ($null -ne $toolDialog) {
                        $shot = Save-Screen 'W49-partial-write-dialog.png'
                        [void](Save-Text 'W49-partial-write-dialog.txt' ("dialog title: " + $toolDialog.Current.Name + "`r`n`r`n" + (Get-WindowText $toolDialog)))
                        # The box is modal: it must be dismissed or every later click on this window - W14's Run
                        # Again, W25's Open Report Folder - waits behind it. Then the row's second half: Open Report
                        # has to open the format that survived, so the button is clicked and what appeared is kept.
                        $ok = @($toolDialog.FindAll($SCOPE::Descendants, [System.Windows.Automation.Condition]::TrueCondition) | Where-Object { $_.Current.AutomationId -in @('1', '2') })[0]
                        if ($null -ne $ok) { Send-Click $ok; Start-Sleep -Seconds 1 }
                        $openReport = Find-ByName $win $names.Report
                        $afterShot = $null
                        if ($null -ne $openReport) {
                            Send-Click $openReport
                            Start-Sleep -Seconds 4
                            $afterShot = Save-Screen 'W49-after-open-report.png'
                        }
                        Add-Answer 'W49' 'captured' ((Split-Path -Leaf $shot) + ', W49-partial-write-dialog.txt' + $(if ($afterShot) { ', ' + (Split-Path -Leaf $afterShot) } else { '' })) ('this run wrote ' + $copied.Count + ' of 3 formats (' + ($unwritten -join ' and ') + ' missing) and the tool put up its message box' + $(if ($null -eq $ok) { '; its button was not found, so it may still be on screen' } else { ', which was dismissed' }) + $(if ($afterShot) { '; Open Report was then clicked and what it opened is in the second picture, for the person to check that it is the surviving format' } else { '; the Open Report button was not found, so the row''s second half is the person''s' }))
                    }
                    else {
                        Add-Answer 'W49' 'not produced' $script:ReportArtefact ('this run wrote ' + $copied.Count + ' of 3 formats (' + ($unwritten -join ' and ') + ' missing), but no message box from the tool was on screen to capture - the row is about that box naming the count and the surviving file, so it is the person''s to check')
                    }
                }
            }
            $jsonPath = Join-Path $userRun.ReportDir ($stem + '.json')
            if (Test-Path -LiteralPath $jsonPath) { $script:ReportJsonPath = $jsonPath }
            $data = if (Test-Path -LiteralPath $jsonPath) { Get-Content -LiteralPath $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
            if (Owns 'W51') {
                if ($null -eq $data) { Add-NotProduced 'W51' 'this run wrote no JSON report, so its verdict could not be read here; the HTML or text file carries it' }
                elseif ($data.Overall.Code -eq 'ERROR') { Add-Answer 'W51' 'captured' $script:ReportArtefact 'this run ended Test Incomplete, which is the row''s own condition' }
                else { Add-NotProduced 'W51' ("this run ended " + $data.Overall.Text + "; the row is only answered when a run is Test Incomplete, which the sheet says to record when it happens") }
            }
            # W58 is two conditional answers - the counters unreadable, or too little traffic to judge - and the sheet
            # says to record either as not produced when it did not appear. A report that has neither row proves
            # nothing about them.
            if (Owns 'W58') {
                if ($null -eq $data) { Add-NotProduced 'W58' 'this run wrote no JSON report, so its retransmission rows could not be read here' }
                else {
                    $tcp = @($data.Results | Where-Object { $_.Tag -eq 'tcp-retransmissions' })
                    $unable = @($tcp | Where-Object { $_.Status -eq 'ERROR' })
                    $small = @($tcp | Where-Object { $_.Status -eq 'INFO' })
                    if ($unable.Count -gt 0) { Add-Answer 'W58' 'captured' $script:ReportArtefact ('the counters could not be read on this run (' + $unable.Count + ' Unable to Check row(s)), which is the first of the row''s two answers') }
                    elseif ($small.Count -gt 0) { Add-Answer 'W58' 'captured' $script:ReportArtefact ('this run had too little TCP traffic to judge (' + $small.Count + ' information row(s)), which is the second of the row''s two answers') }
                    else { Add-NotProduced 'W58' ('this run read both counters and had enough traffic (' + $tcp.Count + ' retransmission row(s), none Unable to Check or informational), so neither answer''s row appeared') }
                }
            }
        }
        else {
            foreach ($row in @('W15', 'W16', 'W17', 'W18', 'W20', 'W21', 'W22', 'W24', 'W27', 'W38', 'W39', 'W49', 'W51', 'W53', 'W57', 'W58', 'W59', 'W60')) { if (Owns $row) { Add-NotProduced $row 'the user run wrote no report' } }
        }
        if ((Owns 'W14') -and $null -ne $win) {
            # The row is about the second run: a new set of three with its own time in the name, the first set still
            # there. One listing after one run cannot show it, so the button the row names is clicked.
            $again = Find-ByName $win $names.Again
            if ($null -eq $report) { Add-NotProduced 'W14' 'the first run wrote no report, so there was nothing to run again from' }
            elseif ($null -eq $again) { Add-NotProduced 'W14' ("the button the row names (" + $names.Again + ") was not found after the first run") }
            else {
                $before = @(Get-ChildItem -LiteralPath $userRun.ReportDir -File -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
                $secondFrom = Get-Date
                Send-Click $again
                $json2 = $null; $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
                while ($null -eq $json2 -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2; $json2 = Get-AnyNewReport $userRun.ReportDir $secondFrom }
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
        if ((Owns 'W25') -and $null -ne $win) {
            # The row is about the button, not about the path this script can compute: what Open Report Folder opens
            # is the thing to record, so it is clicked and the folder Explorer actually opened is read back.
            $listing = @(Get-ChildItem -LiteralPath $userRun.ReportDir -ErrorAction SilentlyContinue | ForEach-Object { "{0,-60} {1,10}  {2}" -f $_.Name, $_.Length, $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss') }) -join "`r`n"
            $folderButton = Find-ByName $win $names.Folder
            if ($null -eq $folderButton) {
                [void](Save-Text 'W25-reports-folder.txt' ("report directory (read by this script, not by the button): " + $userRun.ReportDir + "`r`n`r`n" + $listing))
                Add-Answer 'W25' 'not produced' 'W25-reports-folder.txt' ("the button the row names (" + $names.Folder + ") was not found, so what it opens could not be recorded; the folder this script resolved is in the file")
            }
            else {
                $explorerBefore = @((Get-ExplorerWindows) | ForEach-Object { $_.Hwnd })
                Send-Click $folderButton
                $new = @(); $deadline = (Get-Date).AddSeconds(15)
                while ($new.Count -eq 0 -and (Get-Date) -lt $deadline) {
                    Start-Sleep -Milliseconds 700
                    $new = @((Get-ExplorerWindows) | Where-Object { $explorerBefore -notcontains $_.Hwnd })
                }
                Start-Sleep -Seconds 1
                $opened = @($new | ForEach-Object { $_.Url })
                $shot = if ($opened.Count -gt 0) { Save-Screen 'W25-open-report-folder.png' } else { $null }
                $expectedUrl = ([uri]$userRun.ReportDir).AbsoluteUri.TrimEnd('/')
                $match = @($opened | Where-Object { $_.TrimEnd('/') -eq $expectedUrl }).Count -gt 0
                [void](Save-Text 'W25-reports-folder.txt' (@(
                            "the button opened : " + $(if ($opened.Count) { ($opened -join ', ') } else { '(no new Explorer window within 15 s)' })
                            "the run wrote to  : " + $userRun.ReportDir
                            "same folder       : " + $(if ($match) { 'yes' } else { 'no - read the two paths above' })
                            "note              : new windows are told apart by their handle, so a folder that was already open does not hide the one the button opened"
                            ""
                            $listing
                        ) -join "`r`n"))
                foreach ($w in $new) { Close-ExplorerWindow $w.Hwnd }
                if ($opened.Count -eq 0) { Add-Answer 'W25' 'not produced' 'W25-reports-folder.txt' 'the button was clicked and no new Explorer window appeared within 15 s, so what it opens was not recorded' }
                else { Add-Answer 'W25' 'captured' ((Split-Path -Leaf $shot) + ', W25-reports-folder.txt') ('Open Report Folder opened ' + ($opened -join ', ') + ', which ' + $(if ($match) { 'is' } else { '**is not**' }) + ' the folder the run wrote to') }
            }
        }
        if (Owns 'W56') {
            $sync = Test-PathIsSynced $userRun.ReportDir
            [void](Save-Text 'W56-report-directory.txt' ("resolved report directory: " + $userRun.ReportDir + "`r`nsynced                   : " + $(if ($sync) { 'YES - inside ' + $sync } else { 'no' }) + "`r`nOneDrive env             : " + $(if ($env:OneDrive) { $env:OneDrive } else { '(not set)' })))
            Add-Answer 'W56' 'captured' 'W56-report-directory.txt' $(if ($sync) { 'the reports of this walk are being copied to the cloud as they are written' } else { 'the report folder is not inside a synced folder on this machine' })
        }
    if ($null -ne $win) {
        $close = Find-ByName $win $names.Close
        if ($null -ne $close) { Send-Click $close; [void]$userRun.Process.WaitForExit(15000) }
    }
    if (-not $userRun.Process.HasExited) { $userRun.Process.Kill() }
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
                # The row is about all six controls returning, and the three spinners were never moved: their edit
                # takes WM_SETTEXT while the control's Value does not follow it, and this panel's controls expose no
                # value pattern to UI Automation at all (measured: every field is a Pane with no supported patterns).
                # Changing their text and clicking Reset would put a stale number in the picture and read as a defect
                # that is the harness's. So the pictures go into the bundle and the row is not claimed.
                Add-Answer 'W34' 'not produced' ((Split-Path -Leaf $shotBefore) + ', ' + (Split-Path -Leaf $shot)) ($changed.ToString() + ' text field(s) were changed and restored, which the two pictures show; the ' + $skippedNumeric + ' numeric spinner(s) cannot be moved from here, so the row''s claim about all six controls is the person''s to finish - it is a quick comparison with the pictures in hand')
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
        # Two runs, because the row asks for two things. The redirected one keeps the text; it cannot show the pause,
        # since an empty standard input ends `pause` at once. The second run is the launcher as a person starts it -
        # its own window, nothing redirected - and it is captured while it sits at the pause with the report paths
        # above it, which is what the row is about.
        $out = Join-Path $script:Bundle 'W31-console.txt'
        $errOut = Join-Path $script:Bundle 'W31-console-stderr.txt'
        $p = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\cmd.exe') -ArgumentList @('/c', ('"' + $console + '"')) -WorkingDirectory $PackageDir -RedirectStandardOutput $out -RedirectStandardError $errOut -RedirectStandardInput (New-EmptyStdin) -NoNewWindow -PassThru -Wait
        $keptErr = Save-Stderr $errOut
        $errArtefact = if ($keptErr) { ', W31-console-stderr.txt' } else { '' }
        $errNote = if ($keptErr) { '; the run also printed on standard error, which is in W31-console-stderr.txt' } else { '; it printed nothing on standard error' }
        $reportDir = Join-Path $PackageDir 'Reports'
        $pauseFrom = Get-Date
        $p2 = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\cmd.exe') -ArgumentList @('/c', ('"' + $console + '"')) -WorkingDirectory $PackageDir -PassThru
        $second = $null; $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        while ($null -eq $second -and (Get-Date) -lt $deadline -and -not $p2.HasExited) { Start-Sleep -Seconds 2; $second = Get-AnyNewReport $reportDir $pauseFrom }
        Start-Sleep -Seconds 3
        $paused = (-not $p2.HasExited)
        $shot = $null
        if ($paused) {
            try {
                $p2.Refresh()
                $handle = $p2.MainWindowHandle
                if ($handle -ne [IntPtr]::Zero) {
                    $area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
                    [void][WalkCaptureWin32]::SetWindowPos($handle, [IntPtr]::Zero, 0, 0, $area.Width, $area.Height, 0x0040)   # SWP_SHOWWINDOW
                    [void][WalkCaptureWin32]::SetForegroundWindow($handle)
                    Start-Sleep -Milliseconds 800
                }
            }
            catch { }
            $shot = Save-Screen 'W31-paused-window.png'
        }
        if (-not $p2.HasExited) { $p2.Kill() }
        if ($paused -and $null -ne $second) {
            Add-Answer 'W31' 'captured' ('W31-console.txt' + $errArtefact + ', ' + (Split-Path -Leaf $shot)) ('the text-mode run as it printed (exit code ' + $p.ExitCode + ')' + $errNote + '; the second run had written its report and had still not exited when the picture was taken, which is the pause the row is about, and the window was fitted to the working area first so its last lines are in the picture')
        }
        elseif ($null -eq $second) {
            Add-Answer 'W31' 'not produced' ('W31-console.txt' + $errArtefact) ('the interactive run wrote no report within the timeout, so the paused window could not be captured; the redirected run''s text is in the bundle' + $errNote)
        }
        else {
            Add-Answer 'W31' 'not produced' ('W31-console.txt' + $errArtefact) ('the interactive run ended without waiting, so no paused window was there to capture; the redirected run''s text is in the bundle' + $errNote)
        }
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
        $errOut = Join-Path $script:Bundle 'W28-launcher-window-stderr.txt'
        $launcher = Join-Path $PackageDir 'Start-NetworkCheck.cmd'
        $p = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\cmd.exe') -ArgumentList @('/c', ('"' + $launcher + '"')) -WorkingDirectory $PackageDir -RedirectStandardOutput $out -RedirectStandardError $errOut -RedirectStandardInput (New-EmptyStdin) -NoNewWindow -PassThru -Wait
        # The window this row is about is the one the person sees, and PowerShell writes its own failures to the
        # error stream: a launcher that stops for a reason of its own would otherwise leave half of it unrecorded.
        $keptErr28 = Save-Stderr $errOut
        $errArtefact28 = if ($keptErr28) { ', W28-launcher-window-stderr.txt' } else { '' }
        # The file is the evidence of both rows - W28 names it appearing, W29 reads its fields - and the finally below
        # deletes the original, so it is copied whenever either row is owned.
        $errCopied = $false
        if (Test-Path -LiteralPath $errFile) { [void](Copy-Into $errFile 'W29-LauncherError.txt'); $errCopied = $true }
        if (Owns 'W28') {
            if ($errCopied) { Add-Answer 'W28' 'captured' ('W28-launcher-window.txt' + $errArtefact28 + ', W29-LauncherError.txt') ('what the black window said (exit code ' + $p.ExitCode + ')' + $(if ($keptErr28) { ', what it printed on standard error' } else { '' }) + ', and the error report it named') }
            else { Add-Answer 'W28' 'not produced' ('W28-launcher-window.txt' + $errArtefact28) ('the window''s text is here (exit code ' + $p.ExitCode + ')' + $(if ($keptErr28) { ', with what it printed on standard error beside it' } else { '' }) + ', but no LauncherError.txt appeared beside the launcher, which is half of what the row asks for') }
        }
        if (Owns 'W29') {
            if ($errCopied) { Add-Answer 'W29' 'captured' 'W29-LauncherError.txt' 'the file as the launcher wrote it, fields and all, for reading against section 6''s description' }
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
    # The row is about the launcher the reader double-clicks after extracting, which is the package root's
    # Start-English.cmd / Start-Traditional-Chinese.cmd - not the language folder's inner launcher. A warning raised
    # by the inner file would say nothing about the one the manual sends people to.
    $rootLauncherName = @{ 'en-US' = 'Start-English.cmd'; 'zh-TW' = 'Start-Traditional-Chinese.cmd' }[$lang]
    $rootLauncher = Join-Path (Split-Path -Parent $PackageDir) $rootLauncherName
    $usingRoot = Test-Path -LiteralPath $rootLauncher
    $launcher = if ($usingRoot) { $rootLauncher } else { Join-Path $PackageDir 'Start-NetworkCheck.cmd' }
    $launcherZone = Get-ZoneId $launcher
    $marked = Test-InternetMark $launcherZone
    $zipZone = if ($Zip -and (Test-Path -LiteralPath $Zip)) { Get-ZoneId $Zip } else { '(no -Zip given)' }
    [void](Save-Text 'W5-mark-of-the-web.txt' (@(
                "ZIP                : " + $zipZone
                "launcher double-clicked : " + $launcher
                "                   : " + $(if ($usingRoot) { 'the package root launcher, which is the one the manual sends people to' } else { 'the language folder''s launcher - the root ' + $rootLauncherName + ' is not beside this package, so the row was answered on the inner one' })
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
            # person's decision, not this script's. The call is made off this thread, because it does not return
            # while the dialog it raised is on the screen: see Start-ShellVerb.
            # Only a dialog that was not there before and that names the file just launched: any other top-level
            # #32770 - a save box, an update prompt, something the person left open - would otherwise be captured,
            # cancelled and recorded as this launcher's security warning.
            $dialogCondition = New-Object System.Windows.Automation.PropertyCondition($AE::ClassNameProperty, '#32770')
            $before = @($AE::RootElement.FindAll($SCOPE::Children, $dialogCondition) | ForEach-Object { [int64]$_.Current.NativeWindowHandle })
            $opener = Start-ShellVerb $launcher 'open'
            $launcherLeaf = Split-Path -Leaf $launcher
            $dialog = $null; $stray = $null; $deadline = (Get-Date).AddSeconds(15)
            while ($null -eq $dialog -and (Get-Date) -lt $deadline) {
                Start-Sleep -Milliseconds 500
                foreach ($candidate in @($AE::RootElement.FindAll($SCOPE::Children, $dialogCondition))) {
                    if ($before -contains [int64]$candidate.Current.NativeWindowHandle) { continue }
                    if ((Get-WindowText $candidate) -match [regex]::Escape($launcherLeaf)) { $dialog = $candidate; break }
                    $stray = $candidate
                }
            }
            if ($null -eq $dialog) {
                $strayNote = if ($null -ne $stray) { " A new dialog did appear ('" + $stray.Current.Name + "') without naming the launcher, so it was left alone." } else { '' }
                # The call itself is evidence now that it no longer blocks: one that has returned with no dialog on
                # the screen means Windows raised no question and started the launcher.
                $returned = if ($opener.Handle.IsCompleted) { ' ShellExecute returned without raising one, so the launcher was started.' } else { ' ShellExecute has not returned, so something is still holding it.' }
                Add-NotProduced 'W5' ('the marked launcher raised no dialog naming ' + $launcherLeaf + ' within 15 s on this machine; the run may have started instead, which the sheet asks the person to note.' + $returned + $strayNote)
            }
            else {
                # The dialog's own title is read while it is still on the screen: every property of a window that
                # has been closed comes back empty, and the row would name a dialog with no name.
                $dialogName = $dialog.Current.Name
                $shot = Save-Screen 'W5-security-warning.png'
                [void](Save-Text 'W5-security-warning.txt' ("dialog title: " + $dialogName + "`r`n`r`n" + (Get-WindowText $dialog)))
                # Cancelled and not answered: whether to run a file the machine is warning about is the person's
                # decision. What the row records is what actually happened to the dialog, not what was attempted.
                $closedW5 = Close-Dialog $dialog
                Add-Answer 'W5' 'captured' (Split-Path -Leaf $shot) ("dialog '" + $dialogName + "' raised by " + (Split-Path -Leaf $launcher) + "; every line of it is in W5-security-warning.txt, which is what a manual quotes" + $(if ($closedW5.Closed) { ', and the dialog was cancelled rather than answered (' + $closedW5.How + ')' } else { '. It would not close (' + $closedW5.How + '), so it is still on the screen: cancel it by hand' }))
            }
            Stop-ShellVerb $opener
        }
    }
}

# --------------------------------------------------- the rows whose precondition this machine may not have
# W40 is the one row whose precondition this machine may actually have, so it is answered on both sides.
if ((Owns 'W40') -and -not (Answered 'W40')) {
    # The VPN half of the tool's own Test-IsVirtualAdapter list (NetworkHealthCheck.ps1), which is a superset: it also
    # calls VMware, Hyper-V, vEthernet and Docker adapters virtual, and none of those is the VPN this row is about. So
    # the vendors and mechanisms that carry a VPN are kept - Tailscale, ZeroTier, WireGuard, Wintun, TAP, tunnels, the
    # IKEv2 miniport, the enterprise clients - and the host-virtualization names are left out.
    $vpnPattern = 'vpn|wireguard|zerotier|tailscale|wintun|tap-|tunnel|hamachi|cisco|anyconnect|openvpn|forticlient|globalprotect|pulse secure|ikev2|wan miniport'
    $vpn = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -and ($_.InterfaceDescription -match $vpnPattern -or $_.Name -match $vpnPattern) })
    $vpnNames = @($vpn | ForEach-Object { $_.Name })
    if ($vpn.Count -eq 0) { Add-NotProduced 'W40' 'no VPN adapter is connected on this machine, and the row asks for one only if a VPN is available' }
    elseif (-not $script:ReportArtefact) { Add-NotProduced 'W40' ("a VPN adapter is connected (" + ($vpnNames -join ', ') + ") but this walk captured no report to read it in") }
    else {
        # An adapter with no address of its own is left out of the report (NetworkHealthCheck.ps1, the adapter loop),
        # so a connected VPN is not the same thing as a VPN in the report. The report decides.
        $reportText = if ($script:ReportJsonPath -and (Test-Path -LiteralPath $script:ReportJsonPath)) { Get-Content -LiteralPath $script:ReportJsonPath -Raw -Encoding UTF8 } else { '' }
        $named = @($vpnNames | Where-Object { $reportText -and $reportText.Contains($_) })
        if ($named.Count -gt 0) { Add-Answer 'W40' 'captured' $script:ReportArtefact ("the report names the connected VPN adapter (" + ($named -join ', ') + "); whether it is marked Virtual and listed as information is the person's to read") }
        elseif (-not $reportText) { Add-Answer 'W40' 'not produced' $script:ReportArtefact ("a VPN adapter is connected (" + ($vpnNames -join ', ') + ") but this run wrote no JSON report to check it against") }
        else { Add-Answer 'W40' 'not produced' $script:ReportArtefact ("a VPN adapter is connected (" + ($vpnNames -join ', ') + ") and the report does not name it - an adapter without an address of its own is left out, which is worth the person's eye rather than a captured row") }
    }
}
$conditional = @(
    @{ Row = 'W42'; Missing = 'this machine has Windows PowerShell, and the sheet forbids breaking it to produce the row' }
    @{ Row = 'W47'; Missing = 'no archiver that extracts a whole folder into its view was driven; stock Windows stops earlier, which is W3''s row' }
    @{ Row = 'W48'; Missing = 'the sheet says not to manufacture a report-generation failure; record it if it happens' }
    @{ Row = 'W50'; Missing = 'the sheet says not to manufacture an unrecoverable error; record it if it happens' }
    @{ Row = 'W49'; Missing = 'the sheet says not to manufacture a partial report-write failure; record it if it happens' }
    @{ Row = 'W43'; Missing = 'the restricted-language-mode scenario changes a machine-wide policy and needs elevation; the campaign''s M7 owns it' }
    @{ Row = 'W44'; Missing = 'the AllSigned execution policy is a Group Policy change and needs elevation; the campaign''s M8 owns it' }
    @{ Row = 'W45'; Missing = 'the %TEMP% copy of the launcher''s error report needs the package folder made unwritable; not driven by this script' }
    @{ Row = 'W46'; Missing = 'the unwritable report folder needs an ACL change on Reports; not driven by this script' }
    @{ Row = 'W54'; Missing = 'the before-and-after captures of "it changes nothing" are backlog #42''s chain step, not a capture row' }
    @{ Row = 'W36'; Missing = 'the file table is checked by tests\doc_facts.ps1 (E1) and its reverse direction is backlog #41' }
    @{ Row = 'W37'; Missing = 'a pristine extraction is not made by this script; the same check is backlog #41' }
    @{ Row = 'W13'; Missing = 'the report is opened in the person''s own browser, and the address bar is theirs to read' }
)
foreach ($c in $conditional) {
    if (-not (Owns $c.Row)) { continue }
    if (Answered $c.Row) { continue }   # a row answered by a capture above is not asked again here
    Add-NotProduced $c.Row $c.Missing
}
# The invariant this script is written around: every row it owns leaves with an answer.
foreach ($row in $OwnedRows) {
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
