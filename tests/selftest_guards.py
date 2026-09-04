"""Self-test of the two PowerShell guards in healthcheck/tools/validate_release.py: unparenthesized_arithmetic (arithmetic
inside a New-Object argument list - the v1.2.0 constructor mistake that sent both entry points to console mode) and
overwritten_parameters (a bound parameter overwritten at script scope - the v1.2.0 mistake that opened the user layout
from the IT launcher). Three parts: the v1.2.0 files must be flagged at the known lines, the current files must be clean,
and the synthetic corpus below - built up over the PR #4 review rounds - must be classified as recorded. Backlog #17 keeps
this corpus as the acceptance set for the AST rewrite of the guards.

Usage (from anywhere):  python tests/selftest_guards.py [<v1.2.0 en-US .ps1> <v1.2.0 zh-TW .ps1>]
Without arguments the v1.2.0 anchors are read from git history: commit f7c45a9, the merge of PR #3 (v1.2.0 as shipped)."""
import pathlib, re, subprocess, sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
ANCHOR_COMMIT = 'f7c45a9'
# What the guards must report on the v1.2.0 files: the top-level `$script:Interactive = $false` (line 77 / 70) and the six
# `New-Object System.Drawing.Point(22, 84 + $offset)`-style constructor lines.
ANCHORS = {
    'en-US': (['77 ($Interactive)'], [3756, 3764, 3770, 3779, 3784, 3834]),
    'zh-TW': (['70 ($Interactive)'], [3749, 3757, 3763, 3772, 3777, 3827]),
}

# The validator runs its checks at import time, so the guard functions and the helpers they use are lifted out by source.
src = (ROOT / 'healthcheck' / 'tools' / 'validate_release.py').read_text(encoding='utf-8')
ns = {'re': re}
for name in ('strip_block_comments', 'strip_line_comment', 'abbr', 'logical_lines', 'unparenthesized_arithmetic', 'overwritten_parameters'):
    m = re.search(r'def ' + name + r'\(.*?\):.*?\n(?=def |for rel|# )', src, re.S)
    exec(m.group(0), ns)
g = ns['overwritten_parameters']; a = ns['unparenthesized_arithmetic']; sc = ns['strip_line_comment']
ok = True

def anchor_text(lang, index):
    if len(sys.argv) > 1 + index:
        return pathlib.Path(sys.argv[1 + index]).read_text(encoding='utf-8-sig')
    out = subprocess.run(['git', '-C', str(ROOT), 'show', f'{ANCHOR_COMMIT}:healthcheck/{lang}/NetworkHealthCheck.ps1'], capture_output=True, check=True)
    return out.stdout.decode('utf-8-sig')

for i, lang in enumerate(('en-US', 'zh-TW')):
    t = anchor_text(lang, i)
    ph, ah = g(t), a(t)
    print(f'v1.2.0 {lang} ({ANCHOR_COMMIT}): param guard', ph, '; arithmetic guard', ah)
    ok &= (ph, ah) == ANCHORS[lang]
for lang in ('en-US', 'zh-TW'):
    cur = (ROOT / 'healthcheck' / lang / 'NetworkHealthCheck.ps1').read_text(encoding='utf-8-sig')
    print(f'current {lang}: param guard', g(cur), '; arithmetic guard', a(cur))
    ok &= not g(cur) and not a(cur)
head = (ROOT / 'healthcheck' / 'en-US' / 'NetworkHealthCheck.ps1').read_text(encoding='utf-8-sig').split('\n)', 1)[0] + '\n)\n'
cases = {
    '$script:Interactive = $false # $Interactive': True,
    '$script:Interactive = $InteractiveBackup': True,
    '$script:Interactive = [bool]$Interactive': False,
    '$script:Interactive = ${Interactive}': False,
    '$script:Interactive = $Interactive.IsPresent': False,
    '$script:ConfigPath = "$ConfigPath"': True,
    "$script:ConfigPath = 'literal # $ConfigPath'": True,
    '    $script:PingCount = 4': True,
    '$script:Interactive=$false': True,
    '$script:Interactive = $false <# $Interactive #>': True,
    '$script:ConfigPath = "it\'s $ConfigPath"': True,
    "$script:ConfigPath = 'a' + $ConfigPath": True,
    "$script:ConfigPath = 'it''s' + $ConfigPath": True,
    '$script:interactive = $false': True,
    '$Script:Interactive = [bool]$interactive': False,
    '${script:Interactive} = $false': True,
    '${script:Interactive} = ${Interactive}': False,
    '$global:Interactive = $false': True,
    '$Interactive = $false': True,
    '$interactive = [bool]$Interactive': False,
    '$local:Interactive = $false': True,
    '$ConfigPath = $ConfigPath.Trim()': True,
    '$entryPoint = "User"': False,
    'Set-Variable -Scope Script -Name Interactive -Value $false': True,
    'Set-Variable -Name Interactive -Scope Global -Value ([bool]$Interactive)': True,
    'Set-Variable -Name Interactive -Value $false': True,
    'New-Variable -Name Interactive -Value 1 -Force': True,
    'Set-Variable Interactive $false': True,
    'Set-Variable -Scope Script -Name Other -Value 1': False,
    'Set-Variable -Scope Local -Name Interactive -Value $false': True,
    '[bool]$script:Interactive = $false': True,
    '[bool] $script:Interactive = $false': True,
    '[bool]$script:Interactive = [bool]$Interactive': False,
    '[ValidateNotNull()][bool]$script:Interactive = $false': True,
    '[string[]]$PingTarget = @()': True,
    '[string[]]$PingTarget = @($PingTarget)': False,
    '[int]$Interactive = 1': True,
    '<# comment\n#> $script:Interactive = $false': True,
    '<#\n$script:Interactive = $false\n#>': False,
    '<# a #> $script:Interactive = $false': True,
    '$x = 1 <# start\n$script:Interactive = $false # inside\nend #>\n$script:Interactive = [bool]$Interactive': False,
    'if ($c) { $script:Interactive = $false }': True,
    'if ($c) { $Interactive = $false }': True,
    '$a = 1; $script:Interactive = $false': True,
    'try { $script:Interactive = [bool]$Interactive } catch { }': False,
    'if ($c) { ${script:Interactive} = $false }': True,
    'foreach ($i in 1..3) { $script:PingCount = $i }': True,
    '$h = @{ Interactive = $false }': False,
    '$h[$script:Interactive] = 1': False,
    '$script:Interactive.Value = $false': False,
    'function F { $Interactive = $false }': False,
    'function F { $Interactive = $false }\n$Interactive = $false': True,
    'function F {\n    $Interactive = $false\n}\n$script:Interactive = [bool]$Interactive': False,
    '$script:Interactive `\n    = $false': True,
    '$script:Interactive `\n    = [bool]$Interactive': False,
    '$script:Interactive = `\n    $false': True,
    '$x = 1 `\n    ; $script:Interactive = $false': True,
    '$script:Interactive = $Interactive -and $false': True,
    '$script:Interactive = -not $Interactive': True,
    '$script:Interactive = ($Interactive)': False,
    '$script:Interactive = [bool]($Interactive)': False,
    '$script:Interactive = ([bool]$Interactive)': False,
    '$script:Interactive = [bool]$Interactive.IsPresent': False,
    '$script:Interactive = $Interactive, $true': True,
    '$script:Interactive = if ($x) { $Interactive } else { $false }': True,
    '$script:PingCount = $PingCount + 1': True,
    '$script:PingCount = [int]$PingCount': False,
    'function Reset-Interactive { $script:Interactive = $false }': True,
    'function F { $script:Interactive = [bool]$Interactive }': False,
    'function F { Set-Variable -Scope Script -Name Interactive -Value $false }': True,
    'function F { Set-Variable -Name Interactive -Value $false }': False,
    'function F { $global:Interactive = $false }': True,
    'function F { $Interactive = $false }\n$script:Interactive = $false': True,
    '$script:PingCount += 1': True,
    '$script:PingCount -= 1': True,
    '$script:PingCount++': True,
    '++$script:PingCount': True,
    '$script:PingCount--': True,
    '$PingCount += 1': True,
    'if ($c) { $script:PingCount++ }': True,
    '$script:PingCount -eq 1': False,
    '$x = $script:PingCount - 1': False,
    '$total = $PingCount + 1': False,
    '$script:PingCount | Out-Null': False,
    '--$PingCount': True,
    'if ($c) { ++$script:PingCount }': True,
    '$a = "<#"\n$script:Interactive = $false\n$b = "#>"': True,
    "$a = '<#'\n$script:Interactive = $false\n$b = '#>'": True,
    '$s = "say ""<#"" now"\n$script:Interactive = $false': True,
    '# see <# below\n$script:Interactive = $false': True,
    '$s = "it`"s <#"\n$script:Interactive = $false': True,
    '<# real\n$script:Interactive = $false\n#>': False,
    'Write-Output `#; $script:Interactive = $false': True,
    'Write-Output `# not a comment; $script:Interactive = $false': True,
    'Write-Output `#; $script:Interactive = [bool]$Interactive': False,
    'Write-Output x # `# still a comment; $script:Interactive = $false': False,
    '$a = "<#"; $script:Interactive = $false; $b = "#>"': True,
    'Set-Variable -Na Interactive -Value $false': True,
    'Set-Variable -N Interactive -Va $false': True,
    'Set-Variable -Na Other -Value 1': False,
    'Set-Variable -Name Interactive -Sc Script -Value $false': True,
    'sv Interactive $false': True,
    'nv Interactive 1': True,
    'sv -Name Interactive -Value $false': True,
    'sv Other 1': False,
    '$nv = 1': False,
    '$sv = $Interactive': False,
    "Set-Variable -Name 'Interactive' -Value $false": True,
    "sv 'Interactive' $false": True,
    'Set-Variable -Name "Interactive" -Value $false': True,
    "Set-Variable -Name 'Other' -Value 1": False,
    "Write-Output 'sv Interactive'": False,
    'Write-Output "sv Interactive $false"': False,
    'Write-Output "x; $script:Interactive = $false"': False,
    'Write-Output "sv Other"; sv \'Interactive\' $false': True,
    '($script:Interactive = $false)': True,
    '($script:Interactive = [bool]$Interactive)': False,
    'for ($script:PingCount = 0; $script:PingCount -lt 3; $script:PingCount++) { }': True,
    'Set-Variable -Name Tmp -Value 1; Set-Variable -Name Interactive -Value $false': True,
    'sv Tmp 1; sv Interactive $false': True,
    'Set-Variable -Name Tmp -Value 1; Set-Variable -Name Other -Value 2': False,
    'sv Tmp 1; $x = 2': False,
    'Set-Variable -Name PingCount -Scope 0 -Value 1': True,
    'Set-Item -Path Variable:Interactive -Value $false': True,
    'Set-Item Variable:Interactive $false': True,
    "Set-Content -Path 'Variable:Interactive' -Value $false": True,
    'si Variable:Interactive $false': True,
    'Remove-Item Variable:Interactive': True,
    'Clear-Item -LiteralPath Variable:PingCount': True,
    'Set-Item -Path Variable:Other -Value 1': False,
    'Set-Item -Path HKCU:\\Software\\Test -Value 1': False,
    'Get-Item Variable:Interactive': False,
    'Write-Output "Set-Item Variable:Interactive"': False,
}
fcases = {
    '$script:Interactive = $false': True,
    '$Interactive = $false': False,
    '$local:Interactive = $false': False,
    'Set-Variable -Name Interactive -Value $false': False,
    'Set-Variable -Scope Script -Name Interactive -Value $false': True,
    'Set-Variable -Scope 1 -Name Interactive -Value $false': True,
    'Set-Variable -Scope Local -Name Interactive -Value $false': False,
    '[int]$Interactive = 1': False,
    '[bool]$script:Interactive = $false': True,
    'if ($c) { $Interactive = $false }': False,
    'if ($c) { $script:Interactive = $false }': True,
    '$a = 1; $script:Interactive = $false': True,
    '$Interactive `\n    = $false': False,
    '$PingCount += 1': False,
    '$script:PingCount++': True,
    'Set-Variable -N Interactive -Sc Script -Value $false': True,
    'Set-Variable -N Interactive -Value $false': False,
    'sv -Scope Script -Name Interactive -Value $false': True,
    'sv Interactive $false': False,
    "sv -Scope 'Script' -Name Interactive -Value $false": True,
    "sv 'Interactive' $false": False,
    'sv Tmp 1; sv -Scope Script -Name Interactive -Value $false': True,
    'sv Tmp 1; sv Interactive $false': False,
    'Set-Variable -Name PingCount -Scope 0 -Value 1': False,
    'Set-Variable -Name PingCount -Scope 1 -Value 1': True,
    'Set-Item -Path Variable:Interactive -Value $false': False,
}
for line, expect in cases.items():
    hit = bool(g(head + line + '\n')); ok &= (hit == expect)
    print(f'  top-level {"flagged" if hit else "clean  "} (expected {"flagged" if expect else "clean"}): {line}')
for line, expect in fcases.items():
    hit = bool(g(head + 'function Test-Thing {\n    ' + line + '\n}\n')); ok &= (hit == expect)
    print(f'  in-function {"flagged" if hit else "clean  "} (expected {"flagged" if expect else "clean"}): {line}')
acases = {
    '$a.Location = New-Object System.Drawing.Point(22, 84 + $offset)': True,
    '$a.Location = New-Object System.Drawing.Point(22, (84 + $offset))': False,
    '$a.Location = New-Object System.Drawing.Point(22, 84) # x + y': False,
    '$a.Location = New-Object System.Drawing.Point(22, 84 + $offset) # note': True,
    '$s = New-Object System.Drawing.Size(940, $formHeight)': False,
    '$a = New-Object System.Drawing.Point(-5, 3)': False,
    '$f = New-Object System.Drawing.Font($form.Font.FontFamily, 18, [System.Drawing.FontStyle]::Bold)': False,
    'new-object System.Drawing.Point(22, 84 + $offset)': True,
    'NEW-OBJECT System.Drawing.Size(900, 700 + $offset)': True,
    '$a.Location = New-Object -TypeName System.Drawing.Point -ArgumentList (22, 84 + $offset)': True,
    '$a.Location = New-Object -TypeName System.Drawing.Point -ArgumentList (22, (84 + $offset))': False,
    '$a = New-Object System.Drawing.Point(22, 84); $y = (3 + 4)': False,
    '$o = New-Object PSObject -Property @{ A = 1 }': False,
    '$s = New-Object System.Drawing.Size(780, [math]::Min(560 + $offset, $formHeight))': False,
    '$a.Location = New-Object System.Drawing.Point(22, $bottomY + 44); $b = 1': True,
    '$a.Location = New-Object System.Drawing.Point(22,\n    84 + $offset)': True,
    '$a.Location = New-Object System.Drawing.Point(22,\n    (84 + $offset))': False,
    '$a = New-Object -TypeName System.Drawing.Point `\n    -ArgumentList (22, 84 + $offset)': True,
    '$f = New-Object Foo("a+b", 1)': False,
    "$f = New-Object Foo('x-y', 1)": False,
    '<#\nNew-Object System.Drawing.Point(22, 84 + $offset)\n#>': False,
    '$a = New-Object System.Drawing.Point(22, 84) <# x + y\n#> $b = 1': False,
    '$a = New-Object -TypeName System.Drawing.Point -ArgumentList 22, 84 + $offset': True,
    '$a = New-Object -TypeName System.Drawing.Point -ArgumentList 22, (84 + $offset)': False,
    '$a = New-Object -TypeName System.Drawing.Point -ArgumentList 22, 84 -Property @{}': False,
    '$a = New-Object -TypeName Foo -ArgumentList 22, -5': False,
    '$a = New-Object -TypeName System.Drawing.Point `\n    -ArgumentList 22, 84 + $offset': True,
    '$a = New-Object -TypeName System.Drawing.Point `\n    -ArgumentList (22, 84 + $offset)': True,
    '$a = New-Object -TypeName Foo -ArgumentList "a+b", 1': False,
    '$a = New-Object -TypeName Foo -ArgumentList 1, 2; $b = 3 + 4': False,
    '$a = New-Object System.Drawing.Point(22, 84 % $offset)': True,
    '$a = New-Object System.Drawing.Point(22, (84 % $offset))': False,
    '$a = New-Object Foo("50%", 1)': False,
    '$a = "<#"\nNew-Object System.Drawing.Point(22, 84 + $offset)\n$b = "#>"': True,
    'Write-Output `#; New-Object System.Drawing.Point(22, 84 + $offset)': True,
    '$a = New-Object -Type System.Drawing.Point(22, 84 + $offset)': True,
    '$a = New-Object -T System.Drawing.Point -Arg (22, 84 + $offset)': True,
    '$a = New-Object -TypeName System.Drawing.Point -A 22, 84 + $offset': True,
    '$a = New-Object -Type System.Drawing.Point(22, (84 + $offset))': False,
    '$a = New-Object -T System.Drawing.Point -Arg (22, 84)': False,
    '$a = New-Object System.Drawing.Point 22, 84 + $offset': True,
    '$a = New-Object -Type System.Drawing.Point 22, 84 + $offset': True,
    '$a = New-Object System.Drawing.Point 22, (84 + $offset)': False,
    '$a = New-Object System.Drawing.Point 22, 84': False,
    '$l = New-Object System.Collections.ArrayList\n$x = 1 + 2': False,
    '$a = New-Object System.Drawing.Point 22, 84 -Property @{}; $y = 1 + 2': False,
    '$f = New-Object Foo "a+b", 1': False,
}
for line, expect in acases.items():
    hit = bool(a(line + '\n')); ok &= (hit == expect)
    print(f'  {"flagged" if hit else "clean  "} (expected {"flagged" if expect else "clean"}): {line!r}')
s1 = sc('$x = "a#b" + \'c#d\' # tail'); s2 = sc(ns['strip_block_comments']('<# block #> $y = 1 # z')); s3 = sc("$z = 'it''s' # c"); s4 = sc('a `# b # c'); ok &= s4 == 'a `# b '
ll = ns['logical_lines']; jl = ll('a `\n  b\nc `\n d `\n e'); ok &= jl == [(1, 'a  b'), (3, 'c  d  e')]; print('logical lines:', jl)
bc = ns['strip_block_comments']; ln = bc('a <# x\ny #> b\nc'); ok &= ln == 'a \n b\nc'; print('block stripper keeps line count:', repr(ln))
qs = bc('a "<#" b <# c\n d #> e # f <# g\nh'); ok &= qs == 'a "<#" b \n e # f <# g\nh'; print('block stripper honours quotes and line comments:', repr(qs))
print('comment stripper:', repr(s1), '|', repr(s2), '|', repr(s3))
ok &= s1 == '$x = "a#b" + \'c#d\' ' and s2 == ' $y = 1 ' and s3 == "$z = 'it''s' "
print(f'corpus: {len(cases)} top-level, {len(fcases)} in-function, {len(acases)} constructor cases; anchors {ANCHOR_COMMIT} en-US / zh-TW; helpers checked')
print('ALL SELF-TESTS OK' if ok else 'SELF-TEST FAILURE')
sys.exit(0 if ok else 1)
