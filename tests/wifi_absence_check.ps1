param(
    [ValidateSet("en-US", "zh-TW")][string]$Language = "en-US",
    [string]$ScriptPath = "",
    [string]$OutputRoot = "",
    [int]$TimeoutSeconds = 900,
    [switch]$NoRun
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
# bundle went, so a default under %TEMP% costs nothing.
if ([string]::IsNullOrWhiteSpace($OutputRoot)) { $OutputRoot = Join-Path $env:TEMP "nhc-wifi-absence" }
[void](New-Item -ItemType Directory -Path $OutputRoot -Force)

$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$machine = ($env:COMPUTERNAME -replace '[^A-Za-z0-9_.-]', '_')
$bundle = Join-Path $OutputRoot ("wifi-absence_{0}_{1}" -f $machine, $stamp)
[void](New-Item -ItemType Directory -Path $bundle -Force)

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

# ---- what was there before the run ---------------------------------------------------------------------------------
# The report this check reads has to be the one this run wrote. A child that died, or one killed on the timeout, would
# otherwise leave the newest report of some earlier attempt to be read as this run's - and every check below would
# pass against it, which is the mistake this whole script exists to prevent (PR #70 round 1).
$toolDir = Split-Path -Parent $ScriptPath
$reportDirs = @()
if (-not [string]::IsNullOrWhiteSpace($toolDir)) { $reportDirs += (Join-Path $toolDir "Reports") }
$reportDirs += (Join-Path $env:TEMP "NetworkHealthCheck\Reports")
$reportsBefore = @{}
foreach ($dir in $reportDirs) {
    if (-not (Test-Path -LiteralPath $dir)) { continue }
    foreach ($file in @(Get-ChildItem -LiteralPath $dir -Filter "*.json" -ErrorAction SilentlyContinue)) {
        $reportsBefore[$file.FullName] = $true
    }
}

# ---- the run -------------------------------------------------------------------------------------------------------
$runStart = Get-Date
$runOut = Join-Path $bundle "run-output.txt"
$runErr = Join-Path $bundle "run-errors.txt"
$ran = $false
$runNote = ""
if ($NoRun) {
    # The newest report as it stands, however old: this reads a capture taken earlier, and a freshness cut-off would
    # refuse the very bundles it is for (PR #70 round 1).
    $runNote = "-NoRun was given: the tool was not started, the newest report is read instead"
    Write-Host ("[SKIP] the run: " + $runNote)
    $ran = $true
}
elseif (-not (Test-Path -LiteralPath $ScriptPath)) {
    $runNote = "the tool was not found at " + $ScriptPath
}
else {
    Write-Host ("[ .. ] running the tool, console only - this takes a few minutes")
    $psExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    # One string, with the path in quotes: Start-Process joins an argument array with spaces and keeps none of the
    # quoting, so a checkout under a path with a space in it - this repository's own, for one - would hand the child a
    # truncated -File and never run the tool (PR #70 round 1).
    $arguments = ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -ConsoleOnly' -f $ScriptPath)
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
# A report this run wrote is one that was not there before it started. With -NoRun there was no run, and the newest
# report is what is being re-read, whenever it was taken.
$found = New-Object System.Collections.ArrayList
foreach ($dir in $reportDirs) {
    if (-not (Test-Path -LiteralPath $dir)) { continue }
    foreach ($file in @(Get-ChildItem -LiteralPath $dir -Filter "*.json" -ErrorAction SilentlyContinue)) {
        if ($NoRun -or (-not $reportsBefore.ContainsKey($file.FullName))) { [void]$found.Add($file) }
    }
}
$reportJson = @($found | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
if ($reportJson.Count -eq 0) { $reportJson = $null } else { $reportJson = $reportJson[0] }

$report = $null
if ($null -ne $reportJson) {
    try { $report = Get-Content -LiteralPath $reportJson.FullName -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { $report = $null }
    foreach ($ext in @(".json", ".txt", ".html")) {
        $peer = [System.IO.Path]::ChangeExtension($reportJson.FullName, $ext)
        if (Test-Path -LiteralPath $peer) { Copy-Item -LiteralPath $peer -Destination $bundle -Force }
    }
}
Add-Check "C1" "the report read is the one this run wrote - or, with -NoRun, the newest capture kept" (($null -ne $report) -and $ran) `
    $(if ($null -ne $reportJson) { ("report: {0} ({1})" -f $reportJson.Name, $runNote) } else { "no report this run wrote; " + $runNote })

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

$zip = $bundle + ".zip"
try {
    if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
    Compress-Archive -Path (Join-Path $bundle "*") -DestinationPath $zip -Force
}
catch { $zip = "(the bundle could not be zipped: " + [string]$_.Exception.Message + ")" }

Write-Host ""
Write-Host ("VERDICT: " + $verdict)
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
if ($standingOk -and $behaviourOk) { exit 0 }
exit 1
