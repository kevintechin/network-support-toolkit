using namespace System.Management.Automation.Language
param([string[]]$Path)
# The guards on the shipped scripts, on the PowerShell AST: two that keep the v1.2.0 GUI regressions out
# (backlog #17) and one that keeps a call nobody vetted out (backlog #42).
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
#   Find-UnvettedCall / Find-UnvettedMember - a command the shipped script calls, or a [Type]::Method / $object.Method
#     it invokes, that is neither one of its own functions nor on the
#     list of calls somebody looked at, which is the static half of backlog #42: "it changes nothing" is the
#     tool's first promise and nothing measured it. An allowlist, because the ways to write to Windows are
#     open-ended and a denylist is green until it meets a spelling it does not know. See its own section.
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

# -------------------- Calls the tool may make --------------------

# "It changes nothing" is the tool's first promise to the person who runs it - section 1 of the user manual, the first
# answer of its FAQ, the opening of the IT deployment manual - and nothing measured it (backlog #42). This is the
# static half of that item: every command the shipped script calls has to be one somebody looked at.
#
# It is an allowlist, not a list of forbidden writers, and that is the whole of why it is worth having. The ways to
# write to Windows are open-ended - a cmdlet, a .NET call, a CIM method, an external program with another verb - so a
# denylist stays green until someone uses a spelling it does not know, while an allowlist goes red the moment a call
# arrives that nobody has vetted. The cost is a line and a reason whenever the tool learns to call something new,
# which is exactly when a person should be looking.
#
# Three ways a call passes: it is a function the file defines (a call to ourselves is not a call to Windows); its name
# is in $GuardVettedCalls, each entry carrying the reason it is a read; or its name could not be resolved because it
# is invoked through a variable, and that variable is in $GuardVettedInvocations. Where an entry has an argument rule
# every bare-word argument and parameter must match it, so `netsh wlan show interfaces` passes and `netsh int ip set
# address` is a finding; where it has a file-path rule the bound -FilePath must be one of the named programs.
#
# What it cannot do, and why #42's other half stays open: it reads the calls, not what they do. A vetted read whose
# side effect changes the machine - a query that starts a trigger-started service, a driver call that resets a
# counter - looks exactly like a read here, and only a before-and-after measurement on a quiet machine can see it.
$GuardVettedCalls = @{
    # Reads of the machine.
    'Get-NetAdapter'           = 'the adapter list'
    'Get-NetAdapterStatistics' = 'the adapter counters'
    'Get-NetIPConfiguration'   = 'addresses, gateways and DNS servers'
    'Get-NetIPInterface'       = 'the interface settings'
    'Get-NetNeighbor'          = 'the neighbour table'
    'Get-NetRoute'             = 'the route table'
    'Get-NetTCPSetting'        = 'the TCP settings'
    'Find-NetRoute'            = 'which route a destination would take; it finds, it does not add'
    'Get-CimInstance'          = 'CIM queries; the method-invoking cmdlets are not on this list'
    'Get-WmiObject'            = 'the WMI fallback for the same queries'
    'Get-ItemProperty'         = 'registry values, read'
    'Get-Command'              = 'whether a command exists on this machine'
    'Get-Culture'              = 'the formats'
    'Get-UICulture'            = 'the display language'
    'Get-Date'                 = 'the clock'
    'Test-Path'                = 'whether a path exists'
    'netsh'                    = 'the Wi-Fi and WinHTTP proxy readings; show only, by the rule below'
    'arp'                      = 'the ARP cache; -a only, by the rule below'
    # The report and its folder, which is what the tool does write.
    'New-Item'                 = 'the report folder'
    'Set-Content'              = 'the report files'
    'Remove-Item'              = 'the files it wrote itself - the write probe, an emptied error file'
    'Start-Process'            = 'opens the report it just wrote; the programs are named by the rule below'
    # Objects, text and waiting: nothing of the machine.
    'Add-Member'               = 'an object in memory'
    'Add-Type'                 = 'compiles the P/Invoke reader the Wi-Fi counters need'
    'New-Object'               = 'an object in memory'
    'New-TimeSpan'             = 'arithmetic on times'
    'ConvertFrom-Json'         = 'text'
    'ConvertTo-Json'           = 'text'
    'Join-Path'                = 'text'
    'Split-Path'               = 'text'
    'Measure-Object'           = 'arithmetic'
    'Select-Object'            = 'the pipeline'
    'Sort-Object'              = 'the pipeline'
    'Where-Object'             = 'the pipeline'
    'ForEach-Object'           = 'the pipeline'
    'Out-Null'                 = 'the pipeline'
    'Start-Sleep'              = 'waits'
    'Write-Host'               = 'the console'
}
# A name the parser cannot resolve because the call goes through a variable. The tool resolves netsh.exe to its path
# under %SystemRoot% rather than trusting PATH (PR #67), and the other two hold script blocks the file built itself.
# Keyed <function>:<variable>, and each one's value is traced through $GuardVettedOrigins above: a name alone let a
# future function assign $netsh = 'C:\Users\Public\unreviewed.exe' and invoke it (PR #72 round 3).
$GuardVettedInvocations = @{
    'Get-WifiAssociationSample:netsh'         = 'netsh.exe by its resolved path under %SystemRoot%; show only, by the rule below'
    'Get-HostNameSyntaxProblem:scalarPosition' = 'a script block this file builds where it stands'
    'Invoke-CheckStep:Action'                  = 'the step runner''s own parameter; what a caller passes is the callers'' business, and this guard says so rather than pretending otherwise'
}
# Every bare-word argument and every parameter of these has to match, so a new verb is a finding rather than a silence.
$GuardVettedArguments = @{
    'netsh' = '^(wlan|winhttp|show|interfaces|proxy)$'
    'arp'   = '^-a$'
}
# Where the calls that write are allowed to write. Vetting these by name alone left New-Item free to make a registry
# key and Remove-Item free to delete anything (PR #72 round 1): the name is the same, the destination is the whole
# question. Each entry names the parameters that carry the destination, the literals it may be, and the variables it
# may arrive in - the paths this tool computes at run time, each one a place the run made or wrote itself. A
# destination the parser cannot resolve to one of those is a finding, and a call carrying none of the parameters is
# too, because a destination nobody can read is not a destination anybody vetted.
# A variable is vetted where it is written, not wherever its name appears: vetting $path by name alone left every
# Set-Content in the file clean, and a function that assigned $path = 'C:\Users\...' could write it (PR #72 round 2).
# Each entry is <function>:<variable>, the call site as it stands in the two shipped files. A literal needs no site -
# it names the thing itself.
$GuardVettedDestinations = @{
    'New-Item'      = @{ Parameters = @('Path', 'LiteralPath'); Literals = @(); Variables = @('Initialize-OutputDirectory:preferred', 'Initialize-OutputDirectory:fallback', 'Write-EmergencyReport:directory') }
    'Remove-Item'   = @{ Parameters = @('Path', 'LiteralPath'); Literals = @(); Variables = @('Initialize-OutputDirectory:testFile') }
    'Set-Content'   = @{ Parameters = @('Path', 'LiteralPath'); Literals = @(); Variables = @('Write-EnvironmentReport:path') }
    'Start-Process' = @{ Parameters = @('FilePath'); Literals = @('notepad.exe', 'explorer.exe'); Variables = @('Initialize-Gui:target') }
}
# The one static member that writes a file. Vetting it by name left it free to write anywhere, which is the hole the
# cmdlets had (PR #72 round 2): it carries a destination rule of its own, on the argument that holds the path.
$GuardVettedMemberDestinations = @{
    '[System.IO.File]::WriteAllText' = @{ Index = 0; Literals = @(); Variables = @('Write-Utf8File:Path', 'Initialize-OutputDirectory:testFile') }
}

# The calls the parser does not see as commands at all: [Type]::Method(...) and $object.Method(...). Leaving them out
# was the hole the allowlist was built to close - $obj.SetValue, (Get-CimInstance ...).Delete(), a CIM method - and the
# guard said so in its own header while not looking (PR #72 round 1). Same rule, same measurement: 49 static names and
# 48 method names over the two shipped files, each one read or written down. A name nobody vetted is a finding, which
# is the property that matters: a new .SetValue( or .Delete( goes red the day it arrives.
#
# A method name is vetted, not a method: .Add on a list and .Add on something else read alike here. That is the claim -
# every member invocation carries a name somebody looked at - and it is weaker than "no member invocation writes",
# which no static reading can make.
$GuardVettedStaticMembers = @(
    '$apiType::WlanCloseHandle', '$apiType::WlanEnumInterfaces', '$apiType::WlanFreeMemory', '$apiType::WlanOpenHandle',
    '$apiType::WlanQueryInterface', '[array]::IndexOf', '[char]::ConvertToUtf32', '[char]::IsHighSurrogate',
    '[char]::IsLowSurrogate', '[Console]::ReadKey', '[Convert]::ToInt32', '[double]::IsInfinity',
    '[double]::IsNaN', '[double]::TryParse', '[guid]::NewGuid', '[math]::Ceiling',
    '[math]::Floor', '[math]::Max', '[math]::Min', '[math]::Pow',
    '[math]::Round', '[math]::Sqrt', '[regex]::Escape', '[regex]::Match',
    '[regex]::Matches', '[string]::Equals', '[string]::IsNullOrWhiteSpace', '[System.BitConverter]::GetBytes',
    '[System.BitConverter]::ToUInt32', '[System.Diagnostics.Stopwatch]::StartNew', '[System.Drawing.Color]::FromArgb', '[System.IO.File]::ReadAllText',
    '[System.IO.File]::WriteAllText', '[System.IO.Path]::GetTempPath', '[System.IO.Path]::IsPathRooted', '[System.Net.Dns]::GetHostAddressesAsync',
    '[System.Net.HttpWebRequest]::Create', '[System.Net.IPAddress]::Parse', '[System.Net.IPAddress]::TryParse', '[System.Net.WebRequest]::GetSystemWebProxy',
    '[System.Net.WebUtility]::HtmlEncode', '[System.Runtime.InteropServices.Marshal]::Copy', '[System.Runtime.InteropServices.Marshal]::PtrToStringUni', '[System.Runtime.InteropServices.Marshal]::ReadInt32',
    '[System.Runtime.InteropServices.Marshal]::ReadInt64', '[System.Uri]::TryCreate', '[System.Windows.Forms.Application]::DoEvents', '[System.Windows.Forms.Application]::EnableVisualStyles',
    '[System.Windows.Forms.MessageBox]::Show'
)
$GuardVettedMemberNames = @(
    'Add', 'Add_Click', 'Add_FormClosing', 'Add_Shown', 'Add_TextChanged', 'Add_Tick',
    'AddSeconds', 'AppendLine', 'Contains', 'ContainsKey', 'EndsWith', 'GetAddressBytes',
    'GetAscii', 'GetProxy', 'GetType', 'GetUnicode', 'IndexOf', 'IndexOfAny',
    'LastIndexOf', 'Split', 'StartsWith', 'Substring', 'ToInt64', 'ToLowerInvariant',
    'ToString', 'ToUpperInvariant', 'Trim', 'TrimEnd'
)
# And the names that mean something on a receiver that can write - .AppendText on a FileInfo creates a file, .Clear
# and .Stop and .Send are what their types make of them - are vetted at the invocation they are called from, keyed
# <function>:<receiver>:<member> (PR #72 rounds 3 and 4). The function alone was not the site: a FileInfo.AppendText()
# added inside Write-UiLog produced the key the log box already had. A receiver's type is still not in the AST and
# cannot be inferred from it, so this is as far as a static reading goes - the receiver expression is read as written,
# and a new one, however it is built, is a finding.
$GuardVettedMemberSites = @(
    ':$script:Form:ShowDialog', 'Get-HostNameSyntaxProblem:$label:Normalize',
    'Get-UrlHostProblemSuffix:$written:Normalize', 'Initialize-Gui:$form:Close',
    'Initialize-Gui:$hints:SetToolTip', 'Initialize-Gui:$script:StartButton:PerformClick',
    'Initialize-Gui:$sender:Dispose', 'Initialize-Gui:$sender:Stop',
    'Initialize-Gui:$timer:Start', 'Invoke-DnsLookup:$stopwatch:Stop',
    'Invoke-DnsLookup:$task:Wait', 'Invoke-HttpConnectionTest:$request:GetResponse',
    'Invoke-HttpConnectionTest:$response:Close', 'Invoke-HttpConnectionTest:$response:GetResponseStream',
    'Invoke-HttpConnectionTest:$stopwatch:Stop', 'Invoke-HttpConnectionTest:$stream:Dispose',
    'Invoke-HttpConnectionTest:$stream:ReadByte', 'Invoke-PingMeasurement:$ping:Dispose',
    'Invoke-PingMeasurement:$ping:Send', 'Invoke-TcpConnectionTest:$asyncResult.AsyncWaitHandle:Close',
    'Invoke-TcpConnectionTest:$asyncResult.AsyncWaitHandle:WaitOne', 'Invoke-TcpConnectionTest:$client.Client:IOControl',
    'Invoke-TcpConnectionTest:$client:BeginConnect', 'Invoke-TcpConnectionTest:$client:Close',
    'Invoke-TcpConnectionTest:$client:EndConnect', 'Invoke-TcpConnectionTest:$stopwatch:Stop',
    'Invoke-TraceRoute:$ping:Dispose', 'Invoke-TraceRoute:$ping:Send',
    'Invoke-TraceRoute:$stopwatch:Stop', 'Run-AllChecks:$script:LogBox:Clear',
    'Run-AllChecks:$script:Results:Clear', 'Write-UiLog:$script:LogBox:AppendText',
    'Write-UiLog:$script:LogBox:ScrollToCaret'
)

function Find-UnvettedMember([string]$Text) {
    # The lines of the member invocations whose name is on neither list.
    $ast = ConvertTo-GuardAst $Text
    $hits = New-Object System.Collections.ArrayList
    foreach ($call in $ast.FindAll({ param($node) $node -is [InvokeMemberExpressionAst] }, $true)) {
        $line = $call.Extent.StartLineNumber
        $member = $call.Member.Extent.Text
        if ($call.Static) {
            $name = ('{0}::{1}' -f $call.Expression.Extent.Text, $member)
            if ($GuardVettedStaticMembers -notcontains $name) { [void]$hits.Add(('{0} ({1})' -f $line, $name)); continue }
            if ($GuardVettedMemberDestinations.ContainsKey($name)) {
                $rule = $GuardVettedMemberDestinations[$name]
                $arguments = @($call.Arguments)
                if ($arguments.Count -le $rule.Index) { [void]$hits.Add(('{0} ({1}, no destination to read)' -f $line, $name)); continue }
                if (-not (Test-GuardVettedDestination $arguments[$rule.Index] $rule (Get-GuardEnclosingFunctionAst $call))) {
                    [void]$hits.Add(('{0} ({1}, a destination the entry does not allow)' -f $line, $name))
                }
            }
        }
        elseif ($GuardVettedMemberNames -notcontains $member) {
            $site = ((Get-GuardEnclosingFunction $call) + ':' + $call.Expression.Extent.Text + ':' + $member)
            if ($GuardVettedMemberSites -notcontains $site) { [void]$hits.Add(('{0} (.{1})' -f $line, $member)) }
        }
    }
    return @($hits | Select-Object -Unique)
}

# Where a vetted variable comes from, at the site it is vetted at. The site binding of round 2 proved the names and
# not the value: Write-EnvironmentReport could have assigned $path = 'C:\Users\...' and kept its clean Set-Content
# (PR #72 round 3). Every assignment to the variable inside that function has to be one of the expressions here, as
# they stand, so a changed line is a finding until somebody writes the new one down - and 'parameter' means the
# function may not assign it at all, its value being the callers', which is where this guard stops.
#
# What the expressions say, read together, is the thing worth knowing: every destination is the configured report
# folder or the temporary folder Windows gives, and $netsh is netsh.exe under %SystemRoot%. Where the configuration
# names a rooted folder the tool writes there, by design - so no static rule can say a destination is "inside the
# report area", because the report area is the person's to choose. What this guard says is narrower and true: the
# destination is the one the configuration resolved, through the expressions below.
$GuardVettedOrigins = @{
    'Get-HostNameSyntaxProblem:scalarPosition' = @('{ param([int]$units) $units + 1 - [regex]::Matches($name.Substring(0, [math]::Min($units, $name.Length)), ''[\uD800-\uDBFF][\uDC00-\uDFFF]'').Count }')
    'Get-WifiAssociationSample:netsh'          = @('Join-Path $env:SystemRoot "System32\netsh.exe"')
    'Initialize-Gui:target'                    = @('$null', '$candidate')
    'Initialize-OutputDirectory:fallback'      = @('Join-Path ([System.IO.Path]::GetTempPath()) "NetworkHealthCheck\Reports"')
    'Initialize-OutputDirectory:preferred'     = @('$folderName', 'Join-Path $script:BaseDirectory $folderName')
    'Initialize-OutputDirectory:testFile'      = @('Join-Path $preferred (".write_test_{0}.tmp" -f [guid]::NewGuid().ToString("N"))')
    'Invoke-CheckStep:Action'                  = @('parameter')
    'Write-EmergencyReport:directory'          = @('$script:OutputDirectory', 'Join-Path ([System.IO.Path]::GetTempPath()) "NetworkHealthCheck\Reports"', '[System.IO.Path]::GetTempPath()')
    'Write-EnvironmentReport:path'             = @('Join-Path $folder $name')
    'Write-Utf8File:Path'                      = @('parameter')
}

function Get-GuardAssignmentTargets($Left) {
    # The variables an assignment writes: one, or the elements of a multiple assignment, with attributes and
    # conversions unwrapped - [string]$x = ... and $a, $x = ... both write $x.
    $targets = New-Object System.Collections.ArrayList
    $items = @($Left)
    if ($Left -is [ArrayLiteralAst]) { $items = $Left.Elements }
    foreach ($item in $items) {
        $node = $item
        while ($node -is [AttributedExpressionAst]) { $node = $node.Child }
        if ($node -is [VariableExpressionAst]) { [void]$targets.Add($node) }
    }
    return @($targets)
}
function Get-GuardVariableWrites($Function, [string]$Variable) {
    # Every write to $Variable inside $Function, whatever it is spelled as. Comparing the assignment's source text
    # let $local:netsh = "..." through beside the vetted $netsh = Join-Path ... : the same variable, another spelling,
    # and the vetted assignment still there to be found (PR #72 round 4). The name is normalised the way the parameter
    # guard normalises it, and every other shape that writes - ++ and --, a foreach variable, the variable cmdlets,
    # a multiple or compound assignment - is a write with no expression to vet, which is a finding by itself.
    $writes = New-Object System.Collections.ArrayList
    if ($null -eq $Function) { return @($writes) }
    foreach ($node in $Function.FindAll({ param($item) $true }, $true)) {
        if ($node -is [AssignmentStatementAst]) {
            foreach ($target in (Get-GuardAssignmentTargets $node.Left)) {
                if ((Get-GuardVariableName $target) -ne $Variable) { continue }
                $expression = $null
                if ($node.Operator -eq 'Equals' -and $node.Left -isnot [ArrayLiteralAst] -and $node.Left -is [VariableExpressionAst]) {
                    $expression = $node.Right.Extent.Text
                }
                [void]$writes.Add([pscustomobject]@{ Expression = $expression })
            }
        }
        elseif ($node -is [UnaryExpressionAst] -and ($GuardIncrements -contains [string]$node.TokenKind) -and
                $node.Child -is [VariableExpressionAst] -and (Get-GuardVariableName $node.Child) -eq $Variable) {
            [void]$writes.Add([pscustomobject]@{ Expression = $null })
        }
        elseif ($node -is [ForEachStatementAst] -and $node.Variable -is [VariableExpressionAst] -and
                (Get-GuardVariableName $node.Variable) -eq $Variable) {
            [void]$writes.Add([pscustomobject]@{ Expression = $null })
        }
        elseif ($node -is [CommandAst]) {
            $cmdlet = Get-GuardCommandName $node
            if ($null -eq $cmdlet) { continue }
            $binding = Get-GuardBinding $node
            if ($null -eq $binding) { continue }
            if ($GuardVariableCmdlets -contains $cmdlet) {
                foreach ($name in (Get-GuardLiteral (Get-GuardBound $binding 'Name'))) {
                    if ($name -eq $Variable) { [void]$writes.Add([pscustomobject]@{ Expression = $null }) }
                }
            }
            elseif ($GuardItemCmdlets -contains $cmdlet) {
                foreach ($path in (@(Get-GuardLiteral (Get-GuardBound $binding 'Path')) + @(Get-GuardLiteral (Get-GuardBound $binding 'LiteralPath')))) {
                    $match = [regex]::Match($path, '(?i)(?:^|[\\/:])variable:(\w+)$')
                    if ($match.Success -and $match.Groups[1].Value -eq $Variable) { [void]$writes.Add([pscustomobject]@{ Expression = $null }) }
                }
            }
        }
    }
    return @($writes)
}

function Test-GuardVettedOrigin($Function, [string]$Variable, [string]$Key) {
    # Every assignment to $Variable inside $Function must be one of the vetted expressions; 'parameter' means none.
    if (-not $GuardVettedOrigins.ContainsKey($Key)) { return $false }
    $allowed = $GuardVettedOrigins[$Key]
    $writes = @(Get-GuardVariableWrites $Function $Variable)
    if ($allowed -contains 'parameter') { return ($writes.Count -eq 0) }
    if ($writes.Count -eq 0) { return $false }
    foreach ($write in $writes) {
        if ($null -eq $write.Expression) { return $false }
        if ($allowed -notcontains $write.Expression) { return $false }
    }
    return $true
}

function Get-GuardEnclosingFunctionAst($Node) {
    # The function a node stands in, or $null at the top level of the file.
    $node = $Node.Parent
    while ($null -ne $node) {
        if ($node -is [FunctionDefinitionAst]) { return $node }
        $node = $node.Parent
    }
    return $null
}
function Get-GuardEnclosingFunction($Node) {
    $function = Get-GuardEnclosingFunctionAst $Node
    if ($null -eq $function) { return '' }
    return $function.Name
}
function Test-GuardVettedDestination($Value, $Rule, $Function) {
    # A literal is vetted as itself; anything else has to be a variable vetted at this call site AND assigned there
    # from one of the expressions its entry names.
    $literals = @(Get-GuardLiteral $Value)
    if ($literals.Count -gt 0) {
        foreach ($literal in $literals) { if ($Rule.Literals -notcontains $literal) { return $false } }
        return $true
    }
    $expression = $Value
    if ($null -ne $Value -and $Value.PSObject.Properties['Value']) { $expression = $Value.Value }
    if ($expression -isnot [VariableExpressionAst]) { return $false }
    $site = ''
    if ($null -ne $Function) { $site = $Function.Name }
    $key = ($site + ':' + $expression.VariablePath.UserPath)
    if ($Rule.Variables -notcontains $key) { return $false }
    return (Test-GuardVettedOrigin $Function $expression.VariablePath.UserPath $key)
}

function Test-GuardVettedArgument([CommandAst]$Command, [string]$Key) {
    if ($GuardVettedArguments.ContainsKey($Key)) {
        $pattern = $GuardVettedArguments[$Key]
        foreach ($element in @($Command.CommandElements | Select-Object -Skip 1)) {
            if ($element -is [CommandParameterAst]) {
                if (('-' + $element.ParameterName) -notmatch $pattern) { return $false }
                continue
            }
            # Every argument, not the bare words alone: netsh reads "int" "ip" "set" exactly as it reads int ip set,
            # and a variable is an argument nobody can read (PR #72 round 1). Anything the parser cannot resolve to a
            # string is refused, which is the safe direction for a rule about what a program is being told to do.
            if ($element -isnot [StringConstantExpressionAst]) { return $false }
            if ($element.Value -notmatch $pattern) { return $false }
        }
    }
    if ($GuardVettedDestinations.ContainsKey($Key)) {
        $rule = $GuardVettedDestinations[$Key]
        $binding = Get-GuardBinding $Command
        if ($null -eq $binding) { return $false }
        $function = Get-GuardEnclosingFunctionAst $Command
        $seen = $false
        foreach ($parameter in $rule.Parameters) {
            $bound = Get-GuardBound $binding $parameter
            if ($null -eq $bound) { continue }
            $seen = $true
            if (-not (Test-GuardVettedDestination $bound $rule $function)) { return $false }
        }
        if (-not $seen) { return $false }
    }
    return $true
}

function Find-UnvettedCall([string]$Text) {
    # The lines of the calls that are neither this file's own functions nor vetted above.
    $ast = ConvertTo-GuardAst $Text
    $own = @{}
    foreach ($function in $ast.FindAll({ param($node) $node -is [FunctionDefinitionAst] }, $true)) { $own[$function.Name] = $true }
    $hits = New-Object System.Collections.ArrayList
    foreach ($command in $ast.FindAll({ param($node) $node -is [CommandAst] }, $true)) {
        $line = $command.Extent.StartLineNumber
        # The name as written, not Get-GuardCommandName: that one answers for the handful of cmdlets the other two
        # guards care about and $null for everything else, which would make every call here a finding. Module
        # qualification is stripped; an alias is left as written, so a call spelled `sc` rather than Set-Content is a
        # finding until somebody says which it is - which is the allowlist working, not failing.
        # A module-qualified name is its own identity: stripping to the last backslash let UnreviewedModule\Get-Date
        # inherit the clock's entry and UnreviewedModule\Write-Utf8File the in-file exemption, while PowerShell would
        # run the module's command (PR #72 round 2). The tool qualifies nothing, so any qualified name is a finding.
        $written = $command.GetCommandName()
        $name = $written
        if ($null -eq $name) {
            $first = $command.CommandElements[0]
            if ($first -isnot [VariableExpressionAst]) { [void]$hits.Add(('{0} (a command name built at run time)' -f $line)); continue }
            $variable = $first.VariablePath.UserPath
            $function = Get-GuardEnclosingFunctionAst $command
            $site = ''
            if ($null -ne $function) { $site = $function.Name }
            $key = ($site + ':' + $variable)
            if (-not $GuardVettedInvocations.ContainsKey($key)) { [void]$hits.Add(('{0} (& ${1})' -f $line, $variable)); continue }
            if (-not (Test-GuardVettedOrigin $function $variable $key)) { [void]$hits.Add(('{0} (& ${1}, not from the expression its entry names)' -f $line, $variable)); continue }
            if (-not (Test-GuardVettedArgument $command $variable)) { [void]$hits.Add(('{0} (& ${1}, an argument the entry does not allow)' -f $line, $variable)) }
            continue
        }
        if ($own.ContainsKey($name)) { continue }
        if (-not $GuardVettedCalls.ContainsKey($name)) { [void]$hits.Add(('{0} ({1})' -f $line, $name)); continue }
        if (-not (Test-GuardVettedArgument $command $name)) { [void]$hits.Add(('{0} ({1}, an argument the entry does not allow)' -f $line, $name)) }
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
        $unvetted = @(Find-UnvettedCall $text) + @(Find-UnvettedMember $text)
        foreach ($parseError in $errors) { Write-Output ('[FINDING] {0}:{1}: does not parse: {2}' -f $full, $parseError.Extent.StartLineNumber, $parseError.Message) }
        foreach ($line in $arithmetic) { Write-Output ('[FINDING] {0}:{1}: arithmetic at the top level of a New-Object argument list' -f $full, $line) }
        foreach ($hit in $overwrites) { Write-Output ('[FINDING] {0}:{1}: the write reaches the parameter at script scope' -f $full, $hit) }
        foreach ($hit in $unvetted) { Write-Output ('[FINDING] {0}:{1}: a call nobody vetted' -f $full, $hit) }
        $findings += $errors.Count + $arithmetic.Count + $overwrites.Count + $unvetted.Count
        Write-Output ('{0}: {1} parse error(s), {2} New-Object finding(s), {3} parameter finding(s), {4} unvetted call(s)' -f $full, $errors.Count, $arithmetic.Count, $overwrites.Count, $unvetted.Count)
    }
    Write-Output ('Summary: {0} file(s), {1} finding(s)' -f $targets.Count, $findings)
    exit $findings
}
