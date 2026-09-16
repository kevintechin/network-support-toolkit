param([string]$EnUsAnchor, [string]$ZhTwAnchor)
# Self-test of the AST guards in ast_guards.ps1 - the two from backlog #17 (until 2026-09-04 regular expressions in
# healthcheck/tools/validate_release.py, and this file selftest_guards.py) and the call guard from backlog #42.
# Four parts:
#   1. the v1.2.0 files must be flagged at the known lines - the top-level `$script:Interactive = $false` (line 77 in
#      en-US, 70 in zh-TW) and the six `New-Object System.Drawing.Point(22, 84 + $offset)` constructor lines;
#   2. the current shipped files must parse and come back clean, the call guard included: every command they call
#      is one of their own functions or one somebody vetted;
#   3. the corpus below - built up over the twenty-one Codex rounds of PR #4, one case per spelling a round proposed,
#      plus the shapes the AST rewrite made reachable, plus the call cases of #42 - must be classified exactly as
#      recorded;
#   4. the guards must survive a file that does not parse (the parse step's finding, not theirs).
# The anchors are read from git (commit f7c45a9, the merge of PR #3 = v1.2.0 as shipped) unless a file is passed in.
# They anchor the two guards they were built from: what v1.2.0 called is a question nobody asked at the time, and a
# number recorded here for it would be archaeology rather than a guard.
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
function Expand-Case([string]$Case) {
    # A case that carries a Windows path uses <nl>: the older marker is \n, and "System32\netsh.exe" has one of those
    # in it (PR #72 round 3). A case declares one marker or the other, never both.
    if ($Case.Contains('<nl>')) { return $Case.Replace('<bs>', '\').Replace('<nl>', "`n") }
    return $Case.Replace('\n', "`n")
}
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
    $calls = @(Find-UnvettedCall $text) + @(Find-UnvettedMember $text) + @(Find-UnvettedRedirection $text) +
        @(Find-UnvettedEnvironmentWrite $text)
    Write-Output ('current {0}: {1} parse error(s); parameter guard [{2}]; arithmetic guard [{3}]; call guard [{4}]' -f $language, $errors.Count, ($parameters -join ', '), ($arithmetic -join ', '), ($calls -join ', '))
    if ($errors.Count -or $parameters.Count -or $arithmetic.Count -or $calls.Count) { $ok = $false; Write-Output '  MISMATCH: the shipped file must parse and come back clean' }
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

# The call guard (backlog #42). $true = the guard must report it. Written at the top level of a script with no function
# definitions in it, so a name is vetted or it is not; the last case brings its own function to stand for the tool's own.
$CallCases = @(
    # Writers, by cmdlet: none of these is on the list, and that is the whole rule.
    New-Case 'Set-NetIPAddress -InterfaceAlias Wi-Fi -IPAddress 10.0.0.5' $true
    New-Case 'Set-ItemProperty -Path HKCU:\Software\X -Name Y -Value 1' $true
    New-Case 'Invoke-CimMethod -ClassName Win32_Process -MethodName Create' $true
    New-Case 'Set-Service -Name WlanSvc -StartupType Automatic' $true
    New-Case 'Remove-NetRoute -DestinationPrefix 0.0.0.0/0' $true
    # Writers, by another program: the name is not on the list at all.
    New-Case 'reg add HKCU\Software\X /v Y /d 1 /f' $true
    New-Case 'setx NHC 1' $true
    # A vetted program carrying a verb its entry does not allow.
    New-Case 'netsh int ip set address name="Wi-Fi" static 10.0.0.5' $true
    New-Case 'netsh advfirewall set allprofiles state off' $true
    New-Case 'arp -s 10.0.0.1 aa-bb-cc-dd-ee-ff' $true
    # The same through the resolved-path variable, which is how the tool really calls netsh.
    New-Case '& $netsh int ip set address name="Wi-Fi" dhcp' $true
    # An invocation through a variable nobody vetted.
    New-Case '& $other wlan show interfaces' $true
    New-Case '& (Get-Command netsh) wlan show interfaces' $true
    # Start-Process is vetted for two programs and for the report the run wrote; anything else is a finding.
    New-Case 'Start-Process -FilePath "cmd.exe" -ArgumentList "/c echo hi"' $true
    New-Case 'Start-Process -FilePath $somethingElse' $true
    New-Case 'Start-Process "notepad.exe"' $false
    New-Case 'Start-Process -FilePath "explorer.exe"' $false
    New-Case 'Start-Process -FilePath $target' $true
    # An alias is not the name: a call spelled sc is a finding until somebody says which sc it is.
    New-Case 'sc -Path out.txt -Value x' $true
    # And the reads, which are what the tool does. The two writers here name variables the tool does not
    # have: written when this guard vetted a writer by its name alone, they are findings under the
    # destination rule round 1 asked for, and they stay as two more spellings of it.
    New-Case 'netsh wlan show interfaces' $false
    New-Case '& $netsh winhttp show proxy' $true
    New-Case 'function Get-WifiAssociationSample { $netsh = Join-Path $env:SystemRoot "System32\netsh.exe"<nl>& $netsh wlan show interfaces }' $false
    New-Case 'arp -a' $false
    New-Case 'Get-NetAdapter -ErrorAction Stop' $false
    New-Case 'Get-CimInstance -ClassName Win32_NetworkAdapter' $false
    New-Case 'Set-Content -LiteralPath $path -Value $text' $true
    New-Case 'New-Item -ItemType Directory -Path $reports' $true
    New-Case 'Remove-Item -LiteralPath $probe -Force' $true
    New-Case 'function Get-Mine { 1 }\nGet-Mine' $false
    # Member invocations, which the first version of this guard did not look at at all (PR #72 round 1).
    New-Case '[Microsoft.Win32.Registry]::SetValue("HKCU\X", "Y", 1)' $true
    New-Case '(Get-CimInstance Win32_NetworkAdapter).Delete()' $true
    New-Case '$key.SetValue("a", 1)' $true
    New-Case '$adapter.Disable()' $true
    New-Case '[math]::Round(1.5, 1)' $false
    New-Case '$s.Trim()' $false
    New-Case '[System.IO.File]::WriteAllText($p, $t)' $true
    # Where a writer writes, which vetting it by name alone left open.
    New-Case 'New-Item -Path "HKCU:\Software\X" -ItemType Directory' $true
    New-Case 'New-Item -Path $somewhereElse -ItemType Directory' $true
    New-Case 'Remove-Item -LiteralPath $userFile -Force' $true
    New-Case 'Remove-Item -Recurse -Force' $true
    New-Case 'New-Item -ItemType Directory -Path $preferred' $true
    New-Case 'Remove-Item -LiteralPath $testFile -Force' $true
    # An argument the rule cannot read is an argument nobody vetted: netsh reads "int" as int.
    New-Case 'netsh "int" "ip" "set" "address"' $true
    New-Case '& $netsh $arguments' $true
    New-Case 'arp ''-s'' ''10.0.0.1''' $true
    # Round 2: a variable is vetted where it is written. The same call is clean in the function the tool writes it in
    # and a finding anywhere else - including at the top level, which is where the five above now stand.
    New-Case 'function Write-EnvironmentReport { Set-Content -LiteralPath $path -Value $t }' $true
    New-Case 'function Write-EnvironmentReport { $path = Join-Path $folder $name\nSet-Content -LiteralPath $path -Value $t }' $false
    New-Case 'function Other { Set-Content -LiteralPath $path -Value $t }' $true
    New-Case 'function Initialize-OutputDirectory { New-Item -ItemType Directory -Path $preferred }' $true
    # Flagged since round 7: each of these hands the destination a name, and the fragment never says where
    # that name's value comes from - so the chain has a link missing and cannot be vetted. The same three
    # shapes with the link written in are further down, and they are clean.
    New-Case 'function Initialize-OutputDirectory { $preferred = $folderName\nNew-Item -ItemType Directory -Path $preferred }' $true
    New-Case 'function Initialize-OutputDirectory { Remove-Item -LiteralPath $testFile -Force }' $true
    New-Case 'function Initialize-OutputDirectory { $testFile = Join-Path $preferred (".write_test_{0}.tmp" -f [guid]::NewGuid().ToString("N"))\nRemove-Item -LiteralPath $testFile -Force }' $false
    New-Case 'function Write-EmergencyReport { New-Item -ItemType Directory -Path $directory }' $true
    New-Case 'function Write-EmergencyReport { $directory = $script:OutputDirectory\nNew-Item -ItemType Directory -Path $directory }' $true
    New-Case 'function Initialize-Gui { Start-Process -FilePath $target }' $true
    New-Case 'function Initialize-Gui { $target = $candidate\nStart-Process -FilePath $target }' $true
    New-Case 'function Other { Start-Process -FilePath $target }' $true
    # The one static member that writes a file, with the same rule on the argument that holds the path.
    New-Case 'function Write-Utf8File { [System.IO.File]::WriteAllText($Path, $Content, $e) }' $false
    New-Case 'function Initialize-OutputDirectory { [System.IO.File]::WriteAllText($testFile, "test") }' $true
    New-Case 'function Initialize-OutputDirectory { $testFile = Join-Path $preferred (".write_test_{0}.tmp" -f [guid]::NewGuid().ToString("N"))\n[System.IO.File]::WriteAllText($testFile, "test") }' $false
    New-Case 'function Write-Utf8File { [System.IO.File]::WriteAllText("C:\Users\x.txt", $c) }' $true
    New-Case 'function Other { [System.IO.File]::WriteAllText($Path, $c) }' $true
    New-Case 'function Write-Utf8File { [System.IO.File]::WriteAllText() }' $true
    # And a module-qualified name is its own identity, not the basename's.
    New-Case 'UnreviewedModule\Get-Date' $true
    New-Case 'UnreviewedModule\Write-Utf8File' $true
    New-Case 'Microsoft.PowerShell.Utility\Get-Date' $true
    # Round 3: the value, not only the names. Every assignment to a vetted variable inside its function has to be one
    # the entry names, so the review's own example - the same clean call over a changed assignment - is a finding.
    New-Case 'function Write-EnvironmentReport { $path = "C:/Users/x.txt"\nSet-Content -LiteralPath $path -Value $t }' $true
    New-Case 'function Get-WifiAssociationSample { $netsh = "C:/Users/Public/unreviewed.exe"<nl>& $netsh wlan show interfaces }' $true
    New-Case 'function Invoke-CheckStep { param($Action)\n$Action = { bad }\n& $Action }' $true
    New-Case 'function Invoke-CheckStep { param($Action)\n& $Action }' $false
    # And an instance name that writes on some receiver is vetted where it is called, not by the name: .AppendText on
    # a FileInfo creates a file, and the tool calls it on the log box in Write-UiLog and nowhere else.
    New-Case 'function Other { $file = New-Object System.IO.FileInfo("C:/x.txt")\n$file.AppendText() }' $true
    New-Case 'function Write-UiLog { $box.AppendText($line) }' $true
    New-Case 'function Write-UiLog { $script:LogBox.AppendText($line) }' $false
    New-Case 'function Other { $box.ScrollToCaret() }' $true
    New-Case 'function Invoke-TcpConnectionTest { $socket.IOControl(3, $in, $out) }' $true
    New-Case 'function Invoke-TcpConnectionTest { $client.Client.IOControl(3, $in, $out) }' $false
    # Round 4: every spelling of a write to a vetted variable, and the receiver a writing name is called on.
    New-Case 'function Get-WifiAssociationSample { $netsh = Join-Path $env:SystemRoot "System32<bs>netsh.exe"<nl>$local:netsh = "x.exe"<nl>& $netsh wlan show interfaces }' $true
    New-Case 'function Get-WifiAssociationSample { $netsh = Join-Path $env:SystemRoot "System32<bs>netsh.exe"<nl>[string]$netsh = "x.exe"<nl>& $netsh wlan show interfaces }' $true
    New-Case 'function Get-WifiAssociationSample { $netsh = Join-Path $env:SystemRoot "System32<bs>netsh.exe"<nl>Set-Variable -Name netsh -Value "x.exe"<nl>& $netsh wlan show interfaces }' $true
    New-Case 'function Get-WifiAssociationSample { $netsh = Join-Path $env:SystemRoot "System32<bs>netsh.exe"<nl>foreach ($netsh in $list) { }<nl>& $netsh wlan show interfaces }' $true
    New-Case 'function Write-UiLog { $file = New-Object System.IO.FileInfo("C:/x.txt")<nl>$file.AppendText() }' $true
    New-Case 'function Invoke-TcpConnectionTest { $other.Close() }' $true
    # Round 5: a constructor is a call with a body, an approved assignment has to be the one that can reach the call,
    # and a function defined inside another one is not there at the top level.
    New-Case 'New-Object -TypeName System.IO.FileStream -ArgumentList "C:/Users/Public/x", ([System.IO.FileMode]::Create)' $true
    New-Case 'New-Object -TypeName $typeName' $true
    New-Case 'New-Object System.Collections.ArrayList' $false
    New-Case 'New-Object System.Windows.Forms.Timer' $false
    New-Case '$netsh = "C:/Users/Public/evil.exe"<nl>function Get-WifiAssociationSample { if ($false) { $netsh = Join-Path $env:SystemRoot "System32<bs>netsh.exe" }<nl>& $netsh wlan show interfaces }' $true
    New-Case 'function Other { $script:netsh = "evil.exe" }<nl>function Get-WifiAssociationSample { $netsh = Join-Path $env:SystemRoot "System32<bs>netsh.exe"<nl>& $netsh wlan show interfaces }' $true
    New-Case 'function Outer { function Remove-Item { } }\nRemove-Item -LiteralPath "C:/Users/Public/x"' $true
    New-Case 'function Outer { function Remove-Item { }\nRemove-Item -LiteralPath "C:/Users/Public/x" }' $false
    # Round 6: a loop writes the scope it names, a constructor's arguments choose the overload, a redirection
    # writes a file with no command to read, and a definition counts only where it has already run.
    New-Case 'function Other { foreach ($script:netsh in $list) { } }<nl>function Get-WifiAssociationSample { $netsh = Join-Path $env:SystemRoot "System32<bs>netsh.exe"<nl>& $netsh wlan show interfaces }' $true
    New-Case 'foreach ($script:netsh in $list) { }<nl>function Get-WifiAssociationSample { $netsh = Join-Path $env:SystemRoot "System32<bs>netsh.exe"<nl>& $netsh wlan show interfaces }' $true
    New-Case 'function Other { foreach ($netsh in $list) { } }<nl>function Get-WifiAssociationSample { $netsh = Join-Path $env:SystemRoot "System32<bs>netsh.exe"<nl>& $netsh wlan show interfaces }' $false
    New-Case 'New-Object -TypeName System.Net.Sockets.TcpClient -ArgumentList "host.example", 25' $true
    New-Case 'New-Object System.Net.Sockets.TcpClient' $false
    New-Case 'New-Object System.Drawing.Point(22, 84)' $false
    New-Case 'New-Object System.Drawing.Font("Consolas", 9.5, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Point)' $true
    New-Case 'Get-Date > C:/Users/Public/x' $true
    New-Case 'Get-Date >> C:/Users/Public/x' $true
    New-Case '& netsh wlan show interfaces 2>&1' $false
    New-Case 'Remove-Item -LiteralPath "C:/Users/Public/x"\nfunction Remove-Item { }' $true
    New-Case 'if ($true) { function Remove-Item { } }\nRemove-Item -LiteralPath "C:/Users/Public/x"' $true
    New-Case 'function Remove-Item { }\nRemove-Item -LiteralPath "C:/Users/Public/x"' $false
    New-Case 'function A { B }\nfunction B { 1 }' $false
    # Round 6, and a self-audit rather than a review finding: Add-Type compiles and loads code into this process,
    # which is a wider reach than any file this tool writes, and it was vetted by a name with nothing behind it. A
    # dot-source is the same question about the operator - it runs the thing in the caller's scope.
    # Flagged since round 7: the site and the kind were enough for round 6, and the contents are what count. The
    # block the tool really declares is in the shipped files, which part 2 reads, and its digest is the entry.
    New-Case 'function Get-WlanApiType { $definition = @''<nl>[DllImport("wlanapi.dll")] public static extern uint WlanOpenHandle(uint v);<nl>''@<nl>Add-Type -Namespace NetworkHealthCheck -Name WlanApi -MemberDefinition $definition -ErrorAction Stop }' $true
    New-Case 'function Get-WlanApiType { $definition = $env:SRC<nl>Add-Type -Namespace X -Name Y -MemberDefinition $definition }' $true
    New-Case 'function Get-WlanApiType { $definition = "$($env:SRC)"<nl>Add-Type -Namespace X -Name Y -MemberDefinition $definition }' $true
    New-Case 'function Other { $definition = @''<nl>[DllImport("wlanapi.dll")] public static extern uint WlanOpenHandle(uint v);<nl>''@<nl>Add-Type -MemberDefinition $definition }' $true
    New-Case 'Add-Type -TypeDefinition $source' $true
    New-Case 'Add-Type -Path "C:/Users/Public/evil.dll"' $true
    New-Case 'Add-Type -AssemblyName System.Management.Automation' $true
    New-Case 'Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop' $false
    New-Case 'Add-Type -AssemblyName System.Drawing -ErrorAction Stop' $false
    New-Case 'Add-Type' $true
    New-Case 'function Get-WifiAssociationSample { $netsh = Join-Path $env:SystemRoot "System32<bs>netsh.exe"<nl>. $netsh wlan show interfaces }' $true
    New-Case '. Get-Date' $true
    New-Case '. "C:/Users/Public/evil.ps1"' $true
    # Round 7: what can reach a body decides what that body can see, a literal is not its contents, and a vetted
    # expression that is a name is a question about that name.
    New-Case 'function Invoke-Early { Remove-Item -LiteralPath "C:/Users/Public/x" }\nInvoke-Early\nfunction Remove-Item { }' $true
    New-Case 'function Invoke-Late { Remove-Item -LiteralPath "C:/Users/Public/x" }\nfunction Remove-Item { }\nInvoke-Late' $false
    New-Case 'function Outer { Invoke-Early }\nfunction Invoke-Early { Remove-Item -LiteralPath "C:/Users/Public/x" }\nOuter\nfunction Remove-Item { }' $true
    New-Case 'function A { B }\nfunction B { 1 }\nA' $false
    New-Case 'function Get-WlanApiType { $definition = @''<nl>[DllImport("kernel32.dll")] public static extern void Sleep(uint ms);<nl>''@<nl>Add-Type -Namespace NetworkHealthCheck -Name WlanApi -MemberDefinition $definition -ErrorAction Stop }' $true
    New-Case 'function Initialize-Gui { $target = $null<nl>foreach ($candidate in @($script:LastHtmlReport, $script:LastTextReport, $script:LastJsonReport)) { $target = $candidate }<nl>Start-Process -FilePath $target }' $false
    New-Case 'function Initialize-Gui { $target = $null<nl>$candidate = "C:/Users/Public/evil.exe"<nl>foreach ($candidate in @($script:LastHtmlReport, $script:LastTextReport, $script:LastJsonReport)) { $target = $candidate }<nl>Start-Process -FilePath $target }' $true
    New-Case 'function ConvertTo-SafeString { }<nl>function Initialize-OutputDirectory { $folderName = ConvertTo-SafeString $script:Config.ReportFolderName<nl>if ([System.IO.Path]::IsPathRooted($folderName)) { $preferred = $folderName }<nl>else { $preferred = Join-Path $script:BaseDirectory $folderName }<nl>New-Item -ItemType Directory -Path $preferred }' $false
    New-Case 'function ConvertTo-SafeString { }<nl>function Initialize-OutputDirectory { $folderName = "C:/Users/Public/evil"<nl>if ([System.IO.Path]::IsPathRooted($folderName)) { $preferred = $folderName }<nl>else { $preferred = Join-Path $script:BaseDirectory $folderName }<nl>New-Item -ItemType Directory -Path $preferred }' $true
    New-Case 'function Write-EmergencyReport { $directory = $script:OutputDirectory<nl>New-Item -ItemType Directory -Path $directory }<nl>function Initialize-OutputDirectory { $fallback = Join-Path ([System.IO.Path]::GetTempPath()) "NetworkHealthCheck<bs>Reports"<nl>$script:OutputDirectory = $fallback }' $false
    New-Case 'function Write-EmergencyReport { $directory = $script:OutputDirectory<nl>New-Item -ItemType Directory -Path $directory }<nl>function Other { $script:OutputDirectory = "C:/Users/Public/evil" }' $true
    # Round 8: a definition inside a script block literal has not run - and the self-audit beside it, that nothing
    # here may write an environment variable, which is what the vetted $netsh reads its folder from.
    New-Case '$unused = { function Remove-Item { } }\nRemove-Item -LiteralPath "C:/Users/Public/x"' $true
    New-Case '& { function Remove-Item { }\nRemove-Item -LiteralPath "C:/Users/Public/x" }' $true
    New-Case 'function Write-UiLog { $script:LogBox.AppendText($line) }\nfunction Initialize-Gui { $b.Add_Click({ Write-UiLog }) }' $false
    New-Case '$env:SystemRoot = "C:/Users/Public"' $true
    New-Case 'function Get-WifiAssociationSample { $env:SystemRoot = "C:/Users/Public"<nl>$netsh = Join-Path $env:SystemRoot "System32<bs>netsh.exe"<nl>& $netsh wlan show interfaces }' $true
    New-Case '$env:Path += ";C:/Users/Public"' $true
    # Round 9: a definition inside the body it is called from runs when the body reaches it, and a loop target is a
    # write - including the environment's. The last four ran over the same surface from the other directions.
    New-Case 'function Outer { Remove-Item -LiteralPath "C:/Users/Public/x"\nfunction Remove-Item { } }\nOuter' $true
    New-Case 'function Outer { function Remove-Item { }\nRemove-Item -LiteralPath "C:/Users/Public/x" }\nOuter' $false
    # Clean since round 10, and the reachability rule is why: nothing calls Outer, so that body never runs and
    # the call in it never happens. The same shape with Outer called stands above it, and is a finding.
    New-Case 'function Outer { Remove-Item -LiteralPath "C:/Users/Public/x"\nfunction Remove-Item { } }' $false
    New-Case 'function Outer { Remove-Item -LiteralPath "C:/Users/Public/x" }\nfunction Remove-Item { }\nOuter' $false
    New-Case 'foreach ($env:SystemRoot in "C:/Users/Public") { }' $true
    New-Case 'function Get-WifiAssociationSample { foreach ($env:SystemRoot in "C:/Users/Public") { }<nl>$netsh = Join-Path $env:SystemRoot "System32<bs>netsh.exe"<nl>& $netsh wlan show interfaces }' $true
    New-Case 'foreach ($folder in @($env:TEMP)) { $x = $folder }' $false
    New-Case 'Set-Variable -Name env:SystemRoot -Value "C:/Users/Public"' $true
    New-Case 'Remove-Item -LiteralPath Env:\SystemRoot' $true
    New-Case 'New-Item -Path Env:\SystemRoot -Value "C:/Users/Public"' $true
    New-Case '${env:SystemRoot} = "C:/Users/Public"' $true
    # Round 10: the body a definition stands in decides when it has run, however many scopes down the call is. The
    # fourth of these is refused conservatively - Outer really does define both before anything calls Middle, and
    # working out that nothing else got there first is the flow analysis this guard does not do.
    New-Case 'function Outer { function Middle { Remove-Item -LiteralPath "C:/Users/Public/x" }\nMiddle\nfunction Remove-Item { } }\nOuter' $true
    New-Case 'function Outer { function Middle { Remove-Item -LiteralPath "C:/Users/Public/x" }\nfunction Remove-Item { }\nMiddle }\nOuter' $false
    New-Case 'function Outer { function Middle { Inner }\nfunction Inner { Remove-Item -LiteralPath "C:/Users/Public/x" }\nMiddle\nfunction Remove-Item { } }\nOuter' $true
    New-Case 'function Outer { function Middle { Remove-Item -LiteralPath "C:/Users/Public/x" }\nfunction Remove-Item { } }\nOuter\nMiddle' $true
    New-Case 'function Remove-Item { }\nfunction Outer { function Middle { Remove-Item -LiteralPath "C:/Users/Public/x" }\nMiddle }\nOuter' $false
    New-Case 'function Outer { Remove-Item -LiteralPath "C:/Users/Public/x" }\nfunction Remove-Item { }' $false
)

# A duplicate case would silently shrink the set instead of strengthening it, so the sets are checked for one.
foreach ($set in @(@('top-level', $Cases), @('in-function', $FunctionCases), @('constructor', $ArithmeticCases), @('call', $CallCases))) {
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
foreach ($case in $CallCases) {
    # All four guards: a command, a member invocation, a redirection and a write to the environment are four
    # shapes of the one question - is this reach for the machine vetted (PR #72 rounds 6 and 8).
    $text = (Expand-Case $case.Text) + "`n"
    $hit = (@(Find-UnvettedCall $text).Count + @(Find-UnvettedMember $text).Count +
        @(Find-UnvettedRedirection $text).Count + @(Find-UnvettedEnvironmentWrite $text).Count) -gt 0
    if ($hit -ne $case.Expect) { $ok = $false }
    Write-Output ('  call        {0} (expected {1}): {2}' -f $(if ($hit) { 'flagged' } else { 'clean  ' }), $(if ($case.Expect) { 'flagged' } else { 'clean' }), $case.Text)
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

Write-Output ('corpus: {0} top-level, {1} in-function, {2} constructor, {3} call cases; anchors {4} en-US / zh-TW; guards on the PowerShell AST' -f $Cases.Count, $FunctionCases.Count, $ArithmeticCases.Count, $CallCases.Count, $AnchorCommit)
Write-Output $(if ($ok) { 'ALL SELF-TESTS OK' } else { 'SELF-TEST FAILURE' })
exit $(if ($ok) { 0 } else { 1 })
