# Validation Record — NetworkHealthCheck v1.1.0

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

1. **GUI fallback gap (major):** `Initialize-Gui`'s try/catch covers assembly loading only; an exception thrown during form construction exits with code 1 instead of falling back to console mode. Fix: wrap the entire function body.
2. On report-write failure the emergency report is produced twice (double dialog in GUI mode).
3. If one of the three report formats fails, the whole run is treated as a report failure — "Open Report" stays disabled even when HTML/TXT succeeded.
4. Retransmission thresholds are parsed with raw `[double]` casts (inconsistent with the `ConvertTo-IntSafe` defensive style; a non-numeric config value degrades that step to ERROR). Packet-loss/latency thresholds silently round decimals to integers.
5. CIM fallback path: an IPv6 gateway can satisfy the "IPv4 default gateway" check; a null DHCP state maps to "static" instead of "unknown".
6. Dead stores to clean up: `$script:NetworkSnapshot`, local `$systemSummary`.

### From fault-injection review (2026-07-28)

7. TCPv6 retransmission ratio can exceed 100 % (observed 15 retrans / 5 sent = "300 %") — retransmissions of pre-sample traffic break the percentage semantics; cap the display or annotate as a ratio.
8. "Configured value: AUTO_GATEWAY" leaks an internal placeholder into a user-facing failure message; reword to "No default gateway exists to test."
9. The non-required public-IP ping shows "100 % loss" with an Information badge and no explanation; add "informational — ICMP may be blocked; see the Connectivity group for the authoritative internet verdict."
10. Virtual adapters (VirtualBox / Hyper-V) earn Pass rows and inflate the adapter count; demote virtual NICs to Information and report physical vs virtual counts separately ("0 physical" should itself be a failure signal).
11. Full PowerShell stack traces (with local file paths) render in the HTML report; keep them in JSON only, show a one-line summary in HTML.
12. Add a "Method" line to each check's details (command / API + parameters) so reports are self-explaining during walkthroughs (author request).
