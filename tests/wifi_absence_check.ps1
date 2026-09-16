param(
    [ValidateSet("en-US", "zh-TW")][string]$Language = "en-US",
    [string]$ScriptPath = "",
    [string]$OutputRoot = "",
    [int]$TimeoutSeconds = 900
)

# wifi_absence_check.ps1 - what a computer with no wireless adapter should read, checked on such a computer.
#
# Not a chain step: it needs a machine with no radio, which no hosted runner is and the reference machine is not. It
# is the check backlog #69 asked for - run it on the guest that raised the item, or on any machine without a radio,
# and hand the bundle back.
#
# What this checks is NOT "are the three Wi-Fi rows Information". A run can reach that by accident, which is how the
# first verification of #69 passed while the fix could not have fired: on that boot the WLAN service happened to be
# running and answering. WLAN AutoConfig is trigger-started, so a computer with no wireless adapter is in one of two
# standings depending on what has touched the service since it started, and only one of them is the standing the item
# came from.
#
# Whether this machine has a radio is decided here by a copy of the rule, deliberately: a check that asked the
# code under test whether the computer has a wireless adapter would agree with it by construction.
#
# The run writes into a folder this check makes, named in a configuration this check writes. Two runs of the tool on
# one computer in the same second produce the same report NAME - Save-Reports has second precision - so in a shared
# folder no amount of care over the path identifies the writer, and the other run can overwrite the file between the
# child printing it and this reading it (PR #70 round 3). A folder nobody else knows about has one writer. It also
# settles where to look: the tool resolves ReportFolderName against its own folder, or takes it as it stands where it
# is rooted, so a configuration file beside the copy under test would otherwise decide where the report went. The
# price is that the run uses this check's configuration rather than the machine's, which is stated in the bundle.
#
# There is no mode that reads a report this check did not produce. The standing readings are of this machine now, so
# against someone else's report they would say nothing about the standing that produced it - and saying nothing while
# looking like an answer is the failure this script exists to prevent. A bundle already carries its own checks.txt.
#
# So this records the standing first - the WLAN service stopped, netsh refusing, and an adapter list with no wireless
# entry in it - runs the tool once, records the standing again, and then reads the run's own JSON report. The verdict
# is PASS only where the standing was reproduced AND all three rows read Information AND each of them carries what the
# adapter list answered. Everything it reads goes into a bundle beside this script, so the evidence travels.
#
# Windows PowerShell 5.1, no elevation, read-only apart from the tool's own reports and this bundle.

$ErrorActionPreference = "Continue"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($ScriptPath)) {
    # Beside this script where it was copied to a machine on its own; otherwise the checkout's copy of the language
    # asked for, since tests\ sits next to healthcheck\.
    $ScriptPath = Join-Path $here "NetworkHealthCheck.ps1"
    if (-not (Test-Path -LiteralPath $ScriptPath)) {
        $ScriptPath = Join-Path (Split-Path -Parent $here) ("healthcheck\{0}\NetworkHealthCheck.ps1" -f $Language)
    }
}
# Never the folder this script came from: in a checkout that is the repository. Every line below says where the
# bundle went, so a default under %TEMP% costs nothing. It is resolved to a full path because the folder inside it is
# written into a configuration the child reads, and the child resolves a relative folder against ITS own directory -
# which would put the reports beside the tool, in a checkout or inside the package (PR #70 round 4).
if ([string]::IsNullOrWhiteSpace($OutputRoot)) { $OutputRoot = Join-Path $env:TEMP "nhc-wifi-absence" }
[void](New-Item -ItemType Directory -Path $OutputRoot -Force)
$OutputRoot = (Resolve-Path -LiteralPath $OutputRoot).Path

# The bundle is this process's: a name built from the computer and the second alone is one two copies of this check
# started in the same second would share, and with it the folder their children write into - which is the whole
# guarantee this check rests on (PR #70 round 4). Milliseconds and the process id, as the campaign bundles are named,
# and the folder is created without -Force so that a name that somehow exists is an error rather than a share.
$stamp = Get-Date -Format "yyyyMMdd_HHmmss_fff"
$machine = ($env:COMPUTERNAME -replace '[^A-Za-z0-9_.-]', '_')
$bundle = Join-Path $OutputRoot ("wifi-absence_{0}_{1}_p{2}" -f $machine, $stamp, $PID)
try { [void](New-Item -ItemType Directory -Path $bundle -ErrorAction Stop) }
catch {
    Write-Host ("[FAIL] the bundle folder could not be made for this process alone: " + [string]$_.Exception.Message)
    exit 1
}

$checks = New-Object System.Collections.ArrayList
function Add-Check([string]$Id, [string]$Title, [bool]$Ok, [string]$Evidence) {
    [void]$checks.Add([pscustomobject]@{ Id = $Id; Title = $Title; Ok = $Ok; Evidence = $Evidence })
    $mark = "FAIL"
    if ($Ok) { $mark = "PASS" }
    Write-Host ("[{0}] {1} {2}" -f $mark, $Id.PadRight(3), $Title)
    if (-not [string]::IsNullOrWhiteSpace($Evidence)) { Write-Host ("        " + $Evidence) }
}
function Save-Text([string]$Name, [object]$Content) {
    $path = Join-Path $bundle $Name
    ($Content | Out-String -Width 200) | Set-Content -LiteralPath $path -Encoding UTF8
    return $path
}

Write-Host ""
Write-Host "backlog #69 - what a computer with no wireless adapter reads, checked on one"
Write-Host ("  computer   : {0}" -f $env:COMPUTERNAME)
Write-Host ("  os         : {0}" -f (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption)
Write-Host ("  powershell : {0}" -f $PSVersionTable.PSVersion)
Write-Host ("  tool       : {0}" -f $ScriptPath)
Write-Host ("  bundle     : {0}" -f $bundle)
Write-Host ""

# ---- the tool under test -------------------------------------------------------------------------------------------
# Verifying the wrong copy is the same mistake as verifying in the wrong standing, so the file is read before it is
# run: the version it reports, and the two functions the fix is made of.
$toolText = ""
if (Test-Path -LiteralPath $ScriptPath) { $toolText = Get-Content -LiteralPath $ScriptPath -Raw }
$toolVersion = "(not read)"
$m = [regex]::Match($toolText, '\$script:ToolVersion\s*=\s*"([^"]+)"')
if ($m.Success) { $toolVersion = $m.Groups[1].Value }
$hasInventory = $toolText -match 'function Get-WirelessAdapterInventory'
$hasVerdict = $toolText -match 'function Get-WirelessAbsenceVerdict'
Add-Check "T1" "the copy under test is the one carrying the fix, not an older package" `
    ($hasInventory -and $hasVerdict) `
    ("ToolVersion {0}; Get-WirelessAdapterInventory={1}, Get-WirelessAbsenceVerdict={2}" -f $toolVersion, $hasInventory, $hasVerdict)

# ---- the standing, before ------------------------------------------------------------------------------------------
$svcBefore = Get-Service -Name WlanSvc -ErrorAction SilentlyContinue
$svcBeforeText = "WlanSvc: not installed on this machine"
if ($null -ne $svcBefore) { $svcBeforeText = ("WlanSvc: Status={0}, StartType={1}" -f $svcBefore.Status, $svcBefore.StartType) }

$adapters = @()
$adapterError = ""
try { $adapters = @(Get-NetAdapter -ErrorAction Stop) } catch { $adapterError = [string]$_.Exception.Message }

function Test-WirelessEntry($adapter) {
    if ($null -eq $adapter) { return $false }
    foreach ($field in @("PhysicalMediaType", "MediaType")) {
        $value = [string]$adapter.$field
        if ($value -like "*Native 802.11*" -or $value -like "*802.11*") { return $true }
    }
    foreach ($pair in @(@{ Field = "NdisPhysicalMedium"; Want = 9 }, @{ Field = "InterfaceType"; Want = 71 })) {
        $raw = [string]$adapter.($pair.Field)
        $number = 0
        if ([int]::TryParse($raw, [ref]$number)) { if ($number -eq $pair.Want) { return $true } }
        elseif ($raw -like "*802*11*") { return $true }
    }
    return $false
}
$wireless = @($adapters | Where-Object { Test-WirelessEntry $_ })

$netshOut = @()
$netshExit = -999
try {
    $netshOut = @(& cmd.exe /c "netsh wlan show interfaces 2>&1")
    $netshExit = $LASTEXITCODE
}
catch { $netshOut = @("netsh could not be started: " + [string]$_.Exception.Message) }

$standingBefore = @()
$standingBefore += ("taken at {0}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))
$standingBefore += $svcBeforeText
$standingBefore += ""
$standingBefore += "Get-NetAdapter:"
if ($adapterError) { $standingBefore += ("  could not be read - " + $adapterError) }
$standingBefore += ($adapters | Select-Object Name, Status, InterfaceType, NdisPhysicalMedium, MediaType, PhysicalMediaType | Format-Table -AutoSize | Out-String -Width 200)
$standingBefore += ("wireless entries by the tool's own rule: {0}" -f $wireless.Count)
$standingBefore += ""
$standingBefore += ("netsh wlan show interfaces -> exit code {0}" -f $netshExit)
$standingBefore += $netshOut
[void](Save-Text "standing-before.txt" $standingBefore)

Add-Check "S1" "the WLAN service is stopped before the run - the standing the item came from" `
    ($null -ne $svcBefore -and [string]$svcBefore.Status -eq "Stopped") $svcBeforeText
Add-Check "S2" "the adapter list holds no wireless entry - this is a computer with no radio" `
    ($adapters.Count -gt 0 -and $wireless.Count -eq 0) `
    ("{0} adapter(s) listed, {1} of them wireless{2}" -f $adapters.Count, $wireless.Count, $(if ($adapterError) { "; Get-NetAdapter error: " + $adapterError } else { "" }))
Add-Check "S3" "netsh did not answer either - so neither Wi-Fi reader can be asked" `
    ($netshExit -ne 0) ("netsh exit code {0}" -f $netshExit)

# ---- where the run will write --------------------------------------------------------------------------------------
# An empty folder made for this run, and a configuration naming it, so that the report this check reads has exactly
# one writer (PR #70 rounds 1 to 3). The configuration is this check's, not the machine's: a sidecar file beside the
# copy under test would otherwise decide both what the run does and where it puts the answer.
$runReports = Join-Path $bundle "run-reports"
[void](New-Item -ItemType Directory -Path $runReports -Force)
$runReports = (Resolve-Path -LiteralPath $runReports).Path
# The tool writes NetworkHealthCheck_<stamp>_<computer>.json into that folder and falls back to a shared folder under
# %TEMP% where it cannot - which this check then refuses, correctly but confusingly. A bundle under a deep path is how
# that happens without anyone noticing: measured, a 190-character folder plus the report's name crosses MAX_PATH, both
# children fall back, and the run looks broken for a reason nobody reads (PR #70 round 4). Refused here instead, with
# the reason and what to do about it.
# Two files are written in there, and the report is not always the longer: Initialize-OutputDirectory first writes
# .write_test_<32 hex>.tmp to see whether it can, and those 48 characters beat the report's own name wherever the
# computer is called something short - seven characters or fewer (PR #70 round 5). The room asked for is the longest
# of the two, or the probe fails, the tool falls back to the shared folder, and the run is refused for a reason this
# preflight had just said was not there.
$reportNameLength = ("NetworkHealthCheck_yyyyMMdd_HHmmss_{0}.json" -f $machine).Length
$probeNameLength = (".write_test_{0}.tmp" -f ([guid]::NewGuid().ToString("N"))).Length
$longestNameLength = [Math]::Max($reportNameLength, $probeNameLength)
if (($runReports.Length + 1 + $longestNameLength) -ge 260) {
    Write-Host ("[FAIL] the bundle path is too long for the tool to write in: {0} characters, and the longest file it writes there - the report at {1} or its write probe at {2} - needs {3} more." -f $runReports.Length, $reportNameLength, $probeNameLength, ($longestNameLength + 1))
    Write-Host  "       Run this again with -OutputRoot pointing somewhere shorter, for example C:\nhc."
    exit 1
}
$configPath = Join-Path $bundle "run-config.json"
[void](Save-Text "run-config.json" (ConvertTo-Json @{ ReportFolderName = $runReports }))

# ---- the run -------------------------------------------------------------------------------------------------------
$runStart = Get-Date
$runOut = Join-Path $bundle "run-output.txt"
$runErr = Join-Path $bundle "run-errors.txt"
$ran = $false
$runNote = ""
if (-not (Test-Path -LiteralPath $ScriptPath)) {
    $runNote = "the tool was not found at " + $ScriptPath
}
else {
    Write-Host ("[ .. ] running the tool, console only - this takes a few minutes")
    $psExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    # One string, with the path in quotes: Start-Process joins an argument array with spaces and keeps none of the
    # quoting, so a checkout under a path with a space in it - this repository's own, for one - would hand the child a
    # truncated -File and never run the tool (PR #70 round 1).
    $arguments = ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -ConsoleOnly -ConfigPath "{1}"' -f $ScriptPath, $configPath)
    $proc = Start-Process -FilePath $psExe -PassThru -NoNewWindow -RedirectStandardOutput $runOut -RedirectStandardError $runErr `
        -ArgumentList $arguments
    # Touching the handle is what makes ExitCode readable after the wait.
    $null = $proc.Handle
    if ($proc.WaitForExit($TimeoutSeconds * 1000)) {
        # A run that ended in anything but 0 is not a run this check may read a report from.
        $ran = ($proc.ExitCode -eq 0)
        $runNote = ("exit code {0}, {1:n0} s" -f $proc.ExitCode, ((Get-Date) - $runStart).TotalSeconds)
    }
    else {
        try { $proc.Kill() } catch { }
        $runNote = ("the tool did not finish within {0} s and was stopped" -f $TimeoutSeconds)
    }
    Write-Host ("[ .. ] " + $runNote)
}

# ---- the standing, after -------------------------------------------------------------------------------------------
$svcAfter = Get-Service -Name WlanSvc -ErrorAction SilentlyContinue
$svcAfterText = "WlanSvc: not installed on this machine"
if ($null -ne $svcAfter) { $svcAfterText = ("WlanSvc: Status={0}, StartType={1}" -f $svcAfter.Status, $svcAfter.StartType) }
[void](Save-Text "standing-after.txt" @(("taken at {0}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss")), $svcAfterText, $runNote))
Add-Check "S4" "and it is still stopped afterwards - the run happened in that standing, not beside it" `
    ($null -ne $svcAfter -and [string]$svcAfter.Status -eq "Stopped") $svcAfterText

# ---- the report ----------------------------------------------------------------------------------------------------
# The child prints the path of the report it wrote, and that file has to be inside the folder made for this run.
# The path is read rather than the label beside it, because the label is in the tool's own language; a run that wrote
# somewhere else - the tool falls back to a shared folder under %TEMP% where its own is not writable - is refused
# rather than read, because a shared folder is one this check cannot call its own (PR #70 rounds 2 and 3).
$reportJson = $null
$reportNote = ""
if (-not $ran) { $reportNote = "there is no run to read a report from" }
else {
    $claimed = ""
    if (Test-Path -LiteralPath $runOut) {
        foreach ($line in @(Get-Content -LiteralPath $runOut -ErrorAction SilentlyContinue)) {
            $match = [regex]::Match([string]$line, '(?:[A-Za-z]:\\|\\\\)[^<>|]*\.json')
            if ($match.Success) { $claimed = $match.Value.Trim() }
        }
    }
    $runReportsFull = (Get-Item -LiteralPath $runReports).FullName
    if ([string]::IsNullOrWhiteSpace($claimed)) { $reportNote = "the run printed no JSON report path" }
    elseif (-not (Test-Path -LiteralPath $claimed)) { $reportNote = "the run named a report that is not there: " + $claimed }
    else {
        $claimedItem = Get-Item -LiteralPath $claimed
        if ((Split-Path -Parent $claimedItem.FullName) -ne $runReportsFull) {
            $reportNote = "the run wrote outside the folder made for it, so another writer could share it: " + $claimedItem.FullName
        }
        else { $reportJson = $claimedItem; $reportNote = "named by the run, in the folder made for it" }
    }
}

$report = $null
if ($null -ne $reportJson) {
    try { $report = Get-Content -LiteralPath $reportJson.FullName -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { $report = $null }
    foreach ($ext in @(".json", ".txt", ".html")) {
        $peer = [System.IO.Path]::ChangeExtension($reportJson.FullName, $ext)
        if (Test-Path -LiteralPath $peer) { Copy-Item -LiteralPath $peer -Destination $bundle -Force }
    }
}
Add-Check "C1" "the report read is the one this run named, in the folder this check made for it" `
    (($null -ne $report) -and $ran) `
    $(if ($null -ne $reportJson) { ("report: {0} - {1} ({2})" -f $reportJson.Name, $reportNote, $runNote) } else { ($reportNote + "; " + $runNote) })

$rows = @()
if ($null -ne $report) { $rows = @($report.Results) }
function Get-Row([string]$Tag) { return @($rows | Where-Object { [string]$_.Tag -eq $Tag }) }
# @() at the call site, not only inside the function: a one-row answer comes back as a scalar PSCustomObject,
# whose .Count is $null rather than 1, and an empty one comes back as nothing at all.
$radio = @(Get-Row "wifi")
$retry = @(Get-Row "wifi-retry")
$assoc = @(Get-Row "wifi-association")
$three = @()
if ($radio.Count -eq 1) { $three += $radio[0] }
if ($retry.Count -eq 1) { $three += $retry[0] }
if ($assoc.Count -eq 1) { $three += $assoc[0] }

Add-Check "C2" "the three Wi-Fi rows are there, one each" ($three.Count -eq 3) `
    ("wifi={0}, wifi-retry={1}, wifi-association={2}" -f $radio.Count, $retry.Count, $assoc.Count)

$statuses = @($three | ForEach-Object { [string]$_.Status })
Add-Check "C3" "all three read Information - the machine is the answer, not a reader that failed" `
    ($three.Count -eq 3 -and @($statuses | Where-Object { $_ -ne "INFO" }).Count -eq 0) `
    ("statuses: " + (($statuses -join ", ")))

$withHardware = @($three | Where-Object { ([string]$_.Details) -match "Native 802" })
Add-Check "C4" "each of them carries what the adapter list answered - the reading this fix is about" `
    ($three.Count -eq 3 -and $withHardware.Count -eq 3) `
    ("rows whose details name the adapter list's answer: {0} of {1}" -f $withHardware.Count, $three.Count)

$radioDetails = ""
if ($radio.Count -eq 1) { $radioDetails = [string]$radio[0].Details }
$serviceSilent = ($radioDetails -match "1062") -or ($radioDetails -match "wlanapi=(?!ok)")
Add-Check "C5" "and the WLAN service still did not answer - both readers silent, three rows agreeing anyway" `
    $serviceSilent `
    $(if ($radioDetails) { "radio row's service line: " + (@($radioDetails -split "`r?`n" | Where-Object { $_ -match "wlanapi|1062" }) -join " / ") } else { "no radio row to read" })

$messages = @($three | ForEach-Object { [string]$_.Message })
$distinct = @($messages | Sort-Object -Unique)
Add-Check "C6" "the three rows say it in their own words - no row borrowed another's sentence" `
    ($three.Count -eq 3 -and $distinct.Count -eq 3) ("{0} distinct sentence(s) over {1} row(s)" -f $distinct.Count, $three.Count)

$retryWeightless = $false
if ($retry.Count -eq 1) { $retryWeightless = [bool]$retry[0].Weightless }
Add-Check "C7" "the retries row still decides nothing" $retryWeightless ("Weightless = " + $retryWeightless)

# ---- the verdict ---------------------------------------------------------------------------------------------------
$standingOk = @($checks | Where-Object { ($_.Id -like "S*" -or $_.Id -like "T*") -and -not $_.Ok }).Count -eq 0
$behaviourOk = @($checks | Where-Object { $_.Id -like "C*" -and -not $_.Ok }).Count -eq 0
$failed = @($checks | Where-Object { -not $_.Ok })

$lines = @()
$lines += ("backlog #69 wireless-absence check - {0} - {1}" -f $env:COMPUTERNAME, (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))
$lines += ("tool: {0}" -f $ScriptPath)
$lines += ("run: {0}" -f $runNote)
$lines += ""
foreach ($c in $checks) {
    $mark = "FAIL"
    if ($c.Ok) { $mark = "PASS" }
    $lines += ("[{0}] {1} {2}" -f $mark, $c.Id.PadRight(3), $c.Title)
    if ($c.Evidence) { $lines += ("        " + $c.Evidence) }
}
$lines += ""
foreach ($row in $three) {
    $lines += ("--- {0} / {1} [{2}] {3}" -f $row.Category, $row.Check, $row.Status, $row.Tag)
    $lines += ("    " + [string]$row.Message)
    foreach ($d in @([string]$row.Details -split "`r?`n")) { if ($d) { $lines += ("      | " + $d) } }
    $lines += ""
}
$verdict = "INCONCLUSIVE - the copy under test or the standing was not what this check needs, so this run says nothing about backlog #69"
if ($standingOk -and $behaviourOk) { $verdict = "PASS - the standing was reproduced and all three rows read the machine" }
elseif ($standingOk -and -not $behaviourOk) { $verdict = "FAIL - the standing was reproduced and the rows did not read it" }
$lines += ("VERDICT: " + $verdict)
[void](Save-Text "checks.txt" $lines)
$checks | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $bundle "checks.json") -Encoding UTF8

# The bundle is the deliverable: a check that answered and could not hand the evidence over has not finished, so a
# failed archive is a failure of this run and not a line of text (PR #70 round 5). The note goes into the bundle's own
# checks.txt as well, since that file is then the only copy of it.
# The path and what is said about it are two things: reusing one variable for both is how a line came to report a
# removal it had not looked for (PR #70 round 7).
$zipPath = $bundle + ".zip"
$zip = $zipPath
$zipOk = $true
$zipNote = ""
try {
    # -ErrorAction Stop on both, because catch takes terminating errors only and this script runs with
    # $ErrorActionPreference = "Continue": a file that became unreadable while the bundle was being enumerated
    # would otherwise be reported, skipped, and left with $zipOk true beside an incomplete archive (PR #70
    # round 6). Invoke-PackageAcceptance.ps1 has done it this way since backlog #19.
    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force -ErrorAction Stop }
    Compress-Archive -Path (Join-Path $bundle "*") -DestinationPath $zipPath -Force -ErrorAction Stop
}
catch {
    $zipOk = $false
    # The exception alone can be a bare NullReferenceException, which says nothing about where it was writing.
    $zipNote = ("{0}: {1}" -f $zipPath, [string]$_.Exception.Message)
    # A partial archive is worse than none, because it looks like the evidence: measured, Compress-Archive without
    # -ErrorAction Stop reports an unreadable source file and writes the rest of them anyway. And a removal is not a
    # removal until the file is gone - this one is terminating for the same reason as the two above, and the file is
    # looked for afterwards rather than assumed away, because something else can hold a new archive open (round 7).
    if (Test-Path -LiteralPath $zipPath) {
        try { Remove-Item -LiteralPath $zipPath -Force -ErrorAction Stop } catch { }
    }
    if (Test-Path -LiteralPath $zipPath) {
        $zip = ("(a partial archive is still at {0})" -f $zipPath)
        $zipNote = $zipNote + "; and what it left there could not be removed"
    }
    else { $zip = "(not archived)" }
    $failLine = "[FAIL] B1  the evidence could not be put in one file that travels: " + $zipNote
    Write-Host $failLine
    try { Add-Content -LiteralPath (Join-Path $bundle "checks.txt") -Value $failLine -Encoding UTF8 } catch { }
}

Write-Host ""
Write-Host ("VERDICT: " + $verdict + $(if ($zipOk) { "" } else { " - and the evidence could not be archived" }))
if ($failed.Count -gt 0) {
    Write-Host ("what did not hold: " + (@($failed | ForEach-Object { $_.Id }) -join ", "))
    if (-not $standingOk) {
        Write-Host "  the C checks only mean something in that standing - on a computer with a working radio they are"
        Write-Host "  expected to fail, and nothing here is a finding against the tool."
        Write-Host "  S1/S2/S4: reboot and touch nothing to do with the network, then run this again; or stop WlanSvc"
        Write-Host "  as an administrator (it is trigger-started, so stopping it changes no setting)."
    }
}
Write-Host ("bundle : " + $bundle)
Write-Host ("zip    : " + $zip)
Write-Host ""
if ($standingOk -and $behaviourOk -and $zipOk) { exit 0 }
exit 1
