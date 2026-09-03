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

$gui = @($funcs | Where-Object { $_.Name -eq "Initialize-Gui" })[0]
$tries = @($gui.FindAll({ param($n) $n -is [System.Management.Automation.Language.TryStatementAst] }, $true))
$big = $tries | Sort-Object { $_.Extent.Text.Length } -Descending | Select-Object -First 1
$startLine = $big.Body.Extent.StartLineNumber
$label = (Split-Path -Leaf (Split-Path -Parent $ScriptPath)) + " " + $(if ($Interactive) { "IT entry" } else { "user entry" })
try {
    $bodyText = $big.Body.Extent.Text.Trim(); $bodyText = $bodyText.Substring(1, $bodyText.Length - 2)   # strip the block's own braces
    & ([scriptblock]::Create($bodyText)) | Out-Null
    $line = "$label`: Initialize-Gui body OK (script lines $startLine-$($big.Body.Extent.EndLineNumber)); form '" + $script:Form.Text + "' " + $script:Form.Size.Width + "x" + $script:Form.Size.Height
    if ($null -ne $script:OptionsPanel) { $line += "; panel PingCount=" + $script:OptionsPanel["PingCount"].Value + "/max " + $script:OptionsPanel["PingCount"].Maximum + ", SampleSeconds=" + $script:OptionsPanel["SampleSeconds"].Value + "/max " + $script:OptionsPanel["SampleSeconds"].Maximum }
    $line
    if ($null -ne $script:Form) { $script:Form.Dispose() }
    exit 0
}
catch {
    "$label`: EXCEPTION " + $_.Exception.Message
    "  script line " + ($startLine + $_.InvocationInfo.ScriptLineNumber - 1) + ": " + $_.InvocationInfo.Line.Trim()
    exit 1
}
