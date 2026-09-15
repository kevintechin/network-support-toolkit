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
    [switch]$PackageOnly,
    [string]$ReportPath,
    [ValidateSet('en-US', 'zh-TW')]
    [string]$ReportLanguage = 'en-US',
    [switch]$ReportOnly
)

$ErrorActionPreference = 'Stop'
if (-not $RepoRoot) { $RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path }
if (-not $PackageDir) { $PackageDir = Join-Path $RepoRoot 'healthcheck' }
$PackageDir = (Resolve-Path -LiteralPath $PackageDir).Path
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path

if ($ReportOnly -and -not $ReportPath) { throw '-ReportOnly needs -ReportPath: there is no report to read' }

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
    return @($out | Sort-Object -CaseSensitive -Unique)
}
function Get-ScriptFacts([string]$scriptPath) {
    # The -Tag arguments and the exit codes, from the AST rather than from a regular expression: both can be reached
    # through a variable ($pingTag is "ping-target", or "ping-gateway" for AUTO_GATEWAY; the entry points end on
    # "exit $exitCode"), and a pattern over the file text sees neither - which left two live tags and every exit code
    # but one outside the checks below.
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
    $found = New-Object System.Collections.Generic.List[string]
    $unresolved = New-Object System.Collections.Generic.List[string]
    $exits = New-Object System.Collections.Generic.List[string]
    $exitShapes = New-Object System.Collections.Generic.List[string]
    # What each function returns, so that "exit $exitCode" where $exitCode = Start-ConsoleMode is read to the end:
    # the codes that reach the operating system are the ones that function returns, and a change there is a change in
    # behaviour that the shape alone would not show.
    $returns = @{}
    foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        $values = New-Object System.Collections.Generic.List[string]
        foreach ($r in $f.Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.ReturnStatementAst] }, $true)) {
            $node = $r.Pipeline
            if ($node -is [System.Management.Automation.Language.PipelineAst]) {
                $elements = @($node.PipelineElements)
                $node = $(if ($elements.Count -eq 1) { $elements[0] } else { $null })
            }
            $expr = $(if ($node -is [System.Management.Automation.Language.CommandExpressionAst]) { $node.Expression } else { $null })
            if ($expr -is [System.Management.Automation.Language.ConstantExpressionAst]) { $values.Add([string]$expr.Value) }
            elseif ($null -ne $r.Pipeline) { $values.Add('<' + $r.Pipeline.Extent.Text + '>') }
        }
        $returns[$f.Name] = @($values | Sort-Object -Unique)
    }
    $assigned = @{}
    $computed = @{}
    foreach ($a in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
        if (-not ($a.Left -is [System.Management.Automation.Language.VariableExpressionAst])) { continue }
        $name = $a.Left.VariablePath.UserPath
        # Every assignment counts, not only the ones that happen to carry a literal: a variable that is a string
        # constant here and a function call there would otherwise look resolved, and the tag the call returns would be
        # outside every check while A6 stayed green.
        $node = $a.Right
        if ($node -is [System.Management.Automation.Language.PipelineAst]) {
            $elements = @($node.PipelineElements)
            $node = $(if ($elements.Count -eq 1) { $elements[0] } else { $null })
        }
        $expr = $(if ($node -is [System.Management.Automation.Language.CommandExpressionAst]) { $node.Expression } else { $null })
        if ($expr -is [System.Management.Automation.Language.ConstantExpressionAst]) {
            if (-not $assigned.ContainsKey($name)) { $assigned[$name] = New-Object System.Collections.Generic.List[string] }
            $assigned[$name].Add([string]$expr.Value)
        } else {
            if (-not $computed.ContainsKey($name)) { $computed[$name] = New-Object System.Collections.Generic.List[string] }
            $computed[$name].Add($a.Right.Extent.Text + ' at line ' + $a.Extent.StartLineNumber)
        }
    }
    foreach ($cmd in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $elements = @($cmd.CommandElements)
        for ($i = 0; $i -lt $elements.Count; $i++) {
            $e = $elements[$i]
            if (-not ($e -is [System.Management.Automation.Language.CommandParameterAst])) { continue }
            if ($e.ParameterName -ne 'Tag') { continue }
            $arg = $e.Argument
            if (($null -eq $arg) -and (($i + 1) -lt $elements.Count)) { $arg = $elements[$i + 1] }
            if ($arg -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $found.Add($arg.Value) }
            elseif ($arg -is [System.Management.Automation.Language.VariableExpressionAst]) {
                $name = $arg.VariablePath.UserPath
                if ($computed.ContainsKey($name)) { $unresolved.Add('$' + $name + ' is assigned ' + ($computed[$name] -join '; ')) }
                elseif ($assigned.ContainsKey($name)) { foreach ($v in $assigned[$name]) { $found.Add($v) } }
                else { $unresolved.Add('$' + $name + ' at line ' + $arg.Extent.StartLineNumber + ' is never assigned a literal') }
            }
            elseif ($null -eq $arg) { $unresolved.Add('-Tag with no argument at line ' + $e.Extent.StartLineNumber) }
            else { $unresolved.Add($arg.Extent.Text + ' at line ' + $arg.Extent.StartLineNumber) }
        }
    }
    # An exit statement's argument, read the same way. A3 compares the two languages on the literals and on the shapes
    # of whatever is not a literal ("Start-ConsoleMode"), so a changed exit code is caught in either form.
    foreach ($e in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ExitStatementAst] }, $true)) {
        $node = $e.Pipeline
        if ($node -is [System.Management.Automation.Language.PipelineAst]) {
            $elements = @($node.PipelineElements)
            $node = $(if ($elements.Count -eq 1) { $elements[0] } else { $null })
        }
        $expr = $(if ($node -is [System.Management.Automation.Language.CommandExpressionAst]) { $node.Expression } else { $null })
        if ($expr -is [System.Management.Automation.Language.ConstantExpressionAst]) { $exits.Add([string]$expr.Value) }
        elseif ($expr -is [System.Management.Automation.Language.VariableExpressionAst]) {
            $name = $expr.VariablePath.UserPath
            if ($assigned.ContainsKey($name)) { foreach ($v in $assigned[$name]) { $exits.Add([string]$v) } }
            if ($computed.ContainsKey($name)) {
                foreach ($v in $computed[$name]) {
                    $shape = $v -replace ' at line \d+$', ''
                    $exitShapes.Add($shape)
                    # A call to a function of this script is followed into it: its literal returns are exit codes too.
                    if ($returns.ContainsKey($shape.Trim())) { foreach ($r in $returns[$shape.Trim()]) { $exits.Add($r) } }
                }
            }
            if (-not ($assigned.ContainsKey($name) -or $computed.ContainsKey($name))) { $exitShapes.Add('$' + $name + ' is never assigned') }
        }
        elseif ($null -eq $expr) { $exitShapes.Add('exit with no argument') }
        else { $exitShapes.Add($expr.Extent.Text) }
    }
    return @{
        Tags = @($found | Sort-Object -Unique); Unresolved = @($unresolved | Sort-Object -Unique)
        ExitCodes = @($exits | Sort-Object -Unique); ExitShapes = @($exitShapes | Sort-Object -Unique)
    }
}
function Remove-IndentedCode([string]$text) {
    # Markdown's third code form: four spaces or a tab, in a place where a paragraph could have started. Inside a
    # list those same four spaces are the item's own continuation and the text in them is ordinary - stripping
    # every indented line would hide emphasis a manual really carries and report a verdict as undocumented, so the
    # condition is what is written here rather than a pattern (PR #64, round 9).
    $lines = $text -split '\r?\n'
    $out = New-Object System.Collections.Generic.List[string]
    $inList = $false
    foreach ($line in $lines) {
        if ($line -match '^\s*$') { $out.Add($line); continue }
        $indented = $line -match '^(?: {4,}|\t)'
        if (-not $indented) {
            $inList = ($line -match '^\s{0,3}(?:[-*+]\s|[0-9]+[.)]\s)')
            $out.Add($line)
            continue
        }
        if ($inList) { $out.Add($line) } else { $out.Add(' ') }
    }
    return ($out -join [Environment]::NewLine)
}

function Get-EmphasisSpans([string]$path) {
    # Unique, case-sensitively: a manual writes both `**Information**` and `**information**`, and a fold would keep
    # one of them - which is how the strings this reader exists for came to be missing from it (PR #64, round 2).
    # What a document quotes from the screen - a verdict line, a badge word - is emphasised rather than coded: it is
    # a phrase the reader sees in the report, not an identifier. Only the coverage direction is ever asserted over
    # these, because a manual emphasises ordinary phrases too and the reverse reading would be prose interpretation.
    # Code regions go first, both ways round: `**Overall Healthy**` renders as code, and a reader of the raw source
    # would take the asterisks inside it for emphasis and call the verdict documented (PR #64, round 6).
    $text = Read-Text $path
    $out = New-Object System.Collections.Generic.List[string]
    if ($path -like '*.html') {
        $text = [regex]::Replace($text, '(?s)<!--.*?-->', ' ')
        $text = [regex]::Replace($text, '(?s)<code[^>]*>.*?</code>', ' ')
        $text = [regex]::Replace($text, '(?s)<pre[^>]*>.*?</pre>', ' ')
        foreach ($m in [regex]::Matches($text, '(?s)<(strong|b|em)[^>]*>(.*?)</\1>')) { $out.Add((ConvertFrom-HtmlText $m.Groups[2].Value).Trim()) }
        # A page gives a verdict its own badge where the markdown puts it in bold, as the sop/ pages badge a
        # fingerprint name: the first run of this check reported "Overall Healthy" as undocumented in both HTML
        # manuals, where it is on the screen in a badge and the markdown's bold row is what the reader sees.
        foreach ($m in [regex]::Matches($text, '(?s)<span class="verdict[^"]*"[^>]*>(.*?)</span>')) { $out.Add((ConvertFrom-HtmlText $m.Groups[1].Value).Trim()) }
    } else {
        # A code span is opened by a run of backticks of any length and closed by one as long, which covers the
        # fenced block and the double-backtick span alike; an HTML comment renders as nothing at all. Round 6 read
        # one backtick only, so `` **Overall Healthy** `` still offered its asterisks to the reader below
        # (PR #64, round 7).
        $text = [regex]::Replace($text, '(?s)<!--.*?-->', ' ')
        # Markdown fences with tildes as well as with backticks, and a ~~~ block is code just the same.
        $text = [regex]::Replace($text, '(?m)^(~{3,})[^\r\n]*\r?\n[\s\S]*?^\1[^\r\n]*$', ' ')
        $text = [regex]::Replace($text, '(?s)(`+)(?:(?!\1).)*\1', ' ')
        $text = Remove-IndentedCode $text
        foreach ($m in [regex]::Matches($text, '\*\*([^*\r\n]+)\*\*')) { $out.Add($m.Groups[1].Value.Trim()) }
        foreach ($m in [regex]::Matches($text, '(?<![*\w])\*([^*\r\n]+)\*(?![*\w])')) { $out.Add($m.Groups[1].Value.Trim()) }
        # Underscores emphasise too, and a manual that changed delimiter without changing what renders would have
        # been told its verdict was undocumented (PR #64, round 10).
        foreach ($m in [regex]::Matches($text, '__([^_\r\n]+)__')) { $out.Add($m.Groups[1].Value.Trim()) }
        foreach ($m in [regex]::Matches($text, '(?<![_\w])_([^_\r\n]+)_(?![_\w])')) { $out.Add($m.Groups[1].Value.Trim()) }
    }
    return @($out | Sort-Object -CaseSensitive -Unique)
}

function Get-SectionRegion([string]$path, [string]$number) {
    # The text of one numbered section, from its own heading to the next heading of the same level. A file table is a
    # section's table, and reading the whole document instead would let a name anywhere in it stand for a row.
    $text = Read-Text $path
    if ($path -like '*.html') {
        $heads = @([regex]::Matches($text, '(?s)<h2[^>]*>(.*?)</h2>'))
        for ($i = 0; $i -lt $heads.Count; $i++) {
            $inner = (ConvertFrom-HtmlText $heads[$i].Groups[1].Value).Trim()
            if ($inner -match ('^' + [regex]::Escape($number) + '(?![0-9.])')) {
                $start = $heads[$i].Index + $heads[$i].Length
                $end = $(if ($i + 1 -lt $heads.Count) { $heads[$i + 1].Index } else { $text.Length })
                return $text.Substring($start, $end - $start)
            }
        }
        return ''
    }
    $heads = @([regex]::Matches($text, '(?m)^##[^#].*$'))
    for ($i = 0; $i -lt $heads.Count; $i++) {
        if ($heads[$i].Value -match ('^##\s+' + [regex]::Escape($number) + '(?![0-9.])')) {
            $start = $heads[$i].Index + $heads[$i].Length
            $end = $(if ($i + 1 -lt $heads.Count) { $heads[$i + 1].Index } else { $text.Length })
            return $text.Substring($start, $end - $start)
        }
    }
    return ''
}

function Get-SpansIn([string]$path, [string]$region) {
    # Get-CodeSpans reads a file; a section is a fragment of one, so the same two shapes are read from the text.
    $out = New-Object System.Collections.Generic.List[string]
    if ($path -like '*.html') {
        foreach ($m in [regex]::Matches($region, '(?s)<code[^>]*>(.*?)</code>')) { $out.Add((ConvertFrom-HtmlText $m.Groups[1].Value).Trim()) }
    } else {
        $stripped = [regex]::Replace($region, '(?s)```.*?```', ' ')
        foreach ($m in [regex]::Matches($stripped, '`([^`\r\n]+)`')) { $out.Add($m.Groups[1].Value.Trim()) }
    }
    return @($out)
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

function Get-SectionHeadings([string]$path) {
    $text = Read-Text $path
    if ($path -like '*.html') {
        $out = New-Object System.Collections.Generic.List[string]
        foreach ($m in [regex]::Matches($text, '(?s)<h[1-4][^>]*>(.*?)</h[1-4]>')) {
            $inner = (ConvertFrom-HtmlText $m.Groups[1].Value).Trim()
            if ($inner -match '^([0-9]+(?:\.[0-9]+)?)') { $out.Add($Matches[1]) }
        }
        return @($out | Sort-Object -Unique)
    }
    return @([regex]::Matches($text, '(?m)^#{2,4}\s+([0-9]+(?:\.[0-9]+)?)\s*') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
}
function Get-ProseText([string]$path) {
    # The HTML pages carry their own references, and they are maintained by hand beside the markdown, so they are read
    # the same way - with the stylesheet and any script removed first, since neither is prose.
    $text = Read-Text $path
    if ($path -like '*.html') {
        $text = [regex]::Replace($text, '(?s)<style[^>]*>.*?</style>', ' ')
        $text = [regex]::Replace($text, '(?s)<script[^>]*>.*?</script>', ' ')
        return (ConvertFrom-HtmlText $text)
    }
    return $text
}
# ----------------------------------------------------------------- ground truth
$Languages = @('en-US', 'zh-TW')
$tags = @{}; $unresolvedTags = @{}; $fingerprints = @{}; $fingerprintTitles = @{}; $exitCodes = @{}; $exitShapes = @{}; $configKeys = @{}
$fingerprintOrder = @{}; $fingerprintTitleOf = @{}; $verdicts = @{}; $badges = @{}
$verdictBranchCount = @{}; $badgeBranchCount = @{}; $prefixText = @{}
foreach ($lang in $Languages) {
    $scriptPath = Join-Path $PackageDir ($lang + '\NetworkHealthCheck.ps1')
    $text = Read-Text $scriptPath
    $facts = Get-ScriptFacts $scriptPath
    $tags[$lang] = $facts.Tags
    $unresolvedTags[$lang] = $facts.Unresolved
    $exitCodes[$lang] = $facts.ExitCodes
    $exitShapes[$lang] = $facts.ExitShapes

    # The fingerprint chain, read from the function itself rather than from the whole file: $key is assigned nowhere
    # else in it, but a regex over the file would not know that.
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
    $fn = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-FingerprintSummary' }, $true))
    if ($fn.Count -ne 1) { throw ('Get-FingerprintSummary not found once in ' + $scriptPath) }
    $body = $fn[0].Extent.Text
    $fingerprints[$lang] = @([regex]::Matches($body, '\$key\s*=\s*"([a-z-]+)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    $fingerprintTitles[$lang] = @([regex]::Matches($body, '(?m)^\s*"([a-z-]+)"\s*\{\s*\$title') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    # The order the rules are evaluated in, which is what the field manual's table claims to reproduce (backlog #33,
    # tier 3): the assignments as they stand in the function, the first of them being the default the chain falls
    # back to. Sorting here would throw away the only thing this reads the function for.
    $fingerprintOrder[$lang] = @([regex]::Matches($body, '\$key\s*=\s*"([a-z-]+)"') | ForEach-Object { $_.Groups[1].Value })
    $titleOf = @{}
    foreach ($m in [regex]::Matches($body, '(?s)"([a-z-]+)"\s*\{\s*\$title\s*=\s*"([^"]*)"')) { $titleOf[$m.Groups[1].Value] = $m.Groups[2].Value }
    # The default fingerprint has no case of its own - A5 says so - so its title is the one the default branch sets,
    # and a table row for it is a row about that branch.
    $defaultBranch = [regex]::Match($body, '(?s)\n\s*default\s*\{(.*)$')
    if ($defaultBranch.Success) {
        $defaultTitle = [regex]::Match($defaultBranch.Groups[1].Value, '\$title\s*=\s*"([^"]*)"')
        if ($defaultTitle.Success) { $titleOf[$fingerprintOrder[$lang][0]] = $defaultTitle.Groups[1].Value }
    }
    $fingerprintTitleOf[$lang] = $titleOf

    # The strings the report puts on the screen (backlog #33, tier 2), read from the two functions that produce them:
    # the verdict of a run, and the badge of a row. A document quotes these as text, so the ground truth has to be the
    # text and not the code behind it.
    $verdictOf = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
    $verdictBranches = 0; $badgeBranches = 0
    $fnOverall = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-OverallStatus' }, $true))
    if ($fnOverall.Count -ne 1) { throw ('Get-OverallStatus not found once in ' + $scriptPath) }
    # Every branch that names a code, counted: the pair below is read in the shape the function is written in
    # today, and a refactor this reader cannot follow would drop a verdict from the ground truth of both scripts at
    # once, where A8 compares two equally reduced maps and says nothing (PR #64, round 6).
    $verdictBranches = @([regex]::Matches($fnOverall[0].Extent.Text, 'Code\s*=\s*[''"][A-Za-z]+[''"]')).Count
    foreach ($m in [regex]::Matches($fnOverall[0].Extent.Text, '(?s)Code\s*=\s*"([A-Z]+)"\s*[\r\n]+\s*Text\s*=\s*"([^"]*)"')) { $verdictOf[$m.Groups[1].Value] = $m.Groups[2].Value }
    $verdicts[$lang] = $verdictOf
    $badgeOf = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
    $fnBadge = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-StatusText' }, $true))
    if ($fnBadge.Count -ne 1) { throw ('Get-StatusText not found once in ' + $scriptPath) }
    $badgeBranches = @([regex]::Matches($fnBadge[0].Extent.Text, '(?m)^\s*[''"][A-Za-z]+[''"]\s*\{')).Count
    foreach ($m in [regex]::Matches($fnBadge[0].Extent.Text, '"([A-Z]+)"\s*\{\s*return\s*"([^"]*)"')) { $badgeOf[$m.Groups[1].Value] = $m.Groups[2].Value }
    $badges[$lang] = $badgeOf
    # And what the live log prints, which is the same status seen earlier: the console lines while the run
    # happens and the log pane of the graphical window. These were two lists of words and the lists drifted -
    # ERROR read 'Unable to Check' in the report and '[Error]' on the screen, which are two different claims
    # about one reading, and zh-TW's WARN differed as well (backlog #70, found on the en-US walk of
    # 2026-09-15). G1 below checks the report's words against the manual that defines them; what is kept here
    # is the text of Get-StatusPrefix, so that A12 can check the log has no words of its own to drift with.
    $fnPrefix = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-StatusPrefix' }, $true))
    if ($fnPrefix.Count -ne 1) { throw ('Get-StatusPrefix not found once in ' + $scriptPath) }
    $prefixText[$lang] = [string]$fnPrefix[0].Extent.Text
    $verdictBranchCount[$lang] = $verdictBranches
    $badgeBranchCount[$lang] = $badgeBranches

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
Write-Output ("Identifiers: {0} tags, {1} fingerprints, {2} configuration keys, exit code(s) {3}{4}" -f $tags['en-US'].Count, $fingerprints['en-US'].Count, $configKeys['en-US'].Count, ($exitCodes['en-US'] -join '/'), $(if ($exitShapes['en-US'].Count) { ' plus ' + ($exitShapes['en-US'] -join ', ') } else { '' }))

# ------------------- G. the strings a report puts on the screen (backlog #33, tier 2)
# The user manual of a language explains what the reader sees: the verdict of the run and the badge on a row. The
# strings come from the two functions that produce them, so the manual is checked against the program rather than
# against another document; where a real report is given, the run's own verdict and badges are checked too, which is
# the half that can only be measured after a run and so lives in the chain's resultset step.
$UserManualOf = @{}
foreach ($lang in $Languages) { $UserManualOf[$lang] = @($UserManuals | Where-Object { $_ -like ('*\' + $lang + '\*') }) }
# Emphasis alone, which is what the rule above says: a code span would let a manual present a verdict as an
# identifier and still pass. Measured before the rule was narrowed - no user manual codes one of these strings today,
# in either language or either format - so this refuses a change of style rather than the style there is
# (PR #64, round 5).
function Get-QuotedStrings([string]$doc) { return @(Get-EmphasisSpans $doc) }

if ($ReportPath) {
    $reportFile = (Resolve-Path -LiteralPath $ReportPath).Path
    $report = Get-Content -LiteralPath $reportFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $lang = $ReportLanguage
    $quoted = @(); foreach ($doc in $UserManualOf[$lang]) { $quoted += @(Get-QuotedStrings $doc) }
    $quoted = @($quoted | Sort-Object -CaseSensitive -Unique)
    $name = Split-Path -Leaf $reportFile

    # The report carries the code and the text together, and the script is what pairs them: a text that is merely
    # one of the four would pass while the report showed the wrong one of them (PR #64, round 1).
    $verdictText = [string]$report.Overall.Text
    $verdictCode = [string]$report.Overall.Code
    $expectedText = $(if ($verdicts[$lang].ContainsKey($verdictCode)) { [string]$verdicts[$lang][$verdictCode] } else { '' })
    $verdictDetail = $(if (-not $expectedText) { "the report's code " + $verdictCode + " is not one the script produces: " + (@($verdicts[$lang].Keys | Sort-Object) -join ', ') } else { "the report pairs " + $verdictCode + " with '" + $verdictText + "'; the script pairs it with '" + $expectedText + "'" })
    Assert-True ("G2 [{0}] the verdict it shows is the one the {1} script pairs with its code" -f $name, $lang) ($expectedText -and ($expectedText -ceq $verdictText)) $verdictDetail
    Assert-True ("G3 [{0}] the user manual quotes the verdict it shows" -f $name) ($quoted -ccontains $verdictText) ("not quoted in the {0} user manual: '{1}'" -f $lang, $verdictText)

    $rows = @($report.Results)
    $codes = @($rows | ForEach-Object { [string]$_.Status } | Where-Object { $_ } | Sort-Object -CaseSensitive -Unique)
    $badgeProblems = @()
    # A row whose status is missing or empty renders a badge of nothing, and dropping it here would have let the
    # report say so in silence (PR #64, round 7).
    $statusless = @($rows | Where-Object { -not [string]$_.Status }).Count
    if ($statusless) { $badgeProblems += ('{0} row(s) carry no status at all, so they can render no defined badge' -f $statusless) }
    foreach ($code in $codes) {
        $badge = $(if ($badges[$lang].ContainsKey($code)) { [string]$badges[$lang][$code] } else { '' })
        if (-not $badge) { $badgeProblems += ("status " + $code + " has no badge in the script"); continue }
        if (-not ($quoted -ccontains $badge)) { $badgeProblems += ("status " + $code + " shows as '" + $badge + "', which the manual does not quote") }
    }
    Assert-True ("G4 [{0}] every badge its {1} row(s) carry is defined and quoted ({2})" -f $name, @($report.Results).Count, ($codes -join ', ')) ($badgeProblems.Count -eq 0) ($badgeProblems -join '; ')
}
if ($ReportOnly) {
    Write-Output ("Summary: {0} passed, {1} failed" -f $passes, $fails)
    exit $fails
}

foreach ($lang in $Languages) {
    $expected = @(@($verdicts[$lang].Values) + @($badges[$lang].Values) | Sort-Object -CaseSensitive -Unique)
    foreach ($doc in $UserManualOf[$lang]) {
        $quoted = Get-QuotedStrings $doc
        $missing = @($expected | Where-Object { -not ($quoted -ccontains $_) })
        Assert-True ("G1 [{0}] every verdict and badge the report can show is quoted ({1})" -f (Split-Path -Leaf $doc), $expected.Count) ($missing.Count -eq 0) ('not documented: ' + ($missing -join ', '))
    }
}

# --------------------------------------------------- A. the two languages agree
Assert-SetEqual 'A1 result tags are the same in both scripts' $tags['zh-TW'] $tags['en-US']
Assert-SetEqual 'A2 fingerprint keys are the same in both scripts' $fingerprints['zh-TW'] $fingerprints['en-US']
Assert-SetEqual 'A3 exit codes are the same in both scripts' $exitCodes['zh-TW'] $exitCodes['en-US']
Assert-SetEqual 'A3b what the scripts exit with, where it is not a literal, is the same' $exitShapes['zh-TW'] $exitShapes['en-US']
Assert-SetEqual 'A4 configuration keys are the same in both files' $configKeys['zh-TW'] $configKeys['en-US']
# The screen strings differ by language; which statuses have one does not, and a code with a verdict in one script
# and none in the other would leave a row of the other language's report unexplained.
Assert-SetEqual 'A8 the verdict codes are the same in both scripts' @($verdicts['zh-TW'].Keys) @($verdicts['en-US'].Keys)
Assert-SetEqual 'A9 the badge codes are the same in both scripts' @($badges['zh-TW'].Keys) @($badges['en-US'].Keys)
# A2 compares the keys as sets, so two scripts could try the same rules in a different order and agree on nothing
# that matters (PR #64, round 1). The order is what C2 then holds one table to, and it must be one order.
Assert-True 'A10 the fingerprint chain is tried in the same order in both scripts' ((@($fingerprintOrder['zh-TW']) -join ',') -eq (@($fingerprintOrder['en-US']) -join ',')) ('zh-TW tries ' + (@($fingerprintOrder['zh-TW']) -join ', ') + '; en-US tries ' + (@($fingerprintOrder['en-US']) -join ', '))
foreach ($lang in $Languages) {
    # Every fingerprint the chain can select has a title and its advice lines; "healthy" is the switch's default.
    Assert-SetEqual ("A5 [{0}] every fingerprint key has a case in the switch" -f $lang) $fingerprintTitles[$lang] @($fingerprints[$lang] | Where-Object { $_ -ne 'healthy' })
    # A tag this step cannot resolve to a literal is a tag it is not checking, so it says so instead of passing.
    Assert-True ("A6 [{0}] every -Tag argument resolves to a literal" -f $lang) ($unresolvedTags[$lang].Count -eq 0) ('unresolved: ' + ($unresolvedTags[$lang] -join '; '))
    # And the same rule for the strings on the screen: as many verdicts and badges as there are branches naming one.
    $readCounts = ('{0} of {1} verdict(s), {2} of {3} badge(s)' -f $verdicts[$lang].Count, $verdictBranchCount[$lang], $badges[$lang].Count, $badgeBranchCount[$lang])
    Assert-True ("A11 [{0}] every verdict and badge branch was read ({1})" -f $lang, $readCounts) (($verdicts[$lang].Count -eq $verdictBranchCount[$lang]) -and ($badges[$lang].Count -eq $badgeBranchCount[$lang])) ('a branch the reader could not follow would be missing from the ground truth: ' + $readCounts)
    # A12: the log's word for a status is the report's word, and the only way to promise that without a second list
    # to keep in step is for the log to have no list. Get-StatusPrefix returns the badge in brackets, so a word
    # added to or changed in Get-StatusText reaches the screen with no edit here and no edit there (backlog #70).
    $ownWords = @([regex]::Matches($prefixText[$lang], 'return\s+"\[[^"]+\]"')).Count
    $fromBadge = ($prefixText[$lang] -match 'Get-StatusText')
    Assert-True ("A12 [{0}] the live log's word for a status is the report's word, taken from it rather than listed again" -f $lang) ($fromBadge -and ($ownWords -eq 0)) ('Get-StatusPrefix ' + $(if ($fromBadge) { 'reads Get-StatusText' } else { 'does not read Get-StatusText' }) + ' and returns ' + $ownWords + ' word(s) of its own')
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

# The order the rules are tried in is a claim the field manual's table makes by the order of its rows, and nothing
# read one against the other (backlog #33, tier 3). The chain's own order is the order of the assignments, whose
# first is the default - the value a run keeps when no rule matches - so the table ends with it rather than opening
# with it. Everything else is in evaluation order, first rule first.
if (-not $PackageOnly) {
    $chain = @($fingerprintOrder['en-US'])
    $default = $chain[0]
    $expectedRows = @(@($chain | Select-Object -Skip 1) + @($default))
    $middot = [string][char]0x00B7
    foreach ($doc in $FieldManual) {
        $name = Split-Path -Leaf $doc
        $region = Get-SectionRegion $doc '4'
        $rows = New-Object System.Collections.Generic.List[object]
        if ($doc -like '*.html') {
            foreach ($m in [regex]::Matches($region, '<span class="fp">([a-z-]+)</span>([^<]*)</td>')) { $rows.Add(@{ Key = $m.Groups[1].Value; Title = (ConvertFrom-HtmlText $m.Groups[2].Value).Trim() }) }
        } else {
            foreach ($m in [regex]::Matches($region, '(?m)^\|\s*`([a-z-]+)`\s*' + $middot + '\s*([^|]+)\|')) { $rows.Add(@{ Key = $m.Groups[1].Value; Title = $m.Groups[2].Value.Trim() }) }
        }
        $keys = @($rows | ForEach-Object { $_.Key })
        Assert-True ("C2 [{0}] its fingerprint table is the chain's own order, the default last ({1} rows)" -f $name, $keys.Count) (($keys -join ',') -ceq ($expectedRows -join ',')) ("the table reads " + ($keys -join ', ') + "; the chain tries " + (@($chain | Select-Object -Skip 1) -join ', ') + ", and falls back to " + $default)
        $wrongTitle = @($rows | Where-Object { [string]$fingerprintTitleOf['en-US'][$_.Key] -cne $_.Title } | ForEach-Object { "{0}: the table says '{1}', the script '{2}'" -f $_.Key, $_.Title, [string]$fingerprintTitleOf['en-US'][$_.Key] })
        Assert-True ("C3 [{0}] every row's title is the title the script gives that fingerprint" -f $name) ($wrongTitle.Count -eq 0) ($wrongTitle -join '; ')
    }
}

# ------------------------------------- D. the result tags and the field manual
if (-not $PackageOnly) {
    $stale = @($InternalTags | Where-Object { $tags['en-US'] -notcontains $_ })
    Assert-True 'D1 the internal-tag list has no stale entry' ($stale.Count -eq 0) ('no longer in the script: ' + ($stale -join ', '))
    $documentedTags = @($tags['en-US'] | Where-Object { $InternalTags -notcontains $_ })
    # Both formats: a tag dropped from the page and not from the markdown is exactly the drift this step exists for.
    foreach ($doc in $FieldManual) {
        $spans = Get-CodeSpans $doc
        Assert-Covered ("D2 [{0}] every result tag is documented ({1} of {2}; the rest are internal)" -f (Split-Path -Leaf $doc), $documentedTags.Count, $tags['en-US'].Count) $documentedTags $spans
    }
}

# ------------------------------- A7. the exit codes the documents quote
# The codes anything in the package can produce: the two scripts, and the launchers that report them. The other
# direction is deliberately not asserted - 0 is not a fact a manual is expected to name.
$launcherExits = New-Object System.Collections.Generic.List[string]
foreach ($folder in @('', 'en-US', 'zh-TW')) {
    $path = $(if ($folder) { Join-Path $PackageDir $folder } else { $PackageDir })
    if (-not (Test-Path -LiteralPath $path)) { continue }
    foreach ($cmd in @(Get-ChildItem -LiteralPath $path -File -Filter '*.cmd')) {
        foreach ($m in [regex]::Matches((Read-Text $cmd.FullName), '(?i)exit\s*/b\s*(\d+)')) { $launcherExits.Add($m.Groups[1].Value) }
    }
}
$producibleExits = @($exitCodes['en-US'] + $exitCodes['zh-TW'] + $launcherExits | Sort-Object -Unique)
# The validator is a third producer with a set of its own, and the manuals document it in its own paragraph. Pooling
# every code the package can produce would let the validator's documented failure code be one only the PowerShell
# script has, so the paragraph a code sits in decides which set it is measured against.
$validatorExits = New-Object System.Collections.Generic.List[string]
$validatorPath = Join-Path $PackageDir 'tools\validate_release.py'
if (Test-Path -LiteralPath $validatorPath) {
    foreach ($m in [regex]::Matches((Read-Text $validatorPath), '(?s)sys\.exit\(([^)]*)\)')) {
        foreach ($n in [regex]::Matches($m.Groups[1].Value, '\b(\d+)\b')) { $validatorExits.Add($n.Groups[1].Value) }
    }
}
$validatorExits = @($validatorExits | Sort-Object -Unique)
# The forms the documents actually use, in both languages: "exit code 3", "exits 0", "exits with code 1", the zh-TW
# "<code> N" and "with N it ends", and the second outcome of a sentence that lists two ("exits 0 when ..., 1 when ...").
$ExitPatterns = @(
    '(?i)\bexit(?:s|ed)?\s+(?:with\s+)?(?:code\s+)?(\d+)',
    '\u7d50\u675f\u4ee3\u78bc(?:\u70ba|\u662f)?\s*(\d+)',
    '\u4ee5\s*(\d+)\s*\u7d50\u675f')
$ExitContinuation = '(?i)(?:,|;|\uff0c|\u3001)\s*(?:or\s+)?(\d+)\s+(?:when|if)\b'
# A code a sentence attributes to the launcher is measured against the launcher's own set, the way a code in the
# validator's paragraph is. The verb is what decides: "the launcher exits 1" is its own code, while "the launcher
# explains exit code 3" and "'exit code 1' in the launcher and 'exit code 3' in the message" are the program's, which
# the launcher only reports - so the pattern binds the number to the verb and not merely to the word.
$LauncherAttributed = '(?i)\blauncher\s+(?:always\s+|only\s+)?exit(?:s|ed)?\s+(?:with\s+)?(?:code\s+)?(\d+)'
foreach ($doc in $AllDocs) {
    $name = Split-Path -Leaf $doc
    $text = (Get-ProseText $doc) -replace "`r`n", "`n"
    $unknown = New-Object System.Collections.Generic.List[string]
    $count = 0
    $offset = 0
    foreach ($rawLine in ($text -split "`n")) {
        # The markup around a number is not part of it: the field manual writes the launcher's code as `1`, and a
        # pattern that wants a digit after the space would read the markdown and the page differently.
        $line = $rawLine -replace '[`*_]', ''
        $codes = New-Object System.Collections.Generic.List[string]
        foreach ($pattern in $ExitPatterns) {
            foreach ($m in [regex]::Matches($line, $pattern)) { $codes.Add($m.Groups[1].Value) }
        }
        $launcherCodes = @([regex]::Matches($line, $LauncherAttributed) | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        foreach ($code in $launcherCodes) {
            $count++
            if ($launcherExits -notcontains $code) { $unknown.Add(($code + ' (the launcher produces ' + (@($launcherExits | Sort-Object -Unique) -join '/') + ')')) }
        }
        if ($codes.Count) {
            foreach ($m in [regex]::Matches($line, $ExitContinuation)) { $codes.Add($m.Groups[1].Value) }
            $back = $text.Substring([Math]::Max(0, $offset - 600), [Math]::Min(600, $offset))
            $allowed = $producibleExits
            $producer = 'the package'
            if (($validatorExits.Count -gt 0) -and ($back -match 'validate_release\.py')) { $allowed = $validatorExits; $producer = 'the validator' }
            foreach ($code in @($codes | Sort-Object -Unique)) {
                $count++
                if ($allowed -notcontains $code) { $unknown.Add(($code + ' (' + $producer + ' produces ' + ($allowed -join '/') + ')')) }
            }
        }
        $offset += $rawLine.Length + 1
    }
    Assert-True ("A7 [{0}] the {1} exit code(s) it quotes are codes their producer has" -f $name, $count) ($unknown.Count -eq 0) ('not produced: ' + (@($unknown | Sort-Object -Unique) -join ', '))
}

# --------------------------------- E. the file names the documents send people to
$packageFiles = New-Object System.Collections.Generic.List[string]
foreach ($folder in @('', 'en-US', 'zh-TW', 'docs', 'tools')) {
    $path = $(if ($folder) { Join-Path $PackageDir $folder } else { $PackageDir })
    if (Test-Path -LiteralPath $path) { Get-ChildItem -LiteralPath $path -File | ForEach-Object { $packageFiles.Add($_.Name) } }
}
# A quoted name is checked whether it is bare or carries its folder - "tools\validate_release.py" and
# "en-US\Start-NetworkCheck-IT.cmd" are references a reader follows, and a misspelling in either form used to pass.
# Runtime artefacts are outside the shape on purpose: they are .txt and nobody ships them.
$fileSpanPattern = '^(?:\.\.[\\/])*(?:(en-US|zh-TW|docs|tools)[\\/])?([A-Za-z0-9][A-Za-z0-9_.\-]*\.(?:ps1|cmd|py|json|md|html))$|^SHA256SUMS\.txt$'
$packagePaths = New-Object System.Collections.Generic.List[string]
foreach ($folder in @('en-US', 'zh-TW', 'docs', 'tools')) {
    $path = Join-Path $PackageDir $folder
    if (Test-Path -LiteralPath $path) { Get-ChildItem -LiteralPath $path -File | ForEach-Object { $packagePaths.Add(($folder + '/' + $_.Name)) } }
}
# A span can be a whole command line - the field manual quotes `powershell ... -File NetworkHealthCheck.ps1 ...` -
# and the reader runs what it says, so the executables inside one are read as well. Only .ps1, .cmd and .py: a report
# file name in an example is not a package file, and .txt artefacts are written at run time.
$executableTokenPattern = '^(?:(en-US|zh-TW|docs|tools)[\\/])?([A-Za-z0-9][A-Za-z0-9_.\-]*\.(?:ps1|cmd|py))$'
function ConvertTo-BareToken([string]$token) {
    # ".\NetworkHealthCheck.ps1" and "'tools/validate_release.py'" name the same files as the bare forms; a command
    # line is quoted and dot-relative often enough that dropping those would leave the copied command unchecked.
    $t = $token.Trim().Trim('"').Trim("'")
    return ($t -replace '^\.[\\/]', '')
}
foreach ($doc in $AllDocs) {
    $name = Split-Path -Leaf $doc
    $spans = @(Get-CodeSpans $doc)
    $quoted = @($spans | Where-Object { $_ -match $fileSpanPattern })
    $quoted += @($spans | Where-Object { $_ -notmatch $fileSpanPattern -and $_ -match '\s' } |
        ForEach-Object { $_ -split '\s+' } | ForEach-Object { ConvertTo-BareToken $_ } | Where-Object { $_ -match $executableTokenPattern })
    # A fenced block is a command the reader copies whole, so the executables in it are read like any other name; the
    # config-key check already reads these blocks, and E1 was the one place they were dropped.
    $quoted += @(Get-CodeBlocks $doc | ForEach-Object { $_ -split '[\s;|]+' } | ForEach-Object { ConvertTo-BareToken $_ } | Where-Object { $_ -match $executableTokenPattern })
    $quoted = @($quoted | Sort-Object -Unique)
    $absent = @($quoted | Where-Object {
        $normal = $_ -replace '\\', '/'
        $inPackage = $(if ($normal -like '*/*') { $packagePaths -contains $normal } else { $packageFiles -contains $normal })
        # A path is read from where the document sits, which is what "../VALIDATION.md" in every technical-guide copy
        # means; the package-relative and the checkout-relative readings follow, because the guide also points at
        # "docs/design-v1.2-triage-wizard.md in the repository", a real file the package does not carry.
        $fromDocument = $false
        try { $fromDocument = Test-Path -LiteralPath (Join-Path (Split-Path -Parent $doc) $normal) } catch { $fromDocument = $false }
        -not ($inPackage -or $fromDocument -or (Test-Path -LiteralPath (Join-Path $RepoRoot $normal)))
    })
    Assert-True ("E1 [{0}] the {1} file name(s) it quotes are in the package" -f $name, $quoted.Count) ($absent.Count -eq 0) ('not in the package: ' + ($absent -join ', '))

    # And the links a reader clicks: a Markdown target or an href that names a local file has to resolve, from the
    # folder the document sits in. An absolute URL, a mail address and a bare anchor are somebody else's business.
    $text = Read-Text $doc
    $links = New-Object System.Collections.Generic.List[string]
    foreach ($m in [regex]::Matches($text, '\]\(([^)\s]+)\)')) { $links.Add($m.Groups[1].Value) }
    foreach ($m in [regex]::Matches($text, 'href\s*=\s*"([^"]+)"')) { $links.Add($m.Groups[1].Value) }
    foreach ($m in [regex]::Matches($text, "href\s*=\s*'([^']+)'")) { $links.Add($m.Groups[1].Value) }
    $local = @($links | Where-Object { $_ -notmatch '^[a-z][a-z0-9+.-]*:' -and $_ -notmatch '^#' } |
        ForEach-Object { ($_ -split '#')[0] } | Where-Object { $_ } | Sort-Object -Unique)
    # Only from the document's own folder, which is where the browser looks: a leaf name that exists somewhere else in
    # the package is not the file the reader would get, and accepting it was the check agreeing with itself.
    $broken = @($local | Where-Object {
        $normal = $_ -replace '\\', '/'
        $resolved = $false
        try { $resolved = Test-Path -LiteralPath (Join-Path (Split-Path -Parent $doc) $normal) } catch { $resolved = $false }
        -not $resolved
    })
    Assert-True ("E2 [{0}] the {1} local link(s) it carries resolve" -f $name, $local.Count) ($broken.Count -eq 0) ('broken: ' + ($broken -join ', '))
}

# --------------------------- E3. the package's file table, the other way round (backlog #41)
# E1 asks whether a name a document quotes is in the package. This asks the reverse: a file that ships and that the
# user manual's file table never names is a file the reader walking that table will not recognise, and 1.2.4 showed
# the risk is not hypothetical - two manuals joined the package and two README files left it, and what kept the
# table right was a person editing four files by hand.
#
# The table is read as the section's own code spans, in order, with two conventions of its own:
#   - a span that is only an extension continues the name before it, because a row reads `...User_Manual_en-US.md`, `.html`;
#   - a span with a wildcard covers what it matches, because the two technical guides share one row.
# A span naming a folder covers the folder and not its contents: the row for `en-US\` is the entry for the folder
# itself, and reading it as coverage would excuse every file inside and leave this check asserting nothing. What a
# table may leave unenumerated is the waiver list below instead, with the reason recorded beside each. Reports\ needs
# no waiver: the tool creates it on first run and it is not a shipped file, so it is not in the set at all.
$TableWaivers = @(
    @{ Prefix = 'docs/'; Reason = 'the table names the folder beside the wildcard for the guides, which ship in each language folder as well, where they are named' },
    @{ Prefix = 'tools/'; Reason = 'the table names the folder beside SHA256SUMS.txt; what is in it is the validator, and section 8 is written for the person running the tool' })
# The extensions the package ships, which is the shape E1 already states for the names a document may quote:
# runtime artefacts are .txt and nobody ships them, SHA256SUMS.txt apart. The fallback below reads a folder, so it
# needs the shape; the git path checks that the shape is still the truth, which is what keeps the two paths one rule.
$ShippedExtensions = @('.ps1', '.cmd', '.json', '.md', '.html', '.py')
function Test-LooksShipped([string]$rel) {
    $leaf = Split-Path -Leaf $rel
    if ($leaf -ceq 'SHA256SUMS.txt') { return $true }
    return ($ShippedExtensions -ccontains ([IO.Path]::GetExtension($leaf)).ToLowerInvariant())
}
# What ships is what the asset carries, and build_asset.py packages the tracked files: a run from the checkout
# leaves LauncherError_<stamp>.txt or PowerShellMessages_<stamp>.txt in a language folder, and reading the folder
# would make E3 demand a table row for a file no release has ever contained (PR #64, round 1). An extracted release
# has no git to ask, so the folder is the fallback there, and the source is named in the assertion either way.
$shippedRel = New-Object System.Collections.Generic.List[string]
$inventory = 'the folder'
$tracked = @()
if ($PackageDir -eq (Join-Path $RepoRoot 'healthcheck')) {
    try {
        $ErrorActionPreference = 'Continue'
        $lines = @(& git -C $RepoRoot ls-files healthcheck 2>$null)
        if ($LASTEXITCODE -eq 0) { $tracked = @($lines | ForEach-Object { [string]$_ } | Where-Object { $_ -like 'healthcheck/*' } | ForEach-Object { $_.Substring('healthcheck/'.Length) }) }
    } catch { $tracked = @() }
    finally { $ErrorActionPreference = 'Stop' }
}
if ($tracked.Count) {
    $inventory = 'git'
    foreach ($rel in $tracked) { if (($rel -notlike '*/Reports/*') -and ($rel -notlike 'Reports/*')) { $shippedRel.Add($rel) } }
} else {
    # An extracted release, where there is no git to ask: a launcher that has run there leaves LauncherError_<stamp>.txt
    # or PowerShellMessages_<stamp>.txt beside the script, and neither is a file any release carries (PR #64, round 5).
    Get-ChildItem -LiteralPath $PackageDir -File | Where-Object { Test-LooksShipped $_.Name } | ForEach-Object { $shippedRel.Add($_.Name) }
    foreach ($folder in @('en-US', 'zh-TW', 'docs', 'tools')) {
        $path = Join-Path $PackageDir $folder
        if (Test-Path -LiteralPath $path) { Get-ChildItem -LiteralPath $path -File | Where-Object { Test-LooksShipped $_.Name } | ForEach-Object { $shippedRel.Add($folder + '/' + $_.Name) } }
    }
}
# The shape is a claim about the package, so it is checked where the package can be read in full: a release that
# shipped a file of another kind would leave the fallback blind to it, and this is what would say so.
if ($inventory -eq 'git') {
    $offShape = @($shippedRel | Where-Object { -not (Test-LooksShipped $_) })
    Assert-True ('E3 every file the package ships has an extension the fallback inventory knows' ) ($offShape.Count -eq 0) ('outside the shape ' + ($ShippedExtensions -join ', ') + ' and not SHA256SUMS.txt: ' + ($offShape -join ', '))
}
$staleWaiver = @($TableWaivers | Where-Object { $prefix = $_.Prefix; -not @($shippedRel | Where-Object { $_ -like ($prefix + '*') }).Count } | ForEach-Object { $_.Prefix })
Assert-True ('E3 the file-table waiver list has no stale entry' ) ($staleWaiver.Count -eq 0) ('nothing ships under: ' + ($staleWaiver -join ', '))
foreach ($lang in $Languages) {
    # Each language's manual enumerates the package root and its own folder; the other language's folder is the
    # third waiver, and its own manual is what enumerates it.
    $other = @($Languages | Where-Object { $_ -ne $lang })[0]
    $waived = @($TableWaivers | ForEach-Object { $_.Prefix }) + @($other + '/')
    $required = @($shippedRel | Where-Object { $file = $_; -not @($waived | Where-Object { $file -like ($_ + '*') }).Count })
    foreach ($doc in $UserManualOf[$lang]) {
        $name = Split-Path -Leaf $doc
        $region = Get-SectionRegion $doc '8'
        $spans = @(Get-SpansIn $doc $region | ForEach-Object { ($_ -replace '\\', '/').Trim() } | Where-Object { $_ })
        $matchers = New-Object System.Collections.Generic.List[string]
        $tooBroad = New-Object System.Collections.Generic.List[string]
        $previous = ''
        foreach ($span in $spans) {
            if ($span -match '/$') { continue }                                  # a folder: an entry for itself
            if ($span -match '^\.[A-Za-z0-9]+$') {                                # ".html" continues the name before it
                if ($previous) { $matchers.Add(([IO.Path]::ChangeExtension($previous, $span.TrimStart('.')))) }
                continue
            }
            if ($span -notmatch '^[A-Za-z0-9*][A-Za-z0-9_.\-]*(/[A-Za-z0-9*][A-Za-z0-9_.*\-]*)?$') { continue }
            $matchers.Add($span)
            $previous = $span
            # A wildcard stands for a family that shares one row - the two technical guides - and not for a folder.
            # `*` or `en-US/*` would have made every required file documented and left this check asserting nothing,
            # which is the hazard the folder rule above exists for, arriving through the other door (PR #64, round 10).
            if ($span -match '\*') {
                $leaf = @($span -split '/')[-1]
                $stem = @($leaf -split '\*')[0]
                if (($stem.Length -lt 3) -or ($leaf -notmatch '\.[A-Za-z0-9]+$')) { $tooBroad.Add(('{0}: a wildcard names a family, so it needs at least three characters before the * and a file extension after it' -f $span)) }
            }
        }
        # How much each wildcard covers is part of the shape: a row groups a pair, and one that answered for half the
        # folder would hide whatever the package gained next.
        foreach ($matcher in @($matchers | Where-Object { $_ -match '\*' } | Sort-Object -CaseSensitive -Unique)) {
            $covered = @($required | Where-Object { $_ -like $matcher })
            if ($covered.Count -gt 2) { $tooBroad.Add(('{0}: one row may group a pair, and this covers {1} files ({2})' -f $matcher, $covered.Count, ($covered -join ', '))) }
        }
        $unnamed = @($required | Where-Object { $file = $_; -not @($matchers | Where-Object { $file -like $_ }).Count })
        if ($tooBroad.Count) { $unnamed = @($unnamed) + @($tooBroad) }
        Assert-True ("E3 [{0}] every file the package ships in the root and in {1}\ is named by the file table ({2} files by {3}, {4} names)" -f $name, $lang, $required.Count, $inventory, $matchers.Count) ($unnamed.Count -eq 0) ('not in the table: ' + ($unnamed -join ', '))
    }
}

# ------------------------------------------ F. the section numbers a document cites
$MarkdownDocs = @($AllDocs)
# A reference into another document names it just before the number - "the user manual, section 5", "field manual, §7",
# and the zh-TW documents' own forms. The window is short and has to end at the number, because a whole sentence of
# prose will contain the word "manual" often enough to swallow a real mistake: the first version of this rule did, and
# the self-test caught it.
$OtherDocumentReference = '(?i)(manual|guide|sop|template|readme|page|\u624b\u518a|\u6307\u5357|\u7bc4\u672c|\u9801\u9762|\u6587\u4ef6)[^.\u3002]{0,20}$'
# Both spellings, and a reference that carries more than one number: "sections 3.6 and 8" cites two sections, and the
# zh-TW documents bracket the number between the two characters \u7b2c and \u7bc0 instead. Only the first number used to be
# read, and the Chinese form not at all - so a mistyped number in a zh-TW manual met no check whatsoever.
$SectionNumber = '[0-9]+(?:\.[0-9]+)?'
$SectionPatterns = @(
    ('(?i)\bsections?\s+(' + $SectionNumber + '(?:\s*(?:,|and|&)\s*' + $SectionNumber + ')*)'),
    ('\u00a7\s*(' + $SectionNumber + '(?:\s*(?:,|and|&|\u3001)\s*\u00a7?\s*' + $SectionNumber + ')*)'),
    ('\u7b2c\s*(' + $SectionNumber + '(?:\s*(?:\u3001|,|\u8207|\u548c|\u53ca)\s*(?:\u7b2c\s*)?' + $SectionNumber + ')*)\s*\u7bc0'))
foreach ($doc in $MarkdownDocs) {
    $name = Split-Path -Leaf $doc
    $text = Get-ProseText $doc
    $headings = Get-SectionHeadings $doc
    if (-not $headings.Count) { continue }
    $bad = New-Object System.Collections.Generic.List[string]
    $cited = 0
    foreach ($pattern in $SectionPatterns) {
        foreach ($m in [regex]::Matches($text, $pattern)) {
            $before = $text.Substring([Math]::Max(0, $m.Index - 40), [Math]::Min(40, $m.Index))
            if ($before -match $OtherDocumentReference) { continue }   # a reference into another document
            foreach ($number in @([regex]::Matches($m.Groups[1].Value, $SectionNumber) | ForEach-Object { $_.Value })) {
                $cited++
                if ($headings -notcontains $number) { $bad.Add($m.Value.Trim()) }
            }
        }
    }
    Assert-True ("F1 [{0}] every section it cites exists ({1} headings, {2} references)" -f $name, $headings.Count, $cited) ($bad.Count -eq 0) ('no such section: ' + (@($bad | Sort-Object -Unique) -join ', '))
}

Write-Output ("Summary: {0} passed, {1} failed" -f $passes, $fails)
exit $fails
