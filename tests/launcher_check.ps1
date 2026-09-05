param([string]$PackageDir, [string]$WorkDir)
# Backlog #28: LauncherError.txt suggested "extract the complete ZIP file to a local folder" whatever had stopped the
# launcher - for exit code 3 (the language-mode guard of backlog #18, checklist M7) and for PowerShell's AllSigned
# refusal (M8) alike - so the file alone, sent to IT, misled. Since 1.2.3 the suggested action follows the reason, and
# this runs the six language launchers through every reason, started like a double-click (cmd.exe /s /c, stdin from
# NUL so that the trailing pause returns) from a staged copy whose program file is missing or replaced by a stub that
# exits with the wanted code: no network, no window and no policy are needed.
#   1. the program file is missing -> exit 1; the suggestion is to extract the complete ZIP (the one case where it fits)
#   2. the program exits 3          -> exit 1; the Error line names exit code 3 and the suggestion points at the
#                                      environment report, not at the ZIP
#   3. the program exits 1          -> exit 1; the suggestion points at the message PowerShell printed above and at
#                                      allowing NetworkHealthCheck.ps1, not at the ZIP
# The assertions read the suggested-action line alone - "Suggested action: " / the zh-TW label, spelled as character
# codes so that this file stays ASCII (see env_guard_check.ps1) - because the Script: line names NetworkHealthCheck.ps1
# in every file and would satisfy a whole-file match for nothing.
#   -PackageDir: the package root holding en-US\ and zh-TW\
#   -WorkDir:    an existing folder for the staged copies
# Example: tests\launcher_check.ps1 -PackageDir healthcheck -WorkDir $env:TEMP\nhc-launcher
$ErrorActionPreference = 'Stop'

$passes = 0
$fails = 0
function Assert-Equal($name, $actual, $expected) {
    if ("$actual" -eq "$expected") { $script:passes++; Write-Output "[PASS] $name -> $actual" }
    else { $script:fails++; Write-Output "[FAIL] $name -> got '$actual', expected '$expected'" }
}
function Assert-True($name, $condition, $detail) {
    if ($condition) { $script:passes++; Write-Output "[PASS] $name" }
    else { $script:fails++; Write-Output "[FAIL] $name -> $detail" }
}

$PackageDir = (Resolve-Path -LiteralPath $PackageDir).Path
$cmdExe = Join-Path $env:SystemRoot 'System32\cmd.exe'
$labelEn = 'Suggested action: '
$labelZh = [string]([char]0x5EFA + [char]0x8B70 + [char]0xFF1A)   # the zh-TW label: "suggestion" and a full-width colon
$errorEn = 'Error: '
$errorZh = [string]([char]0x932F + [char]0x8AA4 + [char]0xFF1A)   # the zh-TW "Error:" label
$utf8Bom = New-Object System.Text.UTF8Encoding($true)

$reasons = @(
    @{ Name = 'missing program file'; Stub = $null;    Expect = 'ZIP';                            Reject = 'NetworkHealthCheck_ENVIRONMENT_' },
    @{ Name = 'exit code 3';          Stub = 'exit 3'; Expect = 'NetworkHealthCheck_ENVIRONMENT_'; Reject = 'ZIP' },
    @{ Name = 'exit code 1';          Stub = 'exit 1'; Expect = 'NetworkHealthCheck\.ps1';         Reject = 'ZIP' }
)

foreach ($lang in @('en-US', 'zh-TW')) {
    foreach ($launcher in @('Start-NetworkCheck.cmd', 'Start-NetworkCheck-IT.cmd', 'Start-NetworkCheck-Console.cmd')) {
        foreach ($reason in $reasons) {
            $case = '{0} {1}, {2}' -f $lang, $launcher, $reason.Name
            $stage = Join-Path $WorkDir ('launcher\' + $lang + '_' + ($launcher -replace '\.cmd$', '') + '_' + ($reason.Name -replace '[^A-Za-z0-9]+', '-'))
            if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
            New-Item -ItemType Directory -Force -Path $stage | Out-Null
            Copy-Item -LiteralPath (Join-Path $PackageDir ($lang + '\' + $launcher)) -Destination $stage
            if ($null -ne $reason.Stub) { [IO.File]::WriteAllText((Join-Path $stage 'NetworkHealthCheck.ps1'), $reason.Stub + "`r`n", $utf8Bom) }

            # The launchers switch the console to UTF-8 (chcp 65001) before they print, so their output is read as UTF-8.
            $savedEncoding = [Console]::OutputEncoding
            $ErrorActionPreference = 'Continue'   # a nonzero exit code is the expected result here, not a terminating error
            try {
                [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
                $output = @(& $cmdExe /s /c ('"' + (Join-Path $stage $launcher) + '" <nul') 2>&1 | ForEach-Object { [string]$_ })
                $code = $LASTEXITCODE
            }
            finally {
                [Console]::OutputEncoding = $savedEncoding
                $ErrorActionPreference = 'Stop'
            }

            Assert-Equal "$case - the launcher exits 1" $code 1
            $file = Join-Path $stage 'LauncherError.txt'
            Assert-True "$case - LauncherError.txt is written next to the launcher" (Test-Path -LiteralPath $file) 'no LauncherError.txt'
            if (Test-Path -LiteralPath $file) {
                $lines = @(Get-Content -LiteralPath $file -Encoding UTF8)
                $suggested = @($lines | Where-Object { $_.StartsWith($labelEn) -or $_.StartsWith($labelZh) })
                Assert-Equal "$case - one suggested-action line in the file" $suggested.Count 1
                $line = [string]$(if ($suggested.Count) { $suggested[0] } else { '' })
                Assert-True ("$case - the suggestion fits the reason ({0})" -f $reason.Expect) ($line -match $reason.Expect) $line
                Assert-True ("$case - the suggestion is not another reason's ({0})" -f $reason.Reject) ($line -notmatch $reason.Reject) $line
                if ($reason.Stub -eq 'exit 3') {
                    $errorLine = [string]@($lines | Where-Object { $_.StartsWith($errorEn) -or $_.StartsWith($errorZh) })[0]
                    Assert-True "$case - the Error line names exit code 3" ($errorLine -match ' 3(?!\d)') $errorLine
                }
            }
            Assert-True "$case - the screen shows the suggestion under the reason" (@($output | Where-Object { $_.StartsWith($labelEn) -or $_.StartsWith($labelZh) }).Count -ge 1) ((@($output | Select-Object -Last 6)) -join ' | ')
        }
    }
}

Write-Output ("Summary: {0} passed, {1} failed" -f $passes, $fails)
exit $fails
