param([string]$EnUsAnchor, [string]$ZhTwAnchor)
# Self-test of the two AST guards in ast_guards.ps1 (backlog #17; until 2026-09-04 they were regular expressions in
# healthcheck/tools/validate_release.py and this file was selftest_guards.py). Four parts:
#   1. the v1.2.0 files must be flagged at the known lines - the top-level `$script:Interactive = $false` (line 77 in
#      en-US, 70 in zh-TW) and the six `New-Object System.Drawing.Point(22, 84 + $offset)` constructor lines;
#   2. the current shipped files must parse and come back clean;
#   3. the corpus below - built up over the twenty-one Codex rounds of PR #4, one case per spelling a round proposed,
#      plus the shapes the AST rewrite made reachable - must be classified exactly as recorded;
#   4. the guards must survive a file that does not parse (the parse step's finding, not theirs).
# The anchors are read from git (commit f7c45a9, the merge of PR #3 = v1.2.0 as shipped) unless a file is passed in.
#
# Usage:  tests\selftest_guards.ps1 [-EnUsAnchor <v1.2.0 en-US .ps1>] [-ZhTwAnchor <v1.2.0 zh-TW .ps1>]
# A case is written on one line: `\n` in a case stands for a line break (no case needs a literal backslash-n).
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ast_guards.ps1')

$Root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$AnchorCommit = 'f7c45a9'
$Anchors = @{
    'en-US' = @{ Parameters = @('77 ($Interactive)'); Arithmetic = @(3756, 3764, 3770, 3779, 3784, 3834); Override = $EnUsAnchor }
    'zh-TW' = @{ Parameters = @('70 ($Interactive)'); Arithmetic = @(3749, 3757, 3763, 3772, 3777, 3827); Override = $ZhTwAnchor }
}
$ok = $true

function Get-AnchorText([string]$Language, [string]$Override) {
    if ($Override) { return [IO.File]::ReadAllText((Resolve-Path -LiteralPath $Override).Path) }
    # The blob's own bytes: the working tree is CRLF and the repository LF, which changes no line number, but the
    # console encoding would mangle the zh-TW strings if the output went through the pipeline.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'git'
    $psi.Arguments = ('-C "{0}" show {1}:healthcheck/{2}/NetworkHealthCheck.ps1' -f $Root, $AnchorCommit, $Language)
    $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $process = [System.Diagnostics.Process]::Start($psi)
    $text = $process.StandardOutput.ReadToEnd()
    $errorText = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) { throw ('git show {0}:healthcheck/{1}/NetworkHealthCheck.ps1 failed: {2}' -f $AnchorCommit, $Language, $errorText.Trim()) }
    return $text.TrimStart([char]0xFEFF)
}
function Test-SameList($Actual, $Expected) { return (@($Actual) -join ' | ') -eq (@($Expected) -join ' | ') }
function Expand-Case([string]$Case) { return $Case.Replace('\n', "`n") }
# One object per case rather than a dictionary entry or a pair: PowerShell's hash tables are case-insensitive while the
# corpus holds cases that differ only in case ($Script:Interactive against $script:Interactive), and an array literal
# would flatten a pair into its two values.
function New-Case([string]$Text, [bool]$Expect) { return [pscustomobject]@{ Text = $Text; Expect = $Expect } }

# -------------------- 1. the v1.2.0 anchors --------------------

foreach ($language in @('en-US', 'zh-TW')) {
    $anchor = $Anchors[$language]
    $text = Get-AnchorText $language $anchor.Override
    $parameters = @(Find-OverwrittenParameter $text)
    $arithmetic = @(Find-UnparenthesizedArithmetic $text)
    Write-Output ('v1.2.0 {0} ({1}): parameter guard [{2}]; arithmetic guard [{3}]' -f $language, $(if ($anchor.Override) { $anchor.Override } else { $AnchorCommit }), ($parameters -join ', '), ($arithmetic -join ', '))
    if (-not (Test-SameList $parameters $anchor.Parameters)) { $ok = $false; Write-Output ('  MISMATCH: expected parameter guard [{0}]' -f ($anchor.Parameters -join ', ')) }
    if (-not (Test-SameList $arithmetic $anchor.Arithmetic)) { $ok = $false; Write-Output ('  MISMATCH: expected arithmetic guard [{0}]' -f ($anchor.Arithmetic -join ', ')) }
}

# -------------------- 2. the shipped files --------------------

foreach ($language in @('en-US', 'zh-TW')) {
    $text = [IO.File]::ReadAllText((Join-Path $Root ('healthcheck\{0}\NetworkHealthCheck.ps1' -f $language)))
    $errors = @(Get-GuardParseError $text)
    $parameters = @(Find-OverwrittenParameter $text)
    $arithmetic = @(Find-UnparenthesizedArithmetic $text)
    Write-Output ('current {0}: {1} parse error(s); parameter guard [{2}]; arithmetic guard [{3}]' -f $language, $errors.Count, ($parameters -join ', '), ($arithmetic -join ', '))
    if ($errors.Count -or $parameters.Count -or $arithmetic.Count) { $ok = $false; Write-Output '  MISMATCH: the shipped file must parse and come back clean' }
}

# -------------------- 3. the corpus --------------------

$Head = $null
$source = [IO.File]::ReadAllText((Join-Path $Root 'healthcheck\en-US\NetworkHealthCheck.ps1'))
$Head = $source.Substring(0, $source.IndexOf("`n)")) + "`n)`n"   # the shipped param block, so the cases have parameters

# Written at the top level of a script that has the shipped param block: $true = the guard must report it.
$Cases = @(
    New-Case '$script:Interactive = $false # $Interactive' $true
    New-Case '$script:Interactive = $InteractiveBackup' $true
    New-Case '$script:Interactive = [bool]$Interactive' $false
    New-Case '$script:Interactive = ${Interactive}' $false
    New-Case '$script:Interactive = $Interactive.IsPresent' $false
    New-Case '$script:ConfigPath = "$ConfigPath"' $true
    New-Case '$script:ConfigPath = ''literal # $ConfigPath''' $true
    New-Case '    $script:PingCount = 4' $true
    New-Case '$script:Interactive=$false' $true
    New-Case '$script:Interactive = $false <# $Interactive #>' $true
    New-Case '$script:ConfigPath = "it''s $ConfigPath"' $true
    New-Case '$script:ConfigPath = ''a'' + $ConfigPath' $true
    New-Case '$script:ConfigPath = ''it''''s'' + $ConfigPath' $true
    New-Case '$script:interactive = $false' $true
    New-Case '$Script:Interactive = [bool]$interactive' $false
    New-Case '${script:Interactive} = $false' $true
    New-Case '${script:Interactive} = ${Interactive}' $false
    New-Case '$global:Interactive = $false' $true
    New-Case '$Interactive = $false' $true
    New-Case '$interactive = [bool]$Interactive' $false
    New-Case '$local:Interactive = $false' $true
    New-Case '$ConfigPath = $ConfigPath.Trim()' $true
    New-Case '$entryPoint = "User"' $false
    New-Case 'Set-Variable -Scope Script -Name Interactive -Value $false' $true
    New-Case 'Set-Variable -Name Interactive -Scope Global -Value ([bool]$Interactive)' $true
    New-Case 'Set-Variable -Name Interactive -Value $false' $true
    New-Case 'New-Variable -Name Interactive -Value 1 -Force' $true
    New-Case 'Set-Variable Interactive $false' $true
    New-Case 'Set-Variable -Scope Script -Name Other -Value 1' $false
    New-Case 'Set-Variable -Scope Local -Name Interactive -Value $false' $true
    New-Case '[bool]$script:Interactive = $false' $true
    New-Case '[bool] $script:Interactive = $false' $true
    New-Case '[bool]$script:Interactive = [bool]$Interactive' $false
    New-Case '[ValidateNotNull()][bool]$script:Interactive = $false' $true
    New-Case '[string[]]$PingTarget = @()' $true
    New-Case '[string[]]$PingTarget = @($PingTarget)' $false
    New-Case '[int]$Interactive = 1' $true
    New-Case '<# comment\n#> $script:Interactive = $false' $true
    New-Case '<#\n$script:Interactive = $false\n#>' $false
    New-Case '<# a #> $script:Interactive = $false' $true
    New-Case '$x = 1 <# start\n$script:Interactive = $false # inside\nend #>\n$script:Interactive = [bool]$Interactive' $false
    New-Case 'if ($c) { $script:Interactive = $false }' $true
    New-Case 'if ($c) { $Interactive = $false }' $true
    New-Case '$a = 1; $script:Interactive = $false' $true
    New-Case 'try { $script:Interactive = [bool]$Interactive } catch { }' $false
    New-Case 'if ($c) { ${script:Interactive} = $false }' $true
    New-Case 'foreach ($i in 1..3) { $script:PingCount = $i }' $true
    New-Case '$h = @{ Interactive = $false }' $false
    New-Case '$h[$script:Interactive] = 1' $false
    New-Case '$script:Interactive.Value = $false' $false
    New-Case 'function F { $Interactive = $false }' $false
    New-Case 'function F { $Interactive = $false }\n$Interactive = $false' $true
    New-Case 'function F {\n    $Interactive = $false\n}\n$script:Interactive = [bool]$Interactive' $false
    New-Case '$script:Interactive `\n    = $false' $true
    New-Case '$script:Interactive `\n    = [bool]$Interactive' $false
    New-Case '$script:Interactive = `\n    $false' $true
    New-Case '$x = 1 `\n    ; $script:Interactive = $false' $true
    New-Case '$script:Interactive = $Interactive -and $false' $true
    New-Case '$script:Interactive = -not $Interactive' $true
    New-Case '$script:Interactive = ($Interactive)' $false
    New-Case '$script:Interactive = [bool]($Interactive)' $false
    New-Case '$script:Interactive = ([bool]$Interactive)' $false
    New-Case '$script:Interactive = [bool]$Interactive.IsPresent' $false
    New-Case '$script:Interactive = $Interactive, $true' $true
    New-Case '$script:Interactive = if ($x) { $Interactive } else { $false }' $true
    New-Case '$script:PingCount = $PingCount + 1' $true
    New-Case '$script:PingCount = [int]$PingCount' $false
    New-Case 'function Reset-Interactive { $script:Interactive = $false }' $true
    New-Case 'function F { $script:Interactive = [bool]$Interactive }' $false
    New-Case 'function F { Set-Variable -Scope Script -Name Interactive -Value $false }' $true
    New-Case 'function F { Set-Variable -Name Interactive -Value $false }' $false
    New-Case 'function F { $global:Interactive = $false }' $true
    New-Case 'function F { $Interactive = $false }\n$script:Interactive = $false' $true
    New-Case '$script:PingCount += 1' $true
    New-Case '$script:PingCount -= 1' $true
    New-Case '$script:PingCount++' $true
    New-Case '++$script:PingCount' $true
    New-Case '$script:PingCount--' $true
    New-Case '$PingCount += 1' $true
    New-Case 'if ($c) { $script:PingCount++ }' $true
    New-Case '$script:PingCount -eq 1' $false
    New-Case '$x = $script:PingCount - 1' $false
    New-Case '$total = $PingCount + 1' $false
    New-Case '$script:PingCount | Out-Null' $false
    New-Case '--$PingCount' $true
    New-Case 'if ($c) { ++$script:PingCount }' $true
    New-Case '$a = "<#"\n$script:Interactive = $false\n$b = "#>"' $true
    New-Case '$a = ''<#''\n$script:Interactive = $false\n$b = ''#>''' $true
    New-Case '$s = "say ""<#"" now"\n$script:Interactive = $false' $true
    New-Case '# see <# below\n$script:Interactive = $false' $true
    New-Case '$s = "it`"s <#"\n$script:Interactive = $false' $true
    New-Case '<# real\n$script:Interactive = $false\n#>' $false
    New-Case 'Write-Output `#; $script:Interactive = $false' $true
    New-Case 'Write-Output `# not a comment; $script:Interactive = $false' $true
    New-Case 'Write-Output `#; $script:Interactive = [bool]$Interactive' $false
    New-Case 'Write-Output x # `# still a comment; $script:Interactive = $false' $false
    New-Case '$a = "<#"; $script:Interactive = $false; $b = "#>"' $true
    New-Case 'Set-Variable -Na Interactive -Value $false' $true
    New-Case 'Set-Variable -N Interactive -Va $false' $true
    New-Case 'Set-Variable -Na Other -Value 1' $false
    New-Case 'Set-Variable -Name Interactive -Sc Script -Value $false' $true
    New-Case 'sv Interactive $false' $true
    New-Case 'nv Interactive 1' $true
    New-Case 'sv -Name Interactive -Value $false' $true
    New-Case 'sv Other 1' $false
    New-Case '$nv = 1' $false
    New-Case '$sv = $Interactive' $false
    New-Case 'Set-Variable -Name ''Interactive'' -Value $false' $true
    New-Case 'sv ''Interactive'' $false' $true
    New-Case 'Set-Variable -Name "Interactive" -Value $false' $true
    New-Case 'Set-Variable -Name ''Other'' -Value 1' $false
    New-Case 'Write-Output ''sv Interactive''' $false
    New-Case 'Write-Output "sv Interactive $false"' $false
    New-Case 'Write-Output "x; $script:Interactive = $false"' $false
    New-Case 'Write-Output "sv Other"; sv ''Interactive'' $false' $true
    New-Case '($script:Interactive = $false)' $true
    New-Case '($script:Interactive = [bool]$Interactive)' $false
    New-Case 'for ($script:PingCount = 0; $script:PingCount -lt 3; $script:PingCount++) { }' $true
    New-Case 'Set-Variable -Name Tmp -Value 1; Set-Variable -Name Interactive -Value $false' $true
    New-Case 'sv Tmp 1; sv Interactive $false' $true
    New-Case 'Set-Variable -Name Tmp -Value 1; Set-Variable -Name Other -Value 2' $false
    New-Case 'sv Tmp 1; $x = 2' $false
    New-Case 'Set-Variable -Name PingCount -Scope 0 -Value 1' $true
    New-Case 'Set-Item -Path Variable:Interactive -Value $false' $true
    New-Case 'Set-Item Variable:Interactive $false' $true
    New-Case 'Set-Content -Path ''Variable:Interactive'' -Value $false' $true
    New-Case 'si Variable:Interactive $false' $true
    New-Case 'Remove-Item Variable:Interactive' $true
    New-Case 'Clear-Item -LiteralPath Variable:PingCount' $true
    New-Case 'Set-Item -Path Variable:Other -Value 1' $false
    New-Case 'Set-Item -Path HKCU:\Software\Test -Value 1' $false
    New-Case 'Get-Item Variable:Interactive' $false
    New-Case 'Write-Output "Set-Item Variable:Interactive"' $false
    # The shapes the AST reaches that the regular expressions did not: the three variants assessed and deferred in
    # round 21 of PR #4 (a multiple assignment, Clear-Variable / Remove-Variable, an alias of the cmdlet), a foreach
    # loop variable, a module-qualified call, another store, and code the parser sees as string data rather than text
    # a stripper has to recognise.
    New-Case '$tmp, $script:Interactive = 1, $false' $true
    New-Case '$tmp, $Interactive = 1, $false' $true
    New-Case '$tmp, $other = 1, $false' $false
    New-Case '$script:Interactive = $Interactive' $false
    New-Case 'Clear-Variable -Name Interactive' $true
    New-Case 'Clear-Variable -Name Other' $false
    New-Case 'Remove-Variable -Name Interactive' $true
    New-Case 'clv Interactive' $true
    New-Case 'rv Interactive' $true
    New-Case 'set Interactive $false' $true
    New-Case 'sc Variable:Interactive $false' $true
    New-Case 'rm Variable:Interactive' $true
    New-Case 'ni Variable:Interactive' $true
    New-Case 'Microsoft.PowerShell.Utility\Set-Variable -Name Interactive -Value $false' $true
    New-Case 'foreach ($PingCount in 1..3) { $x = 1 }' $true
    New-Case 'foreach ($other in 1..3) { $x = 1 }' $false
    New-Case '$env:Interactive = 1' $false
    New-Case '$s = @"\n$script:Interactive = $false\n"@' $false
    New-Case '$s = @''\n$script:Interactive = $false\n''@' $false
)
# The same lines inside a function: an unqualified write is a local there, an explicit $script: / $global: one is not.
$FunctionCases = @(
    New-Case '$script:Interactive = $false' $true
    New-Case '$Interactive = $false' $false
    New-Case '$local:Interactive = $false' $false
    New-Case 'Set-Variable -Name Interactive -Value $false' $false
    New-Case 'Set-Variable -Scope Script -Name Interactive -Value $false' $true
    New-Case 'Set-Variable -Scope 1 -Name Interactive -Value $false' $true
    New-Case 'Set-Variable -Scope Local -Name Interactive -Value $false' $false
    New-Case '[int]$Interactive = 1' $false
    New-Case '[bool]$script:Interactive = $false' $true
    New-Case 'if ($c) { $Interactive = $false }' $false
    New-Case 'if ($c) { $script:Interactive = $false }' $true
    New-Case '$a = 1; $script:Interactive = $false' $true
    New-Case '$Interactive `\n    = $false' $false
    New-Case '$PingCount += 1' $false
    New-Case '$script:PingCount++' $true
    New-Case 'Set-Variable -N Interactive -Sc Script -Value $false' $true
    New-Case 'Set-Variable -N Interactive -Value $false' $false
    New-Case 'sv -Scope Script -Name Interactive -Value $false' $true
    New-Case 'sv Interactive $false' $false
    New-Case 'sv -Scope ''Script'' -Name Interactive -Value $false' $true
    New-Case 'sv ''Interactive'' $false' $false
    New-Case 'sv Tmp 1; sv -Scope Script -Name Interactive -Value $false' $true
    New-Case 'sv Tmp 1; sv Interactive $false' $false
    New-Case 'Set-Variable -Name PingCount -Scope 0 -Value 1' $false
    New-Case 'Set-Variable -Name PingCount -Scope 1 -Value 1' $true
    New-Case 'Set-Item -Path Variable:Interactive -Value $false' $false
    # New with the AST: a multiple assignment, the deferred cmdlets, and a -Scope the parser cannot read.
    New-Case '$tmp, $script:Interactive = 1, $false' $true
    New-Case '$tmp, $Interactive = 1, $false' $false
    New-Case 'Clear-Variable -Name Interactive' $false
    New-Case 'Clear-Variable -Name Interactive -Scope Script' $true
    New-Case 'Remove-Variable -Scope Global -Name Interactive' $true
    New-Case 'foreach ($PingCount in 1..3) { $x = 1 }' $false
    New-Case 'Set-Variable -Name Interactive -Scope $scope -Value $false' $true
)
# Constructor argument lists, checked on their own (no param block needed).
$ArithmeticCases = @(
    New-Case '$a.Location = New-Object System.Drawing.Point(22, 84 + $offset)' $true
    New-Case '$a.Location = New-Object System.Drawing.Point(22, (84 + $offset))' $false
    New-Case '$a.Location = New-Object System.Drawing.Point(22, 84) # x + y' $false
    New-Case '$a.Location = New-Object System.Drawing.Point(22, 84 + $offset) # note' $true
    New-Case '$s = New-Object System.Drawing.Size(940, $formHeight)' $false
    New-Case '$a = New-Object System.Drawing.Point(-5, 3)' $false
    New-Case '$f = New-Object System.Drawing.Font($form.Font.FontFamily, 18, [System.Drawing.FontStyle]::Bold)' $false
    New-Case 'new-object System.Drawing.Point(22, 84 + $offset)' $true
    New-Case 'NEW-OBJECT System.Drawing.Size(900, 700 + $offset)' $true
    New-Case '$a.Location = New-Object -TypeName System.Drawing.Point -ArgumentList (22, 84 + $offset)' $true
    New-Case '$a.Location = New-Object -TypeName System.Drawing.Point -ArgumentList (22, (84 + $offset))' $false
    New-Case '$a = New-Object System.Drawing.Point(22, 84); $y = (3 + 4)' $false
    New-Case '$o = New-Object PSObject -Property @{ A = 1 }' $false
    New-Case '$s = New-Object System.Drawing.Size(780, [math]::Min(560 + $offset, $formHeight))' $false
    New-Case '$a.Location = New-Object System.Drawing.Point(22, $bottomY + 44); $b = 1' $true
    New-Case '$a.Location = New-Object System.Drawing.Point(22,\n    84 + $offset)' $true
    New-Case '$a.Location = New-Object System.Drawing.Point(22,\n    (84 + $offset))' $false
    New-Case '$a = New-Object -TypeName System.Drawing.Point `\n    -ArgumentList (22, 84 + $offset)' $true
    New-Case '$f = New-Object Foo("a+b", 1)' $false
    New-Case '$f = New-Object Foo(''x-y'', 1)' $false
    New-Case '<#\nNew-Object System.Drawing.Point(22, 84 + $offset)\n#>' $false
    New-Case '$a = New-Object System.Drawing.Point(22, 84) <# x + y\n#> $b = 1' $false
    New-Case '$a = New-Object -TypeName System.Drawing.Point -ArgumentList 22, 84 + $offset' $true
    New-Case '$a = New-Object -TypeName System.Drawing.Point -ArgumentList 22, (84 + $offset)' $false
    New-Case '$a = New-Object -TypeName System.Drawing.Point -ArgumentList 22, 84 -Property @{}' $false
    New-Case '$a = New-Object -TypeName Foo -ArgumentList 22, -5' $false
    New-Case '$a = New-Object -TypeName System.Drawing.Point `\n    -ArgumentList 22, 84 + $offset' $true
    New-Case '$a = New-Object -TypeName Foo -ArgumentList "a+b", 1' $false
    New-Case '$a = New-Object -TypeName Foo -ArgumentList 1, 2; $b = 3 + 4' $false
    New-Case '$a = New-Object System.Drawing.Point(22, 84 % $offset)' $true
    New-Case '$a = New-Object System.Drawing.Point(22, (84 % $offset))' $false
    New-Case '$a = New-Object Foo("50%", 1)' $false
    New-Case '$a = "<#"\nNew-Object System.Drawing.Point(22, 84 + $offset)\n$b = "#>"' $true
    New-Case 'Write-Output `#; New-Object System.Drawing.Point(22, 84 + $offset)' $true
    New-Case '$a = New-Object -Type System.Drawing.Point(22, 84 + $offset)' $true
    New-Case '$a = New-Object -T System.Drawing.Point -Arg (22, 84 + $offset)' $true
    New-Case '$a = New-Object -TypeName System.Drawing.Point -A 22, 84 + $offset' $true
    New-Case '$a = New-Object -Type System.Drawing.Point(22, (84 + $offset))' $false
    New-Case '$a = New-Object -T System.Drawing.Point -Arg (22, 84)' $false
    New-Case '$a = New-Object System.Drawing.Point 22, 84 + $offset' $true
    New-Case '$a = New-Object -Type System.Drawing.Point 22, 84 + $offset' $true
    New-Case '$a = New-Object System.Drawing.Point 22, (84 + $offset)' $false
    New-Case '$a = New-Object System.Drawing.Point 22, 84' $false
    New-Case '$l = New-Object System.Collections.ArrayList\n$x = 1 + 2' $false
    New-Case '$a = New-Object System.Drawing.Point 22, 84 -Property @{}; $y = 1 + 2' $false
    New-Case '$f = New-Object Foo "a+b", 1' $false
    # New with the AST: the @( ) argument list has the same comma problem, a method call does not (it splits its
    # arguments on the commas itself), the arithmetic spine can be longer than one operator, and the mistake outside a
    # New-Object argument list is legitimate array concatenation and stays out of scope.
    New-Case '$a = New-Object -TypeName System.Drawing.Point -ArgumentList @(22, 84 + $offset)' $true
    New-Case '$a = New-Object -TypeName System.Drawing.Point -ArgumentList @(22, (84 + $offset))' $false
    New-Case '$a = New-Object System.Drawing.Point(22, 84 + $offset + $extra)' $true
    New-Case '$a = New-Object System.Drawing.Point(22, 84 - $offset)' $true
    New-Case '$a = New-Object System.Drawing.Point(22, 84 * $offset)' $true
    New-Case '$a = New-Object Foo(@(1, 2) + $x)' $false
    New-Case '$a = [System.Drawing.Point]::new(22, 84 + $offset)' $false
    New-Case 'Write-Output (1 + 2)' $false
    New-Case 'Write-Output (1, 2 + $x)' $false
    New-Case '$s = @"\nNew-Object System.Drawing.Point(22, 84 + $offset)\n"@' $false
    New-Case '$s = @''\nNew-Object System.Drawing.Point(22, 84 + $offset)\n''@' $false
)

# A duplicate case would silently shrink the set instead of strengthening it, so the sets are checked for one.
foreach ($set in @(@('top-level', $Cases), @('in-function', $FunctionCases), @('constructor', $ArithmeticCases))) {
    foreach ($duplicate in @($set[1] | ForEach-Object { $_.Text } | Group-Object -CaseSensitive | Where-Object { $_.Count -gt 1 })) {
        $ok = $false; Write-Output ('  DUPLICATE {0} case: {1}' -f $set[0], $duplicate.Name)
    }
}
foreach ($case in $Cases) {
    $hit = @(Find-OverwrittenParameter ($Head + (Expand-Case $case.Text) + "`n")).Count -gt 0
    if ($hit -ne $case.Expect) { $ok = $false }
    Write-Output ('  top-level   {0} (expected {1}): {2}' -f $(if ($hit) { 'flagged' } else { 'clean  ' }), $(if ($case.Expect) { 'flagged' } else { 'clean' }), $case.Text)
}
foreach ($case in $FunctionCases) {
    $hit = @(Find-OverwrittenParameter ($Head + "function Test-Thing {`n    " + (Expand-Case $case.Text) + "`n}`n")).Count -gt 0
    if ($hit -ne $case.Expect) { $ok = $false }
    Write-Output ('  in-function {0} (expected {1}): {2}' -f $(if ($hit) { 'flagged' } else { 'clean  ' }), $(if ($case.Expect) { 'flagged' } else { 'clean' }), $case.Text)
}
foreach ($case in $ArithmeticCases) {
    $hit = @(Find-UnparenthesizedArithmetic ((Expand-Case $case.Text) + "`n")).Count -gt 0
    if ($hit -ne $case.Expect) { $ok = $false }
    Write-Output ('  constructor {0} (expected {1}): {2}' -f $(if ($hit) { 'flagged' } else { 'clean  ' }), $(if ($case.Expect) { 'flagged' } else { 'clean' }), $case.Text)
}

# -------------------- 4. a file that does not parse --------------------

# The parse step reports the syntax error; the guards read what the parser could build and report what they find there.
$broken = $Head + "if (`$c) {`n    `$script:Interactive = `$false`n"   # the block is never closed
$brokenErrors = @(Get-GuardParseError $broken).Count
$brokenHits = @(Find-OverwrittenParameter $broken)
Write-Output ('unparsed input: {0} parse error(s), parameter guard [{1}]' -f $brokenErrors, ($brokenHits -join ', '))
if ($brokenErrors -lt 1 -or $brokenHits.Count -lt 1) { $ok = $false; Write-Output '  MISMATCH: expected a parse error and the finding inside the unclosed block' }

Write-Output ('corpus: {0} top-level, {1} in-function, {2} constructor cases; anchors {3} en-US / zh-TW; guards on the PowerShell AST' -f $Cases.Count, $FunctionCases.Count, $ArithmeticCases.Count, $AnchorCommit)
Write-Output $(if ($ok) { 'ALL SELF-TESTS OK' } else { 'SELF-TEST FAILURE' })
exit $(if ($ok) { 0 } else { 1 })
