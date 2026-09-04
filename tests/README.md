# tests/ — the NetworkHealthCheck validation chain

Backlog #16: the scripts that validate a NetworkHealthCheck release used to live in a session scratchpad. This folder commits them, so the whole chain — including the real-window run that caught the two 1.2.0 GUI regressions — is reproducible from a fresh checkout. Nothing here ships: the release asset is built from `healthcheck/` only (`build_asset.py` packages the tracked files under that folder and nothing else).

## Run the chain

```
powershell -NoProfile -ExecutionPolicy Bypass -File tests\Invoke-ValidationChain.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests\Invoke-ValidationChain.ps1 -Package -RequireHealthy     # release: + asset round trip, Overall Healthy required
powershell -NoProfile -ExecutionPolicy Bypass -File tests\Invoke-ValidationChain.ps1 -SkipGui                     # no interactive desktop
powershell -NoProfile -ExecutionPolicy Bypass -File tests\Invoke-ValidationChain.ps1 -Steps parse,validator,guards,unit,report
```

Prerequisites: Windows 10 / 11 with Windows PowerShell 5.1 (the tool's own runtime), Python 3 on `PATH` (`-Python` to point elsewhere), git (the guard self-test reads the v1.2.0 anchor files from history), and for the `gui` step an interactive desktop session: windows open, get clicked and close by themselves, so leave the desktop alone while they run. The default chain takes about ten minutes; the two IT-entry window runs account for most of it because each samples TCP retransmissions for 125 s.

Everything the chain produces goes under `%TEMP%\nhc-tests\<timestamp>\` (`-WorkDir` to choose): staged copies of `healthcheck/<lang>/` with their `Reports/`, one `<step>_<case>.log` per run, and `summary.md` with the table the chain prints. The repository is never written to, and the exit code is the number of failed cases.

## Steps and what "pass" means

| Step | Script | Pass | Reference (1.2.1) |
|---|---|---|---|
| `parse` | `parse_check.ps1`, both languages | the Windows PowerShell 5.1 parser reports 0 errors | 0 × 2 |
| `validator` | `healthcheck/tools/validate_release.py` | exit 0 and `Summary: N passed, 0 failed` | 66 / 66 |
| `guards` | `selftest_guards.py` | the v1.2.0 files (git `f7c45a9`) are flagged at line 77 / 70 and the six constructor lines, the current files are clean, and the synthetic corpus is classified as recorded | ALL SELF-TESTS OK |
| `unit` | `unit_tests.ps1`, both languages | exit 0 and 0 failed | 89 × 2 |
| `report` | `report_stage_tests.ps1`, both languages | exit 0 and 0 failed | 103 × 2 |
| `gui-headless` | `gui_repro.ps1`, both languages × both entries | the body of `Initialize-Gui` runs to the end without an exception | user form 940×700, IT form 940×872 |
| `gui` | `gui_check.ps1`, both languages × both entries, on staged copies (the IT copy configured with 30 pings / 125 s), launched through the shipped `Start-NetworkCheck.cmd` / `Start-NetworkCheck-IT.cmd` like a double-click | the launcher starts PowerShell with `-Interactive -ExpandDetails` for the IT entry only; the window is found; the IT title carries the IT marker and the user title does not; the user run starts by itself; the IT window is idle first (Start enabled, nothing changing for 3 s, no report), then Start is clicked with the panel untouched and the click takes effect; the JSON report's `EntryPoint` and `ExpandDetails` match the entry and `PingCount` / `SampleSeconds` match the folder's configuration (30 / 125 for IT: not clamped to the spinner defaults); the window is closed through its Close button; the launcher exits 0 and writes no `LauncherError.txt` | EntryPoint User 4 / 8, EntryPoint IT 30 / 125, 28 results |
| `acceptance` | console runs on staged copies: en-US user and zh-TW user through the shipped `Start-NetworkCheck-Console.cmd` (its trailing `pause` reads from NUL), and en-US with the IT switches (`-ConsoleOnly -PingCount 6 -SampleSeconds 6 -PingTarget 8.8.8.8 -TcpTarget 1.1.1.1:53 -TracerouteHops 4 -ExpandDetails`) by calling the script directly, because the launcher takes no arguments | exit 0, no `LauncherError.txt`, and a JSON report whose run options match the launch (entry point, ExpandDetails, ping count, sample seconds, hops, extra targets present); `-RequireHealthy` adds Overall Healthy | Overall Healthy; 28 / 30 / 28 results |
| `package` (`-Package`) | `build_asset.py`, then `validate_release.py` run from inside the extracted ZIP, then the extracted `Start-NetworkCheck-IT.cmd` through the real window in both languages | the asset builds from tracked files only with CRLF intact; the packaged validator passes inside the package; the extracted IT launcher opens the IT window with the same checks as the `gui` step | 66 / 66; SHA256 printed for the release notes |

`-RequireHealthy` is off by default: on a machine with a real network problem a warning is the tool doing its job, not a failed test. The reference results above were produced on the author's machine (Windows 11, Windows PowerShell 5.1.26100), where the release record in `healthcheck/VALIDATION.md` expects Overall Healthy.

## The scripts on their own

| Script | What it does | Usage |
|---|---|---|
| `parse_check.ps1` | Parses one script with the Windows PowerShell 5.1 parser and lists the errors. | `-Path <NetworkHealthCheck.ps1>` |
| `unit_tests.ps1` | Loads the helper functions (parsing, conversion, classification, Wi-Fi output parsing) out of the script by AST and checks them against fixed inputs, including Windows 10 / 11 and localized `netsh wlan` samples. | `-ScriptPath <NetworkHealthCheck.ps1>` |
| `report_stage_tests.ps1` | Loads every function of the script, builds the minimal script state, and exercises the report stage: all formats succeed; one format fails; all fail (exactly one emergency report); fingerprint keys from tagged results; run options and profile text; IT-scoped results never change the verdict; adapter counter rows; route ordering; and the IT panel built from real WinForms controls headless, which keeps a configured 30 pings / 300 s instead of clamping them. | `-ScriptPath <NetworkHealthCheck.ps1> -WorkDir <existing folder>` |
| `gui_repro.ps1` | Headless smoke test of `Initialize-Gui`: runs the body of its main `try` block as a script block, so an exception surfaces with its position instead of being swallowed by the function's own `catch` (which silently falls back to console mode). | `-ScriptPath <NetworkHealthCheck.ps1> [-Interactive]` |
| `gui_check.ps1` | Drives the real window through UI Automation the way a person would: runs the shipped launcher for the entry (`-Via Launcher`, the default; `-Via Direct` calls `powershell.exe -File` for debugging), finds the window of the PowerShell process the launcher started and prints the launcher's effective command line; for the user entry verifies that the run starts by itself; for the IT entry lists the panel's edit fields, verifies the window is idle (Start enabled, nothing changing for 3 s, no report), clicks Start with the panel untouched and verifies the click took effect; waits for the JSON report, prints the run options it recorded, closes the window with its Close button, and exits nonzero on any of those failing, on a nonzero exit code of the launched process, or on a `LauncherError.txt`. The folder must be named `en-US` or `zh-TW` (the button names are per language). WinForms controls surface as generic panes through UI Automation, but their names, enabled state and window classes are exact; the JSON report remains the evidence for the values. | `-PackageDir <copy of healthcheck\en-US or zh-TW> -Entry User|IT [-Via Launcher|Direct] [-TimeoutSeconds 300]` |
| `selftest_guards.py` | Self-test of the validator's two PowerShell guards (`unparenthesized_arithmetic`, `overwritten_parameters`): the v1.2.0 anchors, the current files, and the synthetic corpus from the PR #4 review rounds. Backlog #17 keeps this corpus as the acceptance set for the AST rewrite of the guards. | `python tests/selftest_guards.py [<v1.2.0 en-US .ps1> <v1.2.0 zh-TW .ps1>]` |
| `build_asset.py` | Builds the release asset by the packaging rule (tracked files under `healthcheck/` only, working-tree bytes, one `NetworkHealthCheck-<version>/` top folder, deflate) and prints its size and SHA256. | `python tests/build_asset.py [<out.zip>]` |
| `Invoke-ValidationChain.ps1` | Runs the steps above in order on staged copies and prints the summary table. | see above |

## Notes

- `unit_tests.ps1` and `report_stage_tests.ps1` carry a UTF-8 byte-order mark on purpose: Windows PowerShell 5.1 reads a script without one in the system code page, and these two contain zh-TW text in their assertions. `gui_check.ps1` spells its zh-TW button names as character codes for the same reason and stays ASCII.
- The test scripts load functions out of the language files by AST and `Invoke-Expression`, so the functions under test are the shipped ones; nothing is copied into the tests.
- `parse_check.ps1`, `unit_tests.ps1`, `report_stage_tests.ps1` and `gui_repro.ps1` are the scripts that produced the 1.2.1 record, committed as they ran (`report_stage_tests.ps1` was `report_stage_tests_v121.ps1`). `gui_check.ps1` is the 1.2.1 driver extended in the PR #5 review (launcher-driven, idle check before Start, exit codes propagated). `selftest_guards.py` and `build_asset.py` differ from their scratchpad versions only in resolving paths from the repository root and reading the v1.2.0 anchors from git.
