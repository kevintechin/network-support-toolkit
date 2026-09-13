param([string]$PackageDir, [string]$WorkDir)
# The six language launchers (user, IT, console x en-US, zh-TW), started like a double-click (cmd.exe /s /c, stdin
# from NUL so that a trailing pause returns) from a staged copy, through every reason they can stop for and through
# the runs that must leave nothing behind. No network, no window and no policy are needed for any case but the
# fallback run at the end. Three backlog items are measured here:
#   #28 (since 1.2.3): the suggested action follows the reason - a missing program file -> extract the complete ZIP
#       (the one case where it fits); exit code 3 -> the environment report, with the Error line naming exit code 3;
#       any other exit code -> allowing NetworkHealthCheck.ps1, never the ZIP for a run that did start.
#   #47 (1.2.14): PowerShell's error stream is kept in PowerShellMessages_<stamp>.txt beside the launcher, printed
#       back under the error and named by the error report and by the suggested action; a run that printed nothing
#       there leaves no such file; the error report is LauncherError_<stamp>.txt, so a second attempt is a second
#       file; where the launcher's folder cannot be written both go to %TEMP% under the NetworkHealthCheck_ prefix.
#   #44 (1.2.14): the report's Date/time line names this computer's short-date pattern, read from the registry.
#   #34 (1.2.14): a run whose window could not open falls back to console mode and, with its standard input
#       redirected, ends without waiting for a key - the paths on the screen, exit 0, nothing written beside the
#       launcher. The interactive wait itself needs a real console and is checked by hand (VALIDATION.md).
# Every staged copy sits under a folder named "launcher (1)": a browser's second download is extracted to a folder
# named like the ZIP plus " (1)", and a ")" inside a parenthesised batch block ends the block, which is how a report
# written from inside one would have stopped halfway on exactly that machine.
# The assertions read labelled lines - "Suggested action: " and the other labels, the zh-TW ones spelled as character
# codes so that this file stays ASCII (see env_guard_check.ps1) - because the Script: line names NetworkHealthCheck.ps1
# in every file and would satisfy a whole-file match for nothing.
#   -PackageDir: the package root holding en-US\ and zh-TW\
#   -WorkDir:    an existing folder for the staged copies
# Example: tests\launcher_check.ps1 -PackageDir healthcheck -WorkDir $env:TEMP\nhc-launcher
$ErrorActionPreference = 'Stop'

$passes = 0
$fails = 0
function Assert-Equal($name, $actual, $expected) {
    if ("$actual" -eq "$expected") { $script:passes++; Write-Output "[PASS] $name -> $actual" }
    else { $script:fails++; Write-Output "[FAIL] $name -> got '$actual', expected '$expected'" }
}
function Assert-True($name, $condition, $detail) {
    if ($condition) { $script:passes++; Write-Output "[PASS] $name" }
    else { $script:fails++; Write-Output "[FAIL] $name -> $detail" }
}

$PackageDir = (Resolve-Path -LiteralPath $PackageDir).Path
$WorkDir = (Resolve-Path -LiteralPath $WorkDir).Path
$cmdExe = Join-Path $env:SystemRoot 'System32\cmd.exe'
$icacls = Join-Path $env:SystemRoot 'System32\icacls.exe'
$utf8Bom = New-Object System.Text.UTF8Encoding($true)
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$stageRoot = Join-Path $WorkDir 'launcher (1)'

# The labels, per language. zh-TW: "suggestion", "error", "date/time", "PowerShell messages", "JSON report", each with
# a full-width colon; the closing full-width parenthesis of the short-date pattern.
$labels = @{
    'en-US' = @{ Suggested = 'Suggested action: '; Error = 'Error: '; Date = 'Date/time: '; Messages = 'PowerShell messages: '; Json = 'JSON report: '; Close = ')' }
    'zh-TW' = @{
        Suggested = [string]([char]0x5EFA + [char]0x8B70 + [char]0xFF1A)
        Error     = [string]([char]0x932F + [char]0x8AA4 + [char]0xFF1A)
        Date      = [string]([char]0x65E5 + [char]0x671F + [char]0x6642 + [char]0x9593 + [char]0xFF1A)
        Messages  = 'PowerShell ' + [string]([char]0x8A0A + [char]0x606F + [char]0xFF1A)
        Json      = 'JSON ' + [string]([char]0x5831 + [char]0x544A + [char]0xFF1A)
        Close     = [string][char]0xFF09
    }
}
# The pattern the launcher reads from the same place. $null when the value cannot be read, which the report then omits.
$shortDate = $null
try { $shortDate = [string](Get-ItemProperty -LiteralPath 'HKCU:\Control Panel\International' -Name sShortDate -ErrorAction Stop).sShortDate } catch { $shortDate = $null }
if ([string]::IsNullOrWhiteSpace($shortDate)) { $shortDate = $null }
Write-Output ("short-date pattern of this machine: " + $(if ($null -eq $shortDate) { '(not readable)' } else { $shortDate }))

$marker = 'nhc-launcher-check: what PowerShell said'
$stderrStub = '[Console]::Error.WriteLine("' + $marker + '"); exit 1'

function Invoke-Launcher([string]$Stage, [string]$Launcher) {
    # Like a double-click, stdin from NUL; the launchers switch the console to UTF-8 (chcp 65001) before they print,
    # so their output is read as UTF-8. Returns the output lines and the exit code.
    $savedEncoding = [Console]::OutputEncoding
    $ErrorActionPreference = 'Continue'   # a nonzero exit code is the expected result here, not a terminating error
    try {
        [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
        $output = @(& $cmdExe /s /c ('"' + (Join-Path $Stage $Launcher) + '" <nul') 2>&1 | ForEach-Object { [string]$_ })
        $code = $LASTEXITCODE
    }
    finally {
        [Console]::OutputEncoding = $savedEncoding
        $ErrorActionPreference = 'Stop'
    }
    return @{ Output = $output; ExitCode = $code }
}
function New-Stage([string]$Name, [string]$Lang, [string]$Launcher, [string]$Stub) {
    $stage = Join-Path $stageRoot $Name
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    Copy-Item -LiteralPath (Join-Path $PackageDir ($Lang + '\' + $Launcher)) -Destination $stage
    # A [string] parameter turns $null into '': the missing-program case must write no stub at all.
    if (-not [string]::IsNullOrEmpty($Stub)) { [IO.File]::WriteAllText((Join-Path $stage 'NetworkHealthCheck.ps1'), $Stub + "`r`n", $utf8Bom) }
    return $stage
}
function Get-Reports([string]$Dir) { @(Get-ChildItem -LiteralPath $Dir -Filter 'LauncherError_*.txt' -File -ErrorAction SilentlyContinue | Sort-Object Name) }
function Get-Messages([string]$Dir) { @(Get-ChildItem -LiteralPath $Dir -Filter 'PowerShellMessages_*.txt' -File -ErrorAction SilentlyContinue | Sort-Object Name) }
function Get-TempFiles([string]$Filter, [datetime]$Since) { @(Get-ChildItem -LiteralPath $env:TEMP -Filter $Filter -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $Since }) }
function Get-Line([string[]]$Lines, [string]$Label) { @($Lines | Where-Object { $_.StartsWith($Label) }) }   # callers wrap the result in @(): one line comes back as a string

# The zh-TW labels spelled above must be the launcher's own: a wrong character code would make every zh-TW case
# fail for the label rather than for the launcher, so the spelling is checked against the file first.
$zhLauncher = [IO.File]::ReadAllText((Join-Path $PackageDir 'zh-TW\Start-NetworkCheck.cmd'), $utf8NoBom)
foreach ($k in @('Suggested', 'Error', 'Date', 'Messages')) {
    Assert-True ("zh-TW label '{0}' as spelled here is in the zh-TW launcher" -f $k) ($zhLauncher.Contains($labels['zh-TW'][$k])) 'character codes and launcher disagree'
}
$zhScript = [IO.File]::ReadAllText((Join-Path $PackageDir 'zh-TW\NetworkHealthCheck.ps1'), $utf8Bom)
Assert-True "zh-TW label 'Json' as spelled here is in the zh-TW script" ($zhScript.Contains($labels['zh-TW']['Json'])) 'character codes and script disagree'

$reasons = @(
    @{ Name = 'missing program file'; Stub = $null;       Expect = 'ZIP';                            Reject = 'NetworkHealthCheck_ENVIRONMENT_'; Messages = $false },
    @{ Name = 'exit code 3';          Stub = 'exit 3';    Expect = 'NetworkHealthCheck_ENVIRONMENT_'; Reject = 'ZIP';                            Messages = $false },
    @{ Name = 'exit code 1';          Stub = $stderrStub; Expect = 'NetworkHealthCheck\.ps1';         Reject = 'ZIP';                            Messages = $true }
)

foreach ($lang in @('en-US', 'zh-TW')) {
    $L = $labels[$lang]
    foreach ($launcher in @('Start-NetworkCheck.cmd', 'Start-NetworkCheck-IT.cmd', 'Start-NetworkCheck-Console.cmd')) {
        foreach ($reason in $reasons) {
            $case = '{0} {1}, {2}' -f $lang, $launcher, $reason.Name
            $stage = New-Stage ($lang + '_' + ($launcher -replace '\.cmd$', '') + '_' + ($reason.Name -replace '[^A-Za-z0-9]+', '-')) $lang $launcher $reason.Stub
            $tempStart = Get-Date
            $r = Invoke-Launcher $stage $launcher
            $output = $r.Output

            Assert-Equal "$case - the launcher exits 1" $r.ExitCode 1
            $reports = Get-Reports $stage
            Assert-Equal "$case - exactly one LauncherError_<stamp>.txt is written next to the launcher" $reports.Count 1
            $messages = Get-Messages $stage
            if ($reports.Count -eq 1) {
                $file = $reports[0].FullName
                Assert-True "$case - the report's name is LauncherError_<digits>.txt" ($reports[0].Name -match '^LauncherError_\d+\.txt$') $reports[0].Name
                $lines = @(Get-Content -LiteralPath $file -Encoding UTF8)
                $suggested = @(Get-Line $lines $L.Suggested)
                Assert-Equal "$case - one suggested-action line in the file" $suggested.Count 1
                $line = [string]$(if ($suggested.Count) { $suggested[0] } else { '' })
                Assert-True ("$case - the suggestion fits the reason ({0})" -f $reason.Expect) ($line -match $reason.Expect) $line
                Assert-True ("$case - the suggestion is not another reason's ({0})" -f $reason.Reject) ($line -notmatch $reason.Reject) $line
                if ($reason.Stub -eq 'exit 3') {
                    $errorLine = [string]@(Get-Line $lines $L.Error)[0]
                    Assert-True "$case - the Error line names exit code 3" ($errorLine -match ' 3(?!\d)') $errorLine
                }
                # #44: the Date/time line states the pattern the date part is in, beside whatever else the shell printed.
                $dateLines = @(Get-Line $lines $L.Date)
                Assert-Equal "$case - one Date/time line" $dateLines.Count 1
                $dateLine = [string]$(if ($dateLines.Count) { $dateLines[0] } else { '' })
                if ($null -ne $shortDate) {
                    Assert-True "$case - the Date/time line names this computer's short-date pattern" ($dateLine.EndsWith($shortDate + $L.Close)) $dateLine
                }
                else {
                    Assert-True "$case - no pattern was readable, and the Date/time line carries none" (-not $dateLine.Contains('(') -and -not $dateLine.Contains($L.Close)) $dateLine
                }
                Assert-True "$case - the Folder line quotes the staged folder, parentheses and all" (@($lines | Where-Object { $_.EndsWith($stage + '\') }).Count -eq 1) (($lines | Select-Object -First 8) -join ' | ')
                # #47: the messages line, and the file it names when PowerShell printed something.
                $messageLines = @(Get-Line $lines $L.Messages)
                Assert-Equal "$case - one PowerShell-messages line in the file" $messageLines.Count 1
                $messageLine = [string]$(if ($messageLines.Count) { $messageLines[0] } else { '' })
                if ($reason.Messages) {
                    Assert-Equal "$case - exactly one PowerShellMessages_<stamp>.txt beside the launcher" $messages.Count 1
                    if ($messages.Count -eq 1) {
                        $stampOfReport = $reports[0].Name -replace '^LauncherError_(\d+)\.txt$', '$1'
                        $stampOfMessages = $messages[0].Name -replace '^PowerShellMessages_(\d+)\.txt$', '$1'
                        Assert-Equal "$case - the two files carry the same stamp" $stampOfMessages $stampOfReport
                        $said = [IO.File]::ReadAllText($messages[0].FullName, $utf8NoBom)
                        Assert-True "$case - the messages file holds what PowerShell printed on its error stream" ($said.Contains($marker)) $said
                        Assert-True "$case - the messages line names that file" ($messageLine.EndsWith($messages[0].FullName)) $messageLine
                        Assert-True "$case - the suggested action names that file" ($line.Contains($messages[0].FullName)) $line
                        Assert-True "$case - the screen prints what PowerShell said back, under the error" (@($output | Where-Object { $_.Contains($marker) }).Count -ge 1) ((@($output | Select-Object -Last 8)) -join ' | ')
                    }
                }
                else {
                    Assert-Equal "$case - no PowerShellMessages file is left beside the launcher" $messages.Count 0
                    Assert-True "$case - the messages line says there is none" (-not $messageLine.Contains('PowerShellMessages_')) $messageLine
                    Assert-True "$case - the screen prints nothing from PowerShell" (@($output | Where-Object { $_.Contains($marker) }).Count -eq 0) ((@($output | Select-Object -Last 8)) -join ' | ')
                }
            }
            Assert-True "$case - the screen shows the suggestion under the reason" (@(Get-Line $output $L.Suggested).Count -ge 1) ((@($output | Select-Object -Last 6)) -join ' | ')
            Assert-Equal "$case - nothing went to the temporary folder" (@(Get-TempFiles 'NetworkHealthCheck_LauncherError_*.txt' $tempStart) + @(Get-TempFiles 'NetworkHealthCheck_PowerShellMessages_*.txt' $tempStart)).Count 0

            if ($reason.Name -eq 'missing program file') {
                # #47: a second attempt is a second file, and the later one sorts after the earlier one on the same machine.
                $r2 = Invoke-Launcher $stage $launcher
                $reports2 = Get-Reports $stage
                Assert-Equal "$case - a second attempt still exits 1" $r2.ExitCode 1
                Assert-Equal "$case - a second attempt is a second report, the first one kept" $reports2.Count 2
                if ($reports2.Count -eq 2) {
                    Assert-True "$case - the second report sorts after the first" ([string]::CompareOrdinal($reports2[1].Name, $reports2[0].Name) -gt 0) ($reports2[0].Name + ' / ' + $reports2[1].Name)
                }
            }
        }

        # A run that ends with exit code 0 leaves nothing beside the launcher: no error report, and the empty messages
        # file deleted. The console launcher's trailing pause reads from NUL.
        $case = '{0} {1}, exit code 0' -f $lang, $launcher
        $stage = New-Stage ($lang + '_' + ($launcher -replace '\.cmd$', '') + '_exit-code-0') $lang $launcher 'exit 0'
        $tempStart = Get-Date
        $r = Invoke-Launcher $stage $launcher
        Assert-Equal "$case - the launcher exits 0" $r.ExitCode 0
        Assert-Equal "$case - no error report" (Get-Reports $stage).Count 0
        Assert-Equal "$case - no messages file: the empty capture was deleted" (Get-Messages $stage).Count 0
        Assert-Equal "$case - nothing went to the temporary folder" (@(Get-TempFiles 'NetworkHealthCheck_LauncherError_*.txt' $tempStart) + @(Get-TempFiles 'NetworkHealthCheck_PowerShellMessages_*.txt' $tempStart)).Count 0
    }

    # #47, the other place: where the launcher's own folder cannot be written, both files go to %TEMP% under the
    # NetworkHealthCheck_ prefix, and the screen names the report there. The stage is denied for writing (WD, AD) to
    # this account for the run alone; the deny is removed whatever happens.
    $case = '{0} Start-NetworkCheck.cmd, exit code 1 in a folder that cannot be written' -f $lang
    $stage = New-Stage ($lang + '_Start-NetworkCheck_unwritable-folder') $lang 'Start-NetworkCheck.cmd' $stderrStub
    $tempStart = Get-Date
    $denied = $false
    try {
        & $icacls $stage '/deny' ($env:USERNAME + ':(WD,AD)') 2>&1 | Out-Null
        $denied = ($LASTEXITCODE -eq 0)
        if ($denied) { $r = Invoke-Launcher $stage 'Start-NetworkCheck.cmd' }
    }
    finally {
        & $icacls $stage '/remove:d' $env:USERNAME 2>&1 | Out-Null
    }
    if (-not $denied) {
        Write-Output "[SKIP] $case - icacls could not deny writing on the staged folder"
    }
    else {
        Assert-Equal "$case - the launcher exits 1" $r.ExitCode 1
        Assert-Equal "$case - nothing was written beside the launcher" ((Get-Reports $stage).Count + (Get-Messages $stage).Count) 0
        $tempReports = @(Get-TempFiles 'NetworkHealthCheck_LauncherError_*.txt' $tempStart)
        $tempMessages = @(Get-TempFiles 'NetworkHealthCheck_PowerShellMessages_*.txt' $tempStart)
        Assert-Equal "$case - one NetworkHealthCheck_LauncherError_<stamp>.txt in the temporary folder" $tempReports.Count 1
        Assert-Equal "$case - one NetworkHealthCheck_PowerShellMessages_<stamp>.txt in the temporary folder" $tempMessages.Count 1
        if ($tempReports.Count -eq 1 -and $tempMessages.Count -eq 1) {
            $lines = @(Get-Content -LiteralPath $tempReports[0].FullName -Encoding UTF8)
            Assert-True "$case - the report carries the same lines as one beside the launcher, the pattern included" (@(Get-Line $lines $L.Date).Count -eq 1 -and @(Get-Line $lines $L.Messages).Count -eq 1 -and @(Get-Line $lines $L.Suggested).Count -eq 1 -and ($null -eq $shortDate -or [string]@(Get-Line $lines $L.Date)[0] -like ('*' + $shortDate + '*'))) ($lines -join ' | ')
            Assert-True "$case - the messages line names the file in the temporary folder" ([string]@(Get-Line $lines $L.Messages)[0] -like ('*' + $tempMessages[0].FullName)) ([string]@(Get-Line $lines $L.Messages)[0])
            Assert-True "$case - the messages file holds what PowerShell printed" ([IO.File]::ReadAllText($tempMessages[0].FullName, $utf8NoBom).Contains($marker)) 'marker missing'
            Assert-True "$case - the screen names the report in the temporary folder" (@($r.Output | Where-Object { $_.Contains($tempReports[0].FullName) }).Count -ge 1) ((@($r.Output | Select-Object -Last 6)) -join ' | ')
        }
        foreach ($f in @($tempReports) + @($tempMessages)) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue }
    }
}

# #34: the fallback run. A staged copy of the whole language folder whose Initialize-Gui returns $false at once (the
# shape a machine without a usable desktop produces), started through the user launcher with the standard input
# redirected, on a configuration trimmed to one ping target and a one-second window so that the case measures the
# fallback and not the network. It must end by itself - the wait for a key is gated on the input not being redirected -
# with the report paths on the screen, exit 0, a JSON report written, and nothing beside the launcher.
function Invoke-LauncherWithTimeout([string]$Stage, [string]$Launcher, [int]$TimeoutMs) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $cmdExe
    $psi.Arguments = '/s /c "' + '"' + (Join-Path $Stage $Launcher) + '"' + '"'
    $psi.WorkingDirectory = $Stage
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $utf8NoBom
    $psi.StandardErrorEncoding = $utf8NoBom
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.StandardInput.Close()
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    $hung = $false
    if (-not $p.WaitForExit($TimeoutMs)) { $hung = $true; try { $p.Kill() } catch { } }
    $p.WaitForExit()
    $lines = @(($outTask.Result + "`n" + $errTask.Result) -split "`r?`n")
    return @{ Output = $lines; ExitCode = $p.ExitCode; Hung = $hung }
}
foreach ($lang in @('en-US', 'zh-TW')) {
    $L = $labels[$lang]
    $case = '{0} Start-NetworkCheck.cmd, fallback to console mode' -f $lang
    $stage = Join-Path $stageRoot ($lang + '_Start-NetworkCheck_fallback')
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    Get-ChildItem -LiteralPath (Join-Path $PackageDir $lang) -File | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $stage }
    # Initialize-Gui returns $false before it touches Windows Forms: the line after the function's opening brace.
    $scriptPath = Join-Path $stage 'NetworkHealthCheck.ps1'
    $text = [IO.File]::ReadAllText($scriptPath, $utf8Bom)
    $head = 'function Initialize-Gui {' + "`r`n"
    Assert-Equal "$case - the staged script has one Initialize-Gui to stub" ([regex]::Matches($text, [regex]::Escape($head)).Count) 1
    $text = $text.Replace($head, $head + '    $script:GuiAvailable = $false; [void]$script:StartupMessages.Add("staged by tests/launcher_check.ps1: the window is made to fail"); return $false' + "`r`n")
    [IO.File]::WriteAllText($scriptPath, $text, $utf8Bom)
    $configPath = Join-Path $stage 'NetworkHealthCheck.config.json'
    $config = [IO.File]::ReadAllText($configPath, $utf8Bom) | ConvertFrom-Json
    $config.Tests.PingCount = 1
    $config.Tests.PingCountMaximum = 1
    $config.Tests.RetransmissionSampleSeconds = 1
    $config.Tests.RetransmissionIntervalSeconds = 0
    $config.Tests.PingTargets = @($config.Tests.PingTargets | Where-Object { $_.Address -eq 'AUTO_GATEWAY' })
    $config.Tests.DnsNames = @()
    $config.Tests.TcpTargets = @()
    $config.Tests.HttpTargets = @()
    foreach ($p in @($config.Checks.PSObject.Properties)) { if ($p.Value -is [bool]) { $config.Checks.($p.Name) = $false } }
    $config.Checks.TracerouteHops = 1
    [IO.File]::WriteAllText($configPath, ($config | ConvertTo-Json -Depth 10), $utf8Bom)
    $started = Get-Date
    $r = Invoke-LauncherWithTimeout $stage 'Start-NetworkCheck.cmd' 300000
    Assert-True "$case - the run ended by itself within 300 s" (-not $r.Hung) 'killed at the timeout: the fallback waited for a key with its input redirected'
    Assert-Equal "$case - the launcher exits 0" $r.ExitCode 0
    Assert-True "$case - the report paths are on the screen" (@(Get-Line $r.Output $L.Json).Count -eq 1) ((@($r.Output | Select-Object -Last 8)) -join ' | ')
    $json = @(Get-ChildItem -LiteralPath (Join-Path $stage 'Reports') -Filter '*.json' -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $started })
    Assert-Equal "$case - one JSON report was written" $json.Count 1
    Assert-Equal "$case - nothing beside the launcher: no error report, no messages file" ((Get-Reports $stage).Count + (Get-Messages $stage).Count) 0
    Assert-Equal "$case - nothing went to the temporary folder" (@(Get-TempFiles 'NetworkHealthCheck_LauncherError_*.txt' $started) + @(Get-TempFiles 'NetworkHealthCheck_PowerShellMessages_*.txt' $started)).Count 0
}

Write-Output ("Summary: {0} passed, {1} failed" -f $passes, $fails)
exit $fails
