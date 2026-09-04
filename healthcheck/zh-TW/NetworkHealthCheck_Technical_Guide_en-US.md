# NetworkHealthCheck Portable 1.2.1: Features, Design, Validation, and Limitations

## 1. Purpose

This document describes the features, architecture, decision rules, error handling, validation approach, known limitations, and source-comment strategy of the portable `NetworkHealthCheck` tool. It applies to version **1.2.1** and to both the Traditional Chinese and English packages. The executable logic is the same; user-visible text, default test names, and comment language are localized separately.

## 2. Product scope

This is a portable Windows PowerShell diagnostic tool. It installs no service, driver, or packet-capture component. Its purpose is not to replace Wireshark, enterprise monitoring, or switch management. It gives non-technical users a single action that collects consistent network evidence and preserves reasons when a check cannot run.

The tool is read-only with respect to system configuration. It does not change IP, DNS, routes, firewall, proxy, or adapter state. Its active behavior is limited to ping, DNS lookup, TCP connection, and HTTP/HTTPS GET tests.

## 3. Package contents

| File | Purpose |
|---|---|
| `Start-NetworkCheck.cmd` | GUI launcher. Displays startup failures and attempts to write `LauncherError.txt`. |
| `Start-NetworkCheck-Console.cmd` | Console fallback when Windows Forms cannot be used. |
| `Start-NetworkCheck-IT.cmd` | IT entry (1.2): run-options panel, no auto-run, HTML opens with the IT diagnostics expanded. Same switches work in console mode. |
| `NetworkHealthCheck.ps1` | Main diagnostics, decision logic, error handling, and report generation. |
| `NetworkHealthCheck.config.json` | Company IP standards, targets, timeouts, and thresholds. |
| `README_*.txt` | Quick-start and configuration instructions. |
| `NetworkHealthCheck_Technical_Guide_*.md` | English and Traditional Chinese versions of this document. |
| `SHA256SUMS.txt` | SHA-256 values for release files. |
| `tools/validate_release.py` | Cross-platform static release validator; it does not run Windows network checks. |

## 4. Features and decision rules

### 4.1 Configuration loading

The program creates safe built-in defaults, reads the JSON file, and recursively merges overrides. A missing or malformed configuration does not terminate the whole run. Built-in defaults are used, the reason is recorded as `ERROR / Unable to Check`, and other executable checks continue.

Semantic validation covers IPv4 addresses, CIDRs, prefix lengths, gateways, DNS servers, DHCP Boolean state, TCP host/port values, HTTP/HTTPS URLs, DNS targets, and primary timeout values. Some inconsistent thresholds produce warnings. Since 1.1.4, every numeric threshold is parsed by a culture-invariant, non-throwing converter: a non-numeric value (Booleans, NaN and infinities included) is listed in the configuration warnings and replaced by the built-in default, and decimal thresholds (for example `2.5`) are honored instead of being rounded to integers. Count-based settings — the adapter error/discard deltas, `TcpRetransmissionCriticalCount`, `MinimumTcpSegmentsForRate`, `PingCount` and the timeouts — must be whole numbers within the 32-bit integer range; a decimal or out-of-range value there is reported and replaced by the default rather than silently changed. Semantic errors do not currently remove every affected value automatically, so an invalid setting can still make a related result meaningless; the report states this explicitly.

### 4.2 Adapter and IP discovery

The preferred source is `Get-NetIPConfiguration`, `Get-NetIPInterface`, and NetAdapter/NetTCPIP objects. If those are unavailable or fail to provide data, the program falls back to CIM/WMI `Win32_NetworkAdapterConfiguration` and `Win32_NetworkAdapter`.

Collected fields include interface name, description, index, link speed, MAC, network profile, IPv4/IPv6, prefixes, gateways, DNS, DHCP state, and source. Adapters with IPv4 plus a gateway are treated as primary; if none exist, adapters with IPv4 are used. In the CIM/WMI fallback (1.1.4), only IPv4 next hops from `DefaultIPGateway` count as gateways, and a missing `DHCPEnabled` value is reported as unknown rather than as static.

Base rules:

| Condition | Result |
|---|---|
| No connected adapter with an IP address | `FAIL` |
| `169.254.x.x` detected | `FAIL`; commonly indicates DHCP failure |
| Adapter has no IPv4 but has other IP data | `WARN` |
| No IPv4 default gateway | `FAIL` |
| No DNS servers | `FAIL` |

### 4.3 Company-standard comparison

Compliance is evaluated only when at least one rule exists under `Expected`. When all rules are empty, the tool displays current values and does not claim that they are correct or incorrect.

- IP: any IPv4 on a primary adapter may exactly match an allowed address or fall within an allowed CIDR.
- Prefix: any current primary-adapter prefix may match the allowed list.
- Gateway: any current primary-adapter gateway may match the allowed list.
- DNS: every required DNS entry must appear in the aggregated DNS list from primary adapters.
- DHCP: every primary adapter with a known DHCP state must match the expected value; no available state produces `ERROR`.

This multi-adapter aggregation is convenient for common systems, but VPNs, virtual switches, or simultaneous wired/wireless connections may require a customized interface filter.

### 4.4 Ping, packet loss, and latency

Each target uses the .NET `Ping` class and the configured number of probes:

```text
packet loss = (sent - received) / sent × 100%
```

Average, minimum, and maximum latency use successful replies. The decision order is: no replies, critical loss, warning loss, critical average latency, then warning average latency. A severe condition on `Required=true` becomes `FAIL`. A completely silent optional target is normally `INFO`, because ICMP may be blocked.

The default is four probes. With the default 20% critical-loss threshold, one lost reply equals 25% and is severe. Organizations that consider this too sensitive should increase `PingCount` or change thresholds.

### 4.5 DNS

DNS uses `System.Net.Dns.GetHostAddressesAsync()` with a timeout. A required name-resolution failure is `FAIL`; an optional one is `WARN`. This validates the operating system's effective resolver behavior. It does not query each configured DNS server independently.

### 4.6 TCP and HTTP/HTTPS

TCP uses `TcpClient.BeginConnect()`, a bounded wait, and `EndConnect()` to verify whether a socket can be established.

HTTP/HTTPS uses `HttpWebRequest`:

- GET method and automatic redirects.
- Windows system proxy and default proxy credentials.
- Attempts to enable TLS 1.2.
- Reads one byte from the response stream to confirm readability.
- A 4xx/5xx response is still considered network-path reachability; the status code remains in the report.

A `RequiredConnectivityGroups` group passes when at least one member succeeds, not when every member succeeds. The default Internet group can therefore be satisfied by either its TCP or HTTP/HTTPS member.

### 4.7 Adapter errors and discards

`Get-NetAdapterStatistics` is sampled before and after the test:

```text
error delta = ΔReceivedPacketErrors + ΔOutboundPacketErrors
discard delta = ΔReceivedDiscardedPackets + ΔOutboundDiscardedPackets
```

If an ending cumulative value is lower than its baseline, the adapter probably reconnected or the counter reset/overflowed. The tool reports `WARN` rather than calculating a negative delta. Thresholds are controlled by AdapterError* and AdapterDiscard* settings.

### 4.8 TCP retransmissions

CIM/WMI reads:

- `Win32_PerfRawData_Tcpip_TCPv4`
- `Win32_PerfRawData_Tcpip_TCPv6`
- `SegmentsSentPersec`
- `SegmentsRetransmittedPersec`

Although the RawData property names contain `Persec`, the program treats the values as cumulative snapshots and computes deltas:

```text
approximate retransmission rate = ΔRetransmittedSegments / ΔSentSegments × 100%
```

Rules:

1. Missing before/after data: `ERROR`.
2. Ending value below baseline: reset/overflow, `ERROR`.
3. Both sent and retransmitted deltas are zero: insufficient sample, `INFO`.
4. Sent segments below `MinimumTcpSegmentsForRate`: retransmissions produce `WARN`; none produce `INFO`.
5. With enough traffic, percentage and absolute count determine `PASS/WARN/FAIL`.

This is a system-wide approximation for the whole computer and sample period. It cannot identify the application, remote host, or TCP stream responsible for a retransmission.

### 4.9 Overall result

Overall precedence is fixed:

```text
FAIL > ERROR > WARN > PASS
```

Any `FAIL` produces Problem Detected. With no failure but at least one unexecuted check, the result is Test Incomplete. Warnings are next, and only then Overall Healthy.

### 4.10 Adapter classification, IT diagnostics, and the fingerprint (1.2)

Every adapter is classified as physical or virtual: the NetAdapter `Virtual` / `HardwareInterface` flags win, the CIM fallback uses `Win32_NetworkAdapter.PhysicalAdapter`, and without flags a description pattern (VirtualBox, Hyper-V, VMware, TAP, tunnel, loopback, WAN Miniport, WireGuard, ZeroTier, Tailscale, Docker, VPN, ISATAP, Teredo) decides. Virtual adapters are `INFO` rows and never trigger the APIPA or no-IPv4 rules; the "Usable Network Adapters" row reports physical and virtual counts and becomes `WARN` when only virtual adapters carry a gateway (VPN or virtualization) and `FAIL` when no physical adapter is connected. Error-counter rows for adapters with no traffic during the sample, or for virtual adapters, are `INFO` — counters only testify when traffic flows. Primary-adapter selection for the company-standard comparison is unchanged.

IT diagnostics run on every run (each can be disabled under `Checks` in the configuration or with `-NoWifi` / `-NoTraceroute`), are `INFO` only, carry `Scope = "IT"`, and appear in the collapsed IT section of the HTML report:

| Check | Source | Notes |
|---|---|---|
| Wi-Fi radio | `netsh wlan show interfaces`, parsed by value shape (MAC, GHz, 802.11x, percentage, numbers) because labels are localized and their order differs between Windows 10 and 11 | SSID, BSSID, band (inferred from the channel when the build prints none), channel, rates, signal %, RSSI (real when netsh prints it, otherwise estimated from the percentage) |
| IPv4 default routes | `Get-NetRoute -DestinationPrefix 0.0.0.0/0`, sorted by the effective metric (route metric + interface metric, the order Windows uses) | more than one route on different interfaces is called out in the details |
| Gateway neighbor (ARP) | `Get-NetNeighbor` (fallback `arp -a`) | a missing or incomplete MAC is noted; the gateway ping stays the authoritative test |
| Proxy settings | HKCU Internet Settings, `WebRequest.GetSystemWebProxy`, `netsh winhttp show proxy` | explains "TCP to 443 passes but HTTPS fails" |
| Traceroute (first hops) | .NET `Ping` with TTL 1..N (default 3, maximum 10), 1000 ms per hop | target is the first non-AUTO ping target |
| Adapter drivers | NetAdapter `DriverVersion` / `DriverDate` / `DriverProvider` | physical adapters only |

IT-scoped rows never affect the overall result or the summary counts: `Get-OverallStatus` and `Get-SummaryCounts` exclude `Scope = "IT"`, and a failed IT collection shows as "Unable to Check" inside the IT section only (the whole IT step runs in that scope, so even an unexpected exception there cannot flip the verdict). Virtual-adapter counter rows are informational regardless of their deltas.

Every result now carries a language-neutral `Tag` (for example `ping-gateway`, `dns`, `connectivity-group`, `tcp-retransmissions`, `wifi`) and a `Scope` (`Main` or `IT`). A fingerprint is computed from the tags — `local`, `gateway-unreachable`, `gateway-up-internet-dead` (a required connectivity group failed and no group passed while the gateway answers), `dns` (only when no DNS check passed), `quality` (loss, latency, retransmission or adapter-error warnings or failures, when nothing else failed), `attention` (other warning-only runs), `mixed`, `incomplete`, `healthy` — and drives the "What to tell IT" section at the top of the HTML and text reports; the JSON report stores it under `Fingerprint`.

Run options come from the entry point: `Start-NetworkCheck-IT.cmd` passes `-Interactive -ExpandDetails`; the switches `-PingTarget`, `-DnsName`, `-TcpTarget` (host:port), `-HttpUrl`, `-PingCount`, `-SampleSeconds`, `-TracerouteHops`, `-NoTraceroute`, `-NoWifi` add or tune this run only (several ping / DNS / TCP values are separated by commas, semicolons or spaces, e.g. `-PingTarget 10.0.0.1,10.0.0.2`; several URLs are separated by spaces only, because commas and semicolons are legal inside a URL) and are recorded in the report's run profile line and in the JSON `RunOptions` object (`EntryPoint`, `ExtraTargets` — the accepted values, `RawTargets` — the values as entered, `PingCount`, `SampleSeconds`, `TracerouteHops`, `ChecksEnabled`). The IT panel's ping-count and sample-seconds spinners cover 1–20 and 1–120 s by default; a configured value above these limits widens the spinner's range, so the configured value is displayed and an untouched Start runs with it (1.2.1). The configuration file is never written. JSON `SchemaVersion` is 2.

## 5. Error-handling design

- Every major step is wrapped by `Invoke-CheckStep`; exceptions become `ERROR` results and later checks continue.
- `Get-ExceptionDetails` records exception type, message, and up to five inner exceptions. Since 1.1.4 the script position and call stack are collected separately by `Get-ExceptionDiagnostics` and stored only in the JSON report's `Diagnostics` field; the HTML and text reports show a one-line pointer instead, so local file paths never render in the human-facing reports. The emergency (`FATAL`) file still carries the full detail.
- GUI initialization failure falls back to console mode.
- An unwritable report directory falls back to `%TEMP%\NetworkHealthCheck\Reports`.
- HTML, TXT, and JSON are attempted separately. Since 1.1.5 a failed format is reported (log line, GUI warning dialog) while the formats that succeeded stay usable — "Open Report" opens the first available of HTML, TXT, JSON, and console mode prints "(not written)" for the missing one. Only when all three fail is a single emergency `FATAL` text report written (with the three write errors and their call stacks) and a single error dialog shown; console mode then exits with code 1. The report stage is handled once inside `Run-AllChecks` and never re-thrown, so the outer handlers no longer produce a second FATAL file or dialog.
- The launcher displays missing-file/PowerShell/non-zero-exit failures and attempts to write `LauncherError.txt`.

## 6. Source design and comments

The program consists of 77 named functions grouped into helpers, configuration, system discovery, policy comparison, active tests, counters, reporting, orchestration, and GUI.

Version 1.1.0 adds:

- An architecture and safety overview at the top of each source file.
- Section comments before each major functional group.
- Existing local comments for fallbacks and edge cases.
- Traditional Chinese comments in the zh-TW source and English comments in the en-US source.

Comments focus on intent and risk rather than restating every obvious PowerShell statement. Function names and executable structure remain the same in both languages to reduce maintenance drift.

## 7. Validation approach

### 7.1 Static validation completed for this release

The build performed checks that do not require a Windows network environment:

1. Required files and directories exist.
2. Both JSON files parse as UTF-8 with BOM.
3. PowerShell/JSON use UTF-8 BOM and Windows scripts use CRLF.
4. English PowerShell, configuration, and README contain no Chinese user-facing text.
5. After removing strings and comments, the English and Chinese PowerShell executable skeletons are identical.
6. Both sources expose the same 77-function set.
7. Launchers reference `NetworkHealthCheck.ps1` correctly.
8. Every SHA-256 entry is recalculated and compared.
9. ZIP integrity tests report no damaged members.

The validator is `tools/validate_release.py`; run it against the package root to reproduce these checks. Current results are recorded in `../VALIDATION.md`.

### 7.2 Validation status on Windows

The original 1.1.0 package was produced in a non-Windows build environment, so Windows Forms, NetTCPIP, NetAdapter, CIM/WMI performance counters, and real network operations could not be executed at packaging time. Since then, versions 1.1.1–1.1.3 (2026-07-28/30) have completed full Windows validation on Windows 11 with Windows PowerShell 5.1: real-machine acceptance runs of both language versions, an independent code review, and five author-executed fault-injection scenarios. The current record is maintained in `../VALIDATION.md`. Version 1.1.4 (2026-09-03) closes backlog items #4, #5, #6, and #11 (threshold parsing, CIM-fallback gateway/DHCP semantics, dead stores, stack traces kept out of HTML/TXT) and was re-validated with the same chain: parser, validator, helper unit tests, acceptance runs of both languages, and a fault-injection configuration. Version 1.1.5 (2026-09-03) closes backlog items #2 and #3 (single emergency report; partial report-write failures keep the successful formats usable) and was validated with the same chain plus report-stage functional tests that stub the file writer. Version 1.2.0 (2026-09-03) implements Phase A of the v1.2 design (`docs/design-v1.2-triage-wizard.md` in the repository): adapter classification, IT diagnostics, the fingerprint and "What to tell IT" section, JSON schema 2, and the IT entry point. It was validated with the same chain plus the extended unit tests (Wi-Fi parser on Windows 10 / 11 / localized samples, classification) and functional tests of the run options and fingerprint. Version 1.2.1 (2026-09-03) closes the one finding of the seventh Codex pass on the v1.2.0 pull request, which completed after the merge (the IT panel no longer truncates a configured ping count or sample length that exceeds the spinner defaults), and fixes two 1.2.0 regressions found by the first real GUI runs of that version. First, six control positions were written as `New-Object System.Drawing.Point(22, 84 + $offset)`, which PowerShell parses as a three-element argument list because the comma binds tighter than `+`, so `Initialize-Gui` threw and both entry points silently fell back to console mode. Second, the script-level initialization `$script:Interactive = $false` overwrote the bound `-Interactive` parameter (a script's top-level scope and its `$script:` scope are the same), so `Start-NetworkCheck-IT.cmd` opened the user layout and auto-started instead of showing the run-options panel. The arithmetic is now parenthesized, the initialization takes the parameter's value, a static guard rejects both patterns (inside this validator up to 1.2.1; on the PowerShell AST in the repository's test chain since 2026-09-04, which is why the packaged validator runs 62 checks rather than 66), and both entries were exercised through the real window (UI Automation) in both languages in addition to the usual chain. Static validation still does not replace Windows acceptance testing — the two complement each other.

### 7.3 Recommended Windows acceptance matrix

| Scenario | Expected result |
|---|---|
| Windows 11, standard user, healthy DHCP | GUI completes; HTML/TXT/JSON are created; core connectivity passes. |
| Wi-Fi disabled/cable removed | Adapter/gateway/DNS failures appear; a report is still created. |
| DHCP failure with 169.254.x.x | APIPA check is `FAIL`. |
| Invalid JSON | Error is shown/reported; built-in defaults continue. |
| Read-only report folder | Output falls back to `%TEMP%` with a notice. |
| PowerShell blocked by policy | Launcher shows the reason and attempts `LauncherError.txt`. |
| GUI components unavailable | Automatic console fallback or manual console launcher works. |
| DNS blocked | Required DNS fails while IP/TCP tests still execute. |
| TCP port closed | Required target fails; optional target is informational; group uses other members. |
| HTTP returns 403/500 | Path is reachable and status code is retained. |
| Adapter reconnects | Counter reset warning appears; no negative delta is reported. |
| Sufficient TCP traffic | Deltas match before/after CIM values for TCPv4/TCPv6. |

Acceptance should cross-check reports against `Get-NetIPConfiguration`, `Get-NetAdapterStatistics`, raw CIM/WMI counters, and the organization's network plan.

## 8. Known limitations

1. **Windows only.** Intended for Windows 10/11 and compatible Windows Server with PowerShell 5.1 or later.
2. **Not a packet analyzer.** It does not capture packets or inspect ACK/sequence numbers and cannot prove a per-flow root cause.
3. **Short, system-wide TCP sample.** Background updates, browsers, and other programs affect the numbers; zero traffic means insufficient evidence.
4. **ICMP may be blocked.** Ping failure does not prove that TCP/HTTPS is unavailable.
5. **Multi-adapter/VPN aggregation.** One adapter may satisfy part of a rule; complex environments need adapter/type/route filtering.
6. **No VLAN, switch, or radio telemetry.** It cannot directly read VLAN IDs, switch CRCs, optics, Wi-Fi signal/channel congestion, or AP roaming logs.
7. **Cannot infer an unspecified company standard.** Empty Expected rules display current state only.
8. **HTTP GET reaches the target service.** Use approved, side-effect-free health URLs. Targets may log source IP, User-Agent, or proxy-authentication activity.
9. **Thresholds require calibration.** Defaults are not guaranteed for Wi-Fi, VPN, satellite, international WAN, data center, or high-throughput servers.
10. **Policy and endpoint security can block data.** AppLocker, WDAC, EDR, WMI policy, or damaged performance counters produce `ERROR`, not proof of a network defect.
11. **Reports contain sensitive data.** Computer/user names, MAC/IP/DNS, internal services, and exception stacks (JSON report only, with local script paths) may be present.
12. **No automatic repair.** Diagnosis is intentionally separated from configuration changes.

12. **Wi-Fi data is client-side and text-parsed.** `netsh` output is parsed by value shape; an unusual build may leave a field empty, and the RSSI is estimated when the build does not print it. The access point's client table is the stronger evidence.
13. **Adapter classification without NetAdapter flags is heuristic** (description patterns).
14. **Traceroute is bounded** to 10 hops and 1 s per hop; silent hops show as `*`, and the default 3 hops rarely reach a public target — the goal is to see where packets stop, not to reach it.

## 9. Release and maintenance guidance

- Replace default public targets with organization-approved services before broad deployment.
- Establish baseline reports for wired, Wi-Fi, VPN, and restricted-internet environments.
- After editing `.ps1`, rerun static validation and Windows acceptance and regenerate SHA-256 values.
- Deploy the whole folder rather than a single launcher.
- For precise retransmission diagnosis, correlate report timestamps with Wireshark, pktmon, switch counters, or centralized monitoring.
