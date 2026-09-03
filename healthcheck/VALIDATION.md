# Validation Record — NetworkHealthCheck

## v1.2.1 · 2026-09-03 — IT panel keeps configured values; two 1.2.0 GUI regressions

**Changes** (PR #4). The first item is the seventh Codex pass on PR #3; the other two were found by the first real GUI runs of 1.2.0 — the earlier chain exercised the WinForms code by review only.

1. **IT panel truncated configured sampling values (Codex, PR #3 round 7 — P2).** `Set-OptionsPanelValues` clamped `PingCount` to the spinner's 1–20 range and `RetransmissionSampleSeconds` to 1–120, and Start wrote the clamped values back through `Get-RunOptionsFromPanel` even when nothing was touched, while configuration validation accepts any positive Int32 — so `PingCount: 30` ran as 30 from the user entry and the console but as 20 from the IT launcher (300 s → 120 s likewise). Fix: the spinner's `Maximum` is raised to the configured value before the value is assigned (`max(20, configured)` / `max(120, configured)`); the default ranges are unchanged for configurations within them, a panel edit still wins, and "Reset to config" restores both value and range. `TracerouteHops` was already consistent (configuration and panel both enforce 1–10).
2. **The GUI fell back to console mode for both entries (1.2.0 regression, P1).** Six control positions were written as `New-Object System.Drawing.Point(22, 84 + $offset)` (also `Size(900, 700 + $offset)` and `Point(22, $bottomY + 44)`). A `New-Object` argument list is parsed in expression mode, where the comma binds tighter than `+`, so `(22, 84 + $offset)` is the three-element array `22, 84, $offset` and the constructor threw "cannot find an overload for Point and the argument count 3". `Initialize-Gui` caught it, logged "The graphical interface could not be started. Console mode will be used.", and every double-click of `Start-NetworkCheck.cmd` or `Start-NetworkCheck-IT.cmd` ran in a console window. Introduced by v1.2.0 — up to 1.1.5 those lines were literals. Fix: the arithmetic is parenthesized.
3. **The IT launcher opened the user layout (1.2.0 regression, P1).** The top-level line `$script:Interactive = $false` ran after parameter binding and overwrote the bound `-Interactive` switch — a script's top-level scope and its `$script:` scope are the same variable table — so once the GUI could start at all, `Start-NetworkCheck-IT.cmd` showed the user window (no run-options panel, auto-start) with only `-ExpandDetails` in effect. Fix: the variable is initialized from the parameter and the redundant re-assignment in the entry block is removed.
4. **Validator** — two new guards per language file: no unparenthesized arithmetic inside a `New-Object` argument list, and no top-level `$script:<Parameter> = <literal>`; both flag the v1.2.0 files (six lines, and line 77 / 70) and pass on 1.2.1 — 62 → 66 checks. Version 1.2.1 in both scripts, READMEs, guides (§4.10 documents the panel-range rule, §7.2 the history); function count unchanged (77).

**Re-validation (Windows 11, Windows PowerShell 5.1.26100):**

| Step | Result |
|---|---|
| PS 5.1 parser, both languages | 0 errors × 2 |
| `validate_release.py` | 66 passed, 0 failed — skeleton identical, 77 = 77 functions, both new guards pass (and flag the v1.2.0 files when run against them), hashes regenerated (22 files) |
| Helper unit tests | 89 × 2 (unchanged) |
| Report-stage functional tests | 103 × 2 — new I: real WinForms panel controls created headless (no form): a configured 30 pings / 300 s is shown, the spinner ranges widen to 30 / 300, an untouched Start keeps 30 / 300 in the effective configuration and the profile text; a panel edit (12 / 45) still wins; "Reset to config" restores 30 / 300; the default configuration keeps the 1–20 / 1–120 ranges and shows 4 / 8; a CLI `-PingCount 25` is shown, not clamped; traceroute hops keep 1–10 |
| Headless `Initialize-Gui` (the function body executed without showing the form, both entries × both languages) | before the fix: all four threw at `$overall.Location = New-Object System.Drawing.Point(22, 84 + $offset)`; after: user form 940×700, IT form 940×872 with the panel populated |
| **GUI, user entry — real window (UI Automation)** | en-US and zh-TW: the window opens, the run starts by itself, JSON `EntryPoint = User`, ping count 4, sample 8 s, Overall Healthy, 28 results; closed with the Close button, exit 0 |
| **GUI, IT entry — real window (UI Automation)**, configuration `PingCount: 30`, `RetransmissionSampleSeconds: 125` | en-US and zh-TW: the title carries "- IT", the window is the panel layout (872 px logical), the run does not start by itself; Start clicked with the panel untouched → JSON `EntryPoint = IT`, `PingCount = 30`, `SampleSeconds = 125`, gateway ping 30/30, Overall Healthy, 28 results; closed with the Close button, exit 0. Before the fixes the same launch fell back to console mode, and with fix 2 alone it opened the user layout (title without "- IT", 700 px, auto-start) — both also reproduced through `Start-NetworkCheck-IT.cmd` itself |
| Acceptance, en-US user entry (console) | exit 0, Overall Healthy, 28 results (6 IT), fingerprint `healthy`, ~12 s |
| Acceptance, en-US IT entry (console switches: `-PingCount 6 -SampleSeconds 6 -PingTarget 8.8.8.8 -TcpTarget 1.1.1.1:53 -TracerouteHops 4 -ExpandDetails`) | exit 0, 30 results, `EntryPoint = IT`, ping count 6, sample 6 s, 4 hops, extra targets present, ~8 s |
| Acceptance, zh-TW user entry (console) | exit 0, Overall Healthy, 28 results (6 IT), ~10 s |

Lesson: "reviewed, not exercised headlessly" was not enough for WinForms code — the 1.2.0 GUI never opened on a real machine during its six review rounds because every acceptance run used `-ConsoleOnly`. From 1.2.1 the chain includes the headless `Initialize-Gui` smoke test and a UI Automation run of both entries in both languages (backlog #16 is about committing those driver scripts). The panel's spinner values cannot be read back through UI Automation (WinForms `NumericUpDown` exposes no value pattern here); the JSON run options are the evidence instead.

## v1.2.0 · 2026-09-03 — v1.2 Phase A

**Changes** (design: `docs/design-v1.2-triage-wizard.md`, §3–§5; closes backlog #10 and #13):

- **No modes.** Every check runs on every run. The IT entry (`Start-NetworkCheck-IT.cmd` → `-Interactive -ExpandDetails`) adds a run-options panel (extra ping / DNS / TCP / URL targets, ping count, sample seconds, traceroute hops, optional checks, expand details), does not auto-run, and gains an "Open JSON" button. The same options are console switches (`-PingTarget`, `-DnsName`, `-TcpTarget`, `-HttpUrl`, `-PingCount`, `-SampleSeconds`, `-TracerouteHops`, `-NoTraceroute`, `-NoWifi`). Options are applied to an in-memory copy of the configuration; the JSON file is never written.
- **Adapter classification (#10)** — NetAdapter `Virtual` / `HardwareInterface`, CIM `PhysicalAdapter`, or description patterns. Virtual adapters are `INFO` rows; "Usable Network Adapters" reports physical / virtual counts (`WARN` when only virtual adapters carry a gateway, `FAIL` when no physical adapter is connected); error-counter rows for zero-traffic or virtual adapters are `INFO` (the "counters only testify when traffic flows" note).
- **IT diagnostics (#13 and more)** — Wi-Fi radio (`netsh wlan show interfaces`, value-shape parser that handles the Windows 10 and Windows 11 layouts and localized labels, real RSSI when printed), IPv4 default routes, gateway neighbor (ARP), proxy settings, first-hops traceroute (bounded), adapter drivers. All `INFO`, `Scope = "IT"`, collapsed in the HTML, switchable under `Checks`.
- **Report** — every result carries a language-neutral `Tag` and a `Scope`; a fingerprint (`local`, `gateway-unreachable`, `gateway-up-internet-dead`, `dns`, `quality`, `attention`, `mixed`, `incomplete`, `healthy`) drives the new "What to tell IT" section; HTML has a run-profile line, "Expand all / Collapse all", and the collapsed IT section (`-ExpandDetails` opens everything); TXT mirrors it; JSON is schema 2 with `RunOptions` and `Fingerprint`.
- Function count 61 → 76; validator constants and required-file / CRLF lists extended to the IT launchers; both configs gain a `Checks` block.

**Re-validation (Windows 11, Windows PowerShell 5.1.26100):**

| Step | Result |
|---|---|
| PS 5.1 parser, both languages | 0 errors × 2 |
| `validate_release.py` | 62 passed, 0 failed — skeleton identical, 76 = 76 functions, IT launchers CRLF, hashes regenerated (22 files) |
| Helper unit tests | 89 × 2 — new: Wi-Fi parser on Windows 11 (Band / Channel before Radio type, Rssi line), Windows 10 with localized labels and decimal rates, disconnected interface, empty input; adapter classification (flags win over description patterns) |
| Report-stage functional tests | 50 × 2 — the earlier A/B/C write-failure scenarios plus D: eight fingerprint keys from tagged results, and E: run options (extra targets appended, invalid `host:port` reported, out-of-range hops → default, `-NoWifi`, base config untouched, profile text) |
| Acceptance, en-US user entry (console) | exit 0, Overall Healthy, 28 results (6 IT), every result tagged, fingerprint `healthy`, HTML has the tell-IT section / IT block / toggle script, ~17 s |
| Acceptance, en-US IT entry (console switches: extra ping, DNS, TCP, 6-s sample, 4 hops, `-ExpandDetails`) | exit 0, 31 results, `RunOptions.EntryPoint = IT`, extra targets present, 25 `<details open>`, ~8 s |
| Acceptance, zh-TW user entry (console) | exit 0, Overall Healthy, 28 results (6 IT), ~10 s |
| Live IT diagnostics on the test machine | Wi-Fi: SSID, 5 GHz, channel 149, 468/390 Mbps, 78 % / −65 dBm (real RSSI); one default route; gateway neighbor Reachable with MAC; proxy off / direct; traceroute 3 hops (destination not reached, as expected for a public target); 1 physical adapter with driver data |

Not exercised live: a virtual-only-adapter machine ("0 physical" WARN / FAIL path — covered by the classification unit tests and review), a proxy misconfiguration (would require changing the user's proxy settings), and the GUI options panel itself (WinForms; reviewed, and its option plumbing is covered by scenario E). Runtime budget: healthy run 10–17 s, well under the 45 s worst-case budget.

**Independent review — Codex (`chatgpt-codex-connector`), PR #3, round 1 · 2026-09-03.** Three findings on commit b74dc71 (one P1, two P2), all accepted and fixed:

1. *IT-only failures reached the overall result (P1).* An IT collector that threw (permissions, policy, missing provider) added an `ERROR` row and `Get-OverallStatus` counted every `ERROR`, so a healthy run became "Test Incomplete" with the `incomplete` fingerprint — contradicting the promise that IT rows never change the verdict. Fix: `Get-OverallStatus` and `Get-SummaryCounts` exclude `Scope = "IT"`; `Invoke-CheckStep` gained `-Scope` and the whole IT step runs in the IT scope, so even an unexpected exception inside it lands in the IT section only.
2. *Virtual-adapter counter rows were downgraded only when they were PASS.* Deltas above a threshold had already turned the status into `WARN` / `FAIL`, so a VPN adapter could still fail the run. Fix: the virtual classification is applied first, independently of the threshold-derived status; the no-traffic rule follows.
3. *Default routes were sorted lexicographically by route metric, then interface metric.* Windows prefers the lowest route metric + interface metric. Fix: new `Sort-DefaultRoutes` sorts by the effective metric (then route metric); the details line shows it. Function count 76 → 77.

Re-validation after round 1: parser 0 errors × 2; validator 62/62; unit tests 89 × 2; report-stage functional tests 64 × 2 (new: F — an IT-scoped `ERROR` and a failing IT step leave the verdict PASS and the counts untouched while a main-scope step failure still flips it; G — a virtual adapter with 50 errors is INFO, the same physical adapter is FAIL, a zero-traffic adapter is INFO; H — routes 10+100 / 20+5 / 0+50 sort as 25, 50, 110); console acceptance en-US user, en-US IT switches and zh-TW user all Overall Healthy, exit 0.

**Independent review — Codex, PR #3, round 2 · 2026-09-03.** Two P2 findings on commit 7dd99a2, both accepted and fixed:

1. *Counter resets on virtual adapters still warned.* The counter-reset branch emitted a main-scope `WARN` and returned before the virtual-adapter classification ran, so a VPN adapter reconnecting during the sample could turn a healthy run into "Attention Required". Fix: the classification is computed before the reset check and a reset on a virtual adapter is `INFO`.
2. *The IT panel's aggregate checkbox overwrote per-check settings.* One "Routes / ARP / proxy / drivers" checkbox wrote its value back to all four flags on Start, overriding a configuration that enabled some and disabled others. Fix: the panel exposes one checkbox per optional check (Wi-Fi RF, traceroute, routes, gateway ARP, proxy, drivers) on a second row; each is populated from, and written back to, its own flag. Panel height 180 px.

Re-validation after round 2: parser 0 errors × 2; validator 62/62; unit tests 89 × 2; report-stage functional tests 66 × 2 (new: G2 — a counter reset is INFO on a virtual adapter and WARN on a physical one); console acceptance en-US user, en-US IT switches and zh-TW user all Overall Healthy, exit 0. The reworked panel was reviewed, not exercised headlessly.

**Independent review — Codex, PR #3, round 3 · 2026-09-03.** Four findings on commit 5d25e49 (one P1, three P2), all accepted and fixed:

1. *The IT form did not fit a 1366×768 working area (P1).* 700 + 190 = 890 px put the Start button and the title bar off-screen. Fix: the form height is capped against `Screen.WorkingArea` (minus 40 px), the bottom button row and the report label are placed from the actual height, and the log box absorbs the difference; the user entry is unchanged on normal screens.
2. *Warning-only runs unrelated to link quality got the `quality` fingerprint.* Fix: `quality` is chosen only when a loss / latency / retransmission / adapter-error warning exists; other warning-only runs get the new `attention` fingerprint with generic guidance.
3. *An optional extra `-DnsName` that failed selected the `dns` fingerprint although the main DNS check passed.* Fix: `dns` requires that no DNS check passed.
4. *Option-validation notices accumulated across GUI re-runs.* An invalid extra TCP target was appended to the process-wide startup messages and re-emitted (and duplicated) on every Run Again. Fix: per-run `RunOptionMessages`, reset whenever options are applied; `Run-AllChecks` emits startup messages plus the current run's option notices.
5. *(own findings while re-testing)* A run whose only failure was a quality check (18 % TCPv4 retransmissions during a live sample) got the generic `mixed` fingerprint — `quality` now also covers loss / retransmission / adapter-error **failures** when nothing else failed, and `mixed` is reserved for other failures. And because `powershell.exe -File` passes `-PingTarget a,b` as a single string, multi-value switches are now split on commas / semicolons inside `Set-RunOptions` (the launchers and the README examples use `-File`).

Re-validation after round 3: parser 0 errors × 2; validator 62/62; unit tests 89 × 2; report-stage functional tests 76 × 2 (new: config warning only → `attention`; optional DNS failure with a passing DNS check → `attention`, not `dns`; invalid TCP target is a per-run notice that disappears when options are reapplied; `-PingTarget 10.0.0.1,10.0.0.2` yields two extra targets; retransmission FAIL alone → `quality`, with another failure → `mixed`); console acceptance en-US user, en-US IT switches (including an invalid `-TcpTarget bad`, reported once as a startup notice) and zh-TW user, exit 0. The form-sizing change was reviewed, not exercised headlessly.

**Independent review — Codex, PR #3, round 4 · 2026-09-03.** Two P2 findings on commit f6d0d4a, both accepted and fixed:

1. *The 600-px floor still overflowed very short working areas* (an 800×600 remote session with a taskbar leaves ~560 px). Fix: the form height is capped strictly at the working area minus 40 px (sanity floor 400 px), the log box may shrink to 36 px, and when even that does not fit the form turns on `AutoScroll` with the designed size as `AutoScrollMinSize`, so every control stays reachable.
2. *CLI validation notices were lost on the first interactive Start.* `-Interactive -TcpTarget bad` recorded a notice, but the panel was populated from the accepted targets only; Start re-applied the sanitized panel values, reset the per-run notices, and the warning vanished. Fix: `RunOptions` now also carries `RawTargets` (the values as entered) and the panel is populated from them, so the invalid value stays visible and is re-validated — and re-reported — on every run until the IT user removes it.

Re-validation after round 4: parser 0 errors × 2; validator 62/62; unit tests 89 × 2; report-stage functional tests 78 × 2 (new: raw targets keep the invalid value while the accepted list excludes it); console acceptance en-US user, en-US IT switches and zh-TW user, exit 0. Form sizing and the panel were reviewed, not exercised headlessly.

**Independent review — Codex, PR #3, round 5 · 2026-09-03.** Three P2 findings on commit 32d93e0, all accepted and fixed:

1. *`gateway-up-internet-dead` fired for any failing group.* A failing optional group (`WARN`) next to a passing required Internet group still produced the WAN / ISP guidance. Fix: the fingerprint requires a **required** group to fail (`FAIL`) and no group to pass; a required failure next to a passing group is `mixed`, an optional failure alone is `attention`.
2. *Gateway ping execution errors were read as an unreachable gateway.* An `ERROR` (the Ping API could not run) overrode the overall `ERROR` with local-link guidance. Fix: only `FAIL` establishes `gateway-unreachable`; execution errors keep `incomplete`.
3. *Multi-value splitting broke URLs containing commas or semicolons.* Fix: URLs (CLI `-HttpUrl` and the panel box) are separated by whitespace only; ping / DNS / TCP lists still accept commas, semicolons or spaces. Documented in the guides.

Re-validation after round 5: parser 0 errors × 2; validator 62/62; unit tests 89 × 2; report-stage functional tests 83 × 2 (new: optional group failure → `attention`; required failure next to a passing group → `mixed`; gateway ping `ERROR` → `incomplete`; a URL with `,` and `;` survives as one target); console acceptance en-US user, en-US IT switches (including `-HttpUrl "https://www.microsoft.com/?ids=1,2"`) and zh-TW user, exit 0.

**Independent review — Codex, PR #3, round 6 · 2026-09-03 (requested by the maintainer after the five-round limit).** One P2 finding on commit 01ff2c7, accepted and fixed:

1. *CLI ping / DNS / TCP lists were split on commas and semicolons only* while the guide and the IT panel also accept spaces, so `-PingTarget "10.0.0.1 10.0.0.2"` became one invalid target. Fix: the three CLI lists now split on commas, semicolons or whitespace (`[,;\s]+`), matching the panel; URLs keep the whitespace-only rule.

Re-validation after round 6: parser 0 errors × 2; validator 62/62; unit tests 89 × 2; report-stage functional tests 86 × 2 (new: whitespace and mixed separators for ping / DNS / TCP); console acceptance en-US user, en-US IT switches (`-PingTarget "8.8.8.8 9.9.9.9" -TcpTarget "1.1.1.1:53 bad"` → two pings accepted, one TCP accepted, `bad` reported once) and zh-TW user, exit 0.

**Independent review — Codex, PR #3, round 7 · 2026-09-03 (the pass on 08fa353 completed at 15:04, five minutes after the PR was merged at 14:59).** One P2 finding, accepted and fixed in v1.2.1 (PR #4 — see the entry above):

1. *Configured sampling values above the IT panel's spinner range were silently truncated.* `Set-OptionsPanelValues` clamped `PingCount` to 1–20 and `RetransmissionSampleSeconds` to 1–120 and Start wrote the clamped values back, so a valid configuration ran with different sampling through the IT launcher (30 pings → 20, 300 s → 120 s).

The same release fixes two 1.2.0 GUI regressions that the seven review rounds could not see because the GUI was never opened during validation (the "reviewed, not exercised headlessly" rows above).

## v1.1.5 · 2026-09-03

**Changes** (backlog #2 and #3):

- **#3 Partial report-write failures** — `Save-Reports` no longer throws. It returns the per-format paths that were written plus `FailedFormats` / `WriteErrors`, and the new `Complete-ReportStage` decides what happens: all three written → as before; some written → WARN log line, GUI warning dialog, "Open Report" and "Open Folder" enabled, the label points at the first available report; none written → one emergency FATAL report (containing all three write errors with their diagnostics) and one error dialog. "Open Report" now opens the first available of HTML, TXT, JSON instead of insisting on HTML. Console mode prints "(not written)" per missing format, lists the failed formats, and exits 1 only when nothing could be written.
- **#2 Double emergency report** — `Run-AllChecks` handles the report stage once and returns a result object instead of re-throwing, so the GUI click handler and `Start-ConsoleMode` no longer produce a second FATAL file and a second dialog for the same failure. Their catch blocks remain for genuinely unhandled errors elsewhere in the run.
- Function count 60 → 61 (`Complete-ReportStage`); validator constants updated.

**Re-validation (Windows 11, Windows PowerShell 5.1.26100):**

| Step | Result |
|---|---|
| PS 5.1 parser, both languages | 0 errors × 2 |
| `validate_release.py` | 54 passed, 0 failed — skeleton identical, 61 = 61 functions, hashes regenerated |
| Helper unit tests | 57 × 2 (unchanged) |
| Report-stage functional tests (every function loaded via the PowerShell AST, `Write-Utf8File` stubbed to fail selectively, run against both language files) | 23 × 2 — A: all formats written, no FATAL; B: HTML fails → TXT/JSON kept, primary = TXT, no FATAL, the write error carries the call stack; C: all three fail → exactly one FATAL file containing the three write errors with call stacks |
| Acceptance, en-US / zh-TW console | en-US and zh-TW Overall Healthy, exit 0, tool version 1.1.5, 22 results, 11 Method / 10 Manual-check lines |

Not fault-injected end-to-end: a real disk-level write failure during a full run (the functional tests cover the report stage in isolation), and the GUI dialogs were reviewed rather than exercised headlessly.

**Independent review — Codex (`chatgpt-codex-connector`), PR #2 · 2026-09-03: no findings.** The review of commit cb3eda5 completed without any comment on the first pass. This closing note is a documentation-only commit on top of the reviewed code.

## v1.1.4 · 2026-09-03

**Changes** (backlog #4, #5, #6, #11 — see the backlog below):

- **#4 Threshold parsing** — new `ConvertTo-DoubleSafe` / `Test-IsNumericValue` helpers (culture-invariant, non-throwing). Packet-loss, latency and TCP-retransmission thresholds keep decimals instead of being rounded to integers; a non-numeric threshold no longer throws inside the configuration check (which used to degrade that whole step to ERROR) — it is listed in the "Configuration Thresholds" warning and the built-in default is used. Latency thresholds now get the same ordering check as packet loss and retransmissions.
- **#5 CIM/WMI fallback** — only IPv4 next hops from `DefaultIPGateway` count as gateways (an IPv6 gateway can no longer satisfy the IPv4 default-gateway check); a null `DHCPEnabled` is reported as unknown instead of "Disabled (static IP)". Verified by unit test of the filter and by review; the fallback path itself was not fault-injected (NetTCPIP is available on the test machine).
- **#6 Dead stores** — `$script:NetworkSnapshot` and the unused `$systemSummary` capture in `Run-AllChecks` removed.
- **#11 Stack traces** — `Get-ExceptionDetails` now returns the human-readable summary (type, message, inner exceptions); script position and call stack are collected by the new `Get-ExceptionDiagnostics` and stored in a new `Diagnostics` field on every result. HTML and text reports never render it (they show a one-line pointer to the JSON report); the JSON report carries it; the emergency FATAL file keeps the full detail via `-IncludeDiagnostics`. JSON `SchemaVersion` stays 1 — the field is additive.
- Function count 56 → 59; validator updated (`TOOL_VERSION` / `FUNCTION_COUNT` constants, stale "version 1.1.0" label fixed).

**Re-validation (Windows 11, Windows PowerShell 5.1.26100):**

| Step | Result |
|---|---|
| PS 5.1 parser, both languages | 0 errors × 2 |
| `validate_release.py` | 54 passed, 0 failed — skeleton identical, 59 = 59 functions, no CJK in en-US, SHA256 regenerated |
| Helper unit tests (functions extracted via the PowerShell AST, run against both language files) | 26 passed × 2 — decimals kept; `"abc"`, `"5%"`, `"2,5"`, booleans → default; summary/diagnostics split; IPv4-only gateway filter; null DHCP stays unknown |
| Acceptance, en-US console | exit 0, 22 results, tool version 1.1.4, 11 Method / 10 Manual-check lines, every result carries `Diagnostics` (all empty on a healthy run), no call-stack or location text in HTML/TXT |
| Acceptance, zh-TW console | exit 0, Overall Healthy, 22 results, 11 / 10 lines, no call-stack or location text in HTML/TXT |
| Fault-injection config — `PacketLossWarningPercent:"abc"`, `TcpRetransmissionWarningPercent:"x"`, `AdapterErrorWarningDelta:true`, `LatencyWarningMs:100.5`, `TcpRetransmissionCriticalPercent:2.5`, DNS name `nonexistent.invalid` | exit 0; "Configuration Thresholds" WARN lists exactly the three non-numeric values and the run continues on defaults (previously the raw `[double]` cast threw); the DNS failure carries type / message / inner errors in Details and `Location` + `Call stack` only in JSON `Diagnostics`; HTML/TXT show the pointer line and contain no stack or path |

The first en-US acceptance run ended "Attention Required" because TCPv4 retransmissions were 4.1 % during the sample window — a live-network condition above the 2 % warning threshold, not a code effect. The final re-run of both language versions on the finished files (after the header-comment and documentation edits) was **Overall Healthy**: Pass 19 / Warning 0 / Fail 0 / Unable-to-check 0 / Information 3, exit 0, in each language.

**Independent review — Codex (`chatgpt-codex-connector`), PR #1, round 1 · 2026-09-03.** Three P2 findings on commit 84cf529, all accepted and fixed in the same PR:

1. *Rejected integer thresholds still reached `ConvertTo-IntSafe`.* A JSON Boolean was reported as invalid, but `[int]$true` = 1 was then used at runtime (e.g. `AdapterErrorCriticalDelta: true` turned one adapter error into a FAIL instead of using 10; the TCP count and minimum-sample thresholds likewise). Fix: `ConvertTo-IntSafe` treats Booleans like null and returns the default, so the reported fallback actually happens.
2. *Non-finite thresholds accepted.* `"NaN"` and `"Infinity"` pass `Double.TryParse`, and every comparison against NaN is false, so excessive loss / latency / retransmissions would have stayed PASS. Fix: `ConvertTo-DoubleSafe` and `Test-IsNumericValue` require a finite value.
3. *Configuration-parse diagnostics dropped from JSON.* `Load-Configuration` kept only the summary, so a malformed config lost its stack everywhere. Fix: the catch also stores `Get-ExceptionDiagnostics`, and the "Configuration File" result carries it in `Diagnostics` (JSON only, like every other exception path).

Re-validation after round 1: parser 0 errors × 2; validator 54/54; unit tests 36 × 2 (new cases: Boolean → default for integers; `"NaN"`, `"Infinity"`, `[double]::NaN` → default and non-numeric); acceptance en-US and zh-TW Overall Healthy, exit 0; a fault config with `"NaN"` and two Boolean integer thresholds lists all three in the threshold warning; a malformed config file yields the "Configuration File" ERROR with `Diagnostics` populated in JSON and no stack in HTML/TXT.

**Independent review — Codex, PR #1, round 2 · 2026-09-03.** One P2 finding on commit 61bb3a4, accepted and fixed:

1. *Report-write failures lost their original diagnostics.* The three `Save-Reports` catch blocks built their strings with the summary-only `Get-ExceptionDetails`, then threw a new string; the emergency FATAL file therefore recorded the location/stack of that later `throw`, not of the original write failure — a regression against the documented "FATAL keeps full detail" promise. Fix: those three sites use `-IncludeDiagnostics` (they feed the UI log and the FATAL file only, never the HTML/TXT reports). Every remaining summary-only call now either passes a separate `Diagnostics` value to a check result or is the configuration-load message that is rendered in HTML by design.

Re-validation after round 2: parser 0 errors × 2; validator 54/54; unit tests 36 × 2; acceptance en-US Overall Healthy, exit 0; zh-TW first run "Attention Required" (TCPv4 retransmissions 3.9 % in the sample window — live-network condition), re-run Overall Healthy, exit 0. The write-failure path itself was not fault-injected (it would require making both the report folder and `%TEMP%` unwritable); verified by review plus the skeleton-equality check.

**Independent review — Codex, PR #1, round 3 · 2026-09-03.** One P2 finding on commit 15d9102, accepted and fixed:

1. *Count thresholds accepted decimals that runtime silently rounded.* `AdapterErrorCriticalDelta: 2.4` passed the numeric validation, but `Compare-AdapterStatistics` still went through `ConvertTo-IntSafe` (`[int]2.4` = 2), so a delta of 2 could FAIL below the configured threshold; `TcpRetransmissionCriticalCount` and `MinimumTcpSegmentsForRate` likewise. Fix (the "reject" option): new `Test-IsWholeNumber` helper; `ConvertTo-IntSafe` now returns the default for anything that is not a finite whole number within Int32 (no more silent rounding anywhere it is used), and `Test-ConfigurationSemantics` reports "must be a whole number" for the six count thresholds and for the integer test settings (`PingCount`, timeouts, sample seconds) — so validation and runtime agree. Function count 59 → 60; validator constant updated.

Re-validation after round 3: parser 0 errors × 2; validator 54/54; unit tests 52 × 2 (new cases: 2.4 / "2.4" / 3 000 000 000 / null → default, 24.0 / "24" / 1e3 / [uint32] → integers, `Test-IsWholeNumber` matrix); acceptance: en-US exit 0 with a single WARN from a live TCPv4 retransmission sample (3.0 %, reproduced on re-run — the same network condition seen earlier today, not a code effect), zh-TW Overall Healthy, exit 0; fault config with `AdapterErrorCriticalDelta: 2.4`, `TcpRetransmissionCriticalCount: 49.5`, `PingCount: 2.5` and `LatencyWarningMs: 100.5` lists exactly the three whole-number violations (the decimal latency threshold is accepted) and the ping checks run with the default count of 4, proving the fallback happens at runtime.

**Independent review — Codex, PR #1, round 4 · 2026-09-03.** One P2 finding on commit 9842f30, accepted and fixed:

1. *Out-of-Int32 count thresholds passed validation.* `Test-IsWholeNumber` checked integrality but not bounds, so `AdapterErrorCriticalDelta: 3000000000` produced no configuration warning while `ConvertTo-IntSafe` rejected it at runtime and used 10. Fix: the Int32 range check moved into `Test-IsWholeNumber` (the converter relies on it), and the "must be a whole number" messages now say "in the supported range".

Re-validation after round 4: parser 0 errors × 2; validator 54/54; unit tests 57 × 2 (new cases: 3 000 000 000 and −2 147 483 649 rejected, 2 147 483 647 accepted); acceptance: en-US and zh-TW Overall Healthy, exit 0; fault config with `AdapterErrorCriticalDelta: 3000000000` and `MinimumTcpSegmentsForRate: 2147483647` reports exactly the out-of-range value and accepts the Int32 maximum.

**Independent review — Codex, PR #1, round 5 · 2026-09-03: no findings.** The review of commit 3bfc73b completed without any comment. Review loop summary: 5 Codex passes, 6 P2 findings (3 + 1 + 1 + 1), all accepted and fixed in four rounds, each round re-validated with the full chain. This closing note is a documentation-only commit on top of the reviewed code.

## Packaging — v1.1.3 GitHub Release asset · 2026-09-03

- **Finding:** GitHub's auto-generated *Code → Download ZIP* exported every file with LF line endings — the repository stores LF, the author's working tree is CRLF via `core.autocrlf`, and no `.gitattributes` existed. Run against a simulated download (`git archive` of the committed tree), `validate_release.py` reported **27 failures**: all 8 CRLF checks and all 19 SHA256 manifest entries. The auto-generated ZIP was therefore not the validated package (backlog #15).
- **Fix 1 — `.gitattributes`:** `healthcheck/**` is now `text eol=crlf` (the validator, the manifest, this file and validation-matrix.html stay LF), so GitHub-generated archives export CRLF. Re-simulated from the committed tree: **54 passed, 0 failed**.
- **Fix 2 — Release asset:** `NetworkHealthCheck-1.1.3.zip` is built from the *tracked* files under `healthcheck/` only (`git ls-files` → working-tree bytes), which excludes `Reports/` and every other untracked output by construction (§8.11 PII rule). The extracted ZIP was validated before upload: **54 passed, 0 failed**. The asset's SHA256 is in the release notes.
- **LF `.cmd` check:** the LF-only launcher was exercised through its `goto :launcher_error` → `:show_launcher_error` path under cmd.exe and behaved correctly. The CRLF requirement stays as a packaging rule (cmd.exe's label scan is known to misbehave intermittently on LF-only batch files), not as a reproduced failure.

## Scenario matrix — v1.1.3 · 2026-07-30 (author-executed, five fault scenarios)

> Formatted version: [validation-matrix.html](validation-matrix.html) — open locally in a browser (GitHub shows HTML files as source).

All five scenarios re-run on v1.1.3 (Windows 11, en-US build). Every overall verdict correct; every v1.1.3 wording fix verified **under fault conditions** (the 07-29 note "failure path not fault-injected" is now closed for #8 and #9).

| Check | 01 All pass | 02 Wrong DNS | 03 NIC disabled | 04 WAN cut | 05 AP off | As expected? |
|---|---|---|---|---|---|---|
| **Overall verdict** | Healthy | Problem | Problem | Problem | Problem | ✓ 5/5 |
| Default gateway (config) | Pass | Pass | **Fail** | Pass | **Fail** | ✓ |
| Gateway ping | Pass 1.8 ms | Pass | Fail — no target | **Pass 2.2 ms** | Fail — no target | ✓ — 04's "gateway OK" is the *gateway-up-internet-dead* lane signature |
| Public-IP ping (optional) | Pass 30 ms | Pass | Info — send **errors** | Info — **TimedOut** | Info — Unreachable→timeouts | ✓ — the ICMP failure *type* is itself evidence: error = no route to send; timeout = packet left, nothing returned |
| DNS resolution | Pass | **Fail** | Fail | Fail | Fail | ✓ |
| TCP 1.1.1.1:443 | Pass | **Pass** | Info | Info | Info | ✓ — 02's TCP-by-IP pass separates the DNS lane cleanly |
| Internet group | Pass | **Pass** | Fail | Fail | Fail | ✓ |
| TCPv4 retransmissions | 0 % | 0 % | 0 % (38 seg — packets can't leave) | **40.3 % FAIL** (link up, no ACKs) | 16.7 % WARN (small sample) | ✓ — fingerprint pair confirmed: *NIC dead → zero; WAN dead behind a live link → spike* |
| Connected adapters | 3 | 3 | 2 | 3 | 2 | ✓ |

**Fix verification in fault conditions:** #8 AUTO_GATEWAY explanatory wording appears in 03/05; #9 optional-ping Information explanation appears in 03/04/05; Method + Manual-check lines present in every scenario.

**Additional observations:**
- Run duration stretches under faults (04: ~27 s vs ~10 s baseline) — connect/DNS timeouts dominate; the retransmission sample window auto-extended to 24.8 s (`Wait-ForMinimumTcpSample` behaving as designed).
- OS-locale exception strings bleed into reports (a Chinese "作業逾時" appears in the en-US report when the OS throws it) — logged as backlog #14.
- Raw scenario reports are kept out of the repository by design: they contain hostname, username, SSID, and MAC (see technical guide §8.11). This matrix carries the evidence without the PII.
- zh-TW coverage: scenario runs were executed on en-US; zh-TW is covered by happy-path acceptance runs (v1.1.1–v1.1.3) plus the token-skeleton identity proof — the fault-path logic is literally the same code.

## v1.1.3 · 2026-07-29

**Changes** (closing the loop on the fault-injection review):

- **Backlog #1 (major) fixed** — `Initialize-Gui`'s try/catch now wraps the entire function body: any exception during form construction falls back to console mode instead of exiting 1. (Failure path verified by parser + code review; not fault-injected.)
- **Backlog #7 fixed** — a retransmission ratio above 100 % now carries an inline note: it means retransmissions of segments sent before the sample window; read as a ratio, not a percentage.
- **Backlog #8 fixed** — the AUTO_GATEWAY placeholder no longer leaks raw: the failure detail now explains it resolves to the current IPv4 default gateway and none exists.
- **Backlog #9 fixed** — an optional ping target that fails completely now explains its Information badge: ICMP may simply be blocked; the Connectivity group is the authoritative internet verdict.

**Re-validation:** PS 5.1 parser 0 errors × 2; acceptance re-run on both language versions — exit 0, Overall Healthy, tool version 1.1.3 in reports.

## v1.1.2 · 2026-07-28

**Change:** every check's details now also carry a **Manual check line** — the copy-paste command a person can run to reproduce the result by hand (`ping -n 4 <target>`, `nslookup <host>`, `Test-NetConnection <host> -Port <port>`, `Invoke-WebRequest <url> -UseBasicParsing`, `Get-NetAdapterStatistics -Name '<adapter>'`, `Get-CimInstance Win32_PerfRawData_Tcpip_*` sampled twice). The connectivity group is deliberately excluded — it is derived from its members. Reports are now self-explaining **and self-reproducible**.

**Re-validation:** PS 5.1 parser 0 errors × 2; acceptance re-run on both language versions — exit 0, 10 Manual-check lines each (11 Method lines minus the group).

## v1.1.1 · 2026-07-28

**Change:** every check's details now carry a **Method line** stating the underlying API/command and its parameters (e.g., ".NET Ping — 4 ICMP echo requests, timeout 1200 ms", "Win32_PerfRawData_Tcpip_TCPv4 cumulative counters") — reports are self-explaining during walkthroughs. Backlog item 12; both language versions updated identically.

**Re-validation:** PS 5.1 parser — 0 errors in both versions; function parity 56 = 56, names identical; real-machine acceptance re-run on both en-US and zh-TW — Overall Healthy, exit 0, all 11 Method lines present in each report.

---

# v1.1.0 baseline

## Windows acceptance run · 2026-07-28

- **Environment:** Windows 11 Pro (10.0.26200), Windows PowerShell 5.1.26100, standard user, console mode (`-ConsoleOnly`)
- **Result: Overall Healthy** — Pass 20 / Warning 0 / Fail 0 / Unable-to-check 0 · exit code 0 · ~21 s end to end
- All three report formats generated and well-formed (HTML / TXT / JSON)
- Multi-adapter aggregation limitation (technical guide §8.5) observed exactly as documented: virtual adapters (VirtualBox, Hyper-V) listed alongside the active Wi-Fi NIC
- Judgment gating confirmed live: TCP retransmission rate evaluated only after the sent-segment sample exceeded `MinimumTcpSegmentsForRate`

## Independent code review · 2026-07-28

- **Scope:** full read of the 2,825-line en-US script; grep sweeps for any system-mutating command; both language versions parsed with the real Windows PowerShell 5.1 engine; extracted math helpers unit-tested under 5.1 (IPv4-in-CIDR 12/12, mask-to-prefix 5/5, safe converters)
- **Verdict: approved with caveats — zero critical findings**
- **Read-only claim verified:** every filesystem write is confined to the tool's own `Reports/` folder or `%TEMP%`; active network behavior is limited to ping / DNS lookup / TCP connect / HTTP GET, as documented
- **Localization integrity verified:** en-US and zh-TW compile to identical 56-function token skeletons — localization cannot drift behavior

### Verified-correct highlights

- Every counter delta (adapter errors/discards, TCP retransmissions) carries an explicit reset/overflow guard — no wrapped or negative numbers reach a verdict
- "Unable to check" (ERROR) is kept separate from "problem detected" (FAIL) end to end; the tool never conflates *couldn't measure* with *network broken*
- Overall verdict priority FAIL > ERROR > WARN > PASS lives in a single authority function used by all three report formats

## Fault-injection runs · 2026-07-28 (author-executed)

| Scenario | Fault lane | Overall verdict | Key evidence in the report |
|---|---|---|---|
| AP powered off | Local / no link | Problem Detected ✓ | No default gateway; AUTO_GATEWAY target unresolvable; only virtual NICs remain |
| AP WAN disabled | Gateway OK, internet dead | Problem Detected ✓ | Gateway ping 0 % loss **and** Internet group fail; TCPv4 retransmissions 13.8 % (FAIL) |
| PC Wi-Fi NIC disabled | Local / no route | Problem Detected ✓ | Ping attempts error immediately; retransmissions 0 % — packets never leave |
| Wrong DNS (1.2.3.4) | DNS | Problem Detected ✓ | Name resolution FAIL while TCP-by-IP passes — clean lane separation |

All four injected faults were detected and correctly classified at the overall-verdict level. Notable fingerprint pair: WAN-dead-but-link-up drives retransmissions **up** (packets leave, no ACKs); NIC-disabled drives them to **zero** (packets cannot leave).

## Known issues — backlog for v1.1.1

1. ~~GUI fallback gap (major)~~ — **fixed in v1.1.3** (2026-07-29).
2. ~~On report-write failure the emergency report is produced twice (double dialog in GUI mode).~~ — **fixed in v1.1.5** (2026-09-03).
3. ~~If one of the three report formats fails, the whole run is treated as a report failure — "Open Report" stays disabled even when HTML/TXT succeeded.~~ — **fixed in v1.1.5** (2026-09-03).
4. ~~Retransmission thresholds are parsed with raw `[double]` casts (inconsistent with the `ConvertTo-IntSafe` defensive style; a non-numeric config value degrades that step to ERROR). Packet-loss/latency thresholds silently round decimals to integers.~~ — **fixed in v1.1.4** (2026-09-03).
5. ~~CIM fallback path: an IPv6 gateway can satisfy the "IPv4 default gateway" check; a null DHCP state maps to "static" instead of "unknown".~~ — **fixed in v1.1.4** (2026-09-03).
6. ~~Dead stores to clean up: `$script:NetworkSnapshot`, local `$systemSummary`.~~ — **fixed in v1.1.4** (2026-09-03).

### From fault-injection review (2026-07-28)

7. ~~Retransmission ratio above 100 % unexplained~~ — **fixed in v1.1.3** (inline ratio note).
8. ~~AUTO_GATEWAY placeholder leak~~ — **fixed in v1.1.3** (explanatory detail).
9. ~~Optional-ping Information badge unexplained~~ — **fixed in v1.1.3** (inline explanation).
10. ~~Virtual adapters (VirtualBox / Hyper-V) earn Pass rows and inflate the adapter count; demote virtual NICs to Information and report physical vs virtual counts separately ("0 physical" should itself be a failure signal). **Design note (2026-07-29):** this applies to the error-counter check too — a zero-traffic adapter (0 cumulative bytes) reporting "0 errors" is vacuous evidence (counters only testify when traffic flows); annotate zero-traffic adapters and reuse the existing primary-adapter classification (`Get-PrimaryAdapters`) instead of inventing a new mechanism.~~ — **done in v1.2.0** (2026-09-03).
11. ~~Full PowerShell stack traces (with local file paths) render in the HTML report; keep them in JSON only, show a one-line summary in HTML.~~ — **fixed in v1.1.4** (2026-09-03).
12. ~~Add a "Method" line to each check's details~~ — **done in v1.1.1** (2026-07-28).
13. ~~Wi-Fi RF data (RSSI / channel / band) for wireless adapters — needs `netsh wlan show interfaces` parsing (locale-sensitive output) or the native WLAN API; note the client-side view is inherently weaker evidence than the AP's client table.~~ — **done in v1.2.0** (2026-09-03).
14. OS-locale exception strings pass through verbatim into reports (e.g., a Chinese "作業逾時" inside an en-US report); consider mapping common .NET socket/web exceptions to the report language, or note the behavior in the technical guide.

### From release packaging (2026-09-03)

15. ~~GitHub *Code → Download ZIP* shipped LF line endings — the auto-generated archive failed the validator (all 8 CRLF checks, all 19 SHA256 manifest entries) and was therefore not the validated package~~ — **fixed 2026-09-03** (`.gitattributes`: `healthcheck/** text eol=crlf`, re-simulated archive 54/54; the v1.1.3 release asset is built from tracked files only — see the Packaging entry at the top).

### From the v1.2.1 GUI runs (2026-09-03)

16. The unit, functional, headless-GUI and UI Automation test scripts live outside the repository (session scratchpad); commit them — e.g. a top-level `tests/` folder outside the shipped `healthcheck/` package — so the full chain, including the real-window run that caught the two 1.2.0 GUI regressions, is reproducible from a fresh checkout.
