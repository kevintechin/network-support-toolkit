<#
.SYNOPSIS
    Guides the acceptance of a NetworkHealthCheck release asset on one machine through the scenarios of the checklist (backlog #24).

.DESCRIPTION
    One campaign per machine. The scenarios of tests/package-acceptance-checklist.md run in order: the automated ones
    (the acceptance runner of backlog #19) by themselves; the ones that need the machine changed, or a person at the
    desktop, with a prompt - what to do, in English and in Traditional Chinese - and, once the person answers done, a
    check that the machine really is in the state the scenario needs before anything runs. The driver never performs
    the click that is under test (a double-click on a downloaded ZIP, an Unblock, a policy change made elevated): it
    verifies preconditions, runs what can be run, collects the evidence - reports, environment reports, launcher
    errors, screenshots, the reports a compressed-folder view is about to delete - and records the answers a person gives.

    Every scenario's result goes to campaign.json as soon as it is known, so a campaign survives a logoff or a reboot
    and continues where it stopped: run the same command again (-Resume is implied when the state exists). A scenario
    that needs another session - the standard-user run - is left PENDING with the exact command to run there; the
    state, the asset, the extracted package and a copy of tests\ live under C:\Users\Public, which every account can
    reach. Each invocation ends by rebuilding the campaign bundle: campaign_summary.md, campaign.json, answers.log and
    one folder per scenario with its evidence, zipped next to the state. The exit code is the number of failed
    scenarios plus the scenarios this invocation selected and could not finish (quit, not reached, left for another
    session); a scenario a person skipped, one whose precondition the machine did not meet, or one -SkipGui dropped,
    is SKIPPED and not counted, and scenarios never selected stay pending in the summary without counting.

    -Answers replays a campaign without a person (the self-test): a file of key=value lines, <Id>=done|skip|quit for
    the gate of a scenario and <Id>/<question>=text for its questions; a missing gate answer counts as skip, and a
    precondition the machine does not meet is a skip rather than a retry.

.PARAMETER Zip
    The downloaded release asset. Needed on the first invocation; later ones use the copy kept in the state.
.PARAMETER ExpectedSha256
    The digest from the release notes; a mismatch stops the campaign before it starts.
.PARAMETER Campaign
    A name for the campaign, one state folder each. Default: <computer>_<date>.
.PARAMETER StateDir
    Where the state lives. Default: C:\Users\Public\NetworkHealthCheck-acceptance\<campaign>.
.PARAMETER Resume
    Continue an existing campaign (implied when its state exists).
.PARAMETER Answers
    Replay from a file of answers instead of asking.
.PARAMETER Scenarios
    Run these scenario ids only, in the plan's order.
.PARAMETER SkipGui
    No real windows anywhere in the campaign (a session without an interactive desktop).
.PARAMETER GuiTimeoutSeconds
    How long one real-window run may take.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\Invoke-AcceptanceCampaign.ps1 -Zip "$env:USERPROFILE\Downloads\NetworkHealthCheck-1.2.2.zip" -ExpectedSha256 5dde92c7f6a5e05a525b92b401beb65edc850a4f92fda7a41adfc5b4e4ea78f7 -Campaign win10-zhTW
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\Public\NetworkHealthCheck-acceptance\win10-zhTW\tests\Invoke-AcceptanceCampaign.ps1 -Campaign win10-zhTW -Resume
#>
[CmdletBinding()]
param(
    [string]$Zip,
    [string]$ExpectedSha256,
    [string]$Campaign,
    [string]$StateDir,
    [switch]$Resume,
    [string]$Answers,
    [string[]]$Scenarios,
    [switch]$SkipGui,
    [int]$GuiTimeoutSeconds = 360
)

$ErrorActionPreference = 'Stop'
$PsExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$CmdExe = Join-Path $env:SystemRoot 'System32\cmd.exe'
$Tests = $PSScriptRoot
$Base = 'C:\Users\Public\NetworkHealthCheck-acceptance'
if (-not $Campaign) { $Campaign = $env:COMPUTERNAME + '_' + (Get-Date -Format 'yyyyMMdd') }
$Campaign = $Campaign -replace '[^\w.-]', '_'
if (-not $StateDir) { $StateDir = Join-Path $Base $Campaign }
$StateFile = Join-Path $StateDir 'campaign.json'
$AnswersLog = Join-Path $StateDir 'answers.log'
# A campaign interrupted after M7 leaves every new PowerShell in ConstrainedLanguage, where this script's own New-Object
# below is refused: say where the recovery notes are and stop, instead of dying on that line (PR #11 round 5). Under M8
# the unsigned script does not start at all, which is why the notes are written before either policy is applied.
if ([string]$ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
    Write-Host ('PowerShell is in {0} language mode on this machine: the campaign cannot run or resume here.' -f [string]$ExecutionContext.SessionState.LanguageMode)
    Write-Host ('Put the machine back first without PowerShell - see ' + (Join-Path $StateDir 'RECOVER.txt') + ' (after M7: run undo-M7.cmd in that folder as administrator) - then run this command again.')
    exit 3
}
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)   # the first .NET object: nothing above this line needs FullLanguage
$Now = { Get-Date -Format 'yyyy-MM-dd HH:mm:ss' }
# A standard user has no Administrators group in the token at all; an administrator under UAC has it, marked deny-only
# until elevated - so presence, not enabled state, is the question (the probe asks it the same way).
$IsStandardUser = -not (([string](& (Join-Path $env:SystemRoot 'System32\whoami.exe') /groups /fo csv /nh)) -match 'S-1-5-32-544')

# -------------------- Console, answers, state --------------------
function Write-Line([string[]]$Lines, [string]$Color = 'Gray') { foreach ($l in $Lines) { Write-Host ('  ' + $l) -ForegroundColor $Color } }
$AnswersTable = $null
if ($Answers) {
    $AnswersTable = @{}
    foreach ($line in [IO.File]::ReadLines((Resolve-Path -LiteralPath $Answers).Path)) {
        if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith('#')) { continue }
        $i = $line.IndexOf('=')
        if ($i -lt 1) { continue }
        $AnswersTable[$line.Substring(0, $i).Trim()] = $line.Substring($i + 1).Trim()
    }
}
function ConvertTo-Hashtable($Object) {
    # ConvertFrom-Json gives PSCustomObjects; the state is edited as ordered hashtables and written back as JSON.
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { $h = [ordered]@{}; foreach ($k in $Object.Keys) { $h[[string]$k] = ConvertTo-Hashtable $Object[$k] }; return $h }
    if ($Object -is [System.Management.Automation.PSCustomObject]) { $h = [ordered]@{}; foreach ($p in $Object.PSObject.Properties) { $h[$p.Name] = ConvertTo-Hashtable $p.Value }; return $h }
    if ($Object -is [array]) { return @($Object | ForEach-Object { ConvertTo-Hashtable $_ }) }
    return $Object
}
function Save-State { [IO.File]::WriteAllText($StateFile, ($State | ConvertTo-Json -Depth 10), $Utf8NoBom) }
function Add-Event([string]$Text) {
    $State.Events = @($State.Events) + @([ordered]@{ Time = (& $Now); Text = $Text })
    Write-Host ('  [' + (Get-Date -Format 'HH:mm:ss') + '] ' + $Text) -ForegroundColor DarkGray
}
function Add-Answer([string]$Id, [string]$Key, [string]$Answer) {
    [IO.File]::AppendAllText($AnswersLog, ('{0}  {1}/{2} = {3}' -f (& $Now), $Id, $Key, $Answer) + "`r`n", $Utf8NoBom)
    if ($null -eq $State.Scenarios[$Id].Answers) { $State.Scenarios[$Id].Answers = [ordered]@{} }
    $State.Scenarios[$Id].Answers[$Key] = $Answer
}
function Read-Answer([string]$Id, [string]$Key, [string[]]$Prompt, [string[]]$Choices, [string]$Default) {
    # The prompt (English and zh-TW), then the answer: from the answers file (<Id> for the gate, <Id>/<Key> for a
    # question; missing = the default) or from the console (blank = the default, or asked again without one).
    Write-Line $Prompt 'Cyan'
    $lookup = $(if ($Key -eq 'gate') { $Id } else { $Id + '/' + $Key })
    if ($null -ne $AnswersTable) {
        $a = $(if ($AnswersTable.ContainsKey($lookup)) { $AnswersTable[$lookup] } else { $Default })
        Write-Host ('  > ' + $a + '   (answers file)') -ForegroundColor DarkGray
    }
    else {
        $a = ''
        while ([string]::IsNullOrWhiteSpace($a)) {
            $a = Read-Host ('  > ' + $(if ($Choices) { $Choices -join ' / ' } else { 'answer' }))
            if ([string]::IsNullOrWhiteSpace($a) -and $Default) { $a = $Default }
        }
    }
    $a = ([string]$a).Trim()
    # With choices, the answer is matched case-insensitively; a value outside them is asked again at the console, and
    # in answers mode returned as typed for the caller to refuse (PR #11 round 7) - a typo must never become a skip.
    if ($null -ne $Choices -and $Choices.Count -gt 0) {
        while ($Choices -notcontains $a.ToLowerInvariant()) {
            if ($null -ne $AnswersTable) { break }
            Write-Host ('  answer one of: ' + ($Choices -join ' / ')) -ForegroundColor Yellow
            $a = ([string](Read-Host ('  > ' + ($Choices -join ' / ')))).Trim()
            if ([string]::IsNullOrWhiteSpace($a) -and $Default) { $a = $Default }
        }
        if ($Choices -contains $a.ToLowerInvariant()) { $a = $a.ToLowerInvariant() }
    }
    Add-Answer $Id $Key $a
    return $a
}
function Set-Result([string]$Id, [string]$Result, [string]$Detail, [string[]]$Evidence, [double]$Seconds) {
    $s = $State.Scenarios[$Id]
    $s.Result = $Result; $s.Detail = $Detail; $s.Seconds = [math]::Round($Seconds, 1); $s.Finished = (& $Now)
    $s.Evidence = @($Evidence | Where-Object { $_ })
    Save-State
    $color = @{ PASS = 'Green'; FAIL = 'Red'; SKIPPED = 'Yellow'; PENDING = 'Magenta' }[$Result]
    Write-Host ('[{0}] {1}: {2}' -f $Result, $Id, $Detail) -ForegroundColor $color
}

# -------------------- Helpers the scenarios use --------------------
function Invoke-Native([string]$FilePath, [string[]]$ArgumentList, [string]$LogPath) {
    # A native command's merged output and exit code, kept as a log; stderr must not become a terminating error.
    $ErrorActionPreference = 'Continue'
    $prev = [Console]::OutputEncoding
    try { [Console]::OutputEncoding = $Utf8NoBom } catch { }
    $lines = @(& $FilePath @ArgumentList 2>&1 | ForEach-Object { if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { [string]$_ } })
    $code = $LASTEXITCODE
    try { [Console]::OutputEncoding = $prev } catch { }
    $ErrorActionPreference = 'Stop'
    if ($LogPath) { [IO.File]::WriteAllLines($LogPath, [string[]](@('> ' + $FilePath + ' ' + ($ArgumentList -join ' '), 'exit code ' + $code, '') + $lines), $Utf8NoBom) }
    return @{ Output = $lines; ExitCode = $code }
}
function Invoke-Acceptance([string]$Id, [string[]]$ExtraArgs) {
    # Invoke-PackageAcceptance.ps1 for one scenario: work dir and bundle under the scenario's folder, the console
    # output shown and kept as acceptance.log. Returns the exit code, the summary line and the bundle.
    $dir = Join-Path $StateDir $Id
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Tests 'Invoke-PackageAcceptance.ps1'), '-Label', ($Campaign + '-' + $Id), '-WorkDir', (Join-Path $dir 'work'), '-BundleDir', $dir, '-GuiTimeoutSeconds', $GuiTimeoutSeconds) + $ExtraArgs
    if ($State.SkipGui -and ($argList -notcontains '-SkipGui')) { $argList += '-SkipGui' }
    $lines = @()
    $ErrorActionPreference = 'Continue'
    $prev = [Console]::OutputEncoding
    try { [Console]::OutputEncoding = $Utf8NoBom } catch { }
    & $PsExe @argList 2>&1 | ForEach-Object {
        $t = $(if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { [string]$_ })
        Write-Host ('    ' + $t)
        $lines += $t
    }
    $code = $LASTEXITCODE
    try { [Console]::OutputEncoding = $prev } catch { }
    $ErrorActionPreference = 'Stop'
    [IO.File]::WriteAllLines((Join-Path $dir 'acceptance.log'), [string[]]$lines, $Utf8NoBom)
    $summary = [string]@($lines | Where-Object { $_ -match '^Summary: ' })[-1]
    $bundle = @(Get-ChildItem -LiteralPath $dir -Filter 'nhc-acceptance_*.zip' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1)[0]
    return @{ ExitCode = $code; Summary = $summary; Bundle = $(if ($null -ne $bundle) { $bundle.Name } else { '' }) }
}
function Copy-LanguageFolder([string]$Lang, [string]$Destination) {
    # A fresh copy of one language folder of the extracted package - files only, never Reports\ - like the chain's
    # staged copies.
    if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    Get-ChildItem -LiteralPath (Join-Path $State.PackageRoot $Lang) -File | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $Destination }
    return $Destination
}
function Invoke-LauncherRun([string]$Id, [string]$Lang) {
    # The shipped console launcher of one language, started the way a double-click starts it (cmd.exe; stdin from NUL
    # so that its pause returns), from a fresh copy under the scenario's folder. The console launcher rather than the
    # window launcher, so that a policy which turns out not to apply ends in a console run and a report instead of a
    # window waiting for a click. What it leaves behind is the evidence: the exit code, the console text,
    # LauncherError.txt, an environment report (next to the copy, or in TEMP) and any report.
    $copy = Copy-LanguageFolder $Lang (Join-Path (Join-Path $StateDir $Id) $Lang)
    $started = Get-Date
    $r = Invoke-Native $CmdExe @('/s', '/c', ('"' + (Join-Path $copy 'Start-NetworkCheck-Console.cmd') + '" <nul')) (Join-Path $copy 'launcher-output.log')
    $launcherError = Join-Path $copy 'LauncherError.txt'
    $envReports = @(Get-ChildItem -LiteralPath $copy -Filter 'NetworkHealthCheck_ENVIRONMENT_*.txt' -ErrorAction SilentlyContinue) + @(Get-ChildItem -LiteralPath $env:TEMP -Filter 'NetworkHealthCheck_ENVIRONMENT_*.txt' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt $started })
    foreach ($e in $envReports) { if ($e.DirectoryName -ne $copy) { Copy-Item -LiteralPath $e.FullName -Destination $copy -Force } }
    $reports = @(Get-ChildItem -LiteralPath (Join-Path $copy 'Reports') -Filter '*.json' -ErrorAction SilentlyContinue)
    return @{
        Copy = $copy; ExitCode = $r.ExitCode; Output = $r.Output
        LauncherError = $(if (Test-Path -LiteralPath $launcherError) { Get-Content -LiteralPath $launcherError -Raw } else { '' })
        EnvironmentReports = @($envReports | ForEach-Object { $_.FullName }); Reports = @($reports | ForEach-Object { $_.FullName })
    }
}
function Save-Screenshot([string]$Path) {
    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName System.Windows.Forms
    $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bitmap = New-Object System.Drawing.Bitmap($bounds.Width, $bounds.Height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try { $graphics.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size); $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png) }
    finally { $graphics.Dispose(); $bitmap.Dispose() }
}
function Get-PrimaryBounds { Add-Type -AssemblyName System.Windows.Forms; return [System.Windows.Forms.Screen]::PrimaryScreen.Bounds }
function Get-ZoneId([string]$Path) {
    # The Mark of the Web: the Zone.Identifier stream's ZoneId line, 'stream present' without one, 'no mark' without a stream.
    if (-not (Test-Path -LiteralPath $Path)) { return 'file missing' }
    $stream = Get-Item -LiteralPath $Path -Stream Zone.Identifier -ErrorAction SilentlyContinue
    if ($null -eq $stream) { return 'no mark' }
    $id = @(Get-Content -LiteralPath $Path -Stream Zone.Identifier -ErrorAction SilentlyContinue | Where-Object { $_ -match '^ZoneId=' })[0]
    if ($id) { return [string]$id }
    return 'stream present'
}
function Read-Json([string]$Path) { Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json }
function Get-NewestJson([string]$Dir, [datetime]$After) {
    @(Get-ChildItem -LiteralPath $Dir -Filter '*.json' -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt $After } | Sort-Object LastWriteTime -Descending | Select-Object -First 1)[0]
}
function Get-ArchiveViewReports([datetime]$After) {
    # Files written under a Windows compressed-folder view (%TEMP%\Temp1_*.zip\...\Reports\) since $After - the reports
    # a run from inside the view leaves where the view will delete them.
    @(Get-ChildItem -LiteralPath $env:TEMP -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^Temp\d*_.*\.zip$' } | ForEach-Object {
        Get-ChildItem -LiteralPath $_.FullName -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.DirectoryName -match '\\Reports$' -and $_.LastWriteTime -gt $After }
    })
}
function Get-NetworkFacts {
    # Adapters that are up with an IPv4 address, and IPv4 default gateways - read the way the tool reads them, with
    # the CIM fallback when the cmdlet is missing.
    $withAddress = 0; $gateways = 0
    if (Get-Command Get-NetIPConfiguration -ErrorAction SilentlyContinue) {
        foreach ($c in @(Get-NetIPConfiguration -ErrorAction SilentlyContinue)) {
            if ($null -eq $c.NetAdapter -or ([string]$c.NetAdapter.Status) -ne 'Up') { continue }
            if (@($c.IPv4Address | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_.IPAddress) }).Count -gt 0) { $withAddress++ }
            $gateways += @($c.IPv4DefaultGateway | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_.NextHop) }).Count
        }
    }
    else {
        foreach ($c in @(Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -ErrorAction SilentlyContinue | Where-Object { $_.IPEnabled })) {
            if (@($c.IPAddress | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' -and $_ -notlike '169.254.*' }).Count -gt 0) { $withAddress++ }
            $gateways += @($c.DefaultIPGateway | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' }).Count
        }
    }
    return @{ WithAddress = $withAddress; Gateways = $gateways }
}
function Get-MachineEnv([string]$Name) { return [Environment]::GetEnvironmentVariable($Name, 'Machine') }
function Get-MachinePolicyExecutionPolicy {
    # Read in a new process, the way the launcher's PowerShell will see it.
    return ([string](& $PsExe -NoProfile -Command 'Get-ExecutionPolicy -Scope MachinePolicy')).Trim()
}
function Get-ReportsUnder([string]$Root, [string]$Lang, [datetime]$After) {
    @(Get-ChildItem -LiteralPath $Root -Recurse -File -Filter '*.json' -ErrorAction SilentlyContinue | Where-Object { $_.DirectoryName -match ('\\' + [regex]::Escape($Lang) + '\\Reports$') -and $_.LastWriteTime -gt $After } | Sort-Object LastWriteTime -Descending)
}

# -------------------- The state --------------------
if (Test-Path -LiteralPath $StateFile) {
    $State = ConvertTo-Hashtable (Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json)
    if ($SkipGui) { $State.SkipGui = $true }
    Write-Host ('NetworkHealthCheck acceptance campaign "{0}" - resumed {1} on {2} as {3}{4}' -f $Campaign, (& $Now), $env:COMPUTERNAME, $env:USERNAME, $(if ($IsStandardUser) { ' (standard user)' } else { '' }))
}
else {
    if (-not $Zip) { throw ('no campaign "{0}" under {1} and no -Zip to start one' -f $Campaign, $StateDir) }
    $Zip = (Resolve-Path -LiteralPath $Zip).Path
    $digest = (Get-FileHash -LiteralPath $Zip -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($ExpectedSha256 -and ($digest -ne $ExpectedSha256.Trim().ToLowerInvariant())) { throw ('the asset is not the published one: SHA256 {0}, expected {1}' -f $digest, $ExpectedSha256.Trim().ToLowerInvariant()) }
    foreach ($sub in @('asset', 'package')) { New-Item -ItemType Directory -Force -Path (Join-Path $StateDir $sub) | Out-Null }
    Copy-Item -LiteralPath $Zip -Destination (Join-Path $StateDir 'asset') -Force
    $zipCopy = Join-Path (Join-Path $StateDir 'asset') (Split-Path -Leaf $Zip)
    $testsCopy = Join-Path $StateDir 'tests'
    if ((Resolve-Path -LiteralPath $Tests).Path -ne $testsCopy) {
        if (Test-Path -LiteralPath $testsCopy) { Remove-Item -LiteralPath $testsCopy -Recurse -Force }
        Copy-Item -LiteralPath $Tests -Destination $testsCopy -Recurse
    }
    $packageDir = Join-Path $StateDir 'package'
    Get-ChildItem -LiteralPath $packageDir -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force
    Expand-Archive -LiteralPath $zipCopy -DestinationPath $packageDir -Force
    $tops = @(Get-ChildItem -LiteralPath $packageDir -Directory)
    if ($tops.Count -ne 1 -or $tops[0].Name -notlike 'NetworkHealthCheck-*') { throw ('expected one NetworkHealthCheck-<version> folder at the top of the ZIP, found: ' + (@($tops | ForEach-Object { $_.Name }) -join ', ')) }
    $version = 'unknown'
    foreach ($line in [IO.File]::ReadLines((Join-Path $tops[0].FullName 'en-US\NetworkHealthCheck.ps1'))) { if ($line -match '^\$script:ToolVersion\s*=\s*"([^"]+)"') { $version = $Matches[1]; break } }
    $State = [ordered]@{
        Campaign = $Campaign; Created = (& $Now); Computer = $env:COMPUTERNAME; StartedBy = $env:USERNAME
        OriginalZip = $Zip; ZipCopy = $zipCopy; Digest = $digest; ExpectedSha256 = $(if ($ExpectedSha256) { $ExpectedSha256.Trim().ToLowerInvariant() } else { '' })
        PackageRoot = $tops[0].FullName; ToolVersion = $version; TestsCopy = $testsCopy; SkipGui = [bool]$SkipGui
        Scenarios = [ordered]@{}; Events = @()
    }
    Write-Host ('NetworkHealthCheck {0} acceptance campaign "{1}" - started {2} on {3} as {4}' -f $version, $Campaign, $State.Created, $env:COMPUTERNAME, $env:USERNAME)
    Write-Host ('  asset {0} (SHA256 {1}{2}); state {3}' -f (Split-Path -Leaf $Zip), $digest, $(if ($ExpectedSha256) { ', matches the release notes' } else { ', not compared' }), $StateDir)
}
# The plan's scenario ids, in order; -Scenarios is checked against them here so that the resume command printed for a
# partial campaign carries the same subset (PR #11 round 1) - following it must continue what was asked, not the plan.
$PlanIds = @('A1', 'M4', 'M1', 'M2', 'M3', 'A3', 'A4', 'M7', 'M8', 'M9', 'A2')
$Wanted = @()
if ($Scenarios) {
    $Wanted = @($Scenarios | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim().ToUpperInvariant() } | Where-Object { $_ })
    $unknown = @($Wanted | Where-Object { $PlanIds -notcontains $_ })
    if ($unknown.Count) { throw ('unknown scenario(s): ' + ($unknown -join ', ') + '; known: ' + ($PlanIds -join ', ')) }
    $Wanted = @($PlanIds | Where-Object { $Wanted -contains $_ })
}
$ResumeCommand = 'powershell -NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $State.TestsCopy 'Invoke-AcceptanceCampaign.ps1') + '" -Campaign ' + $Campaign + ' -StateDir "' + $StateDir + '" -Resume' + $(if ($Wanted.Count) { ' -Scenarios ' + ($Wanted -join ',') } else { '' })
$RecoveryNotes = Join-Path $StateDir 'RECOVER.txt'
function Write-RecoveryNotes {
    # RECOVER.txt and undo-M7.cmd in the state folder: how to put the machine back WITHOUT PowerShell, for a policy
    # scenario interrupted before its revert - under M7 every new PowerShell is ConstrainedLanguage and this script's
    # own New-Object is refused, under M8 the unsigned script does not start at all (PR #11 round 5). Written before
    # any policy is applied, and again when M9 has recorded the service's original state.
    $m9 = $State.Scenarios['M9']
    $svcType = 'the startup type recorded in campaign.json under Scenarios.M9.Facts once M9 has started'
    $svcStop = 'net stop AppIDSvc if it was stopped'
    if ($null -ne $m9 -and $null -ne $m9.Facts -and $m9.Facts.AppIDSvcStartType -and [string]$m9.Facts.AppIDSvcStartType -ne 'n/a') {
        $map = @{ Automatic = 'auto'; Manual = 'demand'; Disabled = 'disabled' }
        $t = [string]$m9.Facts.AppIDSvcStartType
        $svcType = $(if ($map.ContainsKey($t)) { $map[$t] } else { $t.ToLowerInvariant() }) + '   (it was ' + $t + ', ' + [string]$m9.Facts.AppIDSvcStatus + ')'
        $svcStop = $(if ([string]$m9.Facts.AppIDSvcStatus -eq 'Stopped') { 'net stop AppIDSvc   (it was stopped)' } else { 'leave it running (it was running)' })
    }
    $lines = @(
        ('NetworkHealthCheck acceptance campaign "' + $Campaign + '" - how to put the machine back WITHOUT PowerShell'),
        ('Written ' + (& $Now) + '. For a policy scenario interrupted before its revert: under M7 every new PowerShell is'),
        'ConstrainedLanguage and the campaign cannot resume; under M8 the unsigned campaign script does not start at all.',
        '',
        'M7  __PSLockdownPolicy (every new PowerShell in ConstrainedLanguage)',
        '    right-click undo-M7.cmd in this folder > Run as administrator; or, in an elevated command prompt:',
        '    reg delete "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment" /v __PSLockdownPolicy /f',
        '',
        'M8  Group Policy execution policy (AllSigned)',
        '    gpedit.msc > Computer Configuration > Administrative Templates > Windows Components > Windows PowerShell',
        '    > Turn on Script Execution > Not Configured > OK; then in a command prompt:   gpupdate /force',
        '    (gpedit and gpupdate need no PowerShell; deleting the registry values alone is undone by the next policy refresh)',
        '',
        'M9  AppLocker Script rules',
        '    secpol.msc > Application Control Policies > AppLocker > Configure rule enforcement > Script rules: Not configured;',
        '    delete the Script rules; then   gpupdate /force. The Application Identity service back as it was:',
        ('    sc config AppIDSvc start= ' + $svcType),
        ('    ' + $svcStop),
        '',
        'Then run the campaign again, so that the revert is recorded:',
        ('    ' + $ResumeCommand)
    )
    Set-Content -LiteralPath $RecoveryNotes -Value $lines -Encoding UTF8
    $cmd = @(
        '@echo off',
        'rem Undo M7 of the NetworkHealthCheck acceptance campaign: remove the machine-wide __PSLockdownPolicy. Run as administrator.',
        'reg delete "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment" /v __PSLockdownPolicy /f',
        'if errorlevel 1 echo Could not delete the value - is this prompt running as administrator? & pause & exit /b 1',
        'echo __PSLockdownPolicy removed: new PowerShell windows are FullLanguage again. Resume the campaign to record the revert.',
        'pause'
    )
    [IO.File]::WriteAllLines((Join-Path $StateDir 'undo-M7.cmd'), [string[]]$cmd, [Text.Encoding]::ASCII)
}
Write-RecoveryNotes

# -------------------- The plan --------------------
function Get-Plan {
    $desktop = [Environment]::GetFolderPath('Desktop')
    $m2Dir = Join-Path $desktop 'NHC-M2'
    $m3Dir = Join-Path $desktop 'NHC-M3'
    $zipName = Split-Path -Leaf $State.OriginalZip
    $top = Split-Path -Leaf $State.PackageRoot
    # Printed before a policy is applied: the way back that needs no PowerShell, for the case the campaign cannot resume.
    $recoverLines = @(('If this window closes before the revert, put the machine back WITHOUT PowerShell as written in ' + $RecoveryNotes + ' (for M7: run undo-M7.cmd there as administrator), then run the campaign again.'),
                      ('若這個視窗在還原前關掉了，請照 ' + $RecoveryNotes + ' 的說明、不用 PowerShell 把機器改回來（M7：以系統管理員身分執行同資料夾的 undo-M7.cmd），再重新執行 campaign。'))
    return @(
        @{ Id = 'A1'; Title = 'Baseline: the acceptance runner on this machine as it is'; Kind = 'auto'; Session = 'admin'
           Instruction = @('The acceptance runner: the asset, the package, the probe, the chain (real windows included unless -SkipGui) and the root launchers. Leave the desktop alone while windows open and close (about ten minutes).',
                           '驗收 runner：asset、套件、探針、驗證鏈（含真視窗，除非 -SkipGui）與根目錄啟動器。視窗開關期間請勿操作桌面（約十分鐘）。')
           Action = { param($Ctx)
               $extra = @('-Zip', $State.ZipCopy)
               if ($State.ExpectedSha256) { $extra += @('-ExpectedSha256', $State.ExpectedSha256) }
               $r = Invoke-Acceptance $Ctx.Id $extra
               @{ Passed = ($r.ExitCode -eq 0); Detail = ('exit code {0}; {1}' -f $r.ExitCode, $r.Summary); Evidence = @($r.Bundle, 'acceptance.log') }
           } },
        @{ Id = 'M4'; Title = 'The IT window at 1366 x 768'; Kind = 'reconfigure'; Session = 'admin'; NeedsGui = $true
           Instruction = @('Set the display to 1366 x 768 (VMware: View > Autosize > off; Windows: Settings > System > Display > Display resolution). Then answer done.',
                           '把顯示器設成 1366 x 768（VMware：檢視 > 自動調整大小 > 關閉；Windows：設定 > 系統 > 顯示器 > 顯示器解析度）。完成後輸入 done。')
           Prepare = { param($Ctx) $b = Get-PrimaryBounds; return @{ ScreenBefore = ('{0}x{1}' -f $b.Width, $b.Height) } }   # what to put back afterwards
           Precondition = { $b = Get-PrimaryBounds; if ($b.Width -eq 1366 -and $b.Height -eq 768) { @{ Ok = $true; Detail = '1366x768' } } else { @{ Ok = $false; Detail = ('the primary screen is {0}x{1}, not 1366x768' -f $b.Width, $b.Height) } } }
           Cleanup = @{ Instruction = @('Set the display back to the size it had before this scenario (the campaign recorded it and checks it). Then answer done.', '把顯示器改回這個情境之前的大小（campaign 有記錄並會檢查）。完成後輸入 done。')
                        Verify = { param($Ctx) $b = Get-PrimaryBounds; $now = ('{0}x{1}' -f $b.Width, $b.Height); if ($now -eq [string]$Ctx.Facts.ScreenBefore) { @{ Ok = $true; Detail = ('back at ' + $now) } } else { @{ Ok = $false; Detail = ('the screen is {0}; it was {1} before M4' -f $now, $Ctx.Facts.ScreenBefore) } } } }
           Action = { param($Ctx)
               $stage = Copy-LanguageFolder 'en-US' (Join-Path $Ctx.Dir 'stage\en-US')
               $shot = Join-Path $Ctx.Dir 'M4_IT_window_1366x768.png'
               $r = Invoke-Native $PsExe @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Tests 'gui_check.ps1'), '-PackageDir', $stage, '-Entry', 'IT', '-Via', 'Launcher', '-TimeoutSeconds', $GuiTimeoutSeconds, '-Screenshot', $shot) (Join-Path $Ctx.Dir 'gui_check.log')
               $window = [string]@($r.Output | Where-Object { $_ -match "window: '" })[0] -replace '^\[[^\]]+\]\s*', ''
               $bad = @()
               if ($r.ExitCode -ne 0) { $bad += ('gui_check exit code {0}: {1}' -f $r.ExitCode, [string]@($r.Output | Where-Object { $_ -match 'ERROR' })[0]) }
               if (-not (Test-Path -LiteralPath $shot)) { $bad += 'no screenshot' }
               $json = Get-NewestJson (Join-Path $stage 'Reports') $Ctx.Started
               if ($null -eq $json) { $bad += 'no JSON report' }
               else {
                   $d = Read-Json $json.FullName
                   $cfg = Read-Json (Join-Path $stage 'NetworkHealthCheck.config.json')
                   if ([int]$d.RunOptions.PingCount -ne [int]$cfg.Tests.PingCount -or [int]$d.RunOptions.SampleSeconds -ne [int]$cfg.Tests.RetransmissionSampleSeconds) { $bad += ('the report carries PingCount {0} / SampleSeconds {1}, the configuration {2} / {3}' -f $d.RunOptions.PingCount, $d.RunOptions.SampleSeconds, $cfg.Tests.PingCount, $cfg.Tests.RetransmissionSampleSeconds) }
                   Copy-Item -LiteralPath $json.FullName -Destination $Ctx.Dir -Force
               }
               # Only a yes certifies the layout; a no is the layout failing, anything else is the observation not made (PR #11 round 2).
               $seen = Read-Answer $Ctx.Id 'panel-usable' @(('Open ' + $shot + ' and look: are the run-options panel and the Start button fully visible and usable at this size? (yes / no / unsure)'), '打開這張截圖看：執行選項面板與「開始檢測」按鈕在這個尺寸下是否完整可見、可用？（yes / no / unsure）') @('yes', 'no', 'unsure') 'unsure'
               if ($seen -eq 'no') { $bad += 'the observer reports the panel or the Start button not usable at this size' }
               elseif ($seen -ne 'yes') { $bad += ('the layout was not confirmed usable (answer: ' + $seen + ')') }
               @{ Passed = ($bad.Count -eq 0); Detail = (($bad -join '; ') + $(if ($bad.Count) { ' | ' } else { '' }) + $window + '; observer: ' + $seen); Evidence = @('M4_IT_window_1366x768.png', 'gui_check.log') }
           } },
        @{ Id = 'M1'; Title = 'Run from inside the compressed-folder view'; Kind = 'manual'; Session = 'admin'
           Instruction = @(('In Explorer, double-click the downloaded ZIP - ' + $State.OriginalZip + ' - without extracting it. Open ' + $top + ' > en-US and double-click Start-NetworkCheck.cmd. As soon as the tool window is up (the run started), answer done: a screenshot is taken then. Do NOT close the ZIP window.'),
                           ('在檔案總管直接雙擊下載的 ZIP（' + $State.OriginalZip + '），不要解壓。打開 ' + $top + ' > en-US，雙擊 Start-NetworkCheck.cmd。工具視窗一出現（開始跑了）就輸入 done：那一刻會截圖。不要關 ZIP 視窗。'))
           Action = { param($Ctx)
               # The evidence the checklist asks for: the window running from inside the view, and the reports the view
               # is about to delete (PR #11 round 4).
               $shot = Join-Path $Ctx.Dir 'M1_window_from_the_view.png'
               Save-Screenshot $shot
               $null = Read-Answer $Ctx.Id 'run-finished' @('Let the run finish and the tool window close (do not close the ZIP window). Then answer done.', '等它跑完、工具視窗關閉（不要關 ZIP 視窗）。然後輸入 done。') @('done') 'done'
               $found = @(Get-ArchiveViewReports $Ctx.Started)
               $jsons = @($found | Where-Object { $_.Extension -eq '.json' } | Sort-Object LastWriteTime -Descending)
               if ($jsons.Count -eq 0) { return @{ Passed = $false; Detail = ('no report under {0}\Temp*_*.zip since {1}: was the ZIP opened in the view and Start-NetworkCheck.cmd double-clicked inside it?' -f $env:TEMP, $Ctx.Started.ToString('HH:mm:ss')); Evidence = @('M1_window_from_the_view.png') } }
               $dest = Join-Path $Ctx.Dir 'reports-from-the-view'
               New-Item -ItemType Directory -Force -Path $dest | Out-Null
               foreach ($f in $found) { Copy-Item -LiteralPath $f.FullName -Destination $dest -Force }
               $d = Read-Json $jsons[0].FullName
               $startup = @($d.Results | Where-Object { $_.Tag -eq 'startup' })
               Write-Line @('The reports were copied out; you may close the ZIP window now.', '報告已複製出來，現在可以關閉 ZIP 視窗了。') 'Cyan'
               @{ Passed = ($startup.Count -gt 0); Detail = ('{0} file(s) copied out of {1}; startup rows: {2}{3}' -f $found.Count, (Split-Path -Parent $jsons[0].DirectoryName), $startup.Count, $(if ($startup.Count) { ' - "' + [string]$startup[0].Message + '"' } else { ' - the compressed-folder warning is missing' })); Evidence = @('M1_window_from_the_view.png', 'reports-from-the-view') }
           } },
        @{ Id = 'M2'; Title = 'Extract without Unblock and double-click the root launcher'; Kind = 'manual'; Session = 'admin'
           Instruction = @(('Right-click the downloaded ZIP > Extract All... into ' + $m2Dir + ' (do NOT Unblock it). Open the extracted folder and double-click Start-English.cmd. As soon as a Windows prompt appears - or the tool window, if nothing appeared - answer done: a screenshot is taken at that moment.'),
                           ('在下載的 ZIP 上按右鍵 > 全部解壓縮，解壓到 ' + $m2Dir + '（不要 Unblock）。打開解壓出來的資料夾，雙擊 Start-English.cmd。Windows 一跳出提示（或沒有提示、工具視窗出現時）就輸入 done：那一刻會截圖。'))
           Action = { param($Ctx)
               $mark = Get-ZoneId $State.OriginalZip
               $shot = Join-Path $Ctx.Dir 'M2_after_double-click.png'
               Save-Screenshot $shot
               $seen = Read-Answer $Ctx.Id 'windows-showed' @('What did Windows show? 1 = Open File - Security Warning, 2 = SmartScreen (Windows protected your PC), 3 = nothing, the tool ran, 4 = something else', 'Windows 顯示了什麼？1 = 開啟檔案－安全性警告，2 = SmartScreen（Windows 已保護您的電腦），3 = 沒有，工具直接跑了，4 = 其他') @('1', '2', '3', '4') '4'
               if ($seen -eq '4') { $seen = '4: ' + (Read-Answer $Ctx.Id 'windows-showed-other' @('Describe what Windows showed.', '請描述 Windows 顯示了什麼。') @() 'not described') }
               $null = Read-Answer $Ctx.Id 'run-finished' @('If a prompt is still waiting, choose what lets the tool run. When the tool window has closed, answer done.', '若提示還在等，選擇讓工具執行的選項。工具視窗關閉後輸入 done。') @('done') 'done'
               $launcher = @(Get-ChildItem -LiteralPath $m2Dir -Recurse -File -Filter 'Start-English.cmd' -ErrorAction SilentlyContinue)[0]
               $json = @(Get-ReportsUnder $m2Dir 'en-US' $Ctx.Started)[0]
               $bad = @()
               if ($null -eq $launcher) { $bad += ('Start-English.cmd not found under ' + $m2Dir) }
               if ($null -eq $json) { $bad += 'no en-US report written after the double-click' } else { Copy-Item -LiteralPath $json.FullName -Destination $Ctx.Dir -Force }
               $launcherMark = $(if ($null -ne $launcher) { Get-ZoneId $launcher.FullName } else { 'n/a' })
               @{ Passed = ($bad.Count -eq 0); Detail = (($bad -join '; ') + $(if ($bad.Count) { ' | ' } else { '' }) + ('download mark: {0}; extracted launcher mark: {1}; Windows showed: {2}; report: {3}' -f $mark, $launcherMark, $seen, $(if ($null -ne $json) { $json.Name } else { 'none' }))); Evidence = @('M2_after_double-click.png') }
           } },
        @{ Id = 'M3'; Title = 'Unblock, extract, both root launchers, Open Report'; Kind = 'manual'; Session = 'admin'
           Instruction = @(('Right-click the downloaded ZIP > Properties > tick Unblock > OK. Extract All... into ' + $m3Dir + '. Double-click Start-English.cmd and let it run; close it. Double-click Start-Traditional-Chinese.cmd and let it run; when its run has finished and the window is still open, answer done: a screenshot of the window is taken then.'),
                           ('在下載的 ZIP 上按右鍵 > 內容 > 勾選「解除封鎖」> 確定。全部解壓縮到 ' + $m3Dir + '。雙擊 Start-English.cmd 讓它跑完、關閉。再雙擊 Start-Traditional-Chinese.cmd 讓它跑完；跑完、視窗還開著時輸入 done：那一刻會截圖視窗。'))
           Action = { param($Ctx)
               # The evidence the checklist asks for: the window after its run, and the browser showing the report (PR #11 rounds 2 and 4).
               $windowShot = Join-Path $Ctx.Dir 'M3_zhTW_window_after_the_run.png'
               Save-Screenshot $windowShot
               $mark = Get-ZoneId $State.OriginalZip
               $bad = @()
               $names = @()
               foreach ($lang in @('en-US', 'zh-TW')) {
                   $json = @(Get-ReportsUnder $m3Dir $lang $Ctx.Started)[0]
                   if ($null -eq $json) { $bad += ('no ' + $lang + ' report under ' + $m3Dir); continue }
                   Copy-Item -LiteralPath $json.FullName -Destination $Ctx.Dir -Force
                   $names += $json.Name
                   $d = Read-Json $json.FullName
                   if ([string]$d.RunOptions.EntryPoint -ne 'User') { $bad += ($lang + ': EntryPoint ' + $d.RunOptions.EntryPoint + ', expected User') }
               }
               # Open Report: the evidence is a screenshot of the browser showing the HTML report, taken the moment the
               # person says it is on screen; only that certifies the item - a no is the tool failing, anything else is
               # the scenario not done as instructed (PR #11 rounds 1 and 2).
               $opened = Read-Answer $Ctx.Id 'open-report' @('Now click Open Report in that window. Is the browser showing the HTML report? Bring it to the front and answer shown - a screenshot is taken then. Answer failed if Open Report did not open it, or not clicked.', '現在在那個視窗按「開啟報告」。瀏覽器是否正顯示 HTML 報告？把它移到最前面並輸入 shown，那一刻會截圖。若「開啟報告」沒有打開，輸入 failed；沒有按則輸入 not clicked。') @('shown', 'failed', 'not clicked') 'not clicked'
               $shot = ''
               if ($opened -eq 'shown') { $shot = Join-Path $Ctx.Dir 'M3_open_report_browser.png'; Save-Screenshot $shot }
               elseif ($opened -eq 'failed') { $bad += 'Open Report did not open the browser' }
               else { $bad += 'Open Report was not exercised: the scenario asks for it to be clicked and the browser shown' }
               @{ Passed = ($bad.Count -eq 0); Detail = (($bad -join '; ') + $(if ($bad.Count) { ' | ' } else { '' }) + ('download mark after Unblock: {0}; reports: {1}; Open Report: {2}' -f $mark, ($names -join ', '), $opened)); Evidence = @(@('M3_zhTW_window_after_the_run.png') + $names + @($(if ($shot) { 'M3_open_report_browser.png' }))) }
           } },
        @{ Id = 'A3'; Title = 'Host-only network (an address, no gateway, no internet)'; Kind = 'reconfigure'; Session = 'admin'
           Instruction = @('VMware: VM > Settings > Network Adapter > Host-only. Wait until Windows shows the new address (about ten seconds), then answer done.',
                           'VMware：VM > 設定 > 網路介面卡 > 僅限主機。等 Windows 拿到新位址（約十秒）後輸入 done。')
           Precondition = { $f = Get-NetworkFacts; if ($f.WithAddress -gt 0 -and $f.Gateways -eq 0) { @{ Ok = $true; Detail = ('{0} adapter(s) with an address, no gateway' -f $f.WithAddress) } } else { @{ Ok = $false; Detail = ('adapters with an IPv4 address: {0}, default gateways: {1} - host-only means an address and no gateway' -f $f.WithAddress, $f.Gateways) } } }
           Action = { param($Ctx)
               $r = Invoke-Acceptance $Ctx.Id @('-PackageDir', $State.PackageRoot, '-ChainSteps', 'acceptance,resultset', '-SkipGui')
               @{ Passed = ($r.ExitCode -eq 0); Detail = ('exit code {0}; {1}' -f $r.ExitCode, $r.Summary); Evidence = @($r.Bundle, 'acceptance.log') }
           }
           Cleanup = @{ Instruction = @('Set the adapter back to NAT. When Windows has a gateway again, answer done.', '把介面卡改回 NAT。Windows 重新拿到閘道後輸入 done。')
                        Verify = { $f = Get-NetworkFacts; if ($f.Gateways -gt 0) { @{ Ok = $true; Detail = ('{0} gateway(s)' -f $f.Gateways) } } else { @{ Ok = $false; Detail = 'still no default gateway' } } } } },
        @{ Id = 'A4'; Title = 'Network adapter disconnected'; Kind = 'reconfigure'; Session = 'admin'
           Instruction = @('VMware: VM > Settings > Network Adapter > untick Connected. Wait until Windows shows no network (about ten seconds), then answer done.',
                           'VMware：VM > 設定 > 網路介面卡 > 取消勾選「已連線」。等 Windows 顯示沒有網路（約十秒）後輸入 done。')
           Precondition = { $f = Get-NetworkFacts; if ($f.WithAddress -eq 0) { @{ Ok = $true; Detail = 'no adapter with an IPv4 address' } } else { @{ Ok = $false; Detail = ('{0} adapter(s) still have an IPv4 address' -f $f.WithAddress) } } }
           Action = { param($Ctx)
               $r = Invoke-Acceptance $Ctx.Id @('-PackageDir', $State.PackageRoot, '-ChainSteps', 'acceptance,resultset', '-SkipGui')
               @{ Passed = ($r.ExitCode -eq 0); Detail = ('exit code {0}; {1}' -f $r.ExitCode, $r.Summary); Evidence = @($r.Bundle, 'acceptance.log') }
           }
           Cleanup = @{ Instruction = @('Tick Connected again and set the adapter back to NAT. When Windows has a gateway again, answer done.', '重新勾選「已連線」並把介面卡改回 NAT。Windows 重新拿到閘道後輸入 done。')
                        Verify = { $f = Get-NetworkFacts; if ($f.Gateways -gt 0) { @{ Ok = $true; Detail = ('{0} gateway(s)' -f $f.Gateways) } } else { @{ Ok = $false; Detail = 'still no default gateway' } } } } },
        @{ Id = 'M7'; Title = 'Every new PowerShell in ConstrainedLanguage (__PSLockdownPolicy = 4)'; Kind = 'reconfigure'; Session = 'admin'
           Instruction = @('In an ELEVATED command prompt run:   setx /M __PSLockdownPolicy 4   - then answer done. This puts every new PowerShell on this machine into ConstrainedLanguage until it is removed; you will be asked to remove it afterwards.',
                           '在「以系統管理員身分執行」的命令提示字元執行：setx /M __PSLockdownPolicy 4，然後輸入 done。移除之前，這台機器每個新的 PowerShell 都會是 ConstrainedLanguage；之後會提示你移除。') + $recoverLines
           Precondition = { $v = Get-MachineEnv '__PSLockdownPolicy'; if ($v -eq '4') { @{ Ok = $true; Detail = '__PSLockdownPolicy=4 in the machine environment' } } else { @{ Ok = $false; Detail = ('__PSLockdownPolicy is ' + $(if ($v) { $v } else { 'not set' }) + ' in the machine environment') } } }
           Action = { param($Ctx)
               $env:__PSLockdownPolicy = '4'   # what a double-click inherits from Explorer after the broadcast; PowerShell reads the machine value itself
               try { $r = Invoke-LauncherRun $Ctx.Id 'en-US' } finally { Remove-Item -LiteralPath Env:\__PSLockdownPolicy -ErrorAction SilentlyContinue }
               $bad = @()
               if ($r.ExitCode -ne 1) { $bad += ('launcher exit code {0}, expected 1' -f $r.ExitCode) }
               if ($r.LauncherError -notmatch 'exit code 3') { $bad += 'LauncherError.txt does not report exit code 3' }
               if ($r.EnvironmentReports.Count -ne 1) { $bad += ('{0} environment report(s), expected exactly 1' -f $r.EnvironmentReports.Count) }
               elseif ((Get-Content -LiteralPath $r.EnvironmentReports[0] -Raw) -notmatch 'ConstrainedLanguage') { $bad += 'the environment report does not name ConstrainedLanguage' }
               if ($r.Reports.Count) { $bad += 'a report was written although the guard should have stopped the run' }
               @{ Passed = ($bad.Count -eq 0); Detail = (($bad -join '; ') + $(if ($bad.Count) { ' | ' } else { '' }) + ('launcher exit {0}; environment report(s): {1}; reports: {2}' -f $r.ExitCode, $r.EnvironmentReports.Count, $r.Reports.Count)); Evidence = @('en-US\launcher-output.log', 'en-US\LauncherError.txt', 'en-US\NetworkHealthCheck_ENVIRONMENT_*.txt') }
           }
           Cleanup = @{ Instruction = @('Remove it - in an ELEVATED command prompt:   reg delete "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment" /v __PSLockdownPolicy /f   - then answer done.', '移除它——在「以系統管理員身分執行」的命令提示字元執行：reg delete "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment" /v __PSLockdownPolicy /f，然後輸入 done。')
                        Verify = { $v = Get-MachineEnv '__PSLockdownPolicy'; if ($null -eq $v -or $v -eq '') { @{ Ok = $true; Detail = 'removed' } } else { @{ Ok = $false; Detail = ('__PSLockdownPolicy is still ' + $v) } } } } },
        @{ Id = 'M8'; Title = 'Group Policy execution policy: allow only signed scripts'; Kind = 'reconfigure'; Session = 'admin'
           Instruction = @('gpedit.msc > Computer Configuration > Administrative Templates > Windows Components > Windows PowerShell > Turn on Script Execution > Enabled, "Allow only signed scripts" > OK; then in a command prompt:   gpupdate /force   - then answer done. While this is in force, no unsigned PowerShell script starts - this campaign included: keep this window open.',
                           'gpedit.msc > 電腦設定 > 系統管理範本 > Windows 元件 > Windows PowerShell > 開啟指令碼執行 > 已啟用、「只允許已簽署的指令碼」> 確定；再在命令提示字元執行 gpupdate /force，然後輸入 done。生效期間任何未簽章的 PowerShell 腳本都跑不起來——包括這個 campaign：請保持這個視窗開著。') + $recoverLines
           Precondition = { $p = Get-MachinePolicyExecutionPolicy; if ($p -eq 'AllSigned') { @{ Ok = $true; Detail = 'MachinePolicy=AllSigned' } } else { @{ Ok = $false; Detail = ('MachinePolicy is ' + $p + ', not AllSigned') } } }
           Action = { param($Ctx)
               $r = Invoke-LauncherRun $Ctx.Id 'en-US'
               $bad = @()
               if ($r.ExitCode -eq 0) { $bad += 'the launcher exited 0: the unsigned script ran under AllSigned' }
               if ($r.Reports.Count) { $bad += 'a report was written: the unsigned script ran' }
               if (-not $r.LauncherError) { $bad += 'no LauncherError.txt' }
               $shown = @($r.Output | Where-Object { $_.Trim() -ne '' } | Select-Object -First 4) -join ' / '
               @{ Passed = ($bad.Count -eq 0); Detail = (($bad -join '; ') + $(if ($bad.Count) { ' | ' } else { '' }) + ('launcher exit {0}; environment report(s): {1}; what the user sees: {2}' -f $r.ExitCode, $r.EnvironmentReports.Count, $shown)); Evidence = @('en-US\launcher-output.log', 'en-US\LauncherError.txt') }
           }
           Cleanup = @{ Instruction = @('Set Turn on Script Execution back to Not Configured, then   gpupdate /force   - then answer done.', '把「開啟指令碼執行」改回「尚未設定」，再執行 gpupdate /force，然後輸入 done。')
                        Verify = { $p = Get-MachinePolicyExecutionPolicy; if ($p -eq 'Undefined') { @{ Ok = $true; Detail = 'MachinePolicy=Undefined' } } else { @{ Ok = $false; Detail = ('MachinePolicy is still ' + $p) } } } } },
        @{ Id = 'M9'; Title = 'AppLocker script rules enforced (Enterprise / Education)'; Kind = 'reconfigure'; Session = 'admin'
           Instruction = @('secpol.msc > Application Control Policies > AppLocker > Script Rules > right-click > Create Default Rules, then DELETE the default rule that allows BUILTIN\Administrators all scripts - your account is an administrator, and with that rule in place it is exempt and the test measures nothing; AppLocker > Configure rule enforcement > Script rules: Configured, Enforce rules. Then in an ELEVATED command prompt:   sc config AppIDSvc start= auto & net start AppIDSvc & gpupdate /force   - then answer done. The driver checks that the rules really restrict this account before it runs anything.',
                           'secpol.msc > 應用程式控制原則 > AppLocker > 指令碼規則 > 右鍵 > 建立預設規則，然後「刪除」允許 BUILTIN\Administrators 執行所有指令碼的那條預設規則——你的帳號是管理員，留著它就被豁免、什麼都量不到；AppLocker > 設定規則強制執行 > 指令碼規則：已設定、強制執行規則。再在「以系統管理員身分執行」的命令提示字元執行：sc config AppIDSvc start= auto & net start AppIDSvc & gpupdate /force，然後輸入 done。driver 執行前會確認規則真的限制了這個帳號。') + $recoverLines
           Prepare = { param($Ctx)
               # The copy the launcher will run, made now so that the precondition can ask AppLocker about the very path
               # that is executed (PR #11 round 7); and the service's state, which the instruction changes and must go back.
               $null = Copy-LanguageFolder 'en-US' (Join-Path $Ctx.Dir 'en-US')
               try { $svc = Get-Service -Name AppIDSvc -ErrorAction Stop; return @{ AppIDSvcStartType = [string]$svc.StartType; AppIDSvcStatus = [string]$svc.Status } } catch { return @{ AppIDSvcStartType = 'n/a'; AppIDSvcStatus = 'n/a' } }
           }
           Precondition = {
               try {
                   $p = Get-AppLockerPolicy -Effective -ErrorAction Stop
                   $scriptRules = @($p.RuleCollections | Where-Object { [string]$_.RuleCollectionType -eq 'Script' })[0]
                   $svc = Get-Service -Name AppIDSvc -ErrorAction Stop
                   # Enforcement with no rule at all lets every script run: the experiment would then measure nothing (PR #11 round 5).
                   if ($null -ne $scriptRules -and [string]$scriptRules.EnforcementMode -eq 'Enabled' -and [int]$scriptRules.Count -eq 0) { @{ Ok = $false; Detail = 'Script rules enforced but empty - create the default rules first, or nothing is enforced' } }
                   elseif ($null -ne $scriptRules -and [string]$scriptRules.EnforcementMode -eq 'Enabled' -and [string]$svc.Status -eq 'Running') {
                       # The rules must restrict the account that runs the test: the default rules exempt BUILTIN\Administrators,
                       # and an exempt account would run the script normally and record a FAIL that measures nothing (PR #11
                       # round 6). AppLocker's own evaluation decides, for the shipped script where the campaign keeps it.
                       $copy = Join-Path $StateDir 'M9\en-US\NetworkHealthCheck.ps1'   # the path Invoke-LauncherRun executes, made by Prepare
                       if (-not (Test-Path -LiteralPath $copy)) { $null = Copy-LanguageFolder 'en-US' (Join-Path $StateDir 'M9\en-US') }
                       $decision = @(Test-AppLockerPolicy -PolicyObject $p -Path $copy -User ($env:USERDOMAIN + '\' + $env:USERNAME) -ErrorAction Stop)[0]
                       if ($null -ne $decision -and [string]$decision.PolicyDecision -eq 'Allowed') { @{ Ok = $false; Detail = ('the Script rules allow {0}\{1} to run the script here ({2}) - this account is exempt, so delete the default rule for BUILTIN\Administrators (or use rules that restrict it) before the test' -f $env:USERDOMAIN, $env:USERNAME, $decision.MatchingRule) } }
                       else { @{ Ok = $true; Detail = ('Script rules enforced ({0} rules), AppIDSvc running; the script is {1} for {2}\{3}' -f $scriptRules.Count, $(if ($null -ne $decision) { [string]$decision.PolicyDecision } else { 'not allowed' }), $env:USERDOMAIN, $env:USERNAME) } }
                   }
                   else { @{ Ok = $false; Detail = ('Script rules: ' + $(if ($null -ne $scriptRules) { [string]$scriptRules.EnforcementMode + ', ' + $scriptRules.Count + ' rules' } else { 'none' }) + '; AppIDSvc ' + $svc.Status) } }
               }
               catch { @{ Ok = $false; Detail = ('AppLocker is not available here: ' + $_.Exception.Message) } }
           }
           Action = { param($Ctx)
               $r = Invoke-LauncherRun $Ctx.Id 'en-US'
               $what = ''
               $passed = $false
               if ($r.EnvironmentReports.Count -ge 1 -and $r.LauncherError -match 'exit code 3') { $what = 'the script ran in ConstrainedLanguage and the guard fired (environment report written)'; $passed = ($r.Reports.Count -eq 0) }
               elseif ($r.Reports.Count -eq 0 -and $r.ExitCode -ne 0) { $what = 'the script was blocked before its first line (no environment report; the launcher reported the failure)'; $passed = $true }
               elseif ($r.Reports.Count -gt 0) { $what = 'the script ran unrestricted although the Script rules are enforced' }
               else { $what = 'no report, no launcher error, exit code 0 - unexplained' }
               $shown = @($r.Output | Where-Object { $_.Trim() -ne '' } | Select-Object -First 4) -join ' / '
               @{ Passed = $passed; Detail = ('{0}; launcher exit {1}; environment report(s): {2}; reports: {3}; what the user sees: {4}' -f $what, $r.ExitCode, $r.EnvironmentReports.Count, $r.Reports.Count, $shown); Evidence = @('en-US\launcher-output.log', 'en-US\LauncherError.txt', 'en-US\NetworkHealthCheck_ENVIRONMENT_*.txt') }
           }
           Cleanup = @{ Instruction = @('AppLocker > Configure rule enforcement > Script rules: Not configured; delete the Script rules; gpupdate /force. Then put the Application Identity service back as it was before this scenario (the campaign recorded its startup type and state and checks them): in an ELEVATED command prompt   sc config AppIDSvc start= <manual|auto|disabled>   and   net stop AppIDSvc   if it was stopped. Then answer done.',
                                        'AppLocker > 設定規則強制執行 > 指令碼規則：尚未設定；刪除指令碼規則；gpupdate /force。然後把 Application Identity 服務改回這個情境之前的狀態（campaign 有記錄啟動類型與狀態並會檢查）：在「以系統管理員身分執行」的命令提示字元執行 sc config AppIDSvc start= <manual|auto|disabled>，若原本是停止的再執行 net stop AppIDSvc。完成後輸入 done。')
                        Verify = { param($Ctx)
                            # The precondition proved the policy readable; a policy that cannot be read now does not certify the revert (PR #11 round 3).
                            try {
                                $p = Get-AppLockerPolicy -Effective -ErrorAction Stop
                                $s = @($p.RuleCollections | Where-Object { [string]$_.RuleCollectionType -eq 'Script' })[0]
                                if ($null -ne $s -and [string]$s.EnforcementMode -eq 'Enabled') { return @{ Ok = $false; Detail = 'Script rules still enforced' } }
                                if ($null -ne $s -and [int]$s.Count -gt 0) { return @{ Ok = $false; Detail = ('{0} Script rule(s) still present ({1}); the revert asks for them deleted' -f $s.Count, $s.EnforcementMode) } }
                                $svc = Get-Service -Name AppIDSvc -ErrorAction Stop
                                $wantType = [string]$Ctx.Facts.AppIDSvcStartType; $wantStatus = [string]$Ctx.Facts.AppIDSvcStatus
                                if ($wantType -ne 'n/a' -and ([string]$svc.StartType -ne $wantType -or [string]$svc.Status -ne $wantStatus)) { return @{ Ok = $false; Detail = ('Script rules no longer enforced, but AppIDSvc is {0} ({1}); it was {2} ({3}) before M9' -f $svc.StartType, $svc.Status, $wantType, $wantStatus) } }
                                @{ Ok = $true; Detail = ('Script rules no longer enforced; AppIDSvc {0} ({1}) as before' -f $svc.StartType, $svc.Status) }
                            }
                            catch { @{ Ok = $false; Detail = ('cannot read the AppLocker policy or the service now: ' + $_.Exception.Message) } }
                        } } },
        @{ Id = 'A2'; Title = 'The acceptance runner as a standard user'; Kind = 'auto'; Session = 'standard'
           Instruction = @('Create a standard user if none exists (elevated: net user nhc-test <password> /add), sign out, sign in as that user, and run:', ('    ' + $ResumeCommand), 'Then sign back in as the administrator and run the same command once more to finish the campaign.',
                           '若還沒有標準使用者，先建立一個（系統管理員：net user nhc-test <密碼> /add），登出、以該使用者登入，執行上面的命令。之後再以系統管理員登入、再執行一次同樣的命令來完成 campaign。')
           Action = { param($Ctx)
               $extra = @('-Zip', $State.ZipCopy)
               if ($State.ExpectedSha256) { $extra += @('-ExpectedSha256', $State.ExpectedSha256) }
               $r = Invoke-Acceptance $Ctx.Id $extra
               @{ Passed = ($r.ExitCode -eq 0); Detail = ('as {0}: exit code {1}; {2}' -f $env:USERNAME, $r.ExitCode, $r.Summary); Evidence = @($r.Bundle, 'acceptance.log') }
           } }
    )
}

# -------------------- One scenario --------------------
function Invoke-Scenario($S) {
    # Returns 'next' or 'stop'. Records PASS / FAIL / SKIPPED / PENDING in the state.
    $id = $S.Id
    if ($null -eq $State.Scenarios[$id]) { $State.Scenarios[$id] = [ordered]@{ Title = $S.Title; Result = ''; Detail = ''; Seconds = 0; Started = ''; Finished = ''; Evidence = @(); Answers = [ordered]@{}; Reverted = ''; ActionResult = ''; ActionDetail = ''; Attempted = $false; Facts = [ordered]@{} } }
    $rec = $State.Scenarios[$id]
    if ($rec.Result -and $rec.Result -ne 'PENDING') { Write-Host ('[{0}] {1}: recorded earlier at {2} - {3}' -f $rec.Result, $id, $rec.Finished, $rec.Detail) -ForegroundColor DarkGray; return 'next' }
    Write-Host ''
    Write-Host ('=== {0} - {1} ===' -f $id, $S.Title) -ForegroundColor White
    if ($rec.Result -eq 'PENDING' -and $rec.ActionResult) {
        # The scenario ran and the machine was not put back (the campaign stopped at the revert prompt, or the revert
        # could not be verified): the action is not run again - only the revert is asked for, then the result is final.
        Write-Host ('  the scenario ran earlier ({0}: {1}); the change is still to be reverted' -f $rec.ActionResult, $rec.ActionDetail) -ForegroundColor Yellow
        $ctx = @{ Id = $id; Dir = (Join-Path $StateDir $id); Started = (Get-Date); Facts = $rec.Facts }
        return (Complete-Cleanup $S $rec $ctx)
    }
    if ($S.Session -eq 'standard' -and -not $IsStandardUser) {
        Write-Line $S.Instruction 'Cyan'
        Set-Result $id 'PENDING' 'needs a standard-user session; run the command above there' @() 0
        return 'next'
    }
    if ($S.Session -ne 'standard' -and $IsStandardUser) {
        Set-Result $id 'PENDING' 'left for the administrator session' @() 0
        return 'next'
    }
    if ($S.NeedsGui -and $State.SkipGui) { Set-Result $id 'SKIPPED' '-SkipGui' @() 0; return 'next' }
    $dir = Join-Path $StateDir $id
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $ctx = @{ Id = $id; Dir = $dir; Started = (Get-Date); Facts = [ordered]@{} }
    if ($null -ne $S.Prepare) {
        # What the machine looked like before the change - recorded once: a campaign interrupted at the gate, after the
        # person changed the machine, must not describe the changed machine as the original on resume (PR #11 round 2).
        if ($null -ne $rec.Facts -and @($rec.Facts.Keys).Count -gt 0) { $ctx.Facts = $rec.Facts; Write-Host ('  facts recorded earlier are kept: ' + (@($rec.Facts.Keys | ForEach-Object { $_ + '=' + $rec.Facts[$_] }) -join ', ')) -ForegroundColor DarkGray }
        else {
            try { $ctx.Facts = ConvertTo-Hashtable (& $S.Prepare $ctx); $rec.Facts = $ctx.Facts; Write-RecoveryNotes }   # the notes name the recorded state
            catch { Set-Result $id 'FAIL' ('could not prepare the scenario: ' + $_.Exception.Message) @() 0; return 'next' }
        }
    }
    $rec.Started = (& $Now)
    Save-State
    if ($S.Kind -ne 'auto') {
        Write-Line $S.Instruction 'Cyan'
        # Once the person has answered done, the change may be on the machine whether or not the precondition agreed
        # (a NIC disconnected while another still has an address, a policy half applied): from then on a skip goes
        # through the revert like a finished scenario would, and only a skip before any attempt leaves at once (PR #11
        # round 3).
        $attempted = [bool]$rec.Attempted   # persisted: a quit or a crash after the first done must not forget the attempt (PR #11 round 4)
        $skipReason = ''
        while ($true) {
            $gate = Read-Answer $id 'gate' @('When done, answer done; skip to leave this scenario out; quit to stop the campaign here.', '完成後輸入 done；要略過這個情境輸入 skip；要在這裡中止 campaign 輸入 quit。') @('done', 'skip', 'quit') 'skip'
            if ($gate -eq 'quit') { Set-Result $id 'PENDING' $(if ($attempted) { 'quit by the user after an attempt; the change, if any, may still be on the machine' } else { 'quit by the user' }) @() 0; return 'stop' }
            if ($gate -ne 'done' -and $gate -ne 'skip') { Set-Result $id 'PENDING' ("unrecognized answer '" + $gate + "' at the gate (done / skip / quit); nothing was run") @() 0; return 'next' }
            if ($gate -ne 'done') {
                if (-not $skipReason) { $skipReason = 'skipped by the user' }
                if ($attempted -and $null -ne $S.Cleanup) {
                    $rec.ActionResult = 'SKIPPED'; $rec.ActionDetail = $skipReason; $rec.Evidence = @(); $rec.Seconds = 0
                    Set-Result $id 'PENDING' ('skipped after an attempt ({0}); the change, if any, is still to be reverted' -f $skipReason) @() 0
                    return (Complete-Cleanup $S $rec $ctx)
                }
                Set-Result $id 'SKIPPED' $skipReason @() 0
                return 'next'
            }
            $attempted = $true
            if (-not $rec.Attempted) { $rec.Attempted = $true; Save-State }
            if ($null -eq $S.Precondition) { break }
            $pc = & $S.Precondition
            if ($pc.Ok) { Add-Event ('{0}: precondition met - {1}' -f $id, $pc.Detail); break }
            Write-Line @(('Not yet: ' + $pc.Detail), ('還沒好：' + $pc.Detail)) 'Yellow'
            $skipReason = 'precondition not met: ' + $pc.Detail
            if ($null -ne $AnswersTable) {
                if ($null -ne $S.Cleanup) {
                    $rec.ActionResult = 'SKIPPED'; $rec.ActionDetail = $skipReason; $rec.Evidence = @(); $rec.Seconds = 0
                    Set-Result $id 'PENDING' ('skipped after an attempt ({0}); the change, if any, is still to be reverted' -f $skipReason) @() 0
                    return (Complete-Cleanup $S $rec $ctx)
                }
                Set-Result $id 'SKIPPED' $skipReason @() 0
                return 'next'
            }
        }
    }
    else { Write-Line $S.Instruction 'Cyan' }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try { $r = @(& $S.Action $ctx | Where-Object { $_ -is [hashtable] })[-1] }
    catch { $r = @{ Passed = $false; Detail = ('exception: ' + $_.Exception.Message); Evidence = @() } }
    $sw.Stop()
    if ($null -eq $r) { $r = @{ Passed = $false; Detail = 'the scenario returned no result'; Evidence = @() } }
    $outcome = $(if ($r.Passed) { 'PASS' } else { 'FAIL' })
    if ($null -eq $S.Cleanup) { Set-Result $id $outcome ([string]$r.Detail) @($r.Evidence) $sw.Elapsed.TotalSeconds; return 'next' }
    # A scenario that changed the machine is not final until the change is verified gone (PR #11 round 1): the action's
    # outcome is kept aside and the record stays PENDING, so that a campaign stopped or killed at the revert prompt
    # resumes at the revert, counts in the exit code until then, and never exits 0 with the machine still changed.
    $rec.ActionResult = $outcome; $rec.ActionDetail = [string]$r.Detail; $rec.Evidence = @($r.Evidence | Where-Object { $_ }); $rec.Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    Set-Result $id 'PENDING' ('ran ({0}); the change is still to be reverted' -f $outcome) @($r.Evidence) $sw.Elapsed.TotalSeconds
    return (Complete-Cleanup $S $rec $ctx)
}
function Complete-Cleanup($S, $rec, $ctx) {
    # The machine must be put back before the next scenario: the prompt repeats until the change is verified gone, and
    # only then does the action's outcome become the scenario's result. A quit, or a revert the answers file cannot
    # verify, leaves the scenario PENDING with the change named - the exit code counts it, and a resume asks again.
    $id = $S.Id
    Write-Line $S.Cleanup.Instruction 'Cyan'
    while ($true) {
        $gate = Read-Answer $id 'revert' @('When reverted, answer done; quit to stop the campaign here (the change stays in place until the campaign is resumed!).', '還原後輸入 done；要在這裡中止 campaign 輸入 quit（在 campaign 續跑之前，變更會留在機器上！）。') @('done', 'quit') 'done'
        if ($gate -eq 'quit') { $rec.Reverted = 'NOT REVERTED - quit'; Set-Result $id 'PENDING' ('ran ({0}) but NOT REVERTED - quit; resume to put the machine back' -f $rec.ActionResult) @($rec.Evidence) $rec.Seconds; Add-Event ('{0}: the campaign stopped with the change still in place' -f $id); return 'stop' }
        # Anything short of a verified revert stops the campaign here, like a quit: the next scenario must not run on a
        # machine that may still be changed (PR #11 round 8).
        if ($gate -ne 'done') { $rec.Reverted = 'NOT VERIFIED - unrecognized answer'; Set-Result $id 'PENDING' ("ran ({0}) but the revert was not confirmed: unrecognized answer '{1}' (done / quit); resume to put the machine back" -f $rec.ActionResult, $gate) @($rec.Evidence) $rec.Seconds; Add-Event ('{0}: the campaign stopped with the revert unconfirmed' -f $id); return 'stop' }
        $v = & $S.Cleanup.Verify $ctx
        if ($v.Ok) {
            $rec.Reverted = 'yes - ' + $v.Detail
            Add-Event ('{0}: reverted - {1}' -f $id, $v.Detail)
            Set-Result $id $rec.ActionResult $rec.ActionDetail @($rec.Evidence) $rec.Seconds   # the scenario's own detail, not the pending text
            return 'next'
        }
        Write-Line @(('Still in place: ' + $v.Detail), ('還沒還原：' + $v.Detail)) 'Yellow'
        if ($null -ne $AnswersTable) { $rec.Reverted = 'NOT VERIFIED - ' + $v.Detail; Set-Result $id 'PENDING' ('ran ({0}) but NOT REVERTED - {1}; resume to put the machine back' -f $rec.ActionResult, $v.Detail) @($rec.Evidence) $rec.Seconds; Add-Event ('{0}: the campaign stopped with the change still in place' -f $id); return 'stop' }
    }
}

# -------------------- The campaign --------------------
$plan = Get-Plan
if ($Wanted.Count) { $selected = @($plan | Where-Object { $Wanted -contains $_.Id }) } else { $selected = $plan }
foreach ($s in $plan) { if ($null -eq $State.Scenarios[$s.Id]) { $State.Scenarios[$s.Id] = [ordered]@{ Title = $s.Title; Result = ''; Detail = ''; Seconds = 0; Started = ''; Finished = ''; Evidence = @(); Answers = [ordered]@{}; Reverted = ''; ActionResult = ''; ActionDetail = ''; Attempted = $false; Facts = [ordered]@{} } } }
Save-State
Add-Event ('invocation by {0}{1}: scenarios {2}{3}' -f $env:USERNAME, $(if ($IsStandardUser) { ' (standard user)' } else { '' }), (@($selected | ForEach-Object { $_.Id }) -join ','), $(if ($null -ne $AnswersTable) { '; answers from ' + $Answers } else { '' }))
$stopped = $false
foreach ($s in $selected) {
    if ($stopped) { if (-not $State.Scenarios[$s.Id].Result) { Set-Result $s.Id 'PENDING' 'not reached: the campaign was stopped earlier' @() 0 }; continue }
    if ((Invoke-Scenario $s) -eq 'stop') { $stopped = $true }
}
Save-State   # the invocation's event, and anything a scenario that ran nothing left in memory

# -------------------- The summary and the bundle --------------------
$rows = @()
foreach ($s in $plan) {
    $rec = $State.Scenarios[$s.Id]
    $result = $(if ($rec.Result) { $rec.Result } else { 'PENDING' })
    $detail = $(if ($rec.Result) { $rec.Detail } else { 'not run yet' })
    $rows += [pscustomobject]@{ Id = $s.Id; Title = $s.Title; Result = $result; Seconds = $rec.Seconds; Detail = $detail; Reverted = $rec.Reverted; Finished = $rec.Finished }
}
$passed = @($rows | Where-Object { $_.Result -eq 'PASS' }).Count
$failed = @($rows | Where-Object { $_.Result -eq 'FAIL' }).Count
$skipped = @($rows | Where-Object { $_.Result -eq 'SKIPPED' }).Count
$pending = @($rows | Where-Object { $_.Result -eq 'PENDING' }).Count
# The exit code answers for this invocation: every failure on record, plus what this invocation selected and could
# not finish (quit, not reached, left for another session). Scenarios never selected stay pending in the summary
# without counting, so that a partial run on purpose (-Scenarios) can exit 0.
$selectedIds = @($selected | ForEach-Object { $_.Id })
$pendingSelected = @($rows | Where-Object { $_.Result -eq 'PENDING' -and $selectedIds -contains $_.Id }).Count
$md = @()
$md += ('# NetworkHealthCheck {0} acceptance campaign - {1}' -f $State.ToolVersion, $Campaign)
$md += ''
$md += ('- Machine: {0}; started {1} by {2}; this invocation {3} by {4}{5}' -f $State.Computer, $State.Created, $State.StartedBy, (& $Now), $env:USERNAME, $(if ($IsStandardUser) { ' (standard user)' } else { '' }))
$md += ('- Asset: {0} (SHA256 {1}{2})' -f (Split-Path -Leaf $State.ZipCopy), $State.Digest, $(if ($State.ExpectedSha256) { ', matches the release notes' } else { ', not compared' }))
$md += ('- Real windows: {0}; state: {1}' -f $(if ($State.SkipGui) { 'none (-SkipGui)' } else { 'yes' }), $StateDir)
$md += ('- Recovery without PowerShell (a policy scenario interrupted before its revert): {0}' -f $RecoveryNotes)
$md += ''
$md += '| Id | Scenario | Result | s | Detail | Reverted | Finished |'
$md += '|---|---|---|---:|---|---|---|'
$md += @($rows | ForEach-Object { '| {0} | {1} | {2} | {3} | {4} | {5} | {6} |' -f $_.Id, $_.Title, $_.Result, $_.Seconds, ($_.Detail -replace '\|', '\|'), $_.Reverted, $_.Finished })
$md += ''
$md += ('Summary: {0} passed, {1} failed, {2} skipped, {3} pending' -f $passed, $failed, $skipped, $pending)
$summaryPath = Join-Path $StateDir 'campaign_summary.md'
[IO.File]::WriteAllLines($summaryPath, [string[]]$md, $Utf8NoBom)
Write-Host ''
$rows | Format-Table -AutoSize -Wrap Id, Result, Seconds, Detail | Out-String -Width 220 | Write-Host
Write-Host $md[-1]
try {
    # The bundle: the summary, the state, the answers, and per scenario its evidence - never the work dirs, the staged
    # package copies' program files, or the package itself.
    $bundle = Join-Path $StateDir 'bundle'
    if (Test-Path -LiteralPath $bundle) { Remove-Item -LiteralPath $bundle -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $bundle | Out-Null
    foreach ($f in @($summaryPath, $StateFile, $AnswersLog, $RecoveryNotes, (Join-Path $StateDir 'undo-M7.cmd'))) { if (Test-Path -LiteralPath $f) { Copy-Item -LiteralPath $f -Destination $bundle } }
    foreach ($s in $plan) {
        $dir = Join-Path $StateDir $s.Id
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        Get-ChildItem -LiteralPath $dir -Recurse -File | Where-Object { $_.FullName -notmatch '\\work\\' -and ($_.Extension -in @('.log', '.png', '.zip', '.json', '.html', '.txt')) -and $_.Name -notlike '*.config.json' -and $_.Name -notlike 'README_*' } | ForEach-Object {
            $target = Join-Path $bundle ($_.FullName.Substring($StateDir.Length).TrimStart('\'))
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
            Copy-Item -LiteralPath $_.FullName -Destination $target -Force
        }
    }
    $zipOut = Join-Path $StateDir ('nhc-campaign_{0}_{1}.zip' -f $State.Computer, $Campaign)
    if (Test-Path -LiteralPath $zipOut) { Remove-Item -LiteralPath $zipOut -Force }
    Compress-Archive -Path (Join-Path $bundle '*') -DestinationPath $zipOut
    Write-Host ('bundle {0} ({1} bytes)' -f $zipOut, (Get-Item -LiteralPath $zipOut).Length)
}
catch { Write-Host ('bundle not written: ' + $_.Exception.Message + ' - the state folder holds everything: ' + $StateDir) -ForegroundColor Red; $failed++ }
if ($pending -gt 0) { Write-Line @(('{0} scenario(s) pending. To continue: ' -f $pending), ('    ' + $ResumeCommand)) 'Cyan' }
exit ($failed + $pendingSelected)
