param([string]$Path)
$t = $null; $e = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$t, [ref]$e)
"{0}: {1} parse errors" -f (Split-Path -Leaf (Split-Path -Parent $Path)), @($e).Count
foreach ($x in @($e)) { "  line " + $x.Extent.StartLineNumber + ": " + $x.Message }
exit @($e).Count
