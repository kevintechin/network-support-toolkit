param([string]$ScriptPath, [switch]$Interactive)
# Headless smoke test of Initialize-Gui: load every function via the AST, set the minimal script state, then run the
# body of Initialize-Gui's main try block as a script block so an exception surfaces with its position instead of
# being swallowed by the function's catch (which silently falls back to console mode).
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$errors)
$funcs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Parent -is [System.Management.Automation.Language.NamedBlockAst] }, $true)
foreach ($f in $funcs) { Invoke-Expression $f.Extent.Text }
$script:ToolVersion = "repro"
$script:BaseDirectory = Split-Path -Parent $ScriptPath
$script:Results = New-Object System.Collections.ArrayList
$script:StartupMessages = New-Object System.Collections.ArrayList
$script:BaseConfig = Get-DefaultConfig
$script:Interactive = [bool]$Interactive
Set-RunOptions -Overrides @{ EntryPoint = $(if ($Interactive) { "IT" } else { "User" }); ExpandDetails = [bool]$Interactive } | Out-Null
$script:OutputDirectory = $script:BaseDirectory
Add-Type -AssemblyName System.Windows.Forms; Add-Type -AssemblyName System.Drawing
$script:GuiAvailable = $true


# Every fixed-size control against the box it was given (backlog #49): GetPreferredSize is WinForms' own answer, so
# a check box's glyph and a button's padding are counted by the framework rather than guessed at here. Width only -
# a label wider than its box wraps and loses its second line inside 22 px, which is the defect; the Reset button's
# preferred *height* is 3 px more than its box and renders correctly on every machine this project has captured, so
# asserting height would fail on something nobody can see. AutoSize controls size themselves and are not measured.
function Get-FixedControls($Parent) {
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($c in $Parent.Controls) {
        if ((@('Label', 'CheckBox', 'Button', 'RadioButton') -contains $c.GetType().Name) -and (-not $c.AutoSize) -and $c.Text) {
            $out.Add([pscustomobject]@{ Text = [string]$c.Text; Need = [int]$c.GetPreferredSize([System.Drawing.Size]::Empty).Width; Width = [int]$c.Width })
        }
        foreach ($nested in (Get-FixedControls $c)) { $out.Add($nested) }
    }
    # ToArray, not @(...): the array subexpression over a List[object] throws in Windows PowerShell 5.1.
    return $out.ToArray()
}
$gui = @($funcs | Where-Object { $_.Name -eq "Initialize-Gui" })[0]
$tries = @($gui.FindAll({ param($n) $n -is [System.Management.Automation.Language.TryStatementAst] }, $true))
$big = $tries | Sort-Object { $_.Extent.Text.Length } -Descending | Select-Object -First 1
$startLine = $big.Body.Extent.StartLineNumber
$label = (Split-Path -Leaf (Split-Path -Parent $ScriptPath)) + " " + $(if ($Interactive) { "IT entry" } else { "user entry" })
try {
    $bodyText = $big.Body.Extent.Text.Trim(); $bodyText = $bodyText.Substring(1, $bodyText.Length - 2)   # strip the block's own braces
    & ([scriptblock]::Create($bodyText)) | Out-Null
    $fixed = @(Get-FixedControls $script:Form)
    $tight = @($fixed | Where-Object { $_.Need -gt $_.Width })
    if ($tight.Count -gt 0) {
        "$label`: " + $tight.Count + " control(s) render text wider than the box the form gives them: " + (@($tight | ForEach-Object { "'" + $_.Text + "' needs " + $_.Need + " px in " + $_.Width }) -join '; ')
        if ($null -ne $script:Form) { $script:Form.Dispose() }
        exit 1
    }
    $line = "$label`: Initialize-Gui body OK (script lines $startLine-$($big.Body.Extent.EndLineNumber)); form '" + $script:Form.Text + "' " + $script:Form.Size.Width + "x" + $script:Form.Size.Height
    if ($null -ne $script:OptionsPanel) { $line += "; panel PingCount=" + $script:OptionsPanel["PingCount"].Value + "/max " + $script:OptionsPanel["PingCount"].Maximum + ", PingCountMaximum=" + $script:OptionsPanel["PingCountMaximum"].Value + "/max " + $script:OptionsPanel["PingCountMaximum"].Maximum + ", SampleSeconds=" + $script:OptionsPanel["SampleSeconds"].Value + "/max " + $script:OptionsPanel["SampleSeconds"].Maximum }
    # A control that fits its own box is still unreachable if the window can be made narrower than the grid it sits
    # in: the options panel is anchored left and right, so its width shrinks with the form's. The narrowest form the
    # user is allowed must still show the panel's rightmost control (PR #35, round 1).
    $panel = $null
    if ($null -ne $script:OptionsPanel) { $panel = $script:OptionsPanel["PingTarget"].Parent }
    if ($null -ne $panel) {
        $rightmost = 0
        foreach ($c in $panel.Controls) { if (($c.Left + $c.Width) -gt $rightmost) { $rightmost = $c.Left + $c.Width } }
        $panelAtMinimum = $panel.Width - ($script:Form.Width - $script:Form.MinimumSize.Width)
        if ($rightmost -gt $panelAtMinimum) {
            "$label`: the panel is " + $panelAtMinimum + " px wide at the window's minimum width and its rightmost control ends at " + $rightmost + " px, so it cannot be reached there"
            if ($null -ne $script:Form) { $script:Form.Dispose() }
            exit 1
        }
    }
    $line += "; " + $fixed.Count + " fixed-size controls fit their boxes"
    if ($null -ne $panel) { $line += "; the panel is " + $panelAtMinimum + " px at the minimum window width against a grid " + $rightmost + " px wide" }
    $line
    if ($null -ne $script:Form) { $script:Form.Dispose() }
    exit 0
}
catch {
    "$label`: EXCEPTION " + $_.Exception.Message
    "  script line " + ($startLine + $_.InvocationInfo.ScriptLineNumber - 1) + ": " + $_.InvocationInfo.Line.Trim()
    exit 1
}
