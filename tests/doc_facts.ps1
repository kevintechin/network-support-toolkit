<#
.SYNOPSIS
    Checks the documents against the program's own identifiers (backlog #33, tier 1).

.DESCRIPTION
    The manuals, the guides and the sop/ field manual quote things the program defines: result tags, fingerprint keys,
    configuration keys, exit codes, launcher and program file names, and their own section numbers. Nothing keeps those
    in step with the scripts except a person remembering, and every claim lives in four files at once (two languages
    times markdown and HTML), so a fix that lands in one copy is invisible.

    This step reads the identifiers out of the shipped scripts and the shipped configuration - no run of the tool, no
    network, no Python - and asserts both directions where both are sound: that every identifier a document quotes
    exists in the program, and that every identifier the program has is documented where that document claims to
    document them. It cannot check prose, and it does not try: a sentence that states a rule from one side only is what
    the review loop is for.

    What it does not check is written down as it goes: the internal tags below are named in one list, so a new tag
    forces a decision instead of slipping through.

.PARAMETER PackageDir
    The package - a folder holding en-US\ and zh-TW\. Default: the checkout's healthcheck\.
.PARAMETER RepoRoot
    The checkout, for the documents outside the package (sop\). Default: the parent of tests\. Pass -PackageOnly to
    leave them out, which is what a run against an extracted release asset wants.
.PARAMETER PackageOnly
    Check only the documents that ship inside the package.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\doc_facts.ps1
#>
param(
    [string]$PackageDir,
    [string]$RepoRoot,
    [switch]$PackageOnly
)

$ErrorActionPreference = 'Stop'
if (-not $RepoRoot) { $RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path }
if (-not $PackageDir) { $PackageDir = Join-Path $RepoRoot 'healthcheck' }
$PackageDir = (Resolve-Path -LiteralPath $PackageDir).Path
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path

$fails = 0; $passes = 0
function Assert-True([string]$name, [bool]$ok, [string]$detail) {
    if ($ok) { $script:passes++; Write-Output "[PASS] $name" }
    else { $script:fails++; Write-Output ("[FAIL] $name -> $detail") }
}
function Assert-SetEqual([string]$name, $actual, $expected) {
    $a = @($actual | Sort-Object -Unique); $e = @($expected | Sort-Object -Unique)
    $only = @($a | Where-Object { $e -notcontains $_ })
    $miss = @($e | Where-Object { $a -notcontains $_ })
    $detail = @()
    if ($miss.Count) { $detail += ('missing: ' + ($miss -join ', ')) }
    if ($only.Count) { $detail += ('unexpected: ' + ($only -join ', ')) }
    Assert-True $name (($only.Count -eq 0) -and ($miss.Count -eq 0)) ($detail -join '; ')
}
function Assert-Covered([string]$name, $required, $present) {
    $miss = @($required | Where-Object { $present -notcontains $_ })
    Assert-True $name ($miss.Count -eq 0) ('not documented: ' + ($miss -join ', '))
}

function Read-Text([string]$path) { [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) }
function ConvertFrom-HtmlText([string]$s) {
    ($s -replace '<[^>]+>', '') -replace '&lt;', '<' -replace '&gt;', '>' -replace '&quot;', '"' -replace '&#39;', "'" -replace '&amp;', '&'
}
function Get-CodeSpans([string]$path) {
    # The identifiers a document means as identifiers: `x` in markdown, <code>x</code> in HTML. Prose is not searched -
    # "config" and "healthy" are ordinary words, and a substring match on them would pass for the wrong reason.
    $text = Read-Text $path
    $out = New-Object System.Collections.Generic.List[string]
    if ($path -like '*.html') {
        foreach ($m in [regex]::Matches($text, '(?s)<code[^>]*>(.*?)</code>')) { $out.Add((ConvertFrom-HtmlText $m.Groups[1].Value).Trim()) }
        # The sop/ pages give a fingerprint name its own badge instead of a code span; it is the same identifier.
        foreach ($m in [regex]::Matches($text, '(?s)<span class="fp"[^>]*>(.*?)</span>')) { $out.Add((ConvertFrom-HtmlText $m.Groups[1].Value).Trim()) }
    } else {
        $stripped = [regex]::Replace($text, '(?s)```.*?```', ' ')
        foreach ($m in [regex]::Matches($stripped, '`([^`\r\n]+)`')) { $out.Add($m.Groups[1].Value.Trim()) }
    }
    return @($out | Sort-Object -Unique)
}
function Get-CodeBlocks([string]$path) {
    $text = Read-Text $path
    $out = New-Object System.Collections.Generic.List[string]
    if ($path -like '*.html') {
        foreach ($m in [regex]::Matches($text, '(?s)<pre[^>]*>(.*?)</pre>')) { $out.Add((ConvertFrom-HtmlText $m.Groups[1].Value)) }
    } else {
        foreach ($m in [regex]::Matches($text, '(?s)```[a-z]*\r?\n(.*?)```')) { $out.Add($m.Groups[1].Value) }
    }
    return @($out)
}

# ----------------------------------------------------------------- ground truth
$Languages = @('en-US', 'zh-TW')
$tags = @{}; $fingerprints = @{}; $fingerprintTitles = @{}; $exitCodes = @{}; $configKeys = @{}
foreach ($lang in $Languages) {
    $scriptPath = Join-Path $PackageDir ($lang + '\NetworkHealthCheck.ps1')
    $text = Read-Text $scriptPath
    $tags[$lang] = @([regex]::Matches($text, 'Tag\s+"([a-z0-9-]+)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    $exitCodes[$lang] = @([regex]::Matches($text, '(?m)^\s*exit\s+(\d+)\s*$') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)

    # The fingerprint chain, read from the function itself rather than from the whole file: $key is assigned nowhere
    # else in it, but a regex over the file would not know that.
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
    $fn = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-FingerprintSummary' }, $true))
    if ($fn.Count -ne 1) { throw ('Get-FingerprintSummary not found once in ' + $scriptPath) }
    $body = $fn[0].Extent.Text
    $fingerprints[$lang] = @([regex]::Matches($body, '\$key\s*=\s*"([a-z-]+)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    $fingerprintTitles[$lang] = @([regex]::Matches($body, '(?m)^\s*"([a-z-]+)"\s*\{\s*\$title') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)

    $cfg = Get-Content -LiteralPath (Join-Path $PackageDir ($lang + '\NetworkHealthCheck.config.json')) -Raw -Encoding UTF8 | ConvertFrom-Json
    $keys = New-Object System.Collections.Generic.List[string]
    function Add-Keys($obj, [string]$prefix) {
        foreach ($p in $obj.PSObject.Properties) {
            $script:keyList.Add($prefix + $p.Name)
            if ($p.Value -is [PSCustomObject]) { Add-Keys $p.Value ($prefix + $p.Name + '.') }
            # A list of targets carries keys of its own - Name, Address, Required, Host, Port, Url, Group - and an IT
            # person has to write those too, so every element is walked, not only the objects.
            elseif ($p.Value -is [object[]]) {
                foreach ($item in $p.Value) { if ($item -is [PSCustomObject]) { Add-Keys $item ($prefix + $p.Name + '.') } }
            }
        }
    }
    $script:keyList = $keys
    Add-Keys $cfg ''
    $configKeys[$lang] = @($keys | Sort-Object -Unique)
}

# The tags that carry no row of their own in the field manual's inventory: the configuration and environment rows the
# report opens with, the per-step error row, and the startup notice. A tag added to the script fails the coverage
# check below until it is documented or named here on purpose.
$InternalTags = @('config', 'config-file', 'environment', 'startup', 'step-error', 'system')

# ------------------------------------------------------------------- documents
function Package-Doc([string]$rel) { Join-Path $PackageDir $rel }
$ItManuals = @(
    (Package-Doc 'en-US\NetworkHealthCheck_IT_Deployment_Manual_en-US.md'),
    (Package-Doc 'en-US\NetworkHealthCheck_IT_Deployment_Manual_en-US.html'),
    (Package-Doc 'zh-TW\NetworkHealthCheck_IT_Deployment_Manual_zh-TW.md'),
    (Package-Doc 'zh-TW\NetworkHealthCheck_IT_Deployment_Manual_zh-TW.html'))
$UserManuals = @(
    (Package-Doc 'en-US\NetworkHealthCheck_User_Manual_en-US.md'),
    (Package-Doc 'en-US\NetworkHealthCheck_User_Manual_en-US.html'),
    (Package-Doc 'zh-TW\NetworkHealthCheck_User_Manual_zh-TW.md'),
    (Package-Doc 'zh-TW\NetworkHealthCheck_User_Manual_zh-TW.html'))
$Guides = @()
foreach ($folder in @('docs', 'en-US', 'zh-TW')) {
    foreach ($lang in $Languages) { $Guides += (Package-Doc ($folder + '\NetworkHealthCheck_Technical_Guide_' + $lang + '.md')) }
}
$FieldManual = @()
if (-not $PackageOnly) {
    $FieldManual = @((Join-Path $RepoRoot 'sop\support-engineer-field-manual.md'), (Join-Path $RepoRoot 'sop\support-engineer-field-manual.html'))
}
$AllDocs = @($ItManuals + $UserManuals + $Guides + $FieldManual)
foreach ($d in $AllDocs) { if (-not (Test-Path -LiteralPath $d)) { throw ('document not found: ' + $d) } }
Write-Output ("Documents: {0} in the package{1}" -f (@($ItManuals + $UserManuals + $Guides)).Count, $(if ($PackageOnly) { '' } else { ', 2 in sop/' }))
Write-Output ("Identifiers: {0} tags, {1} fingerprints, {2} configuration keys, exit code(s) {3}" -f $tags['en-US'].Count, $fingerprints['en-US'].Count, $configKeys['en-US'].Count, ($exitCodes['en-US'] -join '/'))

# --------------------------------------------------- A. the two languages agree
Assert-SetEqual 'A1 result tags are the same in both scripts' $tags['zh-TW'] $tags['en-US']
Assert-SetEqual 'A2 fingerprint keys are the same in both scripts' $fingerprints['zh-TW'] $fingerprints['en-US']
Assert-SetEqual 'A3 exit codes are the same in both scripts' $exitCodes['zh-TW'] $exitCodes['en-US']
Assert-SetEqual 'A4 configuration keys are the same in both files' $configKeys['zh-TW'] $configKeys['en-US']
foreach ($lang in $Languages) {
    # Every fingerprint the chain can select has a title and its advice lines; "healthy" is the switch's default.
    Assert-SetEqual ("A5 [{0}] every fingerprint key has a case in the switch" -f $lang) $fingerprintTitles[$lang] @($fingerprints[$lang] | Where-Object { $_ -ne 'healthy' })
}

# ------------------------- B. the configuration file and the IT deployment manual
$leafKeys = @($configKeys['en-US'] | Where-Object { $_ -like '*.*' } | ForEach-Object { $_.Split('.')[-1] } | Sort-Object -Unique)
$containerKeys = @($configKeys['en-US'] | Where-Object { $_ -notlike '*.*' } | Where-Object { $k = $_; @($configKeys['en-US'] | Where-Object { $_ -like ($k + '.*') }).Count -gt 0 })
$topLeafKeys = @($configKeys['en-US'] | Where-Object { $_ -notlike '*.*' -and $containerKeys -notcontains $_ })
foreach ($doc in $ItManuals) {
    $name = Split-Path -Leaf $doc
    $spans = Get-CodeSpans $doc
    $blocks = (Get-CodeBlocks $doc) -join "`n"
    $documented = @(($leafKeys + $topLeafKeys) | Where-Object { ($spans -contains $_) -or ($blocks -match ('"' + [regex]::Escape($_) + '"')) })
    Assert-Covered ("B1 [{0}] every configuration key is quoted" -f $name) ($leafKeys + $topLeafKeys) $documented

    # A container is the object an IT person has to put the key inside, so its name has to appear as well - in the
    # heading of its section, in a JSON example, or in the prose.
    $text = Read-Text $doc
    $missingContainers = @($containerKeys | Where-Object { $text -notmatch ('(?<![A-Za-z])' + [regex]::Escape($_) + '(?![A-Za-z])') })
    Assert-True ("B2 [{0}] every configuration container is named" -f $name) ($missingContainers.Count -eq 0) ('not named: ' + ($missingContainers -join ', '))

    # And nothing is documented that the configuration does not have: the keys of every example that is a configuration
    # example (one that carries at least one real key) must all be real.
    $phantom = New-Object System.Collections.Generic.List[string]
    foreach ($block in (Get-CodeBlocks $doc)) {
        $blockKeys = @([regex]::Matches($block, '"([A-Za-z][A-Za-z0-9]*)"\s*:') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        if (-not @($blockKeys | Where-Object { $configKeys['en-US'] -contains $_ -or $leafKeys -contains $_ }).Count) { continue }
        foreach ($k in $blockKeys) { if (($leafKeys -notcontains $k) -and ($topLeafKeys -notcontains $k) -and ($containerKeys -notcontains $k)) { $phantom.Add($k) } }
    }
    Assert-True ("B3 [{0}] every key in a configuration example exists" -f $name) ($phantom.Count -eq 0) ('not in the configuration: ' + (@($phantom | Sort-Object -Unique) -join ', '))
}

# ------------------------- C. the fingerprint keys and the documents that name them
foreach ($doc in @($Guides + $FieldManual)) {
    $name = (Split-Path -Leaf (Split-Path -Parent $doc)) + '/' + (Split-Path -Leaf $doc)
    $spans = Get-CodeSpans $doc
    Assert-Covered ("C1 [{0}] every fingerprint key is quoted" -f $name) $fingerprints['en-US'] $spans
}

# ------------------------------------- D. the result tags and the field manual
if (-not $PackageOnly) {
    $stale = @($InternalTags | Where-Object { $tags['en-US'] -notcontains $_ })
    Assert-True 'D1 the internal-tag list has no stale entry' ($stale.Count -eq 0) ('no longer in the script: ' + ($stale -join ', '))
    $documentedTags = @($tags['en-US'] | Where-Object { $InternalTags -notcontains $_ })
    $spans = Get-CodeSpans $FieldManual[0]
    Assert-Covered ("D2 every result tag is documented ({0} of {1}; the rest are internal)" -f $documentedTags.Count, $tags['en-US'].Count) $documentedTags $spans
}

# --------------------------------- E. the file names the documents send people to
$packageFiles = New-Object System.Collections.Generic.List[string]
foreach ($folder in @('', 'en-US', 'zh-TW', 'docs', 'tools')) {
    $path = $(if ($folder) { Join-Path $PackageDir $folder } else { $PackageDir })
    if (Test-Path -LiteralPath $path) { Get-ChildItem -LiteralPath $path -File | ForEach-Object { $packageFiles.Add($_.Name) } }
}
$fileSpanPattern = '^(Start-[A-Za-z-]+\.cmd|NetworkHealthCheck\.ps1|NetworkHealthCheck\.config\.json|SHA256SUMS\.txt|README_BILINGUAL\.md)$'
foreach ($doc in $AllDocs) {
    $name = Split-Path -Leaf $doc
    $quoted = @(Get-CodeSpans $doc | Where-Object { $_ -match $fileSpanPattern })
    $absent = @($quoted | Where-Object { $packageFiles -notcontains $_ })
    Assert-True ("E1 [{0}] the {1} file name(s) it quotes are in the package" -f $name, $quoted.Count) ($absent.Count -eq 0) ('not in the package: ' + ($absent -join ', '))
}

# ------------------------------------------ F. the section numbers a document cites
$MarkdownDocs = @($AllDocs | Where-Object { $_ -like '*.md' })
# A reference into another document names it just before the number - "the user manual, section 5", "field manual, §7".
# The window is short and has to end at the number, because a whole sentence of prose will contain the word "manual"
# often enough to swallow a real mistake: the first version of this rule did, and the self-test caught it.
$OtherDocumentReference = '(?i)(manual|guide|sop|template|readme|page)[^.]{0,20}$'
foreach ($doc in $MarkdownDocs) {
    $name = Split-Path -Leaf $doc
    $text = Read-Text $doc
    $headings = @([regex]::Matches($text, '(?m)^#{2,4}\s+([0-9]+(?:\.[0-9]+)?)\s*[^\r\n]*') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    if (-not $headings.Count) { continue }
    $bad = New-Object System.Collections.Generic.List[string]
    foreach ($m in [regex]::Matches($text, '(?i)\bsections?\s+([0-9]+(?:\.[0-9]+)?)')) {
        $before = $text.Substring([Math]::Max(0, $m.Index - 40), [Math]::Min(40, $m.Index))
        if ($before -match $OtherDocumentReference) { continue }   # a reference into another document
        if ($headings -notcontains $m.Groups[1].Value) { $bad.Add($m.Value.Trim()) }
    }
    Assert-True ("F1 [{0}] every section it cites exists ({1} headings)" -f $name, $headings.Count) ($bad.Count -eq 0) ('no such section: ' + (@($bad | Sort-Object -Unique) -join ', '))
}

Write-Output ("Summary: {0} passed, {1} failed" -f $passes, $fails)
exit $fails
