# Validation Record — NetworkHealthCheck

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
2. On report-write failure the emergency report is produced twice (double dialog in GUI mode).
3. If one of the three report formats fails, the whole run is treated as a report failure — "Open Report" stays disabled even when HTML/TXT succeeded.
4. ~~Retransmission thresholds are parsed with raw `[double]` casts (inconsistent with the `ConvertTo-IntSafe` defensive style; a non-numeric config value degrades that step to ERROR). Packet-loss/latency thresholds silently round decimals to integers.~~ — **fixed in v1.1.4** (2026-09-03).
5. ~~CIM fallback path: an IPv6 gateway can satisfy the "IPv4 default gateway" check; a null DHCP state maps to "static" instead of "unknown".~~ — **fixed in v1.1.4** (2026-09-03).
6. ~~Dead stores to clean up: `$script:NetworkSnapshot`, local `$systemSummary`.~~ — **fixed in v1.1.4** (2026-09-03).

### From fault-injection review (2026-07-28)

7. ~~Retransmission ratio above 100 % unexplained~~ — **fixed in v1.1.3** (inline ratio note).
8. ~~AUTO_GATEWAY placeholder leak~~ — **fixed in v1.1.3** (explanatory detail).
9. ~~Optional-ping Information badge unexplained~~ — **fixed in v1.1.3** (inline explanation).
10. Virtual adapters (VirtualBox / Hyper-V) earn Pass rows and inflate the adapter count; demote virtual NICs to Information and report physical vs virtual counts separately ("0 physical" should itself be a failure signal). **Design note (2026-07-29):** this applies to the error-counter check too — a zero-traffic adapter (0 cumulative bytes) reporting "0 errors" is vacuous evidence (counters only testify when traffic flows); annotate zero-traffic adapters and reuse the existing primary-adapter classification (`Get-PrimaryAdapters`) instead of inventing a new mechanism.
11. ~~Full PowerShell stack traces (with local file paths) render in the HTML report; keep them in JSON only, show a one-line summary in HTML.~~ — **fixed in v1.1.4** (2026-09-03).
12. ~~Add a "Method" line to each check's details~~ — **done in v1.1.1** (2026-07-28).
13. Wi-Fi RF data (RSSI / channel / band) for wireless adapters — needs `netsh wlan show interfaces` parsing (locale-sensitive output) or the native WLAN API; note the client-side view is inherently weaker evidence than the AP's client table.
14. OS-locale exception strings pass through verbatim into reports (e.g., a Chinese "作業逾時" inside an en-US report); consider mapping common .NET socket/web exceptions to the report language, or note the behavior in the technical guide.

### From release packaging (2026-09-03)

15. ~~GitHub *Code → Download ZIP* shipped LF line endings — the auto-generated archive failed the validator (all 8 CRLF checks, all 19 SHA256 manifest entries) and was therefore not the validated package~~ — **fixed 2026-09-03** (`.gitattributes`: `healthcheck/** text eol=crlf`, re-simulated archive 54/54; the v1.1.3 release asset is built from tracked files only — see the Packaging entry at the top).
