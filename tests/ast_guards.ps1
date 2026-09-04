using namespace System.Management.Automation.Language
param([string[]]$Path)
# The two guards that keep the v1.2.0 GUI regressions out of the shipped scripts, on the PowerShell AST (backlog #17).
# Until 2026-09-04 they were regular expressions over the comment-free logical lines of the file in
# healthcheck/tools/validate_release.py; nineteen review rounds each added another spelling to catch, which is what the
# parser does for free. tests/selftest_guards.ps1 is the acceptance set: the v1.2.0 files must be flagged at the known
# lines, the current files must be clean, and the corpus built up over those rounds must be classified as recorded.
#
#   Find-UnparenthesizedArithmetic - arithmetic at the top level of a New-Object argument list. The comma binds tighter
#     than every arithmetic operator, so `New-Object System.Drawing.Point(22, 84 + $offset)` is really
#     `Point(@(22, 84) + $offset)`: one three-element argument, the runtime's "argument count 3", and in v1.2.0 an
#     Initialize-Gui that threw and sent both entry points to console mode. Two spellings, two signatures: a
#     parenthesized argument list (or an @( ) one) whose top-level expression is an arithmetic BinaryExpressionAst over
#     the ArrayLiteralAst the commas built, and an unparenthesized `-ArgumentList 22, 84 + $offset`, where the comma
#     ends the array and `+` and `$offset` reach New-Object as positional arguments it cannot bind.
#   Find-OverwrittenParameter - a bound parameter overwritten by a write that reaches the script scope, where the
#     parameter itself lives: a script's top-level scope and its $script: scope are the same variable table, so the
#     v1.2.0 `$script:Interactive = $false` overwrote -Interactive and the IT launcher opened the user layout. An
#     explicit $script: / $global: write counts anywhere, an unqualified / $local: / $private: one only outside a
#     function, and the only accepted initializer is the parameter's own value ($Interactive, [bool]$Interactive,
#     @($PingTarget), $Interactive.IsPresent): a transformed value belongs in a variable of its own. Assignments
#     (including compound and multiple ones), ++ / --, a foreach loop variable, the variable cmdlets and the item
#     cmdlets on the Variable: drive all write the same table and are all read here.
#
# Out of scope by design, in both guards: code the parser cannot see through - Invoke-Expression, a command name or a
# variable path built at runtime, splatting, a scope passed as a variable to a variable cmdlet (that one is flagged
# rather than trusted). A script block passed to a command (& { }, ForEach-Object { }) is treated as its enclosing
# scope: ForEach-Object really does write the caller's variables, and for the rest flagging is a guard's safe direction.
#
# Usage:  tests\ast_guards.ps1 -Path <file.ps1> [<file.ps1> ...]     one line per finding; exit code = findings
#         . tests\ast_guards.ps1                                     dot-sourced without -Path: the functions only
$ErrorActionPreference = 'Stop'

# The comma binds tighter than these; every other operator (-join, -and, -f) leaves a legitimate array on the left.
$GuardArithmetic = @('Plus', 'Minus', 'Multiply', 'Divide', 'Rem')
$GuardArithmeticText = @('+', '-', '*', '/', '%')
$GuardIncrements = @('PlusPlus', 'MinusMinus', 'PostfixPlusPlus', 'PostfixMinusMinus')
$GuardVariableCmdlets = @('Set-Variable', 'New-Variable', 'Clear-Variable', 'Remove-Variable')
# The Variable: drive is the same variable table reached through the provider; these cmdlets have no -Scope.
$GuardItemCmdlets = @('Set-Item', 'Set-Content', 'New-Item', 'Clear-Item', 'Remove-Item')

function Get-GuardCommandMap {
    # <name as written> -> <cmdlet>, with the aliases the running PowerShell defines for each of them (sv, set, nv, clv,
    # rv, si, sc, ni, cli, ri, rm, del, erase, rd, rmdir on Windows PowerShell 5.1; New-Object has none there, but an
    # alias defined for it resolves here too). Read from the session rather than hand-maintained: every review round
    # found another spelling of the same call.
    $map = @{}
    foreach ($cmdlet in (@('New-Object') + $GuardVariableCmdlets + $GuardItemCmdlets)) {
        $map[$cmdlet] = $cmdlet
        foreach ($alias in @(Get-Alias -Definition $cmdlet -ErrorAction SilentlyContinue)) { $map[$alias.Name] = $cmdlet }
    }
    return $map
}
$GuardCommands = Get-GuardCommandMap

function ConvertTo-GuardAst([string]$Text, $Errors) {
    # Whatever the parser makes of the text, errors and all: whether a file parses is the parse step's own check
    # (parse_check.ps1), and a finding read out of a partially parsed file still beats no finding at all. $Errors is an
    # optional [ref] that receives the parse errors, so a caller can tell how much of the AST it can trust.
    $tokens = $null; $parseErrors = $null
    $ast = [Parser]::ParseInput($Text, [ref]$tokens, [ref]$parseErrors)
    if ($null -ne $Errors) { $Errors.Value = @($parseErrors) }
    return $ast
}
function Get-GuardParseError([string]$Text) {
    $errors = $null
    [void](ConvertTo-GuardAst $Text ([ref]$errors))
    return @($errors)
}
function Get-GuardExpression($Node) {
    # The single expression a pipeline, a parenthesis or an @( ) subexpression wraps; $null when it is anything else
    # (a real pipeline, several statements, an assignment inside the parentheses).
    if ($Node -is [CommandExpressionAst]) { return $Node.Expression }
    if ($Node -is [PipelineAst]) {
        if ($Node.PipelineElements.Count -eq 1) { return Get-GuardExpression $Node.PipelineElements[0] }
        return $null
    }
    if ($Node -is [StatementBlockAst]) {
        if ($Node.Statements.Count -eq 1) { return Get-GuardExpression $Node.Statements[0] }
        return $null
    }
    return $null
}
function Get-GuardBinding([CommandAst]$Command) {
    # What PowerShell's own binder makes of the call: parameter names may be abbreviated (-Na, -Sc), arguments
    # positional, values quoted, the command an alias. A call it cannot bind statically returns $null.
    try { return [StaticParameterBinder]::BindCommand($Command, $true) } catch { return $null }
}
function Get-GuardCommandName([CommandAst]$Command) {
    # The cmdlet this call invokes, module qualification and aliases resolved; $null when the name is not a literal.
    $name = $Command.GetCommandName()
    if (-not $name) { return $null }
    return $GuardCommands[$name.Substring($name.LastIndexOf('\') + 1)]
}
function Get-GuardBound($Binding, [string]$Parameter) {
    # The binder's result for one parameter, or $null when the call does not carry it.
    if ($null -eq $Binding -or -not $Binding.BoundParameters.ContainsKey($Parameter)) { return $null }
    return $Binding.BoundParameters[$Parameter]
}
function Get-GuardLiteral($Bound) {
    # The literal values of a bound parameter - one, or the elements of an array literal. A value the parser cannot
    # resolve to a literal (a variable, an expandable string, an expression) yields nothing: dynamic, out of scope.
    if ($null -eq $Bound -or $null -eq $Bound.Value) { return @() }
    $items = @($Bound.Value)
    if ($Bound.Value -is [ArrayLiteralAst]) { $items = $Bound.Value.Elements }
    $values = New-Object System.Collections.ArrayList
    foreach ($item in $items) { if ($item -is [ConstantExpressionAst]) { [void]$values.Add([string]$item.Value) } }
    return $values
}
function Test-GuardInFunction($Node) {
    # A function is the only construct in these files that gives the assignments below a scope of their own; if, try,
    # foreach and switch blocks do not.
    $parent = $Node.Parent
    while ($null -ne $parent) {
        if ($parent -is [FunctionDefinitionAst]) { return $true }
        $parent = $parent.Parent
    }
    return $false
}

# -------------------- New-Object argument lists --------------------

function Test-GuardCommaBindsTighter($Expression) {
    # `(22, 84 + $offset)` and `@(22, 84 + $offset)`: the arithmetic is applied to the array the commas built, so the
    # argument list holds one value of three elements instead of the two written. `(22, (84 + $offset))` is an
    # ArrayLiteralAst, `(780, [math]::Min(560 + $offset, $h))` keeps its arithmetic inside a method call, and
    # `(1 + 2)` or `(@($a) + $b)` have no comma-built array on the left - none of them is the mistake.
    if ($Expression -is [ParenExpressionAst]) { $inner = Get-GuardExpression $Expression.Pipeline }
    elseif ($Expression -is [ArrayExpressionAst]) { $inner = Get-GuardExpression $Expression.SubExpression }
    else { return $false }
    # `(22, 84 + $a + $b)` nests to the left, so the array literal sits at the bottom of the arithmetic spine.
    while ($inner -is [BinaryExpressionAst] -and $GuardArithmetic -contains $inner.Operator.ToString()) {
        if ($inner.Left -is [ArrayLiteralAst]) { return $true }
        $inner = $inner.Left
    }
    return $false
}
function Get-GuardArgumentList([CommandAst]$Command) {
    # The expressions New-Object receives as the constructor's argument list: whatever binds to -ArgumentList (named or
    # positional - `Type(...)` included, since the parser makes the parenthesis a command element of its own) and, when
    # nothing binds to it, every parenthesized element of the call, so that a call the binder cannot resolve is still read.
    $arguments = New-Object System.Collections.ArrayList
    $bound = Get-GuardBound (Get-GuardBinding $Command) 'ArgumentList'
    if ($null -ne $bound) { [void]$arguments.Add($bound.Value) }
    else { foreach ($element in $Command.CommandElements) { if ($element -is [ParenExpressionAst]) { [void]$arguments.Add($element) } } }
    # `-ArgumentList (1, 2 + $x), 3`: every element of an argument array is an argument list of its own.
    foreach ($argument in @($arguments)) {
        if ($argument -is [ArrayLiteralAst]) { foreach ($element in $argument.Elements) { [void]$arguments.Add($element) } }
    }
    return $arguments
}
function Test-GuardStrayOperator([CommandAst]$Command) {
    # `New-Object Type 22, 84 + $offset`, with or without -ArgumentList: the comma ends the array and the arithmetic
    # operator, read in command mode, becomes a bare-word argument of its own, so New-Object is handed more positional
    # arguments than it has parameters for. Both halves are required - a bare `+` among the elements and a call the
    # binder cannot satisfy - so that a quoted "a+b" (not a bare word) and a call with a stray argument of its own
    # (`Point(22, 84) <# comment #> $b = 1`, whatever else is wrong with it) are not read as arithmetic.
    $stray = $false
    foreach ($element in $Command.CommandElements) {
        if ($element -is [StringConstantExpressionAst] -and $element.StringConstantType -eq 'BareWord' -and $GuardArithmeticText -contains $element.Value) { $stray = $true }
    }
    if (-not $stray) { return $false }
    $binding = Get-GuardBinding $Command
    return ($null -ne $binding -and $binding.BindingExceptions.Count -gt 0)
}
function Find-UnparenthesizedArithmetic([string]$Text) {
    # The lines of the New-Object calls whose argument list carries unparenthesized arithmetic.
    $ast = ConvertTo-GuardAst $Text
    $lines = New-Object System.Collections.ArrayList
    foreach ($command in $ast.FindAll({ param($node) $node -is [CommandAst] }, $true)) {
        if ((Get-GuardCommandName $command) -ne 'New-Object') { continue }
        $found = $false
        foreach ($argument in (Get-GuardArgumentList $command)) { if (Test-GuardCommaBindsTighter $argument) { $found = $true } }
        if (-not $found) { $found = Test-GuardStrayOperator $command }
        if ($found -and -not $lines.Contains($command.Extent.StartLineNumber)) { [void]$lines.Add($command.Extent.StartLineNumber) }
    }
    return @($lines)
}

# -------------------- Parameters overwritten at script scope --------------------

function Get-GuardVariableName($Variable) {
    $path = $Variable.VariablePath.UserPath
    return $path.Substring($path.LastIndexOf(':') + 1)
}
function Test-GuardWritesParameter($Target, [hashtable]$Parameters, [bool]$InFunction) {
    # A write of one of the parameters that reaches the scope the parameter lives in.
    if (-not ($Target -is [VariableExpressionAst])) { return $false }
    $path = $Target.VariablePath
    if (-not $path.IsVariable) { return $false }   # $env:X and other drive-qualified paths are a different store
    if (-not $Parameters.ContainsKey((Get-GuardVariableName $Target))) { return $false }
    if ($path.IsScript -or $path.IsGlobal) { return $true }
    return (-not $InFunction)
}
function Expand-GuardTarget($Left) {
    # The variables an assignment writes: [bool]$script:X and [ValidateNotNull()][string[]]$X wrap the variable in a
    # cast / attribute, and `$tmp, $script:X = 1, $false` (a multiple assignment) writes every element of the array.
    while ($Left -is [AttributedExpressionAst]) { $Left = $Left.Child }   # ConvertExpressionAst is one of these
    if (-not ($Left -is [ArrayLiteralAst])) { return @($Left) }
    $targets = New-Object System.Collections.ArrayList
    foreach ($element in $Left.Elements) {
        while ($element -is [AttributedExpressionAst]) { $element = $element.Child }
        [void]$targets.Add($element)
    }
    return $targets
}
function Test-GuardIsParameterItself($Right, [string]$Name) {
    # The one initializer that is not an overwrite: the parameter's own value, in any of the shapes that only read it -
    # $Name, ${Name}, ($Name), [bool]$Name, @($Name), $Name.IsPresent and nestings of those. "$Name", $Name.Trim(),
    # $Name -and $false, -not $Name, `$Name, $true` and every literal are transformed values, and a transformed value
    # belongs in a script variable with a name of its own.
    $expression = $Right
    if ($expression -is [PipelineBaseAst] -or $expression -is [CommandExpressionAst]) { $expression = Get-GuardExpression $expression }
    while ($true) {
        if ($expression -is [ParenExpressionAst]) { $expression = Get-GuardExpression $expression.Pipeline; continue }
        if ($expression -is [ArrayExpressionAst]) { $expression = Get-GuardExpression $expression.SubExpression; continue }
        if ($expression -is [AttributedExpressionAst]) { $expression = $expression.Child; continue }
        if ($expression -is [MemberExpressionAst] -and -not ($expression -is [InvokeMemberExpressionAst]) -and
            $expression.Member -is [StringConstantExpressionAst] -and $expression.Member.Value -eq 'IsPresent') { $expression = $expression.Expression; continue }
        break
    }
    if (-not ($expression -is [VariableExpressionAst])) { return $false }
    $path = $expression.VariablePath
    return ($path.IsVariable -and $path.IsUnqualified -and $path.UserPath -eq $Name)
}
function Test-GuardCmdletScope($Bound, [bool]$InFunction) {
    # Set-Variable and its siblings reach the same variable table through the cmdlet interface: -Scope Script / Global
    # (or a numeric parent scope) from anywhere, no -Scope / -Scope Local / -Scope 0 from the top level. A -Scope the
    # parser cannot read is flagged: the call cannot be shown to stay local.
    if ($null -eq $Bound) { return (-not $InFunction) }
    $values = @(Get-GuardLiteral $Bound)
    if (-not $values.Count) { return $true }
    $scope = $values[0].ToLowerInvariant()
    if ($scope -eq 'script' -or $scope -eq 'global') { return $true }
    $number = 0
    if ([int]::TryParse($scope, [ref]$number) -and $number -ge 1) { return $true }
    return (-not $InFunction)
}
function Find-OverwrittenParameter([string]$Text) {
    # "<line> ($<Parameter>)" per assignment, "<line> (<Cmdlet> <Parameter>)" per cmdlet call, in source order.
    $ast = ConvertTo-GuardAst $Text
    $hits = New-Object System.Collections.ArrayList
    if ($null -eq $ast.ParamBlock) { return @($hits) }
    # A param block holds default values, not assignments, so nothing inside it can be an overwrite of its own parameter.
    $parameters = @{}
    foreach ($parameter in $ast.ParamBlock.Parameters) { $parameters[$parameter.Name.VariablePath.UserPath] = $true }
    $wanted = { param($node)
        $node -is [AssignmentStatementAst] -or $node -is [UnaryExpressionAst] -or $node -is [CommandAst] -or $node -is [ForEachStatementAst]
    }
    foreach ($node in $ast.FindAll($wanted, $true)) {
        $line = $node.Extent.StartLineNumber
        $inFunction = Test-GuardInFunction $node
        if ($node -is [AssignmentStatementAst]) {
            $targets = @(Expand-GuardTarget $node.Left)
            foreach ($target in $targets) {
                if (-not (Test-GuardWritesParameter $target $parameters $inFunction)) { continue }
                # A compound assignment (+= -= *= /= %=) always changes the value, and a multiple assignment cannot be
                # the accepted copy of the parameter into itself; a plain = must carry the parameter's own value.
                if ($node.Operator.ToString() -eq 'Equals' -and $targets.Count -eq 1 -and (Test-GuardIsParameterItself $node.Right (Get-GuardVariableName $target))) { continue }
                [void]$hits.Add(('{0} (${1})' -f $line, (Get-GuardVariableName $target)))
            }
        }
        elseif ($node -is [UnaryExpressionAst]) {
            if ($GuardIncrements -notcontains $node.TokenKind.ToString()) { continue }
            $target = @(Expand-GuardTarget $node.Child)[0]
            if (Test-GuardWritesParameter $target $parameters $inFunction) { [void]$hits.Add(('{0} (${1})' -f $line, (Get-GuardVariableName $target))) }
        }
        elseif ($node -is [ForEachStatementAst]) {
            # The loop variable is assigned on every iteration, unqualified: the script scope at the top level.
            if (Test-GuardWritesParameter $node.Variable $parameters $inFunction) { [void]$hits.Add(('{0} (${1})' -f $line, (Get-GuardVariableName $node.Variable))) }
        }
        else {
            $cmdlet = Get-GuardCommandName $node
            if ($null -eq $cmdlet -or $cmdlet -eq 'New-Object') { continue }
            $binding = Get-GuardBinding $node
            if ($null -eq $binding) { continue }
            if ($GuardVariableCmdlets -contains $cmdlet) {
                foreach ($name in (Get-GuardLiteral (Get-GuardBound $binding 'Name'))) {
                    if ($parameters.ContainsKey($name) -and (Test-GuardCmdletScope (Get-GuardBound $binding 'Scope') $inFunction)) { [void]$hits.Add(('{0} ({1} {2})' -f $line, $cmdlet, $name)) }
                }
            }
            else {
                # The item cmdlets take no -Scope, so a Variable:<Name> path behaves like an unqualified write.
                foreach ($path in (@(Get-GuardLiteral (Get-GuardBound $binding 'Path')) + @(Get-GuardLiteral (Get-GuardBound $binding 'LiteralPath')))) {
                    $match = [regex]::Match($path, '(?i)(?:^|[\\/:])variable:(\w+)$')
                    if ($match.Success -and $parameters.ContainsKey($match.Groups[1].Value) -and -not $inFunction) {
                        [void]$hits.Add(('{0} ({1} Variable:{2})' -f $line, $cmdlet, $match.Groups[1].Value))
                    }
                }
            }
        }
    }
    return @($hits | Select-Object -Unique)
}

# -------------------- Scanning files --------------------

if ($Path) {
    # powershell.exe -File hands "a.ps1,b.ps1" over as one string; a path that exists as written is never split.
    $targets = New-Object System.Collections.ArrayList
    foreach ($item in $Path) {
        if (Test-Path -LiteralPath $item) { [void]$targets.Add($item) }
        else { foreach ($part in ($item -split ',')) { if ($part.Trim()) { [void]$targets.Add($part.Trim()) } } }
    }
    $findings = 0
    foreach ($file in $targets) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { Write-Output ('[FINDING] {0}: no such file' -f $file); $findings++; continue }
        $full = (Resolve-Path -LiteralPath $file).Path
        $text = [IO.File]::ReadAllText($full)
        $errors = @(Get-GuardParseError $text)
        $arithmetic = @(Find-UnparenthesizedArithmetic $text)
        $overwrites = @(Find-OverwrittenParameter $text)
        foreach ($parseError in $errors) { Write-Output ('[FINDING] {0}:{1}: does not parse: {2}' -f $full, $parseError.Extent.StartLineNumber, $parseError.Message) }
        foreach ($line in $arithmetic) { Write-Output ('[FINDING] {0}:{1}: arithmetic at the top level of a New-Object argument list' -f $full, $line) }
        foreach ($hit in $overwrites) { Write-Output ('[FINDING] {0}:{1}: the write reaches the parameter at script scope' -f $full, $hit) }
        $findings += $errors.Count + $arithmetic.Count + $overwrites.Count
        Write-Output ('{0}: {1} parse error(s), {2} New-Object finding(s), {3} parameter finding(s)' -f $full, $errors.Count, $arithmetic.Count, $overwrites.Count)
    }
    Write-Output ('Summary: {0} file(s), {1} finding(s)' -f $targets.Count, $findings)
    exit $findings
}
