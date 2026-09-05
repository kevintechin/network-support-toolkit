# Package acceptance on another machine — checklist (backlog #19)

One copy per machine and scenario. `Invoke-PackageAcceptance.ps1` fills the automated part and puts this file into its bundle; the rest is what only a person at the desktop can see. An observation without an evidence file (a report, a screenshot, the probe) does not count. Bring the bundle ZIP(s), this file and the screenshots back to the record (`healthcheck/VALIDATION.md`).

**Guided:** `Invoke-AcceptanceCampaign.ps1` (backlog #24) walks this list — it prompts for each change or click below, verifies the machine before running, collects the evidence and writes `campaign_summary.md`; this file stays the specification of what each scenario expects. Its scenario ids are the ones below: A1, M4, M1, M2, M3, A3, A4, M7, M8, M9, A2. Not driven: A5 (run the campaign again under another name after changing the NIC type), A6 (`-SkipGui`), M5 and M6 (the runner's console cases cover them in A1: both console launchers, and the unreachable-target cases in both languages), M10 (read the `adapter` rows and the probe in A1's bundle), M11 (optional hardware).

## The machine

| | |
|---|---|
| Label (as passed to `-Label`) | |
| VM / hardware, NIC type (`e1000e` / `vmxnet3` / physical) | |
| Network mode (NAT / bridged / host-only / disconnected) | |
| Display size, DPI | |
| Account (administrator / standard user) | |
| Policy state (none / `__PSLockdownPolicy` / AppLocker / GPO execution policy / WDAC) | |
| Probe file in the bundle (`environment_probe_*.txt`) | |

Which machines close which gap of backlog #19: **Windows 10** (the tool has never run on it; its PowerShell is 5.1.19041); a **system locale opposite to the report language** in both directions (zh-TW Windows running the en-US package, en-US Windows running the zh-TW package — the chain's two unreachable-target cases show the `Cause:` line in the report language above the operating system's message in the other one); **no wireless adapter, only virtual adapters, or no desktop** (the zero-`wifi`-row rule, the adapter classification, the console fallback). A VM has no wireless adapter, so the Windows 10 `netsh wlan` layout stays untested unless a USB Wi-Fi adapter is passed through. Use Enterprise evaluation media where AppLocker is to be tried; Pro cannot enforce it.

## Preparation

1. In the VM, download `NetworkHealthCheck-<version>.zip` from the Releases page with the browser, so that the Mark of the Web is real. `certutil -hashfile <zip> SHA256` must equal the digest in the release notes.
2. Get the repository's `tests/` folder onto the machine (Code → Download ZIP of the repository, or a copy from the host). Line endings do not matter for these scripts; nothing else is needed — no Python, no git.
3. Snapshot the VM before the first scenario and revert between scenarios that change the machine.

## A. The automated part — one command

```
powershell -NoProfile -ExecutionPolicy Bypass -File tests\Invoke-PackageAcceptance.ps1 -Zip "%USERPROFILE%\Downloads\NetworkHealthCheck-<version>.zip" -ExpectedSha256 <digest from the release notes> -Label <machine-scenario>
```

Leave the desktop alone while it runs (about ten minutes: four real windows, two of them sampling for 125 s). It verifies the asset, extracts it, checks the manifest and the line endings, writes the probe, runs the chain's PowerShell-only steps (parser, unit, report-stage, language-mode guard, headless and real-window GUI, console acceptance with both languages against unreachable targets, result-set self-check) and the package root's launchers, and leaves `nhc-acceptance_<computer>_<label>_<time>.zip` next to the downloaded ZIP. Its exit code is the number of failed and not-run cases.

| Scenario | Command variant | Result (from `acceptance_summary.md`) | Bundle file |
|---|---|---|---|
| A1 baseline (NAT, administrator) | as above | | |
| A2 standard user (log in as one) | as above | | |
| A3 host-only network (no internet) | as above; expect the connectivity checks to fail with `[SocketError …]` / `[WebExceptionStatus …]` causes | | |
| A4 NIC disconnected | as above; expect the adapters row FAIL, "0 physical", no gateway rows | | |
| A5 other NIC type (`ethernet0.virtualDev`) | as above | | |
| A6 no desktop session (run through a scheduled task or a service account, if tried) | add `-SkipGui` | | |

## B. What only a person can see

| # | Steps | Expected | Observed | Evidence |
|---|---|---|---|---|
| M1 | Double-click the downloaded ZIP, open `en-US\`, double-click `Start-NetworkCheck.cmd` **without extracting** | Stock Windows extracts only the file clicked into a temporary view folder (`%TEMP%\Temp1_<zip>\…` on Windows 10, `%TEMP%\<guid>_<zip>.<n>\…` on Windows 11), so the launcher finds no `NetworkHealthCheck.ps1` beside itself and stops with its own message ("The program file NetworkHealthCheck.ps1 is missing. Keep all files in the same folder."), writes `LauncherError.txt` next to itself in that folder and pauses; no report. Where an archiver extracts the whole folder, the tool runs and its report must carry the compressed-folder warning row (backlog #18) — the reports then land in the view folder and disappear with it. Either is the package behaving as designed; the launcher stopped for any other reason is not | | screenshot + `LauncherError.txt` and a listing of the view folder copied out before closing the view (or the report, where the tool ran) |
| M2 | Extract with Explorer **without** Unblock; double-click `Start-English.cmd` | Record the exact Windows prompt (Open File – Security Warning / SmartScreen) and whether the tool runs after it | | screenshot |
| M3 | Right-click the ZIP → Properties → Unblock; extract; double-click `Start-English.cmd` and `Start-Traditional-Chinese.cmd` | The user window opens and starts by itself; the report's "Open Report" opens the HTML in the default browser | | screenshot of the window and of the browser |
| M4 | `Start-NetworkCheck-IT.cmd` at 1366×768 | The IT window fits the screen (the tool clamps its height to the working area minus 40 px), the run-options panel and the Start button are reachable, and the JSON report's `PingCount` / `SampleSeconds` are the configuration's values | | screenshot of the window |
| M5 | `Start-NetworkCheck-Console.cmd` in both languages | Text-mode run, reports written, the window pauses at the end | | the TXT report |
| M6 | zh-TW Windows: an en-US report against unreachable targets (`NetworkHealthCheck.ps1 -ConsoleOnly -PingTarget nhc-no-such-host.invalid -TcpTarget 192.0.2.1:9 -HttpUrl https://nhc-no-such-host.invalid/ -ExpandDetails`); en-US Windows: the zh-TW script the same way | The `Cause:` line is in the report's language; the operating system's own message beneath it is in the other language | | the HTML report |
| M7 | `setx /M __PSLockdownPolicy 4`, open a new session, double-click `Start-English.cmd`; afterwards remove the variable | The launcher shows its own message and pauses (exit code 3 from a *new* PowerShell process — the part the chain's simulation cannot reach); exactly one `NetworkHealthCheck_ENVIRONMENT_<time>.txt` next to the script naming the mode, the version and the machine; no report | | the launcher's console output as captured (`launcher-output.log`), `LauncherError.txt`, the environment report |
| M8 | Group Policy: Computer Configuration → Administrative Templates → Windows Components → Windows PowerShell → *Turn on Script Execution* = **Allow only signed scripts**; `gpupdate /force`; double-click `Start-English.cmd`; revert afterwards | The process-scoped Bypass is overridden: the script does not start, and the user sees PowerShell's "not digitally signed" message through the launcher's pause. Record the exact text — this is the case the language-mode guard cannot reach, because the guard is inside the script | | the launcher's console output as captured (`launcher-output.log` — verbatim what the user sees, in the machine's language), `LauncherError.txt` |
| M9 | (Enterprise) AppLocker: default Script rules **minus the rule that allows BUILTIN\Administrators all scripts** (an administrator is otherwise exempt and the test measures nothing — the driver checks the decision for the account under test with `Test-AppLockerPolicy`), enforce, start the Application Identity service; double-click `Start-English.cmd`; revert afterwards | Record what happens: whether the launcher runs, what PowerShell reports, whether an environment report appears. This is the gold standard of backlog #18; the chain's `envguard` step only simulates it | | the launcher's console output as captured, `LauncherError.txt`, any environment report |

For M7–M9 the driver starts the console launcher the way a double-click does and keeps its output verbatim; that text is the evidence — a screenshot of the same console would show less (it is not searchable and cuts off), so none is asked for. **Before** either policy is applied, the driver has written `RECOVER.txt` and `undo-M7.cmd` into the campaign's state folder: under M7 every new PowerShell is ConstrainedLanguage and the campaign cannot resume, under M8 the unsigned campaign script does not start at all, so the way back must not need PowerShell — `reg delete` for M7 (the `.cmd`), gpedit for M8, secpol for M9.
| M10 | Adapter type in the report (`adapter` rows, "Adapter type:") | A VM's NIC is reported as **Physical** — `Get-NetAdapter` says `HardwareInterface=True` for it, and the shipped rule decides on that flag before it looks at the description. The probe's last section prints the same classification | | the JSON report + the probe |
| M11 | (optional) USB Wi-Fi adapter passed through to the Windows 10 VM | One `wifi` row per connected interface, parsed from this Windows version's `netsh wlan` layout; the probe records the layout as printed | | the probe + the JSON report |

## What every report must show

Overall verdict as expected for the scenario; one `adapter` row per connected adapter with its type; one `wifi` row saying no wireless interface (or one per connected interface); gateway rows naming the machine's gateways; the `PowerShell Version` row carrying `FullLanguage`; `[SocketError …]` / `[WebExceptionStatus …]` causes wherever a target fails; no stack trace in HTML or TXT; JSON `SchemaVersion` 2 with `RunOptions.EntryPoint` matching the launcher used.
