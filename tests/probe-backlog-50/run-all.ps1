<#
.SYNOPSIS
    Backlog #50: runs the five minimal batch files beside this script on the machine that produced the failure,
    both halves - what the screen shows and what the text streams carry - and records the machine.

.DESCRIPTION
    The zh-TW console launcher ended a successful run on DESKTOP-CO7QIMR (Windows 10 22H2, zh-TW display) with
    cmd's "is not recognized as an internal or external command" after the completion sentence, from the launcher's
    last echo line, the one that names the exit code. The five files beside this script move one variable each
    (the table is in README.md). This script runs every one of them twice, and each run gets a console of its own:

      1. As a double-click. The .cmd is handed to the shell with its folder as the working directory, which is what
         Explorer does and yields the same command line (cmd.exe /c ""<file>" ", recorded in the manifest). The
         window is left at its `pause`, photographed, and only then ended - by one key aimed at that window, the way
         a person ends it, or killed where the key could not be aimed. The picture is the window's own rectangle
         where the started process owns a window (the classic console); where another process hosts the console
         (Windows Terminal, on builds that delegate to it) the terminal window in the foreground is framed instead,
         and failing that the whole primary screen is taken. The manifest says which.
      2. Redirected. cmd.exe /c in a new console window, standard output and standard error into two files, an
         empty standard input so that `pause` ends by itself. The bytes are kept as written, a hex dump beside each,
         because the variants print under different code pages and one decoding would hide what is measured.

    A console of its own is the point. `chcp` changes the console and not the process, so five variants run through
    `call` in one window all inherit whatever code page the first one set: variant 3, "without chcp", would never
    see the machine's own code page, and variants 2, 4 and 5 would never make the change that variant 1 makes.
    Measured on the reference machine on 2026-09-13: after a `call` of a file with `chcp 65001`, a `call`ed file
    without one reports 65001, a child `cmd /c` reports 65001, and a `start`ed new console reports the machine's
    950. Start-Process with redirected streams opens a new console unless -NoNewWindow is given (measured the same
    day: the child reported 950 while the parent console stood at 65001), and this script never gives it.

    Everything lands in results_<computer>_<stamp>\ beside this script: <variant>.png, <variant>.log (standard
    output), <variant>-stderr.log (kept only when something was printed there), machine.txt, and run-all.txt, the
    manifest binding each file to the run that produced it. Send the whole folder back with the results in it.

    It refuses to run from a network path - a UNC one by its shape, a drive letter mapped to a share by what the
    root's DriveInfo says it is - because cmd prints a warning of its own for a network working directory, which
    would sit on the screen beside the lines being measured; and in a session whose screen cannot be captured
    (locked, or an RDP session that was disconnected rather than logged off: the picture would be uniformly black).

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\run-all.ps1

    Run it from a PowerShell window on the machine, in the folder, at the desktop, and leave the keyboard and the
    mouse alone while the five windows open and close (18 s on the reference machine, five of those windows).
#>
[CmdletBinding()]
param(
    # Seconds between the window appearing and the picture. Four lines of batch reach `pause` in well under one.
    [int]$SettleSeconds = 2,
    # Seconds to wait for a started run to show a window of its own before another window, or the screen, is framed.
    [int]$WindowTimeoutSeconds = 10
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$Variants = @('1-as-shipped', '2-last-line-ascii', '3-without-chcp', '4-with-bom', '5-halfwidth-colon')
$Folder = $PSScriptRoot
$CmdExe = Join-Path $env:SystemRoot 'System32\cmd.exe'
$Utf8Bom = New-Object System.Text.UTF8Encoding($true)
$TerminalClass = 'CASCADIA_HOSTING_WINDOW_CLASS'

# ------------------------------------------------------------------------------------------------------ refusals
# A UNC path by its shape, and a drive letter mapped to a share by what the drive says it is - a copy put on `Z:\`
# would pass a test on the shape alone, and cmd treats it as a network path just the same.
$networkReason = ''
if ($Folder -like '\\*') { $networkReason = 'a UNC path' }
else {
    try {
        $root = [IO.Path]::GetPathRoot($Folder)
        if ($root) {
            $drive = New-Object System.IO.DriveInfo($root)
            if ($drive.DriveType -eq [IO.DriveType]::Network) { $networkReason = 'a drive letter mapped to a share (' + $root.TrimEnd('\') + ')' }
        }
    }
    catch { }
}
if ($networkReason) {
    Write-Output ("REFUSED: this folder is on a network path - " + $networkReason + " - at " + $Folder + ". cmd.exe prints a warning of its own for a network working directory, which would sit on the screen beside the lines being measured. Copy the folder to a local disk and run it from there.")
    exit 2
}
$missing = @($Variants | Where-Object { -not (Test-Path -LiteralPath (Join-Path $Folder ($_ + '.cmd'))) })
if ($missing.Count -gt 0) {
    Write-Output ('REFUSED: not all five variants are beside this script. Missing: ' + ($missing -join ', ') + '. Copy the whole folder.')
    exit 2
}

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type @"
using System; using System.Text; using System.Runtime.InteropServices;
public static class ProbeBacklog50Win32 {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
    [DllImport("user32.dll", SetLastError = true)] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}
"@

# ------------------------------------------------------------------------------------------------------- capture
function Save-Bitmap([System.Drawing.Rectangle]$Rect, [string]$Path) {
    $bitmap = New-Object System.Drawing.Bitmap($Rect.Width, $Rect.Height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen($Rect.Location, [System.Drawing.Point]::Empty, $Rect.Size)
        $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally { $graphics.Dispose(); $bitmap.Dispose() }
}
function Test-CaptureWorks {
    # A capture of a locked screen or a disconnected RDP session is uniformly black. A corner is not evidence of
    # that - a black wallpaper or one dark window would fail a corner test on a usable desktop - so the primary
    # screen is sampled on a grid, and one non-black pixel anywhere is enough. The same test walk_capture.ps1 makes.
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
function Get-WindowRectangle([IntPtr]$Handle) {
    if ($Handle -eq [IntPtr]::Zero) { return $null }
    $r = New-Object 'ProbeBacklog50Win32+RECT'
    if (-not [ProbeBacklog50Win32]::GetWindowRect($Handle, [ref]$r)) { return $null }
    $rect = New-Object System.Drawing.Rectangle($r.Left, $r.Top, ($r.Right - $r.Left), ($r.Bottom - $r.Top))
    # Clipped to the virtual screen: a window hanging off an edge would otherwise ask for pixels that are not there.
    $rect = [System.Drawing.Rectangle]::Intersect($rect, [System.Windows.Forms.SystemInformation]::VirtualScreen)
    if ($rect.Width -le 0 -or $rect.Height -le 0) { return $null }
    return $rect
}
function Get-WindowClass([IntPtr]$Handle) {
    if ($Handle -eq [IntPtr]::Zero) { return '' }
    $sb = New-Object System.Text.StringBuilder 256
    $n = [ProbeBacklog50Win32]::GetClassName($Handle, $sb, $sb.Capacity)
    if ($n -le 0) { return '' }
    return $sb.ToString()
}
function Get-HostDescription([string]$Class) {
    switch ($Class) {
        'ConsoleWindowClass' { return 'the classic console (conhost)' }
        $TerminalClass       { return 'Windows Terminal' }
        ''                   { return 'a window whose class could not be read' }
        default              { return ('a window of an unrecognised class, ' + $Class) }
    }
}
function Stop-Run([System.Diagnostics.Process]$Process, [IntPtr]$Target) {
    # `pause` is ended the way a person ends it - one key - but only when the key is certain to land in the window
    # the picture framed: that window has to be the foreground window at that moment. Otherwise, or if the run is
    # still there three seconds after the key, it is killed, and the exit code of a killed run is no measurement.
    if ($Process.HasExited) { return ('the run had already ended by itself, exit code ' + $Process.ExitCode) }
    if ($Target -ne [IntPtr]::Zero -and [ProbeBacklog50Win32]::GetForegroundWindow() -eq $Target) {
        try {
            [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
            if ($Process.WaitForExit(3000)) { return ('by one key from this script at its pause, the way a person ends it; exit code ' + $Process.ExitCode) }
        }
        catch { }
    }
    try { $Process.Kill(); [void]$Process.WaitForExit(5000) } catch { }
    return 'killed by this script after the picture, because a key could not be aimed at its window; its exit code is therefore not a measurement - the redirected run''s is'
}

# ------------------------------------------------------------------------------------------------- bytes and text
function Format-Bytes([byte[]]$Bytes) {
    if ($null -eq $Bytes -or $Bytes.Length -eq 0) { return @('(nothing)') }
    $lines = @()
    for ($o = 0; $o -lt $Bytes.Length; $o += 16) {
        $n = [Math]::Min(16, $Bytes.Length - $o)
        $hex = @(); $ascii = ''
        for ($i = $o; $i -lt ($o + $n); $i++) {
            $b = $Bytes[$i]
            $hex += ('{0:x2}' -f $b)
            if ($b -ge 32 -and $b -le 126) { $ascii += [string][char]$b } else { $ascii += '.' }
        }
        $lines += ('{0:x8}  {1,-47}  {2}' -f $o, ($hex -join ' '), $ascii)
    }
    return $lines
}
function Get-DecodedLines([byte[]]$Bytes, [int]$CodePage) {
    if ($null -eq $Bytes -or $Bytes.Length -eq 0) { return @('(nothing)') }
    try { $encoding = [System.Text.Encoding]::GetEncoding($CodePage) }
    catch { return @('(code page ' + $CodePage + ' is not available on this machine)') }
    return @($encoding.GetString($Bytes) -split "`r?`n")
}
function Get-FileFacts([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    $bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $crlf = 0; $bareLf = 0
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        if ($bytes[$i] -eq 10) { if ($i -gt 0 -and $bytes[$i - 1] -eq 13) { $crlf++ } else { $bareLf++ } }
    }
    $endings = 'mixed line endings'
    if ($bareLf -eq 0) { $endings = 'CRLF' } elseif ($crlf -eq 0) { $endings = 'LF' }
    $bomText = 'no BOM'
    if ($bom) { $bomText = 'UTF-8 with a BOM' }
    $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    return ('{0} bytes, {1}, {2}, sha256 {3}' -f $bytes.Length, $bomText, $endings, $hash)
}
function Get-RegistryValue([string]$Path, [string]$Name) {
    try {
        $item = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop
        return [string]$item.$Name
    }
    catch { return $null }
}
function Get-DelegationName([string]$Guid) {
    # The two values under HKCU\Console\%%Startup name the default console host on builds that can delegate
    # (Windows 11, and Windows 10 with a Windows Terminal that registers itself); absent, the classic console is
    # the only host. The host that actually opened each window is read from the window's class, below.
    if (-not $Guid) { return 'absent: the classic console is the only host on this build' }
    switch ($Guid.ToUpperInvariant()) {
        '{00000000-0000-0000-0000-000000000000}' { return 'let Windows decide' }
        '{B23D10C0-E52E-411E-9D5B-C09FDF709C7D}' { return 'the classic console (conhost)' }
        '{2EACA947-7F5F-4CFA-BA87-8F7FBEEFBE69}' { return 'Windows Terminal' }
        '{E12CFF52-A866-4C77-9A90-F570A7AA2C6B}' { return 'Windows Terminal' }
        default                                  { return ('unrecognised: ' + $Guid) }
    }
}
function Get-ProcessCommandLine([int]$ProcessId) {
    try {
        $filter = 'ProcessId = ' + $ProcessId
        $w = $null
        if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) { $w = Get-CimInstance -ClassName Win32_Process -Filter $filter -ErrorAction Stop }
        else { $w = Get-WmiObject -Class Win32_Process -Filter $filter -ErrorAction Stop }
        if ($null -ne $w -and $w.CommandLine) { return [string]$w.CommandLine }
    }
    catch { }
    return '(the command line could not be read)'
}
function Get-FileVersionLine([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return ($Path + ': not present') }
    $vi = (Get-Item -LiteralPath $Path).VersionInfo
    return ($Path + ': file version ' + $vi.FileVersion + ', product version ' + $vi.ProductVersion)
}

# ------------------------------------------------------------------------------------------ the session, checked
if (-not (Test-CaptureWorks)) {
    Write-Output "REFUSED: this session cannot be captured - the screen is locked, or an RDP session was disconnected rather than logged off. Log in at the desktop (or reconnect the session), then run this again."
    exit 2
}

$Stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$Results = Join-Path $Folder ('results_' + $env:COMPUTERNAME + '_' + $Stamp)
New-Item -ItemType Directory -Path $Results -Force | Out-Null
$EmptyStdin = Join-Path $Results 'stdin.empty'
[IO.File]::WriteAllText($EmptyStdin, '')

$Manifest = New-Object System.Collections.Generic.List[string]
function Note([string]$Line) { $script:Manifest.Add($Line); Write-Output $Line }

Note ('Backlog #50 probe - ' + $env:COMPUTERNAME + ' - ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'))
Note ('folder:  ' + $Folder)
Note ('results: ' + $Results)
Note 'Each variant runs twice, each time in a console of its own: once as a double-click, photographed at its pause; once redirected, its bytes kept.'

# ------------------------------------------------------------------------------------------------------- machine
$cv = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$nls = 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\CodePage'
$acp = Get-RegistryValue $nls 'ACP'
$oemcp = Get-RegistryValue $nls 'OEMCP'
$consoleCp = Get-RegistryValue 'HKCU:\Console' 'CodePage'
$delegationConsole = Get-RegistryValue 'HKCU:\Console\%%Startup' 'DelegationConsole'
$delegationTerminal = Get-RegistryValue 'HKCU:\Console\%%Startup' 'DelegationTerminal'
$titleKeys = @()
try {
    $titleKeys = @(Get-ChildItem -LiteralPath 'HKCU:\Console' -ErrorAction Stop | Where-Object { $null -ne $_.GetValue('CodePage') } | ForEach-Object { $_.PSChildName + ' = ' + $_.GetValue('CodePage') })
}
catch { }
$verLine = '(ver could not be run)'
try { $verLine = (@(& $CmdExe /c ver) | Where-Object { $_ }) -join ' ' } catch { }
$sessionName = '(none)'
if ($env:SESSIONNAME) { $sessionName = $env:SESSIONNAME }
$consoleCpText = 'not set'
if ($consoleCp) { $consoleCpText = $consoleCp }
$titleKeysText = 'none set'
if ($titleKeys.Count -gt 0) { $titleKeysText = $titleKeys -join '; ' }
$delegationConsoleText = 'absent'
if ($delegationConsole) { $delegationConsoleText = $delegationConsole }
$delegationTerminalText = 'absent'
if ($delegationTerminal) { $delegationTerminalText = $delegationTerminal }
$primary = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$virtual = [System.Windows.Forms.SystemInformation]::VirtualScreen
$machine = @()
$machine += ('machine:               ' + $env:COMPUTERNAME + ', user ' + $env:USERNAME + ', session ' + $sessionName)
$machine += ('when:                  ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'))
$machine += ('ver:                   ' + $verLine.Trim())
$machine += ('Windows:               ' + (Get-RegistryValue $cv 'ProductName') + ' ' + (Get-RegistryValue $cv 'DisplayVersion') + ' (ReleaseId ' + (Get-RegistryValue $cv 'ReleaseId') + '), build ' + (Get-RegistryValue $cv 'CurrentBuild') + '.' + (Get-RegistryValue $cv 'UBR') + ', edition ' + (Get-RegistryValue $cv 'EditionID') + ', ' + [Environment]::OSVersion.VersionString)
$machine += ('cmd.exe:               ' + (Get-FileVersionLine $CmdExe))
$machine += ('conhost.exe:           ' + (Get-FileVersionLine (Join-Path $env:SystemRoot 'System32\conhost.exe')))
$machine += ('ACP:                   ' + $acp)
$machine += ('OEMCP:                 ' + $oemcp)
$machine += ('HKCU\Console CodePage: ' + $consoleCpText)
$machine += ('per-title CodePage:    ' + $titleKeysText)
$machine += ('DelegationConsole:     ' + $delegationConsoleText + ' - ' + (Get-DelegationName $delegationConsole))
$machine += ('DelegationTerminal:    ' + $delegationTerminalText + ' - ' + (Get-DelegationName $delegationTerminal))
try { $machine += ('system locale:         ' + (Get-WinSystemLocale).Name) } catch { $machine += 'system locale:         (Get-WinSystemLocale not available)' }
$machine += ('culture / UI culture:  ' + (Get-Culture).Name + ' / ' + (Get-UICulture).Name)
try { $machine += ('display languages:     ' + (@(Get-WinUserLanguageList | ForEach-Object { $_.LanguageTag }) -join ', ')) } catch { $machine += 'display languages:     (Get-WinUserLanguageList not available)' }
$machine += ('screen:                primary ' + $primary.Width + 'x' + $primary.Height + ', virtual ' + $virtual.Width + 'x' + $virtual.Height)
$machine += ('PowerShell:            ' + $PSVersionTable.PSVersion.ToString() + '; this window''s console output code page ' + [Console]::OutputEncoding.CodePage + ' (context only: no run below inherits this console)')
[IO.File]::WriteAllLines((Join-Path $Results 'machine.txt'), [string[]]$machine, $Utf8Bom)
Note ''
Note '-- machine.txt'
foreach ($line in $machine) { Note ('    ' + $line) }

# ------------------------------------------------------------------------------------------------- the variants
$pictures = 0; $logs = 0
foreach ($v in $Variants) {
    $file = Join-Path $Folder ($v + '.cmd')
    $picture = Join-Path $Results ($v + '.png')
    Note ''
    Note ('== ' + $v)
    Note ('file:         ' + $file + ' - ' + (Get-FileFacts $file))

    # 1. The double-click: the file itself handed to the shell, its folder the working directory.
    $handle = [IntPtr]::Zero; $p = $null; $commandLine = ''; $appearedAfter = -1.0
    $hosted = [IntPtr]::Zero
    # The foreground window before the start, so that a terminal window that was already there is not mistaken
    # for the one this run opened. Where another process hosts the console the started process never owns a
    # window, and waiting the whole timeout for one it cannot have costs the run ten seconds a variant.
    $foregroundBefore = [ProbeBacklog50Win32]::GetForegroundWindow()
    $started = Get-Date
    try {
        $p = Start-Process -FilePath $file -WorkingDirectory $Folder -PassThru
        $commandLine = Get-ProcessCommandLine $p.Id
        $deadline = (Get-Date).AddSeconds($WindowTimeoutSeconds)
        while ((Get-Date) -lt $deadline) {
            try {
                if ($p.HasExited) { break }
                $p.Refresh()
                if ($p.MainWindowHandle -ne [IntPtr]::Zero) { $handle = $p.MainWindowHandle; $appearedAfter = ((Get-Date) - $started).TotalSeconds; break }
                $fg = [ProbeBacklog50Win32]::GetForegroundWindow()
                if ($fg -ne [IntPtr]::Zero -and $fg -ne $foregroundBefore -and (Get-WindowClass $fg) -eq $TerminalClass) {
                    $hosted = $fg; $appearedAfter = ((Get-Date) - $started).TotalSeconds; break
                }
            }
            catch { break }
            Start-Sleep -Milliseconds 200
        }
        Start-Sleep -Seconds $SettleSeconds
    }
    catch {
        Note ('double-click: not produced - the shell could not start the file: ' + $_.Exception.Message)
    }
    if ($null -ne $p) {
        Note ('double-click: started ' + $started.ToString('HH:mm:ss.fff') + ' as ' + $commandLine + ' in ' + $Folder)
        if ($p.HasExited) {
            Note ('screen:       not produced - the run ended before a picture could be taken, exit code ' + $p.ExitCode + '; a double-clicked window waits at its pause, so this is itself a finding')
        }
        else {
            $target = $handle; $framed = ''
            if ($target -ne [IntPtr]::Zero) {
                if ([ProbeBacklog50Win32]::IsIconic($target)) { [void][ProbeBacklog50Win32]::ShowWindow($target, 9) }   # SW_RESTORE
                [void][ProbeBacklog50Win32]::SetForegroundWindow($target)
                Start-Sleep -Milliseconds 500
                $class = Get-WindowClass $target
                $classText = '(unreadable)'
                if ($class) { $classText = $class }
                Note ('host:         the started process owns a window of class ' + $classText + ' - ' + (Get-HostDescription $class) + '; it appeared ' + ('{0:0.0}' -f $appearedAfter) + ' s after the start')
                $framed = 'the window''s own rectangle'
            }
            else {
                # No window of its own: another process hosts the console. If that host is the foreground window,
                # it is what the person would be looking at, so it is framed; else the screen is. A terminal that
                # came to the foreground during the wait is named with the seconds it took; one found only after
                # the timeout is named as that, because it may have been on the screen all along.
                $foreground = [ProbeBacklog50Win32]::GetForegroundWindow()
                $class = Get-WindowClass $foreground
                if ($class -eq $TerminalClass) {
                    $target = $foreground
                    $when = 'after ' + $WindowTimeoutSeconds + ' s, the whole wait'
                    if ($hosted -ne [IntPtr]::Zero -and $hosted -eq $foreground) { $when = 'after ' + ('{0:0.0}' -f $appearedAfter) + ' s, having come to the foreground during the wait' }
                    Note ('host:         the started process owned no window of its own; the foreground window is Windows Terminal (class ' + $class + '), which hosts it, ' + $when)
                    $framed = 'the terminal window''s rectangle (the foreground window)'
                }
                else {
                    $classText = '(unreadable)'
                    if ($class) { $classText = $class }
                    Note ('host:         the started process owned no window of its own after ' + $WindowTimeoutSeconds + ' s, and the foreground window is not a terminal (class ' + $classText + ') - see the delegation values in machine.txt')
                }
            }
            $rect = Get-WindowRectangle $target
            if ($null -ne $rect) {
                Save-Bitmap $rect $picture
                Note ('screen:       captured - ' + (Split-Path -Leaf $picture) + ', ' + $framed + ', ' + $rect.Width + 'x' + $rect.Height + ' at (' + $rect.X + ',' + $rect.Y + '), taken ' + $SettleSeconds + ' s after the wait ended')
            }
            else {
                Save-Bitmap $primary $picture
                Note ('screen:       captured - ' + (Split-Path -Leaf $picture) + ', the whole primary screen, because no window could be framed')
            }
            $pictures++
            Note ('ended:        ' + (Stop-Run $p $target))
        }
    }

    # 2. The redirected run, in a console of its own (no -NoNewWindow), its pause ended by an empty standard input.
    $out = Join-Path $Results ($v + '.log')
    $err = Join-Path $Results ($v + '-stderr.log')
    try {
        $q = Start-Process -FilePath $CmdExe -ArgumentList ('/c ""' + $file + '" "') -WorkingDirectory $Folder -RedirectStandardOutput $out -RedirectStandardError $err -RedirectStandardInput $EmptyStdin -PassThru -Wait
        $outBytes = [IO.File]::ReadAllBytes($out)
        $errBytes = [byte[]]@()
        if (Test-Path -LiteralPath $err) {
            $errBytes = [IO.File]::ReadAllBytes($err)
            if ($errBytes.Length -eq 0) { Remove-Item -LiteralPath $err -Force }
        }
        $logs++
        $errText = 'empty (no file kept)'
        if ($errBytes.Length -gt 0) { $errText = $errBytes.Length.ToString() + ' bytes in ' + (Split-Path -Leaf $err) }
        Note ('redirected:   cmd.exe /c ""' + $file + '" " in a new console, exit code ' + $q.ExitCode + '; standard output ' + $outBytes.Length + ' bytes in ' + (Split-Path -Leaf $out) + '; standard error ' + $errText)
        Note 'stdout bytes:'
        foreach ($line in (Format-Bytes $outBytes)) { Note ('    ' + $line) }
        Note 'stdout read as code page 65001 (UTF-8, what the shipped launcher sets):'
        foreach ($line in (Get-DecodedLines $outBytes 65001)) { Note ('    | ' + $line) }
        if ($oemcp) {
            Note ('stdout read as code page ' + $oemcp + ' (this machine''s OEMCP, what a console starts at):')
            foreach ($line in (Get-DecodedLines $outBytes ([int]$oemcp))) { Note ('    | ' + $line) }
        }
        Note 'stderr bytes:'
        foreach ($line in (Format-Bytes $errBytes)) { Note ('    ' + $line) }
        if ($errBytes.Length -gt 0) {
            Note 'stderr read as code page 65001:'
            foreach ($line in (Get-DecodedLines $errBytes 65001)) { Note ('    | ' + $line) }
            if ($oemcp) {
                Note ('stderr read as code page ' + $oemcp + ':')
                foreach ($line in (Get-DecodedLines $errBytes ([int]$oemcp))) { Note ('    | ' + $line) }
            }
        }
    }
    catch {
        Note ('redirected:   not produced - ' + $_.Exception.Message)
    }
}

# ------------------------------------------------------------------------------------------------------- the end
Remove-Item -LiteralPath $EmptyStdin -Force -ErrorAction SilentlyContinue
Note ''
Note ('pictures ' + $pictures + ' of ' + $Variants.Count + ', logs ' + $logs + ' of ' + $Variants.Count)
Note ('Send the whole folder back, ' + (Split-Path -Leaf $Results) + ' included. The screen is the evidence the item was raised on; the bytes say what the screen was made of.')
[IO.File]::WriteAllLines((Join-Path $Results 'run-all.txt'), [string[]]$Manifest, $Utf8Bom)
Write-Output ('manifest: ' + (Join-Path $Results 'run-all.txt'))
if ($pictures -eq $Variants.Count -and $logs -eq $Variants.Count) { exit 0 }
exit 1
