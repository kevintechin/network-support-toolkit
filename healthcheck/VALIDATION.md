# Validation Record — NetworkHealthCheck

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
4. Retransmission thresholds are parsed with raw `[double]` casts (inconsistent with the `ConvertTo-IntSafe` defensive style; a non-numeric config value degrades that step to ERROR). Packet-loss/latency thresholds silently round decimals to integers.
5. CIM fallback path: an IPv6 gateway can satisfy the "IPv4 default gateway" check; a null DHCP state maps to "static" instead of "unknown".
6. Dead stores to clean up: `$script:NetworkSnapshot`, local `$systemSummary`.

### From fault-injection review (2026-07-28)

7. ~~Retransmission ratio above 100 % unexplained~~ — **fixed in v1.1.3** (inline ratio note).
8. ~~AUTO_GATEWAY placeholder leak~~ — **fixed in v1.1.3** (explanatory detail).
9. ~~Optional-ping Information badge unexplained~~ — **fixed in v1.1.3** (inline explanation).
10. Virtual adapters (VirtualBox / Hyper-V) earn Pass rows and inflate the adapter count; demote virtual NICs to Information and report physical vs virtual counts separately ("0 physical" should itself be a failure signal). **Design note (2026-07-29):** this applies to the error-counter check too — a zero-traffic adapter (0 cumulative bytes) reporting "0 errors" is vacuous evidence (counters only testify when traffic flows); annotate zero-traffic adapters and reuse the existing primary-adapter classification (`Get-PrimaryAdapters`) instead of inventing a new mechanism.
11. Full PowerShell stack traces (with local file paths) render in the HTML report; keep them in JSON only, show a one-line summary in HTML.
12. ~~Add a "Method" line to each check's details~~ — **done in v1.1.1** (2026-07-28).
13. Wi-Fi RF data (RSSI / channel / band) for wireless adapters — needs `netsh wlan show interfaces` parsing (locale-sensitive output) or the native WLAN API; note the client-side view is inherently weaker evidence than the AP's client table.
