<#
.SYNOPSIS
    Checks the backlog page against itself, and the repository README's Backlog row against the page (backlog #55).

.DESCRIPTION
    docs\backlog.md carries an index table of the open items, one body per open item, and a table of the closed
    items, and it states the rules the three have to satisfy: a number is permanent, never renumbered and never
    reused, and a closed item keeps its number. Nothing read one part against the other, which is how #54 reached
    main with a body and no row, and how the README's count of open items said twenty-two where the page itself said
    twenty-three. This step reads the page and asserts the four statements the page makes about itself - an open row
    has a body, a body has an open row, no number stands in both tables, no number between 1 and the highest used is
    in neither and none is below 1 - and then reads the README's Backlog row, which restates the page, against the page: its count of
    open items, every item it lists as open (in both directions), the anchor each listed item links to, the count
    each of its groups states, and its list of closed numbers.

    What it reads on the README's row is the enumeration, not the prose. An item the row lists is a link to the
    item's own heading, [#N](docs/backlog.md#anchor); a bare #N on the row is a mention - a cross-reference, the
    sentence about the item that stands in two groups - and is not read. A group is a parenthesis on the row that
    holds at least one such link, and its stated count is the last number standing alone before the parenthesis
    opens, written as a word from one to twenty or in digits - a date, a version or a mention like #25 is not a
    count. The closed numbers are one sentence, "Numbers ... are closed", a
    comma-separated list of numbers and "a to b" ranges, each number once. The sentence about the overlap, where
    the row has one, is read as "sum to N where the items are M", in words or digits; any other wording states no
    total to check. The arithmetic the item asked for - the stated counts sum to the open
    count plus one for each further group an item is listed in - is checked as three statements so that one mistake
    fails one check: every listed item is an open row (R2), every open row is listed (R3), and each group's stated
    count is the number of items it encloses - an item once in each group it stands in, and it may stand in more
    than one - with no link standing outside every group and, where the row has a sentence stating what the groups
    sum to and how many items there are, that sentence saying what they do (R5).

    What it does not check is the prose: the row restates each item in a clause of its own, and whether that clause
    is still what the item's body says is what a reader with both documents open is for. The page's own rule for it
    is under "Adding and closing an item".

.PARAMETER RepoRoot
    The checkout: docs\backlog.md and README.md are read under it. Default: the parent of tests\.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\backlog_index.ps1
#>
param([string]$RepoRoot)

$ErrorActionPreference = 'Stop'
if (-not $RepoRoot) { $RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$BacklogPath = Join-Path $RepoRoot 'docs\backlog.md'
$ReadmePath = Join-Path $RepoRoot 'README.md'

$fails = 0; $passes = 0
function Assert-True([string]$name, [bool]$ok, [string]$detail) {
    if ($ok) { $script:passes++; Write-Output "[PASS] $name" }
    else { $script:fails++; Write-Output ("[FAIL] $name -> $detail") }
}
function Write-Summary { Write-Output ("Summary: {0} passed, {1} failed" -f $script:passes, $script:fails) }

function Read-Lines([string]$path) {
    # Both files carry a byte-order mark, which ReadAllText with UTF8 drops. Lines are split on either line ending:
    # the checkout has CRLF, a runner's may have LF, and a regular expression anchored on $ would otherwise keep the
    # carriage return inside what it captured.
    $text = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
    return @($text -split '\r?\n')
}
function Get-Slug([string]$heading) {
    # GitHub's anchor for a heading: lowercase; everything that is not a letter, a digit, whitespace, a hyphen or an
    # underscore removed; whitespace to hyphens. The em dash of '### 41 - Nothing checks ...' is removed and the two
    # spaces around it survive as the double hyphen the page's own links carry (#41--nothing-checks-...).
    return (([regex]::Replace($heading.ToLowerInvariant(), '[^\p{L}\p{N}\s_-]', '')) -replace '\s', '-')
}
function Format-Numbers($numbers) { return (@(@($numbers) | Sort-Object { [int]$_ } -Unique | ForEach-Object { '#' + $_ }) -join ', ') }
function Get-Duplicates($list) { return @(@($list) | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name }) }
function Find-Line([string[]]$lines, [string]$wanted) {
    for ($i = 0; $i -lt $lines.Count; $i++) { if ([string]::Equals($lines[$i].Trim(), $wanted, [StringComparison]::Ordinal)) { return $i } }
    return -1
}

# ------------------------------------------ I. the page against itself
$lines = Read-Lines $BacklogPath
$openAt = Find-Line $lines '## Open items'
$closedAt = Find-Line $lines '## Closed items'
$rulesAt = Find-Line $lines '## Adding and closing an item'
$shape = ($openAt -ge 0) -and ($closedAt -gt $openAt) -and ($rulesAt -gt $closedAt)
Assert-True 'I0 the page has its three sections, in order: Open items, Closed items, Adding and closing an item' $shape ('found at lines {0}, {1}, {2} (0 = not found); nothing below can be read without them' -f ($openAt + 1), ($closedAt + 1), ($rulesAt + 1))
if (-not $shape) { Write-Summary; exit $fails }

$TableRow = '^\|\s*(\d+)\s*\|'
$BodyHeading = '^### (\d+) ' + [string][char]0x2014 + ' (.+?)\s*$'
# The open table is the rows between the Open items heading and the first item body; a table inside a body is that
# body's own. The bodies are every item heading before the Closed items heading, with the heading text kept for the
# anchor. The closed table is every row between the Closed items heading and the rules.
$openRows = New-Object System.Collections.Generic.List[string]
$bodyNumbers = New-Object System.Collections.Generic.List[string]
$headings = @{}
for ($i = $openAt + 1; $i -lt $closedAt; $i++) {
    $line = $lines[$i]
    if ($line -match $BodyHeading) {
        $n = [string][int]$Matches[1]
        $bodyNumbers.Add($n)
        if (-not $headings.ContainsKey($n)) { $headings[$n] = $line.Substring(4).TrimEnd() }
        continue
    }
    if (($bodyNumbers.Count -eq 0) -and ($line -match $TableRow)) { $openRows.Add([string][int]$Matches[1]) }
}
$closedRows = New-Object System.Collections.Generic.List[string]
for ($i = $closedAt + 1; $i -lt $rulesAt; $i++) { if ($lines[$i] -match $TableRow) { $closedRows.Add([string][int]$Matches[1]) } }

$open = @($openRows | Sort-Object { [int]$_ } -Unique)
$closed = @($closedRows | Sort-Object { [int]$_ } -Unique)
$bodies = @($bodyNumbers | Sort-Object { [int]$_ } -Unique)

$noBody = @($open | Where-Object { $bodies -notcontains $_ })
Assert-True ('I1 every open row has a body ({0} rows)' -f $open.Count) ($noBody.Count -eq 0) ('row without a body: ' + (Format-Numbers $noBody))
$noRow = @($bodies | Where-Object { $open -notcontains $_ })
Assert-True ('I2 every body has an open row ({0} bodies)' -f $bodies.Count) ($noRow.Count -eq 0) ('body without an open row: ' + (Format-Numbers $noRow))
$both = @($open | Where-Object { $closed -contains $_ })
Assert-True ('I3 no number is in both tables ({0} closed rows)' -f $closed.Count) ($both.Count -eq 0) ('in both tables: ' + (Format-Numbers $both))
$used = @(@($open) + @($closed) | ForEach-Object { [int]$_ })
$highest = 0
if ($used.Count) { $highest = [int](($used | Measure-Object -Maximum).Maximum) }
$gaps = @()
if ($highest -gt 0) { $gaps = @(1..$highest | Where-Object { $used -notcontains $_ }) }
# The numbers start at 1: a row or a body numbered 0 is a number the casts keep and the range above never sees
# (PR #63, round 4), and it is not the next unused number that an addition receives.
$belowOne = @(@($openRows) + @($closedRows) + @($bodyNumbers) | Where-Object { [int]$_ -lt 1 } | Sort-Object -Unique)
$gapDetail = @()
if ($highest -eq 0) { $gapDetail += 'no row in either table' }
if ($gaps.Count) { $gapDetail += ('in neither table: ' + (Format-Numbers $gaps)) }
if ($belowOne.Count) { $gapDetail += ('below 1: ' + (Format-Numbers $belowOne)) }
Assert-True ('I4 every number from 1 to {0}, the highest used, is in one of the tables, and none is below 1' -f $highest) ($gapDetail.Count -eq 0) ($gapDetail -join '; ')
$dupOpen = Get-Duplicates $openRows; $dupClosed = Get-Duplicates $closedRows; $dupBody = Get-Duplicates $bodyNumbers
$dupDetail = @()
if ($dupOpen.Count) { $dupDetail += ('twice in the open table: ' + (Format-Numbers $dupOpen)) }
if ($dupClosed.Count) { $dupDetail += ('twice in the closed table: ' + (Format-Numbers $dupClosed)) }
if ($dupBody.Count) { $dupDetail += ('two bodies: ' + (Format-Numbers $dupBody)) }
Assert-True 'I5 no number is listed twice in a table or has two bodies' ($dupDetail.Count -eq 0) ($dupDetail -join '; ')

# ------------------------------------------ R. the README's Backlog row against the page
$readme = Read-Lines $ReadmePath
$rows = @($readme | Where-Object { $_ -match '^\|\s*Backlog\s*\|' })
Assert-True 'R0 the README has one Backlog row' ($rows.Count -eq 1) ('{0} rows begin with "| Backlog |"; nothing below can be read without one' -f $rows.Count)
if ($rows.Count -ne 1) { Write-Summary; exit $fails }
$row = [string]$rows[0]

$countMatch = [regex]::Match($row, '^\|\s*Backlog\s*\|\s*(\d+) items? open\b')
$stated = $(if ($countMatch.Success) { [int]$countMatch.Groups[1].Value } else { -1 })
Assert-True ('R1 the README''s open count is the index''s row count ({0})' -f $open.Count) ($stated -eq $open.Count) $(if ($countMatch.Success) { ('the README says {0} items open' -f $stated) } else { 'the row does not begin with "N items open"' })

# The closed list is the sentence 'Numbers ... are closed'; everything before it is the open part of the row.
$closedSentence = [regex]::Match($row, 'Numbers\s+(.+?)\s+are closed')
$openPart = $(if ($closedSentence.Success) { $row.Substring(0, $closedSentence.Index) } else { $row })

# The links the open part carries, each with its number and its target; then a copy of the open part with every
# markdown link reduced to its text - [#N] for an item link - so that the parentheses left are the row's own.
$LinkPattern = '\[#(\d+)\]\(([^()\s]+)\)'
$links = @([regex]::Matches($openPart, $LinkPattern) | ForEach-Object { @{ Number = [string][int]$_.Groups[1].Value; Target = $_.Groups[2].Value; Text = $_.Value } })
$scan = [regex]::Replace($openPart, $LinkPattern, { param($m) '[#' + [string][int]$m.Groups[1].Value + ']' })
$scan = [regex]::Replace($scan, '\[([^\]]*)\]\([^()]*\)', { param($m) $m.Groups[1].Value })

$listed = @($links | ForEach-Object { $_.Number } | Sort-Object { [int]$_ } -Unique)
$notOpen = @($listed | Where-Object { $open -notcontains $_ })
Assert-True ('R2 every item the README lists as open is an open row ({0} listed)' -f $listed.Count) ($notOpen.Count -eq 0) ('listed as open and not an open row: ' + (Format-Numbers $notOpen))
$notListed = @($open | Where-Object { $listed -notcontains $_ })
Assert-True 'R3 every open row is listed in the README' ($notListed.Count -eq 0) ('open and not listed: ' + (Format-Numbers $notListed))

# R4: a listed item links to its own heading. An item without a body is I1's finding and has no anchor to compare.
$wrongAnchor = @()
foreach ($link in $links) {
    if (-not $headings.ContainsKey($link.Number)) { continue }
    $expected = 'docs/backlog.md#' + (Get-Slug $headings[$link.Number])
    if (-not [string]::Equals($link.Target, $expected, [StringComparison]::Ordinal)) { $wrongAnchor += ('{0} should be [#{1}]({2})' -f $link.Text, $link.Number, $expected) }
}
Assert-True ('R4 every listed item links to its own heading ({0} links)' -f $links.Count) ($wrongAnchor.Count -eq 0) ($wrongAnchor -join '; ')

# R5: the groups. A top-level parenthesis of the reduced open part that holds at least one item link is a group;
# its stated count is the last number in the text since the previous group closed. Nesting is allowed inside a
# group; a parenthesis with no item link in it is prose.
$NumberWords = @('one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine', 'ten', 'eleven', 'twelve', 'thirteen', 'fourteen', 'fifteen', 'sixteen', 'seventeen', 'eighteen', 'nineteen', 'twenty')
# A count stands alone: digits joined to a hyphen, a dot, a colon or a hash are a date, a version, a time or a mention
# (2026-09-09, 1.2.8, #25), and the last of those before a parenthesis is not what the group says it holds.
$CountPattern = '(?i)(?<![#\d.:-])\b(\d+|' + ($NumberWords -join '|') + ')\b(?![\d.:-])'
function ConvertTo-Count([string]$token) {
    if ($token -match '^\d+$') { return [int]$token }
    return ([array]::IndexOf($NumberWords, $token.ToLowerInvariant()) + 1)
}
$groups = New-Object System.Collections.Generic.List[hashtable]
$depth = 0; $start = -1; $previousEnd = 0
for ($i = 0; $i -lt $scan.Length; $i++) {
    $c = $scan[$i]
    if ($c -eq '(') { if ($depth -eq 0) { $start = $i }; $depth++ }
    elseif ($c -eq ')') {
        if ($depth -gt 0) { $depth-- }
        if (($depth -eq 0) -and ($start -ge 0)) {
            $inside = $scan.Substring($start + 1, $i - $start - 1)
            $members = @([regex]::Matches($inside, '\[#(\d+)\]') | ForEach-Object { [string][int]$_.Groups[1].Value })
            if ($members.Count -gt 0) {
                $before = $scan.Substring($previousEnd, $start - $previousEnd)
                $counts = @([regex]::Matches($before, $CountPattern))
                # The group is named by its count phrase - 'nine in tests/ and the build' - or, without one, by the
                # tail of what precedes it.
                $label = $(if ($counts.Count) { $before.Substring($counts[$counts.Count - 1].Index).Trim() } else { $before.Trim() })
                if ($label.Length -gt 60) { $label = '...' + $label.Substring($label.Length - 60) }
                $groups.Add(@{ Label = $label; Members = $members; Start = $start; End = $i; Stated = $(if ($counts.Count) { ConvertTo-Count $counts[$counts.Count - 1].Groups[1].Value } else { -1 }) })
                $previousEnd = $i + 1
            }
            $start = -1
        }
    }
}
$groupProblems = @()
$sum = 0; $appearances = 0
foreach ($g in $groups) {
    $sum += [Math]::Max(0, $g.Stated); $appearances += $g.Members.Count
    if ($g.Stated -lt 0) { $groupProblems += ('no count before "{0}"' -f $g.Label) }
    elseif ($g.Stated -ne $g.Members.Count) { $groupProblems += ('"{0}" says {1} and lists {2}: {3}' -f $g.Label, $g.Stated, $g.Members.Count, (Format-Numbers $g.Members)) }
    # An item stands in a group once: a copied link, with the count raised to cover it, is a second membership of the
    # same group and not of a further one, and the arithmetic would count it as an item (PR #63, round 2).
    $twice = Get-Duplicates $g.Members
    if ($twice.Count) { $groupProblems += ('"{0}" lists {1} twice' -f $g.Label, (Format-Numbers $twice)) }
}
# A link outside every group is listed and counted nowhere, and the row's rule is that an item stands inside a group:
# with the groups blanked out, any item link left is such a link (PR #63, round 1 - a link moved out of its group,
# the group's count lowered with it, passed every check).
$outside = $scan
foreach ($g in $groups) { $outside = $outside.Substring(0, $g.Start) + (' ' * ($g.End - $g.Start + 1)) + $outside.Substring($g.End + 1) }
$ungrouped = @([regex]::Matches($outside, '\[#(\d+)\]') | ForEach-Object { [string][int]$_.Groups[1].Value })
if ($ungrouped.Count) { $groupProblems += ('listed outside every group: ' + (Format-Numbers $ungrouped)) }
# Where the row states what the groups sum to and how many items there are - 'the groups sum to fifteen where the
# items are fourteen' - the two numbers are the arithmetic above and no other; a row without the sentence states
# no total to check.
$overlap = [regex]::Match($openPart, '(?i)\bsum to (\d+|[a-z]+) where the items are (\d+|[a-z]+)\b')
if ($overlap.Success) {
    $saidSum = ConvertTo-Count $overlap.Groups[1].Value; $saidItems = ConvertTo-Count $overlap.Groups[2].Value
    if (($saidSum -ne $sum) -or ($saidItems -ne $listed.Count)) { $groupProblems += ('the row says the groups sum to {0} where the items are {1}; they sum to {2} and the items are {3}' -f $saidSum, $saidItems, $sum, $listed.Count) }
}
# An item in more than one group is counted once per group it stands in, whatever a group repeats.
$repeated = @($groups | ForEach-Object { @($_.Members | Sort-Object -Unique) } | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
$arithmetic = ('{0} = {1}' -f (@($groups | ForEach-Object { [string]$_.Stated }) -join ' + '), $sum)
if ($repeated.Count) { $arithmetic += (': {0} items, {1} in more than one group' -f $listed.Count, (Format-Numbers $repeated)) } else { $arithmetic += (': {0} items, none in more than one group' -f $listed.Count) }
Assert-True ('R5 each group''s stated count is the number of items it lists, and no listed item stands outside a group ({0} groups; {1})' -f $groups.Count, $arithmetic) (($groups.Count -gt 0) -and ($groupProblems.Count -eq 0)) $(if ($groups.Count -eq 0) { 'the row has no group: no parenthesis holding an item link' } else { $groupProblems -join '; ' })

# R6: the closed list, 'Numbers 1 to 20, 23, 24, ... are closed', expanded and set against the closed table.
$listedClosed = @(); $unreadable = @()
if ($closedSentence.Success) {
    foreach ($token in ($closedSentence.Groups[1].Value -split ',')) {
        $t = $token.Trim()
        if ($t -match '^(\d+)\s+to\s+(\d+)$') { $a = [int]$Matches[1]; $b = [int]$Matches[2]; if ($b -ge $a) { $listedClosed += @($a..$b | ForEach-Object { [string]$_ }) } else { $unreadable += $t } }
        elseif ($t -match '^(\d+)$') { $listedClosed += [string][int]$Matches[1] }
        else { $unreadable += $t }
    }
}
# A number listed twice - '1 to 20, 20', or two ranges that overlap - is a malformed list, and the set comparison
# below would not see it (PR #63, round 3); it is found before the list is reduced to a set.
$twiceClosed = Get-Duplicates $listedClosed
$listedClosed = @($listedClosed | Sort-Object { [int]$_ } -Unique)
$closedMissing = @($closed | Where-Object { $listedClosed -notcontains $_ })
$closedExtra = @($listedClosed | Where-Object { $closed -notcontains $_ })
$closedDetail = @()
if (-not $closedSentence.Success) { $closedDetail += 'the row has no "Numbers ... are closed" sentence' }
if ($unreadable.Count) { $closedDetail += ('unreadable: ' + ($unreadable -join ', ')) }
if ($twiceClosed.Count) { $closedDetail += ('listed as closed twice: ' + (Format-Numbers $twiceClosed)) }
if ($closedMissing.Count) { $closedDetail += ('closed and not listed: ' + (Format-Numbers $closedMissing)) }
if ($closedExtra.Count) { $closedDetail += ('listed as closed and not in the closed table: ' + (Format-Numbers $closedExtra)) }
Assert-True ('R6 the README''s closed list is the closed table, each number once ({0} numbers)' -f $closed.Count) ($closedDetail.Count -eq 0) ($closedDetail -join '; ')

Write-Summary
exit $fails
